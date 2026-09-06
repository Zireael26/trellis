# Codex model guidance — Astra and existing GPT workers

This filename is retained for existing links. Model-specific deltas live in
`core-rules/references/model-prompting-deltas.md`; direct-dispatch effort policy
lives in `docs/codex-routing.md`. This guide replaces the older GPT-5.x assumption
that Codex is only a secondary executor. The user-selected main agent owns
planning and synthesis, whether hosted by Codex, Claude Code, or pi.

## Working with Astra

OpenAI's [Astra model guide](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)
was checked on 2026-09-05. It highlights sensitivity to conflicting skill
instructions, excess clarification and testing, verbose output, and a need to
specify useful delegation. Trellis applies that advice through its shared rules:

- Let explicit user instructions resolve workflow choices; carry authorization
  forward, and identify the exact rule if a skill still requires a pause.
- State objective, scope, evidence, and output expectations. Keep instructions
  concise and use progressive disclosure for specialist procedures.
- Delegate substantial independent work when the host supports it and the work
  benefits. Group related units; preserve selected models and provider failures.
- Run checks appropriate to the change and all required gates. Repeat only when
  the artifact changes or evidence leaves an unresolved concern.

Treat these as behavior guidance, not a measured improvement on Trellis tasks.
Retain the existing worker roles until representative comparisons justify a change.

## Host capabilities

Use the tools actually present. Batch independent reads; serialize dependent
changes. Maintain task state through available plan tools or the task artifact.
Give short progress updates during sustained work, following the host's cadence;
report changed findings rather than narrating commands. Do not require absent
legacy names such as `multi_tool_use.parallel` or `TodoWrite`.

Native async tools, mid-turn steering, and cache-preserving effort updates need
host implementation. A prompt or hook cannot enable an unsupported API feature.
Trellis currently integrates existing harnesses; it should not add a Responses
client merely to duplicate facilities already supplied by them.

## API migration boundary

If a Trellis component starts making direct Astra API requests, verify the
[model's current API contract](https://developers.openai.com/api/docs/models/gpt-6-astra)
and the migration section of the guide before changing it. Tool calling requires
Responses; retain compatible effort, map `none`/`minimal` to `low`, and remove
unsupported sampling/logprob options. API effort and host-only modes are separate
surfaces. No direct API client, model pin, or fleet runtime is changed by this guide.
