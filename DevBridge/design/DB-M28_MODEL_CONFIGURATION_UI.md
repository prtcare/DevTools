# DB-M28 -- Model Configuration UI: Design

Date (UTC): 2026-08-31 | Lane B | Status: DESIGN

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing built here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency. Do NOT design DB-M28 for Nexus migration.

---

## 1. Objective

A safe operator-facing **Model Configuration UI** that lets the operator
**inspect** the existing DevBridge AI subsystem and **configure operator
policy** -- which providers, routes, models and supported
reasoning/capability options DevBridge may consider in later
assisted/automatic development.

DB-M28 **configures** DevBridge AI policy/configuration (provider/model
enablement and configuration status). It does **not** execute any AI model,
does not make paid API calls, does not make network calls, and does not mutate
governed state (workbook / roadmap / budget / pricing / provider health /
routing policy).

## 2. Discovery -- what already exists (REUSE, never duplicate)

Verified by reading the DB-M14..M27 libraries and configs (all absolute paths
under `C:\Personal\DevTools\DevBridge`).

### 2.1 Configuration storage (the existing DevBridge config mechanism)

- `config\providers.json` -- schemaVersion 1, `providers[]`; each record has
  `Enabled`, `Configured`, `ProviderType`, `BaseEndpoint`, `GatewayType`,
  `Supports*` capability flags, `ConfigurationKey`, `SecretReference`
  (env-var NAME only). File header: records are editable configuration.
- `config\models.json` -- schemaVersion 1, `models[]`; each record has
  `Enabled`, `ModelId`, `ProviderId`, `ProviderModelId`, `UnderlyingModelId`,
  `GatewayProviderId`, `LocalOrRemote`, `SupportsCoding/Reasoning/Vision/
  ToolUse/StructuredOutput/PromptCaching/Batch/Streaming`, `ContextWindow`,
  `MaxOutputTokens`, `ReasoningLevelsSupported`, `RelativeSpeed`,
  `ReliabilityClass`, `EndpointOverride`, `Notes`. File header: records are
  editable configuration.
- `config\ai-routing.json` -- execution mode (`MANUAL` only), `roles`
  (DefaultCheapModel etc.), `routingDefaults` (inert until DB-M19).
- `config\pricing\pricing-catalogue.json` (DB-M15), `config\currency\
  exchange-rates.json` + `config\cost\cost-calculator.json` (DB-M16),
  `config\performance\confidence-bands.json` (DB-M24). **Read-only for
  DB-M28.**
- Loader: `Import-AiRoutingConfiguration` (AiRoutingFoundation.ps1) and the
  DB-M16 chain `Import-AiCostConfiguration`. Validators:
  `Validate-AiRoutingFoundation`, `Test-AiProvider`, `Test-AiModel`,
  `Validate-AiProviderCatalogue`, `Validate-AiModelCatalogue`.

### 2.2 Secret system (reuse, never render values)

- Secrets are stored as env-var **NAMEs** (`SecretReference`,
  `ConfigurationKey`, `ApiKeyReference`), validated by
  `^[A-Z][A-Z0-9_]{2,}$` (never a value).
- Values live externally (`C:\Personal\UserSecrets\usersecrets.txt` -> env
  vars via `Load-Secrets.ps1`, outside DevBridge). The only production value
  read is `[Environment]::GetEnvironmentVariable` inside the DB-M23 adapter
  boundary (AdapterRequest.ps1), immediately redacted via
  `ConvertTo-DbM23RedactedHeaders`.
- Leak guard: `Test-AiRoutingSecretValueLeak` (DB-M14) + per-milestone
  wrappers (`Test-DbM23SecretLeak`, `Test-DbM26SecretLeak`,
  `Test-DbM27SecretLeak`).

### 2.3 Routing eligibility (DB-M19, READ-ONLY)

- `Test-AiModelCapabilityFit -Model -Provider -Requirement -Pricing
  -ProviderHealth -Policy -ProcessingTier -TimestampUtc` -> `@{ Fits;
  Eligible; RejectionReasons; FirstReason; ... }`.
