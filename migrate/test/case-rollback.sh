#!/usr/bin/env bash
# case-rollback.sh -- a rollback restores the NAMES, not only the bindings (SBX wave 6, 2026-10-20): apps resolve
# their service by name in VCAP_SERVICES, and a multi-bound app is restarted by its other service's step.
# Fixture test/fixtures/waves-chain.tsv: one wave, services svc-7 svc-8 svc-9 chained by a-28 (8+7) and a-49 (9+8).
# svc-9's Valkey is HOLLOW (CF has it, the broker lost it). Usage: bash migrate/test/case-rollback.sh [workdir]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
export CF_CMD="$HERE/cf-fake" JOB_POLL=0 SOAK=0 MIGRATE_OP=test RESTART_TIMEOUT=2
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
newrun(){ R="$W/$1"; rm -rf "$R"; mkdir -p "$R"; cp "$HERE/fixtures/waves-chain.tsv" "$R/waves.tsv"
  export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; "$CF_CMD" seed "$R/waves.tsv" > /dev/null
  printf 'SAFE_RUN="%s"\n' "$HERE/safe-fake" > "$R/vault.conf"; }
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
V9=$(vkof $G9); V8=$(vkof $G8); V7=$(vkof $G7)
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
check "R12 apply again with the hollow still there: the failed binding is not read as 'already bound'; CF refuses a new one; names undone again" "[ $(nev bind-valkey ok ".app==\"$A9\" and (.note|test(\"already present\"))") = 0 ] && [ $(nev bind-valkey fail ".app==\"$A9\" and (.note|test(\"already bound\"))") = 1 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 2 ]"

echo "== P: purge the hollow valkey, provision again, apply again -> svc-9 migrates"
"$CF_CMD" curl -X DELETE "/v3/service_instances/$V9?purge=true" > /dev/null
check "P1 purge: instance and its failed binding gone from CF" "[ \"$(siname $V9)\" = GONE ] && [ $(jq --arg a $A9 '[.bind[]|select(.app==$a)]|length' "$CFFAKE_STATE") = 1 ]"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov2.log" 2>&1
check "P2 provision: svc-9 'gone from CF -- creating again', a new staged valkey; svc-7/8 untouched" "[ $(nev create-valkey fail ".service==\"$G9\" and (.note|test(\"gone from CF\"))") = 1 ] && [ $(nev create-valkey ok ".service==\"$G9\"") = 2 ] && [ $(nev create-valkey ok) = 4 ]"
V9b=$(vkof $G9); check "P3 new staged valkey named svc-9-valkey-staged" "[ \"$(siname $V9b)\" = svc-9-valkey-staged ] && [ \"$V9b\" != \"$V9\" ]"
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
newrun F; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; V9=$(vkof $G9)
python3 - "$CFFAKE_STATE" $V9 <<'EOF2'
import json,sys; p,v=sys.argv[1:]; st=json.load(open(p)); st['si'][v]['name']='svc-9-renamed-by-hand'; json.dump(st,open(p,'w'))
EOF2
CFFAKE_NAMED="$NAMED" bash "$M" apply --wave 1 --yes --force --run "$R" > "$R/apply.log" 2>&1; rc=$?   # --force: preflight would catch the hand rename
check "F1 svc-9: drift recorded, valkey left as it is (rollback-names fail names it), redis back to svc-9 (rename-standby undone)" "[ $(nev drift fail ".service==\"$G9\" and (.note|test(\"renamed-by-hand\"))") = 1 ] && [ $(nev rollback-names fail ".service==\"$G9\" and (.note|test(\"renamed-by-hand\"))") = 1 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 1 ] && [ \"$(siname $G9)\" = svc-9 ]"
check "F2 svc-7 and svc-8 migrated regardless (a-49 restarted by svc-8 found svc-9 = the redis)" "[ $rc = 0 ] && [ $(nev verify ok ".service==\"$G8\"") = 3 ] && [ $(nev verify ok ".service==\"$G7\"") = 3 ]"

echo "== S: a rename-back that FAILS is recorded under its own step; the rename lines keep saying what CF has; the next rollback finishes it"
newrun S; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; V9=$(vkof $G9)
CFFAKE_HOLLOW=svc-9 CFFAKE_NAMED="$NAMED" CFFAKE_RENAME_FAIL=$G9:svc-9 bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "S1 valkey undone, redis PATCH back failed: rollback-names fail, rename-standby still 'ok' for ledger_done, CF redis still standby" "[ $(nev rename-valkey undone ".service==\"$G9\"") = 1 ] && [ $(nev rollback-names fail ".service==\"$G9\" and (.note|test(\"rename back to svc-9 failed\"))") = 1 ] && [ $(nev rename-standby fail) = 0 ] && [ \"$(siname $G9)\" = svc-9-redis-standby ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1
check "S2 status: svc-9 NAMES-STUCK with !!" "grep -q 'svc-9 .* NAMES-STUCK .*!!' '$R/status.log'"
check "S3 a-49 (restarted by svc-8's step) crashed: svc-9 missing from its env -> svc-8 rolled back (names back) -- the SBX chain, now with the stuck redis as the cause" "[ $(nev rollback ok ".service==\"$G8\"") -ge 1 ] && [ \"$(siname $G8)\" = svc-8 ]"
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-9 --yes --reason retry --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "S4 rollback again (no fake failure): redis back to svc-9, rename-standby undone; exit reflects the dead binding only" "[ \"$(siname $G9)\" = svc-9 ] && [ $(nev rename-standby undone ".service==\"$G9\"") = 1 ] && grep -q 'valkey already named svc-9-valkey-staged' '$R/rb.log'"
bash "$M" apply --wave 1 --service svc-7 --yes --force --run "$R" > "$R/apply7.log" 2>&1
CFFAKE_NAMED="$NAMED" CFFAKE_RENAME_FAIL=$G7:svc-7 bash "$M" rollback --wave 1 --service svc-7 --yes --reason "force a names failure" --run "$R" > "$R/rb7.log" 2>&1; rc=$?
check "S6 operator rollback whose redis rename-back fails: exit 1, 'names not restored', NAMES-STUCK" "[ $rc = 1 ] && grep -q 'names not restored' '$R/rb7.log' && [ $(nev rollback-names fail ".service==\"$G7\"") = 1 ]"
CFFAKE_NAMED="$NAMED" bash "$M" rollback --wave 1 --service svc-7 --yes --reason "again" --run "$R" > "$R/rb7b.log" 2>&1; rc=$?
check "S7 rollback again: finishes, exit 0, redis svc-7, apps rolled back, no name-sync pending" "[ $rc = 0 ] && [ \"$(siname $G7)\" = svc-7 ] && [ $(nev rename-standby undone ".service==\"$G7\"") = 1 ] && [ \"$(WAVE= bash "$M" status --run "$R" | grep -c 'name-sync pending')\" = 0 ]"

echo "== N: plain 'apply --wave' after a neighbour was rolled back re-does the multi-bound app (review finding 7)"
newrun N; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1
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

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
