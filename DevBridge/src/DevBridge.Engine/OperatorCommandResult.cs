// OperatorCommandResult.cs — the command result model (DB-M12.1, Part 6).
// A command result is ALWAYS grounded in the refreshed backend state, never in the
// process exit code alone (Part 7: BACKEND_STATE_MISMATCH). Secret/sensitive prompt
// content is never stored in logs by the UI.
namespace DevBridge.Engine;

public enum CommandResultCode
{
    SUCCESS,                 // scripts ran and the expected lifecycle transition was reached
    FAILED,                  // a script exited nonzero / verification failed / state not reached
    BLOCKED,                 // command could not be attempted (bad state) or timed out
    CANCELLED,               // operator cancelled before execution
    MANUAL_ACTION_REQUIRED,  // no durable backend entry point; operator must act per guidance
}

public sealed class OperatorCommandResult
{
    public string CommandId { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public OperatorCommandKind Kind { get; init; } = OperatorCommandKind.Script;

    public DateTime StartedAtUtc { get; init; }
    public DateTime? CompletedAtUtc { get; init; }

    public int ExitCode { get; init; } = -1;
    public CommandResultCode Result { get; init; } = CommandResultCode.FAILED;

    /// <summary>Compact stdout summary (last lines of the combined script output).</summary>
    public string StdoutSummary { get; init; } = "";

    /// <summary>Full combined script output (shown in the expandable log, not the compact panel).</summary>
    public string FullOutput { get; init; } = "";

    /// <summary>Compact stderr / failure summary.</summary>
    public string ErrorSummary { get; init; } = "";

    /// <summary>Paths to artifacts the command generated (evidence the operator can open).</summary>
    public List<string> GeneratedArtifacts { get; init; } = new();

    public string PreviousState { get; init; } = "—";
    public string NewState { get; init; } = "—";
    public string NextAllowedAction { get; init; } = "—";

    /// <summary>Human-readable outcome, including the BACKEND_STATE_MISMATCH marker.</summary>
    public string Message { get; init; } = "";

    /// <summary>True when the command exited 0 but the expected lifecycle transition was NOT reached.</summary>
    public bool IsBackendStateMismatch { get; init; }

    public string StateValidationLabel => IsBackendStateMismatch ? "BACKEND_STATE_MISMATCH" : "";

    // ---- DB-M12.2 one-command-contract output fields ----
    /// <summary>The backend's own result token (DB0X_RESULT_CODE, else the outcome token).</summary>
    public string ResultCodeToken { get; init; } = "";

    /// <summary>Evidence artifacts the command produced (task reports + state evidence the backend declared).</summary>
    public List<string> EvidenceReferences { get; init; } = new();

    /// <summary>True when the command declared it modified the authoritative workbook (nullable = not declared).</summary>
    public bool? WorkbookModified { get; init; }

    /// <summary>True when the command declared it modified Nexus source (DevBridge never may; guarded).</summary>
    public bool? NexusSourceModified { get; init; }

    /// <summary>True when the command declared it modified a git repository (observed only; never by DevBridge).</summary>
    public bool? GitModified { get; init; }

    /// <summary>True when a human action is required for the governed lifecycle to proceed.</summary>
    public bool RequiresHumanAction { get; init; }

    /// <summary>Human action type token (e.g. HUMAN_GIT_PR_CREATE, HUMAN_GOVERNANCE_REVIEW).</summary>
    public string HumanActionType { get; init; } = "";

    /// <summary>Correlation id echoed from the command input (for traceability).</summary>
    public string CorrelationId { get; init; } = "";
}

public static class CommandResultText
{
    /// <summary>Trim a script output block to a compact summary (last N non-empty lines).</summary>
    public static string Compact(string output, int maxLines = 12)
    {
        if (string.IsNullOrWhiteSpace(output)) return "(no output)";
        var lines = output.Split('\n')
            .Select(l => l.TrimEnd('\r'))
            .Where(l => !string.IsNullOrWhiteSpace(l))
            .ToList();
        if (lines.Count <= maxLines) return string.Join("\n", lines);
        int start = lines.Count - maxLines;
        return string.Join("\n", lines.Skip(start));
    }
}
