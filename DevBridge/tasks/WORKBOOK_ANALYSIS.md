# WORKBOOK ANALYSIS - DB-M01 (Development Control Workbook Discovery)

**Workbook:** C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx

**Inspected:** 08/30/2026 17:03:09 UTC | SHA256 (before): E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941
**Status:** Read-only inspection. The workbook was NOT modified.

## Overview

- Worksheets: 14
- Excel tables: 3
- Defined names (named ranges): 0
- Charts / drawings: 1 chart(s)

## Worksheets

| # | Sheet | Layout | Used range | Rows | Cols | Header row | Excel table |
|---|-------|--------|------------|------|------|------------|-------------|
| 1 | Control Center | dashboard | A1:M30 | 30 | 13 | - | - |
| 2 | Master Roadmap | table | A1:AG675 | 675 | 33 | 5 | MasterRoadmapTable |
| 3 | Active Changes | table | A1:AD78 | 78 | 30 | 5 | ActiveChangesTable |
| 4 | Audit Findings | table | A1:M23 | 23 | 13 | 5 | AuditFindingsTable |
| 5 | Session Protocol | tabular-list | A1:H34 | 34 | 8 | 5 | - |
| 6 | Version History | tabular-list | A1:AJ957 | 957 | 36 | 5 | - |
| 7 | Phase Plan | tabular-list | A1:I29 | 29 | 9 | 4 | - |
| 8 | Architecture Decisions | tabular-list | A1:J9 | 9 | 10 | 4 | - |
| 9 | Open Decisions | tabular-list | A1:J8 | 8 | 10 | 4 | - |
| 10 | Dependencies & Blockers | tabular-list | A1:J15 | 15 | 10 | 4 | - |
| 11 | Tool & Integration Registry | tabular-list | A1:J20 | 20 | 10 | 4 | - |
| 12 | Activity Log | dashboard | A1:AH52 | 52 | 34 | - | - |
| 13 | Development Guide | tabular-list | A1:K164 | 164 | 11 | 4 | - |
| 14 | Existing Assets | tabular-list | A1:F15 | 15 | 6 | 4 | - |

## Excel tables found

- **MasterRoadmapTable** on *Master Roadmap* - ref A5:AG630, 33 columns:
    - Node ID
    - Parent ID
    - Node Type
    - Sort Key
    - Hierarchy Path
    - Layer
    - Phase
    - Name
    - Outcome / Purpose
    - Dependencies
    - Parallel Safe
    - Projects
    - Files / Globs
    - Schema Contexts
    - Contracts / APIs
    - Gate
    - Acceptance Criteria
    - Status
    - Breakdown Complete
    - Manual Progress
    - Derived Progress
    - Reported Progress
    - Owner
    - Priority
    - Risk
    - Source
    - Notes
    - Simple Goal
    - Current Evidence
    - Next Action
    - Column1
    - Column2
    - Column3
- **ActiveChangesTable** on *Active Changes* - ref A5:Y8, 25 columns:
    - Change ID
    - Node ID
    - Milestone / Feature
    - Summary
    - Requested By
    - Worker
    - Repositories
    - Projects
    - Files / Globs
    - Schema Contexts
    - Contracts / APIs
    - Status
    - Preflight Verdict
    - Conflicts With
    - Dependency On
    - Risk
    - Branch
    - Worktree
    - Started At
    - Last Heartbeat
    - Completed At
    - Result / Evidence
    - Change Version
    - Session / Chat
    - Notes
- **AuditFindingsTable** on *Audit Findings* - ref A5:M23, 13 columns:
    - Finding ID
    - Severity
    - Area
    - Repository
    - Evidence
    - Impact
    - Required Action
    - Roadmap Link
    - Status
    - Owner
    - Due Gate
    - Verification
    - Notes

## Concept coverage

Classification: **CONFIRMED** = found at sheet/header/named-range level. **LIKELY** = inferred from sampled values only. **UNRESOLVED** = not found or ambiguous.

