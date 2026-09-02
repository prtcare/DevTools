// OperatorCommand.cs — the UI-owned operator command vocabulary (DB-M12.1).
//
// Each entry is UI/operator metadata that DESCRIBES a governed lifecycle action:
// which backend script(s) to invoke, the state the action may run from, the state
// it must produce, and how dangerous it is. It NEVER overrides backend validation
// — the script performs all governance checks. A command whose underlying backend
// implementation is not durably callable is declared GUIDED_MANUAL_ACTION with the
// exact reason recorded, so the UI can never present it as an automatic button.
namespace DevBridge.Engine;

public enum OperatorCommandKind
{
    Script,            // invokes an existing backend PowerShell script
    GuidedManual,      // no durable backend entry point; operator guidance / evidence entry
    Navigation,        // opens a generated artifact/report (read-only)
    Clipboard,         // copies a generated artifact verbatim (read-only)
}

public enum OperatorDangerLevel
{
    ReadOnly,           // no authoritative state mutated by this command
    WritesWorkbook,     // may mutate NEXUS_DEVELOPMENT_CONTROL.xlsx (operator confirmation required)
    WritesNexusSource,  // may mutate Nexus source repositories (not exposed by DB-M12.1)
}

public sealed class OperatorCommand
{
    public string CommandId { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public OperatorCommandKind Kind { get; init; } = OperatorCommandKind.Script;

    /// <summary>Lifecycle status(es) this command may run from. Empty = any.</summary>
    public string[] RequiredStates { get; init; } = Array.Empty<string>();

    /// <summary>The lifecycle status the command must produce. Empty = no transition asserted.</summary>
    public string ResultingExpectedState { get; init; } = "";

    /// <summary>DB-M12.2: an exact current-status the command may run from (stale guard).
    /// When non-empty the command is rejected with STALE_GOVERNANCE_STATE unless the live
    /// status equals it. A per-invocation input ExpectedCurrentState overrides this.</summary>
    public string? ExpectedCurrentState { get; init; }

    /// <summary>DB-M12.2: the command is addressed at a specific task (requires NodeId +
    /// ChangeId in the command input, matching the current task).</summary>
    public bool RequiresTaskIdentity { get; init; }

    /// <summary>Backend script names (relative to scripts\, run in order, first failure stops).</summary>
    public string[] Scripts { get; init; } = Array.Empty<string>();

    /// <summary>Whether the operator must supply input before the action can complete.</summary>
    public bool RequiresUserInput { get; init; }

    /// <summary>Whether the action mutates the authoritative workbook.</summary>
    public bool WritesWorkbook { get; init; }

    /// <summary>Whether the action mutates Nexus source repositories.</summary>
    public bool WritesNexusSource { get; init; }

    public OperatorDangerLevel DangerLevel { get; init; } = OperatorDangerLevel.ReadOnly;

    public int TimeoutMs { get; init; } = 600000;

    /// <summary>For Clipboard commands, the tasks\ artifact file to copy.</summary>
    public string? ArtifactFile { get; init; }

    public string Description { get; init; } = "";

    /// <summary>When Kind == GuidedManual, why there is no automatic invocation.</summary>
    public string? GuidedReason { get; init; }

    /// <summary>Operator guidance shown for guided/manual commands.</summary>
    public string? ManualGuidance { get; init; }
}

public static class OperatorCommandCatalog
{
    /// <summary>All operator commands keyed by CommandId.</summary>
    public static readonly IReadOnlyDictionary<string, OperatorCommand> All;

    public static OperatorCommand? Get(string commandId)
        => All.TryGetValue(commandId, out var cmd) ? cmd : null;

