# MACC Insight Gap Assessment

## Current coverage

The solution already covers a strong first version of MACC-vs-retail analysis:

| Capability | Current evidence |
| --- | --- |
| Current actual cost vs retail equivalent | Measures for actual cost, retail equivalent cost, estimated savings, savings rate, effective unit cost, and retail unit price. |
| Retail match confidence | Match status, candidate count, matched cost coverage, unmatched cost, matched row count, unmatched row count, and row coverage. |
| Current and prior-month analysis | Cost Management export supports MTD and last-month periods. |
| Historical savings trend foundation | Running history mode maintains `cost-retail-history.csv` with `HistoryMonth`, `ExportRunId`, `ExportedUtc`, `Period`, `SubscriptionName`, and `SubscriptionId`. |
| Customer troubleshooting surfaces | Report pages include overview, export validation, pipeline diagnostics, data quality actions, retail reference, decomposition trees, and drillthrough. |
| Multi-location data storage | Launcher supports local, Azure Blob, ADLS Gen2, and SharePoint parameter mapping. |

## Primary gaps to close

| Priority | Gap | Why it matters |
| --- | --- | --- |
| 1 | MACC commitment burn-down | Customers need to know how much eligible spend has retired against the commitment, remaining commitment, utilization percentage, and whether they are on pace before agreement end. |
| 1 | Eligible vs non-eligible MACC spend | Not all Azure spend retires MACC. Separate eligible, ineligible, unknown, Marketplace, support, credits, taxes, reservations, and savings plans where data allows. |
| 1 | Agreement metadata and targets | Add configurable agreement start/end dates, commitment amount, currency, expected monthly burn, and customer-defined thresholds. |
| 1 | Long-term benefit ledger | Persist monthly snapshots of actual cost, retail equivalent, estimated savings, match coverage, eligible spend, and agreement burn-down so benefits can be audited over the full agreement term. |
| 2 | Benefit attribution by pricing model | Distinguish MACC/negotiated pricing effects from reservations, savings plans, Azure Hybrid Benefit, credits, refunds, and marketplace charges. |
| 2 | Invoice/billing reconciliation | Tie report totals back to invoice period, billing profile/account, subscription, and charge type to increase customer trust. |
| 2 | Price agreement audit evidence | Store the rate inputs used for each monthly calculation: retail price, effective unit cost, meter, region, unit of measure, match status, and candidate count. |
| 2 | Forecast and pacing | Add month-end forecast, agreement-end forecast, required monthly burn, and risk flags for under-consumption or unexpected spikes. |
| 3 | Ownership accountability | Bring in tags, resource group ownership, application, environment, and business unit views so customers can act on savings gaps. |
| 3 | Exception workflow | Add review status, owner, notes, and resolution for unmatched or multiple-candidate retail mappings. |
| 3 | Price-change tracking | Track retail price effective dates and month-over-month retail rate changes to explain savings movement that is not caused by usage changes. |

## Recommended report additions

### MACC Commitment Overview

Purpose: executive view of agreement health.

Suggested visuals:

- Commitment amount, eligible spend to date, remaining commitment, utilization percent, days/months remaining.
- Actual burn vs planned burn line chart.
- Forecasted agreement-end utilization.
- Risk indicator: on track, watch, at risk, overrun.
- Eligible vs ineligible spend split.
- Top services and subscriptions contributing to commitment retirement.

### Benefit Ledger

Purpose: audit-ready historical record.

Suggested visuals:

- Monthly actual cost, retail equivalent, estimated savings, savings rate.
- Monthly eligible MACC spend and cumulative eligible spend.
- Retail match coverage by month.
- Benefit attribution waterfall: retail equivalent -> negotiated/MACC effect -> reservations/savings plans -> credits/refunds -> actual billed cost.
- Export run ID and exported UTC slicers for auditability.

### Agreement Price Audit

Purpose: show how savings estimates were calculated.

Suggested visuals:

- Row-level table with subscription, service, region, meter, product, usage quantity, actual cost, effective unit cost, retail unit price, retail equivalent cost, estimated savings, match status, candidate count, and export run ID.
- Filters for unmatched, multiple candidates, high-dollar variance, and low match confidence.
- Detail page for a single meter/service showing retail candidates and selected match.

