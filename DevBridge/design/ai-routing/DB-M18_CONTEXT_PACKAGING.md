# DB-M18 — Context Budget + Package Foundation

**Milestone:** DB-M18 · **Lane:** B — AI ROUTING PLATFORM · **Status:** IMPLEMENTED
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31

This companion document covers the **ContextBudget v1** and **ContextPackage v1** layers of DB-M18:
how the candidate context sections of a governed task are chosen, budgeted, reduced, sanitized, and
packaged into the smallest authoritative context package DB-M19 will pass to a model. Classification
and capability requirements are in `DB-M18_TASK_CLASSIFICATION.md`.

**NO AI, NO MODEL SELECTION, NO COST.** Packaging is **deterministic reduction only** — there is no AI
summarizer, no provider call, no model choice, and no pricing math. A package is built from governed
task state (read-only) plus optionally a history summary and a file-context map; it never sends the
entire repo, workbook, or history.

---

## 1. Hard constraints honored

| Constraint | Status |
|---|---|
| Smallest authoritative context package | **YES** — 7 mandatory sections + pruned optional/low-value context; mandatory context is never dropped |
| Never drop mandatory context | **YES** — task identity, goal, acceptance criteria, reserved scope, mandatory ADR constraints, explicit blockers, required report format are always included (S6) |
| No AI summarizer | **YES** — excerpting is deterministic truncation with an explicit omission marker |
| One consistent token estimator, labeled | **YES** — `Get-EstimatedTokenCount`, **chars / 4**, `EstimatedTokens` labeled everywhere |
| Secrets never packaged | **YES** — reuses DB-M17/DB-M14 secret guards; suspicious content is excluded + a warning recorded (S9) |
| No DB-M14 / DB-M16 / DB-M17 file modified | **YES** — read-only references only |
| Workbook / Nexus repos untouched | **YES** |
| Manual workflow compatible | **YES** — package is a CHATGPT/DeepSeek/Claude handoff artifact |
| Schema freeze | **YES** — ContextBudget v1 and ContextPackage v1 frozen here |

## 2. What DB-M18 packaging provides

```powershell
$secs   = Get-DbM18ContextSections -Task $task            # candidate sections (mandatory + optional)
$budget = New-ContextBudget -TaskId $task.taskId -AllowedInputTokens 20000 -Sections $secs
$pkg    = Build-ContextPackage -Task $task -Classification $c -Budget $budget -Sections $secs
$sum    = Get-ContextPackageSummary -Package $pkg          # UI-discoverable summary
Test-ContextPackage -Package $pkg                          # structural validation
```

The pipeline is: **candidate sections → budget plan → sanitized, hash-stable package**.

## 3. Section model

`New-DbM18ContextSection` produces a candidate section: `SectionId`, `Title`, `Priority`, `ContentType`
(`TEXT` default), `Content`, `Tokens` (computed via the estimator when not supplied), `IsLargeFile`.
Priority vocabulary: **`MANDATORY | OPTIONAL | LOW_VALUE`**. Unknown priority values normalize to
`OPTIONAL` (never silently treated as mandatory).

## 4. Mandatory sections — the never-dropped set

`Get-DbM18ContextSections` always emits these seven (S6 proves each is included and its content is
preserved verbatim):

| SectionId | Content |
|---|---|
| `task_identity` | TaskId, NodeId, ChangeId, phase, nodeType, status |
| `goal` | The task's goal |
| `acceptance_criteria` | Acceptance criteria (the governed "definition of done") |
| `reserved_scope` | Exact reserved scope (repos/projects/globs/schemas/contracts/affected nodes + parallel-safety note) |
| `mandatory_adrs` | Governing ADRs (GOVERNS_SUBSTRATE / GOVERNS / CONSTRAINS relations, or any conflicting ADR) |
| `blockers` | Explicit blocking reasons |
| `report_format` | The required report format template |

A budget may **excerpt** a large mandatory file (never drop it). If mandatory context exceeds the
available budget even after excerpting, the budget is **EXCEEDS** and the package is built **FAILED**
— never silently truncated.

