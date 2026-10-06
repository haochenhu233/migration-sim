#!/usr/bin/env bash
# apps-list.sh -- build verify/apps.txt (app-name  https://first-route) for all sim-* apps
# visible to the current cf login. Re-run whenever apps are added.
# Every API response is shape-checked: an error document aborts, it is never read as "no apps".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
api(){ local j; j=$(cf curl "$1" 2>/dev/null)
  if ! printf '%s' "$j" | jq -e 'type=="object" and has("resources")' >/dev/null 2>&1; then
    echo "!! CF API error on $1: $(printf '%s' "$j" | jq -r '.errors[0] | "\(.title): \(.detail)"' 2>/dev/null || echo 'no/invalid response')" >&2; return 1; fi
  printf '%s' "$j"; }
apps=""; next="/v3/apps?per_page=200"
while [ -n "$next" ] && [ "$next" != "null" ]; do
  page=$(api "$next") || exit 1
  apps="$apps$(printf '%s' "$page" | jq -r '.resources[] | select(.name|startswith("sim-")) | .guid + " " + .name')"$'\n'
  next=$(printf '%s' "$page" | jq -r '.pagination.next.href // "null"'); [ "$next" != "null" ] && next="/v3/${next#*/v3/}"
done
apps=$(printf '%s' "$apps" | grep . || true)
[ -n "$apps" ] || { echo "!! no sim-* apps found" >&2; exit 1; }
: > "$HERE/apps.txt.tmp"
while read -r guid name; do
  r=$(api "/v3/apps/$guid/routes") || exit 1
  route=$(printf '%s' "$r" | jq -r '.resources[0].url // empty')
  if [ -n "$route" ]; then echo "$name https://$route" >> "$HERE/apps.txt.tmp"; else echo "   note: $name has no route (skipped)" >&2; fi
done <<< "$apps"
sort "$HERE/apps.txt.tmp" > "$HERE/apps.txt" && rm -f "$HERE/apps.txt.tmp"
echo "wrote $HERE/apps.txt:"; cat "$HERE/apps.txt"
