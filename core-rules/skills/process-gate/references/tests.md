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

Web stacks default to `pnpm` if `pnpm-lock.yaml` is present, `bun` if `bun.lock` or `bun.lockb`, `npm` if `package-lock.json`. The gate auto-detects `scripts.typecheck`, `scripts.lint`, and `scripts.test` first, while `local.config.sh` wins. When `package.json` omits `scripts.typecheck` or `scripts.lint` and `node_modules` is installed locally, `check-tests.sh` falls back to fast local `node_modules/.bin` binaries (`P45`):

- **typecheck** (requires `tsconfig.json`): `tsrs --noEmit` → `tsgo --noEmit` → `tsc --noEmit`.
- **lint**: `oxlint` (when `.oxlintrc.json`, `oxlint.config.*`, or `package.json` `oxlint` is present) → `biome check .` (`biome.json` / `biome.jsonc`) → `eslint . --quiet` (`.eslintrc*` / `eslint.config.*`). Missing or uninstalled tools downgrade to `warn` rather than false-blocking.

When `typecheck`, `lint`, and `tests` are independent (and `PROCESS_GATE_TEST_COVERS_STATIC` has not folded static checks into the full battery), `check-tests.sh` executes them concurrently bounded by local host CPU cores and collects findings in deterministic order (`typecheck` → `lint` → `tests`). Set `PROCESS_GATE_SERIAL_CHECKS=1` to force sequential execution. Static read-only rows in `run-all.sh` likewise execute concurrently before `Tests & coverage`.

