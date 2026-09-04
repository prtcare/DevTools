// NextActionEngine.cs — derives, entirely from DevBridgeState (current-task.json
// status/nextAllowedAction + evidence artifacts), the single instruction the
// operator must follow and the exact set of permitted action buttons.
//
// Rule: the UI NEVER guesses an action. Every branch is grounded in an explicit
// state field or an evidence artifact. Unknown/mismatched states degrade to a
// safe "review the task" outcome with no governed button enabled.
namespace DevBridge.Engine;

public sealed record FailureInfo(string StageKey, string StageLabel, string? Timestamp, string Result, string RecommendedAction);

public sealed class NextActionInfo
{
    public string Instruction { get; init; } = "";
    public bool HasActiveTask { get; init; }
    public string? CurrentStage { get; init; }
    public List<LifecycleStageState> Stages { get; init; } = new();
    public List<string> EnabledButtons { get; init; } = new();
    public FailureInfo? Failure { get; init; }
    public int ResidualObservationCount { get; init; }
}

public static class NextActionEngine
{
    public static readonly (string Key, string Label)[] AllButtons =
    {
        ("START_PREFLIGHT", "START PREFLIGHT"),
        ("RESERVE_TASK", "RESERVE TASK"),
        ("CREATE_CHATGPT_HANDOFF", "CREATE CHATGPT HANDOFF"),
        ("COPY_FOR_CHATGPT", "COPY FOR CHATGPT"),
        ("COPY_FOR_DEEPSEEK", "COPY DEEPSEEK PROMPT"),
        ("OPEN_DEEPSEEK_PROMPT", "OPEN DEEPSEEK PROMPT"),
        ("RUN_VERIFICATION", "RUN VERIFICATION"),
        ("CREATE_CLAUDE_REVIEW_PACKAGE", "CREATE CLAUDE REVIEW PACKAGE"),
        ("COPY_FOR_CLAUDE", "COPY FOR CLAUDE"),
        ("OPEN_REVIEW_PACKET", "OPEN REVIEW PACKET"),
        ("RECORD_CLAUDE_RESULT", "RECORD CLAUDE RESULT"),
        ("COPY_FIX_CONTEXT", "COPY FIX CONTEXT"),
        ("RECONCILE_CORRECTION", "RECONCILE CORRECTION"),
        ("RUN_GOVERNED_COMPLETION", "RUN GOVERNED COMPLETION"),
        ("CLOSE_TRIAL_CYCLE", "CLOSE TRIAL CYCLE"),
        ("START_NEXT_CYCLE", "START NEXT CYCLE"),
        ("VALIDATE_WORKBOOK", "VALIDATE WORKBOOK"),
        ("OPEN_PREFLIGHT_REPORT", "OPEN PREFLIGHT REPORT"),
        ("OPEN_VERIFICATION_REPORT", "OPEN VERIFICATION REPORT"),
        ("OPEN_CONSISTENCY_REPORT", "OPEN CONSISTENCY REPORT"),
        ("OPEN_COMPLETION_REPORT", "OPEN COMPLETION REPORT"),
        ("OPEN_DETAIL", "OPEN TASK DETAIL"),
        // DB-GH01 human-gate guidance buttons. The engine enables REVIEW_GOVERNANCE_ISSUE
        // in a governance-issue state; the Git-gate buttons (CREATE_PR / REVIEW_PR /
        // MERGE_PR) and RESTORE_REAL_NEXUS_BASELINE are documented but NEVER enabled —
        // the UI TELLS the operator what a human must do; it never drives or pretends.
        ("CREATE_PR", "CREATE PR"),
        ("REVIEW_PR", "REVIEW PR"),
        ("MERGE_PR", "MERGE PR"),
        ("REVIEW_GOVERNANCE_ISSUE", "REVIEW GOVERNANCE ISSUE"),
        ("RESTORE_REAL_NEXUS_BASELINE", "RESTORE REAL NEXUS BASELINE"),
    };

