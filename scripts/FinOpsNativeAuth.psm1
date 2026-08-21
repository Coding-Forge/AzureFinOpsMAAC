Set-StrictMode -Version Latest

function Get-FinOpsCloudProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$AzureCloud
    )

    switch ($AzureCloud) {
        "AzureCloud" {
            [pscustomobject]@{
                AzureCloud = "AzureCloud"
                EnvironmentName = "AzureCloud"
                ResourceManagerUrl = "https://management.azure.com/"
                SqlResourceUrl = "https://database.windows.net/"
                AuthorityHost = "https://login.microsoftonline.com/"
            }
        }
        "AzureUSGovernment" {
            [pscustomobject]@{
                AzureCloud = "AzureUSGovernment"
                EnvironmentName = "AzureUSGovernment"
                ResourceManagerUrl = "https://management.usgovcloudapi.net/"
                SqlResourceUrl = "https://database.usgovcloudapi.net/"
                AuthorityHost = "https://login.microsoftonline.us/"
            }
        }
    }
}

function Assert-FinOpsAzAccounts {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw "Az.Accounts is required for native enterprise auth. Install with: Install-Module Az.Accounts -Scope CurrentUser"
    }
}

function Connect-FinOpsNativeAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$AzureCloud,

        [ValidateSet("Existing", "ManagedIdentity", "ServicePrincipal")]
        [string]$AuthMode = "Existing",

        [string]$TenantId,

        [string]$ClientId,

        [string]$ClientSecret,

        [string]$ManagedIdentityClientId
    )

    Assert-FinOpsAzAccounts
    Import-Module Az.Accounts -ErrorAction Stop

    $profile = Get-FinOpsCloudProfile -AzureCloud $AzureCloud

    switch ($AuthMode) {
        "Existing" {
            $context = Get-AzContext -ErrorAction SilentlyContinue
            if (-not $context) {
                throw "AuthMode=Existing requires an existing Az.Accounts context. Use Connect-AzAccount first, or choose ManagedIdentity/ServicePrincipal."
            }
            if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
                Write-Warning "Current Az context tenant is $($context.Tenant.Id), expected $TenantId."
            }
            return $context
        }
        "ManagedIdentity" {
            $args = @{
                Identity = $true
                Environment = $profile.EnvironmentName
            }
            if ($TenantId) { $args.Tenant = $TenantId }
            if ($ManagedIdentityClientId) { $args.AccountId = $ManagedIdentityClientId }
            return Connect-AzAccount @args
        }
        "ServicePrincipal" {
            if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($ClientSecret)) {
                throw "ServicePrincipal auth requires TenantId, ClientId, and ClientSecret."
            }
            $secureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
            $credential = [pscredential]::new($ClientId, $secureSecret)
            return Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential -Environment $profile.EnvironmentName
        }
    }
}

function Get-FinOpsAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$AzureCloud,

        [Parameter(Mandatory)]
        [ValidateSet("Arm", "Sql")]
        [string]$Resource
    )

    Assert-FinOpsAzAccounts
    Import-Module Az.Accounts -ErrorAction Stop

    $profile = Get-FinOpsCloudProfile -AzureCloud $AzureCloud
    $resourceUrl = if ($Resource -eq "Sql") { $profile.SqlResourceUrl } else { $profile.ResourceManagerUrl }
    $token = Get-AzAccessToken -ResourceUrl $resourceUrl -ErrorAction Stop

    if ($token.Token -is [securestring]) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token.Token)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    return [string]$token.Token
}

function Invoke-FinOpsArmRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$AzureCloud,

        [Parameter(Mandatory)]
        [ValidateSet("GET", "POST", "PUT", "PATCH", "DELETE")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body,

        [int]$MaxAttempts = 5
    )

    $profile = Get-FinOpsCloudProfile -AzureCloud $AzureCloud
    $baseUri = $profile.ResourceManagerUrl.TrimEnd("/")
    $uri = if ($Path -match "^https?://") { $Path } else { "$baseUri/$($Path.TrimStart('/'))" }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $token = Get-FinOpsAccessToken -AzureCloud $AzureCloud -Resource Arm
        $headers = @{
            Authorization = "Bearer $token"
            "Content-Type" = "application/json"
        }

        try {
            $invokeArgs = @{
                Uri = $uri
                Method = $Method
                Headers = $headers
                ErrorAction = "Stop"
            }
            if ($null -ne $Body) {
                $invokeArgs.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 }
            }

            return Invoke-RestMethod @invokeArgs
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $retryable = $statusCode -in @(408, 429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            $retryAfterSeconds = $null
            $retryAfterValues = $null
            if ($_.Exception.Response -and $_.Exception.Response.Headers.TryGetValues("Retry-After", [ref]$retryAfterValues)) {
                $retryAfterValue = @($retryAfterValues)[0]
                [int]$parsedRetryAfter = 0
                if ($retryAfterValue -and [int]::TryParse([string]$retryAfterValue, [ref]$parsedRetryAfter)) {
                    $retryAfterSeconds = $parsedRetryAfter
                }
            }

            $backoffSeconds = if ($null -ne $retryAfterSeconds) {
                [Math]::Min(120, $retryAfterSeconds)
            }
            else {
                [Math]::Min(60, [Math]::Pow(2, $attempt))
            }

            Write-Host "Request to $uri returned $statusCode; retrying in $backoffSeconds second(s) (attempt $attempt of $MaxAttempts)."
            Start-Sleep -Seconds $backoffSeconds
        }
    }
}

function Get-FinOpsNativeSubscriptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("AzureCloud", "AzureUSGovernment")]
        [string]$AzureCloud,

        [string]$TenantId
    )

    $result = Invoke-FinOpsArmRest -AzureCloud $AzureCloud -Method GET -Path "/subscriptions?api-version=2022-12-01"
    $subscriptions = @($result.value)
    if ($TenantId) {
        # The ARM subscriptions list does not always include tenantId. Tenant filtering is applied by auth context.
        Write-Verbose "TenantId was provided; ensure the native auth context is connected to tenant $TenantId."
    }

    return @($subscriptions | Sort-Object displayName)
}

Export-ModuleMember -Function @(
    "Get-FinOpsCloudProfile",
    "Connect-FinOpsNativeAccount",
    "Get-FinOpsAccessToken",
    "Invoke-FinOpsArmRest",
    "Get-FinOpsNativeSubscriptions"
)
