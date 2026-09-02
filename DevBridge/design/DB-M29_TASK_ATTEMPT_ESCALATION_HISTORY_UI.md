# DB-M29 -- TASK COST, ATTEMPT & ESCALATION HISTORY UI: Design

Date: 2026-09-01  |  Lane B  |  Status: DESIGN

Temporary DevBridge scaffolding for Nexus Phase 1/2. DevBridge is NOT part of
Nexus. Nothing implemented in DB-M29 is intended for migration into Nexus. Do
NOT design DB-M29 for Nexus migration.

---

## 0. DB-M29 DISCOVERY (printed before coding)

DISCOVERY FIRST -- inspected before any DB-M29 code was written. Every listed
foundation was read READ-ONLY; the reusable identifiers below were confirmed to
exist on the live tree.

| Foundation | Reusable surface inspected |
|------------|----------------------------|
| **DB-M17** attempt/usage history | `AiAttemptRecord v1` (60-field): TaskId, ChangeId, NodeId, AttemptId `ATT-<ChangeId>-NNN`, RetryNumber, ParentAttemptId, EscalatedFromAttemptId, EscalatedToAttemptId, EscalationReason, StartedAtUtc, EndedAtUtc, ProviderId, ModelId, UnderlyingModelId, GatewayProviderId, LocalOrRemote, ReasoningLevel (NONE\|LOW\|MEDIUM\|HIGH\|MAX), TaskType, ExecutionMode, Result (PENDING/RUNNING/SUCCESS/FAILED/CANCELLED/ESCALATED/BLOCKED/WAITING_HUMAN/BUDGET_STOPPED), FailureCategory (11-member), FailureFingerprintId, VerificationResult (VERIFIED/FAILED/PENDING), ClaudeReviewStatus (NONE/PENDING/PASS/FIX_REQUIRED), EstimatedCost, ActualCost, UsageSource (ACTUAL/ESTIMATED/UNKNOWN), Currency, HumanIntervention, tokens, DurationMs. Query layer: Get-AiAttemptsForChange/ForTask/All/ByProvider/ByModel, Get-AiFailedAttempts, Get-AiAttemptAggregates. `Get-AiAttemptStoreDir` = logs\tasks\<node>\<change>\ai-attempts; `Get-AiAttemptStateIndexPath` = state\attempts\<changeId>\index.json. **On-disk store is EMPTY today** (only per-change stage artifacts exist under logs/tasks/WI-07-0.2.3/CHG-20260830-016 and WI-07-0.2.4/CHG-20260830-017); the UI consumes the DB-M17 query layer honestly and shows an empty state rather than inventing history. |
| **DB-M20** retry/escalation decisions | `EscalationChain v1` (`New-EscalationChain -Attempts -TaskId -NodeId -ChangeId -ChainId`, ChainId=`CHAIN-<taskId>`, orders by RetryNumber, TerminalAttempt, TerminalOutcome, EscalationEvents, LoopFree, LoopReason). `EscalationDecision v1` (DecisionId, Action, NextProviderId/ModelId/ReasoningLevel, ReasonCodes, Explanation, RequiresHuman, HumanActionType, CumulativeActualCost/EstimatedCost, DecisionTimestampUtc). `EscalationInput v1`. Vocabularies: Get-DbM20Actions (RETRY_SAME_ROUTE, RETRY_SAME_MODEL_HIGHER_REASONING, SWITCH_MODEL, SWITCH_PROVIDER_ROUTE, REBUILD_CONTEXT, CORRECT_CURRENT_ATTEMPT, REQUEST_MISSING_CONTEXT, STOP_SUCCESS, STOP_NO_ELIGIBLE_ESCALATION, STOP_BUDGET_LIMIT, STOP_GOVERNANCE, HUMAN_*), Get-DbM20ReasonCodes (SUCCESS_VERIFIED, VERIFICATION_FAILED, CLAUDE_REVIEW_FIX, RETRY_TRANSIENT, BUDGET_CEILING_REACHED, GOVERNANCE_BLOCKED, REASONING_ESCALATION, MODEL_ESCALATION, CORRECT_CURRENT_ATTEMPT, ...), Get-DbM20DecisionStatuses, Get-DbM20ContextActions, Get-DbM20HumanActionTypes. |
| **DB-M21** budget decisions + failure fingerprints | Budget decision vocab: ALLOW, ALLOW_WITH_WARNING, BLOCK_BUDGET_EXCEEDED, BLOCK_COST_UNKNOWN (+ more). `FailureFingerprint v1` (`New-FailureFingerprint`): FingerprintId `FP-<ver>-<16hex>`, Signature SHA-256, TaskType, FailureCategory, NormalizedFailureCodes sorted/deduped, route identity (ModelId/UnderlyingModelId/ProviderId/GatewayProviderId/ReasoningLevel/ContextHash/ToolCategory), OccurrenceCount, AttemptIds, FirstSeenUtc/LastSeenUtc. Recurrence vocab: FIRST_OCCURRENCE, REPEATED_SAME_ROUTE, REPEATED_SAME_MODEL, REPEATED_SAME_FAILURE, REPEATED_AFTER_REASONING_ESCALATION, REPEATED_AFTER_MODEL_SWITCH, KNOWN_FAILURE_RESOLVED. Get-DbM21RepeatSuppressionReasons, Get-DbM21ToolCategories, Get-DbM21FingerprintSecretLeak. |
| **DB-M22** provider health/failure evidence | `ProviderHealthEvidence v1` (ProviderId, RouteId, GatewayProviderId, UnderlyingModelId, ObservedState = DB-M14 health states AVAILABLE/RATE_LIMITED/DEGRADED/AUTH_ERROR/UNAVAILABLE/DISABLED/UNKNOWN, EvidenceType, FailureCategory (DB-M20 vocab), HttpStatusClass, RetryAfterUtc, AttemptIdReference, Confidence). Circuit vocab: CLOSED/OPEN/HALF_OPEN. Health reason codes vocabulary. |
| **DB-M23** provider/gateway/underlying-model identity | Price statuses: CONFIGURED, FREE, LOCAL_COST_UNKNOWN, PRICE_UNKNOWN. DB-M23 error category -> DB-M20 failure category map (AUTHENTICATION/RATE_LIMIT/PROVIDER_UNAVAILABLE->PROVIDER_AVAILABILITY/TIMEOUT/INVALID_OUTPUT/CONTEXT_TOO_LARGE/TOOL_FAILURE/UNKNOWN_FAILURE). Route identity never collapses gateway vs underlying model. Secret-leak guard + redaction helpers. |
| **DB-M24** performance intelligence | `Resolve-AiTaskChains -Records` (group by task key, order RetryNumber/StartedAtUtc/AttemptId). `Resolve-AiChainFacts -Chain -SuccessDefinition` (terminal attempt, outcome, first-attempt success, escalation, human intervention, last-attempt instant). `ModelPerformanceSummary v1` (EscalationCount, HumanInterventionCount, FailureCategoryCounts, VerifiedSuccessCount, ...). Confidence bands (INSUFFICIENT/LOW/MODERATE/HIGH). |
| **DB-M25** quality-adjusted cost/savings | `Resolve-DbM25VerifiedSuccess -Attempt -SuccessDefinition` (authoritative verified-success semantics: Result=SUCCESS AND VerificationResult=VERIFIED; FAILED contradicts a self-PASS; review gate). `Resolve-DbM25RecordCost -Record -ReportingCurrencyUpper -AllowEstimatedFallback` (DB-M16 semantics: ActualCost preferred, EstimatedCost labelled). `Get-DbM25ChainCost`, `Get-DbM25FilteredAttempts`. |
| **DB-M26** dashboard attempt/chain views | `Get-DbM26ChainView` (per-chain rows + per-attempt cumulative cost), `Get-DbM26AttemptHistory` (chronological rows), `Get-DbM26VerifiedSuccessView`, `Get-DbM26RecordCost`. Dashboard is the CROSS-TASK aggregate; DB-M29 is the PER-TASK drilldown and reuses the same record/chains/cost foundations instead of duplicating a database or formula. |
| **DB-M27** cost-calculator presentation | `Export-DbM27CalculatorHtml` pattern: self-contained HTML (inline CSS/JS, embedded JSON), UTF8 no-BOM WriteAllText as the operator-requested artifact, library performs no other writes. |
| **DB-M28** model-config presentation | `New-DbM28ModelConfigurationView -Configuration $cfg` fixture-injection pattern; self-contained HTML renderer; ReadOnlyGuard (AUTO_EXECUTION_ENABLED=FALSE, paid calls 0, network calls 0); `Test-DbM28SecretLeak`; `Out-DbM28Markers` (backend always exits 0, outcomes via stdout markers). |
| **UI shell / navigation** | Lane C operator console (`MainViewModel` / `MainWindow`) surfaces per-stage artifact evidence; the Lane B analysis UIs (DB-M26/27/28) are standalone self-contained HTML artifacts surfaced to the operator. DB-M29 follows the same delivery shape. |

