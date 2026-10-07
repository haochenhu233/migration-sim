#!/usr/bin/env bash
# migrate.sh -- Redis->Valkey migration tool (operator layer). See DESIGN.md.
#     migrate.sh status [--wave N] [--run <dir>]      (dashboard; wrap in: watch -n 3 -c ...)
# Run dir holds waves.tsv (the plan) + ledger.jsonl (what happened) + commands.log + lock + STOP.
set -uo pipefail
SUB="${1:-}"; shift || true
RUN="."; WAVE=""
WSIZE=""; MAXAPPS=""; SILENTMAX=""; ORDER=""; FREE_IPS=""; SVCRE=""; ARG=""
while [ "${1:-}" ]; do case "$1" in --run) RUN="$2"; shift 2;; --wave) WAVE="$2"; shift 2;; --wave-size) WSIZE="$2"; shift 2;; --max-apps) MAXAPPS="$2"; shift 2;; --silent-max-apps) SILENTMAX="$2"; shift 2;; --order) ORDER="$2"; shift 2;; --free-ips) FREE_IPS="$2"; shift 2;; --services) SVCRE="$2"; shift 2;; -*) shift;; *) ARG="$1"; shift;; esac; done
PLAN="$RUN/waves.tsv"; LEDGER="$RUN/ledger.jsonl"