| Concept | Status | Evidence |
|---------|--------|----------|
| Goals | CONFIRMED | [header] Master Roadmap::AB 'Simple Goal'<br>[text] Master Roadmap: 'Simple Goal'<br>[header] Master Roadmap::I 'Outcome / Purpose'<br>[header] Version History::I 'Outcome / Purpose'<br>[text] Master Roadmap: 'Outcome / Purpose'<br>[text] Version History: 'Outcome / Purpose'<br>[header] Tool & Integration Registry::C 'Primary Purpose'<br>[text] Tool & Integration Registry: 'Primary Purpose' |
| Milestones | CONFIRMED | [label] Control Center::D 'Milestones'<br>[header] Active Changes::C 'Milestone / Feature'<br>[header] Development Guide::C 'Milestone ID'<br>[header] Development Guide::D 'Milestone'<br>[text] Control Center: 'Milestones'<br>[text] Master Roadmap: 'Build when this milestone becomes active.'<br>[text] Master Roadmap: 'Milestone'<br>[text] Active Changes: 'Milestone / Feature'<br>[text] Version History: 'Milestone'<br>[text] Development Guide: 'NEXUS DEVELOPMENT GUIDE — MILESTONES IN PLAIN ENGLISH'<br>[text] Development Guide: 'Milestone'<br>[text] Development Guide: 'Milestone ID'<br>[nodeType] Master Roadmap: 'Milestone'<br>[nodeType] Version History: 'Milestone' |
| Work Items | CONFIRMED | [label] Control Center::G 'Work items'<br>[text] Control Center: 'Work items'<br>[text] Phase Plan: 'A work item can be resolved, reserved, executed/reviewed and evidenced'<br>[nodeType] Master Roadmap: 'WorkItem'<br>[nodeType] Version History: 'WorkItem'<br>[text] Active Changes: 'WI-07-0.1.3'<br>[text] Active Changes: 'WI-07-0.1.3 Nexus.Developer bootstrap and DevTools migration' |
| Tasks | CONFIRMED | [nodeType] Master Roadmap: 'Subtask'<br>[nodeType] Master Roadmap: 'Task'<br>[nodeType] Version History: 'Subtask'<br>[nodeType] Version History: 'Task'<br>[text] Active Changes: 'T-07-0.1.3.2'<br>[text] Activity Log: 'ACT-20260825-001'<br>[text] Activity Log: 'ACT-20260825-002'<br>[text] Activity Log: 'ACT-20260825-003'<br>[text] Activity Log: 'ACT-20260825-004'<br>[text] Master Roadmap: 'nexus-roadmap.yaml v2.2'<br>[text] Active Changes: 'nexus-roadmap.yaml v2.2'<br>[text] Active Changes: 'M-07-0.1 Versioned roadmap and simultaneous-development control'<br>[text] Audit Findings: 'ChatTurnIdentity returns nexus-dev, empty UserId and fixed permissions.'<br>[text] Audit Findings: 'Cross-tenant access test fails closed.'<br>[text] Version History: 'nexus-roadmap.yaml v2.2'<br>[text] Architecture Decisions: 'Cross-layer Phase 1'<br>[header] Master Roadmap::AD 'Next Action'<br>[text] Master Roadmap: 'Next Action' |
| Dependencies | CONFIRMED | [sheet] Dependencies & Blockers<br>[header] Master Roadmap::J 'Dependencies'<br>[header] Active Changes::O 'Dependency On'<br>[header] Version History::J 'Dependencies'<br>[text] Master Roadmap: 'Dependencies'<br>[text] Active Changes: 'Dependency On'<br>[text] Active Changes: 'Source dependency satisfied: DevTools.zip supplied 2026-08-26'<br>[text] Version History: 'Dependencies'<br>[text] Dependencies & Blockers: 'DEPENDENCIES & BLOCKERS — EXPLICIT RELATIONSHIP GRAPH'<br>[text] Dependencies & Blockers: 'Dependency'<br>[text] Activity Log: 'Blocked dependency recorded'<br>[text] Activity Log: 'Blocked dependency recorded; Blocked'<br>[header] Phase Plan::E 'Depends On'<br>[header] Dependencies & Blockers::C 'Depends On / Blocks'<br>[header] Development Guide::J 'Depends On'<br>[text] Phase Plan: 'Depends On'<br>[text] Dependencies & Blockers: 'Depends On / Blocks'<br>[text] Development Guide: 'Depends On'<br>[text] Phase Plan: 'Required blockers cleared for Phase 1 path'<br>[header] Dependencies & Blockers::D 'Relation Type'<br>[text] Dependencies & Blockers: 'Relation Type' |
| Status | CONFIRMED | [header] Master Roadmap::R 'Status'<br>[header] Active Changes::L 'Status'<br>[header] Audit Findings::I 'Status'<br>[header] Version History::R 'Status'<br>[header] Phase Plan::G 'Status'<br>[header] Architecture Decisions::C 'Status'<br>[header] Open Decisions::I 'Status'<br>[header] Dependencies & Blockers::F 'Status'<br>[label] Activity Log::AG 'Human Review Status'<br>[header] Development Guide::F 'Status'<br>[text] Master Roadmap: 'Status'<br>[text] Active Changes: 'Status'<br>[text] Audit Findings: 'Status'<br>[text] Version History: 'Status'<br>[text] Phase Plan: 'Status'<br>[text] Architecture Decisions: 'Status'<br>[text] Open Decisions: 'Status'<br>[text] Dependencies & Blockers: 'Status'<br>[text] Activity Log: 'Human Review Status'<br>[text] Development Guide: 'Status'<br>[header] Tool & Integration Registry::F 'Current State'<br>[header] Existing Assets::E 'State'<br>[text] Master Roadmap: 'MASTER ROADMAP — CURRENT STATE'<br>[text] Tool & Integration Registry: 'Current State'<br>[text] Existing Assets: 'State'<br>[text] Existing Assets: 'Security, durable state and final layer ownership are still incomplete.' |
| Acceptance Criteria | CONFIRMED | [header] Master Roadmap::Q 'Acceptance Criteria'<br>[header] Version History::Q 'Acceptance Criteria'<br>[text] Master Roadmap: 'Acceptance Criteria'<br>[text] Version History: 'Acceptance Criteria' |
| Versioning | CONFIRMED | [sheet] Version History<br>[header] Active Changes::W 'Change Version'<br>[header] Active Changes::Z 'Version History ID'<br>[header] Version History::AA 'Record Version'<br>[header] Version History::AE 'Supersedes Version'<br>[header] Version History::Z 'Baseline Version'<br>[label] Activity Log::P 'Expected RowVersion'<br>[label] Activity Log::Q 'Previous RowVersion'<br>[label] Activity Log::R 'New RowVersion'<br>[text] Active Changes: 'Version History ID'<br>[text] Active Changes: 'Change Version'<br>[text] Active Changes: 'M-07-0.1 Versioned roadmap and simultaneous-development control'<br>[text] Session Protocol: 'Documents and versions read'<br>[text] Session Protocol: 'Node missing or multiple current versions'<br>[text] Version History: 'VERSION HISTORY — APPEND ONLY'<br>[text] Version History: 'Baseline Version'<br>[text] Version History: 'Record Version'<br>[text] Version History: 'Supersedes Version'<br>[text] Architecture Decisions: 'Master Roadmap | Version History'<br>[text] Activity Log: 'Previous RowVersion'<br>[text] Activity Log: 'New RowVersion'<br>[text] Activity Log: 'Expected RowVersion'<br>[text] Activity Log: 'Workbook v1.1 / 624 current nodes / 685 version records / ADR-001..004'<br>[text] Architecture Decisions: 'Daily use should be simple, while history must remain complete and traceable.'<br>[text] Tool & Integration Registry: 'Repositories, branches, PRs, history'<br>[header] Version History::AC 'Is Current'<br>[text] Version History: 'Is Current'<br>[header] Architecture Decisions::G 'Supersedes / Related'<br>[text] Architecture Decisions: 'Supersedes / Related'<br>[header] Version History::AB 'Effective From'<br>[text] Version History: 'Effective From' |
| Activity Log | CONFIRMED | [sheet] Activity Log<br>[label] Activity Log::A 'Activity ID'<br>[text] Activity Log: 'ACTIVITY LOG — APPEND-ONLY DEVELOPMENT EVENTS'<br>[text] Activity Log: 'Activity ID'<br>[text] Existing Assets: 'IToolCatalog, IToolGateway, descriptors, invocations and results exist.'<br>[label] Activity Log::B 'Timestamp UTC'<br>[text] Activity Log: 'Timestamp UTC'<br>[label] Activity Log::AH 'Created At'<br>[text] Activity Log: 'Created At'<br>[text] Tool & Integration Registry: 'TOOL & INTEGRATION REGISTRY — WHAT DEVELOPER CHAT CAN EVENTUALLY CONTROL' |
| Architecture | CONFIRMED | [sheet] Architecture Decisions<br>[text] Active Changes: 'Architecture audit + control workbook v1.0 + Nexus.Developer bootstrap'<br>[text] Active Changes: 'Repository name stays Nexus.Developer to match v2.2 architecture.'<br>[text] Audit Findings: 'ARCHITECTURE & FUTURE-PROOFING AUDIT'<br>[text] Architecture Decisions: 'ARCHITECTURE DECISIONS — APPROVED CONCEPTS AND WHY'<br>[text] Activity Log: 'Architecture Audit'<br>[text] Activity Log: 'Roadmap / Phase 1 architecture'<br>[text] Existing Assets: 'Foundation architecture exists and should be preserved.'<br>[text] Existing Assets: 'Architecture split'<br>[header] Master Roadmap::N 'Schema Contexts'<br>[header] Active Changes::J 'Schema Contexts'<br>[header] Version History::N 'Schema Contexts'<br>[text] Master Roadmap: 'Schema Contexts'<br>[text] Active Changes: 'Schema Contexts'<br>[text] Version History: 'Schema Contexts'<br>[header] Master Roadmap::O 'Contracts / APIs'<br>[header] Active Changes::K 'Contracts / APIs'<br>[header] Version History::O 'Contracts / APIs'<br>[text] Master Roadmap: 'Contracts / APIs'<br>[text] Active Changes: 'Contracts / APIs'<br>[text] Version History: 'Contracts / APIs'<br>[header] Active Changes::AA 'ADR ID'<br>[header] Version History::AJ 'ADR / Decision Link'<br>[header] Architecture Decisions::A 'ADR ID'<br>[header] Open Decisions::J 'Resolution / ADR'<br>[text] Active Changes: 'ADR ID'<br>[text] Session Protocol: 'Node ID + applicable ADR/Decision IDs'<br>[text] Version History: 'ADR / Decision Link'<br>[text] Architecture Decisions: 'ADR ID'<br>[text] Architecture Decisions: 'ADR-001'<br>[text] Architecture Decisions: 'ADR-002'<br>[text] Architecture Decisions: 'ADR-003'<br>[text] Architecture Decisions: 'ADR-004'<br>[text] Open Decisions: 'Resolution / ADR'<br>[text] Open Decisions: 'ADR-014 | M-02-1.2'<br>[text] Activity Log: 'Workbook v1.1 / 624 current nodes / 685 version records / ADR-001..004'<br>[text] Tool & Integration Registry: 'Design/review/coding assistance' |
| Decisions | CONFIRMED | [sheet] Architecture Decisions<br>[sheet] Open Decisions<br>[header] Version History::AJ 'ADR / Decision Link'<br>[header] Architecture Decisions::D 'Decision'<br>[header] Open Decisions::A 'Decision ID'<br>[header] Open Decisions::D 'Question / Decision Needed'<br>[text] Session Protocol: 'Node ID + applicable ADR/Decision IDs'<br>[text] Version History: 'ADR / Decision Link'<br>[text] Architecture Decisions: 'ARCHITECTURE DECISIONS — APPROVED CONCEPTS AND WHY'<br>[text] Architecture Decisions: 'Decision'<br>[text] Open Decisions: 'OPEN DECISIONS — QUESTIONS THAT MUST NOT DISAPPEAR BETWEEN CHATS'<br>[text] Open Decisions: 'Question / Decision Needed'<br>[text] Open Decisions: 'Decision ID'<br>[header] Active Changes::AA 'ADR ID'<br>[header] Architecture Decisions::A 'ADR ID'<br>[header] Open Decisions::J 'Resolution / ADR'<br>[text] Active Changes: 'ADR ID'<br>[text] Architecture Decisions: 'ADR ID'<br>[text] Architecture Decisions: 'ADR-001'<br>[text] Architecture Decisions: 'ADR-002'<br>[text] Architecture Decisions: 'ADR-003'<br>[text] Architecture Decisions: 'ADR-004'<br>[text] Open Decisions: 'Resolution / ADR'<br>[text] Open Decisions: 'ADR-014 | M-02-1.2'<br>[text] Activity Log: 'Workbook v1.1 / 624 current nodes / 685 version records / ADR-001..004'<br>[text] Open Decisions: 'Decided' |
| Repository | CONFIRMED | [header] Active Changes::G 'Repositories'<br>[header] Audit Findings::D 'Repository'<br>[label] Activity Log::V 'Repository'<br>[header] Existing Assets::C 'Repository / Files'<br>[text] Active Changes: 'Repositories'<br>[text] Active Changes: 'Repository name stays Nexus.Developer to match v2.2 architecture.'<br>[text] Audit Findings: 'Repository'<br>[text] Tool & Integration Registry: 'Scoped repository permissions'<br>[text] Tool & Integration Registry: 'Repositories, branches, PRs, history'<br>[text] Activity Log: 'Repository'<br>[text] Existing Assets: 'Repository / Files'<br>[header] Master Roadmap::L 'Projects'<br>[header] Active Changes::H 'Projects'<br>[header] Version History::L 'Projects'<br>[label] Activity Log::W 'Project'<br>[text] Master Roadmap: 'Projects'<br>[text] Active Changes: 'Projects'<br>[text] Active Changes: 'All current projects (inspection only)'<br>[text] Version History: 'Projects'<br>[text] Activity Log: 'Project'<br>[header] Active Changes::Q 'Branch'<br>[label] Activity Log::X 'Branch'<br>[text] Active Changes: 'Branch'<br>[text] Activity Log: 'Branch'<br>[header] Active Changes::R 'Worktree'<br>[label] Activity Log::Y 'Worktree'<br>[text] Active Changes: 'Worktree'<br>[text] Activity Log: 'Worktree'<br>[header] Master Roadmap::M 'Files / Globs'<br>[header] Active Changes::I 'Files / Globs'<br>[header] Version History::M 'Files / Globs'<br>[text] Master Roadmap: 'Files / Globs'<br>[text] Active Changes: 'Files / Globs'<br>[text] Version History: 'Files / Globs' |
| Completion Evidence | CONFIRMED | [header] Master Roadmap::AC 'Current Evidence'<br>[header] Active Changes::V 'Result / Evidence'<br>[header] Audit Findings::E 'Evidence'<br>[header] Session Protocol::C 'Evidence recorded'<br>[header] Phase Plan::F 'Exit Evidence'<br>[label] Activity Log::AC 'Evidence'<br>[text] Master Roadmap: 'Current Evidence'<br>[text] Master Roadmap: 'No implementation evidence reviewed yet.'<br>[text] Active Changes: 'Result / Evidence'<br>[text] Audit Findings: 'Evidence'<br>[text] Session Protocol: 'Evidence recorded'<br>[text] Phase Plan: 'Exit Evidence'<br>[text] Phase Plan: 'A work item can be resolved, reserved, executed/reviewed and evidenced'<br>[text] Tool & Integration Registry: 'Bounded execution + evidence'<br>[text] Activity Log: 'Evidence'<br>[text] Development Guide: 'No implementation evidence reviewed yet.'<br>[header] Audit Findings::L 'Verification'<br>[text] Audit Findings: 'Verification'<br>[header] Active Changes::AD 'Validation Result'<br>[text] Active Changes: 'Validation Result' |

