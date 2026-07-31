<#
.SYNOPSIS
Windows Forms launcher for the Azure FinOps MACC Retail data export scripts.

.DESCRIPTION
Provides a guided UI for running the Cost Management and resource-group export
scripts, choosing where generated CSV/JSON files are staged, and optionally
uploading the output to Azure Blob Storage or ADLS Gen2.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:SolutionRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultOutputRoot = Join-Path $PSScriptRoot "exports"
$script:DefaultLauncherSettingsPath = Join-Path $script:DefaultOutputRoot "finops-launcher-settings.json"
$script:LauncherSettingsPath = $script:DefaultLauncherSettingsPath

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 160,
        [int]$Height = 22
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    return $label
}

function New-TextBox {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width = 520,
        [string]$Text = ""
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($Width, 24)
    $textBox.Text = $Text
    return $textBox
}

function New-CheckBox {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [bool]$Checked = $false,
        [int]$Width = 260
    )

    $checkBox = New-Object System.Windows.Forms.CheckBox
    $checkBox.Text = $Text
    $checkBox.Location = New-Object System.Drawing.Point($X, $Y)
    $checkBox.Size = New-Object System.Drawing.Size($Width, 24)
    $checkBox.Checked = $Checked
    return $checkBox
}

function ConvertTo-BaseUrl {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Local", "AzureBlob", "ADLSGen2", "SharePoint")]
        [string]$StorageLocation,

        [string]$LocalPath,
        [string]$StorageAccount,
        [string]$ContainerOrFileSystem,
        [string]$Prefix,
        [string]$SharePointDataRoot
    )

    $normalizedPrefix = ($Prefix -replace "\\", "/").Trim("/")
    switch ($StorageLocation) {
        "Local" {
            if ([string]::IsNullOrWhiteSpace($LocalPath)) {
                throw "Local output folder is required."
            }

            $root = $LocalPath.Trim()
            if (-not $root.EndsWith("\") -and -not $root.EndsWith("/")) {
                $root += "\"
            }

            return $root
        }
        "AzureBlob" {
            if ([string]::IsNullOrWhiteSpace($StorageAccount) -or [string]::IsNullOrWhiteSpace($ContainerOrFileSystem)) {
                throw "Azure Blob storage account and container are required."
            }

            $base = "https://$($StorageAccount.Trim()).blob.core.windows.net/$($ContainerOrFileSystem.Trim())/"
            if ($normalizedPrefix) {
                $base += "$normalizedPrefix/"
            }

            return $base
        }
        "ADLSGen2" {
            if ([string]::IsNullOrWhiteSpace($StorageAccount) -or [string]::IsNullOrWhiteSpace($ContainerOrFileSystem)) {
                throw "ADLS Gen2 storage account and file system are required."
            }

            $base = "https://$($StorageAccount.Trim()).dfs.core.windows.net/$($ContainerOrFileSystem.Trim())/"
            if ($normalizedPrefix) {
                $base += "$normalizedPrefix/"
            }

            return $base
        }
        "SharePoint" {
            if ([string]::IsNullOrWhiteSpace($SharePointDataRoot)) {
                throw "SharePoint document library folder URL is required."
            }

            $base = $SharePointDataRoot.Trim()
            if (-not $base.EndsWith("/")) {
                $base += "/"
            }

            return $base
        }
    }
}

function ConvertTo-PowerShellLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Set-TextFileUtf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        [string]$Value
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Show-AnalysisPurposeDialog {
    param([ValidateSet("Current", "History")][string]$CurrentMode = "Current")

    $purposeForm = New-Object System.Windows.Forms.Form
    $purposeForm.Text = "Choose analysis purpose"
    $purposeForm.Size = New-Object System.Drawing.Size(650, 320)
    $purposeForm.StartPosition = "CenterScreen"
    $purposeForm.FormBorderStyle = "FixedDialog"
    $purposeForm.MaximizeBox = $false
    $purposeForm.MinimizeBox = $false

    $prompt = New-Label "What is the purpose of this data pull?" 20 20 590 26
    $prompt.Font = New-Object System.Drawing.Font($prompt.Font, [System.Drawing.FontStyle]::Bold)
    $purposeForm.Controls.Add($prompt)

    $currentRadio = New-Object System.Windows.Forms.RadioButton
    $currentRadio.Text = "Current view - analyze month-to-date and last month only"
    $currentRadio.Location = New-Object System.Drawing.Point(35, 65)
    $currentRadio.Size = New-Object System.Drawing.Size(560, 24)
    $currentRadio.Checked = ($CurrentMode -ne "History")
    $purposeForm.Controls.Add($currentRadio)

    $currentDescription = New-Label "Best for a point-in-time review. Each run creates a new run folder, and Power BI reads the current MTD/last-month files." 58 92 540 44
    $purposeForm.Controls.Add($currentDescription)

    $historyRadio = New-Object System.Windows.Forms.RadioButton
    $historyRadio.Text = "Running history - build a MACC savings history for Power BI"
    $historyRadio.Location = New-Object System.Drawing.Point(35, 145)
    $historyRadio.Size = New-Object System.Drawing.Size(560, 24)
    $historyRadio.Checked = ($CurrentMode -eq "History")
    $purposeForm.Controls.Add($historyRadio)

    $historyDescription = New-Label "Best for monthly operations. The launcher maintains cost-retail-history.csv so Power BI can trend actual cost, retail equivalent, and estimated MACC savings over time." 58 172 540 48
    $purposeForm.Controls.Add($historyDescription)

    $continueButton = New-Object System.Windows.Forms.Button
    $continueButton.Text = "Continue"
    $continueButton.Location = New-Object System.Drawing.Point(385, 235)
    $continueButton.Size = New-Object System.Drawing.Size(100, 32)
    $continueButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $purposeForm.AcceptButton = $continueButton
    $purposeForm.Controls.Add($continueButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(495, 235)
    $cancelButton.Size = New-Object System.Drawing.Size(100, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $purposeForm.CancelButton = $cancelButton
    $purposeForm.Controls.Add($cancelButton)

    if ($purposeForm.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    if ($historyRadio.Checked) {
        return "History"
    }

    return "Current"
}

function Get-LauncherSettings {
    if ($script:LauncherSettingsPath -eq $script:DefaultLauncherSettingsPath -and (Test-Path $script:DefaultLauncherSettingsPath)) {
        try {
            $defaultSettings = Get-Content -Path $script:DefaultLauncherSettingsPath -Raw | ConvertFrom-Json
            if ($defaultSettings.SettingsFilePath -and (Test-Path ([string]$defaultSettings.SettingsFilePath))) {
                $script:LauncherSettingsPath = [string]$defaultSettings.SettingsFilePath
            }
        }
        catch {
            Write-Warning "Could not read default launcher settings pointer from $script:DefaultLauncherSettingsPath."
        }
    }

    if (-not (Test-Path $script:LauncherSettingsPath)) {
        return [pscustomobject]@{
            AnalysisMode = $null
            SettingsFilePath = $script:LauncherSettingsPath
        }
    }

    try {
        $settings = Get-Content -Path $script:LauncherSettingsPath -Raw | ConvertFrom-Json
        if (-not $settings.PSObject.Properties["SettingsFilePath"]) {
            $settings | Add-Member -NotePropertyName SettingsFilePath -NotePropertyValue $script:LauncherSettingsPath -Force
        }
        return $settings
    }
    catch {
        Write-Warning "Could not read launcher settings from $script:LauncherSettingsPath. The analysis purpose will be requested again."
    }

    return [pscustomobject]@{
        AnalysisMode = $null
        SettingsFilePath = $script:LauncherSettingsPath
    }
}

function Save-LauncherSettings {
    param([hashtable]$Updates)

    New-Item -ItemType Directory -Path (Split-Path -Parent $script:LauncherSettingsPath) -Force | Out-Null
    $settings = Get-LauncherSettings
    $merged = [ordered]@{}
    foreach ($property in $settings.PSObject.Properties) {
        $merged[$property.Name] = $property.Value
    }

    if ($Updates) {
        foreach ($key in $Updates.Keys) {
            $merged[$key] = $Updates[$key]
        }
    }

    $merged["SettingsFilePath"] = $script:LauncherSettingsPath
    $merged["UpdatedUtc"] = (Get-Date).ToUniversalTime().ToString("o")
    $merged | ConvertTo-Json -Depth 8 | Set-Content -Path $script:LauncherSettingsPath -Encoding UTF8

    if ($script:LauncherSettingsPath -ne $script:DefaultLauncherSettingsPath) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:DefaultLauncherSettingsPath) -Force | Out-Null
        [ordered]@{
            SettingsFilePath = $script:LauncherSettingsPath
            UpdatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:DefaultLauncherSettingsPath -Encoding UTF8
    }
}

function Update-PathFromRegistry {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Ensure-AzureCliForUi {
    param([bool]$InstallAzureCli)

    Update-PathFromRegistry
    if (Get-Command az -ErrorAction SilentlyContinue) {
        return
    }

    if (-not $InstallAzureCli) {
        throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows or select 'Install Azure CLI if missing'."
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget is not available. Install Azure CLI manually from https://aka.ms/installazurecliwindows."
    }

    winget install --exact --id Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements --disable-interactivity
    Update-PathFromRegistry

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI installation completed, but az is not available on PATH. Open a new PowerShell window and rerun the launcher."
    }
}

function Set-AzureCloudForUi {
    param([string]$AzureCloud = "AzureCloud")

    $validClouds = @("AzureCloud", "AzureUSGovernment")
    if ($AzureCloud -notin $validClouds) {
        throw "Unsupported Azure cloud '$AzureCloud'. Use AzureCloud or AzureUSGovernment."
    }

    $currentCloud = az cloud show --query name --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentCloud) -or $currentCloud.Trim() -ne $AzureCloud) {
        Write-Host "Setting Azure CLI cloud to $AzureCloud..."
        az cloud set --name $AzureCloud | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not set Azure CLI cloud to '$AzureCloud'."
        }
    }
}

