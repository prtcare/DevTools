namespace DevBridge.Workspace.Locking;

// SP1-M02: shared interop writer-lock vocabulary, mirroring Nexus.Developer's
// DevelopmentControl lock outcome contract exactly (see Nexus.Developer.Core
// DevelopmentControlWriteLock.cs). A bounded acquire NEVER throws for expected
// contention; it returns a WriterLockAttempt describing how acquisition went.

/// <summary>
/// Outcome of a bounded writer-lock acquire. Mirrors Nexus.Developer's
/// <c>DevelopmentControlLockOutcome</c> vocabulary so Forge-side callers speak the
/// same language as Developer-side callers.
/// </summary>
public enum WriterLockOutcome
{
    /// <summary>The lock was acquired and is held by the returned <see cref="WriterLockAttempt.Lock"/>.</summary>
    Acquired = 1,

    /// <summary>The acquire exceeded its bounded timeout — there is never a silent infinite wait.</summary>
    Timeout = 2,

    /// <summary>
    /// The previous holder's process/thread died while holding the lock and the kernel
    /// transferred ownership to this acquire, so the lock IS held and the caller may proceed.
    /// The caller should treat the preceding write as failed/unknown rather than relying on it.
    /// (Named-mutex layer only; a count-1 named semaphore has no abandoned signal — a dead
    /// holder's slot is returned to the pool by the kernel and surfaces as <see cref="Acquired"/>.)
    /// </summary>
    AbandonedRecovered = 3,

    /// <summary>
    /// The underlying lock could not be created or waited on at the system level (bad name,
    /// same-name-different-kind collision, permission, un-creatable lock directory, ...).
    /// The caller must not attempt the write.
    /// </summary>
    SystemFailure = 4,
}

/// <summary>
/// A held (or released) cross-process writer lock. <see cref="Dispose"/> is the
/// exception-safe release path; releasing twice is a no-op. Implementations may carry
/// platform thread-affinity requirements — see <see cref="NamedObjectWriterLock"/>.
/// </summary>
public interface IWriterLock : IDisposable
{
    /// <summary>True while the underlying primitive is still held (before Release/Dispose).</summary>
    bool IsHeld { get; }

    /// <summary>Deterministically releases the lock. Releasing twice is a no-op.</summary>
    void Release();
}

/// <summary>
/// Result of a bounded lock-acquire attempt. <see cref="Lock"/> is non-null exactly when the
/// lock is held (<see cref="WriterLockOutcome.Acquired"/> or
/// <see cref="WriterLockOutcome.AbandonedRecovered"/>). <see cref="Elapsed"/> is the time the
/// acquire waited. Mirrors Nexus.Developer's <c>DevelopmentControlLockAttempt</c>.
/// </summary>
public sealed record WriterLockAttempt(
    WriterLockOutcome Outcome,
    IWriterLock? Lock,
    TimeSpan Elapsed);

/// <summary>
/// Which OS named-object primitive a <see cref="NamedObjectWriterLock"/> should open.
/// CRITICAL: a Windows Mutex and a count-1 Semaphore are different kernel object types and
/// CANNOT coexist under the same object name — every writer for a governed path must open the
/// same kind. Defaults to <see cref="NamedLockPrimitive.Mutex"/>, the primitive Nexus.Developer
/// documents as its named cross-process writer lock.
/// </summary>
public enum NamedLockPrimitive
{
    Mutex = 0,
    Semaphore = 1,
}
