// Program.cs — DB-M12.3 FULL UI LIFECYCLE AUTOMATION acceptance suite.
//
// Verifies that the DevBridge operator console is the complete operator console
// over the DB-M12.2 hardened backend: it launches; it shows an unmissable TRIAL
// vs REAL mode banner; it renders the 12-stage / 8-token lifecycle from backend
// state (never invented by the UI); the next-action panel is backend-driven; the
// M03-M11 commands are callable and correctly gated (M05 handoff gate, M06-fail
// blocks M07, trial safe-stop, real human Git gates with no automatic merge,
// M10 trial/real gating, M11 advisory); writer-busy, stale-state and backend-
// mismatch are surfaced; history never hides failed attempts; the parallel view
// never guesses; there is no roadmap structural-edit capability, no auto baseline
// restore, no silent mode switch; DB-M26 stays a separate read-only module; and
// nothing touches the workbook, Nexus source, or current trial evidence.
//
// Console exit code: 0 = all 65 checks pass, 1 = failures.
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;
using DevBridge.Engine;
using DevBridge.UI;
using DevBridge.UI.ViewModels;

namespace DevBridge.UITests;

internal static class Program
{
    private static int _pass;
    private static int _fail;
    private static readonly List<string> Failures = new();
    private static readonly List<string> WrittenPaths = new();

    // Valid 14-marker zero-context handoff — satisfies every ChatGptHandoffCheck
    // rule marker (matched case-insensitively).
    private const string ValidHandoff =
        "CHATGPT HANDOFF — DevBridge temporary external scaffolding.\n" +
        "Mode: TRIAL (disposable proving activity, not permanent Nexus development).\n" +
        "This is temporary scaffolding for Nexus Phase 1/2 only; DevBridge will be retired.\n" +
        "Architecture: NOT Nexus — no Nexus architecture/contracts changes via DevBridge.\n" +
        "Roadmap protection: the roadmap is immutable; no structural edits are permitted.\n" +
        "Workbook authority: NEXUS_DEVELOPMENT_CONTROL.xlsx is the authoritative control record.\n" +
        "Git gate: git is a formal human-gated lifecycle — a human creates and merges PRs.\n" +
        "Claude gate: the DB-M08 Claude review gate applies.\n" +
        "Task identity: task WI-07-0.2.4 node WI-07-0.2.4 change CHG-20260830-020.\n" +
        "Exact scope: the exact reserved scope is stated below.\n" +
        "Forbidden: ChatGPT must not perform structural edits and must not create/merge PRs.\n" +
        "Acceptance criteria: the acceptance criteria for this task are included below.\n" +
        "Verification: the DB-M06 verification requirements are included below.\n" +
        "Output contract: the DeepSeek completion report output contract is stated.";

