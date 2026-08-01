<#
.SYNOPSIS
Pulls Azure Cost Management actual-cost data and saves JSON/CSV exports.

.DESCRIPTION
This script reproduces the cost-analysis pull performed from this machine:
- verifies Azure CLI is available, optionally installing it with winget
- signs in with device-code flow when no Azure context exists
- optionally sets the tenant and subscription context
- queries Cost Management for month-to-date and prior-month actual costs
- exports raw JSON, detailed CSV, summary CSV files, and Retail Prices join/enrichment files

.EXAMPLE
.\Get-CostAnalysis.ps1 -SubscriptionId "c3454f9a-72a4-473e-b7ab-4e9b1107fd6d"

.EXAMPLE
.\Get-CostAnalysis.ps1

.EXAMPLE
.\Get-CostAnalysis.ps1 -SubscriptionId "<sub-id-1>","<sub-id-2>"

.EXAMPLE
.\Get-CostAnalysis.ps1 -TenantId "<tenant-id>" -SubscriptionId "<subscription-id>" -InstallAzureCli
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = "AzureCloud",

    [string[]]$SubscriptionId,

    [string]$OutputDir = (Join-Path $PSScriptRoot "exports"),

    [datetime]$AsOfDate = (Get-Date),

    [datetime]$CustomStartDate = [datetime]::MinValue,

    [datetime]$CustomEndDate = [datetime]::MinValue,

    [switch]$InstallAzureCli,

    [switch]$SkipRetailPriceLookup
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
        throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows or rerun this script with -InstallAzureCli."
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
        return
    }

    Write-Host "No Azure login found. Starting device-code sign-in..."
    $loginArgs = @("login", "--use-device-code", "--allow-no-subscriptions", "--output", "json")
    if ($TenantId) {
        $loginArgs += @("--tenant", $TenantId)
    }

    az @loginArgs | Out-Null
}

function Get-TargetSubscriptions {
    param(
        [string]$TenantId,
        [string[]]$RequestedSubscriptionIds
    )

    $allSubscriptions = @(az account list --all --output json | ConvertFrom-Json)
    if (-not $allSubscriptions -or $allSubscriptions.Count -eq 0) {
        throw "No Azure subscriptions are visible for the current identity."
    }

    $enabledSubscriptions = @($allSubscriptions | Where-Object { $_.state -eq "Enabled" })
    if ($TenantId) {
        $enabledSubscriptions = @($enabledSubscriptions | Where-Object { $_.tenantId -eq $TenantId })
    }

    if (-not $enabledSubscriptions -or $enabledSubscriptions.Count -eq 0) {
        if ($TenantId) {
            throw "No enabled subscriptions were found for tenant '$TenantId'."
        }
        throw "No enabled subscriptions were found for the current identity."
    }

    $selectedSubscriptions = @()
    if ($RequestedSubscriptionIds -and $RequestedSubscriptionIds.Count -gt 0) {
        $requestedSet = @{}
        foreach ($id in $RequestedSubscriptionIds) {
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $requestedSet[$id.Trim().ToLowerInvariant()] = $true
            }
        }

        $selectedSubscriptions = @(
            $enabledSubscriptions | Where-Object {
                $requestedSet.ContainsKey(([string]$_.id).ToLowerInvariant())
            }
        )

        $foundSet = @{}
        foreach ($sub in $selectedSubscriptions) {
            $foundSet[([string]$sub.id).ToLowerInvariant()] = $true
        }

        $missing = @(
            $requestedSet.Keys | Where-Object { -not $foundSet.ContainsKey($_) }
        )

        foreach ($missingId in @($missing)) {
            az account set --subscription $missingId 2>$null
            if ($LASTEXITCODE -eq 0) {
                $subscriptionJson = az account show --output json 2>$null
                if ($LASTEXITCODE -eq 0 -and $subscriptionJson) {
                    $subscription = $subscriptionJson | ConvertFrom-Json
                    if ($subscription.state -eq "Enabled" -and (-not $TenantId -or $subscription.tenantId -eq $TenantId)) {
                        $selectedSubscriptions += $subscription
                        $foundSet[([string]$subscription.id).ToLowerInvariant()] = $true
                    }
                }
            }
        }

        $missing = @(
            $requestedSet.Keys | Where-Object { -not $foundSet.ContainsKey($_) }
        )

        if ($missing.Count -gt 0) {
            $currentCloud = az cloud show --query name --output tsv 2>$null
            $visibleSubscriptionIds = @($enabledSubscriptions | ForEach-Object { "$($_.name) [$($_.id)] tenant=$($_.tenantId)" })
            throw "These subscription IDs were not found or are not enabled/accessible in Azure cloud '$currentCloud': $($missing -join ', '). Visible enabled subscriptions: $($visibleSubscriptionIds -join '; ')"
        }
    }
    else {
        $selectedSubscriptions = $enabledSubscriptions
    }

    if (-not $selectedSubscriptions -or $selectedSubscriptions.Count -eq 0) {
        throw "No target subscriptions were selected."
    }

    Write-Host "Target subscriptions ($($selectedSubscriptions.Count)):"
    $selectedSubscriptions |
        Sort-Object name |
        Select-Object @{ Name = "SubscriptionName"; Expression = { $_.name } },
                      @{ Name = "SubscriptionId"; Expression = { $_.id } },
                      @{ Name = "TenantId"; Expression = { $_.tenantId } } |
        Format-Table -AutoSize |
        Out-String -Width 240 |
        Write-Host

    return @($selectedSubscriptions)
}

function Set-AzureContextSubscription {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    az account set --subscription $SubscriptionId
}

