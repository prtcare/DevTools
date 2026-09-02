# DB-M32 -- ESSENTIAL SAFETY, RECOVERY & OPERATIONAL HARDENING: Design

Date: 2026-09-01  |  Lane B  |  Status: DESIGN

Temporary DevBridge scaffolding for Nexus Phase 1/2. DevBridge is NOT part of
Nexus. Nothing implemented in DB-M32 is intended for migration into Nexus. Do
NOT design DB-M32 for Nexus migration.

---

## 1. Purpose and boundary

DB-M32 makes DevBridge safe enough to survive normal operator mistakes,
application restart, interrupted commands, stale state and recoverable failures
while supporting supervised Nexus development.

PRIMARY OBJECTIVE (7 focus areas):
1. Restart / recovery.
2. Operation idempotence.
3. Interrupted-operation detection.
4. Safe state reconciliation.
5. Essential logging / diagnostics.
6. Secret / redaction protection.
7. Operator-visible recovery guidance.

"Nothing more." KEEP THIS MILESTONE SMALL.

- **DB-M32 is a READ-ONLY observation + classification + guidance engine.** It
  NEVER writes live state, never deletes a writer lock, never touches the
  canonical workbook, never runs a git write, never rolls back, never restores a
  baseline, never executes an AI/provider action. It detects, classifies, and
  PREPARES GUIDANCE for the human operator.
- **No automatic rollback.** DB-M32 does NOT perform (and does not propose to
  perform automatically): `git reset --hard`, `git clean`, overwriting the
  canonical workbook from a backup, reverting user source files, deleting
  evidence. Recovery PREPARES GUIDANCE only; the human decides and acts.
- **Pre-DevBridge baseline remains read-only reference.** DB-M32 must not
  restore it. Restoration happens only after DB-M34 acceptance and an explicit
  human decision.
- **No autonomy expansion.** AUTO AI execution = NO, automatic provider
  execution = NO, automatic PR = NO, automatic review = NO, automatic merge =
  NO, automatic next task = NO, autonomous development loop = NO, autonomous
  parallel scheduler = NO.
- **No complexity beyond the 7 focus areas.** DB-M32 does NOT add enterprise
  monitoring, distributed scheduling, complex telemetry or orchestration, a new
  transaction/journal persistence layer, or modifications to existing command
  backends. Existing backends are OBSERVED, never changed.
- **Scope:** DB-M32 writes ONLY under `scripts/recovery-safety/`, `design/`,
  `state/`, `tasks/`. No Lane A / Lane B / Lane C / DB-GH01 / Nexus source is
  modified. **NO PARALLEL_SCOPE_CONFLICT.**
- Known external drifts DBM26 S41 and DBM181 R45 continue to be reported
  separately (see section 8.4). They are NOT DB-M32 failures unless DB-M32
  changes their recorded signatures.

---

## 2. Discovery findings (DB-M32 DISCOVERY, 2026-09-01)

Consolidated from read-only inspection of: DB-M12.2 command backends, DB-M12.3
UI (OperatorCommandService + WorkbookWriterGate + StateReader), DB-M12.4 trial
closure, DB-M30 supervised workflow, DB-M31 workbook/Git engine, lifecycle state
files, current-task state, attempt state, writer lock, backup evidence, audit
trace, operation IDs, backend mismatch handling, stale-state handling, Git-state
refresh, configuration/secrets handling, logging/error reporting.

### 2.1 Which commands may be interrupted

Every command that writes the workbook then writes state (or writes state then
its evidence field) has an interruption window. Kill can land BETWEEN a durable
write and its state tail:

