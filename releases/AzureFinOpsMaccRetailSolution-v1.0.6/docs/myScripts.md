Here’s the plain-English summary of what the Azure FinOps PowerShell solution is doing.

## Big picture

The scripts are a **data pull and evidence-generation tool** for Azure FinOps / MACC analysis. They sign into Azure, collect cost, pricing, subscription, resource location, billing, and invoice-related evidence, then write a run folder full of CSV/JSON files that the Power BI project can load.

Think of it as three main jobs:

1. **Pull Azure spend data** — month-to-date, last month, and optionally a custom date range.
2. **Enrich that spend with retail-price and audit context** — so you can compare actual cost vs retail price and estimate savings / MACC eligibility.
3. **Package everything for Power BI and audit review** — local files, optional Azure Blob / ADLS upload, and Power BI parameter updates.

## Main scripts and what each one does

| Script | What it does in plain English |
|---|---|
| `Start-FinOpsDataPull.ps1` | Opens the Windows Forms launcher UI, collects choices, creates a timestamped run folder, writes settings, generates the actual run script, updates the Power BI project parameters, and launches the selected exports. |
| `Get-CostAnalysis.ps1` | Pulls Azure Cost Management data across selected subscriptions, creates cost CSVs, enriches rows with Azure Retail Prices API data, and creates service/resource group summaries. |
| `Get-AzureResourceGroupsByLocation.ps1` | Lists resource groups and Azure regions so the report can show where resources live. |
| `Get-AzureBillingContactAudit.ps1` | Pulls billing-account, billing-profile, invoice-section, invoice, and billing-role evidence to help review who owns billing, invoice routing, PO numbers, and contacts. |
| `New-FinOpsAuditArtifacts.ps1` | Takes the enriched cost files and creates MACC / FinOps audit outputs: agreement status, benefit ledger, price audit, retail match exceptions, estimated savings, AHB/RI/SP opportunity files, and quality snapshots. |

## APIs and services being called

### 1. Azure CLI sign-in and subscription discovery

The scripts use Azure CLI commands like:

- `az account show`
- `az login --use-device-code`
- `az account list`
- `az account set`
- `az account list-locations`

**What this retrieves:**

- Who is signed in.
- Which tenants and subscriptions are visible.
- Which subscriptions are enabled.
- Azure region metadata, such as `eastus`, `westus3`, display names, geography, paired regions, latitude/longitude.

**Watch for:**

- User not signed into Azure CLI.
- Azure CLI missing or not on PATH.
- Wrong tenant selected.
- Subscriptions not visible because of permission issues.
- Device-code login waiting for the user to complete browser authentication.

---

### 2. Azure Cost Management API

The main cost pull calls:

```text
https://management.azure.com/{subscription}/providers/Microsoft.CostManagement/query?api-version=2023-11-01
```

It queries **ActualCost** with daily granularity.

**What this retrieves:**

For each selected subscription, the script pulls cost grouped by things like:

- Service name
- Resource group name
- Resource location
- Meter
- Product
- Part number
- Unit of measure
- Currency
- Usage quantity
- Cost

It runs this for:

- **Month-to-date**
- **Last month**
- **Custom range**, if selected

**Outputs include:**

- `mtd-cost-by-service-resourcegroup.csv`
- `last-month-cost-by-service-resourcegroup.csv`
- `custom-cost-by-service-resourcegroup.csv`, if custom range is enabled
- JSON versions of the same data
- Per-subscription folders under `subscriptions\...`
- `cost-summary-by-service.csv`
- `cost-summary-by-resourcegroup.csv`

**Watch for:**

- Cost Management API throttling or temporary failures.
- Cost data delay: Azure cost data is not always real-time.
- Missing permissions: the user needs enough access to read cost data.
- Large subscription sets can take a while.
- Currency consistency if multiple subscriptions are in different billing setups.

---

### 3. Azure Retail Prices API

The script calls:

```text
https://prices.azure.com/api/retail/prices
```

with OData-style filters such as service name, meter, region, and unit of measure.

**What this retrieves:**

- Retail SKU ID
- Retail meter ID
- Product name
- SKU name
- Meter name
- Retail price
- Unit price
- Retail currency
- Retail region

This lets the tool compare **actual Azure cost** from Cost Management against **public retail price** to estimate negotiated/EA savings.

**Outputs include:**

