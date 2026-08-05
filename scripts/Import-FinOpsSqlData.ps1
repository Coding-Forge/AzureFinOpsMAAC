<#
.SYNOPSIS
Loads durable FinOps history CSV files into the Azure SQL durable store.

.DESCRIPTION
Uses the current Azure CLI sign-in to request an Entra ID token for Azure SQL Database,
derives dimension rows from durable history CSV files, and bulk-loads the finops schema.

Use -Replace for a full reload from the durable CSV history store.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerName,

    [string]$DatabaseName = "FinOpsMaccRetail",

    [string]$SchemaName = "finops",

    [string]$HistoryRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\history"),

    [string]$CurrentRunRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\latest-run"),

    [switch]$Replace
)

$ErrorActionPreference = "Stop"

function Get-AzureSqlAccessToken {
    $token = az account get-access-token --resource "https://database.windows.net/" --query accessToken --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not get Azure SQL access token from Azure CLI. Run az login first. Details: $token"
    }

    return [string]$token
}

function New-SqlConnection {
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $connectionString = "Server=tcp:$ServerName,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $connection.AccessToken = $AccessToken
    $connection.Open()
    return $connection
}

function Invoke-SqlNonQuery {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$Sql
    )

    $command = $Connection.CreateCommand()
    $command.CommandTimeout = 300
    $command.CommandText = $Sql
    [void]$command.ExecuteNonQuery()
}

function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$Sql
    )

    $command = $Connection.CreateCommand()
    $command.CommandTimeout = 300
    $command.CommandText = $Sql
    $table = New-Object System.Data.DataTable
    $table.Load($command.ExecuteReader())
    return ,$table
}

function Quote-SqlName {
    param([Parameter(Mandatory)][string]$Name)
    return "[" + ($Name -replace "]", "]]") + "]"
}

function New-SqlStringLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return "NULL"
    }

    return "N'" + ($Value -replace "'", "''") + "'"
}

function Read-CsvSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) {
        return @(Import-Csv -Path $Path)
    }

    return @()
}

function Get-CloudDisplayName {
    param([AllowNull()][string]$AzureCloud)
    switch ($AzureCloud) {
        "AzureCloud" { return "Azure Commercial" }
        "AzureUSGovernment" { return "Azure Government" }
        "AzureChinaCloud" { return "Azure China (21Vianet)" }
        "AzureGermanCloud" { return "Azure Germany" }
        default {
            if ([string]::IsNullOrWhiteSpace($AzureCloud)) { return "" }
            return $AzureCloud
        }
    }
}

function Get-UsageDateAsDate {
    param([AllowNull()][string]$UsageDate)
    if ([string]::IsNullOrWhiteSpace($UsageDate) -or $UsageDate.Length -lt 8) {
        return $null
    }

    try {
        return [datetime]::ParseExact($UsageDate.Substring(0, 8), "yyyyMMdd", [Globalization.CultureInfo]::InvariantCulture).Date
    }
    catch {
        return $null
    }
}

function Get-AzureRegionKey {
    param(
        [AllowNull()][string]$AzureCloud,
        [AllowNull()][string]$ArmRegionName
    )

    return "$(Get-CloudDisplayName $AzureCloud)|$([string]$ArmRegionName)"
}

function ConvertTo-NullableDecimal {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [DBNull]::Value
    }

    $parsed = 0D
    if ([decimal]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }

    return [DBNull]::Value
}

function ConvertTo-NullableInt {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [DBNull]::Value
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return [DBNull]::Value
}

function ConvertTo-NullableDateTime {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [DBNull]::Value
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed
    }

    return [DBNull]::Value
}

function ConvertTo-NullableDate {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [DBNull]::Value
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.Date
    }

    return [DBNull]::Value
}

function Get-RowValue {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Row.PSObject.Properties.Name -contains $Name) {
        return $Row.PSObject.Properties[$Name].Value
    }

    return $null
}

function New-ObjectRows {
    param([object[]]$Rows)
    return @($Rows | Where-Object { $null -ne $_ })
}

function Select-DistinctRows {
    param(
        [object[]]$Rows,
        [string[]]$KeyColumns
    )

    $seen = @{}
    foreach ($row in $Rows) {
        $key = ($KeyColumns | ForEach-Object { [string](Get-RowValue -Row $row -Name $_) }) -join "|"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $row
        }
    }
}

