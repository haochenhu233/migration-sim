# SBX session — copy-paste command blocks (continues after the cache-service apps)

All blocks run from `~/ocfp/migration-sim` in terminal B, with `bash verify/poll.sh 3 <label>`
running in terminal A. Each block ends with a snapshot; keep the labels. Where a block prints
`jq` output, paste that output back.

---

## 6. Queue service — producer, consumer, lock move TOGETHER

Why: the three apps share data through `sim-redis-queue` (the list, the seq counter, lock
keys). A partial move splits the group across two stores: every app still says `connected`,
yet the consumer starves. This is the evidence for "rollback unit = service".

### 6a — deliberately move ONLY the producer, watch the consumer starve

```bash
APP=sim-producer
cf bind-service $APP sim-valkey-queue && cf unbind-service $APP sim-redis-queue && cf restart $APP
sleep 30
bash verify/snapshot.sh queue-split
f=$(ls -t verify/data/*queue-split.jsonl | head -1)
jq -r 'select(.mode=="consumer" or .mode=="producer") | [._app, .server, (.mode_data|tostring)] | @tsv' "$f"
```
Expect: producer on `valkey` with `queue_len` growing; consumer on `redis`, `consumed` frozen.

### 6b — complete the group (consumer + lock)

```bash
for APP in sim-consumer sim-lock; do
  cf bind-service $APP sim-valkey-queue && cf unbind-service $APP sim-redis-queue && cf restart $APP --strategy rolling
done
sleep 30
bash verify/snapshot.sh after-queue
f=$(ls -t verify/data/*after-queue.jsonl | head -1)
jq -r 'select(.mode=="consumer" or .mode=="lock") | [._app, .server, (.mode_data|tostring)] | @tsv' "$f"
```
Read: consumer `duplicates` jumps (the seq counter restarted at 1 on the empty Valkey) and
`gaps` = messages stranded on the old Redis → a queue needs a data copy or a drained queue at
cutover. lock `double_exec > 0` (or two instances on one window in `runs`) → with a ROLLING
restart, instances briefly hold "the lock" on different stores → lock-based apps should be
restarted non-rolling or tolerate duplicates.

## 7. Read the downtime meter

```bash
# terminal A: Ctrl-C the poller first
f=$(ls -t verify/data/*wave-cache.jsonl | head -1)
echo "polls: $(grep -c . "$f")"
jq -r 'select(.connected==false) | ._app' "$f" | sort | uniq -c | awk '{printf "%-22s ~%ds down\n", $2, $1*3}'
echo "--- errors / reconnects per app (self-counted) ---"
f=$(ls -t verify/data/*after-queue.jsonl | head -1)
jq -r '[._app, .since_start.errors, .since_start.reconnects] | @tsv' "$f" | column -t
```
No lines after `polls:` = no poll ever caught an app disconnected. Resolution = 3 s.
Restart the poller for the next blocks: `bash verify/poll.sh 3 wave-2`

## 8. Store service — measure the loss, then (if possible) copy

Why: a data-store app's values are the only copy. Migrating it like a cache loses them;
the probe quantifies exactly how much.

### 8a — migrate WITHOUT copying data (the naive migration)

```bash
APP=sim-store-bound
cf bind-service $APP sim-valkey-store && cf unbind-service $APP sim-redis-store && cf restart $APP
sleep 30
bash verify/snapshot.sh store-nocopy
f=$(ls -t verify/data/*store-nocopy.jsonl | head -1)
jq -r 'select(.mode=="store") | [._app, .server, .canary.survived_restart, .canary.written_at, .mode_data.seeded_at_start, .mode_data.checksum_ok] | @tsv' "$f"
```
Read it as: **`survived_restart=false` + `seeded_at_start=1000`** = the store was EMPTY when
the app came up: the old data did not survive (expected without a copy). The probe re-creates
its deterministic dataset on start, so `found`/`checksum_ok` go green again within seconds —
those say the app works, not that data survived. (`survived_restart=true` +
`seeded_at_start=0` is what a successful copy looks like.)

### 8b — roll back (Redis never touched → canary present again)

