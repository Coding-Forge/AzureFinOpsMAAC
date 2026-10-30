<#
.SYNOPSIS
Checks ARM private DNS and authorized Cost Management access from the workload.

.DESCRIPTION
Run inside the Function execution environment. Expected IPs must come from the
approved ARM private endpoint NIC, not from DNS. This read-only check does not
prove private transport or enforce egress policy; retain network evidence and
repeat with public ARM egress denied before accepting a private-only deployment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ipaddress[]]$ExpectedPrivateIpAddress,

    [Parameter(Mandatory)]
    [guid[]]$SubscriptionId,

    [ValidateSet("Existing", "ManagedIdentity")]
    [string]$AuthMode = "ManagedIdentity",

    [string]$TenantId = $env:FINOPS_TENANT_ID,

    [string]$ManagedIdentityClientId = $env:FINOPS_MANAGED_IDENTITY_CLIENT_ID,

    [datetime]$QueryDate = [datetime]::UtcNow.Date.AddDays(-1)
)

$ErrorActionPreference = "Stop"

if ($env:FINOPS_AZURE_CLOUD -and $env:FINOPS_AZURE_CLOUD -ne "AzureCloud") {
    throw "This ARM Private Link check supports Azure Commercial only."
}

$expectedAddresses = @($ExpectedPrivateIpAddress | ForEach-Object {
    $bytes = $_.GetAddressBytes()
    $isPrivate = $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and (
        $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    )
    if (-not $isPrivate) {
        throw "ExpectedPrivateIpAddress must contain only the approved endpoint's RFC1918 IPv4 addresses."
    }
    $_.ToString()
})

Import-Module (Join-Path $PSScriptRoot "FinOpsNativeAuth.psm1") -Force

$profile = Get-FinOpsCloudProfile -AzureCloud AzureCloud
$armHostname = ([uri]$profile.ResourceManagerUrl).DnsSafeHost
$resolvedAddresses = @([System.Net.Dns]::GetHostAddresses($armHostname) | ForEach-Object { $_.ToString() })
if ($resolvedAddresses.Count -eq 0 -or @($resolvedAddresses | Where-Object { $_ -notin $expectedAddresses }).Count -gt 0) {
    throw "ARM DNS does not resolve exclusively to the approved endpoint IPs. No authenticated API call was attempted."
}

if ($QueryDate.Date -ge [datetime]::UtcNow.Date) {
    throw "QueryDate must be before today (UTC)."
}

$null = Connect-FinOpsNativeAccount `
    -AzureCloud AzureCloud `
    -AuthMode $AuthMode `
    -TenantId $TenantId `
    -ManagedIdentityClientId $ManagedIdentityClientId

$body = @{
    type = "ActualCost"
    timeframe = "Custom"
    timePeriod = @{
        from = $QueryDate.Date.ToString("yyyy-MM-ddT00:00:00Z")
        to = $QueryDate.Date.ToString("yyyy-MM-ddT23:59:59Z")
    }
    dataset = @{
        granularity = "Daily"
        aggregation = @{
            totalCost = @{ name = "Cost"; function = "Sum" }
            totalQuantity = @{ name = "UsageQuantity"; function = "Sum" }
        }
        grouping = @(
            @{ type = "Dimension"; name = "ServiceName" }
            @{ type = "Dimension"; name = "ResourceGroupName" }
        )
    }
}

foreach ($id in $SubscriptionId) {
    $null = Invoke-FinOpsArmRest -AzureCloud AzureCloud -Method GET -Path "/subscriptions/${id}?api-version=2022-12-01"
    $response = Invoke-FinOpsArmRest `
        -AzureCloud AzureCloud `
        -Method POST `
        -Path "/subscriptions/$id/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
        -Body $body

    if ($null -eq $response.properties -or $null -eq $response.properties.columns -or $null -eq $response.properties.rows) {
        throw "Cost Management did not return a valid query result."
    }

    [pscustomobject]@{
        ArmHostname = $armHostname
        ResolvedIpAddresses = $resolvedAddresses
        SubscriptionId = $id
        QueryDate = $QueryDate.Date.ToString("yyyy-MM-dd")
        SubscriptionReadSucceeded = $true
        CostQuerySucceeded = $true
        PrivateTransportVerified = $false
    }
}
