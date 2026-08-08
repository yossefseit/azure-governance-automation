targetScope = 'resourceGroup'

@description('Create a CanNotDelete lock at this resource-group scope.')
param enabled bool = true

@description('Name of the management lock.')
param lockName string

var lockResourceId = extensionResourceId(resourceGroup().id, 'Microsoft.Authorization/locks', lockName)

resource deleteProtection 'Microsoft.Authorization/locks@2020-05-01' = if (enabled) {
  name: lockName
  properties: {
    level: 'CanNotDelete'
    notes: 'Prevents accidental deletion of governance lab resources. Remove deliberately before cleanup.'
  }
}

@description('Deterministic cleanup candidate, emitted even when lock creation is disabled.')
output lockResourceId string = lockResourceId
