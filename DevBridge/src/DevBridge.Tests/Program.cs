// Program.cs — DB-M12 fixture runner (no external test framework; console exit code).
// Builds representative DevBridge states on disk and asserts that DevBridge.Engine
// derives the correct next action, enabled buttons (no invalid transitions), stage
// states, failure visibility, task history (failed attempts never hidden), control
// health and the parallel active-changes view.
using System.Text.Json;
using DevBridge.Engine;

int pass = 0, fail = 0;
var failures = new List<string>();

void Check(bool cond, string name, string detail)
{
    if (cond) { pass++; }
    else { fail++; failures.Add($"  FAIL {name}: {detail}"); }
}

bool SetsEqual(IEnumerable<string> actual, IEnumerable<string> expected)
{
    var a = actual.OrderBy(x => x, StringComparer.Ordinal).ToArray();
    var e = expected.OrderBy(x => x, StringComparer.Ordinal).ToArray();
    return a.SequenceEqual(e, StringComparer.Ordinal);
}

string EnabledDesc(IEnumerable<string> b) => string.Join(",", b.OrderBy(x => x, StringComparer.Ordinal));

// ---- optional: read-only live smoke against the REAL DevBridge state -----------
if (args.Length > 0 && args[0] == "--live")
{
    LiveSmoke();
    return;
}

static void LiveSmoke()
{
    var cfg = DevBridgeConfig.Load();
    Console.WriteLine("LIVE SMOKE — read-only view of the live DevBridge state");
    Console.WriteLine($"Root: {cfg.Root}");
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Console.WriteLine($"Node: {s.NodeId}  Task: {s.TaskName}  Status: {s.Status}  Change: {s.ChangeId ?? "null"}");
    Console.WriteLine($"INSTRUCTION: {n.Instruction}");
    Console.WriteLine($"ENABLED: {string.Join(", ", n.EnabledButtons)}");
    foreach (var st in n.Stages) Console.WriteLine($"  {st.Key,-17} {st.State}");
    var h = ControlHealthService.Evaluate(cfg);
    Console.WriteLine($"Workbook: {h.WorkbookState} sheets={h.SheetCount}/{h.ExpectedSheets} sha={(h.WorkbookSha256 ?? "-")}");
    Console.WriteLine($"Consistency: {h.LastConsistencyResult} @ {h.LastConsistencyAt ?? "-"}");
    Console.WriteLine($"History tasks: {TaskHistoryService.Scan(cfg).Count}");
    var (rows, open, term, ts) = ActiveChangesSnapshot.Load(cfg);
    Console.WriteLine($"Active changes: {rows.Count} rows, {open} open / {term} terminal ({ts})");
}

// --------------------------------------------------------------------- fixture root
static string NewRoot(string label)
{
    string dir = Path.Combine(Path.GetTempPath(), "dbm12-" + label + "-" + Guid.NewGuid().ToString("N")[..8]);
    Directory.CreateDirectory(Path.Combine(dir, "state"));
    Directory.CreateDirectory(Path.Combine(dir, "tasks"));
    Directory.CreateDirectory(Path.Combine(dir, "scripts"));
    return dir;
}

void W(string root, string rel, string content)
{
    string p = Path.Combine(root, rel);
    Directory.CreateDirectory(Path.GetDirectoryName(p)!);
    File.WriteAllText(p, content);
}

string StateJson(string status, string nextAction, string nodeId = "WI-07-0.2.4", string name = "Test Task",
    string changeId = "CHG-20260830-017", string? verdict = null, string? phase = "P0", string? layer = "App")
{
    var sb = new System.Text.StringBuilder();
    sb.Append("{\"nodeId\":\"").Append(nodeId).Append("\",\"name\":\"").Append(name)
      .Append("\",\"nodeType\":\"WorkItem\",\"phase\":\"").Append(phase ?? "").Append("\",\"layer\":\"")
      .Append(layer ?? "").Append("\",\"changeId\":\"").Append(changeId).Append("\",\"status\":\"")
      .Append(status).Append("\",\"nextAllowedAction\":\"").Append(nextAction).Append("\"");
    if (verdict is not null) sb.Append(",\"preflightVerdict\":\"").Append(verdict).Append("\"");
    sb.Append(",\"selectedAt\":\"2026-08-30T17:04:09Z\"}");
    return sb.ToString();
}

// ---- DB-M12.1 helpers -------------------------------------------------------
void WriteState(string root, string status, string nextAction, string changeId, string? verdict = null)
    => W(root, @"state/current-task.json", StateJson(status, nextAction, changeId: changeId, verdict: verdict));

ScriptRunOutcome Ok(string stdout) => new(true, 0, stdout, "", TimeSpan.FromMilliseconds(10), false);

FakeScriptRunner Runner(params (string script, Func<string, ScriptRunOutcome> behavior)[] pairs)
{
    var d = new Dictionary<string, Func<string, ScriptRunOutcome>>(StringComparer.OrdinalIgnoreCase);
    foreach (var (s, f) in pairs) d[s] = f;
    return new FakeScriptRunner(d);
}

// ==================================================================== fixtures

// ---- 0. NO ACTIVE TASK ------------------------------------------------------
{
    string root = NewRoot("none");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(!n.HasActiveTask, "NO_TASK: no active task flag", $"hasTask={n.HasActiveTask}");
    Check(n.Instruction.Contains("Start preflight", StringComparison.Ordinal), "NO_TASK: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "START_PREFLIGHT" }), "NO_TASK: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Failure is null, "NO_TASK: no failure", n.Failure?.Result ?? "none");
}

// ---- 1. CONTROL_VALIDATED ---------------------------------------------------
{
    string root = NewRoot("validated");
    W(root, @"state/current-task.json", StateJson("CONTROL_VALIDATED", "START_NEW_PREFLIGHT"));
    W(root, @"state/workbook-consistency.json", "{\"nodeId\":\"WI-07-0.2.4\",\"controlValidationResult\":\"PASS\",\"validatedAtUtc\":\"2026-08-30T17:00:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.HasActiveTask, "CONTROL_VALIDATED: active task", $"hasTask={n.HasActiveTask}");
    Check(n.Instruction.Contains("Development cycle complete", StringComparison.Ordinal), "CONTROL_VALIDATED: instruction", n.Instruction);
    // DB-M12.3: START_NEXT_CYCLE was unbound (absent from the operator catalog); the
    // cycle-restart action is the real START_PREFLIGHT backend command.
    Check(SetsEqual(n.EnabledButtons, new[] { "START_PREFLIGHT", "OPEN_DETAIL" }), "CONTROL_VALIDATED: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Done && m.State == StageState.Current), "CONTROL_VALIDATED: Done current",
        "done stage not current");
    Check(!n.EnabledButtons.Contains("VALIDATE_WORKBOOK"), "CONTROL_VALIDATED: validate disabled", "VALIDATE_WORKBOOK enabled");
    Check(n.Failure is null, "CONTROL_VALIDATED: no failure", n.Failure?.Result ?? "none");
}

// ---- 2. PREFLIGHTED CLEAR (+ stale completion parallel-safety) ---------------
{
    string root = NewRoot("preflighted");
    W(root, @"state/current-task.json", StateJson("PREFLIGHTED", "RESERVE", changeId: "CHG-20260830-018", verdict: "CLEAR"));
    W(root, @"state/preflight.json", "{\"verdict\":\"CLEAR\",\"generatedAtUtc\":\"2026-08-30T17:10:00Z\"}");
    // STALE completion.json from a PREVIOUS cycle — must NOT hijack this state.
    W(root, @"state/completion.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"completedAtUtc\":\"2026-08-30T16:50:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Reserve this task", StringComparison.Ordinal), "PREFLIGHTED: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "RESERVE_TASK", "OPEN_PREFLIGHT_REPORT", "OPEN_DETAIL" }), "PREFLIGHTED: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Reservation && m.State == StageState.Current), "PREFLIGHTED: reservation current", "reservation not current");
    Check(n.Failure is null, "PREFLIGHTED: no failure", n.Failure?.Result ?? "none");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "PREFLIGHTED: stale completion must not enable completion",
        "RUN_GOVERNED_COMPLETION enabled from stale completion.json");
}

// ---- 3. PREFLIGHT FAILED -----------------------------------------------------
{
    string root = NewRoot("preflightfail");
    W(root, @"state/current-task.json", StateJson("PREFLIGHTED", "RESOLVE_PREFLIGHT", verdict: "FAIL"));
    W(root, @"state/preflight.json",
        "{\"verdict\":\"FAIL\",\"blockingReasons\":[\"Dependency M-07-0.2.9 not started\",\"Open decision DEC-009 unresolved\"]}");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("blocking issues", StringComparison.Ordinal), "PREFLIGHT_FAILED: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "OPEN_PREFLIGHT_REPORT", "OPEN_DETAIL" }), "PREFLIGHT_FAILED: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("RESERVE_TASK"), "PREFLIGHT_FAILED: reserve disabled", "RESERVE_TASK enabled on blocked preflight");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Preflight && m.State == StageState.Failed), "PREFLIGHT_FAILED: preflight failed", "preflight not failed");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Reservation && m.State == StageState.Blocked), "PREFLIGHT_FAILED: reservation blocked", "reservation not blocked");
    Check(n.Failure is not null && n.Failure.StageKey == "PREFLIGHT", "PREFLIGHT_FAILED: failure surfaced", n.Failure?.StageKey ?? "none");
    Check(n.Failure is not null && n.Failure.Result.Contains("Dependency M-07-0.2.9", StringComparison.Ordinal), "PREFLIGHT_FAILED: failure reason",
        n.Failure?.Result ?? "none");
}

// ---- 4. RESERVED --------------------------------------------------------------
{
    string root = NewRoot("reserved");
    W(root, @"state/current-task.json", StateJson("RESERVED", "CHATGPT_HANDOFF", changeId: "CHG-20260830-019"));
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Prepare the ChatGPT handoff", StringComparison.Ordinal), "RESERVED: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "CREATE_CHATGPT_HANDOFF", "OPEN_DETAIL" }), "RESERVED: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("RESERVE_TASK"), "RESERVED: reserve disabled", "RESERVE_TASK enabled after reservation");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.ChatGpt && m.State == StageState.Current), "RESERVED: chatgpt current", "chatgpt not current");
}

// ---- 5. AWAITING_CHATGPT_PROMPT (handoff VALID — DB-M12.3 M05 gate) -----------
// The handoff fixture is a valid 14-marker zero-context handoff so the existing
// "copy enabled when ready" intent holds under the new HandoffReady gate.
{
    string root = NewRoot("awaiting");
    W(root, @"state/current-task.json", StateJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", changeId: "CHG-20260830-020"));
    string validHandoff =
        "CHATGPT HANDOFF — DevBridge temporary external scaffolding.\n" +
        "Mode: TRIAL (disposable proving activity, not permanent Nexus development).\n" +
        "This is temporary scaffolding for Nexus Phase 1/2 only; DevBridge will be retired.\n" +
        "Architecture: NOT Nexus — no Nexus architecture/contracts changes via DevBridge.\n" +
        "Roadmap protection: the roadmap is immutable; no structural edits are permitted.\n" +
        "Workbook authority: NEXUS_DEVELOPMENT_CONTROL.xlsx is the authoritative control record.\n" +
        "Git gate: git is a formal human-gated lifecycle — a human creates and merges PRs.\n" +
        "Claude gate: the DB-M08 Claude review gate applies.\n" +
        "Task identity: task WI-07-0.2.4 node WI-07-0.2.4 change CHG-20260830-020.\n" +
        "Exact scope: the exact reserved scope is stated below.\n" +
        "Forbidden: ChatGPT must not perform structural edits and must not create/merge PRs.\n" +
        "Acceptance criteria: the acceptance criteria for this task are included below.\n" +
        "Verification: the DB-M06 verification requirements are included below.\n" +
        "Output contract: the DeepSeek completion report output contract is stated.";
    W(root, @"tasks/CHATGPT_HANDOFF.md", validHandoff);
    W(root, @"tasks/DEEPSEEK_PROMPT.md", "# Awaiting ChatGPT Prompt\n\nNo implementation prompt yet\n");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(s.HandoffReady, "AWAITING: handoff passes 14 checks", $"ready={s.HandoffReady}");
    Check(n.Instruction.Contains("Copy this task context to ChatGPT", StringComparison.Ordinal), "AWAITING: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "COPY_FOR_CHATGPT", "OPEN_DETAIL" }), "AWAITING: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.ChatGpt && m.State == StageState.Current), "AWAITING: chatgpt current", "chatgpt not current");
    Check(!n.EnabledButtons.Contains("CREATE_CHATGPT_HANDOFF"), "AWAITING: recreate disabled", "CREATE_CHATGPT_HANDOFF enabled");
}

// ---- 5c. AWAITING_CHATGPT_PROMPT but handoff INVALID (DB-M12.3 M05 gate) -------
{
    string root = NewRoot("awaitinginvalid");
    W(root, @"state/current-task.json", StateJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", changeId: "CHG-20260830-022"));
    W(root, @"tasks/CHATGPT_HANDOFF.md", "Brief handoff note that misses the 14 mandatory zero-context checks.");
    W(root, @"tasks/DEEPSEEK_PROMPT.md", "# Awaiting ChatGPT Prompt\n\nNo implementation prompt yet\n");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(!s.HandoffReady, "M05_GATE: handoff not ready", $"ready={s.HandoffReady}");
    Check(s.HandoffValidation is not null && s.HandoffValidation.Missing.Count > 0, "M05_GATE: missing checks surfaced",
        $"missing={s.HandoffValidation?.Missing.Count}");
    Check(n.Instruction.Contains("CHATGPT_HANDOFF_NOT_READY", StringComparison.Ordinal), "M05_GATE: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "CREATE_CHATGPT_HANDOFF", "OPEN_DETAIL" }), "M05_GATE: buttons (copy disabled)",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("COPY_FOR_CHATGPT"), "M05_GATE: copy disabled", "COPY_FOR_CHATGPT enabled on invalid handoff");
}

// ---- 5b. AWAITING_CHATGPT_PROMPT but handoff MISSING --------------------------
{
    string root = NewRoot("awaitingmissing");
    W(root, @"state/current-task.json", StateJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", changeId: "CHG-20260830-021"));
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("handoff not found", StringComparison.Ordinal), "AWAITING_MISSING: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "CREATE_CHATGPT_HANDOFF", "OPEN_DETAIL" }), "AWAITING_MISSING: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("COPY_FOR_CHATGPT"), "AWAITING_MISSING: copy disabled", "COPY_FOR_CHATGPT enabled without handoff");
}

// ---- 6. IMPLEMENTATION IN PROGRESS -------------------------------------------
{
    string root = NewRoot("implementing");
    W(root, @"state/current-task.json", StateJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", changeId: "CHG-20260830-022"));
    W(root, @"tasks/CHATGPT_HANDOFF.md", "Handoff text that exists.");
    W(root, @"tasks/DEEPSEEK_PROMPT.md",
        "Implement the ExcelWorkbookColumnMap in Nexus.Developer.Core per the acceptance criteria: " +
        "Required() must throw on missing column, GetCell must handle inlineStr and shared strings, " +
        "and every method must be deterministic and side-effect free with full test coverage.");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("DeepSeek", StringComparison.Ordinal), "IMPL: instruction mentions DeepSeek", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "COPY_FOR_DEEPSEEK", "OPEN_DEEPSEEK_PROMPT", "RUN_VERIFICATION", "OPEN_DETAIL" }), "IMPL: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.DeepSeek && m.State == StageState.Current), "IMPL: deepseek current", "deepseek not current");
    Check(!n.EnabledButtons.Contains("COPY_FOR_CHATGPT"), "IMPL: chatgpt copy disabled", "COPY_FOR_CHATGPT enabled during implementation");
}

// ---- 7. VERIFICATION FAILED ---------------------------------------------------
{
    string root = NewRoot("veriffail");
    W(root, @"state/current-task.json", StateJson("VERIFIED", "FIX_AND_REVERIFY", changeId: "CHG-20260830-023"));
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"primaryResult\":\"VERIFICATION_FAILED\",\"verifiedAtUtc\":\"2026-08-30T18:00:00Z\",\"partsFailed\":2}");
    W(root, @"tasks/VERIFICATION_REPORT.md", "VERIFICATION_FAILED\n\n2 parts failed: schema check, row count.");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Verification failed", StringComparison.Ordinal), "VERIF_FAIL: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "OPEN_VERIFICATION_REPORT", "RUN_VERIFICATION", "OPEN_DETAIL" }), "VERIF_FAIL: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Verification && m.State == StageState.Failed), "VERIF_FAIL: verification failed", "verification not failed");
    Check(n.Failure is not null && n.Failure.StageKey == "VERIFICATION", "VERIF_FAIL: failure surfaced", n.Failure?.StageKey ?? "none");
    Check(n.Failure is not null && n.Failure.RecommendedAction.Contains("re-run", StringComparison.OrdinalIgnoreCase), "VERIF_FAIL: recommendation", n.Failure?.RecommendedAction ?? "none");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "VERIF_FAIL: completion disabled", "RUN_GOVERNED_COMPLETION enabled");
}

// ---- 8. VERIFIED (no packet yet) ----------------------------------------------
{
    string root = NewRoot("verified");
    W(root, @"state/current-task.json", StateJson("VERIFIED", "CLAUDE_REVIEW", changeId: "CHG-20260830-024"));
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:10:00Z\"}");
    W(root, @"tasks/VERIFICATION_REPORT.md", "VERIFICATION_PASSED\n\n22/22 parts, 8/8 acceptance criteria.");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Review this task in Claude", StringComparison.Ordinal), "VERIFIED: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "CREATE_CLAUDE_REVIEW_PACKAGE", "OPEN_VERIFICATION_REPORT", "OPEN_DETAIL" }), "VERIFIED: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Claude && m.State == StageState.Current), "VERIFIED: claude current", "claude not current");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "VERIFIED: completion disabled until claude passes", "RUN_GOVERNED_COMPLETION enabled");
}

// ---- 9. AWAITING CLAUDE REVIEW (packet ready) ---------------------------------
{
    string root = NewRoot("awaitclaude");
    // AWAIT_CLAUDE under the DB-M07 manifest model: COPY/RECORD unlock only for the
    // CURRENT CLAUDE REVIEW MANIFEST (current-task dbM07 ready stamp for this
    // node/change BOUND to the current DB-M06 verification via verifiedAtUtc ==
    // verification.json verifiedAtUtc + tasks/CLAUDE_REVIEW_PACKAGE.md). A
    // REVIEW_PACKET.md alone is the legacy wrapper and never counts as the current
    // manifest.
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Test Task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-20260830-025\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-025\",\"manifestId\":\"MFT-20260830-025\",\"verifiedAtUtc\":\"2026-08-30T18:15:00Z\"},"
      + "\"selectedAt\":\"2026-08-30T18:15:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:15:00Z\"}");
    W(root, @"tasks/VERIFICATION_REPORT.md", "VERIFICATION_PASSED");
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# CLAUDE REVIEW PACKAGE - CHG-20260830-025\n\nManifest ID: MFT-20260830-025");
    W(root, @"tasks/REVIEW_PACKET.md", "Claude review packet: verification results, changed files, acceptance criteria.");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Review this task in Claude", StringComparison.Ordinal), "AWAIT_CLAUDE: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "COPY_FOR_CLAUDE", "RECORD_CLAUDE_RESULT", "OPEN_REVIEW_PACKET", "OPEN_VERIFICATION_REPORT", "OPEN_DETAIL" }),
        "AWAIT_CLAUDE: buttons", $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE"), "AWAIT_CLAUDE: recreate disabled", "CREATE_CLAUDE_REVIEW_PACKAGE enabled");
}

