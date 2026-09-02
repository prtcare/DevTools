# WORKBOOK AUTHORITY RECONCILIATION

Investigation: READ-ONLY authoritative workbook reconciliation for DevBridge.
Lane C - this session. Date (UTC): 2026-08-31.
Investigation evidence only. No workbook write, no state mutation, no lifecycle
progression. Historical reports are not overwritten.

Temporary DevBridge scaffolding for Nexus Phase 1/2. Retired with DevBridge;
nothing here migrates into Nexus.

---

## 0. Trigger

DB-M22 recorded a workbook SHA256 (F520060C...). DB-M23 later observed a
different hash (E866D3C4...) and attributed the drift to concurrent DB-GH01
activity, but DB-GH01 reported WorkbookModified=NO and DB-M12.2 reported
byte-identical. No AI-generated attribution may be accepted without evidence.
This reconciliation determines, from disk evidence, what actually happened.

## 1. Canonical workbook identity (Step 1, 3)

Canonical path: C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx

| Property | Value |
|---|---|
| Exists | YES |
| Size | 583522 bytes |
| CreatedUtc | 2026-08-30T10:58:47Z |
| LastWriteUtc | 2026-08-30T18:51:46Z |
| LastAccessUtc | 2026-08-31T07:08:33Z (read during reconciliation) |
| Read-only open | OK (FileShare ReadWrite/Delete) |
| SHA256 | F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884 |
| Governed sheets | 14 / 14 load, 0 errors |

**CANONICAL_PATH_IDENTITY: PASS**

The canonical path is known, exists, opens read-only, and its SHA256
F520060C... is recorded identically by DB-M22, DB-GH01 (pre-DevBridge-baseline
capture AND live), DB-M12.2, and the current reconciliation. Only DB-M23
recorded a different value, and that value matches a DIFFERENT file (section 3).

## 2. Governed sheets and mappings (Step 1, 8)

All 14 governed sheets present and loadable (0 failures):

1. Control Center (dashboard, dataStart 5)
2. Master Roadmap (674 rows, header 5, dataStart 6)
3. Active Changes (79 rows, header 5, dataStart 6)
4. Audit Findings (21 rows, header 5, dataStart 6)
5. Session Protocol (34 rows, header 5, dataStart 6)
6. Version History (958 rows, header 5, dataStart 6)
7. Phase Plan (28 rows, header 4, dataStart 5)
8. Architecture Decisions (8 rows, header 4, dataStart 5)
9. Open Decisions (7 rows, header 4, dataStart 5)
10. Dependencies & Blockers (14 rows, header 4, dataStart 5)
11. Tool & Integration Registry (19 rows, header 4, dataStart 5)
12. Activity Log (55 rows, header 4, dataStart 5)
13. Development Guide (163 rows, header 4, dataStart 5)
14. Existing Assets (15 rows, header 4, dataStart 5)

Mappings (config/development-control-map.json) valid: every governed sheet
resolves to a worksheet entry, opens, and its dataStart/header rows match the
map. No corruption detected (all sheets parse as XDocument, row counts sane).

**14-sheet load: PASS** | **Mapping validation: PASS** | **Corruption: NONE**

## 3. Hash history and timeline (Steps 4, 5)

### Recorded hashes by milestone

| Source | Recorded SHA256 (prefix) | Matches file |
|---|---|---|
| DB-M12.1 | 93D2620D... | logs/workbook-backups/..._184615.xlsx |
| preflight.json | 24C8D3AF... | logs/workbook-backups/..._225830.xlsx |
| DB-M22 | F520060C... | canonical (authoritative) |
| DB-GH01 (baseline + live) | F520060C... | canonical (authoritative) |
| DB-M12.2 | F520060C... | canonical (authoritative) |
| Current reconciliation | F520060C... | canonical (authoritative) |
| DB-M23 | E866D3C4... | backup\NEXUS_DEVELOPMENT_CONTROL.xlsx AND _190528.xlsx |

### On-disk workbook files (all hashes)

