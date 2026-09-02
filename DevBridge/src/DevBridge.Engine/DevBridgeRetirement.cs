// DevBridgeRetirement.cs — DevBridge's own lifecycle (DB-GH01). DevBridge is
// TEMPORARY external scaffolding for Nexus Phase 1/2 only. Nothing implemented
// here may become Nexus runtime/architecture/contracts/services/libraries/
// infrastructure/dependency, and it will be retired. The retirement state is
// represented explicitly; retirement must NOT require a Nexus runtime migration.
using System;

namespace DevBridge.Engine;

public enum DevBridgeRetirementState
{
    ActiveTemporaryBridge,
    ReadyForRealNexusSupport,
    RetirementEligible,
    Retired,
}

public static class DevBridgeRetirement
{
    public static DevBridgeRetirementState FromString(string? token) => token?.Trim().ToUpperInvariant() switch
    {
        "READY_FOR_REAL_NEXUS_SUPPORT" => DevBridgeRetirementState.ReadyForRealNexusSupport,
        "RETIREMENT_ELIGIBLE" => DevBridgeRetirementState.RetirementEligible,
        "RETIRED" => DevBridgeRetirementState.Retired,
        _ => DevBridgeRetirementState.ActiveTemporaryBridge,
    };

    public static string ToToken(DevBridgeRetirementState state) => state switch
    {
        DevBridgeRetirementState.ReadyForRealNexusSupport => "READY_FOR_REAL_NEXUS_SUPPORT",
        DevBridgeRetirementState.RetirementEligible => "RETIREMENT_ELIGIBLE",
        DevBridgeRetirementState.Retired => "RETIRED",
        _ => "ACTIVE_TEMPORARY_BRIDGE",
    };

    public static string Description(DevBridgeRetirementState state) => state switch
    {
        DevBridgeRetirementState.ReadyForRealNexusSupport => "DevBridge has real Nexus support; no further DevBridge work is scaffolded.",
        DevBridgeRetirementState.RetirementEligible => "DevBridge is no longer needed. Retirement requires no Nexus runtime migration.",
        DevBridgeRetirementState.Retired => "DevBridge retired.",
        _ => "DevBridge is an active temporary bridge for Nexus Phase 1/2 only.",
    };
}
