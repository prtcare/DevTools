# DB-M18.1 — Dependency Development Lineage & Context Resolver

**Milestone:** DB-M18.1 · **Lane:** B — AI ROUTING PLATFORM (sub-milestone of DB-M18)
**Status:** DESIGN + IMPLEMENTED · **Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-31
**Companion docs:** `design/ai-routing/DB-M18_TASK_CLASSIFICATION.md`, `design/ai-routing/DB-M18_CONTEXT_PACKAGING.md`

DevBridge already understands *that* Task C depends on Task A and Task B at the governance/roadmap
level (DB-M03 `dependencies` in `state/preflight.json`, `Dependencies & Blockers` sheet, Master Roadmap
node `Dependencies`). DB-M18.1 adds the missing half: **what each dependency actually delivered** — the
verified development lineage — and reconciles that history against **what the current repository really
contains**, so future M05/M07/M09 handoffs and later automatic AI execution receive compact, verified,
fresh dependency context instead of a flat "C depends on A and B".

This capability is **READ / ANALYZE / CONTEXT only**. It never modifies phases, milestones, roadmap
hierarchy, roadmap sequence, development order, architecture, goals, outcomes, acceptance criteria, or
dependencies. Dependency relationships may be **read**; they may not be redesigned by this milestone.

---

## 0. Temporary DevBridge boundary

DevBridge is TEMPORARY external scaffolding for Nexus Phase 1/2. Nothing delivered here becomes Nexus
runtime architecture, contracts, services, libraries, infrastructure, or a dependency. DB-M18.1 exists
only to help DevBridge understand Nexus development history while DevBridge exists. It will be retired
with DevBridge.

**NO LIVE NEXUS MUTATION:** implementation and testing never modify Nexus source, the authoritative
`NEXUS_DEVELOPMENT_CONTROL.xlsx`, or any governed roadmap state. Repository inspection is **read-only**.
All tests run against fixtures / temp copies.

---

## 1. Hard constraints honored

| Constraint | Status |
|---|---|
| READ/ANALYZE/CONTEXT only; no roadmap mutation | **YES** — no writer to governed state |
| Deterministic (zero AI calls, zero paid/network calls) | **YES** |
| Reuses DB-M18/DB-M17/DB-M14 contracts, never modifies them | **YES** (dot-source read-only) |
| No provider name / model selection (ADR-005) | **YES** |
| No DevBridge→Nexus migration surface | **YES** |
| Workbook / Nexus repos / Lane-C lifecycle state untouched | **YES** |
| Secrets never packaged | **YES** (DB-M17/DB-M14/DB-M18 guards reused) |
| Schema freeze (v1) | **YES** — `Get-DbM181SchemaVersions` |
| Backend scripts always exit 0; outcomes via stdout markers | **YES** (integration hooks keep existing contracts) |

---

## 2. What DB-M18.1 provides

```powershell
. (Join-Path $PSScriptRoot "DependencyLineage.ps1")     # the library (dot-source read-only)

# Capability 1 — graph
$graph = Resolve-DependencyGraph -Task $task -TaskCatalog $catalog
# Capability 2 — lineage
$lineage = Get-DbM181TaskLineage -TaskId 'WI-07-0.2.3' -EvidenceRoot $logsTasksRoot
# Capability 3 — reconciliation
$recon = Reconcile-LineageRepository -LineageSet $lineageSet -RepositoryRoot $repoRoot
# Capability 4 — index
$index = New-LineageIndex -LineageSet $lineageSet -Reconciliation $recon
# Capability 5 — freshness
$fresh = Test-LineageFreshness -Index $index -RepositoryRoot $repoRoot
# Capability 6 — relevance
$rel   = Get-DbM181Relevance -Graph $graph -LineageSet $lineageSet -Task $task
# Capability 7 — context package
$ctx   = Build-DependencyDevelopmentContext -Task $task -Graph $graph -LineageSet $lineageSet `
          -Reconciliation $recon -Relevance $rel -Freshness $fresh
