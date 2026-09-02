# DB-M20 — Retry + Automatic Escalation DECISION Engine (EscalationEngine v1)

**Milestone:** DB-M20 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M20 is a **decision engine, not an executor**. It computes a deterministic retry / escalation
**plan** from a failed attempt, its preserved attempt chain, the DB-M19 routing evidence and a
DB-M20 escalation policy. It **never executes** anything: `AUTO_EXECUTION_ENABLED = FALSE`, no live
AI/provider invocation, no paid API calls, no autonomous Nexus changes.

Companion: `DB-M20_ESCALATION_POLICY.md`.

---

## 1. Governing constraints (non-negotiable)

| Constraint | Behaviour |
|---|---|
| Decision-engine only | Every outcome is a **recommendation** (`Status` + `Action` + `ReasonCodes`). `AutoExecutionEnabled` is always `$false`; `ExecutionMode = AUTO` is refused outright (`AUTO_EXECUTION_PROHIBITED`). |
| No Nexus modification | No Nexus workbook, roadmap, or Lane C state is read, written, or restructured. Exports refuse every Nexus-owned and every outside-root path (see §8). |
| Human Git gates never bypassed | `HUMAN_GIT_GATE` / `PR_PENDING` / `MERGE_PENDING` produce `HUMAN_GIT_ACTION_REQUIRED` (human `GIT_ACTION`) — never a model escalation. |
| Claude review gates never bypassed | A `FIX_REQUIRED` review signal maps to `CLAUDE_REVIEW_FIX` → focused correction on the same route; it is an AI-side correction, never a skip of the review. |
| Non-AI failures never escalate to a model | Scope / governance / git / PR / merge / architecture failures stop or go to a human. `NO_QUALITY_ESCALATION_FOR_NON_AI` is emitted. No stronger model is spent on a non-AI problem. |
| Verification is authoritative | A self-reported `SUCCESS` whose independent verification `FAILED` is classified `VERIFICATION_FAILURE` (marker `SELF_REPORTED_PASS_FAILED_VERIFICATION`) → `CORRECT_CURRENT_ATTEMPT`. Model says PASS / DB-M06 says FAIL ⇒ **FAILURE**. |
| Hard capability filters never bypassed | Model escalation considers **only** DB-M19 `ELIGIBLE` candidates. A `REJECTED` candidate (capability/context/budget gap) is never re-admitted, even if stronger or more expensive. |
| No infinite retry loops | Bounded by `MaxAttemptsPerTask` + `MaxSameModelRetries` + `MaxReasoningEscalations` + `MaxModelEscalations`, plus chain `LoopFree` validation and the exact-combination loop check. |
| One-step reasoning escalation | LOW→MEDIUM→HIGH→MAX, one step at a time, only when the model supports it and the policy allows. Never an automatic jump to MAX. |
| Focused FIX over REBUILD | `CORRECT_CURRENT_ATTEMPT` preserves verified work and corrects only the failed delta. `NEW_FIX_TASK_REQUIRED` is represent-only (no roadmap/workbook record is ever created). |
| Request-level ceiling only | `MaxAllowedCost` is the **request** ceiling. No daily / monthly / org / retry-pool / team budgets (DB-M21 territory). Incremental and cumulative costs are always present — never hidden. |
| DB-M24 evidence, no overconfidence | Historical evidence (confidence, success rate) influences candidate ranking only when `ConfidenceSufficient`. INSUFFICIENT confidence must not produce overconfident escalation. |
| Deterministic | No randomness; stable sorts; a pure function of (input, policy, preserved chain). ADR-005: no branch on provider/model **names**. |
| Frozen contracts | DB-M14/15/16/17/18/19/M24 are consumed READ-ONLY. An incompatible change would `STOP: SHARED_CONTRACT_CHANGE_REQUIRED`. |

## 2. Pipeline (deterministic decision order)

```
New-EscalationInput (v1) ─ Test-EscalationInput ─ Get-AiEscalationDecision
 1. AUTO check                → AUTO_EXECUTION_PROHIBITED
 2. chain assembly            → CurrentAttempt + AttemptChain, dedupe by AttemptId
 3. human intervention flag   → HUMAN_REVIEW_REQUIRED
 4. verified success          → STOP_SUCCESS  (SUCCESS_VERIFIED)
 5. classification            → Get-AiFailureCategory (verification-authoritative)
 6. governance / auth / budget
      - policy StopFailureCategories      → STOP_GOVERNANCE
      - policy HumanGateFailureCategories → human action
      - recorded BUDGET_FAILURE           → STOP_BUDGET_LIMIT (BudgetStop)
      - request ceiling exceeded          → STOP_BUDGET_LIMIT (BUDGET_CEILING_REACHED)
 7. attempt-limit check       → ATTEMPT_LIMIT_REACHED (no further attempt)
 8. category action table     → §3
 9. finalize                  → loop protection (§5) + cost-ceiling re-check (§6)
```

