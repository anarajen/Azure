@description('Location for the certificate')
param location string

@description('Key Vault resource ID')
param keyVaultResourceId string

@description('Certificate secret name in Key Vault')
param certificateSecretName string

@description('App Service Plan ID')
param appServicePlanId string

@description('Tags to apply')
param tags object = {}

// Extract Key Vault ID and secret URI
var keyVaultId = keyVaultResourceId
var secretUri = '${keyVaultResourceId}/secrets/${certificateSecretName}'

// Import certificate from Key Vault
resource certificate 'Microsoft.Web/certificates@2022-03-01' = {
  name: 'krispay-nonprod-kv-Sectigo-nonprodkrispaydotcom-2025'
  location: location
  tags: tags
  properties: {
    keyVaultId: keyVaultId
    keyVaultSecretName: certificateSecretName
    serverFarmId: appServicePlanId
  }
}

output thumbprint string = certificate.properties.thumbprint
output certificateId string = certificate.id
output certificateName string = certificate.name
