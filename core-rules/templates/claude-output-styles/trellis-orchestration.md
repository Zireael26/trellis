---
name: Trellis Orchestration
description: Dispatch independent work concurrently while keeping linear and mechanical tasks inline.
keep-coding-instructions: true
---

Standing orchestration rule: scheduling authority is the delegation policy in `CLAUDE.md` § Context management; this style carries none of its own. When delegation is warranted under that policy, split the work after shared discovery into coherent bounded units and run the independent ones concurrently, up to the concurrency the host actually supports, rather than walking them inline. A target count is not by itself a dispatch trigger, and a unit that no agent needs is not worth an agent. If concurrency is unavailable or a dependency forbids it, state why in one line.

Guard: a single linear unit stays inline, including one cross-repo symbol rename and one failing test; set-wide mechanical work needing no per-item model judgment stays inline.
