# DB-M25 Quality-Adjusted Cost Analytics

Status: DESIGN (implementation follows in scripts/ai-routing/quality-cost/)

## Purpose

Quality-adjusted cost analytics for DevBridge AI usage. The objective is NOT
simply "which model is cheapest per attempt?" but "what is the real expected
cost of obtaining a VERIFIED successful result?" DB-M25 combines attempt cost
(actual preferred, estimated labelled), failed attempts, retry/escalation
cost, verified success, first-attempt success, cost per successful task,
provider route, reasoning level, task classification and confidence into
transparent cost-efficiency analytics.

DB-M25 is DevBridge-only, temporary, and NOT designed for Nexus migration.
DB-M25 executes nothing, makes no AI/provider/paid/network calls, and does not
modify routing policy, pricing, attempt history or the workbook.

## Core principle

Cheap attempt cost does not necessarily mean cheap successful development.

- Model A: Rs.2 per attempt, 4 attempts commonly required.
  Effective success cost ~ Rs.8.
- Model B: Rs.5 per attempt, usually succeeds first attempt.
  Effective success cost ~ Rs.5.

DB-M25 represents this correctly: the chain cost (all attempts, failed
included) per verified success is the unit of analysis, never the single
attempt price.

## Verified success is authoritative

Success must use independent evidence. Preference:

- VerificationResult = VERIFIED (DB-M17 verification evidence, DB-M06 report)
- applicable accepted Claude review state where review is required

over model self-reported success. A model saying PASS is not sufficient if
verification later failed; a rejected implementation is never counted as
successful merely because the model finished.

DB-M25 resolves success with `Resolve-DbM25VerifiedSuccess`:

| Input | Rule |
|---|---|
| Result | must be SUCCESS |
| VerificationResult = FAILED | contradicts success (never counted) |
| VerificationResult = VERIFIED | verified success |
| VerificationResult = PENDING / absent | verified only under VERIFIED_PREFERRED (flagged model-returned, never verified) |
| Review required (query RequiresClaudeReview) | review status must be PASS, else REVIEW_REJECTED (not success) |

SuccessDefinition (DB-M24 vocabulary, consumed READ-ONLY):

- VERIFIED (DB-M25 default) - only independently verified successes count.
  A plain model-returned success is tracked transparently
  (ModelReturnedSuccessCount) but does NOT qualify for verified-success
  metrics. This is the authoritative default the brief demands.
- VERIFIED_PREFERRED - verification authoritative when present; a plain
  SUCCESS counts as a success but is flagged model-returned (not verified).
- MODEL_RETURNED - Result=SUCCESS counts regardless (comparison only, never
  the default for quality-adjusted analytics).

## Attempt-chain cost

Every paid/real AI attempt contributes to actual cost. A chain is the task's
attempts in RetryNumber / StartedAtUtc order (DB-M24 Resolve-AiTaskChains
reused READ-ONLY). Chain cost = sum of usable cost evidence of every attempt
in the chain.

- Attempt 1 fail Rs.3, attempt 2 fail Rs.6, attempt 3 pass Rs.10.
  Verified successful chain cost = Rs.19. Never report only Rs.10.

Cost evidence rules (DB-M16/DB-M17 semantics, READ-ONLY):

- ActualCost is preferred over EstimatedCost.
- EstimatedCost is used only when the query allows estimated-cost fallback,
  and the use is labelled (EstimatedCostFallbackUsed + a warning).
- Only attempts whose CostCurrency equals the reporting currency contribute;
  historic cost in another currency is NEVER re-converted (historical FX
  evidence is preserved, not rewritten). Currency mismatches are excluded with
  a warning.
- An attempt with no cost evidence contributes zero and is counted
  (MissingCost) ONLY when it is an executed attempt (Result SUCCESS / FAILED /
  ESCALATED). Non-attempts never add cost and never inflate missing-cost
  counters:
  - BUDGET_STOPPED - budget prevented the attempt; no model call, no AI cost
  - WAITING_HUMAN / BLOCKED (git gate, review wait) - no AI cost
  - PENDING - not an attempt yet
  - provider-health wait is a provider-side fact, never a MODEL_QUALITY cost

## Cost metrics (QualityAdjustedCostResult v1)

Per group (default group-by: model route):

- AverageAttemptCost / MedianAttemptCost - cost per attempt over the group.
- AverageAttemptsPerVerifiedSuccess / MedianAttemptsPerVerifiedSuccess.
- FirstAttemptVerifiedSuccessRate - verified chain whose attempt #1 is a
  verified success, divided by sample.
- VerifiedSuccessRate - verified successes / sample.
- TotalCostPerVerifiedSuccess - SUM of verified-success chain costs.
- ObservedCostPerVerifiedSuccess - MEAN verified-success chain cost.
- ExpectedCostPerVerifiedSuccess - see below.
- EscalationCostShare / FailedAttemptCostShare / ProviderFailureCostShare /
  ModelQualityFailureCostShare - shares of the group's total attempt cost.
