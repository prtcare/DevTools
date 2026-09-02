// StageRowViewModel.cs — one lifecycle stage chip for the dashboard/flow views.
//
// The 12-stage / 8-token display vocabulary (NOT_STARTED / READY / CURRENT /
// PASS / FAIL / BLOCKED / HUMAN_ACTION / NOT_APPLICABLE) is resolved by
// DevBridge.Engine (StageDisplayResolver) from backend state — the UI never
// invents a stage or a token. This wrapper only maps a display token to brushes.
using System.Windows.Media;
using DevBridge.Engine;

namespace DevBridge.UI.ViewModels;

public sealed class StageRowViewModel
{
    public string Key { get; }
    public string Label { get; }
    public string DisplayToken { get; }
    public string StateText => DisplayToken;
    public Brush Background { get; }
    public Brush Foreground { get; }

    public StageRowViewModel(StageDisplayRow row)
    {
        Key = row.Key;
        Label = row.Label;
        DisplayToken = row.Token;
        switch (row.Token)
        {
            case StageDisplayResolver.Pass:
                Background = new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32));
                Foreground = Brushes.White;
                break;
            case StageDisplayResolver.Current:
                Background = new SolidColorBrush(Color.FromRgb(0x15, 0x65, 0xC0));
                Foreground = Brushes.White;
                break;
            case StageDisplayResolver.Fail:
                Background = new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28));
                Foreground = Brushes.White;
                break;
            case StageDisplayResolver.Blocked:
                Background = new SolidColorBrush(Color.FromRgb(0xE6, 0x51, 0x00));
                Foreground = Brushes.White;
                break;
            case StageDisplayResolver.HumanAction:
                Background = new SolidColorBrush(Color.FromRgb(0x6D, 0x4D, 0x9E));
                Foreground = Brushes.White;
                break;
            case StageDisplayResolver.Ready:
                Background = new SolidColorBrush(Color.FromRgb(0x25, 0x87, 0x5F));
                Foreground = Brushes.White;
                break;
            case StageDisplayResolver.NotApplicable:
                Background = new SolidColorBrush(Color.FromRgb(0xE4, 0xE8, 0xEC));
                Foreground = new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA3));
                break;
            default: // NOT_STARTED
                Background = new SolidColorBrush(Color.FromRgb(0xEC, 0xF0, 0xF3));
                Foreground = new SolidColorBrush(Color.FromRgb(0x54, 0x6E, 0x7A));
                break;
        }
    }
}
