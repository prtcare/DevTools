# DB-M12.4 -- Governed Trial Cycle Closure & Fresh-Cycle Selection

Date (UTC): 2026-08-31  |  Lane C  |  Milestone: DB-M12.4

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency.

---

## 1. Problem statement

The FINAL HARDENED LANE C TRIAL PART 1 exposed a **governance-state gap**: after
the trial lifecycle for WI-07-0.2.4 reached its governed terminal state
(`CLAUDE_REVIEW_PASSED_TRIAL` / `TRIAL_CYCLE_SAFE_STOP` / `TRIAL_ONLY_UNMERGED`,
with M10 correctly NOT run), M03 (`Get-NextTask.ps1`) auto-selected WI-07-0.2.4
**again**:

- M03 = PASS, Verdict = CLEAR, Selected automatically = YES, Hard-coded task = NO.
- The work item's roadmap row is still `Planned`; its parent M-07-0.2 is
  `In Progress`; Active Changes row 80 (CHG-20260830-017) still classifies
  **Open** because its Status cell reads `Open -- reserved via DB-M04 ...`.
- No governed operation can close that trial reservation: M10 correctly refuses
  (`TRIAL_COMPLETION_NOT_APPLICABLE` for trial evidence).

This is NOT an M03 defect. M03 is behaving exactly as designed: an open
reservation names the parent as current work, and a dependency-satisfied
`Planned` child is the deterministic next candidate. The gap is that the trial
execution state can never be **closed** and the reservation can never be
**released**, so a fresh cycle can never start without repeatedly re-selecting
the same prohibited work item.

## 2. Root cause (probe evidence, 2026-08-31)

Read-only probe `DBM124_probe.ps1` against the canonical workbook
(`F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884`) and the
recorded M04 backup (`logs/workbook-backups/NEXUS_DEVELOPMENT_CONTROL_20260830_225830.xlsx`,
SHA `24C8D3AF2210C0F1F61B10FB96019A8AC7C8D8BBC67263F1498C4A11B075297C`):

| Fact | Evidence |
|---|---|
| Live WI-07-0.2.4 roadmap Status | `Planned` (Type WorkItem, Parent M-07-0.2, Phase P0) |
| Pre-reservation WI-07-0.2.4 Status (backup) | `Planned` -- **identical** to live; trial never touched the roadmap row |
| M-07-0.2 Status (live + backup) | `In Progress` |
| Active Changes row 80 (CHG-20260830-017) | Status `Open -- reserved via DB-M04 governed reservation; implementation pending CHATGPT handoff` → **Classification Open** |
| Version History for WI-07-0.2.4 | **none** -- the trial wrote no Version History |
| Activity Log last row | 56 (ACT-20260830-019, `Active Change Scope Amendment`); next free row = 57 |
| reservationEvidence (state/current-task.json) | backupSha256 `24C8D3AF...` matches backup; activeChangesRow 80; activityLogRow 55 |

**M03 selection path for WI-07-0.2.4**: open reservation → M-07-0.2 is current
work → WI-07-0.2.4 is its only dependency-satisfied `Planned` child → selected.

## 3. Design decisions

### 3.1 Minimum governed state transition

1. **Close the trial reservation**: mark Active Changes row 80's Status cell with
   a new Terminal status whose first keyword is `Closed` (distinct from
   `Completed` / `Cancelled`). Extend `Read-DevelopmentControl.ps1` so a
   `Closed`-prefixed status classifies **Terminal**. This drops M-07-0.2 out of
   the current-work candidate set (its only naming reservation becomes terminal).
2. **Record trial-proving history** in DevBridge-local state
   (`state/trial-proving-history.json`): the used NodeId + ChangeId.
   `Get-NextTask.ps1` excludes already-proven NodeIds **in TRIAL mode only** at
   all three candidate points (`$candidates`, `$planned`, `$plannedChildren`),
   so WI-07-0.2.4 can no longer be picked by the NEXT-WORK fallback either.
   Roadmap sequencing is untouched; the work item is **not** marked complete.
