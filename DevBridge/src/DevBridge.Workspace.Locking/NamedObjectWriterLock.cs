using System.Diagnostics;

namespace DevBridge.Workspace.Locking;

// SP1-M02: the Forge-side named-object writer lock — the layer that lets Forge/DevTools writers
// genuinely contend with Nexus.Developer writers. Developer's real exclusive-writer mechanism is
// a WINDOWS OS NAMED OBJECT (not a file). This class opens the SAME kernel object kind under the
// SAME derived name; which kind matters absolutely (a Mutex and a Semaphore cannot share one name).
//
// Interop facts (verified read-only against Nexus.Developer source):
//   * Nexus.Developer.Core/DevelopmentControl/DevelopmentControlMutexIdentity.cs:18 -> prefix
//     "NexusDevelopmentControl_"; line 38 -> UPPERCASE SHA-256 hex; lines 52-59 -> normalizer.
//   * Nexus.Developer.Core/DevelopmentControl/NamedDevelopmentControlMutex.cs:7 -> the canonical
//     named lock is a System.Threading.Mutex ("a real Windows kernel mutex shared by every
//     process"); factory Kind = "named-mutex".
//   * Nexus.Developer.Core/DevelopmentControl/SemaphoreDevelopmentControlWriteLock.cs:5-15 -> a
//     count-1 named Semaphore is the documented ALTERNATIVE for async critical sections, with the
//     hard warning that a Mutex and a Semaphore are different object types and cannot coexist
//     under the same name.
//   * The write path (ConcurrencyGuardedDevelopmentControlStore / DevelopmentControlAtomicWriteCoordinator)
//     acquires whichever IDevelopmentControlWriteLockFactory it is composed with; Nexus.Developer
//     has NOT yet bound that composition root (SP1-M00 report §14.1, wave-01 report §6.1).
//   * ExcelDevelopmentControlStore itself acquires NO OS lock (it is a passive adapter); the lock
//     is taken by the guard/coordinator around the adapter's atomic save.
//
// Default primitive = Mutex (the primitive Developer names as its named cross-process writer
// lock). If Developer later composes the Semaphore factory, Forge MUST flip NamedLockPrimitive to
// Semaphore; a mismatch surfaces loudly here as SystemFailure (WaitHandleCannotBeOpenedException),
// never as silent divergence.
public sealed class NamedObjectWriterLock : IWriterLock
{
    private readonly NamedLockPrimitive _primitive;
    private readonly Mutex? _mutex;
    private readonly Semaphore? _semaphore;
    private bool _held;

    private NamedObjectWriterLock(SharedLockIdentity identity, Mutex mutex)
    {
        Identity = identity;
        _primitive = NamedLockPrimitive.Mutex;
        _mutex = mutex;
        _held = true;
    }

    private NamedObjectWriterLock(SharedLockIdentity identity, Semaphore semaphore)
    {
        Identity = identity;
        _primitive = NamedLockPrimitive.Semaphore;
        _semaphore = semaphore;
        _held = true;
    }

    public SharedLockIdentity Identity { get; }

    public bool IsHeld => _held;

    /// <summary>
    /// Bounded, non-throwing acquire of the OS named object for <paramref name="identity"/>.
    /// Mirrors Nexus.Developer's outcome vocabulary; never throws for expected contention and
    /// never waits beyond <paramref name="timeout"/>.
    /// THREAD AFFINITY: for <see cref="NamedLockPrimitive.Mutex"/> ownership is bound to the
    /// thread that calls <see cref="Mutex.WaitOne(TimeSpan)"/>; Release/ReleaseMutex must run on
    /// that same thread (no await between acquire and release). The semaphore variant has no such
    /// affinity and is safe across an awaited critical section.
    /// </summary>
    public static WriterLockAttempt TryAcquire(
        SharedLockIdentity identity,
        TimeSpan timeout,
        NamedLockPrimitive primitive = NamedLockPrimitive.Mutex)
    {
        if (identity is null) throw new ArgumentNullException(nameof(identity));
        if (timeout < TimeSpan.Zero) timeout = TimeSpan.Zero;
        return primitive == NamedLockPrimitive.Semaphore
            ? AcquireSemaphore(identity, timeout)
            : AcquireMutex(identity, timeout);
    }

    private static WriterLockAttempt AcquireMutex(SharedLockIdentity identity, TimeSpan timeout)
    {
        var watch = Stopwatch.StartNew();
        var mutex = new Mutex(false, identity.ObjectName);
        try
        {
            bool acquired;
            try
            {
                acquired = mutex.WaitOne(timeout);
            }
            catch (AbandonedMutexException)
            {
                // Previous owner died mid-write; the kernel transferred ownership to us, so the
                // lock IS held and the caller may proceed (no permanently locked workbook).
                watch.Stop();
                return new WriterLockAttempt(
                    WriterLockOutcome.AbandonedRecovered,
                    new NamedObjectWriterLock(identity, mutex),
                    watch.Elapsed);
            }

            if (!acquired)
            {
                watch.Stop();
                mutex.Dispose();
                return new WriterLockAttempt(WriterLockOutcome.Timeout, null, watch.Elapsed);
            }

            watch.Stop();
            return new WriterLockAttempt(
                WriterLockOutcome.Acquired,
                new NamedObjectWriterLock(identity, mutex),
                watch.Elapsed);
        }
        catch (Exception ex) when (
            ex is UnauthorizedAccessException
                or WaitHandleCannotBeOpenedException
                or IOException
                or ObjectDisposedException
                or ArgumentException)
        {
            // WaitHandleCannotBeOpenedException here is the classic same-name-different-kind
            // collision (Developer composed a Semaphore while Forge opened a Mutex): surface it as
            // SystemFailure so the kind mismatch is loud, not silently divergent.
            watch.Stop();
            try { mutex.Dispose(); } catch { /* best effort */ }
            return new WriterLockAttempt(WriterLockOutcome.SystemFailure, null, watch.Elapsed);
        }
    }

    private static WriterLockAttempt AcquireSemaphore(SharedLockIdentity identity, TimeSpan timeout)
    {
        var watch = Stopwatch.StartNew();
        var semaphore = new Semaphore(1, 1, identity.ObjectName);
        try
        {
            var acquired = semaphore.WaitOne(timeout);
            if (!acquired)
            {
                watch.Stop();
                semaphore.Dispose();
                return new WriterLockAttempt(WriterLockOutcome.Timeout, null, watch.Elapsed);
            }

            watch.Stop();
            return new WriterLockAttempt(
                WriterLockOutcome.Acquired,
                new NamedObjectWriterLock(identity, semaphore),
                watch.Elapsed);
        }
        catch (Exception ex) when (
            ex is UnauthorizedAccessException
                or WaitHandleCannotBeOpenedException
                or IOException
                or ObjectDisposedException
                or ArgumentException)
        {
            watch.Stop();
            try { semaphore.Dispose(); } catch { /* best effort */ }
            return new WriterLockAttempt(WriterLockOutcome.SystemFailure, null, watch.Elapsed);
        }
    }

    public void Release()
    {
        if (!_held) return;
        try
        {
            if (_primitive == NamedLockPrimitive.Mutex) _mutex!.ReleaseMutex();
            else _semaphore!.Release();
        }
        catch
        {
            // Deterministic release: a stray ReleaseMutex on a non-owning thread (thread-affinity
            // misuse) or a raced handle must not throw out of Release/Dispose.
        }
        finally
        {
            _held = false;
        }
    }

    public void Dispose()
    {
        Release();
        _mutex?.Dispose();
        _semaphore?.Dispose();
    }
}
