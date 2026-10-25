#!/usr/bin/env bash
# case-inflight.sh -- offline cases for provision --max-inflight N (2026-10-25): never more creates alive (issued, not yet
# succeeded/failed) than N, so no deploy task queues on the director into Blacksmith's hourly no-deployment sweep
# (knowledge/blacksmith/hollow-valkey-orphan-sweep.md). The fake records the max number of creates alive at any POST.
# Usage: bash migrate/test/case-inflight.sh [workdir]. PASS/FAIL per check; exit 1 on any FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
export CF_CMD="$HERE/cf-fake" BOSH_CMD="$HERE/bosh-fake" JOB_POLL=0 SOAK=0 MIGRATE_OP=test
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
newrun(){ R="$W/$1"; rm -rf "$R"; mkdir -p "$R"; cp "$HERE/../example/waves.tsv" "$R/"
  export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; "$CF_CMD" seed "$R/waves.tsv" > /dev/null
  printf 'SAFE_RUN="%s"\n' "$HERE/safe-fake" > "$R/vault.conf"; }
maxalive(){ jq -r '.maxinflight // 0' "$CFFAKE_STATE"; }
nok(){ jq -r 'select(.step=="create-valkey" and .outcome=="ok") | .service' "$R/ledger.jsonl" | sort -u | wc -l | tr -d ' '; }
nni(){ jq -r 'select(.step=="create-valkey" and .outcome=="fail" and (.note|startswith("not issued"))) | .service' "$R/ledger.jsonl" | sort -u | wc -l | tr -d ' '; }
# example wave 1 = 4 services, wave 2 = 6; each create needs CFFAKE_CREATE_POLLS job polls to finish

echo "== N: no --max-inflight: every create of the wave is alive at once (today's behaviour, and the counter works)"
newrun N; CFFAKE_CREATE_POLLS=3 bash "$M" provision --wave 1 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "N1 4 creates ok, 4 alive at the last POST" "[ $rc = 0 ] && [ \$(nok) = 4 ] && [ \$(maxalive) = 4 ]"
check "N2 no gate line without the option" "! grep -q 'max-inflight' $R/p.log"

echo "== I: --max-inflight 2 over one wave"
newrun I; CFFAKE_CREATE_POLLS=3 bash "$M" provision --wave 1 --max-inflight 2 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "I1 4 creates ok, never more than 2 alive" "[ $rc = 0 ] && [ \$(nok) = 4 ] && [ \$(maxalive) -le 2 ]"
check "I2 the gate held creates back and says so; CF shows 0 in progress at the end of the wave" "grep -q 'held the next create back [1-9][0-9]* time(s)' $R/p.log && grep -q '; 0 create(s) in progress on the Valkey plans now' $R/p.log"
check "I3 no 'not issued' lines: waiting is not stopping" "[ \$(nni) = 0 ]"

echo "== W: --max-inflight 3 over two waves: the cap holds across the wave boundary"
newrun Wv; CFFAKE_CREATE_POLLS=4 bash "$M" provision --waves 1-2 --max-inflight 3 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
n12=$(awk -F'\t' '$1==1 || $1==2 {print $4}' "$R/waves.tsv" | sort -u | wc -l | tr -d ' ')
check "W1 every create of both waves ok ($n12), never more than 3 alive" "[ $rc = 0 ] && [ \$(nok) = $n12 ] && [ \$(maxalive) -le 3 ]"

echo "== S: a straggler from a killed run (a create in progress this run never issued) counts against the cap"
newrun S; PL=$(jq -r '.plans | to_entries[] | select(.value.offering=="valkey") | .key' "$CFFAKE_STATE" | head -1); SP=$(jq -r '.si | to_entries[0].value.space' "$CFFAKE_STATE")
"$CF_CMD" curl -X POST /v3/service_instances -d "{\"type\":\"managed\",\"name\":\"straggler-valkey-staged\",\"relationships\":{\"space\":{\"data\":{\"guid\":\"$SP\"}},\"service_plan\":{\"data\":{\"guid\":\"$PL\"}}}}" > /dev/null
check "S0 the straggler is in progress before the run" "[ \$(jq -r '[.si[]|select(.name==\"straggler-valkey-staged\" and .last_op.state!=\"succeeded\")]|length' $CFFAKE_STATE) = 1 ]"
CFFAKE_CREATE_POLLS=6 bash "$M" provision --wave 1 --max-inflight 2 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "S1 4 creates ok; straggler included, never more than 2 alive" "[ $rc = 0 ] && [ \$(nok) = 4 ] && [ \$(maxalive) -le 2 ]"
check "S2 the first gate line counted the straggler (1 in progress before any create of this run)" "grep -q 'max-inflight 2: [1-9] create(s) in progress on the Valkey plans -- next create waits' $R/p.log"

