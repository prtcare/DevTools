# DB-M12.2 -- Reusable Lifecycle Backend Commands

Milestone: DB-M12.2 - Date (UTC): 2026-08-31 - Lane C backend surface (temporary DevBridge scaffolding for Nexus Phase 1/2; retired with DevBridge, nothing migrates into Nexus).

## Objective

Convert the DB-M12.1 **guided-manual** lifecycle commands into a **reusable,
generic, governed backend command surface**. Every lifecycle action in the
DB-M03..DB-M11 pipeline now has a durable, identity-agnostic entry point that
operates on the CURRENT task in state/current-task.json, routes the lifecycle
correctly, writes only execution-state evidence through hardened governance, and
reports success the DevBridge way: **state-first** (expected marker + evidence +
state transition + no prohibited side effects), never exit code alone.

Nothing here may become Nexus runtime/architecture/contracts/services/libraries/
infrastructure/dependency. This is proving scaffolding only; after validation a
human restores the pre-DevBridge workbook backup + Nexus baseline.

## Command surface

DB-M12.2 **adds** nine reusable script-backed commands and keeps the three
already-safe DB-M12.1 automated commands (START_PREFLIGHT, RESERVE_TASK,
CREATE_CHATGPT_HANDOFF) unchanged. Command names and contracts reuse the
DB-M12.1 vocabulary; no competing command-result framework was invented.

| CommandId | Backend script | RequiredStates | ResultingExpectedState | WritesWorkbook |
|---|---|---|---|---|
| RUN_VERIFICATION | Run-Verification.ps1 | identity required | VERIFIED | no |
| CREATE_CLAUDE_REVIEW_PACKAGE | New-ClaudeReviewPackage.ps1 | {VERIFIED} | VERIFIED | no |
| RECORD_CLAUDE_RESULT | Set-ClaudeReviewResult.ps1 | {VERIFIED} | routed | no |
| CREATE_CORRECTION_CONTEXT | New-CorrectionContext.ps1 | {DB_M09_FIX_REQUIRED} | DB_M09_FIX_REQUIRED | no |
| RUN_GOVERNED_COMPLETION | Complete-GovernedCycle.ps1 | {CLAUDE_REVIEW_PASSED_TRIAL, CLAUDE_REVIEW_PASSED_REAL, AWAITING_HUMAN_PR, PR_OPEN, AWAITING_HUMAN_REVIEW, AWAITING_HUMAN_MERGE, MERGED, READY_FOR_GOVERNED_COMPLETION} | COMPLETION_WRITTEN | yes |
| VALIDATE_WORKBOOK | Invoke-WorkbookValidation.ps1 | {COMPLETION_WRITTEN} | CONTROL_VALIDATED | no |
| CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE | New-ClaudeWorkbookReviewPackage.ps1 | any | advisory | no |
| REFRESH_GIT_GATE_STATE | Get-GitGateState.ps1 | any | observation | no |
| GET_CURRENT_LIFECYCLE_STATE | Get-CurrentLifecycleState.ps1 | any | observation | no |

Full catalog stays 29: 12 Script + 5 GuidedManual (CREATE_PR, REVIEW_PR,
MERGE_PR, REVIEW_GOVERNANCE_ISSUE, RESTORE_REAL_NEXUS_BASELINE -- all honestly
human) + 8 Navigation + 4 Clipboard.

## One-command contract (reused from DB-M12.1)

Input: `CommandId, NodeId, ChangeId, Mode, Parameters, ExpectedCurrentState,
Actor, CorrelationId` (LifecycleCommandInput.cs).

Output: `CommandId, Status, PreviousState, CurrentState, NextAllowedAction,
ResultCode, EvidenceReferences, WorkbookModified, NexusSourceModified,
GitModified, RequiresHumanAction, HumanActionType, StartedAtUtc, CompletedAtUtc,
Errors, Warnings`.

## Engine orchestration (OperatorCommandService.cs)

1. Input validation: known CommandId; task-identity match for commands that
   require it; Mode must equal the derived mode (no implicit switch);
   Actor >= 2 chars.
2. GuidedManual / Navigation / Clipboard -> MANUAL_ACTION_REQUIRED with the
   recorded reason (never fabricated as an automatic run).
3. Stale-state guard: ExpectedCurrentState != current status ->
   STALE_GOVERNANCE_STATE.
4. RequiredStates gate -> BLOCKED (no script invoked).
5. Writer serialization: WritesWorkbook commands acquire the workbook-writer lock
   (WorkbookWriterGate) -> WORKBOOK_WRITER_BUSY while a live writer holds it.
