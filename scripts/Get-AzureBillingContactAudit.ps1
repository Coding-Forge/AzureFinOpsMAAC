<#
.SYNOPSIS
Exports Azure billing contact and ownership evidence for invoice-recipient review.

.DESCRIPTION
Uses Azure CLI and Azure Billing REST APIs to export billing accounts, billing
profiles, invoice sections, subscription billing properties, and billing role
assignments into Markdown, CSV, and raw JSON files.

The export is read-only. It does not modify billing configuration.
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = "AzureCloud",

    [string[]]$SubscriptionId = @(),

    [string]$OutputDir = (Join-Path $PSScriptRoot "exports\billing-contact-audit"),

    [switch]$InstallAzureCli,

    [switch]$IncludeInvoices,

    [int]$RecentInvoiceLimit = 12,

    [string]$ApiVersion = "2024-04-01"
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
        throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows or rerun with -InstallAzureCli."
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

function Get-AzureResourceManagerEndpoint {
    $endpoint = az cloud show --query endpoints.resourceManager --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($endpoint)) {
        throw "Could not determine Azure Resource Manager endpoint for the active Azure CLI cloud."
    }

    return $endpoint.TrimEnd("/")
}

function Ensure-AzureLogin {
    $accountJson = az account show --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) {
        return ($accountJson | ConvertFrom-Json)
    }

    Write-Host "No Azure login found. Starting device-code sign-in..."
    $loginArgs = @("login", "--use-device-code", "--allow-no-subscriptions", "--output", "json")
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $loginArgs += @("--tenant", $TenantId.Trim())
    }

    az @loginArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure sign-in failed."
    }

    $accountJson = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
        throw "Azure sign-in succeeded, but no active Azure CLI account context is available."
    }

    return ($accountJson | ConvertFrom-Json)
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Get-PropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string[]]$PropertyPath
    )

    $cursor = $Object
    foreach ($propertyName in $PropertyPath) {
        if ($null -eq $cursor) {
            return $null
        }
        if ($cursor.PSObject.Properties.Name -notcontains $propertyName) {
            return $null
        }
        $cursor = $cursor.$propertyName
    }

    return $cursor
}

function ConvertTo-AuditText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ""
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
        return [string]$Value
    }

    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Invoke-AzRestJson {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$AllowFailure
    )

    try {
        $resourceManagerEndpoint = Get-AzureResourceManagerEndpoint
        $resolvedUri = if ($Uri -like "https://management.azure.com*") {
            $Uri -replace "^https://management\.azure\.com", $resourceManagerEndpoint
        }
        else {
            $Uri
        }

        $raw = az rest --method get --uri $resolvedUri --resource $resourceManagerEndpoint --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorText = ($raw | Out-String).Trim()
            if ($AllowFailure) {
                return [pscustomobject]@{
                    Ok = $false
                    Uri = $resolvedUri
                    Error = $errorText
                    Data = $null
                }
            }

            if ($errorText -match "RBACAccessDenied") {
                throw @"
Azure Billing REST call failed because the signed-in identity does not currently have active RBAC/billing permission.

If your access is granted through PIM, activate the required role first, then force a fresh Azure CLI token:
  az logout
  az login --tenant <tenant-id>
  az account set --subscription <subscription-id>

Original Azure CLI response:
$errorText
"@
            }

            throw "az rest failed for $resolvedUri`n$errorText"
        }

        $data = if ([string]::IsNullOrWhiteSpace($raw)) { $null } else { $raw | ConvertFrom-Json }
        return [pscustomobject]@{
            Ok = $true
            Uri = $resolvedUri
            Error = $null
            Data = $data
        }
    }
    catch {
        if ($AllowFailure) {
            return [pscustomobject]@{
                Ok = $false
                Uri = $Uri
                Error = $_.Exception.Message
                Data = $null
            }
        }
        throw
    }
}

