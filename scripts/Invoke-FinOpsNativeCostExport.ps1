<#
.SYNOPSIS
Exports Azure Cost Management data using native Az.Accounts token auth and ARM REST.

.DESCRIPTION
This is the first enterprise-native replacement for Azure CLI based Cost Management
queries. It uses FinOpsNativeAuth.psm1 to authenticate with an existing Az context,
managed identity, or service principal, then calls the Cost Management REST API
directly with Invoke-RestMethod.

The script currently writes the core Cost Management CSV/JSON files used by later
pipeline stages. Retail Prices enrichment remains in the legacy local/POC script
until the full native production pipeline is completed.
#>
[CmdletBinding()]
param(
    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = $(if ($env:FINOPS_AZURE_CLOUD) { $env:FINOPS_AZURE_CLOUD } else { "AzureCloud" }),

    [ValidateSet("Existing", "ManagedIdentity", "ServicePrincipal")]
    [string]$AuthMode = $(if ($env:FINOPS_AUTH_MODE) { $env:FINOPS_AUTH_MODE } else { "Existing" }),

    [string]$TenantId = $env:FINOPS_TENANT_ID,

    [string[]]$SubscriptionId = @(
        if ($env:FINOPS_SUBSCRIPTION_IDS) {
            $env:FINOPS_SUBSCRIPTION_IDS -split "[,;]" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
        }
    ),

    [datetime]$AsOfDate = (Get-Date),

    [datetime]$CustomStartDate = [datetime]::MinValue,

    [datetime]$CustomEndDate = [datetime]::MinValue,

    [string]$OutputDir = (Join-Path $PSScriptRoot "exports"),

    [string]$ClientId = $env:FINOPS_CLIENT_ID,

    [string]$ClientSecret = $env:FINOPS_CLIENT_SECRET,

    [string]$ManagedIdentityClientId = $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FinOpsNativeAuth.psm1") -Force

function Convert-CostResponseToRows {
    param([Parameter(Mandatory)]$Response)

    $columns = @($Response.properties.columns | ForEach-Object { $_.name })
    return @($Response.properties.rows | ForEach-Object {
        $row = $_
        $object = [ordered]@{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $object[$columns[$i]] = $row[$i]
        }
        [pscustomobject]$object
    })
}

function Export-NativeCostQuery {
    param(
        [Parameter(Mandatory)][object]$Subscription,
        [Parameter(Mandatory)][hashtable]$TimePeriod,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][object[]]$GroupingDimensions,
        [Parameter(Mandatory)][string]$FileSuffix
    )

    $subscriptionId = [string]$Subscription.subscriptionId
    $subscriptionName = [string]$Subscription.displayName
    $subscriptionDir = Join-Path (Join-Path $DestinationDir "subscriptions") $subscriptionId
    New-Item -ItemType Directory -Path $subscriptionDir -Force | Out-Null

    $body = @{
        type = "ActualCost"
        timeframe = "Custom"
        timePeriod = $TimePeriod
        dataset = @{
            granularity = "Daily"
            aggregation = @{
                totalCost = @{
                    name = "Cost"
                    function = "Sum"
                }
                totalQuantity = @{
                    name = "UsageQuantity"
                    function = "Sum"
                }
            }
            grouping = $GroupingDimensions
        }
    }

    $bodyPath = Join-Path $subscriptionDir "$Prefix-cost-query-$FileSuffix.json"
    $jsonPath = Join-Path $subscriptionDir "$Prefix-cost-by-$FileSuffix.json"
    $csvPath = Join-Path $subscriptionDir "$Prefix-cost-by-$FileSuffix.csv"

    $body | ConvertTo-Json -Depth 30 | Set-Content -Path $bodyPath -Encoding UTF8
    Write-Host "Querying $Prefix $FileSuffix costs for $subscriptionName ($subscriptionId)..."

    $response = Invoke-FinOpsArmRest `
        -AzureCloud $AzureCloud `
        -Method POST `
        -Path "/subscriptions/$subscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
        -Body $body `
        -MaxAttempts 8

    $response | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8
    $rows = @(Convert-CostResponseToRows -Response $response)
    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyName AzureCloud -NotePropertyValue $AzureCloud -Force
        $row | Add-Member -NotePropertyName SubscriptionId -NotePropertyValue $subscriptionId -Force
        $row | Add-Member -NotePropertyName SubscriptionName -NotePropertyValue $subscriptionName -Force
    }
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    [pscustomobject]@{
        Prefix = $Prefix
        FileSuffix = $FileSuffix
        SubscriptionId = $subscriptionId
        SubscriptionName = $subscriptionName
        Json = $jsonPath
        Csv = $csvPath
        RowCount = $rows.Count
        TotalCost = if ($rows.Count) { [math]::Round((($rows | Measure-Object -Property Cost -Sum).Sum), 4) } else { 0 }
        Currency = if ($rows.Count) { $rows[0].Currency } else { $null }
        Rows = $rows
    }
}