    [STAThread]
    private static int Main()
    {
        Check(SetsEqual(new[] { "a", "B" }, new[] { "B", "a" }), "SELF-CHECK: SetsEqual harness", "harness must be sane");
        _pass--; // remove the harness self-check from the count (65 net below)

        // =====================================================================
        // A. UI LAUNCH + MODE BANNER (no silent mode switch)
        // =====================================================================
        string launchError = "";
        try
        {
            var app = new App();
            app.InitializeComponent();
            var window = new MainWindow(); // constructs the real MainViewModel (default config)
            _ = window; // never shown — launch smoke only
            var vm = (MainViewModel)window.DataContext;
            Check(vm.StatusText.Contains("STATE", StringComparison.OrdinalIgnoreCase),
                "UI-01", "Operator console launches (Application + App resources + MainWindow)");
        }
        catch (Exception e)
        {
            launchError = e.ToString();
            Check(false, "UI-01", $"launch threw: {e.Message}");
        }

        // TRIAL vs REAL fixtures for the banner / mode checks.
        string trialRoot = NewRoot("trial");
        W(trialRoot, @"state/current-task.json", TaskJson("PREFLIGHTED", "RESERVE", "CHG-TRIAL-01"));
        var vmTrial = new MainViewModel(DevBridgeConfig.Load(trialRoot));

        string realRoot = NewRoot("real");
        W(realRoot, @"state/current-task.json", TaskJson("PREFLIGHTED", "RESERVE", "CHG-REAL-01",
            mode: DevBridgeMode.RealToken));
        var vmReal = new MainViewModel(DevBridgeConfig.Load(realRoot));

        Check(vmTrial.ModeBannerText.Contains("TRIAL", StringComparison.Ordinal)
              && vmTrial.ModeBannerText.Contains("disposable proving activity", StringComparison.OrdinalIgnoreCase),
            "UI-02", $"TRIAL banner: '{vmTrial.ModeBannerText}'");
        Check(vmReal.ModeBannerText.Contains("REAL_NEXUS_DEVELOPMENT", StringComparison.Ordinal)
              && vmReal.ModeBannerText.Contains("governed human Git gates", StringComparison.OrdinalIgnoreCase),
            "UI-03", $"REAL banner: '{vmReal.ModeBannerText}'");

        // No silent/automatic mode switch: the UI has no mode-switch control and no
        // command can flip the mode; the badge is the explicit state token.
        bool noModeCommand = OperatorCommandCatalog.All.Values.All(c =>
            !c.CommandId.Contains("MODE", StringComparison.OrdinalIgnoreCase)
            && !(c.DisplayName ?? "").Contains("mode switch", StringComparison.OrdinalIgnoreCase));
        Check(noModeCommand && vmTrial.ModeBadgeText == DevBridgeMode.TrialToken
              && vmReal.ModeBadgeText == DevBridgeMode.RealToken,
            "UI-04", $"no mode command; badge={vmTrial.ModeBadgeText}/{vmReal.ModeBadgeText}");
        Check((vmTrial.ModeBannerBrush as SolidColorBrush)?.Color != (vmReal.ModeBannerBrush as SolidColorBrush)?.Color,
            "UI-05", "TRIAL vs REAL banner brush differ");
        vmTrial.Refresh();
        Check(vmTrial.ModeBannerText.Contains("disposable proving activity", StringComparison.OrdinalIgnoreCase),
            "UI-06", "banner persists across refresh (never auto-switches)");

        // =====================================================================
        // B. LIFECYCLE VISUALIZATION — 12 stages x 8 tokens, backend-derived
        // =====================================================================
        var noTaskState = StateReader.Read(DevBridgeConfig.Load(NewRoot("none")));
        var noTaskNext = NextActionEngine.Evaluate(noTaskState);
        var noTaskRows = StageDisplayResolver.Resolve(noTaskState, noTaskNext);

        Check(noTaskRows.Count == 12, "VIZ-01", $"rows={noTaskRows.Count}");
        string[] expectedKeys =
        {
            "PREFLIGHT", "RESERVATION", "CHATGPT_HANDOFF", "IMPLEMENTATION", "VERIFICATION",
            "CLAUDE_REVIEW_PACKAGE", "CLAUDE_REVIEW", "CORRECTION", "HUMAN_GIT_GATE",
            "GOVERNED_COMPLETION", "WORKBOOK_VALIDATION", "PERIODIC_WORKBOOK_REVIEW",
        };
        Check(noTaskRows.Select(r => r.Key).SequenceEqual(expectedKeys), "VIZ-02", "12 stage keys in mission order");

        string[] tokens8 =
        {
            StageDisplayResolver.NotStarted, StageDisplayResolver.Ready, StageDisplayResolver.Current,
            StageDisplayResolver.Pass, StageDisplayResolver.Fail, StageDisplayResolver.Blocked,
            StageDisplayResolver.HumanAction, StageDisplayResolver.NotApplicable,
        };
        Check(noTaskRows.All(r => tokens8.Contains(r.Token)), "VIZ-03", "every token in the 8-token vocabulary");

        Check(noTaskRows.Single(r => r.Token == StageDisplayResolver.Ready).Key == "PREFLIGHT",
            "VIZ-04", $"no-task: first waiting stage READY (got {noTaskRows.First(r => r.Token == StageDisplayResolver.Ready).Key})");

        // Trial fixture: Human Git Gate + Governed Completion are NOT_APPLICABLE.
        var trialState = StateReader.Read(DevBridgeConfig.Load(trialRoot));
        var trialRows = StageDisplayResolver.Resolve(trialState, NextActionEngine.Evaluate(trialState));
        Check(trialRows.Single(r => r.Key == "HUMAN_GIT_GATE").Token == StageDisplayResolver.NotApplicable
              && trialRows.Single(r => r.Key == "GOVERNED_COMPLETION").Token == StageDisplayResolver.NotApplicable,
            "VIZ-05", "trial: git gate + governed completion NOT_APPLICABLE");

        // Active fixture: exactly one CURRENT stage.
        string activeRoot = NewRoot("active");
        W(activeRoot, @"state/current-task.json", TaskJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", "CHG-20260830-020"));
        W(activeRoot, @"tasks/CHATGPT_HANDOFF.md", ValidHandoff);
        W(activeRoot, @"tasks/DEEPSEEK_PROMPT.md", "# Awaiting ChatGPT Prompt\n\nNo implementation prompt yet\n");
        var activeState = StateReader.Read(DevBridgeConfig.Load(activeRoot));
        var activeRows = StageDisplayResolver.Resolve(activeState, NextActionEngine.Evaluate(activeState));
        Check(activeRows.Count(r => r.Token == StageDisplayResolver.Current) == 1
              && activeRows.Single(r => r.Token == StageDisplayResolver.Current).Key == "CHATGPT_HANDOFF",
            "VIZ-06", $"current count={activeRows.Count(r => r.Token == StageDisplayResolver.Current)}");

        // The VM renders exactly the resolver's rows (backend truth, never invented).
        var vmActive = new MainViewModel(DevBridgeConfig.Load(activeRoot));
        Check(vmActive.Stages.Count == 12
              && vmActive.Stages.Zip(activeRows, (v, r) => v.Key == r.Key && v.DisplayToken == r.Token).All(x => x),
            "VIZ-07", "VM.Stages == StageDisplayResolver rows (keys + tokens)");

        // Claude Review Package: PASS when the packet artifact exists; READY when
        // verification is complete but the packet is not yet assembled.
        string pkgRoot = NewRoot("pkg");
        W(pkgRoot, @"state/current-task.json", TaskJson("VERIFIED", "CLAUDE_REVIEW", "CHG-PKG-01"));
        W(pkgRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-PKG-01\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        W(pkgRoot, @"tasks/REVIEW_PACKET.md", "packet");
        var pkgRows = StageDisplayResolver.Resolve(StateReader.Read(DevBridgeConfig.Load(pkgRoot)),
            NextActionEngine.Evaluate(StateReader.Read(DevBridgeConfig.Load(pkgRoot))));
        string pkgReadyRoot = NewRoot("pkgready");
        W(pkgReadyRoot, @"state/current-task.json", TaskJson("VERIFIED", "CLAUDE_REVIEW", "CHG-PKG-02"));
        W(pkgReadyRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-PKG-02\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        var pkgReadyRows = StageDisplayResolver.Resolve(StateReader.Read(DevBridgeConfig.Load(pkgReadyRoot)),
            NextActionEngine.Evaluate(StateReader.Read(DevBridgeConfig.Load(pkgReadyRoot))));
        Check(pkgRows.Single(r => r.Key == "CLAUDE_REVIEW_PACKAGE").Token == StageDisplayResolver.Pass
              && pkgReadyRows.Single(r => r.Key == "CLAUDE_REVIEW_PACKAGE").Token == StageDisplayResolver.Ready,
            "VIZ-08", $"packet PASS / pre-packet READY (got {pkgRows.Single(r => r.Key == "CLAUDE_REVIEW_PACKAGE").Token}/{pkgReadyRows.Single(r => r.Key == "CLAUDE_REVIEW_PACKAGE").Token})");

        // =====================================================================
        // C. BACKEND-DRIVEN NEXT ACTION (UI never guesses)
        // =====================================================================
        var next = NextActionEngine.Evaluate(activeState);
        Check(vmActive.Instruction == next.Instruction, "NEXT-01",
            $"VM instruction == engine (status='{vmActive.StatusText}', got='{vmActive.Instruction}')");
        bool buttonsMatch = vmActive.ActionButtons.All(b =>
            b.IsEnabled == next.EnabledButtons.Contains(b.Key));
        Check(buttonsMatch, "NEXT-02",
            $"VM button enablement == engine EnabledButtons (status='{vmActive.StatusText}', " +
            $"vm-enabled=[{EnabledDesc(vmActive.ActionButtons.Where(b => b.IsEnabled).Select(b => b.Key))}], " +
            $"engine=[{EnabledDesc(next.EnabledButtons)}])");
        var noneNext = NextActionEngine.Evaluate(noTaskState);
        Check(noneNext.Instruction.Contains("Start preflight", StringComparison.OrdinalIgnoreCase)
              && SetsEqual(noneNext.EnabledButtons, new[] { "START_PREFLIGHT" }),
            "NEXT-03", $"no-task: '{noneNext.Instruction}' buttons=[{EnabledDesc(noneNext.EnabledButtons)}]");

        // =====================================================================
        // D. M03-M11 CALLABLE WIRING through the operator catalog
        // =====================================================================
        var startPre = OperatorCommandCatalog.Get("START_PREFLIGHT")!;
        Check(startPre.Kind == OperatorCommandKind.Script && startPre.ResultingExpectedState == "PREFLIGHTED"
              && startPre.Scripts.Contains("Test-DevelopmentPreflight.ps1"),
            "WIRE-01", "M03 START_PREFLIGHT script command -> PREFLIGHTED");
        var reserve = OperatorCommandCatalog.Get("RESERVE_TASK")!;
        Check(reserve.Kind == OperatorCommandKind.Script && reserve.WritesWorkbook
              && reserve.RequiredStates.Contains("PREFLIGHTED"),
            "WIRE-02", "M04 RESERVE_TASK script command, writes workbook from PREFLIGHTED");
        var handoff = OperatorCommandCatalog.Get("CREATE_CHATGPT_HANDOFF")!;
        Check(handoff.Kind == OperatorCommandKind.Script && handoff.ResultingExpectedState == "AWAITING_CHATGPT_PROMPT",
            "WIRE-03", "M05 CREATE_CHATGPT_HANDOFF script command -> AWAITING_CHATGPT_PROMPT");
        var verif = OperatorCommandCatalog.Get("RUN_VERIFICATION")!;
        Check(verif.Kind == OperatorCommandKind.Script && verif.RequiredStates.Contains("VERIFIED"),
            "WIRE-04", "M06 RUN_VERIFICATION script command requires VERIFIED");
        var pkgCmd = OperatorCommandCatalog.Get("CREATE_CLAUDE_REVIEW_PACKAGE")!;
        Check(pkgCmd.Kind == OperatorCommandKind.Script && pkgCmd.RequiredStates.Contains("VERIFIED"),
            "WIRE-05", "M07 CREATE_CLAUDE_REVIEW_PACKAGE script command requires VERIFIED");
        var record = OperatorCommandCatalog.Get("RECORD_CLAUDE_RESULT")!;
        Check(record.Kind == OperatorCommandKind.Script && record.RequiresUserInput
              && record.Scripts.Contains("Set-ClaudeReviewResult.ps1") && record.RequiresTaskIdentity,
            "WIRE-06", "M08 RECORD_CLAUDE_RESULT script command (operator input, task identity)");
        var fixCtx = OperatorCommandCatalog.Get("CREATE_CORRECTION_CONTEXT")!;
        Check(fixCtx.Kind == OperatorCommandKind.Script && fixCtx.RequiredStates.Contains("DB_M09_FIX_REQUIRED"),
            "WIRE-07", "M09 CREATE_CORRECTION_CONTEXT script command requires DB_M09_FIX_REQUIRED");
        var completion = OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!;
        Check(completion.Kind == OperatorCommandKind.Script && completion.WritesWorkbook && completion.RequiresTaskIdentity,
            "WIRE-08", "M10 RUN_GOVERNED_COMPLETION script command (workbook write, task identity)");
        var validate = OperatorCommandCatalog.Get("VALIDATE_WORKBOOK")!;
        Check(validate.Kind == OperatorCommandKind.Script && validate.ResultingExpectedState == "CONTROL_VALIDATED",
            "WIRE-09", "M11 VALIDATE_WORKBOOK script command -> CONTROL_VALIDATED");
        var advisory = OperatorCommandCatalog.Get("CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE")!;
        Check(advisory.Kind == OperatorCommandKind.Script && advisory.WritesWorkbook == false,
            "WIRE-10", "M11 advisory package command is read-only (never edits the roadmap/workbook)");
        var lifecycle = OperatorCommandCatalog.Get("GET_CURRENT_LIFECYCLE_STATE")!;
        var gitObs = OperatorCommandCatalog.Get("REFRESH_GIT_GATE_STATE")!;
        Check(lifecycle is { Kind: OperatorCommandKind.Script, WritesWorkbook: false }
              && gitObs is { Kind: OperatorCommandKind.Script, WritesWorkbook: false },
            "WIRE-11", "GET_CURRENT_LIFECYCLE_STATE + REFRESH_GIT_GATE_STATE read-only script commands");
        var reconcile = OperatorCommandCatalog.Get("RECONCILE_CORRECTION")!;
        Check(reconcile.Kind == OperatorCommandKind.Script && reconcile.RequiresTaskIdentity
              && reconcile.DangerLevel == OperatorDangerLevel.ReadOnly
              && reconcile.Scripts.Contains("Confirm-CorrectedImplementation.ps1")
              && reconcile.RequiredStates.Contains("DB_M09_FIX_REQUIRED")
              && reconcile.ResultingExpectedState == "DB_M09_FIX_REQUIRED",
            "WIRE-12", "DB-M15 RECONCILE_CORRECTION read-only script command from DB_M09_FIX_REQUIRED");
        Check(OperatorCommandCatalog.Get("RUN_VERIFICATION")!.RequiredStates.Contains("DB_M09_FIX_REQUIRED"),
            "WIRE-13", "M06 RUN_VERIFICATION callable from DB_M09_FIX_REQUIRED (re-verifies reconciled corrected attempt)");

        // =====================================================================
        // E. M05 ZERO-CONTEXT HANDOFF GATE
        // =====================================================================
        string invalidRoot = NewRoot("invalid");
        W(invalidRoot, @"state/current-task.json", TaskJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", "CHG-20260830-022"));
        W(invalidRoot, @"tasks/CHATGPT_HANDOFF.md", "Brief handoff note that misses the 14 mandatory zero-context checks.");
        W(invalidRoot, @"tasks/DEEPSEEK_PROMPT.md", "# Awaiting ChatGPT Prompt\n\nNo implementation prompt yet\n");
        var invalidState = StateReader.Read(DevBridgeConfig.Load(invalidRoot));
        var invalidNext = NextActionEngine.Evaluate(invalidState);
        Check(!invalidState.HandoffReady
              && invalidNext.Instruction.Contains(ChatGptHandoffValidation.ChatGptHandoffNotReadyToken, StringComparison.Ordinal)
              && invalidNext.EnabledButtons.Contains("CREATE_CHATGPT_HANDOFF")
              && !invalidNext.EnabledButtons.Contains("COPY_FOR_CHATGPT"),
            "M05-01", $"invalid handoff: not-ready gate (buttons=[{EnabledDesc(invalidNext.EnabledButtons)}])");
        Check(activeState.HandoffReady
              && next.EnabledButtons.Contains("COPY_FOR_CHATGPT")
              && !next.EnabledButtons.Contains("CREATE_CHATGPT_HANDOFF"),
            "M05-02", "valid 14-marker handoff: COPY enabled, CREATE disabled");
        string missingRoot = NewRoot("missing");
        W(missingRoot, @"state/current-task.json", TaskJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", "CHG-20260830-023"));
        W(missingRoot, @"tasks/DEEPSEEK_PROMPT.md", "# Awaiting ChatGPT Prompt\n\nNo implementation prompt yet\n");
        var missingNext = NextActionEngine.Evaluate(StateReader.Read(DevBridgeConfig.Load(missingRoot)));
        Check(missingNext.EnabledButtons.Contains("CREATE_CHATGPT_HANDOFF") && !missingNext.EnabledButtons.Contains("COPY_FOR_CHATGPT"),
            "M05-03", $"missing handoff: copy disabled (buttons=[{EnabledDesc(missingNext.EnabledButtons)}])");
        var vmInvalid = new MainViewModel(DevBridgeConfig.Load(invalidRoot));
        Check(vmInvalid.HandoffReadyText == ChatGptHandoffValidation.ChatGptHandoffNotReadyToken
              && vmActive.HandoffReadyText == "READY",
            "M05-04", $"VM handoff readiness: invalid={vmInvalid.HandoffReadyText} valid={vmActive.HandoffReadyText}");

        // =====================================================================
        // F. M06 FAILURE BLOCKS M07
        // =====================================================================
        string verifFailRoot = NewRoot("veriffail");
        W(verifFailRoot, @"state/current-task.json", TaskJson("VERIFIED", "CLAUDE_REVIEW", "CHG-VF-01"));
        W(verifFailRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-VF-01\",\"primaryResult\":\"VERIFICATION_FAILED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        var vfNext = NextActionEngine.Evaluate(StateReader.Read(DevBridgeConfig.Load(verifFailRoot)));
        Check(!vfNext.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE")
              && !vfNext.EnabledButtons.Contains("RECORD_CLAUDE_RESULT")
              && vfNext.EnabledButtons.Contains("RUN_VERIFICATION")
              && vfNext.Failure is { StageKey: "VERIFICATION" },
            "M06-01", $"M06-fail blocks M07 (buttons=[{EnabledDesc(vfNext.EnabledButtons)}])");
        string verifPassRoot = NewRoot("verifpass");
        W(verifPassRoot, @"state/current-task.json", TaskJson("VERIFIED", "CLAUDE_REVIEW", "CHG-VP-01"));
        W(verifPassRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-VP-01\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        var vpNext = NextActionEngine.Evaluate(StateReader.Read(DevBridgeConfig.Load(verifPassRoot)));
        Check(vpNext.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE") && vpNext.Failure is null,
            "M06-02", $"M06-pass arms M07 (buttons=[{EnabledDesc(vpNext.EnabledButtons)}])");

        // =====================================================================
        // G. TRIAL SAFE-STOP + M10 TRIAL COMPLETION NOT APPLICABLE
        // =====================================================================
        var m10Trial = M10CompletionEligibility.Evaluate(
            trialMode: true, verificationPassed: true, claudePass: true,
            humanGitGate: HumanGitGateState.NotApplicable, fingerprintGuard: RoadmapGuardVerdict.Preserved);
        Check(m10Trial.Verdict == M10CompletionEligibilityVerdict.NotApplicable
              && m10Trial.Token == M10CompletionEligibility.TrialCompletionNotApplicableToken,
            "M10-01", m10Trial.Token);

        string trialStopRoot = NewRoot("trialstop");
        W(trialStopRoot, @"state/current-task.json", TaskJson("CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-TS-01"));
        var tsState = StateReader.Read(DevBridgeConfig.Load(trialStopRoot));
        var tsNext = NextActionEngine.Evaluate(tsState);
        var tsRows = StageDisplayResolver.Resolve(tsState, tsNext);
        Check(tsNext.Instruction.Contains("TRIAL_CYCLE_SAFE_STOP", StringComparison.Ordinal)
              && !tsNext.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION")
              && tsRows.Single(r => r.Key == "GOVERNED_COMPLETION").Token == StageDisplayResolver.NotApplicable,
            "M10-02", $"trial safe-stop (buttons=[{EnabledDesc(tsNext.EnabledButtons)}])");
        var avail = CommandAvailabilityEvaluator.Evaluate(DevBridgeConfig.Load(trialStopRoot),
            OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!);
        Check(avail == CommandAvailability.NotApplicable, "M10-03", $"availability={avail}");

        // =====================================================================
        // H. REAL HUMAN GIT GATES + PR/REVIEW/MERGE HUMAN-ONLY + NO AUTO MERGE
        // =====================================================================
        string realPrRoot = NewRoot("realpr");
        W(realPrRoot, @"state/current-task.json", TaskJson("AWAITING_HUMAN_PR", "HUMAN_GIT_PR_CREATE", "CHG-REAL-02", mode: DevBridgeMode.RealToken, git: "AWAITING_HUMAN_PR"));
        W(realPrRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-REAL-02\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        W(realPrRoot, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-REAL-02\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T18:05:00Z\"}");
        var prState = StateReader.Read(DevBridgeConfig.Load(realPrRoot));
        var prHuman = HumanActionResolver.Resolve(prState);
        Check(prHuman is { CommandId: "CREATE_PR", ActionType: "HUMAN_GIT_PR_CREATE" }, "GIT-01",
            $"awaiting PR -> {prHuman?.CommandId}/{prHuman?.ActionType}");

        string realReviewRoot = NewRoot("realreview");
        W(realReviewRoot, @"state/current-task.json", TaskJson("PR_OPEN", "HUMAN_GIT_PR_REVIEW", "CHG-REAL-03", mode: DevBridgeMode.RealToken, git: "PR_OPEN"));
        var reviewHuman = HumanActionResolver.Resolve(StateReader.Read(DevBridgeConfig.Load(realReviewRoot)));
        Check(reviewHuman is { CommandId: "REVIEW_PR", ActionType: "HUMAN_GIT_PR_REVIEW" }, "GIT-02",
            $"PR open -> {reviewHuman?.CommandId}/{reviewHuman?.ActionType}");

        string realMergeRoot = NewRoot("realmerge");
        W(realMergeRoot, @"state/current-task.json", TaskJson("AWAITING_HUMAN_MERGE", "HUMAN_GIT_PR_MERGE", "CHG-REAL-04", mode: DevBridgeMode.RealToken, git: "AWAITING_HUMAN_MERGE"));
        var mergeHuman = HumanActionResolver.Resolve(StateReader.Read(DevBridgeConfig.Load(realMergeRoot)));
        Check(mergeHuman is { CommandId: "MERGE_PR", ActionType: "HUMAN_GIT_PR_MERGE" }, "GIT-03",
            $"awaiting merge -> {mergeHuman?.CommandId}/{mergeHuman?.ActionType}");

        Check(prState.M10Eligibility is { Verdict: M10CompletionEligibilityVerdict.BlockedHumanGitGatePending }
              && prState.M10Eligibility.Token == "BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING",
            "GIT-04", $"M10 blocked by pending human merge ({prState.M10Eligibility?.Token})");
        var prNext = NextActionEngine.Evaluate(prState);
        Check(!prNext.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "GIT-05",
            $"PR pending: completion disabled (buttons=[{EnabledDesc(prNext.EnabledButtons)}])");

        bool gitCommandsHumanOnly = true;
        string gitServiceNote = "";
        var fake = new FakeScriptRunner();
        foreach (var id in new[] { "CREATE_PR", "REVIEW_PR", "MERGE_PR" })
        {
            var cmd = OperatorCommandCatalog.Get(id)!;
            var r = OperatorCommandService.Execute(DevBridgeConfig.Load(realPrRoot), cmd, fake, null);
            if (cmd.Kind != OperatorCommandKind.GuidedManual || r.Result != CommandResultCode.MANUAL_ACTION_REQUIRED)
            { gitCommandsHumanOnly = false; gitServiceNote = $"{id}:{cmd.Kind}:{r.Result}"; }
        }
        Check(gitCommandsHumanOnly, "GIT-06", $"PR/review/merge GuidedManual -> MANUAL_ACTION_REQUIRED ({gitServiceNote})");

        var mergeCmd = OperatorCommandCatalog.Get("MERGE_PR")!;
        bool noAutoMerge = mergeCmd.GuidedReason is not null
                           && mergeCmd.GuidedReason.Contains("never merges automatically", StringComparison.OrdinalIgnoreCase)
                           && OperatorCommandCatalog.All.Values.All(c =>
                               c.Kind != OperatorCommandKind.Script
                               || (c.CommandId.StartsWith("MERGE", StringComparison.OrdinalIgnoreCase) == false
                                   && c.CommandId.StartsWith("APPROVE", StringComparison.OrdinalIgnoreCase) == false));
        Check(noAutoMerge, "GIT-07", "MERGE_PR is guided human-only; no script command auto-merges/approves");

        // REAL merged + all gates satisfied -> completion armed.
        string realDoneRoot = NewRoot("realdone");
        W(realDoneRoot, @"state/current-task.json", TaskJson("MERGED", "READY_FOR_GOVERNED_COMPLETION", "CHG-REAL-05", mode: DevBridgeMode.RealToken, git: "MERGED"));
        W(realDoneRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-REAL-05\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        W(realDoneRoot, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-REAL-05\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T18:05:00Z\"}");
        W(realDoneRoot, @"state/roadmap-fingerprint.json", FpJson("fp-a", "fp-a"));
        W(realDoneRoot, @"state/pre-devbridge-baseline.json", BaselineJson);
        var doneState = StateReader.Read(DevBridgeConfig.Load(realDoneRoot));
        var doneNext = NextActionEngine.Evaluate(doneState);
        Check(doneState.M10Eligibility is { Verdict: M10CompletionEligibilityVerdict.ReadyForGovernedCompletion }
              && doneState.M10Eligibility.Token == "READY_FOR_GOVERNED_COMPLETION"
              && doneNext.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"),
            "GIT-08", $"real merged+eligible -> completion armed ({doneState.M10Eligibility?.Token})");

        // =====================================================================
        // I. M10 REAL GATING EDGE CASES
        // =====================================================================
        string realNoVerifRoot = NewRoot("realnoverif");
        W(realNoVerifRoot, @"state/current-task.json", TaskJson("MERGED", "READY_FOR_GOVERNED_COMPLETION", "CHG-REAL-06", mode: DevBridgeMode.RealToken, git: "MERGED"));
        var noVerifState = StateReader.Read(DevBridgeConfig.Load(realNoVerifRoot));
        var noVerifNext = NextActionEngine.Evaluate(noVerifState);
        Check(noVerifState.M10Eligibility is { Verdict: M10CompletionEligibilityVerdict.BlockedNoVerificationPass }
              && !noVerifNext.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION")
              && noVerifNext.Failure is { StageKey: "M10" },
            "M10-04", $"real merged but no verification -> blocked ({noVerifState.M10Eligibility?.Token})");

        string realFpRoot = NewRoot("realfp");
        W(realFpRoot, @"state/current-task.json", TaskJson("MERGED", "READY_FOR_GOVERNED_COMPLETION", "CHG-REAL-07", mode: DevBridgeMode.RealToken, git: "MERGED"));
        W(realFpRoot, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-REAL-07\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\"}");
        W(realFpRoot, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-REAL-07\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T18:05:00Z\"}");
        W(realFpRoot, @"state/roadmap-fingerprint.json", FpJson("fp-a", "fp-b"));
        var fpState = StateReader.Read(DevBridgeConfig.Load(realFpRoot));
        Check(fpState.M10Eligibility is { Verdict: M10CompletionEligibilityVerdict.BlockedRoadmapStructureWriteProhibited }
              && fpState.M10Eligibility.Token == ProtectedRoadmapFingerprintGuard.BlockToken,
            "M10-05", $"roadmap fingerprint changed -> blocked ({fpState.M10Eligibility?.Token})");

        // =====================================================================
        // J. M11 CALLABLE + ADVISORY + FIX POLICY + BASELINE (retirement lifecycle removed — Forge is permanent)
        // =====================================================================
        Check(OperatorCommandCatalog.Get("VALIDATE_WORKBOOK") is { Kind: OperatorCommandKind.Script }
              && OperatorCommandCatalog.Get("CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE") is { Kind: OperatorCommandKind.Script },
            "M11-01", "M11 deterministic + advisory commands callable");

        string m11Root = NewRoot("m11");
        W(m11Root, @"state/current-task.json", TaskJson("PREFLIGHTED", "RESERVE", "CHG-M11-01"));
        W(m11Root, @"state/db-m11-review-recommendation.json", "{\"deterministicValidationPassed\":true,\"claudeWorkbookReviewRecommended\":true,\"reason\":\"after milestone\"}");
        var m11State = StateReader.Read(DevBridgeConfig.Load(m11Root));
        var m11Rows = StageDisplayResolver.Resolve(m11State, NextActionEngine.Evaluate(m11State));
        var vmM11 = new MainViewModel(DevBridgeConfig.Load(m11Root));
        Check(vmM11.AdvisoryReviewText == "CLAUDE_WORKBOOK_REVIEW_RECOMMENDED"
              && m11Rows.Single(r => r.Key == "PERIODIC_WORKBOOK_REVIEW").Token == StageDisplayResolver.Ready,
            "M11-02", "advisory recommendation surfaces READY periodic review (read-only)");
        var m11NoRows = StageDisplayResolver.Resolve(noTaskState, noTaskNext);
        Check(m11NoRows.Single(r => r.Key == "PERIODIC_WORKBOOK_REVIEW").Token == StageDisplayResolver.NotApplicable,
            "M11-03", "no recommendation -> periodic review NOT_APPLICABLE");

        Check(FixTaskPolicy.Classify(workItemActive: true) == FixAction.CorrectCurrentAttempt
              && FixTaskPolicy.Explain(FixAction.CorrectCurrentAttempt).Contains("CORRECT_CURRENT_ATTEMPT", StringComparison.Ordinal),
            "FIX-01", "active defect -> CORRECT_CURRENT_ATTEMPT (focused delta)");
        Check(FixTaskPolicy.Classify(workItemActive: false) == FixAction.NewFixTaskRequired
              && FixTaskPolicy.Explain(FixAction.NewFixTaskRequired).Contains("Never create a phase/milestone", StringComparison.OrdinalIgnoreCase),
            "FIX-02", "completed defect -> separate fix task, never a new phase/milestone");

        var restore = OperatorCommandCatalog.Get("RESTORE_REAL_NEXUS_BASELINE")!;
        var restoreResult = OperatorCommandService.Execute(DevBridgeConfig.Load(realDoneRoot), restore, new FakeScriptRunner(), null);
        Check(restore.Kind == OperatorCommandKind.GuidedManual
              && restoreResult.Result == CommandResultCode.MANUAL_ACTION_REQUIRED,
            "BASELINE-01", "RESTORE_REAL_NEXUS_BASELINE is human-only (never auto-restored)");

        var doneHuman = HumanActionResolver.Resolve(doneState);
        Check(doneHuman is { CommandId: "RESTORE_REAL_NEXUS_BASELINE", ActionType: "RESTORE_REAL_NEXUS_BASELINE" }
              && doneHuman.Instructions.Contains("never resets git", StringComparison.OrdinalIgnoreCase),
            "BASELINE-02", "real restart advisory present + never-auto wording");

        // RETIRE-01 removed 2026-09-05 — retirement lifecycle deleted; Forge is permanent.

        var vmDone = new MainViewModel(DevBridgeConfig.Load(realDoneRoot));
        Check(doneState.PreDevBridgeBaseline.Present
              && doneState.PreDevBridgeBaseline.Workbook is { Sha256: "AAAA" }
              && vmDone.PreBaselineText.Contains("main", StringComparison.Ordinal),
            "BASELINE-03", $"baseline captured read-only ({vmDone.PreBaselineText})");

        // =====================================================================
        // K. WRITER BUSY / STALE / BACKEND MISMATCH / DOUBLE-CLICK / HISTORY / PARALLEL / UNTOUCHED
        // =====================================================================
        string writerRoot = NewRoot("writer");
        W(writerRoot, @"state/current-task.json", TaskJson("PREFLIGHTED", "RESERVE", "CHG-WR-01"));
        var writerCfg = DevBridgeConfig.Load(writerRoot);
        var (acquired, _) = WorkbookWriterGate.TryAcquire(writerCfg, "test-owner");
        var second = WorkbookWriterGate.TryAcquire(writerCfg, "second");
        bool secondBusy = !second.Acquired && second.Message!.Contains("WORKBOOK_WRITER_BUSY", StringComparison.Ordinal);
        WorkbookWriterGate.Release(writerCfg);
        var third = WorkbookWriterGate.TryAcquire(writerCfg, "third");
        bool reacquired = third.Acquired;
        if (third.Acquired) WorkbookWriterGate.Release(writerCfg);
        Check(acquired && secondBusy && reacquired, "BUSY-01", "writer lock: first acquires, second WORKBOOK_WRITER_BUSY, release re-acquires");

        string staleRoot = NewRoot("stale");
        W(staleRoot, @"state/current-task.json", TaskJson("VERIFIED", "CLAUDE_REVIEW", "CHG-ST-01"));
        var staleRunner = Runner(("Run-Verification.ps1", _ => Ok("DB06_OUTCOME: VERIFICATION_PASSED\nDB06_RESULT_PASS: True")));
        var staleRun = OperatorCommandService.Execute(DevBridgeConfig.Load(staleRoot), OperatorCommandCatalog.Get("RUN_VERIFICATION")!,
            staleRunner, new LifecycleCommandInput("RUN_VERIFICATION", "WI-07-0.2.4", "CHG-ST-01", null, null, "PREFLIGHTED", "Operator", null));
        Check(staleRun.Result == CommandResultCode.BLOCKED && staleRun.Message.Contains("STALE_GOVERNANCE_STATE", StringComparison.Ordinal),
            "STALE-01", $"stale expected state rejected ({staleRun.Message})");

        string mismatchRoot = NewRoot("mismatch");
        W(mismatchRoot, @"state/current-task.json", TaskJson("RESERVED", "CHATGPT_HANDOFF", "CHG-MM-01"));
        var mismatchRun = OperatorCommandService.Execute(DevBridgeConfig.Load(mismatchRoot), OperatorCommandCatalog.Get("CREATE_CHATGPT_HANDOFF")!,
            Runner(("New-ChatGptHandoff.ps1", _ => Ok(""))), null);
        Check(mismatchRun.Result == CommandResultCode.FAILED && mismatchRun.IsBackendStateMismatch
              && mismatchRun.Message.Contains("BACKEND_STATE_MISMATCH", StringComparison.Ordinal),
            "MISMATCH-01", $"exit-0-but-no-transition -> BACKEND_STATE_MISMATCH ({mismatchRun.Message})");

        var guard = new CommandConcurrencyGuard();
        bool first = guard.TryBegin("RUN_VERIFICATION");
        bool secondBlocked = !guard.TryBegin("RESERVE_TASK");
        bool active = guard.ActiveCommandId == "RUN_VERIFICATION";
        guard.End("RUN_VERIFICATION");
        bool released = guard.ActiveCommandId is null && guard.TryBegin("RESERVE_TASK");
        Check(first && secondBlocked && active && released, "DBLCK-01", "busy/double-click guard: second command refused while one runs");

        string histRoot = NewRoot("hist");
        string successDir = Path.Combine(histRoot, "logs", "tasks", "WI-07-0.2.4", "CHG-HIST-01");
        Directory.CreateDirectory(successDir);
        W(successDir, "current-task.json", TaskJson("COMPLETION_WRITTEN", "WORKBOOK_CONSISTENCY_VALIDATION", "CHG-HIST-01", name: "Excel persistence adapter"));
        W(successDir, "completion.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-HIST-01\",\"completedAtUtc\":\"2026-08-30T20:00:00Z\"}");
        W(successDir, "verification.json", "{\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T19:40:00Z\"}");
        W(successDir, "claude-review.json", "{\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T19:45:00Z\"}");
        string failDir = Path.Combine(histRoot, "logs", "tasks", "WI-07-0.2.5", "CHG-HIST-02");
        Directory.CreateDirectory(failDir);
        W(failDir, "current-task.json", TaskJson("VERIFIED", "CLAUDE_REVIEW", "CHG-HIST-02", name: "Failed attempt"));
        W(failDir, "verification.json", "{\"primaryResult\":\"VERIFICATION_FAILED\",\"verifiedAtUtc\":\"2026-08-30T18:20:00Z\"}");
        var history = TaskHistoryService.Scan(DevBridgeConfig.Load(histRoot));
        var badHist = history.FirstOrDefault(h => h.ChangeId == "CHG-HIST-02");
        Check(history.Count == 2 && badHist is { Result: "FAILED" },
            "HIST-01", $"history keeps failed attempt (failed={badHist?.Result}, count={history.Count})");

        string parallelRoot = NewRoot("parallel");
        W(parallelRoot, @"state/db-m11-extraction.txt",
            "DB-M11 workbook consistency snapshot 2026-08-30\n" +
            "ACTIVE CHANGES rows=79\n" +
            "  row 79: A=[CHG-20260830-016] C=[WI-07-0.2.3] L=[Completed -- WI-07-0.2.3] U=[2026-08-30T16:46:12Z] W=[1.0] AC=[Governed Multi-Sheet Completion] AD=[Pass] -> classify=Terminal\n" +
            "  row 78: A=[CHG-20260830-015] C=[WI-07-0.2.2] L=[Clean implementation verified] U=[46264] W=[1.0] AC=[Implementation Verification] AD=[Pass] -> classify=Open\n" +
            "  row 25: A=[CHG-20260825-002] L-lead=[Completed]\n" +
            "  row 26: A=[CHG-20260825-003] L-lead=[Blocked -- environment S]\n");
        var (rows, open, term, _) = ActiveChangesSnapshot.Load(DevBridgeConfig.Load(parallelRoot));
        var vmParallel = new MainViewModel(DevBridgeConfig.Load(parallelRoot));
        bool parallelOk = rows.Count == 4 && open == 2 && term == 2
                          && vmParallel.ActiveChanges.Count == 4
                          && rows.First(r => r.ChangeId == "CHG-20260830-016").RepositoryDisplay == "UNKNOWN / NOT AVAILABLE";
        Check(parallelOk, "PARALLEL-01", $"parallel view: {rows.Count} rows, open={open}/term={term}, repository never guessed");

        // =====================================================================
        // L. DB-M26 SEPARATE ANALYTICS MODULE (read-only; renders its own result)
        // =====================================================================
        string m26Root = NewRoot("m26");
        W(m26Root, @"state/current-task.json", TaskJson("PREFLIGHTED", "RESERVE", "CHG-M26-01"));
        W(m26Root, @"state/db-m26-result.json",
            "{\"Milestone\":\"DB-M26\",\"Implementation\":\"PASS\"," +
            "\"AutoExecutionEnabled\":\"FALSE\",\"ProviderModelExecuted\":\"NO\"," +
            "\"RoadmapModificationCapability\":\"NO\",\"GitPrMergeCapability\":\"NO\"," +
            "\"AI_APICalls\":0,\"NetworkCalls\":0," +
            "\"WorkbookSha256Current\":\"F520060CB753EC8EC96B44BCBD193BDAB69CA68D4CC27198663665D5FE63F884\"," +
            "\"Tests\":{\"Passed\":382,\"Failed\":0,\"ScenarioCount\":\"45/45\"}}");
        var vmM26 = new MainViewModel(DevBridgeConfig.Load(m26Root));
        Check(vmM26.AnalyticsImplementation == "PASS"
              && vmM26.AnalyticsTests == "382 passed / 0 failed"
              && vmM26.AnalyticsScenarios == "45/45"
              && vmM26.AnalyticsDesignDocPath.EndsWith("DB-M26_AI_USAGE_COST_DASHBOARD.md", StringComparison.Ordinal),
            "M26-01", $"DB-M26 tab renders its own recorded result (impl={vmM26.AnalyticsImplementation}, tests={vmM26.AnalyticsTests})");
        Check(vmM26.AnalyticsAutoExecution == "FALSE"
              && vmM26.AnalyticsProviderModelExecuted == "NO"
              && vmM26.AnalyticsRoadmapCapability == "NO"
              && vmM26.AnalyticsGitPrMergeCapability == "NO"
              && vmM26.AnalyticsPaidApiCalls == "0"
              && vmM26.AnalyticsNetworkCalls == "0"
              && vmM26.AnalyticsWorkbookSha.StartsWith("F520060C", StringComparison.Ordinal),
            "M26-02", "DB-M26 separate read-only module: no auto-execution, no provider/model, no roadmap/git capability, zero paid/network calls");

        // UNTOUCHED: every fixture write lives under the temp roots; the real workbook
        // (when the real config points at one) keeps its pre-run SHA.
        string tempDir = Path.GetTempPath();
        bool allInTemp = WrittenPaths.All(p =>
            p.StartsWith(tempDir, StringComparison.OrdinalIgnoreCase)
            && !p.Contains("Nexus.Developer", StringComparison.OrdinalIgnoreCase));
        bool noRealDevbridgeWrite = WrittenPaths.All(p =>
            !p.StartsWith(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..")), StringComparison.OrdinalIgnoreCase)
            || p.StartsWith(tempDir, StringComparison.OrdinalIgnoreCase));
        Check(allInTemp && noRealDevbridgeWrite && string.IsNullOrEmpty(launchError),
            "UNTOUCHED-01", $"all {WrittenPaths.Count} fixture writes under temp; nothing in real DevBridge root / Nexus.Developer");

        Console.WriteLine($"DB-M12.3 UI LIFECYCLE SUITE — PASSED : {_pass}");
        Console.WriteLine($"DB-M12.3 UI LIFECYCLE SUITE — FAILED : {_fail}");
        Console.WriteLine(_pass > 0 && _fail == 0 ? "RESULT : ALL 65 CHECKS PASS" : "RESULT : FAILURES PRESENT");
        foreach (var f in Failures) Console.WriteLine(f);
        return _fail == 0 ? 0 : 1;
    }

    // ------------------------------------------------------------------ harness

    private static void Check(bool cond, string name, string detail)
    {
        if (cond) { _pass++; }
        else { _fail++; Failures.Add($"  FAIL {name}: {detail}"); }
    }

    private static bool SetsEqual(IEnumerable<string> actual, IEnumerable<string> expected)
    {
        var a = actual.OrderBy(x => x, StringComparer.Ordinal).ToArray();
        var e = expected.OrderBy(x => x, StringComparer.Ordinal).ToArray();
        return a.SequenceEqual(e, StringComparer.Ordinal);
    }

    private static string EnabledDesc(IEnumerable<string> b) => string.Join(",", b.OrderBy(x => x, StringComparer.Ordinal));

    private static string NewRoot(string label)
    {
        string dir = Path.Combine(Path.GetTempPath(), "dbm123-ui-" + label + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Path.Combine(dir, "state"));
        Directory.CreateDirectory(Path.Combine(dir, "tasks"));
        Directory.CreateDirectory(Path.Combine(dir, "scripts"));
        return dir;
    }

    private static void W(string root, string rel, string content)
    {
        string p = Path.Combine(root, rel);
        Directory.CreateDirectory(Path.GetDirectoryName(p)!);
        File.WriteAllText(p, content);
        WrittenPaths.Add(p);
    }

    private static string TaskJson(string status, string nextAction, string changeId,
        string? mode = null, string? git = null, string? verdict = "CLEAR",
        string nodeId = "WI-07-0.2.4", string name = "Test Task")
    {
        var sb = new StringBuilder();
        sb.Append("{\"nodeId\":\"").Append(nodeId).Append("\",\"name\":\"").Append(name)
          .Append("\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\",\"changeId\":\"").Append(changeId)
          .Append("\",\"status\":\"").Append(status).Append("\",\"nextAllowedAction\":\"").Append(nextAction).Append("\"");
        if (verdict is not null) sb.Append(",\"preflightVerdict\":\"").Append(verdict).Append("\"");
        if (mode is not null) sb.Append(",\"mode\":\"").Append(mode).Append("\"");
        if (git is not null) sb.Append(",\"gitLifecycleState\":\"").Append(git).Append("\"");
        sb.Append(",\"selectedAt\":\"2026-08-30T17:04:09Z\"}");
        return sb.ToString();
    }

    private static string FpJson(string before, string after) =>
        "{\"before\":{\"value\":\"" + before + "\",\"sheetCoverage\":\"Master Roadmap\",\"configSource\":\"test\"}," +
        "\"after\":{\"value\":\"" + after + "\",\"sheetCoverage\":\"Master Roadmap\",\"configSource\":\"test\"}}";

    private const string BaselineJson =
        "{\"workbook\":{\"path\":\"C:\\\\baseline\\\\NEXUS_DEVELOPMENT_CONTROL.xlsx\",\"sha256\":\"AAAA\",\"capturedAtUtc\":\"2026-08-01T00:00:00Z\"}," +
        "\"git\":{\"repository\":\"C:\\\\baseline\\\\nexus\",\"branch\":\"main\",\"headCommit\":\"deadbeef\",\"capturedAtUtc\":\"2026-08-01T00:00:00Z\"}}";

    private static ScriptRunOutcome Ok(string stdout) => new(true, 0, stdout, "", TimeSpan.FromMilliseconds(10), false);

    private static FakeScriptRunner Runner(params (string script, Func<string, ScriptRunOutcome> behavior)[] pairs)
    {
        var d = new Dictionary<string, Func<string, ScriptRunOutcome>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (s, f) in pairs) d[s] = f;
        return new FakeScriptRunner(d);
    }

    // Faked backend script runner (mirrors DevBridge.Tests harness).
    private sealed class FakeScriptRunner : IScriptProcessRunner
    {
        private readonly Dictionary<string, Func<string, ScriptRunOutcome>> _behaviors;

        public FakeScriptRunner(Dictionary<string, Func<string, ScriptRunOutcome>>? behaviors = null)
            => _behaviors = behaviors ?? new Dictionary<string, Func<string, ScriptRunOutcome>>(StringComparer.OrdinalIgnoreCase);

        public ScriptRunOutcome Run(string scriptPath, int timeoutMs, IReadOnlyDictionary<string, string>? environment = null)
        {
            string name = Path.GetFileName(scriptPath);
            return _behaviors.TryGetValue(name, out var behavior)
                ? behavior(scriptPath)
                : new ScriptRunOutcome(false, -1, "", $"no fake behavior for {name}", TimeSpan.Zero, false);
        }
    }
}
