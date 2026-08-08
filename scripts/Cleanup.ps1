[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [string]$DeploymentName = 'aglab-governance',
    [string]$Confirmation = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

function Test-ExactManifestResourceId {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$ExpectedResourceId,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        throw "$Label is missing from the cleanup manifest; nothing was deleted."
    }
    if (-not $ResourceId.Equals($ExpectedResourceId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label does not match the exact expected lab resource ID; nothing was deleted."
    }
    if ($ResourceId.Contains("`n") -or $ResourceId.Contains("`r")) {
        throw "$Label contains an invalid line break; nothing was deleted."
    }
}

function Test-AzureResourceExistence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$ApiVersion
    )

    $url = "$($ResourceId)?api-version=$ApiVersion"
    $result = (& az rest --method get --url $url --only-show-errors --output none 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { return $true }
    $verifiedNotFoundPattern = '(?i)(^|[^a-z0-9_])[a-z][a-z0-9]*NotFound([^a-z0-9_]|$)|(?:HTTP|status(?:\s+code)?)[\s:=]+404(?:\D|$)'
    if ($result -match $verifiedNotFoundPattern) { return $false }
    throw "Could not verify resource state before deletion: $result"
}

function Invoke-AzureResourceDelete {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$ApiVersion,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return }
    if (-not (Test-AzureResourceExistence -ResourceId $ResourceId -ApiVersion $ApiVersion)) {
        Write-Output "Already absent; skipping $Label`: $ResourceId"
        return
    }
    Write-Output "Deleting $Label`: $ResourceId"
    $url = "$($ResourceId)?api-version=$ApiVersion"
    & az rest --method delete --url $url --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete $Label; cleanup stopped." }
}

function Get-AzureInventoryJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string[]]$CliArguments
    )

    $output = (& az @CliArguments 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inventory $Label; cleanup stopped before further mutation."
    }
    return $output.Trim()
}

function ConvertFrom-InventoryArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InventoryText,

        [Parameter(Mandatory)]
        [string]$Label
    )

    try {
        $parsed = ConvertFrom-Json -InputObject $InventoryText -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw "$Label inventory was malformed JSON; cleanup stopped before further mutation."
    }
    if ($parsed -isnot [System.Array]) {
        throw "$Label inventory was not a JSON array; cleanup stopped before further mutation."
    }
    return $parsed
}

function Test-AllowedStringInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InventoryText,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [bool]$RequireEmpty,

        [string[]]$Allowed = @()
    )

    $items = @(ConvertFrom-InventoryArray -InventoryText $InventoryText -Label $Label)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item) -or $item -match "[`r`n`t]") {
            throw "$Label inventory was not a valid string array; cleanup stopped before further mutation."
        }
        if (-not $seen.Add($item)) {
            throw "$Label inventory contains a duplicate item; cleanup stopped before further mutation."
        }
        if ($RequireEmpty) {
            throw "$Label inventory is not empty before resource-group deletion; cleanup stopped."
        }
        $isAllowed = $false
        foreach ($allowedItem in $Allowed) {
            if ($item.Equals($allowedItem, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isAllowed = $true
            }
        }
        if (-not $isAllowed) {
            throw "$Label inventory contains an unexpected item; cleanup stopped before further mutation."
        }
    }
}

