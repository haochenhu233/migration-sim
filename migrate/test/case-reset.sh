#!/usr/bin/env bash
# case-reset.sh -- offline cases for scripts/reset-scaled.sh against cf-fake + safe-fake + bosh-fake.
# Usage: bash migrate/test/case-reset.sh [workdir]. Every case prints PASS/FAIL; exit 1 if any FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; RS="$HERE/../../scripts/reset-scaled.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
export CF_CMD="$HERE/cf-fake" BOSH_CMD="$HERE/bosh-fake" JOB_POLL=0 SOAK=0 MIGRATE_OP=test RESET_POLL=0 RESET_WAIT=5
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
newrun(){ R="$W/$1"; rm -rf "$R"; mkdir -p "$R"; cp "$HERE/../example/waves.tsv" "$R/"
  export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; "$CF_CMD" seed "$R/waves.tsv" > /dev/null
  printf 'SAFE_RUN="%s"\n' "$HERE/safe-fake" > "$R/vault.conf"; }
nvalkey(){ jq '[.si[]|select(.plan|startswith("plan-valkey-"))]|length' "$CFFAKE_STATE"; }
nredis(){ jq '[.si[]|select(.plan|startswith("plan-redis-"))]|length' "$CFFAKE_STATE"; }
napps(){ jq '.apps|length' "$CFFAKE_STATE"; }
# bindings of plan apps to their plan redis (guid pairs from waves.tsv)
nbound_redis(){ awk -F'\t' 'NR>1 {print $9 "\t" $4}' "${PLANF:-$R/waves.tsv}" | while IFS=$'\t' read -r a s; do jq -r --arg a "$a" --arg s "$s" '[.bind[]|select(.app==$a and .si==$s)]|length' "$CFFAKE_STATE"; done | awk '{n+=$1} END {print n+0}'; }
nbound_valkey(){ jq '[.bind[] as $b | select(.si as $s | $b.app != null and ($s|length)>0) | $b] | map(select(.si as $s | input_filename==null)) | length' "$CFFAKE_STATE" 2>/dev/null; }
nbind_to_valkeys(){ jq '[.si|to_entries[]|select(.value.plan|startswith("plan-valkey-"))|.key] as $v | [.bind[]|select(.si as $s | $v|index($s))]|length' "$CFFAKE_STATE"; }

echo "== A: a migrated run (wave 1 cut over = 4 services, wave 2's 8 untouched) -> dry run changes nothing, --go resets, reset state refused"
newrun A
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
pairs=$(awk -F'\t' 'NR>1 && $1==1' "$R/waves.tsv" | wc -l | tr -d ' '); allpairs=$(awk 'NR>1' "$R/waves.tsv" | wc -l | tr -d ' '); NV0=$(nvalkey); NR0=$(nredis); NA0=$(napps)
check "A0 setup: 4 valkeys cut over, $pairs app-service pairs on valkey" "[ $NV0 = 4 ] && [ $(nbind_to_valkeys) = $pairs ]"
bash "$RS" --run "$R" > "$R/dry.log" 2>&1; rc=$?
check "A1 dry run: exits 0, says DRY RUN, lists 12 rollbacks and the 4 valkeys as CF has them, changes nothing (valkeys/bindings/ledger untouched)" "[ $rc = 0 ] && grep -q 'DRY RUN' '$R/dry.log' && [ $(grep -c '   would: migrate.sh rollback' "$R/dry.log") = 12 ] && [ $(grep -c 'deleted only once named' "$R/dry.log") = 4 ] && [ $(nvalkey) = $NV0 ] && [ $(nbind_to_valkeys) = $pairs ] && ! grep -q '\"op\":\"test\".*\"step\":\"rollback\"' '$R/ledger.jsonl' && [ -s '$R/ledger.jsonl' ]"
bash "$RS" --run "$R" --go > "$R/go.log" 2>&1; rc=$?
check "A2 --go: exits 0, 4 rolled back + 8 untouched, verify 0 problems, 4 deleted, archive created" "[ $rc = 0 ] && [ $(grep -c ': rolled back' "$R/go.log") = 4 ] && [ $(grep -c 'nothing to roll back' "$R/go.log") = 8 ] && grep -q ' 0 problem(s)' '$R/go.log' && grep -q '   4 to delete, 0 already gone, 0 refused' '$R/go.log' && grep -q 'all gone' '$R/go.log' && ls -d '$R'/pass-* >/dev/null"
PLANF=$(ls -d "$R"/pass-*)/waves.tsv
check "A3 CF state: no valkey, all redis still there under plan names, all apps there and bound to their redis ($allpairs pairs), none to a valkey" "[ $(nvalkey) = 0 ] && [ $(nredis) = $NR0 ] && [ $(napps) = $NA0 ] && [ $(nbound_redis) = $allpairs ] && [ $(nbind_to_valkeys) = 0 ] && [ $(jq -r '.si[]|select(.plan|startswith("plan-redis-"))|.name' "$CFFAKE_STATE" | grep -c -- '-redis-standby') = 0 ]"
check "A4 run dir: ledger/inventory/waves moved into the archive, vault.conf stays" "[ ! -e '$R/ledger.jsonl' ] && [ ! -e '$R/waves.tsv' ] && [ -s '$R/vault.conf' ] && [ -s \"\$(ls -d '$R'/pass-*)/ledger.jsonl\" ] && [ -s \"\$(ls -d '$R'/pass-*)/waves.tsv\" ]"
cp "$(ls -d "$R"/pass-*)/waves.tsv" "$R/"; printf '' > "$R/ledger.jsonl"
bash "$RS" --run "$R" --go > "$R/go2.log" 2>&1; rc=$?
check "A5 re-run on the reset state (plan + empty ledger): refused -- empty ledger means nothing to reset" "[ $rc = 2 ] && grep -q 'ledger.jsonl missing' '$R/go2.log'"

