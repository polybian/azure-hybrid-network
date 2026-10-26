# Cost Notes: Azure Hybrid Network

> ⚠️ **All prices below are ESTIMATES**, based on published Azure list
> pricing (US regions, pay-as-you-go) as of late 2025. Azure changes prices;
> confirm current rates in the [Azure pricing
> calculator](https://azure.microsoft.com/pricing/calculator/) before you
> deploy. Nothing in this repo was deployed, so **no real spend exists**.

## Estimated costs (per month, running 24/7)

| Resource | SKU | Estimate | Notes |
|---|---|---|---|
| VPN Gateway | VpnGw1AZ | ~$140/mo (~$0.19/hr) | The big one. Billed hourly from the moment the gateway exists: **tunnel up or not**. |
| Gateway public IP | Standard, static | ~$3.65/mo (~$0.005/hr) | Required for the VPN Gateway. |
| Local Network Gateway | - | $0 | Free. It's just a config object. |
| Site-to-site connection | - | $0 | Free. You pay for the gateway, not the tunnel. |
| VNet / subnets / NSGs | - | $0 | Free (NSG flow logs would add storage cost if enabled). |
| Optional test VM (off by default) | Standard_B2s | ~$30/mo (~$0.042/hr) | Only if you uncomment it: and only while it's running/deallocated-but-kept. |

**Data transfer (egress):** traffic leaving Azure to the internet/on-prem is
metered, ESTIMATE ~$0.087/GB for the first 10 TB/mo in North America.
Inbound traffic is free. Test pings and RDP sessions barely register; don't
run bulk transfers through the tunnel for fun.

## Why this SKU stack

VpnGw1AZ is the cheapest gateway that is fully featured (zone-redundant,
IKEv2, BGP-capable). Stepping up to VpnGw2 roughly doubles the hourly cost
for throughput this design will never use; stepping down to Basic loses IKEv2 and
BGP. The optional VM is commented out in the template for the same reason
this whole design is built around one principle: **nothing should bill
while you're not looking at it.**

## Teardown reminder

**Delete the resource group when you're done:**

```bash
az group delete --name rg-hybrid --yes --no-wait
```

A VpnGw1AZ left running for a forgotten month costs ~$140. Set a calendar
reminder for the day after your test session if you think you'll forget. The
gateway takes 30–45 minutes to *create*: it takes one command to delete.
