# DB-M17 — AI Attempt / Usage History Foundation

**Milestone:** DB-M17 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-30

This document describes the implemented attempt-history foundation: the canonical **AiAttemptRecord v1**
and **AiAttemptHistory v1** contracts, the append-only store layout, the lifecycle operations, token-usage
rules, cost-field handling, and the query/aggregation foundation for DB-M24. Companion:
`DB-M17_FAILURE_TAXONOMY.md`.

**NO AUTOMATIC AI EXECUTION EXISTS YET.** No provider call, no model call, no routing, no pricing
calculation, no cost math, no escalation behavior. DB-M17 records **what happened** (or is happening) in
the existing manual workflow; it never decides, routes, or prices.

---

## 1. Hard constraints honored

| Constraint | Status |
|---|---|
| No pricing logic / no DB-M15 file touched | **NONE** — DB-M15 owns pricing; cost fields below are stored only |
| No DB-M12 UI file touched (`src/DevBridge.*`) | **NONE** |
| DB-M14 provider/model contracts unchanged | **YES** — read-only consumption via `Get-ContractProperty` |
| `Nexus.Developer` / workbook / Nexus repos | **UNTOUCHED** |
| No AI model execution / provider API calls | **YES** — test S28 proves no network/pricing tokens in the library |
| Manual workflow (ChatGPT → DeepSeek → DevBridge verification → Claude) | **PRESERVED** — the store records manual-mode attempts; it does not replace the loop |
| Complete prompts stored by default | **NO** — only `PromptHash` / `ContextHash` / `PromptArtifactReference` |
| Secrets stored | **NO** — a dedicated secret-value guard runs inside every record validation |

## 2. What DB-M17 provides

A per-change, append-oriented execution history for AI attempts that **DB-M12's UI can discover without
any database infrastructure** (plain JSON on disk), with structural validation, reference validation
against the frozen DB-M14 catalogues, lifecycle update operations, and deterministic aggregate queries
that DB-M24 will consume for usage intelligence / model recommendations. DB-M17 does **not** recommend
models (that is DB-M24).

## 3. Storage layout (lightweight JSON — no database)

```
logs/tasks/<NodeId>/<ChangeId>/ai-attempts/
    ATT-<ChangeId>-NNN.json        # canonical AiAttemptRecord v1, one file per attempt
    history.json                   # AiAttemptHistory v1 index (append-only id list + counts)
state/attempts/<ChangeId>/index.json   # discovery mirror (DB-M13/DB-M24 layout)
```

- The **canonical record** is the per-attempt file. It is the source of truth for the attempt.
- `history.json` is the append-only **id index** for one change. Its `AttemptIds` array is never
  reordered and never shrinks; a later successful attempt never erases earlier failed attempts.
- `state/attempts/<ChangeId>/index.json` is a **discovery mirror** for DB-M24 and the DB-M12 UI: it
  records `SchemaVersion`, `HistoryPath`, `AttemptCount`, the attempt ids, and `UpdatedAtUtc`, without
  duplicating record bodies. It is refreshed on every save.
- Path helpers: `Get-AiAttemptStoreDir`, `Get-AiAttemptHistoryPath`, `Get-AiAttemptRecordPath`,
  `Get-AiAttemptStateIndexPath`, `Resolve-AiAttemptRoot` (walks up to `config/ai-routing.json`).

## 4. AiAttemptRecord v1 — schema

`schemaVersion: 1`, frozen at DB-M17. Every field is present on the record; fields not yet known stay
`null` (**UNKNOWN**). 60 fields:

| Group | Fields |
|---|---|
| Schema | `SchemaVersion` (1) |
| Task identity | `TaskId`, `MilestoneId`, `WorkItemId`, `NodeId`, `ChangeId` |
| Attempt identity | `AttemptId` (`ATT-<ChangeId>-NNN`), `ParentAttemptId`, `RoutingDecisionId`, `RetryNumber` |
| Provider / model (DB-M14 refs) | `ProviderId`, `ModelId`, `UnderlyingModelId`, `GatewayProviderId` |
| Planning | `ReasoningLevel`, `TaskType`, `Complexity`, `Risk`, `ExecutionMode` |
| Timing | `StartedAtUtc`, `EndedAtUtc`, `DurationMs` |
| Token usage | `UsageSource`, `InputTokens`, `CachedInputTokens`, `CacheWriteTokens`, `OutputTokens`, `ReasoningTokens`, `ToolCalls` |
| Cost (stored only — DB-M16 prices) | `EstimatedCost`, `ActualCost`, `CostCurrency`, `ExchangeRate`, `PricingRecordId` |
| Result / failure | `Result`, `FailureCategory`, `VerificationResult`, `VerificationEvidencePath`, `EscalatedFromAttemptId`, `EscalatedToAttemptId`, `EscalationReason`, `ContradictoryStateEvidence` |
| Context | `ContextTokens`, `RawAvailableContextTokens`, `SelectedContextTokens`, `ContextReductionPercent` |
| Evidence | `FilesChanged`, `TestsPassed`, `TestsFailed`, `TestsSkipped` |
| Flags | `HumanIntervention`, `ManualOverride` |
| Sensitive-prompt protection | `PromptHash`, `ContextHash`, `PromptArtifactReference` |
| Free text | `Notes` |

