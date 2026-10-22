# Migration tool — design (operator layer first)

The bind/unbind/restart mechanics are small. What makes a Tuesday-afternoon wave succeed with
a nervous app team on the call is that the operator **always knows where every service is**,
**can stop at any moment without leaving anything half-done**, and **can go backwards**. This
document defines that layer. Implementation: one bash script (`migrate.sh`, subcommands, same
shape as the discovery tool), `jq`, and plain files — no daemon, no database, no new UI.
The operator's step-by-step instructions (scan → plan → provision → provision-check → preflight →
apply, FAIL → action tables) are in [RUNBOOK.md](RUNBOOK.md); this document is the why.

---

## 1. The ledger, explained

**What it is.** A single append-only text file, `ledger.jsonl` — one JSON object per line,
one line per thing that happened. Nothing is ever edited or deleted; new facts are appended.

```json
{"ts":"2026-10-14T14:02:11Z","wave":2,"service":"orders-cache","app":"orders-api","step":"bind-valkey","outcome":"ok","ms":2140,"op":"jsmith","note":""}
{"ts":"2026-10-14T14:02:19Z","wave":2,"service":"orders-cache","app":"orders-api","step":"unbind-redis","outcome":"ok","ms":1830,"op":"jsmith","note":""}
{"ts":"2026-10-14T14:03:02Z","wave":2,"service":"orders-cache","app":"orders-api","step":"restart","outcome":"ok","ms":41200,"op":"jsmith","note":"rolling"}
{"ts":"2026-10-14T14:03:50Z","wave":2,"service":"orders-cache","app":"orders-api","step":"verify","outcome":"fail","ms":900,"op":"jsmith","note":"NOAUTH from app"}
{"ts":"2026-10-14T14:04:05Z","wave":2,"service":"orders-cache","app":"orders-api","step":"rollback","outcome":"ok","ms":38000,"op":"jsmith","note":"rebind redis + restart; cause: verify fail"}
```

**Why this and not "the script remembers".** A script's memory dies with the process — on a
Ctrl-C, an SSH drop, a laptop lid. The ledger survives all of that, and it gives four things
for free:

| need | how the ledger provides it |
|---|---|
| **resume** after interruption | `apply` reads the ledger first and skips every step already recorded `ok` for that app; it continues from the first missing one |
| **status** at any moment | "where is app X?" = its **last** event. "where is service Y?" = derived from its apps' last events. No separate state to keep in sync |
| **rollback** knows what to undo | the sequence of `ok` steps for an app *is* the list of things to reverse, in reverse order |
| **the evidence pack** | the report is the ledger rendered: per-app timeline, durations (`ms`), incidents (`outcome:fail`), who did what (`op`) |

**How a state is computed (the only rule).** An app's state = the `step` of its most recent
event with `outcome=ok`, unless its most recent event of any kind is `fail`/`blocked`, in which
case the state is that failure. That's one `jq` expression; `status`, `watch`, `rollback`, and
`report` all call the same one, so they can never disagree.

**Reading it by hand** (nothing is hidden in a format only the tool understands):

```bash
jq -r 'select(.app=="orders-api") | "\(.ts) \(.step) \(.outcome) \(.note)"' ledger.jsonl   # one app's story
jq -r 'select(.outcome!="ok") | "\(.ts) \(.service)/\(.app) \(.step): \(.note)"' ledger.jsonl  # every incident
```

**Where it lives.** `runs/<env>/ledger.jsonl` next to `waves.tsv` (the plan is a tab file, not YAML -- editable in Excel, no YAML parser needed on the bastion), `commands.log` (every cf/
genesis command with timestamp and exit code) and `lock`. Copy the directory and you have the
complete record of the migration; git-track it if you want history of history.

**What it is not.** Not a lock (that's the `lock` file), not the plan (that's `waves.tsv`), and
never a source of truth about the *platform* — before acting, `apply` always re-reads reality
(`cf` bindings, app state) and reconciles: if the ledger says "bound to valkey" but CF doesn't,
the ledger gets a `drift` event and the operator is asked, not overridden.

---

## 1a. Identity rule — GUIDs, never names

