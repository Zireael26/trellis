# Dependency currency (weekly)

You are checking how **out-of-date** each active project's dependencies are. The sibling `dep-vulnerabilities` task tracks security; this task tracks staleness — patch behind, minor behind, major behind. Major-version drift on framework-tier packages (Next, React, Node, TypeScript, etc.) is also reported by `dep-major-upgrade-watch`; this task is the broad ecosystem view, that one is the curated framework view. They corroborate each other.

## Execution model (read this — supersedes any "host required" wording in older runs)

This audit runs in the standard scheduled-task sandbox (Linux aarch64). The sandbox has:

- **File tools** (`Read`, `Glob`, `Grep`) with access to `__SE_CORE_PATH__/` AND `__PROJECTS_ROOT__/<project>/`. Use these for all manifest / lockfile reads.
- **Bash sandbox** (`mcp__workspace__bash`) with `curl`, `jq`, and `npm` available, plus public-internet network. **Bash does NOT see `__PROJECTS_ROOT__/`.** Use bash only for HTTP queries to the npm registry.
- `pnpm`, `bun`, `pip`, `cargo-outdated`, `go` are **not** installed in the sandbox. Don't rely on `pnpm outdated` / `npm outdated` — they need `node_modules`. Compute "current" from lockfiles, "latest" from the registry HTTP API, and diff yourself.

**Proof point: `gotchas-rollup` Reads `<project>/gotchas.md` on every run and successfully collects content. `cross-project-process-audit` Reads per-project files and produces detailed findings. The same Read access is available to this audit. Do not assume otherwise.**

### Anti-patterns that broke earlier runs (do NOT repeat)

