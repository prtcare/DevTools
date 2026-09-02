# DB-M18.1 Implementation Report

**Milestone:** DB-M18.1 — Dependency Development Lineage & Context Resolver
**Lane:** B (AI Routing / evidence engine)
**Date (utc):** 2026-08-31T17:00:12Z
**Implementation:** **PASS**

---

## 1. Boundary (NON-NEGOTIABLE, preserved)

- DevBridge is **TEMPORARY Phase 1/2 external scaffolding**; nothing migrates into Nexus.
- DB-M18.1 is **READ / ANALYZE / CONTEXT only**. No autonomous modification of phases,
  milestones, roadmap hierarchy/sequence, development order, architecture, goals,
  outcomes, acceptance criteria, or dependencies. Dependency relationships are READ,
  never redesigned.
- **Deterministic**: zero AI calls, zero paid API calls, zero network calls.
- **No provider names and no model selection** anywhere in resolution logic (ADR-005).
- **No live Nexus mutation**: the authoritative workbook and Nexus repositories are
  untouched; all testing ran on throwaway fixture directories.

---

## 2. Deliverables

| Artifact | Status |
|---|---|
| `scripts/ai-routing/DependencyLineage.ps1` (library, 1754 lines) | PASS |
| `scripts/ai-routing/Test-DbM181DependencyLineage.ps1` (test suite, 497 lines) | PASS |
| `design/DB-M18.1_DEPENDENCY_DEVELOPMENT_LINEAGE_CONTEXT_RESOLVER.md` | PASS |
| `state/db-m18-1-result.json` (deterministic result record) | PASS |
| `tasks/DB-M18.1_IMPLEMENTATION_REPORT.md` (this file) | PASS |
| M05/M07/M09 additive integration edits (see §6) | PASS |

Diagnostic (throwaway, not deliverables): `logs/selftest/db181-probe.ps1`,
`db181-probe2.ps1`, `db181-final-suite.log`, `db18-reg-final.log`.

---

## 3. Required capabilities — PASS per line

| # | Capability | Status | Test evidence |
|---|---|---|---|
| 1 | Graph resolution (direct + transitive, cycles/missing/invalid/blocked/duplicate) | **PASS** | G1–G7 |
| 2 | Lineage collection (deltaAttribution + inventory dual shapes, completions, claude-decision, scope amendments, components) | **PASS** | L8–L14 |
| 3 | Repository reconciliation (CURRENT / MODIFIED_LATER / SUPERSEDED / MISSING / RENAMED_OR_MOVED / HISTORICAL_ONLY) | **PASS** | R15 |
| 4 | Lineage index | **PASS** | F16 |
| 5 | Freshness (repo change + dependency-set change → DEPENDENCY_CONTEXT_STALE; UNVERIFIED fallback never blocks) | **PASS** | F16, F17, I38b |
| 6 | Relevance (RELEVANT / SUPPORTING / NOT_RELEVANT / UNKNOWN_RELEVANCE, omitted refs listed) | **PASS** | R18–R23 |
| 7 | Dependency Development Context package | **PASS** | I34, T38, P39 |
| 8 | M05 handoff lineage section + readiness gate | **PASS** | I34, I35, R46 |
| 9 | M07 Claude review package context | **PASS** | I36, R47 |
| 10 | M09 correction context | **PASS** | I37, R48 |
| 11 | Scope-change handling (CONTINUE / SCOPE_CHANGE_REQUIRED) | **PASS** | S28, S29 |
| 12 | Dependency defect classification (NORMAL_DEPENDENCY_REUSE / extension / unknown rejected) | **PASS** | D30–D33 |
| 13 | Supersession record | **PASS** | S44 |
| 14 | Token / context size control (ContextMetrics; omitted deps named) | **PASS** | C40 |
| 15 | Provenance (vocabulary complete; every statement carries Provenance + Confidence) | **PASS** | E24–E27, P39 |

**Orchestrator** `Get-DbM181TaskDependencyContext` (one-shot bundle
graph+lineage+reconciliation+index+freshness+relevance+context): **PASS** — I38, I38b.

Also proven: determinism (T38, byte-identical under pinned time), no-secret (S41),
Trial/Real semantics + supersession (S44), no-source-modification (S42),
no-workbook-modification (S43).

---

## 4. Test results

- **64 checks, 63 passed, 1 failed.**
- Matrix (51 minimum): **51/51 required matrix tests PASS** (G1..S44).
- Orchestrator: I38 + I38b **PASS**.
- Regressions: R46, R47, R48, R49, R50 **PASS**; **R45 FAIL (documented, pre-existing,
  external)** — see §5.
- Build (B51): `dotnet build src\DevBridge.slnx` → **exit 0, 0 error CS tokens**.
- Warnings: 0. Errors: 1 (R45, external).

---

## 5. The single non-passing check — R45 (pre-existing, external to DB-M18.1)

`Test-DbM18Classification.ps1` (DB-M18 parent child suite) reports **203 checks,
2 failures** — exactly as before DB-M18.1:

```
FAIL: S27 fixture TaskId correct
FAIL: S27 fixture ChangeId from governed state
```

**Root cause (governed-state drift, not DB-M18.1):** the DB-M18 suite's S27 fixture
hard-codes `TaskId = WI-07-0.2.4` and `ChangeId = CHG-20260830-017`, but
`state/current-task.json` is now `M-07-0.2` (no changeId) because DB-M12.4 performed the
LIVE closure of the WI-07-0.2.4 trial cycle on 2026-08-31 (row 80 Closed, node Planned,
reservation released).