For stateless JS/TS unit suites (`P50`), prefer Vitest `isolate: false` (or Node's native `--test` runner on Node 26 with built-in TypeScript stripping) and narrow in-memory fixtures over per-file VM re-initialization and full-project disk clones.

Python projects auto-detect in this order: `uv.lock` → `uv run`, `pdm.lock` → `pdm run`, otherwise `pyproject.toml` alone → `python -m` (from the project's active venv). Default commands once a runner is selected:

- **typecheck:** `<runner> mypy .` when `[tool.mypy]` exists in `pyproject.toml` or a `mypy.ini` is present. Pyright remains available via an explicit `PROCESS_GATE_TYPECHECK_CMD` override; the gate does not auto-pick Pyright.
- **lint:** `<runner> ruff check .` when `[tool.ruff]` exists in `pyproject.toml` or a `ruff.toml` is present.
- **tests:** `<runner> pytest` when `[tool.pytest.ini_options]` exists in `pyproject.toml` or `pytest.ini`/`conftest.py` is present.

For other non-Node, non-Python stacks the commands are project-supplied: `cargo check && cargo clippy && cargo test`, `go vet && go test ./...`, etc.

Automatic detection chooses one test command, not a polyglot dispatcher. When it detects suites in more than one language and omits any, the row warns, names the omitted suites and reports `Tests: partial` if a test command ran (`not run` if none ran). Declare a project-wide `PROCESS_GATE_TEST_CMD` in the base-side `process-gate-local/local.config.sh` to make the project dispatcher authoritative. A declared command is not second-guessed.

## Posture

| Result | Posture |
|---|---|
| All three commands pass | **pass** |
| Typecheck or lint fails | **fail** — non-negotiable; same gate that `stop-verify` enforces in-session |
| Tests fail | **fail** |
| Tests timeout (default 90 min to bound runaway runs while allowing full suites and database-lock waits; override via `PROCESS_GATE_TEST_TIMEOUT`, loaded from BASE so an increase cannot apply to its own push) | **fail** |
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

## Net test-LOC growth ratchet (`P49`)

On non-tag ranges where `base..head` resolves, `check-tests.sh` sums `git diff --numstat` added minus deleted lines across test paths (`*.bats`, `tests/**`, `__tests__/**`, `*test*`, `*spec*`). By default (`PROCESS_GATE_TEST_NET_BUDGET=400`, `PROCESS_GATE_TEST_NET_BUDGET_MODE=warn`), ranges adding more than `+400` net test lines emit a warning nudging table-driven consolidation (or `/test-cleanup`). Set `PROCESS_GATE_TEST_NET_BUDGET_MODE=block` in `local.config.sh` to enforce as a hard failure, or `off` to disable.

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

## Verdict reuse

A passing Tests verdict is reused by default when nothing changed. The key is
the committed tree, the test command, the runner, the toolchain, the platform
and the keyed environment (below). Refs, Git config, the checkout path and
other session environment are not keyed, so a pass transfers between
worktrees, fresh clones and agent sessions on one host. Typecheck, lint, coverage and every other gate row still
run (or static checks are covered by the exact base-declared full-battery
tuple). Reuse applies to explicit push and merge runs; a narrowed or docs-only
range, a tag push (other than the verified release-tag path), a dirty checkout,
a different gated HEAD, a different command, a different toolchain or a
verdict older than seven days misses and runs the command.

The invariant: a reused verdict equals what rerunning the identical command,
in the same keyed tree and environment, would give now. Reuse does not judge
whether the configured command is the project's full suite; a narrow committed
command runs narrow with or without reuse. A reused row therefore prints
`Tests: reused: configured command`, never `Tests: full` (run-all and
accept-branch accept that scope).

Two writers share the key:

- The canonical `python3 [-I] scripts/run-tests-local.py` command writes its
  own full-battery verdicts under `verdicts/`; `--verdict-status
  [--head=COMMIT]` is a read-only probe (a miss exits 1). Its runner is the
  runner, fence and helper blobs. Its key also holds the native-stage decision
  (`run` or `skip`, as `test_suites_native_decision` makes it): the base that
  decides whether the cargo stages run comes from refs and branch config, which
  are not keyed, so a battery that skipped them never satisfies a range that
  needs them. A run whose plan disagrees with the keyed decision writes no
  verdict.
- Any other project `PROCESS_GATE_TEST_CMD` is recorded by `check-tests.sh`
  in `$TRELLIS_HOME/state/gate-verdicts/` after the command exits 0 for a full
  run and a recapture shows the run left the head, the clean tree, the runner
  and the keyed environment unchanged and the toolchain's executables
  byte-identical (versions are keyed as probed when the run started, so a miss
  probes them once). Its runner is the process-gate code that decides and
  records it. The run's output is retained as `logs/<id>.log`; the verdict
  records its sha256 and every lookup re-hashes it, so a verdict without its
  execution log is a miss. Before the command runs, the lookup persists an
  in-flight intent (owner pid, start) under the store lock; while any run of
  the same tree and command is unresolved, no lookup reuses a pass. A failing
  run, under that lock, records a failure for the tree and command, drops every
  pass for them and ends its intent; a pass whose run started before that
  failure is never recorded, so overlapping pass/fail runs cannot leave a flaky
  pass behind. A passing run that publishes nothing releases its intent; an
  owner that exits without finalizing (killed, or its store calls failed)
  counts as a failure dated when it is resolved, not when it started: it may
  have failed at any point while unresolved, so it supersedes every pass that
  overlapped it. A forced-full run (`PG_PUSH_TEST_SCOPE=full`) never reads a
  pass but is tracked the same way. A run never executes untracked: when the
  store's metadata is unhealthy (a lock or directory not owner-private, a
  multi-link lock) or the intent cannot be written, the lookup moves the store
  aside to `gate-verdicts.unhealthy-<time>-<id>`, so none of its passes is read
  again whatever is repaired later, and tracks the run in a fresh store,
  reported as a `tests: verdict store:` finding. When the store cannot be moved
  aside (lookup exit 3), its passes are still readable after a repair, so the
  test command does not run and Tests fails with `tests: not run`. A store
  that was moved aside, or never existed, holds no pass to revive: if a fresh
  one cannot be made, the run executes and the error is reported. Store errors are never swallowed.
- The gate's range interface (`PG_TESTS_BASE`, `PG_TESTS_HEAD`,
  `PG_TESTS_RECEIPT_FILE`, below) is not passed to a generic command whose run
  the lookup tracks: the verdict is keyed without the range, so committed code
  that narrowed on it would publish a pass that a wider range then reuses. A
  project that selects tests through the range interface should set
  `gate.verdict_reuse: false`. The contained local runner and selector-narrowed
  runs still receive it.

