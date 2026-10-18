#!/usr/bin/env bash
# populate.sh -- generate and push a SCALE population for the migration rehearsal (lab / SBX).
#   bash scripts/populate.sh --services N --apps M --run runs/<env> --space <name> [--prefix scl] [--offering redis]
#                            [--plan cache-small] [--parallel 8] [--memory 64M]
#   bash scripts/populate.sh --run runs/<env> --space <name> [--prefix scl] --teardown
# Layout (deterministic, written to runs/<env>/layout-<prefix>.tsv, same columns as scripts/layout.tsv):
#   app i = <prefix>-app-NNN bound round-robin to service <prefix>-redis-NN; every 10th app is ALSO
#   bound to a second service (multi-bound -> one restart per wave); every app of the LAST service is
#   STOPPED, so that service is a truly silent one (rebind only, no restart) -- needs N >= 2.
#   Apps are apps/sim-go (SIM_MODE=cache, /check contract), SIM_SERVICE_NAME = the first bound service.
# Steps: services (--parallel at a time; an existing service counts as ready only when its last operation
#   is 'create succeeded' -- 'in progress' is waited on, 'failed' stops the run: delete it by hand) ->
#   manifests in chunks of --parallel apps, pushed concurrently, each push with its OWN copy of CF_HOME
#   (concurrent token refreshes on one config.json race, DESIGN.md) -> stop the silent service's apps.
#   Idempotent: ready services and existing apps are skipped; a half-pushed chunk is completed on re-run.
# --teardown deletes every <prefix>-app-NNN app and every <prefix>-redis-NN[-redis-standby] service
#   (Redis AND the Valkey that took the name), waits, reports what is left.
# Scope: strict name patterns, never 'sim-' (reset-population.sh's scope). --space is REQUIRED and
#   compared with `cf target`: this is a lab-setup script that uses the current target (unlike the
#   migration tool, which is GUID-only), so the target is verified instead of assumed.
# Every cf listing is checked: a failing `cf apps`/`cf services` (expired token, API error) stops the run
#   -- it is never read as "nothing there". Prints counts only. The migration plan is still built from the
#   discovery scan (--services "^<prefix>-redis-"). Needs a SpaceDeveloper login.
set -uo pipefail
N=""; M=""; RUN=""; SPACE=""; PREFIX=scl; OFFERING=redis; PLAN=cache-small; PAR=8; MEM=64M; TEARDOWN=0
while [ "${1:-}" ]; do case "$1" in
  --services) N="$2"; shift 2;; --apps) M="$2"; shift 2;; --run) RUN="$2"; shift 2;; --space) SPACE="$2"; shift 2;; --prefix) PREFIX="$2"; shift 2;;
  --offering) OFFERING="$2"; shift 2;; --plan) PLAN="$2"; shift 2;; --parallel) PAR="$2"; shift 2;; --memory) MEM="$2"; shift 2;;
  --teardown) TEARDOWN=1; shift;; *) echo "unknown arg $1"; exit 2;; esac; done
