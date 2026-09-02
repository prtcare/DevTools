# DB-M22 — Provider Health Foundation (ProviderHealthEvidence v1 + ProviderHealthPolicy v1)

**Milestone:** DB-M22 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M22 is a **deterministic provider-health and route-failover foundation**. It
answers "is this configured provider/model route currently suitable for use?"
and "if not, is there another eligible route that can be recommended?" — it
**never executes a provider/model**, makes **no paid API call** and **no network
call**. `AUTO_EXECUTION_ENABLED = FALSE`. Recommendation/decision only.

Companion: `DB-M22_FAILOVER.md`.

---

## 1. Governing constraints

| Constraint | Behaviour |
|---|---|
| Health is not quality | Provider/route conditions (AUTH_ERROR, RATE_LIMITED, PROVIDER_UNAVAILABLE, NETWORK_FAILURE, TIMEOUT) are **never** written back into a model's quality score. DB-M24's ModelQualityFailureCount vs ProviderFailureCount are never conflated. |
| Same model, many routes | A model may be UNAVAILABLE through a direct provider and AVAILABLE through a gateway. Route identity is `ProviderId` + `GatewayProviderId` (+ `UnderlyingModelId`), so that is represented correctly. |
| Reuse DB-M14 vocabulary | Health states are the DB-M14 set: `AVAILABLE / RATE_LIMITED / DEGRADED / AUTH_ERROR / UNAVAILABLE / DISABLED / UNKNOWN`. No invented aliases. |
| Consume foundations read-only | DB-M14 catalogue/route identity; DB-M17 attempt history; DB-M19 eligible candidates; DB-M20 escalation decisions; DB-M21 budget permission + failure fingerprints; DB-M24 performance evidence. No competing store. |
| Evidence expiry | Health evidence expires. An AVAILABLE from weeks ago never proves current availability. Deterministic freshness policy via injected evaluation timestamp. |
| Unknown is explicit | UNKNOWN is never silently treated as AVAILABLE. Policy decides allow (low-risk) / disallow (high-risk confirmed) / require operator confirmation. |
| DISABLED stays disabled | A configuration-disabled provider/model remains unavailable regardless of historical success. No health logic re-enables it automatically. |
| No secrets | Raw API keys / authorization headers / tokens / credentials are never stored. A secret-like value in any stored health field rejects the evidence. |
| Manual override is explicit | Only explicit `OverrideReference` + `OverrideReason` + timestamp counts. DB-M22 never infers human approval. A manual health override never silently re-enables a configuration-DISABLED provider. |
| No roadmap / Git / execution | Health logic can never rewrite the roadmap, create/approve/merge a PR, or bypass AWAITING_HUMAN_PR / PR_OPEN / AWAITING_HUMAN_MERGE. A human Git gate is NOT a provider failure. |
| Deterministic | The evaluation timestamp is injected; freshness/cooldown windows are derived from it, never the machine clock. No randomness. ADR-005: no provider/model name branching. |

## 2. Health evidence model

### ProviderHealthEvidence v1

| Field | Meaning |
|---|---|
| `SchemaVersion` | 1 |
| `EvidenceId` | deterministic unique evidence id (`HE-<hash16>`) |
| `ProviderId` | the provider this evidence describes |
| `RouteId` | route key (`ProviderId` or `ProviderId|GatewayProviderId`) where route-specific |
| `UnderlyingModelId` | the underlying model where route-specific (nullable) |
| `GatewayProviderId` | gateway where route-specific (nullable) |
| `ObservedState` | DB-M14 health state observed |
| `EvidenceType` | `CONFIGURATION`, `RECENT_ATTEMPT`, `PASSIVE_FAILURE`, `PASSIVE_SUCCESS`, `MANUAL_OPERATOR_STATUS`, `SYNTHETIC_TEST`, `FUTURE_HEALTH_PROBE` |
| `ObservedAtUtc` | when observed (injected in tests) |
| `ExpiresAtUtc` | explicit expiry (nullable; policy freshness is the default) |
| `FailureCategory` | DB-M20 failure category when the evidence records a failure |
| `HttpStatusClass` | e.g. `429`, `5xx` — only where safely applicable |
| `RetryAfterUtc` | server-provided retry-after instant (nullable) |
| `LatencyMs` | transport latency (nullable) |
| `Source` | where the evidence came from (free identifier, e.g. attempt id / operator id / probe id) |
| `Confidence` | evidence confidence |
| `AttemptIdReference` | DB-M17 attempt id when the evidence derives from an attempt |
| `Notes` / `ReasonCodes` | structured notes |

### Health sources
`CONFIGURATION`, `RECENT_ATTEMPT`, `PASSIVE_FAILURE`, `PASSIVE_SUCCESS`,
`MANUAL_OPERATOR_STATUS`, `SYNTHETIC_TEST`, `FUTURE_HEALTH_PROBE`. DB-M22
prefers deterministic/offline fixtures; no real paid provider is invoked.

## 3. ProviderHealthPolicy v1 (schemaVersion = 1)

