# Reference — Tests & coverage

Authoritative source: `engineering-process.md` §7 (Definition of done) and §8.6 (Testing bar).

## What the gate checks

The gate enforces presence and pass-status of the project-declared test commands. Coverage thresholds, framework choice, and integration scope are project-local.

## Required commands

Declared in `<project>/.claude/skills/process-gate-local/local.config.sh` or, for Codex, `<project>/.agents/skills/process-gate-local/local.config.sh`:

```bash
PROCESS_GATE_TYPECHECK_CMD="pnpm typecheck"
PROCESS_GATE_LINT_CMD="pnpm lint"
PROCESS_GATE_TEST_CMD="pnpm test"
```

The file is read from the base of the gated range and parsed as data (see SKILL.md, "Gate config is read from the range base, as data"): changing a command in a PR takes effect only after it merges.

When the full test battery already runs the exact typecheck and lint commands,
base-side config may declare `PROCESS_GATE_TEST_COVERS_STATIC` as a three-item
array: the covering test command, typecheck command, and lint command. Only an
exact match of all three effective commands deduplicates the standalone checks;
the row reports `typecheck and lint: included in full test battery`. Docs-only
ranges always retain them, even if the policy names that same battery command.
Other narrowed test commands and changed static commands retain them too. An
inherited declaration is ignored: this is a reviewed config assertion about the
battery's contents, not an environment bypass. Trellis's own declaration matches
`run-tests.sh`'s `shellcheck_tree` and `aeo_static_and_python` stages.

Web stacks default to `pnpm` if `pnpm-lock.yaml` is present, `bun` if `bun.lockb`, `npm` if `package-lock.json`. The gate auto-detects but local.config.sh wins.

