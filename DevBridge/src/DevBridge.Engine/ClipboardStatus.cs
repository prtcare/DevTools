// ClipboardStatus.cs — clipboard workflow status (Part 11).
//
// The UI never auto-sends information to external AI services. It only copies a
// generated artifact verbatim and reports a clear status:
//   READY TO COPY / COPIED / ARTIFACT MISSING / NOT APPLICABLE / ERROR
// The mapping is a pure function so the status logic is testable in Engine.
namespace DevBridge.Engine;

public enum ClipboardStatusKind
{
    ReadyToCopy,
    Copied,
    ArtifactMissing,
    NotApplicable,
    Error,
}

public sealed record ClipboardStatusInfo(ClipboardStatusKind Kind, string Label, string Message)
{
    public static ClipboardStatusInfo ForResult(bool ok, string message) => ok
        ? new ClipboardStatusInfo(ClipboardStatusKind.Copied, "COPIED", message)
        : new ClipboardStatusInfo(ClipboardStatusKind.Error, "ERROR", message);
}

public static class ClipboardStatusMapper
{
    /// <summary>Map whether the artifact file exists to the pre-copy status.</summary>
    public static ClipboardStatusInfo StatusFor(bool artifactExists, string message)
    {
        if (!artifactExists)
            return new ClipboardStatusInfo(ClipboardStatusKind.ArtifactMissing, "ARTIFACT MISSING",
                message ?? "Artifact not found.");
        return new ClipboardStatusInfo(ClipboardStatusKind.ReadyToCopy, "READY TO COPY", message);
    }

    public static ClipboardStatusInfo NotApplicable() =>
        new(ClipboardStatusKind.NotApplicable, "NOT APPLICABLE", "No copy action is available for the current stage.");

    public static ClipboardStatusInfo Error(string message) =>
        new(ClipboardStatusKind.Error, "ERROR", message);
}
