# DB-M27 -- AI Cost Calculator UI: Implementation Report

Date (UTC): 2026-08-31 18:00  |  Lane B  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing built here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency. Do NOT design DB-M27 for Nexus migration.

---

## 1. What this milestone delivered

An operator-facing **AI Cost Calculator UI** that ESTIMATES the expected monetary
cost of a model/provider configuration **BEFORE execution**. Calculation/UI only —
the calculator never executes a provider/model, never makes a paid API call, and
never makes a network call. One self-contained interactive HTML artifact rendered
by PowerShell, exactly like DB-M26.

The engine, contracts, renderer and test suite live entirely in DB-M27-owned files
under `scripts/ai-routing/calculator/`; every token→cost number comes from
**DB-M16 `Calculate-AiAttemptCost`** (the authoritative engine) consumed
READ-ONLY — no pricing formula, exchange rate, or rate is ever invented or
duplicated.

### 1.1 Contracts + engine (CalculatorContracts.ps1 / CalculatorEngine.ps1)

- **CalculatorRequest v1** — Provider, RouteType (DIRECT/GATEWAY/LOCAL), Model,
  UnderlyingModelId (gateway), PricingRecordId (optional override), ReasoningLevel,
  Input/Output/Cached-input/Cache-write tokens, AttemptCount,
  ExpectedCorrectionAttempts, optional EscalationPath, CurrencyTarget (USD/INR),
  injected NowUtc. Deterministic and validated.
- **CalculatorView v1** — Request echo, Scenario, Pricing (record id + status +
  effective window + lookup state + PriceStatus), Estimate (DB-M16 result incl.
  PerAttempt/TotalMultiAttempt + ESTIMATED-vs-ACTUAL labels), Quality (DB-M25/M24
  panel), EscalationSteps + EscalationTotal (read-only simulation), Budget
  (DB-M21 informational context), ReadOnlyGuard, selector data. Schema-validated.
- **DB-M16 is the single cost authority**: input cost = uncached tokens at input
  price, cached input at the cached rate, output at the output price,
  reasoning billed per `ReasoningTokenBilling=INCLUDED_IN_OUTPUT` (never double
  charged), cache-write **never billed on an ESTIMATE** (DB-M16 bills
  CacheWrite5m/1h only on ACTUAL usage) — shown as null with the explicit
  `CacheWriteBillingNote`, never a fabricated zero.
- **Pricing version always visible**: the effective record id + governed status
  (`NEEDS_REVIEW` for the effective anthropic record at the reference timestamp) +
  effective window are displayed; missing/stale pricing is an explicit
  `PRICE_NOT_FOUND`/`PRICE_UNKNOWN`/`LOCAL_COST_UNKNOWN` state, never a guessed
  number.
- **Currency**: USD identity or INR via the effective `fx-usdinr-dev-v2` (83.5)
  exchange rate from DB-M16 — verified 0.0310 USD → 2.5885 INR.
- **LOCAL != FREE**: no-record local routes surface `LOCAL_COST_UNKNOWN`
  (provider-level 0 is a default, never shown as a real zero); the UI states
  the invariant and never prints a fabricated `₹0`/`$0`.
- **OpenRouter/gateway identity preserved**: provider (openrouter) and underlying
  model are kept distinct; billing resolves to the underlying model's own
  catalogue entry (never collapsed, never `PRICE_UNKNOWN` by mistake).
- **Escalation estimate**: read-only per-step DB-M16 iteration along the operator
  path with running cumulative totals; `SimulationOnly=true`,
  `RoutingPolicyUnmodified=true`. Routing policy is never consulted or modified.
- **Quality-aware view**: observed verified-success rate, first-attempt success
  rate, observed + expected cost per verified success, sample size, confidence
  category (DB-M24 bands). Low-confidence evidence is explicitly labelled
  "NOT statistically reliable" and never presented as proven; with no observed
  evidence the panel honestly says there is none.
- **Budget context (DB-M21)**: task/daily/monthly limits, projected spend,
  estimated % consumed, per-scope decision. Purely informational:
  `OverrideAllowed=false`, `InformationalOnly=true` always. An over-limit attempt
  displays the policy verdict (`BLOCK_BUDGET_EXCEEDED`,
  `REQUIRE_HUMAN_OVERRIDE`) as context but the calculator **never grants,
  modifies, or overrides a budget** and never executes an attempt.

### 1.2 Renderer (CalculatorRender.ps1)

Self-contained interactive HTML (inline CSS/JS, embedded DB-M15 catalogue +
DB-M16 exchange-rate JSON, no network). Form controls for every supported input
(provider / route / model / underlying model / pricing version / reasoning level /
tokens / attempts / corrections / currency), an ESTIMATED PREVIEW panel
(browser recompute, explicitly labelled), the authoritative DB-M16 engine result
for the reference scenario (stamped, never changed by the page), quality panel,
escalation table, budget bar, and a read-only guard footer
(`AUTO EXECUTION DISABLED`, auto-execution, provider/model executed, paid calls,
network calls, budget/routing/pricing/health modification capability). The **only**
write in the library is `Export-DbM27CalculatorHtml`'s
`[System.IO.File]::WriteAllText` of the operator-requested HTML artifact.

