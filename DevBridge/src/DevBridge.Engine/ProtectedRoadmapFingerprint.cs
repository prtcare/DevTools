// ProtectedRoadmapFingerprint.cs — deterministic structural fingerprint of the
// PROTECTED roadmap surface (DB-GH01). It covers phase/milestone identity,
// hierarchy, goals/outcomes, acceptance criteria, dependencies, sequencing/
// structure, and architecture references — explicitly NOT a whole-workbook hash
// and NOT execution-state columns (status, progress, evidence, notes).
//
// The engine owns the rule model and the before/after guard. The actual
// OOXML extraction against a live workbook is performed by the read-only
// backend script scripts/Get-ProtectedRoadmapFingerprint.ps1, which emits the
// same fields; the guard logic here is the single source of truth for the
// verdict so that the backend and the UI agree.
using System;
using System.Collections.Generic;
using System.Linq;

namespace DevBridge.Engine;

/// <summary>
/// Protected-column configuration for one sheet: identity/hierarchy/structure
/// columns whose byte-equivalence must be proven across a governed write.
/// </summary>
public sealed record ProtectedSheetColumns(
    string Sheet,
    string HeaderRow,
    IReadOnlyList<string> IdentityColumns,     // node id, parent, hierarchy path
    IReadOnlyList<string> StructureColumns,    // goals/outcomes, acceptance criteria, deps, sequencing
    IReadOnlyList<string> ArchitectureColumns) // architecture references / ADR refs where applicable
{
    public IEnumerable<string> AllColumns => IdentityColumns.Concat(StructureColumns).Concat(ArchitectureColumns);
}

public sealed record RoadmapProtectionConfig(
    int SchemaVersion,
    string FingerprintAlgorithm,
    IReadOnlyList<ProtectedSheetColumns> Sheets)
{
    public bool IsValid(out IReadOnlyList<string> errors)
    {
        var e = new List<string>();
        if (SchemaVersion != 1) e.Add($"roadmap-protection schema version {SchemaVersion} != 1");
        if (!string.Equals(FingerprintAlgorithm, "SHA-256", StringComparison.OrdinalIgnoreCase))
            e.Add($"fingerprint algorithm '{FingerprintAlgorithm}' != SHA-256");
        if (Sheets is null || Sheets.Count == 0) e.Add("no protected sheets configured");
        foreach (var s in Sheets ?? new List<ProtectedSheetColumns>())
        {
            if (string.IsNullOrWhiteSpace(s.Sheet)) e.Add("sheet name blank");
            if (string.IsNullOrWhiteSpace(s.HeaderRow)) e.Add($"sheet '{s.Sheet}' header row blank");
            if (!s.IdentityColumns.Any()) e.Add($"sheet '{s.Sheet}' has no identity columns");
            var dup = s.AllColumns.GroupBy(c => c, StringComparer.OrdinalIgnoreCase).FirstOrDefault(g => g.Count() > 1);
            if (dup is not null) e.Add($"sheet '{s.Sheet}' column '{dup.Key}' listed more than once");
        }
        errors = e;
        return e.Count == 0;
    }
}

/// <summary>Result of fingerprinting one workbook.</summary>
public sealed record ProtectedRoadmapFingerprint(
    string Value,          // deterministic SHA-256 over the protected surface
    string SheetCoverage,  // "Master Roadmap;Phase Plan;Architecture Decisions" etc.
    string ConfigSource,   // config file path or "test-fixture"
    string? Error);        // non-null when the fingerprint could not be computed

public enum RoadmapGuardVerdict
{
    Preserved,
    StructureChanged,
    NotComparable,
}

public static class ProtectedRoadmapFingerprintGuard
{
    public const string BlockToken = "ROADMAP_STRUCTURE_WRITE_PROHIBITED";

    /// <summary>Before/after guard. Any protected change blocks the governed write.</summary>
    public static RoadmapGuardVerdict Guard(ProtectedRoadmapFingerprint? before, ProtectedRoadmapFingerprint? after)
    {
        if (before is null || after is null) return RoadmapGuardVerdict.NotComparable;
        if (before.Error is not null || after.Error is not null) return RoadmapGuardVerdict.NotComparable;
        return string.Equals(before.Value, after.Value, StringComparison.OrdinalIgnoreCase)
            ? RoadmapGuardVerdict.Preserved
            : RoadmapGuardVerdict.StructureChanged;
    }

    public static string BlockMessage(RoadmapGuardVerdict verdict) => verdict switch
    {
        RoadmapGuardVerdict.StructureChanged =>
            $"{BlockToken}: the protected roadmap surface changed between fingerprint capture and the governed write.",
        RoadmapGuardVerdict.NotComparable =>
            $"{BlockToken}: the protected roadmap fingerprint could not be computed or compared; the write is blocked.",
        _ => "",
    };
}
