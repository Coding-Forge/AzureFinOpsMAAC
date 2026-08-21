<#
.SYNOPSIS
Builds durable history files from native Cost Management and Billing exports.

.DESCRIPTION
The native extraction path writes raw Cost Management CSVs and billing audit CSVs
without using the legacy Azure CLI enrichment pipeline. This script creates the
core normalized cost files and upserts durable history files so Azure SQL loading
can run after native extraction.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputRoot,

    [Parameter(Mandatory)]
    [string]$HistoryRoot,

    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = "AzureCloud",

    [string]$TenantId,

    [datetime]$AsOfDate = (Get-Date)
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

function Get-AzureCloudDisplayName {
    param([string]$CloudName)
    switch ($CloudName) {
        "AzureCloud" { "Azure Commercial" }
        "AzureUSGovernment" { "Azure Government" }
        "AzureChinaCloud" { "Azure China (21Vianet)" }
        default { $CloudName }
    }
}

function New-FinOpsMeterKey {
    param([string]$ServiceName, [string]$Meter, [string]$Product, [string]$PartNumber, [string]$UnitOfMeasure)
    return @($ServiceName, $Meter, $Product, $PartNumber, $UnitOfMeasure) -join "|"
}

function ConvertTo-FinOpsDecimal {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 0D }
    $parsed = 0D
    if ([decimal]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return 0D
}

