# AI_ROUTING_ARCHITECTURE.md — DB-M13 Design

**Milestone:** DB-M13 · **Lane:** B — AI ROUTING DISCOVERY · **Status:** DESIGN ONLY
**Root:** `C:\Personal\DevTools\DevBridge`
**Date:** 2026-08-30

This document is the **design proposal** for adding the MODEL ROUTER, AI COST CONTROLLER, AUTOMATIC
MODEL ESCALATION ENGINE, and MODEL PERFORMANCE / USAGE INTELLIGENCE to the existing architecture.
It is **not** an implementation. No executable model-router code is introduced by DB-M13.

**Governing charter:** ADR-005 — *"AI capability is abstracted as `AiRole -> Provider -> Model ->
Configuration` (no business logic branches on provider name)."* Every design element below is a
direct implementation of that contract, and the existing manual lifecycle
`Development Control → DevBridge → ChatGPT → DeepSeek → Verification → Claude → Completion` is
preserved as the **MANUAL** default.

---

## 1. Component map — future AI routing services

The brief names logical interfaces `IAiProvider`, `IAiModel`, `IModelRouter`, `IModelPricingService`,
`ICostCalculator`, `IEscalationEngine`, `IModelPerformanceService`, `ITaskClassifier`,
`IContextBudgetService`.

DevBridge is PowerShell 5.1 with a **dot-source library + JSON contract** convention
(`Read-DevelopmentControl.ps1` is the model). PowerShell has no interface keyword, so each logical
interface maps to a **contract = dot-sourced library script exporting functions + a JSON schema**.
Names may adjust to the naming convention (`*-AiProvider`, `*-Router`, …) during DB-M14; the logical
name is retained here for traceability.

### 1.1 IAiProvider — provider adapter

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/AiProvider.ps1` (library) + `config/providers.json` |
| Responsibility | Uniform call surface for one AI provider (Claude, DeepSeek, OpenAI, local, OpenRouter). Maps a *capability request* to a provider-specific request (endpoint, model, reasoning level, token budget) and returns a **standardized attempt result**. Also exposes `Test-ProviderHealth`. |
| Inputs | Provider id, capability request (model id, reasoning level, context budget), prompt package, options |
| Outputs | `attempt` result record (tokens, cost-eligible usage, result, latency) or health verdict |
| Dependencies | `config/providers.json` (connection, non-secret), secrets via **env vars only** (UserSecrets pattern, §9 discovery); `IAiModel` for model capabilities |
| Persistence need | None (attempt persisted by the router layer) |
| UI exposure | None in DB-M13; DB-M12 UI may expose provider health/status later |
| Lifecycle integration | **Model execution** point (AUTO); in MANUAL/ASSISTED it remains a contract for the human launcher (`deepcode.ps1` is the reference adapter behavior) |

### 1.2 IAiModel — model catalog descriptor

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `config/models.json` (data) + `scripts/ai-routing/ModelCatalog.ps1` accessor |
| Responsibility | Describe one model's **capabilities** (context window, supported reasoning levels, task support, latency class, pricing pointer, effective-dated eligibility) |
| Inputs | Model id |
| Outputs | Capability descriptor object |
| Dependencies | None (static data + verified pricing reference) |
| Persistence need | Catalog file (config data, versioned) |
| UI exposure | Config editor in future UI |
| Lifecycle integration | Consumed by router (filtering), cost calculator (pricing lookup), context budget service (context window) |

### 1.3 IModelRouter — routing decision engine

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/ModelRouter.ps1` + `config/routing-policy.json` |
| Responsibility | Given a **task profile + capability requirements + constraints**, produce a **ranked routing decision**: eligible models, chosen model, reasoning level, estimated cost, budget pass/fail, fallback chain, and the recommendation reason — **all by capability, never by provider-name branching** |
| Inputs | Task profile (`ITaskClassifier` output), capability requirements (RequiresCoding, Complexity, Risk, ContextRequirement, CostLimit, LatencyPreference), provider health, pricing |
| Outputs | `routingDecision` record (chosen model, ranked alternatives, estimated cost, budget verdict, fallbacks, rationale) |
| Dependencies | `ITaskClassifier`, `IAiModel`, `IModelPricingService`, `ICostCalculator`, `IModelPerformanceService` (feedback), provider health |
| Persistence need | Decision embedded in the attempt record + `tasks/ROUTING_RECOMMENDATION.md` for humans |
| UI exposure | Recommendation surfaced in UI (DB-M12 later); never overrides human |
| Lifecycle integration | **Model recommendation** (ASSISTED), and the dispatch point for **model execution** (AUTO) |

### 1.4 IModelPricingService — effective-dated pricing data access

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/ModelPricing.ps1` + `config/pricing/*.json` (data files) |
| Responsibility | Look up the price for `(provider, model, currency, date, processing tier, time band)` honoring the **effective-date window**; cache lookups |
| Inputs | Provider, model, date, currency, tier, time band |
| Outputs | Price quote (input / cached-input / cache-write / output / reasoning / tool-call / media prices) |
| Dependencies | `config/pricing/*.json` data (verified, versioned); no provider calls |
| Persistence need | Data files + verification metadata (`Source`, `VerifiedAt`) |
| UI exposure | Pricing review tool (later) |
| Lifecycle integration | **Cost estimation** (pre-execution) and **actual-cost** finalize (post-execution) |