- AverageCorrectionCost - mean chain cost of correction-loop chains (a chain
  with more than one attempt before its terminal verified success, or with
  HumanIntervention).
- AverageSuccessfulChainCost - alias of ObservedCostPerVerifiedSuccess.
- ProviderFailureCost / ModelQualityFailureCost - cost of attempts whose
  FailureCategory is a provider-side category (PROVIDER_AVAILABILITY /
  RATE_LIMIT / AUTHENTICATION) vs MODEL_QUALITY. A rate limit, timeout or
  gateway failure is never automatically a model-quality cost.
- FailureCategoryCosts - full category -> cost table.
- EscalationCost - cost of attempts carrying escalation evidence;
  EscalatedChainCost - total cost of chains that escalated.
- LocalCostStatus - CONFIGURED / FREE / LOCAL_COST_UNKNOWN / PRICE_UNKNOWN
  (DB-M23 vocabulary, READ-ONLY). A LOCAL route whose only cost evidence is an
  explicit zero provider-token price is LOCAL_COST_UNKNOWN (operational cost
  unknown), NEVER FREE. OperationalCostUnknown is reported for LOCAL routes.
  DB-M25 never invents electricity/hardware cost.

## Expected cost per success (transparent mathematics)

ExpectedCostPerVerifiedSuccess =

- OBSERVED_CHAINS basis (sample confidence MODERATE or HIGH): the mean
  observed verified-success chain cost. Actual attempt chains are available
  and preferred.
- COLD_START_SIMPLE basis (confidence LOW or INSUFFICIENT): the labelled
  simple estimate = AverageAttemptCost / VerifiedSuccessRate, clearly
  tentative. If VerifiedSuccessRate is zero/unknown the estimate stays null.
  ExpectedCostBasis is always reported so the basis is never silent.

The simplistic attempt-price / success-rate formula is never presented as
fact when observed chains materially change the answer.

## Local model cost

LOCAL is never automatically FREE. Reusing DB-M23/M15/M16 semantics: provider
token price zero is the provider-token component only; local operational cost
(infrastructure/electricity/hardware) is unknown unless configured, and DB-M25
never invents it. LocalCostStatus + OperationalCostUnknown + a warning carry
this for LOCAL routes.

## Currency

Reuse DB-M16. No second FX engine. Reporting currency (default INR) is a
query field. Historical reproducibility preserves the applicable historical
FX/pricing evidence: stored costs in the reporting currency are used as-is;
stored costs in another currency are excluded (never re-converted) with a
warning.

## Confidence

Reuse DB-M24 confidence principles (INSUFFICIENT / LOW / MODERATE / HIGH,
configurable bands consumed READ-ONLY from config/performance/
confidence-bands.json). Analytics with insufficient evidence are labelled
INSUFFICIENT and every result carries a ConfidenceLevel + warnings. A strong
savings claim is never made from one attempt.

## Operating modes

MANUAL: analytics displayed only. ASSISTED: analytics may support
recommendation evidence. AUTO: DB-M25 executes nothing.
AUTO_EXECUTION_ENABLED = FALSE. No provider/model executed, 0 paid calls,
0 network calls.

## Boundaries

- DB-M25 does NOT select models; DB-M19 selects/recommends. DB-M25 produces
  evidence DB-M19 may later consume. No silent routing-policy mutation.
- Budget blocking is reported as budget-prevented, never fabricated as an
  unsuccessful AI attempt (a budget block is not a model-quality failure).
- Provider outages create wasted cost/time and are kept distinct from quality
  cost (route availability cost is not model-quality cost).
- Reuses DB-M24 performance calculations READ-ONLY; DB-M25 owns
  cost-quality/savings analysis, DB-M24 owns performance intelligence.
- Temporary DevBridge boundary: DB-M25 writes only DevBridge-owned files, no
  Nexus source/workbook/roadmap modification, no PR/merge capability, no AI
  execution, no claim that Nexus must reuse these analytics later.

## Reuse map (all READ-ONLY)

| Source | Reused |
|---|---|
| DB-M14 AiRoutingContracts.ps1 | Get-ContractProperty, vocabularies |
| DB-M16 AiCostContracts.ps1 / CostCalculator.ps1 | cost/currency semantics (fields on attempt records) |
| DB-M17 AttemptStore.ps1 | AiAttemptRecord v1 fields, failure/verification vocabularies |
| DB-M19 RoutingCandidate.ps1 | route identity semantics (data, never compared to literals) |
| DB-M20 EscalationContracts.ps1 | escalation evidence fields, ClaudeReviewStatus vocabulary |
| DB-M23 AdapterContracts.ps1 | Get-DbM23PriceStatuses, Test-DbM23SecretLeak |
| DB-M24 AiPerformanceFoundation.ps1 | Resolve-AiTaskChains, ConvertTo-AiPerfUtc, Get-AiConfidenceLevel, Get-AiPerfMean/Median, success-definition + confidence + preset-window vocabularies |
| config/performance/confidence-bands.json | confidence bands (loaded READ-ONLY) |
