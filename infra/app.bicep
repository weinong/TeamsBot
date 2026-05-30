// =============================================================================
// App stage: Container App (pulls the freshly built image) + Azure Bot
// pointed at it. Run AFTER infra.bicep and AFTER az acr build.
//
// Deploy:
//   az deployment group create -g <rg> -f infra/app.bicep -p infra/app.bicepparam \
//     -p containerImage=<acr-login-server>/teams-faq-bot:<tag>
// =============================================================================

@description('Azure region for new resources.')
param location string = resourceGroup().location

@description('Short name prefix (must match infra.bicep).')
param namePrefix string

@description('Full image reference, e.g. acrweinongwfaqbot.azurecr.io/teams-faq-bot:0.1.0')
param containerImage string

@description('Name of the existing UAMI (from infra.bicep).')
param uamiName string

@description('Name of the existing ACR (from infra.bicep).')
param acrName string

@description('Name of the existing Container Apps environment (from infra.bicep).')
param containerEnvName string

@description('Name of the existing Azure OpenAI account.')
param aoaiAccountName string

@description('Chat completion deployment name in AOAI.')
param chatDeployment string = 'gpt-5.4'

@description('Embedding deployment name in AOAI.')
param embeddingDeployment string = 'text-embedding-3-large'

@description('Azure OpenAI REST API version.')
param aoaiApiVersion string = '2024-06-01'

@description('Set true for o1/o3/o4/gpt-5 family. If false, auto-detect by name.')
param forceReasoningModel bool = false

@description('Min replicas for the Container App.')
param minReplicas int = 1

@description('Max replicas for the Container App.')
param maxReplicas int = 3

@description('Bot SKU. F0 is free.')
@allowed([ 'F0', 'S1' ])
param botSku string = 'F0'

// -----------------------------------------------------------------------------
// Existing resources (created by infra.bicep)
// -----------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: uamiName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerEnvName
}

resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: aoaiAccountName
}

// -----------------------------------------------------------------------------
// Container App
// -----------------------------------------------------------------------------
resource ca 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${namePrefix}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3978
        transport: 'auto'
        traffic: [
          { latestRevision: true, weight: 100 }
        ]
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uami.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'bot'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'PORT', value: '3978' }
            { name: 'BOT_ID', value: uami.properties.clientId }
            { name: 'BOT_TYPE', value: 'UserAssignedMSI' }
            { name: 'BOT_TENANT_ID', value: subscription().tenantId }
            { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
            { name: 'AZURE_OPENAI_ENDPOINT', value: aoai.properties.endpoint }
            { name: 'AZURE_OPENAI_API_VERSION', value: aoaiApiVersion }
            { name: 'AZURE_OPENAI_CHAT_DEPLOYMENT', value: chatDeployment }
            { name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT', value: embeddingDeployment }
            { name: 'AZURE_OPENAI_REASONING_MODEL', value: forceReasoningModel ? 'true' : '' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Azure Bot (UserAssignedMSI — no client secret / cert needed)
// -----------------------------------------------------------------------------
resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: 'bot-${namePrefix}'
  location: 'global'
  kind: 'azurebot'
  sku: { name: botSku }
  properties: {
    displayName: 'bot-${namePrefix}'
    endpoint: 'https://${ca.properties.configuration.ingress.fqdn}/api/messages'
    msaAppId: uami.properties.clientId
    msaAppType: 'UserAssignedMSI'
    msaAppTenantId: subscription().tenantId
    msaAppMSIResourceId: uami.id
    iconUrl: 'https://docs.botframework.com/static/devportal/client/images/bot-framework-default.png'
    developerAppInsightsApplicationId: ''
    publicNetworkAccess: 'Enabled'
  }
}

// Channels — Web Chat & Direct Line are auto-provisioned with the bot.
// Add the Microsoft Teams channel so the app can be sideloaded into Teams.
resource teamsChannel 'Microsoft.BotService/botServices/channels@2022-09-15' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      isEnabled: true
      enableCalling: false
    }
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output containerAppName string = ca.name
output containerAppFqdn string = ca.properties.configuration.ingress.fqdn
output messagingEndpoint string = bot.properties.endpoint
output botName string = bot.name
