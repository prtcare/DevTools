// ActionButtonViewModel.cs — one action button on the dashboard. The key/label
// come from NextActionEngine.AllButtons; IsEnabled comes from the engine's
// EnabledButtons for the current state. A button is never enabled unless the
// engine grounds it in an explicit state field or evidence artifact.
using System.Windows.Input;

namespace DevBridge.UI.ViewModels;

public sealed class ActionButtonViewModel : ObservableObject
{
    public string Key { get; }
    public string Label { get; }
    public ICommand Command { get; }

    private bool _isEnabled;
    public bool IsEnabled
    {
        get => _isEnabled;
        set => SetProperty(ref _isEnabled, value);
    }

    public ActionButtonViewModel(string key, string label, ICommand command)
    {
        Key = key;
        Label = label;
        Command = command;
    }
}
