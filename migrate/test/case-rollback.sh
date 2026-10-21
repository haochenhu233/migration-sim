#!/usr/bin/env bash
# case-rollback.sh -- a rollback restores the NAMES, not only the bindings (SBX wave 6, 2026-10-20): apps resolve
# their service by name in VCAP_SERVICES, and a multi-bound app is restarted by its other service's step.
# Fixture test/fixtures/waves-chain.tsv: one wave, services svc-7 svc-8 svc-9 chained by a-28 (8+7) and a-49 (9+8).
# svc-9's Valkey is HOLLOW (CF has it, the broker lost it). Usage: bash migrate/test/case-rollback.sh [workdir]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
export CF_CMD="$HERE/cf-fake" BOSH_CMD="$HERE/bosh-fake" JOB_POLL=0 SOAK=0 MIGRATE_OP=test RESTART_TIMEOUT=2
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
newrun(){ R="$W/$1"; rm -rf "$R"; mkdir -p "$R"; cp "$HERE/fixtures/waves-chain.tsv" "$R/waves.tsv"
  export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; "$CF_CMD" seed "$R/waves.tsv" > /dev/null
  printf 'SAFE_RUN="%s"\n' "$HERE/safe-fake" > "$R/vault.conf"; }
pc(){ bash "$M" provision-check --wave 1 --run "$R" > "$R/pc-gate.log" 2>&1; }   # the hollow gate: apply needs a provision-check line per service
ledger(){ jq -r "$1" "$R/ledger.jsonl" 2>/dev/null; }
nev(){ ledger "select(.step==\"$1\" and .outcome==\"$2\"${3:+ and $3}) | .service" | wc -l | tr -d ' '; }
siname(){ jq -r --arg g "$1" '.si[$g].name // "GONE"' "$CFFAKE_STATE"; }
vkof(){ ledger "select(.service==\"$1\" and .step==\"create-valkey\" and .outcome==\"ok\") | .note" | grep -oE '[0-9a-f-]{36}' | tail -1; }
restarts(){ jq -r --arg g "$1" '.restarts[$g] // 0' "$CFFAKE_STATE"; }
G7=d3acf6c9-f3e7-55b7-a03d-85a31138daed; G8=81b5df7b-0956-52fd-abae-489a4a3cf5fb; G9=2bd2f594-d863-5f1b-8fd6-7ef66f006e5f
A9=59e78dba-0ead-51a3-89ad-025963e2b75e; A49=b9394f71-478b-5bf8-a7ca-38836735a72c; A8=b3755176-489d-5a39-8894-a31bf2478b17
A28=92bf25f7-ae91-5364-aa6b-4107f958fa90; A7=7d747e4d-a281-591b-80e4-aec211d5196f; A57=171732b1-7fdc-57fd-a61e-c2d9a8cedd67
NAMED="$A9:svc-9,$A49:svc-9,$A8:svc-8,$A28:svc-8,$A7:svc-7,$A57:svc-7"   # each app looks its FIRST service up by name

echo "== R: hollow valkey in a chained wave -- the rollback restores names, the neighbours still migrate"
newrun R
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; check "R0 provision: 3 staged" "[ $? = 0 ] && [ $(nev create-valkey ok) = 3 ]"
V9=$(vkof $G9); V8=$(vkof $G8); V7=$(vkof $G7); pc   # checked while all three are sound; svc-9 goes hollow AFTER the check (lost between the check and the window)
CFFAKE_HOLLOW=svc-9 CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply1.log" 2>&1; rc=$?
check "R1 apply exits 0 (one service rolled back, wave went on)" "[ $rc = 0 ]"
check "R2 svc-9: rename-valkey undone + rename-standby undone, in that order" "[ \"$(ledger "select(.service==\"$G9\" and .outcome==\"undone\") | .step" | paste -sd, -)\" = rename-valkey,rename-standby ]"
check "R3 CF names back: redis svc-9, hollow valkey svc-9-valkey-staged" "[ \"$(siname $G9)\" = svc-9 ] && [ \"$(siname $V9)\" = svc-9-valkey-staged ]"
check "R4 Blacksmith's copies synced back (read back)" "[ \"$(cat "$SAFEFAKE_STATE/$G9")\" = svc-9 ] && [ \"$(cat "$SAFEFAKE_STATE/$V9")\" = svc-9-valkey-staged ]"
check "R5 a-9: bind failed 'deployment not found', rollback:fail names the purge command" "[ $(nev bind-valkey fail ".app==\"$A9\" and (.note|test(\"deployment not found\"))") = 1 ] && [ $(nev rollback fail ".app==\"$A9\" and (.note|test(\"purge=true\"))") = 1 ]"
check "R6 a-49 (9+8) and a-28 (8+7) verified on their other service; svc-7 and svc-8 fully verified" "[ $(nev verify ok ".service==\"$G8\"") = 3 ] && [ $(nev verify ok ".service==\"$G7\"") = 3 ] && [ $(nev verify ok ".service==\"$G9\"") = 0 ]"
check "R7 svc-7, svc-8 valkeys carry the names; their redis are standby" "[ \"$(siname $V7)\" = svc-7 ] && [ \"$(siname $G7)\" = svc-7-redis-standby ] && [ \"$(siname $V8)\" = svc-8 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status1.log" 2>&1
check "R8 status: 2 VERIFIED, svc-9 ATTENTION, purge advice shown" "[ $(grep -c ' VERIFIED ' "$R/status1.log") = 2 ] && grep -q 'svc-9 .* ATTENTION' '$R/status1.log' && grep -q 'purge=true' '$R/status1.log'"
bash "$M" status --run "$R" > "$R/overview.log" 2>&1
check "R9 overview: 3 services created (the undone one still has its staged valkey)" "grep -qE '^1 +3 +3 +0 ' '$R/overview.log'"
check "R10 inventory: svc-9 staged under its own names, svc-8 cut-over" "[ \"$(awk -F'\t' -v s=$G9 'NR>1 && $7==s && !d++ {print $6, $8, $11}' "$R/inventory.tsv")\" = 'svc-9 svc-9-valkey-staged staged' ] && [ \"$(awk -F'\t' -v s=$G8 'NR>1 && $7==s && !d++ {print $6, $8, $11}' "$R/inventory.tsv")\" = 'svc-8-redis-standby svc-8 cut-over' ]"
bash "$M" preflight --wave 1 --run "$R" > "$R/pf.log" 2>&1
check "R11 preflight after the undo: svc-9 name matches its guid again (no drift)" "grep -q 'service svc-9: name matches guid' '$R/pf.log' && ! grep -q 'svc-9: ledger says renamed' '$R/pf.log'"
CFFAKE_HOLLOW=svc-9 CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply1b.log" 2>&1
check "R12 apply again with the hollow still there: the failed binding is not adopted; its delete fails through the broker (deployment not found) -> bind fail, names undone again" "[ $(nev bind-valkey ok ".app==\"$A9\" and (.note|test(\"already present\"))") = 0 ] && [ $(nev bind-valkey fail ".app==\"$A9\" and (.note|test(\"could not be deleted.*deployment not found\"))") = 1 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 2 ]"

