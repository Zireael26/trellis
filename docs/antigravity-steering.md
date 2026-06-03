# AntiGravity prompting — steering reference

Source: the canonical AntiGravity gap authority — `core-rules/inheritance.md` ("Known gap: AntiGravity native hooks deferred") + the Trellis process-enforcement design (`docs/specs/2026-06-02-trellis-process-enforcement-design.md`, §4 cross-harness framing). This doc operationalizes that single source of truth for an operator running an AntiGravity session; it does not introduce or soften any claim beyond it.

AntiGravity is a Trellis secondary harness. The spine — parent rules and canonical skills — loads on every AntiGravity session via `AGENTS.md` and `.agents/`. The one thing that is **different** about AntiGravity, and the reason this doc exists, is the harness gap: AntiGravity runs **no workspace hooks**, so the turn-level enforcement that Claude Code and Codex get for free is absent, and the operator must compensate by hand. Read this before doing edit-heavy or risky work in an AntiGravity session.

---

## 1. The harness reality — no workspace hooks (Tier 1 + Tier 2 absent)

Trellis defers shipping a workspace hook envelope for AntiGravity (`core-rules/inheritance.md`, "Known gap"). Consequently **Tier 1 and Tier 2 hook enforcement** (`block-destructive`, `post-edit-verify`, `stop-verify`, and the rest) is **not available** in AntiGravity sessions. There is no PreToolUse gate that can stop a destructive command before it runs, and no Stop gate that can reject a turn.

What *does* still apply on AntiGravity:

- **Parent rules** via `AGENTS.md` and `.agents/rules/` — load-bearing on every session.
- **Canonical skills** via `.agents/skills/` — `process-gate` and `security-gate`, invoked by name.
- **Tier 3** (git hooks) at commit/push boundaries — unaffected by the harness gap.

Treat an AntiGravity session as **Tier-3-gated only**. High-risk operations that Tier 1 would normally catch in Claude Code or Codex — `rm -rf`, schema mutations — have no turn-level backstop here and must be caught at the commit/push boundary or avoided.

## 2. The `execute` skill body is advisory-only — NOT enforcement

On Claude Code and Codex the `execute` skill body (`core-rules/skills/execute/`) is defense-in-depth on top of the hooks: it runs code-review and ui-verify in-body and emits the canonical receipt marker, and a per-turn diff-hash idempotency marker keeps the hooks from double-charging the same review. On AntiGravity the hooks are gone, so the same skill body becomes **advisory-only**: it still emits the byte-identical receipt marker (`<!-- dod-receipt … -->`) and still runs code-review/ui-verify in-body, but **nothing rejects the turn** — a skill body cannot fail-closed a turn, and `run-all.sh` carries no code-review/ui-verify/receipt gate to catch them at merge.

So on AntiGravity, **code-review, ui-verify, and receipts are SOFT (advisory, no automated backstop)**. The receipt marker the body emits is honest model discipline, not a gate. Do not read a clean in-body review on AntiGravity as an enforced one.

## 3. The deterministic merge gate DOES apply

AntiGravity runs no workspace hooks, but it **does** run git hooks, so it gets exactly two carriers at the boundary:

1. The **local `pre-push` git hook** (`core-rules/githooks/pre-push`, calling `run-all.sh --mode=merge`), which fires on every harness incl. AntiGravity and is **fail-closed at push** — and **not un-bypassable**: the only escape is an explicit `--no-verify` / direct-push, itself a logged tripwire caught by the daily `bypass-tripwire` audit (`scheduled-tasks/bypass-tripwire/`). It covers the **deterministic gate set only**: PR-hygiene / secrets / bypass / tests / docs / stack / security-diff / analyze.
2. Plain **branch protection** (require-PR on `main`).

This is real enforcement and it is identical on AntiGravity to every other harness — for the deterministic gates. It does **not** cover code-review, ui-verify, or receipts (§2): those three have no merge backstop on any harness, which on AntiGravity means they have **zero** automated enforcement, since the turn-level hooks that carry them elsewhere are absent here.

## 4. Standing rule — route risky / UI / edit-heavy runs through Claude or Codex

Because code-review, ui-verify, and receipts have no automated backstop on AntiGravity, the standing mitigation is: **route risky, UI, or edit-heavy runs through Claude or Codex**, where the turn-level hooks actually block, before the diff reaches the AntiGravity branch. Enable Claude Code alongside (`"harnesses": ["claude", "antigravity"]`) and run the risky change through a Claude session first — Tier 1 + Tier 2 protect the diff before it lands.

Reserve AntiGravity-only sessions for low-risk, read-mostly work where the absence of turn-level enforcement is acceptable and the deterministic merge gate plus branch protection are sufficient. When in doubt, move the turn to Claude or Codex.

```text
This is an AntiGravity session: no workspace hooks run, so code-review, ui-verify, and receipts are advisory only with no automated backstop. The deterministic merge gate (local pre-push run-all.sh --mode=merge) and branch protection still apply. Route any risky, UI, or edit-heavy change through a Claude or Codex session before it reaches the branch.
```

---

This gap is re-evaluated via a fresh ADR if and when a supported AntiGravity workspace hook API is published (`core-rules/inheritance.md`, "Known gap"). Until then, the framing above is the honest description of AntiGravity enforcement: deterministic gates hard at the merge boundary, code-review/ui-verify/receipts soft with no backstop, and the standing rule to route high-risk work through a hook-running harness.