function Get-TableColumnSchema {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$SchemaName,
        [Parameter(Mandatory)][string]$TableName
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = @"
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = @schemaName
  AND TABLE_NAME = @tableName
  AND COLUMN_NAME <> 'LoadedUtc'
ORDER BY ORDINAL_POSITION;
"@
    [void]$command.Parameters.Add("@schemaName", [System.Data.SqlDbType]::NVarChar, 128)
    $command.Parameters["@schemaName"].Value = $SchemaName
    [void]$command.Parameters.Add("@tableName", [System.Data.SqlDbType]::NVarChar, 128)
    $command.Parameters["@tableName"].Value = $TableName

    $schema = New-Object System.Data.DataTable
    $schema.Load($command.ExecuteReader())
    return ,$schema
}

function Convert-ForSqlColumn {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$DataType,
        [Parameter(Mandatory)][string]$Nullable
    )

    if ($DataType -in @("decimal", "numeric", "money", "smallmoney", "float", "real")) {
        return ConvertTo-NullableDecimal $Value
    }
    if ($DataType -in @("int", "bigint", "smallint", "tinyint")) {
        return ConvertTo-NullableInt $Value
    }
    if ($DataType -in @("datetime", "datetime2", "smalldatetime")) {
        return ConvertTo-NullableDateTime $Value
    }
    if ($DataType -eq "date") {
        return ConvertTo-NullableDate $Value
    }
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        if ($Nullable -eq "NO") {
            return ""
        }
        return [DBNull]::Value
    }

    return [string]$Value
}

