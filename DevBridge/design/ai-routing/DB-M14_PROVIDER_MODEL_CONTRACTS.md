# DB-M14 — Provider Abstraction + Model Catalogue Foundation

**Milestone:** DB-M14 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-30

This document describes the implemented provider/model contract foundation. It is the executable
counterpart of DB-M13's `AI_ROUTING_ARCHITECTURE.md` Phase 1-21. Companion: `DB-M14_SHARED_CONTRACT_FREEZE.md`.

**NO AUTOMATIC AI EXECUTION EXISTS YET.** No provider call, no model call, no routing, no pricing,
no escalation, no health check execution. DB-M14 establishes identity + capability contracts only.

---

## 1. Implementation location decision (Phase 1 discovery)

DevBridge has **two** execution layers:

| Layer | Owner | Tech | Status |
|---|---|---|---|
| Governance lifecycle (DB-M03..M11) | existing lane | PowerShell 5.1 dot-source libraries + JSON state + Markdown | working, untouched |
| Operator UI | **DB-M12 lane** | `.NET` solution `src/DevBridge.slnx` → `DevBridge.Engine` (net10.0 class lib), `DevBridge.UI` (WPF), `DevBridge.Tests` | **in progress, unfinished, DB-M12-owned** |

**Decision:** DB-M14 is implemented **PowerShell-first and isolated**, consistent with the working
governance layer and the DB-M13 parallel plan. Rationale:

- The live lifecycle is PowerShell; the router must eventually integrate with those scripts, so the
  contracts live where the consumers live.
- `DevBridge.Engine` is **DB-M12-owned and unfinished**; the parallel-safety rule forbids depending on
  incomplete DB-M12 files, and forbids modifying them. No DB-M14 file touches `src/`.
- The brief allows PowerShell if DevBridge remains PowerShell-first; the governance layer is.
- No large new application framework was created.

**Future note (not acted on):** when `DevBridge.Engine` stabilizes, an adapter could bridge the
PowerShell contracts to the .NET domain. That is a later decision, not DB-M14's.

## 2. Files created (all additive, DB-M14-owned)

| File | Purpose |
|---|---|
| `config/ai-routing.json` | execution mode (MANUAL-only active), role aliases, inert routing defaults |
| `config/providers.json` | provider identity catalogue (7 providers, all `Enabled=false`, `Configured=false`) |
| `config/models.json` | seed model catalogue (4 models, all `Enabled=false`, conservative capabilities) |
| `scripts/ai-routing/AiRoutingContracts.ps1` | vocabularies, schema versions, capability-requirement + routing-decision contracts, secret guard, ADR-005 branching guard |
| `scripts/ai-routing/AiProvider.ps1` | provider identity functions (`New-AiProvider`, `Test-AiProvider`, `Add/Get/Get-Enabled`, `Validate-AiProviderCatalogue`) |
| `scripts/ai-routing/ModelCatalogue.ps1` | model identity + capability catalogue (`New-AiModel`, `Test-AiModel`, `Add/Get/Get-Enabled`, `Find-AiModelByCapability/Provider/UnderlyingModel`, `Validate-AiModelCatalogue`) |
| `scripts/ai-routing/AiRoutingFoundation.ps1` | aggregator: dot-sources the three libs, `Import-AiRoutingConfiguration`, `Validate-AiRoutingFoundation` |
| `scripts/ai-routing/Test-AiRoutingFoundation.ps1` | self-contained assertion suite (51 checks) — **zero paid API calls** |

**Usage:** `powershell -NoProfile -Command ". 'scripts\ai-routing\AiRoutingFoundation.ps1'"`, then call
the exported functions. Configuration is validated deterministically with `Validate-AiRoutingFoundation`.

## 3. Provider identity (Phase 2)

Provider records carry identity + capability-support metadata only — **no provider-specific business
fields, no secrets**. Seed providers: `deepseek`, `anthropic`, `openai`, `gemini`, `openrouter`,
`local`, `ollama`.

