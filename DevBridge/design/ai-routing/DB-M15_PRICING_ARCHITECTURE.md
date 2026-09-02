# DB-M15 — Pricing Catalogue Architecture

Milestone: **DB-M15 — Pricing Catalogue + Price Versioning** (Lane B1)
Status: **Implemented** · Effective-dated reference catalogue · zero paid API calls
Depends on: DB-M13 discovery, DB-M14 provider/model contracts (frozen v1)
Follows: DB-M16 (actual-cost + USD→INR) · DB-M17 (attempt/usage history) · DB-M19 (routing decisions)

---

## 1. Scope

DB-M15 OWNS:

- the pricing domain model and configuration,
- price versioning / effective-dated history,
- deterministic price lookup (`Get-AiPriceAt` / `Get-AiCurrentPrice`),
- provider/model pricing profiles (processing tiers, time bands),
- price verification metadata and status classification.

DB-M15 does **NOT** own (and does not touch):

- task/attempt cost calculation — **DB-M16 owns actual cost and USD→INR conversion**;
- attempt/usage history records and usage recording — **DB-M17 owns those**;
- the Operator UI (.NET `src/DevBridge.*`) — DB-M12;
- the workbook or Nexus.Developer — never modified by DB-M15.

---

## 2. Design principles

1. **Rates are data, never code.** Numeric prices live only in
   `config/pricing/pricing-catalogue.json` and are consumed exclusively through
   catalogue lookup functions. No pricing constant is hard-coded in any
   PowerShell routing logic, and no provider-name branching exists outside the
   pricing subsystem (ADR-005).
2. **Effective-dated and immutable.** Every rate is a row in `[EffectiveFromUtc,
   EffectiveToUtc)` — from-inclusive, to-exclusive, null to = open-ended.
   Historic rows are never rewritten; a price change closes the old row's
   EffectiveToUtc at the change boundary and adds a new row from that boundary.
3. **Deterministic and timezone-independent.** Lookups resolve instants against
   UTC. All datetime strings are normalized to `Kind=Utc` via `ConvertTo-AiUtc`
   before any comparison, so results are identical on any host timezone. When a
   request timestamp is available it is used; `[datetime]::UtcNow` is used only
   as an explicit fallback, never local system time.
4. **Provider/model independent.** The catalogue stores plain `ProviderId` /
   `ModelId` keys and cross-validates them against the DB-M14 catalogues. No
   provider is special-cased in lookup or validation.
5. **No guessing, no silent overwrite.** Reference figures are seeded with
   `Source = 'reference'` and no `VerifiedAtUtc`, so every seed record classifies
   `NEEDS_REVIEW` until verified against provider documentation. Rates are never
   scraped and never silently overwritten.
6. **Zero network / zero paid calls.** No `Invoke-RestMethod`, `WebRequest`,
   `HttpClient`, or any network/HTTP call exists anywhere in the DB-M15
   libraries (asserted by the test suite).

---

## 3. Domain model

### PricingRecord v1

| Field | Meaning |
|---|---|
| `PricingRecordId` | unique, `^[A-Za-z0-9._\-]{1,120}$` |
| `ProviderId`, `ModelId` | lower-cased keys; cross-checked against DB-M14 catalogues |
| `Currency` | ISO-4217, uppercase (seed: USD) |
| `EffectiveFromUtc` / `EffectiveToUtc` | `[from, to)` window; null to = open-ended |
| `ProcessingTier` | `STANDARD \| BATCH \| FLEX \| PRIORITY` |
| `TimeBand` | `DEFAULT \| PEAK \| OFF_PEAK` |
| `InputPricePerMillion` | uncached input, USD per 1,000,000 tokens |
| `CachedInputPricePerMillion` | cache-hit / cached input |
| `CacheWrite5mPricePerMillion` | 5-minute cache write |
| `CacheWrite1hPricePerMillion` | 1-hour cache write |
| `OutputPricePerMillion` | output tokens |
| `ReasoningTokenPricePerMillion`, `ToolCallPrice`, `ImagePrice`, `AudioPrice`, `StoragePrice` | extended dimensions; **null when unknown/not applicable** (never faked as 0) |
| `AdditionalMultiplier`, `MinimumCharge` | modifier / floor |
| `Source` | `provider-documentation \| manual-verified \| sync-proposal \| reference` |
| `VerifiedAtUtc`, `ManualOverride`, `Notes` | verification metadata |
| `SchemaVersion` | **1** (frozen) |
| `ModelResolved`, `ProviderResolved` | computed during import/validation (not persisted) |

