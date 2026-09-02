// ClaudeReviewPackageValidation.cs — DB-M07 (DB-GH01). EVERY Claude review
// package must carry the governance header so the review is self-contained and
// the reviewer never assumes prior DevBridge memory. This is the reusable
// header check applied to a generated package before it is offered to Claude.
using System;
using System.Collections.Generic;
using System.Linq;

namespace DevBridge.Engine;

public enum ClaudeReviewPackageHeaderItem
{
    TemporaryBoundary,       // DevBridge is temporary external scaffolding
    TrialOrRealMode,         // explicit trial vs real
    ArchitectureIndependence,// review may not redesign Nexus architecture
    RoadmapImmutability,     // no roadmap redesign / structural edits
    FixTaskRule,             // CORRECT_CURRENT_ATTEMPT vs NEW_FIX_TASK_REQUIRED
    ExactScope,              // exact change scope under review
    ForbiddenEdits,          // forbidden workbook/source edits
    HumanGitGates,           // human PR/review/merge gates
    DecisionVocabulary,      // PASS / FIX / GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED
}

public sealed record ClaudeReviewPackageValidationResult(
    bool HasGovernanceHeader,
    IReadOnlyList<ClaudeReviewPackageHeaderItem> Present,
    IReadOnlyList<ClaudeReviewPackageHeaderItem> Missing);

public static class ClaudeReviewPackageValidation
{
    public const string MissingHeaderToken = "CLAUDE_REVIEW_PACKAGE_MISSING_GOVERNANCE_HEADER";

    private static readonly (ClaudeReviewPackageHeaderItem item, string[] markers)[] Rules =
    {
        (ClaudeReviewPackageHeaderItem.TemporaryBoundary, new[] { "TEMPORARY", "external scaffolding", "retire" }),
        (ClaudeReviewPackageHeaderItem.TrialOrRealMode, new[] { "TRIAL", "REAL_NEXUS_DEVELOPMENT" }),
        (ClaudeReviewPackageHeaderItem.ArchitectureIndependence, new[] { "architecture", "NOT authorized to redesign" }),
        (ClaudeReviewPackageHeaderItem.RoadmapImmutability, new[] { "roadmap", "redesign", "immutable" }),
        (ClaudeReviewPackageHeaderItem.FixTaskRule, new[] { "CORRECT_CURRENT_ATTEMPT", "NEW_FIX_TASK_REQUIRED" }),
        (ClaudeReviewPackageHeaderItem.ExactScope, new[] { "scope", "delta" }),
        (ClaudeReviewPackageHeaderItem.ForbiddenEdits, new[] { "forbidden", "must not", "prohibited" }),
        (ClaudeReviewPackageHeaderItem.HumanGitGates, new[] { "PR", "merge", "human" }),
        (ClaudeReviewPackageHeaderItem.DecisionVocabulary, new[] { "PASS", "GOVERNANCE_ISSUE", "HUMAN_DECISION_REQUIRED" }),
    };

    public static ClaudeReviewPackageValidationResult Validate(string? markdown)
    {
        if (string.IsNullOrWhiteSpace(markdown))
            return new ClaudeReviewPackageValidationResult(false, Array.Empty<ClaudeReviewPackageHeaderItem>(), Rules.Select(r => r.item).ToArray());

        var present = new List<ClaudeReviewPackageHeaderItem>();
        foreach (var (item, markers) in Rules)
            if (markers.Any(m => markdown.Contains(m, StringComparison.OrdinalIgnoreCase))) present.Add(item);

        var missing = Rules.Select(r => r.item).Where(i => !present.Contains(i)).ToArray();
        return new ClaudeReviewPackageValidationResult(missing.Length == 0, present, missing);
    }
}
