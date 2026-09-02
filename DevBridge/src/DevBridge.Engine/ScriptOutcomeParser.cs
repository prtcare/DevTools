// ScriptOutcomeParser.cs — reads the DB-* outcome markers the governed backend
// scripts print to stdout (DB0X_OUTCOME: <TOKEN>, DB0X_RESULT_PASS: True|False,
// PREFLIGHT VERDICT: <TOKEN>). These markers are the scripts' OWN communication
// contract — the UI does not interpret business logic, it only reads the outcome
// the script declared. Several scripts exit 0 even on a governed STOP, so the
// exit code alone can never be trusted (DB-M12.1, Part 7).
//
// DB-M12.2 extends the contract with the one-command fields the reusable backend
// scripts declare alongside the outcome: DB0X_RESULT_CODE, DB0X_WORKBOOK_MODIFIED,
// DB0X_NEXUS_SOURCE_MODIFIED, DB0X_GIT_MODIFIED, DB0X_REQUIRES_HUMAN_ACTION,
// DB0X_HUMAN_ACTION_TYPE and repeatable DB0X_EVIDENCE lines.
using System.Text.RegularExpressions;

namespace DevBridge.Engine;

public sealed record ScriptOutcome(
    string? OutcomeToken,     // e.g. RESERVED / REUSED / STOP_RESERVATION_CONFLICT / CLEAR
    bool? ResultPass,         // DB0X_RESULT_PASS: True|False when present
    string? Verdict,          // PREFLIGHT VERDICT: <verdict> when present
    string? ResultCode = null,                // DB-M12.2: DB0X_RESULT_CODE token (e.g. TRIAL_COMPLETION_NOT_APPLICABLE)
    bool? WorkbookModified = null,            // DB-M12.2: DB0X_WORKBOOK_MODIFIED True|False
    bool? NexusSourceModified = null,         // DB-M12.2: DB0X_NEXUS_SOURCE_MODIFIED True|False
    bool? GitModified = null,                 // DB-M12.2: DB0X_GIT_MODIFIED True|False
    bool? RequiresHumanAction = null,         // DB-M12.2: DB0X_REQUIRES_HUMAN_ACTION True|False
    string? HumanActionType = null,           // DB-M12.2: DB0X_HUMAN_ACTION_TYPE token
    IReadOnlyList<string>? Evidence = null)   // DB-M12.2: repeatable DB0X_EVIDENCE <path>
{
    public bool IsGovernedStop => OutcomeToken is not null && OutcomeToken.StartsWith("STOP_", StringComparison.Ordinal);
}

public static class ScriptOutcomeParser
{
    private static readonly Regex OutcomeRe = new(
        @"(?im)^\s*(?:DB\d\d_OUTCOME|OUTCOME)\s*:\s*([A-Za-z0-9_]+)",
        RegexOptions.Compiled);

    private static readonly Regex ResultPassRe = new(
        @"(?im)^\s*DB\d\d_RESULT_PASS\s*:\s*(True|False)",
        RegexOptions.Compiled);

    private static readonly Regex VerdictRe = new(
        @"(?im)^\s*PREFLIGHT\s+VERDICT\s*:\s*([A-Za-z0-9_ ]+)",
        RegexOptions.Compiled);

    // ---- DB-M12.2 one-command-contract markers (all optional, all on stdout) ----
    private static readonly Regex ResultCodeRe = new(
        @"(?im)^\s*DB\d\d_RESULT_CODE\s*:\s*([A-Za-z0-9_]+)",
        RegexOptions.Compiled);

    private static readonly Regex WorkbookModifiedRe = new(
        @"(?im)^\s*DB\d\d_WORKBOOK_MODIFIED\s*:\s*(True|False)",
        RegexOptions.Compiled);

    private static readonly Regex NexusSourceModifiedRe = new(
        @"(?im)^\s*DB\d\d_NEXUS_SOURCE_MODIFIED\s*:\s*(True|False)",
        RegexOptions.Compiled);

    private static readonly Regex GitModifiedRe = new(
        @"(?im)^\s*DB\d\d_GIT_MODIFIED\s*:\s*(True|False)",
        RegexOptions.Compiled);

    private static readonly Regex RequiresHumanActionRe = new(
        @"(?im)^\s*DB\d\d_REQUIRES_HUMAN_ACTION\s*:\s*(True|False)",
        RegexOptions.Compiled);

    private static readonly Regex HumanActionTypeRe = new(
        @"(?im)^\s*DB\d\d_HUMAN_ACTION_TYPE\s*:\s*([A-Za-z0-9_]+)",
        RegexOptions.Compiled);

    private static readonly Regex EvidenceRe = new(
        @"(?im)^\s*DB\d\d_EVIDENCE\s*:\s*(.+)$",
        RegexOptions.Compiled);

    public static ScriptOutcome Parse(string stdout)
    {
        string? token = null;
        bool? pass = null;
        string? verdict = null;

        var mOut = OutcomeRe.Match(stdout);
        if (mOut.Success) token = mOut.Groups[1].Value.Trim();

        var mPass = ResultPassRe.Match(stdout);
        if (mPass.Success) pass = string.Equals(mPass.Groups[1].Value, "True", StringComparison.Ordinal);

        var mVerd = VerdictRe.Match(stdout);
        if (mVerd.Success) verdict = mVerd.Groups[1].Value.Trim();

        var mCode = ResultCodeRe.Match(stdout);
        string? resultCode = mCode.Success ? mCode.Groups[1].Value.Trim() : null;

        bool? wbMod = MatchBool(WorkbookModifiedRe, stdout);
        bool? nexMod = MatchBool(NexusSourceModifiedRe, stdout);
        bool? gitMod = MatchBool(GitModifiedRe, stdout);
        bool? reqHuman = MatchBool(RequiresHumanActionRe, stdout);

        var mHuman = HumanActionTypeRe.Match(stdout);
        string? humanActionType = mHuman.Success ? mHuman.Groups[1].Value.Trim() : null;

        var evidence = new List<string>();
        foreach (Match m in EvidenceRe.Matches(stdout))
        {
            string v = m.Groups[1].Value.Trim().TrimEnd('\r');
            if (v.Length > 0) evidence.Add(v);
        }

        return new ScriptOutcome(token, pass, verdict, resultCode, wbMod, nexMod, gitMod, reqHuman, humanActionType, evidence);
    }

    private static bool? MatchBool(Regex re, string stdout)
    {
        var m = re.Match(stdout);
        return m.Success ? string.Equals(m.Groups[1].Value, "True", StringComparison.Ordinal) : (bool?)null;
    }
}
