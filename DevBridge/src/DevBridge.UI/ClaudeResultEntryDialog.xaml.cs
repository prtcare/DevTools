// ClaudeResultEntryDialog.xaml.cs — DB-M12.3 pure INPUT-CAPTURE dialog for
// RECORD CLAUDE RESULT (DB-M08). The operator pastes Claude's exact review
// response verbatim and selects one of the 4 supported decisions (PASS / FIX /
// GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED). Blocking / non-blocking counts
// are captured separately and folded into the review text so evidence preserves
// them. The mode-routing preview mirrors the backend script's switch (read-only;
// the backend decides, never this dialog). Recording itself goes through the
// DB-M12.2 backend command — the UI never writes state or evidence directly.
using System;
using System.Windows;
using System.Windows.Controls;

namespace DevBridge.UI;

public partial class ClaudeResultEntryDialog : Window
{
    private readonly string? _nodeId;
    private readonly string? _changeId;
    private readonly string? _taskName;
    private readonly string _modeToken; // TRIAL | REAL_NEXUS_DEVELOPMENT

    /// <summary>One of PASS / FIX / GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED (null until confirmed).</summary>
    public string? Decision { get; private set; }

    /// <summary>Verbatim review text (never interpreted by the UI).</summary>
    public string? ReviewText { get; private set; }

    public int BlockingFindings { get; private set; }
    public int NonBlockingObservations { get; private set; }

    public ClaudeResultEntryDialog(string? nodeId, string? changeId, string? taskName, string? modeToken = null)
    {
        InitializeComponent();
        _nodeId = nodeId;
        _changeId = changeId;
        _taskName = taskName;
        _modeToken = string.IsNullOrWhiteSpace(modeToken) ? "TRIAL" : modeToken;
        UpdateRoutingPreview();
        ReviewTextBox.Focus();
    }

    private string SelectedDecision()
    {
        if (GovernanceRadio.IsChecked == true) return "GOVERNANCE_ISSUE";
        if (HumanDecisionRadio.IsChecked == true) return "HUMAN_DECISION_REQUIRED";
        if (FixRadio.IsChecked == true) return "FIX";
        return "PASS";
    }

    /// <summary>Mirror Set-ClaudeReviewResult.ps1's routing switch. Read-only preview.</summary>
    private void UpdateRoutingPreview()
    {
        bool trial = _modeToken.Equals("TRIAL", StringComparison.OrdinalIgnoreCase);
        string route;
        switch (SelectedDecision())
        {
            case "PASS":
                route = trial
                    ? "PASS + TRIAL  →  CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP"
                    : "PASS + REAL  →  CLAUDE_REVIEW_PASSED_REAL / AWAITING_HUMAN_PR (human Git gate)";
                break;
            case "FIX":
                route = "FIX  →  DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT";
                break;
            case "GOVERNANCE_ISSUE":
                route = "GOVERNANCE_ISSUE  →  GOVERNANCE_ISSUE / HUMAN_GOVERNANCE_REVIEW";
                break;
            default:
                route = "HUMAN_DECISION_REQUIRED  →  HUMAN_DECISION_REQUIRED / HUMAN_DECISION";
                break;
        }
        RoutingPreviewText.Text = $"Current mode: {_modeToken}\n{route}";
    }

    private void Decision_Checked(object sender, RoutedEventArgs e)
    {
        if (RoutingPreviewText is null) return; // during InitializeComponent
        UpdateRoutingPreview();
    }

    private static bool TryParseCount(TextBox box, out int value)
        => int.TryParse((box.Text ?? "").Trim(), out value) && value >= 0;

    private void Record_Click(object sender, RoutedEventArgs e)
    {
        string text = (ReviewTextBox.Text ?? "").Trim();
        if (text.Length == 0)
        {
            MessageBox.Show(this,
                "Paste Claude's review response text before recording. " +
                "The exact original text is preserved verbatim in the evidence.",
                "Missing review text", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (!TryParseCount(BlockingFindingsText, out int blocking))
        {
            MessageBox.Show(this, "Blocking findings must be a non-negative whole number.",
                "Invalid count", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (!TryParseCount(NonBlockingObservationsText, out int nonBlocking))
        {
            MessageBox.Show(this, "Non-blocking observations must be a non-negative whole number.",
                "Invalid count", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        Decision = SelectedDecision();
        ReviewText = text;
        BlockingFindings = blocking;
        NonBlockingObservations = nonBlocking;
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Decision = null;
        DialogResult = false;
    }
}
