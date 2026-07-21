# Reference-token handoff — spike / design spec

**Date:** 2026-07-21
**Status:** SPIKE / design exploration — **no build this pass.** Prototype-on-paper only; recommends go/no-go criteria for a future implementation cycle.
**Owner:** __MAINTAINER_NAME__ (solo maintainer)
**Related:**
- Source: spec 017 digest batch-2 adoption, item **P15** ("reference-token handoff spike"), route `spike`.
- Prior recommendation consumed: `docs/specs/2026-07-07-session-event-log-spike.md`, §7 conditional GO criteria **G1–G3**.
- Touched subsystem: none. This document discusses the current `context-log.md` handoff, the P4 event-log design, and a possible cross-harness resolver; all remain unchanged this pass.

---

## 1. Problem & intent

Trellis currently pushes summarized context into each next-session or subagent prompt. Fan-out repeats that payload once per child, freezes each copy at send time, and provides no receipt showing which child read which version. A correction made after fan-out must be found and resent to every holder manually.

P15 proposes a waggle-style, attributed **reference token** instead: mint one roughly 30-byte pointer to a canonical context artifact, place that token in each handoff prompt, and let the receiving agent resolve the artifact on demand. Resolution records a read receipt. A correction creates a new artifact revision and notifies known holders to re-resolve the same stable token.

The intended fan-out is small and explicit:

1. A parent publishes the shared context artifact once and receives `tr1_<26 base32 chars>` (30 ASCII bytes total).
2. Each child prompt carries that token plus only its child-specific assignment.
3. Claude or Codex resolves the token through the same Trellis surface; the resolver returns the current revision and records who read it.
4. A correction appends a revision, advances the token's logical head, and queues a correction notice for every live holder found through receipts.

### The intellectual core (read before evaluating the sketch)

Five facts keep this spike honest and prevent it from overclaiming:

- **A token is an indirection mechanism, not context compression.** The canonical artifact still costs storage, and every resolving agent still pays the token cost of reading the selected content. The potential saving comes only from avoiding repeated prompt-time copies and from resolving narrower or corrected content.
- **Propagation is not retroactive model-state repair.** A resolver cannot remove stale text already consumed by a running model. Here, "corrections propagate" means known holders receive a notice at the next reachable harness boundary and must re-resolve before acting. An offline or terminated holder updates only if it resumes.
- **Attribution is audit evidence, not proof of comprehension.** A receipt proves that a harness identity resolved revision `N`; it does not prove the model understood, retained, or followed it.
- **The waggle-dance-inspired correctness figures (99% vs. 20%) and the roughly 15x context-duplication tax are VENDOR-REPORTED AND UNVERIFIED.** Trellis has not measured them. They are hypotheses, not evidence, until Trellis independently reproduces them under representative Claude-to-Codex and Codex-to-Claude fan-out.
- **The resolver is new runtime machinery.** Both harnesses need a reachable mint/resolve/receipt/correction surface. It does not exist today. Unlike the P4 event-log spike, which could mostly reuse transcript hooks, canonical-root resolution, and disk-janitor machinery, this proposal needs a new shared service boundary and a harness bridge on each side.

### Non-goals (this pass)

- No code, no hook edits, no schema changes, no resolver, and no wiring. Design only.
- No change to `context-log.md`, the current handoff hooks, or their Codex twins.
- No implementation of the P4 event log; this spec consumes its conditional recommendation without declaring G1–G3 satisfied.
- No claim that vendor-reported 99% vs. 20% correctness or ~15x duplication savings apply to Trellis.
- Not wiring this spec into `registry.md` or any index (it is an unmerged HOLD/design artifact).

---

## 2. Design sketch (prototype-on-paper)

A harness-neutral resolver owns stable tokens, immutable artifact revisions, receipts, and correction notices. The token is the handoff; the artifact remains the evidence.

### 2.1 Token and artifact semantics

- **Opaque, stable token.** `tr1_` identifies the protocol version; 26 base32 characters provide the lookup id. Attribution and location remain resolver metadata, not token text. The token is short enough to repeat, but is not a secret or an authorization credential.
- **Logical head, immutable revisions.** A token names one logical artifact. Publishing a correction appends revision `N+1`; prior revisions and their receipts remain auditable. Resolve returns the current head unless a caller explicitly requests a historical revision.
- **Attributed mint.** The mint record includes project/canonical-root scope, originating harness, session, agent or parent task, branch/worktree, timestamp, and artifact kind. The resolver authenticates the caller independently; callers cannot assert attribution through prompt text.
- **Bounded content.** The artifact contains shared handoff context, not an unfiltered transcript or secret store. Large evidence remains referenced by git object, transcript offset, or event-log coordinates.

### 2.2 Resolve and read receipts

Both harnesses call one conceptual interface, for example:

`trellis ref resolve <token>`

The response includes token id, artifact revision, content, author attribution, correction state, and a receipt id. The resolver records resolving harness/session/agent, requested and returned revision, timestamp, and outcome. Receipts are append-only. Failed lookups are recorded separately; they are not successful reads.

