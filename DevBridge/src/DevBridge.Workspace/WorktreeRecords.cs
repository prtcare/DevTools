namespace DevBridge.Workspace;

/// <summary>One entry parsed from <c>git worktree list --porcelain</c>.</summary>
/// <param name="Path">Absolute working-tree path (as reported by git).</param>
/// <param name="Branch">Short branch name (e.g. <c>feature/x</c>), or <see langword="null"/> when detached.</param>
/// <param name="Detached">True when the worktree HEAD is detached.</param>
/// <param name="HeadSha">Full HEAD commit sha when reported.</param>
public sealed record WorktreeRecord(string Path, string? Branch, bool Detached, string? HeadSha)
{
    public string Describe()
        => Detached
            ? $"{Path} (detached @ {(HeadSha is { Length: >= 8 } ? HeadSha[..8] : HeadSha ?? "?")})"
            : $"{Path} [{Branch}] @ {(HeadSha is { Length: >= 8 } ? HeadSha[..8] : HeadSha ?? "?")}";
}

/// <summary>Read-only status of one worktree.</summary>
/// <param name="Branch">Short branch currently checked out in the worktree.</param>
/// <param name="HeadSha">Full HEAD commit sha.</param>
/// <param name="IsClean">True when <c>git status --porcelain</c> is empty.</param>
/// <param name="UntrackedCount">Number of untracked (<c>??</c>) entries.</param>
/// <param name="DirtyEntries">Raw porcelain status lines (each names the affected file).</param>
public sealed record WorktreeStatusInfo(
    string Branch,
    string HeadSha,
    bool IsClean,
    int UntrackedCount,
    string[] DirtyEntries);

/// <summary>Parses the porcelain worktree listing. Internal: callers reach it through the facade.</summary>
internal static class WorktreeListParser
{
    public static List<WorktreeRecord> Parse(string porcelain)
    {
        var records = new List<WorktreeRecord>();
        string? path = null;
        string? head = null;
        string? branch = null;
        bool detached = false;

        void Flush()
        {
            if (path is null)
            {
                return;
            }

            records.Add(new WorktreeRecord(path, branch, detached, head));
            path = null;
            head = null;
            branch = null;
            detached = false;
        }

        foreach (string rawLine in porcelain.Split('\n'))
        {
            string line = rawLine.TrimEnd('\r');
            if (line.Length == 0)
            {
                Flush();
                continue;
            }

            if (line.StartsWith("worktree ", StringComparison.Ordinal))
            {
                path = line["worktree ".Length..];
            }
            else if (line.StartsWith("HEAD ", StringComparison.Ordinal))
            {
                head = line["HEAD ".Length..];
            }
            else if (line.StartsWith("branch ", StringComparison.Ordinal))
            {
                string full = line["branch ".Length..];
                branch = full.StartsWith("refs/heads/", StringComparison.Ordinal)
                    ? full["refs/heads/".Length..]
                    : full;
            }
            else if (line == "detached")
            {
                detached = true;
            }
            // "bare", "prunable", "locked" lines are ignored — they carry no path/branch info.
        }

        Flush();
        return records;
    }
}
