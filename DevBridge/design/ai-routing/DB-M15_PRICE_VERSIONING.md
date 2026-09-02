# DB-M15 — Price Versioning

Milestone: **DB-M15 — Pricing Catalogue + Price Versioning** (Lane B1)
Effective-dated pricing history · historic prices never destroyed · zero paid API calls

---

## 1. Model

Every price is a `PricingRecord v1` row with an effective window:

```
[ EffectiveFromUtc , EffectiveToUtc )
```

- `EffectiveFromUtc` **inclusive**.
- `EffectiveToUtc` **exclusive**.
- `EffectiveToUtc = null` means **open-ended** (no end yet).

A *price change* is therefore always two operations that preserve the past:

1. **Close** the predecessor: set its `EffectiveToUtc` to the change boundary `T`.
2. **Add** the successor: a new record with `EffectiveFromUtc = T`.

The window convention means adjacent periods are legal and seamless:

```
v1: [ 2026-08-01, 2026-09-01 )
v2: [ 2026-09-01, 2026-10-01 )
v3: [ 2026-10-01,           )
```

There is no overlap and no gap; a lookup at any instant resolves exactly one
record (`FOUND`).

---

## 2. Guarantees

1. **Historic records are never mutated except to close their effective period.**
   The single permitted mutation is setting a predecessor's `EffectiveToUtc` to
   a successor's `EffectiveFromUtc` (see `Add-AiPriceVersion -ClosePredecessor`).
2. **Historic lookups keep resolving the historic rate.** A lookup at `t` in v1's
   window returns v1's rates, forever — even after v2 and v3 exist.
3. **Overlapping records are rejected, never silently resolved.** Adding a record
   whose window overlaps an existing effective record for the same
   provider/model/tier/time-band throws unless `-ClosePredecessor` is given (and
   then the predecessor must genuinely *precede* the new record — it is never
   allowed to rewrite history).
4. **A price change never destroys the old rate.** The old row stays in the
   catalogue, closed at the boundary, and remains the answer for lookups inside
   its window.
5. **No scraping, no silent overwrite.** Rates change only through this explicit
   versioning path, with auditable `Source` / `VerifiedAtUtc` metadata.

---

## 3. Operations

### 3.1 Current price
```powershell
Get-AiCurrentPrice -Catalogue $pricing -ProviderId 'anthropic' -ModelId 'claude-sonnet-5'
```

### 3.2 Price at an instant (audit / actual-cost input)
```powershell
Get-AiPriceAt -Catalogue $pricing -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' `
              -TimestampUtc '2026-08-31T08:00:00Z'        # PEAK
Get-AiPriceAt -Catalogue $pricing -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' `
              -TimestampUtc '2026-08-31T00:30:00Z'        # OFF_PEAK
```

### 3.3 Introduce a price change (closes the predecessor at the boundary)
```powershell
$newRate = New-AiPricingRecord -PricingRecordId 'ds-v4flash-offpeak-20260915' `
    -ProviderId 'deepseek' -ModelId 'deepseek-v4-flash' `
    -EffectiveFromUtc '2026-09-15T00:00:00Z' -TimeBand 'OFF_PEAK' `
    -InputPricePerMillion 0.25 -CachedInputPricePerMillion 0.008 -OutputPricePerMillion 0.75 `
    -Source 'provider-documentation' -VerifiedAtUtc '2026-09-14T00:00:00Z'
Add-AiPriceVersion -Catalogue $pricing -Record $newRate -ClosePredecessor
```

After this, the old `ds-v4flash-offpeak-20260830` record has
`EffectiveToUtc = 2026-09-15T00:00:00Z` and still answers any lookup before that
instant. Adding the same record **without** `-ClosePredecessor` throws, because
it would overlap the still-open old record.

### 3.4 Validate the whole history
```powershell
Validate-AiPriceHistory -Catalogue $pricing -Providers $providers -Models $models
```
Equivalently `Validate-AiPricingCatalogue`. Reports overlap errors, per-record
errors, unknown references, plus informational gaps and per-status counts.

---

## 4. Lookup states

`Get-AiPriceAt` returns exactly one of:

| State | Meaning | Flags |
|---|---|---|
| `FOUND` | exactly one effective record at the instant | — |
| `NOT_FOUND` | no records for the key, or only future records | `IsFuture`, `NearestUpcomingEffectiveFromUtc` |
| `AMBIGUOUS` | more than one effective record (invalid catalogue); never silently chosen | — |
| `EXPIRED` | price coverage lapsed (historic records exist, none effective now) | `IsExpired`, `HasGap`, `IsFuture`, `NearestUpcomingEffectiveFromUtc` |

A gap between records (`v1` ends, `v2` starts later) is **not** an error — it is
reported by validation (`Gaps`) and surfaces as `EXPIRED` at lookup, an explicit
state the router handles deliberately.

---

## 5. Status classification timeline

For a single record, `Get-AiPricingRecordStatus`:

| Window position | Status |
|---|---|
| `EffectiveToUtc ≤ now` | `EXPIRED` (effective period ended) |
| `now < EffectiveFromUtc` | `NEEDS_REVIEW` (not yet effective) |
| active, `ManualOverride` | `MANUAL_OVERRIDE` |
| active, verified + authoritative source + model resolved | `CURRENT` |
| active, anything else (unverified / non-authoritative source / unresolved model) | `NEEDS_REVIEW` |

---

## 6. Time-band dimension

DeepSeek pricing differentiates `PEAK` vs `OFF_PEAK`:

- peak interval 1 = `[01:00, 04:00) UTC`
- peak interval 2 = `[06:00, 10:00) UTC`
- all other UTC times = `OFF_PEAK`

The band is **derived from the request timestamp in UTC** (`Resolve-AiPricingTimeBand`)
and is independent of where the record is stored. Lookup matches a concrete band
first and falls back to `DEFAULT` when no concrete-band record is effective; an
explicit `-TimeBand` parameter overrides the resolver. Boundary convention
`[start, end)` is enforced by mandatory boundary tests.

---

## 7. Configuration shape

```jsonc
{
  "schemaVersion": 1,
  "currencyDefault": "USD",
  "description": "...",
  "records": [
    {
      "PricingRecordId": "ds-v4flash-offpeak-20260830",
      "ProviderId": "deepseek",
      "ModelId": "deepseek-v4-flash",
      "Currency": "USD",
      "EffectiveFromUtc": "2026-08-30T00:00:00Z",
      "EffectiveToUtc": null,          // open-ended until a successor closes it
      "ProcessingTier": "STANDARD",
      "TimeBand": "OFF_PEAK",
      "InputPricePerMillion": 0.22,
      "CachedInputPricePerMillion": 0.007,
      "OutputPricePerMillion": 0.66,
      "Source": "reference",           // auditable; never scraped
      "VerifiedAtUtc": null,           // unverified -> NEEDS_REVIEW
      "ManualOverride": false,
      "Notes": "..."
    }
  ]
}
```

Unknown / not-applicable price dimensions stay **null** — never faked as zero.

---

## 8. Parallel safety

DB-M15 owns `scripts/ai-routing/AiPricing*.ps1`, `PricingCatalogue.ps1`,
`AiRoutingPricingFoundation.ps1`, `config/pricing/`, and the DB-M15 docs/result.
DB-M14 frozen contracts, DB-M17 attempt/usage records, DB-M12 UI, Lane C
workbook/concurrency artifacts, and the workbook are untouched. Versioning
operations modify only DB-M15-owned catalogue data.
