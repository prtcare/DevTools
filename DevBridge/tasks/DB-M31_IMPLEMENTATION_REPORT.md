# DB-M31 -- GOVERNED REAL-USE WORKBOOK & GIT SUPPORT: Implementation Report

Date: 2026-09-01 (local) / 2026-09-01 08:48 UTC  |  Lane B  |  Result: **PASS**

Temporary DevBridge scaffolding for Nexus Phase 1/2. DevBridge is NOT part of
Nexus. Nothing implemented in DB-M31 is intended for migration into Nexus. Do
NOT design DB-M31 for Nexus migration.

---

## 1. What this milestone delivered

A **GOVERNED REAL-USE workbook & Git support** layer that hardens DevBridge for
later **supervised** use against REAL Nexus development, while preserving the
TRIAL / DevBridge-proving environment and keeping **absolute roadmap
immutability and zero autonomy expansion**. The engine is READ-ONLY: it proves
the governed workbook write chain exclusively on fixture copies, observes Git
read-only, prepares human-only PR packages, and gates M10 governed completion
on explicit evidence. It never executes a model/provider, never creates/reviews/
merges a PR automatically, never restores a baseline, never runs a destructive
Git command, and never advances the lifecycle.

```
governed write chain (fixture-only)
  fresh-read -> authority/path validation -> stale-state check (STALE_GOVERNANCE_STATE)
  -> serialized writer (WORKBOOK_WRITER_BUSY / duplicate OperationId rejected)
  -> plan approval (ROADMAP_STRUCTURE_WRITE_PROHIBITED on any structural write)
  -> protected-roadmap fingerprint before
  -> hash-validated backup (BACKUP_CREATION_FAILED)
  -> execution-state write on a temp copy -> atomic replace
  -> reopen actual -> read-back exact intended state (WORKBOOK_READBACK_FAILED)
  -> protected-roadmap fingerprint after (must equal before)
  -> only then append the audit trace (workbook SHA before/after, git HEAD, backup)
Git observation (read-only)
  repo / branch / HEAD / HEAD subject / working-tree / changed files
  remote PR state stays UNKNOWN (never inferred as NO_PR / NOT_MERGED)
human Git gates
  AWAITING_HUMAN_PR / PR_OPEN / AWAITING_HUMAN_REVIEW / AWAITING_HUMAN_MERGE
  / MERGED / READY_FOR_GOVERNED_COMPLETION -- only from explicit evidence
M10 governed completion gate
  TRIAL short-circuits to TRIAL_COMPLETION_NOT_APPLICABLE first; REAL requires
  M06 PASS, Claude PASS, no governance issue, approved scope, positive human
  merge evidence, fresh state, preserved fingerprint, eligible lifecycle
M11 post-completion validation
  14-sheet consistency + protected roadmap unchanged + closures + evidence
human-only PR package -> AWAITING_HUMAN_PR (DevBridge never opens the PR)
pre-DevBridge baseline represent-only (RestoreForbidden; never restored)
```

DB-M31 is **explicitly NOT autonomous development.** It adds no automatic AI
execution, no automatic PR creation/approval/merge, no autonomous roadmap
progression, and no automatic next-task loops. Every external capability (PR
create/review/merge, completion, baseline restore) is a distinct **HUMAN**
action; only RUN COMPLETION and RUN WORKBOOK VALIDATION invoke a governed
backend.

### 1.1 Contracts (WorkbookGitContracts.ps1)

- `Get-DbM31WriterStates` -- IDLE/READY/WRITING/BUSY/FAILED/STALE/DONE.
- `Get-DbM31FailureStates` -- the explicit 10-token failure/recovery
  vocabulary: WORKBOOK_WRITER_BUSY, STALE_GOVERNANCE_STATE,
  BACKEND_STATE_MISMATCH, WORKBOOK_READBACK_FAILED, BACKUP_CREATION_FAILED,
  PROTECTED_ROADMAP_MISMATCH, GIT_STATE_UNKNOWN, PR_STATE_UNKNOWN,
  MERGE_STATE_UNKNOWN, HUMAN_GIT_ACTION_REQUIRED. No silent retry/recovery.
