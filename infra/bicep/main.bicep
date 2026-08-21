targetScope = 'resourceGroup'

@description('Short workload name used in resource names.')
param workloadName string = 'finops'

@description('Deployment environment label.')
param environmentName string = 'prod'

@description('Azure region for resources.')
param location string = resourceGroup().location

@description('Azure cloud technical value passed to the Function app.')
@allowed([
  'AzureCloud'
  'AzureUSGovernment'
])
param finOpsAzureCloud string = 'AzureCloud'

@description('Authentication mode used by the FinOps ingestion runtime. ManagedIdentity is the preferred production default.')
@allowed([
  'ManagedIdentity'
  'ServicePrincipal'
])
param finOpsAuthMode string = 'ManagedIdentity'

@description('Tenant ID used by the FinOps ingestion runtime.')
param finOpsTenantId string

@description('Comma-separated subscription IDs to ingest.')
param finOpsSubscriptionIds string

@description('Client/application ID used only when finOpsAuthMode is ServicePrincipal.')
param finOpsClientId string = ''

@description('Optional Key Vault secret URI for FINOPS_CLIENT_SECRET when finOpsAuthMode is ServicePrincipal. Example: https://vault.vault.azure.net/secrets/finops-client-secret/version')
param finOpsClientSecretKeyVaultSecretUri string = ''

@description('Timer trigger NCRONTAB schedule, UTC.')
param finOpsTimerSchedule string = '0 0 6 * * *'

@description('SQL logical server name. Must be globally unique.')
param sqlServerName string

@description('SQL database name.')
param sqlDatabaseName string = 'FinOpsMaccRetail'

@description('SQL schema name used by the FinOps tables.')
param sqlSchemaName string = 'finops'

@description('SQL Database compute tier. GeneralPurpose Serverless is recommended for small deployments.')
@allowed([
  'GP_S_Gen5_1'
  'GP_Gen5_2'
  'GP_Gen5_4'
  'BC_Gen5_2'
])
param sqlSkuName string = 'GP_S_Gen5_1'

@description('SQL Database max size in bytes. Default is 10 GB.')
param sqlMaxSizeBytes int = 10737418240

@description('Enable public network access for SQL server. Use false when using private endpoint/network integration.')
param sqlPublicNetworkAccessEnabled bool = true

@description('Optional client IP to allow through SQL firewall. Leave empty to skip firewall rule.')
param sqlAllowedClientIp string = ''

@description('Optional Microsoft Entra SQL admin display/login name.')
param sqlEntraAdminLogin string = ''

@description('Optional Microsoft Entra SQL admin object ID.')
param sqlEntraAdminObjectId string = ''

@description('Function App service plan SKU. Y1 is classic consumption. Use EP1 or another Premium/Dedicated SKU when enablePrivateNetworking=true.')
param functionPlanSkuName string = 'Y1'

@description('Function runtime PowerShell version.')
param functionPowerShellVersion string = '7.6'

@description('Application Insights retention in days.')
param appInsightsRetentionDays int = 90

@description('Enable Azure Monitor scheduled-query alerts for FinOps Function failures and missed successful runs.')
param enableMonitoringAlerts bool = false

@description('Optional email address for alert notifications. Leave empty to deploy alert rules without an action group.')
param alertNotificationEmail string = ''

@description('How often Azure Monitor evaluates FinOps ingestion log alerts.')
param alertEvaluationFrequency string = 'PT15M'

@description('Evaluation window used by the failed-run alert.')
param alertWindowSize string = 'PT15M'

@description('How many hours without a successful FinOps run should trigger the missed-run alert.')
param missedRunAlertWindowHours int = 36

@description('Create a VNet, a NAT Gateway for static Function outbound egress, a Function App private endpoint (inbound lockdown), and route Function outbound traffic through the VNet. Requires a Function plan that supports regional VNet integration, such as EP1. Azure SQL stays on public networking and is firewalled by IP (see sqlAllowedClientIp) rather than given a private endpoint.')
param enablePrivateNetworking bool = false

@description('Virtual network address prefix used when private networking is enabled.')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Subnet prefix for Function regional VNet integration. This subnet is delegated to Microsoft.Web/serverFarms and egresses through the NAT Gateway.')
param functionIntegrationSubnetPrefix string = '10.40.1.0/24'

