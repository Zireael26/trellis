# Publish GPTX as a standard Trellis feature

Date: 2026-07-27
Updated: 2026-07-29
Status: Accepted; publication gated by Spec 027 live certification
Specs: `specs/022-multi-model-session-modes/`, `specs/027-gptx-public-release/`
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

Anthropic now documents the product boundary explicitly: supported gateway wire formats do
not imply support for non-Claude models, and Anthropic does not endorse, maintain, or audit
third-party gateway products. Public GPTX documentation must quote and link that boundary,
describe participation as native-feeling rather than Anthropic-native, and hold publication
until live certification proves every public Agent, team, Workflow, advisor, and rollback
claim.

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
8. Default both GPT-backed main-session modes to Sol xhigh. Terra remains a fast
   bounded-work teammate and an explicit `--model terra` escape hatch, but it may not
   run with advisor `none` and must receive smarter advice before editing.
9. Treat advisor recovery as one end-to-end contract: bound callbacks and timeouts in
   the router, configure reversible proxy retry/cooldown behavior, verify the installed
   gateway in the doctor, and revive absent installed launch agents before a routed
   cmux session.
10. Treat Agent slot aliases as launcher-scoped capability names, not provider identity.
    Export and version the effective child alias map, classify after resolution, preserve
    literal full model IDs, and fail closed when inherited mapping and defaults disagree.
11. Make `gpt-mid`, `gpt-high`, `gpt-sol`, and `gpt-terra` the canonical GPT executor
    identities wherever GPTX Agent capability exists. Preserve the flat named-teammate and
    unnamed-subagent lifecycle supplied by Claude Code.
12. Treat the OpenAI Codex plugin for Claude Code and `codex-worker` as optional legacy
    compatibility. GPTX setup, certification, architecture, and examples must not depend on
    plugin installation; generic Codex CLI harness support remains independent.
13. Describe GPT participation as native-feeling use of existing Claude Code model, Agent,
    team, and tool surfaces. Never describe non-Claude routing as endorsed, audited,
    maintained, or supported by Anthropic.
14. Require Spec 027 live certification and full scratch-mirror inspection before public
    publication. Hermetic tests cannot substitute for live provider/team/Workflow proof.

## Consequences

- Public Trellis now contains an unofficial provider binding and must maintain it across
  Claude Code and CLIProxyAPI upgrades.
- The mirror lint changes from a blanket name ban to a narrow path allowlist; private
  namespaces, credentials, account identifiers, and absolute paths remain forbidden.
- cmux/tmux interaction is preserved because Trellis wraps `cmux claude-teams` instead of
  replacing it.
- A Claude-main/Sol-advisor session uses a read-only nested agent, because Anthropic
  executes its built-in advisor upstream before a pass-through proxy can replace it.
- Terra is not chosen automatically as an orchestrator. Explicit operator selection is
  still supported and fails closed before cmux when advice is disabled.
- The setup is reversible from an install manifest and settings backup.
- A routed session now fails closed with a reinstall instruction when the local gateway
  cannot be restored, rather than starting cmux against an unavailable endpoint.
- Public operators inherit an unsupported integration and must maintain the router,
  translator pin, credential boundary, live certification, and rollback discipline across
  Claude Code, Codex, and CLIProxyAPI changes.
- Native GPT Agent profiles replace plugin-companion delegation as the default GPT path.
  Existing plugin users may retain their command/job workflow, but its failure never
  silently selects a GPTX, Claude, or direct Codex lane.
- Public claims about advisor, named teammates, unnamed subagents, Dynamic Workflows, and
  reversible install remain release-gated until the corresponding Spec 027 rows pass.

## Review scope rationale

The advisor-recovery follow-up crosses the router, installer, doctor, launcher, tests,
operator documentation, and spec receipts. Its review diff is slightly larger than the
normal Trellis hard cap. Splitting those surfaces across separate PRs would temporarily
publish a partial recovery contract—for example retry behavior without callback cleanup,
or service revival without the matching install/doctor guidance—and make rollback depend
on commit ordering. Keeping the contract together gives reviewers one failure/recovery
story and preserves a single feature-level rollback boundary.

The Spec 025 alias amendment is also intentionally cohesive even though its executable
matrix pushes the review range above the ordinary hard line cap. Launcher defaults, locked
child environment, guard resolution, generated policy prose, installer packaging, and
fail-closed tests form one provider-boundary invariant. Splitting the matrix from the guard
would permit the same display-alias/provider drift to regress between commits. The branch
therefore uses this ADR as the explicit size exception and keeps live/service acceptance
outside the review range until the operator grants a maintenance window.

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

**Require the OpenAI Codex plugin as the GPT execution path.** Rejected. The plugin's
slash-command, companion, and background-job lifecycle is useful optional prior art, but
GPTX can route explicit GPT models and register GPT Agent profiles without it. Making the
plugin mandatory would add a second orchestration boundary and make plugin availability an
unrelated failure mode for main-model, Agent, team, and Workflow use.

**Publish from hermetic evidence alone.** Rejected. Fixtures prove routing, transforms,
retry bounds, and fail-closed policy; they do not attest a real provider, named teammate,
unnamed subagent, Dynamic Workflow, or reversible live installation. Spec 027 makes live
certification a hard publication dependency.