    private static readonly (LifecycleStageKey Key, string Label)[] StageCatalog =
    {
        (LifecycleStageKey.Idle, "Task"),
        (LifecycleStageKey.Preflight, "Preflight"),
        (LifecycleStageKey.Reservation, "Reservation"),
        (LifecycleStageKey.ChatGpt, "ChatGPT"),
        (LifecycleStageKey.DeepSeek, "DeepSeek"),
        (LifecycleStageKey.Verification, "Verification"),
        (LifecycleStageKey.Claude, "Claude Review"),
        (LifecycleStageKey.FixLoop, "Fix Loop"),
        (LifecycleStageKey.Completion, "Completion"),
        (LifecycleStageKey.ControlValidation, "Workbook Validation"),
        (LifecycleStageKey.Done, "Done"),
    };

    public static NextActionInfo Evaluate(DevBridgeState s)
    {
        // ---- 0. no active task ----
        if (!s.TaskStateFilePresent || string.IsNullOrWhiteSpace(s.Status))
        {
            return Build(
                "No active task. Start preflight for the next governed task.",
                hasTask: false, current: LifecycleStageKey.Idle,
                stages: Markers(m => m.Key == LifecycleStageKey.Idle ? StageState.Current : StageState.Waiting),
                buttons: new[] { "START_PREFLIGHT" });
        }

        // ---- 1. control validated (cycle closed) ----
        if (s.Status == "CONTROL_VALIDATED")
        {
            return Build(
                AppendAdvisory("Development cycle complete. Start the next preflight.", s),
                hasTask: true, current: LifecycleStageKey.Done,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Done ? StageState.Current : StageState.Complete),
                buttons: new[] { "START_PREFLIGHT", "OPEN_DETAIL" });
        }

