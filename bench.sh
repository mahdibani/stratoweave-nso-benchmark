#!/usr/bin/env bash
# StratoWeave / SORESPO benchmark on the quicklab-srl topology.
# Prerequisite: lab deployed and orchestrator running (see README.md, steps 1-3).
# Usage (from WSL): ./bench.sh [runs]    -> writes results/bench-<timestamp>.txt
set -u
RUNS=${1:-5}
API=${API:-http://localhost:3000}
LAB=${LAB:-$HOME/stratoweave/sorespo/test/quicklab-srl}
P=sorespo-quicklab-srl
RESULTS_DIR=${RESULTS_DIR:-$(cd "$(dirname "$0")" && pwd)/results}
mkdir -p "$RESULTS_DIR"
OUT=$RESULTS_DIR/bench-$(date +%Y%m%d-%H%M%S).txt
ROUTERS="AMS-CORE-1 FRA-CORE-1 STO-CORE-1 LJU-CORE-1"
cd "$LAB"
exec > >(tee "$OUT") 2>&1

now() { date +%s.%N; }
since() { echo "$(now) - $1" | bc | awk '{printf "%.3f\n", $1}'; }
has_vrf() { docker exec $P-$1 sr_cli 'info from running / network-instance acme-65501 type' 2>/dev/null | grep -c ip-vrf; }
all_vrf() { local n=0 r; for r in ams-core-1 fra-core-1 sto-core-1 lju-core-1; do n=$((n + $(has_vrf $r))); done; echo $n; }
ping_pair() { docker exec $P-cust-$1 ping -c 1 -W 1 -I 10.200.1.$1 10.200.1.$2 >/dev/null 2>&1; }
mesh_ok() { local ok=0 i j; for i in 1 2 3 4; do for j in 1 2 3 4; do if [ $i != $j ] && ping_pair $i $j; then ok=$((ok+1)); fi; done; done; echo $ok; }
wait_until() { local deadline=$(( $(date +%s) + $1 )); shift; while [ $(date +%s) -lt $deadline ]; do eval "$@" && return 0; sleep 0.2; done; return 1; }
patch_xml() { curl -s -o /dev/null -w '%{http_code} %{time_total}' -m ${2:-60} -X PATCH -H 'Content-Type: application/yang-data+xml' ${3:+-H "$3"} -d @"$1" $API/restconf/data; }
del() { curl -s -o /dev/null -w '%{http_code} %{time_total}' -m ${2:-60} -X DELETE "$API/restconf/data/$1"; }
first_diff_line() { curl -s "$API/device/$1/diff?format=xml" | head -1; }
diff_clean() { local r; for r in $ROUTERS; do first_diff_line $r | grep -q '^# No differences' || return 1; done; }
q_last() { curl -s $API/device/$1/q | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d)[-1] if d else '')"; }
q_decide() {
  local tx
  tx=$(curl -s "$API/device/$1/q/$2?format=xml" | python3 -c "import json,sys; print(json.load(sys.stdin)['device_txid'])")
  curl -s -X POST -H 'Content-Type: application/json' -d "{\"device_txid\":\"$tx\",\"approved\":$3}" $API/device/$1/q/$2/set_approval
}
set_approval_required() {
  curl -s -o /dev/null -X PATCH -H 'Content-Type: application/yang-data+json' \
    -d "{\"netinfra:netinfra\":{\"router\":[{\"name\":\"$1\",\"approval-required\":$2}]}}" $API/restconf/data
}
lju_subif_disabled() { docker exec $P-lju-core-1 sr_cli "info from running / interface ethernet-1/3 subinterface 100 admin-state" 2>/dev/null | grep -q disable; }
stats() { sort -n | awk '{a[NR]=$1; s+=$1} END {printf "avg %.3fs  min %.3fs  max %.3fs  (n=%d)", s/NR, a[1], a[NR], NR}'; }
restart_sorespo() {
  docker exec $P-sweave pkill -f '^/sorespo'; sleep 1
  local t; t=$(now)
  docker exec -d -w / $P-sweave sh -c "/sorespo $1 >> /sorespo.stdout 2>&1"
  wait_until 30 '[ "$(curl -s -o /dev/null -w %{http_code} $API/device)" = 200 ]'
  echo "restart ${1:-without --db}: API up in $(since $t)s"
}

