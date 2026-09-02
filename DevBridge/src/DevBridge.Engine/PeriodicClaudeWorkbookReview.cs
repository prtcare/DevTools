// PeriodicClaudeWorkbookReview.cs — DB-M11 advisory layer (DB-GH01). Role B:
// periodic, advisory, READ-ONLY workbook review by Claude. Verdicts are
// PASS / OBSERVATIONS / GOVERNANCE_CONCERN / HUMAN_REVIEW_REQUIRED. The review
// must NOT modify the workbook and must NOT redesign the roadmap. Deterministic
// validation (the probes) and the advisory review are separate concerns: the
// deterministic pass never depends on Claude, and the advisory review never
// blocks deterministic work — it only RECOMMENDS.
using System;
using System.Collections.Generic;

namespace DevBridge.Engine;

public enum PeriodicReviewVerdict
{
    Pass,
    Observations,
    GovernanceConcern,
    HumanReviewRequired,
}

public static class PeriodicReviewVerdicts
{
    public static PeriodicReviewVerdict FromString(string? token) => token?.Trim().ToUpperInvariant() switch
    {
        "PASS" => PeriodicReviewVerdict.Pass,
        "OBSERVATIONS" => PeriodicReviewVerdict.Observations,
        "GOVERNANCE_CONCERN" => PeriodicReviewVerdict.GovernanceConcern,
        "HUMAN_REVIEW_REQUIRED" => PeriodicReviewVerdict.HumanReviewRequired,
        _ => PeriodicReviewVerdict.Observations,
    };

    public static bool RequiresHuman(PeriodicReviewVerdict verdict) => verdict == PeriodicReviewVerdict.HumanReviewRequired;
}

/// <summary>Configurable trigger conditions for a periodic Role B review.</summary>
public sealed record PeriodicReviewTriggers(
    bool AfterMilestoneCompletion,
    int AfterNWorkItems,
    bool AfterFixTaskChain,
    bool AfterM11SuspiciousNonStructuralCondition,
    bool Manual)
{
    public bool ShouldRecommend(int completedWorkItems, bool fixTaskChainActive, bool m11Suspicious)
        => AfterMilestoneCompletion || (AfterNWorkItems > 0 && completedWorkItems >= AfterNWorkItems)
           || (AfterFixTaskChain && fixTaskChainActive)
           || (AfterM11SuspiciousNonStructuralCondition && m11Suspicious)
           || Manual;
}

/// <summary>The advisory recommendation DB-M11 may emit. It is NEVER a blocking
/// verdict and never auto-invokes Claude — it only suggests a review.</summary>
public sealed record M11ReviewRecommendation(
    bool DeterministicValidationPassed,
    bool ClaudeWorkbookReviewRecommended,
    string? Reason)
{
    public string Token => ClaudeWorkbookReviewRecommended
        ? "CLAUDE_WORKBOOK_REVIEW_RECOMMENDED"
        : "NO_ADVISORY_REVIEW_RECOMMENDED";
}

/// <summary>A read-only advisory review artifact. The reviewer writes this
/// report; the workbook is never modified by the advisory path.</summary>
public sealed record PeriodicClaudeWorkbookReviewReport(
    string GeneratedAtUtc,
    PeriodicReviewVerdict Verdict,
    string Findings,
    string? Recommendations)
{
    public const string ReadOnlyContract =
        "Role B periodic review is READ-ONLY: it must not modify NEXUS_DEVELOPMENT_CONTROL.xlsx and must not redesign the roadmap.";
}
