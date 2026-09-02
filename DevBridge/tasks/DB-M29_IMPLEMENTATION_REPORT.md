# DB-M29 -- TASK COST, ATTEMPT & ESCALATION HISTORY UI: Implementation Report

Date: 2026-09-01 (local) / 2026-08-31 19:32 UTC  |  Lane B  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. DevBridge is NOT part of
Nexus. Nothing implemented in DB-M29 is intended for migration into Nexus. Do
NOT design DB-M29 for Nexus migration.

---

## 1. What this milestone delivered

An operator-facing **TASK COST, ATTEMPT & ESCALATION HISTORY UI** showing the
COMPLETE AI execution history of a task across attempts, retries, corrections,
escalations, provider failures, model-quality failures, budget decisions and
verification outcomes. For any task the operator can answer:

- **WHAT WAS TRIED?** — ordered attempt timeline: provider, model, reasoning.
- **WHY DID IT FAIL?** — failure category, failure fingerprint, verification.
- **WHY DID DEVBRIDGE RETRY OR ESCALATE?** — transition arrows + DB-M20 action +
  reason codes + explanation.
- **HOW MUCH DID EACH ATTEMPT COST?** — per-attempt actual vs estimated cost.
- **WHAT WAS THE TOTAL COST?** — task total actual + total estimated.
- **WHICH ATTEMPT FINALLY PASSED VERIFICATION?** — terminal verified-success
  marker on the winning attempt.

DB-M29 is a **PURE presentation engine** (takes records/decisions/fingerprints
as parameters, returns a view). It **owns NO persistence** — the DB-M17 attempt
store is the ONLY history source and is consumed READ-ONLY. **No second
attempt-history database is created.** The on-disk attempt store is EMPTY
today; the UI renders an honest empty state (`No attempt history recorded.`)
instead of inventing history.

DB-M29 **reuses (does NOT rebuild)** the DB-M14..M28 chain READ-ONLY:

- **DB-M16** cost semantics — every cost figure resolves via
  `Resolve-DbM25RecordCost` (actual preferred / estimated labelled / currency
  matched); DB-M29 never recomputes a cost formula.
- **DB-M17** attempt record contracts + vocabulary + query layer — the ONLY
  attempt-history source. DB-M29 never writes an attempt record.
- **DB-M19** routing eligibility vocab — NOT invoked; history is display only;
  the hard capability gate is untouched.
- **DB-M20** `New-EscalationChain` + EscalationDecision/Input contracts +
  action/reason-code vocabularies — the timeline's WHY-RETRY/ESCALATE evidence.
- **DB-M21** budget decision vocab + `FailureFingerprint v1` + recurrence
  vocabulary — the timeline's failure-fingerprint + budget-stop evidence.
- **DB-M22** `ProviderHealthEvidence v1` shape + health vocab — optional
  provider-failure context per attempt, never a health-write.
- **DB-M23** price-status vocab + error-category map — route identity never
  collapses gateway vs underlying model.
- **DB-M24** `Resolve-AiTaskChains` / `Resolve-AiChainFacts` — task grouping,
  chain ordering, task facts.
- **DB-M25** `Resolve-DbM25VerifiedSuccess` (authoritative) +
  `Resolve-DbM25RecordCost` (DB-M16 semantics) — verified-success state + cost
  resolution.
- **DB-M26** aggregate dashboard — DB-M29 is the per-task drilldown; no
  duplicate analytics.
- **DB-M27 / DB-M28** renderer pattern (self-contained HTML artifact) +
  ReadOnlyGuard + secret-leak guard + markers.

### 1.1 Contracts (HistoryContracts.ps1)

- Schema versions for TaskHistoryQuery / TaskHistoryView / TaskHistoryRow /
  AttemptTimelineNode / TimelineTransition / ReadOnlyGuard (all v1).
- `Get-DbM29TransitionTypes` — the timeline-arrow vocabulary: `RETRY`,
  `RETRY_SAME_MODEL_HIGHER_REASONING`, `SWITCH_MODEL`,
  `SWITCH_PROVIDER_ROUTE`, `REBUILD_CONTEXT`, `CORRECTION`,
  `CORRECTION_CLAUDE_REVIEW_FIX`, `BUDGET_STOP`, `HUMAN_REVIEW`,
  `GOVERNANCE_STOP`, `VERIFIED_SUCCESS`, `FAILED_NO_RETRY`.
