#!/usr/bin/env bash
# case-provision.sh -- offline cases for provision / staged rename / inventory / name-sync / shared gate,
# against migrate/test/cf-fake + safe-fake. Usage: bash migrate/test/case-provision.sh [workdir]
# Every case prints PASS/FAIL; exit 1 if any FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
export CF_CMD="$HERE/cf-fake" BOSH_CMD="$HERE/bosh-fake" JOB_POLL=0 SOAK=0 MIGRATE_OP=test
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }   # check <label> <shell condition>
newrun(){ # newrun <name> -> fresh run dir + fake state, vault.conf pointing at safe-fake
  R="$W/$1"; rm -rf "$R"; mkdir -p "$R"; cp "$HERE/../example/waves.tsv" "$R/"
  export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; "$CF_CMD" seed "$R/waves.tsv" > /dev/null
  printf 'SAFE_RUN="%s"\n' "$HERE/safe-fake" > "$R/vault.conf"; }
ledger(){ jq -r "$1" "$R/ledger.jsonl" 2>/dev/null; }                                   # ledger <jq filter>
nev(){ ledger "select(.step==\"$1\" and .outcome==\"$2\"${3:+ and $3}) | .service" | wc -l | tr -d ' '; }   # nev <step> <outcome> [extra jq]
siname(){ jq -r --arg g "$1" '.si[$g].name' "$CFFAKE_STATE"; }
G0=2f6fe3d9-1e8a-48cf-ae53-4d6e0f5ca70a   # cache-0  wave 1
G16=372a9867-d67f-41d4-82f8-74d134137944 # cache-16 wave 1
G3=130952d2-5373-454f-909c-54520fe4d24d  # cache-3  wave 2
G4=2a620cd6-8c54-417f-80b8-e5bb304c0d14  # cache-4  wave 2

echo "== A: provision both waves, re-run, preflight, shared gate"
newrun A
bash "$M" provision --waves 1-2 --yes --run "$R" > "$R/prov1.log" 2>&1; check "A1 provision exits 0" "[ $? = 0 ]"
check "A2 12 staged creates in the ledger" "[ $(nev create-valkey ok '(.note|test("\\(staged"))') = 12 ]"
check "A3 fake has 12 instances named *-valkey-staged" "[ $(jq '[.si[]|select(.name|endswith("-valkey-staged"))]|length' "$CFFAKE_STATE") = 12 ]"
check "A4 inventory: 12 lines, all staged, valkey_name = <name>-valkey-staged" "[ $(awk -F'\t' 'NR>1 && !($11=="staged" && $8==($6 "-valkey-staged"))' "$R/inventory.tsv" | wc -l | tr -d ' ') = 0 ] && [ $(awk -F'\t' 'NR>1 && $11=="staged" && $8==($6 "-valkey-staged") && $4!="" && $5!=""' "$R/inventory.tsv" | wc -l | tr -d ' ') = 12 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status1.log" 2>&1
check "A5 status wave 1 shows STAGED for 4 services" "[ $(grep -c ' STAGED ' "$R/status1.log") = 4 ]"
n1=$(grep -c . "$R/ledger.jsonl"); bash "$M" provision --waves 1-2 --yes --run "$R" > "$R/prov2.log" 2>&1
check "A6 re-run: no new create-valkey ok lines" "[ $(nev create-valkey ok) = 12 ] && grep -q 'already there' '$R/prov2.log'"
bash "$M" provision-check --run "$R" > "$R/pc-a.log" 2>&1   # the hollow gate: apply/preflight need a provision-check line per service
bash "$M" preflight --wave 1 --run "$R" > "$R/pf1.log" 2>&1; check "A7 preflight wave 1 OK" "[ $? = 0 ] && grep -q '^PREFLIGHT: OK' '$R/pf1.log'"
check "A8 preflight reports 4 staged present + 4 not shared" "[ $(grep -c 'staged valkey present' "$R/pf1.log") = 4 ] && [ $(grep -c 'not shared' "$R/pf1.log") = 4 ]"
CFFAKE_SHARED=$G0 bash "$M" preflight --wave 1 --run "$R" > "$R/pf-shared.log" 2>&1; check "A9 shared instance -> preflight FAIL" "[ $? != 0 ] && grep -q 'FAIL  service cache-0: shared into 1' '$R/pf-shared.log'"

echo "== B: staged valkey vanished from CF -> preflight FAIL, provision records the loss and creates again"
python3 - "$CFFAKE_STATE" "$(ledger "select(.service==\"$G16\" and .step==\"create-valkey\" and .outcome==\"ok\") | .note" | grep -oE '[0-9a-f-]{36}' | head -1)" <<'EOF'
import json,sys; p,g=sys.argv[1],sys.argv[2]; st=json.load(open(p)); del st['si'][g]; json.dump(st,open(p,'w'))
EOF
bash "$M" preflight --wave 1 --run "$R" > "$R/pf-gone.log" 2>&1; check "B1 preflight FAILs on the missing staged valkey" "[ $? != 0 ] && grep -q 'FAIL  service cache-16: staged valkey .* not found in CF' '$R/pf-gone.log'"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov3.log" 2>&1
check "B2 provision: void (fail 'gone') then a new ok for cache-16" "[ $(nev create-valkey fail ".service==\"$G16\" and (.note|test(\"gone from CF\"))") = 1 ] && [ $(nev create-valkey ok ".service==\"$G16\"") = 2 ]"
bash "$M" preflight --wave 1 --run "$R" > "$R/pf-gone1.log" 2>&1; check "B2b preflight before a new provision-check: cache-16's line is for the OLD valkey -> FAIL (hollow gate)" "[ $? != 0 ] && grep -q 'FAIL  service cache-16: provision-check line is for another valkey' '$R/pf-gone1.log'"
bash "$M" provision-check --wave 1 --run "$R" > "$R/pc-b.log" 2>&1
check "B2c provision-check --wave 1 replaced wave 1's 4 lines and KEPT wave 2's 8 (merge), checked_at column filled" "[ $(awk -F'\t' 'NR>1 && $1==1' "$R/provision-check.tsv" | wc -l | tr -d ' ') = 4 ] && [ $(awk -F'\t' 'NR>1 && $1==2' "$R/provision-check.tsv" | wc -l | tr -d ' ') = 8 ] && [ $(awk -F'\t' 'NR>1 && $14 ~ /^20[0-9][0-9]-/' "$R/provision-check.tsv" | wc -l | tr -d ' ') = 12 ]"
bash "$M" preflight --wave 1 --run "$R" > "$R/pf-gone2.log" 2>&1; check "B3 preflight OK again" "grep -q '^PREFLIGHT: OK' '$R/pf-gone2.log' && [ $(grep -c 'provision-check OK, BOSH deployment present' "$R/pf-gone2.log") = 4 ]"
check "B4 inventory still staged for cache-16 (new guid)" "grep -q $'cache-16-valkey-staged\t'\"$(ledger "select(.service==\"$G16\" and .step==\"create-valkey\" and .outcome==\"ok\") | .note" | tail -1 | grep -oE '[0-9a-f-]{36}' | head -1)\"$'\tcache-small\tstaged' '$R/inventory.tsv'"

