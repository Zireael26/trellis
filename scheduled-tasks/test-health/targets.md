# Targets — test-health

Reads `__SE_CORE_PATH__/registry.md` at runtime. Target set = `registry \ blacklist`.

## Runner requirement (REQUIRED — not optional)

**Run on the macOS host, not the default linux-arm64 scheduled-task sandbox.**

The registered projects' `node_modules` trees are installed on macOS-arm64. When the task runs in the linux-arm64 sandbox, every JS test errors at module load (`@rollup/rollup-linux-arm64-gnu` / `@rolldown/binding-linux-arm64-gnu` missing). `bun` and `pytest` are also not present in the sandbox.

Configure the scheduler to dispatch this task to the host (or to a worktree whose `node_modules` matches the sandbox arch). Until this is done, `test-health` produces only meta-findings and cannot verify any suite is green.

If the task detects it is running in an environment where `[ "$(uname)" = "Darwin" ]` is false AND the registered projects are unreachable at the canonical path, emit a single **info** finding — `test-health requires host execution; sandbox run skipped` — and exit.

## Scope

- Weekly, Monday at 11 AM — after `cross-project-process-audit` (10 AM) and `registry-blacklist-health` (10:30 AM). Ordering intentional: we want process/registry issues surfaced first, so if the registry is broken we know before spending 5 minutes/project running tests.

## Per-project overrides

Override the default test command for a project by adding a line here:
```
# <project-name>: <command>
```

E.g., if Neev's "fast" suite is `pnpm test:unit` (not `pnpm test`), override it here.

No overrides set as of 2026-04-20.

## Skip list

Projects that can't be tested automatically (e.g., needs GPU, needs production DB):

```
# <project-name>: <reason>
```

No skips set as of 2026-04-20.
