// ============================================================
// Azure Hybrid Network Lab — site-to-site VPN design (LAB ONLY)
// ============================================================
// LAB DESIGN. Nothing here touches a real subscription, a real
// on-premises network, or a real public IP. All on-prem values
// are TEST-NET-3 (RFC 5737) placeholders you replace with your own.

@description('Azure region for the deployment. Keep it close to you: eastus for Chicago.')
param location string = resourceGroup().location

@description('Public IP of the on-premises VPN device. PLACEHOLDER — replace with your real on-prem public IP at deploy time.')
param onPremPublicIp string = '203.0.113.10'

@description('On-premises address space reachable through the tunnel. PLACEHOLDER — replace with your real LAN range.')
param onPremAddressSpace array = [
  '192.168.0.0/16'
]

@description('IPsec pre-shared key. NEVER hardcode or commit a value. Pass at deploy time (--parameters sharedKey=...) or via a Key Vault reference.')
@secure()
param sharedKey string

var vnetName = 'vnet-hybrid-lab'
var gwPublicIpName = 'pip-vpngw-hybrid-lab'
var gwName = 'vpngw-hybrid-lab'
var lngName = 'lng-onprem-lab'
var connName = 'conn-onprem-lab'

// ------------------------------------------------------------
// NSGs — default-deny posture, explicit allow-list on top.
// Azure's built-in rules already deny stray inbound traffic at
// priority 65500, but we add an explicit DenyAllInbound rule so
// the intent is visible in review and in `az network nsg show`.
// ------------------------------------------------------------
resource nsgApp 'Microsoft.Network/networkSecurityGroups@2021-05-01' = {
  name: 'nsg-app'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowOnPremHttps'
        properties: {
          description: 'App tier: HTTPS from on-prem only (through the tunnel)'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '192.168.0.0/16'
          destinationAddressPrefix: '10.10.1.0/24'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowOnPremRdp'
        properties: {
          description: 'Management: RDP ONLY from on-prem through the tunnel — never from the internet'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '192.168.0.0/16'
          destinationAddressPrefix: '10.10.1.0/24'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          description: 'Explicit deny-all: everything not allow-listed above is dropped'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 4096
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource nsgData 'Microsoft.Network/networkSecurityGroups@2021-05-01' = {
  name: 'nsg-data'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowAppToSql'
        properties: {
          description: 'Data tier: SQL only from the app subnet — nothing else can reach it'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: '10.10.1.0/24'
          destinationAddressPrefix: '10.10.2.0/24'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          description: 'Explicit deny-all: everything not allow-listed above is dropped'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 4096
          direction: 'Inbound'
        }
      }
    ]
  }
}

// ------------------------------------------------------------
// VNet: 10.10.0.0/16
//  - GatewaySubnet 10.10.0.0/27  (reserved name required by Azure;
//    /27 is the recommended minimum, leaves room for active-active)
//  - snet-app     10.10.1.0/24   (web/app tier, NSG attached)
//  - snet-data    10.10.2.0/24   (data tier, NSG attached)
// Note: NSGs must NEVER be attached to GatewaySubnet — Azure
// blocks it and the deploy will fail if you try.
// ------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.10.0.0/27'
        }
      }
      {
        name: 'snet-app'
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: {
            id: nsgApp.id
          }
        }
      }
      {
        name: 'snet-data'
        properties: {
          addressPrefix: '10.10.2.0/24'
          networkSecurityGroup: {
            id: nsgData.id
          }
        }
      }
    ]
  }
}

// ------------------------------------------------------------
// VPN Gateway: VpnGw1, route-based, IKEv2.
// VpnGw1 = the lab sweet spot: ~1 Gbps aggregate, up to 30
// tunnels, BGP capable — without the VpnGw2+ price jump.
// (Full "why" in docs/architecture.md.)
// ------------------------------------------------------------
resource gwPublicIp 'Microsoft.Network/publicIPAddresses@2021-05-01' = {
  name: gwPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2021-05-01' = {
  name: gwName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'gwIpConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: gwPublicIp.id
          }
        }
      }
    ]
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    enableBgp: false
  }
}

// ------------------------------------------------------------
// Local Network Gateway: the on-prem side of the tunnel.
// gatewayIpAddress and addressPrefixes are placeholders —
// the deploy is meaningless until you set your real values.
// ------------------------------------------------------------
resource localNetworkGateway 'Microsoft.Network/localNetworkGateways@2021-05-01' = {
  name: lngName
  location: location
  properties: {
    gatewayIpAddress: onPremPublicIp
    localNetworkAddressSpace: {
      addressPrefixes: onPremAddressSpace
    }
  }
}

// ------------------------------------------------------------
// Site-to-site connection: IPsec/IKEv2 between the Azure VPN
// Gateway and the on-prem device. The shared key is a secure
// parameter — it exists only at deploy time, never in the file.
// ------------------------------------------------------------
resource vpnConnection 'Microsoft.Network/connections@2021-05-01' = {
  name: connName
  location: location
  properties: {
    virtualNetworkGateway1: {
      id: vpnGateway.id
    }
    localNetworkGateway2: {
      id: localNetworkGateway.id
    }
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
    routingWeight: 0
    sharedKey: sharedKey
  }
}

// ------------------------------------------------------------
// OPTIONAL test VM (COMMENTED OUT — costs money while running).
// Uncomment to spin up a small box in snet-app for end-to-end
// tunnel testing (ping/RDP from on-prem through the VPN).
// Remember: delete it (or the whole resource group) when done.
// ------------------------------------------------------------
/*
resource testVmNic 'Microsoft.Network/networkInterfaces@2021-05-01' = {
  name: 'nic-testvm-lab'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/snet-app'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource testVm 'Microsoft.Compute/virtualMachines@2021-07-01' = {
  name: 'vm-test-lab'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    osProfile: {
      computerName: 'vm-test-lab'
      adminUsername: 'azureuser'
      // Use SSH keys, not passwords, when you enable this.
      adminPassword: 'REPLACE-WITH-SECURE-VALUE'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: testVmNic.id
        }
      ]
    }
  }
}
*/

output vnetId string = vnet.id
output vpnGatewayId string = vpnGateway.id
output vpnGatewayPublicIp string = gwPublicIp.properties.ipAddress
output connectionStatus string = vpnConnection.properties.connectionStatus
