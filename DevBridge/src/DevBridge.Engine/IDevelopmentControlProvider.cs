// IDevelopmentControlProvider.cs — the boundary between Forge's orchestration code
// and the physical development-control store (Excel today, Azure later). Wave B
// continuation (2026-09-05): orchestration code should ask this interface for a
// role's workbook path/liveness/writer-lock rather than knowing a physical
// filename, sheet name, or column exists. Only ExcelDevelopmentControlProvider
// is implemented; AzureDevelopmentControlProvider does not exist yet and no
// caller should assume Excel is the only possible backing store.
//
// Forge boundary: this interface and ExcelDevelopmentControlProvider must never
// take a dependency on a running Nexus Platform/Developer/Product service, or on
// Azure. The Excel provider reads/writes local files only.
namespace DevBridge.Engine;

/// <summary>How the provider is currently resolving workbooks. Surfaced so callers
/// (and the UI) can tell a genuine V2 two-workbook setup from the V1 transitional
/// fallback, rather than silently treating them the same.</summary>
public enum DevelopmentControlMode
{
    /// <summary>Only the legacy single V1 workbook (NEXUS_DEVELOPMENT_CONTROL.xlsx)
    /// was found. Foundation resolves to it; Products has no data yet. This is the
    /// expected mode until Wave F migrates the V1 workbook into the two-workbook
    /// V2 layout — it is not an error.</summary>
    V1SingleWorkbookCompatibility,

    /// <summary>Foundation and Products each resolved to their own distinct V2
    /// workbook file.</summary>
    V2TwoWorkbook,
}

/// <summary>Result of an attempt to resolve an immutable ID to the workbook role
/// that owns it. This is the minimum boundary Task B02-5 asks for — a real
/// cross-workbook Context Resolver (content-level lookup, dependency traversal,
/// DCR linkage, lineage) is future work and is deliberately NOT implemented here.</summary>
public sealed record DevelopmentControlLookupResult(
    bool Supported,
    DevelopmentControlRole? Role,
    string? WorkbookPath,
    string Note);

public interface IDevelopmentControlProvider
{
    /// <summary>V1SingleWorkbookCompatibility or V2TwoWorkbook — never silently one or the other.</summary>
    DevelopmentControlMode Mode { get; }

    /// <summary>True when this role has a resolved, existing workbook file.</summary>
    bool IsRoleAvailable(DevelopmentControlRole role);

    /// <summary>Absolute path to the role's workbook, or "" if not configured/found.</summary>
    string GetWorkbookPath(DevelopmentControlRole role);

    /// <summary>Human-readable file name for the role's workbook (for UI/log display).</summary>
    string GetDisplayName(DevelopmentControlRole role);

    /// <summary>Read-only structural health probe (opens, sheet count, SHA-256) for the role's workbook.</summary>
    WorkbookLivenessResult ProbeLiveness(DevelopmentControlRole role);

    /// <summary>The sheet count a healthy workbook of this role is expected to have.
    /// Role-specific so a future Products schema need not match Foundation's.</summary>
    int ExpectedSheetCount(DevelopmentControlRole role);

    /// <summary>Acquire the writer lock that must be held before a governed write touching
    /// this role's workbook. See ExcelDevelopmentControlProvider's remarks on why this is
    /// currently ONE shared lock across both roles, not a per-role lock.</summary>
    (bool Acquired, string? Message) TryAcquireWriterLock(DevelopmentControlRole role, string? owner);

    void ReleaseWriterLock(DevelopmentControlRole role);

    bool IsWriterBusy(DevelopmentControlRole role);

    /// <summary>Attempt to resolve which role's workbook owns an immutable ID. Deliberately
    /// NOT a real content lookup (no cell/sheet reading) — establishes the access boundary
    /// the future Context Resolver will use, per Task B02-5. Always returns Supported=false
    /// today; the Note explains why.</summary>
    DevelopmentControlLookupResult TryResolveId(string immutableId);
}
