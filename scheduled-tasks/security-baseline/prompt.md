# Security baseline (quarterly, host-only)

You are running the quarterly **project-wide security baseline** across every active project. Mode 1 of the `security-gate` skill — see `__TRELLIS_PATH__/core-rules/skills/security-gate/SKILL.md` for the canonical contract and `__TRELLIS_PATH__/security-gate-plan.md` for threat model and rationale.

This task replaces the **ground truth** that per-push diff scans (Mode 2) deduplicate against. Without a fresh baseline, latent vulnerabilities sit forever — diff scans only see what current PRs touch.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Skill scripts: `__TRELLIS_PATH__/core-rules/skills/security-gate/scripts/`
- Personal projects root: `__PROJECTS_ROOT__/`
- Fleet audit output: `__TRELLIS_PATH__/audits/`

These are the only authoritative paths. Do not "reconcile" to alternates that may appear in older snapshots.

## Environment guard (do this FIRST)

Before running any scanner, verify the host:

1. `[ "$(uname)" = "Darwin" ]` must succeed. If not — you are in the linux-arm64 sandbox, not on the macOS host. Write the rollup with a single info finding (`security-baseline requires host execution; sandbox run skipped`) at the canonical output path and stop. Do **not** attempt scans.
2. `command -v semgrep && command -v osv-scanner && command -v gitleaks` must all succeed. If any is missing, emit one info finding per missing tool and continue with the engines that are present (the scanner libraries warn-and-skip gracefully — see `core-rules/skills/security-gate/scripts/lib/*.sh`).
3. `[ -f __TRELLIS_PATH__/core-rules/CLAUDE.md ]` and `[ -d __PROJECTS_ROOT__ ]` — if either fails, the host is not configured correctly. Stop with one info finding describing the mismatch.

## Inputs

1. `Read` `__TRELLIS_PATH__/registry.md` — active project list.
2. `Read` `__TRELLIS_PATH__/blacklist.md` — opt-out list.
3. `Read` `__TRELLIS_PATH__/scheduled-tasks/security-baseline/targets.md` — per-project overrides + skip list.
4. Glob `__TRELLIS_PATH__/audits/*-security-baseline-rollup.md`, sorted lexically; the **most recent** is the previous run, used for the new-vs-recurring-vs-resolved delta.

Target set = `(registry ∖ blacklist) ∖ targets-skip-list`.

If a registered project's directory is missing on disk, record one info finding for it and continue with the rest.

## Per-project procedure

For each target project `<P>`:

### 1. Resolve config

- Read `<P>/.claude/skills/security-gate-local/local.config.sh` if present — it sets `SECURITY_GATE_STACK_PROFILE`, `LLM_PROVIDER`, `LLM_MODEL`. Fleet overrides from `targets.md` apply only when project-local config is absent.
- If neither names a profile, default by registry class:
  - `single Next.js app`, `app`, `monorepo SaaS` → `web-next`
  - `portfolio site` → `web-static`
  - `game (Unity, …)` → `unity-game`
  - LLM/RAG-shaped (e.g. vericite) → `web-rag-llm`

### 2. Run the baseline

```
bash __TRELLIS_PATH__/core-rules/skills/security-gate/scripts/run-baseline.sh <P> [--profile=<name>] [--no-llm]
```

- Pass `--no-llm` if no `LLM_PROVIDER` is configured for the project (host or project-local). The OSS engine produces real findings without LLM triage; the rollup must note FP rate is unmeasured for those projects.
- Wall-clock per project: 10–60 minutes. Run sequentially — parallel execution can blow Semgrep's memory ceiling on the host.
- Capture exit code per project. The script always returns 0 on a successful run regardless of finding severity (baselines establish state, not block).

### 3. Compare against prior baseline

The script wrote `<P>/audits/<YYYY-MM-DD>-baseline-<P>.json`. The previous baseline (if any) is the next-most-recent file matching `<P>/audits/*-baseline-<P>.json`.

Read both. For each current-tree finding in `findings`, use identity `(tool, rule, file, line)` and exclude baseline `dropped` entries:

- **new** — present this run, absent in prior.
- **recurring** — present in both.
- **resolved** — absent this run, present in prior.

Severity is read from the new baseline (or, when only present in prior, from the prior).

Compare `historical_findings` separately by exact `fingerprint`. Report new, recurring, and resolved history-only credentials with their persisted disposition; do not merge them into the current-tree counts or Critical/High gate totals. Their severity remains the scanner's real severity.