@description('Subnet prefix for the Function App private endpoint (inbound).')
param privateEndpointSubnetPrefix string = '10.40.2.0/24'

@description('Name of the Function integration subnet.')
param functionIntegrationSubnetName string = 'snet-functions-integration'

@description('Name of the Function App private endpoint subnet.')
param privateEndpointSubnetName string = 'snet-private-endpoints'

@description('Deploy a jump box VM plus Azure Bastion so you can privately reach the Function App (SCM/Kudu, diagnostics) once it is behind a private endpoint. Requires enablePrivateNetworking=true.')
param enableJumpBox bool = false

@description('Jump box VM admin username.')
param jumpBoxAdminUsername string = 'azureuser'

@description('SSH public key (ssh-rsa/ssh-ed25519 ...) for the jump box admin user. Required when enableJumpBox=true.')
param jumpBoxSshPublicKey string = ''

@description('Jump box VM size.')
param jumpBoxVmSize string = 'Standard_B2s_v2'

@description('Name of the jump box subnet.')
param jumpBoxSubnetName string = 'snet-jumpbox'

@description('Subnet prefix for the jump box VM.')
param jumpBoxSubnetPrefix string = '10.40.3.0/24'

@description('Subnet prefix for Azure Bastion. Must be /26 or larger; the subnet is always named AzureBastionSubnet.')
param bastionSubnetPrefix string = '10.40.4.0/26'

@description('Create an RBAC-enabled Key Vault for customer-managed FinOps secrets. The template does not create secret values.')
param enableKeyVault bool = false

@description('Optional Key Vault name. Leave blank to use a generated name.')
param keyVaultName string = ''

@description('Secret name expected to hold the service principal client secret when using the Key Vault created by this template.')
param finOpsClientSecretName string = 'finops-client-secret'

@description('Client IP address (no CIDR) allowed to reach the Key Vault over its public endpoint firewall, for example to store/retrieve the jump box SSH private key from your workstation. Leave blank to leave the vault\'s network ACL default-deny with no client IP allowed.')
param keyVaultAllowedClientIp string = ''

var normalizedWorkload = toLower(replace(replace(workloadName, '_', ''), '-', ''))
var normalizedEnvironment = toLower(replace(replace(environmentName, '_', ''), '-', ''))
var suffix = uniqueString(resourceGroup().id, workloadName, environmentName)
var storageAccountName = take('${normalizedWorkload}${normalizedEnvironment}${suffix}', 24)
var generatedKeyVaultName = take('${normalizedWorkload}-${normalizedEnvironment}-${suffix}-kv', 24)
var effectiveKeyVaultName = empty(keyVaultName) ? generatedKeyVaultName : keyVaultName
var appInsightsName = '${workloadName}-${environmentName}-appi'
var planName = '${workloadName}-${environmentName}-plan'
var functionAppName = '${workloadName}-${environmentName}-${suffix}-func'
var vnetName = '${workloadName}-${environmentName}-vnet'
var functionPrivateEndpointName = '${workloadName}-${environmentName}-func-pe'
var functionPrivateDnsZoneName = 'privatelink.azurewebsites.net'
var sqlPrivateEndpointName = '${workloadName}-${environmentName}-sql-pe'
var sqlPrivateDnsZoneName = replace('privatelink.${environment().suffixes.sqlServerHostname}', '..', '.')
var storageBlobPrivateEndpointName = '${workloadName}-${environmentName}-stblob-pe'
var storageQueuePrivateEndpointName = '${workloadName}-${environmentName}-stqueue-pe'
var storageTablePrivateEndpointName = '${workloadName}-${environmentName}-sttable-pe'
var storageBlobPrivateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var storageQueuePrivateDnsZoneName = 'privatelink.queue.${environment().suffixes.storage}'
var storageTablePrivateDnsZoneName = 'privatelink.table.${environment().suffixes.storage}'
var keyVaultPrivateEndpointName = '${workloadName}-${environmentName}-kv-pe'
var keyVaultPrivateDnsZoneName = replace('privatelink.${environment().suffixes.keyvaultDns}', '..', '.')
var natGatewayName = '${workloadName}-${environmentName}-natgw'
var natPublicIpName = '${workloadName}-${environmentName}-natgw-pip'
var bastionName = '${workloadName}-${environmentName}-bastion'
var bastionPublicIpName = '${workloadName}-${environmentName}-bastion-pip'
var bastionNsgName = '${workloadName}-${environmentName}-bastion-nsg'
var jumpBoxNsgName = '${workloadName}-${environmentName}-jumpbox-nsg'
var jumpBoxNicName = '${workloadName}-${environmentName}-jumpbox-nic'
var jumpBoxVmName = '${workloadName}-${environmentName}-jumpbox'
var actionGroupName = '${workloadName}-${environmentName}-finops-alerts'
var alertActionGroups = enableMonitoringAlerts && !empty(alertNotificationEmail) ? [
  actionGroup.id
] : []
var effectiveClientSecretUri = !empty(finOpsClientSecretKeyVaultSecretUri) ? finOpsClientSecretKeyVaultSecretUri : (enableKeyVault ? 'https://${effectiveKeyVaultName}${environment().suffixes.keyvaultDns}/secrets/${finOpsClientSecretName}' : '')
var finOpsSecretAppSettings = finOpsAuthMode == 'ServicePrincipal' ? [
  {
    name: 'FINOPS_CLIENT_ID'
    value: finOpsClientId
  }
  {
    name: 'FINOPS_CLIENT_SECRET'
    value: '@Microsoft.KeyVault(SecretUri=${effectiveClientSecretUri})'
  }
] : []

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: appInsightsRetentionDays
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (enableKeyVault) {
  name: effectiveKeyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: !empty(keyVaultAllowedClientIp) ? [
        {
          value: keyVaultAllowedClientIp
        }
      ] : []
    }
  }
}

