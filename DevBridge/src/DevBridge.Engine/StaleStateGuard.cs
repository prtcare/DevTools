// StaleStateGuard.cs — DB-M12.2 stale-governance-state protection.
//
// A command invoked with an ExpectedCurrentState must only run when the LIVE
// lifecycle status matches it. If the operator acted on stale information (the
// task moved on, or was never at the position the caller believed), running the
// command would apply governed writes against an unknown lifecycle position.
// The guard rejects with STALE_GOVERNANCE_STATE instead.
namespace DevBridge.Engine;

public static class StaleStateGuard
{
    public static (bool Ok, string? Rejection) Check(string? expectedCurrentState, string currentStatus)
    {
        if (string.IsNullOrWhiteSpace(expectedCurrentState)) return (true, null);
        string norm = expectedCurrentState.Trim();
        if (string.Equals(norm, currentStatus, StringComparison.Ordinal)) return (true, null);
        return (false, $"STALE_GOVERNANCE_STATE — command expected current state '{norm}' but the live lifecycle state is '{currentStatus}'. "
                     + "Refresh the state and re-issue the command with the current ExpectedCurrentState.");
    }
}
