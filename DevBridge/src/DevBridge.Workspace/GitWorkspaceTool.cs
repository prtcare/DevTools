using System.Text.Json;

namespace DevBridge.Workspace;

/// <summary>
/// Local Git Workspace Tool (SP1-M01). A small, bootstrap-safe facade that drives the
/// local <c>git.exe</c> to create, inspect and remove <b>worker</b> linked worktrees
/// for the canonical Forge repository.
///
/// Design rules honoured here:
/// <list type="bullet">
/// <item>Local only: this type never touches a remote/cloud service or the network; it
///     talks exclusively to <c>git.exe</c> and the local file system.</item>
/// <item>Windows-first, injection-free: every git invocation is <c>git -C &lt;path&gt; ...</c>
///     with each argument passed verbatim via <see cref="System.Diagnostics.ProcessStartInfo.ArgumentList"/>.</item>
/// <item>Expected failures are returned as <see cref="WorkspaceResult"/>, never thrown.</item>
/// <item>Deterministic paths: a worker branch maps to exactly one directory,
///     <c>&lt;repository&gt;\.forge\worktrees\&lt;BranchSlug&gt;</c>.</item>
/// <item>Branch ownership: one worker → one branch → one worktree. This tool never
///     creates a worktree for an existing branch, never removes the primary worktree,
///     and never deletes branches (the human merge gate stays intact).</item>
/// </list>
/// </summary>
public static class GitWorkspaceTool
{
    private const string TrunkBranch = "main";

    // ------------------------------------------------------------------ create

    /// <summary>
    /// Creates a linked worktree for a brand-new <paramref name="branch"/> at the
    /// deterministic path <c>&lt;repositoryPath&gt;\.forge\worktrees\&lt;slug&gt;</c>.
    /// Refusals are returned, never thrown. On success <paramref name="worktreePath"/>
    /// is set to the absolute path that was created; on refusal it is set to "".
    /// </summary>
    public static WorkspaceResult CreateWorktree(string repositoryPath, string branch, out string worktreePath)
    {
        worktreePath = string.Empty;

        WorkspaceResult? repoGuard = RequireRepository(repositoryPath, out string repo);
        if (repoGuard is not null)
        {
            return repoGuard;
        }

        if (string.IsNullOrWhiteSpace(branch))
        {
            return WorkspaceResult.Fail("branch name is required to create a worktree.");
        }

        string branchName = branch.Trim();

        if (string.Equals(branchName, TrunkBranch, StringComparison.OrdinalIgnoreCase))
        {
            return WorkspaceResult.Fail($"branch '{branchName}' is the trunk branch; refusing to create a worker worktree for it.");
        }

        string? headBranch = GetHeadBranch(repo);
        if (headBranch is not null && string.Equals(branchName, headBranch, StringComparison.OrdinalIgnoreCase))
        {
            return WorkspaceResult.Fail($"branch '{branchName}' is already checked out as the repository's current branch; refusing.");
        }

        WorktreeRecord? existing = FindWorktreeForBranch(repo, branchName);
        if (existing is not null)
        {
            return WorkspaceResult.Fail(
                $"a worktree for branch '{branchName}' already exists at '{existing.Path}'.",
                $"git worktree list reports branch '{branchName}' -> {existing.Path}");
        }

        if (BranchExistsAnywhere(repo, branchName))
        {
            return WorkspaceResult.Fail(
                $"branch '{branchName}' already exists in this repository; a worker worktree needs a brand-new branch.",
                "Existing branches are never checked out by CreateWorktree.");
        }

        string? slug = BranchSlug.ToSlug(branchName);
        if (slug is null)
        {
            return WorkspaceResult.Fail(
                $"branch name '{branchName}' cannot be mapped to a safe, unambiguous directory segment.");
        }

        string target = Path.Combine(repo, ".forge", "worktrees", slug);

        if (Directory.Exists(target) && Directory.EnumerateFileSystemEntries(target).Any())
        {
            return WorkspaceResult.Fail(
                $"target worktree path already exists and is not empty: {target}",
                "Refusing to overwrite existing content; remove or rename it first.");
        }

        if (File.Exists(target))
        {
            return WorkspaceResult.Fail(
                $"target worktree path already exists as a file: {target}");
        }

        GitOutcome add = GitRunner.Run(repo, new[] { "worktree", "add", "-b", branchName, target });
        if (!add.Started || add.ExitCode != 0)
        {
            return WorkspaceResult.Fail(
                $"git worktree add failed for branch '{branchName}'.", GitErrorDetail(add));
        }

        GitOutcome verify = GitRunner.Run(target, new[] { "rev-parse", "--show-toplevel" });
        if (!verify.Started || verify.ExitCode != 0 || !PathsEqual(verify.StdOut.Trim(), target))
        {
            return WorkspaceResult.Fail(
                $"worktree was created but the post-create verification failed for branch '{branchName}' at '{target}'.",
                GitErrorDetail(verify));
        }

        worktreePath = target;
        return WorkspaceResult.Ok(
            $"created worktree for branch '{branchName}' at '{target}'.",
            $"verified via rev-parse --show-toplevel == '{target}'.");
    }