The command-verdict store is Trellis-guarded state: both reread-guards (and
the native and Pi guards) deny an agent Write or Edit whose target is under
`state/gate-verdicts`, also through a symlinked parent, or is another name (a
hard link or symlink) for a stored file. The block-destructive rules are
allowlists: `gate-verdict-direct-write` denies any shell command naming a
`gate-verdicts` path component, and `gate-verdict-ancestor-write` any command
naming `~/.trellis`, `$TRELLIS_HOME`, their `state` directory or a path under
`state`, unless every simple command on every line is a read-only tool (cat,
head, tail, ls, stat, wc, jq, sha256sum, shasum, test, grep, cd, echo,
printf) and no output redirection other than `N>/dev/null` or `N>&M` appears.
Archivers, patch and editor tools, git, rename, chown, interpreters and
command substitutions are therefore denied without being listed. less, file and
python3 are left out: less -o writes a file, file -C writes a compiled .mgc
into the working directory, and whether python3 only reads
cannot be decided from the text. These are pattern guards over the command
text: a path reached through a glob, a variable, a backslash or brace
expansion, a custom literal home spelling, or a relative path from a working
directory already inside the store is not recognised, and a hard link made
that way is still refused at Write and Edit.
That stops agent tool calls, not
the operating system: a process of the same UID outside an agent tool (a
project test, a script the agent wrote and ran) can still write a verdict and
a matching log, as for every other same-UID record in the earlier rulings. The
gate's mktemp inputs file is opened without following links and must be a
private, single-link regular file; a rewritten one cannot name a toolchain
whose executables differ.

**The reusable command grammar is an allowlist.** A command is reusable only
when it parses completely to known test runners started with audited options
(`RUNNER_SPECS` in `scripts/lib/gate_verdict.py`); any token or form the
grammar does not know refuses reuse, and the command then runs in full. Simple
commands may be joined only by `&&` (no `;`, `||`, pipes, redirections,
subshells or background jobs); no word may contain a shell expansion, and the
command (or a package script) may contain no control character: the shell
reads a newline as a command separator. Each is
an optional run of inline `NAME=value` assignments whose names `ENV_RULES`
keys or ignores, optionally after a bare `env`, then one of:

| Form | Audited options |
|---|---|
| `pytest`, `py.test`, `python[3[.N]] [-B\|-I\|-u] -m pytest`, behind `uv run` or `pdm run` | `-q`/`-v` levels, `-s`, `-x`, `-l`, `--strict-markers`, `--strict-config`, `--tb=`, `--color=`, `--capture=`, `--durations=`, `--maxfail=`, `-n`/`--dist` (xdist), `--import-mode=`, `--junitxml=`, `--cov*`, `--timeout=`, `--basetemp=`, `-p no:cacheprovider`, `-r<chars>`; positionals only tracked directories |
| `jest` | `--ci`, `--silent`, `--verbose`, `--coverage`, `--runInBand`/`-i`, `--detectOpenHandles`, `--forceExit`, `--passWithNoTests`, `--bail`, `--json`, `--maxWorkers=`, `--testTimeout=`, `--reporters=`¹, `--outputFile=`, coverage reporters¹/directory |
| `vitest run`, `vitest --run` | `--coverage`, `--silent`, `--passWithNoTests`, `--no-file-parallelism`, `--reporter=`¹, `--pool=`, worker counts, `--testTimeout=`, `--outputFile=`, `--bail=` |
| `node … --test …` | `--test-reporter=`¹, `--test-reporter-destination=`, `--test-concurrency=`, `--test-timeout=`, `--test-isolation=process`, `--experimental-test-coverage`, `--test-force-exit`, `--enable-source-maps`, `--no-warnings`; no positionals |
| `cargo test` | `--workspace`, `--all-features`, `--no-default-features`, `--features`, `--locked`, `--frozen`, `--offline`, `--release`, `--all-targets`, `--no-fail-fast`, `-j`, `--color`, `--target-dir`, quiet/verbose; after `--`: `--nocapture`, `--show-output`, `--test-threads`, `--color`, `--format` |
| `cargo nextest run` | the cargo set, `--no-capture`, `--test-threads`, output and status levels |
| `go test` | `-v`, `-race`, `-cover*`, `-failfast`, `-json`, `-count`, `-timeout`, `-p`, `-parallel`, `-tags`, `-mod`, `-shuffle`; positionals `./…` patterns under tracked directories |
| `npm`, `pnpm`, `yarn` `[-s] test\|t\|run <script> [-- args]` | the committed root `package.json` script, parsed by this grammar with the args appended; a `pre`/`post` script for it, workspace, directory, config, prefix and script-shell options all refuse |