CFFAKE_HOLLOW=svc-9 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc.log" 2>&1; rc=$?
check "R13 provision-check sees it: CF succeeded, no BOSH deployment -> HOLLOW with the purge command, FAIL; svc-7/8 OK with their deployments" "[ $rc = 1 ] && grep -q '^HOLLOW   wave 1 *svc-9 .*purge=true' '$R/pc.log' && grep -q 'FAIL (2 of 3 ok, 0 missing, 0 mismatched, 1 hollow, 0 api-errors; bosh: 2 of 3 valkeys have a deployment)' '$R/pc.log'"

echo "== P: purge the hollow valkey, provision again, apply again -> svc-9 migrates"
"$CF_CMD" curl -X DELETE "/v3/service_instances/$V9?purge=true" > /dev/null
check "P1 purge: instance and its failed binding gone from CF" "[ \"$(siname $V9)\" = GONE ] && [ $(jq --arg a $A9 '[.bind[]|select(.app==$a)]|length' "$CFFAKE_STATE") = 1 ]"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov2.log" 2>&1
check "P2 provision: svc-9 'gone from CF -- creating again', a new staged valkey; svc-7/8 untouched" "[ $(nev create-valkey fail ".service==\"$G9\" and (.note|test(\"gone from CF\"))") = 1 ] && [ $(nev create-valkey ok ".service==\"$G9\"") = 2 ] && [ $(nev create-valkey ok) = 4 ]"
V9b=$(vkof $G9); check "P3 new staged valkey named svc-9-valkey-staged" "[ \"$(siname $V9b)\" = svc-9-valkey-staged ] && [ \"$V9b\" != \"$V9\" ]"
bash "$M" provision-check --wave 1 --run "$R" > "$R/pc2.log" 2>&1; rc=$?
check "P3b provision-check after the purge + re-create: OK 3 of 3, bosh 3 present" "[ $rc = 0 ] && grep -q 'OK (3 of 3 ok: 1 staged, 2 cut-over; 0 missing, 0 mismatched, 0 hollow, 0 api-errors; bosh: 3 of 3 valkeys have a deployment)' '$R/pc2.log'"
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply2.log" 2>&1; rc=$?
check "P4 apply: svc-9 renamed again (3rd rename-standby ok), a-9 and a-49 verified on it; exit 0" "[ $rc = 0 ] && [ $(nev rename-standby ok ".service==\"$G9\"") = 3 ] && [ $(nev verify ok ".service==\"$G9\"") = 2 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status2.log" 2>&1; check "P5 status: 3 VERIFIED" "[ $(grep -c ' VERIFIED ' "$R/status2.log") = 3 ]"

echo "== C: the SBX repair -- old-tool rollback left names swapped and a-57 crash-looping; 'rollback' fixes it"
# svc-7 as the old tool left it: bindings back on redis, names swapped, a-57 restarted and crashing (rollback:fail)
python3 - "$CFFAKE_STATE" $A57 $G7 $V7 <<'EOF'
import json,sys; p,a,g,v=sys.argv[1:]; st=json.load(open(p))
for k in [k for k,b in st['bind'].items() if b['app']==a]: del st['bind'][k]
st['bind']['b-a57-redis']={'app':a,'si':g}; st['restarts'][a]=st['restarts'].get(a,0)+1; st.setdefault('env',{})[a]=['svc-7-redis-standby']; json.dump(st,open(p,'w'))
EOF
jq -nc --arg s $G7 --arg a $A57 '{ts:"2026-10-20T16:25:48Z",wave:1,service:$s,app:$a,step:"rollback",outcome:"fail",ms:0,op:"old",note:"cause: restart failed; FAILED: instances 0/1 after 300s"}' >> "$R/ledger.jsonl"
check "C0 setup: a-57 on redis, names still swapped, stats CRASHED" "[ \"$(siname $G7)\" = svc-7-redis-standby ] && [ \"$(CFFAKE_NAMED=$NAMED $CF_CMD curl /v3/apps/$A57/processes/web/stats | jq -r '.resources[0].state')\" = CRASHED ]"
r0=$(restarts $A57)
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "sbx repair" --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "C1 rollback exits 0, names restored (redis svc-7, valkey staged), copies synced" "[ $rc = 0 ] && [ \"$(siname $G7)\" = svc-7 ] && [ \"$(siname $V7)\" = svc-7-valkey-staged ] && [ \"$(cat "$SAFEFAKE_STATE/$G7")\" = svc-7 ]"
check "C2 a-57 restarted once more (names back -> RUNNING), rollback ok with 'restart'" "[ $(restarts $A57) = $((r0+1)) ] && [ $(nev rollback ok ".app==\"$A57\" and (.note|test(\"restart\"))") = 1 ] && [ \"$(CFFAKE_NAMED=$NAMED $CF_CMD curl /v3/apps/$A57/processes/web/stats | jq -r '.resources[0].state')\" = RUNNING ]"
check "C3 a-7 and a-28 back on redis, restarted; a-28 still fine on svc-8's valkey" "[ $(nev rollback ok ".service==\"$G7\"") = 3 ] && [ $(jq --arg a $A28 --arg v $V8 '[.bind[]|select(.app==$a and .si==$v)]|length' "$CFFAKE_STATE") = 1 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status3.log" 2>&1; check "C4 status: svc-7 ROLLED-BACK, no name-sync pending" "grep -q 'svc-7 .* ROLLED-BACK' '$R/status3.log' && ! grep -q 'name-sync pending' '$R/status3.log'"
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --service svc-7 --yes --run "$R" > "$R/apply3.log" 2>&1; rc=$?
check "C5 re-migrate svc-7 after the rollback: renamed again, 3 apps verified" "[ $rc = 0 ] && [ \"$(siname $V7)\" = svc-7 ] && [ $(nev verify ok ".service==\"$G7\"") = 6 ]"

