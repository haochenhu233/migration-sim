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
| `sim-cache-bound` | cf-bind | cache | happy path: endpoint switch, `server=valkey`, cache refills | [ ] |
| `sim-session-bound` | cf-bind | session | session continuity (or clean re-login) across cutover | [ ] |
| `sim-store-bound` | cf-bind | store | data-copy correctness via checksum | [ ] |
| `sim-producer` / `sim-consumer` | cf-bind (same Redis) | queue | gapless sequence: lost/duplicated messages counted | [ ] |
| `sim-lock` | cf-bind | lock | double-execution count during switch | [ ] |
| `sim-bound-pinned` | cf-bind + pinned `REDIS_HOST` | cache | THE hazard: still reports the OLD endpoint after migration | [ ] |
| `sim-static-env` | env var only | cache | manual-update path | [ ] |
| `sim-ups` | user-provided service | cache | UPS update + restage path | [ ] |
| `sim-keyuser` | service key (task/script) | — | keys don't migrate | [ ] |
| `sim-password-only` | cf-bind, `AUTH <pw>` | cache | classic OK / secure WRONGPASS — the plan-decision evidence | [ ] |
| `sim-username-aware` | cf-bind, uses `username` | cache | secure opt-in path, `auth_user` = binding id | [ ] |
| `sim-pipeline` | bound to Redis A **and** B, moves data A→B | store | ordering: breaks if A/B migrate in wrong order | [ ] |
| `sim-batch` | cf-bind, connects on schedule (CF task) | store | idle ≠ exempt: first reconnect lands on Valkey | [ ] |
| `sim-spring-*` | cf-bind | cache + session | real Java stack | [ ] |
| `sim-win-bound` | cf-bind, Windows | cache | same story on Windows | [ ] |
| `sim-tls-bound` | cf-bind, connects on `tls_port` (16379) | cache | TLS consumers: Valkey target must be a TLS plan + cert trusted (found in NP: a real app uses 16379) | [ ] |

## Phase 2 — realistic population (~100+ live connections)

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

**3b. The CLI (`migrate/migrate.sh`) — in this order**
- [ ] `plan` → `waves.yml` from the merged report (pipeline pairs together, hazards + data-store flagged)
- [x] `status` = project summary (per wave + TOTAL, %, progress bar) + snapshot files; `status --wave N` = wave detail; corruption-tolerant parser; 50k-line ledger renders in 0.7 s (measured)
- [x] (was:) `status` dashboard working on `migrate/example/` (phases, switched/verified, standby clock, last event, attention list, hazard warning); `watch -n 3 -c migrate.sh status --wave N`
- [ ] `preflight --wave N` incl. blast-radius line; lock file
- [ ] `dry-run --wave N` with rollback row per step
- [ ] `apply` — idempotent, ledger-driven, STOP file, Ctrl-C safe, rolling restart for ≥2 instances, soak timer
- [ ] `verify` — L1 platform (bindings, running, crashes) · L2 network (census on Valkey: conns to Valkey, none to Redis) · L3 server-side (CLIENT LIST / ACL LOG on Valkey) · L4 logs + optional team health URL · L5 data counts; `/check` only for sim apps (DESIGN §6b)
- [ ] `rollback --app/--service/--wave` per the table
- [ ] `confirm` / `retire` (confirm + grace + double prompt)
- [ ] `report --wave N` evidence pack
- [ ] data copy for store-mode services (RDB snapshot / brief sync) + key-count verification
- [ ] rollback scope = service (auto-rollback re-binds every moved app of the service); `--scope app` override
- [ ] handles pinned-env apps (refuse in preflight), UPS, service keys (new key), multi-instance, Windows, TLS consumers (TLS plan + cert trust)

**3c. Scenarios (SBX, 6 Redis + 6 Valkey, waves of two)**
- [ ] S1 happy migration of the population in three waves
- [ ] S2 rollback: one wave back to Redis — prove "minutes", data intact on standby
- [ ] S3 **accident drill**: every row of the accident matrix, with client devops on the call
- [ ] S4 secure-plan variant: `sim-password-only` + `sim-username-aware` → WRONGPASS vs OK captured
- [ ] S5 pipeline ordering: wrong order once (prove the break), then correct
- [ ] S6 TLS consumer onto a TLS-enabled Valkey plan
- [ ] S7 name swap: rename Redis → `-redis-standby`, Valkey → original name; then `cf push` an app with its ORIGINAL manifest (`services: [<name>]`) and prove it binds the Valkey, not the Redis

## Phase 4 — verification & report

- [ ] run verifier after each scenario; produce `report/<scenario>.md`
- [ ] report sections: per-app switched/functional/data (pass/fail) · downtime per app · lost/duplicate messages · double executions · latency before/after · what the pinned/UPS/key apps did (expected failures shown as expected)
- [ ] report is the template for the real migration's evidence pack
- [ ] findings folded back into: migration script fixes · academy deck (real numbers) · `knowledge/migration/`

---

## Decisions

- 2026-10-03 — **Retirement happens** ~1–2 weeks after full confirmation (grace default 14 d), never automatically. **IP headroom is a preflight check**, not an assumption. **Rollback unit = the service** (all its apps; pipeline groups together); per-app only as explicit override.
- 2026-10-03 — Valkey naming: **preference = (B) substituted names** (`redis`→`valkey`, case-preserving; `-valkey` suffix when the name has no "redis"), pending the client's decision. Teams update manifests/pipelines at their own pace during the standby weeks; the old Redis is renamed `<name>-redis-standby` at cutover so a stale manifest fails loudly ("service instance not found") instead of silently re-binding it. Consequences owned: 6th academy ask ("update the service name in your manifest"), and a periodic drift scan during standby (apps bound back to a `-redis-standby` service).

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

## Open questions

- [ ] dominant client stacks — Java/Spring + .NET assumed; confirm (decides which real-stack apps matter)
- [ ] are classic plans + patched broker in SBX yet, or do we start on secure plans and switch when they land?
- [ ] data-copy mechanism: exists to test, or does `sim-store-bound` first just *measure* loss to give the copy tool a target?
- [ ] SBX quotas (apps, service instances, memory) — enough for the Phase-2 population?
- [ ] which Windows stack / .NET runtime is standard in the client estate?
- [ ] how many real consumers use the TLS port (16379)? (census has the port -- `awk -F'\t' '$4==16379' backward/02_conns.tsv`) -> sizes the TLS-plan requirement for Valkey

## Log

- 2026-09-30 — **Population live in SBX.** Six core Go probe apps up, baseline captured (`verify/data/*-baseline.jsonl`). Next: access variants + Windows + TLS apps, Valkey twins, first migration (cache).

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
