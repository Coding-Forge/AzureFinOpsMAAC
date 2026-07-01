# Azure FinOps MACC vs Retail Solution

## Introduction

This solution helps compare actual Azure costs (including negotiated pricing effects such as MACC outcomes) with estimated public Azure retail pricing for the same usage profile.

The project includes:
- Power BI report and semantic model in PBIP format
- PowerShell automation scripts for cost extraction and enrichment
- Configurable data integration for local files, Azure Blob Storage, ADLS Gen2, or SharePoint document libraries
- Supporting documentation for dashboard interpretation and operations

## Repository Layout

- `powerbi/` - PBIP report (`Cost-Management.pbip`), report pages, visuals, and semantic model tables/measures
- `scripts/` - PowerShell scripts to extract and enrich cost data
- `docs/` - Guidance and dashboard documentation
- `pictures/` - Screenshot assets and visual references
- `schedules/` - Scheduling assets and helpers (if used)
- `tools/` - Utility helpers and local tooling
- `build-release.ps1` - Builds versioned release folders and zip files under `releases/`

## Data Source Configuration

The semantic model sources generated CSV files from the storage location selected for the export run. Configure these Power BI parameters before refresh:

| Parameter | Value |
| --- | --- |
| `AnalysisMode` | `Current` for MTD/last-month only, or `History` for running MACC savings history |
| `StorageLocation` | `Local`, `AzureBlob`, `ADLSGen2`, or `SharePoint` |
| `LocalDataRoot` | Local current run folder that contains the generated CSV files, ending with `\` |
| `HistoryDataRoot` | Local durable history folder that contains `cost-retail-history.csv`, ending with `\` |
| `BlobDataRoot` | Blob HTTPS base URL, for example `https://<account>.blob.core.windows.net/<container>/<prefix>/` |
| `AdlsDataRoot` | ADLS Gen2 HTTPS base URL, for example `https://<account>.dfs.core.windows.net/<filesystem>/<folder>/` |
| `SharePointDataRoot` | SharePoint document library folder URL, for example `https://<tenant>.sharepoint.com/sites/<site>/Shared%20Documents/<folder>/` |

The launcher writes `powerbi-storage-settings.json` into each run folder with the exact parameter values to copy into Power BI Desktop.

## Prerequisites

- Windows with PowerShell 7+ (or Windows PowerShell 5.1 for basic script execution)
- Azure CLI (`az`) authenticated to the target tenant/subscription
- Power BI Desktop (PBIP-capable build)
- Access rights to query Azure Cost Management data at the intended scope

## Quick Start

You can use either the latest tagged release zip or a cloned copy of the repository.

### Option A - Download the latest tagged release

1. Go to the repository's **Releases** page.
2. Download the latest `AzureFinOpsMaccRetailSolution-v<version>.zip` asset.
3. Extract the zip to a local folder such as:

```text
C:\Projects\Fabric\AzureFinOpsMaccRetailSolution
```

4. Open PowerShell in the extracted folder and launch the Windows UI:

```powershell
cd C:\Projects\Fabric\AzureFinOpsMaccRetailSolution
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

### Option B - Clone the repository

1. Clone or open the repository root in VS Code.
2. Launch the Windows UI from the repository root:

```powershell
cd C:\Projects\Fabric\AzureFinOpsMaccRetailSolution
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

### Run the solution

1. Choose the startup purpose: **Current view** or **Running history**. The launcher saves this choice and does not ask again unless you click **Change purpose**.
2. Click **Load from tenant**, select the subscriptions to include, choose the export options and storage destination, then click **Run export**.
3. Copy the generated parameter values from `powerbi-storage-settings.json` into Power BI Desktop.
4. Open `powerbi/Cost-Management.pbip` in Power BI Desktop and refresh the model.
5. Review pages:
- `FinOps MACC vs Retail Overview`
- `MACC Commitment Overview`
- `MACC Benefit Ledger`
- `Agreement Price Audit`
- `Coverage and Exceptions`
- `Billing and Ownership`
- `Granular Detail / Drillthrough`
- `Data Quality & Customer Actions`

## Windows Data Pull UI

Run `scripts/Start-FinOpsDataPull.ps1` to open the Windows Forms launcher. The UI includes:

- **Startup purpose** - choose **Current view** for MTD/last-month analysis or **Running history** to build `cost-retail-history.csv` for monthly MACC savings trends. The choice is saved in `scripts\exports\finops-launcher-settings.json`.
- **Change purpose** - reopens the startup purpose dialog and saves the new choice.
- **Save settings / Load settings** - saves and reloads launcher fields in `scripts\exports\finops-launcher-settings.json`, including tenant, selected storage destination, output root, script options, storage fields, and selected subscription IDs.
- **Settings** - choose the JSON settings file location with a browse dialog. Save Settings and Load Settings use the selected file. If a custom settings file is selected, the launcher remembers that path for the next startup.
- **Run export** - tenant, subscription loader with multi-select checkboxes, date, script selection, Azure CLI install option, Retail Prices lookup option, and destination selection.
- **Local** - local staging/output root. Every run creates a timestamped `run-*` folder.
- **Azure Blob** - storage account, container, and virtual folder prefix. Upload uses `az storage blob upload-batch --auth-mode login`.
- **ADLS Gen2** - storage account, file system, and folder path. Upload uses `az storage fs directory upload --auth-mode login`.
- **SharePoint** - document library folder URL for Power BI to read from. Copy or sync the generated CSV files to this folder after export.
- **Instructions** - operating steps and Power BI parameter mapping.

Cloud destinations are staged locally first because the existing export scripts write files. After a successful script run, the launcher uploads the run folder to the selected Blob container or ADLS Gen2 file system. For SharePoint, copy or sync the generated CSV files from the run folder to the configured document library folder. The launcher uses the signed-in Azure CLI identity for Blob and ADLS uploads and does not store storage account keys or SAS tokens.

Saved subscription IDs are reapplied after subscriptions are loaded from Azure. If the saved subscriptions are no longer visible to the signed-in account, they remain unchecked.

## Running History Mode

Choose **Running history** at startup when the customer wants Power BI to trend estimated MACC savings over time instead of only reviewing the current MTD and last-month exports.

History mode does not ask Power Query to scan every timestamped run folder. Instead, each run updates one durable history file. Power Query uses `HistoryDataRoot` for the historical fact table and `LocalDataRoot` for the supporting current-run files.

History mode:
- Requires the Cost Management export and Retail Prices enrichment.
- Maintains a stable local file at `<output-root>\history\cost-retail-history.csv`.
- Adds `HistoryMonth`, `ExportRunId`, `ExportedUtc`, `Period`, `SubscriptionName`, and `SubscriptionId` columns.
- Replaces the same `HistoryMonth` + `Period` slice when rerun, so rerunning June updates June MTD and May last-month rows instead of duplicating them.
- Copies the latest `cost-retail-history.csv` into the timestamped run folder so Blob, ADLS Gen2, SharePoint, or local Power BI refresh can consume it.

Duplicate handling is done by the launcher before Power BI reads the data. The history update keeps existing rows except rows whose key matches a new row's `HistoryMonth` + `Period`, then writes the combined result back to `cost-retail-history.csv`. This prevents duplicate month-period snapshots while allowing a rerun to refresh corrected or late-arriving Cost Management data.

For Power BI historical reporting, set:

```text
AnalysisMode = History
StorageLocation = <Local | AzureBlob | ADLSGen2 | SharePoint>
LocalDataRoot = <latest run folder that contains summary/supporting CSV files>
HistoryDataRoot = <output-root>\history\
```

For one-time analysis, set:

```text
AnalysisMode = Current
```

## MACC Agreement, Audit, and Long-Term Benefit Tracking

Use the **Agreement** tab in the launcher before running an export. Enter the agreement ID, optional customer name, agreement start/end dates, commitment amount/currency, and watch/at-risk pacing thresholds.

For guided customer help, open:

- `docs/help/index.html` - end-to-end launcher and Power BI report guide.
- `docs/help/faq.html` - FAQ and troubleshooting guide.

After each run with Retail Prices lookup enabled, the launcher calls `scripts/New-FinOpsAuditArtifacts.ps1` and creates these files in the run folder:

| File | How to use it |
| --- | --- |
| `agreement-config.csv` | Confirms the agreement metadata used for the run. |
| `macc-agreement-status.csv` | Shows eligible spend to date, remaining commitment, utilization %, expected burn, variance, required monthly run rate, and pacing status. |
| `macc-benefit-ledger.csv` | Durable monthly ledger of actual cost, retail equivalent, estimated savings, eligibility buckets, and match coverage. |
| `agreement-price-audit.csv` | Row-level calculation evidence for actual unit cost, retail unit price, estimated savings, match status, SKU/meter IDs, and eligibility. |
| `retail-price-snapshot.csv` | Retail price rows selected for the run, used as pricing evidence. |
| `retail-match-exceptions.csv` | Review queue for unmatched retail prices, multiple candidates, or rows needing MACC eligibility review. |
| `data-quality-snapshot.csv` | Per-run match coverage, exception counts, and review-cost totals. |
| `export-run-manifest.csv` / `.json` | Run ID, timestamp, mode, destination, selected subscriptions count, file count, totals, and calculation version. |
| `billing-reconciliation.csv` | Customer-maintained invoice reconciliation template. Enter invoice totals and variance notes after reviewing billing records. |
| `ownership-mapping.csv` | Customer-maintained mapping for business unit, application, environment, owner, and cost center. |

Recommended monthly review flow:

1. Run the export in **Running history** mode at the same cadence as monthly cost reviews.
2. Refresh the PBIP model from the generated `powerbi-storage-settings.json` values.
3. Open **MACC Commitment Overview** for agreement health, utilization, pacing, remaining commitment, and service-level eligible spend.
4. Open **MACC Benefit Ledger** to trend actual cost, retail equivalent cost, estimated savings, savings rate, and eligible/review spend over time.
5. Open **Agreement Price Audit** when a customer asks how a savings estimate was calculated.
6. Open **Coverage and Exceptions** to work unmatched, multiple-candidate, and eligibility-review rows from highest `ActualCost` to lowest.
7. Open **Billing and Ownership** after filling `billing-reconciliation.csv` with invoice totals and `ownership-mapping.csv` with team/application ownership.

Cloud destinations include the generated audit CSV files in the uploaded run folder. SharePoint mode still requires copying or syncing the generated files to the configured document library folder.

## Using The Scripts

Primary script:
- `scripts/Get-CostAnalysis.ps1`

Common examples:

```powershell
# Standard run
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "<your-subscription-id>"

# Skip Retail Prices enrichment for faster execution
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "<your-subscription-id>" -SkipRetailPriceLookup

# Install Azure CLI if missing
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "<your-subscription-id>" -InstallAzureCli
```

Script output workflow:
- Scripts generate CSV outputs locally
- The launcher can keep outputs local, upload them to Azure Blob Storage, upload them to ADLS Gen2, or configure a SharePoint document library source
- The semantic model consumes the updated files on next refresh based on `StorageLocation` and the matching root-path parameter

Key output files used by the report:
- `mtd-cost-by-retail-join-enriched.csv`
- `last-month-cost-by-retail-join-enriched.csv`
- `mtd-cost-by-service-resourcegroup.csv`
- `last-month-cost-by-service-resourcegroup.csv`
- `cost-summary-by-service.csv`
- `cost-summary-by-resourcegroup.csv`
- `cost-retail-history.csv` when `AnalysisMode = History`

## Drillthrough Usage

From `FinOps MACC vs Retail Overview`, right-click a supported data point (for example service or region) and choose:
- `Drill through -> Granular Detail / Drillthrough`

From the granular page, use the page navigation control in the header to return to `FinOps MACC vs Retail Overview`.

## Scheduling

For regular refreshes, run the script on a schedule (for example Windows Task Scheduler), then refresh/publish the report.

Example scheduled command:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Projects\Fabric\AzureFinOpsMaccRetailSolution\scripts\Get-CostAnalysis.ps1" -SubscriptionId "<your-subscription-id>"
```

## Building a Release Zip

Create a distributable release folder and zip from the solution root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0
```

Release outputs are written to `releases/`. See `docs/Release_Process.md` for
the full release, validation, and Git tagging workflow.

## Disclaimer

THIS SOLUTION IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.

IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOLUTION OR THE USE OR OTHER DEALINGS IN THE SOLUTION.

Cost and savings outputs are estimates and may be affected by data latency, pricing model nuances, entitlement configuration, and mapping coverage.