function Ensure-AzureLoginForUi {
    param(
        [string]$TenantId,
        [string]$AzureCloud = "AzureCloud"
    )

    Set-AzureCloudForUi -AzureCloud $AzureCloud

    $accountJson = az account show --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) {
        return
    }

    $loginArgs = @("login", "--use-device-code", "--allow-no-subscriptions", "--output", "json")
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $loginArgs += @("--tenant", $TenantId.Trim())
    }

    az @loginArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure sign-in failed."
    }
}

function Get-AzureSubscriptionsForUi {
    param(
        [string]$TenantId,
        [bool]$InstallAzureCli,
        [string]$AzureCloud = "AzureCloud"
    )

    Ensure-AzureCliForUi -InstallAzureCli $InstallAzureCli
    Ensure-AzureLoginForUi -TenantId $TenantId -AzureCloud $AzureCloud

    $subscriptions = @(az account list --all --output json | ConvertFrom-Json)
    if (-not $subscriptions -or $subscriptions.Count -eq 0) {
        throw "No Azure subscriptions are visible for the signed-in identity."
    }

    $enabledSubscriptions = @($subscriptions | Where-Object { $_.state -eq "Enabled" })
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $tenantFilter = $TenantId.Trim()
        $enabledSubscriptions = @($enabledSubscriptions | Where-Object { $_.tenantId -eq $tenantFilter })
    }

    if (-not $enabledSubscriptions -or $enabledSubscriptions.Count -eq 0) {
        throw "No enabled Azure subscriptions were found for the selected tenant."
    }

    return @($enabledSubscriptions | Sort-Object name)
}

function New-RunScript {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runRoot = Join-Path $Config.OutputRoot "run-$runStamp"
    $historyRoot = if ([string]::IsNullOrWhiteSpace([string]$Config.HistoryRoot)) {
        Join-Path $Config.OutputRoot "history"
    }
    else {
        [string]$Config.HistoryRoot
    }
    $historyPath = Join-Path $historyRoot "cost-retail-history.csv"
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $settings = [ordered]@{
        AnalysisMode = $Config.AnalysisMode
        AzureCloud = if ([string]::IsNullOrWhiteSpace([string]$Config.AzureCloud)) { "AzureCloud" } else { [string]$Config.AzureCloud }
        StorageLocation = $Config.StorageLocation
        LocalDataRoot = ConvertTo-BaseUrl -StorageLocation "Local" -LocalPath $runRoot
        HistoryDataRoot = ConvertTo-BaseUrl -StorageLocation "Local" -LocalPath $historyRoot
        CustomRangeEnabled = [bool]$Config.CustomRangeEnabled
        CustomStartDate = if ($Config.CustomRangeEnabled) { $Config.CustomStartDate.ToString("yyyy-MM-dd") } else { "" }
        CustomEndDate = if ($Config.CustomRangeEnabled) { $Config.CustomEndDate.ToString("yyyy-MM-dd") } else { "" }
        BillingContactAuditFolder = if ($Config.RunBillingContactAudit) { Join-Path $runRoot "billing-contact-audit" } else { "" }
        BlobDataRoot = if ($Config.StorageLocation -eq "AzureBlob") {
            ConvertTo-BaseUrl -StorageLocation "AzureBlob" -StorageAccount $Config.StorageAccount -ContainerOrFileSystem $Config.ContainerOrFileSystem -Prefix $Config.Prefix
        }
        else {
            ""
        }
        AdlsDataRoot = if ($Config.StorageLocation -eq "ADLSGen2") {
            ConvertTo-BaseUrl -StorageLocation "ADLSGen2" -StorageAccount $Config.StorageAccount -ContainerOrFileSystem $Config.ContainerOrFileSystem -Prefix $Config.Prefix
        }
        else {
            ""
        }
        SharePointDataRoot = if ($Config.StorageLocation -eq "SharePoint") {
            ConvertTo-BaseUrl -StorageLocation "SharePoint" -SharePointDataRoot $Config.SharePointDataRoot
        }
        else {
            ""
        }
        OutputFolder = $runRoot
        HistoryFile = $historyPath
        AgreementId = $Config.AgreementId
        CustomerName = $Config.CustomerName
        AgreementStartDate = $Config.AgreementStartDate.ToString("yyyy-MM-dd")
        AgreementEndDate = $Config.AgreementEndDate.ToString("yyyy-MM-dd")
        CommitmentAmount = $Config.CommitmentAmount
        CommitmentCurrency = $Config.CommitmentCurrency
        PacingWarningPercent = $Config.PacingWarningPercent
        PacingCriticalPercent = $Config.PacingCriticalPercent
        CreatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $settingsPath = Join-Path $runRoot "powerbi-storage-settings.json"
    $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsPath -Encoding UTF8

    $subscriptionLiteral = "@()"
    if ($Config.SubscriptionIds.Count -gt 0) {
        $subscriptionLiteral = "@(" + (($Config.SubscriptionIds | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ", ") + ")"
    }

    $tenantLiteral = ConvertTo-PowerShellLiteral $Config.TenantId
    $azureCloudLiteral = ConvertTo-PowerShellLiteral $(if ([string]::IsNullOrWhiteSpace([string]$Config.AzureCloud)) { "AzureCloud" } else { [string]$Config.AzureCloud })
    $outputLiteral = ConvertTo-PowerShellLiteral $runRoot
    $scriptRootLiteral = ConvertTo-PowerShellLiteral $PSScriptRoot
    $storageAccountLiteral = ConvertTo-PowerShellLiteral $Config.StorageAccount
    $containerLiteral = ConvertTo-PowerShellLiteral $Config.ContainerOrFileSystem
    $prefixLiteral = ConvertTo-PowerShellLiteral (($Config.Prefix -replace "\\", "/").Trim("/"))
    $settingsPathLiteral = ConvertTo-PowerShellLiteral $settingsPath
    $asOfDateLiteral = ConvertTo-PowerShellLiteral $Config.AsOfDate.ToString("yyyy-MM-dd")
    $customStartDateLiteral = ConvertTo-PowerShellLiteral $(if ($Config.CustomRangeEnabled) { $Config.CustomStartDate.ToString("yyyy-MM-dd") } else { "" })
    $customEndDateLiteral = ConvertTo-PowerShellLiteral $(if ($Config.CustomRangeEnabled) { $Config.CustomEndDate.ToString("yyyy-MM-dd") } else { "" })
    $analysisModeLiteral = ConvertTo-PowerShellLiteral $Config.AnalysisMode
    $historyPathLiteral = ConvertTo-PowerShellLiteral $historyPath
    $historyRootLiteral = ConvertTo-PowerShellLiteral $historyRoot
    $agreementIdLiteral = ConvertTo-PowerShellLiteral $Config.AgreementId
    $customerNameLiteral = ConvertTo-PowerShellLiteral $Config.CustomerName
    $agreementStartDateLiteral = ConvertTo-PowerShellLiteral $Config.AgreementStartDate.ToString("yyyy-MM-dd")
    $agreementEndDateLiteral = ConvertTo-PowerShellLiteral $Config.AgreementEndDate.ToString("yyyy-MM-dd")
    $commitmentAmountLiteral = ConvertTo-PowerShellLiteral $Config.CommitmentAmount
    $commitmentCurrencyLiteral = ConvertTo-PowerShellLiteral $Config.CommitmentCurrency
    $pacingWarningLiteral = ConvertTo-PowerShellLiteral $Config.PacingWarningPercent
    $pacingCriticalLiteral = ConvertTo-PowerShellLiteral $Config.PacingCriticalPercent

    $installAzureCli = if ($Config.InstallAzureCli) { '$true' } else { '$false' }
    $skipRetail = if ($Config.SkipRetailPriceLookup) { '$true' } else { '$false' }
    $runCost = if ($Config.RunCostAnalysis) { '$true' } else { '$false' }
    $runResourceGroups = if ($Config.RunResourceGroups) { '$true' } else { '$false' }
    $runBillingContactAudit = if ($Config.RunBillingContactAudit) { '$true' } else { '$false' }
    $customRangeEnabled = if ($Config.CustomRangeEnabled) { '$true' } else { '$false' }
    $storageLocationLiteral = ConvertTo-PowerShellLiteral $Config.StorageLocation

    $runScript = @"
`$ErrorActionPreference = "Stop"
`$scriptRoot = $scriptRootLiteral
`$outputRoot = $outputLiteral
`$tenantId = $tenantLiteral
`$azureCloud = $azureCloudLiteral
`$subscriptionIds = $subscriptionLiteral
`$asOfDate = [datetime]$asOfDateLiteral
`$customRangeEnabled = $customRangeEnabled
`$customStartDate = $customStartDateLiteral
`$customEndDate = $customEndDateLiteral
`$installAzureCli = $installAzureCli
`$skipRetailPriceLookup = $skipRetail
`$runCostAnalysis = $runCost
`$runResourceGroups = $runResourceGroups
`$runBillingContactAudit = $runBillingContactAudit
`$onlyBillingContactAudit = `$runBillingContactAudit -and -not `$runCostAnalysis -and -not `$runResourceGroups
`$analysisMode = $analysisModeLiteral
`$storageLocation = $storageLocationLiteral
`$storageAccount = $storageAccountLiteral
`$containerOrFileSystem = $containerLiteral
`$prefix = $prefixLiteral
`$historyPath = $historyPathLiteral
`$historyRoot = $historyRootLiteral
`$settingsPath = $settingsPathLiteral
`$agreementId = $agreementIdLiteral
`$customerName = $customerNameLiteral
`$agreementStartDate = [datetime]$agreementStartDateLiteral
`$agreementEndDate = [datetime]$agreementEndDateLiteral
`$commitmentAmount = [decimal]$commitmentAmountLiteral
`$commitmentCurrency = $commitmentCurrencyLiteral
`$pacingWarningPercent = [decimal]$pacingWarningLiteral
`$pacingCriticalPercent = [decimal]$pacingCriticalLiteral

if (`$azureCloud -notin @("AzureCloud", "AzureUSGovernment")) {
    throw "Unsupported Azure cloud '`$azureCloud'. Use AzureCloud or AzureUSGovernment."
}

`$currentCloud = az cloud show --query name --output tsv 2>`$null
if (`$LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(`$currentCloud) -or `$currentCloud.Trim() -ne `$azureCloud) {
    Write-Host "Setting Azure CLI cloud to `$azureCloud..."
    az cloud set --name `$azureCloud | Out-Null
    if (`$LASTEXITCODE -ne 0) { throw "Could not set Azure CLI cloud to '`$azureCloud'." }
}