function Test-AllowedRoleInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InventoryText,

        [Parameter(Mandatory)]
        [bool]$RequireEmpty,

        [Parameter(Mandatory)]
        [string]$ExpectedScope,

        [Parameter(Mandatory)]
        [string]$ReviewerRoleId,

        [Parameter(Mandatory)]
        [string]$ExpectedReaderRoleId
    )

    $items = @(ConvertFrom-InventoryArray -InventoryText $InventoryText -Label 'Role-assignment')
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $requiredProperties = @('id', 'scope', 'roleDefinitionId', 'principalId')
    $principalPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    foreach ($item in $items) {
        if ($item -isnot [pscustomobject]) {
            throw 'Role-assignment inventory was not a valid assignment array; cleanup stopped before further mutation.'
        }
        foreach ($property in $requiredProperties) {
            if ($property -notin $item.PSObject.Properties.Name -or
                $item.$property -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$item.$property) -or
                [string]$item.$property -match "[`r`n`t]") {
                throw 'Role-assignment inventory was not a valid assignment array; cleanup stopped before further mutation.'
            }
        }
        $roleId = [string]$item.id
        if (-not $seen.Add($roleId)) {
            throw 'Role-assignment inventory contains a duplicate item; cleanup stopped before further mutation.'
        }
        $roleScope = [string]$item.scope
        if ($roleScope.Equals($ExpectedScope, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($RequireEmpty) {
                throw 'Exact-scope role-assignment inventory is not empty before resource-group deletion; cleanup stopped.'
            }
            if (-not $roleId.Equals($ReviewerRoleId, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Role-assignment inventory contains an unexpected exact-scope assignment; cleanup stopped before further mutation.'
            }
            if (-not ([string]$item.roleDefinitionId).Equals($ExpectedReaderRoleId, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]$item.principalId -notmatch $principalPattern) {
                throw 'Reviewer role-assignment inventory properties are unexpected; cleanup stopped before further mutation.'
            }
        }
        elseif ($roleScope.StartsWith("$ExpectedScope/", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Role-assignment inventory contains an unexpected descendant-scope assignment; cleanup stopped before further mutation.'
        }
    }
}

Test-DeploymentName -Name $DeploymentName
Test-AzureSubscriptionContext -SubscriptionId $SubscriptionId
if ($Confirmation -cne "DELETE:$DeploymentName") {
    throw "Cleanup stopped. Pass -Confirmation DELETE:$DeploymentName after preserving sanitized evidence."
}

$manifestText = (& az deployment sub show `
    --name $DeploymentName `
    --subscription $SubscriptionId `
    --query properties.outputs.cleanupManifest.value `
    --output json `
    --only-show-errors 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the deployment cleanup manifest; nothing was deleted.' }

try {
    $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw 'Cleanup manifest was malformed JSON; nothing was deleted.'
}
if ($manifest.schemaVersion -ne '1.2' -or $manifest.labMarker -ne 'azure-governance-automation') {
    throw 'Cleanup manifest failed schema or lab-marker validation; nothing was deleted.'
}
if ([string]::IsNullOrWhiteSpace([string]$manifest.prefix) -or $manifest.prefix -notmatch '^[a-z0-9]{3,12}$') {
    throw 'Cleanup manifest has an invalid lowercase alphanumeric prefix; nothing was deleted.'
}
if ([string]::IsNullOrWhiteSpace([string]$manifest.governanceResourceGroupName)) {
    throw 'Cleanup manifest has no governance resource-group name; nothing was deleted.'
}

$ids = $manifest.resourceIds
$policyDefinitionIds = @($ids.policyDefinitions)
$remediationIds = @($ids.remediations)
$prefix = [string]$manifest.prefix
$expectedResourceGroupName = "rg-$prefix-governance"
if ($manifest.governanceResourceGroupName -cne $expectedResourceGroupName) {
    throw 'Manifest resource-group name does not match its prefix; nothing was deleted.'
}

$subscriptionBase = "/subscriptions/$SubscriptionId"
$resourceGroupId = "$subscriptionBase/resourceGroups/$expectedResourceGroupName"
$expectedLockId = "$resourceGroupId/providers/Microsoft.Authorization/locks/$prefix-delete-protection"
$expectedActionGroupId = "$resourceGroupId/providers/Microsoft.Insights/actionGroups/ag-$prefix-cost"
$expectedBudgetId = "$subscriptionBase/providers/Microsoft.Consumption/budgets/$prefix-monthly-guardrail"
$expectedPolicyAssignmentId = "$subscriptionBase/providers/Microsoft.Authorization/policyAssignments/$prefix-guardrails"
$expectedPolicySetId = "$subscriptionBase/providers/Microsoft.Authorization/policySetDefinitions/$prefix-baseline"
$expectedSubscriptionDeploymentNames = @(
    "$prefix-subscription-budget"
    "$prefix-policy-governance"
)
$expectedResourceGroupDeploymentNames = @(
    "$prefix-notification-group"
    "$prefix-reviewer-access"
    "$prefix-resource-lock"
)

function Test-ExactNameSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Actual,

        [Parameter(Mandatory)]
        [string[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Label manifest set is incomplete or contains extra entries; nothing was deleted."
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Actual) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value) -or [string]$value -match "[`r`n]") {
            throw "$Label contains an invalid name; nothing was deleted."
        }
        if (-not $seen.Add([string]$value)) {
            throw "$Label contains a duplicate name; nothing was deleted."
        }
        $matched = $false
        foreach ($expectedValue in $Expected) {
            if ([string]$value -eq $expectedValue) { $matched = $true }
        }
        if (-not $matched) { throw "$Label contains an unexpected name; nothing was deleted." }
    }
}

if ('deploymentNames' -notin $manifest.PSObject.Properties.Name -or
    'subscriptionModules' -notin $manifest.deploymentNames.PSObject.Properties.Name -or
    'resourceGroupModules' -notin $manifest.deploymentNames.PSObject.Properties.Name) {
    throw 'Cleanup manifest is missing deterministic deployment names; nothing was deleted.'
}
$subscriptionDeploymentNames = @($manifest.deploymentNames.subscriptionModules)
$resourceGroupDeploymentNames = @($manifest.deploymentNames.resourceGroupModules)
Test-ExactNameSet -Actual $subscriptionDeploymentNames -Expected $expectedSubscriptionDeploymentNames -Label 'Subscription module deployment names'
Test-ExactNameSet -Actual $resourceGroupDeploymentNames -Expected $expectedResourceGroupDeploymentNames -Label 'Resource-group module deployment names'
$subscriptionDeploymentIds = @(
    foreach ($moduleName in $subscriptionDeploymentNames) {
        "$subscriptionBase/providers/Microsoft.Resources/deployments/$moduleName"
    }
)

Test-ExactManifestResourceId -ResourceId $ids.lock -ExpectedResourceId $expectedLockId -Label 'Lock ID'
Test-ExactManifestResourceId -ResourceId $ids.actionGroup -ExpectedResourceId $expectedActionGroupId -Label 'Action group ID'
Test-ExactManifestResourceId -ResourceId $ids.budget -ExpectedResourceId $expectedBudgetId -Label 'Budget ID'
Test-ExactManifestResourceId -ResourceId $ids.policyAssignment -ExpectedResourceId $expectedPolicyAssignmentId -Label 'Policy assignment ID'
Test-ExactManifestResourceId -ResourceId $ids.policySetDefinition -ExpectedResourceId $expectedPolicySetId -Label 'Policy set definition ID'

$expectedPolicyDefinitionIds = @(
    "$subscriptionBase/providers/Microsoft.Authorization/policyDefinitions/$prefix-inherit-rg-tag",
    "$subscriptionBase/providers/Microsoft.Authorization/policyDefinitions/$prefix-require-rg-tag",
    "$subscriptionBase/providers/Microsoft.Authorization/policyDefinitions/$prefix-allowed-locations"
)
if ($policyDefinitionIds.Count -ne $expectedPolicyDefinitionIds.Count) {
    throw 'Policy definition manifest count is unexpected; nothing was deleted.'
}
foreach ($expectedId in $expectedPolicyDefinitionIds) {
    if (-not ($policyDefinitionIds | Where-Object { $_.Equals($expectedId, [System.StringComparison]::OrdinalIgnoreCase) })) {
        throw 'Policy definition manifest set is unexpected; nothing was deleted.'
    }
}

$expectedRemediationIds = @(
    "$subscriptionBase/providers/Microsoft.PolicyInsights/remediations/$prefix-remediate-environment",
    "$subscriptionBase/providers/Microsoft.PolicyInsights/remediations/$prefix-remediate-owner"
)
if ($remediationIds.Count -ne 2) {
    throw 'Remediation manifest count is unexpected; nothing was deleted.'
}
foreach ($resourceId in $remediationIds) {
    if (-not ($expectedRemediationIds | Where-Object { $_.Equals($resourceId, [System.StringComparison]::OrdinalIgnoreCase) })) {
        throw 'Remediation ID is not an expected lab remediation; nothing was deleted.'
    }
}
foreach ($expectedId in $expectedRemediationIds) {
    if (-not ($remediationIds | Where-Object { $_.Equals($expectedId, [System.StringComparison]::OrdinalIgnoreCase) })) {
        throw 'Remediation manifest set is incomplete or duplicated; nothing was deleted.'
    }
}

$roleGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$remediationRolePattern = '^' + [regex]::Escape("$subscriptionBase/providers/Microsoft.Authorization/roleAssignments/") + $roleGuidPattern + '$'
$reviewerRolePattern = '^' + [regex]::Escape("$resourceGroupId/providers/Microsoft.Authorization/roleAssignments/") + $roleGuidPattern + '$'
if ([string]::IsNullOrWhiteSpace([string]$ids.remediationRoleAssignment) -or $ids.remediationRoleAssignment -notmatch $remediationRolePattern) {
    throw 'Remediation role assignment type or scope is unexpected; nothing was deleted.'
}
if ([string]::IsNullOrWhiteSpace([string]$ids.reviewerRoleAssignment) -or $ids.reviewerRoleAssignment -notmatch $reviewerRolePattern) {
    throw 'Reviewer role assignment type or scope is unexpected; nothing was deleted.'
}

function Test-ResourceGroupMarker {
    [CmdletBinding()]
    param()

    $resourceGroupText = (& az group show `
        --name $expectedResourceGroupName `
        --subscription $SubscriptionId `
        --output json `
        --only-show-errors 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read and verify the governance resource group; cleanup stopped.'
    }
    try {
        $resourceGroup = $resourceGroupText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'Resource-group marker inventory was malformed; cleanup stopped.'
    }
    if ($resourceGroup -isnot [pscustomobject] -or
        'id' -notin $resourceGroup.PSObject.Properties.Name -or
        'tags' -notin $resourceGroup.PSObject.Properties.Name -or
        $resourceGroup.tags -isnot [pscustomobject] -or
        'portfolioLab' -notin $resourceGroup.tags.PSObject.Properties.Name -or
        'managedBy' -notin $resourceGroup.tags.PSObject.Properties.Name) {
        throw 'Resource-group marker inventory was malformed; cleanup stopped.'
    }
    if ($resourceGroup.tags.portfolioLab -ne 'azure-governance-automation' -or $resourceGroup.tags.managedBy -ne 'bicep') {
        throw 'Resource-group safety markers do not match; cleanup stopped.'
    }
    if (-not ([string]$resourceGroup.id).Equals($resourceGroupId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resource-group ID does not match the exact expected lab scope; cleanup stopped.'
    }
}

function Test-ResourceGroupInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$RequireEmpty
    )

    $directResources = Get-AzureInventoryJson `
        -Label 'direct resource-group resources' `
        -CliArguments @(
            'resource', 'list',
            '--subscription', $SubscriptionId,
            '--resource-group', $expectedResourceGroupName,
            '--query', '[].id',
            '--output', 'json',
            '--only-show-errors'
        )
    $locks = Get-AzureInventoryJson `
        -Label 'resource-group locks' `
        -CliArguments @(
            'lock', 'list',
            '--subscription', $SubscriptionId,
            '--resource-group', $expectedResourceGroupName,
            '--query', '[].id',
            '--output', 'json',
            '--only-show-errors'
        )
    $subscriptionRoles = Get-AzureInventoryJson `
        -Label 'subscription role assignments' `
        -CliArguments @(
            'role', 'assignment', 'list',
            '--subscription', $SubscriptionId,
            '--all',
            '--fill-principal-name', 'false',
            '--fill-role-definition-name', 'false',
            '--query', '[].{id:id,scope:scope,roleDefinitionId:roleDefinitionId,principalId:principalId}',
            '--output', 'json',
            '--only-show-errors'
        )
    $deployments = Get-AzureInventoryJson `
        -Label 'resource-group deployment records' `
        -CliArguments @(
            'deployment', 'group', 'list',
            '--subscription', $SubscriptionId,
            '--resource-group', $expectedResourceGroupName,
            '--query', '[].name',
            '--output', 'json',
            '--only-show-errors'
        )

    Test-AllowedStringInventory `
        -InventoryText $directResources `
        -Label 'Direct resource-group resource' `
        -RequireEmpty $RequireEmpty `
        -Allowed @([string]$ids.actionGroup)
    Test-AllowedStringInventory `
        -InventoryText $locks `
        -Label 'Resource-group lock' `
        -RequireEmpty $RequireEmpty `
        -Allowed @([string]$ids.lock)
    Test-AllowedRoleInventory `
        -InventoryText $subscriptionRoles `
        -RequireEmpty $RequireEmpty `
        -ExpectedScope $resourceGroupId `
        -ReviewerRoleId ([string]$ids.reviewerRoleAssignment) `
        -ExpectedReaderRoleId "$subscriptionBase/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    Test-AllowedStringInventory `
        -InventoryText $deployments `
        -Label 'Resource-group deployment record' `
        -RequireEmpty $false `
        -Allowed $resourceGroupDeploymentNames
}

function Test-ResourceGroupPresence {
    [CmdletBinding()]
    param()

    $output = (& az group exists `
        --name $expectedResourceGroupName `
        --subscription $SubscriptionId `
        --only-show-errors 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not determine whether the governance resource group exists; nothing was deleted.'
    }
    if ($output -ceq 'true') { return $true }
    if ($output -ceq 'false') { return $false }
    throw 'Resource-group existence inventory returned an invalid value; nothing was deleted.'
}

