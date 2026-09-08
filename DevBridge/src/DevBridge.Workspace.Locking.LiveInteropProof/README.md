# SP1-M02 — LIVE Forge ↔ Developer cross-process writer-lock proof

**P1-WAVE-03, Lane B.** Evidence that the two independently-built lock implementations — Forge's
`DevBridge.Workspace.Locking` (this repo) and Nexus.Developer's real composition root
(`AddDevelopmentControl` → `ConcurrencyGuardedDevelopmentControlStore` →
`NamedDevelopmentControlWriteLockFactory`, System.Threading.Mutex) — genuinely contend on the
**same OS named object** for the same canonical governed workbook path, with no silent writes,
no infinite waits, and no partial mutation on failure.

- `dev-probe/`  — Developer side. `DevProbe.csproj` ProjectReferences
  `C:\Personal\Nexus-W3-M05\src\Nexus.Developer.Infrastructure` (the Lane A worktree that bound the
  composition root). Runs real guarded Excel mutations on a **disposable** workbook copy.
  Repoint this ProjectReference at the integrated Nexus.Developer path once Wave-03 is merged.
- `forge-probe/` — Forge side. `ForgeProbe.csproj` ProjectReferences the real M02
  `DevBridge.Workspace.Locking` library. No workbook is opened (the lock layer works on the path string).
- `run-proof.ps1` — orchestrator: builds both probes, makes two disposable workbooks, seeds them
  through the real guarded store, and runs the six cases. Exits 0 iff all assertions pass.
- `evidence/` — captured output from the passing run (per-case `.out.log` + `results.txt`).
- `NuGet.config` — required for restore (github-prtcare feed for `Nexus.ProductCore.Contracts`,
  reached transitively through the Developer Infrastructure reference).

The authoritative `NEXUS_DEVELOPMENT_CONTROL.xlsx` is never opened, copied, or written.

## Re-run

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-proof.ps1
```

Requires the Developer Lane A worktree at `C:\Personal\Nexus-W3-M05` (or edit the DevProbe
ProjectReference), `dotnet 10.0`, and the GitHub Packages credentials in
`GITHUB_PACKAGES_USERNAME` / `GITHUB_PACKAGES_TOKEN` (see `NuGet.config`).

## Result (2026-09-07): 15/15 PASSED

| Case | Claim | Result |
|---|---|---|
| 3 | same path → identical lock identity both sides (hash + mutex name) | PASS — `ABB0153E…BBD0` dev == forge |
| 4 | different paths → different identity, both sides agree | PASS |
| 1 | Developer holds real mutex → Forge acquire times out (bounded) | PASS — `Timeout` @ 3006ms; positive control `Acquired` @ 2ms |
| 2 | Forge holds → Developer guarded write `LOCK_TIMEOUT`, workbook bytes unchanged | PASS — wall ~4.2s (2s budget); hash unchanged; positive `SUCCESS` after release mutates |
| 5 | explicit bounded no-infinite-wait | PASS — `Timeout` @ 1211ms (1200ms requested) |
| 6 | failed contention never partially mutates | PASS — bytes identical under blocked write |

This resolves the M02 report §9 decision 2 premise: Nexus.Developer's composition root is now
**bound** (Lane A) and its runtime primitive is the named **Mutex**, matching this library's
`NamedLockPrimitive.Mutex` default.
