// OperatorCommandService.cs — DB-M12.1 command orchestration + DB-M12.2 one-command
// contract.
//
// UI -> OperatorCommandService -> existing DB-M03..DB-M11 script -> refresh state
// -> validate the expected lifecycle transition -> result.
//
// The service performs NO governance itself: it launches the canonical backend
// scripts and checks that the REFRESHED state satisfies the transition the command
// declared (Part 7). A process that exits 0 but leaves the state untouched is a
// BACKEND_STATE_MISMATCH, never a success. Guided/manual commands are never
// auto-invoked — they return MANUAL_ACTION_REQUIRED with the recorded reason.
//
// DB-M12.2 additions (all behind the existing surface):
//   * optional LifecycleCommandInput (one-command contract) validated before run
//     (NodeId/ChangeId identity, explicit Mode match, Actor);
//   * StaleStateGuard on ExpectedCurrentState (STALE_GOVERNANCE_STATE);
//   * WorkbookWriterGate serialization for WritesWorkbook commands
//     (WORKBOOK_WRITER_BUSY);
//   * the input is passed into the scripts via the environment channel
//     (DB_COMMAND_INPUT_* overrides), so a script never hard-codes the task;
//   * the result carries the script's DB-M12.2 markers (ResultCodeToken,
//     WorkbookModified, NexusSourceModified, GitModified, RequiresHumanAction,
//     HumanActionType, EvidenceReferences) plus the CorrelationId.
using System.Text;
using System.Text.Json;

namespace DevBridge.Engine;

public static class OperatorCommandService
{
    /// <summary>Execute one operator command against the live DevBridge state.</summary>
    public static OperatorCommandResult Execute(DevBridgeConfig cfg, OperatorCommand cmd, IScriptProcessRunner runner, LifecycleCommandInput? input = null, IDevelopmentControlProvider? provider = null)
    {
        // B03-1: runtime writer-lock access now goes through IDevelopmentControlProvider
        // with an explicit role, never inferred. Today Forge orchestration only writes
        // the Foundation workbook, so Foundation is the explicit role passed below — not
        // a default silently baked into the provider. A caller that already resolved a
        // provider (e.g. from a role-aware host) may pass it in; otherwise this wraps the
        // same cfg the legacy call sites already pass, so behavior is unchanged.
        var ctrlProvider = provider ?? new ExcelDevelopmentControlProvider(cfg);
        var started = DateTime.UtcNow;
        var prev = StateReader.Read(cfg);
        string prevStatus = Normalize(prev.Status);
        string prevVerdict = Normalize(prev.PreflightVerdict);
        string? correlation = input?.CorrelationId;

        // ---- input validation (one-command contract; scripts only) ----
        if (cmd.Kind == OperatorCommandKind.Script)
        {
            var (ok, error) = LifecycleCommandInputValidation.Validate(input, cmd, prev);
            if (!ok)
            {
                return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                    CommandResultCode.FAILED, started, error!,
                    summary: cmd.Description, correlation: correlation);
            }
        }

