# DB-M26 -- AI Usage / Cost Dashboard: Implementation Report

Date (UTC): 2026-08-31  |  Lane B  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing built here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency. Do NOT design DB-M26 for Nexus migration.

---

## 1. What this milestone delivered

A read-only operator-facing AI analytics dashboard: **one self-contained HTML
artifact** that answers the brief's ten questions (total spend, on what, verified
results, cheap-but-retry routes, failure cost, escalation cost, true cost per
verified success, savings, budgets approaching limits, provider failures driving
waste). The engine and renderer live entirely in DB-M26-owned files under
`scripts/ai-routing/dashboard/`; every number derives READ-ONLY from the
existing foundations and is never a divergent alternate metric.

### 1.1 Engine + contracts (DashboardContracts.ps1 / DashboardData.ps1)

- **DashboardRequest v1** -- deterministic window presets (TODAY / LAST_7_DAYS /
  LAST_30_DAYS / THIS_MONTH / CUSTOM / ALL_TIME) resolved against a NowUtc
  reference, plus optional Provider/Model/UnderlyingModel/Gateway/TaskType/
  ReasoningLevel/LocalOrRemote filters (case-insensitive, DB-M25 semantics).
- **DashboardView v1** -- SummaryCards, CostBreakdown, VerifiedSuccessView,
  QualityAdjustedCostView, SavingsView, FailedCostView, BudgetView,
  ProviderHealthView, ModelPerformanceView, AttemptHistory, ChainView,
  LocalOpenRouterView, ConfidenceSummary, ReadOnlyGuard. Schema-validated and
  secret-leak guarded (DB-M25 wrapper READ-ONLY).
- **DB-M25 is the single evidence source**: verified success, chain cost,
  escalation cost, failed-attempt cost, savings, confidence and cost-per-success
  all come from `QualityCost.ps1` / `AiQualityCostContracts.ps1` (dot-sourced
  READ-ONLY). The dashboard never recomputes an inconsistent metric.
- **Spend split** (reporting pass, DB-M16 semantics): ACTUAL vs ESTIMATED
  pending; estimated cost is labelled and excluded from verified-success cost
  unless estimated-cost fallback is enabled (S06).

### 1.2 Renderer (DashboardRender.ps1)

11 tabbed views (summary cards, cost breakdown, quality-adjusted cost, savings,
failed cost, budget, provider health, model performance, verified success,
attempt history, chains, local/OpenRouter, confidence), a read-only footer
(`READ-ONLY ANALYTICS`, auto-execution, write-actions, policy version, provider/
model executed, paid calls, network calls), confidence badges
(INSUFFICIENT/LOW/MODERATE/HIGH), budget WARNING/BLOCKED badges, and the explicit
"the dashboard never grants budget overrides" note. The **only** write in the
library is `Export-DbM26DashboardHtml`'s `[System.IO.File]::WriteAllText` of the
operator-requested HTML artifact.

## 2. Test suite (task #47) -- Test-DbM26Dashboard.ps1

45 scenarios, **382 assertions, 0 failed, exit 0**. Highlights:

- S01-S05 dashboard loads / empty state / one attempt / fail+pass chain /
  cumulative cost (fail 3 + fail 6 + pass 10 = **19**, running 3/9/19).
- S06-S07 actual vs estimated spend; a model self-PASS with failed verification
  is CONTRADICTED, never success.
- S08-S12 failed-attempt cost, provider-failure vs model-quality separation,
  escalation cost (3+6), correction cost (full multi-attempt chain).
- S13-S17 first-attempt success rate, cost per verified success, savings with
  explicit baseline (13 vs 5 -> absolute 8 / 61.54%), confidence + sample on
  every recommendation-like analytic.
- S18-S22 filters: task type / provider / model / reasoning / CUSTOM window.
- S23-S25 direct `prov-a|model-a|(none)` vs gateway `prov-a|model-a|openrouter`
  stay separate, underlying model preserved, LOCAL = LOCAL_COST_UNKNOWN (never
  invented as FREE).
- S26-S29 budget WARNING at 90/100 and BLOCKED at 120/100; provider health +
  circuit state displayed from the passed snapshot.