- `Get-DbM31GitGateTokens` / `Get-DbM31MergeConfirmedStates` -- the human Git
  gate vocabulary; only MERGED / READY_FOR_GOVERNED_COMPLETION count as positive
  merge evidence. A merge is NEVER inferred from a commit, a clean tree, a
  branch change, or a PR closure alone.
- `Get-DbM31M10Tokens` (12), `Get-DbM31TrialFlowTokens` (DB-M12.4 preserved),
  `Get-DbM31M11Tokens`.
- `New-DbM31ReadOnlyGuard` -- AutoExecutionEnabled=FALSE, 0 paid/network calls,
  every *Modified=NO, BaselineRestored=NO, AutomaticPrCreated=NO,
  AutomaticMergePerformed=NO, AutomaticNextTask=NO, SecretValuesDisplayed/
  Logged=NO.
- `Test-DbM31SecretLeak` -- the shared secret-material scan; SHA/hash fields
  (Sha256, WorkbookSha256Before/After, PreWriteSha256, PostWriteSha256,
  BackupSha256, FingerprintBefore/After) are exempt by name, free text is
  scanned, and no secret value is ever rendered or logged.
- `Test-DbM31ForbiddenCommand` -- flags git reset --hard / git clean / git push
  / git merge / git commit / git rebase / git checkout -f / git stash drop /
  gh pr create / gh pr merge / gh pr review / gh api .../pulls|merges /
  workbook overwrite / auto-execution. The library contains ZERO such
  invocations (C43, C44).
- `Out-DbM31Markers` -- backend contract: always exits 0; outcomes only via
  DB31_* stdout markers.

### 1.2 Engine (WorkbookGitEngine.ps1)

- OOXML via ZipArchive + XDocument (no COM); `Read-DbM31ZipXml` disposes entry
  streams so Update-mode writes never hit "Entries cannot be opened multiple
  times". PS 5.1-safe.
- `Resolve-DbM31ProtectedRoadmapFingerprint` -- DB-GH01-compatible canonical
  SHA-256 over "{sheet}|{col}|{row}|{value};" tokens (UTF-8), protected
  columns sorted, every row from dataStartRow counted, execution-state columns
  excluded. Reproduces the recorded authority 25BBECA4… (715 rows / 9161 cells)
  exactly (D51).
- `Test-DbM31ExecutionStatePlan` -- approves ONLY execution-state surfaces
  (Master Roadmap R,T,U,V,W,Z,AA,AC,AD; Control Center A2); any append to a
  protected sheet or write to protected identity/structure/architecture columns
  returns ROADMAP_STRUCTURE_WRITE_PROHIBITED with zero writes (A2).
- `Resolve-DbM31CanonicalWrite` -- the single governed write chain above,
  proven against fixture copies only (-Fixture). Every failure returns a
  canonical failure token; the write is treated as failed and never silently
  recovered (A1-A14).
- `Resolve-DbM31GitObservation` -- read-only git observation with the honesty
  contract: remote PR state is UNKNOWN whenever it cannot be explicitly
  verified; it is never fabricated and never inferred from local state (B15-B18,
  B23, B24).
- `Resolve-DbM31HumanGitGate` -- derives the gate position from explicit
  evidence only; merge confirmation requires positive merge evidence (B19-B24).
- `Get-DbM31LifecycleState` -- evidence-ownership guard: verification / Claude
  review / completion evidence applies ONLY when bound to the current task's
  changeId; stale evidence is surfaced as a warning, never counted (B25-B31).
- `Resolve-DbM31M10Eligibility` -- hardened M10 gate (B25-B31).
- `Resolve-DbM31TrialFlow` -- TRIAL flow preserved (M03..CLOSE_TRIAL_CYCLE);
  M10 is always TRIAL_COMPLETION_NOT_APPLICABLE in trial (B31).