echo "== C: apply wave 1 on staged valkeys: rename-standby, rename-valkey, name-sync both, apps migrated"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply1.log" 2>&1; check "C1 apply wave 1 exits 0" "[ $? = 0 ]"
check "C2 4 rename-standby ok, 4 rename-valkey ok, 0 day-of creates in wave 1" "[ $(nev rename-standby ok) = 4 ] && [ $(nev rename-valkey ok) = 4 ] && [ $(nev create-valkey ok '.wave==1 and (.note|test("\\(staged")|not)') = 0 ]"
check "C3 CF names: redis cache-0 -> cache-0-redis-standby, valkey -> cache-0" "[ \"$(siname $G0)\" = cache-0-redis-standby ] && [ \"$(jq -r '.si[]|select(.name=="cache-0")|.plan' "$CFFAKE_STATE")\" = plan-valkey-cache-small ]"
check "C4 8 name-sync ok (4 redis + 4 valkey), values read back" "[ $(nev name-sync ok) = 8 ] && [ \"$(cat "$SAFEFAKE_STATE/$G0")\" = cache-0-redis-standby ] && [ \"$(cat "$SAFEFAKE_STATE/$(jq -r '.si|to_entries[]|select(.value.name=="cache-0" and .value.plan=="plan-valkey-cache-small")|.key' "$CFFAKE_STATE")")\" = cache-0 ]"
check "C5 4 apps verified" "[ $(nev verify ok) = 4 ]"
check "C6 inventory: wave 1 cut-over with the real names, wave 2 still staged" "[ $(awk -F'\t' 'NR>1 && $1==1 && $11=="cut-over" && $8==$6 && $6=="cache-0"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 0 ] && [ $(awk -F'\t' 'NR>1 && $1==1 && $11=="cut-over" && $8=="cache-0" && $6=="cache-0-redis-standby"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 1 ] && [ $(awk -F'\t' 'NR>1 && $1==2 && $11=="staged"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 8 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status1b.log" 2>&1
check "C7 status wave 1: 4 VERIFIED, no name-sync footer" "[ $(grep -c ' VERIFIED ' "$R/status1b.log") = 4 ] && ! grep -q 'name-sync pending' '$R/status1b.log'"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply1b.log" 2>&1; check "C8 apply wave 1 again: idempotent (no new rename/create events)" "[ $? = 0 ] && [ $(nev rename-valkey ok) = 4 ] && [ $(nev rename-standby ok) = 4 ]"
check "C9 name-sync-wave-1.sh holds the 8 safe commands" "[ $(grep -c '^safe set secret/' "$R/name-sync-wave-1.sh") = 8 ]"

echo "== D: wave 2 -- crash after the staged PATCH (no ledger line), and a name-sync failure"
# cache-3: the operator's previous run renamed redis + patched the staged valkey, then died before writing rename-valkey
VK3=$(ledger "select(.service==\"$G3\" and .step==\"create-valkey\" and .outcome==\"ok\") | .note" | grep -oE '[0-9a-f-]{36}' | head -1)
"$CF_CMD" curl "/v3/service_instances/$G3" -X PATCH -d '{"name":"cache-3-redis-standby"}' > /dev/null
"$CF_CMD" curl "/v3/service_instances/$VK3" -X PATCH -d '{"name":"cache-3"}' > /dev/null
printf '{"ts":"2026-10-18T00:00:00Z","wave":2,"service":"%s","app":"","step":"rename-standby","outcome":"ok","ms":0,"op":"test","note":"cache-3 -> cache-3-redis-standby"}\n' "$G3" >> "$R/ledger.jsonl"
SAFEFAKE_FAIL=$G4 bash "$M" apply --wave 2 --yes --run "$R" > "$R/apply2.log" 2>&1; check "D1 apply wave 2 exits 0" "[ $? = 0 ]"
check "D2 cache-3: rename-valkey ok 'found already renamed', no PATCH on it" "[ $(nev rename-valkey ok ".service==\"$G3\" and (.note|test(\"already renamed\"))") = 1 ] && [ $(grep -c "PATCH	/v3/service_instances/$VK3" "$R/commands.log") = 0 ]"
check "D3 cache-4: name-sync fail on the redis rename, ok on the valkey" "[ $(nev name-sync fail ".service==\"$G4\" and (.note|startswith(\"$G4 \"))") = 1 ] && [ $(nev name-sync ok ".service==\"$G4\"") = 1 ]"
bash "$M" status --wave 2 --run "$R" > "$R/status2.log" 2>&1
check "D4 status wave 2: footer 'name-sync pending: 2' (cache-4 failed + cache-3's hand-added rename with no sync event; review finding 3), all 8 VERIFIED" "grep -q 'name-sync pending: 2 ' '$R/status2.log' && [ $(grep -c ' VERIFIED ' "$R/status2.log") = 8 ]"
bash "$M" name-sync --wave 2 --run "$R" > "$R/ns2.log" 2>&1; check "D5 name-sync --wave 2: 14 in sync, 2 set now (cache-4 redis after the failure; cache-3 redis whose ledger line was hand-added without a sync)" "[ $? = 0 ] && grep -q 'name-sync: 14 in sync, 2 set now, 0 failed; still pending: 0' '$R/ns2.log'"
check "D6 the fixed value is in Blacksmith's (fake) vault" "[ \"$(cat "$SAFEFAKE_STATE/$G4")\" = cache-4-redis-standby ]"
bash "$M" status --run "$R" > "$R/summary.log" 2>&1
check "D7 summary: 12 created, 12 verified, inventory all cut-over" "grep -q '^TOTAL *12 *12 ' '$R/summary.log' && [ $(awk -F'\t' 'NR>1 && $11=="cut-over"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 12 ]"

