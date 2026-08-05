<#
.SYNOPSIS
Creates the Azure SQL database schema for the Azure FinOps MACC Retail durable store.

.DESCRIPTION
Uses the current Azure CLI sign-in to request an Entra ID token for Azure SQL Database,
optionally creates the target database, and deploys the finops schema/tables.

This script does not require sqlcmd or the SqlServer PowerShell module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerName,

    [string]$DatabaseName = "FinOpsMaccRetail",

    [string]$SchemaName = "finops",

    [switch]$CreateDatabase,

    [switch]$DropExistingTables
)

$ErrorActionPreference = "Stop"

function Quote-SqlName {
    param([Parameter(Mandatory)][string]$Name)
    return "[" + ($Name -replace "]", "]]") + "]"
}

function Get-AzureSqlAccessToken {
    $token = az account get-access-token --resource "https://database.windows.net/" --query accessToken --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not get Azure SQL access token from Azure CLI. Run az login first. Details: $token"
    }

    return [string]$token
}

function Invoke-AzureSqlBatch {
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$DatabaseName,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$Sql
    )

    $connectionString = "Server=tcp:$ServerName,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $connection.AccessToken = $AccessToken
    try {
        $connection.Open()
        $batches = [regex]::Split($Sql, "(?im)^\s*GO\s*;?\s*$") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($batch in $batches) {
            $command = $connection.CreateCommand()
            $command.CommandTimeout = 120
            $command.CommandText = $batch
            [void]$command.ExecuteNonQuery()
        }
    }
    finally {
        $connection.Dispose()
    }
}

function New-TableDefinition {
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string[]]$Columns,
        [string[]]$UniqueColumns = @()
    )

    [pscustomobject]@{
        Name = $TableName
        Columns = $Columns
        UniqueColumns = $UniqueColumns
    }
}

$schema = Quote-SqlName $SchemaName
$database = Quote-SqlName $DatabaseName
$accessToken = Get-AzureSqlAccessToken

if ($CreateDatabase) {
    $createDatabaseSql = @"
IF DB_ID(N'$($DatabaseName.Replace("'", "''"))') IS NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'CREATE DATABASE $database';
    EXEC (@sql);
END
"@
    Write-Host "Ensuring database exists: $DatabaseName"
    try {
        Invoke-AzureSqlBatch -ServerName $ServerName -DatabaseName "master" -AccessToken $accessToken -Sql $createDatabaseSql
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            Write-Warning "Database already exists: $DatabaseName"
        }
        else {
            throw
        }
    }
}

