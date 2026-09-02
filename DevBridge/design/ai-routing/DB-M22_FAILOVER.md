# DB-M22 — Failover Foundation (ProviderFailoverDecision v1)

**Milestone:** DB-M22 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M22 failover answers "if this route is not currently usable, is there another
eligible route that can be recommended?" It is a **decision only**: no provider
is invoked, no workflow is switched, no fallback is executed. `AUTO_EXECUTION_ENABLED
= FALSE`. 0 paid API calls, 0 network calls.

Companion: `DB-M22_PROVIDER_HEALTH.md`.

---

## 1. Failover must preserve routing eligibility

DB-M22 never selects arbitrary fallback providers. A fallback route must already
satisfy DB-M19 hard eligibility constraints (capabilities, reasoning support,
context size, locality, allowed/disallowed provider/model, budget where DB-M21
says allowed). Hard filters are **never** bypassed because the preferred provider
is down. A route REJECTED by DB-M19 is never re-admitted by DB-M22.

## 2. ProviderFailoverDecision v1

| Field | Meaning |
|---|---|
| `SchemaVersion` | 1 |
| `DecisionId` | deterministic decision id |
| `TaskId`, `AttemptId` | originating context |
| `OriginalProviderId`, `OriginalModelId`, `OriginalRouteId` | the route that is unhealthy |
| `OriginalHealthState` | effective health of that route |
| `Action` | structured action (below) |
| `RecommendedProviderId`, `RecommendedModelId`, `RecommendedRouteId` | healthy alternate (or null) |
| `UnderlyingModelId` | preserved across a route switch where possible |
| `HealthEvidenceReferences` | evidence ids used |
| `RoutingEvidenceReference` | DB-M19 evidence reference |
| `BudgetEvidenceReference` | DB-M21 budget reference |
| `EscalationEvidenceReference` | DB-M20 decision reference |
| `ReasonCodes` | closed vocabulary (below) |
| `RetryAfterUtc` | honored from RATE_LIMITED evidence |
| `RequiresHuman` | bool |
| `HumanActionType` | DB-M20 human action type when RequiresHuman |
| `PolicyId` | health/failover policy used |
| `GeneratedAtUtc` | injected decision timestamp |

## 3. Failover action vocabulary

`USE_CURRENT_ROUTE`, `SWITCH_ROUTE`, `WAIT_RETRY_AFTER`, `WAIT_COOLDOWN`,
`NO_HEALTHY_ROUTE`, `HUMAN_PROVIDER_CONFIGURATION_REQUIRED`,
`HUMAN_PROVIDER_DECISION_REQUIRED`, `STOP_PROVIDER_UNAVAILABLE`,
`ROUTING_REPLAN_REQUIRED`.

## 4. Failover reason-code vocabulary (DB-M22-owned, closed)

`HEALTHY_ROUTE`, `ROUTE_UNHEALTHY`, `NO_HEALTHY_ALTERNATE`, `HEALTHY_ALTERNATE_FOUND`,
`ALTERNATE_REJECTED_BY_ROUTER`, `ALTERNATE_OVER_BUDGET`, `ALTERNATE_BUDGET_OK`,
`ALTERNATE_BUDGET_UNKNOWN`, `BUDGET_REQUIRES_OVERRIDE`, `KNOWN_FAILURE_SUPPRESSED`,
`REPEAT_PROHIBITED`, `RETRY_AFTER_PENDING`, `COOLDOWN_PENDING`, `COOLDOWN_ELAPSED`,
`AUTH_REQUIRES_HUMAN`, `AUTH_NEVER_MODEL_ESCALATES`, `PROVIDER_DISABLED`,
`UNKNOWN_HEALTH_LOW_RISK_ALLOWED`, `UNKNOWN_HEALTH_HIGH_RISK_DENIED`,
`MODEL_QUALITY_NOT_A_HEALTH_SIGNAL`, `TRANSPORT_OK_QUALITY_POOR`,
`HUMAN_GIT_GATE_NOT_PROVIDER_FAILURE`, `CLAUDE_REVIEW_GATE_PRESERVED`,
`GOVERNANCE_BLOCK_NOT_FAILOVER`, `DETERMINISTIC`, `MANUAL_MODE_PRESERVED`,
`ASSISTED_RECOMMENDATION`, `AUTO_EXECUTION_PROHIBITED`.

## 5. Failover decision logic (deterministic)

1. Evaluate original route effective health.
2. If healthy (`AVAILABLE`/`DEGRADED`/permissive `UNKNOWN`) → `USE_CURRENT_ROUTE`.
3. If `DISABLED` → `STOP_PROVIDER_UNAVAILABLE` (never re-enabled).
4. If `AUTH_ERROR`:
   - never model-escalate (no `SWITCH_MODEL` / higher reasoning) — `AUTH_NEVER_MODEL_ESCALATES`;
   - if an eligible alternate route exists (different provider, healthy, budget-ok) → `SWITCH_ROUTE` while keeping the auth problem visible; else `HUMAN_PROVIDER_CONFIGURATION_REQUIRED`.
5. If `RATE_LIMITED` with `RetryAfterUtc` future and no healthy alternate → `WAIT_RETRY_AFTER` (RetryAfterUtc carried).
6. If `UNAVAILABLE` / `RATE_LIMITED` / `DEGRADED`:
   - healthy eligible alternate exists → `SWITCH_ROUTE` (subject to budget);
   - no healthy alternate → `NO_HEALTHY_ROUTE`.
7. `UNKNOWN` health → policy decides: permissive low-risk → allowed; high-risk confirmed-availability → `NO_HEALTHY_ROUTE`/`HUMAN_PROVIDER_DECISION_REQUIRED`.
8. Circuit `OPEN` before cooldown → `WAIT_COOLDOWN`; cooldown elapsed → probe eligible (`HALF_OPEN`).

## 6. Budget integration (DB-M21)

Before recommending an alternate route that would incur an AI call, DB-M22
consumes `Test-AiBudget` with the alternate route's proposed cost. If the
alternate route exceeds budget → `ROUTING_REPLAN_REQUIRED` (budget evidence
attached), never an executable failover. Budget is not bypassed because provider
health changed.

## 7. Failure-fingerprint integration (DB-M21)

DB-M22 uses `New-FailureFingerprint` + `Get-AiKnownFailureEvidence` +
`Test-AiRepeatAttemptAllowed` to avoid repeatedly retrying a known provider
failure under identical conditions (same provider, same AUTH_ERROR, same config,
multiple occurrences). A suppressed repeat yields `KNOWN_FAILURE_SUPPRESSED` and
`HUMAN_PROVIDER_CONFIGURATION_REQUIRED` (or `WAIT_COOLDOWN`); DB-M22 never
executes the retry itself.

## 8. DB-M20 integration

DB-M20 may say `SWITCH_PROVIDER_ROUTE`. DB-M22 determines whether an alternate
route is currently suitable. It never changes DB-M20's reasoning or
model-quality classification. If no healthy alternate exists, that fact is
returned — no fallback is fabricated.

## 9. Passive health learning / performance separation

- transport success → positive availability evidence;
- HTTP/provider timeout → negative route evidence;
- verified model output later failing quality checks → **DO NOT** mark provider unavailable.
- DB-M24 answers "how well?"; DB-M22 answers "can it be used now?". Never combined
  into one score.

## 10. Git / governance gates

A human Git gate (`AWAITING_HUMAN_PR`, `PR_OPEN`, `AWAITING_HUMAN_MERGE`) and a
Claude-review gate are **not** provider failures. Health/failover logic never
turns them into failover, never routes around them, and never auto-advances.
