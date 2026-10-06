#!/usr/bin/env bash
# reset-population.sh -- rebuild the SBX tool-test population from scripts/layout.tsv:
#   1. unbind every sim-* app from every sim-* service
#   2. delete every Valkey twin (sim-valkey-* and any original-named Valkey) -> frees IPs
#   3. rename *-redis-standby back to their original names
#   4. bind per layout.tsv, set the pinned app back to env (hazard), restart / stop as laid out
# Idempotent; safe to re-run after a tool test. Needs: cf admin login targeted at the sim space.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; LAYOUT="$HERE/layout.tsv"
REDIS="sim-redis-cache sim-redis-session sim-redis-store sim-redis-queue sim-redis-pipe-a sim-redis-pipe-b"
echo "== 1. unbind everything"
for app in $(cf apps | awk 'NR>3 && $1 ~ /^sim-/ {print $1}'); do
  for svc in $(cf curl "/v3/apps/$(cf app "$app" --guid)/env" 2>/dev/null | jq -r '.system_env_json.VCAP_SERVICES[]?[]?.name' 2>/dev/null); do
    case "$svc" in sim-ups-redis) continue;; esac
    echo "   unbind $app <- $svc"; cf unbind-service "$app" "$svc" >/dev/null 2>&1 || true
  done
done
echo "== 2. delete Valkey instances (frees their IPs)"
for inst in $(cf curl "/v3/service_instances?service_offering_names=valkey&per_page=200" | jq -r '.resources[].name' | grep '^sim-'); do
  echo "   delete $inst"; cf delete-service "$inst" -f >/dev/null 2>&1 || true
done
echo "== 3. rename standbys back"
for r in $REDIS; do
  if cf service "$r-redis-standby" >/dev/null 2>&1; then echo "   $r-redis-standby -> $r"; cf rename-service "$r-redis-standby" "$r"; fi
done
echo "   waiting for valkey deletions to finish ..."
for i in $(seq 1 60); do n=$(cf curl "/v3/service_instances?service_offering_names=valkey&per_page=200" | jq -r '.resources[].name' | grep -c '^sim-'); [ "$n" = 0 ] && break; sleep 10; done
echo "== 4. bind per layout, fix env, restart/stop"
cf set-env sim-bound-pinned SIM_SOURCE env >/dev/null       # the hazard: back to the pinned path
while IFS=$'\t' read -r app services state note; do
  [ "$app" = app ] && continue
  for svc in ${services//,/ }; do echo "   bind $app -> $svc"; cf bind-service "$app" "$svc" >/dev/null 2>&1 || true; done
  if [ "$state" = stopped ]; then cf stop "$app" >/dev/null; echo "   $app stopped (silent)"; else cf restart "$app" >/dev/null 2>&1 || cf start "$app" >/dev/null; fi
done < "$LAYOUT"
echo "== 5. re-point the unbound credential-copy apps at sim-redis-cache (static-env via env, sim-ups via the UPS)"
cf create-service-key sim-redis-cache reset-key >/dev/null 2>&1 || true
CRED=$(cf service-key sim-redis-cache reset-key | sed -n '/{/,$p' | jq -c '.credentials // .')
HOST=$(printf '%s' "$CRED" | jq -r .host); PW=$(printf '%s' "$CRED" | jq -r .password)
if [ -n "$HOST" ] && [ "$HOST" != null ]; then
  cf set-env sim-static-env REDIS_HOST "$HOST" >/dev/null; cf set-env sim-static-env REDIS_PASSWORD "$PW" >/dev/null; cf restart sim-static-env >/dev/null 2>&1 || true
  cf set-env sim-bound-pinned REDIS_HOST "$HOST" >/dev/null; cf set-env sim-bound-pinned REDIS_PASSWORD "$PW" >/dev/null; cf restart sim-bound-pinned >/dev/null 2>&1 || true
  cf update-user-provided-service sim-ups-redis -p "{\"host\":\"$HOST\",\"port\":6379,\"password\":\"$PW\"}" >/dev/null; cf restart sim-ups >/dev/null 2>&1 || true
  echo "   static-env, bound-pinned, ups -> $HOST"
else echo "   !! could not read sim-redis-cache credentials; set static-env/ups by hand"; fi
echo "== done. verify:"; cf services | grep -E '^sim-redis'; echo "then: bash verify/apps-list.sh && bash verify/snapshot.sh tool-baseline"