echo "== B: safety -- a valkey that still has a binding, or still carries the production name, is refused and nothing is deleted"
newrun B
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
G0=2f6fe3d9-1e8a-48cf-ae53-4d6e0f5ca70a   # cache-0, wave 1
VK0=$(jq -r --arg s "$G0" 'select(.service==$s and .step=="create-valkey" and .outcome=="ok") | .note' "$R/ledger.jsonl" | tail -1 | grep -oE '[0-9a-f-]{36}' | head -1)
# roll back by hand everything except: leave a foreign binding on cache-0's valkey after its rollback
for s in $(awk -F'\t' 'NR>1 && $1==1 && !x[$3]++ {print $3}' "$R/waves.tsv"); do bash "$M" rollback --wave 1 --service "$s" --yes --reason t --run "$R" > /dev/null 2>&1; done
"$CF_CMD" curl -X POST /v3/service_credential_bindings -d "{\"type\":\"app\",\"relationships\":{\"app\":{\"data\":{\"guid\":\"860c4212-e028-4013-ba36-4cab96e5aa45\"}},\"service_instance\":{\"data\":{\"guid\":\"$VK0\"}}}}" > /dev/null 2>&1
NV1=$(nvalkey)
bash "$RS" --run "$R" --go > "$R/go.log" 2>&1; rc=$?
check "B1 a valkey with a binding left: refused, exit 1, NO valkey deleted, no archive" "[ $rc = 1 ] && grep -q 'still has 1 binding(s)/key(s) -- refused' '$R/go.log' && [ $(nvalkey) = $NV1 ] && ! ls -d '$R'/pass-* >/dev/null 2>&1 && [ -s '$R/ledger.jsonl' ]"
"$CF_CMD" curl -X DELETE "/v3/service_credential_bindings/$(jq -r --arg v "$VK0" '.bind|to_entries[]|select(.value.si==$v)|.key' "$CFFAKE_STATE")" > /dev/null 2>&1
bg=$(jq -r --arg a 860c4212-e028-4013-ba36-4cab96e5aa45 --arg s "$G0" '.bind|to_entries[]|select(.value.app==$a and .value.si==$s)|.key' "$CFFAKE_STATE")
"$CF_CMD" curl -X DELETE "/v3/service_credential_bindings/$bg" > /dev/null 2>&1   # someone unbound app-0 from its redis after the rollback
bash "$RS" --run "$R" --go > "$R/go2.log" 2>&1; rc=$?
check "B2 an app without its redis binding after the rollback pass: verify fails, exit 1, nothing deleted, no archive" "[ $rc = 1 ] && grep -q 'has NO binding to its redis' '$R/go2.log' && grep -q 'nothing deleted' '$R/go2.log' && [ $(nvalkey) = $NV1 ] && ! ls -d '$R'/pass-* >/dev/null 2>&1"

echo "== C: CF API error while verifying -> stop, nothing deleted"
newrun C
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
NV2=$(nvalkey)
CFFAKE_FAIL_GET="/v3/service_credential_bindings" bash "$RS" --run "$R" --go > "$R/go.log" 2>&1; rc=$?
check "C1 bindings listing fails (API error): said per pair, exit 1, nothing deleted, no archive" "[ $rc != 0 ] && grep -q 'cannot list bindings' '$R/go.log' && [ $(nvalkey) = $NV2 ] && ! ls -d '$R'/pass-* >/dev/null 2>&1"

echo; [ "$fails" = 0 ] && echo "ALL PASS (workdir $W)" || { echo "$fails FAIL (workdir $W)"; exit 1; }