**Why DB-M18.1 is exonerated:**
1. `Test-DbM18Classification.ps1` dot-sources only `TaskClassification.ps1` +
   `ContextPackage.ps1`. It **never loads `DependencyLineage.ps1`**, so no DB-M18.1 code
   runs in that suite.
2. The drift predates DB-M18.1's integration edits (it occurred at DB-M12.4 closure).
3. DB-M18.1 **did not modify** `Test-DbM18Classification.ps1` or any DB-M18 file
   (parent-milestone boundary respected).

**Decision:** documented here and in `state/db-m18-1-result.json`; the DB-M18 suite is
left untouched (the fixture drift is a DB-M18/DB-M12.4 boundary concern).

---

## 6. M05 / M07 / M09 additive integrations (verified live and benign)

All three hooks are **additive and backward-compatible**. Each is `Test-Path`-guarded and
wrapped in `try/catch`: if the resolver library, its evidence root, or the resolution is
unavailable, the command proceeds **exactly** as before DB-M18.1, and existing stdout
markers, exit codes, and mandatory zero-context sections are never altered.

### M05 — `New-ChatGptHandoff.ps1`
1. **Context build** (before the Dependencies section): dot-sources `DependencyLineage.ps1`,
   builds the TaskCatalog from `Get-AllRoadmapNodes` (READ-only), merges the current-task
   identity with the DB-M03 preflight dependencies, and calls
   `Get-DbM181TaskDependencyContext -RepositoryRoot $script:RepoPath -EvidenceRoot <logs\tasks>`.
   Emits additive `DB05_LINEAGE_CONTEXT: <FreshnessStatus>` (or
   `DB05_LINEAGE_CONTEXT_UNAVAILABLE` on soft failure).
2. **Lineage section** (after the Dependencies area): emits
   `Get-DbM181HandoffLineageSection` as a `## Dependency Development Lineage (DB-M18.1)`
   block, or a one-line "no lineage evidence" note.
3. **Readiness gate** (PART 18b, after `DB05_HANDOFF_GATE: READY`): runs
   `Test-DbM181HandoffReadiness`. Fires **only** when the resolver is present AND the
   context resolves to `STALE`/`UNRESOLVED` for required node dependencies →
   `DB05_HANDOFF_TOKEN: CHATGPT_HANDOFF_NOT_READY` + explicit `DB05_LINEAGE_STATUS` /
   `DB05_LINEAGE_REASON` + `exit 1`. A leaf task is `NOT_REQUIRED` and never falsely
   blocked; a zero-context handoff is never blocked.

### M07 — `New-ClaudeReviewPackage.ps1`
Builds the dependency context (no catalog / no repository → UNVERIFIED, never STALE) and
appends `Get-DbM181ClaudeDependencyContext` (relevant dependencies only) to the package
header before the write.

### M09 — `New-CorrectionContext.ps1`
Builds the dependency context and appends `Get-DbM181CorrectionDependencyContext`
(affected scope, creator, correction routing) to the fix context before the write.

### Live proof (from this run's fixture outputs)
- R47's fixture `m07reg\tasks\CLAUDE_REVIEW_PACKAGE.md` ends with
  `## Dependency Development Context (DB-M18.1)` → the resolver **ran** inside the real
  M07 command and the marker `DB07_OUTCOME: CLAUDE_REVIEW_PACKAGE_CREATED` still passed.
- R48's fixture `m09reg\tasks\FIX_CONTEXT.md` ends with
  `### Dependency Context (DB-M18.1)` → resolver **ran** inside the real M09 command and
  `DB09_OUTCOME: FIX_CONTEXT_CREATED` still passed.
- R46 confirms the M05 gate marker contract is intact.

---

## 7. Non-mutation proofs

| Proof | Result |
|---|---|
| S42 DevBridge `src` fingerprint unchanged by the suite | PASS |
| S42 Nexus.Developer git state unchanged by the suite | PASS |
| S43 authoritative workbook SHA-256 byte-identical before/after the run | PASS |
| Roadmap modification capability | **NO** |
| Nexus source modified | **NO** |
| Canonical workbook modified | **NO** |
| Provider/model executed (0 paid API calls, 0 network calls) | **NO** |

Workbook SHA-256 at run close: `6D42C3BF6D3307B4B1A45870CE12F41E403DFED412E59F33D7B487E93A83E4F5`.
(Lane C's workbook-authority reconciliation recorded `F520060C` at 2026-08-31T07:12Z; the
workbook has since changed through legitimate external activity — NOT DB-M18.1, which
performed zero workbook writes.)

---

## 8. Files written vs. modified (scope proof)

**Created (owned by DB-M18.1):**
1. `scripts/ai-routing/DependencyLineage.ps1`
2. `scripts/ai-routing/Test-DbM181DependencyLineage.ps1`
3. `design/DB-M18.1_DEPENDENCY_DEVELOPMENT_LINEAGE_CONTEXT_RESOLVER.md`
4. `state/db-m18-1-result.json`
5. `tasks/DB-M18.1_IMPLEMENTATION_REPORT.md`

**Modified (minimal additive integration hooks only):**
6. `scripts/New-ChatGptHandoff.ps1` (M05)
7. `scripts/New-ClaudeReviewPackage.ps1` (M07)
8. `scripts/New-CorrectionContext.ps1` (M09)

No `src/DevBridge.*` file, no Nexus source, and no workbook file were modified.

---

## 9. Final status

- Ready for dependency-heavy proving cycle: **YES**
- Ready as prerequisite for DB-M30: **YES**
- **Stop after DB-M18.1.** (Lane B next milestone per roadmap ordering.)
