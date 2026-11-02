# herdr-foreman — multi-model orchestration inside Herdr

Applies when a session runs in a Herdr app terminal (herdr-core `hc`: `HC_SCOPE` and `HC_TERMINAL_ID` are set). The executable procedure and
quota-aware role chains are the copy in the **active immutable Trellis release** under
`core-rules/skills/herdr-foreman/`; that release alone decides. A legacy user-level copy
under `~/.claude/skills/herdr-foreman/` may be read for discovery and never authorizes a
decision. This file states the rules the apex, foreman, and workers must agree on.

## Topology

| Role | Who | Owns |
|---|---|---|
| Apex (one per project) | the active user-selected main agent, in the hc terminal that started the session | briefs, git, executed receipts, acceptance, operator-facing decisions |
| Foreman (one per worktree, optional) | pi parent session (Sol xhigh by default) driving dynamic workflows/subagents | fan-out, worker choice, receipts it runs itself, **commits at phase boundaries** when the work order delegates that bounded Git action |
| Workers | named pi subagents chosen per role from live quota | one bounded unit each; never commit, push, or merge |
| Configured named routes | e.g. an Opus author, a Claude code-reviewer via the Agent tool | the roles the classifier or the operator selected for this run — a configured route, not an identity that owns the role universally |

One writer per worktree. The foreman's cwd is the worktree, never the main checkout.
Renaming the apex grants nobody Git rights: a worker or foreman commits only where an
explicit work order delegates that bounded action, and the apex owns every commit
otherwise.

`SubagentWorkflow` is off in the user's global `~/.pi/agent/subagents.json`.
`foreman-start.sh` turns it on for the foreman's worktree only, by rewriting
`<worktree>/.pi/subagents.json` to exactly `workflowsEnabled: true` and
`toolDescriptionMode: "compact"` before pi starts; branch-supplied keys are
dropped, and a write failure aborts the start. Before that, `core-rules/pi/lib/validate-project-pi.sh` refuses any
`.pi` content the protected base has not approved (B0-6); every Trellis pi
launcher runs it. A pi apex that needs workflows writes the same file in its
own cwd before it starts. A running agent keeps the tools it started with.

## Rules

1. **Cross-family verification is mandatory.** Reviewer, security reviewer, and refuters must not share a model family with the implementer. The resolver enforces it (`--implementer <agent>`); a foreman that cannot satisfy it reports `DEGRADED` rather than self-certifying.
2. **Quota decides, not preference.** Roles resolve from the live usage snapshot against ordered chains in `roles.json`; a chain with no candidate in quota is surfaced to the operator, never silently swapped for another family. Unmetered routes count as available; exhausted or disabled providers do not.
3. **Spend free compute on redundancy, not scope.** Three-vote adversarial refute per finding; two to three independent attempts plus a judge on hard units; loop-until-dry for discovery.
4. **Receipts are executed, never reported.** Apex and foreman each run the named receipt command and assert pass counts. Worker and foreman self-reports are claims.
5. **Contracts live on disk.** The brief (`HANDOFF.md`) is the session-survivable contract; it names the apex's hc address, worktree, decisions, environment traps, phase boundaries, and hard stops. Chat is not a contract.
6. **Preserve phase-boundary work under the work order's Git authorization.** The apex owns commits unless the work order explicitly delegates that bounded action to the foreman. When a phase's suites are green, the authorized owner commits if authorized; otherwise retain the diff and receipts for the apex without treating the skill as Git permission. A dead session leaving thousands of uncommitted lines is the failure this rule exists to prevent.
7. **Hard stops stay with the apex and operator.** PR, merge, deploy, prod mutation, secret handling, scope change.
8. **Stealth and unmetered routes get code and tests only.** No `.env`, tfvars, kubeconfigs, or tokens to third-party routes of unknown provenance.
9. **Finish includes teardown.** Accepted, superseded, or abandoned workstream → end the foreman (`hc kill <t>`, then `hc rm <t>`); it is a held resource like a named teammate.

## Visibility and teardown

- Delegated agents run as the apex's `hc` sub-agents (`hc run --bg`), listed under
  the apex in the Herdr app's Agents sidebar with live status. No pane is opened
  for them and Trellis carries no pane or grid placement; the operator peeks at an
  agent or pulls it into a pane with the app's own controls.
