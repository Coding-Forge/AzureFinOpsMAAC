targetScope = 'managementGroup'

@description('Resource ID returned by arm-private-link-resource.bicep.')
param resourceManagementPrivateLinkId string

@description('GUID name for the root-management-group private-link association.')
param associationName string = guid(managementGroup().id, resourceManagementPrivateLinkId)

var validatedResourceManagementPrivateLinkId = toLower(managementGroup().name) != toLower(tenant().tenantId)
  ? fail('ARM Private Link associations must be deployed to the tenant root management group.')
  : empty(trim(resourceManagementPrivateLinkId))
    ? fail('resourceManagementPrivateLinkId must not be empty.')
    : resourceManagementPrivateLinkId

resource privateLinkAssociation 'Microsoft.Authorization/privateLinkAssociations@2020-05-01' = {
  name: associationName
  properties: {
    privateLink: validatedResourceManagementPrivateLinkId
    publicNetworkAccess: 'Enabled'
  }
}

output privateLinkAssociationId string = privateLinkAssociation.id
output resourceManagementPrivateLinkId string = resourceManagementPrivateLinkId
