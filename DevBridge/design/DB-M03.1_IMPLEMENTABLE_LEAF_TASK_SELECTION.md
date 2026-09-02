# DB-M03.1 — IMPLEMENTABLE LEAF-TASK SELECTION & PREFLIGHT RESOLUTION

**Milestone:** DB-M03.1 (governance / preflight correction)
**Date:** 2026-08-31
**Status:** DESIGN
**Owner lane:** Lane B backend governance
**Driver bug:** FINAL HARDENED LANE C trial Part 1 — M03 auto-selected the **Milestone container** `M-07-0.2` as "the task" (drill-down found zero ready planned children) and the preflight returned the honest-but-coarse `SCOPE_INCOMPLETE`.

---

## 1. Context & why

`Get-NextTask.ps1` has no node-implementability concept. When the CURRENT WORK anchor has no ready planned child it executes the fallback `$taskNode = $cw`, returning a **container** as the task. `Test-DevelopmentPreflight.ps1` then cannot derive a scope for a Milestone and returns `SCOPE_INCOMPLETE` — a legitimate blocker, but not the *most* precise signal, and it leaves the engine able to "select" a non-implementable node.

**DB-M03.1 objective:** the M03 engine must never present a non-implementable node as the implementation target. Containers resolve recursively to an eligible leaf, or the engine reports an honest block state.

## 2. Immutable boundaries (verbatim constraints)

- This milestone must NOT modify: phases, milestones, roadmap hierarchy, roadmap sequencing, development order, architecture, goals, acceptance criteria, dependencies. **M03 may READ and INTERPRET these only.**
- Do not modify DB-M18.1-owned lineage/index/reconciliation files.
- Do not modify the authoritative workbook while implementing/testing M03.1. Use fixtures / byte-identical temp copies.
- Do not modify Nexus source. Do not start a new real/live trial task during the milestone implementation.
- Stop after DB-M03.1: do NOT start M04/M05 on the live workbook, do NOT manually choose another Nexus task, do NOT run M10, do NOT restore the pre-DevBridge baseline.

## 3. Design decisions

### 3.1 Implementability classification — `Get-ImplementabilityClass`

Deterministic, driven by the governed **`NodeType` column**, `BreakdownComplete` (col S), and child presence. **NodeId prefixes are NOT used for classification.**

| NodeType (col) | BreakdownComplete | Has children | Class |
|---|---|---|---|
| Layer / Feature / Milestone | any | any | `NON_IMPLEMENTABLE_CONTAINER` |
| WorkItem | `No` | any | `INCOMPLETE_WORK_ITEM` |
| WorkItem | Yes / blank | 0 | `IMPLEMENTABLE_LEAF` |
| WorkItem | Yes / blank | >0 | `NON_IMPLEMENTABLE_CONTAINER` |
| Task | `No` | any | `INCOMPLETE_WORK_ITEM` |
| Task | Yes / blank | 0 | `IMPLEMENTABLE_LEAF` |
| Task | Yes / blank | >0 | `NON_IMPLEMENTABLE_CONTAINER` |
| Subtask | any | any | `IMPLEMENTABLE_LEAF` |
| anything else | — | — | `UNKNOWN_NODE_TYPE` |

Rules behind the table:
- Only `BreakdownComplete` **exactly "No"** is the incomplete signal; blank is treated as not-incomplete (S7 fixture: leaf WI-07-0.2.4 has blank breakdown and must remain an implementable leaf).
- `INCOMPLETE_WORK_ITEM` is never directly selectable; the resolver still descends into its children (a partially-broken-down WorkItem may still have ready Tasks), but a block caused by an incomplete breakdown carries `HUMAN_GOVERNANCE_REQUIRED`.
- Acceptance criteria do NOT gate classification — AC lives at Milestone level (83/83 leaf Milestones; WorkItem ~14/64, Task 1/83, Subtask 0/101 leaves). AC is validated by **inheritance** from the Milestone ancestor inside leaf validation.

### 3.2 Container → leaf resolution — `Resolve-ImplementableDescendant`

