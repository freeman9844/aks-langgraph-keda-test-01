param location string = resourceGroup().location
var suffix = uniqueString(resourceGroup().id)
resource ws 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: 'metrics-${suffix}'
  location: location
  properties: {}
}
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'runs${suffix}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}
resource aks 'Microsoft.ContainerService/managedClusters@2024-10-01' = {
  name: 'runs-${suffix}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: 'runs-${suffix}'
    nodeResourceGroup: 'mc-runs-${suffix}'
    enableRBAC: true
    agentPoolProfiles: [{
      name: 'system'
      count: 2
      mode: 'System'
      vmSize: 'Standard_D4s_v5'
      osType: 'Linux'
      type: 'VirtualMachineScaleSets'
      enableAutoScaling: false
    }]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    workloadAutoScalerProfile: { keda: { enabled: true } }
    azureMonitorProfile: { metrics: { enabled: true } }
  }
}
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'runs-${suffix}'
  location: location
  properties: {}
}
resource rule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'runs-${suffix}'
  location: location
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      prometheusForwarder: [{ name: 'prom', streams: ['Microsoft-PrometheusMetrics'] }]
    }
    destinations: { monitoringAccounts: [{ name: 'workspace', accountResourceId: ws.id }] }
    dataFlows: [{ streams: ['Microsoft-PrometheusMetrics'], destinations: ['workspace'] }]
  }
}
resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'runs-collection'
  scope: aks
  properties: { dataCollectionRuleId: rule.id }
}
resource endpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'configurationAccessEndpoint'
  scope: aks
  properties: { dataCollectionEndpointId: dce.id }
}
resource reader 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'runs-reader'
  location: location
}
resource federated 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: reader
  name: 'keda'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:kube-system:keda-operator'
    audiences: ['api://AzureADTokenExchange']
  }
}
resource queryRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ws.id, reader.id, 'read')
  scope: ws
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b0d8363b-8ddd-447d-831f-62ca05bff136')
    principalId: reader.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource pullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, 'pull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}
output cluster string = aks.name
output registry string = acr.name
output endpoint string = ws.properties.metrics.prometheusQueryEndpoint
output clientId string = reader.properties.clientId
