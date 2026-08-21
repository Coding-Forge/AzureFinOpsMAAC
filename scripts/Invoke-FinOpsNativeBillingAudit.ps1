<#
.SYNOPSIS
Exports Azure billing contact and ownership evidence using native Az.Accounts auth and ARM REST.

.DESCRIPTION
Enterprise-native replacement path for the Azure CLI billing audit. Uses
FinOpsNativeAuth.psm1 for Existing, ManagedIdentity, or ServicePrincipal auth,
then calls Microsoft.Billing REST APIs with Invoke-RestMethod.

The output file names and columns match the existing billing-contact-audit
folder shape so downstream durable history and Azure SQL loaders can reuse them.
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

    [string]$OutputDir = (Join-Path $PSScriptRoot "exports\billing-contact-audit"),

    [switch]$IncludeInvoices = ($env:FINOPS_INCLUDE_INVOICES -ne "false"),

    [int]$RecentInvoiceLimit = 12,

    [string]$ApiVersion = "2024-04-01",

    [string]$ClientId = $env:FINOPS_CLIENT_ID,

    [string]$ClientSecret = $env:FINOPS_CLIENT_SECRET,

    [string]$ManagedIdentityClientId = $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FinOpsNativeAuth.psm1") -Force

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
        if ($null -eq $cursor) { return $null }
        if ($cursor.PSObject.Properties.Name -notcontains $propertyName) { return $null }
        $cursor = $cursor.$propertyName
    }

    return $cursor
}

function ConvertTo-AuditText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) { return [string]$Value }
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Save-Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Object
    )

    $Object | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8
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

    $Rows | Select-Object $Columns | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Get-CollectionItems {
    param([AllowNull()]$Response)

    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties.Name -contains "value") { return @($Response.value) }
    return @($Response)
}

function Invoke-NativeBillingRest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowFailure
    )

    try {
        $data = Invoke-FinOpsArmRest -AzureCloud $AzureCloud -Method GET -Path $Path -MaxAttempts 5
        return [pscustomobject]@{
            Ok = $true
            Uri = $Path
            Error = $null
            Data = $data
        }
    }
    catch {
        if ($AllowFailure) {
            return [pscustomobject]@{
                Ok = $false
                Uri = $Path
                Error = $_.Exception.Message
                Data = $null
            }
        }
        throw
    }
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

Connect-FinOpsNativeAccount `
    -AzureCloud $AzureCloud `
    -AuthMode $AuthMode `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ClientSecret $ClientSecret `
    -ManagedIdentityClientId $ManagedIdentityClientId | Out-Null

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$rawJsonDir = Join-Path $OutputDir "raw-json"
New-Item -ItemType Directory -Path $rawJsonDir -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$billingAccountRows = @()
$billingProfileRows = @()
$invoiceSectionRows = @()
$invoiceRows = @()
$roleAssignmentRows = @()
$subscriptionBillingRows = @()
$warningRows = @()

$billingAccountsResult = Invoke-NativeBillingRest -Path "/providers/Microsoft.Billing/billingAccounts?api-version=$ApiVersion" -AllowFailure
Save-Json -Path (Join-Path $rawJsonDir "billingAccounts.response.json") -Object $billingAccountsResult

if (-not $billingAccountsResult.Ok) {
    $warningRows += [pscustomobject]@{
        Area = "Billing account discovery"
        Scope = "Microsoft.Billing/billingAccounts"
        Message = "The identity could not enumerate billing accounts."
        Detail = $billingAccountsResult.Error
    }
}
else {
    foreach ($billingAccount in (Get-CollectionItems -Response $billingAccountsResult.Data)) {
        $billingAccountName = [string]$billingAccount.name
        $billingAccountId = [string]$billingAccount.id
        $safeBillingAccountName = ConvertTo-SafeFileName -Value $billingAccountName

        $accountDetailsResult = Invoke-NativeBillingRest -Path "$billingAccountId?api-version=$ApiVersion" -AllowFailure
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

        $rolesResult = Invoke-NativeBillingRest -Path "$billingAccountId/billingRoleAssignments?api-version=$ApiVersion" -AllowFailure
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

        $profilesResult = Invoke-NativeBillingRest -Path "$billingAccountId/billingProfiles?api-version=$ApiVersion" -AllowFailure
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

            $profileRolesResult = Invoke-NativeBillingRest -Path "$profileId/billingRoleAssignments?api-version=$ApiVersion" -AllowFailure
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

            $invoiceSectionsResult = Invoke-NativeBillingRest -Path "$profileId/invoiceSections?api-version=$ApiVersion" -AllowFailure
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
                $invoicesResult = Invoke-NativeBillingRest -Path "$profileId/invoices?api-version=$ApiVersion" -AllowFailure
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
    $subscriptionsResult = Invoke-NativeBillingRest -Path "/subscriptions?api-version=2022-12-01" -AllowFailure
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
    if ([string]::IsNullOrWhiteSpace($subId)) { continue }

    $safeSubId = ConvertTo-SafeFileName -Value $subId
    $billingPropertyResult = Invoke-NativeBillingRest -Path "/subscriptions/$subId/providers/Microsoft.Billing/billingProperty/default?api-version=$ApiVersion" -AllowFailure
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
$reportLines.Add("Auth path: **Native Az.Accounts / ARM REST**")
$reportLines.Add("")
$reportLines.Add("## Billing accounts")
Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "DisplayName", "AccountType", "AgreementType", "Status", "SoldTo", "RegistrationNumber", "RawJson") -Rows $billingAccountRows
$reportLines.Add("")
$reportLines.Add("## Billing profiles")
Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "BillingProfileName", "DisplayName", "Status", "BillTo", "InvoiceEmailOptIn", "InvoiceDay", "PoNumber", "Currency", "RawJson") -Rows $billingProfileRows
$reportLines.Add("")
$reportLines.Add("## Invoice sections")
Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "BillingProfileName", "InvoiceSectionName", "DisplayName", "State", "Labels", "SystemId", "RawJson") -Rows $invoiceSectionRows
if ($IncludeInvoices) {
    $reportLines.Add("")
    $reportLines.Add("## Recent invoices")
    Add-MarkdownTable -Lines $reportLines -Headers @("BillingAccountName", "BillingProfileName", "InvoiceName", "InvoiceDate", "DueDate", "Status", "AmountDue", "BilledAmount", "PoNumber") -Rows $invoiceRows
}
$reportLines.Add("")
$reportLines.Add("## Subscription billing properties")
Add-MarkdownTable -Lines $reportLines -Headers @("SubscriptionName", "SubscriptionId", "State", "BillingAccountId", "BillingProfileId", "InvoiceSectionId", "ProductId", "ProductName", "SkuId", "RawJson") -Rows $subscriptionBillingRows
$reportLines.Add("")
$reportLines.Add("## Billing role assignments")
Add-MarkdownTable -Lines $reportLines -Headers @("Scope", "BillingAccountName", "Parent", "PrincipalId", "PrincipalName", "PrincipalEmail", "RoleDefinitionId", "RoleAssignmentName") -Rows $roleAssignmentRows
$reportLines.Add("")
$reportLines.Add("## Warnings")
Add-MarkdownTable -Lines $reportLines -Headers @("Area", "Scope", "Message", "Detail") -Rows $warningRows

$reportPath = Join-Path $OutputDir "Azure-Billing-Contact-Audit-$timestamp.md"
$reportLines | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "Native billing contact audit saved to: $OutputDir"
Write-Host "Report: $reportPath"