```text
ProviderId / DisplayName / Enabled / Configured / ProviderType / BaseEndpoint / GatewayType
SupportsStreaming / SupportsTools / SupportsPromptCaching / SupportsBatch
SupportsStructuredOutput / SupportsReasoningControls / SupportsUsageReporting / SupportsHealthCheck
ConfigurationKey / SecretReference / Notes
```

- `ProviderType` vocabulary: `DIRECT | GATEWAY | LOCAL | OPENAI_COMPATIBLE | OLLAMA_COMPATIBLE`.
- All seed providers are `Enabled=false` and `Configured=false` — **no provider is claimed operational**.
- `SecretReference` holds an **env-var NAME** (`DEEPSEEK_API_KEY`, …) — never a value (Phase 15).

## 4. Model identity — gateway vs. underlying model (Phase 3)

Provider identity and underlying-model identity are **separable**. A model record has:

```text
ModelId / ProviderId / ProviderModelId / UnderlyingModelId / GatewayProviderId / DisplayName
Enabled / ModelFamily / ModelVersion / LocalOrRemote / EndpointOverride / EffectiveFrom / EffectiveTo
```

- `UnderlyingModelId` = the true underlying model. Defaults to `ModelId` (a direct model is its own
  underlying model).
- `GatewayProviderId` = the gateway delivering the route (`openrouter`, …), when applicable.
- The **same underlying model via a direct provider and via a gateway is two distinct delivery
  routes**, never two underlying models. Proven by test S9:
  `Find-AiModelByUnderlyingModel -UnderlyingModelId 'deepseek-v4-flash'` returns both the `deepseek`
  direct route and the `openrouter` gateway route.

## 5. Capability metadata (Phase 4)

```text
SupportsCoding / SupportsReasoning / SupportsVision / SupportsToolUse / SupportsStructuredOutput
SupportsPromptCaching / SupportsBatch / SupportsStreaming
ContextWindow / MaxOutputTokens / ReasoningLevelsSupported / RelativeSpeed / ReliabilityClass
LocalOrRemote / AdditionalCapabilityTags
```

- **Unknown is expressed as `null`**, false means definitively unsupported, true only where proven.
  Seed records mark every unverified capability `null` rather than guessing (Phase 12 rule).
- Capability records **do not embed routing policy**. The catalogue describes; DB-M19 decides.

## 6. Reasoning normalization (Phase 5)

Normalized, provider-independent vocabulary: **`NONE | LOW | MEDIUM | HIGH | MAX`**.
Models declare `ReasoningLevelsSupported`. Provider adapters (future) translate these into
provider-specific controls; **no provider-specific reasoning parameter names exist in business logic**.

## 7. Reliability / speed vocabularies (Phase 6)

- `RelativeSpeed`: `VERY_FAST | FAST | NORMAL | SLOW`
- `ReliabilityClass`: `EXPERIMENTAL | STANDARD | HIGH | CRITICAL_GRADE`

Both are configurable/documented with ordering used by capability queries (at-least/at-most).

## 8. Provider health vocabulary (Phase 7)

**Representation only** — no health checks are performed (DB-M22):

```text
AVAILABLE | RATE_LIMITED | DEGRADED | AUTH_ERROR | UNAVAILABLE | DISABLED | UNKNOWN
```

`Find-AiModelByCapability -ProviderHealth @{ provider = 'UNAVAILABLE' }` excludes models on
`UNAVAILABLE | DISABLED | AUTH_ERROR` providers (proven by test S17).

## 9. Execution modes (Phase 14)

- `config/ai-routing.json` `executionMode: "MANUAL"`, `allowedRuntimeModes: ["MANUAL"]`.
- **MANUAL is the only active runtime mode.** ASSISTED and AUTO are vocabulary values and future
  configuration; `Validate-AiRoutingFoundation` rejects any active mode not in `allowedRuntimeModes`
  and rejects AUTO outright (proven by S11).
- AUTO additionally requires a future governance gate (new ADR + workbook update + enable flag +
  kill switch) — **not implemented**.

## 10. Role aliases (Phase 13)

