<#
.SYNOPSIS
Validates native enterprise authentication without using Azure CLI for ARM calls.
#>
[CmdletBinding()]
param(
    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = "AzureCloud",

    [ValidateSet("Existing", "ManagedIdentity", "ServicePrincipal")]
    [string]$AuthMode = "Existing",

    [string]$TenantId,

    [string]$ClientId,

    [string]$ClientSecret,

    [string]$ManagedIdentityClientId
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FinOpsNativeAuth.psm1") -Force

$context = Connect-FinOpsNativeAccount `
    -AzureCloud $AzureCloud `
    -AuthMode $AuthMode `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ClientSecret $ClientSecret `
    -ManagedIdentityClientId $ManagedIdentityClientId

$profile = Get-FinOpsCloudProfile -AzureCloud $AzureCloud
$armToken = Get-FinOpsAccessToken -AzureCloud $AzureCloud -Resource Arm
$sqlToken = Get-FinOpsAccessToken -AzureCloud $AzureCloud -Resource Sql
$subscriptions = @(Get-FinOpsNativeSubscriptions -AzureCloud $AzureCloud -TenantId $TenantId)

[pscustomobject]@{
    AzureCloud = $AzureCloud
    ResourceManagerUrl = $profile.ResourceManagerUrl
    SqlResourceUrl = $profile.SqlResourceUrl
    Account = $context.Account.Id
    Tenant = $context.Tenant.Id
    ArmTokenAvailable = -not [string]::IsNullOrWhiteSpace($armToken)
    SqlTokenAvailable = -not [string]::IsNullOrWhiteSpace($sqlToken)
    SubscriptionCount = $subscriptions.Count
    Subscriptions = @($subscriptions | ForEach-Object {
        [pscustomobject]@{
            SubscriptionId = $_.subscriptionId
            DisplayName = $_.displayName
            State = $_.state
        }
    })
}
