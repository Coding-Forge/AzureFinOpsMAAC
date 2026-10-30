targetScope = 'subscription'

@description('Azure region for the resource group and resource-management private link.')
param location string

@description('Resource group that owns the tenant-shared resource-management private link.')
param resourceGroupName string = 'rg-arm-private-link'

@description('Name of the Azure Resource Manager resource-management private link.')
param resourceManagementPrivateLinkName string = 'arm-private-link'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module resourceManagementPrivateLink './modules/resource-management-private-link.bicep' = {
  name: 'deploy-resource-management-private-link'
  scope: resourceGroup
  params: {
    location: location
    resourceManagementPrivateLinkName: resourceManagementPrivateLinkName
  }
}

output resourceManagementPrivateLinkId string = resourceManagementPrivateLink.outputs.resourceManagementPrivateLinkId
output resourceGroupName string = resourceGroup.name