echo "== O: --app override rolls back one app and leaves the names alone (a-8 resolves by tag, not by name: with the
#       names kept for the other apps, a by-name app would not find <name>-redis-standby -- that is the override's price)"
CFFAKE_NAMED="${NAMED/$A8:svc-8,/}" bash "$M" rollback --wave 1 --service svc-8 --app a-8 --yes --reason "one app" --run "$R" > "$R/rb2.log" 2>&1; rc=$?
check "O1 names unchanged (valkey still svc-8), only a-8 rolled back, no undone line for svc-8" "[ $rc = 0 ] && [ \"$(siname $V8)\" = svc-8 ] && [ $(nev rollback ok ".service==\"$G8\"") = 1 ] && [ $(nev rename-valkey undone ".service==\"$G8\"") = 0 ] && grep -q 'names stay' '$R/rb2.log'"

echo "== F: apply gives a service up after the standby rename (valkey renamed by hand) -> redis gets its name back"
newrun F; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V9=$(vkof $G9)
python3 - "$CFFAKE_STATE" $V9 <<'EOF2'
import json,sys; p,v=sys.argv[1:]; st=json.load(open(p)); st['si'][v]['name']='svc-9-renamed-by-hand'; json.dump(st,open(p,'w'))
EOF2
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --force --run "$R" > "$R/apply.log" 2>&1; rc=$?   # --force: preflight would catch the hand rename
check "F1 svc-9: drift recorded, valkey left as it is (rollback-names fail names it), redis back to svc-9 (rename-standby undone)" "[ $(nev drift fail ".service==\"$G9\" and (.note|test(\"renamed-by-hand\"))") = 1 ] && [ $(nev rollback-names fail ".service==\"$G9\" and (.note|test(\"renamed-by-hand\"))") = 1 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 1 ] && [ \"$(siname $G9)\" = svc-9 ]"
check "F2 svc-7 and svc-8 migrated regardless (a-49 restarted by svc-8 found svc-9 = the redis)" "[ $rc = 0 ] && [ $(nev verify ok ".service==\"$G8\"") = 3 ] && [ $(nev verify ok ".service==\"$G7\"") = 3 ]"

