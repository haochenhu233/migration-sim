# Tool-test population — reset & verify (SBX)

The migration tool is tested against the existing 14 sim apps and 6 Redis services, rebound
into the shapes the real plan showed (shared service, data-sharing group, multi-service chain,
silent service, data-store service, hazard, Windows). `scripts/reset-population.sh` rebuilds
that state from whatever a previous test left behind. Run it before every tool test.

## What the reset does (`scripts/reset-population.sh`)

1. **Unbind everything** — every `sim-*` app is unbound from every `sim-*` service it is bound
   to (read from its `VCAP_SERVICES`). The UPS `sim-ups-redis` is left alone (its own path).
2. **Delete all Valkey instances** named `sim-*` — the twins from the theory validation and the
   Valkey that took the name `sim-redis-cache` in S7. The tool must create Valkeys itself under
   the original names, so they must not exist and their IPs must be free. Waits for deletions.
3. **Rename standbys back** — `sim-redis-<x>-redis-standby` → `sim-redis-<x>`. The Redis
   deployments, data and GUIDs are untouched; only the names return to the pre-migration state.
4. **Bind per `scripts/layout.tsv` and set states** — started apps are restarted to pick up
   their bindings; `sim-session-bound` is **stopped** (a bound, non-running app = a silent
   service); `sim-bound-pinned` gets `SIM_SOURCE=env` back (the hazard).

5. **Re-point the credential-copy apps** — `sim-static-env` (env), `sim-bound-pinned` (env) and
   `sim-ups` (UPS) get `sim-redis-cache`'s current host/password from a service key, so the
   whole population starts on Redis.

Not touched: the apps (no push), Redis data. Idempotent — safe to re-run.

**After the reset:** `cf services | grep valkey` must print nothing — the script stops with an error if any `sim-*` Valkey survives the deletion wait.

## The layout (`scripts/layout.tsv`)

| app | bound to | state | plays |
|---|---|---|---|
| sim-cache-bound, sim-username-aware, sim-password-only, sim-win-bound | sim-redis-cache | started | the big shared service (incl. Windows) |
| sim-bound-pinned | sim-redis-cache | started | **hazard** — preflight must refuse the cache wave until its env is cleared |
| sim-producer, sim-consumer, sim-lock | sim-redis-queue | started | data-sharing group (service-scope rollback) |
| sim-pipeline-a | sim-redis-pipe-a **and** sim-redis-pipe-b | started | multi-bound app → ONE restart per wave |
| sim-pipeline-b | sim-redis-pipe-a | started | completes the 2-service / 2-app chain |
| sim-store-bound | sim-redis-store | started | data-store service → add `datastore` to its flags in `waves.tsv` by hand |
| sim-session-bound | sim-redis-session | **stopped** | silent service → rebind only, no restart, stays stopped |

## Run

```bash
cd ~/ocfp/migration-sim && git pull
bash scripts/reset-population.sh                       # ~5 min; prints each step
cf services | grep -E '^sim-redis'                     # 6 Redis, bound apps as in the layout, NO sim-valkey-*
bash verify/apps-list.sh && bash verify/snapshot.sh tool-baseline
```
Expect in the snapshot: every started app on `redis` (`AUTH_USER=n/a`), `sim-session-bound`
not answering (stopped — correct), `sim-bound-pinned` with `SOURCE=env`.

## Build the plan for this population

```bash
# discovery scan of SBX (also re-validates the toolkit on the sim apps)
cd ~/ocfp/redis-consumer-discovery
bash redis-consumer-discovery.sh run        <sbx-env> --path ./sbx-tool
bash redis-consumer-discovery.sh scan-apps  <sbx-env> --path ./sbx-tool
bash redis-consumer-discovery.sh list-redis <sbx-env> --path ./sbx-tool
bash redis-consumer-discovery.sh scan-ups   <sbx-env> --path ./sbx-tool    # sim-ups: unknown -> static-ref: ups
bash redis-consumer-discovery.sh merge      <sbx-env> --path ./sbx-tool

cd ~/ocfp/migration-sim
# --services: the scan covers the WHOLE foundation -- other teams' SBX Redis (healthcheck, old tests)
# would otherwise land in wave 1; scope the plan to ours
bash migrate/migrate.sh plan ~/ocfp/redis-consumer-discovery/sbx-tool/merged_report.csv --run runs/sbx --wave-size 3 --services '^sim-redis-'
# mark the data-store service: append  datastore  to the flags column of the sim-redis-store row in runs/sbx/waves.tsv
cat runs/sbx/plan-summary.md
```
Expect: 6 services, 12 connections, 1 silent service (session), one 2-service component,
one 5-app shared service, 1 hazard, 1 Windows app, ~5 waves with the silent one first.
`sim-static-env` and `sim-ups` show under `sim-redis-cache` with flags `no-binding:static-ref-env-var`
/ `no-binding:static-ref-ups` (`unknown` for sim-ups if `scan-ups` was not run):
the census found them (correct), but they have no binding, so dry-run/apply print `SKIP … TEAM
ACTION` for them -- exactly what the real migration does for static-ref / UPS consumers.

## Then the tool