### Price status (calculated)

`CURRENT | NEEDS_REVIEW | EXPIRED | MANUAL_OVERRIDE`, precedence:

```
EXPIRED (effective period ended) → NEEDS_REVIEW (not yet effective)
→ active: MANUAL_OVERRIDE > NEEDS_REVIEW > CURRENT
```

`CURRENT` additionally requires: `VerifiedAtUtc` present **and**
`Source ∈ {provider-documentation, manual-verified}` **and**
`ModelResolved -ne $false`.

### Vocabularies

- TimeBands: `DEFAULT | PEAK | OFF_PEAK`
- ProcessingTiers: `STANDARD | BATCH | FLEX | PRIORITY`
- Sources: `provider-documentation | manual-verified | sync-proposal | reference`
- Statuses: `CURRENT | NEEDS_REVIEW | EXPIRED | MANUAL_OVERRIDE`
- LookupStates: `FOUND | NOT_FOUND | AMBIGUOUS | EXPIRED`

---

## 4. File layout (DB-M15 owned)

```
scripts/ai-routing/
  AiPricingContracts.ps1        contracts: record, lookup result, vocab, status,
                                validation, secret-leak guard, ConvertTo-AiUtc
  AiPricingTimeBands.ps1        time-band resolution (provider rules ISOLATED here)
  PricingCatalogue.ps1          catalogue ops, Add-AiPriceVersion, Get-AiPriceAt,
                                Validate-AiPricingCatalogue/Validate-AiPriceHistory
  AiRoutingPricingFoundation.ps1 aggregator: dot-sources DB-M14 foundation +
                                the three pricing libs; Import-AiPricingConfiguration,
                                Validate-AiPricingFoundation
  Test-AiPricingCatalogue.ps1   DB-M15 assertion suite (71 assertions)
config/pricing/
  pricing-catalogue.json        seed reference catalogue (schemaVersion 1)
design/ai-routing/
  DB-M15_PRICING_ARCHITECTURE.md   (this file)
  DB-M15_PRICE_VERSIONING.md       versioning + operational guide
state/
  db-m15-result.json               milestone result
```

Dot-source chain (aggregator dot-sources DB-M14 files read-only):

```
AiRoutingContracts.ps1 ──► AiProvider.ps1 ──► ModelCatalogue.ps1 ──► AiRoutingFoundation.ps1
AiPricingContracts.ps1 ──► AiPricingTimeBands.ps1 ──► PricingCatalogue.ps1
AiRoutingPricingFoundation.ps1  (dot-sources all of the above)
```

Schema versions for DB-M15 v1 contracts are registered in
`Get-AiPricingSchemaVersions` — **not** in DB-M14's `Get-AiRoutingSchemaVersions`
— so the frozen DB-M14 files stay byte-identical.

---

## 5. Time-band resolution (isolated)

`Resolve-AiPricingTimeBand -ProviderId <id> -TimestampUtc <UTC>`:

- **DeepSeek** (only provider with time-differentiated pricing today):
  - peak interval 1 = `[01:00, 04:00) UTC`
  - peak interval 2 = `[06:00, 10:00) UTC`
  - everything else = `OFF_PEAK`
- **Every other provider** = `DEFAULT`.

Boundary convention is deterministic and documented: a timestamp exactly at a
peak *start* is PEAK; exactly at a peak *end* is OFF_PEAK (interval `[start, end)`).
Boundary tests are mandatory and enforced in the suite (section A).

Time-band determination is **separated from price storage**; provider-specific
rules live only in `AiPricingTimeBands.ps1`, keeping general business logic free
of provider-name branching.

