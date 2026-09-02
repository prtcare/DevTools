# MAPPING REPORT - DB-M02 (Canonical Nexus Development Control Mapping)

**Workbook:** C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx
**Mapping generated:** 2026-08-30 | **SHA256 (before):** E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941
**Status:** Read-only mapping. The workbook was NOT modified.

## 1. All 14 worksheets and their governance roles

Every worksheet is understood. None is silently ignored.

| # | Sheet | Role | Header row | Data starts | Unique key | Mutation |
|---|-------|------|-----------|-------------|-----------|----------|
| 1 | Control Center | DERIVED_SUMMARY | labels row 4 | row 5 | - | UPDATE_EXISTING (manual cells only) |
| 2 | Master Roadmap | CURRENT_STATE | 5 | 6 | Node ID | UPDATE_EXISTING + append for new nodes |
| 3 | Active Changes | GOVERNANCE (concurrency ledger) | 5 | 6 | Change ID | APPEND_ONLY (reservations + lifecycle updates, never delete) |
| 4 | Audit Findings | GOVERNANCE | 5 | 6 | Finding ID | UPDATE_AND_APPEND_HISTORY |
| 5 | Session Protocol | PROTOCOL | 5 (+ sub-headers) | 6 | Step | NONE |
| 6 | Version History | APPEND_ONLY | 5 | 6 | Node ID + Record Version | APPEND_ONLY |
| 7 | Phase Plan | GOVERNANCE | 4 | 5 | Phase Step | UPDATE_AND_APPEND_HISTORY |
| 8 | Architecture Decisions | GOVERNANCE | 4 | 5 | ADR ID | APPEND_ONLY |
| 9 | Open Decisions | GOVERNANCE | 4 | 5 | Decision ID | UPDATE_AND_APPEND_HISTORY |
| 10 | Dependencies & Blockers | GOVERNANCE | 4 | 5 | Relation ID | UPDATE_AND_APPEND_HISTORY |
| 11 | Tool & Integration Registry | GOVERNANCE | 4 | 5 | Tool / Service | UPDATE_AND_APPEND_HISTORY |
| 12 | Activity Log | APPEND_ONLY | 4 | 5 | Activity ID | APPEND_ONLY |
| 13 | Development Guide | REFERENCE | 4 | 5 | Milestone ID | UPDATE_EXISTING (mirror Master Roadmap) |
| 14 | Existing Assets | REFERENCE | 4 | 5 | Area | UPDATE_AND_APPEND_HISTORY |

## 2. Governance roles in plain English

- **PROTOCOL - Session Protocol.** Executable governance: 14 numbered steps (7 pre-implementation, 7 implementation/completion) plus 6 append-only version rules. No file edit is permitted before Step 7. DevBridge must never override it.
- **CURRENT_STATE - Master Roadmap.** The only sheet holding the latest approved state of every node. Everything else either references it, archives it, or mirrors it.
- **APPEND_ONLY - Version History and Activity Log.** The memory. Version History archives governed state changes; Activity Log records events. Neither may ever have a historical row edited or deleted.
- **GOVERNANCE - Active Changes, Audit Findings, Phase Plan, Architecture Decisions, Open Decisions, Dependencies & Blockers, Tool & Integration Registry.** The control surfaces: reservations, obligations, sequence, constraints, open questions, explicit relationship graph, and approved tooling.
- **REFERENCE - Development Guide and Existing Assets.** Plain-English planning view and the reuse catalog. Both feed task-context generation.
- **DERIVED_SUMMARY - Control Center.** Dashboard summarizing the rest. Mixes formula cells (derived from Master Roadmap) and manual cells that observably drift; DevBridge recomputes rather than trusts.

## 3. Cross-sheet relationships

Validated by value matching in DB-M01 (16 reference checks) and extended here:

| Relationship | From | To | Resolution |
|--------------|------|----|-----------|
| Current state of | Master Roadmap (Node ID) | Version History (Node ID) | 100% on Parent ID test; Is Current=Yes is the current projection |
| Reserves | Active Changes (Node ID / Affected Nodes) | Master Roadmap (Node ID) | 92% |
| Graphs | Dependencies & Blockers (From Node / Depends On-Blocks) | Master Roadmap (Node ID) | 100% (From Node), 47% (Depends On / Blocks, free text) |
| Constrains | Architecture Decisions (Roadmap Links) | Master Roadmap (Node ID) | 65% |
| Affects | Open Decisions (Roadmap Links) | Master Roadmap (Node ID) | 86% |
| Targets | Audit Findings (Roadmap Link) | Master Roadmap (Node ID) | 89% |
| Executes | Phase Plan (Roadmap Link) | Master Roadmap (Node ID) | 40% (free text) |
| Mirrors | Development Guide (Milestone ID) | Master Roadmap (Node ID) | 100% |
| Causes | Version History (Change ID) | Active Changes (Change ID) | 100% |
| Events | Activity Log (Change ID) | Active Changes (Change ID) | 99-100% |
| Originates | Dependencies & Blockers (Source Change) | Active Changes (Change ID) | - |
| Resolves | Open Decisions (Resolution / ADR) | Architecture Decisions (ADR ID) | 2% (free text) |

ID spaces: RoadmapNode (01/F-/M-/WI-/T-/S-), ChangeId (CHG-YYYYMMDD-NNN), AdrId (ADR-NNN), DecisionId (DEC-NNN), ActivityId (ACT-YYYYMMDD-NNN), FindingId (AF-NNN), RelationId (REL-NNN), PhaseStep (P1-00..P2-10).

The authoritative governing flow:

```
Session Protocol GOVERNS all sheets
Control Center SUMMARIZES Master Roadmap / Active Changes / Version History
Master Roadmap CURRENT_STATE_OF Version History (which ARCHIVES it)
Active Changes RESERVES Master Roadmap nodes -> RELEASES_RECORDS to Version History -> EVENTED_BY Activity Log
Dependencies & Blockers GRAPHS Master Roadmap nodes (authoritative over textual Dependencies)
Architecture Decisions CONSTRAINS Master Roadmap nodes -> RESOLVES Open Decisions
Open Decisions AFFECTS Master Roadmap nodes -> RESOLVED_BY Architecture Decisions
Audit Findings TARGETS Master Roadmap nodes
Phase Plan EXECUTES Master Roadmap nodes
Development Guide MIRRORS Milestone nodes
Existing Assets SUPPORTS task-context reuse
Activity Log EVIDENCES every governed write
```

## 4. Mandatory read rules

The canonical read path, applied before every task:

1. **Session Protocol** - the full protocol; it is executable governance.
2. **Control Center** - changelog narrative (current workbook version, recent governed changes), headline metrics, control state. Never trust manual summary numbers; recompute.
3. **Master Roadmap** - the target node, its full ancestry (Layer > Feature > Milestone > WorkItem > Task > Subtask), Dependencies, Status, Acceptance Criteria, Current Evidence, Next Action. Read the full governed data range A6:AG675 (659 records; corrected by DB-M02.1 - the formal Excel table boundary A5:AG630 is NOT the governance boundary).
4. **Active Changes** - every row NOT Completed/Cancelled (Session Protocol step 3): Preflight Verdict, Conflicts With, Dependency On, scope columns, Branch, Worktree.
5. **Dependencies & Blockers** - all relations on the target node; resolve the transitive closure of Open/Blocking relations.
6. **Architecture Decisions** - all Approved ADRs touching scope; a contradiction is ARCHITECTURE CONFLICT.
7. **Open Decisions** - all Open rows touching scope; a blocking unresolved decision stops preflight.
8. **Audit Findings** - findings linked to the target node or overlapping scope.
9. **Version History** - Is Current=Yes confirmation and version chains when verifying current state.
10. **Phase Plan** - permitted execution sequence (current/non-superseded rows only).
11. **Development Guide** - plain-English milestone guidance for task context.
12. **Existing Assets** - reuse instructions for task context (instruct REUSE, not rebuild).
13. **Tool & Integration Registry** - only when the task involves external tools/integrations (approval/safety gate).
14. **Activity Log** - correlation and human-review evidence when verifying prior operations.

## 5. Conditional update rules (write triggers)

