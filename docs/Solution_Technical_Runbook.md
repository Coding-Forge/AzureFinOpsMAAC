# Solution Technical Runbook

This runbook contains the operational and technical details that were previously mixed into the root README. Use the root README for a plain-English overview; use this file when you need to operate, troubleshoot, validate, or explain the implementation.

## Repository layout

| Path | Purpose |
| --- | --- |
| `powerbi\` | PBIP report, report pages, visuals, semantic model, tables, measures, and Power Query definitions. |
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
- Power BI Desktop with PBIP support.
- Access to read Azure Cost Management data for the selected subscriptions.
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
- Tenant and subscription selection.
- Month-to-date, last-month, and optional custom range exports.
- Cost Management export.
- Resource group/location export.
- Azure billing contact audit.
- Retail Prices lookup toggle.
- Local, Azure Blob Storage, ADLS Gen2, or SharePoint output configuration.
- Agreement ID, customer name, term dates, commitment amount, currency, and pacing thresholds.
- Save/load of launcher settings.

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
| `cost-retail-history.csv` | Durable historical fact file when using History mode. |
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

For one-time analysis, use:

```text
AnalysisMode = Current
```

For trend analysis, use:

```text
AnalysisMode = History
```

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

Release outputs are written to `releases\`. See `docs\Release_Process.md` for the full release, validation, and Git tagging workflow.
