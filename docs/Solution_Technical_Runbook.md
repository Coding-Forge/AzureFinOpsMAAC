# Solution Technical Runbook

This runbook contains the operational and technical details that were previously mixed into the root README. Use the root README for a plain-English overview; use this file when you need to operate, troubleshoot, validate, or explain the implementation.

## Repository layout

| Path | Purpose |
| --- | --- |
| `powerbi\` | Power BI artifacts. Releases can include the PBIP source project, the customer-facing PBIT template, or both. |
| `scripts\` | PowerShell scripts used to collect and enrich Azure cost, pricing, resource, and billing data. |
| `docs\` | Supporting documentation, report guides, FAQ, and release process. |
| `pictures\` | Screenshot assets and visual references. |
| `tools\` | Utility helpers and local tooling. |
| `build-release.ps1` | Builds versioned release folders and zip files under `releases\`. |

## Primary scripts

| Script | Purpose |
| --- | --- |
| `scripts\Start-FinOpsDataPull.ps1` | Windows Forms launcher. Collects run settings, writes `powerbi-storage-settings.json`, generates a timestamped runner script, updates PBIP parameter defaults, and launches selected exports. |
| `scripts\Get-CostAnalysis.ps1` | Pulls Azure Cost Management data, exports cost CSV/JSON files, enriches rows with Azure Retail Prices API data, and creates cost summaries. |
| `scripts\Get-AzureResourceGroupsByLocation.ps1` | Lists resource groups and enriches them with Azure location metadata. |
| `scripts\Get-AzureBillingContactAudit.ps1` | Exports billing account, billing profile, invoice section, invoice, subscription billing property, and billing role assignment evidence. |
| `scripts\New-FinOpsAuditArtifacts.ps1` | Creates MACC agreement status, benefit ledger, price audit, data-quality, exception, and savings-opportunity files from enriched cost data. |

## Prerequisites

- Windows with PowerShell 7+ or Windows PowerShell 5.1.
- Azure CLI available on PATH.
- Azure CLI signed into the target tenant.
- Power BI Desktop with PBIP support. PBIT export for customer releases is done manually from Power BI Desktop.
- Azure RBAC access to read Azure Cost Management data for the selected subscriptions. `Cost Management Reader` is the preferred least-privilege role.
- Additional billing permissions when running the billing contact audit.
- Storage data-plane permissions when uploading to Azure Blob Storage or ADLS Gen2.

The launcher can optionally install Azure CLI with `winget` when selected.

## Standard run

From the repository root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Start-FinOpsDataPull.ps1
```

The launcher supports:

- Current view or running history mode.
- Azure cloud selection: `AzureCloud` or `AzureUSGovernment`.
- Tenant and subscription selection.
- Month-to-date, last-month, and optional custom range exports.
- Cost Management export.
- Resource group/location export.
- Azure billing contact audit.
- Retail Prices lookup toggle.
- Local, Azure Blob Storage, ADLS Gen2, or SharePoint output configuration.
- Agreement ID, customer name, term dates, commitment amount, currency, and pacing thresholds.
- Save/load of launcher settings.

## Azure Government / GCC High operation

The current scripts were originally developed against commercial Azure endpoints and should be validated carefully before customer use in Azure Government / GCC High. The Azure CLI cloud profile controls Azure Resource Manager endpoints used by `az account`, `az rest`, and storage upload commands.

For an Azure Government tenant, select this on the Run export tab:

```text
Azure cloud = AzureUSGovernment
```

The launcher runs `az cloud set --name <selected cloud>` before loading subscriptions and before executing the generated run script. You can also set it manually before launching:

```powershell
az cloud set --name AzureUSGovernment
az login --use-device-code --allow-no-subscriptions
az account set --subscription "<subscription-id>"
az cloud show
```

Confirm `az cloud show` reports `AzureUSGovernment` when troubleshooting. If you later return to commercial Azure, either choose `AzureCloud` in the launcher or reset manually with:

```powershell
az cloud set --name AzureCloud
```

Common government cloud URLs:

| Purpose | URL |
| --- | --- |
| Azure Government portal | `https://portal.azure.us` |
| Microsoft 365 / Office sign-in | `https://portal.office365.us` |
| Microsoft 365 admin center | `https://admin.microsoft.us` |
| Entra admin center | `https://entra.microsoft.us` |
| My Apps | `https://myapps.microsoft.us` |

### Government cloud validation checklist

Before relying on the report for a GCC High / Azure Government customer, validate:

1. `az account list` shows the intended government tenant/subscriptions.
2. Cost Management query succeeds for the selected subscription.
3. Billing audit APIs return data or documented warnings appropriate to the customer's billing model.
4. Storage upload works if using Azure Blob Storage or ADLS Gen2 in Azure Government.
5. Retail Prices enrichment succeeds and produces acceptable match coverage.
6. Power BI Desktop can open the PBIT and refresh from the generated local or government storage paths.

### Known caveats

- The scripts call the Azure Retail Prices API at `https://prices.azure.com/api/retail/prices`. Validate that this public retail endpoint and its metadata are acceptable for the government customer scenario before using retail-equivalent savings externally.
- Billing APIs may expose less data depending on MCA/EA/CSP/reseller structure and government cloud availability.
- Government storage account URLs and authentication are controlled by Azure CLI cloud context; do not mix commercial and government storage roots.
- Microsoft 365 GCC High portals use `.us` endpoints; do not use commercial admin URLs for tenant administration.

## Power BI parameter handling

Each run writes:

```text
powerbi-storage-settings.json
```

The generated runner then updates:

```text
powerbi\Cost-Management.SemanticModel\definition\expressions.tmdl
```

Updated parameter defaults include:

| Parameter | Purpose |
| --- | --- |
| `AnalysisMode` | `Current` for MTD/last-month only, or `History` for trend reporting. |
| `StorageLocation` | `Local`, `AzureBlob`, `ADLSGen2`, or `SharePoint`. |
| `LocalDataRoot` | Latest local run folder that contains generated CSV files. |
| `HistoryDataRoot` | Durable local history folder for `cost-retail-history.csv`. |
| `BlobDataRoot` | Azure Blob HTTPS base URL. |
| `AdlsDataRoot` | ADLS Gen2 HTTPS base URL. |
| `SharePointDataRoot` | SharePoint document library folder URL. |

Power BI Desktop must be closed before the run because the script intentionally refuses to update PBIP project files while `PBIDesktop*` processes are running.

## APIs and commands called

### Azure CLI context and subscription discovery

The scripts use:

```text
az account show
az login --use-device-code
az account list
az account set
az account list-locations
```

These commands identify the signed-in user, visible tenants/subscriptions, enabled subscriptions, and Azure region metadata.

Watch for missing Azure CLI, incomplete sign-in, wrong tenant, inaccessible subscriptions, or device-code login waiting for user action.

### Azure Cost Management API

Cost pulls use:

```text
https://management.azure.com/{scope}/providers/Microsoft.CostManagement/query?api-version=2023-11-01
```

The request queries `ActualCost` with daily granularity. It groups data by service, resource group, resource location, meter, product, part number, and unit of measure.

In Azure Government, Azure CLI should translate `management.azure.com` calls to the active cloud's Resource Manager endpoint when using `az rest`. Confirm this by setting `AzureUSGovernment` before running and validating the generated exports.

The script runs the query for:

- Month-to-date.
- Last month.
- Optional custom date range.

The Cost Management path includes retry handling for throttling and temporary service failures.

### Azure Retail Prices API

Retail enrichment uses:

```text
https://prices.azure.com/api/retail/prices
```

The script filters by service name, meter, ARM region, and unit of measure. It retrieves retail SKU/meter identifiers, product names, SKU names, meter names, retail prices, unit prices, currency, and retail region.

For Azure Government scenarios, treat retail enrichment as a validation item. Public retail pricing metadata may not always align with government offers, billing constructs, or contracted terms.

This path can be slow and throttle-prone. The script retries 429, timeout, and temporary 5xx failures with backoff and honors `Retry-After` when returned.

### Azure Billing APIs