## 5. Optional and derived sections

| Section | Added when | Priority |
|---|---|---|
| `history` | attempt-history summary passed (from DB-M17 read-only) | LOW_VALUE |
| `source_references` | task has `sourceReferences` | LOW_VALUE |
| per-file context sections | `FileContextMap` / `FileContextRoot` provided | LOW_VALUE (per-file) |
| derived optional sections | computed from scope | OPTIONAL |

File context applies **deterministic** selection only: globs are matched against relative paths, text
files are excerpted to `ExcerptChars`, and binary/generated/large artifacts are rejected (S11/S12). No
file content is ever fetched over a network; only files already on disk under the supplied root are
considered.

## 6. ContextBudget v1 — schema

`schemaVersion: 1`. The budget is a **plan**: one row per candidate section with the decided action.

| Group | Fields |
|---|---|
| Schema / identity | `SchemaVersion`, `BudgetId` (`BUD-<TaskId>`), `TaskId`, `NodeId`, `ChangeId` |
| Budget | `AllowedInputTokens`, `ReservedOutputTokens`, `AvailableInputTokens` (= allowed − reserved) |
| Outcome | `BudgetStatus` (`FITS | REDUCED | EXCEEDS`), `Strategy`, `Failure`, `TotalTokens`, `SelectedContextTokens`, `ReductionRequired`, `ReductionPercent`, `ExcerptChars` |
| Plan | `Sections[]` — per section: `SectionId`, `Title`, `Priority`, `ContentType`, `Tokens`, `ExcerptTokens`, `IsLargeFile`, `Action` (`INCLUDE | EXCERPT | EXCLUDE`), `ExcludeReason` |

### Budget logic (deterministic)

1. **Validate** — `AllowedInputTokens > 0`, `ReservedOutputTokens ≥ 0` and `< AllowedInputTokens`,
   `available > 0` (S23).
2. **Mandatory first** — if mandatory tokens exceed available, excerpt large mandatory files. If still
   too large → **EXCEEDS** (`INSUFFICIENT_BUDGET`), every section marked `EXCLUDE`, package FAILED.
3. **Fit check** — if everything fits → **FITS**, strategy `NONE` (S24: selected = available without
   reserve; with reserve more is excluded).
4. **Reduce** — drop `LOW_VALUE` first (history/source-refs/per-file), then `OPTIONAL` if still over
   (`DROP_LOW_VALUE`, `DROP_OPTIONAL_AND_LOW_VALUE`), excerpting large mandatory files when needed.
   Mandatory is **never** excluded (S7).

The eight budget scenarios S18–S25 lock: reserve semantics, selected-never-exceeds-available, and the
EXCEEDS case selecting zero (a FAILED package, never a silent truncation).

## 7. Token estimator — one method, labeled

`Get-EstimatedTokenCount` counts **characters / 4** (ceiling), returns 0 for null/empty, and is
deterministic. Every token figure on a classification, budget, or package is an **EstimatedToken**
approximation — never a provider billing number. S8 locks the estimator (4 chars → 1, 200 chars → 50,
empty → 0, deterministic).

## 8. Build-ContextPackage — sanitize, excerpt, hash

`Build-ContextPackage` applies the budget plan to the candidate sections:

- `EXCLUDE` → `Included = $false` + `ExcludeReason` (dropped, recorded in `DroppedSectionIds`).
- `EXCERPT` → deterministic truncation to `ExcerptChars` with an explicit
  `...[excerpted: N chars omitted]...` marker — excerpts are never silent (S22).
- `INCLUDE` → content sanitized by the secret guard; a secret-like value is **excluded and replaced by
  a redaction marker**, and a warning is recorded (S9). The raw secret never reaches the package.
- Token counts are recomputed on the actual packaged content; selected tokens are summed over included
  sections.

Output is a **ContextPackage v1** (`SchemaVersion: 1`):

