#requires -Version 7.0
<#
.SYNOPSIS
    Full bootstrap of the Teams FAQ bot Azure infra + first deploy.

.DESCRIPTION
    1. Deploys infra.bicep (UAMI, ACR, Log Analytics, Container Apps Env, RBAC).
    2. Builds + pushes the container image via ACR Tasks.
    3. Deploys app.bicep (Container App + Azure Bot, endpoint wired).

    Idempotent — safe to re-run; Bicep diffs against existing state.

.EXAMPLE
    ./scripts/deploy.ps1
    ./scripts/deploy.ps1 -ImageTag 0.2.0
    ./scripts/deploy.ps1 -SubscriptionId <guid> -ResourceGroup my-rg -Location westus3 -NamePrefix my-faqbot -AcrName myfaqbotacr -AoaiAccountName my-aoai
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId   = '${AZURE_SUBSCRIPTION_ID}',
    [string]$ResourceGroup    = 'weinongw-oai',
    [string]$Location         = 'westus3',
    [string]$NamePrefix       = 'weinongw-faqbot',
    [string]$AcrName          = 'acrweinongwfaqbot',
    [string]$AoaiAccountName  = 'weinongw-oai',
    [string]$ImageRepository  = 'teams-faq-bot',
    [string]$ImageTag         = 'latest',
    [switch]$SkipImageBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

Write-Host "==> Setting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

Write-Host "==> Ensuring resource group $ResourceGroup in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null

# -----------------------------------------------------------------------------
# Phase 1 — infra
# -----------------------------------------------------------------------------
Write-Host "==> [Phase 1] Deploying infra.bicep" -ForegroundColor Cyan
$infraDeployName = "infra-$(Get-Date -Format yyyyMMddHHmmss)"
$infraJson = az deployment group create `
    --resource-group $ResourceGroup `
    --name $infraDeployName `
    --template-file (Join-Path $repoRoot 'infra/infra.bicep') `
    --parameters (Join-Path $repoRoot 'infra/infra.bicepparam') `
    --parameters namePrefix=$NamePrefix acrName=$AcrName aoaiAccountName=$AoaiAccountName location=$Location `
    --query properties.outputs `
    -o json
if ($LASTEXITCODE -ne 0) { throw "infra deployment failed" }
$infra = $infraJson | ConvertFrom-Json

$uamiClientId   = $infra.uamiClientId.value
$acrLoginServer = $infra.acrLoginServer.value
$caeName        = $infra.containerAppEnvName.value

Write-Host "    UAMI client id : $uamiClientId"
Write-Host "    ACR login srv  : $acrLoginServer"
Write-Host "    CAE            : $caeName"

# -----------------------------------------------------------------------------
# Phase 2 — build + push image
# -----------------------------------------------------------------------------
$imageRef = "$acrLoginServer/$ImageRepository`:$ImageTag"
if ($SkipImageBuild) {
    Write-Host "==> [Phase 2] SKIPPED image build (will use $imageRef)" -ForegroundColor Yellow
} else {
    Write-Host "==> [Phase 2] az acr build -> $imageRef" -ForegroundColor Cyan
    Push-Location $repoRoot
    try {
        az acr build `
            --registry $AcrName `
            --image "$ImageRepository`:$ImageTag" `
            --image "$ImageRepository`:latest" `
            --file Dockerfile `
            . | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "az acr build failed" }
    } finally {
        Pop-Location
    }
}

# -----------------------------------------------------------------------------
# Phase 3 — Container App + Bot
# -----------------------------------------------------------------------------
Write-Host "==> [Phase 3] Deploying app.bicep with image $imageRef" -ForegroundColor Cyan
$appDeployName = "app-$(Get-Date -Format yyyyMMddHHmmss)"
$appJson = az deployment group create `
    --resource-group $ResourceGroup `
    --name $appDeployName `
    --template-file (Join-Path $repoRoot 'infra/app.bicep') `
    --parameters (Join-Path $repoRoot 'infra/app.bicepparam') `
    --parameters namePrefix=$NamePrefix uamiName="id-$NamePrefix" acrName=$AcrName containerEnvName=$caeName aoaiAccountName=$AoaiAccountName containerImage=$imageRef location=$Location `
    --query properties.outputs `
    -o json
if ($LASTEXITCODE -ne 0) { throw "app deployment failed" }
$app = $appJson | ConvertFrom-Json

Write-Host ""
Write-Host "==> DONE" -ForegroundColor Green
Write-Host "    Container App  : https://$($app.containerAppFqdn.value)"
Write-Host "    Health         : https://$($app.containerAppFqdn.value)/health"
Write-Host "    Bot endpoint   : $($app.messagingEndpoint.value)"
Write-Host "    Azure Bot name : $($app.botName.value)"
Write-Host ""
Write-Host "Test in Web Chat:" -ForegroundColor Cyan
Write-Host "  https://ms.portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.BotService/botServices/$($app.botName.value)/channelsReact"
