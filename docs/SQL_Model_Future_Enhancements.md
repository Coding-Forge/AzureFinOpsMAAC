# Future Enhancements: SQL-Only FinOps Data Model

## Context

The `powerbi/sql/cost-management.pbip` project is a SQL-only Power BI canvas built directly
against the Azure SQL `FinOpsMaccRetail` database (`finops` schema), with no CSV dependency.
As of this writing, 17 `finops.*` tables are available and fully support core cost, retail
price comparison, billing inventory, and pipeline health reporting.

The original CSV-based report (`powerbi/Cost-Management.pbip`) has additional pages that
answer governance/commitment-tracking questions the SQL model **cannot** currently answer,
because the underlying SQL tables/views don't exist yet. This document tracks that gap so
it can be picked up as future work.

---

## Required for future build-out (tracked as backlog items)

These three capabilities are needed by real report pages in the original CSV model and
should be prioritized whenever the SQL-only model is extended:

### 1. MACC Commitment Burn-Down / Pacing

**Customer question it answers**: "What's our MACC commitment burn-down / pacing status?"

**What's missing**: No SQL equivalent of `MaccAgreementStatus` or `MaccBenefitLedger` exists
today. These would need to capture:
- Agreement ID, term start/end dates, commitment amount, currency (see `docs/MY_FAQ.md` →
  "Why do I need to fill out the Agreement tab?" for the full pacing/eligibility model).
- Monthly ledger of actual cost, retail-equivalent cost, estimated savings, savings rate,
  and MACC eligibility category (eligible / review / ineligible).
- Pacing status calculation (Green/Yellow/Red/Complete/Expired risk) based on elapsed term
  vs. eligible consumption.

**Suggested approach**: Add a `finops.MaccAgreementConfig` table (one row per agreement,
populated manually or via an admin process) plus a `finops.MaccBenefitLedger` view/table
that aggregates `finops.CostRetailFact` by month and joins to the agreement config to
compute burn-down metrics.

### 2. Data Quality Exceptions Queue

**Customer question it answers**: "What data quality exceptions need review?"

**What's missing**: No SQL equivalent of `DataQualitySnapshot` or `RetailMatchExceptions`
exists today.

**Suggested approach**: Add a `finops.RetailMatchExceptions` view that selects rows from
`finops.FactRetailPriceMatch` / `finops.CostRetailFact` where `RetailMatchStatus` indicates
"No Match" or "Multiple Candidates," ranked by `Cost` descending. Add a
`finops.DataQualitySnapshot` view/table summarizing match coverage percentages and row
counts per ingestion run (much of this data already exists in
`finops.IngestionFreshnessByCloud` / `finops.RetailMatchCoverageByCloud` and could be
extended rather than built from scratch).

### 3. Billing Reconciliation & Ownership Mapping

**Customer question it answers**: "Which invoices reconcile against exports, and who owns
what?"

**What's missing**: No SQL equivalent of `BillingReconciliation`, `OwnershipMapping`, or
`ExportRunManifest` exists today. These were originally customer-maintained CSV templates
(filled in manually), not pipeline-generated data.

**Suggested approach**: Decide whether these should remain manually-maintained templates
(in which case they could be simple SQL tables the customer edits directly, or kept as CSV
and loaded via a hybrid CSV+SQL model) or become pipeline-derived. At minimum, add a
`finops.ExportRunManifest` table (the pipeline already tracks similar data in
`finops.IngestionRun` — this could likely be extended or reused directly rather than
building a new table from scratch).

---

## Optional, not required for any future build

### Azure Hybrid Benefit / DevTest / Spot / Reservation savings opportunities

**Customer questions they'd answer**: "Where can we apply Azure Hybrid Benefit?", "What
DevTest/Spot pricing opportunities exist?", "What's our Reservation/Savings Plan coverage?"

**Status**: No `finops` SQL equivalents exist for `AzureHybridBenefitInventory`,
`AzureHybridBenefitOpportunities`, `DevTestPricingOpportunities`,
`DevTestSubscriptionInventory`, `SpotPricingOpportunities`, `SpotWorkloadInventory`,
`ReservationSavingsPlanCoverage`, or `ReservationSavingsPlanInventory`.

**Decision**: This is explicitly marked **optional** — not required for any future build of
the SQL-only model. Pick this up only if there's a specific customer ask for these specific
opportunity/savings categories; otherwise, leave it out of scope indefinitely.

---

## Summary Table

| Capability | Priority | SQL tables needed |
|---|---|---|
| MACC commitment burn-down / pacing | Required (future) | `MaccAgreementConfig`, `MaccBenefitLedger` |
| Data quality exceptions queue | Required (future) | `RetailMatchExceptions`, `DataQualitySnapshot` (or extend existing freshness/coverage tables) |
| Billing reconciliation & ownership mapping | Required (future) | `BillingReconciliation`, `OwnershipMapping`, `ExportRunManifest` (or extend `IngestionRun`) |
| Azure Hybrid Benefit / DevTest / Spot / Reservation opportunities | Optional, not required | `AzureHybridBenefitInventory`, `AzureHybridBenefitOpportunities`, `DevTestPricingOpportunities`, `DevTestSubscriptionInventory`, `SpotPricingOpportunities`, `SpotWorkloadInventory`, `ReservationSavingsPlanCoverage`, `ReservationSavingsPlanInventory` |