- `Resolve-DbM31M11Validation` -- 7-part post-completion validation (C32, C33).
- `Resolve-DbM31FixTaskGovernance` -- NEW_FIX_TASK_REQUIRED /
  HUMAN_GOVERNANCE_REQUIRED; DevBridge never creates a phase/milestone/
  hierarchy/roadmap order (C34-C36).
- `Resolve-DbM31PrPreparationPackage` -- the human PR package; result state is
  AWAITING_HUMAN_PR, never PR_OPEN, until real evidence exists; performs NO Git
  action (C37, C38).
- `Resolve-DbM31AuditTrace` -- operation/task/change ID, mode, timestamp,
  input/result lifecycle state, workbook SHA before/after, git HEAD
  before/after, human action required, verification + Claude results, backup
  path, fingerprint before/after. No secret material (C41).
- `Resolve-DbM31PreDevBridgeBaseline` -- represent-only validation; the resolver
  NEVER restores (C42).
- `Test-DbM31BackendStateMismatch` -- BACKEND_STATE_MISMATCH when a script
  claims success but leaves the lifecycle state untouched (A12).
- `Get-DbM31View` -- the unified supervised view consumed by the CLI + HTML
  renderer (D48).

### 1.3 Renderer (WorkbookGitRender.ps1)

Self-contained HTML console (UTF-8 no-BOM, written ONLY via `WriteAllText` to
the operator-requested path): mode/lifecycle snapshot, human Git gate (explicit
evidence only; remote PR state shown as UNKNOWN), M10 governed completion gate
with per-prerequisite check, the five DISTINCT human actions (CREATE PR /
REVIEW PR / MERGE PR are HUMAN-only; RUN COMPLETION and RUN WORKBOOK
VALIDATION are the only backend actions), protected-roadmap fingerprint,
M11 post-completion validation, and the read-only guard. Every emission passes
`Test-DbM31SecretLeak` before return (D48).

### 1.4 CLI (Show-DbM31GovernedRealUse.ps1)

Read-only supervised guide. Always exits 0; outcomes communicated via DB31_*
stdout markers. Accepts explicit surfaces for fixture testing; never writes the
live canonical workbook, never advances the lifecycle, never runs a Git write.

---

## 2. Test results

`scripts/governed-workbook-git/Test-DbM31GovernedRealUse.ps1`

- **54 scenarios (A1-D54)** -- 54/54 green, exit 0.
- **Assertions:** 191 passed, 0 failed.

```
DB-M31 TEST SUMMARY: 191 passed, 0 failed
DB-M31 SCENARIOS: 54/54 scenarios passed
```

(Full run log: `state/db-m31-test-run.log`; result: `state/db-m31-result.json`.)

### 2.1 Scenario walkthrough (A1-D54)

