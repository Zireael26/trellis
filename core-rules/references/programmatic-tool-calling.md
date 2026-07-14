# programmatic-tool-calling — batch a fan-out's tool calls in one pass

A cost-and-context discipline for tasks that fan out to **many** tool calls:
issue them from a **single code pass** and reduce the results **in the script**,
not by round-tripping every call and every raw result through the model. Adapted
from Anthropic's *Code execution with MCP* and *advanced tool use* (programmatic
tool calling, public beta) posts (2026). This is a **spike / pattern doc** — it
generalizes a pattern Trellis already uses in one place; it ships no tooling.

## The pattern

When a task calls the same tool (or a small set) across a **large, known
work-list** — one HTTP query per package, one read per file, one probe per
project — the naive shape is a call-per-item loop where the model sees, and pays
for, every intermediate result. Invert it:

1. **Batch the calls into one pass** — emit all N calls from a single `bash`/code
   step (a real batch endpoint where one exists; a loop inside one script where
   it doesn't), not N separate model turns.
2. **Reduce in the script, not the model** — filter, join, and summarize the raw
   results *in code*; the model receives the distilled finding, never the N raw
   payloads.

The bill grows with the size of the *answer*, not the size of the *fan-out*.
Trellis already applies the reflex to schema loading — load every deferred tool
in **one** `ToolSearch` call, not one per tool.

## The platform primitive

On the Anthropic API this shape is a first-class feature: **programmatic tool
calling** (public beta) lets the model write orchestration code that calls tools
inside a **code-execution sandbox**, so intermediate results are handled by the
code and only the summary re-enters context. Anthropic reports ~**38% fewer
billed input tokens** on a 75-tool agent benchmark with **no accuracy change**
(the related *Code execution with MCP* worked example reports up to ~98.7%).
Treat it as **capability-gated**, the way `loops.md` treats `/goal`: reach for the
primitive on the API, and for the hand-rolled pattern everywhere else.

## The Trellis precedent

The private dependency-vulnerability audit already does this. Its osv.dev step
batches by contract — "osv.dev also supports `POST /v1/querybatch` with up
to 1000 queries per call. Use it. Single-query loops will exhaust the per-project
budget on a 2k-package pnpm-lock." One `curl` pass covers a whole lockfile; the
script parses the response and the model sees only the advisories. The
generalization: **any audit that fans out over a work-list should batch the same
way.**

## When to use

- An audit or task issuing **many** independent, mostly-mechanical tool calls
  over a known work-list — a rough floor is a dozen-plus, or one-per-target
  across the registry. Below that a plain loop is fine; the pattern is overhead.
- The per-call results **don't each need the model's judgment** — they are
  fetched, filtered, reduced. If every result decides *what you call next*, the
  work is genuinely sequential and this doesn't apply.
- Read-mostly fan-out especially — scans, digests, currency / vuln sweeps — where
  raw payloads are large and the distilled answer is small.

## Relationship to other surfaces

- `orchestrate` — a **different axis**: it fans out across *agents*, each doing
  its own reasoning; this batches *tool calls* inside *one* pass, where code (not
  the model) processes each result. An orchestrated agent whose unit is a fan-out
  audit should batch its tool calls this way.
- `core-rules/references/loops.md` — the batch pass is one iteration of a
  time-based / proactive audit loop; this keeps that iteration cheap.
- `core-rules/skills/orchestrate/references/codex-executor.md` — a batched
  fan-out is the kind of execution-heavy bounded unit an executor node runs.
- `core-rules/references/source-driven-development.md` — the platform claims
  above are source-cited per this discipline; re-verify the beta's specifics
  against the current docs before relying on them.
