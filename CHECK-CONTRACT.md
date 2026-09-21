# The `/check` contract

Every simulation app — Python, Spring, .NET — exposes `GET /check` returning this JSON. The
verifier and the report are written against this contract only; an app is "done" when its
`/check` satisfies it.

`GET /healthz` always returns 200 (used as the CF health check) so a **failing app stays up
and keeps reporting** instead of being restarted by the platform.

## Common fields (all modes)

| field | type | meaning |
|---|---|---|
| `app` | string | CF app name (from `VCAP_APPLICATION`) |
| `instance` | int | CF instance index |
| `mode` | string | `cache` / `session` / `store` / `producer` / `consumer` / `lock` |
| `expects` | string | free label from `SIM_EXPECTS` (e.g. `cf-bind`, `pinned-hazard`) — report readability only |
| `source` | string | where credentials came from: `vcap:<service-name>` / `env` / `ups:<name>` |
| `auth_style` | string | `password` (one-arg AUTH) or `username` (user + pw when username present) |
| `endpoint` | string | `host:port` actually connected to |
| `connected` | bool | a live round-trip succeeded during this check |
| `server` | string | `valkey` if `INFO server` has `valkey_version`, else `redis`, else `unknown` |
| `version` | string | that version string |
| `auth_user` | string | `ACL WHOAMI` result, or `n/a` (command renamed/unsupported) |
| `roundtrip_ms` | number | SET/GET/DEL of a nonce, milliseconds (null if failed) |
| `error` | string | last error text if `connected=false` |
| `families` | object | command-family smoke: `{string, hash, list, zset, eval, multi, stream, pubsub}` → `ok` / error text |
| `canary` | object | `{key, written_at, present}` — a key written at FIRST start with a timestamp; deterministic name so it survives app restarts; `present=true` after cutover means the data was copied |
| `since_start` | object | `{ops, errors, reconnects, started_at}` — counters since the process started |
| `latency_ms` | object | `{p50, p99}` over the last 200 worker operations |
| `mode_data` | object | mode-specific block below |

Ground truth is always **self-generated and deterministic** from `(app name, SIM_SEED)`, so an
app can verify itself after a restart with no memory of its previous life.

## Mode-specific `mode_data`

**cache** — read-through cache with TTL over a rotating key range.
`{keys: N, hits, misses, sampled, correct}` · **pass**: `correct == sampled` (values match the
deterministic computation) and `connected`. After cutover: `misses` spike then `hits` recover.

**session** — mints a deterministic session token at first start and keeps it refreshed.
`{token_key, present, ttl_s}` · **pass (copied)**: `present=true` across cutover;
**pass (not copied)**: `present=false` immediately after, `true` again once re-minted —
the report shows which happened.

**store** — N deterministic keys (`store:<app>:<i>`), never overwritten if present.
`{expected, found, checksum_ok, missing_sample}` · **pass**: `found == expected` and
`checksum_ok`. Anything else after cutover = data loss, quantified.

**producer** — pushes `{seq, ts}` to a list, `seq` from a Redis counter.
`{queue, last_seq, pushed}` · **pass**: `pushed` still increasing after cutover.

**consumer** — pops from that list, verifies continuity.
`{queue, last_seq, consumed, gaps, duplicates}` · **pass**: `gaps == 0 && duplicates == 0`
across the cutover (with data copy); without copy the report quantifies the loss.

**lock** — instances compete for `SET NX EX`; the winner "runs a job" and increments a
per-window counter. `{acquired, jobs_run, double_exec}` · **pass**: `double_exec == 0`
across cutover (lock state lost at switch is the failure this detects).

## Pass criteria the verifier applies after migration (per app)

1. **switched** — `endpoint` ≠ baseline endpoint **and** `server == valkey` *(except the
   deliberate hazard apps, whose expectation is the opposite — see scenario tables)*.
2. **functional** — `connected` and every family the mode uses reports `ok`.
3. **data** — the mode's pass rule above.
4. **behavior** — `since_start.errors` stops increasing; `reconnects` ≤ 1 per restart;
   `latency_ms.p99` within 2× baseline.
5. **continuity** — measured from the poll timeline: seconds with `connected=false` per app.

## Configuration (env vars)

| var | values | default |
|---|---|---|
| `SIM_MODE` | cache/session/store/producer/consumer/lock | cache |
| `SIM_SOURCE` | vcap / env / ups | vcap |
| `SIM_SERVICE_NAME` | pick a specific bound service (multi-bind apps) | first match |
| `SIM_AUTH` | password / username | username |
| `SIM_EXPECTS` | free label | "" |
| `SIM_SEED` | int | 1 |
| `SIM_KEYS` | dataset/keyspace size | 1000 (store) / 200 (cache) |
| `SIM_INTERVAL_MS` | worker loop period | 250 |
| `SIM_QUEUE` | queue name (producer/consumer) | `queue:sim` |
| `REDIS_HOST/PORT/PASSWORD/USERNAME` | used when `SIM_SOURCE=env` | — |
