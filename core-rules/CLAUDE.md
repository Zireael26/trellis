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

- Ignore the default "try the simplest approach / don't refactor beyond what was asked" directive. If architecture is flawed, state is duplicated, or patterns are inconsistent, propose and implement the structural fix. Ask "what would a senior perfectionist dev reject in code review?" Fix that.
- Write code that reads like a human wrote it. No robotic comment blocks. Default to no comments. Only comment when the WHY is non-obvious.
- Commit messages follow the same rule: terse, human voice, no `Co-authored-by: Claude` or `🤖 Generated with Claude Code` footers.
- Don't build for imaginary scenarios. Simple and correct beats elaborate and speculative.

## Context management

- Before any structural refactor on a file >300 LOC, remove all dead props, unused exports, unused imports, debug logs. Commit cleanup separately.
- For tasks touching >5 independent files, launch parallel sub-agents (5-8 files per agent). Each gets its own ~167K context window. Sequential processing of 20 files guarantees context decay by file 12.
- After 10+ messages, re-read any file before editing it. Auto-compaction may have destroyed your memory of its contents.
- If you notice context degradation (referencing nonexistent variables, forgetting file structure), run `/compact` proactively. Write session state to `context-log.md`.
- Each file read is capped at 2000 lines. For files >500 LOC, use offset and limit to read in chunks.
- Tool results over 50K chars get truncated to a 2KB preview. If results look suspiciously small, re-run with narrower scope or read the source directly.

## Edit safety

- Before every file edit, re-read the file. After editing, read it again. The Edit tool fails silently on stale `old_string` matches.
- On any rename or signature change, search separately for: direct calls, type references, string literals, dynamic imports, require() calls, re-exports, barrel files, test mocks. Assume grep missed something.
- Never delete a file without verifying nothing references it.

## Definition of done

- Receipts required. When declaring done, include the verification command you ran, its exit code, and the diff lines that prove the change. "It works" without receipts is not done.
- Open todos mean not done. If `TodoWrite` has `in_progress` or `pending` items, complete them, defer with a reason, or abandon with a reason. The Stop hook enforces this.
- On edit-heavy turns a code-review subagent runs against the diff. Resolve findings or explicitly acknowledge and defer them. You do not self-mark your own homework.
- For UI-visible changes, verify visually: run the dev server, take a computer-use screenshot (fallback: headless Playwright), attach it. Logically verified is not visually verified.

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
- Terse responses. No trailing summaries of what was just done — the user can read the diff.
- Flag real problems up front. Don't bury them under "here's what I did."

## Hooks

Full hook specifications in `hooks.md` (sibling file). Two tiers: **fast-local** fires on every turn (`block-destructive`, `post-edit-verify`, `truncation-check`, `session-context`, `save-context-log`, `post-compact-context`); **heavy-gated** fires on wrap-up (`stop-verify`, `code-review-subagent`, `ui-verify`). Claude Code uses `.claude/hooks/` and `.claude/settings.json`; Codex uses `.codex/hooks.json` and `.codex/hooks/`. Git-boundary tier (husky / native git hooks): `pre-commit`, `commit-msg`, `pre-push` — pre-push includes the SE Core PR-flow guard blocking direct push to `main`.

## Skills

Canonical skills under `core-rules/skills/<name>/`. Inherited by every project via `.claude/skills/<name>/` symlink (and `.agents/skills/<name>/` for Codex-enabled projects). Current canonical skill: **process-gate** — pre-PR enforcement of commit format, PR size, secrets, bypass markers, tests, docs discipline, and stack-profile validators. Mandatory before merging to `main`. Spec: `core-rules/skills/process-gate/SKILL.md`.

## Project-local files every project maintains

- `CLAUDE.md` — project-specific rules only. No duplication of this file. Target <5 KB.
- `gotchas.md` — lessons logged as they happen.
- `context-log.md` — maintained by the `save-context-log` hook.

## Control plane

Active projects opt in via `registry.md`; temporary exemptions in `blacklist.md`. Audits, registry, and project onboarding live in `__SE_CORE_PATH__/`. Narrative manual (why/how, onboarding playbook, incident patterns, glossary): `__SE_CORE_PATH__/engineering-process.md` — read on demand when you need deeper context than these terse rules give you. Target <5 KB for this file; split deeper reference into sibling docs on demand.

## Inheritance

Load-bearing inheritance mechanism (symlink + @-import, skills inheritance, multi-harness Claude Code + Codex layout, silent-drop invariants, registered-project checklist): `core-rules/inheritance.md`. The scheduled `cross-project-process-audit` fails a project missing required Claude inheritance; Codex-enabled projects are also checked for `AGENTS.md`, `.agents/`, and `.codex/` parity.