### 1.5 ICostCalculator — cost computation

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/CostCalculator.ps1` |
| Responsibility | Token usage × pricing → **estimated cost** and **actual cost**; currency + exchange rate; **quality-adjusted cost** (DB-M25 hook) |
| Inputs | Token usage (input / cached / output / reasoning / tools / media), pricing quote, currency, exchange rate |
| Outputs | `costRecord` (estimated/actual, currency, exchange rate, breakdown) |
| Dependencies | `IModelPricingService`, `IAiModel` |
| Persistence need | Cost embedded in attempt record + budget record |
| UI exposure | Cost display (later) |
| Lifecycle integration | **Cost estimation**, **budget gate**, **attempt finalize** |

### 1.6 IEscalationEngine — retry / escalation decision

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/EscalationEngine.ps1` + `config/escalation-policy.json` |
| Responsibility | Given an attempt result + failure category, decide: **retry same model / raise reasoning level / escalate to more capable model / fail over provider / escalate to human**. Reuses the existing `AI-Config\ESCALATION-RULES.md` vocabulary (12 conditions, ISSUE/AFFECTED TASK/AFFECTED FILES/OPTIONS/RECOMMENDATION/STATUS report) |
| Inputs | Attempt result, failure category, retry number, budget remaining, provider health, policy |
| Outputs | `escalationDecision` (next action, target, reason) |
| Dependencies | `ICostCalculator`, `IModelPerformanceService`, `IModelRouter`, provider health |
| Persistence need | Escalation chain recorded on attempt record (EscalatedFrom/EscalatedTo) |
| UI exposure | Human approval gate for escalations above budget / to AUTO (later) |
| Lifecycle integration | **Retry**, **reasoning escalation**, **model escalation**, **provider failover**, **human review** |

### 1.7 IModelPerformanceService — usage / quality intelligence

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/ModelPerformance.ps1` + `state/attempts/` data |
| Responsibility | Aggregate attempt history → per-model metrics (success rate, latency, cost, failure fingerprints, context usage); **feedback to router** so recommendations improve over time |
| Inputs | Attempt records (DB-M17), verification results |
| Outputs | Model performance report; router feedback (success probabilities, quality-adjusted cost) |
| Dependencies | Attempt store, `IAiModel`, `ICostCalculator` |
| Persistence need | `state/attempts/` (JSON records) |
| UI exposure | Performance dashboard (later) |
| Lifecycle integration | **Post-completion intelligence**; feeds **model recommendation** and **escalation** |

### 1.8 ITaskClassifier — task capability profiling

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/TaskClassifier.ps1` |
| Responsibility | Map preflight + task evidence → **capability profile**: RequiresCoding, Complexity, Risk, ContextRequirement, CostLimit, LatencyPreference, TaskType, ReasoningLevel |
| Inputs | `state/preflight.json`, `state/current-task.json`, workbook node data (via `Read-DevelopmentControl.ps1`), build/test commands present |
| Outputs | `taskProfile` record |
| Dependencies | `Read-DevelopmentControl.ps1` (existing shared lib) |
| Persistence need | Profile attached to preflight evidence / attempt record |
| UI exposure | None (pure backend) |
| Lifecycle integration | **Task classification** — first routing hook, after DB-M03, before DB-M05 |

### 1.9 IContextBudgetService — context packaging budget

| Attribute | Design |
|---|---|
| Layer / project | DevBridge — `scripts/ai-routing/ContextBudget.ps1` |
| Responsibility | Given the chosen model's context window + task profile, decide how to **package context**: prioritize (scope, ADRs, dependencies, evidence) vs. deprioritize/omit low-value sections; estimate context tokens |
| Inputs | Context package candidates (DB-M05 sections), model context window, task profile |
| Outputs | Prioritized/trimmed package plan + `ContextTokens` estimate |
| Dependencies | `IAiModel`, `ITaskClassifier` |
| Persistence need | Token estimate stored on attempt/context record |
| UI exposure | None |
| Lifecycle integration | **Context packaging** — augments DB-M05 handoff (advisory only; deterministic handoff content untouched) |

