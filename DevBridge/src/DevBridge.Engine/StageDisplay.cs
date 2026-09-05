// StageDisplay.cs — DB-M12.3 full-UI lifecycle visualization mapping.
//
// The engine's next-action engine exposes an 11-stage list carrying the 5-value
// StageState vocabulary (Complete/Current/Waiting/Failed/Blocked). The DB-M12.3
// mission requires the operator console to display the lifecycle as 12 stages
// with an 8-token display vocabulary:
//   NOT_STARTED / READY / CURRENT / PASS / FAIL / BLOCKED / HUMAN_ACTION / NOT_APPLICABLE
//
// This resolver performs the mapping IN THE ENGINE (backend decides, UI renders
// backend truth). The UI never invents a stage or a token. Everything is derived
// from the DevBridgeState snapshot (artifacts, mode, git gate, M10 eligibility,
// M11 advisory recommendation) plus the engine's own stage markers.
//
// READY vs NOT_STARTED: among engine-backed stages still Waiting, the FIRST one
// in display order is the immediate next actionable step (READY); every later
// Waiting stage is NOT_STARTED. Stages the mission marks as conditional
// (Correction, Human Git Gate, Governed Completion in trial, Periodic review)
// are resolved directly from state and fall back to NOT_APPLICABLE when they do
// not apply to the current cycle.
using System;
using System.Collections.Generic;
using System.Linq;

namespace DevBridge.Engine;

/// <summary>One display row of the 12-stage lifecycle visualization.</summary>
public sealed record StageDisplayRow(string Key, string Label, string Token, int Order);

public static class StageDisplayResolver
{
    /// <summary>The 8 display tokens the mission requires.</summary>
    public const string NotStarted = "NOT_STARTED";
    public const string Ready = "READY";
    public const string Current = "CURRENT";
    public const string Pass = "PASS";
    public const string Fail = "FAIL";
    public const string Blocked = "BLOCKED";
    public const string HumanAction = "HUMAN_ACTION";
    public const string NotApplicable = "NOT_APPLICABLE";

    // Provisional token used while mapping engine Waiting stages before the
    // first-ready split below.
    private const string WaitingPlaceholder = "WAITING_PLACEHOLDER";

    /// <summary>The 12 stages, in display order (mission naming, verbatim).</summary>
    public static readonly (string Key, string Label, LifecycleStageKey? Backing)[] Catalog =
    {
        ("PREFLIGHT", "Preflight", LifecycleStageKey.Preflight),
        ("RESERVATION", "Reservation", LifecycleStageKey.Reservation),
        ("CHATGPT_HANDOFF", "ChatGPT Handoff", LifecycleStageKey.ChatGpt),
        ("IMPLEMENTATION", "Implementation", LifecycleStageKey.DeepSeek),
        ("VERIFICATION", "Verification", LifecycleStageKey.Verification),
        ("CLAUDE_REVIEW_PACKAGE", "Claude Review Package", null),      // artifact-derived
        ("CLAUDE_REVIEW", "Claude Review", LifecycleStageKey.Claude),
        ("CORRECTION", "Correction if required", LifecycleStageKey.FixLoop),
        ("HUMAN_GIT_GATE", "Human Git Gate", null),                    // mode/git-state-derived
        ("GOVERNED_COMPLETION", "Governed Completion", null),          // M10-trial-derived + engine marker
        ("WORKBOOK_VALIDATION", "Workbook Validation", LifecycleStageKey.ControlValidation),
        ("PERIODIC_WORKBOOK_REVIEW", "Periodic Claude Workbook Review", null), // DB-M11 derived
    };

    /// <summary>Resolve the 12-stage display from the backend snapshot + engine markers.</summary>
    public static IReadOnlyList<StageDisplayRow> Resolve(DevBridgeState s, NextActionInfo next)
    {
        var rows = new List<StageDisplayRow>();
        var engine = next.Stages.ToDictionary(x => x.Key, x => x.State);
        StageState? Engine(LifecycleStageKey key) => engine.TryGetValue(key, out var st) ? st : null;

        for (int i = 0; i < Catalog.Length; i++)
        {
            var (key, label, backing) = Catalog[i];
            string token = NotStarted;
            if (backing is not null)
            {
                token = MapEngineState(Engine(backing.Value));
            }
            else
            {
                token = key switch
                {
                    "CLAUDE_REVIEW_PACKAGE" => ResolveClaudeReviewPackage(s, Engine),
                    "HUMAN_GIT_GATE" => ResolveHumanGitGate(s),
                    "GOVERNED_COMPLETION" => ResolveGovernedCompletion(s, Engine),
                    "PERIODIC_WORKBOOK_REVIEW" => ResolvePeriodicWorkbookReview(s),
                    _ => NotStarted,
                };
            }
            rows.Add(new StageDisplayRow(key, label, token, i));
        }

        // READY split: the first still-waiting engine-backed stage is the immediate
        // next actionable step; all later waiting stages are NOT_STARTED.
        bool readyAssigned = false;
        for (int i = 0; i < rows.Count; i++)
        {
            if (rows[i].Token != WaitingPlaceholder) continue;
            rows[i] = rows[i] with
            {
                Token = readyAssigned ? NotStarted : Ready,
            };
            readyAssigned = true;
        }

        return rows;
    }