echo "== E: orphan staged valkey (fresh ledger, instances already there) -> preflight FAIL, provision adopts"
newrun E; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; rm -f "$R/ledger.jsonl" "$R/inventory.tsv"
bash "$M" preflight --wave 1 --run "$R" > "$R/pf.log" 2>&1; check "E1 preflight FAILs: staged exists but ledger has no create-valkey" "[ $? != 0 ] && [ $(grep -c 'but the ledger has no create-valkey' "$R/pf.log") = 4 ]"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; check "E2 provision adopts the 4 (no new instances)" "[ $(nev create-valkey ok '(.note|test("adopted"))') = 4 ] && [ $(jq '[.si[]|select(.name|endswith("-valkey-staged"))]|length' "$CFFAKE_STATE") = 4 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1; check "E3 adopted staged valkeys show STAGED, inventory staged (review finding 1)" "[ $(grep -c ' STAGED ' "$R/status.log") = 4 ] && [ $(awk -F'\t' 'NR>1 && $11=="staged"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 4 ]"
bash "$M" preflight --wave 1 --free-ips 0 --run "$R" > "$R/pf-g1.log" 2>&1; check "E3b hollow gate: preflight without any provision-check -> 4 FAIL 'no provision-check line', verdict FAIL" "[ $? != 0 ] && [ $(grep -c 'FAIL  service cache-.*: no provision-check line' "$R/pf-g1.log") = 4 ] && ! grep -q '^PREFLIGHT: OK' '$R/pf-g1.log'"
bash "$M" provision-check --wave 1 --no-bosh --run "$R" > /dev/null 2>&1; bash "$M" preflight --wave 1 --free-ips 0 --run "$R" > "$R/pf-g2.log" 2>&1
check "E3c a --no-bosh provision-check does not pass the gate (bosh=skipped)" "[ $? != 0 ] && [ $(grep -c 'did not see a BOSH deployment .* (bosh=skipped)' "$R/pf-g2.log") = 4 ]"
bash "$M" provision-check --wave 1 --run "$R" > /dev/null 2>&1; sed -i.bak 's/\t20[0-9][0-9]-[^\t]*$/\t2020-01-01T00:00:00Z/' "$R/provision-check.tsv"; bash "$M" preflight --wave 1 --free-ips 0 --run "$R" > "$R/pf-g3.log" 2>&1
check "E3d a provision-check older than the valkey's create does not pass the gate" "[ $? != 0 ] && [ $(grep -c 'is older than the valkey.s create' "$R/pf-g3.log") = 4 ]"
bash "$M" provision-check --wave 1 --run "$R" > /dev/null 2>&1
bash "$M" preflight --wave 1 --free-ips 0 --run "$R" > "$R/pf2.log" 2>&1; check "E4 preflight: 0 IPs needed for a staged wave, passes with --free-ips 0 (review finding 2)" "[ $? = 0 ] && grep -q '0 Valkey(s) still to create (IPs needed: 0; 4 already' '$R/pf2.log'"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "E5 apply renames the adopted staged valkeys: 4 rename-valkey ok, CF names right, 8 name-sync ok" "[ $? = 0 ] && [ $(nev rename-valkey ok) = 4 ] && [ \"$(siname $G0)\" = cache-0-redis-standby ] && [ $(jq '[.si[]|select(.name=="cache-0")]|length' "$CFFAKE_STATE") = 1 ] && [ $(nev name-sync ok) = 8 ]"

echo "== F: no vault.conf -> name-sync skipped, script written; day-of apply without provision unchanged"
newrun F; rm -f "$R/vault.conf"
bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; bash "$M" provision-check --wave 1 --run "$R" > /dev/null 2>&1
"$CF_CMD" curl "/v3/service_instances/$G0" -X PATCH -d '{"name":"cache-0-redis-standby"}' > /dev/null   # a run died after this PATCH, before its ledger line
bash "$M" preflight --wave 1 --run "$R" > "$R/pf.log" 2>&1; check "F0 redis already under the standby name, no ledger line: preflight PASSes it as 'renamed by a run that died', not drift" "[ $? = 0 ] && grep -q 'PASS  service cache-0: already carries the standby name' '$R/pf.log' && ! grep -q 'already exists in the space' '$R/pf.log'"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "F1 apply exits 0 without vault.conf" "[ $? = 0 ]"
check "F1b cache-0: rename-standby ok 'found already renamed', no PATCH on it, migrated" "[ $(nev rename-standby ok ".service==\"$G0\" and (.note|test(\"found already renamed\"))") = 1 ] && [ $(grep -c "PATCH	/v3/service_instances/$G0" "$R/commands.log") = 0 ] && [ $(nev verify ok ".service==\"$G0\"") = 1 ]"
check "F2 8 name-sync skipped, 8 commands in name-sync-wave-1.sh" "[ $(nev name-sync skipped) = 8 ] && [ $(grep -c '^safe set' "$R/name-sync-wave-1.sh") = 8 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1; check "F3 status footer: name-sync pending: 8" "grep -q 'name-sync pending: 8 ' '$R/status.log'"
bash "$M" name-sync --wave 1 --run "$R" > "$R/ns.log" 2>&1; check "F4 name-sync without vault.conf refuses with a hint" "[ $? != 0 ] && grep -q 'no SAFE_RUN' '$R/ns.log'"
newrun G; bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
check "G1 day-of apply: 4 creates under the real name, no rename-valkey, inventory cut-over" "[ $(nev create-valkey ok '(.note|test("\\(staged")|not)') = 4 ] && [ $(nev rename-valkey ok) = 0 ] && [ $(awk -F'\t' 'NR>1 && $1==1 && $11=="cut-over"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 4 ] && [ $(nev verify ok) = 4 ]"

echo "== I: SAFE_RUN reaches the wrong Vault -> name-sync pre-check fails, nothing written (review finding 5)"
newrun I; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; bash "$M" provision-check --wave 1 --run "$R" > /dev/null 2>&1
SAFEFAKE_STATE="$R/other-vault" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "I1 apply still exits 0" "[ $? = 0 ]"
check "I2 8 name-sync fail with 'pre-check', nothing in the other vault, right vault untouched" "[ $(nev name-sync fail '(.note|test("pre-check"))') = 8 ] && [ ! -d "$R/other-vault" -o $(ls "$R/other-vault" 2>/dev/null | wc -l | tr -d ' ') = 0 ] && [ \"$(cat "$SAFEFAKE_STATE/$G0")\" = cache-0 ]"
bash "$M" name-sync --wave 1 --run "$R" > "$R/ns.log" 2>&1; check "I3 name-sync with the right vault: 0 in sync, 8 set now" "[ $? = 0 ] && grep -q 'name-sync: 0 in sync, 8 set now, 0 failed; still pending: 0' '$R/ns.log' && [ \"$(cat "$SAFEFAKE_STATE/$G0")\" = cache-0-redis-standby ]"

echo "== H: a staged create fails -> inventory create-failed; next provision deletes the corpse and creates again"
newrun H; CFFAKE_FAIL_CREATE=cache-22-valkey-staged bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov1.log" 2>&1
check "H1 1 create-valkey fail, inventory shows create-failed for cache-22" "[ $(nev create-valkey fail) = 1 ] && grep -q $'cache-22\t[^\t]*\t-\t-\tcache-small\tcreate-failed' '$R/inventory.tsv'"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov2.log" 2>&1
check "H2 re-run: corpse deleted, new staged valkey ok, 4 staged in CF" "[ $(nev create-valkey ok '(.note|test("deleted failed leftover"))') = 1 ] && [ $(jq '[.si[]|select((.name|endswith("-valkey-staged")) and .last_op.state=="succeeded")]|length' "$CFFAKE_STATE") = 4 ]"
check "H3 svc_note_guid picks the NEW valkey, not the deleted corpse" "[ \"$(jq -r '.si|to_entries[]|select(.value.name=="cache-22-valkey-staged")|.key' "$CFFAKE_STATE")\" = \"$(ledger 'select(.step=="create-valkey" and .outcome=="ok" and (.note|test("deleted failed leftover"))) | .note' | grep -oE '[0-9a-f-]{36}' | head -1)\" ]"

echo "== J: provision-check (read-only): same space/org, same plan name, last op; missing / mismatch / killed run"
newrun J; bash "$M" provision --waves 1-2 --yes --run "$R" > /dev/null 2>&1
bash "$M" provision-check --run "$R" > "$R/pc1.log" 2>&1; check "J1 all 12 OK, verdict OK, tsv: 12 lines with org/space, both plans cache-small, offering valkey" "[ $? = 0 ] && grep -q 'PROVISION-CHECK: OK (12 of 12 ok: 12 staged, 0 cut-over; 0 missing, 0 mismatched, 0 hollow, 0 api-errors; bosh: 12 of 12 valkeys have a deployment)' '$R/pc1.log' && [ $(awk -F'\t' 'NR>1 && $11=="OK" && $7=="cache-small" && $8=="cache-small" && $9=="valkey" && $5!="" && $6!=""' "$R/provision-check.tsv" | wc -l | tr -d ' ') = 12 ]"
CFFAKE_WRONG=cache-0-valkey-staged:space bash "$M" provision-check --wave 1 --run "$R" > "$R/pc2.log" 2>&1; check "J2 valkey in another space -> MISMATCH, verdict FAIL, exit 1" "[ $? = 1 ] && grep -q '^MISMATCH wave 1 *cache-0 .*space differs' '$R/pc2.log' && grep -q 'PROVISION-CHECK: FAIL (3 of 4 ok, 0 missing, 1 mismatched, 0 hollow, 0 api-errors; bosh: 4 of 4 valkeys have a deployment)' '$R/pc2.log'"
CFFAKE_WRONG=cache-0-valkey-staged:plan bash "$M" provision-check --wave 1 --run "$R" > "$R/pc3.log" 2>&1; check "J3 valkey on another plan -> MISMATCH naming both plans" "[ $? = 1 ] && grep -q \"plan name 'cache-other' != redis plan 'cache-small'\" '$R/pc3.log'"
check "J4 provision-check wrote nothing to the ledger" "[ $(nev create-valkey ok) = 12 ] && [ $(ledger 'select(.step=="drift")' | wc -l | tr -d ' ') = 0 ]"
newrun J2; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1
bash "$M" provision-check --run "$R" > "$R/pc4.log" 2>&1; check "J5 wave 2 not provisioned -> 8 MISSING, verdict FAIL" "[ $? = 1 ] && [ $(grep -c '^MISSING  wave 2 ' "$R/pc4.log") = 8 ] && grep -q 'PROVISION-CHECK: FAIL (4 of 12 ok, 8 missing, 0 mismatched, 0 hollow, 0 api-errors; bosh: 4 of 4 valkeys have a deployment)' '$R/pc4.log'"
CFFAKE_NO_INCLUDED=1 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc6.log" 2>&1; check "J7 plan GET without 'included' (shape not as assumed) -> 4 API-ERROR, never OK" "[ $? = 1 ] && [ $(grep -c '^API-ERROR' "$R/pc6.log") = 4 ] && grep -q 'FAIL (0 of 4 ok, 0 missing, 0 mismatched, 0 hollow, 4 api-errors; bosh: 0 of 0 valkeys have a deployment)' '$R/pc6.log'"
python3 - "$CFFAKE_STATE" "$(ledger "select(.service==\"$G0\" and .step==\"create-valkey\" and .outcome==\"ok\") | .note" | tail -1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)" <<'PY'
import json,sys; f,g=sys.argv[1:]; st=json.load(open(f)); del st['si'][g]; json.dump(st,open(f,'w'))
PY
bash "$M" provision-check --wave 1 --run "$R" > "$R/pc7.log" 2>&1; check "J8 valkey deleted by hand -> MISSING 'gone from CF', verdict FAIL" "[ $? = 1 ] && grep -q '^MISSING  wave 1 *cache-0 .*gone from CF' '$R/pc7.log' && grep -q 'FAIL (3 of 4 ok, 1 missing' '$R/pc7.log'"
bash "$M" apply --wave 2 --yes --run "$R" > /dev/null 2>&1
bash "$M" provision-check --wave 2 --run "$R" > "$R/pc8.log" 2>&1; check "J9 after apply: cut-over valkeys carry <name>, verdict counts them as cut-over" "[ $? = 0 ] && grep -q 'OK (8 of 8 ok: 0 staged, 8 cut-over;' '$R/pc8.log'"
newrun J4; CFFAKE_FAIL_CREATE=cache-22-valkey-staged bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1
bash "$M" provision-status --run "$R" > "$R/ps1.log" 2>&1; check "J10 provision-status: wave 1 = 4 services, 3 staged, 1 create-failed; wave 2 = 8 not-provisioned; TOTAL 12; 'still without' hint" "[ $? = 0 ] && grep -qE '^1 +4 +3 +0 +1 +0 +0' '$R/ps1.log' && grep -qE '^2 +8 +0 +0 +0 +8 +0' '$R/ps1.log' && grep -qE '^TOTAL +12 +3 +0 +1 +8 +0' '$R/ps1.log' && grep -q '^9 service(s) still without' '$R/ps1.log' && [ \"$(grep -E '^[0-9]+ +[0-9]+ ' "$R/ps1.log" | cut -d' ' -f1 | paste -sd, -)\" = 1,2 ]"
bash "$M" provision-status --wave 1 --run "$R" > "$R/ps2.log" 2>&1; check "J11 provision-status --wave 1 lists the 4 services with state and note" "[ $(grep -cE '^  (staged|create-failed) +cache-' "$R/ps2.log") = 4 ] && grep -qE '^  create-failed +cache-22 .*provision failed' '$R/ps2.log'"
bash "$M" provision --waves 1-2 --yes --run "$R" > /dev/null 2>&1; bash "$M" provision-status --run "$R" > "$R/ps3.log" 2>&1; check "J12 after the re-run: all 12 provisioned, hint points to provision-check" "grep -qE '^TOTAL +12 +12 +0 +0 +0 +0' '$R/ps3.log' && grep -q '^all 12 services provisioned -- next: provision-check' '$R/ps3.log'"
newrun J3; CFFAKE_CREATE_POLLS=50 JOB_POLL=1 bash "$M" provision --wave 1 --yes --run "$R" > "$R/pc5.log" 2>&1 & pid=$!; sleep 4; kill -TERM $pid; wait $pid 2>/dev/null
check "J6 provision killed mid-wave: inventory.tsv written by the EXIT trap, counts line printed" "[ -s '$R/inventory.tsv' ] && grep -q '^inventory: 12 services -- staged ' '$R/pc5.log' && [ $(awk -F'\t' 'NR>1 && $1==1 && $11=="not-provisioned"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 4 ]"
bash "$M" provision-check --wave 1 --run "$R" > "$R/pc9.log" 2>&1; check "J6b right after the kill: the 4 in-flight creates are reported as MISSING with the in-progress instance named (review: partial state)" "[ $? = 1 ] && [ $(grep -c "^MISSING  wave 1 .*carries '.*-valkey-staged' (.*create in progress) -- provision adopts" "$R/pc9.log") = 4 ]"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/pc10.log" 2>&1; check "J6c re-run while still in progress: 4 create-valkey fail 'not ours to touch' (refused, not adopted)" "[ $(nev create-valkey fail '(.note|test("in progress"))') = 4 ]"
CFFAKE_FINISH_JOBS=1 bash "$M" provision --wave 1 --yes --run "$R" > "$R/pc11.log" 2>&1; bash "$M" provision-check --wave 1 --run "$R" > "$R/pc12.log" 2>&1
check "J6d re-run once the broker finished the creates: adopted ('already existed'), provision-check OK 4 of 4" "[ $? = 0 ] && grep -q 'OK (4 of 4 ok: 4 staged' '$R/pc12.log' && [ $(nev create-valkey ok '(.note|test("adopted"))') = 4 ]"

echo "== S: creates reach the broker one at a time (each leaves 'initial' before the next POST); the builds still overlap"
ov(){ jq -r '.overlap // 0' "$CFFAKE_STATE"; }   # POSTs made while another create was still 'initial' (what Blacksmith would see together)
newrun S
CFFAKE_INITIAL_POLLS=2 bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; rc=$?
check "S1 4 created, exit 0, overlap 0, 4 'broker accepted' lines, the note carries the wait" "[ $rc = 0 ] && [ $(nev create-valkey ok) = 4 ] && [ $(ov) = 0 ] && [ $(grep -c 'broker accepted the create' "$R/prov.log") = 4 ] && [ $(nev create-valkey ok '(.note|test("broker accepted after"))') = 4 ]"
newrun S2   # the broker never answers the first create: nothing else is issued in this RUN (wave 2 untouched); the issued one is still waited for
CFFAKE_INITIAL_POLLS=99 ACCEPT_TIMEOUT=0 bash "$M" provision --waves 1-2 --yes --run "$R" > "$R/prov.log" 2>&1; rc=$?
check "S2 first create not accepted in time: 1 created (its job waited for), 3 'not issued', wave 2 not started, exit 1, overlap 0, said out loud" "[ $rc = 1 ] && [ $(nev create-valkey ok) = 1 ] && [ $(nev create-valkey fail '(.note|test("not issued: create of .* still"))') = 3 ] && [ $(ledger 'select(.wave==2)' | wc -l | tr -d ' ') = 0 ] && [ $(ov) = 0 ] && grep -q 'no further create issued' '$R/prov.log' && grep -q 'stopped at wave 1' '$R/prov.log'"
bash "$M" provision --waves 1-2 --yes --run "$R" > "$R/prov2.log" 2>&1; rc=$?
check "S3 re-run creates the other 11: 12 staged, exit 0, overlap still 0" "[ $rc = 0 ] && [ $(nev create-valkey ok) = 12 ] && [ $(ov) = 0 ]"
newrun S4   # a create the broker refuses does not hold the others back
CFFAKE_FAIL_CREATE=cache-0-valkey-staged bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1
check "S4 one create fails: the other 3 still issued one after the other, 3 ok + 1 fail, overlap 0" "[ $(nev create-valkey ok) = 3 ] && [ $(nev create-valkey fail) = 1 ] && [ $(ov) = 0 ]"

echo "== Q: provision-check's BOSH half: hollow valkey, bosh listing failure, no BOSH_CMD, bosh.conf, --no-bosh, empty director"
newrun Q; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1
CFFAKE_HOLLOW=cache-0 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc.log" 2>&1; rc=$?
check "Q1 CF says succeeded, BOSH has no deployment -> HOLLOW with the purge command, verdict FAIL 1 hollow, exit 1, tsv bosh=none" "[ $rc = 1 ] && grep -q '^HOLLOW   wave 1 *cache-0 .*purge=true' '$R/pc.log' && grep -q 'PROVISION-CHECK: FAIL (3 of 4 ok, 0 missing, 0 mismatched, 1 hollow, 0 api-errors; bosh: 3 of 4 valkeys have a deployment)' '$R/pc.log' && [ \"$(awk -F'\t' -v n=cache-0 'NR>1 && $2==n {print $13}' "$R/provision-check.tsv")\" = none ]"
BOSHFAKE_BAD=1 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc2.log" 2>&1; rc=$?
check "Q2 bosh listing fails -> said once, every service API-ERROR, verdict FAIL, never a pass" "[ $rc = 1 ] && grep -q '^!! bosh: .*failed' '$R/pc2.log' && [ $(grep -c '^API-ERROR wave 1 ' "$R/pc2.log") = 4 ] && grep -q 'bosh: listing FAILED)' '$R/pc2.log'"
BOSH_CMD= bash "$M" provision-check --wave 1 --run "$R" > "$R/pc3.log" 2>&1; rc=$?
check "Q3 no BOSH_CMD and no bosh.conf -> refused before the walk, exit 1" "[ $rc = 1 ] && grep -q 'provision-check needs BOSH' '$R/pc3.log' && ! grep -q '^OK ' '$R/pc3.log'"
printf 'BOSH_CMD="%s"\n' "$BOSH_CMD" > "$R/bosh.conf"; BOSH_CMD= bash "$M" provision-check --wave 1 --run "$R" > "$R/pc4.log" 2>&1; rc=$?
check "Q4 BOSH_CMD from bosh.conf -> OK 4 of 4, bosh 4 present" "[ $rc = 0 ] && grep -q 'OK (4 of 4 ok: 4 staged, 0 cut-over; 0 missing, 0 mismatched, 0 hollow, 0 api-errors; bosh: 4 of 4 valkeys have a deployment)' '$R/pc4.log'"
rm "$R/bosh.conf"; BOSH_CMD= bash "$M" provision-check --wave 1 --no-bosh --run "$R" > "$R/pc5.log" 2>&1; rc=$?
check "Q5 --no-bosh: CF only, verdict says NOT CHECKED, tsv bosh=skipped" "[ $rc = 0 ] && grep -q 'bosh: NOT CHECKED (--no-bosh))' '$R/pc5.log' && [ $(awk -F'\t' -v v=skipped 'NR>1 && $13==v' "$R/provision-check.tsv" | wc -l | tr -d ' ') = 4 ]"
BOSHFAKE_EMPTY=1 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc6.log" 2>&1; rc=$?
check "Q6 director lists no deployment at all -> refused as the wrong director, every service API-ERROR, FAIL" "[ $rc = 1 ] && grep -q 'wrong director' '$R/pc6.log' && [ $(grep -c '^API-ERROR wave 1 ' "$R/pc6.log") = 4 ]"
BOSHFAKE_NOREDIS=1 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc7.log" 2>&1; rc=$?
check "Q7 a non-empty listing without the plan's Redis (the env's own director) -> wrong director, API-ERROR, no HOLLOW, no purge advice" "[ $rc = 1 ] && grep -q 'none of the plan.s 4 Redis -- wrong director' '$R/pc7.log' && [ $(grep -c '^API-ERROR wave 1 ' "$R/pc7.log") = 4 ] && ! grep -q 'HOLLOW\|purge=true' '$R/pc7.log'"
# Q8/Q9: the listing runs under timeout(1) on Linux. bosh-fake refuses (exit 97) when it is outside the terminal's
# foreground process group -- where a timeout without --foreground puts it and where the real genesis (script(1) ->
# raw mode) is STOPPED by SIGTTOU (SBX, 2026-10-21). That check only arms with a controlling terminal, so this
# harness says whether it was armed; `script -q /dev/null bash migrate/test/case-provision.sh` arms it anywhere.
tpg=$(ps -o tpgid= -p $$ | tr -d ' '); case "$tpg" in ''|-1|0) ttyarm="NOT armed (no controlling terminal)";; *) ttyarm=armed;; esac
if command -v timeout >/dev/null 2>&1 && timeout --foreground 1 true 2>/dev/null; then
  BOSHFAKE_HANG=1 BOSH_TIMEOUT=1 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc8.log" 2>&1; rc=$?
  sleep 1; left=$(pgrep -g "$(ps -o pgid= -p $$ | tr -d ' ')" -f 'deployments --json' | wc -l | tr -d ' ')
  check "Q8 director gives no answer -> wrapper killed after BOSH_TIMEOUT AND its hung child ended (none left in our process group), said as such, every service API-ERROR, FAIL (foreground-group check $ttyarm)" "[ $rc = 1 ] && grep -q 'gave no answer within 1s (wrapper killed' '$R/pc8.log' && [ $(grep -c '^API-ERROR wave 1 ' "$R/pc8.log") = 4 ] && [ $left = 0 ]"
  bash "$M" provision-check --wave 1 --run "$R" > "$R/pc9.log" 2>&1; rc=$?
  check "Q9 under timeout(1) the listing still runs in the foreground process group -> OK 4 of 4 (foreground-group check $ttyarm)" "[ $rc = 0 ] && grep -q 'bosh: 4 of 4 valkeys have a deployment' '$R/pc9.log' && ! grep -q 'foreground process group' '$R/pc9.log'"