// ---- 10. CLAUDE FIX REQUIRED --------------------------------------------------
{
    string root = NewRoot("fixreq");
    W(root, @"state/current-task.json", StateJson("VERIFIED", "CLAUDE_REVIEW", changeId: "CHG-20260830-026"));
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"decision\":\"FAIL\",\"dbM09Required\":true,\"reviewedAt\":\"2026-08-30T18:30:00Z\",\"blockingFindings\":[\"Sheet update plan missing row\"],\"residualObservations\":[{\"severity\":\"INFO\",\"blocking\":\"false\",\"subject\":\"Naming\",\"detail\":\"Consider renaming X.\"}]}");
    W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "FAIL\nCLAUDE_FIX_REQUIRED\n\nFindings: sheet update plan missing row.");
    W(root, @"tasks/FIX_CONTEXT.md", "FIX_CONTEXT: address the Claude findings and regenerate the implementation prompt.");
    W(root, @"tasks/REVIEW_PACKET.md", "Review packet.");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(n.Instruction.Contains("Claude found issues", StringComparison.Ordinal), "FIX_REQ: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "COPY_FIX_CONTEXT", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }), "FIX_REQ: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Claude && m.State == StageState.Failed), "FIX_REQ: claude failed", "claude not failed");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.FixLoop && m.State == StageState.Current), "FIX_REQ: fixloop current", "fixloop not current");
    Check(n.Failure is not null && n.Failure.StageKey == "CLAUDE", "FIX_REQ: failure surfaced", n.Failure?.StageKey ?? "none");
    Check(n.ResidualObservationCount == 1, "FIX_REQ: residual counted separately", $"residuals={n.ResidualObservationCount}");
    Check(s.ResidualObservations.Count == 1 && s.ResidualObservations[0].Blocking == false, "FIX_REQ: residual non-blocking parsed",
        $"severity={s.ResidualObservations[0].Severity} blocking={s.ResidualObservations[0].Blocking}");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "FIX_REQ: completion disabled on fix loop", "RUN_GOVERNED_COMPLETION enabled");
}

// ---- 11. CLAUDE PASSED — REAL mode, merge CONFIRMED -> governed completion ----
// DB-GH01: a real Claude PASS never arms completion by itself. Only a CONFIRMED
// human merge + DB-M06 PASS + Claude PASS + preserved roadmap fingerprint unlock it.
{
    string root = NewRoot("claudepass");
    W(root, @"config/devbridge.json", "{\"mode\":\"REAL_NEXUS_DEVELOPMENT\"}");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Test Task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-20260830-027\",\"status\":\"READY_FOR_GOVERNED_COMPLETION\",\"nextAllowedAction\":\"RUN_GOVERNED_COMPLETION\","
      + "\"mode\":\"REAL_NEXUS_DEVELOPMENT\",\"gitLifecycleState\":\"READY_FOR_GOVERNED_COMPLETION\","
      + "\"repositoryStates\":[{\"isGitRepo\":true,\"branch\":\"main\",\"headCommit\":\"abc1234\",\"dirty\":false,\"capturedAt\":\"2026-08-30T18:40:00Z\"}],"
      + "\"selectedAt\":\"2026-08-30T18:40:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-027\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:10:00Z\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-027\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T18:40:00Z\"}");
    W(root, @"state/roadmap-fingerprint.json",
        "{\"before\":{\"value\":\"AAA\",\"sheetCoverage\":\"Master Roadmap\",\"configSource\":\"config/roadmap-protection.json\",\"error\":null}," +
        "\"after\":{\"value\":\"AAA\",\"sheetCoverage\":\"Master Roadmap\",\"configSource\":\"config/roadmap-protection.json\",\"error\":null}}");
    W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "PASS\n\nNo blocking findings.");
    W(root, @"tasks/REVIEW_PACKET.md", "Review packet.");
    var cfg = DevBridgeConfig.Load(root);
    var s11 = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s11);
    Check(n.Instruction.Contains("Run governed completion", StringComparison.Ordinal), "CLAUDE_PASS: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "RUN_GOVERNED_COMPLETION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }), "CLAUDE_PASS: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Completion && m.State == StageState.Current), "CLAUDE_PASS: completion current", "completion not current");
    Check(n.Failure is null, "CLAUDE_PASS: no failure", n.Failure?.Result ?? "none");
    Check(!n.EnabledButtons.Contains("COPY_FIX_CONTEXT"), "CLAUDE_PASS: fix copy disabled", "COPY_FIX_CONTEXT enabled");
    Check(s11.ModeToken == "REAL_NEXUS_DEVELOPMENT" && s11.HumanGitState == HumanGitGateState.ReadyForGovernedCompletion,
        "CLAUDE_PASS: real mode + merge gate surfaced", $"{s11.ModeToken}/{GitLifecycle.ToToken(s11.HumanGitState)}");
}

// ---- 11b. CLAUDE PASSED — TRIAL mode -> TRIAL_CYCLE_SAFE_STOP (no M10, no PR) --
{
    string root = NewRoot("claudepasstrial");
    W(root, @"config/devbridge.json", "{\"mode\":\"TRIAL\"}");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Test Task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-20260830-028b\",\"status\":\"CLAUDE_REVIEW_PASSED_TRIAL\",\"nextAllowedAction\":\"TRIAL_CYCLE_SAFE_STOP\","
      + "\"mode\":\"TRIAL\",\"gitLifecycleState\":\"NOT_APPLICABLE\",\"selectedAt\":\"2026-08-30T18:41:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-028b\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:10:00Z\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-028b\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T18:41:00Z\"}");
    W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "PASS\n\nNo blocking findings.");
    W(root, @"tasks/REVIEW_PACKET.md", "Review packet.");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(s.TrialCycleSafeStop && s.TrialMode, "CLAUDE_PASS_TRIAL: safe-stop flag", $"status={s.Status} next={s.NextAllowedAction}");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "CLAUDE_PASS_TRIAL: completion never armed", EnabledDesc(n.EnabledButtons));
    Check(!n.EnabledButtons.Contains("CREATE_PR"), "CLAUDE_PASS_TRIAL: no human PR gate for trial", EnabledDesc(n.EnabledButtons));
    Check(n.Instruction.Contains("TRIAL_CYCLE_SAFE_STOP", StringComparison.Ordinal), "CLAUDE_PASS_TRIAL: safe-stop instruction", n.Instruction);
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Completion && m.State == StageState.Blocked), "CLAUDE_PASS_TRIAL: completion blocked", "not blocked");
    Check(s.M10Eligibility is not null && s.M10Eligibility.Token == "TRIAL_COMPLETION_NOT_APPLICABLE",
        "CLAUDE_PASS_TRIAL: m10 not applicable", s.M10Eligibility?.Token ?? "null");
}

// ---- 12. COMPLETION WRITTEN ---------------------------------------------------
{
    string root = NewRoot("completed");
    W(root, @"state/current-task.json", StateJson("COMPLETION_WRITTEN", "WORKBOOK_CONSISTENCY_VALIDATION", changeId: "CHG-20260830-028"));
    W(root, @"state/completion.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-028\",\"completedAtUtc\":\"2026-08-30T18:50:00Z\"}");
    W(root, @"tasks/COMPLETION_REPORT.md", "COMPLETION_REPORT\n\nWorkbook rows updated.");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Run workbook consistency validation", StringComparison.Ordinal), "COMPLETION: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "VALIDATE_WORKBOOK", "OPEN_COMPLETION_REPORT", "OPEN_DETAIL" }), "COMPLETION: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.ControlValidation && m.State == StageState.Current), "COMPLETION: validation current", "validation not current");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "COMPLETION: completion disabled (already written)", "RUN_GOVERNED_COMPLETION enabled");
}

// ---- 13. CONTROL VALIDATION FAILED --------------------------------------------
{
    string root = NewRoot("consfail");
    W(root, @"state/current-task.json", StateJson("CONTROL_VALIDATION_FAILED", "RESOLVE_CONSISTENCY", changeId: "CHG-20260830-029"));
    W(root, @"state/workbook-consistency.json", "{\"nodeId\":\"WI-07-0.2.4\",\"controlValidationResult\":\"FAIL\",\"validatedAtUtc\":\"2026-08-30T19:00:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Resolve workbook-control inconsistencies", StringComparison.Ordinal), "CONS_FAIL: instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "OPEN_CONSISTENCY_REPORT", "OPEN_DETAIL" }), "CONS_FAIL: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.ControlValidation && m.State == StageState.Failed), "CONS_FAIL: validation failed", "validation not failed");
    Check(n.Failure is not null && n.Failure.StageKey == "CONTROL_VALIDATION", "CONS_FAIL: failure surfaced", n.Failure?.StageKey ?? "none");
    Check(!n.EnabledButtons.Contains("START_NEXT_CYCLE"), "CONS_FAIL: next cycle disabled", "START_NEXT_CYCLE enabled");
    Check(!n.EnabledButtons.Contains("VALIDATE_WORKBOOK"), "CONS_FAIL: validate disabled (needs backend procedure)", "VALIDATE_WORKBOOK enabled");
}

// ---- 14. UNKNOWN STATE -> safe fallback (never guess) -------------------------
{
    string root = NewRoot("unknown");
    W(root, @"state/current-task.json", StateJson("SOME_UNKNOWN_STATUS", "WEIRD_ACTION", changeId: "CHG-20260830-030"));
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("not mapped", StringComparison.Ordinal), "UNKNOWN: fallback instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "OPEN_DETAIL" }), "UNKNOWN: only detail enabled", $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(n.Failure is null, "UNKNOWN: no fabricated failure", n.Failure?.Result ?? "none");
}

// ---- 15. STALE-EVIDENCE HIJACK (parallel-lane regression lock) --------------
// A fresh PREFLIGHTED record (changeId still null — the LIVE parallel-lane
// scenario) must NOT be hijacked by the PREVIOUS cycle's leftover evidence
// (nodeId WI-07-0.2.3 / changeId CHG-20260830-016): no completion prompt, no
// Claude-pass completion, no verification short-circuit. Only RESERVE is governed.
{
    string root = NewRoot("hijack");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Concurrency, locking and atomic writes\",\"nodeType\":\"WorkItem\","
      + "\"phase\":\"P0\",\"layer\":\"App\",\"changeId\":\"\",\"status\":\"PREFLIGHTED\","
      + "\"nextAllowedAction\":\"RESERVE\",\"preflightVerdict\":\"CLEAR\",\"selectedAt\":\"2026-08-30T17:04:09Z\"}");
    W(root, @"state/preflight.json", "{\"verdict\":\"CLEAR\",\"generatedAtUtc\":\"2026-08-30T17:05:00Z\"}");
    // Stale evidence from the prior cycle (WI-07-0.2.3 / CHG-20260830-016):
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T16:48:00Z\"}");
    W(root, @"state/completion.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"completedAtUtc\":\"2026-08-30T16:50:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T16:45:00Z\"}");
    W(root, @"state/workbook-consistency.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"controlValidationResult\":\"PASS\",\"validatedAtUtc\":\"2026-08-30T16:52:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(n.Instruction.Contains("Reserve this task", StringComparison.Ordinal), "HIJACK: instruction stays reserve", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "RESERVE_TASK", "OPEN_PREFLIGHT_REPORT", "OPEN_DETAIL" }), "HIJACK: only reserve/open enabled",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "HIJACK: prior Claude PASS must not arm completion", "RUN_GOVERNED_COMPLETION enabled");
    Check(!n.EnabledButtons.Contains("VALIDATE_WORKBOOK"), "HIJACK: prior completion must not arm validation", "VALIDATE_WORKBOOK enabled");
    Check(!n.EnabledButtons.Contains("RUN_VERIFICATION"), "HIJACK: prior verification must not short-circuit", "RUN_VERIFICATION enabled");
    Check(n.Failure is null, "HIJACK: no failure fabricated from stale evidence", n.Failure?.Result ?? "none");
    Check(n.ResidualObservationCount == 0, "HIJACK: no residual from prior cycle", $"residuals={n.ResidualObservationCount}");
}

// ==================================================================== history
{
    string root = NewRoot("history");
    string successDir = Path.Combine(root, "logs", "tasks", "WI-07-0.2.4", "CHG-20260830-031");
    Directory.CreateDirectory(successDir);
    W(successDir, "current-task.json", StateJson("COMPLETION_WRITTEN", "WORKBOOK_CONSISTENCY_VALIDATION", changeId: "CHG-20260830-031", name: "Excel persistence adapter"));
    W(successDir, "completion.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-031\",\"completedAtUtc\":\"2026-08-30T20:00:00Z\",\"name\":\"Excel persistence adapter\"}");
    W(successDir, "verification.json", "{\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T19:40:00Z\"}");
    W(successDir, "claude-review.json", "{\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T19:45:00Z\"}");
    W(successDir, "build-result.json", "{\"projects\":[\"DevBridge.Engine\",\"DevBridge.UI\",\"DevBridge.Tests\"],\"warnings\":0,\"errors\":0}");
    W(successDir, "test-result.json", "{\"testRun\":{\"passed\":199,\"failed\":0,\"total\":199},\"harnessRun\":{\"checksPassed\":32}}");
    W(successDir, "FIX_CONTEXT.md", "FIX_CONTEXT\nFIX_CONTEXT\nSome fix text.");
    W(successDir, "VERIFICATION_REPORT.md", "VERIFICATION_PASSED");
    W(successDir, "REVIEW_PACKET.md", "packet");
    W(successDir, "COMPLETION_REPORT.md", "done");

    string failDir = Path.Combine(root, "logs", "tasks", "WI-07-0.2.5", "CHG-20260830-032");
    Directory.CreateDirectory(failDir);
    W(failDir, "current-task.json", StateJson("VERIFIED", "CLAUDE_REVIEW", changeId: "CHG-20260830-032", name: "Failed attempt"));
    W(failDir, "verification.json", "{\"primaryResult\":\"VERIFICATION_FAILED\",\"verifiedAtUtc\":\"2026-08-30T18:20:00Z\"}");
    W(failDir, "VERIFICATION_REPORT.md", "VERIFICATION_FAILED\n\nSome failures.");

    var cfg = DevBridgeConfig.Load(root);
    var history = TaskHistoryService.Scan(cfg);
    Check(history.Count == 2, "HISTORY: two tasks scanned", $"count={history.Count}");
    var ok = history.FirstOrDefault(h => h.ChangeId == "CHG-20260830-031");
    Check(ok is not null, "HISTORY: success task found", "missing");
    if (ok is not null)
    {
        Check(ok.Result == "SUCCESS", "HISTORY: success result", ok.Result);
        Check(ok.BuildProjects == 3, "HISTORY: build projects", $"{ok.BuildProjects}");
        Check(ok.TestsPassed == 199 && ok.TestsTotal == 199, "HISTORY: test numbers", $"{ok.TestsPassed}/{ok.TestsTotal}");
        Check(ok.HarnessChecks == 32, "HISTORY: harness checks", $"{ok.HarnessChecks}");
        Check(ok.VerificationResult == "VERIFICATION_PASSED", "HISTORY: verification result", ok.VerificationResult ?? "null");
        Check(ok.ClaudeResult == "PASS", "HISTORY: claude result", ok.ClaudeResult ?? "null");
        Check(ok.WorkbookResult == "FAIL" || ok.WorkbookResult == null, "HISTORY: no workbook evidence => unset", ok.WorkbookResult ?? "null");
    }
    var bad = history.FirstOrDefault(h => h.ChangeId == "CHG-20260830-032");
    Check(bad is not null, "HISTORY: failed task found", "missing");
    if (bad is not null)
    {
        Check(bad.Result == "FAILED", "HISTORY: failed attempt never hidden", bad.Result);
        Check(bad.VerificationResult == "VERIFICATION_FAILED", "HISTORY: failed verification shown", bad.VerificationResult ?? "null");
    }

    // Detail listing: missing artifacts => NOT APPLICABLE
    var detail = TaskHistoryService.Detail(successDir);
    Check(detail.Count == 13, "DETAIL: 13 stages listed", $"count={detail.Count}");
    var pre = detail.First(d => d.Stage == "PREFLIGHT_REPORT");
    Check(!pre.Present, "DETAIL: missing preflight NOT APPLICABLE", $"present={pre.Present}");
    var handoff = detail.First(d => d.Stage == "CHATGPT_HANDOFF");
    Check(!handoff.Present, "DETAIL: missing handoff NOT APPLICABLE", $"present={handoff.Present}");
    var comp = detail.First(d => d.Stage == "COMPLETION_REPORT");
    Check(comp.Present && (comp.Summary ?? "").Contains("done"), "DETAIL: completion present + summary", comp.Summary ?? "null");
}

// ==================================================================== control health
{
    string root = NewRoot("health");
    W(root, @"state/workbook-consistency.json", "{\"controlValidationResult\":\"PASS\",\"validatedAtUtc\":\"2026-08-30T19:00:00Z\",\"knownMirrorGaps\":[\"Development Guide v1.2 not mirrored to repo docs\"]}");
    W(root, @"state/db-m11-extraction.txt",
        "DB-M11 workbook consistency snapshot 2026-08-30\n" +
        "AC classified: open=22 terminal=32\n" +
        "OPEN DECISIONS rows=7\n" +
        "AUDIT FINDINGS rows=21\n" +
        "DEPENDENCIES & BLOCKERS rows=14\n");
    var cfg = DevBridgeConfig.Load(root);
    var h = ControlHealthService.Evaluate(cfg);
    Check(h.WorkbookState == "ERROR", "HEALTH: missing workbook => ERROR (read-only probe, never created)", h.WorkbookState);
    Check(h.LastConsistencyResult == "PASS", "HEALTH: last consistency PASS", h.LastConsistencyResult ?? "null");
    Check(h.LastConsistencyAt is not null, "HEALTH: validated at present", h.LastConsistencyAt ?? "null");
    Check(h.OpenActiveChanges == 22, "HEALTH: open active changes", $"{h.OpenActiveChanges}");
    Check(h.OpenBlockers == 9, "HEALTH: open blockers (14-5)", $"{h.OpenBlockers}");
    Check(h.OpenDecisions == 2, "HEALTH: open decisions (7-5)", $"{h.OpenDecisions}");
    Check(h.OpenAuditFindings == 16, "HEALTH: open audit findings (21-5)", $"{h.OpenAuditFindings}");
    Check(h.HasKnownMirrorGap && h.KnownMirrorGap is not null, "HEALTH: known mirror gap surfaced", h.KnownMirrorGap ?? "null");
}

// ==================================================================== active changes (parallel view)
{
    string root = NewRoot("active");
    W(root, @"state/db-m11-extraction.txt",
        "DB-M11 workbook consistency snapshot 2026-08-30\n" +
        "ACTIVE CHANGES rows=79\n" +
        "  row 79: A=[CHG-20260830-016] C=[WI-07-0.2.3 (Excel persistence adapter)] L=[Completed -- WI-07-0.2.3] U=[2026-08-30T16:46:12Z] W=[1.0] AC=[Governed Multi-Sheet Completion] AD=[Pass -- DB-M10 post-write verification confirmed workbook write.] -> classify=Terminal\n" +
        "  row 78: A=[CHG-20260830-015] C=[WI-07-0.2.2] L=[Clean implementation verified] U=[46264] W=[1.0] AC=[Implementation Verification] AD=[Pass -- clean.] -> classify=Open\n" +
        "AC rows with ChangeID CHG-20260830-016: [79]\n" +
        "  row 25: A=[CHG-20260825-002] L-lead=[Completed]\n" +
        "  row 26: A=[CHG-20260825-003] L-lead=[Blocked -- environment S]\n");
    var cfg = DevBridgeConfig.Load(root);
    var (rows, open, term, ts) = ActiveChangesSnapshot.Load(cfg);
    Check(rows.Count == 4, "PARALLEL: four change rows", $"count={rows.Count}");
    Check(open == 2 && term == 2, "PARALLEL: open/terminal counts", $"open={open} term={term}");
    var done = rows.First(r => r.ChangeId == "CHG-20260830-016");
    Check(done.Classification == "Terminal", "PARALLEL: explicit classify=Terminal honored", done.Classification);
    Check(done.NodeContext.Contains("WI-07-0.2.3", StringComparison.Ordinal), "PARALLEL: node context captured", done.NodeContext);
    Check(done.Worker is not null && done.Activity is not null && done.Verification is not null, "PARALLEL: rich detail merged",
        $"worker={done.Worker} activity={done.Activity} verification={done.Verification}");
    var llead = rows.First(r => r.ChangeId == "CHG-20260825-002");
    Check(llead.Classification == "Terminal", "PARALLEL: leading-keyword rule (Completed=>Terminal)", llead.Classification);
    var blocked = rows.First(r => r.ChangeId == "CHG-20260825-003");
    Check(blocked.Classification == "Open", "PARALLEL: Blocked not auto-terminal", blocked.Classification);
}

// ==================================================================== DB-M12.1 operator command layer

