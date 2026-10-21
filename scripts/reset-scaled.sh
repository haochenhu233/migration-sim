#!/usr/bin/env bash
# reset-scaled.sh -- put the scaled simulation back to its initial state: only the Redis, under their original
# names, every app bound to its Redis, no Valkey -- then archive the run so the rehearsal starts over.
#
#   bash scripts/reset-scaled.sh --run runs/sbx            # dry run: says what it would do, changes nothing
#   bash scripts/reset-scaled.sh --run runs/sbx --go       # does it
#
# Phases (each stops the script on its first error; re-running continues where it stopped):
#   1. rollback -- `migrate.sh rollback` for every service of the plan: names back (redis -> <name>, valkey ->
#      <name>-valkey-staged), Vault name-sync, rebind redis, unbind valkey, restart. Recorded in the ledger; a
#      service already rolled back (or never touched) is a no-op.
#   2. verify  -- from CF, by guid: every Redis of the plan is named <name>; every app of the plan has a binding
#      to its Redis; no app has a binding to a Valkey. Anything else = stop, nothing is deleted.
#   3. delete  -- the Valkeys the tool created (guids from the ledger's create-valkey notes) that still exist:
#      each must be named <name>-valkey-staged (staged name = rolled back) and have no binding or key; then
#      DELETE without purge (the broker deletes the BOSH deployment and its Vault entry); waits until gone.
#      A Valkey under any other name, or with a binding, is refused -- never deleted.
#   4. archive -- moves ledger, inventory, provision-check.tsv, waves.tsv, plan-summary.md, status/ into
#      <run>/pass-<date>/; vault.conf and bosh.conf stay. The next rehearsal starts at scan -> plan.
# Nothing here deletes an app or a Redis. Needs: cf logged in (admin), jq, and the run dir with waves.tsv +
# ledger.jsonl. Every cf curl answer is shape-checked; an error document is never read as "nothing there".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate/migrate.sh"; CF="${CF_CMD:-cf}"
RUN=""; GO=""; POLL="${RESET_POLL:-10}"; WAITMAX="${RESET_WAIT:-900}"
while [ $# -gt 0 ]; do case "$1" in --run) RUN="${2%/}"; shift 2;; --go) GO=1; shift;; *) echo "usage: reset-scaled.sh --run <dir> [--go]"; exit 2;; esac; done
[ -n "$RUN" ] && [ -s "$RUN/waves.tsv" ] || { echo "!! --run <dir> with waves.tsv required"; exit 2; }
[ -s "$RUN/ledger.jsonl" ] || { echo "!! $RUN/ledger.jsonl missing -- nothing was migrated from this run dir? (archive by hand if the plan is all there is)"; exit 2; }
PLAN="$RUN/waves.tsv"; LEDGER="$RUN/ledger.jsonl"
say(){ printf '%s\n' "$*"; }
cfget(){ local j; j=$($CF curl "$1" 2>/dev/null); printf '%s' "$j" | jq -e 'type=="object" and (has("errors")|not)' >/dev/null 2>&1 || { CF_ERR="$(printf '%s' "$j" | jq -r '.errors[0].detail // .errors[0].title // "no/invalid JSON"' 2>/dev/null)"; return 1; }; printf '%s' "$j"; }
cfcode(){ local j; j=$($CF curl "$1" 2>/dev/null)   # "ok" | "notfound" (CF-ResourceNotFound / 10010) | the error title | "" on junk
  printf '%s' "$j" | jq -r 'if type!="object" then "" elif has("errors") then (if (.errors[0].title=="CF-ResourceNotFound" or .errors[0].code==10010) then "notfound" else (.errors[0].title // "error") end) else "ok" end' 2>/dev/null; }
nbind(){ local j; j=$(cfget "/v3/service_credential_bindings?service_instance_guids=$1&per_page=200") || { echo ERR; return; }; printf '%s' "$j" | jq -r '.resources|length'; }
bound(){ local j; j=$(cfget "/v3/service_credential_bindings?type=app&app_guids=$1&service_instance_guids=$2") || { echo ERR; return; }; printf '%s' "$j" | jq -r '.resources|length'; }
mode="DRY RUN (nothing changes; add --go)"; [ -n "$GO" ] && mode="LIVE"
say "reset-scaled: $mode -- run $RUN"
say "== 1. rollback every service of the plan (via migrate.sh rollback; no-op for services already back on redis)"
fail=0
while read -r w name; do
  if [ -n "$GO" ]; then
    out=$(bash "$M" rollback --wave "$w" --service "$name" --yes --reason "reset for the next rehearsal" --run "$RUN" 2>&1); rc=$?
    if [ $rc = 0 ]; then say "   wave $w $name: rolled back"
    elif printf '%s' "$out" | grep -q 'nothing to roll back'; then say "   wave $w $name: untouched, nothing to roll back"
    else say "!! wave $w $name: rollback failed (rc $rc) -- fix it, then run this script again"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; fail=1; break; fi
  else say "   would: migrate.sh rollback --wave $w --service $name"; fi
done < <(awk -F'\t' 'NR>1 && !s[$3]++ {print $1, $3}' "$PLAN")
[ $fail = 0 ] || exit 1
if [ -z "$GO" ]; then   # phases 2-4 only make sense after the rollbacks; show what phase 3 would look at, as it is now
  say "== 2-4 (dry run): verify, delete, archive run only with --go, after the rollbacks. Valkeys the ledger knows, as CF has them now:"
  for vk in $(jq -r 'select(.step=="create-valkey" and .outcome=="ok") | .note' "$LEDGER" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u); do
    code=$(cfcode "/v3/service_instances/$vk"); case "$code" in notfound) say "   $vk: already gone"; continue;; ok) ;; *) say "   $vk: cannot read it (${code:-no JSON})"; continue;; esac
    j=$(cfget "/v3/service_instances/$vk") || { say "   $vk: $CF_ERR"; continue; }
    say "   $(printf '%s' "$j" | jq -r '"\(.name) (\(.last_operation.type) \(.last_operation.state))"') $vk: $(nbind "$vk") binding(s) -- deleted only once named *-valkey-staged and unbound"
  done
  say "dry run ends here -- run with --go"; exit 0
