# SCOPE CHANGE PREFLIGHT — WI-07-0.2.4 / CHG-20260830-017

**Result:** `SCOPE_CHANGE_CLEAR`
**Date:** 2026-08-31
**Type:** READ-ONLY governance preflight. No workbook, Nexus source, Core implementation, or Active Change was modified.

---

## 1. PART 1 — Fresh authoritative governance read

Source: `NEXUS_DEVELOPMENT_CONTROL.xlsx` (read-only via the temporary verification harness `governance-dump` mode; `GOVERNANCE-HASH-UNCHANGED: True`).

| Check | Verdict | Evidence |
|---|---|---|
| 1. WI-07-0.2.4 exists/current | OK | Master Roadmap row present; Name "Concurrency, locking and atomic writes"; Status Planned; Priority Critical; Gate GATE_A; Dependencies WI-07-0.2.3. |
| 2. CHG-20260830-017 exists exactly once | OK | Exactly one Active Changes row. |
| 3. Change remains Open | OK | Status "Open — reserved via DB-M04 governed reservation; implementation pending CHATGPT handoff". |
| 4. Reservation reflects original Core-only scope | OK | Repositories `Nexus.Developer`; Projects `Nexus.Developer.Core`; Files/Globs `src/Nexus.Developer.Core/DevelopmentControl/**`. |
| 5. No new conflicting Active Change | OK | No OPEN change owns `src/Nexus.Developer.Core/DevelopmentControl/**` or `src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs`. CHG-20260830-016 (the prior WI-07-0.2.3 owner of `DevelopmentControl/**`) is Completed. |
| 6. Dependency WI-07-0.2.3 Complete | OK | Roadmap WI-07-0.2.3 Status Complete; CHG-016 Completed (DB-M10 multi-sheet completion applied). |
| 7. No new blocking Open Decision | OK | No Decisions sheet; no OPEN Decision-type change; CHG-017 ADR ID blank. |
| 8. No new blocking Audit Finding | OK | AF-001..AF-018 reviewed; none target Nexus.Developer DevelopmentControl. AF-012 (bootstrap, In Progress) is related but not blocking this change. |
| 9. Applicable ADRs unchanged | OK | No ADR document set in repo; referenced ADR-005 cited unchanged in prior changes. |
| 10. Workbook mappings valid | OK | All three tracked sheets (Master Roadmap, Active Changes, Audit Findings) read via the known schema mappings. |

Governance is materially unchanged → **not** `SCOPE_PREFLIGHT_STALE`.

## 2. PART 2 — Current Core implementation (read-only, preserved)

9 files delivered under `src/Nexus.Developer.Core/DevelopmentControl/**`:

- `DevelopmentControlConcurrencyOutcome.cs` — SUCCESS / CONCURRENCY_CONFLICT / LOCK_TIMEOUT / VALIDATION_FAILURE / NOT_FOUND / INVALID_REQUEST / IO_FAILURE.
- `DevelopmentControlMutexIdentity.cs` — deterministic SHA-256 named-object identity, path-normalized, no machine path embedded.
- `DevelopmentControlWriteLock.cs` — `DevelopmentControlLockOutcome`, `DevelopmentControlLockAttempt`, `IDevelopmentControlWriteLock`.
- `IDevelopmentControlWriteLockFactory.cs` — bounded acquire abstraction.
- `NamedDevelopmentControlMutex.cs` / `SemaphoreDevelopmentControlWriteLock.cs` — named cross-process primitives + factories (abandoned-mutex recovery; any-thread-release variant).
- `AtomicWriteResult.cs` — `AtomicWriteResult<T>`, `AtomicWriteRequest<T>`, `IDevelopmentControlAtomicWriteCoordinator`.
- `DevelopmentControlAtomicWriteCoordinator.cs` — acquire → verify RowVersion → work unit → controlled result.
- `ConcurrencyGuardedDevelopmentControlStore.cs` — 22-op `IDevelopmentControlStore` decorator; mutations under the mutex with pre-write persisted-state verification; `ExecuteAtomicWriteAsync<T>`.

Integration expectation placed on the adapter: the work unit (`AtomicWriteRequest<T>.WorkUnit`, `Func<IDevelopmentControlStore, Task<MutationResult<T>>>`) is invoked against the store; today each store op performs its own open → temp-write → validate → promote cycle. For a multi-op work unit to be one atomic save, the adapter must accept the work unit and save once.

**Coherent, preserve-worthy. No redesign required.**

## 3. PART 3 — Infrastructure inspection (read-only)

`src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs` (1502 lines):