# ---- plan: merged/aggregated report -> waves.tsv (detailed, stays in env) + plan-summary.md (aggregates only)
#   migrate.sh plan <merged_report.csv|aggregated_report.csv> [--run <dir>] [--wave-size N] [--max-apps M] [--order easy|hard]
#   --wave-size N  max services per wave (default 10)      --max-apps M  max app restarts per wave (default 40)
#   --silent-max-apps S  restart cap for waves made only of SILENT services (no live consumer; default 120)
#                        -- nobody observes them, so they can be batched large
#   --order easy   (default) silent services first (no live consumer), then islands, then shared, then multi-service
#   --order hard   largest components first
#   --services <ERE>  only services whose NAME matches (e.g. '^sim-redis-' in SBX); others are
#                     excluded and counted -- the scan covers the whole foundation
# Rows whose method is not cf-bind (static-ref / unknown / api-error) get flag no-binding:<method>:
# the app consumes the Redis without a binding, so the tool cannot rebind it -- dry-run/apply list
# it as a TEAM action (update env / UPS / config) and skip it.
# Waves = connected components of the app<->service binding graph (an app and every service it
# is bound to travel together => one restart per app), packed largest-first, max N services per
# wave (a component larger than N gets its own wave). Services keyed by GUID (DESIGN 1a).
cmd_plan(){
  local rep="$1"; [ -s "$rep" ] || { echo "usage: migrate.sh plan <report.csv> [--run dir] [--wave-size N]"; exit 1; }
  mkdir -p "$RUN"
  awk -F',' -v OFS='\t' -v wsize="${WSIZE:-10}" -v maxapps="${MAXAPPS:-40}" -v silentmax="${SILENTMAX:-120}" -v order="${ORDER:-easy}" -v svcre="$SVCRE" -v run="$RUN" -v now="$(date -u +%FT%TZ)" '
    function find(x){ while (par[x]!=x) { par[x]=par[par[x]]; x=par[x] } return x }
    function union(a,b,  ra,rb){ ra=find(a); rb=find(b); if (ra!=rb) par[rb]=ra }
    function plan_of(dep,  p){ p=dep; sub(/^(redis|valkey)-/,"",p); sub(/-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,"",p); return p }
    NR==1 { for (i=1;i<=NF;i++) col[$i]=i; LIVE=("ever_live" in col)?col["ever_live"]:col["live_connection"]; next }
    {
      gsub(/\r$/,"")
      ag=$col["app_guid"]; sg=$col["service_instance_guid"]
      if (ag=="" || sg=="" || sg=="?" || $col["app_name"] ~ /^EXTERNAL/) { skipped++; next }
      if ($col["deployment_exists"]=="no") { ghosts[sg]=1; ghostrows++; next }
      if (svcre!="" && $col["redis_service_name"] !~ svcre) { excluded[sg]=1; exrows++; next }
      k=ag SUBSEP sg; if (k in seen) next; seen[k]=1; rows++
      if ($col["method"]!="cf-bind") { nob[k]=$col["method"]; nnob++ }
      app[ag]=$col["app_name"]; aorg[ag]=$col["org"]; asp[ag]=$col["space"]; aplat[ag]=$col["platform"]
      svc[sg]=$col["redis_service_name"]; sorg[sg]=$col["redis_service_org"]; ssp[sg]=$col["redis_service_space"]
      splan[sg]=plan_of($col["redis_deployment"]); sdep[sg]=$col["redis_deployment"]
      edge[rows]=k
      if ($col["method"]=="cf-bind" && $col["static_ref"]!="") { hz[k]=1; nhz++; hzapp[ag]=1 }
      if ($LIVE=="no") { idle[k]=1; nidle++ } else live[k]=1
      if ($col["org"]!=$col["redis_service_org"] || $col["space"]!=$col["redis_service_space"]) { xs[k]=1; xsvc[sg]=1 }
      nbound[ag]++; sapps[sg]++
      if (!("a"ag in par)) par["a"ag]="a"ag; if (!("s"sg in par)) par["s"sg]="s"sg; union("a"ag,"s"sg)
    }
    END {
      # components
      for (a in app) { r=find("a"a); capp[r]++; cmembers_a[r]=cmembers_a[r] " " a }
      for (sg in svc){ r=find("s"sg); csvc[r]++; cmembers_s[r]=cmembers_s[r] " " sg; comp_of[sg]=r }
      nc=0; for (r in csvc) { cl[++nc]=r }
      # live apps per component (0 = silent: every connection idle)
      for (i=1;i<=rows;i++){ k=edge[i]; split(k,kk,SUBSEP); if (k in live) clive[find("s"kk[2])]++ }
      # sort key: easy = (silent first, then by services asc, apps asc); hard = services desc, apps desc
      for (i=1;i<=nc;i++){ r=cl[i]; if (order=="hard") skey[r]=sprintf("%05d%05d", 99999-csvc[r], 99999-capp[r]); else skey[r]=sprintf("%d%05d%05d", (clive[r]>0?1:0), csvc[r], capp[r]) }
      for (i=2;i<=nc;i++){ v=cl[i]; j=i-1; while (j>0 && skey[cl[j]]>skey[v]) { cl[j+1]=cl[j]; j-- } cl[j+1]=v }
      # pack into waves: both caps -- services per wave AND app restarts per wave
      # silent components (no live consumer anywhere) get their own, larger caps: nobody observes them
      w=1; used=0; usedapps=0; wsil=-1
      for (i=1;i<=nc;i++) { r=cl[i]; sil=(clive[r]==0)?1:0
        capA=sil?silentmax:maxapps; capS=sil?wsize*3:wsize
        if ((used>0 && used+csvc[r] > capS) || (usedapps>0 && usedapps+capp[r] > capA) || (wsil>=0 && wsil!=sil)) { w++; used=0; usedapps=0 }
        wsil=sil
        cw[r]=w; used+=csvc[r]; usedapps+=capp[r]; wsvc[w]+=csvc[r]; wapp[w]+=capp[r]; wcomp[w]++; if (sil) wsilent[w]+=csvc[r]
        if (csvc[r]>capS || capp[r]>capA) { w++; used=0; usedapps=0; wsil=-1 }   # an oversized component owns its wave
      }
      nw=w; if (used==0) nw=w-1
      # ---- waves.tsv (detailed; stays in the env)
      f=run "/waves.tsv"
      print "wave","component","service","service_guid","service_org","service_space","valkey_plan","app","app_guid","app_org","app_space","flags" > f
      for (i=1;i<=rows;i++) { k=edge[i]; split(k, kk, SUBSEP); ag=kk[1]; sg=kk[2]; r=comp_of[sg]
        fl=""; if (k in hz) fl=fl "hazard,"; if (k in idle) fl=fl "idle,"; if (k in xs) fl=fl "cross-space,"
        if (nbound[ag]>1) fl=fl "multi-bound,"; if (aplat[ag]=="windows") fl=fl "windows,"
        if (k in nob) { m=nob[k]; gsub(/[ :]+/,"-",m); fl=fl "no-binding:" m "," }
        sub(/,$/,"",fl)
        cid=substr(r,2,8)
        print cw[r], cid, svc[sg], sg, sorg[sg], ssp[sg], splan[sg], app[ag], ag, aorg[ag], asp[ag], fl > f
        wteams[cw[r] SUBSEP aorg[ag]]=1
      }
      # ---- components.tsv (detailed)
      g=run "/components.tsv"; print "component","wave","services","apps","service_names" > g
      for (i=1;i<=nc;i++) { r=cl[i]; names=""; n=split(cmembers_s[r], ms, " "); for (j=1;j<=n;j++) names=names (names==""?"":";") svc[ms[j]]
        print substr(r,2,8), cw[r], csvc[r], capp[r], names > g }
      # ---- plan-summary.md (AGGREGATES ONLY -- safe to share)
      h=run "/plan-summary.md"
      nsvc=0; for (sg in svc) nsvc++; napp=0; for (a in app) napp++
      nmb=0; for (a in app) if (nbound[a]>1) nmb++
      nxsvc=0; for (sg in xsvc) nxsvc++; nhzapp=0; for (a in hzapp) nhzapp++
      nwin=0; for (a in app) if (aplat[a]=="windows") nwin++
      norg=0; for (a in app) if (!(aorg[a] in orgs)) { orgs[aorg[a]]=1; norg++ }
      ng=0; for (x in ghosts) ng++
      # idle-only services: every connection idle
      for (i=1;i<=rows;i++){ k=edge[i]; split(k,kk,SUBSEP); if (k in live) slive[kk[2]]=1 }
      nidlesvc=0; for (sg in svc) if (!(sg in slive)) nidlesvc++
      # component histogram
      for (i=1;i<=nc;i++){ r=cl[i]; key=(csvc[r]==1 && capp[r]==1)?"1 svc / 1 app": (csvc[r]==1)?"1 svc / n apps": (csvc[r]<=3)?"2-3 svcs":(csvc[r]<=10)?"4-10 svcs":">10 svcs"; hist[key]++ }
      printf "# Migration plan summary (aggregates only)\n\ngenerated %s from %s\n\n", now, FILENAME > h
      printf "| metric | value |\n|---|---|\n" > h
      printf "| connections (app↔service, deduped) | %d |\n| services | %d |\n| apps | %d |\n| orgs (≈teams) | %d |\n", rows, nsvc, napp, norg > h
      nex=0; for (x in excluded) nex++
      printf "| rows skipped (external / no guid) | %d |\n| ghost services excluded (no deployment) | %d (%d rows) |\n", skipped, ng, ghostrows > h
      if (svcre!="") printf "| services excluded by --services %s | %d (%d rows) |\n", svcre, nex, exrows > h
      printf "| connections WITHOUT a binding (static-ref / unknown -> team action, tool skips) | %d |\n", nnob > h
      printf "| multi-bound apps (2+ services → 1 restart per wave) | %d |\n| services used across spaces/orgs (joint window + sharing) | %d |\n", nmb, nxsvc > h
      printf "| hazard apps (cf-bind + pinned ref) | %d (%d connections) |\n| idle connections (no live seen) | %d |\n| services with NO live connection at all | %d |\n| windows apps | %d |\n\n", nhzapp, nhz, nidle, nidlesvc, nwin > h
      printf "## Binding-graph components: %d\n\n| shape | count |\n|---|---|\n", nc > h
      for (key in hist) printf "| %s | %d |\n", key, hist[key] > h
      # apps-per-service distribution (how heavy are the shared services)
      for (sg in svc){ n=sapps[sg]; b=(n==1)?"1 app":(n<=5)?"2-5 apps":(n<=20)?"6-20 apps":(n<=50)?"21-50 apps":">50 apps"; aps[b]++; if (n>maxaps) maxaps=n }
      printf "\n## Apps per service\n\n| apps bound | services |\n|---|---|\n" > h
      for (b in aps) printf "| %s | %d |\n", b, aps[b] > h
      printf "\nmost-shared service: %d apps (one restart each when its wave runs)\n", maxaps > h
      # largest components by size, independent of wave ordering
      for (i=1;i<=nc;i++) big[i]=cl[i]
      for (i=2;i<=nc;i++){ v=big[i]; j=i-1; while (j>0 && (csvc[big[j]]<csvc[v] || (csvc[big[j]]==csvc[v] && capp[big[j]]<capp[v]))) { big[j+1]=big[j]; j-- } big[j+1]=v }
      printf "\nlargest components (services/apps): " > h
      for (i=1;i<=5 && i<=nc;i++) printf "%s%d/%d", (i>1?", ":""), csvc[big[i]], capp[big[i]] > h
      printf "\n\n## Wave proposal (live waves: max %d services / %d restarts; silent waves: max %d services / %d restarts; order=%s)\n\n| wave | services | silent svcs | apps (restarts) | components | orgs |\n|---|---|---|---|---|---|\n", wsize, maxapps, wsize*3, silentmax, order > h
      for (w=1;w<=nw;w++){ t=0; for (x in wteams){ split(x,xx,SUBSEP); if (xx[1]==w) t++ }
        printf "| %d | %d | %d | %d | %d | %d |\n", w, wsvc[w], wsilent[w]+0, wapp[w], wcomp[w], t > h }
      printf "\nIP headroom needed: %d Valkeys in total (one per service); per wave as above.\n", nsvc > h
      printf "\nDetailed files (stay in the environment): waves.tsv, components.tsv\n" > h
      printf "plan: %d connections, %d services, %d apps -> %d component(s) in %d wave(s)\n", rows, nsvc, napp, nc, nw
      printf "plan: wrote %s/waves.tsv, %s/components.tsv (detailed) and %s/plan-summary.md (aggregates only -- shareable)\n", run, run, run
    }' "$rep"
}

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
    { s=$4; a=$9; if (!(s in seen)) { order[++ns]=s; seen[s]=1; plan[s]=$7; disp[s]=$3 " (" substr($4,1,8) ")" }
      apps[s]++; k=s SUBSEP a
      state = (k in st) ? st[k] : "PENDING"
      if (index($12,"hazard")) hz[s]++
      if (rank(state) >= 4) switched[s]++
      if (state=="VERIFIED") verified[s]++
      if (rank(state) < 0) failed[s]++
      if (state=="ROLLED-BACK") rolled[s]++
      if (!(s in minrank) || rank(state) < minrank[s]) minrank[s]=rank(state)
      total_apps++ }
    END {
      printf "wave %s   services %d   apps %d   started %s   STOP: %s   lock: %s\n\n", (wave==""?"all":wave), ns, total_apps, started, stop, lock
      printf "%-28s %-12s %-14s %5s %9s %9s %-14s %s\n", "service (guid)","plan","phase","apps","switched","verified","standby-until","last event"
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
        printf "%-28s %-12s %-14s %5d %9s %9s %-14s %s%s\n", disp[s], plan[s], phase, apps[s], switched[s]+0 "/" apps[s], (verified[s]+0) "/" apps[s], sb, (s in last_ev ? last_ev[s] : "-"), mark
      }
      hzn=0; for (s in hz) hzn+=hz[s]
      if (hzn>0) printf "\n!! %d hazard app(s) in scope (pinned env) -- preflight will refuse until fixed\n", hzn
    }' "$RUN/.states.tsv" "$PLAN"
  # per-app detail for services needing attention
  awk -F'\t' 'NR>1 && $2!="" && ($3 ~ /fail|blocked|rollback/) {printf "   %-15s %-15s %-28s %s\n", $1, $2, $3, $5}' "$RUN/.states.tsv" | { read -r first && { echo; echo "attention:"; echo "$first"; cat; }; }
  rm -f "$RUN/.states.tsv"
}