Service names change during the migration by design (Redis → `<name>-redis-standby`, Valkey
born as `<name>`), so a name is never an identity. The plan and the ledger key every service
on its **service-instance GUID** (`redis_si_guid`, `valkey_si_guid`; apps on `app_guid`); names
are recorded attributes. Consequences:
- `rename-standby` is a ledger event: `{guid, from, to}` — the full name history is on file.
- `create-valkey` records the new instance's GUID; `plan` writes it back into `waves.tsv`.
- `apply` never issues a name-taking `cf` command: every step is a **v3 API call addressed by
  GUID** (§1b). Before each step it still asserts the name↔GUID mapping it expects
  (`/v3/service_instances?names=<n>&space_guids=<s>` → exactly the GUID the ledger holds for that
  role: `<name>` ⇒ the Valkey, `<name>-redis-standby` ⇒ the Redis). Mismatch ⇒ `drift` event,
  stop, ask — never bind the wrong instance.
- `status` prints `name (guid-prefix)` for services, so the dashboard stays unambiguous while
  names are in motion. BOSH deployment names are GUID-based already and never change.

## 1b. No `cf target` — waves run in parallel across orgs and spaces

NP spreads ~300 Redis over ~40 orgs, and waves are meant to run **concurrently**. `cf target`
only writes the org/space into `~/.cf/config.json` so that name-based CLI commands can resolve
names; it is per config file, not per command, so several workers sharing one `CF_HOME` would
fight over it. `cf curl` ignores the target entirely. Therefore:

| step | v3 call (all by GUID, space-independent) |
|---|---|
| rename Redis → standby | `PATCH /v3/service_instances/<redis>` `{"name":"<n>-redis-standby"}` |
| create Valkey in the same space | `POST /v3/service_instances` `{type:managed, name:<n>, relationships:{space:<redis's space>, service_plan:<valkey plan>}}` → 202 job |
| bind app → Valkey | `POST /v3/service_credential_bindings` `{type:app, relationships:{app, service_instance}}` → 202 job |
| unbind app ← standby | `DELETE /v3/service_credential_bindings/<binding>` → 202 job |
| restart | `POST /v3/apps/<app>/actions/restart`; ≥2 instances: `POST /v3/deployments {app}` (rolling); stopped app: no call |
| waits / checks | `GET /v3/jobs/<job>` until COMPLETE/FAILED · `GET /v3/service_instances/<guid>` last_operation · `GET /v3/apps/<app>/processes/web/stats` |

Consequences:
- **One `cf login`** (an admin) serves every wave; nothing is ever targeted; a worker cannot act in
  the wrong space because there is no "current space".
- **Per-worker `CF_HOME`** anyway: `cf curl` refreshes the access token by rewriting
  `config.json`, and concurrent rewrites race. `apply` copies the logged-in config into
  `runs/<env>/cf-home/wave-N/.cf/` and runs with `CF_HOME=runs/<env>/cf-home/wave-N` — `CF_HOME`
  is the **parent** of `.cf` (cf reads `$CF_HOME/.cf/config.json`); copying `.cf` to the
  `CF_HOME` directory itself gives "No API endpoint set" (populate.sh, 2026-10-18). If the client's UAA rotates refresh
  tokens (`jwt.refresh.rotate=true`) the copies would invalidate each other — preflight tests
  this once (refresh a copy, check the original still works) and, if so, each wave worker logs in
  itself instead of copying.
- **Per-wave lock** (`runs/<env>/wave-N.lock`), not a global one; the `STOP` file stays global.
- **Ledger under concurrent writers:** one line per event appended with `>>` (O_APPEND, a line is
  far below PIPE_BUF) — appends from several processes never interleave on a local filesystem.
  `status` reads the whole file, so the dashboard shows every running wave.
- The CLI equivalent of each call is printed alongside in `dry-run` for operators who think in
  `cf` commands; it is documentation, not what runs.

## 2. Per-app state machine

```
PENDING ─bind-valkey─► BOUND-V ─unbind-redis─► UNBOUND-R ─restart─► RESTARTED ─verify─► VERIFIED
   ▲                      │                        │                    │                 │
   └────── rollback ──────┴────────────────────────┴────────────────────┘                 │
                                                                            confirm (per service)
                                                                                          ▼
                                                        STANDBY ─(grace elapsed)─ retire ─► RETIRED
                                                           ▲                                (final)
                                                       rollback still possible
```

