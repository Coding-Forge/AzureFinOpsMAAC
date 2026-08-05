# FinOps Semantic Model Redesign Progress

## Goal

Move the solution from a mostly script-shaped, pre-joined CSV reporting model toward a cleaner relationship-based semantic model, while preserving the current script-based extraction, retry, matching, and audit evidence strengths.

## Progress meter

```text
Overall progress: 24 / 24 complete
[########################] 100%
```

| Phase | Status | Complete | Total |
| --- | --- | ---: | ---: |
| Phase 1 - Stabilize current model | Complete | 5 | 5 |
| Phase 2 - Add normalized CSV outputs | Complete | 6 | 6 |
| Phase 3 - Build relationship-based semantic model | Complete | 7 | 7 |
| Phase 4 - Retire redundant staging tables | Complete | 4 | 4 |
| Phase 5 - Release and documentation | Complete | 2 | 2 |

## Phase 1 - Stabilize current model

Purpose: make sure the current release is reliable before changing the data shape.

- [x] Confirm Power BI refresh is stable with the latest model.
- [x] Confirm `template\Cost-Management.pbit` opens and prompts for expected parameters.
- [x] Confirm latest generated Cost Management totals match Azure Cost Management for the selected scope/date range.
- [x] Confirm Fabric costs appear correctly in the latest generated data and report.
- [x] Confirm the latest release zip works from a clean extracted folder.

## Phase 2 - Add normalized CSV outputs

Purpose: add model-friendly files without breaking existing audit/report files.

- [x] Add `fact-cost-usage.csv` from raw Cost Management output.
- [x] Add `dim-subscription.csv` from selected subscriptions.
- [x] Add `dim-service.csv` from cost/service values.
- [x] Add `dim-region.csv` from Azure location metadata and normalized ARM region names.
- [x] Add `dim-meter.csv` / product-meter-unit metadata.
- [x] Add `fact-retail-price-match.csv` with selected match, candidate count, confidence/status, and retail SKU references.

## Phase 3 - Build relationship-based semantic model

Purpose: make Power BI responsible for relationships, slicers, reusable dimensions, and measures.

- [x] Add/import `FactCostUsage`.
- [x] Add/import `FactRetailPriceMatch`.
- [x] Add/import normalized dimensions: subscription, service, region, meter, retail SKU, match status.
- [x] Relate facts to dimensions with single-direction filter paths where possible.
- [x] Rebuild core measures from normalized facts.
- [x] Validate totals against the current enriched-file model.
- [x] Update PBIT parameters and refresh behavior.

## Phase 4 - Retire redundant staging tables

Purpose: reduce refresh complexity and avoid cyclic dependency/staging-table issues.

- [x] Hide or remove `mtd-cost-by-retail-join`.
- [x] Hide or remove `mtd-cost-by-retail-join-with-arm-region`.
- [x] Hide or remove `last-month-cost-by-retail-join`.
- [x] Hide or remove `last-month-cost-by-retail-join-with-arm-region`.

## Phase 5 - Release and documentation

Purpose: make the redesign understandable and distributable.

- [x] Update README, technical runbook, report guide, and release process.
- [x] Publish a release with the updated PBIT and PBIP/source package.

## Design principles

- Keep PowerShell responsible for extraction, throttling, API retry, raw evidence, retail price matching, and audit file generation.
- Move reusable slicing and analysis behavior into the Power BI semantic model.
- Preserve existing enriched/audit CSVs until the relationship model is validated.
- Add normalized files in parallel before removing or hiding legacy staging tables.
- Validate every phase against Azure Cost Management totals and known service-level spend, especially Microsoft Fabric.

## Phase 1 validation notes

Use this section to capture evidence from the stabilization pass.

