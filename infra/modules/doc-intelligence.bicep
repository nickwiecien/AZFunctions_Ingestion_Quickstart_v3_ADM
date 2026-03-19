@description('Azure region for Document Intelligence')
param location string

@description('Document Intelligence account name')
param docIntelligenceName string

@description('SKU for Document Intelligence')
param skuName string = 'S0'

@description('Principal ID of the Function App managed identity for RBAC')
param functionAppPrincipalId string = ''

resource docIntelligence 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: docIntelligenceName
  location: location
  kind: 'FormRecognizer'
  sku: {
    name: skuName
  }
  properties: {
    customSubDomainName: docIntelligenceName
    publicNetworkAccess: 'Enabled'
  }
}

// Cognitive Services User role
resource cognitiveServicesUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: docIntelligence
  name: guid(docIntelligence.id, functionAppPrincipalId, 'a97b65f3-24c7-4388-baec-2e87135dc908')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output docIntelligenceId string = docIntelligence.id
output docIntelligenceEndpoint string = docIntelligence.properties.endpoint
output docIntelligenceName string = docIntelligence.name