echo "== S: a rename-back that FAILS is recorded under its own step; the rename lines keep saying what CF has; the next rollback finishes it"
newrun S; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V9=$(vkof $G9); V8=$(vkof $G8)
CFFAKE_HOLLOW=svc-9 CFFAKE_NAMED="$NAMED" CFFAKE_RENAME_FAIL=$G9:svc-9 bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "S1 valkey undone, redis PATCH back failed: rollback-names fail, rename-standby still 'ok' for ledger_done, CF redis still standby" "[ $(nev rename-valkey undone ".service==\"$G9\"") = 1 ] && [ $(nev rollback-names fail ".service==\"$G9\" and (.note|test(\"rename back to svc-9 failed\"))") = 1 ] && [ $(nev rename-standby fail) = 0 ] && [ \"$(siname $G9)\" = svc-9-redis-standby ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1
check "S2 status: svc-9 NAMES-STUCK with !!" "grep -q 'svc-9 .* NAMES-STUCK .*!!' '$R/status.log'"
check "S3 a-49 (9+8) is BLOCKED for svc-8 (svc-9 name-stuck): not bound, not restarted, 'bind-valkey blocked' names the stuck service; svc-8 itself migrated (a-8, a-28 verified), NOT rolled back" "[ $(nev bind-valkey blocked ".service==\"$G8\" and .app==\"$A49\" and (.note|test(\"svc-9 is name-stuck\"))") = 1 ] && [ $(restarts $A49) = 0 ] && [ $(nev verify ok ".service==\"$G8\"") = 2 ] && [ $(nev rollback ok ".service==\"$G8\"") = 0 ] && [ \"$(siname $V8)\" = svc-8 ] && grep -q 'a-49 .* BLOCKED: svc-9 name-stuck' '$R/apply.log'"
check "S3b status: svc-8 ATTENTION with a-49 BLOCKED in the attention list" "grep -q 'svc-8 .* ATTENTION' '$R/status.log' && grep -q \"$A49 *bind-valkey:blocked .*svc-9 is name-stuck\" '$R/status.log'"
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-9 --yes --reason retry --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "S4 rollback again (no fake failure): redis back to svc-9, rename-standby undone; exit reflects the dead binding only" "[ \"$(siname $G9)\" = svc-9 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 1 ] && grep -q 'valkey already named svc-9-valkey-staged' '$R/rb.log'"
CFFAKE_HOLLOW=svc-9 CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply-s5.log" 2>&1
check "S5 apply again once svc-9's names are back: a-49 no longer blocked -> migrated on svc-8 (blocked is not done); svc-9 given up on again, its names back" "[ $(nev verify ok ".service==\"$G8\" and .app==\"$A49\"") = 1 ] && [ $(restarts $A49) = 1 ] && [ \"$(siname $G9)\" = svc-9 ]"
bash "$M" apply --wave 1 --service svc-7 --yes --force --run "$R" > "$R/apply7.log" 2>&1
CFFAKE_NAMED="$NAMED" CFFAKE_RENAME_FAIL=$G7:svc-7 bash "$M" rollback --wave 1 --service svc-7 --yes --reason "force a names failure" --run "$R" > "$R/rb7.log" 2>&1; rc=$?
check "S6 operator rollback whose redis rename-back fails: exit 1, 'names not restored', NAMES-STUCK" "[ $rc = 1 ] && grep -q 'names not restored' '$R/rb7.log' && [ $(nev rollback-names fail ".service==\"$G7\"") = 1 ]"
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "again" --run "$R" > "$R/rb7b.log" 2>&1; rc=$?
check "S7 rollback again: finishes, exit 0, redis svc-7, apps rolled back, no name-sync pending" "[ $rc = 0 ] && [ \"$(siname $G7)\" = svc-7 ] && [ $(nev rename-standby undone ".service==\"$G7\"") = 1 ] && [ \"$(WAVE= bash "$M" status --run "$R" | grep -c 'name-sync pending')\" = 0 ]"

echo "== N: plain 'apply --wave' after a neighbour was rolled back re-does the multi-bound app (review finding 7)"
newrun N; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "N0 all 3 migrated" "[ $(nev verify ok) = 8 ]"
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-8 --yes --reason test --run "$R" > "$R/rb.log" 2>&1; check "N1 svc-8 rolled back, names back" "[ $? = 0 ] && [ \"$(siname $G8)\" = svc-8 ]"
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply2.log" 2>&1; rc=$?
check "N2 apply --wave 1 (no --service): a-28 and a-49 re-bound to svc-8's valkey although verified on svc-7/svc-9; 3 verified for svc-8" "[ $rc = 0 ] && [ $(nev verify ok ".service==\"$G8\"") = 6 ] && [ $(nev bind-valkey ok ".service==\"$G8\" and .app==\"$A28\"") = 2 ]"

