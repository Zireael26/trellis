# GPT-5.x prompting — steering reference

Source: the Trellis process-enforcement design (`docs/specs/2026-06-02-trellis-process-enforcement-design.md`, §4 cross-harness framing) — the levers pinned there, not model recall. This doc deliberately covers **only** the levers the design pinned for the GPT-5.x / Codex harness; it does not enumerate the model's full API surface. Where the exact configuration surface is not verifiable from the design, the lever is described as steering **intent** rather than a concrete flag, parameter name, or value — inventing those for a published, fleet-wide doc is the one failure mode this artifact must not have.

GPT-5.x is Trellis's secondary harness (Codex). The spine — hooks, the autonomy slider, the context-log/primer system, the merge gates — is model-agnostic and already steers every harness identically. This doc carries only the genuine per-harness reporting/affordance deltas (verbosity, plan tracking, progress cadence). The load-bearing rules live in `core-rules/CLAUDE.md`, `core-rules/autonomy.md`, and the hooks — this is the why and the spare parts for the GPT-5.x deltas.

**Reasoning effort and cross-model routing are NOT restated here — they are governed by `docs/codex-routing.md`.** In brief: effort is governed by the dispatch-time ladder in `docs/codex-routing.md §3` — an operating band plus exception tiers, with effort declared explicitly per unit at dispatch, never defaulted — and the reasoning-heavy stages (planning, spec, architecture, the `analyze` gate, synthesis) route to **Claude**, not to a Codex effort-lift. The earlier "raise Codex effort from a medium baseline at plan/analyze" framing was retired in RC.5: it implied a medium baseline that contradicted the then-current routing.

---

## 1. Verbosity — low, calibrated to task

Keep verbosity low: short on lookups and confirmations, longer only on genuinely open-ended analysis. This maps to the same Trellis surface Opus uses — `core-rules/CLAUDE.md` "Communication" ("Terse responses. No trailing prose summaries") — so no rule change is needed; the GPT-5.x default is steered to honor the existing house voice rather than narrate.

The intent, for a project whose harness exposes a verbosity control or for a `CLAUDE.md` reminder:

```text
Keep responses concise and low-verbosity. Skip non-essential preamble and trailing summaries. Match length to task complexity — terse on lookups and confirmations, expansive only on open-ended analysis.
```

## 2. Plan tracking and parallel tool use — `update_plan` + `multi_tool_use.parallel`

Two named GPT-5.x affordances map onto the dispatch and state-tracking behavior Trellis already expects:

- **`update_plan`** — keep the working plan current as tasks complete. This is the GPT-5.x-native counterpart to the `execute` loop's checkbox-tick discipline (`core-rules/skills/execute/`): the plan is the live state, ticked as each unit lands, not a stale snapshot. Use it so the agent's tracked plan and the on-disk plan/tasks file stay in step across a long run.
- **`multi_tool_use.parallel`** — issue independent tool calls together. This honors `core-rules/CLAUDE.md` "Context management", which already directs batching independent reads/searches/analyses rather than serializing them. The reusable snippet (shared with `docs/opus-4.8-steering.md §3`):

  ```text
  If you intend to call multiple tools and there are no dependencies between the tool calls, make all of the independent tool calls in parallel. For example, when reading 3 files, run 3 tool calls in parallel. However, if some tool calls depend on previous calls to inform dependent values, do NOT call them in parallel — call them sequentially. Never use placeholders or guess missing parameters in tool calls.
  ```

Use `update_plan` and `multi_tool_use.parallel` by their GPT-5.x names where the harness provides them; the underlying discipline (live plan, batched independent calls) is what the Trellis surfaces already require of every harness.

## 3. Progress floor — surface progress on a cadence

This is the one genuine GPT-5.x delta the design sanctions, and it runs **opposite** to the Opus guidance: `docs/opus-4.8-steering.md` deliberately does **not** add "summarize every N tool calls" scaffolding (4.8 already paces its own updates well). For GPT-5.x the design pins a **progress floor** — surface progress on a regular cadence during a long autonomous run, roughly every **6 steps** or **10 tool calls**, whichever comes first — so a multi-step run stays legible to the operator and to the context-log/primer system rather than going dark for a long stretch.

This is a per-harness delta, not an override of the spine: it changes only the GPT-5.x reporting cadence, nothing about what work gets done or which gates fire. The intent:

```text
On a long autonomous run, surface a brief progress update on a regular cadence — roughly every 6 steps or every 10 tool calls, whichever comes first — so the run stays legible. Keep each update short (current step, what's next); this is a floor, not an invitation to narrate every action.
```

---

This doc covers only the design-pinned GPT-5.x reporting/affordance levers above. It intentionally does not catalog or reject other features — the spine in `core-rules/` already steers GPT-5.x identically to every other harness, and reasoning effort / routing lives in `docs/codex-routing.md`. If a future design revision pins another GPT-5.x-specific lever, it lands here next to these, sourced to the design rather than to model recall.
