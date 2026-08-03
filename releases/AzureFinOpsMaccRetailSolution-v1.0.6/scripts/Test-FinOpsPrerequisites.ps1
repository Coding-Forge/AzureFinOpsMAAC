<#
.SYNOPSIS
Checks whether the local workstation is ready to run the Azure FinOps MACC Retail solution.

.DESCRIPTION
Validates local PowerShell, Azure CLI, Azure CLI cloud/login context, optional Power BI Desktop,
repository folders, and writable output/history paths. The script is read-only except for creating
or testing the configured output/history directories when -OutputRoot or -HistoryRoot are supplied.
#>
[CmdletBinding()]
param(
    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$AzureCloud = "AzureCloud",

    [string]$TenantId,

    [string[]]$SubscriptionId = @(),

    [string]$OutputRoot,

    [string]$HistoryRoot,

    [switch]$CheckPowerBiDesktop,

    [switch]$RequireLogin,

    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-CheckResult {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Pass", "Warn", "Fail", "Info")]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Area,

        [Parameter(Mandatory)]
        [string]$Check,

        [string]$Detail = "",

        [string]$Recommendation = ""
    )

    $script:Results.Add([pscustomobject][ordered]@{
        Status = $Status
        Area = $Area
        Check = $Check
        Detail = $Detail
        Recommendation = $Recommendation
    })
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-ExternalJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Command
    )

    $output = & $Command[0] @($Command | Select-Object -Skip 1) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output | Out-String).Trim()
    }

    return $output | ConvertFrom-Json
}

function Test-WritableDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Area
    )

    try {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $testFile = Join-Path $Path ".finops-write-test-$([guid]::NewGuid().ToString('N')).tmp"
        "test" | Set-Content -Path $testFile -Encoding UTF8
        Remove-Item -Path $testFile -Force
        Add-CheckResult -Status Pass -Area $Area -Check "Writable path" -Detail $Path
    }
    catch {
        Add-CheckResult -Status Fail -Area $Area -Check "Writable path" -Detail $Path -Recommendation $_.Exception.Message
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$solutionRoot = Split-Path -Parent $scriptRoot

Add-CheckResult -Status Info -Area "Solution" -Check "Solution root" -Detail $solutionRoot

foreach ($relativePath in @(
    "scripts\Start-FinOpsDataPull.ps1",
    "scripts\Get-CostAnalysis.ps1",
    "scripts\Get-AzureBillingContactAudit.ps1",
    "scripts\Get-AzureResourceGroupsByLocation.ps1",
    "scripts\New-FinOpsAuditArtifacts.ps1",
    "powerbi\Cost-Management.pbip",
    "powerbi\Cost-Management.SemanticModel\definition\model.tmdl"
)) {
    $path = Join-Path $solutionRoot $relativePath
    if (Test-Path $path) {
        Add-CheckResult -Status Pass -Area "Solution" -Check "Required file" -Detail $relativePath
    }
    else {
        Add-CheckResult -Status Fail -Area "Solution" -Check "Required file" -Detail $relativePath -Recommendation "Restore the missing file from the repository or release package."
    }
}

foreach ($script in @(
    "Start-FinOpsDataPull.ps1",
    "Get-CostAnalysis.ps1",
    "Get-AzureBillingContactAudit.ps1",
    "Get-AzureResourceGroupsByLocation.ps1",
    "New-FinOpsAuditArtifacts.ps1"
)) {
    $path = Join-Path $scriptRoot $script
    if (Test-Path $path) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -eq 0) {
            Add-CheckResult -Status Pass -Area "PowerShell" -Check "Script parses" -Detail $script
        }
        else {
            Add-CheckResult -Status Fail -Area "PowerShell" -Check "Script parses" -Detail $script -Recommendation (($errors | Select-Object -First 3 | Out-String).Trim())
        }
    }
}

$psVersion = $PSVersionTable.PSVersion.ToString()
if ($PSVersionTable.PSVersion.Major -ge 5) {
    Add-CheckResult -Status Pass -Area "PowerShell" -Check "PowerShell version" -Detail $psVersion
}
else {
    Add-CheckResult -Status Fail -Area "PowerShell" -Check "PowerShell version" -Detail $psVersion -Recommendation "Use Windows PowerShell 5.1 or PowerShell 7+."
}

try {
    $executionPolicy = Get-ExecutionPolicy -Scope Process
    Add-CheckResult -Status Info -Area "PowerShell" -Check "Process execution policy" -Detail $executionPolicy
}
catch {
    Add-CheckResult -Status Warn -Area "PowerShell" -Check "Process execution policy" -Detail "Unable to read execution policy." -Recommendation $_.Exception.Message
}

