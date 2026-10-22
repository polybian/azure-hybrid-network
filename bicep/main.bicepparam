// Parameters file for the Azure Hybrid Network implementation.
// TEST ONLY — every value here is a placeholder (TEST-NET-3 / RFC 5737
// style). Replace with your own on-prem details at deploy time.
//
// The IPsec pre-shared key is NOT in this file. It is read at deploy
// time from Azure Key Vault via az.getSecret() (see the runbook, step 3,
// for creating the vault and storing the secret). Replace the placeholder
// subscription ID below with your own before deploying — or bypass the
// vault entirely by overriding at the CLI:
//   az deployment group create ... --parameters sharedKey="$PSK"

using './main.bicep'

param location = 'eastus'
param onPremPublicIp = '203.0.113.10'
param onPremAddressSpace = [
  '192.168.0.0/16'
]
// Key Vault reference — placeholder subscription ID (all zeros) on purpose.
param sharedKey = az.getSecret('00000000-0000-0000-0000-000000000000', 'rg-hybrid', 'kv-hybrid', 'vpn-psk')