**Reusable identifiers confirmed:** attempt contracts (AiAttemptRecord v1), chain IDs (CHAIN-<taskId>), task IDs (TaskId/ChangeId/NodeId on each record), provider/model IDs (ProviderId/ModelId/UnderlyingModelId/GatewayProviderId), verification states (VERIFIED/FAILED/PENDING + ClaudeReviewStatus), failure categories (DB-M17/DB-M20 11-member vocabulary), cost calculations (DB-M16 semantics via DB-M25 Resolve-DbM25RecordCost), correction relationships (ParentAttemptId / ClaudeReviewStatus=FIX_REQUIRED / DB-M20 CORRECT_CURRENT_ATTEMPT), escalation relationships (EscalatedFromAttemptId/EscalatedToAttemptId/EscalationReason + DB-M20 EscalationDecision + New-EscalationChain).

**Do not create a second attempt-history database:** DB-M29 owns NO persistence. Its engine is pure (takes records/decisions/fingerprints as parameters and returns a view). The only write in the entire library is `Export-DbM29TaskHistoryHtml` writing the operator-requested HTML artifact (the same pattern as DB-M27/DB-M28).

---

## 1. Primary objective

Build an operator-facing UI that shows the COMPLETE AI execution history of a
task across attempts, retries, corrections, escalations, provider failures,
model-quality failures, budget decisions and verification outcomes. The operator
must be able to understand, for any task:

- **WHAT WAS TRIED?** -- ordered attempt timeline: provider, model, reasoning.
- **WHY DID IT FAIL?** -- failure category, failure fingerprint, verification.
- **WHY DID DEVBRIDGE RETRY OR ESCALATE?** -- transition arrows + DB-M20 action +
  reason codes + explanation.
- **HOW MUCH DID EACH ATTEMPT COST?** -- per-attempt actual vs estimated cost.
- **WHAT WAS THE TOTAL COST?** -- task total actual + total estimated.
- **WHICH ATTEMPT FINALLY PASSED VERIFICATION?** -- terminal verified-success
  marker on the winning attempt.

AUTO_EXECUTION_ENABLED = FALSE. 0 paid calls, 0 network calls, no secrets stored,
no AI execution, no attempt-history mutation, no workbook/state writes.

---

## 2. Boundary and reuse map

DB-M29 **reuses (does NOT rebuild)** the DB-M14..M28 chain READ-ONLY:

| Foundation | DB-M29 relationship |
|------------|---------------------|
| DB-M14 | route/health vocabularies + `Get-ContractProperty` (READ-ONLY). |
| DB-M16 | cost semantics -- every cost figure resolves via `Resolve-DbM25RecordCost` (DB-M16 authority); DB-M29 never recomputes a cost formula. |
| DB-M17 | attempt record contracts + vocabulary + query layer -- the ONLY attempt-history source. DB-M29 never writes an attempt record. |
| DB-M19 | routing eligibility vocab (NOT invoked -- history is display only; hard capability gate untouched). |
| DB-M20 | `New-EscalationChain` + EscalationDecision/Input contracts + action/reason-code vocabularies -- the timeline's "WHY RETRY/ESCALATE" evidence. |
| DB-M21 | budget decision vocab + `FailureFingerprint v1` + recurrence vocabulary -- the timeline's failure-fingerprint + budget-stop evidence. |
| DB-M22 | `ProviderHealthEvidence v1` shape + health vocab -- optional provider-failure context per attempt. |
| DB-M23 | price-status vocab + error-category map (route identity never collapsed). |
| DB-M24 | `Resolve-AiTaskChains`/`Resolve-AiChainFacts` -- task grouping, chain ordering, task facts. |
| DB-M25 | `Resolve-DbM25VerifiedSuccess` (authoritative) + `Resolve-DbM25RecordCost` (DB-M16 semantics) -- verified-success state + cost resolution. |
| DB-M26 | aggregate dashboard -- DB-M29 is the per-task drilldown; no duplicate analytics. |
| DB-M27 | renderer pattern only (self-contained HTML artifact). |
| DB-M28 | renderer pattern + ReadOnlyGuard + secret-leak guard + markers. |

