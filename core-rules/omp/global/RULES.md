# OMP sticky rules

- **Sol effort is `xhigh` only.** Never `gpt-5.6-sol:max`. Max overthinks.
- **No Anthropic/Claude models in this harness.** Subscription stays off OMP.
- **Eval is the workflow VM.** Mix workers with `agent({ agent: "<resolved-name>" })`; the name comes from the live role resolver or an explicit operator choice. No per-call `model`, Pi packages, or `hub`/teammate fan-out.
- **Operator-named agent wins.** If the operator names an eligible agent, use that exact name; otherwise defer to the live role resolver.
- **Resolver owns default routing.** The orchestrator remains the parent; workers never commit/merge; review is a fresh resolver-selected reviewer, never the producer. Do not infer a roster or provider from this file.
- **Fan-out by default.** Eligible work has ≥2 genuinely independent bounded units and exceeds a handful of tool calls. When a request explicitly lists eligible files, projects, questions, or other targets, treat that list as the unit boundary: do only shared discovery inline, then dispatch one `parallel()` wave with one bounded `agent()` per target before per-target work. For eligible work without an explicit list, derive and dispatch ≥2 independent bounded units concurrently or state why that floor cannot be met. Never batch eligible targets into one shell or tool call; set-wide mechanical work whose per-item results need no model judgment is not eligible and stays inline. Tiny single-unit, dependent, or mechanical work stays inline. This is the one fan-out convention.