| File | SHA256 (full) | Size | CreatedUtc | LastWriteUtc |
|---|---|---|---|---|
| backup\NEXUS_DEVELOPMENT_CONTROL.xlsx | E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941 | 549324 | 2026-08-30T13:14:37Z | 2026-08-30T10:58:47Z |
| logs\workbook-backups\..._184615.xlsx | 93D2620D919789D9C7199C417FF3A9FD5B09DA0464F0D3800DB0748E62772372 | 582711 | 2026-08-30T18:46:15Z | 2026-08-30T17:28:31Z |
| logs\workbook-backups\..._190528.xlsx | E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941 | 549324 | 2026-08-30T13:35:28Z | 2026-08-30T10:58:47Z |
| logs\workbook-backups\..._220538.xlsx | F52A1A8FE491B6C91809EAC92DB2F0DCCD43FF7C5C80BA2618E19B64D3FDD4F7 | 550536 | 2026-08-30T16:35:38Z | 2026-08-30T13:35:29Z |
| logs\workbook-backups\..._225830.xlsx | 24C8D3AF2210C0F1F61B10FB96019A8AC7C8D8BBC67263F1498C4A11B075297C | 584525 | 2026-08-30T17:28:30Z | 2026-08-30T16:46:13Z |
| logs\selftest\T2_reserve\...\NEXUS_DEVELOPMENT_CONTROL_20260831_095700.xlsx | C8D6813BE06A6B3570E75E28B5CCF6EEEAEDD0DC5A97C5EB6E3B4C9C4F61446E | 582957 | 2026-08-31T04:27:00Z | 2026-08-31T04:26:49Z |
| logs\selftest\T5_scope\...\NEXUS_DEVELOPMENT_CONTROL_20260831_095727.xlsx | F5F0B84897E61E2EBBCAC69D299618121C44E254EA89F29A3D3E104C9F60D0A3 | 582957 | 2026-08-31T04:27:27Z | 2026-08-31T04:27:15Z |

### Backup hash comparison (Step 4)

- DB-M12.1 recorded hash == _184615 backup (93D2620D...). Consistent.
- preflight.json workbookSha256 == _225830 backup (24C8D3AF...). Consistent
  (preflight capture).
- backup\NEXUS_DEVELOPMENT_CONTROL.xlsx == _190528 backup (E866D3C4...). Both
  are a stale pre-write snapshot (LastWriteUtc 2026-08-30T10:58:47Z, i.e. the
  workbook content BEFORE the governed write).
- **DB-M23's observed hash (E866D3C4...) == the stale backup copy, NOT the
  canonical workbook.** This is the decisive fact.

### File write timeline (Step 5)

- Canonical lastWriteUtc = **2026-08-30T18:51:46Z** -- the final governed write
  (reservation of CHG-20260830-017 via DB-M04, evidenced by the reservation row
  in the workbook and preflight capture 24C8D3AF...).
- This timestamp predates ALL four relevant milestones: DB-M22 (DateUtc
  2026-08-31T05:10:36Z), DB-GH01 (05:17/05:20Z), DB-M12.2 (06:15:42Z), DB-M23
  (11:20:00Z).
- Therefore the canonical workbook was NOT written at any point during the
  discrepancy window. Its hash has been F520060C... continuously.
- The legitimate whole-file change 93D2620D... -> F520060C... occurred BEFORE
  the window (between DB-M12.1 and DB-GH01) via governed preflight/reservation
  writes. This is a WHOLE_FILE_HASH_CHANGE, not hash drift, and it does not
  explain DB-M23's value.

**CAUSE (of the M23 observation): PROVEN -- DB-M23 hashed a different file.**
The value DB-M23 recorded (E866D3C4...) is byte-for-byte the hash of
backup\NEXUS_DEVELOPMENT_CONTROL.xlsx (and _190528), a stale pre-write snapshot.
No invention required.

## 4. DB-GH01 claim (Step 6)

**GH01_CONFIRMED_NO_WORKBOOK_WRITE**

- DB-GH01 recorded LiveWorkbookSha256 F520060C... == current canonical.
- The canonical lastWriteUtc (2026-08-30T18:51:46Z) predates DB-GH01's run
  (2026-08-31T05:17Z); a file's LastWriteTimeUtc is physical evidence no write
  occurred during/after DB-GH01.
- DB-GH01 result itself records WorkbookModified: "NO".

DB-GH01's claim is CONFIRMED by independent disk evidence.

## 5. DB-M23 attribution evaluation (Step 7)

**M23 attribution: NOT_SUPPORTED**

- DB-M23's result asserts the hash difference is "external Lane A (DB-GH01)
  activity". This is NOT supported.
- DB-GH01 reported WorkbookModified=NO and its own hash equals the canonical
  F520060C..., which never changed during the window.
- DB-M23's observed hash exactly equals the stale backup copy
  backup\NEXUS_DEVELOPMENT_CONTROL.xlsx (E866D3C4...). DB-M23's script hashed a
  DIFFERENT file, not the authoritative workbook.
- The attribution to DB-GH01 was an inference, not authoritative evidence.

DB-M23's historical result is NOT modified. This evaluation is recorded
separately in state/workbook-authority-reconciliation.json.

## 6. Governance consistency (Step 8)

