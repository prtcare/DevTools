# DB-M20 — Escalation Policy (EscalationPolicy v1)

**Milestone:** DB-M20 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

An `EscalationPolicy v1` is **pure configuration data** that bounds the DB-M20 retry / escalation
decision engine. The engine reads every budget, gate and tie-breaker from the policy object — no
budget or gate is hard-coded in engine logic. ADR-005 applies: nothing in a policy or its evaluation
branches on a provider/model name.

Companion: `DB-M20_RETRY_ESCALATION.md`.

---

## 1. Failure categories (20 members)

```
MODEL_QUALITY                    PROVIDER_AVAILABILITY          RATE_LIMIT
AUTHENTICATION                   TIMEOUT                        CONTEXT_TOO_LARGE
CONTEXT_INSUFFICIENT             INVALID_OUTPUT                 TOOL_FAILURE
BUILD_FAILURE                    TEST_FAILURE                   VERIFICATION_FAILURE
CLAUDE_REVIEW_FIX                SCOPE_CHANGE_REQUIRED          GOVERNANCE_BLOCKED
HUMAN_GIT_GATE                   PR_PENDING                     MERGE_PENDING
ARCHITECTURE_CONFLICT            UNKNOWN_FAILURE
```

The DB-M17 **recorded** failure categories (read-only) are a strict subset; DB-M20-specific
categories (`TIMEOUT`, `CONTEXT_TOO_LARGE`, `CONTEXT_INSUFFICIENT`, `INVALID_OUTPUT`,
`VERIFICATION_FAILURE`, `CLAUDE_REVIEW_FIX`, governance) arrive via the explicit escalation
signal — never recorded onto an attempt.

## 2. Failure classes (7)

| Class | Members | Escalation intent |
|---|---|---|
| `TRANSIENT` | `PROVIDER_AVAILABILITY`, `RATE_LIMIT`, `TIMEOUT`, `TOOL_FAILURE` | bounded same-route retry, then provider-route switch |
| `QUALITY` | `MODEL_QUALITY`, `INVALID_OUTPUT`, `BUILD_FAILURE`, `TEST_FAILURE`, `VERIFICATION_FAILURE`, `CLAUDE_REVIEW_FIX` | reasoning escalation / model escalation / focused correction |
| `CONTEXT` | `CONTEXT_TOO_LARGE`, `CONTEXT_INSUFFICIENT` | larger-window model or context rebuild / request missing context |
| `AUTHENTICATION` | `AUTHENTICATION` | never a model issue → `AUTH_ACTION` |
| `BUDGET` | recorded `BUDGET_FAILURE` | `BudgetStop` → `STOP_BUDGET_LIMIT` (never a model escalation) |
| `GOVERNANCE` | `SCOPE_CHANGE_REQUIRED`, `GOVERNANCE_BLOCKED`, `HUMAN_GIT_GATE`, `PR_PENDING`, `MERGE_PENDING`, `ARCHITECTURE_CONFLICT` | stop or human; **never** model/reasoning escalation |
| `UNKNOWN` | `UNKNOWN_FAILURE` | conservative stop (`UNKNOWN_CONSERVATIVE`) |

## 3. Actions (16)

```
RETRY_SAME_ROUTE               RETRY_SAME_MODEL_HIGHER_REASONING   SWITCH_MODEL
SWITCH_PROVIDER_ROUTE          REBUILD_CONTEXT                     CORRECT_CURRENT_ATTEMPT
REQUEST_MISSING_CONTEXT        STOP_SUCCESS                        STOP_NO_ELIGIBLE_ESCALATION
STOP_BUDGET_LIMIT              STOP_GOVERNANCE                     HUMAN_REVIEW_REQUIRED
HUMAN_GOVERNANCE_REQUIRED      HUMAN_GIT_ACTION_REQUIRED           HUMAN_ARCHITECTURE_DECISION_REQUIRED
NEW_FIX_TASK_REQUIRED
```

`NEW_FIX_TASK_REQUIRED` is **represent-only** — it requests a fix task but never creates a roadmap /
workbook record.

## 4. Context actions (5) and human action types (8)

Context: `KEEP_CONTEXT` · `EXPAND_CONTEXT` · `REBUILD_CONTEXT` · `REDUCE_NOISE` ·
`REQUEST_MISSING_CONTEXT`

Human: `NONE` · `GIT_ACTION` · `GOVERNANCE_REVIEW` · `REVIEW_FIX` · `ARCHITECTURE_DECISION` ·
`CONTEXT_PROVISION` · `FIX_TASK` · `AUTH_ACTION`

Mandatory governance context is **never** removed (`MANDATORY_GOVERNANCE_RETAINED`).

