# Changelog

All notable changes to Trellis are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project uses Conventional Commits. Portable Trellis releases use semantic versions and annotated immutable tags. Earlier dated entries remain as historical records.

## [v1.0.0] — 2026-09-06

### Added

- A shared behavior contract for Claude Code, Codex and Pi, with native action normalization, Pi extension and worker context, portable verification receipts and task recovery.
- Capability reports that distinguish observed enforcement, advisory behavior, unsupported features and unknown native state.
- Evaluation cohort identities, wiki proposal refinement and native Pi evaluation adapters. The held-out pilot found equal pass rates with and without the skill; it did not justify skill promotion.
- Canonical skill discovery in the management checkout without attaching it to a mutable runtime.

### Fixed

- Preserve shared attachment ownership, registry agreement and project-authored surfaces through partial detach, recovery, repair and explicit release adoption.
- Allocate managed command scratch under the verified local home. Preserve native hook arguments, stdin and prior-hook status through the managed dispatcher.
- Reject failed or empty hook generation before publishing attachment or adoption dispatchers. Refuse blank hooks during ownership validation; malformed adoption targets leave the current hooks and release intact.
- Reconcile scheduled inputs, usage estimates, routing guidance and proven obsolete consumers. Export the portable Pi surfaces through the public projection.
- Confine test Git mutations and fixture cleanup to disposable roots. Restore real release dependencies in fixtures and bound the local runner to four shards, with two concurrent cases in ten audited suites and a one-hour deadline.

## [v1.0.0-rc.54] — 2026-09-04

### Fixed

- **The same jq `//` false-collapse in the managed-exclude check, surfaced by fixing the first one.** `exclude.managed_by_attachment` was read as `.managed_by_attachment // empty`, so every worktree that does not own the shared exclude block — one owner per checkout, so all the others — reported `managed excludes: owner managed-block state is invalid`. It was invisible while the hook-authority failure short-circuited the rest of the row: at rc.52 only 13 of 21 rows evaluated the exclude check at all. Both boolean reads now go through one `hc_json_bool` helper; a sweep found no other boolean read through `// empty`.

## [v1.0.0-rc.53] — 2026-09-04

### Fixed

- **Every secondary worktree in a multi-worktree checkout reported a phantom ownership error.** The shared-hook-authority scan read `.git_hooks.enabled // empty`, and jq's `//` treats `false` as absent — so the non-hook-owning worktree the scan exists to bless collapsed to empty and fell through to `corrupt`. Their hooks were live all along (shared `core.hooksPath`, executable `pre-push`); the error was a false positive that also masked real findings in the same field. Two worktrees in one consumer and one in another now report `shared`.

- **Owned-artifact verification refused with a bare `return 3` naming nothing.** Locating which of ~200 owned leaves had drifted required `bash -x` on the whole detach — which is what made the affected consumer's stall at rc.46 take hours. It now names the artifact and its recorded kind, and separately names an owner record whose worktree root no longer exists, the state `registry deregister` creates by design when it leaves owner records behind as recover evidence.

- **`registry deregister` could not remove the row that broke the listing.** It selected through the strict reader, which fails the whole listing on any row whose path is present but unresolvable as a canonical Git worktree — the exact row deregister exists to remove. Selection now uses the diagnostic reader; the write still re-reads under the lock and stays strict.

## [v1.0.0-rc.52] — 2026-09-04

### Fixed

- **Attach durability: silent `exit 3`/`exit 4` paths in attach, detach, recover and adoption now name what failed.** The managed exclude block, pending detach journals, detach owner-transfer mismatches, `core.hooksPath` races and dead registry rows all had bare `return "$TRELLIS_EX_CONFLICT"` with no message; each now prints the path, the expected and actual hashes or the phase counters that explain the refusal. `registry deregister --fleet NAME (--project ID | --root PATH | --worktree-root PATH) [--force]` removes registered worktree rows, refusing a row whose path still exists unless forced — the missing tool for the dead rows that block a whole checkout group from adopting. `adopt` names the offending rows and points at it. Detach now verifies it actually restored `core.hooksPath` and warns loudly when the restored path leaves pushes UNGATED until re-attach. Adoption reports owned keys the new template no longer carries as `left in place (no longer in template)` instead of showing no drift.

- **Release verification was `O(entries)` process spawns and ran up to six times per adopted row.** `release_store_verify_path` shelled out per manifest entry (10,000+ `ls`/`git hash-object` spawns over a 2,821-entry tree), which is what made `release adopt --all` take 2h10m for 16 projects. Hashing and permission collection are now batched through one `git hash-object --stdin-paths` and one `xargs ls`, and a successful verification is memoized for the shell process that performed it. **57.852s → 5.581s** on a sealed copy of live rc.40 (2,834 entries), with what is verified unchanged: tampered bytes, tampered oids and extra payload files are still refused, failures are never memoized, and each memo key carries the owning shell's `$$` so a forked child re-verifies rather than inheriting a stale success verdict across a process boundary.

- **`attach` refused every normal interactive PATH on macOS.** The attach-durability work hard-refused any PATH entry with a symlinked component, and `/System/Cryptexes/App/usr/bin` is line 2 of `/etc/paths` on macOS 13+ behind a symlinked `/System/Cryptexes/App` — so `trellis attach` exited 5 on a stock login shell, which is the defect that work set out to remove. Symlinked and trailing-slash entries are canonicalized again, with the entry, its resolved target and the symlinked component named on stderr. Relative entries, control characters, real non-directories, unresolvable directories and a resolved target that is itself non-canonical still refuse; a symlink dangling at any component is skipped like any other missing entry.

- **Spec 044 de-slop, cohorts C6 and C8: evidence-doctrine sweep over `core-rules/hooks` and the Claude/Codex hook twins.** ~10,000 lines across 195 files, every hunk tracing to an approved unit in `specs/044-de-slop` (71 scan units and 2,164 rows in phase 1, triaged to 236 approved fix units with per-unit operator decisions in phase 2). C6 and C8 ship together because a twin pair must change together: landing a hook fix without its twin is exactly the Claude/Codex drift the twins exist to prevent, and it is invisible to typecheck, lint and tests — it surfaces only when a session runs under the other harness. Size exception recorded in `docs/adr/2026-09-04-de-slop-c6c8-single-pr.md`.

- **Skill I/O now fails closed instead of swallowing incomplete data (de-slop C7).** Quota reports missing `stale`, expiry, or `errors` are dropped with a diagnostic rather than treated as healthy; PR hygiene, secrets scan, wiki `mark-stale` writes, and security scanners (garak/gitleaks/llm-call) propagate git/scanner/lock failures instead of exiting 0; foreman prompt failures surface to the caller. Wiki write tests cover unavailable `fcntl` and rollback/temp-cleanup errors. Tick path in the foreman HANDOFF template is `core-rules/skills/execute/scripts/tick.sh`; roles state stays at `~/.trellis/state/roles-resolved.json` after the main merge.
- **Managed git-hooks dir now passes through every previous project hook.** Attach set `core.hooksPath` to `~/.trellis/state/git-hooks/<checkout-id>/`, which held only the `post-checkout` and `pre-push` dispatchers, so every other project hook under `previous-hooks-path` (husky `pre-commit`, `commit-msg`) went silently inert. Attach, relink, and release adoption now write a deterministic pass-through shim for each executable standard hook name found under `previous-hooks-path` (relative paths resolve against the checkout root); each shim re-executes the previous hook with the caller's `PATH`/`HOME`/`TMPDIR`/`TMP`/`TEMP`/`LC_ALL` plus every `GIT_*` variable present at entry (`GIT_INDEX_FILE`, `GIT_AUTHOR_*`, … so lint-staged/husky partial commits keep working) — the exact prior-hook delegation contract, with `env -i` semantics for everything else and no control-plane sanitization — and exits 0 when the previous hook is missing or non-executable. Validators accept the shims as managed files (regenerated and compared like the dispatchers, fail-closed on tampering), detach removes them, and any gain or loss under `previous-hooks-path` is re-synced by the next attach, relink, or release adoption — there is no background watcher. Doctor's `git hook authority` drift line now names the likely cause (``husky`` ``prepare`` after a package install resets `core.hooksPath`) alongside the absolute-path remedy.

## [v1.0.0-rc.51] — 2026-09-04

### Fixed

- **`pi auth check` is not a liveness probe, and trusting it produced a wrong roster "fix" in rc.50.** It does not load user packages or extensions, so it answers `provider_not_found` for every plugin-registered provider even while that provider dispatches fine. Probing by actual dispatch (`pi -p --model <id>`) gives the real picture: `antigravity/gemini-3.8-flash`, `opencode-go-2/muse-spark-1.3-contributor`, `xai/grok-4.6`, `meta/muse-spark-1.3-contributor` and `opencode/muse-spark-1.3-contributor-free` all answer; only `xai-oauth/...` and `google-antigravity/...` are genuinely not found, and `opencode-go` answers with a 401 credits error. rc.50 moved `cheap-2` from `opencode-go-2` to `opencode-go` on the strength of the bad probe, pointing a working lane at the one account with no balance. Reverted. The `xai-oauth` to `xai` half was correct and stands.

- **`PROVIDER_NAMES` in the usage adapter is an allowlist, not a rename table, and antigravity fell out of it.** A provider missing from that map is dropped with `provider-dropped: unmapped-provider`, so it can never report quota. The roster's `provider` field is also the dispatch prefix — `resolve-roles.py` refuses any model that is not `<provider>/...` — so when the roster was corrected to pi's `antigravity/` prefix, the adapter's `google-antigravity` output stopped matching and a provider sitting at 99% headroom was refused as `no-report`. Now mapped to itself. The same diagnostic showed **`opencode` had never been mapped at all**, so the Zen lane's real session/weekly/monthly budgets were invisible to the resolver and the route passed only on its `metered: prepaid` declaration; it now reports properly ($12 per 5h session, $30 weekly, $60 monthly, all provider-wide).

- **The Meta Muse Code subscription and the OpenCode Go 1 account are now roster lanes.** `muse-meta` (`meta/muse-spark-1.3-contributor:xhigh`, the subscription reached through `pi-meta-oauth`) and `cheap-1` (`opencode-go/...`) join the foreman, implementer and deep-work chains as reportless Muse fallback for when Codex quota is exhausted. Neither publishes an OpenUsage report. `cheap-1` is placed LAST in every chain: Go account 1 answers `401 CreditsError: Insufficient balance` today, and a `metered: prepaid` candidate is eligible without a usage report, so ahead of a working lane it hands the foreman a route that dies on its first call — which is exactly what happened twice on 2026-09-04. `muse-meta`'s 5h window is small: a single foreman exhausted it in ~50 minutes on 09-03, so it sits behind the two Go/Zen lanes rather than ahead of them.

- **`xai` declared unmetered, by operator ruling.** It publishes no OpenUsage report, and refusing it as `no-report` left every verdict role degraded whenever Codex was exhausted — which is most of the time this week. `UNMETERED` is an operator assertion of headroom, not a measurement, which is why it is set by ruling and named in the code comment.

Net effect on the resolver, live: degraded roles drop from five (`foreman`, `hard_implementer`, `security_reviewer`, `merge_reviewer`, `refuter`) to two. `scout` and `reviewer` resolve to `antigravity/gemini-3.8-flash:high` at 0.99 reported headroom; `hard_implementer` and `security_reviewer` to `xai/grok-4.6:xhigh`. `merge_reviewer` and `refuter` remain degraded because only three families are reachable with Codex exhausted and each verdict role must draw a distinct one — honest scarcity, not a defect.

## [v1.0.0-rc.50] — 2026-09-04

### Fixed

- **The process gate's main checks ran unbounded on macOS, turning a hung command into a silent multi-hour `git push`.** `run_check` in `core-rules/skills/process-gate/scripts/check-tests.sh` guarded its ceiling with `command -v timeout` and had no fallback, so on any host without GNU timeout — every stock macOS box — typecheck, lint and tests ran with no limit at all. Measured 2026-09-04: two pushes from the affected consumer sat in the test leg for 3h17m and 3h45m against a half-dead Docker daemon whose client calls never returned; `git push` simply never came back, with no tell in the session. The portable `run_with_timeout` (perl process-group + SIGALRM) already existed in the same file for the mutation probe and is now shared. Where no bounded runner is reachable at all the check still RUNS and the gate emits one warn naming the condition — refusing to run was tried first and is worse, since it turns the gate into a silent skip whenever PATH is minimal. Exit 124 (GNU timeout) and 142 (the perl path) are reported as "exceeded Ns and was killed" rather than "exited 124", which reads like a test failure. Also un-skips the ceiling test that was gated on `command -v timeout` — skipped on exactly the platform where the ceiling was not being applied. `check-tests.bats` 31/31.

- **The reader guard denied every `gcloud`/`kubectl` output pipeline.** GCP and Kubernetes resource identifiers embed a literal secrets-directory segment (`projects/<num>/…`, `namespaces/<ns>/…`), and those appear as *arguments* to `grep`/`sed`/`awk` when post-processing command output, where no file is read. `core-rules/hooks/block-destructive.sh` denied all of them. The affected consumer had worked around it by replacing its owned hook symlink with a local copy — the right fix in the wrong place, since it also blocks detach. Upstreamed, and tightened against a hole the local version had: it stripped any path containing a segment literally named `projects` or `namespaces`, so a genuine read of `/Users/<me>/projects/<app>/…/creds.json` was silently allowed. Two guards close that — the command must actually invoke `gcloud` or `kubectl`, and the identifier must start at a token boundary. `block-destructive.bats` 34/34, six new tests.

- **Three roster entries named providers pi does not register, and the foreman role had no eligible candidate at all.** Probed against the live install: `xai-oauth`, `opencode-go-2`, `meta` and `antigravity` all return `provider_not_found`, while `opencode`, `opencode-go`, `openai-codex` and `xai` are ready. `grok` and `security-reviewer` move to `xai`; `cheap-2` moves to `opencode-go` (same model id, the registered account). That is the silent-drift defect logged on 09-03, where the resolver still returned `dispatchable: true` and two dispatches ran into silence. `meta` and `antigravity` are left alone — genuinely absent from pi despite installed plugins and stored credentials, and guessing another id would be a silent substitution rather than a correction. Separately, `sol` is Codex-weekly-exhausted and `grok` publishes no usage report, so `foreman-start.sh` refused with `no foreman candidate has quota`; the chain is now `sol -> cheap -> cheap-2 -> grok` and resolves to `opencode/muse-spark-1.3-contributor-free:xhigh`. The first attempt at `opencode-go` failed with `401 CreditsError: Insufficient balance` — the prepaid blind spot, where `metered: "prepaid"` grants eligibility without a usage report and `pi auth check` returns ready on the mere presence of an API key. `security_reviewer`, `merge_reviewer`, `hard_implementer`, `reviewer` and `refuter` remain degraded and are reported as such.

- **The user settings template imposed operator preferences, and `attach --user` refused because of it.** `core-rules/templates/claude-user-settings.json` renders through an `explicit-json` merge, so every top-level leaf it declares is an owned key the attach transaction will not overwrite. `outputStyle` forced "Trellis Orchestration" over whatever style the operator had chosen, and `hooks.SessionStart` wired `herdr-foreman-session.sh` over any hand-wired SessionStart hooks. Both collided, `attach --user` exited 3, and `~/.claude/skills/herdr-foreman` stayed pinned to the **rc.35** payload — which is why the rc.49 1+4 foreman layout never reached a live session, and why a session reading that link found OMP prose that rc.49 does not contain (rc.49 `SKILL.md`: zero OMP references; rc.35: nine). The template now declares only `workflowSizeGuideline`, which is Trellis policy; the output-style file and the hook script both still ship as owned leaves, so nothing is lost but the imposition. `user-surface.bats` 20/20, `doctor.bats` explicit-json drift 1/1.

- **The mirror's payload-prune `rm -rf` had no empty-path guard.** `preflight_payload_no_publish_prunes` in `scripts/sync-to-template.sh` rejected absolute paths and `..` but not an empty entry, so a blank line made it run `rm -rf "$stage/"` and delete the staged payload. Both prune loops now use `${stage:?}` / `${path:?}`. This was SC2115, the only finding blocking the gate's lint leg on this repo since PR #442, so every PR here inherited a red gate for it.

## [v1.0.0-rc.49] — 2026-09-03

### Changed

- **Foreman panels render 1+4, not 2x2 — the orchestrator keeps the full-height left third.** The old grid gave pane one a quarter of the tab, but the orchestrator is the pane the operator reads and coordinates through; workers are glanced at. `foreman-start.sh` now splits the orchestrator right at ratio 0.3333 and fills the right two-thirds as a 2x2, so a panel holds five panes before overflowing to a new tab (capacity thresholds 4 → 5). `--ratio` is the fraction the split *target* keeps, confirmed in a probe tab rather than assumed: the resulting geometry on an 291x81 tab is orchestrator 97x80 and four workers at 97x40. Doctrine updated in `core-rules/skills/herdr-foreman/SKILL.md` and `core-rules/references/herdr-foreman.md` § Panel layout and teardown.

### Fixed

- **`Read()` deny removal now reaches attached projects.** rc.48 emptied `permissions.deny` in both settings templates, but nothing propagated it: the settings render merges with `merge_missing` (`scripts/attach-project.sh:1191`), which writes only template keys the destination lacks, and `release adopt` replays the owner record's recorded owned-key value. Both leave an existing populated array untouched, so a template change that *removes* entries is undeliverable to an already-attached project by either path. Detach followed by a fresh attach is the only mechanism that renders the new template — the same remedy `doctor` prescribes for drifted manifest leaves. Recorded here because the rc.48 entry claimed a fix that no attached project had received.

## [v1.0.0-rc.48] — 2026-09-03

### Fixed

- **Settings templates no longer ship `Read()` deny rules, which were costing a non-bypassable approval prompt on ordinary `grep` calls.** `core-rules/templates/claude-settings.json` and `claude-settings.local.json` carried a 35-entry `permissions.deny` list — `node_modules`, `.next`, `dist`, `build`, `out`, `target`, `vendor`, `.venv`, caches, lockfiles — that had propagated verbatim to 25 project settings files. It was context hygiene, not security: no `.env`, no secrets, no credentials. Claude Code 2.1.259 escalates to a manual prompt whenever a Bash read target **cannot be statically resolved** *and* a `Read()` deny rule is configured (reason codes `cd-compound-read`, `deniedPathInsideDirectory`), and that escalation is in the same non-auto-approvable class as `cd-compound-write`, `cd-compound-redirect`, `cd-multi-positional`, `shell-expansion`, and unenumerable globs — so `--dangerously-skip-permissions` does not suppress it. Every subagent work order shaped `cd <worktree> && grep -n <pat> <rel/path>` stalled on an approval prompt in every attached project. `deny` is now `[]` rather than absent: `scripts/tests/doctor.bats` ("portable doctor accepts retained explicit-json values after template changes") pins `["permissions","deny"]` as an owned key and needs the template to keep shipping it, the same way pinning `effortLevel` broke when that key stopped being shipped. Deny rules remain the right tool for paths that would be an incident if read; they are the wrong tool for keeping build output out of context.

## [v1.0.0-rc.47] — 2026-09-03

### Fixed

- **Registries with legacy `omp` rows no longer fail validation.** Every registry row written before rc.46 carries `["claude", "codex", "omp"]`, which the retired-harness schema rejects, so `trellis registry list`, release adopt, and doctor failed with `registry failed schema-aware validation` (exit 4). Registry loads now drop the retired `omp` token from each checkout's `harnesses` with a one-line stderr notice; reads never rewrite the persisted file, and the next registry write persists the normalized form. `local_registry_normalize_harnesses` likewise drops `omp` instead of erroring, so attach, adopt, and annotate succeed on legacy rows. Unknown harness tokens still error as before.

## [v1.0.0-rc.46] — 2026-09-03

### Changed

- **OMP retired, pi is the sole foreman/worker harness.** The supported triad is now `codex` (GPT web-search/computer-use), `pi` (default foreman/worker, GPT and non-GPT), `claude code` (Claude-family). `core-rules/omp` (adapter `trellis.ts`, global `AGENTS/RULES`, `eval-workflow` skill, `deepseek` agent), `core-rules/templates/omp-*.yml`, `hooks/lib/omp-reviewer.sh` and `omp-review-route.bats` are deleted; `code-review-subagent.sh`/`lib/code-reviewer.sh` route cross-family review through `pi -p --no-session … --model $model` with validated `~/.trellis/state/roles-resolved.json`, `herdr-foreman-session.sh` (both harnesses) lists `pi` Herdr agents and uses `~/.trellis/state`; `inheritance-manifest.json` valid harnesses are `claude,codex` (+`user`), `pi` rides the `codex` `.agents` block.

- **GLM-family and DeepSeek-family removed from the roster everywhere.** No ban language — they simply do not appear in any roster, catalog, fixture, or doc. `lane-catalog.json`/`schema.json` lose `glm`/`deepseek` lanes and `openrouter` route classes (remaining 4 routes byte-identical to `config.py` `_CANONICAL_OPENROUTER_ROUTES`); `conductor.wf.js` omits `deepseek` from `AGENT_FAMILIES`; fixtures `herdr-task-routing/exhausted.json` and `usage-federation` scenarios use live `muse`/`luna`/`grok`/`flash`/`sol` agents.

### Added

- **Lane-freshness poller (30 m).** `scripts/lane-freshness.py` GETs OpenUsage `127.0.0.1:6736/v1/limits`, normalizes `remaining` by time-elapsed and `min(session, weekly)`, writes atomically to `~/.trellis/state/lane-availability.json` (`remaining`, `resetsAt`, `utilization`, `fetchedAt`, `errors`; stale >90 m, fail-open never deletes). Scheduled via `scheduled-tasks/lane-freshness` (30 m cadence, materializer-bound) and surfaced as one deterministic `Lane availability: … (age …)` line in `session-context.sh`/`env-echo.sh` for every orchestrator session.

## [v1.0.0-rc.36] — 2026-08-31

### Added

- **Usage Federation schema v5 records pi dispatch acceptance.** Dispatch receipts now admit `harness='pi'`, while immutable `acceptance_records` bind base, head, checker, verdict, and timestamp provenance to the originating dispatch; the private `receipt accept` command writes the relation and a reversible migration preserves existing receipts and bindings.
- **Trellis now runs commit-time git hooks on itself.** `.git/hooks` previously held fourteen `.sample` files and nothing else, so every commit to the repository that authors the process gate was unchecked at the git boundary; the verdict blocks in its own pull requests were real only because an operator ran the scripts by hand. `.husky/commit-msg` and `.husky/pre-commit` fail closed when a required checker is missing or not executable, naming both the path they looked for and the remedy, and `scripts/check-commit-message.sh` validates conventional-commit shape, subject length, and description form. There is deliberately **no** `command -v node` carve-out: the checkers are pure shell apart from `lint-recipe-routing.sh`, which owns its own Node prerequisite, so a blanket guard would have skipped three working checks on a node-less machine and printed a reassuring line — the same silent fail-open these hooks exist to remove. `scripts/install-commit-hooks.sh` prints its resolved destination before any mutation and refuses a destination outside the current worktree unless one is passed explicitly, because `git rev-parse --git-path hooks` resolves to the **main checkout** when run from a linked worktree. `pre-push` is deliberately not installed and `install-commit-hooks.bats` asserts its absence: the managed dispatcher still hardcodes `PATH`, so installing it now would make this checkout unpushable. Both bats suites are hermetic — each hook runs in a temporary pseudo-repository against stubbed binaries, touching no real index — and `TRELLIS_HOOK_SOURCE_ROOT` allows a hook extracted from any revision to be proven against.

