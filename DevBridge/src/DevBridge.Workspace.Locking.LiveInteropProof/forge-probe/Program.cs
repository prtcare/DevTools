// SP1-M02 Lane B live-interop Forge probe.
//
// Uses the real M02 library DevBridge.Workspace.Locking exactly as Forge/DevTools writers
// would (SharedLockIdentity + NamedObjectWriterLock, default Mutex primitive). Never
// touches any repo; no workbook is opened by the Forge side (the M02 lock layer operates on
// the canonical path string only).
//
// Modes:
//   identity <path>               print HASH + ObjectName for a workbook path
//   acquire-hold <path> <seconds> acquire the named mutex, hold <seconds>, release
//   tryacquire <path> <timeoutMs> bounded acquire; print outcome + elapsed ms

using DevBridge.Workspace.Locking;

if (args.Length == 0)
{
    Console.Error.WriteLine("usage: ForgeProbe <mode> <args...>");
    return 2;
}

try
{
    return args[0] switch
    {
        "identity" => Identity(args[1]),
        "acquire-hold" => AcquireHold(args[1], int.Parse(args[2])),
        "tryacquire" => TryAcquire(args[1], int.Parse(args[2])),
        _ => Usage()
    };
}
catch (Exception ex)
{
    Console.Error.WriteLine("UNEXPECTED: " + ex);
    return 3;
}

static int Usage()
{
    Console.Error.WriteLine("unknown mode");
    return 2;
}

static int Identity(string path)
{
    var identity = SharedLockIdentity.FromWorkbookPath(path);
    Console.WriteLine($"FORGEIDENTITY path={identity.Identity}");
    Console.WriteLine($"FORGEIDENTITY hash={identity.HashHex}");
    Console.WriteLine($"FORGEIDENTITY name={identity.ObjectName}");
    return 0;
}

static int AcquireHold(string path, int seconds)
{
    var identity = SharedLockIdentity.FromWorkbookPath(path);
    var attempt = NamedObjectWriterLock.TryAcquire(identity, TimeSpan.FromSeconds(10), NamedLockPrimitive.Mutex);
    Console.WriteLine($"FORGEHOLD acquire={attempt.Outcome}");
    if (attempt.Outcome != WriterLockOutcome.Acquired || attempt.Lock is null)
        return 1;
    using (attempt.Lock)
    {
        Console.WriteLine("FORGEHOLD HELD-START");
        Console.Out.Flush();
        Thread.Sleep(TimeSpan.FromSeconds(seconds));
        Console.WriteLine("FORGEHOLD HELD-END");
    }
    Console.WriteLine("FORGEHOLD RELEASED");
    return 0;
}

static int TryAcquire(string path, int timeoutMs)
{
    var identity = SharedLockIdentity.FromWorkbookPath(path);
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var attempt = NamedObjectWriterLock.TryAcquire(identity, TimeSpan.FromMilliseconds(timeoutMs), NamedLockPrimitive.Mutex);
    sw.Stop();
    Console.WriteLine($"FORGETRY outcome={attempt.Outcome} elapsedMs={sw.ElapsedMilliseconds} held={attempt.Lock?.IsHeld}");
    if (attempt.Outcome is WriterLockOutcome.Acquired or WriterLockOutcome.AbandonedRecovered && attempt.Lock is not null)
    {
        attempt.Lock.Release();
        attempt.Lock.Dispose();
    }
    return 0;
}