// ---- C. command catalog integrity ------------------------------------------
{
    Check(OperatorCommandCatalog.All.Count == 32, "CATALOG: 32 commands", $"{OperatorCommandCatalog.All.Count}");
    var ids = OperatorCommandCatalog.All.Values.Select(c => c.CommandId).ToArray();
    Check(ids.Distinct(StringComparer.OrdinalIgnoreCase).Count() == ids.Length, "CATALOG: unique ids", "duplicate id");
    Check(OperatorCommandCatalog.Get("START_PREFLIGHT") is not null, "CATALOG: known id resolves", "null");
    Check(OperatorCommandCatalog.Get("BOGUS") is null, "CATALOG: unknown id -> null", "resolved");
    var autoScripts = OperatorCommandCatalog.All.Values.Where(c => c.Kind == OperatorCommandKind.Script).ToList();
    Check(autoScripts.Count == 16, "CATALOG: 16 script-backed", $"{autoScripts.Count}");
    Check(autoScripts.All(c => c.Scripts.Length > 0), "CATALOG: every script command names a backend script",
        string.Join(",", autoScripts.Select(c => c.CommandId)));
    // DB-M12.2: RUN_GOVERNED_COMPLETION and RECORD_CLAUDE_RESULT deliberately leave
    // ResultingExpectedState empty (the transition is mode/condition-derived) and the
    // three observation/advisory commands declare no transition. Everything else
    // declares the lifecycle state it must produce.
    string[] emptyTransition = { "RUN_GOVERNED_COMPLETION", "RECORD_CLAUDE_RESULT", "CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE", "REFRESH_GIT_GATE_STATE", "GET_CURRENT_LIFECYCLE_STATE" };
    Check(autoScripts.Where(c => c.ResultingExpectedState.Length == 0).All(c => emptyTransition.Contains(c.CommandId, StringComparer.Ordinal)),
        "CATALOG: empty-transition script commands are the documented mode-derived/observation set",
        string.Join(",", autoScripts.Where(c => c.ResultingExpectedState.Length == 0).Select(c => c.CommandId)));
    Check(autoScripts.All(c => emptyTransition.Contains(c.CommandId, StringComparer.Ordinal) || c.ResultingExpectedState.Length > 0),
        "CATALOG: script commands either declare a transition or are documented observation", "mixed");
    // DB-M12.2: the 9 reusable lifecycle commands are all Script commands.
    foreach (var id in new[] { "RUN_VERIFICATION", "CREATE_CLAUDE_REVIEW_PACKAGE", "RECORD_CLAUDE_RESULT", "VALIDATE_WORKBOOK", "RUN_GOVERNED_COMPLETION",
        "CREATE_CORRECTION_CONTEXT", "CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE", "REFRESH_GIT_GATE_STATE", "GET_CURRENT_LIFECYCLE_STATE" })
        Check(OperatorCommandCatalog.Get(id)?.Kind == OperatorCommandKind.Script, $"CATALOG: {id} is a script command", OperatorCommandCatalog.Get(id)?.Kind.ToString() ?? "missing");
    var guided = OperatorCommandCatalog.All.Values.Where(c => c.Kind == OperatorCommandKind.GuidedManual).ToList();
    Check(guided.Count == 5, "CATALOG: exactly 5 guided/manual", $"{guided.Count}");
    Check(guided.All(c => !string.IsNullOrWhiteSpace(c.GuidedReason)), "CATALOG: guided commands record a reason",
        string.Join(",", guided.Select(c => c.CommandId)));
    // DB-GH01: the 5 human-gated guidance commands exist, are guided/manual, and gate on human-Git states.
    foreach (var (id, states) in new[]
    {
        ("CREATE_PR", new[] { "CLAUDE_REVIEW_PASSED_REAL", "AWAITING_HUMAN_PR" }),
        ("REVIEW_PR", new[] { "PR_OPEN", "AWAITING_HUMAN_REVIEW" }),
        ("MERGE_PR", new[] { "AWAITING_HUMAN_MERGE" }),
        ("REVIEW_GOVERNANCE_ISSUE", new[] { "GOVERNANCE_ISSUE" }),
        ("RESTORE_REAL_NEXUS_BASELINE", new[] { "READY_FOR_GOVERNED_COMPLETION" }),
    })
    {
        var c = OperatorCommandCatalog.Get(id);
        Check(c is not null && c.Kind == OperatorCommandKind.GuidedManual && !string.IsNullOrWhiteSpace(c.GuidedReason),
            $"CATALOG: {id} is guided/manual with a reason", c?.GuidedReason ?? "missing");
        Check(c is not null && c.RequiredStates.SequenceEqual(states, StringComparer.Ordinal),
            $"CATALOG: {id} gates on human-Git states", string.Join("|", c?.RequiredStates ?? Array.Empty<string>()));
    }
    Check(OperatorCommandCatalog.Get("RESTORE_REAL_NEXUS_BASELINE")!.GuidedReason!.Contains("git reset --hard", StringComparison.OrdinalIgnoreCase),
        "CATALOG: restore baseline never auto-runs destructive restore",
        OperatorCommandCatalog.Get("RESTORE_REAL_NEXUS_BASELINE")!.GuidedReason!);
    var clip = OperatorCommandCatalog.All.Values.Where(c => c.Kind == OperatorCommandKind.Clipboard).ToList();
    Check(clip.Count == 3 && clip.All(c => !string.IsNullOrWhiteSpace(c.ArtifactFile)), "CATALOG: clipboard commands have artifact files", $"{clip.Count}");
    Check(OperatorCommandCatalog.Get("RESERVE_TASK")!.WritesWorkbook && OperatorCommandCatalog.Get("RESERVE_TASK")!.RequiresUserInput,
        "CATALOG: reserve is an operator-confirmed workbook write", "not flagged");
    Check(!OperatorCommandCatalog.Get("START_PREFLIGHT")!.WritesWorkbook, "CATALOG: preflight is read-only", "flagged write");
    Check(OperatorCommandCatalog.Get("RECORD_CLAUDE_RESULT")!.RequiresUserInput, "CATALOG: claude record requires operator input", "not flagged");
}

// ---- P. script outcome marker parsing (Part 7: exit code is never trusted) --
{
    var reserved = ScriptOutcomeParser.Parse("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: True");
    Check(reserved.OutcomeToken == "RESERVED" && reserved.ResultPass == true && !reserved.IsGovernedStop, "PARSE: reserved", $"{reserved}");
    var stop = ScriptOutcomeParser.Parse("DB03_OUTCOME: STOP_NO_NEXT_TASK");
    Check(stop.IsGovernedStop, "PARSE: STOP_ token is a governed stop", $"{stop.OutcomeToken}");
    var verdict = ScriptOutcomeParser.Parse("PREFLIGHT VERDICT: CLEAR");
    Check(verdict.Verdict == "CLEAR", "PARSE: preflight verdict", $"{verdict.Verdict}");
    var reused = ScriptOutcomeParser.Parse("DB04_OUTCOME: REUSED");
    Check(reused.OutcomeToken == "REUSED" && !reused.IsGovernedStop, "PARSE: REUSED is not a stop", $"{reused.OutcomeToken}");
    var passFalse = ScriptOutcomeParser.Parse("DB04_RESULT_PASS: False\nDB04_OUTCOME: RESERVED");
    Check(passFalse.ResultPass == false, "PARSE: result_pass false", $"{passFalse.ResultPass}");
}

// ---- S. command execution via a faked backend script ------------------------
// S1: START_PREFLIGHT success (NO_TASK -> PREFLIGHTED)
{
    string root = NewRoot("cmd-preflight-ok");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(
        ("Get-NextTask.ps1", _ => { WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-041"); return Ok("DB03_OUTCOME: TASK_SELECTED\nDB03_RESULT_PASS: True"); }),
        ("Test-DevelopmentPreflight.ps1", _ => { W(root, @"state/preflight.json", "{\"verdict\":\"CLEAR\"}"); W(root, @"tasks/PREFLIGHT_REPORT.md", "PREFLIGHT VERDICT: CLEAR"); return Ok("PREFLIGHT VERDICT: CLEAR\nDB03_RESULT_PASS: True"); }));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("START_PREFLIGHT")!, fake);
    Check(r.Result == CommandResultCode.SUCCESS, "CMD-PREFLIGHT: success", r.Result.ToString());
    Check(r.PreviousState == "NO_TASK" && r.NewState == "PREFLIGHTED", "CMD-PREFLIGHT: transition", $"{r.PreviousState}->{r.NewState}");
    Check(r.NextAllowedAction == "RESERVE", "CMD-PREFLIGHT: next allowed refreshed", r.NextAllowedAction);
    Check(fake.Invoked.Count == 2, "CMD-PREFLIGHT: both scripts invoked", string.Join(",", fake.Invoked));
    Check(r.GeneratedArtifacts.Any(p => p.EndsWith("PREFLIGHT_REPORT.md", StringComparison.OrdinalIgnoreCase)), "CMD-PREFLIGHT: artifact discovered",
        string.Join("|", r.GeneratedArtifacts));
}

// S2: governed STOP stops the sequence and blocks (no state forced)
{
    string root = NewRoot("cmd-preflight-stop");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Get-NextTask.ps1", _ => Ok("DB03_OUTCOME: STOP_NO_NEXT_TASK\nDB03_RESULT_PASS: False")));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("START_PREFLIGHT")!, fake);
    Check(r.Result == CommandResultCode.BLOCKED, "CMD-STOP: blocked", r.Result.ToString());
    Check(r.Message.Contains("STOP_NO_NEXT_TASK", StringComparison.Ordinal), "CMD-STOP: stop token surfaced", r.Message);
    Check(fake.Invoked.Count == 1, "CMD-STOP: second script never invoked", string.Join(",", fake.Invoked));
    Check(r.NewState == "NO_TASK", "CMD-STOP: no state forced", r.NewState);
}

// S3: preflight reports RESULT_PASS: False -> BLOCKED despite exit 0
{
    string root = NewRoot("cmd-preflight-fail");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(
        ("Get-NextTask.ps1", _ => { WriteState(root, "PREFLIGHTED", "RESOLVE_PREFLIGHT", "CHG-20260830-042", verdict: "FAIL"); return Ok("DB03_OUTCOME: TASK_SELECTED"); }),
        ("Test-DevelopmentPreflight.ps1", _ => Ok("PREFLIGHT VERDICT: FAIL\nDB03_RESULT_PASS: False")));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("START_PREFLIGHT")!, fake);
    Check(r.Result == CommandResultCode.BLOCKED, "CMD-PREFLIGHT-FAIL: blocked on result_pass false", r.Result.ToString());
    Check(r.Message.Contains("DB*_RESULT_PASS: False", StringComparison.Ordinal), "CMD-PREFLIGHT-FAIL: reason shown", r.Message);
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(!n.EnabledButtons.Contains("RESERVE_TASK"), "CMD-PREFLIGHT-FAIL: reserve stays disabled", EnabledDesc(n.EnabledButtons));
}

// S4: RESERVE_TASK success (PREFLIGHTED -> RESERVED)
{
    string root = NewRoot("cmd-reserve-ok");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-043");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ =>
    {
        WriteState(root, "RESERVED", "CHATGPT_HANDOFF", "CHG-20260830-043");
        return Ok("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: True");
    }));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.SUCCESS, "CMD-RESERVE: success", r.Result.ToString());
    Check(r.PreviousState == "PREFLIGHTED" && r.NewState == "RESERVED", "CMD-RESERVE: transition", $"{r.PreviousState}->{r.NewState}");
}

// S5: idempotent reuse (DB04_OUTCOME: REUSED) still succeeds on the refreshed state
{
    string root = NewRoot("cmd-reserve-reused");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-044");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ =>
    {
        WriteState(root, "RESERVED", "CHATGPT_HANDOFF", "CHG-20260830-044");
        return Ok("DB04_OUTCOME: REUSED\nDB04_RESULT_PASS: True");
    }));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.SUCCESS && r.NewState == "RESERVED", "CMD-REUSED: success on refreshed state", r.Result.ToString());
}

// S6: state gate blocks a command that cannot run from the current state
{
    string root = NewRoot("cmd-reserve-gate");
    WriteState(root, "RESERVED", "CHATGPT_HANDOFF", "CHG-20260830-045");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ => Ok("DB04_OUTCOME: RESERVED")));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.BLOCKED, "CMD-GATE: blocked", r.Result.ToString());
    Check(r.Message.Contains("from state 'RESERVED'", StringComparison.Ordinal), "CMD-GATE: required states in message", r.Message);
    Check(fake.Invoked.Count == 0, "CMD-GATE: no script invoked", $"{fake.Invoked.Count}");
}

// S7: BACKEND_STATE_MISMATCH — script exits 0 but the refreshed state did not move
{
    string root = NewRoot("cmd-reserve-mismatch");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-046");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ => Ok("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: True"))); // claims success, writes nothing
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.FAILED, "CMD-MISMATCH: failed", r.Result.ToString());
    Check(r.IsBackendStateMismatch, "CMD-MISMATCH: flagged mismatch", $"{r.IsBackendStateMismatch}");
    Check(r.Message.StartsWith("BACKEND_STATE_MISMATCH", StringComparison.Ordinal), "CMD-MISMATCH: message prefix", r.Message);
    Check(r.StateValidationLabel == "BACKEND_STATE_MISMATCH", "CMD-MISMATCH: validation label", r.StateValidationLabel);
}

// S8: nonzero exit -> FAILED (never assumed success)
{
    string root = NewRoot("cmd-reserve-exit");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-047");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ => new ScriptRunOutcome(false, 3, "boom\nDB04_RESULT_PASS: False", "", TimeSpan.FromMilliseconds(10), false)));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.FAILED, "CMD-EXIT: failed", r.Result.ToString());
    Check(r.Message.Contains("exit code 3", StringComparison.Ordinal), "CMD-EXIT: exit code surfaced", r.Message);
}

// S9: timeout -> BLOCKED
{
    string root = NewRoot("cmd-reserve-timeout");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-048");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ => ScriptRunOutcome.Timeout(100)));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.BLOCKED, "CMD-TIMEOUT: blocked", r.Result.ToString());
    Check(r.Message.Contains("timed out", StringComparison.Ordinal), "CMD-TIMEOUT: message", r.Message);
}

// S10: exit 0 but DB*_RESULT_PASS: False -> BLOCKED
{
    string root = NewRoot("cmd-reserve-nopass");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-049");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ => Ok("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: False")));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.BLOCKED, "CMD-NOPASS: blocked", r.Result.ToString());
}

// S11: CREATE_CHATGPT_HANDOFF success (RESERVED -> AWAITING_CHATGPT_PROMPT)
{
    string root = NewRoot("cmd-handoff-ok");
    WriteState(root, "RESERVED", "CHATGPT_HANDOFF", "CHG-20260830-050");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("New-ChatGptHandoff.ps1", _ =>
    {
        WriteState(root, "AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", "CHG-20260830-050");
        W(root, @"tasks/CHATGPT_HANDOFF.md", "handoff");
        W(root, @"tasks/DEEPSEEK_PROMPT.md", "# Awaiting ChatGPT Prompt\n");
        return Ok("DB05_OUTCOME: AWAITING_CHATGPT_PROMPT\nDB05_RESULT_PASS: True");
    }));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CREATE_CHATGPT_HANDOFF")!, fake);
    Check(r.Result == CommandResultCode.SUCCESS, "CMD-HANDOFF: success", r.Result.ToString());
    Check(r.NewState == "AWAITING_CHATGPT_PROMPT", "CMD-HANDOFF: new state", r.NewState);
    Check(r.GeneratedArtifacts.Any(p => p.EndsWith("CHATGPT_HANDOFF.md", StringComparison.OrdinalIgnoreCase)), "CMD-HANDOFF: artifact discovered",
        string.Join("|", r.GeneratedArtifacts));
}

// S12: DB-GH01 human-gated commands NEVER fake an automatic run (Part 5).
// The DB-M12.2 reusable lifecycle commands (RUN_VERIFICATION, CREATE_CLAUDE_REVIEW_PACKAGE,
// RECORD_CLAUDE_RESULT, VALIDATE_WORKBOOK, RUN_GOVERNED_COMPLETION, CREATE_CORRECTION_CONTEXT,
// CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE, REFRESH_GIT_GATE_STATE, GET_CURRENT_LIFECYCLE_STATE)
// are Script commands now and are covered by the DB-M12.2 test block; only the 5
// human-gated guidance commands remain GuidedManual.
foreach (var id in new[] { "CREATE_PR", "REVIEW_PR", "MERGE_PR", "REVIEW_GOVERNANCE_ISSUE", "RESTORE_REAL_NEXUS_BASELINE" })
{
    string root = NewRoot("cmd-guided-" + id.ToLowerInvariant());
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner();
    var cmd = OperatorCommandCatalog.Get(id)!;
    var r = OperatorCommandService.Execute(cfg, cmd, fake);
    Check(r.Result == CommandResultCode.MANUAL_ACTION_REQUIRED, $"GUIDED:{id}: manual action required", r.Result.ToString());
    Check(fake.Invoked.Count == 0, $"GUIDED:{id}: no script invoked", $"{fake.Invoked.Count}");
    Check(r.Message.Contains("Manual action required", StringComparison.Ordinal), $"GUIDED:{id}: reason surfaced", r.Message);
}

// S13: navigation/clipboard are UI actions — the service never runs them
{
    string root = NewRoot("cmd-nav");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner();
    var nav = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("OPEN_DETAIL")!, fake);
    Check(nav.Result == CommandResultCode.MANUAL_ACTION_REQUIRED, "CMD-NAV: service does not execute navigation", nav.Result.ToString());
    var clip = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("COPY_FOR_CHATGPT")!, fake);
    Check(clip.Result == CommandResultCode.MANUAL_ACTION_REQUIRED, "CMD-CLIP: service does not execute clipboard", clip.Result.ToString());
    Check(fake.Invoked.Count == 0, "CMD-NAV: no script invoked", $"{fake.Invoked.Count}");
}

// ---- C. Claude evidence entry (Part 10) -------------------------------------
// C1: PASS (trial) records both evidence files with the TRIAL route; the engine
// derives TRIAL_CYCLE_SAFE_STOP and NEVER arms governed completion for trial evidence.
{
    string root = NewRoot("claude-pass-record");
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-051");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:10:00Z\"}");
    W(root, @"tasks/VERIFICATION_REPORT.md", "VERIFICATION_PASSED");
    W(root, @"tasks/REVIEW_PACKET.md", "packet");
    var cfg = DevBridgeConfig.Load(root);
    var rec = ClaudeResultEvidence.Record(cfg, new ClaudeResultEntry(ClaudeReviewDecision.Pass, "Looks good — merge it.", "WI-07-0.2.4", "CHG-20260830-051", "Test Task", TrialMode: true));
    Check(rec.Ok, "CLAUDE-PASS: recorded", rec.Message);
    var md = File.ReadAllText(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_RESULT.md"));
    Check(md.StartsWith("PASS", StringComparison.Ordinal), "CLAUDE-PASS: md decision", md.Trim());
    Check(md.Contains("Looks good — merge it.", StringComparison.Ordinal), "CLAUDE-PASS: review text preserved verbatim", "text missing");
    Check(!md.Contains("CLAUDE_FIX_REQUIRED", StringComparison.Ordinal), "CLAUDE-PASS: no fix marker", "fix marker present");
    using var c1json = JsonDocument.Parse(File.ReadAllText(Path.Combine(cfg.StateDir, "claude-review.json")));
    Check(c1json.RootElement.GetProperty("trialMode").GetBoolean() && c1json.RootElement.GetProperty("routeLifecycleState").GetString() == "CLAUDE_REVIEW_PASSED_TRIAL",
        "CLAUDE-PASS: json trial route", c1json.RootElement.GetProperty("routeLifecycleState").GetString() ?? "null");
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "CLAUDE-PASS: trial never arms governed completion", EnabledDesc(n.EnabledButtons));
    Check(n.Instruction.Contains("TRIAL", StringComparison.OrdinalIgnoreCase), "CLAUDE-PASS: trial-stop instruction", n.Instruction);
    Check(!n.EnabledButtons.Contains("COPY_FIX_CONTEXT"), "CLAUDE-PASS: fix context disabled", EnabledDesc(n.EnabledButtons));
}

// C2: FIX REQUIRED marks CLAUDE_FIX_REQUIRED; engine arms the fix loop, never completion
{
    string root = NewRoot("claude-fix-record");
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-052");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-08-30T18:10:00Z\"}");
    W(root, @"tasks/VERIFICATION_REPORT.md", "VERIFICATION_PASSED");
    W(root, @"tasks/REVIEW_PACKET.md", "packet");
    var cfg = DevBridgeConfig.Load(root);
    var rec = ClaudeResultEvidence.Record(cfg, new ClaudeResultEntry(ClaudeReviewDecision.Fix, "Row 7 of the sheet update plan is missing.", "WI-07-0.2.4", "CHG-20260830-052", "Test Task"));
    Check(rec.Ok, "CLAUDE-FIX: recorded", rec.Message);
    var md = File.ReadAllText(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_RESULT.md"));
    Check(md.Contains("CLAUDE_FIX_REQUIRED", StringComparison.Ordinal), "CLAUDE-FIX: fix marker present", "missing");
    Check(md.Contains("Row 7 of the sheet update plan is missing.", StringComparison.Ordinal), "CLAUDE-FIX: review text preserved", "text missing");
    var json = JsonSerializer.Deserialize<JsonDocument>(File.ReadAllText(Path.Combine(cfg.StateDir, "claude-review.json")));
    Check(json is not null && json.RootElement.GetProperty("decision").GetString() == "FIX", "CLAUDE-FIX: json decision FIX",
        json?.RootElement.GetProperty("decision").GetString() ?? "null");
    Check(json is not null && json.RootElement.GetProperty("dbM09Required").GetBoolean(), "CLAUDE-FIX: dbM09Required true", "false");
    Check(json is not null && json.RootElement.GetProperty("reviewText").GetString()!.Contains("Row 7", StringComparison.Ordinal), "CLAUDE-FIX: json text preserved", "text missing");
    var n = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "CLAUDE-FIX: completion disabled on fix loop", EnabledDesc(n.EnabledButtons));
    Check(n.Instruction.Contains("Claude found issues", StringComparison.Ordinal), "CLAUDE-FIX: fix-loop instruction", n.Instruction);
}

