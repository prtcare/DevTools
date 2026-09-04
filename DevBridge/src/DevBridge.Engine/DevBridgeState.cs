// DevBridgeState.cs — a null-safe snapshot of the live DevBridge control state.
// Built from state/current-task.json plus the evidence artifacts in tasks/.
// Everything the next-action engine needs is captured here so the engine stays
// pure and fully testable with fixtures.
using System.Text.Json;

namespace DevBridge.Engine;

public sealed record ArtifactPresence(
    bool NextTask, bool PreflightReport, bool StartBaseline, bool ChatGptHandoff,
    bool DeepSeekPrompt, bool DeepSeekPromptHasImplementation, bool VerificationReport,
    bool ReviewPacket, bool ClaudeReviewPrompt, bool ClaudeReviewResult,
    bool FixContext, bool SheetUpdatePlan, bool CompletionReport, bool WorkbookConsistencyReport);

public sealed class DevBridgeState
{
    // ---- identity (from current-task.json, may be null pre-preflight) ----
    public string? NodeId { get; init; }
    public string? TaskName { get; init; }
    public string? ChangeId { get; init; }
    public string? ActivityId { get; init; }
    public string? Phase { get; init; }
    public string? Layer { get; init; }
    public string? ParentNodeId { get; init; }
    public string? FeatureNodeId { get; init; }

    // ---- state machine (authoritative explicit fields) ----
    public string? Status { get; init; }
    public string? NextAllowedAction { get; init; }
    public string? PreflightVerdict { get; init; }
    public bool TaskStateFilePresent { get; init; }

    // ---- derived evidence ----
    public ArtifactPresence Artifacts { get; init; } = new(false, false, false, false, false, false, false, false, false, false, false, false, false, false);
    public string? VerificationPrimaryResult { get; init; }
    public string? ClaudeDecision { get; init; }
    public bool ClaudeFixRequired { get; init; }
    public bool CompletionWritten { get; init; }
    public string? CompletionNodeId { get; init; }
    public string? CompletionChangeId { get; init; }
    public string? ConsistencyResult { get; init; }
    public string? SelectedAtDisplay { get; init; }

    // ---- failure / observation surfaces ----
    public string? PreflightBlockingReasons { get; init; }
    public string? VerificationFailureDetail { get; init; }
    public string? ClaudeFixDetail { get; init; }
    public string? ConsistencyFailureDetail { get; init; }
    public List<ResidualObservation> ResidualObservations { get; init; } = new();

    // ---- evidence timestamps (display only) ----
    public string? VerifiedAtUtc { get; init; }
    public string? ClaudeReviewedAtUtc { get; init; }
    public string? CompletionWrittenAtUtc { get; init; }
    public string? ConsistencyValidatedAtUtc { get; init; }

    // ---- current task detail numbers (from preserved evidence, display only) ----
    public int? BuildProjects { get; init; }
    public int? BuildWarnings { get; init; }
    public int? BuildErrors { get; init; }
    public int? TestsPassed { get; init; }
    public int? TestsFailed { get; init; }
    public int? TestsTotal { get; init; }
    public int? HarnessChecks { get; init; }

    // ---- navigation ----
    public string? CurrentTaskJsonPath { get; init; }
    public string? CurrentTaskHistoryDir { get; init; }

    // ---- DB-GH01 governance surface ----
    public DevBridgeOperatingMode Mode { get; init; } = DevBridgeOperatingMode.Trial;
    public string? ModeToken { get; init; }                       // explicit token (TRIAL | REAL_NEXUS_DEVELOPMENT)
    public bool TrialMode => Mode == DevBridgeOperatingMode.Trial;
    public ObservedGitState? GitObserved { get; init; }
    public HumanGitGateState HumanGitState { get; init; } = HumanGitGateState.NotApplicable;
    public string? GitHumanGuidance { get; init; }
    public DevBridgeRetirementState Retirement { get; init; } = DevBridgeRetirementState.ActiveTemporaryBridge;
    public PreDevBridgeBaselineState PreDevBridgeBaseline { get; init; } = PreDevBridgeBaselineState.Empty;
    public ChatGptHandoffValidationResult? HandoffValidation { get; init; }
    public bool HandoffReady => HandoffValidation?.IsReady ?? false;
    public ClaudeReviewPackageValidationResult? ReviewPackageValidation { get; init; }

    // ---- DB-M07 Claude Review Manifest (new review model: Claude reads the ACTUAL
    // Nexus files). True only when current-task dbM07 carries a ready stamp for THIS
    // node/change AND the manifest file exists — a legacy/stale REVIEW_PACKET.md from
    // a previous cycle is never treated as the current manifest. ----
    public bool ClaudeReviewManifestReady { get; init; }
    public string? ClaudeReviewManifestId { get; init; }
    public M10CompletionEligibilityResult? M10Eligibility { get; init; }
    public RoadmapGuardVerdict? RoadmapGuard { get; init; }       // before/after protected fingerprint
    public M11ReviewRecommendation? M11Recommendation { get; init; }
    public bool TrialCycleSafeStop => Status == "CLAUDE_REVIEW_PASSED_TRIAL" || NextAllowedAction == "TRIAL_CYCLE_SAFE_STOP";
    public bool TrialCycleClosed => Status == "TRIAL_CYCLE_CLOSED";
}

public sealed record ResidualObservation(string Severity, bool Blocking, string Subject, string Detail);

public static class StateJson
{
    /// <summary>Read a JSON file tolerantly. Returns null when missing or malformed.</summary>
    public static JsonElement? TryRead(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            return doc.RootElement.Clone();
        }
        catch (JsonException) { return null; }
    }

    public static string? Str(JsonElement? root, string key)
    {
        if (root is null || !root.Value.TryGetProperty(key, out var el)) return null;
        return el.ValueKind switch
        {
            JsonValueKind.String => el.GetString(),
            JsonValueKind.True => "True",
            JsonValueKind.False => "False",
            JsonValueKind.Number => el.GetRawText(),
            _ => null, // null / object / array carry no scalar display value here
        };
    }
}