- S30-S32 attempt history preserved; failed attempts not hidden after success.
- S33-S40 token scans + guard assertions: zero write tokens, zero provider/
  network/paid tokens, zero pricing/router/budget/health mutation, PolicyVersion
  immutable 0.0.0, footer zeroes.
- S41-S42 canonical Nexus workbook SHA-256 F520060C byte-identical; all 18
  M12.x UI source files byte-identical, no DevBridge.UI reference.
- S43-S45 DB-M25 regression green (337/337), DB-M14..DB-M24 regressions green,
  build + schema validators pass on real artifacts.

## 3. Defects found and fixed (test-driven)

1. **DashboardRender.ps1 -- PowerShell 5.1 parse errors**: a variable holding a
   static method group (`$esc = [System.Net.WebUtility]::HtmlEncode`) cannot be
   invoked with `()` in PS 5.1, and bare function calls inside `.Append(...)` are
   parse errors. Fixed by wrapping every call in `$( ... )` and using the
   existing `ConvertTo-DbM26HtmlEscaped` helper.
2. **DashboardData.ps1 -- `$pid` collision**: `Get-DbM26ProviderHealthView`
   assigned to `$pid`, which is the read-only automatic PID variable; under
   `Set-StrictMode` any non-null provider-health snapshot threw "Cannot overwrite
   variable PID". Renamed to `$policyId`. Caught by S28/S29/S38.
3. **Test assertion mismatches** (caught by the first full run): the chain
   drilldown leaves non-escalated attempts with an empty Escalation string (not
   `'none'`, unlike history), and the footer renders `Paid calls:
   <strong>0</strong>` with a `<strong>` tag between label and value. Assertions
   corrected to match the real contract.

## 4. Scope discipline (non-negotiables honored)

- **Read-only analytics**: no AI model execution, no routing-policy change, no
  budget change, no provider-health change, no attempt-history edit.
  AUTO_EXECUTION_ENABLED = FALSE. Paid calls 0, network calls 0.
- **Temporary DevBridge boundary**: DB-M26 writes only under
  `scripts/ai-routing/dashboard/` + `design/ai-routing/DB-M26_AI_USAGE_COST_DASHBOARD.md`
  + `state/db-m26-result.json`. No Nexus runtime/architecture/contracts/services
  change. Not designed for Nexus migration.
- Authoritative workbook
  `C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx` SHA-256
  F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884 byte-identical
  before and after (S41).
- **M12.3 untouched**: all 18 M12.x UI source files under `src\DevBridge.UI`
  byte-identical (S42); DB-M12.3's lifecycle UI files are not modified.
- DB-M14/M16/M17/M19/M20/M21/M22/M23/M24/M25 frozen implementation files
  SHA-256 verified byte-identical (frozen-file post-check) and all their
  regressions green (S43/S44).
- No Nexus phases/milestones/roadmap hierarchy/architecture/goals/outcomes/
  acceptance criteria/dependencies modified. No Nexus source or workbook change.
  No Git PR/merge capability.

## 5. Verification results

- Test-DbM26Dashboard.ps1: **382/382 PASS, 45/45 scenarios, exit 0**.
- Regressions: DBM14 51/51, DBM16 167/167, DBM17 99/99, DBM19 136/136,
  DBM20 149/149, DBM21 Budget 77/77 + Fingerprints 74/74, DBM22 Health 68/68 +
  Failover 64/64, DBM23 203/203, DBM24 128/128, DBM25 337/337 -- all PASS, exit 0.
- Workbook and M12.x UI file hashes verified after the run (S41/S42).

## 6. Outputs

- design/ai-routing/DB-M26_AI_USAGE_COST_DASHBOARD.md
- scripts/ai-routing/dashboard/DashboardContracts.ps1
- scripts/ai-routing/dashboard/DashboardData.ps1
- scripts/ai-routing/dashboard/DashboardRender.ps1
- scripts/ai-routing/dashboard/Test-DbM26Dashboard.ps1
- state/db-m26-result.json

**Stop after DB-M26.**