usage(){ echo "usage: populate.sh --services N --apps M --run runs/<env> --space <name> [--prefix scl] [--offering redis] [--plan cache-small] [--parallel 8] [--memory 64M] | --run runs/<env> --space <name> [--prefix scl] --teardown"; exit 2; }
[ -n "$RUN" ] && [ -n "$SPACE" ] || usage
case "$RUN" in *[[:space:]]*) echo "!! --run path must not contain whitespace"; exit 2;; esac
case "$PREFIX" in sim|sim-*) echo "!! prefix '$PREFIX' is the hand-laid SBX population's scope (reset-population.sh) -- use another"; exit 2;; esac
printf '%s' "$PREFIX" | grep -qE '^[a-z][a-z0-9]{1,11}$' || { echo "!! prefix: lowercase letters/digits, 2-12 chars"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"; APPDIR="$HERE/../apps/sim-go"
mkdir -p "$RUN/populate" || exit 2; LAYOUT="$RUN/layout-$PREFIX.tsv"; LOGD="$RUN/populate"
die(){ echo "!! $*" >&2; exit 1; }
T0=$(date +%s); elapsed(){ echo "$(( $(date +%s) - T0 ))s"; }
APP_RE="^$PREFIX-app-[0-9]{3}\$"; SVC_RE="^$PREFIX-redis-[0-9]{2}(-redis-standby)?\$"

# ---- target: verified, not assumed
cf target > "$LOGD/target.txt" 2>&1 || die "cf target failed -- not logged in? ($(tail -1 "$LOGD/target.txt"))"
tspace=$(sed -n 's/^space: *//p' "$LOGD/target.txt" | tr -d '[:space:]')
[ "$tspace" = "$SPACE" ] || die "cf target is space '${tspace:-<none>}', expected '$SPACE' (cf target -s $SPACE)"
# ---- listings into files, exit status checked (a failing listing is an error, never "nothing there")
list_apps(){ cf apps > "$LOGD/cf-apps.txt" 2>&1 || die "cf apps failed: $(tail -1 "$LOGD/cf-apps.txt")"
  awk -v re="$APP_RE" 'NR>3 && $1 ~ re {print $1}' "$LOGD/cf-apps.txt" > "$1"; }
list_svcs(){ cf services > "$LOGD/cf-services.txt" 2>&1 || die "cf services failed: $(tail -1 "$LOGD/cf-services.txt")"
  awk -v re="$SVC_RE" 'NR>3 && $1 ~ re {print $1 "\t" $2}' "$LOGD/cf-services.txt" > "$1"; }   # name, offering (the only columns decided on)
# ---- last operation of one service: "succeeded" | "in progress" | "failed" | "" (not found) ; message on failure
svc_status(){ cf service "$1" > "$LOGD/svc-$1.txt" 2>&1 || { echo ""; return; }
  sed -n 's/^ *status: *//p' "$LOGD/svc-$1.txt" | head -1 | sed 's/^[a-z]* //'; }      # "create succeeded" -> "succeeded"
svc_message(){ sed -n 's/^ *message: *//p' "$LOGD/svc-$1.txt" | head -1; }

if [ "$TEARDOWN" = 1 ]; then
  echo "== teardown of $PREFIX-app-NNN / $PREFIX-redis-NN in space $SPACE ($(sed -n 's/^org: *//p' "$LOGD/target.txt" | tr -d '[:space:]'))"
  list_apps "$LOGD/td-apps.txt"; n=0; f=0
  for a in $(cat "$LOGD/td-apps.txt"); do if cf delete "$a" -f -r > /dev/null 2>&1; then n=$((n+1)); else f=$((f+1)); echo "   !! delete app $a failed"; fi; done
  echo "   apps deleted: $n, failed: $f (bindings go with the apps)"
  list_svcs "$LOGD/td-svcs.txt"; n=0; f=0
  while IFS=$'\t' read -r s off; do [ -n "$s" ] || continue
    if cf delete-service "$s" -f > /dev/null 2>&1; then n=$((n+1)); else f=$((f+1)); echo "   !! delete-service $s ($off) failed"; fi; done < "$LOGD/td-svcs.txt"
  echo "   services deletion requested: $n, failed: $f -- waiting"
  for i in $(seq 1 120); do list_svcs "$LOGD/td-svcs.txt"; left=$(wc -l < "$LOGD/td-svcs.txt" | tr -d ' '); [ "$left" = 0 ] && break; sleep 10; done
  [ "$left" = 0 ] || { echo "   !! $left service(s) still present after 20 min:"; while IFS=$'\t' read -r s off; do echo "      $s ($off): $(svc_status "$s") $(svc_message "$s")"; done < "$LOGD/td-svcs.txt"; exit 1; }
  echo "== teardown done in $(elapsed)"; exit 0
fi

[ -n "$N" ] && [ -n "$M" ] || die "--services N and --apps M are required"
case "$N$M$PAR" in *[!0-9]*) die "--services/--apps/--parallel must be integers";; esac
[ "$N" -ge 2 ] && [ "$M" -ge "$N" ] && [ "$PAR" -ge 1 ] || die "need --services >= 2, --apps >= --services, --parallel >= 1"
[ "$N" -le 99 ] && [ "$M" -le 999 ] || die "limits: 99 services, 999 apps (name width)"
[ -f "$APPDIR/bin/sim-linux" ] || die "$APPDIR/bin/sim-linux missing (build the sim app first)"