function Convert-CostResponseToCsv {
    param(
        [Parameter(Mandatory)]
        [string]$JsonPath,

        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    $json = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $columns = @($json.properties.columns | ForEach-Object { $_.name })
    $rows = @($json.properties.rows | ForEach-Object {
        $row = $_
        $object = [ordered]@{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $object[$columns[$i]] = $row[$i]
        }
        [pscustomobject]$object
    })

    $rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    return $rows
}

function Normalize-LocationKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return ($Value.ToLowerInvariant() -replace "[^a-z0-9]", "")
}

function Get-ArmRegionNameLookup {
    $locations = @(az account list-locations --output json | ConvertFrom-Json)
    $lookup = @{}

    foreach ($location in $locations) {
        $keys = @(
            $location.name,
            $location.displayName,
            $location.regionalDisplayName,
            $location.metadata.physicalLocation
        )

        foreach ($key in $keys) {
            $normalized = Normalize-LocationKey $key
            if ($normalized) {
                $lookup[$normalized] = $location.name
            }
        }

        # Cost Management commonly returns "us west 3"; Retail Prices expects "westus3".
        $displayName = [string]$location.displayName
        if ($displayName -match "^(?<direction>East|West|North|South|Central)\s+US(?<suffix>.*)$") {
            $alternate = "US $($Matches.direction)$($Matches.suffix)"
            $lookup[(Normalize-LocationKey $alternate)] = $location.name
        }
    }

    $lookup["global"] = "global"
    return $lookup
}

function Convert-CostManagementLocationToArmRegionName {
    param([string]$ResourceLocation)

    if ([string]::IsNullOrWhiteSpace($ResourceLocation)) {
        return $ResourceLocation
    }

    $value = $ResourceLocation.Trim().ToLowerInvariant()
    if ($value -match "^us\s+(?<direction>east|west|north|south|central)(?<suffix>.*)$") {
        $suffix = ($Matches.suffix -replace "[^a-z0-9]", "")
        return "$($Matches.direction)us$suffix"
    }

    if ($value -match "^us\s+gov\s+(?<region>virginia|arizona|texas)$") {
        return "usgov$($Matches.region)"
    }

    if ($value -match "^us\s+dod\s+(?<region>central|east)$") {
        return "usdod$($Matches.region)"
    }

    return $ResourceLocation
}

function Get-FinOpsAzureRegionMap {
    $regionCsv = @'
Display Name,Azure Region,Azure Cloud
Australia Central,australiacentral,Azure Commercial
Australia Central 2,australiacentral2,Azure Commercial
Australia East,australiaeast,Azure Commercial
Australia Southeast,australiasoutheast,Azure Commercial
Austria East,austriaeast,Azure Commercial
Belgium Central,belgiumcentral,Azure Commercial
Brazil South,brazilsouth,Azure Commercial
Brazil Southeast,brazilsoutheast,Azure Commercial
Canada Central,canadacentral,Azure Commercial
Canada East,canadaeast,Azure Commercial
Central India,centralindia,Azure Commercial
South India,southindia,Azure Commercial
India South Central,indiasouthcentral,Azure Commercial
West India,westindia,Azure Commercial
Central US,centralus,Azure Commercial
East US,eastus,Azure Commercial
East US 2,eastus2,Azure Commercial
North Central US,northcentralus,Azure Commercial
South Central US,southcentralus,Azure Commercial
West Central US,westcentralus,Azure Commercial
West US,westus,Azure Commercial
West US 2,westus2,Azure Commercial
West US 3,westus3,Azure Commercial
Chile Central,chilecentral,Azure Commercial
Denmark East,denmarkeast,Azure Commercial
East Asia,eastasia,Azure Commercial
Southeast Asia,southeastasia,Azure Commercial
France Central,francecentral,Azure Commercial
France South,francesouth,Azure Commercial
Germany North,germanynorth,Azure Commercial
Germany West Central,germanywestcentral,Azure Commercial
Indonesia Central,indonesiacentral,Azure Commercial
Israel Central,israelcentral,Azure Commercial
Italy North,italynorth,Azure Commercial
Japan East,japaneast,Azure Commercial
Japan West,japanwest,Azure Commercial
Korea Central,koreacentral,Azure Commercial
Korea South,koreasouth,Azure Commercial
Malaysia West,malaysiawest,Azure Commercial
Mexico Central,mexicocentral,Azure Commercial
New Zealand North,newzealandnorth,Azure Commercial
North Europe,northeurope,Azure Commercial
West Europe,westeurope,Azure Commercial
Norway East,norwayeast,Azure Commercial
Norway West,norwaywest,Azure Commercial
Poland Central,polandcentral,Azure Commercial
Qatar Central,qatarcentral,Azure Commercial
South Africa North,southafricanorth,Azure Commercial
South Africa West,southafricawest,Azure Commercial
Spain Central,spaincentral,Azure Commercial
Sweden Central,swedencentral,Azure Commercial
Sweden South,swedensouth,Azure Commercial
Switzerland North,switzerlandnorth,Azure Commercial
Switzerland West,switzerlandwest,Azure Commercial
Taiwan North,taiwannorth,Azure Commercial
UAE Central,uaecentral,Azure Commercial
UAE North,uaenorth,Azure Commercial
UK South,uksouth,Azure Commercial
UK West,ukwest,Azure Commercial
Arizona,usgovarizona,Azure Government
Texas,usgovtexas,Azure Government
Virginia,usgovvirginia,Azure Government
Iowa (DoD Central),usdodcentral,Azure Government
Texas (DoD East),usdodeast,Azure Government
China East,chinaeast,Azure China (21Vianet)
China East 2,chinaeast2,Azure China (21Vianet)
China East 3,chinaeast3,Azure China (21Vianet)
China North,chinanorth,Azure China (21Vianet)
China North 2,chinanorth2,Azure China (21Vianet)
China North 3,chinanorth3,Azure China (21Vianet)
'@

    return @($regionCsv | ConvertFrom-Csv)
}