        // ---- guided / manual: never fabricate an automatic run ----
        if (cmd.Kind == OperatorCommandKind.GuidedManual)
        {
            return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                CommandResultCode.MANUAL_ACTION_REQUIRED, started,
                $"Manual action required — {cmd.GuidedReason ?? "no durable backend entry point."}",
                summary: cmd.Description, correlation: correlation);
        }

        // ---- navigation / clipboard are handled by the UI, not the executor ----
        if (cmd.Kind is OperatorCommandKind.Navigation or OperatorCommandKind.Clipboard)
        {
            return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                CommandResultCode.MANUAL_ACTION_REQUIRED, started,
                $"'{cmd.DisplayName}' is a read-only UI action (no backend script).",
                summary: cmd.Description, correlation: correlation);
        }

        // ---- stale-state guard: an expected current state must match the live state ----
        var stale = StaleStateGuard.Check(input?.ExpectedCurrentState ?? cmd.ExpectedCurrentState, prevStatus);
        if (!stale.Ok)
        {
            return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                CommandResultCode.BLOCKED, started, stale.Rejection!,
                summary: cmd.Description, correlation: correlation);
        }

        // ---- state gate (UI protection on top of the backend's own revalidation) ----
        if (cmd.RequiredStates.Length > 0 && !cmd.RequiredStates.Contains(prevStatus, StringComparer.Ordinal))
        {
            return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                CommandResultCode.BLOCKED, started,
                $"Cannot run {cmd.CommandId} from state '{prevStatus}'; requires {string.Join(" | ", cmd.RequiredStates)}.",
                summary: cmd.Description, correlation: correlation);
        }

        // ---- writer serialization: only one governed workbook writer at a time ----
        bool lockHeld = false;
        if (cmd.WritesWorkbook)
        {
            var gate = ctrlProvider.TryAcquireWriterLock(DevelopmentControlRole.Foundation, input?.Actor ?? "operator");
            if (!gate.Acquired)
            {
                return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                    CommandResultCode.BLOCKED, started, gate.Message!,
                    summary: cmd.Description, correlation: correlation);
            }
            lockHeld = true;
        }

        try
        {
            // ---- run the backend scripts in order ----
            var combined = new StringBuilder();
            string errorSummary = "";
            ScriptOutcome lastOutcome = new(null, null, null);
            var inputEnv = BuildInputEnvironment(input);

            foreach (var script in cmd.Scripts)
            {
                string path = cfg.ResolveScriptPath(script);
                var r = runner.Run(path, cmd.TimeoutMs, inputEnv);

                combined.AppendLine($"===== {script} (exit {r.ExitCode}, {r.Elapsed.TotalSeconds:F1}s, {(r.TimedOut ? "TIMED OUT" : "ok")}) =====");
                combined.AppendLine(string.IsNullOrWhiteSpace(r.Combined) ? "(no output)" : r.Combined);

                var outcome = ScriptOutcomeParser.Parse(r.Stdout);
                lastOutcome = outcome;

                if (r.TimedOut)
                {
                    return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                        CommandResultCode.BLOCKED, started,
                        $"{script} timed out after {cmd.TimeoutMs / 1000}s. The backend state was not assumed — refresh to re-check.",
                        summary: CommandResultText.Compact(combined.ToString()), full: combined.ToString(), error: r.Stderr,
                        outcome: outcome, correlation: correlation);
                }

                if (outcome.IsGovernedStop)
                {
                    return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                        CommandResultCode.BLOCKED, started,
                        $"{script} reported a governed STOP ({outcome.OutcomeToken}). No state change was forced.",
                        summary: CommandResultText.Compact(combined.ToString()), full: combined.ToString(), error: r.Stderr,
                        outcome: outcome, correlation: correlation);
                }

                if (r.ExitCode != 0)
                {
                    return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                        CommandResultCode.FAILED, started,
                        $"{script} failed with exit code {r.ExitCode}. Review the script output below.",
                        summary: CommandResultText.Compact(combined.ToString()), full: combined.ToString(), error: r.Stderr,
                        outcome: outcome, correlation: correlation);
                }

                if (outcome.ResultPass == false)
                {
                    return Build(cmd, prevStatus, prevStatus, prev.NextAllowedAction,
                        CommandResultCode.BLOCKED, started,
                        $"{script} reported DB*_RESULT_PASS: False. Governed check failed; no state change forced.",
                        summary: CommandResultText.Compact(combined.ToString()), full: combined.ToString(), error: r.Stderr,
                        outcome: outcome, correlation: correlation);
                }
            }

            // ---- refresh state and validate the declared lifecycle transition ----
            var next = StateReader.Read(cfg);
            string newStatus = Normalize(next.Status);
            string nextAction = Normalize(next.NextAllowedAction);

            bool mismatch = !string.IsNullOrEmpty(cmd.ResultingExpectedState)
                            && newStatus != cmd.ResultingExpectedState;

            // DB-M12.2 state-first hardening: a workbook-writing command that claims
            // COMPLETED must have actually moved the lifecycle to COMPLETION_WRITTEN.
            if (!mismatch && cmd.WritesWorkbook && lastOutcome.OutcomeToken == "COMPLETED" && newStatus != "COMPLETION_WRITTEN")
                mismatch = true;

            if (mismatch)
            {
                return Build(cmd, prevStatus, newStatus, nextAction,
                    CommandResultCode.FAILED, started,
                    $"BACKEND_STATE_MISMATCH — expected state '{cmd.ResultingExpectedState}' but the refreshed state is '{newStatus}'. " +
                    "The command is not assumed to have succeeded despite exit code 0.",
                    summary: CommandResultText.Compact(combined.ToString()), full: combined.ToString(), error: errorSummary,
                    mismatch: true, outcome: lastOutcome, correlation: correlation,
                    generated: DiscoverGeneratedArtifacts(cfg, cmd, next));
            }

            return Build(cmd, prevStatus, newStatus, nextAction,
                CommandResultCode.SUCCESS, started,
                $"OK — {cmd.DisplayName} completed; state is now '{newStatus}'.",
                summary: CommandResultText.Compact(combined.ToString()), full: combined.ToString(), error: errorSummary,
                outcome: lastOutcome, correlation: correlation,
                generated: DiscoverGeneratedArtifacts(cfg, cmd, next));
        }
        finally
        {
            if (lockHeld) ctrlProvider.ReleaseWriterLock(DevelopmentControlRole.Foundation);
        }
    }

    /// <summary>Pass the one-command input into the scripts via the environment
    /// channel (DB_COMMAND_INPUT_*), so scripts stay generic and never hard-code the task.</summary>
    private static IReadOnlyDictionary<string, string>? BuildInputEnvironment(LifecycleCommandInput? input)
    {
        if (input is null) return null;
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(input.NodeId)) env["DB_COMMAND_INPUT_NODE_ID"] = input.NodeId;
        if (!string.IsNullOrWhiteSpace(input.ChangeId)) env["DB_COMMAND_INPUT_CHANGE_ID"] = input.ChangeId;
        if (!string.IsNullOrWhiteSpace(input.Mode)) env["DB_COMMAND_INPUT_MODE"] = input.Mode;
        if (!string.IsNullOrWhiteSpace(input.Actor)) env["DB_COMMAND_INPUT_ACTOR"] = input.Actor;
        if (!string.IsNullOrWhiteSpace(input.CorrelationId)) env["DB_COMMAND_INPUT_CORRELATION_ID"] = input.CorrelationId;
        if (!string.IsNullOrWhiteSpace(input.ExpectedCurrentState)) env["DB_COMMAND_INPUT_EXPECTED_CURRENT_STATE"] = input.ExpectedCurrentState;
        if (input.Parameters is { Count: > 0 })
            env["DB_COMMAND_INPUT_PARAMETERS"] = JsonSerializer.Serialize(input.Parameters);
        return env.Count == 0 ? null : env;
    }

    /// <summary>Best-effort list of artifacts the command may have produced (for the
    /// operator to open). Only tasks\ files already present are listed.</summary>
    private static List<string> DiscoverGeneratedArtifacts(DevBridgeConfig cfg, OperatorCommand cmd, DevBridgeState next)
    {
        var list = new List<string>();
        foreach (var file in ArtifactFilesFor(cmd))
        {
            string p = Path.Combine(cfg.TasksDir, file);
            if (File.Exists(p)) list.Add(p);
        }
        return list;
    }

    private static string[] ArtifactFilesFor(OperatorCommand cmd) => cmd.CommandId switch
    {
        "START_PREFLIGHT" => new[] { "PREFLIGHT_REPORT.md", "NEXT_TASK.md" },
        "RESERVE_TASK" => new[] { "START_BASELINE.md" },
        "CREATE_CHATGPT_HANDOFF" => new[] { "CHATGPT_HANDOFF.md", "DEEPSEEK_PROMPT.md" },
        "RUN_VERIFICATION" => new[] { "VERIFICATION_REPORT.md" },
        "CREATE_CLAUDE_REVIEW_PACKAGE" => new[] { "REVIEW_PACKET.md", "CLAUDE_REVIEW_PACKAGE.md" },
        "COPY_FOR_CLAUDE" => new[] { "CLAUDE_REVIEW_PACKAGE.md" },
        "RECORD_CLAUDE_RESULT" => new[] { "CLAUDE_REVIEW_RESULT.md" },
        "CREATE_CORRECTION_CONTEXT" => new[] { "FIX_CONTEXT.md" },
        "RUN_GOVERNED_COMPLETION" => new[] { "COMPLETION_REPORT.md" },
        "CLOSE_TRIAL_CYCLE" => new[] { "TRIAL_CYCLE_CLOSURE_REPORT.md" },
        "START_NEXT_CYCLE" => new[] { "PREFLIGHT_REPORT.md", "NEXT_TASK.md" },
        "VALIDATE_WORKBOOK" => new[] { "WORKBOOK_CONSISTENCY_REPORT.md" },
        "CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE" => new[] { "CLAUDE_WORKBOOK_REVIEW_PACKET.md" },
        _ => Array.Empty<string>(),
    };

    private static OperatorCommandResult Build(
        OperatorCommand cmd, string prevStatus, string newStatus, string? nextAction,
        CommandResultCode code, DateTime started, string message,
        string? summary = null, string? full = null, string? error = null, bool mismatch = false,
        List<string>? generated = null, ScriptOutcome? outcome = null, string? correlation = null)
    {
        var artifacts = generated ?? new List<string>();
        var evidence = new List<string>(artifacts);
        if (outcome?.Evidence is not null)
            foreach (var e in outcome.Evidence)
                if (!evidence.Contains(e, StringComparer.OrdinalIgnoreCase)) evidence.Add(e);

        string resultToken = outcome?.ResultCode ?? outcome?.OutcomeToken ?? "";
        bool isNonWriteTerminal = resultToken is "TRIAL_COMPLETION_NOT_APPLICABLE" or "NO_ADVISORY_REVIEW_RECOMMENDED";

        return new OperatorCommandResult
        {
            CommandId = cmd.CommandId,
            DisplayName = cmd.DisplayName,
            Kind = cmd.Kind,
            StartedAtUtc = started,
            CompletedAtUtc = DateTime.UtcNow,
            ExitCode = code == CommandResultCode.SUCCESS ? 0 : 1,
            Result = code,
            StdoutSummary = summary ?? "",
            FullOutput = full ?? summary ?? "",
            ErrorSummary = error ?? "",
            GeneratedArtifacts = artifacts,
            PreviousState = prevStatus,
            NewState = newStatus,
            NextAllowedAction = Normalize(nextAction),
            Message = message,
            IsBackendStateMismatch = mismatch,
            ResultCodeToken = resultToken,
            EvidenceReferences = evidence,
            WorkbookModified = outcome?.WorkbookModified
                ?? (cmd.WritesWorkbook && code == CommandResultCode.SUCCESS && !isNonWriteTerminal),
            NexusSourceModified = outcome?.NexusSourceModified ?? false,
            GitModified = outcome?.GitModified ?? false,
            RequiresHumanAction = outcome?.RequiresHumanAction
                ?? (cmd.Kind == OperatorCommandKind.GuidedManual),
            HumanActionType = outcome?.HumanActionType ?? "",
            CorrelationId = correlation ?? "",
        };
    }

    private static string Normalize(string? s) => string.IsNullOrWhiteSpace(s) ? "NO_TASK" : s;
}

