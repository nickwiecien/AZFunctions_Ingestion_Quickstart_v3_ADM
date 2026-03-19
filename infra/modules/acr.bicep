@description('Azure region for the Container Registry')
param location string

@description('ACR name (must be globally unique, alphanumeric only)')
param acrName string

@description('SKU for ACR')
param skuName string = 'Basic'

@description('Principal ID of the Function App managed identity for ACR Pull')
param functionAppPrincipalId string = ''

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: skuName
  }
  properties: {
    adminUserEnabled: true
  }
}

// AcrPull role for the Function App managed identity
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(functionAppPrincipalId)) {
  scope: acr
  name: guid(acr.id, functionAppPrincipalId, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output acrId string = acr.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
#disable-next-line outputs-should-not-contain-secrets
output acrAdminUsername string = acr.listCredentials().username
#disable-next-line outputs-should-not-contain-secrets
output acrAdminPassword string = acr.listCredentials().passwords[0].value
