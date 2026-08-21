# Azure FinOps MACC vs Retail Solution

## What this solution does

This solution helps explain Azure consumption, negotiated pricing impact, and MACC commitment progress in a way that can be reviewed with finance, customer stakeholders, account teams, and technical owners.

It collects Azure cost and billing evidence, compares actual Azure cost against estimated public retail pricing, and packages the results into a Power BI report plus supporting audit files. The goal is not to replace official invoice or contract systems. The goal is to make the cost story easier to understand, inspect, and discuss.

## Why it was made

Azure cost reviews often require information from several places: Cost Management, billing records, retail price references, subscription/resource metadata, and customer agreement details. Those sources are useful but fragmented.

This project brings those signals together so a team can answer practical FinOps questions without manually stitching together exports each time.

## Questions it helps answer

| Question | How the solution helps |
| --- | --- |
| What did the customer spend this month and last month? | Pulls actual Azure cost by subscription, service, resource group, region, meter, and product. |
| How does actual cost compare with public retail pricing? | Matches usage to Azure Retail Prices data and estimates retail-equivalent cost and savings. |
| Is the MACC commitment pacing on track? | Calculates eligible spend, remaining commitment, expected burn, variance, and pacing status. |
| Which areas need review before presenting savings? | Flags unmatched retail prices, multiple candidate matches, and rows that need eligibility review. |
| Which services, regions, or resource groups are driving spend? | Provides Power BI pages and CSV summaries for drilldown and discussion. |
| Who owns billing, invoice routing, and billing access? | Exports billing account, billing profile, invoice section, invoice, subscription billing property, and billing role evidence where permissions allow. |
| Where might RI/SP, Azure Hybrid Benefit, Spot, or Dev/Test opportunities exist? | Produces first-pass opportunity files that identify candidates for deeper validation. |
| How do I separate commercial and Azure Gov data? | Captures `AzureCloud` in generated files and provides Cloud and Subscription slicers on the main overview page. |
| How do I separate commercial and Azure Gov data? | Captures `AzureCloud` in generated files and provides Cloud and Subscription slicers on the main overview page. |
| How do I separate commercial and Azure Gov data? | Captures `AzureCloud` in generated files and provides Cloud and Subscription slicers on the main overview page. |

## What is included

- A Power BI report package. Releases may include the PBIP source project, the customer-facing PBIT template, or both.
- A Windows PowerShell launcher for running data pulls.
- Scripts that collect Azure cost, pricing, resource location, and billing evidence.
- CSV/JSON outputs that can be stored locally, in Azure Blob Storage, in ADLS Gen2, or copied to SharePoint.
- Audit files for price matching, MACC agreement status, benefit ledger history, billing review, and data-quality follow-up.
- Optional Azure SQL durable store with operational freshness views for run health, cloud/subscription recency, row counts, and retail match coverage.

## Minimum access required

The person running the data pull needs Azure RBAC access that can read Cost Management data for the selected scope. The recommended least-privilege role is:

```text
Cost Management Reader
```

Assign it at the subscription, management group, or billing scope being analyzed. Some environments may also require billing-reader style permissions for billing profile, invoice, and billing-role evidence.

## How it works at a high level

1. Run the launcher from PowerShell.
2. Choose the tenant, subscriptions, analysis mode, agreement details, and storage destination.
3. The scripts collect Azure cost, pricing, resource, and billing evidence.
4. A timestamped run folder is created with CSV, JSON, log, and audit files.
5. Power BI reads the generated files and refreshes the report.
6. Review the report for cost trends, MACC pacing, pricing match quality, billing ownership, and follow-up actions.

## Typical review flow

1. Start with the Power BI overview page to confirm total cost, retail-equivalent cost, estimated savings, and data-quality coverage.
2. Review MACC commitment status to see whether the agreement is on track, watch, or at risk.
3. Drill into services, subscriptions, resource groups, and regions driving cost.
4. Open the exceptions view to review unmatched or ambiguous pricing rows before using savings estimates externally.
5. Use the billing audit outputs to confirm invoice routing, PO information, billing ownership, and role assignments.
6. Treat RI/SP, Azure Hybrid Benefit, Spot, and Dev/Test outputs as opportunity indicators that require validation before action.

