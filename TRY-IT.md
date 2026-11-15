# Try StratoWeave yourself: a hands-on guide

You'll drive a real L3VPN over 4 Nokia SR Linux routers by changing the **intent**, and watch StratoWeave turn it into router config and traffic.

```
 cust-1 ── AMS-CORE-1 ─┬─ FRA-CORE-1 ── cust-2        4 PEs (Nokia SR Linux)
                       │      │                       4 CEs (FRR), one per PE
 cust-3 ── STO-CORE-1 ─┴─ LJU-CORE-1 ── cust-4        1 VPN "acme-65501", 4 sites
```

Run everything in a **WSL terminal**: type `wsl` in PowerShell or cmd. The one exception is the browser, which works from Windows.

## 0. Start the lab (after a reboot, or after `make stop`)

One time only: install `jq`, which pretty-prints JSON and is used below and by some make targets:

```bash
sudo apt update && sudo apt install -y jq
```

Docker Desktop must be running. Then:

```bash
cd ~/stratoweave/sorespo/test/quicklab-srl
make start                       # 9 containers, ~1 min when images are cached
make copy
docker exec -d -w / sorespo-quicklab-srl-sweave sh -c '/sorespo >> /sorespo.stdout 2>&1'
make wait                        # until the 4 routers answer NETCONF
make send-config-wait FILE=netinfra.xml
make send-config-wait FILE=l3vpn-svc.xml
make test-ping                   # all 12 site-to-site pings must pass
```

If the lab is already running (`docker ps | grep sorespo` shows 9 containers), skip to step 1.

## 1. Look around

- **Web UI:** open <http://localhost:3000> in your Windows browser.
- **The intent you sent**, as RFC 8299 JSON:
  ```bash
  curl -s -H 'Accept: application/yang-data+json' localhost:3000/restconf/data/ietf-l3vpn-svc:l3vpn-svc | jq
  ```
- **Each layer.** Layer 0 is your intent. Layer 3 is what goes to the routers.
  ```bash
  make get-config-json1 | jq '.' | head -40     # Inter layer: derived VRFs, loopbacks, iBGP
  make get-config-json2 | jq '.' | head -40     # RFS layer: one entry per router
  ```
- **What one router should have, what it has, and the difference:**
  ```bash
  make get-target-ams-core-1  | head -40
  make get-diff-ams-core-1                      # "# No differences" = in sync
  ```
- **The router itself:**
  ```bash
  make cli-ams-core-1
  #   show network-instance summary
  #   show network-instance acme-65501 protocols bgp neighbor
  #   info network-instance acme-65501
  #   quit
  ```

**Postman:** send `GET http://localhost:3000/restconf/data` with header `Accept: application/yang-data+json`. There is no auth.

## 2. Example: remove one site, then bring it back

This is the core idea: you change the intent, and StratoWeave computes and pushes the router config, both to create and to delete.

```bash
# site 2 can reach site 1?
docker exec sorespo-quicklab-srl-cust-2 ping -c 2 -I 10.200.1.2 10.200.1.1

# delete SITE-2 from the intent
curl -X DELETE localhost:3000/restconf/data/ietf-l3vpn-svc:l3vpn-svc/sites/site=SITE-2

# the VRF disappeared from FRA-CORE-1, and site 2 is cut off
docker exec sorespo-quicklab-srl-fra-core-1 sr_cli "show network-instance summary"
docker exec sorespo-quicklab-srl-cust-2 ping -c 2 -W 1 -I 10.200.1.2 10.200.1.1   # 100% loss

# put it back (re-sending the whole file is idempotent: only SITE-2 changes)
make send-config-wait FILE=l3vpn-svc.xml
sleep 15; make test-ping                                                           # 12/12 again
```

## 3. Example: the approval queue (human validation)

```bash
# require approval for every change on LJU-CORE-1
curl -X PATCH -H 'Content-Type: application/yang-data+json' \
  -d '{"netinfra:netinfra":{"router":[{"name":"LJU-CORE-1","approval-required":true}]}}' \
  localhost:3000/restconf/data

# ask to remove SITE-4. Use Async, otherwise the call waits for the approval!
curl -X DELETE -H 'Async: true' localhost:3000/restconf/data/ietf-l3vpn-svc:l3vpn-svc/sites/site=SITE-4

# see what is waiting, and the exact NETCONF diff
curl -s localhost:3000/config-queue | jq
curl -s localhost:3000/device/LJU-CORE-1/q | jq                     # -> {"tr-XXXX": {...}}
curl -s 'localhost:3000/device/LJU-CORE-1/q/tr-XXXX?format=xml' | jq -r .config_diff
```

Site 4 still works at this point, because nothing has been pushed yet. Approve it with the `device_txid` shown above:

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"device_txid":"<device_txid>","approved":true}' \
  localhost:3000/device/LJU-CORE-1/q/tr-XXXX/set_approval
```

You can also approve from the Web UI's queue page.

Clean up afterwards:

```bash
curl -X PATCH -H 'Content-Type: application/yang-data+json' \
  -d '{"netinfra:netinfra":{"router":[{"name":"LJU-CORE-1","approval-required":false}]}}' \
  localhost:3000/restconf/data
make send-config-wait FILE=l3vpn-svc.xml
```

> ⚠️ If you **reject** (`"approved":false`) instead, the intent keeps the change but the router doesn't get it, and `/diff` won't show the gap (REPORT.md, F2). To recover, delete the site and send the file again.

## 4. Example: drift (someone changes a router by hand)

```bash
# break site 4 behind the orchestrator's back
docker exec sorespo-quicklab-srl-lju-core-1 sr_cli -ec \
  "set / interface ethernet-1/3 subinterface 100 admin-state disable"
make get-diff-lju-core-1                         # still "No differences": not detected yet

# re-read the router: StratoWeave sees the drift and pushes the intent back
make resync-lju-core-1
docker exec sorespo-quicklab-srl-lju-core-1 sr_cli \
  "info from running / interface ethernet-1/3 subinterface 100 admin-state"   # enable
```

## 5. Example: a router is down during a change

```bash
docker pause sorespo-quicklab-srl-lju-core-1                 # LJU unreachable
curl -X DELETE localhost:3000/restconf/data/ietf-l3vpn-svc:l3vpn-svc/sites   # 204 "success" anyway
curl -s localhost:3000/device/LJU-CORE-1/info | jq .queue_length           # 1 change waiting
docker unpause sorespo-quicklab-srl-lju-core-1                 # LJU catches up within ~0.5 s
make send-config-wait FILE=l3vpn-svc.xml                       # restore everything
```

NSO would refuse the whole transaction here. StratoWeave applies what it can and converges later.

## 6. Benchmark and stop

```bash
bash /mnt/c/Projects/stratoweave-nso-benchmark/bench.sh 5   # ~7 min, writes results/
make stop                                                            # destroys the 9 containers
```

`make stop` only removes the containers. The images stay cached, so the next `make start` is fast. The orchestrator's intent lives in memory unless you start it with `--db /sw.lmdb`, so after a restart run the two `send-config-wait` commands again.
