# Operator runbook — scan → plan → provision → provision-check → preflight → apply

The instructions for one foundation, from the discovery scan to the cutover. Every command is
run on the bastion of that foundation, in `~/ocfp/migration-sim`, with `<env>` the genesis
environment name (SBX: `sbx-us`, run dir `runs/sbx`). The values that differ per foundation
(services network name, cloud-config name, the `--services` pattern) are written down once per
foundation in `runs/<env>/README` by whoever runs it first; the reasons behind every step are
in `DESIGN.md`.

Two files decide everything: **`runs/<env>/waves.tsv`** is the plan (what to migrate, in which
wave) and **`runs/<env>/ledger.jsonl`** is the record (what happened). Every command reads the
ledger before it does anything, so **every command can be re-run** — a re-run continues, it
does not repeat.

## The timeline (NP, decided 2026-10-21)

| when | step | section |
|---|---|---|
| Thursday + Friday, twice a day | discovery scan, merge | 2 |
| Friday | `plan` from the freshest report, review, `name-check --fix`, `provision`, `provision-check` | 3, 4, 5 |
| Saturday, Sunday morning | `provision-check` again (the Valkeys are still real) | 5 |
| Sunday | `preflight`, `dry-run`, `apply` per lane; `status` in another terminal | 6, 7, 8 |
| after | `name-sync` to 0, hand checks, numbers; `confirm` / `retire` weeks later | 9 |

---

## 1. Before anything: access and the two config files

Needed on the bastion: an **admin `cf` login** at the foundation (`cf curl /v3/info` answers);
a **vault session for genesis** (the BOSH half of `provision-check` and `free-ips.sh` go through
`genesis @<env> b …`); `jq`; and `tmux` — the bastion logs idle sessions out, and `provision`
and `apply` run for hours.

```bash
tmux new -s mig            # later: tmux attach -t mig
cd ~/ocfp/migration-sim && git pull
mkdir -p runs/<env>

# name-sync: the tool writes Blacksmith's copy of each renamed instance's name through this wrapper
cp -n migrate/example/safe-run.sh runs/<env>/safe-run.sh
printf 'SAFE_RUN="bash runs/<env>/safe-run.sh"\n' > runs/<env>/vault.conf
BLACKSMITH_ENV=<env> bash runs/<env>/safe-run.sh "safe get secret/<any redis guid>:instance_name"   # must print that instance's name

# provision-check: the BOSH listing goes through this
printf 'BOSH_CMD="genesis @<env> b"\n' > runs/<env>/bosh.conf

# optional: the operator name the ledger records (default: your login)
export MIGRATE_OP=<name>
```

If the first command answers `invalid option name set: pipefail` or `syntax error near unexpected
token '$'{\r''`, the files arrived with Windows line endings (a copy through a Windows machine or a
browser). Once: `sed -i 's/\r$//' migrate/*.sh migrate/example/*.sh migrate/test/*` — then
`bash -n migrate/migrate.sh` prints nothing. Hand the bundle over as the tarball, not as single files.

Rules for the genesis BOSH wrapper, learned in SBX: **run `genesis @<env> b env` once in the
terminal before `provision-check`** (it stores the vault session; the tool captures output and
cannot answer the login prompt). **Never pipe `genesis … b …` output to `head`** — redirect to a
file. Never `eval "$(genesis … --connect)"` in your own shell; `safe-run.sh` does that inside its
own process.

---

## 2. Scan — who uses which Redis

In the discovery toolkit's directory (`~/ocfp/redis-consumer-discovery`), one output directory
per scan day:

```bash
cd ~/ocfp/redis-consumer-discovery
D=./scan-$(date +%F-%H%M)
bash redis-consumer-discovery.sh run        <env> --path $D     # live connections (Linux + Windows cells)
bash redis-consumer-discovery.sh scan-apps  <env> --path $D     # bindings, env vars, manifests (the slow part)
bash redis-consumer-discovery.sh list-redis <env> --path $D
bash redis-consumer-discovery.sh scan-ups   <env> --path $D     # user-provided services with copied credentials
bash redis-consumer-discovery.sh merge      <env> --path $D     # -> $D/merged_report.csv
bash owners.sh $D                                                # -> $D/merged_report_owners.csv (for the teams)
cd ~/ocfp/migration-sim
```

`RCD_PAR=16` speeds `run` up; `RCD_RESUME=1` continues an interrupted one. To see what changed
between two scans: `bash compare-reports.sh <old>/merged_report.csv <new>/merged_report.csv`.

