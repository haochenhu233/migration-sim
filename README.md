# migration-sim

Rehearsal of the Redis→Valkey migration in the client SBX: test apps that genuinely use Redis and self-report via `/check`, a realistic ~100-connection population, the migration script, and the verifier/report.

**Start at [PLAN.md](PLAN.md)** — the living checklist (phases 0–4, app matrix, decisions, open questions, log).
**To run a migration:** [migrate/RUNBOOK.md](migrate/RUNBOOK.md) — scan → plan → provision → provision-check → preflight → apply, with what to do on each FAIL and what may be pasted out.

Layout (fills in as phases complete): `apps/sim-go` (primary: static binaries, works air-gapped; `apps/sim-py` = reference) · `apps/sim-spring` · `apps/sim-win` · `verify/` · `migrate/` · `scenarios/` · `report/`
