# Scaled simulation in client SBX — copy-paste runbook (2026-10-18)

20 Redis→Valkey pairs, ~120 apps, two orgs, waves of 4 services / ≤40 restarts, two lanes.
Goal: prove the tool and the day-ahead runbook at NP's shape, and take the per-service / per-app
timings NP's wall-clock is extrapolated from. Paste back **counts and timings only** — no app,
service, org or space names (plan names, IP counts and wave numbers are fine).

Already done (2026-10-18): subnet `ocfp-3` (z3) added to the cf network; Redis and Valkey standalone
plans steered to z3 with raised `limit`; blacksmith redeployed; probe landed in z3; `safe-run.sh`
verified against the broker's Vault.

All commands run on the bastion in `~/ocfp/migration-sim` unless the line says otherwise.

---

## 0. Once: variables and the two config files

```bash
cd ~/ocfp/migration-sim && git pull

# fill in once per shell (or put them in ~/.sbx-sim.env and `source` it)
export POP_ORG_A=<existing sim org>      POP_SPACE_A=<existing sim space>
export POP_ORG_B=<new org>               POP_SPACE_B=<new space>
export BOSH_CMD="genesis @sbx-us b"
# optional: MIGRATE_OP=<name> if the ledger's "op" field should not be your login (shared accounts)

# name-sync: the tool writes Blacksmith's copy of each renamed instance's name through this wrapper
cp -n migrate/example/safe-run.sh runs/sbx/safe-run.sh
printf 'SAFE_RUN="bash runs/sbx/safe-run.sh"\n' > runs/sbx/vault.conf
cat runs/sbx/vault.conf
```

Expected: one line, `SAFE_RUN="bash runs/sbx/safe-run.sh"`.

---

## 1. Org B

```bash
cf create-org "$POP_ORG_B" && cf create-space "$POP_SPACE_B" -o "$POP_ORG_B"
cf set-space-role "$(cf target | sed -n 's/^user: *//p')" "$POP_ORG_B" "$POP_SPACE_B" SpaceDeveloper
cf enable-service-access redis  -o "$POP_ORG_B"
cf enable-service-access valkey -o "$POP_ORG_B"
cf target -o "$POP_ORG_B" -s "$POP_SPACE_B" && cf marketplace -e valkey
```

Expected: the standalone Valkey plan is listed in org B. If not, preflight will later fail every
`sclb` service with "plan not available in space" — fix the visibility first.

---

## 2. Two populations (10 Redis + 60 apps each)

```bash
cf target -o "$POP_ORG_A" -s "$POP_SPACE_A"
time bash scripts/populate.sh --services 10 --apps 60 --run runs/sbx --org "$POP_ORG_A" --space "$POP_SPACE_A" --prefix scla --parallel 3

cf target -o "$POP_ORG_B" -s "$POP_SPACE_B"
time bash scripts/populate.sh --services 10 --apps 60 --run runs/sbx --org "$POP_ORG_B" --space "$POP_SPACE_B" --prefix sclb --parallel 3
```

