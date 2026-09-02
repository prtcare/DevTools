# DB-M21 — Failure Fingerprinting + Combined Attempt Permission

**Milestone:** DB-M21 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M21 Part B answers: "have we already seen effectively this same failure under
effectively the same attempt conditions?" It produces a deterministic
`FailureFingerprint v1` and a combined `Get-AiAttemptPermission` decision that
combines budget + known-failure + the DB-M20 escalation recommendation. No
model/provider execution. `AUTO_EXECUTION_ENABLED = FALSE`.

Companion: `DB-M21_BUDGET_CONTROL.md`.

---

## 1. Governing constraints

| Constraint | Behaviour |
|---|---|
| Deterministic fingerprint | SHA-256 signature over a **normalized** component string (task type, failure category, normalized codes, route, reasoning, context hash, prompt hash reference, tool category). Same meaningful failure → same signature. |
| Normalization | Timestamps, GUIDs, temp paths, absolute user-machine directory prefixes and (policy-allowed) line-number / retry-counter noise collapse to stable markers. Meaningful error-code differences are preserved. |
| Secret protection | Raw prompts/secrets are never inputs. Prompt/context are carried as hashes or references. A secret-like value in any stored field rejects the fingerprint. |
| Provider vs model separation | `AUTHENTICATION` / `RATE_LIMIT` / `PROVIDER_AVAILABILITY` (infrastructure) never match `MODEL_QUALITY` fingerprints — the category is part of the signature, so M24 quality history stays meaningful. |
| Recurrence typed, not flat | `FIRST_OCCURRENCE` · `REPEATED_SAME_ROUTE` · `REPEATED_SAME_MODEL` · `REPEATED_SAME_FAILURE` · `REPEATED_AFTER_REASONING_ESCALATION` · `REPEATED_AFTER_MODEL_SWITCH` · `KNOWN_FAILURE_RESOLVED`. |
| Retry suppression | An identical repeat (same failure + same model + same reasoning + known-same context, above the repeat threshold) is suppressed with `RETRY_SUPPRESSED_KNOWN_FAILURE`. DB-M20 then replans (reasoning / model / context / human / stop). DB-M21 never executes that replan. |
| No roadmap power | `PERSISTENT_IMPLEMENTATION_FAILURE` is an **evidence signal only**. The lifecycle may choose `CORRECT_CURRENT_ATTEMPT` while active or later `NEW_FIX_TASK_REQUIRED`; DB-M21 creates/modifies no roadmap or workbook record. |
| Algorithm versioning | `AlgorithmVersion` is recorded; a v2 normalization never silently reinterprets a v1 signature (matching is version-scoped). |
| Collision safety | The final signature is SHA-256, but the structured components stay inspectable so an unexpected grouping can be diagnosed. Behaviour never depends on the opaque hash alone. |
| Deterministic | Stable sorts, fixed normalization pipeline, injected timestamps. ADR-005: no provider/model name branching. |

## 2. FailureFingerprint v1

| Field | Meaning |
|---|---|
| `SchemaVersion` / `FingerprintId` | identity (`FP-<version>-<sig16>`) |
| `AlgorithmVersion` | normalization/signature algorithm version (int) |
| `TaskId` / `ChangeId` | scoping |
| `TaskType` | DB-M14 task-type vocabulary |
| `FailureCategory` | DB-M20 failure-category vocabulary (read-only) |
| `NormalizedFailureCodes` | normalized, sorted, deduped error/verification codes |
| `ModelId` / `UnderlyingModelId` / `ProviderId` / `GatewayProviderId` | route identity |
| `ReasoningLevel` | NONE/LOW/MEDIUM/HIGH/MAX |
| `ContextHash` | 64-hex SHA-256 of the context package (hash, never content) |
| `PromptHashReference` | prompt artifact reference or 64-hex prompt hash (never the prompt) |
| `ToolCategory` | build/test/verification/coding/runtime/provider/... |
| `NormalizedSignature` | the pre-hash normalized component string (explainable) |
| `Signature` | SHA-256 hex of `NormalizedSignature` |
| `FirstSeenUtc` / `LastSeenUtc` / `OccurrenceCount` / `AttemptIds` | recurrence bookkeeping |

## 3. Normalization pipeline (`Get-DbM21NormalizeFailureCode`)

