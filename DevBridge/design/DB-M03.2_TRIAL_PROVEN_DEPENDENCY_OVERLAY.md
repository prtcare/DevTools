# DB-M03.2 — TRIAL-PROVEN DEPENDENCY OVERLAY

**Milestone:** DB-M03.2 (governance / dependency qualification for proving cycles)
**Date:** 2026-09-01
**Status:** DESIGN & IMPLEMENTED
**Owner lane:** Lane C proving-cycle readiness (governed by DB-M12.4)
**Driver:** After the governed closure of the WI-07-0.2.4 trial cycle (DB-M12.4), the next proving candidate WI-07-0.2.5 is blocked by a textual dependency on WI-07-0.2.4 — a predecessor that is trial-proven but whose REAL roadmap status is and must remain `Planned`.

---

## 1. Context & why

A governed DevBridge proving cycle follows a strict lifecycle: M03 preflight/selection, M04 reserve, M05 handoff, M06 verify, M07/M08 Claude review, and in TRIAL mode a governed safe-stop / trial-cycle closure (DB-M12.4) that records `TRIAL_CYCLE_CLOSED` evidence WITHOUT ever marking the real work item Complete. The closure evidence lives in the trial-proving history and the evidence tree (`logs\tasks\<node>\<change>\`).

The successor WI-07-0.2.5 depends on WI-07-0.2.4. Without an overlay, the dependency gate `Test-DepsSatisfied` requires a `Completed`/`Complete` predecessor — WI-07-0.2.4 will never be one, because converting trial evidence into real Nexus completion is **forbidden**. The proving cycle would stall at M03 with `NO_IMPLEMENTABLE_DESCENDANT` forever, defeating the purpose of chained proving.

**DB-M03.2 objective:** for SUBSEQUENT PROVING-CYCLE SELECTION ONLY, a governedly closed TRIAL proving task may satisfy its dependencies — without modifying the real work-item status, the workbook, the roadmap, or the Nexus source baseline. The overlay is a disposable proving-scaffold qualification, explicitly **not** real completion, and every engine that consumes it tells the truth about that distinction.

## 2. Immutable boundaries (verbatim constraints)

- **TRIAL_DEPENDENCY_SATISFIED is NOT** COMPLETE / MERGED / REAL_VERIFIED_COMPLETE / M10_COMPLETE / READY_FOR_GOVERNED_COMPLETION.
- DO NOT mark WI-07-0.2.4 Complete; DO NOT convert trial evidence into real Nexus completion.
- The real Nexus restart point is the preserved PRE-DEVBRIDGE workbook + source/Git baseline; proving activity is disposable Phase 1/2 scaffolding.
- NO LIVE MUTATION during development/tests: fixtures/temp state only. The authoritative workbook is never written by any DB-M03.2 engine run or test.
- Do not modify DB-M18.1-owned lineage/index files (additive calls only).
- Do not modify DB-M28 UI files (Lane B) — config/ai-routing, model-config, src DevBridge.UI are out of scope.
- Stop after DB-M03.2: do NOT run live M04/M05, do NOT mark WI-07-0.2.4 Complete, do NOT run M10, do NOT restore the pre-DevBridge baseline.

## 3. Design decisions

### 3.1 One shared qualification helper — `TrialDependencyOverlay.ps1`

A single read-only helper (`Test-TrialDependencySatisfied`) is dot-sourced by every engine that checks dependencies. No duplicated dependency engines.

Qualification gates (all must pass; the first failure returns an honest block code):

| Gate | Check | Block code on failure |
|---|---|---|
| 0 | Overlay enabled (config `trialDependencyOverlay.enabled` ≠ false; env `DB_TRIAL_DEPENDENCY_OVERLAY` ∉ `0/false/False/FALSE`; default **enabled**) | `OVERLAY_DISABLED` |
| 1 | `Get-DevBridgeMode` == `TRIAL` | `NOT_TRIAL_MODE` |
| 2 | `trial-proving-history.json` entry `{result = TRIAL_CYCLE_CLOSED, implementationState = TRIAL_ONLY_UNMERGED, mode = TRIAL, preReservationStatus = Planned}` for the node | `NO_TRIAL_HISTORY` / `TRIAL_DEPENDENCY_EVIDENCE_INVALID` |
| 3 | DB-M18.1 `DbM181Context.FreshnessStatus` ≠ `DEPENDENCY_CONTEXT_STALE` | `DEPENDENCY_CONTEXT_STALE` |
| 4 | Evidence dir `<stateDir>\..\logs\tasks\<node>\<change>\` exists | `EVIDENCE_DIR_MISSING` |
| 5 | `claude-decision.json`: `dbM06Result == VERIFICATION_PASS`, `decision == PASS`, `trialMode == true`, `implementationState == TRIAL_ONLY_UNMERGED` | `TRIAL_DEPENDENCY_EVIDENCE_INVALID` |

When all gates pass, the helper returns a **provenance object** (capability 5 — chained trial proving with provenance per node):

- identity: `nodeId`, `changeId`, `closedAtUtc`
- overlay truth: `overlayStatus = TRIAL_DEPENDENCY_SATISFIED`, `realNexusCompletion = $false`, `disposableProvingContext = $true`, `realStatus` (authoritative roadmap status), `realStatusAuthoritative = $true`
- chained evidence: `verificationEvidence { m06Result, testsPassed/testsFailed/testsSkipped/testsTotal, buildSucceeded/buildWarnings/buildErrors, harness }` and `claudeEvidence { milestone, decision, trialMode, implementationState, reviewedAgainstDbM06, reviewTimestampUtc }`
- closure: `closureEvidence { result, mode, implementationState, preReservationStatus, closedAtUtc }`
- reconciliation: `repositoryReconciliation { historicalTrialEvidence, currentTrialRepositoryReality = EVIDENCE_PRESENT, freshness, staleReasons }`

### 3.2 Four wired insertion sites (all additive to existing behavior)

1. **`Get-NextTask.ps1`** — `Test-DepsSatisfied`: a dep is satisfied if live status is `Complete`/`Completed` **or** the overlay qualifies (`TRIAL_DEPENDENCY_SATISFIED`). The selection basis records the overlay truthfully.
2. **`Test-DevelopmentPreflight.ps1`** PART 4 — dependency validation: trial-proven deps yield dependency state `TRIAL_DEPENDENCY_SATISFIED` (real roadmap status preserved), pass leaf validation with an overlay detail note.
3. **`Reserve-DevelopmentChange.ps1`** Part 1 revalidation — re-qualifies the trial dep at reserve time; stale/invalid evidence stops with an honest block.
4. **`New-ChatGptHandoff.ps1`** PART 1 item 6 — live dependency recheck honors `TRIAL_DEPENDENCY_SATISFIED` like a real `SATISFIED` dep, and appends the truthful Trial-Proven Dependency Context section to the handoff.

### 3.3 Truthful consumption (capabilities 9, 10, 11)

- **M04 reserve** (capability 9): reserves only the new task (WI-07-0.2.5); the predecessor's real status is never altered.
- **M05 handoff** (capability 10): the Trial-Proven Dependency Context section tells ChatGPT the predecessor is `TRIAL_CYCLE_CLOSED` / `TRIAL_ONLY_UNMERGED`, its real roadmap status is `Planned` and authoritative, overlay status `TRIAL_DEPENDENCY_SATISFIED`, real completion capability **NO**, and the real restart point is the preserved PRE-DEVBRIDGE baseline.
- **M07 package** (capability 11): `New-ClaudeReviewPackage.ps1` adds a "Trial-Proven Dependency Distinction" section that distinguishes real `Completed` predecessors from trial-proven `TRIAL_DEPENDENCY_SATISFIED` ones.

### 3.4 Invalidation, reconciliation, restoration (capabilities 6, 7, 12)

- **Invalidation** → honest block: if closure evidence is missing/contradictory the engines stop with `TRIAL_DEPENDENCY_EVIDENCE_INVALID`; if the DB-M18.1 lineage context is `DEPENDENCY_CONTEXT_STALE` they stop with `DEPENDENCY_CONTEXT_STALE` (rebuild path is DB-M18.1-owned).
- **No false workbook completion**: there is no TRIAL_TO_REAL_COMPLETION path. `TRIAL_TO_REAL_COMPLETION_CAPABILITY = NO`.
- **Restoration safety**: no DB-M03.2 engine writes the authoritative workbook, no Nexus source is touched, and the pre-DevBridge baseline remains the restart point.

## 4. Files changed

| File | Change |
|---|---|
| `scripts/TrialDependencyOverlay.ps1` | NEW shared qualification helper + provenance builder (275 lines) |
| `scripts/Get-NextTask.ps1` | dependency satisfaction honors trial-proven overlay; truthful basis |
| `scripts/Test-DevelopmentPreflight.ps1` | PART 4 dependency state = TRIAL_DEPENDENCY_SATISFIED + leaf detail |
| `scripts/Reserve-DevelopmentChange.ps1` | Part 1 re-qualification with honest block on stale/invalid |
| `scripts/New-ChatGptHandoff.ps1` | item-6 dep recheck + Trial-Proven Dependency Context section |
| `scripts/New-ClaudeReviewPackage.ps1` | Trial-Proven Dependency Distinction section |
| `scripts/Test-DBM032TrialDependencyOverlay.ps1` | NEW 46-check suite (units, engines, non-mutation, regressions, build) |

## 5. Test matrix (46 checks)

- **A1–A7** overlay unit qualification (provenance truth, missing history, REAL mode, stale context, FIX decision, config disable).
- **B8–B13** M03 selection engine (WI-07-0.2.5 selected with truthful basis; sparse/invalid evidence → honest block; REAL mode re-selects WI-07-0.2.4).
- **C14–C22** preflight / M04 / M05 / M07 integration incl. truthful handoff content and no stale-stop.
- **D23–D26** non-mutation: real status stays `Planned`, M04 leaves predecessor untouched, pre-overlay behavior with no history, authoritative workbook untouched.
- **R27–R33** regression suites (DB-M03.1, DB-M12.2, DB-M12.4, DB-M10 probe, DB-GH01, DB-M18.1 known-R45-drift-only, DB-M04Safety last).
- **I34–I39** invariants: workbook hash, Nexus repo status, live state, solution build 0 warnings / 0 errors.

## 6. Known limitation

Lane B's DB-M18.1 resolver has one pre-existing external drift (R45: child classification suite hard-codes WI-07-0.2.4 as current task while the live current task is M-07-0.2). It is Lane B-owned, unchanged by DB-M03.2, and asserted as the known-drift signature only (63/64).
