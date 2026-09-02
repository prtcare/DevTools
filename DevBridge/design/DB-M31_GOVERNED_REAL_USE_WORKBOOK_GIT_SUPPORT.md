# DB-M31 -- GOVERNED REAL-USE WORKBOOK & GIT SUPPORT: Design

Date: 2026-09-01  |  Lane B  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. DevBridge is NOT part of
Nexus. Nothing implemented in DB-M31 is intended for migration into Nexus. Do
NOT design DB-M31 for Nexus migration.

---

## 1. Purpose and boundary

DB-M31 hardens and UNIFIES the existing DevBridge workbook-write and Git
observation paths so that DevBridge can later be used SAFELY in a governed REAL
Nexus development cycle, while keeping absolute roadmap immutability and zero
autonomy expansion.

- **DO NOT switch to REAL_NEXUS_DEVELOPMENT now.** The current environment
  remains TRIAL / DevBridge proving state. DB-M31 is implemented and tested
  using fixtures / temp copies (synthetic OOXML workbook fixtures, temp git
  repos, temp state roots). The actual switch to REAL happens only after final
  DevBridge acceptance and restoration of the PRE-DEVBRIDGE Nexus baseline.
- **DB-M31 does NOT add:** autonomous development, automatic AI execution,
  automatic PR creation/approval/merge, autonomous roadmap progression,
  automatic next-task loops. Every external Git / ChatGPT / Claude Code /
  DeepSeek step stays a human action.
- **DB-M31 is READ-ONLY against the live canonical workbook.** Its writer is
  proven exclusively on fixture workbook copies. The live workbook must remain
  byte-identical across the DB-M31 run (`6D42C3BF6D3307B4B1A45870CE12F41E403DFED412E59F33D7B487E93A83E4F5`).
- **Scope:** DB-M31 writes ONLY under `scripts/governed-workbook-git/`,
  `design/`, `state/`, `tasks/`. No Lane A / Lane C / DB-GH01 / Nexus source is
  modified. **NO PARALLEL_SCOPE_CONFLICT.**

---

## 2. Discovery findings (DB-M31 DISCOVERY, 2026-09-01)

Consolidated from read-only inspection of the workbook writer, Git-state
reader, lifecycle gates, and the workbook sheet structure.

### 2.1 All workbook write paths

There is NO single writer module. Four production PowerShell OOXML writers are
scattered and duplicated, all pure `System.IO.Compression.ZipArchive` +
`System.Xml.Linq.XDocument` (no COM/Excel), all following the same safe pattern
**temp-copy -> mutate -> verify temp -> atomic replace -> reopen canonical ->
re-verify**:

| Writer | Gate | Sheets/cells written |
|--------|------|----------------------|
| `scripts/Reserve-DevelopmentChange.ps1` | M04 RESERVE_TASK | Active Changes append (row `Get-LastDataRow+1`); Activity Log append; dimension updates |
| `scripts/Complete-Workbook-DBM10.ps1` | M10 completion | Control Center A2 prepend; Master Roadmap R327/R324 exec-state cells (`R,T,AC,AD,AA`); Active Changes R79 (`L,U,V,AC,AD`); Version History append rows 958/959; Activity Log row 54; Tool & Integration Registry row 16; Existing Assets row 16 |
| `scripts/Complete-GovernedCycle.ps1` | M12.2 RUN_GOVERNED_COMPLETION | data-driven `Apply-PlanToWorkbook` over `state/sheet-update-plan.json` (execution-state cells only) |
| `scripts/Close-TrialCycle.ps1` | M12.4 CLOSE_TRIAL_CYCLE | Active Changes reservation row -> Closed; Activity Log append; optional Master Roadmap Status restore (exec-state cell, fingerprint-safe) |

Only 3 operator commands are marked `WritesWorkbook` in
`src/DevBridge.Engine/OperatorCommand.cs` (RESERVE_TASK, RUN_GOVERNED_COMPLETION,
CLOSE_TRIAL_CYCLE). `Read-DevelopmentControl.ps1` is strictly read-only.

