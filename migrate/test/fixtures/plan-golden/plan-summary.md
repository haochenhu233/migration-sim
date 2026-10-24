# Migration plan summary (aggregates only)


| metric | value |
|---|---|
| connections (app↔service, deduped) | 11 |
| services | 6 |
| apps | 11 |
| orgs (≈teams) | 2 |
| rows skipped (external / no guid) | 0 |
| ghost services excluded (no deployment) | 1 (1 rows) |
| connections WITHOUT a binding (static-ref / unknown -> team action, tool skips) | 2 |
| multi-bound apps (2+ services → 1 restart per wave) | 0 |
| services used across spaces/orgs (joint window + sharing) | 0 |
| hazard apps (cf-bind + pinned ref) | 1 (1 connections) |
| idle connections (no live seen) | 2 |
| services with NO live connection at all | 2 |
| windows apps | 1 |

## Binding-graph components: 6

| shape | count |
|---|---|
| 1 svc / 1 app | 4 |
| 1 svc / n apps | 2 |

## Apps per service

| apps bound | services |
|---|---|
| 2-5 apps | 2 |
| 1 app | 4 |

most-shared service: 5 apps (one restart each when its wave runs)

## Services per plan (each gets a Valkey of the same plan -- vCPU / disk / quota input)

| plan | services |
|---|---|
| cache-small | 5 |
| cache-medium | 1 |

largest components (services/apps): 1/5, 1/2, 1/1, 1/1, 1/1

## Wave proposal (live waves: max 10 services / 40 restarts; silent waves: max 30 services / 120 restarts; order=easy)

| wave | services | silent svcs | apps (restarts) | components | orgs |
|---|---|---|---|---|---|
| 1 | 2 | 2 | 2 | 2 | 2 |
| 2 | 4 | 0 | 9 | 4 | 2 |

IP headroom needed: 6 Valkeys in total (one per service); per wave as above.

Detailed files (stay in the environment): waves.tsv, components.tsv