// ---- T. result text + clipboard status (Parts 11/12) ------------------------
{
    var many = string.Join("\n", Enumerable.Range(1, 20).Select(i => $"line {i}"));
    var c = CommandResultText.Compact(many);
    Check(c.Split('\n').Length == 12, "COMPACT: trimmed to 12 lines", $"{c.Split('\n').Length}");
    Check(c.StartsWith("line 9", StringComparison.Ordinal), "COMPACT: keeps the tail", c[..16]);
    Check(CommandResultText.Compact("") == "(no output)", "COMPACT: empty marker", CommandResultText.Compact(""));
    Check(CommandResultText.Compact("only one") == "only one", "COMPACT: short unchanged", CommandResultText.Compact("only one"));
    Check(!CommandResultText.Compact(many).StartsWith("line 1", StringComparison.Ordinal), "COMPACT: head dropped", "head kept");
}
{
    var ready = ClipboardStatusMapper.StatusFor(true, "Ready.");
    Check(ready.Kind == ClipboardStatusKind.ReadyToCopy && ready.Label == "READY TO COPY", "CLIP: ready to copy", ready.Label);
    var miss = ClipboardStatusMapper.StatusFor(false, "missing");
    Check(miss.Kind == ClipboardStatusKind.ArtifactMissing && miss.Label == "ARTIFACT MISSING", "CLIP: artifact missing", miss.Label);
    Check(ClipboardStatusMapper.NotApplicable().Kind == ClipboardStatusKind.NotApplicable, "CLIP: not applicable", ClipboardStatusMapper.NotApplicable().Kind.ToString());
    Check(ClipboardStatusInfo.ForResult(true, "copied").Kind == ClipboardStatusKind.Copied, "CLIP: copied", ClipboardStatusInfo.ForResult(true, "copied").Kind.ToString());
    Check(ClipboardStatusInfo.ForResult(false, "err").Kind == ClipboardStatusKind.Error, "CLIP: error", ClipboardStatusInfo.ForResult(false, "err").Kind.ToString());
}

// ---- ST. stale-cycle protection at the command layer (Part 15) --------------
// A fresh PREFLIGHTED record with prior-cycle evidence present must neither arm
// completion nor let a command validate against a stale transition.
{
    string root = NewRoot("cmd-stale");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Concurrency locking\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\",\"changeId\":\"\",\"status\":\"PREFLIGHTED\",\"nextAllowedAction\":\"RESERVE\",\"preflightVerdict\":\"CLEAR\",\"selectedAt\":\"2026-08-30T17:04:09Z\"}");
    W(root, @"state/preflight.json", "{\"verdict\":\"CLEAR\"}");
    // STALE prior-cycle evidence (WI-07-0.2.3 / CHG-20260830-016) — must be gated out
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"decision\":\"PASS\",\"dbM09Required\":false,\"reviewedAt\":\"2026-08-30T16:48:00Z\"}");
    W(root, @"state/completion.json", "{\"nodeId\":\"WI-07-0.2.3\",\"changeId\":\"CHG-20260830-016\",\"completedAtUtc\":\"2026-08-30T16:50:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var n0 = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(SetsEqual(n0.EnabledButtons, new[] { "RESERVE_TASK", "OPEN_PREFLIGHT_REPORT", "OPEN_DETAIL" }), "CMD-STALE: only reserve/open before",
        $"got [{EnabledDesc(n0.EnabledButtons)}]");
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ =>
    {
        W(root, @"state/current-task.json", StateJson("RESERVED", "CHATGPT_HANDOFF", changeId: "CHG-20260830-053"));
        return Ok("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: True");
    }));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.SUCCESS, "CMD-STALE: reservation succeeds", r.Result.ToString());
    var n1 = NextActionEngine.Evaluate(StateReader.Read(cfg));
    Check(!n1.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "CMD-STALE: stale completion still gated after reserve", EnabledDesc(n1.EnabledButtons));
    Check(!n1.EnabledButtons.Contains("VALIDATE_WORKBOOK"), "CMD-STALE: stale completion cannot arm validation", EnabledDesc(n1.EnabledButtons));
    Check(n1.Instruction.Contains("ChatGPT handoff", StringComparison.Ordinal), "CMD-STALE: next instruction is handoff", n1.Instruction);
}

// ==================================================================== DB-GH01
// G. GOVERNANCE HARDENING — 35 enumerated governance properties (task #44).
//    Each GH1:N block proves exactly one property. Fixtures are read-only temp
//    dirs; the live workbook and Nexus source are never touched.
Console.WriteLine();
Console.WriteLine("DB-GH01 governance properties covered: G1..G35");

// ---- G1. Mode default is TRIAL (safe default, never inferred) ----------------
{
    Check(DevBridgeMode.FromString(null) == DevBridgeOperatingMode.Trial, "GH1:G1 mode default trial", DevBridgeMode.FromString(null).ToString());
    Check(DevBridgeMode.FromString("") == DevBridgeOperatingMode.Trial && DevBridgeMode.FromString("BOGUS") == DevBridgeOperatingMode.Trial,
        "GH1:G1 blank/unknown keeps trial", "not trial");
    Check(DevBridgeMode.ToToken(DevBridgeOperatingMode.Trial) == DevBridgeMode.TrialToken, "GH1:G1 trial token", DevBridgeMode.ToToken(DevBridgeOperatingMode.Trial));
}

// ---- G2. Mode REAL_NEXUS_DEVELOPMENT parses + round-trips --------------------
{
    Check(DevBridgeMode.FromString("REAL_NEXUS_DEVELOPMENT") == DevBridgeOperatingMode.RealNexusDevelopment, "GH1:G2 real parses", "not real");
    Check(DevBridgeMode.ToToken(DevBridgeOperatingMode.RealNexusDevelopment) == DevBridgeMode.RealToken, "GH1:G2 real token", DevBridgeMode.ToToken(DevBridgeOperatingMode.RealNexusDevelopment));
    Check(!DevBridgeMode.IsTrial(DevBridgeOperatingMode.RealNexusDevelopment) && DevBridgeMode.IsTrial(DevBridgeOperatingMode.Trial), "GH1:G2 IsTrial", "IsTrial wrong");
}

// ---- G3. Mode precedence: current-task overrides config ----------------------
{
    string root = NewRoot("gh1-mode-precedence");
    W(root, @"config/devbridge.json", "{\"mode\":\"REAL_NEXUS_DEVELOPMENT\"}");
    W(root, @"state/current-task.json", "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"T\",\"nodeType\":\"WorkItem\",\"status\":\"RESERVED\",\"changeId\":\"CHG-20260831-001\",\"mode\":\"TRIAL\"}");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    Check(s.ModeToken == "TRIAL" && s.Mode == DevBridgeOperatingMode.Trial, "GH1:G3 current-task mode wins", s.ModeToken ?? "null");
}

// ---- G4. Mode falls back to cycle trial evidence (dbM08/dbM06) ---------------
{
    string root = NewRoot("gh1-mode-evidence");
    W(root, @"config/devbridge.json", "{\"mode\":\"REAL_NEXUS_DEVELOPMENT\"}");
    W(root, @"state/current-task.json", "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"T\",\"nodeType\":\"WorkItem\",\"status\":\"RESERVED\",\"changeId\":\"CHG-20260831-002\",\"dbM08\":{\"trialMode\":true}}");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    Check(s.ModeToken == "TRIAL" && s.TrialMode, "GH1:G4 cycle trial evidence fallback", s.ModeToken ?? "null");
}

// ---- G5. Git lifecycle round-trip (ToToken -> FromString) --------------------
{
    bool ok = true; string detail = "";
    foreach (HumanGitGateState st in Enum.GetValues<HumanGitGateState>())
    {
        if (GitLifecycle.FromString(GitLifecycle.ToToken(st)) != st) { ok = false; detail = st.ToString(); break; }
    }
    Check(ok, "GH1:G5 git lifecycle round-trip", ok ? "all states" : $"failed at {detail}");
}

// ---- G6. Git lifecycle accepts the CLAUDE_REVIEW_PASSED_REAL alias -----------
{
    Check(GitLifecycle.FromString("CLAUDE_REVIEW_PASSED_REAL") == HumanGitGateState.ClaudeReviewPassed, "GH1:G6 alias real pass", "alias failed");
    Check(GitLifecycle.FromString("claude_review_passed_real") == HumanGitGateState.ClaudeReviewPassed, "GH1:G6 alias case-insensitive", "case failed");
}

// ---- G7. Git lifecycle unknown token -> NotApplicable (never invented) -------
{
    Check(GitLifecycle.FromString("???") == HumanGitGateState.NotApplicable, "GH1:G7 unknown git token", GitLifecycle.FromString("???").ToString());
}

// ---- G8. Git human gates: exactly the five operator stages require a human ---
{
    bool ok = true; string bad = "";
    foreach (HumanGitGateState st in Enum.GetValues<HumanGitGateState>())
    {
        bool expected = st is HumanGitGateState.AwaitingHumanPr or HumanGitGateState.PrOpen
                            or HumanGitGateState.AwaitingHumanReview or HumanGitGateState.AwaitingHumanMerge
                            or HumanGitGateState.Merged;
        if (GitLifecycle.RequiresHumanGate(st) != expected) { ok = false; bad = st.ToString(); break; }
    }
    Check(ok, "GH1:G8 requires-human-gate set", ok ? "exact set" : $"mismatch at {bad}");
}

// ---- G9. Merge confirmed is OBSERVED, never inferred -------------------------
{
    Check(GitLifecycle.MergeConfirmed(HumanGitGateState.Merged) && GitLifecycle.MergeConfirmed(HumanGitGateState.ReadyForGovernedCompletion),
        "GH1:G9 merged confirmed", "merged not confirmed");
    Check(!GitLifecycle.MergeConfirmed(HumanGitGateState.PrOpen) && !GitLifecycle.MergeConfirmed(HumanGitGateState.NotApplicable),
        "GH1:G9 never inferred from open/clean", "inferred merge");
}

// ---- G10. Git human guidance TELLs the operator, never pretends --------------
{
    Check(GitLifecycle.HumanGuidance(HumanGitGateState.AwaitingHumanMerge).Contains("never merges", StringComparison.OrdinalIgnoreCase),
        "GH1:G10 never merges wording", GitLifecycle.HumanGuidance(HumanGitGateState.AwaitingHumanMerge));
    Check(GitLifecycle.HumanGuidance(HumanGitGateState.PrOpen).Contains("human", StringComparison.OrdinalIgnoreCase),
        "GH1:G10 pr-open guidance", GitLifecycle.HumanGuidance(HumanGitGateState.PrOpen));
}

// ---- G11. Claude decision vocabulary round-trip ------------------------------
{
    bool ok = true; string bad = "";
    foreach (ClaudeReviewDecision d in Enum.GetValues<ClaudeReviewDecision>())
    {
        if (ClaudeReviewDecisions.FromString(ClaudeReviewDecisions.ToToken(d)) != d) { ok = false; bad = d.ToString(); break; }
    }
    Check(ok, "GH1:G11 decision vocabulary round-trip", ok ? "all 4" : $"failed at {bad}");
}

// ---- G12. Unknown decision -> Fix (treated as needing correction) ------------
{
    Check(ClaudeReviewDecisions.FromString("WHATEVER") == ClaudeReviewDecision.Fix, "GH1:G12 unknown -> fix", ClaudeReviewDecisions.FromString("WHATEVER").ToString());
}

// ---- G13. PASS + TRIAL -> CLAUDE_REVIEW_PASSED_TRIAL / TRIAL_CYCLE_SAFE_STOP --
{
    var r = ClaudeReviewDecisions.Route(ClaudeReviewDecision.Pass, trialMode: true);
    Check(r.LifecycleState == "CLAUDE_REVIEW_PASSED_TRIAL" && r.NextAllowedAction == DevBridgeMode.TrialStopAction,
        "GH1:G13 trial pass route", $"{r.LifecycleState}/{r.NextAllowedAction}");
}

// ---- G14. PASS + REAL -> human Git gate, never M10 ---------------------------
{
    var r = ClaudeReviewDecisions.Route(ClaudeReviewDecision.Pass, trialMode: false);
    Check(r.LifecycleState == "CLAUDE_REVIEW_PASSED_REAL" && r.NextAllowedAction == "AWAITING_HUMAN_PR",
        "GH1:G14 real pass route", $"{r.LifecycleState}/{r.NextAllowedAction}");
    Check(r.NextAllowedAction != "RUN_GOVERNED_COMPLETION", "GH1:G14 real pass never arms completion", r.NextAllowedAction);
}

// ---- G15. FIX -> DB_M09_FIX_REQUIRED / CORRECT_CURRENT_ATTEMPT --------------
{
    var r = ClaudeReviewDecisions.Route(ClaudeReviewDecision.Fix, trialMode: false);
    Check(r.LifecycleState == "DB_M09_FIX_REQUIRED" && r.NextAllowedAction == "CORRECT_CURRENT_ATTEMPT",
        "GH1:G15 fix route", $"{r.LifecycleState}/{r.NextAllowedAction}");
}

// ---- G16. GOVERNANCE_ISSUE -> surfaced to a human, never auto-resolved -------
{
    var r = ClaudeReviewDecisions.Route(ClaudeReviewDecision.GovernanceIssue, trialMode: true);
    Check(r.LifecycleState == "GOVERNANCE_ISSUE" && r.NextAllowedAction == "REVIEW_GOVERNANCE_ISSUE",
        "GH1:G16 governance-issue route", $"{r.LifecycleState}/{r.NextAllowedAction}");
}

// ---- G17. HUMAN_DECISION_REQUIRED -> surfaced to the operator ----------------
{
    var r = ClaudeReviewDecisions.Route(ClaudeReviewDecision.HumanDecisionRequired, trialMode: false);
    Check(r.LifecycleState == "HUMAN_DECISION_REQUIRED" && r.NextAllowedAction == "HUMAN_DECISION_REQUIRED",
        "GH1:G17 human-decision route", $"{r.LifecycleState}/{r.NextAllowedAction}");
}

// ---- G18. Evidence record: PASS (trial) writes md + json with trial route ----
{
    string root = NewRoot("gh1-ev-pass");
    var cfg = DevBridgeConfig.Load(root);
    var rec = ClaudeResultEvidence.Record(cfg, new ClaudeResultEntry(ClaudeReviewDecision.Pass, "Trial review ok.", "WI-07-0.2.4", "CHG-20260831-003", "T", TrialMode: true));
    Check(rec.Ok, "GH1:G18 record ok", rec.Message);
    var md = File.ReadAllText(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_RESULT.md"));
    Check(md.StartsWith("PASS", StringComparison.Ordinal) && !md.Contains("CLAUDE_FIX_REQUIRED", StringComparison.Ordinal),
        "GH1:G18 md decision pass, no fix marker", md.Trim());
    using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(cfg.StateDir, "claude-review.json")));
    Check(doc.RootElement.GetProperty("trialMode").GetBoolean() && doc.RootElement.GetProperty("routeLifecycleState").GetString() == "CLAUDE_REVIEW_PASSED_TRIAL",
        "GH1:G18 json trial route", $"{doc.RootElement.GetProperty("routeLifecycleState").GetString()}");
}

// ---- G19. Evidence record: FIX -> CLAUDE_FIX_REQUIRED + dbM09Required --------
{
    string root = NewRoot("gh1-ev-fix");
    var cfg = DevBridgeConfig.Load(root);
    var rec = ClaudeResultEvidence.Record(cfg, new ClaudeResultEntry(ClaudeReviewDecision.Fix, "Missing row.", "WI-07-0.2.4", "CHG-20260831-004", "T"));
    Check(rec.Ok, "GH1:G19 record ok", rec.Message);
    var md = File.ReadAllText(Path.Combine(cfg.TasksDir, "CLAUDE_REVIEW_RESULT.md"));
    Check(md.Contains("CLAUDE_FIX_REQUIRED", StringComparison.Ordinal), "GH1:G19 fix marker", "missing");
    using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(cfg.StateDir, "claude-review.json")));
    Check(doc.RootElement.GetProperty("decision").GetString() == "FIX" && doc.RootElement.GetProperty("dbM09Required").GetBoolean(),
        "GH1:G19 json fix evidence", doc.RootElement.GetProperty("decision").GetString() ?? "null");
}

// ---- G20. Evidence record: PASS + real -> human git route --------------------
{
    string root = NewRoot("gh1-ev-real");
    var cfg = DevBridgeConfig.Load(root);
    ClaudeResultEvidence.Record(cfg, new ClaudeResultEntry(ClaudeReviewDecision.Pass, "Real review ok.", "WI-07-0.2.4", "CHG-20260831-005", "T", TrialMode: false));
    using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(cfg.StateDir, "claude-review.json")));
    bool trial = doc.RootElement.GetProperty("trialMode").GetBoolean();
    string route = doc.RootElement.GetProperty("routeLifecycleState").GetString() ?? "";
    string next = doc.RootElement.GetProperty("routeNextAllowedAction").GetString() ?? "";
    Check(!trial && route == "CLAUDE_REVIEW_PASSED_REAL" && next == "AWAITING_HUMAN_PR", "GH1:G20 real evidence route", $"{route}/{next}");
}

// ---- G21. M10: TRIAL -> TRIAL_COMPLETION_NOT_APPLICABLE ----------------------
{
    var e = M10CompletionEligibility.Evaluate(trialMode: true, verificationPassed: true, claudePass: true, HumanGitGateState.Merged, RoadmapGuardVerdict.Preserved);
    Check(e.Verdict == M10CompletionEligibilityVerdict.NotApplicable && e.Token == M10CompletionEligibility.TrialCompletionNotApplicableToken,
        "GH1:G21 trial not applicable", e.Token);
    Check(!e.Eligible, "GH1:G21 trial never eligible", "eligible");
}

// ---- G22. M10: no DB-M06 verification pass blocks ---------------------------
{
    var e = M10CompletionEligibility.Evaluate(trialMode: false, verificationPassed: false, claudePass: true, HumanGitGateState.Merged, RoadmapGuardVerdict.Preserved);
    Check(e.Token == "BLOCKED_NO_DB_M06_VERIFICATION_PASS", "GH1:G22 no verification", e.Token);
}

// ---- G23. M10: no Claude PASS blocks ----------------------------------------
{
    var e = M10CompletionEligibility.Evaluate(trialMode: false, verificationPassed: true, claudePass: false, HumanGitGateState.Merged, RoadmapGuardVerdict.Preserved);
    Check(e.Token == "BLOCKED_NO_CLAUDE_PASS", "GH1:G23 no claude pass", e.Token);
}

// ---- G24. M10: human git merge gate pending blocks --------------------------
{
    var e = M10CompletionEligibility.Evaluate(trialMode: false, verificationPassed: true, claudePass: true, HumanGitGateState.PrOpen, RoadmapGuardVerdict.Preserved);
    Check(e.Token == "BLOCKED_HUMAN_GIT_MERGE_GATE_PENDING", "GH1:G24 git gate pending", e.Token);
}

// ---- G25. M10: protected roadmap changed blocks the write -------------------
{
    var e = M10CompletionEligibility.Evaluate(trialMode: false, verificationPassed: true, claudePass: true, HumanGitGateState.Merged, RoadmapGuardVerdict.StructureChanged);
    Check(e.Token == ProtectedRoadmapFingerprintGuard.BlockToken, "GH1:G25 roadmap write prohibited", e.Token);
}

// ---- G26. M10: all gates satisfied -> READY_FOR_GOVERNED_COMPLETION ----------
{
    var e = M10CompletionEligibility.Evaluate(trialMode: false, verificationPassed: true, claudePass: true, HumanGitGateState.Merged, RoadmapGuardVerdict.Preserved);
    Check(e.Verdict == M10CompletionEligibilityVerdict.ReadyForGovernedCompletion && e.Token == "READY_FOR_GOVERNED_COMPLETION" && e.Eligible,
        "GH1:G26 ready for governed completion", e.Token);
}