| Command | Write sequence | Interruption window | Re-run behavior today |
|---------|----------------|---------------------|------------------------|
| M04 RESERVE_TASK | workbook append -> `current-task.json` | between replace and state write | **Fails SAFE**: new changeId -> `STOP_RESERVATION_CONFLICT` |
| M05 CREATE_CHATGPT_HANDOFF | md written -> current-task AWAITING -> history copy | any gap | Blocked: `HANDOFF_STATE_STALE` |
| M06 RUN_VERIFICATION | `verification.json` -> current-task VERIFIED | any gap | Safe: re-run overwrites |
| M07 CREATE_CLAUDE_REVIEW_PACKAGE | artifact -> current-task `dbM07` field | artifact written, field not | **REUSED fires BEFORE evidence field** -> evidence gap |
| M08 RECORD_CLAUDE_RESULT | `claude-review.json` -> current-task transition | same | **REUSED gap** -> transition lost |
| M09 CREATE_CORRECTION_CONTEXT | artifact -> current-task `dbM09` field | same | **REUSED gap** |
| M10 RUN_GOVERNED_COMPLETION | atomic replace -> `completion.json` -> current-task | between replace and tails | **DOUBLE-PREPENDS Control Center A2 + duplicate append rows** |
| M11 VALIDATE_WORKBOOK | `workbook-consistency.json` -> current-task | any gap | Safe: re-run overwrites |
| M12.4 CLOSE_TRIAL_CYCLE | atomic replace -> `trial-closure.json` -> current-task | between replace and tails | **AC-Closed guard blocks re-run -> stuck partial** |
| DB13 REFRESH_GIT_GATE_STATE | `git-gate-state.json` | any gap | Safe: overwrite |
| DB14 GET_CURRENT_LIFECYCLE_STATE | `current-lifecycle-state.json` | any gap | Safe: overwrite |
| DB-GH01 BASELINE | read-only | none | PRESERVED_EXISTING guard |

