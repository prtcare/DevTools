// DevBridgeMode.cs — explicit TRIAL vs REAL_NEXUS_DEVELOPMENT distinction
// (DB-GH01). Nexus Forge is permanent development-plane infrastructure, not
// temporary scaffolding; a trial cycle is disposable evidence and never
// produces a real PR/merge. The mode is an explicit field, never inferred
// from the file path.
//
// Source of truth precedence (lowest -> highest):
//   1. config/devbridge.json  "mode"        (default TRIAL — safe default)
//   2. state/current-task.json "mode"        (per-cycle override)
// Neither value is ever inferred. An unknown string keeps the safe default.
using System;

namespace DevBridge.Engine;

public enum DevBridgeOperatingMode
{
    Trial,
    RealNexusDevelopment,
}

public static class DevBridgeMode
{
    public const string TrialToken = "TRIAL";
    public const string RealToken = "REAL_NEXUS_DEVELOPMENT";

    public const string TrialStopAction = "TRIAL_CYCLE_SAFE_STOP";

    /// <summary>Parse an explicit mode token. Unknown/blank => Trial (safe default).</summary>
    public static DevBridgeOperatingMode FromString(string? token)
    {
        if (string.Equals(token, RealToken, StringComparison.OrdinalIgnoreCase)) return DevBridgeOperatingMode.RealNexusDevelopment;
        return DevBridgeOperatingMode.Trial;
    }

    public static string ToToken(DevBridgeOperatingMode mode)
        => mode == DevBridgeOperatingMode.RealNexusDevelopment ? RealToken : TrialToken;

    public static bool IsTrial(DevBridgeOperatingMode mode) => mode == DevBridgeOperatingMode.Trial;
}