function Write-SqlTable {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$SchemaName,
        [Parameter(Mandatory)][string]$TableName,
        [object[]]$Rows = @(),
        [string[]]$KeyColumns = @(),
        [string[]]$ReplacePartitionColumns = @(),
        [switch]$AppendOnly
    )

    $Rows = @($Rows | Where-Object { $null -ne $_ })
    $KeyColumns = @($KeyColumns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $ReplacePartitionColumns = @($ReplacePartitionColumns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $schema = Get-TableColumnSchema -Connection $Connection -SchemaName $SchemaName -TableName $TableName
    $dataTable = New-Object System.Data.DataTable
    $schemaRows = @($schema.Select())
    foreach ($column in $schemaRows) {
        [void]$dataTable.Columns.Add([string]$column.Item("COLUMN_NAME"))
    }

    foreach ($row in $Rows) {
        $dataRow = $dataTable.NewRow()
        foreach ($column in $schemaRows) {
            $name = [string]$column.Item("COLUMN_NAME")
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw "SQL metadata returned a blank column name for $SchemaName.$TableName."
            }
            $dataRow[$name] = Convert-ForSqlColumn -Value (Get-RowValue -Row $row -Name $name) -DataType ([string]$column.Item("DATA_TYPE")) -Nullable ([string]$column.Item("IS_NULLABLE"))
        }
        [void]$dataTable.Rows.Add($dataRow)
    }

    if ($dataTable.Rows.Count -eq 0) {
        Write-Host "Skipping $SchemaName.$TableName (0 rows)"
        return
    }

    if ($Replace) {
        $bulkCopy = [System.Data.SqlClient.SqlBulkCopy]::new($Connection)
        $bulkCopy.DestinationTableName = "[$SchemaName].[$TableName]"
        $bulkCopy.BatchSize = 5000
        $bulkCopy.BulkCopyTimeout = 300
        try {
            foreach ($column in $schemaRows) {
                $name = [string]$column.Item("COLUMN_NAME")
                [void]$bulkCopy.ColumnMappings.Add($name, $name)
            }
            $bulkCopy.WriteToServer($dataTable)
            Write-Host "Loaded $($dataTable.Rows.Count) rows into $SchemaName.$TableName"
        }
        finally {
            $bulkCopy.Close()
        }
        return
    }

    $targetName = "$(Quote-SqlName $SchemaName).$(Quote-SqlName $TableName)"
    $tempName = "#Stage_$($TableName)_$([guid]::NewGuid().ToString('N'))"
    $columnNames = @($schemaRows | ForEach-Object { [string]$_.Item("COLUMN_NAME") })
    $columnList = ($columnNames | ForEach-Object { Quote-SqlName $_ }) -join ", "

    Invoke-SqlNonQuery -Connection $Connection -Sql "SELECT TOP (0) $columnList INTO $tempName FROM $targetName;"

    $bulkCopy = [System.Data.SqlClient.SqlBulkCopy]::new($Connection)
    $bulkCopy.DestinationTableName = $tempName
    $bulkCopy.BatchSize = 5000
    $bulkCopy.BulkCopyTimeout = 300
    try {
        foreach ($column in $schemaRows) {
            $name = [string]$column.Item("COLUMN_NAME")
            [void]$bulkCopy.ColumnMappings.Add($name, $name)
        }
        $bulkCopy.WriteToServer($dataTable)
    }
    finally {
        $bulkCopy.Close()
    }

    if ($AppendOnly) {
        Invoke-SqlNonQuery -Connection $Connection -Sql "INSERT INTO $targetName ($columnList) SELECT $columnList FROM $tempName;"
        Write-Host "Inserted $($dataTable.Rows.Count) rows into $SchemaName.$TableName"
        return
    }

    if ($KeyColumns.Count -gt 0) {
        $onClause = ($KeyColumns | ForEach-Object {
            $quoted = Quote-SqlName $_
            "((target.$quoted = source.$quoted) OR (target.$quoted IS NULL AND source.$quoted IS NULL))"
        }) -join " AND "

        $updateColumns = @($columnNames | Where-Object { $_ -notin $KeyColumns })
        $updateSet = ($updateColumns | ForEach-Object {
            $quoted = Quote-SqlName $_
            "target.$quoted = source.$quoted"
        }) -join ", "
        if (-not [string]::IsNullOrWhiteSpace($updateSet)) {
            $updateSet += ", target.[LoadedUtc] = SYSUTCDATETIME()"
        }
        else {
            $updateSet = "target.[LoadedUtc] = SYSUTCDATETIME()"
        }

        $mergeSql = @"
MERGE $targetName AS target
USING $tempName AS source
ON $onClause
WHEN MATCHED THEN UPDATE SET $updateSet
WHEN NOT MATCHED BY TARGET THEN
    INSERT ($columnList)
    VALUES ($(($columnNames | ForEach-Object { "source.$(Quote-SqlName $_)" }) -join ", "));
"@
        Invoke-SqlNonQuery -Connection $Connection -Sql $mergeSql
        Write-Host "Merged $($dataTable.Rows.Count) source rows into $SchemaName.$TableName"
        return
    }

    if ($ReplacePartitionColumns.Count -gt 0) {
        $partitionClause = ($ReplacePartitionColumns | ForEach-Object {
            $quoted = Quote-SqlName $_
            "((target.$quoted = source.$quoted) OR (target.$quoted IS NULL AND source.$quoted IS NULL))"
        }) -join " AND "
        Invoke-SqlNonQuery -Connection $Connection -Sql "DELETE target FROM $targetName AS target WHERE EXISTS (SELECT 1 FROM $tempName AS source WHERE $partitionClause); INSERT INTO $targetName ($columnList) SELECT $columnList FROM $tempName;"
        Write-Host "Replaced partitions with $($dataTable.Rows.Count) source rows in $SchemaName.$TableName"
        return
    }

    Invoke-SqlNonQuery -Connection $Connection -Sql "INSERT INTO $targetName ($columnList) SELECT $columnList FROM $tempName;"
    Write-Host "Inserted $($dataTable.Rows.Count) rows into $SchemaName.$TableName"
}

function Write-FinOpsOperationalSummary {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$SchemaName
    )

    $objectNameLiteral = New-SqlStringLiteral "$SchemaName.OperationalHealthSummary"
    $viewCheck = Invoke-SqlQuery -Connection $Connection -Sql "SELECT OBJECT_ID($objectNameLiteral, N'V') AS ObjectId;"
    $viewObjectId = if ($viewCheck.Rows.Count -gt 0) { $viewCheck.Rows[0].Item("ObjectId") } else { [DBNull]::Value }
    if ($viewObjectId -eq [DBNull]::Value -or $null -eq $viewObjectId) {
        Write-Warning "Operational monitoring views were not found in schema '$SchemaName'. Run Deploy-FinOpsSqlSchema.ps1 to create or update them."
        return
    }

    $healthSql = @"