- `Get-DbM29TaskRowSortBys` — `TASK_ID | TOTAL_COST | ATTEMPT_COUNT`.
- `Get-DbM29VerifiedStates` — `VERIFIED_SUCCESS | CONTRADICTED | MODEL_RETURNED |
  INCOMPLETE | NO_ATTEMPTS` (labels only; the underlying truth is DB-M25
  `Resolve-DbM25VerifiedSuccess`).
- `Get-DbM29FirstAttemptSuccessValues` — `YES | NO | UNKNOWN`.
- `New-DbM29TaskHistoryQuery` / `Test-DbM29TaskHistoryQuery` — QueryId, NowUtc,
  Currency (INR), SuccessDefinition (DB-M24 vocab), optional TaskId/ProviderId/
  ModelId filters, AllowEstimatedCostFallback, SortBy/SortDirection.
- `New-DbM29TaskHistoryRow` — the brief's TASK HISTORY fields: TaskId, NodeId,
  ChangeId, Mode (ExecutionMode, `(none)` when absent), AttemptCount,
  TotalActualCost, TotalEstimatedCost, VerifiedState, FirstAttemptSuccess,
  FinalProviderId, FinalModelId, FinalUnderlyingModelId, FinalGatewayProviderId,
  FinalReasoningLevel, CorrectionsCount, EscalationsCount, FailureCount,
  FirstAttemptId, TerminalAttemptId, ChainId, LoopFree, Timeline (attempts).
- `New-DbM29AttemptTimelineNode` / `New-DbM29TimelineTransition` — per-attempt
  node fields (identity, cost source + resolved cost amount, cumulative cost,
  verification + review status, failure fingerprint reference) and the
  transition to each node (FromAttemptId/ToAttemptId/Type/Action/ReasonCodes/
  Explanation/DecisionId/RequiresHuman/HumanActionType; first or single node =
  `START` / `VERIFIED_SUCCESS` / `FAILED_NO_RETRY` per the terminal state).
- `New-DbM29ReadOnlyGuard` — AutoExecutionEnabled=FALSE, PaidApiCalls=0,
  NetworkCalls=0, AttemptStoreModified=NO, EscalationDecisionsModified=NO,
  BudgetPolicyModified=NO, FingerprintsModified=NO, SecretValuesDisplayed=NO,
  SecretValuesLogged=NO.
- `Test-DbM29SecretLeak` — the shared secret-material scan (M23/M28 pattern;
  exempts identifier/reference fields, scans free text) applied to every HTML
  output and every view node.
- `Out-DbM29Markers` — backend contract: always exits 0, outcomes only via
  stdout markers.

### 1.2 Engine (HistoryEngine.ps1)

`Get-DbM29TaskHistoryView` builds the view:

1. **Filter** records by optional TaskId / ProviderId / ModelId query filters.
2. **Group** into task chains via `Resolve-AiTaskChains` (ordered by
   RetryNumber → StartedAtUtc → AttemptId) and resolve task facts via
   `Resolve-AiChainFacts` (first-attempt success, terminal attempt).
3. **Task row** via `Get-DbM29TaskRow` — `New-EscalationChain` +
   `Resolve-AiChainFacts`; totals sum the stored CostCurrency-matched
   Actual/Estimated; counters (CorrectionsCount from ParentAttemptId /
   FIX_REQUIRED-then-retry, EscalationsCount from chain.EscalationEvents,
   FailureCount from failed/verification-failed records); timeline nodes carry
   `CumulativeCost`; the `TerminalMarker` sits only on the last node;
   `VerifiedAttemptId` only when VERIFIED_SUCCESS.
4. **Transition typing** (`Get-DbM29Transition`): 1) previous node
   `ClaudeReviewStatus == FIX_REQUIRED` → `CORRECTION_CLAUDE_REVIEW_FIX`
   (reason `CLAUDE_REVIEW_FIX` / `CORRECT_CURRENT_ATTEMPT`); 2) a DB-M20
   decision maps its Action to the transition type; 3) `ParentAttemptId` →
   `CORRECTION`; 4) evidence deltas: provider changed → `SWITCH_PROVIDER_ROUTE`,
   model changed → `SWITCH_MODEL`, reasoning escalated →
   `RETRY_SAME_MODEL_HIGHER_REASONING`, else `RETRY`. Reason codes come ONLY
   from the DB-M20 vocabulary.
