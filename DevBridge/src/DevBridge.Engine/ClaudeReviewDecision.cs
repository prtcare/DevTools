// ClaudeReviewDecision.cs — DB-M08 decision vocabulary (DB-GH01). The review
// verdict is one of four: PASS, FIX, GOVERNANCE_ISSUE, HUMAN_DECISION_REQUIRED.
// Routing is mode-aware:
//   * TRIAL  + PASS -> CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP.
//     M10 is NOT run for a trial; the cycle stops safely.
//   * REAL   + PASS -> Claude review is passed, but completion does NOT follow.
//     The human Git gate comes next (AWAITING_HUMAN_PR ... MERGED), and only a
//     CONFIRMED merge unlocks governed completion. Claude PASS never means
//     merged or production-complete.
//   * FIX / GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED route to their governed
//     stops and never arm completion.
using System;

namespace DevBridge.Engine;

public enum ClaudeReviewDecision
{
    Pass,
    Fix,
    GovernanceIssue,
    HumanDecisionRequired,
}

public sealed record ClaudeReviewRoute(
    ClaudeReviewDecision Decision,
    bool TrialMode,
    string LifecycleState,     // lifecycle state token to write
    string NextAllowedAction,  // next allowed action token to write
    string Instruction);

public static class ClaudeReviewDecisions
{
    public static ClaudeReviewDecision FromString(string? token) => token?.Trim().ToUpperInvariant() switch
    {
        "PASS" => ClaudeReviewDecision.Pass,
        "FIX" => ClaudeReviewDecision.Fix,
        "GOVERNANCE_ISSUE" => ClaudeReviewDecision.GovernanceIssue,
        "HUMAN_DECISION_REQUIRED" => ClaudeReviewDecision.HumanDecisionRequired,
        _ => ClaudeReviewDecision.Fix, // unknown decisions are treated as requiring correction
    };

    public static string ToToken(ClaudeReviewDecision decision) => decision switch
    {
        ClaudeReviewDecision.Pass => "PASS",
        ClaudeReviewDecision.Fix => "FIX",
        ClaudeReviewDecision.GovernanceIssue => "GOVERNANCE_ISSUE",
        _ => "HUMAN_DECISION_REQUIRED",
    };

    /// <summary>Mode-aware routing. This is the ONLY place trial/real routing is decided.</summary>
    public static ClaudeReviewRoute Route(ClaudeReviewDecision decision, bool trialMode) => decision switch
    {
        ClaudeReviewDecision.Pass when trialMode =>
            new ClaudeReviewRoute(decision, true, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP",
                "Trial PASS accepted. This is disposable trial evidence; stop the cycle at TRIAL_CYCLE_SAFE_STOP. M10 is NOT run for a trial."),
        ClaudeReviewDecision.Pass =>
            new ClaudeReviewRoute(decision, false, "CLAUDE_REVIEW_PASSED_REAL", "AWAITING_HUMAN_PR",
                "Claude PASS accepted. The human Git gate comes next — a human creates and reviews the PR. DevBridge never approves its own PR."),
        ClaudeReviewDecision.Fix =>
            new ClaudeReviewRoute(decision, trialMode, "DB_M09_FIX_REQUIRED", "CORRECT_CURRENT_ATTEMPT",
                "Claude found a fixable defect. Correct the current attempt (CORRECT_CURRENT_ATTEMPT); do not rewrite acceptance criteria or roadmap."),
        ClaudeReviewDecision.GovernanceIssue =>
            new ClaudeReviewRoute(decision, trialMode, "GOVERNANCE_ISSUE", "REVIEW_GOVERNANCE_ISSUE",
                "Claude found a governance issue. The operator must review the governance issue; DevBridge never hides or auto-resolves it."),
        _ =>
            new ClaudeReviewRoute(decision, trialMode, "HUMAN_DECISION_REQUIRED", "HUMAN_DECISION_REQUIRED",
                "Claude requires a human decision. Do not proceed on your own; surface the decision to the operator."),
    };
}