## Node hierarchy (Master Roadmap)

Confirmed: **Layer -> Feature -> Milestone -> WorkItem -> Task -> Subtask**, encoded in 'Parent ID', 'Hierarchy Path' and the ID prefixes 'F-', 'M-', 'WI-', 'T-', 'S-'.

| Node Type | Rows (Master Roadmap) |
|-----------|----------------------|
| Feature | 95 |
| Layer | 12 |
| Milestone | 168 |
| Subtask | 101 |
| Task | 141 |
| WorkItem | 142 |

Status vocabulary on Master Roadmap (distinct values):
- Complete, Completed, Implemented - Verify, In Progress, Planned, Superseded

## Cross-sheet references (validated by value matching)

| From | To | Tested | Resolved | Ratio | Status |
|------|----|--------|----------|-------|--------|
| Master Roadmap:Parent ID | Master Roadmap:Node ID | 647 | 647 | 100% | CONFIRMED |
| Master Roadmap:Dependencies | Master Roadmap:Node ID | 284 | 281 | 99% | CONFIRMED |
| Active Changes:Node ID | Master Roadmap:Node ID | 119 | 110 | 92% | CONFIRMED |
| Active Changes:Dependency On | Active Changes:Change ID | 480 | 52 | 11% | UNRESOLVED |
| Active Changes:Version History ID | Version History | 200 | 3 | 2% | UNRESOLVED |
| Version History:Parent ID | Master Roadmap:Node ID | 932 | 904 | 97% | CONFIRMED |
| Version History:Change ID | Active Changes:Change ID | 952 | 952 | 100% | CONFIRMED |
| Dependencies & Blockers:From Node | Master Roadmap:Node ID | 11 | 11 | 100% | CONFIRMED |
| Dependencies & Blockers:Depends On / Blocks | Master Roadmap:Node ID | 19 | 9 | 47% | UNRESOLVED |
| Activity Log:Change ID | Active Changes:Change ID | 0 | 0 | - | UNRESOLVED (no data) |
| Audit Findings:Roadmap Link | Master Roadmap:Node ID | 36 | 32 | 89% | LIKELY |
| Phase Plan:Roadmap Link | Master Roadmap:Node ID | 96 | 38 | 40% | UNRESOLVED |
| Development Guide:Milestone ID | Master Roadmap:Node ID | 160 | 160 | 100% | CONFIRMED |
| Architecture Decisions:Roadmap Links | Master Roadmap:Node ID | 17 | 11 | 65% | LIKELY |
| Open Decisions:Roadmap Links | Master Roadmap:Node ID | 7 | 6 | 86% | LIKELY |
| Open Decisions:Resolution / ADR | Architecture Decisions:ADR ID | 47 | 1 | 2% | UNRESOLVED |

