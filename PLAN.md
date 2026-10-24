# Redis → Valkey migration simulation — plan & progress tracker

Living checklist. Tick items as they complete; add a dated line under **Log** when a phase
changes state. Design decisions go in **Decisions**; unknowns in **Open questions**.

Environment: client SBX foundation. Everything rehearsed here is what the real NP/PD
migration will run.

Legend: `[ ]` todo · `[x]` done · `[~]` in progress · `[-]` dropped

---

## Phase 0 — prerequisites (nothing meaningful can be rehearsed without these)

- [ ] `-classic` Valkey plans available in SBX (valkey-forge `feature/classic-credential-plans-v1.1` → v1.1.1 deployed)
- [ ] patched broker in SBX (blacksmith `fix/classic-plan-unbind` → dev release or v1.3.1) — classic-plan unbind works
- [ ] SBX marketplace shows both plan families (`cache-* → -classic`, `cache-*-secure → ACL`) via kit `params.valkey_plans`
- [ ] SBX broker validation trio: classic unbind = no-op ✓ · secure unbind revokes user ✓ · secure binding creds carry no `admin_password`/`service_type` ✓
- [ ] quota check: SBX org can hold ~25 apps × 2–3 instances + ~10 Redis + ~10 Valkey services
- [ ] a Windows stack available in SBX (for `sim-win-*`)

## Phase 1 — test apps + verifier + baseline

**1a. The `/check` contract (the interface everything else builds on)**
- [x] spec written: `CHECK-CONTRACT.md` — fields, per-mode `mode_data`, pass criteria, env config
- [x] pass criteria per usage mode defined (cache / session / store / producer / consumer / lock)

**1b. The Python probe app (`apps/sim-py`, Flask + redis-py)**
- [x] usage modes: `SIM_MODE=cache|session|store|producer|consumer|lock` — all six smoke-tested locally (fakeredis)
- [x] credential sources: `SIM_SOURCE=vcap|env|ups` (`SIM_SERVICE_NAME` selects a binding for multi-bind apps)
- [ ] service-key runner script (`sim-keyuser`)
- [x] auth styles: `SIM_AUTH=password|username`
- [x] self-generated ground truth: deterministic dataset + checksum (store), Redis-counter sequence with gap/duplicate detection (consumer), deterministic session token (session), per-window lock + per-instance run log (lock), canary key at first start
- [x] command-family smoke in `/check` (string, hash, list, zset, eval, multi, stream, pubsub)
- [x] manifests: `manifests/core.yml` (6 usage apps) + `manifests/access-variants.yml` (pinned, static-env, ups, password-only, username-aware, pipeline a/b); `scripts/create-services.sh`
- [-] sim-py deployment: SBX has only the ONLINE python buildpack (downloads the runtime at staging; air-gapped -> fails). Kept as reference only.
- [x] **`apps/sim-go`**: Go port of the probe (same contract + `SIM_TLS`), static binaries `bin/sim-linux` + `bin/sim-windows.exe`, `binary_buildpack` (no downloads); all six modes pass against miniredis; manifests core/access-variants/windows/tls
- [x] deployed to SBX (2026-09-30): six core apps, `/check` green against real Redis — `server=redis`, connected, `auth_user=n/a` (ACL renamed on hardened Redis); credentials carry per-instance BOSH DNS hostnames, not IPs

**1c. Real-stack apps**
- [ ] `apps/sim-spring` — Spring Boot + Spring Data Redis (Lettuce); `spring.redis.username` handling; optional Spring Cloud Config Server wiring (hidden-config case)
- [x] `apps/sim-win` → covered by `sim-go/bin/sim-windows.exe` (`manifests/windows.yml`); a .NET/StackExchange.Redis variant stays optional for client-stack fidelity
- [ ] both implement the same `/check` contract

**1d. The verifier (`verify/`)**
- [x] `verify/poll.sh`: polls every app's `/check` every N s → timeline JSONL (`verify/data/`)
- [x] `verify/apps-list.sh`: builds `apps.txt` (sim-* apps → routes) from the cf target
- [ ] expectation tables per scenario (what each app MUST report after each step)
- [x] `verify/snapshot.sh [label]`: one-shot capture of all `/check` (the baseline tool)
- [ ] diff/report: switched? functional? data intact? downtime seconds? errors/reconnects? latency p50/p99 vs baseline?
- [ ] **baseline captured** for the Phase-2 population (this is the "before")

**The app matrix (one app per migration risk)**

| app | access | usage | proves | status |
|---|---|---|---|---|
| `sim-cache-bound` | cf-bind | cache | happy path: endpoint switch, `server=valkey`, cache refills | [x] up in SBX |
| `sim-session-bound` | cf-bind | session | session continuity (or clean re-login) across cutover | [x] up in SBX |
| `sim-store-bound` | cf-bind | store | data-copy correctness via checksum | [x] up in SBX |
| `sim-producer` / `sim-consumer` | cf-bind (same Redis) | queue | gapless sequence: lost/duplicated messages counted | [x] up in SBX |
| `sim-lock` | cf-bind | lock | double-execution count during switch | [x] up in SBX |
| `sim-bound-pinned` | cf-bind + pinned `REDIS_HOST` | cache | THE hazard: still reports the OLD endpoint after migration | [x] up in SBX |
| `sim-static-env` | env var only | cache | manual-update path | [x] up in SBX |
| `sim-ups` | user-provided service | cache | UPS update + restage path | [x] up in SBX |
| `sim-keyuser` | service key (task/script) | — | keys don't migrate | [ ] |
| `sim-password-only` | cf-bind, `AUTH <pw>` | cache | classic OK / secure WRONGPASS — the plan-decision evidence | [x] up in SBX |
| `sim-username-aware` | cf-bind, uses `username` | cache | secure opt-in path, `auth_user` = binding id | [x] up in SBX |
| `sim-pipeline` | bound to Redis A **and** B, moves data A→B | store | ordering: breaks if A/B migrate in wrong order | [x] up in SBX |
| `sim-batch` | cf-bind, connects on schedule (CF task) | store | idle ≠ exempt: first reconnect lands on Valkey | [ ] |
| `sim-spring-*` | cf-bind | cache + session | real Java stack | [ ] |
| `sim-win-bound` | cf-bind, Windows | cache | same story on Windows | [x] up in SBX |
| `sim-tls-bound` | cf-bind, connects on `tls_port` (16379) | cache | TLS consumers: Valkey target must be a TLS plan + cert trusted (found in NP: a real app uses 16379) | [ ] |

## Phase 2 — the tool-test population (SBX, 6 Redis; the tool creates the Valkeys)

- [x] `scripts/layout.tsv` + `scripts/reset-population.sh` (2026-10-02): rebinds the existing 14 apps into the shapes the real plan showed — a 5-app shared service incl. the hazard app and Windows, the queue group, a 2-service/2-app chain (multi-bound app → one restart), a SILENT service (bound app stopped), a data-store service (`datastore` flag by hand in waves.tsv); unbinds everything, deletes the Valkey twins (frees IPs), renames standbys back. Re-runnable after every tool test.
- [x] run reset → discovery scan of SBX → `plan --wave-size 3 --services '^sim-redis-'` → waves cover every tool path (2026-10-07; first plan revealed foreign SBX services + non-binding consumers → `--services` filter and `no-binding:<method>` flag added)

(The earlier ~100-connection population idea moves to the lab; SBX stays at 6 Redis.)

- [ ] target shape mirrors the real findings: ~all cf-bind · a handful pinned hazards · ~⅓ idle · a couple Windows · zero pure static-ref in the "normal" set
- [ ] ~10 Redis services (mix of plans), ~25 apps, 2–3 instances each, small pools → 100–150 connections
- [ ] some apps bound to multiple services; some services with multiple apps
- [ ] `sim-batch` scheduled so it is idle during most scans
- [ ] discovery toolkit run against SBX → `merged_report` shows the intended shape (also validates the toolkit once more)
- [ ] verifier baseline captured (Phase 1d last item)

