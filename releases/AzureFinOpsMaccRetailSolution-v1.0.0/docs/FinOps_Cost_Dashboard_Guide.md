# FinOps MACC vs Retail Cost Dashboard Guide

## Purpose

This Power BI project helps customers compare their actual Azure cost from the target tenant against the estimated public Azure retail cost for the same usage. The goal is to show where agreement/MACC pricing appears to save money versus list retail prices and to identify data-quality gaps where usage could not be matched to a Retail Prices API SKU or meter.

## Primary files

| File or folder | Purpose |
|---|---|
| `Cost-Management.pbip` | Recommended PBIP file to open in Power BI Desktop. |
| `Cost-Management.Report` | Report layout pages and visuals. |
| `Cost-Management.SemanticModel` | TMDL semantic model, tables, measures, relationships, and Power Query definitions. |
| `FinOps_Cost_Dashboard_Guide.md` | This documentation file. |
| `scripts\Get-CostAnalysis.ps1` | Script that extracts Azure Cost Management data and enriches it with Azure Retail Prices API data. |

## Data flow

1. `Get-CostAnalysis.ps1` signs into Azure using Azure CLI if needed.
2. The script queries Azure Cost Management for actual cost data.
3. It exports month-to-date and last-month cost data to CSV and JSON (stored locally).
4. It creates retail-join exports with fields such as service, region, meter, product, unit of measure, and usage quantity.
5. It calls the Azure Retail Prices API at `https://prices.azure.com/api/retail/prices` to enrich rows with retail SKU ID, retail meter ID, retail price, retail product name, and match status.
6. **CSV files are uploaded to SharePoint**: `https://<<your-sharepoint-tenant>>.sharepoint.com/sites/FabricGitEssentials/Shared Documents/`
7. Power BI retrieves the enriched CSVs from SharePoint and imports them into `CostRetailFact` using the centralized `SharePointRoot` parameter.
8. Power BI calculates retail equivalent cost as `UsageQuantity * RetailPrice`.
9. Power BI measures compare actual/MACC cost against retail equivalent cost.

## Main PowerShell script

Script location:

```powershell
scripts\Get-CostAnalysis.ps1
```

Typical run command:

```powershell
cd "C:\Projects\Fabric\AzureFinOpsMaccRetailSolution"
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "c3454f9a-72a4-473e-b7ab-4e9b1107fd6d"
```

Faster run without Retail Prices enrichment:

```powershell
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "c3454f9a-72a4-473e-b7ab-4e9b1107fd6d" -SkipRetailPriceLookup
```

Install Azure CLI automatically if needed:

```powershell
.\scripts\Get-CostAnalysis.ps1 -SubscriptionId "<subscription-id>" -InstallAzureCli
```

## Script outputs

The script writes output locally as a temporary staging location:

```text
data\exports
```

**Next step**: Upload the CSV files from this folder to SharePoint at `https://<<your-sharepoint-tenant>>.sharepoint.com/sites/FabricGitEssentials/Shared Documents/` for the Power BI model to consume.

Important files to upload:

| File | Description |
|---|---|
| `mtd-cost-by-retail-join-enriched.csv` | Month-to-date enriched cost data with Retail Prices API match fields. |
| `last-month-cost-by-retail-join-enriched.csv` | Last-month enriched cost data with Retail Prices API match fields. |
| `mtd-cost-by-retail-join-with-arm-region.csv` | Cost data with Azure region normalized to Retail Prices `armRegionName`. |
| `last-month-cost-by-retail-join-with-arm-region.csv` | Last-month version of the normalized region file. |
| `cost-summary-by-service.csv` | Summary of actual cost by Azure service. |
| `cost-summary-by-resourcegroup.csv` | Summary of actual cost by resource group. |

## Power BI semantic model

The model contains a unified fact table:

```text
CostRetailFact
```

`CostRetailFact` combines month-to-date and last-month enriched cost CSVs.

Key columns:

| Column | Purpose |
|---|---|
| `Period` | Labels rows as `MTD` or `Last Month`. |
| `UsageDateAsDate` | Date column created from numeric `UsageDate`. |
| `ServiceName` | Azure service name from Cost Management. |
| `ArmRegionName` | Azure Retail Prices compatible region code. |
| `Meter` | Cost Management meter name. |
| `Product` | Cost Management product name. |
| `UsageQuantity` | Quantity used for retail equivalent calculation. |
| `Cost` | Actual cost from Azure Cost Management. |
| `RetailPrice` | Public retail unit price from Azure Retail Prices API. |
| `RetailEquivalentCost` | Calculated in Power Query as `UsageQuantity * RetailPrice`. |
| `EstimatedSavings` | Calculated in Power Query as `RetailEquivalentCost - Cost`. |
| `RetailSkuId` | Azure Retail Prices API SKU ID when matched. |
| `RetailMeterId` | Azure Retail Prices API meter ID when matched. |
| `RetailMatchStatus` | Match quality indicator: `Matched`, `NoMatch`, or `MultipleCandidates`. |

## Relationships

The model is partially denormalized because the script already joins Cost Management data with Retail Prices data during retrieval. However, dimension relationships were added for a cleaner star-schema model and consistent filtering.

| From | To | Purpose |
|---|---|---|
| `CostRetailFact[UsageDateAsDate]` | `datedim[Date]` | Date filtering and time intelligence. |
| `CostRetailFact[ServiceName]` | `DimService[ServiceName]` | Service slicers and service-level reporting. |
| `CostRetailFact[ArmRegionName]` | `DimRegion[ArmRegionName]` | Region slicers and region-level reporting. |
| `CostRetailFact[RetailMatchStatus]` | `DimRetailMatch[RetailMatchStatus]` | Matched/unmatched data-quality filtering. |

