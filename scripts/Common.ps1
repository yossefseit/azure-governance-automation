Set-StrictMode -Version Latest

$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:DefaultTemplateFile = Join-Path $script:RepositoryRoot 'infra/main.bicep'
$script:DefaultParametersFile = Join-Path $script:RepositoryRoot 'infra/environments/lab.example.bicepparam'

function Test-RequiredCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Test-DeploymentName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Name -notmatch '^[a-zA-Z0-9._() -]{1,64}$') {
        throw 'Deployment name contains unsupported characters or exceeds 64 characters.'
    }
}

function Test-AzureSubscriptionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$SubscriptionId
    )

    Test-RequiredCommand -Name 'az'
    $currentSubscriptionId = (& az account show --query id --output tsv --only-show-errors 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the current Azure CLI account. Sign in to a personally owned lab context and retry.'
    }
    if ([string]::IsNullOrWhiteSpace($currentSubscriptionId)) {
        throw 'Azure CLI returned an empty subscription ID.'
    }
    if (-not $currentSubscriptionId.Equals($SubscriptionId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Azure context mismatch. Requested $SubscriptionId; current context is $currentSubscriptionId. Context was not changed."
    }
}

function Invoke-NativeTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $Command"
    }
}

function Invoke-LocalBicepCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TemplateFile,

        [Parameter(Mandatory)]
        [string]$ParametersFile
    )

    if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
        throw "Template file not found: $TemplateFile"
    }
    if (-not (Test-Path -LiteralPath $ParametersFile -PathType Leaf)) {
        throw "Parameter file not found: $ParametersFile"
    }

    $validationDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "azure-governance-$([guid]::NewGuid().ToString('N'))"
    [void](New-Item -Path $validationDirectory -ItemType Directory)
    try {
        $templateOutput = Join-Path $validationDirectory 'main.json'
        $parameterOutput = Join-Path $validationDirectory 'parameters.json'

        if (-not [string]::IsNullOrWhiteSpace($env:BICEP_BIN)) {
            if (-not (Test-Path -LiteralPath $env:BICEP_BIN -PathType Leaf)) {
                throw "BICEP_BIN does not point to a file: $($env:BICEP_BIN)"
            }
            Invoke-NativeTool -Command $env:BICEP_BIN -Arguments @('lint', $TemplateFile)
            Invoke-NativeTool -Command $env:BICEP_BIN -Arguments @('build', $TemplateFile, '--outfile', $templateOutput)
            Invoke-NativeTool -Command $env:BICEP_BIN -Arguments @('build-params', $ParametersFile, '--outfile', $parameterOutput)
        }
        elseif (Get-Command bicep -ErrorAction SilentlyContinue) {
            Invoke-NativeTool -Command 'bicep' -Arguments @('lint', $TemplateFile)
            Invoke-NativeTool -Command 'bicep' -Arguments @('build', $TemplateFile, '--outfile', $templateOutput)
            Invoke-NativeTool -Command 'bicep' -Arguments @('build-params', $ParametersFile, '--outfile', $parameterOutput)
        }
        else {
            Test-RequiredCommand -Name 'az'
            Invoke-NativeTool -Command 'az' -Arguments @('bicep', 'version')
            Invoke-NativeTool -Command 'az' -Arguments @('bicep', 'lint', '--file', $TemplateFile)
            Invoke-NativeTool -Command 'az' -Arguments @('bicep', 'build', '--file', $TemplateFile, '--outfile', $templateOutput)
            Invoke-NativeTool -Command 'az' -Arguments @('bicep', 'build-params', '--file', $ParametersFile, '--outfile', $parameterOutput)
        }
    }
    finally {
        Remove-Item -LiteralPath $validationDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-ContextConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    Write-Output "Azure context verified: $SubscriptionId"
    Write-Output "Requested operation: $Operation"
    Write-Output 'No Azure subscription or tenant was changed by this script.'
}
