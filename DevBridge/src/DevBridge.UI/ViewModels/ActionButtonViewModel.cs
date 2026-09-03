// ActionButtonViewModel.cs — one action button on the dashboard. The key/label
// come from NextActionEngine.AllButtons; IsEnabled comes from the engine's
// EnabledButtons for the current state. A button is never enabled unless the
// engine grounds it in an explicit state field or evidence artifact.
using System.Windows.Input;

namespace DevBridge.UI.ViewModels;

public sealed class ActionButtonViewModel : ObservableObject
{
    /// <summary>Display section the button belongs to. Pure presentation grouping —
    /// the key/label/command/enablement all still come from the engine exactly as before.</summary>
    public string Group { get; }

    public string Key { get; }
    public string Label { get; }
    public ICommand Command { get; }

    private bool _isEnabled;
    public bool IsEnabled
    {
        get => _isEnabled;
        set => SetProperty(ref _isEnabled, value);
    }

    private bool _isRecommended;
    /// <summary>The single engine-grounded next action the operator should press. Only ever
    /// true while the button is also enabled — derived in MainViewModel from EnabledButtons.</summary>
    public bool IsRecommended
    {
        get => _isRecommended;
        set => SetProperty(ref _isRecommended, value);
    }

    public ActionButtonViewModel(string key, string label, ICommand command)
    {
        Key = key;
        Label = label;
        Command = command;
        Group = GroupOf(key);
    }

    private static string GroupOf(string key) => key switch
    {
        // Primary workflow advances
        "START_PREFLIGHT" or "RESERVE_TASK" or "CREATE_CHATGPT_HANDOFF" or "COPY_FOR_CHATGPT"
            or "COPY_FOR_DEEPSEEK" or "OPEN_DEEPSEEK_PROMPT" or "RUN_VERIFICATION"
            or "CREATE_CLAUDE_REVIEW_PACKAGE" or "COPY_FOR_CLAUDE" or "RECORD_CLAUDE_RESULT"
            => "PRIMARY",

        // Lifecycle / support actions
        "COPY_FIX_CONTEXT" or "RUN_GOVERNED_COMPLETION" or "CLOSE_TRIAL_CYCLE"
            or "START_NEXT_CYCLE" or "VALIDATE_WORKBOOK"
            => "LIFECYCLE",

        // Read-only report / navigation opens
        "OPEN_REVIEW_PACKET" or "OPEN_PREFLIGHT_REPORT" or "OPEN_VERIFICATION_REPORT"
            or "OPEN_CONSISTENCY_REPORT" or "OPEN_COMPLETION_REPORT" or "OPEN_DETAIL"
            => "REPORTS",

        // Documented human-gate guidance (never auto-executed by DevBridge)
        "CREATE_PR" or "REVIEW_PR" or "MERGE_PR" or "REVIEW_GOVERNANCE_ISSUE"
            or "RESTORE_REAL_NEXUS_BASELINE"
            => "HUMAN",

        _ => "PRIMARY",
    };
}