## Phase 3 — migration tool: operator layer first (see `migrate/DESIGN.md`)

**3a. Design & ledger**
- [x] `migrate/DESIGN.md`: ledger (append-only `ledger.jsonl`, state = last event), per-app state machine, rollback-per-step table, commands, dashboard, restart semantics, accident matrix
- [x] ledger schema frozen (`ts, wave, service, app, step, outcome, ms, op, note`; app="" = service-level); `ledger_states` jq = the one state rule; plan file = `waves.tsv`
- [~] identity by GUID (DESIGN §1a): ledger `service` = GUID, status shows name (guid-prefix), `rename-standby` event in the sample ledger — DONE; name→GUID assertion before every cf action — with `apply`

**3b. The CLI (`migrate/migrate.sh`) — in this order**
- [ ] `plan` → `waves.yml` from the merged report (pipeline pairs together, hazards + data-store flagged)
- [x] `status` = project summary (per wave + TOTAL, %, progress bar) + snapshot files; `status --wave N` = wave detail; corruption-tolerant parser; 50k-line ledger renders in 0.7 s (measured)
- [x] (was:) `status` dashboard working on `migrate/example/` (phases, switched/verified, standby clock, last event, attention list, hazard warning); `watch -n 3 -c migrate.sh status --wave N`
- [x] `preflight --wave N`: lock/STOP/ledger · cf session · per service: guid↔name reconciliation with the ledger (drift), last_operation, standby/valkey name collisions, valkey plan visible in the space, secure-plan warning · per app: exists, STARTED, all instances running, hazard env var still present → FAIL · blast radius · `--free-ips N` headroom; exit 1 on any FAIL. Offline-tested with `migrate/test/cf-stub`
- [x] `dry-run --wave N`: exact command sequence in the rehearsed order (per service: rename, create under original name, copy if flagged; per app: bind all, unbind all standby, ONE restart, verify), DONE marks from the ledger, rollback row per step
- [ ] `apply` — idempotent, ledger-driven, STOP file, Ctrl-C safe, rolling restart for ≥2 instances, soak timer
- [ ] `verify` — L1 platform (bindings, running, crashes) · L2 network (census on Valkey: conns to Valkey, none to Redis) · L3 server-side (CLIENT LIST / ACL LOG on Valkey) · L4 logs + optional team health URL · L5 data counts; `/check` only for sim apps (DESIGN §6b)
- [x] `rollback --wave N --service Y [--app X]` per the table (service unit; app override recorded; re-apply redoes the pair after a rollback)
- [x] `confirm` / `retire` (confirm needs every tool app VERIFIED; retire needs confirm + grace, name unchanged, zero bindings/keys, census hook or `--no-census`, double prompt)
- [ ] `report --wave N` evidence pack
- [ ] data copy for store-mode services (RDB snapshot / brief sync) + key-count verification
- [x] rollback scope = service (auto-rollback re-binds every moved app of the service); `--app` override
- [ ] preflight: Valkey plan `persistent` parity with the Redis plan
- [ ] handles pinned-env apps (refuse in preflight), UPS, service keys (new key), multi-instance, Windows, TLS consumers (TLS plan + cert trust)

**3c. Scenarios (SBX, 6 Redis + 6 Valkey, waves of two)**
- [x] S1 core theory validated in SBX (2026-09-30 → 10-01): cache service + all access variants; queue group (split → starvation, group move OK); store no-copy reset vs rollback intact; name-selected binding crash under policy B. Remaining blocks are evidence-gathering, not theory.
- [ ] S2 rollback: one wave back to Redis — prove "minutes", data intact on standby
- [ ] S3 **accident drill**: every row of the accident matrix, with client devops on the call
- [x] S4 secure-plan variant: `sim-password-only` on a `-secure` twin → WRONGPASS evidence captured (2026-10-01)
- [ ] S5 pipeline ordering: wrong order once (prove the break), then correct
- [ ] S6 TLS consumer onto a TLS-enabled Valkey plan (optional)
- [x] S7-7 Blacksmith view after rename: stale (shows original name) → blacksmith backlog item
- [x] S7 rename-first sequence validated on the cache service (2026-10-02): rename Redis → standby with apps bound, Valkey under the original name, apps migrated against it, UNCHANGED manifest push binds the Valkey, rollback under the new names. (was:) S7 name swap (policy A, decided): rename Redis → `-redis-standby`, Valkey → original name; then `cf push` an app with its ORIGINAL manifest (`services: [<name>]`) and prove it binds the Valkey, not the Redis

## Phase 3.5 — the migration-specific plan from the REAL report (before any real wave)

Input: the merged (aggregated) report of the client's most complex env — available now.
Pure file processing (runs in the VDI; only aggregates leave). Output = the real `waves.tsv`
plus a review document for the client, built from the binding graph:

- [ ] **run:** `git pull && bash migrate/migrate.sh plan <aggregated_or_merged_report.csv> --run runs/<env> --wave-size 10` in the VDI; paste `runs/<env>/plan-summary.md` (no names) for joint review
- [x] **first real run (int-np, single-day merged report, 2026-10-02):** 826 connections / 274 services / 750 apps / 41 orgs; 239 components — 136 islands, 82 single-service shared, 14 of 2–3 services, 7 of 4–10 (largest 4 svcs/3 apps); 62 multi-bound apps; 0 cross-space; 15 hazards; 17 windows; 119 services with no live consumer (one scan); apps-per-service: 136×1, 101×2–5, 33×6–20, 4×21–50. Plan (10 svcs / 40 restarts, easy-first): 36 waves — 1–12 silent (119 svcs), 13–23 live islands + small shared, 24–32 the big shared services one per wave (21–38 restarts, 1–2 orgs), 33–36 multi-service chains.
- [ ] **the REAL plan is generated from the freshest aggregated report right before the NP migration** (the estate churns; a plan built early goes stale). Pre-migration checklist item: re-scan → aggregate → `plan` → review summary → edit waves.tsv → go. The 2026-10-02 run was for shape/sizing only.
- [ ] `--silent-max-apps` (bigger cap for silent waves → 2–3 waves instead of 12)
- [ ] weekend mapping: Fri evening = silent block (tooling at scale, no audience); Sat = live islands/small shared; Sun = big shared services + chains, one at a time, dashboard watched
- [ ] connected components of the app↔service graph: size distribution (how many 1-app/1-service islands vs large components), the largest components named by service count
- [ ] multi-bound apps (bound to 2+ Redis): count; each must migrate in ONE wave (restart once)
- [ ] shared services across spaces/orgs: list → joint windows / sharing to replicate on the Valkey
- [ ] hazard apps (cf-bind + static_ref) per component → preflight blockers, contact list
- [ ] TLS consumers (port 16379 in census) → TLS-enabled Valkey plan per affected service
- [ ] data-store candidates: services whose apps declared "data store" on the form (else default: no copy) + persistence parity (Redis plan `persistent` ↔ Valkey plan)
- [ ] idle-only services (never live across scans) and unused services (no consumers) → migrate-by-rebind-only vs decommission list
- [ ] wave proposal: components grouped by size/team, ~N services per wave; pipeline groups (if any declared) kept together
- [ ] IP headroom per wave vs free IPs on the services network
- [ ] review session with client devops: adjust `waves.tsv` by hand (the tool reads the edited file)

## Phase 4 — verification & report

- [ ] run verifier after each scenario; produce `report/<scenario>.md`
- [ ] report sections: per-app switched/functional/data (pass/fail) · downtime per app · lost/duplicate messages · double executions · latency before/after · what the pinned/UPS/key apps did (expected failures shown as expected)
- [ ] report is the template for the real migration's evidence pack
- [ ] findings folded back into: migration script fixes · academy deck (real numbers) · `knowledge/migration/`

---

