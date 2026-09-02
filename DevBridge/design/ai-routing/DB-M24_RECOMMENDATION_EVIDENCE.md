# DB-M24 — Recommendation Evidence (non-binding)

Companion to `DB-M24_MODEL_PERFORMANCE.md`. Describes how DB-M24 turns recorded
attempt history into **evidence for** a routing decision — never the decision itself.

---

## 1. The contract

`PerformanceRecommendation v1`:

| Field | Meaning |
|-------|---------|
| `SchemaVersion` | 1 (frozen) |
| `RecommendationType` | one of CHEAPEST_RELIABLE · HIGHEST_SUCCESS · FASTEST · BEST_COST_PER_SUCCESS · INSUFFICIENT_DATA |
| `RecommendedModelId` / `ProviderId` / `UnderlyingModelId` / `GatewayProviderId` | the suggested delivery route (null for INSUFFICIENT_DATA) |
| `Reason` | human-readable non-binding rationale |
| `EvidenceSampleCount` | terminal tasks behind the winner |
| `ConfidenceLevel` | the winner's sample-confidence level |
| `ComparedModels` | every qualifying route with its metrics (transparent comparison) |
| `ExpectedSuccessRate` / `ExpectedFirstAttemptSuccess` / `ExpectedCostPerSuccess` / `ExpectedDuration` | the winner's observed statistics, **not** a promise |
| `PolicyVersion` | **always `'0.0.0'`** — the immutable DB-M14 policy version; recommending never changes routing policy |
| `Warnings` / `GeneratedAtUtc` | exclusions and audit timestamp |

## 2. Non-binding by construction

- `Compare-AiModelPerformance` ranks routes **without picking a winner** — ranking is
  presentation; the decision is DB-M19's, informed by (not dictated by) this evidence.
- `Get-AiPerformanceRecommendation` returns a suggestion with full `ComparedModels`
  and expected-value fields so a caller can disagree.
- A test asserts the routing config hash is **unchanged** after recommendation and
  that `PolicyVersion` stays `'0.0.0'`. Automatic policy learning is out of scope and
  would require a separate governed decision/gate.

## 3. Candidate gating

A route is a candidate only when **all** of:

1. `SampleCount >= 1` (some terminal task).
2. `ConfidenceLevel` is at least the query's `MinimumConfidenceLevel` (default LOW) —
   INSUFFICIENT samples never drive a recommendation.
3. The type-specific metric is available (e.g. cost types need
   `AverageCostPerSuccessfulTask`; FASTEST needs `AverageDurationMs`).

Routes failing the gate are listed in `Warnings`, never silently dropped.

## 4. The five types

| Type | Selects | Notes |
|------|---------|-------|
| `HIGHEST_SUCCESS` | max `SuccessRate` | ties broken by ModelId |
| `FASTEST` | min `AverageDurationMs` | |
| `CHEAPEST_RELIABLE` | min `AverageCostPerSuccessfulTask` **among routes with `SuccessRate >= 0.8`** | reliability floor is explicit; if none reach the floor, falls back to the cheapest candidate and says so via the floor rule (the floor is a documented constant, not a hidden heuristic) |
| `BEST_COST_PER_SUCCESS` | min `AverageCostPerSuccessfulTask` | the default |
| `INSUFFICIENT_DATA` | — | cold start / too-small sample: no recommendation is fabricated |

## 5. Cold start

With no history — or no route meeting the gate — the recommendation is
`INSUFFICIENT_DATA`: `RecommendedModelId` null, `EvidenceSampleCount` = the largest
observed sample, and a warning ("Cold start" / "insufficient qualifying evidence").
DB-M24 never extrapolates from nothing.

## 6. Evidence integrity rules

- Cost evidence is reused from stored DB-M16 fields; estimated cost only under the
  explicit `AllowEstimatedCostFallback` query flag (labelled).
- Historic INR is never re-converted with today's rate; non-reporting-currency
  evidence is excluded with a warning, not silently converted.
- A provider outage does not reduce a model's intellectual-quality score
  (failure categories kept separate).
- No single opaque score; every expected value is a transparent statistic of the
  recorded sample.
