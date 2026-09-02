# DB-M25 Savings Analytics

Status: DESIGN (implementation follows in scripts/ai-routing/quality-cost/)

## Purpose

Quality-adjusted savings analysis: compare the real expected cost of obtaining
a VERIFIED successful result across routes / policies, with an explicit
baseline and a transparent basis. Savings must compare equivalent verified
outcomes and must never be a favourable-baseline trick.

DB-M25 is DevBridge-only, temporary, and NOT designed for Nexus migration.
DB-M25 executes nothing; no AI/provider/paid/network calls; no policy mutation.

## Savings only on equivalent verified outcomes

Example (baseline route B, alternative route A):

- Baseline route: Rs.40 verified-success cost.
- Alternative route: Rs.22 verified-success cost.
- Quality-adjusted savings: Rs.18 (45%).

Savings are NEVER claimed by comparing a successful expensive model against a
cheap model that failed. Both sides of a savings comparison are verified
successes under the same scope (TaskType / Complexity / Risk filters).

## Baseline types (explicit, never silent)

Get-DbM25BaselineTypes:

- CURRENT_DEFAULT
- MANUAL_BASELINE
- CHEAPEST_ELIGIBLE
- HISTORICAL_ROUTE
- SPECIFIC_MODEL_ROUTE
- SPECIFIC_POLICY

Every SavingsAnalysis carries a BaselineType and a BaselineLabel. DB-M25 never
silently chooses a favourable baseline.

## Baseline basis (observed vs estimated)

Get-DbM25BaselineBasis:

- OBSERVED - the baseline cost-per-verified-success comes from observed
  verified chains.
- ESTIMATED / COUNTERFACTUAL - the baseline is a synthetic or hypothetical
  comparison ("what would have happened if route B was used?"). Counterfactual
  savings are NEVER presented as observed fact; the basis labels them.

Observed data remains distinct from estimated/counterfactual data.

## SavingsAnalysis v1

Fields: AnalysisId, Scope, TaskType, Complexity, Risk, CandidateRoute (and its
identity fields), BaselineRoute (and its identity fields), BaselineType,
BaselineLabel, BaselineBasis, SampleSize, Confidence, AverageAttemptCost,
AttemptsPerVerifiedSuccess, VerifiedSuccessRate, FirstAttemptSuccessRate,
ObservedCostPerVerifiedSuccess, ExpectedCostPerVerifiedSuccess,
BaselineCostPerVerifiedSuccess, AbsoluteSavings, SavingsPercent,
EscalationCost, FailureCost, ProviderFailureCost, ModelQualityFailureCost,
AvoidedRetryCost, Currency, EvidenceReferences, WindowStartUtc, WindowEndUtc,
GeneratedAtUtc, Warnings.

- AbsoluteSavings = baseline cost-per-verified-success minus candidate
  cost-per-verified-success (only when both are non-null and both are verified
  outcomes).
- SavingsPercent = AbsoluteSavings / baseline * 100. A zero or unknown
  baseline leaves both null (division by zero is never produced).
- AvoidedRetryCost = (baseline attempts-per-verified-success minus candidate
  attempts-per-verified-success) x candidate average attempt cost, when
  positive and evidence supports it; labelled ESTIMATED/COUNTERFACTUAL. Where
  evidence does not support a retry-avoidance estimate it stays null.

## Quality adjustment

Savings/efficiency consider VerifiedSuccessRate, FirstAttemptSuccess,
AttemptsPerSuccess, CostPerSuccess, EscalationRate, FailureCategory and
Confidence. A cost reduction that hides quality loss (e.g. a cheap model that
fails verification) never counts as savings: a route with no verified successes
has no cost-per-verified-success and therefore no savings number.

## Confidence

Confidence (DB-M24 principles, READ-ONLY): INSUFFICIENT / LOW / MODERATE /
HIGH. Insufficient evidence -> the savings are labelled INSUFFICIENT and the
report warns "tentative, small sample". A strong statement like "Model X saves
38%" is never made from one attempt.

## Policy comparison (analysis only)

Compare-DbM25Policies supports synthetic/historical comparison between routing
policies, each expressed as a route-selection rule over the computed
quality-adjusted results:

- CHEAPEST_ELIGIBLE - minimum AverageAttemptCost
- CHEAPEST_RELIABLE - minimum cost-per-verified-success among routes with
  VerifiedSuccessRate >= 0.8
- BEST_COST_PER_SUCCESS - minimum ObservedCostPerVerifiedSuccess
- HIGHEST_SUCCESS - maximum VerifiedSuccessRate
- BALANCED - best composite of normalized cost-per-success and success rate

Each policy row is ranked by cost-per-verified-success (presentation only),
carries its SampleSize/Confidence, and is labelled COUNTERFACTUAL unless it is
the actually-observed default. PolicyVersion stays the immutable '0.0.0'.
DB-M25 does NOT alter live policy; the comparison is evidence only for DB-M19.

## Operating modes / boundaries

MANUAL display only; ASSISTED may support recommendation evidence; AUTO
executes nothing; AUTO_EXECUTION_ENABLED = FALSE. No provider/model executed,
0 paid calls, 0 network calls. No hidden policy mutation: config/ai-routing.json
and every DB-M19/M20/M21/M22/M23/M24 implementation file remain byte-identical
(verified by the test suite's before/after SHA-256 scan). No workbook/Nexus
mutation. Temporary DevBridge boundary holds: DevBridge-only files only.