function Export-CombinedRows {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$FileSuffix
    )

    $rows = @($Results | ForEach-Object { $_.Rows })
    $csvPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.csv"
    $jsonPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.json"
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        prefix = $Prefix
        fileSuffix = $FileSuffix
        subscriptionCount = @($Results).Count
        rowCount = @($rows).Count
        subscriptions = @($Results | ForEach-Object {
            [ordered]@{
                id = $_.SubscriptionId
                name = $_.SubscriptionName
            }
        })
        rows = $rows
    } | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

    [pscustomobject]@{
        Prefix = $Prefix
        FileSuffix = $FileSuffix
        Csv = $csvPath
        Json = $jsonPath
        RowCount = @($rows).Count
        TotalCost = if ($rows.Count) { [math]::Round((($rows | Measure-Object -Property Cost -Sum).Sum), 4) } else { 0 }
        Currency = if ($rows.Count) { $rows[0].Currency } else { $null }
    }
}

Connect-FinOpsNativeAccount `
    -AzureCloud $AzureCloud `
    -AuthMode $AuthMode `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ClientSecret $ClientSecret `
    -ManagedIdentityClientId $ManagedIdentityClientId | Out-Null

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$subscriptions = if ($SubscriptionId.Count -gt 0) {
    foreach ($id in $SubscriptionId) {
        $details = Invoke-FinOpsArmRest -AzureCloud $AzureCloud -Method GET -Path "/subscriptions/$id?api-version=2022-12-01"
        [pscustomobject]@{
            subscriptionId = $details.subscriptionId
            displayName = $details.displayName
            state = $details.state
        }
    }
}
else {
    @(Get-FinOpsNativeSubscriptions -AzureCloud $AzureCloud -TenantId $TenantId | Where-Object { $_.state -eq "Enabled" })
}

if (-not $subscriptions -or @($subscriptions).Count -eq 0) {
    throw "No target subscriptions were found for native Cost Management export."
}

$monthStart = Get-Date -Year $AsOfDate.Year -Month $AsOfDate.Month -Day 1 -Hour 0 -Minute 0 -Second 0
$priorMonthStart = $monthStart.AddMonths(-1)
$priorMonthEnd = $monthStart.AddSeconds(-1)
$asOfEnd = Get-Date -Year $AsOfDate.Year -Month $AsOfDate.Month -Day $AsOfDate.Day -Hour 23 -Minute 59 -Second 59

$periods = @(
    @{
        Prefix = "mtd"
        TimePeriod = @{
            from = $monthStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $asOfEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    },
    @{
        Prefix = "last-month"
        TimePeriod = @{
            from = $priorMonthStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $priorMonthEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
)

if (($CustomStartDate -ne [datetime]::MinValue) -xor ($CustomEndDate -ne [datetime]::MinValue)) {
    throw "CustomStartDate and CustomEndDate must be supplied together."
}

if ($CustomStartDate -ne [datetime]::MinValue) {
    $periods += @{
        Prefix = "custom"
        TimePeriod = @{
            from = $CustomStartDate.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $CustomEndDate.Date.AddDays(1).AddSeconds(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

$serviceResourceGroupDimensions = @(
    @{ type = "Dimension"; name = "ServiceName" },
    @{ type = "Dimension"; name = "ResourceGroupName" }
)

$retailJoinDimensions = @(
    @{ type = "Dimension"; name = "ServiceName" },
    @{ type = "Dimension"; name = "ResourceLocation" },
    @{ type = "Dimension"; name = "Meter" },
    @{ type = "Dimension"; name = "Product" },
    @{ type = "Dimension"; name = "PartNumber" },
    @{ type = "Dimension"; name = "UnitOfMeasure" }
)

$summary = @()
foreach ($period in $periods) {
    $serviceResults = foreach ($subscription in $subscriptions) {
        Export-NativeCostQuery -Subscription $subscription -TimePeriod $period.TimePeriod -Prefix $period.Prefix -DestinationDir $OutputDir -GroupingDimensions $serviceResourceGroupDimensions -FileSuffix "service-resourcegroup"
    }
    $summary += Export-CombinedRows -Results @($serviceResults) -DestinationDir $OutputDir -Prefix $period.Prefix -FileSuffix "service-resourcegroup"

    $retailResults = foreach ($subscription in $subscriptions) {
        Export-NativeCostQuery -Subscription $subscription -TimePeriod $period.TimePeriod -Prefix $period.Prefix -DestinationDir $OutputDir -GroupingDimensions $retailJoinDimensions -FileSuffix "retail-join"
    }
    $summary += Export-CombinedRows -Results @($retailResults) -DestinationDir $OutputDir -Prefix $period.Prefix -FileSuffix "retail-join"
}

Write-Host ""
Write-Host "Native Cost Management exports saved to: $OutputDir"
$summary | Select-Object Prefix, FileSuffix, RowCount, TotalCost, Currency, Csv | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
