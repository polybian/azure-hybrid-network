# Azure Hybrid Network — Site-to-Site VPN Design

A production-grade hybrid network design: an on-premises network (home infrastructure or branch-office
router) connected over an IPsec/IKEv2 site-to-site tunnel to an Azure virtual
network, with a classic three-tier layout — dedicated gateway subnet, an app
subnet and a data subnet, each protected by an explicit allow-list NSG. The
optional test VM stays commented out so the design costs nothing until you
actually deploy it.

**What this demonstrates:** hybrid cloud network design, Azure VPN Gateway
sizing, IPsec site-to-site connectivity, VNet/subnet planning, NSG
default-deny design, Bicep infrastructure-as-code, and the operational
discipline of secrets handling, cost awareness, and clean teardown.

```
                        ┌──────────────────────────────────────────────────┐
                        │                    AZURE                         │
                        │              10.10.0.0/16                        │
                        │                                                  │
   ON-PREM              │   ┌──────────────────────────────────────────┐   │
  (home network /         │   │  vpngw-hybrid (VpnGw1AZ)               │   │
   branch router)        │   │  GatewaySubnet  10.10.0.0/27             │   │
  192.168.0.0/16         │   └──────────────────┬───────────────────────┘   │
 ┌──────────────┐        │                      │                           │
 │ VPN device   │        │       ┌──────────────┴──────────────┐            │
 │ (placeholder │──IPsec/IKEv2──▶│                             │            │
 │ 203.0.113.10)│  site-to-site │                             │            │
 └──────────────┘   tunnel      ▼                             ▼            │
                        │  snet-app      + NSG          snet-data   + NSG   │
                        │  10.10.1.0/24  allow 443,    10.10.2.0/24 allow  │
                        │                3389 from      (SQL 1433 1433 from │
                        │                on-prem only    from app   app only)│
                        │                ──────────     ────────   ────────│
                        │  (optional test VM — commented out by default)   │
                        └──────────────────────────────────────────────────┘
```

## Repo layout

| Path | Purpose |
|---|---|
| `bicep/main.bicep` | The whole network as code: VNet + subnets, NSGs, VPN Gateway, Local Network Gateway, IPsec connection (test VM commented out) |
| `bicep/main.bicepparam` | Parameters file with placeholders (no secrets — the shared key is passed at deploy time) |
| `docs/architecture.md` | Design decisions, "why X over Y", and hardening notes |
| `docs/deployment-runbook.md` | Step-by-step deploy, tunnel verification, and teardown commands |
| `docs/cost-notes.md` | SKU price ranges (clearly labeled ESTIMATES) + teardown reminder |
| `.gitignore` | Keeps keys, secrets, and deploy-time artifacts out of git |

## Quick start

```bash
# 0. Prerequisites: an Azure subscription of your own + the Azure CLI
az login
az account set --subscription "<your-subscription-name>"

# 1. Resource group
az group create --name rg-hybrid --location eastus

# 2. Generate a strong pre-shared key (never commit it)
export PSK=$(openssl rand -base64 32)

# 3. Preview what will change (always what-if before deploy)
az deployment group what-if \
  --resource-group rg-hybrid \
  --template-file bicep/main.bicep \
  --parameters bicep/main.bicepparam \
  --parameters sharedKey="$PSK"

# 4. Deploy (the gateway takes ~30-45 min to provision)
az deployment group create \
  --resource-group rg-hybrid \
  --template-file bicep/main.bicep \
  --parameters bicep/main.bicepparam \
  --parameters sharedKey="$PSK"

# 5. Verify the tunnel
az network vpn-connection show \
  --name conn-onprem --resource-group rg-hybrid \
  --query "{status:connectionStatus, protocol:connectionProtocol}" -o table

# 6. When you're done — TEARDOWN (the gateway bills by the hour)
az group delete --name rg-hybrid --yes --no-wait
```

## Security notes

- **NSG default deny:** both subnet NSGs end with an explicit `DenyAllInbound`
  rule; everything above it is a narrow allow-list (on-prem → app on 443/3389,
  app → data on 1433).
- **No public management ports:** RDP/SSH are reachable only from the
  on-premises range *through the tunnel* — never from the internet. There is
  no public IP on any VM in this design.
- **Secrets are referenced, not embedded:** the IPsec pre-shared key is a
  `@secure()` Bicep parameter with no default value; in production it lives in
  Azure Key Vault and is passed as a Key Vault reference (see the runbook).
  No real IPs, subscription IDs, or tenant IDs appear anywhere in this repo —
  the on-prem values are TEST-NET-3 (`203.0.113.0/24`) placeholders.

## Validation

- **Compiled clean with the standalone Bicep CLI (v0.48.1):**
  `bicep build bicep/main.bicep` and `bicep build-params
  bicep/main.bicepparam` both succeed; the generated ARM JSON and
  parameters JSON were re-validated with `python3 -m json.tool`. The
  parameters compile to a Key Vault *reference* for the shared key — no
  secret value exists in any file. Two non-blocking `BCP035` warnings
  remain on the `connections` resource: a known type-definition
  inaccuracy for its gateway sub-references (id-only is the standard
  shape for this resource); they do not block deployment.
- **NOT deployed:** this design was created and compiled locally with
  no Azure CLI, no subscription, and no credentials, so the actual
  deployment was **not** tested. The steps in
  `docs/deployment-runbook.md` are for the user's own Azure subscription.
- To fully validate on your own subscription: deploy (runbook step 5),
  confirm `connectionStatus == Connected` (step 7), pass traffic from
  on-prem to `10.10.1.x`, and watch the tunnel counters move. Then tear it
  down — `az group delete --name rg-hybrid`.
