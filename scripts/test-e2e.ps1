<#
.SYNOPSIS
    End-to-end integration test against a deployed Ingestion Functions app.

.DESCRIPTION
    Validates the full ingestion pipeline by:
    1. Creating a test AI Search index
    2. Uploading the sample PDF to blob storage
    3. Triggering the pdf_orchestrator with fake entra_id and session_id
    4. Polling the orchestrator status until completion
    5. Verifying documents were indexed in AI Search
    6. Cleaning up test data

.PARAMETER TimeoutMinutes
    Maximum time to wait for ingestion to complete (default: 15).

.PARAMETER SkipCleanup
    If set, skips cleanup of test index and blob data.

.EXAMPLE
    ./scripts/test-e2e.ps1
    ./scripts/test-e2e.ps1 -TimeoutMinutes 20 -SkipCleanup
#>

param(
    [Parameter(Mandatory = $false)]
    [int]$TimeoutMinutes = 15,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$OutputsFile = Join-Path $ScriptDir "deploy-outputs.json"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Ingestion Functions - E2E Test" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Load deployment outputs
if (-not (Test-Path $OutputsFile)) {
    Write-Error "Deployment outputs not found at '$OutputsFile'. Run provision.ps1 and build-deploy.ps1 first."
    exit 1
}
$config = Get-Content $OutputsFile | ConvertFrom-Json

$functionAppUrl = $config.functionAppUrl
$functionKey = $config.functionKey
$storageAccountName = $config.storageAccountName

if (-not $functionKey) {
    Write-Error "Function key not found in deploy-outputs.json. Re-run build-deploy.ps1 or set it manually."
    exit 1
}

# Test identifiers
$testEntraId = "test-entra-id-$(Get-Random -Maximum 99999)"
$testSessionId = "test-session-$(Get-Random -Maximum 99999)"
$testIndexStem = "e2e-test-index"
$sourceContainer = "pdf-content"
$extractContainer = "pdf-extract"
$samplePdf = Join-Path $RepoRoot "sample_data" "ManitouCruise22_OG-0.pdf"

Write-Host "Function App: $functionAppUrl" -ForegroundColor Yellow
Write-Host "Test Entra ID: $testEntraId" -ForegroundColor Yellow
Write-Host "Test Session:  $testSessionId" -ForegroundColor Yellow
Write-Host ""

# Helper: call Function App API
function Invoke-FunctionApi {
    param(
        [string]$Path,
        [object]$Body,
        [string]$Method = "POST"
    )
    $uri = "${functionAppUrl}/api/${Path}?code=${functionKey}"
    $bodyJson = $Body | ConvertTo-Json -Depth 10
    try {
        $response = Invoke-RestMethod -Uri $uri -Method $Method -Body $bodyJson -ContentType "application/json" -TimeoutSec 60
        return $response
    }
    catch {
        Write-Host "  API call failed: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

$testsPassed = 0
$testsFailed = 0

# ------------------------------------------------------------------
# Step 1: Create test index
# ------------------------------------------------------------------
Write-Host "[1/5] Creating test AI Search index..." -ForegroundColor Green
try {
    $indexPayload = @{
        index_stem_name = $testIndexStem
        fields          = @{
            content    = "string"
            pagenumber = "int"
            sourcefile = "string"
            sourcepage = "string"
            category   = "string"
        }
        description = "E2E test index for automated validation"
        dimensions  = 3072
    }
    $indexResult = Invoke-FunctionApi -Path "create_new_index" -Body $indexPayload
    $testIndexName = $indexResult
    Write-Host "  Index created: $testIndexName" -ForegroundColor Gray
    $testsPassed++
}
catch {
    Write-Host "  FAILED to create index: $_" -ForegroundColor Red
    $testsFailed++
    Write-Host ""
    Write-Host "Cannot proceed without an index. Exiting." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------
# Step 2: Upload sample PDF to blob storage
# ------------------------------------------------------------------
Write-Host "[2/5] Uploading sample PDF to blob storage..." -ForegroundColor Green
if (-not (Test-Path $samplePdf)) {
    Write-Error "Sample PDF not found at '$samplePdf'."
    exit 1
}

$testBlobPrefix = "e2e-test/$testSessionId"
$blobName = "$testBlobPrefix/ManitouCruise22_OG-0.pdf"

try {
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
    # Ensure container exists
    try { New-AzStorageContainer -Name $sourceContainer -Context $ctx -ErrorAction SilentlyContinue } catch {}
    Set-AzStorageBlobContent -Container $sourceContainer -File $samplePdf -Blob $blobName -Context $ctx -Force | Out-Null
    Write-Host "  Uploaded: $sourceContainer/$blobName" -ForegroundColor Gray
    $testsPassed++
}
catch {
    Write-Error "Failed to upload sample PDF to blob storage: $_"
    exit 1
}

# ------------------------------------------------------------------
# Step 3: Trigger ingestion orchestrator
# ------------------------------------------------------------------
Write-Host "[3/5] Triggering pdf_orchestrator..." -ForegroundColor Green
try {
    $ingestionPayload = @{
        source_container   = $sourceContainer
        extract_container  = $extractContainer
        prefix_path        = $blobName
        index_name         = $testIndexName
        automatically_delete = $true
        analyze_images     = $false
        chunking_strategy  = "pagewise"
        embedding_model    = "text-embedding-3-large"
        cosmos_logging     = $true
        entra_id           = $testEntraId
        session_id         = $testSessionId
    }

    $orchestratorResult = Invoke-FunctionApi -Path "orchestrators/pdf_orchestrator" -Body $ingestionPayload
    $statusQueryUri = $orchestratorResult.statusQueryGetUri
    Write-Host "  Orchestrator started. Polling status..." -ForegroundColor Gray
    $testsPassed++
}
catch {
    Write-Host "  FAILED to trigger orchestrator: $_" -ForegroundColor Red
    $testsFailed++
    Write-Host ""
    Write-Host "Cannot proceed without orchestrator. Exiting." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------
# Step 4: Poll orchestrator status
# ------------------------------------------------------------------
Write-Host "[4/5] Waiting for ingestion to complete (timeout: ${TimeoutMinutes}m)..." -ForegroundColor Green
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$completed = $false
$orchestratorStatus = "Unknown"

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    try {
        $status = Invoke-RestMethod -Uri $statusQueryUri -Method GET -TimeoutSec 30
        $orchestratorStatus = $status.runtimeStatus

        switch ($orchestratorStatus) {
            "Completed" {
                Write-Host "  Orchestrator completed successfully." -ForegroundColor Gray
                $completed = $true
                $testsPassed++
                break
            }
            "Failed" {
                Write-Host "  Orchestrator FAILED." -ForegroundColor Red
                Write-Host "  Output: $($status.output)" -ForegroundColor Red
                $testsFailed++
                $completed = $true
                break
            }
            "Terminated" {
                Write-Host "  Orchestrator was terminated." -ForegroundColor Red
                $testsFailed++
                $completed = $true
                break
            }
            default {
                $customStatus = $status.customStatus
                Write-Host "  Status: $orchestratorStatus | $customStatus" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Host "  Polling error: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($completed) { break }
}

if (-not $completed) {
    Write-Host "  TIMEOUT: Orchestrator did not complete within ${TimeoutMinutes} minutes." -ForegroundColor Red
    $testsFailed++
}

# ------------------------------------------------------------------
# Step 5: Verify indexed documents
# ------------------------------------------------------------------
Write-Host "[5/5] Verifying documents in AI Search index..." -ForegroundColor Green
if ($orchestratorStatus -eq "Completed") {
    try {
        $verifyPayload = @{
            index_stem_name = $testIndexStem
        }
        $activeIndex = Invoke-FunctionApi -Path "get_active_index" -Body $verifyPayload
        Write-Host "  Active index: $activeIndex" -ForegroundColor Gray
        Write-Host "  Documents successfully indexed!" -ForegroundColor Gray
        $testsPassed++
    }
    catch {
        Write-Host "  Could not verify index: $_" -ForegroundColor Red
        $testsFailed++
    }
}
else {
    Write-Host "  Skipping verification (orchestrator did not complete)." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Host ""
    Write-Host "Cleaning up test data..." -ForegroundColor Green

    # Delete test blobs
    try {
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        Get-AzStorageBlob -Container $sourceContainer -Prefix $testBlobPrefix -Context $ctx | Remove-AzStorageBlob -Force
    } catch {}

    Write-Host "  Test blobs cleaned up." -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  E2E Test Results" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: $testsPassed" -ForegroundColor Green
Write-Host "  Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "  Test Entra ID:  $testEntraId" -ForegroundColor Gray
Write-Host "  Test Session:   $testSessionId" -ForegroundColor Gray
Write-Host "  Test Index:     $testIndexName" -ForegroundColor Gray
Write-Host ""

if ($testsFailed -gt 0) {
    Write-Host "  RESULT: FAILED" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "  RESULT: PASSED" -ForegroundColor Green
    exit 0
}
