// WorkbookWriterGate.cs — DB-M12.2 serialization for authoritative workbook writes.
//
// Only one governed command may hold the workbook-writer lock at a time. The gate
// is a lock file under logs\workbook-writer.lock carrying the owning PID and a
// timestamp. A lock whose owning process is dead is treated as stale and reclaimed;
// a lock held by a LIVE process reports WORKBOOK_WRITER_BUSY so a second writer is
// blocked rather than racing on the authoritative workbook.
//
// The gate complements (does not replace) the scripts' own PART-1 live SHA256
// pre-write check and the backup/read-back discipline.
using System.Diagnostics;

namespace DevBridge.Engine;

public static class WorkbookWriterGate
{
    public static string LockPath(DevBridgeConfig cfg) => Path.Combine(cfg.Root, "logs", "workbook-writer.lock");

    /// <summary>Acquire the writer lock. Returns false (with a WORKBOOK_WRITER_BUSY
    /// message) when a live writer holds it.</summary>
    public static (bool Acquired, string? Message) TryAcquire(DevBridgeConfig cfg, string? owner)
    {
        string path = LockPath(cfg);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path))
            {
                string? text = SafeRead(path);
                int pid = ParsePid(text);
                if (pid > 0 && IsProcessAlive(pid))
                    return (false, $"WORKBOOK_WRITER_BUSY — another writer (pid {pid}) holds the workbook writer lock. Re-run after it finishes.");
                // Stale lock owned by a dead process: reclaim.
                try { File.Delete(path); } catch (Exception) { /* re-check below */ }
            }
            string content = $"pid={Environment.ProcessId} acquired={DateTime.UtcNow:o} owner={(owner ?? "operator")}";
            File.WriteAllText(path, content);
            return (true, null);
        }
        catch (Exception ex)
        {
            return (false, $"WORKBOOK_WRITER_BUSY — the writer lock could not be acquired: {ex.Message}");
        }
    }

    /// <summary>Read-only busy probe for the availability vocabulary. Never creates
    /// a lock; returns true only when a LIVE process holds the writer lock.</summary>
    public static bool IsBusy(DevBridgeConfig cfg)
    {
        try
        {
            string path = LockPath(cfg);
            if (!File.Exists(path)) return false;
            int pid = ParsePid(SafeRead(path));
            return pid > 0 && IsProcessAlive(pid);
        }
        catch (Exception) { return true; }
    }

    public static void Release(DevBridgeConfig cfg)
    {
        try
        {
            string path = LockPath(cfg);
            if (File.Exists(path) && string.Equals(Environment.ProcessId.ToString(), ReadOwnPid(SafeRead(path)), StringComparison.Ordinal))
                File.Delete(path);
        }
        catch (Exception) { /* best effort; a stale lock is reclaimed on next acquire */ }
    }

    private static int ParsePid(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return 0;
        string own = ReadOwnPid(text);
        return int.TryParse(own, out int pid) ? pid : 0;
    }

    private static string ReadOwnPid(string? text)
    {
        if (text is null) return "";
        int i = text.IndexOf("pid=", StringComparison.OrdinalIgnoreCase);
        if (i < 0) return "";
        int start = i + 4;
        int end = text.IndexOf(' ', start);
        return end < 0 ? text[start..] : text[start..end];
    }

    private static bool IsProcessAlive(int pid)
    {
        try { using var p = Process.GetProcessById(pid); return p is not null; }
        catch (ArgumentException) { return false; }
    }

    private static string? SafeRead(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}