    private static string MapEngineState(StageState? state) => state switch
    {
        StageState.Complete => Pass,
        StageState.Current => Current,
        StageState.Failed => Fail,
        StageState.Blocked => Blocked,
        StageState.Waiting => WaitingPlaceholder,
        _ => NotStarted,
    };

    /// <summary>Claude Review Package: PASS only for the CURRENT manifest (dbM07 stamp
    /// bound to the current DB-M06 verification). A stamped package bound to an OLDER
    /// DB-M06 (a previous correction cycle) is stale and must be REGENERATED, so it
    /// never renders PASS — even though its legacy REVIEW_PACKET.md cover pointer is
    /// still on disk. Legacy pre-stamp artifacts (REVIEW_PACKET.md alone, no dbM07) keep
    /// their historical PASS. READY once verification has passed and (re)generation of
    /// the package is the immediate next step.</summary>
    private static string ResolveClaudeReviewPackage(DevBridgeState s, Func<LifecycleStageKey, StageState?> engine)
    {
        if (s.ClaudeReviewManifestReady) return Pass;   // CURRENT manifest (dbM07 stamp for this node/change, bound to current DB-M06)
        // A stale stamped package carries its legacy REVIEW_PACKET.md/CLAUDE_REVIEW_PROMPT.md
        // cover pointer too; that must NOT be mistaken for a current package.
        if (!s.ClaudeReviewManifestStale && (s.Artifacts.ReviewPacket || s.Artifacts.ClaudeReviewPrompt)) return Pass; // legacy artifact present
        if (engine(LifecycleStageKey.Verification) == StageState.Complete
            || engine(LifecycleStageKey.Claude) == StageState.Current
            || engine(LifecycleStageKey.Claude) == StageState.Complete) return Ready;
        return NotStarted;
    }

    /// <summary>Human Git Gate: NOT_APPLICABLE in trial; PASS once the merge is
    /// confirmed; HUMAN_ACTION while any human git gate is pending; READY as the
    /// gate approaches.</summary>
    private static string ResolveHumanGitGate(DevBridgeState s)
    {
        if (s.TrialMode) return NotApplicable;
        switch (s.HumanGitState)
        {
            case HumanGitGateState.Merged:
            case HumanGitGateState.ReadyForGovernedCompletion:
                return Pass;
            case HumanGitGateState.AwaitingHumanPr:
            case HumanGitGateState.PrOpen:
            case HumanGitGateState.AwaitingHumanReview:
            case HumanGitGateState.AwaitingHumanMerge:
            case HumanGitGateState.ClaudeReviewPassed:
                return HumanAction;
            case HumanGitGateState.ImplementationComplete:
            case HumanGitGateState.VerificationPassed:
                return Ready;
            default:
                return NotApplicable;
        }
    }

    /// <summary>Governed Completion: NOT_APPLICABLE for disposable trial evidence;
    /// otherwise the engine's own completion marker (already M10-gated).</summary>
    private static string ResolveGovernedCompletion(DevBridgeState s, Func<LifecycleStageKey, StageState?> engine)
    {
        bool trialNotApplicable = s.TrialMode
            && (s.TrialCycleSafeStop
                || s.M10Eligibility?.Token == M10CompletionEligibility.TrialCompletionNotApplicableToken);
        if (trialNotApplicable) return NotApplicable;
        return MapEngineState(engine(LifecycleStageKey.Completion));
    }

    /// <summary>Periodic Claude Workbook Review (DB-M11): advisory READ-ONLY. Only
    /// surfaces when the backend recommendation says a review is warranted.</summary>
    private static string ResolvePeriodicWorkbookReview(DevBridgeState s)
        => s.M11Recommendation is { ClaudeWorkbookReviewRecommended: true }
            ? Ready
            : NotApplicable;
}