Systemic weakness: **the untethered tail.** The workbook write is atomic and
verified, but the state tail (`current-task.json`, and M10's `completion.json`)
is written AFTER the replace via NON-ATOMIC `WriteAllText`
(`Set-DevBridgeStateEntry`). A kill in that window leaves the workbook durable
but the state stale, and REUSED guards that fire before the evidence field is
written are NOT recovery-safe.

### 2.2 Which states can become ambiguous after restart

1. **`current-task.json` mid-write corruption** -- non-atomic JSON write; a kill
   during write can truncate/corrupt JSON.
2. **Workbook SHA moved with no evidence recording the new SHA** -- if the
   workbook changed and no evidence file records a `WorkbookSha256After` that
   matches, the write state is AMBIGUOUS (WRITE_CONFIRMED vs NOT_APPLIED cannot
   be told apart).
3. **REUSED-guard evidence gaps** -- M07/M08/M09 exit REUSED before writing the
   current-task evidence field; a kill in that window leaves the artifact durable
   but the evidence permanently missing (REUSED is not recovery-safe).
4. **M10 partial completion** -- workbook landed (A2 prepended, rows appended)
   but `completion.json`/current-task not updated -> a re-run double-writes.
5. **M12.4 partial closure** -- workbook closed (AC row = Closed) but
   `trial-closure.json`/current-task stale -> the AC-Closed guard blocks re-run
   -> stuck partial with no guidance.
6. **DB-M31 writer lock stale** -- the DB-M31 fixture engine's lock
   (`WORKBOOK_WRITER_BUSY = lock file exists`) has NO stale recovery: a crash
   between acquire and release leaves the lock forever. (The live
   C# WorkbookWriterGate reclaims dead-PID locks on acquire; the DB-M31 engine
   lock does not.)

### 2.3 Which commands are already idempotent

Already guarded (safe re-run): M04 RESERVED->REUSED, M05 precondition,
M07/M08/M09 REUSED (with the evidence-gap caveat above), M10
COMPLETION_WRITTEN + completion.json REUSED, M12.4 layered
TRIAL_CYCLE_ALREADY_CLOSED, DB-GH01 PRESERVED_EXISTING.
Overwrite-only (safe to re-run, no guard needed): M03, M06, M11, DB13, DB14.
NOT recovery-safe today: M10 tail, M12.4 tail, M07/M08/M09 evidence fields.

### 2.4 Missing recovery evidence

- No journal / operation token couples a workbook write to its state tail.
- No stale-lock recovery for the DB-M31 engine lock.
- No operator-visible recovery classification anywhere; the C# timeout path says
  only "refresh to re-check".
- No standalone diagnostics/audit log file from any command (stdout markers and
  tasks/*.md reports only).

### 2.5 Missing operator guidance

- No SYSTEM RECOVERY STATUS / EXPECTED STATE / OBSERVED STATE / RECOVERY
  CLASSIFICATION / RECOMMENDED HUMAN ACTION surface exists.
- No per-command "safe to retry vs review required" answer is exposed.

### 2.6 Secret leakage risk

LOW and confined. Config holds only env-var NAMES (e.g. `DEEPSEEK_API_KEY`),
no key values. M06 echoes build/test output to `DB06_EVIDENCE`. DB-M32 must
never surface config content, connection strings, tokens, or auth headers, and
must redact its own diagnostics the same way DB-M31 does.

### 2.7 Unnecessary complexity NOT to add

- No new transaction journal for the command backends (would change their
  behavior -- out of scope; DB-M32 observes only).
- No auto-fix / no state writes by DB-M32 itself.
- No live lock deletion (DB-M32 may only CLASSIFY a stale lock and recommend a
  human action).
- No git write, no rollback, no telemetry/monitoring, no scheduler.

---

## 3. Architecture

DB-M32 is a 5-file Lane B engine under `scripts/recovery-safety/`, mirroring the
DB-M30/DB-M31 shape. All 18 required capabilities are implemented by these five
files; DB-M32 itself NEVER writes live state (its only writes are the caller-
supplied `-RenderPath`/`-DiagnosticsPath` outputs and the suite's own
state/tasks outputs).

```
scripts/recovery-safety/
  RecoveryContracts.ps1        vocabulary, ReadOnlyGuard, secret scanner, markers
  RecoveryEngine.ps1           pure view builder: reconcile -> detect -> classify
  RecoveryRender.ps1           self-contained operator recovery panel HTML
  Show-DbM32EssentialSafety.ps1  CLI entry (DB32_* markers, ALWAYS exit 0)
  Test-DbM32EssentialSafety.ps1 49-scenario matrix (A1-N4)
```

Data flow:

```
 state/*.json  +  logs\workbook-writer.lock  +  canonical workbook SHA (read-only)
        +  git (read-only)  +  config/... (names only, redacted)
                    |   read
                    v
   [1] RECONCILE   build the observed system picture, one view per lane
                    |
                    v
   [2] DETECT      six interrupted-operation rules over observed state
                    |
                    v
   [3] CLASSIFY    seven recovery classifications per lane condition
                    |
                    v
   [4] GUIDE       operator recovery panel: SYSTEM RECOVERY STATUS / LAST
                   OPERATION / EXPECTED STATE / OBSERVED STATE / CLASSIFICATION
                   / RECOMMENDED HUMAN ACTION  (6 example actions)
                    |
                    v
   [5] REPORT      DB32_* stdout markers + optional diagnostics + HTML panel
```

### 3.1 Vocabulary (RecoveryContracts.ps1)

- `New-DbM32ReadOnlyGuard` -- `AutoExecutionEnabled = $false`, provider
  execution disabled, network = none. Mirror of DB-M30/DB-M31 guard.
- `Test-DbM32SecretLeak` -- scans every value the engine will render/log; on
  leak -> `DB32_SECRET_SCAN: FAIL` + exit 0. Exempt names are the same
  vocab/coverage metadata fields DB-M31 exempts (SHA/hash/token fields,
  RecommendedTitle/RecommendedBody/Plan/Operations/Scope/Config object NAMES).
- `Out-DbM32Markers` -- DB32_OUTCOME / DB32_RECOVERY_CLASSIFICATION /
  DB32_SYSTEM_RECOVERY_STATUS / DB32_LAST_OPERATION / DB32_SECRET_SCAN /
  DB32_AUTO_EXECUTION_ENABLED: False / DB32_REQUIRES_HUMAN_ACTION /
  DB32_WORKBOOK_MODIFIED: False / DB32_GIT_MODIFIED: False /
  DB32_NEXUS_SOURCE_MODIFIED: False.
- Shared enums as plain arrays of strings (PS 5.1 has no enum literals).

### 3.2 Reconciliation (RecoveryEngine.ps1, stage 1)

`Get-DbM32ReconciledView -Root -WorkbookPath -RepositoryPath -NowUtc` reads ONLY:

| Source | Fields observed | Read-only |
|--------|-----------------|-----------|
| `state/current-task.json` | taskId, changeId, status, nextAllowedAction, evidence fields (dbM07/dbM08/dbM09), workbookSha, gitHead | yes |
| `state/current-lifecycle-state.json` | mode, lifecycle state, m10Eligibility, evidence | yes |
| `state/preflight.json`, `reservation.json`, `verification.json`, `claude-review.json`, `completion.json`, `trial-closure.json`, `trial-proving-history.json`, `pre-devbridge-baseline.json` | per-lane evidence + recorded SHA | yes |
| `logs\workbook-writer.lock` | existence, pid, acquired, owner | yes |
| canonical workbook | SHA-256 (stream read only) | yes |
| git (repo at -RepositoryPath) | `rev-parse --abbrev-ref HEAD`, `rev-parse HEAD`, `status --porcelain` | yes (read-only invocations only) |
| `config/providers.json`, `models.json`, `ai-routing.json` | provider/model ENABLED / CONFIGURED booleans ONLY | yes |

Every observed fact is captured into one `$View` object; every value that will
be rendered is passed through `Test-DbM32SecretLeak` before it is allowed into
the view. **Nothing is written by stage 1.**

### 3.3 Interrupted-operation detection (stage 2)

Six deterministic rules. Each rule maps a concrete observable condition to a
token. Detection is pure comparison over the reconciled view; NO inference.

| Token | Trigger condition (all observable) |
|-------|-------------------------------------|
| `RESERVATION_STARTED_BUT_UNVERIFIED` | `reservation.json` absent AND current-task taskId set AND workbook Active Changes has a reservation row whose changeId matches current-task changeId |
| `WORKBOOK_WRITE_STARTED_BUT_READBACK_MISSING` | workbook SHA differs from every recorded `WorkbookSha256After`/`postWorkbookSha256` in state evidence AND no evidence file records the current SHA |
| `VERIFICATION_STARTED_BUT_RESULT_MISSING` | `verification.json` absent AND current-task status implies a verification transition pending AND no `VERIFIED`/`VERIFICATION_PASSED` evidence |
| `CLAUDE_RESULT_RECORDING_INTERRUPTED` | `claude-review.json` absent AND current-task evidence field `dbM08` absent AND a CLAUDE package artifact exists in `logs/tasks/` |
| `TRIAL_CLOSURE_STARTED_BUT_UNVERIFIED` | workbook's Active Changes reservation row for current change = Closed AND `trial-closure.json`/current-task status != TRIAL_CYCLE_CLOSED |
| `COMPLETION_STARTED_BUT_UNVERIFIED` | workbook Control Center A2 prepended AND `completion.json` absent AND current-task status != COMPLETION_WRITTEN |

Each rule is an independent testable function returning `$null` (not raised) or
the token + the observed facts that triggered it. The six rules never fire on
live canonical state (verified clean today); they are proven on fixtures.

### 3.4 Recovery classification (stage 3)

Seven classifications. Classification is derived from the detected tokens +
operation identity + workbook/lock verdicts, by a pure table lookup. DB-M32
NEVER acts on a classification; it only reports it and recommends a human action.

| Classification | Meaning | Human action example |
|----------------|---------|----------------------|
| `SAFE_TO_RESUME` | Op identity `same-op-retried`, workbook write NOT_APPLIED or CONFIRMED, no ambiguity | Resume the op |
| `SAFE_TO_RETRY` | Command in the safe-retry catalog, no evidence gap, no lock | Re-run the command |
| `REFRESH_REQUIRED` | State files stale vs observed (git HEAD/PR, or lifecycle snapshot) | REFRESH STATE |
| `READBACK_RECONCILIATION_REQUIRED` | Workbook write started but read-back evidence missing | REVIEW WORKBOOK READ-BACK |
| `HUMAN_REVIEW_REQUIRED` | Ambiguity (WRITE_STATE_AMBIGUOUS), evidence gap, or unsafe re-run | Human review; RECORD CLAUDE RESULT AGAIN / REVIEW GIT STATE |
| `GOVERNANCE_REVIEW_REQUIRED` | STALE_GOVERNANCE_STATE, governance block, or prohibited action | HUMAN GOVERNANCE REVIEW |
| `DO_NOT_RETRY` | Double-write hazard proven (M10/M12.4 tail), destructive risk, or unknown | Do not re-run; human review |

### 3.5 Operation identity (part of stage 2/3)

Five identities, assigned from the reconciled view:

| Identity | Determination |
|----------|---------------|
| `same-op-retried` | evidence file for the op exists with matching OperationId/changeId and the observed end state matches |
| `new` | no evidence, no partial workbook effect |
| `stale` | evidence exists but references an older changeId/workbook SHA than observed |
| `wrong-task` | current-task changeId differs from the evidence's changeId (EvidenceApplies rule: both empty or matching) |
| `completed` | op end state already durably recorded (REUSED-compatible) |

### 3.6 Workbook recovery verdict (stage 3)

Over the workbook SHA + recorded evidence:

| Verdict | Condition |
|---------|-----------|
| `WRITE_CONFIRMED` | current workbook SHA == a recorded `WorkbookSha256After`/`postWorkbookSha256` for the current op |
| `WRITE_NOT_APPLIED` | current workbook SHA == the recorded pre-write SHA (`WorkbookSha256Before` / preflight SHA / baseline SHA) and no write evidence for a newer SHA |
| `WRITE_STATE_AMBIGUOUS` | current workbook SHA differs from both -> cannot tell applied vs not -> **HUMAN_REVIEW_REQUIRED**, NO auto overwrite, NO inference |

### 3.7 Writer-lock recovery verdict (stage 3)

Over `logs\workbook-writer.lock`:

| Verdict | Condition |
|---------|-----------|
| `ACTIVE_WRITER` | lock exists, pid alive |
| `STALE_WRITER_RECORD` | lock exists, pid NOT alive |
| `UNKNOWN_WRITER_STATE` | lock exists, pid unreadable/empty |

DB-M32 does NOT delete the lock. It reports the verdict; for
`STALE_WRITER_RECORD` it recommends the human verify no writer is running and
reclaim per the DB-M12.3 gate rules. No tight retry loop.

### 3.8 Git recovery (stage 4, read-only)

- Refreshes branch / HEAD / working-tree / PR state ONLY via read-only git
  invocations (`rev-parse`, `log`, `status --porcelain`).
- Compares observed HEAD/PR against recorded evidence; mismatch -> report
  `gitHead` drift under EXPECTED vs OBSERVED.
- **Never infers remote state.** Remote PR state stays UNKNOWN unless a real
  observation says otherwise. Recommended action: REVIEW GIT STATE.

### 3.9 Operator recovery panel (stage 4, RecoveryRender.ps1)

Self-contained HTML (UTF-8 no-BOM, no external assets, WriteAllText only
library write -- the DB-M31 renderer pattern). Sections:

```
SYSTEM RECOVERY STATUS            OK / ATTENTION REQUIRED / AMBIGUOUS / STALE
LAST OPERATION                    command name + OperationId + timestamp
EXPECTED STATE                    state the command should have produced
OBSERVED STATE                    what reconciliation actually found
RECOVERY CLASSIFICATION           one of the 7 values
RECOMMENDED HUMAN ACTION          one of: REFRESH STATE, RE-RUN VERIFICATION,
                                  REVIEW WORKBOOK READ-BACK, RECORD CLAUDE RESULT
                                  AGAIN, REVIEW GIT STATE, HUMAN GOVERNANCE REVIEW
                                  (never a generic "something went wrong")
```

Safe-retry catalog: `RUN_PREFLIGHT`, `RESERVE_TASK`, `CREATE_CHATGPT_HANDOFF`,
`REGISTER_IMPLEMENTATION_RESULT`, `RUN_VERIFICATION`,
`CREATE_CLAUDE_REVIEW_PACKAGE`, `RECORD_CLAUDE_RESULT`,
`CREATE_CORRECTION_CONTEXT`, `REFRESH_GIT_GATE_STATE`, `RUN_GOVERNED_COMPLETION`,
`VALIDATE_WORKBOOK`, `CLOSE_TRIAL_CYCLE`. Only commands whose detected state
proves SAFE_TO_RETRY show RETRY; everything else shows REVIEW REQUIRED.

### 3.10 Backend-state mismatch (stage 3)

`Test-DbM32BackendStateMismatch` (same string-compare semantics as
`Test-DbM31BackendStateMismatch`): claimed success && expected result state &&
observed state != expected -> `BACKEND_STATE_MISMATCH`. On restart with a
mismatch, DB-M32 preserves the mismatch (exit success + expected transition
absent) and classifies `REFRESH_REQUIRED` / `HUMAN_REVIEW_REQUIRED`.

### 3.11 Stale governance (stage 3)

`STALE_GOVERNANCE_STATE` preserved: if recorded `ExpectedBeforeSha`/governance
input does not match the fresh read, DB-M32 reports the stale governance state
verbatim and lets the operator decide. No silent overwrite.

### 3.12 Logging / diagnostics (stage 5)

Diagnostics record, per op: timestamp, operation ID, task/change, mode,
lifecycle before/after, result, failure category, recovery classification,
workbook SHA, git HEAD. No secret material (redaction is a hard gate before any
line is emitted). `-DiagnosticsPath` is caller-supplied; default state.

### 3.13 Secret redaction (Contracts)

Every value rendered or logged passes `Test-DbM32SecretLeak`. Config
providers/models are rendered ONLY as `CONFIGURED` / `NOT_CONFIGURED` /
`ENABLED` / `DISABLED`. No API keys, tokens, auth headers, connection secrets,
or provider credentials ever appear. `DB32_SECRET_SCAN: FAIL` + exit 0 on any
leak.

### 3.14 Crash / restart fixtures (test suite)

Fixture-only simulation (the suite does NOT crash the real machine): stale
writer lock (write a fixture lock with a dead pid), externally-changed workbook
(temp copy mutated to a different SHA), changed Git HEAD (temp repo checked out
to a different commit), interrupted op states (fixture state roots missing each
of the six tails). Each fixture asserts the correct token / classification /
panel output.

### 3.15 No automatic rollback (invariant)

Asserted by tests: no path in DB-M32 can issue `git reset`, `git clean`,
workbook overwrite from backup, source revert, or evidence delete. The engine
contains zero destructive invocations and zero workbook/git write calls. The
only "restore" text is the pre-DevBridge baseline note ("NO RESTORE FUNCTION
EXISTS"), surfaced as guidance only.

---

## 4. Required capabilities -> components map

| # | Required capability | Component |
|---|--------------------|-----------|
| 1 | Startup state reconciliation | `Get-DbM32ReconciledView` (RecoveryEngine stage 1) |
| 2 | Interrupted-operation detection (6 tokens) | six rule functions (stage 2) |
| 3 | Recovery classification (7 values) | classification table (stage 3) |
| 4 | Idempotent governed commands (12) | safe-retry catalog + op-identity rules (3.5, 3.9) |
| 5 | Operation identity (5 values) | identity rules (3.5) |
| 6 | Workbook recovery (3 verdicts) | workbook verdict (3.6) |
| 7 | Writer-lock recovery (3 states, no deletion) | lock verdict (3.7) |
| 8 | Git recovery (refresh read-only, never infer) | git observer (3.8) |
| 9 | Operator recovery panel | RecoveryRender (3.9) |
| 10 | Safe retry (proven-safe only) | catalog + SAFE_TO_RETRY gating (3.9) |
| 11 | Backend state mismatch preserved | `Test-DbM32BackendStateMismatch` (3.10) |
| 12 | Stale governance preserved | stale-governance reporting (3.11) |
| 13 | Logging/diagnostics | diagnostics recorder (3.12) |
| 14 | Secret redaction | `Test-DbM32SecretLeak` (3.13) |
| 15 | Crash/restart fixture tests | 3 fixture families in the suite (3.14) |
| 16 | No automatic rollback | invariant tests (3.15) |
| 17 | Pre-DevBridge baseline read-only | baseline represent-only note (3.15) |
| 18 | No autonomy expansion | `DB32_AUTO_EXECUTION_ENABLED: False` + invariants (3.15) |

---

## 5. Test matrix (49 items, A1-N4)

| Range | Items | Coverage |
|-------|-------|----------|
| A1-A6 | 6 | Interrupted-operation tokens, one per rule (3.3) |
| B1-B7 | 7 | Recovery classifications, one per value (3.4) |
| C1-C5 | 5 | Operation identities (3.5) |
| D1-D3 | 3 | Workbook verdicts, incl. AMBIGUOUS -> HUMAN_REVIEW (3.6) |
| E1-E3 | 3 | Writer-lock verdicts, incl. stale-lock NO-delete (3.7) |
| F1-F2 | 2 | Git refresh read-only + remote never inferred (3.8) |
| G1-G3 | 3 | Safe-retry catalog gates RETRY only when proven-safe (3.9) |
| H1-H3 | 3 | Panel: status, expected/observed, recommended action (no generic text) |
| I1-I2 | 2 | Backend-state mismatch preserved (3.10) |
| J1 | 1 | Stale governance preserved, no silent overwrite (3.11) |
| K1 | 1 | Diagnostics record all required fields, no secret material (3.12) |
| L1-L2 | 2 | Secret redaction: CONFIGURED/NOT_CONFIGURED only; leak -> FAIL+exit0 |
| M1-M3 | 3 | Crash/restart fixtures: stale writer lock, changed workbook, changed HEAD |
| N1-N4 | 4 | Invariants: no rollback capability; baseline read-only; no autonomy; always exit 0 |

Total 49 scenarios. Every scenario asserts the DB32_* stdout marker contract and
exit 0.

---

## 6. Outputs

- `design\DB-M32_ESSENTIAL_SAFETY_RECOVERY_HARDENING.md` (this document).
- `scripts\recovery-safety\` (RecoveryContracts.ps1, RecoveryEngine.ps1,
  RecoveryRender.ps1, Show-DbM32EssentialSafety.ps1,
  Test-DbM32EssentialSafety.ps1).
- `state\db-m32-result.json` -- PASS/FAIL summary (see section 8).
- `state\db-m32-test-run.log` -- 49-scenario run log.
- `tasks\DB-M32_IMPLEMENTATION_REPORT.md` -- implementation report.
- Previous outputs preserved. Live canonical workbook SHA unchanged
  (`6D42C3BF...`); live Nexus source untouched.

---

## 7. Security posture (summary)

- READ-ONLY observation engine; zero workbook/git/state writes by DB-M32.
- No lock deletion, no rollback, no baseline restore, no auto execution, no
  remote inference.
- Recovery PREPARES GUIDANCE only; human gates remain human.
- Secrets never leave the redaction boundary (CONFIGURED/NOT_CONFIGURED only).
- No autonomy expansion; `DB32_AUTO_EXECUTION_ENABLED: False` always.

---

## 8. Final report (DB-M32 RESULT)

`state/db-m32-result.json` reports PASS/FAIL for: Implementation, Startup
reconciliation, Interrupted-operation detection, Recovery classification,
Idempotent critical commands, Operation identity, Workbook recovery, Writer-lock
recovery, Git recovery, Operator recovery panel, Safe retry, Stale-state
handling, Backend-state mismatch, Logging/diagnostics, Secret redaction; "NO"
lines for: Automatic rollback capability, Destructive Git recovery capability,
Automatic baseline restore, AUTO AI execution, Automatic PR, Automatic merge,
Automatic next task, Autonomous development cycle, Autonomous parallel
scheduler; "NO" for Canonical workbook modified during tests and Nexus source
modified; DB-M31 preserved PASS/FAIL (DBM31 191/0 preserved); Tests
Passed/Failed; Build PASS/FAIL + Warnings/Errors; Ready for DB-M33 final
supervised proving: YES/NO; Stop after DB-M32.
