# GPTX security and trust boundaries

GPTX is a local, unofficial gateway integration. It changes where selected Claude Code
requests travel, so its security claim is narrower than “local proxy equals safe.” This
document states what GPTX protects, what each component can see, how failures behave, and
what remains outside the guarantee.

Anthropic's official boundary is controlling:

> “Any gateway that exposes a supported API format works. Anthropic doesn't endorse,
> maintain, or audit third-party gateway products, and doesn't support routing Claude
> Code to non-Claude models through any gateway.”

Source: [Other LLM gateways](https://code.claude.com/docs/en/llm-gateway), accessed
2026-07-29. GPTX is not endorsed, audited, maintained, or supported by Anthropic.

## Security goals

GPTX aims to preserve these properties:

1. Claude subscription credentials reach only Anthropic.
2. CLIProxyAPI and GPT upstreams receive only proxy/Codex credentials.
3. Explicit GPT/Codex requests use the GPT lane; Claude and unknown IDs default to
   Anthropic.
4. Explicit model, advisor, and delegate selections fail closed without silent provider
   substitution.
5. Advisor callbacks are loopback-only, unguessable, bounded, deduplicated, and tied to
   one parent request.
6. GPT effort aliases cannot silently lose their requested effort tier.
7. A transient 408/5xx does not cool the only Codex credential for later requests, while
   authentication, quota, and rate-limit cooling remains enabled.
8. Installation and removal preserve stable rollback artifacts.
9. Public diagnostics and release receipts contain no secret values, prompts, or advice
   bodies.

These goals do not make a third-party model, translator, local process, or generated model
output trustworthy.

## Assets

- Claude Code subscription OAuth and Anthropic request headers;
- CLIProxyAPI local API key;
- Codex/ChatGPT authentication material managed by CLIProxyAPI;
- source code, prompts, tool results, and structured outputs sent through either lane;
- high-entropy advisor callback URLs;
- local settings, launch-agent definitions, proxy configuration, backups, and manifest;
- provider-selection, effort, and callback receipts.

## Trusted components

| Component | What it can see | What it must not receive |
|---|---|---|
| Claude Code | full conversation, tools, project context, saved subscription login | N/A; primary client |
| Trellis router | every routed request; in-memory Claude headers on Anthropic/Claude-advisor paths; local proxy key | Must not persist credentials or expose them in status |
| Anthropic | Claude-lane requests and Opus/Fable advisor context | Local proxy key, Codex auth |
| CLIProxyAPI fork | GPT prompts/tool traffic, callback URL, local proxy key, Codex auth path | Claude OAuth and `x-api-key` |
| GPT/Codex provider | translated GPT-lane prompts, tool traffic, Sol advisor context | Claude OAuth and Anthropic API key |
| cmux/launchd | process paths, arguments, environment/service lifecycle | Secret values in arguments or public logs |

The Trellis router is a sensitive trusted process even though it binds to loopback: it
sees request content and temporarily holds credentials needed for the selected lane.
CLIProxyAPI is also trusted with GPT-lane content and Codex authentication.

## Routing and credential flow

Closed predicate:

```text
explicit gpt-*, codex-*, oN*, *-sol|terra|luna -> CLIProxyAPI
claude-* and every unknown model              -> api.anthropic.com
```

Claude-prefix precedence runs before GPT suffix matching. This prevents a model ID such as
`claude-...-sol` from entering the GPT lane.

### Anthropic lane

The router removes Trellis-internal selection headers and otherwise forwards the request
byte-for-byte to `api.anthropic.com`. Saved Claude subscription OAuth remains active when
only `ANTHROPIC_BASE_URL` is set. Anthropic documents that gateways forwarding this
subscription traffic must preserve the OAuth capability in `anthropic-beta`.

### GPT lane

Before forwarding to CLIProxyAPI, the router:

- removes `authorization`;
- removes `x-api-key`;
- removes Trellis-internal selection headers;
- injects the local CLIProxyAPI key;
- recalculates `content-length` after any effort-alias normalization.

CLIProxyAPI then uses its own Codex authentication. Claude credentials are not copied,
translated, persisted in callback state, or sent to the GPT provider.

### Advisor paths

- **Opus/Fable advice:** router uses original in-memory Claude headers to call Anthropic
  directly. Those headers never pass through CLIProxyAPI.
- **Sol advice:** router builds fresh proxy-only headers and sends the bounded advisor
  context through CLIProxyAPI.
- **GPT continuation:** router sends one proxy-only continuation to the original GPT main
  model after removing the advisor tool.

Callback registry entries are memory-only. They may temporarily contain the parent request
body and headers required to complete the transaction. They are removed on parent
cancellation, deadline/expiry, or registry cleanup and are never returned by the status
endpoint.

## Local key handling

The shipped macOS service reads Keychain service `cliproxyapi-key` for the current user.
The key must never appear in:

- repository files;
- shell history as a literal argument;
- prompts or chat transcripts;
- status output;
- public issues, receipts, or screenshots.

Key presence may be checked without printing the value. A custom
`GPTX_PROXY_KEY_FILE` process must use a file outside the repository with mode `0600` and
must explicitly pass that environment variable to the router service. The shipped launch
agent does not configure a key file.

Codex authentication remains in CLIProxyAPI's configured auth directory. GPTX does not
copy those auth files into Trellis.

## Advisor callback controls

The callback is intentionally uncredentialed because CLIProxyAPI must call it. Its
controls are capability-based and bounded:

- router listens only on `127.0.0.1`;
- callback ID is 24 random bytes encoded as base64url;
- fork accepts only the internal loopback callback header path;
- callback body is capped at 64 KiB and must be valid JSON when present;
- one absolute 270-second deadline covers queue, advice, and continuation;
- default concurrency is two;
- one parent/session/turn identity maps to one callback transaction;
- duplicate delivery shares the pending promise or exact settled response;
- callback-delivery disconnect does not cancel shared work;
- original parent closure, transaction deadline, or registry expiry can cancel work;
- status exposes counts and sanitized last-receipt fields, not callback URLs or content.

A malicious same-host process that discovers a live callback URL could attempt delivery.
High entropy and short bounded lifetime reduce discovery risk; they do not defend against a
compromised router/CLIProxy process or same-user process able to inspect its memory or
traffic. Such a compromise is outside GPTX's trust boundary.

## Agent and Workflow controls

The Agent provider guard runs at the caller before spawn. It resolves explicit models,
launcher slot aliases, and registered Agent types before applying `--delegates`.

- `auto` permits known GPT, known Claude, and extension providers;
- `gpt` permits only resolved GPT;
- `claude` permits only resolved Claude;
- `none` rejects every Agent call;
- missing, stale, malformed, or mismatched alias-policy state rejects the call;
- guard never rewrites `model`, `subagent_type`, or `name`.

Workflow transport failure remains failure. Required stages preserve declared identities;
null, throw, missing identity, duplicate identity, or wrong schema identity prevents the
stage checkpoint and fails closed. An optional provider leg may be absent only when the
recipe declares it optional; it never authorizes silent substitution.

Terra's advice-before-mutation requirement was retired 2026-07-30 for **delegated** units:
the orchestrator's review of the finished diff is the gate, and a blocking advisory
round-trip cancelled the throughput advantage that is the only reason to select Terra.

Two parts of the old invariant survive, because the review-gate substitution does not
cover them:

- **Irreversible work.** Where a unit would destroy data, write outside its declared
  paths, or cause an externally visible effect, advice absence, failure, auth error, or
  quota error still returns blocked with zero mutation. Reviewing a diff cannot undo an
  effect that already landed.
- **Terra as the main model.** There is no orchestrator above a main loop, so the launcher
  rejects such a session unless a Claude-family oracle is reachable — `--advisor
  auto|opus|fable`, or `--delegates claude|auto` so a Claude reviewer can be spawned.
  `--advisor sol` is same-family review and does not qualify.

## Retry and cooling policy

Trellis-owned CLIProxyAPI config uses:

```yaml
request-retry: 1
disable-cooling: false
transient-error-cooldown-seconds: -1
```

Meaning:

- at most one proxy retry;
- transient 408/500/502/503/504 responses fail but do not mark the only Codex credential
  unavailable for later turns;
- authentication, quota, and rate-limit cooling remains active;
- advisor circuit breakers open after repeated matching transport/408/5xx failures and
  admit one bounded half-open probe;
- explicit advisor selections fast-fail while open;
- only `auto` may use the already documented and visibly stamped Opus-to-Sol fallback.

Retry-failure certification uses fake or isolated upstreams only. Do not inject faults into
live provider services.

## Failure matrix

| Failure | Detection | Result | Safe recovery |
|---|---|---|---|
| Router down | launcher readiness / doctor | Routed session blocked | Wait for active sessions to exit; inspect or reinstall in maintenance window |
| CLIProxy down | status readiness / GPT probe | GPT lane unavailable | No fallback; restore recorded service after safe-window inspection |
| Claude OAuth forwarding broken | real Claude probe | Certification FAIL | Hold release; inspect Anthropic lane/header handling |
| Local proxy key missing | router startup error | Router does not become ready | Add key privately to Keychain; never print it |
| Codex auth/quota unavailable | doctor `QUOTA` | GPT proof unavailable | Repair login or wait; not a PASS |
| Unknown model | routing table + upstream response | Goes to Anthropic; may fail there | Use an explicit supported model ID |
| Explicit advisor unavailable | transaction receipt | Selected lane fails | Select another lane explicitly or restore capacity |
| `auto` Opus limit | advisor receipt/status | Visible persisted Sol fallback | Wait for retry time or explicitly request retry probe |
| Advisor malformed/oversized callback | callback validation | Bounded 4xx/5xx settlement | Inspect fork/router version pin; no unbounded retry |
| Advisor timeout | transaction counter | Bounded 503 settlement | Capture sanitized status; diagnose provider/stage without restart under load |
| Duplicate callback | replay counter | One transaction, shared/replayed response | No action unless counts indicate integration drift |
| Stale Agent policy | guard denial | No Agent spawned | Relaunch naturally through current launcher |
| Locked provider mismatch/unknown | guard denial | No Agent spawned | Correct explicit model/provider selection |
| Required Workflow unit null/wrong identity | stage gate | Workflow fails closed | Repair selected lane or recipe; never filter failure away |
| Terra advice failure on irreversible work | agent contract | No mutation | Restore allowed advisor, narrow to reversible edits, or choose another model explicitly |
| Terra main model with no reachable Claude oracle | launcher policy | Session rejected before start | Use `--advisor auto\|opus\|fable`, or `--delegates claude\|auto` |
| Transient 408/5xx | proxy/router receipt | Request failure, no credential cooldown | Retry only within documented bound |
| Auth/quota/rate limit | proxy cooling | Credential cools normally | Wait or reauthenticate; no bypass |
| Install interrupted | manifest/backups/service state | Potential partial local state | Preserve artifacts; use captured rollback inventory in safe window |

## Reversible installation

Installer keeps stable first-install backups for:

- `~/.claude/settings.json`;
- original CLIProxyAPI config;
- prior Homebrew CLIProxyAPI running state.

Manifest `~/.trellis/gptx-install.json` records Trellis root, policy version, source paths,
Agent links, installed-fork ownership, backups, and prior service state. It contains local
paths and must not be published, but it contains no intended credential values.

Uninstall removes only recorded links/services/binary, restores recorded settings and
proxy config, and restarts the prior Homebrew service when recorded. Upgrade must preserve
the first rollback target rather than backing up an already-modified GPTX installation.

## Residual risks

1. **Unsupported client use.** Anthropic may change Claude Code behavior, policy, model
   schema, headers, or gateway compatibility without supporting this integration.
2. **Translator maintenance.** CLIProxyAPI must keep pace with Claude Code's API features.
   A translated completion can work while tools, structured output, or server tools break.
3. **Local process compromise.** Loopback prevents network exposure, not malicious
   same-host/same-user processes or a compromised router/translator binary.
4. **Provider data handling.** GPT-lane prompts and code leave Anthropic's provider
   boundary and are subject to the GPT/Codex provider's terms and account settings.
5. **Model behavior.** Provider routing does not make model output safe or correct. Normal
   permission, review, destructive-op, secret, and release gates remain required.
6. **Catalog drift.** Subscription context and supported aliases can change with a Codex
   update. Runtime catalog evidence wins over marketing/API model pages.
7. **Experimental team semantics.** Claude Code agent teams are experimental and have
   documented resumption, coordination, and shutdown limitations.
8. **Operational disruption.** Replacing services under active sessions can strand
   callbacks or invalidate in-flight work. GPTX forbids using active sessions to create a
   maintenance window.
9. **Logs and support bundles.** Local logs may contain model/provider error fragments and
   paths. Review and sanitize before sharing; never upload raw auth/config directories.

## Incident response

1. Stop starting new routed sessions. Do not kill existing user sessions.
2. Capture sanitized `gptx-doctor` output and `/__gptx/status` counters. Do not capture
   credentials, callback URLs, prompts, advice bodies, or raw proxy config.
3. Record installed Trellis SHA, CLIProxy pin, Claude Code/Codex versions, and manifest
   presence.
4. Classify failure by lane and stage: Anthropic, GPT translation, advisor advice,
   continuation, Agent guard, Workflow stage, or installation.
5. Reproduce retry/timeout failures only with fake or isolated upstreams.
6. Wait for every active routed session to exit naturally before service mutation.
7. If installation or certification failed, use captured manifest/backups to roll back in
   the same safe window.
8. Verify restored service health and credential separation before resuming work.
9. Publish only sanitized, minimal reproduction evidence.

## Verification sources

- setup and rollback: [Agent onboarding](../AGENT_ONBOARD_GPTX.md);
- architecture and model policy: [GPTX overview](gptx.md);
- generated policy tables:
  [session policy](gptx-session-policy-matrix.md) and
  [model overrides](gptx-model-override-matrix.md);
- public certification contract: [Spec 027](../specs/027-gptx-public-release/);
- source and prior-art provenance: [GPTX sources](references/gptx-sources.md).
