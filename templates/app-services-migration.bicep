@description('Location for all resources')
param location string = resourceGroup().location

@description('App services configuration array')
param appServices array

@description('Common tags for all resources')
param commonTags object = {}

@description('Private DNS zone resource ID for the private endpoint (if any)')
param privateDnsZoneResourceId string = '/subscriptions/9048e167-320c-4204-8671-f4bf4557b1d5/resourceGroups/DEVUAT-ASE-RG/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net'

@description('Virtual Network Subnet ID for VNet integration')
param virtualNetworkSubnetId string = '/subscriptions/9048e167-320c-4204-8671-f4bf4557b1d5/resourceGroups/DEVUAT-ASE-RG/providers/Microsoft.Network/virtualNetworks/DEVUAT-APP-VNET/subnets/DEVUAT-ASE-OUTBOUND-SUBNET'

@description('Application Insights workspace resource ID')
param logAnalyticsWorkspaceResourceId string = ''

@description('Private endpoint subnet ID')
param privateEndpointSubnetId string = '/subscriptions/9048e167-320c-4204-8671-f4bf4557b1d5/resourceGroups/DEVUAT-ASE-RG/providers/Microsoft.Network/virtualNetworks/DEVUAT-APP-VNET/subnets/DEVUAT-ASE-SUBNET'

@description('Key Vault resource ID containing the certificate')
param keyVaultResourceId string

@description('Certificate secret name in Key Vault')
param certificateSecretName string


// Import wildcard certificate from Key Vault
module certificate 'certificate-import.bicep' = {
  name: 'import-wildcard-certificate'
  params: {
    location: location
    keyVaultResourceId: keyVaultResourceId
    certificateSecretName: certificateSecretName
    appServicePlanId: appServices[0].appServicePlanId // Use first app's plan
    tags: commonTags
  }
}

// App Services
module appService 'app-service-module.bicep' = [for app in appServices: {
  name: 'deploy-${app.name}'
  params: {
    appServiceName: app.name
    location: location
    virtualNetworkSubnetId: virtualNetworkSubnetId
    appInsightsResourceId: app.appInsightsResourceId ?? ''
    appServicePlanId: app.appServicePlanId
    privateDnsZoneResourceId: !empty(privateDnsZoneResourceId) ? privateDnsZoneResourceId : null
		privateEndpointSubnetId: !empty(privateEndpointSubnetId) ? privateEndpointSubnetId :null
    logAnalyticsWorkspaceResourceId: !empty(logAnalyticsWorkspaceResourceId) ? logAnalyticsWorkspaceResourceId : ''
    tags: commonTags
    customDomains: app.?customDomains ?? []
    certificateThumbprint: length(app.?customDomains ?? []) > 0 ? certificate.outputs.thumbprint : ''
    deploymentSlots: app.?deploymentSlots ?? []
  }
}]


 // module domainVerification 'domain-verification.bicep' = [for (app, i) in appServices: if (length(app.?customDomains ?? []) > 0) {
   // name: 'domain-verification-${app.name}'
	 // dependsOn: [
		 // appService[i]
	 // ]
   // params: {
     // appName: app.name
     // certificateThumbprint: certificate.outputs.thumbprint
     // customDomains: app.customDomains
   // }
 // }]


// Outputs
output appServices array = [for (app, index) in appServices: {
  name: appService[index].name
  id: appService[index].outputs.appServiceId
  defaultHostName: appService[index].outputs.defaultHostName
  possibleOutboundIpAddresses: appService[index].outputs.possibleOutboundIpAddresses
  principalId: appService[index].outputs.principalId
  tenantId: appService[index].outputs.tenantId
  enabledHostNames: appService[index].outputs.enabledHostNames
  deploymentSlots: appService[index].outputs.deploymentSlots
}]

output summary object = {
  resourceGroup: resourceGroup().name
  appServicesCount: length(appServices)
  location: location
}