$tables = @(
    New-TableDefinition -TableName "IngestionRun" -UniqueColumns @("ExportRunId") -Columns @(
        "ExportRunId nvarchar(128) NOT NULL",
        "ExportedUtc datetime2(7) NULL",
        "AzureCloud nvarchar(64) NULL",
        "AzureCloudDisplayName nvarchar(128) NULL",
        "TenantId nvarchar(128) NULL",
        "AnalysisMode nvarchar(32) NULL",
        "StorageLocation nvarchar(64) NULL",
        "SubscriptionCount int NULL",
        "AsOfDate date NULL",
        "AgreementId nvarchar(256) NULL",
        "OutputRoot nvarchar(1024) NULL",
        "HistoryRoot nvarchar(1024) NULL",
        "ActualCost decimal(19,4) NULL",
        "RetailEquivalentCost decimal(19,4) NULL",
        "EstimatedSavings decimal(19,4) NULL",
        "CalculationVersion nvarchar(64) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_IngestionRun_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "DimAzureCloud" -UniqueColumns @("AzureCloud") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "AzureCloudDisplayName nvarchar(128) NOT NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_DimAzureCloud_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "DimAzureRegion" -UniqueColumns @("AzureRegionKey") -Columns @(
        "AzureRegionKey nvarchar(256) NOT NULL",
        "ArmRegionName nvarchar(128) NOT NULL",
        "ResourceLocation nvarchar(256) NULL",
        "RegionDisplayName nvarchar(256) NULL",
        "AzureRegionName nvarchar(128) NULL",
        "AzureCloudDisplayName nvarchar(128) NOT NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_DimAzureRegion_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "DimSubscription" -UniqueColumns @("AzureCloud","TenantId","SubscriptionId") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "AzureCloudDisplayName nvarchar(128) NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_DimSubscription_TenantId DEFAULT N''",
        "SubscriptionId nvarchar(128) NOT NULL",
        "SubscriptionName nvarchar(512) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_DimSubscription_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "DimService" -UniqueColumns @("ServiceName") -Columns @(
        "ServiceName nvarchar(512) NOT NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_DimService_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "DimMeter" -UniqueColumns @("MeterKey") -Columns @(
        "MeterKey nvarchar(1200) NOT NULL",
        "ServiceName nvarchar(512) NULL",
        "Meter nvarchar(512) NULL",
        "Product nvarchar(512) NULL",
        "PartNumber nvarchar(256) NULL",
        "UnitOfMeasure nvarchar(256) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_DimMeter_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "DimRetailSku" -UniqueColumns @("RetailSkuKey") -Columns @(
        "RetailSkuKey nvarchar(1200) NOT NULL",
        "RetailSkuId nvarchar(256) NULL",
        "RetailMeterId nvarchar(256) NULL",
        "RetailProductId nvarchar(256) NULL",
        "RetailArmRegionName nvarchar(128) NULL",
        "RetailUnitOfMeasure nvarchar(256) NULL",
        "RetailPrice decimal(19,8) NULL",
        "RetailUnitPrice decimal(19,8) NULL",
        "RetailCurrencyCode nvarchar(32) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_DimRetailSku_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "FactCostUsage" -UniqueColumns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency") -Columns @(
        "HistoryMonth char(7) NOT NULL",
        "Period nvarchar(64) NOT NULL",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "AzureCloud nvarchar(64) NOT NULL",
        "AzureCloudDisplayName nvarchar(128) NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_FactCostUsage_TenantId DEFAULT N''",
        "SubscriptionId nvarchar(128) NOT NULL",
        "SubscriptionName nvarchar(512) NULL",
        "UsageDate int NOT NULL",
        "UsageDateAsDate date NULL",
        "ServiceName nvarchar(512) NOT NULL",
        "ResourceLocation nvarchar(256) NULL",
        "ArmRegionName nvarchar(128) NOT NULL",
        "AzureRegionKey nvarchar(256) NULL",
        "MeterKey nvarchar(1200) NOT NULL",
        "Meter nvarchar(512) NULL",
        "Product nvarchar(512) NULL",
        "PartNumber nvarchar(256) NULL",
        "UnitOfMeasure nvarchar(256) NULL",
        "Currency nvarchar(32) NOT NULL",
        "UsageQuantity decimal(28,8) NULL",
        "Cost decimal(19,4) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_FactCostUsage_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "FactRetailPriceMatch" -UniqueColumns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency","RetailSkuKey") -Columns @(
        "HistoryMonth char(7) NOT NULL",
        "Period nvarchar(64) NOT NULL",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "AzureCloud nvarchar(64) NOT NULL",
        "AzureCloudDisplayName nvarchar(128) NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_FactRetailPriceMatch_TenantId DEFAULT N''",
        "SubscriptionId nvarchar(128) NOT NULL",
        "UsageDate int NOT NULL",
        "ServiceName nvarchar(512) NOT NULL",
        "ArmRegionName nvarchar(128) NOT NULL",
        "AzureRegionKey nvarchar(256) NULL",
        "MeterKey nvarchar(1200) NOT NULL",
        "Currency nvarchar(32) NOT NULL",
        "UsageQuantity decimal(28,8) NULL",
        "Cost decimal(19,4) NULL",
        "RetailSkuKey nvarchar(1200) NOT NULL CONSTRAINT DF_FactRetailPriceMatch_RetailSkuKey DEFAULT N''",
        "RetailMatchStatus nvarchar(128) NULL",
        "RetailCandidateCount int NULL",
        "RetailSkuId nvarchar(256) NULL",
        "RetailMeterId nvarchar(256) NULL",
        "RetailProductId nvarchar(256) NULL",
        "RetailArmRegionName nvarchar(128) NULL",
        "RetailUnitOfMeasure nvarchar(256) NULL",
        "RetailPrice decimal(19,8) NULL",
        "RetailUnitPrice decimal(19,8) NULL",
        "RetailCurrencyCode nvarchar(32) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_FactRetailPriceMatch_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "CostRetailFact" -UniqueColumns @("AzureCloud","TenantId","SubscriptionId","HistoryMonth","Period","UsageDate","ServiceName","ArmRegionName","Meter","Product","PartNumber","UnitOfMeasure","Currency") -Columns @(
        "HistoryMonth char(7) NOT NULL",
        "Period nvarchar(64) NOT NULL",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_CostRetailFact_TenantId DEFAULT N''",
        "SubscriptionName nvarchar(512) NULL",
        "SubscriptionId nvarchar(128) NOT NULL",
        "UsageQuantity decimal(28,8) NULL",
        "Cost decimal(19,4) NULL",
        "UsageDate int NOT NULL",
        "ServiceName nvarchar(512) NOT NULL",
        "ResourceLocation nvarchar(256) NULL",
        "ArmRegionName nvarchar(128) NOT NULL",
        "Meter nvarchar(512) NOT NULL",
        "Product nvarchar(512) NULL",
        "PartNumber nvarchar(256) NULL",
        "UnitOfMeasure nvarchar(256) NULL",
        "Currency nvarchar(32) NOT NULL",
        "RetailMatchStatus nvarchar(128) NULL",
        "RetailCandidateCount int NULL",
        "RetailSkuId nvarchar(256) NULL",
        "RetailMeterId nvarchar(256) NULL",
        "RetailProductId nvarchar(256) NULL",
        "RetailProductName nvarchar(512) NULL",
        "RetailSkuName nvarchar(512) NULL",
        "RetailMeterName nvarchar(512) NULL",
        "RetailArmRegionName nvarchar(128) NULL",
        "RetailUnitOfMeasure nvarchar(256) NULL",
        "RetailPrice decimal(19,8) NULL",
        "RetailUnitPrice decimal(19,8) NULL",
        "RetailCurrencyCode nvarchar(32) NULL",
        "RetailEquivalentCost decimal(19,4) NULL",
        "EstimatedSavings decimal(19,4) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_CostRetailFact_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "BillingSubscriptionProperties" -UniqueColumns @("AzureCloud","TenantId","SubscriptionId") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_BillingSubscriptionProperties_TenantId DEFAULT N''",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "SubscriptionName nvarchar(512) NULL",
        "SubscriptionId nvarchar(128) NOT NULL",
        "State nvarchar(128) NULL",
        "BillingAccountId nvarchar(1024) NULL",
        "BillingProfileId nvarchar(1024) NULL",
        "InvoiceSectionId nvarchar(1024) NULL",
        "ProductId nvarchar(256) NULL",
        "ProductName nvarchar(512) NULL",
        "SkuId nvarchar(256) NULL",
        "RawJson nvarchar(1024) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_BillingSubscriptionProperties_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "BillingAccount" -UniqueColumns @("AzureCloud","TenantId","BillingAccountName") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_BillingAccount_TenantId DEFAULT N''",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "BillingAccountName nvarchar(512) NOT NULL",
        "DisplayName nvarchar(512) NULL",
        "AccountType nvarchar(128) NULL",
        "AgreementType nvarchar(128) NULL",
        "Status nvarchar(128) NULL",
        "SoldTo nvarchar(max) NULL",
        "RegistrationNumber nvarchar(256) NULL",
        "RawJson nvarchar(1024) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_BillingAccount_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "BillingProfile" -UniqueColumns @("AzureCloud","TenantId","BillingAccountName","BillingProfileName") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_BillingProfile_TenantId DEFAULT N''",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "BillingAccountName nvarchar(512) NOT NULL",
        "BillingProfileName nvarchar(512) NOT NULL",
        "DisplayName nvarchar(512) NULL",
        "Status nvarchar(128) NULL",
        "BillTo nvarchar(max) NULL",
        "InvoiceEmailOptIn nvarchar(128) NULL",
        "InvoiceDay nvarchar(64) NULL",
        "PoNumber nvarchar(256) NULL",
        "Currency nvarchar(32) NULL",
        "RawJson nvarchar(1024) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_BillingProfile_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "InvoiceSection" -UniqueColumns @("AzureCloud","TenantId","BillingAccountName","BillingProfileName","InvoiceSectionName") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_InvoiceSection_TenantId DEFAULT N''",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "BillingAccountName nvarchar(512) NOT NULL",
        "BillingProfileName nvarchar(512) NOT NULL",
        "InvoiceSectionName nvarchar(512) NOT NULL",
        "DisplayName nvarchar(512) NULL",
        "State nvarchar(128) NULL",
        "Labels nvarchar(max) NULL",
        "SystemId nvarchar(256) NULL",
        "RawJson nvarchar(1024) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_InvoiceSection_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "BillingInvoice" -UniqueColumns @("AzureCloud","TenantId","BillingAccountName","BillingProfileName","InvoiceName") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_BillingInvoice_TenantId DEFAULT N''",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "BillingAccountName nvarchar(512) NOT NULL CONSTRAINT DF_BillingInvoice_BillingAccountName DEFAULT N''",
        "BillingProfileName nvarchar(512) NOT NULL CONSTRAINT DF_BillingInvoice_BillingProfileName DEFAULT N''",
        "InvoiceName nvarchar(512) NOT NULL",
        "InvoiceDate nvarchar(64) NULL",
        "DueDate nvarchar(64) NULL",
        "Status nvarchar(128) NULL",
        "AmountDue nvarchar(128) NULL",
        "BilledAmount nvarchar(128) NULL",
        "PoNumber nvarchar(256) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_BillingInvoice_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "BillingRoleAssignment" -UniqueColumns @("AzureCloud","TenantId","Scope","PrincipalId","RoleDefinitionId") -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_BillingRoleAssignment_TenantId DEFAULT N''",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "Scope nvarchar(1024) NOT NULL",
        "BillingAccountName nvarchar(512) NULL",
        "Parent nvarchar(1024) NULL",
        "PrincipalId nvarchar(256) NOT NULL",
        "PrincipalName nvarchar(512) NULL",
        "PrincipalEmail nvarchar(512) NULL",
        "RoleDefinitionId nvarchar(512) NOT NULL",
        "RoleAssignmentName nvarchar(512) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_BillingRoleAssignment_LoadedUtc DEFAULT SYSUTCDATETIME()"
    );
    New-TableDefinition -TableName "AgreementPriceAudit" -Columns @(
        "AzureCloud nvarchar(64) NOT NULL",
        "TenantId nvarchar(128) NOT NULL CONSTRAINT DF_AgreementPriceAudit_TenantId DEFAULT N''",
        "AgreementId nvarchar(256) NULL",
        "RunId nvarchar(128) NULL",
        "ExportRunId nvarchar(128) NULL",
        "ExportedUtc datetime2(7) NULL",
        "HistoryMonth char(7) NOT NULL",
        "Period nvarchar(64) NOT NULL",
        "SubscriptionName nvarchar(512) NULL",
        "SubscriptionId nvarchar(128) NOT NULL",
        "UsageDate int NOT NULL",
        "ServiceName nvarchar(512) NOT NULL",
        "ResourceLocation nvarchar(256) NULL",
        "ArmRegionName nvarchar(128) NOT NULL",
        "Meter nvarchar(512) NOT NULL",
        "Product nvarchar(512) NULL",
        "PartNumber nvarchar(256) NULL",
        "UnitOfMeasure nvarchar(256) NULL",
        "Currency nvarchar(32) NULL",
        "UsageQuantity decimal(28,8) NULL",
        "ActualCost decimal(19,4) NULL",
        "RetailMatchStatus nvarchar(128) NULL",
        "RetailEquivalentCost decimal(19,4) NULL",
        "EstimatedSavings decimal(19,4) NULL",
        "LoadedUtc datetime2(7) NOT NULL CONSTRAINT DF_AgreementPriceAudit_LoadedUtc DEFAULT SYSUTCDATETIME()"
    )
)

$schemaSql = @"
IF SCHEMA_ID(N'$($SchemaName.Replace("'", "''"))') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA $schema');
END
GO
"@
$schemaSql += [Environment]::NewLine

if ($DropExistingTables) {
    $dropStatements = @()
    foreach ($table in @($tables | Sort-Object Name -Descending)) {
        $dropStatements += "IF OBJECT_ID(N'$SchemaName.$($table.Name)', N'U') IS NOT NULL DROP TABLE $schema.$(Quote-SqlName -Name ($table.Name));"
    }
    $schemaSql += ($dropStatements -join [Environment]::NewLine) + [Environment]::NewLine + "GO" + [Environment]::NewLine
}

foreach ($table in $tables) {
    $tableName = Quote-SqlName -Name ($table.Name)
    $objectName = "$schema.$tableName"
    $columnSql = ($table.Columns | ForEach-Object { "    $_" }) -join "," + [Environment]::NewLine
    $schemaSql += @"
IF OBJECT_ID(N'$SchemaName.$($table.Name)', N'U') IS NULL
BEGIN
    CREATE TABLE $objectName
    (
$columnSql
    );
END
GO
"@
    $schemaSql += [Environment]::NewLine

    if ($table.UniqueColumns.Count -gt 0) {
        $indexName = Quote-SqlName -Name ("UX_" + $table.Name)
        $indexColumns = ($table.UniqueColumns | ForEach-Object { Quote-SqlName -Name $_ }) -join ", "
        $schemaSql += @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = N'UX_$($table.Name)'
      AND object_id = OBJECT_ID(N'$SchemaName.$($table.Name)')
)
BEGIN
    CREATE UNIQUE INDEX $indexName ON $objectName ($indexColumns);
END
GO
"@
        $schemaSql += [Environment]::NewLine
    }
}

$schemaSql += @"
CREATE OR ALTER VIEW $schema.[IngestionFreshnessByCloud]
AS
WITH CostByCloud AS (
    SELECT
        AzureCloud,
        AzureCloudDisplayName,
        TenantId,
        MAX(ExportedUtc) AS LatestCostExportedUtc,
        MAX(LoadedUtc) AS LatestCostLoadedUtc,
        MAX(UsageDateAsDate) AS LatestUsageDate,
        COUNT_BIG(*) AS CostRowCount,
        COUNT(DISTINCT SubscriptionId) AS SubscriptionCount,
        SUM(Cost) AS ActualCost
    FROM $schema.[FactCostUsage]
    GROUP BY AzureCloud, AzureCloudDisplayName, TenantId
),
RetailByCloud AS (
    SELECT
        AzureCloud,
        AzureCloudDisplayName,
        TenantId,
        COUNT_BIG(*) AS RetailRowCount,
        SUM(CASE WHEN RetailMatchStatus = N'Matched' THEN 1 ELSE 0 END) AS MatchedRetailRows,
        SUM(CASE WHEN RetailMatchStatus = N'NoMatch' THEN 1 ELSE 0 END) AS UnmatchedRetailRows,
        SUM(CASE WHEN RetailMatchStatus = N'MultipleCandidates' THEN 1 ELSE 0 END) AS MultipleCandidateRetailRows
    FROM $schema.[FactRetailPriceMatch]
    GROUP BY AzureCloud, AzureCloudDisplayName, TenantId
),
LatestRun AS (
    SELECT
        ExportRunId,
        ExportedUtc,
        AzureCloud,
        AzureCloudDisplayName,
        TenantId,
        AsOfDate,
        OutputRoot,
        HistoryRoot,
        LoadedUtc,
        ROW_NUMBER() OVER (
            PARTITION BY AzureCloud, TenantId
            ORDER BY COALESCE(ExportedUtc, LoadedUtc) DESC, LoadedUtc DESC, ExportRunId DESC
        ) AS RowNumber
    FROM $schema.[IngestionRun]
)
SELECT
    COALESCE(c.AzureCloud, r.AzureCloud, lr.AzureCloud) AS AzureCloud,
    COALESCE(c.AzureCloudDisplayName, r.AzureCloudDisplayName, lr.AzureCloudDisplayName) AS AzureCloudDisplayName,
    COALESCE(c.TenantId, r.TenantId, lr.TenantId, N'') AS TenantId,
    lr.ExportRunId AS LatestExportRunId,
    lr.ExportedUtc AS LatestRunExportedUtc,
    lr.LoadedUtc AS LatestRunLoadedUtc,
    c.LatestCostExportedUtc,
    c.LatestCostLoadedUtc,
    c.LatestUsageDate,
    lr.AsOfDate,
    c.CostRowCount,
    c.SubscriptionCount,
    c.ActualCost,
    r.RetailRowCount,
    r.MatchedRetailRows,
    r.UnmatchedRetailRows,
    r.MultipleCandidateRetailRows,
    CAST(
        CASE
            WHEN NULLIF(r.RetailRowCount, 0) IS NULL THEN NULL
            ELSE (CONVERT(decimal(19,4), r.MatchedRetailRows) / CONVERT(decimal(19,4), r.RetailRowCount)) * 100
        END AS decimal(9,2)
    ) AS RetailMatchPercent,
    DATEDIFF(hour, COALESCE(c.LatestCostExportedUtc, lr.ExportedUtc), SYSUTCDATETIME()) AS HoursSinceLastRun,
    DATEDIFF(hour, COALESCE(c.LatestCostLoadedUtc, lr.LoadedUtc), SYSUTCDATETIME()) AS HoursSinceLastLoad,
    CASE
        WHEN COALESCE(c.CostRowCount, 0) = 0 THEN N'NoCostRows'
        WHEN COALESCE(c.LatestCostExportedUtc, lr.ExportedUtc) < DATEADD(hour, -36, SYSUTCDATETIME()) THEN N'Stale'
        WHEN r.RetailRowCount IS NULL OR r.RetailRowCount = 0 THEN N'MissingRetailMatch'
        WHEN (CONVERT(decimal(19,4), r.MatchedRetailRows) / NULLIF(CONVERT(decimal(19,4), r.RetailRowCount), 0)) < 0.80 THEN N'RetailCoverageAtRisk'
        WHEN (CONVERT(decimal(19,4), r.MatchedRetailRows) / NULLIF(CONVERT(decimal(19,4), r.RetailRowCount), 0)) < 0.95 THEN N'RetailCoverageReview'
        ELSE N'Healthy'
    END AS FreshnessStatus,
    lr.OutputRoot,
    lr.HistoryRoot
FROM CostByCloud c
FULL OUTER JOIN RetailByCloud r
    ON c.AzureCloud = r.AzureCloud
   AND ISNULL(c.TenantId, N'') = ISNULL(r.TenantId, N'')
FULL OUTER JOIN (SELECT * FROM LatestRun WHERE RowNumber = 1) lr
    ON COALESCE(c.AzureCloud, r.AzureCloud) = lr.AzureCloud
   AND ISNULL(COALESCE(c.TenantId, r.TenantId, N''), N'') = ISNULL(lr.TenantId, N'');
GO

CREATE OR ALTER VIEW $schema.[IngestionFreshnessBySubscription]
AS
WITH CostBySubscription AS (
    SELECT
        AzureCloud,
        AzureCloudDisplayName,
        TenantId,
        SubscriptionId,
        MAX(SubscriptionName) AS SubscriptionName,
        MAX(ExportedUtc) AS LatestCostExportedUtc,
        MAX(LoadedUtc) AS LatestCostLoadedUtc,
        MAX(UsageDateAsDate) AS LatestUsageDate,
        COUNT_BIG(*) AS CostRowCount,
        SUM(Cost) AS ActualCost
    FROM $schema.[FactCostUsage]
    GROUP BY AzureCloud, AzureCloudDisplayName, TenantId, SubscriptionId
),
RetailBySubscription AS (
    SELECT
        AzureCloud,
        AzureCloudDisplayName,
        TenantId,
        SubscriptionId,
        COUNT_BIG(*) AS RetailRowCount,
        SUM(CASE WHEN RetailMatchStatus = N'Matched' THEN 1 ELSE 0 END) AS MatchedRetailRows,
        SUM(CASE WHEN RetailMatchStatus = N'NoMatch' THEN 1 ELSE 0 END) AS UnmatchedRetailRows,
        SUM(CASE WHEN RetailMatchStatus = N'MultipleCandidates' THEN 1 ELSE 0 END) AS MultipleCandidateRetailRows
    FROM $schema.[FactRetailPriceMatch]
    GROUP BY AzureCloud, AzureCloudDisplayName, TenantId, SubscriptionId
)
SELECT
    COALESCE(s.AzureCloud, c.AzureCloud, r.AzureCloud) AS AzureCloud,
    COALESCE(s.AzureCloudDisplayName, c.AzureCloudDisplayName, r.AzureCloudDisplayName) AS AzureCloudDisplayName,
    COALESCE(s.TenantId, c.TenantId, r.TenantId, N'') AS TenantId,
    COALESCE(s.SubscriptionId, c.SubscriptionId, r.SubscriptionId) AS SubscriptionId,
    COALESCE(s.SubscriptionName, c.SubscriptionName) AS SubscriptionName,
    c.LatestCostExportedUtc,
    c.LatestCostLoadedUtc,
    c.LatestUsageDate,
    c.CostRowCount,
    c.ActualCost,
    r.RetailRowCount,
    r.MatchedRetailRows,
    r.UnmatchedRetailRows,
    r.MultipleCandidateRetailRows,
    CAST(
        CASE
            WHEN NULLIF(r.RetailRowCount, 0) IS NULL THEN NULL
            ELSE (CONVERT(decimal(19,4), r.MatchedRetailRows) / CONVERT(decimal(19,4), r.RetailRowCount)) * 100
        END AS decimal(9,2)
    ) AS RetailMatchPercent,
    DATEDIFF(hour, c.LatestCostExportedUtc, SYSUTCDATETIME()) AS HoursSinceLastRun,
    DATEDIFF(hour, c.LatestCostLoadedUtc, SYSUTCDATETIME()) AS HoursSinceLastLoad,
    CASE
        WHEN COALESCE(c.CostRowCount, 0) = 0 THEN N'NoCostRows'
        WHEN c.LatestCostExportedUtc < DATEADD(hour, -36, SYSUTCDATETIME()) THEN N'Stale'
        WHEN r.RetailRowCount IS NULL OR r.RetailRowCount = 0 THEN N'MissingRetailMatch'
        WHEN (CONVERT(decimal(19,4), r.MatchedRetailRows) / NULLIF(CONVERT(decimal(19,4), r.RetailRowCount), 0)) < 0.80 THEN N'RetailCoverageAtRisk'
        WHEN (CONVERT(decimal(19,4), r.MatchedRetailRows) / NULLIF(CONVERT(decimal(19,4), r.RetailRowCount), 0)) < 0.95 THEN N'RetailCoverageReview'
        ELSE N'Healthy'
    END AS FreshnessStatus
FROM $schema.[DimSubscription] s
FULL OUTER JOIN CostBySubscription c
    ON s.AzureCloud = c.AzureCloud
   AND ISNULL(s.TenantId, N'') = ISNULL(c.TenantId, N'')
   AND s.SubscriptionId = c.SubscriptionId
FULL OUTER JOIN RetailBySubscription r
    ON COALESCE(s.AzureCloud, c.AzureCloud) = r.AzureCloud
   AND ISNULL(COALESCE(s.TenantId, c.TenantId, N''), N'') = ISNULL(r.TenantId, N'')
   AND COALESCE(s.SubscriptionId, c.SubscriptionId) = r.SubscriptionId;
GO

CREATE OR ALTER VIEW $schema.[RetailMatchCoverageByCloud]
AS
SELECT
    AzureCloud,
    AzureCloudDisplayName,
    TenantId,
    COUNT_BIG(*) AS RetailRowCount,
    SUM(CASE WHEN RetailMatchStatus = N'Matched' THEN 1 ELSE 0 END) AS MatchedRetailRows,
    SUM(CASE WHEN RetailMatchStatus = N'NoMatch' THEN 1 ELSE 0 END) AS UnmatchedRetailRows,
    SUM(CASE WHEN RetailMatchStatus = N'MultipleCandidates' THEN 1 ELSE 0 END) AS MultipleCandidateRetailRows,
    CAST((CONVERT(decimal(19,4), SUM(CASE WHEN RetailMatchStatus = N'Matched' THEN 1 ELSE 0 END)) / NULLIF(CONVERT(decimal(19,4), COUNT_BIG(*)), 0)) * 100 AS decimal(9,2)) AS RetailMatchPercent,
    CASE
        WHEN COUNT_BIG(*) = 0 THEN N'NoRetailRows'
        WHEN (CONVERT(decimal(19,4), SUM(CASE WHEN RetailMatchStatus = N'Matched' THEN 1 ELSE 0 END)) / NULLIF(CONVERT(decimal(19,4), COUNT_BIG(*)), 0)) < 0.80 THEN N'AtRisk'
        WHEN (CONVERT(decimal(19,4), SUM(CASE WHEN RetailMatchStatus = N'Matched' THEN 1 ELSE 0 END)) / NULLIF(CONVERT(decimal(19,4), COUNT_BIG(*)), 0)) < 0.95 THEN N'Review'
        ELSE N'Healthy'
    END AS CoverageStatus
FROM $schema.[FactRetailPriceMatch]
GROUP BY AzureCloud, AzureCloudDisplayName, TenantId;
GO

CREATE OR ALTER VIEW $schema.[OperationalHealthSummary]
AS
SELECT
    N'CloudFreshness' AS CheckName,
    AzureCloud,
    AzureCloudDisplayName,
    TenantId,
    CAST(NULL AS nvarchar(128)) AS SubscriptionId,
    CAST(NULL AS nvarchar(512)) AS SubscriptionName,
    FreshnessStatus AS Status,
    LatestRunExportedUtc,
    LatestCostLoadedUtc,
    LatestUsageDate,
    CostRowCount,
    RetailRowCount,
    RetailMatchPercent,
    HoursSinceLastRun,
    HoursSinceLastLoad
FROM $schema.[IngestionFreshnessByCloud]
UNION ALL
SELECT
    N'SubscriptionFreshness' AS CheckName,
    AzureCloud,
    AzureCloudDisplayName,
    TenantId,
    SubscriptionId,
    SubscriptionName,
    FreshnessStatus AS Status,
    LatestCostExportedUtc AS LatestRunExportedUtc,
    LatestCostLoadedUtc,
    LatestUsageDate,
    CostRowCount,
    RetailRowCount,
    RetailMatchPercent,
    HoursSinceLastRun,
    HoursSinceLastLoad
FROM $schema.[IngestionFreshnessBySubscription]
WHERE FreshnessStatus <> N'Healthy';
GO

"@

Write-Host "Deploying schema '$SchemaName' to database '$DatabaseName' on '$ServerName'..."
Invoke-AzureSqlBatch -ServerName $ServerName -DatabaseName $DatabaseName -AccessToken $accessToken -Sql $schemaSql
Write-Host "Azure SQL durable schema and monitoring view deployment complete."