# ============================================================================ cf helpers
CF="${CF_CMD:-cf}"
if command -v timeout >/dev/null 2>&1; then TMO="timeout 30"; else TMO=""; fi   # macOS has no timeout(1)
cfcurl(){ $TMO "$CF" curl "$1" 2>/dev/null; }                      # read-only CF API
cf_json_ok(){ printf '%s' "$1" | jq -e 'type=="object" and (has("errors")|not)' >/dev/null 2>&1; }
# cflist <path>: a LIST endpoint; prints the JSON only if it really has .resources -- an error
# document (bad filter, auth) must never be read as "empty list". Returns 1 on API error.
cflist(){ local j; j=$(cfcurl "$1"); printf '%s' "$j" | jq -e 'type=="object" and has("resources")' >/dev/null 2>&1 || return 1; printf '%s' "$j"; }

# wave_rows <N>: the wave's plan rows (TSV, no header). Columns: see cmd_plan header.
wave_rows(){ awk -F'\t' -v w="$1" 'NR>1 && $1==w' "$PLAN"; }
# ledger_done <service_guid> <app_guid|""> <step>: "ts" if the ledger has that step ok, else ""
ledger_done(){ [ -s "$LEDGER" ] || return 0
  ledger_lines | jq -r --arg s "$1" --arg a "$2" --arg st "$3" 'select(.service==$s and .app==$a and .step==$st and .outcome=="ok") | .ts' | tail -1; }