**Stale-state checks:** only M04 compares a live whole-file SHA against a
recorded preflight hash (`STOP_PREFLIGHT_STALE`). M12.2/M12.4 rely on the
protected-roadmap fingerprint before/after. **M10 trusts the externally
captured `state/roadmap-fingerprint.json` instead of recomputing `after` on the
mutated temp** -- a freshness gap DB-M31 closes in its own chain.

**Backup:** M04 is hash-validated (`STOP_BACKUP_FAILED` if backup SHA != pre-write
SHA); M12.2/M12.4 validate existence only; M10 consumes an external backup.
**Read-back:** every writer re-opens and re-verifies after the atomic replace
(`STOP_WRITE_VERIFY_FAILED`, `STOP_PLAN_VERIFICATION_FAILED_POST_WRITE`, exit 2).
**Busy-lock:** atomic replace via `Move-Item -Force` with catch -> fail-stop; no
tight retry loops anywhere. Gap: M04's `[IO.File]::Copy(temp, canonical, true)`
has no try/catch.

### 2.2 Structural-roadmap-write hazard analysis

The protected surface (`config/roadmap-protection.json`) is the 5 sheets
Master Roadmap, Phase Plan, Architecture Decisions, Dependencies & Blockers,
Open Decisions, restricted to identity+structure columns ONLY, with
execution-state columns (Status R, Progress T/U/V, Owner W, Current Evidence
AC, Next Action AD, Notes AA, Source AF) explicitly excluded. Verified: **no
code path can currently write a protected column.** Every write to a protected
sheet targets only Master Roadmap execution-state cells `R/T/AC/AD/AA`. The
data-driven `Apply-PlanToWorkbook` recomputes `fpAfter` on the temp and blocks
with `STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED` before the atomic replace. The
fingerprint guard (`Get-ProtectedRoadmapFingerprint.ps1` +
`src/DevBridge.Engine/ProtectedRoadmapFingerprint.cs`) is SHA-256 over
`{sheet}|{col}|{row}|{value};` tokens for protected columns only (715 rows /
9161 cells / `25BBECA4...` today).

### 2.3 Git-state paths