SELECT
    CheckName,
    AzureCloudDisplayName,
    SubscriptionName,
    Status,
    LatestUsageDate,
    CostRowCount,
    RetailRowCount,
    RetailMatchPercent,
    HoursSinceLastRun,
    HoursSinceLastLoad
FROM $(Quote-SqlName $SchemaName).[OperationalHealthSummary]
WHERE Status <> N'Healthy'
ORDER BY
    CASE
        WHEN Status IN (N'Stale', N'NoCostRows', N'RetailCoverageAtRisk') THEN 0
        WHEN Status IN (N'MissingRetailMatch', N'RetailCoverageReview') THEN 1
        ELSE 2
    END,
    AzureCloudDisplayName,
    SubscriptionName;
"@
    $health = Invoke-SqlQuery -Connection $Connection -Sql $healthSql
    if ($health.Rows.Count -gt 0) {
        $healthText = $health | Format-Table -AutoSize | Out-String -Width 240
        Write-Host "`nOperational health warnings:`n$healthText"
    }
    else {
        Write-Host "Operational health summary: all monitored checks are Healthy."
    }

    $freshnessSql = @"
SELECT
    AzureCloudDisplayName,
    TenantId,
    LatestRunExportedUtc,
    LatestUsageDate,
    CostRowCount,
    SubscriptionCount,
    RetailMatchPercent,
    HoursSinceLastRun,
    FreshnessStatus
FROM $(Quote-SqlName $SchemaName).[IngestionFreshnessByCloud]
ORDER BY AzureCloudDisplayName, TenantId;
"@
    $freshness = Invoke-SqlQuery -Connection $Connection -Sql $freshnessSql
    if ($freshness.Rows.Count -gt 0) {
        $freshnessText = $freshness | Format-Table -AutoSize | Out-String -Width 240
        Write-Host "`nCloud freshness summary:`n$freshnessText"
    }
}

$paths = @{
    FactCostUsage = Join-Path $HistoryRoot "fact-cost-usage-history.csv"
    FactRetailPriceMatch = Join-Path $HistoryRoot "fact-retail-price-match-history.csv"
    CostRetailFact = Join-Path $HistoryRoot "cost-retail-history.csv"
    IngestionRun = Join-Path $HistoryRoot "export-run-manifest-history.csv"
    BillingSubscriptionProperties = Join-Path $HistoryRoot "billing-subscription-properties-history.csv"
    BillingAccount = Join-Path $HistoryRoot "billing-accounts-history.csv"
    BillingProfile = Join-Path $HistoryRoot "billing-profiles-history.csv"
    InvoiceSection = Join-Path $HistoryRoot "billing-invoice-sections-history.csv"
    BillingInvoice = Join-Path $HistoryRoot "billing-invoices-history.csv"
    BillingRoleAssignment = Join-Path $HistoryRoot "billing-role-assignments-history.csv"
    AgreementPriceAudit = Join-Path $HistoryRoot "agreement-price-audit-history.csv"
    DimAzureRegion = Join-Path $CurrentRunRoot "dim-region.csv"
}

$factCostUsage = @(Read-CsvSafe $paths.FactCostUsage)
$factRetailPriceMatch = @(Read-CsvSafe $paths.FactRetailPriceMatch)
$costRetailFact = @(Read-CsvSafe $paths.CostRetailFact)
$ingestionRun = @(Read-CsvSafe $paths.IngestionRun)
$billingSubscriptionProperties = @(Read-CsvSafe $paths.BillingSubscriptionProperties)
$billingAccount = @(Read-CsvSafe $paths.BillingAccount)
$billingProfile = @(Read-CsvSafe $paths.BillingProfile)
$invoiceSection = @(Read-CsvSafe $paths.InvoiceSection)
$billingInvoice = @(Read-CsvSafe $paths.BillingInvoice)
$billingRoleAssignment = @(Read-CsvSafe $paths.BillingRoleAssignment)
$agreementPriceAudit = @(Read-CsvSafe $paths.AgreementPriceAudit)

