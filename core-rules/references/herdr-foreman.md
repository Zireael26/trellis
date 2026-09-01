# herdr-foreman — multi-model orchestration inside Herdr

Applies when a session runs inside Herdr (`HERDR_ENV=1`). Executable procedure and
quota-aware role chains live in the user-level skill `~/.claude/skills/herdr-foreman/`;
the OMP side of the contract is in `~/.omp/agent/AGENTS.md` § Foreman contract. This
file states the rules those two must agree on.

## Topology

| Role | Who | Owns |
|---|---|---|
| Apex (one per project) | Claude in the pane that started the session | briefs, git, executed receipts, acceptance, operator-facing decisions |
| Foreman (one per worktree) | OMP parent session (Sol xhigh by default) driving `eval` | fan-out, worker choice, receipts it runs itself, **commits at phase boundaries** |
| Workers | named OMP agents chosen per role from live quota | one bounded unit each; never commit, push, or merge |
| Claude-only roles | Opus author, Claude code-reviewer (Agent tool) | durable prose; second-family review |

One writer per worktree. The foreman's cwd is the worktree, never the main checkout.

## Rules

1. **Cross-family verification is mandatory.** Reviewer, security reviewer, and refuters must not share a model family with the implementer. The resolver enforces it (`--implementer <agent>`); a foreman that cannot satisfy it reports `DEGRADED` rather than self-certifying.
2. **Quota decides, not preference.** Roles resolve from `omp usage --json` against ordered chains in `roles.json`; a chain with no candidate in quota is surfaced to the operator, never silently swapped for another family. Unmetered routes count as available; exhausted or disabled providers do not.
3. **Spend free compute on redundancy, not scope.** Three-vote adversarial refute per finding; two to three independent attempts plus a judge on hard units; loop-until-dry for discovery.
4. **Receipts are executed, never reported.** Apex and foreman each run the named receipt command and assert pass counts. Worker and foreman self-reports are claims.
5. **Contracts live on disk.** The brief (`HANDOFF.md`) is the session-survivable contract; it names the apex pane, worktree, decisions, environment traps, phase boundaries, and hard stops. Chat is not a contract.
6. **Commit at every phase boundary.** The foreman is the only process in the worktree allowed to commit and must do so when a phase's suites are green. A dead session leaving thousands of uncommitted lines is the failure this rule exists to prevent.
7. **Hard stops stay with the apex and operator.** PR, merge, deploy, prod mutation, secret handling, scope change.
8. **Stealth and unmetered routes get code and tests only.** No `.env`, tfvars, kubeconfigs, or tokens to third-party routes of unknown provenance.
9. **Finish includes teardown.** Accepted, superseded, or abandoned workstream → close the foreman pane; it is a held resource like a named teammate.

## Panel layout and teardown

A panel is a visible review surface and a held resource. Keep it readable enough
to review:

- Keep a panel to a readable 2x2 grid of at most four workers. When it has more
  than three workers, give that grid its own tab rather than stacking workers in
  a column or crowding the operator's working tab.
- Prefer visible panes when the operator needs to watch the work; reserve
  headless runs for throwaway bounded work.
- Close each worker pane as soon as its output is accepted, superseded, or
  abandoned. In a review panel, close reviewers before starting the judge: the
  judge reads their persisted reports, not live sessions. Close the panel's tab
  when the workstream finishes.

## Precedent

One remediation spec on a fleet project (2026-08-20 → 22): an OMP foreman completed 18 remediation tasks and died with ~7.7k uncommitted lines; the on-disk `HANDOFF.md`/`REVIEW-HANDOFF.md` let a fresh apex resume in minutes. Rules 5 and 6 are the direct lesson. The same review found receipt theatre exactly where one model family certified its own work — rule 1.
