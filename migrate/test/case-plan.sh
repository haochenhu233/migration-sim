#!/usr/bin/env bash
# case-plan.sh -- offline cases for `migrate.sh plan` on test/fixtures/merged_report.csv (no CF needed).
# Usage: bash migrate/test/case-plan.sh [workdir]. Every case prints PASS/FAIL; exit 1 if any FAIL.
# The fixture has one component per --isolate class (cache = no-binding, store = hazard, queue = windows)
# and three normal ones (session + redis-small-test silent, healthcheck live); ghost is excluded.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; M="$HERE/../migrate.sh"; F="$HERE/fixtures/merged_report.csv"; W="${1:-$(mktemp -d)}"; mkdir -p "$W"
fails=0; pass(){ echo "PASS  $1"; }; fail(){ echo "FAIL  $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then pass "$1"; else fail "$1 -- [$2]"; fi; }
# wave_of <run> <service name> -> its wave; svcs_in <run> <wave> -> distinct service names of that wave, one per line
wave_of(){ awk -F'\t' -v s="$2" 'NR>1 && $3==s {print $1; exit}' "$1/waves.tsv"; }
svcs_in(){ awk -F'\t' -v w="$2" 'NR>1 && $1==w {print $3}' "$1/waves.tsv" | sort -u; }
nwaves(){ awk -F'\t' 'NR>1 {print $1}' "$1/waves.tsv" | sort -un | tail -1; }
apps_in(){ awk -F'\t' -v w="$2" 'NR>1 && $1==w {print $8}' "$1/waves.tsv" | sort -u | paste -sd, -; }
plan(){ local r="$W/$1"; shift; rm -rf "$r"; mkdir -p "$r"; bash "$M" plan "${REP:-$F}" --run "$r" "$@" > "$r/plan.log" 2>&1; echo $? > "$r/rc"; }

echo "== P1: default plan: no isolation, flags still written, no class column"
plan p1
check "P1a 2 waves, exit 0" "[ $(cat $W/p1/rc) = 0 ] && [ $(nwaves $W/p1) = 2 ]"
check "P1b the flagged components share wave 2 with a normal one (nothing isolated by default)" "[ $(wave_of $W/p1 sim-redis-store) = 2 ] && [ $(wave_of $W/p1 sim-redis-cache) = 2 ] && [ $(wave_of $W/p1 sim-redis-queue) = 2 ] && [ $(wave_of $W/p1 serviceshealthcheck-redis) = 2 ]"
check "P1c flags unchanged in waves.tsv (hazard, no-binding:<method>, windows, idle)" "grep -q 'sim-pinned.*hazard' $W/p1/waves.tsv && grep -q 'sim-static-env.*no-binding:static-ref-env-var' $W/p1/waves.tsv && grep -q 'sim-win.*windows' $W/p1/waves.tsv && grep -q 'sim-session.*idle' $W/p1/waves.tsv"
check "P1d summary has no class column and no Isolated section; stdout has no isolate line" "! grep -q '| class |' $W/p1/plan-summary.md && ! grep -q 'Isolated waves' $W/p1/plan-summary.md && ! grep -q 'isolate' $W/p1/plan.log"
# golden files = HEAD's output before --isolate existed (test/fixtures/plan-golden, summary without its 'generated' line): the default plan must not move at all
G="$HERE/fixtures/plan-golden"
check "P1e default plan byte-identical to the golden waves.tsv / components.tsv / plan-summary.md" "cmp -s $W/p1/waves.tsv $G/waves.tsv && cmp -s $W/p1/components.tsv $G/components.tsv && cmp -s <(grep -v '^generated ' $W/p1/plan-summary.md) $G/plan-summary.md"

echo "== P2: --isolate hazard,no-binding,windows: one class per wave, packed last, class order windows < no-binding < hazard"
plan p2 --isolate hazard,no-binding,windows
check "P2a 5 waves, exit 0" "[ $(cat $W/p2/rc) = 0 ] && [ $(nwaves $W/p2) = 5 ]"
check "P2b normal waves first: silent pair in 1, healthcheck in 2" "[ $(wave_of $W/p2 sim-redis-session) = 1 ] && [ $(wave_of $W/p2 redis-small-test) = 1 ] && [ $(wave_of $W/p2 serviceshealthcheck-redis) = 2 ]"
check "P2c wave 3 = windows only, 4 = no-binding only, 5 = hazard only" "[ \"$(svcs_in $W/p2 3)\" = sim-redis-queue ] && [ \"$(svcs_in $W/p2 4)\" = sim-redis-cache ] && [ \"$(svcs_in $W/p2 5)\" = sim-redis-store ]"
check "P2d the isolated component travels whole: store's plain app is in the hazard wave with the pinned one" "[ $(apps_in $W/p2 5) = sim-pinned,sim-store ]"
check "P2e wave table has the class column with the right labels" "grep -q '^| 3 | 1 | 0 | 1 | 1 | 1 | windows |$' $W/p2/plan-summary.md && grep -q '^| 4 | 1 | 0 | 5 | 1 | 1 | no-binding |$' $W/p2/plan-summary.md && grep -q '^| 5 | 1 | 0 | 2 | 1 | 1 | hazard |$' $W/p2/plan-summary.md && grep -q '^| 1 | 2 | 2 | 2 | 2 | 2 | - |$' $W/p2/plan-summary.md"
check "P2f Isolated section: per-class rows and the total with denominators" "grep -q '^| hazard | 5-5 | 1 | 1 | 2 |$' $W/p2/plan-summary.md && grep -q '^| no-binding | 4-4 | 1 | 1 | 5 |$' $W/p2/plan-summary.md && grep -q '^| windows | 3-3 | 1 | 1 | 1 |$' $W/p2/plan-summary.md && grep -q '^isolated in total: 3 of 6 components, 3 of 6 services, 8 of 11 apps in the last 3 wave(s); the other 2 wave(s) carry none of these classes$' $W/p2/plan-summary.md"
check "P2g stdout line" "grep -q '^plan: --isolate hazard,no-binding,windows: 3 component(s) / 3 service(s) / 8 app(s) in the last 3 wave(s); 2 wave(s) carry none of these classes$' $W/p2/plan.log"
check "P2h components.tsv and waves.tsv hold the same 6 services as the default plan (only wave numbers moved)" "[ \"$(cut -f4 $W/p2/waves.tsv | sort -u)\" = \"$(cut -f4 $W/p1/waves.tsv | sort -u)\" ] && [ $(awk -F'\t' 'NR>1' $W/p2/components.tsv | wc -l) = 6 ]"

echo "== P3: a component with two classes takes the most blocked one (hazard over windows)"
REP="$W/two-class.csv"; cp "$F" "$REP"
echo "sim-win-store,dev,sim,0000001b-0000-4000-8000-000000000027,cf-bind,,,sim-redis-store,dev,sim,redis-cache-medium-00000067-0000-4000-8000-000000000103,00000067-0000-4000-8000-000000000103,windows,yes,yes,both" >> "$REP"
plan p3 --isolate hazard,no-binding,windows; unset REP
check "P3a store (hazard + a windows app) is in the hazard wave, alone; the windows wave holds queue only" "[ \"$(svcs_in $W/p3 5)\" = sim-redis-store ] && [ \"$(svcs_in $W/p3 3)\" = sim-redis-queue ] && grep -q '^| 5 | 1 | 0 | 3 | 1 | 1 | hazard |$' $W/p3/plan-summary.md"
check "P3b Isolated rows count the component once, under hazard (3 apps), windows still 1" "grep -q '^| hazard | 5-5 | 1 | 1 | 3 |$' $W/p3/plan-summary.md && grep -q '^| windows | 3-3 | 1 | 1 | 1 |$' $W/p3/plan-summary.md && grep -q '^isolated in total: 3 of 6 components, 3 of 6 services, 9 of 12 apps' $W/p3/plan-summary.md"

echo "== P4: a subset: --isolate hazard leaves no-binding and windows components in the normal waves"
plan p4 --isolate hazard
check "P4a store alone in the last wave (3); cache and queue stay with healthcheck in wave 2" "[ $(nwaves $W/p4) = 3 ] && [ \"$(svcs_in $W/p4 3)\" = sim-redis-store ] && [ \"$(svcs_in $W/p4 2 | paste -sd, -)\" = serviceshealthcheck-redis,sim-redis-cache,sim-redis-queue ]"
check "P4b Isolated section lists hazard only" "grep -q '^| hazard | 3-3 | 1 | 1 | 2 |$' $W/p4/plan-summary.md && ! grep -q '^| no-binding |' $W/p4/plan-summary.md && ! grep -q '^| windows |' $W/p4/plan-summary.md"

echo "== P5: unknown class -> usage error, nothing written"
plan p5 --isolate hazard,foo
check "P5 exit 1, names the class, no files" "[ $(cat $W/p5/rc) = 1 ] && grep -q \"unknown class 'foo'\" $W/p5/plan.log && [ ! -e $W/p5/waves.tsv ] && [ ! -e $W/p5/plan-summary.md ]"

echo "== P6: --order hard with --isolate: isolated still last, one class per wave"
plan p6 --isolate hazard,no-binding,windows --order hard
check "P6 last three waves are windows, no-binding, hazard; normal components before them" "[ $(nwaves $W/p6) = 5 ] && [ \"$(svcs_in $W/p6 3)\" = sim-redis-queue ] && [ \"$(svcs_in $W/p6 4)\" = sim-redis-cache ] && [ \"$(svcs_in $W/p6 5)\" = sim-redis-store ] && [ $(wave_of $W/p6 serviceshealthcheck-redis) -le 2 ]"

echo "== P7: an oversized isolated component still owns its wave, still last"
plan p7 --isolate no-binding --max-apps 3
check "P7 cache (5 apps > cap 3) alone in the last wave; the other components' waves untouched by it" "[ \"$(svcs_in $W/p7 $(nwaves $W/p7))\" = sim-redis-cache ] && [ $(awk -F'\t' -v w=$(nwaves $W/p7) 'NR>1 && $1==w' $W/p7/waves.tsv | wc -l) = 5 ] && grep -q '^| no-binding | ' $W/p7/plan-summary.md"

echo "== P8: the option value is normalised once -- blanks, duplicates, trailing comma, = form (review 2026-10-23 finding 1/2)"
plan p8 --isolate "hazard, windows"
check "P8a 'hazard, windows' isolates BOTH (cache stays normal in 2; windows wave 3, hazard wave 4), header shows the normalised list" "[ $(nwaves $W/p8) = 4 ] && [ \"$(svcs_in $W/p8 3)\" = sim-redis-queue ] && [ \"$(svcs_in $W/p8 4)\" = sim-redis-store ] && [ $(wave_of $W/p8 sim-redis-cache) = 2 ] && grep -q 'isolate=hazard,windows)' $W/p8/plan-summary.md && grep -q '^| windows | 3-3 | 1 | 1 | 1 |$' $W/p8/plan-summary.md"
plan p8b --isolate=windows
check "P8b --isolate=windows is accepted (not swallowed as an unknown flag)" "[ $(cat $W/p8b/rc) = 0 ] && [ \"$(svcs_in $W/p8b $(nwaves $W/p8b))\" = sim-redis-queue ] && grep -q '^plan: --isolate windows: 1 component(s)' $W/p8b/plan.log"
plan p8c --isolate hazard,hazard,
check "P8c duplicates and a trailing comma collapse to one class" "grep -q 'isolate=hazard)' $W/p8c/plan-summary.md && [ $(grep -c '^| hazard |' $W/p8c/plan-summary.md) = 1 ]"
plan p8d --isolate " "
check "P8d a blank list is an error, nothing written" "[ $(cat $W/p8d/rc) = 1 ] && grep -q 'no class given' $W/p8d/plan.log && [ ! -e $W/p8d/waves.tsv ]"

echo "== P9: second fixture (merged_report_iso.csv): bridge app across two classes, two components of one class in one wave, silent isolated, mixed platform rows"
REP="$HERE/fixtures/merged_report_iso.csv"; plan p9 --isolate windows,no-binding; unset REP
check "P9a bridge: m-app binds svc-X (windows app) and svc-Y (static-ref app) -> ONE component, class no-binding, last wave, 3 apps" "[ \"$(svcs_in $W/p9 4 | paste -sd, -)\" = svc-X,svc-Y ] && [ $(apps_in $W/p9 4) = env-y,m-app,win-x ] && grep -q '^| 4 | 2 | 0 | 3 | 1 | 1 | no-binding |$' $W/p9/plan-summary.md"
check "P9b two live windows components share one windows wave (3); the silent windows one has its own (2), silent svcs 1" "[ \"$(svcs_in $W/p9 3 | paste -sd, -)\" = svc-WL,svc-WL2 ] && [ \"$(svcs_in $W/p9 2)\" = svc-WI ] && grep -q '^| 2 | 1 | 1 | 1 | 1 | 1 | windows |$' $W/p9/plan-summary.md && grep -q '^| windows | 2-3 | 3 | 3 | 3 |$' $W/p9/plan-summary.md"
check "P9c class follows the windows FLAG: mixed-p (last row platform blank) has no windows flag and stays normal with svc-Z in wave 1" "[ \"$(svcs_in $W/p9 1 | paste -sd, -)\" = svc-P,svc-Q,svc-Z ] && ! grep -q 'mixed-p.*windows' $W/p9/waves.tsv && grep -q '^| 1 | 3 | 0 | 2 | 2 | 1 | - |$' $W/p9/plan-summary.md"
check "P9d totals with denominators" "grep -q '^isolated in total: 4 of 6 components, 5 of 8 services, 6 of 8 apps in the last 3 wave(s); the other 1 wave(s) carry none of these classes$' $W/p9/plan-summary.md"
REP="$HERE/fixtures/merged_report_iso.csv"; plan p9e --isolate hazard,windows; unset REP
check "P9e --isolate hazard,windows on a report with no hazard: '| hazard | - | 0 | 0 | 0 |' row; the X/Y bridge now counts as windows (its no-binding class was not requested) and joins the live windows wave" "grep -q '^| hazard | - | 0 | 0 | 0 |$' $W/p9e/plan-summary.md && [ \"$(svcs_in $W/p9e $(nwaves $W/p9e) | paste -sd, -)\" = svc-WL,svc-WL2,svc-X,svc-Y ] && grep -q '^| windows | 2-3 | 4 | 5 | 6 |$' $W/p9e/plan-summary.md && [ \"$(svcs_in $W/p9e 1 | paste -sd, -)\" = svc-P,svc-Q,svc-Z ]"

echo; echo "case-plan: $fails failure(s)"; [ $fails = 0 ]
