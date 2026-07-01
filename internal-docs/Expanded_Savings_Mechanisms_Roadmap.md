# Expanded Savings Mechanisms Roadmap

## Goal

Expand the solution beyond MACC-style agreement tracking so customers can explain Azure savings from multiple commercial and technical benefit mechanisms. The report should separate:

- Public retail equivalent cost
- Actual/effective customer cost
- Estimated negotiated agreement discount
- Reservation and Savings Plan effects
- Azure Hybrid Benefit effects
- Spot, Dev/Test, credits, refunds, marketplace, and other adjustments

## Guiding principles

- Do not overstate savings. Separate estimated directional savings from billing-system-confirmed discounts.
- Keep a clear audit trail: run ID, exported UTC, calculation version, source rows, match status, and exception status.
- Treat credits/refunds as financial offsets, not service unit-price discounts.
- Preserve existing MACC reporting while generalizing naming toward agreement and benefit attribution.
- Use customer-provided agreement metadata until official agreement/billing balance APIs are integrated.

## Savings mechanisms to add

| Sequence | Mechanism | What it means | Likely data source | Reporting to add |
| --- | --- | --- | --- | --- |
| 1 | Enterprise Agreement (EA) / negotiated agreement pricing | Actual customer price is lower than public retail because of enterprise agreement pricing or negotiated rates. | Existing Cost Management actual cost plus Azure Retail Prices comparison; optional future price sheet API. | EA savings overview, EA savings ledger, service/subscription/region detail, audit evidence. |
| 2 | Reservations / Reserved Instances | 1-year or 3-year committed capacity produces lower effective rates for eligible services. | Cost Management amortized cost, reservation utilization/coverage exports, reservation APIs where available. | Reservation utilization, coverage, unused commitment, amortized vs actual cost, expiring reservations. |
| 3 | Azure Savings Plans for Compute | Hourly compute spend commitment applies discounted rates across eligible compute usage. | Cost Management amortized cost and savings plan utilization/coverage data. | Savings plan utilization, coverage, hourly commitment burn, uncovered eligible compute. |
| 4 | Azure Hybrid Benefit | Existing Windows Server or SQL Server licensing reduces Azure licensing cost. | Resource configuration, meter/SKU, licensing flags where available, customer-maintained mapping if needed. | AHB-enabled vs eligible-not-enabled workloads, estimated missed savings. |
| 5 | Spot pricing | Interruptible compute capacity gets lower prices. | Cost Management usage/meter/SKU data and VM configuration. | Spot actual vs retail, interrupted workload review, suitability candidates. |
| 6 | Dev/Test pricing | Eligible subscriptions or offers receive discounted Windows/dev-test rates. | Subscription offer/category, Cost Management actual cost, retail comparison. | Dev/Test savings summary and subscriptions using discounted dev/test rates. |
| 7 | Credits, refunds, sponsorship, adjustments | Invoice offsets reduce payable amount but are not service unit-price discounts. | Billing/invoice exports, Cost Management charge type where available. | Financial offsets page separated from technical/price savings. |
| 8 | Marketplace private offers | Marketplace product prices are negotiated outside Azure retail meter pricing. | Marketplace charges, billing exports, private offer metadata if available. | Marketplace negotiated savings and reconciliation page. |
| 9 | Support plan or other commercial adjustments | Support/contract adjustments not tied to Azure service usage meters. | Billing exports or customer-maintained reconciliation. | Commercial adjustment reconciliation, not included in service savings rate. |

## Phase 1: Enterprise Agreement savings

Status: first implementation complete on `feature/expanded-savings-mechanisms`.

### Implementation approach

Use the existing actual-vs-retail comparison as the first EA/negotiated agreement estimate:

- `ActualCost`: actual cost from Azure Cost Management.
- `RetailEquivalentCost`: usage quantity multiplied by Azure Retail Prices API unit price.
- `EstimatedEaSavings`: `RetailEquivalentCost - ActualCost`.
- `EaSavingsRate`: `EstimatedEaSavings / RetailEquivalentCost`.
- `AgreementPricingCategory`: start as `EA / negotiated agreement estimate`.

This does not prove official EA price sheet savings. It gives an auditable estimate using public retail as the comparison baseline. Future phases can improve this with official price sheet and billing profile APIs.

### Data files to add

| File | Purpose |
| --- | --- |
| `enterprise-agreement-savings.csv` | Per-service/subscription/month summary of actual cost, retail equivalent cost, estimated EA savings, savings rate, match coverage, and eligibility/review flags. |
| `enterprise-agreement-price-audit.csv` | Row-level EA savings evidence based on actual cost versus retail equivalent. Can initially reuse `agreement-price-audit.csv` fields with EA-specific labels. |

### Semantic model additions