echo "== E: end-loop undo on a day-of create failure keeps the phase (CREATE-FAILED), redis gets its name back"
newrun E   # no provision: day-of creates
CFFAKE_FAIL_CREATE=svc-9 CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "E1 svc-9 create failed -> rename-standby undone, redis named svc-9" "[ $(nev create-valkey fail ".service==\"$G9\"") = 1 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 1 ] && [ \"$(siname $G9)\" = svc-9 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1; bash "$M" status --run "$R" > "$R/ov.log" 2>&1
check "E2 status: svc-9 CREATE-FAILED (undo lines are not a phase); overview created 2, c-fail 1" "grep -q 'svc-9 .* CREATE-FAILED' '$R/status.log' && grep -qE '^1 +3 +2 +1 ' '$R/ov.log'"
check "E3 inventory: svc-9 not-provisioned/create-failed under its own name; svc-8 cut-over" "[ \"$(awk -F'\t' -v s=$G9 'NR>1 && $7==s && !d++ {print $6, $11}' "$R/inventory.tsv")\" = 'svc-9 create-failed' ]"

echo "== K: apps rolled back before ('rollback ok'): restarted when that rollback skipped the restart (ledger) or the app is down (stats); left alone otherwise (SBX app-028)"
newrun K; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "K0 all 3 migrated" "[ $(nev verify ok) = 8 ]"
# svc-7 as the old tool left it: names still swapped, every app's bindings back on redis. a-57: restart failed, rollback
# WITHOUT restart, crashed (its last start saw 'svc-7-redis-standby'). a-7: same history but RUNNING -- its process still
# holds the valkey env (came up after the 300 s timeout). a-28: rollback WITH restart, running -> nothing to do.
python3 - "$CFFAKE_STATE" $G7 $V7 $A57 $A7 $A28 <<'EOP'
import json,sys; p,g,v,a57,a7,a28=sys.argv[1:]; st=json.load(open(p))
for a,env in ((a57,['svc-7-redis-standby']),(a7,['svc-7']),(a28,['svc-8','svc-7'])):
    for k in [k for k,b in st['bind'].items() if b['app']==a and b['si']==v]: del st['bind'][k]
    st['bind']['b-old-'+a[:8]]={'app':a,'si':g}; st.setdefault('env',{})[a]=env
json.dump(st,open(p,'w'))
EOP
for a in $A57 $A7 $A28; do did="rebind redis + unbind valkey"; [ $a = $A28 ] && did="$did + restart"
  jq -nc --arg s $G7 --arg a $a '{ts:"2026-10-20T16:10:01Z",wave:1,service:$s,app:$a,step:"restart",outcome:"fail",ms:0,op:"old",note:"instances 0/1 after 300s"}' >> "$R/ledger.jsonl"
  jq -nc --arg s $G7 --arg a $a --arg d "$did" '{ts:"2026-10-20T16:25:48Z",wave:1,service:$s,app:$a,step:"rollback",outcome:"ok",ms:0,op:"old",note:("cause: restart of the app failed; "+$d)}' >> "$R/ledger.jsonl"
done
stat(){ CFFAKE_NAMED=$NAMED $CF_CMD curl /v3/apps/$1/processes/web/stats | jq -r '.resources[0].state'; }
check "K1 setup: a-57 CRASHED, a-7 and a-28 RUNNING, all three at 'rollback ok'" "[ \"$(stat $A57)\" = CRASHED ] && [ \"$(stat $A7)\" = RUNNING ] && [ \"$(stat $A28)\" = RUNNING ]"
r57=$(restarts $A57); r7=$(restarts $A7); r28=$(restarts $A28)
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "sbx repair" --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "K2 rollback exits 0, names back" "[ $rc = 0 ] && [ \"$(siname $G7)\" = svc-7 ] && [ \"$(siname $V7)\" = svc-7-valkey-staged ]"
check "K3 a-57 (crashed) restarted once more, now RUNNING, 'rollback ok; restart' recorded" "[ $(restarts $A57) = $((r57+1)) ] && [ $(nev rollback ok ".app==\"$A57\" and .op==\"test\" and (.note|test(\"; restart\"))") = 1 ] && [ \"$(stat $A57)\" = RUNNING ]"
check "K4 a-7 (RUNNING, but the earlier rollback never restarted it) restarted too -- the ledger decides, not the stats" "[ $(restarts $A7) = $((r7+1)) ] && [ $(nev rollback ok ".app==\"$A7\" and .op==\"test\" and (.note|test(\"; restart\"))") = 1 ] && grep -q 'a-7: rolled back before, its last start was for the valkey' '$R/rb.log'"
check "K5 a-28 (earlier rollback DID restart it, running) left alone: no restart, no new line, not in the output" "[ $(restarts $A28) = $r28 ] && [ $(nev rollback ok ".app==\"$A28\" and .op==\"test\"") = 0 ] && ! grep -q 'a-28' '$R/rb.log'"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1; check "K6 status: svc-7 ROLLED-BACK" "grep -q 'svc-7 .* ROLLED-BACK' '$R/status.log'"
# K7: a STOPPED app at 'rollback ok' (stats 0/1) is looked at and left alone -- no restart, no new line
python3 - "$CFFAKE_STATE" $A57 <<'EOP'
import json,sys; p,a=sys.argv[1:]; st=json.load(open(p)); st['apps'][a]['state']='STOPPED'; json.dump(st,open(p,'w'))
EOP
r57=$(restarts $A57); n57=$(nev rollback ok ".app==\"$A57\"")
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "again" --run "$R" > "$R/rb2.log" 2>&1; rc=$?
check "K7 rollback again with a-57 STOPPED: exit 0, no restart, no new ledger line, nothing said about restarting it" "[ $rc = 0 ] && [ $(restarts $A57) = $r57 ] && [ $(nev rollback ok ".app==\"$A57\"") = $n57 ] && ! grep -q 'restarting it' '$R/rb2.log'"
# K8: stats unreadable for an app at 'rollback ok' -> rollback fail, said out loud, exit 1, ATTENTION
CFFAKE_STATS_FAIL=$A7 CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "again" --run "$R" > "$R/rb3.log" 2>&1; rc=$?
bash "$M" status --wave 1 --run "$R" > "$R/status3.log" 2>&1
check "K8 a-7's stats answer an error: 'rollback fail … cannot read its instances', exit 1, status ATTENTION -- never a silent skip" "[ $rc = 1 ] && [ $(nev rollback fail ".app==\"$A7\" and (.note|test(\"cannot read its instances\"))") = 1 ] && grep -q 'a-7: rolled back before, cannot read its instances' '$R/rb3.log' && grep -q 'svc-7 .* ATTENTION' '$R/status3.log'"

