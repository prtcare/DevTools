// ArtifactRowViewModel.cs — one row of the current-task artifact presence table.
using System.Windows.Media;

namespace DevBridge.UI.ViewModels;

public sealed class ArtifactRowViewModel
{
    public string Stage { get; }
    public bool Present { get; }
    public string PresentText => Present ? "PRESENT" : "MISSING";
    public Brush PresentBrush => Present
        ? new SolidColorBrush(Color.FromRgb(0x1B, 0x7A, 0x3D))
        : new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA3));

    public ArtifactRowViewModel(string stage, bool present)
    {
        Stage = stage;
        Present = present;
    }
}