## Decisions
- 2026-10-18 — **Scaled rehearsal runs in the client's SBX, 20 pairs** (supersedes 2026-09-27 "idle subnet not pursued" and 2026-10-14/18 "our lab"). Capacity: the idle AWS subnet `10.139.131.64/26` (z3) was added to the cf network as `ocfp-3` in the Vault inventory (`net.subnets/ocfp-3`: az, cidr_block, cidr_prefix, dns, gateway, id, ip_0, ip_n) + `genesis @sbx-us:cf deploy` (cloud config uploaded, manifest deploy skipped); two subnet entries with the same AZ are one BOSH pool. Both Redis and Valkey standalone plans steered to z3 (`azs:`), blacksmith redeployed, a probe landed in z3 (old subnet first; the new one fills when its 12 are gone). `free-ips.sh`: 82 free of 153 (z1 3, z2 9, z3 70). Size: 20 pairs / ~120 apps, `--shape np` (10×1, 7×2–5, 2×6–20, 1×25 apps per service; 43% silent; 3 chains), `--wave-size 4 --max-apps 40`, two lanes, **two spaces in two orgs** (`populate.sh --org/--space`, prefixes scla/sclb), no sharing. Proves the tool and the runbook, not the clock: NP's wall-clock is extrapolated from the per-service/per-app timings.
- 2026-10-19 — **SBX populated: 2 orgs × (10 Redis + 60 apps)**; Redis create ≈ 50–60 s each with 8 concurrent (8 in 406 s), app push ≈ 4 s each 8-wide. Three things bit on the way, all fixed in `populate.sh`: the per-chunk `CF_HOME` copy must be `<dir>/.cf` (cf reads `$CF_HOME/.cf/config.json`); the old sim org's quota (fresh orgs for both populations); Diego **allocation** full for staging (1 GB + 4 GB disk per concurrent push) although cells were at ~40% real use → an app counts as pushed only with a STAGED droplet, `--parallel 3`, and **two temporary diego-cells (`params.diego_cell_instances: 7`, was 5) — to be set back at teardown**. The bastion auto-logs-out idle sessions: long runs go in `tmux`.
- 2026-10-19 — **Layout rule fixed before `plan`:** the merged report showed every multi-bound app on `*-redis-10` = the stopped (silent) service, so no running app was bound to two Redis and redis-01…06+10 formed one 7-service component (one oversized wave instead of 5–6). `populate.sh` now makes every **7th** app multi-bound to its pair neighbour (never the last service): 8 started multi-bound apps per org, components of 2–4 services; `--layout-only` + `scripts/test/case-layout.sh` prove the classes for the N actually used. 14 apps per org re-pushed (007…056 gain, 010…060 lose the second binding); Redis untouched.
- 2026-10-19 — **Provision report / resume / check (asked before the SBX provision):** (1) the report is `inventory.tsv` (now with `org`/`space`), written on every end of `provision` (EXIT trap) plus a counts line, and rewritten by `status`; (2) a re-run continues from the **ledger** — the inventory is a derived view, never read back; (3) new read-only `provision-check`: reads every Redis and Valkey back from CF, same space/org, same plan NAME (Redis's live plan), last op succeeded, expected name; `MISSING`/`MISMATCH`/`API-ERROR` per service, `provision-check.tsv`, verdict `PROVISION-CHECK: OK|FAIL` after the full walk. Offline cases J1–J6 (fake got `/v3/service_plans/<g>?include=service_offering`, `/v3/spaces/<g>`, `/v3/organizations/<g>`, `CFFAKE_WRONG=<name>:space|plan`). Review found: a failed org GET poisoned the space cache (next service crashed the walk under `set -u`) → cache written only when space+org are known; verdict says `n of n ok: s staged, c cut-over`; MISSING looks the staged name up in the space (in-flight create of a killed run named with its state; the first re-run refuses it while in progress, the next adopts it — runbook says wait). Cases J6b–d, J7–J9 (fake: `CFFAKE_NO_INCLUDED`, `CFFAKE_FINISH_JOBS`). Not yet verified live: the `include=service_offering` shape (a wrong shape shows as 20 API-ERRORs, never as a pass).
- 2026-10-20 — **SBX provision: 19 of 20 first pass; 1 create failed `address already in use`** (`10.139.131.85`, new z3 subnet): a Transit Gateway attachment ENI, invisible to BOSH and to `free-ips.sh`. Reserved in the Vault OCFP config (explicit `reserved_*` keys must repeat the defaults `.64–.68`, `.127` — the first attempt would have unreserved them; caught by `bosh-configs compare`), cloud-config uploaded without a cf deploy, `provision --wave 2` re-created. Knowledge: `genesis-kits/ocfp-transit-gateway-ip-not-reserved.md`. More non-BOSH ENIs (ELB, RDS, endpoints) in the same subnet caused two more failures → the whole non-BOSH range reserved; then 20/20 staged, `provision-check` OK. Each collision costs ~9 min of CPI retries. **NP pre-check added:** TGW/endpoint/ELB/RDS ENIs per subnet vs `ocfp show network --reserved`.
- 2026-10-18 — **Valkeys are provisioned 2–3 days ahead** (`migrate.sh provision --waves A-B`): created under the staged name `<name>-valkey-staged`; `runs/<env>/inventory.tsv` (app, Redis, Valkey, names, guids, state) is what the client reviews before the window; on cutover day `apply` renames Redis → standby, then the staged Valkey → `<name>` (`rename-valkey`), then the apps as before. Day-of create stays as the fallback. `copy-data` stays on cutover day. DESIGN §6c.
- 2026-10-18 — **The tool sets Blacksmith's copy of the name itself** (supersedes the 2026-10-14 "operator step"): after every rename, `safe set secret/<guid> instance_name=<new name>` + read-back, through `SAFE_RUN` in `runs/<env>/vault.conf` (e.g. `genesis @sbx-us:blacksmith bosh ssh blacksmith/0 -c`); path is `secret/<guid>` in Blacksmith's **own** Vault (not `secret/blacksmith/<guid>`, not the env Vault), reachable only on the broker VM. Ledger `name-sync ok|fail|skipped` — cosmetic, never a phase; `status` footer until 0; `name-sync --wave N` re-checks after one reconciler cycle. Without `vault.conf` the commands wait in `name-sync-wave-N.sh`. **Verified live 2026-10-18** with `migrate/example/safe-run.sh` (connection from `genesis … bosh --connect` scoped to the script, `bosh -d … ssh <group/uuid> -c`, token via `sudo` from the creds file): output `blacksmith/<uuid>: stdout | <name>`. Three layers had to be worked around on the client bastion: genesis's pre-2026-07 single-quote wrapper, genesis's `$` rewriting of bosh arguments, and the instance not matching `blacksmith/0`. DESIGN §6d.
- 2026-10-18 — **Shared service instances are refused in preflight** (`relationships/shared_spaces` non-empty): CF refuses to rename a shared instance and the tool has no sharing flow. NP's plan has 0 cross-space services (plan-summary line "services used across spaces/orgs"), so no flow is built; a shared one is handled by hand.
- 2026-10-14 — **Blacksmith's stale instance name after `cf rename-service`** (path corrected 2026-10-18: `secret/<guid>`, broker VM; the tool runs the step now — see above) (verified with the blacksmith agent at `ac99f1d6`): the name operators see is the per-instance root `secret/blacksmith/<guid>` `instance_name` (UI overrides the index with it); nothing functional keys on it. **Migration window: no Blacksmith release, the tool stays cf-only**; an *operator* step after each rename: `safe set secret/blacksmith/<old-redis-guid> instance_name=<name>-redis-standby`, check after one reconciler cycle (a set landing mid-cycle is overwritten with the value read at cycle start), set back on rollback. Never edit the `db` index by hand. **After the migration**: implement `Broker.Update` for context-only requests, then advertise `allow_context_updates: true` (never the flag alone — CF would fail every rename). Details in `knowledge/blacksmith/primer/broker-and-forges.md`.
- 2026-10-14/18 — **z1 is the IP limit, not the total** (SBX: 27 free, z1 4): the forge standalone plans pin `meta.default.azs: [z1]` (clusters `[z1, z2]`), so every standalone Redis/Valkey lands in z1 and BOSH never falls back to another AZ. Lever (kit param, verified in source 2026-10-18): `params.valkey_plans.standalone.azs: [z3]` → redeploy blacksmith; existing instances keep their AZ. Decided: try it in SBX (it is the NP/PROD lever too) → ~10 new pairs (Redis→z2, Valkey→z3) + the 6 existing; the 20-pair throughput rehearsal runs in our own lab; the client's lab only for the Phase 3.5 run from the real report. `free-ips.sh` to report per-AZ NEED against the plan's first AZ; preflight to gate on it. *(Rehearsal location superseded 2026-10-18: SBX with the `ocfp-3` subnet.)*
- **2026-10-08 — `apply` built and exercised against a stateful fake CF** (happy path, STOPPED app, failed provision → leftover deleted and re-created, mid-wave crash → resume, restart/verify failure → service auto-rollback, rolling restart, lock refusal, STOP file, lane `--waves A-B`). Not yet: per-worker `CF_HOME` copy + UAA refresh-rotation check (needed only for parallel lanes), `report`, L2/L3 in `verify`.
- 2026-10-11 — **`migrate/free-ips.sh`** (cloud-config pool − reserved − static − `bosh instances` IPs, per subnet; `--plan` = services still to create; preflight reads `free-ips.txt` minus creates since, FAILs if unreadable; `apply` now requires the `PREFLIGHT: OK` verdict line). First change under `skills/logic-delta-review`: the review found 11 issues incl. a gawk/mawk-fatal construct and a fail-open crash — all fixed before commit. Decided: Valkeys are provisioned into the **cf network** (shared with CF growth) → run free-ips right before provisioning, not once.
- 2026-10-09 — **`confirm` and `retire` are kept but not part of the operator flow** (preflight → dry-run → apply → status, + rollback when needed). Retirement only when the client asks; then `confirm --by … --grace 0h` + `retire` is the whole procedure.
- **2026-10-09 — SBX waves 1–3 applied for real through the tool** (6 Valkeys, 13/15 tool connections verified, store parked on the datastore answer, 2 apps to the team; 3 concurrent Blacksmith provisions fine, ~3 min). `rollback`/`confirm`/`retire` built and exercised offline (rollback → re-apply → confirm → retire; retire refusals: not confirmed, grace, no census, after retire). `status` counts team-action apps apart (`N+T`).
- **2026-10-08 — no `cf target`, parallel waves (DESIGN §1b).** NP's services/apps span ~40 orgs and waves run concurrently; `apply` drives the v3 API by GUID (rename/create/bind/unbind/restart/jobs), one admin login, per-worker `CF_HOME` copies only to keep token refreshes from racing, per-wave locks. `dry-run` now prints the API calls (CLI equivalents as comments).

- 2026-10-02 — **Team-side changes under policy A are exactly three, all optional-until-needed or already named:** (1) pipelines that CREATE the service: `cf create-service redis …` → `valkey` (create-if-missing pipelines are unaffected; unconditional ones fail loudly with "name already in use"; `disable-service-access redis` flushes out the rest); (2) code selecting the binding by VCAP label `redis` — a code change unless the Valkey offering carries a `redis` tag (platform lever: settle before the academy); (3) the ~20 pinned addresses. Bind commands, manifests, service names, restarts: untouched.

- 2026-10-01 — **State reset is a known experience for the app teams**: three years of Redis stemcell/release upgrades recreated the service VMs and teams were fine. Pending one check (are the plans `persistent`? → AOF on persistent disk survives recreation), this either (a) proves tolerance of full state reset → data copy becomes opt-in only, academy line "same event as the upgrades you've been through", or (b) proves restart tolerance only → keep the "flag real data" ask. **Parity rule either way:** the Valkey plan's `persistent` must match the Redis plan it replaces (preflight check).

- 2026-10-03 — **Retirement happens** ~1–2 weeks after full confirmation (grace default 14 d), never automatically. **IP headroom is a preflight check**, not an assumption. **Rollback unit = the service** (all its apps; pipeline groups together); per-app only as explicit override.
- 2026-10-01 — **Naming DECIDED by the client: policy A — rename swap.** Valkey created as `<name>-valkey`, then Redis → `<name>-redis-standby`, Valkey → `<name>` (before the app restart, so name-selecting apps work unchanged). Teams with hard-coded names in pipelines fix them manually. S7 tests it. (Superseded: 2026-10-03 preference B)
- 2026-10-03 — Valkey naming (superseded): **preference = (B) substituted names** (`redis`→`valkey`, case-preserving; `-valkey` suffix when the name has no "redis"), pending the client's decision. Teams update manifests/pipelines at their own pace during the standby weeks; the old Redis is renamed `<name>-redis-standby` at cutover so a stale manifest fails loudly ("service instance not found") instead of silently re-binding it. Consequences owned: 6th academy ask ("update the service name in your manifest"), and a periodic drift scan during standby (apps bound back to a `-redis-standby` service).

- 2026-10-02 — **Weekend maintenance window, not per-team windows.** Teams are informed; they deal with their apps' restart inside it. Waves are grouped technically (connected components, size), not by team scheduling.
- 2026-10-02 — **Replacement Valkey in the same org+space as the Redis**, sharing replicated, created as `<name>-valkey`, then **name-swapped** after verification (Redis → `<name>-redis-standby`, Valkey → `<name>`) so team manifests/pipelines resolve to the Valkey. Validate the swap in SBX.
- 2026-10-02 — **No retiring** unless explicitly asked; old Redis stays on standby. Verification gate = L1–L3 only (L4/L5 optional).

- 2026-10-01 — **No ordering by default.** Ordering honored only when a team declared it on the form, within one wave; otherwise restart once per app per wave in any order — undeclared ordering needs are the team's to handle in their window.
- 2026-10-01 — **Real-app verification is platform-side only** (L1 bindings/health, L2 connection census on the Valkey VM, L3 CLIENT LIST/ACL LOG on Valkey, L4 logs/health URL, L5 data counts); `/check` is sim-only.

- 2026-10-01 — **Migration is a per-service substitution; the binding graph is preserved automatically** (each Redis → exactly one Valkey, every (app,Redis) → (app,Valkey)). Graph still matters operationally: waves built from connected components so a multi-bound app restarts once; cross-team shared services need a joint window; verify per app over all its connections.

- 2026-09-20 — steps agreed: 0 prereqs → 1 apps+verifier+baseline → 2 population → 3 script+scenarios → 4 verify+report. Verifier is built with the apps (baseline before migration), not after.
- 2026-09-20 — scale via instances + pools (~25 apps → 100+ connections), not 100 distinct apps; population mirrors real proportions.
- 2026-09-20 — usage pattern = a mode of one Python probe (all cf-bind); access-pattern variants only in cache mode; Spring + .NET for real-stack fidelity.
- 2026-09-20 — migration waves bind `-classic` plans (no app code change); `-secure` is an explicit scenario (S4), not the default.
- 2026-09-27 — **SBX = functional rehearsal at 6 Redis + 6 Valkey (12 service IPs)**; scenarios recycle IPs by retiring after standby; **lab = scale rehearsal** (API limits, director load, wave parallelism). Attaching the idle subnet to the -ocf network is NOT pursued (cloud-config + routing + CF ASG work for capacity the lab gives free).
- 2026-09-28 — **auto-rollback per app is the default** (app stays working on Redis; incident recorded; wave continues; 3-in-a-row circuit breaker pauses the wave). Status has two levels (project summary / wave detail) + derived snapshot TSVs; ledger stays the only source of truth.
- 2026-09-28 — **operator layer is the product**: ledger-driven CLI, terminal dashboard (`watch`), per-step rollback, accident drill — before any scale. No new UI.

- **2026-10-20 (SBX waves 1–6, two lanes): a hollow Valkey and the rollback that broke its neighbours.**
  Waves 1–5: 115 of 115 connections verified, 0 failed. Wave 6 (3 chained services 07–08–09): 09's
  Valkey was *hollow* — CF said `create succeeded`, Blacksmith's index had no entry, BOSH had no
  deployment, no BOSH task ever existed. Cause (verified in `blacksmith/internal/broker`):
  `Vault.Index()` is an unlocked read-modify-write of the whole index; 4 concurrent creates right
  after a leftover delete lost 09's line; `LastOperation()` answers "succeeded, instance deleted" for
  an instance missing from the index (`broker.go:481`), so CF recorded a success. `provision-check`
  asks CF only, so it passed. Bind then failed "deployment not found"; the tool rolled 09 back but
  left the names swapped; app-049 (bound 09+08) was restarted by 08's step and crashed ("no
  credentials found", by-name lookup); 08 rolled back the same way and broke app-028 (08+07); lane B
  stopped after 3 failures. Decisions: (1) **rollback restores names** (`rollback_names`, ledger
  outcome `undone`, failures under `rollback-names`, phase NAMES-STUCK; `apply` undoes a service it
  gives up after the standby rename; `--app` override keeps names) — commit below; (2) **`provision`
  must serialize what Blacksmith sees** (POST, wait until `last_operation.state` leaves `initial`,
  next) and wait for a leftover's delete job; (3) **`provision-check` must ask BOSH** for the
  deployment (`BOSH_RUN` like `SAFE_RUN`) — (2)+(3) are the next delta; (4) a hollow instance is
  removed with `cf curl -X DELETE /v3/service_instances/<g>?purge=true` (no broker call), then
  `provision --wave N` creates it again. Blacksmith backlog: lock the index write; never answer
  "succeeded" for a create whose line is missing. Review round (fresh agent) found 11 items, all
  addressed or recorded (finding 9, in-progress bindings count as present, left as is).
  **Repair run 2026-10-21 01:56–02:50 UTC, through the tool after `b4715f8`:** `case-rollback.sh`
  ALL PASS on the bastion; `rollback --wave 6 --service` 07, 08, 09 in that order — each restored
  both names + synced Blacksmith's copies, restarted only the apps whose last recorded step was on
  the Valkey (07: 3 of 7, 08: 1 of 8); 09's run reported the one expected failure (app-019's
  binding to the hollow Valkey, "deployment not found") with the purge command. Purge, `provision
  --wave 6` (one create, alone), BOSH deployment grep by guid (present), `provision-check`, `apply
  --wave 6` → **TOTAL 136 of 136 verified, 20 of 20 services, 0 rolled-back.** App-028 (the
  crash-looping multi-bound app, 08+07) was still `0/1 crashed` after 08's rollback and needed a
  manual `cf restart`. **Cause (ledger, 2026-10-21):** its line under 07 was `rollback ok` from the
  old auto-rollback (bindings only, no restart — its previous line `restart:fail` was not in the
  restart list), and `rollback_service` skipped every app at `rollback ok` outright. **Fixed:**
  `restart:fail` restarts like `restart`; an app at `rollback ok` is looked at again — the ledger
  first (that rollback skipped the restart after a start onto the Valkey → restart, RUNNING proves
  nothing), the stats second (an instance down → restart; all up → skipped, no new line; unreadable
  → `rollback fail`, loud). Review round found the stats-only first version wrong (a slow app that
  came up after the restart timeout runs on the Valkey env while RUNNING) plus two swallowed API
  errors (app state, instance count) — all fixed; cases K0–K8, X1–X2. Follow-up noted by the
  reviewer: after `rollback --service 09`, an app at `rollback:fail` under 08 (restarted by 08's
  step, crashed because 09's name was stuck) is fixed only by a second `rollback --service 08`;
  the runbook says so (§6b), no automatic cross-service retry.
- **2026-10-21 — `provision` serializes what Blacksmith sees; `provision-check` asks BOSH** (decisions 2+3
  of 2026-10-20, asked by the client: "one by one, but don't wait for the last one to finish").
  Verified in `blacksmith/internal/broker/broker.go` `Provision`: the index line is written in
  `storeInstanceData` *before* the 202, and CF moves the instance from `initial` to `in progress`
  on that 202 — so "poll until the state leaves `initial`, then the next POST" is exactly "one
  Provision call at a time", while the BOSH builds still overlap (`svc_create_accept`, ACCEPT_TIMEOUT
  120 s; past it, or after 3 listing errors, the rest of the wave is recorded `not issued` and a
  re-run creates them; the issued ones are still waited for). `provision-check` reads
  `bosh deployments --json` once through `BOSH_CMD` (env or `runs/<env>/bosh.conf`), requires a
  deployment ending in each Valkey's guid; result `HOLLOW` (+ purge command) for a succeeded Valkey
  without one; listing failure → API-ERROR for every service; empty listing refused (wrong
  director); no BOSH_CMD → refused unless `--no-bosh` (verdict says NOT CHECKED). Fakes:
  `CFFAKE_INITIAL_POLLS`, `st.overlap` (POSTs made while another create was `initial`; must be 0),
  bosh-fake `deployments` from the cf-fake state. Cases S1–S4, Q1–Q6, R13, P3b. Not yet verified
  live: the real `bosh deployments --json` shape through the genesis wrapper (`Tables[0].Rows[].name`,
  as `free-ips.sh` reads `instances`) — a wrong shape shows as API-ERRORs, never as a pass.
  Review round (fresh agent, 9 findings, all taken): a non-empty listing from the **wrong director**
  would have read as "every Valkey hollow" with purge advice for healthy instances → the listing must
  hold the plan's Redis deployments, else API-ERROR (Q7); `ISSUE_STOP` was per wave and the run
  exited 0 → it is per run, `provision --waves A-B` stops at that wave with exit 1 (S2); a voided
  create made `rollback_names` look up a gone Valkey guid → looked up only when the create is still
  `done`; the gate sits after adoption and before any DELETE/POST; verdict says "n of m valkeys have
  a deployment"; HOLLOW advice differs for a cut-over Valkey (rollback first); `bosh.conf` comments
  stripped.
  **First live run (SBX, 12:26 local): the BOSH listing froze for 180 s and then "failed".** Not the
  director: `genesis … bosh` runs bosh inside `script(1)` (raw-mode tcsetattr), and GNU `timeout`
  without `--foreground` moves the command out of the terminal's foreground process group, where
  that call is *stopped* (SIGTTOU) until `timeout` kills it (rc 124). `cf curl` under `timeout 30`
  never touched the terminal, `free-ips.sh` never used `timeout` — so only this call hit it. Fix:
  `timeout --foreground $BOSH_TIMEOUT` (probed; none at all if unsupported), no INT shield on the
  read-only listing, rc 124 said as "no answer within Ns", error text from the **tail** of stderr
  (the 200-char head showed only the deprecation warning). bosh-fake exits 97 outside the foreground
  group, so the harness reproduces the freeze under a pty (`script -q /dev/null bash …`): old code
  11 FAIL, new code 73 of 73 (Q8 timeout message, Q9 foreground). Review round (fresh agent, 3
  findings, all taken): `--foreground` signals only the perl wrapper, which bails without killing
  its `script`/bosh child → the terminal would stay in raw mode after rc 124 — the tool now ends
  every process of its group whose command line is the listing (`pkill -g … -f`) and runs `stty
  sane`; Q8 asserts none is left (the fake's hang is a child carrying the listing on its command
  line; the first version exec-optimized into a bare `sleep` and the assertion could not bite —
  caught by the negative check); error text tails stdout `.Lines` and stderr separately (bosh's
  own director error is on stdout and would have been cut again); fake comment. **Second live run
  (13:21): fails in seconds, rc 1, cause = no valid vault session** — genesis prompts for the
  login only with stdin AND stdout on a terminal (`Term.pm in_controlling_terminal`); the tool
  captures stdout, so it bails with its env-var method list. Remedy: `g32 @sbx-us b env` on the
  terminal first (stores the session), then the check; the tool now recognises the text and says
  that (Q10, 74 of 74 under a pty, 73 plain). **Third live run (13:49, after `g32 @sbx-us b env`):
  `bosh: 71 deployments listed by 'g32 @sbx-us b' (20 of 20 Redis of the plan found)`, every
  service `bosh deployment present`, `PROVISION-CHECK: OK (20 of 20 ok: 0 staged, 20 cut-over; 0
  missing, 0 mismatched, 0 hollow, 0 api-errors; bosh: 20 of 20 valkeys have a deployment)` —
  the real `deployments --json` shape through the wrapper is verified.** Knowledge:
  `knowledge/genesis/genesis-bosh-under-timeout-sigttou.md`.