DB-M29 **owns** (under `scripts/ai-routing/task-history/` only):
`HistoryContracts.ps1`, `HistoryEngine.ps1`, `HistoryRender.ps1`,
`Test-DbM29TaskHistory.ps1` + design/state/tasks outputs. **NO
PARALLEL_SCOPE_CONFLICT** with any other lane.

---

## 3. Contracts (HistoryContracts.ps1)

- `Get-DbM29SchemaVersions` -- TaskHistoryQuery/TaskHistoryView/TaskHistoryRow/
  AttemptTimelineNode/TimelineTransition/ReadOnlyGuard all v1.
- `Get-DbM29TransitionTypes` -- the timeline-arrow vocabulary, driven by record
  evidence + DB-M20 vocab:
  `RETRY`, `RETRY_SAME_MODEL_HIGHER_REASONING`, `SWITCH_MODEL`,
  `SWITCH_PROVIDER_ROUTE`, `REBUILD_CONTEXT`, `CORRECTION`,
  `CORRECTION_CLAUDE_REVIEW_FIX`, `BUDGET_STOP`, `HUMAN_REVIEW`,
  `GOVERNANCE_STOP`, `VERIFIED_SUCCESS`, `FAILED_NO_RETRY`.
- `Get-DbM29TaskRowSortBys` -- `TASK_ID | TOTAL_COST | ATTEMPT_COUNT`.
- `Get-DbM29VerifiedStates` -- `VERIFIED_SUCCESS | CONTRADICTED | MODEL_RETURNED |
  INCOMPLETE | NO_ATTEMPTS` (labels only; the underlying truth is DB-M25
  `Resolve-DbM25VerifiedSuccess`).
- `Get-DbM29FirstAttemptSuccessValues` -- `YES | NO | UNKNOWN`.
- `New-DbM29TaskHistoryQuery` / `Test-DbM29TaskHistoryQuery` -- QueryId, NowUtc,
  Currency (INR), SuccessDefinition (DB-M24 vocab), optional TaskId/ProviderId/
  ModelId filters, AllowEstimatedCostFallback, SortBy/SortDirection.
- `New-DbM29TaskHistoryRow` -- the brief's TASK HISTORY fields: TaskId, NodeId,
  ChangeId, Mode (ExecutionMode, `(none)` when absent), AttemptCount,
  TotalActualCost, TotalEstimatedCost, VerifiedState, FirstAttemptSuccess,
  FinalProviderId, FinalModelId, FinalUnderlyingModelId, FinalGatewayProviderId,
  FinalReasoningLevel, CorrectionsCount, EscalationsCount, FailureCount,
  FirstAttemptId, TerminalAttemptId, ChainId, LoopFree, Timeline (attempts).
- `New-DbM29AttemptTimelineNode` -- Seq, AttemptId, RetryNumber, ParentAttemptId,
  EscalatedFromAttemptId, EscalatedToAttemptId, EscalationReason, ProviderId,
  ModelId, UnderlyingModelId, GatewayProviderId, ReasoningLevel, Result,
  FailureCategory, FailureFingerprintId, FailureFingerprint (optional object),
  VerificationResult, ClaudeReviewStatus, EstimatedCost, ActualCost, CostSource
  (ACTUAL/ESTIMATED/none), CostAmount (resolved), CumulativeCost, DurationMs,
  InputTokens, OutputTokens, ContextTokens, HumanIntervention,
  TimestampUtc (StartedAtUtc, else EndedAtUtc), IsTerminal, VerifiedState,
  Transition (TimelineTransition to THIS node).
