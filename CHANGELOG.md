# Changelog

All notable changes to Trellis are documented here.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project uses Conventional Commits. Versioning is rolling — entries are dated, not numbered, since Trellis is the meta-repo for personal projects rather than a published artifact.

## Unreleased

## [v1.0.0-rc.22] — 2026-07-31

**The operator-facing surfaces caught up with rc.20 and rc.21.** Both prior releases fixed
the reasoning and the internal runbook; neither reached the two documents a new operator
actually reads before certifying. The result was a published contract that described a
world two releases out of date.

`AGENT_ONBOARD_GPTX.md` §7 still said exit `2` meant Codex auth, quota, or cooldown — the
`UPSTR` classification rc.20 added for provider outages had no entry. It now names both
causes, states that the line prefix distinguishes them, and says where each one sends you:
`QUOTA` to billing and auth, `UPSTR` to the provider's status page. Folding them together
would have someone re-authenticating through an outage.

The same section listed six concerns but omitted the agent-slug check entirely — the one
that compares every `gpt-*` profile against the alias table of the **running** router
rather than the checkout's. That check exists because a router process older than the
checkout serves a profile whose alias it never loaded, and delegating to it returns
`502 unknown provider`. Undocumented, its failure reads as a broken agent definition.

### Added

- Day-one `unverified` guidance on both public surfaces. A freshly certified router
  reports `unverified` within hours with nothing wrong, because the `anthropic-beta`
  union grows with **session shape** — subagent, Skill, headless and background runs each
  send a different flag list — not only with upgrades. The published rule is now to
  re-certify **once after a day of ordinary sessions**, not on each drift notice. Without
  it the documentation drove exactly the behavior rc.21 was written to prevent.
- Troubleshooting rows for `UPSTR`, for a standing `unverified`, and for the
  `NOT CERTIFIED — every probe must pass first. Baseline left unchanged.` refusal, which
  is correct behavior rather than a fault: a baseline written off probes that never
  reached the model would certify nothing.

### Fixed

- Exit `2` semantics in the onboarding guide, which described only one of its two causes.
- The `--certify` check list, which omitted the agent-slug-versus-running-router probe.

## [v1.0.0-rc.21] — 2026-07-30

**Documentation caught up with rc.20, and `unverified` got an explanation.** rc.20 added a
third certification classification and a third reason to exit 2, but the published failure
contract still described only `QUOTA`. An operator reading the docs would have had no entry
for the case the release existed to handle.