## UNRESOLVED mappings

- **Master Roadmap columns Column1 / Column2 / Column3 (AE:AG)** - Present in MasterRoadmapTable schema but no populated values observed in sample. Purpose unknown.
- **Master Roadmap used range extends beyond Excel table (A5:AG630)** - Sheet dimension reaches row 675 and 34 content rows sit below the table end. Whether this is intentional data or a not-extended table is unknown.
- **Active Changes columns Z:AD outside Excel table (A5:Y8)** - Version History ID, ADR ID, Affected Nodes, Change Type, Validation Result exist as sheet columns but are not part of ActiveChangesTable. Sampling shows them sparsely populated.
- **Control Center computed dashboard semantics** - Dashboard cells are formulas with no cached values in the file; the exact count/label relationships cannot be established from the workbook XML.
- **Identifier linkage is by naming convention, not enforced** - No defined names, data validations or explicit foreign keys exist. Cross-sheet references were validated by value matching only.
- **Version History row-to-row versioning semantics** - ADR-003 states Master Roadmap holds current state and Version History is the append-only archive, but the full Is Current / Supersedes resolution rule is not formally defined in the workbook.

## Conclusions

- **Likely task-control sheet:** Master Roadmap (node hierarchy with Status, Dependencies, Acceptance Criteria, Owner, Priority, Next Action).
- **Concurrency control:** Active Changes (change reservation ledger); Session Protocol defines the mandatory pre-implementation protocol.
- **Historical record:** Version History (append-only, linked to Change IDs); Activity Log is the event log.
- **Governance:** Architecture Decisions (ADR) and Open Decisions record decisions; Dependencies & Blockers is the explicit relationship graph.
- All 13 scanned concepts were found at name/header level (CONFIRMED). No relationship was invented; ambiguous items are listed under UNRESOLVED.

---

## DB-M01 RESULT

Workbook: C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx
Sheets found: 14
Tables found: 3
Likely task-control sheet: Master Roadmap
Unresolved mappings: 6
Workbook modified: NO