## Measures

Core customer-facing measures:

| Measure | Meaning |
|---|---|
| `Actual / MACC Cost` | Sum of actual Azure Cost Management cost. |
| `Retail Equivalent Cost` | Sum of estimated retail equivalent cost. |
| `Estimated Savings` | `Retail Equivalent Cost - Actual / MACC Cost`. |
| `Savings Rate` | `Estimated Savings / Retail Equivalent Cost`. |
| `Retail Match Coverage` | Share of actual cost that has a matched Retail Prices row. |
| `Unmatched Actual Cost` | Actual cost that could not be confidently matched to Retail Prices. |
| `Average Effective Unit Cost` | Actual cost divided by usage quantity. |
| `Average Retail Unit Price` | Average public retail unit price. |

## Report pages

| Page | Purpose |
|---|---|
| `Cost vs Retail Price by Service` | Original report page. |
| `FinOps MACC vs Retail Overview` | Executive overview with KPIs, trend, service savings, region comparison, and service/region detail. |
| `Granular Detail / Drillthrough` | Row-level SKU, meter, service, region, and cost details. |
| `Data Quality & Customer Actions` | Highlights unmatched spend, match coverage, and action items before customer-facing reviews. |

## Permissions and roles needed

Minimum practical permissions depend on where the data is queried.

### Azure subscription / resource scope

For subscription-level Cost Management queries, the identity running the script generally needs one of the following at the target subscription, management group, or billing scope:

| Role | Use |
|---|---|
| `Cost Management Reader` | Preferred least-privilege role for reading cost data. |
| `Reader` | May be enough for some subscription resource metadata, but may not always grant cost visibility depending on tenant/billing settings. |
| `Billing Reader` | Often needed when costs are controlled through billing account or billing profile access. |
| `Cost Management Contributor` | More access than needed for read-only reporting; use only if required by governance. |
| `Owner` or `Contributor` | Not recommended just for reporting, but these roles often have enough access if already granted. |

### Azure CLI authentication

The script uses Azure CLI. Interactive usage can use:

```powershell
az login --use-device-code --allow-no-subscriptions
```

For scheduled unattended usage, use one of these instead:

| Option | Notes |
|---|---|
| Service principal | Good for Windows Task Scheduler, automation servers, or CI/CD. Grant only the needed Cost Management/Billing roles. |
| Managed identity | Best for Azure Automation or Azure VM-hosted scheduled jobs. |
| User login token | Not recommended for long-term scheduled jobs because tokens expire and require interactive sign-in. |

### Azure Retail Prices API

The Azure Retail Prices API is public and does not require Azure RBAC permissions.

## Running on a regular schedule

Recommended cadence: daily, early morning, or shortly after expected Azure cost ingestion. Azure Cost Management data can lag, so customer-facing reports should note that data is subject to Azure billing latency.

### Option 1: Windows Task Scheduler

Use Task Scheduler to run PowerShell daily:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Projects\Fabric\AzureFinOpsMaccRetailSolution\scripts\Get-CostAnalysis.ps1" -SubscriptionId "c3454f9a-72a4-473e-b7ab-4e9b1107fd6d"
```

For unattended scheduling, configure the script or wrapper to authenticate with a service principal instead of relying on interactive `az login`.

### Option 2: Azure Automation

Use Azure Automation with a managed identity. Assign the managed identity Cost Management/Billing read permissions at the target scope. Configure the automation to upload script outputs directly to SharePoint at the configured `SharePointRoot` location.

### Option 3: Power BI scheduled refresh

The PBIP now reads from SharePoint using the `SharePointRoot` parameter. For Power BI Service scheduled refresh, ensure the CSV files are continuously available at the SharePoint location. The service will retrieve them automatically on each refresh with no additional gateway configuration needed.

## Customer review checklist

Before presenting to customers:

1. Refresh the Power BI model after running the script.
2. Check `Retail Match Coverage`; avoid overstating savings if coverage is low.
3. Review `Unmatched Actual Cost` on the Data Quality page.
4. Inspect `MultipleCandidates` rows because they may need manual validation.
5. Confirm the period being shown: MTD vs Last Month.
6. Clarify that Retail Prices are public list prices and do not include all possible reservations, savings plans, credits, taxes, marketplace terms, or private pricing nuances.
7. Use `Estimated Savings` as directional evidence unless SKU matching has been validated.

## Known limitations

- Retail SKU ID is not directly returned by Azure Cost Management; it is inferred through service, region, meter, product, and unit-of-measure matching.
- Some services return `global` or non-region-specific usage, which may not match cleanly to Retail Prices API rows.
- Some rows have `MultipleCandidates`; these should be reviewed before customer-facing claims.
- Cost Management data may lag behind actual usage.
- CSV files must be uploaded to the SharePoint location (`SharePointRoot` parameter) for Power BI to access them on refresh.
- MACC commitment/burn-down is not currently included because the script does not retrieve MACC commitment balance or billing account commitment data.

## Recommended next enhancements

| Enhancement | Benefit |
|---|---|
| MACC commitment / burn-down page | Shows how actual spend contributes to customer commitment. |
| Budget vs actual | Helps customers understand pacing against monthly budgets. |
| Forecast to month-end | Improves proactive cost management. |
| Month-over-month variance | Highlights cost increases and reductions. |
| Resource group and tag ownership | Assigns accountability to teams or applications. |
| Reservation/Savings Plan coverage | Explains additional savings not captured by retail comparison alone. |
| SKU match exception workflow | Improves confidence in savings claims. |