else pass "Q8/Q9 skipped: no timeout(1) with --foreground on this box (macOS) -- the listing runs unbounded here"; fi
BOSHFAKE_NOAUTH=1 bash "$M" provision-check --wave 1 --run "$R" > "$R/pc10.log" 2>&1; rc=$?
check "Q10 no valid vault session (genesis cannot prompt, stdout captured) -> said with the remedy, not the method list; every service API-ERROR, FAIL" "[ $rc = 1 ] && grep -q \"no valid vault session, and genesis cannot ask for the login while its output is captured -- run '.*bosh-fake env' once in this shell\" '$R/pc10.log' && ! grep -q 'VAULT_GITHUB_TOKEN' '$R/pc10.log' && [ $(grep -c '^API-ERROR wave 1 ' "$R/pc10.log") = 4 ]"

# Q11: Ctrl-C at the "type yes" question. The question is read in a $(ask) subshell where SIGINT is back at its
# default, so Ctrl-C -- which the terminal sends to the whole foreground group: main shell AND subshell -- ends
# it; the main shell's flag trap is deferred while it waits for the subshell and runs once after. With the read
# in the main shell (before 2026-10-22) the trap ran and bash restarted the read: a line per Ctrl-C, never an end.
# Three things this case had to get right (each hid the bug on the old code in a first version): apply gets its
# own pty (script(1), util-linux `-c` or BSD form) whose input is held open -- a pty at EOF answers every read at
# once, question over, no Ctrl-C needed; apply runs in the harness's FOREGROUND -- an async job (`&`) of a
# non-interactive bash has SIGINT ignored, and a shell that enters with it ignored cannot trap it, so nothing
# would react; the signal goes by command line (pkill -f, anchored so the pty wrapper is not hit) to every
# process that IS this apply: main shell and its $(ask) subshell, as the terminal would. A watchdog ends an
# unanswered question by force so the old behaviour shows as "took 12 s" instead of hanging the suite.
bash "$M" provision-check --wave 1 --run "$R" > "$R/pc11.log" 2>&1                       # a fresh OK line (Q10 left API-ERRORs)
pat="^bash [^ ]*migrate.sh apply --wave 1 --run $R\$"
( for _ in $(seq 1 50); do grep -q 'type yes' "$R/int.log" 2>/dev/null && break; sleep 0.2; done; sleep 0.3; pkill -INT -f "$pat" ) &
( sleep 12; pkill -9 -f "$pat" ) & wd=$!
t0=$(date +%s)
if script -q -c true /dev/null >/dev/null 2>&1; then script -q -c "bash $M apply --wave 1 --run $R" /dev/null < <(sleep 30) > "$R/int.log" 2>&1
else script -q /dev/null bash "$M" apply --wave 1 --run "$R" < <(sleep 30) > "$R/int.log" 2>&1; fi
dt=$(( $(date +%s)-t0 )); kill $wd 2>/dev/null; wait 2>/dev/null
check "Q11 Ctrl-C at 'Execute wave 1 now? type yes:' (SIGINT to main shell + question subshell, own pty, input held open) ends it: not confirmed within 10 s (took ${dt}s), no wave-start in the ledger, no lock left" \
  "[ $dt -lt 10 ] && grep -q 'type yes: ' '$R/int.log' && grep -q 'not confirmed' '$R/int.log' && ! grep -q '\"step\":\"wave-start\"' '$R/ledger.jsonl' && [ ! -s '$R/wave-1.lock' ]"