function Export-FinOpsCsv {
    param([string]$Path, [string[]]$Columns, [object[]]$Rows = @())
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $rowsToWrite = @($Rows | Where-Object { $null -ne $_ })
    if ($rowsToWrite.Count -eq 0) {
        Set-Content -Path $Path -Value (($Columns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ",") -Encoding UTF8
        return
    }
    $rowsToWrite | Select-Object $Columns | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Get-HistoryMonth {
    param([string]$UsageDate)
    if ($UsageDate -and $UsageDate.Length -ge 6) { return "$($UsageDate.Substring(0, 4))-$($UsageDate.Substring(4, 2))" }
    return ""
}

function Add-HistoryMetadata {
    param([object[]]$Rows, [string]$RunId, [string]$ExportedUtc)
    foreach ($row in $Rows) {
        if (-not ($row.PSObject.Properties.Name -contains "ExportRunId")) { $row | Add-Member -NotePropertyName ExportRunId -NotePropertyValue $RunId -Force }
        if (-not ($row.PSObject.Properties.Name -contains "ExportedUtc")) { $row | Add-Member -NotePropertyName ExportedUtc -NotePropertyValue $ExportedUtc -Force }
        if (-not ($row.PSObject.Properties.Name -contains "TenantId")) { $row | Add-Member -NotePropertyName TenantId -NotePropertyValue $TenantId -Force }
        if (-not ($row.PSObject.Properties.Name -contains "AzureCloud")) { $row | Add-Member -NotePropertyName AzureCloud -NotePropertyValue $AzureCloud -Force }
        $row
    }
}

function Get-ReplaceKey {
    param([object]$Row, [string[]]$Columns)
    return (($Columns | ForEach-Object { if ($Row.PSObject.Properties.Name -contains $_) { [string]$Row.PSObject.Properties[$_].Value } else { "" } }) -join "|")
}

function Update-HistoryFile {
    param([string]$CurrentPath, [string]$HistoryFileName, [string[]]$KeyColumns)
    if (-not (Test-Path $CurrentPath)) { return }
    $historyPath = Join-Path $HistoryRoot $HistoryFileName
    $newRows = @(Import-Csv $CurrentPath)
    $newRows = @(Add-HistoryMetadata -Rows $newRows -RunId $runId -ExportedUtc $exportedUtc)
    $existingRows = if (Test-Path $historyPath) { @(Import-Csv $historyPath) } else { @() }
    $replaceKeys = @{}
    foreach ($row in $newRows) { $replaceKeys[(Get-ReplaceKey -Row $row -Columns $KeyColumns)] = $true }
    $keptRows = @($existingRows | Where-Object { -not $replaceKeys.ContainsKey((Get-ReplaceKey -Row $_ -Columns $KeyColumns)) })
    @($keptRows + $newRows) | Export-Csv -Path $historyPath -NoTypeInformation -Encoding UTF8
    Copy-Item -Path $historyPath -Destination (Join-Path $OutputRoot $HistoryFileName) -Force
    Write-Host "Updated durable history: $historyPath"
}

New-Item -ItemType Directory -Path $HistoryRoot -Force | Out-Null
$runId = Split-Path -Leaf $OutputRoot
$exportedUtc = (Get-Date).ToUniversalTime().ToString("o")
$cloudDisplay = Get-AzureCloudDisplayName $AzureCloud

$periods = @("mtd", "last-month", "custom")
$factRows = @()
foreach ($prefix in $periods) {
    $sourcePath = Join-Path $OutputRoot "$prefix-cost-by-retail-join.csv"
    if (-not (Test-Path $sourcePath)) { continue }
    $periodLabel = switch ($prefix) { "mtd" { "MTD" } "last-month" { "Last Month" } default { "Custom" } }
    $factRows += @(Import-Csv $sourcePath | ForEach-Object {
        $armRegionName = ConvertTo-FinOpsCanonicalArmRegionName $_.ResourceLocation
        [pscustomobject][ordered]@{
            Period = $periodLabel
            AzureCloud = $AzureCloud
            SubscriptionId = $_.SubscriptionId
            SubscriptionName = $_.SubscriptionName
            UsageDate = $_.UsageDate
            ServiceName = $_.ServiceName
            ResourceLocation = $_.ResourceLocation
            ArmRegionName = $armRegionName
            MeterKey = New-FinOpsMeterKey -ServiceName $_.ServiceName -Meter $_.Meter -Product $_.Product -PartNumber $_.PartNumber -UnitOfMeasure $_.UnitOfMeasure
            Meter = $_.Meter
            Product = $_.Product
            PartNumber = $_.PartNumber
            UnitOfMeasure = $_.UnitOfMeasure
            Currency = $_.Currency
            UsageQuantity = $_.UsageQuantity
            Cost = $_.Cost
        }
    })
}

$factPath = Join-Path $OutputRoot "fact-cost-usage.csv"
Export-FinOpsCsv -Path $factPath -Columns @("Period","AzureCloud","SubscriptionId","SubscriptionName","UsageDate","ServiceName","ResourceLocation","ArmRegionName","MeterKey","Meter","Product","PartNumber","UnitOfMeasure","Currency","UsageQuantity","Cost") -Rows $factRows

$cloudRows = @([pscustomobject]@{ AzureCloud = $AzureCloud; "Azure Cloud" = $cloudDisplay })
Export-FinOpsCsv -Path (Join-Path $OutputRoot "dim-azure-cloud.csv") -Columns @("AzureCloud","Azure Cloud") -Rows $cloudRows

$subscriptionRows = @($factRows | Where-Object SubscriptionId | Group-Object SubscriptionId | ForEach-Object {
    $first = $_.Group | Select-Object -First 1
    [pscustomobject]@{ AzureCloud = $first.AzureCloud; SubscriptionId = $first.SubscriptionId; SubscriptionName = $first.SubscriptionName }
})
Export-FinOpsCsv -Path (Join-Path $OutputRoot "dim-subscription.csv") -Columns @("AzureCloud","SubscriptionId","SubscriptionName") -Rows $subscriptionRows

$serviceRows = @($factRows | Where-Object ServiceName | Select-Object ServiceName -Unique | Sort-Object ServiceName)
Export-FinOpsCsv -Path (Join-Path $OutputRoot "dim-service.csv") -Columns @("ServiceName") -Rows $serviceRows

$regionRows = @($factRows | Where-Object ArmRegionName | Group-Object ArmRegionName | ForEach-Object {
    $first = $_.Group | Select-Object -First 1
    [pscustomobject][ordered]@{
        "Display Name" = if ($first.ResourceLocation) { (Get-Culture).TextInfo.ToTitleCase(([string]$first.ResourceLocation).ToLowerInvariant()) } else { $first.ArmRegionName }
        "Azure Region" = $first.ArmRegionName
        "Azure Cloud" = $cloudDisplay
        ArmRegionName = $first.ArmRegionName
        ResourceLocation = $first.ResourceLocation
    }
})
Export-FinOpsCsv -Path (Join-Path $OutputRoot "dim-region.csv") -Columns @("Display Name","Azure Region","Azure Cloud","ArmRegionName","ResourceLocation") -Rows $regionRows

$meterRows = @($factRows | Where-Object MeterKey | Group-Object MeterKey | ForEach-Object {
    $first = $_.Group | Select-Object -First 1
    [pscustomobject]@{ MeterKey = $first.MeterKey; ServiceName = $first.ServiceName; Meter = $first.Meter; Product = $first.Product; PartNumber = $first.PartNumber; UnitOfMeasure = $first.UnitOfMeasure }
})
Export-FinOpsCsv -Path (Join-Path $OutputRoot "dim-meter.csv") -Columns @("MeterKey","ServiceName","Meter","Product","PartNumber","UnitOfMeasure") -Rows $meterRows

$retailRows = @()
foreach ($prefix in $periods) {
    $enrichedPath = Join-Path $OutputRoot "$prefix-cost-by-retail-join-enriched.csv"
    if (-not (Test-Path $enrichedPath)) { continue }
    $periodLabel = switch ($prefix) { "mtd" { "MTD" } "last-month" { "Last Month" } default { "Custom" } }
    $retailRows += @(Import-Csv $enrichedPath | ForEach-Object {
        $armRegionName = ConvertTo-FinOpsCanonicalArmRegionName $_.ArmRegionName
        $retailArmRegionName = ConvertTo-FinOpsCanonicalArmRegionName $_.RetailArmRegionName
        $retailSkuKey = @($_.RetailSkuId, $_.RetailMeterId, $retailArmRegionName, $_.RetailUnitOfMeasure) -join "|"
        [pscustomobject][ordered]@{
            Period = $periodLabel
            AzureCloud = $AzureCloud
            SubscriptionId = $_.SubscriptionId
            UsageDate = $_.UsageDate
            ServiceName = $_.ServiceName
            ArmRegionName = $armRegionName
            MeterKey = New-FinOpsMeterKey -ServiceName $_.ServiceName -Meter $_.Meter -Product $_.Product -PartNumber $_.PartNumber -UnitOfMeasure $_.UnitOfMeasure
            Currency = $_.Currency
            UsageQuantity = $_.UsageQuantity
            Cost = $_.Cost
            RetailSkuKey = $retailSkuKey
            RetailMatchStatus = $_.RetailMatchStatus
            RetailCandidateCount = $_.RetailCandidateCount
            RetailSkuId = $_.RetailSkuId
            RetailMeterId = $_.RetailMeterId
            RetailProductId = $_.RetailProductId
            RetailArmRegionName = $retailArmRegionName
            RetailUnitOfMeasure = $_.RetailUnitOfMeasure
            RetailPrice = $_.RetailPrice
            RetailUnitPrice = $_.RetailUnitPrice
            RetailCurrencyCode = $_.RetailCurrencyCode
        }
    })
}

$retailMatchPath = Join-Path $OutputRoot "fact-retail-price-match.csv"
Export-FinOpsCsv -Path $retailMatchPath -Columns @("Period","AzureCloud","SubscriptionId","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency","UsageQuantity","Cost","RetailSkuKey","RetailMatchStatus","RetailCandidateCount","RetailSkuId","RetailMeterId","RetailProductId","RetailArmRegionName","RetailUnitOfMeasure","RetailPrice","RetailUnitPrice","RetailCurrencyCode") -Rows $retailRows

$retailSkuRows = @($retailRows | Where-Object RetailSkuKey | Group-Object RetailSkuKey | ForEach-Object {
    $first = $_.Group | Select-Object -First 1
    [pscustomobject]@{
        RetailSkuKey = $first.RetailSkuKey
        RetailSkuId = $first.RetailSkuId
        RetailMeterId = $first.RetailMeterId
        RetailProductId = $first.RetailProductId
        RetailArmRegionName = $first.RetailArmRegionName
        RetailUnitOfMeasure = $first.RetailUnitOfMeasure
        RetailPrice = $first.RetailPrice
        RetailUnitPrice = $first.RetailUnitPrice
        RetailCurrencyCode = $first.RetailCurrencyCode
    }
})
Export-FinOpsCsv -Path (Join-Path $OutputRoot "dim-retail-sku.csv") -Columns @("RetailSkuKey","RetailSkuId","RetailMeterId","RetailProductId","RetailArmRegionName","RetailUnitOfMeasure","RetailPrice","RetailUnitPrice","RetailCurrencyCode") -Rows $retailSkuRows

$historyRows = @($factRows | ForEach-Object {
    $row = [ordered]@{
        HistoryMonth = Get-HistoryMonth $_.UsageDate
        ExportRunId = $runId
        ExportedUtc = $exportedUtc
        TenantId = $TenantId
    }
    foreach ($property in $_.PSObject.Properties) { $row[$property.Name] = $property.Value }
    [pscustomobject]$row
})
$historyFactPath = Join-Path $OutputRoot "fact-cost-usage-history.csv"
Export-FinOpsCsv -Path $historyFactPath -Columns @("HistoryMonth","ExportRunId","ExportedUtc","TenantId","Period","AzureCloud","SubscriptionId","SubscriptionName","UsageDate","ServiceName","ResourceLocation","ArmRegionName","MeterKey","Meter","Product","PartNumber","UnitOfMeasure","Currency","UsageQuantity","Cost") -Rows $historyRows
Update-HistoryFile -CurrentPath $historyFactPath -HistoryFileName "fact-cost-usage-history.csv" -KeyColumns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period")

$retailHistoryRows = @($retailRows | ForEach-Object {
    $row = [ordered]@{
        HistoryMonth = Get-HistoryMonth $_.UsageDate
        ExportRunId = $runId
        ExportedUtc = $exportedUtc
        TenantId = $TenantId
    }
    foreach ($property in $_.PSObject.Properties) { $row[$property.Name] = $property.Value }
    [pscustomobject]$row
})
$retailHistoryPath = Join-Path $OutputRoot "fact-retail-price-match-history.csv"
Export-FinOpsCsv -Path $retailHistoryPath -Columns @("HistoryMonth","ExportRunId","ExportedUtc","TenantId","Period","AzureCloud","SubscriptionId","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency","UsageQuantity","Cost","RetailSkuKey","RetailMatchStatus","RetailCandidateCount","RetailSkuId","RetailMeterId","RetailProductId","RetailArmRegionName","RetailUnitOfMeasure","RetailPrice","RetailUnitPrice","RetailCurrencyCode") -Rows $retailHistoryRows
Update-HistoryFile -CurrentPath $retailHistoryPath -HistoryFileName "fact-retail-price-match-history.csv" -KeyColumns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period")

# CostRetailFact / cost-retail-history.csv: full cost-vs-retail detail (RetailEquivalentCost, EstimatedSavings)
# built directly from the enriched retail-join CSVs so the SQL-loaded finops.CostRetailFact table is populated
# by the serverless/native pipeline the same way the legacy GUI (Start-FinOpsDataPull.ps1) does.
$costRetailRows = @()
foreach ($prefix in $periods) {
    $enrichedPath = Join-Path $OutputRoot "$prefix-cost-by-retail-join-enriched.csv"
    if (-not (Test-Path $enrichedPath)) { continue }
    $periodLabel = switch ($prefix) { "mtd" { "MTD" } "last-month" { "Last Month" } default { "Custom" } }
    $costRetailRows += @(Import-Csv $enrichedPath | ForEach-Object {
        $armRegionName = ConvertTo-FinOpsCanonicalArmRegionName $_.ArmRegionName
        $retailArmRegionName = ConvertTo-FinOpsCanonicalArmRegionName $_.RetailArmRegionName
        $usageText = [string]$_.UsageDate
        $historyMonth = if ($usageText.Length -ge 6) { "$($usageText.Substring(0, 4))-$($usageText.Substring(4, 2))" } else { "" }
        $cost = ConvertTo-FinOpsDecimal $_.Cost
        $quantity = ConvertTo-FinOpsDecimal $_.UsageQuantity
        $retailPrice = ConvertTo-FinOpsDecimal $_.RetailPrice
        $retailEquivalent = if ($retailPrice -gt 0 -and $quantity -ne 0) { [math]::Round($quantity * $retailPrice, 6) } else { 0D }
        $estimatedSavings = $retailEquivalent - $cost
        [pscustomobject][ordered]@{
            HistoryMonth = $historyMonth
            Period = $periodLabel
            ExportRunId = $runId
            ExportedUtc = $exportedUtc
            AzureCloud = $AzureCloud
            TenantId = $TenantId
            SubscriptionName = $_.SubscriptionName
            SubscriptionId = $_.SubscriptionId
            UsageQuantity = $_.UsageQuantity
            Cost = $_.Cost
            UsageDate = $_.UsageDate
            ServiceName = $_.ServiceName
            ResourceLocation = $_.ResourceLocation
            ArmRegionName = $armRegionName
            Meter = $_.Meter
            Product = $_.Product
            PartNumber = $_.PartNumber
            UnitOfMeasure = $_.UnitOfMeasure
            Currency = $_.Currency
            RetailMatchStatus = $_.RetailMatchStatus
            RetailCandidateCount = $_.RetailCandidateCount
            RetailSkuId = $_.RetailSkuId
            RetailMeterId = $_.RetailMeterId
            RetailProductId = $_.RetailProductId
            RetailProductName = $_.RetailProductName
            RetailSkuName = $_.RetailSkuName
            RetailMeterName = $_.RetailMeterName
            RetailArmRegionName = $retailArmRegionName
            RetailUnitOfMeasure = $_.RetailUnitOfMeasure
            RetailPrice = $_.RetailPrice
            RetailUnitPrice = $_.RetailUnitPrice
            RetailCurrencyCode = $_.RetailCurrencyCode
            RetailEquivalentCost = [math]::Round([decimal]$retailEquivalent, 4)
            EstimatedSavings = [math]::Round([decimal]$estimatedSavings, 4)
        }
    })
}

$costRetailHistoryPath = Join-Path $HistoryRoot "cost-retail-history.csv"
$costRetailColumns = @("HistoryMonth","Period","ExportRunId","ExportedUtc","AzureCloud","TenantId","SubscriptionName","SubscriptionId","UsageQuantity","Cost","UsageDate","ServiceName","ResourceLocation","ArmRegionName","Meter","Product","PartNumber","UnitOfMeasure","Currency","RetailMatchStatus","RetailCandidateCount","RetailSkuId","RetailMeterId","RetailProductId","RetailProductName","RetailSkuName","RetailMeterName","RetailArmRegionName","RetailUnitOfMeasure","RetailPrice","RetailUnitPrice","RetailCurrencyCode","RetailEquivalentCost","EstimatedSavings")
$existingCostRetailRows = if (Test-Path $costRetailHistoryPath) { @(Import-Csv $costRetailHistoryPath) } else { @() }
$costRetailReplaceKeys = @{}
foreach ($row in $costRetailRows) { $costRetailReplaceKeys[(Get-ReplaceKey -Row $row -Columns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period"))] = $true }
$keptCostRetailRows = @($existingCostRetailRows | Where-Object { -not $costRetailReplaceKeys.ContainsKey((Get-ReplaceKey -Row $_ -Columns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period"))) })
Export-FinOpsCsv -Path $costRetailHistoryPath -Columns $costRetailColumns -Rows (@($keptCostRetailRows) + @($costRetailRows))
Copy-Item -Path $costRetailHistoryPath -Destination (Join-Path $OutputRoot "cost-retail-history.csv") -Force
Write-Host "Updated durable history: $costRetailHistoryPath"

$manifestRows = @([pscustomobject]@{
    ExportRunId = $runId
    ExportedUtc = $exportedUtc
    AnalysisMode = "History"
    StorageLocation = "Local"
    TenantId = $TenantId
    SubscriptionCount = @($subscriptionRows).Count
    AsOfDate = $AsOfDate.ToString("yyyy-MM-dd")
    AgreementId = if ($env:FINOPS_AGREEMENT_ID) { $env:FINOPS_AGREEMENT_ID } else { "MACC-Agreement" }
    SettingsPath = ""
    OutputRoot = $OutputRoot
    HistoryRoot = $HistoryRoot
    FileCount = @(Get-ChildItem -Path $OutputRoot -File -ErrorAction SilentlyContinue).Count
    ActualCost = [math]::Round([decimal](($factRows | Measure-Object -Property Cost -Sum).Sum), 4)
    RetailEquivalentCost = ""
    EstimatedSavings = ""
    CalculationVersion = "native-cost-v1"
    AzureCloud = $AzureCloud
})
Export-FinOpsCsv -Path (Join-Path $OutputRoot "export-run-manifest.csv") -Columns @("ExportRunId","ExportedUtc","AnalysisMode","StorageLocation","TenantId","SubscriptionCount","AsOfDate","AgreementId","SettingsPath","OutputRoot","HistoryRoot","FileCount","ActualCost","RetailEquivalentCost","EstimatedSavings","CalculationVersion","AzureCloud") -Rows $manifestRows
Update-HistoryFile -CurrentPath (Join-Path $OutputRoot "export-run-manifest.csv") -HistoryFileName "export-run-manifest-history.csv" -KeyColumns @("ExportRunId")

$billingRoot = Join-Path $OutputRoot "billing-contact-audit"
if (Test-Path $billingRoot) {
    Update-HistoryFile -CurrentPath (Join-Path $billingRoot "subscription-billing-properties.csv") -HistoryFileName "billing-subscription-properties-history.csv" -KeyColumns @("AzureCloud","TenantId","SubscriptionId")
    Update-HistoryFile -CurrentPath (Join-Path $billingRoot "billing-accounts.csv") -HistoryFileName "billing-accounts-history.csv" -KeyColumns @("AzureCloud","TenantId","BillingAccountName")
    Update-HistoryFile -CurrentPath (Join-Path $billingRoot "billing-profiles.csv") -HistoryFileName "billing-profiles-history.csv" -KeyColumns @("AzureCloud","TenantId","BillingProfileName","BillingAccountName")
    Update-HistoryFile -CurrentPath (Join-Path $billingRoot "invoice-sections.csv") -HistoryFileName "billing-invoice-sections-history.csv" -KeyColumns @("AzureCloud","TenantId","InvoiceSectionName","BillingProfileName","BillingAccountName")
    Update-HistoryFile -CurrentPath (Join-Path $billingRoot "invoices.csv") -HistoryFileName "billing-invoices-history.csv" -KeyColumns @("AzureCloud","TenantId","InvoiceName","BillingAccountName","BillingProfileName")
    Update-HistoryFile -CurrentPath (Join-Path $billingRoot "billing-role-assignments.csv") -HistoryFileName "billing-role-assignments-history.csv" -KeyColumns @("AzureCloud","TenantId","Scope","PrincipalId","RoleDefinitionId")
}

Update-HistoryFile -CurrentPath (Join-Path $OutputRoot "agreement-price-audit.csv") -HistoryFileName "agreement-price-audit-history.csv" -KeyColumns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","Meter","Product","PartNumber","UnitOfMeasure")
Update-HistoryFile -CurrentPath (Join-Path $OutputRoot "retail-price-snapshot.csv") -HistoryFileName "retail-price-snapshot-history.csv" -KeyColumns @("AzureCloud","TenantId","RetailSkuId","RetailMeterId","RetailArmRegionName","RetailUnitOfMeasure")
Update-HistoryFile -CurrentPath (Join-Path $OutputRoot "retail-match-exceptions.csv") -HistoryFileName "retail-match-exceptions-history.csv" -KeyColumns @("AzureCloud","TenantId","ExceptionId")
Update-HistoryFile -CurrentPath (Join-Path $OutputRoot "data-quality-snapshot.csv") -HistoryFileName "data-quality-snapshot-history.csv" -KeyColumns @("AzureCloud","TenantId","AgreementId","Period","Currency")
Update-HistoryFile -CurrentPath (Join-Path $OutputRoot "billing-reconciliation.csv") -HistoryFileName "billing-reconciliation-history.csv" -KeyColumns @("AzureCloud","TenantId","AgreementId","BillingPeriod")

Write-Host "Native durable history updated from: $OutputRoot"
