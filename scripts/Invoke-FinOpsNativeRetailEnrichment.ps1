<#
.SYNOPSIS
Adds Azure Retail Prices API matching to native Cost Management retail-join CSVs.

.DESCRIPTION
Reads native `*-cost-by-retail-join.csv` files, normalizes ARM region names,
queries the public Azure Retail Prices API, and writes:

- `*-cost-by-retail-join-with-arm-region.csv`
- `*-cost-by-retail-join-enriched.csv`

This script does not require Azure CLI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

function Normalize-LocationKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return ($Value.ToLowerInvariant() -replace "[^a-z0-9]", "")
}

function Convert-CostManagementLocationToArmRegionName {
    param([string]$ResourceLocation)
    if ([string]::IsNullOrWhiteSpace($ResourceLocation)) { return $ResourceLocation }
    $value = $ResourceLocation.Trim().ToLowerInvariant()
    if ($value -match "^us\s+(?<direction>east|west|north|south|central)(?<suffix>.*)$") {
        $suffix = ($Matches.suffix -replace "[^a-z0-9]", "")
        return "$($Matches.direction)us$suffix"
    }
    if ($value -match "^us\s+gov\s+(?<region>virginia|arizona|texas)$") { return "usgov$($Matches.region)" }
    if ($value -match "^us\s+dod\s+(?<region>central|east)$") { return "usdod$($Matches.region)" }
    if ($value -match "^us\s+(?<region>west|east|central)\s*(?<suffix>\d*)$") { return "$($Matches.region)us$($Matches.suffix)" }
    return ($value -replace "\s+", "")
}

function ConvertTo-FinOpsCanonicalArmRegionName {
    param([string]$RegionName)
    if ([string]::IsNullOrWhiteSpace($RegionName)) { return $RegionName }
    $converted = Convert-CostManagementLocationToArmRegionName $RegionName
    $normalized = Normalize-LocationKey $converted
    switch ($normalized) {
        "usgovvirginia" { return "usgovvirginia" }
        "usgovtexas" { return "usgovtexas" }
        "usgovarizona" { return "usgovarizona" }
        "usdodcentral" { return "usdodcentral" }
        "usdodeast" { return "usdodeast" }
        "global" { return "global" }
        default { return $converted }
    }
}

function New-ODataStringLiteral {
    param([string]$Value)
    if ($null -eq $Value) { $Value = "" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-RestRetryDelaySeconds {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord, [int]$Attempt)
    $retryAfter = $null
    if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.Headers) {
        $retryAfter = $ErrorRecord.Exception.Response.Headers["Retry-After"]
    }
    if (-not [string]::IsNullOrWhiteSpace($retryAfter)) {
        $seconds = 0
        if ([int]::TryParse($retryAfter, [ref]$seconds) -and $seconds -gt 0) { return [Math]::Min(300, $seconds) }
    }
    return [Math]::Min(120, [Math]::Pow(2, $Attempt) * 5)
}

function Invoke-RestMethodWithRetry {
    param([string]$Uri, [string]$Method = "Get", [int]$MaxAttempts = 6)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method $Method
        }
        catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
            $message = $_.Exception.Message
            $isRetryable = $statusCode -eq 429 -or $statusCode -in @(500, 502, 503, 504) -or $message -match "Too many requests|Too Many Requests|temporarily unavailable|timeout|timed out"
            if (-not $isRetryable -or $attempt -eq $MaxAttempts) { throw }
            $delaySeconds = Get-RestRetryDelaySeconds -ErrorRecord $_ -Attempt $attempt
            Write-Warning "Retail Prices API request was throttled or temporarily unavailable. Retrying in $delaySeconds seconds. Attempt $attempt of $MaxAttempts."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-RetailPriceCandidates {
    param([string]$ServiceName, [string]$MeterName, [string]$ArmRegionName, [string]$UnitOfMeasure, [hashtable]$Cache)
    $cacheKey = "$ServiceName|$MeterName|$ArmRegionName|$UnitOfMeasure"
    if ($Cache.ContainsKey($cacheKey)) { return @($Cache[$cacheKey]) }
    $filters = @()
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) { $filters += "serviceName eq $(New-ODataStringLiteral $ServiceName)" }
    if (-not [string]::IsNullOrWhiteSpace($MeterName)) { $filters += "meterName eq $(New-ODataStringLiteral $MeterName)" }
    if (-not [string]::IsNullOrWhiteSpace($ArmRegionName)) { $filters += "armRegionName eq $(New-ODataStringLiteral $ArmRegionName)" }
    if (-not [string]::IsNullOrWhiteSpace($UnitOfMeasure)) { $filters += "unitOfMeasure eq $(New-ODataStringLiteral $UnitOfMeasure)" }
    if ($filters.Count -eq 0) { $Cache[$cacheKey] = @(); return @() }
    $filter = $filters -join " and "
    $url = "https://prices.azure.com/api/retail/prices?`$filter=$([uri]::EscapeDataString($filter))"
    $items = @()
    do {
        $response = Invoke-RestMethodWithRetry -Uri $url -Method Get
        $items += @($response.Items)
        $url = $response.NextPageLink
    } while ($url)
    $Cache[$cacheKey] = @($items)
    return @($items)
}

