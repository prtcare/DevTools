# AI_ROUTING_PARALLEL_PLAN.md — Parallel-safe sequencing for DB-M14 → DB-M25

**Milestone:** DB-M13 · **Lane:** B — AI ROUTING DISCOVERY · **Status:** DESIGN ONLY
**Root:** `C:\Personal\DevTools\DevBridge` · **Date:** 2026-08-30

Plan for implementing the AI Routing / Cost Platform **in parallel lanes** without rebuilding the
existing lifecycle, without touching DB-M03–M11, without depending on unfinished DB-M12, and while
keeping the manual flow usable at every step.

---

## 1. Parallel-safety principles (apply to every milestone)

1. **Additive-only.** New files under `config/`, `scripts/ai-routing/`, `state/`, `tasks/`; new
   directories `state/attempts/`, `logs/tasks/<node>/<change>/attempts/`. No existing file is edited
   by any routing milestone.
2. **Read-only consumption of stable contracts.** Every routing component consumes the DB-M03–M11
   contracts (§11 of the discovery report) **by reference**; it never alters their schema or content.
3. **Shared contracts frozen early.** attempt v1, pricing v1, provider-catalog + health shape, and the
   routing request/response shape are frozen at DB-M14. Parallel lanes compile against the frozen
   schemas, so no cross-lane interface churn.
4. **Mode flag guards behavior.** `config/ai-routing.json` `"mode":"manual"` is the only valid runtime
   value until ASSISTED is explicitly enabled (DB-M19 dry-run gate); `"auto"` is invalid/blocked until
   the governance gate in §3.3 of the architecture doc passes.
5. **Manual flow always runnable.** After every milestone, the `Development Control → DevBridge →
   ChatGPT → DeepSeek → Verification → Claude → Completion` flow runs exactly as before (no routing
   config present or present-and-inert).
6. **Human is always the last hop.** No milestone may introduce a path where DevBridge executes an AI
   call or spends money without a human decision, except behind the future AUTO governance gate.

---

## 2. Lanes

### Lane A — Contracts & Data Foundation (defines the shared contracts)

| Milestone | Deliverable | Parallel-safe with |
|---|---|---|
| DB-M14 | Provider catalog, attempt schema v1, pricing schema v1, health shape, `mode` flag | — (contract freeze; everything else gates on it) |
| DB-M15 | Pricing data files + effective-dated lookup | DB-M16, DB-M17, DB-M18 (schemas frozen) |
| DB-M17 | Attempt store + accessors | DB-M15, DB-M16, DB-M18 |

**Lane A exit gate:** attempt + pricing records round-trip byte-stable; catalog loads with zero secrets.

### Lane B — Decision Engines (consume Lane A)

| Milestone | Deliverable | Depends on | Parallel-safe with |
|---|---|---|---|
| DB-M16 | Cost calculator | DB-M15 | DB-M17, DB-M18 |
| DB-M18 | Task classifier + context budget | DB-M13 contracts | DB-M16, DB-M17 |
| DB-M19 | Router (capability-based) | DB-M16, DB-M18 | design parallel with M20-22; implementation sequential |
| DB-M20 | Retry/escalation engine | DB-M17, DB-M19, DB-M21 | design parallel with M21/M22 |
| DB-M21 | Budget + failure fingerprints | DB-M16, DB-M17 | design parallel with M20/M22 |
| DB-M22 | Provider health + failover | DB-M14, DB-M19 | design parallel with M20/M21 |

**Lane B exit gate:** router dry-run parity with historical human choices; escalation traces match the
12 existing escalation conditions; failover ends in a human path.

### Lane C — Operational Intelligence (reads attempts; independent of B's internals)

| Milestone | Deliverable | Depends on | Parallel-safe with |
|---|---|---|---|
| DB-M23 | Local / OpenRouter adapters | DB-M14, DB-M22 | all of Lane B (isolated adapters) |
| DB-M24 | Performance intelligence | DB-M17, DB-M19 | DB-M20-23 |
| DB-M25 | Quality-adjusted cost | DB-M24, DB-M17 | after DB-M24 |

**Lane C exit gate:** performance report renders from real attempts; quality-adjusted ranking produced.

---

## 3. Shared contracts (frozen at DB-M14 — the "contracts ledger")