```bash
bash migrate/migrate.sh preflight --wave 1 --run runs/sbx --free-ips 6
bash migrate/migrate.sh dry-run   --wave 1 --run runs/sbx
```
Preflight: clean on wave 1 except a WARN for the stopped app (handled as rebind-only); the
cache wave must FAIL on `sim-bound-pinned` until `cf set-env sim-bound-pinned SIM_SOURCE vcap`
(the team-side fix), then pass. Dry-run prints exactly what `apply` will execute.

## After a test

`bash scripts/reset-population.sh` again. Every tool test starts from the same baseline.

## Then apply — wave 1 first (one silent service, one stopped app)

```bash
cd ~/ocfp/migration-sim && git pull
# apply = preflight gate -> "type yes" -> lock -> rename -> create valkey (job) -> bind -> unbind -> (no restart: STOPPED) -> verify L1
bash migrate/migrate.sh apply --wave 1 --run runs/sbx
bash migrate/migrate.sh status --wave 1 --run runs/sbx
cf services | grep -i session            # sim-redis-session (valkey) + sim-redis-session-redis-standby (redis)
cf service sim-redis-session             # bound apps: sim-session-bound
cf start sim-session-bound && sleep 20 && curl -s https://<sim-session-bound route>/check | jq '.source, .connected'   # picks up the valkey
cf stop sim-session-bound                # back to the layout
```
Paste: the apply output, `status --wave 1`, and the `cf services` lines.

Wave 2 needs two things first: the hazard app's env cleared (`cf unset-env sim-bound-pinned
REDIS_HOST` + `REDIS_PASSWORD`, restart) -- preflight refuses until then -- and a copy-data hook
for the store service (`runs/sbx/copy-data.sh <standby_guid> <valkey_guid> <name>`, exit 0 =
copied; without it apply asks on the terminal). Rehearse the lane model: wave 2 and wave 3 in two
terminals at once (`--wave 2` and `--wave 3`), then `status` shows both.

**Done in SBX 2026-10-09:** wave 1 (3 min 17 s, rebind-only on the STOPPED app, `/check` =
valkey 8.1.8), wave 2 (3 Valkeys provisioned concurrently in ~3 min, 8 apps in 7.5 min; store
parked on the datastore decision, 2 apps handed to the team), wave 3 (5 min). Found and fixed on
the way: the copy-data prompt tested the loop's stdin instead of the tty; team-action apps held a
service in MIGRATING; hazard footer ignored progress.

## Then the rest of the lifecycle — rollback (scenario 11), confirm, retire (scenario 12)

```bash
# 11 -- timed rollback of one service: every app of it back on the standby (rebind redis, unbind
#       valkey, restart only the ones that had been restarted). The valkey is kept.
time bash migrate/migrate.sh rollback --wave 2 --service sim-redis-cache --reason "scenario 11" --run runs/sbx
bash migrate/migrate.sh status --wave 2 --run runs/sbx      # phase ROLLED-BACK, apps 0/5
curl -s https://<sim-cache-bound route>/check | jq '.server, .source'        # redis again, canary from Sept 30 intact
#       --app <name> rolls back ONE app (recorded as an override); re-migrate = apply the same wave/service
bash migrate/migrate.sh apply --wave 2 --service sim-redis-cache --run runs/sbx   # redoes bind/unbind/restart/verify after the rollback

# confirm -- the app team's sign-off; refuses unless every tool app of the service is VERIFIED
bash migrate/migrate.sh confirm --wave 2 --service sim-redis-cache --by "cache team" --grace 1h --run runs/sbx   # NP/PD: default 336h = 14 d
bash migrate/migrate.sh status --wave 2 --run runs/sbx      # phase STANDBY, standby-until = confirm + grace

# 12 -- retire: refuses before confirm, before the grace ends (--force overrides, recorded), if the
#       standby's name drifted, if any binding/key is still on it, and without a census of who is
#       still connected: a runs/sbx/retire-census.sh <standby_guid> <name> hook (exit 0 = nobody),
#       or --no-census after you checked by hand (CLIENT LIST on the standby VM). Asks twice.
bash migrate/migrate.sh retire --wave 2 --service sim-redis-cache --no-census --run runs/sbx
bash migrate/migrate.sh status --run runs/sbx               # retired 1/6; then watch the IP come back (bosh deployments / cloud-config)
```

Offline rehearsal of the same thing (no CF): `migrate/test/cf-fake` is a stateful fake CF —
`CFFAKE_STATE=/tmp/s.json migrate/test/cf-fake seed runs/sbx/waves.tsv`, then
`CF_CMD=$PWD/migrate/test/cf-fake JOB_POLL=0 SOAK=0 bash migrate/migrate.sh apply --waves 1-3 --run <copy of runs/sbx> --yes`.
Failure injection: `CFFAKE_FAIL_CREATE=<svc name>`, `CFFAKE_CRASH=<app guid>`, `CFFAKE_BIND_FAIL=<app guid>`,
`CFFAKE_STOPPED=<app guid>` (at seed), `CFFAKE_INSTANCES=<guid>=3`, `runs/<x>/verify-hook.sh` exit 1.