DFS pre-order over governed reading order (children sorted by `SortKey` ascending, then source `Row` ascending — the order an operator reads the roadmap). A descendant is a candidate leaf iff:
1. class == `IMPLEMENTABLE_LEAF`, **and**
2. `Test-DepsSatisfied` (dependencies resolved to Completed/Complete; no Open+Blocking REL), **and**
3. not trial-proven-excluded (`Test-NotTrialProven`, TRIAL mode only).

Returns `{ leaf, chain, reason }`; `reason` is the first cause when no leaf is found (trial-excluded, dependency-unsatisfied, all containers, none planned).

### 3.3 Selection flow rewrite (`Get-NextTask.ps1`)

- Anchor = CURRENT WORK first, else NEXT WORK fallback (unchanged ordering).
- `class = Get-ImplementabilityClass anchor`:
  - `IMPLEMENTABLE_LEAF` → leaf-selection validation → `SELECTED` (`TaskNode = anchor`).
  - container / `INCOMPLETE_WORK_ITEM` / `UNKNOWN_NODE_TYPE` → `Resolve-ImplementableDescendant` → `SELECTED` (`TaskNode = leaf`, chain recorded in `SelectionBasis`) **or** block.
- **Block object:** `TaskSelectionStatus = <block token>`, `TaskNodeId = null`, `TaskNode = null`, `BlockState`, `BlockReason` (from resolver `reason`), `Candidates` preserved for transparency.

### 3.4 Leaf-selection validation (capability c) — `leafValidation[]`

Applied to a selected leaf; emitted into `preflight.json`:
- **identity** — node exists in governed range, NodeId resolves.
- **hierarchy** — node is a leaf of the governed chain; records `anchorNodeId` + resolution `chain`.
- **execution state** — node Status is not Completed/Terminal and no open Active-Change conflicts.
- **dependencies** — re-verified `Test-DepsSatisfied`.
- **acceptance criteria** — inherited from the nearest Milestone (or AC-carrying) ancestor; recorded as `AC_INHERITED` / `AC_ABSENT_WARN`.
- **repo / project** — informational here (final gate is preflight PART 2 / PART 6).
- **no conflict** — no node/project/file-glob conflict with another reserved work item.
- **no incompatible reservation** — node not subject to an incompatible open reservation.

### 3.5 Block-state semantics (capability f) — full token set

| Token | Meaning | current-task.json | preflight.json verdict |
|---|---|---|---|
| `NO_IMPLEMENTABLE_DESCENDANT` | container anchor with **zero** eligible leaf descendants (all dep-blocked / trial-excluded / not planned) | status `PREFLIGHTED`, nodeId=anchor, nextAllowedAction `RESOLVE_GOVERNANCE_BLOCK` | block token |
| `HUMAN_GOVERNANCE_REQUIRED` | anchor breakdown incomplete or a human governance decision is required to make a target selectable | status `PREFLIGHTED`, nodeId=anchor, nextAllowedAction `RESOLVE_GOVERNANCE_BLOCK` | block token |
| `IMPLEMENTATION_TARGET_UNKNOWN` | anchor (or selected node) cannot be classified (UNKNOWN_NODE_TYPE) | status `PREFLIGHTED`, nodeId=anchor, nextAllowedAction `RESOLVE_GOVERNANCE_BLOCK` | block token |
| `TASK_SELECTION_AMBIGUOUS` | no current-work and no governed next-work target (pre-existing) | (existing minimal handling — no current-task write) | verdict token |
| `SCOPE_INCOMPLETE` | **leaf** selected but repo/project scope not derivable (preflight PART 6, pre-existing) | status `PREFLIGHTED`, nodeId=leaf, nextAllowedAction `RESOLVE_PREFLIGHT` | verdict token |

Block tokens short-circuit the preflight **before** scope derivation (they are selection-time verdicts); `SCOPE_INCOMPLETE` remains a *post-selection* verdict for a selected leaf. Both are non-CLEAR governed blockers.

### 3.6 Preflight integration (`Test-DevelopmentPreflight.ps1`)

