namespace DevBridge.Workspace;

/// <summary>
/// Uniform outcome for every <see cref="GitWorkspaceTool"/> operation. Expected
/// failures are returned, never thrown. <see cref="Detail"/> carries optional
/// structured payloads: for <c>ListWorktrees</c> it is a JSON array of
/// <see cref="WorktreeRecord"/>; for <c>GetWorktreeStatus</c> it is a JSON object
/// of <see cref="WorktreeStatusInfo"/>; for removal refusals it is the dirty-file
/// listing. Everything else treats <see cref="Detail"/> as free-form text.
/// </summary>
public sealed record WorkspaceResult(bool Success, string Message, string? Detail = null)
{
    public static WorkspaceResult Ok(string message, string? detail = null)
        => new(true, message, detail);

    public static WorkspaceResult Fail(string message, string? detail = null)
        => new(false, message, detail);

    public override string ToString()
        => Success ? $"OK: {Message}" : $"FAIL: {Message}";
}