- `New-DbM29TimelineTransition` -- FromAttemptId, ToAttemptId, Type, Action
  (DB-M20 action or ''), ReasonCodes (DB-M20 vocab), Explanation, DecisionId,
  RequiresHuman, HumanActionType. When no transition applies (first node or a
  single-attempt task): Type `START` / `VERIFIED_SUCCESS` / `FAILED_NO_RETRY` per
  the terminal state.
- `New-DbM29ReadOnlyGuard` -- AutoExecutionEnabled=FALSE, PaidApiCalls=0,
  NetworkCalls=0, AttemptStoreModified=NO, EscalationDecisionsModified=NO,
  BudgetPolicyModified=NO, FingerprintsModified=NO, SecretValuesDisplayed=NO,
  SecretValuesLogged=NO.
- `Test-DbM29SecretLeak` -- the shared secret-material scan (M23/M28 pattern;
  exempts identifier/reference fields, scans free text) applied to every HTML
  output and every view node.
- `Out-DbM29Markers` -- backend contract: always exits 0, outcomes only via
  stdout markers (`DB29_OUTCOME` / `DB29_RESULT_PASS` /
  `DB29_WORKBOOK_MODIFIED: False` / `DB29_NEXUS_SOURCE_MODIFIED: False` /
  `DB29_GIT_MODIFIED: False`).

---

## 4. Engine (HistoryEngine.ps1)

`Get-DbM29TaskHistoryView` -- PURE. Parameters: `-Records` (AiAttemptRecord v1
objects, optional), `-Query`, `-EscalationDecisions` (optional), `-Fingerprints`
(optional), `-ProviderHealth` (optional). Writes nothing.

Pipeline (all reuse READ-ONLY):

1. **Query validation** -- `Test-DbM29TaskHistoryQuery`; throw on invalid.
2. **Task grouping + ordering** -- `Resolve-AiTaskChains -Records` (DB-M24).
3. **Chain facts** -- per chain: `Resolve-AiChainFacts -Chain -SuccessDefinition`
   (DB-M24) and `New-EscalationChain -Attempts -TaskId -ChangeId` (DB-M20) for
   ChainId/EscalationEvents/LoopFree.
4. **Task row** -- per chain:
   - AttemptCount, CorrectionsCount (records with ParentAttemptId OR a
     FIX_REQUIRED review followed by a retry), EscalationsCount
     (chain.EscalationEvents), FailureCount (Result in FAILED/CANCELLED/BLOCKED/
     BUDGET_STOPPED OR VerificationResult=FAILED).
   - TotalActualCost = sum of record ActualCost (DB-M16 evidence);
     TotalEstimatedCost = sum of record EstimatedCost. Never recalculated.
   - VerifiedState from `Resolve-DbM25VerifiedSuccess` on the terminal attempt
     under the query's SuccessDefinition, mapped to the DB-M29 label.
     NO_ATTEMPTS when the task has zero records.
   - FirstAttemptSuccess: YES when the FIRST ordered attempt resolves verified
     success; NO when it resolves otherwise; UNKNOWN when no attempts.
   - Final provider/model/underlying/gateway/reasoning from the terminal attempt.
   - Mode from the terminal attempt's ExecutionMode (fallback TaskType).
