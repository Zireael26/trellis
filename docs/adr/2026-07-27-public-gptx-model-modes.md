# Publish GPTX as a standard Trellis feature

Date: 2026-07-27
Status: Accepted
Spec: `specs/022-multi-model-session-modes/`
Supersedes: the private-binding publication decision in
`docs/adr/2026-07-26-multi-model-lane-continuity.md`

## Context

Spec 021 published a proxy-agnostic continuity contract but intentionally withheld the
working local binding. The operator has now explicitly chosen the opposite product
boundary: Public Trellis should ship the unofficial integration, a maintained
CLIProxyAPI fork, and onboarding precise enough for another LLM to reproduce it.

The same review also exposed two functional gaps. Claude Code's local advisor eligibility
check rejected custom GPT IDs even though the gateway speaks the Anthropic contract, and
the global GPT context override was lower than the current Codex subscription catalog.

## Decision

1. Publish the split router, model predicate, doctor, installer, cmux launcher, and GPT
   agent roster.
2. Maintain the advisor bridge in the MIT CLIProxyAPI fork recorded by
   `scripts/gptx/proxy-fork.json`.
3. Preserve the credential boundary: Claude OAuth may traverse the trusted local router,
   but never CLIProxyAPI or a non-Anthropic upstream.
4. Use Claude Code's documented Opus alias pinning for GPT main sessions. This passes the
   local advisor capability gate while the request body retains the real GPT model ID.
5. Let `auto` fall back visibly from Opus to Sol on a Claude usage limit, persist a retry
   time, and restore Opus after a successful probe.
6. Discover GPT context from Codex's installed model catalog and leave the process-wide
   auto-compact override unset.
7. Keep the prior rule against silent main-model substitution. A mode or advisor change
   is selected at launch or reported visibly; the router does not disguise provider use.

## Consequences

- Public Trellis now contains an unofficial provider binding and must maintain it across
  Claude Code and CLIProxyAPI upgrades.
- The mirror lint changes from a blanket name ban to a narrow path allowlist; private
  namespaces, credentials, account identifiers, and absolute paths remain forbidden.
- cmux/tmux interaction is preserved because Trellis wraps `cmux claude-teams` instead of
  replacing it.
- A Claude-main/Sol-advisor session uses a read-only nested agent, because Anthropic
  executes its built-in advisor upstream before a pass-through proxy can replace it.
- The setup is reversible from an install manifest and settings backup.

## Alternatives considered

**Keep the binding private.** Rejected by the explicit public product decision; it leaves
the public continuity feature without the implementation that provides it.

**Patch or impersonate a Claude model ID in every request.** Rejected. Documented alias
pinning passes the local capability gate and still sends the true GPT ID.

**Set one global compaction window.** Rejected. It would trade GPT safety for premature
compaction of native 1M Claude sessions.

**Route Claude subscription traffic through the GPT translator.** Rejected. The
translation layer has no need for the credential and creates an unnecessary account and
security boundary.
