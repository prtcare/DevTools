# DB-M17 — Failure Taxonomy for AI Attempt History

**Milestone:** DB-M17 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-30

This document defines the **shared vocabulary** DB-M17 uses to classify the outcome of one AI execution
attempt and the rules that keep the recorded state internally consistent. It is the companion to
`DB-M17_ATTEMPT_HISTORY.md` and is consumed by DB-M19 (routing), DB-M22 (health/failover), and DB-M24
(usage intelligence / model recommendations).

**DB-M17 classifies and records; it does not act on failure.** No retry, no failover, no escalation
behavior is implemented here — only the taxonomy and the history records that make those behaviors
legible later.

---

## 1. Result states (attempt lifecycle)

`Get-AiAttemptResultStates`:

```text
PENDING  RUNNING  SUCCESS  FAILED  CANCELLED  ESCALATED  BLOCKED  WAITING_HUMAN  BUDGET_STOPPED
```

- **PENDING** — created (`Start-AiAttempt`), not yet run.
- **RUNNING** — in progress (recorded by the executor, a future milestone; vocabulary valid today).
- **SUCCESS** — attempt completed acceptably.
- **FAILED** — attempt completed but did not meet the acceptance bar; carries a `FailureCategory`.
- **CANCELLED** — attempt was stopped before a result (human or operator decision, no failure).
- **ESCALATED** — attempt was handed up (e.g. model insufficient → premium model). The escalation is a
  **link** (`EscalatedFromAttemptId` / `EscalatedToAttemptId` + `EscalationReason`), not a behavior.
