#requires -Version 7.0
<#
.SYNOPSIS
    Builds a new container image via ACR Tasks (no local Docker required).

.EXAMPLE
    ./scripts/build-image.ps1                  # tags :latest
    ./scripts/build-image.ps1 -ImageTag 0.2.0  # tags :0.2.0 AND :latest
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId  = '${AZURE_SUBSCRIPTION_ID}',
    [string]$AcrName         = 'acrweinongwfaqbot',
    [string]$ImageRepository = 'teams-faq-bot',
    [string]$ImageTag        = 'latest'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

az account set --subscription $SubscriptionId | Out-Null

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
Write-Host ""
Write-Host "Pushed: $loginServer/$ImageRepository`:$ImageTag" -ForegroundColor Green
Write-Host "Pushed: $loginServer/$ImageRepository`:latest" -ForegroundColor Green