Convenience/manual-mode configuration in `config/ai-routing.json` `roles`:
`DefaultCheapModel`, `DefaultCodingModel`, `DefaultReviewer`, `DefaultPremiumModel`.
Roles are **references, not routing**; they resolve to catalogue models (warning if unresolved, S19).

## 11. Schema versioning (Phase 17)

Frozen **v1** contracts — `schemaVersion: 1` in every artifact. See `DB-M14_SHARED_CONTRACT_FREEZE.md`.
Later incompatible changes must introduce **v2**, never silently change v1 semantics (proven by S13:
a `schemaVersion: 2` record is rejected).

## 12. Secret references (Phase 15)

- No secrets are stored anywhere. `SecretReference`/`ConfigurationKey` are env-var NAMEs.
- `Test-AiRoutingSecretValueLeak` scans any record/catalogue for API-key-shaped VALUES
  (`sk-…`, `AIza…`, `ghp_…`, PEM blocks, inline `api_key=` assignments) and flags them
  (proven by S12). The scan runs inside every catalogue validation.

## 13. Catalogue queries (Phase 10)

Implemented (filtering only — **no winner selection, no pricing**):

| Function | Behavior |
|---|---|
| `Add-AiProvider` / `Add-AiModel` | insert; duplicate ids rejected |
| `Get-AiProvider` / `Get-AiProviders` / `Get-AiEnabledProviders` | by id / all / enabled |
| `Get-AiModel` / `Get-AiModels` / `Get-AiEnabledModels` | by id / all / enabled |
| `Find-AiModelByProvider` | all models of a provider |
| `Find-AiModelByUnderlyingModel` | all delivery routes for one underlying model |
| `Find-AiModelByCapability` | capability filter: enabled, provider-enabled, health-aware, then coding / vision / tool-use / structured-output / reasoning-level / context-size / output-size / reliability / latency / local-remote / allowed-disallowed providers+models |
| `Validate-AiProviderCatalogue` / `Validate-AiModelCatalogue` | deterministic validation |
| `Validate-AiRoutingFoundation` | end-to-end config validation |

Capability queries return **candidates**, never a price-based winner — that is DB-M19.

## 14. ADR-005 enforcement (Phase 20)

`Test-AiProviderNameBranching` scans for direct comparisons of a Provider/Model identifier against a
literal provider/model name (`-eq`, `-ne`, `-in`, `-notin`, `-match`, `-like`, `-ceq`, `-cne`),
including `@('a','b')` membership. Test S14 proves:
- crafted `if ($Provider -eq "deepseek-v4-flash")` → detected
- crafted `$ProviderId -in @('anthropic','openai')` → detected
- variable-only comparisons → clean
- **all four shared routing libraries contain zero provider-name branches.**

## 15. Manual-mode compatibility (Phase 14)

- `config/ai-routing.json` is inert: `routingDefaults.enabled: false`, `policyVersion "0.0.0"`.
- The existing `Development Control → DevBridge → ChatGPT → DeepSeek → Verification → Claude →
  Completion` flow is untouched. No DB-M03..M11 script, workbook, state, or Nexus file was modified.

## 16. Tests (Phase 24)

`Test-AiRoutingFoundation.ps1` — **51 checks, all pass, 0 failed, 0 paid API calls.** Scenarios:
provider creation/validation, duplicate provider, model creation, unknown provider, disabled-model
exclusion, capability filtering (coding/vision/structured-output), reasoning-level filtering,
context-size filtering, gateway identity, underlying-model identity, manual execution mode
(MANUAL valid / AUTO rejected / ASSISTED not-yet), secret-value leakage protection, schema v1
validation, provider-name branching guard (literal + array + real-libs), catalogue
serialization/deserialization (temp config round-trip), duplicate `ProviderModelId`, provider-health
exclusion, no-network/API-call scan of the libraries, role resolution, capability-requirement
validation, routing-decision shape validation.

---
*End of DB-M14 contracts doc. Contract freeze: `DB-M14_SHARED_CONTRACT_FREEZE.md`.*
