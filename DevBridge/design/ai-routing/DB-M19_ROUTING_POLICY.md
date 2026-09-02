# DB-M19 — Routing Policy (RoutingPolicy v1)

**Milestone:** DB-M19 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

A `RoutingPolicy v1` is **pure configuration data** that drives STEP 5 of the DB-M19 router. The
ranking engine reads **every** weight, threshold and tie-breaker from the policy object — no policy
weight or threshold is hard-coded in routing logic. ADR-005 applies: nothing in a policy or its
evaluation branches on a provider/model name.

Companion: `DB-M19_MODEL_ROUTER.md`.

---

## 1. Objectives

| Objective | Meaning |
|---|---|
| `CHEAPEST_ELIGIBLE` | Lowest estimated attempt cost among eligible candidates |
| `CHEAPEST_RELIABLE` | Conservative default (see §4): satisfy hard requirements + minimum reliability, prefer sufficient historical confidence, compare estimated current-attempt cost, consider verified cost-per-success when reliable |
| `BEST_COST_PER_SUCCESS` | Minimize verified cost-per-success (requires reliable evidence) |
| `HIGHEST_SUCCESS` | Highest verified success rate; a self-reported PASS that failed independent verification does NOT count |
| `FASTEST_RELIABLE` | Fastest among reliable candidates |
| `BALANCED` | Weighted multi-objective combination |
| `MANUAL` | Present candidates; never auto-select (the winner stays `$null`) |

## 2. Rejection vocabulary (17 members)

The STEP-1 hard eligibility filter returns structured reasons — vocabulary members, never free text —
each accompanied by a human-readable detail:

```
MODEL_DISABLED                      PROVIDER_DISABLED                  PROVIDER_UNAVAILABLE
CAPABILITY_CODING_MISSING           CAPABILITY_VISION_MISSING          CAPABILITY_TOOL_USE_MISSING
STRUCTURED_OUTPUT_MISSING           REASONING_LEVEL_INSUFFICIENT       CONTEXT_TOO_SMALL
OUTPUT_LIMIT_TOO_SMALL              RELIABILITY_TOO_LOW                PROVIDER_DISALLOWED
MODEL_DISALLOWED                    LOCALITY_CONFLICT                  BUDGET_EXCEEDED
PRICE_UNAVAILABLE                   PROCESSING_TIER_UNSUPPORTED
```

## 3. Policy schema (v1)

| Field | Type | Notes |
|---|---|---|
| `SchemaVersion` | int | `1` |
| `PolicyId` | string | required; trimmed |
| `Name` | string | defaults to `PolicyId` |
| `Objective` | string | one of §1; required |
| `Enabled` | bool | disabled policies refuse to route |
| `Weights` | object | see §3.1 |
| `Thresholds` | object | see §3.2 |
| `TieBreaker` | string[] | deterministic tie-break chain (see §3.3); required non-empty |
| `MinimumConfidenceForHistoricalWeight` | string | `INSUFFICIENT`/`LOW`/`MODERATE`/`HIGH` (DB-M24 vocabulary) |
| `Notes` | string | optional |

### 3.1 Weights (each `0..1`; missing = excluded from the score)

`cost` · `success` · `firstAttemptSuccess` · `costPerSuccess` · `latency` · `reliability`

A policy must declare at least one non-zero weight. The score is:

```
PolicyScore = Σ( weight_i × component_i )   over declared non-zero weights
```

where the components are the **explained, per-candidate scores**:

| Component | Formula |
|---|---|
| `cost` | `1 − EstimatedCost / MaxKnownCost` (0 if unknown) |
| `success` | verified `SuccessRate` when historical confidence is sufficient, else `0` |
| `firstAttemptSuccess` | verified `FirstAttemptSuccessRate` when sufficient, else `0` |
| `costPerSuccess` | `1 − AverageCostPerSuccessfulTask / MaxKnownCps` when sufficient, else `0` |
| `latency` | `RelativeSpeed → 0..1` (`VERY_FAST=1.0, FAST=0.75, NORMAL=0.5, SLOW=0.25`; unknown = 0) |
| `reliability` | `ReliabilityClass → 0..1` (`CRITICAL_GRADE=1.0, HIGH=0.75, STANDARD=0.5, EXPERIMENTAL=0.25`; unknown = 0, conservative) |