- **PART 1 guard extended:** `TASK_SELECTION_AMBIGUOUS` keeps its existing minimal path. The new block tokens write a **block preflight** (verdict = token, `blockingReasons` = `BlockReason`) **and** a current-task.json record (status `PREFLIGHTED`, nodeId = anchor, nextAllowedAction `RESOLVE_GOVERNANCE_BLOCK`, `implementability` = anchor class). The C# `START_NEXT_CYCLE` contract (`ResultingExpectedState: PREFLIGHTED`) holds because status remains `PREFLIGHTED`.
- **CLEAR path:** record `implementability: "IMPLEMENTABLE_LEAF"` in current-task.json; emit `leafValidation[]` in preflight.json; `nextAllowedAction = RESERVE`.
- Verdict precedence unchanged; block tokens naturally outrank SCOPE_INCOMPLETE because they short-circuit earlier.

### 3.7 M04 gate (`Reserve-DevelopmentChange.ps1:360`) — backward compatible

```powershell
if ($preflight.verdict -ne "CLEAR" -or $current.nextAllowedAction -ne "RESERVE" -or $current.status -ne "PREFLIGHTED") { Stop-Outcome "STOP_PREFLIGHT_STALE" ... }
$impl = [string]$current.implementability
if ($impl -and $impl -ne "IMPLEMENTABLE_LEAF") { Stop-Outcome "STOP_NOT_IMPLEMENTABLE_LEAF" ... }
```

Enforced **only when the field is present**. Legacy fixtures (`Test-DBM04Safety` hand-writes current-task.json without `implementability`; `Test-DBM12-2Commands`) keep the old behavior. All DB-M03.1 preflights write the field, so every CLEAR reservation thereafter is a proven `IMPLEMENTABLE_LEAF`.

### 3.8 M05 gate (`New-ChatGptHandoff.ps1:70`) — container guard

```powershell
if ($script:CurrentState.status -ne "RESERVED" -or $script:CurrentState.nextAllowedAction -ne "CHATGPT_HANDOFF") { Stop-Outcome "HANDOFF_STATE_STALE" ... }
$impl = [string]$script:CurrentState.implementability
if ($impl -and $impl -ne "IMPLEMENTABLE_LEAF") { Stop-Outcome "HANDOFF_CONTAINER_PROHIBITED" ... }
```

Same backward-compatible pattern. A container can never reach M05 anyway (M04 + preflight already gate it), but this is the explicit capability-(j) guard.

### 3.9 Regression impact

- **C# DevBridge.Tests / DevBridge.UITests:** all M03/M04/M05 scripts are FAKED (`FakeScriptRunner`) → PowerShell changes cannot break the C# suites.
- **Test-DBM12-2Commands:** runs the 9 M12.2 lifecycle commands (not M03/M04/M05) against hand-written state without `implementability` → unaffected.
- **Test-DBM04Safety:** hand-writes state without `implementability` → M04 compat gate passes it through unchanged.
- **Test-DBM124TrialCycleClosure S8/S9:** currently assert the OLD container-as-task behavior (`task == "M-07-0.2"`) → **rewritten** to assert the new block behavior (`NO_IMPLEMENTABLE_DESCENDANT`, `task == ""`). S7 (no history → selects leaf WI-07-0.2.4) still passes unchanged.

## 4. Test matrix (32 tests) — `scripts/Test-DBM031ImplementableLeafSelection.ps1`

Fixture root `logs\selftest\db-m03-1\*`, byte-identical workbook copies + state/tasks dirs + env overrides (DB-M12.4 pattern). All fixtures use generic identities; no live workbook/state/git mutation; build 0 warnings/0 errors.

**A. Classification (10):**
1. Milestone → NON_IMPLEMENTABLE_CONTAINER
2. Feature → NON_IMPLEMENTABLE_CONTAINER
3. Layer → NON_IMPLEMENTABLE_CONTAINER
4. Leaf WorkItem (breakdown blank) → IMPLEMENTABLE_LEAF
5. WorkItem BreakdownComplete=No → INCOMPLETE_WORK_ITEM
6. WorkItem with children → NON_IMPLEMENTABLE_CONTAINER
7. Task with children → NON_IMPLEMENTABLE_CONTAINER
8. Leaf Task → IMPLEMENTABLE_LEAF
9. Subtask → IMPLEMENTABLE_LEAF
10. Unknown NodeType → UNKNOWN_NODE_TYPE

