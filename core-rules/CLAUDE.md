# Parent engineering rules

Cross-cutting rules that apply to every active personal project. Project-specific `CLAUDE.md` files extend this — they do not repeat it.

---

## Planning

- When asked to plan, output only the plan. No code until explicit approval.
- When given a plan, follow it exactly. Flag real problems and wait.
- For non-trivial features (3+ steps or architectural decisions), interview the user about implementation, UX, and tradeoffs before writing code.
- Never attempt multi-file refactors in one response. Break into phases of max 5 files. Complete, verify (hooks enforce), get approval, then continue.
- Don't hide confusion. If a request has multiple valid interpretations, surface them — don't pick silently. If something is unclear, stop and name what's confusing before guessing.
- Frame each task as a verifiable goal before writing code: bug → reproducing test that fails then passes; refactor → tests green before and after; new behavior → explicit acceptance check per step. Weak goals ("make it work") force back-and-forth; strong goals let you loop independently.

## Code quality

- Default to surgical scope: touch only what the task requires, match existing style, don't refactor adjacent code. Carve-outs: (a) if structural rot blocks the current task, flag and fix it in scope; (b) if you spot adjacent rot worth fixing, use `mcp__ccd_session__spawn_task` to spin a separate session — never silently bundle.
- No abstractions for single-use code. Three similar lines beat a premature factory.
- When two patterns in the codebase contradict, pick one (recency or test coverage), justify the choice, and flag the loser for cleanup. Don't blend or "average" them.
- Write code that reads like a human wrote it. No robotic comment blocks. Default to no comments. Only comment when the WHY is non-obvious.
- Commit messages follow the same rule: terse, human voice, no `Co-authored-by: Claude` or `🤖 Generated with Claude Code` footers.
- Don't build for imaginary scenarios. Simple and correct beats elaborate and speculative.

## Context management

- Before any structural refactor on a file >300 LOC, remove all dead props, unused exports, unused imports, debug logs. Commit cleanup separately.
- Dispatch sub-agents in parallel whenever work decomposes into independent units — not just file-count refactors. Use them when (a) parallelism cuts wall time meaningfully (≥2 independent searches, fetches, or analyses), or (b) bulky read-heavy work would bloat the main context window. Single message, multiple `Agent` tool calls. Skip for trivially serial work or when one result must inform the next.
- Token cost is real. Before spawning sub-agents, starting `monitor`, or fetching large files, ask if a narrower tool would suffice. Don't optimize for thoroughness when the question is small.
- If you notice context degradation (referencing nonexistent variables, forgetting file structure), run `/compact` proactively — the `save-context-log` hook fires on `PreCompact` and writes `context-log.md` automatically; do not author the file by hand.
- At session start, the `session-context` hook auto-injects the previous session's `context-log.md`. Treat that injection as authoritative for "what was I in the middle of" — branch, files touched, open todos, last decisions. Read it before asking the user to re-explain context. The log is stored at the canonical project root (resolved via `git --git-common-dir`), so worktree sessions see the same log as the main checkout.

## Edit safety

- Before every file edit, re-read the file. After editing, read it again. The Edit tool fails silently on stale `old_string` matches.
- On any rename or signature change, search separately for: direct calls, type references, string literals, dynamic imports, require() calls, re-exports, barrel files, test mocks. Assume grep missed something.
- Before adding new code in an unfamiliar area, read the immediate callers, the module's public exports, and any shared utilities it would touch. "Looks orthogonal" is dangerous — if you can't explain why the surrounding code is structured the way it is, ask.
- Never delete a file without verifying nothing references it.

## Definition of done

- Receipts required. When declaring done, include the verification command you ran, its exit code, and the diff lines that prove the change. "It works" without receipts is not done.
- Open todos mean not done. If `TodoWrite` has `in_progress` or `pending` items, complete them, defer with a reason, or abandon with a reason. The Stop hook enforces this.
- On edit-heavy turns a code-review subagent runs against the diff. Resolve findings or explicitly acknowledge and defer them. You do not self-mark your own homework.
- For UI-visible changes, verify visually: run the dev server, take a computer-use screenshot (fallback: headless Playwright), attach it. Logically verified is not visually verified.
- Tests must fail when business intent changes, not just when an implementation detail moves. A test you can't break by inverting the requirement is wrong — receipts only prove the assertion ran, not that it asserts anything load-bearing.

## Debugging

- Work from raw error data. Don't guess. If a bug report has no output, ask for it.
- For any long-running process (dev server, test watcher, build, log tail), use the `monitor` tool — never `tail -f`, polling loops, or repeated Bash calls. Monitor streams stdout lines as notifications with zero token overhead.
- If a fix doesn't work after two attempts, stop. Read the entire relevant section top-down. State where your mental model was wrong before trying again.

## Self-correction

- After any correction from the user, log the pattern to `gotchas.md` in the project root. Convert mistakes into rules. Review gotchas at session start.
- When pointed to existing code as reference, study it and match its patterns exactly. Working code is a better spec than English.
- When asked to test your own output, adopt a new-user persona. Walk through as if you've never seen the project.

## Communication

- When the user says "yes," "do it," or "push," execute. Don't repeat the plan.
- Terse responses. No trailing prose summaries — TodoWrite carries in-flight state, the diff carries the result.
- Flag real problems up front. Don't bury them under "here's what I did."

## Advisor

When the `advisor` tool is available (auto-forwards full conversation history; no parameters required), prefer Opus when model selection is offered. Call before substantive work — writing, locking an interpretation, declaring done — and when stuck. On multi-step tasks, call at least once before committing to an approach and once before declaring done. Skip on short reactive tasks where the next action is dictated by tool output you just read; over-calling burns tokens and yields little.

## Hooks

Two tiers — **fast-local** (every turn) and **heavy-gated** (wrap-up) — plus a **git-boundary** tier (husky / native git hooks) whose `pre-push` carries the SE Core PR-flow guard blocking direct push to `main`. Per-hook names, harness paths (`.claude/` vs `.codex/`), and event wiring live in `hooks.md`.

## Skills

Canonical skills under `core-rules/skills/<name>/`, inherited by every project via symlink (Claude Code: `.claude/skills/`; Codex: `.agents/skills/`). Current canonical: **process-gate** — mandatory pre-PR gate. Spec: `core-rules/skills/process-gate/SKILL.md`.

## Project-local files every project maintains

- `CLAUDE.md` — project-specific rules only. No duplication of this file. Target <5 KB.
- `gotchas.md` — lessons logged as they happen.
- `context-log.md` — maintained by the `save-context-log` hook on every `PreCompact` (Claude Code) / `Stop` (Codex). Stored at the canonical project root so it survives worktree cleanup. Auto-injected at session start by `session-context` and after compaction by `post-compact-context`. Never edit by hand.

## Control plane

Active projects opt in via `registry.md`; temporary exemptions in `blacklist.md`. Audits, registry, and project onboarding live in `/Users/abhishek/projects/se-core/`. Narrative manual (why/how, onboarding playbook, incident patterns, glossary): `/Users/abhishek/projects/se-core/engineering-process.md` — read on demand when you need deeper context than these terse rules give you. Target <5 KB for this file; split deeper reference into sibling docs on demand.

## Inheritance

Load-bearing inheritance mechanism (symlink + @-import, skills inheritance, multi-harness Claude Code + Codex layout, silent-drop invariants, registered-project checklist): `core-rules/inheritance.md`. The scheduled `cross-project-process-audit` fails a project missing required Claude inheritance; Codex-enabled projects are also checked for `AGENTS.md`, `.agents/`, and `.codex/` parity.
