# DevBridge — OPERATOR GUIDE

> DB-M34 output · 2026-09-02 · DevBridge is **TEMPORARY, SUPERVISED** scaffolding
> for Nexus Phase 1/2. It never executes a model, never opens ChatGPT/Claude, never
> creates/approves/merges a PR, never writes roadmap structure, and never restores
> the pre-DevBridge baseline. **You are the operator; DevBridge guides and gates.**

This guide is the simple operating order for a supervised task. Read
`DEVBRIDGE_TRIAL_VS_REAL.md` first if you are unsure whether the environment is
TRIAL or REAL — the two differ at steps 16–18.

---

## 0. Where things live

| Thing | Location |
|---|---|
| Operator console (WPF) | `src/DevBridge.UI` — run `dotnet run --project src\DevBridge.UI` (or launch the built `DevBridge.UI.exe`) |
| Terminal workflow guide (CLI) | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\supervised-workflow\Show-DbM30SupervisedWorkflow.ps1` |
| Terminal recovery panel (CLI) | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\recovery-safety\Show-DbM32EssentialSafety.ps1` |
| Backend scripts | `scripts\*.ps1` (one governed command per file) |
| Lifecycle state | `state\current-task.json`, `state\*.json` (evidence/state only — **not** authority) |
| Authoritative workbook | `C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx` (Excel is authority) |
| Current task artifacts | `tasks\` (handoff, verification, review package, …) |
| Per-change evidence | `logs\tasks\<node>\<change>\` |

Every backend command is invoked as
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\<command>.ps1`.
Every command **always exits 0**; read the **stdout markers** (e.g. `DB04_OUTCOME`,
`DB06_OUTCOME`, `VERDICT=…`, `next=…`) for the real outcome.

---

## The 20-step operating order

