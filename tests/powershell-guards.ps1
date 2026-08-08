$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixtureDirectory = Join-Path $PSScriptRoot 'fixtures'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "governance-ps-$([guid]::NewGuid().ToString('N'))"
[void](New-Item -Path $testDirectory -ItemType Directory)
$mockLog = Join-Path $testDirectory 'az.log'
$mockState = Join-Path $testDirectory 'state'

function Invoke-ScriptProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [string[]]$AdditionalArguments = @()
    )

    $output = ('' | & pwsh -NoLogo -NoProfile -File $ScriptPath -SubscriptionId $SubscriptionId @AdditionalArguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Test-ExpectedFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ExpectedText,

        [string[]]$AdditionalArguments = @()
    )

    $result = Invoke-ScriptProcess `
        -ScriptPath $ScriptPath `
        -SubscriptionId $SubscriptionId `
        -AdditionalArguments $AdditionalArguments
    if ($result.ExitCode -eq 0) { throw "Command unexpectedly succeeded: $ScriptPath" }
    if (-not $result.Output.Contains($ExpectedText)) { throw "Expected '$ExpectedText' in output: $($result.Output)" }
}

function Invoke-CleanupProcess {
    [CmdletBinding()]
    param()

    return Invoke-ScriptProcess `
        -ScriptPath (Join-Path $repositoryRoot 'scripts/Cleanup.ps1') `
        -SubscriptionId $matchingSubscriptionId `
        -AdditionalArguments @('-DeploymentName', 'aglab-governance', '-Confirmation', 'DELETE:aglab-governance')
}

function Test-CleanupFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExpectedText
    )

    $result = Invoke-CleanupProcess
    if ($result.ExitCode -eq 0) { throw 'Cleanup unexpectedly succeeded.' }
    if (-not $result.Output.Contains($ExpectedText)) {
        throw "Expected '$ExpectedText' in cleanup output: $($result.Output)"
    }
}

function Test-NoCleanupMutation {
    [CmdletBinding()]
    param()

    $logText = Get-Content -LiteralPath $mockLog -Raw
    if ($logText -match 'deployment sub delete|group delete|rest --method delete') {
        throw 'A failure-guard scenario reached an Azure mutation command.'
    }
}

function Initialize-Scenario {
    [CmdletBinding()]
    param()

    Clear-Content -LiteralPath $mockLog
    Remove-Item -LiteralPath $mockState -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -Path $mockState -ItemType Directory)
    foreach ($name in @(
        'MOCK_INVENTORY_FAILURE',
        'MOCK_FINAL_DIRECT_RESOURCES_JSON',
        'MOCK_FINAL_LOCKS_JSON',
        'MOCK_FINAL_ROLE_ASSIGNMENTS_JSON',
        'MOCK_FINAL_ACTION_GROUP_ROLE_ASSIGNMENTS_JSON',
        'MOCK_FINAL_GROUP_DEPLOYMENTS_JSON',
        'MOCK_FINAL_RESOURCE_GROUP_JSON',
        'MOCK_GROUP_EXISTS_FAILURE',
        'MOCK_REST_GET_MODE'
    )) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:MOCK_GROUP_EXISTS_OUTPUT = 'true'
    $env:MOCK_RESOURCE_GROUP_JSON = $correctResourceGroupJson
    $env:MOCK_DIRECT_RESOURCES_JSON = ConvertTo-Json -InputObject @($actionGroupId) -Compress
    $env:MOCK_LOCKS_JSON = ConvertTo-Json -InputObject @($lockId) -Compress
    $env:MOCK_ROLE_ASSIGNMENTS_JSON = ConvertTo-Json -InputObject @(
        [ordered]@{
            id = $reviewerRoleId
            scope = $resourceGroupId
            roleDefinitionId = $readerRoleId
            principalId = $reviewerPrincipalId
        }
    ) -Compress
    $env:MOCK_ACTION_GROUP_ROLE_ASSIGNMENTS_JSON = '[]'
    $env:MOCK_GROUP_DEPLOYMENTS_JSON = ConvertTo-Json -InputObject @(
        'aglab-notification-group'
        'aglab-reviewer-access'
        'aglab-resource-lock'
    ) -Compress
    $env:MOCK_ABSENT_RESOURCE_IDS_JSON = '[]'
}

