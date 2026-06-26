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
| `LocalDataRoot` | Local run folder that contains the generated CSV files, ending with `\` |
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

1. Open the repository root in VS Code.
2. Launch the Windows UI:

```powershell
cd C:\Projects\Fabric\AzureFinOpsMaccRetailSolution
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

3. Choose the startup purpose: **Current view** or **Running history**.
4. Click **Load from tenant**, select the subscriptions to include, choose the export options and storage destination, then click **Run export**.
5. Copy the generated parameter values from `powerbi-storage-settings.json` into Power BI Desktop.
6. Open `powerbi/Cost-Management.pbip` in Power BI Desktop and refresh the model.
7. Review pages:
- `FinOps MACC vs Retail Overview`
- `Granular Detail / Drillthrough`
- `Data Quality & Customer Actions`

## Windows Data Pull UI

Run `scripts/Start-FinOpsDataPull.ps1` to open the Windows Forms launcher. The UI includes:

- **Startup purpose** - choose **Current view** for MTD/last-month analysis or **Running history** to build `cost-retail-history.csv` for monthly MACC savings trends.
- **Run export** - tenant, subscription loader with multi-select checkboxes, date, script selection, Azure CLI install option, Retail Prices lookup option, and destination selection.
- **Local** - local staging/output root. Every run creates a timestamped `run-*` folder.
- **Azure Blob** - storage account, container, and virtual folder prefix. Upload uses `az storage blob upload-batch --auth-mode login`.
- **ADLS Gen2** - storage account, file system, and folder path. Upload uses `az storage fs directory upload --auth-mode login`.
- **SharePoint** - document library folder URL for Power BI to read from. Copy or sync the generated CSV files to this folder after export.
- **Instructions** - operating steps and Power BI parameter mapping.

Cloud destinations are staged locally first because the existing export scripts write files. After a successful script run, the launcher uploads the run folder to the selected Blob container or ADLS Gen2 file system. For SharePoint, copy or sync the generated CSV files from the run folder to the configured document library folder. The launcher uses the signed-in Azure CLI identity for Blob and ADLS uploads and does not store storage account keys or SAS tokens.

## Running History Mode

Choose **Running history** at startup when the customer wants Power BI to trend estimated MACC savings over time instead of only reviewing the current MTD and last-month exports.

History mode:
- Requires the Cost Management export and Retail Prices enrichment.
- Maintains a stable local file at `<output-root>\history\cost-retail-history.csv`.
- Adds `HistoryMonth`, `ExportRunId`, `ExportedUtc`, `Period`, `SubscriptionName`, and `SubscriptionId` columns.
- Replaces the same `HistoryMonth` + `Period` slice when rerun, so rerunning June updates June MTD and May last-month rows instead of duplicating them.
- Copies the latest `cost-retail-history.csv` into the timestamped run folder so Blob, ADLS Gen2, SharePoint, or local Power BI refresh can consume it.

For Power BI historical reporting, set:

```text
AnalysisMode = History
StorageLocation = <Local | AzureBlob | ADLSGen2 | SharePoint>
<matching root parameter> = <the folder that contains cost-retail-history.csv>
```

For one-time analysis, set:

```text
AnalysisMode = Current
```

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
