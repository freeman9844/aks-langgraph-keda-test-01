param clusterName string
param location string = resourceGroup().location
var suffix = uniqueString(resourceGroup().id)
resource aks 'Microsoft.ContainerService/managedClusters@2024-10-01' existing = { name: clusterName }
resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: 'stream${suffix}'
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: 'stream${suffix}'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}
resource model 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: 'stream-lab'
  sku: { name: 'GlobalStandard', capacity: 10 }
  properties: { model: { format: 'OpenAI', name: 'gpt-4.1-nano', version: '2025-04-14' } }
}
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'stream-inference'
  location: location
}
resource fed 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'runtime'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:run-lab:stream-runtime'
    audiences: ['api://AzureADTokenExchange']
  }
}
resource role 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, identity.id, 'inference')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
output clientId string = identity.properties.clientId
output endpoint string = 'https://${account.name}.openai.azure.com'