5. **Terminal markers**: `BUDGET_STOPPED` → `BUDGET_STOP`; `WAITING_HUMAN` /
   `BLOCKED` / RequiresHuman → `HUMAN_REVIEW`; `STOP_GOVERNANCE` /
   `GOVERNANCE_BLOCKED` → `GOVERNANCE_STOP`; verified → `VERIFIED_SUCCESS`;
   else `FAILED_NO_RETRY`.
6. **Empty store honesty** — no records → an honest view (`NO_ATTEMPTS`,
   `No attempt history recorded.`, warning) instead of fabricated history.

Every cost figure resolves via `Resolve-DbM25RecordCost` (DB-M16 semantics);
verified-success is `Resolve-DbM25VerifiedSuccess` (authoritative). DB-M29 has
**no cost formula** of its own.

### 1.3 Renderer (HistoryRender.ps1)

Self-contained HTML (inline CSS/JS, embedded JSON) — task rows, attempt
timeline with transition arrows, per-attempt + cumulative + total cost,
verified-success highlighting, failure fingerprints, provider-failure
warnings, and the read-only guard footer. Marker strings carried in the output
and asserted by the suite:

- `AUTO AI EXECUTION DISABLED · attempts executed: NO · paid calls 0 ·
  network calls 0.`
- `Attempt-history database: NONE · DB-M17 attempt store consumed READ-ONLY.`
- `Secret values displayed: NO.` · `Secret values logged: NO.`
- `No attempt history recorded.` on the honest empty store.
- Footer `read-only · no AI execution`.

Every HTML emission is passed through `Test-DbM29SecretLeak` before return; the
only library disk write is `Export-DbM29TaskHistoryHtml`'s `WriteAllText` of the
operator-requested artifact.

---

## 2. Test results

`scripts/ai-routing/task-history/Test-DbM29TaskHistory.ps1`

- **55 scenarios (S1-S55)** — 55/55 green, exit 0.
- **Assertions:** 391 passed, 0 failed.

```
DB-M29 TEST SUMMARY: 391 passed, 0 failed
DB-M29 SCENARIOS: 55 scenarios
DB-M29 REGRESSION DBM17: 99 passed, 0 failed, exit 0
DB-M29 REGRESSION DBM20: 149 passed, 0 failed, exit 0
DB-M29 REGRESSION DBM21: 74 passed, 0 failed, exit 0
DB-M29 REGRESSION DBM26: 381 passed, 1 failed, exit 1
DB-M29 REGRESSION DBM28: 359 passed, 0 failed, exit 0
```

(Full run log: `state/db-m29-test-run.log`.)

### 2.1 Scenario walkthrough (S1-S55)

