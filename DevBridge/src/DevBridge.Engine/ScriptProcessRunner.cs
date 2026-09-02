// ScriptProcessRunner.cs — invokes an EXISTING governed backend PowerShell script
// safely (DB-M12.1, Part 4). Reuses the DB-M12 ScriptRunner approach:
//   * powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<explicit path>"
//   * explicit script path, never an untrusted constructed command line
//   * stdout and stderr captured separately
//   * exit code captured, timeout enforced (process killed)
// The UI never duplicates backend business logic — it only launches the canonical
// script and reports what happened. Environment overrides are honored only when an
// explicit allow-list is passed (used by self-tests to redirect writes away from
// the authoritative workbook).
using System.Diagnostics;
using System.Text;

namespace DevBridge.Engine;

public sealed record ScriptRunOutcome(
    bool Succeeded,
    int ExitCode,
    string Stdout,
    string Stderr,
    TimeSpan Elapsed,
    bool TimedOut)
{
    public string Combined => (Stdout + "\n" + Stderr).Trim();
    public static ScriptRunOutcome Timeout(int timeoutMs) => new(false, -1, "", "", TimeSpan.Zero, true);
    public static ScriptRunOutcome Missing(string path) => new(false, 1, $"Script not found: {path}", "", TimeSpan.Zero, false);
    public static ScriptRunOutcome Failed(string error) => new(false, -1, "", error, TimeSpan.Zero, false);
}

public interface IScriptProcessRunner
{
    ScriptRunOutcome Run(string scriptPath, int timeoutMs, IReadOnlyDictionary<string, string>? environment = null);
}

/// <summary>Real PowerShell runner. Parameterized ProcessStartInfo — no shell string
/// is ever assembled from untrusted input, so there is no injection surface.</summary>
public sealed class ScriptProcessRunner : IScriptProcessRunner
{
    private readonly string _workingDirectory;

    public ScriptProcessRunner(string workingDirectory) => _workingDirectory = workingDirectory;

    public ScriptRunOutcome Run(string scriptPath, int timeoutMs, IReadOnlyDictionary<string, string>? environment = null)
    {
        if (!File.Exists(scriptPath)) return ScriptRunOutcome.Missing(scriptPath);

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\"",
            WorkingDirectory = _workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        if (environment is not null)
        {
            foreach (var (k, v) in environment)
                psi.Environment[k] = v;
        }

        try
        {
            using var p = new Process { StartInfo = psi };
            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            var sw = Stopwatch.StartNew();
            p.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            if (!p.WaitForExit(timeoutMs))
            {
                try { p.Kill(); } catch { /* already gone */ }
                return ScriptRunOutcome.Timeout(timeoutMs);
            }
            p.WaitForExit(); // flush async handlers
            sw.Stop();
            return new ScriptRunOutcome(p.ExitCode == 0, p.ExitCode, stdout.ToString(), stderr.ToString(), sw.Elapsed, false);
        }
        catch (Exception e)
        {
            return ScriptRunOutcome.Failed(e.Message);
        }
    }
}
