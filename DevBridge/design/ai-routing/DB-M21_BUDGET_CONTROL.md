# DB-M21 — Budget Control (BudgetPolicy v1 + BudgetEvaluation v1)

**Milestone:** DB-M21 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M21 Part A is a **control / decision foundation**: it answers "is the proposed
AI attempt allowed under the configured budget policy?" It consumes cost evidence
from DB-M15 pricing / DB-M16 cost / DB-M17 attempt history / DB-M19 routing /
DB-M20 escalation decisions — it **never calculates model prices itself** and
**never executes a provider/model**. `AUTO_EXECUTION_ENABLED = FALSE`.

Companion: `DB-M21_FAILURE_FINGERPRINTS.md`.

---

## 1. Governing constraints

| Constraint | Behaviour |
|---|---|
| Control/decision only | Budget evaluation produces a structured `Decision` (+ reason codes), never an execution. |
| Consumes cost evidence | Spend comes from DB-M17 `ActualCost`/`EstimatedCost`; the proposed attempt cost comes from the DB-M20 escalation decision / DB-M19 estimate. No pricing math here. |
| Actual over estimate | An attempt with `ActualCost` contributes its actual; an attempt with only `EstimatedCost` contributes the estimate (marked pending). Never both. |
| Cumulative retry cost | All failed attempts count toward spend; a later success never erases earlier failed spend (DB-M17 append-only semantics). |
| Human gates cost nothing | `HUMAN_GIT_ACTION_REQUIRED`, `HUMAN_GOVERNANCE_REQUIRED`, `HUMAN_REVIEW_REQUIRED`, `CLAUDE_REVIEW_REQUIRED` (no model call), `SCOPE_CHANGE_REQUIRED`, `GOVERNANCE_BLOCKED`, `ARCHITECTURE_CONFLICT`, `PR_PENDING`, `MERGE_PENDING` consume **zero** AI budget. Budget is for AI/provider execution, not elapsed workflow time. |
| Unknown cost is explicit | An unknown price/cost is never treated as zero. `UnknownCostPolicy` decides ALLOW / WARN / BLOCK. |
| Override is explicit only | DB-M21 never infers human approval. Only explicit `OverrideReference` + `OverrideReason` + timestamp evidence counts. |
| No roadmap power | A block or a fingerprint never rewrites the roadmap. DB-M21 creates no Nexus/roadmap records. |
| Deterministic | The evaluation timestamp is injected; day/month windows are derived from it (never machine-local "now"). No randomness. ADR-005: no provider/model name branching. |
| Request ceiling beyond M20 | DB-M20 owns the request-level `MaxAllowedCost` ceiling. DB-M21 adds TASK / CHANGE / SESSION / DAILY / MONTHLY / TEAM scopes. |

## 2. BudgetPolicy v1 (pure configuration data)

| Field | Type | Default | Meaning |
|---|---|---|---|
| `SchemaVersion` | int | `1` | required |
| `PolicyId` | string | — | required; trimmed |
| `Name` | string | `PolicyId` | display name |
| `Enabled` | bool | `true` | a disabled policy refuses to decide |
| `Currency` | string | `INR` | the accounting currency spend is compared in |
| `TaskLimit` | double? | `$null` | limit per task (null = not configured) |
| `ChangeLimit` | double? | `$null` | limit per change |
| `SessionLimit` | double? | `$null` | limit per session window |
| `DailyLimit` | double? | `$null` | limit per accounting day |
| `MonthlyLimit` | double? | `$null` | limit per accounting month |
| `TeamLimit` | double? | `$null` | team / workspace limit (generic scope key) |
| `WarnAtPercent` | double | `80` | projected >= limit*WarnAtPercent/100 → warning |
| `BlockAtPercent` | double | `100` | projected >= limit*BlockAtPercent/100 → block |
| `IncludeEstimatedPendingCost` | bool | `true` | pending estimates + the proposed estimate count toward the limit |
| `UnknownCostPolicy` | string | `BLOCK` | `ALLOW` / `WARN` / `BLOCK` when a cost is unknown or unconvertible |
| `AllowManualOverride` | bool | `true` | a human may override a block |
| `RequireReasonForOverride` | bool | `true` | override without a reason is rejected |
| `AccountingUtcOffsetHours` | double | `0` | day/month boundaries in UTC + this offset (deterministic) |
| `Notes` | string | — | optional |