The tool plans from **`merged_report.csv`** (the owners file is for the teams). An app bound to a
Redis **after** the last scan is not in the plan and is not migrated; it shows up later as drift
and `retire` refuses while it is bound. That is why the last scan is as late as possible
(Sunday morning before `plan` is allowed — `plan` is cheap).

What leaves the environment: nothing from the scan (every file has app and org names). The
counts come from `plan-summary.md` in the next step.

---

## 3. Plan — waves

```bash
bash migrate/migrate.sh plan ~/ocfp/redis-consumer-discovery/<scan dir>/merged_report.csv \
     --run runs/<env> --services '<ERE of our service names>' --wave-size 10 --max-apps 40
cat runs/<env>/plan-summary.md
```

- `--services` keeps only the Redis whose **name** matches (the scan covers the whole
  foundation; SBX: `'^(scla|sclb)-redis-'`). Excluded services are counted in the summary.
- `--wave-size` = services per wave, `--max-apps` = app restarts per wave;
  `--silent-max-apps 120` is the cap for waves made only of silent services (no live consumer).
- An app and every service it is bound to land in the **same wave** (one restart per app).
- `--isolate hazard,no-binding,windows` (any subset) puts the components that carry those flags
  into their own waves, **numbered last**, one class per wave. Use it when the waves run in one
  window (NP Sunday): every other wave then carries none of the named classes (name all three for a run that waits for no team); the isolated waves
  run when the pinned refs are fixed (hazard), the hand re-points are done (no-binding), or the
  Windows restart was drilled in SBX. A whole component moves with its flagged connection — the
  summary's "Isolated waves" table says how many services and apps that is.
- Connections whose method is not `cf-bind` (hardcoded address, UPS) are flagged
  `no-binding:<method>` — the tool cannot rebind them; preflight, dry-run and apply list them as
  **team action**.

Output: `waves.tsv` (the plan, names inside — stays in the env), `components.tsv`,
`plan-summary.md` (**aggregates only — the file to paste out**).

Review `waves.tsv` by eye: a service that spans several teams needs a joint window; a
`hazard` flag means a bound app also hardcodes the address (the team fixes the env var before
its wave). The `wave` column can be edited by hand before `provision`.

### 3b. Blacksmith's copy of the names — `name-check --fix`

Instances imported from the old broker (lab, 2026-10-22) have **no `instance_name`** in their
Blacksmith Vault root: no name in the broker UI, and `apply`'s name-sync would refuse them.
Once after `plan`, with the vault session fresh (`vault.conf` as in section 2):

```bash
bash migrate/migrate.sh name-check --fix --run runs/<env>          # every wave; or --waves A-B
```

One `safe` call per wave (≈ 30 s), one more for the seeds. Per service: `in sync`, `UNSET` (root
present, key missing → `--fix` writes the CF name and reads it back), `NO ROOT` (never written:
not this broker's instance, or `SAFE_RUN` reaches the wrong Vault — if **every** service says so,
fix `vault.conf`), `MISMATCH` (the broker holds another name — never written; look by hand).
A dead vault session is reported as such and nothing is recorded. `preflight` WARNs on anything
not in sync and on waves never checked; it does not block. Without `name-check`, `apply` still
seeds an unset root with the standby name.

If a ledger from an earlier plan is in the run dir, move it aside first
(`mv runs/<env>/ledger.jsonl runs/<env>/ledger-<date>.jsonl`): the new plan's GUIDs differ and
a clean ledger keeps `status` readable.

---

## 4. Provision — the Valkeys, days ahead

Before the first provision on a foundation: every non-BOSH address in the services subnets
(Transit Gateway attachment, endpoints, ELB, RDS) must be in the cloud-config `reserved` list —
`free-ips.sh` cannot see them, and a collision costs ~9 min of CPI retries per create
(SBX 2026-10-20; knowledge `genesis-kits/ocfp-transit-gateway-ip-not-reserved.md`).

```bash
export BOSH_CMD="genesis @<env> b"
bash migrate/free-ips.sh --network <services network> --cloud-config <cloud-config name> \
     --plan runs/<env>/waves.tsv --out runs/<env>/free-ips.txt       # free IPs vs Valkeys to create
time bash migrate/migrate.sh provision --waves 1-<last> --max-inflight <N> --run runs/<env>
bash migrate/migrate.sh provision-status --run runs/<env>            # ledger view: per wave staged / create-failed / not-provisioned
column -ts $'\t' runs/<env>/inventory.tsv | less -S                   # the client's review list (names inside)
```