5. **Timeline** -- per chain, iterate the ordered attempts in order:
   - Build `AttemptTimelineNode` for each attempt (all fields from the record,
     cost resolved via `Resolve-DbM25RecordCost`, CumulativeCost = running sum).
   - Between attempt[i-1] and attempt[i], classify the transition with
     `Get-DbM29Transition` (deterministic, evidence-first, reason codes from the
     DB-M20 vocabulary):
     1. prev.ClaudeReviewStatus = FIX_REQUIRED AND next retries -> Type
        `CORRECTION_CLAUDE_REVIEW_FIX`, Action `CORRECT_CURRENT_ATTEMPT`,
        ReasonCodes `CLAUDE_REVIEW_FIX`+`CORRECT_CURRENT_ATTEMPT`.
     2. A matching EscalationDecision exists for next (keyed by AttemptId) ->
        Type from the decision Action (SWITCH_PROVIDER_ROUTE ->
        `SWITCH_PROVIDER_ROUTE`, SWITCH_MODEL -> `SWITCH_MODEL`,
        RETRY_SAME_MODEL_HIGHER_REASONING -> `RETRY_SAME_MODEL_HIGHER_REASONING`,
        REBUILD_CONTEXT -> `REBUILD_CONTEXT`, else RETRY/CORRECTION per evidence),
        carry DecisionId + Action + ReasonCodes + RequiresHuman + HumanActionType.
     3. else provider changed -> `SWITCH_PROVIDER_ROUTE`; model changed ->
        `SWITCH_MODEL`; reasoning escalated (order NONE<LOW<MEDIUM<HIGH<MAX) ->
        `RETRY_SAME_MODEL_HIGHER_REASONING`; else `RETRY`.
   - The FIRST node's Transition = `START`; a terminal node after the last gets
     its terminal marker (`VERIFIED_SUCCESS` when the terminal resolves verified
     success, `BUDGET_STOP` when Result=BUDGET_STOPPED, `HUMAN_REVIEW` when
     WAITING_HUMAN/BLOCKED with RequiresHuman evidence, `GOVERNANCE_STOP` when a
     STOP_GOVERNANCE decision or GOVERNANCE_BLOCKED reason is present,
     `FAILED_NO_RETRY` otherwise).
   - **Failure fingerprint** on a node: the record's FailureFingerprintId; when a
     matching Fingerprint object is supplied, attach it (signature prefix,
     normalized codes, recurrence type from DB-M21 vocabulary).
   - **Provider failure evidence**: optional -- when a ProviderHealthEvidence
     carries AttemptIdReference matching the node, attach observed health state +
     retry-after as a node note (never a health-write).
6. **Empty-store honesty** -- when no records match: TaskRows = @(), Count = 0,
   Empty = true, Warnings includes "No attempt history recorded for the current
   selection." The UI renders an honest empty state.
7. **Assemble** -- `TaskHistoryView` (RequestId, QueryId, GeneratedAtUtc, NowUtc,
   Currency, SuccessDefinition, Count, Empty, TaskRows, ReadOnlyGuard, Warnings).

`Get-DbM29Transition` and `Get-DbM29TimelineNode` are exported separately so the
test suite can unit-test the classifier without the full view.

---

## 5. Renderer (HistoryRender.ps1)

`Export-DbM29TaskHistoryHtml` -- self-contained HTML (inline CSS/JS, embedded
JSON), UTF8 no-BOM `WriteAllText` of the operator-requested artifact; the ONLY
write in the library (DB-M27/DB-M28 pattern).

Marker strings carried in the output and asserted by the suite:

- `AUTO AI EXECUTION DISABLED · attempts executed: NO · paid calls 0 · network
  calls 0.`
- `Attempt-history database: NONE · DB-M17 attempt store consumed READ-ONLY.`
- `Secret values displayed: NO.` · `Secret values logged: NO.`
- Empty state marker when no attempts: `No attempt history recorded.`

Sections:

1. **TASK HISTORY** -- filterable/sortable table of the brief's 13 fields:
   Task ID, Change ID, Mode, Attempt count, Total actual cost, Total estimated
   cost, Verified-success state, First-attempt success YES/NO, Final model,
   Final provider, Corrections count, Escalations count, Failure count.
2. **ATTEMPT TIMELINE** (per selected task) -- the complete ordered chain with
   transition arrows and reason badges between attempts. Each node card shows:
   attempt number + AttemptId, provider/model/underlying/gateway, reasoning
   level, result, failure category + failure fingerprint (id + signature prefix
   + recurrence when a fingerprint is attached), verification result, Claude
   review status, cost (actual vs estimated labelled), cumulative cost, tokens,
   duration, timestamp. Each transition badge shows the DB-M20 Action + reason
   codes + explanation (+ DecisionId). The terminal node carries its terminal
   marker (`VERIFIED SUCCESS` highlighted on the winning attempt).
