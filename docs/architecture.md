# Architecture & Design Decisions

## Topology

- **Azure side:** one VNet `10.10.0.0/16` with three subnets:
  - `GatewaySubnet` — `10.10.0.0/27`. The name is mandatory (Azure reserves
    it for the gateway). `/27` is the recommended minimum: it leaves enough
    addresses for high-availability/active-active gateway configs later
    without resizing the subnet.
  - `snet-app` — `10.10.1.0/24` (app tier, ~251 usable addresses).
  - `snet-data` — `10.10.2.0/24` (data tier, ~251 usable addresses).
  - A /24 per workload tier is deliberately roomy: it absorbs growth without
    renumbering and keeps the address plan human-readable.
- **On-prem side:** represented by a Local Network Gateway — the on-prem VPN
  device's public IP (`203.0.113.10`, a TEST-NET-3 placeholder) plus its LAN
  range (`192.168.0.0/16`, placeholder). Azure pushes these prefixes into the
  gateway's effective routes.
- **The tunnel:** one IPsec/IKEv2 site-to-site connection between the Azure
  VPN Gateway and the on-prem device, authenticated with a pre-shared key.
- **Security:** an NSG on each workload subnet, explicit deny-all at the
  bottom, narrow allow-lists above.

## Design decisions

### VPN Gateway SKU: VpnGw1 — and why

The gateway is the single most expensive line item, so the SKU choice matters:
- **VpnGw1** (~1 Gbps aggregate, up to 30 S2S tunnels, BGP-capable, zone
  redundancy in supported regions) is the lab sweet spot. It's the smallest
  SKU that is still fully featured — zone-redundant, IKEv2, custom IPsec
  policies — without paying the VpnGw2+ premium for throughput a lab will
  never use.
- **Why not Basic?** The Basic SKU is cheaper but caps out at 100 Mbps,
  supports only IKEv1 for S2S, and can't do BGP or active-active. For a
  portfolio piece demonstrating current best practice, that's the wrong
  message.
- **Why not VpnGw2/3/4/5?** Each step roughly doubles the hourly cost for
  1.25–10 Gbps throughput. A lab tunnel carrying test pings and RDP doesn't
  need it; if the workload grows, the SKU is upgradeable in place (with a
  brief gateway resize window).

### Route-based VPN, IKEv2

Route-based (as opposed to policy-based) gateways route on IP prefixes rather
than per-tunnel traffic selectors. That means: multiple tunnels, overlapping
use of BGP later, and simpler troubleshooting (`get effective routes` shows
the actual programmed prefixes). IKEv2 is the current standard — faster
rekeying and better NAT-traversal behavior than IKEv1.

### BGP vs static routes: static here, BGP documented

This design uses **static routes** — the on-prem prefixes live in the Local
Network Gateway definition. Reasoning:
- One tunnel, one on-prem site, stable prefixes: static is simpler to read,
  simpler to debug, and has no BGP session to flap.
- The failure mode is honest: if the on-prem LAN renumbers, you update the
  LNG (one parameter) instead of debugging a BGP peering.

BGP would be the right call with: multiple on-prem sites, redundant tunnels
(active-active gateway), or dynamic branch prefixes. The gateway SKU chosen
(VpnGw1) already supports BGP, so enabling it later is a config change, not a
rebuild — that's a deliberate part of the design.

### Subnet sizing

- `GatewaySubnet /27`: Azure requires a gateway subnet and recommends /27 or
  larger. Going smaller (/28, /29) blocks future active-active or
  ExpressRoute-gateway coexistence. It's cheap address space — spend it.
- `/24` workload subnets: standard tier-per-subnet layout. The address plan
  leaves `10.10.3.0/24`+ free for future tiers (e.g. `snet-mgmt` for a jump
  host, `snet-private-endpoints` for Private Link) without overlapping the
  on-prem `192.168.0.0/16`.

### NSG rule design

- **Default-deny posture, explicit and visible.** Azure's built-in
  `DenyAllInBound` (priority 65500) already drops stray traffic, but this
  design adds an explicit `DenyAllInbound` at priority 4096. Why: it's
  visible in review, it shows up in flow-log analysis without ambiguity, and
  in an interview you can point at it and explain your intent.
- **Allow-lists are minimal and directional:** on-prem may reach the app tier
  only on 443 (app traffic) and 3389 (management *through the tunnel* — never
  from the internet). The data tier accepts only 1433 from the app subnet.
  Nothing else crosses subnet boundaries.
- **Priorities are spaced (100, 110, …, 4096):** room to insert rules later
  without renumbering.

### Private DNS

Azure provides name resolution at `168.63.129.16` by default, which resolves
VM hostnames within the VNet. For a real hybrid deployment you'd add a
**Private DNS zone** (e.g. `privatelink` zones or a custom
`corp.internal` zone) linked to the VNet, with conditional forwarders on the
on-prem DNS pointing Azure-bound queries at a DNS forwarder in `snet-app`
(or Azure DNS Private Resolver). This design documents the pattern but
doesn't deploy it — DNS infrastructure is a second lab, not a footnote.

## Why X over Y: VPN Gateway vs ExpressRoute vs Virtual WAN

| Option | When it wins | Why not here |
|---|---|---|
| **VPN Gateway (S2S)** | Lab, small branch, cloud-first org, budget-sensitive | — (this is the pick) |
| **ExpressRoute** | Predictable latency/throughput, compliance needs, heavy data transfer | Private circuit, $300+/mo port + provider fees, weeks to provision — the opposite of a lab |
| **Virtual WAN** | Many branches, global footprint, SD-WAN integration | Management-plane overhead for one tunnel; the hub alone costs more than VpnGw1 |

The honest framing: VPN Gateway is the right *first* hybrid link. If the org
outgrows it (dozens of sites, SLA-backed latency), ExpressRoute or vWAN is a
migration, not a regret — the VNet/NSG/subnet design survives unchanged.

## Hardening notes

- **No public management surface:** no public IPs on workload VMs; RDP/SSH
  only through the tunnel. In production, replace even that with Azure
  Bastion or just-in-time VM access.
- **Shared key hygiene:** 32+ random bytes, stored in Key Vault, rotated on a
  schedule; the template's `@secure()` parameter guarantees the key never
  lands in the template, the parameters file, or deployment logs in plaintext.
- **Gateway diagnostics:** in production, enable diagnostic settings on the
  gateway (TunnelDiagnosticLog, IKEDiagnosticLog) shipping to Log Analytics —
  that's how you see Phase 1/Phase 2 failures instead of guessing.
- **NSG flow logs:** enable on both NSGs to a storage account for forensic
  review of denied traffic.
- **On-prem side:** the tunnel is only as strong as the device terminating
  it — keep its firmware patched and its PSK out of chat/email/tickets.
- **LNG hygiene:** keep the Local Network Gateway's address prefixes tight
  (only what on-prem actually owns); over-broad prefixes black-hole traffic
  that should have gone to the internet.
