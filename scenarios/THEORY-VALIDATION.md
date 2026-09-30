# Theory validation in SBX — 6 Redis + 6 Valkey, by hand

**Goal:** prove the migration mechanics on real services with apps that self-report, before
any tooling automates them. Everything here is done with plain `cf` commands; the tool comes
later and must reproduce exactly these steps. Tick the results table as you go.

**The theory under test:** for a bound app, `bind valkey → unbind redis → restart` moves it
to Valkey with no code change; old Redis stays intact so rollback is `bind redis → unbind
valkey → restart`; cache apps refill, data-store apps need a copy, pinned-env apps silently
keep the old address, password-only apps break on `-secure` plans and work on `-classic`.

## 0. Prerequisites (Phase 0 of PLAN.md)

- [ ] `cf marketplace -e valkey` shows the classic plans (e.g. `cache-small`) — and, for S4, a `-secure` one
- [ ] patched broker deployed (classic-plan unbind works)
- [ ] 12 free IPs on the services network; quota for ~15 apps × 1–2 instances
- [ ] `cf target -o <sim-org> -s <sim-space>`
- [ ] **buildpacks are the offline `_system` ones** (`cf buildpacks`): manifests use `binary_buildpack_system`; a plain `binary_buildpack`/`python_buildpack` name is the ONLINE variant and fails at staging (no egress). Confirm the Windows binary buildpack's exact name.

## 1. Deploy the population

```bash
bash scripts/create-services.sh redis cache-small          # 6 Redis: cache, session, store, queue, pipe-a, pipe-b
cd apps/sim-go && cf push -f manifests/core.yml && cd ../..  # cache, session, store, producer, consumer, lock (static Go binary, binary_buildpack: no downloads)
# access variants: fill the <REDIS-IP>/<PASSWORD> placeholders first (cf service-key sim-redis-cache k; cf service-key sim-redis-cache k)
cf cups sim-ups-redis -p '{"host":"<ip>","port":6379,"password":"<pw>"}'
cd apps/sim-go && cf push -f manifests/access-variants.yml && cd ../..
cd apps/sim-go && cf push -f manifests/windows.yml && cd ../..     # Windows stack, same binary code
bash verify/apps-list.sh
bash verify/snapshot.sh baseline                            # every /check green, server=redis
```
Expect in the baseline: `connected=true`, `server=redis`, `auth_user=n/a` (hardened Redis),
store `checksum_ok=true`, producer/consumer `gaps=0`, lock `double_exec=0`.

## 2. Create the Valkey twins

```bash
for s in cache session store queue pipe-a pipe-b; do cf create-service valkey cache-small sim-valkey-$s; done
# wait: cf service sim-valkey-cache | grep status   -> create succeeded
```
Record each twin's IP (needed for the pinned-hazard demo): `cf create-service-key sim-valkey-cache k && cf service-key sim-valkey-cache k`.

## 3. Migrate one service by hand — the four steps (start with cache)

Open a second terminal first: `bash verify/poll.sh 3 wave-cache` (this measures downtime).

```bash
APP=sim-cache-bound
cf bind-service   $APP sim-valkey-cache        # 1. bind valkey
cf unbind-service $APP sim-redis-cache         # 2. unbind redis (Redis untouched)
cf restart $APP --strategy rolling             # 3. restart (rolling: 2 instances) -- or plain `cf restart` for 1 instance
sleep 30                                       # soak
bash verify/snapshot.sh after-cache            # 4. verify
```
**Pass:** `endpoint` = the Valkey IP, `server=valkey`, `connected=true`, `families` all ok,
cache `misses` spike then `hits` recover; `auth_user` = `default` on a classic plan. In the
poll timeline: seconds with `connected=false` per instance = the measured downtime (rolling
should be ~0).

Repeat for `session`, `queue` (producer + consumer + lock — **all three apps of the service
before judging**), `pipe-a`/`pipe-b` (S5: deliberately migrate **b before a** once and watch
the consumer's `gaps` climb; then do it in the right order).

## 4. The store service — measure, don't assume

Migrate `sim-store-bound` the same way **without** copying data and read `mode_data`:
`found` drops to 0, `checksum_ok=false`, `canary.present=false` — that is the loss a cache-only
migration causes a data-store app, quantified. Then roll back (§6) and, if a copy mechanism is
available, migrate again with it: `found == expected`, `checksum_ok=true`, `canary.present=true`.

## 5. The access variants — each proves one claim

| app | do | expect after migration of `sim-redis-cache` |
|---|---|---|
| `sim-bound-pinned` | same four steps | **still reports the OLD Redis endpoint** (`SIM_SOURCE=env`) — the hazard, live. Then `cf unset-env sim-bound-pinned REDIS_HOST` … → after restart it follows the binding |
| `sim-static-env` | nothing (no binding) | unchanged — keeps talking to Redis until its env is edited: the manual-update path |
| `sim-ups` | `cf update-user-provided-service sim-ups-redis -p '{…valkey…}'; cf restage sim-ups` | switches only after the UPS update — the UPS path |
| `sim-password-only` | four steps onto **classic** | works (`auth_user=default`) |
| `sim-password-only` | four steps onto a **`-secure`** twin (S4) | `connected=false`, error WRONGPASS/NOAUTH — the evidence for the plan decision |
| `sim-username-aware` | four steps onto `-secure` | works, `auth_user` = binding guid |

## 6. Rollback — prove "minutes"

```bash
cf bind-service $APP sim-redis-cache; cf unbind-service $APP sim-valkey-cache; cf restart $APP --strategy rolling
bash verify/snapshot.sh rollback-cache          # server=redis again; store: data intact (Redis was never touched)
```
Time it wall-clock; that number goes in the report and the academy.

## 7. Standby & retire

Leave the migrated Redis services running (standby) for the session; at the end delete one
(`cf delete-service sim-redis-cache`) to confirm apps on Valkey don't notice — and that its IP
frees up (IP recycling for the next scenario).

## Results table

| service / app | step done | switched? | works? | data | downtime s | rollback min | notes |
|---|---|---|---|---|---|---|---|
| cache | | | | n/a | | | |
| session | | | | token present? | | | |
| store (no copy) | | | | found/expected | | | |
| store (copy) | | | | checksum_ok | | | |
| queue: producer/consumer/lock | | | | gaps/dups/double_exec | | | |
| pipe a→b wrong order / right order | | | | gaps | | | |
| bound-pinned | | | | | | | old endpoint kept? |
| password-only on classic / secure | | | | | | | WRONGPASS on secure? |
| username-aware on secure | | | | | | | auth_user = binding? |
| TLS consumer (if a TLS plan exists) | | | | | | | cert trusted? |

**"Theory validated" =** every row filled, every expectation met or explained. Anything that
surprises us becomes a scenario in `migrate/DESIGN.md`'s accident matrix.
