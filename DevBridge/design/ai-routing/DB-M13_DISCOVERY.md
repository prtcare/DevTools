# DB-M13 — AI Routing / Cost Platform — Discovery Report

**Milestone:** DB-M13 · **Lane:** B — AI ROUTING DISCOVERY (parallel to DB-M12 UI)
**Project:** Nexus DevBridge · **Root:** `C:\Personal\DevTools\DevBridge`
**Date:** 2026-08-30 · **Type:** DISCOVERY / DESIGN ONLY — no executable routing code introduced

---

## 1. Scope of this document

This report records what was **discovered** about the existing DevBridge architecture so the future
AI Routing / Cost Platform (MODEL ROUTER, AI COST CONTROLLER, AUTOMATIC MODEL ESCALATION ENGINE,
MODEL PERFORMANCE / USAGE INTELLIGENCE) can be added **without rebuilding or replacing** the current
system. Companion documents:

- `AI_ROUTING_ARCHITECTURE.md` — component map, capability-based routing, execution modes, schemas, integration points.
- `AI_ROUTING_MILESTONE_DEPENDENCIES.md` — DB-M14 → DB-M25 milestone definitions.
- `AI_ROUTING_PARALLEL_PLAN.md` — parallel-safe implementation sequencing and integration gates.
- `..\..\state\db-m13-discovery.json` — structured record of this discovery.

**Hard constraints honored:** no working-lifecycle script, DB-M03–M11 file, DB-M12 UI file,
`NEXUS_DEVELOPMENT_CONTROL.xlsx`, or Nexus repository was read-write touched. All evidence below was
gathered by **read-only inspection**. No executable model-router code exists after this milestone.

---

## 2. Executive summary

DevBridge is a **PowerShell 5.1 accelerator** that drives governed Nexus development against a
canonical Excel workbook (`NEXUS_DEVELOPMENT_CONTROL.xlsx`). It is **not** an application that calls
AI APIs. It is a *governance + orchestration* layer that produces deterministic artifacts (JSON state,
Markdown briefs, review packets) which **humans** move between AI tools (ChatGPT, DeepSeek, Claude)
by copy-paste. The AI calls happen **outside** DevBridge today (see §8, §9).

The future routing platform therefore must be designed as a **decision/advisory layer that consumes
the same stable contracts** DevBridge already produces (preflight, reservation, handoff, verification,
review, completion) and **returns recommendations + records**, while the manual execution loop stays
intact. AUTO execution is future work and must NOT be introduced during DB-M13.

