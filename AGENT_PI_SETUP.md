# Trellis pi harness setup

This recipe supports pi **1.1.0 and above**, and installs 1.1.0, the version the reference
setup runs. Earlier pi versions are not supported: `trellis doctor` warns below 1.1.0. It
installs no computer-use tools: pi has none in this setup. Route a unit that needs a browser page or
a native desktop app to Codex CLI as an hc sub-agent or to Claude Code, as
[Computer use with Pi](docs/PI-COMPUTER-USE.md) describes; that page also covers removing an
earlier install.

This guide has two reading modes:

- **Skim:** the checklist below shows the complete order and the expected checkpoint.
- **Execute:** run every numbered **Command** and **Verify** block in order in the same Bash shell. Stop on the first non-zero exit. Within a step, do not substitute versions, paths, or settings — those are pinned for a reason the reasoning section gives. Providers and models are the one thing you *are* expected to swap; see the next section. Blocks marked **UNVERIFIED** are operator actions and are the only exceptions.

The operator input is seven credential actions: paste two OpenCode Go keys and one OpenRouter key into hidden terminal prompts, then complete the ChatGPT Codex, xAI, `antigravity` (Google), and GitHub Copilot OAuth browser flows. The executing agent must hand those actions to the operator and must never ask the operator to paste a secret into chat.

## What this repository does and does not ship

The boundary is a **subset**, not the whole pi tree. The public publisher withholds exactly two directories under `core-rules/pi` — `agents/`, the provider roster, and `extensions/tests/`, the web-search extension's test suite, whose fixtures the mirror lint rejects — and publishes everything else there. So the machinery this guide depends on is in the public mirror:

| Published | What it is |
|---|---|
| `core-rules/pi/patches/` | the version-pinned patch bundles, their installers, their regression tests and `COMPACTION.md` |
| `core-rules/pi/extensions/trellis.ts` | the pi extension |
| `core-rules/pi/extensions/trellis-web-search.ts` | the always-loaded web-search extension step 2 installs |
| `core-rules/pi/hooks/dispatch.sh` | the hook dispatcher |
| `core-rules/pi/statusline/omp-statusline/` | the `omp-statusline` footer fork source (the upstream `pi-statusline` footer plus OMP-parity segments); install with `npm install --omit=dev --legacy-peer-deps` inside the copied directory |
| `core-rules/pi/tests/` | the boundary and transport tests |
| `core-rules/inheritance-manifest.json` | the manifest the attach planner reads, projected so it declares no withheld source |

Two things stay private, because each states a specific operator's live provider accounts rather than any portable rule:

| Not published | Why | What this guide gives you instead |
|---|---|---|
| `core-rules/pi/agents/*.md` | one pinned `model:` per agent is a direct statement of which provider subscriptions the author holds | the agent-file schema, a template, and the fail-closed boundary rules the roster must satisfy (step 9) |
| `core-rules/skills/herdr-foreman/` | same reason; it also encodes that roster in its dispatch table | the placement policy your launcher must implement, stated as a rule (steps 9-10) |

The published `inheritance-manifest.json` is projected to match: the publisher removes exactly the two link entries that name those two withheld sources, and nothing else. A mirror user's planner therefore closes against the sources they actually have, instead of failing on a path they can never obtain. It is not a blanket "drop what is missing" filter — any *other* dangling source is still a publication failure, which is what keeps the projection from hiding a real defect.

Substitute your own providers. Everything from step 1 to step 8 is provider-shaped, not provider-specific: swap the model ids for the accounts you actually have and the rest of the setup is unchanged.

### Pi is an opt-in harness selection, not a new default

`trellis.config.json` publishes with `"harnesses": ["claude"]`. That placeholder is unchanged and is *not* a statement that pi is unsupported — it is the same conservative default the mirror has always shipped. To get the pi surface, name it: pass `--harness pi` explicitly to `trellis attach` (alongside `--harness claude --harness codex` for all three). Changing `trellis.config.json` does not select attachment harnesses. The attachment default is Claude Code and Codex. Selecting `pi` or `codex` also pulls in the shared `.agents` surface; selecting neither leaves both untouched.

You can see exactly what a selection would install, with no writes and no attachment, by running the planner against a checkout's `core-rules` directory:

```bash
bash scripts/lib/surface-plan.sh --payload "$PWD/core-rules" --harness pi
```

### Conformance fixtures publish through the existing `scripts/` allowlist

`scripts/harness-conformance.py` is a source-only adapter fixture corpus covering the Claude, Codex and pi rows. It reaches the mirror because `scripts/` is already an allowlisted directory — no new export rule was added for it, and it is not a capability database. There is **no** `core-rules/harness-capabilities.json` in this repository; do not look for one and do not write code against it. The script requires the caller to supply OS write and network containment, and by construction it reports nothing about native host outcomes.

## Checklist

| Step | Action | Passing checkpoint |
|---:|---|---|
| 0 | Enter the Trellis checkout | Darwin host, git checkout, and required patch bundle found |
| 1 | Install pi 1.1.0 | `pi --version` prints `1.1.0` or later |
| 2 | Install active add-ons and `settings.json` | three npm packages at checked versions, local `opencode-go-2.ts` and `trellis-web-search.ts`, `omp-statusline` fork, exact `settings.json` with the built-in MCP off |
| 3 | Put API keys in macOS Keychain | all three Keychain lookups succeed without printing a key |
| 4 | Configure command-backed API-key auth | mode `0600`; four API-provider commands match |
| 5 | Perform subscription OAuth logins | Codex, xAI, `antigravity`, and GitHub Copilot credentials are ready |
| 6 | Write `subagents.json` | exact five settings print, workflows off by default and on per project |
| 7 | Write `pi-statusline.json` | exact 19-segment OMP-parity ordered list prints |
| 8 | Configure account 2 and durable pi temp root | account-2 env loads; `os.tmpdir()` resolves under `~/.trellis` |
| 9 | Author and materialize your agent roster | every agent you wrote resolves from `.agents/agents/`; boundaries pass |
| 10 | Launch agents as hc sub-agents | one `hc run --bg`, briefed at launch; no pane placement |
| 11 | Understand remote compaction | six reason codes understood; not installed by step 2 |
| 12 | Fire pi and enumerate active tools | the 9-name tool list prints, including `trellis_web_search` |

Computer use has no row: pi carries no computer-use tools in this setup.

## 0. Enter the Trellis checkout

**Command**

```bash
cd "$(git rev-parse --show-toplevel)"
export TRELLIS_REPO_ROOT="$PWD"
```

**Verify**

```bash
test "$(uname -s)" = "Darwin"
test -d "$TRELLIS_REPO_ROOT/.git"
# The patch bundle is part of the published subset, so this check is a
# corrupted-checkout guard rather than a "go find it elsewhere" gate.
if [ ! -f "$TRELLIS_REPO_ROOT/core-rules/pi/patches/apply-pi-subagents-patches.sh" ] || \
   [ ! -f "$TRELLIS_REPO_ROOT/core-rules/pi/patches/pi-subagents-0.19.0-preserve-cleanup-worktree.patch" ]; then
  printf '%s\n' 'Required pi-subagents 0.19.0 cleanup-preservation patch bundle is missing; check out the full tree before continuing.' >&2
  exit 1
fi

printf 'repo=%s\nos=%s\n' "$TRELLIS_REPO_ROOT" "$(uname -s)"
```

Expected: two lines ending in the checkout path and `os=Darwin`.

This guide is macOS-only by construction: step 3 stores keys in the macOS Keychain and step 8 pins a temp root below `~/.trellis`. On Linux, substitute your own secret store in step 3 and keep every other step.

## 1. Install pi 1.1.0

**The supported floor is pi 1.1.0; any later version is supported.** The install pins 1.1.0 exactly, the version the reference setup runs, so a fresh install is reproducible: do not use `latest` or omit `@1.1.0`. A machine that already runs a later pi keeps it; the Verify below accepts it, and step 12 is the check to re-run after any pi upgrade. `trellis doctor` warns when pi is below 1.1.0, or missing while a registered checkout selects the pi harness.

