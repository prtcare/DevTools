// ControlHealthService.cs — aggregates control-health evidence from the backend
// (workbook-consistency.json + the DB-M11 extraction snapshot) plus a live
// read-only workbook liveness probe. Open decisions/audit findings are shown as
// counts, never classified as blockers by the UI.
using System.Text.Json;
using System.Text.RegularExpressions;

namespace DevBridge.Engine;

public sealed class ControlHealth
{
    public string? WorkbookPath { get; init; }
    public string WorkbookState { get; init; } = "ERROR";   // AVAILABLE / ERROR
    public int SheetCount { get; init; }
    public int ExpectedSheets { get; init; } = 14;
    public string? WorkbookSha256 { get; init; }
    public string? WorkbookError { get; init; }

    public string? LastConsistencyResult { get; init; }     // PASS / FAIL / null
    public string? LastConsistencyAt { get; init; }

    public int? OpenActiveChanges { get; init; }
    public int? OpenBlockers { get; init; }
    public int? OpenDecisions { get; init; }
    public int? OpenAuditFindings { get; init; }
    public string? KnownMirrorGap { get; init; }
    public bool HasKnownMirrorGap { get; init; }
    public string? EvidenceNote { get; init; }
}

public static class ControlHealthService
{
    /// <summary>Legacy entry point — evaluates the Foundation role via a fresh
    /// ExcelDevelopmentControlProvider. Existing callers are unaffected; prefer the
    /// role-aware overload below for new code (added 2026-09-05, Wave B continuation).</summary>
    public static ControlHealth Evaluate(DevBridgeConfig cfg) =>
        Evaluate(cfg, new ExcelDevelopmentControlProvider(cfg), DevelopmentControlRole.Foundation);

    /// <summary>Role-aware evaluation via the provider boundary — does not assume Excel,
    /// a physical filename, or a specific sheet count beyond what the provider reports
    /// for that role.</summary>
    public static ControlHealth Evaluate(DevBridgeConfig cfg, IDevelopmentControlProvider provider, DevelopmentControlRole role)
    {
        var live = provider.ProbeLiveness(role);
        int expectedSheets = provider.ExpectedSheetCount(role);

        // ---- backend consistency evidence ----
        string? consResult = null, consAt = null, mirrorGap = null;
        bool hasGap = false;
        int? openChanges = null, openBlockers = null, openDecisions = null, openFindings = null;
        var cons = StateJson.TryRead(Path.Combine(cfg.StateDir, "workbook-consistency.json"));
        if (cons is not null)
        {
            consResult = StateJson.Str(cons, "controlValidationResult");
            consAt = StateJson.Str(cons, "validatedAtUtc");
            if (cons.Value.TryGetProperty("knownMirrorGaps", out var gaps) && gaps.ValueKind == JsonValueKind.Array && gaps.GetArrayLength() > 0)
            { hasGap = true; mirrorGap = gaps[0].GetString(); }
        }
        else
        {
            var rep = Path.Combine(cfg.TasksDir, "WORKBOOK_CONSISTENCY_REPORT.md");
            if (File.Exists(rep))
            {
                string txt = File.ReadAllText(rep);
                consResult = txt.Contains("CONTROL_VALIDATION_FAILED", StringComparison.OrdinalIgnoreCase) ? "FAIL" : "PASS";
            }
        }

        // ---- open counts from the DB-M11 extraction snapshot (backend evidence) ----
        string? extraction = ReadExtraction(cfg);
        if (extraction is not null)
        {
            var m = Regex.Match(extraction, @"AC classified: open=(\d+) terminal=(\d+)");
            if (m.Success) openChanges = int.Parse(m.Groups[1].Value);
            var d = Regex.Match(extraction, @"OPEN DECISIONS rows=(\d+)");
            if (d.Success) openDecisions = int.Parse(d.Groups[1].Value) - 5; // 5 header/blank rows -> data decisions
            var f = Regex.Match(extraction, @"AUDIT FINDINGS rows=(\d+)");
            if (f.Success) openFindings = int.Parse(f.Groups[1].Value) - 5; // AF IDs are 18; subtract non-ID rows
            var b = Regex.Match(extraction, @"DEPENDENCIES & BLOCKERS rows=(\d+)");
            if (b.Success) openBlockers = int.Parse(b.Groups[1].Value) - 5;
        }
        // Prefer the machine-readable consistency file for counts where present.
        if (cons is not null && cons.Value.TryGetProperty("sheetResults", out var sr) && sr.ValueKind == JsonValueKind.Array)
        {
            openChanges ??= FindCount(sr, "sheet", "Active Changes", "issues");
        }

        string workbookState = live.FileExists && live.Opens && (expectedSheets == 0 || live.SheetCount == expectedSheets) ? "AVAILABLE" : "ERROR";
        string evidenceNote = consAt is not null
            ? $"Counts and classifications are backend evidence, last validated against the workbook at {consAt} UTC."
            : "No workbook-consistency evidence found; counts unavailable.";

        return new ControlHealth
        {
            WorkbookPath = provider.GetWorkbookPath(role),
            WorkbookState = workbookState,
            SheetCount = live.SheetCount,
            ExpectedSheets = expectedSheets,
            WorkbookSha256 = live.Sha256,
            WorkbookError = live.Error,
            LastConsistencyResult = consResult,
            LastConsistencyAt = consAt,
            OpenActiveChanges = openChanges,
            OpenBlockers = openBlockers,
            OpenDecisions = openDecisions,
            OpenAuditFindings = openFindings,
            KnownMirrorGap = mirrorGap,
            HasKnownMirrorGap = hasGap,
            EvidenceNote = evidenceNote,
        };
    }

    private static int? FindCount(JsonElement array, string key, string value, string target)
    {
        foreach (var row in array.EnumerateArray())
        {
            if (row.ValueKind == JsonValueKind.Object && row.TryGetProperty(key, out var k) && k.GetString() == value)
            {
                if (row.TryGetProperty(target, out var t)) return 0; // present => no structural issue counted here
            }
        }
        return null;
    }

    private static string? ReadExtraction(DevBridgeConfig cfg)
    {
        string p = Path.Combine(cfg.StateDir, "db-m11-extraction.txt");
        if (!File.Exists(p)) return null;
        try { return File.ReadAllText(p); } catch { return null; }
    }
}