- Rejection vocabulary `Get-DbM19RejectionReasons`:
  `MODEL_DISABLED, PROVIDER_DISABLED, PROVIDER_UNAVAILABLE,
  CAPABILITY_CODING_MISSING, CAPABILITY_VISION_MISSING,
  CAPABILITY_TOOL_USE_MISSING, STRUCTURED_OUTPUT_MISSING,
  REASONING_LEVEL_INSUFFICIENT, CONTEXT_TOO_SMALL, OUTPUT_LIMIT_TOO_SMALL,
  RELIABILITY_TOO_LOW, PROVIDER_DISALLOWED, MODEL_DISALLOWED,
  LOCALITY_CONFLICT, BUDGET_EXCEEDED, PRICE_UNAVAILABLE,
  PROCESSING_TIER_UNSUPPORTED`.
- **Hard constraints (NOT toggle-fixable)**: capability gates
  (CAPABILITY_*), context/output/reliability gates, and pricing-coverage gates
  (`PRICE_UNAVAILABLE`, `PROCESSING_TIER_UNSUPPORTED`) are hard. Only
  `MODEL_DISABLED` / `PROVIDER_DISABLED` / `PROVIDER_UNAVAILABLE`(health) are
  config/state-sensitive. **A capability-incompatible model cannot be made
  eligible by a UI toggle.**

### 2.4 Route/price status (DB-M23, READ-ONLY)

- `Get-ProviderRoutePriceStatus -Catalogue -ProviderId -ModelId
  -LocalOrRemote -TimestampUtc -HasConfiguredOperationalCostBasis` ->
  `@{ PriceStatus; ProviderTokenPrice; OperationalCostUnknown; LookupState;
  PricingRecordId }` with statuses `CONFIGURED | FREE | LOCAL_COST_UNKNOWN |
  PRICE_UNKNOWN`. **LOCAL with no record -> LOCAL_COST_UNKNOWN**
  (`ProviderTokenPrice=0` is a provider-level default only, never FREE).
- Route types `DIRECT | GATEWAY | LOCAL`; provider types
  `DIRECT | GATEWAY | LOCAL | OPENAI_COMPATIBLE | OLLAMA_COMPATIBLE`.
- OpenRouter identity preserved: `Get-OpenRouterRouteDecomposition` ->
  `ProviderModelId` = full route, `UnderlyingModelId` = model part after last
  `/` (variant stripped), `GatewayProviderId` = `openrouter`. `Register-
  OpenRouterRoute` persists via `New-AiModel`. `Resolve-DbM27BillingIdentity`
  bills the UNDERLYING model (never collapses identities).

### 2.5 Provider health (DB-M22, READ-ONLY)

- Health states: `AVAILABLE | RATE_LIMITED | DEGRADED | AUTH_ERROR |
  UNAVAILABLE | DISABLED | UNKNOWN` (no `HEALTHY` literal).
- Reader: `Get-EffectiveProviderHealth`; availability: `Test-ProviderRoute-
  Available`; circuit states `CLOSED | OPEN | HALF_OPEN`.
- **No health-mutation function exists.** `Test-ProviderHealthOverride` is
  decision-only and gated (`ConfigurationDisabled -> OVERRIDE_PROHIBITED`);
  `Update-ProviderCircuitState` is a pure next-state decision. DB-M28 must not
  invent health operations.

### 2.6 Budget (DB-M21, READ-ONLY)

- `Test-AiBudget` -> BudgetEvaluation v1: `Decision` in
  `ALLOW | ALLOW_WITH_WARNING | BLOCK_BUDGET_EXCEEDED | BLOCK_COST_UNKNOWN |
  REQUIRE_HUMAN_OVERRIDE | NO_APPLICABLE_BUDGET`; scopes
  `TASK | CHANGE | SESSION | DAILY | MONTHLY | TEAM`; limit rows carry
  `Scope, ScopeKey, Limit, CurrentActualSpend, CurrentEstimatedPendingSpend,
  ProjectedSpend, Decision, ReasonCodes`.