### 1. Start DevBridge
Open the operator console (WPF) or run the `Show-DbM30SupervisedWorkflow.ps1`
terminal guide. The console derives everything from `state\` — it never invents a
stage or an action.

### 2. Check Trial/Real mode
Read the mode banner/token. It is either `TRIAL` or `REAL_NEXUS_DEVELOPMENT`
and comes from `config/devbridge.json` / `state/current-task.json`. There is no
silent switch and no UI control flips it. **Do not proceed on a mode you did not
explicitly verify.**

### 3. Check workbook health
Confirm the canonical workbook is reachable and its protected-roadmap fingerprint
is the recorded one:
`powershell -File scripts\Get-ProtectedRoadmapFingerprint.ps1` → compare the value
with `state/roadmap-fingerprint.json`. A fingerprint change before any write is a
governance signal — stop and investigate.

### 4. Start / resolve the next task
When no task is current, run M03 preflight to surface the next governable task.
If DevBridge reports a **recovery/governance block** (see step 19), resolve it
first. The current live position (M-07-0.2 at DB-M34) is a container that must
never be implemented directly — M03 selects an *implementable leaf*.

### 5. Run M03 — governed preflight
`powershell -File scripts\Get-NextTask.ps1`
`powershell -File scripts\Test-DevelopmentPreflight.ps1`
Writes `state/preflight.json`, `tasks/NEXT_TASK.md`, `tasks/PREFLIGHT_REPORT.md`
and sets the current task to `PREFLIGHTED`.
Accept only a `verdict=CLEAR` on an implementable leaf
(`implementability=IMPLEMENTABLE_LEAF`, `next=RESERVE`). In TRIAL mode a
trial-proven predecessor may satisfy a dependency **via the trial overlay only**;
in REAL mode the overlay is never applied.

### 6. Run M04 — reservation
`powershell -File scripts\Reserve-DevelopmentChange.ps1`
This is a governed **workbook write**: it backs up the workbook, appends Active
Changes + Activity Log rows, records the Git baseline, and sets `RESERVED` with a
`changeId`. Expect an idempotency marker (`REUSED`) if you re-run after a crash —
never force a duplicate reservation.

### 7. Generate the M05 handoff
`powershell -File scripts\New-ChatGptHandoff.ps1`
Freshly validates the reservation against the live workbook, embeds the DB-M18.1
dependency development context (what dependent earlier work actually delivered,
fresh or honestly stale), and writes `tasks/CHATGPT_HANDOFF.md`. It sets the task
to `AWAITING_CHATGPT_PROMPT`. A handoff that fails its zero-context check is
`CHATGPT_HANDOFF_NOT_READY` — regenerate, never copy an invalid handoff.

### 8. Copy to ChatGPT
**Human step.** Copy the handoff to ChatGPT. ChatGPT returns an implementation
prompt. DevBridge never calls ChatGPT.

### 9. Copy the ChatGPT prompt to Claude Code / DeepSeek
**Human step.** Copy the produced prompt (and `tasks/DEEPSEEK_PROMPT.md`
placeholder) to the external implementation tool. DevBridge never executes it.

### 10. Return the implementation result
**Human step.** Bring the implementation result back (files changed, evidence,
tests/build output). Register the result so M06 can verify it (see the operator
console / M05 → implementation registration flow).

### 11. Run M06 — verification
`powershell -File scripts\Run-Verification.ps1`
Deterministically verifies the registered implementation. **M06 independently
verifies; an implementation self-report is never trusted as PASS.** Only on
`VERIFICATION_PASSED` may you proceed. On `VERIFICATION_FAILED`, fix and re-verify.

### 12. Generate M07 — Claude review package
`powershell -File scripts\New-ClaudeReviewPackage.ps1`
Builds a focused review package (`CLAUDE_REVIEW_PACKAGE.md` +
`logs/tasks\<node>\<change>\`) with the dependency-context and Trial/Real
distinction. Only after M06 PASS (a failed verification blocks M07).

### 13. Send to Claude
**Human step.** Send the review package to Claude. DevBridge never calls Claude.

### 14. Record the M08 result
`powershell -File scripts\Set-ClaudeReviewResult.ps1`
Record the decision you received: `PASS`, `FIX`, `GOVERNANCE_ISSUE`, or
`HUMAN_DECISION_REQUIRED`. M08 writes `state/claude-review.json` and transitions
the task. The console disables this until real evidence exists.

### 15. Run correction if required
If the decision is `FIX`:
`powershell -File scripts\New-CorrectionContext.ps1`
then re-run M06 (step 11) and M07 (step 12) until PASS. Corrections stay focused
on the current attempt — a defect found after completion is a *new fix task*, not
a silent re-open.

### 16. REAL mode — human Git gates
**REAL mode only (TRIAL stops at step 17).** DevBridge observes Git read-only
(`scripts\Get-GitGateState.ps1`) and reports the gate position from evidence
(`AWAITING_HUMAN_PR / PR_OPEN / AWAITING_HUMAN_REVIEW / AWAITING_HUMAN_MERGE /
MERGED / READY_FOR_GOVERNED_COMPLETION`). The **human** creates the PR, reviews it,
and merges it. DevBridge never creates/approves/merges a PR and never infers a
merge.

### 17. M10 — completion
`powershell -File scripts\Test-DBM10CompletionEligibility.ps1`
- **TRIAL mode:** M10 is not applicable — `TRIAL_COMPLETION_NOT_APPLICABLE`. The
  cycle stops at `TRIAL_CYCLE_SAFE_STOP`, then close it:
  `powershell -File scripts\Close-TrialCycle.ps1` → `TRIAL_CYCLE_CLOSED`.
- **REAL mode:** M10 is eligible only after DB-M06 PASS + Claude PASS + a
  **confirmed human merge** + a preserved protected-roadmap fingerprint. Any miss
  yields a specific `BLOCKED_*` token.

### 18. M11 — validation (REAL completion)
`powershell -File scripts\Invoke-WorkbookValidation.ps1`
After a governed completion, validate the workbook (`CONTROL_VALIDATED`).
TRIAL closure does not use M11.

### 19. Recovery / governance blocks
When DevBridge shows a block, read the token and the recovery panel:
`powershell -File scripts\recovery-safety\Show-DbM32EssentialSafety.ps1`.
See `DEVBRIDGE_ERROR_RECOVERY_REFERENCE.md` for what each token means, what to do,
and what **not** to do. The recovery panel always gives a specific recommended
human action (REFRESH STATE, RE-RUN VERIFICATION, RECORD CLAUDE RESULT AGAIN,
REVIEW WORKBOOK READ-BACK, REVIEW GIT STATE, HUMAN GOVERNANCE REVIEW) — never a
generic message. DevBridge never silently retries, overwrites, or rolls back.

### 20. Trial closure vs real completion — know the difference
- **TRIAL:** disposable proving. Ends `TRIAL_CYCLE_SAFE_STOP` → `CLOSE_TRIAL_CYCLE`
  → `TRIAL_CYCLE_CLOSED` / `START_NEXT_CYCLE`. No PR, no merge, no M10. The real
  roadmap node stays `Planned`; trial evidence is `TRIAL_ONLY_UNMERGED`. This is
  **not** completion of real Nexus work.
- **REAL:** real Nexus work. Human Git gates → M10 → M11 → the roadmap node is
  genuinely progressed. REAL is only entered after DB-M34 acceptance and the
  human-authorized pre-DevBridge baseline restoration.

---

## Golden rules

1. **Excel is authority.** JSON/UI/cache are evidence/state only.
2. **The protected roadmap is immutable.** No phase/milestone/order/goal/
   acceptance-criteria/dependency write is possible.
3. **No autonomy.** No automatic model execution, retry, escalation, PR, review,
   merge, next task, or autonomous loop. DevBridge recommends; you execute
   externally.
4. **M10 is never run for a trial.**
5. **Secrets never appear.** Config holds env-var names only; console/HTML/logs
   render `CONFIGURED`/`NOT_CONFIGURED` at most.
6. **If in doubt, run the recovery panel and follow its specific instruction.**