- 14 sheets load: PASS.
- Mappings valid: PASS.
- WI-07-0.2.4 present in Master Roadmap: PASS (row 328, WorkItem "Concurrency,
  locking and atomic writes", status Planned).
- CHG-20260830-017 present in Active Changes: PASS (row 80, node WI-07-0.2.4,
  milestone M-07-0.2, status "Open -- reserved via DB-M04 governed reservation;
  implementation pending CHATGPT handoff", classification Open).
- Trial lifecycle coherent: PASS. Live current-task.json holds WI-07-0.2.4 /
  CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP / CHG-20260830-017,
  matching the workbook reservation row. Stale-cycle protection keeps
  claude-review.json + verification.json on the PREVIOUS cycle
  (WI-07-0.2.3 / CHG-20260830-016) -- expected, not corruption.
- No corruption: PASS.

## 7. Protected roadmap fingerprint (Step 9)

Baseline recorded by DB-GH01 (state/roadmap-fingerprint.json, captured
2026-08-31T05:17:07Z):

> 25BBECA448CC83B76F9A639BBF5A3E4A1599FDE536938A413FBE9DB5D67BE057
> (5 sheets, 715 protected rows, 9161 protected cells)

Current fingerprint computed READ-ONLY inline (replication of
Get-ProtectedRoadmapFingerprint.ps1 over config/roadmap-protection.json, NO
state write):

> 25BBECA448CC83B76F9A639BBF5A3E4A1599FDE536938A413FBE9DB5D67BE057
> (5 sheets, 715 protected rows, 9161 protected cells)

Identical. **PROTECTED_STRUCTURE_UNCHANGED.** Phases, milestones, hierarchy,
development order, architecture/layers, goals/outcomes, acceptance criteria,
and dependencies are untouched.

## 8. Classification (Step 10)

Exactly one classification: **HASH_DRIFT_DIFFERENT_FILE_REFERENCE**

DB-M23 recorded the hash of a different file (the stale backup copy
backup\NEXUS_DEVELOPMENT_CONTROL.xlsx / _190528, E866D3C4...) rather than the
authoritative workbook. The authoritative workbook's recorded hash is stable at
F520060C... across DB-M22, DB-GH01, DB-M12.2, and the current reconciliation.

Separate reports (do NOT conflate):

- **WHOLE_FILE_HASH_CHANGE: YES (legitimate, pre-window).** The authoritative
  workbook's whole-file hash changed from 93D2620D... (DB-M12.1) to F520060C...
  (DB-GH01 onward) via governed preflight/reservation writes. This happened
  BEFORE the DB-M22/M23 window and does not explain DB-M23's value.
- **PROTECTED_ROADMAP_STRUCTURE_CHANGE: NO.** Fingerprint unchanged.

## 9. Authority decision (Step 11)

**WORKBOOK_AUTHORITY_CONFIRMED**

All confirmation conditions met:
1. Canonical path known and correct (CANONICAL_PATH_IDENTITY PASS).
2. Workbook opens read-only; 14/14 governed sheets load; mappings valid.
3. Trial governance coherent (WI-07-0.2.4 / CHG-20260830-017 present and
   consistent with live state).
4. Protected roadmap structure unchanged (fingerprint 25BBECA4... identical).
5. Discrepancy explained (different-file-reference, evidence-backed).

## 10. Step 12 (no mutation)

- Workbook modified during reconciliation: **NO**
- Nexus source modified: **NO**
- Lifecycle state modified: **NO**
- Git modified: **NO**

Artifacts produced (investigation evidence only):
- tasks/WORKBOOK_AUTHORITY_RECONCILIATION.md
- state/workbook-authority-reconciliation.json

## 11. Result

```
WORKBOOK AUTHORITY RECONCILIATION RESULT
  Canonical workbook: C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx
  Canonical path identity: PASS
  Current SHA256: F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884
  Current LastWriteTimeUtc: 2026-08-30T18:51:46Z
  DB-M22 recorded SHA: F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884
  DB-M23 observed SHA: E866D3C4D260031D3C067F4C9C272A497FD913AD7C8D0CBFD0BF42F76BCD2941
  DB-GH01 recorded/observed SHA: F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884
  DB-M12.2 observed SHA: F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884
  Relevant backup hashes: 93D2620D (M12.1/_184615), 24C8D3AF (preflight/_225830),
    F52A1A8F (_220538), E866D3C4 (backup\ + _190528, = DB-M23 observed)
  GH01 claim: GH01_CONFIRMED_NO_WORKBOOK_WRITE
  M23 attribution: NOT_SUPPORTED (inference; DB-M23 hashed a different file)
  Hash drift classification: HASH_DRIFT_DIFFERENT_FILE_REFERENCE
  14-sheet load: PASS (14/14, 0 errors)
  Mapping validation: PASS
  Trial governance consistency: PASS (WI-07-0.2.4 + CHG-20260830-017 present, coherent)
  Protected roadmap fingerprint: 25BBECA448CC83B76F9A639BBF5A3E4A1599FDE536938A413FBE9DB5D67BE057
  Protected roadmap structure: PROTECTED_STRUCTURE_UNCHANGED
  Workbook modified during reconciliation: NO
  Nexus source modified: NO
  Lifecycle state modified: NO
  Git modified: NO
  VERDICT: WORKBOOK_AUTHORITY_CONFIRMED
  Workbook-sensitive lifecycle may resume: YES
  Lane C new task may start: NO
  Next action: DB-M12.3 / FINAL HARDENED TRIAL PLANNING (when authorized)
```

**Stop. No repair performed. M10 not run. No Nexus task started. No baseline
restored.**
