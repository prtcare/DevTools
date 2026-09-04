// MainViewModel.cs — the DevBridge Operator Console view model.
//
// The UI never guesses an action: the "WHAT YOU NEED TO DO NEXT" instruction, the
// enabled button set, the lifecycle stage states and every failure/residual surface
// are derived by DevBridge.Engine (NextActionEngine + StateReader + services) from
// state/current-task.json and the evidence artifacts. All governed writes flow
// through the EXISTING backend PowerShell scripts via ScriptRunner — never through
// UI code.
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using DevBridge.Engine;
using DevBridge.UI.Services;

namespace DevBridge.UI.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private readonly DevBridgeConfig _cfg;
    private readonly Dispatcher _dispatcher;
    private readonly CommandConcurrencyGuard _commandGuard = new();

    public MainViewModel() : this(DevBridgeConfig.Load()) { }

    /// <summary>DB-M12.3: configurable root so the operator console is fixture-testable
    /// without ever touching the real workbook/state. Tests pass a temp-root config.</summary>
    public MainViewModel(DevBridgeConfig cfg)
    {
        _cfg = cfg;
        _dispatcher = Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        RefreshCommand = new RelayCommand(_ => Refresh());
        ActionCommand = new RelayCommand(key => RunAction(key as string ?? ""));
        OpenCommand = new RelayCommand(p => TryOpen(p as string));
        OpenFolderCommand = new RelayCommand(p => TryOpenFolder(p as string));

        ActionButtons = NextActionEngine.AllButtons
            .Select(b => new ActionButtonViewModel(b.Key, b.Label, ActionCommand))
            .ToList();

        // Pure presentation grouping of the SAME button instances (so enablement and the
        // recommended highlight stay in sync with ActionButtons after every Refresh).
        PrimaryActions = ActionButtons.Where(b => b.Group == "PRIMARY").ToList();
        LifecycleActions = ActionButtons.Where(b => b.Group == "LIFECYCLE").ToList();
        ReportActions = ActionButtons.Where(b => b.Group == "REPORTS").ToList();
        HumanGateActions = ActionButtons.Where(b => b.Group == "HUMAN").ToList();

        BackendRoot = _cfg.Root;
        Refresh();
    }

    // ----------------------------------------------------------------- commands
    public RelayCommand RefreshCommand { get; }
    public RelayCommand ActionCommand { get; }
    public RelayCommand OpenCommand { get; }
    public RelayCommand OpenFolderCommand { get; }

    // ---------------------------------------------------------------- busy/status
    private bool _isBusy;
    public bool IsBusy { get => _isBusy; set => SetProperty(ref _isBusy, value); }

    private string _busyText = "";
    public string BusyText { get => _busyText; set => SetProperty(ref _busyText, value); }

    private string _statusText = "";
    public string StatusText { get => _statusText; set => SetProperty(ref _statusText, value); }

    private string _lastActionMessage = "";
    public string LastActionMessage { get => _lastActionMessage; set => SetProperty(ref _lastActionMessage, value); }

    private string _scriptOutput = "";
    public string ScriptOutput { get => _scriptOutput; set => SetProperty(ref _scriptOutput, value); }

    // ------------------------------------------------------ live command output panel
    private bool _commandPanelVisible;
    public bool CommandPanelVisible { get => _commandPanelVisible; set => SetProperty(ref _commandPanelVisible, value); }

    private bool _hasCommandRun;
    public bool HasCommandRun { get => _hasCommandRun; set => SetProperty(ref _hasCommandRun, value); }

    private string _runningCommandName = "";
    public string RunningCommandName { get => _runningCommandName; set => SetProperty(ref _runningCommandName, value); }

    private string _commandRunStatus = "";
    public string CommandRunStatus { get => _commandRunStatus; set => SetProperty(ref _commandRunStatus, value); }

    private Brush _commandStatusBrush = new SolidColorBrush(Color.FromRgb(0x54, 0x6E, 0x7A));
    public Brush CommandStatusBrush { get => _commandStatusBrush; set => SetProperty(ref _commandStatusBrush, value); }

    private string _commandOutputSummary = "";
    public string CommandOutputSummary { get => _commandOutputSummary; set => SetProperty(ref _commandOutputSummary, value); }

    // ------------------------------------------------------- clipboard workflow status
    private string _clipboardStatusText = "NOT APPLICABLE";
    public string ClipboardStatusText { get => _clipboardStatusText; set => SetProperty(ref _clipboardStatusText, value); }

    private string _lastRefreshTime = "";
    public string LastRefreshTime { get => _lastRefreshTime; set => SetProperty(ref _lastRefreshTime, value); }

    public string BackendRoot { get; }

    // ----------------------------------------------------------- next action panel
    private string _instruction = "";
    public string Instruction { get => _instruction; set => SetProperty(ref _instruction, value); }

    private string _instructionSub = "";
    public string InstructionSub { get => _instructionSub; set => SetProperty(ref _instructionSub, value); }

    private Brush _instructionBrush = new SolidColorBrush(Color.FromRgb(0x1B, 0x27, 0x33));
    public Brush InstructionBrush { get => _instructionBrush; set => SetProperty(ref _instructionBrush, value); }

    private Brush _instructionAccent = new SolidColorBrush(Color.FromRgb(0x15, 0x65, 0xC0));
    public Brush InstructionAccent { get => _instructionAccent; set => SetProperty(ref _instructionAccent, value); }

    // Display label of the single highlighted next action (button marked IsRecommended).
    private string _recommendedLabel = "";
    public string RecommendedLabel { get => _recommendedLabel; set => SetProperty(ref _recommendedLabel, value); }

    // ------------------------------------------------------------------ stages
    private List<StageRowViewModel> _stages = new();
    public List<StageRowViewModel> Stages { get => _stages; set => SetProperty(ref _stages, value); }

    // ------------------------------------------------------------------ buttons
    // ActionButtons remains the full engine-ordered set (tests + enablement loop rely on it).
    // The four grouped lists share the same ActionButtonViewModel instances — display only.
    public List<ActionButtonViewModel> ActionButtons { get; }
    public List<ActionButtonViewModel> PrimaryActions { get; }
    public List<ActionButtonViewModel> LifecycleActions { get; }
    public List<ActionButtonViewModel> ReportActions { get; }
    public List<ActionButtonViewModel> HumanGateActions { get; }

    // ----------------------------------------------------------- current task card
    private string _nodeId = "—";
    public string NodeId { get => _nodeId; set => SetProperty(ref _nodeId, value); }

    private string _taskName = "—";
    public string TaskName { get => _taskName; set => SetProperty(ref _taskName, value); }

    private string _changeId = "—";
    public string ChangeId { get => _changeId; set => SetProperty(ref _changeId, value); }

    private string _phase = "—";
    public string Phase { get => _phase; set => SetProperty(ref _phase, value); }

    private string _layer = "—";
    public string Layer { get => _layer; set => SetProperty(ref _layer, value); }

    private string _status = "—";
    public string Status { get => _status; set => SetProperty(ref _status, value); }

    private string _nextAllowed = "—";
    public string NextAllowed { get => _nextAllowed; set => SetProperty(ref _nextAllowed, value); }

    private string _preflightVerdict = "—";
    public string PreflightVerdict { get => _preflightVerdict; set => SetProperty(ref _preflightVerdict, value); }

    private string _selectedAt = "—";
    public string SelectedAt { get => _selectedAt; set => SetProperty(ref _selectedAt, value); }

    // ------------------------------------------------------------ current task fields
    private List<FieldRow> _currentTaskFields = new();
    public List<FieldRow> CurrentTaskFields { get => _currentTaskFields; set => SetProperty(ref _currentTaskFields, value); }

    // ---------------------------------------------------------------- failures
    private bool _hasFailure;
    public bool HasFailure { get => _hasFailure; set => SetProperty(ref _hasFailure, value); }

    private string _failureStage = "";
    public string FailureStage { get => _failureStage; set => SetProperty(ref _failureStage, value); }

    private string _failureTimestamp = "";
    public string FailureTimestamp { get => _failureTimestamp; set => SetProperty(ref _failureTimestamp, value); }

    private string _failureResult = "";
    public string FailureResult { get => _failureResult; set => SetProperty(ref _failureResult, value); }

    private string _failureRecommended = "";
    public string FailureRecommended { get => _failureRecommended; set => SetProperty(ref _failureRecommended, value); }

    // ------------------------------------------------------- residual observations
    private List<ResidualObservation> _residuals = new();
    public List<ResidualObservation> Residuals { get => _residuals; set => SetProperty(ref _residuals, value); }

    private bool _hasResiduals;
    public bool HasResiduals { get => _hasResiduals; set => SetProperty(ref _hasResiduals, value); }

    private string _residualSummary = "";
    public string ResidualSummary { get => _residualSummary; set => SetProperty(ref _residualSummary, value); }

    // ------------------------------------------------------------------ artifacts
    private List<ArtifactRowViewModel> _artifacts = new();
    public List<ArtifactRowViewModel> Artifacts { get => _artifacts; set => SetProperty(ref _artifacts, value); }

    // -------------------------------------------------------------------- history
    private List<TaskHistoryRowViewModel> _history = new();
    public List<TaskHistoryRowViewModel> History { get => _history; set => SetProperty(ref _history, value); }

    private TaskHistoryRowViewModel? _selectedHistory;
    public TaskHistoryRowViewModel? SelectedHistory
    {
        get => _selectedHistory;
        set { if (SetProperty(ref _selectedHistory, value)) LoadSelectedDetail(); }
    }

    private List<TaskDetailRowViewModel> _selectedDetail = new();
    public List<TaskDetailRowViewModel> SelectedDetail { get => _selectedDetail; set => SetProperty(ref _selectedDetail, value); }

    private string _selectedDetailCaption = "Select a task in the history table to inspect its per-stage evidence.";
    public string SelectedDetailCaption { get => _selectedDetailCaption; set => SetProperty(ref _selectedDetailCaption, value); }

    // ------------------------------------------------------------------- control health
    private string _workbookState = "—";
    public string WorkbookState { get => _workbookState; set => SetProperty(ref _workbookState, value); }

    private Brush _workbookStateBrush = new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA3));
    public Brush WorkbookStateBrush { get => _workbookStateBrush; set => SetProperty(ref _workbookStateBrush, value); }

    private string _sheetCountText = "—";
    public string SheetCountText { get => _sheetCountText; set => SetProperty(ref _sheetCountText, value); }

    private string _workbookSha = "—";
    public string WorkbookSha { get => _workbookSha; set => SetProperty(ref _workbookSha, value); }

    private string _workbookError = "—";
    public string WorkbookError { get => _workbookError; set => SetProperty(ref _workbookError, value); }

    private string _lastConsistency = "—";
    public string LastConsistency { get => _lastConsistency; set => SetProperty(ref _lastConsistency, value); }

    private Brush _consistencyBrush = new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA3));
    public Brush ConsistencyBrush { get => _consistencyBrush; set => SetProperty(ref _consistencyBrush, value); }

    private string _consistencyAt = "—";
    public string ConsistencyAt { get => _consistencyAt; set => SetProperty(ref _consistencyAt, value); }

    private string _openActiveChanges = "—";
    public string OpenActiveChanges { get => _openActiveChanges; set => SetProperty(ref _openActiveChanges, value); }

    private string _openBlockers = "—";
    public string OpenBlockers { get => _openBlockers; set => SetProperty(ref _openBlockers, value); }

    private string _openDecisions = "—";
    public string OpenDecisions { get => _openDecisions; set => SetProperty(ref _openDecisions, value); }

    private string _openAuditFindings = "—";
    public string OpenAuditFindings { get => _openAuditFindings; set => SetProperty(ref _openAuditFindings, value); }

    private string _knownMirrorGap = "—";
    public string KnownMirrorGap { get => _knownMirrorGap; set => SetProperty(ref _knownMirrorGap, value); }

    private bool _hasMirrorGap;
    public bool HasMirrorGap { get => _hasMirrorGap; set => SetProperty(ref _hasMirrorGap, value); }

    private string _evidenceNote = "";
    public string EvidenceNote { get => _evidenceNote; set => SetProperty(ref _evidenceNote, value); }

    // ------------------------------------------------- DB-GH01 governance card
    private string _modeBadgeText = "TRIAL";
    public string ModeBadgeText { get => _modeBadgeText; set => SetProperty(ref _modeBadgeText, value); }

    private Brush _modeBadgeBrush = new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00));
    public Brush ModeBadgeBrush { get => _modeBadgeBrush; set => SetProperty(ref _modeBadgeBrush, value); }

    private string _modeCaption = "";
    public string ModeCaption { get => _modeCaption; set => SetProperty(ref _modeCaption, value); }

    private string _retirementText = "—";
    public string RetirementText { get => _retirementText; set => SetProperty(ref _retirementText, value); }

    private string _humanGitStateText = "—";
    public string HumanGitStateText { get => _humanGitStateText; set => SetProperty(ref _humanGitStateText, value); }

    private string _humanGitGuidanceText = "";
    public string HumanGitGuidanceText { get => _humanGitGuidanceText; set => SetProperty(ref _humanGitGuidanceText, value); }

    private string _gitObservedText = "—";
    public string GitObservedText { get => _gitObservedText; set => SetProperty(ref _gitObservedText, value); }

    private string _verificationResultText = "—";
    public string VerificationResultText { get => _verificationResultText; set => SetProperty(ref _verificationResultText, value); }

    private string _claudeResultText = "—";
    public string ClaudeResultText { get => _claudeResultText; set => SetProperty(ref _claudeResultText, value); }

    private string _roadmapGuardText = "—";
    public string RoadmapGuardText { get => _roadmapGuardText; set => SetProperty(ref _roadmapGuardText, value); }

    private string _m10EligibilityText = "—";
    public string M10EligibilityText { get => _m10EligibilityText; set => SetProperty(ref _m10EligibilityText, value); }

    private string _handoffReadyText = "—";
    public string HandoffReadyText { get => _handoffReadyText; set => SetProperty(ref _handoffReadyText, value); }

    private string _advisoryReviewText = "—";
    public string AdvisoryReviewText { get => _advisoryReviewText; set => SetProperty(ref _advisoryReviewText, value); }

    private string _preBaselineText = "—";
    public string PreBaselineText { get => _preBaselineText; set => SetProperty(ref _preBaselineText, value); }

    // ------------------------------------------------- DB-M12.3 always-visible mode banner
    private string _modeBannerText = "";
    public string ModeBannerText { get => _modeBannerText; set => SetProperty(ref _modeBannerText, value); }

    private Brush _modeBannerBrush = new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00));
    public Brush ModeBannerBrush { get => _modeBannerBrush; set => SetProperty(ref _modeBannerBrush, value); }

    // ------------------------------------------------- DB-M12.3 human action panel
    private bool _hasHumanAction;
    public bool HasHumanAction { get => _hasHumanAction; set => SetProperty(ref _hasHumanAction, value); }

    private string _humanActionType = "";
    public string HumanActionType { get => _humanActionType; set => SetProperty(ref _humanActionType, value); }

    private string _humanActionReason = "";
    public string HumanActionReason { get => _humanActionReason; set => SetProperty(ref _humanActionReason, value); }

    private string _humanActionInstructions = "";
    public string HumanActionInstructions { get => _humanActionInstructions; set => SetProperty(ref _humanActionInstructions, value); }

    private string _humanActionEvidence = "";
    public string HumanActionEvidence { get => _humanActionEvidence; set => SetProperty(ref _humanActionEvidence, value); }

    // ------------------------------------------------- DB-M12.3 workbook health panel
    private string _workbookAuthorityText = "NOT VERIFIED";
    public string WorkbookAuthorityText { get => _workbookAuthorityText; set => SetProperty(ref _workbookAuthorityText, value); }

    private string _writerBusyText = "—";
    public string WriterBusyText { get => _writerBusyText; set => SetProperty(ref _writerBusyText, value); }

    private string _lastGovernedWriteText = "—";
    public string LastGovernedWriteText { get => _lastGovernedWriteText; set => SetProperty(ref _lastGovernedWriteText, value); }

    // ------------------------------------------------- DB-M12.3 AI analytics (SEPARATE_MODULE, read-only)
    private string _analyticsImplementation = "—";
    public string AnalyticsImplementation { get => _analyticsImplementation; set => SetProperty(ref _analyticsImplementation, value); }

    private string _analyticsTests = "—";
    public string AnalyticsTests { get => _analyticsTests; set => SetProperty(ref _analyticsTests, value); }

    private string _analyticsScenarios = "—";
    public string AnalyticsScenarios { get => _analyticsScenarios; set => SetProperty(ref _analyticsScenarios, value); }

    private string _analyticsAutoExecution = "—";
    public string AnalyticsAutoExecution { get => _analyticsAutoExecution; set => SetProperty(ref _analyticsAutoExecution, value); }

    private string _analyticsProviderModelExecuted = "—";
    public string AnalyticsProviderModelExecuted { get => _analyticsProviderModelExecuted; set => SetProperty(ref _analyticsProviderModelExecuted, value); }

    private string _analyticsRoadmapCapability = "—";
    public string AnalyticsRoadmapCapability { get => _analyticsRoadmapCapability; set => SetProperty(ref _analyticsRoadmapCapability, value); }

    private string _analyticsGitPrMergeCapability = "—";
    public string AnalyticsGitPrMergeCapability { get => _analyticsGitPrMergeCapability; set => SetProperty(ref _analyticsGitPrMergeCapability, value); }

    private string _analyticsPaidApiCalls = "—";
    public string AnalyticsPaidApiCalls { get => _analyticsPaidApiCalls; set => SetProperty(ref _analyticsPaidApiCalls, value); }

    private string _analyticsNetworkCalls = "—";
    public string AnalyticsNetworkCalls { get => _analyticsNetworkCalls; set => SetProperty(ref _analyticsNetworkCalls, value); }

    private string _analyticsWorkbookSha = "—";
    public string AnalyticsWorkbookSha { get => _analyticsWorkbookSha; set => SetProperty(ref _analyticsWorkbookSha, value); }

    public string AnalyticsDesignDocPath => Path.Combine(_cfg.Root, "design", "ai-routing", "DB-M26_AI_USAGE_COST_DASHBOARD.md");

    // -------------------------------------------------------------- parallel changes
    private List<ActiveChangeRow> _activeChanges = new();
    public List<ActiveChangeRow> ActiveChanges { get => _activeChanges; set => SetProperty(ref _activeChanges, value); }

    private string _activeCounts = "";
    public string ActiveCounts { get => _activeCounts; set => SetProperty(ref _activeCounts, value); }

    private string _activeTimestamp = "";
    public string ActiveTimestamp { get => _activeTimestamp; set => SetProperty(ref _activeTimestamp, value); }

    public string ParallelEvidenceNote =>
        "Counts and lifecycle classifications are backend evidence (DB-M11 extraction). " +
        "Repository / Risk / Parallel-Safe are NOT classified by the UI — the operator console never schedules.";

    // --------------------------------------------------------------------- refresh
    public void Refresh()
    {
        try
        {
            IsBusy = true;
            BusyText = "Reading control state…";
            LastActionMessage = "";

            DevBridgeState state = StateReader.Read(_cfg);
            NextActionInfo next = NextActionEngine.Evaluate(state);
            ControlHealth health = ControlHealthService.Evaluate(_cfg);
            List<TaskHistoryItem> history = TaskHistoryService.Scan(_cfg);
            var (rows, open, term, ts) = ActiveChangesSnapshot.Load(_cfg);

            // next-action panel
            Instruction = next.Instruction;
            var sub = new List<string>();
            if (next.CurrentStage is not null) sub.Add($"Current stage: {next.CurrentStage}");
            if (!string.IsNullOrWhiteSpace(state.Status)) sub.Add($"Status: {state.Status}");
            if (!string.IsNullOrWhiteSpace(state.NextAllowedAction)) sub.Add($"Next allowed: {state.NextAllowedAction}");
            InstructionSub = sub.Count > 0 ? string.Join("   ·   ", sub) : "";

            bool hasFailure = next.Failure is not null;
            if (hasFailure)
            {
                InstructionBrush = new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28));
                InstructionAccent = new SolidColorBrush(Color.FromRgb(0x8E, 0x18, 0x18));
            }
            else if (!next.HasActiveTask)
            {
                InstructionBrush = new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32));
                InstructionAccent = new SolidColorBrush(Color.FromRgb(0x1B, 0x5E, 0x20));
            }
            else
            {
                InstructionBrush = new SolidColorBrush(Color.FromRgb(0x15, 0x65, 0xC0));
                InstructionAccent = new SolidColorBrush(Color.FromRgb(0x0D, 0x47, 0x8E));
            }

            // stages — DB-M12.3: 12-stage / 8-token display resolved in the engine
            Stages = StageDisplayResolver.Resolve(state, next)
                .Select(row => new StageRowViewModel(row))
                .ToList();

            // current task card
            NodeId = state.NodeId ?? "—";
            TaskName = string.IsNullOrWhiteSpace(state.TaskName) ? "—" : state.TaskName;
            ChangeId = string.IsNullOrWhiteSpace(state.ChangeId) ? "—" : state.ChangeId;
            Phase = string.IsNullOrWhiteSpace(state.Phase) ? "—" : state.Phase;
            Layer = string.IsNullOrWhiteSpace(state.Layer) ? "—" : state.Layer;
            Status = string.IsNullOrWhiteSpace(state.Status) ? "—" : state.Status;
            NextAllowed = string.IsNullOrWhiteSpace(state.NextAllowedAction) ? "—" : state.NextAllowedAction;
            PreflightVerdict = string.IsNullOrWhiteSpace(state.PreflightVerdict) ? "—" : state.PreflightVerdict;
            SelectedAt = string.IsNullOrWhiteSpace(state.SelectedAtDisplay) ? "—" : state.SelectedAtDisplay;

            // failure panel
            if (hasFailure && next.Failure is not null)
            {
                FailureStage = $"{next.Failure.StageKey} — {next.Failure.StageLabel}";
                FailureTimestamp = next.Failure.Timestamp ?? "—";
                FailureResult = next.Failure.Result;
                FailureRecommended = next.Failure.RecommendedAction;
            }
            else
            {
                FailureStage = FailureTimestamp = FailureResult = FailureRecommended = "";
            }
            HasFailure = hasFailure;

            // residual observations (shown separately from failures)
            Residuals = state.ResidualObservations;
            HasResiduals = state.ResidualObservations.Count > 0;
            ResidualSummary = state.ResidualObservations.Count == 0
                ? "No residual observations recorded."
                : $"{state.ResidualObservations.Count} residual observation(s) carried forward — none of them block the current state.";

            // current task full identity field list
            CurrentTaskFields = new List<FieldRow>
            {
                new("Node ID", state.NodeId ?? "—"),
                new("Task", state.TaskName ?? "—"),
                new("Change ID", state.ChangeId ?? "—"),
                new("Activity ID", state.ActivityId ?? "—"),
                new("Phase", state.Phase ?? "—"),
                new("Layer", state.Layer ?? "—"),
                new("Parent / Current Work", state.ParentNodeId ?? "—"),
                new("Feature", state.FeatureNodeId ?? "—"),
                new("Status", state.Status ?? "—"),
                new("Next allowed action", state.NextAllowedAction ?? "—"),
                new("Preflight verdict", state.PreflightVerdict ?? "—"),
                new("Selected / reserved at", state.SelectedAtDisplay ?? "—"),
                new("Task state file", state.TaskStateFilePresent ? state.CurrentTaskJsonPath ?? "present" : "ABSENT"),
                new("History directory", state.CurrentTaskHistoryDir ?? "—"),
            };

            // artifacts
            var a = state.Artifacts;
            Artifacts = new List<ArtifactRowViewModel>
            {
                new("NEXT_TASK", a.NextTask),
                new("PREFLIGHT_REPORT", a.PreflightReport),
                new("START_BASELINE", a.StartBaseline),
                new("CHATGPT_HANDOFF", a.ChatGptHandoff),
                new("DEEPSEEK_PROMPT", a.DeepSeekPrompt),
                new("DEEPSEEK_PROMPT_IMPLEMENTATION", a.DeepSeekPromptHasImplementation),
                new("VERIFICATION_REPORT", a.VerificationReport),
                new("REVIEW_PACKET", a.ReviewPacket),
                new("CLAUDE_REVIEW_PROMPT", a.ClaudeReviewPrompt),
                new("CLAUDE_REVIEW_RESULT", a.ClaudeReviewResult),
                new("FIX_CONTEXT", a.FixContext),
                new("SHEET_UPDATE_PLAN", a.SheetUpdatePlan),
                new("COMPLETION_REPORT", a.CompletionReport),
                new("WORKBOOK_CONSISTENCY_REPORT", a.WorkbookConsistencyReport),
            };

            // history (never hides failed attempts — engine result derivation is authoritative)
            History = history.Select(h => new TaskHistoryRowViewModel(h)).ToList();
            if (SelectedHistory is not null && History.All(h => h.Item.DetailDir != SelectedHistory.Item.DetailDir))
                SelectedHistory = null; // selection no longer present after refresh
            LoadSelectedDetail();

            // control health
            WorkbookState = health.WorkbookState;
            WorkbookStateBrush = health.WorkbookState == "AVAILABLE"
                ? new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32))
                : new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28));
            SheetCountText = health.SheetCount == 0 ? "— / 14" : $"{health.SheetCount} / {health.ExpectedSheets}";
            WorkbookSha = string.IsNullOrWhiteSpace(health.WorkbookSha256) ? "—" : health.WorkbookSha256;
            WorkbookError = string.IsNullOrWhiteSpace(health.WorkbookError) ? "—" : health.WorkbookError;
            LastConsistency = health.LastConsistencyResult ?? "NO EVIDENCE";
            ConsistencyBrush = health.LastConsistencyResult == "PASS"
                ? new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32))
                : health.LastConsistencyResult == "FAIL"
                    ? new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28))
                    : new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA3));
            ConsistencyAt = health.LastConsistencyAt ?? "—";
            OpenActiveChanges = health.OpenActiveChanges?.ToString() ?? "—";
            OpenBlockers = health.OpenBlockers?.ToString() ?? "—";
            OpenDecisions = health.OpenDecisions?.ToString() ?? "—";
            OpenAuditFindings = health.OpenAuditFindings?.ToString() ?? "—";
            KnownMirrorGap = health.HasKnownMirrorGap ? (health.KnownMirrorGap ?? "yes") : "none";
            HasMirrorGap = health.HasKnownMirrorGap;
            EvidenceNote = health.EvidenceNote ?? "";

            // DB-GH01 governance card — TRIAL vs REAL, human Git states, gates, baseline.
            ModeBadgeText = state.ModeToken ?? (state.TrialMode ? "TRIAL" : "REAL_NEXUS_DEVELOPMENT");
            ModeBadgeBrush = state.TrialMode
                ? new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00))  // amber — trial evidence
                : new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32));  // green — real nexus work
            ModeCaption = state.TrialMode
                ? "TRIAL cycle — disposable evidence, stops at TRIAL_CYCLE_SAFE_STOP; never a real PR/merge."
                : "REAL_NEXUS_DEVELOPMENT cycle — human-gated PR/merge required before governed completion.";
            RetirementText = state.Retirement switch
            {
                DevBridgeRetirementState.ReadyForRealNexusSupport => "READY_FOR_REAL_NEXUS_SUPPORT",
                DevBridgeRetirementState.RetirementEligible => "RETIREMENT_ELIGIBLE",
                DevBridgeRetirementState.Retired => "RETIRED",
                _ => "ACTIVE_TEMPORARY_BRIDGE",
            };
            HumanGitStateText = GitLifecycle.ToToken(state.HumanGitState);
            HumanGitGuidanceText = GitLifecycle.HumanGuidance(state.HumanGitState);
            GitObservedText = state.GitObserved is { } g
                ? $"{g.Branch ?? "—"} @ {ShortSha(g.HeadCommit)} · {g.MergeState ?? "—"}" + (g.Dirty ? " · DIRTY" : "")
                : "No git observation";
            VerificationResultText = string.IsNullOrWhiteSpace(state.VerificationPrimaryResult)
                ? "NO EVIDENCE" : state.VerificationPrimaryResult;
            ClaudeResultText = string.IsNullOrWhiteSpace(state.ClaudeDecision)
                ? "NO EVIDENCE" : state.ClaudeDecision;
            RoadmapGuardText = state.RoadmapGuard switch
            {
                RoadmapGuardVerdict.Preserved => "PRESERVED",
                RoadmapGuardVerdict.StructureChanged => "STRUCTURE_CHANGED",
                _ => "NOT_COMPARABLE",
            };
            M10EligibilityText = state.M10Eligibility is { } m10 ? m10.Token : "NOT_EVALUATED";
            HandoffReadyText = state.HandoffReady
                ? "READY"
                : state.HandoffValidation is null
                    ? "NOT_YET_GENERATED"
                    : ChatGptHandoffValidation.ChatGptHandoffNotReadyToken;
            AdvisoryReviewText = state.M11Recommendation is { } m11 ? m11.Token : "NO_RECOMMENDATION";
            PreBaselineText = state.PreDevBridgeBaseline.Present
                ? $"Workbook {ShortSha(state.PreDevBridgeBaseline.Workbook?.Sha256)} · git {state.PreDevBridgeBaseline.Git?.Branch} @ {ShortSha(state.PreDevBridgeBaseline.Git?.HeadCommit)}"
                : "NOT CAPTURED";

            // DB-M12.3 always-visible mode banner — impossible to miss, never a
            // silent/automatic mode switch (the UI has no mode-switch control).
            ModeBannerText = state.TrialMode
                ? "TRIAL — Trial activity is disposable proving activity and is not permanent Nexus development."
                : "REAL_NEXUS_DEVELOPMENT — Real Nexus development: governed human Git gates and completion apply.";
            ModeBannerBrush = state.TrialMode
                ? new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00))
                : new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32));

            // DB-M12.3 human action panel — backend-derived (HumanActionResolver),
            // display only; DevBridge never performs a guided/manual action itself.
            var human = HumanActionResolver.Resolve(state);
            HasHumanAction = human is not null;
            HumanActionType = human?.ActionType ?? "";
            HumanActionReason = human?.Reason ?? "";
            HumanActionInstructions = human?.Instructions ?? "";
            HumanActionEvidence = human?.Evidence ?? "";

            // DB-M12.3 workbook health panel — read-only. The resolved historical
            // DB-M23 hash note is NEVER surfaced as an active corruption warning.
            WorkbookAuthorityText = WorkbookAuthorityStatus(_cfg);
            WriterBusyText = WorkbookWriterGate.IsBusy(_cfg)
                ? "BUSY — another writer holds the workbook lock"
                : "IDLE";
            LastGovernedWriteText = state.CompletionWritten && state.CompletionWrittenAtUtc is not null
                ? $"Governed completion write at {state.CompletionWrittenAtUtc} (node {state.CompletionNodeId ?? "—"} / change {state.CompletionChangeId ?? "—"})"
                : "No governed completion write recorded yet";

            // DB-M12.3 AI analytics summary — SEPARATE_MODULE, read-only. The tab
            // renders DB-M26's recorded truth; it never recomputes or mutates it.
            LoadAnalytics(_cfg);

            // parallel active changes
            ActiveChanges = rows;
            ActiveCounts = $"{open} open · {term} terminal";
            ActiveTimestamp = ts;

            StatusText = "STATE READY";
            LastRefreshTime = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            IsBusy = false;
            BusyText = "";

            // DB-M12.3 double-click protection: with the busy flag now cleared, arm
            // exactly the engine-grounded button set (a running command disables all).
            bool anyCopy = next.EnabledButtons.Any(k => k.StartsWith("COPY_", StringComparison.Ordinal));
            ClipboardStatusText = IsBusy
                ? ClipboardStatusMapper.NotApplicable().Label
                : anyCopy
                    ? ClipboardStatusMapper.StatusFor(true, "Ready to copy the current artifact.").Label
                    : ClipboardStatusMapper.NotApplicable().Label;

            // The single recommended action = the engine's first enabled ADVANCE button
            // (a real workflow step) when one exists; otherwise the first enabled button
            // (e.g. read a report). Pure display emphasis — never changes what is enabled.
            string recommended = next.EnabledButtons.FirstOrDefault(IsAdvance)
                ?? next.EnabledButtons.FirstOrDefault() ?? "";
            RecommendedLabel = ActionButtons.FirstOrDefault(b => b.Key == recommended)?.Label ?? "";
            foreach (var b in ActionButtons)
            {
                bool enabled = !IsBusy && next.EnabledButtons.Contains(b.Key);
                b.IsEnabled = enabled;
                b.IsRecommended = enabled && b.Key == recommended;
            }
        }
        catch (Exception e)
        {
            StatusText = $"STATE ERROR: {e.Message}";
            IsBusy = false;
            BusyText = "";
        }
    }

    private void LoadSelectedDetail()
    {
        if (SelectedHistory is null)
        {
            SelectedDetail = new List<TaskDetailRowViewModel>();
            SelectedDetailCaption = "Select a task in the history table to inspect its per-stage evidence.";
            return;
        }
        var item = SelectedHistory.Item;
        SelectedDetail = TaskHistoryService.Detail(item.DetailDir ?? "")
            .Select(d => new TaskDetailRowViewModel(d)).ToList();
        SelectedDetailCaption =
            $"{item.NodeId} · {item.ChangeId} — per-stage artifact evidence (missing artifacts are NOT APPLICABLE).";
    }

    // ------------------------------------------------------------------- actions
    // DB-M12.1: every action routes through the operator command catalog
    // (OperatorCommandCatalog) — a UI-owned vocabulary of metadata that points at
    // the EXISTING backend scripts. Guided/manual commands never fake an automatic
    // run; they show the recorded reason. All governed writes flow through the
    // existing backend PowerShell scripts via OperatorCommandService.
    private void RunAction(string key)
    {
        // Busy / double-invocation protection (Part 13): while a governed command
        // runs, refuse all further lifecycle actions.
        if (IsBusy || _commandGuard.ActiveCommandId is not null)
        {
            LastActionMessage = "A governed command is running — wait for it to finish.";
            return;
        }

        var cmd = OperatorCommandCatalog.Get(key);
        if (cmd is null) { LastActionMessage = $"No action bound for '{key}'."; return; }

        // DB-M12.3 M08 flow: RECORD_CLAUDE_RESULT needs operator evidence input
        // (verdict + verbatim review text). Route it through the upgraded dialog and
        // the one-command input contract BEFORE the kind switch — the catalog declares
        // it Kind=Script, so the dead GuidedManual branch is removed below.
        if (cmd.CommandId == "RECORD_CLAUDE_RESULT")
        {
            OpenClaudeResultDialog(cmd);
            return;
        }

        switch (cmd.Kind)
        {
            case OperatorCommandKind.Navigation:
                HandleNavigation(cmd);
                break;
            case OperatorCommandKind.Clipboard:
                HandleClipboard(cmd);
                break;
            case OperatorCommandKind.GuidedManual:
                ShowGuidance(cmd.DisplayName, BuildGuidance(cmd));
                break;
            default:
                RunOperatorCommand(cmd);
                break;
        }
    }

    private string T(string file) => Path.Combine(_cfg.TasksDir, file);

    /// <summary>Run a script-backed operator command through the command service.</summary>
    private void RunOperatorCommand(OperatorCommand cmd) => RunOperatorCommand(cmd, null);

    /// <summary>Run a script-backed operator command with the DB-M12.2 one-command
    /// input contract (used by RECORD_CLAUDE_RESULT, which supplies the verdict +
    /// verbatim review text through the backend script's parameters channel).</summary>
    private void RunOperatorCommand(OperatorCommand cmd, LifecycleCommandInput? input)
    {
        if (IsBusy || !_commandGuard.TryBegin(cmd.CommandId)) return;

        // Operator confirmation for authoritative-workbook writes (Part 9). The
        // backend still performs every governance check — this is operator-only.
        if (cmd.WritesWorkbook)
        {
            var st = StateReader.Read(_cfg);
            var confirm = MessageBox.Show(
                $"This operation will update the authoritative\n{_cfg.WorkbookDisplayName} workbook.\n\n" +
                $"Task: {st.TaskName ?? st.NodeId ?? "—"}\nNode: {st.NodeId ?? "—"}\nChange: {st.ChangeId ?? "—"}\n\nContinue?",
                $"CONFIRM — {cmd.DisplayName}", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
            {
                _commandGuard.End(cmd.CommandId);
                LastActionMessage = $"{cmd.DisplayName} cancelled by operator (no workbook write).";
                return;
            }
        }

        IsBusy = true;
        BusyText = $"Running {cmd.DisplayName}…";
        // DB-M12.3 double-click protection: while a governed command runs, every
        // lifecycle button is visually disabled (the guard also refuses re-entry).
        foreach (var b in ActionButtons) b.IsEnabled = false;
        CommandPanelVisible = true;
        HasCommandRun = true;
        RunningCommandName = cmd.DisplayName;
        CommandRunStatus = "RUNNING";
        CommandStatusBrush = new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00));
        CommandOutputSummary = "";
        ScriptOutput = "";
        LastActionMessage = "";

        var cfg = _cfg;
        var runner = new ScriptProcessRunner(cfg.Root);
        Task.Run(() =>
        {
            OperatorCommandResult result;
            try { result = OperatorCommandService.Execute(cfg, cmd, runner, input); }
            catch (Exception e) { result = BuildCrashResult(cmd, e); }
            _dispatcher.BeginInvoke(() =>
            {
                _commandGuard.End(cmd.CommandId);
                IsBusy = false;
                BusyText = "";
                ApplyResult(result);
                Refresh();
            });
        });
    }

    private void ApplyResult(OperatorCommandResult r)
    {
        ScriptOutput = string.IsNullOrWhiteSpace(r.FullOutput) ? r.StdoutSummary : r.FullOutput;
        CommandOutputSummary = r.StdoutSummary;
        RunningCommandName = r.DisplayName;
        switch (r.Result)
        {
            case CommandResultCode.SUCCESS:
                CommandRunStatus = "PASS";
                CommandStatusBrush = new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32));
                break;
            case CommandResultCode.BLOCKED:
                CommandRunStatus = "BLOCKED";
                CommandStatusBrush = new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00));
                break;
            case CommandResultCode.CANCELLED:
            case CommandResultCode.MANUAL_ACTION_REQUIRED:
                CommandRunStatus = "MANUAL";
                CommandStatusBrush = new SolidColorBrush(Color.FromRgb(0x54, 0x6E, 0x7A));
                break;
            default:
                CommandRunStatus = "FAILED";
                CommandStatusBrush = new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28));
                break;
        }
        LastActionMessage = r.IsBackendStateMismatch
            ? $"{r.Message}  [{r.StateValidationLabel}]"
            : r.Message;
    }

    private void HandleClipboard(OperatorCommand cmd)
    {
        string? file = cmd.ArtifactFile;
        string? path = string.IsNullOrWhiteSpace(file) ? null : T(file);

        if (path is null || !File.Exists(path))
        {
            var missing = ClipboardStatusMapper.StatusFor(false, "Copy skipped — artifact missing.");
            ClipboardStatusText = missing.Label;
            LastActionMessage = missing.Message;
            return;
        }
        var r = ClipboardService.CopyFile(path);
        var info = ClipboardStatusInfo.ForResult(r.Ok, r.Message);
        ClipboardStatusText = info.Label;
        LastActionMessage = r.Message;
    }

    private void HandleNavigation(OperatorCommand cmd)
    {
        switch (cmd.CommandId)
        {
            case "OPEN_DEEPSEEK_PROMPT": TryOpen(T("DEEPSEEK_PROMPT.md")); break;
            case "OPEN_REVIEW_PACKET":
            {
                // New model: Claude reviews the CURRENT CLAUDE REVIEW MANIFEST
                // (tasks/CLAUDE_REVIEW_PACKAGE.md) - the exact detailed content COPY FOR
                // CLAUDE sends. Open that manifest. The legacy REVIEW_PACKET.md is only a
                // cover pointer and is never opened as review content; if it must serve an
                // older pre-manifest cycle, say so rather than silently showing a pointer.
                string manifest = T("CLAUDE_REVIEW_PACKAGE.md");
                if (File.Exists(manifest)) { TryOpen(manifest); break; }
                string legacy = T("REVIEW_PACKET.md");
                if (File.Exists(legacy))
                {
                    TryOpen(legacy);
                    LastActionMessage = "No CLAUDE REVIEW MANIFEST present - opened legacy tasks/REVIEW_PACKET.md (pointer only).";
                }
                else
                {
                    LastActionMessage = "No CLAUDE REVIEW MANIFEST present. Run CREATE CLAUDE REVIEW PACKAGE first.";
                }
                break;
            }
            case "OPEN_PREFLIGHT_REPORT": TryOpen(T("PREFLIGHT_REPORT.md")); break;
            case "OPEN_VERIFICATION_REPORT": TryOpen(T("VERIFICATION_REPORT.md")); break;
            case "OPEN_CONSISTENCY_REPORT": TryOpen(T("WORKBOOK_CONSISTENCY_REPORT.md")); break;
            case "OPEN_COMPLETION_REPORT": TryOpen(T("COMPLETION_REPORT.md")); break;
            case "OPEN_CHATGPT_HANDOFF": TryOpen(T("CHATGPT_HANDOFF.md")); break;
            case "OPEN_DETAIL":
            {
                string? dir = StateReader.Read(_cfg).CurrentTaskHistoryDir;
                TryOpenFolder(string.IsNullOrWhiteSpace(dir) ? _cfg.TasksDir : dir);
                break;
            }
            default: LastActionMessage = $"No open target for '{cmd.CommandId}'."; break;
        }
    }

    /// <summary>DB-M12.3 M08 flow: capture the operator's Claude verdict + verbatim
    /// review text, then run RECORD_CLAUDE_RESULT through OperatorCommandService with
    /// a DB-M12.2 LifecycleCommandInput (identity + mode + parameters). Recording goes
    /// through the backend script (Set-ClaudeReviewResult.ps1) — the UI never writes
    /// state or evidence directly.</summary>
    private void OpenClaudeResultDialog(OperatorCommand cmd)
    {
        var st = StateReader.Read(_cfg);
        var dlg = new ClaudeResultEntryDialog(st.NodeId, st.ChangeId, st.TaskName, st.ModeToken)
        { Owner = Application.Current.MainWindow };
        if (dlg.ShowDialog() != true || dlg.Decision is null)
        {
            LastActionMessage = "Claude result recording cancelled by operator.";
            return;
        }

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["decision"] = dlg.Decision,
            ["reviewText"] = ComposeReviewText(dlg),
        };
        var input = new LifecycleCommandInput(
            CommandId: cmd.CommandId,
            NodeId: st.NodeId,
            ChangeId: st.ChangeId,
            Mode: st.ModeToken,
            Parameters: parameters,
            ExpectedCurrentState: st.Status,
            Actor: "operator",
            CorrelationId: null);

        RunOperatorCommand(cmd, input);
    }

    /// <summary>Preserve the verbatim review text and fold the operator-entered
    /// blocking/non-blocking counts into the evidence the backend script records.</summary>
    private static string ComposeReviewText(ClaudeResultEntryDialog dlg)
    {
        var sb = new StringBuilder(dlg.ReviewText ?? "");
        sb.AppendLine();
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine($"Blocking findings: {dlg.BlockingFindings}");
        sb.AppendLine($"Non-blocking observations: {dlg.NonBlockingObservations}");
        return sb.ToString();
    }

    /// <summary>Defensive read of state/workbook-authority-reconciliation.json. The
    /// console renders the confirmed authority decision only; it never re-surfaces the
    /// resolved historical DB-M23 hash note as an active corruption warning.</summary>
    private static string WorkbookAuthorityStatus(DevBridgeConfig cfg)
    {
        var el = StateJson.TryRead(Path.Combine(cfg.StateDir, "workbook-authority-reconciliation.json"));
        if (el is null) return "NOT VERIFIED";
        string? verdict = StateJson.Str(el, "Verdict");
        return verdict is not null && verdict.StartsWith("WORKBOOK_AUTHORITY", StringComparison.Ordinal)
            ? "WORKBOOK_AUTHORITY_CONFIRMED"
            : string.IsNullOrWhiteSpace(verdict) ? "NOT VERIFIED" : verdict;
    }

    /// <summary>DB-M12.3 AI analytics summary — SEPARATE_MODULE, read-only. The tab
    /// renders DB-M26's own result file; it never recomputes or duplicates M26 logic.</summary>
    private void LoadAnalytics(DevBridgeConfig cfg)
    {
        var el = StateJson.TryRead(Path.Combine(cfg.StateDir, "db-m26-result.json"));
        if (el is null)
        {
            AnalyticsImplementation = "NO DB-M26 RESULT";
            return;
        }
        AnalyticsImplementation = StateJson.Str(el, "Implementation") ?? "—";
        JsonElement? tests = el.Value.TryGetProperty("Tests", out var t) && t.ValueKind == JsonValueKind.Object
            ? t : null;
        if (tests is not null)
        {
            AnalyticsTests = $"{StateJson.Str(tests, "Passed") ?? "—"} passed / {StateJson.Str(tests, "Failed") ?? "—"} failed";
            AnalyticsScenarios = StateJson.Str(tests, "ScenarioCount") ?? "—";
        }
        else
        {
            AnalyticsTests = StateJson.Str(el, "TestsPassed") ?? "—";
            AnalyticsScenarios = StateJson.Str(el, "Scenarios") ?? "—";
        }
        AnalyticsAutoExecution = StateJson.Str(el, "AutoExecutionEnabled") ?? StateJson.Str(el, "AutomaticExecutionEnabled") ?? "—";
        AnalyticsProviderModelExecuted = StateJson.Str(el, "ProviderModelExecuted") ?? "—";
        AnalyticsRoadmapCapability = StateJson.Str(el, "RoadmapModificationCapability") ?? "—";
        AnalyticsGitPrMergeCapability = StateJson.Str(el, "GitPrMergeCapability") ?? "—";
        AnalyticsPaidApiCalls = StateJson.Str(el, "AI_APICalls") ?? "—";
        AnalyticsNetworkCalls = StateJson.Str(el, "NetworkCalls") ?? "—";
        AnalyticsWorkbookSha = StateJson.Str(el, "WorkbookSha256Current") ?? "—";
    }

    private static string BuildGuidance(OperatorCommand cmd)
    {
        var sb = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(cmd.ManualGuidance)) sb.AppendLine(cmd.ManualGuidance);
        if (!string.IsNullOrWhiteSpace(cmd.GuidedReason))
        {
            sb.AppendLine();
            sb.AppendLine($"Why this stays manual: {cmd.GuidedReason}");
        }
        return sb.ToString();
    }

    private static OperatorCommandResult BuildCrashResult(OperatorCommand cmd, Exception e) => new()
    {
        CommandId = cmd.CommandId,
        DisplayName = cmd.DisplayName,
        Kind = cmd.Kind,
        StartedAtUtc = DateTime.UtcNow,
        CompletedAtUtc = DateTime.UtcNow,
        ExitCode = -1,
        Result = CommandResultCode.FAILED,
        StdoutSummary = "",
        ErrorSummary = e.Message,
        PreviousState = "—",
        NewState = "—",
        Message = $"Command crashed: {e.Message}",
    };

    private static string ShortSha(string? s)
        => string.IsNullOrWhiteSpace(s) ? "—" : s.Length >= 7 ? s[..7] : s;

    /// <summary>A real workflow advance (as opposed to a COPY_/OPEN_ helper). Used only to
    /// decide which enabled button to highlight — enablement stays fully engine-driven.</summary>
    private static bool IsAdvance(string key)
        => !key.StartsWith("OPEN_", StringComparison.Ordinal)
           && !key.StartsWith("COPY_", StringComparison.Ordinal);

    private void TryOpen(string? path)
    {
        var r = FileOpener.Open(path);
        LastActionMessage = r.Ok ? r.Message : $"{r.Message} (open actions are read-only navigation).";
    }

    private void TryOpenFolder(string? path)
    {
        var r = FileOpener.OpenFolder(path);
        LastActionMessage = r.Ok ? r.Message : r.Message;
    }

    private static void ShowGuidance(string title, string body)
        => MessageBox.Show(body, $"GUIDANCE — {title}", MessageBoxButton.OK, MessageBoxImage.Information);
}

public sealed class FieldRow
{
    public string Name { get; }
    public string Value { get; }
    public FieldRow(string name, string value)
    {
        Name = name;
        Value = value;
    }
}
