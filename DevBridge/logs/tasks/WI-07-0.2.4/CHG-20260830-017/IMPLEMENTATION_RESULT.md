# WI-07-0.2.4 — Concurrency, locking and atomic writes (CHG-20260830-017)

## IMPLEMENTATION RESULT — CONTINUATION

**Result: PASS** · **Preserved: YES** (Core foundation byte-intact; only in-scope deltas applied) · **Commit created: NO**

**Repository:** `C:\Personal\Nexus.Developer` (HEAD `ea39db9`, branch `feature/m-08-1-2-ci-pipeline`, unchanged)  
**Scope:** original Core `src/Nexus.Developer.Core/DevelopmentControl/**` + ONE approved Infrastructure file `src/Nexus.Developer.Infrastructure/DevelopmentControl/ExcelDevelopmentControlStore.cs` (CHG-20260830-017 amendment ACT-20260830-019). No other Infrastructure file touched.

---

## 1. Scope compliance

- **Infrastructure file modified: YES** — only `ExcelDevelopmentControlStore.cs`.
  - PRE-EXISTING content: baseline `6160c4fea3185ec48701d2934c55d354b4780ecedd7a2b2363d4ac16ce3d9a80`, 90279 bytes (WI-07-0.2.3 / CHG-20260830-016 deliverable, untracked) — NOT newly created, NOT erased.
  - CURRENT TASK delta (the approved amendment): batch entry `ExecuteAtomicWorkUnitAsync` (IDevelopmentControlAtomicWorkUnitRunner), `RunAtomicWorkUnitCore`, `ValidateTempAndCommit`, `AtomicWritePreconditionException`, `SnapshotBoundDevelopmentControlStore` facade, `_batchWorkbook` shared-workbook field, `RunMutation` batch branch, `WithSnapshotRead` batch-aware read wrappers, `GetNodeCore` made static. Current SHA-256 `17a25a566a7e23f25586bd88ee63a40f9173ea9309e196ae63cd79ce77228657`, 104070 bytes.
- **Other Infrastructure files: NONE** — `DevelopmentControlCellCodec.cs`, `ExcelWorkbookColumnMap.cs`, `WorkbookSchemaValidator.cs`, `WorkbookSchemaReport.cs`, `ActivityLogMigration.cs` byte-identical, mtimes 2026-08-30 (pre-session). Not modified.
- **Core files:** 7/9 original files byte-identical to the amendment baselines (foundation preserved). Exactly 2 modified (routing to the runner): `DevelopmentControlAtomicWriteCoordinator.cs`, `ConcurrencyGuardedDevelopmentControlStore.cs`. Exactly 1 created (in-scope Core correction): `IDevelopmentControlAtomicWorkUnitRunner.cs`.
- **Scope compliance = YES.** `git status --short` shows only pre-existing untracked Core/Infra deliverables + the pre-existing workbook `M` (the amendment's own write, hash `f520060c…` stable across this implementation). No DevBridge files touched. No parallel-lane overlap.

## 2. Build and existing suite

- Build: `dotnet build Nexus.Developer.slnx -c Debug` → **0 Warnings, 0 Errors**.
- Existing tests: `dotnet test tests/Nexus.Developer.Core.Tests` → **199 passed, 0 failed, 0 skipped**.
- Concurrency harness (`%TEMP%\NexusWi07_024_Harness`, outside the repository): **62/62 PASS** — 47 prior checks (A1–S2, incl. C1–C6 cross-process mutex, D10 two-writer race, E1–E8 coordinator/guard mappings now routing through the runner) + **15 new G checks**.
- Canonical workbook SHA-256 before: `f520060cb753ec8ec96b44bcbd193bdab69ca68d4cc27198663665d5fe63f884` → after: identical. **Unchanged.**

## 3. Multi-operation integration (G group)

| Check | Proof |
|---|---|
| G1 create inside a work unit | SUCCESS, RowVersion 1 |
| G2 two-op work unit commits | SUCCESS, final persisted RowVersion advanced by exactly 2 |
| G3 Version History append-only | exactly 2 records appended; prior records preserved; only the previously-current record's Is-Current flips Yes→No (ADR-003) |
| G4 Activity Log append-only | exactly 2 rows appended; prior rows byte-identical (ADR-003) |
| G5 second-op failure inside the unit | whole unit CONCURRENCY_CONFLICT (controlled, not an exception) |
| G6 failure atomicity | canonical temp workbook byte-identical (op1 NOT persisted, no CommitTemp) |
| G7 failed unit appended ZERO VH/AL rows | op1 in-memory evidence discarded |
| G8/G9 race through the runner | writer A (fresh) SUCCESS N→N+1; writer B (stale) CONCURRENCY_CONFLICT carrying current node (N+1) |
| G10/G11 | B's conflict changed nothing; B did NOT overwrite A (final state is A's) |
| G12/G13 runner direct pre-verify | adapter's OWN RowVersion pre-check (bypassing the coordinator) → controlled CONCURRENCY_CONFLICT, no save |
| G14 single-op work unit | SUCCESS, RowVersion +1 (WI-07-0.2.3 single-mutation behavior intact) |
| G15 one save | no leftover temp-save artifacts after every unit (ONE temp-write → validate → atomic-replace per save) |