3. **Prove the pre-reservation execution status** from recorded evidence: the M04
   backup workbook (SHA must equal `reservationEvidence.backupSha256`). For the
   live case, pre-reservation status = `Planned` = current live status, so
   restoration is a verified no-op recorded as evidence. If the backup is
   missing/unreadable, its SHA mismatches, or the node is absent from it →
   **STOP: TRIAL_PRE_RESERVATION_STATE_UNKNOWN**; never guess.
4. **State transition**: `CLAUDE_REVIEW_PASSED_TRIAL` / `TRIAL_CYCLE_SAFE_STOP`
   → `TRIAL_CYCLE_CLOSED`, `nextAllowedAction = START_NEXT_CYCLE`.

### 3.2 New lifecycle state

- `TRIAL_CYCLE_CLOSED` (trial terminal-closure state). Never equals, implies, or
  produces `COMPLETED` / `MERGED` / `READY_FOR_GOVERNED_COMPLETION` /
  `M10_COMPLETE`. M10 remains forbidden for the trial and unchanged for REAL.
- REAL mode (`REAL_NEXUS_DEVELOPMENT`) may never reach or use
  `TRIAL_CYCLE_CLOSED`; `CLOSE_TRIAL_CYCLE` is prohibited there and returns an
  explicit blocked marker.

### 3.3 Authoritative state storage

- Workbook stores the governed execution-state truth it already owns: Active
  Changes Status cell (execution state, **not** a protected roadmap column) and
  the Activity Log append. No new roadmap column/table, no roadmap structural
  edit, no Version History row (no governed roadmap fact changed: the node stays
  `Planned`).
- DevBridge-local state records proving-cycle history and closure evidence
  (temporary bridge evidence; dies with the bridge):
  - `state/trial-closure.json` -- closure evidence.
  - `state/trial-proving-history.json` -- proving-cycle history consumed by M03.
  - `tasks/TRIAL_CYCLE_CLOSURE_REPORT.md` -- human-readable closure report.

### 3.4 Protected-roadmap safety

Protected fingerprint (config/roadmap-protection.json, value
`25BBECA448CC83B76F9A639BBF5A3E4A1599FDE536938A413FBE9DB5D67BE057`) covers only
Master Roadmap identity/structure columns, Phase Plan, Architecture Decisions,
Dependencies & Blockers, Open Decisions. The closure writes Active Changes
Status and Activity Log rows only -- **both explicitly outside the protected
surface** -- so the fingerprint must be byte-identical before/after closure.
`Close-TrialCycle.ps1` recomputes the fingerprint before and after the write and
fails closed on any drift. The script has zero capability to change Phase,
Milestone, roadmap hierarchy/sequence, development order, architecture/layers,
goals, outcomes, acceptance criteria, or dependencies.

### 3.5 M03 trial-proving exclusion (design)

- Mode detection: dot-source `Set-DevBridgeStateEntry.ps1`; resolve mode via
  `Get-DevBridgeMode` (current-task `mode` → config `mode` → dbM08/dbM06
  trialMode) against an overridable state dir / config path.
- Exclusion applies **only** when mode == `TRIAL` **and** the proving-history
  file lists the NodeId. REAL mode is completely unaffected.
- `$nodes` stays intact for `Test-DepsSatisfied` dependency resolution; the used
  NodeIds are filtered only at candidate construction. No hard-coded task name.

### 3.6 Fixture-testing mechanism

`Read-DevelopmentControl.ps1` gains an env-gated workbook override
(`DB_DEV_CONTROL_WORKBOOK_OVERRIDE`) and `Get-NextTask.ps1` gains a state-dir /
config-path override (`DB_NEXTTASK_STATE_DIR`, `DB_NEXTTASK_CONFIG_PATH`), so
the M03-exclusion tests run against temp byte-identical workbook copies and temp
state dirs -- never the canonical workbook or live state.

---

## 4. Component contracts

### 4.1 `scripts/Close-TrialCycle.ps1` (new, DB24_* markers)

