# Cross-model strength routing — steering reference

Current routing is capability-based and respects the operator's selected model and harness. The role resolver in `core-rules/references/delegation.md` owns automatic worker selection; this document owns deliberate direct Codex dispatch and its effort policy. Prompt guidance lives in `core-rules/references/model-prompting-deltas.md` and `docs/gpt-5.x-steering.md`.

## Current status — direct Codex CLI and optional plugin companion

Generic Codex CLI support is independent of a plugin. The optional OpenAI Codex Companion is a Claude Code integration; an installed copy is not a prerequisite for native Codex work. A selected provider failure is visible and requires explicit re-selection, never silent substitution.

The old `codex-worker` and Spec 013 workflow recipes were retired by commit `2ad1808` before live acceptance. Do not recreate them from historical examples. Receipts remain in `docs/adr/2026-07-10-codex-parallel-orchestration.md` and `specs/013-codex-parallel-orchestration/spec.md`.

## 1. Topology — the selected main agent orchestrates

Codex, Claude Code, or pi can host the main agent. Keep task ownership, planning, acceptance, and synthesis with that agent; delegate substantial independent units through the host's available tools when useful. A user-selected Astra or Fable session does not need to switch to Claude to plan or to Codex to implement. Check actual tool availability, permissions, model access, and worker receipts.

## 2. Routing policy — task requirements and measured results

For automatic worker selection, use the finite task shapes and compatible chains in `core-rules/references/delegation.md`. Explicit operator selections win. Preserve cost/latency roles and family separation for verdict roles; a flagship launch does not justify replacing every worker.

The July 2026 Claude/GPT-5.x benchmark table is superseded as routing guidance. D7 closed with a shortfall on 2026-08-23 after its 2026-08-15 expiry; there was no fresh consensus sweep. That history is retained in Git and the Spec 013 records, and is not evidence that Fable beats Astra at planning or that Astra is cheaper on Trellis's tasks. Re-evaluate representative work with fixed acceptance checks, actual usage, elapsed time, and review outcomes before changing automatic routes.

OpenAI's [Astra guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra), checked 2026-09-05, establishes model capabilities and prompting advice; it does not establish a Trellis cross-model ranking.

## 3. Effort — set per unit at dispatch

Every deliberate direct Codex CLI command and every plugin-owned `codex-companion.mjs` command selects its effort explicitly at dispatch. Blanket xhigh over-thinks mechanical work orders: slower and quota-hungrier for zero quality gain.

**Operating band** — Trellis policy for deliberate direct Codex workers; verify the selected model and supported efforts before dispatch:

- **medium** — mechanical or frozen-scope work with a strong oracle: renames, migrations, coverage fills, dependency bumps, and bounded implementation whose tests or compiler make correctness cheap to check.
- **high** — moderately complex cross-file work with useful tests or diagnostics: implementation that needs broader context or judgment but still has a strong verification path.
- **xhigh** — weak-oracle debugging, security-sensitive work, difficult design, or high-consequence implementation where missed edge cases matter more than latency.

This ladder supersedes the temporary 2026-07-10 `xhigh`-only operating-band suspension. **`max` is not an approved automatic direct-dispatch tier** — this is a house cost policy, not an Astra capability limit or a new performance measurement (`core-rules/references/model-routing.md` § Effort). Explicit user instructions and host controls govern the current session. The retired recipe validators enforced the same ceiling before the implementation was retired. Explicit effort remains mandatory.

**Explicit effort or error.** Every direct Codex CLI and plugin-owned companion command selects effort explicitly at dispatch. An omitted required effort is a caller error. The legacy plugin-specific Workflow recipes are historical only (Spec 013).

**Exception tiers** — above the band, opt-in per unit:

- **`max`** — retired from automatic direct-dispatch policy on 2026-07-30. The former recipe validators rejected it before those recipes were retired. This does not override an explicit user choice supported by the current host.
- **`ultra`** — very difficult units that genuinely decompose. Mechanism (source-verified 2026-07-10): ultra sends `max` effort on the wire plus a proactive-delegation prompt — subagent count is the model's choice, bounded by the CLI's `features.multi_agent_v2.max_concurrent_threads_per_session` (default 4 = main + 3 subagents; CLI warns at ≥8). The recorded check covered Sol and Terra; do not extrapolate that historical mode mapping to Astra or a different installed host.