---

## 6. Deterministic price lookup

`Get-AiPriceAt -Catalogue <catalogue> -ProviderId <id> -ModelId <id>
-TimestampUtc <UTC> [-ProcessingTier <tier>] [-TimeBand <band>]`

Algorithm (deterministic, exactly-one-record semantics):

1. Normalize timestamp to UTC (`ConvertTo-AiUtc`), keys to lower-case, tier to
   upper-case.
2. Resolve band: explicit `-TimeBand` wins; else provider resolver at the UTC
   timestamp.
3. Collect `keyRecords` = records matching provider/model/tier.
4. Filter `effective` = records with `EffectiveFromUtc ≤ ts < EffectiveToUtc`
   (null end = open).
5. Band precedence: a concrete band (`PEAK`/`OFF_PEAK`) wins over `DEFAULT`;
   `DEFAULT` is the fallback when no concrete-band record is effective.
6. Classify:
   - exactly one effective match → **FOUND**
   - more than one → **AMBIGUOUS** (never silently chooses between records)
   - none effective, no key records → **NOT_FOUND**
   - none effective, historic records lapsed → **EXPIRED** (`IsExpired`; sets
     `HasGap`/`IsFuture`/`NearestUpcomingEffectiveFromUtc` when relevant)
   - none effective, only future records → **NOT_FOUND** + `IsFuture`.

`Get-AiCurrentPrice` is the same lookup with an explicit `[datetime]::UtcNow`.

`PriceLookupResult v1` carries `LookupState`, `MatchedRecords`, `Record`, `Status`,
`IsExpired`, `IsFuture`, `HasGap`, `NearestUpcomingEffectiveFromUtc`, `Message`.

---

## 7. Versioning model