## Getting started

From the solution root, run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

Then use the launcher to load subscriptions, choose the export options, and run the data pull. Close Power BI Desktop before running the export because the launcher updates PBIP parameter defaults before the refresh.

After the run completes, open the customer template if the release includes one:

```text
template\Cost-Management.pbit
```

If the release includes the PBIP source project instead, open:

```text
powerbi\Cost-Management.pbip
```

When the PBIT prompts for parameters, use the values from the generated `powerbi-storage-settings.json` in the run folder. At minimum, set `StorageLocation`, `LocalDataRoot`, and `HistoryDataRoot` for a local run. Then refresh the model.

## Key outputs

Each run creates a timestamped folder such as:

```text
run-YYYYMMDD-HHMMSS
```

Important outputs include:

| Output | Purpose |
| --- | --- |
| `finops-data-pull.log` | Run transcript and first place to check if something failed. |
| `powerbi-storage-settings.json` | Parameter values used by the Power BI model. |
| `cost-summary-by-service.csv` | Service-level cost summary. |
| `cost-summary-by-resourcegroup.csv` | Resource-group-level cost summary. |
| `*-cost-by-retail-join-enriched.csv` | Cost data enriched with public retail price matches. |
| `fact-cost-usage.csv` | Normalized cost fact table for the relationship-based model. |
| `fact-retail-price-match.csv` | Normalized retail price match fact table. |
| `dim-*.csv` | Normalized dimension files for cloud, subscription, service, region, meter, and retail SKU analysis. `dim-region.csv` includes `Display Name`, `Azure Region`, and `Azure Cloud`. |
| `macc-agreement-status.csv` | MACC commitment, utilization, burn variance, and pacing status. |
| `macc-benefit-ledger.csv` | Durable benefit ledger for trend and audit review. |
| `retail-match-exceptions.csv` | Pricing and eligibility rows that need review. |
| `data-quality-snapshot.csv` | Match coverage and exception summary. |
| `billing-contact-audit\` | Billing, invoice, role, and ownership evidence where available. |

## Model design at a glance

The Power BI model now uses a hybrid design:

- **Related model tables** support the core analytical experience. Normalized facts such as `FactCostUsage` and `FactRetailPriceMatch` connect to dimensions for subscription, service, region, meter, retail SKU, match status, and role-playing dates.
- **Standalone audit and template tables** remain intentionally disconnected when forcing a relationship would create ambiguous filters, duplicate totals, or misleading cross-filter behavior.
- **Durable history files** are the analytical source of truth for multi-cloud History mode. Each fetch still creates a timestamped run folder for evidence/debugging, but durable history files under the configured history root preserve Commercial and Government runs side by side.

Disconnected tables are still important. They support evidence review, exception management, billing reconciliation, ownership mapping, export traceability, and diagnostics. Use them as report-specific detail/evidence tables rather than as universal slicer targets.

## Supporting documentation

More detailed operational and technical information has been moved out of this front-door README:

- `docs\Solution_Technical_Runbook.md` - APIs called, script flow, outputs, blockers, troubleshooting, and operating notes.
- `docs\FinOps_Cost_Dashboard_Guide.md` - Power BI model/report guidance.
- `docs\Report_Pages_Preview.md` - Report page reference.
- `docs\Release_Process.md` - Release packaging and validation workflow.
- `docs\MY_FAQ.md` - FAQ and common issues.

## Important things to watch

- **Run the prerequisite checker first** on a new workstation:
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FinOpsPrerequisites.ps1 -AzureCloud AzureCloud -CheckPowerBiDesktop
  ```