# ============================================================================ dry-run
# dry-run --wave N: the exact command sequence apply would run, in the rehearsed order:
#   per service: rename-standby, create-valkey (under the ORIGINAL name), copy-data if flagged
#   per app:     bind every wave service, unbind every standby, ONE restart, verify
# Steps already recorded ok in the ledger are marked DONE and skipped by apply (idempotent).
cmd_dryrun(){
  [ -n "$WAVE" ] || { echo "usage: migrate.sh dry-run --wave N [--run dir]"; exit 1; }
  [ -s "$PLAN" ] || { echo "no $PLAN"; exit 1; }
  local rows; rows=$(wave_rows "$WAVE"); [ -n "$rows" ] || { echo "wave $WAVE: no rows in $PLAN"; exit 1; }
  local nsvc napp norg; nsvc=$(printf '%s\n' "$rows" | cut -f4 | sort -u | wc -l | tr -d ' ')
  napp=$(printf '%s\n' "$rows" | cut -f9 | sort -u | wc -l | tr -d ' '); norg=$(printf '%s\n' "$rows" | cut -f10 | sort -u | wc -l | tr -d ' ')
  echo "DRY-RUN wave $WAVE: $nsvc service(s), $napp app(s) ($napp restarts), $norg org(s). Nothing is executed."
  echo "rollback row per step -- see DESIGN §3; rollback scope = the whole service."
  echo
  # ---- phase A: per service
  printf '%s\n' "$rows" | awk -F'\t' '!seen[$4]++ {print $4"\t"$3"\t"$5"\t"$6"\t"$7"\t"$12}' | while IFS=$'\t' read -r sg name sorg ssp plan flags; do
    local std="${name}-redis-standby"
    echo "== service $name ($(printf '%s' "$sg" | cut -c1-8))  plan=$plan  org/space=$sorg/$ssp  flags=[$flags]"
    echo "   cf target -o $sorg -s $ssp"
    d=$(ledger_done "$sg" "" rename-standby); echo "   ${d:+DONE $d  }cf rename-service $name $std                 # rollback: rename back (only if abandoning)"
    d=$(ledger_done "$sg" "" create-valkey);  echo "   ${d:+DONE $d  }cf create-service valkey $plan $name           # rollback: cf delete-service $name"
    echo "   ${d:+DONE          }assert: '$name' resolves to a VALKEY instance (new guid), '$std' resolves to guid $(printf '%s' "$sg" | cut -c1-8)"
    case ",$flags," in *,datastore,*) d=$(ledger_done "$sg" "" copy-data); echo "   ${d:+DONE $d  }copy-data $std -> $name  (replication / MIGRATE / DUMP-RESTORE per SESSION-COMMANDS 8c)   # rollback: none needed";; esac
  done
  echo
  # ---- phase B: per app (one restart per app per wave)
  printf '%s\n' "$rows" | awk -F'\t' '!seen[$9]++ {print $9"\t"$8"\t"$10"\t"$11"\t"$12}' | while IFS=$'\t' read -r ag app aorg asp aflags; do
    echo "== app $app ($(printf '%s' "$ag" | cut -c1-8))  org/space=$aorg/$asp  flags=[$aflags]"
    echo "   cf target -o $aorg -s $asp"
    case ",$aflags," in *,hazard,*) echo "   !! HAZARD: pinned env present -- preflight refuses until the app team removed it";; esac
    case ",$aflags," in *,no-binding:*) echo "   SKIP  no binding (${aflags##*no-binding:}) -- TEAM ACTION: update env var / UPS / config to the Valkey; nothing for the tool to rebind"; echo; continue;; esac
    # every wave service this app is bound to
    printf '%s\n' "$rows" | awk -F'\t' -v a="$ag" '$9==a {print $4"\t"$3}' | while IFS=$'\t' read -r sg name; do
      d=$(ledger_done "$sg" "$ag" bind-valkey);  echo "   ${d:+DONE $d  }cf bind-service $app $name                      # rollback: cf unbind-service $app $name"
    done
    printf '%s\n' "$rows" | awk -F'\t' -v a="$ag" '$9==a {print $4"\t"$3}' | while IFS=$'\t' read -r sg name; do
      d=$(ledger_done "$sg" "$ag" unbind-redis); echo "   ${d:+DONE $d  }cf unbind-service $app ${name}-redis-standby   # rollback: cf bind-service $app ${name}-redis-standby"
    done
    sg1=$(printf '%s\n' "$rows" | awk -F'\t' -v a="$ag" '$9==a {print $4; exit}')
    d=$(ledger_done "$sg1" "$ag" restart);  echo "   ${d:+DONE $d  }cf restart $app [--strategy rolling if >=2 instances]  # rollback: rebind standby + restart"
    d=$(ledger_done "$sg1" "$ag" verify);   echo "   ${d:+DONE $d  }verify $app: L1 bindings+running+no crashes · L2 census on valkey, none on standby · L3 CLIENT LIST/ACL LOG   # fail: auto-rollback the SERVICE"
  done
  echo
  echo "end of wave: services -> STANDBY (grace $(( ${GRACE_DAYS:-14} )) d); no retire."
}