// Some tenants enforce private-only Key Vault via Azure Policy regardless of publicNetworkAccess
// and networkAcls (observed: publicNetworkAccess is forced to Disabled and public IP-rule access
// is rejected outright), so give it a private endpoint too. This keeps the vault reachable from
// the jump box and the Function App over the VNet even when the public IP allowlist is overridden.
resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enableKeyVault && enablePrivateNetworking) {
  name: keyVaultPrivateDnsZoneName
  location: 'global'
}

resource keyVaultPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enableKeyVault && enablePrivateNetworking) {
  name: '${vnetName}-kv-link'
  parent: keyVaultPrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enableKeyVault && enablePrivateNetworking) {
  name: keyVaultPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${keyVaultPrivateEndpointName}-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource keyVaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enableKeyVault && enablePrivateNetworking) {
  name: 'default'
  parent: keyVaultPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZone.id
        }
      }
    ]
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    // Some tenants enforce private-only SQL via Azure Policy regardless of this value; when enablePrivateNetworking=true
    // this template also creates a SQL private endpoint (sqlPrivateEndpoint) so connectivity works either way.
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : (sqlPublicNetworkAccessEnabled ? 'Enabled' : 'Disabled')
    administrators: empty(sqlEntraAdminLogin) || empty(sqlEntraAdminObjectId) ? null : {
      administratorType: 'ActiveDirectory'
      login: sqlEntraAdminLogin
      sid: sqlEntraAdminObjectId
      tenantId: subscription().tenantId
      principalType: 'User'
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  name: sqlDatabaseName
  parent: sqlServer
  location: location
  sku: {
    name: sqlSkuName
  }
  properties: {
    maxSizeBytes: sqlMaxSizeBytes
  }
}