| Check | Result | Evidence / notes |
| --- | --- | --- |
| Refresh stable | Passed | User confirmed PBIP refresh completed without errors after removing cyclic staging dependencies. |
| PBIT opens and prompts | Passed | User exported a fresh PBIT after the stable PBIP refresh and saved it to `template\Cost-Management.pbit`. |
| Cost total matches Azure Cost Management | Passed | Validated against a completed local export run. Generated service/resource-group and enriched retail-join files matched expected Cost Management totals for the tested date range. |
| Fabric cost appears | Passed | The tested local run showed Microsoft Fabric cost in both MTD service/resource group and enriched retail-join files. Report-level visual confirmation is still part of the refresh/PBIT manual check. |
| Clean release extraction works | Passed | Release zip extracted to a clean temp folder. Required public files existed, extracted launcher parsed successfully, and manifest showed a clean build. |

## Phase 2 validation notes

| Check | Result | Evidence / notes |
| --- | --- | --- |
| Normalized output function parses | Passed | `scripts\Get-CostAnalysis.ps1` parsed successfully after adding normalized output functions. |
| Synthetic normalized output test | Passed | Focused helper test generated `fact-cost-usage.csv`, `dim-subscription.csv`, `dim-service.csv`, `dim-region.csv`, `dim-meter.csv`, `fact-retail-price-match.csv`, and `dim-retail-sku.csv` from a two-row synthetic dataset. |
| Existing files preserved | Passed | New outputs are additive. Existing enriched cost, retail join, summary, history, and audit CSV generation remains in place. |

## Phase 3 validation notes

| Check | Result | Evidence / notes |
| --- | --- | --- |
| `FactCostUsage` imported | Passed | Added `powerbi\Cost-Management.SemanticModel\definition\tables\FactCostUsage.tmdl`, sourced from `fact-cost-usage.csv`, and registered it in `model.tmdl`. |
| `FactRetailPriceMatch` imported | Passed | Added `powerbi\Cost-Management.SemanticModel\definition\tables\FactRetailPriceMatch.tmdl`, sourced from `fact-retail-price-match.csv`, and registered it in `model.tmdl`. |
| Backward compatibility | Passed | New fact tables are additive and tolerate missing normalized CSVs with `MissingField.UseNull`; existing report tables and measures remain unchanged. |
| Normalized dimensions imported | Passed | Added `DimSubscription`, `DimServiceModel`, `DimRegionModel`, `DimMeter`, and derived `DimRetailSku` from normalized outputs/facts. Continued using existing `DimRetailMatch` for match-status filtering. |
| Normalized relationships added | Passed with exception | Added single-direction relationships from `FactCostUsage` and `FactRetailPriceMatch` to subscription, service, region, meter, and retail match dimensions. `DimRetailSku` remains disconnected because relating a fact-derived Retail SKU table back to `FactRetailPriceMatch` creates a cyclic dependency in Power BI. |
| Normalized measures added | Passed | Added additive normalized measures for actual cost, retail equivalent cost, estimated savings, savings rate, matched actual cost, retail match coverage, and cost row count. Existing measures were not replaced. |
| Normalized history support added | Passed | Generated run scripts now maintain `fact-cost-usage-history.csv` and `fact-retail-price-match-history.csv`; normalized fact tables switch between current files and history files based on `AnalysisMode`. |
| Normalized totals validated | Passed | Against a completed local export run, `FactCostUsage` and `FactRetailPriceMatch` matched enriched-file totals with zero delta. Generated normalized files had the expected fact and dimension row counts. |
| Refresh behavior validated | Passed | User refreshed PBIP successfully after removing `DimRetailSku` semantic import, retiring service-resourcegroup staging queries, and repointing legacy MTD/Last Month measures to `FactCostUsage`. Power BI generated a local date table for `FactCostUsage[UsageDateAsDate]`, which was committed as part of the stable model. |

## Phase 4 validation notes

| Check | Result | Evidence / notes |
| --- | --- | --- |
| Retail join staging tables retired | Passed | The four redundant retail join staging tables were marked `isHidden` instead of deleted because the `finops_pipeline_diagnostics` page still references them. This preserves diagnostics visuals while removing the tables from the normal field list. |

