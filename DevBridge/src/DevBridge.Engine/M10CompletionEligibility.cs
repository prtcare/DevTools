// M10CompletionEligibility.cs — DB-M10 CRITICAL gate (DB-GH01). Governed
// completion is eligible ONLY when every gate is proven:
//   * TRIAL mode -> TRIAL_COMPLETION_NOT_APPLICABLE. M10 is never run for a
//     trial cycle (disposable evidence).
//   * REAL mode -> DB-M06 PASS, Claude PASS, a CONFIRMED human merge
//     (Merged), and the protected roadmap fingerprint preserved across the
//     write. Any unmet gate blocks with a specific BLOCKED_* verdict.
// This type never performs the write; it only declares eligibility.
using System;

namespace DevBridge.Engine;

public enum M10CompletionEligibilityVerdict
{
    NotApplicable,                       // TRIAL_COMPLETION_NOT_APPLICABLE
    ReadyForGovernedCompletion,
    BlockedTrialMode,                    // trial attempts completion
    BlockedNoVerificationPass,           // DB-M06 not PASS
    BlockedNoClaudePass,                 // Claude review not PASS
    BlockedHumanGitGatePending,          // merge not confirmed
    BlockedRoadmapStructureWriteProhibited, // protected fingerprint changed
}

public sealed record M10CompletionEligibilityResult(
    M10CompletionEligibilityVerdict Verdict,
    string Token,
    string Instruction)
{
    public bool Eligible => Verdict == M10CompletionEligibilityVerdict.ReadyForGovernedCompletion;
}

public static class M10CompletionEligibility
{
    public const string TrialCompletionNotApplicableToken = "TRIAL_COMPLETION_NOT_APPLICABLE";

    public static M10CompletionEligibilityResult Evaluate(
        bool trialMode,
        bool verificationPassed,
        bool claudePass,
        HumanGitGateState humanGitGate,
        RoadmapGuardVerdict fingerprintGuard)
    {
        if (trialMode)
            return new M10CompletionEligibilityResult(
                M10CompletionEligibilityVerdict.NotApplicable,
                TrialCompletionNotApplicableToken,
                "TRIAL cycle: M10 governed completion is NOT applicable. The cycle stops at TRIAL_CYCLE_SAFE_STOP; completion is never run for trial evidence.");

        if (!verificationPassed)
            return Blocked(M10CompletionEligibilityVerdict.BlockedNoVerificationPass,
                "BLOCKED_NO_DB_M06_VERIFICATION_PASS",
                "DB-M06 verification has not passed. Completion requires DB-M06 PASS first.");

        if (!claudePass)
            return Blocked(M10CompletionEligibilityVerdict.BlockedNoClaudePass,
                "BLOCKED_NO_CLAUDE_PASS",
                "Claude review has not passed. Completion requires Claude PASS.");

        if (!GitLifecycle.MergeConfirmed(humanGitGate))
            return Blocked(M10CompletionEligibilityVerdict.BlockedHumanGitGatePending,
                "BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING",
                "The human Git merge gate is not confirmed. A REAL completion requires a CONFIRMED merge — never an inferred one.");

        if (fingerprintGuard != RoadmapGuardVerdict.Preserved)
            return Blocked(M10CompletionEligibilityVerdict.BlockedRoadmapStructureWriteProhibited,
                ProtectedRoadmapFingerprintGuard.BlockToken,
                ProtectedRoadmapFingerprintGuard.BlockMessage(fingerprintGuard));

        return new M10CompletionEligibilityResult(
            M10CompletionEligibilityVerdict.ReadyForGovernedCompletion,
            "READY_FOR_GOVERNED_COMPLETION",
            "All gates satisfied: DB-M06 PASS, Claude PASS, human merge confirmed, protected roadmap fingerprint preserved. The governed completion write may proceed.");
    }

    private static M10CompletionEligibilityResult Blocked(M10CompletionEligibilityVerdict verdict, string token, string instruction)
        => new(verdict, token, instruction);
}