function ConvertTo-TmdlStringLiteral {
    param([AllowNull()][string]`$Value)

    if (`$null -eq `$Value) {
        `$Value = ""
    }

    return '"' + (`$Value -replace '"', '""') + '"'
}

function Set-TmdlExpressionDefault {
    param(
        [Parameter(Mandatory)]
        [string]`$Content,

        [Parameter(Mandatory)]
        [string]`$Name,

        [AllowNull()]
        [string]`$Value
    )

    `$literal = ConvertTo-TmdlStringLiteral `$Value
    `$pattern = "(?m)^(expression\s+`$Name\s*=\s*)(.*?)(\s+meta\s+\[)"
    return [regex]::Replace(`$Content, `$pattern, {
        param(`$match)
        return `$match.Groups[1].Value + `$literal + `$match.Groups[3].Value
    })
}

function Assert-PowerBiDesktopClosed {
    `$powerBiProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        `$_.ProcessName -like "PBIDesktop*"
    })

    if (`$powerBiProcesses.Count -gt 0) {
        `$processList = (`$powerBiProcesses | ForEach-Object { "`$(`$_.ProcessName) (PID `$(`$_.Id))" }) -join ", "
        throw "Power BI Desktop appears to be running: `$processList. Save and close the PBIP before this script updates Power BI project files."
    }
}

function Update-PowerBiProjectParameters {
    param(
        [Parameter(Mandatory)]
        [string]`$ScriptRoot,

        [Parameter(Mandatory)]
        [string]`$SettingsPath
    )

    `$solutionRoot = Split-Path -Parent `$ScriptRoot
    `$expressionsPath = Join-Path `$solutionRoot "powerbi\Cost-Management.SemanticModel\definition\expressions.tmdl"
    if (-not (Test-Path `$expressionsPath)) {
        Write-Warning "Power BI expressions file was not found: `$expressionsPath"
        return
    }

    Assert-PowerBiDesktopClosed

    `$settings = Get-Content `$SettingsPath -Raw | ConvertFrom-Json
    `$content = Get-Content `$expressionsPath -Raw
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "AnalysisMode" -Value `$settings.AnalysisMode
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "StorageLocation" -Value `$settings.StorageLocation
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "LocalDataRoot" -Value `$settings.LocalDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "HistoryDataRoot" -Value `$settings.HistoryDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "BlobDataRoot" -Value `$settings.BlobDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "AdlsDataRoot" -Value `$settings.AdlsDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "SharePointDataRoot" -Value `$settings.SharePointDataRoot
    `$utf8NoBom = [System.Text.UTF8Encoding]::new(`$false)
    [System.IO.File]::WriteAllText(`$expressionsPath, `$content, `$utf8NoBom)
    Write-Host "Updated Power BI parameter defaults: `$expressionsPath"
}

function Select-FinOpsHistoryRows {
    param(
        [Parameter(Mandatory)]
        [string]`$CsvPath,

        [Parameter(Mandatory)]
        [string]`$Period,

        [Parameter(Mandatory)]
        [string]`$RunId,

        [Parameter(Mandatory)]
        [string]`$ExportedUtc
    )

    Import-Csv -Path `$CsvPath | ForEach-Object {
        `$usageText = [string]`$_.UsageDate
        `$historyMonth = if (`$usageText.Length -ge 6) { "`$(`$usageText.Substring(0, 4))-`$(`$usageText.Substring(4, 2))" } else { "" }

        [pscustomobject][ordered]@{
            HistoryMonth = `$historyMonth
            ExportRunId = `$RunId
            ExportedUtc = `$ExportedUtc
            Period = `$Period
            SubscriptionName = `$_.SubscriptionName
            SubscriptionId = `$_.SubscriptionId
            UsageQuantity = `$_.UsageQuantity
            Cost = `$_.Cost
            UsageDate = `$_.UsageDate
            ServiceName = `$_.ServiceName
            ResourceLocation = `$_.ResourceLocation
            Meter = `$_.Meter
            Product = `$_.Product
            PartNumber = `$_.PartNumber
            UnitOfMeasure = `$_.UnitOfMeasure
            Currency = `$_.Currency
            ArmRegionName = `$_.ArmRegionName
            RetailMatchStatus = `$_.RetailMatchStatus
            RetailCandidateCount = `$_.RetailCandidateCount
            RetailSkuId = `$_.RetailSkuId
            RetailMeterId = `$_.RetailMeterId
            RetailProductId = `$_.RetailProductId
            RetailProductName = `$_.RetailProductName
            RetailSkuName = `$_.RetailSkuName
            RetailMeterName = `$_.RetailMeterName
            RetailArmRegionName = `$_.RetailArmRegionName
            RetailUnitOfMeasure = `$_.RetailUnitOfMeasure
            RetailPrice = `$_.RetailPrice
            RetailUnitPrice = `$_.RetailUnitPrice
            RetailCurrencyCode = `$_.RetailCurrencyCode
        }
    }
}

function Update-FinOpsCostHistory {
    param(
        [Parameter(Mandatory)]
        [string]`$OutputRoot,

        [Parameter(Mandatory)]
        [string]`$HistoryPath
    )

    `$mtdPath = Join-Path `$OutputRoot "mtd-cost-by-retail-join-enriched.csv"
    `$lastMonthPath = Join-Path `$OutputRoot "last-month-cost-by-retail-join-enriched.csv"
    `$customPath = Join-Path `$OutputRoot "custom-cost-by-retail-join-enriched.csv"
    if (-not (Test-Path `$mtdPath) -or -not (Test-Path `$lastMonthPath)) {
        throw "History mode requires Retail Prices enrichment files. Clear 'Skip Retail Prices lookup' and rerun the cost export."
    }

    `$runId = Split-Path -Leaf `$OutputRoot
    `$exportedUtc = (Get-Date).ToUniversalTime().ToString("o")
    `$newRows = @(
        Select-FinOpsHistoryRows -CsvPath `$mtdPath -Period "MTD" -RunId `$runId -ExportedUtc `$exportedUtc
        Select-FinOpsHistoryRows -CsvPath `$lastMonthPath -Period "Last Month" -RunId `$runId -ExportedUtc `$exportedUtc
    )
    if (Test-Path `$customPath) {
        `$newRows += Select-FinOpsHistoryRows -CsvPath `$customPath -Period "Custom" -RunId `$runId -ExportedUtc `$exportedUtc
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent `$HistoryPath) -Force | Out-Null
    `$existingRows = if (Test-Path `$HistoryPath) { @(Import-Csv -Path `$HistoryPath) } else { @() }
    `$replaceKeys = @{}
    foreach (`$row in `$newRows) {
        `$replaceKeys["`$(`$row.HistoryMonth)|`$(`$row.Period)"] = `$true
    }

    `$keptRows = @(
        `$existingRows | Where-Object {
            -not `$replaceKeys.ContainsKey("`$(`$_.HistoryMonth)|`$(`$_.Period)")
        }
    )

    `$allRows = @(`$keptRows) + @(`$newRows)
    `$allRows |
        Sort-Object HistoryMonth, Period, SubscriptionName, ServiceName, ResourceLocation, Meter, UsageDate |
        Export-Csv -Path `$HistoryPath -NoTypeInformation -Encoding UTF8

    Copy-Item -Path `$HistoryPath -Destination (Join-Path `$OutputRoot "cost-retail-history.csv") -Force
    Write-Host "Historical cost file updated: `$HistoryPath"
    Write-Host "Historical cost file copied to: `$((Join-Path `$OutputRoot "cost-retail-history.csv"))"
}

function Select-FinOpsNormalizedHistoryRows {
    param(
        [Parameter(Mandatory)]
        [string]`$CsvPath,

        [Parameter(Mandatory)]
        [string]`$RunId,

        [Parameter(Mandatory)]
        [string]`$ExportedUtc
    )

    Import-Csv -Path `$CsvPath | ForEach-Object {
        `$usageText = [string]`$_.UsageDate
        `$historyMonth = if (`$usageText.Length -ge 6) { "`$(`$usageText.Substring(0, 4))-`$(`$usageText.Substring(4, 2))" } else { "" }
        `$row = [ordered]@{
            HistoryMonth = `$historyMonth
            ExportRunId = `$RunId
            ExportedUtc = `$ExportedUtc
        }

        foreach (`$property in `$_.PSObject.Properties) {
            `$row[`$property.Name] = `$property.Value
        }

        [pscustomobject]`$row
    }
}

function Update-FinOpsNormalizedHistoryFile {
    param(
        [Parameter(Mandatory)]
        [string]`$OutputRoot,

        [Parameter(Mandatory)]
        [string]`$HistoryRoot,

        [Parameter(Mandatory)]
        [string]`$FileName,

        [Parameter(Mandatory)]
        [string]`$HistoryFileName
    )

    `$currentPath = Join-Path `$OutputRoot `$FileName
    if (-not (Test-Path `$currentPath)) {
        Write-Warning "Normalized history file was skipped because the current run file was not found: `$currentPath"
        return
    }

    New-Item -ItemType Directory -Path `$HistoryRoot -Force | Out-Null
    `$historyFilePath = Join-Path `$HistoryRoot `$HistoryFileName
    `$runId = Split-Path -Leaf `$OutputRoot
    `$exportedUtc = (Get-Date).ToUniversalTime().ToString("o")
    `$newRows = @(Select-FinOpsNormalizedHistoryRows -CsvPath `$currentPath -RunId `$runId -ExportedUtc `$exportedUtc)
    `$existingRows = if (Test-Path `$historyFilePath) { @(Import-Csv -Path `$historyFilePath) } else { @() }
    `$replaceKeys = @{}
    foreach (`$row in `$newRows) {
        `$replaceKeys["`$(`$row.HistoryMonth)|`$(`$row.Period)"] = `$true
    }

    `$keptRows = @(
        `$existingRows | Where-Object {
            -not `$replaceKeys.ContainsKey("`$(`$_.HistoryMonth)|`$(`$_.Period)")
        }
    )

    `$allRows = @(`$keptRows) + @(`$newRows)
    `$allRows |
        Sort-Object HistoryMonth, Period, SubscriptionName, ServiceName, ArmRegionName, MeterKey, UsageDate |
        Export-Csv -Path `$historyFilePath -NoTypeInformation -Encoding UTF8

    Copy-Item -Path `$historyFilePath -Destination (Join-Path `$OutputRoot `$HistoryFileName) -Force
    Write-Host "Normalized history file updated: `$historyFilePath"
    Write-Host "Normalized history file copied to: `$((Join-Path `$OutputRoot `$HistoryFileName))"
}

function Update-FinOpsNormalizedHistories {
    param(
        [Parameter(Mandatory)]
        [string]`$OutputRoot,

        [Parameter(Mandatory)]
        [string]`$HistoryRoot
    )

    Update-FinOpsNormalizedHistoryFile -OutputRoot `$OutputRoot -HistoryRoot `$HistoryRoot -FileName "fact-cost-usage.csv" -HistoryFileName "fact-cost-usage-history.csv"
    Update-FinOpsNormalizedHistoryFile -OutputRoot `$OutputRoot -HistoryRoot `$HistoryRoot -FileName "fact-retail-price-match.csv" -HistoryFileName "fact-retail-price-match-history.csv"
}

Start-Transcript -Path (Join-Path `$outputRoot "finops-data-pull.log") -Force
try {
    Write-Host "Output folder: `$outputRoot"
    Write-Host "Power BI storage settings: `$settingsPath"
    if (-not `$onlyBillingContactAudit) {
        Update-PowerBiProjectParameters -ScriptRoot `$scriptRoot -SettingsPath `$settingsPath
    }

    if (`$runCostAnalysis) {
        `$costArgs = @{
            OutputDir = `$outputRoot
            AsOfDate = `$asOfDate
        }
        if (`$customRangeEnabled) {
            `$costArgs.CustomStartDate = [datetime]`$customStartDate
            `$costArgs.CustomEndDate = [datetime]`$customEndDate
        }
        if (`$tenantId) { `$costArgs.TenantId = `$tenantId }
        if (`$subscriptionIds.Count -gt 0) { `$costArgs.SubscriptionId = `$subscriptionIds }
        if (`$installAzureCli) { `$costArgs.InstallAzureCli = `$true }
        if (`$skipRetailPriceLookup) { `$costArgs.SkipRetailPriceLookup = `$true }

        & (Join-Path `$scriptRoot "Get-CostAnalysis.ps1") @costArgs
    }

    if (`$runResourceGroups) {
        `$resourceArgs = @{
            OutputDir = `$outputRoot
        }
        if (`$installAzureCli) { `$resourceArgs.InstallAzureCli = `$true }
        if (`$subscriptionIds.Count -eq 1) {
            `$resourceArgs.SubscriptionId = `$subscriptionIds[0]
        }
        else {
            `$resourceArgs.AllSubscriptions = `$true
        }

        & (Join-Path `$scriptRoot "Get-AzureResourceGroupsByLocation.ps1") @resourceArgs
    }

    if (`$runBillingContactAudit) {
        `$billingAuditArgs = @{
            OutputDir = (Join-Path `$outputRoot "billing-contact-audit")
            SubscriptionId = `$subscriptionIds
            IncludeInvoices = `$true
        }
        if (`$tenantId) { `$billingAuditArgs.TenantId = `$tenantId }
        if (`$installAzureCli) { `$billingAuditArgs.InstallAzureCli = `$true }

        & (Join-Path `$scriptRoot "Get-AzureBillingContactAudit.ps1") @billingAuditArgs
    }

    if (`$analysisMode -eq "History" -and -not `$onlyBillingContactAudit) {
        if (-not `$runCostAnalysis) {
            throw "History mode requires the Cost Management export."
        }

        Update-FinOpsCostHistory -OutputRoot `$outputRoot -HistoryPath `$historyPath
        Update-FinOpsNormalizedHistories -OutputRoot `$outputRoot -HistoryRoot `$historyRoot
    }

    if (`$runCostAnalysis -and -not `$skipRetailPriceLookup) {
        `$auditArgs = @{
            OutputRoot = `$outputRoot
            HistoryRoot = `$historyRoot
            AnalysisMode = `$analysisMode
            TenantId = `$tenantId
            SubscriptionIds = `$subscriptionIds
            AsOfDate = `$asOfDate
            StorageLocation = `$storageLocation
            SettingsPath = `$settingsPath
            AgreementId = `$agreementId
            CustomerName = `$customerName
            AgreementStartDate = `$agreementStartDate
            AgreementEndDate = `$agreementEndDate
            CommitmentAmount = `$commitmentAmount
            CommitmentCurrency = `$commitmentCurrency
            PacingWarningPercent = `$pacingWarningPercent
            PacingCriticalPercent = `$pacingCriticalPercent
        }

        & (Join-Path `$scriptRoot "New-FinOpsAuditArtifacts.ps1") @auditArgs
    }
    elseif (`$runCostAnalysis) {
        Write-Warning "MACC audit artifacts require Retail Prices enrichment. Clear 'Skip Retail Prices lookup' to generate agreement, ledger, exception, and price evidence files."
    }

    if (`$storageLocation -eq "AzureBlob") {
        Write-Host "Uploading output to Azure Blob Storage..."
        `$uploadArgs = @(
            "storage", "blob", "upload-batch",
            "--account-name", `$storageAccount,
            "--destination", `$containerOrFileSystem,
            "--source", `$outputRoot,
            "--overwrite", "true",
            "--auth-mode", "login"
        )
        if (`$prefix) { `$uploadArgs += @("--destination-path", `$prefix) }
        az @uploadArgs
        if (`$LASTEXITCODE -ne 0) { throw "Azure Blob upload failed." }
    }
    elseif (`$storageLocation -eq "ADLSGen2") {
        Write-Host "Uploading output to ADLS Gen2..."
        `$uploadArgs = @(
            "storage", "fs", "directory", "upload",
            "--account-name", `$storageAccount,
            "--file-system", `$containerOrFileSystem,
            "--source", `$outputRoot,
            "--destination-path", $(if ($prefixLiteral -eq "''") { "'.'" } else { $prefixLiteral }),
            "--recursive",
            "--overwrite", "true",
            "--auth-mode", "login"
        )
        az @uploadArgs
        if (`$LASTEXITCODE -ne 0) { throw "ADLS Gen2 upload failed." }
    }

    Write-Host ""
    Write-Host "Done. Configure Power BI parameters from $settingsPathLiteral."
}
finally {
    Stop-Transcript
}
"@

    $runScriptPath = Join-Path $runRoot "run-finops-data-pull.ps1"
    $runScript | Set-Content -Path $runScriptPath -Encoding UTF8
    return [pscustomobject]@{
        RunRoot = $runRoot
        RunScriptPath = $runScriptPath
        SettingsPath = $settingsPath
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Azure FinOps MACC Retail Data Pull"
$form.Size = New-Object System.Drawing.Size(920, 700)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(900, 680)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($tabs)

$runTab = New-Object System.Windows.Forms.TabPage
$runTab.Text = "Run export"
$tabs.TabPages.Add($runTab)

$localTab = New-Object System.Windows.Forms.TabPage
$localTab.Text = "Local"
$tabs.TabPages.Add($localTab)

$blobTab = New-Object System.Windows.Forms.TabPage
$blobTab.Text = "Azure Blob"
$tabs.TabPages.Add($blobTab)

$adlsTab = New-Object System.Windows.Forms.TabPage
$adlsTab.Text = "ADLS Gen2"
$tabs.TabPages.Add($adlsTab)

$sharePointTab = New-Object System.Windows.Forms.TabPage
$sharePointTab.Text = "SharePoint"
$tabs.TabPages.Add($sharePointTab)

$agreementTab = New-Object System.Windows.Forms.TabPage
$agreementTab.Text = "Agreement"
$tabs.TabPages.Add($agreementTab)

$settingsTab = New-Object System.Windows.Forms.TabPage
$settingsTab.Text = "Settings"
$tabs.TabPages.Add($settingsTab)

$instructionsTab = New-Object System.Windows.Forms.TabPage
$instructionsTab.Text = "Instructions"
$tabs.TabPages.Add($instructionsTab)

$runTab.Controls.Add((New-Label "Tenant ID (optional)" 20 25))
$tenantTextBox = New-TextBox 210 22 360
$runTab.Controls.Add($tenantTextBox)

$runTab.Controls.Add((New-Label "Azure cloud" 590 25 90))
$azureCloudComboBox = New-Object System.Windows.Forms.ComboBox
$azureCloudComboBox.DropDownStyle = "DropDownList"
$azureCloudComboBox.Location = New-Object System.Drawing.Point(680, 22)
$azureCloudComboBox.Size = New-Object System.Drawing.Size(180, 24)
[void]$azureCloudComboBox.Items.AddRange(@("AzureCloud", "AzureUSGovernment"))
$azureCloudComboBox.SelectedItem = "AzureCloud"
$runTab.Controls.Add($azureCloudComboBox)

$runTab.Controls.Add((New-Label "Subscriptions" 20 65))
$loadSubscriptionsButton = New-Object System.Windows.Forms.Button
$loadSubscriptionsButton.Text = "Load from tenant"
$loadSubscriptionsButton.Location = New-Object System.Drawing.Point(210, 62)
$loadSubscriptionsButton.Size = New-Object System.Drawing.Size(130, 28)
$runTab.Controls.Add($loadSubscriptionsButton)

$selectAllSubscriptionsButton = New-Object System.Windows.Forms.Button
$selectAllSubscriptionsButton.Text = "Select all"
$selectAllSubscriptionsButton.Location = New-Object System.Drawing.Point(350, 62)
$selectAllSubscriptionsButton.Size = New-Object System.Drawing.Size(90, 28)
$runTab.Controls.Add($selectAllSubscriptionsButton)

$clearSubscriptionsButton = New-Object System.Windows.Forms.Button
$clearSubscriptionsButton.Text = "Clear"
$clearSubscriptionsButton.Location = New-Object System.Drawing.Point(450, 62)
$clearSubscriptionsButton.Size = New-Object System.Drawing.Size(90, 28)
$runTab.Controls.Add($clearSubscriptionsButton)

$subscriptionStatusLabel = New-Label "Load subscriptions for cost/resource exports. Billing audit can run without selections." 550 66 315 36
$runTab.Controls.Add($subscriptionStatusLabel)

$subscriptionListBox = New-Object System.Windows.Forms.CheckedListBox
$subscriptionListBox.Location = New-Object System.Drawing.Point(210, 98)
$subscriptionListBox.Size = New-Object System.Drawing.Size(600, 96)
$subscriptionListBox.CheckOnClick = $true
$subscriptionListBox.DisplayMember = "DisplayName"
$runTab.Controls.Add($subscriptionListBox)

$runTab.Controls.Add((New-Label "As-of date" 20 210))
$asOfDatePicker = New-Object System.Windows.Forms.DateTimePicker
$asOfDatePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$asOfDatePicker.Location = New-Object System.Drawing.Point(210, 206)
$asOfDatePicker.Size = New-Object System.Drawing.Size(180, 24)
$runTab.Controls.Add($asOfDatePicker)

$customRangeCheckBox = New-CheckBox "Also export custom range" 420 207 $false 200
$runTab.Controls.Add($customRangeCheckBox)
$runTab.Controls.Add((New-Label "Start" 620 210 45))
$customStartDatePicker = New-Object System.Windows.Forms.DateTimePicker
$customStartDatePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$customStartDatePicker.Location = New-Object System.Drawing.Point(665, 206)
$customStartDatePicker.Size = New-Object System.Drawing.Size(90, 24)
$customStartDatePicker.Value = (Get-Date -Day 1)
$runTab.Controls.Add($customStartDatePicker)
$runTab.Controls.Add((New-Label "End" 760 210 35))
$customEndDatePicker = New-Object System.Windows.Forms.DateTimePicker
$customEndDatePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$customEndDatePicker.Location = New-Object System.Drawing.Point(795, 206)
$customEndDatePicker.Size = New-Object System.Drawing.Size(90, 24)
$runTab.Controls.Add($customEndDatePicker)

$runCostCheckBox = New-CheckBox "Run Cost Management export" 210 245 $true 280
$runResourceGroupsCheckBox = New-CheckBox "Run resource group location export" 500 245 $true 300
$installCliCheckBox = New-CheckBox "Install Azure CLI if missing" 210 280 $false 280
$skipRetailCheckBox = New-CheckBox "Skip Retail Prices lookup" 500 280 $false 300
$runBillingContactAuditCheckBox = New-CheckBox "Run Azure billing contact audit" 210 315 $true 300
$runTab.Controls.AddRange(@($runCostCheckBox, $runResourceGroupsCheckBox, $installCliCheckBox, $skipRetailCheckBox, $runBillingContactAuditCheckBox))

$runTab.Controls.Add((New-Label "Save output to" 20 355))
$destinationComboBox = New-Object System.Windows.Forms.ComboBox
$destinationComboBox.DropDownStyle = "DropDownList"
$destinationComboBox.Location = New-Object System.Drawing.Point(210, 351)
$destinationComboBox.Size = New-Object System.Drawing.Size(220, 24)
[void]$destinationComboBox.Items.AddRange(@("Local", "AzureBlob", "ADLSGen2", "SharePoint"))
$destinationComboBox.SelectedIndex = 0
$runTab.Controls.Add($destinationComboBox)

$summaryTextBox = New-Object System.Windows.Forms.TextBox
$summaryTextBox.Location = New-Object System.Drawing.Point(20, 405)
$summaryTextBox.Size = New-Object System.Drawing.Size(840, 125)
$summaryTextBox.Multiline = $true
$summaryTextBox.ScrollBars = "Vertical"
$summaryTextBox.ReadOnly = $true
$summaryTextBox.Text = "Choose export and storage options, then click Run. A PowerShell window opens to execute the export and upload steps."
$runTab.Controls.Add($summaryTextBox)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run export"
$runButton.Location = New-Object System.Drawing.Point(20, 555)
$runButton.Size = New-Object System.Drawing.Size(130, 34)
$runTab.Controls.Add($runButton)

$openOutputButton = New-Object System.Windows.Forms.Button
$openOutputButton.Text = "Open output root"
$openOutputButton.Location = New-Object System.Drawing.Point(165, 555)
$openOutputButton.Size = New-Object System.Drawing.Size(140, 34)
$runTab.Controls.Add($openOutputButton)

$changePurposeButton = New-Object System.Windows.Forms.Button
$changePurposeButton.Text = "Change purpose"
$changePurposeButton.Location = New-Object System.Drawing.Point(320, 555)
$changePurposeButton.Size = New-Object System.Drawing.Size(145, 34)
$runTab.Controls.Add($changePurposeButton)

$saveSettingsButton = New-Object System.Windows.Forms.Button
$saveSettingsButton.Text = "Save settings"
$saveSettingsButton.Location = New-Object System.Drawing.Point(480, 555)
$saveSettingsButton.Size = New-Object System.Drawing.Size(130, 34)
$runTab.Controls.Add($saveSettingsButton)

$loadSettingsButton = New-Object System.Windows.Forms.Button
$loadSettingsButton.Text = "Load settings"
$loadSettingsButton.Location = New-Object System.Drawing.Point(625, 555)
$loadSettingsButton.Size = New-Object System.Drawing.Size(130, 34)
$runTab.Controls.Add($loadSettingsButton)

$localTab.Controls.Add((New-Label "Local output root" 20 30))
$localOutputTextBox = New-TextBox 190 27 560 $script:DefaultOutputRoot
$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(765, 25)
$browseButton.Size = New-Object System.Drawing.Size(80, 28)
$localTab.Controls.AddRange(@($localOutputTextBox, $browseButton))

$localTab.Controls.Add((New-Label "History root" 20 70))
$historyRootTextBox = New-TextBox 190 67 560 (Join-Path $script:DefaultOutputRoot "history")
$historyBrowseButton = New-Object System.Windows.Forms.Button
$historyBrowseButton.Text = "Browse"
$historyBrowseButton.Location = New-Object System.Drawing.Point(765, 65)
$historyBrowseButton.Size = New-Object System.Drawing.Size(80, 28)
$localTab.Controls.AddRange(@($historyRootTextBox, $historyBrowseButton))

$localInfo = New-Object System.Windows.Forms.TextBox
$localInfo.Location = New-Object System.Drawing.Point(20, 115)
$localInfo.Size = New-Object System.Drawing.Size(825, 220)
$localInfo.Multiline = $true
$localInfo.ReadOnly = $true
$localInfo.Text = @"
Local mode writes directly under the selected output root.

Each run creates a timestamped run-* folder. Use that folder as the Power BI LocalDataRoot parameter value. The launcher also writes powerbi-storage-settings.json in the run folder with the exact parameter values.

History root stores durable files such as cost-retail-history.csv and macc-benefit-ledger.csv across runs. If settings are loaded, the saved history location is reused.
"@
$localTab.Controls.Add($localInfo)

$blobTab.Controls.Add((New-Label "Storage account" 20 30))
$blobAccountTextBox = New-TextBox 190 27 520
$blobTab.Controls.Add($blobAccountTextBox)
$blobTab.Controls.Add((New-Label "Container" 20 70))
$blobContainerTextBox = New-TextBox 190 67 520
$blobTab.Controls.Add($blobContainerTextBox)
$blobTab.Controls.Add((New-Label "Virtual folder prefix" 20 110))
$blobPrefixTextBox = New-TextBox 190 107 520 "finops-cost-management"
$blobTab.Controls.Add($blobPrefixTextBox)

$blobInfo = New-Object System.Windows.Forms.TextBox
$blobInfo.Location = New-Object System.Drawing.Point(20, 155)
$blobInfo.Size = New-Object System.Drawing.Size(825, 250)
$blobInfo.Multiline = $true
$blobInfo.ReadOnly = $true
$blobInfo.Text = @"
Azure Blob mode stages files locally, then uploads the run folder with:
az storage blob upload-batch --auth-mode login

Before running, sign in with Azure CLI and make sure your identity has permission to write blobs. In Power BI, set:
StorageLocation = AzureBlob
BlobDataRoot = https://<account>.blob.core.windows.net/<container>/<prefix>/
"@
$blobTab.Controls.Add($blobInfo)

$adlsTab.Controls.Add((New-Label "Storage account" 20 30))
$adlsAccountTextBox = New-TextBox 190 27 520
$adlsTab.Controls.Add($adlsAccountTextBox)
$adlsTab.Controls.Add((New-Label "File system" 20 70))
$adlsFileSystemTextBox = New-TextBox 190 67 520
$adlsTab.Controls.Add($adlsFileSystemTextBox)
$adlsTab.Controls.Add((New-Label "Folder path" 20 110))
$adlsPrefixTextBox = New-TextBox 190 107 520 "finops-cost-management"
$adlsTab.Controls.Add($adlsPrefixTextBox)

$adlsInfo = New-Object System.Windows.Forms.TextBox
$adlsInfo.Location = New-Object System.Drawing.Point(20, 155)
$adlsInfo.Size = New-Object System.Drawing.Size(825, 250)
$adlsInfo.Multiline = $true
$adlsInfo.ReadOnly = $true
$adlsInfo.Text = @"
ADLS Gen2 mode stages files locally, then uploads the run folder with:
az storage fs directory upload --auth-mode login

Before running, sign in with Azure CLI and make sure your identity has Storage Blob Data Contributor or equivalent permissions. In Power BI, set:
StorageLocation = ADLSGen2
AdlsDataRoot = https://<account>.dfs.core.windows.net/<file-system>/<folder-path>/
"@
$adlsTab.Controls.Add($adlsInfo)

$sharePointTab.Controls.Add((New-Label "Document library folder URL" 20 30 180))
$sharePointRootTextBox = New-TextBox 220 27 600 "https://<tenant>.sharepoint.com/sites/<site>/Shared%20Documents/finops-cost-management/"
$sharePointTab.Controls.Add($sharePointRootTextBox)

$sharePointInfo = New-Object System.Windows.Forms.TextBox
$sharePointInfo.Location = New-Object System.Drawing.Point(20, 80)
$sharePointInfo.Size = New-Object System.Drawing.Size(825, 285)
$sharePointInfo.Multiline = $true
$sharePointInfo.ReadOnly = $true
$sharePointInfo.Text = @"
SharePoint mode stages files locally and configures Power BI to read from a SharePoint document library folder.

Use the folder URL for the document library path that will contain the generated CSV files, for example:
https://<tenant>.sharepoint.com/sites/<site>/Shared%20Documents/finops-cost-management/

After the export finishes, copy or sync the generated CSV files from the run folder to this SharePoint folder. In Power BI, set:
StorageLocation = SharePoint
SharePointDataRoot = https://<tenant>.sharepoint.com/sites/<site>/Shared%20Documents/finops-cost-management/

Power BI will prompt for organizational account credentials for the SharePoint HTTPS endpoint if credentials are not already configured.
"@
$sharePointTab.Controls.Add($sharePointInfo)

$agreementTab.Controls.Add((New-Label "Agreement ID" 20 30 160))
$agreementIdTextBox = New-TextBox 220 27 260 "MACC-Agreement"
$agreementTab.Controls.Add($agreementIdTextBox)

$agreementTab.Controls.Add((New-Label "Customer name" 20 70 160))
$customerNameTextBox = New-TextBox 220 67 420
$agreementTab.Controls.Add($customerNameTextBox)

$agreementTab.Controls.Add((New-Label "Agreement start" 20 110 160))
$agreementStartDatePicker = New-Object System.Windows.Forms.DateTimePicker
$agreementStartDatePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$agreementStartDatePicker.Location = New-Object System.Drawing.Point(220, 106)
$agreementStartDatePicker.Size = New-Object System.Drawing.Size(180, 24)
$agreementStartDatePicker.Value = (Get-Date -Day 1)
$agreementTab.Controls.Add($agreementStartDatePicker)

$agreementTab.Controls.Add((New-Label "Agreement end" 430 110 130))
$agreementEndDatePicker = New-Object System.Windows.Forms.DateTimePicker
$agreementEndDatePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$agreementEndDatePicker.Location = New-Object System.Drawing.Point(570, 106)
$agreementEndDatePicker.Size = New-Object System.Drawing.Size(180, 24)
$agreementEndDatePicker.Value = (Get-Date -Day 1).AddYears(1).AddDays(-1)
$agreementTab.Controls.Add($agreementEndDatePicker)

$agreementTab.Controls.Add((New-Label "Commitment amount" 20 150 170))
$commitmentAmountTextBox = New-TextBox 220 147 180 "0"
$agreementTab.Controls.Add($commitmentAmountTextBox)

$agreementTab.Controls.Add((New-Label "Currency" 430 150 120))
$commitmentCurrencyTextBox = New-TextBox 570 147 100 "USD"
$agreementTab.Controls.Add($commitmentCurrencyTextBox)

$agreementTab.Controls.Add((New-Label "Watch threshold %" 20 190 170))
$pacingWarningTextBox = New-TextBox 220 187 100 "10"
$agreementTab.Controls.Add($pacingWarningTextBox)

$agreementTab.Controls.Add((New-Label "At-risk threshold %" 430 190 140))
$pacingCriticalTextBox = New-TextBox 570 187 100 "20"
$agreementTab.Controls.Add($pacingCriticalTextBox)

$agreementInfo = New-Object System.Windows.Forms.TextBox
$agreementInfo.Location = New-Object System.Drawing.Point(20, 235)
$agreementInfo.Size = New-Object System.Drawing.Size(825, 260)
$agreementInfo.Multiline = $true
$agreementInfo.ReadOnly = $true
$agreementInfo.ScrollBars = "Vertical"
$agreementInfo.Text = @"
Agreement settings drive MACC burn-down, pacing, and audit outputs.

Each run writes agreement-config.csv, macc-agreement-status.csv, macc-benefit-ledger.csv, agreement-price-audit.csv, retail-match-exceptions.csv, retail-price-snapshot.csv, data-quality-snapshot.csv, export-run-manifest.csv/json, billing-reconciliation.csv, and ownership-mapping.csv.

Use the commitment amount and dates from the customer's MACC agreement. The watch and at-risk thresholds compare eligible spend to expected burn as of the run date.

Keep agreement metadata generic if the output will be shared broadly. Do not put secrets or tenant credentials in these fields.
"@
$agreementTab.Controls.Add($agreementInfo)

$settingsTab.Controls.Add((New-Label "Settings JSON file" 20 30 170))
$settingsPathTextBox = New-TextBox 190 27 560 $script:LauncherSettingsPath
$settingsTab.Controls.Add($settingsPathTextBox)

$browseSettingsButton = New-Object System.Windows.Forms.Button
$browseSettingsButton.Text = "Browse"
$browseSettingsButton.Location = New-Object System.Drawing.Point(765, 25)
$browseSettingsButton.Size = New-Object System.Drawing.Size(80, 28)
$settingsTab.Controls.Add($browseSettingsButton)

$settingsInfo = New-Object System.Windows.Forms.TextBox
$settingsInfo.Location = New-Object System.Drawing.Point(20, 80)
$settingsInfo.Size = New-Object System.Drawing.Size(825, 260)
$settingsInfo.Multiline = $true
$settingsInfo.ReadOnly = $true
$settingsInfo.Text = @"
Choose where launcher settings are saved and loaded from.

The settings JSON stores:
- analysis purpose
- tenant ID
- selected subscription IDs
- export options
- output root
- storage destination fields
- agreement and MACC pacing fields

Use Browse to pick an existing settings JSON or choose a new JSON file location. Save Settings and Load Settings on the Run export tab use this file.

If you choose a custom settings file, the launcher stores a pointer in the default settings file so the same custom file is used next time.
"@
$settingsTab.Controls.Add($settingsInfo)

$instructionsTextBox = New-Object System.Windows.Forms.TextBox
$instructionsTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$instructionsTextBox.Multiline = $true
$instructionsTextBox.ScrollBars = "Vertical"
$instructionsTextBox.ReadOnly = $true
$instructionsTextBox.Text = @"
Operating flow

1. Open this launcher from PowerShell:
   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1

2. On Run export, choose AzureCloud or AzureUSGovernment, enter an optional tenant ID, click Load from tenant, and check the subscriptions to include.

3. On Agreement, enter the customer's MACC agreement ID, term, commitment amount, currency, and pacing thresholds.

4. Keep Run Azure billing contact audit selected when you need invoice recipient, sold-to, bill-to, PO, billing profile, invoice section, subscription billing property, and billing-role evidence.

5. Choose Local, AzureBlob, ADLSGen2, or SharePoint. Configure the matching tab before running.

6. Click Run export. A separate PowerShell window runs the data pull. Keep it open until it reports Done.

7. Open the generated powerbi-storage-settings.json from the run folder and copy the values into Power BI Desktop parameters:
   StorageLocation
   LocalDataRoot
   HistoryDataRoot
   BlobDataRoot
   AdlsDataRoot
   SharePointDataRoot

8. If SharePoint was selected, copy or sync the generated CSV files from the run folder to the configured SharePoint document library folder.

9. Refresh the PBIP model.

10. Review MACC audit files:
   agreement-config.csv
   macc-agreement-status.csv
   macc-benefit-ledger.csv
   agreement-price-audit.csv
   retail-match-exceptions.csv
   retail-price-snapshot.csv
   data-quality-snapshot.csv
   export-run-manifest.csv/json
   billing-reconciliation.csv
   ownership-mapping.csv

11. Review billing contact audit files under billing-contact-audit:
   Azure-Billing-Contact-Audit-*.md
   billing-accounts.csv
   billing-profiles.csv
   invoice-sections.csv
   subscription-billing-properties.csv
   billing-role-assignments.csv
   invoices.csv

Notes

- Cloud upload uses Azure CLI auth-mode login, so no storage secrets are saved by the launcher.
- The Power BI base path must end with a slash.
- For Blob, ADLS, or SharePoint reads, configure Power BI credentials for the HTTPS endpoint or use an approved SAS-based endpoint if your environment requires it.
"@
$instructionsTab.Controls.Add($instructionsTextBox)

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose local output root"
    $dialog.SelectedPath = $localOutputTextBox.Text
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $localOutputTextBox.Text = $dialog.SelectedPath
        if ([string]::IsNullOrWhiteSpace($historyRootTextBox.Text)) {
            $historyRootTextBox.Text = Join-Path $dialog.SelectedPath "history"
        }
    }
})

$historyBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose durable history root"
    $dialog.SelectedPath = $historyRootTextBox.Text
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $historyRootTextBox.Text = $dialog.SelectedPath
    }
})

function Sync-LauncherSettingsPathFromForm {
    if (-not [string]::IsNullOrWhiteSpace($settingsPathTextBox.Text)) {
        $script:LauncherSettingsPath = $settingsPathTextBox.Text.Trim()
    }
}

function Select-LauncherSettingsPath {
    param([string]$Title = "Choose launcher settings JSON file")

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = $Title
    $dialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $dialog.FileName = Split-Path -Leaf $settingsPathTextBox.Text
    $currentDirectory = Split-Path -Parent $settingsPathTextBox.Text
    if (-not [string]::IsNullOrWhiteSpace($currentDirectory) -and (Test-Path $currentDirectory)) {
        $dialog.InitialDirectory = $currentDirectory
    }

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $settingsPathTextBox.Text = $dialog.FileName
        Sync-LauncherSettingsPathFromForm
        return $true
    }

    return $false
}

$browseSettingsButton.Add_Click({
    [void](Select-LauncherSettingsPath)
})

$openOutputButton.Add_Click({
    if (Test-Path $localOutputTextBox.Text) {
        Start-Process explorer.exe -ArgumentList $localOutputTextBox.Text
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Output root does not exist yet: $($localOutputTextBox.Text)", "Output root", "OK", "Information") | Out-Null
    }
})

