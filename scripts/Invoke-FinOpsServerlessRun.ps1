<#
.SYNOPSIS
Runs the FinOps ingestion flow without the Windows Forms launcher.

.DESCRIPTION
Runner for scheduled/serverless execution. Native mode uses Az.Accounts and
ARM REST extraction scripts. CliBridge mode authenticates Azure CLI and runs
the existing desktop/POC extraction scripts for backward compatibility.

Use this for local development, POC, custom-container Functions, or Container
App Jobs where Azure CLI is available. The enterprise-native production runner
should replace Azure CLI calls with Az.Accounts token acquisition and direct
ARM / Cost Management / Billing REST calls.
#>
[CmdletBinding()]
param(
    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = $(if ($env:FINOPS_AZURE_CLOUD) { $env:FINOPS_AZURE_CLOUD } else { "AzureCloud" }),

    [string]$TenantId = $env:FINOPS_TENANT_ID,

    [string[]]$SubscriptionId = @(
        if ($env:FINOPS_SUBSCRIPTION_IDS) {
            $env:FINOPS_SUBSCRIPTION_IDS -split "[,;]" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
        }
    ),

    [datetime]$AsOfDate = (Get-Date),

    [string]$OutputRoot = $(if ($env:FINOPS_OUTPUT_ROOT) { $env:FINOPS_OUTPUT_ROOT } else { (Join-Path $PSScriptRoot "exports") }),

    [string]$HistoryRoot = $(if ($env:FINOPS_HISTORY_ROOT) { $env:FINOPS_HISTORY_ROOT } else { (Join-Path $OutputRoot "history") }),

    [switch]$SkipRetailPriceLookup = ($env:FINOPS_SKIP_RETAIL_PRICE_LOOKUP -eq "true"),

    [switch]$RunBillingContactAudit = ($env:FINOPS_RUN_BILLING_AUDIT -ne "false"),

    [switch]$LoadAzureSql = ($env:FINOPS_SQL_ENABLED -eq "true"),

    [string]$AzureSqlServerName = $env:FINOPS_SQL_SERVER,

    [string]$AzureSqlDatabaseName = $(if ($env:FINOPS_SQL_DATABASE) { $env:FINOPS_SQL_DATABASE } else { "FinOpsMaccRetail" }),

    [string]$AzureSqlSchemaName = $(if ($env:FINOPS_SQL_SCHEMA) { $env:FINOPS_SQL_SCHEMA } else { "finops" }),

    [ValidateSet("Native", "CliBridge")]
    [string]$ExtractionMode = $(if ($env:FINOPS_EXTRACTION_MODE) { $env:FINOPS_EXTRACTION_MODE } else { "Native" }),

    [ValidateSet("Existing", "ServicePrincipal", "ManagedIdentity")]
    [string]$AuthMode = $(if ($env:FINOPS_AUTH_MODE) { $env:FINOPS_AUTH_MODE } else { "Existing" })
)

$ErrorActionPreference = "Stop"

function Invoke-FinOpsAzureCliLogin {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$AzureCloud,

        [Parameter(Mandatory)]
        [ValidateSet("Existing", "ServicePrincipal", "ManagedIdentity")]
        [string]$AuthMode,

        [string]$TenantId
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI is required for this bridge runner. Use local dev, a custom Function container, or an Azure Container App Job image with Azure CLI installed. The enterprise-native runner should use Az.Accounts + REST without Azure CLI."
    }

    az cloud set --name $AzureCloud | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure CLI cloud to $AzureCloud."
    }

    switch ($AuthMode) {
        "Existing" {
            az account show --output none 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "AuthMode=Existing requires Azure CLI to already be signed in."
            }
        }
        "ServicePrincipal" {
            if ([string]::IsNullOrWhiteSpace($env:FINOPS_CLIENT_ID) -or [string]::IsNullOrWhiteSpace($env:FINOPS_CLIENT_SECRET) -or [string]::IsNullOrWhiteSpace($TenantId)) {
                throw "ServicePrincipal auth requires FINOPS_CLIENT_ID, FINOPS_CLIENT_SECRET, and FINOPS_TENANT_ID."
            }

            az login --service-principal --username $env:FINOPS_CLIENT_ID --password $env:FINOPS_CLIENT_SECRET --tenant $TenantId --output none
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI service principal login failed."
            }
        }
        "ManagedIdentity" {
            $args = @("login", "--identity", "--output", "none")
            if (-not [string]::IsNullOrWhiteSpace($env:FINOPS_MANAGED_IDENTITY_CLIENT_ID)) {
                $args += @("--username", $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID)
            }

            az @args
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI managed identity login failed."
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $actualTenant = az account show --query tenantId --output tsv
        if ($LASTEXITCODE -eq 0 -and $actualTenant -and $actualTenant.Trim() -ne $TenantId) {
            Write-Warning "Current Azure CLI tenant is $actualTenant but FINOPS_TENANT_ID is $TenantId."
        }
    }
}

