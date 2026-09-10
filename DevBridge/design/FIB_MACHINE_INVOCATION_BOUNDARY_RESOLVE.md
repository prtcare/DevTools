# FIB — Forge machine-callable invocation boundary (RESOLVE)

Status: POST GATE A — contract + composition batch. No worker/model dispatch. No merge.

## 1. Purpose

A stable, machine-readable, out-of-process invocation boundary that lets Nexus
Developer call the **existing governed Forge lifecycle** — without requiring the
Nexus Platform runtime, an always-running service, or any new orchestration engine.

Scope this batch: **RESOLVE / INSPECT** (non-destructive). PREPARE is documented as
a designed future operation and **not implemented** (blocker in §6). No second Task
Resolver, dependency/context resolver, or model router was created — every engine
below pre-exists and is dot-sourced verbatim.

## 2. Invocation surface

One-shot out-of-process PowerShell entry point. JSON request file in; JSON result
file out; exit code `0` iff a result document was written. Result file is the
machine contract — console text is never parsed.

```
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ^
    DevBridge\scripts\forge-invocation\Invoke-ForgeResolve.ps1 ^
        -RequestFile <req.json> [-ResultFile <res.json>]
```

- `ResultFile` defaults to `RequestFile` with `.result.json` appended.
- Deterministic, recovery-safe: no always-on process; a caller that dies mid-run
  simply re-runs; repeated RESOLVE is a no-op with respect to governed state.