Mirrors `Complete-GovernedCycle.ps1` structure (Out-Markers → exit 0; only
stdout markers convey outcome). Inputs: `-NodeId`, `-ChangeId`,
`-TaskIdentity` (JSON string) or environment `DB_COMMAND_INPUT_*`; accepts
`DB24_STATE_DIR` / `DB24_TASKS_DIR` / `DB24_WORKBOOK_OVERRIDE` /
`DB24_MODE` env overrides for fixtures.

Eligibility gates (all must pass, else the specific DB24 marker):
1. Mode must be `TRIAL` (else `DB24_OUTCOME: TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE`,
   `DB24_RESULT_PASS: False`, `DB24_WORKBOOK_MODIFIED: False`).
2. Current lifecycle must be a legitimate terminal/safe-stop trial state
   (`CLAUDE_REVIEW_PASSED_TRIAL` or `TRIAL_CYCLE_SAFE_STOP`), and identity must
   match the active task (else `STOP_NOT_A_TRIAL_SAFE_STOP` /
   `TRIAL_CYCLE_IDENTITY_MISMATCH`).
3. Workbook writer must not be busy (self-check lock; service holds it during
   run, belt-and-braces) and governance state must be fresh (stale-guard token
   check; else `STALE_GOVERNANCE_STATE`).
4. No real PR/merge lifecycle: `implementationState == TRIAL_ONLY_UNMERGED`,
   `m10Run != true`, no `completion.json` for this change, no git MERGED /
   READY_FOR_GOVERNED_COMPLETION state (else `STOP_TRIAL_HAS_REAL_LIFECYCLE`).
5. Targeted cycle identity (NodeId + ChangeId) must match the active / safe-stopped
   cycle.

Pre-reservation proof: open the recorded backup workbook; SHA must equal
`reservationEvidence.backupSha256`; read the node's roadmap Status. If
`backupStatus == liveStatus` → `restoreRequired = False` (evidence recorded). If
they differ → add a roadmap Status-cell restore op to the plan (execution-state
column, fingerprint-safe). Missing/corrupt backup or absent node → **STOP:
TRIAL_PRE_RESERVATION_STATE_UNKNOWN** (exit 0, `DB24_OUTCOME` marker).

Write plan (temp copy → validate → atomic Move-Item, mirrored from M10):
- Active Changes row 80 Status cell (column L) → `Closed -- governed TRIAL cycle
  closure (DB-M12.4); trial proving evidence preserved; roadmine node NOT
  completed (remains Planned); not a real completion; M10 not applicable to trial.`
- Activity Log row 57 (next free) append: Operation `Governed Trial Cycle
  Closure`, ChangeID CHG-20260830-017, EntityID WI-07-0.2.4, Verdict CLEAR,
  Result CLOSED, Evidence trial-closure.json, reason text. No Version History row.
- Compute protected fingerprint before/after; abort on drift.

State/evidence writes (DevBridge-local only):
- `state/trial-closure.json` {changeId, nodeId, closedAtUtc, mode, result,
  preReservationStatus, restoreRequired, backupSha256, postWorkbookSha256,
  activityLogRow, nextAction START_NEXT_CYCLE}.
- `state/trial-proving-history.json` append entry {nodeId, changeId, closedAtUtc,
  mode, result, implementationState: TRIAL_ONLY_UNMERGED, preReservationStatus}.
- `current-task.json` → status `TRIAL_CYCLE_CLOSED`, nextAllowedAction
  `START_NEXT_CYCLE`, add dbM12.4 block.
- `tasks/TRIAL_CYCLE_CLOSURE_REPORT.md`.

Idempotence: if current-task status is already `TRIAL_CYCLE_CLOSED` (or the
Active Change row already `Closed`-terminal) → `DB24_OUTCOME: TRIAL_CYCLE_ALREADY_CLOSED`,
`DB24_RESULT_PASS: True`, `DB24_WORKBOOK_MODIFIED: False`; no writes.

Markers (DB24_*): OUTCOME / RESULT_PASS / RESULT_CODE / WORKBOOK_MODIFIED /
STATE_WRITTEN / PRE_RESERVATION_STATE / RESTORE_REQUIRED / FINGERPRINT_BEFORE /
FINGERPRINT_AFTER / ACTIVITY_LOG_ROW / ALREADY_CLOSED / PROHIBITED_REAL_MODE /
EVIDENCE.