- **Master Roadmap** is updated on approved completion (Status, Current Evidence, Next Action, progress) and on any governed fact/concept/status/ownership change - always paired with a new Version History record (Session Protocol step 14).
- **Active Changes**: reservation appended BEFORE editing (step 7); lifecycle fields (Status, timestamps, Result / Evidence, Branch, Worktree, Validation Result, ADR ID) updated on the owning row; rows never deleted (steps 12-13).
- **Version History**: a newer Record Version appended whenever a governed fact changes, even without code changes ('Concept changes count').
- **Activity Log**: an Activity ID appended for every governed operation DevBridge performs, with before/after values, preflight verdict, result, evidence, and Human Review Status.
- **Audit Findings**: update Status/Verification when a task resolves a finding; append when a new finding is discovered.
- **Open Decisions**: Status to Decided + Resolution / ADR when a task resolves a decision; append new DEC- rows as they arise.
- **Dependencies & Blockers**: append REL- relations when discovered; mark Satisfied/Resolved when cleared.
- **Architecture Decisions**: append a new ADR when a decision is approved; mark superseded ADRs without deleting.
- **Phase Plan**: update Status to Completed with Exit Evidence on phase completion; mark superseded rows, never delete.
- **Development Guide**: mirror Master Roadmap milestone status/evidence/next step.
- **Existing Assets**: update/append when an implementation materially creates, replaces, or invalidates an asset record.
- **Tool & Integration Registry**: update Current State / Approval / Safety when tooling changes; never authorize an unlisted or unapproved tool.
- **Control Center**: update manual cells only (changelog, workbook version, summary values, release assessment) - recomputed before writing; formula cells never written.

Every write to a governed sheet is paired with an Activity Log record and, where it changes a governed fact, a Version History record.

## 6. Append-only protections

- **Version History**: append-only. Never update, delete, or rewrite existing historical rows. Node ID + Record Version unique; exactly one Is Current=Yes per node.
- **Activity Log**: append-only. Never delete or update activity records.
- **Active Changes**: completed reservation rows remain. Never delete. Lifecycle fields may only be updated on the owning reservation row.
- **Architecture Decisions**: approved ADRs are authoritative; rows are appended; superseded ADRs are marked, not deleted.
- **Phase Plan / Open Decisions / Dependencies & Blockers / Audit Findings / Existing Assets**: superseded/old rows are preserved with explanatory state; never deleted.
- **Session Protocol**: the 'Never delete' rule guarantees cancelled, superseded, and mistaken history remains with explanatory state.
- **Master Roadmap**: contains only the latest approved state per Node ID; the past lives in Version History. Never rewritten.

## 7. Unresolved mappings

1. **Master Roadmap Column1/Column2/Column3 (AE:AG)** - present in the table schema, observed empty; purpose unknown. Low impact.
2. **Master Roadmap rows beyond the table (A5:AG630 vs A1:AG675)** - RESOLVED in DB-M02.1. The 34 rows below the table end (rows 631-675: F-12-4..F-12-16 features; F-07-10 / F-06-8 / M-04-3.3 / M-12-0.4 subtrees added under ADR-005, CHG-20260826-003) are structurally valid governed RoadmapNode records, not table leftovers. Governance now covers the full structurally valid used range A6:AG675 (659 records).
3. **Active Changes columns Z:AD outside the Excel table (A5:Y8)** - Version History ID, ADR ID, Affected Nodes, Change Type, Validation Result are advisory; sparse. Table may need extension (human decision).
4. **Control Center manual summary drift** - observed: Workbook version 1.8 vs narrative v3.26; Roadmap nodes 624 vs 659 actual. DevBridge recomputes rather than trusts; surfaced as a governance gap.
5. **Identifier linkage is by naming convention** - no enforced foreign keys; DevBridge validates every reference by value matching.
6. **Active Changes Status is free-form narrative** - DevBridge classifies by leading keyword (Completed/Cancelled/Blocked/In Progress/Open); flagged for human normalization.
7. **Status vocabulary split (Complete vs Completed)** - treated as equivalent for eligibility.
8. **Version History versioning semantics** - resolution rule (Record Version / Is Current / Supersedes Version) now derivable from Session Protocol append rules + ADR-003; not yet a closed algorithm in the workbook.
9. **Activity Log Human Review Status sparsely populated** - DevBridge populates it on every appended record.

None of these prevents safe preflight; each is handled by an explicit rule in `development-control-map.json`.

## 8. Can the workbook safely drive automated preflight?

**YES, with documented caveats.**

The Session Protocol was extracted in full (14 steps + 6 append-only rules) and can be enforced deterministically: mandatory reads -> scope declaration -> rule-by-rule concurrency comparison -> single verdict (CLEAR / DEPENDENCY FOUND / OVERLAP FOUND / CONFLICT FOUND / ARCHITECTURE CONFLICT) -> mandatory reservation before editing -> verification -> human review -> integration -> append-only completion.

