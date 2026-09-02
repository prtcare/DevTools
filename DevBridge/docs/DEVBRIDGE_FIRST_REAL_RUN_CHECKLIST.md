# DevBridge — FIRST REAL RUN CHECKLIST

> DB-M34 output · 2026-09-02 · Use this **only** after the pre-real transition
> (mode = `REAL_NEXUS_DEVELOPMENT`, baseline restoration authorized and done).
> Goal: one complete, human-gated REAL cycle with every gate visibly exercised.
> If any line does not hold, **stop** — do not continue past it.

## 0. Preconditions

- [ ] `Get-DevBridgeMode` resolves mode REAL_NEXUS_DEVELOPMENT (config + current-task).
- [ ] DB-M34 result recorded; operator authorized the transition.
- [ ] Pre-DevBridge baseline reference verified (`state/pre-devbridge-baseline.json`).
- [ ] **Baseline identity confirmed** — the pre-DevBridge workbook backup SHA
      (`F520060C…`) and Nexus git commit (`ea39db91…`) match
      `state\pre-devbridge-baseline.json` before any real step.
- [ ] Protected-roadmap fingerprint health check passes on the restored workbook.
- [ ] **Workbook authority confirmed** — the restored
      `C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx` is the
      authoritative control workbook, fingerprint-matched.
- [ ] **No trial overlay active** — mode resolved REAL; a trial-proven predecessor
      must NOT satisfy any REAL dependency (expect an honest block if one exists).

## 1. M03 — REAL preflight (no trial overlay)

- [ ] `verdict=CLEAR` on an **implementable leaf** (`implementability=IMPLEMENTABLE_LEAF`).
- [ ] Selected node is the smallest implementable leaf past the resolved governance
      block — **not** a container, **not** the current live M-07-0.2 position.
- [ ] **No trial-proven overlay applied.** If a dependency is only trial-satisfied,
      expect an honest `RESOLVE_GOVERNANCE_BLOCK` / `NO_IMPLEMENTABLE_DESCENDANT`
      (DB-M33 scenario E) — resolve it for real, never by switching the overlay on.
- [ ] Preflight writes `state/preflight.json`, `tasks/NEXT_TASK.md`,
      `tasks/PREFLIGHT_REPORT.md`; current task = `PREFLIGHTED`.

## 2. M04 — REAL reservation

- [ ] Real governed reservation on the **live** workbook (backup → Active Changes +
      Activity Log rows → Git-baseline record) with a `changeId`.
- [ ] Re-run is idempotent (`REUSED`) if needed; never a duplicate reservation.

## 3. M05 — handoff

- [ ] `CHATGPT_HANDOFF.md` generated; zero-context check passed
      (`CHATGPT_HANDOFF_NOT_READY` absent).
- [ ] Handoff/context carries **real** dependency lineage (a real predecessor's
      actual delivered scope), not trial provenance.

## 4–5. Human model gates

- [ ] Human copies handoff → ChatGPT → implementation tool.
- [ ] Human registers the returned implementation result for M06.
- [ ] M06 = `VERIFICATION_PASSED` (independent, deterministic; never a self-report).
- [ ] M07 package created; M08 decision recorded: `CLAUDE_REVIEW_PASSED_REAL`.

## 6. REAL human Git gates (DevBridge watches read-only)

- [ ] `git gate = AWAITING_HUMAN_PR` → **human** creates the PR
      (`CREATE_PR`). Verify `PR_OPEN`.
- [ ] Human reviews the PR (`REVIEW_PR`). Verify gate advances.
- [ ] Human merges the PR (`MERGE_PR`). DevBridge reports `MERGED` **only** from
      explicit Git evidence. `prState=UNKNOWN` → do **not** proceed; confirm in Git.

## 7. M10 — real completion eligibility

- [ ] M06 PASS ✅ · Claude PASS ✅ · confirmed human merge ✅ · protected-roadmap
      fingerprint unchanged ✅ → `READY_FOR_GOVERNED_COMPLETION`.
- [ ] Any `BLOCKED_*` token → resolve that specific prerequisite; **never** run
      M10 past a block. (M10 is still `TRIAL_COMPLETION_NOT_APPLICABLE` if the
      mode somehow read TRIAL — stop and fix the mode first.)

## 8. M11 — validation

- [ ] After the governed completion write, `Invoke-WorkbookValidation.ps1`
      returns `CONTROL_VALIDATED`.

## 9. Record + review

- [ ] Real completion recorded with evidence (workbook read-back verified,
      fingerprint preserved).
- [ ] First-real-run retrospective: note any token that appeared where this
      checklist did not predict it — update `DEVBRIDGE_OPERATOR_GUIDE.md` and this
      checklist, do not "handle it silently."

## Stop rules

Any box that does not check → **STOP at that step**, run the recovery panel
(`Show-DbM32EssentialSafety.ps1`), follow its specific instruction, and re-check
before continuing. A first real run that "mostly" passes is a failed first run.