- **No budget-write function exists anywhere.** DB-M28 displays cost/budget
  implications only; it is never a budget-override UI.

### 2.7 UI shell

- All AI UI milestones render **self-contained HTML** (no shared shell; no
  `src\DevBridge.UI` modification). DB-M26 has an `AI ANALYTICS` tab that
  reads `state\db-mNN-result.json`. DB-M27 registered "COST CALCULATOR" under
  the same AI Analytics area by producing its own artifact + result file.
- Lane A may be editing shared shell concurrently (DB-M03.1). DB-M28 therefore
  uses an **isolated self-contained HTML page** and reports
  `INTEGRATION_PENDING_SHARED_UI` for any shared-shell integration.

### 2.8 Persistence finding (the one genuinely open decision)

- **No config-JSON writer exists.** `config\*.json` are loaded-and-validated;
  the M25/M26/M27 suites hash-assert them byte-identical **across their own
  runs** (scope proof). The files' own descriptions say they are **editable
  configuration**.
- DB-M28 is explicitly authorized to configure provider/model enablement and
  configuration status. DB-M28 therefore provides a **safe, validated,
  atomic, audited persistence adapter** for `config\providers.json` and
  `config\models.json` ONLY, following the existing `Move-Item -Force` atomic
  pattern (workbook) and `Write-DevBridgeJson` (array-preserving, UTF-8 no
  BOM). Pricing/currency/cost/confidence configs stay read-only.

## 3. Contracts (ModelConfigContracts.ps1)

### 3.1 ModelConfigView v1 (read-only presentation contract)

```
SchemaVersion=1
GeneratedAtUtc
Providers        : ProviderRow[]     (see 4.1)
Models           : ModelRow[]        (see 4.2)
Routes           : RouteRow[]        (see 4.3, DIRECT/GATEWAY/LOCAL)
ReasoningLevels  : string[]          (Get-AiRoutingReasoningLevels, existing vocabulary)
CapabilityList   : string[]          (existing capability flags)
LocalModels      : LocalRow[]        (see 4.5)
OpenRouterRoutes : GatewayRow[]      (see 4.6)
PricingReference : PricingRow[]      (see 4.7, DB-M15 status)
HealthStatus     : HealthRow[]       (see 4.9, read-only snapshot)
SecretStatus     : SecretRow[]       (see 4.10, CONFIGURED/NOT_CONFIGURED/INVALID_CONFIGURATION)
EligibilitySummary : EligibilityRow[] (see 4.8)
Persistence      : @{ Supported=$true; Targets=@('config\providers.json','config\models.json');
                      Mechanism='atomic-temp-move'; Validated=$true; ReadBack=$true; Audit=$true;
                      ImmutableTargets=@('config\pricing\...','config\currency\...','config\cost\...',
                      'config\performance\...','config\ai-routing.json','config\devbridge.json');
                      LiveConfigUnmodifiedByTestRun=$true }
AuditLog         : ConfigChangeRecord[]  (read from state\db-m28-config-changes.json, redacted)
CostEstimate     : CostEstimateRef | null (DB-M27 integration, read-only)
Guard            : ModelConfigReadOnlyGuard v1
```

### 3.2 ModelConfigReadOnlyGuard v1

```
SchemaVersion=1
AutoExecutionEnabled=$false
ProviderModelExecuted=$false
PaidApiCalls=0
NetworkCalls=0
BudgetPolicyUnmodified=$true
PricingUnmodified=$true
ProviderHealthUnmodified=$true
RoutingPolicyUnmodified=$true
CapabilityHardChecksUnmodified=$true      # DB-M19 hard gates never overridden
CanonicalWorkbookUnmodified=$true
NexusSourceUnmodified=$true
GitUnmodified=$true
SecretValuesDisplayed=$false
SecretValuesLogged=$false
ConfigWriteAuthorizedScope=@('providers.json','models.json')
ConfigWriteAtomic=$true
ConfigWriteValidated=$true
ConfigWriteReadBack=$true
```