    // --------------------------------------------------------------- validate

    /// <summary>
    /// Confirms the branch's worktree exists, is a git repository and is currently on
    /// the expected branch. Read-only.
    /// </summary>
    public static WorkspaceResult ValidateWorktree(string repositoryPath, string branch)
    {
        WorkspaceResult? repoGuard = RequireRepository(repositoryPath, out string repo);
        if (repoGuard is not null)
        {
            return repoGuard;
        }

        if (string.IsNullOrWhiteSpace(branch))
        {
            return WorkspaceResult.Fail("branch name is required to validate a worktree.");
        }

        string branchName = branch.Trim();
        WorktreeRecord? record = FindWorktreeForBranch(repo, branchName);
        if (record is null)
        {
            return WorkspaceResult.Fail($"no worktree is registered for branch '{branchName}'.");
        }

        if (!IsGitRepository(record.Path))
        {
            return WorkspaceResult.Fail($"worktree path '{record.Path}' is no longer a git repository.");
        }

        string? current = GetHeadBranch(record.Path);
        if (current is null)
        {
            return WorkspaceResult.Fail($"worktree at '{record.Path}' is in detached HEAD state; expected branch '{branchName}'.");
        }

        if (!string.Equals(current, branchName, StringComparison.OrdinalIgnoreCase))
        {
            return WorkspaceResult.Fail(
                $"worktree at '{record.Path}' is on branch '{current}', not '{branchName}'.");
        }

        string headSha = GetHeadSha(record.Path);
        return WorkspaceResult.Ok(
            $"worktree for branch '{branchName}' is valid.",
            $"path={record.Path}\nbranch={current}\nHEAD={headSha}");
    }

    // ------------------------------------------------------------------ list

    /// <summary>
    /// Parses <c>git worktree list --porcelain</c> into records. On success
    /// <see cref="WorkspaceResult.Detail"/> holds a JSON array of
    /// <see cref="WorktreeRecord"/>. Read-only.
    /// </summary>
    public static WorkspaceResult ListWorktrees(string repositoryPath)
    {
        WorkspaceResult? repoGuard = RequireRepository(repositoryPath, out string repo);
        if (repoGuard is not null)
        {
            return repoGuard;
        }

        GitOutcome list = GitRunner.Run(repo, new[] { "worktree", "list", "--porcelain" });
        if (!list.Started || list.ExitCode != 0)
        {
            return WorkspaceResult.Fail("git worktree list failed.", GitErrorDetail(list));
        }

        List<WorktreeRecord> records = WorktreeListParser.Parse(list.StdOut);
        return WorkspaceResult.Ok(
            $"{records.Count} worktree(s).",
            JsonSerializer.Serialize(records));
    }

    // ----------------------------------------------------------------- status

