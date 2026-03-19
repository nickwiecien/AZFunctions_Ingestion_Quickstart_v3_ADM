using 'main.bicep'

// Required: Azure region for all resources
param location = 'eastus'

// Required: naming prefix (3-12 chars, lowercase, used in all resource names)
param namingPrefix = 'ingest'

// Environment (dev, staging, prod)
param environment = 'dev'

// AI Search SKU
param searchSkuName = 'basic'

// Azure OpenAI model deployments
param embeddingsDeploymentName = 'text-embedding-3-large'
param embeddingsModelName = 'text-embedding-3-large'
param embeddingsDimensions = 3072
param gptVisionDeploymentName = 'gpt-4o'
param gptVisionModelName = 'gpt-4o'
param whisperDeploymentName = 'whisper'

// If Whisper is not available in primary region, use a separate account:
param whisperAccountName = 'ingest-aoai-whisper-dev'
param whisperLocation = 'northcentralus'

// Function App Premium plan
param functionAppSkuName = 'EP1'
param maximumElasticWorkerCount = 10

// Cosmos DB
param cosmosDatabaseName = 'ingestion-db'
param cosmosLocation = 'westus2'
param cosmosStatusContainerName = 'ingestion-status'
param cosmosProfileContainerName = 'use-case-profiles'