# Ownership and complete resource-group contents are checked before any delete,
# including the lock. A verified absent group permits a late-stage partial rerun
# to finish only the manifest-bound subscription resources/deployment records.
$resourceGroupPresent = Test-ResourceGroupPresence
if ($resourceGroupPresent) {
    Test-ResourceGroupMarker
    Test-ResourceGroupInventory -RequireEmpty $false
}

function Test-LabRoleAssignment {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$ExpectedScope,

        [Parameter(Mandatory)]
        [string]$ExpectedRoleGuid,

        [Parameter(Mandatory)]
        [string]$ExpectedPrincipalType,

        [Parameter(Mandatory)]
        [string]$ExpectedDescription,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return }
    if (-not (Test-AzureResourceExistence -ResourceId $ResourceId -ApiVersion '2022-04-01')) { return }
    $url = "$($ResourceId)?api-version=2022-04-01"
    $roleText = (& az rest --method get --url $url --only-show-errors --output json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect $Label; nothing was deleted." }
    $role = $roleText | ConvertFrom-Json
    $roleSuffix = "/providers/Microsoft.Authorization/roleDefinitions/$ExpectedRoleGuid"
    if (-not ([string]$role.properties.scope).Equals($ExpectedScope, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$role.properties.roleDefinitionId).EndsWith($roleSuffix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $role.properties.principalType -ne $ExpectedPrincipalType -or
        $role.properties.description -ne $ExpectedDescription) {
        throw "$Label properties do not match the lab assignment; nothing was deleted."
    }
}

Test-LabRoleAssignment `
    -ResourceId $ids.remediationRoleAssignment `
    -ExpectedScope $subscriptionBase `
    -ExpectedRoleGuid '4a9ae827-6dc8-4573-8ac7-8239d42aa03f' `
    -ExpectedPrincipalType 'ServicePrincipal' `
    -ExpectedDescription 'Allows only the policy assignment managed identity to remediate resource tags at assignment scope.' `
    -Label 'remediation role assignment'
Test-LabRoleAssignment `
    -ResourceId $ids.reviewerRoleAssignment `
    -ExpectedScope $resourceGroupId `
    -ExpectedRoleGuid 'acdd72a7-3385-48ef-bd42-f606fba81ae7' `
    -ExpectedPrincipalType 'Group' `
    -ExpectedDescription 'Read-only access to the governance lab resource group.' `
    -Label 'reviewer role assignment'

Write-ContextConfirmation -SubscriptionId $SubscriptionId -Operation "cleanup deployment $DeploymentName"

# Dependency order is deliberate: lock first; remediation before assignment;
# assignment before initiative; initiative before definitions; budget before its
# action group; direct RG resources and assignments before the marked group;
# deterministic nested deployment records before the root deployment record.
Invoke-AzureResourceDelete -ResourceId $ids.lock -ApiVersion '2020-05-01' -Label 'management lock'
foreach ($resourceId in $remediationIds) { Invoke-AzureResourceDelete -ResourceId $resourceId -ApiVersion '2024-10-01' -Label 'policy remediation' }
Invoke-AzureResourceDelete -ResourceId $ids.policyAssignment -ApiVersion '2025-03-01' -Label 'policy assignment'
Invoke-AzureResourceDelete -ResourceId $ids.remediationRoleAssignment -ApiVersion '2022-04-01' -Label 'policy identity role assignment'
Invoke-AzureResourceDelete -ResourceId $ids.policySetDefinition -ApiVersion '2025-03-01' -Label 'policy initiative'
foreach ($resourceId in $policyDefinitionIds) { Invoke-AzureResourceDelete -ResourceId $resourceId -ApiVersion '2025-03-01' -Label 'policy definition' }
Invoke-AzureResourceDelete -ResourceId $ids.budget -ApiVersion '2024-08-01' -Label 'subscription budget'
Invoke-AzureResourceDelete -ResourceId $ids.reviewerRoleAssignment -ApiVersion '2022-04-01' -Label 'optional reviewer role assignment'
Invoke-AzureResourceDelete -ResourceId $ids.actionGroup -ApiVersion '2023-01-01' -Label 'action group'

if ($resourceGroupPresent) {
    # No mutation occurs between this final empty-content/ownership check and the
    # resource-group delete request.
    Test-ResourceGroupInventory -RequireEmpty $true
    Test-ResourceGroupMarker

    & az group delete `
        --name $manifest.governanceResourceGroupName `
        --subscription $SubscriptionId `
        --yes `
        --no-wait `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Resource-group delete request failed; cleanup stopped.' }

    & az group wait `
        --name $manifest.governanceResourceGroupName `
        --subscription $SubscriptionId `
        --deleted `
        --interval 10 `
        --timeout 600 `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Resource-group deletion was not observed before timeout.' }
}

foreach ($deploymentId in $subscriptionDeploymentIds) {
    Invoke-AzureResourceDelete `
        -ResourceId $deploymentId `
        -ApiVersion '2025-04-01' `
        -Label 'subscription module deployment record'
}

& az deployment sub delete `
    --name $DeploymentName `
    --subscription $SubscriptionId `
    --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Resources were removed, but the deployment record could not be deleted.' }

Write-Output 'Cleanup completed; the governance resource group is absent and deterministic deployment records were processed. Preserve the command result only as sanitized evidence.'
