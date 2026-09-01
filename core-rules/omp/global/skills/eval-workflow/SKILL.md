---
name: eval-workflow
description: OMP dynamic workflows via eval. Use named agents per stage, with names selected by the live role resolver or an explicit operator choice. Use whenever the user says workflow, eval, fan-out, parallel agents, or wants different models for different stages.
---

# eval-workflow

OMP `eval` **is** the workflow VM. Mix workers by the `agent` name selected by
the live role resolver or operator. The parent session remains the orchestrator
at its active effort ceiling; never request an unsupported max tier. Do not
install Pi packages. Do not fan out through `hub`. Do not use Anthropic/Claude
models on OMP.

`agent()` has no `model` field. Named agents carry the model from live role
configuration.

**Operator-named agent wins.** Otherwise use the live role resolver; do not infer
a roster, provider, model, or price from this skill.
When a fan-out is warranted beyond a handful of tool calls, use the same **≥2
independent bounded units concurrently** convention; state why that floor cannot
be met, and keep tiny or dependent work inline.

## Fit table

| Unit shape | choose | evidence |
|---|---|---|
| Scan, classify, latency-sensitive | a live eligible candidate in a suitable family | verified TTFT and availability |
| High-volume similar units | a live eligible low-cost candidate in a capable family | verified throughput and current cost |
| Mechanical coding against an oracle | a live eligible capable candidate | oracle result and published eval |
| Hard, weak-oracle, or security-sensitive | a live eligible high-capability candidate at `xhigh` | tier definition and independent review |
| Independent review | a live eligible fresh candidate from a family not authoring the unit | author/reviewer family receipt |

The resolver's current role chain supplies the candidate. An explicit eligible
operator selection takes precedence. This table describes unit shape only; it
does not encode a model, provider, roster, or price.

Advisor is `/advisor on`, not `agent()`. Planning stays on the orchestrator seat
at its active effort ceiling.

## Compile

Same-shape units share one `agent` string. One JS `eval` cell.

```js
// `roles` is loaded from the live roles-resolved artifact; operator selection
// has already taken precedence when present.
const scanAgent = roles.scout.chosen.agent
const implementAgent = roles.implementer.chosen.agent
const reviewAgent = roles.reviewer.chosen.agent

phase("Scan")
const files = await agent("List target files. Return string[].", {
  agent: scanAgent,
  schema: { type: "array", items: { type: "string" } },
})

phase("Implement")
const results = await parallel(
  files.map((f) => () =>
    agent(`Unit for ${f}. Files: [${f}]. Done when: <proof>. Touch nothing else.`, {
      agent: implementAgent,
      label: f,
      schema: VERDICT,
      isolated: true,
    }),
  ),
)

phase("Review")
return await agent(
  "Fresh review. Default not-done unless proof holds.\n" + JSON.stringify(results),
  { agent: reviewAgent, schema: REVIEW },
)
```

Always `schema` on results a later stage reads. Mutating units `isolated: true`.
Workers never commit/merge.

If the operator requests an agent or effort unavailable in this harness, say so
and stop; do not silently substitute.

## Do not

- `agent(prompt, { model: "..." })` — stripped
- Per-call model selection or an unsupported max effort tier
- Anthropic/Claude on OMP
- Named `hub` teammates for fan-out
- Review on the producer
