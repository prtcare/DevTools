// Program.cs — SP1-M01 Git Workspace Tool fixture runner (console exit-code harness,
// mirroring the repo's existing DevBridge.Tests style — NO xunit/NUnit).
//
// Every scenario creates an isolated throwaway git repository under Path.GetTempPath()
// (git init, local user.name/user.email, one seed commit on the default branch) and then
// exercises GitWorkspaceTool against that scratch repo only. The harness never touches
// the DevTools/Forge repository the tool is delivered into.
using System.Diagnostics;
using System.Text.Json;
using DevBridge.Workspace;

int pass = 0, fail = 0;
var failures = new List<string>();

void Check(bool cond, string name, string detail)
{
    if (cond) { pass++; }
    else { fail++; failures.Add($"  FAIL {name}: {detail}"); }
}

// ---- minimal local git runner for fixture setup / assertions -----------------
static (int Code, string Out, string Err) Git(string cwd, params string[] args)
{
    var psi = new ProcessStartInfo("git")
    {
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true,
    };
    psi.ArgumentList.Add("-C");
    psi.ArgumentList.Add(cwd);
    foreach (string a in args) psi.ArgumentList.Add(a);

    using var p = Process.Start(psi)!;
    string stdout = p.StandardOutput.ReadToEnd();
    string stderr = p.StandardError.ReadToEnd();
    p.WaitForExit();
    return (p.ExitCode, stdout, stderr);
}

static string GitOk(string cwd, params string[] args)
{
    var (code, stdout, stderr) = Git(cwd, args);
    if (code != 0)
    {
        throw new InvalidOperationException($"git {string.Join(' ', args)} -> exit {code}: {stderr.Trim()} {stdout.Trim()}");
    }

    return stdout;
}

static string NewRepo(string label, string defaultBranch = "main")
{
    string dir = Path.Combine(Path.GetTempPath(), "gwt-" + label + "-" + Guid.NewGuid().ToString("N")[..8]);
    Directory.CreateDirectory(dir);
    GitOk(dir, "init", "-b", defaultBranch);
    GitOk(dir, "config", "user.name", "Workspace Test Harness");
    GitOk(dir, "config", "user.email", "wt-harness@example.com");
    File.WriteAllText(Path.Combine(dir, "seed.txt"), "seed\n");
    GitOk(dir, "add", "seed.txt");
    GitOk(dir, "commit", "-m", "initial");
    return dir;
}

static string CurrentBranch(string worktreePath)
    => GitOk(worktreePath, "symbolic-ref", "--short", "HEAD").Trim();

static bool PathsEqual(string a, string b)
    => string.Equals(
        Path.GetFullPath(a).TrimEnd(Path.DirectorySeparatorChar),
        Path.GetFullPath(b).TrimEnd(Path.DirectorySeparatorChar),
        StringComparison.OrdinalIgnoreCase);

static List<WorktreeRecord> ParseList(WorkspaceResult r)
    => JsonSerializer.Deserialize<List<WorktreeRecord>>(r.Detail!)!;

static WorktreeStatusInfo ParseStatus(WorkspaceResult r)
    => JsonSerializer.Deserialize<WorktreeStatusInfo>(r.Detail!)!;

// 1. create ----------------------------------------------------------------
{
    string repo = NewRepo("create");
    string wt = "";
    var r = GitWorkspaceTool.CreateWorktree(repo, "feature/alpha", out wt);

    Check(r.Success, "CREATE: succeeds on a fresh branch", r.Message);
    Check(wt.Length > 0 && Directory.Exists(wt), "CREATE: worktree path exists on disk", wt);
    Check(CurrentBranch(wt) == "feature/alpha", "CREATE: worktree is on the right branch", CurrentBranch(wt));
    string top = GitOk(wt, "rev-parse", "--show-toplevel").Trim();
    Check(PathsEqual(top, wt), "CREATE: rev-parse --show-toplevel equals path", $"{top} vs {wt}");
    var v = GitWorkspaceTool.ValidateWorktree(repo, "feature/alpha");
    Check(v.Success, "CREATE: ValidateWorktree reports valid", v.Message);
}