- **2026-10-21 — NP timeline and the second SBX pass (client decisions).** NP: Redis creation is
  disabled in the NP envs; discovery scans Thursday and Friday, twice a day, so the plan comes
  from the freshest merged report; Valkeys are created on the **Friday** (`provision` +
  `provision-check` with BOSH), the migration runs on the **Sunday** — two days to look at the
  Valkeys and the pairs. NP z1 headroom checked by the client: ~1500 free IPs for ~200 Redis in
  the large env, ~200 free for tens of Redis in the small ones — no IP work needed. The hollow
  Valkey is covered by `provision-check`; the vault session is kept valid by hand. SBX: **the
  whole rehearsal is run once more** to rule out remaining issues (mirroring the NP shape:
  provision, two idle days, apply), and SBX is recovered (teardown, cells back to 5) **after** the
  NP upgrade. Known gap for the two-day window: `preflight`/`apply` work from the plan's app
  list; an app bound to a Redis between the last scan and the window is not migrated by the
  tool — it shows up at `verify` (drift) and `retire` refuses while the standby has a binding.
  Mitigation: one more scan on the Sunday morning before `plan`, or a preflight check "live
  bindings of each Redis ⊆ plan apps" (not built yet).

- **2026-10-21 — The 7 apply/rollback defects fixed before the second SBX pass** (asked: "check
  the connections migration and rollback, renaming and rename back, again"; two fresh-agent reviews
  found them, a third reviewed the fix). Each needed a failure during the handling of a failure,
  which the first pass never had. (1) *rollback re-run said done while the app ran on the Valkey*:
  after a `rollback fail` the restart is decided by the **ledger** — restarted (or failed to) onto
  the Valkey since the pair's last rollback **ok** ⇒ restart; a rollback fail in between undid
  nothing, RUNNING proves nothing (`restarted_since_rollback_ok`; the same rule for a `rollback ok`
  that skipped its restart, and — review round 3 — for any other last line such as the new
  `bind-valkey blocked`). (2) *multi-bound app restarted into a hole*: a wave service given up on
  whose Redis still carries `-redis-standby` (NAMES-STUCK) **blocks the app** — `bind-valkey
  blocked`, nothing bound or restarted; `rollback --service` the stuck one, then `apply`. (3) the
  instance count is never guessed (unreadable ⇒ `drift fail`, app skipped). (4) a Valkey binding
  still `in progress` is **waited for, never adopted** (`binding_ready`: ok / none / corpse / ERR /
  WAIT); past BIND_TIMEOUT only that app is left as it is, the service goes on (review round 3: a
  service rollback would have tried to delete the in-progress binding). (5) **the hollow gate**:
  `preflight` needs, for every wave service with a Valkey, its `provision-check.tsv` line — same
  guid, `OK`, `bosh=present`, `checked_at` ≥ the create; `--no-bosh` does not pass; the file is now
  merged per wave (`--wave N` no longer wipes the other waves' lines). Consequence: BOSH access on
  cutover day too, and a resume of a day-of wave needs a `provision-check` after its creates. (6)
  the record of a rebind that failed (CF keeps it, state `failed`, and refuses "already bound")
  is deleted first, in rollback and in apply. (7) a Valkey purged *before* the rollback (404) is
  "name free": the Redis still goes back, the create is **voided** (`create-valkey fail "purged
  before the rollback"` — inventory/status say create-failed, `provision` creates again; review
  round 3: an `undone` alone left the purged guid listed as staged). Small: a halt inside the
  services loop still waits for the issued creates and puts names back; a Redis found already
  under the standby name is recorded, not refused (preflight agrees); `rollback` ignores Ctrl-C
  outright (a handler kept the shell alive but killed the `jq` children — review round 3);
  `svc_create_wait` checks its listing; `rollback` rewrites the inventory. **Harness rule learned:**
  the gate broke every offline flow that applied straight after `provision` — the harnesses now
  run `provision → provision-check → apply` like the procedure, and case R's hollow is injected
  *after* the check (the Friday-check / Sunday-loss shape). The new reset case (API error in the
  *verify* phase) crashed `reset-scaled.sh` ("CF_ERR: unbound variable": set inside `$(…)`) —
  fixed; checklist rows 25 (subshell-set status) and 26 (last-event rules cover new events). Fake:
  bindings follow their job (`in progress` until polled out; a failed bind leaves the record, as
  CF does), `CFFAKE_BIND_POLLS`, list-valued `CFFAKE_RENAME_FAIL` / `CFFAKE_FAIL_GET` (`$` =
  exact). Negative check: the new cases run against the old `migrate.sh` fail (S3/S5, D2, D4,
  G1/G2, W1/W2, I1). Suites: provision 80 of 80, rollback 76 of 76, reset 9 of 9 (macOS, plain;
  bastion = Linux not re-run for this change — no OS-specific construct added). Not verified live
  yet: a CF binding's `in progress` state shape and CF refusing the DELETE of an in-progress
  binding (both fail closed if different). The second SBX pass should trigger #1/#4/#6 on
  purpose (kill the terminal mid-bind; a rollback with the broker stopped).

## Open questions

- [ ] dominant client stacks — Java/Spring + .NET assumed; confirm (decides which real-stack apps matter)
- [ ] are classic plans + patched broker in SBX yet, or do we start on secure plans and switch when they land?
- [ ] data-copy mechanism: exists to test, or does `sim-store-bound` first just *measure* loss to give the copy tool a target?
- [ ] SBX quotas (apps, service instances, memory) — enough for the Phase-2 population?
- [ ] which Windows stack / .NET runtime is standard in the client estate?
- [ ] are the client's Redis plans `persistent: true`? (`appendonly yes` in redis.conf on a service VM) — decides whether upgrade history = reset tolerance
- [ ] how many real consumers use the TLS port (16379)? (census has the port -- `awk -F'\t' '$4==16379' backward/02_conns.tsv`) -> sizes the TLS-plan requirement for Valkey

## Log

- 2026-10-22 — **Client lab: an app already crashed before its wave made preflight FAIL and the whole
  wave stop** (rule was "fix BEFORE migrating": a broken app would fail verify and roll the service back).
  Decision: handle it like a STOPPED app — rebind, no restart, verify on bindings only (a crash-restart
  keeps the env of the last start, so nothing changes for it until the team restarts it; then it is on the
  Valkey); not "skip the app" (it would stay bound to a Redis renamed now and retired later). Exception:
  partly running on a datastore service ⇒ still FAIL / `drift fail` (its live instance would keep writing
  to the standby Redis). Decision taken once per wave (ledger first); rollback restarts it only when it is
  all RUNNING now (started since ⇒ may hold the Valkey env). `status` footer "rebound but NOT restarted"
  lists STOPPED + broken-before apps for the teams. Cases V1–V10 (fake `CFFAKE_BROKEN`); old code fails
  9 of 10. **Review round found 6:** a `rollback fail` erased the decision (retry restarted the app);
  a multi-bound app reused the first service's stale decision after the other's rollback had restarted
  it; "nothing changed" said on a half-migrated app; a malformed verify note the case could not see;
  the rollback marker tested on the whole note (incl. `--reason`); the footer counted pairs. All fixed,
  cases W1–W3 reproduce them (pre-fix script fails 4 of the new checks). Interim for the lab: `cf stop` the crashed apps before the wave (never `apply --force`: it skips
  preflight, restarts the app, verify fails, the service rolls back). Second lab finding — Redis
  instances with **no `instance_name` in Blacksmith's Vault** (imported from the old broker): planned as
  `name-check [--fix]` (seed the root `secret/<guid>` from the CF name when empty; batched per wave) — next.
- 2026-10-23 — **`name-check [--fix]` built** (the lab's nameless Redis). Verified live first (SBX, 2026-10-22,
  `scla-redis-01` root): `safe rm secret/<g>:instance_name` leaves the root; `safe get` then prints
  `!! no key `instance_name` exists in secret …`; the reconciler has no source to refill it
  (`resolveInstanceName` falls back to Metadata keys nothing sets) — the lab's state, persistent. The UI
  list still shows the index's name, the detail page none (`handlers/bosh/handler.go:357`). Design: one
  `SAFE_RUN` call per wave, every answer keyed by the full guid on one stdout line (`2>&1 | sed`), so a dead
  session is "nothing recorded", never "all unset"; seed only on the no-key shape (`safe set` creates a
  secret when the path is absent — the wrong-Vault trap), mismatch reported and never written; `name_sync`
  accepts the unset shape at rename time; preflight WARNs from the ledger only. Cases X1–X7 (fake: real
  wording for both shapes, `SAFEFAKE_ERR`); old code fails all 7. **Review round found 6:** the expected
  name was the plan's, not the ledger's (a re-check after wave 1 = MISMATCH on every migrated service, and
  `--fix` would seed the stale name) → `nc_expected` follows `rename-standby`; VM-shell errors (`bash: safe:
  command not found`) were recorded as a MISMATCH per service → classified as errors, and "every service the
  same non-name text" aborts; the seed call had no "answered at all?" guard (a dead wrapper logged "seeded
  but …") → guarded, honest note; an empty value was written on an unverified shape → reported, not written;
  the fake split on `; ` inside names; `wave_started` took the name-check time. All fixed, cases X8–X11.
  Provision suite 108 checks. Next in SBX: `name-check --fix --wave <its wave>` on the deleted-name instance
  (expect UNSET → seeded, UI detail page named again), then its wave.
- 2026-10-23 — **SBX `name-check --fix` run (all 7 waves, 25 services): 1 unset → seeded (the drill), 10 MISMATCH,
  nothing written.** 7 of the 10 were the first pass's stale `-redis-standby` names: `reset-scaled` rolls back via
  `migrate.sh rollback`, whose name-sync is not fatal, and phase 2 verifies CF names only — so a reset finishes green
  with Blacksmith's copies not put back; the archive then hides them from the new ledger. Fixed with
  `name-sync --waves 1-7 --run runs/sbx/pass-<date>` (the archived ledger holds `rename-standby undone`; needs
  `vault.conf` copied in) → 22 of 25 in sync. The other 3: 2 `sim-redis-*` left as `-redis-standby` by the first
  simulation (never retired) and 1 renamed by hand → **hand steps by design: the tool only writes names whose
  rename it recorded.** Decision: delete the first simulation's 6 standby Redis (its retire step) and re-plan.
  Found by the way: `sclb-redis-09`'s deployment has **0 VMs** since its only deploy (task 9071562, 2026-10-19,
  CPI "address already in use" — the reserved-IP incident); CF said `create succeeded` (Blacksmith's
  task-id-0/1 "deployment exists → succeeded" path). Its apps migrated and rolled back fine → the tool never
  touches the Redis; edges: rollback onto a dead source is reported ok, `--copy-data` would fail. Kept as the
  "dead source" fixture. Follow-up: `provision-check` BOSH half should also require ≥1 running instance per
  Valkey deployment (this shape passes "deployment present").
