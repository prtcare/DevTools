# AI_ROUTING_MILESTONE_DEPENDENCIES.md — DB-M14 → DB-M25

**Milestone:** DB-M13 · **Lane:** B — AI ROUTING DISCOVERY · **Status:** DESIGN ONLY
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-30

Planned milestones for the AI Routing / Cost Platform. Every milestone below is **additive** (new
`config/`, `scripts/ai-routing/`, `state/`, `tasks/` content) and **never modifies** DB-M03–M11,
DB-M12 UI files (when they exist), the workbook, or Nexus repositories. Sequencing and parallel-safety
analysis: `AI_ROUTING_PARALLEL_PLAN.md`.

**Shared contracts** (frozen at DB-M14, consumed by all later milestones):
- `attempt` record schema v1 (§4 architecture doc)
- effective-dated pricing schema v1 (§5 architecture doc)
- routing request/response schema (taskProfile → routingDecision)
- provider catalog + health status shape

---

## DB-M14 — Provider abstraction

| Attribute | Value |
|---|---|
| Purpose | `IAiProvider` contract: provider catalog (`config/providers.json`), `AiProvider.ps1` library, credential handling via **env vars only** (UserSecrets pattern), `Test-ProviderHealth` stub, standardized attempt-result mapping |
| Dependencies | DB-M13 (this milestone); reads existing `AI-Config/deepcode.ps1` behavior as the reference adapter |
| Files / projects affected | NEW: `config/providers.json`, `scripts/ai-routing/AiProvider.ps1`, `config/ai-routing.json` (mode flag: `manual`/`assisted`/`auto`-disabled). None existing modified |
| Parallel-safe | **Yes for other milestones that do not consume provider execution**; this milestone **freezes the contracts** the rest consume |
| Shared contracts | attempt schema v1, provider catalog shape, health-status shape |
| Integration gate | Provider catalog loads with zero secrets in config; no provider call made; `mode = manual` is the only valid runtime value |

## DB-M15 — Pricing & versioning

| Attribute | Value |
|---|---|
| Purpose | `config/pricing/*.json` data files + `ModelPricing.ps1` effective-dated lookup; pricing versioning + `Source`/`VerifiedAt` metadata |
| Dependencies | DB-M13; DB-M14 contract freeze (schema alignment) |
| Files / projects affected | NEW: `config/pricing/2026-*.json`, `scripts/ai-routing/ModelPricing.ps1`. No existing files modified |
| Parallel-safe | **Yes** with DB-M16/DB-M17 once pricing schema is frozen (M14) |
| Shared contracts | pricing schema v1, IAiModel catalog reference |
| Integration gate | Lookup returns correct price for a known effective date; missing row ⇒ UNKNOWN, never a guess |

## DB-M16 — Cost calculator

| Attribute | Value |
|---|---|
| Purpose | `CostCalculator.ps1`: token × price → estimated/actual cost, currency + exchange rate, breakdown; budget-gate helper |
| Dependencies | DB-M15 (pricing data); DB-M14 contracts |
| Files / projects affected | NEW: `scripts/ai-routing/CostCalculator.ps1`. No existing files modified |
| Parallel-safe | **Yes** with DB-M17/DB-M18 (depends only on frozen schemas) |
| Shared contracts | costRecord shape (estimated/actual/currency/exchange rate) |
| Integration gate | Cost calculation validated against one real provider invoice/receipt; deterministic unit tests |

## DB-M17 — Attempt history

| Attribute | Value |
|---|---|
| Purpose | Attempt-record store: `logs/tasks/<node>/<change>/attempts/<AttemptId>.json` + `state/attempts/<changeId>/`; read/write accessors; append-only; `AttemptId = ATT-<ChangeId>-NNN` |
| Dependencies | DB-M14 attempt schema v1 |
| Files / projects affected | NEW: `scripts/ai-routing/AttemptStore.ps1`; NEW state/log dirs. No existing files modified |
| Parallel-safe | **Yes** with DB-M16/DB-M18; **must precede** DB-M20/DB-M24/DB-M25 (they read attempts) |
| Shared contracts | attempt schema v1 (persisted shape) |
| Integration gate | Attempt record round-trips (write → read) byte-stable; append-only enforced; no DB migration |