Applied in fixed order to each failure/error code:
1. timestamps → `<TS>`
2. GUIDs → `<GUID>`
3. temp paths / `AppData\Local\Temp` / user-home prefixes → `<TMP>` / `<USERDIR>`
4. absolute user-machine directory prefixes → `<USERDIR>`
5. line-number / column spans `(12,34)` → `(N)` when policy allows
6. volatile retry counters (`retry #2`, `attempt 3`) → `retry N` / `attempt N`

`NormalizeLineNumbers` is a switch (default on). Meaningful error distinctions
(e.g. a changed error code) are never normalized away.

## 4. Operations

- `New-AiFailureFingerprint` — normalize + hash into a `FailureFingerprint v1`;
  validates hash-shaped `ContextHash`/`PromptHash` (64-hex) and rejects any
  secret-like stored value.
- `Compare-AiFailureFingerprint -NewFingerprint -KnownFingerprints -Result` —
  version-scoped match; returns the recurrence type + occurrence bookkeeping.
- `Get-AiKnownFailureEvidence -Fingerprint -KnownFingerprints -Result` — the
  matched prior fingerprints, recurrence type, same-route / same-context flags.
- `Test-AiRepeatAttemptAllowed -Evidence -ProposedProviderId -ProposedModelId
  -ProposedReasoningLevel -ProposedContextHash -MaxRepeatsBeforeSuppress` —
  `RETRY_ALLOWED_*` vs `RETRY_SUPPRESSED_KNOWN_FAILURE`.
- `Get-AiAttemptPermission` — combined budget + known-failure + DB-M20 decision.

### Recurrence typing

- no signature match → `FIRST_OCCURRENCE`
- match + verified SUCCESS now → `KNOWN_FAILURE_RESOLVED`
- match + same (provider, model, reasoning) → `REPEATED_SAME_ROUTE`
- match + same (provider, model), reasoning higher → `REPEATED_AFTER_REASONING_ESCALATION`
- match + same (provider, model), reasoning otherwise different → `REPEATED_SAME_MODEL`
- match + different model → `REPEATED_AFTER_MODEL_SWITCH`
- fallback → `REPEATED_SAME_FAILURE`

### Retry suppression matrix

Suppression (`RETRY_SUPPRESSED_KNOWN_FAILURE`) requires: matched
`REPEATED_SAME_ROUTE`, **known-same context** (`ContextHash` present and equal),
and `OccurrenceCount > MaxRepeatsBeforeSuppress`. A changed context hash, a
reasoning escalation, or a model switch are meaningful changes →
`RETRY_ALLOWED_*` (the DB-M20 layer decides the escalation).

## 5. Combined attempt permission (`Get-AiAttemptPermission`)

Outcomes: `ALLOW_ATTEMPT` · `ALLOW_WITH_BUDGET_WARNING` · `BLOCK_BUDGET` ·
`BLOCK_KNOWN_FAILURE_REPEAT` · `REQUIRE_HUMAN_OVERRIDE` ·
`REQUIRE_ESCALATION_REPLAN`.

Precedence (deterministic):
1. **DB-M20 terminal / human / AUTO** (`STOP_*`, `HUMAN_*`,
   `AUTO_EXECUTION_PROHIBITED`) → `REQUIRE_ESCALATION_REPLAN` (never an AI
   attempt; `STOP_GOVERNANCE` and `HUMAN_GIT_ACTION_REQUIRED` never
   budget-evaluate into a retry).
2. **Known-failure suppression** → `BLOCK_KNOWN_FAILURE_REPEAT` when DB-M20 was
   about to repeat the identical route, else `REQUIRE_ESCALATION_REPLAN` (a
   budget override does **not** permit an identical repeat).
3. **Budget** → `BLOCK_BUDGET` / `REQUIRE_HUMAN_OVERRIDE`.
4. **Budget warning** → `ALLOW_WITH_BUDGET_WARNING`.
5. else `ALLOW_ATTEMPT`.

`PERSISTENT_IMPLEMENTATION_FAILURE` is emitted as an evidence signal when the
same implementation failure recurs; it authorises nothing on the roadmap.

## 6. Temporary DevBridge boundary

DB-M21 Part B computes in memory; it writes nothing, executes nothing, carries
no Nexus assembly reference and no runtime execution lever. It consumes DB-M20
vocabularies and decisions read-only.

## 7. Operations

`New-AiFailureFingerprint` · `Compare-AiFailureFingerprint` ·
`Get-AiKnownFailureEvidence` · `Test-AiRepeatAttemptAllowed` ·
`Get-AiAttemptPermission`.