### 4. Per-project artifact

Already on disk (`<P>/audits/<date>-baseline-<P>.{md,json}`). Do not duplicate — link from the rollup.

## Fleet rollup

Write `__TRELLIS_PATH__/audits/<YYYY-MM-DD>-security-baseline-rollup.md`:

```markdown
# Security baseline rollup — <YYYY-MM-DD>

## Header

- Quarter: <Q>
- Projects scanned: <count> / <registry size> (<list of skipped + reason>)
- Wall-clock total: <minutes>
- Tool versions: semgrep <v>, osv-scanner <v>, gitleaks <v>, llm <v|absent>

## Quarter-over-quarter delta

| Project | New | Recurring | Resolved | Critical/High kept | Notes |
|---|---|---|---|---|---|
| <P> | … | … | … | … | <link to per-project audit> |

## Newly introduced this quarter

For each new finding (top-down by severity):

- **<severity>** `<tool>/<rule>` @ `<file>:<line>` — <short message>
- Triage: <kept|no-llm-pass> — <reason>
- Suggested fix: <one line>
- Project: <P>
- Audit: `<P>/audits/<date>-baseline-<P>.md`

## Recurring high-priority

Findings recurring at Critical or High severity. These are unfixed since last quarter — call out by name.

- <same shape>

## Resolved this quarter

- **<severity>** `<tool>/<rule>` @ `<file>:<line>` — closed (was: <project>)

## Auto-spawn fix branches

For every **new** Critical/High finding, leave a one-line note:
- `<P>:<finding-id>` — would auto-spawn `claude/security-fix-<P>-<finding-id>` (manual creation deferred until interactive remediation flow lands per plan §6).

(Auto-spawn is plan §4 future work; the rollup records intent only.)

## Methodology notes

- Baseline JSON shape: `security-gate.baseline.v2` (`core-rules/skills/security-gate/SKILL.md`): current-tree `findings` drive gate/delta counts; `historical_findings` is a separate fingerprint-keyed visibility stream.
- Diff scans (Mode 2) deduplicate against the **newest** baseline JSON per project. This run's baselines become the ground truth until next quarter.
- FP rate per project: <list, when LLM triage was used>. When `--no-llm`, FP rate is unmeasured.
```

## Anti-patterns (do NOT repeat)

1. **Do not run scanners in parallel.** Semgrep alone uses several GB on a Next.js codebase; six concurrent runs will swap and stall.
2. **Do not edit project source files.** Even auto-fix suggestions land as findings, not patches. Remediation is a separate flow (plan §4 Mode 1 outputs — fix branches per-finding, deferred per Phase 1 spec).
3. **Do not skip the previous-baseline read.** "All findings are new" is the wrong default when `*-baseline-<P>.json` already exists for that project.
4. **Do not silently lower severity.** If the LLM triage was used and emitted a `severity_override`, surface it explicitly in the rollup with the override reason; don't quietly merge it.
5. **Do not call this scan complete with zero scanners.** If the host check passes but every engine warned-and-skipped, that's a host configuration regression; emit a critical info finding so the next on-call sees it.

## Receipts (definition of done for this run)

- One per-project audit written under `<P>/audits/` for every non-skipped target.
- One fleet rollup written under `__TRELLIS_PATH__/audits/`.
- Tool versions captured in the rollup header (reproducibility — re-running this rollup must be possible from the recorded versions alone).
- Quarter-over-quarter delta populated, even when the answer is "no change".
- For at least one new Critical/High finding (if any): full reproduction step from the per-project audit's `exploit_steps` field surfaced in the rollup.

## Loop safety

This task is a Trellis loop and honors `core-rules/loop-safety.md`. Ceilings resolve most-specific-wins: this stanza's per-loop override → project-local `.trellis.config.json.loop_safety` → central `trellis.config.json.loop_safety` → built-in fallback constants (100 / 3 / $1000). The loop **halts on any one** ceiling and emits a structured halt report (which ceiling tripped, last progress marker, work done so far); as a cron loop it surfaces the halt in its run report rather than dying silently.

- **`max_iterations`**: inherit default (100).
- **`no_progress_iterations`**: inherit default (3).
- **`budget_ceiling_usd`**: inherit default (1000).
- **Progress signal**: **work-list drain** — this is a sequential per-registry sweep, so an iteration makes progress when it scans a target project and drains it from the remaining set (`(registry ∖ blacklist) ∖ targets-skip-list`). No drain across `no_progress_iterations` consecutive iterations halts the loop.
