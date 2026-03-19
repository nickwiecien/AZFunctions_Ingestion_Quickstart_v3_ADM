@description('Azure region for Cosmos DB')
param location string

@description('Cosmos DB account name')
param cosmosAccountName string

@description('Name of the database for status records')
param databaseName string = 'ingestion-db'

@description('Name of the container for ingestion status tracking')
param statusContainerName string = 'ingestion-status'

@description('Name of the container for use-case profiles')
param profileContainerName string = 'use-case-profiles'

@description('Principal ID of the Function App managed identity for RBAC')
param functionAppPrincipalId string = ''

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource statusContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: statusContainerName
  properties: {
    resource: {
      id: statusContainerName
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
    }
  }
}

resource profileContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: profileContainerName
  properties: {
    resource: {
      id: profileContainerName
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
    }
  }
}

// Cosmos DB Built-in Data Contributor role
resource cosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = if (!empty(functionAppPrincipalId)) {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, functionAppPrincipalId, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: functionAppPrincipalId
    scope: cosmosAccount.id
  }
}

output cosmosAccountId string = cosmosAccount.id
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint
output cosmosAccountName string = cosmosAccount.name
output databaseName string = database.name
output statusContainerName string = statusContainer.name
output profileContainerName string = profileContainer.name
