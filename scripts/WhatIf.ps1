[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [string]$Location = 'westeurope',
    [string]$DeploymentName = 'aglab-whatif',
    [string]$ParametersFile,
    [string]$TemplateFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

if ([string]::IsNullOrWhiteSpace($ParametersFile)) { $ParametersFile = $script:DefaultParametersFile }
if ([string]::IsNullOrWhiteSpace($TemplateFile)) { $TemplateFile = $script:DefaultTemplateFile }
if ([string]::IsNullOrWhiteSpace($Location)) { throw 'Location must not be empty.' }

Test-DeploymentName -Name $DeploymentName
Test-AzureSubscriptionContext -SubscriptionId $SubscriptionId
Invoke-LocalBicepCheck -TemplateFile $TemplateFile -ParametersFile $ParametersFile
Write-ContextConfirmation -SubscriptionId $SubscriptionId -Operation 'subscription what-if (no deployment)'

& az deployment sub what-if `
    --name $DeploymentName `
    --location $Location `
    --subscription $SubscriptionId `
    --template-file $TemplateFile `
    --parameters $ParametersFile `
    --result-format FullResourcePayloads `
    --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Azure what-if failed with exit code $LASTEXITCODE." }