| # | Scenario | What it proves | Result |
|---|----------|----------------|--------|
| A1 | execution-state-only workbook writes | approved plan classified Approved; write verified; appended Active Changes row present | PASS |
| A2 | structural roadmap write rejected | phase append + protected identity-column cell write -> ROADMAP_STRUCTURE_WRITE_PROHIBITED, zero bytes written | PASS |
| A3 | fingerprint before/after | protected roadmap fingerprint preserved across the write | PASS |
| A4 | canonical workbook authority | non-canonical path without -Fixture -> WORKBOOK_AUTHORITY_REJECTED | PASS |
| A5 | backup before write | hash-validated backup created before any write | PASS |
| A6 | pre-write hash | STALE_GOVERNANCE_STATE when the workbook changed since the fresh read | PASS |
| A7 | post-write hash | post-write SHA differs from pre-write; write verified | PASS |
| A8 | read-back validation | reopen -> read-back exact intended state | PASS |
| A9 | writer busy | WORKBOOK_WRITER_BUSY while the serialization lock is held | PASS |
| A10 | stale state | stale governance state rejected | PASS |
| A11 | duplicate write protection | duplicate OperationId rejected; no duplicate write lands | PASS |
| A12 | backend mismatch | BACKEND_STATE_MISMATCH when claimed success leaves wrong state | PASS |
| A13 | backup failure handling | BACKUP_CREATION_FAILED; no write when backup failed | PASS |
| A14 | read-back failure handling | WORKBOOK_READBACK_FAILED surfaced | PASS |
| B15 | Git branch observation | repo recognized; branch observed from the fixture repo | PASS |
| B16 | HEAD observation | HEAD commit + subject observed; CommitState PRESENT | PASS |
| B17 | working-tree observation | dirty tree + untracked file listed; clean tree observed clean | PASS |
| B18 | unknown remote state stays UNKNOWN | PR state never inferred; missing repo -> UNKNOWN (never NO_PR); honesty note present | PASS |
| B19 | human PR state | AWAITING_HUMAN_PR; not merge-confirmed | PASS |
| B20 | PR_OPEN only from evidence | PR_OPEN from positive evidence; no evidence / PR closure alone -> PR_STATE_UNKNOWN | PASS |
| B21 | human review gate | AWAITING_HUMAN_REVIEW + human review action | PASS |
| B22 | human merge gate | AWAITING_HUMAN_MERGE; MERGED is merge-confirmed | PASS |
| B23 | merge not inferred from commit | commits exist but never confirm a merge | PASS |
| B24 | merge not inferred from clean tree | clean tree never confirms a merge | PASS |
| B25 | M10 blocked without merge | BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING / MERGE_STATE_UNKNOWN | PASS |
| B26 | M10 blocked without M06 PASS | BLOCKED_NO_DB_M06_VERIFICATION_PASS | PASS |
| B27 | M10 blocked without Claude PASS | BLOCKED_NO_CLAUDE_PASS | PASS |
| B28 | M10 blocked by governance issue | BLOCKED_GOVERNANCE_ISSUE | PASS |
| B29 | M10 allowed only in REAL fixture | all gates satisfied -> READY_FOR_GOVERNED_COMPLETION (REAL fixture) | PASS |
| B30 | Trial M10 not applicable | TRIAL_COMPLETION_NOT_APPLICABLE | PASS |
| B31 | trial closure preserved | TRIAL flow: TRIAL_CYCLE_CLOSED preserved; trial evidence never merged | PASS |
| C32 | M11 post-completion validation | 7 parts all pass on a completed fixture | PASS |
| C33 | M11 failure surfaced | M11_VALIDATION_FAILED with explicit governance/reconciliation detail | PASS |
| C34 | fix-task rule | NEW_FIX_TASK_REQUIRED for a genuine defect under existing structure | PASS |
| C35 | no phase creation | fix-task rule never creates a phase | PASS |
| C36 | no milestone creation | fix-task rule never creates a milestone/hierarchy/roadmap order | PASS |
| C37 | PR package generation | AWAITING_HUMAN_PR; title carries change id; human-only rule; 2 changed files carried; never claims a merge | PASS |
| C38 | PR package no execution | HEAD + working tree unchanged by package generation | PASS |
| C39 | Activity Log evidence | append present as evidence | PASS |
| C40 | Version History evidence | append present as evidence | PASS |
| C41 | audit trace | one audit record; pre/post SHA; secret-free; scans clean | PASS |
| C42 | pre-DevBridge baseline read-only | baseline represented + validated; restore-forbidden; baseline workbook untouched | PASS |
| C43 | no automatic restore | zero restore invocations in the library; guard BaselineRestored=NO | PASS |
| C44 | no destructive Git command | zero forbidden git/gh invocations in the library | PASS |
| D45 | no automatic PR | guard AutomaticPrCreated=NO; zero gh pr create / git push invocations | PASS |
| D46 | no automatic merge | guard AutomaticMergePerformed=NO; zero gh pr merge / git merge invocations | PASS |
| D47 | no automatic next task | guard AutomaticNextTask=NO; no auto-next-task vocabulary/capability | PASS |
| D48 | no AI execution | AUTO_EXECUTION_ENABLED false; 0 paid/network calls; assembled view secret-free | PASS |
| D49 | DB-M30 regression | child suite exit 0; DB-M30 still 314 passed / 0 failed | PASS |
| D50 | DB-M12.4 regression | child suite exit 0; output produced | PASS |
| D51 | DB-GH01 fingerprint regression | DB-GH01 script exit 0; DB-M31 fingerprint authority reproduces 25BBECA4… / 715 rows / 9161 cells | PASS |
| D52 | canonical workbook unchanged during tests | live canonical workbook SHA 6D42C3BF… unchanged | PASS |
| D53 | Nexus source unchanged | Nexus repo git-status porcelain unchanged | PASS |
| D54 | build 0 errors | zero assertion failures + zero failing scenarios across the suite | PASS |

