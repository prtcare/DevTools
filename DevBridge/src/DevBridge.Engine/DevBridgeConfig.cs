// DevBridgeConfig.cs — reads config/devbridge.json. The authoritative workbook
// path comes from here; the UI treats the workbook as the single source of truth.
// Also loads the explicit operating MODE (TRIAL | REAL_NEXUS_DEVELOPMENT), the
// DevBridge retirement state, and the protected-roadmap fingerprint config.
using System.Text.Json;

namespace DevBridge.Engine;

public sealed class DevBridgeConfig
{
    public string Root { get; init; } = "";
    public string StateDir { get; init; } = "";
    public string TasksDir { get; init; } = "";
    public string LogsTasksDir { get; init; } = "";
    public string ScriptsDir { get; init; } = "";
    public string WorkbookPath { get; init; } = "";
    public string WorkbookDisplayName { get; init; } = "NEXUS_DEVELOPMENT_CONTROL.xlsx";

    /// <summary>Explicit mode from config (default TRIAL). Per-cycle override may live in current-task.json.</summary>
    public DevBridgeOperatingMode Mode { get; init; } = DevBridgeOperatingMode.Trial;

    /// <summary>DevBridge's own lifecycle position.</summary>
    public DevBridgeRetirementState Retirement { get; init; } = DevBridgeRetirementState.ActiveTemporaryBridge;

    /// <summary>Protected roadmap fingerprint configuration (null = not configured → guard is NotComparable).</summary>
    public RoadmapProtectionConfig? RoadmapProtection { get; init; }

    public static DevBridgeConfig Load(string? rootOverride = null)
    {
        string root = rootOverride ?? LocateRoot();
        string cfgFile = Path.Combine(root, "config", "devbridge.json");
        string workbook = "";
        string modeToken = "";
        string retirementToken = "";
        if (File.Exists(cfgFile))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(cfgFile));
                if (doc.RootElement.TryGetProperty("developmentControlWorkbook", out var wb))
                    workbook = wb.GetString() ?? "";
                if (doc.RootElement.TryGetProperty("mode", out var md))
                    modeToken = md.GetString() ?? "";
                if (doc.RootElement.TryGetProperty("retirement", out var rt))
                    retirementToken = rt.GetString() ?? "";
            }
            catch (JsonException) { /* fall back to default */ }
        }
        if (string.IsNullOrWhiteSpace(workbook) || !File.Exists(workbook))
        {
            // Second chance: the workbook lives beside the repo by convention.
            string fallback = Path.Combine(Path.GetFullPath(Path.Combine(root, "..")), "Nexus.Developer", "NEXUS_DEVELOPMENT_CONTROL.xlsx");
            if (string.IsNullOrWhiteSpace(workbook) && File.Exists(fallback)) workbook = fallback;
        }
        return new DevBridgeConfig
        {
            Root = root,
            StateDir = Path.Combine(root, "state"),
            TasksDir = Path.Combine(root, "tasks"),
            LogsTasksDir = Path.Combine(root, "logs", "tasks"),
            ScriptsDir = Path.Combine(root, "scripts"),
            WorkbookPath = workbook,
            WorkbookDisplayName = string.IsNullOrWhiteSpace(workbook) ? "NEXUS_DEVELOPMENT_CONTROL.xlsx" : Path.GetFileName(workbook),
            Mode = DevBridgeMode.FromString(modeToken),
            Retirement = DevBridgeRetirement.FromString(retirementToken),
            RoadmapProtection = LoadRoadmapProtection(root),
        };
    }

    /// <summary>Load config/roadmap-protection.json tolerantly. Missing/malformed => null (guard NotComparable).</summary>
    public static RoadmapProtectionConfig? LoadRoadmapProtection(string root)
    {
        string path = Path.Combine(root, "config", "roadmap-protection.json");
        var el = StateJson.TryRead(path);
        if (el is null) return null;
        try
        {
            int schema = StateJson.Str(el, "schemaVersion") is string sv && int.TryParse(sv, out var s) ? s : -1;
            string algo = StateJson.Str(el, "fingerprintAlgorithm") ?? "SHA-256";
            var sheets = new List<ProtectedSheetColumns>();
            if (el.Value.TryGetProperty("sheets", out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                foreach (var sh in arr.EnumerateArray())
                {
                    sheets.Add(new ProtectedSheetColumns(
                        StateJson.Str(sh, "sheet") ?? "",
                        StateJson.Str(sh, "headerRow") ?? "",
                        StringList(sh, "identityColumns") ?? Array.Empty<string>(),
                        StringList(sh, "structureColumns") ?? Array.Empty<string>(),
                        StringList(sh, "architectureColumns") ?? Array.Empty<string>()));
                }
            }
            return new RoadmapProtectionConfig(schema, algo, sheets);
        }
        catch (Exception) { return null; }

        static IReadOnlyList<string>? StringList(JsonElement? parent, string key)
        {
            if (parent is null || !parent.Value.TryGetProperty(key, out var arr) || arr.ValueKind != JsonValueKind.Array) return Array.Empty<string>();
            var list = new List<string>();
            foreach (var v in arr.EnumerateArray())
                if (v.ValueKind == JsonValueKind.String) list.Add(v.GetString()!);
            return list;
        }
    }

    /// <summary>Locate the DevBridge root from the assembly location (bin path) by walking up to the folder that holds config/.</summary>
    private static string LocateRoot()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir, "config", "devbridge.json"))) return dir;
            dir = Path.GetDirectoryName(dir);
        }
        return AppContext.BaseDirectory;
    }
}
