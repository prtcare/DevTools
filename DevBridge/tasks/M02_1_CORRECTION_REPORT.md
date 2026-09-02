# CORRECTION REPORT - DB-M02.1 (Master Roadmap Full-Range Governance Correction)

**Milestone:** DB-M02.1 (corrective)
**Date:** 2026-08-30
**Workbook:** C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx (READ-ONLY; NOT modified)
**Workbook SHA256 (before AND after):** E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941
**Scope discipline:** This milestone touches ONLY the DB-G02 critical issue C-1 (Master Roadmap range governance). No unrelated warnings were altered. DB-M03 was NOT implemented.

---

## Problem

DB-G02 (validation gate) failed with critical issue C-1: the mapping/config governed Master Roadmap by the **formal Excel table boundary** (`A5:AG630`), but the workbook's actual governed current-state content extends to row 675. Rows 631-675 hold **34 structurally valid RoadmapNode records** that were therefore excluded from governance. Those records are real governed nodes:

- **F-12-4 .. F-12-16** — feature rows appended below the table end.
- **F-07-10 subtree, F-06-8 subtree, M-04-3.3 subtree, M-12-0.4 subtree** — added under ADR-005 / CHG-20260826-003.

They are referenced by open Active Changes reservations (CHG-20260830-004/-005 → M-07-10.3; CHG-20260830-008/-011/-012 → M-04-3.3; CHG-20260830-004 → F-07-10 subtree, F-06-8, M-12-0.4) and by ADR-005. The table metadata is stale (content appended without extending the table); the table boundary is NOT the governance boundary.

---

## Step-by-step findings

### Step 1 — Reconfirm the actual roadmap range (read-only; derived, not hard-coded)

Re-scanned `xl/worksheets/sheet2.xml` with a structural scan over the worksheet's used range (dimension A1:AG675). The governed set was derived by structural validity (RoadmapNode ID pattern + Node Type vocabulary + parent linkage), NOT by the table boundary and NOT by hard-coding row 675.

- **Total governed RoadmapNode records: 659** (rows **6-675**)
- Within formal Excel table (`A5:AG630`): **625**
- Beyond table (rows 631-675): **34**
- Duplicate Node IDs: **NONE**

The last governed record ends at row 675; the used-range dimension ends at AG675 — row 675 is derived, not assumed.

### Step 2 — Correct `config/development-control-map.json` (Master Roadmap only)

- `schemaVersion`: 2.0 → **2.1**
- Added `correctedAtUtc` and a `correction` field describing the DB-M02.1 correction.
- Master Roadmap sheet record now explicitly distinguishes:
  - **`formalExcelTableRange`**: `A5:AG630`
  - **`governedDataRange`**: `{"range":"A6:AG675","startRow":6,"endRow":675,"recordCount":659,"withinTableRecordCount":625,"beyondTableRecordCount":34,"detectionRule":"<structural rule>","note":"Corrected in DB-M02.1 ..."}`
- Replaced the old mandatory read condition ("read rows within the table A5:AG630; treat 631-675 as NOT governed") with the **full governed-data-range rule** and the documented structural detection rule.
- Updated `notes`, `preflight.caveats[1]` (full-range statement), and `mappingReadyCriteria.evidence`.
- Marked `unresolved[1]` ("Master Roadmap rows beyond the Excel table A5:AG630 vs A1:AG675") as **RESOLVED in DB-M02.1**, impact updated accordingly.

No other sheet's mapping was changed.

### Step 3 — Check `config/sheet-governance.json`

The only sheet whose Master Roadmap read rule relied on the table boundary is **Master Roadmap** itself. Its new-node write trigger was updated:

- Before: `"New node creation (append new row in table range)"`
- After: `"New node creation (append new row in the governed data range, below the last governed record; the formal Excel table boundary is not the governance boundary - DB-M02.1)"`

No other sheet in sheet-governance.json was changed. Session Protocol mutation remains `NONE` (unchanged).

### Step 4 — Reusable safe range-detection rule (documented)

The canonical rule, written into the map's `governedDataRange.detectionRule` and mirrored in MAPPING_REPORT.md:

1. Start from the header row (row 5) and the worksheet's used range.
2. Iterate all content rows below the header.
3. A row is a governed RoadmapNode record iff: column A matches the RoadmapNode ID pattern AND column C (Node Type) ∈ {Layer, Feature, Milestone, WorkItem, Task, Subtask}.
4. Ignore blank rows. Do NOT truncate at the Excel table end. Do NOT silently classify malformed rows — report them.

### Step 5 — Verify 34 recovered nodes

- **Count:** 34
- **Node ID range:** F-06-8, F-07-10, F-12-4..F-12-16, M-04-3.3, M-06-8.1, M-07-10.1..4, M-12-0.4, WI-04-3.3.1..2, WI-06-8.1.1, WI-07-10.1.1..3, WI-07-10.2.1, WI-07-10.3.1..2, WI-07-10.4.1, WI-12-0.4.1..2
- **Phases:** Phase 1 and Phase 2 content present.
- **Layers:** CORE (F-06, F-07, F-12) and additional governed layers for M-04/M-12 subtrees.
- **Statuses:** includes **Active / In Progress / current-path** nodes (e.g. M-07-10.3, M-04-3.3, F-07-10 subtree nodes are targeted by open reservations and are non-terminal), plus planned/completed nodes.
- All 34 resolve to real governed current-state records (verified against the full set).

### Step 6 — Hierarchy revalidation (over ALL 659 records)

Read-only checks (no workbook repair performed):

- Duplicate Node IDs: **0**
- Orphans (non-Layer record with no parent; Layer with a parent): **0**
- Broken parents (Parent ID that does not exist in the set): **0**
- Sort Key prefix consistency (every non-Layer SortKey starts with its parent's SortKey + "."): **0 violations**
- Hierarchy Path consistency: 623/659 stored paths match reconstruction exactly. 14 empty (M-07-0.2, WI-07-0.2.1..10, WI-07-3.2.3, WI-07-3.2.4, T-07-6.2.1.2) and 22 abbreviated ("..." / Feature-skipped: F-07-0 subtree rows 314-323 plus recovered beyond-table WorkItems) — documented formatting variance, none structurally breaking. **No data repaired.**

### Step 7 — Dependency / active-change impact check

All 34 recovered nodes were checked for references across the other governed sheets:

- **144 distinct references** from Active Changes (Node ID + Affected Nodes), Version History, and ADR-005 resolve to the recovered set.
- **34 of 34** recovered nodes are referenced by at least one other governed sheet.
- Active reservations target them: CHG-20260830-004/-005 → M-07-10.3; CHG-20260830-008/-011/-012 → M-04-3.3; CHG-20260830-004 → F-07-10 subtree, F-06-8, M-12-0.4.
- D&B / Development Guide / Open Decisions / Audit Findings have no references to the recovered nodes — verified legitimately (no dangling references).
- No reference resolution was broken by the range correction.

### Step 8 — Scope discipline

Only the C-1-related Master Roadmap range rule was changed. No unrelated warnings (W-1..W-5, other unresolved items) were altered.

### Step 9 — `tasks/MAPPING_REPORT.md` updated

Added the labeled note **"DB-M02.1 MASTER ROADMAP RANGE CORRECTION"** (detection rule, config effects, result summary) and corrected the two C-1-related spots that referenced the stale table-range read rule.

### Step 10 — Validation of corrected mapping + JSONs + workbook hash

- Both corrected JSONs parse (`config/development-control-map.json` schemaVersion 2.1; `config/sheet-governance.json` 14 sheets, 9 fields each).
- Re-read Master Roadmap via the corrected mapping (full governed data range rule): **659 records**, firstRow 6, lastRow 675, withinTable 625, beyondTable 34 — matches `governedDataRange` exactly.
- Hierarchy over the full set: 0 duplicates, 0 broken parents, 0 orphans, 0 sort-key violations.
- **Workbook SHA256 unchanged:** E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941 (read-only; never written).

---

## Result

**DB-M02.1: PASS**

- `masterRoadmapFullRangeMapped`: true (governedDataRange A6:AG675, 659 records)
- `previouslyOmittedNodesRecovered`: 34
- `hierarchyValid`: true
- `workbookUnchanged`: true
- `safeToRerunG02`: true

DB-G02 critical issue C-1 is resolved; the gate may be re-run.