$allCloudValues = @(
    $factCostUsage | ForEach-Object AzureCloud
    $factRetailPriceMatch | ForEach-Object AzureCloud
    $costRetailFact | ForEach-Object AzureCloud
    "AzureCloud"
    "AzureUSGovernment"
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique

$dimAzureCloud = foreach ($cloud in $allCloudValues) {
    [pscustomobject]@{
        AzureCloud = [string]$cloud
        AzureCloudDisplayName = Get-CloudDisplayName ([string]$cloud)
    }
}

$dimAzureRegion = @()
foreach ($row in Read-CsvSafe $paths.DimAzureRegion) {
    $cloudDisplay = Get-RowValue -Row $row -Name "Azure Cloud"
    $armRegionName = Get-RowValue -Row $row -Name "ArmRegionName"
    if (-not [string]::IsNullOrWhiteSpace([string]$armRegionName)) {
        $dimAzureRegion += [pscustomobject]@{
            AzureRegionKey = "$cloudDisplay|$armRegionName"
            ArmRegionName = $armRegionName
            ResourceLocation = Get-RowValue -Row $row -Name "ResourceLocation"
            RegionDisplayName = Get-RowValue -Row $row -Name "Display Name"
            AzureRegionName = Get-RowValue -Row $row -Name "Azure Region"
            AzureCloudDisplayName = $cloudDisplay
        }
    }
}

$dimSubscription = Select-DistinctRows -Rows @(
    @($factCostUsage + $costRetailFact) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SubscriptionId) } |
        ForEach-Object {
            [pscustomobject]@{
                AzureCloud = $_.AzureCloud
                AzureCloudDisplayName = Get-CloudDisplayName $_.AzureCloud
                TenantId = if ($_.PSObject.Properties.Name -contains "TenantId") { $_.TenantId } else { "" }
                SubscriptionId = $_.SubscriptionId
                SubscriptionName = $_.SubscriptionName
            }
        }
) -KeyColumns @("AzureCloud","TenantId","SubscriptionId")

$dimService = Select-DistinctRows -Rows @(
    @($factCostUsage + $costRetailFact) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ServiceName) } |
        ForEach-Object { [pscustomobject]@{ ServiceName = $_.ServiceName } }
) -KeyColumns @("ServiceName")

$dimMeter = Select-DistinctRows -Rows @(
    $factCostUsage |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MeterKey) } |
        ForEach-Object {
            [pscustomobject]@{
                MeterKey = $_.MeterKey
                ServiceName = $_.ServiceName
                Meter = $_.Meter
                Product = $_.Product
                PartNumber = $_.PartNumber
                UnitOfMeasure = $_.UnitOfMeasure
            }
        }
) -KeyColumns @("MeterKey")

$dimRetailSku = Select-DistinctRows -Rows @(
    $factRetailPriceMatch |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.RetailSkuKey) } |
        ForEach-Object {
            [pscustomobject]@{
                RetailSkuKey = $_.RetailSkuKey
                RetailSkuId = $_.RetailSkuId
                RetailMeterId = $_.RetailMeterId
                RetailProductId = $_.RetailProductId
                RetailArmRegionName = $_.RetailArmRegionName
                RetailUnitOfMeasure = $_.RetailUnitOfMeasure
                RetailPrice = $_.RetailPrice
                RetailUnitPrice = $_.RetailUnitPrice
                RetailCurrencyCode = $_.RetailCurrencyCode
            }
        }
) -KeyColumns @("RetailSkuKey")

$factCostUsageRows = foreach ($row in $factCostUsage) {
    [pscustomobject]@{
        HistoryMonth = $row.HistoryMonth
        Period = $row.Period
        ExportRunId = $row.ExportRunId
        ExportedUtc = $row.ExportedUtc
        AzureCloud = $row.AzureCloud
        AzureCloudDisplayName = Get-CloudDisplayName $row.AzureCloud
        TenantId = if ($row.PSObject.Properties.Name -contains "TenantId") { $row.TenantId } else { "" }
        SubscriptionId = $row.SubscriptionId
        SubscriptionName = $row.SubscriptionName
        UsageDate = $row.UsageDate
        UsageDateAsDate = Get-UsageDateAsDate $row.UsageDate
        ServiceName = $row.ServiceName
        ResourceLocation = $row.ResourceLocation
        ArmRegionName = $row.ArmRegionName
        AzureRegionKey = Get-AzureRegionKey -AzureCloud $row.AzureCloud -ArmRegionName $row.ArmRegionName
        MeterKey = $row.MeterKey
        Meter = $row.Meter
        Product = $row.Product
        PartNumber = $row.PartNumber
        UnitOfMeasure = $row.UnitOfMeasure
        Currency = $row.Currency
        UsageQuantity = $row.UsageQuantity
        Cost = $row.Cost
    }
}

