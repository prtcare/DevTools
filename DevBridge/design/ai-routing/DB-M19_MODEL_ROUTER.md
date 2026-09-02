# DB-M19 — Capability-Based Model Router

**Milestone:** DB-M19 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M19 is the **capability-based model router**: given a TaskClassification + CapabilityRequirement
(DB-M18), a ContextBudget/ContextPackage (DB-M18), the model catalogue + pricing (DB-M14/DB-M15),
the cost engine (DB-M16) and historical performance evidence (DB-M24), the router produces a
**transparent, recommendation-only model selection** — never an execution.

**THE ROUTER SELECTS / RECOMMENDS A MODEL AND DOES NOT EXECUTE IT.** No provider API call, no
automatic DeepSeek/Claude/ChatGPT invocation, no automatic workflow advancement. Routing is
**capability-based, never provider/model-name-based** (ADR-005): every branch reads a capability,
a price, a context figure, a reliability class, or a policy weight — no code path compares against a
provider/model literal.

Companion: `DB-M19_ROUTING_POLICY.md` (RoutingPolicy v1, the default CHEAPEST_RELIABLE policy, the
17-member rejection vocabulary, the ranking weight model). The evidence/cost/performance engines are
owned by earlier milestones: DB-M14 (contracts), DB-M15 (price versioning), DB-M16 (cost), DB-M17
(attempt history), DB-M24 (performance + recommendation evidence).

---

## 1. Hard constraints honored

| Constraint | Status |
|---|---|
| **Selects/recommends only; never executes** | **YES** — `Get-AiRoutingRecommendation` returns a decision + evidence; no model is invoked; the recommendation markdown states "nothing was executed" |
| AUTO execution | **PROHIBITED** — an `ExecutionMode=AUTO` request is refused with status `AUTO_EXECUTION_PROHIBITED` (tested) |
| No paid API calls / no network / no model execution | **YES** — the library makes zero web calls; the test suite runs offline (0 paid calls, 0 network calls) |
| Capability-based routing (ADR-005) | **YES** — S19 test greps the router sources for provider/model name branching |
| STEP 1 hard eligibility with the 17-item rejection vocabulary | **YES** — `Get-EligibleAiModels` + `Test-AiModelCapabilityFit`; reasons are vocabulary members, never free text |
| Model health from configured state only | **YES** — provider health is supplied state (`AVAILABLE`/`UNAVAILABLE`/`DISABLED`/`AUTH_ERROR`/`RATE_LIMITED`/`DEGRADED`/`UNKNOWN`); **no network health probe**; `UNKNOWN` is not silently healthy when the policy requires confirmed availability |
| STEP 2 context fit (mandatory + output/reasoning reserve) → `NO_ELIGIBLE_MODEL_CONTEXT` | **YES** — `Test-AiRoutingContextFit`; `UsableContext = ContextWindow − (ExpectedOutputTokens + reasoningReserveTokens)`; mandatory context is never truncated |
| STEP 3 cost via the DB-M16 engine (no duplicate math) | **YES** — `Get-AiCandidateCostEstimate` builds a DB-M16 `CostCalculationInput` and calls `Calculate-AiAttemptCost`; unknown price → `COST_UNKNOWN` label |
| STEP 4 historical performance via DB-M24, NON-BINDING | **YES** — `Get-AiCandidatePerformanceEvidence` (VERIFIED_PREFERRED); INSUFFICIENT confidence → little/no ranking power |
| STEP 5 policy ranking from the RoutingPolicy object | **YES** — `Rank-AiRoutingCandidates` reads every weight/threshold/tie-breaker from the policy; default policy CHEAPEST_RELIABLE; no hard-coded weights |
| Explainable scores (never opaque "Score=83.7") | **YES** — every candidate carries `ComponentScores` (cost/success/firstAttemptSuccess/costPerSuccess/latency/reliability) and the recommendation reason lists them |
| Reasoning level = minimum normalized, never auto-MAX | **YES** — `Get-DbM19SelectedReasoningLevel` picks the lowest supported level satisfying the requirement |
| Manual override must still satisfy hard constraints | **YES** — `Test-AiManualOverride` accepts only eligible routes; ineligible override → rejected with explanation |
| Budget: request-level `MaxAllowedCost` only | **YES** — `BUDGET_EXCEEDED` at request level; no daily/monthly budget concepts |
| DB-M14 shared contracts unchanged | **YES** — `AiRoutingContracts.ps1` read-only; `RoutingDecision` stays DB-M14 v1; the DB-M19 companion `RoutingDecisionEvidence v1` is DB-M19-owned |
| Manual workflow preserved (DevBridge → ChatGPT → DeepSeek → DB-M06 verification → Claude) | **YES** — `Export-AiRoutingRecommendation` never writes `CHATGPT_HANDOFF.md` / `DEEPSEEK_PROMPT.md` / `CLAUDE_REVIEW_PROMPT.md`; `MANUAL` mode presents candidates without selecting |
| Parallel-safety | **YES** — DB-M18/24/16/17/15/12 files byte-identical; `Nexus.Developer` and `NEXUS_DEVELOPMENT_CONTROL.xlsx` untouched; DB-M19 files live only under `scripts\ai-routing\router\` + `design\ai-routing\` + `state\db-m19-result.json` |
| Schema freeze | **YES** — RoutingPolicy v1, RoutingCandidate v1, RoutingDecisionEvidence v1, RoutingRequest v1 frozen here; DB-M14 `RoutingDecision` stays v1 |

## 2. Pipeline

```
RoutingRequest v1 (TaskId + CapabilityRequirement + Classification +
                 ContextBudget/ContextPackage + MaxAllowedCost + ExecutionMode + timestamp)
        │
        ▼
