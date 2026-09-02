# DevBridge — ERROR & RECOVERY REFERENCE

> DB-M34 output · 2026-09-02 · Engine: DB-M32 Essential Safety & Recovery
> (PASS 127/127, 49 scenarios). Recovery engine: `scripts\recovery-safety\
> Show-DbM32EssentialSafety.ps1`. **Repository reality is authoritative** —
> DevBridge never silently retries, overwrites, rolls back, or invents a PASS.

## When to use this

A run failed, a session was interrupted, a marker is missing, or DevBridge shows
a token you do not recognize. First rule: **do not re-run commands blindly.**
Read the token, consult this table, run the recovery panel, follow its specific
recommended action.

## Recovery classifications (DB-M32 vocabulary)

| Classification | Meaning | Operator action |
|---|---|---|
| `SAFE_TO_RESUME` | No partial governed write; state is consistent | Resume the interrupted step normally (idempotent commands will reuse) |
| `SAFE_TO_RETRY` | Last action failed cleanly before any side effect | Re-run the failed command once |
| `REFRESH_REQUIRED` | DevBridge state is stale vs workbook/Git evidence | Re-derive state from authoritative evidence (recovery panel "REFRESH STATE") |
| `READBACK_RECONCILIATION_REQUIRED` | A governed write was applied but the read-back check was not confirmed | Re-read the workbook rows and reconcile — do **not** re-apply the write |
| `HUMAN_REVIEW_REQUIRED` | Outcome depends on evidence only a human can confirm | Human reviews the specific artifact named by the panel |
| `GOVERNANCE_REVIEW_REQUIRED` | A governance/roadmap concern surfaced | Human governance review; no implementation continues |
| `DO_NOT_RETRY` | Retrying would duplicate, corrupt, or misrepresent | Investigate root cause first; contact the operator |

## Workbook + lock verdicts

Three workbook verdicts and three lock verdicts are produced by the recovery
engine (see DB-M32 result/design for the full matrix):
- **Workbook:** unchanged / written-and-read-back-ok / needs-reconciliation.
- **Lock:** absent / held-by-this-op / mismatch (`MISMATCH_LOCK_RECOVERY` —
  a writer lock held by a *different* operation means the earlier write may be
  mid-flight: reconcile, never force).

## Canonical error/recovery tokens (DB-M34 Area 17)

For each token: **meaning** / **operator should** / **operator should NOT**.

| Token | Meaning | Operator SHOULD | Operator SHOULD NOT |
|---|---|---|---|
| `WORKBOOK_WRITER_BUSY` | A governed writer lock is held by another operation; a write may be mid-flight | Reconcile via the recovery panel; wait/verify the other op finished | Force a second writer, overwrite, or delete the lock |
| `STALE_GOVERNANCE_STATE` | The M03/governance basis went stale between preflight and use | Re-run M03 preflight fresh (`STOP_PREFLIGHT_STALE` → refresh) | Push a stale preflight through to reservation |
| `BACKEND_STATE_MISMATCH` | Backend/DevBridge state disagrees with workbook or Git evidence | Run the recovery panel; REFRESH STATE from authoritative evidence | Trust the stale JSON; silently re-derive "for convenience" |
| `DEPENDENCY_CONTEXT_STALE` | Dependency lineage context is stale vs live current work | Regenerate fresh dependency context; treat old context as stale | Use stale dependency provenance to satisfy a REAL selection |
| `SCOPE_CHANGE_REQUIRED` | Requested work is out of the reserved scope | Run the governed scope-change path / new reservation | Silently expand the reserved scope |
| `IMPLEMENTATION_TARGET_UNKNOWN` | No registrable implementation target/result exists to verify | Register the real implementation result/artifact first | Verify an empty or invented target; record PASS on nothing |
| `NO_IMPLEMENTABLE_DESCENDANT` | Selected node is a container / has no derivable implementable scope in this mode | Resolve governance/dependency; pick the correct leaf | Implement the container as the task |
| `HUMAN_GOVERNANCE_REQUIRED` | Resolution needs a human governance decision | Make + record the decision (`HUMAN_GOVERNANCE_DECISION`) | Auto-resolve or auto-bypass the governance block |
| `MERGE_STATE_UNKNOWN` | No explicit Git evidence of a PR merge | Confirm the merge from real Git evidence | Infer a merge; proceed past a merge gate on assumption |
| `TRIAL_COMPLETION_NOT_APPLICABLE` | M10 asked while the mode is TRIAL | Close the trial cycle instead (`Close-TrialCycle.ps1`) | Run M10 against a TRIAL |
| `TRIAL_CYCLE_SAFE_STOP` | Trial reached its safe stop after a recorded Claude PASS | Close the trial (`CLOSE_TRIAL_CYCLE`) → `TRIAL_CYCLE_CLOSED` | Treat the trial stop as a REAL completion |
| `TRIAL_CYCLE_CLOSED` | Trial cycle is closed and recorded | Start the next cycle / park for the next proving phase | Re-open or force a second closure write |