- Runtime availability of the Nexus Platform is **not** required. RESOLVE reads the
  configured authoritative workbook read-only (the existing DB-M03 zip/XML reader)
  and the configured governed state; it writes **nothing** under `DevBridge\state\`
  or `DevBridge\tasks\`. The governed preflight engine is pointed at a disposable
  scratch root under `DevBridge\temp\forge-invocation\` (git-ignored) so its native
  state writes never touch real governed state.

### Environment (all optional, all pre-existing overrides)

| var | effect |
|---|---|
| `DB_DEV_CONTROL_WORKBOOK_OVERRIDE` | byte-copy fixture workbook (reader override; tests) |
| `DB_NEXTTASK_STATE_DIR` | governed state dir the resolver reads for TRIAL proving-history (tests point at fixture) |
| `DB_NEXTTASK_CONFIG_PATH` | `config\devbridge.json` |
| `DB_FIB_SCRATCH_ROOT` | redirect the engine write-scratch (default `DevBridge\temp\forge-invocation\<runId>`) |

## 3. Reused existing engines (no duplication)

| Result concern | Reused engine | Manner |
|---|---|---|
| Task resolution | `Get-NextTask.ps1` `Get-NextTask` | dot-sourced, read-only |
| Eligibility / preflight / scope / governance | `Test-DevelopmentPreflight.ps1` `Test-DevelopmentPreflight` | dot-sourced; state writes diverted to scratch |
| Read-only workbook | `Read-DevelopmentControl.ps1` | dot-sourced |
| Task classification | `TaskClassification.ps1` `Classify-DevBridgeTask` | dot-sourced, deterministic |
| Address convention | `TaskClassification.ps1` `ConvertFrom/ConvertTo-DbM18NodeAddress` | `Role:Id`, Foundation default |
| Routing policy surface | `config\ai-routing.json` (DB-M14 inert defaults) | read-only status |

Routing is surfaced as **status only**: DB-M19 is MANUAL-only and requires an
enabled policy + a post-reservation context package; RESOLVE never fabricates a
worker/model/provider recommendation and never auto-executes.

## 4. Request (JSON)

```json
{
  "schemaVersion": 1,
  "api": "forge.resolve",
  "operation": "RESOLVE",
  "requestId": "ndr-20260909-0001",
  "issuedAtUtc": "2026-09-09T12:00:00Z",
  "actor": "nexus-developer",
  "origin": "nexus-developer",
  "governedTask": {
    "nodeId": "WI-07-0.2.4",
    "changeId": null,
    "mode": "TRIAL"
  },
  "scope": { "repo": "D:\\NEXUS\\Forge" },
  "routing": { "executionMode": "MANUAL" }
}
```

- `governedTask.nodeId` — optional bare governed id (roadmap identity). Omit for a
  free governed resolve (Forge picks the governed next task).
- `governedTask.address` — optional `Role:Id`. Only the Foundation role is
  resolvable by Forge; a Products/cross-scope address fails closed.
- `mode`/`scope`/`routing` are declared intent — echoed, never silently altered.

## 5. Result (JSON) — key fields

```json
{
  "schemaVersion": 1, "api": "forge.resolve", "operation": "RESOLVE",
  "requestId": "ndr-20260909-0001", "runId": "ndr-20260909-0001",
  "state": "SUCCESS",                       // SUCCESS | FAILED
  "failures": [ { "code": "...", "stage": "...", "message": "..." } ],
  "issuedAtUtc": "...", "completedAtUtc": "...", "actor": "...", "origin": "...",
  "governed": { "mode": "TRIAL", "workbookSha256": "...",
                "currentLifecycleState": { "status": "...", "nextAllowedAction": "...", "present": true },
                "requestedNode": { "nodeId": "WI-07-0.2.4", "exists": true },
                "resolvedTarget": { "nodeId": "...", "name": "...", "nodeType": "...", "phase": "...", "layer": "...", "address": "Foundation:..." } },
  "taskResolution": { "status": "SELECTED", "currentWorkNodeId": "...", "taskNodeId": "...",
                      "selectionBasis": [ "..." ], "candidates": [ "..." ],
                      "blockState": null, "blockReason": null, "ambiguityReason": null },
  "preflight": { "verdict": "CLEAR", "readiness": "READY",
                 "reason": "", "scope": { "status": "COMPLETE" },
                 "dependencies": [ ], "leafValidation": [ ] },
  "dependencyContext": { "status": "RESOLVED", "blockedDependencyIds": [], "basis": "..." },
  "classification": { "taskType": "IMPLEMENTATION", "complexity": "LOW", "...": "..." },
  "routing": { "executionMode": "MANUAL", "autoExecution": "PROHIBITED",
               "recommendationStatus": "NOT_ENABLED", "selectedWorker": null, "selectedProvider": null, "selectedModel": null },
  "reservation": { "alreadyReserved": false, "changeId": null,
                   "activeChangeCount": 3, "namingReservations": [ ] },
  "worktree": { "prepState": "NOT_CREATED", "branch": null, "note": "..." },
  "humanGate": { "required": false, "nextGovernedAction": "RESERVE" },
  "evidence": [ { "kind": "workbook-sha256", "value": "..." },
                { "kind": "preflight", "path": "..." }, { "kind": "result", "path": "..." } ]
}
```

Deterministic `state` semantics (fail-closed): `REQUEST_INVALID` /
`IDENTITY_INVALID` / `SCOPE_NOT_GOVERNED` (requested node exists but is not the
governed next task) / `SELECTION_BLOCKED` (resolver block or ambiguity) /
`PREFLIGHT_NOT_CLEAR` → `FAILED` with `failures[]`. Only a governed CLEAR selection
is `SUCCESS`.

## 6. PREPARE — designed, not implemented (blocker)

PREPARE would compose M03 → M04 (`Reserve-DevelopmentChange.ps1`) to make an
eligible task ready. **Not safely composable in this batch**:

1. Reservation is an authoritative-ledger write: it appends a new governed
   `CHG-yyyyMMdd-NNN` + `ACT-…` record and takes a git baseline — a durable
   commitment this batch must not fabricate before worker dispatch / human
   integration is authorized (batch forbids: no fabricated DevelopmentControl
   record, no worker execution, STOP before merge/integration).
2. M04's workbook redirection to a controlled copy is honored **only under
   `DB04_SELFTEST=1`** (a test-mode flag; DB-M33 proves the fixtures this way). No
   production-mode override exists that a recovery-safe machine caller could use —
   so a real PREPARE cannot target controlled storage without lying about being a
   self-test.
3. RESOLVE therefore lands now; PREPARE (and the DB-M19 routing call it would feed)
   is the documented next boundary op once worker execution is authorized.