- `mtd-cost-by-retail-join.csv`
- `mtd-cost-by-retail-join-with-arm-region.csv`
- `mtd-cost-by-retail-join-enriched.csv`
- Similar files for `last-month` and `custom`
- `retail-price-snapshot.csv`
- `retail-match-exceptions.csv`
- `data-quality-snapshot.csv`

**Watch for:**

- This is the slowest and most throttle-prone part.
- The Retail Prices API may return multiple possible matches.
- Some cost rows may not match a public retail SKU.
- Retail price is public list pricing, not the customer’s contracted price.
- The estimate is useful for directional savings analysis, not an official billing reconciliation.
- If `Skip Retail Prices lookup` is selected, some downstream MACC/audit artifacts will not be generated.

The throttling error you saw was from this API. I added retry/backoff handling so it should wait and retry instead of immediately failing.

---

### 4. Azure Resource Manager / Billing APIs

The billing audit calls Azure Management APIs such as:

```text
https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01
https://management.azure.com/{billingAccountId}/billingProfiles?api-version=2024-04-01
https://management.azure.com/{billingProfileId}/invoiceSections?api-version=2024-04-01
https://management.azure.com/{billingProfileId}/invoices?api-version=2024-04-01
https://management.azure.com/{scope}/billingRoleAssignments?api-version=2024-04-01
https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Billing/billingProperty/default?api-version=2024-04-01
https://management.azure.com/subscriptions?api-version=2022-12-01
```

**What this retrieves:**

- Billing accounts
- Billing profiles
- Invoice sections
- Recent invoices
- PO numbers
- Bill-to / sold-to details
- Invoice email settings
- Billing role assignments
- Subscription billing properties

**Outputs include:**

