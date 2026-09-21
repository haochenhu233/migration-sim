#!/usr/bin/env bash
# apps-list.sh -- build verify/apps.txt (app-name  https://first-route) for all sim-* apps
# in the current cf target. Re-run whenever apps are added.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cf curl "/v3/apps?names=$(cf curl '/v3/apps?per_page=200' | jq -r '.resources[].name' | grep '^sim-' | paste -sd, -)&per_page=200" \
 | jq -r '.resources[] | .guid + " " + .name' | while read -r guid name; do
  route=$(cf curl "/v3/apps/$guid/routes" | jq -r '.resources[0].url // empty')
  [ -n "$route" ] && echo "$name https://$route"
done | sort > "$HERE/apps.txt"
echo "wrote $HERE/apps.txt:"; cat "$HERE/apps.txt"
