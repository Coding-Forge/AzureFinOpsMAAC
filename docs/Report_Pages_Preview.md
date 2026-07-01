# Report Pages Preview

This report contains the original FinOps cost and retail comparison pages plus dedicated MACC audit pages.

## Existing Pages

| Page | Purpose |
|---|---|
| Report Landing Page | Entry point, table of contents, and navigation. |
| MACC Retail Overview | Current cost versus retail equivalent analysis. |
| Decomposition Trees | Drill-down paths for cost and savings drivers. |
| Azure Retail Reference | Azure Retail Prices snapshot reference. |
| Cost Export Validation | Export completeness and validation checks. |
| Pipeline Diagnostics | Data pipeline stage diagnostics. |
| Data Quality Actions | Data quality metrics and remediation guidance. |
| Model Technical Tables | Technical schema and model support view. |
| Granular Drillthrough | Hidden drillthrough page for detailed analysis. |

## Created MACC Audit Pages

| Page | Uses | Purpose |
|---|---|---|
| MACC Commitment Overview | `MaccAgreementStatus`, `MaccBenefitLedger` | Executive agreement health, pacing status, remaining commitment, utilization, expected burn, and service-level eligible spend. |
| MACC Benefit Ledger | `MaccBenefitLedger` | Long-term monthly ledger of actual cost, retail equivalent cost, estimated savings, savings rate, eligibility buckets, and match coverage. |
| Agreement Price Audit | `AgreementPriceAudit`, `RetailPriceSnapshot` | Row-level evidence for how savings estimates were calculated and which Azure Retail Prices rows were used. |
| Coverage and Exceptions | `DataQualitySnapshot`, `RetailMatchExceptions` | Data quality, retail match coverage, unmatched/multiple-candidate rows, and MACC eligibility review queue. |
| Billing and Ownership | `ExportRunManifest`, `BillingReconciliation`, `OwnershipMapping` | Export run traceability, invoice reconciliation template, and team/application/accountability mapping. |

Use these pages after a successful launcher run with Cost Management export and Retail Prices lookup enabled. `BillingReconciliation` and `OwnershipMapping` are customer-maintained templates, so those sections remain blank until users fill the corresponding CSV files.

## Recommended MACC Audit Views

| View | Primary tables/measures | Recommended visuals |
|---|---|---|
| MACC Commitment Overview | `MaccAgreementStatus`, `MACC Commitment Amount`, `MACC Eligible Spend To Date`, `MACC Remaining Commitment`, `MACC Commitment Utilization`, `MACC Burn Variance`, `MACC Required Monthly Run Rate` | KPI cards, pacing status, commitment burn-down, eligible spend vs expected burn. |
| Benefit Ledger | `MaccBenefitLedger`, `Ledger Actual Cost`, `Ledger Retail Equivalent Cost`, `Ledger Estimated Savings`, `Ledger Savings Rate`, `Ledger Eligible Spend`, `Ledger Review Spend` | Monthly trend, service contribution matrix, eligible/review/ineligible breakdown. |
| Agreement Price Audit | `AgreementPriceAudit`, `RetailPriceSnapshot` | Row-level evidence table filtered by service, region, meter, SKU, match status, and estimated savings. |
| Coverage and Exceptions | `RetailMatchExceptions`, `DataQualitySnapshot`, `Open Exception Count`, `Exception Actual Cost`, `Audit Retail Match Coverage` | Exception queue ranked by actual cost, match coverage, multiple-candidate and no-match breakdown. |
| Billing Reconciliation | `BillingReconciliation`, `Billing Reconciliation Variance`, `ExportRunManifest` | Invoice vs export variance, run manifest detail, calculation version, and export timestamp. |

## Getting Started

1. Start at the Landing Page to review the report structure.
2. Open MACC Retail Overview for current cost versus retail comparisons.
3. Open MACC Commitment Overview for agreement health and pacing.
4. Open MACC Benefit Ledger for long-term monthly savings trends.
5. Open Agreement Price Audit when validating individual prices, meters, regions, and savings calculations.
6. Open Coverage and Exceptions to prioritize unmatched and review-needed rows.
7. Open Billing and Ownership after filling the customer-maintained reconciliation and ownership CSV templates.

## Tips for Effective Use

- Use filters and slicers to focus on subscriptions, months, services, regions, and match status.
- Review Coverage and Exceptions before making customer-facing savings claims.
- Keep Billing Reconciliation and Ownership Mapping updated as part of monthly governance.
- Use Agreement Price Audit as the evidence page when customers ask how savings were calculated.