# Capabilities 8–10 — integration adapters (M05/M07/M09)
$section   = Get-DbM181HandoffLineageSection -Task $task -Context $ctx          # M05 markdown
$readiness = Test-DbM181HandoffReadiness -Task $task -Context $ctx               # M05 gate
$claude    = Get-DbM181ClaudeDependencyContext -Task $task -Context $ctx         # M07 summary
$correction= Get-DbM181CorrectionDependencyContext -Task $task -Context $ctx     # M09 summary
# Capabilities 11–13 — scope / defect / supersession
$scope  = Test-DbM181ScopeChange -Task $task -FilePath 'src/.../X.cs' -Context $ctx
$defect = Classify-DbM181DependencyDefect -Task $task -DependencyId 'WI-07-0.2.3' -Context $ctx
$supers = Get-DbM181Supersession -LineageSet $lineageSet -AssetPath 'PaymentService.cs'
# Capability 14 — token control
$metrics = New-DbM181ContextMetrics -Context $ctx
# Capability 15 — provenance
#   every statement carries Provenance (WORKBOOK | IMPLEMENTATION_REPORT | M06 | CLAUDE_REVIEW | GIT |
#   CURRENT_REPOSITORY | FIX_TASK | LATER_WORK_ITEM) and Confidence when evidence is incomplete
```

---

## 3. Evidence model (read-only sources)

DB-M18.1 never invents history. Every lineage statement resolves to a provenance-tagged source:

| Provenance | Source on disk |
|---|---|
| `WORKBOOK` | governed task shape (`state/preflight.json`, `state/current-task.json` `dependencies[]`), Master Roadmap node `Dependencies` |
| `IMPLEMENTATION_REPORT` | `tasks/*_IMPLEMENTATION_REPORT.md`, `logs/tasks/<Node>/<Change>/IMPLEMENTATION_RESULT.md` |
| `M06` | `state/verification.json`, `logs/tasks/<Node>/<Change>/VERIFICATION_RESULT.md`, `changed-files.json`, `build-result.json`, `test-result.json`, `acceptance-matrix.json` |
| `CLAUDE_REVIEW` | `state/claude-review.json`, `logs/tasks/<Node>/<Change>/claude-decision.json`, `CLAUDE_DECISION_RESULT.md`, `CLAUDE_REVIEW_PACKAGE.md` |
| `GIT` | read-only `git rev-parse`/`git status --porcelain`/`git log --name-status` (REAL mode only; never writes) |
| `CURRENT_REPOSITORY` | read-only scan of the repository root (file existence + SHA-256) |
| `FIX_TASK` | M09 correction context (`tasks/FIX_CONTEXT.md`, `state/claude-review.json` FIX decisions), fix-task classification |
| `LATER_WORK_ITEM` | later task evidence dirs that name the same asset (changed-files.json deltaAttribution, scope amendments) |
| `STATE_RESULT` | `state/db-m<NN>-result.json` milestone result records |
| `TRIAL_PROVING` | `state/trial-proving-history.json` |

**Key lineage facts derivable per task** from the evidence dirs: `reservation.json` (identity, scope),
`changed-files.json` (deltaAttribution: `C_continuation_delta_created` / `C_continuation_delta_modified` /
`B_preserved_unchanged`), `build-result.json`/`test-result.json`/`acceptance-matrix.json` (verification
numbers), `claude-decision.json` (Claude decision, blocking findings, non-blocking observations),
`IMPLEMENTATION_RESULT.md` (self-reported files created/modified/deleted, known limitations),
`scope-amendment.json` (scope amendments + added files + prior owner attribution).

---

## 4. Contracts (schemaVersion = 1, frozen at DB-M18.1)

Registered by `Get-DbM181SchemaVersions` in `scripts/ai-routing/DependencyLineage.ps1`
(DB-M18.1-owned registry; `AiRoutingContracts.ps1` / `TaskClassification.ps1` / `ContextPackage.ps1`
are never modified). Incompatible changes require a v2 contract with its own schemaVersion + validator;
additive optional fields are allowed within v1.

### 4.1 `DependencyGraphResolution` v1 — Capability 1
| Group | Fields |
|---|---|
| Schema / identity | `SchemaVersion`, `GraphId`, `TaskId`, `NodeId`, `ChangeId` |
| Graph | `DirectDependencies[]` (`DependencyId`, `Type`, `State`, `Status`, `Detail`), `TransitiveDependencies[]` (`DependencyId`, `Depth`, `Path[]`) |
| Problems | `CycleDetected`, `Cycles[]` (`Nodes[]`), `MissingDependencies[]` (`DependencyId`, `Reason`), `InvalidReferences[]` (`Reference`, `Reason`), `BlockedDependencies[]` (`DependencyId`, `Reason`), `DuplicatePaths[]` (`Path[]`, `Count`) |
| Evidence | `ResolvedCount`, `EdgeCount`, `GraphEvidence` (`Source`), `ResolvedAtUtc` |

Resolution is deterministic: depth-first over `Task.dependencies` (and a supplied `TaskCatalog` map of
nodeId → task shape when transitive tasks are not the current task). Direct edges first; transitive
edges only through valid node references. A node reference that matches no catalog/evidence node is a
`MissingDependencies` entry (never an invented node). A revisit of a node already on the current DFS
stack is a `CycleDetected`. A second distinct path to the same node is a `DuplicatePaths` entry
(recorded for traceability, not an error). `REL-001..011`-style explicit D&B references without a node
pattern are preserved as direct dependencies but excluded from transitive recursion (they are not node
references).

### 4.2 `DevelopmentLineage` v1 — Capability 2
Per dependent task:
`TaskId`, `NodeId`, `ChangeIds[]`, `OriginalPurpose`, `AcceptanceCriteria`, `CompletionState`
(`Completed | In Progress | Planned | TRIAL_CYCLE_CLOSED`), `VerificationState` (`VERIFICATION_PASSED |
VERIFICATION_FAILED | PENDING | NONE`), `FilesCreated[]`, `FilesModified[]`, `ContractsCreated[]`,
`ContractsChanged[]`, `ClassesServicesCreated[]`, `SchemaChanges[]`, `ConfigChanges[]`, `TestsAdded[]`,
`ImplementationEvidence[]` (path + Provenance), `M06Evidence`, `ClaudeReviewOutcome` (decision +
Provenance), `BlockingFindings[]`, `NonBlockingObservations[]`, `KnownLimitations[]`, `ScopeAmendments[]`
(each with `PriorOwner`/`AddedFiles`/`Provenance`), `CorrectionAttempts[]`, `FixTasks[]`, `GitEvidence`
(REAL mode only), `LaterModifiers[]`, `Provenance[]`, `Confidence` (`FULL | PARTIAL | INFERRED`).

Collection order (deterministic): governed identity → evidence dir scan → M06/Claude records → later
task cross-references. Absent evidence stays empty/`null` with `Confidence` lowered — never invented.

### 4.3 `RepositoryReconciliation` v1 — Capability 3
`SchemaVersion`, `ReconciledAtUtc`, `RepositoryRoot`, `Entries[]` per historical asset:
`HistoricalPath`, `HistoricalTask`, `Status`
(`CURRENT | MODIFIED_LATER | SUPERSEDED | RENAMED_OR_MOVED | MISSING | HISTORICAL_ONLY | UNKNOWN`),
`CurrentPath`, `CurrentSha256`, `HistoricalSha256`, `LaterModifiers[]`, `Evidence`.
Status derivation (deterministic): if the exact path exists with the same SHA → `CURRENT`; exact path
exists but hash differs → `MODIFIED_LATER` (unless superseded by a rename mapping → `SUPERSEDED`);
path absent but a same-name/likely-move candidate exists under a different directory → `RENAMED_OR_MOVED`;
path absent and no candidate → `MISSING`; a file present only in history (never in repo) →
`HISTORICAL_ONLY`; insufficient evidence → `UNKNOWN`. **Current repository truth wins for implementation
context; historical evidence is preserved alongside it.**

### 4.4 `LineageIndex` v1 — Capability 4
`SchemaVersion`, `IndexId`, `BuiltAtUtc`, `SourceFingerprint` (SHA-256 of the concatenated evidence
inputs so freshness can be tested without rescanning everything), `Entries[]` per asset:
`AssetPath`, `OriginallyCreatedBy` (`TaskId` + `ChangeId` + Provenance), `LaterModifiedBy[]`,
`ContractCreatedBy`, `FixTasks[]`, `CurrentImplementation` (`Status`, `CurrentPath`), `VerifiedChain[]`
(tasks whose evidence is VERIFICATION_PASSED), `ReconciliationStatus`.

`New-LineageIndex` answers: "which task originally created this file?", "which later tasks modified
it?", "which task created this contract?", "which fix task changed it?", "what is the current
implementation?", "which verified development chain led to this asset?" — without rescanning every
historical artifact where the index is fresh.

### 4.5 `FreshnessReport` v1 — Capability 5
`SchemaVersion`, `TaskId`, `FreshnessStatus` (`FRESH | DEPENDENCY_CONTEXT_STALE`), `StaleReasons[]`,
`CurrentRepositoryFingerprint`, `IndexedFingerprint`, `RebuildRequired`.
Freshness is computed by comparing the index's `SourceFingerprint` and the repository fingerprint
(directory walk of the relevant scope: sorted relative paths + SHA-256 of each file) against a fresh
walk. Any mismatch → `DEPENDENCY_CONTEXT_STALE` with explicit `StaleReasons[]`. Stale context is never
used silently: every consumer (`Build-DependencyDevelopmentContext`, M05 readiness) treats stale as
"rebuild before handoff".

### 4.6 `RelevanceReport` v1 — Capability 6
`SchemaVersion`, `TaskId`, `Relevance[]` (`DependencyId`, `Relevance`
(`RELEVANT | SUPPORTING | NOT_RELEVANT | UNKNOWN_RELEVANCE`), `Reason`), `OmittedDependencyReferences[]`.
Relevance signals (evidence-based, deterministic): shared `scope paths` / `projects` / `contracts` /
`symbols` / `services` / `schema objects` / `configuration` between the current task's reserved scope
and the dependency's delivered scope ⇒ `RELEVANT`; same repository/milestone chain or acceptance-criteria
overlap ⇒ `SUPPORTING`; no overlap ⇒ `NOT_RELEVANT`; insufficient evidence ⇒ `UNKNOWN_RELEVANCE`.
Default context includes only `RELEVANT`/`SUPPORTING`; omitted nodes are preserved as references for
traceability.

### 4.7 `DependencyDevelopmentContext` v1 — Capability 7
`SchemaVersion`, `ContextId`, `CurrentTask`, `DirectDependencies`, `RelevantTransitiveDependencies`,
`DeliveredSummary[]` (per dependency: purpose, completion, verification), `CurrentFiles[]`,
`CurrentContracts[]`, `RelevantClassesServices[]`, `RelevantSchemaConfig[]`, `TestsEvidence[]`,
`LaterChanges[]`, `Fixes[]`, `SupersededComponents[]`, `CurrentRepositoryTruth`, `KnownLimitations[]`,
`ClaudeObservations[]`, `ReusePoints[]`, `ExtensionPoints[]`, `CollisionPoints[]`,
`Provenance[]`, `Confidence`, `FreshnessStatus`, `ContextMetrics` (4.8).
Both machine-readable (JSON) and human-readable (`Get-DbM181DependencyContextSummary -AsMarkdown`).

### 4.8 `ContextMetrics` v1 — Capability 14
`SchemaVersion`, `CandidateContextSize` (chars), `FilteredContextSize` (chars), `EstimatedTokens`
(chars/4, DB-M18 estimator), `DependencyCount`, `IncludedDependencyCount`, `OmittedDependencyCount`,
`OmissionReasons[]`. Context is compact by construction: symbol-level evidence, relevant contracts,
file references, and small required excerpts — never full source files.

### 4.9 `M05HandoffReadiness` v1 — Capability 8
`SchemaVersion`, `TaskId`, `LineageStatus` (`READY | STALE | UNRESOLVED | NOT_REQUIRED`),
`Ready`, `HandoffToken` (`CHATGPT_HANDOFF_READY | CHATGPT_HANDOFF_NOT_READY`), `Reason`.
When the task's dependency lineage is required and unresolved/stale → `CHATGPT_HANDOFF_NOT_READY` with an
explicit reason. When no dependencies exist (leaf task) or no lineage evidence is required →
`NOT_REQUIRED`/`READY` (never a false block).

### 4.10 `ScopeChangeDecision` v1 — Capability 11
`SchemaVersion`, `FilePath`, `InGovernedScope`, `Decision` (`CONTINUE | SCOPE_CHANGE_REQUIRED`),
`CurrentOwner`, `OriginalCreator`. If the current task legitimately needs to modify a dependency-owned
file that is outside its governed reserved scope → `SCOPE_CHANGE_REQUIRED`; nothing is added silently.

### 4.11 `DependencyDefectClassification` v1 — Capability 12
`SchemaVersion`, `DependencyId`, `Classification`
(`NORMAL_DEPENDENCY_REUSE | NORMAL_DEPENDENCY_EXTENSION | DEPENDENCY_SCOPE_EXPANSION_REQUIRED |
DEPENDENCY_DEFECT_FOUND`), `Routing` (`CORRECT_CURRENT_ATTEMPT | NEW_FIX_TASK_REQUIRED |
HUMAN_GOVERNANCE_REQUIRED`), `PreservedOriginalHistory` (always `true`), `Reason`.
Normal extension ≠ defect. A genuine defect in already-completed work preserves original history, never
reopens old acceptance criteria, and routes: in-attempt → `CORRECT_CURRENT_ATTEMPT`; post-completion →
`NEW_FIX_TASK_REQUIRED` under the existing governed structure; structural roadmap change required →
`HUMAN_GOVERNANCE_REQUIRED`.

### 4.12 `SupersessionRecord` v1 — Capability 13
`SchemaVersion`, `OriginalImplementation`, `SupersededBy` (`TaskId`), `CurrentImplementation`,
`Instruction` ("Do not build against the superseded original."). Derived from reconciliation when a
later task's `changed-files.json`/scope evidence replaces an asset path with a new path.

### 4.13 `TaskLineageEvidenceRef` v1
`SchemaVersion`, `TaskId`, `EvidencePaths[]` (each `{ Kind, Path, Provenance }`). Used to make every
lineage statement traceable.

---

## 5. Graph resolution detail (Capability 1)

1. Read the current task's governed `dependencies[]` (DB-M03). Direct edges = node-shaped entries
   (`^(F|M|WI|T|S)-`), plus preserved non-node references (e.g. `REL-001..011`).
2. For each direct edge, look up the dependency task's own `dependencies[]` in the `TaskCatalog`
   (supplied) or the evidence index (`logs/tasks/<Node>/`). Recursively expand.
3. Deterministic problems:
   - **cycle**: DFS stack revisit (`A→B→A`).
   - **missing node**: a referenced node present in no catalog/evidence record.
   - **invalid reference**: a dependency whose `dependencyId` is empty or does not match the node
     pattern and is not a preserved D&B reference.
   - **blocked/incomplete**: `state` = `BLOCKED`/`IN_PROGRESS`/`SATISFIED=false`; or a dependency whose
     own completion state is not terminal.
   - **duplicate path**: two distinct dependency chains reach the same node.
4. Produce deterministic graph evidence (sorted arrays) for the context package and tests 1–7.

---

## 6. Repository reconciliation detail (Capability 3)

`Reconcile-LineageRepository` walks:
- **Historical set**: every `FilesCreated`/`FilesModified`/`FilesDeleted` path from each lineage record.
- **Current set**: read-only recursive walk of `RepositoryRoot` (relative paths, sorted), restricted to
  text/known source extensions and the task's repository/project scope when supplied; SHA-256 per file.
- **Rename/move candidate**: for a missing historical path, search the current set for a file with the
  same basename (or a strong stem match) under a different directory → `RENAMED_OR_MOVED` (candidate
  recorded). Supersession mapping (same basename replaced by a new path, e.g. `PaymentService.cs` →
  `PaymentOrchestrator.cs`) is recorded when a later task's evidence shows the replacement.

Repository scanning is always read-only. In TRIAL/test mode a fixture repository root is used; in REAL
mode the governed repository path is used and Git evidence is added read-only.

---

## 7. Freshness detail (Capability 5)

- `New-LineageIndex` records `SourceFingerprint` = SHA-256 over the concatenation of (sorted evidence
  input paths, their file hashes, the governed dependency set).
- `Test-LineageFreshness` recomputes the same fingerprint plus a fresh repository-scope walk and
  compares. Equal → `FRESH`. Any difference (evidence file changed, dependency set changed, a lineage
  file deleted/renamed in the repo, a repo file's hash changed) → `DEPENDENCY_CONTEXT_STALE` +
  `StaleReasons[]` naming exactly what changed.
- Consumers: `Build-DependencyDevelopmentContext` stamps the freshness status; `Test-DbM181HandoffReadiness`
  maps stale/unresolved to `CHATGPT_HANDOFF_NOT_READY`. Test 16 (stale detection) and 17 (rebuild)
  exercise both sides.

---

## 8. Relevance filter detail (Capability 6)

Signals scored per dependency (all deterministic):
- scope-path overlap (`filesGlobs` vs delivered `FilesCreated`),
- project overlap (`projects` vs dependency `Projects`),
- contract overlap (`contractsApis` vs `ContractsCreated`/`ContractsChanged`),
- symbol/service/class overlap (dependency's `ClassesServicesCreated` matched against the current
  task's goal/acceptance text and scope),
- schema-object overlap (`schemaContexts`),
- configuration overlap,
- acceptance-criteria keyword overlap,
- dependency-edge proximity (depth in the resolved graph).

`RELEVANT` (direct scope/contract/symbol overlap), `SUPPORTING` (chain/milestone/ac-topic overlap),
`NOT_RELEVANT` (no signal), `UNKNOWN_RELEVANCE` (no evidence). Context includes relevant + supporting by
default; `OmittedDependencyReferences` keeps traceability for everything else. Test 18 (irrelevant
filtered) / 19 (relevant transitive retained) / 20–23 (contract/service/schema/config relevance)
lock the behavior.

---

## 9. Context size control detail (Capability 14)

`Build-DependencyDevelopmentContext` assembles compact fields only — no full source files, no entire
evidence blobs. `Get-DbM181DependencyContextSummary` reports, per the brief: candidate context size,
filtered context size, dependency count, included dependency count, omitted dependency count, reason
for omissions, and an `EstimatedTokens` figure (DB-M18 `chars/4` estimator, labeled). Secret guard
(`Test-DbM18SecretText`, reused) redacts any secret-like value before it reaches a context.

---

## 10. Provenance detail (Capability 15)

Every important lineage statement carries a `Provenance` tag (see §3) and, when evidence is incomplete,
an explicit `Confidence` (`FULL | PARTIAL | INFERRED`). Inferred history is never presented as verified
history: statements derived by cross-referencing (e.g. "file X later modified by task Y") are marked
`LATER_WORK_ITEM` with `Confidence: PARTIAL` unless confirmed by M06 `changed-files.json`
(`M06` / `FULL`). Test 39 locks provenance preservation; test 38 locks deterministic output (same inputs
→ byte-identical JSON).

---

## 11. M05 / M07 / M09 integration (Capabilities 8–10)

All three integration hooks are **additive and backward-compatible**:
- They **dot-source** `scripts/ai-routing/DependencyLineage.ps1` only if it exists (`Test-Path` guard) —
  absence of the library never breaks the script.
- They never alter existing stdout markers, exit codes, or mandatory zero-context M05 sections.
- They never write new files beyond what the scripts already write; the dependency section is embedded
  in the existing handoff/package/context markdown.
- They never touch the workbook, Nexus source, or governed state.

**M05 (`New-ChatGptHandoff.ps1`):** after the existing `Dependencies` section, a new
`Dependency Development Lineage (DB-M18.1)` section is emitted via `Get-DbM181HandoffLineageSection`
when lineage evidence resolves. The PART 18b readiness gate is extended with an additive check:
`Test-DbM181HandoffReadiness`; a required-but-stale/unresolved lineage yields
`CHATGPT_HANDOFF_NOT_READY` with an explicit reason. The 14 existing ChatGptHandoffValidation rules are
unchanged.

**M07 (`New-ClaudeReviewPackage.ps1`):** the review package gains a `Dependency Development Context`
subsection built from `Get-DbM181ClaudeDependencyContext` (relevant dependencies only — Claude is not
flooded with irrelevant history). The M12.2 fixture flow (no lineage evidence) emits a one-line
"no lineage evidence recorded" note and stays green.

**M09 (`New-CorrectionContext.ps1`):** the fix context gains a `Dependency Context` subsection from
`Get-DbM181CorrectionDependencyContext` naming the affected dependency/component, its original creator,
later modifiers, the current repository implementation, and whether the correction belongs to the
current attempt (CORRECT_CURRENT_ATTEMPT) or completed prior work (NEW_FIX_TASK_REQUIRED).

---

## 12. Parallel-safety (Lane C proving cycle)

- DB-M18.1 writes only its own additive files: `scripts/ai-routing/DependencyLineage.ps1`,
  `scripts/ai-routing/Test-DbM181DependencyLineage.ps1`, `design/DB-M18.1_*.md`,
  `state/db-m18-1-result.json`, `tasks/DB-M18.1_IMPLEMENTATION_REPORT.md`.
- The M05/M07/M09 integration edits are minimal and additive with a `Test-Path` guard. If the other
  lane were actively editing those shared files, the resolver still stands behind its stable contracts
  and DB-M18.1 reports `INTEGRATION_PENDING_SHARED_FILE`. At DB-M18.1's run, the Lane C trial cycle is
  closed (`TRIAL_CYCLE_CLOSED`, reservation released) so the integration edits are applied.
- DB-M18.1 never reads/writes `state/current-task.json` (WI-07-0.2.4, Lane C) and never touches the
  workbook. No `src/DevBridge.*` file is modified (Lane A/C boundary).

---

## 13. Test matrix (51 minimum, in `Test-DbM181DependencyLineage.ps1`)

Graph (1–7), lineage (8–14), reconciliation (10–15), freshness (16–17), relevance (18–23), evidence &
provenance (24–26), limitation/scope (27–33), integration (34–37), determinism (38–39), token control
(40), safety (41–44), regressions (45–50), build (51). Full mapping in §15 of the implementation
report. All suites run under throwaway fixture dirs; the DB-M18/DB-M12.2 regression suites run in child
processes; real workbook/repo hashes are asserted unchanged around the run.

---

## 14. Deliverables

1. `scripts/ai-routing/DependencyLineage.ps1` — the library (contracts + resolver + adapters).
2. `scripts/ai-routing/Test-DbM181DependencyLineage.ps1` — the 51+ test suite.
3. `design/DB-M18.1_DEPENDENCY_DEVELOPMENT_LINEAGE_CONTEXT_RESOLVER.md` — this document.
4. `state/db-m18-1-result.json` — deterministic result record.
5. `tasks/DB-M18.1_IMPLEMENTATION_REPORT.md` — implementation report.
6. Minimal additive integration edits to `New-ChatGptHandoff.ps1`, `New-ClaudeReviewPackage.ps1`,
   `New-CorrectionContext.ps1`.

---

*End of DB-M18.1 design. Classification/context packaging: `design/ai-routing/DB-M18_*.md`.*
