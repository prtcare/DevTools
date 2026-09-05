// StateReader.cs — builds a DevBridgeState snapshot from the live backend files.
// Read-only. Missing files degrade to nulls/absent flags; it never fabricates values.
using System.Text.Json;

namespace DevBridge.Engine;

public static class StateReader
{
    public static DevBridgeState Read(DevBridgeConfig cfg)
    {
        string currentTaskPath = Path.Combine(cfg.StateDir, "current-task.json");
        var ct = StateJson.TryRead(currentTaskPath);
        bool taskFilePresent = ct is not null;

        var artifacts = DetectArtifacts(cfg);

        // ---- identity + state machine ----
        string? nodeId = StateJson.Str(ct, "nodeId");
        string? status = StateJson.Str(ct, "status");
        string? nextAction = StateJson.Str(ct, "nextAllowedAction");
        string? verdict = StateJson.Str(ct, "preflightVerdict") ?? ReadPreflightVerdict(cfg);

        string? name = StateJson.Str(ct, "name") ?? (ct is not null && ct.Value.TryGetProperty("name", out var nm) ? nm.GetString() : null);
        string? changeId = StateJson.Str(ct, "changeId") ?? StateJson.Str(ct, "completionChangeId");
        string? activityId = StateJson.Str(ct, "activityId");
        string? phase = StateJson.Str(ct, "phase");
        string? layer = StateJson.Str(ct, "layer");
        string? parent = StateJson.Str(ct, "parentNodeId") ?? StateJson.Str(ct, "currentWorkNodeId");
        string? feature = StateJson.Str(ct, "featureNodeId");

        // A state\*.json evidence file (verification / claude / completion / consistency)
        // belongs to the cycle that wrote it. It only applies to the CURRENT cycle when
        // its identity matches: same change id once the task is reserved, or same node id
        // for un-reserved legacy evidence. A fresh PREFLIGHTED/RESERVED record (changeId
        // still null) must never be hijacked by the previous cycle's leftover evidence
        // (parallel-lane scenario).
        bool EvidenceApplies(string? evidenceChangeId, string? evidenceNodeId)
        {
            if (!string.IsNullOrWhiteSpace(changeId))
            {
                if (!string.IsNullOrWhiteSpace(evidenceChangeId))
                    return string.Equals(evidenceChangeId, changeId, StringComparison.Ordinal);
                return evidenceNodeId is not null && string.Equals(evidenceNodeId, nodeId, StringComparison.Ordinal);
            }
            // Not reserved yet: prior-cycle evidence always carries a change id => stale.
            if (!string.IsNullOrWhiteSpace(evidenceChangeId)) return false;
            return evidenceNodeId is not null && string.Equals(evidenceNodeId, nodeId, StringComparison.Ordinal);
        }

        // ---- verification evidence ----
        string? verifResult = null;
        string? verifiedAt = null;
        var verifJson = StateJson.TryRead(Path.Combine(cfg.StateDir, "verification.json"));
        if (verifJson is not null)
        {
            string? evChange = StateJson.Str(verifJson, "changeId");
            string? evNode = StateJson.Str(verifJson, "nodeId") ?? StateJson.Str(verifJson, "taskId");
            if (EvidenceApplies(evChange, evNode))
            {
                verifResult = StateJson.Str(verifJson, "primaryResult");
                verifiedAt = StateJson.Str(verifJson, "verifiedAtUtc");
            }
        }
        else if (artifacts.VerificationReport && MdApplies(SafeRead(Path.Combine(cfg.TasksDir, "VERIFICATION_REPORT.md")), nodeId, changeId))
        {
            var txt = SafeRead(Path.Combine(cfg.TasksDir, "VERIFICATION_REPORT.md"));
            verifResult = txt is not null && txt.Contains("VERIFICATION_FAILED", StringComparison.OrdinalIgnoreCase)
                ? "VERIFICATION_FAILED"
                : txt is not null && txt.Contains("VERIFICATION_PASSED", StringComparison.OrdinalIgnoreCase)
                    ? "VERIFICATION_PASSED" : null;
        }

        // ---- claude evidence ----
        string? claudeDecision = null;
        bool claudeFixRequired = false;
        bool claudeEvidenceApplies = false;
        string? claudeAt = null;
        // DB-M08 record binding: the DB-M06 verification identity (verifiedAtUtc) and
        // manifest id the review was recorded against (Set-ClaudeReviewResult.ps1). This
        // is what makes the review evidence verification-CYCLE-aware instead of just
        // node/change-aware.
        string? reviewedAgainstDbM06 = null;
        var claudeJson = StateJson.TryRead(Path.Combine(cfg.StateDir, "claude-review.json"));
        if (claudeJson is not null)
        {
            string? evChange = StateJson.Str(claudeJson, "changeId");
            string? evNode = StateJson.Str(claudeJson, "nodeId");
            claudeEvidenceApplies = EvidenceApplies(evChange, evNode);
            if (claudeEvidenceApplies)
            {
                claudeDecision = StateJson.Str(claudeJson, "decision");
                claudeAt = StateJson.Str(claudeJson, "reviewedAt");
                reviewedAgainstDbM06 = StateJson.Str(claudeJson, "reviewedAgainstDbM06");
                if (claudeJson.Value.TryGetProperty("dbM09Required", out var d9) && d9.ValueKind == JsonValueKind.True)
                    claudeFixRequired = true;
            }
        }
        else if (artifacts.ClaudeReviewResult && MdApplies(SafeRead(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_RESULT.md")), nodeId, changeId))
        {
            var txt = SafeRead(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_RESULT.md"));
            claudeDecision = txt is not null && txt.Contains("FAIL", StringComparison.OrdinalIgnoreCase)
                && !txt.Contains("PASS", StringComparison.OrdinalIgnoreCase) ? "FAIL" : "PASS";
            claudeFixRequired = txt is not null && txt.Contains("CLAUDE_FIX_REQUIRED", StringComparison.OrdinalIgnoreCase);
        }

        // ---- DB-M08 / Claude-review freshness for the CURRENT verification cycle ----
        // A recorded review is bound to the DB-M06 verification it was reviewed against
        // (reviewedAgainstDbM06 = that cycle's verifiedAtUtc). Once a FRESH DB-M06
        // verification of a corrected attempt lands with a NEW verifiedAtUtc, the earlier
        // review is HISTORICAL evidence for the PRIOR cycle — it must not satisfy DB-M07
        // for the corrected cycle, even though node and change are unchanged. Positive
        // proof only: a record with no binding field (legacy evidence) is never guessed
        // stale, so pre-binding records keep their historical meaning.
        bool claudeReviewStale = claudeEvidenceApplies
            && !string.IsNullOrWhiteSpace(reviewedAgainstDbM06)
            && !string.IsNullOrWhiteSpace(verifiedAt)
            && !string.Equals(reviewedAgainstDbM06, verifiedAt, StringComparison.Ordinal);

        // ---- completion + consistency ----
        bool completionWritten = false;
        string? completionAt = null;
        string? completionNodeId = null;
        string? completionChangeId = null;
        var compJson = StateJson.TryRead(Path.Combine(cfg.StateDir, "completion.json"));
        if (compJson is not null)
        {
            string? evChange = StateJson.Str(compJson, "changeId");
            string? evNode = StateJson.Str(compJson, "nodeId");
            if (EvidenceApplies(evChange, evNode))
            {
                completionWritten = true;
                completionAt = StateJson.Str(compJson, "completedAtUtc");
                completionNodeId = StateJson.Str(compJson, "nodeId");
                completionChangeId = StateJson.Str(compJson, "changeId");
            }
        }
        // Shared tasks\COMPLETION_REPORT.md can be a prior cycle's leftover; it is only
        // honoured when it names the CURRENT task/change (MdApplies). The engine's status
        // guard + CompletionMatchesCurrent also keep a leftover from hijacking early states.
        if (artifacts.CompletionReport && !completionWritten
            && MdApplies(SafeRead(Path.Combine(cfg.TasksDir, "COMPLETION_REPORT.md")), nodeId, changeId))
            completionWritten = true;

        string? consistencyResult = null;
        string? consistencyAt = null;
        var consJson = StateJson.TryRead(Path.Combine(cfg.StateDir, "workbook-consistency.json"));
        if (consJson is not null)
        {
            string? evChange = StateJson.Str(consJson, "changeId");
            string? evNode = StateJson.Str(consJson, "nodeId");
            if (EvidenceApplies(evChange, evNode))
            {
                consistencyResult = StateJson.Str(consJson, "controlValidationResult");
                consistencyAt = StateJson.Str(consJson, "validatedAtUtc");
            }
        }
        else if (artifacts.WorkbookConsistencyReport && MdApplies(SafeRead(Path.Combine(cfg.TasksDir, "WORKBOOK_CONSISTENCY_REPORT.md")), nodeId, changeId))
        {
            var txt = SafeRead(Path.Combine(cfg.TasksDir, "WORKBOOK_CONSISTENCY_REPORT.md"));
            consistencyResult = txt is not null && txt.Contains("CONTROL_VALIDATION_FAILED", StringComparison.OrdinalIgnoreCase)
                ? "FAILED" : "PASS";
        }

        // ---- residual observations ----
        var residuals = new List<ResidualObservation>();
        if (claudeEvidenceApplies && claudeJson is not null && claudeJson.Value.TryGetProperty("residualObservations", out var obs))
        {
            foreach (var o in obs.EnumerateArray())
            {
                residuals.Add(new ResidualObservation(
                    StateJson.Str(o, "severity") ?? "INFO",
                    bool.TryParse(StateJson.Str(o, "blocking"), out var b) && b,
                    StateJson.Str(o, "subject") ?? "",
                    StateJson.Str(o, "detail") ?? ""));
            }
        }

        // ---- failure detail ----
        string? preflightBlocking = null;
        if (verdict is not null && verdict.StartsWith("CLEAR", StringComparison.OrdinalIgnoreCase) == false)
        {
            var pre = StateJson.TryRead(Path.Combine(cfg.StateDir, "preflight.json"));
            if (pre is not null && pre.Value.TryGetProperty("blockingReasons", out var br) && br.ValueKind == JsonValueKind.Array)
                preflightBlocking = string.Join(" | ", br.EnumerateArray().Select(x => x.GetString()).Where(x => x is not null));
            preflightBlocking ??= "Preflight did not return CLEAR.";
        }
        string? verifDetail = verifResult is not null && verifResult.StartsWith("VERIFICATION_FAILED", StringComparison.OrdinalIgnoreCase)
            ? $"primaryResult={verifResult}" : null;

        // ---- current task detail numbers ----
        int? buildProjects = null, buildWarnings = null, buildErrors = null;
        int? testsPassed = null, testsFailed = null, testsTotal = null, harness = null;
        string? histDir = FindHistoryDir(cfg, nodeId, changeId);
        // Prefer the preserved history copy, then the tasks/ root copy.
        if (histDir is not null)
        {
            var b = StateJson.TryRead(Path.Combine(histDir, "build-result.json"));
            if (b is not null) { buildProjects = CountArray(b, "projects"); buildWarnings = IntProp(b, "warnings"); buildErrors = IntProp(b, "errors"); }
            var t = StateJson.TryRead(Path.Combine(histDir, "test-result.json"));
            if (t is not null && t.Value.TryGetProperty("testRun", out var tr)) { testsPassed = IntProp(tr, "passed"); testsFailed = IntProp(tr, "failed"); testsTotal = IntProp(tr, "total"); }
            if (t is not null && t.Value.TryGetProperty("harnessRun", out var hr)) harness = IntProp(hr, "checksPassed");
        }
        if (buildProjects is null)
        {
            var b = StateJson.TryRead(Path.Combine(cfg.TasksDir, "build-result.json"));
            if (b is not null) { buildProjects = CountArray(b, "projects"); buildWarnings = IntProp(b, "warnings"); buildErrors = IntProp(b, "errors"); }
        }

        // ---- DB-GH01 governance surface ----
        // Explicit mode: current-task "mode" wins, then config, then cycle trial evidence.
        DevBridgeOperatingMode mode = cfg.Mode;
        string? modeToken = StateJson.Str(ct, "mode");
        if (!string.IsNullOrWhiteSpace(modeToken))
        {
            mode = DevBridgeMode.FromString(modeToken);
        }
        else if (ct is not null && (BlockBool(ct, "dbM08", "trialMode") || BlockBool(ct, "dbM06", "trialMode")))
        {
            mode = DevBridgeOperatingMode.Trial;
        }

        // Observed git (read-only; DevBridge never mutates a repository).
        ObservedGitState? gitObserved = null;
        if (ct is not null && ct.Value.TryGetProperty("repositoryStates", out var repos) && repos.ValueKind == JsonValueKind.Array && repos.GetArrayLength() > 0)
        {
            var repo = repos[0];
            gitObserved = new ObservedGitState(
                IsTrue(StateJson.Str(repo, "isGitRepo")),
                StateJson.Str(repo, "branch"),
                StateJson.Str(repo, "headCommit"),
                IsTrue(StateJson.Str(repo, "dirty")),
                "UNMERGED", // merge state is asserted by the operator via gitLifecycleState, never inferred here
                StateJson.Str(repo, "capturedAt"));
        }

        // Human Git gate position: explicit gitLifecycleState, else mapped from status (real-mode only).
        string? gitLifecycleToken = StateJson.Str(ct, "gitLifecycleState");
        HumanGitGateState gitGate = gitLifecycleToken is not null
            ? GitLifecycle.FromString(gitLifecycleToken)
            : GitLifecycle.FromString(status);

        // Protected roadmap fingerprint guard.
        RoadmapGuardVerdict? roadmapGuard = null;
        var fp = StateJson.TryRead(Path.Combine(cfg.StateDir, "roadmap-fingerprint.json"));
        if (fp is not null)
        {
            if (fp.Value.TryGetProperty("before", out var bef) && fp.Value.TryGetProperty("after", out var aft))
                roadmapGuard = ProtectedRoadmapFingerprintGuard.Guard(FpFrom(bef), FpFrom(aft));
            else if (fp.Value.TryGetProperty("fingerprint", out var fv))
                roadmapGuard = RoadmapGuardVerdict.NotComparable; // single-capture evidence; guarded at the write
        }

        // M10 completion eligibility (pure gate; never performs the write).
        var m10 = M10CompletionEligibility.Evaluate(
            mode == DevBridgeOperatingMode.Trial,
            verifResult is not null && verifResult.StartsWith("VERIFICATION_PASSED", StringComparison.OrdinalIgnoreCase),
            claudeDecision is not null && claudeDecision.StartsWith("PASS", StringComparison.OrdinalIgnoreCase),
            gitGate,
            roadmapGuard ?? RoadmapGuardVerdict.NotComparable);

        // ChatGPT handoff validation (v1) — READY / CHATGPT_HANDOFF_NOT_READY.
        ChatGptHandoffValidationResult? handoff = null;
        string? handoffMd = SafeRead(Path.Combine(cfg.TasksDir, "CHATGPT_HANDOFF.md"));
        if (handoffMd is not null) handoff = ChatGptHandoffValidation.Validate(handoffMd);

        // Claude review package governance-header validation (DB-M07).
        ClaudeReviewPackageValidationResult? pkg = null;
        string? pkgMd = SafeRead(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_PACKAGE.md"));
        if (pkgMd is not null) pkg = ClaudeReviewPackageValidation.Validate(pkgMd);

        // DB-M07 Claude Review Manifest readiness for the CURRENT cycle: current-task
        // dbM07 carries a ready stamp whose nodeId/changeId match the current task AND
        // the manifest file exists AND the stamp is bound to the CURRENT applied DB-M06
        // verification (dbM07.verifiedAtUtc == verifiedAt). Same node/change is NOT
        // enough: after a fresh DB-M06 verification of a corrected attempt, the previous
        // cycle's package is stale even though it names the same task — it must be
        // regenerated against the latest DB-M06. A legacy/stale REVIEW_PACKET.md (old
        // model, no dbM07 stamp) is deliberately NOT current — COPY FOR CLAUDE stays
        // disabled until the current manifest is generated.
        bool manifestReady = false;
        bool manifestStale = false;
        string? manifestId = null;
        if (ct is not null && nodeId is not null && changeId is not null
            && ct.Value.TryGetProperty("dbM07", out var db7) && db7.ValueKind == JsonValueKind.Object)
        {
            bool stamped = IsTrue(StateJson.Str(db7, "ready"))
                && string.Equals(StateJson.Str(db7, "nodeId"), nodeId, StringComparison.Ordinal)
                && string.Equals(StateJson.Str(db7, "changeId"), changeId, StringComparison.Ordinal)
                && File.Exists(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_PACKAGE.md"));
            string? db7VerifiedAt = StateJson.Str(db7, "verifiedAtUtc");
            bool boundToCurrentVerification = stamped
                && !string.IsNullOrWhiteSpace(db7VerifiedAt)
                && !string.IsNullOrWhiteSpace(verifiedAt)
                && string.Equals(db7VerifiedAt, verifiedAt, StringComparison.Ordinal);
            manifestReady = boundToCurrentVerification;
            // Positive proof a stamped manifest is stale: it exists for this node/change
            // but is bound to an OLDER DB-M06 verification than the one now applied.
            manifestStale = stamped && !boundToCurrentVerification;
            if (manifestReady) manifestId = StateJson.Str(db7, "manifestId");
        }

        // DB-M15 correction reconciliation (post CORRECT_CURRENT_ATTEMPT): current-task
        // dbM09 carries a correctionReconciled stamp whose result is CORRECTION_DELTA_DETECTED.
        // True only for the CURRENT cycle (same node/change as the M09 fix decision).
        bool correctionReconciled = false;
        if (ct is not null && nodeId is not null && changeId is not null
            && ct.Value.TryGetProperty("dbM09", out var db9) && db9.ValueKind == JsonValueKind.Object)
        {
            string? db9Node = StateJson.Str(db9, "nodeId");
            string? db9Change = StateJson.Str(db9, "changeId");
            bool db9Applies = string.Equals(db9Node, nodeId, StringComparison.Ordinal)
                && string.Equals(db9Change, changeId, StringComparison.Ordinal);
            if (db9Applies && db9.TryGetProperty("correctionReconciled", out var rec) && rec.ValueKind == JsonValueKind.Object)
                correctionReconciled = string.Equals(StateJson.Str(rec, "result"), "CORRECTION_DELTA_DETECTED", StringComparison.Ordinal);
        }

        // DB-M11 advisory review recommendation (Role B; read-only, never blocking).
        M11ReviewRecommendation? m11 = null;
        var m11r = StateJson.TryRead(Path.Combine(cfg.StateDir, "db-m11-review-recommendation.json"));
        if (m11r is not null)
        {
            m11 = new M11ReviewRecommendation(
                IsTrue(StateJson.Str(m11r, "deterministicValidationPassed")),
                IsTrue(StateJson.Str(m11r, "claudeWorkbookReviewRecommended")),
                StateJson.Str(m11r, "reason"));
        }

        var preBaseline = PreDevBridgeBaseline.Load(cfg);

        return new DevBridgeState
        {
            NodeId = nodeId,
            TaskName = name,
            ChangeId = changeId,
            ActivityId = activityId,
            Phase = phase,
            Layer = layer,
            ParentNodeId = parent,
            FeatureNodeId = feature,
            Status = status,
            NextAllowedAction = nextAction,
            PreflightVerdict = verdict,
            TaskStateFilePresent = taskFilePresent,
            Artifacts = artifacts,
            VerificationPrimaryResult = verifResult,
            ClaudeDecision = claudeDecision,
            ClaudeFixRequired = claudeFixRequired,
            CompletionWritten = completionWritten,
            CompletionNodeId = completionNodeId,
            CompletionChangeId = completionChangeId,
            ConsistencyResult = consistencyResult,
            SelectedAtDisplay = StateJson.Str(ct, "selectedAt") ?? StateJson.Str(ct, "reservedAt") ?? StateJson.Str(ct, "completedWorkbookWriteAt"),
            PreflightBlockingReasons = preflightBlocking,
            VerificationFailureDetail = verifDetail,
            ClaudeFixDetail = claudeFixRequired ? "Claude requested a fix loop (DB-M09)." : null,
            ConsistencyFailureDetail = consistencyResult is not null && !consistencyResult.StartsWith("PASS", StringComparison.OrdinalIgnoreCase)
                ? $"controlValidationResult={consistencyResult}" : null,
            ResidualObservations = residuals,
            VerifiedAtUtc = verifiedAt,
            ClaudeReviewedAtUtc = claudeAt,
            CompletionWrittenAtUtc = completionAt,
            ConsistencyValidatedAtUtc = consistencyAt,
            BuildProjects = buildProjects,
            BuildWarnings = buildWarnings,
            BuildErrors = buildErrors,
            TestsPassed = testsPassed,
            TestsFailed = testsFailed,
            TestsTotal = testsTotal,
            HarnessChecks = harness,
            CurrentTaskJsonPath = currentTaskPath,
            CurrentTaskHistoryDir = histDir,
            Mode = mode,
            ModeToken = DevBridgeMode.ToToken(mode),
            GitObserved = gitObserved,
            HumanGitState = gitGate,
            GitHumanGuidance = GitLifecycle.HumanGuidance(gitGate),
            PreDevBridgeBaseline = preBaseline,
            HandoffValidation = handoff,
            ReviewPackageValidation = pkg,
            ClaudeReviewManifestReady = manifestReady,
            ClaudeReviewManifestId = manifestId,
            ClaudeReviewManifestStale = manifestStale,
            ClaudeReviewStale = claudeReviewStale,
            CorrectionReconciled = correctionReconciled,
            M10Eligibility = m10,
            RoadmapGuard = roadmapGuard,
            M11Recommendation = m11,
        };
    }

    // ---- DB-GH01 helpers ----

    /// <summary>
    /// A shared tasks\*.md fallback only applies to the CURRENT cycle when it names the
    /// current node or change. This closes the stale-hijack gap where a previous cycle's
    /// leftover CLAUDE_REVIEW_RESULT.md / VERIFICATION_REPORT.md / COMPLETION_REPORT.md /
    /// WORKBOOK_CONSISTENCY_REPORT.md would otherwise bleed into a fresh cycle.
    /// </summary>
    private static bool MdApplies(string? text, string? nodeId, string? changeId)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        if (!string.IsNullOrWhiteSpace(changeId) && text.Contains(changeId, StringComparison.OrdinalIgnoreCase)) return true;
        if (!string.IsNullOrWhiteSpace(nodeId) && text.Contains(nodeId, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static bool BlockBool(JsonElement? ct, string block, string key)
        => ct is not null && ct.Value.TryGetProperty(block, out var b) && IsTrue(StateJson.Str(b, key));

    private static bool IsTrue(string? token)
        => token is not null && token.StartsWith("True", StringComparison.OrdinalIgnoreCase);

    private static ProtectedRoadmapFingerprint? FpFrom(JsonElement el)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        return new ProtectedRoadmapFingerprint(
            StateJson.Str(el, "value") ?? "",
            StateJson.Str(el, "sheetCoverage") ?? "",
            StateJson.Str(el, "configSource") ?? "",
            StateJson.Str(el, "error"));
    }

    public static ArtifactPresence DetectArtifacts(DevBridgeConfig cfg)
    {
        string T(string f) => Path.Combine(cfg.TasksDir, f);
        string deepseek = SafeRead(T("DEEPSEEK_PROMPT.md")) ?? "";
        bool hasImpl = deepseek.Contains("No implementation prompt yet", StringComparison.OrdinalIgnoreCase) == false
                       && deepseek.Length > 120
                       && !deepseek.TrimStart().StartsWith("# Awaiting ChatGPT Prompt", StringComparison.OrdinalIgnoreCase);
        return new ArtifactPresence(
            File.Exists(T("NEXT_TASK.md")),
            File.Exists(T("PREFLIGHT_REPORT.md")),
            File.Exists(T("START_BASELINE.md")),
            File.Exists(T("CHATGPT_HANDOFF.md")),
            File.Exists(T("DEEPSEEK_PROMPT.md")),
            hasImpl,
            File.Exists(T("VERIFICATION_REPORT.md")),
            File.Exists(T("REVIEW_PACKET.md")),
            File.Exists(T("CLAUDE_REVIEW_PROMPT.md")),
            File.Exists(T("CLAUDE_REVIEW_RESULT.md")),
            File.Exists(T("FIX_CONTEXT.md")),
            File.Exists(T("SHEET_UPDATE_PLAN.md")),
            File.Exists(T("COMPLETION_REPORT.md")),
            File.Exists(T("WORKBOOK_CONSISTENCY_REPORT.md")));
    }

    private static string? ReadPreflightVerdict(DevBridgeConfig cfg)
    {
        var p = StateJson.TryRead(Path.Combine(cfg.StateDir, "preflight.json"));
        return StateJson.Str(p, "verdict");
    }

    private static string? FindHistoryDir(DevBridgeConfig cfg, string? nodeId, string? changeId)
    {
        if (string.IsNullOrWhiteSpace(nodeId) || string.IsNullOrWhiteSpace(changeId)) return null;
        string d = Path.Combine(cfg.LogsTasksDir, nodeId, changeId);
        return Directory.Exists(d) ? d : null;
    }

    private static string? SafeRead(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    private static int? IntProp(JsonElement? el, string key)
        => el is not null && el.Value.ValueKind == JsonValueKind.Object && el.Value.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetInt32() : null;

    private static int? CountArray(JsonElement? el, string key)
        => el is not null && el.Value.ValueKind == JsonValueKind.Object && el.Value.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.GetArrayLength() : null;
}
