# DB-M30 — SUPERVISED DEVELOPMENT WORKFLOW INTEGRATION: Design

**Milestone:** DB-M30 (workflow integration / operator guidance)
**Date:** 2026-09-01
**Status:** DESIGN
**Owner lane:** Cross-lane integration (Lane C lifecycle guidance; Lane B AI recommendation / cost / history consumed READ-ONLY)

Temporary DevBridge scaffolding for Nexus Phase 1/2. DevBridge is NOT part of
Nexus. Nothing implemented in DB-M30 is intended for migration into Nexus. Do
NOT design DB-M30 for Nexus migration.

---

## 0. DB-M30 DISCOVERY (printed before coding)

DISCOVERY FIRST — inspected before any DB-M30 code was written. Every listed
foundation was read READ-ONLY; the reusable identifiers below were confirmed to
exist on the live tree.

| Foundation | Reusable surface inspected |
|------------|----------------------------|
| **Lifecycle** (DB-M12.2/12.3, DB-M03.1/03.2, DB-M12.4) | `state/current-task.json` (task identity, status, `nextAllowedAction`, `preflightVerdict`, `implementability`); `state/current-lifecycle-state.json` (mode, `trialMode`, evidence, M10 eligibility, git lifecycle); durable stage artifacts `state/preflight.json` / `state/reservation.json` / `state/verification.json` / `state/claude-review.json` / `state/completion.json`; per-change evidence tree `logs\tasks\<node>\<change>\` (`CHATGPT_HANDOFF.md`, `VERIFICATION_RESULT.md`, `CLAUDE_REVIEW_PACKAGE.md`, `CLAUDE_DECISION_RESULT.md`, `claude-decision.json`); `state/trial-proving-history.json`; the 8-token stage display vocabulary (NOT_STARTED / READY / CURRENT / PASS / FAIL / BLOCKED / HUMAN_ACTION / NOT_APPLICABLE) and 12-stage display catalog from `src/DevBridge.Engine/StageDisplay.cs`. Lifecycle commands: `Get-NextTask.ps1`, `Test-DevelopmentPreflight.ps1`, `Reserve-DevelopmentChange.ps1`, `New-ChatGptHandoff.ps1`, `Run-Verification.ps1`, `New-ClaudeReviewPackage.ps1`, `Set-ClaudeReviewResult.ps1`, `New-CorrectionContext.ps1`, `Get-GitGateState.ps1`, `Complete-GovernedCycle.ps1`, `Complete-Task.ps1`. |
| **DB-M18.1 dependency context** | `Get-DbM181TaskDependencyContext -Task -TaskCatalog -EvidenceRoot -RepositoryRoot -NowUtc` returns `{Graph, LineageSet, Reconciliation, Index, Freshness, Relevance, Context}`; `Context` = `DependencyDevelopmentContext v1` (DirectDependencies, DeliveredSummary[], CurrentFiles[], CurrentContracts[], TestsEvidence[], ReusePoints[], ExtensionPoints[], CollisionPoints[], FreshnessStatus, ContextMetrics, PackageHash). Freshness `FRESH/STALE/REBUILD_REQUIRED/UNVERIFIED` (never falsely STALE). M05 already integrates it with the TaskCatalog built from `Get-AllRoadmapNodes` and Task shape `{taskId, nodeId, changeId, name, dependencies}`. |
| **DB-M19 routing recommendation** | `Get-AiRoutingRecommendation -Request -Configuration -ProviderHealth -PerformanceRecords -Policy` returns `{Status, Policy, ExecutionMode, Winner, WinnerEligible, EligibleCandidates[], RejectedCandidates[], Decision, Evidence, RecommendationReason, ...}`. Deterministic, zero AI/network/paid calls; `AUTO` refused (`AUTO_EXECUTION_PROHIBITED`). Routing policy is DISABLED in live config (`routingDefaults.enabled=false`) — DB-M30 surfaces an honest NOT_ENABLED card and never enables routing (DB-M19 hard gate). |
| **DB-M27 cost calculator** | `Invoke-DbM27Calculator -Configuration -Request -AttemptRecords -BudgetPolicy` → `CalculatorView v1` (estimate for a provider/model/reasoning scenario; DB-M16 authority, deterministic, NowUtc injected). `New-DbM27CalculatorRequest` (ProviderId, ModelId, RouteType, ReasoningLevel, tokens, CurrencyTarget, NowUtc). `deepseek-v4-flash` exists in `config/models.json` + `config/pricing/pricing-catalogue.json`. |
| **DB-M21 budget** | `Test-AiBudget -Policy -Attempts -TaskId -ChangeId -ProposedAttemptCost ...` → `BudgetEvaluation v1` (`Decision` ALLOW / ALLOW_WITH_WARNING / BLOCK_* / REQUIRE_HUMAN_OVERRIDE / NO_APPLICABLE_BUDGET). No live budget config file — defaults/injected policy only. |
| **DB-M22 provider health** | `Get-EffectiveProviderHealth -Evidence -Policy -EvaluationTimestampUtc -ProviderId -GatewayProviderId` → `{HealthState, CircuitState, ReasonCodes, RetryAfterUtc, RequiresHuman, ...}` (DB-M14 vocab, read-only). |
| **DB-M26 dashboard** | `Get-DbM26DashboardView -Records -Request -NowUtc -BudgetPolicy -ProviderHealthState ...` → `DashboardView v1` (SummaryCards, CostBreakdown, ChainView[], AttemptHistory[], VerifiedSuccessView[], ReadOnlyGuard, Warnings[]). `New-DbM26DashboardRequest` (PresetWindow ALL_TIME default, ReportingCurrency INR). |
| **DB-M29 task history** | `Get-DbM29TaskHistoryView -Records -Query -EscalationDecisions -Fingerprints -ProviderHealth` → `TaskHistoryView v1` (TaskRows[], Empty, Count, ReadOnlyGuard, Warnings[]); `Export-DbM29TaskHistoryHtml -View -OutputPath` writes the operator-requested HTML artifact. Empty-store honesty: `No attempt history recorded.` |
| **DB-M17 attempt store** | `Get-AiAttemptsForTask -Root -NodeId -TaskId` / `Get-AiAttemptsAll -Root` → `AiAttemptRecord v1[]`. On-disk store is EMPTY today (`state/attempts/` absent); consumed READ-ONLY. |
| **DB-M28/M29 delivery pattern** | Contracts/Engine/Render triads; `New-DbM29ReadOnlyGuard` (AutoExecutionEnabled=false, PaidApiCalls=0, NetworkCalls=0, *Modified=NO); `Test-DbM29SecretLeak`; `Out-DbM29Markers` (backend always exits 0, outcomes via stdout markers); self-contained HTML artifact (inline CSS/JS, embedded JSON, UTF-8 no-BOM `WriteAllText` is the ONLY library write). |

**Reusable identifiers confirmed:** stage vocab + 12-stage catalog (engine),
lifecycle artifact paths, `Get-ContractProperty`, `ConvertTo-AiUtc`,
`Import-AiCostConfiguration`, `New-RoutingRequest`, `New-DbM27CalculatorRequest`,
`New-DbM26DashboardRequest`, `New-DbM29TaskHistoryQuery`, `Resolve-DbM25RecordCost`
(DB-M16 cost authority), `Resolve-DbM25VerifiedSuccess` (verified-success
authority), `New-AiAttemptRecord`, DB-M17 query layer.

**Do not create a second lifecycle/attempt/history database:** DB-M30 owns NO
persistence. Its engine is pure (takes artifacts/records/decisions as inputs and
returns a view). The only write in the entire library is
`Export-DbM30WorkflowHtml` writing the operator-requested HTML artifact (the
same pattern as DB-M27/DB-M28/DB-M29).

---

## 1. Primary objective

Integrate the existing DevBridge lifecycle, dependency context, AI
recommendation, cost information and history systems into **ONE coherent
SUPERVISED operator workflow**. The operator follows a single guided pipeline:

```
Excel / governed task
  -> M03 task selection
  -> DB-M18.1 dependency development context
  -> M04 reservation
  -> M05 ChatGPT handoff
  -> AI recommendation / cost guidance
  -> HUMAN copies handoff to ChatGPT
  -> ChatGPT produces implementation prompt
  -> HUMAN copies prompt to Claude Code / DeepSeek
  -> implementation happens externally
  -> HUMAN returns implementation result
  -> M06 deterministic verification
  -> M07 Claude review package
  -> HUMAN sends package to Claude
  -> HUMAN records Claude decision
  -> M08
  -> correction loop if required
  -> human Git gates in REAL mode
  -> governed completion