¹ A built-in reporter name, or a `./` module file tracked in HEAD. A bare
specifier resolves as a package from `node_modules`; that, or a path outside
the tree, is code the key does not bind, and a reporter module can end the run
before any test executes. The same contract applies to reporters named in
committed runner configuration: Jest's `reporters`, `coverageReporters` and
`testResultsProcessor` in `package.json` `jest` or `jest.config.json` are
checked entry by entry (`<rootDir>/` counts as `./`), and a JS/TS Jest or
Vitest configuration that mentions a reporter at all refuses, because its
value cannot be read without running it. Every root `jest.config.*`,
`vite.config.*`, `vitest.config.*` and `vitest.workspace.*`/`vitest.projects.*`
file is checked. Jest's other module options (`preset`, `globalSetup`,
`globalTeardown`, `setupFiles`, `setupFilesAfterEnv`, `testEnvironment`,
`testRunner`, `runner`, `resolver`, `snapshotResolver`, `testSequencer`,
`transform`, `watchPlugins`, `dependencyExtractor`, `prettierPath`,
`moduleLoader`) and its path options (`rootDir`, `roots`, `modulePaths`,
`moduleDirectories`, `moduleNameMapper`, `projects`) may name a package or an
in-tree path, resolved as Jest resolves `<rootDir>`; an absolute or outside
path refuses, and each object in `projects` is checked the same way. A string
`projects` entry (a project directory or glob, at any depth) refuses: Jest
loads that project's own configuration, which this check does not read.
Path values are checked physically as well: the resolved path, symlinks
followed, must stay inside the real tree root.

**Symlinks and submodules.** A tracked symlink (Git mode 120000) must
resolve, as the filesystem resolves it, to a file tracked in HEAD; one whose
target is absolute, a directory (ignored files under it would be discovered
under a name no runner skips), outside the real tree root, untracked,
ignored or in `.git` (any letter case) refuses reuse for every command, the
full battery included. The tree key binds the link's
target spelling, not the files it reaches, so a link out of the keyed tree (a
Jest `rootDir`, a test directory, a config file) would let an unkeyed file
decide the run. A gitlink (submodule) refuses too: its content and any
committed ignore setting for it are outside this tree. Jest path values into
`.git` (any letter case, also through a link) refuse.

Everything else refuses: name, file, shard, changed-file and only-filters;
help, list, dry-run and no-execution modes (`--help`, `--listTests`,
`--test-only`, `-- --help`, `-args -test.list`, `make -n`); execution
replacement (`go test -exec`, `cargo +toolchain`); `make`, `npx`, `bun`, shell
wrappers (`bash -c`) and path-qualified programs.

**What is keyed or refused.** One table, `ENV_RULES`, decides every
environment name; the first matching row wins:

| Action | Names |
|---|---|
| refuse (narrowing) | `PG_PUSH_TEST_SCOPE`, Bats filters, `TRELLIS_TEST_*` (not `TRELLIS_TEST_SHARDS`), non-operational `TRELLIS_LOCAL_GATE_*`, `TRELLIS_HEAVY_TEST*`, `PYTEST_*`, `JEST_*`, `VITEST`/`VITEST_*`, `NEXTEST_*` (not `NEXTEST_TEST_THREADS`), `CARGO_*` including `CARGO_HOME` and every target, rustflags, runner, wrapper and config override (not `CARGO_TARGET_DIR`, `CARGO_TERM_*`, `CARGO_BUILD_JOBS`, `CARGO_NET_OFFLINE`), `RUSTFLAGS`, `RUSTDOCFLAGS`, `RUSTC*`, `GOFLAGS`, `GOENV`, `GOROOT`, `GOWORK` (not `GOWORK=off`, which is keyed), `MAKEFLAGS`, `GNUMAKEFLAGS`, `MFLAGS`, `MAKEFILES` |
| refuse (injection) | `LD_*`, `DYLD_*`, `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `IFS`, `POSIXLY_CORRECT`, `PYTHON*` (not `PYTHONDONTWRITEBYTECODE`, `PYTHONUNBUFFERED`), `PERL*`, `RUBY*`, `GEM_*`, `BUNDLE_*`, `NODE_*` (not `NODE_ENV`, `NODE_EXTRA_CA_CERTS`), `npm_config_*`, `pnpm_config_*` (not `pnpm_config_verify_deps_before_run`), `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`, `JAVA_OPTS`, `CLASSPATH`, `MAVEN_OPTS`, `MAVEN_ARGS`, `GRADLE_OPTS` |
| key (value) | exported shell functions (`BASH_FUNC_*`), `CDPATH`, `CI`, `TZ`, `LANG`, `LANGUAGE`, `LC_*`, `NODE_ENV`, `NODE_EXTRA_CA_CERTS`, `COREPACK_*` (not `COREPACK_HOME`), `DOCKER_*`, `GOTOOLCHAIN`, `GOEXPERIMENT`, `GODEBUG`, `GOOS`, `GOARCH`, `CGO_ENABLED`, `RUST_TEST_THREADS`, `NEXTEST_TEST_THREADS`, `CARGO_NET_OFFLINE`, `UV_*`, `PDM_*`, `YARN_*`, `pnpm_config_verify_deps_before_run`, and every `gate.env_passthrough` name (set, empty or unset) |
| ignore (speed only) | `CARGO_BUILD_JOBS`: build parallelism changes how fast, not what is built or run (the release qualification run exports it) |
| refuse (path-valued) | `DOCKER_CONFIG`; a `UV_*`, `PDM_*` or `YARN_*` name ending `_FILE`, `_FILENAME`, `_PATH`, `_DIR`, `_HOME`, `_ENVIRONMENT`, `_PROJECT`, `_DIRECTORY`, `_FOLDER`, `_PYTHON` or `_RC` (`UV_CONFIG_FILE`, `PDM_CONFIG_FILE`, `YARN_RC_FILENAME`, `UV_PYTHON`), or whose value is a path (an `http(s)` URL is not; `file:` is): keying it binds the name, not what it points at |

A refused name neither records nor reuses: the command runs. The managed
pre-push dispatcher starts the gate under `env -i` with only its fixed
environment, the passthrough names and `DOCKER_HOST`, and it forwards the
passthrough names of the remote-default (`origin/HEAD`) `.trellis.json`. The
verdict keys that same policy: the names it declares, plus any the candidate
HEAD declares, and the policy's blob as `policy`. The dispatcher passes that
blob as `TRELLIS_GATE_ENV_POLICY`; a gate whose own reading differs (the remote
default moved under it) refuses.

**External configuration.** Configuration a runner reads from outside the
tree is keyed by content, present or absent: Cargo's `$HOME/.cargo/config*`
and every ancestor `.cargo/config*`; the user and global `npmrc` (and pnpm's
and yarn's rc files) for package scripts; Go's env file; for `uv run` and
`pdm run`, the project environment's interpreter and the managers' config.
An explicit Cargo home (`CARGO_HOME`, inherited or inline) refuses instead. So
does any of that configuration that replaces the program a run executes, or
redirects it to code or configuration the key does not bind, since hashing
the file binds its text, not what it names: a Cargo `runner`, `rustc`,
`rustc-wrapper`, `rustc-workspace-wrapper`, `rustdoc`, `linker`, `ar`,
`include`, `paths`, `patch`, `path`, `replace-with`, `directory`,
`local-registry` or a `linker` in `rustflags`; an npmrc `script-shell`,
`shell`, `node-options`, `userconfig`, `globalconfig`, `onload-script`,
`shell-emulator`, `use-node-version`, `node-version`, `npm-path` or pnpmfile;
a Yarn `script-shell`, `yarn-path`, `yarnPath`, `plugins`,
`injectEnvironmentFiles` or a `--` CLI line; a Go env `GOFLAGS`, `GOTOOLCHAIN`,
`GOROOT`, `GOWORK`, `CC`, `CXX`, `AR` or `GOENV`. Any pytest configuration file or
`conftest.py` above the checkout, and any ancestor `go.work`, refuses too.
For package scripts, every ancestor `.npmrc`, `.yarnrc` and `.yarnrc.yml` from
the checkout up to `/` is inventoried the same way: keyed by content, and
refused when it sets any of those settings.

**Committed executor settings.** The committed root `.npmrc`, `.yarnrc` and
`.yarnrc.yml` (for package scripts) and `.cargo/config*` (for Cargo) are
checked for the same settings, because the tree key binds the file, not the
program it names. A program or path setting (a Cargo `runner`, `linker`,
`rustc`, wrapper, `rustdoc`, `ar`, `path`, `directory` or `local-registry`; an
npm `script-shell` or `shell`; a Yarn `script-shell`, `yarn-path` or
`yarnPath`) is allowed only as a relative path to a file or directory tracked
in the tree; a program named without a `/` is looked up on `PATH` and refuses,
as does an absolute or outside path. Every other setting in that list refuses
whenever it is set.

**Native stages.** Their Cargo adapter runs cargo from `/` with a private,
fresh `CARGO_HOME`, so the only Cargo configuration they load is
`/.cargo/config*`: it is keyed, and an executor setting there refuses. The
pinned `+1.97.1` cargo, rustc and rustdoc, the `rustc -vV` answer (through the
caller's probe) and the offline registry files are keyed whatever the rustup
default is; a changed pin misses and a missing or unusable one refuses. A
candidate whose `rustc -vV` probe fails costs reuse even when another
installed candidate answers, since the stage's own longer probe may select it.

**Ignored files.** Any git-ignored path refuses reuse unless it is a
`.DS_Store` file or lies in a directory every runner of the command skips by
default: pytest's `__pycache__` and default `norecursedirs` (`.*`, `build`,
`dist`, `node_modules`, `venv`, `*.egg`, `CVS`, `_darcs`, `{arch}`); jest,
vitest and `node --test` `node_modules`; cargo `target`; go any `.`/`_` path
(not `testdata` or `vendor`). No cache directory is exempt for every runner
(`node --test` discovers tests in `__pycache__`), and there is no coverage or
output-directory allowance: pytest and `node --test` discover tests there. A
directory the command names explicitly (`pytest .hidden`, `go test
./_tools/...`) is traversed whatever its name, so a path under it is judged by
its components below that root; an ignored directory holding a root, or an
ignored `conftest.py` on the way to one, refuses. A committed pytest discovery
setting (`norecursedirs`, `testpaths`, `rootdir`, `confcutdir`), or a committed
runner config that names the skipped directory (a Cargo `[[test]] path`, a jest
`roots` entry, a pytest `addopts` path), refuses it again. Ignored `.env` files
therefore refuse.

**Toolchain dispatchers.** A tool reached through rustup, a pyenv, rbenv,
nodenv, goenv, jenv or asdf shim, mise or volta binds the executable the
manager selects for the project (`rustup show active-toolchain` plus the hashed
`rustup which` binary; `<manager> which <tool>` otherwise), not the proxy. A
rustup proxy is recognised by what the executable is, not by its name: a
hard-linked or copied proxy answers `RUSTUP_FORCE_ARG0=rustup … --version` as
rustup, and is queried through itself. Every identity probe goes through the
caller's version probe, so the local runner contains it like a `--version`
probe. When the selection cannot be
established (an unknown `shims` directory, a manager that fails or names
nothing), reuse is refused. rustup with no installed toolchain is keyed as
"none". nvm switches `PATH` itself, so its `node` is already the resolved
binary.

**Kill switches.** `.trellis.json` `gate.verdict_reuse: false` per project;
`$TRELLIS_HOME/state/gate-verdicts/reuse-disabled` (any file, created by the
operator outside an agent session) for every project on the machine; and the
weekly backstop's `reuse-disabled.json` in the gate state directory.

Opt out per project when tests depend on external state (a live database, a
remote service, time-sensitive fixtures) in the committed `.trellis.json`:

```json
{ "gate": { "verdict_reuse": false } }
```

An unreadable or mistyped policy also refuses reuse; it never widens it.

Full-battery verdicts live in `${TRELLIS_GATE_STATE_DIR:-$HOME/.local/state/trellis-gate}/`
(directories mode 0700, records 0600). The default is pinned regardless of `XDG_STATE_HOME`,
so cron and interactive agents share the queue and disable marker. An explicit
state override must be absolute, outside every checkout, and shared by all
callers; invalid roots refuse before creating state. Queue metadata uses
`queue.lock`; admitted runners retain the legacy `lock` flock until close, so
pre-072 runners cannot overlap them. The toolchain binds each discovered tool's
resolved path and executable bytes, plus a version for tools with a uniform
`--version`. Narrowing and test-seam variables (`PG_PUSH_TEST_SCOPE`, Bats
filters, `TRELLIS_TEST_*` other than `TRELLIS_TEST_SHARDS`, non-operational
`TRELLIS_LOCAL_GATE_*`, `TRELLIS_HEAVY_TEST*`, and the rest of `ENV_RULES`) refuse reuse. Checkout HEAD
must be the gated head. Ignored files matching any non-recursive suite-discovery
glob also refuse reuse, including files under ignored parent directories.
A failed version probe refuses reuse, and that is all it does: a probe that
times out (2 s) is a miss, and the test command runs as if no verdict existed;
it never fails or blocks the gate. When the command was otherwise reusable,
the run is still tracked by its tree and command alone: a failure supersedes
every earlier pass for them, and a pass publishes nothing. A refused command
never touches the store. `mktemp`, `lsof`, `ps` and the npm/npx
entrypoints bind resolved executable bytes without invoking a version command;
normal npm/npx installations additionally bind the resolved package metadata,
so an npm-only upgrade changes the key even if its entrypoint is unchanged.
Other discovered tools require a successful version probe. Dirty, narrowed, test-seam, partial, failed, timed-out, interrupted or
containment-ambiguous runs never qualify. An explicit rerun invalidates an older
pass for the same inputs before starting. Changing inputs during a run also
prevents a write. The retained aggregate and its digest must still validate.
Wrong modes, symlinked records, missing evidence and verdicts older than seven
days are misses, never passes. The weekly uncached backstop compares tree-matched
candidates even when scheduler toolchain inputs differ, records the
differing field names, and raises P1 on a failing unchanged tree.
A `reuse-disabled.json` marker in the state directory disables reads and writes
for both writers until an operator reviews the divergence and removes it.

Residual inputs: contents of the allowed ignored dependency/cache directories
(`node_modules`, virtualenvs), Python installed package contents, npm/npx
imported contents beyond entrypoints/package metadata (and package metadata
hidden by nonstandard wrappers), environment names outside `ENV_RULES` on a direct (unmanaged) gate
run, external services, external Git exclude/config file bytes, and same-UID
writes from outside an agent tool are not covered.
Projects whose results depend on these should set `gate.verdict_reuse: false`.
Fresh Git discovery still checks ignored suites on every lookup. The seven-day cap
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
verdict with the same tree, command, runner/fence, toolchain and platform.
Refs are not keyed, so creating the verified tag changes nothing; the tag's
identity is verified separately. An occupied/disabled/stale/tampered verdict
misses. No new reusable full verdict is written by the tag-reading rerun.

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

Only push Tests receives gate-owned `PG_TESTS_BASE` and `PG_TESTS_HEAD`, full commit SHAs for the exact resolved range (not hard-coded trunk or necessarily checkout HEAD); `A...B` uses merge-base(A, B). A generic command whose run the verdict lookup tracks receives none of the range interface (see "Verdict reuse"); a project that selects through it sets `gate.verdict_reuse: false`.
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
`shellcheck source=` hints, Python `import`/`from` modules under `scripts/`,
JS/TS/MJS `import`/`require` edges under `core-rules/pi/` and `scripts/`,
optional `declared-test-inputs.json` fixture mappings, and literal helper/fixture
references from both endpoint trees. Inspect suite selection provenance with
`python3 scripts/lib/push-test-map.py --explain <base>..<head>` (emitting
`explicit-owner`, `import-consumer`, `declared-fixture`, and `fixed-smoke` reason
tags), or run narrowed suites locally via `bash scripts/run-tests.sh --changed`.
Set `PROCESS_GATE_TEST_SELECTION=full` to force the full battery (`P48`). A removed dependency edge still selects its old
consumer. Changes to `scripts/lib/` always require the full battery; unknown
paths, missing required suites, and dependencies reaching core hook/skill/Pi
suites also fall back to full (`uncertain-full`). Selections travel only as command arguments,
never as an environment-carried file list.

## Docs-only ranges (opt-in)

A range that changes only passive records can skip the test battery. The rule is narrow, and doubt runs the full battery.

The project opts in with a policy file at `.claude/skills/process-gate-local/docs-only-tests.policy` or `.agents/skills/process-gate-local/docs-only-tests.policy`. If both exist, their Git blobs must be byte-identical. The gate reads the policy and canonical `.trellis.json` from the range's base, never from the checkout. Set `"gate": {"docs_only_tests": false}` to disable both the ordinary and release-metadata classes. Absent or `true` does not opt in by itself; invalid base project JSON disables narrowing. A policy edit cannot exempt its own push. A later incremental push can use a policy already at its branch base, but that is not protected-base approval or merge evidence.

The format is one directive per line. Comments are whole lines starting with `#`; the rest of a directive line is its value.

