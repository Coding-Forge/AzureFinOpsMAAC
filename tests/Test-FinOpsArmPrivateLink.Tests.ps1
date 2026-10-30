$ErrorActionPreference = "Stop"
$checkPath = Join-Path $PSScriptRoot "../scripts/Test-FinOpsArmPrivateLink.ps1"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-CheckFixture {
    param(
        [string]$Hostname = "10.40.2.10",
        [string[]]$ExpectedAddress = @("10.40.2.10"),
        [string]$ApiError = "",
        [string]$ErrorOnMethod = "GET",
        [object]$Response = @{ properties = @{ columns = @(@{ name = "Cost" }); rows = @() } },
        [datetime]$QueryDate = [datetime]::UtcNow.Date.AddDays(-1),
        [guid[]]$SubscriptionId = @("11111111-1111-1111-1111-111111111111")
    )

    $state = @{
        AuthenticationCount = 0
        Requests = [System.Collections.Generic.List[object]]::new()
        Results = @()
        Error = ""
    }

    # Numeric hostnames let the real .NET resolver run without external DNS.
    function Import-Module { param($Name, [switch]$Force) }
    function Get-FinOpsCloudProfile { @{ ResourceManagerUrl = "https://$Hostname/" } }
    function Connect-FinOpsNativeAccount { $state.AuthenticationCount++ }
    function Invoke-FinOpsArmRest {
        param($AzureCloud, $Method, $Path, $Body)
        $state.Requests.Add(@{ Method = $Method; Path = $Path; Body = $Body })
        if ($ApiError -and $Method -eq $ErrorOnMethod) { throw $ApiError }
        if ($Method -eq "POST") { return $Response }
        return @{ subscriptionId = $SubscriptionId[0] }
    }

    try {
        $state.Results = @(& $checkPath -ExpectedPrivateIpAddress $ExpectedAddress -SubscriptionId $SubscriptionId -QueryDate $QueryDate)
    }
    catch {
        $state.Error = $_.Exception.Message
    }
    return $state
}

$previousCloud = $env:FINOPS_AZURE_CLOUD
try {
    $env:FINOPS_AZURE_CLOUD = "AzureCloud"

    $result = Invoke-CheckFixture -SubscriptionId @(
        "11111111-1111-1111-1111-111111111111",
        "22222222-2222-2222-2222-222222222222"
    )
    Assert-True (-not $result.Error) "Approved endpoint check failed: $($result.Error)"
    Assert-True ($result.AuthenticationCount -eq 1 -and $result.Requests.Count -eq 4) "Every subscription must be read and queried."
    Assert-True ($result.Results.Count -eq 2) "An empty cost result must still count as an authorized query."
    foreach ($item in $result.Results) {
        Assert-True ($item.CostQuerySucceeded -and -not $item.PrivateTransportVerified) "DNS/API success must not claim private transport."
        Assert-True ($null -eq $item.PSObject.Properties["rows"]) "Diagnostics must not return cost rows."
    }
    $query = $result.Requests[1].Body
    Assert-True ($query.timePeriod.from.Substring(0, 10) -eq $query.timePeriod.to.Substring(0, 10)) "The query must be bounded to one day."
    Write-Host "PASS: approved endpoint, multiple subscriptions, empty results, bounded query, safe output"

    foreach ($hostname in @("203.0.113.1", "10.40.2.99")) {
        $result = Invoke-CheckFixture -Hostname $hostname
        Assert-True ($result.Error -like "*DNS does not resolve exclusively*") "Unexpected address was not rejected."
        Assert-True ($result.AuthenticationCount -eq 0 -and $result.Requests.Count -eq 0) "DNS mismatch must fail before authentication."
    }
    Write-Host "PASS: public and incorrect private DNS fail before authentication"

    foreach ($address in @("203.0.113.1", "127.0.0.1", "::1", "172.15.0.1", "172.32.0.1", "192.169.0.1")) {
        $result = Invoke-CheckFixture -ExpectedAddress @($address)
        Assert-True ($result.Error -like "*RFC1918*") "Invalid endpoint address was not rejected."
        Assert-True ($result.AuthenticationCount -eq 0 -and $result.Requests.Count -eq 0) "Invalid input must not trigger authentication."
    }
    Write-Host "PASS: public, loopback, and IPv6 expected addresses are rejected"

    foreach ($address in @("172.16.0.1", "172.31.255.254", "192.168.0.1")) {
        $result = Invoke-CheckFixture -Hostname $address -ExpectedAddress @($address)
        Assert-True (-not $result.Error) "Valid RFC1918 endpoint addresses must be accepted."
    }
    Write-Host "PASS: RFC1918 address-range boundaries"

    $result = Invoke-CheckFixture -ExpectedAddress @("10.40.2.10", "10.40.2.11")
    Assert-True (-not $result.Error) "DNS may resolve a subset of the endpoint's approved IPs."
    Write-Host "PASS: multiple approved endpoint IPs"

    $result = Invoke-CheckFixture -ApiError "HTTP 403 Forbidden"
    Assert-True ($result.Error -eq "HTTP 403 Forbidden" -and $result.Results.Count -eq 0) "Authorization failures must not be reported as success."
    Assert-True ($result.Requests.Count -eq 1) "Failed metadata access must stop before querying costs."
    Write-Host "PASS: authorization failure stops the check"

    $result = Invoke-CheckFixture -ApiError "HTTP 403 Forbidden" -ErrorOnMethod "POST"
    Assert-True ($result.Error -eq "HTTP 403 Forbidden" -and $result.Results.Count -eq 0) "Cost query authorization failures must not be reported as success."
    Assert-True ($result.Requests.Count -eq 2) "Failed cost queries must not try another endpoint."
    Write-Host "PASS: cost query failure does not fall back to another endpoint"

    $result = Invoke-CheckFixture -Response @{ properties = @{} }
    Assert-True ($result.Error -like "*valid query result*" -and $result.Results.Count -eq 0) "Malformed query responses must fail."
    Write-Host "PASS: malformed query response is rejected"

    $result = Invoke-CheckFixture -QueryDate ([datetime]::UtcNow.Date)
    Assert-True ($result.Error -like "*before today*" -and $result.AuthenticationCount -eq 0) "Incomplete/future query dates must fail before authentication."
    Write-Host "PASS: query date validation"

    $env:FINOPS_AZURE_CLOUD = "AzureUSGovernment"
    $result = Invoke-CheckFixture
    Assert-True ($result.Error -like "*Azure Commercial only*" -and $result.AuthenticationCount -eq 0) "Unvalidated sovereign-cloud checks must fail."
    Write-Host "PASS: Azure Commercial restriction"
}
finally {
    $env:FINOPS_AZURE_CLOUD = $previousCloud
}