resource sqlFirewallRule 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!enablePrivateNetworking && sqlPublicNetworkAccessEnabled && !empty(sqlAllowedClientIp)) {
  name: 'AllowDeploymentClient'
  parent: sqlServer
  properties: {
    startIpAddress: sqlAllowedClientIp
    endIpAddress: sqlAllowedClientIp
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (enablePrivateNetworking) {
  name: natPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Gives the Function App a single fixed egress IP so Azure SQL can be firewalled to it while staying on public networking.
resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = if (enablePrivateNetworking) {
  name: natGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

var jumpBoxSubnetsInline = enableJumpBox ? [
  {
    name: 'AzureBastionSubnet'
    properties: {
      addressPrefix: bastionSubnetPrefix
      privateEndpointNetworkPolicies: 'Disabled'
      networkSecurityGroup: {
        id: bastionNsg.id
      }
    }
  }
  {
    name: jumpBoxSubnetName
    properties: {
      addressPrefix: jumpBoxSubnetPrefix
      privateEndpointNetworkPolicies: 'Disabled'
      networkSecurityGroup: {
        id: jumpBoxNsg.id
      }
    }
  }
] : []

// Subnets are declared inline on the VNet resource (rather than as separate Microsoft.Network/virtualNetworks/subnets
// child resources) because ARM PUTs the parent VNet's full subnet collection on every deployment; declaring subnets
// as separate resources causes the parent VNet update to attempt to remove subnets currently in use (e.g. by the
// jump box NIC), which fails deployment.
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = if (enablePrivateNetworking) {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: concat([
      {
        name: functionIntegrationSubnetName
        properties: {
          addressPrefix: functionIntegrationSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ], jumpBoxSubnetsInline)
  }
}

var functionIntegrationSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, functionIntegrationSubnetName)
var privateEndpointSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, privateEndpointSubnetName)
var bastionSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'AzureBastionSubnet')
var jumpBoxSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, jumpBoxSubnetName)

resource functionPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enablePrivateNetworking) {
  name: functionPrivateDnsZoneName
  location: 'global'
}

resource functionPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enablePrivateNetworking) {
  name: '${vnetName}-link'
  parent: functionPrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

// Some tenants enforce private-only SQL via Azure Policy; this private endpoint keeps SQL reachable
// from the Function App (via VNet integration) and the jump box even when public access is forced off.
resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enablePrivateNetworking) {
  name: sqlPrivateDnsZoneName
  location: 'global'
}

resource sqlPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enablePrivateNetworking) {
  name: '${vnetName}-sql-link'
  parent: sqlPrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enablePrivateNetworking) {
  name: sqlPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${sqlPrivateEndpointName}-connection'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource sqlPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enablePrivateNetworking) {
  name: 'default'
  parent: sqlPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: sqlPrivateDnsZone.id
        }
      }
    ]
  }
}

// Storage account also has publicNetworkAccess forced off by tenant policy; the Functions host
// needs blob/queue/table access for AzureWebJobsStorage (triggers, leases, bindings), so each
// sub-resource gets its own private endpoint + private DNS zone.
resource storageBlobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enablePrivateNetworking) {
  name: storageBlobPrivateDnsZoneName
  location: 'global'
}

resource storageBlobPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enablePrivateNetworking) {
  name: '${vnetName}-stblob-link'
  parent: storageBlobPrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource storageBlobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enablePrivateNetworking) {
  name: storageBlobPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageBlobPrivateEndpointName}-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource storageBlobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enablePrivateNetworking) {
  name: 'default'
  parent: storageBlobPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: storageBlobPrivateDnsZone.id
        }
      }
    ]
  }
}

resource storageQueuePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enablePrivateNetworking) {
  name: storageQueuePrivateDnsZoneName
  location: 'global'
}

resource storageQueuePrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enablePrivateNetworking) {
  name: '${vnetName}-stqueue-link'
  parent: storageQueuePrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource storageQueuePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enablePrivateNetworking) {
  name: storageQueuePrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageQueuePrivateEndpointName}-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'queue'
          ]
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource storageQueuePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enablePrivateNetworking) {
  name: 'default'
  parent: storageQueuePrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue'
        properties: {
          privateDnsZoneId: storageQueuePrivateDnsZone.id
        }
      }
    ]
  }
}

resource storageTablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enablePrivateNetworking) {
  name: storageTablePrivateDnsZoneName
  location: 'global'
}

resource storageTablePrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enablePrivateNetworking) {
  name: '${vnetName}-sttable-link'
  parent: storageTablePrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource storageTablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enablePrivateNetworking) {
  name: storageTablePrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageTablePrivateEndpointName}-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'table'
          ]
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource storageTablePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enablePrivateNetworking) {
  name: 'default'
  parent: storageTablePrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: {
          privateDnsZoneId: storageTablePrivateDnsZone.id
        }
      }
    ]
  }
}

// --- Jump box + Azure Bastion: private admin access to the Function App private endpoint ---

resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = if (enableJumpBox) {
  name: bastionNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunicationInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunicationOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

resource jumpBoxNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = if (enableJumpBox) {
  name: jumpBoxNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromBastionSubnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (enableJumpBox) {
  name: bastionPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastionHost 'Microsoft.Network/bastionHosts@2023-09-01' = if (enableJumpBox) {
  name: bastionName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableIpConnect: true
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource jumpBoxNic 'Microsoft.Network/networkInterfaces@2023-09-01' = if (enableJumpBox) {
  name: jumpBoxNicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: jumpBoxSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

// No public IP: reachable only through Azure Bastion.
resource jumpBoxVm 'Microsoft.Compute/virtualMachines@2023-09-01' = if (enableJumpBox) {
  name: jumpBoxVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: jumpBoxVmSize
    }
    osProfile: {
      computerName: jumpBoxVmName
      adminUsername: jumpBoxAdminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${jumpBoxAdminUsername}/.ssh/authorized_keys'
              keyData: jumpBoxSshPublicKey
            }
          ]
        }
      }
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
          id: jumpBoxNic.id
        }
      ]
    }
  }
}

resource functionPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: functionPlanSkuName
    tier: functionPlanSkuName == 'Y1' ? 'Dynamic' : 'ElasticPremium'
  }
  properties: {
    reserved: false
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    // When private networking is enabled, the site is reachable only via its private endpoint (see functionPrivateEndpoint).
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      vnetRouteAllEnabled: enablePrivateNetworking
      powerShellVersion: functionPowerShellVersion
      use32BitWorkerProcess: false
      appSettings: concat([
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: functionPowerShellVersion
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'FINOPS_TIMER_SCHEDULE'
          value: finOpsTimerSchedule
        }
        {
          name: 'FINOPS_EXTRACTION_MODE'
          value: 'Native'
        }
        {
          name: 'FINOPS_AUTH_MODE'
          value: finOpsAuthMode
        }
        {
          name: 'FINOPS_AZURE_CLOUD'
          value: finOpsAzureCloud
        }
        {
          name: 'FINOPS_TENANT_ID'
          value: finOpsTenantId
        }
        {
          name: 'FINOPS_SUBSCRIPTION_IDS'
          value: finOpsSubscriptionIds
        }
        {
          name: 'FINOPS_SQL_ENABLED'
          value: 'true'
        }
        {
          name: 'FINOPS_SQL_SERVER'
          value: sqlServer.properties.fullyQualifiedDomainName
        }
        {
          name: 'FINOPS_SQL_DATABASE'
          value: sqlDatabase.name
        }
        {
          name: 'FINOPS_SQL_SCHEMA'
          value: sqlSchemaName
        }
        {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: enablePrivateNetworking ? '1' : '0'
        }
      ], finOpsSecretAppSettings)
    }
  }
}

