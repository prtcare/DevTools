# DB-M23 Local Models Foundation

Status: DESIGN (implementation follows in scripts/ai-routing/providers/)

## Purpose

Establish the provider-adapter foundation that lets DevBridge eventually reach
LOCAL model runtimes through the existing provider-independent AI-routing
architecture. DB-M23 is a CONFIGURATION / CAPABILITY-DISCOVERY / TRANSLATION /
DRY-RUN milestone. It performs NO paid production model execution and makes NO
real provider calls. AUTO_EXECUTION_ENABLED = FALSE.

DB-M23 is DevBridge-only, temporary, and NOT designed for Nexus migration.

## Architecture principle

Business logic stays provider-independent. The flow remains:

```
Task -> DB-M18 classification/context -> DB-M19 routing -> DB-M21 budget
  -> DB-M22 provider health -> provider adapter -> (future execution layer)
```

DB-M23 owns provider adapter foundations. Routing logic (DB-M19), budget
approval (DB-M21), health/failover (DB-M22) and retry/escalation (DB-M20)
remain in their own milestones. Adapters NEVER move routing policy into
provider-specific code and NEVER bypass DB-M19/M21/M22.

## Generic local abstraction (NOT "Ollama == local models")

A local provider is represented generically. A runtime (Ollama, LM Studio,
llama.cpp server, any OpenAI-compatible local endpoint) is expressed by the
`ApiStyle` and `GatewayType` vocabulary members from DB-M14, never by a
hard-coded runtime name in shared logic.

| DB-M14 vocabulary | Members relevant to local |
|---|---|
| Get-AiRoutingProviderTypes | LOCAL, OPENAI_COMPATIBLE, OLLAMA_COMPATIBLE, DIRECT, GATEWAY |
| Get-AiRoutingGatewayTypes | OPENAI_COMPATIBLE, OLLAMA_COMPATIBLE, ANTHROPIC_COMPATIBLE, DIRECT, OPENROUTER |
| Get-AiRoutingLocalOrRemote | LOCAL, REMOTE, UNKNOWN |

No capability is invented: every capability field that was not configured or
discovered stays null (= UNKNOWN). UNKNOWN must remain explicit.

## LocalProviderConfiguration v1 (DB-M23-owned)

Fixed field list (schemaVersion 1):

| Field | Semantics |
|---|---|
| ProviderId | normalized lowercase identifier (data, never compared to a literal in shared logic) |
| DisplayName | human label |
| Endpoint | base endpoint URI (`local://` or `http(s)://`); LOCAL providers may use non-https schemes |
| ApiStyle | from Get-DbM23ApiStyles (OPENAI_COMPATIBLE / OLLAMA_COMPATIBLE / ANTHROPIC_COMPATIBLE / OPENROUTER / GENERIC) |
| Enabled | bool; disabled provider is unusable (scenario 2) |
| RequiresAuthentication | bool; if true a SecretReference (env-var NAME) must be present |
| DefaultTimeoutSeconds | positive integer or null |
| SupportsStreaming | bool |
| SupportsToolCalls | bool |
| SupportsStructuredOutput | bool |
| HealthMode | PASSIVE / ACTIVE / MANUAL / UNKNOWN |
| Locality | forced 'LOCAL' |
| ConfigurationKey | secret/configuration KEY NAME (never a value) |
| SecretReference | env-var NAME (never a value) when RequiresAuthentication |
| Notes | free text |

No secrets are stored in configuration. SecretReference / ConfigurationKey are
NAMES. Test-DbM23SecretLeak rejects any secret-LIKE VALUE in any stored field.

`Test-LocalProviderConfiguration` validates: ProviderId required; Locality must
be LOCAL; Endpoint must look like a URI; ApiStyle valid; bool fields typed;
SecretReference must be a `^[A-Z][A-Z0-9_]{2,}$` NAME when present;
RequiresAuthentication=true implies SecretReference present; no secret values.

## Local model registration

`Register-LocalModel` maps a configured local model into the DB-M14 model
catalogue via `New-AiModel` (read-only consumption; DB-M14 files untouched).

Preserved fields: ProviderId, ModelId, UnderlyingModelId, DisplayName,
capabilities (tool use, structured output, vision, coding, reasoning),
ReasoningLevelsSupported, ContextWindow, MaxOutputTokens, LocalOrRemote='LOCAL',
EndpointOverride=<endpoint>. Health state is NOT part of the model record
(health lives in DB-M22); the registration reports a HealthState reference only
when DB-M22 evidence exists.