6. Run scripts and classify: timeout -> BLOCKED; governed STOP_* token ->
   BLOCKED; nonzero exit -> FAILED; DB0X_RESULT_PASS False -> BLOCKED.
7. Refresh state and validate the declared transition. Refreshed state did not
   reach ResultingExpectedState -> FAILED with IsBackendStateMismatch
   (BACKEND_STATE_MISMATCH). M10 hardening: a WritesWorkbook command that
   reports COMPLETED while state is not COMPLETION_WRITTEN is a mismatch.
8. Non-write terminal tokens TRIAL_COMPLETION_NOT_APPLICABLE and
   NO_ADVISORY_REVIEW_RECOMMENDED are valid successes (no write happened).

## Backend script contract

- **Always exits 0.** Outcomes are communicated ONLY on stdout via markers:
  `DB0X_OUTCOME: <TOKEN>`, `DB0X_RESULT_PASS: True|False`,
  `DB0X_RESULT_CODE`, `DB0X_WORKBOOK_MODIFIED`, `DB0X_NEXUS_SOURCE_MODIFIED`,
  `DB0X_GIT_MODIFIED`, `DB0X_REQUIRES_HUMAN_ACTION`, `DB0X_HUMAN_ACTION_TYPE`,
  repeatable `DB0X_EVIDENCE`. An exit code alone is never trusted.
- Env channel: `DB0X_STATE_DIR` / `DB0X_TASKS_DIR` redirect writes (fixtures),
  plus the one-command channel `DB_COMMAND_INPUT_*`. M10/M11 honor a
  workbook override (`DB10_WORKBOOK_OVERRIDE` / `DB11_WORKBOOK_OVERRIDE`) so the
  authoritative workbook is never the apply target in a fixture.
- ASCII-only source (PS 5.1 no-BOM hazard; em-dashes forbidden).
- Shared array-safe JSON library Set-DevBridgeStateEntry.ps1 uses
  System.Web.Script.Serialization.JavaScriptSerializer (PS 5.1 flattens
  single-element arrays under ConvertTo-Json); mode precedence is
  current-task "mode" -> config -> dbM08/dbM06 trialMode evidence.

## M10 RUN_GOVERNED_COMPLETION (Complete-GovernedCycle.ps1)

- TRIAL mode -> TRIAL_COMPLETION_NOT_APPLICABLE, no write, no evidence (trial
  cycles must not complete).
- REAL mode gates: DB-M06 VERIFICATION_PASSED + Claude PASS + human git merge
  observed (gitLifecycleState MERGED / READY_FOR_GOVERNED_COMPLETION). Each
  unmet gate -> named STOP_* token with HUMAN_ACTION_TYPE (e.g.
  STOP_HUMAN_GIT_MERGE_GATE_PENDING / HUMAN_GIT_MERGE).
- Protected-roadmap fingerprint (config/roadmap-protection.json, 5 sheets) is
  captured before and after; any structural drift ->
  STOP_ROADMAP_STRUCTURE_WRITE_PROHIBITED.
- Real apply: backup under state/backups -> temp copy -> apply
  state/sheet-update-plan.json -> read-back verify on temp -> fingerprint-after
  equal -> atomic Move-Item -> reopen read-back -> roadmap-fingerprint.json +
  completion.json + COMPLETED. Execution-state sheets (Activity Log, Version
  History) are the safe apply targets; protected sheets are never written.
- Duplicate completion for the same changeId -> REUSED (no duplicate evidence,
  no re-write).

## Route semantics

- RECORD_CLAUDE_RESULT: PASS+TRIAL -> CLAUDE_REVIEW_PASSED_TRIAL /
  TRIAL_CYCLE_SAFE_STOP; PASS+REAL -> CLAUDE_REVIEW_PASSED_REAL /
  AWAITING_HUMAN_PR; FIX -> DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT
  (dbM09Required); GOVERNANCE_ISSUE -> GOVERNANCE_ISSUE / HUMAN_GOVERNANCE_REVIEW;
  HUMAN_DECISION_REQUIRED -> HUMAN_DECISION_REQUIRED / HUMAN_DECISION. Invalid
  decisions -> STOP_INVALID_DECISION, no transition. Duplicate decision ->
  REUSED.
- CREATE_CORRECTION_CONTEXT requires DB_M09_FIX_REQUIRED + a FIX decision; writes
  tasks/FIX_CONTEXT.md with verbatim findings + the fix-task rule; preserves the
  current task (status + identity) unchanged; idempotent REUSED.