| Table/measure | Purpose |
| --- | --- |
| `EnterpriseAgreementSavings` | Import `enterprise-agreement-savings.csv`. |
| `EA Actual Cost` | Sum of EA actual cost. |
| `EA Retail Equivalent Cost` | Sum of retail equivalent cost. |
| `Estimated EA Savings` | Retail equivalent minus actual cost. |
| `EA Savings Rate` | Estimated EA savings divided by retail equivalent. |
| `EA Match Coverage` | Share of actual cost with matched retail pricing. |

### Report additions

| Page | Audience | Questions answered |
| --- | --- | --- |
| Enterprise Agreement Savings | Executives, account teams, FinOps leads | How much lower is actual cost than public retail? Which subscriptions/services drive EA savings? What is the savings rate and retail match coverage? |
| EA Savings Detail | Analysts and customer engineers | Which rows produce the savings estimate? Which rows need pricing or eligibility review? |

## Phase 2: Reservation and Savings Plan savings

Status: first implementation started.

Research Cost Management export dimensions needed for:

- `PricingModel`
- `ChargeType`
- `BenefitId`
- `BenefitName`
- Reservation order/reservation ID if exposed
- Amortized cost versus actual cost

Add reservation/savings-plan pages only after confirming the export shape for the target agreement/subscription type.

### First implementation delivered

- `reservation-savings-plan-coverage.csv` generated from current actual-vs-retail rows.
- `reservation-savings-plan-inventory.csv` customer-maintained inventory template.
- `ReservationSavingsPlanCoverage.tmdl` and `ReservationSavingsPlanInventory.tmdl`.
- Measures for RI/SP actual cost, retail equivalent cost, estimated rate savings, savings rate, and match coverage.
- Report page: `Reservation and Savings Plan Coverage`.

### Important limitation

The first implementation is an opportunity and coverage review view. It does not yet consume official reservation or savings plan utilization, coverage, amortized cost, or benefit ID exports. Treat any RI/SP savings numbers as directional until official Cost Management benefit fields are integrated.

## Phase 3: License and workload optimization savings

Status: Azure Hybrid Benefit first implementation started.

Add AHB, Spot, and Dev/Test analysis after usage/resource configuration fields are available. Some of these may require resource inventory joins beyond current Cost Management groupings.

### Azure Hybrid Benefit first implementation delivered

- `azure-hybrid-benefit-opportunities.csv` generated from current actual-vs-retail rows using Windows/SQL workload heuristics.
- `azure-hybrid-benefit-inventory.csv` customer-maintained license/workload inventory template.
- `AzureHybridBenefitOpportunities.tmdl` and `AzureHybridBenefitInventory.tmdl`.
- Measures for AHB opportunity actual cost, retail equivalent cost, estimated rate savings, and opportunity savings rate.
- Report page: `Azure Hybrid Benefit Opportunities`.

### Important limitation

The first implementation is an opportunity review. It does not yet inspect VM or SQL resource configuration to confirm whether Azure Hybrid Benefit is enabled, nor does it validate license entitlement. Treat results as candidate workloads until reviewed by licensing and engineering owners.

### Spot pricing first implementation delivered

- `spot-pricing-opportunities.csv` generated from current actual-vs-retail rows using Spot/interruptible workload heuristics.
- `spot-workload-inventory.csv` customer-maintained workload suitability template.
- `SpotPricingOpportunities.tmdl` and `SpotWorkloadInventory.tmdl`.
- Measures for Spot opportunity actual cost, retail equivalent cost, estimated rate savings, and opportunity savings rate.
- Report page: `Spot Pricing Opportunities`.

### Dev/Test pricing first implementation delivered

- `devtest-pricing-opportunities.csv` generated from current actual-vs-retail rows using subscription/workload naming heuristics.
- `devtest-subscription-inventory.csv` customer-maintained subscription and owner review template.
- `DevTestPricingOpportunities.tmdl` and `DevTestSubscriptionInventory.tmdl`.
- Measures for Dev/Test opportunity actual cost, retail equivalent cost, estimated rate savings, and opportunity savings rate.
- Report page: `Dev/Test Pricing Opportunities`.

### Important limitation

Spot and Dev/Test first implementations are opportunity reviews. Confirmed Spot savings requires resource configuration and eviction/suitability review. Confirmed Dev/Test savings requires subscription offer/category validation and eligibility review.

Next roadmap targets: credits/refunds/sponsorship adjustments, marketplace private offers, and support/commercial adjustments.

## Open design questions

- Should official EA price sheet APIs be required for a "confirmed EA savings" report, or should the first version remain "estimated versus public retail"?
- Which billing account scopes will customers commonly have permission to access?
- Should credits/refunds be shown in the same savings report or only on reconciliation pages?
- Should marketplace/private offers be included in the same model or isolated due to different pricing mechanics?

## First implementation checklist

- Generate `enterprise-agreement-savings.csv` from existing audit cost rows.
- Add `EnterpriseAgreementSavings.tmdl`.
- Add EA savings measures to `MaccAuditMeasures.tmdl` or a new `SavingsMechanismMeasures.tmdl`.
- Add an `Enterprise Agreement Savings` report page.
- Document the distinction between estimated EA savings and official billing-system discounts.
