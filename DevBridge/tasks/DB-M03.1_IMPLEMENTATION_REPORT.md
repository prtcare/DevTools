# DB-M03.1 -- Implementable Leaf-Task Selection & Preflight Resolution: Implementation Report

Date (UTC): 2026-08-31  |  Lane C  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing here migrates into Nexus runtime/architecture/contracts/services/
libraries/infrastructure/dependency.

---

## 1. What this milestone delivered

The FINAL HARDENED LANE C TRIAL PART 1 post-closure run exposed an **M03
selection defect** (not a governance-state gap): with the trial-closed
`WI-07-0.2.4` correctly excluded by proving history, M03 auto-selected the
CURRENT WORK anchor `M-07-0.2` -- a **Milestone container** -- as "the task",
and preflight then hit `SCOPE_INCOMPLETE` / `RESOLVE_PREFLIGHT` because a
container carries no derivable implementation scope. M03 was surfacing a
container as the selection target, which the governed contract forbids: only an
`IMPLEMENTABLE_LEAF` may be reserved (M04) and handed off (M05).

DB-M03.1 hardens M03 end-to-end so a container is **never returned as the
task**:

- **Deterministic implementability classification** -- `Get-ImplementabilityClass`
  driven by the governed **`NodeType`** column, `BreakdownComplete` (col S), and
  child presence. **NodeId prefixes are NOT used.** Layer/Feature/Milestone =>
  `NON_IMPLEMENTABLE_CONTAINER`; WorkItem/Task with `BreakdownComplete=No` =>
  `INCOMPLETE_WORK_ITEM`; WorkItem/Task with children => container; leaf
  WorkItem/Task (no children, breakdown blank) => `IMPLEMENTABLE_LEAF`; Subtask
  => leaf; unknown NodeType => `UNKNOWN_NODE_TYPE`.
- **Container -> leaf resolution** -- `Resolve-ImplementableDescendant` performs a
  DFS pre-order over governed reading order (SortKey ascending, then Row
  ascending). A candidate leaf requires class `IMPLEMENTABLE_LEAF` **and**
  dependencies satisfied **and** not trial-proven-excluded (TRIAL mode only).
  Returns `{ leaf, chain, reason }`, with `reason` naming the first blocking
  cause when no leaf is found.
- **Leaf-selection validation** -- `leafValidation[]` emitted into `preflight.json`
  for a selected leaf: identity, hierarchy (anchor + resolution chain),
  execution state (not terminal, no open conflict), dependencies re-verified,
  acceptance criteria inherited from the nearest AC-carrying Milestone
  (`AC_INHERITED` / `AC_ABSENT_WARN`), repo/project informational, no conflict,
  no incompatible reservation.
- **Honest block states** -- `NO_IMPLEMENTABLE_DESCENDANT` /
  `HUMAN_GOVERNANCE_REQUIRED` / `IMPLEMENTATION_TARGET_UNKNOWN` short-circuit
  preflight **before** scope derivation: current-task.json status `PREFLIGHTED`,
  nodeId = anchor, `nextAllowedAction RESOLVE_GOVERNANCE_BLOCK`, preflight
  verdict = token. `SCOPE_INCOMPLETE` remains a *post-selection* verdict for a
  selected leaf; `TASK_SELECTION_AMBIGUOUS` keeps its pre-existing minimal path.
  All are non-CLEAR governed blockers.
- **M04 gate** (`Reserve-DevelopmentChange.ps1`) -- a classified non-leaf target
  is refused with `STOP_NOT_IMPLEMENTABLE_LEAF`; **backward compatible**: legacy
  state without the implementability field reserves normally (E30). Set-StrictMode
  property-access safety added so missing fields never crash the gate.
- **M05 gate** (`New-ChatGptHandoff.ps1`) -- a classified container is refused
  with `HANDOFF_CONTAINER_PROHIBITED`; **backward compatible**: legacy state
  without the implementability field hands off normally (E32).

The `M-07-0.2` Milestone-container defect is reproduced safely in byte-identical
fixtures and proven resolved (matrix B13/B14, C20/C21, D25/D27). No live M04
reserve, no live M05 handoff, no workbook mutation, no Nexus source change, and
no manual task selection were performed.

---

## 2. Constraints honored (verbatim)

- **Roadmap immutability**: this milestone did NOT modify phases, milestones,
  roadmap hierarchy, roadmap sequencing, development order, architecture, goals,
  acceptance criteria, or dependencies. M03 may only READ and INTERPRET them.
- **DB-M18.1 boundary**: no DB-M18.1-owned lineage/index/reconciliation files
  were modified.
