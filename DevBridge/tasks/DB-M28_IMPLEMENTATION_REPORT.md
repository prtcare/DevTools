# DB-M28 -- MODEL CONFIGURATION UI: Implementation Report

Date: 2026-09-01 (local) / 2026-08-31 18:49 UTC  |  Lane B  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing built here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency. Do NOT design DB-M28 for Nexus migration.

---

## 1. What this milestone delivered

An operator-facing **MODEL CONFIGURATION UI** for the existing DevBridge AI
subsystem. The UI lets the operator **INSPECT** which providers / routes /
models and which supported reasoning + capability options DevBridge may
consider, and **CONFIGURE** operator policy (provider/model enablement and
configuration status). It never executes a provider/model, never makes a paid
API call, and never makes a network call. **AUTO_EXECUTION_ENABLED = FALSE.**

DB-M28 **reuses (does NOT rebuild)** the DB-M14..M27 chain READ-ONLY:

- **DB-M14** model/route catalogue — provider/route/model identity, gateway +
  underlying-model separation, local routes.
- **DB-M15** pricing catalogue — the pricing **reference** (read-only authority).
- **DB-M19** routing eligibility — the **hard capability gate** (`Test-AiModelCapabilityFit`)
  whose rejection vocabulary drives the routing-eligibility summary. DB-M28 can
  enable/disable a model but **never manually overrides** an M19 hard check.
- **DB-M21** budget policy — display-only context, never a budget-override UI.
- **DB-M22** provider health — **read-only**; no manual HEALTHY marking, no
  circuit reset, no AUTH_ERROR clear, no failover.
- **DB-M23** provider route price status — price status table
  (`LOCAL_COST_UNKNOWN` / `PRICE_UNKNOWN` / `CONFIGURED` / `FREE`).
- **DB-M26** analytics — the model-config UI is configuration, not a duplicate
  dashboard.
- **DB-M27** cost calculator — the **VIEW COST ESTIMATE** card delegates to
  `Invoke-DbM27Calculator`; no cost formula is duplicated.

### 1.1 Contracts (ModelConfigContracts.ps1)

- Schema versions for ConfigView / ReadOnlyGuard / ConfigChange / AuditRecord /
  EligibilityRow (all v1).
- `Get-DbM28TargetTypes` = `PROVIDER | MODEL`; `Get-DbM28ChangeCategories` =
  `PROVIDER | MODEL | CONFIG_STATUS`.
- Editable fields are the **only** writable surface: provider `Enabled /
  Configured / Notes`, model `Enabled / Notes`. Pricing, currency, cost,
  confidence bands, `devbridge.json` are immutable targets.
- `Get-DbM28SecretStatuses` = `CONFIGURED | NOT_CONFIGURED |
  INVALID_CONFIGURATION | NO_SECRET_REQUIRED`.
- `Get-DbM28EligibilityStates` = `ELIGIBLE | DISABLED | CAPABILITY_MISMATCH |
  PRICING_UNKNOWN | PROVIDER_UNHEALTHY | CONFIGURATION_INCOMPLETE` (the brief's
  "or equivalent existing states" — these are the DB-M19 vocabulary mapped to
  the DB-M28 summary).
- `New-DbM28ReadOnlyGuard` — deterministic no-execution guard:
  `AutoExecutionEnabled = FALSE`, `PaidApiCalls = 0`, `NetworkCalls = 0`, all
  Unmodified flags = true, `SecretValuesDisplayed/Logged = FALSE`, writable
  config scope restricted to `config\providers.json` + `config\models.json`.
- `Test-DbM28SecretLeak` — the shared secret-material scan (api-key /
  authorization / `sk-` / password / secret patterns) applied to **every** HTML
  output and audit record.
- `New-DbM28ConfigChangeRequest` / `Test-DbM28ConfigChangeRequest` /
  `New-DbM28ConfigChangeRecord` — the validated audited change pipeline.