// 2. duplicate create refused, no partial state -----------------------------
{
    string repo = NewRepo("dup");
    string wt1 = "", wt2 = "";
    var r1 = GitWorkspaceTool.CreateWorktree(repo, "feature/dup", out wt1);
    Check(r1.Success, "DUP: first create succeeds", r1.Message);

    var r2 = GitWorkspaceTool.CreateWorktree(repo, "feature/dup", out wt2);
    Check(!r2.Success, "DUP: second create for same branch refuses", r2.Message);
    Check(r2.Message.Contains("already exists", StringComparison.OrdinalIgnoreCase), "DUP: refusal cites existing worktree", r2.Message);
    Check(wt2 == "", "DUP: no worktreePath returned on refusal", wt2);

    var list = ParseList(GitWorkspaceTool.ListWorktrees(repo));
    Check(list.Count == 2, "DUP: no partial state (still main + one)", $"count={list.Count}");
    Check(list.Count(x => string.Equals(x.Branch, "feature/dup", StringComparison.OrdinalIgnoreCase)) == 1,
        "DUP: exactly one worktree for the branch", "count==1");
}

// 3. invalid repo refused ---------------------------------------------------
{
    string dir = Path.Combine(Path.GetTempPath(), "gwt-norepo-" + Guid.NewGuid().ToString("N")[..8]);
    Directory.CreateDirectory(dir);
    string wt = "";
    var r = GitWorkspaceTool.CreateWorktree(dir, "feature/x", out wt);
    Check(!r.Success, "INVALIDREPO: non-repo directory refused", r.Message);
    Check(r.Message.Contains("not a git repository", StringComparison.OrdinalIgnoreCase), "INVALIDREPO: message is clear", r.Message);
    Check(wt == "", "INVALIDREPO: empty worktreePath", wt);
}

// 4. invalid / refused branch names -----------------------------------------
{
    string repo = NewRepo("refused");
    GitOk(repo, "branch", "already"); // pre-existing local branch, no worktree

    var rMain = GitWorkspaceTool.CreateWorktree(repo, "main", out _);
    Check(!rMain.Success, "REFUSED: 'main' refused", rMain.Message);
    var rEmpty = GitWorkspaceTool.CreateWorktree(repo, "", out _);
    Check(!rEmpty.Success, "REFUSED: empty branch refused", rEmpty.Message);
    var rBlank = GitWorkspaceTool.CreateWorktree(repo, "   ", out _);
    Check(!rBlank.Success, "REFUSED: whitespace branch refused", rBlank.Message);
    var rExisting = GitWorkspaceTool.CreateWorktree(repo, "already", out _);
    Check(!rExisting.Success, "REFUSED: branch already existing on repo refused", rExisting.Message);
    Check(rExisting.Message.Contains("already exists", StringComparison.OrdinalIgnoreCase), "REFUSED: existing-branch message", rExisting.Message);

    var list = ParseList(GitWorkspaceTool.ListWorktrees(repo));
    Check(list.Count == 1, "REFUSED: no worktree added by any refusal", $"count={list.Count}");
}
{
    // default branch is not "main": the repository's current branch must still be refused.
    string repo = NewRepo("trunkhead", defaultBranch: "trunk");
    var r = GitWorkspaceTool.CreateWorktree(repo, "trunk", out _);
    Check(!r.Success, "REFUSED-HEAD: repository current branch refused even when not main", r.Message);
    Check(r.Message.Contains("current branch", StringComparison.OrdinalIgnoreCase), "REFUSED-HEAD: message cites current branch", r.Message);
}

// 5. existing non-empty worktree dir refused ---------------------------------
{
    string repo = NewRepo("blocked");
    string? slug = BranchSlug.ToSlug("feature/block");
    string target = Path.Combine(repo, ".forge", "worktrees", slug!);
    Directory.CreateDirectory(target);
    File.WriteAllText(Path.Combine(target, "existing.txt"), "occupied");

    string wt = "";
    var r = GitWorkspaceTool.CreateWorktree(repo, "feature/block", out wt);
    Check(!r.Success, "EXISTDIR: non-empty target path refused", r.Message);
    Check(r.Message.Contains("already exists", StringComparison.OrdinalIgnoreCase), "EXISTDIR: message cites existing path", r.Message);
    Check(File.Exists(Path.Combine(target, "existing.txt")), "EXISTDIR: pre-existing content untouched", "sentinel survived");
    Check(wt == "", "EXISTDIR: empty worktreePath", wt);
}

// 6. list -------------------------------------------------------------------
{
    string repo = NewRepo("list");
    var rc = GitWorkspaceTool.CreateWorktree(repo, "feature/list", out string wt);
    Check(rc.Success, "LIST: create ok", rc.Message);

    var records = ParseList(GitWorkspaceTool.ListWorktrees(repo));
    Check(records.Count == 2, "LIST: shows main + created branch worktree", $"count={records.Count}");
    Check(records.Any(x => string.Equals(x.Branch, "main", StringComparison.OrdinalIgnoreCase)), "LIST: main present", "main not found");
    var rec = records.FirstOrDefault(x => string.Equals(x.Branch, "feature/list", StringComparison.OrdinalIgnoreCase));
    Check(rec is not null, "LIST: feature/list present", rec?.Path ?? "null");
    Check(rec is not null && PathsEqual(rec.Path, wt), "LIST: record path equals created path", rec?.Path ?? "null");
}