## DB-M18 — Task classifier & context package

| Attribute | Value |
|---|---|
| Purpose | `TaskClassifier.ps1` (taskProfile from preflight evidence) + `ContextBudget.ps1` (context packaging advice + ContextTokens estimate) |
| Dependencies | DB-M13; consumes `preflight.json` / `current-task.json` (read-only) and `Read-DevelopmentControl.ps1` |
| Files / projects affected | NEW: `scripts/ai-routing/TaskClassifier.ps1`, `scripts/ai-routing/ContextBudget.ps1`. No existing files modified |
| Parallel-safe | **Yes** with DB-M16/DB-M17; **must precede** DB-M19 (router consumes taskProfile) |
| Shared contracts | taskProfile shape, routing request/response schema (input side) |
| Integration gate | Classifier reproduces known profiles on ≥ N historical preflight records; handoff file untouched |

## DB-M19 — Router

| Attribute | Value |
|---|---|
| Purpose | `ModelRouter.ps1` + `config/routing-policy.json`: filter → score → choose → cost → budget verdict → emit `tasks/ROUTING_RECOMMENDATION.md`; capability-based, no provider-name branching (ADR-005) |
| Dependencies | DB-M16 (cost), DB-M18 (taskProfile), DB-M14 contracts |
| Files / projects affected | NEW: `scripts/ai-routing/ModelRouter.ps1`, `config/routing-policy.json`. No existing files modified |
| Parallel-safe | **Sequential after** DB-M16 + DB-M18; other milestones (M20+) can be designed in parallel but gate on it |
| Shared contracts | routing request/response schema; ROUTING_RECOMMENDATION.md format |
| Integration gate | Router dry-run parity with historical human model choices; MANUAL flow still works with `mode = manual` |

## DB-M20 — Retry & escalation engine

| Attribute | Value |
|---|---|
| Purpose | `EscalationEngine.ps1` + `config/escalation-policy.json`: retry / reasoning up / model up / provider failover / human escalate; reuses `AI-Config\ESCALATION-RULES.md` vocabulary |
| Dependencies | DB-M19 (router), DB-M17 (attempts), DB-M21 (budget/fingerprints) |
| Files / projects affected | NEW: `scripts/ai-routing/EscalationEngine.ps1`, `config/escalation-policy.json`. No existing files modified |
| Parallel-safe | **Design parallel** with DB-M21/DB-M22; **implementation gates on** DB-M19 + DB-M17 + DB-M21 |
| Shared contracts | escalationDecision shape; EscalatedFrom/EscalatedTo fields on attempt schema |
| Integration gate | Decision trace for each failure category matches the 12 escalation conditions; human-approval path for spend-above-budget |

## DB-M21 — Budget & failure fingerprints

| Attribute | Value |
|---|---|
| Purpose | Budget policy (`config/budget-policy.json`), budget gate helper, failure-fingerprint taxonomy (FailureCategory vocabulary consumed by escalation) |
| Dependencies | DB-M16 (cost), DB-M17 (attempts), DB-M18 |
| Files / projects affected | NEW: `config/budget-policy.json`, `scripts/ai-routing/BudgetGate.ps1`, `config/failure-fingerprints.json`. No existing files modified |
| Parallel-safe | **Yes** with DB-M20 (design) / DB-M22; implementation uses attempts data from DB-M17 |
| Shared contracts | FailureCategory enum, budget verdict shape |
| Integration gate | Budget gate flags and suggests cheaper fallback; never silently re-runs |

## DB-M22 — Provider health & failover

