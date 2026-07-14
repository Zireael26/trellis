---
description: Declare the current branch's change size-capped and spec-exempt, so the mandatory-pipeline gate lets the push through. --emergency for urgent over-cap work.
argument-hint: "<why this needs no spec>"  |  --emergency "<why>"
---

# Surgical: $ARGUMENTS

You are declaring that the work on **this branch** is a small, mechanical, or
otherwise spec-exempt change — the escape hatch built into the mandatory-pipeline
gate (spec 006). The gate blocks a push that carries more than the size floor of
feature code with no spec triad behind it; a valid surgical declaration is one of
the three ways past it (spec triad, surgical, emergency).

This is a **deliberate, size-capped** exemption, not a bypass. It writes a
branch-bound marker that the deterministic gate honors only while the binding
holds (same branch, same worktree, same merge-base). Grow the diff past the
surgical ceiling and the marker stops working — the gate re-blocks and audit-logs
the oversized claim. That cap is the whole point: surgical is for genuinely small
changes, and the size limit keeps it honest without asking the model to judge.

See `engineering-process.md` (§ mandatory pipeline) / `specs/006-process-parity-and-mandatory-pipeline`
for the full gate contract and `core-rules/hooks.md` for the marker format.

## When this is the right call

- A rename, a typo fix, a dependency bump, a config tweak, a comment pass.
- A one-file mechanical refactor with no behavior change.
- Anything where writing a spec triad would cost more than the change is worth
  AND the net gated diff stays under the surgical ceiling.

If the change introduces or alters real behavior, or is large, this is the wrong
command — run `clarify -> spec -> plan -> tasks` instead. Surgical does
not exempt you from the pipeline for a real feature; it just records that *this*
change is not one.

## Steps

### 1. Parse the argument

- `$ARGUMENTS` starts with `--emergency` → **emergency** mode. The rest of the
  line is the reason.
- Otherwise → **surgical** mode. The whole line is the reason.
- Empty reason → print one line and stop:
  > Usage: `/surgical "<why this needs no spec>"` — or `/surgical --emergency "<why>"` for urgent over-cap work.

A reason is **required** in both modes. The marker records it; the audit log
records it for emergency and oversized claims. Do not invent a reason — if you
cannot state honestly why this needs no spec, it probably needs one.

### 2. Locate the harness-neutral entrypoint

The gate script is deployed per-project. Prefer the Claude path, fall back to the
Codex/agents path:

```bash
if [ -f .claude/hooks/spec-gate.sh ]; then SPECGATE=.claude/hooks/spec-gate.sh
elif [ -f .codex/hooks/spec-gate.sh ]; then SPECGATE=.codex/hooks/spec-gate.sh
elif [ -f .agents/hooks/spec-gate.sh ]; then SPECGATE=.agents/hooks/spec-gate.sh  # legacy fallback
else echo "spec-gate not installed (run scripts/onboard-project.sh)"; fi
```

### 3. Write the marker

Do **not** hand-write the marker file — the gate parses seven exact fields
(branch, worktree, merge-base, HEAD, session, mode, reason) and a
hand-written one will silently fail to bind. Let the mechanism write it:

- Surgical:
  ```bash
  bash "$SPECGATE" --mark "<reason>"
  ```
- Emergency:
  ```bash
  bash "$SPECGATE" --mark-emergency "<reason>"
  ```

The writer computes the branch/worktree/merge-base binding from live git state,
so run it from inside the branch's worktree (any subdirectory is fine).

### 4. Acknowledge

Print exactly one line to the user:

- Surgical:
  > Marked this branch surgical (size-capped, spec-exempt): `<reason>`. Keep the net gated diff under the surgical ceiling or the gate re-blocks.
- Emergency:
  > Marked this branch **emergency** (any-size override, audit-logged): `<reason>`. This obligates a post-facto spec — open one before the next feature.

## What this command does NOT do

- It does not disable the gate — it satisfies one of its three routes for this
  branch only.
- It does not raise the ceiling. An over-ceiling surgical claim is invalid and
  audit-logged as `oversized-surgical`; use `--emergency` for genuine over-cap
  urgency, and expect the follow-up spec obligation.
- It does not touch `trellis.config.json`, the spec triad, or any other branch.
- It does not survive a rebase onto a new merge-base or a move to another
  worktree — the binding intentionally breaks, so re-run it if you rebase.

## Boundaries

- **Branch-scoped + bound.** The marker lives at `<canonical-root>/.claude/session-surgical`
  (gitignored) and is honored only on a full bind match. A stale marker from a
  different branch/worktree/base is ignored, not trusted.
- **Emergency is logged, not free.** Every emergency override appends a line to
  `<canonical-root>/.claude/spec-gate-audit.log` and every oversized surgical
  claim appends an `oversized-surgical` line. The cross-project process audit
  surfaces these — an emergency without a follow-up spec is a visible debt.
- **Deterministic + harness-equal.** The gate that reads this marker is a pure
  function of git/filesystem state, so `/surgical` behaves identically under
  Claude and Codex. Parity by construction, not by prose.
