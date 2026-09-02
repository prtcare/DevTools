# DB-M12.2 -- Reusable Lifecycle Backend Commands: Implementation Report

Date (UTC): 2026-08-31  |  Lane C  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency.

---

## 1. What this milestone delivered

Nine lifecycle actions that were **GUIDED_MANUAL** in DB-M12.1 are now durable,
identity-agnostic backend commands. Each command reads the CURRENT task from
state/current-task.json, routes the lifecycle correctly, writes only
execution-state evidence, and reports success the DevBridge way: expected marker
+ evidence + state transition + no prohibited side effects (else
BACKEND_STATE_MISMATCH). Exit code alone is never trusted -- backend scripts
ALWAYS exit 0 and communicate outcomes ONLY via stdout markers (DB0X_OUTCOME /
DB0X_RESULT_PASS / DB0X_RESULT_CODE / DB0X_WORKBOOK_MODIFIED /
DB0X_NEXUS_SOURCE_MODIFIED / DB0X_GIT_MODIFIED / DB0X_REQUIRES_HUMAN_ACTION /
DB0X_HUMAN_ACTION_TYPE / DB0X_EVIDENCE).

### 1.1 New reusable command surface

| Command | Script | Behavior |
|---|---|---|
| RUN_VERIFICATION | Run-Verification.ps1 | runs the existing test suite for the current task; PASS -> VERIFIED, FAIL stays put |
| CREATE_CLAUDE_REVIEW_PACKAGE | New-ClaudeReviewPackage.ps1 | writes CLAUDE_REVIEW_PACKAGE.md + REVIEW_PACKET.md; VERIFIED unchanged; REUSED on re-run |
| RECORD_CLAUDE_RESULT | Set-ClaudeReviewResult.ps1 | PASS+TRIAL -> TRIAL_CYCLE_SAFE_STOP; PASS+REAL -> AWAITING_HUMAN_PR; FIX -> DB_M09_FIX_REQUIRED; GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED surface a human action; invalid -> STOP_INVALID_DECISION; REUSED on duplicate |
| CREATE_CORRECTION_CONTEXT | New-CorrectionContext.ps1 | DB_M09_FIX_REQUIRED + FIX decision -> FIX_CONTEXT.md with the fix-task rule; current task preserved; REUSED on re-run |
| RUN_GOVERNED_COMPLETION | Complete-GovernedCycle.ps1 | TRIAL -> TRIAL_COMPLETION_NOT_APPLICABLE; REAL gated on M06 PASS + Claude PASS + human merge observed; fingerprint guard; real apply to execution-state sheets with backup + read-back + atomic replace; REUSED on duplicate |
| VALIDATE_WORKBOOK | Invoke-WorkbookValidation.ps1 | COMPLETION_WRITTEN -> CONTROL_VALIDATED / CONTROL_VALIDATION_FAILED |
| CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE | New-ClaudeWorkbookReviewPackage.ps1 | deterministic read-only advisory; recommended -> packet, else NO_ADVISORY_REVIEW_RECOMMENDED |
| REFRESH_GIT_GATE_STATE | Get-GitGateState.ps1 | read-only observation; PR state NEVER fabricated (unavailable -> UNKNOWN) |
| GET_CURRENT_LIFECYCLE_STATE | Get-CurrentLifecycleState.ps1 | read-only snapshot of task/mode/status/next-action/git-gate/M10 eligibility/evidence |

### 1.2 Engine orchestration (OperatorCommandService)

Input validation -> honest GuidedManual/Manual -> stale-state guard ->
RequiredStates gate -> writer lock (WritesWorkbook only) -> script run +
classification -> refreshed-state validation. M10 hardening: a WritesWorkbook
command reporting COMPLETED while state is not COMPLETION_WRITTEN is a
BACKEND_STATE_MISMATCH. Non-write terminals (TRIAL_COMPLETION_NOT_APPLICABLE,
NO_ADVISORY_REVIEW_RECOMMENDED) are valid successes. The one-command contract
reuses DB-M12.1's LifecycleCommandInput / result model; no competing framework
was invented.

### 1.3 WorkbookWriterGate

Lock file under logs/workbook-writer.lock with PID + timestamp; a live holder
blocks a second writer (WORKBOOK_WRITER_BUSY); a stale lock owned by a dead
process is reclaimed. The Release bug (lock never deleted because the path
string was read as the PID content) was caught by the writer-serialization
tests and fixed.

## 2. Test suite (task #48)

