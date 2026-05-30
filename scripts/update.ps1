#requires -Version 7.0
<#
.SYNOPSIS
    Quick redeploy: build a new image and roll the Container App.
    Use this for everyday code/FAQ updates (no infra changes).

.EXAMPLE
    ./scripts/update.ps1
    ./scripts/update.ps1 -ImageTag 0.2.0
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId       = '${AZURE_SUBSCRIPTION_ID}',
    [string]$ResourceGroup        = 'weinongw-oai',
    [string]$AcrName              = 'acrweinongwfaqbot',
    [string]$ImageRepository      = 'teams-faq-bot',
    [string]$ImageTag             = 'latest',
    [string]$ContainerAppName     = 'ca-weinongw-faqbot'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

az account set --subscription $SubscriptionId | Out-Null

Write-Host "==> Building image $ImageRepository`:$ImageTag" -ForegroundColor Cyan
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

$loginServer = az acr show -n $AcrName --query loginServer -o tsv
$imageRef = "$loginServer/$ImageRepository`:$ImageTag"

Write-Host "==> Rolling Container App $ContainerAppName -> $imageRef" -ForegroundColor Cyan
az containerapp update `
    --resource-group $ResourceGroup `
    --name $ContainerAppName `
    --image $imageRef `
    --query "{name:name, image:properties.template.containers[0].image, latestRev:properties.latestRevisionName}" `
    -o table
if ($LASTEXITCODE -ne 0) { throw "containerapp update failed" }

Write-Host ""
Write-Host "Done. Tail logs with:" -ForegroundColor Green
Write-Host "  az containerapp logs show -g $ResourceGroup -n $ContainerAppName --follow"
