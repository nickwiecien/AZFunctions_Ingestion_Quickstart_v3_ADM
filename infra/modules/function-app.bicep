@description('Azure region')
param location string

@description('Function App name')
param functionAppName string

@description('Storage account name (for managed identity AzureWebJobsStorage)')
param storageAccountName string

@description('ACR login server')
param acrLoginServer string

@description('ACR admin username')
param acrAdminUsername string

@secure()
@description('ACR admin password')
param acrAdminPassword string

@description('Container image name (without registry prefix)')
param containerImageName string = 'ingestionfunctions:latest'

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('Premium plan SKU (EP1, EP2, EP3)')
param planSkuName string = 'EP1'

@description('Premium plan tier')
param planSkuTier string = 'ElasticPremium'

@description('Maximum elastic worker count')
param maximumElasticWorkerCount int = 10

@description('Document Intelligence endpoint')
param docIntelEndpoint string

@description('Azure OpenAI endpoint')
param aoaiEndpoint string

@description('Azure OpenAI embeddings model deployment name')
param aoaiEmbeddingsModel string

@description('Azure OpenAI embeddings dimensions')
param aoaiEmbeddingsDimensions int

@description('Azure OpenAI GPT vision model deployment name')
param aoaiGptVisionModel string

@description('Azure OpenAI Whisper endpoint')
param aoaiWhisperEndpoint string

@description('Azure OpenAI Whisper model deployment name')
param aoaiWhisperModel string

@description('Azure OpenAI Whisper model type')
param aoaiWhisperModelType string

@description('AI Search endpoint')
param searchEndpoint string

@description('AI Search service name')
param searchServiceName string

@description('Cosmos DB endpoint')
param cosmosEndpoint string

@description('Cosmos DB database name')
param cosmosDatabase string

@description('Cosmos DB status container name')
param cosmosContainer string

@description('Cosmos DB profile database name')
param cosmosProfileDatabase string

@description('Cosmos DB profile container name')
param cosmosProfileContainer string

@description('Azure subscription ID (for Data Factory triggers)')
param subscriptionId string = ''

@description('Resource group name (for Data Factory triggers)')
param resourceGroupName string = ''

@description('Data Factory name (for Data Factory triggers)')
param dataFactoryName string = ''

@description('Data Factory upload trigger name')
param referenceUploadTriggerName string = ''

@description('Data Factory delete trigger name')
param referenceDeleteTriggerName string = ''

// App Service Plan (Elastic Premium)
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${functionAppName}-plan'
  location: location
  kind: 'elastic'
  sku: {
    name: planSkuName
    tier: planSkuTier
  }
  properties: {
    maximumElasticWorkerCount: maximumElasticWorkerCount
    reserved: true // Linux
  }
}

// Function App
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    reserved: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${acrLoginServer}/${containerImageName}'
      acrUseManagedIdentityCreds: false
      appSettings: [
        // Durable Functions storage — managed identity requires explicit service URIs
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageAccountName}.blob.core.windows.net' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageAccountName}.queue.core.windows.net' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageAccountName}.table.core.windows.net' }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
        { name: 'DOCKER_REGISTRY_SERVER_URL', value: 'https://${acrLoginServer}' }
        { name: 'DOCKER_REGISTRY_SERVER_USERNAME', value: acrAdminUsername }
        { name: 'DOCKER_REGISTRY_SERVER_PASSWORD', value: acrAdminPassword }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        // Keys are empty — code uses DefaultAzureCredential (managed identity)
        { name: 'STORAGE_CONN_STR', value: '' }
        { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName }
        { name: 'DOC_INTEL_ENDPOINT', value: docIntelEndpoint }
        { name: 'DOC_INTEL_KEY', value: '' }
        { name: 'AOAI_KEY', value: '' }
        { name: 'AOAI_ENDPOINT', value: aoaiEndpoint }
        { name: 'AOAI_EMBEDDINGS_MODEL', value: aoaiEmbeddingsModel }
        { name: 'AOAI_EMBEDDINGS_DIMENSIONS', value: string(aoaiEmbeddingsDimensions) }
        { name: 'AOAI_GPT_VISION_MODEL', value: aoaiGptVisionModel }
        { name: 'AOAI_WHISPER_ENDPOINT', value: aoaiWhisperEndpoint }
        { name: 'AOAI_WHISPER_KEY', value: '' }
        { name: 'AOAI_WHISPER_MODEL', value: aoaiWhisperModel }
        { name: 'AOAI_WHISPER_MODEL_TYPE', value: aoaiWhisperModelType }
        { name: 'SEARCH_ENDPOINT', value: searchEndpoint }
        { name: 'SEARCH_KEY', value: '' }
        { name: 'SEARCH_SERVICE_NAME', value: searchServiceName }
        { name: 'COSMOS_ENDPOINT', value: cosmosEndpoint }
        { name: 'COSMOS_KEY', value: '' }
        { name: 'COSMOS_DATABASE', value: cosmosDatabase }
        { name: 'COSMOS_CONTAINER', value: cosmosContainer }
        { name: 'COSMOS_PROFILE_DATABASE', value: cosmosProfileDatabase }
        { name: 'COSMOS_PROFILE_CONTAINER', value: cosmosProfileContainer }
        { name: 'SUBSCRIPTION_ID', value: subscriptionId }
        { name: 'RESOURCE_GROUP_NAME', value: resourceGroupName }
        { name: 'DATA_FACTORY_NAME', value: dataFactoryName }
        { name: 'REFERENCE_UPLOAD_TRIGGER_NAME', value: referenceUploadTriggerName }
        { name: 'REFERENCE_DELETE_TRIGGER_NAME', value: referenceDeleteTriggerName }
      ]
    }
  }
}

output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