echo "# StratoWeave SORESPO benchmark - $(date -Is)"
echo "host: $(nproc) CPU, $(free -g | awk '/Mem/{print $2}') GiB RAM (WSL2) | docker $(docker version -f '{{.Server.Version}}')"
echo "sorespo source: $(git -C ../.. log -1 --format='%h %ci') | binary: $(stat -c %y ../../out/bin/sorespo | cut -d. -f1)"
echo

echo "## 0. Baseline"
echo "netinfra PATCH: $(patch_xml netinfra.xml) | l3vpn PATCH: $(patch_xml l3vpn-svc.xml)"
wait_until 120 '[ $(mesh_ok) = 12 ]' && echo "CE full mesh: 12/12 pairs OK" || echo "CE full mesh: $(mesh_ok)/12"
echo

echo "## 1. Service lifecycle x$RUNS (delete all 4 sites, then redeploy)"
: > /tmp/sw_del; : > /tmp/sw_api; : > /tmp/sw_cfg; : > /tmp/sw_traffic
for n in $(seq 1 $RUNS); do
  t=$(now); del ietf-l3vpn-svc:l3vpn-svc/sites >/dev/null; wait_until 60 '[ $(all_vrf) = 0 ]'; since $t >> /tmp/sw_del
  t=$(now); patch_xml l3vpn-svc.xml | awk '{print $2}' >> /tmp/sw_api
  wait_until 60 '[ $(all_vrf) = 4 ]'; since $t >> /tmp/sw_cfg
  wait_until 180 '[ $(mesh_ok) = 12 ]'; since $t >> /tmp/sw_traffic
done
echo "delete 4 sites -> VRF gone on all PEs : $(stats < /tmp/sw_del)"
echo "deploy: sync PATCH returns            : $(stats < /tmp/sw_api)"
echo "deploy: VRF present on all 4 PEs      : $(stats < /tmp/sw_cfg)"
echo "deploy: 12/12 CE pairs forwarding     : $(stats < /tmp/sw_traffic)  (includes eBGP + EVPN convergence)"
printf "rendered device config (lines)        : "; for r in $ROUTERS; do printf '%s=%s ' $r $(curl -s "$API/device/$r/target?format=xml" | wc -l); done; echo
echo

echo "## 2. Out-of-band drift on LJU-CORE-1"
docker exec $P-lju-core-1 sr_cli -ec "set / interface ethernet-1/3 subinterface 100 admin-state disable" >/dev/null
sleep 10
if first_diff_line LJU-CORE-1 | grep -q '^# No differences'; then echo "detected automatically within 10s: NO (/diff still '# No differences')"; else echo "detected automatically within 10s: YES"; fi
t=$(now); curl -s $API/device/LJU-CORE-1/resync >/dev/null
wait_until 60 '! lju_subif_disabled' && echo "GET /device/LJU-CORE-1/resync -> repaired in $(since $t)s"
wait_until 120 'ping_pair 4 1' && echo "cust-4 traffic restored $(since $t)s after resync"
echo

echo "## 3. Approval queue (approval-required on LJU-CORE-1)"
set_approval_required LJU-CORE-1 true
echo "DELETE SITE-4 (Async): HTTP $(curl -s -o /dev/null -w '%{http_code} %{time_total}' -X DELETE -H 'Async: true' $API/restconf/data/ietf-l3vpn-svc:l3vpn-svc/sites/site=SITE-4)"
sleep 2; Q=$(q_last LJU-CORE-1)
lines=$(curl -s "$API/device/LJU-CORE-1/q/$Q?format=xml" | python3 -c "import json,sys; print(len((json.load(sys.stdin).get('config_diff') or '').splitlines()))")
echo "queued $Q: pending NETCONF diff $lines lines | LJU VRF while pending: $(has_vrf lju-core-1) | cust-4 traffic: $(ping_pair 4 1 && echo up || echo down)"
t=$(now); q_decide LJU-CORE-1 $Q true >/dev/null
wait_until 30 '[ $(has_vrf lju-core-1) = 0 ]' && echo "approved -> applied in $(since $t)s"
echo "re-add SITE-4 (Async): HTTP $(patch_xml l3vpn-svc.xml 60 'Async: true')"
sleep 2; Q=$(q_last LJU-CORE-1)
echo "queued $Q -> REJECT: $(q_decide LJU-CORE-1 $Q false)"
sleep 2
echo "after reject: intent SITE-4 HTTP $(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/yang-data+json' $API/restconf/data/ietf-l3vpn-svc:l3vpn-svc/sites/site=SITE-4) | LJU VRF: $(has_vrf lju-core-1) | LJU /diff: $(first_diff_line LJU-CORE-1)"
set_approval_required LJU-CORE-1 false
patch_xml l3vpn-svc.xml >/dev/null; curl -s $API/device/LJU-CORE-1/resync >/dev/null; sleep 3
echo "approval off + same intent re-sent + resync: LJU VRF: $(has_vrf lju-core-1)  (0 = intent and network still diverge)"
del ietf-l3vpn-svc:l3vpn-svc/sites/site=SITE-4 >/dev/null; patch_xml l3vpn-svc.xml >/dev/null
wait_until 60 '[ $(has_vrf lju-core-1) = 1 ]' && echo "workaround (delete + re-add SITE-4): LJU VRF back"
echo