try {
    $matchingSubscriptionId = [guid]::NewGuid().ToString()
    $differentSubscriptionId = [guid]::NewGuid().ToString()
    [void](New-Item -Path $mockLog -ItemType File)
    $env:PATH = "$fixtureDirectory$([System.IO.Path]::PathSeparator)$($env:PATH)"
    $env:MOCK_AZ_LOG = $mockLog
    $env:MOCK_AZ_STATE_DIR = $mockState
    $env:MOCK_SUBSCRIPTION_ID = $matchingSubscriptionId

    Test-ExpectedFailure -ScriptPath (Join-Path $repositoryRoot 'scripts/Validate.ps1') -SubscriptionId $differentSubscriptionId -ExpectedText 'Azure context mismatch'
    Test-ExpectedFailure -ScriptPath (Join-Path $repositoryRoot 'scripts/WhatIf.ps1') -SubscriptionId $differentSubscriptionId -ExpectedText 'Azure context mismatch'
    Test-ExpectedFailure -ScriptPath (Join-Path $repositoryRoot 'scripts/Deploy.ps1') -SubscriptionId $matchingSubscriptionId -ExpectedText 'Final confirmation'
    Test-ExpectedFailure -ScriptPath (Join-Path $repositoryRoot 'scripts/Cleanup.ps1') -SubscriptionId $matchingSubscriptionId -ExpectedText 'Cleanup stopped'

    $subscriptionBase = "/subscriptions/$matchingSubscriptionId"
    $resourceGroupName = 'rg-aglab-governance'
    $resourceGroupId = "$subscriptionBase/resourceGroups/$resourceGroupName"
    $lockId = "$resourceGroupId/providers/Microsoft.Authorization/locks/aglab-delete-protection"
    $actionGroupId = "$resourceGroupId/providers/Microsoft.Insights/actionGroups/ag-aglab-cost"
    $budgetId = "$subscriptionBase/providers/Microsoft.Consumption/budgets/aglab-monthly-guardrail"
    $policyAssignmentId = "$subscriptionBase/providers/Microsoft.Authorization/policyAssignments/aglab-guardrails"
    $policySetId = "$subscriptionBase/providers/Microsoft.Authorization/policySetDefinitions/aglab-baseline"
    $policyInheritId = "$subscriptionBase/providers/Microsoft.Authorization/policyDefinitions/aglab-inherit-rg-tag"
    $policyRequiredId = "$subscriptionBase/providers/Microsoft.Authorization/policyDefinitions/aglab-require-rg-tag"
    $policyLocationsId = "$subscriptionBase/providers/Microsoft.Authorization/policyDefinitions/aglab-allowed-locations"
    $remediationRoleId = "$subscriptionBase/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid().ToString())"
    $reviewerRoleId = "$resourceGroupId/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid().ToString())"
    $reviewerPrincipalId = [guid]::NewGuid().ToString()
    $readerRoleId = "$subscriptionBase/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    $remediationEnvironmentId = "$subscriptionBase/providers/Microsoft.PolicyInsights/remediations/aglab-remediate-environment"
    $remediationOwnerId = "$subscriptionBase/providers/Microsoft.PolicyInsights/remediations/aglab-remediate-owner"
    $subscriptionBudgetDeploymentId = "$subscriptionBase/providers/Microsoft.Resources/deployments/aglab-subscription-budget"
    $policyGovernanceDeploymentId = "$subscriptionBase/providers/Microsoft.Resources/deployments/aglab-policy-governance"

    $env:MOCK_MANIFEST_JSON = [ordered]@{
        schemaVersion = '1.2'
        labMarker = 'azure-governance-automation'
        prefix = 'aglab'
        governanceResourceGroupName = $resourceGroupName
        deploymentNames = [ordered]@{
            subscriptionModules = @('aglab-subscription-budget', 'aglab-policy-governance')
            resourceGroupModules = @('aglab-notification-group', 'aglab-reviewer-access', 'aglab-resource-lock')
        }
        resourceIds = [ordered]@{
            lock = $lockId
            actionGroup = $actionGroupId
            budget = $budgetId
            reviewerRoleAssignment = $reviewerRoleId
            policyAssignment = $policyAssignmentId
            remediationRoleAssignment = $remediationRoleId
            policySetDefinition = $policySetId
            policyDefinitions = @($policyInheritId, $policyRequiredId, $policyLocationsId)
            remediations = @($remediationEnvironmentId, $remediationOwnerId)
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $env:MOCK_ACTION_GROUP_ID = $actionGroupId
    $env:MOCK_REMEDIATION_ROLE_ID = $remediationRoleId
    $env:MOCK_REVIEWER_ROLE_ID = $reviewerRoleId
    $env:MOCK_REMEDIATION_ROLE_JSON = [ordered]@{
        properties = [ordered]@{
            scope = $subscriptionBase
            roleDefinitionId = "$subscriptionBase/providers/Microsoft.Authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f"
            principalType = 'ServicePrincipal'
            description = 'Allows only the policy assignment managed identity to remediate resource tags at assignment scope.'
        }
    } | ConvertTo-Json -Depth 3 -Compress
    $env:MOCK_REVIEWER_ROLE_JSON = [ordered]@{
        properties = [ordered]@{
            scope = $resourceGroupId
            roleDefinitionId = $readerRoleId
            principalType = 'Group'
            description = 'Read-only access to the governance lab resource group.'
        }
    } | ConvertTo-Json -Depth 3 -Compress
    $correctResourceGroupJson = [ordered]@{
        id = $resourceGroupId
        tags = [ordered]@{
            portfolioLab = 'azure-governance-automation'
            managedBy = 'bicep'
        }
    } | ConvertTo-Json -Depth 3 -Compress

    Initialize-Scenario
    $env:MOCK_RESOURCE_GROUP_JSON = [ordered]@{
        id = $resourceGroupId
        tags = [ordered]@{ portfolioLab = 'wrong-marker'; managedBy = 'bicep' }
    } | ConvertTo-Json -Depth 3 -Compress
    Test-CleanupFailure -ExpectedText 'safety markers do not match'
    Test-NoCleanupMutation

    foreach ($mode in @('error', 'invalid')) {
        Initialize-Scenario
        if ($mode -eq 'error') {
            $env:MOCK_GROUP_EXISTS_FAILURE = 'true'
            $expected = 'Could not determine whether'
        }
        else {
            $env:MOCK_GROUP_EXISTS_OUTPUT = 'not-a-boolean'
            $expected = 'existence inventory returned an invalid value'
        }
        Test-CleanupFailure -ExpectedText $expected
        Test-NoCleanupMutation
    }

    foreach ($kind in @('resource', 'lock', 'role', 'deployment')) {
        Initialize-Scenario
        $env:MOCK_INVENTORY_FAILURE = $kind
        Test-CleanupFailure -ExpectedText 'Could not inventory'
        Test-NoCleanupMutation
    }

    Initialize-Scenario
    $env:MOCK_DIRECT_RESOURCES_JSON = 'not-json'
    Test-CleanupFailure -ExpectedText 'malformed JSON'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_LOCKS_JSON = '{}'
    Test-CleanupFailure -ExpectedText 'not a JSON array'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_DIRECT_RESOURCES_JSON = ConvertTo-Json -InputObject @($actionGroupId, $actionGroupId) -Compress
    Test-CleanupFailure -ExpectedText 'duplicate item'
    Test-NoCleanupMutation

    Initialize-Scenario
    $duplicateRole = [ordered]@{
        id = $reviewerRoleId
        scope = $resourceGroupId
        roleDefinitionId = $readerRoleId
        principalId = $reviewerPrincipalId
    }
    $env:MOCK_ROLE_ASSIGNMENTS_JSON = ConvertTo-Json -InputObject @($duplicateRole, $duplicateRole) -Compress
    Test-CleanupFailure -ExpectedText 'duplicate item'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_GROUP_DEPLOYMENTS_JSON = ConvertTo-Json -InputObject @('aglab-notification-group', 'aglab-notification-group') -Compress
    Test-CleanupFailure -ExpectedText 'duplicate item'
    Test-NoCleanupMutation

    $unexpectedResourceId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/unexpected"
    Initialize-Scenario
    $env:MOCK_DIRECT_RESOURCES_JSON = ConvertTo-Json -InputObject @($actionGroupId, $unexpectedResourceId) -Compress
    Test-CleanupFailure -ExpectedText 'Direct resource-group resource inventory contains an unexpected item'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_LOCKS_JSON = ConvertTo-Json -InputObject @($lockId, "$resourceGroupId/providers/Microsoft.Authorization/locks/unexpected") -Compress
    Test-CleanupFailure -ExpectedText 'Resource-group lock inventory contains an unexpected item'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_ROLE_ASSIGNMENTS_JSON = ConvertTo-Json -InputObject @(
        [ordered]@{
            id = "$resourceGroupId/providers/Microsoft.Authorization/roleAssignments/unexpected"
            scope = $resourceGroupId
            roleDefinitionId = $readerRoleId
            principalId = $reviewerPrincipalId
        }
    ) -Compress
    Test-CleanupFailure -ExpectedText 'unexpected exact-scope assignment'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_ROLE_ASSIGNMENTS_JSON = ConvertTo-Json -InputObject @(
        [ordered]@{
            id = $reviewerRoleId
            scope = $actionGroupId
            roleDefinitionId = $readerRoleId
            principalId = $reviewerPrincipalId
        }
    ) -Compress
    Test-CleanupFailure -ExpectedText 'unexpected descendant-scope'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_GROUP_DEPLOYMENTS_JSON = ConvertTo-Json -InputObject @('aglab-notification-group', 'unexpected-module') -Compress
    Test-CleanupFailure -ExpectedText 'Resource-group deployment record inventory contains an unexpected item'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_REST_GET_MODE = 'error-with-incidental-404'
    Test-CleanupFailure -ExpectedText 'Could not verify resource state before deletion'
    Test-NoCleanupMutation

    Initialize-Scenario
    $env:MOCK_FINAL_DIRECT_RESOURCES_JSON = ConvertTo-Json -InputObject @($unexpectedResourceId) -Compress
    Test-CleanupFailure -ExpectedText 'Direct resource-group resource inventory is not empty'
    $logText = Get-Content -LiteralPath $mockLog -Raw
    if (-not $logText.Contains('rest --method delete')) { throw 'Final-drift test never reached the post-mutation recheck.' }
    if ($logText -match '(?m)^group delete') { throw 'Final drift did not block resource-group deletion.' }

    Initialize-Scenario
    $env:MOCK_DIRECT_RESOURCES_JSON = ConvertTo-Json -InputObject @($actionGroupId.ToUpperInvariant()) -Compress
    $env:MOCK_LOCKS_JSON = ConvertTo-Json -InputObject @($lockId.ToUpperInvariant()) -Compress
    $env:MOCK_ROLE_ASSIGNMENTS_JSON = ConvertTo-Json -InputObject @(
        [ordered]@{
            id = $reviewerRoleId.ToUpperInvariant()
            scope = $resourceGroupId.ToUpperInvariant()
            roleDefinitionId = $readerRoleId.ToUpperInvariant()
            principalId = $reviewerPrincipalId
        }
    ) -Compress
    $env:MOCK_GROUP_DEPLOYMENTS_JSON = ConvertTo-Json -InputObject @('AGLAB-NOTIFICATION-GROUP', 'AGLAB-REVIEWER-ACCESS', 'AGLAB-RESOURCE-LOCK') -Compress
    $result = Invoke-CleanupProcess
    if ($result.ExitCode -ne 0) { throw "Complete cleanup mock failed: $($result.Output)" }
    if (-not $result.Output.Contains('governance resource group is absent')) {
        throw "Complete cleanup mock did not report success: $($result.Output)"
    }

    $logLines = @(Get-Content -LiteralPath $mockLog)
    if (@($logLines | Where-Object { $_ -match '^resource list ' }).Count -ne 2) { throw 'Direct resources were not inventoried twice.' }
    if (@($logLines | Where-Object { $_ -match '^lock list ' }).Count -ne 2) { throw 'Locks were not inventoried twice.' }
    if (@($logLines | Where-Object { $_ -match '^role assignment list .*--all ' }).Count -ne 2) { throw 'Subscription roles were not inventoried twice.' }
    if (@($logLines | Where-Object { $_ -match '^deployment group list ' }).Count -ne 2) { throw 'RG deployments were not inventoried twice.' }
    if (@($logLines | Where-Object { $_ -match '^group show ' }).Count -ne 2) { throw 'RG markers were not validated twice.' }

    $mutationLog = @($logLines | Where-Object { $_ -match '^(rest --method delete|group delete|group wait|deployment sub delete)' })
    $expectedMutations = @(
        "rest --method delete --url $lockId`?api-version=2020-05-01 --only-show-errors --output none"
        "rest --method delete --url $remediationEnvironmentId`?api-version=2024-10-01 --only-show-errors --output none"
        "rest --method delete --url $remediationOwnerId`?api-version=2024-10-01 --only-show-errors --output none"
        "rest --method delete --url $policyAssignmentId`?api-version=2025-03-01 --only-show-errors --output none"
        "rest --method delete --url $remediationRoleId`?api-version=2022-04-01 --only-show-errors --output none"
        "rest --method delete --url $policySetId`?api-version=2025-03-01 --only-show-errors --output none"
        "rest --method delete --url $policyInheritId`?api-version=2025-03-01 --only-show-errors --output none"
        "rest --method delete --url $policyRequiredId`?api-version=2025-03-01 --only-show-errors --output none"
        "rest --method delete --url $policyLocationsId`?api-version=2025-03-01 --only-show-errors --output none"
        "rest --method delete --url $budgetId`?api-version=2024-08-01 --only-show-errors --output none"
        "rest --method delete --url $reviewerRoleId`?api-version=2022-04-01 --only-show-errors --output none"
        "rest --method delete --url $actionGroupId`?api-version=2023-01-01 --only-show-errors --output none"
        "group delete --name $resourceGroupName --subscription $matchingSubscriptionId --yes --no-wait --only-show-errors"
        "group wait --name $resourceGroupName --subscription $matchingSubscriptionId --deleted --interval 10 --timeout 600 --only-show-errors"
        "rest --method delete --url $subscriptionBudgetDeploymentId`?api-version=2025-04-01 --only-show-errors --output none"
        "rest --method delete --url $policyGovernanceDeploymentId`?api-version=2025-04-01 --only-show-errors --output none"
        "deployment sub delete --name aglab-governance --subscription $matchingSubscriptionId --only-show-errors"
    )
    if ($mutationLog.Count -ne $expectedMutations.Count) {
        throw "Expected $($expectedMutations.Count) ordered cleanup operations, got $($mutationLog.Count)."
    }
    for ($index = 0; $index -lt $expectedMutations.Count; $index++) {
        if ($mutationLog[$index] -cne $expectedMutations[$index]) {
            throw "Cleanup order mismatch at operation $($index + 1): $($mutationLog[$index])"
        }
    }

    Initialize-Scenario
    $env:MOCK_LOCKS_JSON = '[]'
    $env:MOCK_ROLE_ASSIGNMENTS_JSON = '[]'
    $env:MOCK_ABSENT_RESOURCE_IDS_JSON = ConvertTo-Json -InputObject @(
        $lockId
        $reviewerRoleId
        $remediationRoleId
        $remediationEnvironmentId
        $remediationOwnerId
    ) -Compress
    $result = Invoke-CleanupProcess
    if ($result.ExitCode -ne 0) { throw "Cleanup failed with all optional resources absent: $($result.Output)" }
    $logText = Get-Content -LiteralPath $mockLog -Raw
    foreach ($absentId in @($lockId, $reviewerRoleId, $remediationRoleId)) {
        if ($logText.Contains("rest --method delete --url $absentId`?")) {
            throw 'Cleanup tried to delete an optional resource verified absent.'
        }
    }

    Initialize-Scenario
    $env:MOCK_GROUP_EXISTS_OUTPUT = 'false'
    $env:MOCK_ABSENT_RESOURCE_IDS_JSON = ConvertTo-Json -InputObject @(
        $lockId
        $reviewerRoleId
        $actionGroupId
        $subscriptionBudgetDeploymentId
    ) -Compress
    $result = Invoke-CleanupProcess
    if ($result.ExitCode -ne 0) { throw "Cleanup could not resume after verified RG absence: $($result.Output)" }
    $logText = Get-Content -LiteralPath $mockLog -Raw
    if ($logText -match '(?m)^(resource list|lock list|role assignment list|deployment group list|group show|group delete|group wait)') {
        throw 'RG-absent resume queried or mutated the missing group after existence was verified false.'
    }
    if (-not $logText.Contains("rest --method delete --url $policyGovernanceDeploymentId`?api-version=2025-04-01")) {
        throw 'RG-absent resume did not delete the remaining subscription module record.'
    }
    if (-not $logText.Contains('deployment sub delete --name aglab-governance')) {
        throw 'RG-absent resume did not delete the root deployment record last.'
    }

    Write-Output 'PASS PowerShell lifecycle guards, strict drift inventories, partial reruns, and exact cleanup ordering.'
}
finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