STEP 1  Get-EligibleAiModels       hard capability/provider/price eligibility
        ▼                           (17-item rejection vocabulary; health from state)
STEP 2  Test-AiRoutingContextFit   UsableContext = ContextWindow − (output + reserve)
        ▼
STEP 3  Get-AiCandidateCostEstimate  cost via the DB-M16 engine (never re-implemented)
        ▼
STEP 4  Get-AiCandidatePerformanceEvidence  historical evidence via DB-M24 (NON-BINDING)
        ▼
STEP 5  Rank-AiRoutingCandidates   policy-weighted score + deterministic tie-breakers
        ▼
        DB-M14 RoutingDecision v1 + DB-M19 RoutingDecisionEvidence v1
        (status + winner + eligible/rejected candidates + transparent reason)
```

Every step is deterministic and zero-network. The request is validated (`Test-RoutingRequest`), the
policy is validated (`Test-RoutingPolicy`), and AUTO mode is refused before any eligibility work.

### Execution modes

| Mode | Behaviour |
|---|---|
| `MANUAL` | The router displays eligible choices; the winner field stays `$null`, status = `MANUAL_MODE`. A human override is the only path and it must still pass the hard constraints. The DevBridge → ChatGPT → DeepSeek → verification → Claude loop is unchanged. |
| `ASSISTED` | The router produces a policy-driven recommendation (model, minimum reasoning level, estimated cost, reason, evidence) and never runs it. Status = `RECOMMENDED`. |
| `AUTO` | **Prohibited.** Refused with status `AUTO_EXECUTION_PROHIBITED`; no model is selected or invoked. |

### Outcome statuses

`RECOMMENDED` · `MANUAL_MODE` · `MANUAL_POLICY` · `NO_WINNER` · `NO_ELIGIBLE_MODEL` ·
`NO_ELIGIBLE_MODEL_CONTEXT` · `NO_ELIGIBLE_MODEL_BUDGET` · `NO_ELIGIBLE_MODEL_PRICE` ·
`AUTO_EXECUTION_PROHIBITED`

The specific `NO_ELIGIBLE_MODEL_*` statuses are derived from the stage that eliminated every model:
when every rejected route was eliminated for context fit alone (raw window or usable-context reserve)
→ `NO_ELIGIBLE_MODEL_CONTEXT`; budget alone → `NO_ELIGIBLE_MODEL_BUDGET`; unknown price (policy does
not allow cost-unknown) → `NO_ELIGIBLE_MODEL_PRICE`. An output-limit-only elimination is a distinct
STEP-1 hard gate and keeps the generic `NO_ELIGIBLE_MODEL`.

## 3. STEP 1 — hard eligibility filter

`Get-EligibleAiModels` evaluates every catalogue model route against the requirement and returns
`Eligible` / `Rejected` (with `RejectionReasons`). The reasons are the **17-member vocabulary**,
each with a human-readable detail:

`MODEL_DISABLED`, `PROVIDER_DISABLED`, `PROVIDER_UNAVAILABLE`, `CAPABILITY_CODING_MISSING`,
`CAPABILITY_VISION_MISSING`, `CAPABILITY_TOOL_USE_MISSING`, `STRUCTURED_OUTPUT_MISSING`,
`REASONING_LEVEL_INSUFFICIENT`, `CONTEXT_TOO_SMALL`, `OUTPUT_LIMIT_TOO_SMALL`,
`RELIABILITY_TOO_LOW`, `PROVIDER_DISALLOWED`, `MODEL_DISALLOWED`, `LOCALITY_CONFLICT`,
`BUDGET_EXCEEDED`, `PRICE_UNAVAILABLE`, `PROCESSING_TIER_UNSUPPORTED`

Health is **configured state, not a network probe**:

- `UNAVAILABLE` / `DISABLED` / `AUTH_ERROR` → ineligible (`PROVIDER_UNAVAILABLE` / `PROVIDER_DISABLED`).
- `RATE_LIMITED` / `DEGRADED` → policy-dependent (a warning, not an automatic rejection).
- `UNKNOWN` → not silently healthy; when `Thresholds.requireConfirmedProviderHealth = $true` it is treated as unavailable.

## 4. STEP 2 — context fit (mandatory + reserve)

`Test-AiRoutingContextFit` computes, per model:

```
UsableContext = ContextWindow − (ExpectedOutputTokens + reasoningReserveTokens)
Fits          = UsableContext ≥ RequiredContextTokens (mandatory) and ExpectedOutputTokens ≤ MaxOutputTokens
```

The mandatory context is **never truncated** for routing: if the requirement cannot fit, the model is
rejected with `CONTEXT_TOO_SMALL` and, if every model is eliminated this way, the outcome is
`NO_ELIGIBLE_MODEL_CONTEXT`. The `reasoningReserveTokens` threshold comes from the policy.

## 5. STEP 3 — cost estimation (DB-M16 engine)

`Get-AiCandidateCostEstimate` **never re-implements pricing math**. It:

1. derives usage dimensions (`MandatoryContextTokens` from requirement/budget/package, `ExpectedOutputTokens`),
2. splits input into cached/uncached by `CachedInputFraction`,
3. builds a DB-M16 `New-AiCostCalculationInput` (with an ISO-8601 invariant UTC timestamp so the DB-M16
   validation is host-culture independent),
4. calls `Calculate-AiAttemptCost` (DB-M16) against the DB-M15 pricing catalogue and DB-M16 FX,
5. surfaces the result: `EstimatedCost` + currency, or **`COST_UNKNOWN`** (label) when the lookup or
   calculation yields nothing usable.

The request-level `MaxAllowedCost` gate produces `BUDGET_EXCEEDED`. There are no daily/monthly budgets.

## 6. STEP 4 — historical performance evidence (DB-M24, NON-BINDING)

`Get-AiCandidatePerformanceEvidence` builds a DB-M24 `PerformanceQuery` filtered to the route + task
dimensions, with `SuccessDefinition = VERIFIED_PREFERRED`: a self-reported `SUCCESS` whose independent
verification `FAILED` does **not** count as success. The evidence carries `SampleCount`,
`ConfidenceLevel`, `SuccessRate`, `FirstAttemptSuccessRate`, `AverageCostPerSuccessfulTask` and a
deterministic `PerformanceEvidenceReference`. Confidence below the policy's
`MinimumConfidenceForHistoricalWeight` gives the history **little/no ranking power** (the ranker zeroes
the historical components). This evidence is **non-binding**: it never rejects a model; it only weights
the ranking.

## 7. STEP 5 — policy-weighted ranking

`Rank-AiRoutingCandidates` computes per candidate a set of **explained component scores** and a weighted
`PolicyScore` using the policy object's weights. See `DB-M19_ROUTING_POLICY.md` for the weight model,
the selectability gate (policy `minimumReliability`, `allowCostUnknown`) and the deterministic
tie-breaker chain. Ranking is fully deterministic; no random sampling.

## 8. Manual override

A `ManualOverrideRequest` (`RequestedProviderId` + `RequestedModelId` + optional `RequestedReasoningLevel`)
is validated by `Test-AiManualOverride`:

- the requested route **must already be eligible** (passed the STEP-1 hard constraints),
- the requested reasoning level (when present) must satisfy the requirement and be supported by the model.

Ineligible overrides are **rejected with an explanation** and the recommendation proceeds with the
recommended model. Accepted overrides replace the winner and set `ManualOverride = $true` on the decision.

## 9. Contracts

| Contract | Owner | Version |
|---|---|---|
| `RoutingRequest` | DB-M19 | v1 |
| `RoutingPolicy` | DB-M19 | v1 |
| `RoutingCandidate` | DB-M19 | v1 |
| `RoutingDecisionEvidence` | DB-M19 | v1 (companion) |
| `RoutingDecision` | **DB-M14** | v1 (**unchanged**) |
| `CapabilityRequirement` | DB-M14 | v1 (reused) |
| `TaskClassification` / `ContextBudget` / `ContextPackage` | DB-M18 | v1 (consumed) |
| `CostCalculationInput` | DB-M16 | v1 (consumed) |
| `ModelPerformanceSummary` | DB-M24 | v1 (consumed, non-binding) |

## 10. Files

| File | Role |
|---|---|
| `scripts\ai-routing\router\Router.ps1` | Orchestrator; `Get-AiRoutingRecommendation`, `New-RoutingRequest`/`Test-RoutingRequest`, `Test-AiManualOverride`, `New-DbM19RecommendationReason`, `Export-AiRoutingRecommendation` |
| `scripts\ai-routing\router\RoutingPolicy.ps1` | RoutingPolicy v1, objectives, rejection vocabulary, default CHEAPEST_RELIABLE |
| `scripts\ai-routing\router\RoutingCandidate.ps1` | RoutingCandidate v1 + RoutingDecisionEvidence v1 |
| `scripts\ai-routing\router\RoutingEligibility.ps1` | STEP 1 filter + STEP 2 context fit |
| `scripts\ai-routing\router\RoutingCost.ps1` | STEP 3 cost via DB-M16 |
| `scripts\ai-routing\router\RoutingPerformance.ps1` | STEP 4 evidence via DB-M24 |
| `scripts\ai-routing\router\RoutingRank.ps1` | STEP 5 ranking + component scores |
| `scripts\ai-routing\router\Test-DbM19Routing.ps1` | Offline test suite (136 tests) |
| `design\ai-routing\DB-M19_MODEL_ROUTER.md` | This document |
| `design\ai-routing\DB-M19_ROUTING_POLICY.md` | Policy design |
| `state\db-m19-result.json` | Milestone result record |

**Read-only inputs** (never modified): `scripts\ai-routing\AiRoutingContracts.ps1` (DB-M14),
`AiRoutingCostFoundation.ps1` (DB-M14+M15+M16), `AiCostContracts.ps1`, `scripts\ai-routing\performance\*` (DB-M17+DB-M24).

## 11. Verification

`Test-DbM19Routing.ps1` (exit 0 = all pass) exercises, offline: policy contracts, cold start,
history-aware CHEAPEST_RELIABLE and BEST_COST_PER_SUCCESS (cheap-but-failure-prone ranks below
slightly-more-expensive-high-success), cost-only, HIGHEST_SUCCESS (self-reported PASS with failed
verification does NOT count), gateway (direct + gateway = two candidates for one underlying),
reasoning LOW/MEDIUM/HIGH, context fit (fits cheapest, excludes cheapest, mandatory exceeds all →
`NO_ELIGIBLE_MODEL_CONTEXT`, output reserve), budget (`BUDGET_EXCEEDED`), catalogue (disabled model,
disabled provider, unavailable provider, unknown price, missing provider reference), deterministic
tie-breakers, transparent recommendation reason, manual override accept/reject, AUTO refusal,
MANUAL-mode preservation, recommendation export to a DB-M19-owned temp path, and the DB-M14 frozen
contract hash (SHA-256 byte-identical). **0 paid API calls, 0 network calls.**