// ---- DB-M12.2 command availability vocabulary ----
public enum CommandAvailability
{
    Available,            // script command, runnable from the current lifecycle state
    NotApplicable,        // correct for this mode/position but performs no write (e.g. M10 in TRIAL)
    HumanActionRequired,  // no durable backend entry point (guided / navigation / clipboard)
    Blocked,              // cannot run from the current lifecycle state
    Busy,                 // the workbook writer lock is held by another process
}

public static class CommandAvailabilityEvaluator
{
    public static CommandAvailability Evaluate(DevBridgeConfig cfg, OperatorCommand cmd, IDevelopmentControlProvider? provider = null)
    {
        // B03-1: same provider-boundary migration as OperatorCommandService.Execute above —
        // explicit Foundation role, no silent inference, legacy behavior preserved.
        var ctrlProvider = provider ?? new ExcelDevelopmentControlProvider(cfg);
        var s = StateReader.Read(cfg);
        string status = string.IsNullOrWhiteSpace(s.Status) ? "NO_TASK" : s.Status;

        if (cmd.Kind is OperatorCommandKind.GuidedManual or OperatorCommandKind.Navigation or OperatorCommandKind.Clipboard)
            return CommandAvailability.HumanActionRequired;

        if (cmd.RequiredStates.Length > 0 && !cmd.RequiredStates.Contains(status, StringComparer.Ordinal))
            return CommandAvailability.Blocked;

        if (cmd.WritesWorkbook && ctrlProvider.IsWriterBusy(DevelopmentControlRole.Foundation))
            return CommandAvailability.Busy;

        if (cmd.CommandId == "RUN_GOVERNED_COMPLETION" && s.TrialMode && s.TrialCycleSafeStop)
            return CommandAvailability.NotApplicable;

        return CommandAvailability.Available;
    }
}