Per-service state = the "lowest" state among its apps, plus the service-level steps
(`create-valkey`, `copy-data`, `confirm`, `retire`). Wave state = the same over its services.

## 3. Rollback, defined per step

**Scope rule:** the unit of rollback is the **service** (all its apps), because apps sharing a
Redis may share data through it; rolling back one app alone would split the group between
Redis and Valkey. `rollback --app X` exists as an explicit override for apps known to be
independent. Rollback of one service does not touch an app's other connections (an app on
R1-rolled-back and V2 is fine — connections are independent), except for declared pipeline
groups, which roll back together. Writes made to the Valkey between cutover and rollback are
lost for that service (cache: irrelevant; store: the copy discipline keeps Redis authoritative
until `confirm`, and rollback happens before `confirm` by construction).


| app is at | rollback does | data risk |
|---|---|---|
| BOUND-V | unbind Valkey | none |
| UNBOUND-R | rebind Redis | none — Redis untouched |
| RESTARTED / VERIFIED (or that restart **failed**) | rebind Redis + restart — a failed restart onto the Valkey counts: the rebind helps only after a new start | writes made to Valkey since cutover (store-mode apps: counted and reported) |
| already ROLLED BACK (`rollback ok`) | looked at again, the **ledger first**: if that rollback did not restart the app although it had been (or failed to be) restarted onto the Valkey, restart it now — its process still runs on the Valkey env, RUNNING proves nothing (SBX 2026-10-20, app-028). Otherwise the stats: an instance down → restart (names were swapped at its last start); all up → skipped without a new ledger line; instances or app state unreadable → `rollback fail`, never a silent skip | none |
| `rollback fail`, `bind-valkey blocked`, `drift fail`, any other last line | the **ledger first** (2026-10-21 review): restarted (or failed to restart) onto the Valkey since the pair's last rollback **ok** ⇒ restart now — a rollback *fail* in between undid nothing, and RUNNING proves nothing (the process keeps the env of its last start); else the stats (an instance down ⇒ restart). The rebind looks for the **record of an earlier rebind that failed** (CF keeps it in state `failed` and refuses a second binding for the pair) and deletes it first; a binding still `in progress` is waited for (BIND_TIMEOUT), never adopted | none |
| data copied | nothing — the copy is additive; Redis stays authoritative until `confirm` | none |
| STANDBY | rebind Redis + restart (Redis still running) | same as above |
| **RETIRED** | **impossible** | — the reason `retire` needs `confirm` + grace + a second prompt |
| *(service)* names | **before** the app rows: Valkey `<name>` → `<name>-valkey-staged`, then Redis `<name>-redis-standby` → `<name>`, Blacksmith copies synced back; ledger `rename-valkey undone` / `rename-standby undone` (a failure: `rollback-names fail`, phase NAMES-STUCK, `rollback --service` again). A Valkey **purged before** the rollback (CF 404) is not a failure: the name is free, the create is voided (`create-valkey fail "purged before the rollback"`, so inventory/status say create-failed, `provision` creates again) and the Redis still goes back | none — CF renames reach no broker |

**Names are restored on every full-service rollback (decided 2026-10-20, SBX wave 6).** Apps
resolve their service by name in `VCAP_SERVICES`; a rolled-back service that keeps the swapped
names crashes every app of it that restarts later — and a multi-bound app is restarted by its
*other* service's step ("no credentials found"). The same undo runs when `apply` gives a service
up after its Redis took the standby name (drift, failed create/rename/copy). Only the `--app`
override keeps the names (the other apps still use the Valkey under `<name>`): an app rolled back
that way sits on `<name>-redis-standby`, so it must resolve its service by tag/offering, not name.

`dry-run` and `status` print the current row for every app, so "can we still go back?" always
has a factual answer.

## 4. Commands

