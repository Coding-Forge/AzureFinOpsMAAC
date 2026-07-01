# Solution Progress

## Solution goal

Build an Azure FinOps MACC vs Retail solution that pulls Azure Cost Management data, enriches it with Azure Retail Prices data, and presents current and historical savings insights in Power BI.

## Current implementation state

| Area | Status | Notes |
| --- | --- | --- |
| Cost extraction scripts | In progress | `scripts/Get-CostAnalysis.ps1` handles Cost Management export and retail enrichment behavior. |
| Windows launcher UI | In progress | `scripts/Start-FinOpsDataPull.ps1` provides a Windows Forms launcher for configuring and running exports. |
| Local output | Implemented | Exports stage to timestamped local run folders. |
| Azure Blob output | Implemented | Launcher uploads staged output with Azure CLI login auth. |
| ADLS Gen2 output | Implemented | Launcher uploads staged output with Azure CLI login auth. |
| SharePoint output | Documented/manual | Launcher captures the SharePoint folder URL for Power BI parameters; files are copied or synced outside the script. |
| Power BI parameters | In progress | Semantic model contains storage parameters for local, Blob, ADLS Gen2, and SharePoint locations. |
| Running history | In progress | Launcher supports a startup purpose for current view versus running history. |
| MACC agreement audit | Implemented | Launcher Agreement tab and `scripts/New-FinOpsAuditArtifacts.ps1` generate commitment status, benefit ledger, price audit, retail price snapshot, exceptions, data quality, run manifest, reconciliation, and ownership mapping files. |
| Power BI audit model | Implemented | Semantic model includes tables and measures for agreement status, benefit ledger, audit evidence, exceptions, quality snapshots, reconciliation, and ownership mapping. |
| Release packaging | In progress | `build-release.ps1` creates a clean release folder and zip while excluding generated and internal-only content. |

## Important files

| Path | Purpose |
| --- | --- |
| `scripts/Start-FinOpsDataPull.ps1` | Windows UI launcher for data pull configuration and execution. |
| `scripts/Get-CostAnalysis.ps1` | Core Cost Management and Azure Retail Prices export script. |
| `powerbi/Cost-Management.pbip` | Power BI project entry point. |
| `powerbi/Cost-Management.SemanticModel/definition/expressions.tmdl` | Power Query parameters and data source logic. |
| `README.md` | Customer-facing operation and setup guide. |
| `build-release.ps1` | Creates distribution releases. |
| `internal-docs/` | Development-only progress and trace notes; excluded from releases. |

## Current handoff notes

- The working tree has uncommitted changes across the launcher, cost script, README, semantic model, and report visual JSON files.
- The launcher writes `powerbi-storage-settings.json` into run output folders so users can copy matching parameter values into Power BI Desktop.
- Cloud destinations stage files locally first, then upload to Blob or ADLS Gen2 after a successful export.
- SharePoint is configured as a Power BI read location but currently depends on manual copy or sync of generated CSV files.
- The release script now excludes `internal-docs/*` so these progress notes do not ship.

## Open work

| Item | Notes |
| --- | --- |
| Validate launcher flow end to end | Confirm settings save/load, subscription selection, current/history mode, and each destination path. |
| Validate Power BI refresh paths | Confirm Power Query reads correctly for Local, Blob, ADLS Gen2, and SharePoint parameter combinations. |
| Confirm history behavior | Verify `cost-retail-history.csv` creation and append/update behavior. |
| Review MACC audit visuals | Add or polish report pages/cards for MACC commitment overview, benefit ledger, agreement price audit, exceptions, and reconciliation using the new semantic model tables. |
| Review PBIP visual changes | Ensure modified report pages render correctly in Power BI Desktop. |
| Release smoke test | Build a release zip and test from a clean folder. |

## Completion checklist

- Launcher parses without PowerShell syntax errors.
- Current-mode export succeeds for at least one subscription.
- History-mode export creates or updates expected history output.
- Blob upload succeeds using `az storage blob upload-batch --auth-mode login`.
- ADLS Gen2 upload succeeds using `az storage fs directory upload --auth-mode login`.
- Generated `powerbi-storage-settings.json` contains valid parameter values.
- Power BI Desktop opens the PBIP and refreshes using the selected storage location.
- Release zip does not contain `internal-docs`, `.git`, `scripts/exports`, local `.pbi` cache folders, logs, temp files, or prior zip files.



- HTML help expanded with report page explanations and technical/security guidance for script behavior, external calls, permissions, data outputs, and governance controls.
