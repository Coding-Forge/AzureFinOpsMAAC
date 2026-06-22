<#
.SYNOPSIS
Pulls Azure Cost Management actual-cost data and saves JSON/CSV exports.

.DESCRIPTION
This script reproduces the cost-analysis pull performed from this machine:
- verifies Azure CLI is available, optionally installing it with winget
- signs in with device-code flow when no Azure context exists
- optionally sets the tenant and subscription context
- queries Cost Management for month-to-date and prior-month actual costs
- exports raw JSON, detailed CSV, summary CSV files, and Retail Prices join/enrichment files

.EXAMPLE
.\Get-FdpoCostAnalysis.ps1 -SubscriptionId "c3454f9a-72a4-473e-b7ab-4e9b1107fd6d"

.EXAMPLE
.\Get-FdpoCostAnalysis.ps1 -TenantId "<tenant-id>" -SubscriptionId "<subscription-id>" -InstallAzureCli
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    [string]$SubscriptionId,

    [string]$OutputDir = (Join-Path $PSScriptRoot "exports"),

    [datetime]$AsOfDate = (Get-Date),

    [switch]$InstallAzureCli,

    [switch]$SkipRetailPriceLookup
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

function Ensure-AzureLogin {
    $accountJson = az account show --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) {
        return
    }

    Write-Host "No Azure login found. Starting device-code sign-in..."
    $loginArgs = @("login", "--use-device-code", "--allow-no-subscriptions", "--output", "json")
    if ($TenantId) {
        $loginArgs += @("--tenant", $TenantId)
    }

    az @loginArgs | Out-Null
}

function Set-AzureContext {
    if ($TenantId -and -not $SubscriptionId) {
        Write-Host "TenantId was provided without SubscriptionId. Logging into tenant and using the default visible subscription."
        az login --tenant $TenantId --use-device-code --allow-no-subscriptions --output json | Out-Null
    }

    if ($SubscriptionId) {
        Write-Host "Setting Azure subscription context to $SubscriptionId..."
        az account set --subscription $SubscriptionId
    }

    $account = az account show --output json | ConvertFrom-Json
    if (-not $account.id) {
        throw "No active Azure subscription is selected. Run 'az account list --all --output table' and rerun with -SubscriptionId."
    }

    Write-Host "Using tenant: $($account.tenantId)"
    Write-Host "Using subscription: $($account.name) ($($account.id))"
    return $account
}

function Convert-CostResponseToCsv {
    param(
        [Parameter(Mandatory)]
        [string]$JsonPath,

        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    $json = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $columns = @($json.properties.columns | ForEach-Object { $_.name })
    $rows = @($json.properties.rows | ForEach-Object {
        $row = $_
        $object = [ordered]@{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $object[$columns[$i]] = $row[$i]
        }
        [pscustomobject]$object
    })

    $rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    return $rows
}

function Normalize-LocationKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return ($Value.ToLowerInvariant() -replace "[^a-z0-9]", "")
}

function Get-ArmRegionNameLookup {
    $locations = @(az account list-locations --output json | ConvertFrom-Json)
    $lookup = @{}

    foreach ($location in $locations) {
        $keys = @(
            $location.name,
            $location.displayName,
            $location.regionalDisplayName,
            $location.metadata.physicalLocation
        )

        foreach ($key in $keys) {
            $normalized = Normalize-LocationKey $key
            if ($normalized) {
                $lookup[$normalized] = $location.name
            }
        }

        # Cost Management commonly returns "us west 3"; Retail Prices expects "westus3".
        $displayName = [string]$location.displayName
        if ($displayName -match "^(?<direction>East|West|North|South|Central)\s+US(?<suffix>.*)$") {
            $alternate = "US $($Matches.direction)$($Matches.suffix)"
            $lookup[(Normalize-LocationKey $alternate)] = $location.name
        }
    }

    $lookup["global"] = "global"
    return $lookup
}

function Add-ArmRegionName {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [hashtable]$LocationLookup
    )

    foreach ($row in $Rows) {
        $resourceLocation = [string]$row.ResourceLocation
        $normalized = Normalize-LocationKey $resourceLocation
        $armRegionName = if ($LocationLookup.ContainsKey($normalized)) { $LocationLookup[$normalized] } else { $resourceLocation }

        $row | Add-Member -NotePropertyName ArmRegionName -NotePropertyValue $armRegionName -Force
        $row
    }
}

