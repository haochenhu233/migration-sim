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
- [ ] deployed to SBX; `/check` green against a Redis service (real `server`/`auth_user`/`eval` values confirmed — fakeredis can't)

**1c. Real-stack apps**
- [ ] `apps/sim-spring` — Spring Boot + Spring Data Redis (Lettuce); `spring.redis.username` handling; optional Spring Cloud Config Server wiring (hidden-config case)
- [ ] `apps/sim-win` — .NET + StackExchange.Redis on the Windows stack
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
- [ ] `verify` — app health · Valkey-side census (reuse discovery worker) · `/check` · key counts · drift check
- [ ] `rollback --app/--service/--wave` per the table
- [ ] `confirm` / `retire` (confirm + grace + double prompt)
- [ ] `report --wave N` evidence pack
- [ ] data copy for store-mode services (RDB snapshot / brief sync) + key-count verification
- [ ] handles pinned-env apps (refuse in preflight), UPS, service keys (new key), multi-instance, Windows, TLS consumers (TLS plan + cert trust)

**3c. Scenarios (SBX, 6 Redis + 6 Valkey, waves of two)**
- [ ] S1 happy migration of the population in three waves
- [ ] S2 rollback: one wave back to Redis — prove "minutes", data intact on standby
- [ ] S3 **accident drill**: every row of the accident matrix, with client devops on the call
- [ ] S4 secure-plan variant: `sim-password-only` + `sim-username-aware` → WRONGPASS vs OK captured
- [ ] S5 pipeline ordering: wrong order once (prove the break), then correct
- [ ] S6 TLS consumer onto a TLS-enabled Valkey plan

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

- 2026-09-20 — plan created; Phase 0 prerequisites listed; nothing started.
- 2026-09-28 — `migrate.sh status` built and demonstrated on a sample ledger (`migrate/example/`); plan file settled as `waves.tsv`.
- 2026-09-28 — Phase 3 redesigned around the operator layer (`migrate/DESIGN.md`); SBX sized to 6+6; lock service merged into the queue Redis.
- 2026-09-20 — Phase 1 started: `/check` contract written; `sim-py` probe built with all six
  usage modes + three credential sources + two auth styles, smoke-tested locally against
  fakeredis (lock-mode double-exec false positive found & fixed: per-window lock keys +
  per-instance run log); manifests for 13 app variants; verifier snapshot/poll/apps-list
  scripts. Next: deploy to SBX against real Redis, then Spring/.NET apps and expectation
  tables. Phase 1 = `[~]`.
