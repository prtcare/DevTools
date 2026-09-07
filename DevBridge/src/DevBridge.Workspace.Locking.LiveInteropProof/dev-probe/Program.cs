// SP1-M02 Lane B live-interop Developer probe.
//
// Every mode binds the REAL Nexus.Developer composition root (AddDevelopmentControl)
// exactly as Lane A wired Program.cs, so the Developer side of the cross-process proof is
// the genuine guarded store over the genuine NamedDevelopmentControlWriteLockFactory
// (System.Threading.Mutex). The disposable workbook is built by the same six-sheet layout
// the Developer integration tests use; the authoritative NEXUS_DEVELOPMENT_CONTROL.xlsx is
// never opened, copied, or written by this probe.
//
// Modes:
//   identity <path>                 print HASH + MutexName for a workbook path
//   make-workbook <dir>             build the disposable governed workbook in <dir>
//   seed <path> <parentId> <wiId>   guarded CreateNode (Milestone parent + Ready WorkItem)
//   hold <path> <seconds>           acquire the real named mutex via the composition root,
//                                   hold it <seconds>, release (same thread, no await)
//   reserve <path> <nodeId> <timeoutSeconds>
//                                   guarded ReserveWorkItemAsync with the given lock timeout;
//                                   report Success / LOCK_TIMEOUT / other, and assert the
//                                   workbook bytes are unchanged on LOCK_TIMEOUT

using System.Security.Cryptography;
using System.Text;
using ClosedXML.Excel;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Developer.Core.DevelopmentControl;
using Nexus.Developer.Infrastructure;

if (args.Length == 0)
{
    Console.Error.WriteLine("usage: DevProbe <mode> <args...>");
    return 2;
}