## 2. Test suite -- Test-DbM27Calculator.ps1

46 scenarios (S1-S46), all against the real DB-M14..M26 implementations consumed
READ-ONLY (SHA-256 verified byte-identical before/after), plus deterministic
synthetic fixtures. **266 assertions, 0 failed, exit 0.**

Highlights:

- S1-S8 UI opens + provider/route (DIRECT/GATEWAY/LOCAL)/model/underlying-model
  selection + pricing-version display (record `anthropic-claude-sonnet-5-standard-20260830`,
  status `NEEDS_REVIEW`, effective window shown).
- S9-S16 token arithmetic via DB-M16: uncached input (0.01), output (0.02),
  cached input (0.001); cache-write is **null** on estimates with the billing
  note; subtotal 0.0310 USD; multi-attempt 3×0.0310 = 0.0930; INR via
  fx-usdinr-dev-v2 (83.5) → 2.5885.
- S17 ESTIMATED vs ACTUAL (nothing executed → `ActualCost` null, `EstimatedCost`
  present, distinct UI labels).
- S18-S20 missing pricing (`PRICE_NOT_FOUND`, `PRICE_UNKNOWN`) and local cost
  (`LOCAL_COST_UNKNOWN`, never FREE, no fabricated zero).
- S21-S23 gateway identity not collapsed; underlying model preserved; reasoning
  billed INCLUDED_IN_OUTPUT (no double charge).
- S24-S26 quality panel: 30 observed chains → MODERATE confidence, observed +
  expected cost per verified success 3.5, basis OBSERVED_CHAINS, one attempt per
  verified success; 3 chains → INSUFFICIENT, labelled not statistically reliable.
- S27-S28 escalation chain: sonnet 0.04 → haiku 0.02 → cumulative 0.06, read-only
  (SimulationOnly, RoutingPolicyUnmodified).
- S29 budget informational: TASK limit 100, projected 2.5885 INR (2.59% consumed),
  ALLOW; a blocked attempt surfaces BLOCK_BUDGET_EXCEEDED /
  REQUIRE_HUMAN_OVERRIDE yet `OverrideAllowed=false` — never granted.
- S30-S36 capability proofs: no budget-override / routing-decision /
  pricing-write / health-write / execution / network tokens in the calculator
  library; guard zeroes.
- S37-S42 child-suite regressions: DB-M16, DB-M21, DB-M23, DB-M24, DB-M25 all
  green; DB-M26 preserved at its current external signature (see §3).
- S43 DB-M18.1 preserved (child suite; known external R45 reported separately —
  see §3).
- S44 Lane C `src/DevBridge.UI` source files byte-identical.
- S45 `dotnet build src\DevBridge.slnx` 0 errors.
- S46 all M14-M26 + DB-M18.1 frozen files, config files, and the canonical Nexus
  workbook SHA-256 byte-identical after the run.

## 3. External drift (reported separately, never counted as DB-M27 failures)

Per the brief, DB-M27 must not treat pre-existing external drift as its own
failure. Three signatures are preserved and reported:

1. **M26 S41 workbook-authority drift** — the DB-M26 suite freezes the canonical
   workbook authority hash `F520060C`; the live workbook is `6D42C3BF...` after
   DB-M12.4's live trial-cycle closure (2026-08-31). DB-M26 S41 fails; DB-M27
   S46 independently proves the workbook is byte-identical across its own run.
2. **DBM181 R45** — pre-existing DB-M18 classification S27 fixture drift
   (known, external). DB-M18.1 is frozen and unmodified.
3. **DBM181 R50 (intermittent)** — the DB-M12.4 child suite is green standalone
   (54/54, exit 0) but can flake to exit 1 only under heavy sequential build load
   inside a parent suite. S43 proves the standalone green if it ever flakes and
   records it as an environment artifact.

## 4. Boundary compliance

- `AUTO_EXECUTION_ENABLED = FALSE`; Provider/model executed: **NO**;
  Paid API calls: **0**; Network calls: **0**.
- No governance mutation capability: workbook, roadmap, phase/milestone/
  dependencies, routing policy, provider health, pricing records, budget policy,
  Git PR/merge — all read-only inputs.
- Lane C (`src/DevBridge.UI`) untouched; DB-M26 untouched; DB-M18.1 untouched.
- DevBridge is temporary Phase 1/2 scaffolding; nothing here migrates into Nexus.

## 5. Files delivered

- `design/DB-M27_AI_COST_CALCULATOR_UI.md`
- `scripts/ai-routing/calculator/CalculatorContracts.ps1`
- `scripts/ai-routing/calculator/CalculatorEngine.ps1`
- `scripts/ai-routing/calculator/CalculatorRender.ps1`
- `scripts/ai-routing/calculator/Test-DbM27Calculator.ps1`
- `state/db-m27-result.json`
- `tasks/DB-M27_IMPLEMENTATION_REPORT.md` (this report)

**Ready for DB-M28: YES.** **Stop after DB-M27.**