// 7. status (clean -> dirty) -------------------------------------------------
{
    string repo = NewRepo("status");
    var rc = GitWorkspaceTool.CreateWorktree(repo, "feature/stat", out string wt);
    Check(rc.Success, "STATUS: create ok", rc.Message);

    var s1 = ParseStatus(GitWorkspaceTool.GetWorktreeStatus(repo, "feature/stat"));
    Check(s1.IsClean, "STATUS: fresh worktree is clean", $"clean={s1.IsClean} untracked={s1.UntrackedCount}");
    Check(string.Equals(s1.Branch, "feature/stat", StringComparison.OrdinalIgnoreCase), "STATUS: branch reported", s1.Branch);

    File.WriteAllText(Path.Combine(wt, "newfile.txt"), "uncommitted");
    var s2 = ParseStatus(GitWorkspaceTool.GetWorktreeStatus(repo, "feature/stat"));
    Check(!s2.IsClean, "STATUS: dirty after an uncommitted file", $"clean={s2.IsClean}");
    Check(s2.UntrackedCount >= 1, "STATUS: untracked file counted", $"untracked={s2.UntrackedCount}");
    Check(s2.DirtyEntries.Any(e => e.Contains("newfile.txt", StringComparison.Ordinal)), "STATUS: dirty entry names the file", string.Join("; ", s2.DirtyEntries));
}

// 8. safe remove (clean worktree) -------------------------------------------
{
    string repo = NewRepo("safedel");
    var rc = GitWorkspaceTool.CreateWorktree(repo, "feature/rm", out string wt);
    Check(rc.Success, "SAFERM: create ok", rc.Message);
    Check(ParseList(GitWorkspaceTool.ListWorktrees(repo)).Count == 2, "SAFERM: two worktrees before remove", "");

    var rr = GitWorkspaceTool.RemoveWorktree(repo, "feature/rm");
    Check(rr.Success, "SAFERM: clean worktree removal succeeds", rr.Message);
    Check(!Directory.Exists(wt), "SAFERM: worktree directory gone", wt);

    var after = ParseList(GitWorkspaceTool.ListWorktrees(repo));
    Check(after.Count == 1, "SAFERM: list confirms main only", $"count={after.Count}");
    Check(!after.Any(x => string.Equals(x.Branch, "feature/rm", StringComparison.OrdinalIgnoreCase)), "SAFERM: branch worktree gone from list", "");

    var (code, _, _) = Git(repo, "show-ref", "--verify", "refs/heads/feature/rm");
    Check(code == 0, "SAFERM: branch itself survives (tool never deletes branches)", $"show-ref exit={code}");
}

// 9. refuse unsafe remove then force ----------------------------------------
{
    string repo = NewRepo("dirtydel");
    var rc = GitWorkspaceTool.CreateWorktree(repo, "feature/dirty", out string wt);
    Check(rc.Success, "DIRTY: create ok", rc.Message);
    File.WriteAllText(Path.Combine(wt, "dirty.txt"), "unsaved");

    var rf = GitWorkspaceTool.RemoveWorktree(repo, "feature/dirty");
    Check(!rf.Success, "DIRTY: non-force removal refused on dirty worktree", rf.Message);
    Check(rf.Message.Contains("dirty", StringComparison.OrdinalIgnoreCase), "DIRTY: refusal cites dirty state", rf.Message);
    string detail = rf.Detail ?? "";
    Check(detail.Contains("dirty.txt", StringComparison.Ordinal), "DIRTY: refusal lists the file", detail);
    Check(Directory.Exists(wt), "DIRTY: directory retained after refusal", wt);

    var rForce = GitWorkspaceTool.RemoveWorktree(repo, "feature/dirty", force: true);
    Check(rForce.Success, "DIRTY: force=true removes the dirty worktree", rForce.Message);
    Check(!Directory.Exists(wt), "DIRTY: directory gone after force", wt);
}