echo "== V: an app broken BEFORE its wave (lab 2026-10-22): rebound, not restarted, verified on bindings; partly running on a datastore service refused"
newrun V; export RESTART_TIMEOUT=2
A0=860c4212-e028-4013-ba36-4cab96e5aa45; A16=6e49804f-3e74-4af4-96ec-66293ad0c71e; A22=e541007d-27ff-469c-bee0-1aaec73eb5f1
G22=$(awk -F'\t' '$8=="app-22" {print $4}' "$R/waves.tsv")
restarts(){ jq -r --arg g "$1" '.restarts[$g] // 0' "$CFFAKE_STATE"; }
# cache-22 is a datastore service in this run's plan (the fixture has none); the fake seeds from the plan, flags change nothing in its world
awk -F'\t' -v OFS='\t' '$3=="cache-22" { $12=($12==""?"datastore":$12",datastore") } { print }' "$R/waves.tsv" > "$R/w.tmp" && mv "$R/w.tmp" "$R/waves.tsv"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; bash "$M" provision-check --wave 1 --run "$R" > "$R/pc.log" 2>&1
export CFFAKE_INSTANCES="$A16=2,$A22=2"
CFFAKE_BROKEN="$A16:1,$A22:1" bash "$M" preflight --wave 1 --run "$R" > "$R/pf1.log" 2>&1; rc=$?
check "V1 preflight: app-16 1/2 RUNNING on a cache service -> WARN (rebind only); app-22 1/2 on a DATASTORE service -> FAIL 'fix or cf stop'; verdict FAIL" \
  "[ $rc != 0 ] && grep -q 'WARN  app app-16: 1/2 RUNNING before the wave -- rebind only' '$R/pf1.log' && grep -q \"FAIL  app app-22: only 1/2 instances running on a datastore service -- fix or 'cf stop'\" '$R/pf1.log' && grep -q '^PREFLIGHT: 1 FAIL' '$R/pf1.log'"