### 3.3 ConfigChangeRecord v1 (audit)

```
SchemaVersion=1
ChangeId          (e.g. cfg-<epoch>)
TimestampUtc
Category          PROVIDER | MODEL | CONFIG_STATUS
TargetType        PROVIDER | MODEL
TargetId          (ProviderId / ModelId)
Field             (e.g. Enabled, Configured, Notes)
OldValue          (non-secret serialization)
NewValue          (non-secret serialization)
OperatorAction    (e.g. SET, TOGGLE_ENABLE, TOGGLE_DISABLE, SET_CONFIG_STATUS)
ConfigVersion     1
Applied           $true | $false
RedactedFields    string[]  (always includes SecretReference when the row is a provider)
```

### 3.4 ConfigChangeRequest v1 (operator intent)

```
SchemaVersion=1
ChangeId (optional, generated if absent)
TimestampUtc (injected)
Category / TargetType / TargetId / Field / NewValue (string/bool serialization)
OperatorAction
```

## 4. The ten required sections (data sources)

1. **PROVIDERS** -- rows from `config\providers.json` via `New-AiProvider`:
   `ProviderId, DisplayName, Enabled, Configured, ProviderType, GatewayType,
   RouteType (DIRECT|GATEWAY|LOCAL), Capabilities (Supports* flags), Secret
   Reference NAME (never value), Secret status`. Editable: Enabled,
   Configured.
2. **MODELS** -- rows from `config\models.json` via `New-AiModel`: provider,
   model id, display name, version, Enabled, `Supports*` capabilities,
   `ReasoningLevelsSupported`, `ContextWindow`, `MaxOutputTokens`,
   `LocalOrRemote`, route, pricing availability, performance-evidence
   availability (DB-M24/M25), provider-health note. Editable: Enabled.
   Unsupported capabilities shown as absent (never invented).
3. **ROUTES** -- per model: DIRECT / GATEWAY / LOCAL derived from provider
   `ProviderType` + model `GatewayProviderId` + `LocalOrRemote`. No invented
   routes.
4. **REASONING / CAPABILITY OPTIONS** -- `Get-AiRoutingReasoningLevels`
   (`NONE/LOW/MEDIUM/HIGH/MAX`) and the existing `Supports*` capability
   vocabulary only. Unsupported reasoning levels never shown.
5. **LOCAL MODELS** -- local providers (`ProviderType=LOCAL` / `LocalOrRemote
   =LOCAL`) with configuration type, endpoint (where safe), enabled/disabled,
   capabilities, and cost status via `Get-ProviderRoutePriceStatus`:
   `LOCAL_COST_UNKNOWN` preserved; **LOCAL != FREE**; no fabricated 0.
6. **OPENROUTER / GATEWAY MODELS** -- gateway provider (openrouter) and
   underlying model kept separate (`GatewayProviderId`, `UnderlyingModelId`,
   `ProviderModelId`). Identity never collapsed.
7. **PRICING REFERENCE** -- read-only DB-M15 records
   (`Get-AiPricingRecordStatus`: `CURRENT/NEEDS_REVIEW/EXPIRED/
   MANUAL_OVERRIDE`), record id, effective window, currency, price dimensions.
   No price editing.
8. **ROUTING ELIGIBILITY SUMMARY** -- per model route, the DB-M19
   `Test-AiModelCapabilityFit` result consumed READ-ONLY, displayed with the
   raw `RejectionReasons` plus a derived state (mapping in 4.8.1). Toggles
   never override hard capability gates.
9. **HEALTH STATUS -- READ ONLY** -- DB-M22 effective-health snapshot passed
   in (same pattern as DB-M26). HealthState, CircuitState, reason codes.
   No evidence -> `UNKNOWN` + "no health evidence recorded" note. No health
   mutation UI.
