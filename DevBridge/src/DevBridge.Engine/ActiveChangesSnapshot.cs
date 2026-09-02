// ActiveChangesSnapshot.cs — parallel development view. Reads the DB-M11
// extraction snapshot (backend-produced evidence) for the Active Changes ledger.
// Read-only; the UI shows which work is reserved/running in other lanes but never
// schedules and never classifies parallel safety itself.
//
// Two evidence sections are merged:
//   * the compact per-row inventory  (row N: A=[CHG-...] L-lead=[...]) — the full
//     ledger, every change id + Status-lead text;
//   * the raw ACTIVE CHANGES rows    (row N: A=... C=... L=... U=... W=... AC=... AD=...
//     -> classify=Open|Terminal)     — rich detail for the most recent rows.
// Classification uses the backend's explicit classify where present, otherwise the
// documented leading-keyword rule (Status begins "Completed"/"Cancelled" => Terminal).
using System.Text.RegularExpressions;

namespace DevBridge.Engine;

public sealed record ActiveChangeRow(
    string ChangeId,
    string StatusLead,
    string Classification,      // Open | Terminal
    string NodeContext,         // C= scope / node context when captured, else "-"
    string? Worker,             // U= worker id / timestamp when captured, else null
    string? Activity,           // AC= activity type when captured, else null
    string? Verification,       // AD= verification note when captured, else null
    string? SourceLine)
{
    // Repository and Risk are not present in the DB-M11 extraction evidence. The UI
    // must never guess (DB-M12.1 Part 14), so they render as "UNKNOWN / NOT AVAILABLE"
    // — display-only, no backend claim. The operator console never schedules.
    public string RepositoryDisplay => "UNKNOWN / NOT AVAILABLE";
    public string RiskDisplay => "UNKNOWN / NOT AVAILABLE";
}

public static class ActiveChangesSnapshot
{
    public static (List<ActiveChangeRow> Rows, int OpenCount, int TerminalCount, string EvidenceTimestamp) Load(DevBridgeConfig cfg)
    {
        string? text = Read(cfg);
        string timestamp = "unknown";
        var rows = new List<ActiveChangeRow>();
        int open = 0, terminal = 0;
        if (text is null) return (rows, 0, 0, timestamp);

        var ts = Regex.Match(text, @"DB-M11.*?\d{4}-\d{2}-\d{2}");
        if (ts.Success) timestamp = ts.Value;

        // Pass 1: rich detail from the raw ACTIVE CHANGES rows (C/L/U/AC/AD/classify).
        var detail = new Dictionary<string, (string C, string L, string U, string AC, string AD, string? classify)>();
        foreach (var line in text.Split('\n'))
        {
            if (!line.Contains("classify=", StringComparison.Ordinal)) continue;
            var m = Regex.Match(line, @"A=\[([A-Z]{3}-[^\]]+)\](.*)classify=(\w+)");
            if (!m.Success) continue;
            string id = m.Groups[1].Value;
            if (!id.StartsWith("CHG-", StringComparison.OrdinalIgnoreCase)) continue;
            string rest = m.Groups[2].Value;
            string c = Grab(rest, @"C=\[([^\]]*)\]") ?? "";
            string l = Grab(rest, @"L=\[([^\]]*)\]") ?? "";
            string u = Grab(rest, @"U=\[([^\]]*)\]") ?? "";
            string ac = Grab(rest, @"AC=\[([^\]]*)\]") ?? "";
            string ad = Grab(rest, @"AD=\[([^\]]*)\]") ?? "";
            detail[id] = (c, l, u, ac, ad, m.Groups[3].Value);
        }

        // Pass 2: full inventory from the compact per-row section, enriched from detail.
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in text.Split('\n'))
        {
            if (!line.Contains("row ", StringComparison.Ordinal)) continue;
            var m = Regex.Match(line, @"row (\d+): A=\[([A-Z]{3}-[^\]]+)\] L-lead=\[([^\]]*)\]");
            if (!m.Success) continue;
            string id = m.Groups[2].Value;
            if (!id.StartsWith("CHG-", StringComparison.OrdinalIgnoreCase)) continue;
            string lead = m.Groups[3].Value;
            AddRow(rows, detail, ref open, ref terminal, id, lead, line.Trim());
            seen.Add(id);
        }

        // Pass 3: any change present ONLY in the raw section (rich detail, no compact
        // row) still belongs in the inventory — the L= text is its Status-lead.
        foreach (var (id, d) in detail)
        {
            if (seen.Contains(id)) continue;
            AddRow(rows, detail, ref open, ref terminal, id, d.L, $"(raw) {id}");
            seen.Add(id);
        }
        return (rows, open, terminal, timestamp);
    }

    private static void AddRow(List<ActiveChangeRow> rows,
        Dictionary<string, (string C, string L, string U, string AC, string AD, string? classify)> detail,
        ref int open, ref int terminal, string id, string fallbackLead, string sourceLine)
    {
        string classification;
        string ctx;
        string lead;
        string? worker, activity, verification;
        if (detail.TryGetValue(id, out var d))
        {
            classification = d.classify is "Open" or "Terminal" ? d.classify : LeadingKeyword(d.L);
            lead = d.L;
            ctx = d.C;
            worker = string.IsNullOrWhiteSpace(d.U) ? null : d.U;
            activity = string.IsNullOrWhiteSpace(d.AC) ? null : d.AC;
            verification = string.IsNullOrWhiteSpace(d.AD) ? null : d.AD;
        }
        else
        {
            classification = LeadingKeyword(fallbackLead);
            lead = fallbackLead;
            ctx = "";
            worker = null; activity = null; verification = null;
        }

        bool isTerminal = classification == "Terminal";
        if (isTerminal) terminal++; else open++;
        rows.Add(new ActiveChangeRow(id, lead, classification, string.IsNullOrWhiteSpace(ctx) ? "-" : ctx,
            worker, activity, verification, sourceLine));
    }

    /// <summary>Documented leading-keyword rule: Status trimmed begins Completed/Cancelled => Terminal.</summary>
    private static string LeadingKeyword(string lead)
    {
        string t = lead.Trim();
        if (t.StartsWith("Completed", StringComparison.OrdinalIgnoreCase)
            || t.StartsWith("Cancelled", StringComparison.OrdinalIgnoreCase)) return "Terminal";
        return "Open";
    }

    private static string? Grab(string rest, string pattern)
    {
        var m = Regex.Match(rest, pattern);
        return m.Success ? m.Groups[1].Value : null;
    }

    private static string? Read(DevBridgeConfig cfg)
    {
        string p = Path.Combine(cfg.StateDir, "db-m11-extraction.txt");
        if (!File.Exists(p)) return null;
        try { return File.ReadAllText(p); } catch { return null; }
    }
}
