# DB-M18 — Task Classification + Context Package Foundation

**Milestone:** DB-M18 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

DB-M18 is the **provider-independent** layer that turns a governed DevBridge task into the four
inputs DB-M19 routing will consume:

1. **TaskClassification v1** — deterministic task-type, complexity, risk, capability, reasoning and
   context-requirement classification (this document).
2. **CapabilityRequirement v1** — reusing the frozen DB-M14 contract, derived from the classification.
3. **ContextBudget v1** — a plan of which context sections fit an input-token budget and how to reduce.
4. **ContextPackage v1** — the smallest authoritative, sanitized, hash-stable package.

This document covers classification and capability requirements. Companion:
`DB-M18_CONTEXT_PACKAGING.md` covers the budget and the package.

**NO AI, NO MODEL SELECTION, NO COST.** DB-M18 selects **no winning model**, makes **zero AI API
calls**, and performs **no pricing math** (cost is DB-M16 territory). Classification is
**deterministic-first**: every value is either read from governed metadata, derived by a fixed rule,
or left **UNKNOWN** (`null`) — never invented.

---

## 1. Hard constraints honored

| Constraint | Status |
|---|---|
| No provider name in classification logic (ADR-005) | **YES** — vocabulary and rules are provider-neutral; no DeepSeek/Claude/OpenAI/Gemini in any derivation |
| No model selection | **YES** — the classifier outputs `ExecutionMode`, capability flags, and a **manual** requirement; never a chosen model |
| No AI execution / no provider API calls | **YES** — test S28 proves no network/pricing/routing tokens in the libraries |
| No pricing calculation | **YES** — DB-M15/DB-M16 own pricing; DB-M18 stores no cost fields |
| DB-M14 shared contracts unchanged | **YES** — `AiRoutingContracts.ps1` read-only; `CapabilityRequirement` stays DB-M14 v1 (`New-AiCapabilityRequirement` reused; DB-M18 adds a **derivation** helper) |
| DB-M16 cost / FX files untouched | **YES** |
| DB-M17 attempt/history files untouched | **YES** — read-only integration references only (`AiAttemptRecord` shape consumed, never written) |
| DB-M12 / DB-M12.1 UI files untouched | **YES** — no `src/DevBridge.*` file read-write |
| `NEXUS_DEVELOPMENT_CONTROL.xlsx` / Nexus repos | **UNTOUCHED** |
| Manual workflow (ChatGPT → DeepSeek → DevBridge verification → Claude) | **PRESERVED** — the package is a handoff artifact; it does not replace DB-M05/DB-M07 |
| Secrets packaged | **NO** — secret guard + redaction in the packaging layer (see companion doc) |
| Schema freeze | **YES** — TaskClassification v1 frozen here; CapabilityRequirement remains DB-M14 v1; incompatible change requires v2 |

## 2. What DB-M18 classification provides

`Classify-DevBridgeTask` reads a governed task (the `state/current-task.json` shape or an equivalent
PSCustomObject) and returns a **TaskClassification v1**. Every classification is accompanied by
**evidence** — the exact signal (or governed field) each value came from — so a downstream operator or
DB-M19 can trace the reasoning without any model involved.

```powershell
$c = Classify-DevBridgeTask -Task $task -ClassifiedAtUtc '2026-08-30T00:00:00Z'
$c.TaskType          # IMPLEMENTATION / PLANNING / RESEARCH / VERIFICATION / REVIEW / GOVERNANCE
$c.Complexity        # LOW / MEDIUM / HIGH
$c.Risk              # LOW / MEDIUM / HIGH / $null (UNKNOWN)
$c.MinimumReasoningLevel  # NONE / MEDIUM / HIGH (DB-M14 ReasoningLevels vocabulary)
$c.ContextRequirement     # LOW / MEDIUM / HIGH / VERY_HIGH
$c.Evidence.Signals  # the ordered signal list that produced the classification
```

## 3. Input: the governed DevBridge task shape

The classifier consumes the governed task as an object with these optional properties (any may be
absent → UNKNOWN):