    /// <summary>
    /// Read-only status for the branch's worktree: current branch, HEAD sha,
    /// clean/dirty and untracked count. On success <see cref="WorkspaceResult.Detail"/>
    /// holds a JSON object of <see cref="WorktreeStatusInfo"/>.
    /// </summary>
    public static WorkspaceResult GetWorktreeStatus(string repositoryPath, string branch)
    {
        WorkspaceResult? repoGuard = RequireRepository(repositoryPath, out string repo);
        if (repoGuard is not null)
        {
            return repoGuard;
        }

        if (string.IsNullOrWhiteSpace(branch))
        {
            return WorkspaceResult.Fail("branch name is required to read a worktree status.");
        }

        string branchName = branch.Trim();
        WorktreeRecord? record = FindWorktreeForBranch(repo, branchName);
        if (record is null)
        {
            return WorkspaceResult.Fail($"no worktree is registered for branch '{branchName}'.");
        }

        string? current = GetHeadBranch(record.Path);
        if (current is null)
        {
            return WorkspaceResult.Fail($"worktree at '{record.Path}' is in detached HEAD state; expected branch '{branchName}'.");
        }

        if (!string.Equals(current, branchName, StringComparison.OrdinalIgnoreCase))
        {
            return WorkspaceResult.Fail(
                $"worktree at '{record.Path}' is on branch '{current}', not '{branchName}'.");
        }

        string headSha = GetHeadSha(record.Path);
        GitOutcome status = GitRunner.Run(record.Path, new[] { "status", "--porcelain" });
        string[] lines = status.Started && status.ExitCode == 0
            ? NonEmptyLines(status.StdOut)
            : Array.Empty<string>();

        int untracked = lines.Count(line => line.StartsWith("??", StringComparison.Ordinal));
        bool clean = lines.Length == 0;
        var info = new WorktreeStatusInfo(current, headSha, clean, untracked, lines);
        return WorkspaceResult.Ok(
            $"status for branch '{branchName}': {(clean ? "clean" : "dirty")}.",
            JsonSerializer.Serialize(info));
    }

    // ----------------------------------------------------------------- remove

    /// <summary>
    /// Removes the branch's worktree. Refusal cases include: not a git repo; branch is
    /// the trunk/current branch; no registered worktree for the branch; and a dirty
    /// worktree when <paramref name="force"/> is false (the dirty files are reported).
    /// This method never deletes the branch and never runs destructive index/content
    /// commands (<c>git branch -D</c>, <c>git clean</c>, <c>git reset --hard</c>).
    /// </summary>
    public static WorkspaceResult RemoveWorktree(string repositoryPath, string branch, bool force = false)
    {
        WorkspaceResult? repoGuard = RequireRepository(repositoryPath, out string repo);
        if (repoGuard is not null)
        {
            return repoGuard;
        }

        if (string.IsNullOrWhiteSpace(branch))
        {
            return WorkspaceResult.Fail("branch name is required to remove a worktree.");
        }

        string branchName = branch.Trim();

        if (string.Equals(branchName, TrunkBranch, StringComparison.OrdinalIgnoreCase))
        {
            return WorkspaceResult.Fail(
                $"branch '{branchName}' is the trunk branch; refusing to remove its worktree.",
                "The primary/trunk worktree is owned by the repository itself, not by a worker.");
        }

        string? headBranch = GetHeadBranch(repo);
        if (headBranch is not null && string.Equals(branchName, headBranch, StringComparison.OrdinalIgnoreCase))
        {
            return WorkspaceResult.Fail(
                $"branch '{branchName}' is checked out at the repository's primary worktree; refusing to remove it.",
                "The repository's current branch cannot be removed through this tool.");
        }

        WorktreeRecord? record = FindWorktreeForBranch(repo, branchName);
        if (record is null)
        {
            return WorkspaceResult.Fail(
                $"no worktree is registered for branch '{branchName}'; nothing to remove.");
        }

        if (!force)
        {
            GitOutcome status = GitRunner.Run(record.Path, new[] { "status", "--porcelain" });
            string[] lines = status.Started && status.ExitCode == 0
                ? NonEmptyLines(status.StdOut)
                : Array.Empty<string>();

            if (lines.Length > 0)
            {
                return WorkspaceResult.Fail(
                    $"worktree for branch '{branchName}' is dirty; remove refused without force=true.",
                    string.Join(Environment.NewLine, lines));
            }
        }

        string[] removeArgs = force
            ? new[] { "worktree", "remove", "--force", record.Path }
            : new[] { "worktree", "remove", record.Path };

        GitOutcome remove = GitRunner.Run(repo, removeArgs);
        if (!remove.Started || remove.ExitCode != 0)
        {
            return WorkspaceResult.Fail(
                $"git worktree remove failed for branch '{branchName}'.", GitErrorDetail(remove));
        }

        return WorkspaceResult.Ok(
            force
                ? $"removed worktree for branch '{branchName}' at '{record.Path}' (force)."
                : $"removed worktree for branch '{branchName}' at '{record.Path}'.",
            "The branch itself was left intact; branch deletion is out of scope for this tool.");
    }