Unknown capabilities stay null. `Register-LocalModel` never invents a
capability that was not configured or discovered.

## Local price semantics (M15/M16 semantics; LOCAL != FREE)

`Get-ProviderRoutePriceStatus` classifies a route's price status:

| PriceStatus | Meaning |
|---|---|
| CONFIGURED | an effective DB-M15 pricing record exists with a non-zero provider token price |
| FREE | an effective DB-M15 pricing record exists with an explicit zero provider token price |
| LOCAL_COST_UNKNOWN | LOCAL provider with NO effective pricing record: zero provider token price is the default ONLY at the provider level; operational cost stays UNKNOWN (never asserted zero) |
| PRICE_UNKNOWN | REMOTE route with no effective pricing record |

DB-M23 never automatically says LOCAL = FREE. A zero provider token price is
NOT a claim of zero operational cost: `OperationalCostUnknown` is true for any
LOCAL route unless an explicit operational-cost basis is configured.

Pricing is consulted READ-ONLY through the DB-M15 catalogue (Get-AiPriceAt).
No scraping, no live pricing, no invented rates.

## Local health integration (DB-M22 read-only)

Local endpoints integrate with DB-M22 semantics through the DB-M22 evidence
contract (New-ProviderHealthEvidence):

| Local condition | DB-M22 ObservedState | EvidenceType |
|---|---|---|
| endpoint offline / unreachable | UNAVAILABLE | PASSIVE_FAILURE |
| model not loaded | UNAVAILABLE (route unavailable) | PASSIVE_FAILURE |
| configured disabled | DISABLED | CONFIGURATION |
| provider refuses auth | AUTH_ERROR | PASSIVE_FAILURE |
| rate limited | RATE_LIMITED | PASSIVE_FAILURE |

Local endpoint failure is NEVER recorded as MODEL_QUALITY (DB-M20
FailureCategory is PROVIDER_AVAILABILITY / RATE_LIMIT / AUTHENTICATION as
appropriate). No uncontrolled local polling loops: the adapter records evidence
only when an attempt or explicit health event occurs; it never polls on a timer.

## Request + reasoning translation

`New-ProviderRequest` is provider-independent (ModelId, Messages, ReasoningLevel
from DB-M14, MaxOutputTokens, RequiresStructuredOutput, RequiresTools,
ToolDefinitions, TimeoutSeconds, RequestMetadata). No provider-specific
parameter leaks into router/business logic.

`ConvertTo-ProviderNativeRequest` translates the generic request into a
provider-native shape for the configured ApiStyle. DB-M14 reasoning levels
NONE/LOW/MEDIUM/HIGH/MAX translate through the adapter's reasoning table into a
provider-specific parameter. Routing logic never knows the provider parameter
name. If the provider cannot represent the requested reasoning level, the
translation returns UNSUPPORTED and the capability validation reports it
(scenarios 20-22).

## Dry-run mode

`ConvertTo-ProviderNativeRequest -DryRun` builds the provider-native request
(shape + headers with secrets redacted) and returns DRY_RUN_READY. NO request is
sent. The execution gate (AdapterExecutionBoundary) refuses anything other than
MANUAL/ASSISTED display or ASSISTED recommendation; AUTO_EXECUTION_ENABLED=FALSE.

## Operations (DB-M23-owned)

- New-LocalProviderConfiguration / Test-LocalProviderConfiguration
- Register-LocalModel
- Get-ProviderRoutePriceStatus
- New-ProviderRequest / Test-ProviderRequest
- ConvertTo-ProviderNativeRequest (ApiStyle-aware; DRY_RUN)
- ConvertTo-ProviderResponse / ConvertTo-ProviderError / New-NormalizedUsage
- New-ProviderDryRunResult (DRY_RUN_READY)
- Test-ProviderAdapterExecutionAllowed (AUTO guard + routing/budget/health gates)
- Test-DbM23SecretLeak / ConvertTo-DbM23RedactedValue / ConvertTo-DbM23RedactedHeaders

## Boundaries enforced by DB-M23

- No provider/model executed. No network call. No paid call.
- No routing decision (DB-M19), no budget approval (DB-M21), no health verdict
  (DB-M22), no retry/escalation decision (DB-M20).
- Adapters expose route capabilities/status and normalized request/response
  shapes only. Fallback is decided by DB-M22, never by an adapter.
- Git PR/merge capability: none. Roadmap modification capability: none.
