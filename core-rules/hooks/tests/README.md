# Hook test suite

Bats tests for the SE Core hook layer. Scope as of plan task **P3.1** is
**regression coverage for the Phase 1 fixes** (P1.1–P1.5). Broader coverage
(every hook code path, ≥80%) is deferred to a follow-up task — the suite
infrastructure is in place to grow.

## Running

```bash
# install bats (macOS): brew install bats-core
bats core-rules/hooks/tests/
```

CI runs the suite via `.github/workflows/bats.yml`.

## Files

| File | Covers |
|---|---|
| `helpers.bash` | shared setup helpers (project-dir scaffold, jq-free PATH builder, run-with-stderr wrapper) |
| `block-destructive.bats` | P1.1 (rm-rf rule covers absolute paths), P1.2 (DELETE-without-WHERE handles terminated SQL), P1.5 (jq fail-closed) |
| `stop-verify.bats` | P1.3 (todo check runs before dirty-tree skip; stop_hook_active short-circuit) |
| `save-context-log.bats` | P1.4 (JSONL filter excludes tool_result wrappers; envelope validation) |
| `jq-fail-closed.bats` | P1.5 across all 18 hooks (Claude + Codex) — fails closed without env, degrades cleanly with `SE_CORE_NO_JQ_DEGRADE=1` |

## Authoring conventions

- One `.bats` file per hook (or per cross-cutting concern like `jq-fail-closed.bats`).
- Tests start with the plan task ID they cover (`P1.1:`, `P1.5:`).
- Use `helpers.bash` for project-dir setup + jq-free PATH; don't reinvent.
- Don't depend on host-installed toolchains (npx/cargo/go) — those tests should mock or skip.
