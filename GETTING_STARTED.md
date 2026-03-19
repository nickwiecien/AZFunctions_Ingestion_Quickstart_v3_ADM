# Getting Started — Provision, Deploy & Test

This guide walks you through provisioning Azure resources, building and deploying the ingestion functions container, and running an end-to-end test — all from your local machine using PowerShell scripts.

## Prerequisites

| Requirement | How to verify |
|---|---|
| **Azure CLI** | `az --version` |
| **Bicep CLI** (bundled with az) | `az bicep version` |
| **Docker Desktop** | `docker --version` |
| **Python 3.11+** | `python --version` |
| **PowerShell Az Module** | `Get-Module -ListAvailable Az.Storage` (install: `Install-Module Az -Scope CurrentUser`) |
| **Azure Subscription** with Owner/Contributor + User Access Administrator | `az account show` |
| **Logged into Azure CLI** | `az login --tenant <your-tenant-id>` |

> **Multi-tenant note:** If you have guest access to many tenants, use `az login --tenant <tenant-id>` to target the specific tenant with your subscription. A plain `az login` may cause token refresh issues.

## Directory Structure

```
infra/
├── main.bicep              # Main Bicep orchestrator
├── main.bicepparam         # Default parameter values
└── modules/
    ├── acr.bicep           # Azure Container Registry
    ├── ai-search.bicep     # Azure AI Search
    ├── cosmos.bicep         # Cosmos DB (serverless)
    ├── doc-intelligence.bicep # Document Intelligence
    ├── function-app.bicep   # Function App on Premium plan (EP1)
    ├── monitoring.bicep     # Log Analytics + App Insights
    ├── openai.bicep         # Azure OpenAI (embeddings, GPT-4o, Whisper)
    └── storage.bicep        # Storage Account + containers + RBAC

scripts/
├── provision.ps1           # Step 1: Provision all Azure resources
├── build-deploy.ps1        # Step 2: Build container + deploy to Function App
├── test-e2e.ps1            # Step 3: End-to-end integration test
└── teardown.ps1            # Step 4: Delete everything (optional)

notebooks/
├── use_case_onboarding.ipynb   # Interactive onboarding walkthrough
└── benchmark_ingestion.ipynb   # Benchmark processing time + token counts
```

## Quick Start (4 Commands)

```powershell
# 1. Provision Azure resources (~10-15 min)
./scripts/provision.ps1 -ResourceGroupName "rg-ingestion-dev" -NamingPrefix "ingest" -ParametersFile "infra/main.bicepparam"

# 2. Build and deploy the container (~5-10 min)
./scripts/build-deploy.ps1

# 3. Run end-to-end test (~5-15 min depending on document size)
./scripts/test-e2e.ps1

# 4. Tear down when done (optional)
./scripts/teardown.ps1
```

---

## Step-by-Step Walkthrough

### Step 1: Configure Parameters

Before provisioning, review and customize `infra/main.bicepparam`:

```bicep
param location = 'eastus'           // Azure region
param namingPrefix = 'ingest'       // 3-12 char prefix for all resource names
param environment = 'dev'           // dev | staging | prod
param embeddingsDimensions = 3072   // Match your embedding model
param searchSkuName = 'basic'       // basic | standard | standard2
param functionAppSkuName = 'EP1'    // Premium plan SKU (EP1, EP2, EP3)
```

**Key decisions:**
- **Region & Quota**: Check Azure OpenAI model availability in your region. Embeddings (text-embedding-3-large) and GPT-4o need sufficient TPM quota. Use `az cognitiveservices usage list --location <region>` to check.
- **Whisper (separate region)**: If Whisper isn't available in your primary region, set `whisperAccountName` and `whisperLocation` in the param file to create a separate OpenAI account in another region (e.g., `northcentralus`).
- **Cosmos DB location**: If East US has capacity issues for serverless Cosmos DB, set `cosmosLocation` to a different region (e.g., `westus2`).
- **AI Search SKU**: `basic` is sufficient for dev/test. Use `standard` or higher for production workloads.
- **Subscription policies**: If your subscription enforces `disableLocalAuth` on Cognitive Services, the Bicep is already configured for fully managed identity (no API keys).

### Step 2: Provision Resources