```
# scope push: optional; only an explicit, unprotected branch-only push.
scope push
# allow: an anchored, case-sensitive ERE. deny: case-insensitive, beats all allows.
# tests: an optional command, at most once, run in place of the battery.
allow ^docs/adr/[A-Za-z0-9][A-Za-z0-9._-]*\.md$
deny ^docs/adr/0009-pinned\.md$
tests bats scripts/tests/docs-consumers.bats
```

`allow` patterns must be anchored with `^…$`. An unknown keyword, an empty or invalid pattern, or a second `tests` or `scope` line makes the policy malformed.

With `scope push`, use a reviewed passive subtree such as `^docs/records/…$` or an exact approved Markdown path. Global allow rules, `docs/`-wide rules, and subtree rules for `docs/implementation/` do not qualify. Behaviour-bearing namespaces such as `config`, `schemas`, `workflows`, `specs`, `site`, and `content` are excluded regardless of case. Markdown can still be a program or test input: keep full Tests or name a replacement that exercises those consumers. A push-scoped policy requires the clean physical worktree at the gated head (including index, submodules, and unignored untracked files). It cannot narrow tag, mixed, protected, merge, or manual/default runs, or declare the release-metadata class. Policies without `scope push` keep their legacy contexts; older checkers reject the directive and run full.