The billing contact audit uses Azure Management APIs including:

```text
https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01
https://management.azure.com/{billingAccountId}/billingProfiles?api-version=2024-04-01
https://management.azure.com/{billingProfileId}/invoiceSections?api-version=2024-04-01
https://management.azure.com/{billingProfileId}/invoices?api-version=2024-04-01
https://management.azure.com/{scope}/billingRoleAssignments?api-version=2024-04-01
https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Billing/billingProperty/default?api-version=2024-04-01
https://management.azure.com/subscriptions?api-version=2022-12-01
```

These APIs retrieve billing accounts, profiles, invoice sections, invoices, PO numbers, bill-to/sold-to data, subscription billing properties, and billing role assignments.

Billing APIs commonly require higher permissions than subscription reader access. The script writes warnings for many billing access gaps instead of failing the whole run.

### Storage uploads

Azure Blob Storage upload uses:

```text
az storage blob upload-batch --auth-mode login
```

ADLS Gen2 upload uses:

```text
az storage fs directory upload --auth-mode login
```

SharePoint mode does not directly upload through the launcher. Copy or sync the generated files to the configured SharePoint document library folder.

## Main output files

Each run creates a timestamped run folder such as:

```text
run-YYYYMMDD-HHMMSS
```

Important files include:

| File or folder | Purpose |
| --- | --- |
| `finops-data-pull.log` | Full run transcript. Start troubleshooting here. |
| `powerbi-storage-settings.json` | Power BI parameter values for the run. |
| `mtd-cost-by-service-resourcegroup.csv` | Month-to-date cost by service and resource group. |
| `last-month-cost-by-service-resourcegroup.csv` | Last-month cost by service and resource group. |
| `custom-cost-by-service-resourcegroup.csv` | Optional custom-range cost by service and resource group. |
| `cost-summary-by-service.csv` | Service-level cost summary. |
| `cost-summary-by-resourcegroup.csv` | Resource-group-level cost summary. |
| `*-cost-by-retail-join.csv` | Cost rows grouped for retail-price matching. |
| `*-cost-by-retail-join-with-arm-region.csv` | Retail-join rows with normalized ARM region names. |
| `*-cost-by-retail-join-enriched.csv` | Retail-join rows enriched with public retail price fields. |
| `fact-cost-usage.csv` | Normalized cost fact table for the relationship-based semantic model. |
| `fact-retail-price-match.csv` | Normalized retail price match fact table for match coverage and savings measures. |
| `dim-azure-cloud.csv` | Normalized cloud dimension with values such as `AzureCloud` and `AzureUSGovernment`. |
| `dim-subscription.csv` | Normalized subscription dimension. |
| `dim-service.csv` | Normalized service dimension. |
| `dim-region.csv` | Normalized region dimension. |
| `dim-meter.csv` | Normalized meter/product/unit dimension. |
| `dim-retail-sku.csv` | Normalized retail SKU/meter/price dimension. |
| `cost-retail-history.csv` | Durable historical fact file when using History mode. |
| `fact-cost-usage-history.csv` | Durable normalized cost fact history file when using History mode. |
| `fact-retail-price-match-history.csv` | Durable normalized retail match fact history file when using History mode. |
| `agreement-config.csv` | Agreement metadata used for the run. |
| `macc-agreement-status.csv` | MACC utilization, remaining commitment, burn variance, required run rate, and pacing status. |
| `macc-benefit-ledger.csv` | Durable ledger of actual cost, retail equivalent, estimated savings, eligibility buckets, and match coverage. |
| `agreement-price-audit.csv` | Row-level evidence for actual cost, retail price, estimated savings, match status, and eligibility. |
| `retail-price-snapshot.csv` | Retail price rows selected for the run. |
| `retail-match-exceptions.csv` | Review queue for unmatched, multiple-candidate, or eligibility-review rows. |
| `data-quality-snapshot.csv` | Match coverage, exception counts, and review-cost totals. |
| `enterprise-agreement-savings.csv` | Directional estimate of actual cost vs retail-equivalent cost. |
| `reservation-savings-plan-coverage.csv` | First-pass RI/SP opportunity indicators. |
| `azure-hybrid-benefit-opportunities.csv` | First-pass Azure Hybrid Benefit opportunity indicators. |
| `billing-contact-audit\` | Billing contact, invoice, role, subscription billing property, raw JSON, warning, and Markdown report outputs. |

## History mode

Use History mode when the customer wants trend reporting rather than only current MTD and last-month analysis.

History mode:

- Requires Cost Management export.
- Requires Retail Prices enrichment.
- Maintains a durable file at `<output-root>\history\cost-retail-history.csv`.
- Adds history columns such as `HistoryMonth`, `ExportRunId`, `ExportedUtc`, `Period`, `SubscriptionName`, and `SubscriptionId`.
- Replaces matching `HistoryMonth` + `Period` slices on rerun to avoid duplicate snapshots.
- Copies the latest history file into the current run folder for Power BI refresh and upload.
- Maintains normalized history files for `FactCostUsage` and `FactRetailPriceMatch` so the relationship-based model can use the same `AnalysisMode` parameter.

For one-time analysis, use:

```text
AnalysisMode = Current
```

For trend analysis, use:

```text
AnalysisMode = History
```

## Relationship-based semantic model migration

The solution emits normalized CSVs alongside the original enriched/audit files. The original enriched files remain for auditability and backward compatibility. The normalized files support a cleaner star-schema model:

| Normalized file | Intended model role |
| --- | --- |
| `fact-cost-usage.csv` | Actual cost and usage fact. |
| `fact-retail-price-match.csv` | Retail match and pricing fact. |
| `dim-subscription.csv` | Subscription slicer/dimension. |
| `dim-service.csv` | Service slicer/dimension. |
| `dim-region.csv` | Region slicer/dimension. |
| `dim-meter.csv` | Meter/product/unit dimension. |
| `dim-retail-sku.csv` | Retail SKU/price dimension. |

The current model uses normalized facts and dimensions for core analysis while preserving enriched/audit tables for traceability.

### Related core model tables

These tables participate in the relationship model and should be used for cross-filtered analytical views:

| Table | Role |
| --- | --- |
| `FactCostUsage` | Actual cost and usage fact sourced from `fact-cost-usage.csv`. |
| `FactRetailPriceMatch` | Retail match and pricing fact sourced from `fact-retail-price-match.csv`. |
| `DimAzureCloud` | Cloud dimension used to separate commercial and Azure Government data in combined datasets. |
| `DimSubscription` | Subscription dimension. |
| `DimServiceModel` | Service dimension for normalized facts. |
| `DimRegionModel` | Region dimension for normalized facts. |
| `DimMeter` | Meter/product/unit dimension. |
| `DimRetailMatch` | Match status dimension. |
| `DimUsageDate` | Usage-date role-playing date dimension. |
| `DimAgreementStartDate` | Agreement start-date role-playing date dimension. |
| `DimAgreementEndDate` | Agreement end-date role-playing date dimension. |
| `DimAgreementAsOfDate` | Agreement as-of date role-playing date dimension. |
| `DimRetailEffectiveStartDate` | Retail price effective-start role-playing date dimension. |
| `DimRetailEffectiveEndDate` | Retail price effective-end role-playing date dimension. |

`DimRetailSku` is present as a disconnected lookup/detail table derived from `FactRetailPriceMatch`. It is intentionally not related back to `FactRetailPriceMatch` because Power BI evaluates that self-derived dimension plus relationship as a cyclic dependency. Retail SKU fields remain available directly on `FactRetailPriceMatch` for filtering/drilldown, and `DimRetailSku` can be used for reference/detail pages.

### Standalone tables and why they remain disconnected

Some tables intentionally do not have relationships. This is not a defect. These tables are report-specific audit, evidence, template, or diagnostic tables where relationships can create misleading filters, many-to-many ambiguity, duplicate totals, or circular dependencies.

| Table or group | Why it is standalone |
| --- | --- |
| `AgreementPriceAudit` | Row-level calculation evidence. It overlaps with cost, retail, service, region, and meter grain, but is used for audit drilldown rather than primary aggregation. |
| `RetailPriceSnapshot` | Point-in-time pricing evidence. It may include selected retail price rows without a one-to-one analytical relationship to every cost row. |
| `DimRetailSku` | Retail SKU reference/detail table derived from the retail match fact. It remains disconnected to avoid a cyclic dependency caused by relating a fact-derived dimension back to its source fact. |
| `RetailMatchExceptions` | Review queue for unmatched/multiple-candidate rows. It supports operational remediation and should not be allowed to cross-filter core cost totals unexpectedly. |
| `DataQualitySnapshot` | Period-level quality summary. Its grain is intentionally higher than transaction/detail facts. |
| `ExportRunManifest` | Run metadata and traceability. It describes a run, not a cost grain. |
| `BillingReconciliation` | Customer-maintained invoice reconciliation template. It is filled manually and may not match Cost Management grain. |
| `OwnershipMapping` | Customer-maintained business mapping template. It may be incomplete or many-to-many until governed by the customer. |
| `BillingAudit*` tables | Billing account/profile/invoice/role evidence. Billing APIs expose a different hierarchy than Cost Management usage. |
| RI/SP, AHB, Spot, and Dev/Test opportunity tables | First-pass opportunity indicators. They are candidate/review views, not authoritative transactional facts. |
| Legacy enriched/staging tables | Preserved or hidden for backward compatibility, diagnostics, and evidence; core analysis should use normalized facts where possible. |

When using standalone tables, filter them directly on their report pages instead of expecting all core model slicers to affect them.

After any semantic model change, export a fresh `template\Cost-Management.pbit` from Power BI Desktop before publishing a customer release.

## Common blockers and what they mean

| Blocker | Meaning | Action |
| --- | --- | --- |
| Power BI Desktop is running | The launcher needs to update PBIP parameter files safely. | Save and close Power BI Desktop, then rerun. |
| Azure CLI missing | The scripts depend on `az`. | Install Azure CLI or rerun with the launcher install option. |
| Device-code login prompt | No active Azure CLI session exists. | Complete the sign-in in the browser/device-code flow. |
| No enabled subscriptions found | The signed-in identity cannot see target subscriptions. | Confirm tenant, account, role assignments, and subscription IDs. |
| Cost Management API throttling | Azure asked the script to slow down. | Let retry/backoff continue; reduce scope if failures persist. |
| Retail Prices lookup is slow | Many cost rows require public retail-price matching. | Let it run, or skip Retail Prices lookup for a faster but less complete run. |
| History mode fails when retail lookup is skipped | History depends on enriched retail-join files. | Rerun without `Skip Retail Prices lookup`. |
| Billing audit warnings | The identity lacks some billing permissions. | Review `billing-contact-audit-warnings.csv`; request billing admin or reseller evidence if needed. |
| Blob or ADLS upload failure | Local export succeeded, but publishing failed. | Check storage permissions, account/container/file system names, network rules, and login context. |

## Data-quality review checklist

Before using savings outputs in a customer-facing discussion:

1. Confirm all expected subscriptions were included.
2. Confirm MTD and last-month cost totals are directionally correct.
3. Review `data-quality-snapshot.csv` for retail match coverage.
4. Review high-dollar rows in `retail-match-exceptions.csv`.
5. Confirm whether review-category spend should be included or excluded from MACC discussion.
6. Treat public retail savings as directional, not as official invoice reconciliation.
7. Validate RI/SP, Azure Hybrid Benefit, Spot, and Dev/Test candidates with official utilization, entitlement, and resource configuration data.
8. Protect billing audit outputs because they may contain contact, PO, billing role, and invoice information.

## Release packaging

Create a distributable release folder and zip from the solution root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0
```

For customer releases that must include a Power BI template, first export `template\Cost-Management.pbit` from Power BI Desktop, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0 -RequirePbit
```

To publish only the customer template and omit the PBIP source project, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1 -Version 1.0.0 -RequirePbit -ExcludePbip
```

Release outputs are written to `releases\`. See `docs\Release_Process.md` for the full release, PBIT export, validation, and Git tagging workflow.
