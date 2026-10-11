#!/usr/bin/env bash
# free-ips.sh --network <name> [--plan runs/<env>/waves.tsv] [--out runs/<env>/free-ips.txt] [--ips-per-service N]
#   Free dynamic IPs on one BOSH network = what Blacksmith can still provision into.
#   Per subnet: pool = range - network - broadcast - gateway - reserved - static
#               used = IPs of every INSTANCE BOSH knows (all deployments, incl. hard-stopped ones
#                      and failed creates: they keep their IP reservation) that fall in the pool
#               free = pool - used
#   Static ranges are excluded: Blacksmith allocates dynamically. IPs BOSH does not manage
#   (director, jumpbox, load balancers, VMs of ANOTHER director on the same network) must be in
#   `reserved` or they are counted as free. Compilation VMs are transient and not listed -> while a
#   deploy runs, a few IPs more are in use than reported.
#   Director: the one Blacksmith deploys through (its bosh.address). With --plan the script refuses
#   a director that runs none of the plan's Redis deployments (deployment names carry the SI guid).
#   A team-scoped BOSH client sees only its team's deployments: use a director-wide read client.
#   NEED with --plan = services still to create x --ips-per-service (default 1: standalone plans;
#   a clustered plan needs its node count). Services whose Valkey the ledger already shows as
#   created are not counted again (their IP is already in `used`).
#   Read-only. BOSH_CMD = the bosh invocation that works here (default: bosh; bastion: genesis ... bosh).
#   bash/jq/awk only (gawk, mawk >= 1.3.3 and BWK awk).
set -u
NET=""; PLAN=""; OUT=""; IPS_PER=1; CCNAME=""
while [ "${1:-}" ]; do case "$1" in --network) NET="$2"; shift 2;; --plan) PLAN="$2"; shift 2;; --out) OUT="$2"; shift 2;; --ips-per-service) IPS_PER="$2"; shift 2;; --cloud-config) CCNAME="$2"; shift 2;; *) echo "unknown arg $1"; exit 2;; esac; done
[ -n "$NET" ] || { echo "usage: free-ips.sh --network <bosh network name> [--cloud-config <name>] [--plan waves.tsv] [--out free-ips.txt] [--ips-per-service N]   (BOSH_CMD='genesis ... bosh' if needed)"; exit 2; }
case "$IPS_PER" in ''|*[!0-9]*|0) echo "--ips-per-service must be a positive integer"; exit 2;; esac
B="${BOSH_CMD:-bosh}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
die(){ echo "!! $*" >&2; exit 1; }
# bint <file> <path>: `bosh int --path`, stdout on success; "ABSENT" exit 0 when the path is missing; die on any other error
bint(){ local out rc; out=$($B int "$1" --path "$2" 2> "$TMP/bint.err"); rc=$?
  if [ $rc -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
  if grep -qE "Expected to find (a map key|exactly one matching array item|array index)" "$TMP/bint.err"; then echo ABSENT; return 0; fi
  die "bosh int --path $2 failed: $(head -1 "$TMP/bint.err")"; }
# list items from `bosh int` output ("- a.b.c.d - e.f.g.h" -> "a.b.c.d-e.f.g.h"), joined by comma
items(){ awk '/^- / { sub(/^- /, ""); gsub(/ /, ""); print }' | paste -sd, -; }

# 1) cloud-config: the subnets of the network. `bosh cloud-config` is the config NAMED "default";
#    a director with named cloud configs (`bosh configs --type cloud`) needs --cloud-config <name>.
if [ -n "$CCNAME" ]; then
  $B config --type cloud --name "$CCNAME" > "$TMP/cc.yml" 2> "$TMP/cc.err" || die "bosh config --type cloud --name $CCNAME failed: $(cat "$TMP/cc.err")"
else
  $B cloud-config > "$TMP/cc.yml" 2> "$TMP/cc.err" || die "bosh cloud-config failed: $(cat "$TMP/cc.err")"
fi
[ -s "$TMP/cc.yml" ] || die "bosh cloud-config returned nothing"
[ "$(bint "$TMP/cc.yml" /networks)" != ABSENT ] || die "cloud config '${CCNAME:-default}' has no networks -- named cloud configs? run: bosh configs --type cloud, then pass --cloud-config <name>"
nsub=$(bint "$TMP/cc.yml" "/networks/name=$NET/subnets")
[ "$nsub" != ABSENT ] || die "network '$NET' not in cloud-config (or has no subnets); networks: $(bint "$TMP/cc.yml" /networks | awk '/^- name:/ {print $3} /^  name:/ {print $2}' | paste -sd, -)"
nsub=$(printf '%s\n' "$nsub" | grep -c '^- ')
[ "$nsub" -gt 0 ] || die "network '$NET' has no subnets"
: > "$TMP/subnets.tsv"; i=0
while [ "$i" -lt "$nsub" ]; do
  bint "$TMP/cc.yml" "/networks/name=$NET/subnets/$i" > "$TMP/s$i.yml"
  range=$(bint "$TMP/s$i.yml" /range); gw=$(bint "$TMP/s$i.yml" /gateway)
  [ "$range" != ABSENT ] || die "subnet $i of $NET has no range"
  printf '%s\n' "$range" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' || die "subnet $i of $NET: range '$range' is not an IPv4 CIDR -- only IPv4 is supported"
  azs=$(bint "$TMP/s$i.yml" /azs); if [ "$azs" != ABSENT ]; then azs=$(printf '%s\n' "$azs" | items | tr , +); else azs=$(bint "$TMP/s$i.yml" /az); fi
  res=$(bint "$TMP/s$i.yml" /reserved); if [ "$res" != ABSENT ]; then res=$(printf '%s\n' "$res" | items); else res=""; fi
  sta=$(bint "$TMP/s$i.yml" /static);   if [ "$sta" != ABSENT ]; then sta=$(printf '%s\n' "$sta" | items); else sta=""; fi
  [ "$gw" != ABSENT ] || gw="-"; [ "$azs" != ABSENT ] || azs="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "${azs:--}" "$range" "$gw" "$res" "$sta" >> "$TMP/subnets.tsv"
  i=$((i+1))
done

# 2) every IP BOSH has reserved: instances of all deployments (a hard-stopped instance has no VM but keeps its IP).
#    Shape-checked: no Tables / no rows is an error, not "nothing deployed".
$B instances --json > "$TMP/inst.json" 2> "$TMP/inst.err" || die "bosh instances failed: $(cat "$TMP/inst.err")"
jq -e '.Tables and (.Tables|length>0)' "$TMP/inst.json" > /dev/null 2>&1 || die "bosh instances --json: unexpected shape (no Tables): $(head -c 200 "$TMP/inst.json")"
jq -r '.Tables[].Rows[]?.ips // empty' "$TMP/inst.json" | tr ',' '\n' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u > "$TMP/used.txt"
NINST=$(jq '[.Tables[].Rows[]?] | length' "$TMP/inst.json"); NDEP=$(jq '[.Tables[] | select((.Rows|length)>0)] | length' "$TMP/inst.json")
[ "$NINST" -gt 0 ] || die "bosh instances lists 0 instances on this director -- wrong director/credentials? (refusing to report everything as free)"
# with a plan: this director must run the plan's Redis deployments (names carry the SI guid), else it is not Blacksmith's director
if [ -n "$PLAN" ]; then
  [ -s "$PLAN" ] || die "no plan $PLAN"
  jq -r '.Tables[] | (.Title // ""), (.Rows[]?.deployment // empty)' "$TMP/inst.json" | sort -u > "$TMP/deps.txt"
  awk -F'\t' 'NR>1 && $4!="" {print $4}' "$PLAN" | sort -u > "$TMP/plansvc.txt"
  hit=$(grep -c -F -f "$TMP/plansvc.txt" "$TMP/deps.txt" || true)
  [ "${hit:-0}" -gt 0 ] || die "none of the plan's $(wc -l < "$TMP/plansvc.txt" | tr -d ' ') Redis service guids appears in this director's deployment names -- is BOSH_CMD the director Blacksmith deploys through?"
fi

# 3) arithmetic in awk (IPv4 -> int). Membership is numeric, never a string prefix.
#    Array keys go through key(): mawk stringifies integers > 2^31 as 2.88673e+09 otherwise.
awk -F'\t' -v used="$TMP/used.txt" -v net="$NET" -v totals="$TMP/totals" '
  function ip2n(s,  a) { split(s, a, "."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
  function n2ip(n) { return int(n/16777216)%256 "." int(n/65536)%256 "." int(n/256)%256 "." n%256 }
  function key(n) { return sprintf("%.0f", n) }
  function mark(list, tag,   cnt, p, q, j, lo, hi) {        # list "a,b-c,d" -> excl[ip]=tag
    if (list=="") return; cnt=split(list, p, ",")
    for (j=1;j<=cnt;j++) { if (index(p[j],"-")) { split(p[j], q, "-"); lo=ip2n(q[1]); hi=ip2n(q[2]) } else { lo=hi=ip2n(p[j]) }
      if (lo < first || hi > last) { printf "subnet %s: %s entry %s outside range %s\n", $1, tag, p[j], $3 > "/dev/stderr"; bad=1 }
      for (; lo<=hi; lo++) excl[key(lo)]=tag } }
  BEGIN { while ((getline l < used) > 0) inuse[key(ip2n(l))]=1 }
  { split($3, c, "/"); bits=c[2]+0; if (bits<8 || bits>30) { printf "subnet %s: prefix /%d not supported\n", $1, bits > "/dev/stderr"; bad=1; next }
    size=2^(32-bits); base=ip2n(c[1]); first=base - (base % size); last=first+size-1
    if (first != base) { printf "subnet %s: range %s is not aligned (network is %s)\n", $1, $3, n2ip(first) > "/dev/stderr"; bad=1; next }
    delete excl; excl[key(first)]="net"; excl[key(last)]="bcast"; if ($4!="-") excl[key(ip2n($4))]="gw"
    mark($5, "reserved"); mark($6, "static")
    pool=0; u=0; for (n=first; n<=last; n++) { if (key(n) in excl) continue; pool++; if (key(n) in inuse) u++ }
    printf "subnet %s  az %-10s %-18s pool %5d  used %5d  free %5d\n", $1, $2, $3, pool, u, pool-u
    P+=pool; U+=u }
  END { if (bad) exit 3; printf "TOTAL %s: pool %d  used %d  FREE %d\n", net, P, U, P-U; printf "%d %d %d\n", P-U, P, U > totals }
' "$TMP/subnets.tsv" || die "IP arithmetic failed (awk exit $?) -- nothing written"
read -r FREE POOL USEDN < "$TMP/totals" 2>/dev/null || die "IP arithmetic produced no totals -- nothing written"
case "$FREE$POOL$USEDN" in *[!0-9]*|"") die "IP arithmetic produced non-numeric totals '$FREE $POOL $USEDN' -- nothing written";; esac
echo "(BOSH knows $NINST instance(s) in $NDEP deployment(s); IPs outside this director -- its own VM, jumpbox, LBs, other directors -- count as free unless in 'reserved')"
rc=0
if [ -n "$PLAN" ]; then
  # services still to create = plan services minus those whose create-valkey is ok in the run's ledger
  LEDGER="$(dirname "$PLAN")/ledger.jsonl"; : > "$TMP/created.txt"
  [ -s "$LEDGER" ] && jq -R -r 'fromjson? // empty | select(.step=="create-valkey" and .outcome=="ok" and .app=="") | .service' "$LEDGER" | sort -u > "$TMP/created.txt"
  NSVC=$(wc -l < "$TMP/plansvc.txt" | tr -d ' ')
  if [ -s "$TMP/created.txt" ]; then TODO=$(grep -v -x -F -f "$TMP/created.txt" "$TMP/plansvc.txt" | wc -l | tr -d ' '); else TODO=$NSVC; fi
  NEED=$(( TODO * IPS_PER ))
  if [ "$FREE" -ge "$NEED" ]; then echo "plan: $NSVC service(s), $TODO still to create x $IPS_PER IP = $NEED needed alongside the standbys: OK ($FREE free)"
  else echo "plan: $NSVC service(s), $TODO still to create x $IPS_PER IP = $NEED needed alongside the standbys: SHORT by $((NEED-FREE)) ($FREE free)"; rc=1; fi
fi
if [ -n "$OUT" ]; then
  { printf 'free_ips=%s network=%s ts=%s pool=%s used=%s\n' "$FREE" "$NET" "$(date -u +%FT%TZ)" "$POOL" "$USEDN" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"; } || die "cannot write $OUT"
  echo "written $OUT (preflight reads it when --free-ips is not given, minus Valkeys created since)"
fi
exit $rc