1. **Mutation pipeline:** each public mutation = `RunMutation<T>(Func<IXLWorkbook, MutationResult<T>> mutate, ct)` — one `Open` (schema-gated) → one mutate delegate over `WorkbookSnapshot` → `SaveToTemp` + `CommitTemp` **only when `result.Success`**.
2. **Open / SaveToTemp / CommitTemp:** `Open` = `XLWorkbook(path)` + `WorkbookSchemaValidator.Validate`; `SaveToTemp` = same-dir `Path.GetRandomFileName()+".xlsx"` + `SaveAs`; `CommitTemp` = `File.Move(temp, path, overwrite:true)`.
3. **Optimistic check:** `ApplyNodeMutation` — `current is not null && ExpectedRowVersion != current.RowVersion` → `Conflict` with the current node as details. Envelope validation precedes it.
4. **Version History:** appended by `ApplyNodeWrite` via `snap.Versions.For(...)` + `AppendVersionHistory` (single mutation closure).
5. **Activity Log:** `AppendActivityLog(snap, BuildActivityEntry(...))`.
6. **Multi-op per in-memory workbook:** currently NOT possible — one mutation per save; `RunMutation` is single-delegate.
7. **Minimum change enabling Core atomic work-unit execution:** add a batch entry on `ExcelDevelopmentControlStore` that (a) opens ONE workbook, (b) pre-verifies RowVersion against the snapshot, (c) runs the work unit against a private in-memory `IDevelopmentControlStore` facade bound to the `WorkbookSnapshot` (reusing `ApplyNodeMutation` / `ApplyNodeWrite` / `AppendVersionHistory` / `AppendActivityLog` / `WriteActiveChangeRow`), and (d) performs ONE `SaveToTemp` → `CommitTemp` when the final result is Success. No change to CellCodec/ColumnMap/SchemaValidator/SchemaReport/ActivityLogMigration.

## 4. PART 4 — Minimum-scope principle

**Approved added scope is a single file:** `src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs`. No widening to the whole Infrastructure project or `DevelopmentControl/**`. The Core side of the integration (a new `IDevelopmentControlAtomicWorkUnitRunner` contract + a routing tweak in the coordinator/guard) is already inside the ORIGINAL Core scope.

## 5. PART 5 — Architecture check

- Core defines concurrency/work-unit contracts (incl. the new batch-runner interface). Infrastructure implements actual workbook/filesystem composition.
- Core does not depend on Infrastructure (boundary guard + `DevelopmentControlZeroIoTests` keep Core free of ClosedXML/persistence). The adapter implements the Core-defined interface and consumes Core types (`AtomicWriteRequest<T>`) — allowed direction.
- No circular dependency. No ClosedXML introduced into Core. No workbook-specific vocabulary leaked into Core abstractions (the runner contract is purely "run a work unit as one atomic save").
- **ARCHITECTURE_CONFLICT not triggered.**

## 6. PART 6 — Existing asset reuse

The expansion EXTENDS `ExcelDevelopmentControlStore` and reuses `DevelopmentControlCellCodec`, `ExcelWorkbookColumnMap`, `WorkbookSchemaValidator`, `WorkbookSchemaReport`, `ActivityLogMigration`, and the ClosedXML integration. No second store, no second atomic-save engine, no alternative spreadsheet library.

## 7. PART 7 — Acceptance-criteria necessity

Infrastructure integration is **genuinely required**, not a desirable refactor:

- Criterion 1 (atomic multi-op foundation) and criterion 4 (perform mutation/work unit → temp write → validate → atomic promote): a multi-op work unit executed today performs N independent single-op temp-write/promote cycles; a failure after op 1 leaves op 1 committed — not an atomic multi-op write. All-or-nothing across N ops requires the adapter's one-save batch entry.
- The Core-only implementation fully satisfies single-op atomicity and multi-op coordination (mutex + RowVersion verification, verified 44/44 harness checks) but cannot make a multi-op work unit all-or-nothing — a persistence-layer capability Core must not perform.

**Expansion approved as the minimum scope.**

## 8. PART 8 — Active Change collision analysis (expanded scope)

| Axis | Result |
|---|---|
| Node overlap | None new — CHG-017 already owns WI-07-0.2.4 / M-07-0.2 / the WI-07-0.2.x family. |
| Repository overlap | Nexus.Developer — CHG-017's own repository; prior Nexus.Developer changes Completed. |
| Project overlap | `Nexus.Developer.Infrastructure` had no OPEN owner; CHG-016 (prior owner of `DevelopmentControl/**`) is Completed. |
| File overlap | `ExcelDevelopmentControlStore.cs` — no OPEN change's Files/Globs includes it. |
| Schema overlap | None (no schema/DbContext/workbook change in this scope). |
| Contract/API overlap | `IDevelopmentControlStore` (22 ops) unchanged; added Core runner interface is new; no other change claims it. |
| Affected-node overlap | CHG-017's Affected Nodes already cover the family; nothing added. |
| Parallel safety | CHG-017 is the only Open change. |

**Untracked prior-cycle file:** `ExcelDevelopmentControlStore.cs` is a WI-07-0.2.3 deliverable, currently UNTRACKED. Because the file has no git baseline, DB-M06 must (a) record a SHA-256 of the file at correction start and compare it to the WI-07-0.2.3 baseline hash (proving prior-cycle content is intact), and (b) assert the new delta is ONLY the batch entry + in-memory facade additions, with the existing 0.2.3 behaviors preserved (199/199 tests + harness still green). Modifying it under CHG-20260830-017 is permissible — the prior reservation is released (CHG-016 Completed) and the scope expansion formally transfers this one file.