Claude mints tokens that Codex can resolve, and Codex mints tokens that Claude can resolve. **Cross-harness mint/resolve parity is a hard requirement, not a later enhancement.** A design that uses harness-private memory, tool names, identity, or storage is NO-GO even if same-harness fan-out works.

### 2.3 Correction propagation

A correction requires an attributed reason and appends a new revision. The resolver then enumerates live holders from receipts and queues a small notice: token, old revision, new revision, correction summary, and "re-resolve before acting." Each harness bridge delivers notices at its next safe event boundary and acknowledges delivery.

This is at-least-once notification, so notices must be idempotent by `(token, revision, holder)`. A holder remains stale until it resolves the new revision. Unreachable holders stay visible as pending; the system must never label a correction "propagated" merely because it was queued.

### 2.4 Fan-out path

The parent mints once, then gives every child the same shared token plus distinct task instructions. Each child resolves before using the shared context. A child may mint a separate token for its result, preserving parent/child attribution without copying the shared artifact back through every prompt.

The token does not replace task scoping. Branch, cwd, write boundary, and expected output still belong in the direct child assignment when they determine authorization or safety; an unavailable resolver must not erase those guardrails.

### 2.5 Resolver shape

Three placements are plausible:

- **Canonical-root files only:** cheapest prototype, but polling, concurrent receipt writes, correction delivery, and cross-worktree identity become ad hoc service logic hidden in files.
- **Local canonical-root resolver process (recommended for a bounded prototype):** one harness-neutral CLI/IPC contract backed by durable files. It centralizes concurrency and receipts without requiring a network service, but introduces lifecycle, availability, and compatibility work.
- **Remote resolver service:** naturally reachable across machines, but adds authentication, tenancy, network failure, hosting, and data-governance cost before local value is proven.

The local resolver is the smallest architecture that tests the hard parts honestly. A file lookup alone does not test correction delivery; a remote service is premature.

---

## 3. Handoff architecture comparison

| Axis | (a) Current summarized `context-log.md` | (b) P4 session event log | (c) P15 reference-token layer |
|---|---|---|---|
| **Shape** | Push a lossy, one-shot summary into startup context. | Pull a positional per-session slice on demand. | Pass a stable pointer; resolve current artifact and record receipt. |
| **Fixes** | Cheap orientation with no reader action. | Recovers older reasoning/pre-action state; per-session files avoid cross-worktree clobbering. | Avoids prompt-time duplication across fan-out; attributes reads; gives corrections a holder list and stable re-resolution path. |
| **Does not fix** | Dropped history, clobbering, duplicate fan-out, or stale copies. | Repeatedly inlined fan-out context, holder tracking, or correction notification. | Missing source evidence, bad artifact content, comprehension, or already-consumed stale model context. |
| **Read cost** | Fixed bounded startup injection. | Index/navigation plus selected slice tokens. | Resolve call plus selected artifact tokens; the pointer itself is ~30 bytes. |
| **Write/runtime cost** | One existing overwrite path; lowest complexity. | Event projection, indexing, retention, and two harness writers; mostly reuses existing machinery. | New shared resolver, identity, concurrent receipts, revision store, notification queues, and two harness bridges. |
| **Failure mode** | Last writer wins; lost context cannot be recovered. | Missing/corrupt session slice or navigation that costs more than re-derivation. | Resolver outage, stale holders, identity skew, or a valid pointer to wrong/unsafe content. |
| **Best role** | Push orientation. | Canonical evidence for targeted reconstruction. | Cross-harness fan-out indirection and correction control plane. |

**Recommendation:** do not choose one as a universal replacement. Keep `context-log.md` for bounded orientation. If P4 G1–G3 pass, use the event log as the canonical evidence artifact and let reference tokens address an event-log slice or a curated artifact derived from it. Add the token layer only if independent Trellis measurements show enough cross-harness fan-out duplication or correction failures to pay for the new resolver. Without both demand proofs, stop at the cheaper layer that passed its gate.

---

## 4. Cross-harness contract

The protocol boundary must be Trellis-owned and identical from Claude and Codex:

- same token grammar and resolver command/API;
- same project-scope and caller-identity rules;
- same artifact/revision response envelope;
- same receipt and correction-delivery semantics;
- compatibility tests in both directions: Claude mint → Codex resolve/correct, and Codex mint → Claude resolve/correct.

Harness adapters may translate native session ids or event envelopes, but may not change protocol meaning. Unknown protocol versions fail closed with an actionable error. Resolver unavailability is explicit: a handoff may retry or use a clearly labelled cached revision, but it must not silently treat stale cached content as current.

The shared surface also creates a security boundary. Tokens are references, not bearer secrets; project membership authorizes resolution. Artifacts exclude credentials, receipts follow the project's retention policy, and logs do not echo artifact bodies. A leaked token outside its project scope resolves to nothing.

---

## 5. Costs and risks