function New-ODataStringLiteral {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-RetailPriceCandidates {
    param(
        [string]$ServiceName,
        [string]$MeterName,
        [string]$ArmRegionName,
        [string]$UnitOfMeasure,
        [hashtable]$Cache
    )

    $cacheKey = "$ServiceName|$MeterName|$ArmRegionName|$UnitOfMeasure"
    if ($Cache.ContainsKey($cacheKey)) {
        return @($Cache[$cacheKey])
    }

    $filters = @()
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
        $filters += "serviceName eq $(New-ODataStringLiteral $ServiceName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($MeterName)) {
        $filters += "meterName eq $(New-ODataStringLiteral $MeterName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ArmRegionName)) {
        $filters += "armRegionName eq $(New-ODataStringLiteral $ArmRegionName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($UnitOfMeasure)) {
        $filters += "unitOfMeasure eq $(New-ODataStringLiteral $UnitOfMeasure)"
    }

    if ($filters.Count -eq 0) {
        $Cache[$cacheKey] = @()
        return @()
    }

    $filter = $filters -join " and "
    $url = "https://prices.azure.com/api/retail/prices?`$filter=$([uri]::EscapeDataString($filter))"
    $items = @()

    do {
        $response = Invoke-RestMethod -Uri $url -Method Get
        $items += @($response.Items)
        $url = $response.NextPageLink
    } while ($url)

    $Cache[$cacheKey] = @($items)
    return @($items)
}

function Select-BestRetailPriceMatch {
    param(
        [Parameter(Mandatory)]
        [object]$CostRow,

        [object[]]$Candidates
    )

    if (-not $Candidates -or $Candidates.Count -eq 0) {
        return [pscustomobject]@{ MatchStatus = "NoMatch"; CandidateCount = 0; Item = $null }
    }

    $costProduct = ([string]$CostRow.Product).ToLowerInvariant()
    $ranked = @($Candidates | ForEach-Object {
        $score = 0
        if ($costProduct -and $_.productName -and $costProduct.Contains(([string]$_.productName).ToLowerInvariant())) {
            $score += 10
        }
        if ($costProduct -and $_.skuName -and $costProduct.Contains(([string]$_.skuName).ToLowerInvariant())) {
            $score += 5
        }
        [pscustomobject]@{ Score = $score; Item = $_ }
    } | Sort-Object Score -Descending)

    $bestScore = $ranked[0].Score
    $bestItems = @($ranked | Where-Object Score -eq $bestScore | ForEach-Object { $_.Item })
    $uniqueSkuIds = @($bestItems | Select-Object -ExpandProperty skuId -Unique)
    $uniqueMeterIds = @($bestItems | Select-Object -ExpandProperty meterId -Unique)
    $status = if ($bestItems.Count -eq 1 -or ($uniqueSkuIds.Count -eq 1 -and $uniqueMeterIds.Count -eq 1)) { "Matched" } else { "MultipleCandidates" }

    return [pscustomobject]@{
        MatchStatus = $status
        CandidateCount = $Candidates.Count
        Item = ($bestItems | Select-Object -First 1)
    }
}

