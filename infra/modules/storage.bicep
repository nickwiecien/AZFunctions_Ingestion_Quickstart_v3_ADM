@description('Azure region for the storage account')
param location string

@description('Unique name for the storage account')
param storageAccountName string

@description('SKU for the storage account')
param skuName string = 'Standard_LRS'

@description('Blob containers to create for ingestion workflows')
param containerNames array = [
  'pdf-content'
  'pdf-extract'
  'pdf-content-pages'
  'pdf-content-doc-intel-results'
  'pdf-content-doc-intel-formatted-results'
  'pdf-content-image-analysis-results'
  'pdf-content-transcripts'
  'doc-content'
  'doc-extract'
  'qna-pairs'
]

@description('Principal ID of the Function App managed identity for RBAC')
param functionAppPrincipalId string = ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: skuName
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for name in containerNames: {
    parent: blobServices
    name: name
    properties: {
      publicAccess: 'None'
    }
  }
]

// Storage Blob Data Owner role (needed for Durable Functions + app blob operations)
resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor role (needed for Durable Functions task hub)
resource storageQueueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor role (needed for Durable Functions checkpoints)
resource storageTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Account Contributor role
resource storageAccountContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: storageAccount
  name: guid(storageAccount.id, functionAppPrincipalId, '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
