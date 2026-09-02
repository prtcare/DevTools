// ScriptRunner.cs — UI facade over the DB-M12.1 Engine script runner.
// The process-invocation approach (DB-M12.1, Part 4) lives in
// DevBridge.Engine.ScriptProcessRunner: powershell.exe -NoProfile -ExecutionPolicy
// Bypass -File "<explicit script path>", stdout/stderr captured separately, exit
// code captured, timeout enforced, no untrusted shell-string construction. The UI
// never duplicates backend business logic — it only launches the canonical script.
using System.IO;
using DevBridge.Engine;

namespace DevBridge.UI.Services;

public sealed record ScriptRunResult(bool Succeeded, int ExitCode, string Output, TimeSpan Elapsed);

public static class ScriptRunner
{
    /// <summary>Run one backend PowerShell script under the DevBridge root.</summary>
    public static ScriptRunResult Run(DevBridgeConfig cfg, string scriptName, int timeoutMs = 600000)
    {
        string scriptPath = Path.Combine(cfg.ScriptsDir, scriptName);
        var outcome = new ScriptProcessRunner(cfg.Root).Run(scriptPath, timeoutMs);
        return new ScriptRunResult(outcome.Succeeded, outcome.ExitCode, outcome.Combined, outcome.Elapsed);
    }
}