        // ---- 2. control validation failed ----
        if (s.Status == "CONTROL_VALIDATION_FAILED" || IsConsistencyFailed(s))
        {
            return Build(
                AppendAdvisory("Resolve workbook-control inconsistencies before continuing.", s),
                hasTask: true, current: LifecycleStageKey.ControlValidation,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.ControlValidation ? StageState.Failed
                    : m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.ControlValidation) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "OPEN_CONSISTENCY_REPORT", "OPEN_DETAIL" },
                failure: new FailureInfo("CONTROL_VALIDATION", "Workbook Validation", s.ConsistencyValidatedAtUtc,
                    s.ConsistencyFailureDetail ?? "controlValidationResult != PASS",
                    "Resolve the reported workbook-control inconsistencies, then re-run DB-M11."),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 3. completion written -> validate workbook ----
        // The completion.json fallback is gated on the completion belonging to the
        // CURRENT change so a previous cycle's stale completion.json never hijacks a
        // fresh PREFLIGHTED/RESERVED state (parallel lane scenario).
        if (s.Status == "COMPLETION_WRITTEN"
            || (s.CompletionWritten && CompletionMatchesCurrent(s)
                && s.Status is not ("CONTROL_VALIDATED" or "PREFLIGHTED" or "RESERVED" or "AWAITING_CHATGPT_PROMPT")))
        {
            return Build(
                AppendAdvisory("Run workbook consistency validation.", s),
                hasTask: true, current: LifecycleStageKey.ControlValidation,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.ControlValidation ? StageState.Current
                    : m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.ControlValidation) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "VALIDATE_WORKBOOK", "OPEN_COMPLETION_REPORT", "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 3.5. trial cycle safe stop (DB-M08 routed) ----
        // A trial PASS must STOP here. M10 governed completion is never applicable
        // to disposable trial evidence; the cycle intentionally ends. The next
        // governed action is CLOSE_TRIAL_CYCLE (DB-M12.4): close the trial cycle,
        // release the reservation, preserve the evidence, then start a fresh cycle.
        if (s.TrialCycleSafeStop && s.TrialMode)
        {
            return Build(
                "TRIAL cycle complete. Stop at TRIAL_CYCLE_SAFE_STOP. M10 governed completion is NOT applicable to trial evidence. Close the trial cycle to release the reservation.",
                hasTask: true, current: LifecycleStageKey.Done,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Claude ? StageState.Complete
                    : m.Key == LifecycleStageKey.Completion ? StageState.Blocked
                    : m.Key == LifecycleStageKey.Done ? StageState.Current
                    : IsBefore(m.Key, LifecycleStageKey.Claude) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "CLOSE_TRIAL_CYCLE", "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 3.5b. trial cycle closed (DB-M12.4) ----
        // The proving cycle is closed and its reservation released. M10 remains not
        // applicable; the roadmap node is NOT completed. A fresh proving cycle may
        // now start (M03 excludes the proven item from re-selection).
        if (s.TrialCycleClosed && s.TrialMode)
        {
            return Build(
                "TRIAL CYCLE CLOSED. The trial evidence is preserved and the reservation is released; the roadmap node is NOT completed and M10 was NOT run. Start the next proving cycle.",
                hasTask: true, current: LifecycleStageKey.Done,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Claude ? StageState.Complete
                    : m.Key == LifecycleStageKey.Completion ? StageState.Blocked
                    : m.Key == LifecycleStageKey.Done ? StageState.Current
                    : IsBefore(m.Key, LifecycleStageKey.Claude) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "START_NEXT_CYCLE", "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 3.6. governance issue / human decision required ----
        if (s.Status == "GOVERNANCE_ISSUE")
        {
            return Build(
                "A governance issue was raised. The OPERATOR must review it; DevBridge never hides or auto-resolves governance issues.",
                hasTask: true, current: LifecycleStageKey.Claude,
                stages: Markers(m => m.Key == LifecycleStageKey.Claude ? StageState.Failed : StageState.Waiting),
                buttons: new[] { "REVIEW_GOVERNANCE_ISSUE", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                failure: new FailureInfo("GOVERNANCE", "Governance", s.ClaudeReviewedAtUtc,
                    "decision=GOVERNANCE_ISSUE",
                    "Review the governance issue with the operator; do not proceed to completion."),
                residuals: s.ResidualObservations.Count);
        }
        if (s.Status == "HUMAN_DECISION_REQUIRED")
        {
            return Build(
                "A human decision is required before this cycle can continue.",
                hasTask: true, current: LifecycleStageKey.Claude,
                stages: Markers(m => m.Key == LifecycleStageKey.Claude ? StageState.Failed : StageState.Waiting),
                buttons: new[] { "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                failure: new FailureInfo("HUMAN_DECISION", "Human Decision", s.ClaudeReviewedAtUtc,
                    "decision=HUMAN_DECISION_REQUIRED",
                    "Surface the required human decision to the operator."),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 3.7. real-mode human Git gates (DB-GH01) ----
        // Claude PASS in REAL mode does NOT arm completion. A human must create,
        // review, and MERGE the PR first, and the merge must be CONFIRMED — DevBridge
        // never approves its own PR, never merges automatically, never infers a merge.
        if (IsRealGitGateState(s))
        {
            bool mergeConfirmed = GitLifecycle.MergeConfirmed(s.HumanGitState);
            if (mergeConfirmed && s.M10Eligibility?.Eligible == true)
            {
                return Build(
                    "Human merge confirmed and all completion gates are satisfied. Run governed completion.",
                    hasTask: true, current: LifecycleStageKey.Completion,
                    stages: Markers(m =>
                        m.Key == LifecycleStageKey.Completion ? StageState.Current
                        : m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                        : IsBefore(m.Key, LifecycleStageKey.Completion) ? StageState.Complete
                        : StageState.Waiting),
                    buttons: new[] { "RUN_GOVERNED_COMPLETION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                    residuals: s.ResidualObservations.Count);
            }
            if (mergeConfirmed)
            {
                string reason = s.M10Eligibility?.Instruction ?? "Completion eligibility not satisfied.";
                return Build(reason,
                    hasTask: true, current: LifecycleStageKey.Completion,
                    stages: Markers(m => m.Key == LifecycleStageKey.Completion ? StageState.Blocked : StageState.Waiting),
                    buttons: new[] { "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                    failure: new FailureInfo("M10", "Completion", null,
                        s.M10Eligibility?.Token ?? "BLOCKED", reason),
                    residuals: s.ResidualObservations.Count);
            }
            string guidance = s.HumanGitState == HumanGitGateState.ClaudeReviewPassed
                ? "Claude PASS accepted in REAL mode. Create the PR and have a human review it; DevBridge never creates PRs or approves its own PR."
                : s.GitHumanGuidance ?? "Complete the human Git gate before any governed completion.";
            return Build(guidance,
                hasTask: true, current: LifecycleStageKey.Completion,
                stages: Markers(m => m.Key == LifecycleStageKey.Completion ? StageState.Current : StageState.Waiting),
                buttons: new[] { "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 4. claude fix required (DB-M09) ----
        // A FIX decision keeps the cycle on the fix loop UNTIL a FRESH DB-M06
        // verification of the corrected attempt lands (VerifiedAtUtc > ClaudeReviewedAtUtc).
        // Once re-verified, the historical FIX no longer blocks the normal verified flow
        // (the corrected delta goes back to Claude). While a FIX is live on the governed
        // M09 position, the correction loop offers RECONCILE CORRECTION (DB-M15) and -
        // once an externally-completed CORRECT_CURRENT_ATTEMPT has been reconciled as a
        // detected delta - re-verification of the corrected implementation (DB-M06).
        bool fixLive = s.ClaudeFixRequired || (s.ClaudeDecision is not null && s.ClaudeDecision.StartsWith("FAIL", StringComparison.OrdinalIgnoreCase));
        if (fixLive && !FixReVerified(s))
        {
            if (s.Status == "DB_M09_FIX_REQUIRED" && s.CorrectionReconciled)
            {
                // DB-M15 reconciled the corrected implementation -> re-verify it, then
                // Claude re-reviews the corrected delta.
                return Build(
                    "The corrected implementation was detected and reconciled. Run verification on the corrected delta, then re-review the task in Claude.",
                    hasTask: true, current: LifecycleStageKey.FixLoop,
                    stages: Markers(m =>
                        m.Key == LifecycleStageKey.Claude ? StageState.Failed
                        : m.Key == LifecycleStageKey.FixLoop ? StageState.Current
                        : m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                        : IsBefore(m.Key, LifecycleStageKey.Claude) ? StageState.Complete
                        : StageState.Waiting),
                    buttons: new[] { "RUN_VERIFICATION", "COPY_FIX_CONTEXT", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                    failure: new FailureInfo("CLAUDE", "Claude Review", s.ClaudeReviewedAtUtc,
                        s.ClaudeFixDetail ?? $"decision={s.ClaudeDecision}",
                        "Address the findings, regenerate the implementation prompt, and re-run implementation + verification."),
                    residuals: s.ResidualObservations.Count);
            }
            // Governed M09 position: the correction loop owns the lifecycle. RECONCILE
            // CORRECTION reconciles a CORRECT_CURRENT_ATTEMPT implemented OUTSIDE
            // DevBridge without ever leaving the M09 position.
            if (s.Status == "DB_M09_FIX_REQUIRED")
            {
                string instruction = s.Artifacts.FixContext
                    ? "Claude found issues. Copy the correction context to ChatGPT. When the CORRECT_CURRENT_ATTEMPT is implemented outside DevBridge, run RECONCILE CORRECTION."
                    : "Claude found issues. Send the fix context to ChatGPT.";
                var m09Buttons = s.Artifacts.FixContext
                    ? new[] { "COPY_FIX_CONTEXT", "RECONCILE_CORRECTION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }
                    : new[] { "RECONCILE_CORRECTION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" };
                return Build(instruction,
                    hasTask: true, current: LifecycleStageKey.FixLoop,
                    stages: Markers(m =>
                        m.Key == LifecycleStageKey.Claude ? StageState.Failed
                        : m.Key == LifecycleStageKey.FixLoop ? StageState.Current
                        : m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                        : IsBefore(m.Key, LifecycleStageKey.Claude) ? StageState.Complete
                        : StageState.Waiting),
                    buttons: m09Buttons,
                    failure: new FailureInfo("CLAUDE", "Claude Review", s.ClaudeReviewedAtUtc,
                        s.ClaudeFixDetail ?? $"decision={s.ClaudeDecision}",
                        "Address the findings, regenerate the implementation prompt, and re-run implementation + verification."),
                    residuals: s.ResidualObservations.Count);
            }
            // Legacy/non-governed M09 position (status advanced past DB_M09_FIX_REQUIRED):
            // preserve the historical fix-loop instruction and buttons exactly.
            return Build(
                "Claude found issues. Send the fix context to ChatGPT.",
                hasTask: true, current: LifecycleStageKey.FixLoop,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Claude ? StageState.Failed
                    : m.Key == LifecycleStageKey.FixLoop ? StageState.Current
                    : m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.Claude) ? StageState.Complete
                    : StageState.Waiting),
                buttons: s.Artifacts.FixContext
                    ? new[] { "COPY_FIX_CONTEXT", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }
                    : new[] { "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                failure: new FailureInfo("CLAUDE", "Claude Review", s.ClaudeReviewedAtUtc,
                    s.ClaudeFixDetail ?? $"decision={s.ClaudeDecision}",
                    "Address the findings, regenerate the implementation prompt, and re-run implementation + verification."),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 5. claude passed -> governed completion (gated, DB-GH01) ----
        // The trial-stop and real-Git-gate branches above fire first for their statuses.
        // This safety net still refuses completion whenever eligibility is not proven:
        // a trial can never complete, and a real cycle without a confirmed human merge or
        // with a changed protected roadmap fingerprint is blocked.
        if (s.ClaudeDecision is not null && s.ClaudeDecision.StartsWith("PASS", StringComparison.OrdinalIgnoreCase))
        {
            bool eligible = s.M10Eligibility?.Eligible == true;
            string instruction = eligible
                ? "Claude passed and all completion gates are satisfied. Run governed completion."
                : s.TrialMode
                    ? "Trial PASS accepted. M10 governed completion is NOT applicable to trial evidence; the cycle stops here."
                    : s.M10Eligibility?.Instruction ?? "Claude passed, but completion gates are not all satisfied.";
            return Build(instruction,
                hasTask: true, current: LifecycleStageKey.Completion,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Completion ? (eligible ? StageState.Current : StageState.Blocked)
                    : m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.Completion) ? StageState.Complete
                    : StageState.Waiting),
                buttons: eligible
                    ? new[] { "RUN_GOVERNED_COMPLETION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }
                    : new[] { "OPEN_REVIEW_PACKET", "OPEN_DETAIL" },
                failure: eligible ? null : new FailureInfo("M10", "Completion", null,
                    s.M10Eligibility?.Token ?? "BLOCKED", instruction),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 7. verification failed (checked BEFORE the VERIFIED status shortcut:
        //      explicit failure evidence always wins over a stale status field) ----
        if (IsVerificationFailed(s))
        {
            return Build(
                "Verification failed. Review failures and re-run verification.",
                hasTask: true, current: LifecycleStageKey.Verification,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Verification ? StageState.Failed
                    : m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.Verification) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "OPEN_VERIFICATION_REPORT", "RUN_VERIFICATION", "OPEN_DETAIL" },
                failure: new FailureInfo("VERIFICATION", "Verification", s.VerifiedAtUtc,
                    s.VerificationFailureDetail ?? "primaryResult=VERIFICATION_FAILED",
                    "Open the verification report, fix the failures in the implementation, then re-run deterministic verification."),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 6. verified -> awaiting claude review ----
        if (s.Status == "VERIFIED" || (IsVerificationPassed(s) && s.ClaudeDecision is null && !s.Artifacts.ClaudeReviewResult))
        {
            var buttons = new List<string>();
            // COPY + RECORD only unlock for the CURRENT CLAUDE REVIEW MANIFEST (dbM07
            // ready stamp for this node/change + manifest file). A legacy REVIEW_PACKET.md
            // from a previous cycle is never the current manifest -> CREATE is shown so a
            // fresh manifest is generated instead of copying stale context.
            if (s.ClaudeReviewManifestReady)
            {
                buttons.Add("COPY_FOR_CLAUDE");
                buttons.Add("RECORD_CLAUDE_RESULT"); // once Claude returns its verdict, record it (DB-M07/08)
                buttons.Add("OPEN_REVIEW_PACKET");
            }
            else { buttons.Add("CREATE_CLAUDE_REVIEW_PACKAGE"); }
            buttons.Add("OPEN_VERIFICATION_REPORT");
            buttons.Add("OPEN_DETAIL");
            return Build(
                "Verification passed. Review this task in Claude.",
                hasTask: true, current: LifecycleStageKey.Claude,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Claude ? StageState.Current
                    : m.Key == LifecycleStageKey.FixLoop || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.Claude) ? StageState.Complete
                    : StageState.Waiting),
                buttons: buttons.ToArray(),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 8. implementation in progress (prompt present, not yet verified) ----
        if (s.Artifacts.DeepSeekPromptHasImplementation && !s.Artifacts.VerificationReport && s.ClaudeDecision is null)
        {
            return Build(
                "Run this prompt in DeepSeek through Claude Code. When implementation is finished, run deterministic verification.",
                hasTask: true, current: LifecycleStageKey.DeepSeek,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.DeepSeek ? StageState.Current
                    : m.Key == LifecycleStageKey.Verification || m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.DeepSeek) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "COPY_FOR_DEEPSEEK", "OPEN_DEEPSEEK_PROMPT", "RUN_VERIFICATION", "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 9. awaiting chatgpt prompt (handoff done) ----
        if (s.Status == "AWAITING_CHATGPT_PROMPT")
        {
            if (s.Artifacts.ChatGptHandoff && !s.Artifacts.DeepSeekPromptHasImplementation)
            {
                // DB-M12.3 M05 gate: COPY_TO_CHATGPT is only exposed when the handoff
                // passes the 14-check zero-context validation. A present-but-invalid
                // handoff is CHATGPT_HANDOFF_NOT_READY — re-run generation, never copy.
                if (s.HandoffReady)
                {
                    return Build(
                        "Copy this task context to ChatGPT.",
                        hasTask: true, current: LifecycleStageKey.ChatGpt,
                        stages: Markers(m =>
                            m.Key == LifecycleStageKey.ChatGpt ? StageState.Current
                            : m.Key == LifecycleStageKey.DeepSeek || m.Key == LifecycleStageKey.Verification || m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                            : IsBefore(m.Key, LifecycleStageKey.ChatGpt) ? StageState.Complete
                            : StageState.Waiting),
                        buttons: new[] { "COPY_FOR_CHATGPT", "OPEN_DETAIL" },
                        residuals: s.ResidualObservations.Count);
                }
                return Build(
                    "ChatGPT handoff is present but fails the zero-context validation (CHATGPT_HANDOFF_NOT_READY). Re-run handoff generation; COPY TO CHATGPT stays disabled until the 14 checks pass.",
                    hasTask: true, current: LifecycleStageKey.ChatGpt,
                    stages: Markers(m =>
                        m.Key == LifecycleStageKey.ChatGpt ? StageState.Current
                        : m.Key == LifecycleStageKey.DeepSeek || m.Key == LifecycleStageKey.Verification || m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                        : IsBefore(m.Key, LifecycleStageKey.ChatGpt) ? StageState.Complete
                        : StageState.Waiting),
                    buttons: new[] { "CREATE_CHATGPT_HANDOFF", "OPEN_DETAIL" },
                    residuals: s.ResidualObservations.Count);
            }
            // handoff missing -> re-run handoff
            return Build(
                "ChatGPT handoff not found. Re-run the handoff generation.",
                hasTask: true, current: LifecycleStageKey.ChatGpt,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.ChatGpt ? StageState.Current : StageState.Waiting),
                buttons: new[] { "CREATE_CHATGPT_HANDOFF", "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 10. reserved -> prepare handoff ----
        if (s.Status == "RESERVED")
        {
            return Build(
                "Prepare the ChatGPT handoff.",
                hasTask: true, current: LifecycleStageKey.ChatGpt,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.ChatGpt ? StageState.Current
                    : m.Key == LifecycleStageKey.DeepSeek || m.Key == LifecycleStageKey.Verification || m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.ChatGpt) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "CREATE_CHATGPT_HANDOFF", "OPEN_DETAIL" },
                residuals: s.ResidualObservations.Count);
        }

        // ---- 11. preflighted ----
        if (s.Status == "PREFLIGHTED")
        {
            bool clear = s.PreflightVerdict is not null && s.PreflightVerdict.StartsWith("CLEAR", StringComparison.OrdinalIgnoreCase);
            if (clear)
            {
                return Build(
                    "Reserve this task before implementation.",
                    hasTask: true, current: LifecycleStageKey.Reservation,
                    stages: Markers(m =>
                        m.Key == LifecycleStageKey.Reservation ? StageState.Current
                        : m.Key == LifecycleStageKey.ChatGpt || m.Key == LifecycleStageKey.DeepSeek || m.Key == LifecycleStageKey.Verification || m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                        : IsBefore(m.Key, LifecycleStageKey.Reservation) ? StageState.Complete
                        : StageState.Waiting),
                    buttons: new[] { "RESERVE_TASK", "OPEN_PREFLIGHT_REPORT", "OPEN_DETAIL" },
                    residuals: s.ResidualObservations.Count);
            }
            return Build(
                "Preflight found blocking issues. Resolve them before reserving.",
                hasTask: true, current: LifecycleStageKey.Preflight,
                stages: Markers(m =>
                    m.Key == LifecycleStageKey.Preflight ? StageState.Failed
                    : m.Key == LifecycleStageKey.Reservation ? StageState.Blocked
                    : m.Key == LifecycleStageKey.ChatGpt || m.Key == LifecycleStageKey.DeepSeek || m.Key == LifecycleStageKey.Verification || m.Key == LifecycleStageKey.Claude || m.Key == LifecycleStageKey.Completion || m.Key == LifecycleStageKey.ControlValidation || m.Key == LifecycleStageKey.Done ? StageState.Waiting
                    : IsBefore(m.Key, LifecycleStageKey.Preflight) ? StageState.Complete
                    : StageState.Waiting),
                buttons: new[] { "OPEN_PREFLIGHT_REPORT", "OPEN_DETAIL" },
                failure: new FailureInfo("PREFLIGHT", "Preflight", s.SelectedAtDisplay,
                    s.PreflightBlockingReasons ?? "preflightVerdict != CLEAR",
                    "Resolve the blocking reasons recorded in the preflight report, then re-run DB-M03 preflight."),
                residuals: s.ResidualObservations.Count);
        }

        // ---- 12. fallback: recognized task, unknown/mismatched lifecycle ----
        return Build(
            "Active task recognized but its lifecycle state is not mapped. Review the task detail.",
            hasTask: true, current: LifecycleStageKey.Idle,
            stages: Markers(_ => StageState.Waiting),
            buttons: new[] { "OPEN_DETAIL" },
            residuals: s.ResidualObservations.Count);
    }

    // ------------------------------------------------------------------ helpers

    /// <summary>A REAL-mode cycle positioned on the human Git gate.</summary>
    private static bool IsRealGitGateState(DevBridgeState s)
        => s.Mode == DevBridgeOperatingMode.RealNexusDevelopment
           && s.Status is "CLAUDE_REVIEW_PASSED_REAL" or "AWAITING_HUMAN_PR" or "PR_OPEN"
               or "AWAITING_HUMAN_REVIEW" or "AWAITING_HUMAN_MERGE" or "MERGED"
               or "READY_FOR_GOVERNED_COMPLETION";

    /// <summary>Advisory-only Role B recommendation (DB-M11). Never a blocking verdict.</summary>
    private static string AppendAdvisory(string instruction, DevBridgeState s)
        => s.M11Recommendation is { ClaudeWorkbookReviewRecommended: true }
            ? instruction + " ADVISORY: CLAUDE_WORKBOOK_REVIEW_RECOMMENDED (schedule a read-only Role B workbook review)."
            : instruction;

    private static bool IsVerificationPassed(DevBridgeState s)
        => s.VerificationPrimaryResult is not null
           && s.VerificationPrimaryResult.StartsWith("VERIFICATION_PASSED", StringComparison.OrdinalIgnoreCase);

    private static bool IsVerificationFailed(DevBridgeState s)
        => s.VerificationPrimaryResult is not null
           && s.VerificationPrimaryResult.StartsWith("VERIFICATION_FAILED", StringComparison.OrdinalIgnoreCase);

    private static bool IsConsistencyFailed(DevBridgeState s)
        => s.ConsistencyResult is not null
           && !s.ConsistencyResult.StartsWith("PASS", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// A FIX decision is superseded once a FRESH DB-M06 verification of the corrected
    /// attempt lands (VerifiedAtUtc later than ClaudeReviewedAtUtc). Both timestamps are
    /// written as ISO-8601 UTC, so an ordinal string compare is chronological.
    /// </summary>
    private static bool FixReVerified(DevBridgeState s)
    {
        if (string.IsNullOrWhiteSpace(s.VerifiedAtUtc) || string.IsNullOrWhiteSpace(s.ClaudeReviewedAtUtc)) return false;
        return string.CompareOrdinal(s.VerifiedAtUtc, s.ClaudeReviewedAtUtc) > 0;
    }

    private static bool CompletionMatchesCurrent(DevBridgeState s)
    {
        if (string.IsNullOrWhiteSpace(s.CompletionChangeId)) return false;
        if (!string.IsNullOrWhiteSpace(s.ChangeId)) return s.CompletionChangeId == s.ChangeId;
        return s.CompletionNodeId is not null && s.CompletionNodeId == s.NodeId;
    }

    private static bool IsBefore(LifecycleStageKey key, LifecycleStageKey before)
    {
        int a = Array.FindIndex(StageCatalog, t => t.Key == key);
        int b = Array.FindIndex(StageCatalog, t => t.Key == before);
        return a >= 0 && b >= 0 && a < b;
    }

    private static List<LifecycleStageState> Markers(Func<LifecycleStageState, StageState> stateFor)
    {
        var list = new List<LifecycleStageState>();
        foreach (var (key, label) in StageCatalog)
        {
            var st = new LifecycleStageState(key, label, StageState.Waiting);
            list.Add(st with { State = stateFor(st) });
        }
        return list;
    }

    private static NextActionInfo Build(string instruction, bool hasTask, LifecycleStageKey current,
        List<LifecycleStageState> stages, string[] buttons, FailureInfo? failure = null, int residuals = 0)
    {
        var currentStage = current == LifecycleStageKey.Idle ? null : current.ToString();
        return new NextActionInfo
        {
            Instruction = instruction,
            HasActiveTask = hasTask,
            CurrentStage = currentStage,
            Stages = stages,
            EnabledButtons = buttons.ToList(),
            Failure = failure,
            ResidualObservationCount = residuals,
        };
    }
}