**Single most important architectural fact:** the workbook's own governance already mandates the exact
abstraction the router needs — **ADR-005**: *"AI capability is abstracted as `AiRole -> Provider ->
Model -> Configuration` (no business logic branches on provider name)."* The router design in
`AI_ROUTING_ARCHITECTURE.md` is a direct implementation of ADR-005's contract.

---

## 3. Environment & stack

| Aspect | Discovered fact | Evidence |
|---|---|---|
| Runtime | Windows 11 Pro; PowerShell 5.1 (`powershell.exe`) | session env |
| Not a repo | `C:\Personal\DevTools\DevBridge` is **not** a git repository | `Is a git repository: false` |
| Source of truth | Canonical Excel workbook `C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx` (14 sheets) | `config/devbridge.json`, `config/development-control-map.json` |
| Workbook access | Read via `System.IO.Compression` + `System.Xml.Linq` (OOXML, `inlineStr` cells); writes are temp-copy → mutate → verify → atomic `Move-Item` replace | `scripts/Read-DevelopmentControl.ps1`, `scripts/Complete-Workbook-DBM10.ps1` |
| Config format | JSON (`config/`) | `config/devbridge.json` (minimal), `config/development-control-map.json` (1233-line canonical map) |
| State format | JSON (`state/`) | `state/current-task.json`, `preflight.json`, `reservation.json`, `verification.json`, `claude-review.json`, `completion.json` |
| Artifacts | Markdown (`tasks/`) | `CHATGPT_HANDOFF.md`, `DEEPSEEK_PROMPT.md`, `REVIEW_PACKET.md`, `CLAUDE_REVIEW_PROMPT.md`, `COMPLETION_REPORT.md`, … |
| History | `logs/tasks/<node>/<change>/…` + `logs/workbook-backups/` | per-change preservation; workbook `Version History` + `Activity Log` sheets |
| AI APIs called by DevBridge | **None.** DevBridge never calls any AI API today | `New-ChatGptHandoff.ps1` asserts `"no AI API was called"` |

---

## 4. Configuration & secret handling

### 4.1 DevBridge configuration
- `config/devbridge.json` is deliberately minimal:
  `{"version":"0.1","developmentControlWorkbook":"C:\\Personal\\Nexus.Developer\\NEXUS_DEVELOPMENT_CONTROL.xlsx","repositories":[],"defaultBuildCommands":[],"defaultTestCommands":[]}`.
- `config/development-control-map.json` — the canonical 14-sheet governance map: sheet roles,
  `canonicalReadPath`, `canonicalWritePath`, `sessionProtocol.hardStops`, and per-sheet mutation type
  (`NONE` / `UPDATE_EXISTING` / `APPEND_ONLY` / `UPDATE_AND_APPEND_HISTORY`).
- `config/sheet-governance.json` — per-sheet governance contract mirror.

### 4.2 Secrets — **entirely external to DevBridge**
- No API keys exist in `config/`, `scripts/`, `state/`, or `tasks/`.
- Keys live in `C:\Personal\UserSecrets\usersecrets.txt`; loaded to environment variables by
  `Load-Secrets.ps1` (outside DevBridge).
- `C:\Personal\DevTools\AI-Config\deepcode.ps1` (outside DevBridge) performs the DeepSeek launch:
  - `$env:ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"`
  - `$env:ANTHROPIC_AUTH_TOKEN = $env:DEEPSEEK_API_KEY`
  - `$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "deepseek-v4-flash"` (also `OPUS`/`HAIKU`)
  - then invokes `claude` (Claude Code harness pointed at DeepSeek).
- Governing rule (from `C:\Personal\DevTools\AI-Config\README.md`): *"API keys should not be hard-coded
  into scripts, repositories, prompts, documentation, or source code."*

**Routing implication (carries into DB-M14):** any future provider abstraction must keep this
env-var/UserSecrets pattern. DevBridge config and routing config must remain **secret-free**.

---

## 5. The task state model (stable contract #1)

`state/current-task.json` is the single source of truth for the current governed task. Observed shape
(work item `WI-07-0.2.4`, phase P0, preflight CLEAR):

```json
{
  "taskId": "WI-07-0.2.4", "nodeId": "WI-07-0.2.4", "name": "Concurrency, locking and atomic writes",
  "nodeType": "WorkItem", "phase": "P0", "currentWorkNodeId": "M-07-0.2", "featureNodeId": "F-07-0",
  "status": "PREFLIGHTED", "preflightVerdict": "CLEAR", "nextAllowedAction": "RESERVE",
  "selectedAt": "2026-08-30T17:04:09Z", "repositoryStates": [], "workbookSha256": "24C8D3…"
}
```

**Status → next-allowed-action state machine** (observed in the WI-07-0.2.3 / CHG-20260830-016 cycle):

| Status | nextAllowedAction | Produced by |
|---|---|---|
| `PREFLIGHTED` | `RESERVE` | DB-M03 (Get-NextTask → Test-DevelopmentPreflight) |
| `RESERVED` | `CHATGPT_HANDOFF` | DB-M04 (Reserve-DevelopmentChange) |
| `AWAITING_CHATGPT_PROMPT` | `COPY_TO_CHATGPT` | DB-M05 (New-ChatGptHandoff) |
| `VERIFIED` | `CLAUDE_REVIEW` | DB-M06 (Verify-Task) |
| `COMPLETION_WRITTEN` | `CONTROL_VALIDATE` | DB-M10 (Complete-Workbook-DBM10) |
| `CONTROL_VALIDATED` | `START_NEW_PREFLIGHT` | DB-M11 |

