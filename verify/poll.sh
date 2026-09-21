#!/usr/bin/env bash
# poll.sh -- continuously poll every sim app's /check -> one timeline JSONL (Ctrl-C to stop).
#     bash verify/poll.sh [interval-seconds] [label]      # default 5s; run DURING a migration
# The timeline is what measures downtime per app (seconds with connected=false).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; INT="${1:-5}"; LABEL="${2:-timeline}"
LIST="$HERE/apps.txt"; [ -s "$LIST" ] || { echo "no $LIST -- run: bash verify/apps-list.sh"; exit 1; }
mkdir -p "$HERE/data"; OUT="$HERE/data/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL.jsonl"
echo "polling every ${INT}s -> $OUT   (Ctrl-C to stop)"
while true; do
  while read -r name url; do
    [ -z "$name" ] && continue
    ( body=$(curl -sk --max-time 4 "$url/check" 2>/dev/null)
      if [ -n "$body" ] && printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$body" | jq -c --arg n "$name" --arg t "$(date -u +%FT%TZ)" '{_app:$n,_polled_at:$t,endpoint,server,connected,auth_user,roundtrip_ms,error,since_start,mode_data}'
      else
        jq -nc --arg n "$name" --arg t "$(date -u +%FT%TZ)" '{_app:$n,_polled_at:$t,connected:false,error:"no response"}'
      fi ) >> "$OUT" &
  done < "$LIST"
  wait
  printf '%s  polled %s app(s)\n' "$(date -u +%T)" "$(grep -c . "$LIST")"
  sleep "$INT"
done
