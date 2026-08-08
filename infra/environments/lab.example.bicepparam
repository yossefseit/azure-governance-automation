using '../main.bicep'

// This file is safe to commit: it contains no tenant, subscription, principal,
// or contact identifiers. Copy it to lab.local.bicepparam before authenticated use.
param prefix = 'aglab'
param deploymentLocation = 'westeurope'
param labEnvironment = 'lab'
param ownerTagValue = 'portfolio'
param costCenterTagValue = 'learning'

param allowedLocations = [
  'westeurope'
  'northeurope'
]
param locationPolicyEffect = 'Audit'
param requiredTagPolicyEffect = 'Audit'
param inheritancePolicyEffect = 'Disabled'

// Currency comes from the target subscription agreement. This threshold is an
// early warning only and does not authorize, block, or cap Azure consumption.
param monthlyBudgetAmount = 5
// Stable example as of this lab revision. In the ignored local copy, select an
// approved first-of-month UTC billing start date and retain it across reruns.
param budgetStartDate = '2026-08-01T00:00:00Z'
param budgetContactEmails = []

// Modify and remediation write tags. Keep both disabled until scope and access
// are reviewed; remediation cannot be enabled while inheritance is Disabled.
param createRemediationTasks = false

// If enabled, put a real Entra group object ID only in an ignored local copy.
// Retain that same private ID through disable, redeployment, and cleanup because
// it participates in the deterministic reviewer role-assignment name.
param enableReviewerAccess = false
param reviewerGroupObjectId = ''

param enableResourceLock = true
