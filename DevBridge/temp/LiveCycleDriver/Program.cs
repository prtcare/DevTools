// LiveCycleDriver.cs — the FINAL HARDENED LANE C TRIAL proving-cycle driver.
//
// Drives the REAL DB-M12.1..DB-M12.4 UI/backend path for a governed operator
// command against the LIVE DevBridge state: it loads the live config, looks the
// command up in the operator command catalog, and executes it through
// OperatorCommandService.Execute — the exact code path a DevBridge operator
// console button triggers. No task is hard-coded: the backend scripts select,
// reserve, and hand off per the authoritative workbook and governed policy.
//
// The driver writes nothing itself: it only invokes the canonical backend scripts
// and prints the structured result + refreshed state. It never touches the
// workbook, Nexus source, or git.
//
// Usage: LiveCycleDriver <CommandId> [key=value ...]
//   e.g. LiveCycleDriver GET_CURRENT_LIFECYCLE_STATE
//        LiveCycleDriver START_NEXT_CYCLE
//        LiveCycleDriver RESERVE_TASK
//        LiveCycleDriver CREATE_CHATGPT_HANDOFF
using System.Text.Json;
using DevBridge.Engine;

internal static class Program
{
    private static int _pass;
    private static int _fail;
    private static readonly List<string> Failures = new();

    private static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.WriteLine("Usage: LiveCycleDriver <CommandId> [key=value ...]");
            return 2;
        }

        string commandId = args[0];
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal);
        string? nodeId = null, changeId = null, mode = null, actor = "operator", expectedState = null;
        foreach (var a in args.Skip(1))
        {
            int eq = a.IndexOf('=');
            if (eq <= 0) continue;
            string k = a[..eq], v = a[(eq + 1)..];
            switch (k.ToLowerInvariant())
            {
                case "nodeid": nodeId = v; break;
                case "changeid": changeId = v; break;
                case "mode": mode = v; break;
                case "actor": actor = v; break;
                case "expectedcurrentstate": expectedState = v; break;
                default: parameters[k] = v; break;
            }
        }

        var cfg = DevBridgeConfig.Load();
        Console.WriteLine($"LIVE ROOT          : {cfg.Root}");
        Console.WriteLine($"WORKBOOK           : {cfg.WorkbookPath}");
        Console.WriteLine($"MODE (config)      : {DevBridgeMode.ToToken(cfg.Mode)}");

        var cmd = OperatorCommandCatalog.Get(commandId);
        if (cmd is null)
        {
            Console.WriteLine($"COMMAND            : UNKNOWN ({commandId})");
            return 2;
        }

        Console.WriteLine($"COMMAND            : {commandId} ({cmd.DisplayName})");
        Console.WriteLine($"KIND               : {cmd.Kind}");
        Console.WriteLine($"REQUIRED STATES    : [{string.Join(" | ", cmd.RequiredStates)}]");
        Console.WriteLine($"RESULTING STATE    : {(string.IsNullOrEmpty(cmd.ResultingExpectedState) ? "(none asserted)" : cmd.ResultingExpectedState)}");
        Console.WriteLine($"WRITES WORKBOOK    : {cmd.WritesWorkbook}");
        Console.WriteLine();

        var input = new LifecycleCommandInput(
            CommandId: commandId,
            NodeId: nodeId,
            ChangeId: changeId,
            Mode: mode,
            Parameters: parameters.Count > 0 ? parameters : null,
            ExpectedCurrentState: expectedState,
            Actor: actor,
            CorrelationId: null);

        var runner = new ScriptProcessRunner(cfg.Root);
        OperatorCommandResult result;
        try
        {
            result = OperatorCommandService.Execute(cfg, cmd, runner, input);
        }
        catch (Exception e)
        {
            Console.WriteLine("EXECUTION EXCEPTION : " + e.Message);
            return 3;
        }

        Console.WriteLine("==================== RESULT ====================");
        Console.WriteLine($"RESULT             : {result.Result}");
        Console.WriteLine($"PREVIOUS STATE     : {result.PreviousState}");
        Console.WriteLine($"NEW STATE          : {result.NewState}");
        Console.WriteLine($"NEXT ACTION        : {result.NextAllowedAction}");
        Console.WriteLine($"MESSAGE            : {result.Message}");
        Console.WriteLine($"MISMATCH           : {result.IsBackendStateMismatch}");
        Console.WriteLine($"RESULT CODE TOKEN  : {result.ResultCodeToken}");
        Console.WriteLine($"WORKBOOK MODIFIED  : {result.WorkbookModified}");
        Console.WriteLine($"NEXUS SRC MODIFIED : {result.NexusSourceModified}");
        Console.WriteLine($"GIT MODIFIED       : {result.GitModified}");
        Console.WriteLine($"EVIDENCE           : [{string.Join("; ", result.EvidenceReferences)}]");
        Console.WriteLine($"GENERATED          : [{string.Join("; ", result.GeneratedArtifacts)}]");
        Console.WriteLine();

        Console.WriteLine("==================== SCRIPT STDOUT ====================");
        Console.WriteLine(string.IsNullOrWhiteSpace(result.FullOutput) ? "(no output)" : result.FullOutput);
        Console.WriteLine("========================================================");

        Check(result.Result == CommandResultCode.SUCCESS, commandId,
            $"command should SUCCEED (got {result.Result}) — {result.Message}");
        Check(!result.IsBackendStateMismatch, commandId, "no backend-state mismatch");

        // ---- refreshed live state snapshot ----
        var after = StateReader.Read(cfg);
        Console.WriteLine();
        Console.WriteLine("==================== REFRESHED STATE ====================");
        Console.WriteLine($"task id            : {after.NodeId} / {after.ChangeId}");
        Console.WriteLine($"name               : {after.TaskName}");
        Console.WriteLine($"status             : {after.Status}");
        Console.WriteLine($"nextAllowedAction  : {after.NextAllowedAction}");
        Console.WriteLine($"trial mode         : {after.TrialMode}");
        Console.WriteLine($"preflight verdict  : {after.PreflightVerdict}");

        Console.WriteLine();
        Console.WriteLine($"ASSERT PASS        : {_pass}");
        Console.WriteLine($"ASSERT FAIL        : {_fail}");
        foreach (var f in Failures) Console.WriteLine($"  FAIL: {f}");
        return _fail == 0 ? 0 : 1;
    }

    private static void Check(bool ok, string id, string message)
    {
        if (ok) { _pass++; Console.WriteLine($"OK   {id}: {message}"); }
        else { _fail++; Failures.Add($"{id}: {message}"); Console.WriteLine($"FAIL {id}: {message}"); }
    }
}