### Classification precedence (verification is authoritative)

1. Explicit DB-M20 escalation category (governance/auth/budget classes are never overridden).
2. `ClaudeReviewStatus = FIX_REQUIRED` → `CLAUDE_REVIEW_FIX`.
3. `VerificationResult = FAILED` → `VERIFICATION_FAILURE` (self-reported PASS is not success).
4. Recorded DB-M17 category, mapped when needed (`CONTEXT_FAILURE→CONTEXT_TOO_LARGE`,
   `VALIDATION_FAILURE→VERIFICATION_FAILURE`, `BUDGET_FAILURE→UNKNOWN_FAILURE`+`BudgetStop`, `UNKNOWN→UNKNOWN_FAILURE`).

An unknown recorded category **throws** — the engine never guesses a failure.

## 3. Category action table (decision engine only)

| Category (class) | Action (first valid) |
|---|---|
| `AUTHENTICATION` | `STOP_NO_ELIGIBLE_ESCALATION` + `AUTH_ACTION` (credentials; `AUTH_NOT_MODEL_ISSUE`) |
| `CONTEXT_INSUFFICIENT` | `REQUEST_MISSING_CONTEXT` (human `CONTEXT_PROVISION`; governance context retained) |
| `CONTEXT_TOO_LARGE` | `SWITCH_MODEL` to larger-window eligible model, else `REBUILD_CONTEXT` (`MANDATORY_GOVERNANCE_RETAINED`), else stop |
| `TIMEOUT` | `RETRY_SAME_ROUTE` while within limits, else `SWITCH_PROVIDER_ROUTE`, else stop |
| `PROVIDER_AVAILABILITY` / `RATE_LIMIT` / `TOOL_FAILURE` | `SWITCH_PROVIDER_ROUTE` when a different-provider eligible route exists, else retry, else stop |
| `VERIFICATION_FAILURE` / `CLAUDE_REVIEW_FIX` / `INVALID_OUTPUT` | `CORRECT_CURRENT_ATTEMPT` (first), then reasoning escalation, then model switch, then `NEW_FIX_TASK_REQUIRED` (represent-only) |
| `MODEL_QUALITY` | `RETRY_SAME_MODEL_HIGHER_REASONING` (one step), then `SWITCH_MODEL` to an eligible candidate, else `STOP_NO_ELIGIBLE_ESCALATION` |
| `BUILD_FAILURE` / `TEST_FAILURE` | repair `RETRY_SAME_ROUTE`, then `CORRECT_CURRENT_ATTEMPT`, then `NEW_FIX_TASK_REQUIRED` |
| `UNKNOWN_FAILURE` | `STOP_NO_ELIGIBLE_ESCALATION` + `UNKNOWN_CONSERVATIVE` (never escalate an unknown to a bigger model) |

Governance categories (`GOVERNANCE_BLOCKED`, `ARCHITECTURE_CONFLICT`, `SCOPE_CHANGE_REQUIRED`,
`HUMAN_GIT_GATE`, `PR_PENDING`, `MERGE_PENDING`) are handled **before** the action table by fixed
policy tables and never reach model/reasoning escalation.

## 4. Preserved chain (DB-M17 read-only)

- `New-EscalationChain` deterministically sorts the chain by `RetryNumber` (stable `AttemptId`
  tie-break) and validates: no duplicate `AttemptId`, no self-escalation, no decreasing retry number.
- `Get-DbM20ChainCounts` derives `SameModelRetryCount`, `ReasoningEscalationsUsed` (levels above the
  base attempt), `ModelEscalationsUsed` (distinct models beyond the first), `CorrectionCount`,
  `BaseReasoningLevel`.
- `Test-AiEscalationLoop` flags a proposal whose exact `(provider, model, reasoning)` combination is
  already in the chain as cyclic.

## 5. Loop protection

- **Same-route actions** (`RETRY_SAME_ROUTE`, `CORRECT_CURRENT_ATTEMPT`, `REBUILD_CONTEXT`,
  `REQUEST_MISSING_CONTEXT`) reuse the current route **by design**; their safety comes from
  `MaxSameModelRetries` + `MaxAttemptsPerTask` + chain `LoopFree`.
