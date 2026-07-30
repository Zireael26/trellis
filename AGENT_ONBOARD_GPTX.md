# Agent onboarding: GPTX session modes

> **Requires two subscriptions.** GPTX routes selected requests to GPT models through a local gateway, so it needs BOTH a Claude subscription and a Codex subscription. It is off by default (`gptx.enabled` in `trellis.config.json`, spec 028), and nothing else in Trellis depends on it — a single-subscription install is fully functional without ever enabling GPTX.

This runbook is for an LLM or human installing GPTX from a Trellis checkout on a
Mac. Follow it in order, show every state-changing command before it runs, and stop
on a failed gate. Never ask anyone to paste a credential into chat.

GPTX is an unofficial local integration. Claude Code remains the terminal and agent
harness, cmux remains the workspace manager, Trellis chooses the model/advisor/delegate
topology, and CLIProxyAPI translates only requests whose model ID is explicitly GPT or
Codex. GPTX does not patch Claude Code and does not require the OpenAI Codex plugin for
Claude Code, `codex-worker`, or any plugin marketplace installation.

> Anthropic documents Anthropic-format gateways, but states: “Anthropic doesn't
> endorse, maintain, or audit third-party gateway products, and doesn't support routing
> Claude Code to non-Claude models through any gateway.” GPTX therefore remains
> unofficial and unsupported by Anthropic. Read the
> [official gateway boundary](https://code.claude.com/docs/en/llm-gateway) before
> installing.

## What this release installs

- a loopback split router on `127.0.0.1:8318`;
- the reviewed CLIProxyAPI fork on `127.0.0.1:8317`;
- `cmux-trellis-teams` and `gptx-doctor` command links;
- session policy and the Agent provider guard;
- `gpt-mid`, `gpt-high`, `gpt-sol`, `gpt-terra`, and `gpt-sol-advisor` definitions;
- reversible launch agents, settings overlay, backups, and install manifest.

The macOS installer is the tested service path. Linux service installation is not part
of this release. The router and tests are ordinary Node/Bash code, but a non-macOS
operator must design and review their own service manager and credential injection.

## Safety contract

These invariants are mandatory:

1. Bind both local services to `127.0.0.1`, never a public interface.
2. Claude subscription OAuth may traverse the Trellis router only on the
   byte-preserving `api.anthropic.com` lane.
3. Never send Claude OAuth, `x-api-key`, or copied Claude request headers to
   CLIProxyAPI.
4. Store the local CLIProxyAPI key in macOS Keychain. Never print it, commit it, add it
   to a prompt, or read it back into a transcript.
5. Keep the advisor callback on a high-entropy loopback URL. Queueing, advice, and the
   GPT continuation share one absolute deadline; duplicate delivery reuses one pending
   transaction or settled response.
6. Preserve `CLAUDE_CODE_MAX_CONTEXT_TOKENS=272000` for the current Codex subscription
   catalog and leave `CLAUDE_CODE_AUTO_COMPACT_WINDOW` unset process-wide.
7. Preserve auth/quota/rate-limit cooling. Only transient 408/5xx credential-wide
   cooldown is disabled; those requests still fail normally.
8. Explicit `--advisor`, `--delegates`, and `--model` selections fail closed. Never
   rewrite or silently substitute a selected lane.
9. A **delegated** Terra unit may mutate unadvised — the orchestrator's review of the
   finished diff is the gate (advice-before-mutation retired 2026-07-30) — except for
   irreversible work: destroying data, writing outside declared paths, or externally
   visible effects still require advice, or Terra stops with no mutation. Terra as the
   **main** model has no orchestrator above it, so such a session must be able to reach a
   Claude-family oracle (`--advisor auto|opus|fable`, or `--delegates claude|auto`);
   `--advisor sol` is same-family and does not qualify.
10. Only a root session intentionally creates a named teammate. Nested Agent calls omit
    `name` and return directly.
11. Back up settings and proxy configuration and retain the install manifest.
12. Never install, upgrade, uninstall, reload, or replace GPTX services underneath an
    active Claude Code/GPTX session. Wait for every routed session to exit naturally.

See [GPTX security and trust boundaries](docs/gptx-security.md) for the threat model and
failure matrix.

## 1. Discover the machine

Run:

```bash
uname -s
command -v node jq go claude cmux codex security launchctl
claude --version
codex --version
cmux --version
```

Required for the tested path:

- macOS;
- Node.js, `jq`, Claude Code, cmux, Codex CLI, Keychain CLI, and `launchctl`;
- Go matching the maintained fork's `go.mod` when building from source;
- a working Claude Code subscription login for Claude requests;
- a working Codex login imported into CLIProxyAPI for GPT requests.

If cmux is installed as an app but absent from `PATH`, Trellis also checks
`/Applications/cmux.app/Contents/Resources/bin/cmux`.

## 2. Build and test the maintained fork

Release provenance:

- maintained fork: [__GITHUB_USER__/CLIProxyAPI](https://github.com/__GITHUB_USER__/CLIProxyAPI);
- upstream: [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI);
- reviewed pin:
  [`108b2a535b0241491436149b65cfb78734c61280`](https://github.com/__GITHUB_USER__/CLIProxyAPI/commit/108b2a535b0241491436149b65cfb78734c61280);
- license: MIT.

The same values live in `scripts/gptx/proxy-fork.json`. Stop if that file and this
runbook disagree.

```bash
git clone --branch main https://github.com/__GITHUB_USER__/CLIProxyAPI.git
cd CLIProxyAPI
git checkout 108b2a535b0241491436149b65cfb78734c61280
go test ./sdk/api/handlers/claude
mkdir -p bin
go build -o bin/cliproxyapi-trellis ./cmd/server
```

The fork recognizes only the Trellis loopback advisor callback. It converts the
translated GPT advisor tool call into Claude Code's `server_tool_use` transaction,
returns `advisor_tool_result`, and merges one GPT continuation into the same response.
It never needs an Anthropic credential.

## 3. Configure CLIProxyAPI and Codex authentication

Create or reuse a CLIProxyAPI YAML configuration that:

- binds `host: 127.0.0.1` and port `8317`;
- uses an auth directory owned by the current user;
- contains a non-example local API key;
- points at a current Codex login.

Follow the [CLIProxyAPI upstream documentation](https://github.com/router-for-me/CLIProxyAPI)
for its complete config and login format. GPTX additionally enforces these top-level
recovery values and backs up the original file:

```yaml
request-retry: 1
disable-cooling: false
transient-error-cooldown-seconds: -1
```

If no current Codex token exists, run the login privately in the operator's terminal:

```bash
/path/to/cliproxyapi-trellis -config /path/to/cliproxyapi.yaml -codex-login
```

This uses Codex/ChatGPT authentication through CLIProxyAPI. It does not install or use
the OpenAI Codex plugin for Claude Code.

## 4. Store the local proxy key without exposing it

The Trellis router and CLIProxyAPI must share the same local API key. The default macOS
service reads Keychain service `cliproxyapi-key` for the current user. Have the operator
enter the configured key directly into their terminal; do not relay it through chat:

```bash
read -s GPTX_PROXY_KEY
security add-generic-password -U -a "$USER" -s cliproxyapi-key -w "$GPTX_PROXY_KEY"
unset GPTX_PROXY_KEY
```

Do not run `security find-generic-password -w` in an agent transcript. Presence can be
checked without revealing the value:

```bash
security find-generic-password -a "$USER" -s cliproxyapi-key >/dev/null
```

`GPTX_PROXY_KEY_FILE` is supported by the router for a custom, directly managed process,
but the shipped launch agent uses Keychain. A custom service definition must explicitly
provide that environment variable and keep the file outside the repository with mode
`0600`.

## 5. Inspect the install before mutation

First confirm no routed Claude Code/GPTX session is active. On an upgrade, wait for every
session to exit naturally. Do not stop sessions or restart services to manufacture a
maintenance window.

From the Trellis checkout:

```bash
scripts/gptx/install.sh \
  --proxy-bin /path/to/CLIProxyAPI/bin/cliproxyapi-trellis \
  --proxy-config /path/to/cliproxyapi.yaml \
  --replace-running-proxy \
  --dry-run
```

The JSON must show:

- `claude_code_max_context_tokens: "272000"` from the Codex catalog;
- `auto_compact_window: "unset"`;
- the intended fork binary and proxy config;
- one retry, global cooling enabled, transient cooldown disabled;
- `replace_running_proxy: true`;
- `start_services: true`.

Stop if any path, context value, policy version, or service action is unexpected.

## 6. Install in the maintenance window

Run the same command without `--dry-run`:

```bash
scripts/gptx/install.sh \
  --proxy-bin /path/to/CLIProxyAPI/bin/cliproxyapi-trellis \
  --proxy-config /path/to/cliproxyapi.yaml \
  --replace-running-proxy
```

The installer:

- preserves the first pre-GPTX settings and proxy backups across later upgrades;
- writes `ANTHROPIC_BASE_URL=http://127.0.0.1:8318`;
- writes `CLAUDE_CODE_MAX_CONTEXT_TOKENS=272000` and removes any process-wide
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` override;
- installs command and Agent links backed by this checkout;
- installs the reviewed fork binary and launch agents;
- records rollback state in `~/.trellis/gptx-install.json`.

The launcher checks gateway health before each routed session. Missing or inactive
recorded launch agents are restored before cmux starts; a gateway that remains unhealthy
blocks launch with a concrete reinstall instruction.

## 7. Certify before real work

Run:

```bash
curl -fsS http://127.0.0.1:8318/__gptx/status | jq '{
  state, upstream, advisor
}'
gptx-doctor --certify
```

`gptx-doctor --certify` checks:

- the offline routing table;
- Anthropic subscription OAuth through the real Claude CLI;
- GPT completion, tool translation, and structured output;
- the advisor server-tool bridge;
- an immediate post-advisor GPT completion;
- proxy retry/cooling policy;
- every `gpt-*` agent slug against the alias table of the **running** router, not the
  checkout's. A router process older than the checkout serves a profile whose alias it
  has never loaded, and delegating to it returns `502 unknown provider`.

Exit `0` means every probe passed. Exit `1` means a failed check — a real break, normally
an upgrade that changed translation. Exit `2` means GPT translation stayed unverified
because the lane never reached the model, and the line prefix says which cause:

- `QUOTA` — Codex auth, quota, or cooldown unavailable. Repair billing or login.
- `UPSTR` — the provider itself returned a service error. Check the provider's status
  page and wait; nothing local is broken.

Exit `2` is not certification under either prefix. The two are deliberately not folded
together: they send you to different places.

### Expect `unverified` on day one, and do not chase it

The router records the **union** of every `anthropic-beta` flag it has seen, and reports
`state: unverified` when a flag appears that the certified baseline lacks. That union
grows with **session shape**, not only with upgrades — a subagent, a Skill, a headless
run, and a background task each send a different flag list, and some carry a
differently-dated variant of a family already certified. So the first session shape you
did not happen to run before certifying will flip the state and name a flag, with
nothing wrong.

Re-certify **once after a day of ordinary sessions**, not on each drift notice.
Certifying again immediately just bakes in another baseline taken before the common
shapes were observed, and you repeat it tomorrow. A standing `unverified` with the lane
serving normally is the honest state, not a defect.

Read that as a day of **router uptime**, not a day on the calendar. The baseline persists
to disk but the observed union does not — it lives in the router process, so a restart
empties it and the router re-accumulates from zero. Two consequences:

- `state: ok` shortly after a restart means "no unseen flag in the last few minutes", not
  "certified clean". Check `uptimeSeconds` alongside `state` before reading anything into
  it.
- Restarting does not clear drift, it postpones it. The flag returns the next time a
  session sends it. Certifying during that window writes a baseline off a union thinner
  than the one that was running, which is the same mistake as certifying too early.

Compare `betaCount` against the baseline's before certifying. Fewer flags than the
baseline means the union is still refilling; wait.

Confirm rather than assume before treating drift as a break: send a structured-output
request carrying the named flag several times. A real translation break is deterministic;
provider flake is not, which is why a single failing probe proves nothing in either
direction.

Then run the deterministic repository suites:

```bash
node scripts/tests/gptx-model-context.test.js
node scripts/tests/gptx-session-policy.test.js
node scripts/tests/gptx-delegation-guard.test.js
node scripts/tests/gptx-generated-docs.test.js
node scripts/tests/gptx-effort-alias.test.js
node scripts/tests/gptx-advisor-router.test.js
node scripts/tests/gptx-router-streamerr.test.js
bats scripts/tests/cmux-trellis-teams.bats
bats scripts/tests/gptx-install.bats
```

Generated policy docs must match byte-for-byte. Never repair generated tables manually.
The public release certification ledger is
[`specs/027-gptx-public-release/`](specs/027-gptx-public-release/).

## 8. Launch modes and independent selectors

No permission bypass is required by GPTX. Pass only the Claude Code/cmux permission flags
you would otherwise choose.

```bash
# Claude main loop with selectively addressed GPT agents
cmux-trellis-teams --mode gptx

# Sol xhigh main loop with Sol advisor
cmux-trellis-teams --mode codex

# Sol xhigh main loop with Opus and visible Sol fallback
cmux-trellis-teams --mode hybrid

# Direct Claude main loop
cmux-trellis-teams --mode claude
```

Main model, advisor, and Agent provider policy are orthogonal:

```bash
cmux-trellis-teams --mode hybrid --model sol --advisor fable --delegates auto
cmux-trellis-teams --mode hybrid --model terra --advisor fable --delegates gpt
cmux-trellis-teams --mode claude --advisor sol --delegates auto
cmux-trellis-teams --mode codex --advisor none --delegates gpt
cmux-trellis-teams --mode codex --delegates claude
cmux-trellis-teams --mode gptx --delegates none
```

Preserved interfaces:

```text
--mode gptx|codex|hybrid|claude
--advisor auto|opus|fable|sol|none
--delegates auto|gpt|claude|none
--model <alias-or-model-id>
```

Omitting `--delegates` is `auto`. Explicit provider locks reject the other provider and
unknown providers before Agent spawn. `none` rejects every Agent call. A permitted lane
that is unavailable still fails visibly; permission never authorizes substitution.

Agent profiles:

- `gpt-mid` → Sol medium;
- `gpt-high` → Sol high;
- `gpt-sol` → Sol xhigh;
- `gpt-terra` → Terra xhigh throughput lane. For a delegated unit a strong advisor is
  recommended, not required: the orchestrator review gate arbitrates the finished diff.
  Irreversible work still needs advice, and a Terra *main* model needs a reachable
  Claude-family oracle because no orchestrator sits above it.

Named Agent identities are teammate mailboxes, not background-task IDs. Use mailbox
messages and `SendMessage` for follow-up, consume unnamed subagent results directly, and
release named teammates with `TaskStop` when accepted or abandoned.

## 9. Troubleshoot by stage

| Symptom | Meaning | Safe action |
|---|---|---|
| Dry-run shows wrong path or context | Wrong checkout, catalog, or config | Stop. Fix input path or catalog before install. |
| `router not answering` | Router launch agent absent or unhealthy | Start no new routed session. Inspect launch-agent status; reinstall only after active sessions exit. |
| Anthropic probe fails | Subscription login, beta/header forwarding, or Anthropic lane broke | Hold GPTX use. Never route Claude traffic through the translator. |
| GPT probe returns `QUOTA` | Codex auth/quota/cooldown unavailable | Wait or repair Codex login. Do not count as translation PASS. |
| GPT probe returns `UPSTR` | Provider returned a service error; the lane never reached the model | Check the provider's status page and wait. Nothing local is broken; do not reinstall or re-auth. Do not count as translation PASS. |
| `state: unverified` with a flag named | A session shape sent an `anthropic-beta` flag the baseline lacks | Normal, and the lane keeps serving. Re-certify once after a day of ordinary sessions, not on each notice. |
| `NOT CERTIFIED — every probe must pass first. Baseline left unchanged.` | Any probe failed, or the lane returned `QUOTA`/`UPSTR` | Correct behavior. Clear that condition first; a baseline written off probes that never reached the model would certify nothing. |
| Advisor callback fails or remains pending | Fork/router mismatch, timeout, or provider failure | Capture sanitized status. Do not retry indefinitely or restart under an active session. |
| Explicit advisor/provider fails | Selected lane unavailable | Report that lane and stop. Do not substitute another provider. |
| Agent guard reports stale policy | Session predates installed policy/alias map | Exit naturally and relaunch through `cmux-trellis-teams`. |
| Terra reports blocked before edit | Advice unavailable for irreversible work (destructive, out-of-paths, externally visible) | Correct result. Restore advice capacity, narrow the unit to reversible edits, or select another model explicitly. |
| Terra main model rejected at launch | No Claude-family oracle reachable; `--advisor sol` does not qualify | Correct result. Use `--advisor auto\|opus\|fable`, or `--delegates claude\|auto`. |
| Generated-doc test differs | Resolver and checked-in tables drift | Regenerate from canonical resolver; never hand-edit rows. |
| Installer lacks existing settings/config | Prerequisite missing | Stop. Create valid Claude settings and CLIProxy config first. |

Status output and release receipts must stay sanitized. Never attach proxy config, auth
directory contents, Keychain values, prompts, or advisor bodies to a public issue.

## 10. Revert or uninstall

Use the same natural maintenance-window rule. Show the plan first:

```bash
scripts/gptx/install.sh --uninstall --dry-run
scripts/gptx/install.sh --uninstall
```

Uninstall restores the recorded Claude settings and original proxy config, removes only
recorded command/Agent links and launch agents, removes the installed fork binary when the
manifest owns it, and restarts the prior Homebrew CLIProxyAPI service when recorded.

If uninstall fails, preserve `~/.trellis/gptx-install.json` and the backup files. Do not
delete or overwrite them while diagnosing recovery.

## 11. Upgrade

1. Wait for all routed sessions to exit naturally.
2. Fetch the maintained fork and review changes from the recorded pin.
3. Run the fork tests and all Trellis GPTX tests.
4. Build the new fork binary.
5. Inspect installer `--dry-run`.
6. Install and rerun `gptx-doctor --certify`.
7. Update `scripts/gptx/proxy-fork.json`, this runbook, security docs, and certification
   receipts together.

Never update the fork, router, or installed service independently without rerunning the
matching certification surface.
