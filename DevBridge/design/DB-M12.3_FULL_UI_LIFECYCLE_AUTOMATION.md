# DB-M12.3 -- Full UI Lifecycle Automation

Milestone: DB-M12.3 - Date (UTC): 2026-08-31 - Lane C operator console
(temporary DevBridge scaffolding for Nexus Phase 1/2; retired with DevBridge,
nothing migrates into Nexus).

## Objective

Make the DevBridge operator console the **complete operator surface over the
DB-M12.2 hardened backend**: every lifecycle stage from M03 (preflight) through
M11 (workbook validation / periodic Claude review) is visible and operable from
the UI, with the UI **never inventing** an action, stage state, or mode. The
DB-M12.2 backend remains authoritative for every decision; the UI renders and
calls, it does not decide.

Nothing here may become Nexus runtime/architecture/contracts/services/libraries/
infrastructure/dependency. This is proving scaffolding only; after validation a
human restores the pre-DevBridge workbook backup + Nexus baseline.

## Non-negotiable constraints (unchanged through DB-M12.3)

- **Zero-context M05 gate**: COPY_TO_CHATGPT is exposed only when the ChatGPT
  handoff passes the 14-check zero-context validation. A present-but-invalid
  handoff is CHATGPT_HANDOFF_NOT_READY; re-run generation, never copy.
- **M06 fail blocks M07**: a failed verification arms RUN_VERIFICATION only;
  CREATE_CLAUDE_REVIEW_PACKAGE and RECORD_CLAUDE_RESULT stay disabled until
  VERIFICATION_PASSED evidence exists.
- **Git stays human-gated**: CREATE_PR / REVIEW_PR / MERGE_PR /
  RESTORE_REAL_NEXUS_BASELINE are GuidedManual. There is **no automatic merge**
  and no script command may auto-approve/auto-merge.
- **Trial M10 NOT_APPLICABLE**: the trial cycle stops at TRIAL_CYCLE_SAFE_STOP;
  RUN_GOVERNED_COMPLETION is never armed for trial evidence.
- **Real M10 requires human merge evidence**: completion is armed only after a
  confirmed human merge (gitLifecycleState MERGED / READY_FOR_GOVERNED_COMPLETION)
  plus DB-M06 PASS + Claude PASS + preserved protected-roadmap fingerprint.
- **No structural roadmap editing**: the roadmap surface is immutable; M11
  advisory packages are read-only; no UI control performs a roadmap structure
  write.
- **No silent mode switch**: TRIAL vs REAL_NEXUS_DEVELOPMENT is an explicit,
  always-visible banner; the UI has no mode-switch control and no command can
  flip the mode.
- **No automatic AI execution / provider execution**: every action routes through
  the existing backend scripts (OperatorCommandService + ScriptRunner); the UI
  never executes a model or writes the workbook itself.
- **DB-M26 stays a separate, read-only analytics module**: the AI
  Usage / Cost Dashboard tab renders DB-M26's own recorded result
  (state/db-m26-result.json) and opens its design document. It contains no
  lifecycle logic, performs no provider/model execution, and never writes.
- **Pre-DevBridge baseline is display-only**: RESTORE_REAL_NEXUS_BASELINE is a
  guided human action; the UI can never auto-restore the baseline.

## Lifecycle visualization (12 stages x 8 tokens, backend-derived)

`StageDisplayResolver` resolves the 12 stage keys in mission order from
`NextActionEngine` stage state, using an 8-token vocabulary:

`NOT_STARTED · READY · CURRENT · PASS · FAIL · BLOCKED · HUMAN_ACTION ·
NOT_APPLICABLE`

- PREFLIGHT, RESERVATION, CHATGPT_HANDOFF, IMPLEMENTATION, VERIFICATION,
  CLAUDE_REVIEW_PACKAGE, CLAUDE_REVIEW, CORRECTION, HUMAN_GIT_GATE,
  GOVERNED_COMPLETION, WORKBOOK_VALIDATION, PERIODIC_WORKBOOK_REVIEW.
- Trial mode renders HUMAN_GIT_GATE and GOVERNED_COMPLETION as NOT_APPLICABLE.
- Exactly one stage may be CURRENT in an active cycle.
- CLAUDE_REVIEW_PACKAGE is PASS when the review packet artifact exists, READY
  when verification is complete but the packet is not yet assembled.
- The VM renders exactly the resolver's rows (keys + tokens) -- the UI never
  invents a stage state.

## Next-action panel (backend driven)

`Instruction`, `InstructionSub`, `Failure`, `Residuals`, and the enabled button
set all come from `NextActionEngine.Evaluate(StateReader.Read(cfg))`. Buttons
are armed exactly to `next.EnabledButtons`, and **only after** the Refresh busy
flag is cleared, so the operator console is operable whenever idle.

## Double-click / busy protection

- A `CommandConcurrencyGuard` refuses a second governed command while one runs.
- While a governed command runs, every lifecycle button is visually disabled.
- The Refresh sequence clears the busy flag **before** arming buttons, so the
  idle console always has its engine-grounded buttons enabled (a defect found and
  fixed during recovery: buttons were being armed while `IsBusy` was still true,
  which left the console permanently disabled).

## DB-M12.3 acceptance suite (src/DevBridge.UITests, console runner)

65 checks, WPF headless launch smoke included. Coverage:

- UI launch (Application + App resources + MainWindow construction)
- TRIAL / REAL banner + badge + brush (never silently switches)
- 12-stage / 8-token lifecycle, backend-derived (VM.Stages == resolver rows)
- backend-driven next action + button enablement (VM == engine)
- M03..M11 callable wiring through the operator catalog (script commands +
  read-only observation/advisory commands)
- M05 zero-context handoff gate (invalid -> COPY disabled)
- M06 fail blocks M07 / M06 pass arms M07
- Trial safe-stop + M10 trial NOT_APPLICABLE (availability vocabulary)
- Real human Git gates (PR / review / merge GuidedManual ->
  MANUAL_ACTION_REQUIRED) + no auto merge + merge prerequisite for completion
- M10 real edge cases (no verification -> blocked; roadmap fingerprint drift ->
  blocked)
- M11 callable + advisory + fix policy + baseline read-only + retirement state
- Writer-busy (WORKBOOK_WRITER_BUSY), stale state (STALE_GOVERNANCE_STATE),
  backend mismatch (BACKEND_STATE_MISMATCH), double-click guard
- Task history (never hides failed attempts), parallel view (repository never
  guessed), DB-M26 separate read-only module
- Every fixture write lives under %TEMP% -- the real workbook / Nexus.Developer
  / live trial evidence are never touched by the suite.

## Outputs

- design/DB-M12.3_FULL_UI_LIFECYCLE_AUTOMATION.md
- state/db-m12-3-result.json
- tasks/DB-M12.3_IMPLEMENTATION_REPORT.md
- tasks/DB-M12.3_INTERRUPTION_RECOVERY.md (recovery evidence)