Construction: `New-AiAttemptRecord`. **Unknown optional values stay `null`**: because PowerShell's
`[string]` parameter binding coerces `$null → ''`, the constructor normalizes empty strings back to
`$null` so the contract's UNKNOWN semantics survive serialization (`null`, never `""`).

## 5. AiAttemptHistory v1 — schema

```json
{
  "SchemaVersion": 1,
  "ChangeId": "CHG-20260901-001",
  "NodeId": "WI-07-0.2.4",
  "TaskId": "…",
  "MilestoneId": "…",
  "CreatedAtUtc": "…",
  "UpdatedAtUtc": "…",
  "AttemptIds": [ "ATT-…-001", "ATT-…-002" ]
}
```

## 6. Append-only semantics (immutable set, mutable record lifecycle)

- **Attempt SET is immutable.** A new attempt id is always **appended** to `history.AttemptIds`; ids are
  never removed, reordered, or backfilled. Proven by S4 (earlier failed attempts stay FAILED after a
  later success; all 5 ids preserved without duplicates).
- **Single-record lifecycle fields are updated in place** — status progression (`PENDING → RUNNING →
  SUCCESS/FAILED/…`) is a field update on the existing record, never a new record and never erasure.
  `Save-AiAttemptRecord` is idempotent for an existing id (lifecycle update) and rejects a duplicate
  **new** id.

## 7. Attempt identity: `ATT-<ChangeId>-NNN`

`New-AiAttemptId` computes `max(suffix)+1` over the change's existing attempt ids (zero-padded `:D3`;
a suffix above 999 widens naturally). An attempt id identifies **one AI execution attempt** — it never
reuses an Activity id or Change id. `Start-AiAttempt` auto-assigns the next number, or accepts an
explicit id and throws on collision (S24).

## 8. Lifecycle operations (no AI calls)

| Operation | Function | Behavior |
|---|---|---|
| Start | `Start-AiAttempt` | New `PENDING` record; auto `ATT-<ChangeId>-NNN`; `RetryNumber` = parent+1 when `ParentAttemptId` given, else 0; persists immediately |
| Usage | `Set-AiAttemptUsage` | Records token/tool usage **verbatim** with `UsageSource` `ACTUAL` or `ESTIMATED`; unknown → `UNKNOWN` and token fields stay null |
| Outcome | `Set-AiAttemptOutcome` | Sets `Result`, optional `FailureCategory`/`EndedAtUtc`/evidence counts; computes `DurationMs` from timestamps when not supplied |
| Verification | `Set-AiAttemptVerification` | Links `VerificationResult` + `VerificationEvidencePath` |
| Escalation | `Set-AiAttemptEscalation` | Sets `EscalatedFromAttemptId` / `EscalatedToAttemptId` + `EscalationReason`. **Records the link only** — DB-M17 never performs escalation |
| Human intervention | `Set-AiAttemptHumanIntervention` | Sets `HumanIntervention`, `ManualOverride`, free-text `Notes` |

All `Set-*` operations validate, persist, append to history, and refresh the state mirror via
`Save-AiAttemptRecord`.

## 9. Token usage rules (provider-reported vs estimated vs unknown)

- `UsageSource` vocabulary: **`ACTUAL | ESTIMATED | UNKNOWN`**.
- `ACTUAL` — token counts are provider-reported, stored verbatim (S15).
- `ESTIMATED` — token counts are estimates, explicitly marked, never relabeled as actual (S16).
- `UNKNOWN` — provider returned no usage; token/tool fields stay `null`. A record whose `UsageSource`
  is `UNKNOWN` but still carries token counts is **rejected** (S14) — the unknown condition is
  preserved, never silently treated as zero.
- All usage counts are validated non-negative (S26).

## 10. Cost fields — stored, never calculated

`EstimatedCost`, `ActualCost`, `CostCurrency`, `ExchangeRate`, `PricingRecordId` are **persisted
fields only**. DB-M17 stores whatever evidence the caller supplies and performs **no pricing math**
(test S28 proves the library contains no pricing-calculator tokens). Pricing computation is DB-M15/DB-M16
territory; `ExchangeRate` (when present) must be `> 0` (S26).

## 11. Verification linkage

`VerificationResult` vocabulary **`VERIFIED | FAILED | PENDING`** plus a `VerificationEvidencePath`
pointing at the DevBridge verification artifact — the same verification the manual workflow already
produces. The attempt history therefore documents the **ChatGPT → DeepSeek → DevBridge verification →
Claude** loop without reimplementing it.

## 12. Sensitive-prompt protection

- Complete prompts are **not** stored by default. Only `PromptHash` / `ContextHash` (SHA-256, validated
  as 64-hex when present — S25) and `PromptArtifactReference` (a pointer, never inline content).