function Get-SelectedSubscriptionIds {
    return @($subscriptionListBox.CheckedItems | ForEach-Object { $_.SubscriptionId })
}

function Set-CheckedSubscriptionsById {
    param([string[]]$SubscriptionIds)

    if (-not $SubscriptionIds) {
        return
    }

    $selected = @{}
    foreach ($id in $SubscriptionIds) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $selected[$id.Trim().ToLowerInvariant()] = $true
        }
    }

    for ($i = 0; $i -lt $subscriptionListBox.Items.Count; $i++) {
        $item = $subscriptionListBox.Items[$i]
        $isChecked = $selected.ContainsKey(([string]$item.SubscriptionId).ToLowerInvariant())
        $subscriptionListBox.SetItemChecked($i, $isChecked)
    }
}

function Get-LauncherSettingsFromForm {
    return @{
        AnalysisMode = $script:AnalysisMode
        AzureCloud = [string]$azureCloudComboBox.SelectedItem
        TenantId = $tenantTextBox.Text.Trim()
        SelectedSubscriptionIds = @(Get-SelectedSubscriptionIds)
        CustomRangeEnabled = $customRangeCheckBox.Checked
        CustomStartDate = $customStartDatePicker.Value.ToString("yyyy-MM-dd")
        CustomEndDate = $customEndDatePicker.Value.ToString("yyyy-MM-dd")
        RunCostAnalysis = $runCostCheckBox.Checked
        RunResourceGroups = $runResourceGroupsCheckBox.Checked
        RunBillingContactAudit = $runBillingContactAuditCheckBox.Checked
        InstallAzureCli = $installCliCheckBox.Checked
        SkipRetailPriceLookup = $skipRetailCheckBox.Checked
        StorageLocation = [string]$destinationComboBox.SelectedItem
        LocalOutputRoot = $localOutputTextBox.Text.Trim()
        HistoryRoot = $historyRootTextBox.Text.Trim()
        BlobStorageAccount = $blobAccountTextBox.Text.Trim()
        BlobContainer = $blobContainerTextBox.Text.Trim()
        BlobPrefix = $blobPrefixTextBox.Text.Trim()
        AdlsStorageAccount = $adlsAccountTextBox.Text.Trim()
        AdlsFileSystem = $adlsFileSystemTextBox.Text.Trim()
        AdlsPath = $adlsPrefixTextBox.Text.Trim()
        SharePointDataRoot = $sharePointRootTextBox.Text.Trim()
        AgreementId = $agreementIdTextBox.Text.Trim()
        CustomerName = $customerNameTextBox.Text.Trim()
        AgreementStartDate = $agreementStartDatePicker.Value.ToString("yyyy-MM-dd")
        AgreementEndDate = $agreementEndDatePicker.Value.ToString("yyyy-MM-dd")
        CommitmentAmount = $commitmentAmountTextBox.Text.Trim()
        CommitmentCurrency = $commitmentCurrencyTextBox.Text.Trim()
        PacingWarningPercent = $pacingWarningTextBox.Text.Trim()
        PacingCriticalPercent = $pacingCriticalTextBox.Text.Trim()
    }
}