| Group | Fields |
|---|---|
| Schema / identity | `SchemaVersion`, `PackageId` (`PKG-<TaskId>`), `TaskId`, `NodeId`, `ChangeId`, `ClassificationId`, `BudgetId`, `GeneratedAtUtc` |
| Outcome | `Status` (`OK | FAILED`), `FailureReason`, `AllowedInputTokens`, `ReservedOutputTokens`, `SelectedContextTokens`, `EstimatedTotalTokens`, `ReductionRequired`, `ReductionPercent` |
| Content | `Sections[]` (per section: `SectionId`, `Title`, `Priority`, `ContentType`, `Content`, `Tokens`, `Included`, `ExcludeReason`) |
| Accountability | `MandatorySectionIds`, `OptionalSectionIds`, `LowValueSectionIds`, `DroppedSectionIds`, `SecretWarnings`, `PackageHash` |
| Provenance | `Origin` — "DB-M18 deterministic context packaging; sources are governed task state (read-only)" |

## 9. Stable package hash

`PackageHash` is a SHA-256 hex of the canonical payload (`Sections` in fixed order, `GeneratedAtUtc`
excluded so identical content hashes identically). S13 proves identical content → identical hash and
different content → different hash. The summary carries the same hash (S29).

## 10. Secret guard + redaction

- Reuses the DB-M17/DB-M14 secret-value guards (`Test-DbM18SecretText`, `Test-AiRoutingSecretValueLeak`).
- A secret-like value in a section → the section's content is replaced with a **redaction marker**
  (`[redacted: …secret-like content detected…]`) and a `SecretWarnings` entry is recorded. The
  suspicious content never reaches the package (S9).
- `Test-ContextPackage` re-checks packaged content and flags any leak.

## 11. Get-ContextPackageSummary

`Get-ContextPackageSummary` returns a compact, JSON-serializable summary for the DB-M12 UI: package
identity, `Status`, budget figures, `SectionCount`, `IncludedSectionCount`, `ExcludedSectionCount`,
`MandatorySectionIds`, `OptionalSectionIds`, `ReductionRequired`/`ReductionPercent`, `PackageHash`, and
a rendered markdown text form (S29).

## 12. Manual-workflow compatibility

A package is the **handoff artifact** for the existing CHATGPT → DeepSeek → DevBridge verification →
Claude loop. It is a self-contained, sanitized, hash-stable context snapshot with its provenance and
its reduction decisions recorded — usable by any of the three model-facing steps **without replacing
DB-M05 or DB-M07**. `ExecutionMode` stays `MANUAL`.

## 13. Schema versioning (v1 freeze)

- Registered by `Get-DbM18SchemaVersions` in the DB-M18 library: `ContextBudgetVersion = 1`,
  `ContextPackageVersion = 1`.
- **ContextBudget v1 and ContextPackage v1 frozen at DB-M18.** Additive optional fields are allowed
  within v1; incompatible changes require a **v2** with its own schemaVersion and validator.
- S14 round-trips both schemas and preserves `null` unknowns.

## 14. Parallel-safety

DB-M18 wrote only its own additive files (see the classification doc). The packaging layer consumes
DB-M14 contracts, DB-M16 pricing, DB-M17 attempt history, and DB-M12 UI contracts **read-only**; none
are modified. `AiRoutingContracts.ps1` is byte-identical (S30 re-hash + DB-M14 regression).

## 15. Tests

Covered by `Test-DbM18Classification.ps1` (203 checks, all pass, 0 paid API calls) — see the
classification doc's test section. The packaging-specific scenarios: S6 (mandatory preservation),
S7 (optional dropping), S8 (estimator), S9 (secret filtering), S10 (history reduced first), S11/S12
(relevant-file selection, binary/generated rejection), S13 (stable hash), S14 (schema round-trips),
S18–S25 (eight budget scenarios), S27 (governed fixture package), S29 (summary).

---
*End of DB-M18 context packaging doc. Classification: `DB-M18_TASK_CLASSIFICATION.md`.*
