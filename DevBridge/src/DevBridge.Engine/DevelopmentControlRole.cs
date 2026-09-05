// DevelopmentControlRole.cs — the two Nexus development-control workbook roles Forge
// is aware of. Replaces the single-workbook assumption formerly baked into
// DevBridgeConfig.WorkbookPath. Introduced 2026-09-05 per the approved V2
// two-workbook Development Control model (Wave A reconciliation).
namespace DevBridge.Engine;

public enum DevelopmentControlRole
{
    /// <summary>NEXUS_FOUNDATION_DEVELOPMENT_CONTROL.xlsx — Nexus Forge, Nexus Platform, all 10 layers.</summary>
    Foundation,

    /// <summary>NEXUS_PRODUCTS_DEVELOPMENT_CONTROL.xlsx — all Nexus products (Developer, Business OS, Trips, future).</summary>
    Products,
}
