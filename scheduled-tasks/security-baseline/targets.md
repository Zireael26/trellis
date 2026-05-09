# Targets — security-baseline

Reads `__SE_CORE_PATH__/registry.md` at runtime. Target set = `registry \ blacklist`.

## Runner requirement (REQUIRED — not optional)

**Run on the macOS host, not the default linux-arm64 scheduled-task sandbox.**

This task invokes the canonical OSS engines pinned by `core-rules/skills/security-gate/SKILL.md`:

- `semgrep` (brew)
- `osv-scanner` (brew)
- `gitleaks` (brew)
- `llm` (pipx) — optional; the task runs with `--no-llm` when no provider key is configured.

None of those are present in the linux-arm64 scheduled-task sandbox. The registered projects' `node_modules` trees are also macOS-arm64-installed; lockfile parsing works either way but Semgrep's path-resolution and Gitleaks' git-history reads need the real working tree at the canonical path.

If the task detects it is running where `[ "$(uname)" = "Darwin" ]` is false AND the registered projects are unreachable at the canonical path, emit a single **info** finding — `security-baseline requires host execution; sandbox run skipped` — and exit. Match the test-health failure mode exactly.

## Cadence

- **Quarterly** — `0 5 1 1,4,7,10 *` — 1st of January, April, July, October at 05:00 local time.
- Picked early-morning so the scan completes (10–60 min/project × 6 projects ≈ up to 6 hours) and the rollup is on disk before the workday starts.
- Each Mode 1 baseline rewrites the project's `audits/<date>-baseline-<project>.{md,json}`. Diff scans (Mode 2, per-push) read whichever JSON is newest, so the cadence directly controls the dedupe horizon.

## Per-project overrides

Override the default profile or LLM provider for a specific project. Format:

```
# <project-name>: <key>=<value> [<key>=<value> ...]
```

Recognized keys: `profile`, `llm_provider`, `llm_model`, `skip` (any value), `audit_dir`.

E.g.:
```
# vericite: profile=web-rag-llm llm_provider=anthropic llm_model=claude-opus-4-7
# lume:     profile=unity-game
# akaushik.org: profile=web-static
```

No overrides set as of 2026-05-08. Per-project `local.config.sh` (under `.claude/skills/security-gate-local/`) takes precedence over these — the override here is a fleet-wide knob; the project-local config is the source of truth for that project's defaults.

## Skip list

Projects to exclude this run only:

```
# <project-name>: <reason>
```

Use `blacklist.md` for permanent exclusions (skips all scheduled tasks). Use this section for "quarterly skip with reason" — e.g., a project mid-rewrite where the baseline would be all noise.

No skips set as of 2026-05-08.

## Output paths

Per-project artifacts (overwritten each run — earlier baselines are recoverable from git history):

- `<project>/audits/<YYYY-MM-DD>-baseline-<project>.md`
- `<project>/audits/<YYYY-MM-DD>-baseline-<project>.json`

Fleet rollup (new file each quarter):

- `__SE_CORE_PATH__/audits/<YYYY-MM-DD>-security-baseline-rollup.md`