echo "== H: STOP file appears while the gate waits on the LAST service of the wave: the wave halts, nothing recorded as ok"
newrun H; CFFAKE_CREATE_POLLS=50 CFFAKE_TOUCH="$R/STOP:4" bash "$M" provision --waves 1-2 --max-inflight 3 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "H1 run stopped at wave 1 (exit 1), 3 creates ok (waited for), the 4th recorded 'not issued: halted'" "[ $rc = 1 ] && grep -q 'stopped at wave 1' $R/p.log && [ \$(nok) = 3 ] && [ \$(nni) = 1 ] && grep -q 'not issued: halted (STOP / Ctrl-C) while waiting in the --max-inflight gate' $R/ledger.jsonl"
check "H2 the wave's provision event says halted after 4 of 4 (1 failed/skipped), not 'provisioned'" "jq -r 'select(.step==\"provision\") | .note' $R/ledger.jsonl | grep -q '^halted after 4 of 4 services (1 failed/skipped)' && grep -q 'wave 1 HALTED after 4 of 4' $R/p.log"
check "H3 wave 2 untouched, no lock left" "[ \$(jq -r 'select(.wave==2)' $R/ledger.jsonl | wc -l | tr -d ' ') = 0 ] && [ ! -s $R/wave-1.lock ] && [ ! -s $R/wave-2.lock ]"
check "H4 after rm STOP, provision again finishes the wave (the 4th service created)" "rm -f $R/STOP && CFFAKE_CREATE_POLLS=2 bash $M provision --wave 1 --max-inflight 3 --yes --run $R > $R/p2.log 2>&1 && [ \$(nok) = 4 ]"

echo "== A: apply (day-of create) halted inside the gate: that service's Redis gets its name back, nothing bound"
newrun A; siname(){ jq -r --arg g "$1" '.si[$g].name' "$CFFAKE_STATE"; }
S1=$(awk -F'\t' '$1==1 {print $4}' "$R/waves.tsv" | awk '!s[$0]++' | sed -n 1p); S3=$(awk -F'\t' '$1==1 {print $4}' "$R/waves.tsv" | awk '!s[$0]++' | sed -n 3p)
N1=$(awk -F'\t' -v g="$S1" '$4==g {print $3; exit}' "$R/waves.tsv"); N3=$(awk -F'\t' -v g="$S3" '$4==g {print $3; exit}' "$R/waves.tsv")
CFFAKE_CREATE_POLLS=50 CFFAKE_TOUCH="$R/STOP:3" bash "$M" apply --wave 1 --max-inflight 2 --yes --run "$R" > "$R/a.log" 2>&1; rc=$?
check "A1 apply stopped (exit 1); two creates issued and waited for, the third 'not issued: halted'" "[ $rc = 1 ] && [ \$(nok) = 2 ] && [ \$(nni) = 1 ]"
check "A2 the halted service's Redis is named back to its plan name; the issued ones keep -redis-standby (resume continues them)" "[ \"\$(siname $S3)\" = \"$N3\" ] && [ \"\$(siname $S1)\" = \"$N1-redis-standby\" ]"
check "A3 no app was bound or restarted" "[ \$(jq -r 'select(.step==\"bind\" or .step==\"restart\") | .app' $R/ledger.jsonl | wc -l | tr -d ' ') = 0 ]"
check "A4 no lock left; after rm STOP, provision-check (the two day-of Valkeys) then apply redoes the halted service" "[ ! -s $R/wave-1.lock ] && rm -f $R/STOP && bash $M provision-check --wave 1 --run $R > $R/pc.log 2>&1; CFFAKE_CREATE_POLLS=2 bash $M apply --wave 1 --max-inflight 4 --yes --run $R > $R/a2.log 2>&1; [ \$(nok) = 4 ]"

echo "== T: the count never drops: the run stops issuing (ISSUE_STOP), nothing issued is abandoned"
newrun T; CFFAKE_CREATE_POLLS=50 INFLIGHT_TIMEOUT=0 bash "$M" provision --wave 1 --max-inflight 1 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "T1 first create issued and finished ok; the other 3 recorded 'not issued' with the reason" "[ \$(nok) = 1 ] && [ \$(nni) = 3 ] && grep -q 'create(s) still in progress after 0s (--max-inflight 1)' $R/p.log"
check "T2 a re-run with room creates the rest (the usual 'provision again later')" "CFFAKE_CREATE_POLLS=2 bash $M provision --wave 1 --max-inflight 4 --yes --run $R > $R/p2.log 2>&1 && [ \$(nok) = 4 ]"

echo "== V: value validation"
newrun V; bash "$M" provision --wave 1 --max-inflight 0 --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "V1 0 refused, nothing done" "[ $rc = 1 ] && grep -q 'whole number above 0' $R/p.log && [ ! -s $R/ledger.jsonl ]"
bash "$M" provision --wave 1 --max-inflight ten --yes --run "$R" > "$R/p.log" 2>&1; rc=$?
check "V2 'ten' refused" "[ $rc = 1 ] && grep -q \"got 'ten'\" $R/p.log"
bash "$M" apply --wave 1 --max-inflight=x --yes --run "$R" > "$R/a.log" 2>&1; rc=$?
check "V3 apply validates the same (--max-inflight=x form)" "[ $rc = 1 ] && grep -q 'whole number above 0' $R/a.log"

echo; echo "$fails FAIL(s)  (workdir $W)"; [ "$fails" = 0 ]
