# DB-M26 — AI Usage / Cost Dashboard

**Lane B.** Consumes the completed AI foundations **READ-ONLY**. Builds an
operator-facing, **read-only analytics dashboard** that answers the ten
questions of the brief and exposes every summary metric to evidence
(drilldown), without executing any AI, mutating any policy/budget/health
state, or touching the Nexus roadmap / workbook / source / lifecycle UI.

**Temporary DevBridge boundary**: DB-M26 is DevBridge-only scaffolding. It is
NOT Nexus code, architecture, contract, service, library or infrastructure,
and is NOT designed for migration into Nexus. After DevBridge is validated,
the pre-DevBridge workbook backup and Nexus source/Git baseline are restored
and DevBridge is retired. DB-M26 performs ZERO writes to the workbook, Nexus
source, roadmap, or lifecycle UI (M12.x).

**AUTO_EXECUTION_ENABLED = FALSE.** No provider/model calls. Paid calls: 0.
Network calls: 0. The dashboard has no write actions and no navigation that
mutates any state.

---

## 1. Objective

Present, in one operator-facing surface:

| Brief question | Where it is answered |
|---|---|
| 1. How much are we spending? | Summary cards: Total AI Spend, Actual Spend, Estimated Pending Spend |
| 2. What are we spending it on? | Cost breakdown by provider/route/model/underlying model/task type/reasoning/success/failure/category/retry-escalation/local-remote/direct-gateway |
| 3. Which models/providers actually deliver verified results? | Verified-success view + Model performance view (DB-M24/DB-M25 verified-success semantics) |
| 4. Which routes look cheap but cause retries? | Quality-adjusted cost view (attempt price vs cost per verified success) + chain drilldown |
| 5. How much cost comes from failures? | Failed-cost view (failed-attempt cost, category split) |
| 6. How much cost comes from escalation? | Escalation cost card + escalation share + chain drilldown |
| 7. What is the true cost per verified success? | Cost Per Verified Success card + per-route expected/observed cost per success |
| 8. Where are we saving money? | Savings view (DB-M25 explicit-baseline analytics) |
| 9. Are budgets approaching limits? | Budget view (DB-M21 vocabulary; read-only) |
| 10. Are provider failures driving waste? | Provider-failure cost separation + provider health view (DB-M22; no polling) |

---

## 2. Read-only consumption map

DB-M26 does NOT duplicate business logic. It calls the foundations' public
functions with **fixture/state passed as parameters**; it never loads or
modifies their files, config, or stores.

| Foundation | Consumed READ-ONLY as | DB-M26 use |
|---|---|---|
| DB-M14 `AiRoutingContracts.ps1` | `Get-ContractProperty`, vocabularies (task type, complexity, risk, reasoning, execution mode, local/remote) | defensive field reads; filter validation |
| DB-M16 cost semantics | ActualCost preferred, EstimatedCost only under explicit fallback, reporting-currency only, no re-conversion | every cost figure on the dashboard |
| DB-M17 `AttemptStore.ps1` | `AiAttemptRecord` v1 shape + failure-category vocabulary | record input; attempt history; chain cost |
| DB-M19 router | `config/ai-routing.json` policyVersion `0.0.0` (read) | "router policy not modified" evidence; routing decision rows if present |
| DB-M20 `escalation/*` | `ClaudeReviewStatus` vocabulary; escalation field meanings | Claude-accepted display; escalation cost separation |
| DB-M21 `budget/*` | budget vocabulary + budget-state function (if present) | Budget view; warning/block status |
| DB-M22 `provider-health/*` | health/circuit/retry-after/evidence vocabulary + health snapshot | Provider health view; circuit state |
| DB-M23 `providers/common/AdapterContracts.ps1` | `Test-DbM23SecretLeak`, price statuses (CONFIGURED/FREE/LOCAL_COST_UNKNOWN/PRICE_UNKNOWN) | secret-leak guard; LOCAL != FREE display |
| DB-M24 `performance/*` | `Resolve-AiTaskChains`, `Resolve-AiChainFacts`, `Resolve-AiFilteredAttempts`, `Get-AiConfidenceLevel(s/Order)`, stats helpers, `Get-AiPerformanceSummaries` | window filtering; chain reconstruction; confidence bands; model performance evidence |
| DB-M25 `quality-cost/*` | `Resolve-DbM25FilteredAttempts`, `Resolve-DbM25VerifiedSuccess`, `Get-DbM25ChainCost`, `Get-DbM25QualityAdjustedCost`, `Get-DbM25SavingsAnalysis`, `Test-DbM25SecretLeak` | the entire quality-adjusted cost view, savings view, verified-success semantics, chain cost |

