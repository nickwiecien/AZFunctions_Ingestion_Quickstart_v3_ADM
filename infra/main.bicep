targetScope = 'resourceGroup'

// Naming & location
@description('Azure region for all resources')
param location string

@description('Naming prefix for all resources (lowercase, no special chars)')
@minLength(3)
@maxLength(12)
param namingPrefix string

@description('Environment identifier (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

// AI Search
@description('AI Search SKU')
param searchSkuName string = 'basic'

// Azure OpenAI model config
@description('Embeddings model deployment name')
param embeddingsDeploymentName string = 'text-embedding-3-large'

@description('Embeddings model name')
param embeddingsModelName string = 'text-embedding-3-large'

@description('Embeddings dimensions')
param embeddingsDimensions int = 3072

@description('GPT vision model deployment name')
param gptVisionDeploymentName string = 'gpt-4o'

@description('GPT vision model name')
param gptVisionModelName string = 'gpt-4o'

@description('Whisper model deployment name')
param whisperDeploymentName string = 'whisper'

@description('Optional: separate Azure OpenAI account name for Whisper (if Whisper not available in primary region)')
param whisperAccountName string = ''

@description('Optional: location for separate Whisper account')
param whisperLocation string = ''

// Container Apps
@description('Function App Premium plan SKU (EP1, EP2, EP3)')
param functionAppSkuName string = 'EP1'

@description('Maximum elastic worker count')
param maximumElasticWorkerCount int = 10

// Cosmos DB
@description('Cosmos DB database name')
param cosmosDatabaseName string = 'ingestion-db'

@description('Cosmos DB location override (if primary region has capacity issues)')
param cosmosLocation string = ''

@description('Cosmos DB status container name')
param cosmosStatusContainerName string = 'ingestion-status'

@description('Cosmos DB profile container name')
param cosmosProfileContainerName string = 'use-case-profiles'

// Derived names
var uniqueSuffix = uniqueString(resourceGroup().id, namingPrefix)
var storageAccountName = toLower('${namingPrefix}st${take(uniqueSuffix, 8)}')
var cosmosAccountName = '${namingPrefix}-cosmos-${environment}-wus2'
var searchServiceName = '${namingPrefix}-search-${environment}'
var docIntelligenceName = '${namingPrefix}-docintel-${environment}'
var openAIAccountName = '${namingPrefix}-aoai-${environment}'
var acrName = toLower('${namingPrefix}acr${take(uniqueSuffix, 6)}')
var functionAppName = '${namingPrefix}-func-${environment}'
var logAnalyticsName = '${namingPrefix}-logs-${environment}'
var appInsightsName = '${namingPrefix}-appi-${environment}'

// Monitoring (deployed first, no identity dependency)
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
  }
}

// Storage Account
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
  }
}

// Cosmos DB
module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos'
  params: {
    location: !empty(cosmosLocation) ? cosmosLocation : location
    cosmosAccountName: cosmosAccountName
    databaseName: cosmosDatabaseName
    statusContainerName: cosmosStatusContainerName
    profileContainerName: cosmosProfileContainerName
  }
}

// AI Search
module aiSearch 'modules/ai-search.bicep' = {
  name: 'ai-search'
  params: {
    location: location
    searchServiceName: searchServiceName
    skuName: searchSkuName
  }
}

// Document Intelligence
module docIntelligence 'modules/doc-intelligence.bicep' = {
  name: 'doc-intelligence'
  params: {
    location: location
    docIntelligenceName: docIntelligenceName
  }
}

// Azure OpenAI
module openAI 'modules/openai.bicep' = {
  name: 'openai'
  params: {
    location: location
    openAIAccountName: openAIAccountName
    embeddingsDeploymentName: embeddingsDeploymentName
    embeddingsModelName: embeddingsModelName
    embeddingsDimensions: embeddingsDimensions
    gptVisionDeploymentName: gptVisionDeploymentName
    gptVisionModelName: gptVisionModelName
    whisperDeploymentName: whisperDeploymentName
    whisperAccountName: whisperAccountName
    whisperLocation: whisperLocation
  }
}

// ACR
module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    location: location
    acrName: acrName
  }
}