- **No authoritative-workbook mutation**: all testing used byte-identical
  workbook copies under `logs\selftest\db-m03-1`; the authoritative
  `NEXUS_DEVELOPMENT_CONTROL.xlsx` SHA is asserted unchanged (I1).
- **No live M04/M05**: `Reserve-DevelopmentChange` and `New-ChatGptHandoff`
  were only exercised against fixture state/workbooks (E29-E32).
- **Stop after DB-M03.1**: no further milestone work, no manual Nexus task
  selection, no M10 run, no baseline restore.

---

## 3. Test matrix (40 checks, all PASS)

| Group | Checks | Scope |
|---|---|---|
| A (classification) | A1-A10 | Milestone/Feature/Layer => container; leaf WorkItem; incomplete WorkItem; WorkItem/Task with children; leaf Task; Subtask; unknown NodeType |
| B (resolution) | B11-B17 | container -> eligible child leaf; deep chain; dep-unsatisfied => `NO_IMPLEMENTABLE_DESCENDANT`; trial-proven-only => block; dep-blocked-then-eligible ordering; incomplete+no eligible => `HUMAN_GOVERNANCE_REQUIRED`; unknown anchor => `IMPLEMENTATION_TARGET_UNKNOWN` |
| C (selection flow) | C18-C23 | current-work leaf as itself; current-work container resolves; NEXT WORK fallback; no target => `TASK_SELECTION_AMBIGUOUS`; trial-proven excluded + fresh sibling; dependency order preserved |
| D (preflight) | D24-D28 | leaf CLEAR => implementability + RESERVE; container block ledger; incomplete block; unknown block; `leafValidation[]` with `AC_INHERITED` |
| E (M04/M05 gates) | E29-E32 | M04 refuses container; M04 legacy backward-compat RESERVED; M05 refuses container; M05 legacy backward-compat HANDOFF_GENERATED |
| I (invariants) | I1-I4 | authoritative workbook untouched; Nexus git delta 0; live `current-task.json` untouched; solution build 0/0 |

**Result:** `DB-M03.1 SAFETY SUMMARY: 40 checks, 40 passed, 0 failed`,
`DB-M03.1 SUITE: PASS`, exit 0.

---

## 4. Regressions (all green)

| Regression | Result |
|---|---|
| Test-DBM124TrialCycleClosure (S8/S9 rewritten for capability k) | 54 / 54 |
| Test-DBM04Safety (M04 engine modified) | 26 / 26 |
| Test-DBM12-2Commands | 59 / 59 |
| GH01 M10 eligibility (read-only gate) | `M10_BLOCKED` / `TRIAL_COMPLETION_NOT_APPLICABLE` / verification PASS |
| DevBridge.Tests engine suite | 410 / 410 |
| DevBridge.UITests (DB-M12.3 UI lifecycle) | 65 / 65 |
| Solution build | 0 errors / 0 warnings |

---

## 5. Owned writes

- `design/DB-M03.1_IMPLEMENTABLE_LEAF_TASK_SELECTION.md`
- `scripts/Get-NextTask.ps1`, `scripts/Test-DevelopmentPreflight.ps1`,
  `scripts/Reserve-DevelopmentChange.ps1`, `scripts/New-ChatGptHandoff.ps1`
- `scripts/Test-DBM124TrialCycleClosure.ps1` (S8/S9)
- `scripts/Test-DBM031ImplementableLeafSelection.ps1` (40-check matrix)
- `state/db-m03-1-result.json`, `tasks/DB-M03.1_IMPLEMENTATION_REPORT.md`
- `logs/selftest/db-m03-1-final.log`

No other DevBridge or Nexus file was written by this milestone. Diagnostic
probes were removed after use.

---

## 6. Current live state (untouched by this milestone)

- Authoritative workbook `NEXUS_DEVELOPMENT_CONTROL.xlsx`:
  SHA256 `6D42C3BF...E4F5` (unchanged; row 80 Closed-terminal, WI-07-0.2.3
  Complete, WI-07-0.2.4 Planned).
- `state/current-task.json`: `M-07-0.2 / PREFLIGHTED / RESOLVE_PREFLIGHT`
  (the pre-existing post-closure preflight record of the defect scenario;
  byte-identical after the suite, invariant I3).
- No M04 reserve, no M05 handoff, no M10, no PR, no merge.

---

## 7. Next steps (NOT part of this milestone)

The governed flow resumes with the operator/human deciding the next action on
`M-07-0.2` under the hardened M03: a fresh `START_NEXT_CYCLE` preflight now
resolves the container anchor to an implementable leaf (or emits an honest
governed block) instead of returning the Milestone as the task. Any live
reserve/handoff and any new milestone must be started explicitly by the human;
DB-M03.1 stops here.
