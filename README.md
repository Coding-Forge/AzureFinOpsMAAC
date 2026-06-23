# Azure FinOps MACC vs Retail Solution

## Introduction

This solution helps compare actual Azure costs (including negotiated pricing effects such as MACC outcomes) with estimated public Azure retail pricing for the same usage profile.

The project includes:
- Power BI report and semantic model in PBIP format
- PowerShell automation scripts for cost extraction and enrichment
- SharePoint-sourced data integration for dynamic cost feeds
- Supporting documentation for dashboard interpretation and operations

## Repository Layout

- `powerbi/` - PBIP report (`Cost-Management.pbip`), report pages, visuals, and semantic model tables/measures
- `scripts/` - PowerShell scripts to extract and enrich cost data
- `docs/` - Guidance and dashboard documentation
- `pictures/` - Screenshot assets and visual references
- `schedules/` - Scheduling assets and helpers (if used)
- `tools/` - Utility helpers and local tooling

## Data Source Configuration

The semantic model sources all cost and retail pricing data from SharePoint:
- **SharePointRoot parameter**: `https://mngenvmcap907283.sharepoint.com/sites/FabricGitEssentials/Shared Documents/`
- CSV files are dynamically retrieved from the SharePoint location using `Web.Contents()` in Power Query
- To change the data source location, update the `SharePointRoot` parameter value in the semantic model

## Prerequisites

- Windows with PowerShell 7+ (or Windows PowerShell 5.1 for basic script execution)
- Azure CLI (`az`) authenticated to the target tenant/subscription
- Power BI Desktop (PBIP-capable build)
- Access rights to query Azure Cost Management data at the intended scope

## Quick Start

1. Open the repository root in VS Code.
2. Generate or refresh cost exports:

```powershell
cd C:\Projects\Fabric\AzureFinOpsMaccRetailSolution
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "<your-subscription-id>"
```

3. Open `powerbi/Cost-Management.pbip` in Power BI Desktop.
4. Refresh the model.
5. Review pages:
- `FinOps MACC vs Retail Overview`
- `Granular Detail / Drillthrough`
- `Data Quality & Customer Actions`

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
- Upload the following files to SharePoint: `https://mngenvmcap907283.sharepoint.com/sites/FabricGitEssentials/Shared Documents/`
- The semantic model will automatically consume the updated files on next refresh

Key output files to upload:
- `mtd-cost-by-retail-join-enriched.csv`
- `last-month-cost-by-retail-join-enriched.csv`
- `mtd-cost-by-service-resourcegroup.csv`
- `last-month-cost-by-service-resourcegroup.csv`

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

## Disclaimer

THIS SOLUTION IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.

IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOLUTION OR THE USE OR OTHER DEALINGS IN THE SOLUTION.

Cost and savings outputs are estimates and may be affected by data latency, pricing model nuances, entitlement configuration, and mapping coverage.