- GET_CURRENT_LIFECYCLE_STATE is read-only: task identity, mode, status, next
  action, git gate position, M10 eligibility, milestone evidence ->
  state/current-lifecycle-state.json.
- REFRESH_GIT_GATE_STATE is read-only; PR state is observed, NEVER fabricated:
  unavailable PR -> prState UNKNOWN.
- New-ClaudeWorkbookReviewPackage: deterministic advisory (read-only);
  recommended -> packet + ADVISORY_REVIEW_PACKAGE_CREATED, otherwise
  NO_ADVISORY_REVIEW_RECOMMENDED.

## Genericity (no hard-coded identities)

Every reusable script reads the CURRENT task from state/current-task.json; the
suite proves it with generic fixtures (N-01-0.1 / CHG-20260831-0xx) and asserts
(I5) that no prior identity (WI-07-0.2.4 / CHG-20260830-017 / ACT-20260830-018)
is hard-coded in any of the ten scripts. The live trial evidence for
WI-07-0.2.4 / CHG-20260830-017 is a read-only regression fixture: it is never
opened for write.

## Test strategy (45 required tests)

- **Engine suite** (src/DevBridge.Tests/Program.cs, console runner): input
  validation (7 rejections + no backend invoked), stale-state, exit-0 mismatch,
  generic M03/M04/M05, M06/M07, M08 all routes, M09 preservation, M10 trial /
  hardened mismatch / real eligible, M11, DB12/DB13/DB14, availability
  vocabulary (NotApplicable/Blocked/Available/HumanActionRequired/Busy),
  writer serialization, marker parsing, env channel. **371 checks, 0 failed.**
- **PS fixture harness** (scripts/Test-DBM12-2Commands.ps1): drives the real
  scripts through env overrides against throwaway state/tasks dirs and workbook
  copies, parsing DB0X_* markers. S1..S26 cover M06 PASS/FAIL, M07 idempotent,
  M08 all routes + REUSED, M09 task-preserving + REUSED, M10 every gate branch
  + real apply on a workbook copy + REUSED, M11 valid/invalid, DB12 read-only,
  DB13 UNKNOWN, DB14 snapshot. Invariants I1..I6: authoritative workbook
  byte-identical (F520060C...), Nexus git delta zero, live trial evidence
  untouched, DB-M23 files untouched, no hard-coded identities, solution builds.
  **59 checks, 0 failed.**

## Defects found and fixed during verification

1. WorkbookWriterGate.Release never deleted the lock (engine): it passed the
   lock PATH to ReadOwnPid instead of the file content, so ownership never
   matched and locks leaked. Exposed by the writer-serialization tests.
2. Set-DevBridgeStateEntry.ps1 Get-DevBridgeField used `.Contains($key)`, which
   cannot bind on JS-parsed Dictionary[string,object]; fixed to `.ContainsKey`.
3. Complete-GovernedCycle.ps1 strict-mode crashes on optional plan members
   ($op.rows / $op.prepend / $rowSpec.numericCols) -- guarded via
   Get-DevBridgeField.
4. Complete-GovernedCycle.ps1 an empty read-back verification array collapsed
   to $null, then `$null.Count` threw under strict mode -- forced @() context.
5. Get-CurrentLifecycleState.ps1 referenced an unset $script:CurrentTaskPath.
6. Run-Verification.ps1 selftest ordering (auto-discovery ran before the
   selftest branch) and M07/M09/M10 idempotency guards were added in the
   preceding implementation pass.

## Scope discipline

- Modified only DevBridge scaffolding: src/DevBridge.Engine, src/DevBridge.Tests,
  scripts/ (10 reusable scripts + shared library + harness).
- NOT modified: C:\Personal\Nexus.Developer (git delta zero; pre-existing
  untracked/modified Nexus files were already present and unchanged),
  authoritative NEXUS_DEVELOPMENT_CONTROL.xlsx (SHA256 F520060C...
  byte-identical before and after), live state/current-task.json +
  state/claude-review.json (WI-07-0.2.4 / CHG-20260830-017 trial evidence
  untouched), DB-M23 files (scripts/ai-routing, design/ai-routing), the
  authoritative roadmap workbook structure.
- M10 was never run for WI-07-0.2.4. The real Nexus baseline was not restored.
  No UI change was required (full auto UI is DB-M12.3).

## Verification

- Solution build: 0 errors, 0 warnings (DevBridge.Engine / DevBridge.Tests).
- Engine suite: 371/371 PASS.
- Fixture harness: 59/59 PASS (S1..S26, I1..I6).
- Authoritative workbook SHA256: F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884 (unchanged).