- **Route-changing actions** (`RETRY_SAME_MODEL_HIGHER_REASONING`, `SWITCH_MODEL`,
  `SWITCH_PROVIDER_ROUTE`) get the exact-combination loop check. A revisit is refused with
  `LOOP_PREVENTED` → `STOP_NO_ELIGIBLE_ESCALATION`, and the proposed next route is not planned.
- Candidate ranking pre-filters current + visited routes, so the finalize loop check is a
  belt-and-suspenders guarantee — it fires whenever a route-changing proposal (e.g. a reasoning
  escalation after a downgrade in the chain) would revisit an attempted combination.

## 6. Cost-aware escalation (DB-M16 engine, request ceiling only)

- `Get-AiEscalationCost` delegates to the DB-M19 STEP 3 estimator
  (`Get-AiCandidateCostEstimate` → DB-M16 `Calculate-AiAttemptCost`). The cost math is **never**
  duplicated.
- Returns the incremental next-attempt cost (`NextAttemptCost`, currency, `NextCostUnknown`) and the
  cumulative cost across the chain (actual preferred, else estimated) — always present, never hidden.
- An unknown price is surfaced as `NextCostUnknown = $true` with a label — **never an invented price**.
- `Test-DbM20BudgetCeiling` (request-level) refuses a next attempt when `cumulative + next estimate`
  exceeds `MaxAllowedCost` (`STOP_BUDGET_LIMIT`).

## 7. Decision schema (EscalationDecision v1)

| Field | Meaning |
|---|---|
| `Status` | one of the 10 decision statuses (e.g. `RECOMMENDED`, `STOP_*`, `HUMAN_*`, `AUTO_EXECUTION_PROHIBITED`) |
| `Action` | one of the 16 actions; `$null` only for `AUTO_EXECUTION_PROHIBITED` |
| `FailureCategory` / `ReasonCodes` | the classified category + a closed vocabulary of reasons (40 members) |
| `NextProviderId` / `NextModelId` / `NextReasoningLevel` | the proposed route for a future attempt (empty for stops) |
| `ContextAction` | `KEEP_CONTEXT` / `EXPAND_CONTEXT` / `REBUILD_CONTEXT` / `REDUCE_NOISE` / `REQUEST_MISSING_CONTEXT` |
| `RequiresHuman` / `HumanActionType` | whether a human must act and which of the 8 human actions |
| `EstimatedNextAttemptCost` / `NextCostCurrency` / `NextCostUnknown` / `CumulativeActualCost` / `CumulativeEstimatedCost` | cost evidence on the recommendation |
| `AutoExecutionEnabled` | always `$false` |
| `PerformanceEvidenceReference` | DB-M24 evidence reference carried through, never used overconfidently |

`Get-AiEscalationDecision -InputObject -Policy` returns the decision; `Test-EscalationDecision`
validates it before export.

## 8. Temporary DevBridge boundary (export)

`Export-AiEscalationDecision` writes only under the DB-M20-owned
`state\ai-routing-escalation-decisions\` (default) inside the DevBridge root, append-only unless
`-Force`. `Test-DbM20ExportPathAllowed` **refuses**:

- any path outside the DevBridge root (e.g. `$env:TEMP`, other projects),
- any path containing a `nexus` component (Nexus repo/workbook paths — `Nexus.Developer` refused),
- live handoff artifacts (filename matches `handoff` / `ROUTING_RECOMMENDATION` / `TASK_HANDOFF`),
- the milestone result file itself (`db-m20-result.json`).

DB-M20 sources carry **no** Nexus assembly reference (`Add-Type`, `[Nexus.*`, `using namespace Nexus`,
`Nexus::`) and no runtime execution lever (`Invoke-Expression`, `Start-Process`, `Start-Job`,
`Invoke-Command`, `System.Reflection`) — nothing built here can be reused by Nexus, by design.

## 9. Operations

`Get-AiFailureCategory` · `Get-AiEscalationDecision` · `Test-AiRetryAllowed` ·
`Get-AiNextReasoningLevel` · `Get-AiEscalationCandidates` · `Get-AiEscalationCost` ·
`Test-AiEscalationLoop` · `Export-AiEscalationDecision` (all backed by `New-*`/`Test-*` contracts).

## 10. Determinism

Every decision is a pure function of `(input, policy, preserved chain)`. No randomness, no
wall-clock ordering, no provider/model name branching. Equal rankings are broken by the policy
tie-break chain. The engine is verified by `Test-DbM20Escalation.ps1` (26 scenarios, S1–S26,
including the Temporary DevBridge boundary assertion).
