// TaskHistoryRowViewModel.cs — wraps an Engine TaskHistoryItem for the history
// DataGrid: computed display strings + a result brush. Failed attempts are never
// hidden — the result text and brush reflect the engine's SUCCESS/FAILED/
// BLOCKED/CANCELLED/WAITING/ESCALATED derivation verbatim.
using System.Windows.Media;
using DevBridge.Engine;

namespace DevBridge.UI.ViewModels;

public sealed class TaskHistoryRowViewModel
{
    public TaskHistoryItem Item { get; }
    public string NodeId => Item.NodeId;
    public string TaskName => Item.TaskName;
    public string ChangeId => Item.ChangeId;
    public string Result => Item.Result;
    public string StartedAt => Item.StartedAt ?? "-";
    public string CompletedAt => Item.CompletedAt ?? "-";
    public string Preflight => Item.PreflightResult ?? "-";
    public string Verification => Item.VerificationResult ?? "-";
    public string Claude => Item.ClaudeResult ?? "-";
    public string Workbook => Item.WorkbookResult ?? "-";
    public string Build => $"{Item.BuildProjects ?? 0} / {Item.BuildWarnings ?? 0} / {Item.BuildErrors ?? 0}";
    public string Tests => Item.TestsTotal is null ? "-" : $"{Item.TestsPassed ?? 0} / {Item.TestsTotal}";
    public string Harness => Item.HarnessChecks?.ToString() ?? "-";
    public string Fixes => Item.FixAttempts.ToString();

    public Brush ResultBrush => Result switch
    {
        "SUCCESS" => new SolidColorBrush(Color.FromRgb(0x1B, 0x7A, 0x3D)),
        "FAILED" => new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28)),
        "BLOCKED" => new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00)),
        "CANCELLED" => new SolidColorBrush(Color.FromRgb(0x6D, 0x4D, 0x9E)),
        "ESCALATED" => new SolidColorBrush(Color.FromRgb(0xB0, 0x40, 0x00)),
        _ => new SolidColorBrush(Color.FromRgb(0x54, 0x6E, 0x7A)), // WAITING
    };

    public TaskHistoryRowViewModel(TaskHistoryItem item) => Item = item;
}
