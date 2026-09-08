// Program.cs — SP1-M02 Shared Interoperable Writer Lock fixture runner (console exit-code
// harness mirroring the M01 DevBridge.Workspace.Tests style — NO xunit/NUnit).
//
// Safety posture (mirrors M01):
//   * Child processes (self-mode) are spawned with ProcessStartInfo.ArgumentList — no shell
//     interpolation anywhere.
//   * No network is contacted.
//   * Every governed path lives under a throwaway root under Path.GetTempPath(); the harness
//     never touches the real Nexus.Developer workbook or any real repo path.
//
// Child self-modes exposed by this harness (used to prove KERNEL mutual exclusion across
// PROCESSES):
//   --lock-hold <named|file> <path> <acquireTimeoutMs> <holdMs>
//       Acquires the layer over <path> with a bounded acquire timeout, prints an ACQUIRE line,
//       prints HELD on success, sleeps holdMs, releases, prints RELEASED. Exits 0.
//   --lock-abandon <path>
//       Acquires the NAMED (mutex) layer over <path>, prints ABANDONED-HELD, and exits WITHOUT
//       releasing — the process death abandons the named mutex to its next waiter.
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using DevBridge.Workspace.Locking;

int pass = 0, fail = 0;
var failures = new List<string>();

void Check(bool cond, string name, string detail)
{
    if (cond) { pass++; }
    else { fail++; failures.Add($"  FAIL {name}: {detail}"); }
}

// ---- self-mode: a child process holds a lock layer for a bounded time -----------------------
static int RunLockHold(string[] args)
{
    // args = --lock-hold <mode:named|file> <path> <acquireMs> <holdMs>
    string mode = args[1];
    string path = args[2];
    int acquireMs = int.TryParse(args[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out var a) ? a : 1000;
    int holdMs = int.TryParse(args[4], NumberStyles.Integer, CultureInfo.InvariantCulture, out var h) ? h : 100;

    WriterLockAttempt attempt;
    if (mode == "named")
        attempt = NamedObjectWriterLock.TryAcquire(SharedLockIdentity.FromWorkbookPath(path), TimeSpan.FromMilliseconds(acquireMs));
    else if (mode == "file")
        attempt = FileWriterLock.TryAcquire(path, TimeSpan.FromMilliseconds(acquireMs));
    else
    {
        Console.WriteLine("BADMODE " + mode);
        return 2;
    }

    Console.WriteLine("ACQUIRE " + attempt.Outcome + " " + Math.Round(attempt.Elapsed.TotalMilliseconds, 1).ToString("0.###", CultureInfo.InvariantCulture));
    if (attempt.Lock is null) return 0; // Timeout / SystemFailure — process exits normally

    Console.WriteLine("HELD");
    Thread.Sleep(holdMs);
    attempt.Lock.Release();
    attempt.Lock.Dispose();
    Console.WriteLine("RELEASED");
    return 0;
}

// ---- self-mode: a child process abandons a named mutex (simulates a crashed Developer writer) -
static int RunLockAbandon(string[] args)
{
    // args = --lock-abandon <path>
    string path = args[1];
    var attempt = NamedObjectWriterLock.TryAcquire(SharedLockIdentity.FromWorkbookPath(path), TimeSpan.FromSeconds(10));
    if (attempt.Lock is null)
    {
        Console.WriteLine("ABANDON-NOT-HELD " + attempt.Outcome);
        return 0;
    }

    Console.WriteLine("ABANDONED-HELD");
    return 0; // intentionally do NOT Release/Dispose — process exit abandons the mutex
}

// ---- child-process plumbing (ArgumentList only — no shell) -----------------------------------
static Process StartChild(params string[] args)
{
    var psi = new ProcessStartInfo
    {
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true,
    };

    // Spawn ourselves. Under `dotnet run`/apphost Environment.ProcessPath is our built .exe; if it
    // is ever not usable, fall back to `dotnet <this assembly> <args>`.
    string? host = Environment.ProcessPath;
    if (!string.IsNullOrEmpty(host) && File.Exists(host))
    {
        psi.FileName = host;
    }
    else
    {
        psi.FileName = "dotnet";
        psi.ArgumentList.Add(typeof(Program).Assembly.Location);
    }

    foreach (string a in args) psi.ArgumentList.Add(a);

    var process = new Process { StartInfo = psi };
    if (!process.Start()) throw new InvalidOperationException("Failed to start child process.");
    return process;
}

static (int Code, string Out) Capture(Process process)
{
    string stdout = process.StandardOutput.ReadToEnd();
    string stderr = process.StandardError.ReadToEnd();
    process.WaitForExit();
    string combined = stdout;
    if (!string.IsNullOrWhiteSpace(stderr)) combined += "\n[stderr] " + stderr.Trim();
    return (process.ExitCode, combined);
}

static (int Code, string Out) RunChild(params string[] args)
{
    using var p = StartChild(args);
    return Capture(p);
}

static (string Outcome, double Ms)? ParseAcquireLine(string output)
{
    var m = Regex.Match(output, @"ACQUIRE\s+([A-Za-z]+)\s+([\d.]+)");
    if (!m.Success) return null;
    double ms = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
    return (m.Groups[1].Value, ms);
}

// ---- independent reference transcription of the documented Developer algorithm ----------------
// Cross-checks SharedLockIdentity against the algorithm documented in Nexus.Developer
// DevelopmentControlMutexIdentity.cs (prefix + UPPERCASE SHA-256 hex of the normalized identity),
// transcribed independently here so a transcription bug in the library cannot hide.
static string ReferenceObjectName(string input)
{
    string value = input.Trim();
    bool looksLikePath = value.Contains('\\') || value.Contains('/') || Path.HasExtension(value);
    string normalized;
    if (!looksLikePath)
    {
        normalized = value;
    }
    else
    {
        string full = Path.GetFullPath(value).Replace('/', '\\').TrimEnd('\\');
        normalized = OperatingSystem.IsWindows() ? full.ToLowerInvariant() : full;
    }

    string hex = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)));
    return "NexusDevelopmentControl_" + hex;
}

