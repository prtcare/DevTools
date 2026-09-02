# DB-M16 — Currency Conversion (USD → INR, generic)

Milestone: **DB-M16 — Actual Cost Calculator + Currency Conversion** (Lane B1)
Effective-dated exchange-rate evidence · historic converted costs reproducible · zero FX/network calls

---

## 1. Model

Every conversion uses an `ExchangeRateRecord v1` with an effective window (same
convention as pricing):

```
[ EffectiveAtUtc , EffectiveToUtc )
```

- `EffectiveAtUtc` **inclusive**, `EffectiveToUtc` **exclusive**, null end =
  open-ended.
- The rate applicable at the **attempt timestamp** is the one used. A later rate
  change never rewrites a historic cost: the same pricing record + the same
  exchange-rate record always produce the same historic converted total.

The model is generic for any base/quote pair (USD→INR is the seed use case).

---

## 2. Historic reproducibility rule

For a request at time `t`:

1. resolve the pricing record effective at `t` (DB-M15),
2. resolve the exchange-rate record effective at `t`,
3. converted = provider-currency total × that rate.

Steps 1–3 are pure functions of `t` and the catalogues, so re-running the
calculation always reproduces the same historic cost — even after newer rates
and prices exist. The `ExchangeRateId` of the evidence used is recorded on the
result.

---

## 3. Conversion flow (`Calculate-AiAttemptCost` step 7)

- `CurrencyTarget == pricing currency` -> identity conversion (rate 1.0).
- `Input.ExchangeRate` supplied (authorized override, > 0) -> used directly; no
  evidence id is recorded (the caller owns that evidence).
- Otherwise `Get-AiExchangeRateAt(base, quote, t)` resolves the single effective
  record. Overlapping windows are rejected by validation; if ambiguity ever
  appears in unvalidated data the lookup **fails safe** (returns nothing) rather
  than silently picking between records.
- **No applicable rate -> `CURRENCY_CONVERSION_UNAVAILABLE`.** The provider-currency
  total remains valid and is returned; no rate is ever invented.
- Missing FX is never patched with a live call — DB-M16 has no network and no FX
  API surface at all.

---

## 4. Exchange-rate sources

`MANUAL_VERIFIED | CONFIGURED | FUTURE_PROVIDER_SYNC`. No live internet. The seed
rows are **DEV fixtures** (`Notes: "DEV FIXTURE - not a live market rate."`) so a
test/local run never pretends a market rate exists where there is none.

### Seed

| ExchangeRateId | Base | Quote | Rate | Effective | Source |
|---|---|---|---|---|---|
| `fx-usdinr-dev-v1` | USD | INR | 75.0 | [2026-01-01, 2026-06-01) | CONFIGURED |
| `fx-usdinr-dev-v2` | USD | INR | 83.5 | [2026-06-01, open) | CONFIGURED |

---

## 5. Configuration shape

```jsonc
{
  "schemaVersion": 1,
  "currencyDefault": "USD",
  "sourcesAllowed": [ "MANUAL_VERIFIED", "CONFIGURED", "FUTURE_PROVIDER_SYNC" ],
  "records": [
    {
      "ExchangeRateId": "fx-usdinr-dev-v1",
      "BaseCurrency": "USD",
      "QuoteCurrency": "INR",
      "Rate": 75.0,
      "EffectiveAtUtc": "2026-01-01T00:00:00Z",
      "EffectiveToUtc": "2026-06-01T00:00:00Z",
      "Source": "CONFIGURED",
      "VerifiedAtUtc": null,
      "ManualOverride": false,
      "Notes": "DEV FIXTURE - not a live market rate. ..."
    }
  ]
}
```

`Validate-AiExchangeRateCatalogue` rejects duplicate ids, schema != 1, rate ≤ 0,
and **overlapping windows** for the same pair (the root cause of non-reproducible
conversion); gaps are informational.

---

## 6. CostVariance v1

```
AbsoluteVariance   = |Actual − Estimated|
PercentageVariance = (Actual − Estimated) / Estimated × 100   (signed, %)
```

A zero/missing estimate leaves `PercentageVariance` null — division by zero is
never produced. Variance is computed by `New-AiCostVariance` and feeds
DB-M17/DB-M21/DB-M24/DB-M25 without modifying their files.
