#!/usr/bin/env bash
# create-services.sh -- create the Redis services the sim apps bind to (idempotent).
#     bash scripts/create-services.sh [offering] [plan]      # default: redis cache-small
set -uo pipefail
OFFERING="${1:-redis}"; PLAN="${2:-cache-small}"
for s in sim-redis-cache sim-redis-session sim-redis-store sim-redis-queue \
         sim-redis-pipe-a sim-redis-pipe-b; do
  if cf service "$s" >/dev/null 2>&1; then echo "exists: $s"; else
    echo "creating: $s ($OFFERING/$PLAN)"; cf create-service "$OFFERING" "$PLAN" "$s"; fi
done
echo "waiting for all to be 'create succeeded' ..."
for s in sim-redis-cache sim-redis-session sim-redis-store sim-redis-queue \
         sim-redis-pipe-a sim-redis-pipe-b; do
  until cf service "$s" | grep -qE 'status:.*create succeeded'; do sleep 10; done; echo "ready: $s"
done
