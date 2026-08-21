<#
.SYNOPSIS
Exports Azure resource groups by subscription, Azure location, and region display name.

.DESCRIPTION
This script uses Azure CLI to list resource groups and enriches each row with
location metadata from 'az account list-locations'. It exports both a detailed
CSV and a summary CSV grouped by subscription and Azure location.

.EXAMPLE
.\Get-AzureResourceGroupsByLocation.ps1

Exports resource groups from the current Azure subscription.

.EXAMPLE
.\Get-AzureResourceGroupsByLocation.ps1 -SubscriptionId "<subscription-id>"

Exports resource groups from a specific subscription.

.EXAMPLE
.\Get-AzureResourceGroupsByLocation.ps1 -AllSubscriptions

Exports resource groups from all enabled subscriptions visible to the signed-in account.

.EXAMPLE
.\Get-AzureResourceGroupsByLocation.ps1 -InstallAzureCli -AllSubscriptions

Installs Azure CLI with winget if needed, signs in if needed, then exports all visible subscriptions.
#>

[CmdletBinding()]
param(
    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = "AzureCloud",

    [string]$SubscriptionId,

    [switch]$AllSubscriptions,

    [string]$OutputDir = (Join-Path $PSScriptRoot "exports"),

    [switch]$InstallAzureCli
)

$ErrorActionPreference = "Stop"

function Update-PathFromRegistry {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Ensure-AzureCli {
    Update-PathFromRegistry
    $az = Get-Command az -ErrorAction SilentlyContinue
    if ($az) {
        Write-Host "Azure CLI found: $($az.Source)"
        return
    }

    if (-not $InstallAzureCli) {
        throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows or rerun this script with -InstallAzureCli."
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget is not available. Install Azure CLI manually from https://aka.ms/installazurecliwindows."
    }

    Write-Host "Installing Azure CLI with winget..."
    winget install --exact --id Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements --disable-interactivity
    Update-PathFromRegistry

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI installation completed, but az is not available on PATH. Open a new PowerShell window and rerun the script."
    }
}

function Set-AzureCloud {
    param(
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$Name = "AzureCloud"
    )

    $currentCloud = az cloud show --query name --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentCloud) -or $currentCloud.Trim() -ne $Name) {
        Write-Host "Setting Azure CLI cloud to $Name..."
        az cloud set --name $Name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set Azure CLI cloud to '$Name'."
        }
    }
}

function Ensure-AzureLogin {
    $accountJson = az account show --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) {
        return
    }

    Write-Host "No Azure login found. Starting device-code sign-in..."
    az login --use-device-code --allow-no-subscriptions --output json | Out-Null
}

function Get-TargetSubscriptions {
    param(
        [string]$RequestedSubscriptionId,
        [bool]$IncludeAllSubscriptions
    )

    if ($RequestedSubscriptionId) {
        az account set --subscription $RequestedSubscriptionId
        return @((az account show --output json | ConvertFrom-Json))
    }

    if ($IncludeAllSubscriptions) {
        return @(az account list --all --query "[?state=='Enabled']" --output json | ConvertFrom-Json)
    }

    return @((az account show --output json | ConvertFrom-Json))
}

function Get-LocationLookup {
    $locations = @(az account list-locations --output json | ConvertFrom-Json)
    $lookup = @{}

    foreach ($location in $locations) {
        $lookup[$location.name] = [pscustomobject]@{
            Location = $location.name
            DisplayName = $location.displayName
            RegionalDisplayName = $location.regionalDisplayName
            GeographyGroup = $location.metadata.geographyGroup
            Latitude = $location.metadata.latitude
            Longitude = $location.metadata.longitude
            PhysicalLocation = $location.metadata.physicalLocation
            PairedRegion = (($location.metadata.pairedRegion | ForEach-Object { $_.name }) -join ";")
        }
    }

    return $lookup
}

Ensure-AzureCli
Set-AzureCloud -Name $AzureCloud
Ensure-AzureLogin