# ============================================================================ preflight
# preflight --wave N: read-only checks; FAIL = apply must not run. Prints the blast radius.
cmd_preflight(){
  [ -n "$WAVE" ] || { echo "usage: migrate.sh preflight --wave N [--run dir]"; exit 1; }
  [ -s "$PLAN" ] || { echo "no $PLAN"; exit 1; }
  local rows; rows=$(wave_rows "$WAVE"); [ -n "$rows" ] || { echo "wave $WAVE: no rows in $PLAN"; exit 1; }
  local fails=0 warns=0
  ok(){ printf 'PASS  %s\n' "$1"; }; fail(){ printf 'FAIL  %s\n' "$1"; fails=$((fails+1)); }; warn(){ printf 'WARN  %s\n' "$1"; warns=$((warns+1)); }
  echo "PREFLIGHT wave $WAVE (run dir: $RUN)"
  # 1 run-dir state
  if [ -s "$RUN/lock" ]; then fail "lock held: $(cat "$RUN/lock")"; else ok "no lock"; fi
  [ -e "$RUN/STOP" ] && fail "STOP file present ($RUN/STOP)" || ok "no STOP file"
  local bad; bad=$(ledger_bad); [ "$bad" = 0 ] && ok "ledger parses ($(grep -c . "$LEDGER" 2>/dev/null || echo 0) lines)" || warn "$bad unparsable ledger line(s)"
  # 2 cf session
  local info; info=$(cfcurl "/v3/info"); if cf_json_ok "$info"; then ok "cf API reachable ($(printf '%s' "$info" | jq -r '.name // "cf"'))"; else fail "cf curl /v3/info failed -- not logged in?"; fi
  # 3 per service
  while IFS=$'\t' read -r sg name sorg ssp plan flags; do
    local j; j=$(cfcurl "/v3/service_instances/$sg")
    if ! cf_json_ok "$j"; then fail "service $name: guid $sg not found"; continue; fi
    local cur st; cur=$(printf '%s' "$j" | jq -r .name); st=$(printf '%s' "$j" | jq -r '.last_operation.state')
    local ren; ren=$(ledger_done "$sg" "" rename-standby)
    if [ -n "$ren" ]; then [ "$cur" = "${name}-redis-standby" ] && ok "service $name: already renamed to standby (ledger agrees)" || fail "service $name: ledger says renamed but CF name is '$cur' (drift)"
    else [ "$cur" = "$name" ] && ok "service $name: name matches guid $(printf '%s' "$sg" | cut -c1-8)" || fail "service $name: guid now named '$cur' (drift -- renamed by hand?)"; fi
    [ "$st" = succeeded ] && ok "service $name: last operation succeeded" || fail "service $name: last_operation=$st"
    # name collisions in the service's space
    local sp; sp=$(printf '%s' "$j" | jq -r '.relationships.space.data.guid')
    local cre; cre=$(ledger_done "$sg" "" create-valkey)
    local lj
    if lj=$(cflist "/v3/service_instances?names=${name}-redis-standby&space_guids=$sp"); then
      if [ -z "$ren" ] && [ "$(printf '%s' "$lj" | jq -r '.resources|length')" != 0 ]; then fail "service $name: '${name}-redis-standby' already exists in the space"; fi
    else fail "service $name: API error checking the standby name (cannot rule out a collision)"; fi
    if [ -z "$cre" ]; then
      if lj=$(cflist "/v3/service_instances?names=$name&space_guids=$sp"); then
        local vk; vk=$(printf '%s' "$lj" | jq -r '.resources[] | select(.guid!="'"$sg"'") | .guid' | head -1)
        [ -n "$vk" ] && fail "service $name: another instance already carries the name (guid $vk) -- create would collide"
      else fail "service $name: API error checking the service name (cannot rule out a collision)"; fi
    fi
    # plan visible in that space (classic plan expected)
    if lj=$(cflist "/v3/service_plans?names=$plan&service_offering_names=valkey&space_guids=$sp&available=true"); then
      [ "$(printf '%s' "$lj" | jq -r '.resources|length')" != 0 ] && ok "service $name: valkey plan '$plan' available in space" || fail "service $name: valkey plan '$plan' not available in space (marketplace/visibility)"
    else fail "service $name: API error checking plan '$plan'"; fi
    case "$plan" in *secure*) warn "service $name: plan '$plan' looks like a SECURE (dynamic-credential) plan -- intended?";; esac
  done < <(printf '%s\n' "$rows" | awk -F'\t' '!seen[$4]++ {print $4"\t"$3"\t"$5"\t"$6"\t"$7"\t"$12}')
  # 4 per app
  while IFS=$'\t' read -r ag app aflags; do
    case ",$aflags," in *,no-binding:*) ok "app $app: no binding (${aflags##*no-binding:}) -- team action, tool will skip"; continue;; esac
    local a; a=$(cfcurl "/v3/apps/$ag")
    if ! cf_json_ok "$a"; then fail "app $app: guid $ag not found"; continue; fi
    local state; state=$(printf '%s' "$a" | jq -r .state)
    [ "$state" = STARTED ] && ok "app $app: STARTED" || warn "app $app: state $state (idle app? it will be restarted anyway)"
    local stats; stats=$(cfcurl "/v3/apps/$ag/processes/web/stats")
    if cf_json_ok "$stats"; then
      local n r; n=$(printf '%s' "$stats" | jq -r '.resources|length'); r=$(printf '%s' "$stats" | jq -r '[.resources[]|select(.state=="RUNNING")]|length')
      [ "$n" = "$r" ] && ok "app $app: $r/$n instance(s) running" || fail "app $app: only $r/$n instances running -- fix BEFORE migrating (a broken app looks like a migration failure after)"
    else warn "app $app: no web process stats"; fi
    case ",$aflags," in *,hazard,*)
      local envj; envj=$(cfcurl "/v3/apps/$ag/environment_variables")
      if ! { cf_json_ok "$envj" && printf '%s' "$envj" | jq -e 'has("var")' >/dev/null 2>&1; }; then
        fail "app $app: cannot read environment variables (API error / role lacks access) -- hazard cannot be ruled out"
      elif printf '%s' "$envj" | jq -r '.var|to_entries[]|"\(.key)=\(.value)"' 2>/dev/null | grep -qiE '(REDIS|VALKEY)[_A-Z0-9]*(HOST|URL|URI|ADDR|ENDPOINT)|redis://'; then
        fail "app $app: HAZARD -- pinned redis env var still present; the team must remove it first"
      else ok "app $app: hazard flag but no pinned env var found now (fixed)"; fi;;
    esac
  done < <(printf '%s\n' "$rows" | awk -F'\t' '!seen[$9]++ {print $9"\t"$8"\t"$12}')
  # 5 blast radius
  local nsvc napp norg nsil nhz; nsvc=$(printf '%s\n' "$rows" | cut -f4 | sort -u | wc -l | tr -d ' '); napp=$(printf '%s\n' "$rows" | cut -f9 | sort -u | wc -l | tr -d ' ')
  norg=$(printf '%s\n' "$rows" | cut -f10 | sort -u | wc -l | tr -d ' '); nhz=$(printf '%s\n' "$rows" | awk -F'\t' '$12 ~ /hazard/' | wc -l | tr -d ' ')
  echo
  echo "BLAST RADIUS wave $WAVE: $nsvc service(s) -> $nsvc Valkey(s) to create (IPs needed: $nsvc), $napp app restart(s), $norg org(s); hazards in wave: $nhz"
  [ -n "${FREE_IPS:-}" ] && { [ "$FREE_IPS" -ge "$nsvc" ] && ok "IP headroom: $FREE_IPS free >= $nsvc needed" || fail "IP headroom: $FREE_IPS free < $nsvc needed"; } || warn "IP headroom not checked (pass --free-ips N from the blacksmith pool / cloud-config)"
  echo
  if [ "$fails" -gt 0 ]; then echo "PREFLIGHT: $fails FAIL, $warns WARN -- do not apply"; exit 1; else echo "PREFLIGHT: OK ($warns WARN)"; fi
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
    { w=$1; s=$4; a=$9; if (!(w in seenw)) { worder[++nw]=w; seenw[w]=1 }
      if (!(s in seens)) { seens[s]=1; wsvc[w]++; ev=svc_ev[s]
        if (ev=="create-valkey" || ev=="confirm" || ev=="retire") wcreated[w]++
        if (ev ~ /create-valkey:fail/) wcfail[w]++
        if (ev=="confirm") wstandby[w]++
        if (ev=="retire")  wretired[w]++ }
      wconn[w]++; k=s SUBSEP a; state=(k in st)?st[k]:"pending"; r=rank(state)
      if (r>=4) wmig[w]++;  if (r==5) wver[w]++;  if (r<0) { wfail[w]++; print w, s, a, state, note[k] >> (sdir "/failed.tsv") }
      if (r==0) wrb[w]++;   if (r==1) wpend[w]++;  if (r==2 || r==3) wprog[w]++
      if (r>=4) print w, $3, $8, state >> (sdir "/migrated.tsv")
      print w, $3, $8, state, note[k] > (sdir "/wave-" w ".tsv") }
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
  plan)      cmd_plan "$ARG" ;;
  dry-run)   cmd_dryrun ;;
  preflight) cmd_preflight ;;
  status) if [ -n "$WAVE" ]; then cmd_status; else cmd_summary; fi ;;
  *) echo "usage: migrate.sh plan <report.csv> | preflight --wave N [--free-ips N] | dry-run --wave N | status [--wave N]   (all: --run <dir>)"; exit 1 ;;
esac