- **Usage Federation's committed operator surface is repository-local and CLI-only.** `scripts/trellis usage` forwards argv to `usage-federation.py`; query, refresh, backfill, strip, report, foreground watch, and doctor use on-demand commands only—no resolver integration, HTTP/socket service, daemon, or background collector. `strip --json` is stdout-only, while human strip/report/watch output uses stderr; Ctrl-C from watch returns 130. Visibility and doctor open an existing schema-v4 WAL store read-only and never create, migrate, or fchmod it. Persistent requested-versus-actual dispatch evidence binds only exact normalized Herdr `agent_session.value`/OMP canonical paths or remains unresolved; reconciliation states are `match`, `fallback_promoted`, `mismatch`, `dispatched_unobserved`, `unreported_requested`, and `stale` at the 600-second boundary, separate from spend and headroom. `real_nanos` and `notional_nanos` remain separate observations and are never summed or used to fill each other. Public strip/report/watch output excludes prompts, completions, keys, raw paths, receipt IDs, and session identities; operator-local query/doctor JSON remains private. T35's accepted machine-1 federation p95 is `36.973167 ms` versus immutable OpenUsage command-per-query `52.347458 ms`; the loaded interleaved window was not reproducible and is not the gate. T39/T41 remain gates, OpenUsage has not been stopped, and no completed cutover is claimed.
- **`scripts/check-decisions-log.sh` validates the canonical decisions-log grammar fail-closed.** Its denominator is every meaningful content line, excluding only headings, HTML comments, blank lines, and fenced examples, so timestamp-space, indented-bullet, and asterisk-bullet files cannot disappear into `0 == 0`. Free prose and Markdown table rows intentionally fail; annotations must use a `#` heading, HTML comment, or fenced block. Candidate-versus-valid counting rejects the captured 52/0 total failure and 75/74 unlisted-kind case. Human diagnostics name the first failing component, cap samples at five lines, and end with a verdict-bearing summary; JSON stays exhaustive and identifies its scope as `file`. Missing or empty logs pass with an explicit warning that file validation cannot prove a decisions block appeared in a reply. The optional surfaced audit count treats all-architectural `SUSPICIOUS` as advisory rather than manufacturing an audit claim.

### Fixed

- **Process-gate liveness checks no longer identify work from flattened argv text.** The relayed
  reminder previously embedded the same full-command matcher it asked every session to run, so a
  `herdr agent prompt` containing that reminder reported a gate that did not exist.
  `scripts/check-process-liveness.sh` now anchors on the executing binary, treats exact script/action
  argv as secondary context, deduplicates process groups, and serves both gate coordination and the
  disk-janitor build guard. Live doctrine names the helper instead of copying its matcher, and a tracked
  source guard rejects full-argv process-name and process-table pipelines.
- **Process-gate hooks no longer fail open from linked worktrees.** The native pre-push hook preserves installed project-local runners, then resolves this repository's tracked skill or an attached project's main-checkout skill via Git's common directory; a missing runner now blocks with per-candidate diagnostics. The advisory PR pre-flight hooks use the same two worktree fallbacks.

- **`foreman-start.sh` no longer aborts every dispatch when `TRELLIS_HOME` is unset.** Spec 039's fail-closed
  dispatch-receipt begin calls a CLI that refuses to run without an absolute private `TRELLIS_HOME`, but an
  interactive session does not export one, so every foreman start exited 4 with
  `dispatch receipt begin failed; aborting before agent start`. The script now resolves the home the way the
  rest of Trellis does — explicit env wins, else `$HOME/.trellis` — so the fail-closed path reports real
  receipt failures instead of a missing variable. The regression escaped because every case in the
  `foreman start records before spawn` test pre-set `TRELLIS_HOME`; the suite now also exercises a caller
  environment without it, and its fake receipt CLI mirrors the real one's refusal.

- **Current Claude and OMP transcript records ingest without collapsing every lane to schema error.** Metadata-only Claude prefixes remain behind the durable watermark until real session context is checkpointable, and OMP HTTP 402 failures persist as `payment_required` serving evidence without counting failed-request usage. Redacted current-record fixtures cover both shapes.
- **Delegated prior hooks now retain the caller's hook environment.** Generated dispatchers capture caller `PATH`, `HOME`, and `TMPDIR` before the outer `env -i` boundary; third-party prior hooks receive those values, use the caller temp path for `TMP`/`TEMP`, and can read caller global/system Git configuration instead of inheriting Trellis's Git-config isolation pins. Trellis-owned control payloads remain under their fixed-PATH `env -i` boundary with `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null`, and receive no caller-only values.
- **Managed pre-push gates now receive the attachment's recorded toolchain PATH without weakening control-plane hermeticity.** Attach resolves the caller PATH into ordered canonical directories and persists it through the existing plan, journal, and owner state. The pre-push gate revalidates every recorded directory and names `toolchain moved, re-attach: <entry>` before execution; post-checkout reconciliation and dispatcher generation keep the fixed `/usr/bin:/bin:/usr/sbin:/sbin` PATH.

## [v1.0.0-rc.35] — 2026-08-27

### Added

- **WikiSkill promotion is contract-first and human-landed.** An on-demand pattern catalog, explicit `wiki-maintain` and `wiki-skill-propose` skills, stdlib validators, an eight-column impact ledger with exact nine-field sidecars, strict accepted-best evaluation, durable rejection history, and paired advisory hooks now cover proposal preparation without granting any validator, hook, or skill commit, push, PR, merge, release, or user-global authority.

### Changed

- **Herdr routing now uses GLM-5.3 Flash through `glm-flash-go` then prepaid `glm-flash`.** The roster, resolver, and fixtures share the `zai` family; prepaid no-report availability is explicit and display-only.

### Fixed

- **Managed attachment excludes tolerate foreign bytes outside Trellis's block.** Verification and doctor now authorize exactly one byte-identical managed block from `managed_block_sha256`; whole-file drift is advisory, detach removes only the managed block, and foreign lines such as Claude Code's runtime excludes survive.
- **Hook-authority refusals name the repair.** When an enabled attachment loses `core.hooksPath` ownership, detach and doctor report the current value, the managed dispatcher, and the exact `git -C <root> config core.hooksPath <managed>` remedy without auto-repairing.

## [v1.0.0-rc.34] — 2026-08-27

### Fixed

- **Measured rc.32-to-rc.33 defect:** rc.32-managed dispatcher verification under the rc.33 CLI broke detach and recovery because commit `10dd211e` changed the dispatcher common body; recorded-release generators now remain authoritative for their dispatcher bytes, and phase-3 restore recovery finalizes.

## [v1.0.0-rc.33] — 2026-08-26

### Fixed

- **Default cross-family verdict routing now derives the implementer's family instead of waiting to be told.** Before the cause fix, the refuter and implementer chains both led with the same three stealth routes (then `ox-alpha/openrouter`, `ox-alpha-go/opencode-go`, and `ox-alpha-zen/opencode-zen`, all `families.stealth`), and `resolve()`'s cross-family filter fired only when the caller passed `--implementer` — so on the default roster the refuter was the implementer's own family by construction: reproduced on the 0bffd6f module, a default call resolved implementer=`ox-alpha` (stealth) + refuter=`ox-alpha-go` (stealth), same-family, while the identical chain only diverged when told (`--implementer ox-alpha` → refuter=`cheap`, trail `ox-alpha-go:same-family`). Six earlier commits widened the detector/refusal/panel surfaces (`family_collapse`, unmapped-agent refusals, `--panel`) but did not remove this default construction. The final fix (fa7b7d8) resolves the implementer first in a filter-off pre-pass and constrains the verdict roles {reviewer, security_reviewer, merge_reviewer, refuter} against the family it actually landed on; the same default call now resolves refuter=`cheap` (meta), cross-family, with the `ox-alpha-go:same-family` trail applied without any flag. An explicit `--implementer` still wins; a derived implementer missing from the central `agents` catalog deliberately leaves the filter off so `family_collapse()` reports it rather than breaking the default path (ruling at `decisions-log.md:355`).

- **Collapse and unmapped-roster failures are findings and refusals, not silent skips.** `family_collapse()` inspects the *resolved* roster — each verdict role against the default producer's family, plus a reviewer==security_reviewer check — and emits `FAMILY COLLAPSE` stderr findings and a `family_collapse` JSON key, reporting rather than repairing and scoped to the default producer so by-design pairings don't warn always-on; the checked verdict tuple includes `reviewer`, `security_reviewer`, `merge_reviewer`, and `refuter`. An agent absent from the central `agents` catalog is no longer skipped: a seat with no catalog entry becomes an explicit finding ("collapse cannot be checked for it"), and an explicitly named `--implementer` missing from `cfg['agents']` raises `SystemExit` instead of short-circuiting `impl_fam=None` into skipping the filter for every candidate. Provider-exhaustion limits are scoped to the model they govern, removing the unscoped-limit failure mode that first collapsed a whole roster. Measured: synthetic all-`xai` roster → four findings including the refuter seat; healthy resolved roster → `[]`; unmapped refuter seat → "refuter agent 'nous-stealth' has no entry in agents"; `provider_state` returns 0.41/`reported` for `gpt-5.6-sol` under Spark's exhausted scoped window where the 0bffd6f code returned 0.0/`exhausted:spark5h`.

- **Verdict-role degradation routes to the Claude apex — an instruction, never a substitution.** With OpenAI at 11% and xAI at 5% (measured 2026-08-23), both review seats fall below `min_remaining` and the only remaining candidates are the implementer's own family, so the honest roster is DEGRADED for verdict roles. `main()` now reads `claude_roles.claude_reviewer` from roles.json and prints the route (`route <roles> to the Claude apex: feature-dev:code-reviewer subagent: second-family review when implementer was OpenAI/xai/stealth`) plus `Do NOT accept a verdict from a degraded roster instead`; the resolver still emits `DEGRADED` and never fills a verdict seat itself, and the JSON output gains `degraded_verdict_roles` so `--json` consumers can join the route. Doctrine at `SKILL.md:79`, ruling at `decisions-log.md:356`.

- **The newly governed OMP policy template and executable Herdr roster stay private in the public mirror.** `skills/herdr-foreman` is excluded and exactly paired in `delist_prune`, so stale published copies are removed during simulation and `--apply`; `core-rules/templates/omp-project-policy.yml` is likewise governed but excluded through `payload_no_publish`. The earlier roster contained six OpenRouter selectors; the current max-only routing cutover removes them, while the subtree remains private because provider routing is operator-specific. Publication lint now permits the exact live `google-antigravity` provider identifier while still rejecting bare, noncanonical-case, embedded, and mixed-line retired AntiGravity-harness references. Executable preflights enforce both prune pairings and safe path validation; 26/26 mirror-lint and 18/18 publication Bats cover provider-token discrimination, no-mutation refusal, and stale-subtree removal.

- **A qualified analyze PASS is a PASS again.** `check-analyze.sh`'s whitespace-stripping normalizer turned `## Verdict: PASS (1 warning)` into the literal `PASS(1WARNING)`, which matched no case arm and fell through to "no recognizable '## Verdict:' line" → warn (exit 2). The parser now accepts `PASS|PASS\(*`; `NEEDS-REVISION`/`BLOCKED` stay exact-match by decision (no qualified form exists; loosening would admit typos), and the advisory invariant holds — the gate exits 0 or 2, never 1. 20/20 `check-analyze.bats`, including the four new qualified-verdict cases (qualified pass exit 0, multi-word qualifier exit 0, qualified NEEDS-REVISION still warn).

- **The managed pre-push dispatcher forwards `TRELLIS_ALLOW_MAIN_PUSH` / `SECURITY_GATE_SKIP`.** Hermetic `env -i` in `_attachment_hooks_dispatcher_common_body` and `trellis_run_managed_payload` dropped the operator environment, making the documented overrides (`core-rules/githooks/pre-push:47`, `check-security-diff.sh:26`) unreachable — the parent commit contained zero occurrences of either name. The generated dispatcher now allowlist-forwards both via `${VAR-}` (empty-if-unset, expanded before the wipe) through the outer `exec env -i` and the managed-payload `env -i`, exports them in the body without `readonly`, keeps `trellis_run_prior_hook` closed, and preserves `HOME=/dev/null` hermeticity. 10/10 `managed-dispatcher-env.bats` (new 228-line suite): child visibility, unset-no-spurious-value, hostile `BASH_ENV`/`CONTEXT_POISON`/`EVIL` stripping, pinned PATH.
- **Deterministic routing now prevents the cheap→DeepSeek fallback incident.** A central catalog and finite task-shape classifier keep an explicit `cheap`/Muse request exact, permit only capability/family-safe pre-dispatch fallback, and require an observed actual-model+effort receipt; generic model/usage-aware fallback and the task→DeepSeek chain are removed. Regression coverage verifies exact cheap resolution and rejects observed `opencode-go/deepseek-v4-flash:max` with `runtime_match=false` (the incident returned 401).
- **The full local merge gate no longer serializes the repository battery into a two-to-three-hour run.** `scripts/run-tests-local.py` drives all 72 pre-existing stages plus the new regression stage (73 total; none removed) through four concurrent `run-tests.sh --scope=local --shard=I/4` processes, isolates their output and timing receipts, replays output deterministically, merges one aggregate TSV, and terminates every shard process group at a 3,600-second wall-clock deadline. Direct `run-tests.sh` invocations now write private temporary timing receipts instead of dirtying the checked-in baseline. 10/10 wrapper Bats and 6/6 suite-coverage Bats verify failure propagation, timeout and signal cleanup, complete four-way partitioning, and no coverage reduction; final full-battery wall time is measured during the release gate rather than predicted. Round-robin was measured unbalanced (shard 1 approximately 5,000 s versus ideal 2,343 s) and was replaced by weight-balanced LPT over a checked-in table.

### Added

- **`resolve-roles.py --panel A,B,C` counts distinct families, not seats, and refuses collapsed or unmappable panels.** A multi-seat panel was a shape `family_collapse` could not see — three refuter seats are three names in a role with room for one. `panel_families()` counts only seats with an exact central `agents` catalog entry, prints `panel: N seats -> M distinct families`, names collapsing and unmappable seats on stderr, and exits 1 on any finding so a foreman cannot bank "3/3 agreed" from a pipeline that ignored the warning; it reads only roles.json and short-circuits before `load_usage` (fully offline). Measured: `--panel cheap,ox-alpha-go,ox-alpha` → 3 seats → 2 distinct families, exit 1 (both stealth seats share one prior); `--panel cheap,flash,deepseek` → 3 distinct families, exit 0; an unmapped seat is a finding, never counted.

### Changed

- **Ox Alpha routing is max-only and excludes OpenRouter.** Automatic roles now use the real OMP agent names for Nous Portal (`ox-alpha`), OpenCode Go (`ox-alpha-go`), and OpenCode Zen (`ox-alpha-zen`); every selector ends in `:max`. OpenCode's official Zen model list and OMP's registry both identify `x-preview-f-free` as Ox Alpha Free. OpenRouter is removed from all role chains because its measured 68% hard-failure rate and `xhigh` ceiling violate the reliability and max-effort invariants.

- **Authorized spec backlog closed: exactly eight specs zeroed with honest receipts, 037 explicitly left open.** The wave spans two commits: f95cd3e closed the verified 014/017/034 trio with receipts; 7cac890 zeroed every task row in exactly 001, 005, 006, 008, 011, 012, 016, and 035-repository-debloat (open rows 0/66, 0/5, 0/32, 0/16, 0/33, 0/24, 0/22, 0/13). Closure statuses mix satisfaction receipts, obsolete dispositions, and operator-recorded `closed_with_shortfall` rulings where a green receipt never existed — 001 reconciled 17 rows (14 satisfied + 3 obsolete, receipts at 0f6bd698/05fec4e2/2d44cb4f); 006 certified deployment (merge 83d7e888, sync 7daf0e73, tag 070ac65, fleet 9/9, manifest-hook 81/81) while its historical gate stayed 7/8 NEEDS CHANGES; 011 Phase B closed-with-shortfall at D7 expiry; 035 ships `specs/035-repository-debloat/dod-receipt.json` with `closure.status: closed_with_shortfall` and `green_claim: false`. 037 is deliberately NOT closed: `specs/037-anti-slop/analyze-2.md` flipped PASS → NEEDS-REVISION, T18 stays open (`specs/037-anti-slop/tasks.md`) — the mirror stages from the sealed release commit (d48ce986), so no mirror-clean receipt exists until rc.33 is sealed ("a merge is not a rollout"), and no green mirror receipt is claimed; the anti-slop doctrine also hardened to report only verified counts and state thresholds as thresholds. Gate: 213/213 serial changed-contract Bats plus a cross-family deciding review (`decisions-log.md:352`). A full-suite follow-up corrected the routing tripwire from 12 to the measured 14 inherited `agent()` sites after 7cac890 added two conductor sites; 13 still fails, keeping additions deliberate.

- **Shell-lint carves `.claude/worktrees/*` out of its tree scan; the worktree triage inventory ships alongside.** `shell_tree_files()` appends `-not -path '.claude/worktrees/*'` to both finds — the `*.sh`/`*.bash` suffix pass and the extensionless-shebang pass — so detached worktrees (21 `wf_*` trees, ~3400 shell files as of 2026-08-19) can no longer poison or floor the process-gate shellcheck, while `.claude/skills`, hooks, and settings remain linted: a precise carve-out, not a wholesale `.claude` drop. 7/7 `shell-lint-tree.bats`: planted `wf_fake` defects in all three shapes are absent from the tree list and a real SC2034 under `wf_fake` leaves the run at status 0, while a planted `.claude/skills` file stays listed. `audits/2026-08-19-wf-worktree-triage.md` inventories all 21 trees (path/branch/dirty/last-commit/action); no trees deleted.

- **Release adoption now treats explicit JSON ownership as key-scoped.** Unowned local keys survive, missing or drifted owned keys are restored to their recorded attachment values, and absent or invalid target files fail closed with a named reason instead of disappearing into comparator failure.
- **Bulk release and doctor failures reach the caller.** Eligible adoption failures determine the final exit class while unavailable inventory rows remain report-only when an eligible target exists, and `doctor` summary errors now return nonzero.
- **Attachment upgrades preserve operator hook authority.** Managed hook payloads can advance without replacing an operator-owned `core.hooksPath`.
- **Legacy fleet migration preserves private routing transactionally.** Top-level `gptx` state is retained through the supported migration path, rollback metadata is integrity-checked, and file identity/link-count probes use the host platform's `stat` dialect.

### Added

- **Release-owned user orchestration surface (spec 038).** `attach`, `detach`, `relink`, and `configure` operate from immutable releases with exact rollback.
- **Persistent fan-out system prompt (spec 038).** Claude Code selects the release-owned `Trellis Orchestration` output style; the OMP adapter appends the same body through `before_agent_start`, with explicit inline guards.

### Changed

- **`doctor` coverage.** Detects user-surface drift and missing inheritance leaves.
- **Resolver hardening.** Scoped-away quota remains unknown instead of fabricated as 100%; the refuter now exposes three executable, pairwise-independent seats or marks the roster `DEGRADED`.

### Fixed

- **OMP Stop reviews are non-Anthropic.**
- **Security-gate model routing.** Non-Anthropic providers require an explicit model, and `local.config.sh` provider/model values now reach child tools and audit provenance.
- **Independent workflow review.** Digest triage uses a separate skeptical verifier; conductor auto-spec/review/execute stages require explicit distinct-family routing or return `DEGRADED/HOLD`.

## [v1.0.0-rc.32] — 2026-08-23

### Fixed

- **Silent model misroute promoted cheap legs to the session model.** The `herdr-foreman` `scout` role pointed at `google/gemini-3.7-flash:high`, but no `google` credential exists — only `google-antigravity`. Standalone the route hard-errors; inside an OMP `eval` the retry layer catches it and promotes the leg to the **session model**, the priciest route in the roster. Three read-only scan legs cost $12.15 on Sol; the same class of work correctly routed cost $0.91. `resolve-roles.py` now rejects any chain row failing `model.startswith(provider + "/")`, in both the selection and overflow passes, so the role walks down its declared chain instead of sideways onto the expensive route.
- **GPT-5.6 ran on the 1M premium context window.** OpenAI bills requests over 272K input tokens at 2x input and 1.5x output for the *entire* request. `extendedContext: false` caps exactly the models with a premium tier — measured across all 44 enabled selectors, only `openai-codex/gpt-5.6-{sol,luna,terra}` change (1,000,000 → 272,000); Grok, Muse, Gemini and the flat-rate `github-copilot` variants are untouched.

### Added

- **`doctor` reports missing inheritance leaves and `core.hooksPath` drift** (spec 038 Phase A). Health checks expand the manifest through the project runtime payload's own surface planner and emit every missing skill/command/agent leaf; an `HC_ERROR` row precedes repair eligibility with a detach-then-attach remedy. The hooks-path row compares the exact local value against the verified checkout state, exiting 3 on conflict with no repair attempted.
- **Spec 038 triad** — user-global orchestration inheritance: spec, plan, 31-task breakdown, and three executable checks.
- **Foreman panes fill a 2x2 grid before opening a new tab.** `foreman-start.sh` splits the caller's tab up to four panes and only then creates a tab; targets derive from `herdr pane layout` geometry rather than list order, which is preorder and produced a column. `--tab <label>` remains an explicit override.
- **Specs 005 and 016 operational follow-ups.** Claude and Codex now register paired advisory `pr-gate-shiftleft` (`PreToolUse(Bash)` on `gh pr create`) and `primer-capture-nudge` (edit-heavy `Stop`) hooks across direct and portable-inheritance settings. The schema-backed conductor ceiling remains absent/0 default-off, and L5-only rule proposal persistence is paired across both harnesses. Disk-janitor configuration materializes the operator's report-tuned 50-worktree/100-GB tripwires while the portable template stays default-safe at 25/80; phantom `/sessions`/`/tmp` registrations are eligible only when one exact canonical path is absent, non-main, Git-prunable, registry-owned, and conclusively inactive, then removed with exact `git worktree remove`—never broad prune.

### Changed

- **Pane teardown is per-pane at acceptance**, not batched at the end of a workstream, with reviewers closed before a judge starts (the judge reads their report files, not their sessions). Acceptance means the artifact is on disk and the receipt was re-run — a worker's self-report is never acceptance.
- **Two runtime-verification rules.** A leg whose *resolved* model differs from the requested one is discarded and re-run: the provider/model invariant checks configuration, and only reading the resolved model catches a stale payload, a session-bound override, or a retry promotion. And a knowingly-failing committed test is never an acceptable outcome — a delegated test-migration unit must be told that deleting a spec for a deleted feature is allowed, because language-level gates do not execute Playwright and a green pipeline then proves only that nothing ran.
- **`delegation.md`: a fact in a message decays; a check in a skill does not.** When a finding would change how a future session behaves, the deliverable is the check, not the message.

### Removed

- **cmux tooling** (504 lines): `scripts/cmux-trellis-teams`, its bats suite, `scripts/rollout-omp-cmux.sh`, and `core-rules/templates/cmux.json.example`. The fleet runs Herdr + Ghostty. Historical references under `audits/`, `specs/` and this changelog are deliberately retained.

### Fixed

- **Managed pre-push dispatcher now forwards TRELLIS_ALLOW_MAIN_PUSH / SECURITY_GATE_SKIP.** Hermetic `env -i` in `scripts/lib/attachment.sh:_attachment_hooks_dispatcher_common_body` (~533-563) and `trellis_run_managed_payload` (~926-939) dropped the operator environment, making documented `TRELLIS_ALLOW_MAIN_PUSH=1` (`core-rules/githooks/pre-push:47`) and `SECURITY_GATE_SKIP=1` (`core-rules/skills/process-gate/scripts/check-security-diff.sh:26`) unreachable. The generated dispatcher now allowlist-forwards `TRELLIS_ALLOW_MAIN_PUSH=${TRELLIS_ALLOW_MAIN_PUSH-}` and `SECURITY_GATE_SKIP=${SECURITY_GATE_SKIP-}` through the outer `exec env -i` and the managed-payload `env -i` (empty-if-unset), exports them in the body without `readonly`, and keeps `trellis_run_prior_hook` closed and `HOME=/dev/null`. Fixes #291.

- **Attachment-migration rollout gaps.** `migrate-project.sh` no longer refuses a project whose `AGENTS.md` is an authored, project-owned file — it is skipped (never entering the snapshot plan), while byte-copies and owned symlinks keep their removal classification, with copy-comparison authority now mirroring the symlink policy exactly. `check-bypass.sh` recognizes hook registration in `.claude/settings.local.json` (the portable-attachment home) as well as `.claude/settings.json`, so attached projects' pushes no longer fail the Bypass-markers row; an empty `"hooks": {}` still does not count.

### Added

