# DB-M27 AI Cost Calculator UI

**Milestone:** DB-M27 — AI Cost Calculator UI
**Lane:** B (AI Routing / evidence engine)
**Date (utc):** 2026-08-31
**Implementation:** PASS
**Mode:** calculation / UI only — the calculator estimates expected monetary cost of a
model/provider configuration BEFORE execution. It never executes a model.

---

## 1. Objective (the brief)

| # | Question | Where it is answered |
|---|---|---|
| 1 | What will this provider/route/model cost for my token load? | Per-attempt estimate (DB-M16) |
| 2 | Which route type is being priced (DIRECT / GATEWAY / LOCAL)? | Provider record `ProviderType` (DB-M14 catalogue) |
| 3 | Which pricing record + version + effective window applies? | DB-M15 `Get-AiPricingRecordStatus` / `Get-AiPriceAt` |
| 4 | What is the cost of input / output / cached-input / cache-write? | DB-M16 `Calculate-AiAttemptCost` dims |
| 5 | What is the full multi-attempt estimate? | Attempt count x per-attempt (+ escalation path) |
| 6 | USD or INR? | DB-M16 currency conversion (fx-usdinr-dev-v1 / v2) |
| 7 | ESTIMATED vs ACTUAL — is the number real spend? | UsageSource / EstimatedOrActual label; nothing is executed |
| 8 | Is the LOCAL cost truly free, or unknown? | DB-M23 `Get-ProviderRoutePriceStatus` (LOCAL != FREE) |
| 9 | What does a verified success really cost at this quality level? | DB-M25 quality-adjusted cost + DB-M24 confidence |
| 10 | What would an escalation chain cost, cumulatively? | Read-only per-step M16 estimate along the operator path |
| 11 | Am I near a budget limit? | DB-M21 `Test-AiBudget` — informational only, never granted |

---

## 2. Boundary (NON-NEGOTIABLE)

- DevBridge is **TEMPORARY Phase 1/2 external scaffolding**; nothing from DB-M27
  migrates into Nexus.
- **Calculation/UI only.** The calculator computes and renders expected costs. It does
  NOT execute any provider/model: `AUTO_EXECUTION_ENABLED = FALSE`, `Provider/model
  executed: NO`, `Paid API calls: 0`, `Network calls: 0`.
- **No governance mutation** — the calculator cannot modify: Nexus workbook, roadmap,
  phase/milestone/dependencies, routing policy, provider health, pricing records, budget
  policy, or Git PR/merge. All of those are read-only inputs.
- **Do not duplicate existing pricing formulas.** Every token->cost number comes from
  DB-M16 `Calculate-AiAttemptCost` (the authoritative engine). The interactive HTML page
  embeds the DB-M15 catalogue + DB-M16 exchange-rate data as JSON and re-applies the
  documented per-million arithmetic client-side purely for live preview; those preview
  numbers are labelled `ESTIMATED PREVIEW` and the authoritative engine-computed result
  for the reference scenario is always stamped on the page. No pricing data, exchange
  rate, or rate is invented anywhere.
- **Do not modify DB-M18.1.** `DependencyLineage.ps1` and `Test-DbM181DependencyLineage.ps1`
  are frozen; R45 remains a pre-existing external DB-M18 drift and is reported separately.
- **Lane C off-limits.** `src/DevBridge.UI` (WPF operator console) is untouched; the
  calculator is a PowerShell-rendered self-contained HTML artifact exactly like DB-M26.
- **DB-M26 is preserved and remains the broader read-only dashboard.** DB-M27 is a
  focused calculator and does not duplicate the dashboard's full surface.

---

## 3. Reuse map (READ-ONLY consumption)