- `Out-DbM28Markers` — backend contract: always exits 0, outcomes only via
  stdout markers (`DB28_OUTCOME` / `DB28_RESULT_PASS` / `DB28_WORKBOOK_MODIFIED:
  False` / `DB28_NEXUS_SOURCE_MODIFIED: False` / `DB28_GIT_MODIFIED: False`).

### 1.2 Engine (ModelConfigEngine.ps1)

`New-DbM28ModelConfigurationView` builds the full 10-section view:

1. **PROVIDERS** — each provider: enabled/disabled, provider type
   (DIRECT/GATEWAY/LOCAL), configuration status (Configured yes/no),
   secret status (`CONFIGURED`/`NOT_CONFIGURED`/`INVALID_CONFIGURATION`/
   `NO_SECRET_REQUIRED`). **Secret values are never displayed**; the env-var
   NAME (SecretReference) is shown, and the value comes only from the
   deterministic `-SecretLookup` presence check.
2. **MODELS** — provider, model id, display name, version, enabled/disabled,
   capability tri-state (`YES`/`NO`/`UNKNOWN` — never fabricated),
   route (DIRECT/GATEWAY/LOCAL), pricing availability, performance-evidence
   availability, health-related provider status.
3. **ROUTES** — direct / gateway / local route display with
   `GatewayProviderId` + `UnderlyingModelId` preserved separately.
4. **REASONING / CAPABILITY OPTIONS** — only the contract levels
   `NONE|LOW|MEDIUM|HIGH|MAX`; a model that asserts no reasoning surface shows
   `NOT_ASSERTED until DB-M15/M19`, never invented levels.
5. **LOCAL MODELS** — `LOCAL` route classification; **LOCAL != FREE**,
   `LOCAL_COST_UNKNOWN` never shown as a fabricated zero.
6. **OPENROUTER / GATEWAY MODELS** — gateway provider kept separate from the
   underlying model; identities never collapsed.
7. **PRICING REFERENCE** — DB-M15 records read-only (10 real records).
8. **ROUTING ELIGIBILITY SUMMARY** — per-model state from
   `Test-AiModelCapabilityFit` (two passes: null requirement = availability;
   coding+tool-use requirement = capability gate) mapped to the DB-M28
   vocabulary, plus `ConfigIncomplete` / `ToggleFixable` / `HardCapabilityGate`.
9. **HEALTH STATUS (READ ONLY)** — DB-M22-shaped rows from an OPTIONAL
   effective-health snapshot; without a snapshot: `NO_EVIDENCE`, all `UNKNOWN`.
   The engine **never** marks healthy, resets a circuit, clears an AUTH_ERROR,
   or fails over.
10. **SECURITY / SECRET STATUS** — per-provider secret status; values never
    rendered; `ReadOnlyGuard` footer.

The engine's persistence adapter (`Apply-DbM28ConfigChange`) is a 6-step
validated atomic audited pipeline: validate the change request → validate the
proposed document by loading it with the **real** `Import-AiCostConfiguration`
on a temp tree → apply only the operator's field (schema/version preserved) →
atomic temp-file + `Move-Item` → read-back deep-equality → audit record to
`state/db-m28-config-changes.json`. Only `config\providers.json` +
`config\models.json` are writable; pricing/currency/cost/confidence/
`devbridge.json` are never rewritten. The `SecretReference` field is always in
the audit `RedactedFields` list.

The **VIEW COST ESTIMATE** card delegates to `Invoke-DbM27Calculator`
(reference scenario: deepseek / deepseek-v4-flash / DIRECT / MEDIUM,
12000/8000/100000 tokens); budget context is informational only. **No cost
formula is duplicated.**

### 1.3 Renderer (ModelConfigRender.ps1)

Self-contained HTML (inline CSS/JS, embedded JSON) with 10 tab panels + a
**VIEW COST ESTIMATE · Configuration Audit** panel and the read-only guard
footer. Marker strings carried in the output and asserted by the suite:

- `AUTO AI EXECUTION DISABLED · provider/model executed: NO · paid calls 0 ·
  network calls 0.`
- `Hard capability override: NO.`
- `Secret values displayed: NO.` · `Secret values logged: NO.`
- `LOCAL is NOT FREE` on the local-models panel.
- Every HTML emission is passed through `Test-DbM28SecretLeak` before return;
  the only library disk write is `Export-DbM28ModelConfigurationHtml`'s
  `WriteAllText` of the operator-requested artifact.

---

## 2. Test results

`scripts/ai-routing/model-config/Test-DbM28ModelConfig.ps1`

- **54 scenarios (S1-S54) + S55 frozen-file re-verification** — 55/55 green, exit 0.
- **Assertions:** 359 passed, 0 failed.

```
DB-M28 TEST SUMMARY: 359 passed, 0 failed
DB-M28 SCENARIOS: 55 scenarios
DB-M28 REGRESSION DBM26: 381 passed, 1 failed, exit 1
DB-M28 REGRESSION DBM181: 63 passed, 1 failed, exit 1
DB-M28 REGRESSION DBM19: 136 passed, 0 failed, exit 0
DB-M28 REGRESSION DBM22: 68 passed, 0 failed, exit 0
DB-M28 REGRESSION DBM23: 203 passed, 0 failed, exit 0
```

(Full run log: `state/db-m28-test-run.log`.)

### 2.1 Scenario walkthrough (S1-S54)