**No foundation file is modified.** DB-M26 ships only its own files under
`scripts\ai-routing\dashboard\` + `design\ai-routing\DB-M26_*` +
`state\db-m26-result.json` + `tasks\DB-M26_IMPLEMENTATION_REPORT.md`.

---

## 3. Architecture

```
scripts/ai-routing/dashboard/
  DashboardContracts.ps1   DB-M26-owned contracts: DashboardRequest v1,
                           DashboardView v1, vocabularies, secret-leak guard,
                           no-write-token guard, schema versions.
  DashboardData.ps1        Read-only aggregation engine: resolves windows,
                           filters records (DB-M24/DB-M25), builds the views
                           (summary cards, breakdowns, verified success,
                           quality-adjusted cost, savings, failed cost, budget,
                           provider health, model performance, attempt history,
                           chain drilldown, local/openrouter).
  DashboardRender.ps1      Self-contained HTML renderer: DashboardView -> one
                           HTML file with inline CSS/JS, no network, no writes
                           except the one requested output file.
  Test-DbM26Dashboard.ps1  45 scenario test suite + DB-M25 + relevant
                           regression suites.
```

**Data flow** (all read-only, deterministic):

```
NowUtc ref + DashboardRequest (window, filters, currency)
   -> resolve FromUtc/ToUtc (DB-M26 window vocabulary)
   -> Resolve-DbM25FilteredAttempts (DB-M25, CUSTOM window query)  [filtered records]
   -> Get-DbM25QualityAdjustedCost (DB-M25)                        [group results]
   -> Get-DbM25SavingsAnalysis (DB-M25)                            [savings]
   -> Get-DbM25ChainCost + Resolve-AiTaskChains (DB-M25/DB-M24)    [chains]
   -> Get-AiConfidenceLevel / stats (DB-M24)                       [confidence/sample]
   -> budget state (input) + DB-M21 vocabulary                     [budget view]
   -> provider-health snapshot (input) + DB-M22 vocabulary         [health view]
   -> DashboardView v1  --ConvertTo-DbM26Html-->  db-m26-dashboard.html
```

The dashboard engine is **pure**: it takes `-Records` (attempts), `-NowUtc`,
`-BudgetState`, `-ProviderHealthState` and `-Request` as parameters and returns
a `DashboardView`. Nothing is loaded from or written to any store by the
engine; a caller decides where records/state come from.

---

## 4. Contracts

### 4.1 `DashboardRequest v1`

| Field | Meaning |
|---|---|
| `SchemaVersion` | 1 |
| `RequestId` | optional identifier |
| `PresetWindow` | `TODAY` \| `LAST_7_DAYS` \| `LAST_30_DAYS` \| `THIS_MONTH` \| `CUSTOM` \| `ALL_TIME` |
| `FromUtc` / `ToUtc` | explicit bounds (CUSTOM; either may be null = open) |
| `NowUtc` | deterministic reference (default UtcNow); resolved by `ConvertTo-AiPerfUtc` |
| `ProviderId` | filter (case-insensitive) |
| `ModelId` | filter |
| `UnderlyingModelId` | filter |
| `GatewayProviderId` | filter (direct vs gateway separation) |
| `TaskType` | filter |
| `ReasoningLevel` | filter |
| `LocalOrRemote` | filter |
| `ReportingCurrency` | default INR |
| `AllowEstimatedCostFallback` | false default (DB-M16 semantics) |
| `SuccessDefinition` | default VERIFIED (DB-M25) |
| `RequiresClaudeReview` | default false (review gate off unless asked) |

Windows are resolved deterministically against `NowUtc`:

- `TODAY`: `NowUtc.Date` .. `NowUtc`
- `LAST_7_DAYS`: `NowUtc.AddDays(-7)` .. `NowUtc`
- `LAST_30_DAYS`: `NowUtc.AddDays(-30)` .. `NowUtc`
- `THIS_MONTH`: `new DateTime(NowUtc.Year, NowUtc.Month, 1, 0, 0, 0, DateTimeKind.Utc)` .. `NowUtc`
- `CUSTOM`: explicit `FromUtc`/`ToUtc`
- `ALL_TIME`: open

Every metric in the view is computed over ONE window; windows are never mixed
without a label. The `DashboardView` carries `WindowStartUtc`/`WindowEndUtc`
and each view section carries the same window.

### 4.2 `DashboardView v1`

Top-level payload (all fields derived from the single filtered record set and
the passed state):

```
SchemaVersion, RequestId, PresetWindow, FromUtc, ToUtc, NowUtc, Currency,
SuccessDefinition, GeneratedAtUtc,
SummaryCards            { TotalAiSpend, ActualSpend, EstimatedPendingSpend,
                          VerifiedSuccessfulTasks, CostPerVerifiedSuccess,
                          FirstAttemptSuccessRate, FailedAttemptCost,
                          EscalationCost, CorrectionCost,
                          QualityAdjustedSavings, BudgetUsedPercent,
                          HealthyProviders, UnavailableOrRateLimitedRoutes }