# ---- 1. layout
awk -v n="$N" -v m="$M" -v p="$PREFIX" 'BEGIN { OFS="\t"; print "app","services","state","note"
  for (i=1; i<=m; i++) { j=((i-1)%n)+1; s=sprintf("%s-redis-%02d", p, j); note="round-robin"; st="started"
    if (i%10==0) { k=((j + int(i/10) - 1) % n) + 1; if (k==j) k=(k%n)+1; s=s "," sprintf("%s-redis-%02d", p, k); note="multi-bound (2 services -> 1 restart per wave)" }
    if (j==n) { st="stopped"; note=note "; stopped: every app of the last service -> silent service, rebind only" }
    print sprintf("%s-app-%03d", p, i), s, st, note } }' > "$LAYOUT" || die "layout write failed"
echo "== layout: $N services, $M apps -> $LAYOUT ($(awk -F'\t' 'NR>1 && $2 ~ /,/' "$LAYOUT" | wc -l | tr -d ' ') multi-bound, $(awk -F'\t' 'NR>1 && $3=="stopped"' "$LAYOUT" | wc -l | tr -d ' ') stopped = all apps of $PREFIX-redis-$(printf '%02d' "$N"), the silent service)"

# ---- 2. services, --parallel at a time; existing ones by STATE, not by name
echo "== services ($OFFERING/$PLAN), $PAR at a time"
list_svcs "$LOGD/services-before.tsv"
ready=0; existed=0; failed=0; i=1
while [ "$i" -le "$N" ]; do
  batch=""; b=0
  while [ "$b" -lt "$PAR" ] && [ "$i" -le "$N" ]; do
    s=$(printf '%s-redis-%02d' "$PREFIX" "$i"); i=$((i+1))
    if grep -q "^$s	" "$LOGD/services-before.tsv"; then
      case "$(svc_status "$s")" in
        succeeded) existed=$((existed+1)); continue;;
        "in progress") echo "   $s: create in progress (earlier run) -- waiting"; batch="$batch $s"; b=$((b+1)); continue;;
        failed) failed=$((failed+1)); echo "   !! $s: create failed earlier ($(svc_message "$s")) -- delete it: cf delete-service $s -f"; continue;;
        *) die "cannot read the state of existing service $s: $(tail -1 "$LOGD/svc-$s.txt")";;
      esac
    fi
    if cf create-service "$OFFERING" "$PLAN" "$s" > "$LOGD/create-$s.log" 2>&1; then batch="$batch $s"; b=$((b+1)); else failed=$((failed+1)); echo "   !! create-service $s: $(tail -1 "$LOGD/create-$s.log")"; fi
  done
  for s in $batch; do
    for t in $(seq 1 90); do st=$(svc_status "$s")
      case "$st" in succeeded) ready=$((ready+1)); break;; failed) failed=$((failed+1)); echo "   !! $s: create failed ($(svc_message "$s"))"; break;; "in progress") ;; *) die "cannot read the state of $s: $(tail -1 "$LOGD/svc-$s.txt")";; esac
      sleep 10; [ "$t" = 90 ] && { failed=$((failed+1)); echo "   !! $s: still '$st' after 15 min"; }
    done
  done
  echo "   services: ready $ready, existed $existed, failed $failed ($(elapsed))"
done
[ "$failed" = 0 ] || die "$failed service(s) failed -- delete them (cf delete-service <name> -f), then re-run (ready ones are skipped)"

