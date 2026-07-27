# Agent onboarding: GPTX session modes

This runbook is written for an LLM setting up Trellis on a user's Mac. Follow it in
order, show the user every state-changing command before it runs, and stop on a failed
gate. Do not ask the user to paste a credential into chat.

GPTX is an unofficial local integration. Claude Code remains the terminal, cmux remains
the workspace and team manager, Trellis chooses the provider topology, and CLIProxyAPI
translates only requests whose model ID is explicitly GPT/Codex.

## Safety contract

These invariants are mandatory:

1. Bind the router and CLIProxyAPI to `127.0.0.1`, never a public interface.
2. Claude subscription OAuth may pass through the Trellis router, but only on the
   byte-preserving `api.anthropic.com` lane.
3. Never send Claude OAuth, `x-api-key`, or copied Claude request headers to CLIProxyAPI.
4. The advisor callback is an uncredentialed, high-entropy, single-use loopback URL.
5. Do not set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` globally. GPT context comes from the
   installed Codex catalog; recognized Claude models keep their native window.
6. Back up Claude settings and retain the install manifest so the change is reversible.

The router and fork have executable tests for items 2–4. If those tests fail, do not
install.

## 1. Discover the machine

Run:

```bash
uname -s
command -v node jq go claude cmux codex
claude --version
codex --version
cmux --version
```

Required:

- macOS;
- Node.js, `jq`, Claude Code, cmux, and Codex;
- Go matching the fork's `go.mod` when building from source;
- a working Claude Code login for Claude modes;
- a working Codex login imported into CLIProxyAPI for GPT modes.

If `cmux` is installed as an app but absent from `PATH`, Trellis also checks
`/Applications/cmux.app/Contents/Resources/bin/cmux`.

## 2. Build and test the maintained fork

Use the exact repository, branch, and verified commit recorded in
`scripts/gptx/proxy-fork.json`:

```bash
git clone --branch codex/trellis-advisor-tool \
  https://github.com/__GITHUB_USER__/CLIProxyAPI.git
cd CLIProxyAPI
git checkout 0748dccf
go test ./sdk/api/handlers/claude
mkdir -p bin
go build -o bin/cliproxyapi-trellis ./cmd/server
```

The fork adds one bounded behavior: when a GPT model asks for Claude Code's `advisor`
tool, it posts to a validated loopback callback and converts the ordinary translated
tool call into Claude's `server_tool_use` plus `advisor_tool_result` transcript. The
router then performs one main-model continuation and the fork merges it into that same
server-tool response. It does not receive or store Anthropic credentials.

## 3. Prepare CLIProxyAPI without exposing its key

The configuration must bind host `127.0.0.1`, port `8317`, use an auth directory owned
by the user, and contain a non-example API key. Reuse a working configuration when one
exists. Never print its key.

Run CLIProxyAPI's Codex login if no current Codex token exists:

```bash
./bin/cliproxyapi-trellis -config /path/to/cliproxyapi.yaml -codex-login
```

The Trellis router needs the same local API key. On macOS, ask the user to run the
following privately in their terminal, replacing the placeholder with the configured
key:

```bash
read -s GPTX_PROXY_KEY
security add-generic-password -U -a "$USER" -s cliproxyapi-key -w "$GPTX_PROXY_KEY"
unset GPTX_PROXY_KEY
```

Do not read the value back into the transcript. Non-Keychain installations may set
`GPTX_PROXY_KEY_FILE` to a mode-600 file outside the repository.

## 4. Dry-run, install, and retain the receipt

From the Trellis checkout:

```bash
scripts/gptx/install.sh \
  --proxy-bin /path/to/CLIProxyAPI/bin/cliproxyapi-trellis \
  --proxy-config /path/to/cliproxyapi.yaml \
  --replace-running-proxy \
  --dry-run
```

Inspect the JSON. It must show:

- `claude_code_max_context_tokens` derived from the Codex catalog;
- `auto_compact_window` equal to `unset`;
- the intended proxy binary and config;
- `replace_running_proxy: true`.

Then run the same command without `--dry-run`. The installer:

- backs up `~/.claude/settings.json`;
- enables the local split router for the user's existing
  `cmux claude-teams ...` command;
- installs `cmux-trellis-teams` and `gptx-doctor` command links;
- installs the five public GPT agent definitions;
- installs the fork binary and reversible launch agents;
- records the prior state in `~/.trellis/gptx-install.json`.

## 5. Certify before starting real work

Run:

```bash
curl -fsS http://127.0.0.1:8318/__gptx/status | jq '{
  state, upstream, advisor
}'
gptx-doctor --certify
```

Then run repository tests:

```bash
node scripts/tests/gptx-model-context.test.js
bats scripts/tests/cmux-trellis-teams.bats
node scripts/tests/gptx-advisor-router.test.js
node scripts/tests/gptx-router-streamerr.test.js
```

Certification must prove Claude pass-through, GPT completion, tool translation,
structured output, and an advisor call. A Codex quota result is `QUOTA`, not a passing
translation proof.

## 6. Launch the four modes

The user's existing command keeps selective GPTX routing:

```bash
cmux claude-teams --dangerously-skip-permissions
```

First-class modes use:

```bash
# Claude main loop plus selectively addressed GPT agents
cmux-trellis-teams --mode gptx --dangerously-skip-permissions

# Terra implementer and Sol advisor; no Claude advisor quota required
cmux-trellis-teams --mode codex --dangerously-skip-permissions

# Terra implementer, Opus advisor, automatic visible fallback to Sol
cmux-trellis-teams --mode hybrid --dangerously-skip-permissions

# Direct Claude session when Codex is exhausted
cmux-trellis-teams --mode claude --dangerously-skip-permissions
```

Override either role:

```bash
cmux-trellis-teams --mode hybrid --model sol --advisor fable
cmux-trellis-teams --mode hybrid --model terra --advisor sol
cmux-trellis-teams --mode claude --advisor sol
cmux-trellis-teams --mode codex --advisor none
```

`--advisor sol` on a Claude main session uses the explicit read-only
`gpt-sol-advisor` agent. Anthropic executes its own built-in advisor upstream, so a
byte-preserving Claude pass-through cannot replace that server call after the fact.

All unrecognized arguments are forwarded in order to `cmux claude-teams`; panes, teams,
hooks, resumability, and the user's permission flag remain cmux behaviors.

## 7. Observe fallback and restore

The first automatic Opus limit response creates one visible switch notice and persists
Sol as the advisor until the retry time. Inspect it with:

```bash
curl -fsS http://127.0.0.1:8318/__gptx/status | jq '.advisor'
```

Trellis probes Opus after the recorded retry time. A successful probe restores Opus and
emits one restore notice. Force the next advisor call to probe immediately:

```bash
curl -fsS -X POST http://127.0.0.1:8318/__gptx/advisor/retry | jq
```

Explicit `--advisor opus`, `fable`, or `sol` is pinned and does not silently switch.

## 8. Revert

Show the user the dry-run, then revert:

```bash
scripts/gptx/install.sh --uninstall --dry-run
scripts/gptx/install.sh --uninstall
```

The uninstall restores the settings backup, removes only the recorded links, services,
and installed fork binary, and restarts the prior Homebrew CLIProxyAPI service when the
manifest says it was running.

## 9. Update

Fetch the maintained fork, review its diff from the recorded verified commit, rerun the
fork unit test and all Trellis tests, rebuild, and rerun the installer with the new
binary. Never update the fork and router independently without certification.
