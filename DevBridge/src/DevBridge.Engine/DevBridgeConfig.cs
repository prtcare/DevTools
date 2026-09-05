// DevBridgeConfig.cs — reads config/devbridge.json. Resolves the two Nexus
// development-control workbook roles (Foundation, Products) that Forge reads
// and writes; WorkbookPath/WorkbookDisplayName remain as the Foundation-role
// legacy accessors so existing single-workbook call sites keep working while
// they migrate to the role-aware API. Also loads the explicit operating MODE
// (TRIAL | REAL_NEXUS_DEVELOPMENT) and the protected-roadmap fingerprint config.
// Forge is permanent Nexus development-plane infrastructure — there is no
// retirement lifecycle here or anywhere else in this project (2026-09-05).
using System.Text.Json;

namespace DevBridge.Engine;

public sealed class DevBridgeConfig
{
    public string Root { get; init; } = "";
    public string StateDir { get; init; } = "";
    public string TasksDir { get; init; } = "";
    public string LogsTasksDir { get; init; } = "";
    public string ScriptsDir { get; init; } = "";
    /// <summary>Legacy single-workbook accessor — resolves to the Foundation role's path. Prefer <see cref="WorkbookPaths"/> for new code.</summary>
    public string WorkbookPath { get; init; } = "";
    /// <summary>Legacy single-workbook accessor — resolves to the Foundation role's display name. Prefer <see cref="WorkbookPaths"/> for new code.</summary>
    public string WorkbookDisplayName { get; init; } = "NEXUS_FOUNDATION_DEVELOPMENT_CONTROL.xlsx";

    /// <summary>The two Nexus development-control workbook roles, each resolved to an absolute path (empty string if not found/configured).</summary>
    public IReadOnlyDictionary<DevelopmentControlRole, string> WorkbookPaths { get; init; } =
        new Dictionary<DevelopmentControlRole, string>
        {
            [DevelopmentControlRole.Foundation] = "",
            [DevelopmentControlRole.Products] = "",
        };

    /// <summary>Resolve a workbook path by role. Returns "" if that role's workbook has not been configured/found.</summary>
    public string GetWorkbookPath(DevelopmentControlRole role) =>
        WorkbookPaths.TryGetValue(role, out var path) ? path : "";

    /// <summary>Explicit mode from config (default TRIAL). Per-cycle override may live in current-task.json.</summary>
    public DevBridgeOperatingMode Mode { get; init; } = DevBridgeOperatingMode.Trial;

    /// <summary>Protected roadmap fingerprint configuration (null = not configured → guard is NotComparable).</summary>
    public RoadmapProtectionConfig? RoadmapProtection { get; init; }

    public static DevBridgeConfig Load(string? rootOverride = null)
    {
        string root = rootOverride ?? LocateRoot();
        string cfgFile = Path.Combine(root, "config", "devbridge.json");
        string foundationWorkbook = "";
        string productsWorkbook = "";
        string modeToken = "";
        if (File.Exists(cfgFile))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(cfgFile));
                // Two-workbook config shape: { "developmentControlWorkbooks": { "foundation": "...", "products": "..." } }.
                if (doc.RootElement.TryGetProperty("developmentControlWorkbooks", out var wbRoles))
                {
                    if (wbRoles.TryGetProperty("foundation", out var fw)) foundationWorkbook = fw.GetString() ?? "";
                    if (wbRoles.TryGetProperty("products", out var pw)) productsWorkbook = pw.GetString() ?? "";
                }
                // Legacy single-workbook config key. Treated as the Foundation role unless
                // developmentControlWorkbooks.foundation already set it explicitly.
                if (string.IsNullOrWhiteSpace(foundationWorkbook) &&
                    doc.RootElement.TryGetProperty("developmentControlWorkbook", out var wb))
                    foundationWorkbook = wb.GetString() ?? "";
                if (doc.RootElement.TryGetProperty("mode", out var md))
                    modeToken = md.GetString() ?? "";
            }
            catch (JsonException) { /* fall back to default */ }
        }
        if (string.IsNullOrWhiteSpace(foundationWorkbook) || !File.Exists(foundationWorkbook))
        {
            // Second chance: the two-workbook set lives beside the repo by convention (V2 target layout).
            string repoParent = Path.GetFullPath(Path.Combine(root, ".."));
            string foundationFallback = Path.Combine(repoParent, "Nexus.Developer", "NEXUS_FOUNDATION_DEVELOPMENT_CONTROL.xlsx");
            // V1 compatibility: the pre-split single workbook, still the live authoritative file until Wave F migrates it.
            string legacySingleWorkbook = Path.Combine(repoParent, "Nexus.Developer", "NEXUS_DEVELOPMENT_CONTROL.xlsx");
            if (string.IsNullOrWhiteSpace(foundationWorkbook) && File.Exists(foundationFallback)) foundationWorkbook = foundationFallback;
            else if (string.IsNullOrWhiteSpace(foundationWorkbook) && File.Exists(legacySingleWorkbook)) foundationWorkbook = legacySingleWorkbook;
        }
        if (string.IsNullOrWhiteSpace(productsWorkbook) || !File.Exists(productsWorkbook))
        {
            string productsFallback = Path.Combine(Path.GetFullPath(Path.Combine(root, "..")), "Nexus.Developer", "NEXUS_PRODUCTS_DEVELOPMENT_CONTROL.xlsx");
            if (string.IsNullOrWhiteSpace(productsWorkbook) && File.Exists(productsFallback)) productsWorkbook = productsFallback;
        }
        return new DevBridgeConfig
        {
            Root = root,
            StateDir = Path.Combine(root, "state"),
            TasksDir = Path.Combine(root, "tasks"),
            LogsTasksDir = Path.Combine(root, "logs", "tasks"),
            ScriptsDir = Path.Combine(root, "scripts"),
            WorkbookPath = foundationWorkbook,
            WorkbookDisplayName = string.IsNullOrWhiteSpace(foundationWorkbook) ? "NEXUS_FOUNDATION_DEVELOPMENT_CONTROL.xlsx" : Path.GetFileName(foundationWorkbook),
            WorkbookPaths = new Dictionary<DevelopmentControlRole, string>
            {
                [DevelopmentControlRole.Foundation] = foundationWorkbook,
                [DevelopmentControlRole.Products] = productsWorkbook,
            },
            Mode = DevBridgeMode.FromString(modeToken),
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