$solutionRoot = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $OutputRoot ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
New-Item -ItemType Directory -Path $HistoryRoot -Force | Out-Null

$runId = [guid]::NewGuid().ToString("N")
$runStartedUtc = (Get-Date).ToUniversalTime()

function Write-FinOpsRunStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Started", "Succeeded", "Failed")]
        [string]$Status,

        [string]$Message = ""
    )

    $elapsedSeconds = [math]::Round(((Get-Date).ToUniversalTime() - $script:runStartedUtc).TotalSeconds, 0)
    Write-Host "FinOpsRunStatus=$Status RunId=$script:runId AzureCloud=$AzureCloud ExtractionMode=$ExtractionMode AuthMode=$AuthMode SqlEnabled=$([bool]$LoadAzureSql) ElapsedSeconds=$elapsedSeconds Message=$Message"
}

Start-Transcript -Path (Join-Path $runRoot "finops-serverless-run.log") -Force
try {
    Write-Host "Starting serverless FinOps run."
    Write-FinOpsRunStatus -Status "Started" -Message "Serverless FinOps run started."
    Write-Host "Run root: $runRoot"
    Write-Host "History root: $HistoryRoot"
    Write-Host "Azure cloud: $AzureCloud"
    Write-Host "Auth mode: $AuthMode"
    Write-Host "Extraction mode: $ExtractionMode"

    if ($ExtractionMode -eq "CliBridge") {
        Invoke-FinOpsAzureCliLogin -AzureCloud $AzureCloud -AuthMode $AuthMode -TenantId $TenantId
    }

    if ($ExtractionMode -eq "Native") {
        $nativeCostArgs = @{
            OutputDir = $runRoot
            AsOfDate = $AsOfDate
            AzureCloud = $AzureCloud
            AuthMode = $AuthMode
        }
        if ($TenantId) { $nativeCostArgs.TenantId = $TenantId }
        if ($SubscriptionId.Count -gt 0) { $nativeCostArgs.SubscriptionId = $SubscriptionId }
        if ($env:FINOPS_CLIENT_ID) { $nativeCostArgs.ClientId = $env:FINOPS_CLIENT_ID }
        if ($env:FINOPS_CLIENT_SECRET) { $nativeCostArgs.ClientSecret = $env:FINOPS_CLIENT_SECRET }
        if ($env:FINOPS_MANAGED_IDENTITY_CLIENT_ID) { $nativeCostArgs.ManagedIdentityClientId = $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID }

        & (Join-Path $PSScriptRoot "Invoke-FinOpsNativeCostExport.ps1") @nativeCostArgs

        if (-not $SkipRetailPriceLookup) {
            & (Join-Path $PSScriptRoot "Invoke-FinOpsNativeRetailEnrichment.ps1") -OutputDir $runRoot

            $nativeAuditArgs = @{
                OutputRoot = $runRoot
                HistoryRoot = $HistoryRoot
                AnalysisMode = "History"
                TenantId = $TenantId
                SubscriptionIds = $SubscriptionId
                AsOfDate = $AsOfDate
                StorageLocation = "Local"
                AgreementId = $(if ($env:FINOPS_AGREEMENT_ID) { $env:FINOPS_AGREEMENT_ID } else { "MACC-Agreement" })
                CustomerName = $env:FINOPS_CUSTOMER_NAME
                CommitmentCurrency = $(if ($env:FINOPS_COMMITMENT_CURRENCY) { $env:FINOPS_COMMITMENT_CURRENCY } else { "USD" })
            }
            if ($env:FINOPS_AGREEMENT_START_DATE) { $nativeAuditArgs.AgreementStartDate = [datetime]$env:FINOPS_AGREEMENT_START_DATE }
            if ($env:FINOPS_AGREEMENT_END_DATE) { $nativeAuditArgs.AgreementEndDate = [datetime]$env:FINOPS_AGREEMENT_END_DATE }
            if ($env:FINOPS_COMMITMENT_AMOUNT) { $nativeAuditArgs.CommitmentAmount = [decimal]$env:FINOPS_COMMITMENT_AMOUNT }
            if ($env:FINOPS_PACING_WARNING_PERCENT) { $nativeAuditArgs.PacingWarningPercent = [decimal]$env:FINOPS_PACING_WARNING_PERCENT }
            if ($env:FINOPS_PACING_CRITICAL_PERCENT) { $nativeAuditArgs.PacingCriticalPercent = [decimal]$env:FINOPS_PACING_CRITICAL_PERCENT }

            & (Join-Path $PSScriptRoot "New-FinOpsAuditArtifacts.ps1") @nativeAuditArgs
        }

        if ($RunBillingContactAudit) {
            $nativeBillingArgs = @{
                OutputDir = (Join-Path $runRoot "billing-contact-audit")
                SubscriptionId = $SubscriptionId
                IncludeInvoices = $true
                AzureCloud = $AzureCloud
                AuthMode = $AuthMode
            }
            if ($TenantId) { $nativeBillingArgs.TenantId = $TenantId }
            if ($env:FINOPS_CLIENT_ID) { $nativeBillingArgs.ClientId = $env:FINOPS_CLIENT_ID }
            if ($env:FINOPS_CLIENT_SECRET) { $nativeBillingArgs.ClientSecret = $env:FINOPS_CLIENT_SECRET }
            if ($env:FINOPS_MANAGED_IDENTITY_CLIENT_ID) { $nativeBillingArgs.ManagedIdentityClientId = $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID }

            & (Join-Path $PSScriptRoot "Invoke-FinOpsNativeBillingAudit.ps1") @nativeBillingArgs
        }

        & (Join-Path $PSScriptRoot "Update-FinOpsNativeHistory.ps1") `
            -OutputRoot $runRoot `
            -HistoryRoot $HistoryRoot `
            -AzureCloud $AzureCloud `
            -TenantId $TenantId `
            -AsOfDate $AsOfDate

        if ($LoadAzureSql) {
            if ([string]::IsNullOrWhiteSpace($AzureSqlServerName)) {
                throw "FINOPS_SQL_ENABLED=true requires FINOPS_SQL_SERVER."
            }

            & (Join-Path $PSScriptRoot "Import-FinOpsSqlData.ps1") `
                -ServerName $AzureSqlServerName `
                -DatabaseName $AzureSqlDatabaseName `
                -SchemaName $AzureSqlSchemaName `
                -HistoryRoot $HistoryRoot `
                -CurrentRunRoot $runRoot
        }
    }
    else {
        $costArgs = @{
            OutputDir = $runRoot
            AsOfDate = $AsOfDate
            AzureCloud = $AzureCloud
        }
        if ($TenantId) { $costArgs.TenantId = $TenantId }
        if ($SubscriptionId.Count -gt 0) { $costArgs.SubscriptionId = $SubscriptionId }
        if ($SkipRetailPriceLookup) { $costArgs.SkipRetailPriceLookup = $true }

        & (Join-Path $PSScriptRoot "Get-CostAnalysis.ps1") @costArgs

        if ($RunBillingContactAudit) {
            $billingArgs = @{
                OutputDir = (Join-Path $runRoot "billing-contact-audit")
                SubscriptionId = $SubscriptionId
                IncludeInvoices = $true
                AzureCloud = $AzureCloud
            }
            if ($TenantId) { $billingArgs.TenantId = $TenantId }

            & (Join-Path $PSScriptRoot "Get-AzureBillingContactAudit.ps1") @billingArgs
        }

        if (-not $SkipRetailPriceLookup) {
            $auditArgs = @{
                OutputRoot = $runRoot
                HistoryRoot = $HistoryRoot
                AnalysisMode = "History"
                TenantId = $TenantId
                SubscriptionIds = $SubscriptionId
                AsOfDate = $AsOfDate
                StorageLocation = "Local"
                AgreementId = $(if ($env:FINOPS_AGREEMENT_ID) { $env:FINOPS_AGREEMENT_ID } else { "MACC-Agreement" })
                CustomerName = $env:FINOPS_CUSTOMER_NAME
                CommitmentCurrency = $(if ($env:FINOPS_COMMITMENT_CURRENCY) { $env:FINOPS_COMMITMENT_CURRENCY } else { "USD" })
            }

            & (Join-Path $PSScriptRoot "New-FinOpsAuditArtifacts.ps1") @auditArgs
        }

        if ($LoadAzureSql) {
            if ([string]::IsNullOrWhiteSpace($AzureSqlServerName)) {
                throw "FINOPS_SQL_ENABLED=true requires FINOPS_SQL_SERVER."
            }

            & (Join-Path $PSScriptRoot "Import-FinOpsSqlData.ps1") `
                -ServerName $AzureSqlServerName `
                -DatabaseName $AzureSqlDatabaseName `
                -SchemaName $AzureSqlSchemaName `
                -HistoryRoot $HistoryRoot `
                -CurrentRunRoot $runRoot
        }
    }

    Write-Host "Serverless FinOps run complete."
    Write-FinOpsRunStatus -Status "Succeeded" -Message "Serverless FinOps run completed."
}
catch {
    Write-FinOpsRunStatus -Status "Failed" -Message $_.Exception.Message
    throw
}
finally {
    Stop-Transcript
}
