@description('Azure region for Azure OpenAI')
param location string

@description('Azure OpenAI account name')
param openAIAccountName string

@description('SKU for Azure OpenAI')
param skuName string = 'S0'

@description('Name of the embeddings model deployment')
param embeddingsDeploymentName string = 'text-embedding-3-large'

@description('Embeddings model name')
param embeddingsModelName string = 'text-embedding-3-large'

@description('Embeddings model version')
param embeddingsModelVersion string = '1'

@description('Embeddings dimensions')
param embeddingsDimensions int = 3072

@description('Name of the GPT-4o model deployment')
param gptVisionDeploymentName string = 'gpt-4o'

@description('GPT-4o model name')
param gptVisionModelName string = 'gpt-4o'

@description('GPT-4o model version')
param gptVisionModelVersion string = '2024-11-20'

@description('Name of the Whisper model deployment')
param whisperDeploymentName string = 'whisper'

@description('Whisper model name')
param whisperModelName string = 'whisper'

@description('Whisper model version')
param whisperModelVersion string = '001'

@description('TPM capacity for embeddings deployment')
param embeddingsCapacity int = 120

@description('TPM capacity for GPT-4o deployment')
param gptVisionCapacity int = 40

@description('TPM capacity for Whisper deployment')
param whisperCapacity int = 3

@description('Principal ID of the Function App managed identity for RBAC')
param functionAppPrincipalId string = ''

@description('Optional: separate OpenAI account for Whisper (if in a different region). Leave empty to use the main account.')
param whisperAccountName string = ''

@description('Optional: location for the Whisper account if separate')
param whisperLocation string = ''

// Main OpenAI account (embeddings + GPT-4o)
resource openAIAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAIAccountName
  location: location
  kind: 'OpenAI'
  sku: {
    name: skuName
  }
  properties: {
    customSubDomainName: openAIAccountName
    publicNetworkAccess: 'Enabled'
  }
}

resource embeddingsDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAIAccount
  name: embeddingsDeploymentName
  sku: {
    name: 'Standard'
    capacity: embeddingsCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingsModelName
      version: embeddingsModelVersion
    }
  }
}

resource gptVisionDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAIAccount
  name: gptVisionDeploymentName
  sku: {
    name: 'Standard'
    capacity: gptVisionCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: gptVisionModelName
      version: gptVisionModelVersion
    }
  }
  dependsOn: [embeddingsDeployment]
}

// Optional separate Whisper account (Whisper availability varies by region)
resource whisperAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = if (!empty(whisperAccountName)) {
  name: !empty(whisperAccountName) ? whisperAccountName : '${openAIAccountName}-whisper'
  location: !empty(whisperLocation) ? whisperLocation : location
  kind: 'OpenAI'
  sku: {
    name: skuName
  }
  properties: {
    customSubDomainName: !empty(whisperAccountName) ? whisperAccountName : '${openAIAccountName}-whisper'
    publicNetworkAccess: 'Enabled'
  }
}

resource whisperDeploymentMain 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (empty(whisperAccountName)) {
  parent: openAIAccount
  name: whisperDeploymentName
  sku: {
    name: 'Standard'
    capacity: whisperCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: whisperModelName
      version: whisperModelVersion
    }
  }
  dependsOn: [gptVisionDeployment]
}

resource whisperDeploymentSeparate 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (!empty(whisperAccountName)) {
  parent: whisperAccount
  name: whisperDeploymentName
  sku: {
    name: 'Standard'
    capacity: whisperCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: whisperModelName
      version: whisperModelVersion
    }
  }
}

// Cognitive Services OpenAI User role on main account
resource openAIRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: openAIAccount
  name: guid(openAIAccount.id, functionAppPrincipalId, '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Cognitive Services OpenAI User role on Whisper account (if separate)
resource whisperRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId) && !empty(whisperAccountName)) {
  scope: whisperAccount
  name: guid(whisperAccount.id, functionAppPrincipalId, '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output openAIAccountId string = openAIAccount.id
output openAIEndpoint string = openAIAccount.properties.endpoint
output openAIAccountName string = openAIAccount.name
output embeddingsDeploymentName string = embeddingsDeploymentName
output embeddingsDimensions int = embeddingsDimensions
output gptVisionDeploymentName string = gptVisionDeploymentName
output whisperDeploymentName string = whisperDeploymentName
output whisperEndpoint string = !empty(whisperAccountName) ? 'https://${whisperAccountName}.openai.azure.com/' : openAIAccount.properties.endpoint
output whisperModelType string = whisperModelName
