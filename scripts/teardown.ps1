<#
.SYNOPSIS
    Deletes the resource group and all contained resources.

.DESCRIPTION
    Tears down all Azure resources created by provision.ps1 by deleting the
    entire resource group. Prompts for confirmation unless -Force is specified.

.PARAMETER ResourceGroupName
    Name of the resource group to delete. If not provided, reads from deploy-outputs.json.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./scripts/teardown.ps1
    ./scripts/teardown.ps1 -ResourceGroupName "rg-ingestion-dev" -Force
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "",

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputsFile = Join-Path $ScriptDir "deploy-outputs.json"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Ingestion Functions - Teardown" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Determine resource group name
if (-not $ResourceGroupName) {
    if (Test-Path $OutputsFile) {
        $config = Get-Content $OutputsFile | ConvertFrom-Json
        $ResourceGroupName = $config.resourceGroupName
    }
    else {
        Write-Error "ResourceGroupName not provided and deploy-outputs.json not found."
        exit 1
    }
}

Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow
Write-Host ""

# Confirm deletion
if (-not $Force) {
    $confirm = Read-Host "This will PERMANENTLY DELETE all resources in '$ResourceGroupName'. Continue? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Delete resource group
Write-Host "Deleting resource group '$ResourceGroupName'..." -ForegroundColor Red
az group delete --name $ResourceGroupName --yes --no-wait
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to initiate resource group deletion."
    exit 1
}

# Clean up local outputs file
if (Test-Path $OutputsFile) {
    Remove-Item $OutputsFile -Force
    Write-Host "Cleaned up deploy-outputs.json" -ForegroundColor Gray
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Teardown Initiated" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource group deletion is in progress (async)." -ForegroundColor Yellow
Write-Host "Run 'az group show -n $ResourceGroupName' to check status." -ForegroundColor Yellow