| command | does |
|---|---|
| `plan <merged_report.csv>` | writes `waves.tsv`; **groups by connected component** of the binding graph (an app and every service it is bound to travel in one wave, so a multi-bound app restarts once) and reports services that span several teams (joint window needed); (`wave, service, redis_si_guid, valkey_plan, app, app_guid, flags`): services per wave (operator edits), apps per service (from the report), pipeline pairs kept in one wave, hazard apps flagged, data-store services flagged for copy; `--services <ERE>` scopes to our service names (the scan covers the whole foundation); connections whose `method` is not `cf-bind` (static-ref env/UPS, unknown) get `no-binding:<method>` — the app really consumes that Redis but there is nothing to rebind, so preflight/dry-run/apply list it as a **team action** and skip it |
| `provision --wave N` / `--waves A-B` | **2–3 days ahead (decided 2026-10-18):** creates the wave's Valkeys now under the staged name `<name>-valkey-staged` (same plan lookup, leftover rules and assert as a day-of create); Redis and apps untouched; writes `inventory.tsv` for the client's review — on every end of the run (EXIT trap), so a killed run leaves it current, followed by one counts line (`staged / cut-over / not-provisioned / create-failed / drift`). Re-runnable; a staged Valkey that vanished is recorded (`create-valkey fail` voids the earlier ok) and created again. The **ledger** is what a re-run continues from; the inventory is derived from it (`status` rewrites it any time) and is never read back. **One create at a time as Blacksmith sees it (2026-10-21):** CF answers a POST at once and calls the broker later from a job worker; Blacksmith writes its instance index (unlocked read-modify-write) inside `Provision`, before its 202, and CF moves the instance from `initial` to `in progress` on that 202 — so the next POST waits until the previous instance has left `initial` (`svc_create_accept`, seconds; ACCEPT_TIMEOUT 120 s). The builds still overlap: nothing waits for a deploy. Past the timeout, or after 3 listing errors in a row, no further create is issued in that run (`create-valkey fail "not issued: …"`); the issued ones are still waited for; a re-run creates the rest. The same path serves `apply`'s day-of creates |
| `provision-status [--wave N]` | the provision view of the ledger (no CF calls, safe while provision runs): per wave services / staged / cut-over / create-failed / not-provisioned / drift + TOTAL; `--wave N` lists each service with its state, staged Valkey guid and last note; closes with "N still without a usable valkey → provision again" or "all provisioned → provision-check" |
| `provision-check [--waves A-B]` | **read-only check after provision (asked 2026-10-19):** for every service of the plan (default all waves) reads the Redis AND its Valkey back from CF: same space GUID (so same org — the space's org is named in the report), same plan **name** under the `valkey` offering (compared with the Redis's live plan, not only the planned one), Valkey last operation succeeded, named `<name>-valkey-staged` (or `<name>` once renamed). No Valkey in the ledger / gone from CF = `MISSING` — and for the first case the staged name is looked up in the Redis's space, so an in-flight create of a killed run is named with its state (adopted by the next provision once succeeded; refused while in progress). Writes `provision-check.tsv` (one line per service: org, space, both plans, result, detail — names inside, stays in the env) and ends with the paste-out verdict `PROVISION-CHECK: OK (n of n ok: s staged, c cut-over; 0 missing, 0 mismatched, 0 api-errors)` or `FAIL`; exit 1 on FAIL; printed only after every service was walked (gate rule). Nothing written to the ledger. **BOSH half (2026-10-21, after the hollow Valkey):** CF's "succeeded" is only the broker's word, and Blacksmith says "succeeded" for an instance it has lost — so `bosh deployments --json` is read once through `BOSH_CMD` (env, or `BOSH_CMD=` in `runs/<env>/bosh.conf`; output to a file, never a pipe; under `timeout --foreground` only — the genesis wrapper runs bosh inside `script(1)`, and a plain `timeout` moves it out of the terminal's foreground process group where that raw-mode call stops it with SIGTTOU, seen as a 180 s freeze in SBX 2026-10-21; `BOSH_TIMEOUT`, default 180 s, rc 124 reported as "no answer within Ns") and every Valkey needs a deployment ending in its guid; a succeeded Valkey without one is `HOLLOW` (purge command in the detail — rollback first if it was cut over — counted in the verdict); a failed or empty listing, or one without any of the plan's **Redis** deployments (the wrong director: it would otherwise read as "all hollow"), is API-ERROR for every service (never a pass); no `BOSH_CMD` is refused unless `--no-bosh` (verdict then says NOT CHECKED). TSV column `bosh`: present / none / skipped / ?; column `checked_at` (UTC, start of the walk). **The file is merged, not overwritten (2026-10-21):** a run for `--wave N` replaces wave N's lines and keeps the others — `preflight` gates every wave on its lines |
| `preflight --wave N` | lock free · **not shared into other spaces** (CF refuses to rename a shared instance; the tool has no sharing flow — NP has 0) · **staged Valkey present under its name and plan; a staged instance the ledger does not know ⇒ FAIL, run `provision` again (adopts it)** · classic plan visible · **IP headroom = free IPs on the services network ≥ Valkeys to create in the wave (+ the whole plan for a project-level preflight)** · quota · every app running · no pending service operations · hazard apps' env fixed · pipeline pairs complete · **the hollow gate (2026-10-21):** every wave service with a Valkey in the ledger needs its `provision-check.tsv` line — same Valkey guid, result `OK`, `bosh=present`, `checked_at` not older than the create — else FAIL (`no line` / `MISSING…` / `bosh=skipped` from `--no-bosh` / `older than the create`); a service without a Valkey yet (day-of create) is a WARN. Consequence: **BOSH access is needed on cutover day too** — a resume of a day-of wave (STOP / Ctrl-C / breaker) needs a `provision-check` run after the creates before `apply` passes again → prints the **blast radius** (services / apps / teams) |
| `dry-run --wave N` | every command in order, with the rollback row after each |
| `apply --wave N` / `--waves A-B` [`--service Y`] [`--app X`] | executes (a range = a lane, sequential); idempotent via the ledger; `STOP` file honored between steps (also inside the services loop: issued creates are still waited for, names of services given up on go back); Ctrl-C finishes the current step, records it, exits. **Per app (2026-10-21 review):** a wave service given up on whose Redis still carries `-redis-standby` (its names-back failed: NAMES-STUCK) **blocks the app** — `bind-valkey blocked` under its other services, nothing bound or restarted (restarted, it would look for `<name>` and find nothing: the SBX wave-6 shape); `rollback --service` the stuck one, then `apply` redoes the app. The instance count is **never guessed** (unreadable ⇒ `drift fail`, app skipped: a 4-instance app would lose its rolling restart). A Valkey binding still `in progress` (bind of a killed run) is **waited for, never adopted**; past BIND_TIMEOUT only that app is left as it is (`bind-valkey fail "still in progress"`), the service goes on; the record of a bind that failed is deleted before binding again. A Redis found already under the standby name with no ledger line is recorded (`rename-standby ok "found already renamed"`), not refused |
| `status [--wave N]` / `watch` | the dashboard (§5) |
| `verify --wave N` | app health · connection census on the Valkey side (discovery worker) · `/check` for sim apps · key counts where data was copied · **"bound to Redis again?"** drift check |
| `rollback --app X` / `--service Y` / `--wave N` | per §3, reason recorded; **Ctrl-C is ignored** for the whole service rollback (a handler would keep the shell alive but still kill the `jq` between a CF call and its ledger line; a half rollback is worse than a slow one) |
| `confirm --service Y --by <team>` | app-team sign-off; starts the standby clock |
| `retire --service Y` | **before deleting: re-run the connection census on the standby Redis — refuse if anyone is still connected** (catches copied-credential apps that were never updated) · then: after the client's full confirmation, ~1–2 weeks post-cutover (standby grace default **14 days**); refuses before `confirm` + grace; asks twice; the only irreversible step |
| `name-sync --wave N` / `--waves A-B` | re-reads Blacksmith's copy of every renamed instance's name (§6d) through `SAFE_RUN` and sets the ones that differ — the "check after one reconciler cycle" step; `status` shows `name-sync pending: N` until it is 0 |
| `report --wave N` | evidence pack from the ledger (markdown): per app switched/verified/downtime, timeline, incidents, rollbacks, operators |