function Get-FinOpsRegionInfo {
    param(
        [string]$AzureRegionName,
        [string]$ResourceLocation
    )

    $normalized = Normalize-LocationKey $AzureRegionName
    $mapped = Get-FinOpsAzureRegionMap | Where-Object { (Normalize-LocationKey $_.'Azure Region') -eq $normalized } | Select-Object -First 1
    if ($mapped) {
        return $mapped
    }

    $displayName = if (-not [string]::IsNullOrWhiteSpace($ResourceLocation)) {
        (Get-Culture).TextInfo.ToTitleCase(([string]$ResourceLocation).Trim().ToLowerInvariant())
    }
    else {
        $AzureRegionName
    }

    return [pscustomobject][ordered]@{
        "Display Name" = $displayName
        "Azure Region" = $AzureRegionName
        "Azure Cloud" = "Azure Commercial"
    }
}

function Add-ArmRegionName {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [hashtable]$LocationLookup
    )

    foreach ($row in $Rows) {
        $resourceLocation = [string]$row.ResourceLocation
        $normalized = Normalize-LocationKey $resourceLocation
        $armRegionName = if ($LocationLookup.ContainsKey($normalized)) { $LocationLookup[$normalized] } else { Convert-CostManagementLocationToArmRegionName $resourceLocation }

        $row | Add-Member -NotePropertyName ArmRegionName -NotePropertyValue $armRegionName -Force
        $row
    }
}

function New-ODataStringLiteral {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-RestRetryDelaySeconds {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [int]$Attempt
    )

    $retryAfter = $null
    if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.Headers) {
        $retryAfter = $ErrorRecord.Exception.Response.Headers["Retry-After"]
    }

    if (-not [string]::IsNullOrWhiteSpace($retryAfter)) {
        $retryAfterSeconds = 0
        if ([int]::TryParse($retryAfter, [ref]$retryAfterSeconds) -and $retryAfterSeconds -gt 0) {
            return [Math]::Min(300, $retryAfterSeconds)
        }

        $retryAfterDate = [datetime]::MinValue
        if ([datetime]::TryParse($retryAfter, [ref]$retryAfterDate)) {
            $secondsUntilRetry = [int][Math]::Ceiling(($retryAfterDate.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalSeconds)
            if ($secondsUntilRetry -gt 0) {
                return [Math]::Min(300, $secondsUntilRetry)
            }
        }
    }

    return [Math]::Min(120, [Math]::Pow(2, $Attempt) * 5)
}

function Invoke-RestMethodWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$Method = "Get",

        [int]$MaxAttempts = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method $Method
        }
        catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
            $message = $_.Exception.Message
            $isRetryable = $statusCode -eq 429 -or $statusCode -in @(500, 502, 503, 504) -or $message -match "Too many requests|Too Many Requests|temporarily unavailable|timeout|timed out"

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            $delaySeconds = Get-RestRetryDelaySeconds -ErrorRecord $_ -Attempt $attempt
            Write-Warning "Retail Prices API request was throttled or temporarily unavailable. Retrying in $delaySeconds seconds. Attempt $attempt of $MaxAttempts."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-RetailPriceCandidates {
    param(
        [string]$ServiceName,
        [string]$MeterName,
        [string]$ArmRegionName,
        [string]$UnitOfMeasure,
        [hashtable]$Cache
    )

    $cacheKey = "$ServiceName|$MeterName|$ArmRegionName|$UnitOfMeasure"
    if ($Cache.ContainsKey($cacheKey)) {
        return @($Cache[$cacheKey])
    }

    $filters = @()
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
        $filters += "serviceName eq $(New-ODataStringLiteral $ServiceName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($MeterName)) {
        $filters += "meterName eq $(New-ODataStringLiteral $MeterName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ArmRegionName)) {
        $filters += "armRegionName eq $(New-ODataStringLiteral $ArmRegionName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($UnitOfMeasure)) {
        $filters += "unitOfMeasure eq $(New-ODataStringLiteral $UnitOfMeasure)"
    }

    if ($filters.Count -eq 0) {
        $Cache[$cacheKey] = @()
        return @()
    }

    $filter = $filters -join " and "
    $url = "https://prices.azure.com/api/retail/prices?`$filter=$([uri]::EscapeDataString($filter))"
    $items = @()

    do {
        $response = Invoke-RestMethodWithRetry -Uri $url -Method Get
        $items += @($response.Items)
        $url = $response.NextPageLink
    } while ($url)

    $Cache[$cacheKey] = @($items)
    return @($items)
}

function Select-BestRetailPriceMatch {
    param(
        [Parameter(Mandatory)]
        [object]$CostRow,

        [object[]]$Candidates
    )

    if (-not $Candidates -or $Candidates.Count -eq 0) {
        return [pscustomobject]@{ MatchStatus = "NoMatch"; CandidateCount = 0; Item = $null }
    }

    $costProduct = ([string]$CostRow.Product).ToLowerInvariant()
    $ranked = @($Candidates | ForEach-Object {
        $score = 0
        if ($costProduct -and $_.productName -and $costProduct.Contains(([string]$_.productName).ToLowerInvariant())) {
            $score += 10
        }
        if ($costProduct -and $_.skuName -and $costProduct.Contains(([string]$_.skuName).ToLowerInvariant())) {
            $score += 5
        }
        [pscustomobject]@{ Score = $score; Item = $_ }
    } | Sort-Object Score -Descending)

    $bestScore = $ranked[0].Score
    $bestItems = @($ranked | Where-Object Score -eq $bestScore | ForEach-Object { $_.Item })
    $uniqueSkuIds = @($bestItems | Select-Object -ExpandProperty skuId -Unique)
    $uniqueMeterIds = @($bestItems | Select-Object -ExpandProperty meterId -Unique)
    $status = if ($bestItems.Count -eq 1 -or ($uniqueSkuIds.Count -eq 1 -and $uniqueMeterIds.Count -eq 1)) { "Matched" } else { "MultipleCandidates" }

    return [pscustomobject]@{
        MatchStatus = $status
        CandidateCount = $Candidates.Count
        Item = ($bestItems | Select-Object -First 1)
    }
}