| Milestone | Consumed | Used for | Read-only |
|---|---|---|---|
| DB-M14 | `New-AiModel`, `Get-AiModels`, `Find-AiModelByProvider/ByUnderlyingModel` | provider/model/route selectors, UnderlyingModelId + GatewayProviderId identity, ReasoningLevelsSupported | yes |
| DB-M15 | `New-AiPricingRecord` (shape), `Get-AiPricingRecordStatus`, `Get-AiPriceAt`, `PricingCatalogue` | pricing-version display, CURRENT/NEEDS_REVIEW/EXPIRED/MANUAL_OVERRIDE, lookup state | yes |
| DB-M16 | `Import-AiCostConfiguration`, `New-AiCostCalculationInput`, `Calculate-AiAttemptCost`, `ConvertTo-AiTokenCost` | ALL token->cost estimation (input/output/cached/cache-write, reasoning billing, currency conversion, ESTIMATED vs ACTUAL, missing-pricing status) | yes |
| DB-M17 | `AiAttemptRecord` v1 (via M24/M25 chain) | historical actual-cost + quality/metrics inputs | yes |
| DB-M20 | `Get-AiEscalationCost` (next-step), `Get-DbM20ChainCumulative` (recorded chains) | escalation-step estimates; predicted path is a read-only M16 iteration | yes |
| DB-M21 | `New-BudgetPolicy`, `Test-AiBudget` -> BudgetEvaluation v1 | task/daily/monthly budget context, estimated % consumed, decision; never grants/overrides | yes |
| DB-M22 | provider-health vocabulary | informational "health unknown/no mutation" footnote | yes |
| DB-M23 | `Get-DbM23PriceStatuses`, `Get-ProviderRoutePriceStatus` (AdapterExecutionGate), local/OpenRouter identity fields | LOCAL != FREE (LOCAL_COST_UNKNOWN never fabricated $0), PRICE_UNKNOWN for remote, provider-vs-underlying distinction | yes |
| DB-M24 | `Get-AiModelPerformance` -> ModelPerformanceSummary v1, `Get-AiConfidenceLevel` | observed success rate, first-attempt success, confidence level, sample size | yes |
| DB-M25 | `Get-DbM25QualityAdjustedCost` -> QualityAdjustedCostResult v1 | verified-success rate, observed/expected cost per verified success, expected-cost basis, quality-adjusted view | yes |
| DB-M26 | DashboardContracts/DashboardRender pattern, ReadOnlyGuard, secret-leak guard, Export pattern | the calculator's Contracts/Render/Test shape; the dashboard itself is untouched | yes |

Dot-source chain (all READ-ONLY): `AiRoutingCostFoundation.ps1` (brings M14+M15+M16),
`providers\common\AdapterExecutionGate.ps1` (M23 price-status table), `budget\BudgetPolicy.ps1`
+ `budget\BudgetEngine.ps1` (M21), `quality-cost\AiQualityCostContracts.ps1` +
`quality-cost\QualityCost.ps1` (M25 -> M24/17/23/14), `escalation\EscalationContracts.ps1` (M20),
`provider-health\ProviderHealthContracts.ps1` (M22 vocab). The calculator never dot-sources any
Lane C `src/DevBridge.*` file.

---

## 4. Architecture

```
scripts/ai-routing/calculator/
  CalculatorContracts.ps1   contracts: CalculatorRequest v1, CalculatorView v1, vocabularies,
                            New-DbM27ReadOnlyGuard, Test-DbM27SecretLeak, schema versions, selector
                            builders. Dot-sources the READ-ONLY reuse chain above.
  CalculatorEngine.ps1      view-model builder: Invoke-DbM27Calculator -Request -> CalculatorView v1.
                            Pure/deterministic (NowUtc injected). Computes the DB-M16 estimate,
                            price-status/version, quality panel, escalation chain, budget context.
                            Never writes. Never executes.
  CalculatorRender.ps1      ConvertTo-DbM27Html -View -> self-contained interactive HTML (inline CSS/JS,
                            embedded catalogue JSON, no network). Export-DbM27CalculatorHtml is the ONLY
                            write the library performs.
  Test-DbM27Calculator.ps1  45-scenario matrix + child-suite regressions + frozen-file/workbook/UI SHA
                            + no-execution/no-mutation greps + build check.
```

### CalculatorRequest v1 (operator inputs, validated)

| Field | Notes |
|---|---|
| `ProviderId` | required; resolved against DB-M14 catalogue |
| `RouteType` | `DIRECT` \| `GATEWAY` \| `LOCAL`; validated against provider record `ProviderType` |
| `ModelId` | required; must exist for that provider/route |
| `UnderlyingModelId` | gateway routes: the actual selected model; preserved and displayed. Direct: == ModelId. Local: == ModelId |
| `PricingRecordId` | optional override; null -> effective record via `Get-AiPriceAt` |
| `ReasoningLevel` | optional; validated against `ReasoningLevelsSupported` when present |
| `InputTokens` / `OutputTokens` / `CachedInputTokens` / `CacheWriteTokens` | non-negative integers |
| `AttemptCount` | 1..N |
| `ExpectedCorrectionAttempts` | 0..N (included in the multi-attempt total) |
| `EscalationPath` | optional ordered `{Step; ProviderId; ModelId; AttemptCount; PricingRecordId}` list — cost-simulation only |
| `CurrencyTarget` | `USD` \| `INR` |
| `NowUtc` | deterministic injection for tests |

### CalculatorView v1 (operator outputs)