    // ------------------------------------------------------------------ prune

    /// <summary>
    /// Runs <c>git worktree prune</c> to drop stale administrative records. Read-only
    /// with respect to working-tree content.
    /// </summary>
    public static WorkspaceResult PruneWorktrees(string repositoryPath)
    {
        WorkspaceResult? repoGuard = RequireRepository(repositoryPath, out string repo);
        if (repoGuard is not null)
        {
            return repoGuard;
        }

        GitOutcome prune = GitRunner.Run(repo, new[] { "worktree", "prune" });
        if (!prune.Started || prune.ExitCode != 0)
        {
            return WorkspaceResult.Fail("git worktree prune failed.", GitErrorDetail(prune));
        }

        return WorkspaceResult.Ok("git worktree prune completed.");
    }

    // ------------------------------------------------------------- internals

    private static WorkspaceResult? RequireRepository(string repositoryPath, out string repo)
    {
        repo = string.Empty;
        if (string.IsNullOrWhiteSpace(repositoryPath))
        {
            return WorkspaceResult.Fail("repository path is required.");
        }

        string full = Path.GetFullPath(repositoryPath);
        if (!IsGitRepository(full))
        {
            return WorkspaceResult.Fail($"'{repositoryPath}' is not a git repository.",
                "git rev-parse --git-dir did not succeed at that path.");
        }

        repo = full;
        return null;
    }

    private static bool IsGitRepository(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        GitOutcome probe = GitRunner.Run(path, new[] { "rev-parse", "--git-dir" });
        return probe.Started && probe.ExitCode == 0 && !string.IsNullOrWhiteSpace(probe.StdOut);
    }

    private static string? GetHeadBranch(string repoOrWorktreePath)
    {
        GitOutcome head = GitRunner.Run(repoOrWorktreePath, new[] { "symbolic-ref", "--short", "HEAD" });
        if (!head.Started || head.ExitCode != 0)
        {
            return null;
        }

        string name = head.StdOut.Trim();
        return name.Length == 0 ? null : name;
    }

    private static string GetHeadSha(string repoOrWorktreePath)
    {
        GitOutcome sha = GitRunner.Run(repoOrWorktreePath, new[] { "rev-parse", "HEAD" });
        return sha.Started && sha.ExitCode == 0 ? sha.StdOut.Trim() : string.Empty;
    }

    private static bool BranchExistsAnywhere(string repositoryPath, string branch)
    {
        GitOutcome local = GitRunner.Run(repositoryPath, new[] { "for-each-ref", "refs/heads", "--format=%(refname:lstrip=2)" });
        if (local.Started && local.ExitCode == 0 &&
            NonEmptyLines(local.StdOut).Any(name => string.Equals(name, branch, StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }

        GitOutcome remote = GitRunner.Run(repositoryPath, new[] { "for-each-ref", "refs/remotes", "--format=%(refname:lstrip=3)" });
        return remote.Started && remote.ExitCode == 0 &&
               NonEmptyLines(remote.StdOut).Any(name => string.Equals(name, branch, StringComparison.OrdinalIgnoreCase));
    }

    private static WorktreeRecord? FindWorktreeForBranch(string repositoryPath, string branch)
    {
        GitOutcome list = GitRunner.Run(repositoryPath, new[] { "worktree", "list", "--porcelain" });
        if (!list.Started || list.ExitCode != 0)
        {
            return null;
        }

        return WorktreeListParser.Parse(list.StdOut)
            .FirstOrDefault(w => !w.Detached && w.Branch is not null &&
                                 string.Equals(w.Branch, branch, StringComparison.OrdinalIgnoreCase));
    }

    private static string[] NonEmptyLines(string text)
        => text.Split('\n')
            .Select(line => line.TrimEnd('\r'))
            .Where(line => line.Length > 0)
            .ToArray();

    private static string GitErrorDetail(GitOutcome outcome)
    {
        string[] parts = new[] { outcome.StdErr, outcome.StdOut }
            .Select(s => s.Trim())
            .Where(s => s.Length > 0)
            .ToArray();

        return string.Join(" | ", parts);
    }

    private static bool PathsEqual(string a, string b)
    {
        try
        {
            return string.Equals(
                Path.GetFullPath(a).TrimEnd(Path.DirectorySeparatorChar),
                Path.GetFullPath(b).TrimEnd(Path.DirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        }
    }
}