```powershell
./scripts/provision.ps1 `
    -ResourceGroupName "rg-ingestion-dev" `
    -NamingPrefix "ingest" `
    -Location "eastus" `
    -ParametersFile "infra/main.bicepparam"
```

CLI parameters (`-NamingPrefix`, `-Location`, `-Environment`) override values in the `.bicepparam` file.

**What this creates:**

| Resource | Purpose |
|---|---|
| Storage Account | Blob containers for source docs, extracts, intermediate processing |
| Cosmos DB (serverless) | Ingestion status tracking + use-case profiles |
| Azure AI Search | Vector index for RAG retrieval |
| Document Intelligence | PDF text/table extraction |
| Azure OpenAI | Embeddings (text-embedding-3-large), Vision (GPT-4o), Transcription (Whisper) |
| Container Registry | Hosts the Function App container image |
| App Service Plan (EP1) | Elastic Premium plan for the Function App |
| Function App | The durable functions ingestion app with system-assigned managed identity |
| Log Analytics + App Insights | Monitoring and diagnostics |

**What this outputs:**
- `scripts/deploy-outputs.json` — resource names, endpoints, and the Function App URL (used by subsequent scripts). This file is gitignored since it may contain sensitive data.

**Managed Identity & RBAC:**

The Function App gets a system-assigned managed identity with these roles automatically assigned:

| Resource | Roles |
|---|---|
| **Storage Account** | Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor, Storage Account Contributor |
| **Cosmos DB** | Built-in Data Contributor (SQL role) |
| **AI Search** | Search Index Data Contributor, Search Service Contributor |
| **Document Intelligence** | Cognitive Services User |
| **Azure OpenAI** | Cognitive Services OpenAI User (on both main and Whisper accounts) |
| **Container Registry** | AcrPull |

The Durable Functions runtime uses identity-based storage via `AzureWebJobsStorage__*` settings with `__credential=managedidentity`. All `*_KEY` app settings are set to empty strings, causing the application code to use `DefaultAzureCredential` throughout.

### Step 3: Build & Deploy Container

```powershell
./scripts/build-deploy.ps1
```

Or with a specific version tag:
```powershell
./scripts/build-deploy.ps1 -Tag "v1.0.0"
```

**What this does:**
1. Builds the Docker image from the repo root `Dockerfile` (includes LibreOffice for non-PDF conversion)
2. Logs into ACR and pushes the image
3. Updates the Function App to use the new container image
4. Retrieves and saves the Function App host key to `deploy-outputs.json`

**Note:** The Function App may take 2-3 minutes to fully start after the container update. If the function key retrieval fails, the script will warn you — just re-run `build-deploy.ps1` or retrieve it manually from the Azure Portal (Function App > App keys).

### Step 4: Run E2E Test

```powershell
./scripts/test-e2e.ps1
```

> **Prerequisite:** Your user account needs **Storage Blob Data Contributor** on the storage account to upload test files. Assign via:
> ```powershell
> New-AzRoleAssignment -SignInName (Get-AzContext).Account.Id `
>     -RoleDefinitionName "Storage Blob Data Contributor" `
>     -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-name>"
> ```

**What this does:**
1. Creates a test AI Search index (`e2e-test-index-{timestamp}`)
2. Uploads the sample PDF (`sample_data/ManitouCruise22_OG-0.pdf`) to blob storage via `Az.Storage` cmdlets
3. Triggers the `pdf_orchestrator` with fake identity values:
   - `entra_id`: `test-entra-id-{random}`
   - `session_id`: `test-session-{random}`
4. Polls the orchestrator status every 15 seconds (timeout: 15 min)
5. Verifies documents were indexed in AI Search
6. Cleans up test blobs

**Options:**
```powershell
# Increase timeout for large documents
./scripts/test-e2e.ps1 -TimeoutMinutes 30

# Skip cleanup to inspect test data
./scripts/test-e2e.ps1 -SkipCleanup
```

### Step 5: Tear Down (Optional)

```powershell
./scripts/teardown.ps1
```

Or skip the confirmation prompt:
```powershell
./scripts/teardown.ps1 -Force
```

This deletes the entire resource group and all contained resources. The deletion runs asynchronously.

---

## Authentication Model

All services use **managed identity** (no API keys):

