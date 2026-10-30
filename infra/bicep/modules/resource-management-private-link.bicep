targetScope = 'resourceGroup'

@description('Name of the Azure Resource Manager resource-management private link.')
param resourceManagementPrivateLinkName string

@description('Azure region for the resource-management private link.')
param location string

resource resourceManagementPrivateLink 'Microsoft.Authorization/resourceManagementPrivateLinks@2020-05-01' = {
  name: resourceManagementPrivateLinkName
  location: location
}

output resourceManagementPrivateLinkId string = resourceManagementPrivateLink.id