CostBreakdown           { Provider[], Route[], Model[], UnderlyingModel[],
                          TaskType[], ReasoningLevel[], Success[],
                          FailureCategory[], RetryEscalation[], LocalOrRemote[],
                          DirectVsGateway[] }      // each: key + cost
VerifiedSuccessView     [ per-task/route: AttemptCompleted, ImplementationVerified,
                          ClaudeAccepted, HumanGitPending ]
QualityAdjustedCostView [ DB-M25 group results, ranked by cost per verified success ]
SavingsView             [ DB-M25 savings analyses with baseline always shown ]
FailedCostView          { ModelQuality, ProviderFailures, RateLimit, Auth,
                          Timeout, BuildTest, Verification, ClaudeFixReview }
BudgetView              { TaskBudget, SessionBudget?, Daily?, Monthly?, ActualSpend,
                          EstimatedPending, Projected, WarningThreshold, BlockThreshold,
                          Status, OverrideEvidence }
ProviderHealthView      [ per route: Provider, Route, Health, CircuitState,
                          RetryAfter, LastEvidenceTime, ConfidenceSource ]
ModelPerformanceView    [ per route: verified success rate, first-attempt rate,
                          attempts/success, cost/success, escalation rate,
                          confidence, sample ]
AttemptHistory          [ per attempt: Task, Change, AttemptId, Provider, Model,
                          Reasoning, Result, Verification, Cost, FailureCategory,
                          Escalation, TimestampUtc ]
ChainView               [ per task chain: attempts + cumulative cost, terminal
                          outcome, verified flag, correction loop ]
LocalOpenRouterView     [ same underlying model direct vs OpenRouter rows kept
                          separate; LocalCostStatus shown, never invented 0 ]
ConfidenceSummary       [ per analytic: ConfidenceLevel + SampleSize ]
ReadOnlyGuard           { AutoExecutionEnabled=false, HasWriteActions=false,
                          PolicyVersion='0.0.0', Warnings[] }
