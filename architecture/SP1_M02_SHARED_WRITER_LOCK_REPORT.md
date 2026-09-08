# SP1-M02 — Shared Interoperable Writer Lock (LANE A)

**Delivered in:** `C:\Personal\DevTools-W2-M02` (branch `sp1-m02-shared-writer-lock`, HEAD `7f3838f`, a linked worktree of the `prtcare/DevTools` repository)
**Developer interop contract read (read-only):** `C:\Personal\Nexus.Developer` (branch `feature/m-08-1-2-ci-pipeline`) — never modified.
**Tool versions:** `dotnet 10.0.400`, net10.0, `ImplicitUsings` + `Nullable` enabled, no external packages added.
**Date:** 2026-09-07.

---

## 1. Scope & rules met

- Added a **`DevBridge.Workspace.Locking`** library (new project under `DevBridge/src/`, mirroring the prior SP1-M01 `DevBridge.Workspace` style) implementing the Forge-side shared interoperable writer lock:
  1. a **named-object writer lock** that re-implements Nexus.Developer's exact identity derivation and opens the same OS named-object kind;
  2. a **file-lock layer** per the frozen Nexus shared-lock protocol (path → SHA-256 → exclusive lock file handle);
  3. a small **uniform facade** (`SharedDevelopmentControlWriterLock`) that acquires both layers when present and releases both. The two layers remain independently usable.
- Added a **`DevBridge.Workspace.Locking.Tests`** console exit-code harness (M01 style, NO xunit) proving identity equality, kernel mutual exclusion **across processes** for both layers, abandoned-recovery/cleanup, bounded timeouts, and — via an **independent reference transcription** of the documented Developer algorithm — that the derived name matches the documented output shape.
- **GIT DISCIPLINE (mandatory):** No stage/commit/push/merge/reset/clean/branch was performed. The **only** tracked file modified is `DevBridge/src/DevBridge.slnx` (two project entries added, exactly as SP1-M01 did). All new source is left untracked. Nothing outside this worktree was created or modified (harness uses only throwaway paths under `Path.GetTempPath()`).
- **No network, no shell interpolation:** child processes are spawned via `ProcessStartInfo.ArgumentList`; `UseShellExecute=false`. Matches M01's safety posture.
- Verification build succeeds for **all eight** projects including the pre-existing `DevBridge.Engine`, `DevBridge.Tests`, `DevBridge.UI`, `DevBridge.UITests`, and the M01 `DevBridge.Workspace(.Tests)`.
- M01 harness preserved: **71 checks, ALL PASS, exit 0** (no regression).

## 2. The two KEY interop facts (verified from Nexus.Developer source, read-only)

### 2.1 Fact 1 — the object name derivation (exact)

`Nexus.Developer.Core/DevelopmentControl/DevelopmentControlMutexIdentity.cs`:

- Line 18 — `private const string MutexNamePrefix = "NexusDevelopmentControl_";`
- Line 38 — `var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)));` → **UPPERCASE** 64-char hex.
- Lines 52-59 — the normalizer:
  ```csharp
  var value = identity.Trim();
  var looksLikePath = value.Contains('\\') || value.Contains('/') || Path.HasExtension(value);
  if (!looksLikePath) return value;
  var full = Path.GetFullPath(value).Replace('/', '\\').TrimEnd('\\');
  return OperatingSystem.IsWindows() ? full.ToLowerInvariant() : full;
  ```
- Line 42-46 — `FromWorkbookPath` pre-normalizes with `Path.GetFullPath(workbookPath)` before `FromStoreIdentity`.

