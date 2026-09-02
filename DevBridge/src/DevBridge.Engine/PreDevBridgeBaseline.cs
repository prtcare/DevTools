// PreDevBridgeBaseline.cs — the pre-DevBridge restart point (DB-GH01). The
// workbook and Nexus git state as they were BEFORE DevBridge began operating
// are captured and represented so that a later REAL NEXUS restart is possible.
//
// ABSOLUTE RULE: this type REPRESENTS the baseline. It contains NO restore
// function and no destructive code path. Restoration is a human-governed
// decision made later (the operator explicitly asks for it); DevBridge must
// never auto-run `git reset --hard`, `git clean`, overwrite the workbook with
// a backup, or delete trial source.
using System;
using System.Text.Json;

namespace DevBridge.Engine;

public sealed record PreDevBridgeWorkbookBaseline(string Path, string Sha256, string CapturedAtUtc);
public sealed record PreDevBridgeGitBaseline(string Repository, string Branch, string HeadCommit, string CapturedAtUtc);

public sealed record PreDevBridgeBaselineState(
    PreDevBridgeWorkbookBaseline? Workbook,
    PreDevBridgeGitBaseline? Git,
    bool Present)
{
    public static PreDevBridgeBaselineState Empty => new(null, null, false);
}

public static class PreDevBridgeBaseline
{
    public const string FileName = "pre-devbridge-baseline.json";

    public static string FilePath(DevBridgeConfig cfg) => Path.Combine(cfg.StateDir, FileName);

    public static PreDevBridgeBaselineState Load(DevBridgeConfig cfg)
    {
        string path = FilePath(cfg);
        var el = StateJson.TryRead(path);
        if (el is null) return PreDevBridgeBaselineState.Empty;

        PreDevBridgeWorkbookBaseline? wb = null;
        if (el.Value.TryGetProperty("workbook", out var w) && w.ValueKind == JsonValueKind.Object)
        {
            wb = new PreDevBridgeWorkbookBaseline(
                StateJson.Str(w, "path") ?? "",
                StateJson.Str(w, "sha256") ?? "",
                StateJson.Str(w, "capturedAtUtc") ?? "");
        }
        PreDevBridgeGitBaseline? git = null;
        if (el.Value.TryGetProperty("git", out var g) && g.ValueKind == JsonValueKind.Object)
        {
            git = new PreDevBridgeGitBaseline(
                StateJson.Str(g, "repository") ?? "",
                StateJson.Str(g, "branch") ?? "",
                StateJson.Str(g, "headCommit") ?? "",
                StateJson.Str(g, "capturedAtUtc") ?? "");
        }
        bool present = wb is not null || git is not null;
        return new PreDevBridgeBaselineState(wb, git, present);
    }

    /// <summary>
    /// Explicit human authorization boundary. Auto-restore is impossible by
    /// construction — there is no restore function. This guidance is what the
    /// UI/engine MAY show the operator; it is never executed by DevBridge.
    /// </summary>
    public static string RestoreAuthorizationGuidance(string workbookPath, string gitRepo)
        => $"Restoring the real Nexus baseline (workbook {workbookPath} and {gitRepo}) is a HUMAN action. "
           + "DevBridge only represents the captured baseline; it never resets git, cleans files, "
           + "overwrites the workbook, or deletes trial source automatically.";
}
