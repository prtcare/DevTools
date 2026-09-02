# DevBridge — HUMAN ACTION REFERENCE

> DB-M34 output · 2026-09-02 · DevBridge has **no autonomy**: every model call,
> PR, merge, and baseline decision is a human action. This reference is the map
> from a DevBridge token/state to the exact human action it is asking for.

DevBridge signals a human action two ways:
1. **`HUMAN_ACTION` lifecycle state / `HUMAN_ACTION_REQUIRED`** — the task needs
   you to do something before it can continue.
2. **`HumanActionResolver` engine tokens** — the *kind* of human action.
   `REVIEW_GOVERNANCE_ISSUE`, `HUMAN_DECISION`, `CREATE_PR`, `REVIEW_PR`,
   `MERGE_PR`, `RESTORE_REAL_NEXUS_BASELINE`.

---

## The eleven human actions — TRIAL vs REAL (DB-M34 Area 16)

DevBridge surfaces human/external work through exactly these action tokens.
Every one is performed by a person; DevBridge never performs them. The
TRIAL-vs-REAL column says whether the action is *permitted* in that mode.

| Human action token | What the person does | Allowed in TRIAL | Allowed in REAL |
|---|---|---|---|
| `COPY_TO_CHATGPT` | Paste `tasks/CHATGPT_HANDOFF.md` into ChatGPT; bring the prompt back | ✅ | ✅ |
| `COPY_TO_CLAUDE_CODE` | Paste the ChatGPT prompt into Claude Code / DeepSeek to implement | ✅ | ✅ |
| `COPY_TO_DEEPSEEK` | (Alternative/2nd model) run the same prompt in DeepSeek | ✅ | ✅ |
| `RETURN_IMPLEMENTATION_RESULT` | Register the finished implementation + evidence so M06 can verify it | ✅ | ✅ |
| `COPY_TO_CLAUDE` | Send the M07 review package to Claude; bring back the verdict | ✅ | ✅ |
| `RECORD_CLAUDE_RESULT` | Record the verdict: `PASS` / `FIX` / `GOVERNANCE_ISSUE` / `HUMAN_DECISION_REQUIRED` | ✅ | ✅ |
| `CREATE_PR` | Create the PR for the change | ❌ (no real PR in a trial) | ✅ (human only) |
| `REVIEW_PR` | Review the open PR | ❌ | ✅ (human only) |
| `MERGE_PR` | Merge the reviewed PR | ❌ | ✅ (human only; DevBridge only credits explicit evidence) |
| `HUMAN_GOVERNANCE_DECISION` | Resolve a governance/roadmap concern and record the decision | ✅ (governance blocks) | ✅ |
| `RESTORE_PRE_DEVBRIDGE_BASELINE` | Authorize + perform the pre-DevBridge workbook/source restore | ❌ during TRIAL (forbidden until DB-M34 PASS + authorization) | ✅ once, at transition |

## Human-action map