**Derivation a Forge writer must reproduce:** `Trim` → if the identity contains `\` or `/` **or** has an extension, treat as a path: `Path.GetFullPath(...).Replace('/','\\').TrimEnd('\\')`, `.ToLowerInvariant()` on Windows (else verbatim) → `SHA-256` over the UTF8 bytes of that normalized string → `Convert.ToHexString` (**uppercase**) → `"NexusDevelopmentControl_" + hex`. This is re-implemented in `SharedLockIdentity.cs` and independently cross-checked in the harness (`ReferenceObjectName`).

### 2.2 Fact 2 — the OS-object KIND the real write path acquires

This is the subtle fact the brief flagged. Verified from the source:

- **`ExcelDevelopmentControlStore` (the store source) itself acquires NO OS lock.** It is a passive ClosedXML adapter: open (`XLWorkbook`), mutate, `SaveToTemp` (lines 470-477), `CommitTemp`/`File.Move(temp, canonical, overwrite:true)` (lines 479-490). A grep of the store for `Mutex`/`Semaphore`/`WaitOne` returns **zero** matches. The lock is taken by the guard/coordinator *around* the adapter.
- **The write path that actually acquires the object is the guard/coordinator, and it acquires an injected factory:**
  - `ConcurrencyGuardedDevelopmentControlStore.cs:172` — `var attempt = _lockFactory.TryAcquire(_identity, _lockTimeout);` (constructor lines 37-48 takes `IDevelopmentControlWriteLockFactory lockFactory`).
  - `DevelopmentControlAtomicWriteCoordinator.cs:47` — `var attempt = _lockFactory.TryAcquire(request.Identity, request.LockTimeout);`.
- **Both primitives exist and share the same name namespace, and a Mutex and a Semaphore cannot coexist under one object name:**
  - `NamedDevelopmentControlMutex.cs:5-7` — *"a named cross-process mutex protecting Development Control workbook writes, backed by System.Threading.Mutex — a real Windows kernel mutex shared by every process"*; factory `Kind = "named-mutex"` (line 108).
  - `SemaphoreDevelopmentControlWriteLock.cs:5-15` — the count-1 named **Semaphore** is the documented **alternative** for async critical sections, with the hard warning (lines 13-15): *"choose ONE primitive per store and use it consistently across ALL writers. The kernel name is shared, but a Mutex and a Semaphore are different object types and cannot coexist under the same name."*
  - `IDevelopmentControlWriteLockFactory.cs:4` — `Kind` names the primitive (`"named-mutex" | "named-semaphore"`).
- **Nexus.Developer has NOT yet bound its composition root.** The M00 stabilization report (§14.1) and the parallel-wave-01 report (§6.1, lines 250-256) both state a concrete factory "is not composed at any root" and that the guarded store has not been exercised through the Excel store in one integration path. So which kind Developer's *future* runtime uses is a **composition decision not yet made in the Developer repo**.

**Consequence recorded as the key interop decision:** every writer for a governed path must open the same kind under the same name. Because Developer's documentation and every guard/coordinator comment name the canonical lock as a **named `Mutex`** (the type is even called `DevelopmentControlMutexIdentity`), this library **defaults to `NamedLockPrimitive.Mutex`**, and exposes `NamedLockPrimitive.Semaphore` as an explicit option. A kind mismatch is intentionally **loud**: opening a Mutex where Developer composed a Semaphore (or vice-versa) throws `WaitHandleCannotBeOpenedException`, which this library maps to `SystemFailure` (never a silent divergence or a silent write without Developer contention). See §9, decision 2.

## 3. Safety model

| Safety property | Mechanism |
|---|---|
| Forge writers genuinely contend with Developer | Re-implemented name derivation + same-kind named object opened on Windows (named-object layer). |
| Never a silent write when Developer holds | Facade acquires the named-object layer **first** with the full bounded budget; Timeout/SystemFailure → the facade returns that outcome **before** the file layer, so a Forge writer never proceeds without Developer contention. |
| No infinite waits | Every layer and the facade are bounded by a caller-supplied timeout; contended acquires return `Timeout`, never hang. |
| Non-throwing acquire | All three acquire paths return a structured attempt (`Acquired`/`Timeout`/`AbandonedRecovered`/`SystemFailure` + `Elapsed`); only argument validation throws. |
| Abandoned-writer recovery | Named-mutex `AbandonedMutexException` → `AbandonedRecovered` with the lock held (kernel transferred ownership), matching Developer's semantics. |
| Deterministic release | `Release()`/`Dispose()` idempotent; file layer closes the exclusive handle and best-effort deletes the lock file. |
| Linux/network-share future | File-lock layer always acquired (see §4/§5). |
| No shell / no network / no real paths | `ProcessStartInfo.ArgumentList` only; all governed paths are throwaway paths under `Path.GetTempPath()`; the real Nexus workbook/repos are never touched. |
| Cross-process proof, not just in-process | Harness spawns child processes (`--lock-hold` / `--lock-abandon` self-modes) that acquire real kernel objects / exclusive file handles in separate OS processes. |

## 4. API surface (`namespace DevBridge.Workspace.Locking`)

```csharp
public enum WriterLockOutcome { Acquired = 1, Timeout = 2, AbandonedRecovered = 3, SystemFailure = 4 }
public interface IWriterLock : IDisposable { bool IsHeld { get; } void Release(); }
public sealed record WriterLockAttempt(WriterLockOutcome Outcome, IWriterLock? Lock, TimeSpan Elapsed);
public enum NamedLockPrimitive { Mutex = 0, Semaphore = 1 }

