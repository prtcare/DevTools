using System.Diagnostics;

namespace DevBridge.Workspace;

/// <summary>Result of running git.exe.</summary>
internal sealed record GitOutcome(int ExitCode, string StdOut, string StdErr, bool Started);

/// <summary>
/// Thin, injection-free wrapper around the local <c>git.exe</c> on PATH.
/// Every invocation uses <c>git -C &lt;directory&gt; ...</c> and passes each argument
/// through <see cref="ProcessStartInfo.ArgumentList"/> so no user-controlled branch or
/// path string is ever shell-interpolated. This tool only ever talks to the local git
/// binary and the local file system.
/// </summary>
internal static class GitRunner
{
    public static GitOutcome Run(string workingDirectory, string[] arguments, int timeoutMs = 60_000)
    {
        try
        {
            var psi = new ProcessStartInfo("git")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };

            psi.ArgumentList.Add("-C");
            psi.ArgumentList.Add(workingDirectory);
            foreach (string arg in arguments)
            {
                psi.ArgumentList.Add(arg);
            }

            using var process = new Process { StartInfo = psi };
            if (!process.Start())
            {
                return new GitOutcome(-1, string.Empty, "git.exe failed to start.", Started: false);
            }

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();

            if (!process.WaitForExit(timeoutMs))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException)
                {
                    // process already exited — nothing to kill
                }

                return new GitOutcome(-1, string.Empty, $"git timed out after {timeoutMs} ms.", Started: true);
            }

            string stdout = stdoutTask.GetAwaiter().GetResult();
            string stderr = stderrTask.GetAwaiter().GetResult();
            return new GitOutcome(process.ExitCode, stdout, stderr, Started: true);
        }
        catch (Exception ex)
        {
            return new GitOutcome(-1, string.Empty, ex.Message, Started: false);
        }
    }
}
