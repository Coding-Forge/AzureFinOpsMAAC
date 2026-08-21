param($Timer)

$ErrorActionPreference = "Stop"

$functionRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path $functionRoot "scripts\Invoke-FinOpsServerlessRun.ps1"

if (-not (Test-Path $runnerPath)) {
    throw "FinOps serverless runner was not found: $runnerPath"
}

Write-Host "Starting FinOps ingestion timer trigger at $(Get-Date -Format o)."
& $runnerPath
Write-Host "FinOps ingestion timer trigger completed at $(Get-Date -Format o)."