| Property | Meaning |
|---|---|
| `taskId`, `nodeId`, `changeId`, `workItemId`, `milestoneId` | Task identity |
| `name`, `goal`, `acceptanceCriteria` | Free text scanned for stage/scope keywords |
| `nodeType`, `phase`, `status` | Governed lifecycle fields |
| `preflightVerdict` | `CLEAR`/`FAIL`/…, used for risk derivation |
| `repositories`, `projects`, `filesGlobs` | Code scope |
| `contractsApis`, `schemaContexts` | Contract/schema scope |
| `affectedNodes` | Breadth signal |
| `blockingReasons`, `activeChangeConflicts` | Blocker / conflict evidence |
| `architectureDecisions` | ADRs; **GOVERNS_SUBSTRATE / GOVERNS / CONSTRAINS / conflict** relations govern the chain |
| `auditFindings` | Constraining findings that name an affected node |
| `risk` | Governed risk field — **preserved verbatim when present** |
| `sourceReferences`, `history`, … | Optional context (used by the packaging layer) |

`Get-DbM18TaskFromState` loads a task from `state/current-task.json` when present.

## 4. TaskClassification v1 — schema

`schemaVersion: 1`, frozen at DB-M18. `ClassificationSource = 'DETERMINISTIC'`; unknown values stay
`null` (never `""`). Registered by `Get-DbM18SchemaVersions` in the DB-M18 library (not in DB-M14's
registry — parallel-safe).

| Group | Fields |
|---|---|
| Schema | `SchemaVersion` (1) |
| Identity | `ClassificationId`, `TaskId`, `NodeId`, `ChangeId`, `WorkItemId`, `MilestoneId`, `ClassifiedAtUtc` |
| Source | `ClassificationSource` (`DETERMINISTIC`), `ClassifierVersion` |
| Core | `TaskType`, `Complexity`, `Risk` |
| Capability | `RequiresCoding`, `RequiresReasoning`, `RequiresVision`, `RequiresToolUse`, `RequiresStructuredOutput` |
| Reasoning | `MinimumReasoningLevel`, `ReasoningRuleApplied`, `ReasoningRule` |
| Context | `ContextRequirement`, `RequiredContextTokens` (approximate, labeled), `ExpectedOutputTokens` (approximate) |
| Policy | `LatencyPreference` (`NORMAL` — DB-M14 RelativeSpeeds member), `ExecutionMode` (`MANUAL` default), `HumanReviewRequired` |
| Scope snapshot | `ReservedScope` (identity + repos/projects/globs/schemas/contracts/affected-nodes/governing-ADRs) |
| Evidence | `Evidence` → `TaskTypeEvidence`, `ComplexityEvidence`, `RiskEvidence`, `ReasoningEvidence`, `Signals[]` |

## 5. Task-type vocabulary and ordered rules

`TaskType` is one of the frozen DB-M14 TaskTypes: **PLANNING / IMPLEMENTATION / VERIFICATION /
REVIEW / RESEARCH / GOVERNANCE**. The classifier scans `name + goal + acceptanceCriteria +
selection + nodeType + status` (lowercased) for stage keywords, **first match wins**:

| Order | Rule | Result |
|---|---|---|
| 1 | verification/validate/test-run keyword | VERIFICATION |
| 2 | review/audit/inspection keyword | REVIEW |
| 3 | architecture/planning/roadmap/design-doc keyword | PLANNING |
| 4 | governance/process/policy/protocol/standards keyword | GOVERNANCE |
| 5 | documentation-only (doc keyword AND **no code scope**) | RESEARCH |
| 6 | research/summarize keyword **without** code scope | RESEARCH |
| 7 | code/implementation scope (keyword **or** governed code scope) | IMPLEMENTATION |
| 8 | research keyword (with code scope present) | RESEARCH |
| 9 | no stage keyword matched | IMPLEMENTATION (default) |

S1 exercises all eight behaviours, including the governed-scope override (a "small UI form" with a
code scope → IMPLEMENTATION, not RESEARCH).

## 6. Complexity — LOW base, additive governed signals

`Complexity` starts `LOW` and rises via fixed rules; an explicit small/simple/minor keyword can revert
it to LOW when no schema is present and scope is single-repo:

- code scope present → MEDIUM
- contract API in scope → MEDIUM
- more than 2 affected nodes → MEDIUM
- schema context (or schema/migration/database keyword) → **HIGH**
- multi-repository scope (or `SigMultiRepo`) → **HIGH**
- GOVERNANCE task → HIGH
- architecture task classified PLANNING → HIGH