Nullable limits — a null limit means that scope is **not configured** (never an
infinite sentinel). The default policy is `budget-policy-default-v1`
(INR, no limits configured → `NO_APPLICABLE_BUDGET` until a limit is set).

## 3. Budget scopes, decisions, purposes, reason codes

```
Scopes:   TASK  CHANGE  SESSION  DAILY  MONTHLY  TEAM
Decisions:ALLOW  ALLOW_WITH_WARNING  BLOCK_BUDGET_EXCEEDED  BLOCK_COST_UNKNOWN
         REQUIRE_HUMAN_OVERRIDE  NO_APPLICABLE_BUDGET
Purposes: AI_ATTEMPT  HUMAN_GATE  GOVERNANCE_WAIT
```

Reason codes (closed vocabulary): `NO_APPLICABLE_LIMIT`, `UNDER_LIMIT`,
`WARNING_THRESHOLD_REACHED`, `TASK_LIMIT_EXCEEDED`, `CHANGE_LIMIT_EXCEEDED`,
`SESSION_LIMIT_EXCEEDED`, `DAILY_LIMIT_EXCEEDED`, `MONTHLY_LIMIT_EXCEEDED`,
`TEAM_LIMIT_EXCEEDED`, `BLOCKED_STRICTEST_LIMIT`, `COST_UNKNOWN_ALLOWED`,
`COST_UNKNOWN_WARN`, `COST_UNKNOWN_BLOCKED`, `CURRENCY_CONVERTED`,
`CURRENCY_UNAVAILABLE`, `ACTUAL_PREFERRED`, `ESTIMATED_PENDING_INCLUDED`,
`HUMAN_GATE_ZERO_COST`, `GOVERNANCE_ZERO_COST`, `HUMAN_OVERRIDE_GRANTED`,
`HUMAN_OVERRIDE_REQUIRED`, `OVERRIDE_REASON_REQUIRED`, `OVERRIDE_PROHIBITED`,
`NO_OVERRIDE_NEEDED`, `DETERMINISTIC_WINDOW`.

## 4. BudgetEvaluation v1 (DB-M21-owned result record)

| Field | Meaning |
|---|---|
| `SchemaVersion` / `EvaluationId` | identity |
| `TaskId` / `ChangeId` / `SessionId` | scope identity (null when not evaluated) |
| `PolicyId` | the policy used |
| `Currency` | accounting currency |
| `CurrentActualSpend` | Σ actual costs (converted) across the scope |
| `CurrentEstimatedPendingSpend` | Σ estimated-only costs (converted) + proposed estimate when included |
| `ProposedAttemptEstimatedCost` | the upcoming attempt estimate (converted; null/unknown marked) |
| `ProjectedSpend` | actual + pending + proposed (per `IncludeEstimatedPendingCost`) |
| `ApplicableLimits` | per-scope limit rows (scope, limit, spend, projected, decision, reason codes, thresholds) |
| `WarningThresholds` | per-scope warn/block thresholds (amounts) |
| `Decision` | one of the 6 decisions |
| `ReasonCodes` | closed vocabulary |
| `RequiresHumanOverride` / `OverrideAllowed` | override state |
| `CurrencyUncertain` | a conversion was unavailable (controlled uncertainty) |
| `Purpose` | `AI_ATTEMPT` / `HUMAN_GATE` / `GOVERNANCE_WAIT` |
| `GeneratedAtUtc` | the **injected** evaluation timestamp (deterministic) |
| `Message` | human-readable summary |

