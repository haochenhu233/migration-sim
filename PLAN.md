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
- [ ] spec written: JSON fields (`app, expects, endpoint, server, version, auth_user, roundtrip, dataset, canary, since_start`) and per-mode pass criteria
- [ ] pass criteria per usage mode defined (cache / session / store / producer / consumer / lock)

**1b. The Python probe app (`apps/sim-py`, Flask + redis-py)**
- [ ] usage modes: `SIM_MODE=cache|session|store|producer|consumer|lock`
- [ ] credential sources: `SIM_SOURCE=vcap|env|ups` (+ service-key runner script)
- [ ] auth styles: `SIM_AUTH=password|username` (password-only vs username-aware)
- [ ] self-generated ground truth: deterministic dataset + checksum (store), gapless sequence (producer/consumer), session token minted pre-cutover (session), lock canary (lock)
- [ ] command-family smoke in `/check` (SET/GET, hash, EVAL, MULTI, Streams, pub/sub) per mode
- [ ] manifests for every variant (table below)
- [ ] deployed to SBX; `/check` green against a Redis service

**1c. Real-stack apps**
- [ ] `apps/sim-spring` — Spring Boot + Spring Data Redis (Lettuce); `spring.redis.username` handling; optional Spring Cloud Config Server wiring (hidden-config case)
- [ ] `apps/sim-win` — .NET + StackExchange.Redis on the Windows stack
- [ ] both implement the same `/check` contract

**1d. The verifier (`verify/`)**
- [ ] `verify.sh`: polls every app's `/check` every N s → timeline file (per app, per poll)
- [ ] expectation tables per scenario (what each app MUST report after each step)
- [ ] baseline capture command (snapshot all `/check` before any migration)
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

## Phase 2 — realistic population (~100+ live connections)

- [ ] target shape mirrors the real findings: ~all cf-bind · a handful pinned hazards · ~⅓ idle · a couple Windows · zero pure static-ref in the "normal" set
- [ ] ~10 Redis services (mix of plans), ~25 apps, 2–3 instances each, small pools → 100–150 connections
- [ ] some apps bound to multiple services; some services with multiple apps
- [ ] `sim-batch` scheduled so it is idle during most scans
- [ ] discovery toolkit run against SBX → `merged_report` shows the intended shape (also validates the toolkit once more)
- [ ] verifier baseline captured (Phase 1d last item)

## Phase 3 — migration script + three scenarios

**3a. The migration script (`migrate/`)**
- [ ] per service: create Valkey (classic plan) → per app: bind valkey → unbind redis → restart → verify → Redis to standby
- [ ] per-app/per-service action log (timestamps) — the report joins on this
- [ ] wave definition input (which services, which order, pipeline pairs together)
- [ ] confirm gate + grace before any retirement; dry-run mode
- [ ] handles: pinned-env apps (report, do not "fix" silently), UPS, service keys (create new key), multi-instance apps, Windows apps
- [ ] data copy for store-mode services (RDB snapshot or brief sync) + key-count verification

**3b. Scenarios**
- [ ] S1 happy migration of the whole population in 2–3 waves
- [ ] S2 rollback: re-bind one wave back to Redis, prove "minutes", data intact on standby
- [ ] S3 failure injection: one service fails verification mid-wave → only that wave rolls back
- [ ] S4 secure-plan variant: migrate `sim-password-only` + `sim-username-aware` onto a `-secure` plan → WRONGPASS vs OK captured as evidence
- [ ] S5 pipeline ordering: migrate A and B in the wrong order once (prove the break), then correctly

## Phase 4 — verification & report

- [ ] run verifier after each scenario; produce `report/<scenario>.md`
- [ ] report sections: per-app switched/functional/data (pass/fail) · downtime per app · lost/duplicate messages · double executions · latency before/after · what the pinned/UPS/key apps did (expected failures shown as expected)
- [ ] report is the template for the real migration's evidence pack
- [ ] findings folded back into: migration script fixes · academy deck (real numbers) · `knowledge/migration/`

---

## Decisions

- 2026-09-20 — steps agreed: 0 prereqs → 1 apps+verifier+baseline → 2 population → 3 script+scenarios → 4 verify+report. Verifier is built with the apps (baseline before migration), not after.
- 2026-09-20 — scale via instances + pools (~25 apps → 100+ connections), not 100 distinct apps; population mirrors real proportions.
- 2026-09-20 — usage pattern = a mode of one Python probe (all cf-bind); access-pattern variants only in cache mode; Spring + .NET for real-stack fidelity.
- 2026-09-20 — migration waves bind `-classic` plans (no app code change); `-secure` is an explicit scenario (S4), not the default.

## Open questions

- [ ] dominant client stacks — Java/Spring + .NET assumed; confirm (decides which real-stack apps matter)
- [ ] are classic plans + patched broker in SBX yet, or do we start on secure plans and switch when they land?
- [ ] data-copy mechanism: exists to test, or does `sim-store-bound` first just *measure* loss to give the copy tool a target?
- [ ] SBX quotas (apps, service instances, memory) — enough for the Phase-2 population?
- [ ] which Windows stack / .NET runtime is standard in the client estate?

## Log

- 2026-09-20 — plan created; Phase 0 prerequisites listed; nothing started.
