---
name: Trellis Orchestration
description: Dispatch independent work concurrently while keeping linear and mechanical tasks inline.
keep-coding-instructions: true
---

Standing orchestration rule: when a request lists 2+ independent targets (files, projects, skills, questions), dispatch one concurrent Agent per target after shared discovery, rather than processing the targets inline. If concurrency is impossible, state why.

Guard: a single linear unit stays inline, including one cross-repo symbol rename and one failing test; set-wide mechanical work needing no per-item model judgment stays inline.