- **BLOCKED** — attempt could not run because a precondition was not met (e.g. provider unavailable).
- **WAITING_HUMAN** — attempt is paused awaiting human review/decision (transitional, not terminal).
- **BUDGET_STOPPED** — attempt stopped by a budget guard (recorded; enforcement is DB-M16's territory).

## 2. Terminal vs transitional states

`Get-AiAttemptTerminalStates`:

```text
SUCCESS  FAILED  CANCELLED  ESCALATED  BLOCKED  BUDGET_STOPPED
```

- **Terminal** states are finished — no further lifecycle writes are expected. `PENDING`, `RUNNING`,
  and `WAITING_HUMAN` are **transitional**.
- Validation: a terminal result without `EndedAtUtc` produces a **warning** (informational, not an
  error) because a terminal attempt should carry an end timestamp. `WAITING_HUMAN` needs no end time
  (proven by S7).
- The taxonomy keeps `ESCALATED` and `FAILED` distinct: an attempt that failed on one model and was
  escalated to another records the failure on the parent (`FAILED` + category + `EscalatedToAttemptId`)
  and the escalation on the child (`ESCALATED`/`SUCCESS` + `EscalatedFromAttemptId`).

## 3. Failure categories

`Get-AiAttemptFailureCategories`:

| Category | Meaning (recorded condition, not an action) |
|---|---|
| `MODEL_QUALITY` | model output did not meet the acceptance bar |
| `PROVIDER_AVAILABILITY` | provider outage / unavailability |
| `RATE_LIMIT` | provider rate limiting (transient) |
| `AUTHENTICATION` | credential / auth failure |
| `TOOL_FAILURE` | a tool/tool-call failed during the attempt |
| `BUILD_FAILURE` | build (compile) failed |
| `TEST_FAILURE` | verification tests failed |
| `CONTEXT_FAILURE` | context limit / context-selection failure |
| `BUDGET_FAILURE` | budget guard triggered (recorded only — enforcement is DB-M16) |
| `VALIDATION_FAILURE` | the attempt's inputs or produced artifacts failed validation |
| `UNKNOWN` | failure occurred but no category is known |

Rules:

- Categories are **distinct and non-conflated** — e.g. `PROVIDER_AVAILABILITY` is never reported as
  `MODEL_QUALITY` (proven by S11/S12).
- A category is only valid on a **non-SUCCESS** outcome; `FailureCategory` on a `SUCCESS` record is
  treated as a contradiction that requires explicit evidence (see §5).
- Unknown failure conditions are recorded honestly as `UNKNOWN` — never guessed (consistent with the
  DB-M14 rule that unverified capability metadata stays `null`).

## 4. Escalation model

- `Set-AiAttemptEscalation` records `EscalatedFromAttemptId` (the parent that failed) and
  `EscalatedToAttemptId` (the child that took over), plus `EscalationReason` free text.
- **Self-references are rejected** — an attempt cannot be its own escalation source, target, or parent
  (S26). Cross-references to ids in the same change are the only valid shape (S9).
- `RetryNumber` on a parent-chained attempt = parent's `RetryNumber + 1` (S10), so the retry chain is
  reconstructable for first-attempt-success and escalation-count metrics.

## 5. Contradictory-state evidence (SUCCESS carrying a blocking failure)

The frozen constraint is: **a SUCCESS cannot silently carry a blocking failure state.** Two readings
are reconciled with the additive `ContradictoryStateEvidence` field:

- `Result = SUCCESS` with a `FailureCategory` and **no** `ContradictoryStateEvidence` → **rejected**
  (S26). A success record that also reports a blocking failure category is internally contradictory.
- `Result = SUCCESS` with a `FailureCategory` **and** `ContradictoryStateEvidence` explaining the
  reconcile (e.g. *"rate limit observed once on a retried request but the final call succeeded"*) →
  **accepted** (S26). The evidence preserves the historical condition while the final state is success.

This keeps history append-oriented and truthful: the transient failure is never erased, it is
**explained**.

## 6. Usage-source semantics (actual vs estimated vs unknown)

`Get-AiAttemptUsageSources`:

- **ACTUAL** — provider-reported token/tool usage, stored verbatim.
- **ESTIMATED** — a projection, explicitly marked, never relabeled as actual.
- **UNKNOWN** — provider returned no usage; token fields stay `null`. `UNKNOWN` carrying counts is
  rejected (S14) so the unknown condition is preserved and not silently treated as zero.

Usage-source is independent of the result state: a `SUCCESS` may carry `ACTUAL`, `ESTIMATED`, or
`UNKNOWN` usage; an `ESTIMATED` attempt is never promoted to `ACTUAL` retroactively without a real
provider report (S16).

## 7. Verification linkage

`Get-AiAttemptVerificationResults`:

```text
VERIFIED  FAILED  PENDING
```

`VerificationEvidencePath` points at the DevBridge verification artifact. This is the same
verification the manual workflow produces — DB-M17 documents it, it does not re-run it. `PENDING`
verification is a valid transitional value.

## 8. Failure-taxonomy validation rules

Enforced by `Test-AiAttemptRecord` (structural) + `Test-AiAttemptRecordReferences` (catalogue refs):

1. `Result`, `FailureCategory`, `UsageSource`, `VerificationResult` must be vocabulary members.
2. `FailureCategory` valid only with a non-SUCCESS result **unless** evidence is present (§5).
3. `UNKNOWN` usage cannot carry token/tool counts (§6).
4. Escalation/parent ids cannot self-reference (§4).
5. A terminal result should carry `EndedAtUtc` (warning).
6. `StartedAtUtc ≤ EndedAtUtc`; durations, tokens, counts, and `RetryNumber` non-negative.
7. Provider/model ids, when present, must resolve against the frozen DB-M14 catalogues; unknown
   optional values stay `null`.
8. `EscalationReason` / `Notes` / `ContradictoryStateEvidence` are free text and therefore **scanned**
   by the secret-value guard — a leaked token in a failure note is rejected (S25).

## 9. DB-M24 consumption mapping

The taxonomy feeds DB-M24's aggregate dimensions directly (`Get-AiAttemptAggregates`):

| DB-M24 need | DB-M17 field(s) |
|---|---|
| Count by model | `ModelId` → `ByModel` |
| Success / failure counts | `Result` → `ByResult`, `SuccessCount`, `FailureCount` |
| By task type | `TaskType` → `ByTaskType` |
| First-attempt success | `RetryNumber = 0` + `Result = SUCCESS` → `FirstAttemptSuccessCount` |
| Escalation count | `EscalatedToAttemptId` present → `EscalationCount` |
| Avg duration | `DurationMs` → `AverageDurationMs` |
| Failure-cause breakdown | `FailureCategory` → `FailuresByCategory` |

---
*End of DB-M17 failure taxonomy. History/schema: `DB-M17_ATTEMPT_HISTORY.md`.*