```bash
APP=sim-store-bound
cf bind-service $APP sim-redis-store && cf unbind-service $APP sim-valkey-store && cf restart $APP
sleep 30
bash verify/snapshot.sh store-rollback
f=$(ls -t verify/data/*store-rollback.jsonl | head -1)
jq -r 'select(.mode=="store") | [._app, .server, .canary.survived_restart, .canary.written_at, .mode_data.seeded_at_start] | @tsv' "$f"
```
Expect: `redis`, `survived_restart=true` with the ORIGINAL (Sept 30) timestamp,
`seeded_at_start=0` — nothing was lost on the standby side.

### 8c — migrate WITH a data copy

Three copy methods, best first. Which ones work depends on the Redis hardening
(`rename-command`), so check that first — on the REDIS VM:

```bash
genesis @<env> b -d <redis-store-deployment> ssh           # the sim-redis-store VM
sudo grep -hiE 'rename-command' /var/vcap/jobs/*/config/* | sort -u   # look for SYNC/PSYNC/MIGRATE/CONFIG
RC=$(ls /var/vcap/packages/*redis*/bin/redis-cli | head -1); RPW=$(sudo grep -h '^requirepass' /var/vcap/jobs/*/config/*.conf | awk '{print $2}')
$RC -a "$RPW" --no-auth-warning DBSIZE                      # the number the copy must reproduce
```
Hostnames/passwords for both services come from `cf service-key sim-redis-store k` /
`cf service-key sim-valkey-store k` (classic plan: the password IS the requirepass).

**Method 1 — live replication (preferred: exact, keeps TTLs, no files).** The Valkey becomes
a temporary replica of the Redis, syncs the full dataset, then is promoted. Needs `PSYNC`
not renamed on the Redis and `CONFIG` available on the Valkey. Do this BEFORE binding apps
(a replica is read-only). On the VALKEY VM:

```bash
genesis @<env> b -d <valkey-store-deployment> ssh
VC=$(ls /var/vcap/packages/*valkey*/bin/valkey-cli | head -1); VPW=$(sudo grep -h '^requirepass' /var/vcap/jobs/*/config/*.conf | awk '{print $2}')
$VC -a "$VPW" --no-auth-warning CONFIG SET masterauth '<redis-password>'
$VC -a "$VPW" --no-auth-warning REPLICAOF <redis-host> 6379
# wait until synced:
$VC -a "$VPW" --no-auth-warning INFO replication | grep -E 'master_link_status|master_sync_in_progress'   # up / 0
$VC -a "$VPW" --no-auth-warning DBSIZE                      # == the Redis DBSIZE
$VC -a "$VPW" --no-auth-warning REPLICAOF NO ONE            # promote: Valkey is now its own primary, data kept
$VC -a "$VPW" --no-auth-warning CONFIG SET masterauth ''
```
If `master_link_status` stays `down` → the Redis refuses replication (PSYNC renamed) → Method 2.

**Method 2 — server-to-server `MIGRATE` (per key, atomic, source kept with COPY).** Needs
`MIGRATE` not renamed on the Redis and network Redis VM → Valkey:6379. On the REDIS VM:

```bash
$RC -a "$RPW" --no-auth-warning --scan \
 | xargs -r -n 100 sh -c '"$0" -a "$1" --no-auth-warning MIGRATE "$2" 6379 "" 0 5000 COPY REPLACE AUTH "$3" KEYS "$@"' "$RC" "$RPW" <valkey-host> '<valkey-password>'
$RC -a "$RPW" --no-auth-warning DBSIZE          # source still intact (COPY)
```

**Method 3 — DUMP/RESTORE through the bastion (always works, slowest; TTLs re-applied).**
From the bastion with a redis-cli that reaches both hosts:

```bash
SRC="redis-cli -h <redis-host> -a <redis-password> --no-auth-warning"; DST="redis-cli -h <valkey-host> -a <valkey-password> --no-auth-warning"
$SRC --scan | while read -r k; do
  ttl=$($SRC PTTL "$k"); [ "$ttl" -lt 0 ] && ttl=0
  $SRC --no-raw DUMP "$k" >/dev/null 2>&1   # (sanity)
  $SRC DUMP "$k" | $DST -x RESTORE "$k" "$ttl" REPLACE >/dev/null
done
$DST DBSIZE
```