When a task completes, `current-task.json` is replaced by the preflight record of the next candidate
(preflight for `WI-07-0.2.4` already references the closed change). Nested evidence sections carried
on the state record include: `reservationEvidence`, `repositoryStates` (git baseline),
`chatgptHandoffGeneratedAt/Path`, `verification{…}`, `claudeReview{…}`, `dbM10Completion{…}`,
`dbM11Validation{…}`.

**Routing implication:** the router must treat `status`/`nextAllowedAction` as **append-only +
additive** — it may observe them and attach a *routing recommendation block*, but never mutate the
state machine. The same discipline applies to every contract below.

---

## 6. Lifecycle — DB-M03 → DB-M11 (the governed pipeline)

Current manual flow, confirmed from scripts and evidence files:

```
Development Control (workbook)
        │  DB-M03  Get-NextTask (selection) + Test-DevelopmentPreflight (Steps 1-6)
        ▼
 PREFLIGHTED ──► preflight.json · current-task.json · NEXT_TASK.md · PREFLIGHT_REPORT.md
        │  DB-M04  Reserve-DevelopmentChange (Step 7)
        ▼
 RESERVED ──► reservation.json · START_BASELINE.md · Active Changes + Activity Log append · git baseline
        │  DB-M05  New-ChatGptHandoff (deterministic context package; NO AI call)
        ▼
 AWAITING_CHATGPT_PROMPT ──► CHATGPT_HANDOFF.md + DEEPSEEK_PROMPT.md (placeholder)
        │  HUMAN:  copy handoff → ChatGPT → ChatGPT produces DeepSeek implementation prompt
        ▼
 DEEPSEEK_PROMPT.md (human pasted)  →  HUMAN launches DeepSeek (deepcode.ps1 → Claude Code + DeepSeek)
        │  DeepSeek implements + returns IMPLEMENTATION RESULT report
        ▼
 VERIFIED ──► verification.json (22-part deterministic verification) · VERIFICATION_REPORT.md
        │  DB-M07  New-ReviewPacket
        ▼
 REVIEW_PACKET.md · CLAUDE_REVIEW_FILES.md · CLAUDE_REVIEW_PROMPT.md
        │  HUMAN:  copy review prompt → Claude reviews → paste result back
        ▼
 claude-review.json · CLAUDE_REVIEW_RESULT.md   (decision PASS / FIX REQUIRED; DB-M09 fix loop)
        │  DB-M10  Complete-Workbook-DBM10 (multi-sheet completion write)
        ▼
 COMPLETION_WRITTEN ──► completion.json (26/26 post-write checks) · COMPLETION_REPORT.md
        │  DB-M11
        ▼
 CONTROL_VALIDATED  → next governed candidate preflighted
```

### 6.1 DB-M03 — selection + preflight (implemented)
- `scripts/Get-NextTask.ps1` — CURRENT WORK FIRST (freshest open reservation wins) / NEXT WORK drill-down.
- `scripts/Test-DevelopmentPreflight.ps1` — Steps 1-6, verdict precedence; outputs
  `state/preflight.json`, `state/current-task.json`, `tasks/NEXT_TASK.md`, `tasks/PREFLIGHT_REPORT.md`.
- Verdicts: `CLEAR` / `DEPENDENCY FOUND` / `OVERLAP FOUND` / `CONFLICT FOUND` / `ARCHITECTURE CONFLICT`
  (+ `BLOCKED_BY_OPEN_DECISION`, `GOVERNANCE_CONTEXT_INCOMPLETE`, `SCOPE_INCOMPLETE`,
  `TASK_SELECTION_AMBIGUOUS`).

