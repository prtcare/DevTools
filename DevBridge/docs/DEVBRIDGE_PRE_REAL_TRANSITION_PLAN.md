# DevBridge — PRE-REAL TRANSITION PLAN (PREPARED, NOT EXECUTED)

> DB-M34 output · 2026-09-02 · DB-M34 Area 18. **This plan is prepared only.**
> DB-M34 does NOT execute it. Every destructive/restoration step below happens
> only after DB-M34 PASS and **explicit human authorization**, as a separate act.

## Precondition gate (must all hold before step 1 is attempted)

- [ ] `state\db-m34-result.json` records DB-M34 PASS with
      `safeForRealNexusDevelopment = YES`.
- [ ] Operator has read `DEVBRIDGE_TRIAL_VS_REAL.md` and `RESTORE_PRE_DEVBRIDGE_BASELINE`
      (the human action) is understood to be a one-time, versioned, reversible-per-backup
      restore — **not** something DevBridge can do.
- [ ] No open half-cycle: recovery panel reports clean (no
      `READBACK_RECONCILIATION_REQUIRED` / `WORKBOOK_WRITER_BUSY`).

## The 11-step transition plan (Area 18 — verbatim)

### Step 1 — Freeze / archive current DevBridge proving state
Freeze live `state\`, `tasks\`, `logs\` (read-only). Archive the proving-state tree
so the DB-M03…DB-M34 record is immutable and auditable. No further governed
proving runs begin.

### Step 2 — Preserve final DevBridge acceptance evidence
Snapshot the DB-M34 acceptance evidence: `design\DB-M34_FINAL_ACCEPTANCE.md`,
`state\db-m34-result.json`, `state\db-m34-test-run.log`,
`tasks\DB-M34_IMPLEMENTATION_REPORT.md`, and this `docs\` set into the archive.

### Step 3 — Identify the exact PRE-DEVBRIDGE Nexus workbook backup
The represent-only baseline is in `state\pre-devbridge-baseline.json`. Workbook
backup: `state\backups\db-m124-preclosure-20260831152502.xlsx` (SHA256
`F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884`). Current live
canonical workbook: `C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx`
(SHA256 `6D42C3BF…E4F5`, post-DB-M12.4 authorized trial closure). Record which
backup is THE restore source.

### Step 4 — Identify the exact PRE-DEVBRIDGE Nexus source/Git baseline
Pre-DevBridge git HEAD: `ea39db910a6e3b00bff880316996a696ae7460dc` on
`feature/m-08-1-2-ci-pipeline` (captured 2026-08-31T05:17:06Z). Verify the Nexus
repository working tree still matches that baseline's recorded identity before
anything is touched.

### Step 5 — Human verifies identities
**Human step.** Verify (a) the backup workbook SHA == `F520060C…`, (b) the Nexus
git HEAD == `ea39db91…`, (c) the protected-roadmap fingerprint of the chosen
restore target is the recorded pre-DevBridge fingerprint. No automated trust;
the person confirms each identity.

### Step 6 — Human-authorized workbook restoration
**Human step — destructive, reversible-per-backup.** Restore the pre-DevBridge
workbook into the canonical path (back up the current 6D42C3BF workbook first so
the trial-closure state is never lost). DevBridge has no restore command.

### Step 7 — Human-authorized Git/source restoration
**Human step.** Bring the Nexus source to the exact pre-DevBridge baseline
(branch/commit as decided at Step 4). No history rewrite; the restoration is to
the original stopping point recorded pre-DevBridge.

### Step 8 — Run read-only post-restore reconciliation
Re-run read-only checks: `Get-ProtectedRoadmapFingerprint.ps1`, workbook-schema/
authority reconciliation, and git status observation. Confirm the restored
workbook fingerprint matches the recorded pre-DevBridge value and the workbook
reads cleanly.

### Step 9 — Confirm Nexus is at the exact original stopping point
Compare restored state against `state\pre-devbridge-baseline.json` and the
recorded M-08-1-2 stopping point (`ea39db91…`). Nothing may be "ahead" of the
original stopping point as a result of DevBridge proving.

### Step 10 — Explicit human switch TRIAL → REAL_NEXUS_DEVELOPMENT
**Human step.** A recorded, explicit switch so `Get-DevBridgeMode` resolves
`REAL_NEXUS_DEVELOPMENT` (config + current-task). There is no silent or timed
switch. After the switch the trial overlay is inert (DB-M33 Gate 1) and REAL
prerequisites (real dependency context, human Git gates, M10-after-merge, M11)
are enforced.

### Step 11 — Run first REAL M03 preflight
Run the first REAL M03 preflight per `DEVBRIDGE_FIRST_REAL_RUN_CHECKLIST.md`.
Expect a CLEAR verdict on a genuine implementable leaf with **no trial overlay**
and fresh real dependency context — or an honest governance block to resolve.

## Anti-goals (repeat)

- ❌ Not executed by DB-M34; not auto-executed later.
- ❌ No deletion of the DevBridge audit trail at any step.
- ❌ No skipping the human Git gates "because DevBridge was proven."
- ❌ No carrying a TRIAL PASS forward as a REAL completion
  (`TRIAL_TO_REAL_COMPLETION_CAPABILITY NO`).
- ❌ No DevBridge restore capability is added or implied — restore is human-only.