- **Engine suite** (src/DevBridge.Tests/Program.cs, console runner): 371 checks,
  0 failed, 0 warnings. Covers input validation (7 rejections + no backend
  invoked), stale state, exit-0 mismatch, generic M03/M04/M05, M06/M07, M08 all
  routes, M09 preservation, M10 trial/hardened/real, M11, DB12/DB13/DB14,
  availability vocabulary, writer serialization, marker parsing, env channel.
- **PS fixture harness** (scripts/Test-DBM12-2Commands.ps1): 59 checks, 0 failed.
  Drives the real scripts through env overrides against throwaway state/tasks
  dirs and workbook copies:
  - S1..S2  M06 PASS / FAIL on a generic fixture (N-01-0.1 / CHG-20260831-0xx)
  - S3..S4  M07 create + idempotent REUSED
  - S5..S11 M08 PASS trial / REUSED / PASS real / FIX / GOVERNANCE_ISSUE /
            HUMAN_DECISION_REQUIRED / invalid STOP
  - S12..S13 M09 task preserved + REUSED
  - S14..S19 M10 trial not-applicable / merge gate / eligible COMPLETED /
            fingerprint drift / REAL real apply on a workbook COPY
            (backup exists, cell read back, completion evidence) / REUSED
  - S20..S21 M11 valid / invalid
  - S22..S23 DB12 recommended / suppressed (read-only)
  - S24..S25 DB13 MERGED observed / UNKNOWN never fabricated
  - S26       DB14 lifecycle snapshot
  - I1..I6    authoritative workbook byte-identical (F520060C...), Nexus git
              delta zero, live trial evidence untouched, DB-M23 files untouched,
              no hard-coded WI/CHG identity in the scripts, solution builds

## 3. Defects found and fixed (test-driven)

1. **WorkbookWriterGate.Release** (engine): lock never released -- the lock PATH
   was read as the PID content, so ownership never matched. Genuine governance
   defect; fixed.
2. **Set-DevBridgeStateEntry.ps1** Get-DevBridgeField: `.Contains($key)` cannot
   bind on JS-parsed Dictionary[string,object]; fixed to `.ContainsKey`.
3. **Complete-GovernedCycle.ps1**: strict-mode crashes on optional plan members
   ($op.rows / $op.prepend / $rowSpec.numericCols) -- guarded via
   Get-DevBridgeField.
4. **Complete-GovernedCycle.ps1**: empty read-back verification array collapsed
   to $null, then `$null.Count` threw under strict mode -- forced @() context.
5. **Get-CurrentLifecycleState.ps1**: referenced unset $script:CurrentTaskPath.
6. Preceding implementation pass: Run-Verification.ps1 selftest ordering + M07/
   M09/M10 idempotency guards.

## 4. Scope discipline (non-negotiables honored)

- Authoritative workbook C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx
  byte-identical: SHA256 F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884
  before and after.
- C:\Personal\Nexus.Developer not modified (git delta zero; the tracked
  modified workbook + untracked DevelopmentControl files are pre-existing and
  unchanged).
- Live trial evidence for WI-07-0.2.4 / CHG-20260830-017 (state/current-task.json
  + state/claude-review.json) untouched -- used only as a read-only regression
  fixture (CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP).
- DB-M23 files (scripts/ai-routing, design/ai-routing) untouched.
- M10 NOT run for WI-07-0.2.4; WI-07-0.2.4 not continued; no new Nexus work item
  started.
- Real Nexus baseline NOT restored; no phase/milestone/structure/architecture
  change; no generic structural roadmap editing capability added.
- No UI change (full auto UI is DB-M12.3, not started).
- TRIAL vs REAL_NEXUS_DEVELOPMENT mode preserved; no silent mode switch. PR state
  is observed, never fabricated (UNKNOWN when unavailable). Git/PR/merge remain
  human-gated.

## 5. Verification results

- Solution build: 0 errors, 0 warnings.
- Engine suite: 371/371 PASS.
- Fixture harness: 59/59 PASS (S1..S26, I1..I6).
- Exit code of the harness: 0; script markers all read back correctly.

## 6. Outputs

- design/DB-M12.2_REUSABLE_LIFECYCLE_BACKEND.md
- state/db-m12-2-result.json
- tasks/DB-M12.2_IMPLEMENTATION_REPORT.md

**Stop after this milestone. Do NOT start DB-M12.3. Do NOT start another Lane C
task. Do NOT run M10 for WI-07-0.2.4. Do NOT restore the real Nexus baseline.**
