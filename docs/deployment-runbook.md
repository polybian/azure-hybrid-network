# Deployment Runbook: Azure Hybrid Network

> **NOTE.** This runbook assumes an Azure subscription of your own. None of
> this was executed from the machine where the template was written. On-prem
> values (`203.0.113.10`, `192.168.0.0/16`) are placeholders: replace them
> with your real on-prem router's public IP and LAN range.

## Prerequisites

- Azure CLI installed (`az --version`)
- An Azure subscription you control
- Bicep CLI: `az bicep install` (one-time; the `az deployment` commands
  below compile Bicep transparently once it's installed)
- Your on-prem VPN device (on-prem router, pfSense/OPNsense box, or a Linux box
  running strongSwan) reachable from the internet with UDP 500/4500 open

## Step 1: Sign in and select the subscription

```bash
az login
az account list -o table
az account set --subscription "<your-subscription-name>"
```

## Step 2: Create the resource group

```bash
az group create --name rg-hybrid --location eastus
```

Keep everything in this one resource group. That's what makes teardown a
single command later.

## Step 3: Generate the pre-shared key (handle with care)

```bash
export PSK=$(openssl rand -base64 32)
echo "$PSK" > /tmp/hybrid-psk.txt   # delete this file after the deploy
chmod 600 /tmp/hybrid-psk.txt
```

**Better (production pattern):** store it in Key Vault instead of a file.
`--enabled-for-template-deployment` is required so ARM can resolve the
Key Vault reference in the parameters file at deploy time:

```bash
az keyvault create --name kv-hybrid --resource-group rg-hybrid --location eastus \
  --enabled-for-template-deployment true
az keyvault secret set --vault-name kv-hybrid --name vpn-psk --value "$PSK"
```

Then put your real subscription ID into `bicep/main.bicepparam` (it ships
with an all-zeros placeholder) so `sharedKey` resolves from the vault:

```bash
az account show --query id -o tsv   # paste this into main.bicepparam
```

(If you'd rather skip the vault for a quick test run, the deploy commands
below pass `--parameters sharedKey="$PSK"` instead: the CLI value overrides
the parameters file.)

## Step 4: Preview with what-if (always, before deploy)

```bash
az deployment group what-if \
  --resource-group rg-hybrid \
  --template-file bicep/main.bicep \
  --parameters bicep/main.bicepparam \
  --parameters onPremPublicIp="<YOUR-REAL-ONPREM-PUBLIC-IP>" \
  --parameters onPremAddressSpace='["<YOUR-REAL-ONPREM-LAN>"]' \
  --parameters sharedKey="$PSK" \
  --parameters vmSshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

Review the change list: 1 VNet, 3 subnets, 2 NSGs, 1 public IP, 1 gateway,
1 local network gateway, 1 connection. No surprises = proceed.

## Step 5: Deploy

```bash
az deployment group create \
  --resource-group rg-hybrid \
  --template-file bicep/main.bicep \
  --parameters bicep/main.bicepparam \
  --parameters onPremPublicIp="<YOUR-REAL-ONPREM-PUBLIC-IP>" \
  --parameters onPremAddressSpace='["<YOUR-REAL-ONPREM-LAN>"]' \
  --parameters sharedKey="$PSK" \
  --parameters vmSshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

**The VPN Gateway takes ~30–45 minutes to provision.** This is normal: Azure
is standing up dedicated gateway infrastructure. The `create` command will
wait. Go get coffee.

## Step 6: Configure the on-prem side

On your on-prem router / strongSwan box, create the matching IPsec tunnel:

- Remote peer: the gateway's public IP
  (from deploy outputs: `az deployment group show ... --query properties.outputs`)
- IKEv2, route-based, pre-shared key = the `$PSK` you generated
- Remote networks: `10.10.0.0/16`
- Local networks: your on-prem LAN (the range you put in the LNG)

## Step 7: Verify the tunnel

```bash
# Connection status - you want "Connected"
az network vpn-connection show \
  --name conn-onprem --resource-group rg-hybrid \
  --query "{status:connectionStatus, protocol:connectionProtocol}" -o table

# What the gateway learned from on-prem (static here, via the LNG)
az network vnet-gateway list-learned-routes \
  --name vpngw-hybrid --resource-group rg-hybrid -o table

# End-to-end: from on-prem, ping an address in snet-app (e.g. 10.10.1.4
# once you enable the optional test VM), or RDP through the tunnel.
```

If status sticks at `Connecting`/`NotConnected`, see the troubleshooting notes below (IKE logs, PSK match, prefix match).

## Step 8: Teardown (do not skip)

The gateway bills by the hour **whether the tunnel is up or not**. When the
test session is over:

```bash
az group delete --name rg-hybrid --yes --no-wait
```

Verify it's gone:

```bash
az group show --name rg-hybrid  # should error: not found
```

Deleting the whole resource group also removes the Key Vault (if you created
one inside it), which is what you want for a test environment.

## Re-deploying later

Re-run steps 2–5. Generate a **fresh** PSK each time (don't reuse the old
one) and update the on-prem device to match.
