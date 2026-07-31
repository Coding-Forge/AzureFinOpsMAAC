# FinOps Semantic Model Redesign Progress

## Goal

Move the solution from a mostly script-shaped, pre-joined CSV reporting model toward a cleaner relationship-based semantic model, while preserving the current script-based extraction, retry, matching, and audit evidence strengths.

## Progress meter

```text
Overall progress: 11 / 24 complete
[###########-------------] 46%
```

| Phase | Status | Complete | Total |
| --- | --- | ---: | ---: |
| Phase 1 - Stabilize current model | In progress | 3 | 5 |
| Phase 2 - Add normalized CSV outputs | Complete | 6 | 6 |
| Phase 3 - Build relationship-based semantic model | In progress | 2 | 7 |
| Phase 4 - Retire redundant staging tables | Not started | 0 | 4 |
| Phase 5 - Release and documentation | Not started | 0 | 2 |

## Phase 1 - Stabilize current model

Purpose: make sure the current release is reliable before changing the data shape.

- [ ] Confirm Power BI refresh is stable with the latest model.
- [ ] Confirm `template\Cost-Management.pbit` opens and prompts for expected parameters.
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
- [ ] Add/import normalized dimensions: subscription, service, region, meter, retail SKU, match status.
- [ ] Relate facts to dimensions with single-direction filter paths where possible.
- [ ] Rebuild core measures from normalized facts.
- [ ] Validate totals against the current enriched-file model.
- [ ] Update PBIT parameters and refresh behavior.

## Phase 4 - Retire redundant staging tables

Purpose: reduce refresh complexity and avoid cyclic dependency/staging-table issues.

- [ ] Hide or remove `mtd-cost-by-retail-join`.
- [ ] Hide or remove `mtd-cost-by-retail-join-with-arm-region`.
- [ ] Hide or remove `last-month-cost-by-retail-join`.
- [ ] Hide or remove `last-month-cost-by-retail-join-with-arm-region`.

## Phase 5 - Release and documentation

Purpose: make the redesign understandable and distributable.

- [ ] Update README, technical runbook, report guide, and release process.
- [ ] Publish a release with the updated PBIT and PBIP/source package.

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
| Refresh stable | Pending |  |
| PBIT opens and prompts | Pending |  |
| Cost total matches Azure Cost Management | Passed | Latest checked run: `C:\Projects\Fabric\AuditDumps\run-20260730-105838`. `mtd-cost-by-service-resourcegroup.csv` and `mtd-cost-by-retail-join-enriched.csv` both total `$473.59` for `20260701`-`20260730`. |
| Fabric cost appears | Passed | Same latest run shows Microsoft Fabric cost of `$127.04` in both MTD service/resource group and enriched retail-join files. Report-level visual confirmation is still part of the refresh/PBIT manual check. |
| Clean release extraction works | Passed | `v1.0.3` release zip extracted to a clean temp folder. Required files existed: `README.md`, `scripts\Start-FinOpsDataPull.ps1`, `template\Cost-Management.pbit`, `powerbi\Cost-Management.pbip`, and `_release-manifest.json`. Extracted launcher parsed successfully. Manifest showed `hasPbit=True`, `hasPbip=True`, and `dirty=False`. |

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