// ---- G27. Fingerprint: unchanged -> Preserved --------------------------------
{
    var before = new ProtectedRoadmapFingerprint("AAA", "Master Roadmap", "test", null);
    var after = new ProtectedRoadmapFingerprint("AAA", "Master Roadmap", "test", null);
    Check(ProtectedRoadmapFingerprintGuard.Guard(before, after) == RoadmapGuardVerdict.Preserved, "GH1:G27 preserved", "not preserved");
}

// ---- G28. Fingerprint: changed -> StructureChanged + block message ----------
{
    var before = new ProtectedRoadmapFingerprint("AAA", "Master Roadmap", "test", null);
    var after = new ProtectedRoadmapFingerprint("BBB", "Master Roadmap", "test", null);
    var v = ProtectedRoadmapFingerprintGuard.Guard(before, after);
    Check(v == RoadmapGuardVerdict.StructureChanged, "GH1:G28 structure changed", v.ToString());
    Check(ProtectedRoadmapFingerprintGuard.BlockMessage(v).StartsWith(ProtectedRoadmapFingerprintGuard.BlockToken, StringComparison.Ordinal),
        "GH1:G28 block message carries token", ProtectedRoadmapFingerprintGuard.BlockMessage(v));
}

// ---- G29. Fingerprint: missing/error -> NotComparable, blocked --------------
{
    Check(ProtectedRoadmapFingerprintGuard.Guard(null, new ProtectedRoadmapFingerprint("A", "s", "t", null)) == RoadmapGuardVerdict.NotComparable,
        "GH1:G29 null before not comparable", "wrong");
    var err = new ProtectedRoadmapFingerprint("", "", "test", "boom");
    Check(ProtectedRoadmapFingerprintGuard.Guard(err, err) == RoadmapGuardVerdict.NotComparable, "GH1:G29 error not comparable", "wrong");
    Check(ProtectedRoadmapFingerprintGuard.BlockMessage(RoadmapGuardVerdict.NotComparable).StartsWith(ProtectedRoadmapFingerprintGuard.BlockToken, StringComparison.Ordinal),
        "GH1:G29 not-comparable block message", ProtectedRoadmapFingerprintGuard.BlockMessage(RoadmapGuardVerdict.NotComparable));
}

// ---- G30. Handoff: complete 14-marker header -> READY ------------------------
{
    string header =
        "DEVELOPMENT HANDBOOK — DevBridge is TEMPORARY external scaffolding for Nexus Phase 1/2 and will retire. " +
        "Mode: TRIAL / REAL_NEXUS_DEVELOPMENT. No architecture changes: this is NOT Nexus architecture and there is no architecture redesign. " +
        "The roadmap is immutable; no structural edits. NEXUS_DEVELOPMENT_CONTROL.xlsx is the authoritative control record. " +
        "Git is a formal human gate: a human owns PR and merge. DB-M08 Claude review gate applies. Task identity: node, task, change. " +
        "Exact scope is stated. Forbidden actions: must not edit roadmap structure, prohibited to PR/merge. Acceptance criteria included. " +
        "DB-M06 verification required. DeepSeek completion report and output contract stated.";
    var r = ChatGptHandoffValidation.Validate(header);
    Check(r.IsReady && r.Missing.Count == 0, "GH1:G30 handoff ready", $"missing={r.Missing.Count}");
}

// ---- G31. Handoff: partial/blank -> CHATGPT_HANDOFF_NOT_READY ----------------
{
    var partial = ChatGptHandoffValidation.Validate("TRIAL only");
    Check(!partial.IsReady && partial.Missing.Count > 0 && partial.NotReadyToken == ChatGptHandoffValidation.ChatGptHandoffNotReadyToken,
        "GH1:G31 partial not ready", $"missing={partial.Missing.Count}");
    var blank = ChatGptHandoffValidation.Validate(null);
    Check(!blank.IsReady && blank.Missing.Count == ChatGptHandoffValidation.AllChecks.Count, "GH1:G31 blank -> all 14 missing", $"{blank.Missing.Count}");
}

// ---- G32. Review package: governance header present -> valid ----------------
{
    string pkg =
        "Claude review package — DevBridge is TEMPORARY external scaffolding and will retire. Mode TRIAL / REAL_NEXUS_DEVELOPMENT. " +
        "NOT authorized to redesign architecture. Roadmap immutable; no redesign. CORRECT_CURRENT_ATTEMPT vs NEW_FIX_TASK_REQUIRED. " +
        "Exact scope delta. Forbidden: must not modify the workbook; prohibited structural edits. PR/merge are human gates. " +
        "Decisions: PASS / GOVERNANCE_ISSUE / HUMAN_DECISION_REQUIRED.";
    var r = ClaudeReviewPackageValidation.Validate(pkg);
    Check(r.HasGovernanceHeader && r.Missing.Count == 0, "GH1:G32 package header present", $"missing={r.Missing.Count}");
}

// ---- G33. Review package: header missing -> token surfaced -------------------
{
    var r = ClaudeReviewPackageValidation.Validate("just the packet, no governance");
    Check(!r.HasGovernanceHeader && r.Missing.Count > 0, "GH1:G33 package header missing", $"missing={r.Missing.Count}");
    Check(ClaudeReviewPackageValidation.MissingHeaderToken == "CLAUDE_REVIEW_PACKAGE_MISSING_GOVERNANCE_HEADER", "GH1:G33 missing header token", ClaudeReviewPackageValidation.MissingHeaderToken);
}

// ---- G34. Pre-DevBridge baseline: represented, human-only restore ------------
{
    string root = NewRoot("gh1-baseline");
    W(root, @"state/pre-devbridge-baseline.json",
        "{\"workbook\":{\"path\":\"C:\\\\Personal\\\\Nexus.Developer\\\\NEXUS_DEVELOPMENT_CONTROL.xlsx\",\"sha256\":\"F520060C\",\"capturedAtUtc\":\"2026-08-01T00:00:00Z\"}," +
        "\"git\":{\"repository\":\"C:\\\\Personal\\\\Nexus.Developer\",\"branch\":\"main\",\"headCommit\":\"abc123\",\"capturedAtUtc\":\"2026-08-01T00:00:00Z\"}}");
    var cfg = DevBridgeConfig.Load(root);
    var b = PreDevBridgeBaseline.Load(cfg);
    Check(b.Present && b.Workbook is not null && b.Workbook.Sha256 == "F520060C" && b.Git is not null && b.Git.Branch == "main",
        "GH1:G34 baseline represented", $"{b.Workbook?.Sha256}/{b.Git?.Branch}");
    Check(PreDevBridgeBaseline.RestoreAuthorizationGuidance("wb", "repo").Contains("HUMAN", StringComparison.OrdinalIgnoreCase)
          && PreDevBridgeBaseline.RestoreAuthorizationGuidance("wb", "repo").Contains("never", StringComparison.OrdinalIgnoreCase),
        "GH1:G34 restore is human-only", PreDevBridgeBaseline.RestoreAuthorizationGuidance("wb", "repo"));
    string root2 = NewRoot("gh1-baseline-empty");
    var e = PreDevBridgeBaseline.Load(DevBridgeConfig.Load(root2));
    Check(!e.Present && e.Workbook is null && e.Git is null, "GH1:G34 missing baseline -> empty", "not empty");
}

// ---- G35. Fix-task rule + M11 advisory (retirement lifecycle removed — Forge is permanent) ----
{
    Check(FixTaskPolicy.Classify(true) == FixAction.CorrectCurrentAttempt && FixTaskPolicy.Classify(false) == FixAction.NewFixTaskRequired,
        "GH1:G35 fix-task rule active vs completed", $"{FixTaskPolicy.Classify(true)}/{FixTaskPolicy.Classify(false)}");
    Check(FixTaskPolicy.Explain(FixAction.HumanGovernanceRequired).Contains("HUMAN_GOVERNANCE_REQUIRED", StringComparison.Ordinal),
        "GH1:G35 structure-unrepresentable stops", FixTaskPolicy.Explain(FixAction.HumanGovernanceRequired));
    var m11a = new M11ReviewRecommendation(true, true, "suspicious non-structural condition");
    var m11b = new M11ReviewRecommendation(true, false, null);
    Check(m11a.Token == "CLAUDE_WORKBOOK_REVIEW_RECOMMENDED" && m11b.Token == "NO_ADVISORY_REVIEW_RECOMMENDED",
        "GH1:G35 m11 advisory token", $"{m11a.Token}/{m11b.Token}");
}

// ==================================================================== DB-M12.2
// REUSABLE LIFECYCLE BACKEND COMMANDS — one-command contract, availability
// vocabulary, stale-state + writer-serialization guards, extended marker parsing,
// and execution of the 9 reusable commands (M06/M07/M08/M09/M10/M11/DB12/DB13/DB14)
// against fake backends. Fixtures use generic ids — no hard-coded WI/CHG identity.
Console.WriteLine();
Console.WriteLine("DB-M12.2 reusable lifecycle backend commands");

// ---- N1. extended marker parsing (one-command contract fields) ----
{
    string stdout = "DB06_OUTCOME: VERIFICATION_PASSED\nDB06_RESULT_PASS: True\nDB06_RESULT_CODE: VERIFICATION_PASSED\n" +
                    "DB06_WORKBOOK_MODIFIED: False\nDB06_NEXUS_SOURCE_MODIFIED: False\nDB06_GIT_MODIFIED: False\n" +
                    "DB06_REQUIRES_HUMAN_ACTION: False\nDB06_HUMAN_ACTION_TYPE:\n" +
                    "DB06_EVIDENCE: state/verification.json\nDB06_EVIDENCE: tasks/VERIFICATION_REPORT.md";
    var o = ScriptOutcomeParser.Parse(stdout);
    Check(o.OutcomeToken == "VERIFICATION_PASSED", "DB-M12.2:N1 outcome token", o.OutcomeToken ?? "null");
    Check(o.ResultPass == true, "DB-M12.2:N1 pass flag", $"{o.ResultPass}");
    Check(o.ResultCode == "VERIFICATION_PASSED", "DB-M12.2:N1 result code", o.ResultCode ?? "null");
    Check(o.WorkbookModified == false && o.NexusSourceModified == false && o.GitModified == false, "DB-M12.2:N1 modified flags", "non-false");
    Check(o.RequiresHumanAction == false, "DB-M12.2:N1 human flag", $"{o.RequiresHumanAction}");
    Check(o.Evidence is { Count: 2 } && o.Evidence[1].Contains("VERIFICATION_REPORT", StringComparison.Ordinal), "DB-M12.2:N1 repeatable evidence", string.Join("|", o.Evidence ?? Array.Empty<string>()));
    Check(!o.IsGovernedStop, "DB-M12.2:N1 not a governed stop", "is stop");
}

// ---- N2. governed STOP markers surface human action on the result ----
{
    string stdout = "DB10_OUTCOME: STOP_HUMAN_GIT_MERGE_GATE_PENDING\nDB10_RESULT_PASS: False\nDB10_RESULT_CODE: STOP_HUMAN_GIT_MERGE_GATE_PENDING\n" +
                    "DB10_WORKBOOK_MODIFIED: False\nDB10_NEXUS_SOURCE_MODIFIED: False\nDB10_GIT_MODIFIED: False\n" +
                    "DB10_REQUIRES_HUMAN_ACTION: True\nDB10_HUMAN_ACTION_TYPE: HUMAN_GIT_MERGE\n" +
                    "DB10_EVIDENCE: state/completion.json";
    var o = ScriptOutcomeParser.Parse(stdout);
    Check(o.IsGovernedStop && o.OutcomeToken == "STOP_HUMAN_GIT_MERGE_GATE_PENDING", "DB-M12.2:N2 governed stop", o.OutcomeToken ?? "null");
    Check(o.RequiresHumanAction == true && o.HumanActionType == "HUMAN_GIT_MERGE", "DB-M12.2:N2 human action surfaced", $"{o.RequiresHumanAction}/{o.HumanActionType}");
}

// ---- N3. input validation: identity, mode, actor (one-command contract) ----
{
    string root = NewRoot("db12-input");
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-060");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Run-Verification.ps1", _ => Ok("DB06_OUTCOME: VERIFICATION_PASSED\nDB06_RESULT_PASS: True")));
    var run = OperatorCommandCatalog.Get("RUN_VERIFICATION")!;
    var r1 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-99-0.0", ChangeId: "CHG-20260830-060", Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(r1.Result == CommandResultCode.FAILED && r1.Message.Contains("NodeId", StringComparison.Ordinal), "DB-M12.2:N3 wrong NodeId rejected", r1.Message);
    var r2 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-001", Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(r2.Result == CommandResultCode.FAILED && r2.Message.Contains("ChangeId", StringComparison.Ordinal), "DB-M12.2:N3 wrong ChangeId rejected", r2.Message);
    var r3 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: null, ChangeId: "CHG-20260830-060", Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(r3.Result == CommandResultCode.FAILED && r3.Message.Contains("NodeId", StringComparison.Ordinal), "DB-M12.2:N3 missing NodeId rejected", r3.Message);
    var r4 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: null, Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(r4.Result == CommandResultCode.FAILED && r4.Message.Contains("ChangeId", StringComparison.Ordinal), "DB-M12.2:N3 missing ChangeId rejected", r4.Message);
    var r5 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RESERVE_TASK", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-060", Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(r5.Result == CommandResultCode.FAILED && r5.Message.Contains("CommandId", StringComparison.Ordinal), "DB-M12.2:N3 CommandId mismatch rejected", r5.Message);
    var r6 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-060", Mode: "REAL_NEXUS_DEVELOPMENT", Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(r6.Result == CommandResultCode.FAILED && r6.Message.Contains("Mode", StringComparison.Ordinal), "DB-M12.2:N3 implicit mode switch rejected", r6.Message);
    var r7 = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-060", Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "A", CorrelationId: null));
    Check(r7.Result == CommandResultCode.FAILED && r7.Message.Contains("Actor", StringComparison.Ordinal), "DB-M12.2:N3 short actor rejected", r7.Message);
    Check(fake.Invoked.Count == 0, "DB-M12.2:N3 validation rejects before run", $"{fake.Invoked.Count}");
}

// ---- N4. one-command input flows into the scripts via the environment channel ----
{
    string root = NewRoot("db12-envchan");
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-061");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Run-Verification.ps1", _ => Ok("DB06_OUTCOME: VERIFICATION_PASSED\nDB06_RESULT_PASS: True")));
    var input = new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-061", Mode: "TRIAL",
        Parameters: new Dictionary<string, string> { ["someParam"] = "1" }, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: "CORR-123");
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RUN_VERIFICATION")!, fake, input);
    Check(r.Result == CommandResultCode.SUCCESS, "DB-M12.2:N4 env channel run succeeds", r.Result.ToString());
    var env = fake.Environments.Count > 0 ? fake.Environments[0] : null;
    Check(env is not null && env!["DB_COMMAND_INPUT_NODE_ID"] == "WI-07-0.2.4" && env!["DB_COMMAND_INPUT_CHANGE_ID"] == "CHG-20260830-061",
        "DB-M12.2:N4 identity passed to script", env is null ? "no env" : env!["DB_COMMAND_INPUT_NODE_ID"]);
    Check(env is not null && env!["DB_COMMAND_INPUT_MODE"] == "TRIAL" && env!["DB_COMMAND_INPUT_ACTOR"] == "Operator" && env!["DB_COMMAND_INPUT_CORRELATION_ID"] == "CORR-123",
        "DB-M12.2:N4 mode/actor/correlation passed", env is null ? "no env" : "ok");
    Check(env is not null && env!["DB_COMMAND_INPUT_EXPECTED_CURRENT_STATE"] == "VERIFIED" && env!["DB_COMMAND_INPUT_PARAMETERS"].Contains("someParam", StringComparison.Ordinal),
        "DB-M12.2:N4 expected-state + parameters passed", env is null ? "no env" : "ok");
    Check(r.CorrelationId == "CORR-123", "DB-M12.2:N4 result carries correlation id", r.CorrelationId);
}

// ---- N5. stale expected state is rejected; a matching expected state runs ----
{
    string root = NewRoot("db12-stale");
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-062");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Run-Verification.ps1", _ => Ok("DB06_OUTCOME: VERIFICATION_PASSED\nDB06_RESULT_PASS: True")));
    var run = OperatorCommandCatalog.Get("RUN_VERIFICATION")!;
    var stale = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-062", Mode: null, Parameters: null, ExpectedCurrentState: "PREFLIGHTED", Actor: "Operator", CorrelationId: null));
    Check(stale.Result == CommandResultCode.BLOCKED && stale.Message.Contains("STALE_GOVERNANCE_STATE", StringComparison.Ordinal), "DB-M12.2:N5 stale expected state rejected", stale.Message);
    Check(fake.Invoked.Count == 0, "DB-M12.2:N5 stale rejected before run", $"{fake.Invoked.Count}");
    var good = OperatorCommandService.Execute(cfg, run, fake, new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-062", Mode: null, Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(good.Result == CommandResultCode.SUCCESS, "DB-M12.2:N5 matching expected state runs", good.Result.ToString());
}

// ---- N6. writer serialization: a second live writer is WORKBOOK_WRITER_BUSY ----
{
    string root = NewRoot("db12-writer");
    WriteState(root, "PREFLIGHTED", "RESERVE", "CHG-20260830-063", verdict: "CLEAR");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Reserve-DevelopmentChange.ps1", _ => { WriteState(root, "RESERVED", "CHATGPT_HANDOFF", "CHG-20260830-063"); return Ok("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: True"); }));
    var (acquired, _) = WorkbookWriterGate.TryAcquire(cfg, "test-owner");
    Check(acquired, "DB-M12.2:N6 first writer acquires", "not acquired");
    var second = WorkbookWriterGate.TryAcquire(cfg, "second");
    Check(!second.Acquired && second.Message!.Contains("WORKBOOK_WRITER_BUSY", StringComparison.Ordinal), "DB-M12.2:N6 second writer busy", second.Message ?? "busy");
    WorkbookWriterGate.Release(cfg);
    var third = WorkbookWriterGate.TryAcquire(cfg, "third");
    Check(third.Acquired, "DB-M12.2:N6 released lock re-acquired", third.Message ?? "");
    if (third.Acquired) WorkbookWriterGate.Release(cfg);

    var gate = WorkbookWriterGate.TryAcquire(cfg, "operator");
    Check(gate.Acquired, "DB-M12.2:N6 execute-level gate acquired", gate.Message ?? "");
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(r.Result == CommandResultCode.BLOCKED && r.Message.Contains("WORKBOOK_WRITER_BUSY", StringComparison.Ordinal), "DB-M12.2:N6 concurrent writer blocked", r.Message);
    Check(fake.Invoked.Count == 0, "DB-M12.2:N6 blocked before script", $"{fake.Invoked.Count}");
    WorkbookWriterGate.Release(cfg);
    var after = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(after.Result == CommandResultCode.SUCCESS, "DB-M12.2:N6 released gate allows the write", after.Result.ToString());
}

// ---- N7. M03/M04/M05 run generically against a non-WI fixture (no hard-coded identity) ----
{
    string root = NewRoot("db12-generic");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"N-01-0.1\",\"name\":\"Generic fixture task\",\"nodeType\":\"WorkItem\",\"phase\":\"P9\",\"layer\":\"Test\",\"changeId\":\"CHG-20260831-001\",\"status\":\"NO_TASK\",\"nextAllowedAction\":\"START_PREFLIGHT\",\"selectedAt\":\"2026-08-31T00:00:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(
        ("Get-NextTask.ps1", _ => { W(root, @"state/current-task.json", StateJson("PREFLIGHTED", "RESERVE", nodeId: "N-01-0.1", changeId: "CHG-20260831-001")); return Ok("DB03_OUTCOME: TASK_SELECTED\nDB03_RESULT_PASS: True"); }),
        ("Test-DevelopmentPreflight.ps1", _ => { W(root, @"state/preflight.json", "{\"verdict\":\"CLEAR\"}"); W(root, @"tasks/PREFLIGHT_REPORT.md", "PREFLIGHT VERDICT: CLEAR"); return Ok("PREFLIGHT VERDICT: CLEAR\nDB03_RESULT_PASS: True"); }),
        ("Reserve-DevelopmentChange.ps1", _ => { W(root, @"state/current-task.json", StateJson("RESERVED", "CHATGPT_HANDOFF", nodeId: "N-01-0.1", changeId: "CHG-20260831-001")); return Ok("DB04_OUTCOME: RESERVED\nDB04_RESULT_PASS: True"); }),
        ("New-ChatGptHandoff.ps1", _ => { W(root, @"state/current-task.json", StateJson("AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", nodeId: "N-01-0.1", changeId: "CHG-20260831-001")); W(root, @"tasks/CHATGPT_HANDOFF.md", "handoff"); return Ok("DB05_OUTCOME: AWAITING_CHATGPT_PROMPT\nDB05_RESULT_PASS: True"); }));
    var p = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("START_PREFLIGHT")!, fake);
    Check(p.Result == CommandResultCode.SUCCESS && p.NewState == "PREFLIGHTED", "DB-M12.2:N7 generic M03 callable", $"{p.Result}/{p.NewState}");
    var m4 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RESERVE_TASK")!, fake);
    Check(m4.Result == CommandResultCode.SUCCESS && m4.NewState == "RESERVED", "DB-M12.2:N7 generic M04 callable", $"{m4.Result}/{m4.NewState}");
    var m5 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CREATE_CHATGPT_HANDOFF")!, fake);
    Check(m5.Result == CommandResultCode.SUCCESS && m5.NewState == "AWAITING_CHATGPT_PROMPT", "DB-M12.2:N7 generic M05 callable", $"{m5.Result}/{m5.NewState}");
}