echo "## 4. Unreachable PE during a multi-device change"
wait_until 180 '[ $(mesh_ok) = 12 ]'
docker pause $P-lju-core-1 >/dev/null
echo "DELETE all sites, LJU paused: HTTP $(del ietf-l3vpn-svc:l3vpn-svc/sites 30)"
sleep 1
echo "VRFs on reachable PEs: ams=$(has_vrf ams-core-1) fra=$(has_vrf fra-core-1) sto=$(has_vrf sto-core-1) | LJU queue_length=$(curl -s $API/device/LJU-CORE-1/info | python3 -c 'import json,sys; print(json.load(sys.stdin)["queue_length"])')"
t=$(now); docker unpause $P-lju-core-1 >/dev/null
wait_until 120 '[ $(has_vrf lju-core-1) = 0 ]' && echo "LJU converged $(since $t)s after coming back"
docker pause $P-lju-core-1 >/dev/null
echo "sync PATCH l3vpn, LJU paused (20s client timeout): HTTP $(patch_xml l3vpn-svc.xml 20)"
echo "VRFs on reachable PEs: ams=$(has_vrf ams-core-1) fra=$(has_vrf fra-core-1) sto=$(has_vrf sto-core-1)"
t=$(now); docker unpause $P-lju-core-1 >/dev/null
wait_until 120 '[ $(has_vrf lju-core-1) = 1 ]' && echo "LJU converged $(since $t)s after coming back"
wait_until 180 '[ $(mesh_ok) = 12 ]' && echo "CE full mesh: 12/12 pairs OK"
echo

echo "## 5. Orchestrator restart"
restart_sorespo ""
echo "  after restart without --db: $(curl -s $API/device) | routers keep config: VRFs $(all_vrf)/4"
docker exec $P-sweave rm -rf /bench.lmdb
restart_sorespo "--db /bench.lmdb"
patch_xml netinfra.xml >/dev/null; patch_xml l3vpn-svc.xml >/dev/null
wait_until 30 diff_clean && echo "  intent loaded, all 4 /diff clean before restart"
restart_sorespo "--db /bench.lmdb"
sleep 8
echo "  after restart with --db: $(curl -s $API/device)"
for r in $ROUTERS; do echo "  $r /diff: $(first_diff_line $r)"; done
echo "  AMS-CORE-1 <net> entries: target=$(curl -s "$API/device/AMS-CORE-1/target?format=xml" | grep -c '<net>') running=$(curl -s "$API/device/AMS-CORE-1/running?format=xml" | grep -c '<net>')"
wait_until 180 '[ $(mesh_ok) = 12 ]' && echo "  CE full mesh: 12/12 pairs OK"
echo

echo "## 6. Footprint"
echo "sorespo RSS: $(docker exec $P-sweave sh -c 'grep VmRSS /proc/$(pgrep -f ^/sorespo | head -1)/status' | awk '{printf "%.0f MiB", $2/1024}') | binary: $(du -h ../../out/bin/sorespo | cut -f1)"
for r in ams-core-1 lju-core-1; do echo "SR Linux $r: $(docker exec $P-$r cat /sys/fs/cgroup/memory.current | awk '{printf "%.0f MiB", $1/1048576}')"; done
echo "FRR CE cust-1: $(docker stats --no-stream --format '{{.MemUsage}}' $P-cust-1 | cut -d/ -f1)"
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep -E 'srlinux|frr|sweave|clab:' | sed 's/^/image: /'
echo
echo "results written to $OUT"