- **New availability dependency (primary).** Fan-out now depends on a resolver process and two harness bridges. A 30-byte prompt is worse than an inline summary if the pointer cannot resolve.
- **Notification machinery may dominate.** Receipts are simple; finding live holders, delivering across both harnesses, retrying, and distinguishing queued/delivered/re-resolved state are not.
- **Mutable-head surprise.** Stable tokens intentionally return newer revisions. Reproducible audits therefore need the receipt's exact revision and an explicit historical-resolve path.
- **Stale-action window.** A holder can act between correction publication and notification. Safety-critical assignments must still carry direct invariants and may require revision pinning plus an explicit supersession check.
- **Token multiplication.** Unbounded child/result tokens recreate navigation and retention problems. Mint only for shared or correctable artifacts; otherwise use direct text.
- **False confidence from receipts.** Resolve does not equal comprehension. Evaluation must score downstream behavior separately.
- **Unverified economics.** Vendor-reported 99% vs. 20% correctness and ~15x duplication claims cannot justify a Trellis build. Local measurements must include resolver overhead, artifact reads, retries, notices, and operator time.

---

## 6. How this consumes P4's conditional GO

P15 follows P4; it does not bypass P4's evidence gates.

- **P4 G1 — Demonstrated demand.** A real handoff must need information that `context-log.md` dropped. P15 can point holders to that evidence and later correct it, but cannot create evidence that was never persisted. A failed P4 G1 is also a NO-GO for using tokens to address event-log evidence.
- **P4 G2 — Net-positive slicing.** The event-log index plus slice must cost less than re-derivation or a larger summary. P15 adds mint, resolve, receipt, and correction-notice overhead to that equation; a token does not make a net-negative slice positive. Measure the combined path, not the 30-byte pointer alone.
- **P4 G3 — Bounded footprint.** Per-session logs and retention must stay within a fleet budget without collisions. P15 adds revision, receipt, and notification retention. The combined budget must include all four stores, with project-scoped pruning that preserves revisions referenced by live receipts.

Passing P4 G1–G3 makes an event-log-backed token prototype coherent; it does not prove the token layer worthwhile. P15 has its own gates below.

---

## 7. Go / no-go criteria (for a future prototype)

**Recommendation this pass: conditional GO on a bounded, instrumented local prototype only after P4 G1–G3 pass; NO-GO on production wiring or remote service work.** The reference-token layer has a credible cross-harness fan-out and correction use, but it also creates runtime machinery Trellis does not have. The vendor figures are unverified, so neither correctness nor token savings is currently established. Default to NO-GO if the criteria below are not met with Trellis data.

**GO if all of:**
- **R1 — Measured fan-out demand.** A bounded sample contains repeated shared-context fan-out across at least one Claude/Codex boundary, and full accounting shows material duplicated prompt tokens or a real stale-correction failure. Vendor-reported ~15x duplication is not the baseline.
- **R2 — Cross-harness parity.** Claude mint → Codex resolve and Codex mint → Claude resolve both succeed under one protocol, with correct attribution and no prompt-asserted identity.
- **R3 — Net-positive total cost.** Mint + resolver + artifact read + receipt + correction-delivery overhead costs less than the inline alternative for the measured workload. Evaluate task correctness independently; do not substitute the vendor-reported 99% vs. 20% figures.
- **R4 — Honest correction closure.** A correction reaches every reachable holder at least once; delivered, re-resolved, pending, and unreachable states remain distinguishable. No test claims retroactive repair of already-consumed context.
- **R5 — Bounded and reversible.** Revision/receipt/notification retention has an explicit disk budget, resolver failure has a labelled fallback, and disabling the prototype restores the existing summary/event-log path without handoff regression.

**NO-GO (kill or defer) if any of:**
- P4 G1–G3 fail; there is no validated canonical evidence path worth addressing.
- Same-harness success masks either failed cross-harness direction (R2 fails).
- Total measured cost is neutral or negative (R3 fails), even if the token itself is small.
- Corrections can be queued but not observed as re-resolved or pending (R4 fails); that is notification theatre, not propagation.
- The resolver becomes a required remote service, secret bearer-token system, or production dependency before the local proof clears R1–R5.

**Explicit next step if GO:** write a separate build spec for a disposable local resolver prototype with one artifact kind, immutable revisions, append-only receipts, correction notices, and a two-direction Claude/Codex harness matrix. Run it on a bounded recorded fan-out corpus, publish Trellis-measured token/correctness/latency results, then make a second go/no-go decision. Do not wire hooks, registry, or production handoffs in that prototype spec by default.

---

## 8. Open questions (resolve at build spec, not now)

- Which existing Trellis identity can authenticate harness/session/agent attribution without trusting prompt-supplied fields?
- What harness boundary can deliver correction notices promptly in both Claude and Codex?
- When must a caller pin a revision instead of following the logical head?
- How are live holders expired without deleting audit receipts needed for reproducibility?
- What measured fan-out corpus is representative enough to replace the vendor-reported baseline?
