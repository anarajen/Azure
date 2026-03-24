
@description('The name of the App Service or Function App')
param appName string

@description('The thumbprint of the wildcard certificate')
param certificateThumbprint string

@description('An array of custom domains to bind')
param customDomains array

resource app 'Microsoft.Web/sites@2022-03-01' existing = {
  name: appName
}

// Register only the first custom domain from the array, it cause conflicts if multiple bindings are created in the same deployment
resource hostNameBinding 'Microsoft.Web/sites/hostNameBindings@2022-03-01' = {
  parent: app
  name: customDomains[0]
  properties: {
    sslState: 'SniEnabled'
    thumbprint: certificateThumbprint
  }
}

output bindings array = {
  appName: appName
  domain: customDomains[0]
  bindingName: hostNameBinding.name
}
