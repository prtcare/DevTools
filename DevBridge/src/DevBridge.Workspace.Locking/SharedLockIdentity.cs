using System.Security.Cryptography;
using System.Text;

namespace DevBridge.Workspace.Locking;

// SP1-M02: deterministic identity for the shared cross-process writer lock over a governed
// Development Control workbook path. This is a faithful RE-IMPLEMENTATION of Nexus.Developer's
// DevelopmentControlMutexIdentity (DevelopmentControlMutexIdentity.cs) so Forge/DevTools
// writers derive the EXACT same OS named-object name Developer writers derive for the same
// governed path, and therefore genuinely contend on the same kernel object.
//
// Derivation contract (verified against Nexus.Developer, read-only):
//   1. normalize  : Trim; if the identity contains '\' or '/' OR Path.HasExtension -> treat as a
//                   filesystem path: Path.GetFullPath(...).Replace('/','\\').TrimEnd('\\');
//                   on Windows, ToLowerInvariant() (matches the filesystem's case-insensitivity).
//                   Non-path identities are used verbatim (trimmed).
//   2. hash       : UTF8 bytes of the normalized identity -> SHA-256 -> Convert.ToHexString
//                   (UPPERCASE hex, 64 chars).
//   3. objectName : "NexusDevelopmentControl_" + that hex.
// No machine-specific absolute path ever appears in the kernel object name; two processes over
// the same governed store contend on the same object regardless of casing/separator spelling.

/// <summary>
/// A deterministic, cross-process shared-lock identity for a governed path / store identity.
/// <see cref="Identity"/> is the normalized store identity (a canonical full path for a
/// workbook). <see cref="ObjectName"/> is the shared OS named-object name. <see cref="HashHex"/>
/// is the 64-char UPPERCASE SHA-256 hex used both inside <see cref="ObjectName"/> and as the
/// deterministic file-lock file name.
/// </summary>
public sealed record SharedLockIdentity
{
    /// <summary>Object-name prefix owned by Nexus.Developer (must match byte-for-byte).</summary>
    public const string ObjectNamePrefix = "NexusDevelopmentControl_";

    private SharedLockIdentity(string identity, string hashHex)
    {
        Identity = identity;
        HashHex = hashHex;
        ObjectName = ObjectNamePrefix + hashHex;
    }

    /// <summary>The normalized store identity (a canonical full path for the workbook store).</summary>
    public string Identity { get; }

    /// <summary>64-char UPPERCASE SHA-256 hex of the UTF8-normalized identity.</summary>
    public string HashHex { get; }

    /// <summary>
    /// The deterministic, cross-process named-object name: <see cref="ObjectNamePrefix"/> + 64
    /// uppercase hex. Stable for the same governed store identity; no absolute path is embedded.
    /// </summary>
    public string ObjectName { get; }

    /// <summary>Derives an identity from a store-identity string (Developer <c>FromStoreIdentity</c>).</summary>
    public static SharedLockIdentity FromStoreIdentity(string identity)
    {
        if (string.IsNullOrWhiteSpace(identity))
            throw new ArgumentException("A store identity is required to derive a lock identity.", nameof(identity));
        var normalized = NormalizeIdentity(identity);
        var hashHex = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)));
        return new SharedLockIdentity(normalized, hashHex);
    }

    /// <summary>
    /// Derives an identity from a governed workbook path (Developer <c>FromWorkbookPath</c>:
    /// pre-normalizes with <see cref="Path.GetFullPath(string)"/> before the shared normalizer).
    /// </summary>
    public static SharedLockIdentity FromWorkbookPath(string workbookPath)
    {
        if (workbookPath is null) throw new ArgumentNullException(nameof(workbookPath));
        return FromStoreIdentity(Path.GetFullPath(workbookPath));
    }

    // Canonicalize a store identity exactly as Nexus.Developer does (DevelopmentControlMutexIdentity.cs,
    // lines 52-59). For a filesystem path resolve to a full path and normalize separators so
    // "C:\A\b.xlsx" and "c:/a/b.xlsx" are the same store; non-path identities are used verbatim
    // (trimmed). Case-insensitive on Windows to match the filesystem.
    private static string NormalizeIdentity(string identity)
    {
        var value = identity.Trim();
        var looksLikePath = value.Contains('\\') || value.Contains('/') || Path.HasExtension(value);
        if (!looksLikePath) return value;
        var full = Path.GetFullPath(value).Replace('/', '\\').TrimEnd('\\');
        return OperatingSystem.IsWindows() ? full.ToLowerInvariant() : full;
    }
}
