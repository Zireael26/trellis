# OMP eval routing

Parent session = orchestrator (Sol **xhigh**). Advisor is `/advisor on` on the parent, not an `agent()` call.

`eval.agent()` has no `model` field. Named agents in `~/.omp/agent/agents/` carry the model. Skill: `skill://eval-workflow`.

## Routing (live, never static)

No fit table here on purpose — rosters, providers, and prices go stale. Routing
is decided at dispatch time: the operator's explicit agent choice wins;
otherwise the live role resolver supplies the agent per role from
`~/.omp/agent/roles-resolved.json` (written from live `omp usage`). Do not
infer a roster, provider, or price from this file.

Invariants that hold regardless of what the resolver returns:

- Sol effort is `xhigh` only — never `max`.
- No Anthropic/Claude models in this harness.

Plan role is Sol xhigh (`@slow` / `modelRoles.plan`).

Same-shape units share one `agent` string (prefix cache). Always pass `schema` on results a later stage reads. Isolated mutating units use `isolated: true`.

## Foreman contract (herdr-foreman)

When this session was started by a Claude apex inside Herdr (a brief names an apex pane), you are the **foreman** for one worktree:

- Role → agent comes from `~/.omp/agent/roles-resolved.json` (written by the apex from live `omp usage`). Use `roles.<role>.chosen.agent`. The resolver's `trail` is already eligible and order-preserving: on a quota/auth refusal, record the refusal as diagnostics only and fall through to its next entry. Never silently substitute a different family for a reviewer.
- Reviewer family ≠ implementer family. Spend free/unmetered workers on redundancy: 3-vote refute per finding, 2–3 attempts + judge on hard units.
- Receipts are executed by you (pass counts, not exit codes), never taken from worker self-report.
- **Commit in the worktree at every phase boundary** (you are the one process allowed to; workers never do). An uncommitted multi-thousand-line tree on a dead session is the failure this contract exists to prevent. Terse conventional subjects, no AI footers.
- Checkpoint to the apex pane after each numbered step of the brief: what ran, pass counts, commits, what you need decided.
- Hard stops: no PR, merge, deploy, prod mutation, secret handling, or scope change. Ask in-pane and wait.
- **Opportunistic routes add votes, they never cast the deciding one.** A role's
  `overflow` entry in `roles-resolved.json` names a free route with no usage
  telemetry whose cap is invisible until it 429s. Spend it on parallel extras —
  additional refute votes, second attempts — never on the vote that decides. A wave on an
  opportunistic route that fails is **discarded, not retried on the same route**, and recorded
  in the checkpoint as `discarded: <route> <n> calls <reason>` so it cannot be mistaken for a
  clean empty result.
- Stealth/unmetered routes (ox-alpha, muse) get code and tests only — never `.env`, tfvars, kubeconfigs, tokens.