## Failure tokens and honest blocks (M03/M05/M06/M10/M12 surface)

| Token | What it means | What to do | What NOT to do |
|---|---|---|---|
| `STOP_PREFLIGHT_STALE` | Preflight basis went stale between preflight and use (governed staleness check) | Re-run M03 preflight fresh | Force the stale reservation through |
| `NO_IMPLEMENTABLE_DESCENDANT` | Selected node is a container with no derivable implementable scope, or dependency not satisfiable in current mode | Resolve governance / dependency, or pick the correct leaf | Implement the container as the task |
| `RESOLVE_GOVERNANCE_BLOCK` | Dependency present but unresolved governance blocks selection | Human governance resolution | Override to make selection pass |
| `SCOPE_CHANGE_REQUIRED` | The requested change is out of the reserved scope | New scope-change path / new reservation | Silently expand scope |
| `CHATGPT_HANDOFF_NOT_READY` | M05 handoff failed its zero-context/validation check | Regenerate the handoff | Copy an invalid handoff |
| `VERIFICATION_FAILED` | M06 independently found the registered evidence does not verify | Fix; correction context (M09); re-run M06 | Record PASS anyway |
| `DB_M09_FIX_REQUIRED` | Claude decision was FIX | Create correction context; correct; re-verify; re-review | Re-open a completed task silently |
| `MERGE_UNCONFIRMED` / `prState=UNKNOWN` | No explicit Git evidence of a merge | Human confirms merge from Git | Infer the merge |
| `BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING` | REAL M10 prerequisite: no confirmed human merge | Merge the PR (human) | Run M10 |
| `BLOCKED_NO_DB_M06_VERIFICATION_PASS` | REAL M10 prerequisite missing | Achieve M06 PASS | Run M10 |
| `BLOCKED_NO_CLAUDE_PASS` | REAL M10 prerequisite missing | Achieve Claude PASS | Run M10 |
| `ROADMAP_STRUCTURE_WRITE_PROHIBITED` | Protected-roadmap fingerprint changed / write attempted | Stop; investigate the change; do not write | Re-run completion |
| `TRIAL_COMPLETION_NOT_APPLICABLE` | M10 asked in TRIAL mode | Close the trial cycle instead (`Close-TrialCycle.ps1`) | Run M10 against a trial |
| `TRIAL_CYCLE_ALREADY_CLOSED` | Idempotent closure guard fired | Reuse the existing closure result | Force a second closure write |
| `WRITE_NOT_APPLIED` | Interrupted-op token: no partial write landed | Safe to resume | Re-apply "for safety" |

## Recommended recovery actions (what the panel tells you)

1. **REFRESH STATE** — re-derive current-task/lifecycle/preflight state from
   evidence. Never edits the workbook.
2. **RE-RUN VERIFICATION** — after M06 failed or was interrupted; deterministic.
3. **RECORD CLAUDE RESULT AGAIN** — the Claude decision exists but was not
   recorded; record it once.
4. **REVIEW WORKBOOK READ-BACK** — reconcile a write whose read-back was not
   confirmed (`READBACK_RECONCILIATION_REQUIRED`).
5. **REVIEW GIT STATE** — confirm/deny a merge from real Git evidence.
6. **HUMAN GOVERNANCE REVIEW** — resolve the governance concern (M03 block /
   dependency / fingerprint).

## Proven failure handling (DB-M33 scenario L, 5/5 PASS)

Stale-governance block, stale dependency context, human-governance container
block, unknown merge state, and writer-lock mismatch recovery were all proven to
produce **honest, specific blocks** — never a forced PASS, never a silent retry.

## Running a suite from an interrupted session

If a milestone test run was interrupted, treat repository/filesystem reality as
authoritative (DB-M33 interruption-recovery method `RESUME_FROM_REPOSITORY_
REALITY`): verify no partial governed write exists (recovery panel), then re-run
the full harness cleanly. Never delete partial evidence or reset state to "make
the run pass."
