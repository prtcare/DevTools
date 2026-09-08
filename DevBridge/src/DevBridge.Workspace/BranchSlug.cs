using System.Text;

namespace DevBridge.Workspace;

/// <summary>
/// Deterministic, injective-on-the-practical-subset mapping from a git branch
/// name to a single, Windows-safe directory segment used under
/// <c>&lt;repository&gt;\.forge\worktrees\&lt;slug&gt;</c>.
///
/// Encoding rules (all deterministic, all case-folded to lower so the segment is
/// stable on a case-insensitive Windows file system):
/// <list type="bullet">
/// <item>Allowed literal output characters: ASCII letters/digits, '_' and internal '.'.
///     Letters are lower-cased.</item>
/// <item>A literal '-' in the branch is escaped to '--' so it can never be confused
///     with the separator marker below.</item>
/// <item>Every run of one-or-more separator characters — '/', '\', whitespace and any
///     Windows-reserved or otherwise unsafe character — is replaced by a single '-'.</item>
/// </list>
///
/// Refused inputs return <see langword="null"/>: empty/whitespace, any ASCII control
/// character, any branch containing "..", a branch starting or ending with '.', and
/// any branch whose slug is a Windows reserved device name (CON, PRN, AUX, NUL,
/// COM1-9, LPT1-9). The tool therefore never constructs an ambiguous or unsafe path.
/// </summary>
public static class BranchSlug
{
    // Windows device names are reserved even with an extension; we compare the whole
    // lower-cased slug against this set (slugs never contain '.' at the end and we
    // refuse leading '.', so base-name-only coverage is sufficient for our segments).
    private static readonly HashSet<string> ReservedDeviceNames = new(StringComparer.Ordinal)
    {
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    };

    /// <summary>
    /// Returns the safe slug for <paramref name="branch"/>, or <see langword="null"/>
    /// when the branch name cannot be mapped to a safe, unambiguous directory segment.
    /// </summary>
    public static string? ToSlug(string? branch)
    {
        if (string.IsNullOrWhiteSpace(branch))
        {
            return null;
        }

        string b = branch.Trim();

        // ASCII control characters are invalid in git refs and in file names.
        foreach (char c in b)
        {
            if (c < 32)
            {
                return null;
            }
        }

        // Never allow a parent-directory escape or a dot-path anywhere in the segment.
        if (b.Contains("..", StringComparison.Ordinal))
        {
            return null;
        }

        // No leading or trailing dot: a segment "." / ".." or a trailing dot is not
        // a legal Windows name, and a leading dot would be a hidden segment.
        if (b.StartsWith('.') || b.EndsWith('.'))
        {
            return null;
        }

        var sb = new StringBuilder(b.Length);
        bool afterSeparator = true; // suppresses a marker before the first kept character

        foreach (char c in b)
        {
            if (IsKeptLiteral(c))
            {
                if (afterSeparator)
                {
                    if (sb.Length > 0)
                    {
                        sb.Append('-');
                    }

                    afterSeparator = false;
                }

                if (c == '-')
                {
                    sb.Append("--"); // escape literal hyphen so it differs from the marker
                }
                else
                {
                    sb.Append(char.ToLowerInvariant(c));
                }
            }
            else
            {
                // separator character (slash, whitespace, Windows-reserved char, ...)
                afterSeparator = true;
            }
        }

        string slug = sb.ToString();
        if (slug.Length == 0)
        {
            return null;
        }

        // slug is already lower-cased; refuse Windows reserved device names.
        if (ReservedDeviceNames.Contains(slug))
        {
            return null;
        }

        return slug;
    }

    private static bool IsKeptLiteral(char c)
        => char.IsAsciiLetterOrDigit(c) || c == '_' || c == '.' || c == '-';
}