function Apply-LauncherSettingsToForm {
    param([Parameter(Mandatory)]$Settings)

    if ($Settings.AnalysisMode -in @("Current", "History")) {
        Set-AnalysisMode -AnalysisMode $Settings.AnalysisMode
    }
    if ($Settings.AzureCloud -in @("AzureCloud", "AzureUSGovernment")) {
        $azureCloudComboBox.SelectedItem = [string]$Settings.AzureCloud
    }
    if ($null -ne $Settings.TenantId) { $tenantTextBox.Text = [string]$Settings.TenantId }
    $asOfDatePicker.Value = (Get-Date).Date
    if ($null -ne $Settings.CustomRangeEnabled) { $customRangeCheckBox.Checked = [bool]$Settings.CustomRangeEnabled }
    if ($Settings.CustomStartDate) {
        $parsedCustomStartDate = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Settings.CustomStartDate, [ref]$parsedCustomStartDate)) {
            $customStartDatePicker.Value = $parsedCustomStartDate
        }
    }
    if ($Settings.CustomEndDate) {
        $parsedCustomEndDate = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Settings.CustomEndDate, [ref]$parsedCustomEndDate)) {
            $customEndDatePicker.Value = $parsedCustomEndDate
        }
    }
    if ($null -ne $Settings.RunCostAnalysis) { $runCostCheckBox.Checked = [bool]$Settings.RunCostAnalysis }
    if ($null -ne $Settings.RunResourceGroups) { $runResourceGroupsCheckBox.Checked = [bool]$Settings.RunResourceGroups }
    if ($null -ne $Settings.RunBillingContactAudit) { $runBillingContactAuditCheckBox.Checked = [bool]$Settings.RunBillingContactAudit }
    if ($null -ne $Settings.InstallAzureCli) { $installCliCheckBox.Checked = [bool]$Settings.InstallAzureCli }
    if ($null -ne $Settings.SkipRetailPriceLookup) { $skipRetailCheckBox.Checked = [bool]$Settings.SkipRetailPriceLookup }
    if ($Settings.StorageLocation -in @("Local", "AzureBlob", "ADLSGen2", "SharePoint")) {
        $destinationComboBox.SelectedItem = [string]$Settings.StorageLocation
    }
    if ($null -ne $Settings.LocalOutputRoot) { $localOutputTextBox.Text = [string]$Settings.LocalOutputRoot }
    if ($null -ne $Settings.HistoryRoot) {
        $historyRootTextBox.Text = [string]$Settings.HistoryRoot
    }
    elseif ($null -ne $Settings.LocalOutputRoot -and -not [string]::IsNullOrWhiteSpace([string]$Settings.LocalOutputRoot)) {
        $historyRootTextBox.Text = Join-Path ([string]$Settings.LocalOutputRoot) "history"
    }
    if ($null -ne $Settings.BlobStorageAccount) { $blobAccountTextBox.Text = [string]$Settings.BlobStorageAccount }
    if ($null -ne $Settings.BlobContainer) { $blobContainerTextBox.Text = [string]$Settings.BlobContainer }
    if ($null -ne $Settings.BlobPrefix) { $blobPrefixTextBox.Text = [string]$Settings.BlobPrefix }
    if ($null -ne $Settings.AdlsStorageAccount) { $adlsAccountTextBox.Text = [string]$Settings.AdlsStorageAccount }
    if ($null -ne $Settings.AdlsFileSystem) { $adlsFileSystemTextBox.Text = [string]$Settings.AdlsFileSystem }
    if ($null -ne $Settings.AdlsPath) { $adlsPrefixTextBox.Text = [string]$Settings.AdlsPath }
    if ($null -ne $Settings.SharePointDataRoot) { $sharePointRootTextBox.Text = [string]$Settings.SharePointDataRoot }
    if ($null -ne $Settings.AgreementId) { $agreementIdTextBox.Text = [string]$Settings.AgreementId }
    if ($null -ne $Settings.CustomerName) { $customerNameTextBox.Text = [string]$Settings.CustomerName }
    if ($Settings.AgreementStartDate) {
        $parsedStartDate = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Settings.AgreementStartDate, [ref]$parsedStartDate)) {
            $agreementStartDatePicker.Value = $parsedStartDate
        }
    }
    if ($Settings.AgreementEndDate) {
        $parsedEndDate = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Settings.AgreementEndDate, [ref]$parsedEndDate)) {
            $agreementEndDatePicker.Value = $parsedEndDate
        }
    }
    if ($null -ne $Settings.CommitmentAmount) { $commitmentAmountTextBox.Text = [string]$Settings.CommitmentAmount }
    if ($null -ne $Settings.CommitmentCurrency) { $commitmentCurrencyTextBox.Text = [string]$Settings.CommitmentCurrency }
    if ($null -ne $Settings.PacingWarningPercent) { $pacingWarningTextBox.Text = [string]$Settings.PacingWarningPercent }
    if ($null -ne $Settings.PacingCriticalPercent) { $pacingCriticalTextBox.Text = [string]$Settings.PacingCriticalPercent }
    if ($Settings.SelectedSubscriptionIds) {
        Set-CheckedSubscriptionsById -SubscriptionIds @($Settings.SelectedSubscriptionIds)
    }
}

