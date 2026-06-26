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

function Show-AnalysisPurposeDialog {
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
    $currentRadio.Checked = $true
    $purposeForm.Controls.Add($currentRadio)

    $currentDescription = New-Label "Best for a point-in-time review. Each run creates a new run folder, and Power BI reads the current MTD/last-month files." 58 92 540 44
    $purposeForm.Controls.Add($currentDescription)

    $historyRadio = New-Object System.Windows.Forms.RadioButton
    $historyRadio.Text = "Running history - build a MACC savings history for Power BI"
    $historyRadio.Location = New-Object System.Drawing.Point(35, 145)
    $historyRadio.Size = New-Object System.Drawing.Size(560, 24)
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

function Ensure-AzureLoginForUi {
    param([string]$TenantId)

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
        [bool]$InstallAzureCli
    )

    Ensure-AzureCliForUi -InstallAzureCli $InstallAzureCli
    Ensure-AzureLoginForUi -TenantId $TenantId

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
    $historyRoot = Join-Path $Config.OutputRoot "history"
    $historyPath = Join-Path $historyRoot "cost-retail-history.csv"
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $settings = [ordered]@{
        AnalysisMode = $Config.AnalysisMode
        StorageLocation = $Config.StorageLocation
        LocalDataRoot = ConvertTo-BaseUrl -StorageLocation "Local" -LocalPath $runRoot
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
        CreatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $settingsPath = Join-Path $runRoot "powerbi-storage-settings.json"
    $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsPath -Encoding UTF8

    $subscriptionLiteral = "@()"
    if ($Config.SubscriptionIds.Count -gt 0) {
        $subscriptionLiteral = "@(" + (($Config.SubscriptionIds | ForEach-Object { ConvertTo-PowerShellLiteral $_ }) -join ", ") + ")"
    }

    $tenantLiteral = ConvertTo-PowerShellLiteral $Config.TenantId
    $outputLiteral = ConvertTo-PowerShellLiteral $runRoot
    $scriptRootLiteral = ConvertTo-PowerShellLiteral $PSScriptRoot
    $storageAccountLiteral = ConvertTo-PowerShellLiteral $Config.StorageAccount
    $containerLiteral = ConvertTo-PowerShellLiteral $Config.ContainerOrFileSystem
    $prefixLiteral = ConvertTo-PowerShellLiteral (($Config.Prefix -replace "\\", "/").Trim("/"))
    $settingsPathLiteral = ConvertTo-PowerShellLiteral $settingsPath
    $asOfDateLiteral = ConvertTo-PowerShellLiteral $Config.AsOfDate.ToString("yyyy-MM-dd")
    $analysisModeLiteral = ConvertTo-PowerShellLiteral $Config.AnalysisMode
    $historyPathLiteral = ConvertTo-PowerShellLiteral $historyPath

    $installAzureCli = if ($Config.InstallAzureCli) { '$true' } else { '$false' }
    $skipRetail = if ($Config.SkipRetailPriceLookup) { '$true' } else { '$false' }
    $runCost = if ($Config.RunCostAnalysis) { '$true' } else { '$false' }
    $runResourceGroups = if ($Config.RunResourceGroups) { '$true' } else { '$false' }
    $storageLocationLiteral = ConvertTo-PowerShellLiteral $Config.StorageLocation

    $runScript = @"
`$ErrorActionPreference = "Stop"
`$scriptRoot = $scriptRootLiteral
`$outputRoot = $outputLiteral
`$tenantId = $tenantLiteral
`$subscriptionIds = $subscriptionLiteral
`$asOfDate = [datetime]$asOfDateLiteral
`$installAzureCli = $installAzureCli
`$skipRetailPriceLookup = $skipRetail
`$runCostAnalysis = $runCost
`$runResourceGroups = $runResourceGroups
`$analysisMode = $analysisModeLiteral
`$storageLocation = $storageLocationLiteral
`$storageAccount = $storageAccountLiteral
`$containerOrFileSystem = $containerLiteral
`$prefix = $prefixLiteral
`$historyPath = $historyPathLiteral
`$settingsPath = $settingsPathLiteral

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

    `$settings = Get-Content `$SettingsPath -Raw | ConvertFrom-Json
    `$content = Get-Content `$expressionsPath -Raw
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "AnalysisMode" -Value `$settings.AnalysisMode
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "StorageLocation" -Value `$settings.StorageLocation
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "LocalDataRoot" -Value `$settings.LocalDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "BlobDataRoot" -Value `$settings.BlobDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "AdlsDataRoot" -Value `$settings.AdlsDataRoot
    `$content = Set-TmdlExpressionDefault -Content `$content -Name "SharePointDataRoot" -Value `$settings.SharePointDataRoot
    Set-Content -Path `$expressionsPath -Value `$content -Encoding UTF8
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
    if (-not (Test-Path `$mtdPath) -or -not (Test-Path `$lastMonthPath)) {
        throw "History mode requires Retail Prices enrichment files. Clear 'Skip Retail Prices lookup' and rerun the cost export."
    }

    `$runId = Split-Path -Leaf `$OutputRoot
    `$exportedUtc = (Get-Date).ToUniversalTime().ToString("o")
    `$newRows = @(
        Select-FinOpsHistoryRows -CsvPath `$mtdPath -Period "MTD" -RunId `$runId -ExportedUtc `$exportedUtc
        Select-FinOpsHistoryRows -CsvPath `$lastMonthPath -Period "Last Month" -RunId `$runId -ExportedUtc `$exportedUtc
    )

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

Start-Transcript -Path (Join-Path `$outputRoot "finops-data-pull.log") -Force
try {
    Write-Host "Output folder: `$outputRoot"
    Write-Host "Power BI storage settings: `$settingsPath"
    Update-PowerBiProjectParameters -ScriptRoot `$scriptRoot -SettingsPath `$settingsPath

    if (`$runCostAnalysis) {
        `$costArgs = @{
            OutputDir = `$outputRoot
            AsOfDate = `$asOfDate
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

    if (`$analysisMode -eq "History") {
        if (-not `$runCostAnalysis) {
            throw "History mode requires the Cost Management export."
        }

        Update-FinOpsCostHistory -OutputRoot `$outputRoot -HistoryPath `$historyPath
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

$instructionsTab = New-Object System.Windows.Forms.TabPage
$instructionsTab.Text = "Instructions"
$tabs.TabPages.Add($instructionsTab)

$runTab.Controls.Add((New-Label "Tenant ID (optional)" 20 25))
$tenantTextBox = New-TextBox 210 22 600
$runTab.Controls.Add($tenantTextBox)

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

$subscriptionStatusLabel = New-Label "Load subscriptions, then check the subscriptions to include." 550 66 315 22
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

$runCostCheckBox = New-CheckBox "Run Cost Management export" 210 245 $true 280
$runResourceGroupsCheckBox = New-CheckBox "Run resource group location export" 500 245 $true 300
$installCliCheckBox = New-CheckBox "Install Azure CLI if missing" 210 280 $false 280
$skipRetailCheckBox = New-CheckBox "Skip Retail Prices lookup" 500 280 $false 300
$runTab.Controls.AddRange(@($runCostCheckBox, $runResourceGroupsCheckBox, $installCliCheckBox, $skipRetailCheckBox))

$runTab.Controls.Add((New-Label "Save output to" 20 325))
$destinationComboBox = New-Object System.Windows.Forms.ComboBox
$destinationComboBox.DropDownStyle = "DropDownList"
$destinationComboBox.Location = New-Object System.Drawing.Point(210, 321)
$destinationComboBox.Size = New-Object System.Drawing.Size(220, 24)
[void]$destinationComboBox.Items.AddRange(@("Local", "AzureBlob", "ADLSGen2", "SharePoint"))
$destinationComboBox.SelectedIndex = 0
$runTab.Controls.Add($destinationComboBox)

$summaryTextBox = New-Object System.Windows.Forms.TextBox
$summaryTextBox.Location = New-Object System.Drawing.Point(20, 375)
$summaryTextBox.Size = New-Object System.Drawing.Size(840, 155)
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

$localTab.Controls.Add((New-Label "Local output root" 20 30))
$localOutputTextBox = New-TextBox 190 27 560 $script:DefaultOutputRoot
$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(765, 25)
$browseButton.Size = New-Object System.Drawing.Size(80, 28)
$localTab.Controls.AddRange(@($localOutputTextBox, $browseButton))

$localInfo = New-Object System.Windows.Forms.TextBox
$localInfo.Location = New-Object System.Drawing.Point(20, 80)
$localInfo.Size = New-Object System.Drawing.Size(825, 220)
$localInfo.Multiline = $true
$localInfo.ReadOnly = $true
$localInfo.Text = @"
Local mode writes directly under the selected output root.

Each run creates a timestamped run-* folder. Use that folder as the Power BI LocalDataRoot parameter value. The launcher also writes powerbi-storage-settings.json in the run folder with the exact parameter values.
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

$instructionsTextBox = New-Object System.Windows.Forms.TextBox
$instructionsTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$instructionsTextBox.Multiline = $true
$instructionsTextBox.ScrollBars = "Vertical"
$instructionsTextBox.ReadOnly = $true
$instructionsTextBox.Text = @"
Operating flow

1. Open this launcher from PowerShell:
   powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1

2. On Run export, enter an optional tenant ID, click Load from tenant, and check the subscriptions to include.

3. Choose Local, AzureBlob, ADLSGen2, or SharePoint. Configure the matching tab before running.

4. Click Run export. A separate PowerShell window runs the data pull. Keep it open until it reports Done.

5. Open the generated powerbi-storage-settings.json from the run folder and copy the values into Power BI Desktop parameters:
   StorageLocation
   LocalDataRoot
   BlobDataRoot
   AdlsDataRoot
   SharePointDataRoot

6. If SharePoint was selected, copy or sync the generated CSV files from the run folder to the configured SharePoint document library folder.

7. Refresh the PBIP model.

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
    }
})

$openOutputButton.Add_Click({
    if (Test-Path $localOutputTextBox.Text) {
        Start-Process explorer.exe -ArgumentList $localOutputTextBox.Text
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Output root does not exist yet: $($localOutputTextBox.Text)", "Output root", "OK", "Information") | Out-Null
    }
})

$loadSubscriptionsButton.Add_Click({
    try {
        $subscriptionStatusLabel.Text = "Loading subscriptions..."
        $form.Refresh()

        $subscriptions = @(Get-AzureSubscriptionsForUi -TenantId $tenantTextBox.Text -InstallAzureCli $installCliCheckBox.Checked)
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

        $subscriptionStatusLabel.Text = "Loaded $($subscriptions.Count) enabled subscription(s)."
    }
    catch {
        $subscriptionStatusLabel.Text = "Subscription load failed."
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cannot load subscriptions", "OK", "Error") | Out-Null
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

        if (-not $runCostCheckBox.Checked -and -not $runResourceGroupsCheckBox.Checked) {
            throw "Select at least one export to run."
        }

        if ($subscriptionListBox.Items.Count -eq 0) {
            throw "Load subscriptions from the tenant before running the export."
        }

        if ($subscriptionIds.Count -eq 0) {
            throw "Select at least one subscription to include."
        }

        if ($script:AnalysisMode -eq "History" -and -not $runCostCheckBox.Checked) {
            throw "Running history requires the Cost Management export."
        }

        if ($script:AnalysisMode -eq "History" -and $skipRetailCheckBox.Checked) {
            throw "Running history requires Retail Prices enrichment so estimated MACC savings can be calculated."
        }

        if ([string]::IsNullOrWhiteSpace($localOutputTextBox.Text)) {
            throw "Local output root is required because cloud destinations are staged locally first."
        }

        $config = @{
            AnalysisMode = $script:AnalysisMode
            TenantId = $tenantTextBox.Text.Trim()
            SubscriptionIds = $subscriptionIds
            AsOfDate = $asOfDatePicker.Value
            OutputRoot = $localOutputTextBox.Text.Trim()
            RunCostAnalysis = $runCostCheckBox.Checked
            RunResourceGroups = $runResourceGroupsCheckBox.Checked
            InstallAzureCli = $installCliCheckBox.Checked
            SkipRetailPriceLookup = $skipRetailCheckBox.Checked
            StorageLocation = $storageLocation
            StorageAccount = $storageAccount
            ContainerOrFileSystem = $containerOrFileSystem
            Prefix = $prefix
            SharePointDataRoot = $sharePointDataRoot
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

$script:AnalysisMode = Show-AnalysisPurposeDialog
if (-not $script:AnalysisMode) {
    return
}

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

[void]$form.ShowDialog()
