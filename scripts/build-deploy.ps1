<#
.SYNOPSIS
    Builds the Docker container, pushes to ACR, and updates the Function App.

.DESCRIPTION
    Uses deployment outputs from provision.ps1 to:
    1. Build the Docker image locally
    2. Login to ACR and push the image
    3. Update the Function App to use the new image

.PARAMETER Tag
    Container image tag (default: latest).

.PARAMETER ImageName
    Container image name (default: ingestionfunctions).

.EXAMPLE
    ./scripts/build-deploy.ps1
    ./scripts/build-deploy.ps1 -Tag "v1.2.3"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Tag = "latest",

    [Parameter(Mandatory = $false)]
    [string]$ImageName = "ingestionfunctions"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$OutputsFile = Join-Path $ScriptDir "deploy-outputs.json"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Ingestion Functions - Build & Deploy" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Load deployment outputs
if (-not (Test-Path $OutputsFile)) {
    Write-Error "Deployment outputs not found at '$OutputsFile'. Run provision.ps1 first."
    exit 1
}
$config = Get-Content $OutputsFile | ConvertFrom-Json
$acrLoginServer = $config.acrLoginServer
$acrName = $config.acrName
$functionAppName = $config.functionAppName
$resourceGroupName = $config.resourceGroupName

$fullImageName = "${acrLoginServer}/${ImageName}:${Tag}"
Write-Host "Image:        $fullImageName" -ForegroundColor Yellow
Write-Host "Function App: $functionAppName" -ForegroundColor Yellow
Write-Host ""

# Step 1: Build Docker image
Write-Host "[1/3] Building Docker image..." -ForegroundColor Green
Push-Location $RepoRoot
try {
    docker build -t $fullImageName .
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker build failed."
        exit 1
    }
    Write-Host "  Build succeeded." -ForegroundColor Gray
}
finally {
    Pop-Location
}

# Step 2: Push to ACR
Write-Host "[2/3] Pushing to ACR ($acrLoginServer)..." -ForegroundColor Green
az acr login --name $acrName
if ($LASTEXITCODE -ne 0) {
    Write-Error "ACR login failed."
    exit 1
}

docker push $fullImageName
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker push failed."
    exit 1
}
Write-Host "  Push succeeded." -ForegroundColor Gray

# Step 3: Update Function App container image
Write-Host "[3/3] Updating Function App container image..." -ForegroundColor Green
az functionapp config container set `
    --name $functionAppName `
    --resource-group $resourceGroupName `
    --image $fullImageName `
    --registry-server $acrLoginServer
if ($LASTEXITCODE -ne 0) {
    Write-Error "Function App container update failed."
    exit 1
}
Write-Host "  Function App updated." -ForegroundColor Gray

# Get the function key for API calls
Write-Host ""
Write-Host "Retrieving Function App host key..." -ForegroundColor Green
$keys = az functionapp keys list --name $functionAppName --resource-group $resourceGroupName --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    $functionKey = ($keys | ConvertFrom-Json).functionKeys.default
    if ($functionKey) {
        # Update the outputs file with the function key
        $config | Add-Member -NotePropertyName "functionKey" -NotePropertyValue $functionKey -Force
        $config | ConvertTo-Json -Depth 5 | Set-Content $OutputsFile -Encoding UTF8
        Write-Host "  Function key saved to deploy-outputs.json" -ForegroundColor Gray
    }
}
else {
    Write-Host "  Could not retrieve function key (app may still be starting). Try again later." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Build & Deploy Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Function App URL: $($config.functionAppUrl)" -ForegroundColor White
Write-Host ""
Write-Host "Next step: Run ./scripts/test-e2e.ps1 to validate the deployment." -ForegroundColor Yellow