// ---- N8. RUN_VERIFICATION (M06) + CREATE_CLAUDE_REVIEW_PACKAGE (M07) execution ----
{
    string root = NewRoot("db12-m06");
    WriteState(root, "AWAITING_CHATGPT_PROMPT", "COPY_TO_CHATGPT", "CHG-20260830-064");
    W(root, @"tasks/CHATGPT_HANDOFF.md", "handoff");
    var cfg = DevBridgeConfig.Load(root);
    var input = new LifecycleCommandInput(CommandId: "RUN_VERIFICATION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-064", Mode: "TRIAL", Parameters: null, ExpectedCurrentState: "AWAITING_CHATGPT_PROMPT", Actor: "Operator", CorrelationId: null);
    var fake6 = Runner(("Run-Verification.ps1", _ => { W(root, @"state/current-task.json", StateJson("VERIFIED", "CLAUDE_REVIEW", changeId: "CHG-20260830-064")); W(root, @"tasks/VERIFICATION_REPORT.md", "VERIFICATION_PASSED"); return Ok("DB06_OUTCOME: VERIFICATION_PASSED\nDB06_RESULT_PASS: True\nDB06_WORKBOOK_MODIFIED: False\nDB06_EVIDENCE: state/verification.json\nDB06_EVIDENCE: tasks/VERIFICATION_REPORT.md"); }));
    var r6 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RUN_VERIFICATION")!, fake6, input);
    Check(r6.Result == CommandResultCode.SUCCESS && r6.NewState == "VERIFIED", "DB-M12.2:N8 M06 success + verified", $"{r6.Result}/{r6.NewState}");
    Check(r6.WorkbookModified == false && r6.NexusSourceModified == false && r6.GitModified == false, "DB-M12.2:N8 M06 never modifies workbook/source/git", $"{r6.WorkbookModified}/{r6.NexusSourceModified}/{r6.GitModified}");
    Check(r6.ResultCodeToken == "VERIFICATION_PASSED", "DB-M12.2:N8 M06 result code", r6.ResultCodeToken);
    Check(r6.EvidenceReferences.Any(p => p.Contains("VERIFICATION_REPORT", StringComparison.Ordinal)), "DB-M12.2:N8 M06 evidence surfaced", string.Join("|", r6.EvidenceReferences));

    var fake7 = Runner(("New-ClaudeReviewPackage.ps1", _ => { W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "governance header"); W(root, @"tasks/REVIEW_PACKET.md", "packet"); return Ok("DB07_OUTCOME: REVIEW_PACKAGE_READY\nDB07_RESULT_PASS: True"); }));
    var r7 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CREATE_CLAUDE_REVIEW_PACKAGE")!, fake7, input with { CommandId = "CREATE_CLAUDE_REVIEW_PACKAGE", ExpectedCurrentState = "VERIFIED" });
    Check(r7.Result == CommandResultCode.SUCCESS && r7.NewState == "VERIFIED", "DB-M12.2:N8 M07 success (state unchanged)", $"{r7.Result}/{r7.NewState}");
    Check(r7.GeneratedArtifacts.Any(p => p.EndsWith("CLAUDE_REVIEW_PACKAGE.md", StringComparison.OrdinalIgnoreCase)) && r7.GeneratedArtifacts.Any(p => p.EndsWith("REVIEW_PACKET.md", StringComparison.OrdinalIgnoreCase)), "DB-M12.2:N8 M07 both artifacts", string.Join("|", r7.GeneratedArtifacts));
}

// ---- N9. RECORD_CLAUDE_RESULT (M08) routes per decision ----
{
    string root = NewRoot("db12-m08");
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-065");
    var cfg = DevBridgeConfig.Load(root);
    var input = new LifecycleCommandInput(CommandId: "RECORD_CLAUDE_RESULT", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-065", Mode: "TRIAL", Parameters: new Dictionary<string, string> { ["decision"] = "PASS", ["reviewText"] = "ok" }, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null);
    var fake8 = Runner(("Set-ClaudeReviewResult.ps1", _ => { WriteState(root, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-20260830-065"); W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "PASS"); return Ok("DB08_OUTCOME: CLAUDE_RESULT_RECORDED\nDB08_RESULT_PASS: True"); }));
    var r8 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RECORD_CLAUDE_RESULT")!, fake8, input);
    Check(r8.Result == CommandResultCode.SUCCESS && r8.NewState == "CLAUDE_REVIEW_PASSED_TRIAL", "DB-M12.2:N9 M08 trial route", $"{r8.Result}/{r8.NewState}");
    Check(r8.NextAllowedAction == "TRIAL_CYCLE_SAFE_STOP", "DB-M12.2:N9 M08 trial next action", r8.NextAllowedAction);
}

// ---- N10. CREATE_CORRECTION_CONTEXT (M09) preserves the existing task ----
{
    string root = NewRoot("db12-m09");
    WriteState(root, "DB_M09_FIX_REQUIRED", "CORRECT_CURRENT_ATTEMPT", "CHG-20260830-066");
    var cfg = DevBridgeConfig.Load(root);
    var fake9 = Runner(("New-CorrectionContext.ps1", _ => { W(root, @"tasks/FIX_CONTEXT.md", "fix findings"); return Ok("DB09_OUTCOME: FIX_CONTEXT_CREATED\nDB09_RESULT_PASS: True"); }));
    var r9 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CREATE_CORRECTION_CONTEXT")!, fake9);
    Check(r9.Result == CommandResultCode.SUCCESS && r9.NewState == "DB_M09_FIX_REQUIRED", "DB-M12.2:N10 M09 success + state preserved", $"{r9.Result}/{r9.NewState}");
    Check(r9.GeneratedArtifacts.Any(p => p.EndsWith("FIX_CONTEXT.md", StringComparison.OrdinalIgnoreCase)), "DB-M12.2:N10 M09 fix context artifact", string.Join("|", r9.GeneratedArtifacts));
}

// ---- N11. RUN_GOVERNED_COMPLETION (M10): trial not-applicable, real eligible, mismatch ----
{
    // trial -> TRIAL_COMPLETION_NOT_APPLICABLE, no write
    string root = NewRoot("db12-m10-trial");
    WriteState(root, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-20260830-067");
    var cfg = DevBridgeConfig.Load(root);
    var input = new LifecycleCommandInput(CommandId: "RUN_GOVERNED_COMPLETION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-067", Mode: "TRIAL", Parameters: null, ExpectedCurrentState: "CLAUDE_REVIEW_PASSED_TRIAL", Actor: "Operator", CorrelationId: null);
    var fakeT = Runner(("Complete-GovernedCycle.ps1", _ => Ok("DB10_OUTCOME: TRIAL_COMPLETION_NOT_APPLICABLE\nDB10_RESULT_PASS: True\nDB10_WORKBOOK_MODIFIED: False")));
    var rT = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!, fakeT, input);
    Check(rT.Result == CommandResultCode.SUCCESS && rT.ResultCodeToken == "TRIAL_COMPLETION_NOT_APPLICABLE", "DB-M12.2:N11 M10 trial not applicable", $"{rT.Result}/{rT.ResultCodeToken}");
    Check(rT.WorkbookModified == false && rT.NewState == "CLAUDE_REVIEW_PASSED_TRIAL", "DB-M12.2:N11 M10 trial no write", $"{rT.WorkbookModified}/{rT.NewState}");

    // hardened: WritesWorkbook + COMPLETED token + state NOT COMPLETION_WRITTEN -> mismatch
    string rootB = NewRoot("db12-m10-mismatch");
    WriteState(rootB, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-20260830-068");
    var cfgB = DevBridgeConfig.Load(rootB);
    var fakeB = Runner(("Complete-GovernedCycle.ps1", _ => { WriteState(rootB, "MERGED", "AWAITING_HUMAN_MERGE", "CHG-20260830-068"); return Ok("DB10_OUTCOME: COMPLETED\nDB10_RESULT_PASS: True\nDB10_WORKBOOK_MODIFIED: True"); }));
    var inputB = new LifecycleCommandInput(CommandId: "RUN_GOVERNED_COMPLETION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-068", Mode: "TRIAL", Parameters: null, ExpectedCurrentState: "CLAUDE_REVIEW_PASSED_TRIAL", Actor: "Operator", CorrelationId: null);
    var rB = OperatorCommandService.Execute(cfgB, OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!, fakeB, inputB);
    Check(rB.Result == CommandResultCode.FAILED && rB.IsBackendStateMismatch && rB.Message.Contains("BACKEND_STATE_MISMATCH", StringComparison.Ordinal), "DB-M12.2:N11 M10 hardened mismatch", rB.Message);

    // real eligible path: COMPLETED + COMPLETION_WRITTEN -> success with workbook write
    string rootC = NewRoot("db12-m10-real");
    W(rootC, @"state/current-task.json", "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Test Task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\",\"changeId\":\"CHG-20260830-069\",\"status\":\"READY_FOR_GOVERNED_COMPLETION\",\"nextAllowedAction\":\"RUN_GOVERNED_COMPLETION\",\"mode\":\"REAL_NEXUS_DEVELOPMENT\",\"selectedAt\":\"2026-08-31T00:00:00Z\"}");
    var cfgC = DevBridgeConfig.Load(rootC);
    var inputC = new LifecycleCommandInput(CommandId: "RUN_GOVERNED_COMPLETION", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-069", Mode: "REAL_NEXUS_DEVELOPMENT", Parameters: null, ExpectedCurrentState: "READY_FOR_GOVERNED_COMPLETION", Actor: "Operator", CorrelationId: null);
    var fakeC = Runner(("Complete-GovernedCycle.ps1", _ => { WriteState(rootC, "COMPLETION_WRITTEN", "CONTROL_VALIDATION", "CHG-20260830-069"); return Ok("DB10_OUTCOME: COMPLETED\nDB10_RESULT_PASS: True\nDB10_WORKBOOK_MODIFIED: True\nDB10_EVIDENCE: state/completion.json"); }));
    var rC = OperatorCommandService.Execute(cfgC, OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!, fakeC, inputC);
    Check(rC.Result == CommandResultCode.SUCCESS && rC.NewState == "COMPLETION_WRITTEN", "DB-M12.2:N11 M10 real eligible", $"{rC.Result}/{rC.NewState}");
    Check(rC.WorkbookModified == true && rC.ResultCodeToken == "COMPLETED", "DB-M12.2:N11 M10 real writes workbook", $"{rC.WorkbookModified}/{rC.ResultCodeToken}");
}

// ---- N12. VALIDATE_WORKBOOK (M11) + periodic advisory (DB12) + git state (DB13) + lifecycle snapshot (DB14) ----
{
    string root = NewRoot("db12-m11");
    WriteState(root, "COMPLETION_WRITTEN", "CONTROL_VALIDATION", "CHG-20260830-070");
    W(root, @"state/completion.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-070\"}");
    var cfg = DevBridgeConfig.Load(root);
    var input = new LifecycleCommandInput(CommandId: "VALIDATE_WORKBOOK", NodeId: "WI-07-0.2.4", ChangeId: "CHG-20260830-070", Mode: null, Parameters: null, ExpectedCurrentState: "COMPLETION_WRITTEN", Actor: "Operator", CorrelationId: null);
    var fake11 = Runner(("Invoke-WorkbookValidation.ps1", _ => { WriteState(root, "CONTROL_VALIDATED", "VALIDATION_COMPLETE", "CHG-20260830-070"); W(root, @"tasks/WORKBOOK_CONSISTENCY_REPORT.md", "DB-M11 RESULT"); return Ok("DB11_OUTCOME: CONTROL_VALIDATED\nDB11_RESULT_PASS: True\nDB11_WORKBOOK_MODIFIED: False"); }));
    var r11 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("VALIDATE_WORKBOOK")!, fake11, input);
    Check(r11.Result == CommandResultCode.SUCCESS && r11.NewState == "CONTROL_VALIDATED", "DB-M12.2:N12 M11 validator callable", $"{r11.Result}/{r11.NewState}");
    Check(r11.GeneratedArtifacts.Any(p => p.EndsWith("WORKBOOK_CONSISTENCY_REPORT.md", StringComparison.OrdinalIgnoreCase)), "DB-M12.2:N12 M11 report artifact", string.Join("|", r11.GeneratedArtifacts));

    string rootR = NewRoot("db12-advisory");
    WriteState(rootR, "COMPLETION_WRITTEN", "CONTROL_VALIDATION", "CHG-20260830-071");
    var cfgR = DevBridgeConfig.Load(rootR);
    var fake12 = Runner(("New-ClaudeWorkbookReviewPackage.ps1", _ => Ok("DB12_OUTCOME: NO_ADVISORY_REVIEW_RECOMMENDED\nDB12_RESULT_PASS: True\nDB12_WORKBOOK_MODIFIED: False")));
    var r12 = OperatorCommandService.Execute(cfgR, OperatorCommandCatalog.Get("CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE")!, fake12);
    Check(r12.Result == CommandResultCode.SUCCESS && r12.ResultCodeToken == "NO_ADVISORY_REVIEW_RECOMMENDED" && r12.WorkbookModified == false, "DB-M12.2:N12 DB12 advisory read-only", $"{r12.Result}/{r12.ResultCodeToken}/{r12.WorkbookModified}");

    string rootG = NewRoot("db12-gitstate");
    var cfgG = DevBridgeConfig.Load(rootG);
    var fake13 = Runner(("Get-GitGateState.ps1", _ => Ok("DB13_OUTCOME: GIT_GATE_STATE_REFRESHED\nDB13_RESULT_PASS: True\nDB13_GIT_MODIFIED: False")));
    var r13 = OperatorCommandService.Execute(cfgG, OperatorCommandCatalog.Get("REFRESH_GIT_GATE_STATE")!, fake13);
    Check(r13.Result == CommandResultCode.SUCCESS && r13.GitModified == false, "DB-M12.2:N12 DB13 git refresh read-only", $"{r13.Result}/{r13.GitModified}");

    var fake14 = Runner(("Get-CurrentLifecycleState.ps1", _ => Ok("DB14_OUTCOME: LIFECYCLE_STATE_SNAPSHOT\nDB14_RESULT_PASS: True")));
    var r14 = OperatorCommandService.Execute(cfgG, OperatorCommandCatalog.Get("GET_CURRENT_LIFECYCLE_STATE")!, fake14);
    Check(r14.Result == CommandResultCode.SUCCESS && r14.ResultCodeToken == "LIFECYCLE_STATE_SNAPSHOT", "DB-M12.2:N12 DB14 lifecycle snapshot", $"{r14.Result}/{r14.ResultCodeToken}");
}

// ---- N13. command availability vocabulary (NotApplicable / Blocked / Available / HumanActionRequired / Busy) ----
{
    string root = NewRoot("db12-avail");
    WriteState(root, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-20260830-072");
    var cfg = DevBridgeConfig.Load(root);
    var run = OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!;
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, run) == CommandAvailability.NotApplicable, "DB-M12.2:N13 trial safe-stop not applicable", CommandAvailabilityEvaluator.Evaluate(cfg, run).ToString());
    WriteState(root, "VERIFIED", "CLAUDE_REVIEW", "CHG-20260830-073");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, run) == CommandAvailability.Blocked, "DB-M12.2:N13 completion blocked from verified", CommandAvailabilityEvaluator.Evaluate(cfg, run).ToString());
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RUN_VERIFICATION")!) == CommandAvailability.Available, "DB-M12.2:N13 verification available", "not available");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("GET_CURRENT_LIFECYCLE_STATE")!) == CommandAvailability.Available, "DB-M12.2:N13 lifecycle snapshot available", "not available");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CREATE_PR")!) == CommandAvailability.HumanActionRequired, "DB-M12.2:N13 guided command needs a human", "not human");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("OPEN_DETAIL")!) == CommandAvailability.HumanActionRequired, "DB-M12.2:N13 navigation is a UI action", "not human");
    var gate = WorkbookWriterGate.TryAcquire(cfg, "operator");
    Check(gate.Acquired, "DB-M12.2:N13 busy probe gate acquired", gate.Message ?? "");
    W(root, @"state/current-task.json", "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Test Task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\",\"changeId\":\"CHG-20260830-074\",\"status\":\"READY_FOR_GOVERNED_COMPLETION\",\"nextAllowedAction\":\"RUN_GOVERNED_COMPLETION\",\"mode\":\"REAL_NEXUS_DEVELOPMENT\",\"selectedAt\":\"2026-08-31T00:00:00Z\"}");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, run) == CommandAvailability.Busy, "DB-M12.2:N13 writer lock -> busy", CommandAvailabilityEvaluator.Evaluate(cfg, run).ToString());
    WorkbookWriterGate.Release(cfg);
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, run) == CommandAvailability.Available, "DB-M12.2:N13 released lock -> available", CommandAvailabilityEvaluator.Evaluate(cfg, run).ToString());
}

// ---- N14. catalogue surface: the 9 reusable commands are script-backed; no hard-coded prior WI/CHG ----
{
    string[] ids = { "RUN_VERIFICATION", "CREATE_CLAUDE_REVIEW_PACKAGE", "RECORD_CLAUDE_RESULT", "CREATE_CORRECTION_CONTEXT",
                     "RUN_GOVERNED_COMPLETION", "VALIDATE_WORKBOOK", "CREATE_CLAUDE_WORKBOOK_REVIEW_PACKAGE",
                     "REFRESH_GIT_GATE_STATE", "GET_CURRENT_LIFECYCLE_STATE" };
    foreach (var id in ids)
    {
        var c = OperatorCommandCatalog.Get(id);
        Check(c is not null && c.Kind == OperatorCommandKind.Script && c.Scripts.Length > 0 && !string.IsNullOrWhiteSpace(c.Description),
            $"DB-M12.2:N14 {id} is script-backed", c is null ? "missing" : $"{c.Kind}/{c.Scripts.Length}");
    }
    string allText = string.Join(" ", OperatorCommandCatalog.All.Values.Select(c => c.CommandId + " " + c.Description + " " + string.Join(" ", c.Scripts)));
    Check(!allText.Contains("WI-07-0.2.4", StringComparison.Ordinal) && !allText.Contains("CHG-20260830-017", StringComparison.Ordinal) && !allText.Contains("ACT-20260830-018", StringComparison.Ordinal),
        "DB-M12.2:N14 no prior WI/CHG hard-coded in the catalogue", "hard-coded id found");
}

// ==================================================================== DB-M12.4
// ---- T1. catalogue surface: CLOSE_TRIAL_CYCLE / START_NEXT_CYCLE ----
{
    var c = OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE");
    Check(c is not null && c.Kind == OperatorCommandKind.Script && c.Scripts.Length == 1 && c.Scripts[0] == "Close-TrialCycle.ps1",
        "DB-M12.4:T1 close script-backed", c is null ? "missing" : c.Scripts.Length.ToString());
    Check(c is not null && c.WritesWorkbook && c.RequiresTaskIdentity && c.RequiresUserInput && c.DangerLevel == OperatorDangerLevel.WritesWorkbook,
        "DB-M12.4:T1 close is a governed workbook writer", c is null ? "missing" : $"{c.WritesWorkbook}/{c.RequiresTaskIdentity}/{c.RequiresUserInput}/{c.DangerLevel}");
    Check(c is not null && c.RequiredStates.Contains("CLAUDE_REVIEW_PASSED_TRIAL") && c.RequiredStates.Contains("TRIAL_CYCLE_SAFE_STOP"),
        "DB-M12.4:T1 close requires trial safe-stop states", c is null ? "missing" : string.Join("|", c.RequiredStates));
    Check(c is not null && c.ResultingExpectedState == "TRIAL_CYCLE_CLOSED" && c.ExpectedCurrentState == "CLAUDE_REVIEW_PASSED_TRIAL",
        "DB-M12.4:T1 close transition contract", c is null ? "missing" : $"{c.ExpectedCurrentState}->{c.ResultingExpectedState}");

    var s = OperatorCommandCatalog.Get("START_NEXT_CYCLE");
    Check(s is not null && s.Scripts.Length == 2 && !s.WritesWorkbook && s.DangerLevel == OperatorDangerLevel.ReadOnly,
        "DB-M12.4:T1 start-next-cycle is read-only preflight", s is null ? "missing" : $"{s.WritesWorkbook}/{s.DangerLevel}");
    Check(s is not null && s.RequiredStates.Length == 1 && s.RequiredStates[0] == "TRIAL_CYCLE_CLOSED",
        "DB-M12.4:T1 start-next-cycle requires closed", s is null ? "missing" : string.Join("|", s.RequiredStates));
}

