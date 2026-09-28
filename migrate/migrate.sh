#!/usr/bin/env bash
# migrate.sh -- Redis->Valkey migration tool (operator layer). See DESIGN.md.
#     migrate.sh status [--wave N] [--run <dir>]      (dashboard; wrap in: watch -n 3 -c ...)
# Run dir holds waves.tsv (the plan) + ledger.jsonl (what happened) + commands.log + lock + STOP.
set -uo pipefail
SUB="${1:-}"; shift || true
RUN="."; WAVE=""
while [ "${1:-}" ]; do case "$1" in --run) RUN="$2"; shift 2;; --wave) WAVE="$2"; shift 2;; *) shift;; esac; done
PLAN="$RUN/waves.tsv"; LEDGER="$RUN/ledger.jsonl"

# ---- the ONE rule: an app's (or service's) state = its last ledger event -----------------------
# Emits TSV: service \t app \t state \t ts \t note      (app "" = service-level events)
ledger_lines(){ # every parsable line as compact JSON; a truncated/garbled line is skipped, not fatal
  [ -s "$LEDGER" ] || return 0
  jq -R -c 'fromjson? // empty' "$LEDGER"
}
ledger_bad(){ [ -s "$LEDGER" ] || { echo 0; return; }; echo $(( $(grep -c . "$LEDGER") - $(ledger_lines | grep -c .) )); }
ledger_states(){
  [ -s "$LEDGER" ] || return 0
  ledger_lines | jq -rs --arg w "$WAVE" '
    map(select($w=="" or (.wave|tostring)==$w))
    | group_by([.service, .app]) | map(last)                      # last event per (service, app)
    | .[] | [ .service, .app,
              (if .outcome=="ok" then .step else (.step + ":" + .outcome) end),
              .ts, .note,
              (if .step=="confirm" and .outcome=="ok"
               then ((.ts|fromdateiso8601) + ((((.note|capture("grace (?<h>[0-9]+)h")) // {h:"24"}).h|tonumber)*3600)
                     | strftime("%m-%d %H:%M"))
               else "" end) ] | @tsv'
}
wave_started(){ [ -s "$LEDGER" ] || { echo "-"; return; }
  ledger_lines | jq -r --arg w "$WAVE" 'select($w=="" or (.wave|tostring)==$w) | .ts' | sort | head -1 | cut -c12-19; }

cmd_status(){
  [ -s "$PLAN" ] || { echo "no $PLAN -- run: migrate.sh plan <merged_report.csv>"; exit 1; }
  local stop="no"; [ -e "$RUN/STOP" ] && stop="YES"
  local lock="free"; [ -s "$RUN/lock" ] && lock=$(cat "$RUN/lock")
  local started; started=$(wave_started)
  ledger_states > "$RUN/.states.tsv"
  awk -F'\t' -v OFS='\t' -v wave="$WAVE" -v started="$started" -v stop="$stop" -v lock="$lock" '
    function state_of(step,   s) {           # ledger step -> app state name
      s = step
      if (s=="bind-valkey")  return "BOUND-V";   if (s=="unbind-redis") return "UNBOUND-R"
      if (s=="restart")      return "RESTARTED"; if (s=="verify")       return "VERIFIED"
      if (s=="rollback")     return "ROLLED-BACK"
      if (s ~ /:fail/)       return "FAILED(" s ")";  if (s ~ /:blocked/) return "BLOCKED(" s ")"
      return toupper(s)
    }
    function rank(st) { if (st ~ /^FAILED|^BLOCKED/) return -1; if (st=="ROLLED-BACK") return 0
      if (st=="PENDING") return 1; if (st=="BOUND-V") return 2; if (st=="UNBOUND-R") return 3
      if (st=="RESTARTED") return 4; if (st=="VERIFIED") return 5; return 1 }
    FILENAME==ARGV[1] {                             # ---- pass 1: ledger states (no header)
      if ($2=="") { svc_ev[$1]=$3; svc_ts[$1]=$4; svc_note[$1]=$5; if ($6!="") standby[$1]=$6 }
      else { st[$1 SUBSEP $2]=state_of($3); ts[$1 SUBSEP $2]=$4; note[$1 SUBSEP $2]=$5 }
      if ($4 > last_ts[$1]) { last_ts[$1]=$4; last_ev[$1]=substr($4,12,8) " " ($2==""?"":$2 " ") $3 ($5!=""?" -- " substr($5,1,48):"") }
      next }
    FNR==1 { next }                                 # ---- pass 2: the plan (waves.tsv header)
    wave!="" && $1!=wave { next }
    { s=$2; a=$5; if (!(s in seen)) { order[++ns]=s; seen[s]=1; plan[s]=$4 }
      apps[s]++; k=s SUBSEP a
      state = (k in st) ? st[k] : "PENDING"
      if (index($7,"hazard")) hz[s]++
      if (rank(state) >= 4) switched[s]++
      if (state=="VERIFIED") verified[s]++
      if (rank(state) < 0) failed[s]++
      if (state=="ROLLED-BACK") rolled[s]++
      if (!(s in minrank) || rank(state) < minrank[s]) minrank[s]=rank(state)
      total_apps++ }
    END {
      printf "wave %s   services %d   apps %d   started %s   STOP: %s   lock: %s\n\n", (wave==""?"all":wave), ns, total_apps, started, stop, lock
      printf "%-15s %-12s %-14s %5s %9s %9s %-14s %s\n", "service","plan","phase","apps","switched","verified","standby-until","last event"
      for (i=1;i<=ns;i++) { s=order[i]
        ev=svc_ev[s]
        if      (ev=="retire")            phase="RETIRED"
        else if (ev=="confirm")           phase="STANDBY"
        else if (ev ~ /create-valkey:fail/) phase="CREATE-FAILED"
        else if (ev ~ /copy-data:fail/)   phase="COPY-FAILED"
        else if (failed[s]>0)             phase="ATTENTION"
        else if (rolled[s]>0 && switched[s]==0) phase="ROLLED-BACK"
        else if (verified[s]==apps[s])    phase="VERIFIED"
        else if (switched[s]>0 || minrank[s]>=2) phase="MIGRATING"
        else if (ev=="create-valkey")     phase="READY"
        else                              phase="PENDING"
        sb=(s in standby) ? standby[s] : "-"
        mark=""; if (phase ~ /FAILED|ATTENTION|ROLLED/) mark="  !!"
        printf "%-15s %-12s %-14s %5d %9s %9s %-14s %s%s\n", s, plan[s], phase, apps[s], switched[s]+0 "/" apps[s], (verified[s]+0) "/" apps[s], sb, (s in last_ev ? last_ev[s] : "-"), mark
      }
      hzn=0; for (s in hz) hzn+=hz[s]
      if (hzn>0) printf "\n!! %d hazard app(s) in scope (pinned env) -- preflight will refuse until fixed\n", hzn
    }' "$RUN/.states.tsv" "$PLAN"
  # per-app detail for services needing attention
  awk -F'\t' 'NR>1 && $2!="" && ($3 ~ /fail|blocked|rollback/) {printf "   %-15s %-15s %-28s %s\n", $1, $2, $3, $5}' "$RUN/.states.tsv" | { read -r first && { echo; echo "attention:"; echo "$first"; cat; }; }
  rm -f "$RUN/.states.tsv"
}

# ---- project summary: per wave + totals, percentages; also writes derived snapshots ------------
cmd_summary(){
  [ -s "$PLAN" ] || { echo "no $PLAN -- run: migrate.sh plan <merged_report.csv>"; exit 1; }
  local bad; bad=$(ledger_bad); mkdir -p "$RUN/status"
  WAVE="" ledger_states > "$RUN/.states.tsv"
  printf 'wave\tservice\tapp\tstate\tnote\n' > "$RUN/status/failed.tsv"; printf 'wave\tservice\tapp\tstate\n' > "$RUN/status/migrated.tsv"
  awk -F'\t' -v OFS='\t' -v bad="$bad" -v sdir="$RUN/status" -v now="$(date -u +%FT%TZ)" '
    function rank(st) { if (st ~ /fail|blocked/) return -1; if (st=="rollback") return 0
      if (st=="bind-valkey") return 2; if (st=="unbind-redis") return 3; if (st=="restart") return 4; if (st=="verify") return 5; return 1 }
    function pct(a,b) { return b ? sprintf("%3d%%", a*100/b) : "  -" }
    FILENAME==ARGV[1] { if ($2=="") svc_ev[$1]=$3; else { st[$1 SUBSEP $2]=$3; note[$1 SUBSEP $2]=$5 }; next }
    FNR==1 { next }
    { w=$1; s=$2; a=$5; if (!(w in seenw)) { worder[++nw]=w; seenw[w]=1 }
      if (!(s in seens)) { seens[s]=1; wsvc[w]++; ev=svc_ev[s]
        if (ev=="create-valkey" || ev=="confirm" || ev=="retire") wcreated[w]++
        if (ev ~ /create-valkey:fail/) wcfail[w]++
        if (ev=="confirm") wstandby[w]++
        if (ev=="retire")  wretired[w]++ }
      wconn[w]++; k=s SUBSEP a; state=(k in st)?st[k]:"pending"; r=rank(state)
      if (r>=4) wmig[w]++;  if (r==5) wver[w]++;  if (r<0) { wfail[w]++; print w, s, a, state, note[k] >> (sdir "/failed.tsv") }
      if (r==0) wrb[w]++;   if (r==1) wpend[w]++;  if (r==2 || r==3) wprog[w]++
      if (r>=4) print w, s, a, state >> (sdir "/migrated.tsv")
      print w, s, a, state, note[k] > (sdir "/wave-" w ".tsv") }
    END {
      print "generated " now "  (ledger lines skipped as unparsable: " bad ")" > (sdir "/summary.tsv")
      print "wave\tservices\tcreated\tcreate_fail\tstandby\tretired\tconnections\tmigrated\tverified\tfailed\trolled_back\tin_progress\tpending" > (sdir "/summary.tsv")
      printf "%-5s %8s %8s %7s %7s %7s | %11s %14s %14s %7s %11s %8s %7s\n", "wave","services","created","c-fail","standby","retired","connections","migrated","verified","failed","rolled-back","in-prog","pending"
      for (i=1;i<=nw;i++) { w=worder[i]
        printf "%-5s %8d %8d %7d %7d %7d | %11d %9d %4s %9d %4s %7d %11d %8d %7d\n", w, wsvc[w], wcreated[w]+0, wcfail[w]+0, wstandby[w]+0, wretired[w]+0, wconn[w], wmig[w]+0, pct(wmig[w],wconn[w]), wver[w]+0, pct(wver[w],wconn[w]), wfail[w]+0, wrb[w]+0, wprog[w]+0, wpend[w]+0
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", w, wsvc[w], wcreated[w]+0, wcfail[w]+0, wstandby[w]+0, wretired[w]+0, wconn[w], wmig[w]+0, wver[w]+0, wfail[w]+0, wrb[w]+0, wprog[w]+0, wpend[w]+0 > (sdir "/summary.tsv")
        T[1]+=wsvc[w]; T[2]+=wcreated[w]; T[3]+=wcfail[w]; T[4]+=wstandby[w]; T[5]+=wretired[w]; T[6]+=wconn[w]; T[7]+=wmig[w]; T[8]+=wver[w]; T[9]+=wfail[w]; T[10]+=wrb[w]; T[11]+=wpend[w]; T[12]+=wprog[w] }
      printf "%-5s %8d %8d %7d %7d %7d | %11d %9d %4s %9d %4s %7d %11d %8d %7d\n", "TOTAL", T[1],T[2],T[3],T[4],T[5],T[6],T[7],pct(T[7],T[6]),T[8],pct(T[8],T[6]),T[9],T[10],T[12],T[11]
      printf "TOTAL\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", T[1],T[2],T[3],T[4],T[5],T[6],T[7],T[8],T[9],T[10],T[12],T[11] > (sdir "/summary.tsv")
      n=40; f=T[6]?int(n*T[8]/T[6]):0; bar=""; for (j=0;j<n;j++) bar=bar (j<f?"#":".")
      printf "\nverified  [%s] %s of %d connections   |  services retired %d/%d\n", bar, pct(T[8],T[6]), T[6], T[5], T[1]
      if (T[9]>0) printf "!! %d connection(s) failed/blocked -- see status/failed.tsv or: migrate.sh status --wave N\n", T[9]
      if (bad>0)  printf "!! %d ledger line(s) unparsable (crash mid-write?) -- skipped; check the tail of ledger.jsonl\n", bad
    }' "$RUN/.states.tsv" "$PLAN"
  rm -f "$RUN/.states.tsv"
}

case "$SUB" in
  status) if [ -n "$WAVE" ]; then cmd_status; else cmd_summary; fi ;;
  *) echo "usage: migrate.sh status [--wave N] [--run <dir>]"; exit 1 ;;
esac