| # | Scenario | What it proves | Result |
|---|----------|----------------|--------|
| S1 | UI opens | renderer emits a self-contained HTML page (doctype, title, no-execution badge, guard footer, cost-estimate card); export writes the artifact | PASS |
| S2 | Provider list renders | all 7 real providers + fixtures, identity + config status | PASS |
| S3 | Model list renders | 4 real models + fixtures, provider display-name join | PASS |
| S4 | Provider enabled/disabled | real all-disabled; fixture enabled+configured; secret CONFIGURED | PASS |
| S5 | Model enabled/disabled | real all-disabled; fixture enabled | PASS |
| S6 | Direct route | deepseek-v4-flash / claude-sonnet-5 route DIRECT | PASS |
| S7 | Gateway route | openrouter route GATEWAY, gateway provider id, underlying model | PASS |
| S8 | Local route | local-7b route LOCAL, section 5 listing | PASS |
| S9 | Reasoning levels from contracts | exactly `NONE,LOW,MEDIUM,HIGH,MAX` | PASS |
| S10 | Unsupported reasoning not shown | no invented levels; `NOT_ASSERTED` label | PASS |
| S11 | Capability display | tri-state, unasserted = UNKNOWN never fabricated | PASS |
| S12 | Tool capability | SupportsToolUse shown from contract | PASS |
| S13 | Structured-output capability | shown when asserted; UNKNOWN when null | PASS |
| S14 | Context capability | numbers when asserted; null/unasserted otherwise | PASS |
| S15 | Pricing reference display | DB-M15 read-only authority, 10 records rendered | PASS |
| S16 | Pricing unknown state | PRICE_UNKNOWN explicit; CONFIGURED for deepseek | PASS |
| S17 | Provider health read-only | snapshot consumed as OPTIONAL input; read-only | PASS |
| S18 | Health cannot be fabricated | no snapshot → NO_EVIDENCE / UNKNOWN; no health-write token in library | PASS |
| S19 | Local provider display | LOCAL type; `LOCAL is NOT FREE` marker | PASS |
| S20 | LOCAL_COST_UNKNOWN preserved | unknown local cost state; never a fabricated zero | PASS |
| S21 | Local never FREE | LOCAL_COST_UNKNOWN ≠ FREE; invariant stated in HTML | PASS |
| S22 | OpenRouter gateway identity | gateway provider ≠ underlying model, never collapsed | PASS |
| S23 | Underlying model preserved | end-to-end through model rows and section 6 | PASS |
| S24 | Routing eligibility summary | DB-M19 source; all 6 vocabulary states present | PASS |
| S25 | Disabled excluded from eligibility | MODEL_DISABLED → DISABLED, not toggle-fixable | PASS |
| S26 | Capability mismatch not toggle-overridable | hard gate CAPABILITY_CODING_MISSING/TOOL_USE; `Hard capability override: NO` | PASS |
| S27 | Configuration incomplete displayed | unconfigured provider / absent secret → CONFIGURATION_INCOMPLETE | PASS |
| S28 | Secrets never rendered | HTML passes `Test-DbM28SecretLeak`; env-var NAME shown, value never | PASS |
| S29 | Secrets never logged | audit JSON passes leak guard; no secret write path in library | PASS |
| S30 | Configured/not-configured secret status | CONFIGURED / NOT_CONFIGURED / NO_SECRET_REQUIRED | PASS |
| S31 | Config validation before save | bad target/field/category/value/missing target rejected; valid passes | PASS |
| S32 | Config persistence | validated atomic adapter on temp tree; live config byte-identical | PASS |
| S33 | Config read-back | persisted value round-trips the real loader | PASS |
| S34 | Config schema/version preserved | only the operator's field changes; unrelated providers untouched | PASS |
| S35 | Config-change audit | timestamp, target, field, old/new non-secret state, operator action | PASS |
| S36 | Secret audit redaction | RedactedFields lists SecretReference; audit JSON has no secret values | PASS |
| S37 | DB-M27 calculator integration | VIEW COST ESTIMATE delegates to DB-M27/DB-M16 authority | PASS |
| S38 | No duplicate cost calculation | library calls `Invoke-DbM27Calculator`; never re-implements formula | PASS |
| S39 | DB-M26 preserved | child suite at its external S41 signature (381 passed / 1 failed, drift) | PASS |
| S40 | DB-M18.1 preserved | child suite at its external R45 signature; R50 proven green standalone | PASS |
| S41 | DB-M19 preserved | router child suite green, 0 failures, exit 0 | PASS |
| S42 | DB-M22 preserved | provider-health child suite green, exit 0 | PASS |
| S43 | DB-M23 preserved | providers child suite green, exit 0 | PASS |
| S44 | No budget override | guard BudgetPolicyUnmodified; informational-only; no `Test-AiBudgetOverride` | PASS |
| S45 | No router hard-rule override | no `New-RoutingDecision`/`Get-AiEscalationDecision`; hard gate engaged | PASS |
| S46 | No provider-health mutation | read-only; no `Set-ProviderHealth`/`Update-ProviderCircuitState` | PASS |
| S47 | No pricing mutation | DB-M15 authority; no `Add-AiPricingRecord`/`Add-AiPriceVersion` | PASS |
| S48 | No AI execution | AUTO_EXECUTION_ENABLED=FALSE; no `Invoke-Provider`/`Send-ProviderRequest` | PASS |
| S49 | Paid API calls = 0 | guard 0; no web/rest/http tokens in library | PASS |
| S50 | Network calls = 0 | guard 0; no WebClient/process-spawn/dynamic-invoke tokens | PASS |
| S51 | Canonical workbook unchanged | Nexus workbook SHA-256 byte-identical (6D42C3BF…), live state | PASS |
| S52 | Nexus source unchanged | guard NexusSourceUnmodified; no workbook path/baseline tokens in library | PASS |
| S53 | UI regression | Lane C UI files byte-identical | PASS |
| S54 | Solution build | dotnet build 0 errors | PASS |
| S55 | Frozen files re-verification | all DB-M14..M27 files, DB-M28 library, live config SHA-256 unchanged | PASS |

### 2.2 Regressions