S2 locks LOW (simple change), MEDIUM (normal coding with a contract), and HIGH (schema; multi-repo).

## 7. Risk — governed field preserved verbatim; derived only when absent

- A governed `risk` field in `LOW/MEDIUM/HIGH` is **preserved verbatim** (S3) — never re-derived.
- A governed value outside the vocabulary → left **UNKNOWN** (a value outside LOW/MEDIUM/HIGH is never
  invented into a mapping).
- When absent, `Get-DbM18RiskFromEvidence` derives from preflight evidence only:
  - verdict `FAIL/BLOCKED/ERROR` → HIGH
  - any explicit blocker → HIGH
  - a conflict whose status is `FAIL/BLOCKED/ERROR` → HIGH; `WARN` → MEDIUM
- No evidence → risk stays **UNKNOWN** (`null`), honestly (S3 "no risk signal").

## 8. Capability requirements (deterministic booleans)

Unknown stays `$null`; each is set **only** by a fixed rule:

| Flag | Set to `true` when |
|---|---|
| `RequiresCoding` | governed code scope present; `false` for documentation-only |
| `RequiresReasoning` | risk/complexity MEDIUM–HIGH, or a PLANNING/GOVERNANCE/VERIFICATION/REVIEW/RESEARCH task |
| `RequiresVision` | task text references a UI surface (form/dashboard/screen/dialog…) — no signal → `null` |
| `RequiresToolUse` | code scope, or PLANNING/GOVERNANCE |
| `RequiresStructuredOutput` | contract API or schema context in scope |
| `HumanReviewRequired` | code scope, or GOVERNANCE/PLANNING/VERIFICATION/REVIEW |

S4 verifies each flag, including the `null` cases (no UI signal → `RequiresVision null`; no code
scope → `RequiresCoding null`).

## 9. MinimumReasoningLevel + ReasoningRuleApplied (DB-M13 rule)

The DB-M13 §2.1 rule is encoded literally: **HIGH risk or HIGH complexity (or schema scope) requires
at least HIGH reasoning**, recorded with `ReasoningRuleApplied = $true` and the applied rule text:

- HIGH risk / HIGH complexity / schema → `MinimumReasoningLevel = HIGH`, `ReasoningRuleApplied = true`
- PLANNING / GOVERNANCE → HIGH, applied
- MEDIUM risk / MEDIUM complexity → MEDIUM (default, not a hard rule)
- reasoning-required default → MEDIUM
- otherwise → `NONE`

S5 locks the HIGH cases (schema, HIGH risk) as rule-applied and the MEDIUM cases as defaults. The
governed WI-07-0.2.4 fixture lands on **MEDIUM with `ReasoningRuleApplied = false`** (MEDIUM
complexity, LOW risk — the default path).

## 10. ContextRequirement — weighted signal score

A deterministic score counts evidence, then maps to a level:

| Score | Level |
|---|---|
| ≥ 5 | VERY_HIGH |
| ≥ 3 | HIGH |
| ≥ 2 | MEDIUM |
| else | LOW |

One point each for: contract in scope · more than 2 affected nodes · code scope · schema context ·
multi-repository · governing ADR · constraining audit finding naming an affected node. The governed
fixture (contract + affected + code scope + governing ADR = **4**) → **HIGH**.

## 11. Token planning — approximate, labeled

`RequiredContextTokens` and `ExpectedOutputTokens` are **approximations**, explicitly labeled, using
one consistent method (`Get-EstimatedTokenCount`, **chars / 4** — see the packaging doc).

- `RequiredContextTokens` — estimated from the identity + goal + acceptance criteria + scope text.
- `ExpectedOutputTokens` — `2048` (default), `1024` for VERIFICATION/REVIEW, `512` for
  RESEARCH/PLANNING/GOVERNANCE.

These are planning numbers for DB-M19, never provider billing.

## 12. CapabilityRequirement v1 — DB-M14 contract reused

`New-CapabilityRequirement` (DB-M18-owned derivation helper) produces a **DB-M14 v1**
`AiCapabilityRequirement` from the classification — the same contract DB-M14 already validates with
`Test-AiCapabilityRequirement`. No DB-M14 file is modified. S26 proves:

- `SchemaVersion` stays 1 (DB-M14 v1), `TaskType`/`Complexity` carried in,
- `ExecutionMode` is `MANUAL`,
- `AllowedProviders` / `AllowedModels` stay **empty** (no provider or model selection — that is
  DB-M19),
- `MaxAllowedCost` stays `null` (cost is DB-M16 territory),
- `PreferredLatency` is a DB-M14 `RelativeSpeeds` member (`NORMAL`),
- an UNKNOWN-heavy classification still yields a valid requirement (unknown `Risk` stays `null`).

## 13. Deterministic-first / UNKNOWN semantics

- Every classification value is a governed read, a fixed rule, or `null` — never an invented value.
- Absent metadata → `null`, never `""`, never a made-up default. S15 verifies unknown fields stay
  `null` through round-trips.
- Evidence is recorded so a human can replay the decision by hand.

## 14. Provider-name independence (ADR-005)

The classification vocabulary (task types, reasoning levels, relative speeds, execution modes) is
entirely provider-neutral. No DeepSeek/Claude/OpenAI/Gemini name appears in any derivation rule. S16
scans the libraries for provider names and proves independence. (Header comments documenting the
prohibition are the only permitted mention.)

## 15. No model selection / no AI execution

The classifier never returns a model, never calls an API, never prices, never routes. S17 proves the
classification carries no model selection; S28 scans the libraries for network, pricing, routing, and
attempt-record tokens and finds none.

## 16. Manual-workflow compatibility

`ExecutionMode` defaults `MANUAL`, matching the active DB-M14 runtime policy and the existing manual
loop. The classification + package are **handoff artifacts** for the CHATGPT / DeepSeek / Claude loop
that DB-M05/DB-M07 already govern — DB-M18 does not drive, replace, or short-circuit it.

## 17. Schema versioning (v1 freeze)

- `Get-DbM18SchemaVersions` → `@{ TaskClassificationVersion = 1; ContextBudgetVersion = 1; ContextPackageVersion = 1 }`.
  Registered in the DB-M18 library, not in DB-M14's registry (parallel-safe).
- **TaskClassification v1 frozen at DB-M18**; `CapabilityRequirement` remains **DB-M14 v1**.
- Additive optional fields are allowed within v1; any incompatible change (rename, retype, removed
  field, changed vocabulary meaning) requires a **v2** contract with its own schemaVersion and
  validator, per the DB-M14 freeze rules. S14 round-trips schema v1 with nulls preserved.

## 18. Validation

`Test-TaskClassification` returns `@{ Valid; Errors; Warnings }` and validates the classification
shape: schema version, required identity, TaskType/Complexity/Risk/ReasoningLevel/ContextRequirement
vocabulary membership, non-negative token estimates, ExecutionMode membership, and
ClassificationSource. A classification carrying a provider or a selected model fails validation.

## 19. Parallel-safety

DB-M18 wrote **only** DB-M18-owned additive files: `scripts/ai-routing/TaskClassification.ps1`,
`scripts/ai-routing/ContextPackage.ps1`, `scripts/ai-routing/Test-DbM18Classification.ps1`, this
document + `DB-M18_CONTEXT_PACKAGING.md`, and `state/db-m18-result.json`. It read (never modified)
the DB-M14 contracts, DB-M16 files, DB-M17 files, DB-M12 UI sources, the workbook, and Nexus
repositories. `AiRoutingContracts.ps1` is byte-identical (S30 re-hashes it and re-runs the DB-M14
regression suite).

## 20. Tests

`Test-DbM18Classification.ps1` — **203 checks, all pass, 0 paid API calls.** S1–S30 cover the eight
classification examples, complexity/risk/reasoning derivation, capability requirements, mandatory
context preservation, optional context dropping, the token estimator, secret filtering, history
reduction, relevant-file selection, binary/generated rejection, stable package hash, schema v1
round-trips, UNKNOWN-preservation, provider-name independence, no-model-selection, the eight
context-budget scenarios, CapabilityRequirement reuse (S26), the governed WI-07-0.2.4 fixture (S27,
READ-ONLY), the no-AI/no-routing/no-pricing scan (S28), the package summary (S29), and the DB-M14
frozen-contract regression (S30).

---
*End of DB-M18 classification doc. Context budget + package: `DB-M18_CONTEXT_PACKAGING.md`.*