### 4.2 `scripts/Read-DevelopmentControl.ps1` (edit)

- Classification (line ~275): first regex becomes
  `"^(Completed|Cancelled|Closed)"` → Terminal.
- Env-gated fixture override: if `$env:DB_DEV_CONTROL_WORKBOOK_OVERRIDE` set,
  use it as `$script:DevControlWorkbook`.

### 4.3 `scripts/Get-NextTask.ps1` (edit)

- Dot-source `Set-DevBridgeStateEntry.ps1`; read mode + proving history from
  overridable state dir; build `$script:UsedProvingIds` (HashSet[string]).
- `$script:TrialExclusion = (mode -eq "TRIAL") -and (used count > 0)`.
- Filter used NodeIds at `$candidates`, `$planned`, `$plannedChildren` only;
  `$nodes` intact for dependency resolution.

### 4.4 C# engine surface

- `DevBridgeState`: add `public bool TrialCycleClosed => Status == "TRIAL_CYCLE_CLOSED";`.
- `NextActionEngine`: AllButtons += (`CLOSE_TRIAL_CYCLE`, "CLOSE TRIAL CYCLE"),
  (`START_NEXT_CYCLE`, "START NEXT CYCLE"). Section 3.5 (trial safe-stop) arms
  `CLOSE_TRIAL_CYCLE` + `OPEN_DETAIL` with a closure instruction. New branch for
  `TrialCycleClosed && TrialMode` → instruction `TRIAL CYCLE CLOSED ...`, buttons
  `START_NEXT_CYCLE` + `OPEN_DETAIL`.
- `OperatorCommandCatalog`:
  - `CLOSE_TRIAL_CYCLE`: RequiredStates {CLAUDE_REVIEW_PASSED_TRIAL,
    TRIAL_CYCLE_SAFE_STOP, TRIAL_CYCLE_CLOSED}, ResultingExpectedState
    `TRIAL_CYCLE_CLOSED`, ExpectedCurrentState `CLAUDE_REVIEW_PASSED_TRIAL`,
    Scripts [Close-TrialCycle.ps1], RequiresTaskIdentity, RequiresUserInput,
    WritesWorkbook, DangerLevel WritesWorkbook.
  - `START_NEXT_CYCLE`: RequiredStates {TRIAL_CYCLE_CLOSED},
    ResultingExpectedState `PREFLIGHTED`, Scripts [Get-NextTask.ps1,
    Test-DevelopmentPreflight.ps1], no task identity, WritesWorkbook.
- `OperatorCommandService.CommandAvailabilityEvaluator`: `CLOSE_TRIAL_CYCLE`
  NotApplicable in REAL mode (blocked via RequiredStates) -- no change needed;
  `RUN_GOVERNED_COMPLETION` trial special case unchanged.
- `ArtifactFilesFor`: `CLOSE_TRIAL_CYCLE` → TRIAL_CYCLE_CLOSURE_REPORT.md;
  `START_NEXT_CYCLE` → PREFLIGHT_REPORT.md + NEXT_TASK.md.
- `ScriptOutcomeParser`: existing DB\d\d_* regexes already cover DB24_*.

### 4.5 UI (MainViewModel / console)

No VM edit required for button arming (buttons come from
`NextActionEngine.AllButtons`). `START_NEXT_CYCLE` is a script command handled by
the existing `RunOperatorCommand` path (WritesWorkbook → confirm dialog).
`CLOSE_TRIAL_CYCLE` likewise.

## 5. Safety invariants (verbatim requirements honored)

- M10 MUST remain unchanged; never invoked by closure. `CLOSE_TRIAL_CYCLE` NEVER
  produces COMPLETED / MERGED / READY_FOR_GOVERNED_COMPLETION / M10_COMPLETE.
- Pre-reservation status never guessed: recorded backup evidence only, else
  STOP TRIAL_PRE_RESERVATION_STATE_UNKNOWN.
- Canonical workbook NOT mutated during tests -- temp byte-identical copies only.
  No live closure performed automatically.
