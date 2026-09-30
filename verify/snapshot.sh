#!/usr/bin/env bash
# snapshot.sh -- capture every sim app's /check ONCE -> a timestamped JSONL file.
#     bash verify/snapshot.sh [label]        # e.g. baseline, after-wave1, after-rollback
# App list: verify/apps.txt (one "app-name https://route" per line; generate with apps-list.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; LABEL="${1:-snap}"
LIST="$HERE/apps.txt"; [ -s "$LIST" ] || { echo "no $LIST -- run: bash verify/apps-list.sh"; exit 1; }
mkdir -p "$HERE/data"; OUT="$HERE/data/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL.jsonl"
while read -r name url; do
  [ -z "$name" ] && continue
  body=$(curl -sk --max-time 10 "$url/check" 2>/dev/null)
  if [ -n "$body" ] && printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$body" | jq -c --arg n "$name" --arg t "$(date -u +%FT%TZ)" '. + {_app:$n,_polled_at:$t}'
  else
    jq -nc --arg n "$name" --arg t "$(date -u +%FT%TZ)" '{_app:$n,_polled_at:$t,connected:false,error:"no response"}'
  fi
done < "$LIST" >> "$OUT"
echo "snapshot: $(wc -l < "$OUT" | tr -d ' ') app(s) -> $OUT"
{ printf 'APP\tMODE\tSOURCE\tENDPOINT\tSERVER\tCONNECTED\tAUTH_USER\n'
  jq -r '[._app, (.mode//"-"), (.source//"-"), ((.endpoint//"-")|sub("\\.standalone\\..*\\.bosh"; ".bosh")), (.server//"-"), (.connected|tostring), (.auth_user//"-")] | @tsv' "$OUT"; } | column -t -s$'\t'
echo "(AUTH_USER = ACL WHOAMI: n/a on hardened Redis is expected; becomes 'default' or the binding user on Valkey)"
