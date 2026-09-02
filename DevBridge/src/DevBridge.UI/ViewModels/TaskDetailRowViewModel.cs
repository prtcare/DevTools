// TaskDetailRowViewModel.cs — one row of the per-stage artifact detail listing.
// Absent artifacts render "NOT APPLICABLE" (the stage was never reached for this
// task), exactly as the milestone requires.
using System.Windows.Media;
using DevBridge.Engine;

namespace DevBridge.UI.ViewModels;

public sealed class TaskDetailRowViewModel
{
    public TaskDetailItem Item { get; }
    public string Stage => Item.Stage;
    public string Label => Item.Label;
    public bool Present => Item.Present;
    public string PresentText => Item.Present ? "PRESENT" : "NOT APPLICABLE";
    public string? FilePath => Item.Path;
    public string Summary => Item.Present ? (Item.Summary ?? "") : "Stage was never reached for this task.";
    public string ToolTip => Item.Path ?? "Not present in this task's evidence directory.";

    public Brush PresentBrush => Item.Present
        ? new SolidColorBrush(Color.FromRgb(0x1B, 0x7A, 0x3D))
        : new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA3));

    public TaskDetailRowViewModel(TaskDetailItem item) => Item = item;
}
