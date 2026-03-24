@description('Array of Function App configurations')
param functionApps array

@description('The location for all resources')
param location string = resourceGroup().location

@description('Virtual Network Subnet ID for VNet integration')
param virtualNetworkSubnetId string = '/subscriptions/9048e167-320c-4204-8671-f4bf4557b1d5/resourceGroups/DEVUAT-ASE-RG/providers/Microsoft.Network/virtualNetworks/DEVUAT-APP-VNET/subnets/DEVUAT-ASE-OUTBOUND-SUBNET'

@description('Application Insights workspace resource ID')
param logAnalyticsWorkspaceResourceId string

@description('Private endpoint subnet ID')
param privateEndpointSubnetId string

@description('Private DNS zone resource ID for the private endpoint')
param privateDnsZoneResourceId string

@description('Tags to apply to resources')
param commonTags object = {}

@description('The thumbprint of the wildcard certificate')
param certificateThumbprint string


module functionApp 'function-app-module.bicep' = [for functionApp in functionApps: {
  name: 'function-app-migration-${functionApp.name}'
  params: {
    appServiceName: functionApp.name
    appServicePlanId: functionApp.appServicePlanId
    location: location
    virtualNetworkSubnetId: virtualNetworkSubnetId
    appInsightsResourceId: functionApp.appInsightsResourceId ?? ''
    appInsightsName: '${functionApp.name}'
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    httpsOnly: true
    clientAffinityEnabled: false
    alwaysOn: false
    minimumElasticInstanceCount: 2
    functionAppScaleLimit: 5
    vnetRouteAllEnabled: true
    publicNetworkAccess: 'Disabled'
    tags: commonTags
    keyVaultReferenceIdentity: 'SystemAssigned'
    http20Enabled: false
    enablePrivateEndpoint: true
		privateEndpointSubnetId: !empty(privateEndpointSubnetId) ? privateEndpointSubnetId :null
    privateEndpointName: '${functionApp.name}-pe'
    privateDnsZoneResourceId: privateDnsZoneResourceId
    customDomains: functionApp.?customDomains ?? []
    deploymentSlots: functionApp.?deploymentSlots ?? []
  }
}]

module domainVerification 'domain-verification.bicep' = [for (app, i) in functionApps: if (length(app.?customDomains ?? []) > 0) {
  name: 'domain-verification-${app.name}'
	dependsOn: [
		functionApp[i]
	]
  params: {
    appName: app.name
    certificateThumbprint: certificateThumbprint
    customDomains: app.customDomains
  }
}]

output functionAppOutputs array = [for i in range(0, length(functionApps)): {
  appServiceId: functionApp[i].outputs.appServiceId
  appServiceName: functionApp[i].outputs.appServiceName
  defaultHostName: functionApp[i].outputs.defaultHostName
  possibleOutboundIpAddresses: functionApp[i].outputs.possibleOutboundIpAddresses
  principalId: functionApp[i].outputs.principalId
  tenantId: functionApp[i].outputs.tenantId
  enabledHostNames: functionApp[i].outputs.enabledHostNames
  privateEndpointId: functionApp[i].outputs.privateEndpointId
  privateEndpointName: functionApp[i].outputs.privateEndpointName
  applicationInsightsId: functionApp[i].outputs.applicationInsightsId
  applicationInsightsName: functionApp[i].outputs.applicationInsightsName
}]