- 2026-10-23 — **NP plan read (largest env, wave size 10): 272 services / 745 apps / 821 connections / 40 orgs,
  237 components, 29 waves (4 silent = 115 services, 25 live).** Client intent: one Sunday, 5–6 terminals each
  running 5–6 waves in parallel — so restarts per wave are lane *wall time*, not risk; balance terminals by the
  restarts column. Hazard 9 components / 9 services / 21 apps over 3 waves; no-binding 3 / 3 / 6 over 3 waves;
  windows 12 / 12 / 19 over 8 waves. **`plan --isolate hazard,no-binding,windows` built**: those components go
  into their own waves, numbered last, one class per wave (class = highest flag in the component; hazard >
  no-binding > windows); default plan byte-identical (golden files). Review found 6: two parsers of one option
  value (`"hazard, windows"` validated by the shell, looked up with the blank by awk → silently not isolated);
  `--isolate=x` swallowed by the parser's `-*)`; windows class read the row's platform while the flag reads the
  app's (last row) → class and flag could disagree; "wait for nobody" overclaimed with a subset of classes;
  P1 was no byte-identity guard; missing cases (bridge app across classes, two components in one class wave,
  silent isolated, absent class). All fixed; new suite `test/case-plan.sh` 29 checks (old code fails 24),
  second fixture `merged_report_iso.csv`. Still to decide with the client: silent waves last (owners: migrate
  or retire), `--wave-size`, IP headroom (157 live / 272 all) via `free-ips.sh`, director workers for 272
  creates. Open: can the merge emit a blank `platform` on a backward row of a Windows app? (then the windows
  flag — and class — miss it: last row wins). **Answered the same evening, from the toolkit's source: worse
  than that.** `platform` came only from the backward scan (cell type of a live connection), so a Windows app
  with no live connection was never known as Windows — the NP "18 windows apps" counts only Windows apps with
  a live connection; the 265 idle connections hide the rest. Fix in the discovery toolkit: `scan-apps` records
  the app's lifecycle stack (`windows*` → windows, `cflinuxfs*`/docker → linux, else `?`) as `app_base.tsv`
  column 6; `merge` prefers it, falls back to the cell value, warns on disagreement; old 5-column files behave
  as before. Plus `plan`'s windows flag made sticky (any row → windows). Found on the way: `merge` exited 1
  unless an external UPS existed (the last statement's status) — `return 0` added. New offline harness for
  the toolkit (`test/cf-stub`, `test/case-platform.sh`, 16 checks; old tool fails 12). Review round (6):
  `compare-reports` does NOT compare platform (my fit claim was wrong — it tracks consumer relationships, by
  design; left as is); the 5-field tab-split read shifted on a null space → `\037` join; CRLF header /
  hand-edited values → CR-tolerant, case-insensitive, odd values counted; the `/v3/apps` lifecycle shape not
  verified live yet (asked for a 5-app `jq` from SBX); `return 0` comment; docs. **NP needs one more scan
  before the plan is final** (the user has no NP access; the client runs it).
- 2026-10-22 — **Second SBX pass, apply: 136 of 136 verified, 20 of 20, every wave 100 %; all 40
  name-syncs failed** with genesis's `[FATAL] Could not successfully authenticate` captured in the ledger
  note: the vault session renewed for the provision-check the day before had expired, and `safe-run.sh`
  (`genesis … bosh --connect`) cannot prompt while the tool captures its output. Cosmetic by design (CF
  names right, apps verified); repair = renew (`g32 @sbx-us b env`), prove the wrapper on one guid, then
  `name-sync --waves 1-6`. Runbook §7 now starts with that renewal. **Open for the tool (after this
  pass):** a preflight WARN that reads one instance name back through `SAFE_RUN` — would have shown this
  before the first rename instead of after 40 failures. Pitfall seen while diagnosing: the ledger note
  stores genesis's coloured output, so `jq` printing a note looks like a live vault error; it is not.

- 2026-10-22 — **Ctrl-C at the `type yes` question never ended it (SBX, first apply of the second pass).**
  `apply` installs its flag trap before the question; bash runs the handler on a trapped SIGINT and then
  *restarts* a terminal `read`, so each Ctrl-C printed the trap line and the question went on (typing `no`
  ends it). Fix: the four questions (apply, provision, rollback's `confirm_or_die`, copy-data `done/skip`)
  read through `a=$(ask)` — a `$(...)` subshell resets trapped signals to default, so Ctrl-C ends the read
  (rc 130, empty answer = no); the main shell's trap runs once afterwards and sets the flag (at the copy-data
  question that halts the wave at its next boundary, as any Ctrl-C). Verified in a python pty on bash 5.3 and
  3.2 (Ctrl-C, slow typing across a pause, `no`, idle then `yes`). Harness Q11 took three versions to bite:
  a pty whose input is at EOF answers every read at once (both old and new code "not confirmed" without any
  signal); an async job (`&`) of a non-interactive bash has SIGINT ignored and a shell entering with it ignored
  cannot trap it (nothing reacted); the final case runs apply in the harness foreground under its own
  `script(1)` pty fed by `<(sleep 30)`, signals by anchored `pkill -f` (main shell + subshell, not the pty
  wrapper), watchdog at 12 s. New code: 81 of 81 (Q11 in 3 s); old code: Q11 FAIL at 12 s with the exact SBX
  transcript. The bastion keeps the old copy for this pass (`no` + Enter cancels; after a Ctrl-C at the
  question type `no`, not `yes` — the flag would halt the wave at its first step).

- 2026-10-22 — **Second SBX pass, provision measured (20 of 20 staged, PROVISION-CHECK OK).** Plan
  from a fresh scan with `--services '^(scla|sclb)-redis-' --wave-size 4 --max-apps 40`: 20 services,
  120 apps, 136 connections, 16 multi-bound, 2 silent, 6 waves — identical to the first pass. One
  `provision --waves 1-6` process, prompts answered by hand: 38 min wall-clock of which ~18 min were
  prompt waits (`--yes` next time). Per-wave timestamps (`provision ok` events): a 4-service wave =
  **3 min 32 s**, a 3-service wave = 3 min 31 s → ~20 min of real work for 20 Valkeys. Create (POST →
  succeeded) min 67 s / median 191 s / max 204 s, n 20: four concurrent builds finished in one build's
  time (no director queuing at 4). Broker accept spacing 5 s (17) / 6 s (3). **NP (274 services,
  waves of 10, `--yes`):** issuing 274 × 5.5 s ≈ 25 min total; wall-clock ≈ 2 h if the director overlaps
  10 builds, ≈ 4.7 h if it caps at 4 — read the first NP wave's create median (≈200 s = overlapping;
  400–600 s = queuing) and check the NP director's `workers` beforehand. Provision runs in ONE process
  by design: the one-create-at-a-time rule (`svc_create_accept`) watches only its own last POST.