| Block | Contents |
|---|---|
| Request echo | Provider, RouteType, Model, UnderlyingModelId, GatewayProviderId, ReasoningLevel, tokens, attempts, currency |
| Scenario | model found, reasoning levels supported, LocalOrRemote |
| Pricing | PricingRecordId, PricingRecordStatus (CURRENT/NEEDS_REVIEW/EXPIRED/MANUAL_OVERRIDE), EffectiveFromUtc/EffectiveToUtc, PriceLookupState, PriceStatus (CONFIGURED/FREE/LOCAL_COST_UNKNOWN/PRICE_UNKNOWN), OperationalCostUnknown, PricingCurrency |
| Estimate | CalculationStatus, InputCost, OutputCost, CachedInputCost, CacheWrite5mCost, CacheWrite1hCost, Subtotal (provider currency), ConvertedTotal (target currency), Currency, PerAttemptCost, TotalMultiAttemptCost, EstimatedOrActual='ESTIMATED', UsageSource, messages |
| Actual-vs-estimated | `EstimatedCost` = computed value; `ActualCost` = null (nothing executed); distinct labels |
| Quality (optional) | SampleCount, VerifiedSuccessRate, FirstAttemptSuccessRate, ObservedCostPerVerifiedSuccess, ExpectedCostPerVerifiedSuccess, ExpectedCostBasis, AverageAttemptsPerVerifiedSuccess, ConfidenceLevel, LocalCostStatus; low-confidence explicitly labelled, never presented as statistically reliable |
| Escalation (optional) | ordered steps `{Step; ProviderId; ModelId; PerAttemptCost; StepTotal; CumulativeCost}`, grand total; `SimulationOnly=true`, `RoutingPolicyUnmodified=true` |
| Budget (informational) | ApplicableLimits `{Scope; Limit; CurrentSpend; ProjectedSpend; EstimatedPercentConsumed; Decision; ReasonCodes}`, warning thresholds, budget decision, `OverrideAllowed=false`, `InformationalOnly=true` |
| Guard | AutoExecutionEnabled=false, ProviderModelExecuted=false, PaidApiCalls=0, NetworkCalls=0, BudgetPolicyUnmodified=true, RoutingPolicyUnmodified=true, PricingUnmodified=true, ProviderHealthUnmodified=true |

### Interactive HTML behaviour

- Self-contained file (inline CSS/JS), no network, no writes except the explicit export.
- Form controls: Provider select, Route select (per provider), Model select (per provider+route),
  Underlying model (shown/preserved for gateway), Pricing version select (effective + all catalogue
  records for the pair, with status), Reasoning level select, token inputs, attempts, correction
  attempts, currency toggle.
- Results panel: ESTIMATED breakdown (input/output/cached/cache-write), per-attempt, multi-attempt,
  currency, pricing record + status + effective window, ESTIMATED-vs-ACTUAL badge, LOCAL semantics
  note, budget bar, quality panel (confidence badge + sample size), escalation table.
- The page embeds the DB-M16-computed authoritative view (JSON) for the reference scenario plus the
  DB-M15 catalogue + DB-M16 exchange rates as JSON. In-browser changes recompute a labelled
  `ESTIMATED PREVIEW` using the documented per-million arithmetic; the authoritative engine result
  remains stamped. No pricing data is invented.

---

## 5. Non-mutation / no-execution proofs (carried in the test suite)

- ReadOnlyGuard: `AutoExecutionEnabled=$false`, `HasWriteActions=$false`, `PolicyVersion='0.0.0'`,
  `ProviderModelExecuted=$false`, `PaidApiCalls=0`, `NetworkCalls=0`.
- Forbidden-token grep over the calculator files: `Invoke-WebRequest`, `Invoke-RestMethod`,
  `Start-Process`, `Invoke-Expression`, `System.Net.WebClient`, `HttpClient`, `Send-`, any
  provider-execution call.
- Frozen-file SHA-256 byte-identical before/after the run (M14..M26 + DB-M18.1 files).
- Canonical Nexus workbook SHA-256 byte-identical.
- Lane C `src/DevBridge.UI` files byte-identical.
- Git state unmodified by the run (no commits/PRs from DB-M27).

---

## 6. 45-case test matrix