// ---- dispatch (child self-modes return before the harness body runs) --------------------------
if (args.Length >= 5 && args[0] == "--lock-hold") return RunLockHold(args);
if (args.Length >= 2 && args[0] == "--lock-abandon") return RunLockAbandon(args);

// ---- parent harness --------------------------------------------------------------------------
string root = Path.Combine(Path.GetTempPath(), "m02lock-" + Guid.NewGuid().ToString("N")[..8]);
Directory.CreateDirectory(root);
double boundedCeilingMs = 3000; // every bounded wait below must finish well inside this

try
{
    // =========================================================== A. identity derivation
    {
        string wbAbs = Path.Combine(root, "IdentityA", "Workbook.XLSX");
        string wbAltSpelling = wbAbs.ToLowerInvariant().Replace('\\', '/'); // forward slashes + lower
        string wbSpacey = "  " + wbAbs + "  ";
        string dirTrailing = Path.Combine(root, "IdentityB") + Path.DirectorySeparatorChar;
        string dirNoTrailing = Path.Combine(root, "IdentityB");
        string relPlain = Path.Combine("m02rel", "File.xlsx");
        string relDotDot = Path.Combine("m02rel", "..", "m02rel", "File.xlsx");
        string token = "shared-control-store-alpha";
        string otherAbs = Path.Combine(root, "IdentityC", "Another.xlsx");

        var idAbs = SharedLockIdentity.FromWorkbookPath(wbAbs);
        Check(idAbs.ObjectName.StartsWith(SharedLockIdentity.ObjectNamePrefix, StringComparison.Ordinal),
            "IDENT: object name uses the Developer prefix", idAbs.ObjectName[..SharedLockIdentity.ObjectNamePrefix.Length]);
        string hexPart = idAbs.ObjectName[SharedLockIdentity.ObjectNamePrefix.Length..];
        Check(hexPart.Length == 64, "IDENT: 64-char hash suffix", $"len={hexPart.Length}");
        Check(Regex.IsMatch(hexPart, @"^[0-9A-F]{64}$"), "IDENT: UPPERCASE hex suffix", hexPart);
        Check(idAbs.HashHex == hexPart, "IDENT: HashHex property equals the object-name suffix", idAbs.HashHex);

        Check(SharedLockIdentity.FromWorkbookPath(wbAbs).ObjectName == idAbs.ObjectName,
            "IDENT: deterministic for the same absolute path", idAbs.ObjectName);
        Check(SharedLockIdentity.FromWorkbookPath(wbAltSpelling).ObjectName == idAbs.ObjectName,
            "IDENT: mixed-case + forward-slash spelling folds to the same name", "lower(fwd) vs abs");
        // FromStoreIdentity trims before path detection (mirrors Developer). FromWorkbookPath runs
        // Path.GetFullPath first, so whitespace is trimmed only on the FromStoreIdentity path.
        Check(SharedLockIdentity.FromStoreIdentity(wbSpacey).ObjectName == idAbs.ObjectName,
            "IDENT: surrounding whitespace is trimmed on the store-identity path", wbSpacey);
        Check(SharedLockIdentity.FromStoreIdentity(dirTrailing).ObjectName == SharedLockIdentity.FromStoreIdentity(dirNoTrailing).ObjectName,
            "IDENT: trailing backslash on a directory folds away", $"{dirTrailing} vs {dirNoTrailing}");
        Check(SharedLockIdentity.FromWorkbookPath(relDotDot).ObjectName == SharedLockIdentity.FromWorkbookPath(relPlain).ObjectName,
            "IDENT: relative-with-extension normalizes via GetFullPath", $"{relDotDot} vs {relPlain}");
        Check(SharedLockIdentity.FromWorkbookPath(relPlain).Identity.EndsWith(Path.Combine("m02rel", "file.xlsx"), StringComparison.OrdinalIgnoreCase),
            "IDENT: relative path resolved to a full path (case-folded on Windows)", SharedLockIdentity.FromWorkbookPath(relPlain).Identity);
        Check(SharedLockIdentity.FromStoreIdentity(token).Identity == token,
            "IDENT: non-path store token used verbatim", SharedLockIdentity.FromStoreIdentity(token).Identity);
        Check(SharedLockIdentity.FromWorkbookPath(otherAbs).ObjectName != idAbs.ObjectName,
            "IDENT: distinct governed paths get distinct names", otherAbs);

        // Reference cross-check over the documented edge-case set.
        var edgeCases = new (string Label, string Input)[]
        {
            ("abs-mixed-case", wbAbs),
            ("forward-slash-lower", wbAltSpelling),
            ("spacey", wbSpacey),
            ("trailing-backslash-dir", dirTrailing),
            ("relative-ext-plain", relPlain),
            ("relative-ext-dotdot", relDotDot),
            ("store-token", token),
            ("other-abs", otherAbs),
        };
        foreach (var (label, input) in edgeCases)
        {
            string actual = SharedLockIdentity.FromStoreIdentity(input).ObjectName;
            string reference = ReferenceObjectName(input);
            Check(actual == reference, $"IDENT-REF: {label} matches the documented algorithm", $"{actual} vs {reference}");
        }
    }

    // =========================================================== B. named-object layer, in-proc
    {
        string path = Path.Combine(root, "InProcNamed", "n.xlsx");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var id = SharedLockIdentity.FromWorkbookPath(path);

        var first = NamedObjectWriterLock.TryAcquire(id, TimeSpan.FromSeconds(5));
        Check(first.Outcome == WriterLockOutcome.Acquired && first.Lock is not null, "NAMED-INPROC: free acquire -> Acquired", first.Outcome.ToString());
        Check(first.Lock!.IsHeld, "NAMED-INPROC: IsHeld true while held", "");
        first.Lock.Release();
        Check(!first.Lock.IsHeld, "NAMED-INPROC: IsHeld false after Release", "");
        first.Lock.Dispose();

        var second = NamedObjectWriterLock.TryAcquire(id, TimeSpan.FromSeconds(5));
        Check(second.Outcome == WriterLockOutcome.Acquired, "NAMED-INPROC: released lock is acquirable again", second.Outcome.ToString());
        second.Lock!.Release();
        second.Lock.Dispose();

        // Distinct identity is independent of a held one.
        string otherPath = Path.Combine(root, "InProcNamed", "m.xlsx");
        var idOther = SharedLockIdentity.FromWorkbookPath(otherPath);
        var held = NamedObjectWriterLock.TryAcquire(id, TimeSpan.FromSeconds(5));
        var other = NamedObjectWriterLock.TryAcquire(idOther, TimeSpan.FromSeconds(5));
        Check(held.Outcome == WriterLockOutcome.Acquired && other.Outcome == WriterLockOutcome.Acquired,
            "NAMED-INPROC: a different governed path is unaffected by a held lock", $"{held.Outcome}/{other.Outcome}");
        other.Lock!.Release(); other.Lock.Dispose();
        held.Lock!.Release(); held.Lock.Dispose();

        // The alternative primitive (count-1 named semaphore) still acquires/releases in-process.
        var sem = NamedObjectWriterLock.TryAcquire(id, TimeSpan.FromSeconds(5), NamedLockPrimitive.Semaphore);
        Check(sem.Outcome == WriterLockOutcome.Acquired && sem.Lock is not null, "NAMED-INPROC: semaphore primitive acquires", sem.Outcome.ToString());
        sem.Lock!.Release(); sem.Lock.Dispose();
    }

    // =========================================================== C. file-lock layer, in-proc
    {
        string path = Path.Combine(root, "InProcFile", "f.xlsx");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var id = SharedLockIdentity.FromWorkbookPath(path);

        var first = FileWriterLock.TryAcquire(path, TimeSpan.FromSeconds(5));
        Check(first.Outcome == WriterLockOutcome.Acquired && first.Lock is not null, "FILE-INPROC: free acquire -> Acquired", first.Outcome.ToString());
        var fw = first.Lock as FileWriterLock;
        string expectedLockPath = Path.Combine(Path.GetDirectoryName(path)!, id.HashHex + ".lock");
        Check(fw is not null && fw.LockPath == expectedLockPath, "FILE-INPROC: deterministic lock-file path", fw?.LockPath ?? "null");
        Check(fw is not null && File.Exists(fw.LockPath), "FILE-INPROC: lock file exists while held", fw?.LockPath ?? "null");

        var contended = FileWriterLock.TryAcquire(path, TimeSpan.FromMilliseconds(200));
        Check(contended.Outcome == WriterLockOutcome.Timeout && contended.Lock is null,
            "FILE-INPROC: same-process second exclusive open -> bounded Timeout", contended.Outcome.ToString());
        Check(contended.Elapsed.TotalMilliseconds < boundedCeilingMs, "FILE-INPROC: contention wait is bounded (no hang)", contended.Elapsed.TotalMilliseconds.ToString("0.###", CultureInfo.InvariantCulture));

        first.Lock!.Release();
        Check(!first.Lock.IsHeld, "FILE-INPROC: IsHeld false after Release", "");

        var again = FileWriterLock.TryAcquire(path, TimeSpan.FromSeconds(5));
        Check(again.Outcome == WriterLockOutcome.Acquired, "FILE-INPROC: released file lock is acquirable again", again.Outcome.ToString());
        again.Lock!.Release(); again.Lock.Dispose();
    }

    // =========================================================== D. shared facade (two layers)
    {
        string path = Path.Combine(root, "Shared", "s.xlsx");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        var acq = SharedDevelopmentControlWriterLock.TryAcquire(path, TimeSpan.FromSeconds(5));
        bool onWindows = OperatingSystem.IsWindows();
        Check(acq.Outcome == WriterLockOutcome.Acquired && acq.Lock is not null, "FACADE: combined acquire -> Acquired", acq.Outcome.ToString());
        Check(acq.NamedObjectLayerEnabled == onWindows, "FACADE: named-object layer attempted on Windows only", $"enabled={acq.NamedObjectLayerEnabled} windows={onWindows}");
        Check(acq.NamedObjectAttempt is null || acq.NamedObjectAttempt.Lock is not null, "FACADE: named-object layer held when attempted", acq.NamedObjectAttempt?.Outcome.ToString() ?? "skipped");
        Check(acq.FileLockAttempt is not null && acq.FileLockAttempt.Lock is not null, "FACADE: file-lock layer always held", acq.FileLockAttempt?.Outcome.ToString() ?? "null");
        Check(acq.Lock!.IsHeld, "FACADE: IsHeld true while both layers held", "");
        acq.Lock.Release();
        Check(!acq.Lock.IsHeld, "FACADE: IsHeld false after Release (both layers)", "");

        var again = SharedDevelopmentControlWriterLock.TryAcquire(path, TimeSpan.FromSeconds(5));
        Check(again.Outcome == WriterLockOutcome.Acquired, "FACADE: released facade is acquirable again", again.Outcome.ToString());
        again.Lock!.Dispose();

        // Named-object layer disabled => file-lock-only acquire still succeeds.
        var fileOnly = SharedDevelopmentControlWriterLock.TryAcquire(path, TimeSpan.FromSeconds(5), new SharedWriterLockOptions { UseNamedObjectLayer = false });
        Check(fileOnly.Outcome == WriterLockOutcome.Acquired && !fileOnly.NamedObjectLayerEnabled && fileOnly.FileLockAttempt!.Lock is not null,
            "FACADE: named layer can be disabled (file lock still held)", fileOnly.Outcome.ToString());
        fileOnly.Lock!.Release();
    }

    // =========================================================== E. named object, across processes
    {
        string path = Path.Combine(root, "XProcNamed", "w.xlsx");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        // Child A holds the named mutex for ~2.2 s.
        using var procA = StartChild("--lock-hold", "named", path, "3000", "2200");
        Thread.Sleep(900); // A acquires almost immediately; 900ms is ample margin

        // The parent's facade must NOT write while a real (cross-process) Developer-style holder
        // owns the named object: named layer contends -> Timeout before any file lock is taken.
        var facadeBlocked = SharedDevelopmentControlWriterLock.TryAcquire(path, TimeSpan.FromMilliseconds(300));
        Check(facadeBlocked.Outcome == WriterLockOutcome.Timeout && facadeBlocked.Lock is null,
            "NAMED-XPROC: facade times out while another PROCESS holds the named object", facadeBlocked.Outcome.ToString());
        Check(facadeBlocked.Elapsed.TotalMilliseconds < boundedCeilingMs, "NAMED-XPROC: facade block is bounded (no hang)", facadeBlocked.Elapsed.TotalMilliseconds.ToString("0.###", CultureInfo.InvariantCulture));

        // Child B: same governed path, short acquire timeout -> must time out while A holds.
        using var procB = StartChild("--lock-hold", "named", path, "600", "100");
        var (codeB, outB) = Capture(procB);
        Check(codeB == 0, "NAMED-XPROC: contending child exits 0", $"code={codeB}");
        Check(outB.Contains("Timeout", StringComparison.Ordinal), "NAMED-XPROC: second PROCESS times out while first holds", outB.Replace("\n", " | "));
        var parsedB = ParseAcquireLine(outB);
        string bDetail = parsedB.HasValue
            ? parsedB.Value.Outcome + " " + parsedB.Value.Ms.ToString("0.###", CultureInfo.InvariantCulture)
            : "no-ACQUIRE-line";
        Check(parsedB is { Outcome: "Timeout" } && parsedB.Value.Ms < boundedCeilingMs,
            "NAMED-XPROC: second PROCESS wait is bounded (no hang)", bDetail);

        var (codeA, outA) = Capture(procA);
        Check(codeA == 0, "NAMED-XPROC: first holder exits 0", $"code={codeA}");
        Check(outA.Contains("HELD", StringComparison.Ordinal) && outA.Contains("RELEASED", StringComparison.Ordinal),
            "NAMED-XPROC: first holder HELD then RELEASED", outA.Replace("\n", " | "));

        // Child C acquires after A released.
        var (codeC, outC) = RunChild("--lock-hold", "named", path, "5000", "150");
        Check(codeC == 0 && outC.Contains("HELD", StringComparison.Ordinal) && outC.Contains("RELEASED", StringComparison.Ordinal),
            "NAMED-XPROC: acquires after the holder releases", $"code={codeC} {outC.Replace("\n", " | ")}");
    }

    // =========================================================== F. file lock, across processes
    {
        string path = Path.Combine(root, "XProcFile", "w.xlsx");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        using var procA = StartChild("--lock-hold", "file", path, "3000", "2200");
        Thread.Sleep(900);

        // Parent facade, named layer disabled, must time out while a PROCESS holds the file lock.
        var facadeBlocked = SharedDevelopmentControlWriterLock.TryAcquire(path, TimeSpan.FromMilliseconds(300),
            new SharedWriterLockOptions { UseNamedObjectLayer = false });
        Check(facadeBlocked.Outcome == WriterLockOutcome.Timeout && facadeBlocked.Lock is null,
            "FILE-XPROC: facade (file-only) times out while another PROCESS holds the file lock", facadeBlocked.Outcome.ToString());

        using var procB = StartChild("--lock-hold", "file", path, "600", "100");
        var (codeB, outB) = Capture(procB);
        Check(codeB == 0, "FILE-XPROC: contending child exits 0", $"code={codeB}");
        Check(outB.Contains("Timeout", StringComparison.Ordinal), "FILE-XPROC: second PROCESS times out while first holds the file lock", outB.Replace("\n", " | "));

        var (codeA, outA) = Capture(procA);
        Check(codeA == 0 && outA.Contains("HELD", StringComparison.Ordinal) && outA.Contains("RELEASED", StringComparison.Ordinal),
            "FILE-XPROC: first holder HELD then RELEASED", $"code={codeA} {outA.Replace("\n", " | ")}");

        var (codeC, outC) = RunChild("--lock-hold", "file", path, "5000", "150");
        Check(codeC == 0 && outC.Contains("HELD", StringComparison.Ordinal) && outC.Contains("RELEASED", StringComparison.Ordinal),
            "FILE-XPROC: acquires after the holder releases", $"code={codeC} {outC.Replace("\n", " | ")}");
    }

    // =========================================================== G. abandoned named mutex + cleanup
    {
        string path = Path.Combine(root, "Abandon", "w.xlsx");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var identity = SharedLockIdentity.FromWorkbookPath(path);

        // Keep the named object alive across the child's exit so its abandoned state is observable.
        using (var keepAlive = new Mutex(false, identity.ObjectName))
        {
            var (codeAb, outAb) = RunChild("--lock-abandon", path);
            Check(codeAb == 0, "ABANDON: crashing-writer child exits 0", $"code={codeAb}");
            Check(outAb.Contains("ABANDONED-HELD", StringComparison.Ordinal), "ABANDON: child acquired and died holding", outAb.Replace("\n", " | "));

            var recovered = NamedObjectWriterLock.TryAcquire(identity, TimeSpan.FromSeconds(5));
            Check(recovered.Outcome == WriterLockOutcome.AbandonedRecovered && recovered.Lock is not null,
                "ABANDON: next acquire reports AbandonedRecovered and holds", recovered.Outcome.ToString());
            Check(recovered.Lock!.IsHeld, "ABANDON: recovered lock is held", "");
            recovered.Lock.Release();
            recovered.Lock.Dispose();

            var after = NamedObjectWriterLock.TryAcquire(identity, TimeSpan.FromSeconds(5));
            Check(after.Outcome == WriterLockOutcome.Acquired, "ABANDON: lock is cleanly acquirable after recovery", after.Outcome.ToString());
            after.Lock!.Release(); after.Lock.Dispose();
        }
    }
}
finally
{
    try { Directory.Delete(root, recursive: true); } catch { /* best effort */ }
}

// ---- report ----------------------------------------------------------------------------------
Console.WriteLine();
Console.WriteLine("================================================================");
Console.WriteLine(" SP1-M02 Shared Interoperable Writer Lock — fixture runner");
Console.WriteLine("================================================================");
foreach (string f in failures) Console.WriteLine(f);
Console.WriteLine();
Console.WriteLine($"TOTAL  : {pass + fail} checks");
Console.WriteLine($"PASSED : {pass}");
Console.WriteLine($"FAILED : {fail}");
Console.WriteLine(pass > 0 && fail == 0 ? "RESULT : ALL PASS" : "RESULT : FAILURES PRESENT");
return fail == 0 ? 0 : 1;