## 5. Decision statuses (10)

```
RECOMMENDED                     STOP_SUCCESS                  STOP_NO_ELIGIBLE_ESCALATION
STOP_BUDGET_LIMIT               STOP_GOVERNANCE               HUMAN_REVIEW_REQUIRED
HUMAN_GOVERNANCE_REQUIRED       HUMAN_GIT_ACTION_REQUIRED     HUMAN_ARCHITECTURE_DECISION_REQUIRED
AUTO_EXECUTION_PROHIBITED
```

## 6. Reason codes (40 members, closed vocabulary)

```
SUCCESS_VERIFIED                VERIFICATION_FAILED            CLAUDE_REVIEW_FIX
VERIFICATION_FAILURE            INVALID_OUTPUT                 SELF_REPORTED_PASS_FAILED_VERIFICATION
RETRY_TRANSIENT                 RETRY_SAME_MODEL_EXHAUSTED     ATTEMPT_LIMIT_REACHED
BUDGET_CEILING_REACHED          BUDGET_FAILURE_RECORDED        GOVERNANCE_BLOCKED
SCOPE_CHANGE                    GIT_GATE_PENDING               PR_PENDING
MERGE_PENDING                   ARCHITECTURE_CONFLICT          AUTH_NOT_MODEL_ISSUE
RATE_LIMIT_ROUTE_SWITCH         PROVIDER_AVAILABILITY_ROUTE_SWITCH  CONTEXT_TOO_LARGE_SWITCH_MODEL
CONTEXT_TOO_LARGE_REBUILD       CONTEXT_INSUFFICIENT           MANDATORY_GOVERNANCE_RETAINED
REASONING_ESCALATION            REASONING_ESCALATION_BLOCKED   MODEL_ESCALATION
MODEL_ESCALATION_NONE_ELIGIBLE  LOOP_PREVENTED                 NO_QUALITY_ESCALATION_FOR_NON_AI
UNKNOWN_CONSERVATIVE            AUTO_PROHIBITED                CORRECT_CURRENT_ATTEMPT
REPEAT_CORRECTION_ESCALATE      MAX_SAME_MODEL_RETRIES         MAX_REASONING_ESCALATIONS
MAX_MODEL_ESCALATIONS           NEW_FIX_TASK_REPRESENT_ONLY    RETRY_REPAIR
HUMAN_INTERVENTION_PENDING
```

## 7. Policy schema (v1)

| Field | Type | Default | Meaning |
|---|---|---|---|
| `SchemaVersion` | int | `1` | required |
| `PolicyId` | string | — | required; trimmed |
| `Name` | string | `PolicyId` | display name |
| `Enabled` | bool | — | disabled policies refuse to decide |
| `MaxAttemptsPerTask` | int | `5` | hard bound on attempts per task (no infinite attempts) |
| `MaxSameModelRetries` | int | `2` | hard bound on retries of the same model route |
| `MaxReasoningEscalations` | int | `2` | hard bound on one-step reasoning escalations per task |
| `MaxModelEscalations` | int | `1` | hard bound on model switches per task |
| `AllowReasoningIncrease` | bool | `$true` | `$false` blocks any reasoning escalation |
| `AllowModelSwitch` | bool | `$true` | `$false` blocks model escalation entirely |
| `AllowProviderRouteSwitch` | bool | `$true` | `$false` blocks provider-route switching |
| `AllowContextRebuild` | bool | `$true` | `$false` blocks `REBUILD_CONTEXT` |
| `StopFailureCategories` | string[] | `GOVERNANCE_BLOCKED`, `ARCHITECTURE_CONFLICT` | terminal stop — no retry/escalation/human action |
| `HumanGateFailureCategories` | string[] | `HUMAN_GIT_GATE`, `PR_PENDING`, `MERGE_PENDING`, `SCOPE_CHANGE_REQUIRED` | human gate — never escalated to a model |
| `MinimumVerificationEvidence` | string | `VERIFIED` | verification standard for `STOP_SUCCESS` |
| `TieBreaker` | string[] | `PerformanceConfidence`, `SuccessRate`, `EstimatedCost`, `ModelId` | deterministic candidate ranking |
| `Notes` | string | — | optional |

The default policy is `escalation-policy-default-v1` (above values). `Test-EscalationPolicy`
validates a policy object deterministically.

## 8. Determinism

Budgets are simple non-negative counters; the loop check is an exact-combination comparison; the
ranking tie-breaker chain is applied in declared order with stable sorts. No randomness, no
wall-clock ordering, no provider/model name comparisons — a decision is a pure function of
`(input, policy, preserved chain)`.