3. **WHY DID IT FAIL / WHY RETRY / WHY ESCALATE** -- a consolidated per-task list
   of every failure category + fingerprint + escalation decision, so the operator
   can answer the six questions at a glance.
4. **READ-ONLY GUARD** footer + warnings.

Every HTML emission passes `Test-DbM29SecretLeak` before return.

---

## 6. Test matrix (S1-S55, 55 scenarios)

Mirrors the DB-M28 harness (Test-DbM28ModelConfig.ps1): scenario registry +
per-scenario try/catch runner + `Assert-*` helpers + child-suite regression
runner that parses the LAST summary line. Fixture builders clone the real
`New-AiAttemptRecord` signature with synthetic records (an attempt store is
EMPTY on disk; the suite proves the view engine on fixtures AND proves the live
empty store renders an honest empty state).

| # | Scenario | Proves |
|---|----------|--------|
| S1 | UI opens | renderer emits a self-contained HTML page (doctype, title, no-execution badge, guard footer); export writes the artifact |
| S2 | Task list renders | real (empty) store -> honest empty state + warning |
| S3 | Empty store honesty | `No attempt history recorded.` marker; Count=0; Empty=true |
| S4 | Task row fields | 13 brief fields present on a fixture task row |
| S5 | Attempt count | row.AttemptCount = ordered record count |
| S6 | Total actual cost | sum of ActualCost (DB-M16 evidence, never recalculated) |
| S7 | Total estimated cost | sum of EstimatedCost |
| S8 | Verified-success state | terminal VERIFIED -> VERIFIED_SUCCESS (DB-M25 authoritative) |
| S9 | Contradicted success | model self-PASS + VerificationResult=FAILED -> CONTRADICTED |
| S10 | Model-returned | SUCCESS + no verification evidence under VERIFIED -> not verified (flagged) |
| S11 | First-attempt success YES | first ordered attempt resolves verified success |
| S12 | First-attempt success NO | first attempt failed, later attempt passed |
| S13 | First-attempt UNKNOWN | no attempts |
| S14 | Final model/provider | terminal attempt identity |
| S15 | Corrections count | ParentAttemptId / FIX_REQUIRED-then-retry counting |
| S16 | Escalations count | chain.EscalationEvents (DB-M20) |
| S17 | Failure count | FAILED/CANCELLED/BLOCKED/BUDGET_STOPPED + verification-failed records |
| S18 | Mode | ExecutionMode fallback TaskType |
| S19 | Timeline ordering | ordered by RetryNumber then AttemptId (DB-M20 chain) |
| S20 | Timeline node fields | all node fields from the record |
| S21 | Per-attempt cost | actual preferred, estimated labelled (DB-M16 via DB-M25) |
| S22 | Cumulative cost | running sum across the chain |
| S23 | First transition START | first node Transition = START |
| S24 | Plain retry | same provider/model/reasoning -> RETRY |
| S25 | Reasoning escalation | same model higher reasoning -> RETRY_SAME_MODEL_HIGHER_REASONING |
| S26 | Model switch | model changed same provider -> SWITCH_MODEL |
| S27 | Provider switch | provider changed -> SWITCH_PROVIDER_ROUTE |
| S28 | Rebuild context | REBUILD_CONTEXT decision -> REBUILD_CONTEXT transition |
| S29 | Correction | CORRECT_CURRENT_ATTEMPT / ParentAttemptId -> CORRECTION |
| S30 | Claude review fix | prev FIX_REQUIRED -> CORRECTION_CLAUDE_REVIEW_FIX, reason CLAUDE_REVIEW_FIX |
| S31 | Escalation decision carried | DecisionId + Action + ReasonCodes + RequiresHuman on the transition |
| S32 | Budget stop terminal | Result=BUDGET_STOPPED -> BUDGET_STOP marker, budget vocab |
| S33 | Human review terminal | WAITING_HUMAN / RequiresHuman -> HUMAN_REVIEW |
| S34 | Governance stop terminal | STOP_GOVERNANCE / GOVERNANCE_BLOCKED -> GOVERNANCE_STOP |
| S35 | Verified-success terminal | terminal VERIFIED -> VERIFIED_SUCCESS highlighted |
| S36 | Failed-no-retry terminal | failed chain end -> FAILED_NO_RETRY |
| S37 | Failure category display | DB-M17/DB-M20 vocab category per failed node |
| S38 | Failure fingerprint display | FailureFingerprintId + signature prefix + recurrence (DB-M21) when attached |
| S39 | Provider failure evidence | optional ProviderHealthEvidence note (DB-M22 shape), never a health-write |
| S40 | Route identity preserved | UnderlyingModelId + GatewayProviderId never collapsed |
| S41 | Task filtering | TaskId/ProviderId/ModelId filters narrow the rows |
| S42 | Sorting | SortBy TASK_ID / TOTAL_COST / ATTEMPT_COUNT |
| S43 | Cost authority | engine never re-implements a cost formula (forbidden-token scan) |
| S44 | No second attempt-history database | no write token to logs/tasks/state/attempts; store READ-ONLY |
| S45 | Secrets never rendered | HTML passes Test-DbM29SecretLeak; env-var NAMES only |
| S46 | Secrets never logged | view JSON passes the leak guard; no secret write path |
| S47 | No AI execution | AUTO_EXECUTION_ENABLED=FALSE; no Invoke-Provider/Send-ProviderRequest token |
| S48 | Paid calls 0 | guard 0; no web/rest/http tokens in library |
| S49 | Network calls 0 | guard 0; no WebClient/process-spawn/dynamic-invoke tokens |
| S50 | Escalation store untouched | no New-EscalationDecision/decision-write token |
| S51 | Budget untouched | no budget-write token; budget evidence display-only |
| S52 | Canonical workbook unchanged | Nexus workbook SHA-256 byte-identical (6D42C3BF...) |
| S53 | Lane C UI unchanged | UI files byte-identical |
| S54 | Solution build | dotnet build 0 errors |
| S55 | Frozen files re-verification | DB-M14..M28 owned files + DB-M29 library + live config SHA-256 unchanged |