---

## 2. Capability-based routing (NOT model-name branching)

Business logic must express **what the task needs**, never **which model to use**. A provider/model is
chosen by the router against those needs. This is ADR-005 enforced.

### 2.1 Task capability profile (output of ITaskClassifier)

| Capability | Type | Derivation (from existing evidence) |
|---|---|---|
| `TaskType` | enum | Node type: PLANNING / IMPLEMENTATION / VERIFICATION / REVIEW / RESEARCH / GOVERNANCE |
| `RequiresCoding` | bool | Does the reserved scope contain implementation files (changed-file classification) |
| `Complexity` | LOW/MEDIUM/HIGH | Scope size, number of mutation ops (13 mutating ops in DB-M06 contract), files, build/test presence |
| `Risk` | LOW/MEDIUM/HIGH | Preflight verdict (CLEAR vs. DEPENDENCY/OVERLAP/CONFLICT), open dependencies, audit findings, active change conflicts |
| `ContextRequirement` | LOW/MEDIUM/HIGH/VERY_HIGH | Estimated context package size (ADRs, existing assets, scope, evidence) |
| `CostLimit` | money or budget tier | Budget policy; optional per task |
| `LatencyPreference` | FAST/BALANCED/THOROUGH | Task urgency / human wait tolerance |
| `ReasoningLevel` | LOW/MEDIUM/HIGH/MAX | Derived from Complexity + Risk (design rule: HIGH risk or HIGH complexity ⇒ at least HIGH reasoning) |

### 2.2 Routing decision procedure (IModelRouter)

```
1. FILTER   eligible models  = models whose capabilities satisfy
             { context window ≥ ContextRequirement, task support ⊇ TaskType,
               latency class ≤ LatencyPreference, eligible on date }
2. SCORE    rank by (quality-adjusted cost asc, success likelihood desc,
             latency asc)  ← feedback from IModelPerformanceService
3. CHOOSE   top candidate as primary; next 1-2 as fallback chain
4. COST     estimated cost via ICostCalculator; compare to CostLimit/budget
5. VERDICT  BUDGET_PASS | BUDGET_EXCEEDED (→ lower cost alternative or escalate)
6. EMIT     routingDecision + tasks/ROUTING_RECOMMENDATION.md (human-readable)
```

**No `if ($model -eq "deepseek-v4-flash")` anywhere.** Provider/model names are **data**, selected by
the router; business logic consumes capabilities only. Policy is configuration
(`config/routing-policy.json`), never code.

---

## 3. Execution modes: MANUAL / ASSISTED / AUTO

### 3.1 MANUAL (current, preserved — the default)

- Flow unchanged: `DevBridge handoff → human → ChatGPT → DeepSeek → human → verification → Claude review`.
- DevBridge calls **no AI API**. Router contributes **observability only** (attempt/cost recording if
  the human opts in) — or nothing at all. DB-M05/DB-M07 artifacts are byte-identical.
- **Backward compatibility requirement (hard):** every DB-M13+ change must leave MANUAL fully usable
  with no router config present.

### 3.2 ASSISTED (target for DB-M16 → DB-M19 rollout)

- DevBridge computes and **surfaces a recommendation** before the human acts:
  - recommended model, reasoning level, estimated cost, budget verdict, fallback chain
  - written to `tasks/ROUTING_RECOMMENDATION.md` + recorded on the attempt record
  - context-packaging advice from `IContextBudgetService` (advisory; handoff file untouched)
- **Human executes** (still the existing manual channels / `deepcode.ps1`).
- Attempt record is created at recommendation time with `EstimatedCost`; actual tokens/cost are
  recorded at verification time (`ActualCost`). Budget gate is **advisory + enforced at verification**
  (a verified result that blew budget is flagged, not re-executed automatically).
- Rollout order: recommendation first (no behavior change) → then cost recording → then budget gate.

### 3.3 AUTO (future — documented, NOT implemented)