- 2026-10-06 — **RETRACTED** the "async deprovision: deleted in CF ≠ gone" finding: it was inferred, never observed. Real cause: `reset-population.sh` never deleted the Valkeys (invalid `service_offering_names` filter on /v3/service_instances → error document read as an empty list). Script fixed (offering from `cf services`, hard stop if Valkeys remain). `retire` still censuses the standby before deleting — as plain prudence, not because of this.

- 2026-10-02 — `preflight` + `dry-run` built, offline-tested against a stub cf (ledger/CF reconciliation, collisions, plan visibility, half-down app and hazard env → FAIL). Next: run both against the SBX population, then `apply`.

- 2026-10-02 — `migrate.sh plan` built and verified on a synthetic report; two-artifact output (detailed in env / aggregate summary shareable). Ready to run on the real most-complex-env report (Phase 3.5).

- 2026-10-02 — S7-7 result: **Blacksmith keeps showing the pre-rename service name** (rename is CF-only; the broker is never told). Backlog item for blacksmith: refresh instance names from the CF API (it already has a CF client) or accept CF context updates (`allow_context_updates`). Until then the ops runbook says: Blacksmith names are the ORIGINAL names; after a migration the standby Redis shows under the name the Valkey now owns.
- 2026-10-02 — Rollback confirmed quick in practice (done several times during the session: bind/unbind/restart, minutes) — the formal timed measurement (block 11) is optional. Retirement explicitly out of scope for now.

