targetScope = 'subscription'

metadata name = 'Azure Governance Automation Lab'
metadata description = 'A deliberately small subscription governance baseline; not a full enterprise landing zone.'

@description('Short lowercase prefix used in resource names. Keep this stable because names are immutable identifiers.')
@minLength(3)
@maxLength(12)
param prefix string = 'aglab'

@description('Azure region for deployment metadata and the governance resource group. The action group itself uses the global location.')
param deploymentLocation string

@description('Environment tag value applied to lab-owned resources.')
@allowed([
  'lab'
  'dev'
  'test'
])
param labEnvironment string = 'lab'

@description('Non-personal owner tag value. Do not use an email address or personal identifier in the committed example.')
@minLength(2)
param ownerTagValue string = 'portfolio'

@description('Cost allocation tag value for the lab governance resource group.')
@minLength(2)
param costCenterTagValue string = 'learning'

@description('Locations considered compliant by the custom location policy. Start in Audit and confirm required global/regional services before Deny.')
@minLength(1)
param allowedLocations array = [
  'westeurope'
]

@description('Effect for the custom resource location policy.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param locationPolicyEffect string = 'Audit'

@description('Effect for missing required tags on resource groups.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param requiredTagPolicyEffect string = 'Audit'

@description('Effect for inheriting missing resource tags from the parent resource group. Enable Modify only after reviewing assignment scope and role creation.')
@allowed([
  'Modify'
  'Disabled'
])
param inheritancePolicyEffect string = 'Disabled'

@description('Monthly budget threshold in the subscription billing currency. This is an alert threshold, not a hard cap.')
@minValue(1)
param monthlyBudgetAmount int = 5

@description('Stable budget period start date selected for the target billing period. Azure expects the first day of a month in UTC; retain the same value across reruns.')
param budgetStartDate string

@description('Optional notification addresses supplied only through an uncommitted local parameter file. Empty keeps source control free of personal data.')
param budgetContactEmails array = []

@description('Create bounded remediation tasks for existing resources. New and updated resources are still evaluated when false.')
param createRemediationTasks bool = false

@description('Assign Reader on the governance resource group to a Microsoft Entra group.')
param enableReviewerAccess bool = false

@description('Microsoft Entra group object ID. Keep real IDs in an uncommitted local parameter file and retain the original value through disable, redeploy, and cleanup so stale deterministic assignments remain discoverable.')
param reviewerGroupObjectId string = ''

@description('Protect the governance resource group from accidental deletion. Cleanup must remove this lock first.')
param enableResourceLock bool = true

var allowedPrefixCharacters = 'abcdefghijklmnopqrstuvwxyz0123456789'
var prefixCharacters = [for prefixIndex in range(0, length(prefix)): substring(prefix, prefixIndex, 1)]
var invalidPrefixCharacters = filter(prefixCharacters, prefixCharacter => !contains(allowedPrefixCharacters, prefixCharacter))

assert prefixIsLowerAlphanumeric = empty(invalidPrefixCharacters)
assert remediationRequiresModify = !createRemediationTasks || inheritancePolicyEffect == 'Modify'
assert reviewerGroupProvided = !enableReviewerAccess || length(reviewerGroupObjectId) == 36

var labMarker = 'azure-governance-automation'
var governanceResourceGroupName = 'rg-${prefix}-governance'
var commonTags = {
  environment: labEnvironment
  owner: ownerTagValue
  costCenter: costCenterTagValue
  managedBy: 'bicep'
  portfolioLab: labMarker
  dataClassification: 'public-demo'
}

resource governanceResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: governanceResourceGroupName
  location: deploymentLocation
  tags: commonTags
}

module notificationGroup 'modules/notification-group.bicep' = {
  name: '${prefix}-notification-group'
  scope: governanceResourceGroup
  params: {
    actionGroupName: 'ag-${prefix}-cost'
    actionGroupShortName: prefix
    contactEmails: budgetContactEmails
    tags: commonTags
  }
}

module subscriptionBudget 'modules/subscription-budget.bicep' = {
  name: '${prefix}-subscription-budget'
  params: {
    budgetName: '${prefix}-monthly-guardrail'
    amount: monthlyBudgetAmount
    startDate: budgetStartDate
    actionGroupResourceId: notificationGroup.outputs.actionGroupResourceId
  }
}

module policyGovernance 'modules/policy-governance.bicep' = {
  name: '${prefix}-policy-governance'
  params: {
    prefix: prefix
    assignmentLocation: deploymentLocation
    allowedLocations: allowedLocations
    locationPolicyEffect: locationPolicyEffect
    requiredTagPolicyEffect: requiredTagPolicyEffect
    inheritancePolicyEffect: inheritancePolicyEffect
    createRemediationTasks: createRemediationTasks
  }
}

module reviewerAccess 'modules/resource-group-access.bicep' = {
  name: '${prefix}-reviewer-access'
  scope: governanceResourceGroup
  params: {
    enabled: enableReviewerAccess
    principalId: reviewerGroupObjectId
  }
}

module resourceLock 'modules/resource-group-lock.bicep' = {
  name: '${prefix}-resource-lock'
  scope: governanceResourceGroup
  params: {
    enabled: enableResourceLock
    lockName: '${prefix}-delete-protection'
  }
}

@description('Machine-readable deterministic cleanup candidates. Optional IDs remain listed while disabled so earlier incremental states stay discoverable; never commit a live output as evidence.')
output cleanupManifest object = {
  schemaVersion: '1.2'
  labMarker: labMarker
  prefix: prefix
  governanceResourceGroupName: governanceResourceGroup.name
  deploymentNames: {
    subscriptionModules: [
      '${prefix}-subscription-budget'
      '${prefix}-policy-governance'
    ]
    resourceGroupModules: [
      '${prefix}-notification-group'
      '${prefix}-reviewer-access'
      '${prefix}-resource-lock'
    ]
  }
  resourceIds: {
    lock: resourceLock.outputs.lockResourceId
    actionGroup: notificationGroup.outputs.actionGroupResourceId
    budget: subscriptionBudget.outputs.budgetResourceId
    reviewerRoleAssignment: reviewerAccess.outputs.roleAssignmentResourceId
    policyAssignment: policyGovernance.outputs.policyAssignmentResourceId
    remediationRoleAssignment: policyGovernance.outputs.remediationRoleAssignmentResourceId
    policySetDefinition: policyGovernance.outputs.policySetDefinitionResourceId
    policyDefinitions: policyGovernance.outputs.policyDefinitionResourceIds
    remediations: policyGovernance.outputs.remediationResourceIds
  }
}

output governanceSummary object = {
  policyAssignmentName: policyGovernance.outputs.policyAssignmentName
  locationPolicyEffect: locationPolicyEffect
  requiredTagPolicyEffect: requiredTagPolicyEffect
  inheritancePolicyEffect: inheritancePolicyEffect
  remediationTasksRequested: createRemediationTasks
  resourceLockRequested: enableResourceLock
  reviewerAccessRequested: enableReviewerAccess
  notificationReceiverCount: length(budgetContactEmails)
  note: 'A budget sends alerts; it is not a hard spending cap.'
}