- **Herdr foreman lane (multi-model orchestration inside Herdr).** New skill `core-rules/skills/herdr-foreman` (expanded to `.claude/skills` and `.omp/skills`): Claude is the apex (briefs, git, executed receipts, acceptance); one OMP foreman pane per worktree drives `eval` workers; roles (`foreman`, `implementer`, `hard_implementer`, `scout`, `reviewer`, `security_reviewer`, `refuter`) resolve from live `omp usage --json` against ordered fallback chains in `roles.json` (`scripts/resolve-roles.py`, 10-min cache, `--implementer` enforces cross-family review, `DEGRADED` surfaced rather than substituted). `scripts/foreman-start.sh` splits a pane with the worktree as cwd and starts OMP on the resolved foreman model; `templates/HANDOFF.md` is the session-survivable brief. Rules in `core-rules/references/herdr-foreman.md`, pointer in `model-lanes.md` (core `CLAUDE.md` is at its byte ceiling). Machine-level pieces stay outside the release by design: the `HERDR_ENV`-gated SessionStart hook in `~/.claude/settings.json` and the OMP foreman contract plus `grok`/`security-reviewer` agents under `~/.omp/agent/`.
- **Anti-slop: evidence-based code doctrine for every fleet language (spec 037).** A language-neutral six-principle doctrine (`core-rules/references/anti-slop.md`) rejecting code that fabricates, obscures, or discards type/contract evidence, adapted from [dmmulroy/anti-slop](https://github.com/dmmulroy/anti-slop) (MIT, vendored per upstream intent). Ships three enforcement layers: generation-time (CLAUDE.md pointer + reviewer **Evidence** axis), turn-time (`slop-tripwire.sh`, an advisory PostToolUse hook over the shared `hooks/lib/slop-patterns.sh` pattern/carve-out contract — never blocks), and gate-time (process-gate row 9 `check-slop.sh`, driven by `.trellis.json` `gate_profiles.anti_slop.posture: off|advisory|enforced`, diff-scoped, native lanes narrowed to profile rules only). Profiles: TypeScript (vendored Oxlint plugin, oxlint 1.78.0 pinned), Python (ruff/mypy ownership split), Go and Rust as dormant fixture-validated templates. `skills/anti-slop/scripts/audit-slop.sh` provides the repo-scoped audit mode consumed by per-project de-slop sessions; doctor gains an info-class presence row.

- **Forward-only high-autonomy decision receipts (GOV-01).** Substantive L4/L5 Stop events now require a canonical `## Decisions made (L<n>)` block whose current-turn entries match the effective autonomy level and exist verbatim in canonical-root `decisions-log.md`; architectural entries must carry `SURFACED INLINE`. Claude Code, Codex, and OMP share one validator core, while L1-L3, clean read-only turns, and all legacy decision-log bytes remain unchanged.
- **Shared local-development infrastructure contract (spec 023).** Trellis now supports an optional configured shared-infra root. When present, it requires registry/manifest parity for every active project (including explicit `services: {}` declarations), coordinates review-gated infrastructure registration through `./scripts/onboard-project.sh --infra-entry`, seeds fixed-port startup preflight, and extends the read-only `./scripts/doctor.sh` surface with shared path, allocation, registry-parity, and port checks.
- Operator documentation for the shared-infrastructure ownership boundary, the external repository contract, onboarding, verification, and recovery.
- **Canonical-clone hygiene policy.** The canonical clone is a published surface, not a workspace: every registered project resolves rules, skills, and hooks through absolute paths into it, so its branch and dirty state are inherited live by all of them. Codifies clean-`main`-only, work-in-worktrees, and makes an off-main or dirty canonical clone a **stop-and-fix condition agents act on unprompted**, with a verified recovery procedure (WIP commit over `git stash`, park in a worktree, `git reset HEAD~1` to restore exact prior state). `trellis-doctor` Tier 0 already checked all three conditions; this makes the response to a Tier 0 failure explicit and blocking rather than advisory. Full procedure in `core-rules/inheritance.md`; one-line pointer in `core-rules/CLAUDE.md`.
- **Native `commit-msg` hook (`core-rules/githooks/commit-msg`).** Validates the conventional-commit header in POSIX `sh` with no Node dependency. Closes a silent hole that was far wider than "non-Node projects": the husky variant shelled out to `./node_modules/.bin/commitlint` and printed `skipping` when absent, and a fleet check found commitlint installed in only **2 of 7** registered projects — so the hook reported success while checking nothing almost everywhere. Both canonical variants now run the native check; husky's still prefers commitlint where it genuinely exists. Header-only by design (type, optional scope, optional `!`, non-empty description, ≤100 chars, no trailing period); merge/revert/fixup/squash/amend headers pass untouched. 15 cases verified. **Projects carrying the old copy keep skipping until they re-seed** — `onboard-project.sh` never overwrites an existing file.
- **Native Oh My Pi (OMP) harness support.** `harnesses` now accepts `"omp"` as the third native value; the private control plane enables `["claude", "codex", "omp"]`. OMP-enabled projects receive exactly five absolute, machine-local, gitignored live links: `.omp/AGENTS.md → <project>/CLAUDE.md`, `.omp/skills → <trellis_root>/core-rules/skills`, `.omp/commands → <trellis_root>/core-rules/commands`, `.omp/agents → <trellis_root>/core-rules/agents`, and `.omp/hooks → <trellis_root>/core-rules/omp/hooks`. The adapter resolves and invokes canonical hooks at runtime, restores project/preset policy for task children, and fails doctor loudly on broken inheritance. The OMP branch is additive and never rewrites Claude Code or Codex surfaces; without `"omp"`, onboarding and doctor impose no `.omp` dependency. Fresh sessions (or an explicit discovery reset/process restart) see canonical changes; there is no full in-process hot reload.

### Removed

- **GPTX-era custom agents.** `codex-worker`, `lane-worker`, `fable-advisor`, and `opus-advisor` are removed from canonical inheritance and active routing. OMP uses only its bundled agents; historical release notes remain below.
- **Retired Codex worker integration.** The unaccepted `codex-worker`, fan-out/recipe preflight, handoff, and probe surfaces are removed; direct CLI, explicitly selected plugin commands, and plugin hook PATH health remain supported.
- **Completed one-off workflow executors.** Five audit and Redis migration runners are removed after their plans retain the completed evidence.

### Deferred

- `native-mobile` security-gate profile (the Swift project, n=1) — the canonical list is entirely web- or game-shaped, and `guess_profile()` proposes `web-next` for a Swift package with no web surface.
- Gated-diff exclusion globs miss Swift test files (the Swift project, n=1) — `FooTests.swift` matches none of `*_test.*`, `*.test.*`, `*.spec.*`, `*.bats`, so the whole `Tests/` tree counts toward `spec_required_diff_lines`. Python and Kotlin conventions miss too; worth one deliberate pass rather than a glob per language as each trips over it. Effect is conservative — more work routed through specs, never less.

### Changed

- **OSV severity normalization is per vulnerability again.** The security-gate adapter now reads OSV-Scanner 2.x package groups, matches each authoritative group score to its vulnerability IDs, and falls back to ecosystem-provided CRITICAL/HIGH/MODERATE/LOW labels when no valid group score exists. CVSS 3 and CVSS 4 scores therefore reach the baseline summary at their real severity without one group's score leaking into another finding; records with no usable severity retain the conservative medium fallback.
- Local applications remain native on macOS; Docker owns shared or project-specific infrastructure only. Project shutdown may stop only project-owned infrastructure and native process helpers, never the shared Compose project.
- Shared-service provisioning is declarative and idempotent on every start rather than first-volume-only. Static onboarding discovery produces evidence and a reviewable proposal but cannot execute project code, read secret values, choose credentials/allocations silently, or mutate the manifest before explicit review.
- The current eleven-project manifest includes `the Flutter monorepo` with `services: {}` and `ports: {}`. Five Vite preview listeners are registered while default `4173` remains deliberately unallocated; the RAG service's evaluation endpoint is `18003`, the monorepo project's native worker health endpoint is `23080`, and the static Astro site's project-owned migration MariaDB is registered on `3307`.
- Infrastructure publication now requires dependency-ordered repository receipts: scoped commit, local gates, PR, merge SHA, and synchronized local `main`.
- **Local-state ignore policy.** Replaced blanket tracked `.claude/` hiding with explicit runtime paths while retaining the canonical clone's intentional machine-local `.claude/` exclusion. The onboarding contract now states that its managed block contains machine-specific symlinks plus the fixed 24-path runtime inventory; other project state remains tracked.

### Fixed

- **The public mirror no longer publishes local fleet identity, and cannot again.** A payload every existing check certified clean carried 80 project-name references and 13 routable IPv4 literals, including an ADR with the production hostname table, an origin IP, and a Cloudflare tunnel id. `lint_mirror` gains two rejections: any local fleet project identifier, and any routable IP literal (private, loopback, link-local and the three RFC 5737 documentation ranges stay allowed). The identifier token set is **read from the machine-local registry, never hardcoded** — a hardcoded list would publish inside the lint the names it exists to suppress, and would go stale on the next onboard — and the check **fails closed** when that state cannot be read. It grants no historical-record exemption for `docs/adr/`, `docs/specs/` or `CHANGELOG.md`, because narrative prose written long after an allowlist decision is exactly where the names accumulated unnoticed. The registry is parsed with `grep`/`sed` rather than `jq`, since `trellis mirror` re-execs through `env -i` with a minimal PATH where a jq-dependent guard would resolve "unreadable" on every real publish. A failed symlink check no longer returns early, so one unresolvable link can no longer short-circuit every content check below it. The retired `registry.md`/`blacklist.md`, `recon.md`, and the hosting ADR are now pruned from any existing mirror rather than left as stale published copies.

- **The mirror identity guard no longer flags an identifier that is already public.** The token set is derived from the machine-local registry, so a project whose id *is* a public domain — a personal site — was reported as a fleet-identity leak wherever the mirror's own README linked to it or used it in the maintainer byline. The mirror could not be certified, and the only two ways out were deleting the byline or deleting the check. A registry row may now carry `metadata.public_identity: true`, set with `trellis registry annotate --metadata-json '{"public_identity": true}'`, and the guard subtracts those identifiers from its token set. The declaration stays machine-local for the same reason the token set is read rather than hardcoded: an allowlist written into the lint would publish, in the mirror, a list of the operator's projects. **Default is closed** — a row that says nothing is private, so nothing can be exempted by omission. The annotation frees only the row it is set on. Parsing keys on the writer's `jq -S` indentation rather than brace depth, because `metadata.legacy` notes carry literal braces inside JSON strings; a source whose shape does not match yields no exemptions, so a format change fails toward flagging more rather than fewer.

- **`trellis mirror --push` can see the SSH agent socket on a stock macOS.** Both the launcher's resolver and the mirror body's re-derivation compared the socket's canonicalised parent against the raw `SSH_AUTH_SOCK` string. Stock macOS spells the launchd agent socket `/var/run/com.apple.launchd.*/Listeners` and `/var` is a symlink to `/private/var`, so the two spellings never matched, the launcher exported an empty marker, and `--push` refused with `requires a verified SSH agent socket` on every default macOS setup — a socket that was there the whole time. Both sites now canonicalise the path and re-assert the safety properties on the canonical form: it must still be a socket, must not be a symlink, and must name the same file (`-ef`) as the path the caller supplied, so only the *spelling* may differ. What is exported and pushed with is the physical path, which is strictly harder to swap under than the raw one it replaces. A socket that is itself a symlink, a non-socket path, and an unclean path (`.`, `..`, `//`) are all still refused.
- **Disk janitor external worktree reaping.** Recoverable linked worktrees registered outside `projects_root` now reap through Git's worktree registry, while the manual `rm -rf` fallback remains restricted to project and temporary roots. Apply summaries now count only successful removals instead of repeating planned bytes after a refusal.
- **August fleet audit remediation.** Hardened dependency and test-health schedules, canonical hook synchronization, pinned Python tool selection, provider-lane failure handling, dependency coverage/disposition controls, and conductor spec-collision verification. Added immutable live OSV and macOS fleet-test evidence under spec 035; project dependency and launch changes remain isolated in their own review branches.
- **OMP/Cmux rollout options.** Removed the advertised `--yes` flag because the rollout has no interactive prompt; the no-op parser state also caused the repository-wide ShellCheck job to fail with SC2034.
- **Mirror lint no longer fails open on a glob-metacharacter mirror path.** `lint_mirror` interpolated the mirror's absolute path directly into every `find -path` pattern, where `*`, `?`, `[`, `]` and `\` are glob syntax rather than literals. A linted directory whose own path contained one of those characters therefore matched no reject term at all: the entire structural private-state scan, the `.git` traversal prunes, and the symlink validation silently passed over a dirty mirror. The root is now escaped once per call and the escaped form used in every pattern, with a fixture linting a bracketed directory name.
- **`trellis show-config` now refuses direct source execution on the same attestation basis as `release`, `upgrade`, and `mirror`.** Its gate was identity-based — it refused only when a consulted machine config named that copy as its `source_root`, and allowed whenever no config answered. That question is undecidable for a copy of the source tree, a git worktree of it, an unpacked tarball, or a clone at a path no config names, so each of those rendered validated local machine state from an unverified copy. The gate now requires the stable launcher's verified payload attestation and refuses otherwise, with no config consulted at all. The gate also runs before argument parsing, as its three siblings do: `show-config.sh -h` previously reached the parser first and exited 0 with usage text out of a copy the launcher had never attested. Only the launcher route changes behaviour for operators; `trellis show-config` through the installed launcher is unaffected.
- **Release-snapshot payload binding no longer accepts a foreign release's execution snapshot.** `sync-to-template.sh` matched the sealed snapshot name with a prefix glob plus a greedy `##*.exec.` strip, so `.tmp.1.2.3.exec.9.exec.SUFFIX` — the snapshot of a release legitimately named `1.2.3.exec.9` — was accepted under a `1.2.3` attestation. The predicate now strips the version delimiters literally at all six sites — the five direct-source gates (`show-config.sh`, the `upgrade.sh` body, both the bootstrap and body of `sync-to-template.sh`, and the launcher body) plus `scripts/lib/release-store.sh`, which carries its own copy because its stated contract is to depend on nothing above `semver.sh` — against one normative definition in `scripts/lib/trellis-home.sh` that `scripts/tests/release-snapshot-predicate.bats` pins all six to. Two name gates took only a name and carried the same greedy strip: `launcher_snapshot_name_is_safe` guarded snapshot creation, copy, bundle emission, and cleanup, and `release_store_snapshot_name_is_safe` guarded snapshot creation, cleanup, and verified attachment-bundle emission — so each accepted a foreign release's snapshot name everywhere it was consulted. Both now take the release store and version and delegate the parse to their pinned copy of the predicate, and `release_store_remove_snapshot` and `release_store_emit_verified_attachment_bundle` take the release version as a required argument so the caller cannot leave the binding unstated.

## [v1.0.0-rc.25] — 2026-08-16

Portable multi-fleet **cutover release** (spec 036, T32). It completes the two-release
rollout begun in `v1.0.0-rc.24`: the compatibility layer that let the tracked control
plane and the machine-local one coexist is withdrawn. Roll back by explicitly adopting
`1.0.0-rc.24` per fleet and restoring the snapshotted local state — see
[`docs/UPGRADING.md`](docs/UPGRADING.md) and [`docs/MIGRATING-LOCAL-FLEETS.md`](docs/MIGRATING-LOCAL-FLEETS.md).

### Changed

- **The machine-local registry is the only fleet inventory.** `trellis registry list` /
  `doctor` / `show-config` are the roster; `trellis registry rebuild --fleet NAME ROOT...`
  reconstructs it from tracked `.trellis.json` manifests under operator-selected roots.
  Documentation, evals, skills, recipes, and the architecture diagram that still named the
  tracked files were repointed at the local registry.
- **Scheduled-task inputs are materialized, not tracked.** `trellis task materialize`
  renders `registry.md`, `blacklist.md`, and `aeo-targets.md` into
  `$TRELLIS_HOME/tasks/<fleet>/<task>/` from one strict local-registry snapshot. Those
  filenames now denote materialized private inputs only; the `aeo-gate` skill's fleet
  command documents the materialized paths.
- **`doctor` diagnoses legacy checkouts instead of repairing them.** Both the portable
  layout classifier (`compatibility-legacy`, `mixed/conflict`) and the explicit
  `TRELLIS_CONFIG` legacy mode still recognize a pre-cutover checkout and name
  `trellis migrate --prepare` as its path. `--fix` no longer seeds direct links,
  re-onboards, or mirrors worktree symlinks; every such row is reported `[manual]`.

### Deprecated

- **Project-local `.trellis.config.json`.** `.trellis.json` is the canonical portable
  project manifest. The old filename remains a read-only fallback in the autonomy,
  package-manager, spec-gate, and process-gate resolvers, retained past cutover solely
  for checkouts explicitly held on the legacy layout; `doctor` reports every such
  checkout and `trellis migrate --prepare` replaces the file. It is removed once no held
  row remains.

### Removed

- **Tracked `registry.md` and `blacklist.md`.** There is no tracked fleet inventory,
  audit roster, or exclusion list. `trellis registry import --registry FILE
  [--blacklist FILE]` still reads a Markdown roster, but only one the operator supplies
  — recover it with `git show <pre-cutover-sha>:registry.md` — and it is no longer a
  repository path. `conformance-check.sh` drops both from its scanned spec-doc and
  single-file sets, and `trellis.config.json` drops them from `template.redact_paths`.
- **Legacy direct-link onboarding.** `onboard-project.sh --legacy` / `--compatibility`
  (and with it `--legacy-relative` and `--infra-entry`) now refuses with exit 2 and names
  `trellis migrate --prepare` followed by `trellis attach`. Nothing in Trellis creates an
  absolute direct link into a mutable source checkout any more. The shared-infrastructure
  `--infra-entry` registration lived only inside that writer and is withdrawn with it;
  re-hosting it on the portable path is the separate reviewed shared-infra PR the plan
  sequences (`plan.md` §4.4 row 73).
- **Legacy worktree mirroring.** `seed-inheritance-symlinks.sh --legacy-mirror` and its
  `--root` spelling refuse with exit 2. The unflagged command reconciles a linked
  worktree from its clone's registration and recorded immutable release, and an
  unregistered clone stays inert.
- **`TRELLIS_ROOT` as a compatibility input.** `config-load.sh` no longer exports the
  source root under that name; callers read `TRELLIS_SOURCE_ROOT`. `TRELLIS_ROOT` keeps
  exactly one meaning: the per-project `.trellis/runtime` anchor that attachment-owned
  hooks receive.

## [v1.0.0-rc.24] — 2026-08-13

### Changed

- **Portable multi-fleet compatibility release.** Immutable annotated releases now install independently of a mutable policy checkout; explicit local-registry project, fleet, or all adoption updates verified attachment-owned runtime anchors only after preflight. Stable launcher, launchd, and mirror publication paths use canonical private machine state, clean reviewed payloads, and never publish operator paths or release, attachment, registry, or task state.

## [v1.0.0-rc.14] — 2026-07-28

### Added

- **Oversized Skill pre-load safety (spec 026).** Model-invoked and direct-slash
  Skills now pass a pre-expansion 65,536-byte UTF-8 root gate. Supported project,
  user, installed plugin-cache, and marketplace roots resolve by explicit
  precedence using declared names or basenames; same-tier ambiguity, invalid
  manifests, and oversized authoritative roots fail closed before `SKILL.md` body
  injection. SessionStart reports warning-only inventory, canonical roots gain a
  hard size linter, and Claude/Codex hook trees remain parity-tested. The normal
  272K GPT context window and auto-compaction policy are unchanged. Unknown future
  loader sources remain an explicit residual boundary.

## [v1.0.0-rc.13] — 2026-07-28

### Added

- **Multi-model lane continuity (spec 021).** A foreign model lane going down or hitting
  its cap no longer ends a delegated unit. `scripts/lane-preflight.sh` is a fail-closed
  probe — always exits 0, reports only, and resolves unknown/error/timeout to unavailable.
  `core-rules/agents/lane-worker.md` pins a first-party model in frontmatter and reaches
  the lane over `Bash`, so the agent works on a stock host instead of hard-failing at
  dispatch; on an unavailable lane it returns a structured `LANE_UNAVAILABLE` receipt and
  the caller re-runs the identical unit locally. `core-rules/references/model-lanes.md`
  carries the proxy-agnostic capability contract. Silent model substitution inside the
  router was considered and rejected — it spends the first-party subscription invisibly;
  see `docs/adr/2026-07-26-multi-model-lane-continuity.md`.

- **Claude 5 alignment (spec 019).** Six parallel audit tracks over the rules,
  skills, references, commands, narrative manual, and steering docs, against a
  distillation of eight published Anthropic sources now committed as
  `docs/research/2026-07-25-claude-5-prompting-corpus.md`. New on-demand
  references carved out of the constitution: `core-rules/references/delegation.md`,
  `core-rules/references/follow-ups.md`,
  `core-rules/references/gotchas-operational.md`, and `core-rules/primers.md`.
- **Unattended-run doctrine.** `core-rules/autonomy.md` gains a section on the
  failure mode that actually breaks long L4/L5 work: ending a turn on a question
  nobody will answer, or on a promise about work not done. It also extends the
  DoD-receipt discipline to the intermediate progress claims a multi-hour run
  makes before it reaches a receipt, and a reporting register that scopes
  terseness by whether anyone is watching.
- **Blind-spot pass and prototype passes in the builder skills.** `clarify` can
  now run a blind-spot pass and prioritizes questions whose answer would change
  the architecture; `brainstorming` permits low-fidelity prototypes with fake
  data where it previously forbade them; `spec` accepts tests, fixtures, rubrics,
  and HTML artifacts as the specification; `execute` gains
  `implementation-notes.md` for logging the conservative choice at each fork,
  scoped so it cannot perturb the diff stat or content hash the gates check.
- **Operator-account identifiers are blocked on the publish path.**
  `scripts/lib/mirror-lint.sh` gains a denylist class reading from
  `local/mirror-denylist.txt`, which lives in a private namespace so the linter
  never publishes the strings it exists to withhold. Absent the file the check
  is a no-op, which is correct for a fresh clone of the public template.

- **Post-remediation fleet audit receipts.** Record the private vulnerability,
  currency, consistency, major-watch, process, hook, host-health, registry,
  conductor, disk, security, lint, inheritance, autonomy, version, and rollup
  reports; close the private finding ledger with evidence and dated manual
  gates. Audit reports and fleet identities remain outside the public mirror.
- **Fleet dependency baseline and remediation ledger (spec 017).** A single
  origin-ref-backed validator now enforces exact shared dependency/toolchain
  lanes, compatible peer ranges, patched transitive security floors, dated
  exceptions, and evidence-backed finding dispositions across npm, pnpm,
  Poetry, and uv projects. `trellis deps` exposes check/snapshot/apply-plan and
  ledger commands; the dependency audits consume the same baseline.

### Changed

- **`core-rules/CLAUDE.md` rightsized: 24,138 → 18,194 bytes, no rule deleted.**
  Four relocations behind the existing on-demand reference mechanism, each
  leaving a pointer. The substantive fixes: the inverted claim that this model
  generation under-dispatches subagents is gone, replaced by a behavior-neutral
  rule that damps rather than encourages; the context-budget countdown is gone,
  being both redundant with a hook-enforced rule and the documented trigger for
  premature wrap-up; "default to no comments" becomes "write code that reads like
  the surrounding code", which is the sentence Anthropic replaced it with. The
  file is model-agnostic throughout, because `AGENTS.md` is a symlink to it and
  every word was reaching the Codex harness as its own instructions. Every
  deterministic gate is byte-identical.
- **`core-rules/references/model-prompting-deltas.md` rewritten** for Opus 5,
  Fable 5 and Mythos 5, Sonnet 5, Haiku 4.5, and the Codex executor path. The
  Sonnet and Haiku rows state that no primary source covers their deltas rather
  than inventing guidance. It also resolves the apparent conflict between the
  Opus 5 instruction to stop using verifier subagents and the Fable 5 finding
  that fresh-context verifiers beat self-critique: the axis is run length, not
  model preference, and deterministic gates are exempt either way.
- **`/doctor` renamed to `/trellis-doctor`.** Claude Code now ships its own
  `/doctor`, which rightsizes skills and `CLAUDE.md` — something this repo wants.
  Blast radius verified as zero seeded symlinks across all nine projects.
- **`docs/opus-4.8-steering.md` renamed to `docs/claude-steering.md`** and made
  generation-neutral with per-model sections, numbering held stable so inbound
  pointers survive. Five unsourced claims about harness mechanics were checked
  against current documentation: four confirmed and sharpened, the fifth deleted
  as unverifiable. The old path joins `DELIST_PRUNE`.
- **Loop budget ceilings are metered against the model the loop runs on.** The
  `usd_per_mtok` constant is correct for Opus 5 at $25/MTok, but Fable 5 and
  Mythos 5 output at $50/MTok, so a Fable loop metered at the Opus rate believes
  it has spent half what it has and sails through the ceiling meant to halt it.
  Also records that Claude 4.7 and later use a tokenizer producing roughly 30
  percent more tokens for the same text, so inherited ceilings need re-deriving.
- **The security-gate finder no longer receives an under-reporting instruction.**
  "Be skeptical, drop aggressively" is gone; current models follow that literally
  and report less. The filter it was reaching for already exists as that prompt's
  two-pass architecture, and over-dropping is now policed as hard as over-keeping.

- **Public dependency bootstrap is runnable without private fleet data.** The
  mirror now receives deterministic, schema-valid empty baseline and ledger
  shells, while sync replaces every private package lane, project name, report,
  and finding before leak checks. Empty registry/blacklist placeholders no
  longer parse as projects, HTML-commented example rows remain inert, and
  executable tests prove `trellis deps check` and `ledger-check` work in a
  fresh public clone. Synced operator docs now keep every public reference
  resolvable without exposing private plan directories, and the public test
  inventory no longer requires deliberately excluded private workflows.

- **Fleet baseline reconciliation.** Pin the published TypeScript 6 compiler-API alias,
  the Node 24 runtime-matched `@types/node` line, Firebase's Node 22 type lane,
  shared globals/PyJWT/FastAPI releases, and ignore generated Vercel output so clean
  remediation heads validate without false drift. Resolve the default projects
  root relative to Trellis so the public mirror contains no maintainer-specific
  absolute path.
- **Fleet audit and conductor fail-closed controls.** `test-health` now halts
  off-host before project access, uses no-optional-lock git reads, and forbids
  dependency hydration. Conductor runs rank-only after any ref-refresh failure,
  blocks all branch/worktree/spec mutation, and accepts credentials only from
  task secrets or Keychain. Auto-spec is temporarily zero while the backlog is
  reconciled; delivered rows and the narrowed the single-app project Loop 5 scope now match main.
- **Permanent blacklist reconciled.** `product-videos` is permanently excluded;
  the obsolete `the multi-frontend app-cc-data` and `DocSynapse` rows were removed while their
  history remains in git.

- **TypeScript compatibility lane corrected to published registry state.** The
  native compiler remains 7.0.2; the compiler-API alias is 6.0.2 because
  `@typescript/typescript6` has no published 6.0.3 release. Fixtures pin the
  same installable side-by-side arrangement.
- **Next lint compatibility lane recorded.** Next projects use ESLint 9.39.2
  while the current `eslint-plugin-react` throws under ESLint 10; non-Next
  projects remain on the 10.4.1 lane until the upstream plugin converges.

### Fixed

- **Workflow required stages now fail closed instead of disappearing as nulls.** Canonical recipes preserve one settled receipt per declared identity, emit structured `workflow_stage_gate` JSON with expected/success/failure counts and IDs, and throw before later required stages when a unit is null, throws, or returns the wrong identity. Valid negative/HOLD verdicts still count as completed receipts. Codex remains optional where intended (`verify-panel`), while a Claude fallback is required and can no longer fail silently. The Workflow test stub now matches production parallel/pipeline failure semantics, including per-item stage skipping and `(previous, originalItem, index)` arguments (spec 024).

### Fixed

- **Hook and gate correctness.** Stop-hook re-entry, Codex pre-push fallback, untracked-file review coverage, nested-review recursion, eslint availability, absolute Go paths, destructive-command bypasses, autonomy resolution/decision receipts, session temp files, and mandatory-pipeline config validation all have executable regressions across both harnesses.
- **Orchestration correctness.** Codex producer and verifier now share the real caller worktree; explicit worktrees cannot collide inside a concurrent wave; dependency-serialized reuse remains valid; conflict repair, target-cwd threading, drift grouping, effort policy, concurrency schema, and no-progress semantics are aligned. Conductor refreshes each project once under a timeout, aborts on partial refresh, and binds ranking/spec worktrees to immutable main SHAs.
- **Fleet tooling correctness.** Eval coverage reconciles active non-blacklisted projects in both check modes while supporting the intentionally private-input-free public mirror. A shared current-format blacklist parser protects fleet mutators; prerelease SemVer ordering, app-server freshness, doctor paths containing spaces, disk-janitor discovery failures, rollout dry-runs, and literal mirror substitutions are covered by focused tests.

## [v1.0.0-rc.12] — 2026-07-14

### Added

- **`core-rules/references/programmatic-tool-calling.md`** — a spike / pattern doc (no tooling) for audits that fan out to **many** tool calls: batch the calls into one `bash`/code pass and reduce the results in the script, so the model pays for the *answer*, not the *fan-out*. Generalizes batching used by the private dependency-vulnerability audit (osv.dev `/v1/querybatch`) and names the API's **programmatic tool calling** (public beta) as the capability-gated platform form. Adopt-loop (spec 008, digest 2026-07-07 P5).

### Changed

- **Audit remediation closeout (spec 015).** All 67 findings from the 2026-07-13 specs/implementation audit now have either a regression-backed fix or an explicit disposition. Shipped specs 005–014, acceptance ledgers, release claims, command references, README census, and the duplicate spec number were reconciled to implementation truth. SPEC 013 is deliberately labelled implementation-shipped / acceptance-partial; its missing live mixed-agent and warm-resume observations are not represented as completed receipts.
- **Public mirror boundary tightened.** `scheduled-tasks/` is no longer published and is pruned from the public tip; current operational examples are genericized. Existing public history is accepted as disclosed rather than force-rewritten, while designated ADR/CHANGELOG/deferred provenance remains intact. Dry-run now lints an apply-equivalent simulated mirror before any mutation.

### Fixed

- **Hook and gate correctness.** Stop-hook re-entry, Codex pre-push fallback, untracked-file review coverage, nested-review recursion, eslint availability, absolute Go paths, destructive-command bypasses, autonomy resolution/decision receipts, session temp files, and mandatory-pipeline config validation all have executable regressions across both harnesses.
- **Orchestration correctness.** Codex producer and verifier now share the real caller worktree; explicit worktrees cannot collide inside a concurrent wave; dependency-serialized reuse remains valid; conflict repair, target-cwd threading, drift grouping, effort policy, concurrency schema, and no-progress semantics are aligned. Conductor refreshes each project once under a timeout, aborts on partial refresh, and binds ranking/spec worktrees to immutable main SHAs.
- **Fleet tooling correctness.** Eval coverage reconciles active non-blacklisted projects in both check modes while supporting the intentionally private-input-free public mirror. A shared current-format blacklist parser protects fleet mutators; prerelease SemVer ordering, app-server freshness, doctor paths containing spaces, disk-janitor discovery failures, rollout dry-runs, and literal mirror substitutions are covered by focused tests.

## [v1.0.0-rc.11] — 2026-07-10

- **Effort band narrowed: xhigh+max only (PR #136, operator directive, temporary).** `medium`/`high` suspended across `docs/codex-routing.md §3`, the codex-worker input contract, all three recipe `EFFORT_ENUM`s, and MANIFEST; revert text carried in §3 + a `follow-ups.md` ledger row. `supportedEfforts` capability floors untouched (capability ≠ policy).
- **No-duplicate-work rule — race-the-legs RETIRED (PR #138, operator directive).** Same work order never dispatches to more than one agent/leg; sequential degrade replaces racing; cross-model review of one produced diff stays legitimate. Speed doctrine now five live patterns; prior same-day ADRs annotated partially-superseded.
- **Sol ultra capability re-ground (PR #138; ADR `2026-07-10-sol-ultra-capability-reground.md`).** Source-verified (`openai/codex` @ rust-v0.144.0): ultra = max effort on the wire + proactive-delegation prompt injection (harness mode, not a deeper tier); CLI default 4 concurrent threads; companion v1.0.5 caps at xhigh so max/ultra are Bash-direct only. Spec 011 D4a prerequisites SATISFIED — telemetry via `turn.completed` usage in `codex exec --json`, ×4 accounting anchored to the 4-thread default in loop-safety, instrumented paired run committed (`specs/011.../research/ultra-probe-2026-07-10/`; ultra vs xhigh 1.38–2.09× tokens). Ultra unlocked for **attended main-loop Bash-direct** dispatch only; recipes keep the hard-reject on surface + visibility grounds.
- **Sandboxless-hatch ban mechanized.** `block-destructive.sh` (both harnesses) denies codex bypass-sandbox + max/ultra compounds; 4 new bats cases (25/25 green).
- **Teammate hook env fixed.** GUI-spawned panes lack nvm in PATH → node-invoking hooks were silently dead; fixed with a `~/.local/bin/node` shim + `PATH` prefix on the codex-plugin `hooks.json` commands and the user-level PostToolUse hook (`env -i` verified). Re-apply after plugin updates (ledger row).
- Adversarial review: 28-agent workflow, 21 confirmed findings (1 blocker: unattended-ultra scoping gap) — all folded pre-merge.

## [v1.0.0-rc.10] — 2026-07-10

### Added
- **GPT-5.6 effort ladder v2 (spec 011 Phase A).** Explicit-effort-or-error on every Codex unit (enum `medium|high|xhigh|max`; omitted = validation error, never a default); `max`/`ultra` exception tiers, opt-in with receipt-logged justification; `ultra` hard-rejected in recipes until token telemetry + ×4 concurrency accounting + one instrumented run exist. Six-field work-order contract + verbatim honest-reporting clause in both runnable prompt builders (5.6 system-card hardening). `supportedEfforts` fail-closed degrade — reject-and-reroute, never clamp. `scripts/codex-effort-preflight.sh` + executable SC3/SC4 matrix (`wf-stub.mjs`) against the real recipes. §2 strength figures untouched behind a dated stale-banner (Phase B re-grounds on ≥2 independent non-OpenAI evals; expiry 2026-08-15). ADR `2026-07-10-gpt-5-6-effort-reground.md`.
- **Follow-ups convention (spec 012).** Prioritized follow-ups at completion boundaries (spec status flip, PR open, DoD receipt), derived zero-exploration, captured in per-spec `## Follow-ups` tables + a root `follow-ups.md` ledger; `<!-- follow-ups: N|none -->` marker beside the DoD receipt; both `stop-verify` hooks warn (non-blocking, warn-stays-warn test-asserted) on receipt-without-marker, with dod-receipt spans stripped pre-scan so a receipt quoting the marker cannot false-satisfy.
- **Blocking `codex-worker` + `codex-fanout` (spec 013; implementation shipped, acceptance partial).** Canonical agent def under `core-rules/agents/` (inherited via `.claude/agents/` symlinks; new projects wired by onboard; `rollout-codex-worker-agent.sh` for the fleet): explicit-background launch, foreground poll chunks, collaboration-tool-ban preamble, bounded stall recovery (cancel + one annotated retry; one-tier-lower on thread-create wedge), receipts with attempts/downgrades/ids. `codex-fanout.wf.js`: mixed Codex/Claude fan-out, config-knob cap (`codex_fanout.concurrency`, default 4), topological `dependsOn` waves, branch-based conflict isolation, anchored receipt STATUS parsing, leak guard with cancel-on-leak. All Workflow dispatch migrated off the fire-and-forget rescue path (now interactive-only). Current speed doctrine is five live patterns — cross-harness pipelined verify, warm-thread pool, primer-fed dispatch, streaming merges, ultra-as-node — plus the no-duplicate-work rule; the original rc.10 race pattern was retired by rc.11. Focused SC2 stall recovery is 2/2 green and the containing runtime recipe suites are 41/41 green; the six-unit stub is structural only, and live SC1/SC3/warm-thread SC5 receipts remain open. `codex-worker-preflight.sh` (CLI ≥0.144, shadowed installs, stale app-servers, pin, companion enum). ADRs `2026-07-10-gpt-5-6-dual-harness-program.md`, `2026-07-10-codex-parallel-orchestration.md`.

### Changed
- **Fan-out doctrine: dynamic workflows preferred over named teammates** on teams-enabled harnesses — teammates never auto-terminate (probe-verified: graceful `shutdown_request` and `TaskStop` both work when invoked, but nothing invokes them automatically) and teammate panes can spawn with hooks dead (`node` absent from PATH). Lifecycle-by-construction over lifecycle-by-discipline (`orchestrate/SKILL.md`).
- `docs/codex-routing.md` §1 topology reframed as policy choice (Codex now has native multi-agent surface); §4.5 canonical Workflow dispatch = `codex-worker`; §6 review invariant precise wording ("never delegated to the executor that produced the diff"); loop-safety gains worker-stall/race/ultra accounting.

## [v1.0.0-rc.9] — 2026-07-09

### Added
- **`writing` — twelfth canonical skill (spec 010).** Drafts and publishes blogs + X threads in the author's or project's voice: voice load → draft → self-review → scriptable validation → publish → receipts. Full auto-post on explicit invocation (`disable-model-invocation: true`; invocation = authorization, named targets bound the scope); posting leg capability-gated with paste-ready degrade; never deletes or edits published content. `core-rules/skills/writing/`.
- **`check-writing.sh` blocking validator** — blog mode (em/en-dashes outside code fences, slop vocabulary, bold-lead-in bullets, antithesis clustering) + thread mode (4–8 tweets, ≤280 chars, no links in tweet bodies — link rides a reply, per the open-sourced ranker). Fixtures + bats. Built by Codex under the 009 pilot (ledger row 2).
- **Dated references:** `ai-tells.md` (clustering-is-the-signal catalog), `x-thread.md` (ranker weights + composer mechanics), `voice.md` (per-target-repo `docs/voice.md` convention — voice files structurally outside the mirror sync).
- `scripts/rollout-writing-skill.sh` (debrief-pattern fleet symlink install); ADR `2026-07-09-writing-skill.md`.

## [v1.0.0-rc.8] — 2026-07-08

### Added
- **Interactive executor delegation (spec 009).** Bounded work-order units may route to a cheap executor leg (Codex via companion, or a cheap Claude worker) from any turn, not only inside orchestrated fan-outs — advisory-first pilot with ledger + flip criteria. Route predicate (work-order vs design, ~20-line soft floor, session-tools + bright-line carve-outs; review never delegated), canonical delegation prompt template, per-unit resume + two-failed-rounds takeover with failure taxonomy, per-dispatch tracking receipt. `docs/codex-routing.md §6`, `orchestrate/references/codex-executor.md`.
- **Ref-integrity guard in `sync-to-template.sh`:** any synced file referencing an unsynced `core-rules/*.md` now fails the sync (dry-run and apply).
- ADR `2026-07-08-interactive-codex-delegation.md`.

### Changed
- **Effort doctrine:** dispatch-time effort ladder for interactive units (xhigh hard/verify, high standard implementation, medium/low mechanical) replaces blanket xhigh; workflow recipes keep xhigh (follow-up named). `docs/codex-routing.md §3`.
- **Routing economics refreshed:** both engines metered; dual-pool quota-headroom rationale; strength claims re-ground only via the 008 model-launch trigger.

### Fixed
- **`core-rules/loop-safety.md` now ships to the public mirror.** It was referenced by 13 synced files (CLAUDE.md § Loops, `references/loops.md`, orchestrate skill + recipes) but absent from SYNC_PATHS — every public fork saw dangling references.

## [v1.0.0-rc.7] — 2026-07-07

Process parity + the mandatory feature pipeline. Makes process enforcement **equal across Claude Code and Codex** and makes the spec pipeline **mandatory for feature-sized changes** — both via one lever: a deterministic pre-push gate keyed on git/filesystem state, so the state (not the model) decides. **Default OFF**; the public template ships off and a fresh install is unchanged. Spec/plan/tasks/clarify: `specs/006-process-parity-and-mandatory-pipeline/`. ADR: `docs/adr/2026-07-07-mandatory-pipeline-and-parity.md`.

### Added

- **The spec-gate** (`core-rules/hooks/lib/spec-gate-core.sh` + `core-rules/hooks/spec-gate.sh` + the byte-identical Codex twin). A pure function of git/fs state: over a size floor, a branch's push is refused unless ONE of — a **spec triad added in this branch's range** (+ an interview artifact), a size-capped **`/surgical`** declaration, or a logged **`/surgical --emergency`** override. Load-bearing teeth at **pre-push** (harness-agnostic git hook = parity by construction); a **Stop-hook** early-warning on both manifests. Fail-**open** on a broken env, fail-**closed** on a present-but-malformed config.
- **`/surgical` command** (`core-rules/commands/surgical.md`) + the marker writer (`spec-gate.sh --mark` / `--mark-emergency`). Writes a branch-bound, size-capped exemption marker; over-ceiling surgical claims and emergency overrides are appended to a gitignored audit log. Inherits to `.claude/commands` + `.agents/commands` + `.agents/workflows`.
- **`mandatory_pipeline` config block** (`enabled` default false, `spec_required_diff_lines` 80, `surgical_max_diff_lines` 400) — in the operator config, the template example, and the JSON schema. Resolution: project-local → central → built-in (off).
- **Doctor Codex-runtime check** (`hc_codex_hooks_enabled`) — warns when Codex is enabled but its runtime hooks are off (`[features] hooks = true`), the condition that would silently no-op the whole Codex enforcement path.
- **Tests**: `scripts/tests/spec-gate.bats` (25 cases incl. default-off, C-CRIT-1/2, surgical/emergency + audit, branch-bound isolation, L4/5 path, fail-open/closed, determinism, Stop-mode block, harness parity) + `scripts/tests/codex-hooks-enabled.bats` (6 cases).

### Changed

- **Doctrine reconciled across 10 files** to one knob-conditional statement (`engineering-process.md` §14.7 authoritative): the `clarify → spec → plan → tasks → analyze` pipeline is **opt-in by default**; when `mandatory_pipeline` is enabled it is **required for above-floor changes**; sub-floor work stays surgical-default at every setting. The old "always opt-in" assertions in `spec`/`clarify`/`analyze`/`execute`/`README`/`inheritance` were rewritten; `brainstorming`'s always-on design-gate is preserved and gains the gate-interaction clause (recognized form required above the floor — no surgical dodge for real features). `CLAUDE.md` Planning + Autonomy and `autonomy.md` state the pipeline is **not** a bright-line guardrail — *who answers* the intake follows the slider (L1–3 `clarify.md`/waiver, L4/5 `decisions-log`).
- **Cross-project process audit** — check 11 reconciled to knob-conditional; new **check 11b** surfaces the gate's audit trail (oversized-surgical + open emergency-overrides with no follow-up spec).

## [v1.0.0-rc.6] — 2026-07-07

Loop-selection doctrine. Integrates the Claude team's *"Getting started with loops"* mental model into Trellis. Spec/plan/tasks: `specs/007-loop-selection-doctrine/`. ADR: `docs/adr/2026-07-07-loop-selection-doctrine.md`. Pure doctrine — no new hook, command, or mechanism.

### Added

- **`core-rules/references/loops.md`** — the loop-*selection* layer Trellis lacked. Maps the four loop types (turn-based / goal-based / time-based / proactive) to Trellis primitives with a decision table, and for each **hands off halting to `loop-safety.md`** rather than restating the ceilings. Grounding confirmed Trellis already *leads* the blog on loop safety (the three-ceiling halting contract, dollar + no-progress ceilings, the merge bright-line) but had no doc answering *which* loop to reach for.
- **Orchestrate norms** (`orchestrate/SKILL.md`) — the **pilot-before-a-large-fan-out** norm (validate a recipe on a 2-3 target subset before scaling) and the canonical **proactive-loop five-stage shape** (detect → triage → resolve-in-parallel → adversarial-review → respond), cross-referencing the recipes that already embody stages (conductor, `drift-holdpr`, `verify-panel`).

### Changed

- **`loop-safety.md`** gains a cross-link (which-loop → `loops.md`; how-it-halts → itself) and a "start simplest — reach for the simplest primitive with a real stop condition" restraint line, the loop-analogue of surgical-default. The blog's operating practices (verification, adversarial review, encode-the-fix, budget awareness) are folded into `loops.md` as **pointers to machinery Trellis already ships** (`stop-verify`/DoD, `verify-panel`, `gotchas`/`propose-rules`/rule-of-three, the three ceilings), not re-authored.

## [v1.0.0-rc.5] — 2026-07-05

SE-board modernization, agent-skills fold-in, and automation-first. Spec/plan/tasks: `specs/005-se-modernization-and-skill-foldin/`. Built cross-model (Codex adversarially reviewing Claude's work through the tracked wrapped path) — the P0 review caught a HIGH prune-safety bug before it landed.

### Added

- **Sync-hardening (Workstream D).** `scripts/lib/mirror-lint.sh` greps the **whole** public mirror — including the public-only files the allowlist sync never touches (`README.md`, `SETUP.md`, `AGENT_SETUP.md`) — for absolute-path leaks (hard-fail anywhere) and stale `antigravity` outside the historical record (`docs/adr/`, `docs/specs/`, `CHANGELOG.md`, the removal tooling); maintainer name + github user are deliberately **not** denylisted (legitimate public attribution / clone URLs). `sync-to-template.sh` gains a `DELIST_PRUNE` register (path-safety-guarded `git rm` of renamed/retired paths — never a blanket unsynced-delete) and a fail-closed post-apply lint that aborts before any commit/push. This guards the exact RC.4 stale-AntiGravity regression. Tests: `mirror-lint.bats` (16), `hook-parity.bats` (bidirectional Claude↔Codex).
- **Cross-model verify-panel recipe** (`core-rules/skills/orchestrate/recipes/verify-panel.wf.js` + reference) — per hard finding, a Claude reviewer and a Codex reviewer judge in parallel and merge into a consensus (`agree-real` / `agree-not-real` / `split` / `single-model`), degrading to single-model when Codex is absent. Realizes the reserved "second-opinion → the other model" routing and the parked `hooks.md` v2 multi-angle reviewers.
- **Process primitives folded from `addyosmani/agent-skills`** (process-only; domain knowledge stays reference-only, per the lean-spine decision): new `core-rules/references/` — `doubt-driven-development` (CLAIM→EXTRACT→DOUBT→RECONCILE→STOP), `source-driven-development`, `versioning`, `deprecation-and-migration`. Nuggets folded into existing skills: `clarify` (hypothesis + confidence per question, predict-to-stop), `tasks` (vertical / contract-first / risk-first slicing taxonomy), `brainstorming` (idea-refine divergent lenses).
- **Automation-first, safe tier.** **C1** — the daily digest now emits a tiny `<root>/.claude/audit-digest.md` that the `session-context` SessionStart hook injects (a push of unresolved findings when work begins, not the pull of a cron report); the `daily-project-digest` task is migrated on-disk. **C5** — `execute` capability-gates execution-heavy bounded units to the Codex executor via the tracked wrapped path (verify + review-of-actual-diff + DoD receipt run identically on a Codex diff).
- **Automation-first, Component-D tier — shipped behavior defaults OFF (current behavior preserved).** **C2** `drift-holdpr` recipe (opt-in, inert until invoked): mechanical drift → a `[HOLD]` PR per project, never merging, never touching project main, refusing non-mechanical divergence, under its own loop-safety ceilings. **C7** gotchas-rollup `auto_promote_pr` (default off = recommend-only; on = a clean n≥3 cluster opens a `[HOLD]` rule-of-three PR against core-rules). **C8** conductor `auto_execute_top_n` was documented in scheduled-task prose but did not ship as a canonical config/schema-backed executable knob; it remains deferred. The **merge bright-line is absolute at every shipped setting** — no knob crosses it.

### Changed

- **Reviewer coverage contract now lives in the prompt string** (A1). The `code-reviewer` prompt gains one explicit line — "report every finding including low-severity/low-confidence; coverage is your job, filtering is not" — in both byte-identical copies, guarded by a new `code-reviewer-parity.bats`. (Grounding found the shipped prompt was already correct on coverage; this makes the contract live in the string, not only the prose.) Five-axis review framing (correctness/readability/architecture/security/performance, review-tests-first, net-health) added to the reviewer **prose**.
- **Edit-safety rule corrected** (S2): the "Edit fails silently on stale `old_string`" premise is retired (the tool errors loudly and the harness tracks file state); the non-hook-backed post-edit re-read is dropped, the `reread-guard`-enforced before-edit re-read kept. **Debugging** now escalates reasoning effort (`/effort max` / ultracode) at the two-attempts stuck-point (A5). **The "max 7 files per phase" cap is now an autonomy-scoped soft ceiling** that widens at L4/L5 (S4).
- **`docs/gpt-5.5-steering.md` → `docs/gpt-5.x-steering.md`** (A6/S3): the effort §1 that contradicted `codex-routing` (Codex `xhigh`-default, plan/analyze → Claude) is dropped and deferred to `codex-routing.md`; verbosity, `update_plan`, and the progress-floor survive.
- **The wrapped tracked path is now Trellis's *prescribed* Codex dispatch** (§4 + `codex-routing.md` §4.5 + `codex-executor.md`): dispatch Codex via `agent(prompt, { agentType: 'codex:codex-rescue' })` inside a Workflow (a first-class harness-tracked node) as the canonical method — there is no wrapper-free path (Claude Code spawns Claude models only; the plugin ships no MCP server). The recipe now **forces synchronous** and detects a background job-handle result to degrade it — closing a real bug where a backgrounded Codex unit silently dropped its result from a fan-out. `check-docs.sh` now implements the advertised "CHANGELOG entry added" warn (closing a reference↔script gap).

### Deferred (to rc.5.1, documented — not dropped)

- **C3** (pr-gate shift-left) + **C6** (primer-capture nudge) — advisory nudge hooks needing dual-manifest wiring. **C4** (L5 auto-append to `gotchas.md`) — a write gate best built after extracting the autonomy-level resolution into a shared lib. Tracked in `specs/005-.../tasks.md` Follow-ups.

## [v1.0.0-rc.4] — 2026-07-05

### Added

- **Cross-harness orchestration — Claude as orchestrator, Codex as a dispatchable executor node.** Trellis previously ran Claude and Codex as pure *parity* harnesses (byte-identical rules, each agent working alone). This release adds the ability for Claude, while driving a dynamic workflow or loop, to dispatch execution-heavy bounded units of work to **Codex as an executor node**, routing each unit to the model whose documented strengths fit it — Claude keeps planning, review, and synthesis; Codex takes the token-cheaper, faster, autonomous execution bulk. The strength-routing policy ships as durable steering **intent** in the new **`docs/codex-routing.md`** (sourced to the July-2026 community/benchmark consensus, not model recall), and as **one capability-gated clause** in `core-rules/CLAUDE.md §Context management` — never as an in-file model conditional (CLAUDE.md/AGENTS.md remain byte-identical symlinks; ADR 2026-05-08 preserved). Codex is a **runtime-detected capability**, not a hard dependency: presence is gated via `codex-companion.mjs setup --json`, and a failed / absent / limit-hit Codex unit degrades cleanly back to the orchestrator (a limit-hit and a failure are the same signal — there is no quota API). The framework is inert on the public mirror without the `openai-codex` plugin. Both models default to `xhigh` effort (Codex's ceiling is `xhigh`, no `max`). ADR: `docs/adr/2026-07-05-dual-harness-orchestration.md`; plan: `docs/plans/2026-07-05-codex-claude-dual-harness-integration.md`.
- **`codex-executor` orchestrate recipe** (`core-rules/skills/orchestrate/recipes/codex-executor.wf.js` + `references/codex-executor.md`) — the reusable mixed-harness fan-out: route `execute`-kind units to Codex when available, keep `plan`/`review`/`synthesize` units on the orchestrator, degrade to Claude-only when Codex is absent. Documents both dispatch paths — Bash-direct from the main loop (zero wrapper) and the in-engine `codex:codex-rescue` forwarder (cheapest in-Workflow path) — and carries a loop-safety `safety` block plus the Component-D guardrails (HOLD-only PRs, own autonomy ceiling, bright-lines on every Codex unit, bypass-perms for overnight runs). Built and reviewed **cross-model**: a bidirectional review (Codex reviewing Claude's work and vice versa) caught two real bugs in the recipe before it landed.
- **Per-model loop budget rate.** `core-rules/loop-safety.md` and the `loop_safety` config block gain an optional **`codex_usd_per_mtok`** so a cross-harness loop attributes Codex-unit spend at the Codex rate instead of the Opus `usd_per_mtok`; absent, it falls back to the single rate (backward compatible).

### Removed

- **AntiGravity harness support (fully stripped).** AntiGravity was admitted as a third harness in v0.4.0 with native hooks deferred, but never became competitive with Claude Code + Codex and was not enabled in any active instance. Removed from the `harnesses` enum (`trellis.config.schema.json`), the onboard + rollout script gates (dropping only the `|| antigravity` disjunct — **Codex parity and the shared `.agents/` surface, including `.agents/workflows/`, are untouched**, since Codex reads them too), the `process-gate` branch-name allowlist, `health-checks` (its `.agents/workflows` check relocated into the Codex path), and the narrative docs. `docs/antigravity-steering.md` is deleted and removed from the public-mirror sync set. The ADR `docs/adr/2026-05-20-antigravity-third-harness.md` is marked **Superseded** by the dual-harness ADR (history preserved). Historical records (`audits/`, `specs/001-*`) are left as-is.

## [v1.0.0-rc.3] — 2026-07-04

### Added

- **Loop-safety contract — the canonical halting guarantee for every Trellis loop.** Trellis is already a loop system (the 16 `scheduled-tasks/` cron loops, the `orchestrate` fan-out workflows, `/loop` and `/goal`), but had no single named contract that every loop halts — halting logic was scattered across the Workflow token budget, `autonomy.md`, and ad-hoc per-task caps. The contract requires every loop to **declare and honor three ceilings and halt on any one**: `max_iterations` (baseline 100), `no_progress_iterations` (baseline 3, keyed on a per-loop **progress signal** — commit/PR, file delta, new finding, work-list drain, or the catch-all state-hash change; a one-shot fan-out with no rounds declares `null`), and `budget_ceiling_usd` (baseline 1000, mapped onto the Workflow engine's token-native `budget.total` via a documented usd-per-MTok rate). Safe-by-default: a loop authored with no thought still halts, and a loop in a broken/misconfigured context falls back to documented built-in constants identical to the baselines. The ceiling **values** live in a new optional `loop_safety` block in `trellis.config.json` (and its schema), resolved most-specific-first — per-loop `safety` override → project-local `.trellis.config.json` → central config → built-in fallback — mirroring the `autonomy` resolution pattern. On a trip the loop hard-stops (never auto-continues) and emits a structured halt report (which ceiling tripped, last progress marker, work done); unattended / cron / `--run-in-background` loops surface the halt in their run report rather than dying silently. This ships as **doctrine + declared fields, not a mechanical enforcement hook** (engine interception is explicitly deferred); compliance is kept honest by a drift check folded into the weekly `cross-project-process-audit`. The policy lives in the new `core-rules/loop-safety.md`, is discoverable to agents through a new `## Loops` section in the always-loaded `core-rules/CLAUDE.md`, and is cross-referenced from `autonomy.md`; the `orchestrate` recipe template and `fanout-verify.wf.js` carry a `safety` block and each scheduled-task prompt declares its stanza. The foundational sub-project of the loop-safety trio (the nesting-depth budget and the "Mayor" loops-supervising-loops recipe extend it). Design: `docs/specs/2026-06-09-loop-safety-contract-design.md`; research: `docs/research/2026-06-09-agent-loops-and-nested-subagents.md`.
- **`scripts/rollout-debrief-skill.sh`** — idempotent per-project installer for the `debrief` skill symlink, modeled on `rollout-builder-skills.sh`. Honors `harnesses` (`.agents/` parity for Codex/AntiGravity), reads the registry, and backs up any pre-existing directory before linking. Used to roll `debrief` out to all 8 registered projects (both surfaces). Deliberately does **not** touch `.gitignore`: the stale per-project fragments already omit `execute`/`brainstorming`/`orchestrate`, so debrief joins a pre-existing fleet-wide drift rather than a new one — refreshing those fragments is a separate, batched re-onboard concern.
- **`scripts/rollout-orchestrate-skill.sh`** — idempotent per-project installer for the `orchestrate` skill symlink, the exact analog of `rollout-debrief-skill.sh`. `orchestrate` (the tenth canonical skill) was seeded by `onboard-project.sh` going forward but never backfilled onto the four projects onboarded before it landed (the monorepo project, the multi-frontend app, the RAG service, the polyglot monorepo), so they were running 9-of-10 canonical skills. This script closes that gap: registry-driven, `harnesses`-gated `.agents/` parity, backs up any pre-existing directory before linking. Rolled `orchestrate` out to all 8 registered projects (both surfaces) — the fleet now carries the full canonical skill set.

### Changed

- **Codex harness parity with Claude Code.** Codex now carries the default-on
  `propose-rules` Stop hook, receives the same shared reviewer/UI hook cores
  during onboarding and sync, and is checked by `doctor` for hook manifest,
  hook-lib, reviewer-core, and `process-gate-local` parity. The parent drift
  audit scope now treats Codex hook assets and shared reviewer cores as
  first-class rollout artifacts.
- **`scripts/onboard-project.sh` — the `.gitignore` Trellis block is now GENERATED, not appended (closes the fleet-wide stacking drift).** The old `ensure_gitignore_fragment` cat-appended a static template whenever a version sentinel changed and never removed prior blocks, so projects accumulated stacked, stale Trellis blocks that omitted newer symlinks — the four `execute`/`brainstorming`/`orchestrate`/`debrief` links showed up as untracked across the whole fleet. Replaced by `write_gitignore_block`: `seed_symlink` records every absolute-target link it creates, and at the end of the run the block is regenerated in full, listing exactly those machine-absolute symlinks (the relative `AGENTS.md` → `CLAUDE.md` link is excluded, so it stays tracked — the user's rule "ignore only the hardcoded-symlink paths"). The block is **version-agnostic** (no skill-count sentinel) and self-healing: each run strips all prior Trellis-managed blocks (every historical sentinel + the legacy `end SE Core fragment` end-marker variant) plus any orphaned canonical-symlink lines stranded between stacked blocks, collapsing them into one clean block. Stripping is **per-block** (not span-based) and the orphan sweep matches only exact Trellis-owned strings, so project-authored `.gitignore` content — even when interleaved between stacked Trellis blocks (e.g. the polyglot monorepo) — is preserved. Rolled out to all 8 registered projects, one PR each. ADR: `docs/adr/2026-06-05-gitignore-generated-block.md`.
- **`engineering-process.md` + `scripts/rollout-{feature-skills,builder-skills,process-gate-skill,presets}.sh`** — onboarding narrative and operator hints updated to describe the generate-and-replace mechanism; the obsolete "paste the fragment yourself" advice is replaced with "re-run `onboard-project.sh`".
- **`core-rules/CLAUDE.md` (and its `AGENTS.md` symlink) — genericized project-name attributions in the always-loaded parent rules.** The four rules promoted into the parent surface from `deferred.md` (worktree-safety, code-asset pairing, cloud-provisioning region check, ADR convention) carried parenthetical project-name attributions (`(the monorepo project, the portfolio site, the polyglot monorepo, the RAG service)`, etc.) — the only project names anywhere in the always-on surface that ships verbatim to the public mirror. Replaced with counts (`(observed across N projects)`), preserving the "grounded in real incidents" evidential weight without naming private projects in the every-session surface. Full provenance (which projects, n-counts, incident dates) is retained in `core-rules/deferred.md`, the CHANGELOG, and the ADRs. Unblocks the public-mirror sync of the post-RC core-rules promotion.

### Removed

- **`core-rules/templates/project.gitignore.fragment`** — deleted. The Trellis `.gitignore` block is now generated by `onboard-project.sh` from the symlinks it creates rather than cat-appended from a static template, so the template is obsolete. Its references in `engineering-process.md` and the rollout-script hints are updated in lockstep.

## [v1.0.0-rc.2] — 2026-06-05

**Dynamic-workflow adoption — Trellis already lived ~80% of the "harness for every task" doctrine (parallel subagent fan-out, verifiable-goal framing, the code-review subagent as adversarial verification, phase decomposition), but the genuinely-new orchestration patterns were unnamed and the ad-hoc `.wf.js` scripts were bespoke one-shot runs, not a reusable library. This release names the patterns, canonicalizes the recipes into a capability-gated `orchestrate` skill that ships through the existing skill-symlink rail to both harnesses, and folds one capability-conditional clause into the always-on parent rules — without leaking Claude-specific surface into the shared Codex prompt.** Design: `docs/specs/2026-06-03-dynamic-workflows-design.md`. The audit-remediation auto-fan-out (Component D) is split to its own follow-up spec, given its higher unattended-autonomy ceiling.

**`debrief` — the teach-it-back skill (eleventh canonical skill).** A member of the Claude Code team's "wise teacher" `CLAUDE.md` prompt, ported to a single harness-neutral, explicit-invoke-only skill: after autonomous work the agent teaches the change back so the human retains the mental model — the deliberate counterweight to the L4/L5 autonomy slider. The port neutralizes the source's Claude-specific surface (gendered voice → neutral; `AskUserQuestion` quiz → capability-gated with a numbered-inline degrade; the `/goal` "don't stop until understood" → the verifiable-goal rule in `CLAUDE.md`, no CLI dependency), and `disable-model-invocation: true` carries the never-auto-fire intent directly — collapsing the originally-planned command+skill pair after Claude Code's command/skill name-collision rule (the skill wins, shadowing the command) made that shape unworkable. Design: `docs/specs/2026-06-05-debrief-skill-design.md`. ADR: `docs/adr/2026-06-05-debrief-teach-it-back-skill.md`.

### Added

- **`orchestrate` — the dynamic-workflow orchestration skill (tenth canonical skill).** Spec-primary architecture: `SKILL.md` is the durable, harness-neutral specification — when-to-use, the pattern catalog, the capability gate, the two-level graceful degrade, the recipe index, and the authoring guide. The `.wf.js` files under `recipes/` are one implementation of that spec (the implementation for a workflow-orchestration tool), and double as a readable stage spec for harnesses that have no such tool. The pattern catalog (`references/patterns.md`) cross-references the four patterns the parent rules already carry (fan-out-and-synthesize, adversarial-verification, generate-goal/loop-until-done, phase-decomposition) and teaches only the two genuinely-new shapes as first-class entries — **tournament** (N candidates compete via pairwise comparison at a scale one context can't hold) and **generate-and-filter** (generate many candidates cheaply, then filter by an explicit quality metric). Ships generic, parametric skeletons — `template.wf.js` (blank starting point: `meta` block, structured-output schema stub, fan-out/verify/verdict scaffolding), `fanout-verify.wf.js` (fan-out-per-target → verify on host → structured verdict), and a `MANIFEST.md` recipe index — not the bespoke one-shot scripts. Every shipped file is parametric and path-neutral; targets come from the registry and dates/scope from `args` or a sidecar config, never baked literals.
- **Capability-conditional orchestration clause in the parent rules.** A single clause folded into the existing parallel-dispatch rule in `core-rules/CLAUDE.md` (the always-on, every-session surface, mirrored to Codex/AntiGravity via the `AGENTS.md` symlink): *if the harness exposes a tool that spawns and coordinates subagents, prefer orchestrating multi-stage work through it (decompose → fan-out → adversarially verify → synthesize); otherwise run the same stages yourself.* Gated on **capability, not harness identity** — the condition is genuinely correct for both harnesses and self-activates the day Codex ships its own workflow runner, with no Trellis change. No new pattern catalog lands in the always-loaded rules; the catalog and recipes are paid for only when orchestration is relevant.
- **`debrief` — the teach-it-back skill.** A single explicit-invoke-only skill (`disable-model-invocation: true`) under `core-rules/skills/debrief/` (`SKILL.md` + `references/quiz-and-degrade.md`), inherited to both harnesses via the existing skill-symlink rail. Gated incremental teaching: restate-first diagnosis, three understanding tiers (problem·branches / solution·edges / broader impact), drill-the-whys, an ELI ladder, a capability-gated quiz (shuffled, no early reveal), and a verifiable stop condition — every checklist item demonstrated, with a bounded defer/abandon escape hatch mirroring the open-todos rule. Ships to the public mirror like every canonical skill — Trellis publishes identical features to both private and public; the eleventh canonical skill.

### Changed

- **`scripts/onboard-project.sh`** — seeds the `orchestrate` skill symlink into both `.claude/skills/` and `.agents/skills/`, following the exact pattern used for the existing canonical skills. The two `untrack_if_tracked` lists and the skill-summary comments are updated in lockstep.
- **`core-rules/inheritance.md`** — the canonical skill count is bumped from nine to ten; `orchestrate` is named alongside the existing skills with the historical count preserved.
- **`scripts/onboard-project.sh`** — seeds the `debrief` skill into both `.claude/skills/` and `.agents/skills/`, and **fixes a pre-existing seed gap**: `execute` and `brainstorming` were carried in the `untrack_if_tracked` lists but never seeded on either surface, so every freshly-onboarded project silently missed them. The version sentinel and skill-census comments are bumped to the 11-skill set in lockstep. (Per the design decision, the seed-gap fix is folded into the `debrief` change and called out here so the bundle is explicit.)
- **`core-rules/templates/project.gitignore.fragment`** — adds the `debrief` symlink entries and bumps the `10-skill set` → `11-skill set` sentinel so it matches the onboard matcher (a stale sentinel would have made the fragment append on every re-onboard).
- **`README.md` / `core-rules/inheritance.md`** — skill census bumped to eleven (private and public ship the same set); `debrief` named in the inline lists, the skills table, and the architecture-tree comment.

## [v1.0.0-rc] — 2026-06-03

**The process-enforcement program — Trellis's first release candidate. The system could already detect drift (the audit fleet), enforce at the turn (hooks), and gate the merge boundary (pre-push), but enforcement was not uniform: a rule could be wired in one harness and missing in the other, or gated at one layer and not the layer that mattered. This release is a thirteen-phase pass that makes every rule fire the same way across both harnesses (Claude Code and Codex) and all three enforcement layers (skills, hooks, gates), then rolls the result out to all seven registered projects and verifies it with a two-tier health check.** The matrix is feature-complete and fleet-deployed; 1.0.0 follows after a few weeks of audit-fleet soak.

### Added

- **`reread-guard` — PreToolUse hook, both harnesses.** Blocks an edit to any file the agent has not read in the current session, the failure mode where an edit lands on stale lines because the file changed underneath the agent or it is working from a two-turn-old mental model. Shipped with `track-read` (records reads) and `stamp-turn` (the per-turn clock the guard reads); the trio lands atomically so a project can never end up half-wired.
- **`execute` — the canonical builder skill.** The load-bearing build step that turns an approved plan into commits without stepping outside the process, emitting the machine-readable `dod-receipt` marker the Stop hooks check. Resolves identically in Claude Code (`.claude/skills/`) and Codex (`.agents/skills/`).
- **Cross-harness pre-push merge gate.** One canonical gate that runs the same `process-gate` check regardless of how a project wires its hooks (husky for Node projects, native `.githooks/` for the rest), replacing per-project wiring that had drifted into three different behaviors. `scripts/sync-merge-gate.sh` re-points each project at the canonical gate safely, skipping any project that carries a custom pre-push it does not recognize rather than overwriting it.
- **Brownfield settings reconciliation.** `scripts/sync-hooks.sh` now wires the canonical `.hooks` block into an existing `settings.json` via `scripts/lib/settings-hooks-merge.sh`, a preserving merge that applies the canonical wiring and re-appends any project-specific hook entry the canonical set does not carry (verified on the monorepo project, whose hand-tuned module-boundary hook survives). The hook-resolution logic is shared with `scripts/lib/prepush-target.sh`.
- **`propose-rules` Stop hook, default-on.** Scans a finished edit-heavy turn for correction signals and proposes a single `gotchas.md` candidate; never blocks.
- **Two-tier doctor preconditions.** `scripts/doctor.sh` Tier 0 now gates on the canonical control plane itself (on main, clean, in sync with origin, doc-path conformance, VERSION-matches-CHANGELOG, receipt-grammar present) before Tier 1 walks every project's inheritance. Green across both tiers is the fleet-wide proof the matrix is intact.

### Fixed

- **`hc_prepush_wired_runall` honors `core.hooksPath`** (PR #97). The check probed only `.husky/pre-push` and `.git/hooks/pre-push`, so native-git-hooks projects (`core.hooksPath=.githooks`) were mis-reported as having no merge gate despite a correctly-wired one. It now resolves the hook git actually runs, keyed on `core.hooksPath`, with a red-green `doctor.bats` case.
- **Reviewer `claude -p` hardened** (DL-SEC-01). The code-review subagent no longer runs with `--dangerously-skip-permissions`; the diff review runs under normal permissions.

## [v0.9.0] — 2026-06-02

**Disk janitor — a single unscoped `turbo.json` `outputs[]` glob (`.next/**` with no `!.next/cache/**` negation) caused turbo to re-archive the entire `.next` tree on every run, accumulating 148 GB over two days on one fleet machine before the disk filled; this release adds a report-first host CLI that scans the fleet for reclaimable build caches, stale worktrees, and package stores, a daily launchd report agent, and an always-run doctor tripwire for the recurring misconfiguration — nothing ever auto-deletes.** ADR: `docs/adr/2026-06-02-disk-janitor.md`.

### Added

- **`scripts/disk-janitor.sh` + `scripts/lib/disk-janitor-lib.sh` — the `trellis disk-janitor` host CLI.** A host operation, not a scheduled-task audit: the audit sandbox cannot measure the real host filesystem, so disk reclamation lives on the host. Scans the active fleet (`registry.md` minus `blacklist.md` minus `disk_janitor.skip_projects`) across three scopes — build caches (`.turbo/cache`, `.next/cache`, `.next/dev`), stale `git worktree` checkouts, and package stores. `--report` (default) prints a human report and writes `audits/YYYY-MM-DD-disk-janitor.md` with a tripwire (free space vs floor, largest cache vs ceiling) and a recurrence pre-pass flagging unscoped-`turbo.json` landmines; `--dry-run` prints the exact deletion plan (per-row human bytes + why-safe, worktrees with their gate verdict) and mutates nothing; `--apply` confirms **per category** (mandatory `y/N` unless `--yes`) before deleting. Flags: `--project <name>`, `--scopes caches,worktrees,stores`, `--yes`, `--help`. **Never auto-deletes** — every deletion path requires a `--dry-run` preview into a confirmed `--apply`. Cache prune refuses any path not resolving under `PROJECTS_ROOT` and ending in a known cache basename; a build is guarded by a running-process check so an active `.next`/`.turbo` is never reaped. A worktree is reaped only when all four gates hold: non-main, older than `worktree_stale_days`, working tree clean (untracked included), and verified-merged. Merge detection avoids `git branch --merged` (blind to the fleet's squash-merge history) — it checks `gh pr list --head <branch> --state merged` then a `[gone]` remote-tracking signal after `git fetch --prune`, and reports an **unverified** branch as a candidate that is never reaped (fail-safe over fail-blind). Bash 3.2, shellcheck-clean; the deletion functions carry explicit guards reviewed line-by-line. `scripts/trellis` dispatches `disk-janitor` alongside `doctor`/`worktree`.
- **Launchd report agent + installer.** `core-rules/templates/org.trellis.disk-janitor.plist` (label `org.trellis.disk-janitor`) runs `trellis disk-janitor --report` daily off-peak via `StartCalendarInterval`, `RunAtLoad` false, logging under the user home. **Report-only — the agent never runs `--apply`.** `scripts/install-disk-janitor-launchd.sh` renders the template with the real `TRELLIS_ROOT`/home substituted, installs into `~/Library/LaunchAgents/`, reloads idempotently, and supports `--uninstall`. Turns the silent-accumulation failure mode into a daily `audits/` artifact so the next runaway cache surfaces days before a full disk.
- **`scripts/lib/health-checks.sh` `hc_turbo_outputs` — report-only doctor guard.** New Tier-1 per-project check wired into `scripts/doctor.sh`: for a project whose `turbo.json` carries the unscoped-`outputs` glob, returns `HC_WARN` and prints the canonical one-line fix (`!.next/cache/**` + `!.next/dev/**` negations); no turbo.json or already-scoped → `HC_OK`. **Report-only — deliberately gets no `doctor --fix` action**: `turbo.json` is a user-owned project file and doctor never auto-edits user-owned files (the same boundary that keeps `--fix` from rewriting a project's `CLAUDE.md` `@`-import). The fix-hint string has one source of truth in the disk-janitor library so the doctor message and the CLI's recurrence pre-pass cannot drift. Minimal additive edit to the 962-line `doctor.sh`; doctor's existing checks and `--fix` machinery are untouched.
- **`disk_janitor` config object** — optional block in `scripts/lib/trellis.config.schema.json` (not in `required[]`, so absence still validates) with an example in `core-rules/templates/trellis.config.json.example`. Keys + defaults: `enabled` (true), `cache_ttl_days` (14), `worktree_stale_days` (30), `free_space_floor_gb` (30), `cache_ceiling_gb` (20), `skip_projects` (`[]`). A clone with no `disk_janitor` block runs on the defaults.
- **Fail-closed `core-rules/` sync-coverage pre-flight** — `scripts/sync-to-template.sh` now aborts before staging if any `core-rules/<name>/` subdir is neither published (listed in `SYNC_PATHS`) nor explicitly kept private (listed in the new `CORE_RULES_NO_SYNC` register). SYNC_PATHS is a positive allowlist with no completeness check, so a newly-added subdir could be silently dropped from the public template — the exact failure that bit PR #78 (`core-rules/githooks/` missing, mirror lacked the new git hook). The check runs in every mode including dry-run, names each unclassified subdir with an actionable message, and is covered by `scripts/tests/sync-coverage.bats`. Logic lives in the pure, sourceable `scripts/lib/sync-coverage.sh`.

## [v0.8.0] — 2026-06-02

**Worktree inheritance seeding — `git worktree add` silently loses all Trellis inheritance (parent rules, 7 skills, 5 commands, presets, `.agents` mirror) because gitignored symlinks are never recreated in a new worktree; this release adds a four-trigger seeder that mirrors the main checkout's inheritance symlinks into every linked worktree, ensuring no project ever fails silently.** ADR: `docs/adr/2026-06-02-worktree-inheritance.md`.

### Added

- **`scripts/seed-inheritance-symlinks.sh`** — idempotent core seeder. Enumerates the inheritance symlinks already present in the project's main checkout (the symlinks `onboard-project.sh` created) and recreates each at the same relative path with the same target in the target worktree. Mirrors rather than re-derives the list, so it owns no symlink inventory and cannot drift from onboard; new skills, presets, and `.agents` entries are covered automatically with no seeder change. Interface: `[--target <dir>] [--root <dir>] [--quiet] [--verify-only]`; exit `0` all present/created, `1` missing (verify-only) or hard error; never aborts its caller for a single bad symlink. Root resolved from the main checkout's `.claude/rules/trellis.md` symlink target — machine-local, teammate-safe on every clone.
- **`core-rules/githooks/post-checkout`** — eager post-checkout hook (thin, harness-agnostic). Fires on `git worktree add` (and branch switches, where seeding is idempotent + cheap): detects a linked worktree via `git rev-parse --git-common-dir` vs `--git-dir`; seeds only in a linked worktree; always `exit 0` so seeding failure never aborts the worktree creation. Installed only on projects whose `core.hooksPath` points at a **tracked** directory — native-`.githooks` projects (the Unity project, the polyglot monorepo) and plain-git. **Not installed on husky projects**: husky v9 sets `core.hooksPath=.husky/_` and `.husky/_/.gitignore` is `*` (husky-generated), so `.husky/_` never materializes in a linked worktree — any hook placed there is dead (verified live on the monorepo project). `onboard-project.sh` gains one additive step: installs the hook for native-hooks projects; the symlink phase is untouched.
- **`scripts/worktree.sh` + `trellis worktree` subcommand** — the universal eager front door, stack-independent. `trellis worktree add <path> [git-args...]` runs `git worktree add` then calls the seeder on the new path; `trellis worktree sync [<path>]` re-seeds an existing worktree (default `$PWD`). Works on every project, including husky projects where the eager git hook is dead. Discoverable via `trellis help`.
- **`scripts/lib/health-checks.sh` `hc_worktree_inheritance`** — new Tier-1 doctor check. Enumerates `git worktree list` for the current repo; for each linked worktree runs the seeder in `--verify-only` mode and reports any missing core inheritance symlinks. `doctor --fix` (gated by the existing Tier-0 canonical-on-main guard) runs the seeder on each offending worktree.
- **SessionStart worktree safety-net** — when `session-context.sh` detects it is running inside a linked worktree with missing inheritance symlinks: (1) runs the seeder (repairs for the *next* session — skills are enumerated at process init before SessionStart hook filesystem changes land, so the current session cannot be healed, verified); (2) emits a loud `additionalContext` warning naming the gap and instructing the operator to restart. Converts the silent-drop failure mode into a visible, self-repairing event for any worktree born without the eager hook (e.g. a husky project on raw `git worktree add`, or a pre-ship clone).

### Changed

- **`core-rules/hooks/session-context.sh`** (+ codex mirror `core-rules/codex/hooks/session-context.sh`) — gained the worktree detect/seed call: at session start, checks whether cwd is a linked worktree and if so runs `seed-inheritance-symlinks.sh --verify-only`; on failure, runs the seeder and emits the loud restart warning. Guard is a no-op outside of linked worktrees and in fully-seeded worktrees.
- **`scripts/onboard-project.sh`** — one additive step: after the symlink phase (untouched), installs `core-rules/githooks/post-checkout` into the project's hook home when the hook home is a tracked directory (native-hooks projects only); husky and plain-git detection logic selects the correct install path or skips as described above.

## [v0.7.2] — 2026-05-31

**Settings-wiring doctor check tolerates project extensions.** `trellis doctor`'s per-project settings check no longer false-positives on projects that legitimately extend their `.claude/settings.json`.

### Changed

- **`scripts/lib/health-checks.sh` `hc_settings_wiring`** — was an exact `.hooks` block match, which flagged any project that added its own wiring (e.g. the monorepo project's project-specific `check-module-boundary.sh` PreToolUse hook, or a bumped `stop-verify` timeout) as drift. Now uses **superset semantics**: each settings file is flattened to `(event, matcher, command)` wirings and the check warns only when a **canonical** wiring is *absent* from the project — extra project hooks and differing timeouts are allowed. Missing wirings are named in the message. Backward-compatible: projects that exactly match the template still pass.

## [v0.7.1] — 2026-05-31

**Package-manager-agnostic hooks + tooling-baseline doctor check.** Hooks that run project scripts no longer assume a package manager, and `trellis doctor` now guards the non-login-shell toolchain regression that bit the fleet twice. Motivated by the 2026-05-31 incident: git hooks run in a non-login shell, resolved Homebrew Node 26 (no pnpm) instead of the nvm Node 24, silently breaking enforcement (see `gotchas.md` 2026-05-31).

### Added

- **`trellis.config.json.package_manager`** (new, optional; schema in `scripts/lib/trellis.config.schema.json`). Resolution: project-local `<project>/.trellis.config.json.package_manager` → fleet `trellis.config.json.package_manager` → `"auto"`. `"auto"` (the default when the key is **unset**) is byte-identical to the previous lockfile detection (`pnpm-lock.yaml`→pnpm, `bun.lock(b)`→bun, `yarn.lock`→yarn, `package-lock.json`→npm), so this key is **purely additive** — no behavior change for any existing consumer, npm projects included. The npm fallback is preserved.
- **`core-rules/hooks/lib/pm.sh`** — shared resolver (`trellis_resolve_pm`, `trellis_pm_available`), auto-propagated to projects via `sync-hooks.sh`. Codex mirror at `core-rules/codex/hooks/lib/pm.sh`. Mirrored (by deliberate anti-coupling) in process-gate `common.sh` (`pg_resolve_pm`) and inlined in `husky/pre-push` (git-level hooks cannot reliably source the synced lib).
- **`scripts/doctor.sh` `== Tooling baseline ==` section** — flags any tool present interactively but missing in a non-login shell (the exact incident signature) and any registered project whose `.nvmrc` major diverges from the running Node. WARN-only — dev-env hygiene, never gates inheritance. New check `hc_tooling_noninteractive_path` in `health-checks.sh`.
- **`engineering-process.md` §13.4 "Local toolchain baseline"** — codifies the machine-level baseline that is otherwise untracked (Node 24 via nvm, the `~/.nvm/default-node` symlink + `~/.zshenv` PATH prepend for non-login shells, standalone pnpm, brew Node kept-but-shadowed as a `summarize` dep, `.nvmrc`-hint vs loose `engines.node`-floor split) + the `gotchas.md` 2026-05-31 root-cause entry.

### Changed

- **`core-rules/hooks/stop-verify.sh`** (+ codex mirror) — the test step's hard-coded `npm test --silent` is replaced by the resolved package manager (`<pm> run test`); a configured-but-absent manager makes the step **skip** rather than hard-fail. This was the one site that ran `npm` regardless of a project's actual manager — wrong on the all-pnpm fleet.
- **`core-rules/husky/pre-push`** — package-manager resolution made config-aware (inlined resolver mirror); `run_script` simplified to `"$PM" run`; added a `command -v "$PM"` guard so a missing manager skips typecheck/test instead of blocking the push.
- **`core-rules/skills/process-gate/scripts/check-tests.sh`** — inline lockfile detection replaced by `pg_resolve_pm` (now config-aware). Invocation form unchanged.

## [v0.7.0] — 2026-05-30

**`trellis doctor`** — a deterministic, on-demand inheritance health-check + repair command that unifies the existing check and fix engines behind one front-end and runs (read-only) after every update. Motivated by two 2026-05-30 drift incidents: a project (`the multi-frontend app`) silently running with zero parent rules (no rules symlink, dead cross-machine `@`-import), and the canonical checkout left on a feature branch silently feeding *every* project stale rules. ADR: `docs/adr/2026-05-30-trellis-doctor.md`.

### Added

- **`scripts/lib/health-checks.sh`** — shared deterministic check library (single source of truth for "what healthy looks like"). Pure functions taking explicit path args (no cwd assumptions); Tier-0 functions probe the canonical clone via `git -C "$TRELLIS_ROOT"` resolved from config, never the caller's cwd. Status codes `HC_OK/HC_ERROR/HC_WARN/HC_INFO`.
- **`scripts/doctor.sh`** — the engine. Read-only by default: Tier-0 global preconditions (canonical on `main` + clean — ahead-of-origin is normal, behind is at most INFO; conformance-check passes; VERSION/CHANGELOG coherent) and Tier-1 per active project (rules symlink resolves to canonical, `@`-import resolves + matches, skills/commands/harness-artifact symlinks, hook + settings drift, version-pin lag). Per-project `✓/⚠/✗` table + deduplicated suggested actions; exit `0` healthy, `1` on ERROR, `2` on bad args. `--project <name>` scopes to one project.
- **`scripts/doctor.sh --fix [--dry-run] [--fix-hooks]`** — repairs by delegating to the idempotent never-clobber treatments (`onboard-project.sh` + a bounded `rm` of known-bad trellis-managed symlinks). `--dry-run` prints the per-project repair plan and mutates nothing. Hook re-sync is gated behind `--fix-hooks` (it changes enforcement behavior). Dead `@`-imports, `settings.json` drift, and Tier-0 issues are reported as manual-only — never auto-editing a user-owned file or the canonical clone.
- **`docs/UPGRADING.md`** — agent-followable upgrade runbook. Leads with the Tier-0 canonical-on-`main` precondition and encodes the two incident lessons (verify canonical-is-on-main before trusting inheritance; resolve symlink targets rather than assuming).
- **`core-rules/commands/doctor.md`** — `/doctor` slash-command (read-only by default; repair only when asked).
- **`scripts/trellis`** — thin dispatcher (`trellis doctor | onboard | upgrade | sync`) so "trellis doctor" reads naturally.

### Changed

- **`scripts/upgrade.sh`** — after a successful `--opt-in` pin adoption, auto-runs `doctor` read-only and prints the exact `--fix` command on drift. Check-only (never mutates projects), exit-neutral for the adoption itself, degrades gracefully if `doctor.sh` is absent (`TRELLIS_SKIP_DOCTOR=1` escape hatch for CI).
- **`engineering-process.md`** — new §14.6 "Updating Trellis" (the canonical upgrade sequence + `doctor` as the verification gate), distinct from §14.5's version-pin machinery. Following §14.x subsections renumbered; live cross-references updated.
- **`scheduled-tasks/cross-project-process-audit/prompt.md`** — runs `scripts/doctor.sh` first for the deterministic inheritance/symlink/hook checks, focusing the audit's LLM judgment on what a script cannot mechanically check.
- **`scripts/conformance-check.sh`** — `SPEC_DOCS` extended to validate the new docs' inline path references.

## [v0.6.5] — 2026-05-29

Opus 4.8 prompting best-practices incorporation. Anthropic's consolidated [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) guide (Opus 4.8 release) was gap-analyzed against Trellis; the guide largely *validates* the existing regime, so the change set is small and targeted. ADR: `docs/adr/2026-05-29-opus-4.8-prompting-best-practices.md`. **Version note:** `feat/antigravity-third-harness` merged first and claimed `v0.6.0`; per that overlap's documented carve-out the later release re-versions, so this Opus 4.8 work ships as `v0.6.5`.

### Added

- **`docs/opus-4.8-steering.md`** — Opus 4.8 steering reference: the deltas between Anthropic's guide and Trellis, plus a reusable prompt-snippet library (overengineering, investigate-before-answering, parallel tool calls, default-to-action, hard-code-to-tests, code-review coverage, short frontend snippet, model identity), each mapped to the Trellis surface that already implements it. Verbose snippets live here rather than in the always-injected parent `CLAUDE.md`.
- **`docs/adr/2026-05-29-opus-4.8-prompting-best-practices.md`** — records what was incorporated, what was deliberately skipped (API-only mechanics, forced `alwaysThinkingEnabled`, the deprecated long pre-4.8 frontend snippet), and the restraint rationale on parent-rule bloat.

### Changed

- **`core-rules/templates/claude-settings.json` — `"effortLevel": "xhigh"`.** The guide's highest-value 4.8 lever. Verified against the Claude Code [model-config docs](https://code.claude.com/docs/en/model-config): `effortLevel` is a real settings field (`low|medium|high|xhigh`; `max` and `ultracode` are session-only and rejected there). Opus 4.8's Claude Code default is `high`; `xhigh` is recommended for coding/agentic work and degrades to `high` on models without it (Sonnet 4.6, Opus 4.6), so the template is fleet-safe. Reaches a project on its next scaffold or settings re-sync; existing projects are unaffected until then.
- **`core-rules/CLAUDE.md` — three surgical rule deltas.** (a) Code quality: no speculative defensive code — validate only at system boundaries, trust internal callers and framework guarantees. (b) Debugging: never claim anything about code you haven't opened; read a referenced file before answering, not after. (c) Context management: noted that Opus 4.8 *under*-dispatches subagents and tools by default (the reverse of 4.6's over-spawning), so the existing dispatch triggers must be honored even when inlining feels easier, and independent tool calls batched in one message. Each delta changes behavior beyond text already present; everything else the guide recommends as a parent-rule line was already in place.
- **`core-rules/autonomy.md` — "Opus 4.8 alignment" section.** Documents that the L1–L5 slider is the guide's `<default_to_action>` ↔ `<do_not_act_before_instructions>` spectrum expressed as a setting, and that the bright-line guardrails implement its balancing-autonomy-and-safety advice (confirm before destructive / shared / external actions; never `--no-verify` as a shortcut).
- **`engineering-process.md`** — §8.6 testing bar gains a general-solutions / don't-hard-code-to-tests rule; §14.3 gains "write rules for the current model" (4.8 literalism → explicit scope, positive > negative examples, sparing `CRITICAL:`/`MUST`); §5.2 gains a code-review coverage-not-filtering note; References lists the steering doc.
- **`core-rules/hooks/code-review-subagent.sh` — reviewer-prompt guidance in the header contract.** The hook is the filter (`severity == "critical"` blocks, the rest advisory); the project-local reviewer should be prompted for coverage, not filtering — report every finding with severity and an optional confidence. Comment-only; the hook's behavior is unchanged (it remains an unwired skeleton).
- **`scripts/sync-to-template.sh` — public-mirror parity.** SYNC_PATHS extended so the public template reaches full 0.6.0 parity, publishing formerly instance-only artifacts: `core-rules/autonomy.md`, `core-rules/presets/`, `recon.md`, `docs/opus-4.8-steering.md`, and the autonomy design spec. The `2026-05-08` meta-audit stays private (it maps per-project security gaps); its lone example citation in `references/secrets.md` was genericized so no synced spec doc dangles on it.

## [v0.6.0] — 2026-05-20

Add AntiGravity (Google's `agy` CLI / standalone Antigravity 2.0 desktop app)
as Trellis's third first-class harness. Shares the existing `AGENTS.md` +
`.agents/{rules,skills,primers}/` inheritance surface with Codex (rules and
skills are byte-identical between the two engines); adds AntiGravity-specific
`.agents/workflows/*.md` slash-command symlinks. **AntiGravity native hook
integration is deferred** — public docs as of 2026-05-20 do not describe a
workspace hook envelope and the standalone desktop app's Customizations panel
does not expose hooks UI; Tier-1 and Tier-2 enforcement on AntiGravity
sessions relies on parent rules + skills + Tier-3 git hooks until the API
ships.

### Added

- **`antigravity` admitted to the `harnesses` enum** in
  `scripts/lib/trellis.config.schema.json`. `scripts/lib/config-load.sh`'s
  jq-fallback error message updated to list all three canonical values.
- **Three-gate onboarding shape in `scripts/onboard-project.sh`.** The
  former Codex-only `if pg_has_harness codex` block is refactored into
  (a) shared `.agents/` surface gated on `codex || antigravity`,
  (b) Codex-only `.codex/` + `.agents/commands/` block,
  (c) AntiGravity-only `.agents/workflows/{primer,primer-refresh,primer-check,explore}.md`
  symlink block. Untrack-legacy and Next-echo blocks updated to match.
- **Rollout scripts honor the shared-surface gate.**
  `scripts/rollout-process-gate-skill.sh`,
  `scripts/rollout-feature-skills.sh`, and `scripts/rollout-presets.sh` all
  change their inner Codex gate to `codex || antigravity` for `.agents/`
  artifacts. Codex-only assets (hook envelope, `commands/` slash commands)
  remain Codex-gated.
- **Branch-name regex extension.**
  `core-rules/skills/process-gate/scripts/check-pr.sh` adds `antigravity` to
  the allowed branch-name prefix regex; the doc at
  `core-rules/skills/process-gate/references/pr-hygiene.md` is updated to
  match, in one commit (cross-file consistency risk).
- **Gitignore fragment carries four new workflow symlinks.**
  `core-rules/templates/project.gitignore.fragment` adds
  `.agents/workflows/{primer,primer-refresh,primer-check,explore}.md`. The
  sentinel header bumps to include `antigravity workflows`; the
  `current_sentinel` literal in `scripts/onboard-project.sh` updates in
  lockstep so re-onboarding is idempotent.
- **Example config and template heredoc updated.**
  `core-rules/templates/trellis.config.json.example` shows
  `["claude", "codex", "antigravity"]`. `scripts/sync-to-template.sh`'s
  embedded comment mentions AntiGravity alongside Codex.
- **Documentation sweep.** `README.md` Codex/AntiGravity setup section + harness bullets + requirements;
  `AGENT_ONBOARD_PROJECT.md` Step 2 + Step 3 + Step 7 verification block; `engineering-process.md` §3,
  §3.2, §5.5 (now tri-harness matrix), §10.3 first-commit checklist;
  `core-rules/inheritance.md` Multi-harness section (now covers three
  harnesses) plus new "Known gap: AntiGravity native hooks deferred"
  subsection.
- **ADR.** `docs/adr/2026-05-20-antigravity-third-harness.md` records the
  decision to admit AntiGravity now and defer hooks, modeled on the
  2026-05-04 Codex parity ADR.
- `core-rules/VERSION` 0.5.0 → 0.6.0 (minor bump — new canonical surface).

### Known gap

- **AntiGravity native hooks not implemented.** Public docs as of 2026-05-20
  do not describe a workspace hook envelope, and the standalone Antigravity
  2.0 desktop app does not expose hooks UI. Tier-1 and Tier-2 enforcement
  on AntiGravity sessions is not available; rules + skills + Tier-3 git
  hooks remain in effect. Gap surfaced in `core-rules/inheritance.md`
  "Known gap" subsection, this CHANGELOG entry, the `onboard-project.sh`
  final-echo block when antigravity is enabled, and the new ADR. Re-evaluate
  when Google publishes a workspace hook API.

## [v0.5.0] — 2026-05-20

MEDIUM-severity remediation pass against `audits/2026-05-08-se-core-meta-audit.md`. Eleven items triaged; six required code or doc changes, three verified already closed, two CI workflows brought back to green. New parked rule lifted from the n=2 `gotchas-rollup` clusters.

### Added

- **`core-rules/deferred.md` — "Code-asset pairing rule" entry (n=2).** From `audits/2026-05-01-gotchas-rollup.md`: the RAG service shipped a TS rename in `apps/api-gateway/src/lib/openapi.ts` without regenerating the checked-in `docs/api/02-openapi.yaml`; the Unity project authored MonoBehaviours in `Assets/Scripts/` without wiring them into `Assets/Scenes/SampleScene.unity`. Both failed only at runtime / integrity-test time; static checks (typecheck, build, lint) were blind to the drift. Parked as an n=2 candidate with graduation criterion "a third project independently reports a bug whose root cause is a code change landing without its paired non-code artifact" — phrasing of the eventual lift (narrow "regenerate generated artifacts" vs. broader "code-asset pairing" invariant with per-project hooks) deferred to the n=3 instance.
- **Bats coverage for the MEDIUM hook + process-gate fixes.** New `core-rules/hooks/tests/session-context.bats` (11 cases — gotchas regex against heading / status-field / bold-tag positives, free-text negatives, Codex parity, 5K-log injection size sanity). New `core-rules/skills/process-gate/tests/` directory with `check-pr-subject.bats` (8 cases including `codex:` and audit-closure for `!` / empty-scope), `check-bypass.bats` (6 cases for active-bypass config detection), `check-secrets.bats` (5 cases for the locator-rewrite). Both suites run from `bats core-rules/hooks/tests/` (45/45 pass) and `bats core-rules/skills/process-gate/tests/` (19/19 pass).

### Changed

- **Collapsed three sources of truth for the canonical hook manifest into two by-design sources.** Audit §2.3 flagged that `scheduled-tasks/parent-hook-drift/prompt.md` inlined the full hook+event+matcher table while `engineering-process.md` §5.2 carried a parallel narrative table and `core-rules/templates/claude-settings.json` was the actual deployment. Three edits to add a hook. Now: `core-rules/hooks/README.md` is the authoritative inventory (names + tiers + origin), and `core-rules/templates/claude-settings.json` is the authoritative event/matcher wiring. `parent-hook-drift/prompt.md` no longer duplicates the manifest — it enumerates canonical scripts from `core-rules/hooks/*.sh` at audit-runtime and iterates the template's `hooks` block for the registration check (with a new finding shape for "canonical manifest disagreement between disk and template" when those drift). `engineering-process.md` §5.2 keeps its narrative "Responsibility" column but gains a preamble citing README.md + template as canonical, marking the table as non-authoritative narrative. Adding a hook is now two edits (README.md + settings.json template) plus an optional narrative row; the audit prompt requires no change.
- **`core-rules/hooks/session-context.sh` and `post-compact-context.sh` — context-log read windows reconciled with documented rationale (audit §2.1).** Session-start budget raised from `head -c 800` to `head -c 1200` (cap is the hook's own 2000-char `additionalContext` ceiling; 1200 leaves room for the branch + commits + gotchas sections that share the budget). Post-compact rehydration budget raised from `head -c 4000` to `head -c 8000` (no overall cap there; `save-context-log.sh` regularly emits 6–10K of branch + open-todos + transcript snippets, so 4K was undersized). Inline comments at each `head -c <N>` document the rationale + cross-reference the other hook's value. Codex parity copies updated.

### Fixed

- **Gotchas "unresolved" detector no longer false-positives on free-text (audit §2.1).** `session-context.sh:73` was `grep -inE 'unresolved'` — case-insensitive substring match anywhere on a line, so prose like "this issue is now resolved (was unresolved on …)" tripped the detector. New regex anchors to line-start and matches ATX headings (`## Unresolved`, `### Unresolved gotchas`), bold status tags (`**unresolved**`), or status fields (`Status: unresolved`). Codex parity copy patched. Bats fixtures in `session-context.bats` cover the three positive shapes and the free-text negative.
- **`check-pr.sh` commit-subject regex now allows the `codex` type (audit §2.2).** Branch-name regex on line 24 already accepted `codex/<slug>`; the subject regex on line 35 did not. A commit `codex: foo` would fail the gate even though `codex/foo` was a valid branch. One-line fix adds `codex` to the leading alternation. Audit's original concerns about `!` breaking-change marker and empty scope were verified CLOSED by the new bats fixture (`feat!: bang` passes, `fix(api)!: scoped bang` passes, `feat(): empty` fails).
- **`check-bypass.sh` now detects active `core.hooksPath` / `commit.gpgsign` bypasses (audit §2.2).** New §3a: `git config --get core.hooksPath` returning `/dev/null` / `/dev/zero` / empty-after-set fires a fail-level finding "core.hooksPath: actively set to disable hooks". New §3b: `git config --get commit.gpgsign` returning `false` fires a warn-level finding "commit.gpgsign: actively disabled via persistent config" (warn, not fail — many projects legitimately disable signing). One-shot bypasses (`git -c commit.gpgsign=false commit`, `git commit --no-gpg-sign`) leave no trace post-hoc and are documented as undetectable in an inline comment block — only branch-protection or pre-commit trapping can catch them.
- **`check-secrets.sh` collapsed the per-pattern-hit O(N×M) diff re-walk (audit §2.2).** The locator that resolved each pattern hit to `file:line` re-ran `git diff --no-color --unified=0 "$RANGE"` per hit, walking the full diff once per match. Now a single awk pass builds a `<file>\t<lineno>\t<content>` lookup table in a `mktemp` temp file; per-hit resolution becomes a single `awk -F'\t' -v h="$hit" 'index($3, h) {print $1":"$2; exit}'` against the small temp file. Bash 3.2-portable (no `declare -A`, no `mapfile`). Trap on EXIT preserves the script's exit code. Wall-clock benchmark on a 1K-line diff with 49 distinct secrets: ~290ms vs ~455ms before (~37% faster); on the audit-named 5K/1-secret case the table-build overhead slightly dominates the savings (~135ms vs ~118ms) — the improvement only manifests when hit count grows, which is the audit's scaling concern. Pre-existing bash-3.2 empty-array bug in `is_allowed` (which crashed the script under `set -u` when the allowlist file was absent and any finding had a non-empty `file`) fixed inline.
- **Shellcheck CI gate green again.** Three warnings on `main` blocking the workflow: `scripts/rollout-presets.sh:162` (SC2155 declare-and-assign), `scripts/rollout-presets.sh:225` (SC2010 ls-pipe-grep), `scripts/onboard-project.sh:229` (SC2034 unused `harness_dir` in `seed_presets()`). Fixed in place; `shellcheck --severity=warning` over the workflow's full `find` invocation now exits 0.
- **Conformance CI gate green again.** Five missing-reference findings on `main`: `engineering-process.md:526` brace `web-{perf,a11y,seo,agent-readiness}.md` and `monorepo-polyglot.md:205` brace `core-rules/husky/{commit-msg,pre-push}` rewritten as individual inline-code paths (all eight target files exist); `monorepo-polyglot.md:246` references to `docs/adr/0001-slice-1-bundle.md` / `docs/adr/0002-slice-2-bundle.md` and `:288` reference to `docs/engineering/repo-structure.md` were prose pointers to the polyglot monorepo-external ADRs / docs not present in Trellis canonical — inline-code markers stripped to remove the false signal to the conformance checker while preserving the prose. Final scan: `clean (19 spec docs, 154 refs scanned)`.

### Verified

Three MEDIUM items were checked against current code and confirmed already closed by earlier remediation cycles. Documented for the audit ledger; no code changes required.

- **Duplicated repo-root helpers (audit §2.1).** P3.5 (v0.1.0) extracted `_se_repo_root` into `core-rules/hooks/lib/deps.sh:50-61` and re-sourced it from `session-context.sh`, `save-context-log.sh`, `post-compact-context.sh` on both harnesses. Grep confirms no inlined `__se_repo_root` definitions remain — every hook reads through the shared lib.
- **Process-gate PR-size lockfile handling (audit §2.2).** `check-pr.sh:56-66` already iterates the diff file list, calls `pg_is_lockfile` (defined in `scripts/lib/common.sh`) per file, and subtracts the lockfile add/del lines from the countable total. Documented as a §1.2 win in the original audit; verified still in force.
- **Remediation-report filename convention (audit §2.3).** P3.8 (v0.1.0) documented the 4-class taxonomy in `scheduled-tasks/README.md:152-166`. Convention: `YYYY-MM-DD-<source-audit>-remediation.md`. `audits/2026-04-27-cross-project-process-audit-remediation.md` follows the convention; `audits/2026-04-27-three-audits-remediation.md` is grandfathered as a multi-source rollup. The `-remediation.md` suffix is load-bearing for `audit-report-rollup` parsing.
- **`core-rules/hooks/README.md` — `inject-primer-index.sh` added to the Tier 1 table.** The v0.3.1 backfill (PR #66) added the hook on disk and wired it into `core-rules/templates/claude-settings.json` and the inline manifest of `scheduled-tasks/parent-hook-drift/prompt.md`, but missed updating the Tier 1 table in `core-rules/hooks/README.md`. This is exactly the kind of canonical-manifest disagreement the v0.5.0 source-of-truth consolidation surfaces — caught and closed in the same release. Tier 1 table now lists all six Tier-1 hooks including `inject-primer-index.sh`.

## [v0.4.5] — 2026-05-20

Autonomy slider — L1–L5 responsibility-slider that controls *who answers* Trellis's interactive gates (user vs. agent) at each gate-hit. Default L3 = current behavior; all gates and quality controls remain mandatory at every level. Independent feature scope from v0.4.0 (rule calibration / audit sweep) — slotted as a minor bump.

### Added

- **Autonomy slider (L1–L5, default L3).** Five-level responsibility slider that controls who answers Trellis's interactive gates — user (lower) or agent (higher). All gates and quality controls fire at every level; the level only changes *who decides*. L1 Pedagogical (ask + explain), L2 Cautious (ask with recommendation), L3 Standard (current behavior), L4 Initiative (single plan-approval, batched questions, architectural decisions still inline), L5 Autonomous (silent decision-making + decision log). Bright-line guardrails (hard hooks, destructive ops, external messages, secrets, DoD receipts, code-review subagent) remain mandatory at every level; PR creation flexes. Architectural decisions surface inline mid-turn even at L5 (reversibility cliff). Defaults to L3 ⇒ no regression for existing projects.
- **`core-rules/autonomy.md`** — canonical level matrix, guardrail list, resolution algorithm, decision-log schema. Imported by `core-rules/CLAUDE.md` via cross-reference.
- **`/autonomy N` slash command** at `core-rules/commands/autonomy.md` — validates 1–5, resolves preset ceiling, clamps with one-line warning if needed, writes `<canonical-root>/.claude/session-autonomy` (gitignored), acknowledges. Session-scoped; survives `/compact` and worktree boundaries.
- **`scripts/lib/trellis.config.schema.json`** gains `autonomy_default` (fleet, 1–5) and `autonomy` (project-local override, 1–5) fields. Both optional. Schema-validated by ajv when available, jq-fallback otherwise.
- **Preset frontmatter** — `compliance-strict.md` declares `autonomy_ceiling: 2` (audit-grade discipline requires human-in-the-loop). `experimental-loose.md` declares `autonomy_ceiling: 5, autonomy_default: 4` (throwaway work; decisions cheap to undo). `core-rules/presets/README.md` documents the new optional frontmatter fields.
- **`<canonical-root>/decisions-log.md`** — new agent-authored file at the canonical project root capturing decisions made at L4/L5. Append-only by agent during turns. Renders into end-of-turn message + PR description body (when PR is created). Separate file (NOT inside `context-log.md`) so it survives `save-context-log.sh`'s overwrite cycle on every PreCompact. Git-tracked by default; storage policy documented in `core-rules/autonomy.md`.
- **`core-rules/hooks/session-context.sh`** extended to inject `Level: L<n> (<name>)` into the session-start context block. At L4/L5, also injects the last 10 entries from `decisions-log.md`. Bats test suite at `core-rules/hooks/tests/session-context-autonomy.bats` (6 tests).
- **`core-rules/hooks/code-review-subagent.sh`** reads autonomy level + passes `decisions-log.md` content as part of the reviewer JSON payload `{diff, autonomy_level, decisions_log}`. At L4/L5 the reviewer is expected to flag implicit decisions present in the diff that are missing from the log.
- **`core-rules/skills/process-gate/SKILL.md`** — code-review subagent prompt at L4/L5 gains a decision-log-completeness clause: implicit decisions present in the diff but missing from the log are flagged as findings. Incomplete logs are no longer free.
- **`scheduled-tasks/autonomy-drift/`** — new weekly audit (Mon 11:30, ahead of preset-drift at 12:00). Flags silent L4/L5 (decisions missing on edit-heavy weeks), chronic override (config probably under-set), ceiling friction (repeated clamp events), schema issues. Read-only; remediation through config edits.
- **`scripts/show-config.sh`** — pretty-prints resolved autonomy level (after fleet + project + session + clamp), active presets with their ceilings/defaults, approved_mcps list. Discoverability without a UI; the deferred UI/TUI work is parked.
- **ADR** at `docs/adr/2026-05-20-autonomy-slider.md`; design spec at `docs/specs/2026-05-20-trellis-autonomy-design.md`; implementation plan at `docs/plans/2026-05-20-trellis-autonomy.md`.
- **`engineering-process.md` §14.8** — narrative for the autonomy slider (why it exists, layers, guardrails, decision log, audit, references).

### Changed

- **`core-rules/CLAUDE.md`** — new `## Autonomy` section cross-referencing `core-rules/autonomy.md`. No behavior change at default L3.
- **`scripts/onboard-project.sh`** — symlinks `core-rules/commands/autonomy.md` into project `.claude/commands/` and `.agents/commands/`. Sentinel bumped to `7-skill set + presets + primer/explore/autonomy commands`.
- **`scripts/rollout-presets.sh`** — `--dry-run` output now surfaces each preset's `autonomy_ceiling` / `autonomy_default` so operators see ceiling clamps at-a-glance.
- **`core-rules/templates/trellis.config.json.example`** — example carries `autonomy_default: 3` with a comment explaining the levels.
- **`core-rules/templates/project.gitignore.fragment`** — gitignores `.claude/session-autonomy` (per-developer state).
- **`core-rules/VERSION`** bumped to `0.4.5` (additive, no breaking change since default L3 preserves current behavior).

### Notes for operators rolling out v0.4.5

- After pulling v0.4.5 into a Trellis clone, run `scripts/sync-hooks.sh --apply` to propagate the extended `session-context.sh` and `code-review-subagent.sh` into registered projects. Without this, the autonomy level + decision-log injection only fires inside the canonical clone.
- Existing projects that want the `/autonomy` slash command available locally should re-run `scripts/onboard-project.sh <project>` (it now symlinks `core-rules/commands/autonomy.md` into `.claude/commands/` and `.agents/commands/`).
- Presets gained `autonomy_ceiling` / `autonomy_default` frontmatter. If your project declares `compliance-strict` or `experimental-loose`, no action needed — the rollout-presets script reads the frontmatter live.

### Implementation note (one-off)

The 20-task plan was executed via the superpowers:subagent-driven-development skill. On ~half the tasks classified as mechanical (single-line edits, pure-prose markdown), the standalone spec-compliance and code-quality reviewer subagents were skipped — the implementer's report plus controller-side bash verification (jq/grep/bats) served as the spec compliance check, and there was no separable code-quality surface beyond what spec compliance covered. Full review machinery ran on substantive code tasks (hook extensions, shell scripts, audit prompts). This was a one-off speed compromise; do not treat it as a new convention for future plans.

## [v0.4.0] — 2026-05-20

Rule calibration for the modern Claude 4.7 / Sonnet 4.6 era plus a 17-audit
sweep confirming the audit backlog is clean. Two behavioral shifts in the
parent layer (context thresholds at 500K-effective-ceiling; parallel-subagent
rule reframed around wall-clock speed and context-isolation), one residual
hook bug fixed, and explicit verification that every prior audit's
Trellis-repo-scoped finding has been resolved.

### Changed

- **Rule calibration for 500K effective context ceiling.** Nominal context is 1M for Opus 4.7 / Sonnet 4.6, but model performance degrades past ~500K — rules now anchor on the empirical limit. Threshold updates across `core-rules/CLAUDE.md`, `engineering-process.md`, `recon.md`, `core-rules/hooks.md`, `security-gate-plan.md`, `scheduled-tasks/obsolete-rules/prompt.md`, plus both Claude and Codex `truncation-check.sh` copies: re-read trigger moved from "after 10+ messages" to "when ctx use ≥40% OR after 25 messages, whichever first"; chunked-read threshold raised from `>500 LOC` to `>1500 LOC`; tool-result truncation threshold raised from `50K` to `100K`; refactor phase cap raised from `max 5 files` to `max 7 files`. Compact-trigger stays env-var configured at 500K for Claude models (no rule change required). Subagent-dispatch threshold (`>5 files`) deliberately preserved — the value is right for the new framing (see next entry).
- **Parallel-subagent rule reframed: speed + context-isolation, not context-bloat avoidance.** `core-rules/CLAUDE.md` and `engineering-process.md` §8.3 now lead with wall-clock parallelism and fresh-context-per-subagent quality, not with cost or main-context-bloat rationale. The cost frame (Anthropic's published "multi-agent costs 10-15× tokens, start single") is a public-API stance for production volume; interactive personal-project development wins on latency and per-subagent context isolation. Triggers unchanged: ≥2 independent searches/fetches/analyses, >5 files, edit-heavy turns. Removed the now-redundant "Token cost is real" follow-up sentence at `core-rules/CLAUDE.md:30` that contradicted the new framing.

### Fixed

- **`code-review-subagent.sh` doc-only skip was too broad.** The previous skip pattern `grep -vE '\.(md|mdx|rst|txt)$|^docs/'` skipped *any* file under `docs/` regardless of extension, so non-doc files like `docs/scripts/setup.sh`, `docs/examples/app.ts`, and `docs/data.json` were wrongly classified as docs and the code-review subagent never fired on them. Pattern tightened to `(^|/)[^/]+\.(md|mdx|rst|txt)$` — only the final path segment's extension decides "doc," so a doc anywhere in the tree still counts as a doc and a non-doc under `docs/` no longer slips through. Applied to both Claude (`core-rules/hooks/code-review-subagent.sh`) and Codex (`core-rules/codex/hooks/code-review-subagent.sh`) variants.

### Verified

- **17-audit sweep (2026-04-26 → 2026-05-11): all Trellis-scoped findings closed.** Direct file-level verification confirmed every critical defect from prior audits is already resolved in tree:
  - `audits/2026-05-08-se-core-meta-audit.md` — six criticals all closed: jq-missing guard via `core-rules/hooks/lib/deps.sh:19-28` (`_se_require_jq` with `TRELLIS_NO_JQ_DEGRADE=1` escape hatch); `block-destructive.sh:45` rm-rf regex tail rewritten to match through whitespace/EOL; `block-destructive.sh:71-72` DELETE-without-WHERE inverted-regex fixed (line 70 comment documents the prior broken `[^;]*$` form); `stop-verify.sh:102-118` runs the TodoWrite check before the dirty-tree skip at line 120-131 (inline comment documents the deliberate ordering); `save-context-log.sh:91-95` JSONL parser filters to `(.message.content | type) == "string"`, excluding tool-result array wrappers; `scripts/onboard-project.sh:193-207, 391` defines and calls `seed_claude_hooks()`.
  - `audits/2026-05-02-dep-major-upgrade-watch.md` — TypeScript / Vite / Unity watchlist bumps already landed: `scheduled-tasks/dep-major-upgrade-watch/watchlist.md` carries TypeScript `^6` (was `~5.7`), Vite `^8` (was `^7`), Unity `6000.4 LTS` (was `2022.3 LTS`).
  - `audits/2026-04-26-parent-hook-drift.md`, `audits/2026-04-27-cross-project-process-audit.md`, `audits/2026-04-27-three-audits-remediation.md`, `audits/2026-04-28-bypass-tripwire.md`, `audits/2026-05-01-audit-rollup.md` — all closed; remediation work landed downstream and on-canonical between 2026-04-27 and 2026-05-11.
  - `audits/2026-05-11-sync-tool-rca.md` — closed; sync-hooks provenance breadcrumbs + worktree-source warning + `--from-main-only` opt-in shipped in `scripts/sync-hooks.sh`.
  - `audits/2026-05-01-dep-currency.md`, `audits/2026-05-01-dep-vulnerabilities.md`, `audits/2026-05-01-dep-major-upgrade-watch.md` — sandbox-skipped runs only (host-execution required); no findings to action.
  - `audits/2026-05-01-gotchas-rollup.md` — first monthly rollup proposed one deferred-rule candidate (code-asset pairing, n=2); deferred for separate work since adding it is process-improvement, not defect-resolution.
  - `audits/2026-04-27-registry-blacklist-health.md`, `audits/2026-04-27-test-health.md` — closed for Trellis scope; the remaining test-health open item (4 Node projects fail at module load in linux-arm64 sandbox vs darwin-arm64 `node_modules`) is scheduled-task MCP configuration, not Trellis-repo code.
- **Pre-existing remediations re-confirmed in tree.** Several fixes from prior internal remediation work that had not been explicitly audited-against-current-code since landing were re-verified during this sweep (see `audits/2026-05-08-se-core-meta-audit.md` defect list above). No drift detected.

## [v0.3.1] — 2026-05-19

Primer freshness loop. Makes the v0.3.0 primer system close the loop on
updates and usage without per-turn LLM cost.

### Added

- **`inject-primer-index` SessionStart hook (both harnesses).** Deterministic
  shell hook reads `<canonical-root>/.claude/primers/INDEX.md`, computes
  drift per primer (FRESH / WARM / STALE / MISSING_PATHS / UNREACHABLE_PIN
  / BROKEN / NO_ENTRY_POINTS) via `git rev-list <pinned>..HEAD -- <entry-points>`,
  and injects a compact ~300-token INDEX-with-flags block into every session.
  Skips silently when INDEX absent (opt-in projects unaffected). Wired in
  `core-rules/templates/claude-settings.json` and `core-rules/codex/hooks.json`
  alongside `session-context.sh` and `post-compact-context.sh`. Bats
  coverage at `core-rules/hooks/tests/inject-primer-index.bats` (7 cases).
  Added to the `parent-hook-drift` canonical manifest (now Ten canonical hooks).
- **`primer-drift` Tier-1 scheduled task.** Weekly Monday 12:15 (after
  preset-drift). Same checks as the SessionStart hook, fleet-wide, one
  audit file per run. Backstop for projects no one's touched recently.
  `scheduled-tasks/primer-drift/{prompt.md,targets.md}`. Scheduled-tasks
  README count bumped to Sixteen.
- ADR `docs/adr/2026-05-19-primer-freshness-loop.md` documenting the
  SessionStart-injection + weekly-backstop architecture and rejected
  alternatives (post-commit LLM hook, PostToolUse dirty-marker, eager-
  load every primer).

### Changed

- **Parent `core-rules/CLAUDE.md` Feature-primers block:** "lean toward
  loading" → "MUST read primer when task names a primer-listed
  feature/dir". Auto-injection means INDEX is always in context; the rule
  shifts "available" → "used". Loading policy line updated:
  agent-decides → auto-injected (since v0.3.1).
- `core-rules/VERSION` 0.3.0 → 0.3.1.

### Note on landing path

This v0.3.1 entry was written on 2026-05-19 and synced to the public mirror
(`Zireael26/trellis@v0.3.1`) but the corresponding private commits were lost
when `chore/v0.3.1-primer-freshness-loop` was reset to `origin/main` instead
of merged. Backfilled into the private trellis-instance repo on 2026-05-20
alongside the v0.4.0 release; the public mirror tag was already correct.

### Notes for operators rolling out v0.4.0

- After pulling v0.4.0 into a Trellis clone, run `scripts/sync-hooks.sh --apply` to propagate the extended `session-context.sh` and `code-review-subagent.sh` into registered projects. Without this, the autonomy level + decision-log injection only fires inside the canonical clone.
- Existing projects that want the `/autonomy` slash command available locally should re-run `scripts/onboard-project.sh <project>` (it now symlinks `core-rules/commands/autonomy.md` into `.claude/commands/` and `.agents/commands/`).
- Presets gained `autonomy_ceiling` / `autonomy_default` frontmatter. If your project declares `compliance-strict` or `experimental-loose`, no action needed — the rollout-presets script reads the frontmatter live.

### Implementation note (one-off)

The 20-task plan was executed via the superpowers:subagent-driven-development skill. On ~half the tasks classified as mechanical (single-line edits, pure-prose markdown), the standalone spec-compliance and code-quality reviewer subagents were skipped — the implementer's report plus controller-side bash verification (jq/grep/bats) served as the spec compliance check, and there was no separable code-quality surface beyond what spec compliance covered. Full review machinery ran on substantive code tasks (hook extensions, shell scripts, audit prompts). This was a one-off speed compromise; do not treat it as a new convention for future plans.

## [v0.3.0] — 2026-05-18

Anthropic large-codebase best-practices bundle plus the late-2026-05 follow-ups
(frontend-quality references, Codex `[features].hooks` rename, brand-sweep
cleanup, Obsidian dep retire). Tagged on the public mirror at
`Zireael26/trellis@v0.3.0`.

### Added

- **Anthropic best-practices bundle — ten changes mapping the Claude blog onto Trellis.** Ten commits land the changes from the 2026-05 Anthropic "How Claude Code works in large codebases" guide that Trellis didn't already cover. Grouped into three phases:
  - **Phase 1 (quick wins).** (1A) `permissions.deny` baseline in `core-rules/templates/claude-settings.json` covering `node_modules`, `.next`, `dist`, `build`, `out`, `target`, `vendor`, `.venv`, `__pycache__`, every cache dir, and every lockfile, plus a new `scripts/rollout-settings.sh` that jq-merges canonical + project-local entries idempotently. New projects pick it up via `onboard-project.sh`; existing projects converge via the rollout script. (1B) Mandatory `## Codebase map` section in project `CLAUDE.md` for any project with ≥5 top-level directories — one line per top-level dir, role only; sub-threshold projects skip the section. Convention added to `engineering-process.md` §9.1 and the `AGENT_ONBOARD_PROJECT.md` Step 4 playbook. (1C) New quarterly `obsolete-rules` audit (Q1/Q2/Q3/Q4 1st 09:00). Walks `core-rules/CLAUDE.md`, presets, `engineering-process.md`, and every project `CLAUDE.md` + `gotchas.md`; classifies each rule as load-bearing / model-compensating / harness-compensating / stylistic / process; surfaces model-or-harness-compensating rules that have aged out of usefulness. Removal-only audit — never proposes additions; gotchas-rollup retains promotion ownership.
  - **Phase 2 (monorepo scoping).** (2D) `stop-verify.sh` is now subtree-aware: when every changed file in a turn sits under one subdirectory carrying its own manifest (`package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`), the hook `cd`s into that subtree before typecheck / lint / test. Mixed-subtree changes and missing nested manifests fall back to repo root. Escape hatch: `PROCESS_GATE_FORCE_ROOT=1`. Patched in both Claude and Codex parity copies. (2E) Optional `scope.json` convention for project-local skills — `{ "paths": ["services/**"], "reason": "..." }` next to a non-canonical `SKILL.md` limits auto-invocation to matching paths. Engine-unenforced; agent-followed via `core-rules/CLAUDE.md` directive. Canonical skills stay global. (2F) `cross-project-process-audit` extended with check 10: warning when a ≥5-top-level-dir project lacks a `## Codebase map` heading; info when the heading exists but the list is stub-only; warning when the listed dirs no longer exist.
  - **Phase 3 (subagent + LSP + governance).** (3G) New `/explore <subsystem>` canonical slash command — read-only subagent maps a subsystem and writes the summary to `<canonical-root>/.claude/primers/_explore/<slug>-<sha>.md`; editing session loads it before touching code. Ephemeral counterpart to `/primer`. Symlinked into `.claude/commands/` and `.agents/commands/` by `onboard-project.sh`; sentinel bumped to "7-skill set + presets + primer/explore commands". (3H) LSP recommendation for polyglot projects added to `engineering-process.md` §8.3 — install per-language LSP binaries (`gopls`, `typescript-language-server`, `pyright`, etc.) plus a Claude Code LSP plugin for ≥2-language repos. Recommendation only; no audit, no hook coupling. (3I) New experimental Tier-2 hook `propose-rules.sh`. Opt-in via `PROCESS_GATE_PROPOSE_RULES=1`. Dispatches a one-shot `claude -p --max-turns 1` subagent at end of turn to read transcript tail + project `gotchas.md` and propose a single candidate entry (or `NONE`). Three layers of cost control: opt-in gate, `stop_hook_active`/pure-chat guards, and a transcript-tail heuristic that only fires the subagent when an explicit-correction signal ("no", "don't", "actually", "stop doing", "that's wrong", "never do") appears in the last ~200 lines. Pairs with `gotchas-rollup` (monthly) — propose-rules surfaces n=1 candidates per turn; the rollup clusters n≥3 into parent-rule promotions. `parent-hook-drift` accepts absence of a settings.json entry for experimental hooks. (3J) Optional `approved_mcps` field added to `scripts/lib/trellis.config.schema.json` and the example config — array of `{ name, purpose, scope: "fleet" | "per-project" }` entries. Documentation-only today; reserved for a future parked `mcp-drift` audit. Sized for solo-DRI use: explicit allowlist now, audit when n=2 projects diverge.
- **Frontend-quality references bundle** — four sibling reference docs at `core-rules/skills/process-gate/references/web-{perf,a11y,seo,agent-readiness}.md`, synthesizing Lighthouse (Performance, Accessibility, Best Practices, SEO, Agentic Browsing), web.dev Learn Accessibility / pa11y / axe-core, Google's AI Optimization Guide, and Cloudflare's `isitagentready.com` scorecard into a single Trellis-stamped checklist. Closes the previously-empty frontend-guidelines slot (gate #6 in `process-gate/SKILL.md:36` is the destination for any future automation). Three-way disagreement on `llms.txt` between Google (debunks), Lighthouse Agentic Browsing (rewards), and Cloudflare (rewards implicitly) explicitly resolved in `web-agent-readiness.md` — Trellis adopts `llms.txt` as a hedge for projects with substantive public docs and skips the speculative WebMCP / MCP-card / x402 / UCP / ACP protocol layer until n=2 ships an agent-served API. a11y tool stance is **axe-core canonical, pa11y fallback for static-HTML projects** — matches the single-app project's existing project-local `check-a11y.sh`; rationale (WCAG 2.2 support, Deque-maintained, Chrome DevTools Issues panel, `@axe-core/react`, shared rule engine with Lighthouse) documented in `web-a11y.md`. Automation (Lighthouse CI, axe-core in CI) remains deferred per `core-rules/deferred.md:57` until Rule of Three; the new references cite that deferral so future agents don't accidentally promote prematurely. Wired in via one cross-profile section appended to `stack-profiles.md` and a new §9.6 in `engineering-process.md`. No parent `CLAUDE.md` edit, no new skill / command / hook / scheduled audit / primer. Capture date 2026-05-16; `web-perf.md`/`web-seo.md`/`web-a11y.md` re-verify semi-annually, `web-agent-readiness.md` quarterly (fastest-shifting axis).

### Changed

- **Codex feature-flag rename: `[features].codex_hooks` → `[features].hooks`.** Codex CLI 0.129+ emits a deprecation warning when it sees `[features].codex_hooks` in `$CODEX_HOME/config.toml`; the canonical key is now `[features].hooks`. The legacy key still works as an alias but should not be used in new installs. Doc references updated across `README.md`, `AGENT_ONBOARD_PROJECT.md`, `engineering-process.md` (§5a hook-tier section and §10.3 onboarding checklist), `core-rules/inheritance.md`, and the `scripts/onboard-project.sh` post-onboarding echo. Each touch points new operators at `hooks = true` while noting the alias for users who still have the legacy key in their config. The bash function name `seed_codex_hooks()` (script-internal — copies `.codex/hooks/*.sh`) is unaffected — it describes a category of hooks, not the deprecated TOML key.
- **Retired Obsidian dependency from the `monthly-documentation-audit` description.** The the monorepo project-scoped monthly doc audit in `scheduled-tasks/README.md` no longer claims to check "Obsidian sync" — the audit covers EPM currency and ADR coverage; doc-write target is the project filesystem (already mounted), so the MCP path is unnecessary overhead.
- **Brand sweep follow-ups.** `security-gate-plan.md` had three stale "SE Core" / `se-core` mentions left over from the 2026-05-12 rebrand (§1 purpose paragraph, §3 infrastructure reuse line, §11 per-project flow); all three now read "Trellis" / "Trellis instance". Historical references in `CHANGELOG.md` (rebrand entry), audit filenames under `audits/`, ADR PR URLs at `Zireael26/se-core`, and `scripts/rollout-rebrand.sh` (whose purpose is the migration itself) are intentionally preserved.


### Added

- **Feature primer system — canonical `commands/` slot + opt-in primer infra.** A primer is a compact, hand-validated context document (~150 lines max) pinned to a commit SHA. Future sessions read the primer instead of re-exploring the feature — the goal is replacing 350K-token exploration runs with 30–50K-token primer-assisted runs for testing, debugging, and extending stable features. Three new canonical commands at `core-rules/commands/{primer.md,primer-refresh.md,primer-check.md}` — first occupants of the new `core-rules/commands/` distribution slot, parallel to `core-rules/skills/`. Templates at `core-rules/commands/templates/{primer-template,primer-index-template}.md`. Reference docs at `docs/primers/{plot-md-integration,handoff-integration}.md`. Parent `core-rules/CLAUDE.md` gains a `## Commands` section and a Feature primers block (cascades to all managed projects via `@`-import — no per-project CLAUDE.md edits required). `scripts/onboard-project.sh` extended to symlink the three commands into `.claude/commands/` and `.agents/commands/` (Codex parity) and seed an empty `.claude/primers/INDEX.md` (copied, not symlinked — primer INDEX is project-state and tracked in git, individual primers too). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets + primer commands)`; covers the three new symlinked commands per harness while explicitly preserving primer content files. `scripts/sync-to-template.sh` SYNC_PATHS gains `core-rules/commands/` and `docs/primers/`. Primer files resolve via `git rev-parse --git-common-dir` (canonical-root convention, same pattern as `context-log.md`) so worktree sessions see the same primer set as the main checkout. The three context-log hooks remain untouched. Opt-in per project: projects without `.claude/primers/INDEX.md` skip primer logic entirely. Forward-looking integrations (`active_primers:` in local `plot.md`, post-commit refresh hooks) documented in `docs/primers/` but not implemented in this phase. Each preset is a single markdown file at `core-rules/presets/<name>.md` that layers on top of the parent rules. Two example presets ship: `compliance-strict` (mandatory ADR per architectural change, two-human PR sign-off, no `--no-verify`, hard-fail secrets, mandatory CHANGELOG, deploy SHA encoding) and `experimental-loose` (direct commits to main, skip the spec-kit pipeline, optional CHANGELOG, PR-size warn-only, test coverage optional; time-bound). Projects opt in via the `presets` array in their own `<project>/.trellis.config.json`. Schema (`scripts/lib/trellis.config.schema.json`) carries an optional `presets` field with kebab-case validation + uniqueItems. Per-project preset selection is read directly by `onboard-project.sh` and `scripts/rollout-presets.sh` from each project's own `<project>/.trellis.config.json` — not via the parent `config-load.sh` loader (presets are a per-project concept). `scripts/rollout-presets.sh` (new, idempotent) installs the declared symlinks under `.claude/rules/preset-<name>.md` and `.agents/rules/preset-<name>.md` and prunes ones no longer declared. `onboard-project.sh` extended with `seed_presets()` (no-op when no project-local config). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets)`; covers `preset-*.md` symlinks via glob. `scheduled-tasks/preset-drift/` runs weekly (Mon 12:00) catching declared-vs-installed mismatches across the registry. Narrative documentation: `engineering-process.md` §14.7 + `core-rules/inheritance.md` extended with the skills-vs-presets symmetry table. (spec-kit Phase D, plan: `docs/plans/2026-05-12-spec-kit-adoption.md`)

### Changed

- **Repo rebrand: SE Core → Trellis.** Full sweep across config files, env vars, JSON keys, scripts, scheduled-tasks prompts, core-rules docs, audit prompts, hook libs, husky pre-push, ADRs, and root docs. Highlights: `se-core.config.json` → `trellis.config.json` (with schema + example); JSON root key `se_core_root` → `trellis_root`; env vars `SE_CORE_ROOT`, `SE_CORE_CONFIG`, `SE_CORE_CONFIG_PATH`, `SE_CORE_TEMPLATE_DIR`, `SE_CORE_SKIP_SECURITY_BASELINE`, `SE_CORE_ALLOW_MAIN_PUSH`, `SE_CORE_NO_JQ_DEGRADE` → `TRELLIS_*`; in-project symlink `.claude/rules/se-core.md` → `.claude/rules/trellis.md` (existing projects re-linked by `scripts/rollout-rebrand.sh`); hardcoded `__USER_HOME__/projects/se-core/` paths → `__TRELLIS_PATH__/`; public mirror remote → `__GITHUB_USER__/trellis`; default `TRELLIS_TEMPLATE_DIR` → `$USER_HOME/projects/trellis`; brand text "SE Core" / "Software Engineering Core" → "Trellis" everywhere except (a) historical audit filenames under `audits/`, (b) the historical PR URLs in `docs/adr/0001-...md` (the legacy `__GITHUB_USER__/se-core` GitHub repo still resolves those references).

### Added

- **Versioning + upgrade flow (spec-kit Phase A)** — `core-rules/VERSION` is the canonical semver pin (initial value `0.1.0`). Optional `trellis_version` field added to `scripts/lib/trellis.config.schema.json` for downstream consumers to pin against. `scripts/upgrade.sh` compares the pinned version to the highest `v*.*.*` tag on `origin` (or `template.remote` fallback) and prints a stat diff of `core-rules/`; `--opt-in` rewrites the pin in config and revalidates against the schema; `--check` exits non-zero on drift for CI. `scheduled-tasks/version-drift/` runs weekly (Mon 11:45) classifying each project as current / no-pin / patch-drift / minor-drift / major-drift / ahead / malformed — only major-drift is critical. `core-rules/templates/trellis.config.json.example` is the first reference config template. `config-load.sh` exports `TRELLIS_VERSION`. `core-rules/VERSION` bumped from `0.1.0` to `0.2.0` on the rebrand commit; `v0.2.0` is the next release tag on the public mirror (`v0.1.0` was already taken by the 2026-05-08 meta-audit wrap-up). (spec-kit Phase A, plan: `docs/plans/2026-05-12-spec-kit-adoption.md`)
- **Eval harness runner** — `scripts/run-evals.sh` discovers fixtures under `core-rules/evals/<project>/<id>/`, invokes `claude -p` headless per fixture (n times each, default 5), evaluates `expected.json` assertions against `git status --porcelain` of the seed snapshot, and emits a pass-rate JSON. Supports `--check` (schema-only validation; no model invocation), `--dry-run`, `--filter <glob>`, and `--changed-only`. Workflow `.github/workflows/evals.yml` always runs `--check` on PRs and runs the full suite when `ANTHROPIC_API_KEY` is wired (deferred to P4.5). (P4.3)
- **Eval fixture schema** — `core-rules/evals/SCHEMA.md` is the canonical specification; `core-rules/evals/template/` is a real, executable reference fixture. Required manifest fields: `version`, `id`, `project`, `prompt`. (P4.1)
- **the monorepo project fixture set** — `core-rules/evals/the monorepo project/` ships 10 fixtures grounded in `audits/2026-04-26-parent-hook-drift.md` and `audits/2026-05-01-audit-rollup.md`: 6 install-canonical-hook regressions (block-destructive, post-edit-verify, stop-verify, truncation-check, ui-verify, code-review-subagent), 2 rebase-drifted-hook regressions (session-context, block-destructive), 1 husky pre-push-guard install, and 1 negative fixture protecting the project-local `check-module-boundary.sh`. Runner now passes `--add-dir <repo-root>` so fixtures can reference the live canonical via repo-rooted paths. (P4.2)
- **the single-app project fixture set** — `core-rules/evals/the single-app project/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push pattern as the monorepo project. Negative fixture protects the project's `CLAUDE.md` from being modified during hooks work. (P4.2)
- **the multi-frontend app fixture set** — `core-rules/evals/the multi-frontend app/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push/preserve-claude-md pattern as the monorepo project/the single-app project. (P4.2)
- **the RAG service fixture set** — `core-rules/evals/the RAG service/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push/preserve-claude-md pattern as the rest of the fleet. (P4.2)
- **the Unity project fixture set** — `core-rules/evals/the Unity project/` ships 10 canonical-conformance fixtures using the same install/rebase pattern. The pre-push fixture targets `.githooks/pre-push` (native git hooks) instead of `.husky/pre-push`, since the Unity project is a Unity project without husky per `core-rules/inheritance.md`. (P4.2)
- **the portfolio site fixture set** — `core-rules/evals/the portfolio site/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push pattern as the monorepo project. Negative fixture protects the project's `CLAUDE.md` from being modified during hooks work. (P4.2)

### Changed

- **audit-report-rollup picks up eval pass-rate** — `scheduled-tasks/audit-report-rollup/prompt.md` now reads `core-rules/evals/.results/<timestamp>.json` files and surfaces a per-project eval pass-rate table with 7-day trend. Implements the "promote rule changes only if pass-rate doesn't regress" guidance from audit §6 P4.4. Until `ANTHROPIC_API_KEY` is wired (P4.4a), the rollup emits a placeholder noting the harness shipped but runtime data is unavailable. (P4.4)
- **Pre-merge eval gate** — `.github/workflows/evals.yml` adds a `gate` summary job combining validate + run results into one status check. The job passes when validate succeeds and run either succeeded or skipped (no secret); fails when run failed (fixture regression). Maintainer wires `evals / gate` as a required status check on `main` per the P4.5 plan instructions. (P4.5)
- **`core-rules/CLAUDE.md`: drop stale `[new policy]` marker** — Definition of done section was tagged "[new policy]" when the receipts-required + Stop-hook-completion-guard rules first landed in 2026-04. Two weeks later, standing policy. First parent-rules edit shipped through the Phase 4 eval gate. (P4.6)
- **Eval schema** — flipped `bare:` default from `false` to `true` for reproducible runs (host isolation). Runner re-injects parent rules via `--append-system-prompt`. Added optional `max_budget_usd` field as per-run dollar cap. (P4.3)

### Fixed

- **Bats CI runner** — `.github/workflows/bats.yml` now configures a default git identity before invoking the suite. Without it, every `setup_project_dir` aborted with `fatal: empty ident name … not allowed` and all 34 tests failed. (P4.1a)
- **Shellcheck CI gate** — `.github/workflows/shellcheck.yml` runs at `--severity=warning` so info+style findings (SC1091 source-file not-following, SC2181 `$?` style, SC2016 single-quoted regex, etc., all intentional patterns) don't fail the gate. The four SC2295 (info) sites — unquoted `${var#$X/}` — are fixed in `scripts/onboard-project.sh`, `scripts/conformance-check.sh`, `scripts/rollout-process-gate-skill.sh`, `core-rules/skills/process-gate/scripts/check-bypass.sh`. (P4.1a)

## [v0.1.0] — 2026-05-08

First tagged checkpoint. Covers everything up to the close of the
2026-05-08 Trellis meta-audit remediation cycle (Phases 0–3 of
`audits/2026-05-08-se-core-meta-audit-plan.md`).

### Added

- **Security-gate skill** — `core-rules/skills/security-gate/` shipped through six phases per `security-gate-plan.md`:
  - Phase 1 — baseline engine + `web-next` profile (Semgrep + OSV-scanner + Gitleaks under a provider-neutral LLM triage layer; default backend: `simonw/llm`).
  - Phase 2 — diff mode + husky `pre-push` wiring; `scripts/onboard-project.sh` symlinks security-gate and runs initial baseline.
  - Phase 3 — quarterly `scheduled-tasks/security-baseline/` (host-pinned, fleet rollup with new/recurring/resolved deltas).
  - Phase 4 — `web-rag-llm` profile: prompt-injection + MCP-tool-misuse Semgrep rules; Garak wrapper.
  - Phase 5 — `unity-game` profile: C# rules covering PlayerPrefs credentials, save HMAC, BinaryFormatter, TLS bypass, hardcoded API keys, in-client IAP; project-local validator spec.
  - Phase 6 — Mode 3 red-team (`scripts/run-redteam.sh`, `prompts/redteam.md`, `references/redteam-runbook.md`) with per-run sign-off.
- **Codex parity** — root `AGENTS.md`, `.agents/` inheritance, canonical `.codex/` hooks, active-project rollout scripts. ADR documenting the oversized parent-layer Codex parity PR.
- **Schema + ADRs** — JSON schema for `trellis.config.json`; `docs/adr/0001-security-gate-stack-consolidation.md` (first ADR; size carve-out for the security-gate consolidation PR).
- **Onboarding installs Claude Tier 1+2 hooks** — `scripts/onboard-project.sh` now seeds `.claude/hooks/*.sh` and `.claude/settings.json` from a canonical template (`core-rules/templates/claude-settings.json`), mirroring `seed_codex_hooks`. (P2.1)
- **Bats regression suite** — `core-rules/hooks/tests/` covers the four Phase 1 hook fixes plus jq fail-closed across all 18 hooks; CI workflow `.github/workflows/bats.yml`. (P3.1)
- **Shared hook lib** — `core-rules/hooks/lib/deps.sh` exposes `_se_require_jq` (replaces the inline P1.5 block in 18 hooks) and `_se_project_dir`. `sync-hooks.sh` / `sync-codex-hooks.sh` / `onboard-project.sh` extended to ship the lib alongside scripts. (P3.5)
- **Self-hosted process-gate against the Trellis canonical clone** — `.claude/skills/process-gate-local/local.config.sh` declares the config stack profile so the gate runs cleanly on the Trellis canonical clone itself. First MERGEABLE verdict. (P3.4)
- **Prompt-shell linter** — `scripts/lint-prompt-shell-blocks.sh` + `.github/workflows/prompt-shell-lint.yml`: extracts ` ```bash` / ` ```sh` blocks from `scheduled-tasks/**/*.md` and `bash -n` syntax-checks each. (P3.9)
- **Audit file taxonomy** — documented 4-class taxonomy (regular audit, remediation report, plan, source audit) in `scheduled-tasks/README.md`; `audit-report-rollup` parser updated to treat each class separately. (P3.8)
- **Recon gap status snapshot** — `recon.md` Status as of 2026-05-08 table marks G1 shipped (TodoWrite-completion guard), G2/G3 skeleton, G4 policy + partial enforcement. (P3.11)
- **Six backfilled ADRs** under `docs/adr/`: bypass-tripwire weekday-only cadence, Tier 2 promotion criteria, test-health host-pinned vs. dep-sandbox walk-back, mypy regex bracket-escaping (fabricated-finding lesson), CLAUDE.md-primary-not-AGENTS.md (D1), rmrf-rule-absolute-outside-cwd (D3). (P3.10)
- **Spec-vs-impl conformance check** — `scripts/conformance-check.sh` + `.github/workflows/conformance.yml`: scans 14 spec docs for inline-code path refs, asserts each resolves at repo root or doc-relative. Current run: clean (114 refs, 0 misses). (P3.6)
- **Shellcheck CI** — `.github/workflows/shellcheck.yml` + `.shellcheckrc`. Resolved all 21 existing violations inline; new violations fail CI. (P3.2)
- **trellis.config.json schema validation on load** — `_pgcfg_validate()` in `scripts/lib/config-load.sh` tries `npx ajv` first, falls back to a jq-based check that enforces `required[]` + non-empty strings + `harnesses minItems=1`. Stripped configs error loudly with a list of missing fields. (P3.3)

### Changed

- Process-gate, onboarding, audits, and template sync now understand Claude Code plus Codex without dropping existing Claude Code hooks.
- `scripts/onboard-project.sh` — also symlinks `security-gate` (Claude Code + Codex paths) and runs the initial Mode 1 baseline at onboarding (`TRELLIS_SKIP_SECURITY_BASELINE=1` to opt out).
- `scheduled-tasks/parent-hook-drift/targets.md` — collapsed inline canonical hook list to single-source-of-truth reference (`core-rules/hooks/README.md` for names, `prompt.md` for matchers). Editing the canonical list now touches one file. (P3.7)
- `core-rules/hooks.md:21` — `block-destructive` rm-rf rule wording updated to "any **absolute path**, `~`, `$HOME`, or `..`" matching the post-P1.1 regex semantics. (P1.1 / D3)

### Fixed

- `core-rules/skills/process-gate/scripts/check-tests.sh` — replaced `[ ... ] && cmd` short-circuit with explicit `if`-block. Previous form returned non-zero from the `run_check` helper when `$worst` was already non-`pass`, which `set -e` propagated and aborted the gate before later checks ran.
- `core-rules/hooks/block-destructive.sh:42` — `rm -rf` rule now blocks absolute paths outside cwd (`rm -rf /Users/me/foo`, `rm -rf ~/work`, `rm -rf $HOME/cache`, `rm -rf ../sibling`). Earlier tail char-class missed any path beyond `/etc`-like roots. Allows `rm -rf .`, `rm -rf ./build`, `rm -rf node_modules`. (P1.1)
- `core-rules/hooks/block-destructive.sh:67-71` — DELETE-without-WHERE now triggers on terminated SQL (`DELETE FROM users;`). Earlier `[^;]*$` clause required no semicolon to EOL — the rule was dead code in production. Handles backticked / double-quoted / schema-qualified table names. (P1.2)
- `core-rules/hooks/stop-verify.sh` — TodoWrite check now runs **before** the dirty-tree skip. Pure-chat turns that close pending todos via TodoWrite no longer slip past the receipts-required guard. (P1.3)
- `core-rules/hooks/save-context-log.sh` — JSONL filter now distinguishes real user prompts (string content) from tool-result wrappers (array content with `tool_result` items). Adds envelope validation: `PROJECT_DIR` must be a directory and `transcript_path` (if present) must exist; loud failure on malformed envelope. (P1.4)
- **jq-missing now fails closed across all 18 hooks** — `if ! command -v jq; then exit 0` replaced with stderr install-help + `exit 1`. `TRELLIS_NO_JQ_DEGRADE=1` opt-out preserves graceful degradation with an audit-trail breadcrumb. (P1.5)

### Project-side (this loop session)

Per Phase 2's hook propagation + onboarding completeness work, the
following landed in fleet projects via per-project PRs: all 9 canonical
hooks + `settings.json` synced to the monorepo project, the single-app project, the portfolio site, the RAG service,
the Unity project; `.gitignore` discipline sweep on the single-app project / the RAG service / the portfolio site
(the multi-frontend app deferred — broken husky pre-push shim); ~25 leaked global
Anthropic skills removed from `the RAG service/.agents/skills/`; the portfolio site's
`.gitignore` `.claude/` over-ignore corrected to allow per-file
unignore.

### Notes

- Phase 4 (eval harness) is paused per plan decision D4 — requires
  explicit human go-ahead. Phase 5 (strategic adoption) is opportunistic.
- the multi-frontend app rollout-process-gate-skill PR remains deferred (P0.2a):
  branch conflicts with main + dirty local worktree blocks safe sync.

## Conventions

- One entry per change. Dated section header `## [YYYY-MM-DD]` when cutting a checkpoint.
- Sections: Added · Changed · Deprecated · Removed · Fixed · Security.
- Each entry links the canonical artifact path so future readers can navigate from changelog to source without searching.