- A dedicated secret-value guard, `Test-AiAttemptSecretLeak`, runs inside every `Test-AiAttemptRecord`
  call. Unlike the DB-M14 shared guard (which exempts `Notes` for provider records), the attempt guard
  **scans free-text fields** — `Notes`, `EscalationReason`, `ContradictoryStateEvidence` — and exempts
  structured identifiers, hashes, artifact refs, enums, numerics, and timestamps. A record carrying an
  API-key-shaped value fails validation (S25).

## 13. Validation rules (`Test-AiAttemptRecord`)

Structural validation returns `@{ Valid; Errors; Warnings }` and enforces:

- `AttemptId` required, unique within a change (save-time).
- Task identity present: `TaskId` or `ChangeId` required.
- `schemaVersion` must be `1`.
- Provider/model refs valid **when provided** (`Test-AiAttemptRecordReferences` against the frozen
  DB-M14 catalogues); unknown optional values stay null.
- `StartedAtUtc ≤ EndedAtUtc`; `DurationMs`, tokens, evidence counts, `RetryNumber` non-negative;
  `ContextReductionPercent` within 0–100; `ExchangeRate > 0`.
- No self-referencing `EscalatedFromAttemptId` / `EscalatedToAttemptId` / `ParentAttemptId`.
- **SUCCESS cannot carry a blocking `FailureCategory` without explicit evidence** — the additive
  `ContradictoryStateEvidence` field reconciles the contradiction; without it the record is rejected
  (S26).
- `UsageSource UNKNOWN` cannot carry usage counts.
- `PromptHash`/`ContextHash` must be 64-hex SHA-256 when present.
- Secret-like values rejected.
- Informational warning (not an error): a terminal `Result` without `EndedAtUtc`.

## 14. Query / aggregation foundation (for DB-M24)

Queries are read-only filters over the canonical records (ArrayList-based, deterministic):

| Function | Returns |
|---|---|
| `Get-AiAttemptsForChange` | all attempts of one change |
| `Get-AiAttemptsForTask` | attempts for a task across changes |
| `Get-AiAttemptsAll` | every attempt in the store |
| `Get-AiAttemptsByProvider` / `Get-AiAttemptsByModel` | attempts matching a provider / model |
| `Get-AiFailedAttempts` | failed + blocked attempts |
| `Get-AiAttemptAggregates` | `TotalAttempts`, `ByModel`, `ByResult`, `ByTaskType`, `FailuresByCategory`, `SuccessCount`, `FailureCount`, `FirstAttemptSuccessCount`, `EscalationCount`, `AverageDurationMs` |

These are exactly the dimensions DB-M24 needs (count by model, success/failure counts, by task type,
first-attempt success, escalation count, avg duration). **DB-M17 does not produce model
recommendations** — that remains DB-M24. S29 exercises the aggregates; S30 proves per-change isolation
in the store and the mirror.

## 15. Manual-workflow preservation

The store is **recording**, not driving. `ExecutionMode` defaults `MANUAL`, matches the active DB-M14
runtime policy, and the existing manual loop is untouched. Nothing in the store performs, routes, or
escalates an AI call.

## 16. Schema versioning (v1 freeze)

- `Get-AiAttemptSchemaVersions` → `@{ AiAttemptRecordVersion = 1; AiAttemptHistoryVersion = 1 }`.
  Registered in the DB-M17 library (not in DB-M14's `Get-AiRoutingSchemaVersions`) to avoid a
  parallel-file edit of the shared contracts file.
- **v1 frozen at DB-M17.** Additive optional fields are allowed within v1; any incompatible change
  (rename, retype, removed field, changed vocabulary meaning) requires a **v2** contract with its own
  schemaVersion and validator, per the DB-M14 freeze rules.
- Proof: S23 round-trips a persisted record through disk and re-reads it as schemaVersion 1 with all
  fields preserved (including `null` unknowns).

## 17. Parallel-safety

DB-M17 wrote **only** DB-M17-owned additive files: `scripts/ai-routing/AttemptStore.ps1`,
`scripts/ai-routing/Test-AttemptStore.ps1`, and this document + `DB-M17_FAILURE_TAXONOMY.md` +
`state/db-m17-result.json`. It read (never modified) the DB-M14 contracts/catalogues. DB-M15 files
(`AiPricingContracts.ps1`, `AiPricingTimeBands.ps1`, `AiRoutingPricingFoundation.ps1`,
`PricingCatalogue.ps1`), DB-M12 `src/` files, the workbook, and Nexus repositories were untouched.

## 18. Tests

`Test-AttemptStore.ps1` — **99 checks, all pass, 0 paid API calls.** Scenarios S1–S30: single success,
failure, three-attempt ending in success, append-preservation, cancelled, blocked, waiting-human,
budget-stopped, escalation links, retry numbering, failure-category validity, missing vs actual vs
estimated usage, human intervention / manual override, provider-model reference lookup, history by
task/change/model, schema v1 round-trip, duplicate-id rejection, secret leakage (Notes + escalation
reason + hashes), full validation rules, state-mirror discovery, no-network/no-pricing scan, aggregate
foundation, and per-change isolation.

---
*End of DB-M17 attempt-history doc. Failure taxonomy: `DB-M17_FAILURE_TAXONOMY.md`.*