    static OperatorCommandCatalog()
    {
        var list = new List<OperatorCommand>
        {
            // =================================================================
            // AUTOMATED — durable backend scripts exist.
            // =================================================================
            new OperatorCommand
            {
                CommandId = "START_PREFLIGHT",
                DisplayName = "Start Preflight",
                Kind = OperatorCommandKind.Script,
                RequiredStates = Array.Empty<string>(),
                ResultingExpectedState = "PREFLIGHTED",
                Scripts = new[] { "Get-NextTask.ps1", "Test-DevelopmentPreflight.ps1" },
                DangerLevel = OperatorDangerLevel.ReadOnly,
                TimeoutMs = 600000,
                Description = "DB-M03 governed preflight: select the current/next task, then run the " +
                              "pre-implementation engine (writes state/preflight.json, tasks/NEXT_TASK.md, " +
                              "tasks/PREFLIGHT_REPORT.md and sets current-task.json to PREFLIGHTED).",
            },
            new OperatorCommand
            {
                CommandId = "RESERVE_TASK",
                DisplayName = "Reserve Task",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "PREFLIGHTED" },
                ResultingExpectedState = "RESERVED",
                Scripts = new[] { "Reserve-DevelopmentChange.ps1" },
                RequiresUserInput = true,       // workbook-write confirmation
                WritesWorkbook = true,
                DangerLevel = OperatorDangerLevel.WritesWorkbook,
                TimeoutMs = 600000,
                Description = "DB-M04 governed reservation: appends the Active Changes + Activity Log rows, " +
                              "backs up the workbook, captures the git baseline and sets current-task.json to " +
                              "RESERVED. Idempotency-aware (reuses an existing live reservation).",
            },
            new OperatorCommand
            {
                CommandId = "CREATE_CHATGPT_HANDOFF",
                DisplayName = "Create ChatGPT Handoff",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "RESERVED" },
                ResultingExpectedState = "AWAITING_CHATGPT_PROMPT",
                Scripts = new[] { "New-ChatGptHandoff.ps1" },
                DangerLevel = OperatorDangerLevel.ReadOnly, // workbook read-only to this engine
                TimeoutMs = 600000,
                Description = "DB-M05 governed handoff: freshly validates the reservation against the live " +
                              "workbook, then writes tasks/CHATGPT_HANDOFF.md, tasks/DEEPSEEK_PROMPT.md " +
                              "(placeholder) and sets current-task.json to AWAITING_CHATGPT_PROMPT.",
            },
            new OperatorCommand
            {
                CommandId = "RUN_GOVERNED_COMPLETION",
                DisplayName = "Run Governed Completion",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "CLAUDE_REVIEW_PASSED_TRIAL", "CLAUDE_REVIEW_PASSED_REAL", "AWAITING_HUMAN_PR",
                    "PR_OPEN", "AWAITING_HUMAN_REVIEW", "AWAITING_HUMAN_MERGE", "MERGED", "READY_FOR_GOVERNED_COMPLETION" },
                ResultingExpectedState = "",   // COMPLETION_WRITTEN only when the gate is satisfied; TRIAL -> TRIAL_COMPLETION_NOT_APPLICABLE
                Scripts = new[] { "Complete-GovernedCycle.ps1" },
                RequiresTaskIdentity = true,
                RequiresUserInput = true,      // governed completion is an operator-confirmed authoritative write
                WritesWorkbook = true,
                DangerLevel = OperatorDangerLevel.WritesWorkbook,
                TimeoutMs = 600000,
                Description = "DB-M10 governed completion: runs the full eligibility gate (mode, DB-M06 pass, Claude PASS, " +
                              "confirmed human merge, protected-roadmap fingerprint), then applies the CURRENT change's " +
                              "sheet-update-plan to the authoritative workbook with backup + read-back and records " +
                              "state/completion.json. TRIAL mode returns TRIAL_COMPLETION_NOT_APPLICABLE with no write.",
            },
            new OperatorCommand
            {
                CommandId = "CLOSE_TRIAL_CYCLE",
                DisplayName = "Close Trial Cycle",
                Kind = OperatorCommandKind.Script,
                // TRIAL_CYCLE_CLOSED is included so a re-invocation is recognised as
                // idempotent (the backend returns TRIAL_CYCLE_ALREADY_CLOSED); the
                // stale guard below confines the authoritative closure to the
                // safe-stop position.
                RequiredStates = new[] { "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "TRIAL_CYCLE_CLOSED" },
                ResultingExpectedState = "TRIAL_CYCLE_CLOSED",
                ExpectedCurrentState = "CLAUDE_REVIEW_PASSED_TRIAL",
                Scripts = new[] { "Close-TrialCycle.ps1" },
                RequiresTaskIdentity = true,
                RequiresUserInput = true,      // operator-confirmed authoritative write (workbook Status + Activity Log)
                WritesWorkbook = true,
                DangerLevel = OperatorDangerLevel.WritesWorkbook,
                TimeoutMs = 600000,
                Description = "DB-M12.4 governed TRIAL cycle closure: closes a proven TRIAL cycle at its safe stop, " +
                              "marks the reservation Closed-terminal, appends one Activity Log row, records " +
                              "state/trial-closure.json + state/trial-proving-history.json + tasks/TRIAL_CYCLE_CLOSURE_REPORT.md, " +
                              "and transitions to TRIAL_CYCLE_CLOSED. NEVER runs M10, NEVER completes the roadmap node, " +
                              "NEVER creates a PR/merge. Prohibited in REAL mode. Idempotent.",
            },
            new OperatorCommand
            {
                CommandId = "START_NEXT_CYCLE",
                DisplayName = "Start Next Cycle",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "TRIAL_CYCLE_CLOSED" },
                ResultingExpectedState = "PREFLIGHTED",
                Scripts = new[] { "Get-NextTask.ps1", "Test-DevelopmentPreflight.ps1" },
                DangerLevel = OperatorDangerLevel.ReadOnly, // preflight writes state evidence only, never the workbook
                TimeoutMs = 600000,
                Description = "DB-M12.4 fresh proving cycle: after a TRIAL cycle is closed, runs M03 + preflight for the " +
                              "NEXT governed task (the closed trial task is excluded from re-selection in TRIAL mode) and " +
                              "transitions to PREFLIGHTED.",
            },

