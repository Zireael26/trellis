# Examples

Reference output from an upstream Trellis deployment (the framework was named SE Core prior to 2026-05-12). Project names have been redacted to `project-a`, `project-b`, etc. Use these to understand the report structure, severity taxonomy, and level of detail when designing private operator audits for your own registry.

## What's here

```
examples/
  audits/                                       # Sample audit reports (one per task type)
    2026-04-27-cross-project-process-audit.md   # Compliance audit (weekly) — the headline run
    2026-04-28-bypass-tripwire.md               # Silent-unless-tripped daily scan (clean-ish day)
    2026-05-01-dep-currency.md                  # Dependency drift report (weekly)
    2026-05-01-gotchas-rollup.md                # Rule-of-Three monthly aggregator
```

## How to read these

Each audit file lives at `audits/YYYY-MM-DD-<task>.md`. Its schema is governed by the operator-owned prompt that produced it; if you change a private prompt, expect its report schema to evolve.

## Once you're running your own audits

The live output dir is `audits/` at the repo root (initially empty, just a `.gitkeep`). You can keep these `examples/` for reference or delete the directory once your own history is sufficient — they're not load-bearing.