function Add-RetailPriceData {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    $cache = @{}
    $index = 0
    $total = $Rows.Count

    foreach ($row in $Rows) {
        $index++
        if (($index % 25) -eq 0 -or $index -eq 1 -or $index -eq $total) {
            Write-Host "Retail Prices lookup progress: $index / $total"
        }

        $candidates = Get-RetailPriceCandidates `
            -ServiceName $row.ServiceName `
            -MeterName $row.Meter `
            -ArmRegionName $row.ArmRegionName `
            -UnitOfMeasure $row.UnitOfMeasure `
            -Cache $cache

        $match = Select-BestRetailPriceMatch -CostRow $row -Candidates $candidates
        $item = $match.Item

        $row | Add-Member -NotePropertyName RetailMatchStatus -NotePropertyValue $match.MatchStatus -Force
        $row | Add-Member -NotePropertyName RetailCandidateCount -NotePropertyValue $match.CandidateCount -Force
        $row | Add-Member -NotePropertyName RetailSkuId -NotePropertyValue $(if ($item) { $item.skuId } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailMeterId -NotePropertyValue $(if ($item) { $item.meterId } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailProductId -NotePropertyValue $(if ($item) { $item.productId } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailProductName -NotePropertyValue $(if ($item) { $item.productName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailSkuName -NotePropertyValue $(if ($item) { $item.skuName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailMeterName -NotePropertyValue $(if ($item) { $item.meterName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailArmRegionName -NotePropertyValue $(if ($item) { $item.armRegionName } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailUnitOfMeasure -NotePropertyValue $(if ($item) { $item.unitOfMeasure } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailPrice -NotePropertyValue $(if ($item) { $item.retailPrice } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailUnitPrice -NotePropertyValue $(if ($item) { $item.unitPrice } else { $null }) -Force
        $row | Add-Member -NotePropertyName RetailCurrencyCode -NotePropertyValue $(if ($item) { $item.currencyCode } else { $null }) -Force
        $row
    }
}

function Invoke-AzRestWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$BodyPath,

        [int]$MaxAttempts = 8
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $resourceManagerEndpoint = Get-AzureResourceManagerEndpoint
        $args = @("rest", "--method", $Method, "--uri", $Uri, "--resource", $resourceManagerEndpoint, "--output", "json")
        if ($BodyPath) {
            $args += @("--body", "@$BodyPath")
        }

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = az @args 2>&1
            $exitCode = $LASTEXITCODE
        }
        catch {
            $output = @($_.Exception.Message)
            $exitCode = 1
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $message = ($output | Out-String).Trim()
        if ($exitCode -eq 0) {
            return $message
        }

        $isRetryable = $message -match "Too Many Requests|429|temporarily unavailable|timeout|timed out|503|504"
        if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
            throw "Azure REST call failed after $attempt attempt(s): $message"
        }

        $delaySeconds = [Math]::Min(300, [Math]::Pow(2, $attempt) * 10)
        Write-Warning "Azure REST call was throttled or temporarily unavailable. Retrying in $delaySeconds seconds. Attempt $attempt of $MaxAttempts."
        Start-Sleep -Seconds $delaySeconds
    }
}

function Invoke-CostQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [hashtable]$TimePeriod,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [object[]]$GroupingDimensions = @(
            @{ type = "Dimension"; name = "ServiceName" },
            @{ type = "Dimension"; name = "ResourceGroupName" }
        ),

        [string]$FileSuffix = "service-resourcegroup"
    )

    $resourceManagerEndpoint = Get-AzureResourceManagerEndpoint
    $uri = "$resourceManagerEndpoint$Scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $body = @{
        type = "ActualCost"
        timeframe = "Custom"
        timePeriod = $TimePeriod
        dataset = @{
            granularity = "Daily"
            aggregation = @{
                totalCost = @{
                    name = "Cost"
                    function = "Sum"
                }
                totalQuantity = @{
                    name = "UsageQuantity"
                    function = "Sum"
                }
            }
            grouping = $GroupingDimensions
        }
    } | ConvertTo-Json -Depth 20

    $bodyPath = Join-Path $DestinationDir "$Prefix-cost-query.json"
    $jsonPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.json"
    $csvPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.csv"

    $body | Set-Content -Path $bodyPath -Encoding UTF8

    Write-Host "Querying $Prefix costs..."
    Invoke-AzRestWithRetry -Method "post" -Uri $uri -BodyPath $bodyPath |
        Set-Content -Path $jsonPath -Encoding UTF8

    $rows = Convert-CostResponseToCsv -JsonPath $jsonPath -CsvPath $csvPath
    $total = ($rows | Measure-Object -Property Cost -Sum).Sum
    $currency = ($rows | Select-Object -First 1 -ExpandProperty Currency -ErrorAction SilentlyContinue)

    return [pscustomobject]@{
        Prefix = $Prefix
        Json = $jsonPath
        Csv = $csvPath
        RowCount = $rows.Count
        TotalCost = [math]::Round($total, 4)
        Currency = $currency
    }
}

function Invoke-CostQueryAcrossSubscriptions {
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions,

        [Parameter(Mandatory)]
        [hashtable]$TimePeriod,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [object[]]$GroupingDimensions = @(
            @{ type = "Dimension"; name = "ServiceName" },
            @{ type = "Dimension"; name = "ResourceGroupName" }
        ),

        [string]$FileSuffix = "service-resourcegroup"
    )

    $subscriptionOutputRoot = Join-Path $DestinationDir "subscriptions"
    New-Item -ItemType Directory -Path $subscriptionOutputRoot -Force | Out-Null

    $combinedRows = @()
    $perSubscriptionResults = @()

    foreach ($sub in $Subscriptions) {
        $subId = [string]$sub.id
        $subName = [string]$sub.name
        $subCloud = if ($sub.PSObject.Properties.Name -contains "cloudName") { [string]$sub.cloudName } elseif ($sub.PSObject.Properties.Name -contains "environmentName") { [string]$sub.environmentName } else { [string]$AzureCloud }
        if ([string]::IsNullOrWhiteSpace($subCloud)) { $subCloud = [string]$AzureCloud }
        $subDestinationDir = Join-Path $subscriptionOutputRoot $subId
        New-Item -ItemType Directory -Path $subDestinationDir -Force | Out-Null

        Write-Host "Querying $Prefix costs for subscription: $subName ($subId)"
        Set-AzureContextSubscription -SubscriptionId $subId

        $subScope = "/subscriptions/$subId"
        $subResult = Invoke-CostQuery `
            -Scope $subScope `
            -TimePeriod $TimePeriod `
            -Prefix $Prefix `
            -DestinationDir $subDestinationDir `
            -GroupingDimensions $GroupingDimensions `
            -FileSuffix $FileSuffix

        $subRows = @(Import-Csv $subResult.Csv)
        foreach ($row in $subRows) {
            $row | Add-Member -NotePropertyName AzureCloud -NotePropertyValue $subCloud -Force
            $row | Add-Member -NotePropertyName SubscriptionId -NotePropertyValue $subId -Force
            $row | Add-Member -NotePropertyName SubscriptionName -NotePropertyValue $subName -Force
            $combinedRows += $row
        }

        $perSubscriptionResults += [pscustomobject]@{
            Prefix = $Prefix
            SubscriptionName = $subName
            SubscriptionId = $subId
            RowCount = $subResult.RowCount
            TotalCost = $subResult.TotalCost
            Currency = $subResult.Currency
        }
    }

    $combinedCsvPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.csv"
    $combinedJsonPath = Join-Path $DestinationDir "$Prefix-cost-by-$FileSuffix.json"

    if ($combinedRows.Count -gt 0) {
        $combinedRows | Export-Csv -Path $combinedCsvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        @() | Export-Csv -Path $combinedCsvPath -NoTypeInformation -Encoding UTF8
    }

    $combinedJson = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        prefix = $Prefix
        fileSuffix = $FileSuffix
        subscriptionCount = $Subscriptions.Count
        rowCount = $combinedRows.Count
        subscriptions = @($Subscriptions | ForEach-Object {
            [ordered]@{
                id = $_.id
                name = $_.name
                tenantId = $_.tenantId
            }
        })
        rows = $combinedRows
    }

    $combinedJson | ConvertTo-Json -Depth 20 | Set-Content -Path $combinedJsonPath -Encoding UTF8

    $total = if ($combinedRows.Count -gt 0) { ($combinedRows | Measure-Object -Property Cost -Sum).Sum } else { 0 }
    $currency = if ($combinedRows.Count -gt 0) { $combinedRows[0].Currency } else { $null }

    return [pscustomobject]@{
        Prefix = $Prefix
        Json = $combinedJsonPath
        Csv = $combinedCsvPath
        RowCount = $combinedRows.Count
        TotalCost = [math]::Round($total, 4)
        Currency = $currency
        SubscriptionCount = $Subscriptions.Count
        PerSubscription = $perSubscriptionResults
    }
}

function New-CostSummaries {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [Parameter(Mandatory)]
        [string[]]$Prefixes
    )

    $serviceRows = foreach ($prefix in $Prefixes) {
        $csvPath = Join-Path $DestinationDir "$prefix-cost-by-service-resourcegroup.csv"
        $csv = @(Import-Csv $csvPath)
        $csv | Group-Object ServiceName | ForEach-Object {
            [pscustomobject]@{
                Period = $prefix
                ServiceName = $_.Name
                Cost = [math]::Round((($_.Group | Measure-Object -Property Cost -Sum).Sum), 4)
                Currency = ($_.Group | Select-Object -First 1 -ExpandProperty Currency)
            }
        }
    }

    $resourceGroupRows = foreach ($prefix in $Prefixes) {
        $csvPath = Join-Path $DestinationDir "$prefix-cost-by-service-resourcegroup.csv"
        $csv = @(Import-Csv $csvPath)
        $csv | Group-Object ResourceGroupName | ForEach-Object {
            [pscustomobject]@{
                Period = $prefix
                ResourceGroupName = $_.Name
                Cost = [math]::Round((($_.Group | Measure-Object -Property Cost -Sum).Sum), 4)
                Currency = ($_.Group | Select-Object -First 1 -ExpandProperty Currency)
            }
        }
    }

    $serviceSummaryPath = Join-Path $DestinationDir "cost-summary-by-service.csv"
    $resourceGroupSummaryPath = Join-Path $DestinationDir "cost-summary-by-resourcegroup.csv"

    $serviceRows | Sort-Object Period, @{ Expression = "Cost"; Descending = $true } |
        Export-Csv -Path $serviceSummaryPath -NoTypeInformation -Encoding UTF8
    $resourceGroupRows | Sort-Object Period, @{ Expression = "Cost"; Descending = $true } |
        Export-Csv -Path $resourceGroupSummaryPath -NoTypeInformation -Encoding UTF8

    return [pscustomobject]@{
        ServiceSummary = $serviceSummaryPath
        ResourceGroupSummary = $resourceGroupSummaryPath
        ServiceRows = $serviceRows
        ResourceGroupRows = $resourceGroupRows
    }
}

function New-FinOpsMeterKey {
    param(
        [string]$ServiceName,
        [string]$Meter,
        [string]$Product,
        [string]$PartNumber,
        [string]$UnitOfMeasure
    )

    return @($ServiceName, $Meter, $Product, $PartNumber, $UnitOfMeasure) -join "|"
}

function New-FinOpsRetailSkuKey {
    param(
        [string]$RetailSkuId,
        [string]$RetailMeterId,
        [string]$RetailArmRegionName,
        [string]$RetailUnitOfMeasure
    )

    if ([string]::IsNullOrWhiteSpace($RetailSkuId) -and [string]::IsNullOrWhiteSpace($RetailMeterId)) {
        return ""
    }

    return @($RetailSkuId, $RetailMeterId, $RetailArmRegionName, $RetailUnitOfMeasure) -join "|"
}

function Export-FinOpsModelCsv {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Columns,

        [object[]]$Rows = @()
    )

    $rowsToWrite = @($Rows | Where-Object { $null -ne $_ })
    if ($rowsToWrite.Count -eq 0) {
        $header = ($Columns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ","
        Set-Content -Path $Path -Value $header -Encoding UTF8
        return
    }

    $rowsToWrite |
        Select-Object $Columns |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function New-NormalizedFinOpsModelFiles {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationDir,

        [Parameter(Mandatory)]
        [string[]]$Prefixes,

        [bool]$IncludeRetailPriceMatch = $true
    )

    $costRows = @()
    $retailMatchRows = @()

    foreach ($prefix in $Prefixes) {
        $periodLabel = switch ($prefix) {
            "mtd" { "MTD" }
            "last-month" { "Last Month" }
            "custom" { "Custom" }
            default { $prefix }
        }

        $costPath = Join-Path $DestinationDir "$prefix-cost-by-retail-join-with-arm-region.csv"
        if (Test-Path $costPath) {
            $costRows += @(Import-Csv $costPath | ForEach-Object {
                $meterKey = New-FinOpsMeterKey -ServiceName $_.ServiceName -Meter $_.Meter -Product $_.Product -PartNumber $_.PartNumber -UnitOfMeasure $_.UnitOfMeasure
                [pscustomobject][ordered]@{
                    Period = $periodLabel
                    AzureCloud = $_.AzureCloud
                    SubscriptionId = $_.SubscriptionId
                    SubscriptionName = $_.SubscriptionName
                    UsageDate = $_.UsageDate
                    ServiceName = $_.ServiceName
                    ResourceLocation = $_.ResourceLocation
                    ArmRegionName = $_.ArmRegionName
                    MeterKey = $meterKey
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

        $enrichedPath = Join-Path $DestinationDir "$prefix-cost-by-retail-join-enriched.csv"
        if ($IncludeRetailPriceMatch -and (Test-Path $enrichedPath)) {
            $retailMatchRows += @(Import-Csv $enrichedPath | ForEach-Object {
                $meterKey = New-FinOpsMeterKey -ServiceName $_.ServiceName -Meter $_.Meter -Product $_.Product -PartNumber $_.PartNumber -UnitOfMeasure $_.UnitOfMeasure
                $retailSkuKey = New-FinOpsRetailSkuKey -RetailSkuId $_.RetailSkuId -RetailMeterId $_.RetailMeterId -RetailArmRegionName $_.RetailArmRegionName -RetailUnitOfMeasure $_.RetailUnitOfMeasure
                [pscustomobject][ordered]@{
                    Period = $periodLabel
                    AzureCloud = $_.AzureCloud
                    SubscriptionId = $_.SubscriptionId
                    UsageDate = $_.UsageDate
                    ServiceName = $_.ServiceName
                    ArmRegionName = $_.ArmRegionName
                    MeterKey = $meterKey
                    Currency = $_.Currency
                    UsageQuantity = $_.UsageQuantity
                    Cost = $_.Cost
                    RetailSkuKey = $retailSkuKey
                    RetailMatchStatus = $_.RetailMatchStatus
                    RetailCandidateCount = $_.RetailCandidateCount
                    RetailSkuId = $_.RetailSkuId
                    RetailMeterId = $_.RetailMeterId
                    RetailProductId = $_.RetailProductId
                    RetailArmRegionName = $_.RetailArmRegionName
                    RetailUnitOfMeasure = $_.RetailUnitOfMeasure
                    RetailPrice = $_.RetailPrice
                    RetailUnitPrice = $_.RetailUnitPrice
                    RetailCurrencyCode = $_.RetailCurrencyCode
                }
            })
        }
    }

    $cloudRows = @(
        $costRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.AzureCloud) } |
            Select-Object AzureCloud -Unique |
            Sort-Object AzureCloud
    )

    $subscriptionRows = @(
        $costRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SubscriptionId) } |
            Group-Object SubscriptionId |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                [pscustomobject][ordered]@{
                    AzureCloud = $first.AzureCloud
                    SubscriptionId = $first.SubscriptionId
                    SubscriptionName = $first.SubscriptionName
                }
            } |
            Sort-Object SubscriptionName, SubscriptionId
    )

    $serviceRows = @(
        $costRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ServiceName) } |
            Select-Object ServiceName -Unique |
            Sort-Object ServiceName
    )

    $observedRegionRows = @(
        $costRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ArmRegionName) } |
            Group-Object ArmRegionName |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                $azureRegionName = Convert-CostManagementLocationToArmRegionName $first.ArmRegionName
                $regionInfo = Get-FinOpsRegionInfo -AzureRegionName $azureRegionName -ResourceLocation $first.ResourceLocation
                [pscustomobject][ordered]@{
                    "Display Name" = $regionInfo.'Display Name'
                    "Azure Region" = $regionInfo.'Azure Region'
                    "Azure Cloud" = $regionInfo.'Azure Cloud'
                    ArmRegionName = $azureRegionName
                    ResourceLocation = $first.ResourceLocation
                }
            }
    )

    $mappedRegionRows = @(
        Get-FinOpsAzureRegionMap | ForEach-Object {
            [pscustomobject][ordered]@{
                "Display Name" = $_.'Display Name'
                "Azure Region" = $_.'Azure Region'
                "Azure Cloud" = $_.'Azure Cloud'
                ArmRegionName = $_.'Azure Region'
                ResourceLocation = $_.'Azure Region'
            }
        }
    )

    $regionRows = @(
        @($mappedRegionRows) + @($observedRegionRows) |
            Group-Object ArmRegionName |
            ForEach-Object { $_.Group | Select-Object -First 1 } |
            Sort-Object "Azure Cloud", "Azure Region"
    )

    $meterRows = @(
        $costRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MeterKey) } |
            Group-Object MeterKey |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                [pscustomobject][ordered]@{
                    MeterKey = $first.MeterKey
                    ServiceName = $first.ServiceName
                    Meter = $first.Meter
                    Product = $first.Product
                    PartNumber = $first.PartNumber
                    UnitOfMeasure = $first.UnitOfMeasure
                }
            } |
            Sort-Object ServiceName, Meter, Product, PartNumber, UnitOfMeasure
    )

    $retailSkuRows = @(
        $retailMatchRows |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.RetailSkuKey) } |
            Group-Object RetailSkuKey |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                [pscustomobject][ordered]@{
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
            } |
            Sort-Object RetailSkuId, RetailMeterId, RetailArmRegionName
    )

    $outputs = @(
        @{ Path = Join-Path $DestinationDir "fact-cost-usage.csv"; Columns = @("Period","AzureCloud","SubscriptionId","SubscriptionName","UsageDate","ServiceName","ResourceLocation","ArmRegionName","MeterKey","Meter","Product","PartNumber","UnitOfMeasure","Currency","UsageQuantity","Cost"); Rows = $costRows },
        @{ Path = Join-Path $DestinationDir "dim-azure-cloud.csv"; Columns = @("AzureCloud"); Rows = $cloudRows },
        @{ Path = Join-Path $DestinationDir "dim-subscription.csv"; Columns = @("AzureCloud","SubscriptionId","SubscriptionName"); Rows = $subscriptionRows },
        @{ Path = Join-Path $DestinationDir "dim-service.csv"; Columns = @("ServiceName"); Rows = $serviceRows },
        @{ Path = Join-Path $DestinationDir "dim-region.csv"; Columns = @("Display Name","Azure Region","Azure Cloud","ArmRegionName","ResourceLocation"); Rows = $regionRows },
        @{ Path = Join-Path $DestinationDir "dim-meter.csv"; Columns = @("MeterKey","ServiceName","Meter","Product","PartNumber","UnitOfMeasure"); Rows = $meterRows },
        @{ Path = Join-Path $DestinationDir "fact-retail-price-match.csv"; Columns = @("Period","AzureCloud","SubscriptionId","UsageDate","ServiceName","ArmRegionName","MeterKey","Currency","UsageQuantity","Cost","RetailSkuKey","RetailMatchStatus","RetailCandidateCount","RetailSkuId","RetailMeterId","RetailProductId","RetailArmRegionName","RetailUnitOfMeasure","RetailPrice","RetailUnitPrice","RetailCurrencyCode"); Rows = $retailMatchRows },
        @{ Path = Join-Path $DestinationDir "dim-retail-sku.csv"; Columns = @("RetailSkuKey","RetailSkuId","RetailMeterId","RetailProductId","RetailArmRegionName","RetailUnitOfMeasure","RetailPrice","RetailUnitPrice","RetailCurrencyCode"); Rows = $retailSkuRows }
    )

    foreach ($output in $outputs) {
        Export-FinOpsModelCsv -Path $output.Path -Columns $output.Columns -Rows $output.Rows
    }

    return [pscustomobject]@{
        FactCostUsage = Join-Path $DestinationDir "fact-cost-usage.csv"
        FactRetailPriceMatch = Join-Path $DestinationDir "fact-retail-price-match.csv"
        DimSubscription = Join-Path $DestinationDir "dim-subscription.csv"
        DimAzureCloud = Join-Path $DestinationDir "dim-azure-cloud.csv"
        DimService = Join-Path $DestinationDir "dim-service.csv"
        DimRegion = Join-Path $DestinationDir "dim-region.csv"
        DimMeter = Join-Path $DestinationDir "dim-meter.csv"
        DimRetailSku = Join-Path $DestinationDir "dim-retail-sku.csv"
        CostRows = @($costRows).Count
        RetailMatchRows = @($retailMatchRows).Count
    }
}

Ensure-AzureCli
Set-AzureCloud -Name $AzureCloud
Ensure-AzureLogin
$targetSubscriptions = Get-TargetSubscriptions -TenantId $TenantId -RequestedSubscriptionIds $SubscriptionId
Set-AzureContextSubscription -SubscriptionId $targetSubscriptions[0].id

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$monthStart = Get-Date -Year $AsOfDate.Year -Month $AsOfDate.Month -Day 1 -Hour 0 -Minute 0 -Second 0
$priorMonthStart = $monthStart.AddMonths(-1)
$priorMonthEnd = $monthStart.AddSeconds(-1)
$asOfEnd = Get-Date -Year $AsOfDate.Year -Month $AsOfDate.Month -Day $AsOfDate.Day -Hour 23 -Minute 59 -Second 59

$periods = @(
    @{
        Prefix = "mtd"
        TimePeriod = @{
            from = $monthStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $asOfEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    },
    @{
        Prefix = "last-month"
        TimePeriod = @{
            from = $priorMonthStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $priorMonthEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
)

$hasCustomStartDate = $CustomStartDate -ne [datetime]::MinValue
$hasCustomEndDate = $CustomEndDate -ne [datetime]::MinValue

if ($hasCustomStartDate -xor $hasCustomEndDate) {
    throw "CustomStartDate and CustomEndDate must be supplied together."
}

if ($hasCustomStartDate) {
    $customStart = Get-Date -Year $CustomStartDate.Year -Month $CustomStartDate.Month -Day $CustomStartDate.Day -Hour 0 -Minute 0 -Second 0
    $customEnd = Get-Date -Year $CustomEndDate.Year -Month $CustomEndDate.Month -Day $CustomEndDate.Day -Hour 23 -Minute 59 -Second 59
    if ($customEnd -lt $customStart) {
        throw "CustomEndDate must be on or after CustomStartDate."
    }

    $periods += @{
        Prefix = "custom"
        TimePeriod = @{
            from = $customStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            to = $customEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

$results = foreach ($period in $periods) {
    Invoke-CostQueryAcrossSubscriptions `
        -Subscriptions $targetSubscriptions `
        -TimePeriod $period.TimePeriod `
        -Prefix $period.Prefix `
        -DestinationDir $OutputDir
}

$retailJoinGroupings = @(
    @{ type = "Dimension"; name = "ServiceName" },
    @{ type = "Dimension"; name = "ResourceLocation" },
    @{ type = "Dimension"; name = "Meter" },
    @{ type = "Dimension"; name = "Product" },
    @{ type = "Dimension"; name = "PartNumber" },
    @{ type = "Dimension"; name = "UnitOfMeasure" }
)

$retailJoinResults = foreach ($period in $periods) {
    Invoke-CostQueryAcrossSubscriptions `
        -Subscriptions $targetSubscriptions `
        -TimePeriod $period.TimePeriod `
        -Prefix $period.Prefix `
        -DestinationDir $OutputDir `
        -GroupingDimensions $retailJoinGroupings `
        -FileSuffix "retail-join"
}

$locationLookup = Get-ArmRegionNameLookup
$retailEnrichedPaths = @()

foreach ($period in $periods) {
    $prefix = $period.Prefix
    $retailJoinCsvPath = Join-Path $OutputDir "$prefix-cost-by-retail-join.csv"
    $retailRows = @(Import-Csv $retailJoinCsvPath)
    $retailRowsWithRegion = @(Add-ArmRegionName -Rows $retailRows -LocationLookup $locationLookup)
    $retailJoinWithRegionPath = Join-Path $OutputDir "$prefix-cost-by-retail-join-with-arm-region.csv"
    $retailRowsWithRegion | Export-Csv -Path $retailJoinWithRegionPath -NoTypeInformation -Encoding UTF8

    if (-not $SkipRetailPriceLookup) {
        Write-Host "Adding Retail Prices API data for $prefix..."
        $enrichedRows = @(Add-RetailPriceData -Rows $retailRowsWithRegion)
        $retailEnrichedPath = Join-Path $OutputDir "$prefix-cost-by-retail-join-enriched.csv"
        $enrichedRows | Export-Csv -Path $retailEnrichedPath -NoTypeInformation -Encoding UTF8
        $retailEnrichedPaths += $retailEnrichedPath
    }
}

$summaries = New-CostSummaries -DestinationDir $OutputDir -Prefixes @($periods | ForEach-Object { $_.Prefix })
$normalizedModelOutputs = New-NormalizedFinOpsModelFiles -DestinationDir $OutputDir -Prefixes @($periods | ForEach-Object { $_.Prefix }) -IncludeRetailPriceMatch:(-not $SkipRetailPriceLookup)

Write-Host ""
Write-Host "Cost exports saved to: $OutputDir"
Write-Host ""
Write-Host "Processed subscriptions: $($targetSubscriptions.Count)"
Write-Host ""
Write-Host "Query results:"
$results |
    Select-Object Prefix, SubscriptionCount, RowCount, TotalCost, Currency, Csv |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Write-Host
Write-Host "Retail join query results:"
$retailJoinResults |
    Select-Object Prefix, SubscriptionCount, RowCount, TotalCost, Currency, Csv |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Write-Host
Write-Host "Summary by service: $($summaries.ServiceSummary)"
Write-Host "Summary by resource group: $($summaries.ResourceGroupSummary)"
Write-Host "Normalized model files:"
Write-Host "  Fact cost usage:        $($normalizedModelOutputs.FactCostUsage)"
Write-Host "  Retail price matches:   $($normalizedModelOutputs.FactRetailPriceMatch)"
Write-Host "  Dimensions:             $($normalizedModelOutputs.DimSubscription), $($normalizedModelOutputs.DimService), $($normalizedModelOutputs.DimRegion), $($normalizedModelOutputs.DimMeter), $($normalizedModelOutputs.DimRetailSku)"
Write-Host "Retail join CSVs: $(Join-Path $OutputDir '*-cost-by-retail-join-with-arm-region.csv')"
if (-not $SkipRetailPriceLookup) {
    Write-Host "Retail enriched CSVs:"
    $retailEnrichedPaths | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host "Retail Prices API lookup skipped. Rerun without -SkipRetailPriceLookup to attempt skuId and meterId enrichment."
}
Write-Host ""
Write-Host "Top month-to-date services:"
$summaries.ServiceRows |
    Where-Object Period -eq "mtd" |
    Sort-Object Cost -Descending |
    Select-Object -First 10 |
    Format-Table -AutoSize |
    Out-String -Width 240 |
    Write-Host