| # | Scenario | What it proves | Result |
|---|----------|----------------|--------|
| S1 | UI opens | renderer emits a self-contained HTML page (doctype, title, no-execution badge, guard footer); export writes the artifact | PASS |
| S2 | Task list renders | real (empty) store → honest empty state + warning | PASS |
| S3 | Empty store honesty | `No attempt history recorded.` marker; Count=0; Empty=true | PASS |
| S4 | Task row fields | 13 brief fields present on a fixture task row | PASS |
| S5 | Attempt count | row.AttemptCount = ordered record count | PASS |
| S6 | Total actual cost | sum of ActualCost (DB-M16 evidence, never recalculated) | PASS |
| S7 | Total estimated cost | sum of EstimatedCost | PASS |
| S8 | Verified-success state | terminal VERIFIED → VERIFIED_SUCCESS (DB-M25 authoritative) | PASS |
| S9 | Contradicted success | model self-PASS + VerificationResult=FAILED → CONTRADICTED | PASS |
| S10 | Model-returned | SUCCESS + no verification evidence under VERIFIED → not verified (flagged) | PASS |
| S11 | First-attempt success YES | first ordered attempt resolves verified success | PASS |
| S12 | First-attempt success NO | first attempt failed, later attempt passed | PASS |
| S13 | First-attempt UNKNOWN | no attempts | PASS |
| S14 | Final model/provider | terminal attempt identity | PASS |
| S15 | Corrections count | ParentAttemptId / FIX_REQUIRED-then-retry counting | PASS |
| S16 | Escalations count | chain.EscalationEvents (DB-M20) | PASS |
| S17 | Failure count | FAILED/CANCELLED/BLOCKED/BUDGET_STOPPED + verification-failed records | PASS |
| S18 | Mode | ExecutionMode fallback TaskType | PASS |
| S19 | Timeline ordering | ordered by RetryNumber then AttemptId (DB-M20 chain) | PASS |
| S20 | Timeline node fields | all node fields from the record | PASS |
| S21 | Per-attempt cost | actual preferred, estimated labelled (DB-M16 via DB-M25) | PASS |
| S22 | Cumulative cost | running sum across the chain | PASS |
| S23 | First transition START | first node Transition = START | PASS |
| S24 | Plain retry | same provider/model/reasoning → RETRY | PASS |
| S25 | Reasoning escalation | same model higher reasoning → RETRY_SAME_MODEL_HIGHER_REASONING | PASS |
| S26 | Model switch | model changed same provider → SWITCH_MODEL | PASS |
| S27 | Provider switch | provider changed → SWITCH_PROVIDER_ROUTE | PASS |
| S28 | Rebuild context | REBUILD_CONTEXT decision → REBUILD_CONTEXT transition | PASS |
| S29 | Correction | CORRECT_CURRENT_ATTEMPT / ParentAttemptId → CORRECTION | PASS |
| S30 | Claude review fix | prev FIX_REQUIRED → CORRECTION_CLAUDE_REVIEW_FIX, reason CLAUDE_REVIEW_FIX | PASS |
| S31 | Escalation decision carried | DecisionId + Action + ReasonCodes + RequiresHuman on the transition | PASS |
| S32 | Budget stop terminal | Result=BUDGET_STOPPED → BUDGET_STOP marker, budget vocab | PASS |
| S33 | Human review terminal | WAITING_HUMAN / RequiresHuman → HUMAN_REVIEW | PASS |
| S34 | Governance stop terminal | STOP_GOVERNANCE / GOVERNANCE_BLOCKED → GOVERNANCE_STOP | PASS |
| S35 | Verified-success terminal | terminal VERIFIED → VERIFIED_SUCCESS highlighted | PASS |
| S36 | Failed-no-retry terminal | failed chain end → FAILED_NO_RETRY | PASS |
| S37 | Failure category display | DB-M17/DB-M20 vocab category per failed node | PASS |
| S38 | Failure fingerprint display | FailureFingerprintId + signature prefix + recurrence (DB-M21) when attached | PASS |
| S39 | Provider failure evidence | optional ProviderHealthEvidence note (DB-M22 shape), never a health-write | PASS |
| S40 | Route identity preserved | UnderlyingModelId + GatewayProviderId never collapsed | PASS |
| S41 | Task filtering | TaskId/ProviderId/ModelId filters narrow the rows | PASS |
| S42 | Sorting | SortBy TASK_ID / TOTAL_COST / ATTEMPT_COUNT | PASS |
| S43 | Cost authority | engine never re-implements a cost formula (forbidden-token scan) | PASS |
| S44 | No second attempt-history database | no write token to logs/tasks/state/attempts; store READ-ONLY | PASS |
| S45 | Secrets never rendered | HTML passes Test-DbM29SecretLeak; env-var NAMES only | PASS |
| S46 | Secrets never logged | view JSON passes the leak guard; no secret write path | PASS |
| S47 | No AI execution | AUTO_EXECUTION_ENABLED=FALSE; no Invoke-Provider/Send-ProviderRequest token | PASS |
| S48 | Paid calls 0 | guard 0; no web/rest/http tokens in library | PASS |
| S49 | Network calls 0 | guard 0; no WebClient/process-spawn/dynamic-invoke tokens | PASS |
| S50 | Escalation store untouched | no New-EscalationDecision/decision-write token | PASS |
| S51 | Budget untouched | no budget-write token; budget evidence display-only | PASS |
| S52 | Canonical workbook unchanged | Nexus workbook SHA-256 byte-identical (6D42C3BF…) | PASS |
| S53 | Lane C UI unchanged | UI files byte-identical | PASS |
| S54 | Solution build | dotnet build 0 errors | PASS |
| S55 | Frozen files re-verification | DB-M14..M28 owned files + DB-M29 library + live config SHA-256 unchanged | PASS |

### 2.2 Regressions