| Attribute | Value |
|---|---|
| Purpose | `ProviderHealth.ps1`: health checks (`Test-ProviderHealth`), failover ordering, **manual fallback when no provider is healthy** |
| Dependencies | DB-M14 (provider catalog), DB-M19 (router fallback chain) |
| Files / projects affected | NEW: `scripts/ai-routing/ProviderHealth.ps1`. No existing files modified |
| Parallel-safe | **Yes** with DB-M20/DB-M21 (design); gates on DB-M14 + DB-M19 for integration |
| Shared contracts | health-status shape, failover decision shape |
| Integration gate | Simulated provider outage routes to alternate provider, then to human; no provider dependence |

## DB-M23 — Local / OpenRouter adapters

| Attribute | Value |
|---|---|
| Purpose | Additional `IAiProvider` adapters: local models (Ollama-style), OpenRouter gateway (multi-provider) |
| Dependencies | DB-M14 (adapter contract), DB-M22 (health), DB-M19 (router eligibility) |
| Files / projects affected | NEW: `scripts/ai-routing/providers/LocalProvider.ps1`, `scripts/ai-routing/providers/OpenRouterProvider.ps1`, catalog entries. No existing files modified |
| Parallel-safe | **Yes** — isolated adapters; validates the abstraction is provider-agnostic |
| Shared contracts | provider catalog shape (unchanged), attempt schema (unchanged) |
| Integration gate | Local + OpenRouter adapters execute a dry-run request; catalog is multi-provider |

## DB-M24 — Performance intelligence

| Attribute | Value |
|---|---|
| Purpose | `ModelPerformance.ps1`: aggregate attempts → per-model success rate, latency, cost, failure fingerprints, context usage; router feedback |
| Dependencies | DB-M17 (attempts), DB-M19 (router), DB-M16 (cost) |
| Files / projects affected | NEW: `scripts/ai-routing/ModelPerformance.ps1`; reads `state/attempts/`. No existing files modified |
| Parallel-safe | **Yes** once attempts exist; independent of DB-M20-23 |
| Shared contracts | performance-report shape, router feedback shape |
| Integration gate | Report on historical attempts; router scores improve on re-run |

## DB-M25 — Quality-adjusted cost

| Attribute | Value |
|---|---|
| Purpose | Quality weighting on cost metric: cost per verified successful outcome (tie back to verification.json PASS + Claude review PASS) |
| Dependencies | DB-M24 (performance), DB-M17 (attempts), DB-M16 (cost), DB-M08 review results |
| Files / projects affected | NEW: `scripts/ai-routing/QualityAdjustedCost.ps1`; reads attempts + verification + review. No existing files modified |
| Parallel-safe | **Yes** after DB-M24; final intelligence milestone |
| Shared contracts | quality-adjusted-cost shape (feeds router SCORE step) |
| Integration gate | Quality-adjusted ranking differs sensibly from raw cost ranking on a labeled sample |

---

## Milestone dependency graph (text)

```
DB-M13 (this milestone — discovery + design, DONE)
   │
   ▼
DB-M14  Provider abstraction  ────────────────►  freezes: attempt v1, pricing v1, provider catalog, health shape
   │
   ├────► DB-M15  Pricing & versioning ────► DB-M16  Cost calculator ──────────┐
   │                                                                             │
   ├────► DB-M17  Attempt history ───────────────────────────────────────────────┤
   │                                                                             ▼
   └────► DB-M18  Task classifier & context ─────────────────────────────► DB-M19  Router
                                                                                 │
                                     ┌───────────────────────────────────────────┘
                                     ▼
                    DB-M21  Budget & fingerprints ──────► DB-M20  Retry & escalation ─► DB-M22  Health & failover
                                                                                            │
                                     ┌──────────────────────────────────────────────────────┘
                                     ▼
                    DB-M23  Local / OpenRouter adapters (isolated; parallel-safe throughout)
                                     │
                                     ▼
                    DB-M24  Performance intelligence ──► DB-M25  Quality-adjusted cost
```

Sequencing rationale and parallel-safe decomposition: `AI_ROUTING_PARALLEL_PLAN.md`.

---

*End of milestone dependencies.*