### Regressions (child suites, LAST-summary parser)

- **DB-M17** AttemptStore (root `Test-AttemptStore.ps1`)
- **DB-M20** Escalation (`escalation/Test-DbM20Escalation.ps1`)
- **DB-M21** Fingerprints (`failure-fingerprints/Test-DbM21Fingerprints.ps1`)
- **DB-M26** Dashboard (`dashboard/Test-DbM26Dashboard.ps1` -- nests M16/21/24/25;
  preserves the current external S41 signature)
- **DB-M28** Model Config (`model-config/Test-DbM28ModelConfig.ps1` -- nests
  M27/19/22/23/181; preserves S41/R45 external signatures)

The DB-M29-owned library files + the canonical workbook + Lane C UI + live
config are SHA-256 byte-identical across the run.

---

## 7. Outputs

- `design/DB-M29_TASK_ATTEMPT_ESCALATION_HISTORY_UI.md` (this file)
- `scripts/ai-routing/task-history/HistoryContracts.ps1`
- `scripts/ai-routing/task-history/HistoryEngine.ps1`
- `scripts/ai-routing/task-history/HistoryRender.ps1`
- `scripts/ai-routing/task-history/Test-DbM29TaskHistory.ps1`
- `state/db-m29-result.json`
- `state/db-m29-test-run.log`
- `tasks/DB-M29_IMPLEMENTATION_REPORT.md`

## 8. Final DB-M29 RESULT report

Terminal output ends with the exact lines:

```
DB-M29 TEST SUMMARY: <N> passed, <N> failed
DB-M29 SCENARIOS: 55 scenarios
Ready for DB-M30: YES
Stop after DB-M29.
```

**Ready for DB-M30: YES**  |  **Stop after DB-M29.**
