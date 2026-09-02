# DB-M16 — Cost Calculation

Milestone: **DB-M16 — Actual Cost Calculator + Currency Conversion** (Lane B1)
Deterministic estimated/actual cost from the DB-M15 pricing catalogue · zero paid API calls · zero network

---

## 1. Objective

Compute the **estimated** (pre-execution) and **actual** (post-execution) cost of an
AI attempt from its usage, using **only** the effective-dated price records that
already live in the DB-M15 pricing catalogue. DB-M16 never executes a provider,
never makes an AI/paid call, and never touches the network or FX APIs.

**Source price rule (hard):** every rate is read through the DB-M15 catalogue
(`Get-AiPriceAt` / `Get-AiPricingRecord`). No rate is embedded in DB-M16 code or
config.

---

## 2. Pipeline

```
CostCalculationInput v1
        │  UsageSource = ESTIMATED | PROVIDER_REPORTED
        ▼
Calculate-AiAttemptCost
  1. validate input                      -> INVALID_USAGE
  2. Get-AiPriceForCost (DB-M15)         -> PRICE_NOT_FOUND / PRICE_AMBIGUOUS
  3. select usage (estimated | actual)
  4. cached/uncached split
  5. per-dimension costs ([decimal])
  6. Subtotal -> ProviderCurrencyTotal   (AdditionalMultiplier, MinimumCharge)
  7. currency conversion                 -> CURRENCY_CONVERSION_UNAVAILABLE
  8. status precedence
        ▼
CostCalculationResult v1
```

---

## 3. CostCalculationInput v1

`schemaVersion` 1. All token/unit dimensions are **nullable** — unknown stays
`null`, and is never silently treated as zero.

| Field | Meaning |
|---|---|
| `TaskId`, `AttemptId` | identity (DB-M14 frozen contracts; passes through to DB-M17) |
| `ProviderId`, `ModelId` | lookup key (normalized lowercase) |
| `RequestTimestampUtc` | when the attempt ran — **the** instant for price and FX resolution |
| `ProcessingTier`, `TimeBand` | tier (STANDARD/BATCH/FLEX); band overrides the resolver when set |
| Actual dims | `InputTokens`, `CachedInputTokens`, `UncachedInputTokens`, `CacheWrite5mTokens`, `CacheWrite1hTokens`, `OutputTokens`, `ReasoningTokens`, `ToolCalls`, `Images`, `AudioUnits`, `StorageUnits` |
| Estimated dims | `EstimatedInputTokens`, `EstimatedCachedInputTokens`, `EstimatedOutputTokens` |
| `CurrencyTarget` | ISO-4217 currency to report the converted total in (e.g. `INR`) |
| `ExchangeRate` | authorized caller-supplied rate override (must be > 0); bypasses FX lookup |
| `PricingRecordIdOverride` | authorized exact-record override; verified to match provider/model |
| `UsageSource` | `PROVIDER_REPORTED` -> ACTUAL; anything else -> ESTIMATED |

Validation: provider/model required, timestamp parseable, tier/band in vocabulary,
negative token/unit counts rejected, `CachedInputTokens > InputTokens` rejected,
FX rate > 0, currency 3-letter, override id format, secret-value guard.

---

## 4. Price resolution (DB-M15 reuse)

`Get-AiPriceForCost` wraps `Get-AiPriceAt`:

- Keyed on provider / model / request timestamp / processing tier / time band.
- **Only `FOUND` is usable.** `NOT_FOUND`/`EXPIRED` -> `PRICE_NOT_FOUND`;
  `AMBIGUOUS` -> `PRICE_AMBIGUOUS`. An `EXPIRED` state is never reinterpreted as a
  "current" rate for a historic request.
- `PricingRecordIdOverride` uses that exact record and **verifies** it matches the
  requested provider/model before accepting it.

The resolved record carries the pricing currency (USD in the seed), every rate
dimension, and `AdditionalMultiplier`/`MinimumCharge`.

---

## 5. Token-cost formula

```
cost = tokens / 1,000,000 × pricePerMillion
```

Implemented with `[decimal]` arithmetic in `ConvertTo-AiTokenCost` (no
floating-point drift). `$null` either side -> `$null` (unknown); an explicit `0`
token count -> `0`.

---

## 6. Cached vs uncached input

- Uncached = `InputTokens − CachedInputTokens`, **unless** the source reports
  `UncachedInputTokens` explicitly.
- `CachedInputTokens ≤ InputTokens` is validated up front; there is no double
  charge (the input total is never billed twice — only the split is billed).
- Cache write (5m / 1h) and cache read are distinct dimensions from the DB-M15
  record; each is charged only when both usage and price are non-null.

---

## 7. Output / reasoning / tool / media / storage

- **Output** is charged from `OutputPricePerMillion`.
- **Reasoning** is config-driven (`ReasoningTokenBilling` in
  `config/cost/cost-calculator.json`), never inferred from a provider name:
  - `INCLUDED_IN_OUTPUT` (default): reasoning is covered by output; charging
    reasoning separately would be a double charge — `ReasoningCost` stays null.
  - `SEPARATE`: reasoning is charged from
    `ReasoningTokenPricePerMillion` on the resolved record.
- **Tool / image / audio / storage** are optional non-token charges
  (`ToolCallPrice`, `ImagePrice`, `AudioPrice`, `StoragePrice`). If a dimension
  reports non-zero usage but the record has no rate, the cost is **not silently
  zeroed** — the calculation becomes `PARTIAL` with a warning naming the missing
  dimension.
- All non-token charges roll into `OtherCost` (tool call is reported separately
  as `ToolCallCost`).

---

## 8. Estimated vs actual

`UsageSource` decides the branch — **never** the caller's wording or a provider
name:

| UsageSource | Dimensions used | EstimatedOrActual |
|---|---|---|
| `PROVIDER_REPORTED` | actual dims | `ACTUAL` |
| anything else / null | estimated dims | `ESTIMATED` |

The result carries both `EstimatedCost`/`ActualCost` (populated according to the
mode) plus `CostCurrency`, so DB-M17 can persist them under the frozen DB-M14
attempt contract without touching DB-M17's schema.

---

## 9. Calculation status

Precedence (highest first):

1. `INVALID_USAGE` — input failed validation
2. `PRICE_NOT_FOUND` / `PRICE_AMBIGUOUS` — no usable price record
3. `USAGE_INCOMPLETE` — price resolved but no usage dimensions at all
4. `PARTIAL` — a billable dimension is missing a rate (warning names it)
5. `CURRENCY_CONVERSION_UNAVAILABLE` — provider-currency cost is valid but no
   exchange-rate evidence (provider total still returned)
6. `COMPLETE` — everything priced and converted

`Warnings` carries the human detail for every non-fatal condition.

---

## 10. Schema / parallel safety

- Frozen v1: `CostCalculationInput`, `CostCalculationResult`, `ExchangeRateRecord`,
  `CostVariance`. Incompatible change -> v2.
- Versions registered in `Get-AiCostSchemaVersions` (DB-M16-owned), so DB-M14 and
  DB-M15 files remain byte-identical.
- DB-M16 owns `AiCostContracts.ps1`, `AiExchangeRates.ps1`, `CostCalculator.ps1`,
  `AiRoutingCostFoundation.ps1`, `config/currency/`, `config/cost/`, and this
  milestone's docs/result. DB-M15 pricing files are read-only; DB-M17/DB-M12/Lane C
  files are untouched.