### 2.2 Regressions

| Suite | Result |
|-------|--------|
| DB-M30 | child suite executed in-suite (D49): exit 0, db-m30-result.json still 314 passed / 0 failed |
| DB-M12.4 | child suite executed in-suite (D50): exit 0, output produced |
| DB-GH01 | fingerprint script exit 0 (D51); protected-roadmap fingerprint unchanged |
| DB-M31 vs itself | live canonical workbook SHA 6D42C3BF… unchanged (D52); Nexus git status unchanged (D53) |

Known external drifts from prior milestones (DBM26 S41 recorded workbook
authority F520060C vs live 6D42C3BF; DBM181 R45 child DB-M18 regression) are
reported separately and are NOT DB-M31 failures. They are outside DB-M31's
scope and are not re-run here.

### 2.3 Proofs

- **Execution-state writes only, roadmap immutable** -- the write chain approves
  ONLY the execution-state columns and surfaces
  ROADMAP_STRUCTURE_WRITE_PROHIBITED (with zero bytes written) for any
  structural write (A1, A2). The protected-roadmap fingerprint is computed
  before and after every write and must be identical (A3).
- **Canonical authority + staleness + serialization** -- the chain validates
  path authority, rejects stale state, and rejects a held writer lock
  (A4, A6, A9-A11).
- **Backup + read-back integrity** -- a hash-validated backup is created before
  the write, and the written workbook is reopened and read back against the
  exact intended state (A5, A8, A13, A14).
- **Git is observed, never mutated** -- branch/HEAD/working-tree are read-only;
  remote PR state stays UNKNOWN and is never fabricated or inferred from local
  state (B15-B18). PR package generation leaves HEAD and the working tree
  unchanged (C38).
- **M10 hardened** -- TRIAL short-circuits to TRIAL_COMPLETION_NOT_APPLICABLE;
  REAL requires positive merge evidence and every gate; no merge is ever
  inferred (B23-B31).
- **Evidence ownership** -- verification / Claude / completion evidence counts
  only when bound to the current task's changeId; stale evidence is a warning
  (evidence-ownership guard).
- **No autonomy expansion** -- zero automatic PR/merge/next-task capability,
  zero destructive git invocations, zero restore invocations, AUTO_EXECUTION
  disabled, no secret material rendered or logged (C43-C48).
- **Integrity regressions** -- DB-M30 (314/0) and DB-M12.4 preserved; the live
  canonical workbook and the Nexus source are untouched during the whole run
  (D49-D53).

---

## 3. Files created

- `design/DB-M31_GOVERNED_REAL_USE_WORKBOOK_GIT_SUPPORT.md`
- `scripts/governed-workbook-git/WorkbookGitContracts.ps1`
- `scripts/governed-workbook-git/WorkbookGitEngine.ps1`
- `scripts/governed-workbook-git/WorkbookGitRender.ps1`
- `scripts/governed-workbook-git/Show-DbM31GovernedRealUse.ps1`
- `scripts/governed-workbook-git/Test-DbM31GovernedRealUse.ps1`
- `state/db-m31-result.json`
- `state/db-m31-test-run.log`
- `tasks/DB-M31_IMPLEMENTATION_REPORT.md` (this file)

## 4. Files modified