function Add-RetailPriceData {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    $cache = @{}
    $index = 0
    $total = $Rows.Count

    foreach ($row in $Rows) {
        $index++
        if (($index % 25) -eq 0 -or $index -eq 1 -or $index -eq $total) {
            Write-Host "Retail Prices lookup progress: $index / $total"
        }

        $candidates = Get-RetailPriceCandidates `
            -ServiceName $row.ServiceName `
            -MeterName $row.Meter `
            -ArmRegionName $row.ArmRegionName `
            -UnitOfMeasure $row.UnitOfMeasure `
            -Cache $cache

        $match = Select-BestRetailPriceMatch -CostRow $row -Candidates $candidates
        $item = $match.Item

        $row | Add-Member -NotePropertyName RetailMatchStatus -NotePropertyValue $match.MatchStatus -Force
        $row | Add-Member -NotePropertyName RetailCandidateCount -NotePropertyValue $match.CandidateCount -Force
        $row | Add-Member -NotePropertyName RetailSkuId -NotePropertyValue $(if ($item) { $item.skuId } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailMeterId -NotePropertyValue $(if ($item) { $item.meterId } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailProductId -NotePropertyValue $(if ($item) { $item.productId } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailProductName -NotePropertyValue $(if ($item) { $item.productName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailSkuName -NotePropertyValue $(if ($item) { $item.skuName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailMeterName -NotePropertyValue $(if ($item) { $item.meterName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailArmRegionName -NotePropertyValue $(if ($item) { $item.armRegionName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailUnitOfMeasure -NotePropertyValue $(if ($item) { $item.unitOfMeasure } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailPrice -NotePropertyValue $(if ($item) { $item.retailPrice } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailUnitPrice -NotePropertyValue $(if ($item) { $item.unitPrice } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailCurrencyCode -NotePropertyValue $(if ($item) { $item.currencyCode } else { $null }) -Force
        $row
    }
}

function Invoke-AzRestWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$BodyPath,

        [int]$MaxAttempts = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $args = @("rest", "--method", $Method, "--uri", $Uri, "--output", "json")
        if ($BodyPath) {
            $args += @("--body", "@$BodyPath")
        }

        $output = az @args 2>&1
        if ($LASTEXITCODE -eq 0) {
            return ($output -join [Environment]::NewLine)
        }

        $message = ($output -join [Environment]::NewLine)
        $isRetryable = $message -match "Too Many Requests|429|temporarily unavailable|timeout|timed out|503|504"
        if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
            throw "Azure REST call failed after $attempt attempt(s): $message"
        }

        $delaySeconds = [Math]::Min(60, [Math]::Pow(2, $attempt) * 5)
        Write-Warning "Azure REST call was throttled or temporarily unavailable. Retrying in $delaySeconds seconds. Attempt $attempt of $MaxAttempts."
        Start-Sleep -Seconds $delaySeconds
    }
}

function Invoke-CostQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [hashtable]$TimePeriod,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [object[]]$GroupingDimensions = @(
            @{ type = "Dimension"; name = "ServiceName" },
            @{ type = "Dimension"; name = "ResourceGroupName" }
        ),

        [string]$FileSuffix = "service-resourcegroup"
    )

    $uri = "https://management.azure.com$Scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
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
    } | ConvertTo-Json -Depth 20

    $bodyPath = Join-Path $DestinationDir "$Prefix-cost-query.json"
    $jsonPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.json"
    $csvPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.csv"

    $body | Set-Content -Path $bodyPath -Encoding UTF8

    Write-Host "Querying $Prefix costs..."
    Invoke-AzRestWithRetry -Method "post" -Uri $uri -BodyPath $bodyPath |
        Set-Content -Path $jsonPath -Encoding UTF8

    $rows = Convert-CostResponseToCsv -JsonPath $jsonPath -CsvPath $csvPath
    $total = ($rows | Measure-Object -Property Cost -Sum).Sum
    $currency = ($rows | Select-Object -First 1 -ExpandProperty Currency -ErrorAction SilentlyContinue)

    return [pscustomobject]@{
        Prefix = $Prefix
        Json = $jsonPath
        Csv = $csvPath
        RowCount = $rows.Count
        TotalCost = [math]::Round($total, 4)
        Currency = $currency
    }
}

function New-CostSummaries {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [Parameter(Mandatory)]
        [string[]]$Prefixes
    )

    $serviceRows = foreach ($prefix in $Prefixes) {
        $csvPath = Join-Path $DestinationDir "$prefix-cost-by-service-resourcegroup.csv"
        $csv = @(Import-Csv $csvPath)
        $csv | Group-Object ServiceName | ForEach-Object {
            [pscustomobject]@{
                Period = $prefix
                ServiceName = $_.Name
                Cost = [math]::Round((($_.Group | Measure-Object -Property Cost -Sum).Sum), 4)
                Currency = ($_.Group | Select-Object -First 1 -ExpandProperty Currency)
            }
        }
    }

    $resourceGroupRows = foreach ($prefix in $Prefixes) {
        $csvPath = Join-Path $DestinationDir "$prefix-cost-by-service-resourcegroup.csv"
        $csv = @(Import-Csv $csvPath)
        $csv | Group-Object ResourceGroupName | ForEach-Object {
            [pscustomobject]@{
                Period = $prefix
                ResourceGroupName = $_.Name
                Cost = [math]::Round((($_.Group | Measure-Object -Property Cost -Sum).Sum), 4)
                Currency = ($_.Group | Select-Object -First 1 -ExpandProperty Currency)
            }
        }
    }

    $serviceSummaryPath = Join-Path $DestinationDir "cost-summary-by-service.csv"
    $resourceGroupSummaryPath = Join-Path $DestinationDir "cost-summary-by-resourcegroup.csv"

    $serviceRows | Sort-Object Period, @{ Expression = "Cost"; Descending = $true } |
        Export-Csv -Path $serviceSummaryPath -NoTypeInformation -Encoding UTF8
    $resourceGroupRows | Sort-Object Period, @{ Expression = "Cost"; Descending = $true } |
        Export-Csv -Path $resourceGroupSummaryPath -NoTypeInformation -Encoding UTF8

    return [pscustomobject]@{
        ServiceSummary = $serviceSummaryPath
        ResourceGroupSummary = $resourceGroupSummaryPath
        ServiceRows = $serviceRows
        ResourceGroupRows = $resourceGroupRows
    }
}

Ensure-AzureCli
Ensure-AzureLogin
$account = Set-AzureContext

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

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

$scope = "/subscriptions/$($account.id)"
$results = foreach ($period in $periods) {
    Invoke-CostQuery -Scope $scope -TimePeriod $period.TimePeriod -Prefix $period.Prefix -DestinationDir $OutputDir
}

$retailJoinGroupings = @(
    @{ type = "Dimension"; name = "ServiceName" },
    @{ type = "Dimension"; name = "ResourceLocation" },
    @{ type = "Dimension"; name = "Meter" },
    @{ type = "Dimension"; name = "Product" },
    @{ type = "Dimension"; name = "PartNumber" },
    @{ type = "Dimension"; name = "UnitOfMeasure" }
)

$retailJoinResults = foreach ($period in $periods) {
    Invoke-CostQuery `
        -Scope $scope `
        -TimePeriod $period.TimePeriod `
        -Prefix $period.Prefix `
        -DestinationDir $OutputDir `
        -GroupingDimensions $retailJoinGroupings `
        -FileSuffix "retail-join"
}

$locationLookup = Get-ArmRegionNameLookup
$retailEnrichedPaths = @()

foreach ($period in $periods) {
    $prefix = $period.Prefix
    $retailJoinCsvPath = Join-Path $OutputDir "$prefix-cost-by-retail-join.csv"
    $retailRows = @(Import-Csv $retailJoinCsvPath)
    $retailRowsWithRegion = @(Add-ArmRegionName -Rows $retailRows -LocationLookup $locationLookup)
    $retailJoinWithRegionPath = Join-Path $OutputDir "$prefix-cost-by-retail-join-with-arm-region.csv"
    $retailRowsWithRegion | Export-Csv -Path $retailJoinWithRegionPath -NoTypeInformation -Encoding UTF8

    if (-not $SkipRetailPriceLookup) {
        Write-Host "Adding Retail Prices API data for $prefix..."
        $enrichedRows = @(Add-RetailPriceData -Rows $retailRowsWithRegion)
        $retailEnrichedPath = Join-Path $OutputDir "$prefix-cost-by-retail-join-enriched.csv"
        $enrichedRows | Export-Csv -Path $retailEnrichedPath -NoTypeInformation -Encoding UTF8
        $retailEnrichedPaths += $retailEnrichedPath
    }
}

$summaries = New-CostSummaries -DestinationDir $OutputDir -Prefixes @("mtd", "last-month")

Write-Host ""
Write-Host "Cost exports saved to: $OutputDir"
Write-Host ""
Write-Host "Query results:"
$results | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
Write-Host "Retail join query results:"
$retailJoinResults | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
Write-Host "Summary by service: $($summaries.ServiceSummary)"
Write-Host "Summary by resource group: $($summaries.ResourceGroupSummary)"
Write-Host "Retail join CSVs: $(Join-Path $OutputDir '*-cost-by-retail-join-with-arm-region.csv')"
if (-not $SkipRetailPriceLookup) {
    Write-Host "Retail enriched CSVs:"
    $retailEnrichedPaths | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host "Retail Prices API lookup skipped. Rerun without -SkipRetailPriceLookup to attempt skuId and meterId enrichment."
}
Write-Host ""
Write-Host "Top month-to-date services:"
$summaries.ServiceRows |
    Where-Object Period -eq "mtd" |
    Sort-Object Cost -Descending |
    Select-Object -First 10 |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Write-Host