1. **Do not conclude "path missing" without attempting `Read` first.** Bash returning "No such file or directory" is expected (bash sandbox doesn't mount `personal/`). It does NOT mean the path is missing — `Read` can still see it.
2. **Do not copy-paste failure-mode templates pre-emptively.** Only emit "unreadable" findings against specific failed `Read` calls.
3. **Do not infer the runtime from prior audit reports.** A prior audit may say "sandbox-skipped" — that was a bug, not a true constraint.

If a specific `Read` call genuinely returns an error, record `unresolved (read-failed: <path>)` for that file. Continue with the rest.

When sampling worktree state, do NOT invoke `git status` against project worktrees — same `.git/index.lock` hazard as in `test-health`. Use direct `Read` of `.git/HEAD` instead.

## Inputs

1. `Read` `__SE_CORE_PATH__/registry.md`.
2. `Read` `__SE_CORE_PATH__/blacklist.md`.
3. Target set = `registry \ blacklist`.
4. Most recent prior `dep-currency` audit if present (use `Glob` over `audits/*-dep-currency.md`) — for the "drift change since last run" delta.

## Connected-folder preflight (do this FIRST, before per-project work)

This audit needs `Read` access to `__PROJECTS_ROOT__/<project>/`. Cowork mode bounds `Read` to **connected folders** — directories explicitly attached to the running session. The cron path inherits connected folders from the task's registration context; "Run now" inherits them from the calling Cowork session.

**Procedure:**

1. After reading the registry/blacklist, pick the first project in `registry \ blacklist`.
2. Attempt `Read` of `__PROJECTS_ROOT__/<that-project>/.git/HEAD`.
3. Branch on the outcome:
   - **Read succeeds** → `personal/` is connected. Continue with per-project scan.
   - **Read fails with "outside this session's connected folders"** → write a stub audit report at the canonical output path containing only:
     - Summary: `personal/ not connected; dep-currency cannot scan projects this run.`
     - One `info` finding: `personal/ not connected to this session. Add __PROJECTS_ROOT__/ via the Cowork folder selector and re-run, OR wait for the next cron-scheduled run (the cron path has personal/ in its registration-time folder set — gotchas-rollup runs successfully via cron, evidence the cron mounts work).`
     - Stop. **Do not** emit per-project "path missing" rows — they add noise without information.
   - **Read fails with any other error** (e.g., a project genuinely missing `.git/HEAD`): proceed with per-project scan. That's a per-project issue, handled at step 1 below.

## Per-project scan

Read-only via file tools.

### 1. Discover deps

**Do NOT use `**`-recursive globs.** They flood with `node_modules/`, `.codex/`, `.codex-backup-*/`, `.claude/worktrees/<agent>/`, and similar. Use the same explicit-Read + shallow-Glob procedure as `dep-vulnerabilities`:

- **Probe project root** with `Read` calls for canonical files (`package.json`, `pnpm-workspace.yaml`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Packages/manifest.json`, `ProjectSettings/ProjectVersion.txt`).
- **Unity nested-app probe**: if root has no Unity files and class is "game/Unity", try `<ProjectNameCapitalized>App/` and `<ProjectName>/` sub-paths (Lume convention is `LumeApp/`).
- **Workspace expansion**: parse `pnpm-workspace.yaml` `packages:` field or root `package.json#workspaces`. For each pattern like `apps/*`, use a shallow Glob `personal/<project>/apps/*/package.json` — never `apps/**/package.json`. Post-filter Glob results to drop paths containing `node_modules/`, `.next/`, `.nuxt/`, `.turbo/`, `.codex/`, `.codex-backup-`, `.claude/worktrees/`, `.git/`, `dist/`, `build/`, `out/`, `target/`, `Library/PackageCache/`, `.venv/`, `venv/`, `.svelte-kit/`, `__pycache__/` — Glob is suffix-matching and returns build-artifact paths that need to be filtered out.
- **Lockfile location**: `Read` (don't Glob) the canonical lockfile at each workspace root: `pnpm-lock.yaml`, `bun.lock`/`bun.lockb`, `package-lock.json`, `yarn.lock`, `poetry.lock`/`uv.lock`/`Pipfile.lock`, `Cargo.lock`, `go.sum`. pnpm uses a single project-root lockfile for all workspaces.

Tag each (project, workspace_path, ecosystem) tuple.

### 2. Read manifests → declared direct deps

For each workspace, `Read` the manifest and parse:

- **package.json**: `dependencies` → runtime-direct; `devDependencies` → dev-direct; `peerDependencies` → peer.
- **pyproject.toml**: `[project.dependencies]`, `[project.optional-dependencies.<group>]`, `[tool.poetry.dependencies]`, `[tool.poetry.group.dev.dependencies]`.
- **requirements.txt**: each non-comment line is a runtime-direct dep.
- **Cargo.toml**: `[dependencies]`, `[dev-dependencies]`, `[workspace.dependencies]`.
- **go.mod**: `require (...)` block; `// indirect` marker means transitive.

Capture: `(name, declared_range, bucket)` per dep.

### 3. Read lockfiles → resolved current versions

Same parsing as `dep-vulnerabilities` step 2 — same lockfile shapes apply. For each direct dep from step 2, find its resolved `current_version` in the lockfile.

If a direct dep appears in the manifest but not in the lockfile, that's a `warning` (`<workspace>: <pkg> declared but not in lockfile — install drift`).

### 4. Query the registry for "latest"

For each unique `(ecosystem, name)`, fetch upstream latest via bash + curl:

- **npm**: `curl -sS -m 10 https://registry.npmjs.org/<name>/latest | jq -r '.version'`. Returns the highest non-prerelease version on the `latest` dist-tag.
- **pypi**: `curl -sS -m 10 https://pypi.org/pypi/<name>/json | jq -r '.info.version'`.
- **crates.io**: `curl -sS -m 10 https://crates.io/api/v1/crates/<name> | jq -r '.crate.max_stable_version'`.
- **Go modules**: `curl -sS -m 10 https://proxy.golang.org/<module>/@latest | jq -r '.Version'`. Module name is path-encoded; use `python3 -c "import urllib.parse; print(urllib.parse.quote(...))"` if needed.

**Batching:** the npm registry doesn't have a true bulk endpoint, but it does serve a fast `https://registry.npmjs.org/<name>/latest` (just the latest version document, ~1 KB). Loop concurrently (`xargs -P 16 curl ...` or similar) to keep total time bounded. Per-project budget: 4 minutes.

Cache: per-run, dedupe `(ecosystem, name)` so each unique package is queried once across all projects.

### 5. Classify drift per dep

For each direct dep with current `C` and latest `L`:

- **patch-behind**: same major.minor, lower patch (`1.2.3 → 1.2.7`).
- **minor-behind**: same major, lower minor (`1.2.3 → 1.5.0`).
- **major-behind**: lower major (`1.2.3 → 2.0.0`).
- **prerelease**: `L` itself is a prerelease (`-rc`, `-beta`, `-alpha`). Don't flag the project as "behind" against a prerelease unless the project's `current` is also a prerelease of the same line.
- **on-target**: `C == L`.

Also compute `time_behind` if the registry response includes the publish date for `C` — npm's full document at `https://registry.npmjs.org/<name>` (no `/latest`) has `time.<version>`. Optional, fetched only when an entry surfaces in the report.

### 6. Bucket by importance

Per project, partition drift findings by manifest bucket:

- **runtime-direct** (`dependencies`)
- **dev-direct** (`devDependencies`)
- **peer** (`peerDependencies`)
- **transitive** (only in lockfile, not declared) — suppressed in this report. If a transitive package is a security finding, `dep-vulnerabilities` will surface it; that's the right place.

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-dep-currency.md`:

```
# Dependency currency — <date>

## Summary
- Projects scanned: <N>
- Total runtime-direct deps: <N>     dev-direct: <N>
- Major-behind (runtime-direct): <N>
- Minor-behind (runtime-direct): <N>
- Patch-behind (runtime-direct): <N>
- New majors released since last run (across all projects): <N>

## Major-behind — runtime-direct (action items)

| Project | Workspace | Package | Current | Latest | Days behind | Notes |
|---|---|---|---|---|---|---|
| neev | apps/web | next | 15.1.0 | 16.2.4 | <N> | also tracked in dep-major-upgrade-watch |

(Sort by days-behind descending. Cross-reference dep-major-upgrade-watch where applicable.)

## Minor-behind — runtime-direct

| Project | Workspace | Package | Current | Latest | Days behind |
|---|---|---|---|---|---|

(Show only deps >`MINOR_BEHIND_DAYS_THRESHOLD` days behind by default; threshold lives in targets.md.)

## Patch-behind summary

| Project | Patch-behind count | Oldest patch (days) |
|---|---|---|

(Per-package list moved to appendix; patch drift rarely individually actionable.)

## Dev-direct drift

| Project | Major-behind | Minor-behind | Patch-behind |
|---|---|---|---|

(Roll-up only. Full per-package list in appendix.)

## Drift change since last run

- New deps now flagged: <N>
- Resolved (caught up): <N>
- Worsened (jumped a class — minor → major): <N>

| Project | Package | Old class | New class |
|---|---|---|---|

## Skipped / unreachable projects

| Project | Reason |
|---|---|

## Cross-cutting observations

(E.g., "all 4 Next.js projects on different majors, no shared upgrade plan"; "TypeScript 5.7 → 6 hitting every project this week".)

## Appendix

### Full runtime-direct list

| Project | Workspace | Package | Current | Latest | Class | Days behind |
|---|---|---|---|---|---|---|

### Full dev-direct list

(same shape)
```

## Severity

- **critical**: a runtime-direct dep is `major-behind` AND the same advisory ID appears in today's `dep-vulnerabilities` audit at high/critical (i.e., upgrading would also fix a CVE).
- **warning**: runtime-direct major-behind, OR runtime-direct minor-behind with `time_behind > 180 days`, OR a manifest/lockfile mismatch (declared but not installed).
- **info**: everything else, including patch drift, dev-direct drift, registry timeouts, project-unreachable per-project skips.

## Boundaries

- **Read-only.** No `pnpm up`, no installs, no commits.
- HTTP traffic limited to public package registries (npm, pypi, crates.io, proxy.golang.org). No unrelated URLs.
- No issues / PRs / external messages.

## Sensible failure modes

- **Registry timeout**: per-project 4-min budget. On overrun, emit `warning` (`outdated query timed out`) and continue.
- **Single-package fetch failure**: emit `info` for that package (`<pkg>: registry fetch failed`) and continue.
- **Private registry**: if a workspace's `.npmrc` points at a private registry the audit doesn't have creds for, emit `warning` and report only public-registry-resolvable deps for that workspace.
- **Lockfile parse error**: emit `warning` and continue; capture parser error in appendix.
- **Manifest declares a dep not in the lockfile**: emit `warning` (`install drift`).
- **A specific `Read` call returns an error**: record `unresolved (read-failed: <path>)` for that single file. Continue with the rest. **Never** roll up to a whole-project skip. If you're about to emit "project X unreadable" for all projects, stop — you almost certainly haven't tried `Read`. `gotchas-rollup` and `cross-project-process-audit` Read project files successfully in this runtime.
- **First run**: no prior `dep-currency` audit exists → "Drift change since last run" is empty; note "first scheduled run; baseline established" in summary.
