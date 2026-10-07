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