fi
say "== 2. verify from CF: redis under its name, every app bound to its redis, none to a valkey"
bad=0; napp=0
while IFS=$'\t' read -r w name sg ag an; do
  j=$(cfget "/v3/service_instances/$sg") || { say "!! $name: cannot read redis $sg: $CF_ERR"; bad=$((bad+1)); continue; }
  cur=$(printf '%s' "$j" | jq -r .name); [ "$cur" = "$name" ] || { say "!! $name: redis $sg is named '$cur' (rollback did not finish? run again)"; bad=$((bad+1)); }
  b=$(bound "$ag" "$sg"); napp=$((napp+1))
  case "$b" in 1) ;; 0) say "!! $name: app $an ($ag) has NO binding to its redis"; bad=$((bad+1));; ERR) say "!! $name: cannot list bindings of app $an: $CF_ERR"; bad=$((bad+1));; *) say "!! $name: app $an has $b bindings to its redis"; bad=$((bad+1));; esac
done < <(awk -F'\t' 'NR>1 {print $1 "\t" $3 "\t" $4 "\t" $9 "\t" $8}' "$PLAN")
say "   $napp app-service pairs checked, $bad problem(s)"
[ $bad = 0 ] || { say "!! not in the expected state -- nothing deleted. Fix the lines above (usually: rollback that service again), then re-run"; exit 1; }
say "== 3. delete the valkeys the tool created (ledger create-valkey notes), only under the staged name and unbound"
vks=$(jq -r 'select(.step=="create-valkey" and .outcome=="ok") | .note' "$LEDGER" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u)
todo=""; refuse=0; gone=0
for vk in $vks; do
  code=$(cfcode "/v3/service_instances/$vk")
  case "$code" in notfound) gone=$((gone+1)); continue;; ok) ;; *) say "!! $vk: cannot read it (${code:-no JSON}) -- stop"; exit 1;; esac
  j=$(cfget "/v3/service_instances/$vk") || { say "!! $vk: $CF_ERR"; exit 1; }
  vn=$(printf '%s' "$j" | jq -r .name); st=$(printf '%s' "$j" | jq -r '.last_operation | "\(.type) \(.state)"')
  case "$vn" in *-valkey-staged) ;; *) say "!! $vk is named '$vn', not a staged name -- is it still cut over? refused (rollback that service, then re-run)"; refuse=$((refuse+1)); continue;; esac
  nb=$(nbind "$vk"); [ "$nb" = 0 ] || { say "!! $vn ($vk) still has ${nb} binding(s)/key(s) -- refused"; refuse=$((refuse+1)); continue; }
  say "   $vn ($vk): $st, no bindings -> delete"; todo="$todo $vk"
done
say "   $(echo $todo | wc -w | tr -d ' ') to delete, $gone already gone, $refuse refused"
[ $refuse = 0 ] || { say "!! refused some -- nothing deleted; fix and re-run"; exit 1; }
if [ -n "$GO" ] && [ -n "$todo" ]; then
  for vk in $todo; do
    r=$($CF curl -X DELETE "/v3/service_instances/$vk" -i 2>/dev/null | head -1)
    case "$r" in *" 202"*|*" 204"*) ;; *) say "!! DELETE $vk: ${r:-no answer} -- stop"; exit 1;; esac
  done
  say "   deletes issued; waiting until CF no longer has them (broker deletes the deployments) ..."
  t=0; left="$todo"
  while [ -n "$left" ] && [ $t -lt $WAITMAX ]; do
    sleep "$POLL"; t=$((t+POLL)); still=""
    for vk in $left; do code=$(cfcode "/v3/service_instances/$vk"); case "$code" in notfound) ;; ok) still="$still $vk";; *) say "!! $vk: cannot read it (${code:-no JSON}) -- stop"; exit 1;; esac; done
    left="$still"
  done
  [ -z "$left" ] || { say "!! still present after ${t}s:$left -- check 'cf service' / the broker, then re-run (this phase is re-runnable)"; exit 1; }
  say "   all gone (${t}s)"
fi
say "== 4. archive the run (ledger, inventory, provision-check, plan, status/) -> $RUN/pass-<date>/; vault.conf + bosh.conf stay"
if [ -n "$GO" ]; then
  d="$RUN/pass-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$d"
  for f in ledger.jsonl inventory.tsv provision-check.tsv waves.tsv plan-summary.md status commands.log; do [ -e "$RUN/$f" ] && mv "$RUN/$f" "$d/"; done
  say "   archived to $d: $(ls "$d" | tr '\n' ' ')"
  say "done: only redis, apps on redis, no valkey. Next: scan -> merge -> migrate.sh plan ... --run $RUN"
else say "   would move them; dry run ends here -- run with --go"; fi
