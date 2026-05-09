# Dependency vulnerabilities (weekdays)

You are scanning every active project's dependency graph for **known security vulnerabilities** (CVEs / GHSAs). The matching `dep-currency` task tracks "is this version old?"; this task tracks "is this version *unsafe*?". They are intentionally separate because CVE feeds update daily and a critical advisory should not have to wait for the weekly currency run.

## Execution model (read this — supersedes any "host required" wording in older runs)

This audit runs in the standard scheduled-task sandbox (Linux aarch64). The sandbox has:

- **File tools** (`Read`, `Glob`, `Grep`) with access to `__SE_CORE_PATH__/` AND `__PROJECTS_ROOT__/<project>/`. Use these for all lockfile / manifest reads. The `cross-project-process-audit` audit uses the same access pattern successfully.
- **Bash sandbox** (`mcp__workspace__bash`) with `curl`, `jq`, and `npm` available, plus public-internet network. **Bash does NOT see `__PROJECTS_ROOT__/`.** Don't `ls` or `cat` project files from bash — it will return "No such file or directory" and an earlier version of this audit mistook that for "project paths unmounted." Use `Read` / `Glob` for project paths; use bash only for HTTP calls.
- `osv-scanner`, `pnpm`, `bun`, `cargo`, `go` are **not** installed in the sandbox. Don't rely on them. Vulnerability data comes from osv.dev's HTTP API directly.

**Proof point: `gotchas-rollup` Reads `<project>/gotchas.md` on every run and successfully collects content from each registered project. `cross-project-process-audit` Reads per-project `.claude/`, `.husky/`, `CLAUDE.md`, etc. and produces detailed per-file findings. The same Read access is available to this audit. Do not assume otherwise.**

### Anti-patterns that broke earlier runs (do NOT repeat)