See [`DB-M15_PRICE_VERSIONING.md`](DB-M15_PRICE_VERSIONING.md) for the full model.
Conceptually equivalent to the brief's `GetPriceAt / GetCurrentPrice /
AddPriceVersion / ValidatePriceHistory`:

| Brief concept | DB-M15 implementation |
|---|---|
| GetPriceAt | `Get-AiPriceAt` |
| GetCurrentPrice | `Get-AiCurrentPrice` |
| AddPriceVersion | `Add-AiPriceVersion [-ClosePredecessor]` |
| ValidatePriceHistory | `Validate-AiPriceHistory` (= `Validate-AiPricingCatalogue`) |

---

## 8. Validation

`Validate-AiPricingCatalogue -Catalogue <catalog> -Providers <catalog>
-Models <catalog>` returns `{ Valid; Errors; Warnings; Gaps; Overlaps;
StatusCounts; Records }`:

- **Errors** (invalid): catalogue null; catalogue-key/PricingRecordId mismatch;
  per-record validation failures; unknown provider reference; negative price;
  overlapping effective periods for the same provider/model/tier/time-band.
- **Warnings** (reviewable, not blocking): unknown model reference
  (record flagged `NEEDS_REVIEW` — "mark for review, don't guess");
  non-recommended source.
- **Info**: gaps between effective periods (a gap produces an `EXPIRED` lookup —
  a legitimate, explicit state), per-status counts.

Single-record validation (`Test-AiPricingRecord`): id format + uniqueness (at
catalogue level), schemaVersion 1, currency format, `EffectiveFrom <
EffectiveTo`, tier/band vocabulary, every present price dimension `≥ 0`, source
vocabulary (warning), parseable `VerifiedAtUtc`, and the pricing secret-leak
guard.

---

## 9. Seed reference catalogue

`config/pricing/pricing-catalogue.json` seeds 10 effective-dated records, all
`Source = 'reference'`, `VerifiedAtUtc = null`, `EffectiveFromUtc =
2026-08-30T00:00:00Z`, open-ended except Gemini (closed `2027-01-01T00:00:00Z`).
All amounts USD per 1,000,000 tokens:

| Record | Provider | Model | Tier | Band | Input / CachedInput / Output (…cache-write) |
|---|---|---|---|---|---|
| ds-v4flash-offpeak | deepseek | deepseek-v4-flash | STANDARD | OFF_PEAK | 0.22 / 0.007 / 0.66 |
| ds-v4flash-peak | deepseek | deepseek-v4-flash | STANDARD | PEAK | 0.44 / 0.014 / 1.32 |
| ds-v4pro-offpeak | deepseek | deepseek-v4-pro | STANDARD | OFF_PEAK | 0.66 / 0.022 / 1.98 |
| ds-v4pro-peak | deepseek | deepseek-v4-pro | STANDARD | PEAK | 1.32 / 0.044 / 3.96 |
| sonnet-5 standard | anthropic | claude-sonnet-5 | STANDARD | DEFAULT | 2.0 / 0.2 / 10.0, cache-write 2.5/4.0 |
| sonnet-5 batch | anthropic | claude-sonnet-5 | BATCH | DEFAULT | 1.0 / 0.1 / 5.0, cache-write 1.25/2.0 |
| haiku-4.5 standard | anthropic | claude-haiku-4-5 | STANDARD | DEFAULT | 1.0 / 0.1 / 5.0, cache-write 1.25/2.0 |
| gpt-5.4-nano | openai | gpt-5.4-nano | STANDARD | DEFAULT | 0.2 / 0.02 / 1.25 |
| gpt-5.4 | openai | gpt-5.4 | STANDARD | DEFAULT | 2.5 / 0.25 / 15.0 |
| gemini economical | gemini | gemini-economical | FLEX | DEFAULT | 0.375 / 0.0375 / 1.875, through 2026-12-31 |

Notes on the seed:

- **Batch** discounts are separate `BATCH`-tier records; the `STANDARD` rates are
  not overwritten. Batch percentages are assumed and flagged `NEEDS_REVIEW`.
- `deepseek-v4-pro`, `gpt-5.4-nano`, `gpt-5.4`, and `gemini-economical` are not
  yet in the DB-M14 model catalogue → records reference models that resolve
  `false`, surface as **warnings** (not errors), and classify `NEEDS_REVIEW` —
  the brief's "mark as requiring review rather than guessing".
- The Gemini economical profile is **not** assumed to apply to every Gemini
  model: it is a single profile record tied to a placeholder model id, flagged
  for association with the real model when catalogued.
- StatusCounts for the seed: `CURRENT=0 NEEDS_REVIEW=10 EXPIRED=0
  MANUAL_OVERRIDE=0` — correct for unverified reference data.

---

## 10. Schema freeze

- `PricingRecord` schemaVersion **1**
- `PriceLookupResult` schemaVersion **1**
- `PricingCatalogue` schemaVersion **1**

Any future incompatible change must introduce a new version; v1 semantics are
never silently mutated.

---

## 11. Parallel safety

- DB-M14 files (`AiRoutingContracts.ps1`, `AiProvider.ps1`,
  `ModelCatalogue.ps1`, `AiRoutingFoundation.ps1`) are dot-sourced read-only and
  remain byte-identical; DB-M15 schema versions live in DB-M15's own registry.
- DB-M17 files (`AttemptStore.ps1`, `Test-AttemptStore.ps1`, `state/attempts/`)
  are untouched by DB-M15.
- DB-M12 `src/DevBridge.*`, Lane C workbook/concurrency artifacts, and the
  workbook itself are untouched by DB-M15.
- Collision check re-run at milestone end: no overlap on DB-M15-owned files.

---

## 12. Tests

`scripts/ai-routing/Test-AiPricingCatalogue.ps1` — 71 assertions, zero paid API
calls, zero network calls, zero credentials read. Covers: DeepSeek peak/off-peak
and **boundary** resolution; record construction + validation; effective-dated
versioning with historic preservation; `FOUND/NOT_FOUND/AMBIGUOUS/EXPIRED`
states; gaps; overlap rejection; band precedence + DEFAULT fallback;
cached/uncached/output/cache-write dimensions; unknown-dimension null; manual
override; source metadata; status classification; serialization round-trip;
schema v1; unknown provider (error) / unknown model (warning); seed catalogue
import + lookups; no-network scan of the DB-M15 libraries.