**B. Container resolution (7):**
11. Milestone → one eligible planned child leaf → SELECTED leaf
12. Milestone → WorkItem → Task → Subtask deep chain → SELECTED leaf
13. Milestone with dep-unsatisfied child → NO_IMPLEMENTABLE_DESCENDANT
14. Milestone whose only child is trial-proven-excluded → NO_IMPLEMENTABLE_DESCENDANT
15. Container with dep-blocked-then-eligible siblings → picks eligible in governed order
16. Container with INCOMPLETE_WORK_ITEM and no eligible descendant → HUMAN_GOVERNANCE_REQUIRED
17. Unknown-type anchor → IMPLEMENTATION_TARGET_UNKNOWN

**C. Selection flow / CURRENT WORK FIRST (6):**
18. Current-work leaf anchor → SELECTED as itself
19. Current-work container → resolves to descendant leaf
20. No current-work → NEXT WORK fallback selects a planned leaf
21. No current-work and no planned → TASK_SELECTION_AMBIGUOUS
22. Trial-proven leaf excluded as child; fresh sibling eligible → selects fresh sibling
23. Dependency order preserved (a child whose dep is unsatisfied never precedes a satisfied child)

**D. Preflight integration (5):**
24. Leaf CLEAR → current-task.json implementability=IMPLEMENTABLE_LEAF, nextAllowedAction=RESERVE
25. Container block → preflight verdict NO_IMPLEMENTABLE_DESCENDANT, current-task status PREFLIGHTED, nodeId=anchor, nextAllowedAction=RESOLVE_GOVERNANCE_BLOCK
26. Human-governance block → verdict HUMAN_GOVERNANCE_REQUIRED
27. Unknown block → verdict IMPLEMENTATION_TARGET_UNKNOWN
28. CLEAR leaf emits leafValidation[] with AC_INHERITED from Milestone ancestor

**E. M04 / M05 gates (4):**
29. M04 refuses RESERVE when implementability present and ≠ IMPLEMENTABLE_LEAF → STOP_NOT_IMPLEMENTABLE_LEAF
30. M04 backward-compat: state without implementability still reserves (legacy T2-equivalent)
31. M05 refuses handoff for container → HANDOFF_CONTAINER_PROHIBITED
32. M05 backward-compat: state without implementability still handoffs

**Invariants (all scenarios):** live workbook SHA256 unchanged; Nexus git delta 0; live state files unchanged; no hard-coded WI-07/CHG identity in the modified scripts; no structural workbook mutation; solution builds 0/0.

## 5. Outputs

- `design/DB-M03.1_IMPLEMENTABLE_LEAF_TASK_SELECTION.md` (this file)
- `scripts/Test-DBM031ImplementableLeafSelection.ps1` (32-test matrix)
- modified: `scripts/Get-NextTask.ps1`, `scripts/Test-DevelopmentPreflight.ps1`, `scripts/Reserve-DevelopmentChange.ps1`, `scripts/New-ChatGptHandoff.ps1`, `scripts/Test-DBM124TrialCycleClosure.ps1` (S8/S9 only)
- `state/db-m03-1-result.json`, `tasks/DB-M03.1_IMPLEMENTATION_REPORT.md`

## 6. Acceptance criteria (milestone mapping)

| Capability | Where satisfied |
|---|---|
| (a) deterministic classification | §3.1 `Get-ImplementabilityClass` |
| (b) container→descendant resolution | §3.2 `Resolve-ImplementableDescendant` |
| (c) leaf validation | §3.4 `leafValidation[]` |
| (d) CURRENT WORK FIRST preserved | §3.3 anchor order unchanged |
| (e) no manual re-selection as normal path | automatic resolution only; no interactive picker added |
| (f) honest block states | §3.5 token set + RESOLVE_GOVERNANCE_BLOCK |
| (g) dependency order preserved | §3.2 Test-DepsSatisfied gate + governed ordering |
| (h) trial-history exclusion (TRIAL only) | §3.2 Test-NotTrialProven unchanged |
| (i) M04 gate only CLEAR for leaf | §3.7 STOP_NOT_IMPLEMENTABLE_LEAF (compat) |
| (j) M05 never handoff for container | §3.8 HANDOFF_CONTAINER_PROHIBITED (compat) |
| (k) reproduce M-07-0.2 fixture safely | Test-DBM124 S8/S9 rewrite + matrix B13/B14 |