| Suite | Result |
|-------|--------|
| DB-M17 | 99/99 PASS, exit 0 |
| DB-M20 | 149/149 PASS, exit 0 |
| DB-M21 | 74/74 PASS, exit 0 |
| DB-M16 | 167/167 PASS (via DB-M26 child regression, 0 failures) |
| DB-M24 | 128/128 PASS (via DB-M26 child regression, 0 failures) |
| DB-M25 | 337/337 PASS (via DB-M26 child regression, 0 failures) |
| DB-M26 | 381/382 — **single external failure S41** (recorded workbook authority F520060C vs live 6D42C3BF after DB-M12.4 closure), reported separately |
| DB-M28 | 359/359 PASS, exit 0 |

DB-M18.1 is NOT invoked by DB-M29; its frozen files
(`DependencyLineage.ps1` + `Test-DbM181DependencyLineage.ps1`) are re-verified
byte-identical by S55, and its R45 external drift remains reported separately.

### 2.3 Proofs

- **No second attempt-history database** — DB-M29 owns NO persistence; the
  engine is pure (records/decisions/fingerprints in, view out). The only write
  in the entire library is `Export-DbM29TaskHistoryHtml` writing the
  operator-requested HTML artifact (S44).
- **Attempt store consumed READ-ONLY** — `No attempt history recorded.` empty
  state + `Attempt-history database: NONE · DB-M17 attempt store consumed
  READ-ONLY.`; empty on-disk store shown honestly, never fabricated.
- **Cost authority** — every cost figure resolves via
  `Resolve-DbM25RecordCost`; no cost formula in the library (S43).
- **Transition + terminal evidence** — DB-M20 decision carried on transitions;
  budget/human/governance/verified/no-retry terminals (S23-S36).
- **Secrets displayed: NO · logged: NO** — HTML + view JSON pass
  `Test-DbM29SecretLeak`; only env-var/reference names are ever shown (S45/S46).
- **AUTO AI execution NO** — `AutoExecutionEnabled=FALSE`; attempts executed
  NO; paid calls 0; network calls 0 (guard + forbidden-token scan) (S47-S49).
- **Escalation / budget / fingerprint stores untouched** — no write token
  (S50/S51).
- **Canonical workbook modified NO · Nexus source modified NO · Lane C UI
  unchanged** — SHA-256 byte-identical (S52/S53); no workbook path or baseline
  token in the library.

---

## 3. Files created

- `design/DB-M29_TASK_ATTEMPT_ESCALATION_HISTORY_UI.md`
- `scripts/ai-routing/task-history/HistoryContracts.ps1`
- `scripts/ai-routing/task-history/HistoryEngine.ps1`
- `scripts/ai-routing/task-history/HistoryRender.ps1`
- `scripts/ai-routing/task-history/Test-DbM29TaskHistory.ps1`
- `state/db-m29-result.json`
- `state/db-m29-test-run.log`
- `tasks/DB-M29_IMPLEMENTATION_REPORT.md` (this file)

## 4. Files modified

None outside the DB-M29-owned scope. The DB-M14..M28 chain, Lane C UI,
`src/`, the canonical Nexus workbook, and live config are byte-identical.

---

## 5. Boundary / overlap

- **DB-M16 / DB-M17 / DB-M19 / DB-M20 / DB-M21 / DB-M22 / DB-M23 / DB-M24 /
  DB-M25**: consumed READ-ONLY. Attempt store, escalation store, budget policy
  and fingerprint store are all untouched; DB-M29 never writes to any of them.
- **DB-M26**: the cross-task aggregate dashboard; DB-M29 is the per-task
  drilldown — no duplicate analytics. DB-M26 preserved at its external S41
  signature.
- **DB-M27 / DB-M28**: renderer + ReadOnlyGuard + secret-leak guard + markers
  pattern borrowed; DB-M28 suite preserved 359/0 exit 0.
- **Lane A / DB-GH01**: DB-M29 wrote ONLY under `scripts/ai-routing/task-history/`,
  `design/`, `state/`, `tasks/`. **NO PARALLEL_SCOPE_CONFLICT.**
- **Nexus**: DB-M29 is DevBridge-only, temporary, and NOT designed for Nexus
  migration.

DB-M29 TEST SUMMARY: 391 passed, 0 failed
DB-M29 SCENARIOS: 55 scenarios

**Ready for DB-M30: YES.** **Stop after DB-M29.**