echo "== X: a restart that fails on the way to the Valkey (restart:fail) is restarted again by the auto-rollback"
newrun X; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc
CFFAKE_CRASH=$A57 CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
check "X1 a-57: restart fail, then the rollback tried a restart (2 restarts), recorded as rollback fail (still crashing)" "[ $(nev restart fail ".app==\"$A57\"") = 1 ] && [ $(restarts $A57) = 2 ] && [ $(nev rollback fail ".app==\"$A57\" and .service==\"$G7\"") = 1 ]"
check "X2 svc-7's names back; svc-8 and svc-9 migrated" "[ \"$(siname $G7)\" = svc-7 ] && [ $(nev verify ok ".service==\"$G8\"") = 3 ] && [ $(nev verify ok ".service==\"$G9\"") = 2 ]"

echo "== D1/D6: rollback re-run after a FAILED rebind: the failed binding record is deleted, the app restarted (defects 1 + 6)"
newrun D; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "D0 all 3 migrated" "[ $(nev verify ok) = 8 ]"
CFFAKE_BIND_FAIL=$A7 CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "drill" --run "$R" > "$R/rb1.log" 2>&1; rc=$?
corpse=$(jq -r --arg a $A7 --arg s $G7 '.bind|to_entries[]|select(.value.app==$a and .value.si==$s)|.key' "$CFFAKE_STATE")
check "D1 a-7's rebind to redis FAILS: rollback fail, exit 1; CF keeps the binding record in state failed (the corpse); a-57, a-28 rolled back" "[ $rc = 1 ] && [ $(nev rollback fail ".app==\"$A7\" and (.note|test(\"bind refused\"))") = 1 ] && [ -n \"$corpse\" ] && [ \"$($CF_CMD curl "/v3/service_credential_bindings?app_guids=$A7&service_instance_guids=$G7" | jq -r '.resources[0].last_operation.state')\" = failed ] && [ $(nev rollback ok ".service==\"$G7\"") = 2 ]"
env7=$(jq -r --arg a $A7 '.env[$a]|join(",")' "$CFFAKE_STATE")
check "D1b a-7 still RUNNING on the valkey env (RUNNING proves nothing -- what the old rule looked at)" "[ \"$(CFFAKE_NAMED=$NAMED $CF_CMD curl /v3/apps/$A7/processes/web/stats | jq -r '.resources[0].state')\" = RUNNING ] && [ \"$env7\" = svc-7 ]"
r7=$(restarts $A7)
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "again" --run "$R" > "$R/rb2.log" 2>&1; rc=$?
check "D2 rollback again: the corpse is deleted first, redis rebound, valkey unbound, and the app RESTARTED (ledger: restarted onto the valkey since its last rollback ok) -> rollback ok, exit 0" "[ $rc = 0 ] && [ $(nev rollback ok ".app==\"$A7\" and (.note|test(\"failed redis binding .* deleted \\\\+ rebind redis \\\\+ unbind valkey \\\\+ restart\"))") = 1 ] && [ $(restarts $A7) = $((r7+1)) ]"
sis7=$(jq -r --arg a $A7 '[.bind[]|select(.app==$a)]|map(.si)|join(",")' "$CFFAKE_STATE")
check "D3 CF: a-7 bound to its redis only (one succeeded binding, no corpse), names back" "[ \"$sis7\" = $G7 ] && [ \"$(jq -r --arg a $A7 --arg s $G7 '.bind|to_entries[]|select(.value.app==$a and .value.si==$s)|.key' "$CFFAKE_STATE")\" != \"$corpse\" ] && [ \"$(siname $G7)\" = svc-7 ]"

echo "== D4: the defect-1 story already in the ledger (a rollback ok that skipped the restart after a rollback fail): the next rollback restarts the app"
newrun D4; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
# a-57 as an older tool left it: bindings back on redis, but its process still holds the valkey env; ledger: restart ok, verify ok, rollback FAIL, rollback ok WITHOUT restart
python3 - "$CFFAKE_STATE" $A57 $G7 $V7 <<'EOP'
import json,sys; p,a,g,v=sys.argv[1:]; st=json.load(open(p))
for k in [k for k,b in st['bind'].items() if b['app']==a]: del st['bind'][k]
st['bind']['b-old-a57']={'app':a,'si':g}; st.setdefault('env',{})[a]=['svc-7']; json.dump(st,open(p,'w'))
EOP
for ev in 'rollback fail "cause: drill; FAILED: bind refused"' 'rollback ok "cause: again; rebind redis + unbind valkey"'; do eval "set -- $ev"
  jq -nc --arg s $G7 --arg a $A57 --arg st "$1" --arg o "$2" --arg n "$3" '{ts:"2026-10-21T10:00:00Z",wave:1,service:$s,app:$a,step:$st,outcome:$o,ms:0,op:"old",note:$n}' >> "$R/ledger.jsonl"; done
