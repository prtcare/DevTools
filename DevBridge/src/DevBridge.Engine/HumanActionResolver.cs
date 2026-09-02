// HumanActionResolver.cs — DB-M12.3 HUMAN ACTION PANEL source.
//
// The mission requires the operator console to surface, from backend state, the
// currently-pending human action with: Action Type, Reason, Instructions,
// Evidence. This resolver derives that single action from the DevBridgeState
// snapshot — it never invents an action, never proposes an automatic run, and
// never enables DevBridge to perform the action. Guided/manual commands
// (CREATE_PR, REVIEW_PR, MERGE_PR, REVIEW_GOVERNANCE_ISSUE,
// RESTORE_REAL_NEXUS_BASELINE) are exactly the keep-list the mission declares
// genuinely human/external.
using System;

namespace DevBridge.Engine;

/// <summary>The currently-pending human action, or null when none is pending.</summary>
public sealed record HumanActionInfo(
    string? CommandId,
    string ActionType,
    string Reason,
    string Instructions,
    string Evidence);

public static class HumanActionResolver
{
    /// <summary>Derive the pending human action from backend state (null = none).</summary>
    public static HumanActionInfo? Resolve(DevBridgeState s)
    {
        if (s.Status == "GOVERNANCE_ISSUE")
        {
            return new HumanActionInfo(
                "REVIEW_GOVERNANCE_ISSUE",
                "HUMAN_GOVERNANCE_DECISION",
                "A Claude review raised a governance issue.",
                "Review the governance issue and decide how to proceed. DevBridge never hides or auto-resolves governance issues.",
                Evidence(s));
        }

        if (s.Status == "HUMAN_DECISION_REQUIRED")
        {
            return new HumanActionInfo(
                null,
                "HUMAN_DECISION",
                "A Claude review requested a human decision.",
                "Provide the required human decision. The cycle pauses until the operator decides.",
                Evidence(s));
        }

        // Real-mode human Git gates (DB-GH01): human-controlled, never DevBridge.
        if (!s.TrialMode)
        {
            switch (s.HumanGitState)
            {
                case HumanGitGateState.AwaitingHumanPr:
                case HumanGitGateState.ClaudeReviewPassed:
                    return new HumanActionInfo(
                        "CREATE_PR",
                        "HUMAN_GIT_PR_CREATE",
                        "Claude review passed in REAL mode.",
                        "Create the PR and request human review. DevBridge never creates or approves PRs.",
                        Evidence(s));
                case HumanGitGateState.PrOpen:
                case HumanGitGateState.AwaitingHumanReview:
                    return new HumanActionInfo(
                        "REVIEW_PR",
                        "HUMAN_GIT_PR_REVIEW",
                        "A PR is open and awaiting human review.",
                        "Review the PR. DevBridge never approves its own PR.",
                        Evidence(s));
                case HumanGitGateState.AwaitingHumanMerge:
                    return new HumanActionInfo(
                        "MERGE_PR",
                        "HUMAN_GIT_PR_MERGE",
                        "Human review is complete.",
                        "A HUMAN must merge the PR. DevBridge never merges automatically and never infers a merge.",
                        Evidence(s));
            }
        }

        // Pre-DevBridge baseline: display-only advisory at the real restart point.
        // Restoration is a later, human-governed decision — there is no restore code.
        if (!s.TrialMode && s.HumanGitState is HumanGitGateState.Merged or HumanGitGateState.ReadyForGovernedCompletion
            && s.PreDevBridgeBaseline.Present)
        {
            string wb = s.PreDevBridgeBaseline.Workbook?.Path ?? "(workbook path not captured)";
            string repo = s.PreDevBridgeBaseline.Git?.Repository ?? "(repository not captured)";
            return new HumanActionInfo(
                "RESTORE_REAL_NEXUS_BASELINE",
                "RESTORE_REAL_NEXUS_BASELINE",
                "A real Nexus restart point is captured.",
                $"Restoring the real Nexus baseline (workbook {wb} and {repo}) is a HUMAN action. "
                + "DevBridge only represents the captured baseline; it never resets git, cleans files, "
                + "overwrites the workbook, or deletes trial source automatically.",
                $"baseline captured {s.PreDevBridgeBaseline.Workbook?.CapturedAtUtc ?? s.PreDevBridgeBaseline.Git?.CapturedAtUtc ?? "(unknown)"}");
        }

        return null;
    }

    private static string Evidence(DevBridgeState s)
    {
        var bits = new System.Collections.Generic.List<string>();
        if (!string.IsNullOrWhiteSpace(s.TaskName)) bits.Add(s.TaskName!);
        if (!string.IsNullOrWhiteSpace(s.ChangeId)) bits.Add(s.ChangeId!);
        if (s.ClaudeDecision is not null) bits.Add($"decision={s.ClaudeDecision}");
        if (s.ClaudeReviewedAtUtc is not null) bits.Add($"reviewedAt={s.ClaudeReviewedAtUtc}");
        if (s.Artifacts.ReviewPacket) bits.Add("tasks/REVIEW_PACKET.md");
        return bits.Count == 0 ? "(no task evidence)" : string.Join(" / ", bits);
    }
}
