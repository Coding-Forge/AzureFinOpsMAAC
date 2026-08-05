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
param functionPowerShellVersion string = '7.4'

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

@description('Create VNet integration, SQL private endpoint, private DNS zone/link, and route Function outbound traffic through the VNet. Requires a Function plan that supports regional VNet integration, such as EP1.')
param enablePrivateNetworking bool = false

@description('Virtual network address prefix used when private networking is enabled.')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Subnet prefix for Function regional VNet integration. This subnet is delegated to Microsoft.Web/serverFarms.')
param functionIntegrationSubnetPrefix string = '10.40.1.0/24'

@description('Subnet prefix for SQL private endpoints.')
param privateEndpointSubnetPrefix string = '10.40.2.0/24'

@description('Name of the Function integration subnet.')
param functionIntegrationSubnetName string = 'snet-functions-integration'

@description('Name of the private endpoint subnet.')
param privateEndpointSubnetName string = 'snet-private-endpoints'

@description('Create an RBAC-enabled Key Vault for customer-managed FinOps secrets. The template does not create secret values.')
param enableKeyVault bool = false

@description('Optional Key Vault name. Leave blank to use a generated name.')
param keyVaultName string = ''

@description('Secret name expected to hold the service principal client secret when using the Key Vault created by this template.')
param finOpsClientSecretName string = 'finops-client-secret'

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
var sqlPrivateEndpointName = '${workloadName}-${environmentName}-sql-pe'
var sqlPrivateDnsZoneName = replace('privatelink.${environment().suffixes.sqlServerHostname}', '..', '.')
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
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    publicNetworkAccess: sqlPublicNetworkAccessEnabled ? 'Enabled' : 'Disabled'
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

resource sqlFirewallRule 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (sqlPublicNetworkAccessEnabled && !empty(sqlAllowedClientIp)) {
  name: 'AllowDeploymentClient'
  parent: sqlServer
  properties: {
    startIpAddress: sqlAllowedClientIp
    endIpAddress: sqlAllowedClientIp
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = if (enablePrivateNetworking) {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource functionIntegrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = if (enablePrivateNetworking) {
  name: functionIntegrationSubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: functionIntegrationSubnetPrefix
    delegations: [
      {
        name: 'Microsoft.Web.serverFarms'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = if (enablePrivateNetworking) {
  name: privateEndpointSubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (enablePrivateNetworking) {
  name: sqlPrivateDnsZoneName
  location: 'global'
}

resource sqlPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (enablePrivateNetworking) {
  name: '${vnetName}-link'
  parent: sqlPrivateDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
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
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      vnetRouteAllEnabled: enablePrivateNetworking
      appSettings: concat([
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
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

resource functionVnetIntegration 'Microsoft.Web/sites/networkConfig@2023-12-01' = if (enablePrivateNetworking) {
  name: 'virtualNetwork'
  parent: functionApp
  properties: {
    subnetResourceId: functionIntegrationSubnet.id
    swiftSupported: true
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (enablePrivateNetworking) {
  name: sqlPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
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
output sqlPrivateEndpointName string = enablePrivateNetworking ? sqlPrivateEndpoint.name : ''
output keyVaultName string = enableKeyVault ? keyVault.name : ''
output finOpsClientSecretKeyVaultReference string = finOpsAuthMode == 'ServicePrincipal' ? effectiveClientSecretUri : ''
output nextSteps array = [
  'Grant the Function managed identity Cost Management Reader on target subscriptions or billing scopes.'
  'Grant the Function managed identity SQL access in the database, for example CREATE USER [<function-name>] FROM EXTERNAL PROVIDER and appropriate role grants.'
  'Deploy the functionapp folder as the Function App package.'
  'Run scripts/Deploy-FinOpsSqlSchema.ps1 or include schema deployment in a controlled release pipeline.'
]