r57=$(restarts $A57)
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "repair" --run "$R" > "$R/rb3.log" 2>&1; rc=$?
check "D4 a-57 (RUNNING, rollback ok on record, but restarted onto the valkey since its last rollback OK -- the fail in between undid nothing) is restarted" "[ $rc = 0 ] && [ $(restarts $A57) = $((r57+1)) ] && grep -q 'a-57: rolled back before, its last start was for the valkey' '$R/rb3.log' && [ $(nev rollback ok ".app==\"$A57\" and .op==\"test\" and (.note|test(\"; restart\"))") = 1 ]"

echo "== G: valkey PURGED before the rollback (the order the hollow advice warns against): the redis still gets its name back (defect 7)"
newrun G; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "G0 all 3 migrated" "[ $(nev verify ok) = 8 ]"
"$CF_CMD" curl -X DELETE "/v3/service_instances/$V7?purge=true" > /dev/null
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "purged first" --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "G1 rollback exits 0: valkey 'not found (purged?) -- name free', redis renamed back to svc-7, rename-valkey undone + rename-standby undone, the create VOIDED (create-valkey fail 'purged')" "[ $rc = 0 ] && grep -q 'not found in CF (purged?) -- name free' '$R/rb.log' && [ \"$(siname $G7)\" = svc-7 ] && [ $(nev rename-valkey undone ".service==\"$G7\" and (.note|test(\"not found\"))") = 1 ] && [ $(nev rename-standby undone ".service==\"$G7\"") = 1 ] && [ $(nev create-valkey fail ".service==\"$G7\" and (.note|test(\"purged before the rollback\"))") = 1 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1
check "G1b inventory/status do not show the purged valkey as staged: svc-7 create-failed under its own name, phase CREATE-FAILED" "[ \"$(awk -F'\t' -v s=$G7 'NR>1 && $7==s && !d++ {print $6, $8, $11}' "$R/inventory.tsv")\" = 'svc-7 - create-failed' ] && grep -q 'svc-7 .* CREATE-FAILED' '$R/status.log'"
check "G2 the 3 apps rebound to the redis and restarted (nothing to unbind: the purge took the bindings)" "[ $(nev rollback ok ".service==\"$G7\" and (.note|test(\"rebind redis \\\\+ restart\"))") = 3 ] && [ $(jq --arg s $G7 '[.bind[]|select(.si==$s)]|length' "$CFFAKE_STATE") = 3 ]"
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "again" --run "$R" > "$R/rb2.log" 2>&1; rc=$?
check "G2b rollback again: nothing to roll back (no valkey, redis not renamed), exit 1, no new ledger line" "[ $rc = 1 ] && grep -q 'nothing to roll back' '$R/rb2.log' && [ $(nev create-valkey fail ".service==\"$G7\"") = 1 ]"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov2.log" 2>&1; check "G3 provision afterwards: svc-7 created again (staged, new guid), no second loss line" "[ $(nev create-valkey ok ".service==\"$G7\"") = 2 ] && [ $(nev create-valkey fail ".service==\"$G7\"") = 1 ] && [ \"$(siname $(vkof $G7))\" = svc-7-valkey-staged ] && [ \"$(vkof $G7)\" != \"$V7\" ]"

echo "== W: a bind IN PROGRESS from a killed run is waited for, never adopted (defect 4); a failed one becomes a corpse and is deleted first"
newrun W; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7); V8=$(vkof $G8)
python3 - "$CFFAKE_STATE" $A57 $V7 $A8 $V8 <<'EOP'
import json,sys; p,a57,v7,a8,v8=sys.argv[1:]; st=json.load(open(p))
st['jobs']['job-hand-ok']={'kind':'bind','polls':3,'n':0,'fail':None};  st['bind']['b-hand-ok']={'app':a57,'si':v7,'job':'job-hand-ok'}     # a-57 -> svc-7's valkey: bind still running
st['jobs']['job-hand-bad']={'kind':'bind','polls':3,'n':0,'fail':'Service broker error: bind refused'}; st['bind']['b-hand-bad']={'app':a8,'si':v8,'job':'job-hand-bad'}   # a-8 -> svc-8's valkey: bind running, will FAIL
json.dump(st,open(p,'w'))
EOP
check "W0 setup: both hand-made bindings read 'in progress'" "[ \"$($CF_CMD curl "/v3/service_credential_bindings?app_guids=$A57&service_instance_guids=$V7" | jq -r '.resources[0].last_operation.state')\" = 'in progress' ]"
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "W1 a-57: waited for the running bind (said so), then adopted it once succeeded -- no second POST (the hand-made binding is THE binding); migrated" "[ $rc = 0 ] && grep -q \"binding b-hand-o is 'in progress' .* waiting for it, not adopting it\" '$R/apply.log' && [ $(nev bind-valkey ok ".app==\"$A57\" and (.note|test(\"already present \\\\(b-hand-ok\\\\)\"))") = 1 ] && [ \"$(jq -r --arg a $A57 --arg v $V7 '.bind|to_entries[]|select(.value.app==$a and .value.si==$v)|.key' "$CFFAKE_STATE")\" = b-hand-ok ] && [ $(nev verify ok ".app==\"$A57\"") = 1 ]"
check "W2 a-8: waited, the bind FAILED -> the failed record deleted first, a new bind made; note says so; migrated" "[ $(nev bind-valkey ok ".app==\"$A8\" and (.note|test(\"failed binding b-hand-bad deleted first\"))") = 1 ] && [ \"$(jq -r --arg a $A8 --arg v $V8 '.bind|to_entries[]|select(.value.app==$a and .value.si==$v)|.key' "$CFFAKE_STATE")\" != b-hand-bad ] && [ $(nev verify ok ".app==\"$A8\"") = 1 ]"
check "W3 neither app was unbound from its redis while the bind was still running (unbind only after a succeeded bind)" "[ $(grep -c 'is .in progress' "$R/apply.log") = 2 ] && [ $(nev unbind-redis ok ".app==\"$A57\"") = 1 ] && [ $(nev unbind-redis ok ".app==\"$A8\"") = 1 ]"