- Absolute roadmap immutability: zero capability to change structure/sequence/
  architecture/goals/acceptance criteria/dependencies; protected fingerprint
  unchanged.
- No PR, no merge, no baseline restore, no M04/M05 auto-launch during DB-M12.4,
  stop after the milestone.

## 6. Acceptance test matrix (33)

| # | Acceptance test | Verification |
|---|---|---|
| 1 | Safe-stop eligible closure | Fixture run → CLOSED, row 80 Terminal, Activity Log +1 |
| 2 | Active/incomplete NOT closable | Fixture status PREFLIGHTED/RESERVED → STOP_NOT_A_TRIAL_SAFE_STOP |
| 3 | REAL mode prohibited | DB24_MODE=REAL → DB24_OUTCOME TRIAL_CYCLE_CLOSURE_PROHIBITED_REAL_MODE, pass False, modified False |
| 4 | No M10 invocation | No completion.json, m10Run stays false, marker never COMPLETED |
| 5 | No false completion | Status TRIAL_CYCLE_CLOSED; no COMPLETED/MERGED/READY_FOR_GOVERNED_COMPLETION |
| 6 | Pre-reservation restore | pre==live==Planned → restoreRequired False, evidence records Planned |
| 7 | Unknown-state blocks | Corrupt/missing backup → TRIAL_PRE_RESERVATION_STATE_UNKNOWN |
| 8 | Reservation closed | Row 80 L starts "Closed" → classification Terminal |
| 9 | Evidence preserved | trial-closure.json + proving-history.json + report exist; logs untouched |
| 10 | TRIAL_ONLY_UNMERGED preserved | dbM06/dbM08 implementationState unchanged |
| 11 | No PR/merge state invented | gitLifecycleState unchanged; no CREATE_PR/MERGE tokens |
| 12 | Activity Log correct | One row, Operation "Governed Trial Cycle Closure", result CLOSED |
| 13 | Version History correct | No Version History row appended (count unchanged) |
| 14 | Fingerprint unchanged | before == after (protected surface) |
| 15 | Idempotence | 2nd run → TRIAL_CYCLE_ALREADY_CLOSED, no duplicate writes |
| 16 | Writer-busy | C# engine: lock held → WORKBOOK_WRITER_BUSY |
| 17 | Stale-state | C# engine: ExpectedCurrentState mismatch → STALE_GOVERNANCE_STATE |
| 18 | Identity mismatch | C#/script: mismatched NodeId/ChangeId → BLOCKED |
| 19 | Lifecycle refresh understands TRIAL_CYCLE_CLOSED | StateReader → NextActionEngine closed branch |
| 20 | UI next action = CLOSE TRIAL CYCLE | NextActionEngine safe-stop branch arms CLOSE_TRIAL_CYCLE |
| 21 | UI shows START NEXT CYCLE after closure | Closed branch arms START_NEXT_CYCLE |
| 22 | M03 excludes used closed task in TRIAL | Fixture M03 → WI-07-0.2.4 not selected |
| 23 | M03 selects fresh eligible | Fixture M03 → next fresh Planned node selected |
| 24 | No hard-coded task | Selection derived from fixtures; no WI-07-0.2.4 literal |
| 25 | REAL M03 unaffected | Fixture REAL + history present → used node still selectable |
| 26 | M10 regression | Test-DBM10CompletionEligibility.ps1 / M10 engine tests pass |
| 27 | M12.2 regression | scripts/Test-DBM12-2Commands.ps1 59/59 |
| 28 | M12.3 regression | Engine suite (incl. M12.3) 377/377; UI suite 65/65 |
| 29 | GH01 regression | G1..G35 |
| 30 | DB-M26 where practical | 382/382 (untouched) |
| 31 | No roadmap mutation capability | Script has no roadmap-structure write; fingerprint guard; UI none |
| 32 | Build 0 errors | Solution build |
| 33 | Canonical/Nexus/live-evidence untouched | SHA + git delta checks |

## 7. Outputs

- design/DB-M12.4_GOVERNED_TRIAL_CYCLE_CLOSURE.md
- state/db-m12-4-result.json
- tasks/DB-M12.4_IMPLEMENTATION_REPORT.md