- 2026-10-02 — **S7 passed**: rename-first naming sequence works end to end; stale-manifest push lands on the Valkey. Theory validation now complete for every scenario except ordering (deferred by policy). Remaining optional evidence: timed rollback + downtime (11 with the poller), retire/IP recycling (12), TLS consumer (S6), Blacksmith UI name after rename (S7-7).

- 2026-10-01 — Phase 3.5 added: build the real migration plan from the most complex env's merged report (graph analysis → waves.tsv + client review) before the first real wave. The report is accessible now.
- 2026-10-01 — **Theory validation considered complete** except ordering (deferred by policy). Still worth collecting if time: timed rollback + plain-vs-rolling downtime (11, poller), retire/IP recycling (12), secure-plan WRONGPASS evidence (S4), TLS consumer (S6), rename swap + stale-manifest push (S7).

- 2026-10-01 — **Naming-policy risk reproduced in SBX:** `sim-pipeline-b` (selects its binding BY NAME, `SIM_SERVICE_NAME`) crashed at its migration restart under substituted naming — no binding named `sim-redis-pipe-a` any more. Fix = team-side config change (`cf set-env SIM_SERVICE_NAME <new name>`); under policy A (rename swap before restart) no change would be needed. Evidence for the client's naming decision.
- 2026-10-01 — Blocks 6a/6b (queue group split → starvation; counter restart invisible to a restarted consumer), 8a/8b (no copy → state reset; rollback → Sept 30 canary intact) done. 8c copy methods written.

