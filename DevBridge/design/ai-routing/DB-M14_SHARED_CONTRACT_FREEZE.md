# DB-M14 — Shared Contract Freeze (v1)

**Milestone:** DB-M14 · **Lane:** B — AI ROUTING PLATFORM · **Status:** FROZEN
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-30

This document freezes the v1 contracts established by DB-M14. Consumers in later milestones may
**read** these contracts and add **new** artifacts; they may not silently change v1 semantics. Any
incompatible change introduces a **v2** contract.

Companion: `DB-M14_PROVIDER_MODEL_CONTRACTS.md`.

---

## 1. Frozen v1 contracts

| Contract | schemaVersion | Where it lives | Consumers (future) |
|---|---|---|---|
| **Provider v1** | `1` | `config/providers.json` + `AiProvider.ps1` (`New-AiProvider` / `Test-AiProvider`) | provider adapters (DB-M23), routing (DB-M19), pricing (DB-M15) |
| **Model v1** | `1` | `config/models.json` + `ModelCatalogue.ps1` (`New-AiModel` / `Test-AiModel`) | capability query (DB-M19), pricing (DB-M15), attempt history (DB-M17) |
| **CapabilityRequirement v1** | `1` | `AiRoutingContracts.ps1` (`New-AiCapabilityRequirement` / `Test-AiCapabilityRequirement`) | task classifier (DB-M18), routing request (DB-M19) |
| **RoutingDecision v1** | `1` | `AiRoutingContracts.ps1` (`New-AiRoutingDecision` / `Test-AiRoutingDecision`) | routing execution (DB-M19), attempt history (DB-M17) |
| **AiRoutingConfig v1** | `1` | `config/ai-routing.json` | foundation validation, manual-mode policy |

Each contract is stamped `schemaVersion: 1` in every record/artifact, and every validator rejects any
record whose schemaVersion is not `1`. Proven by test S13 (a `schemaVersion: 2` provider record is
rejected).

## 2. Versioning rule (amendment process)

1. A v1 contract may be **extended** by adding optional fields — additive changes are allowed without a
   version bump, as long as existing v1 writers/readers keep working and existing semantics do not change.
2. Any change that **redefines, renames, removes, or re-types** an existing field, or changes the meaning
   of a vocabulary value, is **incompatible** and requires a **v2** contract with its own
   `schemaVersion` value, its own validator, and a documented migration path from v1.
3. No field of a frozen v1 contract is silently repurposed. `null` stays `UNKNOWN`/absent; it is never
   later redefined to mean something else.
4. New contracts added by later milestones get their own new `schemaVersion` keys registered in
   `Get-AiRoutingSchemaVersions`. They do not reuse v1 version numbers.

## 3. What DB-M15 (pricing) and DB-M17 (attempt history) must NOT change

- **DB-M15 (pricing)** owns pricing records. Pricing must be stored as **new** artifacts
  (`config/pricing.json` or equivalent) and may reference Provider v1 / Model v1 by id. DB-M15 must not
  add price fields to Provider v1 or Model v1 records. `RoutingDecision.EstimatedCost` stays `null`
  until DB-M15/M16 fills it; the field exists in the frozen contract already.
- **DB-M17 (attempt history)** owns attempt/run records. Attempt records are **new** artifacts that
  reference `RoutingDecisionId`, `ProviderId`, `ModelId` from frozen contracts. DB-M17 must not alter
  RoutingDecision v1 fields or add provider/model branching.
- Neither milestone may change Provider v1 / Model v1 identity semantics (`ProviderId`, `ModelId`,
  `ProviderModelId`, `UnderlyingModelId`, `GatewayProviderId`), the capability vocabulary, or the
  execution-mode policy.

## 4. Protected semantics (must survive into every v2 too)

- **Provider identity ≠ underlying model identity.** `UnderlyingModelId` defaults to `ModelId`; the same
  underlying model via a gateway is a distinct delivery route, never a different underlying model.
- **`null` capability = UNKNOWN.** Capability queries reject UNKNOWN requirements; they never treat
  `null` as supported. `false` is definitively unsupported.
- **Capability query returns candidates only** — never a price/score-based winner.
- **MANUAL-only active runtime mode.** ASSISTED/AUTO remain vocabulary; active-mode policy lives in
  `allowedRuntimeModes` and is enforced at foundation validation.
- **No provider-name branching** (ADR-005). Provider adapters are the only legitimate exception and live
  in their own directory.
- **Secrets are references, never values** — env-var NAMEs in `SecretReference`/`ConfigurationKey`.

## 5. Contract registry (as of DB-M14)

```text
AiRoutingConfigVersion        = 1
ProviderVersion               = 1
ModelVersion                  = 1
CapabilityRequirementVersion  = 1
RoutingDecisionVersion        = 1
```

Enforced by `Get-AiRoutingSchemaVersions` in `AiRoutingContracts.ps1`.

---
*End of DB-M14 contract freeze.*
