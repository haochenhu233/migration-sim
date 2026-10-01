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

### 8c — migrate WITH a data copy (only if a copy mechanism exists; otherwise skip)

Copy first (e.g. `redis-cli --rdb` / `DUMP`+`RESTORE` per key / replication — whatever the
platform offers), then the four steps, then:
```bash
bash verify/snapshot.sh store-copy
f=$(ls -t verify/data/*store-copy.jsonl | head -1)
jq -r 'select(.mode=="store") | [._app, .server, .canary.survived_restart, .canary.written_at, .mode_data.seeded_at_start, .mode_data.checksum_ok] | @tsv' "$f"
```
Pass: `valkey`, `survived_restart=true` (original timestamp), `seeded_at_start=0`, `checksum_ok=true`.

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

```bash
APP=sim-pipeline-b
cf bind-service $APP sim-valkey-pipe-a && cf unbind-service $APP sim-redis-pipe-a && cf restart $APP
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
cf bind-service $APP sim-valkey-pipe-a && cf unbind-service $APP sim-redis-pipe-a && cf restart $APP
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