## 4. Integration summary

The already-built Core concurrency/work-unit foundation is preserved and now integrated end-to-end:

- **Locking composition (Infrastructure → Core only):** Core owns named cross-process writer lock (`DevelopmentControlMutexIdentity` / `NamedDevelopmentControlMutex`), bounded timeout, lock-outcome mapping, coordinator/guard control flow, and the generic RowVersion precondition. Infrastructure owns actual workbook mutation, ClosedXML, temp-save, schema re-validation, and atomic `File.Move` promotion. No Core → Infrastructure dependency.
- **Atomic work unit (all-or-nothing):** `ExecuteAtomicWorkUnitAsync` opens the workbook ONCE (schema gate), pre-verifies `ExpectedRowVersion` against the opened persisted state under the held lock, runs every store operation the work unit calls against the SAME in-memory workbook (mutations append Version History / Activity Log to shared live sheets; reads re-snapshot the live sheets so later ops see prior in-memory writes), and only when the whole unit succeeded saves ONCE to a temp file, re-opens + validates it through `WorkbookSchemaValidator`, and atomically replaces the canonical target. Any failure (a failed op, a stale RowVersion, a structural anomaly) aborts before any temp save — the canonical workbook is never partially written.
- **RowVersion race:** Writer B acquires the lock, re-reads persisted state, observes N+1, and returns a controlled CONCURRENCY_CONFLICT carrying the current node — verified at both the coordinator verify step and the adapter's own runner pre-verify (G8–G13). B never overwrites A.
- **Append-only:** Version History remains append-only per ADR-003 (only the documented predecessor Is-Current flip); Activity Log strictly append-only. Both proven by fingerprint (G3/G4/G7).
- **No second atomic-save path, no second parser, no new spreadsheet library.** The batch entry reuses the adapter's existing `RunMutation`/`SaveToTemp`/`CommitTemp`/`WorkbookSnapshot` machinery.

## 5. Known limitations / notes

- Multi-op atomicity is provided by the new runner path. The pre-existing 22-op single-operation adapter contract is untouched (199/199 tests green; E1–E8 and D-series unchanged).
- `snap.Master.Workbook` resolves on ClosedXML 0.105.1 (build-verified).
- Harness is a TEMPORARY external verification program (outside the repo), per the TEST SCOPE RULE; no permanent in-repo test file was added, and no out-of-scope test project was modified.
- `git status` `M NEXUS_DEVELOPMENT_CONTROL.xlsx` is the scope-amendment's own write (post-amendment hash `f520060c…`, verified pre/post implementation identical) — this implementation performed no canonical write.

## 6. Governance state

- **Nexus Development Control completion state: NOT updated.** No DB-M06 run. No commit, push, merge, branch change, stash, reset, or clean.
- **Commit created: NO.**
- `state/current-task.json` untouched by this implementation (still the amendment's `READY_FOR_SCOPE_DELTA_IMPLEMENTATION` / `CONTINUE_DEEPSEEK_IMPLEMENTATION`).
- This record is a passive output preserved alongside `SCOPE_AMENDMENT_REPORT.md` / `scope-amendment.json` for DB-M06 verification.
