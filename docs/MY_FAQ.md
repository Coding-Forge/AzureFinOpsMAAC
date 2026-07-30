This step is about creating the **contract baseline** for a MACC burn-down model. It tells the report what commitment the customer made, over what time window, and how aggressively the report should flag under-consumption.

**Agreement ID** is the customer’s MACC / Azure commitment agreement identifier. Use the ID from the Microsoft agreement/billing source you trust, not a friendly account name. It becomes the join/filter key for the commitment record and helps distinguish multiple commitments for the same customer.

**Term** is the commitment period. At minimum you need a **start date** and **end date**; sometimes teams also track term length such as 12, 36, or 60 months. This drives elapsed-time calculations, remaining months, expected consumption-to-date, and whether the customer is ahead or behind pace.

**Commitment amount** is the total MACC value the customer agreed to consume during the term. This is the denominator for burn-down: consumed-to-date divided by commitment amount. For example, a $10M MACC with $2.5M eligible consumption is 25% burned.

**Currency** matters because Cost Management tables can expose `costInBillingCurrency`, `costInPricingCurrency`, and `costInUsd`. The agreement currency should match the commitment contract. If the customer’s MACC is denominated in USD, use USD-based eligible consumption. If it’s in another billing currency, use the corresponding billing-currency field and avoid mixing currencies without an explicit FX rule.

**Pacing thresholds** are the health rules. A simple model compares actual burn percentage to expected burn percentage based on time elapsed:

```text
Expected burn % = elapsed term days / total term days
Actual burn %   = eligible MACC consumption / commitment amount
Pacing gap      = actual burn % - expected burn %
```

Example threshold logic:

| Status | Rule |
|---|---|
| **Green** | Actual burn is within 5 percentage points of expected pace, or ahead |
| **Yellow** | Actual burn is 5–15 points behind expected pace |
| **Red** | Actual burn is more than 15 points behind expected pace |
| **Complete** | Actual burn is >= 100% |
| **Expired risk** | End date is near and remaining commitment is material |

The most important nuance: **not all Azure cost counts toward MACC**. A good report should separate **total Azure spend** from **MACC-eligible decrementing consumption**. Marketplace, support, taxes, some reservations/savings-plan constructs, credits, and certain offers can behave differently depending on agreement terms and billing data source. So the Agreement tab should define the commitment, but the model still needs a clear rule for what consumption is eligible to burn it down.