| Service | How it works |
|---|---|
| **Azure Storage** (app code) | `_get_blob_service_client()` in `function_app.py` — uses `DefaultAzureCredential` when `STORAGE_CONN_STR` is empty |
| **Azure Storage** (Durable Functions runtime) | `AzureWebJobsStorage__credential=managedidentity` + explicit `__blobServiceUri`, `__queueServiceUri`, `__tableServiceUri` |
| **Cosmos DB** | `_get_cosmos_client()` — uses `DefaultAzureCredential` when `COSMOS_KEY` is empty |
| **AI Search** | `_get_search_credential()` in `ai_search_utilities.py` — uses `DefaultAzureCredential` when `SEARCH_KEY` is empty |
| **Azure OpenAI** | `_get_aoai_client()` / `_get_aoai_headers()` in `aoai_utilities.py` — uses `azure_ad_token_provider` or Bearer token when `AOAI_KEY` is empty |
| **Document Intelligence** | `analyze_pdf()` in `doc_intelligence_utilities.py` — uses `DefaultAzureCredential` when `DOC_INTEL_KEY` is empty |

For **local development**, populate the `*_KEY` env vars in `local.settings.json` to use API keys instead.

> **Important:** The extension bundle in `host.json` must be `[4.*, 5.0.0)` for Durable Functions managed identity support (bundle 3.x uses the legacy Azure Storage SDK which doesn't support identity-based Table access).

---

## Using the Notebooks

### Onboarding Notebook (`notebooks/use_case_onboarding.ipynb`)

Interactive walkthrough covering:
1. Index creation, file listing, ingestion triggering
2. **File upload** — single file or batch upload to blob storage
3. **End-to-end flow** — upload → ingest → verify with test identity values

### Benchmark Notebook (`notebooks/benchmark_ingestion.ipynb`)

Processes each sample PDF individually and measures:
- **Processing time** per document (wall clock)
- **OCR token count** using `tiktoken` (`cl100k_base`)
- Derived metrics: tokens/page, time/page, tokens/second
- Produces bar chart visualizations saved as PNG

**Setup for both notebooks:**
1. Create `notebooks/.env`:
   ```
   FUNCTION_URI=https://your-func-app.azurewebsites.net
   FUNCTION_KEY=your-function-host-key
   STORAGE_ACCOUNT_NAME=your-storage-account-name
   ```
2. Install dependencies: `pip install python-dotenv requests pandas pypdf tiktoken azure-storage-blob azure-identity matplotlib`
3. Ensure you're authenticated: `az login` or `Connect-AzAccount`

---

## Troubleshooting

| Issue | Solution |
|---|---|
| **Bicep: `InsufficientQuota`** | Check model quota with `az cognitiveservices usage list --location <region>`. Try a different region or reduce TPM capacity in `openai.bicep`. |
| **Bicep: `disableLocalAuth` / `Failed to list key`** | Your subscription enforces managed identity. The Bicep is already configured for this — ensure no `listKeys()` calls remain in outputs. |
| **Cosmos DB: `ServiceUnavailable` in East US** | Set `cosmosLocation` in `main.bicepparam` to a different region (e.g., `westus2`). |
| **Cosmos DB: `failed provisioning state`** | Delete the failed account (`az cosmosdb delete --name <name> --resource-group <rg> --yes`) then re-run provision. |
| **Orchestrator returns 500** | Check that `AzureWebJobsStorage__credential=managedidentity` is set, extension bundle is `[4.*, 5.0.0)`, and Storage Blob/Queue/Table roles are assigned. |
| **`Function host is not running`** | The Durable Functions runtime can't connect to storage. Verify all 4 storage RBAC roles are assigned and the `__*ServiceUri` app settings are present. |
| **Token expiry with multi-tenant accounts** | Use `az login --tenant <tenant-id>` instead of plain `az login`. For PowerShell cmdlets, use `Connect-AzAccount -Tenant <tenant-id>`. |
| **Blob upload 403 in test script** | Your user needs Storage Blob Data Contributor on the storage account. Assign via `New-AzRoleAssignment`. |
| **Function App returns 404 after deploy** | Wait 2-3 min for container startup; check App Insights or `az webapp log download` for errors. |
| **Docker build fails** | Ensure Docker Desktop is running; check that `requirements.txt` packages are resolvable. |
| **`deploy-outputs.json` not found** | Run `provision.ps1` first. |