CFFAKE_BROKEN="$A16:1,$A22:0" bash "$M" preflight --wave 1 --run "$R" > "$R/pf2.log" 2>&1; rc=$?
check "V2 preflight: app-22 fully down (0/2) on the datastore service -> WARN (nothing left to diverge); PREFLIGHT: OK" \
  "[ $rc = 0 ] && grep -q '^PREFLIGHT: OK' '$R/pf2.log' && grep -q 'WARN  app app-22: 0/2 RUNNING before the wave' '$R/pf2.log' && grep -q 'WARN  app app-16: 1/2 RUNNING before the wave' '$R/pf2.log'"
CFFAKE_BROKEN="$A16:1,$A22:1" bash "$M" dry-run --wave 1 --run "$R" > "$R/dry.log" 2>&1
check "V3 dry-run says it: app-16 restart SKIPPED (1/2 RUNNING, rebind only), verify on bindings; app-22 flagged PARTLY running on a DATASTORE service" \
  "grep -q 'app-16.*state=STARTED (1/2 RUNNING)' '$R/dry.log' && [ $(grep -c 'restart SKIPPED: app is 1/2 RUNNING before the wave -- rebind only' "$R/dry.log") = 2 ] && grep -q 'verify app-16: L1 bindings = valkey only, state still 1/2 RUNNING (L2' '$R/dry.log' && [ $(grep -c 'PARTLY running on a DATASTORE service: apply refuses it' "$R/dry.log") = 1 ]"
export CFFAKE_BROKEN="$A16:1,$A22:0"; printf 'exit 0\n' > "$R/copy-data.sh"   # the datastore service needs a copy-data hook (or a terminal)
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "V4 apply exits 0: both broken apps rebound (bind-valkey + unbind-redis ok), 'restart ok skipped: app was r/n RUNNING before the wave', 'verify ok (bindings only)'; the 2 healthy apps verified as usual; no rollback" \
  "[ $rc = 0 ] && [ $(nev bind-valkey ok "(.app==\"$A16\" or .app==\"$A22\")") = 2 ] && [ $(nev unbind-redis ok "(.app==\"$A16\" or .app==\"$A22\")") = 2 ] && [ $(nev restart ok ".app==\"$A16\" and (.note|test(\"^skipped: app was 1/2 RUNNING before the wave\"))") = 1 ] && [ $(nev restart ok ".app==\"$A22\" and (.note|test(\"^skipped: app was 0/2 RUNNING\"))") = 1 ] && [ $(nev verify ok '(.note|test("^L1 ok \\(bindings only: app was [01]/2 RUNNING before the wave\\)$"))') = 2 ] && [ $(nev verify ok) = 4 ] && [ $(nev rollback ok) = 0 ] && [ $(nev rollback fail) = 0 ]"
check "V5 the broken apps were NOT restarted (fake counters 0); app-0 was (1)" "[ $(restarts $A16) = 0 ] && [ $(restarts $A22) = 0 ] && [ $(restarts $A0) = 1 ]"
bash "$M" status --wave 1 --run "$R" > "$R/st.log" 2>&1
check "V6 status: 4 services VERIFIED 1/1; footer: 2 apps rebound but NOT restarted, naming app-16 and app-22 as 'broken before the wave'" \
  "[ $(grep -c ' VERIFIED ' "$R/st.log") = 4 ] && grep -q '^2 app(s) rebound but NOT restarted' '$R/st.log' && grep -q 'app-16 (broken before the wave)' '$R/st.log' && grep -q 'app-22 (broken before the wave)' '$R/st.log'"
# the team fixed app-16 between two runs (all RUNNING now): the ledger's decision holds -- no restart on the re-apply (row 8)
CFFAKE_BROKEN="$A22:0" bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply2.log" 2>&1; rc=$?
check "V7 apply again with app-16 healthy now: idempotent -- no new restart/verify lines, app-16 still not restarted by the tool" "[ $rc = 0 ] && [ $(nev restart ok) = 4 ] && [ $(nev verify ok) = 4 ] && [ $(restarts $A16) = 0 ]"
# rollback of app-16's service while it is still broken: redis rebound, valkey unbound, NO restart (it would only fail); a re-run adds nothing
bash "$M" rollback --wave 1 --service cache-16 --yes --reason drill --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "V8 rollback cache-16 (app-16 still 1/2): rollback ok 'rebind redis + unbind valkey + no restart [broken-before: was 1/2, now 1/2', not restarted, redis binding back" \
  "[ $rc = 0 ] && [ $(nev rollback ok ".app==\"$A16\" and (.note|test(\"rebind redis \\\\+ unbind valkey \\\\+ no restart \\\\[broken-before: was 1/2, now 1/2\"))") = 1 ] && [ $(restarts $A16) = 0 ] && [ $(jq --arg s $G16 --arg a $A16 '[.bind[]|select(.si==$s and .app==$a)]|length' "$CFFAKE_STATE") = 1 ]"
