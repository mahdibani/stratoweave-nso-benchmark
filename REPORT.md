# StratoWeave vs Cisco NSO: evaluation report

*Lab evaluation of 15 November 2026. Every measurement was taken on the same machine: 20 CPUs, 15.5 GB RAM, Windows 11, WSL2, Docker Desktop 29.8. The NSO side is the lab from [nso-nokia-lsa-lab](https://github.com/mahdibani/nso-nokia-lsa-lab) (upper NSO → lower NSO → Nokia SR SIM). The MCP server is deliberately left out of the comparison.*

## 1. Summary

| | Cisco NSO 6.1.21 (our lab) | StratoWeave / SORESPO (tested) |
|---|---|---|
| License and cost | Commercial, per-device licensing. NEDs are commercial too. | **Open source, BSD-3-Clause** (LF Networking, code © Deutsche Telekom) |
| Ran end to end here? | NSO side yes. **The router no** (SR SIM license expired). | **Yes**: 4 PEs + 4 CEs, L3VPN deployed, **12/12 sites forwarding** |
| Router OS | Nokia **SR OS** (SR SIM, needs a license) | Nokia **SR Linux** (free image), plus Cisco IOS-XR and Juniper cRPD |
| Change safety | **Atomic across all devices**, `dry-run` on both layers, rollback | **Per-device** transactions, eventual convergence, no dry-run. Optional **per-device approval queue** with a diff. |
| Maturity | 10+ years, carrier production | First formal release **26.10** (23 Oct 2026). Very active (2,159 commits), small team (4 main authors). |

**Verdict.**
- **StratoWeave is a credible open-source alternative for a lab or proof of concept.** It installs with one `make`, needs no license, reuses standard models (RFC 8299 `ietf-l3vpn-svc`), deploys a 4-PE L3VPN in about 2.4 s, and repairs drift on request.
- **It is not yet a drop-in replacement for NSO in production**, for three reasons:
  1. It has no cross-device transaction and no dry-run.
  2. Rejecting a change in the approval queue leaves the intent and the network silently out of step.
  3. It has no authentication on its HTTP/RESTCONF API.
- **It does not support our router.** SORESPO targets SR Linux. SR OS is supported only for reading platform information, so porting the Orange `i2s` L3VPN means writing a new SR OS device type and new transforms in **Acton**, and it would still need an SR SIM license.

## 2. What StratoWeave is

- **What:** an "intent-based network orchestration" platform. It is an LF Networking project, licensed BSD-3-Clause, with the copyright held by Deutsche Telekom AG. Sources: [stratoweave.org](https://www.stratoweave.org/), [github.com/stratoweave/stratoweave](https://github.com/stratoweave/stratoweave).
- **Language: [Acton](https://www.acton-lang.org/)**, an actor-based compiled language. YANG models are compiled into Acton types, and the orchestrator ships as **one static binary** (`sorespo`, 144 MB).
- **Reference implementation: [SORESPO](https://github.com/stratoweave/sorespo)** ("SOmewhat REalistic Service Provider Orchestrator"). It does IP transport and L3VPN on Nokia SR Linux, Cisco IOS-XR and Juniper cRPD.
- **Architecture: layered pure transforms**, with the same CFS/RFS idea as NSO:

  | Layer | Name | What lives there |
  |---|---|---|
  | 0 | CFS | `netinfra` (routers, backbone links) + **RFC 8299 `ietf-l3vpn-svc`** |
  | 1 | Inter | Derived: loopbacks, iBGP mesh, per-VPN VRFs and endpoints |
  | 2 | RFS | One entry per device: `vrf`, `vrf-interface`, `ebgp-customer`, … |
  | 3 | Device | Vendor YANG (`urn:nokia.com:srlinux:…`), pushed over NETCONF |

  Each transform is a **pure function** from input to output. The platform recomputes the output whenever the input changes and **replaces** what the transform wrote before. Creating, updating and deleting are therefore all the same code path, comparable to NSO FASTMAP.
- **Northbound:** RESTCONF, NETCONF (port 830), TMF 633/640/641 APIs, a Web UI, and an HTTP inspection API (`/layer/N`, `/device/X/{target,running,diff,resync,q}`).
- **Southbound:** NETCONF, with adapters generated from device YANG; SNMP, generated from MIBs; an IOS-XE CLI adapter. gNMI is mentioned on the website, but I found no gNMI southbound code.
- **Activity, measured from git:**
  - `stratoweave`: 2,159 commits, last one 14 Nov 2026, tag `v26.10`.
  - `sorespo`: 1,128 commits, last one 22 Oct 2026.
  - Authors in 2026: Kristian Larsson 667 commits, Marko Zagožen 353, Blaž Dolenc 205+, Johan Nordlander 121, plus a few others.
  - GitHub: 37 stars, 76 open issues.

## 3. Test setup

| | NSO lab ([nso-nokia-lsa-lab](https://github.com/mahdibani/nso-nokia-lsa-lab)) | StratoWeave quicklab-srl |
|---|---|---|
| Orchestrator | 2 × `cisco-nso-prod:6.1.21` (upper CFS + lower RFS, LSA) | 1 × `sorespo` binary in a Debian container |
| Network | 1 × Nokia SR SIM 25.10.R2 (SR OS) | 4 × Nokia SR Linux 25.3.2 PEs + 4 × FRR 10.3.1 CEs (containerlab 0.78) |
| Service | Orange `i2s-cfs-l3vpn` → `i2s-rfs-l3vpn` (proprietary model) | RFC 8299 `ietf-l3vpn-svc`: 1 VPN (`acme-65501`), 4 sites, BGP-EVPN/VXLAN core, eBGP PE–CE |
| Deployed by | `docker compose -f laboratoire/compose.yaml up -d` | `make start` + `make copy` + run `sorespo` |

## 4. Functional tests (StratoWeave)

| # | Test | Result |
|---|---|---|
| T0 | Deploy infra + L3VPN, ping full mesh | ✅ 12/12 CE↔CE pairs forward, and the eBGP PE–CE sessions are `established` |
| T1 | Drift: disable a customer sub-interface by hand on LJU-CORE-1 | ⚠️ **Not detected automatically** (`/diff` still said "No differences" 10 s later). ✅ `GET /device/LJU-CORE-1/resync` detected it and pushed the intent back in about 0.5 s, and traffic came back. |
| T2 | Approval queue: `approval-required=true` on LJU, then delete SITE-4 | ✅ The change was held, and the pending **NETCONF diff** was shown (9 lines, `xc:operation="remove"` on the interface, VRF and VXLAN tunnel). Traffic stayed up until approval, then the change applied in about 0.5 s. |
| T2b | Re-add SITE-4, then **reject** it | ❌ The intent keeps SITE-4, but the router never gets it. `/diff` says "No differences", there is no error, and turning approval off, a resync, or re-sending the same intent do **not** fix it. The only workaround is to delete the site and add it again (finding F2). |
| T3 | Delete all 4 sites while LJU is frozen (`docker pause`) | ⚠️ HTTP **204 success** in 4 ms. The 3 reachable PEs changed immediately, and LJU queued the change (`queue_length 1`). **There is no rollback.** LJU converged 0.5 s after it came back. |
| T3b | Synchronous redeploy with LJU frozen | ⚠️ The "wait" PATCH blocks until every device finishes (client timed out at 20 s) while the other PEs are already configured. LJU caught up 0.45 s after coming back, and traffic was 12/12. |
| T4 | Restart the orchestrator **without** `--db` | ⚠️ All intent is lost (`{"devices":[]}`). The routers keep their config but are no longer managed. |
| T4b | Restart **with** `--db` (LMDB) | ✅ Intent and devices come back, and the API is up in 0.17–0.30 s. ❌ **Bug:** every router then shows a permanent false diff, because the IS-IS `net` leaf-list entry is duplicated in the target (finding F3). |
| T5 | Change `svc-mtu` or `customer-name` | ⚠️ Accepted, but **not mapped** to device config by SORESPO: the reference implementation covers only part of RFC 8299 (finding F4). |

## 5. Benchmark

### 5.1 StratoWeave service lifecycle (5 runs, 4 PEs)

Source: [`results/bench-20261115-234001.txt`](results/bench-20261115-234001.txt), produced by `bench.sh 5`.

| Metric | avg | min | max |
|---|---|---|---|
| Delete all 4 sites → VRF gone on all PEs | **2.14 s** | 1.89 | 2.35 |
| Deploy: synchronous `PATCH` returns | **0.43 s** | 0.38 | 0.50 |
| Deploy: VRF present on all 4 PEs | **2.43 s** | 2.21 | 2.69 |
| Deploy: **12/12 CE pairs forwarding** | **14.7 s** | 13.8 | 15.9 |

The rendered device config is 256–284 XML lines per PE, generated from a 208-line RFC 8299 intent for 4 sites.

The "VRF present" and "VRF gone" numbers include about 1.5 s of measurement overhead, because 4 sequential `docker exec sr_cli` polls run per sample. Measured from the API side, the first deploy converged (`target == running` on all 4 PEs) in 2.3 s for the infrastructure and 3.1 s for the L3VPN. The time to traffic is dominated by eBGP and EVPN convergence on the routers, not by the orchestrator.

| Other measurement (same run) | Result |
|---|---|
| Drift repair (`resync` → router fixed) | **0.48 s**. Traffic is back 10.3 s later (eBGP re-establishes). |
| Approval → applied on the router | **0.48 s** |
| Unreachable PE catches up after it returns | **0.53–0.55 s** |
| Orchestrator restart → API up | **0.27–0.30 s** |
| `sorespo` memory (RSS) | **300 MiB** |
| SR Linux PE memory | **1,439–1,469 MiB** each. FRR CE: 34 MiB |

### 5.2 Side by side (same machine)

| Metric | NSO lab | StratoWeave |
|---|---|---|
| Preview a service change | `?dry-run=cli` on **both** layers: **0.50 s** avg (0.39–0.74, n=5) | No dry-run. A preview exists only through the approval queue, per device, **after** the intent is stored |
| Deploy a service to the network | Not measurable: SR SIM license expired. The commit failed with HTTP 400 in 3.5 s and was **rolled back atomically** (the service was not stored) | **2.4 s** to 4 PEs, **14.7 s** to traffic |
| Failure while pushing to devices | All-or-nothing: rollback on every device and in both NSOs | Partial: reachable devices change, the rest converge later |
| Orchestrator restart | Upper NSO: RESTCONF **2.7 s**, healthy 6.9 s (packages already compiled) | **0.27–0.30 s**. Without `--db` the intent is lost; with `--db` it persists, but see F3 |
| Orchestrator memory | upper **612 MiB** + lower **971 MiB** = 1.58 GiB | **300–380 MiB** (one process, 4 devices) |
| Router memory | SR SIM: 4.12 GB image, license required | SR Linux: **≈1.45 GiB per PE**, 3.06 GB image, free |
| Orchestrator image | `cisco-nso-prod` **3.35 GB** (×2 containers) | `sorespo` binary **144 MB** + Debian base = **422 MB** |
| Time to a working lab from scratch | Hours: load images, compile packages, configure devices, 3 `.cli` files | **About 3.5 min**: `make start` with pulls (3 min 8 s), then the routers are ready in 17 s and the service is deployed in 2–3 s |
| Hand-written service code | Orange L3VPN: YANG 643 lines + Python 85 + XML templates 1,218 = **about 1,950** | SORESPO: transforms 917 lines of Acton + custom YANG 596 = **about 1,510**, reusing standard RFC 8299 (2,788 lines) |

## 6. Feature comparison

| Area | Cisco NSO | StratoWeave | Advantage |
|---|---|---|---|
| Service modeling | YANG + Python/Java + XML templates, FASTMAP | YANG + pure Acton transforms, recomputed on change | Tie: same idea, different tooling |
| Standard models | Possible, but our service is proprietary (`i2s-cfs-l3vpn`) | SORESPO uses **IETF RFC 8299** out of the box | **StratoWeave** |
| Hierarchical orchestration | **LSA**: separate upper and lower NSO instances, dispatch-map | Layers inside **one** process (unlimited layers), with no multi-instance split | **NSO** at scale; StratoWeave is simpler |
| Transactions | Network-wide ACID, across devices and LSA nodes | Per-device NETCONF transaction (candidate / confirmed-commit) | **NSO** |
| Dry-run / simulation | `dry-run` cli / native / xml, through LSA | **None**. Approval queue diff per device, **after** the intent is stored | **NSO** |
| Rollback | Rollback files, `rollback configuration` | None for config (rollback exists only for software upgrades) | **NSO** |
| Human approval | Not built in; commit queue + custom code (our MCP project added it) | **Built in**: `approval-required` per device, queue API + Web UI | **StratoWeave** |
| Drift | `check-sync`, `compare-config`, `sync-to`, `re-deploy` | `/diff`, `/resync` (repairs), `sync-check` before edits. Not continuous out of the box | Tie; StratoWeave repairs in one call |
| Reactive / closed loop | Kickers, external | **Native**: transforms subscribe to telemetry (YANG-push) | **StratoWeave** |
| Northbound | NETCONF, RESTCONF, CLI, JSON-RPC, Web UI, **with AAA/NACM** | RESTCONF, NETCONF, TMF 633/640/641, Web UI. **The HTTP API has no authentication** | **NSO** (security); StratoWeave adds TMF |
| Southbound | Hundreds of commercial NEDs (CLI, NETCONF, SNMP…) | NETCONF adapters **generated** from device YANG, SNMP, IOS-XE CLI | **NSO** breadth; StratoWeave has no NED cost |
| **Nokia SR OS** (our router) | Our NETCONF NED `ned_nokia_srsim` | **Platform probe only** (version, chassis). No SORESPO config support | **NSO** |
| Nokia SR Linux | Needs a NED | **Supported** (reference platform) | **StratoWeave** |
| Persistence / HA | CDB, HA clustering | LMDB with `--db` (off by default), with a bug after reload (F3) | **NSO** |
| Skills needed | Python/Java + YANG, widely known | **Acton**: a niche language, small community | **NSO** |
| Cost / lock-in | Licenses, vendor lock-in | Free, BSD-3, vendor-neutral | **StratoWeave** |
| Support / maturity | Cisco TAC, large community | First release Oct 2026, 4 core devs, 76 open issues | **NSO** |

## 7. Findings (issues seen in StratoWeave)

| ID | Severity | Finding | Evidence |
|---|---|---|---|
| F1 | High | **No atomicity across devices.** A change that touches 4 PEs succeeds on the reachable ones and returns `204`, while the unreachable one converges later. There is no rollback. | T3 |
| F2 | High | **Rejecting a queued change leaves the intent and the network inconsistent, with no signal.** The intent says SITE-4 exists, the router doesn't have it, and `/diff` (target vs running) says "No differences". Turning approval off, `resync` and re-sending the intent don't help. You have to delete and re-add. | T2b |
| F3 | Medium | **False permanent drift after a restart from `--db`.** The target holds the IS-IS `net` leaf-list entry twice, the router once, and `resync` doesn't clear it. It breaks drift monitoring after any restart. | T4b. sorespo binary from the `tip` release, 11 Nov 2026 |
| F4 | Low | **Only part of RFC 8299 is mapped** (`svc-mtu`, `customer-name` and others are ignored). | T5, `src/sorespo/inter.act` |
| F5 | Medium | **The synchronous `PATCH` blocks** until every device is done, including devices waiting for human approval or unreachable. Use `Async: true` and poll. | T2, T3b |
| F6 | Medium | **State is not persistent by default.** Without `--db`, a restart forgets every service, and the routers keep orphaned config. | T4 |
| F7 | High (prod) | **No authentication** on the HTTP/RESTCONF API (port 80). The lab binds it to `127.0.0.1` for this reason. | `test/common/clab.mk` |
| F8 | Info | **Drift is not detected without a resync** (no continuous polling seen within 10 s). | T1 |

F2 and F3 are reproducible with `bench.sh` and are worth reporting upstream as GitHub issues.

## 8. Could we move our Orange L3VPN to StratoWeave?

What it would take:

1. **An SR OS device type.** Add Nokia SR OS (`nokia-conf` / `nokia-state`, 2023-04-14, 36 MB of YANG) as a device type in the system spec, then generate its adapter. Only a platform probe exists today. The size of `nokia-conf` (20 MB) is untested with the YANG→Acton generator, so this is the main technical risk.
2. **Port the model.** Port `i2s-cfs-l3vpn` to CFS YANG, or better, map Orange's fields onto RFC 8299 + `netinfra`.
3. **Rewrite the logic.** Rewrite 1,218 lines of NSO XML templates plus Python as Acton transforms (CFS → Inter → RFS → SR OS device).
4. **The SR SIM license is still required.** StratoWeave changes the orchestrator, not the router.

Rough effort: **several weeks** for one person new to Acton. Faster alternative for the project: keep NSO for the Orange packages, and use StratoWeave + SR Linux as an open-source comparison lab. That is the deployment done here.

## 9. Recommendation

- **For the academic project:**
  - Present StratoWeave as the open-source counterpart, built on the same CFS/RFS principle.
  - Show the working demo (section 10). It is the only end-to-end, data-plane-verified L3VPN in the project so far, because the NSO lab's router is blocked by its license.
  - Present the transaction-safety gaps (F1, F2) as the reason NSO remains the production reference.
- **For production:** NSO, for now. Re-evaluate StratoWeave after a few releases, specifically for:
  - cross-device transactions or a dry-run
  - API authentication
  - SR OS config support
  - fixes for F2 and F3

## 10. Reproduce

See [README.md](README.md). Short version:

```bash
cd ~/stratoweave/sorespo/test/quicklab-srl
make -C ../../ download-release && make start && make copy
docker exec -d -w / sorespo-quicklab-srl-sweave sh -c '/sorespo >> /sorespo.stdout 2>&1'
make wait && make send-config-wait FILE=netinfra.xml && make send-config-wait FILE=l3vpn-svc.xml
make test-ping
bash /mnt/c/Projects/stratoweave-nso-benchmark/bench.sh 5
```
