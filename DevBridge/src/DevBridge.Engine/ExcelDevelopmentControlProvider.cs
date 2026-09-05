// ExcelDevelopmentControlProvider.cs — the Phase 1 IDevelopmentControlProvider
// implementation, backed by local Excel files (ClosedXML/OOXML on disk). This is
// the only implementation that exists; AzureDevelopmentControlProvider is future
// work (Wave F+) and is not started here.
//
// Forge boundary: this class touches only the local filesystem (via DevBridgeConfig,
// WorkbookLiveness, WorkbookWriterGate). It must never call a running Nexus
// Platform/Developer/Product service or Azure — Forge stays operational even when
// all of those are down.
//
// Writer-lock design (Task B02-4): TryAcquireWriterLock/IsWriterBusy/ReleaseWriterLock
// delegate to the existing WorkbookWriterGate, which is ONE lock file scoped to the
// DevBridge root (cfg.Root), not to an individual workbook. This provider deliberately
// keeps that as ONE SHARED lock across both roles rather than introducing a second,
// role-specific lock file. Reasons, recorded here rather than left implicit:
//   * Today only the Foundation role has real, live content (the V1 workbook); the
//     Products workbook is an empty placeholder, so per-role contention does not
//     exist yet to justify separate locks.
//   * A governed operation that must touch both workbooks atomically (e.g. a DCR
//     that starts in Products and creates a linked Platform task in Foundation)
//     is safer under ONE gate than under two gates acquired in some order — two
//     locks introduces real ordering/deadlock risk for no current benefit.
//   * "Do not overbuild distributed locking" — a per-role lock is straightforward
//     to add later (Wave F, once Products has real concurrent writers) without
//     changing this interface; TryAcquireWriterLock already takes a role parameter
//     so that future split is a provider-internal change, not a caller-facing one.
using System.Collections.Generic;

namespace DevBridge.Engine;

public sealed class ExcelDevelopmentControlProvider : IDevelopmentControlProvider
{
    private readonly DevBridgeConfig _cfg;

    public ExcelDevelopmentControlProvider(DevBridgeConfig cfg) => _cfg = cfg;

    public DevelopmentControlMode Mode
    {
        get
        {
            string foundation = _cfg.GetWorkbookPath(DevelopmentControlRole.Foundation);
            string products = _cfg.GetWorkbookPath(DevelopmentControlRole.Products);
            bool foundationIsLegacySingleWorkbook =
                Path.GetFileName(foundation).Equals("NEXUS_DEVELOPMENT_CONTROL.xlsx", StringComparison.OrdinalIgnoreCase);
            return (foundationIsLegacySingleWorkbook || string.IsNullOrWhiteSpace(products) || !File.Exists(products))
                ? DevelopmentControlMode.V1SingleWorkbookCompatibility
                : DevelopmentControlMode.V2TwoWorkbook;
        }
    }

    public bool IsRoleAvailable(DevelopmentControlRole role)
    {
        string path = GetWorkbookPath(role);
        return !string.IsNullOrWhiteSpace(path) && File.Exists(path);
    }

    public string GetWorkbookPath(DevelopmentControlRole role) => _cfg.GetWorkbookPath(role);

    public string GetDisplayName(DevelopmentControlRole role)
    {
        string path = GetWorkbookPath(role);
        if (!string.IsNullOrWhiteSpace(path)) return Path.GetFileName(path);
        return role switch
        {
            DevelopmentControlRole.Foundation => "NEXUS_FOUNDATION_DEVELOPMENT_CONTROL.xlsx",
            DevelopmentControlRole.Products => "NEXUS_PRODUCTS_DEVELOPMENT_CONTROL.xlsx",
            _ => "",
        };
    }

    public WorkbookLivenessResult ProbeLiveness(DevelopmentControlRole role) =>
        WorkbookLiveness.Probe(GetWorkbookPath(role));

    public int ExpectedSheetCount(DevelopmentControlRole role) => role switch
    {
        // The Foundation role inherits the live V1 workbook's schema until Wave F.
        DevelopmentControlRole.Foundation => WorkbookLiveness.ExpectedSheets,
        // Products has no live schema yet — Wave F defines it. 0 means "not yet
        // known", not "expected empty"; callers must not treat 0 as a health failure.
        DevelopmentControlRole.Products => 0,
        _ => 0,
    };

    public (bool Acquired, string? Message) TryAcquireWriterLock(DevelopmentControlRole role, string? owner) =>
        WorkbookWriterGate.TryAcquire(_cfg, owner);

    public void ReleaseWriterLock(DevelopmentControlRole role) => WorkbookWriterGate.Release(_cfg);

    public bool IsWriterBusy(DevelopmentControlRole role) => WorkbookWriterGate.IsBusy(_cfg);

    public DevelopmentControlLookupResult TryResolveId(string immutableId) =>
        new(Supported: false, Role: null, WorkbookPath: null,
            Note: "Cross-workbook ID resolution requires reading workbook content (sheet/cell data), " +
                  "which this provider does not do — it only resolves file paths and structural liveness. " +
                  "This is the access boundary Task B02-5 establishes; the Context Resolver that performs " +
                  "real ID/dependency/DCR/lineage lookup is future work, out of scope for this batch.");
}
