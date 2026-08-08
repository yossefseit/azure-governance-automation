targetScope = 'resourceGroup'

@description('Create a group-based Reader assignment at this resource-group scope.')
param enabled bool = false

@description('Microsoft Entra group object ID. Required when enabled; retain the same private value through disable, redeploy, and cleanup so the deterministic assignment ID remains discoverable.')
param principalId string = ''

var readerRoleDefinitionGuid = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var roleAssignmentName = guid(resourceGroup().id, principalId, readerRoleDefinitionGuid)
var roleAssignmentResourceId = extensionResourceId(resourceGroup().id, 'Microsoft.Authorization/roleAssignments', roleAssignmentName)

resource reviewerReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enabled) {
  name: roleAssignmentName
  properties: {
    principalId: principalId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionGuid)
    description: 'Read-only access to the governance lab resource group.'
  }
}

@description('Deterministic cleanup candidate, emitted even when access is disabled. Its name depends on principalId.')
output roleAssignmentResourceId string = roleAssignmentResourceId
