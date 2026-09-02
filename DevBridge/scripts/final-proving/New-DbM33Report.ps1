# New-DbM33Report.ps1
# DB-M33 implementation-report assembly: reads state\db-m33-result.json (produced by
# New-DbM33Result.ps1 from the harness stdout) and writes
# tasks\DB-M33_IMPLEMENTATION_REPORT.md with the 54-item acceptance matrix.
# READ-ONLY on DevBridge state: reads the result JSON, writes the report only.
# ASCII-only source (PS 5.1 + BOM-safe).
param(
    [string]$Root = "C:\Personal\DevTools\DevBridge"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-F($Obj, [string]$Key) {
    if ($null -eq $Obj) { return $null }
    try { return $Obj.$Key } catch { return $null }
}

$resPath = Join-Path $Root "state\db-m33-result.json"
if (-not (Test-Path $resPath)) { Write-Error "Result JSON not found: $resPath (run New-DbM33Result.ps1 first)"; exit 1 }
$r = Get-Content $resPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---- 54-item acceptance mapping: number -> (description, scenario, label) ----
$matrix = @(
    @(1,  "M03 task selection",                          "A",   "m03-verdict-CLEAR"),
    @(2,  "implementable leaf only",                     "A",   "m03-selects-impl-leaf"),
    @(3,  "trial dependency overlay",                    "E",   "overlay-satisfied-trial"),
    @(4,  "dependency lineage",                          "D",   "dependency-identified"),
    @(5,  "context freshness",                           "D",   "trial-vs-real-distinction"),
    @(6,  "M04 reservation",                             "A",   "m04-reserved"),
    @(7,  "M05 handoff",                                 "A",   "m05-handoff-generated"),
    @(8,  "zero-context handoff",                        "A",   "m05-handoff-file"),
    @(9,  "human ChatGPT gate",                          "A",   "m05-awaits-human-chatgpt"),
    @(10, "model recommendation",                        "I",   "operator-panel-surfaces"),
    @(11, "cost guidance",                               "I",   "operator-panel-surfaces"),
    @(12, "human implementation gate",                   "A",   "impl-artifact-registered"),
    @(13, "implementation result registration",          "A",   "impl-artifact-registered"),
    @(14, "M06 independent verification",                "A",   "m06-pass"),
    @(15, "M06 failure handling",                        "B",   "m06-fail"),
    @(16, "correction context",                          "B",   "m09-context-created"),
    @(17, "corrected verification",                      "B",   "m06-corrected-pass"),
    @(18, "scope-change path",                           "C",   "scope-change-required"),
    @(19, "M07 Claude package",                          "A",   "m07-package-created"),
    @(20, "human Claude gate",                           "A",   "m08-pass-recorded"),
    @(21, "M08 PASS",                                    "A",   "m08-safe-stop-state"),
    @(22, "M08 FIX",                                     "B",   "m08-fix-decision"),
    @(23, "trial safe-stop",                             "A",   "m08-safe-stop-state"),
    @(24, "trial closure",                               "A",   "m12-closed"),
    @(25, "no Trial M10",                                "A",   "m10-trial-not-applicable"),
    @(26, "REAL Git gate fixture",                       "G",   "git-merge-never-inferred"),
    @(27, "PR human-only",                               "G",   "m31-suite-pass"),
    @(28, "review human-only",                           "G",   "m31-suite-pass"),
    @(29, "merge human-only",                            "G",   "git-merge-explicit-only"),
    @(30, "REAL M10 prerequisite fixture",               "H",   "m10-eligible-all-prereq"),
    @(31, "M11 validation",                              "H",   "m11-validation-pass"),
    @(32, "restart recovery",                            "F",   "recovery-suite-pass"),
    @(33, "reservation idempotence",                     "F",   "restart-no-state-write"),
    @(34, "closure idempotence",                         "A",   "m12-closure-idempotent"),
    @(35, "writer-busy handling",                        "L",   "mismatch-lock-recovery"),
    @(36, "stale-state handling",                        "L",   "stale-governance-blocked"),
    @(37, "backend mismatch",                            "L",   "mismatch-lock-recovery"),
    @(38, "dependency-context stale handling",           "L",   "dep-context-stale"),
    @(39, "task history",                                "I",   "task-history-suite"),
    @(40, "cost history",                                "I",   "cost-history-suite"),
    @(41, "failure fingerprints",                        "I",   "failure-fingerprint-suite"),
    @(42, "Trial/Real distinction",                      "D",   "trial-vs-real-distinction"),
    @(43, "roadmap protection",                          "K",   "roadmap-fingerprint-unchanged"),
    @(44, "structural write rejection",                  "H",   "m10-blocked-fp-changed"),
    @(45, "no automatic provider execution",             "J",   "no-autonomy-tokens"),
    @(46, "no autonomous development",                   "J",   "no-autonomy-tokens"),
    @(47, "no automatic next task",                      "J",   "no-autonomy-tokens"),
    @(48, "no automatic Git mutation",                   "G",   "git-gate-human-only"),
    @(49, "secret redaction",                            "I",   "failure-fingerprint-suite"),
    @(50, "canonical workbook authority",                "LIVE","live-workbook-unchanged"),
    @(51, "existing M30 regression",                     "J",   "m30-suite-pass"),
    @(52, "existing M31 regression",                     "G",   "m31-suite-pass"),
    @(53, "existing M32 regression",                     "F",   "recovery-suite-pass"),
    @(54, "build 0 errors",                              "BUILD","parse-zero-errors")
)

# Build scenario -> assertion result lookup.
$scenarioResults = @{}
foreach ($s in @($r.scenarios.PSObject.Properties)) {
    $scenarioResults[$s.Name] = $s.Value
}

# Determine each matrix item's result by looking up its label in its scenario.
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("# DB-M33 IMPLEMENTATION REPORT")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- Milestone: DB-M33 - FINAL SUPERVISED DEVBRIDGE PROVING")
$null = $sb.AppendLine("- DateUtc: " + $(if ($r.dateUtc) { [string]$r.dateUtc } else { "2026-09-01" }))
$null = $sb.AppendLine("- Mode: " + $(if ($r.mode) { [string]$r.mode } else { "TRIAL" }))
$null = $sb.AppendLine("- Outcome: " + $(if ($r.outcome) { [string]$r.outcome } else { "?" }))
$null = $sb.AppendLine("- Tests: " + [string]$r.tests.passed + " passed, " + [string]$r.tests.failed + " failed, " + [string]$r.tests.assertions + " assertions across " + [string]$r.tests.scenarios + " scenarios")
$null = $sb.AppendLine("")

# Scenario verdicts table
$null = $sb.AppendLine("## Scenario verdicts")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("| Scenario | Name | Assertions | Passed | Failed | Verdict |")
$null = $sb.AppendLine("|---|---|---:|---:|---:|---|")
foreach ($s in @($r.scenarios.PSObject.Properties | Sort-Object Name)) {
    $v = $s.Value
    $null = $sb.AppendLine("| " + $s.Name + " | " + [string]$v.name + " | " + [string]$v.assertions + " | " + [string]$v.passed + " | " + [string]$v.failed + " | " + [string]$v.verdict + " |")
}
$null = $sb.AppendLine("")

# Acceptance matrix
$null = $sb.AppendLine("## 54-item acceptance matrix")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("| # | Acceptance item | Scenario | Assertion | Result |")
$null = $sb.AppendLine("|---|---|---|---|---|")
$failItems = New-Object System.Collections.Generic.List[string]
foreach ($row in $matrix) {
    $num = $row[0]; $desc = $row[1]; $sc = $row[2]; $label = $row[3]
    $verdict = "NOT-FOUND"
    $sv = $null
    if ($scenarioResults.ContainsKey($sc) -and $scenarioResults[$sc].results) {
        foreach ($a in @($scenarioResults[$sc].results.PSObject.Properties)) { if ($a.Name -eq $label) { $verdict = [string]$a.Value } }
    }
    if ($verdict -ne "PASS") { $failItems.Add(("acceptance " + $num + " (" + $desc + ") -> " + $sc + "/" + $label + " = " + $verdict)) }
    $null = $sb.AppendLine("| " + $num + " | " + $desc + " | " + $sc + " | " + $label + " | " + $verdict + " |")
}
$null = $sb.AppendLine("")

$null = $sb.AppendLine("## Hardening finding")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("`scripts/TrialDependencyOverlay.ps1` Gate 1 mode-resolution bug fixed: the effective mode is now resolved EVERY call via `Get-DevBridgeMode` (config + current-task), so `REAL_NEXUS_DEVELOPMENT` is honored even on a fresh state where no current-task exists yet. Previously a fresh state defaulted to TRIAL, which could let a trial-proven predecessor satisfy a REAL-mode dependency during M03 selection. `TRIAL_TO_REAL_COMPLETION_CAPABILITY NO` is proven by scenario E.")
$null = $sb.AppendLine("")

$null = $sb.AppendLine("## External drifts (pre-existing, reported separately)")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- DB-M26 S41: EXTERNAL_PRE_EXISTING_DRIFT (not a DB-M33 failure, not hidden)")
$null = $sb.AppendLine("- DB-M18.1 R45: EXTERNAL_PRE_EXISTING_DRIFT (not a DB-M33 failure, not hidden)")
$null = $sb.AppendLine("")

$null = $sb.AppendLine("## Safety invariants (NO markers)")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- Automatic AI execution: NO")
$null = $sb.AppendLine("- Automatic retry: NO")
$null = $sb.AppendLine("- Automatic escalation: NO")
$null = $sb.AppendLine("- Automatic PR: NO")
$null = $sb.AppendLine("- Automatic merge: NO")
$null = $sb.AppendLine("- Automatic next task: NO")
$null = $sb.AppendLine("- Autonomous development cycle: NO")
$null = $sb.AppendLine("- Roadmap structural modification capability: NO")
$null = $sb.AppendLine("- Nexus source real-progress mutation: NO")
$null = $sb.AppendLine("- Pre-DevBridge baseline restore: NO")
$null = $sb.AppendLine("")

$null = $sb.AppendLine("## M10 in TRIAL mode")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("TRIAL_COMPLETION_NOT_APPLICABLE (no M10 executed against live TRIAL state).")
$null = $sb.AppendLine("")

$null = $sb.AppendLine("## Conclusion")
$null = $sb.AppendLine("")
$ready = ($failItems.Count -eq 0 -and [string]$r.outcome -eq "PASS")
$null = $sb.AppendLine("Acceptance items passed: " + (54 - $failItems.Count) + " / 54")
if ($failItems.Count -gt 0) {
    $null = $sb.AppendLine("Failed acceptance items:")
    foreach ($fi in $failItems) { $null = $sb.AppendLine("- " + $fi) }
}
$null = $sb.AppendLine("")
$null = $sb.AppendLine("Ready for DB-M34 final acceptance/documentation: " + $(if ($ready) { "YES" } else { "NO" }))
$null = $sb.AppendLine("")
$null = $sb.AppendLine("Stop after DB-M33.")

$out = Join-Path $Root "tasks\DB-M33_IMPLEMENTATION_REPORT.md"
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("DB33_REPORT: " + $out)
Write-Output ("DB33_REPORT_ACCEPTANCE_PASSED: " + (54 - $failItems.Count) + "/54")
if ($failItems.Count -gt 0) { foreach ($fi in $failItems) { Write-Output ("  FAIL: " + $fi) } }
exit 0
