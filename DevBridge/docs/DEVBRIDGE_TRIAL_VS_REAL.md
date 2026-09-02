# DevBridge — TRIAL vs REAL (and why it matters)

> DB-M34 output · 2026-09-02 · Mode source: `config/devbridge.json` +
> `state/current-task.json` → `Get-DevBridgeMode`. Current recorded mode at
> DB-M34: **TRIAL**. The two modes exist because a *trial* is disposable proving
> and a *real* run is actual Nexus progress — conflating them corrupts both.

## The one-sentence rule

**TRIAL proves DevBridge works without touching real Nexus progress; REAL_NEXUS_
DEVELOPMENT makes real Nexus progress under full human Git gates.** DevBridge is
in TRIAL until DB-M34 acceptance and a human-authorized baseline restoration.

## Mode table

| Aspect | TRIAL (current) | REAL_NEXUS_DEVELOPMENT |
|---|---|---|
| What happens | A disposable trial-proving cycle on a governed fixture/trial node | Real development of an implementable roadmap leaf |
| Workbooks | Trial fixture; canonical live workbook only read (never written except authorized live trial closure) | Canonical live workbook is written |
| M04 reservation | Real workbook write **only** in an authorized live trial closure (DB-M12.4); otherwise fixture | Governed real reservation |
| Git | Read-only; no branch, PR, merge | Human PR → review → merge gates; DevBridge read-only observer |
| M05/M07 context | Carries dependency lineage + explicit **Trial/Real** distinction so a trial never reads as a real completion | Dependency context must be satisfied by real prior work |
| Trial-proven dependency overlay | **Applied** — a trial-proven predecessor may satisfy a dependency for selection | **Never applied** — overlay ignored (Gate 1; DB-M33 hardening) |
| Completion M10 | `TRIAL_COMPLETION_NOT_APPLICABLE` — never run | Eligible only after M06 PASS + Claude PASS + confirmed human merge + unchanged roadmap fingerprint; else a `BLOCKED_*` token |
| End state | `TRIAL_CYCLE_SAFE_STOP` → `CLOSE_TRIAL_CYCLE` → `TRIAL_CYCLE_CLOSED` / `START_NEXT_CYCLE` | Real completion → M11 workbook validation → roadmap node genuinely progressed |
| Roadmap effect | Node stays `Planned`; evidence is `TRIAL_ONLY_UNMERGED` | Node genuinely progressed |
| PR / merge | None | Human-created, human-reviewed, human-merged |
| M10 read of a trial PASS | A trial PASS is **not** real completion — `TRIAL_TO_REAL_COMPLETION_CAPABILITY NO` | — |

## Why DevBridge refuses to let a trial read as real

A governed product must never confuse "DevBridge itself was proven under a trial"
with "the real roadmap was completed." DB-M33 scenario E proved: in REAL mode the
trial overlay is ignored and an unsatisfied dependency yields an honest
`RESOLVE_GOVERNANCE_BLOCK` / `NO_IMPLEMENTABLE_DESCENDANT`, never a false
satisfaction. DB-M33 scenario H proved REAL M10 requires the full real
prerequisite chain and blocks otherwise.

## The live canonical workbook note

The live canonical workbook
(`C:\Personal\Nexus.Developer\NEXUS_DEVELOPMENT_CONTROL.xlsx`) is in the
post-DB-M12.4 **authorized live trial-closure** state (SHA 6D42C3BF…). That was a
governed, evidence-preserving closure of the historical WI-07-0.2.4 trial — not
real Nexus development. The pre-DevBridge baseline (workbook F520060C…, git
ea39db91…) is **represent-only** (see `state/pre-devbridge-baseline.json`) until
the human-authorized real transition.

## How to tell which mode you are in

1. Read `config/devbridge.json` → `mode` field.
2. Read `state/current-task.json` → effective mode the task resolved to.
3. Any operator-console banner / `Show-DbM30` CLI header prints the token.
4. No mode display, or unknown → treat as TRIAL (safe default).

## Transition (only at DB-M34 close, human-authorized)

Switching to REAL is a **separate, explicit, human-authorized act**:
`DEVBRIDGE_PRE_REAL_TRANSITION_PLAN.md` + `DEVBRIDGE_FIRST_REAL_RUN_CHECKLIST.md`
describe it. There is no UI toggle and no command that silently flips the mode.
