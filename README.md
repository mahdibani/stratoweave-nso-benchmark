# StratoWeave evaluation: reproduce it

These are the steps used to install, run and benchmark [StratoWeave](https://www.stratoweave.org/) (LF Networking, BSD-3-Clause) with its reference orchestrator **SORESPO**. The setup has 4 Nokia SR Linux PEs and 4 FRR customer routers, and is compared against the NSO LSA lab in the companion repo [nso-nokia-lsa-lab](https://github.com/mahdibani/nso-nokia-lsa-lab). The findings and the comparison are in [REPORT.md](REPORT.md).

## Requirements

- Windows 11 with WSL2 Ubuntu, and Docker Desktop with **WSL integration enabled for Ubuntu** (Settings → Resources → WSL integration).
- At least 4 CPUs and 8 GB RAM for Docker. The lab uses about 6.5 GB (4 SR Linux nodes at about 1.45 GB each).
- Internet access for the first run. It pulls `ghcr.io/nokia/srlinux:25.3.2` (3 GB), FRR, containerlab and the SORESPO binary.
- **No license needed.** The SR Linux container image is free, unlike the SR SIM that the NSO lab uses.

## 1. Get the code (WSL)

```bash
mkdir -p ~/stratoweave && cd ~/stratoweave
git clone https://github.com/stratoweave/sorespo.git
git clone https://github.com/stratoweave/stratoweave.git   # platform source + docs (reading only)
```

## 2. Deploy the topology

```bash
cd ~/stratoweave/sorespo/test/quicklab-srl
make -C ../../ download-release   # prebuilt sorespo binary (GitHub release "tip"), ~150 MB
make start                        # containerlab (run as a container) deploys 9 containers
make wait                         # waits until all 4 SR Linux PEs answer NETCONF (~17 s)
```

The upstream `make tutorial` runs `make run` in the foreground with a TTY. To run it in the background instead:

```bash
make copy
docker exec -d -w / sorespo-quicklab-srl-sweave sh -c '/sorespo >> /sorespo.stdout 2>&1'
#   add  --db /sw.lmdb  to keep intent across restarts (see REPORT.md, finding F6)
```

The Web UI and HTTP API are at <http://localhost:3000>. RESTCONF is at `/restconf`, and the API has **no authentication**.

## 3. Deploy the L3VPN and test traffic

```bash
make send-config-wait FILE=netinfra.xml     # routers, backbone links (IS-IS, iBGP EVPN)
make send-config-wait FILE=l3vpn-svc.xml    # RFC 8299 ietf-l3vpn-svc: 1 VPN, 4 sites
make test-ping                              # full mesh between the 4 CE loopbacks (12 pairs)
```

### Useful inspection calls

| What | Call |
|---|---|
| Intent (northbound) | `curl -H 'Accept: application/yang-data+json' localhost:3000/restconf/data` |
| One layer (0 CFS, 1 Inter, 2 RFS, 3 Device) | `curl -H 'Accept: application/yang-data+json' localhost:3000/layer/2` |
| What a router should have / has / the difference | `curl 'localhost:3000/device/AMS-CORE-1/target?format=xml'`, then `/running`, then `/diff` |
| Re-read a router and repair drift | `curl localhost:3000/device/AMS-CORE-1/resync` |
| Pending approvals | `curl localhost:3000/config-queue` |
| Approve or reject | `POST /device/<R>/q/<id>/set_approval` with `{"device_txid":"…","approved":true}` |
| Router CLI | `make cli-ams-core-1`, `make cli-cust-1` |

## 4. Run the benchmark

```bash
bash /mnt/c/Projects/stratoweave-nso-benchmark/bench.sh 5
```

This runs about 6 minutes and writes `results/bench-<timestamp>.txt`. It covers:
- the service lifecycle, 5 times: delete and redeploy, with timings to config and to traffic
- out-of-band drift
- the approval queue: approve, then reject
- an unreachable PE during a change
- an orchestrator restart, with and without `--db`
- memory and image sizes

The NSO-side numbers in REPORT.md come from the same machine, against `laboratoire/compose.yaml` from [nso-nokia-lsa-lab](https://github.com/mahdibani/nso-nokia-lsa-lab) (RESTCONF on 8090/8091).

## 5. Stop

```bash
cd ~/stratoweave/sorespo/test/quicklab-srl && make stop
```
