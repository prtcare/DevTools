// ClipboardService.cs — copies a governed artifact (handoff / prompt / packet /
// fix context) verbatim to the Windows clipboard so the operator can paste it into
// ChatGPT / DeepSeek / Claude. Read-only; never invents content.
using System.IO;
using System.Windows;

namespace DevBridge.UI.Services;

public static class ClipboardService
{
    public static (bool Ok, string Message) CopyFile(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return (false, $"Clipboard copy skipped: artifact not found ({path ?? "no path"}).");
        try
        {
            string text = File.ReadAllText(path);
            Clipboard.SetText(text); // WPF STA thread required (command executes on UI thread)
            return (true, $"Copied {Path.GetFileName(path)} ({text.Length} chars) to clipboard.");
        }
        catch (Exception e)
        {
            return (false, $"Clipboard copy failed: {e.Message}");
        }
    }
}