## 4a. Execution model — inside a wave, and lanes across waves

Inside a wave: **services phase** (rename → create → copy-data) issues every create at once and
waits for the jobs — a Valkey is a BOSH deploy (~5–10 min), serialising them buys nothing;
**apps phase** (bind → unbind → restart → verify) is **one app at a time** — the circuit
breaker (3 failed verifies in a row ⇒ stop the wave) and the per-service auto-rollback need a
sequential order to mean anything.

Across waves: **lanes**. `apply --waves 1-7` runs those waves back-to-back in one terminal; the
operator opens as many lanes as the window needs (NP: ~300 creates × ~7 min ÷ 4 lanes ≈ 9 h of
service creation, plus apps phases). Each wave takes its own lock when it starts (§1b); a failed
wave stops its lane only; `STOP` halts every lane at the next step boundary; `status` shows all
lanes. Start with the silent waves — creates + rebinds, no restarts. The rehearsal must confirm
how many concurrent Blacksmith provisions the lab tolerates (create one wave's services at once
in SBX, watch Blacksmith/BOSH), and set the lane count from that.

## 5. Dashboard — two levels

**Level 1 — project summary** (`migrate.sh status`, no arguments): one line per wave plus a
TOTAL line and a progress bar. Per wave: services / Valkey created / create-failed / on
standby / retired · connections / migrated (%) / verified (%) / failed / rolled-back /
in-progress / pending. "Connection" = one app↔service pair (a row of the plan) — the same unit
the discovery report uses, so the operator's "how far are we" is directly comparable to the
"how much is there" they started from.