// ---- T2. TRIAL safe-stop arms CLOSE TRIAL CYCLE; M10 stays not-applicable ----
{
    string root = NewRoot("db124-safestop");
    W(root, @"config/devbridge.json", "{\"mode\":\"TRIAL\"}");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Trial task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-T124-01\",\"status\":\"CLAUDE_REVIEW_PASSED_TRIAL\",\"nextAllowedAction\":\"TRIAL_CYCLE_SAFE_STOP\","
      + "\"mode\":\"TRIAL\",\"selectedAt\":\"2026-08-31T09:00:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(s.TrialCycleSafeStop && s.TrialMode, "DB-M12.4:T2 safe-stop flag", $"status={s.Status}");
    Check(n.EnabledButtons.Contains("CLOSE_TRIAL_CYCLE"), "DB-M12.4:T2 close-trial armed at safe stop", EnabledDesc(n.EnabledButtons));
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "DB-M12.4:T2 M10 never armed", EnabledDesc(n.EnabledButtons));
    Check(!n.EnabledButtons.Contains("CREATE_PR"), "DB-M12.4:T2 no PR in trial", EnabledDesc(n.EnabledButtons));
    Check(n.Instruction.Contains("Close the trial cycle", StringComparison.Ordinal), "DB-M12.4:T2 close instruction", n.Instruction);
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!) == CommandAvailability.Available,
        "DB-M12.4:T2 close available from safe stop", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!).ToString());
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!) == CommandAvailability.NotApplicable,
        "DB-M12.4:T2 M10 not-applicable at trial safe stop", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RUN_GOVERNED_COMPLETION")!).ToString());
}

// ---- T3. TRIAL_CYCLE_CLOSED arms START NEXT CYCLE; completion stays blocked ----
{
    string root = NewRoot("db124-closed");
    W(root, @"config/devbridge.json", "{\"mode\":\"TRIAL\"}");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Trial task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-T124-01\",\"status\":\"TRIAL_CYCLE_CLOSED\",\"nextAllowedAction\":\"START_NEXT_CYCLE\","
      + "\"mode\":\"TRIAL\",\"selectedAt\":\"2026-08-31T09:00:00Z\"}");
    W(root, @"state/trial-proving-history.json", "{\"entries\":[{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-T124-01\",\"closedAtUtc\":\"2026-08-31T10:00:00Z\"}]}");
    W(root, @"state/trial-closure.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-T124-01\",\"preReservationState\":\"Planned\",\"closedAtUtc\":\"2026-08-31T10:00:00Z\"}");
    W(root, @"tasks/TRIAL_CYCLE_CLOSURE_REPORT.md", "TRIAL CYCLE CLOSED\n\nEvidence preserved.");
    var cfg = DevBridgeConfig.Load(root);
    var s = StateReader.Read(cfg);
    var n = NextActionEngine.Evaluate(s);
    Check(s.TrialCycleClosed, "DB-M12.4:T3 closed flag", s.Status ?? "null");
    Check(n.EnabledButtons.Contains("START_NEXT_CYCLE"), "DB-M12.4:T3 start-next-cycle armed", EnabledDesc(n.EnabledButtons));
    Check(!n.EnabledButtons.Contains("CLOSE_TRIAL_CYCLE"), "DB-M12.4:T3 close not re-armed", EnabledDesc(n.EnabledButtons));
    Check(!n.EnabledButtons.Contains("RUN_GOVERNED_COMPLETION"), "DB-M12.4:T3 completion never armed after closure", EnabledDesc(n.EnabledButtons));
    Check(n.Instruction.Contains("TRIAL CYCLE CLOSED", StringComparison.Ordinal), "DB-M12.4:T3 closed instruction", n.Instruction);
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.Completion && m.State == StageState.Blocked), "DB-M12.4:T3 completion blocked", "not blocked");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("START_NEXT_CYCLE")!) == CommandAvailability.Available,
        "DB-M12.4:T3 start-next-cycle available", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("START_NEXT_CYCLE")!).ToString());
}

// ---- T4. REAL mode: CLOSE_TRIAL_CYCLE prohibited (gate blocks before any script) ----
{
    string root = NewRoot("db124-real");
    W(root, @"config/devbridge.json", "{\"mode\":\"REAL_NEXUS_DEVELOPMENT\"}");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Real task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-R124-01\",\"status\":\"READY_FOR_GOVERNED_COMPLETION\",\"nextAllowedAction\":\"RUN_GOVERNED_COMPLETION\","
      + "\"mode\":\"REAL_NEXUS_DEVELOPMENT\",\"selectedAt\":\"2026-08-31T09:00:00Z\"}");
    var cfg = DevBridgeConfig.Load(root);
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!) == CommandAvailability.Blocked,
        "DB-M12.4:T4 close blocked in REAL", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!).ToString());
    var fake = Runner(("Close-TrialCycle.ps1", _ => Ok("DB24_OUTCOME: TRIAL_CYCLE_CLOSED\nDB24_RESULT_PASS: True")));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!, fake,
        new LifecycleCommandInput(CommandId: "CLOSE_TRIAL_CYCLE", NodeId: "WI-07-0.2.4", ChangeId: "CHG-R124-01", Mode: "REAL_NEXUS_DEVELOPMENT", Parameters: null, ExpectedCurrentState: "READY_FOR_GOVERNED_COMPLETION", Actor: "Operator", CorrelationId: "CORR-T4"));
    Check(r.Result == CommandResultCode.BLOCKED, "DB-M12.4:T4 execute blocked in REAL", r.Result.ToString());
    Check(fake.Invoked.Count == 0, "DB-M12.4:T4 no script run in REAL", $"{fake.Invoked.Count}");
}

// ---- T5. stale expected state for CLOSE_TRIAL_CYCLE rejected before run ----
{
    string root = NewRoot("db124-stale");
    W(root, @"config/devbridge.json", "{\"mode\":\"TRIAL\"}");
    WriteState(root, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-T124-02");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Close-TrialCycle.ps1", _ => Ok("DB24_OUTCOME: TRIAL_CYCLE_CLOSED\nDB24_RESULT_PASS: True")));
    var stale = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!, fake,
        new LifecycleCommandInput(CommandId: "CLOSE_TRIAL_CYCLE", NodeId: "WI-07-0.2.4", ChangeId: "CHG-T124-02", Mode: "TRIAL", Parameters: null, ExpectedCurrentState: "VERIFIED", Actor: "Operator", CorrelationId: null));
    Check(stale.Result == CommandResultCode.BLOCKED && stale.Message.Contains("STALE_GOVERNANCE_STATE", StringComparison.Ordinal),
        "DB-M12.4:T5 stale rejected", stale.Message);
    Check(fake.Invoked.Count == 0, "DB-M12.4:T5 stale before script", $"{fake.Invoked.Count}");
}

// ---- T6. writer serialization: CLOSE_TRIAL_CYCLE is a workbook writer ----
{
    string root = NewRoot("db124-busy");
    W(root, @"config/devbridge.json", "{\"mode\":\"TRIAL\"}");
    WriteState(root, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-T124-03");
    var cfg = DevBridgeConfig.Load(root);
    var gate = WorkbookWriterGate.TryAcquire(cfg, "operator");
    Check(gate.Acquired, "DB-M12.4:T6 probe gate acquired", gate.Message ?? "");
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!) == CommandAvailability.Busy,
        "DB-M12.4:T6 writer lock -> busy", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!).ToString());
    WorkbookWriterGate.Release(cfg);
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!) == CommandAvailability.Available,
        "DB-M12.4:T6 released -> available", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!).ToString());
    var fake = Runner(("Close-TrialCycle.ps1", _ => Ok("DB24_OUTCOME: TRIAL_CYCLE_CLOSED\nDB24_RESULT_PASS: True")));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!, fake);
    Check(r.Result == CommandResultCode.FAILED && r.Message.Contains("BACKEND_STATE_MISMATCH", StringComparison.Ordinal),
        "DB-M12.4:T6 no state refresh -> never assumed success", r.Message);
}

// ---- T7. state-first: fake closure that updates state to TRIAL_CYCLE_CLOSED succeeds ----
{
    string root = NewRoot("db124-success");
    W(root, @"config/devbridge.json", "{\"mode\":\"TRIAL\"}");
    WriteState(root, "CLAUDE_REVIEW_PASSED_TRIAL", "TRIAL_CYCLE_SAFE_STOP", "CHG-T124-04");
    var cfg = DevBridgeConfig.Load(root);
    var fake = Runner(("Close-TrialCycle.ps1", _ => { WriteState(root, "TRIAL_CYCLE_CLOSED", "START_NEXT_CYCLE", "CHG-T124-04"); return Ok("DB24_OUTCOME: TRIAL_CYCLE_CLOSED\nDB24_RESULT_PASS: True"); }));
    var r = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("CLOSE_TRIAL_CYCLE")!, fake,
        new LifecycleCommandInput(CommandId: "CLOSE_TRIAL_CYCLE", NodeId: "WI-07-0.2.4", ChangeId: "CHG-T124-04", Mode: "TRIAL", Parameters: null, ExpectedCurrentState: "CLAUDE_REVIEW_PASSED_TRIAL", Actor: "Operator", CorrelationId: "CORR-T7"));
    Check(r.Result == CommandResultCode.SUCCESS && r.NewState == "TRIAL_CYCLE_CLOSED", "DB-M12.4:T7 closure transition validated", r.Message);
    Check(r.WorkbookModified == true, "DB-M12.4:T7 workbook modified surfaced", $"{r.WorkbookModified}");
    Check(r.CorrelationId == "CORR-T7", "DB-M12.4:T7 correlation carried", r.CorrelationId);
}

// ---- T8. catalogue carries no hard-coded prior trial identity ----
{
    string allText = string.Join(" ", OperatorCommandCatalog.All.Values.Select(c => c.CommandId + " " + c.Description + " " + string.Join(" ", c.Scripts)));
    Check(!allText.Contains("WI-07-0.2.4", StringComparison.Ordinal) && !allText.Contains("CHG-20260830-017", StringComparison.Ordinal) && !allText.Contains("CHG-20260830-028", StringComparison.Ordinal),
        "DB-M12.4:T8 no prior trial identity hard-coded", "hard-coded id found");
}

// ---- DB-M15.1. governed M09 (FIX), correction NOT yet reconciled ----
// RECONCILE CORRECTION is the way out; RUN VERIFICATION must stay disabled until a
// CORRECT_CURRENT_ATTEMPT is reconciled as a detected delta (DB-M15).
{
    string root = NewRoot("m15-notreconciled");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Correction task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-M15-01\",\"status\":\"DB_M09_FIX_REQUIRED\",\"nextAllowedAction\":\"CORRECT_CURRENT_ATTEMPT\","
      + "\"dbM09\":{\"result\":\"FIX_CONTEXT_CREATED\",\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-01\"},"
      + "\"selectedAt\":\"2026-09-03T17:04:09Z\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-01\",\"decision\":\"FIX\",\"dbM09Required\":true,\"reviewedAt\":\"2026-09-03T18:30:00Z\"}");
    W(root, @"tasks/FIX_CONTEXT.md", "FIX_CONTEXT for CHG-M15-01 (CORRECT_CURRENT_ATTEMPT).");
    W(root, @"tasks/REVIEW_PACKET.md", "Review packet.");
    var s = StateReader.Read(DevBridgeConfig.Load(root));
    var n = NextActionEngine.Evaluate(s);
    Check(!s.CorrectionReconciled, "DB-M15.1: not-reconciled flag", s.CorrectionReconciled.ToString());
    Check(n.Instruction.Contains("RECONCILE CORRECTION", StringComparison.Ordinal), "DB-M15.1: reconcile instruction", n.Instruction);
    Check(SetsEqual(n.EnabledButtons, new[] { "COPY_FIX_CONTEXT", "RECONCILE_CORRECTION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }), "DB-M15.1: buttons",
        $"got [{EnabledDesc(n.EnabledButtons)}]");
    Check(!n.EnabledButtons.Contains("RUN_VERIFICATION"), "DB-M15.1: run-verify disabled pre-reconcile", "RUN_VERIFICATION enabled");
    Check(n.Stages.Any(m => m.Key == LifecycleStageKey.FixLoop && m.State == StageState.Current), "DB-M15.1: fix loop current", "fix loop not current");
}

// ---- DB-M15.2. governed M09 (FIX), correction RECONCILED (DB-M15 stamp) ----
// The corrected implementation delta was detected -> RUN VERIFICATION enables so a
// FRESH DB-M06 verifies the corrected attempt before it returns to Claude.
{
    string root = NewRoot("m15-reconciled");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Correction task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-M15-02\",\"status\":\"DB_M09_FIX_REQUIRED\",\"nextAllowedAction\":\"CORRECT_CURRENT_ATTEMPT\","
      + "\"dbM09\":{\"result\":\"FIX_CONTEXT_CREATED\",\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-02\","
      + "\"correctionReconciled\":{\"result\":\"CORRECTION_DELTA_DETECTED\",\"reconciledAtUtc\":\"2026-09-03T19:00:00Z\",\"reference\":\"manifest_current_task_delta\"}},"
      + "\"selectedAt\":\"2026-09-03T17:04:09Z\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-02\",\"decision\":\"FIX\",\"dbM09Required\":true,\"reviewedAt\":\"2026-09-03T18:30:00Z\"}");
    W(root, @"tasks/FIX_CONTEXT.md", "FIX_CONTEXT for CHG-M15-02 (CORRECT_CURRENT_ATTEMPT).");
    W(root, @"tasks/REVIEW_PACKET.md", "Review packet.");
    var s2 = StateReader.Read(DevBridgeConfig.Load(root));
    var n2 = NextActionEngine.Evaluate(s2);
    Check(s2.CorrectionReconciled, "DB-M15.2: reconciled flag", s2.CorrectionReconciled.ToString());
    Check(n2.Instruction.Contains("Run verification on the corrected delta", StringComparison.Ordinal), "DB-M15.2: re-verify instruction", n2.Instruction);
    Check(SetsEqual(n2.EnabledButtons, new[] { "RUN_VERIFICATION", "COPY_FIX_CONTEXT", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }), "DB-M15.2: buttons",
        $"got [{EnabledDesc(n2.EnabledButtons)}]");
    Check(!n2.EnabledButtons.Contains("RECONCILE_CORRECTION"), "DB-M15.2: reconcile no longer offered", "RECONCILE_CORRECTION enabled");
}

// ---- DB-M15.3. reconciled correction then FRESH DB-M06 re-verification ----
// verifiedAtUtc AFTER the Claude review -> FixReVerified: the historical FIX no
// longer blocks the normal VERIFIED flow; the corrected delta returns to Claude.
{
    string root = NewRoot("m15-reverified");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-07-0.2.4\",\"name\":\"Correction task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-M15-03\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"dbM09\":{\"result\":\"FIX_CONTEXT_CREATED\",\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-03\","
      + "\"correctionReconciled\":{\"result\":\"CORRECTION_DELTA_DETECTED\",\"reconciledAtUtc\":\"2026-09-03T19:00:00Z\"}},"
      + "\"selectedAt\":\"2026-09-03T17:04:09Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-03\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"2026-09-03T19:30:00Z\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-M15-03\",\"decision\":\"FIX\",\"dbM09Required\":true,\"reviewedAt\":\"2026-09-03T18:30:00Z\"}");
    W(root, @"tasks/FIX_CONTEXT.md", "FIX_CONTEXT for CHG-M15-03 (CORRECT_CURRENT_ATTEMPT).");
    var s3 = StateReader.Read(DevBridgeConfig.Load(root));
    var n3 = NextActionEngine.Evaluate(s3);
    Check(s3.CorrectionReconciled, "DB-M15.3: reconciled flag", s3.CorrectionReconciled.ToString());
    Check(n3.Instruction.Contains("Verification passed", StringComparison.Ordinal), "DB-M15.3: verified flow resumes", n3.Instruction);
    Check(SetsEqual(n3.EnabledButtons, new[] { "CREATE_CLAUDE_REVIEW_PACKAGE", "OPEN_VERIFICATION_REPORT", "OPEN_DETAIL" }), "DB-M15.3: buttons",
        $"got [{EnabledDesc(n3.EnabledButtons)}]");
    Check(!n3.EnabledButtons.Contains("COPY_FIX_CONTEXT") && !n3.EnabledButtons.Contains("RECONCILE_CORRECTION") && !n3.EnabledButtons.Contains("RUN_VERIFICATION"),
        "DB-M15.3: historical FIX superseded", EnabledDesc(n3.EnabledButtons));
}

// ---- DB-M15.4. RECONCILE_CORRECTION execution (catalog entry + governed route) ----
// DB-M15 (RECONCILE_CORRECTION) is only callable from DB_M09_FIX_REQUIRED and is a
// read-only reconciliation: it never writes the workbook/source/git and leaves the
// lifecycle on the M09 position until a fresh DB-M06 re-verifies the corrected delta.
{
    string root = NewRoot("db12-m15");
    WriteState(root, "DB_M09_FIX_REQUIRED", "CORRECT_CURRENT_ATTEMPT", "CHG-20260830-071");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"WI-07-0.2.4\",\"changeId\":\"CHG-20260830-071\",\"decision\":\"FIX\",\"dbM09Required\":true,\"reviewedAt\":\"2026-08-31T18:30:00Z\"}");
    W(root, @"tasks/FIX_CONTEXT.md", "fix findings for CHG-20260830-071 (CORRECT_CURRENT_ATTEMPT).");
    var cfg = DevBridgeConfig.Load(root);
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RECONCILE_CORRECTION")!) == CommandAvailability.Available,
        "DB-M15.4: reconcile available from governed M09", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RECONCILE_CORRECTION")!).ToString());
    Check(CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RUN_VERIFICATION")!) == CommandAvailability.Available,
        "DB-M15.4: run-verification available from governed M09 (executor)", CommandAvailabilityEvaluator.Evaluate(cfg, OperatorCommandCatalog.Get("RUN_VERIFICATION")!).ToString());
    var fake15 = Runner(("Confirm-CorrectedImplementation.ps1", _ => Ok("DB15_OUTCOME: CORRECTION_DELTA_DETECTED\nDB15_RESULT_PASS: True\nDB15_WORKBOOK_MODIFIED: False\nDB15_NEXUS_SOURCE_MODIFIED: False\nDB15_GIT_MODIFIED: False")));
    var r15 = OperatorCommandService.Execute(cfg, OperatorCommandCatalog.Get("RECONCILE_CORRECTION")!, fake15);
    Check(r15.Result == CommandResultCode.SUCCESS && r15.NewState == "DB_M09_FIX_REQUIRED", "DB-M15.4: reconcile success + state preserved", $"{r15.Result}/{r15.NewState}");
    Check(r15.ResultCodeToken == "CORRECTION_DELTA_DETECTED", "DB-M15.4: reconcile result code", r15.ResultCodeToken);
    Check(r15.WorkbookModified == false && r15.NexusSourceModified == false && r15.GitModified == false, "DB-M15.4: reconcile is read-only", $"{r15.WorkbookModified}/{r15.NexusSourceModified}/{r15.GitModified}");
    Check(fake15.Invoked.Count == 1 && fake15.Invoked[0] == "Confirm-CorrectedImplementation.ps1", "DB-M15.4: confirm script invoked", string.Join("|", fake15.Invoked));
}

