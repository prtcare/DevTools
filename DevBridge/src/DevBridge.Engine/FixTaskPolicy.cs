// FixTaskPolicy.cs — DB-M09 (DB-GH01). A defect found while a work item is
// ACTIVE is handled by focused correction of the current attempt (no
// acceptance-criteria/roadmap rewrite). A defect found AFTER completion is a
// SEPARATE fix task under the EXISTING structure — new task id, relation,
// defect reason, repair scope, acceptance condition, execution state. DevBridge
// must NEVER create a phase/milestone, move/reorder, or rewrite history. If the
// existing structure cannot represent the fix, DevBridge stops and asks the
// human (HUMAN_GOVERNANCE_REQUIRED) rather than invent a schema.
using System;

namespace DevBridge.Engine;

public enum FixAction
{
    CorrectCurrentAttempt, // work item still active -> focused delta
    NewFixTaskRequired,    // completed -> separate fix task under existing structure
    HumanGovernanceRequired, // structure cannot represent it -> stop, do not invent schema
}

/// <summary>A fix-task proposal under the EXISTING structure. Representation
/// only — creating it is a governed write by the operator, not by DevBridge.</summary>
public sealed record FixTaskProposal(
    string TaskId,          // new task id under existing node structure
    string RelatedChangeId, // the completed change the defect belongs to
    string DefectReason,
    string RepairScope,
    string AcceptanceCondition,
    string ExecutionStateStatus, // status/execution-state token to write on creation
    string NextAllowedAction);

public static class FixTaskPolicy
{
    public static FixAction Classify(bool workItemActive)
        => workItemActive ? FixAction.CorrectCurrentAttempt : FixAction.NewFixTaskRequired;

    public static string Explain(FixAction action) => action switch
    {
        FixAction.CorrectCurrentAttempt =>
            "The defect is in the current active attempt. Apply a focused correction delta (CORRECT_CURRENT_ATTEMPT); preserve verified work; do not rewrite acceptance criteria or the roadmap.",
        FixAction.NewFixTaskRequired =>
            "The work item is completed. Open a separate fix task under the existing structure (new task id, relation, defect reason, repair scope, acceptance condition, execution state). Never create a phase/milestone, move/reorder, or rewrite history.",
        _ =>
            "The existing structure cannot represent this fix. STOP: HUMAN_GOVERNANCE_REQUIRED. DevBridge must not invent a schema or restructure the roadmap.",
    };
}
