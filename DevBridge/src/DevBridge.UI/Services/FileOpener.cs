// FileOpener.cs — opens a governed report/artifact in the system default editor.
// Read-only navigation; the UI never edits reports itself.
using System.Diagnostics;
using System.IO;

namespace DevBridge.UI.Services;

public static class FileOpener
{
    public static (bool Ok, string Message) Open(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return (false, $"Cannot open: file not found ({path ?? "no path"}).");
        try
        {
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
            return (true, $"Opened {Path.GetFileName(path)}.");
        }
        catch (Exception e)
        {
            return (false, $"Open failed: {e.Message}");
        }
    }

    public static (bool Ok, string Message) OpenFolder(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            return (false, $"Cannot open folder: not found ({path ?? "no path"}).");
        try
        {
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
            return (true, $"Opened folder {path}.");
        }
        catch (Exception e)
        {
            return (false, $"Open folder failed: {e.Message}");
        }
    }
}