// Function App on Premium plan
module functionApp 'modules/function-app.bicep' = {
  name: 'function-app'
  params: {
    location: location
    functionAppName: functionAppName
    storageAccountName: storage.outputs.storageAccountName
    acrLoginServer: acr.outputs.acrLoginServer
    acrAdminUsername: acr.outputs.acrAdminUsername
    acrAdminPassword: acr.outputs.acrAdminPassword
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    planSkuName: functionAppSkuName
    maximumElasticWorkerCount: maximumElasticWorkerCount
    docIntelEndpoint: docIntelligence.outputs.docIntelligenceEndpoint
    aoaiEndpoint: openAI.outputs.openAIEndpoint
    aoaiEmbeddingsModel: openAI.outputs.embeddingsDeploymentName
    aoaiEmbeddingsDimensions: openAI.outputs.embeddingsDimensions
    aoaiGptVisionModel: openAI.outputs.gptVisionDeploymentName
    aoaiWhisperEndpoint: openAI.outputs.whisperEndpoint
    aoaiWhisperModel: openAI.outputs.whisperDeploymentName
    aoaiWhisperModelType: openAI.outputs.whisperModelType
    searchEndpoint: aiSearch.outputs.searchEndpoint
    searchServiceName: aiSearch.outputs.searchServiceName
    cosmosEndpoint: cosmos.outputs.cosmosEndpoint
    cosmosDatabase: cosmos.outputs.databaseName
    cosmosContainer: cosmos.outputs.statusContainerName
    cosmosProfileDatabase: cosmos.outputs.databaseName
    cosmosProfileContainer: cosmos.outputs.profileContainerName
  }
}

// Second pass: assign RBAC roles now that the Function App identity exists
module storageRbac 'modules/storage.bicep' = {
  name: 'storage-rbac'
  params: {
    location: location
    storageAccountName: storageAccountName
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
  }
}

module cosmosRbac 'modules/cosmos.bicep' = {
  name: 'cosmos-rbac'
  params: {
    location: !empty(cosmosLocation) ? cosmosLocation : location
    cosmosAccountName: cosmosAccountName
    databaseName: cosmosDatabaseName
    statusContainerName: cosmosStatusContainerName
    profileContainerName: cosmosProfileContainerName
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
  }
}

module aiSearchRbac 'modules/ai-search.bicep' = {
  name: 'ai-search-rbac'
  params: {
    location: location
    searchServiceName: searchServiceName
    skuName: searchSkuName
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
  }
}

module docIntelligenceRbac 'modules/doc-intelligence.bicep' = {
  name: 'doc-intelligence-rbac'
  params: {
    location: location
    docIntelligenceName: docIntelligenceName
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
  }
}

module openAIRbac 'modules/openai.bicep' = {
  name: 'openai-rbac'
  params: {
    location: location
    openAIAccountName: openAIAccountName
    embeddingsDeploymentName: embeddingsDeploymentName
    embeddingsModelName: embeddingsModelName
    embeddingsDimensions: embeddingsDimensions
    gptVisionDeploymentName: gptVisionDeploymentName
    gptVisionModelName: gptVisionModelName
    whisperDeploymentName: whisperDeploymentName
    whisperAccountName: whisperAccountName
    whisperLocation: whisperLocation
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
  }
}

module acrRbac 'modules/acr.bicep' = {
  name: 'acr-rbac'
  params: {
    location: location
    acrName: acrName
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
  }
}

// Outputs for scripts
output resourceGroupName string = resourceGroup().name
output storageAccountName string = storage.outputs.storageAccountName
output storageBlobEndpoint string = storage.outputs.blobEndpoint
output cosmosEndpoint string = cosmos.outputs.cosmosEndpoint
output cosmosDatabase string = cosmos.outputs.databaseName
output searchEndpoint string = aiSearch.outputs.searchEndpoint
output searchServiceName string = aiSearch.outputs.searchServiceName
output docIntelEndpoint string = docIntelligence.outputs.docIntelligenceEndpoint
output openAIEndpoint string = openAI.outputs.openAIEndpoint
output acrLoginServer string = acr.outputs.acrLoginServer
output acrName string = acr.outputs.acrName
output functionAppName string = functionApp.outputs.functionAppName
output functionAppUrl string = functionApp.outputs.functionAppUrl
output functionAppPrincipalId string = functionApp.outputs.functionAppPrincipalId