echo "== W4: a bind still in progress past BIND_TIMEOUT: that app is left as it is, the service and its other apps go on (review round 3)"
newrun W4; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
python3 - "$CFFAKE_STATE" $A57 $V7 <<'EOP'
import json,sys; p,a57,v7=sys.argv[1:]; st=json.load(open(p))
st['jobs']['job-slow']={'kind':'bind','polls':40,'n':0,'fail':None}; st['bind']['b-slow']={'app':a57,'si':v7,'job':'job-slow'}; json.dump(st,open(p,'w'))
EOP
BIND_TIMEOUT=0 CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "W4a a-57: 'still in progress' -> bind-valkey fail 'app left as it is', NOT restarted, redis binding kept; svc-7 NOT rolled back (valkey still svc-7), a-7 + a-28 verified; exit 0" "[ $rc = 0 ] && [ $(nev bind-valkey fail ".app==\"$A57\" and (.note|test(\"still .in progress. after 0s.*app left as it is\"))") = 1 ] && [ $(restarts $A57) = 0 ] && [ $(jq --arg a $A57 --arg s $G7 '[.bind[]|select(.app==$a and .si==$s)]|length' "$CFFAKE_STATE") = 1 ] && [ \"$(siname $V7)\" = svc-7 ] && [ $(nev verify ok ".service==\"$G7\"") = 2 ] && [ $(nev rollback ok ".service==\"$G7\"") = 0 ]"
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply2.log" 2>&1; rc=$?
check "W4b apply again with the normal timeout: the bind settles, a-57 adopts it and migrates" "[ $rc = 0 ] && [ $(nev bind-valkey ok ".app==\"$A57\" and (.note|test(\"already present \\\\(b-slow\\\\)\"))") = 1 ] && [ $(nev verify ok ".app==\"$A57\"") = 1 ]"

echo "== Y: an app whose LAST line is 'bind-valkey blocked' (or any non-restart line) after a restart onto the valkey: the rollback restarts it (review round 3, finding 1)"
newrun Y; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "Y0 all 3 migrated" "[ $(nev verify ok) = 8 ]"
jq -nc --arg s $G7 --arg a $A57 '{ts:"2026-10-21T12:00:00Z",wave:1,service:$s,app:$a,step:"bind-valkey",outcome:"blocked",ms:0,op:"old",note:"not touched: svc-x is name-stuck"}' >> "$R/ledger.jsonl"
r57=$(restarts $A57)
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "drill" --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "Y1 a-57 (last line blocked, restarted onto the valkey before it) is rebound, unbound AND restarted; rollback ok, exit 0" "[ $rc = 0 ] && [ $(restarts $A57) = $((r57+1)) ] && [ $(nev rollback ok ".app==\"$A57\" and (.note|test(\"rebind redis \\\\+ unbind valkey \\\\+ restart\"))") = 1 ]"

echo "== I: the instance count cannot be read -> the app is skipped, nothing changed; never guessed as 1 (defect 3)"
newrun I; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; pc; V7=$(vkof $G7)
CFFAKE_FAIL_GET="/v3/apps/$A57/processes/web\$" CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "I1 a-57: 'instance count unknown' drift fail, not bound to the valkey, not restarted; the other 5 apps verified; exit 0" "[ $rc = 0 ] && [ $(nev drift fail ".app==\"$A57\" and (.note|test(\"instance count unknown\"))") = 1 ] && [ $(jq --arg a $A57 --arg v $V7 '[.bind[]|select(.app==$a and .si==$v)]|length' "$CFFAKE_STATE") = 0 ] && [ $(restarts $A57) = 0 ] && [ $(nev verify ok) = 7 ] && grep -q 'a-57: cannot read its instance count' '$R/apply.log'"
check "I2 its redis binding untouched; status shows svc-7 ATTENTION" "[ $(jq --arg a $A57 --arg s $G7 '[.bind[]|select(.app==$a and .si==$s)]|length' "$CFFAKE_STATE") = 1 ] && bash '$M' status --wave 1 --run '$R' | grep -q 'svc-7 .* ATTENTION'"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
