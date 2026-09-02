// GitLifecycle.cs — DevBridge's Git view (DB-GH01). Git is a FORMAL
// HUMAN-GATED lifecycle. DevBridge may inspect git, capture baselines, prepare
// commit/PR guidance, and observe PR/merge state. It must NEVER approve its own
// PR, merge automatically, infer a merge, or bypass a pending human gate.
//
// HumanGitGateState is the observable lifecycle position. Merged is the point
// at which a REAL governed completion may be considered — never before, and
// never inferred from a dirty/clean working tree.
using System;

namespace DevBridge.Engine;

/// <summary>Observed git facts — read-only observation, never a mutation.</summary>
public sealed record ObservedGitState(
    bool IsGitRepo,
    string? Branch,
    string? HeadCommit,
    bool Dirty,
    string MergeState,   // "UNMERGED" | "MERGED" | "PR_OPEN" | observed text; never authored
    string? CapturedAtUtc);

public enum HumanGitGateState
{
    NotApplicable,          // trial / pre-git lifecycle
    ImplementationComplete, // after the governed implementation
    VerificationPassed,     // after DB-M06
    ClaudeReviewPassed,     // after Claude review (real mode only)
    AwaitingHumanPr,        // human must create the PR
    PrOpen,                 // PR exists, human-owned
    AwaitingHumanReview,    // human review in progress
    AwaitingHumanMerge,     // review done; human must merge
    Merged,                 // merge confirmed (must be observed, never inferred)
    ReadyForGovernedCompletion,
}

public static class GitLifecycle
{
    /// <summary>Human gate stages that require the OPERATOR, never DevBridge.</summary>
    public static bool RequiresHumanGate(HumanGitGateState state) => state switch
    {
        HumanGitGateState.AwaitingHumanPr
            or HumanGitGateState.PrOpen
            or HumanGitGateState.AwaitingHumanReview
            or HumanGitGateState.AwaitingHumanMerge
            or HumanGitGateState.Merged => true,
        _ => false,
    };

    /// <summary>
    /// A REAL governed completion may proceed only once the merge is CONFIRMED.
    /// A dirty work tree, a closed PR, or "merge looks done" is never sufficient.
    /// </summary>
    public static bool MergeConfirmed(HumanGitGateState state)
        => state == HumanGitGateState.Merged || state == HumanGitGateState.ReadyForGovernedCompletion;

    public static string ToToken(HumanGitGateState state) => state switch
    {
        HumanGitGateState.ImplementationComplete => "IMPLEMENTATION_COMPLETE",
        HumanGitGateState.VerificationPassed => "VERIFICATION_PASSED",
        HumanGitGateState.ClaudeReviewPassed => "CLAUDE_REVIEW_PASSED",
        HumanGitGateState.AwaitingHumanPr => "AWAITING_HUMAN_PR",
        HumanGitGateState.PrOpen => "PR_OPEN",
        HumanGitGateState.AwaitingHumanReview => "AWAITING_HUMAN_REVIEW",
        HumanGitGateState.AwaitingHumanMerge => "AWAITING_HUMAN_MERGE",
        HumanGitGateState.Merged => "MERGED",
        HumanGitGateState.ReadyForGovernedCompletion => "READY_FOR_GOVERNED_COMPLETION",
        _ => "NOT_APPLICABLE",
    };

    public static HumanGitGateState FromString(string? token) => token?.Trim().ToUpperInvariant() switch
    {
        "IMPLEMENTATION_COMPLETE" => HumanGitGateState.ImplementationComplete,
        "VERIFICATION_PASSED" => HumanGitGateState.VerificationPassed,
        "CLAUDE_REVIEW_PASSED" => HumanGitGateState.ClaudeReviewPassed,
        "CLAUDE_REVIEW_PASSED_REAL" => HumanGitGateState.ClaudeReviewPassed,
        "AWAITING_HUMAN_PR" => HumanGitGateState.AwaitingHumanPr,
        "PR_OPEN" => HumanGitGateState.PrOpen,
        "AWAITING_HUMAN_REVIEW" => HumanGitGateState.AwaitingHumanReview,
        "AWAITING_HUMAN_MERGE" => HumanGitGateState.AwaitingHumanMerge,
        "MERGED" => HumanGitGateState.Merged,
        "READY_FOR_GOVERNED_COMPLETION" => HumanGitGateState.ReadyForGovernedCompletion,
        _ => HumanGitGateState.NotApplicable,
    };

    /// <summary>Human guidance shown by the UI — always TELL, never pretend.</summary>
    public static string HumanGuidance(HumanGitGateState state) => state switch
    {
        HumanGitGateState.AwaitingHumanPr => "Create the PR and have a human review it. DevBridge does not create PRs.",
        HumanGitGateState.PrOpen => "A PR is open. A human must review it before any merge.",
        HumanGitGateState.AwaitingHumanReview => "Human review in progress. DevBridge never approves its own PR.",
        HumanGitGateState.AwaitingHumanMerge => "Review done. A HUMAN must merge; DevBridge never merges automatically.",
        HumanGitGateState.Merged => "Merge confirmed. DevBridge may now prepare governed completion guidance.",
        _ => "",
    };
}