**Level 2 — wave detail** (`status --wave N`): the per-service table below, plus an attention
list of failed/rolled-back apps.

**Derived snapshot files** (`runs/<env>/status/`, rewritten on every `status` run):
`summary.tsv`, `wave-N.tsv`, `failed.tsv`, `migrated.tsv`. They are **views, never inputs** —
the ledger stays the only source of truth — but they make the state readable without the
tool (Excel, a shared drive, a status mail) and survive a broken tool. Regenerate with one
command; never edit.

**Scale & robustness (measured):** a synthetic 800-connection plan with a **50,000-line
ledger** (≈20× a realistic ledger — 800 connections produce ~3k events; retries and rollbacks
maybe 10k) renders the project summary in **0.7 s** and a wave view in **0.65 s**, so `watch`
every 3 s is fine for the whole migration. The parser skips an unparsable line (the only
realistic corruption: a line truncated by a crash mid-write) and reports the count instead of
failing; the ledger is append-only text, so the backup policy is a copy per day (`cp`/rsync)
and the drift check against real CF state catches any step that ran but never got recorded.


`watch -n 3 -c migrate.sh status --wave 2` — one screen, rendered from the ledger:

```
wave 2  apps 11/11 running   3 teams   started 14:02   elapsed 00:17   STOP: no   lock: jsmith
service         plan     phase        apps  switched  verified  standby-until  last event
orders-cache    classic  VERIFYING     4     4/4       3/4       —              14:18:42 verify orders-api ok 210ms
session-store   classic  STANDBY       2     2/2       2/2       15:19          14:11:03 confirm by team-b
pay-queue       classic  ROLLED-BACK   3     0/3       —         —              14:15:30 rollback consumer: NOAUTH  !!
inv-cache       classic  PENDING       2     —         —         —
```

Suggested tmux layout: status (top) · `tail -f commands.log` (bottom-left) · sim poller
(bottom-right). Dependencies: bash, jq, column, tput — nothing else.

## 6. Restart semantics (small detail, big UX difference)

- **One restart per app per wave.** For an app bound to k services in the wave: bind all k
  Valkeys, unbind all k Redis, then restart once. The ledger still records one event per
  (service, app) step; the restart event is shared (same `ms`, note `shared restart`).

- ≥2 instances → `cf restart --strategy rolling`: the app never fully stops; the poller shows it.
- 1 instance → plain restart; the poller measures the gap. Both recorded with `ms`.
- **Soak timer** after restart before `verify` counts (default 30 s): lazy-reconnecting pools
  look broken for a moment and must not trigger a rollback.

## 6c. Placement, sharing and naming of the replacement Valkey

- **Same org + space as the Redis it replaces** — always. `plan` takes `redis_service_org` /
  `redis_service_space` from the report; `apply` targets that space for `create-service` and
  for every bind (an app can only bind a service instance in its own space or one shared into
  it).
- **Replicate sharing.** If the Redis was shared into other spaces (`cf curl
  /v3/service_instances/<guid>/relationships/shared_spaces` — the cross-space consumers in the
  report), share the Valkey into the same spaces before binding those apps.