`ultra` requires a named justification for a Trellis-initiated direct dispatch, is never its default, and is invocable only where the installed host exposes it. Automatic routes retain the house band; user-selected session effort follows the host.

**Ultra status (2026-07-10):** D4a prerequisites were satisfied for attended Bash-direct dispatch. The recorded basis was `turn.completed` usage telemetry, loop-safety ×4 accounting, and one instrumented xhigh/ultra paired run. The historical Workflow recipe lane remained limited to xhigh and is now retired.

**Receipts** carry `effort` + `justification` on every result.

**Escape hatch:** max/ultra are forbidden on the sandboxless escape hatch, and no automated route may use the hatch (sandbox posture — spec 011 D5b; the retired Workflow mechanics are historical only in Spec 013).

(The Claude *session* default is governed by `docs/claude-steering.md` §1, which is canonical for Claude effort posture and is where the number and its scoping live; `core-rules/templates/claude-settings.json` enacts it.)

- **Claude** has session-only effort settings the `effortLevel` setting will not take — `max` and `ultracode` — reachable per-session via `/effort` when a task warrants it (`max` over-thinks if applied blindly; test first). `ultracode` is not a level above `xhigh`: it sends `xhigh` and additionally has Claude orchestrate dynamic workflows for substantive tasks (verified 2026-07-25, `code.claude.com/docs/en/model-config`).

## 4. Optional plugin companion presence + fail-closed contract

The OpenAI Codex plugin companion is an **optional runtime-detected capability**,
never a hard dependency. It is not part of Trellis and cannot ship to the public
mirror. Probe it only after the operator explicitly selects that route; absence
never disables generic Codex CLI harness support.

- **Plugin presence gate:** `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs setup --json` → check `ready`, `codex.available`, `auth.loggedIn`. If any is false or missing, the selected plugin lane is unavailable and the unit fails closed with that receipt.
- **Report the actual failure.** A null or task error does not establish quota exhaustion; inspect the returned diagnostics. A confirmed limit hit is a visible plugin-lane failure. Do not transparently re-dispatch the unit to Claude or another provider; a new lane requires an explicit caller/operator selection.
- **`log()` the failure** with the selected lane and attempted unit so an unavailable plugin route cannot look like success or silent single-family execution.

Quality is not laundered by executor routing: every successful unit flows back
into the orchestrator's review gate, and the bright-line guardrails
(destructive-op, external-message, secrets, DoD receipts) fire on direct Codex
CLI and plugin companion commands alike.

## 4.5 Direct execution only

The retired Spec 013 worker is not a supported dispatch path. There is no
`codex-worker` agent, Codex workflow recipe, preflight, or rollout artifact to
invoke. The supported direct modes are:

- **Generic direct CLI:** `codex exec --json -c model_reasoning_effort="<tier>" ... </dev/null` without a plugin; the max/ultra restrictions from §3 apply.
- **Plugin-owned companion:** after the §4 presence gate, `node "$CODEX_PLUGIN"/scripts/codex-companion.mjs task --write --effort <tier> "<prompt>"`.

Both paths are explicit direct execution. Neither creates a worker agent,
automatic fallback, or a background-recipe contract. The historical
`--background` worker/poll rows are records only; see the ADR and Spec 013
named in the retirement note above for their receipts and field lessons.

## 5. Where this is enforced

This doc is the durable intent. It is *carried* by two capability-gated surfaces, neither of which branches on harness identity:

- **The `orchestrate` skill** (`core-rules/skills/orchestrate/SKILL.md`) — capability-gated on available subagent coordination. Use native worker tools when present; deliberate external Codex dispatch uses §4.5. The retired `codex-worker` recipe is not required for native orchestration.
- **A model-neutral capability clause in `CLAUDE.md`** — when orchestrating, route bounded execution-heavy units to an available executor while planning/review/synthesis stay on the orchestrator and explicit provider selections are preserved. Phrased as capabilities the orchestrator may have, never as an identity branch.