**`--max-inflight <N>` — always, and N = the director's free workers.** Blacksmith deletes the index line
of any create whose deploy task is still *queued* when its hourly sweep ticks; CF then reports
`succeeded` for a Valkey that never came (a "hollow" — ext 2026-10-25, 7 of them; see
`knowledge/blacksmith/hollow-valkey-orphan-sweep.md`). A task that has a worker is listed within
seconds, so the rule is "never more creates alive than workers": the next create is issued only when
fewer than N Valkey creates are still `in progress` in CF — this run's, a killed run's, anyone's. N = the
director's `workers` minus what else runs there (Blacksmith batch jobs, other deploys): 20 workers idle →
16; 20 with 8 batch jobs → 10. One `provision` per director at a time. No broker or director restart while
creates are in flight (a broker restart moves the tick; a director restart kills queued tasks). The
per-wave line says how often the gate waited; "not issued … (--max-inflight N)" lines mean the count
never dropped within `INFLIGHT_TIMEOUT` (default 1500 s) — `provision` again later creates the rest.

What `provision` does: for every service of those waves, one Valkey under the staged name
`<name>-valkey-staged`, same space, the plan from `waves.tsv`. Redis and apps are not touched.
Creates are issued one at a time as Blacksmith sees it (a few seconds apart); the builds
overlap. A wave of 10 takes about one Valkey build (~5–10 min) plus the spacing.

If it stops halfway (Ctrl-C, logout, API error): the creates already issued keep running in
Blacksmith. Run `provision-check` (next section) — an instance still building is named with
`create in progress`. **Wait until none says in progress**, then run the same `provision` again:
finished ones are adopted, the rest created. Nothing is created twice. A create that failed is
recorded; the re-run creates it again.

`provision-status` closes with either "N still without a usable valkey → provision again" or
"all provisioned → provision-check".

Paste out: the `time`, the `TOTAL` line of `provision-status`, the counts line at the end of
`provision` (`staged / cut-over / not-provisioned / create-failed / drift`).

---

## 5. Provision-check — are the Valkeys real (run it every day until the window)

```bash
genesis @<env> b env                                       # stores the vault session for this terminal
bash migrate/migrate.sh provision-check --run runs/<env>  # all waves; --waves A-B or --wave N for a part
```

Read-only. For every service of the plan it reads the Redis and its Valkey back from CF (same
space, same plan name, create succeeded, right name) **and** reads `bosh deployments` once: a
Valkey CF calls "succeeded" without a BOSH deployment is **HOLLOW** — Blacksmith has lost it, a
bind would fail "deployment not found" (SBX wave 6, 2026-10-20). The verdict line is the last
line and the one to paste out:

```
PROVISION-CHECK: OK (n of n ok: s staged, c cut-over; 0 missing, 0 mismatched, 0 hollow, 0 api-errors; bosh: n of n valkeys have a deployment)
```

`FAIL` → the lines above it name each service with its problem and the command to run:

| result | meaning | do |
|---|---|---|
| `MISSING` | no Valkey (never created, or gone from CF) | `provision --wave N` again |
| `… create in progress` | a killed run's create still building | wait, check again, then `provision` |
| `MISMATCH` | other space / plan / name | look at it by hand; usually a hand-made instance |
| `HOLLOW` | CF says succeeded, BOSH has no deployment | the purge command printed in the line (`cf curl -X DELETE '/v3/service_instances/<guid>?purge=true'`), then `provision --wave N`, then check again |
| `API-ERROR` | CF or BOSH did not answer, or the listing came from the wrong director | fix access, run again — never a pass |

Three rules that make this step mandatory, not optional:

1. **`apply` refuses a wave whose services have no fresh OK line** (`preflight` FAIL "no
   provision-check line" / "did not see a BOSH deployment" / "older than the valkey's create").
   `--no-bosh` exists for a bastion without BOSH access but does **not** satisfy that gate.
2. A run for `--wave N` **replaces only wave N's lines** in `runs/<env>/provision-check.tsv`;
   the other waves keep theirs.
3. The check is cheap (one BOSH listing, two CF reads per service) — run it on each idle day and
   on the Sunday morning. A Valkey that disappears between Friday and Sunday is found here, not
   at `apply`.

The TSV has names inside and stays in the env; the verdict line has none.

---

## 6. Preflight — the gates, read by eye once per lane

```bash
bash migrate/migrate.sh preflight --wave 1 --run runs/<env>
bash migrate/migrate.sh dry-run   --wave 1 --run runs/<env> > runs/<env>/dry-run-wave-1.txt   # every API call, rollback row after each
```

`PASS` / `WARN` / `FAIL` lines, then the **blast radius** (services, Valkeys still to create,
app restarts, orgs, hazards) and the verdict `PREFLIGHT: OK (n WARN)` or
`PREFLIGHT: n FAIL … -- do not apply`. `apply` runs the same preflight itself before each wave
and stops on any FAIL or on a missing verdict; `--force` overrides and is recorded — do not use
it to get past a FAIL you have not understood.

What it checks, and what to do on a FAIL:

| check | FAIL → |
|---|---|
| no lock, no `STOP` file, ledger parses | a lock from a dead run: look at `runs/<env>/wave-N.lock`, remove by hand only if that process is gone; `rm runs/<env>/STOP` |
| cf API reachable | `cf login` |
| each Redis: present, not shared into other spaces, no pending operation; standby name free | a `create failed` instance under a production name is a leftover — the tool names it |
| each Valkey: staged under its name and plan; an unknown staged instance | `provision --wave N` (adopts it) |
| **hollow gate**: fresh OK + `bosh=present` line per Valkey | section 5 |
| classic plan visible in the space | `cf enable-service-access valkey -o <org>` |
| IP headroom ≥ Valkeys still to create | `free-ips.sh` again (`free-ips.txt` older than 24 h is a WARN); services already staged need none |
| quota in each org | the org's quota (`cf quota`) |
| every app in the wave running | `STOPPED`, or **some instances not RUNNING before the wave** (crashed app): a WARN — the app is rebound, not restarted, verified on bindings only; it comes up on the Valkey when the team next restarts it. FAIL only when it is *partly* running **and** its Redis is a datastore (its live instance would keep writing to the standby Redis): fix it or `cf stop` it before the wave |
| hazard apps' env fixed, pipeline pairs complete | team action |

A WARN never blocks. A service **without a Valkey** yet gives a WARN ("apply creates it today")
— allowed, but see the resume rule in section 7.

---

## 7. Apply — the cutover

One terminal per lane, each in `tmux`; a lane is a range of waves run back-to-back.

First, in each lane's window, renew the vault session and prove the name-sync wrapper works —
genesis's session from the day before has expired by now, and the wrapper cannot ask for a login
while the tool captures its output (SBX 2026-10-22: all 40 name-syncs of a pass failed that way,
the cutover itself unaffected):

```bash
genesis @<env> b env > /dev/null
bash runs/<env>/safe-run.sh "safe get secret/<a redis guid of the wave>:instance_name"   # must print its name
```

```bash
# lane A                                                        # lane B (another terminal)
time bash migrate/migrate.sh apply --waves 1-3 --run runs/<env>  time bash migrate/migrate.sh apply --waves 4-6 --run runs/<env>
```

Each wave: preflight → `Execute wave N now? type yes:` → the **services phase** (Redis renamed
to `<name>-redis-standby`, Valkey renamed from `-valkey-staged` to `<name>`, Blacksmith's copy of
both names set) → the **apps phase**, one app at a time (bind Valkey → unbind Redis → one restart,
rolling for several instances → verify: bindings are Valkey only and the app is running). A
verify, bind or unbind failure **rolls that service back** (names and bindings, restart) and the
wave goes on; **three failures in a row stop the wave** and the lane.

Watch from a third terminal — totals only on the first screen, names only with `--wave N`:

```bash
watch -n 5 -c "bash migrate/migrate.sh status --run runs/<env>"
bash migrate/migrate.sh status --wave 1 --run runs/<env>
```

Stopping: `touch runs/<env>/STOP` halts every lane at its next step boundary (issued creates
are still waited for; a service given up on gets its names back). Ctrl-C finishes the current
step, records it and exits; at a question (`type yes`, `done`/`skip`) Ctrl-C answers no. **Do not kill the terminal** — a kill between a CF call and its
ledger line is the one thing the tool cannot record; the next `apply` finds the state in CF
(a binding `in progress` is waited for, a failed one deleted, a Redis already renamed is
recorded) but slower.

Day-of creates: a service without a staged Valkey is created inside `apply`. **If that wave stops
and is resumed, the resumed `apply` fails preflight for those services** (no provision-check line
newer than the create): run `provision-check --wave N`, then `apply --wave N` again. BOSH access
is therefore needed on the Sunday too.

Re-running `apply --wave N` after anything (stop, rollback, fix) is the normal way to continue:
done steps are skipped, undone ones redone, one app at a time.

### What the dashboard phases mean

| phase | meaning | do |
|---|---|---|
| `STAGED` / `MIGRATING` / `VERIFIED` | as it says; `VERIFIED` = every app on the Valkey | nothing |
| `FAILED(<step>:fail)` | a step failed; the service was rolled back if a bind/unbind/verify | `status --wave N` for the note, fix, `apply --wave N` |
| `BLOCKED(bind-valkey:blocked)` | the app is bound to a neighbouring service whose names are stuck; the app was not touched | roll back the stuck neighbour (`NAMES-STUCK` below), then `apply --wave N` |
| `ROLLED-BACK` | the service is back on Redis, names back | read the reason in the ledger; a Valkey problem → section 5 |
| `NAMES-STUCK` | a rollback could not put a name back (Redis still `-redis-standby`) | `rollback --wave N --service <name> --reason "…"` again; it also restarts the apps it had rebound |
| `attention:` block | every failed/blocked/rolled-back pair, guids only | the rows to act on; `runs/<env>/status/failed.tsv` has the notes |
| `name-sync pending: n` | Blacksmith's copy of n names not set yet (a `safe` call timed out) | section 9 |

### Rolling back by hand

```bash
bash migrate/migrate.sh rollback --wave N --service <name>           --reason "<why>" --run runs/<env>
bash migrate/migrate.sh rollback --wave N --service <name> --app <app> --reason "<why>" --run runs/<env>   # one app
```

`--service` takes a name **or a guid prefix** (`--service 9099605a`). A name is unique per space, not per
wave: when two spaces hold a service of the same name (a shared instance's consumers, or just a common
name), the name matches both and every command refuses with the two prefixes to choose from — use the
prefix. (Before 2026-10-25 `apply`/`provision` took both services silently; ext did exactly that.)

Names go back first (Valkey → `-valkey-staged`, Redis → `<name>`), then every app of the service
is rebound to the Redis, unbound from the Valkey and restarted. Ctrl-C is ignored for the whole
service rollback. Several services of one app: roll back in chain order away from the broken one,
then run the first one once more (SBX 2026-10-20). `--yes` skips the prompt.

---

## 8. After each lane

```bash
bash migrate/migrate.sh status --run runs/<env>                  # TOTAL line, attention block
bash migrate/migrate.sh name-sync --waves 1-6 --run runs/<env>   # until the footer says pending: 0
```

Hand check a few apps (`cf env <app>` shows a `valkey` binding and no `redis`; the app's own
health endpoint). The silent services' STOPPED apps stay STOPPED — they pick the Valkey up when
the team starts them. The same goes for apps that were already crashed before their wave:
`status` lists both kinds in the footer "apps rebound but NOT restarted" — hand that list to the
app teams ("your app is on the Valkey from its next restart; please fix and restart it within the
grace period"). Do not "skip" such an app instead: it would stay bound to a Redis that is renamed
now and retired later.

Paste out per lane: the `time`, the `TOTAL` line of `status`, the `attention:` block if any
(guids, no names), and the numbers lines below (none has a name in it):

```bash
bash migrate/migrate.sh status --run runs/<env> > runs/<env>/summary.txt
jq -r 'select(.step=="create-valkey" and .outcome=="ok") | .ms' runs/<env>/ledger.jsonl | sort -n | awk '{a[NR]=$1} END {print "create ms: min", a[1], "median", a[int(NR/2)+1], "max", a[NR]}'
jq -r 'select(.step=="verify" and .outcome=="ok") | .ms' runs/<env>/ledger.jsonl | wc -l          # apps verified
jq -r 'select(.step=="name-sync") | .ms' runs/<env>/ledger.jsonl | sort -n | tail -1              # slowest name-sync, ms
```

---

## 9. Later: confirm, retire

The standby Redis keep running for the grace period (default 14 days). `confirm --service Y
--by <team>` records the team's sign-off and starts the clock; `retire --service Y` deletes the
standby Redis — it first counts the connections still on it and refuses while anyone is
connected (an app with copied credentials), then asks twice. The only irreversible step.

---

## What may be pasted out of the environment

| yes — no names inside | no — names inside, stays on the bastion |
|---|---|
| `plan-summary.md` | `waves.tsv`, `components.tsv`, `merged_report*.csv` |
| the `PROVISION-CHECK:` line, the `PREFLIGHT:` line, the blast-radius line | `provision-check.tsv`, `preflight-wave-N.log`, `inventory.tsv` |
| `provision-status` / `status` TOTAL lines, the `attention:` block (guids) | `status --wave N`, `status/failed.tsv`, the ledger |
| `time` outputs, the ms numbers lines, counts | `dry-run` output, `commands.log` |
