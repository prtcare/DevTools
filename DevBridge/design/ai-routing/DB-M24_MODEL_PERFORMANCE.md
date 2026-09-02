# DB-M24 — Model Performance Intelligence Foundation

**Lane:** B1 · **Predecessors:** DB-M14 (contracts/catalogues) · DB-M15 (pricing) · DB-M16 (cost/FX) · DB-M17 (attempt history) · **Blocked by:** none (read-only dependency on DB-M17)
**Status:** Implemented · **Schema:** ModelPerformanceSummary v1 · ModelComparison v1 · PerformanceRecommendation v1 · PerformanceQuery v1

---

## 1. Objective

Answer the nine questions the performance foundation must support, **descriptively and
non-bindingly**, from recorded attempt history:

1. Which models succeed most often? — `SuccessRate`, `SuccessCount/SampleCount`
2. First-attempt success? — `FirstAttemptSuccessRate`
3. How many retries are typical before success? — `AverageAttemptsPerSuccessfulTask`
4. Which models escalate? — `EscalationRate`
5. Duration (average / median / P95)? — `AverageDurationMs`, `MedianDurationMs`, `P95DurationMs`
6. Cost per attempt and cost per successful task (failed attempts included)? — `AverageCostPerAttempt`, `AverageCostPerSuccessfulTask`
7. Task-type / complexity / risk / reasoning-level performance? — dimension filters + group-by
8. Provider-route differences for the same underlying model? — `ModelRoute` grouping (provider | model | gateway)
9. Non-binding recommendation evidence? — `PerformanceRecommendation v1` (see companion doc)

**Learning rule (frozen):** historical intelligence is DESCRIPTIVE first and
RECOMMENDATION-ONLY after. DB-M24 never mutates routing policy — a future
policy-learning milestone requires a separate governed decision/gate. `PolicyVersion`
stays the immutable DB-M14 value `'0.0.0'`.

## 2. Scope

**DB-M24 owns:** historical AI performance aggregation, success-rate analytics,
attempt-count analytics, first-attempt success, escalation-rate analytics, duration
analytics, cost-performance statistics, task-type/model performance summaries,
recommendation evidence.

**DB-M24 does NOT own (never modified):** DB-M18 classification/context
(`ContextPackage.ps1`, `TaskClassification.ps1`), DB-M19 routing decisions,
DB-M20 escalation execution, DB-M21 budget enforcement, DB-M15 pricing catalogue,
DB-M16 cost engine, DB-M17 attempt persistence, DB-M12 UI, Nexus source, the
Development Control workbook.

**Shared contracts:** DB-M24 reads DB-M14/DB-M15/DB-M16/DB-M17 contracts read-only.
Schema versions are registered in `Get-AiPerformanceSchemaVersions`
(DB-M24-owned), never in the shared files. If a shared contract change were ever
required the milestone would stop with `SHARED_CONTRACT_CHANGE_REQUIRED`.

## 3. Architecture

```
config/performance/confidence-bands.json   sample-confidence thresholds (configurable)
scripts/ai-routing/performance/
  AiPerformanceContracts.ps1               frozen v1 contracts + vocabularies
  ModelPerformance.ps1                     aggregation engine + operations
  AiPerformanceFoundation.ps1              dot-source chain + Import/Validate
  Test-AiModelPerformance.ps1              34-scenario test suite
```

The engine dot-sources `../AttemptStore.ps1` **read-only** (brings DB-M14 helpers +
DB-M17 attempt vocabulary) and the local contract/engine libraries. No database is
created: every metric is recomputed from the attempt records passed in. An optional
rebuildable cache is **designed but not implemented** (see §11).

No AI API calls, no provider calls, no paid calls, no network, no credentials, no
writes to history or routing configuration.

## 4. Data model — attempt chains

An *attempt chain* is one task's set of attempts, reconstructed from DB-M17 fields:

- **Task identity:** `ChangeId` when present, else `TaskId`, else the `(untracked)` bucket.
- **Chain order:** `RetryNumber` asc, then `StartedAtUtc` asc, then `AttemptId` asc.
- **Terminal attempt:** the last attempt in chain order whose `Result` is terminal
  (SUCCESS / FAILED / CANCELLED / ESCALATED / BLOCKED / BUDGET_STOPPED).
- **Escalation links:** `EscalatedFromAttemptId` / `EscalatedToAttemptId` /
  `EscalationReason`; a chain is *escalated* if any attempt carries either link or
  `Result = ESCALATED`. **Analyzed from recorded history only; never executed.**
- **Human intervention:** `HumanIntervention = true` on any attempt.

A chain with no terminal attempt is *incomplete*: counted in `IncompleteCount`,
excluded from `SampleCount` and outcome metrics, never silently dropped.

## 5. Success definition and first-attempt success

A chain succeeds according to the query's `SuccessDefinition`:

| Definition        | SUCCESS requires |
|-------------------|------------------|
| `VERIFIED`        | `Result=SUCCESS` **and** `VerificationResult=VERIFIED` |
| `MODEL_RETURNED`  | `Result=SUCCESS` (verification ignored) |
| `VERIFIED_PREFERRED` (default) | verification evidence is authoritative when present: a `FAILED` verification contradicts the model's SUCCESS claim and the task is **not** a success; `VERIFIED`/`PENDING`/absent count as model-returned success |

**Rule:** a model response claiming PASS must not automatically count as a verified
success when verification evidence exists and contradicts it. `VerifiedSuccessCount`
and `ModelReturnedSuccessCount` are reported separately and transparently.