As of spec 009, both surfaces cover **interactive units** too (§6) — bounded work-order units route from any turn, not only from orchestrated fan-outs.

If a future revision re-tunes the split, it lands here next to the table, sourced to the evidence rather than to model recall.

## 6. Interactive delegation — bounded work orders from any turn

Any substantial independent work-order unit may route to an available worker from an interactive turn. Pick the leg by task requirements and explicit provider policy first, then capability and quota headroom:

| Leg | Available? | Dispatch | Isolation | Resume | Failure | Cost |
|---|---|---|---|---|---|---|
| **Direct Codex CLI** | operator explicitly selects an installed, authenticated `codex` CLI | deliberate `codex exec --json ...`; no plugin required | Codex workspace sandbox; escape-hatch restrictions still apply | `codex exec resume <thread-id>` when captured | CLI failure stays on the selected lane and fails closed | `codex_usd_per_mtok` |
| **Plugin companion** | operator selected/configured it and `setup --json` reports `ready`, `codex.available`, `auth.loggedIn` (§4) | plugin-owned `task --write --effort <ladder>` command | companion workspace sandbox | companion/Codex thread resume limits apply | null/error is a visible plugin-lane failure; no implicit provider substitution | `codex_usd_per_mtok` |
| **Native worker** | permitted host subagent tool | host-tracked spawn | host sandbox and permissions | reuse the returned worker identity where supported | surface failure on the selected lane | observed usage / session budget |

Every row names an existing mechanic; none authorizes a router to rewrite an explicit provider selection.

**Teardown.** Direct Codex CLI and plugin companion commands exit with their process. An intentionally persistent teammate must be released with its host's paired lifecycle operation after its work is accepted, superseded, failed, or abandoned; use `TaskStop` only on hosts that expose it. See the teammate-teardown section of the `orchestrate` skill and the *Definition of done* teammate clause in `core-rules/CLAUDE.md`.

**Route predicate.** Delegate when the prompt reads as a **work order**: frozen spec, known repro, mechanical refactor, test/coverage fill, dep bump. Keep home when any of:

- **writing the spec IS the work** — ambiguity is design, and design stays on the orchestrator;
- **tiny edit** — ~<20 changed lines, single obvious change (soft judgment aid for delegation overhead; never a substitute for the 006 pipeline gates);
- **session tools needed** — MCP, browser, secrets;
- **bright line** — destructive/irreversible ops, releases, pushes, external messages stay on the orchestrator per existing guardrails.

**Review of executor output is never delegated to the executor that produced the diff, and never skipped** — cross-agent review inside recipes is legitimate; self-review by the producing executor is what's banned. The diff reads like a contributor PR, proof demanded; §4's review gate fires verbatim. Rationale, stated boundedly: the 5.6 system card reports increased agentic-coding overreach vs 5.5 (most pronounced at highest reasoning effort under persistence-heavy prompts) alongside a ~30% *decrease* in misrepresented completions in simulated traffic, and METR reports its highest detected ReAct-harness cheating rate, explicitly prompt/scaffold-dependent. Two failed rounds on the same selected unit end that lane attempt visibly; direct or other-provider execution starts only after explicit caller/operator re-selection, and the takeover is logged.

**Posture: flipped standard since 2026-07-30.** Spec 009 established the bounded work-order predicate; its pilot ledger records the flip, and `core-rules/references/delegation.md` carries the current auto-route contract. Qualifying Codex units use the effort band in §3. Explicit provider locks remain authoritative; pilot history never authorizes an automatic plugin fallback. Token-efficiency framing stays bounded: the "54%" figure is a community-relayed single claim — treat it as directional; no D7 Phase-B re-ground occurred.

**Mechanics:** Direct command forms are in §4.5. The retired worker mechanics have no active reference file; their field lessons and historical receipts remain in `docs/adr/2026-07-10-codex-parallel-orchestration.md` and `specs/013-codex-parallel-orchestration/spec.md`. Delegated units draw the same per-model budgets (`core-rules/loop-safety.md`) and face the same bright-lines as inline work.
