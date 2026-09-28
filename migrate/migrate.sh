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
ledger_states(){
  [ -s "$LEDGER" ] || return 0
  jq -rs --arg w "$WAVE" '
    map(select($w=="" or (.wave|tostring)==$w))
    | group_by([.service, .app]) | map(last)                      # last event per (service, app)
    | .[] | [ .service, .app,
              (if .outcome=="ok" then .step else (.step + ":" + .outcome) end),
              .ts, .note,
              (if .step=="confirm" and .outcome=="ok"
               then ((.ts|fromdateiso8601) + ((((.note|capture("grace (?<h>[0-9]+)h")) // {h:"24"}).h|tonumber)*3600)
                     | strftime("%m-%d %H:%M"))
               else "" end) ] | @tsv' "$LEDGER"
}
wave_started(){ [ -s "$LEDGER" ] || { echo "-"; return; }
  jq -r --arg w "$WAVE" 'select($w=="" or (.wave|tostring)==$w) | .ts' "$LEDGER" | sort | head -1 | cut -c12-19; }

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

case "$SUB" in
  status) cmd_status ;;
  *) echo "usage: migrate.sh status [--wave N] [--run <dir>]"; exit 1 ;;
esac
