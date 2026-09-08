using System.Diagnostics;

namespace DevBridge.Workspace.Locking;

// SP1-M02: the uniform interop facade. For a governed workbook path it acquires BOTH layers when
// present:
//   1. the OS named-object layer (NamedObjectWriterLock) — on Windows, so Forge writers genuinely
//      contend with Nexus.Developer's named-object exclusive writer on the SAME governed workbook;
//   2. the file-lock layer (FileWriterLock) — always, so a future Linux/network-share deployment
//      that cannot see OS named objects still serializes writers, and two Forge writers contend on
//      a real exclusive file handle even if the named object is ever disabled.
// Both layers are independently usable (each has its own public TryAcquire); this facade gives
// callers one interop-safe path that holds and releases both together.

/// <summary>Options for the <see cref="SharedDevelopmentControlWriterLock"/> facade.</summary>
public sealed record SharedWriterLockOptions
{
    /// <summary>
    /// Whether to attempt the OS named-object layer on Windows. Ignored on non-Windows platforms
    /// (the named-object layer is always skipped there). Default true.
    /// </summary>
    public bool UseNamedObjectLayer { get; init; } = true;

    /// <summary>
    /// Which OS named-object kind to open. Must match what Nexus.Developer composes for the same
    /// governed path. Default <see cref="NamedLockPrimitive.Mutex"/>.
    /// </summary>
    public NamedLockPrimitive Primitive { get; init; } = NamedLockPrimitive.Mutex;

    /// <summary>
    /// Optional lock-file directory override for the file-lock layer. When null the file lock is
    /// co-located with the governed file (<see cref="FileWriterLock"/>).
    /// </summary>
    public string? LockFileDirectory { get; init; }
}

/// <summary>
/// Outcome of a combined two-layer acquire. <see cref="Lock"/> is non-null and holds BOTH enabled
/// layers when <see cref="WriterLockOutcome"/> is <see cref="WriterLockOutcome.Acquired"/> or
/// <see cref="WriterLockOutcome.AbandonedRecovered"/>. The per-layer attempts are exposed so
/// callers can see exactly which mechanism protected (or failed) the acquire.
/// </summary>
public sealed record SharedDevelopmentControlLockAttempt(
    WriterLockOutcome Outcome,
    SharedDevelopmentControlWriterLock? Lock,
    TimeSpan Elapsed,
    WriterLockAttempt? NamedObjectAttempt,
    WriterLockAttempt? FileLockAttempt)
{
    /// <summary>True when the named-object layer is enabled on this platform and was attempted.</summary>
    public bool NamedObjectLayerEnabled => NamedObjectAttempt is not null;
}

/// <summary>
/// A held (or released) two-layer shared writer lock. <see cref="Release"/> releases the file layer
/// then the named-object layer; <see cref="Dispose"/> is the exception-safe release path. Releasing
/// twice is a no-op.
/// </summary>
public sealed class SharedDevelopmentControlWriterLock : IWriterLock
{
    private readonly IWriterLock? _namedObjectLock;
    private readonly IWriterLock? _fileLock;
    private bool _released;

    private SharedDevelopmentControlWriterLock(IWriterLock? namedObjectLock, IWriterLock fileLock)
    {
        _namedObjectLock = namedObjectLock;
        _fileLock = fileLock;
    }

    public bool IsHeld => !_released;

    /// <summary>
    /// Bounded, non-throwing two-layer acquire. The named-object layer (when enabled) is acquired
    /// first with the full timeout budget — if Developer holds it, this times out before any file
    /// lock is taken, keeping the whole wait bounded by <paramref name="timeout"/>. The file-lock
    /// layer is then acquired with the remaining budget. Never throws for expected contention.
    /// </summary>
    public static SharedDevelopmentControlLockAttempt TryAcquire(
        string governedPath,
        TimeSpan timeout,
        SharedWriterLockOptions? options = null)
    {
        if (string.IsNullOrWhiteSpace(governedPath))
            throw new ArgumentException("A governed path is required.", nameof(governedPath));
        if (timeout < TimeSpan.Zero) timeout = TimeSpan.Zero;
        options ??= new SharedWriterLockOptions();

        var watch = Stopwatch.StartNew();
        var wantNamedLayer = options.UseNamedObjectLayer && OperatingSystem.IsWindows();

        WriterLockAttempt? named = null;
        WriterLockAttempt? file = null;
        try
        {
            if (wantNamedLayer)
            {
                var identity = SharedLockIdentity.FromWorkbookPath(governedPath);
                named = NamedObjectWriterLock.TryAcquire(identity, timeout, options.Primitive);
                if (named.Lock is null)
                {
                    // Named object contended/failed => the governed path is protected by Developer;
                    // do NOT write, and do not proceed to the file layer (the wait is already at the
                    // bounded timeout when Timeout).
                    return new SharedDevelopmentControlLockAttempt(named.Outcome, null, watch.Elapsed, named, null);
                }
            }

            var remaining = timeout - watch.Elapsed;
            if (remaining < TimeSpan.Zero) remaining = TimeSpan.Zero;
            file = FileWriterLock.TryAcquire(governedPath, remaining, options.LockFileDirectory);
            if (file.Lock is null)
            {
                named?.Lock?.Release();
                named?.Lock?.Dispose();
                return new SharedDevelopmentControlLockAttempt(file.Outcome, null, watch.Elapsed, named, file);
            }

            watch.Stop();
            var shared = new SharedDevelopmentControlWriterLock(named?.Lock, file.Lock);
            var outcome = named is { Outcome: WriterLockOutcome.AbandonedRecovered }
                ? WriterLockOutcome.AbandonedRecovered
                : WriterLockOutcome.Acquired;
            return new SharedDevelopmentControlLockAttempt(outcome, shared, watch.Elapsed, named, file);
        }
        catch (Exception)
        {
            // The layers are non-throwing for expected contention; this is a defensive backstop so a
            // truly unexpected failure still surfaces as a controlled SystemFailure, not an exception.
            named?.Lock?.Release();
            named?.Lock?.Dispose();
            file?.Lock?.Release();
            file?.Lock?.Dispose();
            watch.Stop();
            return new SharedDevelopmentControlLockAttempt(WriterLockOutcome.SystemFailure, null, watch.Elapsed, named, file);
        }
    }

    public void Release()
    {
        if (_released) return;
        _released = true;
        _fileLock?.Release();
        _namedObjectLock?.Release();
    }

    public void Dispose() => Release();
}