n16=$(nev rollback ok ".app==\"$A16\""); bash "$M" rollback --wave 1 --service cache-16 --yes --reason drill --run "$R" > "$R/rb2.log" 2>&1; rc=$?
check "V9 rollback cache-16 again, app-16 still broken: exit 0, no restart, no new ledger line" "[ $rc = 0 ] && [ $(restarts $A16) = 0 ] && [ $(nev rollback ok ".app==\"$A16\"") = $n16 ]"
# app-22 fixed and started by the team after the wave (all RUNNING now) -> its process may hold the valkey env: the rollback restarts it
unset CFFAKE_BROKEN
bash "$M" rollback --wave 1 --service cache-22 --yes --reason drill --run "$R" > "$R/rb3.log" 2>&1; rc=$?
check "V10 rollback cache-22 with app-22 all RUNNING now: restarted once ('started since, may hold the valkey env'), rollback ok" \
  "[ $rc = 0 ] && [ $(restarts $A22) = 1 ] && grep -q 'app-22: broken before the wave (0/2) but all 2/2 RUNNING now -- started since' '$R/rb3.log' && [ $(nev rollback ok ".app==\"$A22\" and (.note|test(\"\\\\+ restart$\"))") = 1 ]"
unset CFFAKE_INSTANCES

echo "== W: review 2026-10-22 -- rollback FAIL retry, multi-bound app restarted by a neighbour's rollback, half-migrated datastore app"
# W1: a rollback that FAILED (bindings listing down) must not erase the broken decision: the retry does not restart the app
newrun W1; export CFFAKE_INSTANCES="$A16=2"; export CFFAKE_BROKEN="$A16:1"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; bash "$M" provision-check --wave 1 --run "$R" > "$R/pc.log" 2>&1
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
CFFAKE_FAIL_GET=/v3/service_credential_bindings bash "$M" rollback --wave 1 --service cache-16 --yes --reason drill --run "$R" > "$R/rb1.log" 2>&1; rc=$?
check "W1a rollback cache-16 with the bindings listing failing: rollback fail, exit 1, app-16 not restarted" "[ $rc != 0 ] && [ $(nev rollback fail ".app==\"$A16\"") = 1 ] && [ $(restarts $A16) = 0 ]"
bash "$M" rollback --wave 1 --service cache-16 --yes --reason drill --run "$R" > "$R/rb2.log" 2>&1; rc=$?
check "W1b retry (API fine): rollback ok 'no restart [broken-before: was 1/2, now 1/2', app-16 still not restarted, redis binding back" \
  "[ $rc = 0 ] && [ $(nev rollback ok ".app==\"$A16\" and (.note|test(\"no restart \\\\[broken-before: was 1/2, now 1/2\"))") = 1 ] && [ $(restarts $A16) = 0 ] && [ $(jq --arg s $G16 --arg a $A16 '[.bind[]|select(.si==$s and .app==$a)]|length' "$CFFAKE_STATE") = 1 ]"
# W2: app-16 bound to cache-16 AND cache-22, 0/2 at the wave (both pairs 'skipped'); the team starts it; rollback of cache-22 restarts it
#     (process now on cache-22's REDIS env); the re-apply for cache-22 must RESTART it (verify on RUNNING), not reuse cache-16's stale 'broken 0/2'
newrun W2; export CFFAKE_INSTANCES="$A16=2"; export CFFAKE_BROKEN="$A16:0"
awk -F'\t' -v OFS='\t' '$8=="app-22" { r=$0; $8="app-16"; $9="'"$A16"'"; print r; print; next } { print }' "$R/waves.tsv" > "$R/w.tmp" && mv "$R/w.tmp" "$R/waves.tsv"
"$CF_CMD" seed "$R/waves.tsv" > /dev/null   # re-seed: the extra binding
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; bash "$M" provision-check --wave 1 --run "$R" > "$R/pc.log" 2>&1
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "W2a apply: app-16 rebound for both services, one skipped-restart line per pair (0/2), not restarted" "[ $rc = 0 ] && [ $(nev restart ok ".app==\"$A16\" and (.note|test(\"^skipped: app was 0/2\"))") = 2 ] && [ $(restarts $A16) = 0 ]"
unset CFFAKE_BROKEN   # the team fixed and started it: 2/2 RUNNING
bash "$M" rollback --wave 1 --service cache-22 --yes --reason drill --run "$R" > "$R/rb.log" 2>&1; rc=$?
check "W2b rollback cache-22: app-16 all RUNNING now -> restarted (1), rollback ok '+ restart'" "[ $rc = 0 ] && [ $(restarts $A16) = 1 ] && [ $(nev rollback ok ".app==\"$A16\" and .service==\"$G22\" and (.note|test(\"\\\\+ restart$\"))") = 1 ]"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply2.log" 2>&1; rc=$?
check "W2c re-apply: cache-22 pair redone WITH a restart (2) and a verify on RUNNING (note 'state STARTED', not 'bindings only'); the one restart is recorded under cache-16 too (real), no new skipped line" \
  "[ $rc = 0 ] && [ $(restarts $A16) = 2 ] && [ $(nev verify ok ".app==\"$A16\" and .service==\"$G22\" and (.note|test(\"^L1 ok \\\\(state STARTED\\\\)$\"))") = 1 ] && [ $(nev restart ok ".app==\"$A16\" and (.note|test(\"^skipped\")|not)") = 2 ] && [ $(nev restart ok ".app==\"$A16\" and (.note|test(\"^skipped\"))") = 2 ]"
# W3: a partly running app on a datastore service whose bind/unbind an earlier run already did (died before the restart line):
#     refused as HALF-MIGRATED (route to rollback), never "nothing changed"
newrun W3; export CFFAKE_INSTANCES="$A22=2"; export CFFAKE_BROKEN="$A22:1"
awk -F'\t' -v OFS='\t' '$3=="cache-22" { $12=($12==""?"datastore":$12",datastore") } { print }' "$R/waves.tsv" > "$R/w.tmp" && mv "$R/w.tmp" "$R/waves.tsv"; printf 'exit 0\n' > "$R/copy-data.sh"
bash "$M" provision --wave 1 --yes --run "$R" > "$R/prov.log" 2>&1; bash "$M" provision-check --wave 1 --run "$R" > "$R/pc.log" 2>&1
for stp in bind-valkey unbind-redis; do jq -nc --arg s "$G22" --arg a "$A22" --arg st "$stp" '{ts:"2026-10-22T00:00:00Z",wave:1,service:$s,app:$a,step:$st,outcome:"ok",ms:1,op:"test",note:""}'; done >> "$R/ledger.jsonl"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; rc=$?
check "W3 apply: app-22 refused with 'HALF-MIGRATED' (drift fail), not 'nothing changed'; not restarted; the other 3 apps verified" \
  "[ $rc = 0 ] && [ $(nev drift fail ".app==\"$A22\" and (.note|test(\"HALF-MIGRATED\"))") = 1 ] && [ $(nev drift fail ".app==\"$A22\" and (.note|test(\"nothing changed\"))") = 0 ] && [ $(restarts $A22) = 0 ] && [ $(nev verify ok) = 3 ]"
unset RESTART_TIMEOUT CFFAKE_INSTANCES CFFAKE_BROKEN