```

---

## 5. Summary cards (derivation)

All numbers come from the filtered records through the DB-M25/DB-M24 engine —
never a divergent alternate metric computed ad hoc in the UI:

| Card | Derivation |
|---|---|
| Total AI Spend | sum of usable cost over executed attempts (DB-M16 semantics) |
| Actual Spend | portion of Total AI Spend sourced ACTUAL |
| Estimated Pending Spend | portion sourced ESTIMATED (labelled estimated) |
| Verified Successful Tasks | count of chains whose terminal outcome is a DB-M25 verified success |
| Cost Per Verified Success | `ObservedCostPerVerifiedSuccess` (or labelled expected) from the DB-M25 group result for the default route |
| First-Attempt Success Rate | DB-M25 `FirstAttemptVerifiedSuccessRate` (or DB-M24 `Get-AiFirstAttemptSuccessRate`) |
| Failed Attempt Cost | DB-M25 `FailedAttemptCost` |
| Escalation Cost | DB-M25 `EscalationCost` |
| Correction Cost | DB-M25 `AverageCorrectionCost` x count, or chain correction cost |
| Quality-Adjusted Savings | DB-M25 `AbsoluteSavings` of the savings view (baseline always shown) |
| Budget Used % | budget view: `ActualSpend / budget * 100`, against warning/block thresholds |
| Healthy Providers | from provider-health snapshot (DB-M22 vocabulary) |
| Unavailable/Rate-Limited Routes | from provider-health snapshot + provider-failure cost evidence |

---

## 6. Verified-success view semantics

Distinguishes, per task/attempt, using DB-M25 `Resolve-DbM25VerifiedSuccess`
and DB-M17 record fields:

- **Attempt completed** — the model finished (Result present), regardless of verification.
- **Implementation verified** — `VerificationResult = VERIFIED` (DB-M06-style independent evidence).
- **Claude accepted** — `ClaudeReviewStatus = PASS` (DB-M20 vocabulary) where review applies.
- **Human Git pending** — terminal success whose Git/merge gate is still pending
  (surfaced as a labelled status, never as a stronger success than the evidence allows).

A model self-reported PASS with `VerificationResult = FAILED` is shown as
**contradicted**, never as success. A review `PENDING`/`FIX_REQUIRED` on a
success claim is shown as **not yet accepted** (REVIEW_REJECTED under the
review gate). DB-M25 `VerifiedSuccessSemantics` is authoritative.

---

## 7. Read-only rule

The rendered HTML contains **no** button, control, or script that writes to any
store. There are no actions for changing routing policy, the model catalogue,
prices, budgets, provider health, or attempt history, and no model execution.
A `ReadOnlyGuard` section is asserted by tests: `AutoExecutionEnabled=false`,
`HasWriteActions=false`, `PolicyVersion='0.0.0'`, and the source of every
`.ps1` in `dashboard\` is grep-scanned for write tokens (no
`Set-Content/Out-File/Add-Content/New-Item/Remove-Item/Invoke-WebRequest`,
no workbook/roadmap/lifecycle references).

---

## 8. UI isolation

DB-M26 ships a **fully self-contained HTML dashboard** (`ConvertTo-DbM26Html`)
in its own module. It does **not** merge into the M12.3 lifecycle UI and does
not modify `src/DevBridge.UI` or any M12.x-owned file. No shared shell or
navigation is touched. (The only output file is the one the operator requests,
written by an explicit render call — `dashboard\` library files themselves
perform no writes.)

---

## 9. Visuals

Summary cards, tables, simple horizontal bars (pure HTML/CSS, no external
libraries, no network), trend counts, filter controls (window + dimensions),
and a chain drilldown (expandable rows with cumulative cost). Low-sample
figures are greyed with an `INSUFFICIENT/LOW` confidence badge and a sample
size; a percentage is never shown without its baseline. Traceability beats
decoration.

---

## 10. Tests (45 scenarios)

`Test-DbM26Dashboard.ps1` implements the 45 required scenarios:

S01 dashboard loads (view valid + HTML non-empty)
S02 empty data state
S03 one attempt
S04 fail + pass chain
S05 cumulative cost correct
S06 actual vs estimated displayed correctly
S07 verified success semantics respected
S08 failed attempt cost shown
S09 provider failure separated
S10 model-quality failure separated
S11 escalation cost shown
S12 correction cost shown
S13 first-attempt success shown
S14 cost per verified success shown
S15 savings baseline shown
S16 savings confidence shown
S17 insufficient evidence labelled
S18 task-type filter
S19 provider filter
S20 model filter
S21 reasoning filter
S22 date filter
S23 direct vs gateway separated
S24 underlying model preserved
S25 local cost unknown handled
S26 budget warning displayed
S27 budget blocked displayed
S28 provider health displayed
S29 circuit state displayed
S30 attempt history preserved
S31 chain drilldown works
S32 failed attempts not hidden
S33 no write actions exist
S34 no provider execution
S35 no pricing mutation
S36 no router-policy mutation
S37 no budget override
S38 no provider-health mutation
S39 zero network calls
S40 zero paid calls
S41 no Nexus/workbook mutation
S42 M12.3 files untouched
S43 DB-M25 regression remains green
S44 relevant AI regressions remain green
S45 build passes (dot-source + full engine run + render)

---

## 11. Outputs

- `design\ai-routing\DB-M26_AI_USAGE_COST_DASHBOARD.md` (this file)
- `scripts\ai-routing\dashboard\DashboardContracts.ps1`
- `scripts\ai-routing\dashboard\DashboardData.ps1`
- `scripts\ai-routing\dashboard\DashboardRender.ps1`
- `scripts\ai-routing\dashboard\Test-DbM26Dashboard.ps1`
- `state\db-m26-result.json`
- `tasks\DB-M26_IMPLEMENTATION_REPORT.md`

Frozen-file proof: DB-M14/16/17/19/20/21/22/23/24/25 implementation files are
SHA-256 verified byte-identical before/after the DB-M26 run; config files are
byte-identical; the workbook SHA stays F520060C...; M12.x UI files untouched.