### 6.2 DB-M04 — reservation (implemented)
- `scripts/Reserve-DevelopmentChange.ps1` — Change ID `CHG-YYYYMMDD-NNN`, Activity ID `ACT-YYYYMMDD-NNN`,
  backup, git baseline, OOXML append (Active Changes + Activity Log), atomic replace, self-test env
  overrides (`DB04_SELFTEST`, `DB04_WORKBOOK_OVERRIDE`, …), idempotency `REUSED` guard.

### 6.3 DB-M05 — ChatGPT handoff + context generation (implemented, 656 lines)
- `scripts/New-ChatGptHandoff.ps1` flow: **PART 1** fresh reservation validation (14 sheets, Change ID
  unique, node match, scope set-compare, conflict scan, dependency re-check) → **PARTS 2-7** context
  package → **PART 8** `tasks/CHATGPT_HANDOFF.md` → **PART 9** `tasks/DEEPSEEK_PROMPT.md` placeholder →
  **PART 10** state → `AWAITING_CHATGPT_PROMPT` → **PART 11** history copy → **PART 12** validation.
- Context package sections: Authoritative Task, Development Control, Goal, Current State,
  Why This Work Is Current, Acceptance Criteria, Completion Gate, Dependencies, Architecture
  Constraints, Open Decisions, Audit Findings, Existing Assets (REUSE / EXTEND / MISSING), Exact
  Reserved Scope, Repository Governance, Git Baseline, Pending Governance, Instructions to ChatGPT,
  Expected DeepSeek Completion Report.
- **Asserts** `no AI API was called`; workbook and Nexus repos untouched.

### 6.4 DB-M06 — verification (stub; executed interactively, fully evidenced)
- `scripts/Verify-Task.ps1` is a **stub** ("Future purpose"). The actual 22-part verification is evidenced
  in `state/verification.json` for CHG-20260830-016: governance revalidation, baseline comparison,
  changed-file inventory (GOVERNANCE_WORKBOOK / IMPLEMENTATION_CHANGE_IN_SCOPE / OUT_OF_SCOPE /
  UNKNOWN; scopeViolation false), contract completeness (22 ops / 13 mutating), safe mutation on temp
  copy, append-only Version History, Activity Log schema (34 columns), canonical hash before/after
  UNCHANGED, build (4 projects, 0/0 warnings/errors), tests (199/199 + harness 32/32), acceptance
  matrix 8/8, state transition → `VERIFIED`/`CLAUDE_REVIEW`.

### 6.5 DB-M07 — Claude review package (stub; executed interactively, fully evidenced)
- `scripts/New-ReviewPacket.ps1` is a **stub**. The packet is evidenced in `tasks/REVIEW_PACKET.md`,
  `tasks/CLAUDE_REVIEW_FILES.md` (exact file manifest with SHA256), `tasks/CLAUDE_REVIEW_PROMPT.md`
  (verbatim prompt between `---BEGIN---` / `---END---` fences; `Decision: PASS | FIX REQUIRED`).

### 6.6 DB-M08 — review-result handling (interactive, evidenced)
- `state/claude-review.json` + `tasks/CLAUDE_REVIEW_RESULT.md` (verbatim human-pasted response).
- CHG-20260830-016: decision `PASS`, blocking 0, residual 1 (MINOR/NON-BLOCKING, carried forward).
- DB-M09 fix loop was NOT required; when required it would be a FIX_CONTEXT + re-run.

### 6.7 DB-M10 — completion write (implemented)
- `scripts/Complete-Workbook-DBM10.ps1` — multi-sheet completion: Control Center A2 prepend, Master
  Roadmap row status/progress/evidence, Active Changes close, Version History append, Tool Registry
  append (ClosedXML, row 16), Activity Log append (row 54), Existing Assets append (row 16). Temp copy →
  mutate → verify (26 checks) → atomic `Move-Item` → re-verify canonical. Exit codes 0/2/3.
