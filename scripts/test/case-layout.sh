#!/usr/bin/env bash
# case-layout.sh -- the layout populate.sh generates really produces the classes it claims (checklist row 24).
#   bash scripts/test/case-layout.sh        (no cf needed: populate.sh --layout-only)
# For each (N services, M apps) the layout must have:
#   L1  every service is the FIRST binding of at least one app (round-robin, M >= N)
#   L2  multi-bound apps exist (M >= 7; none below), and for N >= 3 at least one of them is STARTED (the "restart once" path;
#       2026-10-19: for N=10 "every 10th app" put all of them on the last, stopped service -> none started)
#   L3  no started app is bound to the last service (it stays a truly silent service); every app whose first
#       service is the last one is stopped, no other app is stopped
#   L4  no app is bound twice to the same service
#   L5  the binding graph over services has no component larger than 4 services (NP shape: pairs/chains of 2-4;
#       2026-10-19: one 7-service component for N=10 would have made a single oversized wave)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; POP="$HERE/../populate.sh"; T="${TMPDIR:-/tmp}/case-layout.$$"; mkdir -p "$T"
fail=0; ok(){ echo "  ok   $*"; }; bad(){ echo "  FAIL $*"; fail=1; }
check(){ local n="$1" m="$2" lay="$T/layout-tl.tsv" out
  out=$(bash "$POP" --services "$n" --apps "$m" --run "$T" --org o --space s --prefix tl --layout-only 2>&1) || { bad "($n,$m) populate --layout-only exited $? : $out"; return; }
  [ "$(wc -l < "$lay" | tr -d ' ')" = $((m+1)) ] || { bad "($n,$m) layout has $(wc -l < "$lay") lines, expected $((m+1))"; return; }
  echo "== ($n,$m): ${out#== layout: }"
  # per app: first service number, second (or 0), state
  awk -F'\t' -v n="$n" 'NR>1 { split($2, s, ","); f=s[1]; sub(/.*-/, "", f); f=f+0; g=0; if (s[2]!="") { g=s[2]; sub(/.*-/, "", g); g=g+0 }
      print $1, f, g, $3 }' "$lay" > "$T/apps.txt"
  # L1
  missing=$(awk -v n="$n" '{seen[$2]=1} END { for (j=1;j<=n;j++) if (!seen[j]) printf "%d ", j }' "$T/apps.txt")
  [ -z "$missing" ] && ok "($n,$m) L1 every service has an app" || bad "($n,$m) L1 services without an app: $missing"
  # L2
  mb=$(awk '$3>0' "$T/apps.txt" | wc -l | tr -d ' '); mbs=$(awk '$3>0 && $4=="started"' "$T/apps.txt" | wc -l | tr -d ' ')
  if [ "$m" -lt 7 ]; then [ "$mb" = 0 ] && ok "($n,$m) L2 no multi-bound app below 7 apps" || bad "($n,$m) L2 multi-bound $mb with fewer than 7 apps"
  elif [ "$mb" -ge 1 ] && { [ "$n" -lt 3 ] || [ "$mbs" -ge 1 ]; }; then ok "($n,$m) L2 multi-bound $mb, started $mbs"; else bad "($n,$m) L2 multi-bound $mb, started $mbs (need >=1 started for N>=3)"; fi
  # L3
  v=$(awk -v n="$n" '($2==n || $3==n) && $4=="started" {print $1}' "$T/apps.txt" | tr '\n' ' ')
  [ -z "$v" ] && ok "($n,$m) L3 no started app on the last service" || bad "($n,$m) L3 started apps bound to the last service: $v"
  v=$(awk -v n="$n" '($2==n) != ($4=="stopped") {print $1 "/" $4}' "$T/apps.txt" | tr '\n' ' ')
  [ -z "$v" ] && ok "($n,$m) L3 stopped == apps of the last service" || bad "($n,$m) L3 stopped/last-service mismatch: $v"
  # L4
  v=$(awk '$3>0 && $2==$3 {print $1}' "$T/apps.txt" | tr '\n' ' ')
  [ -z "$v" ] && ok "($n,$m) L4 no double binding to one service" || bad "($n,$m) L4 bound twice to one service: $v"
  # L5: union-find over services joined by multi-bound apps
  big=$(awk -v n="$n" 'function find(x){ while (p[x]!=x) x=p[x]; return x }
      BEGIN { for (j=1;j<=n;j++) p[j]=j } $3>0 { a=find($2); b=find($3); if (a!=b) p[a]=b }
      END { for (j=1;j<=n;j++) c[find(j)]++; mx=0; nc=0; for (r in c) { nc++; if (c[r]>mx) mx=c[r] }; print mx, nc }' "$T/apps.txt")
  set -- $big; [ "$1" -le 4 ] && ok "($n,$m) L5 largest component $1 services, $2 components" || bad "($n,$m) L5 largest component $1 services (max 4), $2 components"
}
check 10 60; check 20 120; check 2 2; check 2 14; check 5 70; check 3 21; check 6 42
rm -rf "$T"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
