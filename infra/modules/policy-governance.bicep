targetScope = 'subscription'

@description('Short naming prefix shared by policy resources.')
@minLength(3)
@maxLength(12)
param prefix string

@description('Region required by the policy assignment system-assigned identity.')
param assignmentLocation string

@description('Locations allowed by the custom location definition.')
@minLength(1)
param allowedLocations array

@description('Effect for resources outside allowedLocations.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param locationPolicyEffect string = 'Audit'

@description('Effect for resource groups missing an environment or owner tag.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param requiredTagPolicyEffect string = 'Audit'

@description('Effect for inheriting missing tags. Disabled avoids creating remediation RBAC by default.')
@allowed([
  'Modify'
  'Disabled'
])
param inheritancePolicyEffect string = 'Disabled'

@description('Create bounded remediation tasks for existing resources. Disabled by default because remediation changes resources.')
param createRemediationTasks bool = false

assert remediationRequiresModify = !createRemediationTasks || inheritancePolicyEffect == 'Modify'

var tagContributorRoleGuid = '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
var tagContributorPolicyRoleId = tenantResourceId('Microsoft.Authorization/roleDefinitions', tagContributorRoleGuid)
var assignmentName = '${prefix}-guardrails'
var initiativeName = '${prefix}-baseline'
var inheritTagDefinitionName = '${prefix}-inherit-rg-tag'
var requiredRgTagDefinitionName = '${prefix}-require-rg-tag'
var allowedLocationsDefinitionName = '${prefix}-allowed-locations'
var remediationRoleAssignmentName = guid(subscription().id, assignmentName, tagContributorRoleGuid)
var remediationRoleAssignmentResourceId = extensionResourceId(subscription().id, 'Microsoft.Authorization/roleAssignments', remediationRoleAssignmentName)
var disabledPrincipalId = guid(subscription().id, assignmentName, 'disabled-policy-identity')

var remediationItems = [
  {
    name: 'environment'
    referenceId: 'inherit-environment-tag'
  }
  {
    name: 'owner'
    referenceId: 'inherit-owner-tag'
  }
]
var remediationResourceIds = [for item in remediationItems: subscriptionResourceId('Microsoft.PolicyInsights/remediations', '${prefix}-remediate-${item.name}')]

resource inheritTagDefinition 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: inheritTagDefinitionName
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    displayName: 'Inherit a missing tag from the parent resource group'
    description: 'Adds a named tag only when it is missing and the parent resource group has a non-empty value. Existing resources require an explicit remediation task.'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-governance-automation'
    }
    parameters: {
      tagName: {
        type: 'String'
        metadata: {
          displayName: 'Tag name'
          description: 'Name of the tag inherited from the parent resource group.'
        }
      }
      effect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Disabled'
        metadata: {
          displayName: 'Inheritance effect'
          description: 'Disabled is safe by default. Modify adds a missing tag and requires assignment identity permissions.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
            exists: 'false'
          }
          {
            value: '[resourceGroup().tags[parameters(\'tagName\')]]'
            notEquals: ''
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          roleDefinitionIds: [
            tagContributorPolicyRoleId
          ]
          conflictEffect: 'audit'
          operations: [
            {
              operation: 'add'
              field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
              value: '[resourceGroup().tags[parameters(\'tagName\')]]'
            }
          ]
        }
      }
    }
  }
}

