# ADR: Process parity + a mandatory feature pipeline via a deterministic gate

**Date:** 2026-07-07
**Status:** Accepted
**Relates to:** builds on `docs/adr/2026-07-05-automation-first-and-skill-foldin.md` (default-off-knob rule; deterministic-trigger-not-more-MUST) and spec `005` (Component-D, the harness-parity rule). Spec/plan/tasks/clarify: `specs/006-process-parity-and-mandatory-pipeline/`.

## Context

Two operator asks that turned out to share one root cause:

1. **Parity** — "processes should follow equally well on Codex and Claude Code" (empirically Claude follows better).
2. **Mandatory pipeline** — "every new feature should be specked, interviewed, planned, and tasked — every single time, whether or not the user asked."

Two read-only investigations (file:line-verified) found the hook **teeth** are already a near-perfect Claude/Codex mirror — hooks do *not* explain the parity gap. The gap is the large **prose-only** surface (the spec pipeline, brainstorming, proactive gates, `CLAUDE.md` doctrine) that both harnesses leave to model discretion; Codex, the weaker instruction-follower, complies less. That is the *same* mechanism-less surface ask 2 wants made mandatory. And the doctrine contradicted itself — `brainstorming` said "MUST unless surgical" while `spec`/`engineering-process`/`analyze` said "always opt-in."

Prior art (spec 005; Opus-4.8 steering) established the sanctioned way to make something "more automatic": a **deterministic trigger in front of an already-mandatory-in-prose skill**, *not* more `MUST` prose (Opus 4.8 over-triggers; Trellis chose restraint), and every new automation ships **default-off behind a knob** so a fresh install is unchanged.

## Decision

Close both asks with **one lever**: a deterministic pre-push gate keyed on git/filesystem state, so the *state* — not the model — decides.

1. **The spec-gate** (`spec-gate-core.sh`, a pure function of git/fs state; `spec-gate.sh` + a byte-identical Codex twin). Over a size floor, a branch's push is refused unless ONE of: a **spec triad added in this branch's range** (not merely existing — C-CRIT-1) and non-template (C-CRIT-2) + an interview artifact; a size-capped **`/surgical`** declaration; or a logged **`/surgical --emergency`** override. Because the verdict is a function of state, Codex cannot follow it *less* well — **parity by construction**.
2. **Teeth at pre-push** (a harness-agnostic git hook), with a **Stop-hook** early-warning on both manifests. The load-bearing enforcement is the git boundary, identical on both harnesses; the Stop hook is a convenience.
3. **Default-off knob** `mandatory_pipeline.enabled` (default `false`). Fresh installs + the public mirror are byte-unchanged; the operator turns it on in their own config. Present-but-malformed fails **closed**; a broken git env fails **open** (advisory).
4. **Scope = diff size over a floor**, never a fragile "new vs. existing" classification. Feature-scale work over the floor takes the triad; mechanical over-floor work takes `/surgical`; sub-floor work stays surgical-default.
5. **Autonomy is not bypassed and not a bright-line.** The gate's block fires the same at every level; *who answers* the intake interview follows the slider — L1–3 `clarify` interviews the user (`clarify.md`/waiver), L4/5 the agent self-answers (`decisions-log.md`).
6. **Doctrine reconciled** to one knob-conditional statement across ten files; `brainstorming`'s always-on design-gate is preserved and gains the gate-interaction clause (a recognized form — triad or `/surgical` — is required above the floor, closing the "declare a feature surgical" dodge).

## Consequences

- **Positive:** the enforcement gap between harnesses is closed at the mechanism level, not by asking Codex to try harder; "every feature gets specked" becomes enforceable rather than aspirational; the escape hatches (`/surgical`, emergency) keep it from taxing genuine one-liners, with an audit log so abuse is visible. Proven by a 25-case bats matrix incl. the deployed-Codex-twin producing an identical verdict + identical Stop-block.
- **Cost / risk:** a new gate on the push path — mitigated by default-off, fail-open on env breakage, and data-grounded thresholds (floor 80 / ceiling 400, from the fleet's net-source diff distribution). Risk that the Codex runtime has hooks disabled and the mechanism silently no-ops — mitigated by the new `doctor` check (`hc_codex_hooks_enabled`).
- **Invariants preserved:** default-off = byte-identical prior behavior; the PR-flow bright-line and the autonomy posture are unchanged; no in-file model conditionals (the branch is on git state, never on which model is running).
- **Deferred:** the PreToolUse Claude-leg hard-deny (advisory in v1, promote after a live-Codex Stop smoke); a live `codex exec` end-to-end demo (documented as a manual release-gate — the load-bearing pre-push teeth are harness-agnostic and the deployed-twin parity is proven deterministically).