Inside `billing-contact-audit\`:

- `billing-accounts.csv`
- `billing-profiles.csv`
- `invoice-sections.csv`
- `billing-role-assignments.csv`
- `subscription-billing-properties.csv`
- `invoices.csv`
- `billing-contact-audit-warnings.csv`
- Raw JSON evidence files
- Markdown report: `Azure-Billing-Contact-Audit-<timestamp>.md`

**Watch for:**

- Billing APIs often require higher permissions than normal subscription reader access.
- It may succeed for subscriptions but fail for billing accounts.
- CSP / reseller-controlled billing may not expose everything directly.
- The script records warnings instead of failing for many billing-permission gaps.
- Billing data may include sensitive customer/contact/PO information, so treat the output folder carefully.

---

### 5. Azure Storage upload APIs / CLI

If selected, the launcher uploads the generated output to:

- Azure Blob Storage via `az storage blob upload-batch`
- ADLS Gen2 via `az storage fs directory upload`

**What this does:**

Copies the run folder into the configured storage account/container/path.

**Watch for:**

- User must have storage data-plane permissions.
- Storage firewall/private endpoint/network rules can block upload.
- Wrong container/file system name or prefix causes upload failure.
- Upload happens after the data pull, so a storage failure may occur even after data files were created locally.

---

## What the Power BI update does

The launcher writes:

```text
powerbi-storage-settings.json
```

Then it updates this Power BI project file:

```text
powerbi\Cost-Management.SemanticModel\definition\expressions.tmdl
```

It changes parameter defaults such as:

- `AnalysisMode`
- `StorageLocation`
- `LocalDataRoot`
- `HistoryDataRoot`
- `BlobDataRoot`
- `AdlsDataRoot`
- `SharePointDataRoot`

This is why the script blocks if Power BI Desktop is open. It does not want to edit the PBIP files while Power BI Desktop may also be holding or rewriting them.

**Watch for:**

- Close Power BI Desktop before running the export.
- If Power BI Desktop is open, the script stops intentionally.
- After the run, open/refresh the PBIP so Power BI reads the new files.

## Important outputs to know

Each run creates a folder like:

```text
C:\Projects\Fabric\AuditDumps\run-YYYYMMDD-HHMMSS
```

Important files:

| File | Purpose |
|---|---|
| `finops-data-pull.log` | Full transcript/log of the run. First place to look for failures. |
| `powerbi-storage-settings.json` | Settings Power BI should use for the run. |
| `*-cost-by-service-resourcegroup.csv` | Cost by service/resource group. |
| `*-cost-by-retail-join-enriched.csv` | Cost rows enriched with retail price matches. |
| `cost-summary-by-service.csv` | Rollup by Azure service. |
| `cost-summary-by-resourcegroup.csv` | Rollup by resource group. |
| `cost-retail-history.csv` | Historical combined file when running in History mode. |
| `macc-benefit-ledger.csv` | MACC/benefit ledger built from enriched cost data. |
| `macc-agreement-status.csv` | Commitment pacing, burn, remaining commitment, risk status. |
| `agreement-price-audit.csv` | Detailed audit trail of cost + retail price matching. |
| `retail-match-exceptions.csv` | Rows needing review because matching was missing or ambiguous. |
| `data-quality-snapshot.csv` | Summary of match coverage and exception counts. |
| `billing-contact-audit\*` | Billing ownership, invoice, role, and contact evidence. |

## Main blockers / hang-ups to expect

### 1. Power BI Desktop is open

**Symptom:**  
“Power BI Desktop appears to be running…”

**Meaning:**  
The script needs to update PBIP parameter files and refuses to do that while Power BI Desktop is open.

**Action:**  
Save and close Power BI Desktop, then rerun.

---

### 2. Azure CLI sign-in required

**Symptom:**  
Device-code login prompt or “No Azure login found.”

**Meaning:**  
The machine has no active Azure CLI session.

**Action:**  
Complete the device-code login. Make sure it is the right tenant/account.

---

### 3. Missing subscription or tenant access

**Symptom:**  
“No enabled subscriptions were found” or selected subscription not found.

**Meaning:**  
The signed-in user cannot see the requested subscription or tenant.

**Action:**  
Confirm Azure role/access, tenant selection, and subscription IDs.

---

### 4. Cost Management throttling or temporary Azure failures

**Symptom:**  
429, timeout, 503, 504, “Too Many Requests.”

**Meaning:**  
Azure is asking the script to slow down.

**Action:**  
The Cost Management and Retail Prices paths now have retry logic, but very large runs may still take time or eventually fail if throttling persists.

---

### 5. Retail Prices lookup is slow

**Symptom:**  
Run appears to sit on “Retail Prices lookup progress…”

**Meaning:**  
The script is matching many Azure cost rows to public retail price records.

**Action:**  
Let it run. For faster but less complete output, use `Skip Retail Prices lookup`, but note that MACC audit artifacts and history mode need the enriched files.

---

### 6. Billing audit permissions

**Symptom:**  
Billing audit warning files contain access errors.

**Meaning:**  
The user can read some Azure resources but not billing-account details.

**Action:**  
Have a billing admin, billing account owner, or CSP/reseller provide the missing evidence.

---

### 7. History mode requires retail enrichment

**Symptom:**  
“History mode requires Retail Prices enrichment files.”

**Meaning:**  
History mode depends on the enriched retail join files.

**Action:**  
Do not skip Retail Prices lookup when running History mode.

---

### 8. Storage upload failures

**Symptom:**  
Azure Blob or ADLS upload failed after local files were generated.

**Meaning:**  
The pull succeeded, but publishing to storage failed.

**Action:**  
Check storage permissions, account/container/file system name, network restrictions, and auth mode.

## What to watch in the results

| Area | What to check |
|---|---|
| **Total cost** | Does MTD / last-month spend look directionally right? |
| **Subscription coverage** | Did all expected subscriptions appear? |
| **Retail match coverage** | In `data-quality-snapshot.csv`, high unmatched cost means savings estimates are less reliable. |
| **Retail exceptions** | Review `retail-match-exceptions.csv` for missing or ambiguous SKU matches. |
| **MACC pacing** | `macc-agreement-status.csv` shows whether the commitment is on track, watch, or at risk. |
| **Estimated savings** | Treat EA/retail savings as directional, not official invoice truth. |
| **RI/SP and AHB files** | These are opportunity indicators, not confirmed entitlement/coverage reports. |
| **Billing contact audit warnings** | These identify where permissions or billing visibility are incomplete. |
| **Raw JSON files** | Useful as evidence, but may include sensitive billing/contact details. |

## Simple explanation for a non-technical stakeholder

This tool logs into Azure, collects the customer’s Azure spend, enriches it with public price data, checks where the spend is happening, and creates files for a Power BI report. It also collects billing evidence such as invoice sections, billing contacts, PO numbers, and billing roles where permissions allow.

The main things that can slow it down are Azure throttling, large numbers of cost lines, retail price matching, and limited billing permissions. The most important results to review are whether all subscriptions were included, whether the cost totals look right, whether retail-price matching coverage is high enough, and whether the MACC commitment is pacing on track.