// 10. refuse main / repository primary worktree removal ----------------------
{
    string repo = NewRepo("mainref");
    var rm = GitWorkspaceTool.RemoveWorktree(repo, "main");
    Check(!rm.Success, "MAINRM: removal of 'main' worktree refused", rm.Message);
    Check(rm.Message.Contains("main", StringComparison.OrdinalIgnoreCase), "MAINRM: message cites trunk/main", rm.Message);
}
{
    string repo = NewRepo("trunkrm", defaultBranch: "trunk");
    var rt = GitWorkspaceTool.RemoveWorktree(repo, "trunk");
    Check(!rt.Success, "MAINRM: removal of current default-branch worktree refused", rt.Message);
}

// 11. prune + BranchSlug path handling ---------------------------------------
{
    string repo = NewRepo("prune");
    var rc = GitWorkspaceTool.CreateWorktree(repo, "feature/prune", out string wt);
    Check(rc.Success, "PRUNE: create ok", rc.Message);
    var pr = GitWorkspaceTool.PruneWorktrees(repo);
    Check(pr.Success, "PRUNE: git worktree prune runs", pr.Message);
}
{
    Check(BranchSlug.ToSlug("feature with spaces") == "feature-with-spaces", "SLUG: space -> dash", BranchSlug.ToSlug("feature with spaces") ?? "null");
    Check(BranchSlug.ToSlug("feature/x/y") == "feature-x-y", "SLUG: slash flatten deterministic", BranchSlug.ToSlug("feature/x/y") ?? "null");
    Check(BranchSlug.ToSlug("feature/x") == "feature-x", "SLUG: single slash flattens to dash", BranchSlug.ToSlug("feature/x") ?? "null");
    Check(BranchSlug.ToSlug("..") is null, "SLUG: '..' refused", BranchSlug.ToSlug("..") ?? "null");
    Check(BranchSlug.ToSlug(".hidden") is null, "SLUG: leading dot refused", BranchSlug.ToSlug(".hidden") ?? "null");
    Check(BranchSlug.ToSlug("feature/../x") is null, "SLUG: embedded '..' refused", BranchSlug.ToSlug("feature/../x") ?? "null");
    Check(BranchSlug.ToSlug("CON") is null, "SLUG: Windows reserved device name refused", BranchSlug.ToSlug("CON") ?? "null");
    Check(BranchSlug.ToSlug("feat:ure<x>") == "feat-ure-x", "SLUG: Windows-reserved chars removed", BranchSlug.ToSlug("feat:ure<x>") ?? "null");
    Check(BranchSlug.ToSlug("valid/name") is string v0 && !v0.Contains('/') && !v0.Contains('\\'),
        "SLUG: no path separators in slug", BranchSlug.ToSlug("valid/name") ?? "null");

    string? sl = BranchSlug.ToSlug("feature/x");
    string? s2 = BranchSlug.ToSlug("feature-x");
    Check(sl is not null && s2 is not null && sl != s2, "SLUG: slash and literal-hyphen map to distinct slugs", $"{sl} vs {s2}");
    Check(sl == "feature-x" && s2 == "feature--x", "SLUG: hyphen literal is escaped, slash is the marker", $"{sl} vs {s2}");

    Check(BranchSlug.ToSlug("Feature/One") == "feature-one", "SLUG: lower-cased deterministic slug", BranchSlug.ToSlug("Feature/One") ?? "null");
    Check(BranchSlug.ToSlug("feature one") == "feature-one", "SLUG: internal space -> dash", BranchSlug.ToSlug("feature one") ?? "null");
    string? a1 = BranchSlug.ToSlug("topic/alpha");
    string? b1 = BranchSlug.ToSlug("topic/beta");
    Check(a1 is not null && b1 is not null && a1 != b1,
        "SLUG: two distinct branch names stay unique", $"{a1} vs {b1}");
    string? dup1 = BranchSlug.ToSlug("release/candidate");
    string? dup2 = BranchSlug.ToSlug("release/candidate");
    Check(dup1 is not null && dup1 == dup2, "SLUG: deterministic (same input -> same slug)", $"{dup1} vs {dup2}");
}

// ------------------------------------------------------------------ report
Console.WriteLine();
Console.WriteLine("================================================================");
Console.WriteLine(" SP1-M01 Git Workspace Tool — fixture runner");
Console.WriteLine("================================================================");
foreach (string f in failures) Console.WriteLine(f);
Console.WriteLine();
Console.WriteLine($"TOTAL  : {pass + fail} checks");
Console.WriteLine($"PASSED : {pass}");
Console.WriteLine($"FAILED : {fail}");
Console.WriteLine(pass > 0 && fail == 0 ? "RESULT : ALL PASS" : "RESULT : FAILURES PRESENT");
return fail == 0 ? 0 : 1;
