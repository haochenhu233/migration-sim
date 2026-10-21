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
bash "$M" preflight --wave 1 --run "$R" > "$R/pf-gone2.log" 2>&1; check "B3 preflight OK again" "grep -q '^PREFLIGHT: OK' '$R/pf-gone2.log'"
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
bash "$M" preflight --wave 1 --free-ips 0 --run "$R" > "$R/pf2.log" 2>&1; check "E4 preflight: 0 IPs needed for a staged wave, passes with --free-ips 0 (review finding 2)" "[ $? = 0 ] && grep -q '0 Valkey(s) still to create (IPs needed: 0; 4 already' '$R/pf2.log'"
bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "E5 apply renames the adopted staged valkeys: 4 rename-valkey ok, CF names right, 8 name-sync ok" "[ $? = 0 ] && [ $(nev rename-valkey ok) = 4 ] && [ \"$(siname $G0)\" = cache-0-redis-standby ] && [ $(jq '[.si[]|select(.name=="cache-0")]|length' "$CFFAKE_STATE") = 1 ] && [ $(nev name-sync ok) = 8 ]"

echo "== F: no vault.conf -> name-sync skipped, script written; day-of apply without provision unchanged"
newrun F; rm -f "$R/vault.conf"
bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1; bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1; check "F1 apply exits 0 without vault.conf" "[ $? = 0 ]"
check "F2 8 name-sync skipped, 8 commands in name-sync-wave-1.sh" "[ $(nev name-sync skipped) = 8 ] && [ $(grep -c '^safe set' "$R/name-sync-wave-1.sh") = 8 ]"
bash "$M" status --wave 1 --run "$R" > "$R/status.log" 2>&1; check "F3 status footer: name-sync pending: 8" "grep -q 'name-sync pending: 8 ' '$R/status.log'"
bash "$M" name-sync --wave 1 --run "$R" > "$R/ns.log" 2>&1; check "F4 name-sync without vault.conf refuses with a hint" "[ $? != 0 ] && grep -q 'no SAFE_RUN' '$R/ns.log'"
newrun G; bash "$M" apply --wave 1 --yes --run "$R" > "$R/apply.log" 2>&1
check "G1 day-of apply: 4 creates under the real name, no rename-valkey, inventory cut-over" "[ $(nev create-valkey ok '(.note|test("\\(staged")|not)') = 4 ] && [ $(nev rename-valkey ok) = 0 ] && [ $(awk -F'\t' 'NR>1 && $1==1 && $11=="cut-over"' "$R/inventory.tsv" | wc -l | tr -d ' ') = 4 ] && [ $(nev verify ok) = 4 ]"

echo "== I: SAFE_RUN reaches the wrong Vault -> name-sync pre-check fails, nothing written (review finding 5)"
newrun I; bash "$M" provision --wave 1 --yes --run "$R" > /dev/null 2>&1
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

echo; [ "$fails" = 0 ] && echo "ALL PASS (workdir $W)" || { echo "$fails FAIL (workdir $W)"; exit 1; }