resource keyVaultSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableKeyVault) {
  name: guid(keyVault.id, functionAppName, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grants the SQL Entra admin (typically the deploying engineer) rights to create/read
// secrets in Key Vault, for example to store the jump box SSH private key so it can be
// retrieved instead of re-generated after local cleanup.
resource keyVaultSecretsOfficerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableKeyVault && !empty(sqlEntraAdminObjectId)) {
  name: guid(keyVault.id, sqlEntraAdminObjectId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: sqlEntraAdminObjectId
    principalType: 'User'
  }
}

// AzureWebJobsStorage now uses identity-based auth (no storage account keys), so the
// Function App's managed identity needs data-plane RBAC on blobs, queues, and tables.
resource storageBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppName, 'StorageBlobDataOwner')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppName, 'StorageQueueDataContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppName, 'StorageTableDataContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionVnetIntegration 'Microsoft.Web/sites/networkConfig@2023-12-01' = if (enablePrivateNetworking) {
  name: 'virtualNetwork'
  parent: functionApp
  properties: {
    subnetResourceId: functionIntegrationSubnetId
    swiftSupported: true
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource functionPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enablePrivateNetworking) {
  name: functionPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${functionPrivateEndpointName}-connection'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource functionPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (enablePrivateNetworking) {
  name: 'default'
  parent: functionPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: functionPrivateDnsZone.id
        }
      }
    ]
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (enableMonitoringAlerts && !empty(alertNotificationEmail)) {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: take('${normalizedWorkload}${normalizedEnvironment}', 12)
    enabled: true
    emailReceivers: [
      {
        name: 'FinOpsIngestionOperator'
        emailAddress: alertNotificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource failedRunAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableMonitoringAlerts) {
  name: '${workloadName}-${environmentName}-finops-run-failed'
  location: location
  properties: {
    displayName: 'FinOps ingestion run failed'
    description: 'Alerts when the Function logs FinOpsRunStatus=Failed.'
    severity: 2
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: alertEvaluationFrequency
    windowSize: alertWindowSize
    criteria: {
      allOf: [
        {
          query: 'traces | where message has "FinOpsRunStatus=Failed"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: alertActionGroups
    }
    autoMitigate: true
    skipQueryValidation: true
  }
}

resource missedRunAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (enableMonitoringAlerts) {
  name: '${workloadName}-${environmentName}-finops-run-missed'
  location: location
  properties: {
    displayName: 'FinOps ingestion success missing'
    description: 'Alerts when no FinOpsRunStatus=Succeeded trace is observed in the configured missed-run window.'
    severity: 3
    enabled: true
    scopes: [
      appInsights.id
    ]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: 'traces | where timestamp > ago(${missedRunAlertWindowHours}h) | where message has "FinOpsRunStatus=Succeeded" | summarize SuccessfulRuns=count()'
          metricMeasureColumn: 'SuccessfulRuns'
          timeAggregation: 'Total'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: alertActionGroups
    }
    autoMitigate: true
    skipQueryValidation: true
  }
}

output sqlServerFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabase string = sqlDatabase.name
output functionAppName string = functionApp.name
output functionPrincipalId string = functionApp.identity.principalId
output functionTenantId string = subscription().tenantId
output storageAccount string = storageAccount.name
output applicationInsightsName string = appInsights.name
output monitoringAlertsEnabled bool = enableMonitoringAlerts
output privateNetworkingEnabled bool = enablePrivateNetworking
output virtualNetworkName string = enablePrivateNetworking ? virtualNetwork.name : ''
output functionPrivateEndpointName string = enablePrivateNetworking ? functionPrivateEndpoint.name : ''
output sqlPrivateEndpointName string = enablePrivateNetworking ? sqlPrivateEndpoint.name : ''
output natGatewayPublicIpAddress string = enablePrivateNetworking ? natPublicIp.properties.ipAddress : ''
output jumpBoxEnabled bool = enableJumpBox
output jumpBoxVmName string = enableJumpBox ? jumpBoxVm.name : ''
output bastionHostName string = enableJumpBox ? bastionHost.name : ''
output keyVaultName string = enableKeyVault ? keyVault.name : ''
output keyVaultPrivateEndpointName string = enableKeyVault && enablePrivateNetworking ? keyVaultPrivateEndpoint.name : ''
output finOpsClientSecretKeyVaultReference string = finOpsAuthMode == 'ServicePrincipal' ? effectiveClientSecretUri : ''
output nextSteps array = [
  'Grant the Function managed identity Cost Management Reader on target subscriptions or billing scopes.'
  'Grant the Function managed identity SQL access in the database, for example CREATE USER [<function-name>] FROM EXTERNAL PROVIDER and appropriate role grants.'
  'When enablePrivateNetworking=true, SQL is given a private endpoint (sqlPrivateEndpointName output) and is reachable from the Function App and the jump box over the VNet. If your tenant policy allows public SQL access instead, set enablePrivateNetworking=false and sqlPublicNetworkAccessEnabled=true with sqlAllowedClientIp set.'
  'When enablePrivateNetworking=true, the Function App is reachable only via its private endpoint. Deploy the functionapp folder either temporarily with enablePrivateNetworking=false for the first deploy, from a CI/CD agent inside the VNet, or from the jump box.'
  'When enableJumpBox=true, connect via Azure Bastion (Azure Portal > Bastion > Connect) using the jump box SSH key to browse https://<functionAppName>.scm.azurewebsites.net and to run sqlcmd against the SQL private endpoint privately.'
  'Run scripts/Deploy-FinOpsSqlSchema.ps1 (from the jump box, since SQL is private) or include schema deployment in a controlled release pipeline.'
]
