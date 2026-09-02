// LifecycleCommandInput.cs — the DB-M12.2 one-command input contract.
//
// Every governed backend command is invoked with the same input shape:
//   CommandId, NodeId, ChangeId, Mode, Parameters, ExpectedCurrentState, Actor,
//   CorrelationId.
//
// Validation is deliberate and conservative:
//   * a command that declares RequiresTaskIdentity must be given the CURRENT
//     task's identity (NodeId + ChangeId) — a command addressed at a different
//     task is rejected rather than misapplied;
//   * Mode, when supplied, must EXACTLY equal the mode already derived from
//     state/config/trial-evidence. A mode switch is never performed implicitly
//     and a mismatch is rejected (TRIAL vs REAL_NEXUS_DEVELOPMENT are never
//     interchangeable at command time);
//   * Actor must be a human operator identity (DevBridge never acts on behalf
//     of a non-human principal).
namespace DevBridge.Engine;

public sealed record LifecycleCommandInput(
    string? CommandId,
    string? NodeId,
    string? ChangeId,
    string? Mode,
    IReadOnlyDictionary<string, string>? Parameters,
    string? ExpectedCurrentState,
    string? Actor,
    string? CorrelationId);

public static class LifecycleCommandInputValidation
{
    /// <summary>Validate a command input against the command and the live state.</summary>
    public static (bool Ok, string? Error) Validate(LifecycleCommandInput? input, OperatorCommand cmd, DevBridgeState current)
    {
        if (input is null) return (true, null);

        if (!string.IsNullOrWhiteSpace(input.CommandId)
            && !string.Equals(input.CommandId, cmd.CommandId, StringComparison.OrdinalIgnoreCase))
        {
            return (false, $"CommandId mismatch — input '{input.CommandId}' does not match command '{cmd.CommandId}'.");
        }

        if (cmd.RequiresTaskIdentity)
        {
            if (string.IsNullOrWhiteSpace(input.NodeId))
                return (false, "NodeId is required for this command.");
            if (string.IsNullOrWhiteSpace(input.ChangeId))
                return (false, "ChangeId is required for this command.");
            if (!string.IsNullOrWhiteSpace(current.NodeId) && !string.Equals(input.NodeId, current.NodeId, StringComparison.Ordinal))
                return (false, $"NodeId '{input.NodeId}' does not match the current task '{current.NodeId}'.");
            if (!string.IsNullOrWhiteSpace(current.ChangeId) && !string.Equals(input.ChangeId, current.ChangeId, StringComparison.Ordinal))
                return (false, $"ChangeId '{input.ChangeId}' does not match the current change '{current.ChangeId}'.");
        }

        if (!string.IsNullOrWhiteSpace(input.Mode))
        {
            string token = input.Mode.Trim();
            bool valid = string.Equals(token, DevBridgeMode.TrialToken, StringComparison.OrdinalIgnoreCase)
                         || string.Equals(token, DevBridgeMode.RealToken, StringComparison.OrdinalIgnoreCase);
            if (!valid)
                return (false, $"Invalid Mode '{token}'. Only {DevBridgeMode.TrialToken} or {DevBridgeMode.RealToken} are valid.");
            DevBridgeOperatingMode requested = DevBridgeMode.FromString(token);
            if (current.Mode != requested)
                return (false, $"Mode '{token}' does not match the derived mode '{DevBridgeMode.ToToken(current.Mode)}'. "
                             + "Mode switches are never implicit and cannot be performed by a lifecycle command.");
        }

        if (!string.IsNullOrWhiteSpace(input.Actor) && input.Actor.Trim().Length < 2)
            return (false, "Actor must be a human operator identity (2+ characters).");

        return (true, null);
    }
}
