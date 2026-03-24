@description('The name of the App Service')
param appServiceName string

@description('The resource ID of the existing App Service Plan')
param appServicePlanId string

@description('The location for all resources')
param location string = resourceGroup().location

@description('The Linux FX Version (e.g., NODE|22-lts)')
param linuxFxVersion string = 'NODE|22-lts'

@description('Custom domain names')
param customDomains array = []

@description('Virtual Network Subnet ID for VNet integration')
param virtualNetworkSubnetId string = ''

@description('Application Insights resource ID - if empty, a new one will be created')
param appInsightsResourceId string = ''

@description('Application Insights name - used when creating new instance')
param appInsightsName string = '${appServiceName}'

@description('Application Insights workspace resource ID')
param logAnalyticsWorkspaceResourceId string = ''

@description('Enable HTTPS only')
param httpsOnly bool = true

@description('Client affinity enabled')
param clientAffinityEnabled bool = false

@description('Always On setting')
param alwaysOn bool = true

@description('Minimum elastic instance count')
param minimumElasticInstanceCount int = 2

@description('Function app scale limit')
param functionAppScaleLimit int = 5


@description('Public network access')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Tags to apply to resources')
param tags object = {}

@description('Key Vault reference identity')
@allowed([
  'SystemAssigned'
  'UserAssigned'
])
param keyVaultReferenceIdentity string = 'SystemAssigned'

@description('Enable HTTP 2.0')
param http20Enabled bool = true

@description('Enable private endpoint for the App Service')
param enablePrivateEndpoint bool = true

@description('Private endpoint subnet ID')
param privateEndpointSubnetId string = ''

@description('Private endpoint name')
param privateEndpointName string = '${appServiceName}-pe'

@description('Private DNS zone resource ID for the private endpoint')
param privateDnsZoneResourceId string = ''

@description('Certificate thumbprint for SSL binding')
param certificateThumbprint string = ''

@description('Deployment slots configuration')
param deploymentSlots array = []
// Example format:
// [
//   {
//     name: 'staging'
//   }
// ]

// Application Insights resource
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = if (empty(appInsightsResourceId)) {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
    WorkspaceResourceId: !empty(logAnalyticsWorkspaceResourceId) ? logAnalyticsWorkspaceResourceId : null
  }
}

// Get the Application Insights resource ID (either existing or newly created)
var actualAppInsightsResourceId = !empty(appInsightsResourceId) ? appInsightsResourceId : (empty(appInsightsResourceId) ? applicationInsights.id : '')

// App Service
resource appService 'Microsoft.Web/sites@2024-11-01' = {
  name: appServiceName
  location: location
  tags: union(tags, {
    'hidden-link: /app-insights-resource-id': actualAppInsightsResourceId
  })
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlanId
    reserved: true
    httpsOnly: httpsOnly
    clientAffinityEnabled: clientAffinityEnabled
    virtualNetworkSubnetId: !empty(virtualNetworkSubnetId) ? virtualNetworkSubnetId : null
    publicNetworkAccess: publicNetworkAccess
    keyVaultReferenceIdentity: keyVaultReferenceIdentity
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: linuxFxVersion
      alwaysOn: alwaysOn
      http20Enabled: http20Enabled
      minimumElasticInstanceCount: minimumElasticInstanceCount
      functionAppScaleLimit: functionAppScaleLimit
      acrUseManagedIdentityCreds: false
      appSettings: empty(appInsightsResourceId) ? [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: applicationInsights.properties.InstrumentationKey
        }
      ] : []
    }
  }
}

// Deployment slots
resource slots 'Microsoft.Web/sites/slots@2024-11-01' = [for slot in deploymentSlots: {
  parent: appService
  name: slot.name
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlanId
    reserved: true
    httpsOnly: httpsOnly
    clientAffinityEnabled: clientAffinityEnabled
    virtualNetworkSubnetId: !empty(virtualNetworkSubnetId) ? virtualNetworkSubnetId : null
    publicNetworkAccess: publicNetworkAccess
    keyVaultReferenceIdentity: keyVaultReferenceIdentity
    siteConfig: {
      numberOfWorkers: 1
      linuxFxVersion: linuxFxVersion
      alwaysOn: alwaysOn
      http20Enabled: http20Enabled
      minimumElasticInstanceCount: minimumElasticInstanceCount
      functionAppScaleLimit: functionAppScaleLimit
      acrUseManagedIdentityCreds: false
      appSettings: empty(appInsightsResourceId) ? [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: applicationInsights.properties.InstrumentationKey
        }
      ] : []
    }
  }
}]

// Private endpoint for App Service
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2022-05-01' = if (enablePrivateEndpoint) {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: {
          privateLinkServiceId: appService.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

// Private endpoint DNS zone group
resource privateEndpointDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-05-01' = if (enablePrivateEndpoint) {
  name: 'default'
  parent: privateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurewebsites-net'
        properties: {
          privateDnsZoneId: privateDnsZoneResourceId
        }
      }
    ]
  }
}

// Private endpoints for deployment slots
resource slotPrivateEndpoints 'Microsoft.Network/privateEndpoints@2022-05-01' = [for (slot, i) in deploymentSlots: if (enablePrivateEndpoint) {
  name: '${appServiceName}-${slot.name}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${appServiceName}-${slot.name}-pe-connection'
        properties: {
          privateLinkServiceId: appService.id
          groupIds: [
            'sites-temp'
          ]
        }
      }
    ]
  }
}]

// Private endpoint DNS zone groups for deployment slots
resource slotPrivateEndpointDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-05-01' = [for (slot, i) in deploymentSlots: if (enablePrivateEndpoint) {
  name: 'default'
  parent: slotPrivateEndpoints[i]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurewebsites-net'
        properties: {
          privateDnsZoneId: privateDnsZoneResourceId
        }
      }
    ]
  }
}]

// Output values
output appServiceId string = appService.id
output appServiceName string = appService.name
output defaultHostName string = appService.properties.defaultHostName
output possibleOutboundIpAddresses string = appService.properties.possibleOutboundIpAddresses
output principalId string = appService.identity.principalId
output tenantId string = appService.identity.tenantId

// Output for custom domains
output hostNames array = [for domain in customDomains: domain]
output enabledHostNames array = appService.properties.enabledHostNames

// Output for private endpoint
output privateEndpointId string = enablePrivateEndpoint ? privateEndpoint.id : ''
output privateEndpointName string = enablePrivateEndpoint ? privateEndpoint.name : ''

// Output for Application Insights
output applicationInsightsId string = empty(appInsightsResourceId) ? applicationInsights.id : appInsightsResourceId
output applicationInsightsName string = empty(appInsightsResourceId) ? applicationInsights.name : ''

// Output for deployment slots
output deploymentSlots array = [for (slot, i) in deploymentSlots: {
  name: slots[i].name
  id: slots[i].id
  defaultHostName: slots[i].properties.defaultHostName
  principalId: slots[i].identity.principalId
  privateEndpointId: enablePrivateEndpoint ? slotPrivateEndpoints[i].id : ''
  privateEndpointName: enablePrivateEndpoint ? slotPrivateEndpoints[i].name : ''
}]