The setup relies on two pi behaviours it has verified only on 1.1.0. Pi 1.x ships a built-in MCP client, which step 2's `settings.json` switches off with `"extensions": ["-builtin:mcp"]`. And with `pi-subagents` 0.19.0, a project `<cwd>/.pi/subagents.json` merges over the global one (verified on pi 1.1.0, step 12), which is how step 6 keeps workflows off everywhere except a foreman's worktree. Instructions that existed only for pi 0.99 and 1.0 (the MCP adapter's built-in allowlist and `autoEnableCodemode` keys) are gone with the adapter. The pi launch forms Herdr uses (fullscreen TUI; one-shot reviewers as interactive `--no-tools` sessions briefed at launch) are unchanged on 1.1.0.

Where a step's evidence came from an earlier version, it says so. The compaction patch bundle in step 11 is **legacy**: it pins pi 0.85.0 / 0.85.1 bundle identities (`chunk-WZB2R5YO.js` / `chunk-JVUZSMYM.js`), refuses every other version, and does not apply to this setup.

**Command**

```bash
npm install --global @earendil-works/pi-coding-agent@1.1.0
```

**Verify**

```bash
pi --version </dev/null | awk -F. '
  /^[0-9]+\.[0-9]+\.[0-9]+$/ && ($1 > 1 || ($1 == 1 && $2 >= 1)) { print "pi=" $0 " floor=1.1.0"; ok = 1 }
  END { if (!ok) { print "pi is below the 1.1.0 floor, or its version is unreadable" > "/dev/stderr"; exit 1 } }'
npm list --global --depth=0 @earendil-works/pi-coding-agent
```

Expected: `pi=1.1.0 floor=1.1.0` (or a later version), `@earendil-works/pi-coding-agent@1.1.0` (or the same later version), and exit 0.

## 2. Install the active add-ons

There are **three npm packages and four local extensions**: `@tintinweb/pi-subagents`, `@narumitw/pi-codex-compact`, `pi-antigravity`; and the local files `opencode-go-2.ts` (account-2 provider), `trellis-web-search.ts` (the `trellis_web_search` tool), `trellis-bash-guard.ts` (a timeout and output cap for bash calls), and the `omp-statusline` fork. The step also writes the whole `settings.json`. This is the trimmed package set the reference setup runs: no MCP adapter, no computer-use server and no session-messaging package, so pi runs no MCP server, and `settings.json` switches pi 1.x's built-in MCP client off. `pi install` performs initial npm package registration. The final `npm ci --legacy-peer-deps` replays the generated lockfile and verifies its integrity without trying to lock pi's globally supplied peer packages. After this first installation, **every reinstall is `npm ci --legacy-peer-deps` in `~/.pi/agent/npm`; never run `npm install` there.**

`trellis-remote-compact` is a separate customization; it is not in the active package set and no implementation ships here. Step 11 records the contract it must satisfy.

The footer itself is the `omp-statusline` fork at `core-rules/pi/statusline/omp-statusline/` (the upstream `pi-statusline` 0.50.x footer plus OMP-parity segments `hostname`, `session`, `subagents`, `token_in/out`, `token_rate`, `cache_read/write`, `context_total`, `time_spent`). It is self-contained, so the upstream package is not installed; step 7 writes the 19-segment config the fork renders.

**Command**

Run these blocks in order. Each block tagged `<!-- pi-guide:file <path> -->` writes exactly that file; `scripts/pi-guide-parity.sh` replays only those tagged blocks, into a temporary HOME, to prove what they write. The guide has seven: `settings.json`, the two extensions and the statusline fork here, then `subagents.json`, `pi-statusline.json` and the `~/.zshenv` snippet. Step 4's `auth.json` merge is deliberately untagged (see step 4).

Register the npm add-ons.

```bash
pi install npm:@tintinweb/pi-subagents@0.19.0
pi install npm:@narumitw/pi-codex-compact@0.54.0
pi install npm:pi-antigravity@0.9.0
```

Write the whole `settings.json`, in the reference setup's key order, after the `pi install` calls above (each of them rewrites it). `lastChangelogVersion` is pi-managed; writing the installed version only skips the first-run changelog. `"extensions": ["-builtin:mcp"]` disables pi's built-in MCP client, so pi's own MCP layer loads no server and adds no MCP or codemode tool. The model ids and thinking levels are the reference roster — swap them for yours.

<!-- pi-guide:file ~/.pi/agent/settings.json -->
```bash
mkdir -p "$HOME/.pi/agent"
cat > "$HOME/.pi/agent/settings.json" <<'JSON'
{
  "lastChangelogVersion": "1.1.0",
  "theme": "dark",
  "defaultProvider": "openai-codex",
  "defaultModel": "gpt-6.1-sol",
  "packages": [
    "npm:@tintinweb/pi-subagents",
    "npm:@narumitw/pi-codex-compact@0.54.0",
    "npm:pi-antigravity@0.9.0"
  ],
  "showHardwareCursor": false,
  "outputPad": 1,
  "autocompleteMaxVisible": 20,
  "terminal": {
    "showTerminalProgress": true
  },
  "steeringMode": "all",
  "followUpMode": "all",
  "transport": "auto",
  "defaultProjectTrust": "always",
  "doubleEscapeAction": "tree",
  "shellCommandPrefix": "if [ -d \"${TRELLIS_PI_TMPDIR:-}\" ]; then export TMPDIR=\"$TRELLIS_PI_TMPDIR\"; fi",
  "modelThinkingLevels": {
    "openai-codex/gpt-6-luna": "max",
    "openai-codex/gpt-6.1-sol": "high",
    "openai-codex/gpt-6-astra": "high",
    "openai-codex/gpt-5.3-codex-spark": "xhigh",
    "openrouter/minimax/minimax-m3:free": "high",
    "opencode-go/muse-spark-1.3-contributor": "xhigh",
    "opencode-go-2/muse-spark-1.3-contributor": "xhigh",
    "antigravity/gemini-3.8-flash": "high"
  },
  "tuiMode": "fullscreen",
  "extensions": ["-builtin:mcp"]
}
JSON
```

Replay the npm lockfile, then re-apply the subagents patch: `npm ci` restores upstream files, including the 0.19.0 cleanup-on-error defect.

```bash
(
  cd "$HOME/.pi/agent/npm"
  npm ci --legacy-peer-deps
)
bash "$TRELLIS_REPO_ROOT/core-rules/pi/patches/apply-pi-subagents-patches.sh" \
  "$HOME/.pi/agent/npm/node_modules/@tintinweb/pi-subagents"
```

Install the second OpenCode Go account's provider: a single-model Muse Spark 1.3 Contributor lane on the openai-responses wire (the Go chat/completions wire 500s Muse; `/responses` answers). The file's header comment explains why it is a second provider rather than key rotation.

<!-- pi-guide:file ~/.pi/agent/extensions/opencode-go-2.ts -->
```bash
mkdir -p "$HOME/.pi/agent/extensions"
install -m 0644 "$TRELLIS_REPO_ROOT/core-rules/pi/extensions/opencode-go-2.ts" \
  "$HOME/.pi/agent/extensions/opencode-go-2.ts"
```

Install web search. The extension registers `trellis_web_search`. It asks Google Search grounding with the `antigravity` credential, which it gets from pi's model registry at call time (step 5), and has no fallback provider. It allows 20 calls per pi process by default.

<!-- pi-guide:file ~/.pi/agent/extensions/trellis-web-search.ts -->
```bash
mkdir -p "$HOME/.pi/agent/extensions"
install -m 0644 "$TRELLIS_REPO_ROOT/core-rules/pi/extensions/trellis-web-search.ts" \
  "$HOME/.pi/agent/extensions/trellis-web-search.ts"
```

Install the bash guard. pi's bash tool has no default timeout and writes any output past 50 KB to a `pi-bash-*.log` with no size limit, so one runaway command can fill the disk. The guard gives every bash tool call that has no timeout one of 1800 s, and passes at most 512 MiB of its output, then one line `[trellis-bash-guard: output truncated at 536870912 bytes]`; a producer cut off there exits 141 (SIGPIPE). `TRELLIS_PI_BASH_TIMEOUT_S` and `TRELLIS_PI_BASH_CAP_BYTES` change either, and 0 turns it off; `trellis doctor` reports both. The command runs unchanged in its own `bash -c`, so state that `shellCommandPrefix` sets reaches it only when exported, as step 2's prefix does. The cap needs `perl` on `PATH`; without it commands run uncapped, with a notice. `!` commands you type yourself do not pass through the guard.

<!-- pi-guide:file ~/.pi/agent/extensions/trellis-bash-guard.ts -->
```bash
mkdir -p "$HOME/.pi/agent/extensions"
install -m 0644 "$TRELLIS_REPO_ROOT/core-rules/pi/extensions/trellis-bash-guard.ts" \
  "$HOME/.pi/agent/extensions/trellis-bash-guard.ts"
```

Copy the `omp-statusline` fork's published source, then install its one runtime dependency.

<!-- pi-guide:file ~/.pi/agent/extensions/omp-statusline/ -->
```bash
mkdir -p "$HOME/.pi/agent/extensions"
rm -rf "$HOME/.pi/agent/extensions/omp-statusline"
cp -R "$TRELLIS_REPO_ROOT/core-rules/pi/statusline/omp-statusline" "$HOME/.pi/agent/extensions/omp-statusline"
```

```bash
(
  cd "$HOME/.pi/agent/extensions/omp-statusline"
  npm install --omit=dev --legacy-peer-deps
)
```

**Verify**

```bash
node - "$HOME/.pi/agent/npm" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const configured = JSON.parse(fs.readFileSync(path.join(root, "..", "settings.json"), "utf8")).packages;
const expectedSources = [
  "npm:@tintinweb/pi-subagents",
  "npm:@narumitw/pi-codex-compact@0.54.0",
  "npm:pi-antigravity@0.9.0",
];
if (JSON.stringify(configured) !== JSON.stringify(expectedSources)) throw new Error("settings packages differ");
console.log(`settings-packages=${configured.length}`);
const expected = new Map([
  ["@tintinweb/pi-subagents", "0.19.0"],
  ["@narumitw/pi-codex-compact", "0.54.0"],
  ["pi-antigravity", "0.9.0"],
]);
for (const [name, want] of expected) {
  const file = path.join(root, "node_modules", ...name.split("/"), "package.json");
  const got = JSON.parse(fs.readFileSync(file, "utf8")).version;
  if (got !== want) throw new Error(`${name}: expected ${want}, got ${got}`);
  console.log(`${name}@${got}`);
}
const local = fs.readFileSync(path.join(process.env.HOME, ".pi", "agent", "extensions", "opencode-go-2.ts"));
const localSource = fs.readFileSync(path.join(process.env.TRELLIS_REPO_ROOT, "core-rules", "pi", "extensions", "opencode-go-2.ts"));
if (!local.equals(localSource)) throw new Error("opencode-go-2.ts differs from core-rules/pi/extensions");
if (!local.toString("utf8").includes('registerProvider("opencode-go-2"')) throw new Error("opencode-go-2 provider registration missing");
console.log("local:opencode-go-2.ts=ready");
const search = fs.readFileSync(path.join(process.env.HOME, ".pi", "agent", "extensions", "trellis-web-search.ts"));
const searchSource = fs.readFileSync(path.join(process.env.TRELLIS_REPO_ROOT, "core-rules", "pi", "extensions", "trellis-web-search.ts"));
if (!search.equals(searchSource)) throw new Error("trellis-web-search.ts differs from core-rules/pi/extensions");
console.log("local:trellis-web-search.ts=ready");
const forkPkg = JSON.parse(fs.readFileSync(path.join(process.env.HOME, ".pi", "agent", "extensions", "omp-statusline", "package.json"), "utf8"));
if (forkPkg.name !== "omp-statusline") throw new Error("omp-statusline fork missing");
console.log(`local:omp-statusline=${forkPkg.version}`);
NODE
python3 - <<'PY'
import json
from pathlib import Path
agent = Path.home() / ".pi" / "agent"
raw = (agent / "settings.json").read_bytes()
assert raw == (json.dumps(json.loads(raw), indent=2) + "\n").encode(), "settings.json: not the step-2 rendering"
settings = json.loads((agent / "settings.json").read_text(encoding="utf-8"))
assert settings["modelThinkingLevels"]["openai-codex/gpt-6-luna"] == "max", settings
assert settings["defaultProvider"] == "openai-codex", settings
assert settings["defaultModel"] == "gpt-6.1-sol", settings
assert settings["extensions"] == ["-builtin:mcp"], settings
print(f"settings.json keys={len(settings)} thinking_levels={len(settings['modelThinkingLevels'])}")
PY
pi list
```

Expected: `settings-packages=3`, three exact npm `name@version` lines, `local:opencode-go-2.ts=ready`, `local:trellis-web-search.ts=ready`, `local:omp-statusline=0.50.0-omp.1`, `settings.json keys=17 thinking_levels=8`, and the three npm packages under `User packages`. Local `.ts` files are auto-discovered and therefore do not appear in `pi list`; the forked statusline directory is auto-discovered via its `package.json` `pi.extensions` entry. Runtime registration is verified in step 8 after its Keychain-backed environment variable exists.

`trellis-web-search.ts` is not the opt-in grounding adapter under `core-rules/pi/web-search/` ([Web search in Pi](docs/pi-web-search.md)); both register the tool name `trellis_web_search`. This one is always loaded and asks pi's model registry for the `antigravity` credential at call time, so it works after step 5. It allows 20 calls per pi process by default (`TRELLIS_WEB_SEARCH_MAX_CALLS`, 1-100), one at a time, each under a 90 s deadline. Load the opt-in adapter with `-e` only in a profile that does not carry this file.

## 3. Put API keys in macOS Keychain

This is an operator handoff. Each command ends in a bare `-w`, so `security` itself prompts for the key on the terminal without echoing it (its own help: "Specify -w as the last option to be prompted"). The key is never a shell variable and never appears in any process's argument list, where other local users and process monitors could read it.

**Command — operator-only, UNVERIFIED in this documentation pass**

Replaying credential-entry prompts during a documentation edit would be unsafe. The no-secret verification below was run successfully.

```bash
printf '%s\n' 'First OpenCode Go API key:'
/usr/bin/security add-generic-password -U -a "$USER" -s opencode-go-key -w

printf '%s\n' 'Second OpenCode Go API key:'
/usr/bin/security add-generic-password -U -a "$USER" -s opencode-go-key-2 -w

printf '%s\n' 'OpenRouter API key:'
/usr/bin/security add-generic-password -U -a "$USER" -s openrouter-api-key -w
```

**Verify**

```bash
for service in opencode-go-key opencode-go-key-2 openrouter-api-key; do
  /usr/bin/security find-generic-password -a "$USER" -s "$service" -w >/dev/null
  printf 'keychain:%s=ready\n' "$service"
done
```

Expected: three `keychain:...=ready` lines. No key value is printed.

## 4. Configure command-backed API-key entries in `auth.json`

Keep the three API-key bytes in Keychain. Merge these four objects into `~/.pi/agent/auth.json`; do not replace OAuth objects already present. The legacy `opencode` and `opencode-go` auth entries use account 1; shipped `cheap-ro` now uses `opencode-go-2`. The local `opencode-go-2` provider reads `OPENCODE_GO_2_API_KEY` at runtime, while the matching command-backed entry keeps the provider/account mapping explicit in the auth store.

```json
{
  "opencode": {
    "type": "api_key",
    "key": "!security find-generic-password -a \"$USER\" -s opencode-go-key -w"
  },
  "opencode-go": {
    "type": "api_key",
    "key": "!security find-generic-password -a \"$USER\" -s opencode-go-key -w"
  },
  "opencode-go-2": {
    "type": "api_key",
    "key": "!security find-generic-password -a \"$USER\" -s opencode-go-key-2 -w"
  },
  "openrouter": {
    "type": "api_key",
    "key": "!security find-generic-password -a \"$USER\" -s openrouter-api-key -w"
  }
}
```

Keep the file at mode `0600`.

This block is not replayed by `scripts/pi-guide-parity.sh`. It merges into an existing auth store so that OAuth objects already present survive, and that merge is Python, which the replay's file-operation allowlist refuses by design. Its own **Verify** below is the check for this step.

**Command**

```bash
python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path.home() / ".pi" / "agent" / "auth.json"
path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
data.update({
    "opencode": {
        "type": "api_key",
        "key": "!security find-generic-password -a \"$USER\" -s opencode-go-key -w",
    },
    "opencode-go": {
        "type": "api_key",
        "key": "!security find-generic-password -a \"$USER\" -s opencode-go-key -w",
    },
    "opencode-go-2": {
        "type": "api_key",
        "key": "!security find-generic-password -a \"$USER\" -s opencode-go-key-2 -w",
    },
    "openrouter": {
        "type": "api_key",
        "key": "!security find-generic-password -a \"$USER\" -s openrouter-api-key -w",
    },
})
tmp = path.parent / f".auth.json.{os.getpid()}.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
```

**Verify**

```bash
python3 - <<'PY'
import json
import stat
from pathlib import Path

path = Path.home() / ".pi" / "agent" / "auth.json"
data = json.loads(path.read_text(encoding="utf-8"))
expected = {
    "opencode": "!security find-generic-password -a \"$USER\" -s opencode-go-key -w",
    "opencode-go": "!security find-generic-password -a \"$USER\" -s opencode-go-key -w",
    "opencode-go-2": "!security find-generic-password -a \"$USER\" -s opencode-go-key-2 -w",
    "openrouter": "!security find-generic-password -a \"$USER\" -s openrouter-api-key -w",
}
for provider, command in expected.items():
    assert data.get(provider) == {"type": "api_key", "key": command}, provider
mode = stat.S_IMODE(path.stat().st_mode)
assert mode == 0o600, oct(mode)
print(f"auth.json mode={mode:04o} api_providers={','.join(expected)}")
PY
```

Expected: `auth.json mode=0600 api_providers=opencode,opencode-go,opencode-go-2,openrouter`.

## 5. Perform the four OAuth logins by hand

This is the second operator handoff. Pi's OAuth flows open a browser and require the account owner. The executing agent starts pi, then the operator performs exactly these inputs:

1. Type `/login` and select **ChatGPT Codex**; complete the browser flow.
2. Type `/login xai`, select **Use a subscription**, and complete the browser flow.
3. Type `/login antigravity` and complete Google sign-in.
4. Type `/login github-copilot` and complete the GitHub sign-in.
5. Type `/exit` and press Return.

Pi stores OAuth access/refresh state in `auth.json`; the `!security` value form applies to API-key `key` fields, not OAuth credential objects. Keep `auth.json` at `0600` and never print its OAuth objects.

**Command — operator-only, UNVERIFIED in this documentation pass**

```bash
env -u PI_CODING_AGENT_DIR -u OPENAI_API_KEY -u XAI_API_KEY pi
```

**Verify**

```bash
for provider in openai-codex xai; do
  result="$(zsh -lc "pi auth check --provider $provider --json")"
  printf '%s\n' "$result"
  printf '%s\n' "$result" | python3 -c \
    'import json, sys; data=json.load(sys.stdin); assert data["status"] == "ready", data'
done
python3 - <<'PY'
import json
from pathlib import Path
data = json.loads((Path.home() / ".pi" / "agent" / "auth.json").read_text())
for provider in ("antigravity", "github-copilot"):
    assert data.get(provider, {}).get("type") == "oauth", provider
    print(f"{provider} oauth=ready")
PY
zsh -lc 'pi --offline --no-session --list-models antigravity' | awk '$1 == "antigravity" { found=1 } END { if (!found) exit 1; print "provider:antigravity=ready" }'
```

Expected: ready markers for Codex, xAI, the `antigravity` and `github-copilot` OAuth objects, and the `antigravity` provider catalogue. `pi auth check` only knows built-in providers, so the `antigravity` check uses its OAuth object plus runtime model registration.

## 6. Write `subagents.json`

These are global defaults for the installed subagent extension. `SubagentWorkflow` is off by default and the `Agent` tool description is compact, because both tool schemas are paid by every pi session.

Workflows are turned on per project, not globally. On pi 1.1.0, pi-subagents merges a project `<cwd>/.pi/subagents.json` over this file and lets the project win, so a session that drives workflows gets `SubagentWorkflow` from `{"workflowsEnabled": true, "toolDescriptionMode": "compact"}` in its own working directory. Let the foreman launcher write it: `foreman-start.sh` rewrites the file to exactly those two keys in the foreman's worktree before pi starts, and the project check accepts that payload only for a foreman launch. Do not hand-write one for an interactive session: step 8's `pi()` refuses an untracked or branch-modified `.pi/subagents.json`, because any of its keys would override the fail-closed global settings below. A project that always wants workflows commits the file through an owner-approved PR. A pane keeps the tools it started with.

**Command**

<!-- pi-guide:file ~/.pi/agent/subagents.json -->
```bash
mkdir -p "$HOME/.pi/agent"
cat > "$HOME/.pi/agent/subagents.json" <<'JSON'
{
  "maxConcurrent": 64,
  "workflowsEnabled": false,
  "fallbackSubagent": "none",
  "strictAgentFiles": true,
  "toolDescriptionMode": "compact"
}
JSON
```

**Verify**

```bash
python3 - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".pi" / "agent" / "subagents.json"
data = json.loads(path.read_text(encoding="utf-8"))
expected = {
    "maxConcurrent": 64,
    "workflowsEnabled": False,
    "fallbackSubagent": "none",
    "strictAgentFiles": True,
    "toolDescriptionMode": "compact",
}
assert data == expected, data
print(json.dumps(data, sort_keys=True))
PY
```

Expected: one JSON line containing all five exact values.

## 7. Write `pi-statusline.json`

The forked `omp-statusline` footer renders OMP `nerd`-preset order: row 1 is the usage group, row 2 is the context group, joined by a `line_break`. Upstream-only configs (11 segments starting with `provider`) render the old footer and are the reason a fresh mirror checkout shows a different status line. Write the exact 19-segment config below.

**Command**

<!-- pi-guide:file ~/.pi/agent/pi-statusline.json -->
```bash
mkdir -p "$HOME/.pi/agent"
cat > "$HOME/.pi/agent/pi-statusline.json" <<'JSON'
{
  "separator": "dot",
  "segments": [
    "token_in", "token_out", "cache_read", "cache_write", "token_rate", "cost", "context", "context_total", "time_spent", "time",
    "line_break",
    "hostname", "model", "thinking", "cwd", "branch", "session", "subagents", "tools"
  ],
  "segmentText": {
    "model": { "prefix": " " },
    "thinking": { "prefix": "" },
    "cwd": { "prefix": " " },
    "branch": { "prefix": " " },
    "context": { "prefix": " " },
    "cost": { "prefix": "$" },
    "time": { "prefix": " " }
  }
}
JSON
```

**Verify**

```bash
python3 - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".pi" / "agent" / "pi-statusline.json"
data = json.loads(path.read_text(encoding="utf-8"))
assert data["separator"] == "dot", data
assert data["segments"] == [
    "token_in", "token_out", "cache_read", "cache_write", "token_rate",
    "cost", "context", "context_total", "time_spent", "time",
    "line_break",
    "hostname", "model", "thinking", "cwd", "branch",
    "session", "subagents", "tools",
], data
print("segments=" + ",".join(data["segments"]))
PY
```

Expected: `segments=token_in,token_out,cache_read,cache_write,token_rate,cost,context,context_total,time_spent,time,line_break,hostname,model,thinking,cwd,branch,session,subagents,tools` with `separator=dot`.

## 8. Configure account 2 and a durable pi worktree root

Add this exact configuration to `~/.zshenv`. The key stays in Keychain; command substitution places it only in the process environment. Keep `PI_CODING_AGENT_DIR` unset so pi continues to use `~/.pi/agent`.

<!-- pi-guide:file ~/.zshenv -->
```zsh
export OPENCODE_GO_2_API_KEY=$(security find-generic-password -a "$USER" -s "opencode-go-key-2" -w 2>/dev/null)

pi() {
  local sys=/usr/bin:/bin:/usr/sbin:/sbin home trellis_home top release pi_tmp pi_root
  home="$(/usr/bin/env -i PATH=$sys python3 -Ic 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')" || return 1
  trellis_home="${${TRELLIS_HOME:-$home/.trellis}:A}"
  top="$(/usr/bin/env -i PATH=$sys git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || top="$PWD"
  case "$trellis_home/" in
    "${top:A}"/*) echo "pi: refusing: TRELLIS_HOME '$trellis_home' is inside '${top:A}'" >&2; return 1 ;;
  esac
  release="$(/usr/bin/env -i PATH=$sys python3 -Ic 'import json, sys; print(json.load(open(sys.argv[1]))["active_cli_release"])' "$trellis_home/config.json")" || return 1
  /usr/bin/env -i HOME="$HOME" PATH="$PATH" TRELLIS_HOME="$trellis_home" \
    /bin/bash "$trellis_home/releases/$release/payload/core-rules/pi/lib/validate-project-pi.sh" "$PWD" || return 1
  pi_tmp="${TMPDIR:-}"
  [[ "$pi_tmp" == /* ]] && pi_tmp="${pi_tmp:A}" || pi_tmp=""
  [[ -n "$pi_tmp" && "$pi_tmp" == "${home:A}" ]] &&
    { echo "pi: refusing: TMPDIR '$TMPDIR' is the home directory, not a temp dir" >&2; return 1; }
  case "$pi_tmp/" in
    /|//|"${home:A}/projects/worktrees"/*|"${home:A}/.pi-worktrees"/*|"${home:A}/.trellis/pi-worktrees"/*|"${top:A}"/*)
      pi_tmp="$(/usr/bin/env -i PATH=$sys getconf DARWIN_USER_TEMP_DIR)" || return 1 ;;
  esac
  pi_tmp="${pi_tmp%/}/pi"
  /bin/mkdir -p -m 0700 "$pi_tmp" && [[ -d "$pi_tmp" && ! -L "$pi_tmp" && -O "$pi_tmp" ]] && /bin/chmod 0700 "$pi_tmp" ||
    { echo "pi: refusing: temp dir '$pi_tmp' is not a private directory of this account" >&2; return 1; }
  pi_root="$home/projects/worktrees/_pi"
  case "${pi_root:A}/" in
    "$trellis_home"/*|"${top:A}"/*)
      echo "pi: refusing: worktree root '$pi_root' resolves to '${pi_root:A}', inside TRELLIS_HOME or the checkout" >&2; return 1 ;;
  esac
  { [[ -d "$pi_root" ]] || /bin/mkdir -p -m 0700 "$pi_root"; } &&
    [[ ! -L "$pi_root" && -O "$pi_root" ]] && /bin/chmod 0700 "$pi_root" ||
    { echo "pi: refusing: worktree root '$pi_root' is not a private directory of this account" >&2; return 1; }
  TRELLIS_PI_TMPDIR="$pi_tmp" TMPDIR="$pi_root" /usr/bin/env -u PI_CODING_AGENT_DIR pi "$@"
}
```

The function refuses to start pi when `<cwd>/.pi` carries anything pi would load that the protected base (origin's default branch) has not already approved: an untracked or branch-modified `settings.json`, MCP configuration, `extensions/`, `skills/`, `prompts/`, `agents/` or `subagents.json`, or any symlink or hardlink there. It reads the validator from the active Trellis release, so it needs an installed release; a checkout without one can call `"$TRELLIS_REPO_ROOT/core-rules/pi/lib/validate-project-pi.sh" "$PWD"` instead. Remove what it names, or merge it through a PR with owner approval.

A direnv `.envrc` can set the variables this function reads, so it trusts none of them blindly. It takes the account home from the passwd entry rather than `$HOME`, refuses a `TRELLIS_HOME` inside the checkout before running anything from it, runs its helpers and the validator on the system `PATH` with a clean environment (no `BASH_ENV` or `SHELLOPTS`), and starts pi with `PI_CODING_AGENT_DIR` unset. The validator in turn refuses a `HOME`, `TRELLIS_HOME` or `PI_CODING_AGENT_DIR` that resolves inside the checkout.

Pi's subagent extension places worktrees under Node's `os.tmpdir()`. On macOS the default is the volatile per-boot `/var/folders/...` root; unmerged agent work there can disappear. The shell function pins interactive pi launches to `~/projects/worktrees/_pi`, pi's slot in the root that holds every harness's worktrees (1.3.12 used `~/.pi-worktrees`). A Herdr launcher must independently scope the same `TMPDIR` for the sessions it starts.

pi's own process writes its other temp files to that root too, including the bash tool's spill logs (`pi-bash-*.log`, the full output of any command too long to show). So the root lives outside `~/.trellis`: a recursive grep over `~/.trellis` once read its own growing spill log until the disk filled. The temp files of the commands pi runs go elsewhere: the function passes a private `$TMPDIR/pi` (the system per-user temp dir when the inherited one lies inside a worktree root or the checkout) as `TRELLIS_PI_TMPDIR`, and step 2's `shellCommandPrefix` points each command's `TMPDIR` at it. The function refuses a worktree root that is a symlink or not a private directory of this account, or that resolves into `TRELLIS_HOME` or the checkout through a linked parent, since a link could lead the spill logs back into `~/.trellis`, and refuses the home directory itself as `TMPDIR`. The bash guard (step 2) caps each spill log at 512 MiB. `scripts/disk-janitor.sh --report --scopes pi` lists what is stale in all three places (report-only in 1.3.12; remove what it lists by hand); worktrees under the earlier roots `~/.pi-worktrees` (1.3.12) and `~/.trellis/pi-worktrees` (before 1.3.12) stay where they are until their work is merged.

**Command**

```bash
mkdir -p -m 0700 "$HOME/projects/worktrees/_pi"
```

**Verify**

```bash
zsh -lc '
  test -z "${PI_CODING_AGENT_DIR+x}"
  test -n "$OPENCODE_GO_2_API_KEY"
  test "$(TMPDIR="$HOME/projects/worktrees/_pi" node -p '\''require("node:os").tmpdir()'\'')" = "$HOME/projects/worktrees/_pi"
  functions pi | grep -F '\''TMPDIR="$pi_root" /usr/bin/env -u PI_CODING_AGENT_DIR pi "$@"'\'' >/dev/null
  printf "OPENCODE_GO_2_API_KEY=loaded tmpdir=%s pi_function=ready\n" "$HOME/projects/worktrees/_pi"
'
zsh -lc 'pi --offline --no-session --list-models opencode-go-2' | awk '$1 == "opencode-go-2" { found=1 } END { if (!found) exit 1; print "provider:opencode-go-2=ready" }'
```

Expected: one line with `OPENCODE_GO_2_API_KEY=loaded`, the durable path, and `pi_function=ready`, followed by `provider:opencode-go-2=ready`; the key itself is never printed.

## 9. Author and materialize your agent roster

Pi discovers agent files **only** under `<cwd>/.pi/agents/`, `<cwd>/.agents/agents/`, or `$PI_CODING_AGENT_DIR/agents/`. It never reads a repository source directory directly. So the roster needs two things: a source of truth you edit, and a launcher that copies it into pi's discovery root immediately before pi starts.

Keep the source at `core-rules/pi/agents/*.md` in your Trellis checkout, and copy it to `<worktree>/.agents/agents/` at launch time, as Trellis's foreman launcher does. Launch-time materialization is the authority, not inheritance seeding: a worktree created after seeding would otherwise start with no roster, and named dispatch would silently fall back. The launcher's project check (step 8) accepts these copies only while they are byte-identical to the release roster, in `.agents/agents/` or `.pi/agents/`; an edited or extra agent file must be tracked and unchanged at the protected base.

**The roster files themselves are not shipped in this repository.** Each one pins a `model:`, so a published roster is a statement of which provider accounts its author holds. Write your own against the schema below.

### Agent file schema

One Markdown file per agent, YAML frontmatter then a plain-prose body that is the agent's standing brief.

| Key | Value | Rule |
|---|---|---|
| `name` | must equal the filename stem | this is the name you dispatch by |
| `description` | one line | what this seat is for; how a dispatcher picks it |
| `tools` | comma-separated | read-only seats: `read, grep, find, ls` — nothing else |
| `model` | `<provider>/<model-id>` | `<provider>` must match a provider id in your `auth.json` from step 4 |
| `thinking` | `max` | |
| `isolation` | `off` or omitted | read-only: `off`, stated explicitly. Mutating: omit the field so the caller decides |

Mutating seats omit the `isolation` field rather than forcing either `off` or
`worktree`. Request the appropriate isolation on each invocation; the agent-file
field takes precedence over a caller's choice when present.

Never set `isolated: true` on any agent — see the reasoning section below.

### Template

Read-only seat:

```markdown
---
name: reviewer-ro
description: Read-only reviewer on <provider>; reports findings, never edits.
tools: read, grep, find, ls
model: <provider>/<model-id>
thinking: max
isolation: off
---

Review only the assigned scope. Do not modify files or run commands.
Report findings with severity, file and line, concrete failure path, and fix direction.
Do not commit, push, or merge.
Yield: findings, evidence checked, residual uncertainty.
```

Mutating seat: same shape with `tools: read, grep, find, ls, bash, edit, write`
and no `isolation` field. The caller selects `off` or `worktree` for that unit.

A useful roster is a small matrix — one read-only and one mutating seat per provider account you hold, plus a dedicated `security-reviewer` that is always read-only. Name the read-only ones with a `-ro` suffix and the mutating ones `-rw`; the verification below checks tool capabilities as well as the read-only naming convention.

### Materialize before launch

Your launcher must do this fail-closed — if the copy fails, do not start pi.

**Command**

```bash
TRELLIS_REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE="${WORKTREE:-$TRELLIS_REPO_ROOT}"
mkdir -p "$WORKTREE/.agents/agents"
cp "$TRELLIS_REPO_ROOT"/core-rules/pi/agents/*.md "$WORKTREE/.agents/agents/"
```

**Verify**

This checks the boundaries that make the roster fail-closed, over whatever agents you wrote.

```bash
TRELLIS_REPO_ROOT="$(git rev-parse --show-toplevel)"
python3 - "$TRELLIS_REPO_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = root / "core-rules" / "pi" / "agents"
destination = root / ".agents" / "agents"
source_files = sorted(source.glob("*.md"))
assert source_files, f"no agent files under {source}"
for src in source_files:
    dst = destination / src.name
    assert dst.is_file(), f"agent not materialized into a pi discovery root: {dst}"
    assert dst.read_bytes() == src.read_bytes(), f"materialized bytes differ: {dst}"
    text = src.read_text(encoding="utf-8")
    assert f"\nname: {src.stem}\n" in text, f"name must equal the filename stem: {src.name}"
    assert "\nisolated: true\n" not in text, f"isolated:true unloads extensions: {src.name}"
    tools = next(line for line in text.splitlines() if line.startswith("tools:"))
    tools = tools.split(":", 1)[1].replace(",", " ").split()
    if (src.stem.endswith("-ro") or src.stem == "security-reviewer"
            or not ("write" in tools or "edit" in tools)):
        assert "\nisolation: off\n" in text, f"read-only isolation veto absent: {src.name}"
        for forbidden in ("bash", "write", "edit"):
            assert forbidden not in tools, f"read-only tool {forbidden} present: {src.name}"
    else:
        assert not any(line.startswith("isolation:") for line in text.splitlines()), (
            f"mutating isolation must remain caller-owned: {src.name}"
        )
print(f"discovery=.agents/agents source={len(source_files)} materialized={len(source_files)} boundaries=pass")
PY
```

Expected: equal non-zero source/materialized counts ending in `boundaries=pass`.

## 10. Launch agents as hc sub-agents

This is a rule about how a launcher starts an agent, not a pi setting. Inside the Herdr app (herdr-core `hc`, `HC_SCOPE` set), start each agent with one call and put its brief in the launch argv:

```sh
hc run --bg --name <name> --cwd <worktree> pi --model <route> @<brief.md> "Execute the brief above. Report with hc send $HC_TERMINAL_ID when done or stuck."
```

The agent is the caller's sub-agent: the app lists it under the caller with live status and ends it with the caller. No pane is placed; the operator opens one from the app when they want to watch. The caller waits with `hc wait --children`, never a sleep loop, and ends the agent with `hc kill` then `hc rm` once its work is accepted. On another machine add `--on <machine>`.

**Verify**

Against your own launcher: start five panes with the same `--tab` label and assert the first four land in one tab and the fifth opens a second tab with that label.

## 11. Understand `trellis-remote-compact`

`trellis-remote-compact` is provider-side compaction for Codex Responses sessions. Pi's built-in local compaction asks a model for a prose summary and discards the prior transcript, including encrypted GPT reasoning blocks. The remote extension captures pi's already-assembled native request and headers, posts them to OpenAI's `/responses/compact`, persists the returned opaque compaction item, and replays it with turns after the compaction boundary. GPT sessions need this to preserve reasoning state instead of paying to reconstruct it after every local summary.

**It is not installed by step 2 and no implementation ships here.** The design is settled; implementation and live runtime acceptance are pending. This section is the contract to build against, not a component you can install today.

**Do not confuse it with the native compaction patches.** `core-rules/pi/patches/COMPACTION.md` describes repairs to pi's own local compactor, and they are legacy: they apply only to a pi 0.85.x install, below this recipe's 1.1.0 floor. The installer selects exact package/bundle pairs: **0.85.0 / `chunk-WZB2R5YO.js`** or **0.85.1 / `chunk-JVUZSMYM.js`**; other identities are refused. The 0.85.1 repair passed copied-package SDK/bundle tests and subsequent installed SDK/bundle checks with synthetic responses, not a native provider call. Local application was backed up and verified; existing Pi processes retain their loaded code until restarted. The original 0.85.0 patch bytes are preserved, but its fixture was unavailable for this qualification and its tests were not rerun. Read `COMPACTION.md` before applying either patch; do not force it onto a different version.

After landing, it is working only when all three are true:

1. a Codex compaction emits the extension's distinct remote-success log rather than a skip/failure;
2. persisted `details.compactionItem.encrypted_content` is non-empty;
3. the next provider request starts with `replacementHistory` and then the turns after the boundary.

Non-Codex sessions intentionally fall back locally with `skip:not-codex`. Every compaction-time skip/failure returns control to pi's local compactor. `replay:boundary-lost` is later: it leaves the outgoing payload untouched and drops the stored replay rather than risking a corrupt splice. Every degraded path is logged. The six required reason codes are:

| Condition | Reason code |
|---|---|
| non-Codex model | `skip:not-codex` |
| no captured request input | `skip:no-capture` |
| non-2xx response | `fail:http-<status>` |
| response lacks a compaction item | `fail:no-compaction-item` |
| 180-second timeout | `fail:timeout` |
| replay boundary cannot be found | `replay:boundary-lost` |

The load-bearing property is that **every** failure mode is a named, logged degradation back to local compaction — never a silent partial splice. If you implement this, keep that property before you keep the reason-code spellings.

## 12. Fire pi and verify the tool surface registers

This probe loads the real pi profile and all installed extensions. It exits from `session_start` before a model request, so tool enumeration is runtime registration evidence rather than model prose or source inspection. The base seven tools are the four default coding tools plus the three subagent tools left when workflows are off; web search (`trellis_web_search`, `web_search`) and image generation (`generate_image`) are expected here because step 2 installs the web-search extension and `pi-antigravity`. Run the probe from a directory without a `.pi/subagents.json`, so step 6's global defaults decide.

**Command**

```bash
PROBE_PATH="$HOME/projects/worktrees/_pi/trellis-pi-tool-probe.$$.ts"
cat >"$PROBE_PATH" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const names = pi.getActiveTools().sort();
    console.log(`TRELLIS_TOOLS=${names.join(",")}`);
    process.exit(0);
  });
}
TS
```

**Verify**

```bash
actual="$(env -u PI_CODING_AGENT_DIR TMPDIR="$HOME/projects/worktrees/_pi" \
  pi --offline --no-session -e "$PROBE_PATH" -p "unused")"
expected='TRELLIS_TOOLS=Agent,bash,edit,generate_image,get_subagent_result,read,steer_subagent,trellis_web_search,write'
printf '%s\n' "$actual"
test "$actual" = "$expected"
python3 - "$PROBE_PATH" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY
```

Expected: exactly this one line and exit 0:

```text
TRELLIS_TOOLS=Agent,bash,edit,generate_image,get_subagent_result,read,steer_subagent,trellis_web_search,write
```

The four default coding tools are `read`, `bash`, `edit`, `write`; `@tintinweb/pi-subagents` adds `Agent`, `get_subagent_result`, and `steer_subagent`, plus `SubagentWorkflow` only where `workflowsEnabled` is true. The statusline, the bash guard and the local account-2 provider intentionally add no tools. `trellis-web-search.ts` adds `trellis_web_search`; `pi-antigravity` adds `generate_image`. A live 0.87.1 session of the reference setup registered these names on 2026-09-27, together with `SubagentWorkflow` (then on globally) and the computer-use and session-messaging tools this guide no longer installs; this 9-name list has not been re-measured as a whole. On 2026-10-08 a pi 1.1.0 session showed `SubagentWorkflow` absent with a project `workflowsEnabled: false` and present with `true`.

Do not start pi with `-e core-rules/pi/web-search/index.ts` while `~/.pi/agent/extensions/trellis-web-search.ts` is installed. Both register `trellis_web_search`. The installed extension registers nothing when `TRELLIS_WEB_SEARCH_CONFIG` is set to a non-blank value, which the adapter requires, but a profile that carries both leaves the owner of the tool to one environment variable. The opt-in adapter ([Web search in Pi](docs/pi-web-search.md)) belongs in a profile without this file.

**Know what web search sends and returns.** `trellis-web-search.ts` sends the model-written query with your `antigravity` credential to one Google endpoint, `daily-cloudcode-pa.googleapis.com`, and has no fallback provider. A failed call reaches the model as a fixed status and reason text, never the provider's error body. The answer and its source links are third-party content, framed as untrusted: verify the sources before acting on them.

## Trellis skills and commands in this management checkout

This section is about working *in* this source checkout, not about the portable install above. `.pi/settings.json` adds two directory pointers so native pi discovers the canonical resources it already owns:

```json
{
  "skills": ["../core-rules/skills"],
  "prompts": ["../core-rules/commands", "../core-rules/commands/*.md"]
}
```

Relative paths in `.pi/settings.json` resolve against `.pi`, not the repository root. Nothing is copied or enumerated, so a skill or command added under `core-rules/` is discovered on reload or the next launch with no second list to update.

Commands need both entries. Pi collects candidate files only from **plain** path entries; a pattern entry merely filters that set, so a glob on its own — `["../core-rules/commands/*.md"]` — discovers nothing at all. The plain directory supplies the files, and because a settings directory is scanned *recursively* (unlike the non-recursive default `prompts/`), the root-only glob is what keeps `core-rules/commands/templates/` from registering `/primer-template` and `/primer-index-template` as user commands.

**Namespaces differ by kind.** Skills register as `/skill:<name>` — `/skill:execute`, `/skill:process-gate`. Prompt templates register as `/<name>` — `/explore`, `/trellis-doctor`. There is no `/execute`, and no `/skill:explore`.

**Trust and reload.** Trust this checkout before loading its project resources. In an already-trusted session, run `/reload` to reload settings, skills, prompts and autocomplete without restarting. A changed `/trust` decision requires a restart to take effect; restarting is also an option for ordinary resource edits. A fresh-process probe does not prove that an existing pane has reloaded.

**Discovery is not enforcement.** These pointers make resources reachable from the editor. They install no hook, no rule, and no gate, and they do not attach this source checkout to a runtime: there is no `.trellis/runtime` here and this checkout is not an immutable release. Parent policy in `core-rules/CLAUDE.md` still governs, by being read, not by being wired.

**The management checkout and an attached project are two different mechanisms, and only one of them installs anything.**

| | Management checkout (`/reload`) | Attached project (immutable runtime) |
|---|---|---|
| What supplies the files | this mutable checkout, read in place | a verified immutable release payload |
| What is written | nothing | owned leaves under `.pi/`, `.agents/`, `.claude/`, `.codex/` |
| What decides the set | `.pi/settings.json` directory pointers | `core-rules/inheritance-manifest.json`, expanded by the planner |
| How you refresh it | `/reload` in an already-trusted session | detach and re-attach against the release |
| Scope of the guarantee | the editor can *see* the resources | the resources are *installed*, at known paths, with known ownership |

Use `/reload` as a **preview** of resource content while editing this checkout. It is not a rehearsal of attachment: it never renders a manifest, never resolves a HOME-scoped user leaf, and never tells you whether a manifest source actually exists. The planner command in the boundary section above is the thing that answers those, and it is still no-write.

**Verify**

The management-resources probe lives under this repository's spec tree, which is not part of the published subset. In a public mirror checkout, these commands validate planner source closure and count the canonical filesystem inventory. They do not verify native pi discovery or replace the management-resources probe:

```bash
bash scripts/lib/surface-plan.sh --payload "$PWD/core-rules" --harness pi >/dev/null && echo "plan closes"
ls core-rules/skills | wc -l
ls core-rules/commands/*.md | wc -l
```

The stricter probe drives the installed bundled CLI (`pi --mode rpc --no-session --no-tools`, `get_commands` only — no model request). Disposable regression fixtures explicitly use `--approve --no-extensions --offline`, without changing saved trust or global settings. The separate `capture` mode preserves the checkout's actual native trust and extension configuration. Its expected set is the complete canonical roster read off disk, so a canonical resource pi fails to discover, or any file below `core-rules/commands` that becomes a user command, exits non-zero with its raw cause rather than being filtered out of the expectation.

**Measured once, on pi 0.85.0, in one operator's local checkout: 17 of 17 skills and 9 of 9 commands**, each once, from its canonical realpath, with the user's own global resources untouched and no collision diagnostics — the legacy `.agents/skills` symlinks resolve to the same realpaths and are deduped silently, so they need no removal. That figure is local evidence from a version this recipe does not install, it has not been re-measured on any later pi version, including the 1.1.0 installed here, and it is not certified by any published test. Re-run the count against your own checkout rather than inheriting it.

Getting there required fixing three canonical files whose frontmatter was not valid YAML, which pi had been rejecting: `core-rules/skills/{orchestrate,security-gate}/SKILL.md` (unquoted `: ` inside `description`) and `core-rules/commands/surgical.md` (a quoted `argument-hint` followed by bare `| --emergency …`). The affected values are now single-quoted; their intended text and the file bodies are preserved. Keep new frontmatter values quoted when they contain `: `, `|`, or `"` — pi warns for a skill and drops a prompt template silently.

## Why each customization exists

Each line below names the measured failure, not a preference.

### Pi 1.1.0 is the floor

**Customization:** install pi 1.1.0 (step 1); keep any later version; never run an earlier one.

**What breaks without it:** the setup depends on two behaviours the reference setup has verified only on pi 1.1.0. Its `settings.json` switches off pi's built-in MCP client with the pi 1.x `extensions` key; an earlier pi either has no such client to switch off or (0.99, 1.0) needed a separate MCP configuration to keep codemode and a server's tools out of sessions. And workflows are scoped to a foreman's worktree by the project `.pi/subagents.json` merge; where that merge does not hold, turning workflows on for a foreman means turning them on for every pi session. The step-2 packages run on 1.1.0 in the reference setup; earlier hosts are not re-checked.

**Demonstration:** step 1's Verify refuses a version below 1.1.0; `trellis doctor` warns on one, and on a missing pi while a registered checkout selects the pi harness; step 2 checks `"extensions": ["-builtin:mcp"]`; step 12 records a 1.1.0 session with `SubagentWorkflow` absent under a project `workflowsEnabled: false` and present under `true`.

### `PI_CODING_AGENT_DIR` stays unset

**Customization:** launch pi with `PI_CODING_AGENT_DIR` absent; the launcher must explicitly unset it for pi children.

**What breaks without it:** pi stops using the canonical `~/.pi/agent` profile, so local extensions, auth, sessions, and OpenUsage accounting can resolve from different roots. The roster's global discovery fallback also moves to the wrong `$PI_CODING_AGENT_DIR/agents` directory.

**Demonstration:** step 8 requires the variable to be absent while loading the local account-2 provider; step 12 unsets it explicitly while loading the full tool surface; step 9 documents the three actual discovery roots.

### The second OpenCode Go account is a second provider

**Customization:** retrieve `opencode-go-key-2` from Keychain into `OPENCODE_GO_2_API_KEY`, then let `opencode-go-2.ts` register the independent `opencode-go-2` provider.

**What breaks without it:** key rotation is invisible to the quota resolver. It can report account A's headroom while a rotating credential command actually selects account B, so dispatch appears healthy while using the wrong quota. Without the named second provider, `cheap-2-ro` and `cheap-2-rw` cannot route on account 2's real headroom.

**Demonstration:** step 3 checks the second Keychain entry without printing it; step 8 proves both that the env value loads and that the runtime provider catalogue registers.

### Interactive pi pins a durable `TMPDIR`

**Customization:** the `pi()` function sets `TMPDIR=$HOME/projects/worktrees/_pi` and passes a private `$TMPDIR/pi` as `TRELLIS_PI_TMPDIR`, which `settings.json`'s `shellCommandPrefix` makes the `TMPDIR` of each command pi runs; foreman scopes the same values to the pi agents it starts through hc. The root was `~/.pi-worktrees` in 1.3.12 and `~/.trellis/pi-worktrees` before it.

**What breaks without it:** pi-subagents creates worktrees under `os.tmpdir()`. On macOS that is the volatile `/var/folders` root, so reboot or OS cleanup can erase a worktree containing unmerged agent changes. pi's bash spill logs share that root, so a root inside `~/.trellis` lets a recursive grep there read its own output without end; and with no split, every build cache the commands write becomes durable and unreaped.

**Demonstration:** step 8 makes Node report the durable root and verifies the exact shell function body; step 12 uses that root for its runtime probe.

### Read-only agents say `isolation: off` explicitly

**Customization:** every `*-ro` agent and `security-reviewer` carries `isolation: off`.

**What breaks without it:** an absent field does not veto the caller. `invocation-config.ts:123` resolves `agentConfig?.isolation ?? params.isolation`, so a caller request for `worktree` passes through and creates a worktree for a read-only task.

**Demonstration:** step 9 fails if any read-only file omits the explicit veto.

### Mutating agents leave isolation to the caller

**Customization:** omit `isolation` from mutating agent files; the invocation
chooses `off` or `worktree`. Keep read-only seats' explicit `off` veto.

**What breaks without it:** `agentConfig?.isolation ?? params.isolation` gives
agent metadata precedence, so a mutating file pinned to `worktree` defeats an
explicit caller request to work in the current checkout. Replacing it with
`off` would make the opposite choice equally impossible.

**Demonstration:** step 9's verification accepts verbatim copied mutating
metadata only when it leaves this field absent.

### No agent uses `isolated: true`

**Customization:** read-only seats use `isolation: off`; mutating seats omit
`isolation` and callers choose it. Never add `isolated: true`.

**What breaks without it:** `agent-runner.ts:636` forces `extensions: false`, unloading every extension for that child, including the subagent surface the harness depends on.

**Demonstration:** step 9 fails on a literal `isolated: true`; step 12 then proves the parent extension surface still loads.

### Read-only agents omit `bash`

**Customization:** read-only `tools:` lists contain only `read`, `grep`, `find`, and `ls`.

**What breaks without it:** the package computes `hasWriteTools` as `write || edit` at `agent-runner.ts:658`. `bash` is uncounted, so a nominally read-only child with `bash` can still mutate through redirects, heredocs, or commands such as `echo x > sentinel`.

**Demonstration:** step 9 rejects `bash`, `write`, or `edit` in every read-only file. The live sentinel failure was captured in an unpublished local evidence file, so reproduce it rather than cite it: give a read-only agent `bash`, ask it to `echo x > sentinel`, and observe the file appear.

### `maxConcurrent` is 64

**Customization:** set the ordinary background-agent pool to 64.

**What breaks without it:** the intended 36–63 agent fan-out queues behind the extension default instead of filling the workstation. This does not raise workflow concurrency: `SubagentWorkflow` uses a separate pool capped at `max(1, min(16, cpus-2))`, which is 12 on the measured 14-CPU host.

**Demonstration:**

```bash
node -e 'const os=require("node:os"); const n=Math.max(1,Math.min(16,os.cpus().length-2)); console.log(`cpus=${os.cpus().length} workflowConcurrency=${n}`)'
```

Expected on the measured host: `cpus=14 workflowConcurrency=12`. Step 6 separately proves `maxConcurrent=64`; the two values are intentionally independent.

### Reinstall npm extensions with `npm ci --legacy-peer-deps`, never `npm install`

**Customization:** preserve `~/.pi/agent/npm/package-lock.json` and run `npm ci --legacy-peer-deps` from that directory. The flag is required because these extensions declare pi peer packages that are supplied by the global pi installation and intentionally absent from this local lockfile. After every reinstall, run `core-rules/pi/patches/apply-pi-subagents-patches.sh` from the selected Trellis source with the installed package root as its argument, as in step 2. It accepts only the pinned version and expected source; a refusal requires investigation before mutating worker runs. Restart pi at an attended boundary to load updated extension code.

**What breaks without it:** `npm install` may float the caret-ranged declarations to newer extension versions; plain npm 12 `npm ci` instead fails by trying to add the globally supplied pi peers to the local lock. Either path prevents a reproducible reinstall.

**Demonstration:** step 2 fires the measured `npm ci --legacy-peer-deps`, which installs from the lockfile and verifies tarball integrity, then reads all three npm versions back from `node_modules`.

### The active add-ons

**Customization:** install `@tintinweb/pi-subagents@0.19.0`, `@narumitw/pi-codex-compact@0.54.0`, `pi-antigravity@0.9.0`, local `opencode-go-2.ts` (openai-responses, Muse Spark 1.3), local `trellis-web-search.ts`, and the `omp-statusline@0.50.0-omp.1` fork from `core-rules/pi/statusline/omp-statusline/`.

**What breaks without it:** omitting subagents removes three active tools and makes the roster undispatchable; omitting the forked statusline removes the provider/model/tool/context/usage footer (upstream alone renders the old 11-segment footer, which is why a mirror checkout shows a different status line); omitting `pi-codex-compact` removes Codex compaction support; omitting `pi-antigravity` makes an `antigravity/`-routed read-only agent unavailable; omitting the local provider removes the separate account-2 lanes; omitting `trellis-web-search.ts` removes `trellis_web_search`.

**Demonstration:** step 2 checks all three npm versions, the local account-2 registration source, the web-search bytes and the fork version; step 8 checks its runtime catalogue; step 5 checks the `antigravity` catalogue; step 12 proves the tool-producing registrations remain active.

### The forked statusline renders the 19-segment footer

**Customization:** copy `core-rules/pi/statusline/omp-statusline/` to `~/.pi/agent/extensions/omp-statusline/`, run `npm install --omit=dev --legacy-peer-deps` there, and write the 19-segment `pi-statusline.json` from step 7 (`separator: dot`, OMP `nerd`-preset order with `line_break`).

**What breaks without it:** upstream alone renders 11 segments (`provider,model,thinking,cwd,branch,tools,context,tokens,cache,cost,time`); the operator footer renders 19 (`token_in,token_out,cache_read,cache_write,token_rate,cost,context,context_total,time_spent,time,line_break,hostname,model,thinking,cwd,branch,session,subagents,tools`). A friend following the old step 7 sees a different footer with no usage row.

**Demonstration:** step 2 checks the fork version; step 7 asserts the exact 19-segment list and `separator`.

### Fail-closed subagent settings

**Customization:** pin `maxConcurrent:64`, `workflowsEnabled:false`, `fallbackSubagent:"none"`, `strictAgentFiles:true`, and `toolDescriptionMode:"compact"` globally; a session that drives workflows gets `workflowsEnabled:true` from the `<cwd>/.pi/subagents.json` its launcher writes (step 6).

**What breaks without it:** ordinary fan-out queues too early; every pi session pays for the `SubagentWorkflow` schema and the full `Agent` description, used or not; unknown names may silently fall back to `general-purpose`; malformed agent files may be skipped instead of refusing dispatch. A workflow-driving session without its project file has no `SubagentWorkflow` tool.

**Demonstration:** step 6 compares the complete five-field JSON object, and step 12 proves `SubagentWorkflow` is absent by default.

### The launcher materializes the agent roster

**Customization:** own definitions under `core-rules/pi/agents/`, then have the launcher copy them into each target worktree's `.agents/agents/` before pi starts.

**What breaks without it:** pi never reads `core-rules/pi/agents/`. If the launcher does not copy the files into one of pi's three discovery roots, named dispatch refuses or falls back despite the roster existing on disk.

**Demonstration:** step 9 checks the copy hook and compares every `.agents/agents` file byte-for-byte with its release source.

### Agents start as hc sub-agents

**Customization:** one `hc run --bg` per agent with the brief as pi's initial message; no pane or tab placement.

**What breaks without it:** a prompt sent after launch can be dropped while pi boots, hand-placed panes sprawl, and an agent with no hc parent is neither listed under its apex nor reported when it gets stuck.

**Demonstration:** step 10 states the launch form, the wait and the teardown.

### Codex uses remote compaction after it lands

**Customization:** add `trellis-remote-compact` once an implementation exists, preserving the remote compaction item and replay history rather than discarding reasoning state on every local summary.

**What breaks without it:** local summary compaction discards encrypted GPT reasoning blocks. Long Codex sessions lose reasoning state at each boundary and spend tokens reconstructing context; silent remote failure would make that degradation look like success.

**Demonstration:** step 11 verifies the branch design and all six observable fallback reasons. Live success remains explicitly unverified until the implementation exists; after landing, require a remote-success log, non-empty encrypted content, and replay beginning with `replacementHistory`.