| Contract | Shape | Consumers |
|---|---|---|
| `attempt` record v1 | JSON schema (§4 architecture) | M17, M20, M21, M24, M25 |
| pricing row v1 | JSON schema (§5 architecture) | M15, M16, M19 |
| `taskProfile` | classifier output shape | M18, M19, M20 |
| `routingDecision` | router response shape | M19, M20, M22 |
| `costRecord` | estimated/actual cost shape | M16, M19, M20, M21, M24, M25 |
| provider catalog + health | connection + status shape | M14, M22, M23, M24 |
| FailureCategory enum | fingerprint taxonomy | M21, M20, M24 |

**Churn rule:** any proposed change to a frozen contract must be issued as a schema amendment (new
version) — never an in-place edit — so parallel lanes always compile against a stable interface.

---

## 4. Integration gates (checkpoints where a lane proves it works in the real lifecycle)

| Gate | After | Proof |
|---|---|---|
| **G1 — Contract freeze** | DB-M14 | Catalog + schemas load; zero secrets; `mode=manual` only valid value |
| **G2 — Data correctness** | DB-M15/DB-M17 | Pricing lookup for known date correct; attempt round-trip byte-stable; no DB migration |
| **G3 — ASSISTED dry-run** | DB-M19 | `ROUTING_RECOMMENDATION.md` generated for a real preflighted task; human could ignore it; MANUAL flow unaffected |
| **G4 — Multi-provider** | DB-M22/DB-M23 | Simulated outage → alternate provider → human fallback; local + OpenRouter dry-run |
| **G5 — Intelligence loop** | DB-M24/DB-M25 | Performance/quality-adjusted metrics feed router SCORE; ranking changes sensibly |
| **G6 — AUTO governance** | *not in scope of DB-M13* | Requires new ADR + workbook governance update + explicit enable flag + kill switch (§3.3 architecture) |

**G3 is the point where ASSISTED mode may be turned on for a real task** — and only then. Everything
before G3 ships inert in `manual` mode.

---

## 5. DB-M12 overlap

**DB-M12 overlap: NONE.**
- DB-M12 (UI) is **not implemented** (confirmed: no UI files; only "Stop after DB-M11" markers exist).
- All routing components are designed against the **stable backend contracts** (§11 discovery) and
  expose **no UI surface** in DB-M13-M25.
- When DB-M12 is built it consumes the same contracts; the routing milestones add config/state files
  the future UI can read (recommendations, cost, performance). No routing milestone blocks or depends
  on DB-M12.

---

## 6. Risk register — shared-contract risks

| Risk | Mitigation |
|---|---|
| Schema churn between parallel lanes | Contracts frozen at DB-M14; amendments are new versions, never in-place edits (§3) |
| Scope creep into provider-name branching | ADR-005 is a hard rule; routing policy is config data, not `if` on model names; CI/self-test asserts no provider-name literals in business logic |
| Pricing becomes stale / wrong | `Source` + `VerifiedAt` per pricing row; DB-M15 verification step; UNKNOWN instead of guessing |
| Attempt records diverge from verification evidence | Attempt `VerificationResult` links to `verification.json`; DB-M06 evidence fields reused (§4 architecture) |
| Secret leakage into routing config | `config/` is secret-free by construction; credentials env-var only; DB-M14 self-test asserts zero secrets |
| Manual flow broken by an inert router | `mode=manual` default; every milestone re-runs the manual flow smoke test (§1.5) |
| Router lock-in to one provider | Capability-based routing + mandatory human fallback (DB-M22); provider catalog is multi-provider (DB-M23) |

---

## 7. Suggested execution order on the critical path

1. **DB-M14** (contracts) — single-threaded, small.
2. **DB-M15 + DB-M16** and **DB-M17** and **DB-M18** in parallel (Lane A + start of Lane B).
3. **DB-M19** (router) — sequential after M16+M18; **G3 gate** here.
4. **DB-M21 + DB-M22** in parallel, then **DB-M20** (escalation) — or all three designed together,
   implemented once M19 is stable.
5. **DB-M23** at any point after M14 (isolated adapters).
6. **DB-M24** then **DB-M25** (intelligence loop) once attempts exist.

Every step above is **parallel-safe** (independent working sets, additive files, frozen contracts) and
leaves the manual lifecycle runnable.

---

*End of parallel plan.*