echo "== X: name-check -- roots with no instance_name (client lab 2026-10-22), an absent root, a mismatch, a dead vault session"
newrun X; X=($(awk -F'\t' 'NR>1 && $1==1 && !s[$4]++ {print $4}' "$R/waves.tsv")); XN=($(awk -F'\t' 'NR>1 && $1==1 && !s[$4]++ {print $3}' "$R/waves.tsv"))
: > "$R/safe/${X[1]}"; rm -f "$R/safe/${X[2]}"; echo other-name > "$R/safe/${X[3]}"   # unset, absent, mismatch; X[0] in sync
bash "$M" name-check --wave 1 --run "$R" > "$R/nc1.log" 2>&1; rc=$?
check "X1 name-check (no --fix): exit 1; 1 ok + 3 fail lines (unset / absent / mismatch), summary '1 in sync, 1 unset (0 seeded), 1 mismatch, 1 absent, 0 unanswered'; nothing written" \
  "[ $rc = 1 ] && [ $(nev name-check ok) = 1 ] && [ $(nev name-check fail "(.note|test(\"unset in Blacksmith\"))") = 1 ] && [ $(nev name-check fail "(.note|test(\"no secret at\"))") = 1 ] && [ $(nev name-check fail "(.note|test(\"MISMATCH: broker holds 'other-name'\"))") = 1 ] && grep -q 'name-check wave 1: 4 services -- 1 in sync, 1 unset (0 seeded), 1 mismatch, 1 absent, 0 unanswered' '$R/nc1.log' && [ -z \"\$(cat "$R/safe/${X[1]}")\" ] && [ ! -f "$R/safe/${X[2]}" ] && [ \"\$(cat "$R/safe/${X[3]}")\" = other-name ]"
bash "$M" name-check --fix --wave 1 --run "$R" > "$R/nc2.log" 2>&1; rc=$?
check "X2 name-check --fix: the unset root is seeded with the CF name and read back; the absent root is NOT created; the mismatch untouched; exit 1 (2 still failing)" \
  "[ $rc = 1 ] && [ $(nev name-check ok "(.note|test(\"was unset; seeded, read back\"))") = 1 ] && [ \"\$(cat "$R/safe/${X[1]}")\" = \"${XN[1]}\" ] && [ ! -f "$R/safe/${X[2]}" ] && [ \"\$(cat "$R/safe/${X[3]}")\" = other-name ] && grep -q '1 unset (1 seeded), 1 mismatch, 1 absent' '$R/nc2.log'"
bash "$M" preflight --wave 1 --run "$R" > "$R/pf-x.log" 2>&1
check "X3 preflight after it: WARN for the absent and the mismatched service (reason from the ledger), no 'never checked', verdict still OK" \
  "grep -q '^PREFLIGHT: OK' '$R/pf-x.log' && [ $(grep -c '^WARN  service .*Blacksmith.s copy of the name' "$R/pf-x.log") = 2 ] && grep -q 'MISMATCH' '$R/pf-x.log' && ! grep -q 'never checked\|none of the' '$R/pf-x.log'"
nbefore=$(nev name-check ok); nbefore=$((nbefore + $(nev name-check fail)))
SAFEFAKE_ERR='403 permission denied' bash "$M" name-check --fix --wave 1 --run "$R" > "$R/nc3.log" 2>&1; rc=$?
check "X4 vault session dead (every answer an error): exit 1, 'nothing recorded', no new ledger line, the error text shown" \
  "[ $rc = 1 ] && grep -q 'nothing recorded' '$R/nc3.log' && grep -q '403 permission denied' '$R/nc3.log' && [ $(( $(nev name-check ok) + $(nev name-check fail) )) = $nbefore ]"
bash "$M" name-check --fix --wave 1 --run "$R" > "$R/nc4.log" 2>&1; rc=$?
check "X5 re-run: idempotent -- 2 in sync (the seeded one included), 0 seeded, the same 2 failures" "[ $rc = 1 ] && grep -q 'name-check wave 1: 4 services -- 2 in sync, 0 unset (0 seeded), 1 mismatch, 1 absent, 0 unanswered' '$R/nc4.log'"
newrun X6; : > "$R/safe/${X[1]}"; rm -f "$R/safe/${X[2]}"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply-x.log" 2>&1; rc=$?
check "X6 apply with no name-check: name-sync seeds the unset root with the standby name ('was (unset)'); the absent root still fails the pre-check, nothing written" \
  "[ $rc = 0 ] && [ $(nev name-sync ok ".service==\"${X[1]}\" and (.note|test(\"was '\\\\(unset\\\\)'; read back\"))") = 1 ] && [ \"\$(cat "$R/safe/${X[1]}")\" = \"${XN[1]}-redis-standby\" ] && [ $(nev name-sync fail ".service==\"${X[2]}\" and (.note|test(\"pre-check\"))") = 1 ] && [ ! -f "$R/safe/${X[2]}" ]"
newrun X7; bash "$M" preflight --wave 1 --run "$R" > "$R/pf-x7.log" 2>&1
check "X7 preflight on a run never name-checked: one WARN 'none of the 4 services checked', verdict OK" "grep -q '^PREFLIGHT: OK' '$R/pf-x7.log' && grep -q 'WARN  name-check: none of the 4 services checked' '$R/pf-x7.log'"
echo "== X8-X11: review 2026-10-23 -- name-check after the rename, the VM shell failing, the seed call dying, a lost set"
R="$W/X6"; export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"   # X6: wave 1 applied (rename-standby ok), X[1] seeded by name_sync, X[2] absent
bash "$M" name-check --wave 1 --run "$R" > "$R/nc8.log" 2>&1; rc=$?
check "X8 name-check after apply: the expected name is the STANDBY one (ledger), so 3 in sync (notes carry '-redis-standby (in sync)'), the absent one still absent, no MISMATCH" \
  "[ $rc = 1 ] && grep -q 'name-check wave 1: 4 services -- 3 in sync, 0 unset (0 seeded), 0 mismatch, 1 absent, 0 unanswered' '$R/nc8.log' && [ $(nev name-check ok ".service==\"${X[1]}\" and (.note|test(\"-redis-standby \\\\(in sync\\\\)\"))") = 1 ] && ! grep -q MISMATCH '$R/nc8.log'"
R="$W/X"; export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; nbefore=$(( $(nev name-check ok) + $(nev name-check fail) ))
SAFEFAKE_RAW='bash: safe: command not found' bash "$M" name-check --fix --wave 1 --run "$R" > "$R/nc9.log" 2>&1; rc=$?
check "X9 the VM shell fails identically per service (PATH without safe): a session problem -- exit 1, nothing recorded, never a MISMATCH" \
  "[ $rc = 1 ] && grep -q 'nothing recorded' '$R/nc9.log' && [ $(( $(nev name-check ok) + $(nev name-check fail) )) = $nbefore ] && ! grep -q MISMATCH '$R/nc9.log'"
newrun X10; : > "$R/safe/${X[1]}"
SAFEFAKE_DEAD_ON=set bash "$M" name-check --fix --wave 1 --run "$R" > "$R/nc10.log" 2>&1; rc=$?
check "X10 the seed call dies before bosh ssh: said as 'returned no answer', the service recorded fail 'seed call returned no answer' (never 'seeded'), root still unset, exit 1" \
  "[ $rc = 1 ] && grep -q 'set+read-back call returned no answer' '$R/nc10.log' && [ $(nev name-check fail ".service==\"${X[1]}\" and (.note|test(\"seed call returned no answer\"))") = 1 ] && [ $(nev name-check ok ".service==\"${X[1]}\"") = 0 ] && [ -z \"\$(cat "$R/safe/${X[1]}")\" ] && grep -q '1 unset (0 seeded)' '$R/nc10.log'"
SAFEFAKE_FAIL=${X[1]} bash "$M" name-check --fix --wave 1 --run "$R" > "$R/nc11.log" 2>&1; rc=$?
check "X11 the set is lost on the broker (read-back still 'no key'): fail 'set issued but the read-back did not return it (unset)', exit 1" \
  "[ $rc = 1 ] && [ $(nev name-check fail ".service==\"${X[1]}\" and (.note|test(\"read-back did not return it \\\\(unset\\\\)\"))") = 1 ] && grep -q '1 unset (0 seeded)' '$R/nc11.log'"

echo; [ "$fails" = 0 ] && echo "ALL PASS (workdir $W)" || { echo "$fails FAIL (workdir $W)"; exit 1; }