10. **SECURITY / SECRET STATUS** -- `CONFIGURED | NOT_CONFIGURED |
    INVALID_CONFIGURATION` per provider, derived from the env-var NAME's
    resolvability (using `[Environment]::GetEnvironmentVariable(NAME)` is
    absent in DB-M28; instead status is derived from
    `Configured` + `SecretReference` present + validated NAME pattern, and
    the UI can show a "check env var presence" read that never displays the
    value). Secret values never rendered, never logged.

### 4.8.1 Eligibility state mapping (documented, honest)

Raw DB-M19 first-rejection-reason -> display state (DB-M28 never invents a
state DB-M19 does not produce; the mapping is display-only):

| DB-M19 rejection reason | Display state |
|---|---|
| (no reasons; Fits=$true) | ELIGIBLE |
| MODEL_DISABLED / PROVIDER_DISABLED | DISABLED |
| PROVIDER_UNAVAILABLE (health) | PROVIDER_UNHEALTHY |
| CAPABILITY_CODING_MISSING / CAPABILITY_VISION_MISSING / CAPABILITY_TOOL_USE_MISSING / STRUCTURED_OUTPUT_MISSING / REASONING_LEVEL_INSUFFICIENT / CONTEXT_TOO_SMALL / OUTPUT_LIMIT_TOO_SMALL / RELIABILITY_TOO_LOW / LOCALITY_CONFLICT / PROVIDER_DISALLOWED / MODEL_DISALLOWED | CAPABILITY_MISMATCH |
| PRICE_UNAVAILABLE / PROCESSING_TIER_UNSUPPORTED | PRICING_UNKNOWN |
| -- DB-M28 derived (config state) -- | CONFIGURATION_INCOMPLETE |

`CONFIGURATION_INCOMPLETE` is a DB-M28 **derived** state (from provider
`Configured=false`, or `SecretReference` missing for an auth-requiring
provider, or a local route with no endpoint) shown alongside the raw DB-M19
reasons; it is clearly labelled "configuration state (DB-M28), not a DB-M19
rejection".

## 5. Persistence design (safe, existing-mechanism, audited)

DB-M28 writes ONLY `config\providers.json` and `config\models.json`, and only
fields the operator changed (Enabled / Configured / Notes). Every write:

1. **Load live** -- read the current file (the source of truth).
2. **Validate before save** -- build the proposed catalogue with `New-AiProvider`
   / `New-AiModel` and run `Validate-AiProviderCatalogue` /
   `Validate-AiModelCatalogue` / `Validate-AiRoutingFoundation` (schema v1,
   env-var NAME pattern, provider references, duplicate ProviderModelId,
   secret-value leak). A failed validation aborts with errors; nothing is
   written.
3. **Surgical field change** -- only the operator's target field changes in
   the serialized document; every other field/record/description is preserved
   byte-for-byte from the live file (no unrelated rewrite).