- **Naming — DECIDED (client, 2026-10-01): rename-first.** Per service: `cf rename-service
  <name> <name>-redis-standby` (apps still bound and running) → `cf create-service valkey
  <plan> <name>` (the Valkey is born with the original name) → copy data if flagged → per app
  bind `<name>` / unbind `<name>-redis-standby` / restart → verify → standby → retire. Apps,
  manifests, pipelines and name-selecting code never see a different name; a stale `cf push`
  during the window lands on the Valkey (early, harmless for cache apps; data-store services
  are copied before any binding). A full-service rollback puts the names back (Valkey →
  `-valkey-staged`, Redis → `<name>`; revised 2026-10-20 after SBX wave 6 — see §3): apps find
  their service by name, so crossed names break the next restart. The earlier alternatives (create as `-valkey` + swap at
  the end; substituted names) are superseded.
- **Provisioned ahead (decided 2026-10-18): the staged name.** `provision` creates the Valkey
  days before the window as `<name>-valkey-staged` (ledger note `(staged`); on cutover day
  `apply` renames the Redis to the standby name and then the staged Valkey to `<name>`
  (`rename-valkey`). From that point the names are exactly the rename-first ones above, so
  rollback, confirm and retire are unchanged. Without a staged Valkey, `apply` creates under
  `<name>` as before (day-of fallback). `copy-data` stays on cutover day: a copy made days
  ahead would be stale.

## 6d. Blacksmith's copy of the name — `name-sync` (decided 2026-10-18)