```

DB-M30 delivers a **Supervised Workflow Guide**: a deterministic, READ-ONLY
engine that computes the operator's current position in that pipeline, the next
human action, and the guidance cards (dependency context, AI recommendation +
cost, history) that belong at that position — rendered as a self-contained HTML
**workflow console** and as a **terminal guide** (stdout markers, exit 0).

**AUTO_EXECUTION_ENABLED = FALSE.** DevBridge is temporary, supervised Phase 1/2
scaffolding. DB-M30 must NOT build: autonomous end-to-end development, automatic
model execution, automatic ChatGPT/Claude Code/Claude review execution, automatic
PR creation/approval/merge, autonomous roadmap progression, or autonomous
continuous development loops. Those belong in Nexus Developer. DB-M30 only
GUIDES a human; every external step (copy handoff to ChatGPT, copy prompt to
Claude Code/DeepSeek, return result, send package to Claude, record decision,
Git gates, completion) is performed by the human operator.

---

## 2. Boundary and reuse map

DB-M30 **reuses (does NOT rebuild)** the following READ-ONLY:

- **Lifecycle** — consumed via durable state artifacts only. The engine never
  invokes a mutating lifecycle command; it reads `current-task.json`,
  `current-lifecycle-state.json`, the per-stage state artifacts and the
  per-change evidence tree, and derives stage tokens from their presence. The
  C# `NextActionEngine`/`StageDisplay` remain the authoritative next-action
  source; DB-M30's stage map is an evidence-grounded checklist rendered from the
  same durable artifacts (documented in 3.2), never an invented state.
- **DB-M18.1** — `DependencyLineage.ps1` consumed READ-ONLY
  (`Get-DbM181TaskDependencyContext`), same pattern M05 already uses.
- **DB-M19** — `Router.ps1` consumed READ-ONLY
  (`Get-AiRoutingRecommendation`), dry-run only. Routing policy is NEVER enabled
  or modified; when disabled the card reports NOT_ENABLED truthfully.
- **DB-M16/DB-M25** — cost authority `Resolve-DbM25RecordCost` /
  `Resolve-DbM25VerifiedSuccess`; DB-M27 `Invoke-DbM27Calculator` for the
  illustrative cost estimate.
- **DB-M17** — attempt store query layer READ-ONLY (empty store honest).
- **DB-M21** — budget vocabulary + `Test-AiBudget`; informational only.
- **DB-M22** — `Get-EffectiveProviderHealth`; informational only.
- **DB-M26 / DB-M29** — `Get-DbM26DashboardView` (aggregate) +
  `Get-DbM29TaskHistoryView` (per-task drilldown) consumed READ-ONLY as the
  History guidance card.
- **DB-M27 / DB-M28** — renderer pattern (self-contained HTML artifact),
  `New-DbM29ReadOnlyGuard`, `Test-DbM29SecretLeak`, `Out-DbM29Markers` borrowed.

**Lane C / DB-GH01 / DB-M03.2** — DB-M30 writes ONLY under
`scripts/supervised-workflow/`, `design/`, `state/`, `tasks/`. It does NOT touch
`src/` (Lane C UI), lifecycle/governance scripts, config, the canonical Nexus
workbook, or the Nexus repos. **NO PARALLEL_SCOPE_CONFLICT.**

---

## 3. Design decisions

### 3.1 Supervised workflow stage catalog (13 stages)

The catalog follows the brief's pipeline verbatim, mapped to the engine's stage
naming. Each stage carries a human action, the commands the operator runs (for
stages that are lifecycle commands), and the evidence sources that mark it done.

| # | Key | Label | Human action | Command to run | Evidence that marks it DONE |
|---|-----|-------|--------------|----------------|-----------------------------|
| 1 | GOVERNED_TASK | Governed Task | Select the governed task from the workbook | (read-only) | `state/current-task.json` has a `nodeId` |
| 2 | M03_SELECTION | M03 Task Selection & Preflight | Run preflight to select the next implementable task | `scripts\Test-DevelopmentPreflight.ps1` | `state/preflight.json` present AND `current-task.status` in PREFLIGHTED/RESERVED/… |
| 3 | DEPENDENCY_CONTEXT | Dependency Development Context | Review the auto-resolved dependency lineage context (DB-M18.1) | (auto, read-only) | DB-M18.1 context card resolved (informational; PASS once M03 done) |
| 4 | M04_RESERVATION | M04 Reservation | Run reserve to reserve the change | `scripts\Reserve-DevelopmentChange.ps1` | `state/reservation.json` present AND a `changeId` on the current task |
| 5 | M05_CHATGPT_HANDOFF | M05 ChatGPT Handoff | Run handoff generation | `scripts\New-ChatGptHandoff.ps1` | `logs\tasks\<node>\<change>\CHATGPT_HANDOFF.md` present |
| 6 | AI_RECOMMENDATION_COST | AI Recommendation & Cost Guidance | Review recommendation + cost guidance before/while implementing | (auto, read-only) | Guidance cards consumed; PASS once M06 evidence appears |
| 7 | EXTERNAL_IMPLEMENTATION | External Implementation (supervised) | Copy handoff → ChatGPT → copy prompt → Claude Code / DeepSeek → return result | (human, external) | M06 verification evidence present |
| 8 | M06_VERIFICATION | M06 Deterministic Verification | Run deterministic verification | `scripts\Run-Verification.ps1` (or `Verify-Task.ps1`) | `state/verification.json` present AND `logs\tasks\<node>\<change>\VERIFICATION_RESULT.md` present |
| 9 | M07_REVIEW_PACKAGE | M07 Claude Review Package | Run package generation | `scripts\New-ClaudeReviewPackage.ps1` | `logs\tasks\<node>\<change>\CLAUDE_REVIEW_PACKAGE.md` present |
| 10 | M08_CLAUDE_DECISION | M08 Claude Decision | Send package to Claude; record the decision | `scripts\Set-ClaudeReviewResult.ps1` | `state/claude-review.json` present AND `logs\tasks\<node>\<change>\CLAUDE_DECISION_RESULT.md` present |
| 11 | CORRECTION_LOOP | Correction Loop | If Claude requested fixes, run the correction context and re-run M06/M07 | `scripts\New-CorrectionContext.ps1` | NOT_APPLICABLE unless the Claude decision is FIX; DONE when correction verified |
| 12 | HUMAN_GIT_GATE | Human Git Gate | Human Git gates (REAL mode only) | `scripts\Get-GitGateState.ps1` | NOT_APPLICABLE in TRIAL mode; PASS once the merge is confirmed in REAL mode |
| 13 | GOVERNED_COMPLETION | Governed Completion | Run governed completion | `scripts\Complete-GovernedCycle.ps1` / `Complete-Task.ps1` | NOT_APPLICABLE in TRIAL mode (governed trial-cycle closure path); PASS once completion evidence appears |

### 3.2 Stage-state derivation (evidence-grounded, never invented)

The engine derives each stage's 8-token display state from the durable artifacts
the lifecycle engine itself writes — the SAME files `StageDisplay.cs` reads. The
derivation is a simple, honest evidence check, not a re-implementation of the
next-action engine:

- **Evidence predicates** (all READ-ONLY): `TaskSelected`, `PreflightDone`,
  `ReservationDone`, `HandoffDone`, `VerificationDone`, `PackageDone`,
  `ClaudeDecisionDone`, `CorrectionNeeded` (claude decision FIX),
  `CorrectionDone` (correction context + reverified), `TrialMode`,
  `GitMerged`, `CompletionDone`, `ChangeIdKnown` (non-empty).
- **Pass rules**: a stage is PASS when its evidence predicate is true (and for
  conditional stages, when it applies).
- **Readiness rules**: after the last PASS stage, the next actionable stage is
  READY; the external-human stages are HUMAN_ACTION when they are the immediate
  next step (the guide tells the operator what to copy and where).
- **Conditional stages**: CORRECTION_LOOP is NOT_APPLICABLE unless the Claude
  decision is FIX; HUMAN_GIT_GATE and GOVERNED_COMPLETION are NOT_APPLICABLE in
  TRIAL mode (the governed trial-cycle closure path replaces them — DB-M12.4).
- **Current stage**: the first stage whose token is READY / HUMAN_ACTION /
  FAIL / BLOCKED is the operator's current position, surfaced at the top of the
  view.

The view records the exact `stateSource` (live vs fixture), the snapshot
`generatedAtUtc`, and a staleness note when `current-lifecycle-state.json` is
older than `current-task.json` — the operator always sees WHERE the state came
from.

### 3.3 Guidance cards

The view carries one card per integrated guidance system. Each card resolver is
fault-isolated (try/catch): a subsystem that is unavailable, disabled, or
misconfigured degrades to an honest `{status: NOT_AVAILABLE}` card with the
reason, never breaking the workflow view and never faking content.

1. **DependencyContext** — `Get-DbM181TaskDependencyContext` for the current
   task (Task shape + TaskCatalog built exactly as M05 does). Card: freshness
   status, direct-dependency count, context metrics, delivered-summary count,
   reuse/extension/collision points, package hash. When the current task has no
   dependencies or the evidence root is missing, the card reports that honestly.
2. **RoutingRecommendation** — `Get-AiRoutingRecommendation`. When the live
   routing policy is enabled the card shows the dry-run winner (provider/model/
   reasoning), estimated cost, eligible/rejected counts and the recommendation
   reason. When disabled (live config today), the card reports
   `NOT_ENABLED` with the DB-M19 gate note. DB-M30 never enables routing.
3. **CostGuidance** — `Invoke-DbM27Calculator` for an illustrative scenario
   (config default coding model, e.g. `deepseek-v4-flash`, INR, injected NowUtc)
   labelled as an estimate, plus the budget policy summary (DB-M21) and the
   history cost totals (actual/estimated) from DB-M25 cost resolution.
4. **ProviderHealth** — optional; `Get-EffectiveProviderHealth` for the current
   task's provider context (health state / circuit state), read-only. Empty
   evidence -> honest no-evidence note.
5. **History** — `Get-DbM26DashboardView` (aggregate summary cards) +
   `Get-DbM29TaskHistoryView` (per-task rows). On the live tree the DB-M17
   attempt store is EMPTY, so the card renders the honest empty state
   (`No attempt history recorded.`) — never invented history. Fixture records in
   tests prove the populated path.

Each card exposes an `Available` flag + `Status` token so the operator can see at
a glance what guidance exists at the current position.

### 3.4 Read-only posture, ReadOnlyGuard, markers

- The engine is PURE: artifacts/records/decisions in, `SupervisedWorkflowView v1`
  out. It never writes `state/`, `config/`, the workbook, or Nexus.
- `New-DbM30ReadOnlyGuard` mirrors the DB-M29 guard: `AutoExecutionEnabled=FALSE`,
  `PaidApiCalls=0`, `NetworkCalls=0`, `AttemptStoreModified=NO`,
  `EscalationDecisionsModified=NO`, `BudgetPolicyModified=NO`,
  `FingerprintsModified=NO`, `SecretValuesDisplayed=NO`,
  `SecretValuesLogged=NO`, `WorkbookModified=NO`, `NexusSourceModified=NO`.
- Every HTML emission passes `Test-DbM29SecretLeak`; the ONLY library disk write
  is `Export-DbM30WorkflowHtml`'s UTF-8 no-BOM `WriteAllText` of the
  operator-requested artifact.
- `Show-DbM30SupervisedWorkflow.ps1` follows the backend contract: **always
  exits 0**, outcomes ONLY via `DB30_OUTCOME` / `DB30_*` stdout markers. It
  prints the current stage, the next human action, and each guidance card's
  availability.

### 3.5 Fixture injection (deterministic, testable)

Like DB-M26/M28/M29, the engine takes NOW + state + records + decisions as
parameters. Tests inject:

- a fixture state dir (synthetic `current-task.json`,
  `current-lifecycle-state.json`, per-stage artifacts) to prove every lifecycle
  position,
- synthetic `AiAttemptRecord v1` fixtures (New-Att pattern from DB-M29) to prove
  the populated history/cost cards,
- an injected routing `Policy` (enabled) to prove the recommendation card
  without touching live config,
- an injected budget policy + a deterministic `NowUtc`.

The live tree is only ever READ (never written) by the engine; the test suite
proves the live `state/`, `config/`, the canonical workbook, and Nexus repos are
byte-identical before/after the run.

---

## 4. Contracts (scripts/supervised-workflow/WorkflowContracts.ps1)

- Schema versions: `SupervisedWorkflowView v1`, `WorkflowStage v1`,
  `GuidanceCard v1`, `ReadOnlyGuard v1`.
- `Get-DbM30StageCatalog` — the 13-stage catalog (key, label, order, human
  action, commands, evidence sources).
- `Get-DbM30StageVocab` — the 8 display tokens (reusing the engine vocabulary).
- `Get-DbM30CardStatuses` — `AVAILABLE | NOT_AVAILABLE | NOT_ENABLED | EMPTY`.
- `New-DbM30ReadOnlyGuard`, `Test-DbM30SecretLeak` (reuses the DB-M29 scanner),
  `Out-DbM30Markers`.

## 5. Engine (scripts/supervised-workflow/WorkflowEngine.ps1)

`Get-DbM30WorkflowView`:

1. Load lifecycle evidence from the state dir (live or fixture) + the per-change
   evidence tree; compute the evidence predicates (3.2).
2. Derive the 13 stage tokens; designate the current stage.
3. Assemble guidance cards (3.3), each fault-isolated.
4. Wrap in `New-DbM30ReadOnlyGuard` + warnings; return the view.

Dot-sources (READ-ONLY reuse chain): `DependencyLineage.ps1`, `Router.ps1`,
`calculator\CalculatorEngine.ps1`, `dashboard\DashboardData.ps1`,
`task-history\HistoryEngine.ps1`, `AttemptStore.ps1`, budget/provider-health
contracts. Subsystem loads are lazy and fault-isolated so a disabled/missing
subsystem degrades to an honest card.

## 6. Renderer + terminal controller

- `WorkflowRender.ps1` — `ConvertTo-DbM30Html` (self-contained HTML: stage
  checklist with tokens, current-stage banner, guidance cards, guard footer)
  + `Export-DbM30WorkflowHtml -View -OutputPath`.
- `Show-DbM30SupervisedWorkflow.ps1` — terminal guide: prints markers +
  current-stage summary + next human action + guidance availability.

## 7. Immutable boundaries (verbatim constraints)

- The DB-M30 guide NEVER advances the lifecycle, executes a model/provider,
  invokes ChatGPT/Claude Code/Claude, creates/approves/merges PRs, modifies the
  roadmap, or restores the baseline. Every one of those steps belongs to the
  human operator (or to Nexus Developer later).
- TRIAL mode: GOVERNED_COMPLETION and HUMAN_GIT_GATE are NOT_APPLICABLE; the
  governed trial-cycle closure path (DB-M12.4) is the completion route.
- Routing policy / model enablement / budget / health are NEVER modified.
- The canonical Nexus workbook, Nexus source, DevBridge source outside the owned
  list, live lifecycle state, config, and Git are byte-identical after the run.

## 8. Files changed (DB-M30-owned ONLY)

| File | Change |
|---|---|
| `design/DB-M30_SUPERVISED_DEVELOPMENT_WORKFLOW_INTEGRATION.md` | NEW design |
| `scripts/supervised-workflow/WorkflowContracts.ps1` | NEW contracts + vocab + guard + markers |
| `scripts/supervised-workflow/WorkflowEngine.ps1` | NEW engine `Get-DbM30WorkflowView` |
| `scripts/supervised-workflow/WorkflowRender.ps1` | NEW HTML renderer + export |
| `scripts/supervised-workflow/Show-DbM30SupervisedWorkflow.ps1` | NEW terminal guide |
| `scripts/supervised-workflow/Test-DbM30SupervisedWorkflow.ps1` | NEW test suite |
| `state/db-m30-result.json` | NEW milestone result |
| `state/db-m30-test-run.log` | NEW test run log |
| `tasks/DB-M30_IMPLEMENTATION_REPORT.md` | NEW implementation report |

No existing file is modified. All existing subsystems are consumed READ-ONLY.

## 9. Test matrix (planned)

- **A1-A9** workflow contracts + stage catalog (13 stages, vocab, order,
  human actions, command references).
- **B10-B18** engine stage derivation across lifecycle positions (no task /
  preflight done / reserved / handoff done / verification done / package done /
  claude decision done / correction FIX / correction verified).
- **C19-C26** guidance cards (dependency context present/absent, routing
  disabled -> NOT_ENABLED / enabled -> recommendation, cost estimate +
  budget, provider health no-evidence, history empty-store honest + populated
  fixture, secret-leak on every HTML emission).
- **D27-D31** non-mutation (no lifecycle-state write, no attempt store write,
  no config write, workbook byte-identical, live state byte-identical).
- **R32-R36** regressions (DB-M29, DB-M26, DB-M28, DB-M18.1 frozen files
  byte-identical; build 0 errors / 0 warnings).
- **I37-I39** invariants (workbook hash, Nexus repo status, solution build).

## 10. Known limitations

- The live routing policy is DISABLED (`routingDefaults.enabled=false`), so the
  routing-recommendation card truthfully reports NOT_ENABLED until the operator
  enables the DB-M19 dry-run gate. Cost guidance and history remain available.
- The live DB-M17 attempt store is EMPTY, so the History card shows the honest
  empty state. The populated path is proven by fixture records in the suite.
- DB-M30's stage map is evidence-grounded from the durable lifecycle artifacts;
  the C# `NextActionEngine` remains the authoritative next-action source. The
  two agree by construction (same artifacts), and the view records its
  `stateSource` for transparency.