`--parallel 3`, not 8: every concurrent push stages in a ~1 GB task on a Diego cell, and SBX's
cells are nearly full once ~120 sim apps run — at 8-wide, pushes fail with
`InsufficientResources` at "Staging app" (seen 2026-10-19). Both orgs must be fresh orgs with the
default quota (the old sim org's quota was hit); one prefix per org, never the same prefix twice
(routes are foundation-wide: a second `sclb` population collides with the first).

Expected per run: `services: ready 10, existed 0, failed 0`, `failed chunks: 0`, `apps 60 of 60`,
`stopped: 6` (every app of the last service = the silent service). A failed service stops the run:
delete it as the message says, re-run — ready services and staged apps are skipped, an app record
left by a failed push (no droplet) is deleted and pushed again.

Paste back: the two `== done in …` lines and the `services:` line with its time.

IP check after both:

```bash
bash migrate/free-ips.sh --network ocfp-int-sbx-us-east-1-ocf --cloud-config ocfp-int-sbx-us-east-1.cf --out runs/sbx/free-ips.txt
```

Expected: z3 ≈ 50 free of 70 (20 Redis took 20), total ≈ 62. Paste the TOTAL line.

---

## 3. Discovery scan (whole foundation) and merge

```bash
cd ~/ocfp/redis-consumer-discovery
bash redis-consumer-discovery.sh run        <sbx-env> --path ./sbx-scale
bash redis-consumer-discovery.sh scan-apps  <sbx-env> --path ./sbx-scale
bash redis-consumer-discovery.sh list-redis <sbx-env> --path ./sbx-scale
bash redis-consumer-discovery.sh scan-ups   <sbx-env> --path ./sbx-scale
bash redis-consumer-discovery.sh merge      <sbx-env> --path ./sbx-scale
cd ~/ocfp/migration-sim
```

---

## 4. Plan (both orgs in one plan)

```bash
bash migrate/migrate.sh plan ~/ocfp/redis-consumer-discovery/sbx-scale/merged_report.csv \
     --run runs/sbx --services '^(scla|sclb)-redis-' --wave-size 4 --max-apps 40
cat runs/sbx/plan-summary.md
```

Expected: 20 services, 120 apps, 2 orgs, 2 silent services, 12 multi-bound apps, 5–6 waves.
Paste back: `plan-summary.md` (aggregates only — it contains no names).

If an older `runs/sbx/ledger.jsonl` from the 6-service rehearsal is still there, move it aside
first: `mv runs/sbx/ledger.jsonl runs/sbx/ledger-6svc-$(date +%F).jsonl` — the plan's GUIDs are new,
but a clean ledger keeps `status` readable.

---

## 5. Day-ahead (2–3 days before the "window"): provision the Valkeys, review the inventory

```bash
bash migrate/free-ips.sh --network ocfp-int-sbx-us-east-1-ocf --cloud-config ocfp-int-sbx-us-east-1.cf \
     --plan runs/sbx/waves.tsv --out runs/sbx/free-ips.txt
time bash migrate/migrate.sh provision --waves 1-6 --run runs/sbx          # adjust 6 to the last wave in plan-summary
bash migrate/migrate.sh status --run runs/sbx
column -ts $'\t' runs/sbx/inventory.tsv | less -S
```

Expected: every service `STAGED` in `status --wave N`; `inventory.tsv` has 120 lines, `state=staged`,
`valkey_name=<name>-valkey-staged`. Blacksmith creates the Valkeys concurrently per wave (4 at a
time); note the `waiting for valkey deploy` → `valkey ready` time per service.

Paste back: `time` of provision, the `TOTAL` line of `status`, and `cut -f9 runs/sbx/inventory.tsv | sort | uniq -c`.

Re-running `provision` is safe at any time: done services are skipped, a staged Valkey that
vanished is created again.

---

## 6. Cutover: two lanes

Terminal 1 (lane A) and terminal 2 (lane B), both in `~/ocfp/migration-sim`:

```bash
# before the first wave of each lane: the gates, once, by eye
bash migrate/migrate.sh preflight --wave 1 --run runs/sbx
bash migrate/migrate.sh dry-run   --wave 1 --run runs/sbx | head -40

# lane A                                                   # lane B (other terminal)
time bash migrate/migrate.sh apply --waves 1-3 --run runs/sbx    time bash migrate/migrate.sh apply --waves 4-6 --run runs/sbx
```

`apply` runs preflight itself before each wave and asks `type yes`. Watch from a third terminal:

```bash
watch -n 5 -c "bash migrate/migrate.sh status --run runs/sbx"
bash migrate/migrate.sh status --wave 1 --run runs/sbx
```

Expected per wave: `rename-standby` → `rename-valkey` (staged Valkey takes the name) → per app
bind / unbind / one restart / verify; phase `VERIFIED`; footer `name-sync pending: 0`.
A verify failure rolls the whole service back and the wave continues; three in a row stop the wave
(`!! lane stopped at wave N`) — then `status --wave N`, fix, `apply --wave N` again.

If `name-sync pending` is not 0 after a wave (a `safe` call timed out):

```bash
bash migrate/migrate.sh name-sync --waves 1-6 --run runs/sbx
```

Paste back per lane: `time`, the `TOTAL` line of `status`, and the `attention:` block if any.

---

## 7. Verify a few apps by hand

```bash
cf target -o "$POP_ORG_A" -s "$POP_SPACE_A"
for a in scla-app-001 scla-app-010 scla-app-055; do curl -s "https://$(cf app $a | sed -n 's/^routes: *//p' | cut -d, -f1)/check" | jq -c '{server, source, connected}'; done
cf services | awk 'NR>3 {print $2}' | sort | uniq -c          # offering counts: 10 redis (standby) + 10 valkey
```

Expected: `server` starts with `valkey`, `connected: true`; the silent service's apps are still
STOPPED (rebind only).

---

## 8. What to write down (the numbers NP's estimate comes from)

| measure | where it comes from |
|---|---|
| Valkey create, per service (min) | `provision` output: `create issued` → `valkey ready` |
| concurrent creates Blacksmith tolerated | 4 per wave × 2 lanes = 8 at once; any `create FAILED`? |
| apps phase, per app (s) | `apply` output: `==` line → `verified`; `status --wave N` last-event column |
| wave wall-clock | `time` per lane ÷ waves |
| name-sync, per instance (s) | ledger `ms` on `name-sync` events: `jq 'select(.step=="name-sync") | .ms' runs/sbx/ledger.jsonl` |
| failures and their class | `status` → `attention:`; `runs/sbx/status/failed.tsv` |

```bash
bash migrate/migrate.sh status --run runs/sbx > runs/sbx/scaled-summary.txt
jq -r 'select(.step=="create-valkey" and .outcome=="ok") | .ms' runs/sbx/ledger.jsonl | sort -n | awk '{a[NR]=$1} END {print "create ms: min", a[1], "median", a[int(NR/2)+1], "max", a[NR]}'
jq -r 'select(.step=="verify" and .outcome=="ok") | .ms' runs/sbx/ledger.jsonl | wc -l
```

Paste back: `scaled-summary.txt` and the two numbers lines.

---

## 9. Teardown (when done; keeps the ledger and inventory as evidence)

```bash
cp runs/sbx/ledger.jsonl runs/sbx/ledger-scaled-$(date +%F).jsonl
cp runs/sbx/inventory.tsv runs/sbx/inventory-scaled-$(date +%F).tsv
cf target -o "$POP_ORG_A" -s "$POP_SPACE_A"; bash scripts/populate.sh --run runs/sbx --org "$POP_ORG_A" --space "$POP_SPACE_A" --prefix scla --teardown
cf target -o "$POP_ORG_B" -s "$POP_SPACE_B"; bash scripts/populate.sh --run runs/sbx --org "$POP_ORG_B" --space "$POP_SPACE_B" --prefix sclb --teardown
bash migrate/free-ips.sh --network ocfp-int-sbx-us-east-1-ocf --cloud-config ocfp-int-sbx-us-east-1.cf
```

Teardown deletes the `scl?-app-NNN` apps and every `scl?-redis-NN` and `scl?-redis-NN-redis-standby`
service — the standby Redis **and** the Valkey that took the name — so no `retire` is needed.
Expected: z3 back to ≈70 free once BOSH has deleted the VMs (a few minutes).

Blacksmith's Vault keeps `secret/<guid>` entries for deleted instances only until its reconciler
cleans them; nothing to do by hand.
