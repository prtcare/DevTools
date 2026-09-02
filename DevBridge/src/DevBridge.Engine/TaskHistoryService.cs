// TaskHistoryService.cs — reads task history from logs\tasks\<NODE-ID>\<CHANGE-ID>\
// plus state/evidence artifacts. Read-only; no independent history database.
// Failed attempts are never hidden: a FAILED result wins over a later SUCCESS.
using System.Text.Json;

namespace DevBridge.Engine;

public sealed record TaskHistoryItem(
    string NodeId,
    string TaskName,
    string ChangeId,
    string? StartedAt,
    string? CompletedAt,
    string Result,           // SUCCESS | FAILED | BLOCKED | CANCELLED | WAITING | ESCALATED
    string? PreflightResult, // CLEAR | FAIL | "-"
    string? VerificationResult,
    string? ClaudeResult,
    string? WorkbookResult,
    int? BuildProjects, int? BuildWarnings, int? BuildErrors,
    int? TestsPassed, int? TestsFailed, int? TestsTotal,
    int? HarnessChecks,
    int FixAttempts,
    string? DetailDir);

public sealed record TaskDetailItem(string Stage, string Label, bool Present, string? Path, string? Summary);

public static class TaskHistoryService
{
    public static List<TaskHistoryItem> Scan(DevBridgeConfig cfg)
    {
        var items = new List<TaskHistoryItem>();
        if (!Directory.Exists(cfg.LogsTasksDir)) return items;
        foreach (var nodeDir in Directory.EnumerateDirectories(cfg.LogsTasksDir).OrderBy(d => d))
        {
            foreach (var changeDir in Directory.EnumerateDirectories(nodeDir).OrderBy(d => d))
            {
                var item = BuildItem(cfg, Path.GetFileName(nodeDir), Path.GetFileName(changeDir), changeDir);
                if (item is not null) items.Add(item);
            }
        }
        return items.OrderByDescending(i => i.CompletedAt ?? i.StartedAt ?? "").ToList();
    }

    private static TaskHistoryItem? BuildItem(DevBridgeConfig cfg, string nodeId, string changeId, string dir)
    {
        string? name = null;
        string? started = null, completed = null;

        var ct = StateJson.TryRead(Path.Combine(dir, "current-task.json"));
        if (ct is null) ct = StateJson.TryRead(Path.Combine(cfg.StateDir, "current-task.json"));
        if (ct is not null)
        {
            name = StateJson.Str(ct, "name");
            started = StateJson.Str(ct, "selectedAt") ?? StateJson.Str(ct, "reservedAt");
            completed = StateJson.Str(ct, "completedWorkbookWriteAt");
        }

        var res = StateJson.TryRead(Path.Combine(dir, "reservation.json"));
        if (res is not null && started is null) started = StateJson.Str(res, "generatedAtUtc");
        if (res is not null && name is null) name = StateJson.Str(res, "name");

        var comp = StateJson.TryRead(Path.Combine(dir, "completion.json"));
        if (comp is not null)
        {
            completed = StateJson.Str(comp, "completedAtUtc");
            if (name is null) name = StateJson.Str(comp, "name");
        }

        string? preflight = null;
        var pre = StateJson.TryRead(Path.Combine(dir, "preflight.json"));
        if (pre is null) pre = StateJson.TryRead(Path.Combine(cfg.StateDir, "preflight.json"));
        if (pre is not null) preflight = StateJson.Str(pre, "verdict");

        var ver = StateJson.TryRead(Path.Combine(dir, "verification.json"));
        string? verification = null;
        if (ver is not null) verification = StateJson.Str(ver, "primaryResult");
        else if (File.Exists(Path.Combine(dir, "VERIFICATION_REPORT.md")))
            verification = SniffReport(Path.Combine(dir, "VERIFICATION_REPORT.md"), "VERIFICATION_PASSED", "VERIFICATION_FAILED");

        string? claude = null;
        var cl = StateJson.TryRead(Path.Combine(dir, "claude-review.json"));
        if (cl is not null) claude = StateJson.Str(cl, "decision");
        else if (File.Exists(Path.Combine(dir, "CLAUDE_REVIEW_RESULT.md")))
            claude = SniffReport(Path.Combine(dir, "CLAUDE_REVIEW_RESULT.md"), "PASS", "FAIL");

        string? wb = null;
        var w = StateJson.TryRead(Path.Combine(dir, "workbook-consistency.json"));
        if (w is not null) wb = StateJson.Str(w, "controlValidationResult");
        else if (File.Exists(Path.Combine(dir, "WORKBOOK_CONSISTENCY_REPORT.md")))
            wb = SniffReport(Path.Combine(dir, "WORKBOOK_CONSISTENCY_REPORT.md"), "CONTROL_VALIDATION_PASSED", "CONTROL_VALIDATION_FAILED");

        // build/test numbers from preserved evidence
        int? bp = null, bw = null, be = null, tp = null, tf = null, tt = null, hc = null;
        var b = StateJson.TryRead(Path.Combine(dir, "build-result.json"));
        if (b is not null)
        {
            bp = ArrayLen(b, "projects");
            bw = Num(b, "warnings"); be = Num(b, "errors");
        }
        var t = StateJson.TryRead(Path.Combine(dir, "test-result.json"));
        if (t is not null)
        {
            if (t.Value.TryGetProperty("testRun", out var tr)) { tp = Num(tr, "passed"); tf = Num(tr, "failed"); tt = Num(tr, "total"); }
            if (t.Value.TryGetProperty("harnessRun", out var hr)) hc = Num(hr, "checksPassed");
        }

        // fix attempts = FIX_CONTEXT.md versions (we count marker lines) — best-effort, evidence-based
        int fixAttempts = 0;
        var fx = Path.Combine(dir, "FIX_CONTEXT.md");
        if (File.Exists(fx))
        {
            string txt = File.ReadAllText(fx);
            fixAttempts = Math.Max(1, CountOccurrences(txt, "FIX") - CountOccurrences(txt, "FIX_CONTEXT"));
            fixAttempts = Math.Max(1, fixAttempts == 0 ? 1 : fixAttempts);
        }
        else if (File.Exists(Path.Combine(cfg.TasksDir, "FIX_CONTEXT.md"))) fixAttempts = 1;

        string result = DeriveResult(verification, claude, wb, comp, preflight, ct);
        return new TaskHistoryItem(
            nodeId, name ?? nodeId, changeId, started, completed, result,
            PreflightOrDefault(preflight), verification, claude, wb,
            bp, bw, be, tp, tf, tt, hc, fixAttempts, dir);
    }

