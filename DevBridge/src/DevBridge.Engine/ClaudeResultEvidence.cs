// ClaudeResultEvidence.cs — safe evidence entry for RECORD CLAUDE RESULT (DB-M08).
//
// DB-M08 has no durable backend command entry point (no script writes
// claude-review.json), so the operator records the verdict via a guided UI
// interaction. This helper writes the two evidence files the ENGINE already reads
// (StateReader): tasks/CLAUDE_REVIEW_RESULT.md and state/claude-review.json.
//
// The decision vocabulary is the DB-GH01 four-decision set
// PASS / FIX / GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED. Routing is mode-aware:
// trial PASS routes to TRIAL_CYCLE_SAFE_STOP; real PASS routes to the human Git
// gate (never straight to M10). This type records evidence and the route; it does
// NOT interpret review semantics and never performs the governed write itself.
using System.Text.Json;

namespace DevBridge.Engine;

public sealed record ClaudeResultEntry(
    ClaudeReviewDecision Decision,
    string ReviewText,         // exact original review text (preserved verbatim)
    string? NodeId,
    string? ChangeId,
    string? TaskName,
    bool TrialMode = false)
{
    public string DecisionToken => ClaudeReviewDecisions.ToToken(Decision);
    public bool Pass => Decision == ClaudeReviewDecision.Pass;
    public bool DbM09Required => Decision == ClaudeReviewDecision.Fix;
    public ClaudeReviewRoute Route => ClaudeReviewDecisions.Route(Decision, TrialMode);
}

public static class ClaudeResultEvidence
{
    public const string ResultMarkdownFile = "CLAUDE_REVIEW_RESULT.md";
    public const string StateJsonFile = "claude-review.json";

    public static (bool Ok, string Message) Record(DevBridgeConfig cfg, ClaudeResultEntry entry)
    {
        string nodeId = string.IsNullOrWhiteSpace(entry.NodeId) ? "UNKNOWN" : entry.NodeId;
        string changeId = string.IsNullOrWhiteSpace(entry.ChangeId) ? "" : entry.ChangeId;
        string text = string.IsNullOrWhiteSpace(entry.ReviewText) ? entry.DecisionToken : entry.ReviewText.Trim();
        string nowUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");

        // ---- tasks/CLAUDE_REVIEW_RESULT.md : exact review text preserved ----
        var md = new System.Text.StringBuilder();
        md.AppendLine(entry.DecisionToken);
        md.AppendLine();
        if (entry.Decision == ClaudeReviewDecision.Fix) md.AppendLine("CLAUDE_FIX_REQUIRED").AppendLine();
        md.AppendLine(text);
        string mdPath = Path.Combine(cfg.TasksDir, ResultMarkdownFile);
        File.WriteAllText(mdPath, md.ToString());

        // ---- state/claude-review.json : engine-readable record, text preserved ----
        var json = new Dictionary<string, object?>
        {
            ["milestone"] = "DB-M08",
            ["nodeId"] = nodeId,
            ["changeId"] = changeId,
            ["name"] = string.IsNullOrWhiteSpace(entry.TaskName) ? null : entry.TaskName,
            ["decision"] = entry.DecisionToken,
            ["dbM09Required"] = entry.DbM09Required,
            ["trialMode"] = entry.TrialMode,
            ["routeLifecycleState"] = entry.Route.LifecycleState,
            ["routeNextAllowedAction"] = entry.Route.NextAllowedAction,
            ["reviewedAt"] = nowUtc,
            ["recordedVia"] = "DevBridge UI evidence-entry dialog (DB-M08 has no backend command entry point)",
            ["reviewText"] = text,   // exact original review text preserved, never interpreted
        };
        string jsonPath = Path.Combine(cfg.StateDir, StateJsonFile);
        File.WriteAllText(jsonPath, JsonSerializer.Serialize(json, new JsonSerializerOptions { WriteIndented = true }));

        return (true, $"Recorded Claude {entry.DecisionToken} evidence ({text.Length} chars preserved). "
            + $"Route: {entry.Route.LifecycleState} / {entry.Route.NextAllowedAction}.");
    }
}
