# Tracing Notes

Use this file to capture development traces that explain why the solution behaves the way it does. Keep entries concise and avoid customer data, secrets, tenant IDs, subscription IDs, or storage keys.

## Decision log

| Decision | Rationale | Related files |
| --- | --- | --- |
| Stage cloud exports locally before upload | Existing export scripts produce local files; staging avoids rewriting core export logic and gives users a durable local run folder. | `scripts/Start-FinOpsDataPull.ps1`, `scripts/Get-CostAnalysis.ps1` |
| Use Azure CLI login auth for Blob and ADLS Gen2 uploads | Avoids storing account keys or SAS tokens in launcher settings. | `scripts/Start-FinOpsDataPull.ps1` |
| Store launcher settings as JSON | Keeps user selections portable and easy to inspect without registry writes. | `scripts/exports/finops-launcher-settings.json` |
| Emit Power BI parameter mapping per run | Reduces mismatch between export destination and semantic model refresh settings. | `powerbi-storage-settings.json`, `README.md` |
| Keep internal markdown under `internal-docs/` | Gives development memory without adding those notes to distribution packages. | `build-release.ps1` |

## Trace template

Copy this table when capturing a meaningful trace.

| Field | Value |
| --- | --- |
| Scenario |  |
| Command or action |  |
| Expected result |  |
| Actual result |  |
| Files reviewed |  |
| Outcome |  |

## Known validation commands

```powershell
Set-Location 'C:\Projects\Fabric\AzureFinOpsMaccRetailSolution'

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path 'scripts\Start-FinOpsDataPull.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null

if ($errors.Count) {
    $errors | ForEach-Object {
        '{0}:{1} {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
    }
    exit 1
}

'OK: launcher parses'
```

```powershell
Set-Location 'C:\Projects\Fabric\AzureFinOpsMaccRetailSolution'
.\build-release.ps1 -Version dev-smoke -Force -NoZip
Get-ChildItem '.\releases\AzureFinOpsMaccRetailSolution-vdev-smoke' -Recurse -Force |
    Where-Object { $_.FullName -like '*internal-docs*' }
```

The second command should return no `internal-docs` files.

## Troubleshooting notes

| Symptom | Likely area | Notes |
| --- | --- | --- |
| Power BI refresh cannot find CSV files | Parameter mismatch | Compare model parameters with the generated `powerbi-storage-settings.json`. |
| Blob upload fails | Azure CLI auth or RBAC | Confirm `az account show` and Storage Blob Data Contributor or equivalent data-plane access. |
| ADLS upload fails | Azure CLI auth, RBAC, or hierarchical namespace path | Confirm file system name and folder path; validate data-plane permissions. |
| Launcher does not remember settings | Settings path or JSON write failure | Check selected settings path and write permissions. |
| History page has missing trends | Missing or stale history file | Confirm history mode was selected and `cost-retail-history.csv` exists in the history root. |

## TMDL measure table fix

Power BI Desktop reported `Unsupported object type - measure is not a supported property in the current context` for `_Measures.tmdl` after MACC audit measures were inserted into the generated `_Measures` table. The fix was to remove those new measures from `_Measures.tmdl` and place them in a dedicated `MaccAuditMeasures.tmdl` table with standard table-child indentation, a hidden placeholder `Measures` column, and a model reference in `model.tmdl`.

## Missing export CSV fallback

A run at `C:\Projects\Fabric\AuditDumps\run-20260630-141844` produced only launcher/log files because Azure Cost Management returned `GatewayTimeout` before CSV exports were written. Power BI then failed refresh because the model pointed at that run folder. The semantic model now has `CsvHeaderColumns`, and `CsvFromSelectedStorage` / `CsvFromHistoryStorage` return empty header-shaped CSV tables when generated files are absent. Header-only placeholder CSVs were also created in the failed run folder so it can load as an empty dataset until the export is rerun successfully.

## Expressions TMDL single-line function fix

Power BI Desktop reported `InvalidLineType` in `expressions.tmdl` after `CsvHeaderColumns` was added as a multi-line M record. This PBIP expressions file uses one-line `expression ...` declarations, so `CsvHeaderColumns` was collapsed into a single-line expression while preserving the missing-file header map. A scan confirmed no expression declaration is followed by unsupported continuation lines.

## Power Query Number.Max fix

Power Query M does not export `Number.Max`. The missing-file fallback originally used `Number.Max(1, columnCount)` inside `CsvHeaderColumns`, which caused `Expression.Error: The import Number.Max matches no exports`. The expression now uses `if columnCount < 1 then 1 else columnCount` before building default column headers.

## Power Query cyclic reference fix

Power BI reported a cyclic reference starting at `mtd-cost-by-retail-join` after the missing-file fallback introduced a shared `CsvHeaderColumns` query. The helper was removed from `expressions.tmdl` and from `model.tmdl` query order. The CSV loaders now create simple column-count-shaped fallback CSV binaries directly, avoiding the shared query dependency. The failed run folder still contains explicit header-only CSV placeholders, so the current refresh can load typed empty tables.

## CSV loader column truncation fix

Power BI reported missing columns such as `SubscriptionId`, `SubscriptionName`, and `RetailUnitPrice` even though the run folder had header-only placeholder CSVs with those headers. The loader was forcing `Csv.Document(..., Columns = columnCount)` for both real files and synthetic fallbacks, and several existing queries pass stale column counts that are smaller than the actual generated headers. The loader now uses `Columns = SafeColumnCount` only when a file is missing and a synthetic fallback is created. Present CSV files are parsed without a forced column count, so their full headers are preserved.

## Launcher history root and audit argument fix

The generated audit script call previously used line continuation in a here-string and produced broken parameter lines such as `-OutputRoot $outputRoot`, causing prompts and `-OutputRoot is not recognized` errors. The launcher now emits a splatted `$auditArgs` hashtable for `New-FinOpsAuditArtifacts.ps1`. The Local tab also has an editable `History root` field, saved as `HistoryRoot` in launcher settings. `New-RunScript` uses the saved history root when present and otherwise defaults to `<LocalOutputRoot>\history`.