    private static string? PreflightOrDefault(string? v) => string.IsNullOrWhiteSpace(v) ? "-" : v;

    private static string DeriveResult(string? verification, string? claude, string? wb, JsonElement? comp, string? preflight, JsonElement? ct)
    {
        // A failed attempt is never hidden: any FAILED evidence wins.
        if (wb is not null && !wb.StartsWith("PASS", StringComparison.OrdinalIgnoreCase)) return "FAILED";
        if (verification is not null && verification.StartsWith("VERIFICATION_FAILED", StringComparison.OrdinalIgnoreCase)) return "FAILED";
        if (claude is not null && claude.StartsWith("FAIL", StringComparison.OrdinalIgnoreCase)) return "FAILED";
        if (preflight is not null && preflight.StartsWith("CLEAR", StringComparison.OrdinalIgnoreCase) == false) return "BLOCKED";
        if (comp is not null || wb is not null && wb.StartsWith("PASS", StringComparison.OrdinalIgnoreCase)) return "SUCCESS";
        if (ct is not null && StateJson.Str(ct, "status") == "CONTROL_VALIDATED") return "SUCCESS";
        if (verification is not null || claude is not null) return "WAITING";
        return "WAITING";
    }

    /// <summary>Full per-stage artifact listing for a task (NOT APPLICABLE when the stage was never reached).</summary>
    public static List<TaskDetailItem> Detail(string dir)
    {
        var rows = new (string stage, string label, string file)[]
        {
            ("NEXT_TASK", "Next Task Selection", "NEXT_TASK.md"),
            ("PREFLIGHT_REPORT", "Preflight Report", "PREFLIGHT_REPORT.md"),
            ("START_BASELINE", "Reservation / Start Baseline", "START_BASELINE.md"),
            ("CHATGPT_HANDOFF", "ChatGPT Handoff", "CHATGPT_HANDOFF.md"),
            ("DEEPSEEK_PROMPT", "DeepSeek Prompt", "DEEPSEEK_PROMPT.md"),
            ("VERIFICATION_REPORT", "Verification Report", "VERIFICATION_REPORT.md"),
            ("REVIEW_PACKET", "Claude Review Packet", "REVIEW_PACKET.md"),
            ("CLAUDE_REVIEW_PROMPT", "Claude Review Prompt", "CLAUDE_REVIEW_PROMPT.md"),
            ("CLAUDE_REVIEW_RESULT", "Claude Review Result", "CLAUDE_REVIEW_RESULT.md"),
            ("FIX_CONTEXT", "Fix Context", "FIX_CONTEXT.md"),
            ("SHEET_UPDATE_PLAN", "Sheet Update Plan", "SHEET_UPDATE_PLAN.md"),
            ("COMPLETION_REPORT", "Completion Report", "COMPLETION_REPORT.md"),
            ("WORKBOOK_CONSISTENCY_REPORT", "Workbook Consistency Report", "WORKBOOK_CONSISTENCY_REPORT.md"),
        };
        var list = new List<TaskDetailItem>();
        foreach (var (stage, label, file) in rows)
        {
            string path = Path.Combine(dir, file);
            bool present = File.Exists(path);
            string? summary = present ? Summarize(path, label) : null;
            list.Add(new TaskDetailItem(stage, label, present, present ? path : null, summary));
        }
        return list;
    }

    private static string Summarize(string path, string label)
    {
        try
        {
            string txt = File.ReadAllText(path);
            txt = txt.Trim();
            int cut = Math.Min(240, txt.Length);
            return txt.Substring(0, cut) + (txt.Length > cut ? " …" : "");
        }
        catch { return null!; }
    }

    private static string? SniffReport(string path, string passMarker, string failMarker)
    {
        try
        {
            string txt = File.ReadAllText(path);
            if (txt.Contains(failMarker, StringComparison.OrdinalIgnoreCase)) return failMarker;
            if (txt.Contains(passMarker, StringComparison.OrdinalIgnoreCase)) return passMarker;
        }
        catch { }
        return null;
    }

    private static int CountOccurrences(string s, string needle)
    {
        int n = 0; int i = 0;
        while ((i = s.IndexOf(needle, i, StringComparison.OrdinalIgnoreCase)) >= 0) { n++; i += needle.Length; }
        return n;
    }

    private static int? Num(JsonElement? el, string key)
        => el is not null && el.Value.ValueKind == JsonValueKind.Object && el.Value.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;

    private static int? ArrayLen(JsonElement? el, string key)
        => el is not null && el.Value.ValueKind == JsonValueKind.Object && el.Value.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array ? v.GetArrayLength() : null;
}