1. **Do not conclude "path missing" without attempting `Read` first.** Bash returning "No such file or directory" is expected (bash sandbox doesn't mount `personal/`). It does NOT mean the path is missing — it means bash can't see it. `Read` can.
2. **Do not copy-paste failure-mode templates pre-emptively.** If you find yourself emitting "<project>: project paths unreadable" without a corresponding failed `Read` call, stop and actually try the `Read`.
3. **Do not infer the runtime from prior audit reports.** A prior audit may say "sandbox-skipped" or "path missing" — that was a bug in the previous audit's logic, not a true runtime constraint.

If a specific `Read` call genuinely returns an error (not just "no such ecosystem file"), record `unresolved (read-failed: <path>)` for that file. Continue with the rest. Never roll up to a whole-project skip without per-file evidence.

When sampling worktree state, do NOT invoke `git status` against project worktrees — the audit-sandbox `.git/index.lock` permission shape leaves a 0-byte lockfile behind. Use direct `Read` of `.git/HEAD` and `.git/refs/heads/<branch>` instead.

## Inputs

1. `Read` `__SE_CORE_PATH__/registry.md`.
2. `Read` `__SE_CORE_PATH__/blacklist.md` (both sections).
3. Target set = `registry \ blacklist` (sections 1 + 2).
4. Read prior audit at `__SE_CORE_PATH__/audits/<previous-date>-dep-vulnerabilities.md` if present (use `Glob` to find the most recent) — used only for the "newly introduced this run" delta.

## Connected-folder preflight (do this FIRST, before per-project work)

This audit needs `Read` access to `__PROJECTS_ROOT__/<project>/`. Cowork mode bounds `Read` to **connected folders** — directories explicitly attached to the running session. The cron path inherits connected folders from the task's registration context; "Run now" inherits them from the calling Cowork session.

**Procedure:**

1. After reading the registry/blacklist, pick the first project in `registry \ blacklist`.
2. Attempt `Read` of `__PROJECTS_ROOT__/<that-project>/.git/HEAD`.
3. Branch on the outcome:
   - **Read succeeds** → `personal/` is connected. Continue with per-project scan.
   - **Read fails with "outside this session's connected folders"** → write a stub audit report at the canonical output path containing only:
     - Summary: `personal/ not connected; dep-vulnerabilities cannot scan projects this run.`
     - One `info` finding: `personal/ not connected to this session. Add __PROJECTS_ROOT__/ via the Cowork folder selector and re-run, OR wait for the next cron-scheduled run (the cron path has personal/ in its registration-time folder set — gotchas-rollup runs successfully via cron, evidence the cron mounts work).`
     - Stop. **Do not** emit per-project "path missing" rows — they add noise without information.
   - **Read fails with any other error** (e.g., genuine "file not found" for a project that doesn't have `.git/HEAD`): proceed with per-project scan. That's a per-project issue, handled at step 1 below.

## Per-project scan

Work via file tools, not bash, for everything project-local.

### 1. Discover the dependency surface

**Do NOT use `**`-recursive globs.** They flood with `node_modules/`, `.codex/`, `.codex-backup-*/`, `.claude/worktrees/<agent>/`, and similar. Use explicit `Read` calls for known paths and **shallow** `Glob` (no `**/`) for workspace expansion. Discovery procedure:

**Step 1.1 — Probe the project root.** For each target `<project>`, attempt `Read` (one at a time; "file not found" is expected for irrelevant ecosystems):

- `personal/<project>/package.json` — Node single-package or monorepo root
- `personal/<project>/pnpm-workspace.yaml` — pnpm monorepo discriminator
- `personal/<project>/pyproject.toml` — Python
- `personal/<project>/Cargo.toml` — Rust
- `personal/<project>/go.mod` — Go
- `personal/<project>/Packages/manifest.json` — Unity at root
- `personal/<project>/ProjectSettings/ProjectVersion.txt` — Unity at root

**Step 1.2 — Unity nested-app probe.** If neither root `Packages/manifest.json` nor root `ProjectSettings/ProjectVersion.txt` was found AND the project's class in registry includes "game/Unity", probe these conventional nested layouts (Lume uses `LumeApp/`):

- `personal/<project>/<ProjectNameCapitalized>App/Packages/manifest.json`
- `personal/<project>/<ProjectName>/Packages/manifest.json`

If found, set the Unity project root accordingly. If not found anywhere, emit `info` (`<project>: Unity manifest not found at root or conventional sub-paths`) and skip Unity scanning for the project.

**Step 1.3 — Workspace expansion (Node monorepos).** If `pnpm-workspace.yaml` exists, `Read` it and parse the `packages:` field. If the root `package.json` has `"workspaces"`, parse that array instead. Each entry is a glob pattern relative to the project root, e.g., `apps/*`, `packages/*`.

For each workspace pattern, expand with a **shallow** Glob — replace the trailing `*` (or `**`) with a concrete depth-1 match against `package.json`:

- Pattern `apps/*` → Glob `personal/<project>/apps/*/package.json`
- Pattern `packages/*` → Glob `personal/<project>/packages/*/package.json`
- Pattern `*` → Glob `personal/<project>/*/package.json` (rare, but supported)
- Pattern `apps/**` (deep) → flatten to depth-2 with `apps/*/package.json` and `apps/*/*/package.json`; do NOT use `apps/**/package.json` literally.

**Post-filter Glob results.** The Glob tool in this runner is noisy — it can return paths under build artifact directories that match the filename. After every Glob, drop any result whose path contains any of these segments anywhere:

```
node_modules/  .next/  .nuxt/  .turbo/  .codex/  .codex-backup-  .claude/worktrees/
.git/  dist/  build/  out/  target/  Library/PackageCache/  .venv/  venv/
.svelte-kit/  __pycache__/
```

The remaining set is the real workspaces.

If a project declares no workspaces, treat the project root itself as the only workspace.

**Step 1.4 — Lockfile location per workspace.** Lockfiles are at the workspace root — for pnpm, the project root only (pnpm uses a single root lockfile for all workspaces); for npm/yarn/bun, usually the same, occasionally per-workspace. `Read` (don't Glob) the canonical filenames at each workspace root, in this order:

- `pnpm-lock.yaml` (project root only — pnpm-workspaces don't have per-workspace lockfiles)
- `bun.lock`, then `bun.lockb` (binary fallback)
- `package-lock.json`
- `yarn.lock`
- `poetry.lock` / `uv.lock` / `Pipfile.lock` for Python
- `Cargo.lock` for Rust
- `go.sum` for Go
- `Packages/packages-lock.json` for Unity (relative to the resolved Unity project root from step 1.2)

Tag each (project, workspace_path, ecosystem, lockfile_path) tuple.

If a project has no recognizable manifest at all (steps 1.1, 1.2 both empty), mark `no-deps-detected` and continue — that itself is worth recording.

If a Unity project has `Packages/manifest.json` but no `Packages/packages-lock.json`, emit `info` (`<project>: Unity packages-lock.json missing — re-resolve in Editor to enable scanning`) and skip vuln scanning for that project.

### 2. Parse lockfiles → (package, ecosystem, version) pairs

Read each lockfile with the `Read` tool. Parse without external libraries — these are all human-readable text.

- **pnpm-lock.yaml** (v6/v9): under `importers.<workspace>.dependencies` and `importers.<workspace>.devDependencies` you find direct deps; under `packages:` you find every resolved version (key format `/<name>@<version>`). Emit one `(npm, name, version)` pair per `packages:` entry. Track which were direct (appeared under `importers`) vs. transitive.
- **package-lock.json** (npm v7+): under `packages` (lockfile v3) each path key like `node_modules/<name>` has a `version` field. Top-level `""` packages key has `dependencies`/`devDependencies` listing the *direct* set.
- **yarn.lock** (v1): pattern matches like `<name>@<range>:` then a `version:` line. yarn-berry (`__metadata: version: <n>`) uses the same shape but with a YAML-ish syntax — same parse.
- **bun.lock**: TOML-ish; key `packages` table entries like `[packages."<name>"]` with a `version`. Treat like npm.
- **bun.lockb**: binary. Cannot parse without bun. Emit an `info` for that workspace and fall back to its `package.json` declared ranges (which is much weaker — no transitive coverage). Recommend the user commit a text `bun.lock` alongside `bun.lockb`.
- **poetry.lock / uv.lock**: TOML. `[[package]]` tables with `name` and `version`. Ecosystem `pypi`.
- **Cargo.lock**: TOML. `[[package]]` tables. Ecosystem `crates`.
- **go.sum**: text, lines `<module> <version>/<hash>`. Ecosystem `go`. Note: go.sum has multiple entries per module (mod and go.mod hashes); de-dup to the highest version per module.
- **Packages/packages-lock.json** (Unity): JSON. `dependencies.<name>.version`. Ecosystem `nuget` if the version looks like NuGet, otherwise `unity-registry` (osv.dev does not currently cover unity-registry; report findings with ecosystem `unity` as `info`-only and note the limitation).

For each (project, workspace) also `Read` the `package.json` (or `pyproject.toml`, etc.) at that workspace to capture which deps are listed in `dependencies` (runtime-direct) vs. `devDependencies` (dev-direct) vs. `peerDependencies`.

### 3. Query osv.dev

For each unique `(ecosystem, name, version)` triple, POST to `https://api.osv.dev/v1/query` via bash:

```
curl -sS -m 10 -X POST https://api.osv.dev/v1/query \
  -H 'Content-Type: application/json' \
  -d '{"package":{"name":"<name>","ecosystem":"<ecosystem-osv-name>"},"version":"<version>"}'
```

Ecosystem mapping (osv.dev names): `npm` → `npm`, `pypi` → `PyPI`, `crates` → `crates.io`, `go` → `Go`, `nuget` → `NuGet`. Skip `unity-registry` and `unity`.

**Batching:** osv.dev also supports `POST /v1/querybatch` with up to 1000 queries per call. Use it. Single-query loops will exhaust the per-project budget on a 2k-package pnpm-lock.

**Budget:** 4 minutes total per project for HTTP. The actual time is dominated by osv.dev round trips; batching keeps it bounded. On overrun, report partial results and emit a `warning` for the affected project (`vuln scan partial — osv.dev budget exceeded`).

For each finding from osv.dev capture:

- `advisory_id` (prefer GHSA, fall back to CVE, fall back to OSV ID)
- `package` and `ecosystem`
- `installed_version`
- `affected_range` (parse from the advisory's `affected[].ranges`)
- `fixed_version` (lowest `fixed` event in the affected ranges)
- `severity` — read from `database_specific.severity` if present, else parse from `severity[]` array (CVSS v3/v4 → critical/high/moderate/low buckets: ≥9.0 critical, 7.0–8.9 high, 4.0–6.9 moderate, <4.0 low)
- `published_at` (advisory `published` field)
- `direct_or_transitive` (per the manifest read in step 2)
- `paths`: top-level dep chain(s) — first 3 chains is enough (skip in v1 if computing this is expensive; a `(direct)` / `(transitive)` flag is the minimum)

### 4. Optional: try `npm audit` for npm-lockfile projects

This is a defense-in-depth check, not the primary source. If `Read` of `package-lock.json` succeeds AND the workspace has a sibling `node_modules` directory present (use `Glob` to check), you MAY also run `npm audit --json --prefix=<workspace_path>` via bash — but:

- bash can't see `__PROJECTS_ROOT__/`. So this branch effectively never fires; skip it unless someone has wired up a host-side runner.
- If you DO somehow have working `npm audit`, dedupe its findings against osv.dev by `(GHSA, package, version)`.

Do not attempt `pnpm audit` or `bun audit`; the binaries aren't installed.

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-dep-vulnerabilities.md`:

```
# Dependency vulnerabilities — <date>

## Summary
- Projects scanned: <N>
- Projects with findings: <N>
- Total unique advisories: <N>
- Critical: <N>   High: <N>   Moderate: <N>   Low: <N>
- New since last run: <N>      Resolved since last run: <N>
- Scan source: osv.dev REST API (cross-ecosystem)

## Critical & high — by project (action items)

### <project> — <workspace path if monorepo>
| Advisory | Package | Installed | Fixed in | Severity | Direct? |
|---|---|---|---|---|---|
| GHSA-xxxx | name | 1.2.3 | 1.2.4 | critical | direct |

(Repeat per project that has critical/high. Omit projects with none.)

## Moderate & low — rolled up

| Project | Critical | High | Moderate | Low |
|---|---|---|---|---|

(Only show projects with non-zero counts.)

## New advisories this run

| Project | Advisory | Package | Severity | Published |
|---|---|---|---|---|

## Resolved since last run

| Project | Advisory | Package | Resolution (best guess) |
|---|---|---|---|

## No-lockfile / scan-skipped projects

| Project | Reason |
|---|---|

## Cross-cutting observations

(Same advisory hitting multiple projects, ecosystem-wide spike, deprecated package showing up everywhere, etc.)

## Appendix — full finding list

| Project | Workspace | Advisory | Package | Installed | Fixed | Severity | Direct? |
|---|---|---|---|---|---|---|---|
```

## Severity escalation

- **critical**: any unique advisory at severity `critical` OR `high` that is `direct`. These are the "stop the line" findings.
- **warning**: `high` transitive, OR any `moderate` direct, OR a no-lockfile project, OR a partial scan due to budget overrun.
- **info**: everything else, including unreadable-project per-project skips and Unity-lock-missing cases.

## Boundaries

- **Read-only.** No `npm audit fix`, no commits, no installs. The audit reports; the user triages.
- HTTP traffic is limited to `https://api.osv.dev/` and (optionally) `https://registry.npmjs.org/`. Don't fetch unrelated URLs.
- Don't open issues, send emails, or post anywhere.

## Sensible failure modes

- **osv.dev unreachable**: if curl returns network errors for the first 3 batched queries, emit one `warning` (`osv.dev unreachable — vuln scan skipped`) and stop. Don't degrade silently.
- **A specific `Read` call returns an error**: record `unresolved (read-failed: <path>)` for that single file. Continue with the rest. **Never** roll up to a whole-project skip. If you're about to emit "project X unreadable" for all projects, stop — you almost certainly haven't tried `Read`. `gotchas-rollup` and `cross-project-process-audit` Read project files successfully in this runtime.
- **Lockfile parse error**: emit one `warning` per file and continue. Capture the parser's error message in the appendix.
- **Empty lockfile**: rare — emit `info`, treat as no-deps-detected.
- **Budget overrun**: emit `warning` for the project, report partial findings, continue.
- **Bun binary lockfile** (`bun.lockb` only, no `bun.lock`): emit `info` recommending the user commit the text format alongside.