| Field | Meaning |
|---|---|
| `PolicyId`, `Name`, `Enabled` | identity + on/off |
| `EvidenceFreshnessSeconds` | how old evidence may be and still count (default 300) |
| `FailureThreshold` | provider failures within the window that OPEN the circuit (default 3) |
| `SuccessRecoveryThreshold` | recent successes that CLOSE a HALF_OPEN/OPEN circuit (default 1) |
| `RateLimitCooldownSeconds` | how long a RATE_LIMITED state persists absent a new signal (default 60) |
| `UnavailableCooldownSeconds` | how long an UNAVAILABLE state persists (default 300) |
| `AuthErrorRequiresHuman` | AUTH_ERROR requires HUMAN_PROVIDER_CONFIGURATION_REQUIRED (default true) |
| `DegradedFailureThreshold` | failures that produce DEGRADED before OPEN (default 1) |
| `AllowUnknownProvider` | UNKNOWN health may be used for low-risk/manual work (default false) |
| `RequireConfirmedAvailableForHighRisk` | high-risk work requires AVAILABLE, not UNKNOWN (default true) |
| `CircuitOpenDurationSeconds` | how long the circuit stays OPEN before HALF_OPEN probe eligibility (default 300) |
| `AllowManualOverride`, `RequireReasonForOverride` | explicit human override switches |
| `Notes` | free text |

No thresholds are hard-coded in engine logic; every value is read from the
policy object.

## 4. Effective health aggregation (deterministic)

`Get-EffectiveProviderHealth` folds recent evidence for a route into one
effective DB-M14 health state. Order (highest priority first):

1. **DISABLED** configuration evidence → `DISABLED` (never re-enabled by health).
2. **AUTH_ERROR** fresh evidence (and `AuthErrorRequiresHuman`) → `AUTH_ERROR` (RequiresHuman).
3. **RATE_LIMITED** fresh evidence → `RATE_LIMITED` until `RetryAfterUtc` (or policy cooldown) elapses.
4. **UNAVAILABLE** failures reaching `FailureThreshold` → `UNAVAILABLE` (cooldown starts at last failure).
5. **DEGRADED** failures reaching `DegradedFailureThreshold` → `DEGRADED`.
6. **Success evidence** reaching `SuccessRecoveryThreshold` with no blocking state → `AVAILABLE`.
7. Otherwise → `UNKNOWN` (explicit; policy decides allow/disallow).

Stale evidence (older than `EvidenceFreshnessSeconds` or past `ExpiresAtUtc`)
does not contribute → the route reports `UNKNOWN` with a `STALE_EVIDENCE` note.
`Same input → same output` (pure function of evidence + policy + injected ts).

## 5. Circuit breaker (CLOSED / OPEN / HALF_OPEN)

| State | Meaning |
|---|---|
| `CLOSED` | route usable |
| `OPEN` | route temporarily suppressed (provider failures reached `FailureThreshold`) |
| `HALF_OPEN` | limited/probe eligibility when `CircuitOpenDurationSeconds` cooldown expired |

Rules (deterministic, evidence-driven):
- failures ≥ `FailureThreshold` within the freshness window → `OPEN` (opened at the last failure time)
- cooldown elapsed → `HALF_OPEN`
- positive/success evidence while HALF_OPEN → `CLOSED`
- failure while HALF_OPEN → `OPEN` again
- `AUTH_ERROR` may demand human action rather than automatic probing.

`Get-ProviderCircuitState` derives the state; `Update-ProviderCircuitState` is
the pure next-state transition used for "what happens if this new evidence lands".

## 6. Secret protection

A secret-like value in any stored health field rejects the evidence
(`Test-DbM22SecretLeak`, same house pattern as DB-M14/DB-M17). AUTH_ERROR is
recorded as a state; the credential is never stored.

## 7. Manual operator override

`Test-ProviderHealthOverride` grants a health override ONLY on explicit
`OverrideReference` + `OverrideReason` + `OverrideTimestampUtc`. Outcomes:
`OVERRIDE_GRANTED`, `OVERRIDE_PROHIBITED` (policy disallows), 
`OVERRIDE_REASON_REQUIRED` (policy requires and it is missing), `NO_OVERRIDE_NEEDED`.
A granted override still cannot re-enable a configuration-DISABLED provider.

## 8. Health history

Evidence is append-only (test suite keeps a list). The current effective state
is derived; prior events remain traceable via `EvidenceId` / `AttemptIdReference`.
Health reports expose the retained evidence, not a single overwritten status.

## 9. Manual / Assisted / Auto

- **MANUAL** — display route-health + fallback evidence; human chooses.
- **ASSISTED** — recommend healthy alternative / wait / human action; human triggers.
- **AUTO** — prohibited. `AUTO_EXECUTION_ENABLED = FALSE` on every decision.

## 10. Operations (no AI execution)

`New-ProviderHealthEvidence`, `Get-EffectiveProviderHealth`,
`Test-ProviderRouteAvailable`, `Get-ProviderCircuitState`,
`Update-ProviderCircuitState`, `Get-EligibleFailoverRoutes`,
`Get-ProviderFailoverDecision`, `Test-ProviderHealthOverride`,
`Export-ProviderHealthReport`.
