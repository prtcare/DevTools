# DB-M12.4 -- Governed Trial Cycle Closure and Fresh-Cycle Selection: Implementation Report

Date (UTC): 2026-08-31  |  Lane C  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency.

---

## 1. What this milestone delivered

The FINAL HARDENED LANE C TRIAL PART 1 exposed a **governance-state gap** (not an
M03 defect): M03 auto-selected `WI-07-0.2.4` / `CHG-20260830-017` again with
M03=PASS, Verdict=CLEAR, even though that trial's lifecycle had ended at
`CLAUDE_REVIEW_PASSED_TRIAL` / `TRIAL_CYCLE_SAFE_STOP` / `TRIAL_ONLY_UNMERGED`
and M10 was correctly NOT run. The trial lifecycle had a safe-stop but no
explicit terminal closure that releases the trial reservation and records a
governed closed-cycle history for fresh M03 selection to consult.

DB-M12.4 adds that capability:

- **New state**: `TRIAL_CYCLE_CLOSED`, reached via an explicit
  `TRIAL_CYCLE_SAFE_STOP -> CLOSE_TRIAL_CYCLE -> TRIAL_CYCLE_CLOSED` transition.
  `nextAllowedAction` becomes `START_NEXT_CYCLE`.
- **New backend command**: `Close-TrialCycle.ps1` (wired as `CLOSE_TRIAL_CYCLE`
  in the operator catalog). It is a governed workbook writer that:
  - proves identity from `current-task.json` (`NodeId` / `ChangeId` / optional
    `TaskIdentity`), rejecting any mismatch (`TRIAL_CYCLE_IDENTITY_MISMATCH`);
  - is **idempotent** (`TRIAL_CYCLE_ALREADY_CLOSED`, pass=true, no re-write);
  - blocks **non-safe-stop** trial states (`STOP_NOT_A_TRIAL_SAFE_STOP`) and
    **REAL mode** (`TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE`, blocked before any
    script runs via the engine gate too);
  - verifies the cycle is proving-only: `dbM08`/`dbM06` implementationState must
    be `TRIAL_ONLY_UNMERGED`, M10 must not have run, `completion.json` must not
    exist, and the git lifecycle must not be `MERGED`/`READY_FOR_GOVERNED_COMPLETION`
    (`STOP_TRIAL_HAS_REAL_LIFECYCLE` with a human governance review marker) --
    so a genuinely completed/merged change can never be "closed as a trial";
  - **restores the pre-reservation execution status** from the recorded M04
    reservation backup (backup SHA verified against the recorded evidence); if
    the exact previous state cannot be proven it stops with
    `TRIAL_PRE_RESERVATION_STATE_UNKNOWN` and **never manufactures a value**;
  - closes the trial reservation (Active Changes row -> Closed-terminal,
    **never Completed**), appends one Activity Log row, and preserves
    `TRIAL_ONLY_UNMERGED` evidence;
  - captures the protected roadmap fingerprint before and after the write
    (`STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED` on any structural drift; the
    closure plan touches only execution-state cells -- Active Changes Status,
    Activity Log rows, one Master Roadmap Status cell);
  - writes to a temp copy, verifies read-back, then atomically replaces
    (`STOP_ATOMIC_REPLACE_FAILED` if the workbook is open); a pre-closure backup
    is always produced (`STOP_BACKUP_FAILED` if not);
  - records `state/trial-closure.json`, appends `state/trial-proving-history.json`,
    and writes `tasks/TRIAL_CYCLE_CLOSURE_REPORT.md`.
- **Fresh-cycle selection**: `Get-NextTask.ps1` (DB-M03) now reads the used
  proving ids from `trial-proving-history.json` and, in TRIAL mode with a
  non-empty history, **excludes the used/closed nodes** from CURRENT WORK and
  NEXT WORK selection. REAL mode is unaffected.