public sealed record SharedLockIdentity                       // name derivation (Developer-exact)
{
    public const string ObjectNamePrefix = "NexusDevelopmentControl_";
    public string Identity { get; }   // normalized store identity (canonical full path)
    public string HashHex   { get; }  // 64-char UPPERCASE SHA-256 hex
    public string ObjectName { get; } // ObjectNamePrefix + HashHex
    public static SharedLockIdentity FromStoreIdentity(string identity);
    public static SharedLockIdentity FromWorkbookPath(string workbookPath);
}

public sealed class NamedObjectWriterLock : IWriterLock    // OS named object (Developer kind)
{
    public static WriterLockAttempt TryAcquire(SharedLockIdentity identity, TimeSpan timeout,
        NamedLockPrimitive primitive = NamedLockPrimitive.Mutex);  // thread-affine for Mutex
}

public sealed class FileWriterLock : IWriterLock           // exclusive lock-file handle
{
    public string LockPath { get; }
    public static WriterLockAttempt TryAcquire(string governedPath, TimeSpan timeout,
        string? lockFileDirectory = null);                 // null => co-located with governed file
}

public sealed record SharedWriterLockOptions
{
    public bool UseNamedObjectLayer { get; init; } = true;  // ignored on non-Windows
    public NamedLockPrimitive Primitive { get; init; } = NamedLockPrimitive.Mutex;
    public string? LockFileDirectory { get; init; }
}
public sealed record SharedDevelopmentControlLockAttempt(
    WriterLockOutcome Outcome,
    SharedDevelopmentControlWriterLock? Lock,
    TimeSpan Elapsed,
    WriterLockAttempt? NamedObjectAttempt,
    WriterLockAttempt? FileLockAttempt);
public sealed class SharedDevelopmentControlWriterLock : IWriterLock  // uniform interop facade
{
    public static SharedDevelopmentControlLockAttempt TryAcquire(string governedPath,
        TimeSpan timeout, SharedWriterLockOptions? options = null);
}
```

Facade ordering (bounded by the single overall `timeout`): acquire the named-object layer first (when on Windows and enabled); if it is not held, return that outcome immediately (no write, no file layer). Otherwise acquire the file-lock layer with the remaining budget. Release releases file-then-named; releasing twice is a no-op. Named-object and file layers are each independently usable through their own `TryAcquire`.

## 5. Lock-file location decision (for adjudication)

Chosen default: **co-located with the governed file** — `<governedFileDirectory>\<64-char UPPERCASE SHA-256 hex>.lock`, opened `FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None`.

Rationale: the file-lock layer exists for a future Linux/network-share deployment that cannot see Windows OS named objects. Only a lock file that is **visible to every writer of the same governed file** — i.e. on the same share/directory as the governed file — actually serializes two machines reaching the file over a shared path. A per-machine `%TEMP%` lock directory would NOT serialize them. Co-location also keeps the lock file on the same volume as the atomic-replace target, which is the strongest guarantee that the lock and the file it guards move together (e.g. under an SMB share). `FileWriterLock.TryAcquire` accepts a `lockFileDirectory` override (e.g. `Path.GetTempPath()`) for single-machine use where directory pollution is unwanted.

Cleanup semantics: **the lock is the open handle, not the file's existence.** `Release()` closes the handle and best-effort deletes the lock file; a leftover file after a crash blocks nothing (the next acquirer opens `OpenOrCreate` + `FileShare.None` once the previous handle is gone). Because `FileShare.None` contention surfaces as a Win32 sharing violation, a contended acquire retries (20 ms cadence) until the bounded timeout and returns `Timeout`.

## 6. Verification evidence

### Build (must succeed; existing projects still build)

Command (from `C:\Personal\DevTools-W2-M02\DevBridge`): `dotnet build src/DevBridge.slnx`

```
Restored ... (8 projects)
  DevBridge.Workspace.Locking -> ...\DevBridge.Workspace.Locking\bin\Debug\net10.0\DevBridge.Workspace.Locking.dll
  DevBridge.Workspace -> ...
  DevBridge.Workspace.Locking.Tests -> ...\DevBridge.Workspace.Locking.Tests\bin\Debug\net10.0\DevBridge.Workspace.Locking.Tests.dll
  DevBridge.Workspace.Tests -> ...
  DevBridge.Engine -> ...
  DevBridge.UI -> ...
  DevBridge.Tests -> ...
  DevBridge.UITests -> ...