function Select-BestRetailPriceMatch {
    param([object]$CostRow, [object[]]$Candidates)
    if (-not $Candidates -or $Candidates.Count -eq 0) {
        return [pscustomobject]@{ MatchStatus = "NoMatch"; CandidateCount = 0; Item = $null }
    }
    $costProduct = ([string]$CostRow.Product).ToLowerInvariant()
    $ranked = @($Candidates | ForEach-Object {
        $score = 0
        if ($costProduct -and $_.productName -and $costProduct.Contains(([string]$_.productName).ToLowerInvariant())) { $score += 10 }
        if ($costProduct -and $_.skuName -and $costProduct.Contains(([string]$_.skuName).ToLowerInvariant())) { $score += 5 }
        [pscustomobject]@{ Score = $score; Item = $_ }
    } | Sort-Object Score -Descending)
    $bestScore = $ranked[0].Score
    $bestItems = @($ranked | Where-Object Score -eq $bestScore | ForEach-Object { $_.Item })
    $uniqueSkuIds = @($bestItems | Select-Object -ExpandProperty skuId -Unique)
    $uniqueMeterIds = @($bestItems | Select-Object -ExpandProperty meterId -Unique)
    $status = if ($bestItems.Count -eq 1 -or ($uniqueSkuIds.Count -eq 1 -and $uniqueMeterIds.Count -eq 1)) { "Matched" } else { "MultipleCandidates" }
    return [pscustomobject]@{ MatchStatus = $status; CandidateCount = $Candidates.Count; Item = ($bestItems | Select-Object -First 1) }
}

$cache = @{}
foreach ($prefix in @("mtd", "last-month", "custom")) {
    $sourcePath = Join-Path $OutputDir "$prefix-cost-by-retail-join.csv"
    if (-not (Test-Path $sourcePath)) { continue }

    $rows = @(Import-Csv $sourcePath)
    $withRegion = @($rows | ForEach-Object {
        $armRegionName = ConvertTo-FinOpsCanonicalArmRegionName $_.ResourceLocation
        $_ | Add-Member -NotePropertyName ArmRegionName -NotePropertyValue $armRegionName -Force
        $_
    })
    $withRegionPath = Join-Path $OutputDir "$prefix-cost-by-retail-join-with-arm-region.csv"
    $withRegion | Export-Csv -Path $withRegionPath -NoTypeInformation -Encoding UTF8

    $index = 0
    $total = $withRegion.Count
    $enriched = @($withRegion | ForEach-Object {
        $index++
        if (($index % 25) -eq 0 -or $index -eq 1 -or $index -eq $total) {
            Write-Host "Native Retail Prices lookup progress for $prefix`: $index / $total"
        }
        $candidates = Get-RetailPriceCandidates -ServiceName $_.ServiceName -MeterName $_.Meter -ArmRegionName $_.ArmRegionName -UnitOfMeasure $_.UnitOfMeasure -Cache $cache
        $match = Select-BestRetailPriceMatch -CostRow $_ -Candidates $candidates
        $item = $match.Item
        $_ | Add-Member -NotePropertyName RetailMatchStatus -NotePropertyValue $match.MatchStatus -Force
        $_ | Add-Member -NotePropertyName RetailCandidateCount -NotePropertyValue $match.CandidateCount -Force
        $_ | Add-Member -NotePropertyName RetailSkuId -NotePropertyValue $(if ($item) { $item.skuId } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailMeterId -NotePropertyValue $(if ($item) { $item.meterId } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailProductId -NotePropertyValue $(if ($item) { $item.productId } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailProductName -NotePropertyValue $(if ($item) { $item.productName } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailSkuName -NotePropertyValue $(if ($item) { $item.skuName } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailMeterName -NotePropertyValue $(if ($item) { $item.meterName } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailArmRegionName -NotePropertyValue $(if ($item) { $item.armRegionName } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailUnitOfMeasure -NotePropertyValue $(if ($item) { $item.unitOfMeasure } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailPrice -NotePropertyValue $(if ($item) { $item.retailPrice } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailUnitPrice -NotePropertyValue $(if ($item) { $item.unitPrice } else { $null }) -Force
        $_ | Add-Member -NotePropertyName RetailCurrencyCode -NotePropertyValue $(if ($item) { $item.currencyCode } else { $null }) -Force
        $_
    })
    $enrichedPath = Join-Path $OutputDir "$prefix-cost-by-retail-join-enriched.csv"
    $enriched | Export-Csv -Path $enrichedPath -NoTypeInformation -Encoding UTF8
}