- **Power BI Desktop must be closed** before running the export because the launcher updates PBIP project files.
- **Azure permissions matter.** The runner needs at least `Cost Management Reader` RBAC for Cost Management exports. Billing data and storage uploads may require additional permissions.
- **Azure Government / GCC High requires extra validation.** Choose `AzureUSGovernment` in the launcher, use government portal URLs, and validate API availability for Cost Management, Billing, and Retail Prices before relying on outputs.
- **Mixed-cloud customers should run one fetch per cloud.** The run folder is evidence for that fetch; History mode reads durable cloud-aware history files so Commercial and Government data can coexist without one run overwriting the other.
- **For Azure SQL durable storage, start small.** For most customers, Azure SQL Database General Purpose serverless with 1 vCore max and 5-10 GB storage is a reasonable starting point; scale after observing refresh/upsert performance.
- **Monitor freshness after SQL loads.** `Import-FinOpsSqlData.ps1` prints cloud freshness and operational warnings from the SQL monitoring views after each load. Use `finops.IngestionFreshnessByCloud`, `finops.IngestionFreshnessBySubscription`, `finops.RetailMatchCoverageByCloud`, and `finops.OperationalHealthSummary` for SQL alert queries or the Power BI **Operational Freshness** page. In Power BI, set `AzureSqlMonitoringEnabled=true` plus the SQL server, database, and schema parameters to populate that page.
- **Retail price matching is directional.** Public retail price estimates are useful for analysis but are not an official invoice reconciliation. For Azure Government, treat public retail/PAYGO equivalents as estimates and validate whether they are appropriate for the customer discussion.
- **Billing data can be sensitive.** Treat exported billing contact, PO, role, and invoice files carefully.
- **Some opportunity files are first-pass indicators.** RI/SP, Azure Hybrid Benefit, Spot, and Dev/Test outputs should be validated with official entitlement, utilization, and configuration data before making claims.
- **PBIT files must be re-exported after model changes.** If the PBIP semantic model changes, open the PBIP in Power BI Desktop, validate refresh, and export a fresh `template\Cost-Management.pbit` before publishing a customer release.

## Azure Government / GCC High note

The solution was originally built and validated against commercial Azure endpoints. To use it with Azure Government / GCC High tenants, choose this value in the launcher:

```text
Azure cloud = AzureUSGovernment
```

The launcher applies the selected Azure CLI cloud before loading subscriptions or running exports. You can also set it manually before launch if preferred:

```powershell
az cloud set --name AzureUSGovernment
az login --use-device-code --allow-no-subscriptions
az account set --subscription "<subscription-id>"
```

For customers that have both Azure Commercial and Azure Government in the same budget period, switch the Azure CLI cloud before each data pull and log in against the correct tenant:

```powershell
# Switch to Azure Government
az cloud set --name AzureUSGovernment
az login --tenant "<government-tenant-id>"
az account set --subscription "<government-subscription-id>"
az account show --query "{cloud:environmentName, tenant:tenantId, subscription:id, name:name}" --output table

# Switch back to Azure Commercial
az cloud set --name AzureCloud
az login --tenant "<commercial-tenant-id>"
az account set --subscription "<commercial-subscription-id>"
az account show --query "{cloud:environmentName, tenant:tenantId, subscription:id, name:name}" --output table
```

If access is granted through PIM, activate the role first and then run `az logout` followed by the appropriate `az cloud set` and `az login --tenant ...` commands so Azure CLI gets a fresh token for that cloud and tenant.

Common government cloud portals:

| Purpose | URL |
| --- | --- |
| Azure Government portal | `https://portal.azure.us` |
| Microsoft 365 sign-in | `https://portal.office365.us` |
| Microsoft 365 admin center | `https://admin.microsoft.us` |
| Entra admin center | `https://entra.microsoft.us` |

Before using results externally, verify the Cost Management, Billing, and Retail Prices calls succeed for the target government tenant. Some billing APIs, invoice fields, retail price metadata, or services may differ from commercial Azure.

## Disclaimer

THIS SOLUTION IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.

IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOLUTION OR THE USE OR OTHER DEALINGS IN THE SOLUTION.

Cost and savings outputs are estimates and may be affected by data latency, pricing model nuances, entitlement configuration, and mapping coverage.