- **No completion semantics**: `CLOSE_TRIAL_CYCLE` never produces
  `COMPLETED` / `MERGED` / `READY_FOR_GOVERNED_COMPLETION` / `M10_COMPLETE`, and
  M10 remains unchanged (still `TRIAL_COMPLETION_NOT_APPLICABLE` for trial
  safe-stops). No PR, no merge, no roadmap structural change.

## 2. Scope proof

Every DB-M12.4 write lands in the milestone-owned files (attribution in
`state/db-m12-4-result.json`). Fixture tests run against throwaway state/tasks
dirs and **byte-identical copies** of the authoritative workbook under
`logs\selftest\db124`. Invariants assert:

- I1: authoritative workbook untouched by the suite and matching its governed
  recorded state (pristine `F520060C...` before any live closure; the recorded
  post-closure SHA from `state/trial-closure.json` after one);
- I2: Nexus repo git state untouched;
- I3: live trial evidence (`current-task.json`, `claude-review.json`,
  `trial-proving-history.json`) untouched;
- I4: no `WI-07-0.2.4` / `CHG-20260830-017` identity hard-coded in the reusable
  scripts;
- I5: the DB-M12.4 scripts have **no completion/roadmap-structure mutation
  capability** (probe of the write/emit surfaces: `Set-DevBridgeStateEntry`
  status values, `Out-Markers` outcome tokens, and structural-edit primitives --
  the scripts legitimately *reject* real-lifecycle vocabulary, so a bare-word
  scan would be a false positive);
- I6: the solution builds with 0 errors / 0 warnings.

## 3. Bugs caught by the DB-M12.4 harness (real production fixes)

The fixture harness caught four real defects, all fixed and regression-proven:

1. **PS 5.1 `Join-Path` output is a PSObject-wrapped string.** Stored as a
   hashtable value and serialized via `JavaScriptSerializer`, PowerShell's ETS
   adaptation adds an indexable `Item` property, which the serializer reflects
   over -> "circular reference ... PSParameterizedProperty". Fixed with `[string]`
   coercion at every site that stores a joined path as a value.
2. **Dotted unquoted hash-literal key** (`dbM12.4 = ...`) is a PowerShell 5.1
   parser error -> the whole script failed to parse. Fixed with quoted
   `'dbM12.4'`.
3. **`$xmlNs` referenced but never declared** in `New-TCell` under
   `Set-StrictMode -Version Latest`. Fixed by declaring the XML namespace.
4. **`Get-DevBridgeField` used `$d.ContainsKey`**, which throws
   `MethodNotFound` on `OrderedDictionary` (and `.Contains` fails on
   `Dictionary[string,object]`). Fixed with a portable indexer-read + exception
   probe in the shared library `Set-DevBridgeStateEntry.ps1`.
5. **`completion.json` mere-existence guard falsely blocked a legitimately
   closed prior cycle.** M10 writes a single per-cycle `state/completion.json`
   that is never cleared when the next cycle is reserved, so a genuine prior
   completion record (WI-07-0.2.3 / CHG-20260830-016) coexists with the
   current trial. The real-lifecycle guard now scopes by the record's OWN
   `changeId`: a prior cycle's record no longer blocks closure (S12), while a
   same-change or unprovable record still blocks with
   `STOP_TRIAL_HAS_REAL_LIFECYCLE` (S13) -- the previous lifecycle is never
   guessed.
6. **Evidence fidelity: `preWriteBackupSha256` recorded the backup PATH.** The
   closure doc now records the pre-closure backup's ACTUAL SHA256 plus a
   separate `preWriteBackupPath` field (S1 asserts a real 64-hex SHA).