Build succeeded.
    0 Warning(s)
    0 Error(s)
Time Elapsed 00:00:04.76
```

### Harness — new M02

Command: `dotnet run --project src/DevBridge.Workspace.Locking.Tests` → **exit 0**

```
================================================================
 SP1-M02 Shared Interoperable Writer Lock — fixture runner
================================================================

TOTAL  : 59 checks
PASSED : 59
FAILED : 0
RESULT : ALL PASS
```

Coverage (all against throwaway paths under `Path.GetTempPath()`; child processes are the harness's own `--lock-hold` / `--lock-abandon` self-modes):

| Area | What is proven |
|---|---|
| A. Identity derivation (20 checks) | prefix `NexusDevelopmentControl_`, 64-char **UPPERCASE** hex, determinism, case/separator/trailing-backslash/whitespace folding, relative-with-extension full-path resolution, store-token verbatim, distinct paths distinct, **and** equality against an independent `ReferenceObjectName` transcription of the documented Developer algorithm on the full edge-case set. |
| B. Named-object layer in-proc (6) | free acquire → `Acquired`; `IsHeld`; idempotent release; re-acquire; distinct-path independence; semaphore primitive acquires. |
| C. File-lock layer in-proc (7) | free acquire; deterministic co-located lock path; lock file exists while held; **same-process second exclusive open → bounded `Timeout`**; bounded wait; release; re-acquire. |
| D. Shared facade (8) | both layers held together on Windows; file layer always held; named layer skippable; idempotent release; re-acquire; named-layer disabled → file-only still works. |
| E. Named object ACROSS PROCESSES (8) | child A holds the real named mutex; **parent facade times out while another PROCESS holds it** (no silent write, bounded); child B exits 0 + times out (bounded); A exits 0 and HELD-then-RELEASED; child C acquires after release. |
| F. File lock ACROSS PROCESSES (5) | child A holds the exclusive file handle; parent file-only facade times out; child B exits 0 + times out; A HELD-then-RELEASED; child C acquires after release. |
| G. Abandoned mutex + cleanup (5) | child acquires the named mutex and exits WITHOUT release; parent's next acquire reports **`AbandonedRecovered`** and holds; then the lock is cleanly `Acquired` again. |

(Per-scenario counts sum to 59; the loop under A contributes 8 runtime checks from 1 call site.)

### Harness — M01 regression

Command: `dotnet run --project src/DevBridge.Workspace.Tests` → **exit 0**

```
TOTAL  : 71 checks
PASSED : 71
FAILED : 0
RESULT : ALL PASS
```

## 7. Files added / changed

All new files are **untracked** (nothing staged or committed). Only one tracked file changed: `DevBridge/src/DevBridge.slnx`.

New library — `DevBridge/src/DevBridge.Workspace.Locking/`:
- `DevBridge.Workspace.Locking.csproj`
- `WriterLockContract.cs` (`WriterLockOutcome`, `IWriterLock`, `WriterLockAttempt`, `NamedLockPrimitive`)
- `SharedLockIdentity.cs` (Developer-exact name derivation)
- `NamedObjectWriterLock.cs` (OS named object — Mutex/Semaphore)
- `FileWriterLock.cs` (exclusive lock-file handle)
- `SharedDevelopmentControlWriterLock.cs` (uniform two-layer facade + options/attempt records)

New console harness — `DevBridge/src/DevBridge.Workspace.Locking.Tests/`:
- `DevBridge.Workspace.Locking.Tests.csproj` (`OutputType Exe`, `ProjectReference` to Locking)
- `Program.cs` (`Check(...)` PASS/FAIL + exit-code harness + child self-modes, no xunit/NUnit)

Changed:
- `DevBridge/src/DevBridge.slnx` — added the two project entries, matching the existing format.

Report:
- `architecture/SP1_M02_SHARED_WRITER_LOCK_REPORT.md` (this file).

## 8. Risks & assumptions

- **Object-kind composition on the Developer side is not yet wired.** The Developer guard/coordinator will acquire whatever `IDevelopmentControlWriteLockFactory` a future composition root binds. This library defaults to **Mutex** (the primitive Developer documents and names as its named cross-process writer lock), and exposes Semaphore. If Developer later binds the **Semaphore** factory for genuinely-async stores, Forge writers must flip `NamedLockPrimitive.Semaphore` — a mismatch is a loud `SystemFailure` (`WaitHandleCannotBeOpenedException`), never a silent divergence. **This is decision 2 in §9.**
- **Identity is only interop-correct when both sides feed the same canonical path.** `FromWorkbookPath` calls `Path.GetFullPath` first, so relative inputs resolve against each process's current directory; the governed workbook must be passed as the same absolute path on both sides (the normal shape for a shared governed workbook).
- **Mutex thread-affinity.** `System.Threading.Mutex` ownership is thread-bound; the harness (and the facade's intended callers) hold synchronously on the acquiring thread with no `await` between acquire and release. The semaphore primitive exists for async critical sections.
- **Named-object namespace is per-session on Windows** (no `Global\` prefix), matching how Developer constructs it. Two writers in different Windows sessions would not contend; the file-lock layer remains the cross-session/network-serialization fallback.
- **File-lock portability.** `FileShare.None` mandatory exclusive sharing is Windows-native; .NET emulates it with advisory locks on Unix. On a Linux/network deployment the file layer serializes cooperating writers but is advisory against non-cooperating processes.
- **Stale lock file after a crash is harmless** by design (lock = handle, not file existence), but it is not auto-deleted; the next acquirer opens/truncates it via `OpenOrCreate`.
- **Same-name-different-kind** (Mutex vs Semaphore) for one governed path will produce `SystemFailure` on one side — this is the intended loud signal, not a recovery path.
- Pre-existing `bin/`/`obj/` build noise regenerated by the required build is untouched and not part of this change (as in M01).

## 9. Decisions a human must confirm

1. **Lock-file location — co-located hash-named file** (`<governedDirectory>\<sha256hex>.lock`) vs a temp/lock directory. This lane chose **co-located** because only a lock file visible to every writer of the governed file (same share) serializes a future Linux/network-share deployment; a per-machine temp dir would not. Confirm co-location is acceptable (it writes one small file next to the governed workbook while a writer is active and best-effort deletes it on release), or mandate a central lock dir.
2. **Object-kind default = Mutex.** Nexus.Developer's composition root is not yet bound; its documentation and every guard/coordinator comment name the canonical named lock as a `System.Threading.Mutex`. Confirm Mutex as the shared-kind contract (and that Semaphore remains an explicit opt-in for async-critical-section stores), or direct the opposite default.
   - **RESOLVED (P1-WAVE-03):** the premise is now moot. Lane A of Wave-03 bound Nexus.Developer's composition root (`DevelopmentControlServiceCollectionExtensions.AddDevelopmentControl`) to the **`NamedDevelopmentControlWriteLockFactory` (System.Threading.Mutex)** for its guarded store, and §10's live cross-process proof passed 15/15 against that real root. The shared-kind contract is empirically **Mutex**, matching this library's default. Semaphore remains an explicit opt-in for a genuinely-async store only; a future divergence would surface loudly (see §8).
3. **File-lock cleanup semantics.** Release closes the handle and best-effort deletes the lock file; a crash leaves a harmless empty file that never blocks future acquisition (lock = handle). Confirm no sweeping/expiry job is required beyond that.
4. **Facade fail-closed on named-object failure.** When the named-object layer is enabled and returns `Timeout`/`SystemFailure`, the facade does NOT fall back to file-only and does NOT write. That is the safe interop behavior (never write without Developer contention); confirm a caller that truly wants file-only should pass `UseNamedObjectLayer=false` explicitly.
5. **`FromStoreIdentity` (verbatim trimmed non-path identities) is retained** alongside `FromWorkbookPath`, mirroring Developer; a non-path store token produces a valid object name but no co-located file-lock directory derivation (file lock falls back to the token's full path directory or `%TEMP%`). Confirm this matches the intended governed-store identity universe (path identities).

## 10. LIVE INTEROP PROOF — SP1-M02 FULLY COMPLETE (P1-WAVE-03 Lane B)

**Status: SP1-M02 FULLY COMPLETE.** Lane A of Wave-03 (M05 Developer-API lane, worktree `Nexus-W3-M05`) bound Nexus.Developer's real composition root — `AddDevelopmentControl` → `ConcurrencyGuardedDevelopmentControlStore` → `NamedDevelopmentControlWriteLockFactory` (**System.Threading.Mutex**) — to its guarded store and HTTP surface. Lane B then ran a **live two-process proof**: a Developer probe (binds the real composition root via `AddDevelopmentControl`, performs real guarded Excel mutations) contended on one OS named mutex with a Forge probe (binds this real `DevBridge.Workspace.Locking` library) over **disposable workbook copies**. The authoritative `NEXUS_DEVELOPMENT_CONTROL.xlsx` was never opened, copied, or written. All 15 assertions passed.

| Case | Claim | Live result |
|---|---|---|
| 3 | Same canonical path → **identical lock identity** on both sides (64-hex hash + full mutex object name) | PASS — dev hash == forge hash == `ABB0153E…BBD0`; name `NexusDevelopmentControl_`+hex identical |
| 4 | Different paths → **different identity**, both sides agree | PASS — wb2 hash `E78A8D55…` ≠ wb1; dev==forge |
| 1 | **Developer holds** the real mutex → **Forge acquire times out** (no silent write) | PASS — `Timeout` @ 3006ms; positive control `Acquired` @ 2ms after Developer released |
| 2 | **Forge holds** → **Developer guarded write `LOCK_TIMEOUT`**, workbook **bytes unchanged** | PASS — wall ~4.2s against a 2s budget (bounded); SHA-256 unchanged; positive control `SUCCESS` after release then mutates the bytes |
| 5 | **Bounded timeout / no infinite wait** (short explicit budget) | PASS — `Timeout` @ 1211ms against a 1200ms request |
| 6 | **Failed contention never partially mutates** the workbook (explicit re-block) | PASS — bytes byte-identical under a blocked guarded write |

Developer's guard surfaced the contention as `MutationResult.Success = false` with `ValidationErrors` containing `LOCK_TIMEOUT` (never a throw), and no partial write was ever observed on a timed-out mutation. This is the empirical, end-to-end proof that Forge and Developer writers genuinely contend on the same OS object for a governed workbook and that the guard's bounded, no-partial-mutation contract holds across the two independently-built stacks.

**Reproduction (re-runnable, preserved in this worktree):** the full harness is archived at
`DevBridge/src/DevBridge.Workspace.Locking.LiveInteropProof/` (both probes + orchestrator `run-proof.ps1`
+ `NuGet.config` + captured `evidence/` logs). Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-proof.ps1
```

The Developer probe ProjectReferences `C:\Personal\Nexus-W3-M05\src\Nexus.Developer.Infrastructure` (the
Lane A worktree); repoint it at the integrated Nexus.Developer path after Wave-03 merges. Requires
`dotnet 10.0` and the GitHub Packages credentials (`GITHUB_PACKAGES_USERNAME` / `GITHUB_PACKAGES_TOKEN`).

**Bottom line:** the Forge-side shared interoperable writer lock is implemented, builds warning-free with all eight solution projects, and is proven by a 59-check exit-code harness (plus M01's preserved 71) — including real cross-process kernel mutual exclusion for both the named-object layer and the file-lock layer, and abandoned-writer recovery — with the two key interop facts (exact name derivation; Mutex-default / Semaphore-alternative kind contract) verified from Nexus.Developer source and recorded above. **P1-WAVE-03 Lane B now closes the loop end-to-end: Nexus.Developer's real composition root (Mutex) and this library contend live on one OS named object, all six briefed cases pass (15/15), and SP1-M02 is FULLY COMPLETE.**