try
{
    return args[0] switch
    {
        "identity" => Identity(args[1]),
        "make-workbook" => MakeWorkbook(args[1]),
        "seed" => await SeedAsync(args[1], args[2], args[3]),
        "hold" => Hold(args[1], int.Parse(args[2])),
        "reserve" => await ReserveAsync(args[1], args[2], double.Parse(args[3])),
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

// ------------------------------------------------------------------ identity
static int Identity(string path)
{
    var identity = DevelopmentControlMutexIdentity.FromWorkbookPath(path);
    Console.WriteLine($"DEVIDENTITY path={identity.Identity}");
    Console.WriteLine($"DEVIDENTITY hash={identity.MutexName["NexusDevelopmentControl_".Length..]}");
    Console.WriteLine($"DEVIDENTITY name={identity.MutexName}");
    return 0;
}

// ------------------------------------------------------------------ disposable workbook
static int MakeWorkbook(string dir)
{
    var path = Path.Combine(Path.GetFullPath(dir), "NEXUS_DEVELOPMENT_CONTROL.xlsx");
    using (var workbook = new XLWorkbook())
    {
        WriteHeaders(workbook.AddWorksheet("Master Roadmap"), 5, WorkbookLayout.MasterRoadmapHeaders);
        WriteHeaders(workbook.AddWorksheet("Version History"), 5, WorkbookLayout.VersionHistoryHeaders);
        WriteHeaders(workbook.AddWorksheet("Active Changes"), 5, WorkbookLayout.ActiveChangesHeaders);
        WriteHeaders(workbook.AddWorksheet("Audit Findings"), 5, WorkbookLayout.AuditFindingsHeaders);
        WriteHeaders(workbook.AddWorksheet("Activity Log"), 4, WorkbookLayout.ActivityLogHeaders);
        var controlCenter = workbook.AddWorksheet("Control Center");
        controlCenter.Cell(2, 1).SetValue("Development Control\nWorkbook v1.0\nRoadmap v1.0");
        workbook.SaveAs(path);
    }
    Console.WriteLine($"WBOK path={path}");
    return 0;
}

// ------------------------------------------------------------------ seed (guarded create)
static async Task<int> SeedAsync(string path, string parentId, string workItemId)
{
    var guard = await GuardAsync(path, 10);
    var parent = await guard.CreateNodeAsync(NewNode(parentId, null, NodeType.Milestone, Status.Planned), Envelope(NextChangeId()));
    Console.WriteLine($"SEED parent success={parent.Success}");
    if (!parent.Success) return 1;
    var wi = await guard.CreateNodeAsync(NewNode(workItemId, new NodeId(parentId), NodeType.WorkItem, Status.Ready), Envelope(NextChangeId()));
    Console.WriteLine($"SEED workitem success={wi.Success}");
    return wi.Success ? 0 : 1;
}

// ------------------------------------------------------------------ hold (real mutex, held across process)
static int Hold(string path, int seconds)
{
    using var provider = Build(path, 10);
    var factory = provider.GetRequiredService<IDevelopmentControlWriteLockFactory>();
    var identity = provider.GetRequiredService<DevelopmentControlMutexIdentity>();

    var attempt = factory.TryAcquire(identity, TimeSpan.FromSeconds(10));
    Console.WriteLine($"DEVHOLD acquire={attempt.Outcome}");
    if (attempt.Outcome != DevelopmentControlLockOutcome.Acquired)
        return 1;
    using (attempt.Lock)
    {
        Console.WriteLine("DEVHOLD HELD-START");
        Console.Out.Flush();
        Thread.Sleep(TimeSpan.FromSeconds(seconds)); // synchronous hold: no await between acquire/release
        Console.WriteLine("DEVHOLD HELD-END");
    }
    Console.WriteLine("DEVHOLD RELEASED");
    return 0;
}

// ------------------------------------------------------------------ reserve (guarded write, may lock-timeout)
static async Task<int> ReserveAsync(string path, string nodeId, double timeoutSeconds)
{
    var before = FileSha(path);
    var outcome = "unknown";
    string details = "";
    bool success = false;

    var guard = await GuardAsync(path, timeoutSeconds);
    var node = await guard.GetNodeAsync(new NodeId(nodeId));
    if (node is null)
    {
        Console.WriteLine("DEVRESERVE node=null");
        return 1;
    }

    MutationResult<Node> res;
    try
    {
        res = await guard.ReserveWorkItemAsync(
            new NodeId(nodeId),
            new ActorRef(ActorType.Agent, "interop-probe", "Interop Probe"),
            "sp1-m02-live", "dev-probe", Envelope(NextChangeId()));
        success = res.Success;
        details = string.Join(" | ", res.ValidationErrors ?? Array.Empty<string>());
    }
    catch (Exception ex)
    {
        details = "THREW " + ex.GetType().Name + ": " + ex.Message;
    }

    outcome = !success
        ? (details.Contains("LOCK_TIMEOUT", StringComparison.OrdinalIgnoreCase) ? "LOCK_TIMEOUT" : "FAILED:" + details)
        : "SUCCESS";

    Console.WriteLine($"DEVRESERVE node={nodeId} timeout={timeoutSeconds}s outcome={outcome}");
    var after = FileSha(path);
    Console.WriteLine($"DEVRESERVE workbookUnchangedOnFailure={(success || outcome != "LOCK_TIMEOUT" ? "n/a" : (before == after ? "TRUE" : "FALSE"))}");
    return 0;
}

// ------------------------------------------------------------------ helpers
static async Task<IConcurrencyGuardedDevelopmentControlStore> GuardAsync(string path, double timeoutSeconds)
{
    var provider = Build(path, timeoutSeconds);
    return provider.GetRequiredService<IConcurrencyGuardedDevelopmentControlStore>();
}

static ServiceProvider Build(string path, double timeoutSeconds)
{
    var services = new ServiceCollection();
    services.AddDevelopmentControl(Path.GetFullPath(path), TimeSpan.FromSeconds(timeoutSeconds));
    return services.BuildServiceProvider();
}

static string FileSha(string path)
{
    var bytes = File.ReadAllBytes(path);
    return Convert.ToHexString(SHA256.HashData(bytes));
}

static string NextChangeId() => "CHG-20260907-" + Guid.NewGuid().ToString("N").Substring(0, 6);

static Node NewNode(string id, NodeId? parent, NodeType type, Status status) => new(
    new NodeId(id), parent, type, "", "", "03", null, "Node " + id, null,
    Array.Empty<NodeId>(), false, Array.Empty<string>(), Array.Empty<string>(),
    Array.Empty<string>(), Array.Empty<string>(), null, null, status, false,
    null, null, null, "Durai", null, null, 0, false, "test", null,
    DateTimeOffset.MinValue, DateTimeOffset.MinValue);

static MutationEnvelope Envelope(string changeId, int? expectedRowVersion = null) => new(
    expectedRowVersion,
    new ActorRef(ActorType.Agent, "interop-probe", "Interop Probe"),
    "NexusDevInteropProbe", null, "session-live", null, changeId, null, null,
    "live interop proof");

static void WriteHeaders(IXLWorksheet sheet, int headerRow, IReadOnlyList<string> headers)
{
    for (var column = 0; column < headers.Count; column++)
    {
        sheet.Cell(headerRow, column + 1).SetValue(headers[column]);
    }
}

// Header layouts for the disposable governed workbook, mirroring the Developer integration
// test fixture exactly (a top-level program cannot declare file-scope fields, so they live
// in a static layout class).
static class WorkbookLayout
{
    internal static readonly string[] MasterRoadmapHeaders =
{
    "Node ID", "Parent ID", "Node Type", "Sort Key", "Hierarchy Path", "Layer", "Phase",
    "Name", "Outcome / Purpose", "Dependencies", "Parallel Safe", "Projects",
    "Files / Globs", "Schema Contexts", "Contracts / APIs", "Gate",
    "Acceptance Criteria", "Status", "Breakdown Complete", "Manual Progress",
    "Derived Progress", "Reported Progress", "Owner", "Priority", "Risk", "Source",
    "Notes", "Simple Goal", "Current Evidence", "Next Action", "Column1", "Column2",
    "Column3"
};

internal static readonly string[] VersionHistoryHeaders =
{
    "Node ID", "Parent ID", "Node Type", "Sort Key", "Hierarchy Path", "Layer", "Phase",
    "Name", "Outcome / Purpose", "Dependencies", "Parallel Safe", "Projects",
    "Files / Globs", "Schema Contexts", "Contracts / APIs", "Gate",
    "Acceptance Criteria", "Status", "Breakdown Complete", "Manual Progress",
    "Derived Progress", "Reported Progress", "Owner", "Priority", "Risk", "Source",
    "Notes", "Baseline Version", "Record Version", "Effective From", "Is Current",
    "Change ID", "Supersedes Version", "Change Type", "Change Summary",
    "ADR / Decision Link"
};

internal static readonly string[] ActiveChangesHeaders =
{
    "Change ID", "Node ID", "Milestone / Feature", "Summary", "Requested By", "Worker",
    "Repositories", "Projects", "Files / Globs", "Schema Contexts", "Contracts / APIs",
    "Status", "Preflight Verdict", "Conflicts With", "Dependency On", "Risk", "Branch",
    "Worktree", "Started At", "Last Heartbeat", "Completed At", "Result / Evidence",
    "Change Version", "Session / Chat", "Notes", "Version History ID", "ADR ID",
    "Affected Nodes", "Change Type", "Validation Result"
};

internal static readonly string[] AuditFindingsHeaders =
{
    "Finding ID", "Severity", "Area", "Repository", "Evidence", "Impact",
    "Required Action", "Roadmap Link", "Status", "Owner", "Due Gate", "Verification",
    "Notes"
};

internal static readonly string[] ActivityLogHeaders =
{
    "Activity ID", "Timestamp UTC", "Actor Type", "Actor ID", "Actor Name", "Source",
    "Chat Platform", "Chat / Session ID", "Prompt ID", "Change ID", "Correlation ID",
    "Operation", "Entity Type", "Entity ID", "Parent ID", "Expected Row Version",
    "Previous Row Version", "New Row Version", "Before Value", "After Value", "Reason",
    "Repository", "Project", "Branch", "Worktree", "Files / Globs",
    "Preflight Verdict", "Result", "Evidence", "Error Code", "Error Message",
    "Duration", "Human Review Status", "Created At"
};
}