4. **Atomic write** -- serialize the full document (JSON, array-preserving,
   UTF-8 no BOM) to `<target>.dbm28.tmp` in the same directory, then
   `Move-Item -Force` over the target (the workbook's atomic pattern).
5. **Read-back verification** -- re-read the written file, re-validate, and
   compare the changed field to the intended new value; report a digest.
6. **Audit** -- append a `ConfigChangeRecord` (timestamp, category, field,
   old/new non-secret state, operator action, config version) to
   `state\db-m28-config-changes.json` (DevBridge-local). `SecretReference`
   field is always redacted/omitted.

**Test-run immutability**: the DB-M28 test suite exercises the full
persistence pipeline against a TEMP copy of the config tree. The live
`config\*.json` are SHA-256-asserted byte-identical after the run (same
convention as M25/M26/M27). In production the UI's "Apply" writes to the live
files via the same validated atomic pipeline.

**Limitation reported (per brief)**: `config\pricing\...`,
`config\currency\...`, `config\cost\...`, `config\performance\...`,
`config\ai-routing.json` (beyond the already-editable fields), and
`config\devbridge.json` are treated as governed read-only for DB-M28; DB-M28
does not force persistence onto them. `config\ai-routing.json` `roles` remain
editable through the same mechanism only if a governed step approves; DB-M28
leaves them read-only and reports the limitation.

## 6. DB-M27 integration (no cost-formula duplication)

The UI exposes **VIEW COST ESTIMATE** for the currently selected model route:
it builds a `New-DbM27CalculatorRequest` (ProviderId, RouteType, ModelId,
UnderlyingModelId, PricingRecordId, ReasoningLevel, token fields,
CurrencyTarget) and calls `Invoke-DbM27Calculator` READ-ONLY. The DB-M16
engine remains the single cost authority; DB-M28 duplicates no cost formulas.

## 7. Secret safety

- UI shows only `CONFIGURED | NOT_CONFIGURED | INVALID_CONFIGURATION`.
- The `SecretReference` env-var NAME may be shown; the value never is.
- `ConvertTo-DbM28Html` runs the output through `Test-DbM28SecretLeak` (DB-M28
  wrapper over the DB-M14 pattern) and the guard footer asserts
  `SecretValuesDisplayed=false`.
- Audit records and logs never contain secret values; `RedactedFields` always
  includes `SecretReference` for provider rows.

## 8. Boundary compliance

- `AUTO_EXECUTION_ENABLED = FALSE`; provider/model executed NO; paid calls 0;
  network calls 0 (adapter gate pattern).
- No governance mutation: workbook, roadmap, milestones, dependencies, budget
  policy, pricing records, provider-health state, routing policy, Git PR/merge
  -- all read-only inputs. DB-M19 hard capability checks never overridden.
- Lane C `src\DevBridge.UI` untouched; DB-M26/DB-M27/DB-M18.1 preserved.
- DevBridge is temporary Phase 1/2 scaffolding; nothing migrates into Nexus.

## 9. Test matrix (54 cases, S1-S54)

1 UI launches | 2 provider list renders | 3 model list renders | 4 provider
enabled/disabled | 5 model enabled/disabled | 6 direct route display | 7
gateway route display | 8 local route display | 9 reasoning levels from
contracts | 10 unsupported reasoning not shown | 11 capability display | 12
tool capability | 13 structured-output capability | 14 context capability |
15 pricing reference display | 16 pricing unknown state | 17 provider health
read-only | 18 health cannot be manually fabricated | 19 local provider
display | 20 LOCAL_COST_UNKNOWN preserved | 21 local never assumed FREE | 22
OpenRouter gateway identity | 23 underlying model preserved | 24 routing
eligibility summary | 25 disabled model excluded from eligibility | 26
capability mismatch cannot be overridden by toggle | 27 configuration
incomplete displayed | 28 secrets never rendered | 29 secrets never logged |
30 configured/not-configured secret status | 31 config validation before save
| 32 config persistence (atomic, temp tree) | 33 config read-back | 34
config schema/version preserved | 35 config-change audit | 36 secret audit
redaction | 37 DB-M27 calculator integration | 38 no duplicate cost
calculation | 39 DB-M26 preserved | 40 DB-M18.1 preserved | 41 DB-M19
preserved | 42 DB-M22 preserved | 43 DB-M23 preserved | 44 no budget override
| 45 no router hard-rule override | 46 no provider-health mutation | 47 no
pricing mutation | 48 no AI execution | 49 paid API calls 0 | 50 network
calls 0 | 51 canonical workbook unchanged | 52 Nexus source unchanged | 53 UI
regression (Lane C byte-identical) | 54 solution build 0 errors.

## 10. Outputs

- `design\DB-M28_MODEL_CONFIGURATION_UI.md` (this file)
- `scripts\ai-routing\model-config\ModelConfigContracts.ps1`
- `scripts\ai-routing\model-config\ModelConfigEngine.ps1`
- `scripts\ai-routing\model-config\ModelConfigRender.ps1`
- `scripts\ai-routing\model-config\Test-DbM28ModelConfig.ps1`
- `state\db-m28-result.json`
- `tasks\DB-M28_IMPLEMENTATION_REPORT.md`

**Ready for DB-M29: YES.** **Stop after DB-M28.**