| Suite | Result |
|-------|--------|
| DB-M16 | 167/167 PASS (via DB-M26 child regression, 0 failures) |
| DB-M19 | 136/136 PASS, exit 0 |
| DB-M21 | 77/77 PASS (via DB-M26 child regression, 0 failures) |
| DB-M22 | 68/68 PASS, exit 0 |
| DB-M23 | 203/203 PASS, exit 0 |
| DB-M24 | 128/128 PASS (via DB-M26 child regression, 0 failures) |
| DB-M25 | 337/337 PASS (via DB-M26 child regression, 0 failures) |
| DB-M26 | 381/382 — **single external failure S41** (recorded workbook authority F520060C vs live 6D42C3BF after DB-M12.4 closure), reported separately |
| DB-M18.1 | 63/64 — **external R45** (DB-M18 classification fixture drift); R50 (DB-M12.4 child) proven green standalone 54/54 |
| DB-M27 | 266/0 PASS (child) |

### 2.3 Proofs

- **Hard capability override: NO** — DB-M19 rejection reasons are never
  suppressed; a model that fails a hard check (CAPABILITY_CODING_MISSING /
  CAPABILITY_TOOL_USE_MISSING) stays CAPABILITY_MISMATCH even when enabled, and
  the UI states `Hard capability override: NO`.
- **Secret values displayed: NO** — HTML passes `Test-DbM28SecretLeak`; only
  the env-var NAME (SecretReference) is ever shown.
- **Secret values logged: NO** — audit records redact `SecretReference`;
  audit JSON passes `Test-DbM28SecretLeak`.
- **Configuration persistence PASS** — validated-before-save, atomic
  (temp+Move-Item), read-back verified, schema/version preserved, audit
  written, only the operator's field changes, live config byte-identical.
- **AUTO AI execution NO** — `AutoExecutionEnabled=FALSE`; provider/model
  executed NO; paid calls 0; network calls 0 (guard + forbidden-token scan of
  the 3 library files).
- **Budget override NO · Pricing modification NO · Provider-health
  modification NO** — no write token in the library; DB-M21/15/22 untouched.
- **Canonical workbook modified NO · Nexus source modified NO** — SHA-256
  byte-identical; no workbook path or baseline token in the library.

---

## 3. Files created

- `design/DB-M28_MODEL_CONFIGURATION_UI.md`
- `scripts/ai-routing/model-config/ModelConfigContracts.ps1`
- `scripts/ai-routing/model-config/ModelConfigEngine.ps1`
- `scripts/ai-routing/model-config/ModelConfigRender.ps1`
- `scripts/ai-routing/model-config/Test-DbM28ModelConfig.ps1`
- `state/db-m28-result.json`
- `state/db-m28-test-run.log`
- `tasks/DB-M28_IMPLEMENTATION_REPORT.md` (this file)

## 4. Files modified

None outside the DB-M28-owned scope. The DB-M14..M27 chain, Lane C UI,
`src/`, the canonical Nexus workbook, and live config are byte-identical.

---

## 5. Boundary / overlap

- **DB-M18.1**: DependencyLineage.ps1 + its test suite frozen and unmodified;
  R45 remains the pre-existing external drift, reported separately.
- **DB-M19**: consumed READ-ONLY as the hard capability gate. DB-M28 may
  enable/disable a model; it never overrides a hard check.
- **DB-M15 / DB-M21 / DB-M22 / DB-M26 / DB-M27**: pricing authority, budget,
  health, analytics, and cost authority respectively — all read-only or
  informational; no duplication.
- **Lane A / DB-GH01**: DB-M28 wrote ONLY under `scripts/ai-routing/model-config/`,
  `design/`, `state/`, `tasks/`. **NO PARALLEL_SCOPE_CONFLICT.**
- **Nexus**: DB-M28 is DevBridge-only, temporary, and NOT designed for Nexus
  migration.

**Ready for DB-M29: YES.** **Stop after DB-M28.**