- DevBridge itself invokes providers via `IAiProvider.Execute` inside the lifecycle.
- **Transition requirements (must all be met before AUTO can be enabled):**
  1. DB-M14 provider abstraction complete + verified (Claude, DeepSeek, OpenAI/OpenRouter, local).
  2. DB-M15 pricing verified, DB-M16 cost calculator validated against a real invoice/receipt.
  3. DB-M17 attempt history with full audit trail (every attempt recorded, immutable append).
  4. DB-M18 classifier + context package validated on ≥ N real preflight records.
  5. DB-M19 router dry-run parity with human choices on historical tasks.
  6. DB-M20 escalation engine with **human approval for spend above budget** and for any provider change.
  7. DB-M21 budget gates + failure fingerprints; DB-M22 provider health/failover with
     **manual fallback when no provider is healthy**.
  8. **Governance gate:** new ADR + workbook governance update (Session Protocol amendment or Open
     Decision resolution) explicitly enabling AUTO, an explicit per-scope human enablement flag, and a
     global kill switch.
- AUTO must **not** change the recorded lifecycle order or the workbook's governance; it only
  automates the execution step inside the existing state machine, with the same verification/review.

---

## 4. AI Attempt record — schema v1 (design only, no DB migration)

Aim: **one canonical record per AI invocation**, tracing task → provider → model → cost → outcome →
escalation. Stored as JSON under `logs/tasks/<node>/<change>/attempts/<AttemptId>.json` (mirrored in
`state/attempts/<changeId>/`). Field names follow the brief exactly.

| Group | Field | Notes |
|---|---|---|
| Identity | `TaskId`, `MilestoneId`, `WorkItemId`, `ChangeId`, `AttemptId` | AttemptId = `ATT-<ChangeId>-NNN`; MilestoneId = roadmap milestone (M-…), WorkItemId = WI-… |
| Execution | `Provider`, `Model`, `Gateway`, `ReasoningLevel` | Gateway = execution channel (e.g., `anthropic-compatible`, `openrouter`) |
| Profile | `TaskType`, `Complexity`, `Risk` | From ITaskClassifier |
| Timing | `StartedAt`, `EndedAt`, `Duration` | UTC ISO-8601; Duration = ms |
| Tokens | `InputTokens`, `CachedInputTokens`, `OutputTokens`, `ContextTokens` | ContextTokens = packaged context size estimate |
| Cost | `EstimatedCost`, `ActualCost`, `Currency`, `ExchangeRate` | Estimated at recommendation; Actual at finalize |
| Outcome | `Result` | PASS / FAILED / BLOCKED / HUMAN_STOPPED / NO_OP |
| Verification | `VerificationResult` | VERIFIED / FAILED / PENDING (link to verification.json) |
| Failure | `FailureCategory` | From failure fingerprint taxonomy (DB-M21) |
| Escalation | `EscalatedFrom`, `EscalatedTo`, `RetryNumber`, `HumanIntervention` | Escalation chain; HumanIntervention = true when a human took over |
| Evidence | `FilesChanged`, `TestsPassed`, `TestsFailed` | Cross-checked by DB-M06 |

**Persistence rule:** JSON records only in DB-M13..M25 — **no DB migrations**. The schema is frozen at
DB-M14 (shared contract) and may be re-read by DB-M17+ without migrations. The DeepSeek completion
report template already carries the evidence fields (Result, Files created/modified/deleted, Tests
passed/failed/skipped, Warnings, Errors, Scope compliance, Known limitations) — the attempt record
consumes those directly.

---

## 5. Effective-dated pricing model — schema v1 (design only)

Stored as **data** in `config/pricing/*.json` (e.g., `2026-08-deepseek.json`, `2026-08-openai.json`),
versioned, with `Source` + `VerifiedAt` per row. **Rates are data, never hard-coded into executable
business logic during DB-M13** (and beyond, per the milestone constraint).

| Field | Type | Notes |
|---|---|---|
| `Provider`, `Model` | string | Matches IAiModel catalog |
| `Currency` | ISO-4217 | Per-row currency |
| `EffectiveFromUtc`, `EffectiveToUtc` | datetime | Effective-dated window (open-ended allowed) |
| `ProcessingTier` | string | e.g., `standard`, `batch` |
| `TimeBand` | string | e.g., `peak` / `off-peak` if provider differentiates |
| `Input` | decimal | Price per input token (1M basis) |
| `CachedInput` | decimal | Price per cached input token |
| `CacheWrite` | decimal | Price per cache write, where applicable |
| `Output` | decimal | Price per output token |
| `Reasoning` | decimal | Price per reasoning token, where applicable |
| `ToolCalls` | decimal | Per tool call, where applicable |
| `Images` / `Audio` / `Storage` | decimal | Per media unit / storage, where applicable |
| `Source` | string | Provider price page / snapshot URL |
| `VerifiedAt` | datetime | When a human or tool verified the row |

Lookup rule (IModelPricingService): exact `(Provider, Model, Currency, ProcessingTier, TimeBand)`
matching `EffectiveFromUtc ≤ date < EffectiveToUtc`. Missing row ⇒ **quote unavailable** ⇒ router
treats cost estimate as UNKNOWN (never guesses).