- `state/completion.json` records 14-sheet results, progress deltas (WI-07-0.2.3 0→100, M-07-0.2 20→30),
  `nextGovernedCandidate` (WI-07-0.2.4), residual observations, post-write verification 26/26, idempotency.

### 6.8 DB-M11 — control validation (implemented)
- Validates workbook state after completion; records `CONTROL_VALIDATED` / `START_NEW_PREFLIGHT`;
  confirms **DB-M12 is NOT implemented** ("No next task reserved or started. Stop after DB-M11.").

---

## 7. Task history, logging, and artifact preservation

| Concern | Discovered mechanism |
|---|---|
| Task history | `logs/tasks/<nodeId>/<changeId>/` — every artifact from the cycle (preflight, handoff, deepseek prompt, verification report, review packet/result, completion report, consistency report, pre-write snapshots) is preserved per change |
| Workbook backups | `logs/workbook-backups/NEXUS_DEVELOPMENT_CONTROL_<timestamp>.xlsx` with recorded SHA256 before/after |
| Governance log | Workbook `Activity Log` sheet (append-only, 34 columns, Activity ID `ACT-YYYYMMDD-NNN`, operation, change ID, human review status) |
| Version history | Workbook `Version History` sheet (append-only, per ADR-003) |
| Change ledger | Workbook `Active Changes` sheet — open rows; closed rows are marked Terminal, never deleted |
| Hash integrity | `Get-WorkbookSha256` before/after every write; canonical hash recorded in state |

**Routing implication:** attempt history (DB-M17) must be stored under the **same** convention —
`logs/tasks/<node>/<change>/attempts/<AttemptId>.json` plus a `state/attempts/<changeId>/…` mirror —
so the performance intelligence layer can consume the existing directory structure without new infra.

---

## 8. Current manual AI workflow (from `C:\Personal\DevTools\AI-Config`)

The AI execution today is a **human-mediated loop**, fully outside DevBridge:

1. **Claude** — planning / design / review (human copy-pastes DevBridge artifacts).
2. **Claude Code + DeepSeek** — implementation, launched via `deepcode.ps1` (Claude Code harness pointed
   at DeepSeek's Anthropic-compatible endpoint, model `deepseek-v4-flash`).
3. **ChatGPT** — converts the DevBridge handoff into the DeepSeek implementation prompt.
4. **Nexus governance files** — control agent autonomy (GLOBAL-RULES, EXECUTION-RULES,
   ESCALATION-RULES, COMPLETION-RULES in `AI-Config`).

**Escalation vocabulary** (from `AI-Config\ESCALATION-RULES.md`) — 12 escalation conditions and a fixed
report format (ISSUE / AFFECTED TASK / AFFECTED FILES / OPTIONS / RECOMMENDATION / STATUS). This is the
existing vocabulary the IEscalationEngine (DB-M20) must **reuse**, not replace.

---

## 9. AI-relevant existing assets & architecture intent

### 9.1 ADR-005 (governing abstraction — the router's charter)
> "AI capability is abstracted as `AiRole -> Provider -> Model -> Configuration`
> (no business logic branches on provider name)."

This is **the** architectural anchor. Capability-based routing (§4 of the architecture doc) is simply
ADR-005 implemented as an executable decision layer. The router must keep provider-name out of business
logic exactly as ADR-005 demands.

### 9.2 Existing AI assets in the Nexus platform (INFORMATIONAL — outside DevBridge, read-only)
Preflight evidence classified the following as `existingAssets`:
- **Model gateway** — `Nexus.Platform.Core/Models`, `Nexus.Platform.Providers.OpenAI` — *"Working foundation"*.
- **Intelligence turn pipeline** — INFORMATIONAL.
- **Developer agent shell** — stub.
- **Chat API / domain / UI** — INFORMATIONAL.
- Tool & Integration Registry phase-1 required tools include **OpenAI/model gateway, Claude, DeepSeek**.

The DevBridge router design should **align with, not duplicate**, the platform model-gateway abstraction
(ADR-005). DevBridge's own routing layer lives in DevBridge config/scripts/state and speaks the same
`AiRole → Provider → Model` vocabulary.

---

## 10. DB-M12 (UI) status — **NONE**

- **DB-M12 is NOT implemented.** No UI candidate files exist anywhere under DevBridge.
- The only "DB-M12" strings in the project are the *negative* markers in the consistency reports:
  *"DB-M12 is NOT implemented. No next task reserved or started. Stop after DB-M11."*
- **Consequence for DB-M13:** every routing/cost component is designed against **stable backend
  contracts** (the JSON state records + script interfaces + Markdown artifacts listed in §5-§7), not a UI.
  When DB-M12 is built it consumes those same contracts. **DB-M12 overlap: NONE.**

---

## 11. Stable contracts the router must integrate with (frozen for DB-M14+)

| Contract | File / interface | Producer |
|---|---|---|
| Task selection + preflight | `state/preflight.json`, `state/current-task.json` (status/nextAllowedAction), `tasks/NEXT_TASK.md` | DB-M03 |
| Reservation | `state/reservation.json`, `state/current-task.json` (reservationEvidence, repositoryStates) | DB-M04 |
| Context package | `tasks/CHATGPT_HANDOFF.md`, `tasks/DEEPSEEK_PROMPT.md` | DB-M05 |
| Verification | `state/verification.json`, `tasks/VERIFICATION_REPORT.md`, acceptance matrix | DB-M06 |
| Review package | `tasks/REVIEW_PACKET.md`, `tasks/CLAUDE_REVIEW_FILES.md`, `tasks/CLAUDE_REVIEW_PROMPT.md` | DB-M07 |
| Review result | `state/claude-review.json`, `tasks/CLAUDE_REVIEW_RESULT.md` | DB-M08 |
| Completion | `state/completion.json`, `state/sheet-update-plan.json`, `tasks/COMPLETION_REPORT.md` | DB-M10 |
| Control validation | `state/current-task.json` (dbM11Validation) | DB-M11 |
| Workbook reads | `scripts/Read-DevelopmentControl.ps1` (dot-sourced accessors; contract = header text, not column letters) | shared lib |
| Governance map | `config/development-control-map.json`, `config/sheet-governance.json` | config |
| External AI governance | `AI-Config/GLOBAL-RULES.md`, `EXECUTION-RULES.md`, `ESCALATION-RULES.md`, `COMPLETION-RULES.md` | outside DevBridge |

**Design rule for the router:** it may **consume** every contract above and **emit new files**
(recommendation, attempt records, cost records, routing policy config) — it must never alter an
existing contract's schema or content.

---

## 12. Discovery conclusions → design inputs

1. **No rebuild needed.** The router is an additive advisory + recording layer over existing contracts.
2. **Manual flow must remain default.** MANUAL (current) stays byte-for-byte compatible; ASSISTED adds
   recommendations; AUTO is gated and unimplemented.
3. **ADR-005 is the charter.** `AiRole → Provider → Model → Configuration`, capability-based, no
   provider-name branching.
4. **Secrets stay external.** Env-var/UserSecrets pattern; no keys in DevBridge or routing config.
5. **Attempt + pricing are new data, not code.** Schema design only in DB-M13 (see architecture doc);
   data files in DB-M15; no DB migrations.
6. **DB-M05 and DB-M07 stay usable** by construction: their artifacts are deterministic Markdown that
   humans exchange; the router adds *separate, clearly-labeled* recommendation/evidence files.
7. **DB-M12 overlap: NONE** — no UI exists; contracts are the backend.

---

*End of DB-M13 discovery report. Companion docs: `AI_ROUTING_ARCHITECTURE.md`,
`AI_ROUTING_MILESTONE_DEPENDENCIES.md`, `AI_ROUTING_PARALLEL_PLAN.md`.*