# ---- 3. apps: manifests in chunks, pushed concurrently, one CF_HOME copy per chunk
echo "== apps: $M in chunks of $PAR, $PAR pushes in parallel, $MEM each"
list_apps "$LOGD/apps-before.txt"
if ls "$LOGD"/chunk-*.log > /dev/null 2>&1; then mkdir -p "$LOGD/prev-$T0" && mv "$LOGD"/chunk-* "$LOGD/push-results.txt" "$LOGD/prev-$T0/" 2>/dev/null; fi
rm -f "$LOGD/chunks.txt"
awk -F'\t' -v before="$LOGD/apps-before.txt" -v par="$PAR" -v out="$LOGD" -v mem="$MEM" -v appdir="$APPDIR" '
  BEGIN { while ((getline l < before) > 0) have[l]=1 }
  NR>1 && !($1 in have) {
    c=int(n/par); f=sprintf("%s/chunk-%03d.yml", out, c)
    if (n%par==0) { if (n>0) close(prev); printf "---\napplications:\n" > f; print f >> (out "/chunks.txt"); prev=f }
    split($2, sv, ","); svl=""; for (k=1; k in sv; k++) svl=svl (k>1?", ":"") sv[k]
    printf "- name: %s\n  path: %s\n  buildpacks: [binary_buildpack_system]\n  memory: %s\n  disk_quota: 256M\n  instances: 1\n  health-check-type: http\n  health-check-http-endpoint: /healthz\n  command: chmod +x bin/sim-linux && ./bin/sim-linux\n  services: [%s]\n  env: { SIM_MODE: cache, SIM_EXPECTS: cf-bind, SIM_KEYS: \"50\", SIM_SERVICE_NAME: %s }\n", $1, appdir, mem, svl, sv[1] >> f
    n++ }
  END { print n+0 > (out "/apps-todo.txt") }' "$LAYOUT" || die "manifest generation failed"
todo=$(cat "$LOGD/apps-todo.txt"); echo "   to push: $todo (already present: $(wc -l < "$LOGD/apps-before.txt" | tr -d ' '))"
if [ "$todo" -gt 0 ]; then
  # one `cf push -f chunk` per line, -P parallel, each in its own CF_HOME copy; -n1 + "$1" (BSD xargs -I is limited to 255 bytes)
  CFH="${CF_HOME:-$HOME/.cf}"; [ -d "$CFH" ] || die "CF_HOME $CFH not found"
  export CFH
  xargs -P "$PAR" -n1 sh -c 'd="$1.cfhome"; rm -rf "$d"; cp -R "$CFH" "$d" && CF_HOME="$d" cf push -f "$1" > "$1.log" 2>&1; echo "$? $1"; rm -rf "$d"' _ < "$LOGD/chunks.txt" > "$LOGD/push-results.txt"
  bad=$(awk '$1!=0' "$LOGD/push-results.txt" | wc -l | tr -d ' ')
  echo "   push chunks: $(wc -l < "$LOGD/chunks.txt" | tr -d ' '), failed chunks: $bad ($(elapsed))"
fi
# verify by listing, not by push exit codes alone (a chunk fails on its first bad app; the others in it never pushed)
list_apps "$LOGD/apps-after.txt"
missing=$(awk -F'\t' -v after="$LOGD/apps-after.txt" 'BEGIN { while ((getline l < after) > 0) have[l]=1 } NR>1 && !($1 in have) {print $1}' "$LAYOUT")
if [ -n "$missing" ]; then echo "   !! apps missing after push: $(printf '%s\n' "$missing" | wc -l | tr -d ' ') -- see $LOGD/chunk-*.log; re-run to push only the missing ones"; printf '%s\n' "$missing" | head -5 | sed 's/^/      /'; fi

# ---- 4. the silent service's apps
echo "== stopping the silent service's apps"
ns=0; for a in $(awk -F'\t' 'NR>1 && $3=="stopped" {print $1}' "$LAYOUT"); do grep -qx "$a" "$LOGD/apps-after.txt" || continue; if cf stop "$a" > /dev/null 2>&1; then ns=$((ns+1)); else echo "   !! stop $a failed"; fi; done
echo "   stopped: $ns"

list_svcs "$LOGD/services-after.tsv"
echo "== done in $(elapsed): services $(awk -F'\t' '$2!="valkey"' "$LOGD/services-after.tsv" | wc -l | tr -d ' ') Redis, apps $(wc -l < "$LOGD/apps-after.txt" | tr -d ' ') of $M"
[ -z "$missing" ] || exit 1
echo "next: discovery scan + plan with --services '^$PREFIX-redis-' ; then migrate/free-ips.sh and preflight"
