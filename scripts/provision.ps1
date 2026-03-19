<#
.SYNOPSIS
    Provisions all Azure resources for the Ingestion Functions app using Bicep.

.DESCRIPTION
    Creates a resource group (if needed) and deploys the Bicep template with all
    required Azure services: Storage, Cosmos DB, AI Search, Document Intelligence,
    Azure OpenAI, ACR, Container Apps Environment, and Function App.

.PARAMETER ResourceGroupName
    Name of the resource group to create/use.

.PARAMETER Location
    Azure region for all resources (default: eastus2).

.PARAMETER NamingPrefix
    Naming prefix for all resources (3-12 chars, lowercase).

.PARAMETER Environment
    Environment identifier: dev, staging, or prod (default: dev).

.PARAMETER ParametersFile
    Path to the .bicepparam file (default: infra/main.bicepparam).

.EXAMPLE
    ./scripts/provision.ps1 -ResourceGroupName "rg-ingestion-dev" -NamingPrefix "ingest"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus2",

    [Parameter(Mandatory = $false)]
    [string]$NamingPrefix = "ingest",

    [Parameter(Mandatory = $false)]
    [ValidateSet("dev", "staging", "prod")]
    [string]$Environment = "dev",

    [Parameter(Mandatory = $false)]
    [string]$ParametersFile = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraDir = Join-Path (Split-Path -Parent $ScriptDir) "infra"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Ingestion Functions - Provision Resources" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Verify az CLI is available
if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) is not installed or not in PATH. Install from https://aka.ms/installazurecli"
    exit 1
}

# Verify logged in
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged into Azure CLI. Run 'az login' first."
    exit 1
}
$accountInfo = $account | ConvertFrom-Json
Write-Host "Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Yellow
Write-Host "Tenant:       $($accountInfo.tenantId)" -ForegroundColor Yellow
Write-Host ""

# Create resource group if it doesn't exist
Write-Host "[1/3] Ensuring resource group '$ResourceGroupName' exists in '$Location'..." -ForegroundColor Green
az group create --name $ResourceGroupName --location $Location --output none
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create resource group."
    exit 1
}
Write-Host "  Resource group ready." -ForegroundColor Gray

# Deploy Bicep template
Write-Host "[2/3] Deploying Bicep template..." -ForegroundColor Green
Write-Host "  Template: $InfraDir\main.bicep" -ForegroundColor Gray

$deployArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroupName
)

if ($ParametersFile -and (Test-Path $ParametersFile)) {
    Write-Host "  Parameters file: $ParametersFile" -ForegroundColor Gray
    # .bicepparam files contain the template reference via 'using', so only pass the params file
    $resolvedParamFile = (Resolve-Path $ParametersFile).Path
    $deployArgs += @("--parameters", $resolvedParamFile)
    # Override CLI-provided values on top of the param file
    $deployArgs += @("--parameters", "location=$Location", "namingPrefix=$NamingPrefix", "environment=$Environment")
} else {
    $deployArgs += @("--template-file", (Join-Path $InfraDir "main.bicep"))
    $deployArgs += @("--parameters", "location=$Location", "namingPrefix=$NamingPrefix", "environment=$Environment")
}

$deployResult = az @deployArgs --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Bicep deployment failed:`n$deployResult"
    exit 1
}

# Filter out WARNING lines before parsing JSON
$jsonLines = $deployResult | Where-Object { $_ -notmatch '^WARNING:' }
$outputs = ($jsonLines | ConvertFrom-Json).properties.outputs
Write-Host "  Deployment succeeded." -ForegroundColor Gray

# Save outputs to a local file for use by other scripts
Write-Host "[3/3] Saving deployment outputs..." -ForegroundColor Green
$outputFile = Join-Path $ScriptDir "deploy-outputs.json"
$outputData = @{
    resourceGroupName    = $outputs.resourceGroupName.value
    storageAccountName   = $outputs.storageAccountName.value
    storageBlobEndpoint  = $outputs.storageBlobEndpoint.value
    cosmosEndpoint       = $outputs.cosmosEndpoint.value
    cosmosDatabase       = $outputs.cosmosDatabase.value
    searchEndpoint       = $outputs.searchEndpoint.value
    searchServiceName    = $outputs.searchServiceName.value
    docIntelEndpoint     = $outputs.docIntelEndpoint.value
    openAIEndpoint       = $outputs.openAIEndpoint.value
    acrLoginServer       = $outputs.acrLoginServer.value
    acrName              = $outputs.acrName.value
    functionAppName      = $outputs.functionAppName.value
    functionAppUrl       = $outputs.functionAppUrl.value
    functionAppPrincipalId = $outputs.functionAppPrincipalId.value
}
$outputData | ConvertTo-Json -Depth 5 | Set-Content $outputFile -Encoding UTF8
Write-Host "  Outputs saved to: $outputFile" -ForegroundColor Gray

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Provisioning Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Key resources:" -ForegroundColor Yellow
Write-Host "  Function App:  $($outputData.functionAppUrl)" -ForegroundColor White
Write-Host "  ACR:           $($outputData.acrLoginServer)" -ForegroundColor White
Write-Host "  AI Search:     $($outputData.searchEndpoint)" -ForegroundColor White
Write-Host "  Cosmos DB:     $($outputData.cosmosEndpoint)" -ForegroundColor White
Write-Host ""
Write-Host "Next step: Run ./scripts/build-deploy.ps1 to build and deploy the container." -ForegroundColor Yellow