**Eligibility.** The range narrows only when every path touched by every commit in it qualifies. That covers both sides of a rename, deleted paths, and changes made and then reverted inside the range. A path qualifies only if it meets all of these:

- It matches an `allow` entry and no `deny` entry.
- It clears the built-in floor, which no policy can widen:
  - ordinary path components only: no dot-directories, spaces, control characters or leading dashes;
  - a `.md` suffix;
  - no behaviour-bearing namespace (`core-rules/`, `scripts/`, `hooks/`, `skills/`, `commands/`, `agents/`, `prompts/`, `templates/`, test, fixture and baseline directories, secret directories);
  - no operative file name (`SKILL.md`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `prompt.md`, `targets.md` and similar), and no `VERSION`, `UPGRADING` or secret-like name. These name checks are case-insensitive.
- Both old and new entries, where present, are plain `100644` UTF-8 text without binary controls or LFS pointers. Case-fold aliases, symlinks, gitlinks and executables do not qualify.

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
- A scoped push with no policy tests command prints `Tests: no-tests: docs-only`. Other ordinary docs-only runs print `Tests: narrowed (docs-only: N files)`, where N counts net changed paths. The verdict includes a checker-owned `tests: docs-policy v1` record with the exact endpoints, policy blob, count, and `battery=not-required|targeted`. The record describes scope, not success or proof that hooks ran. A narrowed pass is never a full-battery pass.
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
