# Why apps roll back — the catalogue (keep it current; read it before every env)

Every rollback so far had one of the causes below. For each: what you see in the app log or the
tool output, what it really is, how to spot it **before** the wave, what fixes it and who, and what
the tool does on its own. Add a row the day a new one appears; do not retell one that is here.

Symptoms the tool prints are the same for most of them — `restart failed: instances 0/1 after 300s`
→ `ROLLBACK service …` — so the app's own log (`cf logs <app> --recent`, or the syslog drain) is what
tells them apart. Nothing in this file names a client app, service or library.

| # | Signature in the app log | Cause | Seen before the wave? | Fix / owner | Tool |
|---|---|---|---|---|---|
| 1 | Node/ioredis: `TypeError [ERR_MISSING_ARGS]: The "options" or "port" or "path" argument must be specified` at `Socket.connect` right after start | App selects its binding by **label** through an env var (`REDIS_SERVICE=redis` → `VCAP_SERVICES.redis[0]`); after the rebind the label is `valkey`, the lookup is empty, the client gets no host/port | **yes** — `static_ref: env-key` in the report (discovery ≥ `b172ad6`); the plan marks it hazard → hazard wave under `--isolate` | `cf set-env <app> <var> valkey` before its wave (apply's restart picks it up); set it back by hand if it rolls back. Owner: platform, with the team's ok | detects, isolates; does not set the var |
| 2 | .NET/Newtonsoft: `System.ArgumentException: Accessed JArray values with invalid key value: "host"` from a shared cache library's `Add…Redis` extension during `ConfigureServices` | The same label lookup, **hard-coded in a shared library** the app links; nothing in the app's env or manifest shows it | **no** by scan. Size the class by buildpack (`hwc`/`dotnet_core`/`binary` on a Windows or .NET stack) over the bound apps; ask the library owners which lookup it does | Library accepts label `valkey` (or selects by tag `redis`, which the Valkey offering carries) and every consuming app is rebuilt. Owner: the library's team. Until then: hazard wave, stays on Redis | no detection yet (`--hazard-buildpacks` proposed) |
| 3 | After the **rollback**: `ReplyError: WRONGPASS invalid username-password pair or user is disabled` on the **Redis**, binding password ends in `\r` | Not the app. The broker's Vault copy of the Redis password carried a CR (instances re-imported by hand from Windows after a Vault refresh); every *new* binding — which is what rollback makes — renders it; the old binding was clean | **yes** — `safe paths secret/ \| grep '/redis/system$'` loop → CR count per instance, on the Blacksmith VM; one scratch-app bind to an imported Redis proves rollback | Strip the CR in every affected secret, `monit restart blacksmith` once (spruce caches Vault reads per process), rebind the apps that got a binding after the import. Owner: platform. `knowledge/blacksmith/bind-password-cr-spruce-cache.md` | rollback itself succeeds (names back, rebound, restarted); the app dies afterwards — check `cf app` after every rollback in an imported env |
| 4 | `restart SKIPPED: app is 0/1 RUNNING before the wave -- rebind only` and `verified (bindings only)` | App was already down or crash-looping before the wave (often cause 3 from an earlier rollback, or a long-dead app) | **yes** — preflight WARN/FAIL `app …: r/n RUNNING before the wave`; `cf events` shows crashes before the wave's first ledger timestamp | Team restarts it on the Valkey later; or `cf stop` it before the wave. Not a rollback by itself | rebinds, does not restart, counts it verified (bindings only); another app of the **same service** failing rolls this one back too |
| 5 | Bind step fails: broker answers the instance is not found / `Instance has been deleted`, service rolls back before any restart | **Hollow Valkey**: CF says `create succeeded`, BOSH has no deployment, the broker has no index line — the hourly no-deployment sweep deleted it while the create waited (Blacksmith write pool of 4, or a queued director task) | **yes** — `provision-check` → `HOLLOW` (BOSH half); preflight refuses a wave without a clean provision-check line | Purge from CF (`cf curl -X DELETE '/v3/service_instances/<g>?purge=true'`), `provision --wave N` again. Prevent: `max_connections` 16 on the broker, `provision --max-inflight 15`, no broker/director restart mid-provisioning. `knowledge/blacksmith/hollow-valkey-orphan-sweep.md` | provision-check + the preflight gate keep it out of apply |
| 6 | `verify fail`: instances running, but the Valkey binding is absent or the Redis binding still present | A bind/unbind job that CF reported done but did not land (API hiccup) | no | Re-run `apply --wave N --service <guid8>`; the ledger redoes the pair | automatic rollback, resumable |

## The three questions for a new one

1. **Was the app healthy before the wave?** `cf events <app>` — crashes before the wave's first
   ledger timestamp mean cause 4, whatever the log says afterwards.
2. **Did it die on the Valkey binding or on the Redis binding?** The crash timestamp against the
   ledger's `bind`/`restart`/`rollback` events; a crash *after* `rollback ok` is cause 3-shaped,
   not an app problem.
3. **How does the app find its store?** Label (causes 1, 2 — breaks), instance name or tag (works).
   `cf env <app>` shows the label; the code or the team tells the lookup.

## Operational pitfalls that are not app causes but produced rollbacks or near-misses

- `--service <name>` matching two same-named services in two spaces (shared instance) — both were
  migrated. Guarded since `2ae2131`: use the guid prefix.
- A halt (STOP / Ctrl-C) inside the `--max-inflight` gate on `apply` left a Redis under its standby
  name until `8e4329f` — now recorded "not issued: halted" and renamed back.
- The Valkey offering must carry tag `redis` (`service.tags` on the forge; ext/int do) or every
  tag-based client (Spring/java-cfenv) becomes cause 2 by another route.