Certifying also surfaced a benign drift report worth documenting rather than fixing. The
baseline records the `anthropic-beta` union as of the moment of certification, and that
union grows with **session shape** — headless runs, subagents, Skills and background tasks
each send a different flag list — not only with upgrades. So the first unobserved shape
after certification flips the router to `unverified` and prints "run `gptx-doctor
--certify`" with nothing wrong.

Measured on 2026-07-30: drift fired on `structured-outputs-2025-11-13` against a baseline
already holding `structured-outputs-2025-12-15` — an older-dated variant of a certified
family. Probed 4 runs per variant, 8/8 translated correctly, so the flag is not a
translation break. Notably the first single-shot comparison pointed the other way, which is
the same trap as diagnosing an outage from one probe.

The union is deliberately left **not** family-aware. Collapsing dated flags into families
would suppress precisely the signal the tripwire exists for, since a real capability change
can ship under an existing prefix. Noisier and honest beats quieter and wrong.

**The ops runbook named a launchd job that no longer exists.** The instance-private GPTX
runbook documented the router as `dev.gptx.router` in four places, including the
incident-time restart command.
The live job is `dev.trellis.gptx-router`; the older plist was found still installed on
2026-07-30 and renamed `.plist.disabled`. Following the runbook during an incident would
restart the wrong job — and with both installed, restart one while the other holds the port,
which is a fix that looks like it worked.

### Fixed
- `docs/gptx.md` failure table gains the provider-outage row (`UPSTR`, exit 2, no baseline
  recorded) and the post-certification drift row, and marks the existing `QUOTA` row exit 2.
- Instance-private runbook — router identity: correct launchd label, correct script path
  (`scripts/gptx/router.js`; `local/gptx-router.js` is a `require` shim, not what launchd
  runs), and the correct log path — the documented `~/.cli-proxy-api/logs/` subdirectory
  does not exist, and `log()` is `DEBUG`-gated so a healthy router writes almost nothing.
- Instance-private runbook — the exit-code section said exit 2 meant quota/cooldown only;
  it now names both causes and where each one sends the reader.
- Instance-private runbook — described `--certify` as "five probes". There are nine (0–8);
  the alias, advisor-bridge and credential-survival checks were missing.

### Added
- Instance-private runbook — guidance to re-certify **once after a day of ordinary
  sessions** rather than on each drift notice, with the rule for telling a benign union
  growth from a real upgrade break: a break is deterministic, provider flake is not.
- Instance-private runbook — records the checkout-update ordering rule, which was
  operational knowledge held nowhere in the repo. The main checkout feeds two consumers on different
  schedules — `~/.claude/agents/*.md` symlink into its working tree and are re-read live,
  while the router `require`s `scripts/gptx/router.js` from the same tree and node caches it
  at load. Advancing the checkout therefore moves every agent instantly and the router not
  at all; the gap is a window where agents declare a slug the running router 502s, which is
  how `gpt-terra` broke fleet-wide. Advance, then kickstart, back to back — restarting first
  reloads the same old code.

## [v1.0.0-rc.20] — 2026-07-30

**A provider outage no longer reads as a broken upgrade.** `gptx-doctor` sorted every
non-success GPT probe into `QUOTA` or `FAIL`. An OpenAI service error matched neither, so
it fell through to `FAIL` and exit 1 — the code reserved for *an upgrade broke the
translation surface*. During a live outage this pointed the operator at their own diff for
a problem entirely on the provider's side.

The failure does not look like a failure. CLIProxyAPI forwards OpenAI's 503 as an in-band
SSE error frame on an **already-200** response: HTTP is 200, `message_start` has been
emitted, and only the absence of the expected block separates it from a genuine break.

### Added
- Third probe classification `UPSTR`, kept deliberately distinct from `QUOTA`. Both mean
  the translation surface went untested, but they send a reader to different places —
  `QUOTA` to billing and auth, `UPSTR` to the provider's status page. Folding them would
  have someone auditing a Codex subscription during an OpenAI outage.
- `scripts/tests/gptx-doctor-classify.bats` (11) pins all four classifications and, more
  importantly, the branch order in both directions: an outage signature must not report
  `FAIL`, and a complete-but-wrong stream must still report `FAIL`. A classifier widened
  without a test holding its edges is how a gate quietly stops gating.
- `GPTX_DOCTOR_LIB_ONLY` guard so the classifier can be sourced without firing eleven
  probes at a live router, matching `core-rules/hooks/lib/spec-gate-core.sh`.

### Changed
- The advisor probe now correlates against the router's own advisor failure count. When
  the advisor's upstream fails, the router behaves correctly — 503, error payload,
  recorded failure — but the CLIProxyAPI fork turns that into an **empty**
  `advisor_tool_result` and finishes the stream cleanly, leaving no error signature in the
  body at all. The probe reports the bridge as UNTESTED rather than passing or failing it.
- `UPSTR` joins the `--certify` refusal guard. A baseline recorded during an outage would
  be written off probes that never exercised tool translation.

### Known issue
- Mid-stream errors are not retried, and this is correct rather than missing: once
  `message_start` is forwarded on a 200 the response is committed, and replaying it would
  mean lying to the client about what it already received. Recovery belongs to the caller.

## [v1.0.0-rc.19] — 2026-07-30

**GPTX becomes optional (spec 028).** GPTX assumed the operator held both a Claude and a
Codex subscription. Most users hold one, and for them the cross-family doctrine was worse
than dead weight — it was doctrine they could not satisfy. `model-routing.md` stated a
≥40% cross-family mix as a *requirement* and named `gpt-*` profiles as the routing target
for five task classes; `core-rules/CLAUDE.md`, which loads in every session of every
project, pointed at all of it unconditionally.

The machinery was already opt-in — spec 020 built the router behind an installer and no
hook depends on it. The **doctrine** was not, and that is what this fixes.

### Added
- `gptx` block in `trellis.config.json` and its schema. Default **off**; absent, `false`,
  and malformed all resolve to off. Off is the safe direction: it can only withdraw an
  instruction to use a lane, never invent one.
- `core-rules/references/model-routing-cross-family.md` — the quarantine target for
  two-subscription doctrine (near-parity table, the mix quota, `gpt-*` rows, the Terra
  throughput tier), opening with its switch predicate.
- `scripts/tests/gptx-switch.bats` (15) and `scripts/tests/gptx-off-state.bats` (10). The
  latter asserts the off-state as a deterministic property rather than a promise.
- `/__gptx/status` now reports `aliases[]`, and `gptx-doctor` compares every `gpt-*`
  agent's declared `model:` against what the **running** router serves.

### Changed
- `model-routing.md` reduced to single-family doctrine, including the single-family form
  of never-self-review: a fresh-context subagent, since the cross-family reviewer is not
  available. The rule changes shape rather than lapsing.
- One shared config reader serves both `mandatory_pipeline` and `gptx`. The two consumers
  read a `false` differently on purpose — for a gate, closed means blocking; for a feature
  handing out routing instructions, closed means off.
- `core-rules/CLAUDE.md`: two unconditional pointers became one conditional pointer, and
  prose was tightened across a dozen non-GPTX bullets. **20,317 → 18,996 bytes**, clearing
  the standing ≤19,000 target that had been over budget for some time. No rule changed
  meaning; many changed wording (recorded as a deviation in `specs/028/tasks.md`).
- `orchestrate/SKILL.md` still required Terra's pre-mutation advisory call, retired
  2026-07-30. It contradicted the routing doctrine beside it; corrected.

### Fixed
- **A router running stale code was indistinguishable from a current one** — `state: ok`,
  `drift: null`, no loaded-source version. This is the class behind rc.18's
  `gpt-5.6-terra-xhigh` returning `502 unknown provider` while every `sol` alias answered
  200: the agent file moved and the running process did not. Now detected, with the
  kickstart command in the failure message.

### Known issue
- `gpt-terra` requests `gpt-5.6-terra-xhigh`, which a router process predating the terra
  aliases does not serve. `~/.claude/agents/` symlinks into the main checkout, so the
  breakage arrives when that checkout advances — **restart the router before pulling.**
  Exactly one of seven profiles is affected; `gpt-mid`, `gpt-high`, `gpt-sol`,
  `gpt-sol-reviewer`, and `gpt-sol-advisor` are unaffected.

## [v1.0.0-rc.18] — 2026-07-30

**Version reconciliation.** `core-rules/VERSION` had been advanced to `rc.15`, `rc.16`, and
`rc.17` by #198, #206, and #207 without a matching CHANGELOG section for any of them, so
the file's newest released entry was `rc.14` while VERSION read `rc.17`. This section closes
that gap: it covers everything merged after `rc.14` (#198–#216), including the three
previously undocumented bumps, and VERSION moves to `rc.18`. Public tags remain
public-mirror-only.

Live certification for this release: `gptx-doctor --certify` green on all ten checks with
both lanes exercised end-to-end (Anthropic subscription OAuth intact; GPT completion,
tool-call round-trip, structured output, and advisor bridge with an actual `gpt-5.6-sol`
receipt). Deterministic gate at the release SHA: 433 Bats assertions, 7 Node suites,
conformance, evals, prompt-shell lint, and `shellcheck -S error` all clean.

Scope of that certification, stated precisely: it was run against the **running** router,
which predates the terra-alias fix below. So the alias fix is proven by unit and
integration test but carries no live receipt yet — that needs a router restart, which is
deferred because a user GPTX session is still live (spec 027 T03). Public mirror
publication remains gated behind T05–T07 for the same reason.

### Added

- **Public GPTX session modes** (#198) — `gptx`/`codex`/`hybrid`/`claude` as a documented
  public surface rather than an instance-private arrangement.
- **Orchestrate-and-mix model routing doctrine** (#211) — `core-rules/references/model-routing.md`.
  Routes on verifiable properties (context footprint, cross-family review) and requires a
  deliberate family mix on dual-eligible fan-out, because a free choice between near-parity
  lanes collapses onto whichever model the orchestrator already holds.
- **Spec 027** GPTX public-release gates and publication plumbing (#210).
- **Spec 028** proposal: a global GPTX switch, default off, so Trellis works out of the box
  for users who do not hold both subscriptions (#212).
- Shared local-infrastructure spec, plan, and task rollout (#201, #203, #204).
- Registry and reporting: Duta (#199), provakil competitor (#205), July operations
  snapshot (#200), disk-janitor reports for 2026-07-28..30 (#208).

### Changed

- **Routing doctrine corrected: family before profile** (#213). An earlier draft consulted a
  per-shape table before allocating family, so the table decided the lane for most units and
  the mix rule could never fire. The pool is now recorded with named stage-1 exclusions, which
  is what makes the 40% mix auditable instead of retro-justifiable.
- **Terra advice gate rescoped, not removed.** The mandatory advice-before-mutation
  round-trip is retired for **delegated** Terra units doing reversible in-repo work: the
  orchestrator's review of the finished diff is the gate, and the blocking call cancelled
  the throughput advantage that is Terra's only reason to exist. Cross-model review of
  that retirement (`audits/2026-07-30-terra-gate-cross-review.md`) found it had been
  applied one step too far, so two parts are restored, one of them stricter than before:
  - A Terra **main** model now requires a reachable Claude-family oracle — `--advisor
    auto|opus|fable`, or `--delegates claude|auto` so a Claude reviewer can be spawned.
    `--advisor sol` no longer qualifies, which the *original* gate accepted; GPT reviewing
    GPT is not independent review. Previously `--mode codex --model terra --advisor none
    --delegates none` resolved valid with no advisor, no orchestrator above it, and zero
    permitted delegate providers — unadvised and structurally unable to spawn a reviewer.
    Sessions relying on mode defaults are unaffected: `delegates` defaults to `auto`.
  - Irreversible work — destroying data, writing outside declared paths, externally
    visible effects — still blocks with zero mutation when advice is unavailable, because
    reviewing a diff cannot undo an effect that already landed. This one is an **agent
    instruction, not a mechanized block**: no hook enforces it, so it is recorded as an
    open follow-up rather than claimed as a rail.

### Fixed

- **`gpt-terra`'s declared `xhigh` effort is now actually enforced.** The alias mechanism
  held a single hardcoded `EXECUTION_MODEL = 'gpt-5.6-sol'` applied to every alias, and the
  alias map contained Sol slugs only. `gpt-terra` declared `effort: xhigh` in frontmatter but
  requested the unaliased `gpt-5.6-terra`, so the router matched no alias, injected no effort,
  and reported `effort: null` / `effortSource: null` — the rung was cosmetic. Adding a terra
  key to the old map would have been worse than the gap: it would have executed **Sol** under
  a terra name. Each alias now carries its own execution model, terra aliases exist for all
  three rungs, and `gpt-terra` requests `gpt-5.6-terra-xhigh` like every other GPT agent
  requests its own alias. A new guard reads the agent files and fails if any GPT agent's
  declared model is not an alias, or if its declared `effort:` disagrees with what the alias
  injects — the two drifting apart is the defect itself.
- **Policy notices now reach the operator.** `session-policy` emitted `notices[]` that the
  launcher never read, so a recommended-but-disabled safety pairing appeared only inside
  `--dry-run` JSON — and the test suite asserted it only there, so the live gap passed.
  Real launches now print `Trellis notice: …` to stderr before exec, covered by a
  non-dry-run test.
- **`max` is hard-rejected at every dispatch validator** (#214), with or without an operator
  justification, and removed from the effort enum. Above `xhigh` these models spend
  substantially more reasoning for very little gain, so the ceiling is now mechanical rather
  than advisory.
- **A busy gateway is no longer restarted** (#213). The health probe used a 2s timeout and
  `launchctl kickstart`ed on timeout, so a healthy-but-loaded router was killed mid-request —
  dropping in-flight work for every session sharing it. The probe now allows 10s and checks
  that the port is actually listening before concluding anything is wrong. Alias-derived
  effort is also pinned as authoritative over an inherited CLI `--effort`.
- **The installer no longer deletes the operator's Claude compact window** (#209).
- **Workflows fail closed at stage boundaries** (#206) instead of proceeding past a required
  stage that did not produce a result.
- **Oversized skill roots are blocked before load** (#207). A single Skill result had injected
  ~212K tokens into one session, which auto-compact then preserved, ending in
  `Prompt is too long`.

### Tests

- Streamed upstream error coverage for the GPT lane (#202).
- `M12` aligned with the merged `max` hard-reject (#216). It had asserted the pre-`0c128e5`
  contract and was failing on `main` — found only by running the full 36-file suite rather
  than the files a given change touches.

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

- **Orthogonal GPTX delegation controls and worker reliability (spec 025).**
  `cmux-trellis-teams` adds `--delegates auto|gpt|claude|none` without changing main-model or
  advisor selection. A session-scoped Agent `PreToolUse` guard resolves launcher-captured
  slot aliases before provider classification, preserves provider-stable full IDs, rejects
  stale or mismatched policy without rewriting tool input, and applies at nested Agent depth
  through inherited settings. Exact GPT worker aliases now enforce `gpt-mid` = medium,
  `gpt-high` = high, and `gpt-sol` = xhigh at the GPT router boundary while retaining 272K
  context, exact forwarded byte length, explicit-model precedence, and same-provider routing.
  Live doctrine and Workflow validators restore medium/high/xhigh with explicit effort and
  existing attended max/ultra exceptions. Advisor callbacks are deadline-bound, cancelable,
  idempotent, concurrency-two, and circuit-broken. Sanitized receipts distinguish requested,
  execution, effort, and pre-spawn provider state without prompt storage or claims of observed
  runtime provider. Canonical policy data generates checked-in 120-row session and 24-row
  model-override matrices with byte-parity tests. Agent instructions distinguish root named
  teammate mailboxes from nested unnamed direct-result subagents while preserving Terra's
  advice-before-mutation invariant.

- **Public GPTX model modes (spec 022).** `cmux-trellis-teams` keeps cmux as the
  session/team surface while exposing `gptx`, `codex`, `hybrid`, and `claude`
  topologies plus independent advisor selection. The public split router preserves a
  closed GPT/open Anthropic credential boundary, a maintained CLIProxyAPI fork bridges
  Claude Code's advisor server tool, and `auto` visibly falls back from Opus to Sol and
  later restores it. GPT context is resolved from the installed Codex catalog instead
  of borrowing the API's 1.05M window; the public roster now includes the missing Sol
  high rung and the fast Terra xhigh implementer. `AGENT_ONBOARD_GPTX.md` provides a
  reversible, agent-executable install and certification runbook.

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

- **GPTX advisor bridge trust boundary (spec 022/024).** The maintained CLIProxyAPI fork
  now activates only for the exact built-in advisor declaration, ignores callback headers
  on ordinary requests, accepts only literal loopback callback IPs with exact high-entropy
  paths, defers callbacks until the full tool sequence is known, fails closed on mixed or
  repeated advisor calls, recursively merges usage, and observes cancellation on every
  output send. Trellis pins the reviewed fork merge commit.

- **GPTX child-advisor inheritance guard (spec 022).** A GPT request that declares the
  advisor tool but loses its session header now receives a Sol xhigh callback, while
  explicit advisor selections—including `none`—remain authoritative. Advisor results
  identify the actual model and selection source. Routed GPT sessions also distinguish
  Agent mailbox identities from `TaskOutput` job IDs. This is implemented entirely in
  Trellis; Claude Code is not patched.

- **GPTX advisor recovery hardening (spec 022).** The advisor bridge now sends a bounded
  active-task context, allows five minutes for Sol xhigh, deduplicates callbacks by
  session and turn, and clears them on every terminal path. The reversible installer configures
  CLIProxyAPI for one retry and no credential-wide cooldown on transient 408/5xx while
  preserving authentication, quota, and rate-limit cooling. The doctor detects obsolete
  pre-bridge global instructions and verifies a Codex completion immediately after the
  advisor probe. The session launcher reloads missing local gateway services before
  starting cmux.

- **GPTX Terra role correction (spec 022).** `codex` and `hybrid` now default to
  GPT-5.6 Sol xhigh as the main orchestrator. Terra remains available as the fast
  bounded-work teammate and through an explicit `--model terra` override, but an
  explicit Terra main with `--advisor none` is rejected before cmux starts. The
  `gpt-terra` agent now fails closed without mutations when its configured Opus,
  Fable, or Sol xhigh advisor is unavailable.

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
  reconciled; delivered rows and the narrowed TGSC Loop 5 scope now match main.
- **Permanent blacklist reconciled.** `product-videos` is permanently excluded;
  the obsolete `curat-cc-data` and `DocSynapse` rows were removed while their
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

- **GPTX delegate locks now classify effective child model, not display alias.** Codex and
  hybrid map Claude Code's `opus` slot to `gpt-5.6-sol`; policy version 2 captures and
  validates that child mapping before Agent `PreToolUse` enforcement. Full model IDs stay
  literal, stale/mismatched policy fails closed, and hermetic tests prove zero real platform
  or service command invocations.

- **The disk janitor no longer reaps a worktree somebody is working in.** The worktree
  scan had no live-process guard, so `merged`-ness stood in as a proxy for "nobody is in
  there" — which is why `--safe-only` was merged-only. A default dry-run was observed
  listing a 1.0 GB clean/unmerged/pushed worktree as reapable while a live process tree
  sat inside it: exactly the case the 2026-07-16 ADR predicted. One host-wide `lsof`
  snapshot per scan (0.21s measured) now gates every reap path, fails closed on any probe
  failure, and is re-taken immediately before each individual removal to close the
  plan→apply race.

- **An upstream mid-stream error is no longer filed as the client's fault.** A lane that
  returns 200, starts streaming, then injects an SSE error frame settled as `aborted` —
  blaming the client that hung up in response — and left the error counter at zero. It now
  settles as `streamErr` and increments `errors`. The frame match is anchored to SSE
  framing rather than the bare substring, so a model writing prose *about* streaming
  cannot mark its own turn as an upstream failure.

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
- **`scripts/rollout-orchestrate-skill.sh`** — idempotent per-project installer for the `orchestrate` skill symlink, the exact analog of `rollout-debrief-skill.sh`. `orchestrate` (the tenth canonical skill) was seeded by `onboard-project.sh` going forward but never backfilled onto the four projects onboarded before it landed (neev, curat.money, vericite, clusterbid-console), so they were running 9-of-10 canonical skills. This script closes that gap: registry-driven, `harnesses`-gated `.agents/` parity, backs up any pre-existing directory before linking. Rolled `orchestrate` out to all 8 registered projects (both surfaces) — the fleet now carries the full canonical skill set.

### Changed

- **Codex harness parity with Claude Code.** Codex now carries the default-on
  `propose-rules` Stop hook, receives the same shared reviewer/UI hook cores
  during onboarding and sync, and is checked by `doctor` for hook manifest,
  hook-lib, reviewer-core, and `process-gate-local` parity. The parent drift
  audit scope now treats Codex hook assets and shared reviewer cores as
  first-class rollout artifacts.
- **`scripts/onboard-project.sh` — the `.gitignore` Trellis block is now GENERATED, not appended (closes the fleet-wide stacking drift).** The old `ensure_gitignore_fragment` cat-appended a static template whenever a version sentinel changed and never removed prior blocks, so projects accumulated stacked, stale Trellis blocks that omitted newer symlinks — the four `execute`/`brainstorming`/`orchestrate`/`debrief` links showed up as untracked across the whole fleet. Replaced by `write_gitignore_block`: `seed_symlink` records every absolute-target link it creates, and at the end of the run the block is regenerated in full, listing exactly those machine-absolute symlinks (the relative `AGENTS.md` → `CLAUDE.md` link is excluded, so it stays tracked — the user's rule "ignore only the hardcoded-symlink paths"). The block is **version-agnostic** (no skill-count sentinel) and self-healing: each run strips all prior Trellis-managed blocks (every historical sentinel + the legacy `end SE Core fragment` end-marker variant) plus any orphaned canonical-symlink lines stranded between stacked blocks, collapsing them into one clean block. Stripping is **per-block** (not span-based) and the orphan sweep matches only exact Trellis-owned strings, so project-authored `.gitignore` content — even when interleaved between stacked Trellis blocks (e.g. clusterbid-console) — is preserved. Rolled out to all 8 registered projects, one PR each. ADR: `docs/adr/2026-06-05-gitignore-generated-block.md`.
- **`engineering-process.md` + `scripts/rollout-{feature-skills,builder-skills,process-gate-skill,presets}.sh`** — onboarding narrative and operator hints updated to describe the generate-and-replace mechanism; the obsolete "paste the fragment yourself" advice is replaced with "re-run `onboard-project.sh`".
- **`core-rules/CLAUDE.md` (and its `AGENTS.md` symlink) — genericized project-name attributions in the always-loaded parent rules.** The four rules promoted into the parent surface from `deferred.md` (worktree-safety, code-asset pairing, cloud-provisioning region check, ADR convention) carried parenthetical project-name attributions (`(neev, akaushik.org, clusterbid-console, vericite)`, etc.) — the only project names anywhere in the always-on surface that ships verbatim to the public mirror. Replaced with counts (`(observed across N projects)`), preserving the "grounded in real incidents" evidential weight without naming private projects in the every-session surface. Full provenance (which projects, n-counts, incident dates) is retained in `core-rules/deferred.md`, the CHANGELOG, and the ADRs. Unblocks the public-mirror sync of the post-RC core-rules promotion.

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
- **Brownfield settings reconciliation.** `scripts/sync-hooks.sh` now wires the canonical `.hooks` block into an existing `settings.json` via `scripts/lib/settings-hooks-merge.sh`, a preserving merge that applies the canonical wiring and re-appends any project-specific hook entry the canonical set does not carry (verified on neev, whose hand-tuned module-boundary hook survives). The hook-resolution logic is shared with `scripts/lib/prepush-target.sh`.
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
- **`core-rules/githooks/post-checkout`** — eager post-checkout hook (thin, harness-agnostic). Fires on `git worktree add` (and branch switches, where seeding is idempotent + cheap): detects a linked worktree via `git rev-parse --git-common-dir` vs `--git-dir`; seeds only in a linked worktree; always `exit 0` so seeding failure never aborts the worktree creation. Installed only on projects whose `core.hooksPath` points at a **tracked** directory — native-`.githooks` projects (lume, clusterbid-console) and plain-git. **Not installed on husky projects**: husky v9 sets `core.hooksPath=.husky/_` and `.husky/_/.gitignore` is `*` (husky-generated), so `.husky/_` never materializes in a linked worktree — any hook placed there is dead (verified live on neev). `onboard-project.sh` gains one additive step: installs the hook for native-hooks projects; the symlink phase is untouched.
- **`scripts/worktree.sh` + `trellis worktree` subcommand** — the universal eager front door, stack-independent. `trellis worktree add <path> [git-args...]` runs `git worktree add` then calls the seeder on the new path; `trellis worktree sync [<path>]` re-seeds an existing worktree (default `$PWD`). Works on every project, including husky projects where the eager git hook is dead. Discoverable via `trellis help`.
- **`scripts/lib/health-checks.sh` `hc_worktree_inheritance`** — new Tier-1 doctor check. Enumerates `git worktree list` for the current repo; for each linked worktree runs the seeder in `--verify-only` mode and reports any missing core inheritance symlinks. `doctor --fix` (gated by the existing Tier-0 canonical-on-main guard) runs the seeder on each offending worktree.
- **SessionStart worktree safety-net** — when `session-context.sh` detects it is running inside a linked worktree with missing inheritance symlinks: (1) runs the seeder (repairs for the *next* session — skills are enumerated at process init before SessionStart hook filesystem changes land, so the current session cannot be healed, verified); (2) emits a loud `additionalContext` warning naming the gap and instructing the operator to restart. Converts the silent-drop failure mode into a visible, self-repairing event for any worktree born without the eager hook (e.g. a husky project on raw `git worktree add`, or a pre-ship clone).

### Changed

- **`core-rules/hooks/session-context.sh`** (+ codex mirror `core-rules/codex/hooks/session-context.sh`) — gained the worktree detect/seed call: at session start, checks whether cwd is a linked worktree and if so runs `seed-inheritance-symlinks.sh --verify-only`; on failure, runs the seeder and emits the loud restart warning. Guard is a no-op outside of linked worktrees and in fully-seeded worktrees.
- **`scripts/onboard-project.sh`** — one additive step: after the symlink phase (untouched), installs `core-rules/githooks/post-checkout` into the project's hook home when the hook home is a tracked directory (native-hooks projects only); husky and plain-git detection logic selects the correct install path or skips as described above.

## [v0.7.2] — 2026-05-31

**Settings-wiring doctor check tolerates project extensions.** `trellis doctor`'s per-project settings check no longer false-positives on projects that legitimately extend their `.claude/settings.json`.

### Changed

- **`scripts/lib/health-checks.sh` `hc_settings_wiring`** — was an exact `.hooks` block match, which flagged any project that added its own wiring (e.g. neev's project-specific `check-module-boundary.sh` PreToolUse hook, or a bumped `stop-verify` timeout) as drift. Now uses **superset semantics**: each settings file is flattened to `(event, matcher, command)` wirings and the check warns only when a **canonical** wiring is *absent* from the project — extra project hooks and differing timeouts are allowed. Missing wirings are named in the message. Backward-compatible: projects that exactly match the template still pass.

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

**`trellis doctor`** — a deterministic, on-demand inheritance health-check + repair command that unifies the existing check and fix engines behind one front-end and runs (read-only) after every update. Motivated by two 2026-05-30 drift incidents: a project (`curat.money`) silently running with zero parent rules (no rules symlink, dead cross-machine `@`-import), and the canonical checkout left on a feature branch silently feeding *every* project stale rules. ADR: `docs/adr/2026-05-30-trellis-doctor.md`.

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

- **`core-rules/deferred.md` — "Code-asset pairing rule" entry (n=2).** From `audits/2026-05-01-gotchas-rollup.md`: vericite shipped a TS rename in `apps/api-gateway/src/lib/openapi.ts` without regenerating the checked-in `docs/api/02-openapi.yaml`; lume authored MonoBehaviours in `Assets/Scripts/` without wiring them into `Assets/Scenes/SampleScene.unity`. Both failed only at runtime / integrity-test time; static checks (typecheck, build, lint) were blind to the drift. Parked as an n=2 candidate with graduation criterion "a third project independently reports a bug whose root cause is a code change landing without its paired non-code artifact" — phrasing of the eventual lift (narrow "regenerate generated artifacts" vs. broader "code-asset pairing" invariant with per-project hooks) deferred to the n=3 instance.
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
- **Conformance CI gate green again.** Five missing-reference findings on `main`: `engineering-process.md:526` brace `web-{perf,a11y,seo,agent-readiness}.md` and `monorepo-polyglot.md:205` brace `core-rules/husky/{commit-msg,pre-push}` rewritten as individual inline-code paths (all eight target files exist); `monorepo-polyglot.md:246` references to `docs/adr/0001-slice-1-bundle.md` / `docs/adr/0002-slice-2-bundle.md` and `:288` reference to `docs/engineering/repo-structure.md` were prose pointers to clusterbid-external ADRs / docs not present in Trellis canonical — inline-code markers stripped to remove the false signal to the conformance checker while preserving the prose. Final scan: `clean (19 spec docs, 154 refs scanned)`.

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
(`__GITHUB_USER__/trellis@v0.3.1`) but the corresponding private commits were lost
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
`__GITHUB_USER__/trellis@v0.3.0`.

### Added

- **Anthropic best-practices bundle — ten changes mapping the Claude blog onto Trellis.** Ten commits land the changes from the 2026-05 Anthropic "How Claude Code works in large codebases" guide that Trellis didn't already cover. Grouped into three phases:
  - **Phase 1 (quick wins).** (1A) `permissions.deny` baseline in `core-rules/templates/claude-settings.json` covering `node_modules`, `.next`, `dist`, `build`, `out`, `target`, `vendor`, `.venv`, `__pycache__`, every cache dir, and every lockfile, plus a new `scripts/rollout-settings.sh` that jq-merges canonical + project-local entries idempotently. New projects pick it up via `onboard-project.sh`; existing projects converge via the rollout script. (1B) Mandatory `## Codebase map` section in project `CLAUDE.md` for any project with ≥5 top-level directories — one line per top-level dir, role only; sub-threshold projects skip the section. Convention added to `engineering-process.md` §9.1 and the `AGENT_ONBOARD_PROJECT.md` Step 4 playbook. (1C) New quarterly `obsolete-rules` audit (Q1/Q2/Q3/Q4 1st 09:00). Walks `core-rules/CLAUDE.md`, presets, `engineering-process.md`, and every project `CLAUDE.md` + `gotchas.md`; classifies each rule as load-bearing / model-compensating / harness-compensating / stylistic / process; surfaces model-or-harness-compensating rules that have aged out of usefulness. Removal-only audit — never proposes additions; gotchas-rollup retains promotion ownership.
  - **Phase 2 (monorepo scoping).** (2D) `stop-verify.sh` is now subtree-aware: when every changed file in a turn sits under one subdirectory carrying its own manifest (`package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`), the hook `cd`s into that subtree before typecheck / lint / test. Mixed-subtree changes and missing nested manifests fall back to repo root. Escape hatch: `PROCESS_GATE_FORCE_ROOT=1`. Patched in both Claude and Codex parity copies. (2E) Optional `scope.json` convention for project-local skills — `{ "paths": ["services/**"], "reason": "..." }` next to a non-canonical `SKILL.md` limits auto-invocation to matching paths. Engine-unenforced; agent-followed via `core-rules/CLAUDE.md` directive. Canonical skills stay global. (2F) `cross-project-process-audit` extended with check 10: warning when a ≥5-top-level-dir project lacks a `## Codebase map` heading; info when the heading exists but the list is stub-only; warning when the listed dirs no longer exist.
  - **Phase 3 (subagent + LSP + governance).** (3G) New `/explore <subsystem>` canonical slash command — read-only subagent maps a subsystem and writes the summary to `<canonical-root>/.claude/primers/_explore/<slug>-<sha>.md`; editing session loads it before touching code. Ephemeral counterpart to `/primer`. Symlinked into `.claude/commands/` and `.agents/commands/` by `onboard-project.sh`; sentinel bumped to "7-skill set + presets + primer/explore commands". (3H) LSP recommendation for polyglot projects added to `engineering-process.md` §8.3 — install per-language LSP binaries (`gopls`, `typescript-language-server`, `pyright`, etc.) plus a Claude Code LSP plugin for ≥2-language repos. Recommendation only; no audit, no hook coupling. (3I) New experimental Tier-2 hook `propose-rules.sh`. Opt-in via `PROCESS_GATE_PROPOSE_RULES=1`. Dispatches a one-shot `claude -p --max-turns 1` subagent at end of turn to read transcript tail + project `gotchas.md` and propose a single candidate entry (or `NONE`). Three layers of cost control: opt-in gate, `stop_hook_active`/pure-chat guards, and a transcript-tail heuristic that only fires the subagent when an explicit-correction signal ("no", "don't", "actually", "stop doing", "that's wrong", "never do") appears in the last ~200 lines. Pairs with `gotchas-rollup` (monthly) — propose-rules surfaces n=1 candidates per turn; the rollup clusters n≥3 into parent-rule promotions. `parent-hook-drift` accepts absence of a settings.json entry for experimental hooks. (3J) Optional `approved_mcps` field added to `scripts/lib/trellis.config.schema.json` and the example config — array of `{ name, purpose, scope: "fleet" | "per-project" }` entries. Documentation-only today; reserved for a future parked `mcp-drift` audit. Sized for solo-DRI use: explicit allowlist now, audit when n=2 projects diverge.
- **Frontend-quality references bundle** — four sibling reference docs at `core-rules/skills/process-gate/references/web-{perf,a11y,seo,agent-readiness}.md`, synthesizing Lighthouse (Performance, Accessibility, Best Practices, SEO, Agentic Browsing), web.dev Learn Accessibility / pa11y / axe-core, Google's AI Optimization Guide, and Cloudflare's `isitagentready.com` scorecard into a single Trellis-stamped checklist. Closes the previously-empty frontend-guidelines slot (gate #6 in `process-gate/SKILL.md:36` is the destination for any future automation). Three-way disagreement on `llms.txt` between Google (debunks), Lighthouse Agentic Browsing (rewards), and Cloudflare (rewards implicitly) explicitly resolved in `web-agent-readiness.md` — Trellis adopts `llms.txt` as a hedge for projects with substantive public docs and skips the speculative WebMCP / MCP-card / x402 / UCP / ACP protocol layer until n=2 ships an agent-served API. a11y tool stance is **axe-core canonical, pa11y fallback for static-HTML projects** — matches TGSC's existing project-local `check-a11y.sh`; rationale (WCAG 2.2 support, Deque-maintained, Chrome DevTools Issues panel, `@axe-core/react`, shared rule engine with Lighthouse) documented in `web-a11y.md`. Automation (Lighthouse CI, axe-core in CI) remains deferred per `core-rules/deferred.md:57` until Rule of Three; the new references cite that deferral so future agents don't accidentally promote prematurely. Wired in via one cross-profile section appended to `stack-profiles.md` and a new §9.6 in `engineering-process.md`. No parent `CLAUDE.md` edit, no new skill / command / hook / scheduled audit / primer. Capture date 2026-05-16; `web-perf.md`/`web-seo.md`/`web-a11y.md` re-verify semi-annually, `web-agent-readiness.md` quarterly (fastest-shifting axis).

### Changed

- **Codex feature-flag rename: `[features].codex_hooks` → `[features].hooks`.** Codex CLI 0.129+ emits a deprecation warning when it sees `[features].codex_hooks` in `$CODEX_HOME/config.toml`; the canonical key is now `[features].hooks`. The legacy key still works as an alias but should not be used in new installs. Doc references updated across `README.md`, `AGENT_ONBOARD_PROJECT.md`, `engineering-process.md` (§5a hook-tier section and §10.3 onboarding checklist), `core-rules/inheritance.md`, and the `scripts/onboard-project.sh` post-onboarding echo. Each touch points new operators at `hooks = true` while noting the alias for users who still have the legacy key in their config. The bash function name `seed_codex_hooks()` (script-internal — copies `.codex/hooks/*.sh`) is unaffected — it describes a category of hooks, not the deprecated TOML key.
- **Retired Obsidian dependency from the `monthly-documentation-audit` description.** The Neev-scoped monthly doc audit in `scheduled-tasks/README.md` no longer claims to check "Obsidian sync" — the audit covers EPM currency and ADR coverage; doc-write target is the project filesystem (already mounted), so the MCP path is unnecessary overhead.
- **Brand sweep follow-ups.** `security-gate-plan.md` had three stale "SE Core" / `se-core` mentions left over from the 2026-05-12 rebrand (§1 purpose paragraph, §3 infrastructure reuse line, §11 per-project flow); all three now read "Trellis" / "Trellis instance". Historical references in `CHANGELOG.md` (rebrand entry), audit filenames under `audits/`, ADR PR URLs at `__GITHUB_USER__/se-core`, and `scripts/rollout-rebrand.sh` (whose purpose is the migration itself) are intentionally preserved.


### Added

- **Feature primer system — canonical `commands/` slot + opt-in primer infra.** A primer is a compact, hand-validated context document (~150 lines max) pinned to a commit SHA. Future sessions read the primer instead of re-exploring the feature — the goal is replacing 350K-token exploration runs with 30–50K-token primer-assisted runs for testing, debugging, and extending stable features. Three new canonical commands at `core-rules/commands/{primer.md,primer-refresh.md,primer-check.md}` — first occupants of the new `core-rules/commands/` distribution slot, parallel to `core-rules/skills/`. Templates at `core-rules/commands/templates/{primer-template,primer-index-template}.md`. Reference docs at `docs/primers/{plot-md-integration,handoff-integration}.md`. Parent `core-rules/CLAUDE.md` gains a `## Commands` section and a Feature primers block (cascades to all managed projects via `@`-import — no per-project CLAUDE.md edits required). `scripts/onboard-project.sh` extended to symlink the three commands into `.claude/commands/` and `.agents/commands/` (Codex parity) and seed an empty `.claude/primers/INDEX.md` (copied, not symlinked — primer INDEX is project-state and tracked in git, individual primers too). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets + primer commands)`; covers the three new symlinked commands per harness while explicitly preserving primer content files. `scripts/sync-to-template.sh` SYNC_PATHS gains `core-rules/commands/` and `docs/primers/`. Primer files resolve via `git rev-parse --git-common-dir` (canonical-root convention, same pattern as `context-log.md`) so worktree sessions see the same primer set as the main checkout. The three context-log hooks remain untouched. Opt-in per project: projects without `.claude/primers/INDEX.md` skip primer logic entirely. Forward-looking integrations (`active_primers:` in local `plot.md`, post-commit refresh hooks) documented in `docs/primers/` but not implemented in this phase. Each preset is a single markdown file at `core-rules/presets/<name>.md` that layers on top of the parent rules. Two example presets ship: `compliance-strict` (mandatory ADR per architectural change, two-human PR sign-off, no `--no-verify`, hard-fail secrets, mandatory CHANGELOG, deploy SHA encoding) and `experimental-loose` (direct commits to main, skip the spec-kit pipeline, optional CHANGELOG, PR-size warn-only, test coverage optional; time-bound). Projects opt in via the `presets` array in their own `<project>/.trellis.config.json`. Schema (`scripts/lib/trellis.config.schema.json`) carries an optional `presets` field with kebab-case validation + uniqueItems. Per-project preset selection is read directly by `onboard-project.sh` and `scripts/rollout-presets.sh` from each project's own `<project>/.trellis.config.json` — not via the parent `config-load.sh` loader (presets are a per-project concept). `scripts/rollout-presets.sh` (new, idempotent) installs the declared symlinks under `.claude/rules/preset-<name>.md` and `.agents/rules/preset-<name>.md` and prunes ones no longer declared. `onboard-project.sh` extended with `seed_presets()` (no-op when no project-local config). `core-rules/templates/project.gitignore.fragment` sentinel bumped to `(7-skill set + presets)`; covers `preset-*.md` symlinks via glob. `scheduled-tasks/preset-drift/` runs weekly (Mon 12:00) catching declared-vs-installed mismatches across the registry. Narrative documentation: `engineering-process.md` §14.7 + `core-rules/inheritance.md` extended with the skills-vs-presets symmetry table. (spec-kit Phase D, plan: `docs/plans/2026-05-12-spec-kit-adoption.md`)

### Changed

- **Repo rebrand: SE Core → Trellis.** Full sweep across config files, env vars, JSON keys, scripts, scheduled-tasks prompts, core-rules docs, audit prompts, hook libs, husky pre-push, ADRs, and root docs. Highlights: `se-core.config.json` → `trellis.config.json` (with schema + example); JSON root key `se_core_root` → `trellis_root`; env vars `SE_CORE_ROOT`, `SE_CORE_CONFIG`, `SE_CORE_CONFIG_PATH`, `SE_CORE_TEMPLATE_DIR`, `SE_CORE_SKIP_SECURITY_BASELINE`, `SE_CORE_ALLOW_MAIN_PUSH`, `SE_CORE_NO_JQ_DEGRADE` → `TRELLIS_*`; in-project symlink `.claude/rules/se-core.md` → `.claude/rules/trellis.md` (existing projects re-linked by `scripts/rollout-rebrand.sh`); hardcoded `__USER_HOME__/projects/se-core/` paths → `__TRELLIS_PATH__/`; public mirror remote → `__GITHUB_USER__/trellis`; default `TRELLIS_TEMPLATE_DIR` → `$USER_HOME/projects/trellis`; brand text "SE Core" / "Software Engineering Core" → "Trellis" everywhere except (a) historical audit filenames under `audits/`, (b) the historical PR URLs in `docs/adr/0001-...md` (the legacy `__GITHUB_USER__/se-core` GitHub repo still resolves those references).

### Added

- **Versioning + upgrade flow (spec-kit Phase A)** — `core-rules/VERSION` is the canonical semver pin (initial value `0.1.0`). Optional `trellis_version` field added to `scripts/lib/trellis.config.schema.json` for downstream consumers to pin against. `scripts/upgrade.sh` compares the pinned version to the highest `v*.*.*` tag on `origin` (or `template.remote` fallback) and prints a stat diff of `core-rules/`; `--opt-in` rewrites the pin in config and revalidates against the schema; `--check` exits non-zero on drift for CI. `scheduled-tasks/version-drift/` runs weekly (Mon 11:45) classifying each project as current / no-pin / patch-drift / minor-drift / major-drift / ahead / malformed — only major-drift is critical. `core-rules/templates/trellis.config.json.example` is the first reference config template. `config-load.sh` exports `TRELLIS_VERSION`. `core-rules/VERSION` bumped from `0.1.0` to `0.2.0` on the rebrand commit; `v0.2.0` is the next release tag on the public mirror (`v0.1.0` was already taken by the 2026-05-08 meta-audit wrap-up). (spec-kit Phase A, plan: `docs/plans/2026-05-12-spec-kit-adoption.md`)
- **Eval harness runner** — `scripts/run-evals.sh` discovers fixtures under `core-rules/evals/<project>/<id>/`, invokes `claude -p` headless per fixture (n times each, default 5), evaluates `expected.json` assertions against `git status --porcelain` of the seed snapshot, and emits a pass-rate JSON. Supports `--check` (schema-only validation; no model invocation), `--dry-run`, `--filter <glob>`, and `--changed-only`. Workflow `.github/workflows/evals.yml` always runs `--check` on PRs and runs the full suite when `ANTHROPIC_API_KEY` is wired (deferred to P4.5). (P4.3)
- **Eval fixture schema** — `core-rules/evals/SCHEMA.md` is the canonical specification; `core-rules/evals/template/` is a real, executable reference fixture. Required manifest fields: `version`, `id`, `project`, `prompt`. (P4.1)
- **Neev fixture set** — `core-rules/evals/neev/` ships 10 fixtures grounded in `audits/2026-04-26-parent-hook-drift.md` and `audits/2026-05-01-audit-rollup.md`: 6 install-canonical-hook regressions (block-destructive, post-edit-verify, stop-verify, truncation-check, ui-verify, code-review-subagent), 2 rebase-drifted-hook regressions (session-context, block-destructive), 1 husky pre-push-guard install, and 1 negative fixture protecting the project-local `check-module-boundary.sh`. Runner now passes `--add-dir <repo-root>` so fixtures can reference the live canonical via repo-rooted paths. (P4.2)
- **Tgsc fixture set** — `core-rules/evals/tgsc/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push pattern as neev. Negative fixture protects the project's `CLAUDE.md` from being modified during hooks work. (P4.2)
- **curat.money fixture set** — `core-rules/evals/curat.money/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push/preserve-claude-md pattern as neev/tgsc. (P4.2)
- **vericite fixture set** — `core-rules/evals/vericite/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push/preserve-claude-md pattern as the rest of the fleet. (P4.2)
- **lume fixture set** — `core-rules/evals/lume/` ships 10 canonical-conformance fixtures using the same install/rebase pattern. The pre-push fixture targets `.githooks/pre-push` (native git hooks) instead of `.husky/pre-push`, since lume is a Unity project without husky per `core-rules/inheritance.md`. (P4.2)
- **akaushik.org fixture set** — `core-rules/evals/akaushik.org/` ships 10 canonical-conformance fixtures using the same install/rebase/pre-push pattern as neev. Negative fixture protects the project's `CLAUDE.md` from being modified during hooks work. (P4.2)

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
hooks + `settings.json` synced to neev, tgsc, akaushik.org, vericite,
lume; `.gitignore` discipline sweep on tgsc / vericite / akaushik
(curat.money deferred — broken husky pre-push shim); ~25 leaked global
Anthropic skills removed from `vericite/.agents/skills/`; akaushik's
`.gitignore` `.claude/` over-ignore corrected to allow per-file
unignore.

### Notes

- Phase 4 (eval harness) is paused per plan decision D4 — requires
  explicit human go-ahead. Phase 5 (strategic adoption) is opportunistic.
- curat.money rollout-process-gate-skill PR remains deferred (P0.2a):
  branch conflicts with main + dirty local worktree blocks safe sync.

## Conventions

- One entry per change. Dated section header `## [YYYY-MM-DD]` when cutting a checkpoint.
- Sections: Added · Changed · Deprecated · Removed · Fixed · Security.
- Each entry links the canonical artifact path so future readers can navigate from changelog to source without searching.