`MaxKnownCost` and `MaxKnownCps` are set-level references computed over the eligible candidate set
(deterministically sorted), so scores are comparable within one request. Historical components are
**zeroed** when evidence confidence is below `MinimumConfidenceForHistoricalWeight` (INSUFFICIENT
evidence has little/no ranking power).

### 3.2 Thresholds

| Threshold | Default | Meaning |
|---|---|---|
| `minimumReliability` | `$null` (no gate) | candidate below this reliability score is not selectable |
| `reasoningReserveTokens` | `0` | extra token reserve subtracted from `ContextWindow` in STEP 2 |
| `allowCostUnknown` | `$true` | when `$false`, an unknown-cost candidate is not selectable (`NO_ELIGIBLE_MODEL_PRICE` if none remain) |
| `requireConfirmedProviderHealth` | `$false` | when `$true`, a provider whose health is not confirmed `AVAILABLE` (e.g. `UNKNOWN`) is treated as unavailable |

### 3.3 Tie-breakers

Declared tie-break chain applied in order after `PolicyScore` (descending). Supported members:
`PolicyScore` (primary key, always first), `EstimatedCost` (ascending), `ReliabilityClass`
(descending), `ModelId` (ascending), `SampleCount` (descending). Missing costs sort last; every sort
is stable and deterministic.

## 4. Default ASSISTED policy — CHEAPEST_RELIABLE

`routing-policy-cheapest-reliable-v1` (the DB-M19 default):

| Field | Value |
|---|---|
| `Objective` | `CHEAPEST_RELIABLE` |
| `Weights` | `cost = 0.45` · `success = 0.10` · `firstAttemptSuccess = 0.05` · `costPerSuccess = 0.30` · `latency = 0.0` · `reliability = 0.10` |
| `Thresholds` | `minimumReliability = 0.7` · `reasoningReserveTokens = 0` · `allowCostUnknown = $true` · `requireConfirmedProviderHealth = $false` |
| `TieBreaker` | `PolicyScore, EstimatedCost, ReliabilityClass, ModelId` |
| `MinimumConfidenceForHistoricalWeight` | `LOW` (≥ 5 samples) |

Design intent: conservative by default. It satisfies the hard capability/context/output/budget
constraints, prefers candidates with sufficient historical confidence, compares estimated current-attempt
cost, and weights verified cost-per-success (so a cheap-but-failure-prone route that needs retries ranks
below a slightly-more-expensive high-success route). The absolute cheapest model wins only when cost and
reliability evidence do not argue otherwise.

## 5. Confidence model (DB-M24 bands, used for ranking weight)

| Band | Samples | Ranking power |
|---|---|---|
| `INSUFFICIENT` | 0–4 | historical components zeroed (cold start / too few) |
| `LOW` | 5–19 | history weighted (default policy threshold) |
| `MODERATE` | 20–49 | history weighted |
| `HIGH` | 50+ | history weighted |

Evidence is **non-binding**: confidence never rejects a model, it only decides how much the history
influences ranking.

## 6. Selectability vs. eligibility

- **Eligibility** (STEP 1–3): hard capability/provider/price/context/budget gates. A rejected route is
  excluded outright with structured reasons.
- **Selectability** (STEP 5): policy-threshold gate — a candidate is selectable only if its
  reliability score meets `minimumReliability` and, when `allowCostUnknown = $false`, its cost is known.
  An eligible-but-not-selectable candidate keeps its score/rank `$null` but is still listed with its
  component scores in the evidence.

## 7. Determinism

Ranking is deterministic: candidates are sorted before computing set-level references, the score is a
pure arithmetic function of the candidate + set references, and equal scores are broken by the declared
tie-breaker chain. No randomness, no wall-clock-dependent ordering, no provider/model name comparisons.
