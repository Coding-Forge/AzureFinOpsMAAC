targetScope = 'subscription'

@description('Object ID of the Function App system-assigned or user-assigned managed identity service principal.')
param functionPrincipalId string

@description('Role definition IDs to assign to the Function identity at this subscription scope. Defaults to Cost Management Reader.')
param roleDefinitionIds array = [
  '72fafb9e-0641-4937-9268-a91bfd8191a3'
]

@description('Principal type for the Function managed identity.')
@allowed([
  'ServicePrincipal'
])
param principalType string = 'ServicePrincipal'

@description('Stable seed used in role assignment GUID names. Change only if you intentionally need parallel duplicate assignments.')
param assignmentNameSeed string = 'finops-function-ingestion'

resource subscriptionRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in roleDefinitionIds: {
  name: guid(subscription().id, functionPrincipalId, roleDefinitionId, assignmentNameSeed)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: functionPrincipalId
    principalType: principalType
  }
}]

output assignedRoleDefinitionIds array = roleDefinitionIds
output assignedPrincipalId string = functionPrincipalId