Git is observe-only: `rev-parse`, `log -1`, `status --porcelain`. Zero remote or
destructive invocations anywhere. `Get-GitGateState.ps1` (DB13) is the dedicated
observer: `prState` defaults to `UNKNOWN` (never inferred as NO_PR/NOT_MERGED);
`mergeConfirmed = prState -in MERGED,READY_FOR_GOVERNED_COMPLETION`. M04 captures
`gitBaseline` (repository, branch, headCommit, headSubject, staged/modified/
untracked files, statusLines, capturedAt). `Get-PreDevBridgeBaseline.ps1` writes
`state/pre-devbridge-baseline.json` represent-only ("NO RESTORE FUNCTION
EXISTS").

### 2.4 Lifecycle gates (duplicate logic + gaps found)

- **M10 eligibility exists in 4 copies** (PS probe, C# engine, and write gates in
  Complete-Workbook-DBM10 + Complete-GovernedCycle), all gating in order:
  TRIAL -> `TRIAL_COMPLETION_NOT_APPLICABLE`; REAL -> M06 PASS -> Claude PASS ->
  merge confirmed (`gitLifecycleState` MERGED/READY_FOR_GOVERNED_COMPLETION,
  never inferred) -> fingerprint PRESERVED. Blocked tokens already exist.
- **M11** = `Invoke-WorkbookValidation.ps1` (lightweight: COMPLETION_WRITTEN +
  completion/changeId match + workbook opens -> CONTROL_VALIDATED) plus the
  26-part/14-sheet matrix recorded in `state/workbook-consistency.json`.
- **M12.2 contract**: always exit 0, stdout markers only (`<PREFIX>_OUTCOME /
  _RESULT_PASS / _RESULT_CODE / _WORKBOOK_MODIFIED / _GIT_MODIFIED /
  _NEXUS_SOURCE_MODIFIED / _REQUIRES_HUMAN_ACTION / _HUMAN_ACTION_TYPE /
  _EVIDENCE`), env-var input channel, and the failure tokens
  `STALE_GOVERNANCE_STATE`, `WORKBOOK_WRITER_BUSY`, `BACKEND_STATE_MISMATCH`
  already exist.
- **M12.4 trial closure**: `CLAUDE_REVIEW_PASSED_TRIAL | TRIAL_CYCLE_SAFE_STOP`
  -> `TRIAL_CYCLE_CLOSED` / `START_NEXT_CYCLE`; TRIAL-only with
  `STOP_TRIAL_HAS_REAL_LIFECYCLE`; never runs M10.
- **Mode** is explicit (`TRIAL` / `REAL_NEXUS_DEVELOPMENT`), unknown -> safe TRIAL.

### 2.5 External findings (NOT modified by DB-M31; reported separately)

1. `scripts/Test-DBM10CompletionEligibility.ps1:106` compares `$Verdict` against
   `"ReadyForGovernedCompletion"` but assigns the underscore token
   `"READY_FOR_GOVERNED_COMPLETION"` -> the probe's `Eligible` marker is always
   `$false` even when all gates pass. The write gates and the C# engine are
   correct; only the probe's self-report is broken. Lane A / DB-GH01 scope.
2. `scripts/Get-CurrentLifecycleState.ps1` reads `verification.json` /
   `claude-review.json` unconditionally (no changeId-ownership guard that the
   C# `StateReader.EvidenceApplies` applies) -> stale `CHG-20260830-016`
   evidence leaks into the live snapshot. DB-M31's own engine applies the
   ownership guard (bound to current task nodeId/changeId).
3. Live `current-task.json` (`RESOLVE_GOVERNANCE_BLOCK`) vs
   `current-lifecycle-state.json` (`RESOLVE_PREFLIGHT`) disagree on next action.
   DB-M31 reports observed state honestly and never invents a state.

### 2.6 External drifts (reported separately, unchanged signatures)

- **DB-M26 S41** workbook-authority fixture drift (suite records F520060C; live
  workbook 6D42C3BF post DB-M12.4 closure).
- **DB-M18.1 R45** child-suite fixture drift (child DB-M18 regression exits
  non-zero).
Neither is a DB-M31 failure; DB-M31 does not change their signatures.

---

## 3. Architecture

Owned directory: `scripts/governed-workbook-git/`. Files:

| File | Purpose |
|------|---------|
| `WorkbookGitContracts.ps1` | self-contained: writer/git/failure/merge vocabularies, ReadOnlyGuard, secret scanner, `Out-DbM31Markers`, `Get-FileSha256`, array normalization, defensive property reader |
| `WorkbookGitEngine.ps1` | the engine: canonical write chain, protected-roadmap fingerprint, execution-state plan validation, Git observation, human-git-gate resolver, M10 eligibility, M11 validation, fix-task governance, PR preparation package, audit trace, pre-DevBridge baseline (read-only) |
| `WorkbookGitRender.ps1` | self-contained HTML human-action UI (CREATE PR / REVIEW PR / MERGE PR / RUN COMPLETION / RUN WORKBOOK VALIDATION as distinct actions) |
| `Show-DbM31GovernedRealUse.ps1` | CLI wrapper: always exit 0, outcomes via `DB31_*` stdout markers |
| `Test-DbM31GovernedRealUse.ps1` | the 54-matrix suite (A1-T54), fixture-driven, exit 0/1 |

Engine input injection: every resolver accepts `-Root` (state root) +
`-WorkbookPath` (fixture workbook) + `-NowUtc`, so tests run against temp
fixtures (state source `FIXTURE`) and only the honesty scenarios read the live
state/workbook read-only (`LIVE`). The engine is deterministic, zero
AI/network/paid calls, and never writes anything outside the operator-requested
artifact + its own evidence under the fixture root.

### 3.1 The unified canonical write chain (Capability 3)

`Resolve-DbM31CanonicalWrite` -- the SINGLE governed write path DB-M31 proves and
documents (in production the existing Lane A writers are the *callers* of this
contract; DB-M31 proves the contract on fixtures):

```
fresh-read authoritative workbook
  -> validate authority/path            (recognized governed workbook path or explicit fixture)
  -> stale-state check                  (current whole-file SHA == ExpectedBeforeSha, else STALE_GOVERNANCE_STATE)
  -> serialized writer                  (acquire writer lock; held -> WORKBOOK_WRITER_BUSY; single attempt, NO tight retry)
  -> hash-validated backup              (copy -> backup path; backup SHA must equal pre-write SHA, else BACKUP_CREATION_FAILED)
  -> approved execution-state write     (validate plan: execution-state sheets/columns ONLY; structural target -> ROADMAP_STRUCTURE_WRITE_PROHIBITED, no write)
  -> save / close
  -> reopen actual canonical workbook
  -> read-back exact intended state     (else WORKBOOK_READBACK_FAILED; write treated as failed)
  -> verify protected roadmap           (fpAfter on reopened workbook == fpBefore, else PROTECTED_ROADMAP_MISMATCH; write treated as failed)
  -> only then update DevBridge state   (evidence + audit trace)
```

No DevBridge JSON/cache state ever becomes authority over Excel: the workbook is
fresh-read each operation and the JSON is updated only after the workbook write
is verified.

### 3.2 Execution-state-only write validation (Capabilities 1, 2, 5)

`Test-DbM31ExecutionStatePlan` classifies every target sheet/column against
`config/development-control-map.json` (sheet roles + mutation types),
`config/sheet-governance.json` (roles), and `config/roadmap-protection.json`
(protected columns). Approved surfaces: Active Changes (APPEND_ONLY), Activity
Log (APPEND_ONLY), Version History (APPEND_ONLY), Tool & Integration Registry
(UPDATE_AND_APPEND_HISTORY), Existing Assets (UPDATE_AND_APPEND_HISTORY),
Control Center A2 (derived summary), and Master Roadmap execution-state cells
(R/T/AC/AD/AA). NEVER: phases, milestones, hierarchy, roadmap sequence,
development order, architecture, goals, acceptance criteria, dependencies
(Session Protocol is `NONE`). A structural target returns
`ROADMAP_STRUCTURE_WRITE_PROHIBITED` and the chain performs zero writes.

### 3.3 Failure / recovery vocabulary (Capability 17)

Unified, explicit, no silent recovery:

| Token | Meaning |
|-------|---------|
| `WORKBOOK_WRITER_BUSY` | a governed writer is already serialized / the lock is held |
| `STALE_GOVERNANCE_STATE` | workbook changed between read and write; operator must refresh/reconsider; no automatic overwrite |
| `BACKEND_STATE_MISMATCH` | script exited 0 but state did not advance as declared |
| `WORKBOOK_READBACK_FAILED` | reopened workbook does not match the intended write |
| `BACKUP_CREATION_FAILED` | backup could not be created or fails SHA validation |
| `PROTECTED_ROADMAP_MISMATCH` | fingerprint changed across the write (write failed) |
| `GIT_STATE_UNKNOWN` | repository/branch/HEAD cannot be observed |
| `PR_STATE_UNKNOWN` | remote PR state cannot be verified; never inferred as NO_PR |
| `MERGE_STATE_UNKNOWN` | positive merge evidence unavailable; M10 blocked |
| `HUMAN_GIT_ACTION_REQUIRED` | a human Git action is the next required step |

No code path silently retries, silently overwrites, or infers a remote/merge
state.

### 3.4 Git observation + human Git gates (Capabilities 7, 8, 9, 15, 19)

`Resolve-DbM31GitObservation -RepositoryPath` (read-only `git -C`): repository
path, branch, HEAD, working-tree status, changed files, commit state. Remote
unknown -> `PR_STATE_UNKNOWN` (never `NO_PR`/`NOT_MERGED`). `Resolve-DbM31HumanGitGate`
derives the gate position ONLY from explicit `gitLifecycleState` evidence:
`AWAITING_HUMAN_PR / PR_OPEN / AWAITING_HUMAN_REVIEW / AWAITING_HUMAN_MERGE /
MERGED / READY_FOR_GOVERNED_COMPLETION`. Merge is NEVER inferred from a clean
working tree, a branch change, commit existence, or PR closure alone; without
positive merge evidence -> `MERGE_STATE_UNKNOWN`, M10 blocked.
`Resolve-DbM31PrPreparationPackage` builds the human PR package (task, change,
scope, changed files, build/tests, M06, Claude review, known non-blocking
observations, dependency-context summary, Git baseline + current HEAD,
recommended PR title/body) and reports `AWAITING_HUMAN_PR` -- it performs no Git
action. `Resolve-DbM31PreDevBridgeBaseline` validates the configured
`PreDevBridgeWorkbookBaseline` / `PreDevBridgeGitBaseline` read-only and never
restores them; automatic destructive commands (`git reset --hard`, `git clean`,
automatic workbook overwrite) are prohibited by contract and absent from the
library.

### 3.5 M10 hardening + M11 + fix-task governance (Capabilities 12, 13, 14)

`Resolve-DbM31M10Eligibility` requires, in order:
Mode = REAL_NEXUS_DEVELOPMENT; M06 PASS; Claude PASS; no blocking governance
issue; approved scope; positive human Git merge evidence; fresh workbook state;
protected roadmap fingerprint preserved; eligible lifecycle state. Any missing
-> a specific BLOCKED token. TRIAL -> `TRIAL_COMPLETION_NOT_APPLICABLE` first
(flow preserved: M03->M04->M05->supervised implementation->M06->M07/M08->
correction->TRIAL_CYCLE_SAFE_STOP->CLOSE_TRIAL_CYCLE).

`Resolve-DbM31M11Validation` (post-completion): 14-sheet consistency,
execution-state coherence, protected roadmap unchanged, dependency/status
consistency, Activity Log / Version History / Active Changes closure, completion
evidence. On failure -> explicit governance/reconciliation state (never a
silent clean claim).

`Resolve-DbM31FixTaskGovernance`: a genuine post-completion defect ->
`NEW_FIX_TASK_REQUIRED` under the existing governed phase/milestone structure;
never a new phase/milestone/hierarchy/roadmap order; if representation requires
structural change -> `HUMAN_GOVERNANCE_REQUIRED`.

### 3.6 Audit trace (Capability 18)

`Resolve-DbM31AuditTrace` records, per governed lifecycle operation: operation
ID, task/change ID, mode, timestamp, input lifecycle state, result lifecycle
state, workbook SHA before/after (where relevant), Git HEAD before/after
observation, human action required, verification result, Claude result. No
secret material (the engine's secret scanner runs on every audit + view).

### 3.7 Human-action UI (Capabilities 16, 20)

`WorkbookGitRender.ps1` emits a self-contained HTML console showing distinct
actions: **CREATE PR** / **REVIEW PR** / **MERGE PR** / **RUN COMPLETION** /
**RUN WORKBOOK VALIDATION**. Only RUN COMPLETION and RUN WORKBOOK VALIDATION are
marked backend-invoking; the three Git actions are human/external (guidance
only). Guard footer: `Read-only guard (DB-M31): AutoExecutionEnabled=False...`;
markers `AUTO_EXECUTION_ENABLED=FALSE`, `LifecycleStateModified=NO ·
WorkbookModified=NO · NexusSourceModified=NO · GitModified=NO`. Every HTML
emission passes the secret scan; the only library disk write is
`Export-DbM31GovernedHtml`'s `WriteAllText` (UTF-8, no BOM) of the
operator-requested artifact.

---

## 4. Test matrix (54) -> scenario IDs

`Test-DbM31GovernedRealUse.ps1` -- fixture-driven, deterministic, exit 0/1.

| # | Proves | Scenario |
|---|--------|----------|
| 1 | execution-state-only workbook writes | A1 |
| 2 | structural roadmap write rejected | A2 |
| 3 | fingerprint before/after | A3 |
| 4 | canonical workbook authority | A4 |
| 5 | backup before write | A5 |
| 6 | pre-write hash | A6 |
| 7 | post-write hash | A7 |
| 8 | read-back validation | A8 |
| 9 | writer busy | A9 |
| 10 | stale state | A10 |
| 11 | duplicate write protection | A11 |
| 12 | backend mismatch | A12 |
| 13 | backup failure handling | A13 |
| 14 | read-back failure handling | A14 |
| 15 | Git branch observation | B15 |
| 16 | HEAD observation | B16 |
| 17 | working-tree observation | B17 |
| 18 | unknown remote state stays UNKNOWN | B18 |
| 19 | human PR state | B19 |
| 20 | PR_OPEN only from evidence | B20 |
| 21 | human review gate | B21 |
| 22 | human merge gate | B22 |
| 23 | merge not inferred from commit | B23 |
| 24 | merge not inferred from clean tree | B24 |
| 25 | M10 blocked without merge | B25 |
| 26 | M10 blocked without M06 PASS | B26 |
| 27 | M10 blocked without Claude PASS | B27 |
| 28 | M10 blocked by governance issue | B28 |
| 29 | M10 allowed only in REAL fixture | B29 |
| 30 | Trial M10 not applicable | B30 |
| 31 | trial closure preserved | B31 |
| 32 | M11 post-completion validation | C32 |
| 33 | M11 failure surfaced | C33 |
| 34 | fix-task rule | C34 |
| 35 | no phase creation | C35 |
| 36 | no milestone creation | C36 |
| 37 | PR package generation | C37 |
| 38 | PR package no execution | C38 |
| 39 | Activity Log evidence | C39 |
| 40 | Version History evidence | C40 |
| 41 | audit trace | C41 |
| 42 | pre-DevBridge baseline read-only | C42 |
| 43 | no automatic restore | C43 |
| 44 | no destructive Git command | C44 |
| 45 | no automatic PR | D45 |
| 46 | no automatic merge | D46 |
| 47 | no automatic next task | D47 |
| 48 | no AI execution | D48 |
| 49 | DB-M30 regression | D49 |
| 50 | DB-M12.4 regression | D50 |
| 51 | DB-GH01 regression | D51 |
| 52 | canonical workbook unchanged during tests | D52 |
| 53 | Nexus source unchanged | D53 |
| 54 | build 0 errors | D54 |

Regression child suites: DB-M30 (`Test-DbM30SupervisedWorkflow.ps1`, recorded
314/0), DB-M12.4 (`Test-DBM124TrialCycleClosure.ps1`, recorded 54/54), DB-GH01
(`Test-DBM10CompletionEligibility.ps1` + `Get-ProtectedRoadmapFingerprint.ps1`
fingerprint unchanged). Frozen files (DB-M14..M30 + DB-M18.1) re-verified
byte-identical.

---

## 5. Boundaries / overlap

- **Lane A / DB-GH01**: the existing four writers and the fingerprint gate are
  consumed READ-ONLY as the contract DB-M31 documents and proves on fixtures.
  DB-M31 modifies none of them (external finding 1 is reported, not fixed).
- **DevBridge.Engine (C#)**: consumed READ-ONLY as the semantic authority for
  the Git gate vocabulary and M10 gate order; DB-M31 does not modify `src/`.
- **DB-M30**: frozen files untouched; DB-M30's suite is a child regression.
- **Nexus**: never written. The live workbook and Nexus source are byte-identical
  before/after the DB-M31 run (D52/D53).