- `scripts/governed-workbook-git/WorkbookGitEngine.ps1` -- in-scope hardening
  during suite bring-up: (1) `Read-DbM31ZipXml` helper disposes zip entry
  streams so Update-mode writes never hit the "Entries cannot be opened multiple
  times" error; (2) `Get-DbM31RowByNumber` uses assignment-form `try` (legal in
  PS 5.1) instead of `try` inside a boolean paren; (3) `Write-DbM31CellXml`
  removes the existing `<is>` element before writing the inlineStr value so the
  first `<is>` no longer wins on read-back; (4) the nested git runner passes
  `[string[]]$GitArgs` splatted as `@GitArgs` (the previous parameter name
  `$Args` collided with PowerShell's automatic variable and passed no
  arguments); (5) the git honesty note reads "never fabricated and never
  inferred from local state".
- `scripts/governed-workbook-git/WorkbookGitContracts.ps1` -- in-scope hardening:
  `Test-DbM31SecretLeak` exempts the hash fields by name (Sha256,
  WorkbookSha256Before/After, PreWriteSha256, PostWriteSha256, BackupSha256,
  FingerprintBefore/After) so audit/fingerprint 64-hex values are not flagged as
  high-entropy tokens.
- No files outside the DB-M31-owned scope were modified; the live canonical
  workbook, the Nexus repo, and prior milestones' files are byte-identical.

---

## 5. Boundary / overlap

- **DB-GH01**: DB-M31 reproduces the DB-GH01 protected-roadmap fingerprint
  exactly (D51); the fingerprint is used for write-time before/after verification
  and M11. DB-GH01 is untouched.
- **DB-M12.4**: the TRIAL flow is preserved; M10 stays
  TRIAL_COMPLETION_NOT_APPLICABLE in trial, and trial evidence is never merged.
  DB-M12.4 closure preserved (D50).
- **DB-M30**: the DB-M30 child suite runs as a regression (D49) with its
  314/0 signature asserted; DB-M31 is the governed real-use layer that DB-M30's
  human Git gates + governed completion stages build on.
- **DB-M17 / DB-M26 / DB-M29 / DB-M27 / DB-M28 / DB-M19 / DB-M18.1**: consumed
  as evidence sources / guidance context READ-ONLY; no attempt store, budget,
  routing policy, model config, or dependency context is modified.
- **Lane A / Lane C**: DB-M31 wrote ONLY under `scripts/governed-workbook-git/`,
  `design/`, `state/`, `tasks/`. **NO PARALLEL_SCOPE_CONFLICT.**
- **Nexus**: DB-M31 is DevBridge-only, temporary, and NOT designed for Nexus
  migration. Nothing in DB-M31 is autonomous end-to-end development; every
  external capability (PR create/review/merge, completion, baseline restore) is
  a distinct human action. The actual switch to REAL_NEXUS_DEVELOPMENT happens
  only after final DevBridge acceptance and restoration of the PRE-DEVBRIDGE
  Nexus baseline.

---

## 6. Final run summary

- **DB-M31 TEST SUMMARY: 191 passed, 0 failed** (54/54 scenarios, exit 0).
- **DB-M31 SCENARIOS: 54/54 scenarios passed** (A1-D54).
- **Regression DB-M30:** child suite exit 0, db-m30-result.json 314 passed /
  0 failed (D49).
- **Regression DB-M12.4:** child suite exit 0, output produced (D50).
- **Regression DB-GH01:** fingerprint script exit 0; protected-roadmap
  fingerprint unchanged at 25BBECA4… / 715 rows / 9161 cells (D51).
- **DB-M31: ALL PASS** (exit 0).
- Auto-execution: **FALSE**. Lifecycle state, routing policy, attempt store,
  budget, fingerprints, live canonical workbook, Nexus source, git: **NOT
  modified**.
- Two known external drifts (DBM26 S41, DBM181 R45) are reported separately and
  are NOT DB-M31 failures.

**Ready for DB-M32: YES.** **Stop after DB-M31.**