| DevBridge token / state | Required human action | DevBridge does | DevBridge never does |
|---|---|---|---|
| `AWAITING_CHATGPT_PROMPT` (M05 handoff ready) | Copy `tasks/CHATGPT_HANDOFF.md` to ChatGPT; bring the prompt back | Produced the handoff | Calls ChatGPT; runs the model |
| M05 → implementation handoff | Copy the ChatGPT prompt (plus `tasks/DEEPSEEK_PROMPT.md`) to your implementation tool | Produced the prompt | Executes the implementation tool |
| Implementation done | Register the result (files changed, evidence, build/test output) so M06 can verify it | Provides the registration flow | Trusts a self-report as PASS |
| `CLAUDE_REVIEW_PACKAGE_CREATED` (M07) | Send `tasks/CLAUDE_REVIEW_PACKAGE.md` to Claude; bring back the decision | Built the package with dependency context + Trial/Real distinction | Calls Claude |
| Claude decision returned | Record it with `Set-ClaudeReviewResult.ps1`: `PASS`, `FIX`, `GOVERNANCE_ISSUE`, or `HUMAN_DECISION_REQUIRED` | Validates + transitions | Infers what Claude said |
| `RESOLVE_GOVERNANCE_BLOCK` | Investigate the governance issue (see Error Recovery reference); make the human call | Explains the block, recommends | Overrides or bypasses it |
| `REVIEW_GOVERNANCE_ISSUE` | Review the surfaced governance concern and record a human decision | Packages the concern | Auto-resolves it |
| `HUMAN_DECISION` | Decide, then record the decision | Applies it | Decides for you |
| `AWAITING_HUMAN_PR` (REAL) | Create the PR for the change | Reports the gate from read-only Git evidence | Creates the PR |
| `PR_OPEN` / `AWAITING_HUMAN_REVIEW` (REAL) | Review the open PR | Reports the gate | Approves |
| `AWAITING_HUMAN_MERGE` (REAL) | Merge the reviewed PR | Reports the gate; only `MERGED` with explicit evidence | Merges; infers a merge |
| `RESTORE_REAL_NEXUS_BASELINE` | (Transition-time, DB-M34-end) authorize + perform the pre-DevBridge baseline restoration | Represents the baseline; guides | Restores it on its own |
| `HUMAN_ACTION_REQUIRED` for cost/model routing | Choose/adjust the provider model or note the recommendation is advisory | Recommends (M16/M27/M28/M29 informational) | Auto-selects a paid provider |

---

## What a "human step" concretely is

1. **ChatGPT gate (M05 → prompt).** Copy `tasks/CHATGPT_HANDOFF.md`. ChatGPT
   returns a step-by-step implementation prompt. Keep that prompt; it is the
   artifact you paste to the implementation tool.
2. **Implementation gate.** Paste the prompt into Claude Code / DeepSeek. The tool
   does the coding. **You** run/verify on your machine; DevBridge has no
   execution hook.
3. **Return + verify.** Register the result, then run M06. M06 is deterministic
   and independent — a PASS means the registered evidence verified, nothing more.
4. **Claude gate (M07/M08).** Send the package; paste Claude's verdict back into
   the recording command.
5. **REAL Git gates.** Create → review → merge the PR yourself. DevBridge watches
   read-only and will not credit a merge it cannot see in evidence.

---

## When DevBridge says a human action is *not* needed

- TRIAL mode: **no PR, no merge, no M10.** The human "action" ends at
  `TRIAL_CYCLE_SAFE_STOP`, then running `Close-TrialCycle.ps1`.
- No `HUMAN_ACTION` token on the current task: the next step is a DevBridge
  command (e.g. M03/M04/M06), not a human one.
- Operator console buttons are only enabled when the underlying real evidence
  exists — a disabled button is not asking for a human action, it is waiting for
  one earlier in the chain.

---

## Recording human results — the only four M08 decisions

| Decision | Meaning | DevBridge transition |
|---|---|---|
| `PASS` | Claude approved the TRIAL/REAL review | `CLAUDE_REVIEW_PASSED_TRIAL` → `TRIAL_CYCLE_SAFE_STOP` (trial) / `CLAUDE_REVIEW_PASSED_REAL` → human PR gates (real) |
| `FIX` | Claude found a defect | `DB_M09_FIX_REQUIRED` → correction context → re-run M06/M07 |
| `GOVERNANCE_ISSUE` | Review surfaced a governance concern | `REVIEW_GOVERNANCE_ISSUE` — human governance review, no implementation continues until resolved |
| `HUMAN_DECISION_REQUIRED` | Escalation to you | Decision recorded then flow resumes |

## Golden rule

If a step says "human," **you** must perform it. If DevBridge's state says a
human action is pending and you do not know which one, run the recovery panel
(`Show-DbM32EssentialSafety.ps1`) — it maps the exact token to the exact action.