- Agents run interactively, never in a print mode (`pi -p`, `codex exec`,
  `claude -p`), so they stay watchable, steerable and available for another turn.
  Harness-native subagents and Dynamic Workflow agents are the only other route.
  Non-model jobs (process-gate runs, test suites) are outside this rule.
- End each agent you started as soon as its output is accepted, superseded, or
  abandoned (`hc kill <t>`, then `hc rm <t>`); never end terminals you did not
  start. On a review panel, end the reviewers before starting the judge: the judge
  reads their persisted reports, not live sessions.
- A stuck agent is the apex's to handle: hc notes the parent when a child goes
  `blocked`, errors or exits. The apex reads it (`hc read <t>`), answers within its
  authority, never forces past a permission prompt, and asks the operator for the
  rest.

## pi launch forms (1.1.0 and above)

Verified on pi 1.0 (2026-10-02) and unchanged on 1.1.0, the supported floor
([pi setup guide](../../AGENT_PI_SETUP.md), step 1).

Reviewer / one-shot form — an interactive pi sub-agent briefed at launch:

```sh
hc run --bg --name review-x --cwd <dir> pi --model <provider/model:effort> --tools read,grep,find,ls,write,bash --no-approve -nc @bundle.md "Review the bundle above. Read-only: write only out.md, then hc send $HC_TERMINAL_ID \"DONE out.md\"."
hc wait --children any   # the report arrives as your next input
hc kill review-x; hc rm review-x   # after reading out.md
```

On another machine add `--on laptop` (its address is then `laptop/t7`) and copy
the bundle there first.

- `--tools read,grep,find,ls,write,bash` is the minimum the report protocol needs:
  `write` for the findings file and `bash` for `hc send`. The brief bounds it to
  read-only work; `bash` can still mutate, so never point a reviewer at a tree
  whose changes would matter. Use `--no-tools` only when the apex collects the
  answer itself with `hc read`.
- `--no-approve` skips cwd project `.pi/` resources (global `defaultProjectTrust` is
  `always`). It is not a sandbox; user-level extensions still load.
- `-nc` turns off `AGENTS.md`/`CLAUDE.md` discovery, which otherwise loads whatever the
  trust setting, so repository instructions stay out of the review. User-level
  extensions and skills can still add context.

Foremen and implementers never pass `-nc`/`--no-context-files` or `--no-rules`:
they must ingest the worktree's CLAUDE.md/Trellis layer. Automated runs state the
project-trust decision explicitly (`--no-approve` or that the worktree's project
resources are intended); never silently add `--approve`.

Pi defaults to fullscreen; `hc read <t>` reads its screen and history.

Gemini 3.8 Flash tool use depends on the pi-antigravity version an agent loaded at
start. Under 0.7.0, both codemode-only and control failed with 20/20
`MALFORMED_FUNCTION_CALL`; under 0.9.0 the same synthetic read/grep/find/ls fixture
ran 16/16 correct with no malformed calls
([ADR](../../docs/adr/2026-10-02-pi-1.0-adoption.md)). `~/.pi/agent/settings.json`
shows the installed version, not what a running agent loaded: an agent started before
0.9.0 was installed (2026-10-03, about 03:30 IST) still runs 0.7.0 and stays
`--no-tools` until restarted. Re-probe with that fixture before relying on Gemini
tools for other tool shapes, and after any later pi-antigravity upgrade.
Codemode is not a default for any role; opt in per unit with `--tools …,codemode`,
with Sol multi-file batch edits the best fit. Sol missed the pilot bar
(≥20% fewer tokens, or lower wall time); Luna's 2.4% wall drop meets its letter,
but Luna never invoked codemode, so it shows no codemode benefit. See the [ADR](../../docs/adr/2026-10-02-pi-1.0-adoption.md)
for the A/B results.

## Precedent

One remediation spec on a fleet project (2026-08-20 → 22): a foreman completed 18 remediation tasks and died with ~7.7k uncommitted lines; the on-disk `HANDOFF.md`/`REVIEW-HANDOFF.md` let a fresh apex resume in minutes. Rules 5 and 6 are the direct lesson. The same review found receipt theatre exactly where one model family certified its own work — rule 1.