---

## 6. Router integration points — mapped to the existing lifecycle

| # | Integration point | Lifecycle position | Component | Behavior in MANUAL / ASSISTED |
|---|---|---|---|---|
| 1 | **Task classification** | After DB-M03 (preflight), before DB-M05 | ITaskClassifier | Emits `taskProfile`; ASSISTED records it |
| 2 | **Context packaging** | Within / alongside DB-M05 | IContextBudgetService | Advisory plan + ContextTokens; handoff file untouched |
| 3 | **Model recommendation** | Before human executes DeepSeek | IModelRouter | `tasks/ROUTING_RECOMMENDATION.md`; attempt record opened (EstimatedCost) |
| 4 | **Cost estimation** | At recommendation and at execution | ICostCalculator | Estimated vs. actual cost |
| 5 | **Budget gate** | Before execution + at verification | ICostCalculator + policy | ASSISTED: flag / suggest cheaper fallback; never silently re-run |
| 6 | **Model execution** | The DeepSeek run | IAiProvider (contract) | MANUAL/ASSISTED: human launches (deepcode.ps1); AUTO: provider execute |
| 7 | **Verification** | DB-M06 | attempt finalize | ActualCost, tokens, VerificationResult written |
| 8 | **Retry** | On failed verification / failed attempt | IEscalationEngine | Decide retry same model vs. escalate |
| 9 | **Reasoning escalation** | Same provider, higher reasoning | IEscalationEngine | Raise ReasoningLevel within model |
| 10 | **Model escalation** | More capable model (same or other provider) | IEscalationEngine + IModelRouter | EscalatedTo on attempt record |
| 11 | **Provider failover** | Provider unhealthy/rate-limited | IEscalationEngine + health | Alternate provider or **human fallback** |
| 12 | **Human review** | DB-M07 / DB-M08 | REVIEW packet (unchanged) + evidence | Router supplies attempt/cost summary as an **extra evidence section** in REVIEW_PACKET.md; review prompt + file manifest untouched |

---

## 7. Proof: DB-M05 and DB-M07 remain usable after the router exists

### 7.1 DB-M05 (ChatGPT handoff) — preserved
- `New-ChatGptHandoff.ps1` produces `CHATGPT_HANDOFF.md` **deterministically** (asserts no AI API, no
  workbook/Nexus change). The router never edits this file.
- The router emits a **separate, clearly-labeled** `tasks/ROUTING_RECOMMENDATION.md` (recommended model,
  reasoning, cost estimate, budget verdict, fallbacks). A human who wants the pure manual flow ignores
  it; a human using ASSISTED reads it before launching DeepSeek.
- The context-packaging advice (IContextBudgetService) is **advisory metadata**, not a rewrite of the
  handoff sections. Handoff remains a self-contained context package.

### 7.2 DB-M07 (Claude review) — preserved
- `REVIEW_PACKET.md`, `CLAUDE_REVIEW_FILES.md` (SHA256 manifest), and `CLAUDE_REVIEW_PROMPT.md`
  (verbatim `---BEGIN---`/`---END---` prompt, `Decision: PASS | FIX REQUIRED`) are provider-agnostic
  Markdown exchanged with a human. The router **does not touch the review prompt or the manifest**.
- The router may append an *attempt & cost summary* section to `REVIEW_PACKET.md` so the reviewer can
  see what models/costs produced the change — this is **additional evidence**, consistent with the
  packet's existing evidence-rich style, and it remains optional (empty when no routing data exists).

### 7.3 No single-provider dependence
- DevBridge consumes routing decisions by capability, not provider. Claude, DeepSeek, OpenAI,
  OpenRouter, and local models are interchangeable through `config/providers.json` + attempt records.
- The router's fallback chain **always terminates in a human path** (DB-M22 health/failover: "no
  healthy provider ⇒ manual execution") — so the system can never be locked to a single AI provider.

---

## 8. What DB-M13 does NOT do (boundaries)

- No executable model-router / cost-controller / escalation-engine code.
- No AUTO mode. No provider calls from DevBridge.
- No DB migrations. No changes to `config/development-control-map.json` or `config/sheet-governance.json`.
- No changes to DB-M03..M11 scripts, the workbook, or Nexus repositories.
- No hard-coded provider pricing into business logic (rates are data, DB-M15).

---

*End of architecture design. Sequencing and parallel-safety: `AI_ROUTING_MILESTONE_DEPENDENCIES.md` and
`AI_ROUTING_PARALLEL_PLAN.md`.*