**Then the four steps and the verdict:**
```bash
APP=sim-store-bound
cf bind-service $APP sim-valkey-store && cf unbind-service $APP sim-redis-store && cf restart $APP
sleep 30
bash verify/snapshot.sh store-copy
f=$(ls -t verify/data/*store-copy.jsonl | head -1)
jq -r 'select(.mode=="store") | [._app, .server, .canary.survived_restart, .canary.written_at, .mode_data.seeded_at_start, .mode_data.checksum_ok] | @tsv' "$f"
```
Pass: `valkey`, `survived_restart=true` with the **Sept 30** timestamp, `seeded_at_start=0`,
`checksum_ok=true` — the dataset moved intact. Record which method worked: that becomes the
migration tool's `copy-data` step, and the hardening check becomes a preflight item.

## 9. Session service

```bash
APP=sim-session-bound
cf bind-service $APP sim-valkey-session && cf unbind-service $APP sim-redis-session && cf restart $APP --strategy rolling
sleep 30
bash verify/snapshot.sh after-session
f=$(ls -t verify/data/*after-session.jsonl | head -1)
jq -r 'select(.mode=="session") | [._app, .server, .canary.survived_restart, (.mode_data|tostring)] | @tsv' "$f"
```
Read: `reminted=1` and `canary.survived_restart=false` → the session did NOT survive
(users would log in again). With a copy it would (`reminted` unchanged, canary present).

## 10. Pipeline ordering — a → b, wrong order first

Why: `sim-pipeline-a` produces into `pipe-a`; `sim-pipeline-b` consumes from `pipe-a`.
(Both apps are bound to pipe-a AND pipe-b to simulate a two-service app.)

### 10a — wrong order: migrate the consumer's service first... by moving only app b

NOTE: the pipeline apps select their binding BY NAME (`SIM_SERVICE_NAME=sim-redis-pipe-a`) —
like a real multi-service app. After the rebind that name no longer exists, so the app exits
at restart ("no credentials found") until the name is updated. This is the naming-policy-B
cost, live. The `set-env` below is the team-side fix.

```bash
APP=sim-pipeline-b
cf bind-service $APP sim-valkey-pipe-a && cf unbind-service $APP sim-redis-pipe-a
cf set-env $APP SIM_SERVICE_NAME sim-valkey-pipe-a && cf restart $APP
sleep 30
bash verify/snapshot.sh pipe-wrong
f=$(ls -t verify/data/*pipe-wrong.jsonl | head -1)
jq -r 'select(._app|startswith("sim-pipeline")) | [._app, .server, (.mode_data|tostring)] | @tsv' "$f"
```
Expect: b on `valkey` consuming nothing; a still producing onto Redis → messages pile up on
the old side. The "break".

### 10b — right order: move the producer too, then check continuity

```bash
APP=sim-pipeline-a
cf bind-service $APP sim-valkey-pipe-a && cf unbind-service $APP sim-redis-pipe-a
cf set-env $APP SIM_SERVICE_NAME sim-valkey-pipe-a && cf restart $APP
sleep 30
bash verify/snapshot.sh pipe-right
f=$(ls -t verify/data/*pipe-right.jsonl | head -1)
jq -r 'select(._app|startswith("sim-pipeline")) | [._app, .server, (.mode_data|tostring)] | @tsv' "$f"
```
Read: `gaps`/`duplicates` on b = the cost of the wrong order (stranded + restarted seq).
Then migrate both apps' second binding (pipe-b) the same way for completeness.

## 11. Rollback — timed

```bash
date +%T
APP=sim-cache-bound
cf bind-service $APP sim-redis-cache && cf unbind-service $APP sim-valkey-cache && cf restart $APP --strategy rolling
sleep 20
bash verify/snapshot.sh rollback-cache
date +%T
```
Expect: `sim-cache-bound` back on `redis`. The two `date` lines = the rollback time. Then put
it back on Valkey (the four steps again) so the end state is "migrated".

## S7. The real naming sequence — rename FIRST, create the Valkey under the original name

Decided sequence for the real migration (policy A): the old Redis is renamed to
`<name>-redis-standby` while its apps are still bound and running; the Valkey is created
under the ORIGINAL name; then each app is re-bound and restarted. Apps, manifests, pipelines
and name-selecting code never see a new name. Rehearse it on `sim-redis-pipe-b`, the one
service whose bindings are still untouched (both pipeline apps are bound to it).

