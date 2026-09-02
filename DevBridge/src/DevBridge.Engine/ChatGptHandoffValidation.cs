// ChatGptHandoffValidation.cs — ChatGptHandoffValidation v1 (DB-GH01). A
// self-contained ChatGPT handoff must carry a governance header covering the
// 14 mandatory checks. The handoff must be fully self-contained (zero
// prior-memory dependence): ChatGPT receives every rule it needs inside the
// handoff, so the mode, boundaries, forbidden actions, git gates, and output
// contract are never assumed.
//
// If any mandatory check is missing, the handoff is CHATGPT_HANDOFF_NOT_READY
// and COPY_TO_CHATGPT must NOT be exposed until it is corrected.
using System;
using System.Collections.Generic;
using System.Linq;

namespace DevBridge.Engine;

public enum ChatGptHandoffCheck
{
    TemporaryBoundaryPresent,     // DevBridge is temporary external scaffolding
    ModePresent,                  // explicit TRIAL vs REAL_NEXUS_DEVELOPMENT
    ArchitectureRulesPresent,     // no Nexus architecture/contracts change via DevBridge
    DesignPhilosophyPresent,      // final purpose + retirement boundary
    RoadmapProtectionPresent,     // absolute roadmap immutability
    WorkbookAuthorityPresent,     // NEXUS_DEVELOPMENT_CONTROL.xlsx is the authoritative control record
    GitHumanGatePresent,          // git is a formal human-gated lifecycle
    ClaudeGatePresent,            // DB-M08 Claude review gate exists
    TaskIdentityPresent,          // task id / change id / node id stated
    ExactScopePresent,            // exact reserved scope stated
    ForbiddenActionsPresent,      // what ChatGPT must not do (structural edits, PR/merge, etc.)
    AcceptanceCriteriaPresent,    // acceptance criteria included
    VerificationPresent,          // DB-M06 verification requirements included
    OutputContractPresent,        // expected DeepSeek completion report contract stated
}

public sealed record ChatGptHandoffValidationResult(
    bool IsReady,
    IReadOnlyList<ChatGptHandoffCheck> Present,
    IReadOnlyList<ChatGptHandoffCheck> Missing)
{
    public string NotReadyToken => ChatGptHandoffValidation.ChatGptHandoffNotReadyToken;
}

public static class ChatGptHandoffValidation
{
    public const string ChatGptHandoffNotReadyToken = "CHATGPT_HANDOFF_NOT_READY";

    public static readonly IReadOnlyList<ChatGptHandoffCheck> AllChecks = Enum.GetValues<ChatGptHandoffCheck>();

    // Required marker substrings, matched case-insensitively. Section headers
    // plus one or more key phrases per check, so a human-written handoff passes
    // the same gate the script enforces.
    private static readonly (ChatGptHandoffCheck check, string[] markers)[] Rules =
    {
        (ChatGptHandoffCheck.TemporaryBoundaryPresent, new[] { "TEMPORARY", "external scaffolding", "retire" }),
        (ChatGptHandoffCheck.ModePresent, new[] { "TRIAL", "REAL_NEXUS_DEVELOPMENT" }),
        (ChatGptHandoffCheck.ArchitectureRulesPresent, new[] { "architecture", "NOT Nexus", "no architecture" }),
        (ChatGptHandoffCheck.DesignPhilosophyPresent, new[] { "scaffolding", "Nexus Phase 1/2", "retire" }),
        (ChatGptHandoffCheck.RoadmapProtectionPresent, new[] { "roadmap", "immutable", "no structural" }),
        (ChatGptHandoffCheck.WorkbookAuthorityPresent, new[] { "NEXUS_DEVELOPMENT_CONTROL.xlsx", "authoritative" }),
        (ChatGptHandoffCheck.GitHumanGatePresent, new[] { "human", "PR", "merge", "gate" }),
        (ChatGptHandoffCheck.ClaudeGatePresent, new[] { "DB-M08", "Claude" }),
        (ChatGptHandoffCheck.TaskIdentityPresent, new[] { "task", "change", "node" }),
        (ChatGptHandoffCheck.ExactScopePresent, new[] { "scope", "exact" }),
        (ChatGptHandoffCheck.ForbiddenActionsPresent, new[] { "forbidden", "must not", "prohibited" }),
        (ChatGptHandoffCheck.AcceptanceCriteriaPresent, new[] { "acceptance", "criteria" }),
        (ChatGptHandoffCheck.VerificationPresent, new[] { "DB-M06", "verification" }),
        (ChatGptHandoffCheck.OutputContractPresent, new[] { "report", "output", "DeepSeek" }),
    };

    public static ChatGptHandoffValidationResult Validate(string? markdown)
    {
        if (string.IsNullOrWhiteSpace(markdown))
            return new ChatGptHandoffValidationResult(false, Array.Empty<ChatGptHandoffCheck>(), AllChecks.ToArray());

        string hay = markdown;
        var present = new List<ChatGptHandoffCheck>();
        foreach (var (check, markers) in Rules)
        {
            if (markers.Any(m => hay.Contains(m, StringComparison.OrdinalIgnoreCase))) present.Add(check);
        }
        var missing = AllChecks.Where(c => !present.Contains(c)).ToArray();
        return new ChatGptHandoffValidationResult(missing.Length == 0, present, missing);
    }
}
