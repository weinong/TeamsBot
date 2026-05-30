// =============================================================================
// Infra stage: identity, registry, observability, container apps environment,
// and role assignments. Run this BEFORE building the container image.
//
// Deploy:
//   az deployment group create -g <rg> -f infra/infra.bicep -p infra/infra.bicepparam
// =============================================================================

@description('Azure region for new resources.')
param location string = resourceGroup().location

@description('Short name prefix used to compose every resource name.')
param namePrefix string

@description('Globally unique ACR name. Lowercase alphanumeric, 5-50 chars.')
param acrName string

@description('Name of an EXISTING Azure OpenAI account (same RG) the bot should call.')
param aoaiAccountName string

// -----------------------------------------------------------------------------
// User-assigned managed identity (bot identity + AOAI/ACR consumer)
// -----------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}'
  location: location
}

// -----------------------------------------------------------------------------
// Azure Container Registry
// -----------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// -----------------------------------------------------------------------------
// Log Analytics workspace + Container Apps environment
// -----------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Role assignments for the UAMI
// -----------------------------------------------------------------------------

// Existing Azure OpenAI account (in this RG)
resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aoaiAccountName
}

// Built-in role definition IDs
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var aoaiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource uamiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, uami.id, acrPullRoleId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

resource uamiAoaiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aoai
  name: guid(aoai.id, uami.id, aoaiUserRoleId)
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aoaiUserRoleId)
  }
}

// -----------------------------------------------------------------------------
// Outputs (consumed by app.bicep / the deploy script)
// -----------------------------------------------------------------------------
output uamiName string = uami.name
output uamiResourceId string = uami.id
output uamiClientId string = uami.properties.clientId
output uamiPrincipalId string = uami.properties.principalId

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer

output containerAppEnvName string = cae.name
output containerAppEnvId string = cae.id

output aoaiEndpoint string = aoai.properties.endpoint