### S7a — rename the Redis out of the way (apps keep running on it)

```bash
cf services | grep '^sim-redis-pipe-b '                           # bound: sim-pipeline-a, sim-pipeline-b
cf rename-service sim-redis-pipe-b sim-redis-pipe-b-redis-standby
bash verify/snapshot.sh s7-renamed                                 # pipeline apps unchanged (they use pipe-a; pipe-b binding intact)
```

### S7b — the Valkey is born with the original name

A twin called `sim-valkey-pipe-b` already exists from step 2; in the real migration the
Valkey is CREATED with the final name. Either is equivalent for the test — pick one:
```bash
cf rename-service sim-valkey-pipe-b sim-redis-pipe-b              # reuse the existing twin
# -- or, the real thing (takes a few minutes): cf delete-service sim-valkey-pipe-b -f; cf create-service valkey <classic-plan> sim-redis-pipe-b
cf services | grep '^sim-redis-pipe-b '                            # offering: valkey, no bound apps yet
```

### S7c — move the apps (the four steps, against the ORIGINAL name)

```bash
for APP in sim-pipeline-a sim-pipeline-b; do
  cf bind-service $APP sim-redis-pipe-b && cf unbind-service $APP sim-redis-pipe-b-redis-standby && cf restart $APP
done
sleep 30; bash verify/snapshot.sh s7-migrated
cf services | grep -E '^sim-redis-pipe-b'                          # Valkey has both apps; standby has none
```
(The pipeline apps still select `pipe-a` by `SIM_SERVICE_NAME`; their pipe-b binding moved
underneath them — the snapshot proves nothing broke.)

### S7d — the stale-manifest push: an UNCHANGED manifest binds the Valkey

`access-variants.yml` still says `services: [sim-redis-pipe-a, sim-redis-pipe-b]` — with pipe-a
already renamed in S7 of the cache-style swap, or untouched, it resolves either way:
```bash
cf unbind-service sim-pipeline-b sim-redis-pipe-b
cd apps/sim-go && cf push sim-pipeline-b -f manifests/access-variants.yml && cd ../..
cf services | grep '^sim-redis-pipe-b '                            # sim-pipeline-b bound again -- to the Valkey
bash verify/snapshot.sh s7-stale-push
```
Pass: the push needed no manifest edit; the binding it created is to the Valkey. The
standby Redis has a name no manifest references.

### S7e — rollback under this naming (names end up crossed; swap back only if abandoning)

```bash
APP=sim-pipeline-a
cf bind-service $APP sim-redis-pipe-b-redis-standby && cf unbind-service $APP sim-redis-pipe-b && cf restart $APP
bash verify/snapshot.sh s7-rollback                                 # app back on redis; service names unchanged
# to ABANDON the migration for this service entirely:  rename valkey away, rename standby back
#   cf rename-service sim-redis-pipe-b sim-redis-pipe-b-valkey; cf rename-service sim-redis-pipe-b-redis-standby sim-redis-pipe-b
```

## 12. Standby → retire one Redis (IP recycling check)

```bash
cf services | grep sim-redis-cache            # bound apps: should be only sim-static-env? (if not moved) else none
cf delete-service sim-redis-cache -f          # refuses while bindings exist -- that refusal IS the standby guard
bash verify/snapshot.sh after-retire          # every app that was on sim-valkey-cache: unchanged
```
Expect: apps on Valkey don't notice; the Redis's service-network IP is free again.

## Results table (fill as you go)

| block | app(s) | switched? | works? | data / counters | downtime s | notes |
|---|---|---|---|---|---|---|
| 6a queue split | producer only | | | consumer frozen? | | |
| 6b queue group | consumer, lock | | | dups / gaps / double_exec | | rolling vs lock |
| 7 downtime | all | | | | | |
| 8a store no-copy | store | | | canary present? | | |
| 8b store rollback | store | | | canary present? | | |
| 8c store copy | store | | | checksum_ok / canary | | |
| 9 session | session | | | reminted / canary | | |
| 10a/10b pipeline | a, b | | | gaps / dups | | |
| 11 rollback | cache | | | | | minutes: |
| 12 retire | cache redis | | | | | IP freed? |
