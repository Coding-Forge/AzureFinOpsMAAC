<#
.SYNOPSIS
Builds a distributable release folder and zip for AzureFinOpsMaccRetailSolution.

.DESCRIPTION
Creates a clean release payload under .\releases, writes a manifest, and creates
a versioned zip file that can be attached to a GitHub release or shared directly.
Generated output, PBIP source, local Power BI cache/settings, and Git metadata
are excluded unless -IncludePbip is explicitly supplied for internal builds.
#>

[CmdletBinding()]
param(
    [string]$Version = (Get-Date -Format "yyyy.MM.dd"),

    [string]$OutputRoot,

    [switch]$Force,

    [switch]$NoZip,

    [switch]$RequirePbit,

    [switch]$ExcludePbip,

    [switch]$IncludePbip
)

$ErrorActionPreference = "Stop"

$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ScriptRoot "releases"
}

$SolutionName = "AzureFinOpsMaccRetailSolution"
$ReleaseName = "$SolutionName-v$Version"
$ReleaseRoot = Join-Path $OutputRoot $ReleaseName
$ZipPath = Join-Path $OutputRoot "$ReleaseName.zip"

function Test-ExcludedReleasePath {
    param([Parameter(Mandatory)][string]$RelativePath)

    $normalized = $RelativePath -replace "\\", "/"
    $excludePowerBiSource = -not $IncludePbip
    if ($excludePowerBiSource -and (
        $normalized -like "powerbi/*.pbip" -or
        $normalized -like "powerbi/*.Report/*" -or
        $normalized -like "powerbi/*.SemanticModel/*"
    )) {
        return $true
    }

    $excludePatterns = @(
        ".git/*",
        ".git",
        "internal-docs/*",
        "releases/*",
        "scripts/exports/*",
        "powerbi/*.Report/.pbi/*",
        "powerbi/*.SemanticModel/.pbi/*",
        "*.zip",
        "*.tmp",
        "*.log"
    )

    foreach ($pattern in $excludePatterns) {
        if ($normalized -like $pattern) {
            return $true
        }
    }

    return $false
}

function Get-GitValue {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return $null
    }

    $value = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($value | Select-Object -First 1)
}

function Get-RelativeReleasePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $pathFullPath = [System.IO.Path]::GetFullPath($Path)
    $rootUri = [System.Uri]::new($rootFullPath + [System.IO.Path]::DirectorySeparatorChar)
    $pathUri = [System.Uri]::new($pathFullPath)
    $relativeUri = $rootUri.MakeRelativeUri($pathUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
}

if ((Test-Path $ReleaseRoot) -and -not $Force) {
    throw "Release folder already exists: $ReleaseRoot. Use -Force to replace it."
}

