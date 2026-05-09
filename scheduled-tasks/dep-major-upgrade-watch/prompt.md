# Dependency major-upgrade watch (monthly)

You are tracking the **strategic** picture: how far each active project is from the framework-tier target versions the user has committed to. The sibling `dep-currency` task gives the broad ecosystem view; this task is narrow, curated, and slow-moving — a few framework packages where being a major version behind is a real plan-and-execute project, not a `pnpm up` away.

Examples it should answer at a glance:
- "Which projects are still on Next 15? When did each of them last attempt the upgrade?"
- "React 19.2 is out — which projects are blocked, and on what?"
- "TypeScript 5 → 6 — what's the cross-project plan?"

## Execution model (read this — supersedes any "host required" wording in older runs)

This audit runs in the standard scheduled-task sandbox (Linux aarch64). The sandbox has:

- **File tools** (`Read`, `Glob`, `Grep`) with access to `__SE_CORE_PATH__/` AND `__PROJECTS_ROOT__/<project>/`. Use these for all manifest / lockfile / engine-version reads.
- **Bash sandbox** (`mcp__workspace__bash`) with `curl`, `jq`, `npm` available, plus public-internet network. **Bash does NOT see `__PROJECTS_ROOT__/`.** Use bash only for HTTP calls (registry latest-version checks).

**Proof point: `gotchas-rollup` Reads `<project>/gotchas.md` on every run and successfully collects content from each registered project. `cross-project-process-audit` Reads `<project>/.claude/`, `<project>/.husky/`, `<project>/CLAUDE.md`, and other per-project files and produces detailed per-file findings. The same Read access is available to this audit. Do not assume otherwise.**

### Anti-patterns that broke earlier runs (do NOT repeat)