## Phase 5 validation notes

| Check | Result | Evidence / notes |
| --- | --- | --- |
| Documentation updated | Passed | README, technical runbook, and report guide now describe normalized model outputs, normalized history files, and the need to re-export `template\Cost-Management.pbit` after semantic model changes. |
| PBIT re-export and release | Passed | User confirmed PBIP refresh succeeded after normalized model/date-dimension changes, then exported a fresh `template\Cost-Management.pbit`. Release package was prepared from this refreshed template. |

## Future roadmap - production durable-store automation

Purpose: move from desktop-driven data pulls to an enterprise production pattern where a scheduled serverless runner uses managed identity or service principal authentication, writes run evidence, and upserts curated data into Azure SQL DB for governed reporting and Fabric/Power BI consumption.

| Workstream | Status | Notes |
| --- | --- | --- |
| SQL durable-store schema | Complete | Initial `finops` schema and durable tables deploy to Azure SQL DB with Entra token auth. The first customer demo database was created and loaded successfully. |
| SQL upsert writer | Complete | `Import-FinOpsSqlData.ps1` now stages rows in SQL temp tables and performs idempotent `MERGE` upserts for keyed tables. Audit evidence replaces only affected run partitions. `-Replace` remains available for full demo/recovery reloads. |
| Serverless ingestion runtime | Started | Azure Function timer-trigger scaffold exists, but the current runner is a CLI bridge for local dev/POC or custom-container hosts. Enterprise production should use native Azure PowerShell/REST calls without depending on Azure CLI being installed in the Function host. |
| Native managed identity / service principal auth | Complete | Native mode now uses `Az.Accounts`/REST for Cost Management and Billing extraction, native retail enrichment, MACC audit generation, durable history updates, and Azure SQL loading without Azure CLI. CLI bridge remains available for local dev/POC fallback. |
| Bicep deployment | Complete in current scope | Added baseline `infra/bicep` deployment for Azure SQL DB, Function App, Storage, App Insights, managed identity, optional SQL firewall rule, native ingestion app settings, optional App Insights scheduled-query alerts, subscription-scope role-assignment helper, opt-in SQL private endpoint / Function VNet integration, and Key Vault references for service-principal secrets. |
| Terraform deployment | Deferred | Baseline `infra/terraform` files exist for future customers standardized on Terraform, but active hardening is deferred. Continue with Bicep-first production deployment. |
| Operational monitoring | Complete in current scope | Azure SQL now deploys read-only monitoring views for cloud/subscription freshness, row counts, retail match coverage, and consolidated operational warnings. The SQL loader prints the health summary after each load, the PBIP includes optional SQL-backed monitoring tables plus an Operational Freshness page, and Bicep can deploy App Insights alerts for failed or missed Function runs. |
| Fabric integration | Planned | Keep Azure SQL DB as governed source of record. Document Fabric mirroring, Dataflow Gen2, pipeline copy, or direct Power BI SQL connection options for BI development. |

Suggested implementation order:

1. Harden Azure SQL schema and table naming.
2. Add SQL staging tables and idempotent upsert procedures.
3. Convert the local SQL loader into a reusable durable-store writer. (Complete)
4. Add Azure Function timer-trigger runner. (Started with CLI bridge; production hardening remains)
5. Replace CLI bridge with native managed identity / service principal REST execution.
6. Add Bicep deployment. (Started with baseline)
7. Add monitoring and freshness reporting.
8. Revisit Terraform if/when a customer requires Terraform-standard deployment.

## Standalone table rationale

Some model tables intentionally remain disconnected because they support audit, evidence, exception, reconciliation, ownership, or opportunity-review pages. They do not always share the same grain as the core cost facts. Keeping them standalone avoids ambiguous relationships, circular dependencies, many-to-many filtering, and duplicate totals while preserving their value for validation and governance.