Automated preflight is safe because:
- The target node's identity, ancestry, dependencies, status, and acceptance criteria are all machine-readable on Master Roadmap.
- The concurrency ledger (Active Changes) is filterable to open reservations (status not Completed/Cancelled).
- The explicit relationship graph (Dependencies & Blockers) is machine-readable and authoritative for eligibility.
- Approved ADRs and Open Decisions provide explicit constraint sets; contradictions map to ARCHITECTURE CONFLICT.
- The append-only model guarantees history is never rewritten, so preflight can trust Is Current markers.
- Every ambiguity found in DB-M01 was resolved into an explicit rule (classify by keyword, recompute summaries, read the table range, validate references by value) or listed as a non-blocking unresolved item.

DevBridge therefore CAN safely read, follow, and later update the workbook without changing its governance model - provided it never bypasses Session Protocol, never writes formula cells, never deletes history, and validates every cross-sheet reference by value.

---

## DB-M02.1 MASTER ROADMAP RANGE CORRECTION

**Date:** 2026-08-30 | **Milestone:** DB-M02.1 (corrective) | **Workbook SHA256 (after):** E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941 (unchanged)

**What changed.** DB-G02 validation failed on critical issue C-1: Master Roadmap governance was keyed to the formal Excel table boundary `A5:AG630`, but the workbook's actual governed content extends to row 675. Rows 631-675 hold 34 structurally valid RoadmapNode records (F-12-4..F-12-16 features, plus the F-07-10 / F-06-8 / M-04-3.3 / M-12-0.4 subtrees added under ADR-005, CHG-20260826-003). The formal table metadata is stale (not extended when content was appended); it is NOT the governance boundary.

**Detection rule (now canonical).** The governed range is derived by structural validity, never by the Excel table boundary, never hard-coded:

1. Start from the header row (row 5) and the worksheet's used range.
2. Iterate all content rows below the header.
3. A row is a governed RoadmapNode record iff: column A matches the RoadmapNode ID pattern `^(F-\d+-\d+|M-\d+-\d+\.\d+|WI-\d+-\d+\.\d+\.\d+|T-\d+-\d+\.\d+\.\d+\.\d+|S-\d+-\d+\.\d+\.\d+\.\d+\.\d+|\d{2})$` AND column C (Node Type) is in {Layer, Feature, Milestone, WorkItem, Task, Subtask}.
4. Ignore blank rows. Do NOT truncate at the Excel table end. Do NOT silently classify malformed rows - report them.

**Mapping/config effects.**
- `config/development-control-map.json` (schemaVersion 2.1): Master Roadmap now distinguishes `formalExcelTableRange` (`A5:AG630`) from `governedDataRange` (`A6:AG675`, startRow 6, endRow 675, recordCount 659, withinTableRecordCount 625, beyondTableRecordCount 34) plus the detection rule. The old read rule (read the table, treat 631-675 as NOT governed) is replaced by the full-range rule. Unresolved item 2 is marked RESOLVED.
- `config/sheet-governance.json`: Master Roadmap new-node write trigger updated to append in the governed data range below the last governed record, with an explicit note that the formal table boundary is not the governance boundary. No other sheet was changed.

**Result:** 34 previously omitted governed records recovered; total governed = 659. Hierarchy valid (0 duplicate Node IDs, 0 broken parents, 0 orphans, sort keys consistent). All 34 recovered nodes are referenced by other governed sheets (144 distinct references; notably Active Changes reservations CHG-20260830-004/-005 -> M-07-10.3 and CHG-20260830-008/-011/-012 -> M-04-3.3, plus ADR-005). Safe to rerun DB-G02.

---

## DB-M02 RESULT

Workbook: C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx
Sheets mapped: 14
Governance roles: PROTOCOL 1 / CURRENT_STATE 1 / APPEND_ONLY 2 / GOVERNANCE 7 / REFERENCE 2 / DERIVED_SUMMARY 1
Session Protocol: extracted (14 steps + 6 append-only rules)
Cross-sheet relationships: 16 reference checks validated + ID-space model
Unresolved mappings: 9 (none block safe preflight)
mappingReady: TRUE
Workbook modified: NO
