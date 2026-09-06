# herdr-foreman — multi-model orchestration inside Herdr

Applies when a session runs inside Herdr (`HERDR_ENV=1`). The executable procedure and
quota-aware role chains are the copy in the **active immutable Trellis release** under
`core-rules/skills/herdr-foreman/`; that release alone decides. A legacy user-level copy
under `~/.claude/skills/herdr-foreman/` may be read for discovery and never authorizes a
decision. This file states the rules the apex, foreman, and workers must agree on.

## Topology

| Role | Who | Owns |
|---|---|---|
| Apex (one per project) | the active user-selected main agent, in the pane that started the session | briefs, git, executed receipts, acceptance, operator-facing decisions |
| Foreman (one per worktree, optional) | pi parent session (Sol xhigh by default) driving dynamic workflows/subagents | fan-out, worker choice, receipts it runs itself, **commits at phase boundaries** when the work order delegates that bounded Git action |
| Workers | named pi subagents chosen per role from live quota | one bounded unit each; never commit, push, or merge |
| Configured named routes | e.g. an Opus author, a Claude code-reviewer via the Agent tool | the roles the classifier or the operator selected for this run — a configured route, not an identity that owns the role universally |

One writer per worktree. The foreman's cwd is the worktree, never the main checkout.
Renaming the apex grants nobody Git rights: a worker or foreman commits only where an
explicit work order delegates that bounded action, and the apex owns every commit
otherwise.

## Rules

1. **Cross-family verification is mandatory.** Reviewer, security reviewer, and refuters must not share a model family with the implementer. The resolver enforces it (`--implementer <agent>`); a foreman that cannot satisfy it reports `DEGRADED` rather than self-certifying.
2. **Quota decides, not preference.** Roles resolve from the live usage snapshot against ordered chains in `roles.json`; a chain with no candidate in quota is surfaced to the operator, never silently swapped for another family. Unmetered routes count as available; exhausted or disabled providers do not.
3. **Spend free compute on redundancy, not scope.** Three-vote adversarial refute per finding; two to three independent attempts plus a judge on hard units; loop-until-dry for discovery.
4. **Receipts are executed, never reported.** Apex and foreman each run the named receipt command and assert pass counts. Worker and foreman self-reports are claims.
5. **Contracts live on disk.** The brief (`HANDOFF.md`) is the session-survivable contract; it names the apex pane, worktree, decisions, environment traps, phase boundaries, and hard stops. Chat is not a contract.
6. **Preserve phase-boundary work under the work order's Git authorization.** The apex owns commits unless the work order explicitly delegates that bounded action to the foreman. When a phase's suites are green, the authorized owner commits if authorized; otherwise retain the diff and receipts for the apex without treating the skill as Git permission. A dead session leaving thousands of uncommitted lines is the failure this rule exists to prevent.
7. **Hard stops stay with the apex and operator.** PR, merge, deploy, prod mutation, secret handling, scope change.
8. **Stealth and unmetered routes get code and tests only.** No `.env`, tfvars, kubeconfigs, or tokens to third-party routes of unknown provenance.
9. **Finish includes teardown.** Accepted, superseded, or abandoned workstream → close the foreman pane; it is a held resource like a named teammate.

## Panel layout and teardown

A panel is a visible review surface and a held resource. Keep it readable enough
to review:

- Keep a panel to a readable 1+4 grid: the Apex orchestrator holds the full-height
  left 40%, and the right 60% fills on demand as a 2x2 of at most four foremen.
  Each completed foreman slot is 30% wide and half-height, smaller than the Apex.
  The orchestrator keeps full height because it is where the operator reads and
  coordinates; foremen are glanced at, not read line by line. Fill all four slots
  before giving the fifth foreman an overflow tab rather than shrinking the
  orchestrator or crowding the operator's working tab. Preserve operator focus.
  `--tab <label>` prefers an existing labelled tab with room, then the caller's
  tab with room, and labels a new tab only when both are full or unavailable.
- Prefer visible panes when the operator needs to watch the work; reserve
  headless runs for throwaway bounded work.
- Close each owned foreman or worker pane as soon as its output is accepted,
  superseded, or abandoned; never close unrelated operator panes. In a review panel, close reviewers before starting the judge: the
  judge reads their persisted reports, not live sessions. Close the panel's tab
  when the workstream finishes.

## Precedent

One remediation spec on a fleet project (2026-08-20 → 22): a foreman completed 18 remediation tasks and died with ~7.7k uncommitted lines; the on-disk `HANDOFF.md`/`REVIEW-HANDOFF.md` let a fresh apex resume in minutes. Rules 5 and 6 are the direct lesson. The same review found receipt theatre exactly where one model family certified its own work — rule 1.