1. **Do not conclude "path missing" without attempting `Read` first.** Bash returning "No such file or directory" is expected (bash sandbox doesn't mount `personal/`). It does NOT mean the path is missing — it means bash can't see it. `Read` can.
2. **Do not copy-paste failure-mode templates pre-emptively.** If you find yourself emitting "<project>: path missing" without a corresponding failed `Read` call, stop and actually try the `Read`.
3. **Do not infer the runtime from prior audit reports.** A prior audit may say "sandbox-skipped" or "path missing" — that was a bug in the previous audit's logic, not a true runtime constraint. Make your own observations via `Read`, not by reading old audits.
4. **Do not stop at "dep-currency was a no-op" and skip per-project reads.** dep-currency is a CONVENIENCE source. If it has no usable data, fall through to direct lockfile reads — that's the primary path now (see step 2).

Only emit `<project>: path unreadable` if a specific `Read` call returned an actual permission error or "file not found at the expected path." Even then, emit it for that specific (project, file) tuple, not for the whole project.

When sampling worktree state, do NOT invoke `git status` against project worktrees — same `.git/index.lock` hazard. Use direct `Read` of `.git/HEAD`.

## Inputs

1. `Read` `__SE_CORE_PATH__/registry.md`.
2. `Read` `__SE_CORE_PATH__/blacklist.md`.
3. `Read` `__SE_CORE_PATH__/scheduled-tasks/dep-major-upgrade-watch/watchlist.md` — **canonical** list of framework-tier packages, target versions, per-project overrides. Human-maintained. The audit reads but never modifies it.
4. Most recent `dep-currency` audit (use `Glob` over `audits/*-dep-currency.md`) if present and within 14 days — used to corroborate "current version" rather than re-deriving from lockfiles.
5. Prior `dep-major-upgrade-watch` audit if present — for the "movement since last run" delta.

## Connected-folder preflight (do this FIRST, before per-project work)

This audit needs `Read` access to `__PROJECTS_ROOT__/<project>/` for the per-project drift table. Cowork mode bounds `Read` to **connected folders** — directories explicitly attached to the running session. The cron path inherits connected folders from the task's registration context; "Run now" inherits them from the calling Cowork session.

The watchlist-hygiene checks and upstream cross-check (steps 1 and 4 below) do NOT need `personal/` — they only read se-core files and make HTTPS calls. Even if the preflight fails, those checks should still run and produce useful findings. The preflight gates only the per-project drift table.

**Procedure:** Run this immediately after the Inputs section, before any Process step.

1. From the registry/blacklist already read, pick the first project in `registry \ blacklist`.
2. Attempt `Read` of `__PROJECTS_ROOT__/<that-project>/.git/HEAD`.
3. Set a flag for the rest of the run:
   - **Read succeeds** → `personal_unreachable = false`. Run the full audit (steps 2 onward) normally.
   - **Read fails with "outside this session's connected folders"** → `personal_unreachable = true`. Skip step 2 (per-project resolution) and step 3 (drift). Still run step 4 (upstream cross-check). The final report contains:
     - Watchlist hygiene findings (real, useful)
     - Upstream cross-check findings (real, useful)
     - One `info` finding for the connected-folder issue: `personal/ not connected to this session. Per-project drift not computable. Add __PROJECTS_ROOT__/ via the Cowork folder selector and re-run, OR wait for the next cron-scheduled run (the cron path has personal/ in its registration-time folder set — gotchas-rollup runs successfully via cron, evidence the cron mounts work).`
     - Per-project tables marked `not produced — personal/ not connected`.
     - **Do not** emit 6 per-project "path missing" rows.
   - **Read fails with any other error** (e.g., a project genuinely missing `.git/HEAD`): set `personal_unreachable = false` and continue with the full audit; that's a per-project problem handled in step 2.

## Process

### 1. Parse the watchlist

Parse `watchlist.md`. For each tracked package, capture:

- `package` (and ecosystem — npm by default; explicit if other)
- `target_version` (version range the user has committed projects to be on)
- `target_set_at` (date the target was set / last revised — for staleness tracking)
- `migration_notes` (free-form, optional)
- `per_project_overrides`: map of `<project> → <override_target>` for projects with a sanctioned different target.

If `watchlist.md` is missing, emit a **critical** finding (`watchlist.md missing`) and stop.

If `watchlist.md` is present but a tracked-package section is malformed, emit a **warning** for that section and skip it (don't stop the whole audit).

### 2. Resolve "current" per (package, project, workspace)

**Primary source: direct lockfile + manifest reads.** Always do this. The dep-currency artifact is OPTIONAL corroboration, never a substitute. This audit must work standalone — do not depend on dep-currency for correctness.

**2.1 — Probe project root and resolve workspaces.** Use the same explicit-Read + shallow-Glob procedure as `dep-vulnerabilities` step 1:

- `Read` `personal/<project>/package.json` (Node single-package or monorepo root).
- `Read` `personal/<project>/pnpm-workspace.yaml` (pnpm monorepo discriminator).
- `Read` `personal/<project>/pyproject.toml`, `Cargo.toml`, `go.mod` for non-Node ecosystems.
- `Read` `personal/<project>/Packages/manifest.json` and `personal/<project>/ProjectSettings/ProjectVersion.txt` for Unity at root.
- For Unity nested layouts (Lume convention): also probe `personal/<project>/<ProjectNameCapitalized>App/Packages/manifest.json` and `personal/<project>/<ProjectName>/Packages/manifest.json`. Lume's specifically lives at `personal/lume/LumeApp/`.
- For Node monorepos: parse `pnpm-workspace.yaml#packages` or root `package.json#workspaces`. For each pattern like `apps/*`, expand with shallow Glob `personal/<project>/apps/*/package.json`. Post-filter Glob results to drop paths containing `node_modules/`, `.next/`, `.nuxt/`, `.turbo/`, `.codex/`, `.codex-backup-`, `.claude/worktrees/`, `.git/`, `dist/`, `build/`, `out/`, `target/`, `Library/PackageCache/`, `.venv/`, `venv/`, `.svelte-kit/`, `__pycache__/`.

**2.2 — Read the lockfile at each workspace root.** Direct `Read` (not Glob):
- pnpm: `personal/<project>/pnpm-lock.yaml` (single root lockfile for all workspaces).
- bun: `personal/<project>/bun.lock` then `bun.lockb`.
- npm: `personal/<project>/package-lock.json`.
- yarn: `personal/<project>/yarn.lock`.
- python: `personal/<project>/poetry.lock` or `uv.lock`.
- rust: `personal/<project>/Cargo.lock`.
- go: `personal/<project>/go.sum`.
- Unity: `<unity-root>/Packages/packages-lock.json`.

**2.3 — Resolve each tracked watchlist package.** For each (package, project, workspace) tuple:
- Look up the package in the lockfile to get the **resolved version**. Same parsing approach as `dep-vulnerabilities` step 2 (lockfile shapes).
- If not in lockfile but declared in the workspace's `package.json` `dependencies`/`devDependencies`/`peerDependencies`, report the `declared range` and tag `(declared, not in lockfile — install drift)`.
- If not present in the manifest at all, record `not-applicable` (this is fine — it means the package isn't part of this project's surface, e.g., `next` in Lume).

**2.4 — Engine-tier specifics:**
- `node`: `Read` `personal/<project>/package.json` and read `engines.node` (declared). Also `Read` `personal/<project>/.nvmrc` and `personal/<project>/.node-version` (literal pin) if present. If both `engines.node` and `.nvmrc` exist and disagree, report both with a `(mismatch)` flag.
- `unity`: `Read` `<unity-root>/ProjectSettings/ProjectVersion.txt` and parse `m_EditorVersion:` value. `<unity-root>` is the path resolved in 2.1 (may be at `personal/<project>/` OR a nested sub-path like `personal/lume/LumeApp/`).

**2.5 — Optional: corroborate with `dep-currency`.** If a `dep-currency` audit from today exists in `audits/` AND it contains an actual per-project version table (i.e., it ran successfully — not a sandbox-skipped no-op), cross-check your lockfile-derived versions against it. If they disagree, log the disagreement and trust the lockfile (it's the canonical source). If the dep-currency artifact is a no-op stub or missing, just skip this corroboration step — do NOT skip the whole audit.

For monorepos with multiple workspaces declaring different versions of the same package, report each workspace as its own row.

If a specific `Read` call genuinely fails (the runner returns an error, not just empty data), record `unresolved (read-failed: <path>)` for that single (package, project, workspace) tuple — not for the whole project. Then move on. Do NOT halt the project's scan based on one failed Read.

If the package is not present in the project at all (e.g., `next` in Lume — Unity project): record `not-applicable`. Don't flag — it just means the package isn't part of that project's surface.

### 3. Compute drift

For each (package, project, workspace) tuple:

- `effective_target` = override-if-present, else watchlist's `target_version`.
- `gap`: classify by major/minor/patch difference between `current` and `effective_target`. Use semver semantics — a `current` of `15.1.0` against an `effective_target` of `^16` is `behind by major`.
- `direction`: `behind`, `ahead`, `on-target`, `prerelease`.
- `target_freshness`: days since `target_set_at`. Targets older than `STALE_TARGET_DAYS` are flagged.

### 4. Cross-check upstream

For each watchlist entry where ecosystem is one of `npm`, `pypi`, `crates`, `go`:

- `npm`: `curl -sS -m 10 https://registry.npmjs.org/<name>/latest | jq -r '.version'`
- `pypi`: `curl -sS -m 10 https://pypi.org/pypi/<name>/json | jq -r '.info.version'`
- `crates`: `curl -sS -m 10 https://crates.io/api/v1/crates/<name> | jq -r '.crate.max_stable_version'`
- `go`: `curl -sS -m 10 https://proxy.golang.org/<module>/@latest | jq -r '.Version'`

For `engine` ecosystem (`node`, `unity`):

- `node`: `curl -sS -m 10 https://nodejs.org/dist/index.json | jq '[.[] | select(.lts != false)][0].version'` returns the latest LTS. Compare against `target_version`.
- `unity`: no programmatic upstream check; emit one `info` (`upstream check skipped: unity (engine) — no programmatic LTS lookup`).

If `latest_upstream` is **strictly greater** than the watchlist's `target_version` by `>= UPSTREAM_LAG_TOLERANCE_MAJOR + 1` majors, emit a `warning` finding suggesting the watchlist target be reviewed. **The audit does NOT modify `watchlist.md`** — the user reviews and updates manually.

Continue to report project drift against the (possibly stale) watchlist target — but flag both.

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-dep-major-upgrade-watch.md`:

```
# Major upgrade watch — <date>

## Summary
- Tracked packages: <N>
- Projects in scope: <N>
- On target: <N>          Behind by major: <N>      Behind by minor: <N>
- Watchlist targets behind upstream: <N>
- Watchlist targets >`STALE_TARGET_DAYS` days old: <N>
- Source for current versions: <"today's dep-currency" | "lockfile reads" | "manifest declared" — note dominant source>

## Per-package picture

### next  (target: ^16, set 2026-05-01)

| Project | Workspace | Current | Effective target | Gap | Direction | Notes |
|---|---|---|---|---|---|---|
| tgsc | (root) | 16.2.4 | ^16 | 0 | on-target | — |
| akaushik.org | (root) | 16.2.0 | ^16 | 0 | on-target | — |
| neev | apps/web | 15.1.0 | ^16 | major | behind | upgrade plan TBD |
| vericite | apps/admin | 15.0.0 | ^16 | major | behind | upgrade plan TBD |
| lume | — | not-applicable | — | — | — | Unity project |

(Repeat per tracked package.)

## Strategic state — projects behind on multiple framework targets

| Project | Major-behind on | Count | Estimated upgrade order |
|---|---|---|---|
| neev | next, react | 2 | next first (React 19 is the gate Next 16 already ships with) |

(Surfaces highest-leverage upgrade candidates.)

## Watchlist hygiene

### Watchlist targets behind upstream

| Package | Watchlist target | Upstream latest | Lag | Recommendation |
|---|---|---|---|---|

### Stale watchlist targets (>`STALE_TARGET_DAYS` days)

| Package | Target set at | Days old | Recommendation |
|---|---|---|---|

### Unresolved (couldn't determine project version)

| Project | Workspace | Package | Reason |
|---|---|---|---|

## Movement since last run

| Project | Package | Previous current | Now | Status change |
|---|---|---|---|---|

(E.g., "tgsc · next: 16.1.0 → 16.2.4 (still on-target)" or "neev · next: 15.0.3 → 15.1.0 (still major-behind, intra-major progress).)

## Cross-cutting observations

(Strategic — e.g., "All projects on Next 16 are also on React 19; the React 19 upgrade was a gating step. Projects on Next 15 can't do React 19 without the framework move first.")

## Recommended actions

1. <prioritized list — usually 3–5 items>
```

## Severity

- **critical**: a project is `behind by major` on a watchlist package whose `target_set_at` is older than `LONG_STALE_DRIFT_DAYS` AND the project hasn't moved on it since the last run.
- **warning**: any `behind-by-major` runtime-direct, OR a watchlist target that has fallen behind upstream by `> UPSTREAM_LAG_TOLERANCE_MAJOR` majors.
- **info**: behind-by-minor, on-target updates, ahead-of-target, unresolved versions, watchlist-staleness reminders, not-applicable rows, upstream-check-skipped (Unity).

## Boundaries

- **Read-only.** Do not modify `watchlist.md`. Do not modify any project lockfile or manifest. The audit reports; the user decides which majors to lift.
- Do not auto-resolve overrides — if the watchlist says "vericite stays on next 15", trust it.
- Do not perform reachability or compatibility analysis. "Can Neev upgrade to Next 16?" is out of scope; this task answers "where are they relative to the target."
- HTTP traffic only to public registries (npm, pypi, crates.io, proxy.golang.org, nodejs.org).

## Sensible failure modes

- **Watchlist missing**: critical finding, stop.
- **Watchlist section malformed**: warning, skip that package, continue.
- **dep-currency audit missing or a no-op stub**: that's fine — direct lockfile reads (2.2) are the primary source. Don't skip the audit.
- **Registry latest fetch fails**: skip step 4 for that package with one `info`. Continue with watchlist-as-truth.
- **A specific `Read` call returns an error (file not at the expected path, permission denied)**: record `unresolved (read-failed: <path>)` for that single (package, project, workspace) tuple. Continue with the rest. **Never** roll this up to "project path missing" without per-file evidence.
- **First run**: no prior `dep-major-upgrade-watch` audit → "Movement since last run" empty; note in summary.

**Anti-pattern: do NOT** emit "project X has no path" without showing which specific `Read` calls failed. If you find yourself about to emit "path missing" for ALL projects, stop — you almost certainly haven't tried `Read`. Other concurrent audits (`gotchas-rollup`, `cross-project-process-audit`) routinely Read project files in this same runtime and succeed.
