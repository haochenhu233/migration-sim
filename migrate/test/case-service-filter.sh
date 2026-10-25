#!/usr/bin/env bash
# case-service-filter.sh -- offline cases for --service on apply/provision (2026-10-25): a service NAME is unique per
# space, not per wave, so the same name in two spaces matched both and apply migrated two services in one go (ext).
# svc_filter now refuses an ambiguous name and prints the guid prefixes; a guid prefix selects exactly one.
# Usage: bash migrate/test/case-service-filter.sh [workdir]. PASS/FAIL per check; exit 1 on any FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
export CF_CMD="$HERE/cf-fake" BOSH_CMD="$HERE/bosh-fake" JOB_POLL=0 SOAK=0 MIGRATE_OP=test
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
nled(){ grep -c . "$R/ledger.jsonl" 2>/dev/null || echo 0; }
newrun(){ # fresh run dir whose wave 1 holds cache-0 twice: the example's (acme/dev) and a twin in acme/qa
  R="$W/$1"; rm -rf "$R"; mkdir -p "$R"
  { cat "$HERE/../example/waves.tsv"
    printf '1\tffff0001\tcache-0\tffffffff-0000-4000-8000-000000000001\tacme\tqa\tcache-small\tapp-0\tffffffff-0000-4000-8000-0000000000a1\tacme\tqa\tidle\n'; } > "$R/waves.tsv"
  export CFFAKE_STATE="$R/cf.json" SAFEFAKE_STATE="$R/safe"; "$CF_CMD" seed "$R/waves.tsv" > /dev/null
  printf 'SAFE_RUN="%s"\n' "$HERE/safe-fake" > "$R/vault.conf"; }
G0=2f6fe3d9-1e8a-48cf-ae53-4d6e0f5ca70a   # cache-0 in acme/dev

echo "== F: --service by a name shared by two services of the wave"
newrun F
check "F0 the fixture has cache-0 twice in wave 1" "[ \$(awk -F'\t' '\$1==1 && \$3==\"cache-0\" {print \$4}' $R/waves.tsv | sort -u | wc -l | tr -d ' ') = 2 ]"
bash "$M" provision --wave 1 --service cache-0 --yes --run "$R" > "$R/p1.log" 2>&1; rc=$?
check "F1 provision --service <name>: refused (exit 1), names both guid prefixes, nothing in the ledger" "[ $rc = 1 ] && grep -q 'matches 2 services in wave 1' $R/p1.log && grep -q -- '--service 2f6fe3d9' $R/p1.log && grep -q -- '--service ffffffff' $R/p1.log && [ \$(nled) = 0 ]"
bash "$M" apply --wave 1 --service cache-0 --yes --run "$R" > "$R/a1.log" 2>&1; rc=$?
check "F2 apply --service <name>: refused (exit 1), nothing in the ledger, no lock left" "[ $rc = 1 ] && grep -q 'matches 2 services in wave 1' $R/a1.log && [ \$(nled) = 0 ] && [ ! -s $R/wave-1.lock ]"
bash "$M" provision --wave 1 --service 2f6fe3d9 --yes --run "$R" > "$R/p2.log" 2>&1; rc=$?
check "F3 provision --service <guid prefix>: exactly that service's Valkey created" "[ $rc = 0 ] && [ \$(jq -r 'select(.step==\"create-valkey\" and .outcome==\"ok\") | .service' $R/ledger.jsonl | sort -u | wc -l | tr -d ' ') = 1 ] && jq -r 'select(.step==\"create-valkey\") | .service' $R/ledger.jsonl | grep -q $G0"
bash "$M" apply --wave 1 --service no-such-service --yes --run "$R" > "$R/a2.log" 2>&1; rc=$?
check "F4 apply --service with no match: refused (exit 1)" "[ $rc = 1 ] && grep -q 'no service matches --service no-such-service' $R/a2.log"
n=$(nled); bash "$M" provision --wave 1 --yes --run "$R" > "$R/p3.log" 2>&1; rc=$?
check "F5 provision without --service still takes the whole wave (both cache-0 among them)" "[ $rc = 0 ] && [ \$(jq -r 'select(.step==\"create-valkey\" and .outcome==\"ok\") | .service' $R/ledger.jsonl | sort -u | wc -l | tr -d ' ') = 5 ]"

echo; echo "$fails FAIL(s)  (workdir $W)"; [ "$fails" = 0 ]
