# DB-M12.1 — UI Operational Integration and Command Orchestration

Milestone: DB-M12.1 · Date (UTC): 2026-08-30 · Lane A2 — this session.

## Objective

Turn the DB-M12 operator console into a **safe command shell** over the existing
governed DevBridge lifecycle. The UI never re-implements a governance rule; every
lifecycle action is described by a UI-owned **operator command** that points at the
**existing DB-M03–DB-M11 backend scripts** and is verified by the **refreshed
state**, never by the process exit code alone.

```
UI  →  OperatorCommandCatalog (UI-owned metadata)
    →  OperatorCommandService (orchestration)
    →  existing backend PowerShell script(s)
    →  StateReader refresh
    →  validate declared lifecycle transition  →  result  →  UI renders
```

## Architecture

### 1. The operator command vocabulary (`DevBridge.Engine/OperatorCommand.cs`)

`OperatorCommand` is UI/operator **metadata**, not business logic. Each entry
declares:

| Field | Meaning |
|---|---|
| `CommandId` / `DisplayName` | stable key + label |
| `Kind` | `Script` \| `GuidedManual` \| `Navigation` \| `Clipboard` |
| `RequiredStates[]` | lifecycle status(es) the command may run from (empty = any) |
| `ResultingExpectedState` | lifecycle status the command **must** produce |
| `Scripts[]` | existing backend script names, run in order, first failure stops |
| `WritesWorkbook` / `DangerLevel` | authoritative-workbook mutation flag (operator confirmation) |
| `RequiresUserInput` | operator confirmation / evidence entry required |
| `TimeoutMs` | process timeout |
| `GuidedReason` / `ManualGuidance` | why a guided command cannot be automated, + what to do |

`OperatorCommandCatalog.All` is the single UI-owned table of commands. The UI
routes **every** action button through `OperatorCommandCatalog.Get(key)` — there is
no per-case lifecycle logic left in the view model.

### 2. Safe script invocation (`DevBridge.Engine/ScriptProcessRunner.cs`)

Reuses the DB-M12 approach:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<explicit path>"`
- explicit script path via `ProcessStartInfo` — **never** an untrusted constructed
  shell command line, no injection surface
- stdout and stderr captured **separately**, exit code captured, timeout enforced
  (process killed on expiry)
- environment overrides only via an explicit allow-list (self-tests redirect writes
  away from the authoritative workbook)

### 3. Reading the scripts' own outcome markers (`ScriptOutcomeParser.cs`)

Several governed scripts (e.g. `Reserve-DevelopmentChange.ps1`,
`Test-DevelopmentPreflight.ps1`) **always exit 0** — outcomes are communicated on
stdout via `DB0X_OUTCOME: <TOKEN>`, `DB0X_RESULT_PASS: True|False` and
`PREFLIGHT VERDICT: <TOKEN>`. `ScriptOutcomeParser` reads those markers; an exit
code alone is never trusted.

### 4. Orchestration (`OperatorCommandService.cs`)

`Execute(cfg, cmd, runner)`:

1. reads the **previous** state;
2. guided/manual commands → `MANUAL_ACTION_REQUIRED` with the recorded reason
   (never fabricated as an automatic run);
3. navigation/clipboard → not executed by the service (UI-only);
4. state gate: `RequiredStates` not satisfied → `BLOCKED`; no script invoked;
5. runs the backend scripts in order and classifies each outcome:
   - timed out → `BLOCKED`
   - governed `STOP_*` marker → `BLOCKED` (state never forced)
   - nonzero exit → `FAILED`
   - `DB*_RESULT_PASS: False` → `BLOCKED`
6. **refreshes** state and validates the declared transition — if the refreshed
   state did not reach `ResultingExpectedState`, the result is `FAILED` with
   `IsBackendStateMismatch` = true and a message prefixed
   `BACKEND_STATE_MISMATCH`. Exit 0 is **never** assumed to mean success.

### 5. Command result model (`OperatorCommandResult.cs`)

`SUCCESS | FAILED | BLOCKED | CANCELLED | MANUAL_ACTION_REQUIRED`, plus previous /
new state, next allowed action, compact + full output, generated-artifact paths and
the `StateValidationLabel`. Sensitive prompt content is never stored in logs.

### 6. Honest guided/manual commands (Part 5)