**First-attempt success** = the chain's *first* attempt succeeded under the same
success definition (attempt #1 in chain order, verification applied where applicable).

## 6. Cost per successful task

- A successful task's cost is the **sum of the usable cost evidence of every attempt
  in its chain** — failed attempts included (Task A ₹1 FAIL + ₹1 FAIL + ₹4 PASS → cost
  **₹6**, not ₹4). `AverageCostPerSuccessfulTask` is the mean over successful tasks;
  `AverageCostPerAttempt` is the per-attempt mean (₹2 in that example).
- **Actual cost is preferred.** `EstimatedCost` is used only when the query explicitly
  sets `AllowEstimatedCostFallback = true`, and that fallback is clearly labelled
  (`EstimatedCostFallbackUsed`, warning text). `AverageActualCost` and
  `AverageEstimatedCost` are reported separately.
- **Currency:** cross-attempt aggregation happens in the query's `ReportingCurrency`
  (default INR). Only cost evidence **already stored in that currency** is reused;
  historic evidence is **never re-converted with today's exchange rate**. Attempts
  whose cost currency differs (or whose cost is missing, or estimated-only with
  fallback disabled) are **excluded from cost metrics and recorded in `Warnings`**
  (`currencyMismatch` / `missingCost` / `fallbackDisabled` → `CostExcludedCount`).
- DB-M24 **never recalculates pricing** — DB-M16 stored cost fields are consumed
  read-only.

## 7. Failure-category separation

Failure categories reuse the DB-M17 taxonomy (MODEL_QUALITY, PROVIDER_AVAILABILITY,
RATE_LIMIT, AUTHENTICATION, TOOL_FAILURE, BUILD_FAILURE, TEST_FAILURE,
CONTEXT_FAILURE, BUDGET_FAILURE, VALIDATION_FAILURE, UNKNOWN). A provider outage
**never reduces a model's intellectual-quality score**:

- `ModelQualityFailureCount` = MODEL_QUALITY only.
- `ProviderFailureCount` = PROVIDER_AVAILABILITY + RATE_LIMIT + AUTHENTICATION
  (delivery-path failures).
- Build/test/context/budget failures and the remaining categories are reported
  individually; `OtherFailureCount` covers TOOL_FAILURE + VALIDATION_FAILURE + UNKNOWN.
- A non-SUCCESS attempt without a category is counted honestly as UNKNOWN.
- `Get-AiFailureDistribution` returns the full per-category distribution.

## 8. Time windows, dimensions, confidence

- **Windows:** ALL_TIME, LAST_7_DAYS, LAST_30_DAYS, LAST_90_DAYS, CUSTOM UTC range.
  Resolved against a caller-supplied `NowUtc` (deterministic tests) or UtcNow.
  Window semantics on `StartedAtUtc`: `[FromUtc, ToUtc)` — the To instant is exclusive.
- **Dimensions (filters and group-by):** ProviderId, ModelId, UnderlyingModelId,
  GatewayProviderId, TaskType, Complexity, Risk, ReasoningLevel, ExecutionMode
  (case-insensitive). VerificationResult and FailureCategory are supported as
  **filters** but not group-by keys.
- **Confidence:** `SampleCount` (number of terminal tasks) maps to a level through
  configurable bands (`config/performance/confidence-bands.json`, default
  INSUFFICIENT <5 · LOW 5–19 · MODERATE 20–49 · HIGH 50+). A small sample is never
  treated as statistically equivalent to a large one; LOW/INSUFFICIENT carry a warning
  and are gated out of recommendations by `MinimumConfidenceLevel`.

## 9. Aggregation rules

- **Task-level metrics** (SampleCount, SuccessCount, FailureCount, first-attempt,
  escalation, human intervention, attempts-per-success, cost-per-success,
  LastAttemptAtUtc) are attributed to the **terminal attempt's group**.
- **Attempt-level metrics** (duration, tokens, per-attempt cost, failure-category
  counts) are attributed to **each attempt's own group**.
- **Outliers:** mean/median/P95 are all reported from the full sample; outliers are
  never silently deleted (`OutlierHandling = NONE` is the only mode; future filtering
  must be explicit and opt-in).
- **No single opaque "AI score":** summaries expose transparent component metrics.

## 10. Operations

`Get-AiModelPerformance` · `Compare-AiModelPerformance` (ranked presentation, never a
winner) · `Get-AiTaskTypePerformance` · `Get-AiFailureDistribution` ·
`Get-AiCostPerSuccessfulTask` · `Get-AiFirstAttemptSuccessRate` ·
`Get-AiEscalationRate` · `Get-AiPerformanceRecommendation`.

## 11. Persistence and performance cache

No database. Metrics are always derived from DB-M17 attempt history. A disposable
cache summary artifact was **designed but intentionally not implemented** in DB-M24:
any future cache must be schema-versioned, clearly derived, never a source of truth,
and carry `GeneratedAtUtc`, `SourceAttemptCount`, `SourceHistoryHash`,
`QueryDimensions`, `SchemaVersion`; it becomes stale when the source history changes.

## 12. Schema versioning

ModelPerformanceSummary v1, ModelComparison v1, PerformanceRecommendation v1,
PerformanceQuery v1 are frozen. Future incompatible changes require v2 with their own
validators; v1 semantics are never silently mutated.

## 13. What DB-M24 deliberately does not do

- **DB-M25** (quality-adjusted savings) is NOT implemented: no quality scoring,
  no retry-burden weighting, no baseline comparison, no savings calculation.
- No automatic routing / policy mutation (`PolicyVersion` stays `'0.0.0'`).
- No escalation execution; no pricing calculation; no attempt persistence writes.
