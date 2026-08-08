[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [string]$Location = 'westeurope',
    [string]$DeploymentName = 'aglab-validate',
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
Write-ContextConfirmation -SubscriptionId $SubscriptionId -Operation 'authenticated ARM validation (no deployment)'

& az deployment sub validate `
    --name $DeploymentName `
    --location $Location `
    --subscription $SubscriptionId `
    --template-file $TemplateFile `
    --parameters $ParametersFile `
    --only-show-errors `
    --output json
if ($LASTEXITCODE -ne 0) { throw "Azure validation failed with exit code $LASTEXITCODE." }
