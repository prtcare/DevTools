# DB-M23 OpenRouter Foundation

Status: DESIGN (implementation follows in scripts/ai-routing/providers/)

## Purpose

Represent OpenRouter as a gateway/provider route in the existing
provider-independent AI-routing architecture, with configuration, model
mapping, request/usage/response/error normalization and a DRY_RUN adapter path.
DB-M23 performs NO paid production model execution and NO real provider calls.

DB-M23 is DevBridge-only, temporary, and NOT designed for Nexus migration.

## OpenRouter is a gateway, not a model

OpenRouter is a gateway/provider ROUTE. The underlying model identity stays
distinct. Gateway identity is NEVER collapsed into model identity.

| Route | ProviderId | ModelId (route) | ProviderModelId (route id) | UnderlyingModelId | GatewayProviderId |
|---|---|---|---|---|---|
| direct anthropic | anthropic | claude-sonnet-5 | claude-sonnet-5 | claude-sonnet-5 | (empty) |
| via OpenRouter | openrouter | or:anthropic/claude-sonnet-5 | anthropic/claude-sonnet-5 | claude-sonnet-5 | openrouter |

Decomposition rule for an OpenRouter route id `org/model`: the model part after
the last `/` (or `:`) is the UnderlyingModelId; the full route id is preserved
as ProviderModelId; the gateway is ProviderId/GatewayProviderId = openrouter.
`Find-AiModelByUnderlyingModel` over a catalogue containing both routes returns
both — proving distinct routes for the same underlying model (scenario 13).

## OpenRouter configuration (secret references only)

`New-OpenRouterProviderConfiguration` builds a provider record
(ProviderType=GATEWAY, GatewayType=OPENROUTER, endpoint api.openrouter.ai) plus
an ApiKeyReference = an environment-variable NAME (e.g. OPENROUTER_API_KEY).
NO API key value is stored in source, JSON config, logs, state files or test
fixtures. The secret value is resolved only inside the adapter boundary and
only as a redacted Authorization header for the DRY_RUN shape. Tests inject
fake secret-like strings and assert they never appear in any artifact.

## OpenRouter model catalogue mapping

`Register-OpenRouterRoute` maps an OpenRouter model identifier into DB-M14
semantics (New-AiModel, read-only): route identity, underlying-model identity,
capability metadata, context limits, pricing metadata references, health state
(reference to DB-M22, never re-implemented), reasoning capabilities. Unknown
capability metadata stays UNKNOWN. No business routing policy is hard-coded
inside the OpenRouter adapter.

## OpenRouter pricing

Reuses the DB-M15 pricing architecture READ-ONLY (Get-AiPriceAt). No scraping,
no fetching of live pricing in DB-M23. Configured/versioned price records are
looked up per route. When pricing is unavailable the classification is
PRICE_UNKNOWN (or LOCAL_COST_UNKNOWN for local) — never an invented cost.

## Request / usage / response / error normalization (shared, common layer)

- New-ProviderRequest: provider-independent request (ModelId, Messages,
  ReasoningLevel, MaxOutputTokens, structured-output requirement, tool
  definitions if supported, timeout, metadata). No provider-specific parameter
  leaks into routing/business logic.
- ConvertTo-ProviderNativeRequest: builds the OpenRouter-native request shape
  (OpenAI-compatible body) for the DRY_RUN path. Reasoning levels translate
  deterministically; a level the gateway/route cannot represent is reported
  UNSUPPORTED, never silently dropped.
- New-NormalizedUsage: InputTokens / OutputTokens / CachedInputTokens /
  CacheWriteTokens / ReasoningTokens / TotalTokens / ProviderReportedCost with
  UsageSource ACTUAL | ESTIMATED | UNKNOWN (DB-M17 vocabulary). Missing usage
  stays null — never fabricated.
- ConvertTo-ProviderResponse: common ProviderResponse v1 (RequestId, ProviderId,
  ModelId, UnderlyingModelId, GatewayProviderId, Status, Text/StructuredContent,
  ToolCalls, Usage, FinishReason, LatencyMs, ProviderRequestId, ErrorCategory,
  RetryAfterUtc, RawResponseReference-if-safe, AutoExecutionEnabled=false). Raw
  secrets never stored; RawResponseReference is an artifact REFERENCE only.
- ConvertTo-ProviderError: normalizes provider-native errors into the DB-M23
  error vocabulary (AUTHENTICATION, RATE_LIMIT, PROVIDER_UNAVAILABLE, TIMEOUT,
  INVALID_OUTPUT, CONTEXT_TOO_LARGE, TOOL_FAILURE, UNKNOWN_FAILURE) and maps
  deterministically onto the DB-M20 failure-category vocabulary
  (PROVIDER_UNAVAILABLE -> PROVIDER_AVAILABILITY; others identity). No
  provider-specific failure logic is created inside DB-M20.

## Execution boundary / dry-run

Adapter selection and the execution gate live in the common layer. The gate
accepts the PRE-COMPUTED routing decision (DB-M19), budget evaluation (DB-M21)
and route availability (DB-M22) as READ-ONLY inputs and refuses when any block:

| Gate input | Blocking state | Refusal |
|---|---|---|
| ExecutionMode | AUTO | AUTO_EXECUTION_PROHIBITED |
| RoutingDecision | no eligible candidate / REJECTED | ROUTING_NOT_ELIGIBLE |
| BudgetEvaluation | Decision not ALLOW / ALLOW_WITH_WARNING / NO_APPLICABLE_BUDGET | BUDGET_BLOCK |
| Health (DB-M22) | Test-ProviderRouteAvailable false | HEALTH_BLOCK |

The adapter cannot rewrite the routing decision, bypass a budget block, or
bypass an unhealthy state (scenarios 43-45). DRY_RUN returns DRY_RUN_READY and
sends nothing; NetworkCalls = 0. AUTO_EXECUTION_ENABLED = FALSE. MANUAL mode is
preserved; ASSISTED routes are represented; AUTO execution is prohibited.

## Boundaries enforced by DB-M23

- No provider/model executed, no network call, no paid call.
- No fallback decision (DB-M22), no retry/escalation decision (DB-M20), no
  budget approval (DB-M21), no routing decision (DB-M19) is made here.
- No Nexus source/workbook mutation, no roadmap modification, no Git PR/merge.
- Temporary DevBridge boundary: no assumption that Nexus will use these adapters.