Blacksmith stores `instance_name` at provision time and never learns of a CF rename (the
broker's `Update` is not implemented; `allow_context_updates` is off — `knowledge/blacksmith/
primer/broker-and-forges.md`). Its UI and listings read the per-instance copy at
`secret/<guid>:instance_name` in the broker's **own** Vault, reachable only on the broker VM.
Rule: **the tool writes that copy itself** after every rename (`rename-standby` ⇒
`secret/<redis>` = `<name>-redis-standby`; `rename-valkey` ⇒ `secret/<valkey>` = `<name>`):
- through `SAFE_RUN` from `runs/<env>/vault.conf` — any command that takes the safe command as
  its one argument; the shipped `migrate/example/safe-run.sh` takes the director connection from
  `genesis @env:blacksmith bosh --connect` (eval'ed inside the script's own process only) and
  calls `bosh -d <blacksmith deployment> ssh blacksmith/0 -c "export PATH=…/safe/bin
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$(sudo … creds); <cmd>"` directly, because `safe`
  on the VM is neither on PATH nor targeted and reads address and token from the environment
  (`safe/main.go:66,94`), and because the command cannot pass through `genesis … bosh ssh`:
  genesis before 2026-07-22 re-parses the bosh command inside single quotes, and every version
  rewrites `$NAME`/`$(` in arguments (`lib/Genesis.pm:677`) — bounded (`SAFE_TIMEOUT`, default 180 s) and Ctrl-C-shielded like
  the CF calls: **known-object check first** — `safe get` must return the name Blacksmith stored
  at provision (`<name>` for the Redis, `<name>-valkey-staged` for a staged Valkey) or already the
  new name; anything else means the wrong Vault is behind `SAFE_RUN` (or not this broker's
  instance) and **nothing is written** (`name-sync fail … pre-check`). Then `safe set …` and
  `safe get …`; **the read-back is the check**, not an exit code (ssh wrappers do not reliably
  pass it);
- recorded as `name-sync ok|fail|skipped` (service-level, never a phase: CF is the system of
  record for the name, the broker's copy is cosmetic); never fatal for the wave; `status`'s
  `name-sync pending: N` counts every rename in the ledger whose last `name-sync` is not ok —
  a rename with no sync event at all (crash, or a wave applied before this existed) is pending;
- every command is also appended to `runs/<env>/name-sync-wave-N.sh`, so without `vault.conf`
  (event `skipped`) the operator runs that file inside `genesis @env:blacksmith ssh`;
- the reconciler preserves an existing name but a set landing mid-cycle can be overwritten ⇒
  `name-sync --wave N` re-checks after one cycle. Long-term fix (backlog): implement
  `Broker.Update` + `allow_context_updates` in Blacksmith, then this step disappears.
- Verified live in SBX (2026-10-18): `safe-run.sh "safe get secret/<guid>:instance_name"` returns
  `blacksmith/<uuid>: stdout | <name>` (plus `stderr |` banner lines), i.e. `sudo` works under
  `bosh ssh -c`, the broker's Vault answers on `http://127.0.0.1:8200`, and the output shape is
  the one the tool parses (prefix stripped, exact value on a line).

## 6a. Ordering policy

Ordering between services is honored **only when a team declared it** (response-form Q3) and
only within one wave. Otherwise the default is **no ordering**: the tool binds, unbinds and
restarts each app once per wave, in any order. Teams that need a specific sequence and did not
declare it in time handle it themselves in their window (e.g. by scaling/stopping a consumer
first). This keeps the wave logic simple and puts the knowledge where it lives.

## 6b. Verification for REAL apps (no `/check`)

`/check` exists only on the sim apps. For client apps, `verify` uses platform-side evidence
only — nothing is installed in or required from the app. Levels, all recorded per connection:

| level | check | source | verdict it gives |
|---|---|---|---|
| L1 platform | binding is to the Valkey and **not** to the old Redis; all instances `running`; no crash events since the restart; health check passing | `cf curl` bindings, `/v3/processes/:guid/stats`, `cf events` | the migration steps *took* and the app came back |
| L2 network | the app's containers hold established connections **to the Valkey IP** and **none to the old Redis IP** after the soak | the discovery census worker on the Valkey VM + cell attribution (same code as the scanner) | the app actually *talks* to Valkey; a pinned address or stale pool shows up as a Redis connection |
| L3 server-side | on the Valkey: `CLIENT LIST` shows the app's cell IP with the expected user; `ACL LOG` has no auth failures from it; `INFO stats` rejected_connections unchanged | Valkey CLI (ACL is available on Valkey, unlike hardened Redis) | auth works — a password-only app on a `-secure` plan is caught here (`WRONGPASS` in `ACL LOG`) without touching the app |
| L4 app signal | recent app logs grep for `NOAUTH|WRONGPASS|ECONNREFUSED|timed out|redis` errors in the soak window; optionally a **team-declared health URL** (response form) returns 200 | `cf logs --recent`, HTTP | the app itself is not complaining |
| L5 data | where data was copied: `DBSIZE`/key counts Redis vs Valkey, sample-key reads | Redis + Valkey CLI | the copy is complete |

**verified** = L1–L3 pass. L4/L5 are usually unavailable for client apps and are optional extras, never gates. The team's `confirm` stays
the final human gate; verification is what lets us say "from the platform side it is good"
with evidence in the ledger (`note` carries the L2/L3 facts, e.g. `census: 2 conns on valkey,
0 on redis; ACL LOG clean`). The sim apps' `/check` is the stand-in for L4/L5 during rehearsal
and lets us prove L1–L3 detect what `/check` sees.

## 7. Accident matrix — designed for, then rehearsed (Phase 3, S3)

| accident | tool behaviour |
|---|---|
| verify fails (can't connect, WRONGPASS from a wrong plan, cold-cache latency misread) | **auto-rollback the whole SERVICE** (every app of that Redis already moved is rebound to it and restarted; apps not yet moved are skipped) — apps sharing a Redis may share data through it (queue, sessions, shared cache), so a partial rollback would split the group across two stores; the safe unit of rollback is the service, per-app rollback only as an explicit operator override (`--scope app`). Declared pipeline groups roll back as a group. Then (rebind Redis + restart, then *verify the rollback*: app connected to Redis again → `rollback-verified`); the app team sees a working app, the ledger sees an incident. The wave **continues** with other apps (they're independent) and the service is marked ATTENTION, never retired. **Circuit breaker:** 3 failures in a row ⇒ systemic (wrong plan family, broker down) ⇒ wave pauses for the operator |
| operator Ctrl-C / SSH drop mid-step | current step completes and is recorded; `apply` resumes from the ledger |
| CF API 429/5xx, broker bind timeout, Valkey create fails | bounded retries with backoff → app marked `blocked`, never skipped silently |
| team pipeline re-pushes during the window, rebinding old Redis | `verify` reports **drift** as an incident, not success |
| two operators | lock file with owner+time; second gets a clear refusal (`--steal` exists, logged) |
| standby grace elapsed, no confirm | listed on the dashboard; **never** auto-retired |
| hazard app (pinned env) in the wave | `preflight` refuses until the env var is gone; the tool never edits app env |
| data-store service, copy verification fails | app stays on Redis; service marked `copy-failed`; nothing cut over |
| wrong plan family (secure instead of classic) | `preflight` checks the plan's credential shape (no `credential_type: dynamic` unless the wave says secure) |
