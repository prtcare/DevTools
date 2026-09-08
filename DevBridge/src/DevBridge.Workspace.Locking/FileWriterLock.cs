using System.Diagnostics;

namespace DevBridge.Workspace.Locking;

// SP1-M02: the file-lock layer per the frozen Nexus shared-lock protocol (path -> SHA-256 -> lock
// file -> exclusive file handle). A Windows OS named object is invisible to a future Linux or
// network-share deployment, so this layer serializes writers with a REAL exclusive file handle
// (FileShare.None) at a deterministic lock-file path derived from the governed path's SHA-256.
//
// LOCK-FILE LOCATION (decision to be adjudicated by the architecture authority):
//   Default = CO-LOCATED with the governed file: <governedDirectory>\<64uppercaseHex>.lock
//   (same volume, visible to every writer of the same governed file, survives network-share
//   replication). A per-machine %TEMP% lock directory would NOT serialize two machines that reach
//   the governed file over a shared path, so co-location is the only default that genuinely
//   serializes a network/Linux deployment. A caller may supply a lockFileDirectory override
//   (e.g. Path.GetTempPath()) for single-machine use where directory pollution is unwanted.
//
// Cleanup semantics: the lock is the OPEN HANDLE, not the file's existence. A leftover file after
// a crash blocks nothing — the next acquirer opens OpenOrCreate + FileShare.None once the previous
// handle is gone. Release closes the handle and best-effort deletes the lock file.
public sealed class FileWriterLock : IWriterLock
{
    // Win32 ERROR_SHARING_VIOLATION -> HRESULT 0x80070020. FileStream surfaces a same-file
    // FileShare.None conflict as IOException with this HResult.
    private const int SharingViolationHResult = unchecked((int)0x80070020);

    private const int RetryDelayMs = 20;

    private readonly FileStream _stream;
    private bool _held;

    private FileWriterLock(SharedLockIdentity identity, FileStream stream, string lockPath)
    {
        Identity = identity;
        _stream = stream;
        LockPath = lockPath;
        _held = true;
    }

    public SharedLockIdentity Identity { get; }

    /// <summary>The deterministic lock-file path whose exclusive handle is held while locked.</summary>
    public string LockPath { get; }

    public bool IsHeld => _held;

    /// <summary>
    /// Bounded, non-throwing acquire of the exclusive file lock for <paramref name="governedPath"/>.
    /// The lock file is <c>&lt;lockFileDirectory ?? governed file's directory&gt;\&lt;SHA-256 hex&gt;.lock</c>,
    /// opened with <see cref="FileShare.None"/>. While another writer holds the exclusive handle the
    /// open fails with a sharing violation; this retries until <paramref name="timeout"/> then returns
    /// <see cref="WriterLockOutcome.Timeout"/>. Never throws for expected contention.
    /// </summary>
    public static WriterLockAttempt TryAcquire(string governedPath, TimeSpan timeout, string? lockFileDirectory = null)
    {
        if (string.IsNullOrWhiteSpace(governedPath))
            throw new ArgumentException("A governed path is required.", nameof(governedPath));
        if (timeout < TimeSpan.Zero) timeout = TimeSpan.Zero;

        var watch = Stopwatch.StartNew();
        var identity = SharedLockIdentity.FromWorkbookPath(governedPath);

        string lockDirectory;
        try
        {
            lockDirectory = ResolveLockDirectory(governedPath, lockFileDirectory);
            Directory.CreateDirectory(lockDirectory);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or NotSupportedException or ArgumentException)
        {
            watch.Stop();
            return new WriterLockAttempt(WriterLockOutcome.SystemFailure, null, watch.Elapsed);
        }

        var lockPath = Path.Combine(lockDirectory, identity.HashHex + ".lock");

        while (true)
        {
            try
            {
                var stream = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                watch.Stop();
                return new WriterLockAttempt(
                    WriterLockOutcome.Acquired,
                    new FileWriterLock(identity, stream, lockPath),
                    watch.Elapsed);
            }
            catch (IOException ex) when (ex.HResult == SharingViolationHResult)
            {
                // Another writer holds the exclusive handle: genuine contention, retry.
            }
            catch (UnauthorizedAccessException)
            {
                // A second exclusive opener can surface as access-denied on some .NET builds;
                // treat as contention and retry (bounded below).
            }
            catch (Exception ex) when (ex is IOException or NotSupportedException or ObjectDisposedException)
            {
                // Non-sharing IOException (e.g. directory disappeared), path too long, etc.
                watch.Stop();
                return new WriterLockAttempt(WriterLockOutcome.SystemFailure, null, watch.Elapsed);
            }

            if (watch.Elapsed >= timeout)
            {
                watch.Stop();
                return new WriterLockAttempt(WriterLockOutcome.Timeout, null, watch.Elapsed);
            }

            Thread.Sleep(RetryDelayMs);
        }
    }

    private static string ResolveLockDirectory(string governedPath, string? overrideDirectory)
    {
        if (!string.IsNullOrWhiteSpace(overrideDirectory))
            return Path.GetFullPath(overrideDirectory);
        var full = Path.GetFullPath(governedPath);
        var dir = Path.GetDirectoryName(full);
        return string.IsNullOrEmpty(dir) ? Path.GetTempPath() : dir;
    }

    public void Release()
    {
        if (!_held) return;
        _held = false;
        try { _stream.Dispose(); }
        finally
        {
            // Best-effort delete: if a contender opened the leftover file in the instant between our
            // close and this delete, the delete fails (file in use) and is swallowed — the contender
            // keeps its own handle, which is the correct lock state.
            try { File.Delete(LockPath); } catch { /* best effort */ }
        }
    }

    public void Dispose() => Release();
}