$loadSubscriptionsButton.Add_Click({
    try {
        $subscriptionStatusLabel.Text = "Loading subscriptions..."
        $form.Refresh()

        $subscriptions = @(Get-AzureSubscriptionsForUi -TenantId $tenantTextBox.Text -InstallAzureCli $installCliCheckBox.Checked -AzureCloud ([string]$azureCloudComboBox.SelectedItem))
        $subscriptionListBox.Items.Clear()

        foreach ($subscription in $subscriptions) {
            $displayName = "$($subscription.name) [$($subscription.id)]"
            if ($subscription.tenantId) {
                $displayName += " - tenant $($subscription.tenantId)"
            }

            $item = [pscustomobject]@{
                DisplayName = $displayName
                SubscriptionId = [string]$subscription.id
                SubscriptionName = [string]$subscription.name
                TenantId = [string]$subscription.tenantId
            }
            [void]$subscriptionListBox.Items.Add($item, $true)
        }

        $settings = Get-LauncherSettings
        if ($settings.SelectedSubscriptionIds) {
            Set-CheckedSubscriptionsById -SubscriptionIds @($settings.SelectedSubscriptionIds)
        }

        $subscriptionStatusLabel.Text = "Loaded $($subscriptions.Count) enabled subscription(s)."
    }
    catch {
        $subscriptionStatusLabel.Text = "Subscription load failed."
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cannot load subscriptions", "OK", "Error") | Out-Null
    }
})