            // =================================================================
            // GUIDED / MANUAL — no durable backend entry point exists (Part 5).
            // =================================================================
            new OperatorCommand
            {
                CommandId = "RUN_VERIFICATION",
                DisplayName = "Run Verification",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "AWAITING_CHATGPT_PROMPT", "VERIFIED" },
                ResultingExpectedState = "VERIFIED",
                Scripts = new[] { "Run-Verification.ps1" },
                RequiresTaskIdentity = true,
                DangerLevel = OperatorDangerLevel.ReadOnly, // reads the workbook; never writes it
                TimeoutMs = 600000,
                Description = "DB-M06 governed verification: runs the configured (or auto-discovered) build/test " +
                              "commands for the CURRENT task, records state/verification.json + tasks/VERIFICATION_REPORT.md, " +
                              "and transitions to VERIFIED on PASS. A verification FAILURE reports DB06_RESULT_PASS: False.",
            },
            new OperatorCommand
            {
                CommandId = "CREATE_CLAUDE_REVIEW_PACKAGE",
                DisplayName = "Create Claude Review Package",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "VERIFIED" },
                ResultingExpectedState = "VERIFIED", // evidence assembly; lifecycle state unchanged
                Scripts = new[] { "New-ClaudeReviewPackage.ps1" },
                RequiresTaskIdentity = true,
                DangerLevel = OperatorDangerLevel.ReadOnly,
                TimeoutMs = 600000,
                Description = "DB-M07 governed package assembly: builds tasks/CLAUDE_REVIEW_PACKAGE.md (governance header) " +
                              "and tasks/REVIEW_PACKET.md from the verification evidence of the CURRENT task for Claude's review.",
            },
            new OperatorCommand
            {
                CommandId = "RECORD_CLAUDE_RESULT",
                DisplayName = "Record Claude Result",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "VERIFIED" },
                ResultingExpectedState = "",   // the routed lifecycle state is mode-derived (trial stop / real git gate / fix / governance)
                Scripts = new[] { "Set-ClaudeReviewResult.ps1" },
                RequiresUserInput = true,      // the operator supplies Claude's verdict + verbatim review text
                RequiresTaskIdentity = true,
                DangerLevel = OperatorDangerLevel.ReadOnly, // writes evidence files + current-task.json, never the workbook
                TimeoutMs = 600000,
                Description = "DB-M08 governed Claude decision recording: preserves the verdict verbatim, writes " +
                              "tasks/CLAUDE_REVIEW_RESULT.md + state/claude-review.json, and routes the cycle " +
                              "(trial PASS -> TRIAL_CYCLE_SAFE_STOP, real PASS -> human Git gate, FIX -> correction loop, " +
                              "governance issue -> human review).",
            },
            new OperatorCommand
            {
                CommandId = "VALIDATE_WORKBOOK",
                DisplayName = "Validate Workbook",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "COMPLETION_WRITTEN" },
                ResultingExpectedState = "CONTROL_VALIDATED",
                Scripts = new[] { "Invoke-WorkbookValidation.ps1" },
                RequiresTaskIdentity = true,
                DangerLevel = OperatorDangerLevel.ReadOnly, // reads the authoritative workbook; writes state evidence only
                TimeoutMs = 600000,
                Description = "DB-M11 governed workbook consistency validation: verifies the authoritative workbook " +
                              "against the lifecycle evidence, records state/workbook-consistency.json + " +
                              "tasks/WORKBOOK_CONSISTENCY_REPORT.md and transitions to CONTROL_VALIDATED.",
            },

            // =================================================================
            // DB-M12.2 REUSABLE LIFECYCLE BACKEND COMMANDS — new durable entry
            // points for the remaining governed lifecycle capabilities.
            // =================================================================
            new OperatorCommand
            {
                CommandId = "CREATE_CORRECTION_CONTEXT",
                DisplayName = "Create Correction Context",
                Kind = OperatorCommandKind.Script,
                RequiredStates = new[] { "DB_M09_FIX_REQUIRED" },
                ResultingExpectedState = "DB_M09_FIX_REQUIRED",
                Scripts = new[] { "New-CorrectionContext.ps1" },
                RequiresTaskIdentity = true,
                DangerLevel = OperatorDangerLevel.ReadOnly,
                TimeoutMs = 600000,
                Description = "DB-M09 governed correction context: assembles tasks/FIX_CONTEXT.md from the Claude fix " +
                              "findings of the CURRENT task while preserving the existing task evidence; scope widening " +
                              "is never silent.",
            },
            new OperatorCommand
            {
                CommandId = "CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE",
                DisplayName = "Create Claude Workbook Review Package",
                Kind = OperatorCommandKind.Script,
                RequiredStates = Array.Empty<string>(),
                ResultingExpectedState = "",   // advisory-only, READ-ONLY
                Scripts = new[] { "New-ClaudeWorkbookReviewPackage.ps1" },
                DangerLevel = OperatorDangerLevel.ReadOnly,
                TimeoutMs = 600000,
                Description = "DB-M11 Role B periodic advisory: computes whether a read-only Claude workbook review is " +
                              "recommended and, when recommended, assembles the read-only review package. Never edits " +
                              "the roadmap.",
            },
            new OperatorCommand
            {
                CommandId = "REFRESH_GIT_GATE_STATE",
                DisplayName = "Refresh Git Gate State",
                Kind = OperatorCommandKind.Script,
                RequiredStates = Array.Empty<string>(),
                ResultingExpectedState = "",   // observation; no lifecycle transition
                Scripts = new[] { "Get-GitGateState.ps1" },
                DangerLevel = OperatorDangerLevel.ReadOnly,
                TimeoutMs = 600000,
                Description = "DB-GH01 Git gate observation: refreshes the observed git lifecycle state (branch, head, " +
                              "PR position) into state/git-gate-state.json. PR state is UNKNOWN whenever it cannot be " +
                              "verified — never fabricated.",
            },
            new OperatorCommand
            {
                CommandId = "GET_CURRENT_LIFECYCLE_STATE",
                DisplayName = "Get Current Lifecycle State",
                Kind = OperatorCommandKind.Script,
                RequiredStates = Array.Empty<string>(),
                ResultingExpectedState = "",   // read-only snapshot
                Scripts = new[] { "Get-CurrentLifecycleState.ps1" },
                DangerLevel = OperatorDangerLevel.ReadOnly,
                TimeoutMs = 600000,
                Description = "Read-only lifecycle snapshot: emits the full current lifecycle state (task identity, mode, " +
                              "status, next action, git gate position, M10 eligibility) to stdout and " +
                              "state/current-lifecycle-state.json.",
            },

            // =================================================================
            // DB-GH01 HUMAN-GATED / GUIDANCE commands — the UI may TELL the
            // operator to perform these actions but never pretends they occurred.
            // =================================================================
            new OperatorCommand
            {
                CommandId = "CREATE_PR",
                DisplayName = "Create PR (Human)",
                Kind = OperatorCommandKind.GuidedManual,
                RequiredStates = new[] { "CLAUDE_REVIEW_PASSED_REAL", "AWAITING_HUMAN_PR" },
                Description = "DB-GH01 Git gate: a HUMAN creates the PR for the real change.",
                GuidedReason = "DevBridge must never create or approve its own PR. This is a human-gated action " +
                               "with no automatic backend entry point by design.",
                ManualGuidance = "Create the PR for the reviewed real change and set the observed git state to " +
                                 "PR_OPEN. DevBridge does not create PRs.",
            },
            new OperatorCommand
            {
                CommandId = "REVIEW_PR",
                DisplayName = "Review PR (Human)",
                Kind = OperatorCommandKind.GuidedManual,
                RequiredStates = new[] { "PR_OPEN", "AWAITING_HUMAN_REVIEW" },
                Description = "DB-GH01 Git gate: a HUMAN reviews the PR.",
                GuidedReason = "DevBridge never approves its own PR. The review is a human-gated action with no " +
                               "automatic backend entry point by design.",
                ManualGuidance = "Have a human review the open PR, then set the observed git state to " +
                                 "AWAITING_HUMAN_MERGE (or PR_OPEN while changes are requested).",
            },
            new OperatorCommand
            {
                CommandId = "MERGE_PR",
                DisplayName = "Merge PR (Human)",
                Kind = OperatorCommandKind.GuidedManual,
                RequiredStates = new[] { "AWAITING_HUMAN_MERGE" },
                Description = "DB-GH01 Git gate: a HUMAN merges the PR.",
                GuidedReason = "DevBridge never merges automatically and must never infer a merge. Merging is a " +
                               "human-gated action with no automatic backend entry point by design.",
                ManualGuidance = "A human merges the reviewed PR. Once the merge is CONFIRMED, set the observed " +
                                 "git state to MERGED so governed completion may be considered.",
            },
            new OperatorCommand
            {
                CommandId = "REVIEW_GOVERNANCE_ISSUE",
                DisplayName = "Review Governance Issue",
                Kind = OperatorCommandKind.GuidedManual,
                RequiredStates = new[] { "GOVERNANCE_ISSUE" },
                Description = "DB-GH01 governance issue: a HUMAN reviews the flagged issue.",
                GuidedReason = "A governance issue is by definition outside DevBridge's mandate to resolve. It is " +
                               "referred to a human; there is no automatic resolution path.",
                ManualGuidance = "Review the governance issue (roadmap-structure protection violation, mode " +
                                 "conflict, or lifecycle rule). DevBridge records the verdict but a human decides " +
                                 "the corrective action.",
            },
            new OperatorCommand
            {
                CommandId = "RESTORE_REAL_NEXUS_BASELINE",
                DisplayName = "Restore Real Nexus Baseline (Human)",
                Kind = OperatorCommandKind.GuidedManual,
                RequiredStates = new[] { "READY_FOR_GOVERNED_COMPLETION" },
                Description = "DB-GH01 retirement/baseline: a HUMAN restores the real Nexus baseline.",
                GuidedReason = "No automatic destructive restore is ever performed by DevBridge (no auto " +
                               "git reset --hard, no overwrite of the authoritative workbook, no deletion of " +
                               "trial source). Restoration is a human-gated action with no automatic entry point.",
                ManualGuidance = "Only a human restores the real Nexus baseline (PreDevBridgeGitBaseline / " +
                                 "PreDevBridgeWorkbookBaseline captured pre-DevBridge). DevBridge never restores it " +
                                 "automatically.",
            },

            // =================================================================
            // NAVIGATION — open a generated artifact (read-only).
            // =================================================================
            new OperatorCommand
            {
                CommandId = "OPEN_PREFLIGHT_REPORT", DisplayName = "Open Preflight Report",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/PREFLIGHT_REPORT.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_VERIFICATION_REPORT", DisplayName = "Open Verification Report",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/VERIFICATION_REPORT.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_REVIEW_PACKET", DisplayName = "Open Review Packet",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/REVIEW_PACKET.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_COMPLETION_REPORT", DisplayName = "Open Completion Report",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/COMPLETION_REPORT.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_CONSISTENCY_REPORT", DisplayName = "Open Consistency Report",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/WORKBOOK_CONSISTENCY_REPORT.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_DEEPSEEK_PROMPT", DisplayName = "Open DeepSeek Prompt",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/DEEPSEEK_PROMPT.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_CHATGPT_HANDOFF", DisplayName = "Open ChatGPT Handoff",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens tasks/CHATGPT_HANDOFF.md.",
            },
            new OperatorCommand
            {
                CommandId = "OPEN_DETAIL", DisplayName = "Open Task Detail",
                Kind = OperatorCommandKind.Navigation,
                Description = "Opens the current task's preserved history directory.",
            },

            // =================================================================
            // CLIPBOARD — copy a generated artifact verbatim (read-only).
            // =================================================================
            new OperatorCommand
            {
                CommandId = "COPY_FOR_CHATGPT", DisplayName = "Copy for ChatGPT",
                Kind = OperatorCommandKind.Clipboard, ArtifactFile = "CHATGPT_HANDOFF.md",
                Description = "Copies tasks/CHATGPT_HANDOFF.md to the clipboard.",
            },
            new OperatorCommand
            {
                CommandId = "COPY_FOR_DEEPSEEK", DisplayName = "Copy DeepSeek Prompt",
                Kind = OperatorCommandKind.Clipboard, ArtifactFile = "DEEPSEEK_PROMPT.md",
                Description = "Copies tasks/DEEPSEEK_PROMPT.md to the clipboard.",
            },
            new OperatorCommand
            {
                CommandId = "COPY_FOR_CLAUDE", DisplayName = "Copy for Claude",
                Kind = OperatorCommandKind.Clipboard, ArtifactFile = "REVIEW_PACKET.md",
                Description = "Copies tasks/REVIEW_PACKET.md (falls back to CLAUDE_REVIEW_PROMPT.md) to the clipboard.",
            },
            new OperatorCommand
            {
                CommandId = "COPY_FIX_CONTEXT", DisplayName = "Copy Fix Context",
                Kind = OperatorCommandKind.Clipboard, ArtifactFile = "FIX_CONTEXT.md",
                Description = "Copies tasks/FIX_CONTEXT.md to the clipboard.",
            },
        };

        All = list.ToDictionary(c => c.CommandId, StringComparer.OrdinalIgnoreCase);
    }
}

public static class OperatorCommandExtensions
{
    /// <summary>Resolve a relative script name against the DevBridge scripts directory.</summary>
    public static string ResolveScriptPath(this DevBridgeConfig cfg, string scriptName)
        => Path.Combine(cfg.ScriptsDir, scriptName);
}
