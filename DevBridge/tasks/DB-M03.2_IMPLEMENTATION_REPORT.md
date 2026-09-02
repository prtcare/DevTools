# DB-M03.2 -- Trial-Proven Dependency Overlay: Implementation Report

Date (UTC): 2026-09-01  |  Lane C  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency.

---

## 1. What this milestone delivered

After the governed closure of the `WI-07-0.2.4` trial cycle (DB-M12.4:
`TRIAL_CYCLE_CLOSED` / `TRIAL_ONLY_UNMERGED`, real roadmap status still
`Planned`), the next proving candidate `WI-07-0.2.5` is blocked by a textual
dependency on `WI-07-0.2.4`. The dependency gate requires a
`Completed`/`Complete` predecessor, and `WI-07-0.2.4` will never be one --
converting trial evidence into real Nexus completion is forbidden.

DB-M03.2 adds a **TRIAL-PROVEN DEPENDENCY OVERLAY**: for SUBSEQUENT
PROVING-CYCLE SELECTION ONLY, a governedly closed TRIAL proving task may satisfy
its dependencies, making `WI-07-0.2.5` resolvable -- **without** modifying the
real work-item status, the workbook, the roadmap, or the Nexus source baseline.

- **One shared read-only helper** -- `scripts/TrialDependencyOverlay.ps1`
  (`Test-TrialDependencySatisfied`, ~275 lines). Dot-sourced by every engine
  that checks dependencies. No duplicated dependency engines.
- **Six qualification gates** -- (0) overlay enabled (default enabled; config
  `trialDependencyOverlay.enabled` or env `DB_TRIAL_DEPENDENCY_OVERLAY` can
  disable); (1) `TRIAL` mode only (`Get-DevBridgeMode`); (2) closure history
  entry `{TRIAL_CYCLE_CLOSED, TRIAL_ONLY_UNMERGED, TRIAL}`; (3) DB-M18.1
  freshness not `DEPENDENCY_CONTEXT_STALE`; (4) evidence dir
  `<stateDir>/../logs/tasks/<node>/<change>/` present; (5) `claude-decision.json`
  `dbM06Result == VERIFICATION_PASS` AND `decision == PASS` AND `trialMode == true`
  AND `implementationState == TRIAL_ONLY_UNMERGED`. Any gate failure returns an
  honest block token -- never fake satisfaction.
- **Truthful provenance** -- `TRIAL_DEPENDENCY_SATISFIED`,
  `realNexusCompletion = false`, `disposableProvingContext = true`,
  `realStatus` authoritative, chained M06/M08 evidence, closure evidence,
  DB-M18.1 repository reconciliation. **TRIAL_TO_REAL_COMPLETION_CAPABILITY = NO.**
- **Four wired insertion sites** -- `Get-NextTask.ps1` `Test-DepsSatisfied`,
  `Test-DevelopmentPreflight.ps1` PART 4, `Reserve-DevelopmentChange.ps1`
  Part 1 revalidation, `New-ChatGptHandoff.ps1` PART 1 item 6.
- **Truthful consumption (M04/M05/M07)** -- M04 reserves only the new task
  (predecessor real status untouched); M05 appends a Trial-Proven Dependency
  Context section (real status authoritative, disposable proving context, real
  completion capability NO); M07 appends a Trial-Proven Dependency Distinction
  section (real Completed vs trial-proven).

## 2. Immutable boundaries honored

- `TRIAL_DEPENDENCY_SATISFIED` is **NOT** COMPLETE / MERGED /
  REAL_VERIFIED_COMPLETE / M10_COMPLETE / READY_FOR_GOVERNED_COMPLETION.
- `WI-07-0.2.4` was **never** marked Complete. Trial evidence was **never**
  converted into real Nexus completion.
- The real Nexus restart point remains the preserved PRE-DEVBRIDGE workbook +
  source/Git baseline. Proving activity is disposable scaffolding.
- NO live mutation during development/tests: all engine runs used byte-identical
  fixture workbook copies under `logs/selftest/db-m03-2`. The authoritative
  workbook SHA is unchanged (`6D42C3BF...E4F5`).
- DB-M18.1-owned lineage/index files were not modified (additive calls only).
- DB-M28 UI files were not touched.
- Stop after DB-M03.2: **no live M04 reserve, no live M05 handoff, no live M10,
  no baseline restore.**

## 3. Implementation notes

- **PS 5.1 `@()` / `List[object]` bug fixed** -- the M05 Trial-Proven Dependency
  Context loop used `foreach ($tov in @($script:DepOverlays))` over a
  `System.Collections.Generic.List[object]`, which throws `ArgumentException:
  Argument types do not match` in Windows PowerShell 5.1 (reproduced in
  isolation; a one-element list is enough). `$script:DepOverlays` is now a plain
  array (`@()` + `+=`).
- **Debug harness** `logs/dbm032-debug/debug-c18.ps1` reproduced the C18 M05
  run standalone with full stderr and confirmed the fix.
- **Suite-log placement** -- the M05 engine's tree sweep (PART 20b) scans the
  real DevBridge root for files touched within its run window. A suite log
  written inside the root trips a false positive; the suite record is therefore
  written outside the root (`logs/selftest/db-m03-2-final.log` is a post-run
  copy).

## 4. Test evidence

`scripts/Test-DBM032TrialDependencyOverlay.ps1` -- **46 checks, 46 passed,
0 failed, exit 0** (`DB-M03.2 SUITE: PASS`).

- **A1-A7** overlay unit qualification (provenance truth, missing history,
  REAL mode ignored, stale context block, FIX decision -> invalid, config
  disable).
- **B8-B13** M03 selection engine (`WI-07-0.2.5` selected with truthful basis;
  sparse/invalid evidence -> honest `NO_IMPLEMENTABLE_DESCENDANT`; REAL mode
  re-selects `WI-07-0.2.4`; env-disable preserves pre-overlay behavior).
- **C14-C22** preflight / M04 / M05 / M07 integration (CLEAR preflight,
  `STOP_PREFLIGHT_STALE`, `HANDOFF_GENERATED` with Trial-Proven Dependency
  Context, `HANDOFF_STATE_STALE` on missing evidence, M07 package markers +
  trial/real distinction).
- **D23-D26** non-mutation (real status stays `Planned`; M04 leaves predecessor
  untouched; no-history pre-overlay behavior; authoritative workbook untouched).
- **R27-R33** regression suites (DB-M03.1, DB-M12.2, DB-M12.4, DB-M10 probe,
  DB-GH01, DB-M18.1 known-R45-drift-only, DB-M04Safety last).
- **I34-I39** invariants + build (workbook hash, Nexus repo git state, live
  state, solution build 0 warnings / 0 errors).

## 5. Outputs

- `design/DB-M03.2_TRIAL_PROVEN_DEPENDENCY_OVERLAY.md`
- `state/db-m03-2-result.json`
- `tasks/DB-M03.2_IMPLEMENTATION_REPORT.md`
- `logs/selftest/db-m03-2-final.log`

Verdict: **PASS**. `TRIAL_TO_REAL_COMPLETION_CAPABILITY = NO`. Real workbook
status preserved. Canonical workbook modified: NO. Nexus source modified: NO.
Current `WI-07-0.2.5` proving candidate resolvable. Ready to resume the Final
Hardened Lane C Trial.