| # | Scenario | Assertion |
|---|---|---|
| 1 | UI opens | `ConvertTo-DbM27Html` returns non-empty self-contained HTML with title + form + read-only footer |
| 2 | Provider selection | request resolves provider; catalogue selector lists providers |
| 3 | Route DIRECT | route accepted, per-attempt estimate present |
| 4 | Route GATEWAY | gateway route accepted, underlying displayed |
| 5 | Route LOCAL | local route accepted, price status honoured |
| 6 | Model selection | model validated against provider+route |
| 7 | Underlying-model display | gateway preserves UnderlyingModelId + GatewayProviderId separately |
| 8 | Pricing-version display | PricingRecordId + status + effective window shown |
| 9 | Input-token calc | InputCost = tokens/1M * input price (via DB-M16) |
| 10 | Output-token calc | OutputCost matches |
| 11 | Cached-input calc | CachedInputCost at cached rate |
| 12 | Cache-write calc | CacheWrite5mCost / CacheWrite1hCost where supported |
| 13 | Total cost | Subtotal + ConvertedTotal correct (USD) |
| 14 | Multi-attempt | TotalMultiAttemptCost = (AttemptCount + ExpectedCorrectionAttempts) x per-attempt |
| 15 | USD | currency target USD |
| 16 | INR | currency target INR, converted at the effective fx rate |
| 17 | Actual vs estimated | EstimatedOrActual='ESTIMATED', ActualCost=null, distinct labels |
| 18 | Missing pricing | CalculationStatus=PRICE_NOT_FOUND; explicit state, no invented number |
| 19 | Unknown local cost | LOCAL_COST_UNKNOWN displayed; no fabricated $0 |
| 20 | LOCAL never FREE | no-record local never yields FREE; provider-level 0 is not a real zero |
| 21 | OpenRouter gateway identity | provider (openrouter) != underlying; not collapsed |
| 22 | Underlying model preserved | UnderlyingModelId round-trips for gateway |
| 23 | Reasoning-level selection | validated against ReasoningLevelsSupported; billed per config (INCLUDED_IN_OUTPUT) |
| 24 | Quality metric display | VerifiedSuccessRate + cost-per-verified-success from M25 present |
| 25 | Low-confidence display | INSUFFICIENT/LOW confidence badge + sample size; never over-claimed |
| 26 | Expected verified-success cost | ExpectedCostPerVerifiedSuccess from M25 (OBSERVED_CHAINS / COLD_START_SIMPLE basis) |
| 27 | Escalation-chain estimate | per-step M16 estimate along operator path, read-only |
| 28 | Cumulative escalation cost | running cumulative per step + grand total |
| 29 | Budget informational | limits + estimated % consumed + decision shown |
| 30 | Budget override impossible | no budget-write token; `Test-AiBudgetOverride` never granted by DB-M27 |
| 31 | Routing modification impossible | no routing-policy-write token; guard true |
| 32 | Pricing modification impossible | no pricing-write token |
| 33 | Provider-health modification impossible | no health-write token |
| 34 | Model execution impossible | no execution token; ProviderModelExecuted=false |
| 35 | Paid calls = 0 | PaidApiCalls=0 + forbidden-network grep |
| 36 | Network calls = 0 | NetworkCalls=0 + no network verbs |
| 37 | DB-M16 regression | child suite green |
| 38 | DB-M21 regression | child suite green |
| 39 | DB-M23 regression | child suite green |
| 40 | DB-M24 regression | child suite green |
| 41 | DB-M25 regression | child suite green |
| 42 | DB-M26 regression | child suite green |
| 43 | DB-M18.1 preserved | child suite 63/64 (R45 excluded, reported separately) |
| 44 | UI regression | Lane C WPF UI files byte-identical |
| 45 | Build 0 errors | `dotnet build src\DevBridge.slnx` exit 0, 0 error CS tokens |

---

## 7. Data flow

```
NowUtc + CalculatorRequest
  -> CalculatorContracts selectors (M14 catalogue, M15 pricing records)
  -> CalculatorEngine:
       scenario identity (M14)  + price status (M23) + pricing version (M15)
       -> New-AiCostCalculationInput -> Calculate-AiAttemptCost (M16)  [authoritative estimate]
       -> quality panel (M25 via M24)  -> escalation chain (M16 per step, M20 read-only)
       -> budget context (M21 Test-AiBudget)
       -> CalculatorView v1 (guard stamped)
  -> ConvertTo-DbM27Html  ->  self-contained interactive HTML (embedded catalogue JSON, JS preview,
                              authoritative reference result stamped)
  -> Export-DbM27CalculatorHtml  (the only write; operator-requested artifact db-m27-calculator.html)
```

---

## 8. Outputs

| Artifact | Status |
|---|---|
| `scripts/ai-routing/calculator/CalculatorContracts.ps1` | PASS |
| `scripts/ai-routing/calculator/CalculatorEngine.ps1` | PASS |
| `scripts/ai-routing/calculator/CalculatorRender.ps1` | PASS |
| `scripts/ai-routing/calculator/Test-DbM27Calculator.ps1` | PASS |
| `design/DB-M27_AI_COST_CALCULATOR_UI.md` (this file) | PASS |
| `state/db-m27-result.json` | PASS |
| `tasks/DB-M27_IMPLEMENTATION_REPORT.md` | PASS |
| Interactive artifact `db-m27-calculator.html` (operator-requested export) | PASS |

Ready for DB-M28: **YES**. **Stop after DB-M27.**