$factRetailRows = foreach ($row in $factRetailPriceMatch) {
    [pscustomobject]@{
        HistoryMonth = $row.HistoryMonth
        Period = $row.Period
        ExportRunId = $row.ExportRunId
        ExportedUtc = $row.ExportedUtc
        AzureCloud = $row.AzureCloud
        AzureCloudDisplayName = Get-CloudDisplayName $row.AzureCloud
        TenantId = if ($row.PSObject.Properties.Name -contains "TenantId") { $row.TenantId } else { "" }
        SubscriptionId = $row.SubscriptionId
        UsageDate = $row.UsageDate
        ServiceName = $row.ServiceName
        ArmRegionName = $row.ArmRegionName
        AzureRegionKey = Get-AzureRegionKey -AzureCloud $row.AzureCloud -ArmRegionName $row.ArmRegionName
        MeterKey = $row.MeterKey
        Currency = $row.Currency
        UsageQuantity = $row.UsageQuantity
        Cost = $row.Cost
        RetailSkuKey = $row.RetailSkuKey
        RetailMatchStatus = $row.RetailMatchStatus
        RetailCandidateCount = $row.RetailCandidateCount
        RetailSkuId = $row.RetailSkuId
        RetailMeterId = $row.RetailMeterId
        RetailProductId = $row.RetailProductId
        RetailArmRegionName = $row.RetailArmRegionName
        RetailUnitOfMeasure = $row.RetailUnitOfMeasure
        RetailPrice = $row.RetailPrice
        RetailUnitPrice = $row.RetailUnitPrice
        RetailCurrencyCode = $row.RetailCurrencyCode
    }
}

$costRetailRows = foreach ($row in $costRetailFact) {
    [pscustomobject]@{
        HistoryMonth = $row.HistoryMonth
        Period = $row.Period
        ExportRunId = $row.ExportRunId
        ExportedUtc = $row.ExportedUtc
        AzureCloud = $row.AzureCloud
        TenantId = if ($row.PSObject.Properties.Name -contains "TenantId") { $row.TenantId } else { "" }
        SubscriptionName = $row.SubscriptionName
        SubscriptionId = $row.SubscriptionId
        UsageQuantity = $row.UsageQuantity
        Cost = $row.Cost
        UsageDate = $row.UsageDate
        ServiceName = $row.ServiceName
        ResourceLocation = $row.ResourceLocation
        ArmRegionName = $row.ArmRegionName
        Meter = $row.Meter
        Product = $row.Product
        PartNumber = $row.PartNumber
        UnitOfMeasure = $row.UnitOfMeasure
        Currency = $row.Currency
        RetailMatchStatus = $row.RetailMatchStatus
        RetailCandidateCount = $row.RetailCandidateCount
        RetailSkuId = $row.RetailSkuId
        RetailMeterId = $row.RetailMeterId
        RetailProductId = $row.RetailProductId
        RetailProductName = $row.RetailProductName
        RetailSkuName = $row.RetailSkuName
        RetailMeterName = $row.RetailMeterName
        RetailArmRegionName = $row.RetailArmRegionName
        RetailUnitOfMeasure = $row.RetailUnitOfMeasure
        RetailPrice = $row.RetailPrice
        RetailUnitPrice = $row.RetailUnitPrice
        RetailCurrencyCode = $row.RetailCurrencyCode
        RetailEquivalentCost = if ($row.PSObject.Properties.Name -contains "RetailEquivalentCost") { $row.RetailEquivalentCost } else { "" }
        EstimatedSavings = if ($row.PSObject.Properties.Name -contains "EstimatedSavings") { $row.EstimatedSavings } else { "" }
    }
}

$ingestionRows = foreach ($row in $ingestionRun) {
    [pscustomobject]@{
        ExportRunId = $row.ExportRunId
        ExportedUtc = $row.ExportedUtc
        AzureCloud = $row.AzureCloud
        AzureCloudDisplayName = Get-CloudDisplayName $row.AzureCloud
        TenantId = $row.TenantId
        AnalysisMode = $row.AnalysisMode
        StorageLocation = $row.StorageLocation
        SubscriptionCount = $row.SubscriptionCount
        AsOfDate = $row.AsOfDate
        AgreementId = $row.AgreementId
        OutputRoot = $row.OutputRoot
        HistoryRoot = $row.HistoryRoot
        ActualCost = $row.ActualCost
        RetailEquivalentCost = $row.RetailEquivalentCost
        EstimatedSavings = $row.EstimatedSavings
        CalculationVersion = $row.CalculationVersion
    }
}