if ((Test-Path $ZipPath) -and -not $Force -and -not $NoZip) {
    throw "Release zip already exists: $ZipPath. Use -Force to replace it."
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

if (Test-Path $ReleaseRoot) {
    Remove-Item -Path $ReleaseRoot -Recurse -Force
}

if ((Test-Path $ZipPath) -and -not $NoZip) {
    Remove-Item -Path $ZipPath -Force
}

New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null

$sourceFiles = Get-ChildItem -Path $ScriptRoot -Recurse -File -Force |
    Where-Object {
        $relativePath = Get-RelativeReleasePath -Root $ScriptRoot -Path $_.FullName
        -not (Test-ExcludedReleasePath -RelativePath $relativePath)
    }

$pbitFiles = @(
    $sourceFiles | Where-Object {
        $relativePath = Get-RelativeReleasePath -Root $ScriptRoot -Path $_.FullName
        $relativePath -like "template\*.pbit" -or $relativePath -like "powerbi\*.pbit"
    }
)

$pbipFiles = @(
    $sourceFiles | Where-Object {
        $relativePath = Get-RelativeReleasePath -Root $ScriptRoot -Path $_.FullName
        $relativePath -like "powerbi\*.pbip" -or
            $relativePath -like "powerbi\*.Report\*" -or
            $relativePath -like "powerbi\*.SemanticModel\*"
    }
)

if ($RequirePbit -and $pbitFiles.Count -eq 0) {
    throw "No Power BI template (.pbit) was found under $ScriptRoot\template or $ScriptRoot\powerbi. Export the customer distribution template before building with -RequirePbit."
}

if ((-not $IncludePbip) -and $pbitFiles.Count -eq 0) {
    throw "Cannot build a public release without a Power BI template (.pbit). Export a sanitized PBIT under $ScriptRoot\template first, or pass -IncludePbip for a local/internal PBIP-source package."
}

foreach ($file in $sourceFiles) {
    $relativePath = Get-RelativeReleasePath -Root $ScriptRoot -Path $file.FullName
    $destinationPath = Join-Path $ReleaseRoot $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath

    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -Path $file.FullName -Destination $destinationPath -Force
}

$commit = Get-GitValue -Arguments @("rev-parse", "HEAD")
$branch = Get-GitValue -Arguments @("branch", "--show-current")
$status = if (Get-Command git -ErrorAction SilentlyContinue) {
    $statusOutput = & git --no-pager status --short 2>$null
    if ($LASTEXITCODE -eq 0) { @($statusOutput) } else { @() }
}
else {
    @()
}

$manifest = [ordered]@{
    solutionName = $SolutionName
    version = $Version
    releaseName = $ReleaseName
    createdUtc = (Get-Date).ToUniversalTime().ToString("o")
    sourceRoot = $ScriptRoot
    gitBranch = $branch
    gitCommit = $commit
    gitHasUncommittedChanges = ($status.Count -gt 0)
    fileCount = @($sourceFiles).Count
    hasPbit = ($pbitFiles.Count -gt 0)
    hasPbip = ($pbipFiles.Count -gt 0)
    pbipExcluded = (-not $IncludePbip)
    pbitFiles = @($pbitFiles | ForEach-Object { Get-RelativeReleasePath -Root $ScriptRoot -Path $_.FullName })
    pbipFiles = @($pbipFiles | ForEach-Object { Get-RelativeReleasePath -Root $ScriptRoot -Path $_.FullName })
    excluded = @(
        ".git",
        "internal-docs",
        "releases",
        "scripts/exports",
        "powerbi/*.pbip",
        "powerbi/*.Report",
        "powerbi/*.SemanticModel",
        "powerbi/*.Report/.pbi",
        "powerbi/*.SemanticModel/.pbi",
        "*.zip",
        "*.tmp",
        "*.log"
    )
}

$manifestPath = Join-Path $ReleaseRoot "_release-manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

if (-not $NoZip) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipDirectory = Split-Path -Parent $ZipPath
    New-Item -ItemType Directory -Path $zipDirectory -Force | Out-Null
    if (Test-Path $ZipPath) {
        Remove-Item -Path $ZipPath -Force
    }

    $zipArchive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -Path $ReleaseRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
            $entryName = (Get-RelativeReleasePath -Root $ReleaseRoot -Path $_.FullName) -replace "\\", "/"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zipArchive,
                $_.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally {
        $zipArchive.Dispose()
    }

    $hash = Get-FileHash -Path $ZipPath -Algorithm SHA256
    $hashPath = "$ZipPath.sha256"
    "$($hash.Hash)  $(Split-Path -Leaf $ZipPath)" | Set-Content -Path $hashPath -Encoding ASCII
}

Write-Host ""
Write-Host "Release build complete."
Write-Host "Version:        $Version"
Write-Host "Release folder: $ReleaseRoot"
if ($pbitFiles.Count -gt 0) {
    Write-Host "PBIT files:     $($pbitFiles.Count)"
}
else {
    Write-Warning "No .pbit file was found under template or powerbi. The release still includes the PBIP source, but customer template distribution requires manually exporting a PBIT before building with -RequirePbit."
}
if ($pbipFiles.Count -gt 0) {
    Write-Host "PBIP files:     $($pbipFiles.Count)"
}
elseif (-not $IncludePbip) {
    Write-Host "PBIP source:    excluded"
}
if (-not $NoZip) {
    Write-Host "Release zip:    $ZipPath"
    Write-Host "SHA256 file:    $ZipPath.sha256"
}
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Test the zip on a clean machine or folder."
Write-Host "2. Commit the release changes."
Write-Host "3. Tag the commit, for example: git tag -a v$Version -m `"Release v$Version`""
Write-Host "4. Push the tag: git push origin v$Version"