resource requiredRgTagDefinition 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: requiredRgTagDefinitionName
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: 'Audit or deny resource groups missing a required tag'
    description: 'Evaluates a parameterized tag on resource groups. Audit is the safe assignment default; Deny requires an exception and rollout process.'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
      source: 'azure-governance-automation'
    }
    parameters: {
      tagName: {
        type: 'String'
        metadata: {
          displayName: 'Required tag name'
          description: 'Tag that must be present on resource groups.'
        }
      }
      effect: {
        type: 'String'
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
        metadata: {
          displayName: 'Effect'
          description: 'Audit first; move to Deny only after reviewing compliance and exceptions.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            field: '[concat(\'tags[\', parameters(\'tagName\'), \']\')]'
            exists: 'false'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

resource allowedLocationsDefinition 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: allowedLocationsDefinitionName
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: 'Audit or deny resources outside approved locations'
    description: 'Evaluates resource locations while excluding locationless and global resources. Audit is the safe assignment default.'
    metadata: {
      category: 'General'
      version: '1.0.0'
      source: 'azure-governance-automation'
    }
    parameters: {
      allowedLocations: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed locations'
          description: 'Azure region names considered compliant.'
          strongType: 'location'
        }
      }
      effect: {
        type: 'String'
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
        metadata: {
          displayName: 'Effect'
          description: 'Audit first; use Deny only after service compatibility and exception review.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'location'
            exists: 'true'
          }
          {
            field: 'location'
            notEquals: 'global'
          }
          {
            field: 'location'
            notIn: '[parameters(\'allowedLocations\')]'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

resource governanceInitiative 'Microsoft.Authorization/policySetDefinitions@2025-03-01' = {
  name: initiativeName
  properties: {
    policyType: 'Custom'
    displayName: 'Portfolio subscription governance baseline'
    description: 'Small subscription baseline for required resource-group tags, resource tag inheritance, and approved locations. This is not an enterprise landing zone initiative.'
    metadata: {
      category: 'Governance'
      version: '1.0.0'
      source: 'azure-governance-automation'
    }
    parameters: {
      allowedLocations: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed locations'
          description: 'Locations passed to the custom location policy.'
          strongType: 'location'
        }
      }
      locationEffect: {
        type: 'String'
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
        metadata: {
          displayName: 'Location effect'
          description: 'Audit, Deny, or Disabled for disallowed locations.'
        }
      }
      requiredTagEffect: {
        type: 'String'
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
        metadata: {
          displayName: 'Required tag effect'
          description: 'Audit, Deny, or Disabled for resource groups missing required tags.'
        }
      }
      inheritanceEffect: {
        type: 'String'
        allowedValues: [
          'Modify'
          'Disabled'
        ]
        defaultValue: 'Disabled'
        metadata: {
          displayName: 'Tag inheritance effect'
          description: 'Disabled avoids tag writes and remediation RBAC until explicitly enabled.'
        }
      }
    }
    policyDefinitionGroups: [
      {
        name: 'organization'
        displayName: 'Organization and cost metadata'
        description: 'Controls for required and inherited resource metadata.'
        category: 'Tags'
      }
      {
        name: 'location'
        displayName: 'Resource location'
        description: 'Controls for approved Azure regions.'
        category: 'General'
      }
    ]
    policyDefinitions: [
      {
        policyDefinitionId: requiredRgTagDefinition.id
        policyDefinitionReferenceId: 'require-environment-tag-on-rg'
        groupNames: [
          'organization'
        ]
        parameters: {
          tagName: {
            value: 'environment'
          }
          effect: {
            value: '[parameters(\'requiredTagEffect\')]'
          }
        }
      }
      {
        policyDefinitionId: requiredRgTagDefinition.id
        policyDefinitionReferenceId: 'require-owner-tag-on-rg'
        groupNames: [
          'organization'
        ]
        parameters: {
          tagName: {
            value: 'owner'
          }
          effect: {
            value: '[parameters(\'requiredTagEffect\')]'
          }
        }
      }
      {
        policyDefinitionId: inheritTagDefinition.id
        policyDefinitionReferenceId: 'inherit-environment-tag'
        groupNames: [
          'organization'
        ]
        parameters: {
          tagName: {
            value: 'environment'
          }
          effect: {
            value: '[parameters(\'inheritanceEffect\')]'
          }
        }
      }
      {
        policyDefinitionId: inheritTagDefinition.id
        policyDefinitionReferenceId: 'inherit-owner-tag'
        groupNames: [
          'organization'
        ]
        parameters: {
          tagName: {
            value: 'owner'
          }
          effect: {
            value: '[parameters(\'inheritanceEffect\')]'
          }
        }
      }
      {
        policyDefinitionId: allowedLocationsDefinition.id
        policyDefinitionReferenceId: 'allowed-resource-locations'
        groupNames: [
          'location'
        ]
        parameters: {
          allowedLocations: {
            value: '[parameters(\'allowedLocations\')]'
          }
          effect: {
            value: '[parameters(\'locationEffect\')]'
          }
        }
      }
    ]
  }
}

resource governanceAssignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: assignmentName
  scope: subscription()
  location: assignmentLocation
  identity: {
    type: inheritancePolicyEffect == 'Modify' ? 'SystemAssigned' : 'None'
  }
  properties: {
    displayName: 'Portfolio subscription governance baseline'
    description: 'Assigns the small governance initiative at subscription scope. Review effects and exclusions before production use.'
    policyDefinitionId: governanceInitiative.id
    enforcementMode: 'Default'
    metadata: {
      assignedBy: 'azure-governance-automation'
      evidenceStatus: 'authored-not-azure-validated'
    }
    parameters: {
      allowedLocations: {
        value: allowedLocations
      }
      locationEffect: {
        value: locationPolicyEffect
      }
      requiredTagEffect: {
        value: requiredTagPolicyEffect
      }
      inheritanceEffect: {
        value: inheritancePolicyEffect
      }
    }
    nonComplianceMessages: [
      {
        message: 'The resource is outside the lab governance baseline. Review the initiative reference and approved exception process.'
      }
    ]
  }
}

resource remediationRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (inheritancePolicyEffect == 'Modify') {
  name: remediationRoleAssignmentName
  scope: subscription()
  properties: {
    principalId: inheritancePolicyEffect == 'Modify' ? governanceAssignment.identity.principalId : disabledPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tagContributorRoleGuid)
    description: 'Allows only the policy assignment managed identity to remediate resource tags at assignment scope.'
  }
}

resource remediations 'Microsoft.PolicyInsights/remediations@2024-10-01' = [for item in remediationItems: if (createRemediationTasks && inheritancePolicyEffect == 'Modify') {
  name: '${prefix}-remediate-${item.name}'
  scope: subscription()
  properties: {
    policyAssignmentId: governanceAssignment.id
    policyDefinitionReferenceId: item.referenceId
    resourceDiscoveryMode: 'ReEvaluateCompliance'
    parallelDeployments: 5
    resourceCount: 50
    failureThreshold: {
      percentage: 0
    }
  }
  dependsOn: [
    remediationRoleAssignment
  ]
}]

output policyAssignmentName string = governanceAssignment.name
output policyAssignmentResourceId string = governanceAssignment.id
@description('Deterministic cleanup candidate, emitted even when Modify is disabled so an earlier incremental state remains discoverable.')
output remediationRoleAssignmentResourceId string = remediationRoleAssignmentResourceId
output policySetDefinitionResourceId string = governanceInitiative.id
output policyDefinitionResourceIds array = [
  inheritTagDefinition.id
  requiredRgTagDefinition.id
  allowedLocationsDefinition.id
]
@description('Deterministic cleanup candidates for both bounded tasks, emitted even when task creation is disabled.')
output remediationResourceIds array = remediationResourceIds