if ($SubscriptionId -and $AllSubscriptions) {
    throw "Use either -SubscriptionId or -AllSubscriptions, not both."
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$detailCsvPath = Join-Path $OutputDir "azure-resource-groups-by-location-$timestamp.csv"
$summaryCsvPath = Join-Path $OutputDir "azure-resource-groups-location-summary-$timestamp.csv"
$jsonPath = Join-Path $OutputDir "azure-resource-groups-by-location-$timestamp.json"

$subscriptions = Get-TargetSubscriptions -RequestedSubscriptionId $SubscriptionId -IncludeAllSubscriptions:$AllSubscriptions.IsPresent
if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    throw "No enabled Azure subscriptions were found for the signed-in account."
}

$locationLookup = Get-LocationLookup
$rows = foreach ($subscription in $subscriptions) {
    Write-Host "Reading resource groups from subscription: $($subscription.name) ($($subscription.id))"
    az account set --subscription $subscription.id

    $resourceGroups = @(az group list --output json | ConvertFrom-Json)
    foreach ($resourceGroup in $resourceGroups) {
        $locationInfo = $locationLookup[$resourceGroup.location]

        [pscustomobject]@{
            SubscriptionName = $subscription.name
            SubscriptionId = $subscription.id
            TenantId = $subscription.tenantId
            ResourceGroupName = $resourceGroup.name
            AzureLocation = $resourceGroup.location
            AzureRegion = if ($locationInfo) { $locationInfo.DisplayName } else { $null }
            RegionalDisplayName = if ($locationInfo) { $locationInfo.RegionalDisplayName } else { $null }
            GeographyGroup = if ($locationInfo) { $locationInfo.GeographyGroup } else { $null }
            PhysicalLocation = if ($locationInfo) { $locationInfo.PhysicalLocation } else { $null }
            Latitude = if ($locationInfo) { $locationInfo.Latitude } else { $null }
            Longitude = if ($locationInfo) { $locationInfo.Longitude } else { $null }
            PairedRegion = if ($locationInfo) { $locationInfo.PairedRegion } else { $null }
            ManagedBy = $resourceGroup.managedBy
            ProvisioningState = $resourceGroup.properties.provisioningState
            Tags = if ($resourceGroup.tags) { ($resourceGroup.tags | ConvertTo-Json -Compress) } else { $null }
        }
    }
}

$rows = @($rows)
$rows | Sort-Object SubscriptionName, AzureLocation, ResourceGroupName |
    Export-Csv -Path $detailCsvPath -NoTypeInformation -Encoding UTF8

$rows | ConvertTo-Json -Depth 20 |
    Set-Content -Path $jsonPath -Encoding UTF8

$summaryRows = $rows |
    Group-Object SubscriptionName, SubscriptionId, AzureLocation, AzureRegion, RegionalDisplayName, GeographyGroup |
    ForEach-Object {
        $first = $_.Group | Select-Object -First 1
        [pscustomobject]@{
            SubscriptionName = $first.SubscriptionName
            SubscriptionId = $first.SubscriptionId
            AzureLocation = $first.AzureLocation
            AzureRegion = $first.AzureRegion
            RegionalDisplayName = $first.RegionalDisplayName
            GeographyGroup = $first.GeographyGroup
            ResourceGroupCount = $_.Count
        }
    }

$summaryRows | Sort-Object SubscriptionName, AzureLocation |
    Export-Csv -Path $summaryCsvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Export complete."
Write-Host "Detailed CSV: $detailCsvPath"
Write-Host "Summary CSV:  $summaryCsvPath"
Write-Host "JSON:         $jsonPath"
Write-Host ""
Write-Host "Resource groups by location:"
$summaryRows |
    Sort-Object SubscriptionName, AzureLocation |
    Format-Table SubscriptionName, AzureLocation, AzureRegion, ResourceGroupCount -AutoSize |
    Out-String -Width 240 |
    Write-Host