if (Test-CommandExists "az") {
    try {
        $azVersionJson = & az version --output json 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "az version failed."
        }

        $azVersionObject = $azVersionJson | ConvertFrom-Json
        $azVersion = $azVersionObject.'azure-cli'
        Add-CheckResult -Status Pass -Area "Azure CLI" -Check "Installed" -Detail "azure-cli $azVersion"
    }
    catch {
        Add-CheckResult -Status Warn -Area "Azure CLI" -Check "Installed" -Detail "Azure CLI is on PATH but version query failed." -Recommendation $_.Exception.Message
    }

    try {
        $cloud = Invoke-ExternalJson -Command @("az", "cloud", "show", "--output", "json")
        if ($cloud.name -eq $AzureCloud) {
            Add-CheckResult -Status Pass -Area "Azure CLI" -Check "Active cloud" -Detail $cloud.name
        }
        else {
            Add-CheckResult -Status Warn -Area "Azure CLI" -Check "Active cloud" -Detail "Current: $($cloud.name); Expected: $AzureCloud" -Recommendation "Run: az cloud set --name $AzureCloud"
        }
    }
    catch {
        Add-CheckResult -Status Fail -Area "Azure CLI" -Check "Active cloud" -Detail "Unable to query Azure CLI cloud." -Recommendation $_.Exception.Message
    }

    try {
        $account = Invoke-ExternalJson -Command @("az", "account", "show", "--output", "json")
        $tenantMatches = [string]::IsNullOrWhiteSpace($TenantId) -or $account.tenantId -eq $TenantId
        if ($tenantMatches) {
            Add-CheckResult -Status Pass -Area "Azure CLI" -Check "Signed in" -Detail "$($account.name) / $($account.id) / tenant $($account.tenantId)"
        }
        else {
            Add-CheckResult -Status Warn -Area "Azure CLI" -Check "Signed in tenant" -Detail "Current tenant: $($account.tenantId); Expected: $TenantId" -Recommendation "Run: az login --tenant `"$TenantId`""
        }
    }
    catch {
        $status = if ($RequireLogin) { "Fail" } else { "Warn" }
        Add-CheckResult -Status $status -Area "Azure CLI" -Check "Signed in" -Detail "No active account or account query failed." -Recommendation "Run: az login --tenant <tenant-id>"
    }

    try {
        $subscriptions = @(Invoke-ExternalJson -Command @("az", "account", "list", "--all", "--output", "json"))
        if ($subscriptions.Count -gt 0) {
            Add-CheckResult -Status Pass -Area "Azure CLI" -Check "Visible subscriptions" -Detail "$($subscriptions.Count) subscription(s) visible."
        }
        else {
            Add-CheckResult -Status Warn -Area "Azure CLI" -Check "Visible subscriptions" -Detail "No subscriptions visible." -Recommendation "Confirm account, tenant, cloud, and RBAC/PIM activation."
        }

        foreach ($id in $SubscriptionId) {
            $match = $subscriptions | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($match) {
                Add-CheckResult -Status Pass -Area "Azure CLI" -Check "Requested subscription visible" -Detail "$($match.name) / $id"
            }
            else {
                Add-CheckResult -Status Warn -Area "Azure CLI" -Check "Requested subscription visible" -Detail $id -Recommendation "Run az account set --subscription `"$id`" after activating PIM, or confirm this subscription belongs to the selected cloud/tenant."
            }
        }
    }
    catch {
        Add-CheckResult -Status Warn -Area "Azure CLI" -Check "Visible subscriptions" -Detail "Unable to list subscriptions." -Recommendation $_.Exception.Message
    }
}
else {
    Add-CheckResult -Status Fail -Area "Azure CLI" -Check "Installed" -Detail "az was not found on PATH." -Recommendation "Install Azure CLI: winget install Microsoft.AzureCLI"
}

if (Test-CommandExists "winget") {
    Add-CheckResult -Status Pass -Area "Packages" -Check "winget available" -Detail "winget found on PATH."
}
else {
    Add-CheckResult -Status Warn -Area "Packages" -Check "winget available" -Detail "winget not found." -Recommendation "Manual installs may be required if Azure CLI or Power BI Desktop are missing."
}

if ($CheckPowerBiDesktop) {
    $pbiProcesses = @(Get-Process -Name "PBIDesktop*" -ErrorAction SilentlyContinue)
    if ($pbiProcesses.Count -eq 0) {
        Add-CheckResult -Status Pass -Area "Power BI" -Check "Power BI Desktop closed" -Detail "No PBIDesktop process is running."
    }
    else {
        Add-CheckResult -Status Warn -Area "Power BI" -Check "Power BI Desktop closed" -Detail (($pbiProcesses | ForEach-Object { "$($_.ProcessName) PID $($_.Id)" }) -join "; ") -Recommendation "Close Power BI Desktop before running the launcher because it updates PBIP/TMDL files."
    }

    $possiblePowerBiPaths = @(
        "$env:ProgramFiles\Microsoft Power BI Desktop\bin\PBIDesktop.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\PBIDesktop.exe"
    )
    $powerBiPath = $possiblePowerBiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($powerBiPath) {
        Add-CheckResult -Status Pass -Area "Power BI" -Check "Power BI Desktop installed" -Detail $powerBiPath
    }
    else {
        Add-CheckResult -Status Warn -Area "Power BI" -Check "Power BI Desktop installed" -Detail "PBIDesktop.exe was not found in common locations." -Recommendation "Install Power BI Desktop with PBIP support."
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    Test-WritableDirectory -Path $OutputRoot -Area "Storage"
}

if (-not [string]::IsNullOrWhiteSpace($HistoryRoot)) {
    Test-WritableDirectory -Path $HistoryRoot -Area "Storage"
}

$failCount = @($script:Results | Where-Object Status -eq "Fail").Count
$warnCount = @($script:Results | Where-Object Status -eq "Warn").Count
$passCount = @($script:Results | Where-Object Status -eq "Pass").Count

if ($AsJson) {
    $summary = [ordered]@{
        Ready = ($failCount -eq 0)
        Pass = $passCount
        Warn = $warnCount
        Fail = $failCount
        Results = @($script:Results.ToArray())
    }

    [pscustomobject]$summary | ConvertTo-Json -Depth 6
}
else {
    Write-Host ""
    Write-Host "Azure FinOps MACC Retail prerequisite check"
    Write-Host "Ready: $(if ($failCount -eq 0) { 'Yes' } else { 'No' })  Pass: $passCount  Warn: $warnCount  Fail: $failCount"
    Write-Host ""
    $script:Results | Sort-Object @{ Expression = { @{ Fail = 0; Warn = 1; Pass = 2; Info = 3 }[$_.Status] } }, Area, Check |
        Format-Table Status, Area, Check, Detail, Recommendation -Wrap
}

if ($failCount -gt 0) {
    exit 1
}