7. **Fixture baseline coupled to the live workbook.** After a governed live
   closure, the authoritative workbook is legitimately no longer the pristine
   F520060C baseline, so fixtures copied from it inherited a Closed
   reservation row and every closure scenario hit the idempotence path. Both
   fixture suites now source fixtures from a pristine F520060C snapshot (the
   live closure's own pre-write backup) and assert the live workbook matches
   its GOVERNED RECORDED state (post-closure SHA from `trial-closure.json`).

## 4. Test evidence

| Suite | Checks | Result |
|---|---|---|
| DB-M12.4 fixture harness (`Test-DBM124TrialCycleClosure.ps1`, S1-S13 + I1-I6) | 54 | **54 passed / 0 failed** |
| DB-M12.2 command regression (`Test-DBM12-2Commands.ps1`) | 59 | **59 passed / 0 failed** |
| GH01 M10 eligibility (`Test-DBM10CompletionEligibility.ps1`) | - | **M10_BLOCKED / TRIAL_COMPLETION_NOT_APPLICABLE / verification PASS** |
| Engine acceptance (`src/DevBridge.Tests`, incl. DB-M12.4 T1-T8) | 410 | **410 passed / 0 failed** |
| UI acceptance (`src/DevBridge.UITests`, incl. DB-M26 read-only module) | 65 | **65 passed / 0 failed** |
| Solution build | - | **0 errors / 0 warnings** |
| Governed live trial closure (WI-07-0.2.4 / CHG-20260830-017) | - | **EXECUTED** (row 80 Closed-terminal, node Planned, evidence preserved) |

## 5. Live closure status

The governed live closure of `WI-07-0.2.4` / `CHG-20260830-017`
(CLOSE_TRIAL_CYCLE in the real state dir) was **EXECUTED** on
`2026-08-31T15:24:45Z`, after explicit human authorization. Pre-closure
validation passed (Mode=TRIAL, target node/change match, lifecycle
`TRIAL_CYCLE_SAFE_STOP`, git/evidence `TRIAL_ONLY_UNMERGED`, M10 not run,
pre-reservation status `Planned` proven from the recorded M04 backup). The
closure:

- set Active Changes row 80 to **Closed-terminal** (never `Completed`);
- left the roadmap node `WI-07-0.2.4` at **Planned** (not completed);
- appended exactly **one** Activity Log row (row 57, Operation
  "Governed Trial Cycle Closure", Result CLOSED, Human Review Not Reviewed);
- preserved all `TRIAL_ONLY_UNMERGED` evidence (`current-task.json`,
  `claude-review.json`, completion.json for the prior WI-07-0.2.3 cycle,
  git baseline);
- produced a pre-closure backup (SHA `F520060C...`, the pristine baseline),
  recorded the post-closure workbook SHA `6D42C3BF...` in
  `state/trial-closure.json`, and kept the protected roadmap fingerprint
  unchanged (`25BBECA...`);
- transitioned live state to **`TRIAL_CYCLE_CLOSED`** /
  `nextAllowedAction=START_NEXT_CYCLE`; a second CLOSE_TRIAL_CYCLE returned
  idempotent `TRIAL_CYCLE_ALREADY_CLOSED` with no re-write.

No M10, no PR, no merge, no roadmap structural change, no Git reset, no
baseline restore. The live trial reservation is now **released**; the final
hardened Lane C proving cycle resumes on a separate human decision and is
NOT started by this milestone.

## 6. Milestone outputs

- Design: `design/DB-M12.4_GOVERNED_TRIAL_CYCLE_CLOSURE.md`
- Result: `state/db-m12-4-result.json`
- This report: `tasks/DB-M12.4_IMPLEMENTATION_REPORT.md`

## 7. Stop conditions (honored)

- M10: **NOT run** for WI-07-0.2.4.
- Live closure: performed ONLY on explicit human authorization (never
  automatic); it closed/released the trial reservation and did NOT complete
  the work item.
- Live M04/M05: **NOT launched** for another work item.
- No PR, no merge, no roadmap structure change, no baseline restore.
- **Stop after the live closure**; M03 / START_NEXT_CYCLE is NOT run and the
  final hardened Lane C proving cycle is NOT started by this milestone.
