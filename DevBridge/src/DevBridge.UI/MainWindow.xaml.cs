using System.Windows;
using DevBridge.UI.ViewModels;

namespace DevBridge.UI;

/// <summary>
/// DevBridge Operator Console. Binds to MainViewModel, which derives everything
/// (next action, enabled buttons, lifecycle stages, failures, health) from
/// DevBridge.Engine — the UI never guesses an action.
/// </summary>
public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new MainViewModel();
        DataContext = _viewModel;
    }
}
