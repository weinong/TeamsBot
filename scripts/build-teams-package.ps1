#requires -Version 7.0
<#
.SYNOPSIS
    Render appPackage/manifest.template.json and produce a sideloadable Teams app zip.

.DESCRIPTION
    Substitutes ${BOT_APP_ID} in the template with the bot's UAMI clientId, then
    zips manifest.json + color.png + outline.png into appPackage/faqbot-teams-app.zip.

    BOT_APP_ID can be passed as -BotAppId, sourced from $env:BOT_APP_ID, or
    auto-discovered from the Azure Bot resource if -ResourceGroup/-BotName are passed
    (requires `az login`).

.EXAMPLE
    $env:BOT_APP_ID = '<uami-client-id>'; ./scripts/build-teams-package.ps1
    ./scripts/build-teams-package.ps1 -BotAppId <guid>
    ./scripts/build-teams-package.ps1 -ResourceGroup weinongw-oai -BotName bot-weinongw-faqbot
#>
[CmdletBinding()]
param(
    [string]$BotAppId       = $env:BOT_APP_ID,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup,
    [string]$BotName,
    [string]$OutputZip      = 'appPackage/faqbot-teams-app.zip'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

if (-not $BotAppId) {
    if ($ResourceGroup -and $BotName) {
        if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null }
        Write-Host "==> Resolving botId from Azure Bot $BotName" -ForegroundColor Cyan
        $BotAppId = az bot show -g $ResourceGroup -n $BotName --query 'properties.msaAppId' -o tsv
        if (-not $BotAppId) { throw "Could not resolve msaAppId for bot $BotName in $ResourceGroup." }
    } else {
        throw "BotAppId not provided. Set `$env:BOT_APP_ID, pass -BotAppId <guid>, or pass -ResourceGroup + -BotName for auto-discovery. See .env.example."
    }
}

$templatePath = Join-Path $repoRoot 'appPackage/manifest.template.json'
$manifestPath = Join-Path $repoRoot 'appPackage/manifest.json'
$colorPath    = Join-Path $repoRoot 'appPackage/color.png'
$outlinePath  = Join-Path $repoRoot 'appPackage/outline.png'

foreach ($p in @($templatePath, $colorPath, $outlinePath)) {
    if (-not (Test-Path $p)) { throw "Missing required file: $p" }
}

Write-Host "==> Rendering manifest.json with botId=$BotAppId" -ForegroundColor Cyan
$rendered = (Get-Content $templatePath -Raw) -replace '\$\{BOT_APP_ID\}', $BotAppId
Set-Content -Path $manifestPath -Value $rendered -Encoding UTF8 -NoNewline

# Sanity check: parse it
try { $null = $rendered | ConvertFrom-Json } catch { throw "Rendered manifest is not valid JSON: $_" }

$zipFullPath = Join-Path $repoRoot $OutputZip
if (Test-Path $zipFullPath) { Remove-Item $zipFullPath -Force }
Write-Host "==> Building zip $OutputZip" -ForegroundColor Cyan
Compress-Archive -Path $manifestPath, $colorPath, $outlinePath -DestinationPath $zipFullPath -Force

Write-Host ""
Write-Host "Package: $zipFullPath" -ForegroundColor Green
Write-Host "Sideload via: Teams -> Apps -> Manage your apps -> Upload an app -> Upload a custom app" -ForegroundColor Green