- 2026-10-01 — **Theory validated for the core claim + every access pattern on the cache service:** sim-cache-bound migrated (4 commands, server=valkey, auth_user=default); pinned hazard shown live (binding moved, app stayed on Redis) and fixed; username-aware, password-only (classic), Windows, UPS (via update-user-provided-service), static-env (via set-env) all on Valkey. Remaining blocks scripted in `scenarios/SESSION-COMMANDS.md` (queue group, downtime, store loss/copy, session, pipeline order, timed rollback, retire).

- 2026-09-30 — **Full population live in SBX: 14 apps** (core six + pinned/static-env/UPS/password-only/username-aware/pipeline a+b + Windows), `baseline-all` captured. Six core Go probe apps up, baseline captured (`verify/data/*-baseline.jsonl`). Next: access variants + Windows + TLS apps, Valkey twins, first migration (cache).

- 2026-09-30 — First SBX push of sim-py failed at staging: it named the ONLINE `python_buildpack`; the client runs offline `*_buildpack_system` buildpacks (as with `java_buildpack_system`). All manifests now use `binary_buildpack_system` (sim-py: `python_buildpack_system`). Ported the probe to Go (static binaries, binary_buildpack) -- also yields the Windows app from the same code. Tests green (miniredis).

- 2026-09-30 — **Switching from tooling to theory validation.** Operator-layer work paused after
  `status` (next when resumed: `plan` → `preflight` → `dry-run` → `apply`). Written for the SBX
  session: `scenarios/THEORY-VALIDATION.md` — the by-hand four-step migration of the 6 services
  with the sim apps, access-variant claims, store-loss measurement, rollback timing, results
  table. Everything the tool later automates must reproduce that runbook.

- 2026-09-20 — plan created; Phase 0 prerequisites listed; nothing started.
- 2026-09-28 — `migrate.sh status` built and demonstrated on a sample ledger (`migrate/example/`); plan file settled as `waves.tsv`.
- 2026-09-28 — Phase 3 redesigned around the operator layer (`migrate/DESIGN.md`); SBX sized to 6+6; lock service merged into the queue Redis.
- 2026-09-20 — Phase 1 started: `/check` contract written; `sim-py` probe built with all six
  usage modes + three credential sources + two auth styles, smoke-tested locally against
  fakeredis (lock-mode double-exec false positive found & fixed: per-window lock keys +
  per-instance run log); manifests for 13 app variants; verifier snapshot/poll/apps-list
  scripts. Next: deploy to SBX against real Redis, then Spring/.NET apps and expectation
  tables. Phase 1 = `[~]`.