### Forecast and Pacing

Purpose: help customers act before the agreement term ends.

Suggested visuals:

- Month-end forecast for current period.
- Agreement-end forecast versus commitment.
- Required monthly run rate to fully consume commitment.
- Variance from expected burn.
- Top drivers of forecast variance.

### Coverage and Exceptions

Purpose: protect confidence in reported savings.

Suggested visuals:

- Retail match coverage by cost, row count, service, region, and month.
- Unmatched cost ranked by financial impact.
- Multiple-candidate mappings ranked by financial impact.
- Exceptions aging and owner/status if an exception workflow file is added.

### Benefit Attribution

Purpose: avoid overstating MACC benefits.

Suggested visuals:

- Cost by pricing model, charge type, reservation, savings plan, Azure Hybrid Benefit, credit, refund, and marketplace/support categories where available.
- Estimated MACC/negotiated savings separated from other optimization benefits.
- Amortized versus actual cost toggle if Cost Management exports support both views.

## Recommended data additions

| Dataset | Purpose | Suggested source |
| --- | --- | --- |
| `agreement-config.csv` or JSON | Agreement start/end, commitment amount, currency, customer name, expected burn profile, alert thresholds. | User-maintained launcher/config page. |
| `macc-benefit-ledger.csv` | Monthly immutable or append-only audit snapshots. | Generated after each history run. |
| `retail-price-snapshot.csv` | Retail prices and effective dates used in each calculation. | Azure Retail Prices API results. |
| `retail-match-exceptions.csv` | Review queue for no-match and multiple-candidate rows. | Generated by export, optionally user-maintained. |
| `billing-reconciliation.csv` | Invoice-period totals and variance against exported cost totals. | Cost Management/Billing export where accessible. |
| `ownership-mapping.csv` | App/team/business unit mapping for subscriptions, resource groups, tags, or resources. | User-maintained mapping file. |

## Recommended audit controls

| Control | Description |
| --- | --- |
| Export run manifest | For every run, write run ID, exported UTC, as-of date, tenant/subscription list, script version/git commit if available, selected mode, storage target, output files, row counts, and total actual/retail/savings values. |
| Input parameter snapshot | Preserve the Power BI parameter mapping, agreement config, selected subscriptions, and storage destination used for each run. |
| Calculation version | Stamp outputs with a calculation schema/version so future formula changes can be explained. |
| Data quality snapshot | Persist retail match coverage, unmatched cost, multiple-candidate cost, null/zero usage rows, currency mismatches, and high-variance rows by run. |
| Price evidence snapshot | Store retail price rows used for matching, including effective start/end dates, SKU ID, meter ID, unit of measure, currency, and selected match ranking. |
| Reconciliation totals | Persist totals by subscription, period, service, charge type, and invoice/billing period where available. |
| Exception disposition | Track who reviewed exceptions, when, the selected mapping or exclusion reason, and whether it affects customer-facing savings. |
| Immutable history option | Prefer append-only monthly ledger snapshots for audit mode; allow corrected reruns to be marked as superseding earlier runs rather than silently replacing them. |

## Suggested implementation sequence

1. Add agreement configuration fields to the launcher and persist them in settings/output.
2. Add export run manifest generation with row counts, totals, script version, selected subscriptions, parameters, and output file inventory.
3. Add `macc-benefit-ledger.csv` as a durable monthly audit ledger, separate from the current replacement-style `cost-retail-history.csv`.
4. Add commitment burn-down measures and a MACC Commitment Overview report page.
5. Add retail match exception export plus an Agreement Price Audit page.
6. Add forecast and pacing measures after agreement metadata and ledger snapshots are stable.
7. Add ownership mapping and benefit attribution enhancements after core auditability is in place.

## Bottom line

The solution already explains estimated MACC-vs-retail savings for current and historical cost exports. The biggest missing customer value is agreement-level auditability: commitment burn-down, eligible-spend classification, immutable benefit snapshots, pricing evidence, and reconciliation back to billing/invoice data. Those additions would make the report more credible for long-term MACC benefit reviews and executive agreement governance.