Commands whose backend implementation is not durably callable stay
`GUIDED_MANUAL_ACTION` with the **exact reason recorded**:

| Command | Why it stays manual |
|---|---|
| `RUN_GOVERNED_COMPLETION` | `Complete-Workbook-DBM10.ps1` is **one-time generated** logic hard-coded to the previous change (CHG-20260830-016 / WI-07-0.2.3). Auto-invoking it for a fresh cycle would write the wrong change's data into the authoritative workbook. |
| `RUN_VERIFICATION` | `Verify-Task.ps1` is a stub; DB-M06 exists only as milestone guidance. |
| `CREATE_CLAUDE_REVIEW_PACKAGE` | `New-ReviewPacket.ps1` is a stub; DB-M07 assembly is milestone guidance. |
| `RECORD_CLAUDE_RESULT` | DB-M08 has no reusable command entry point; the UI provides a safe evidence-entry dialog (below). |
| `VALIDATE_WORKBOOK` | No durable orchestrator script writes `state/workbook-consistency.json`. |

### 7. Claude verdict evidence entry (Part 10)

`ClaudeResultEntryDialog` (PASS / FIX REQUIRED + paste box) → `ClaudeResultEvidence`
writes the two evidence files the existing engine already reads —
`tasks/CLAUDE_REVIEW_RESULT.md` (decision + `CLAUDE_FIX_REQUIRED` when fixes are
required) and `state/claude-review.json` (decision, `dbM09Required`, reviewedAt,
`recordedVia`). The operator's exact review text is preserved **verbatim**; the UI
never interprets review semantics.

### 8. Clipboard workflow (Part 11)

Clipboard commands copy a generated artifact verbatim via
`ClipboardService.CopyFile`; `ClipboardStatusMapper` is a pure function yielding
`READY TO COPY / COPIED / ARTIFACT MISSING / NOT APPLICABLE / ERROR`. The UI never
auto-sends information to external AI services — it only copies.

### 9. Busy / double-click protection (Part 13)

`CommandConcurrencyGuard` (thread-safe `TryBegin`/`End`) plus an `IsBusy` state
gate refuse any further lifecycle action while a governed command runs; the engine
regrounds the enabled button set on every refresh.

### 10. Live command output panel (Part 12)

After a command runs, the dashboard shows a LIVE COMMAND OUTPUT card
(`CommandPanelVisible`) with the command name, a colored PASS/FAILED/BLOCKED/MANUAL
status pill and a compact stdout summary; the full transcript stays in the
expanded LAST SCRIPT OUTPUT log.

### 11. Stale-cycle protection (Part 15)

`StateReader` gates evidence by matching `changeId`/`nodeId`
(`EvidenceApplies`), so a previous cycle's `claude-review.json`, `completion.json`,
`verification.json` or `workbook-consistency.json` can never hijack a fresh record.
Both the next-action engine and the command-layer tests lock this in.

## Scope discipline

- **Modified only** the DB-M12 UI/operator-integration area (`src/DevBridge.UI`,
  `src/DevBridge.Tests`) and new UI-owned orchestration wrappers
  (`src/DevBridge.Engine`: `OperatorCommand*`, `ScriptProcessRunner`,
  `ScriptOutcomeParser`, `ClaudeResultEvidence`, `CommandConcurrencyGuard`,
  `ClipboardStatus`).
- **Not modified**: `NEXUS_DEVELOPMENT_CONTROL.xlsx`, `Nexus.Developer`,
  DB-M15 pricing files, DB-M17 attempt-history files, AI-routing shared contracts,
  live task state, and every DB-M03–DB-M11 business/governance script. The session
  transcript contains zero Write/Edit calls to `scripts/`, `config/`, `state/` or
  the workbook; the workbook SHA-256 was verified identical by two independent
  read-only probes.
- UI testing never triggered a governed workbook write; the live smoke (`--live`)
  is read-only and did not touch Lane C's active task (WI-07-0.2.4, RESERVED).

## Verification

- Full solution build: **0 errors, 0 warnings**.
- Fixture runner: **208 / 208 checks pass** (DB-M12.1 command catalog integrity,
  marker parsing, command execution success/failure/stop/timeout/mismatch/gate,
  guided-manual honesty, Claude evidence entry, clipboard + result-text utilities,
  stale-cycle command-layer regression).
- Live read-only smoke passes against the real DevBridge state.
