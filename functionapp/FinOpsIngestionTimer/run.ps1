param($Timer)

$ErrorActionPreference = "Stop"

$functionRoot = Split-Path -Parent $PSScriptRoot
$solutionRoot = Split-Path -Parent $functionRoot
$runnerPath = Join-Path $solutionRoot "scripts\Invoke-FinOpsServerlessRun.ps1"

if (-not (Test-Path $runnerPath)) {
    throw "FinOps serverless runner was not found: $runnerPath"
}

Write-Host "Starting FinOps ingestion timer trigger at $(Get-Date -Format o)."
& $runnerPath
Write-Host "FinOps ingestion timer trigger completed at $(Get-Date -Format o)."