## 9. PART 9 — Parallel lane collision

Lane B lanes (DB-M13/14/15/16/17/M18/M24, AI-routing, UI) live under `C:\Personal\DevTools\DevBridge` and do not own Nexus.Developer source. The proposed file is under `C:\Personal\Nexus.Developer\src\Nexus.Developer.Infrastructure\...` — no M18/M24/AI-routing/UI lane owns it.

**PARALLEL_SCOPE_CHECK = PASS**

## 10. PART 10 — Proposed revised scope

- **Repository:** `Nexus.Developer`
- **Projects:** `Nexus.Developer.Core` (original) + `Nexus.Developer.Infrastructure` (added)
- **Original scope (unchanged):** `src/Nexus.Developer.Core/DevelopmentControl/**` — the 9 delivered files; may gain the new `IDevelopmentControlAtomicWorkUnitRunner` and the coordinator/guard routing tweak as in-scope correction.
- **ADDED scope:** `src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs` (single file).
- **Contracts/APIs:** `IDevelopmentControlStore` (unchanged, 22 ops); existing Core concurrency/work-unit contracts; new `IDevelopmentControlAtomicWorkUnitRunner`; minimum adapter batch entry.

## 11. PART 11 — Keep existing implementation

Existing Core implementation remains current task work — NOT discarded/reimplemented. The correction prompt modifies only what is necessary: add the runner contract + routing tweak (in-scope Core), add the adapter batch entry (added Infrastructure file).

## 12. PART 12 — Preflight result

`SCOPE_CHANGE_CLEAR`

The task may safely continue after the authoritative Active Changes reservation is formally amended. This preflight does NOT itself amend the workbook or the reservation.

## 13. PART 13 — Outputs

- `tasks/SCOPE_CHANGE_PREFLIGHT.md` (this file)
- `state/scope-change-preflight.json`
- Preserved under `logs/tasks/WI-07-0.2.4/CHG-20260830-017/` (alongside existing `reservation.json`, `START_BASELINE.md`, `CHATGPT_HANDOFF.md` — none modified).

## 14. PART 14 — DevBridge state

Lifecycle state unchanged. Current task remains **IMPLEMENTATION BLOCKED / SCOPE CHANGE REQUIRED**. No RESERVED reset, no implementation PASS, no advance to DB-M06.

---

## FINAL OUTPUT

**SCOPE CHANGE PREFLIGHT RESULT**

- **Node:** WI-07-0.2.4
- **Task:** Concurrency, locking and atomic writes
- **Change ID:** CHG-20260830-017
- **Current implementation:** BLOCKED — SCOPE_CHANGE_REQUIRED
- **Original scope:** `Nexus.Developer` / `Nexus.Developer.Core` / `src/Nexus.Developer.Core/DevelopmentControl/**`
- **Proposed added scope:** `Nexus.Developer.Infrastructure` / `src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs` (single file, minimum)
- **Minimum Infrastructure files required:** 1 — `ExcelDevelopmentControlStore.cs` (batch/multi-op single-save entry + in-memory snapshot-bound facade; all other adapter assets reused unchanged)
- **Architecture:** PASS (Core defines contracts; Infrastructure implements workbook composition; no circular dependency; no ClosedXML into Core)
- **Dependencies:** PASS (WI-07-0.2.3 Complete; CHG-016 Completed; CHG-017 Open)
- **Active Change conflicts:** NONE (CHG-017 is the only Open change; no owner of the proposed file)
- **Parallel lane conflicts:** NONE (PARALLEL_SCOPE_CHECK = PASS)
- **Existing Core implementation preserved:** YES
- **Infrastructure change genuinely required:** YES (atomic multi-op writes are all-or-nothing — criterion 1 / criterion 4)
- **RESULT:** SCOPE_CHANGE_CLEAR

**If SCOPE_CHANGE_CLEAR — exact revised scope:**

- **Repository:** `Nexus.Developer`
- **Projects:** `Nexus.Developer.Core` (original) + `Nexus.Developer.Infrastructure` (added)
- **Files/Globs:**
  - Original (unchanged): `src/Nexus.Developer.Core/DevelopmentControl/**`
  - ADDED: `src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs`
- **Contracts/APIs:** `IDevelopmentControlStore` (unchanged); existing Core concurrency/work-unit contracts; new `IDevelopmentControlAtomicWorkUnitRunner`; minimum adapter batch entry.

- **Workbook modified:** NO
- **Nexus source modified:** NO
- **Next Allowed Action:** AMEND_ACTIVE_CHANGE_SCOPE

Do NOT amend the reservation. Do NOT modify Nexus source. Do NOT run DB-M06.

**Stop.**
