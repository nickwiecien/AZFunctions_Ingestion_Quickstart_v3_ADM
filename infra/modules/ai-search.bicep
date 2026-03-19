@description('Azure region for AI Search')
param location string

@description('AI Search service name')
param searchServiceName string

@description('SKU for AI Search (basic, standard, standard2, standard3)')
param skuName string = 'basic'

@description('Principal ID of the Function App managed identity for RBAC')
param functionAppPrincipalId string = ''

resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: skuName
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

// Search Index Data Contributor role
resource searchIndexDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: searchService
  name: guid(searchService.id, functionAppPrincipalId, '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Search Service Contributor role (for index management)
resource searchServiceContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: searchService
  name: guid(searchService.id, functionAppPrincipalId, '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output searchServiceId string = searchService.id
output searchServiceName string = searchService.name
output searchEndpoint string = 'https://${searchService.name}.search.windows.net'