function Get-CollectionItems {
    param([AllowNull()]$Response)

    if ($null -eq $Response) {
        return @()
    }
    if ($Response.PSObject.Properties.Name -contains "value") {
        return @($Response.value)
    }

    return @($Response)
}

function Save-Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Object
    )

    $Object | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8
}

function Add-MarkdownTable {
    param(
        [AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string[]]$Headers,
        [AllowEmptyCollection()][object[]]$Rows = @()
    )

    $Lines.Add("| " + ($Headers -join " | ") + " |")
    $Lines.Add("| " + (($Headers | ForEach-Object { "---" }) -join " | ") + " |")

    if ($Rows.Count -eq 0) {
        $Lines.Add("| " + (($Headers | ForEach-Object { "" }) -join " | ") + " |")
        return
    }

    foreach ($row in $Rows) {
        $values = foreach ($header in $Headers) {
            $value = if ($row.PSObject.Properties.Name -contains $header) { $row.$header } else { "" }
            ((ConvertTo-AuditText $value) -replace "`r?`n", "<br>") -replace '\|', '\|'
        }
        $Lines.Add("| " + ($values -join " | ") + " |")
    }
}

function Export-AuditCsv {
    param(
        [Parameter(Mandatory)][string]$Path,

        [Parameter(Mandatory)][string[]]$Columns,

        [AllowEmptyCollection()][object[]]$Rows = @()
    )

    if ($Rows.Count -eq 0) {
        $header = ($Columns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ","
        Set-Content -Path $Path -Value $header -Encoding UTF8
        return
    }

    $Rows |
        Select-Object $Columns |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

Ensure-AzureCli
Set-AzureCloud -Name $AzureCloud
$azAccount = Ensure-AzureLogin

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$rawJsonDir = Join-Path $OutputDir "raw-json"
New-Item -ItemType Directory -Path $rawJsonDir -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
Save-Json -Path (Join-Path $rawJsonDir "az-account-show.json") -Object $azAccount

$billingAccountsResult = Invoke-AzRestJson -Uri "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=$ApiVersion" -AllowFailure
Save-Json -Path (Join-Path $rawJsonDir "billingAccounts.response.json") -Object $billingAccountsResult

$billingAccountRows = @()
$billingProfileRows = @()
$invoiceSectionRows = @()
$invoiceRows = @()
$roleAssignmentRows = @()
$subscriptionBillingRows = @()
$warningRows = @()

if (-not $billingAccountsResult.Ok) {
    $warningRows += [pscustomobject]@{
        Area = "Billing account discovery"
        Scope = "Microsoft.Billing/billingAccounts"
        Message = "The signed-in user could not enumerate billing accounts. For MCA/MPA, a Global Administrator may need to elevate or assign Billing account owner."
        Detail = $billingAccountsResult.Error
    }
}
else {
    foreach ($billingAccount in (Get-CollectionItems -Response $billingAccountsResult.Data)) {
        $billingAccountName = [string]$billingAccount.name
        $billingAccountId = [string]$billingAccount.id
        $safeBillingAccountName = ConvertTo-SafeFileName -Value $billingAccountName

        $accountDetailsResult = Invoke-AzRestJson -Uri "https://management.azure.com$billingAccountId?api-version=$ApiVersion" -AllowFailure
        Save-Json -Path (Join-Path $rawJsonDir "billingAccount.$safeBillingAccountName.json") -Object $accountDetailsResult
        $accountDetails = if ($accountDetailsResult.Ok -and $null -ne $accountDetailsResult.Data) { $accountDetailsResult.Data } else { $billingAccount }

        $billingAccountRows += [pscustomobject]@{
            BillingAccountName = $billingAccountName
            DisplayName = Get-PropertyValue $accountDetails @("properties", "displayName")
            AccountType = Get-PropertyValue $accountDetails @("properties", "accountType")
            AgreementType = Get-PropertyValue $accountDetails @("properties", "agreementType")
            Status = Get-PropertyValue $accountDetails @("properties", "billingAccountStatus")
            SoldTo = Get-PropertyValue $accountDetails @("properties", "soldTo")
            RegistrationNumber = Get-PropertyValue $accountDetails @("properties", "registrationNumber")
            RawJson = "raw-json/billingAccount.$safeBillingAccountName.json"
        }

        $rolesResult = Invoke-AzRestJson -Uri "https://management.azure.com$billingAccountId/billingRoleAssignments?api-version=$ApiVersion" -AllowFailure
        Save-Json -Path (Join-Path $rawJsonDir "billingAccount.$safeBillingAccountName.roleAssignments.json") -Object $rolesResult
        if ($rolesResult.Ok) {
            foreach ($role in (Get-CollectionItems -Response $rolesResult.Data)) {
                $roleAssignmentRows += [pscustomobject]@{
                    Scope = "Billing account"
                    BillingAccountName = $billingAccountName
                    Parent = ""
                    PrincipalId = Get-PropertyValue $role @("properties", "principalId")
                    PrincipalName = Get-PropertyValue $role @("properties", "principalName")
                    PrincipalEmail = Get-PropertyValue $role @("properties", "principalEmail")
                    RoleDefinitionId = Get-PropertyValue $role @("properties", "roleDefinitionId")
                    RoleAssignmentName = $role.name
                }
            }
        }

        $profilesResult = Invoke-AzRestJson -Uri "https://management.azure.com$billingAccountId/billingProfiles?api-version=$ApiVersion" -AllowFailure
        Save-Json -Path (Join-Path $rawJsonDir "billingAccount.$safeBillingAccountName.billingProfiles.json") -Object $profilesResult
        if (-not $profilesResult.Ok) {
            $warningRows += [pscustomobject]@{
                Area = "Billing profiles"
                Scope = $billingAccountName
                Message = "Could not enumerate billing profiles for this billing account."
                Detail = $profilesResult.Error
            }
            continue
        }

        foreach ($profile in (Get-CollectionItems -Response $profilesResult.Data)) {
            $profileName = [string]$profile.name
            $profileId = [string]$profile.id
            $safeProfileName = ConvertTo-SafeFileName -Value $profileName

            $billingProfileRows += [pscustomobject]@{
                BillingAccountName = $billingAccountName
                BillingProfileName = $profileName
                DisplayName = Get-PropertyValue $profile @("properties", "displayName")
                Status = Get-PropertyValue $profile @("properties", "status")
                BillTo = Get-PropertyValue $profile @("properties", "billTo")
                InvoiceEmailOptIn = Get-PropertyValue $profile @("properties", "invoiceEmailOptIn")
                InvoiceDay = Get-PropertyValue $profile @("properties", "invoiceDay")
                PoNumber = Get-PropertyValue $profile @("properties", "poNumber")
                Currency = Get-PropertyValue $profile @("properties", "currency")
                RawJson = "raw-json/billingAccount.$safeBillingAccountName.billingProfiles.json"
            }

            $profileRolesResult = Invoke-AzRestJson -Uri "https://management.azure.com$profileId/billingRoleAssignments?api-version=$ApiVersion" -AllowFailure
            Save-Json -Path (Join-Path $rawJsonDir "billingProfile.$safeBillingAccountName.$safeProfileName.roleAssignments.json") -Object $profileRolesResult
            if ($profileRolesResult.Ok) {
                foreach ($role in (Get-CollectionItems -Response $profileRolesResult.Data)) {
                    $roleAssignmentRows += [pscustomobject]@{
                        Scope = "Billing profile"
                        BillingAccountName = $billingAccountName
                        Parent = $profileName
                        PrincipalId = Get-PropertyValue $role @("properties", "principalId")
                        PrincipalName = Get-PropertyValue $role @("properties", "principalName")
                        PrincipalEmail = Get-PropertyValue $role @("properties", "principalEmail")
                        RoleDefinitionId = Get-PropertyValue $role @("properties", "roleDefinitionId")
                        RoleAssignmentName = $role.name
                    }
                }
            }

            $invoiceSectionsResult = Invoke-AzRestJson -Uri "https://management.azure.com$profileId/invoiceSections?api-version=$ApiVersion" -AllowFailure
            Save-Json -Path (Join-Path $rawJsonDir "billingProfile.$safeBillingAccountName.$safeProfileName.invoiceSections.json") -Object $invoiceSectionsResult
            if ($invoiceSectionsResult.Ok) {
                foreach ($invoiceSection in (Get-CollectionItems -Response $invoiceSectionsResult.Data)) {
                    $invoiceSectionRows += [pscustomobject]@{
                        BillingAccountName = $billingAccountName
                        BillingProfileName = $profileName
                        InvoiceSectionName = $invoiceSection.name
                        DisplayName = Get-PropertyValue $invoiceSection @("properties", "displayName")
                        State = Get-PropertyValue $invoiceSection @("properties", "state")
                        Labels = Get-PropertyValue $invoiceSection @("properties", "labels")
                        SystemId = Get-PropertyValue $invoiceSection @("properties", "systemId")
                        RawJson = "raw-json/billingProfile.$safeBillingAccountName.$safeProfileName.invoiceSections.json"
                    }
                }
            }

            if ($IncludeInvoices) {
                $invoicesResult = Invoke-AzRestJson -Uri "https://management.azure.com$profileId/invoices?api-version=$ApiVersion" -AllowFailure
                Save-Json -Path (Join-Path $rawJsonDir "billingProfile.$safeBillingAccountName.$safeProfileName.invoices.json") -Object $invoicesResult
                if ($invoicesResult.Ok) {
                    foreach ($invoice in ((Get-CollectionItems -Response $invoicesResult.Data) | Select-Object -First $RecentInvoiceLimit)) {
                        $invoiceRows += [pscustomobject]@{
                            BillingAccountName = $billingAccountName
                            BillingProfileName = $profileName
                            InvoiceName = $invoice.name
                            InvoiceDate = Get-PropertyValue $invoice @("properties", "invoiceDate")
                            DueDate = Get-PropertyValue $invoice @("properties", "dueDate")
                            Status = Get-PropertyValue $invoice @("properties", "status")
                            AmountDue = Get-PropertyValue $invoice @("properties", "amountDue")
                            BilledAmount = Get-PropertyValue $invoice @("properties", "billedAmount")
                            PoNumber = Get-PropertyValue $invoice @("properties", "poNumber")
                        }
                    }
                }
            }
        }
    }
}

$targetSubscriptions = @()
if ($SubscriptionId.Count -gt 0) {
    $targetSubscriptions = @($SubscriptionId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        [pscustomobject]@{
            subscriptionId = [string]$_
            displayName = ""
            state = ""
        }
    })
}
else {
    $subscriptionsResult = Invoke-AzRestJson -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01" -AllowFailure
    Save-Json -Path (Join-Path $rawJsonDir "subscriptions.response.json") -Object $subscriptionsResult
    if ($subscriptionsResult.Ok) {
        $targetSubscriptions = @(Get-CollectionItems -Response $subscriptionsResult.Data)
    }
    else {
        $warningRows += [pscustomobject]@{
            Area = "Subscriptions"
            Scope = "Microsoft.Resources/subscriptions"
            Message = "Could not enumerate subscriptions for subscription billing property review."
            Detail = $subscriptionsResult.Error
        }
    }
}

foreach ($subscription in $targetSubscriptions) {
    $subId = if ($subscription.subscriptionId) { [string]$subscription.subscriptionId } else { [string]$subscription.id }
    if ([string]::IsNullOrWhiteSpace($subId)) {
        continue
    }

    $safeSubId = ConvertTo-SafeFileName -Value $subId
    $billingPropertyResult = Invoke-AzRestJson -Uri "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Billing/billingProperty/default?api-version=$ApiVersion" -AllowFailure
    Save-Json -Path (Join-Path $rawJsonDir "subscription.$safeSubId.billingProperty.json") -Object $billingPropertyResult

    if (-not $billingPropertyResult.Ok) {
        $warningRows += [pscustomobject]@{
            Area = "Subscription billing property"
            Scope = $subId
            Message = "Could not read billing property for this subscription."
            Detail = $billingPropertyResult.Error
        }
    }

    $subscriptionBillingRows += [pscustomobject]@{
        SubscriptionName = $subscription.displayName
        SubscriptionId = $subId
        State = $subscription.state
        BillingAccountId = Get-PropertyValue $billingPropertyResult.Data @("properties", "billingAccountId")
        BillingProfileId = Get-PropertyValue $billingPropertyResult.Data @("properties", "billingProfileId")
        InvoiceSectionId = Get-PropertyValue $billingPropertyResult.Data @("properties", "invoiceSectionId")
        ProductId = Get-PropertyValue $billingPropertyResult.Data @("properties", "productId")
        ProductName = Get-PropertyValue $billingPropertyResult.Data @("properties", "productName")
        SkuId = Get-PropertyValue $billingPropertyResult.Data @("properties", "skuId")
        RawJson = "raw-json/subscription.$safeSubId.billingProperty.json"
    }
}

Export-AuditCsv -Path (Join-Path $OutputDir "billing-accounts.csv") -Columns @("BillingAccountName", "DisplayName", "AccountType", "AgreementType", "Status", "SoldTo", "RegistrationNumber", "RawJson") -Rows $billingAccountRows
Export-AuditCsv -Path (Join-Path $OutputDir "billing-profiles.csv") -Columns @("BillingAccountName", "BillingProfileName", "DisplayName", "Status", "BillTo", "InvoiceEmailOptIn", "InvoiceDay", "PoNumber", "Currency", "RawJson") -Rows $billingProfileRows
Export-AuditCsv -Path (Join-Path $OutputDir "invoice-sections.csv") -Columns @("BillingAccountName", "BillingProfileName", "InvoiceSectionName", "DisplayName", "State", "Labels", "SystemId", "RawJson") -Rows $invoiceSectionRows
Export-AuditCsv -Path (Join-Path $OutputDir "billing-role-assignments.csv") -Columns @("Scope", "BillingAccountName", "Parent", "PrincipalId", "PrincipalName", "PrincipalEmail", "RoleDefinitionId", "RoleAssignmentName") -Rows $roleAssignmentRows
Export-AuditCsv -Path (Join-Path $OutputDir "subscription-billing-properties.csv") -Columns @("SubscriptionName", "SubscriptionId", "State", "BillingAccountId", "BillingProfileId", "InvoiceSectionId", "ProductId", "ProductName", "SkuId", "RawJson") -Rows $subscriptionBillingRows
Export-AuditCsv -Path (Join-Path $OutputDir "billing-contact-audit-warnings.csv") -Columns @("Area", "Scope", "Message", "Detail") -Rows $warningRows
if ($IncludeInvoices) {
    Export-AuditCsv -Path (Join-Path $OutputDir "invoices.csv") -Columns @("BillingAccountName", "BillingProfileName", "InvoiceName", "InvoiceDate", "DueDate", "Status", "AmountDue", "BilledAmount", "PoNumber") -Rows $invoiceRows
}

Save-Json -Path (Join-Path $rawJsonDir "summary.billingAccounts.json") -Object $billingAccountRows
Save-Json -Path (Join-Path $rawJsonDir "summary.billingProfiles.json") -Object $billingProfileRows
Save-Json -Path (Join-Path $rawJsonDir "summary.invoiceSections.json") -Object $invoiceSectionRows
Save-Json -Path (Join-Path $rawJsonDir "summary.billingRoleAssignments.json") -Object $roleAssignmentRows
Save-Json -Path (Join-Path $rawJsonDir "summary.subscriptionBillingProperties.json") -Object $subscriptionBillingRows
Save-Json -Path (Join-Path $rawJsonDir "summary.warnings.json") -Object $warningRows
if ($IncludeInvoices) {
    Save-Json -Path (Join-Path $rawJsonDir "summary.invoices.json") -Object $invoiceRows
}

$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add("# Azure Billing Contact Audit")
$reportLines.Add("")
$reportLines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$reportLines.Add("")
$reportLines.Add("Signed-in Azure CLI user: **$($azAccount.user.name)**")
$reportLines.Add("")
$reportLines.Add("This report is read-only evidence for invoice recipient, legal payer identity, bill-to, sold-to, PO number, customer scope, and billing-role access review.")
$reportLines.Add("")
$reportLines.Add("## Review checklist")
$reportLines.Add("")
$reportLines.Add("- Search this report and the raw JSON files for Amentum, old Amentum domains, and Amentum mailbox aliases.")
$reportLines.Add("- Confirm SoldTo values identify the current customer legal entity.")
$reportLines.Add("- Confirm BillTo values and invoice contact/email fields identify current customer contacts and mailboxes.")
$reportLines.Add("- Confirm PoNumber values align to the current purchasing process.")
$reportLines.Add("- Confirm affected subscriptions point to the expected BillingProfileId and InvoiceSectionId.")
$reportLines.Add("- Confirm billing-role assignments are limited to current customer, Microsoft, and reseller administrators.")
$reportLines.Add("- If a CSP reseller controls the billing record, request Partner Center customer, account, order, MCA acceptance, reseller relationship, and reconciliation exports from the reseller.")
$reportLines.Add("")
$reportLines.Add("## Warnings")
$reportLines.Add("")
Add-MarkdownTable -Lines $reportLines -Headers @("Area", "Scope", "Message", "Detail") -Rows $warningRows
$reportLines.Add("")
$reportLines.Add("## Billing accounts")
$reportLines.Add("")
Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "DisplayName", "AccountType", "AgreementType", "Status", "SoldTo", "RegistrationNumber", "RawJson") -Rows $billingAccountRows
$reportLines.Add("")
$reportLines.Add("## Billing profiles")
$reportLines.Add("")
Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "BillingProfileName", "DisplayName", "Status", "BillTo", "InvoiceEmailOptIn", "InvoiceDay", "PoNumber", "Currency", "RawJson") -Rows $billingProfileRows
$reportLines.Add("")
$reportLines.Add("## Invoice sections")
$reportLines.Add("")
Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "BillingProfileName", "InvoiceSectionName", "DisplayName", "State", "Labels", "SystemId", "RawJson") -Rows $invoiceSectionRows
$reportLines.Add("")
if ($IncludeInvoices) {
    $reportLines.Add("## Recent invoices")
    $reportLines.Add("")
    Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "BillingProfileName", "InvoiceName", "InvoiceDate", "DueDate", "Status", "AmountDue", "BilledAmount", "PoNumber") -Rows $invoiceRows
    $reportLines.Add("")
}
$reportLines.Add("## Subscription billing properties")
$reportLines.Add("")
Add-MarkdownTable -Lines $reportLines -Headers @("SubscriptionName", "SubscriptionId", "State", "BillingAccountId", "BillingProfileId", "InvoiceSectionId", "ProductId", "ProductName", "SkuId", "RawJson") -Rows $subscriptionBillingRows
$reportLines.Add("")
$reportLines.Add("## Billing role assignments")
$reportLines.Add("")
Add-MarkdownTable -Lines $reportLines -Headers @("Scope", "BillingAccountName", "Parent", "PrincipalId", "PrincipalName", "PrincipalEmail", "RoleDefinitionId", "RoleAssignmentName") -Rows $roleAssignmentRows
$reportLines.Add("")

$reportPath = Join-Path $OutputDir "Azure-Billing-Contact-Audit-$timestamp.md"
$reportLines | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "Billing contact audit saved to: $OutputDir"
Write-Host "Report: $reportPath"