## 5. Operations

- `Get-AiBudgetUsage -Attempts -Scope -ScopeKey -WindowStartUtc -WindowEndUtc -Currency ...`
  filters the DB-M17 records to a scope and sums spend **actual-preferred**
  (`ActualCost` else `EstimatedCost`), converting to the policy currency via an
  applicable DB-M16 exchange-rate record (no invented rates; unavailable
  conversion → `CurrencyUncertain`).
- `Get-AiProjectedSpend -Usage -ProposedAttemptCost -ProposedCostCurrency
  -IncludeEstimatedPendingCost ...` returns the projected total, clearly
  separating **actual incurred** from **estimated pending**.
- `Test-AiBudget -Policy -EvaluationTimestampUtc -Attempts -TaskId -ChangeId
  -SessionId -SessionWindowStartUtc -SessionWindowEndUtc -ProposedAttemptCost
  -ProposedCostCurrency -ProposedCostUnknown -Purpose -Configuration
  -ExchangeRate ...` evaluates every applicable limit; the strictest wins.
- `Test-AiBudgetOverride -Evaluation -OverrideReference -OverrideReason
  -OverrideTimestampUtc -OverrideScope -OverrideAmount ...` grants an override
  **only** on explicit evidence and policy permission.

### Decision precedence (Test-AiBudget)

1. Purpose is not `AI_ATTEMPT` → `ALLOW` (`HUMAN_GATE_ZERO_COST` /
   `GOVERNANCE_ZERO_COST`); no budget consumed.
2. No applicable limit → `NO_APPLICABLE_BUDGET`.
3. For each applicable limit: unknown cost (proposed unknown OR unconvertible
   spend) → per `UnknownCostPolicy` (ALLOW/WARN/BLOCK); else projected vs
   `WarnAtPercent` / `BlockAtPercent`.
4. Strictest wins: block (BLOCK_BUDGET_EXCEEDED / BLOCK_COST_UNKNOWN) >
   `ALLOW_WITH_WARNING` > `ALLOW`. When the strictest is a block and
   `AllowManualOverride` → `REQUIRE_HUMAN_OVERRIDE`.

### Escalation integration

`Test-AiBudget` never calls DB-M20. DB-M20 consumes the budget outcome later:
a budget block surfaces as `STOP_BUDGET_LIMIT`; DB-M21 never lets a retry bypass
the block. Example: attempts ₹3 + ₹8, proposed ₹30, TaskLimit ₹25 →
`BLOCK_BUDGET_EXCEEDED`; the next DB-M20 decision becomes `STOP_BUDGET_LIMIT`.

## 6. Currency

`Convert-DbM21ToPolicyCurrency` uses the supplied `ExchangeRate` when given,
else an applicable `Get-AiExchangeRateAt` record from the DB-M16 catalogue. No
FX engine is implemented. Unavailable conversion → `CurrencyUncertain`, surfaced
as controlled uncertainty (reason `CURRENCY_UNAVAILABLE`), decided per
`UnknownCostPolicy` — never an invented rate.

## 7. Deterministic windows

Day/month boundaries are computed from the **injected** `EvaluationTimestampUtc`
plus `AccountingUtcOffsetHours`: `dayStartUtc = (date of (ts+offset)) - offset`.
No machine-local clock is read inside the engine. Session windows are explicit
caller inputs. Reason `DETERMINISTIC_WINDOW` records the derivation.

## 8. Temporary DevBridge boundary

DB-M21 Part A: writes nothing; computes in memory only. It consumes DB-M16 cost
results, DB-M17 attempt records and DB-M20 decisions read-only. It has no
roadmap, workbook, Git, or execution capability.

## 9. Operations (see companion doc for fingerprint + combined)

`Get-AiBudgetUsage` · `Test-AiBudget` · `Get-AiProjectedSpend` ·
`Test-AiBudgetOverride`.