// ---- DB-M07 POST-CORRECTION FRESHNESS (verification-cycle-aware binding) ------
// The freshness defect: after CORRECT_CURRENT_ATTEMPT, a FRESH DB-M06 verification of
// the corrected delta must invalidate the PREVIOUS Claude review package and the
// PREVIOUS Claude review as evidence for the new cycle. A package/review is valid ONLY
// when bound to the CURRENT DB-M06 verification identity (dbM07.verifiedAtUtc /
// reviewedAgainstDbM06 == verification.json verifiedAtUtc). Same node+change is NOT
// enough. Scenarios 1-11 are generic: they use their own node/change identities and
// never touch a Nexus workbook (read-only derive, asserted in scenario 11).
const string DB07_OLD = "2026-09-04T11:02:44Z"; // DB-M06 verification of the PRIOR (pre-correction) cycle
const string DB07_NEW = "2026-09-05T01:10:25Z"; // FRESH DB-M06 verification of the CORRECTED delta
string ManId(string node, string change, string v) => $"DB07-MANIFEST|{change}|{node}|{v}";

// (1) FIRST DB-M06 PASS + no package yet -> DB-M07 CREATE is ready (COPY/RECORD not yet).
{
    string root = NewRoot("fr-firstpass");
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"WI-12-0.4.1\",\"name\":\"Freshness 1\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"CHG-FRESH-001\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"selectedAt\":\"2026-09-05T01:20:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"WI-12-0.4.1\",\"changeId\":\"CHG-FRESH-001\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    var s1 = StateReader.Read(DevBridgeConfig.Load(root));
    var n1 = NextActionEngine.Evaluate(s1);
    Check(!s1.ClaudeReviewManifestReady && !s1.ClaudeReviewManifestStale && !s1.ClaudeReviewStale,
        "DB07FR(1): first pass — no manifest/review flags yet", $"{s1.ClaudeReviewManifestReady}/{s1.ClaudeReviewManifestStale}/{s1.ClaudeReviewStale}");
    Check(n1.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE"), "DB07FR(1): CREATE ready on first pass", EnabledDesc(n1.EnabledButtons));
    Check(!n1.EnabledButtons.Contains("COPY_FOR_CLAUDE") && !n1.EnabledButtons.Contains("RECORD_CLAUDE_RESULT"),
        "DB07FR(1): no COPY/RECORD before a package exists", EnabledDesc(n1.EnabledButtons));
}

// (2) Package BOUND to the CURRENT DB-M06 verification -> manifest CURRENT (COPY/RECORD).
{
    string root = NewRoot("fr-current");
    const string node = "WI-12-0.4.1";
    const string change = "CHG-FRESH-001";
    string mid = ManId(node, change, DB07_NEW);
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"" + node + "\",\"name\":\"Freshness 2\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"" + change + "\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"manifestId\":\"" + mid + "\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"},"
      + "\"selectedAt\":\"2026-09-05T01:25:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# Claude Review Manifest\n\nNode: " + node + "\nChange: " + change + "\nManifest ID: " + mid);
    var s2 = StateReader.Read(DevBridgeConfig.Load(root));
    var n2 = NextActionEngine.Evaluate(s2);
    Check(s2.ClaudeReviewManifestReady && !s2.ClaudeReviewManifestStale && s2.ClaudeReviewManifestId == mid,
        "DB07FR(2): package bound to current DB-M06 is the current manifest", $"{s2.ClaudeReviewManifestReady}/{s2.ClaudeReviewManifestId}");
    Check(SetsEqual(n2.EnabledButtons, new[] { "COPY_FOR_CLAUDE", "RECORD_CLAUDE_RESULT", "OPEN_REVIEW_PACKET", "OPEN_VERIFICATION_REPORT", "OPEN_DETAIL" }),
        "DB07FR(2): COPY/RECORD for the current manifest", $"got [{EnabledDesc(n2.EnabledButtons)}]");
    Check(!n2.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE"), "DB07FR(2): no regenerate for a current manifest", EnabledDesc(n2.EnabledButtons));
}

// (3) A recorded Claude PASS/FIX bound to the SAME verification is recognized FOR THAT
//     verification only: FIX keeps the fix loop live (3a); PASS is honored (3b).
{
    // 3a: FIX bound to the current verification stays live on the governed M09 position.
    string root = NewRoot("fr-fixbound");
    const string node = "WI-12-0.4.1";
    const string change = "CHG-FRESH-002";
    string mid = ManId(node, change, DB07_NEW);
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"" + node + "\",\"name\":\"Freshness 3a\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"" + change + "\",\"status\":\"DB_M09_FIX_REQUIRED\",\"nextAllowedAction\":\"CORRECT_CURRENT_ATTEMPT\","
      + "\"dbM09\":{\"result\":\"FIX_CONTEXT_CREATED\",\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\"},"
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"manifestId\":\"" + mid + "\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"},"
      + "\"selectedAt\":\"2026-09-05T01:30:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"decision\":\"FIX\",\"dbM09Required\":true,"
      + "\"reviewedAgainstDbM06\":\"" + DB07_NEW + "\",\"reviewedManifestId\":\"" + mid + "\",\"reviewedAt\":\"2026-09-05T02:00:00Z\"}");
    W(root, @"tasks/FIX_CONTEXT.md", "FIX_CONTEXT for " + change);
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# Claude Review Manifest\n\nNode: " + node + "\nChange: " + change + "\nManifest ID: " + mid);
    var s3a = StateReader.Read(DevBridgeConfig.Load(root));
    var n3a = NextActionEngine.Evaluate(s3a);
    Check(!s3a.ClaudeReviewStale, "DB07FR(3a): FIX bound to current verification is NOT stale", s3a.ClaudeReviewStale.ToString());
    Check(SetsEqual(n3a.EnabledButtons, new[] { "COPY_FIX_CONTEXT", "RECONCILE_CORRECTION", "OPEN_REVIEW_PACKET", "OPEN_DETAIL" }),
        "DB07FR(3a): live FIX keeps the correction loop", $"got [{EnabledDesc(n3a.EnabledButtons)}]");
    Check(n3a.Stages.Any(m => m.Key == LifecycleStageKey.FixLoop && m.State == StageState.Current), "DB07FR(3a): fix loop current", "not current");
}
{
    // 3b: PASS bound to the current verification is honored (drives the trial-stop path).
    string root = NewRoot("fr-passbound");
    const string node = "WI-12-0.4.1";
    const string change = "CHG-FRESH-003";
    string mid = ManId(node, change, DB07_NEW);
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"" + node + "\",\"name\":\"Freshness 3b\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"" + change + "\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"mode\":\"TRIAL\","
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"manifestId\":\"" + mid + "\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"},"
      + "\"selectedAt\":\"2026-09-05T01:35:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"decision\":\"PASS\",\"dbM09Required\":false,"
      + "\"reviewedAgainstDbM06\":\"" + DB07_NEW + "\",\"reviewedManifestId\":\"" + mid + "\",\"reviewedAt\":\"2026-09-05T02:10:00Z\"}");
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# Claude Review Manifest\n\nNode: " + node + "\nChange: " + change + "\nManifest ID: " + mid);
    W(root, @"tasks/REVIEW_PACKET.md", "cover");
    var s3b = StateReader.Read(DevBridgeConfig.Load(root));
    var n3b = NextActionEngine.Evaluate(s3b);
    Check(!s3b.ClaudeReviewStale && s3b.ClaudeReviewManifestReady, "DB07FR(3b): PASS bound to current verification is current", $"{s3b.ClaudeReviewStale}/{s3b.ClaudeReviewManifestReady}");
    Check(n3b.Instruction.Contains("Trial PASS accepted", StringComparison.Ordinal), "DB07FR(3b): bound PASS is honored", n3b.Instruction);
}

// (4)(5)(6)(7)(9)(10)(11) CORRECTION LOOP core: after CORRECT_CURRENT_ATTEMPT a FRESH
// DB-M06 re-verifies the SAME node+change. The previous package + previous review are
// now STALE evidence (scenarios 4/5), CREATE re-enables (6), COPY/RECORD stay disabled
// (7), historical evidence is preserved read-only (9), identity is generic (10), and no
// Nexus/workbook is ever touched (11).
{
    string root = NewRoot("fr-stalecore");
    const string node = "WI-12-0.4.1";
    const string change = "CHG-FRESH-002";      // SAME node+change across both verification cycles
    string staleId = ManId(node, change, DB07_OLD);
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"" + node + "\",\"name\":\"Correction task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"" + change + "\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"manifestId\":\"" + staleId + "\",\"verifiedAtUtc\":\"" + DB07_OLD + "\"},"
      + "\"dbM09\":{\"result\":\"FIX_CONTEXT_CREATED\",\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\","
      + "\"correctionReconciled\":{\"result\":\"CORRECTION_DELTA_DETECTED\",\"reconciledAtUtc\":\"2026-09-04T23:00:00Z\"}},"
      + "\"selectedAt\":\"2026-09-04T17:00:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"decision\":\"FIX\",\"dbM09Required\":true,"
      + "\"reviewedAgainstDbM06\":\"" + DB07_OLD + "\",\"reviewedManifestId\":\"" + staleId + "\",\"reviewedAt\":\"2026-09-04T13:06:46Z\"}");
    // Historical evidence on disk: the PRIOR-cycle manifest file + its legacy cover
    // pointer + the recorded FIX report. None may be deleted by the derive.
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# Claude Review Manifest\n\nNode: " + node + "\nChange: " + change + "\nManifest ID: " + staleId + "\nDB-M06 verified (utc): " + DB07_OLD);
    W(root, @"tasks/REVIEW_PACKET.md", "legacy cover pointer for the STALE package");
    W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "FIX\nCLAUDE_FIX_REQUIRED");
    W(root, @"tasks/FIX_CONTEXT.md", "FIX_CONTEXT for " + change);
    var before = Directory.GetFiles(root, "*", SearchOption.AllDirectories)
        .Select(p => Path.GetRelativePath(root, p)).OrderBy(x => x, StringComparer.Ordinal).ToArray();

    var s4 = StateReader.Read(DevBridgeConfig.Load(root));
    var n4 = NextActionEngine.Evaluate(s4);
    var display = StageDisplayResolver.Resolve(s4, n4);

    Check(!s4.ClaudeReviewManifestReady && s4.ClaudeReviewManifestStale,
        "DB07FR(4): same node+change package is STALE after fresh DB-M06", $"{s4.ClaudeReviewManifestReady}/{s4.ClaudeReviewManifestStale}");
    Check(s4.ClaudeReviewStale, "DB07FR(5): same node+change Claude result is STALE after fresh DB-M06", s4.ClaudeReviewStale.ToString());
    Check(n4.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE"), "DB07FR(6): CREATE CLAUDE REVIEW PACKAGE re-enabled after corrected verification", EnabledDesc(n4.EnabledButtons));
    Check(!n4.EnabledButtons.Contains("COPY_FOR_CLAUDE") && !n4.EnabledButtons.Contains("RECORD_CLAUDE_RESULT"),
        "DB07FR(7): COPY/RECORD disabled while the package is stale", EnabledDesc(n4.EnabledButtons));
    var pkgRow = display.First(r => r.Key == "CLAUDE_REVIEW_PACKAGE");
    var claudeRow = display.First(r => r.Key == "CLAUDE_REVIEW");
    Check(pkgRow.Token != StageDisplayResolver.Pass && pkgRow.Token == StageDisplayResolver.Ready,
        "DB07FR(4b): stale package never renders PASS (READY to regenerate)", $"{pkgRow.Token}");
    Check(claudeRow.Token != StageDisplayResolver.Pass, "DB07FR(5b): stale review never renders PASS on the Claude stage", claudeRow.Token);
    Check(n4.Instruction.Contains("Review this task in Claude", StringComparison.Ordinal), "DB07FR(6b): corrected delta awaits a FRESH review", n4.Instruction);

    // (9) Historical evidence preserved: old package + old review remain on disk intact.
    Check(File.Exists(Path.Combine(root, "tasks", "CLAUDE_REVIEW_PACKAGE.md")) && File.ReadAllText(Path.Combine(root, "tasks", "CLAUDE_REVIEW_PACKAGE.md")).Contains("Manifest ID: " + staleId),
        "DB07FR(9): historical package preserved", "missing/changed");
    Check(File.Exists(Path.Combine(root, "state", "claude-review.json")) && File.ReadAllText(Path.Combine(root, "state", "claude-review.json")).Contains(DB07_OLD),
        "DB07FR(9b): historical Claude review preserved", "missing/changed");

    // (10) Genericness: WI-12-0.4.1/CHG-FRESH-002 are our own identities (not the
    // shared WI-07 fixture id); staleness is derived from the DB-M06 binding mismatch,
    // never from matching a hard-coded node/change.

    // (11) Read-only derive: evaluating state never creates/deletes a file, never
    // touches a Nexus workbook.
    var after = Directory.GetFiles(root, "*", SearchOption.AllDirectories)
        .Select(p => Path.GetRelativePath(root, p)).OrderBy(x => x, StringComparer.Ordinal).ToArray();
    Check(before.SequenceEqual(after), "DB07FR(11): derive is read-only — no file created/deleted", $"before {before.Length} after {after.Length}");
    Check(!after.Any(p => p.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase) || p.Contains("Nexus", StringComparison.OrdinalIgnoreCase)),
        "DB07FR(11b): no workbook/Nexus mutation during derive", string.Join(",", after));
}

// (5 again) A stale PASS (not just a stale FIX) must also be superseded: the corrected
// delta returns to Claude rather than riding an old PASS toward completion.
{
    string root = NewRoot("fr-stalepass");
    const string node = "WI-12-0.4.1";
    const string change = "CHG-FRESH-003";     // SAME node+change
    string staleId = ManId(node, change, DB07_OLD);
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"" + node + "\",\"name\":\"Stale pass\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"" + change + "\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"manifestId\":\"" + staleId + "\",\"verifiedAtUtc\":\"" + DB07_OLD + "\"},"
      + "\"selectedAt\":\"2026-09-04T17:00:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    W(root, @"state/claude-review.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"decision\":\"PASS\",\"dbM09Required\":false,"
      + "\"reviewedAgainstDbM06\":\"" + DB07_OLD + "\",\"reviewedManifestId\":\"" + staleId + "\",\"reviewedAt\":\"2026-09-04T13:10:00Z\"}");
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# Claude Review Manifest\n\nNode: " + node + "\nChange: " + change + "\nManifest ID: " + staleId);
    W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "PASS\n\nNo blocking findings.");
    var s5 = StateReader.Read(DevBridgeConfig.Load(root));
    var n5 = NextActionEngine.Evaluate(s5);
    Check(s5.ClaudeReviewStale, "DB07FR(5c): old PASS bound to previous DB-M06 is stale", s5.ClaudeReviewStale.ToString());
    Check(n5.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE") && !n5.EnabledButtons.Contains("COPY_FOR_CLAUDE"),
        "DB07FR(5d): stale PASS does not unlock COPY — fresh review required", EnabledDesc(n5.EnabledButtons));
    Check(!n5.Instruction.Contains("PASS accepted", StringComparison.OrdinalIgnoreCase) && !n5.Instruction.Contains("governed completion", StringComparison.OrdinalIgnoreCase),
        "DB07FR(5e): stale PASS is never honored toward completion", n5.Instruction);
}

// (8) A FRESH package generated against the LATEST DB-M06 restores currency: dbM07
// stamp bound to DB07_NEW -> manifest CURRENT again, COPY/RECORD unlock, and the OLD
// review stays historical (does not drag the cycle back onto the fix loop).
{
    string root = NewRoot("fr-regen");
    const string node = "WI-12-0.4.1";
    const string change = "CHG-FRESH-002";     // SAME node+change as the core correction scenario
    string freshId = ManId(node, change, DB07_NEW);
    W(root, @"state/current-task.json",
        "{\"nodeId\":\"" + node + "\",\"name\":\"Correction task\",\"nodeType\":\"WorkItem\",\"phase\":\"P0\",\"layer\":\"App\","
      + "\"changeId\":\"" + change + "\",\"status\":\"VERIFIED\",\"nextAllowedAction\":\"CLAUDE_REVIEW\","
      + "\"dbM07\":{\"ready\":true,\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"manifestId\":\"" + freshId + "\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"},"
      + "\"selectedAt\":\"2026-09-05T01:40:00Z\"}");
    W(root, @"state/verification.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"primaryResult\":\"VERIFICATION_PASSED\",\"verifiedAtUtc\":\"" + DB07_NEW + "\"}");
    // The OLD FIX review record is still on disk — it must now read as HISTORICAL and
    // must NOT force the corrected delta back onto the fix loop.
    W(root, @"state/claude-review.json", "{\"nodeId\":\"" + node + "\",\"changeId\":\"" + change + "\",\"decision\":\"FIX\",\"dbM09Required\":true,"
      + "\"reviewedAgainstDbM06\":\"" + DB07_OLD + "\",\"reviewedManifestId\":\"" + ManId(node, change, DB07_OLD) + "\",\"reviewedAt\":\"2026-09-04T13:06:46Z\"}");
    W(root, @"tasks/CLAUDE_REVIEW_PACKAGE.md", "# Claude Review Manifest\n\nNode: " + node + "\nChange: " + change + "\nManifest ID: " + freshId + "\nDB-M06 verified (utc): " + DB07_NEW);
    W(root, @"tasks/REVIEW_PACKET.md", "cover pointer");
    W(root, @"tasks/CLAUDE_REVIEW_RESULT.md", "FIX\nCLAUDE_FIX_REQUIRED");
    var s8 = StateReader.Read(DevBridgeConfig.Load(root));
    var n8 = NextActionEngine.Evaluate(s8);
    Check(s8.ClaudeReviewManifestReady && !s8.ClaudeReviewManifestStale && s8.ClaudeReviewManifestId == freshId,
        "DB07FR(8): fresh package binds to the LATEST DB-M06", $"{s8.ClaudeReviewManifestReady}/{s8.ClaudeReviewManifestId}");
    Check(s8.ClaudeReviewStale, "DB07FR(8b): OLD review stays historical after regeneration", s8.ClaudeReviewStale.ToString());
    Check(SetsEqual(n8.EnabledButtons, new[] { "COPY_FOR_CLAUDE", "RECORD_CLAUDE_RESULT", "OPEN_REVIEW_PACKET", "OPEN_VERIFICATION_REPORT", "OPEN_DETAIL" }),
        "DB07FR(8c): fresh manifest unlocks COPY/RECORD (old FIX does not block)", $"got [{EnabledDesc(n8.EnabledButtons)}]");
    Check(!n8.EnabledButtons.Contains("CREATE_CLAUDE_REVIEW_PACKAGE"), "DB07FR(8d): CREATE not re-offered for a current manifest", EnabledDesc(n8.EnabledButtons));
    Check(!n8.EnabledButtons.Contains("COPY_FIX_CONTEXT") && !n8.EnabledButtons.Contains("RECONCILE_CORRECTION"),
        "DB07FR(8e): historical FIX never re-arms the correction loop", EnabledDesc(n8.EnabledButtons));
    Check(n8.Instruction.Contains("Review this task in Claude", StringComparison.Ordinal), "DB07FR(8f): corrected delta is ready for a FRESH Claude review", n8.Instruction);
}

// ==================================================================== report
Console.WriteLine();
Console.WriteLine("================================================================");
Console.WriteLine(" DB-M12 FIXTURE RUNNER — representative DevBridge states");
Console.WriteLine("================================================================");
foreach (var f in failures) Console.WriteLine(f);
Console.WriteLine();
Console.WriteLine($"TOTAL  : {pass + fail} checks");
Console.WriteLine($"PASSED : {pass}");
Console.WriteLine($"FAILED : {fail}");
Console.WriteLine(pass > 0 && fail == 0 ? "RESULT : ALL PASS" : "RESULT : FAILURES PRESENT");
Environment.ExitCode = fail == 0 ? 0 : 1;

// Faked backend script runner for DB-M12.1 tests. Behaviors are keyed by script
// basename; each scenario decides whether the "backend" writes state files, times
// out, or reports a governed STOP — exactly the surface the real scripts expose.
sealed class FakeScriptRunner : IScriptProcessRunner
{
    private readonly Dictionary<string, Func<string, ScriptRunOutcome>> _behaviors;

    public List<string> Invoked { get; } = new();

    /// <summary>DB-M12.2: the one-command environment channel handed to each run.</summary>
    public List<IReadOnlyDictionary<string, string>?> Environments { get; } = new();

    public FakeScriptRunner(Dictionary<string, Func<string, ScriptRunOutcome>>? behaviors = null)
        => _behaviors = behaviors ?? new Dictionary<string, Func<string, ScriptRunOutcome>>(StringComparer.OrdinalIgnoreCase);

    public ScriptRunOutcome Run(string scriptPath, int timeoutMs, IReadOnlyDictionary<string, string>? environment = null)
    {
        string name = Path.GetFileName(scriptPath);
        Invoked.Add(name);
        Environments.Add(environment);
        return _behaviors.TryGetValue(name, out var behavior)
            ? behavior(scriptPath)
            : new ScriptRunOutcome(false, -1, "", $"no fake behavior for {name}", TimeSpan.Zero, false);
    }
}