$saveSettingsButton.Add_Click({
    try {
        if (-not (Select-LauncherSettingsPath -Title "Save launcher settings as")) {
            return
        }
        Sync-LauncherSettingsPathFromForm
        Save-LauncherSettings -Updates (Get-LauncherSettingsFromForm)
        [System.Windows.Forms.MessageBox]::Show("Settings saved to $script:LauncherSettingsPath.", "Settings saved", "OK", "Information") | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cannot save settings", "OK", "Error") | Out-Null
    }
})

$loadSettingsButton.Add_Click({
    try {
        Sync-LauncherSettingsPathFromForm
        $settings = Get-LauncherSettings
        $settingsPathTextBox.Text = $script:LauncherSettingsPath
        Apply-LauncherSettingsToForm -Settings $settings
        [System.Windows.Forms.MessageBox]::Show("Settings loaded from $script:LauncherSettingsPath. Load subscriptions to reapply saved subscription checks.", "Settings loaded", "OK", "Information") | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cannot load settings", "OK", "Error") | Out-Null
    }
})

$selectAllSubscriptionsButton.Add_Click({
    for ($i = 0; $i -lt $subscriptionListBox.Items.Count; $i++) {
        $subscriptionListBox.SetItemChecked($i, $true)
    }
})

$clearSubscriptionsButton.Add_Click({
    for ($i = 0; $i -lt $subscriptionListBox.Items.Count; $i++) {
        $subscriptionListBox.SetItemChecked($i, $false)
    }
})

function Set-AnalysisMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Current", "History")]
        [string]$AnalysisMode,

        [switch]$Persist
    )

    $script:AnalysisMode = $AnalysisMode
    $analysisPurposeText = if ($script:AnalysisMode -eq "History") {
        "Running history - build cost-retail-history.csv for historical MACC savings analysis"
    }
    else {
        "Current view - analyze month-to-date and last month only"
    }

    $form.Text = "Azure FinOps MACC Retail Data Pull - $($script:AnalysisMode)"
    $summaryTextBox.Text = "Analysis purpose: $analysisPurposeText`r`n`r`nChoose export and storage options, then click Run. A PowerShell window opens to execute the export and upload steps."

    if ($script:AnalysisMode -eq "History") {
        $skipRetailCheckBox.Checked = $false
    }

    if ($Persist) {
        Save-LauncherSettings -Updates @{ AnalysisMode = $script:AnalysisMode }
    }
}

$changePurposeButton.Add_Click({
    $selectedMode = Show-AnalysisPurposeDialog -CurrentMode $script:AnalysisMode
    if ($selectedMode) {
        Set-AnalysisMode -AnalysisMode $selectedMode -Persist
        [System.Windows.Forms.MessageBox]::Show("Analysis purpose saved as '$selectedMode'. The startup question will stay hidden unless you use Change purpose again.", "Analysis purpose saved", "OK", "Information") | Out-Null
    }
})

$destinationComboBox.Add_SelectedIndexChanged({
    switch ([string]$destinationComboBox.SelectedItem) {
        "Local" { $tabs.SelectedTab = $localTab }
        "AzureBlob" { $tabs.SelectedTab = $blobTab }
        "ADLSGen2" { $tabs.SelectedTab = $adlsTab }
        "SharePoint" { $tabs.SelectedTab = $sharePointTab }
    }
})

$runButton.Add_Click({
    try {
        $subscriptionIds = @($subscriptionListBox.CheckedItems | ForEach-Object { $_.SubscriptionId })

        $storageLocation = [string]$destinationComboBox.SelectedItem
        $storageAccount = ""
        $containerOrFileSystem = ""
        $prefix = ""
        $sharePointDataRoot = ""

        if ($storageLocation -eq "AzureBlob") {
            $storageAccount = $blobAccountTextBox.Text.Trim()
            $containerOrFileSystem = $blobContainerTextBox.Text.Trim()
            $prefix = $blobPrefixTextBox.Text.Trim()
        }
        elseif ($storageLocation -eq "ADLSGen2") {
            $storageAccount = $adlsAccountTextBox.Text.Trim()
            $containerOrFileSystem = $adlsFileSystemTextBox.Text.Trim()
            $prefix = $adlsPrefixTextBox.Text.Trim()
        }
        elseif ($storageLocation -eq "SharePoint") {
            $sharePointDataRoot = $sharePointRootTextBox.Text.Trim()
        }

        if (-not $runCostCheckBox.Checked -and -not $runResourceGroupsCheckBox.Checked -and -not $runBillingContactAuditCheckBox.Checked) {
            throw "Select at least one export to run."
        }

        $requiresSubscriptionSelection = $runCostCheckBox.Checked -or $runResourceGroupsCheckBox.Checked

        if ($requiresSubscriptionSelection -and $subscriptionListBox.Items.Count -eq 0) {
            throw "Load subscriptions from the tenant before running Cost Management or resource group exports."
        }

        if ($requiresSubscriptionSelection -and $subscriptionIds.Count -eq 0) {
            throw "Select at least one subscription to include for Cost Management or resource group exports."
        }

        $onlyBillingContactAudit = $runBillingContactAuditCheckBox.Checked -and -not $runCostCheckBox.Checked -and -not $runResourceGroupsCheckBox.Checked

        if ($script:AnalysisMode -eq "History" -and -not $onlyBillingContactAudit -and -not $runCostCheckBox.Checked) {
            throw "Running history requires the Cost Management export."
        }

        if ($script:AnalysisMode -eq "History" -and -not $onlyBillingContactAudit -and $skipRetailCheckBox.Checked) {
            throw "Running history requires Retail Prices enrichment so estimated MACC savings can be calculated."
        }

        if ($customRangeCheckBox.Checked -and $customEndDatePicker.Value.Date -lt $customStartDatePicker.Value.Date) {
            throw "Custom range end date must be on or after the start date."
        }

        if ([string]::IsNullOrWhiteSpace($localOutputTextBox.Text)) {
            throw "Local output root is required because cloud destinations are staged locally first."
        }

        if ([string]::IsNullOrWhiteSpace($historyRootTextBox.Text)) {
            $historyRootTextBox.Text = Join-Path $localOutputTextBox.Text.Trim() "history"
        }

        $commitmentAmount = 0D
        if (-not [decimal]::TryParse($commitmentAmountTextBox.Text.Trim(), [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$commitmentAmount)) {
            throw "Commitment amount must be a number."
        }

        $pacingWarningPercent = 10D
        if (-not [decimal]::TryParse($pacingWarningTextBox.Text.Trim(), [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pacingWarningPercent)) {
            throw "Watch threshold percent must be a number."
        }

        $pacingCriticalPercent = 20D
        if (-not [decimal]::TryParse($pacingCriticalTextBox.Text.Trim(), [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pacingCriticalPercent)) {
            throw "At-risk threshold percent must be a number."
        }

        if ($agreementEndDatePicker.Value.Date -lt $agreementStartDatePicker.Value.Date) {
            throw "Agreement end date must be on or after the agreement start date."
        }

        $config = @{
            AnalysisMode = $script:AnalysisMode
            AzureCloud = [string]$azureCloudComboBox.SelectedItem
            TenantId = $tenantTextBox.Text.Trim()
            SubscriptionIds = $subscriptionIds
            AsOfDate = $asOfDatePicker.Value
            CustomRangeEnabled = $customRangeCheckBox.Checked
            CustomStartDate = $customStartDatePicker.Value.Date
            CustomEndDate = $customEndDatePicker.Value.Date
            OutputRoot = $localOutputTextBox.Text.Trim()
            HistoryRoot = $historyRootTextBox.Text.Trim()
            RunCostAnalysis = $runCostCheckBox.Checked
            RunResourceGroups = $runResourceGroupsCheckBox.Checked
            RunBillingContactAudit = $runBillingContactAuditCheckBox.Checked
            InstallAzureCli = $installCliCheckBox.Checked
            SkipRetailPriceLookup = $skipRetailCheckBox.Checked
            StorageLocation = $storageLocation
            StorageAccount = $storageAccount
            ContainerOrFileSystem = $containerOrFileSystem
            Prefix = $prefix
            SharePointDataRoot = $sharePointDataRoot
            AgreementId = if ([string]::IsNullOrWhiteSpace($agreementIdTextBox.Text)) { "MACC-Agreement" } else { $agreementIdTextBox.Text.Trim() }
            CustomerName = $customerNameTextBox.Text.Trim()
            AgreementStartDate = $agreementStartDatePicker.Value.Date
            AgreementEndDate = $agreementEndDatePicker.Value.Date
            CommitmentAmount = $commitmentAmount.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            CommitmentCurrency = if ([string]::IsNullOrWhiteSpace($commitmentCurrencyTextBox.Text)) { "USD" } else { $commitmentCurrencyTextBox.Text.Trim().ToUpperInvariant() }
            PacingWarningPercent = $pacingWarningPercent.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            PacingCriticalPercent = $pacingCriticalPercent.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }

        $run = New-RunScript -Config $config
        $summaryTextBox.Text = @"
Run script created:
$($run.RunScriptPath)

Output folder:
$($run.RunRoot)

Power BI parameter settings:
$($run.SettingsPath)

A PowerShell execution window is opening now.
"@

        Start-Process powershell.exe -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-NoExit",
            "-File", $run.RunScriptPath
        )
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cannot start export", "OK", "Error") | Out-Null
    }
})

$launcherSettings = Get-LauncherSettings
$settingsPathTextBox.Text = $script:LauncherSettingsPath
if ($launcherSettings.AnalysisMode -in @("Current", "History")) {
    Apply-LauncherSettingsToForm -Settings $launcherSettings
}
else {
    $selectedMode = Show-AnalysisPurposeDialog
    if (-not $selectedMode) {
        return
    }

    Set-AnalysisMode -AnalysisMode $selectedMode -Persist
}

[void]$form.ShowDialog()