$tableRows = [ordered]@{
    DimAzureCloud = New-ObjectRows $dimAzureCloud
    DimAzureRegion = New-ObjectRows $dimAzureRegion
    DimSubscription = New-ObjectRows $dimSubscription
    DimService = New-ObjectRows $dimService
    DimMeter = New-ObjectRows $dimMeter
    DimRetailSku = New-ObjectRows $dimRetailSku
    IngestionRun = New-ObjectRows $ingestionRows
    FactCostUsage = New-ObjectRows $factCostUsageRows
    FactRetailPriceMatch = New-ObjectRows $factRetailRows
    CostRetailFact = New-ObjectRows $costRetailRows
    BillingSubscriptionProperties = New-ObjectRows $billingSubscriptionProperties
    BillingAccount = New-ObjectRows $billingAccount
    BillingProfile = New-ObjectRows $billingProfile
    InvoiceSection = New-ObjectRows $invoiceSection
    BillingInvoice = New-ObjectRows $billingInvoice
    BillingRoleAssignment = New-ObjectRows $billingRoleAssignment
    AgreementPriceAudit = New-ObjectRows $agreementPriceAudit
}

$tableKeys = @{
    DimAzureCloud = @("AzureCloud")
    DimAzureRegion = @("AzureRegionKey")
    DimSubscription = @("AzureCloud","TenantId","SubscriptionId")
    DimService = @("ServiceName")
    DimMeter = @("MeterKey")
    DimRetailSku = @("RetailSkuKey")
    IngestionRun = @("ExportRunId")
    FactCostUsage = @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency")
    FactRetailPriceMatch = @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency","RetailSkuKey")
    CostRetailFact = @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","Meter","Product","PartNumber","UnitOfMeasure","Currency")
    BillingSubscriptionProperties = @("AzureCloud","TenantId","SubscriptionId")
    BillingAccount = @("AzureCloud","TenantId","BillingAccountName")
    BillingProfile = @("AzureCloud","TenantId","BillingAccountName","BillingProfileName")
    InvoiceSection = @("AzureCloud","TenantId","BillingAccountName","BillingProfileName","InvoiceSectionName")
    BillingInvoice = @("AzureCloud","TenantId","BillingAccountName","BillingProfileName","InvoiceName")
    BillingRoleAssignment = @("AzureCloud","TenantId","Scope","PrincipalId","RoleDefinitionId")
}

$tablePartitionKeys = @{
    AgreementPriceAudit = @("AzureCloud","TenantId","ExportRunId")
}

$accessToken = Get-AzureSqlAccessToken
$connection = New-SqlConnection -ServerName $ServerName -DatabaseName $DatabaseName -AccessToken $accessToken
try {
    if ($Replace) {
        $tableOrder = @(
            "AgreementPriceAudit",
            "BillingRoleAssignment",
            "BillingInvoice",
            "InvoiceSection",
            "BillingProfile",
            "BillingAccount",
            "BillingSubscriptionProperties",
            "CostRetailFact",
            "FactRetailPriceMatch",
            "FactCostUsage",
            "IngestionRun",
            "DimRetailSku",
            "DimMeter",
            "DimService",
            "DimSubscription",
            "DimAzureRegion",
            "DimAzureCloud"
        )
        foreach ($table in $tableOrder) {
            Invoke-SqlNonQuery -Connection $connection -Sql "DELETE FROM [$SchemaName].[$table];"
        }
    }

    foreach ($tableName in @($tableRows.Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$tableName)) {
            throw "Internal load map contained a blank table name."
        }
        Write-Host "Preparing $SchemaName.$tableName ($(@($tableRows[$tableName]).Count) source rows)..."
        Write-SqlTable -Connection $connection -SchemaName $SchemaName -TableName $tableName -Rows @($tableRows[$tableName]) -KeyColumns @($tableKeys[$tableName]) -ReplacePartitionColumns @($tablePartitionKeys[$tableName])
    }

    Write-FinOpsOperationalSummary -Connection $connection -SchemaName $SchemaName
}
finally {
    $connection.Dispose()
}