Python projects auto-detect in this order: `uv.lock` → `uv run`, `pdm.lock` → `pdm run`, otherwise `pyproject.toml` alone → `python -m` (from the project's active venv). Default commands once a runner is selected:

- **typecheck:** `<runner> mypy .` when `[tool.mypy]` exists in `pyproject.toml` or a `mypy.ini` is present. Pyright remains available via an explicit `PROCESS_GATE_TYPECHECK_CMD` override; the gate does not auto-pick Pyright.
- **lint:** `<runner> ruff check .` when `[tool.ruff]` exists in `pyproject.toml` or a `ruff.toml` is present.
- **tests:** `<runner> pytest` when `[tool.pytest.ini_options]` exists in `pyproject.toml` or `pytest.ini`/`conftest.py` is present.

For other non-Node, non-Python stacks the commands are project-supplied: `cargo check && cargo clippy && cargo test`, `go vet && go test ./...`, etc.

## Posture

| Result | Posture |
|---|---|
| All three commands pass | **pass** |
| Typecheck or lint fails | **fail** — non-negotiable; same gate that `stop-verify` enforces in-session |
| Tests fail | **fail** |
| Tests timeout (default 25 min: up to 15 min database-lock wait plus 10 min battery; override via `PROCESS_GATE_TEST_TIMEOUT`) | **fail** |
| Typecheck command not declared AND not auto-detectable | **fail** — typecheck is non-negotiable per `engineering-process.md` §7 (Definition of done); a project that cannot typecheck cannot meet the bar |
| Lint or test command not declared AND not auto-detectable | **warn** — declare them in `local.config.sh` |

## Failed-check output

A failed or timed-out typecheck, lint, or test command keeps its complete output under
`<TRELLIS_GATE_STATE_DIR>/failed-shards/process-gate-failure.*/output.txt`; the default state root is
`~/.local/state/trellis-gate`. The directory is mode `0700`, the output is mode `0600`, and each
file is capped at 5 MiB. The gate prints the path, includes up to 20 buried TAP `not ok` lines in
the finding, and keeps the last 10 lines for context. On a new failure, entries older than seven
days are pruned and at most eight process-gate failure directories are retained. This storage is
separate from the local gate's own token-named shard artifacts in the same `failed-shards` parent.

## Coverage

Project-local. The gate does not enforce a coverage percentage. Projects that want one declare:

```bash
PROCESS_GATE_COVERAGE_CMD="pnpm test:coverage"
PROCESS_GATE_COVERAGE_FLOOR=70  # warn below this
```

Falling below floor: **warn** (don't block, but visible in verdict).

## What the gate does NOT enforce

- **Test framework choice.** Vitest, Jest, Pytest, Cargo test, Go test — project's call.
- **Test naming conventions.** Project-local.
- **Integration / E2E scope.** Run in CI, not at gate time. The gate only covers fast unit + typecheck + lint per `engineering-process.md` §8.6.
- **Mutation testing.** Project's call.

## Stack-specific extensions

Web projects often add accessibility tests (axe-core, pa11y) and visual regression tests. These run via stack-profile validators, not the canonical `check-tests.sh`. See `references/stack-profiles.md`.

## When tests should run

The gate runs tests on the *full project*, not just the diff (exceptions are a project-owned push dispatcher using the interface below, and an opted-in docs-only range). Reasoning: a change in module A can break tests in module B that the diff doesn't touch. Covered by the canonical `stop-verify` hook in-session and the `pre-push` hook at git boundary; the gate is a third confirmation at PR time.

For very large monorepos where full-project test runs exceed the 5-min budget:

```bash
# A project-owned dispatcher consumes the gate's push scope below.
PROCESS_GATE_TEST_CMD="python3 .claude/skills/process-gate-local/tests.py"
PROCESS_GATE_TEST_TIMEOUT=600
```

The trade-off (faster gate but theoretically incomplete coverage) must be acknowledged in the project's `CLAUDE.md`.

## Exact-input local battery verdicts

The canonical `python3 [-I] scripts/run-tests-local.py` command always runs
uncached. Only `check-tests.sh` can replace that command with a runner-written
passing verdict; typecheck, lint, coverage and every other gate row still run
(or static checks are covered by the exact base-declared full-battery tuple).
`--verdict-status [--head=COMMIT]` is a read-only probe: a miss exits 1.

Verdicts live in `${TRELLIS_GATE_STATE_DIR:-$HOME/.local/state/trellis-gate}/verdicts/`
(mode 0700, records 0600). The default is pinned regardless of `XDG_STATE_HOME`,
so cron and interactive agents share the queue and disable marker. An explicit
state override must be absolute, outside every checkout, and shared by all
callers; invalid roots refuse before creating state. Queue metadata uses
`queue.lock`; admitted runners retain the legacy `lock` flock until close, so
pre-072 runners cannot overlap them. Inputs over-include the clean tree, test inventory and
suite blobs, runner/fence/helper blobs, tool paths/binaries/versions, platform,
Git refs/config and a digest of the effective environment. Only queue/output and
heavy-slot transport variables are excluded. The heavy exclusions are exactly
`FD`, `TOKEN`, `SLOT`, `POOL` and `DIR_ID` under `TRELLIS_HEAVY_`; other heavy
configuration is bound, and `TRELLIS_HEAVY_TEST*` refuses reuse. Checkout HEAD
must be the gated head. Ignored files matching any non-recursive suite-discovery
glob also refuse reuse, including files under ignored parent directories.
A failed version probe refuses reuse. `mktemp`, `lsof`, `ps` and the npm/npx
entrypoints bind resolved executable bytes without invoking a version command;
normal npm/npx installations additionally bind the resolved package metadata,
so an npm-only upgrade changes the key even if its entrypoint is unchanged.
Other discovered tools require a successful version probe. Dirty, narrowed, test-seam, partial, failed, timed-out, interrupted or
containment-ambiguous runs never qualify. An explicit rerun invalidates an older
pass for the same inputs before starting. Changing inputs during a run also
prevents a write. The retained aggregate and its digest must still validate.
Wrong modes, symlinked records, missing evidence and verdicts older than seven
days are misses, never passes. The weekly uncached backstop compares tree-matched
candidates even when scheduler environment/toolchain inputs differ, records the
differing field names, and raises P1 on a failing unchanged tree.
A `reuse-disabled.json` marker in the state directory disables reads and writes
until an operator reviews the divergence and removes it.

Residual inputs: unrelated ignored dependency/cache contents, Python installed
package contents, npm/npx imported contents beyond entrypoints/package metadata
(and package metadata hidden by nonstandard wrappers),
and external Git exclude/config file bytes are not individually hashed. Fresh
Git discovery still checks ignored suites on every lookup. The seven-day cap
and conservative weekly tree-divergence backstop limit, but do not eliminate,
those residuals; retain uncached release qualification.

Passing timing evidence is retained separately under `passing-runs/<id>/` with
head, tree and aggregate digest. `python3 -I scripts/refresh-stage-weights.py`
updates the reviewed weights from the last five passing runs plus the pinned
baseline; unmeasured stages explicitly keep their estimates. Failed shard
outputs older than seven days are pruned on admission and `--runs-reap`.

## Verified release-tag reuse (1.4.0)

A single tag-only push may reuse a full release-tree verdict only after
`release-payload-commit.sh --verify-tag` passes. Both pre-push carriers pass the
observed tag ref and object ID as arguments; Tests independently verifies them
again. Mixed/multiple tags, failed verification and unclassified tag pushes run
full tests, not the ordinary docs-only or exact-HEAD shortcuts.

The checkout must be clean and byte-identical to the approved release-commit
tree (the payload's sole parent). T30 must validate exactly one retained passing
verdict with the same tree, runner/fence, inventory, toolchain, environment,
platform and Git configuration. The only permitted ref difference is addition
of this verified tag; other ref changes or an occupied/disabled/stale/tampered
verdict miss. No new reusable full verdict is written by the tag-reading rerun.

T32's `scripts/tests/release-metadata-audit.json` is read from the approved
release tree. It must be complete, source-digest matched and internally
consistent. Every observed `tag_reads: true` suite runs under the normal Tests
command timeout, and a failure blocks. Static checks, coverage and other gate
rows retain their normal behavior. The verdict prints the reused run ID/tree
and explicitly notes the tag-reading rerun. Its scope is `full` (reused full
release-tree evidence plus the tag checks), never a selector narrowing. A
missing, unreadable, incomplete,
stale or ambiguous trace leaves the full command unchanged. The checked-in
targeted trace remains incomplete until the release owner certifies full
coverage; installing this code alone never promotes that evidence.

## Push scope and command receipts

Only push Tests receives gate-owned `PG_TESTS_BASE` and `PG_TESTS_HEAD`, full commit SHAs for the exact resolved range (not hard-coded trunk or necessarily checkout HEAD); `A...B` uses merge-base(A, B).
`run-all.sh` snapshots them before rows; `check-tests.sh` resolves argv. Both unset inherited interface values. Only Tests receives them, even through the heavy clean-env boundary; Claude and Codex share the scripts.

Merge, release, unknown and missing modes provide no interface and run the existing command unchanged. Standalone `check-tests.sh --mode=push` also needs explicit `--range` or `--base`.
**Absent/unresolved scope or any unclassifiable path must select the full suite.** A project dispatcher owns its conservative classification and coverage map; the gate does not certify those choices.

In scoped push mode, `PG_TESTS_RECEIPT_FILE` names a private temporary file; the command may write exactly one newline-terminated line (at most 128 bytes):

```text
PG_TESTS_RECEIPT full
PG_TESTS_RECEIPT narrowed 7
PG_TESTS_RECEIPT no-tests docs-only
```

`narrowed N` requires a positive selected-test count; `no-tests docs-only` reports zero. The row and final verdict show `full`, `narrowed: N selected`, or `no-tests: docs-only`.
An executed command without a receipt defaults to `full`, not an independently measured count. Undeclared Tests are `not run`; a missing checker `Tests:` line is `unknown`. Stdout is not a receipt channel.
Malformed/multiple receipts fail the row; a valid receipt never overrides command failure or timeout. The gate removes the file after reading it. Existing base-policy docs-only behavior below is unchanged.

## Base-side test-file selector (opt-in)

`PROCESS_GATE_TEST_MAP="scripts/lib/push-test-map.py"` opts into a base-owned
Python selector for explicit branch-only pushes (`PG_PUSH_TEST_SCOPE=branch`,
set by pre-push; tags and mixed pushes force `full`). The gate executes the
regular BASE blob with isolated Python, appends its selected `--test-file=`
arguments to the existing Tests command, and falls back to that unmodified
command when the map cannot decide, HEAD differs from the pushed range head,
or the tracked tree/index is dirty. Merge/manual gates never use the selector
and keep their previous passive-docs exemption (also for break-glass main pushes
without tags). The gate consumes and unsets `PG_PUSH_TEST_SCOPE` before check
commands run; both runners also scrub it from descendants.
The base is the pushed range's base. For a branch's later pushes that is its own
previous push, so a branch can select with a map it changed itself, the same
trust the base-side `PROCESS_GATE_TEST_CMD` already carries. Narrowing is a
push-time speedup only: merge acceptance never uses the selector.
A successful selected command must write `PG_TESTS_RECEIPT narrowed M` for exactly M
selected files; missing, full or mismatched receipts fail as `unknown`, never
claiming a full-battery pass. A failing selected run reports its actual failure
with scope `unknown`, without demanding a success receipt. Trellis's contained
runner deduplicates selected files, keeps static/core stages and recipe lint,
and alone writes the receipt
after successful execution and verified containment cleanup. Planner and shard
children do not receive the gate receipt interface.

The Trellis mapper over-includes transitive `source`/Bats `load` dependencies,
`shellcheck source=` hints, and literal helper/fixture references from both
endpoint trees. A removed dependency edge therefore still selects its old
consumer. Changes to `scripts/lib/` always require the full battery; unknown
paths, missing required suites, and dependencies reaching core hook/skill
suites also fall back to full. Selections travel only as command arguments,
never as an environment-carried file list.

## Docs-only ranges (opt-in)

A range that changes only passive records can skip the test battery. The rule is narrow, and doubt runs the full battery.

The project opts in with a policy file at `.claude/skills/process-gate-local/docs-only-tests.policy` or `.agents/skills/process-gate-local/docs-only-tests.policy`. If both exist, they must be identical. The gate reads the policy from Git objects at the range's base, never from the range or the checkout. A policy edit carried in a PR therefore takes effect only after it merges, and the edit itself runs the full battery because it changes a dot-directory path.

The format is one directive per line. Comments are whole lines starting with `#`; the rest of a directive line is its value.

```
# allow: an anchored, case-sensitive ERE. deny: an ERE that beats every allow.
# tests: an optional command, at most once, run in place of the battery.
allow ^docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md$
deny ^docs/adr/0009-pinned\.md$
tests bats scripts/tests/docs-consumers.bats
```

`allow` patterns must be anchored with `^…$`. An unknown keyword, an empty or invalid pattern, or a second `tests` line makes the policy malformed.

**Eligibility.** The range narrows only when every path touched by every commit in it qualifies. That covers both sides of a rename, deleted paths, and changes made and then reverted inside the range. A path qualifies only if it meets all of these:

- It matches an `allow` entry and no `deny` entry.
- It clears the built-in floor, which no policy can widen:
  - ordinary path components only: no dot-directories, spaces, control characters or leading dashes;
  - a `.md` suffix;
  - no behaviour-bearing namespace (`core-rules/`, `scripts/`, `hooks/`, `skills/`, `commands/`, `agents/`, `prompts/`, `templates/`, test, fixture and baseline directories, secret directories);
  - no operative file name (`SKILL.md`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `prompt.md`, `targets.md` and similar), and no `VERSION`, `UPGRADING` or secret-like name. These name checks are case-insensitive.
- Its blob is a plain `100644` file: not a symlink, gitlink or executable, with no NUL byte, and not an LFS pointer.

**Full battery, with a `process-gate: notice (docs-only: full tests — <reason>)` on stderr, when:**

- the policy is unreadable or malformed;
- the range start is not an ancestor of its end;
- the range has no commits or no changed paths;
- the range contains a merge commit;
- any path fails eligibility.

With no policy at the base, or a range the shared diff-base resolver (`core-rules/skills/process-gate/scripts/lib/diff-base.sh`) cannot resolve, the battery runs silently, as it always has.

**When the range narrows:**

- Typecheck and lint still run.
- The battery is replaced by the policy's `tests` command, or skipped if the policy has none. That command takes no heavy slot.
- Coverage and the mutation spot-check are skipped.
- A scoped push with no policy tests command prints `Tests: no-tests: docs-only`. A policy command's canonical scope receipt is retained when present; other docs-only runs keep `Tests: narrowed (docs-only: N files)`, where N counts net changed paths. `run-all.sh` repeats the scope under the verdict. A narrowed pass is never a full-battery pass.
- The other rows are unaffected. Secrets, Bypass markers, Docs discipline and Security run in full on every range.

The narrowing presumes that the protected base passed its own full gate. It does not reuse or verify a prior test receipt.

**Trellis's own policy** is `.claude/skills/process-gate-local/docs-only-tests.policy`. It allows `docs/`, spec and top-level Markdown, and it denies the runbooks, the process doctrine, steering, prompt and setup text. Its `tests` line runs only the checks that read repository Markdown: `scripts/tests/gpt6-roster-sweep.bats`, the A3.8 repository scan in `scripts/tests/release-tag-consumers.bats`, the tracked-source scan in `scripts/tests/check-process-liveness.bats`, and `scripts/conformance-check.sh`.

## Release-metadata class (base-side opt-in)

A docs-only policy can additionally declare:

```
class release-metadata scripts/tests/release-metadata-audit.json
```

This class allows only regular passive `VERSION` / `core-rules/VERSION` (one
semver line), `CHANGELOG.md`, and `docs/adr/*.md` changes, checking every commit,
including subsequently reverted changes. Bash refuses ranges containing merges
and enforces the exact path floor before invoking Python; other paths fall back
to the ordinary docs/full class, even if the frozen helper is permissive.
The helper and its local imports are extracted from the base into a private,
short-lived directory, never executed from the candidate. Base policy denies
still apply. A clean candidate, an intact full-green base verdict, unchanged tools/environment,
runner/inventory/suites/config, and unchanged refs except the current branch's
base-to-candidate advance are mandatory. Only the audited suites replace the
battery; local static checks still run. The verdict carries
`Tests: narrowed (release-metadata: N files)`. No narrowed run writes a full verdict.

The audit is read from the base, must be regular, `complete: true`, and bind all
non-metadata source blobs through `source_digest`. Incomplete, stale, missing,
malformed or unqualified evidence runs the full battery. Ordinary docs keep
using their existing class. The shipped audit is **targeted, not complete**;
the directive is deliberately not enabled in Trellis's policy until the release
owner finishes the full-battery trace. Do not promote the targeted sample.

Capture real read opens with Linux `strace -f -yy -s 4096 -e trace=%file`, one
log per targeted suite under `trellis heavy --light --lane <lane>` and sandbox
HOME/TRELLIS_HOME/TMPDIR. macOS native file-open tracing needs operator-granted
DTrace/root privileges; a sandboxed local Linux VM is an alternative. Summarize
with `python3 -I scripts/trace-release-metadata.py --trace <suite>=<log> ...`.
Targeted summaries record hashes of the retained raw traces and always emit
`complete: false`. For the full CI Bats inventory, use
`bash scripts/trace-full-battery.sh <new-evidence-directory> --workers N` on Linux.
Collection still writes `complete: false`; the separate
`python3 -I scripts/trace-release-metadata.py --promote-run <directory>` step
requires every inventory log, zero exits, successful parsing and matching HEAD
source digests before writing `complete: true`. See
[`docs/FULL-BATTERY-TRACE.md`](../../../../docs/FULL-BATTERY-TRACE.md) for the
sandbox, evidence and promotion workflow. File probes and Git object-store reads
are included conservatively. Full tracing and owner review, not this sample,
determine the final suite set and the ≤10-minute metadata timing receipt.

## Machine-wide heavy slots

The test battery runs through `trellis heavy` (spec 054), so parallel lanes on one host take
turns instead of starving each other. `check-tests.sh` runs `trellis heavy --check` once, before
any check. On exit 0 the battery waits for a slot, and `PROCESS_GATE_TEST_TIMEOUT` starts only once
the slot is held. On any other exit, or with no launcher, the battery runs on the old bounded
path and the gate prints `process-gate: notice (heavy-gate-unavailable: <reason>)` to stderr.
The path is chosen before the battery runs, so a failing battery is never re-run.
`PROCESS_GATE_HEAVY_LAUNCHER` names the launcher (default: `trellis` on `PATH`). Typecheck, lint,
coverage and the mutation spot-check are not gated. The battery always uses the heavy pool, never
`--light`.

## CI vs gate

The gate runs locally or in a pre-merge agent context. CI runs on the merge commit. Both must be green:

- **Gate green, CI red:** environmental difference. Investigate (env vars, OS, Node version pin).
- **Gate red, CI green:** unlikely — usually means the gate was skipped or the project's `local.config.sh` doesn't match CI commands. Reconcile.

The gate should mirror CI's fast-suite as closely as possible. Slow integration suites stay in CI only.
