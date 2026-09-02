# Trellis pi harness setup

This guide has two reading modes:

- **Skim:** the checklist below shows the complete order and the expected checkpoint.
- **Execute:** run every numbered **Command** and **Verify** block in order in the same Bash shell. Stop on the first non-zero exit. Within a step, do not substitute versions, paths, or settings — those are pinned for a reason the reasoning section gives. Providers and models are the one thing you *are* expected to swap; see the next section. Blocks marked **UNVERIFIED** are operator actions and are the only exceptions.

The operator input is six credential actions: paste two OpenCode Go keys and one OpenRouter key into hidden terminal prompts, then complete the ChatGPT Codex, xAI, and Google Antigravity OAuth browser flows. The executing agent must hand those actions to the operator and must never ask the operator to paste a secret into chat.

## What this repository does and does not ship

Steps 0-8 and 12 are complete and reproducible as written. Steps 9-11 describe policy whose reference implementation is **not** published here, because those files state a specific operator's live provider accounts rather than any portable rule:

| Not published | Why | What this guide gives you instead |
|---|---|---|
| `core-rules/pi/agents/*.md` | one pinned `model:` per agent is a direct statement of which provider subscriptions the author holds | the agent-file schema, a template, and the fail-closed boundary rules the roster must satisfy (step 9) |
| `core-rules/skills/herdr-foreman/` | same reason; it also encodes that roster in its dispatch table | the placement policy your launcher must implement, stated as a rule (steps 9-10) |

Substitute your own providers. Everything from step 1 to step 8 is provider-shaped, not provider-specific: swap the model ids for the accounts you actually have and the rest of the setup is unchanged.

## Checklist

| Step | Action | Passing checkpoint |
|---:|---|---|
| 0 | Enter the Trellis checkout | Darwin host and a git checkout found |
| 1 | Install pi 0.84.4 | `pi --version` prints `0.84.4` |
| 2 | Install five active add-ons | four npm packages locked to checked versions plus local `opencode-go-2.ts` source |
| 3 | Put API keys in macOS Keychain | all three Keychain lookups succeed without printing a key |
| 4 | Configure command-backed API-key auth | mode `0600`; four API-provider commands match |
| 5 | Perform subscription OAuth logins | Codex, xAI, and Antigravity credentials are ready |
| 6 | Write `subagents.json` | exact four fail-closed settings print |
| 7 | Write `pi-statusline.json` | exact ordered segment list prints |
| 8 | Configure account 2 and durable pi temp root | account-2 env loads; `os.tmpdir()` resolves under `~/.trellis` |
| 9 | Author and materialize your agent roster | every agent you wrote resolves from `.pi/agents/`; boundaries pass |
| 10 | Implement the Herdr placement policy | 2x2 fill before overflow; `--tab` is preference plus overflow label |
| 11 | Understand remote compaction | six reason codes understood; not installed by step 2 |
| 12 | Fire pi and enumerate active tools | exactly nine names print |

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
printf 'repo=%s\nos=%s\n' "$TRELLIS_REPO_ROOT" "$(uname -s)"
```

Expected: two lines ending in the checkout path and `os=Darwin`.

This guide is macOS-only by construction: step 3 stores keys in the macOS Keychain and step 8 pins a temp root below `~/.trellis`. On Linux, substitute your own secret store in step 3 and keep every other step.

## 1. Install pi 0.84.4

The package version is exact. Do not use `latest` or omit `@0.84.4`.

**Command**

```bash
npm install --global @earendil-works/pi-coding-agent@0.84.4
```

**Verify**

```bash
test "$(pi --version)" = "0.84.4"
npm list --global --depth=0 @earendil-works/pi-coding-agent
```

Expected: `@earendil-works/pi-coding-agent@0.84.4` and exit 0.

## 2. Install the five active add-ons

There are **five, not three**: four npm packages and one local provider extension. `pi install` performs initial npm package registration. The final `npm ci --legacy-peer-deps` replays the generated lockfile and verifies its integrity without trying to lock pi's globally supplied peer packages. After this first installation, **every reinstall is `npm ci --legacy-peer-deps` in `~/.pi/agent/npm`; never run `npm install` there.**

`trellis-remote-compact` is a separate sixth customization; it is not in the active package set and no implementation ships here. Step 11 records the contract it must satisfy.

**Command**

```bash
pi install npm:@tintinweb/pi-subagents@0.19.0
pi install npm:pi-intercom@0.12.1
pi install npm:@narumitw/pi-statusline@0.50.0
pi install npm:pi-antigravity@0.5.2
python3 - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".pi" / "agent" / "settings.json"
data = json.loads(path.read_text(encoding="utf-8"))
data["packages"] = [
    "npm:@tintinweb/pi-subagents",
    "npm:pi-intercom",
    "npm:@narumitw/pi-statusline",
    "npm:pi-antigravity@0.5.2",
]
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY
(
  cd "$HOME/.pi/agent/npm"
  npm ci --legacy-peer-deps
)

mkdir -p "$HOME/.pi/agent/extensions"
cat > "$HOME/.pi/agent/extensions/opencode-go-2.ts" <<'TS'
/**
 * opencode-go-2 — second OpenCode Go account as an independent provider.
 *
 * Why a provider rather than key rotation: pi's auth.json is keyed by provider
 * name, one credential each, and a rotating `!command` would be invisible to
 * the quota resolver — it would report headroom for an account it is not using,
 * which is a fallback indistinguishable from success. Two providers means the
 * resolver sees two lanes with separate quotas and routes on real headroom.
 *
 * The model list is cloned from the on-disk opencode-go catalogue rather than
 * hardcoded, so it cannot drift from account 1. modelRegistry is not available
 * on ExtensionAPI at factory time — it lives on ExtensionContext — so the
 * catalogue is read from models-store.json directly.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function opencodeGoModels(): any[] {
  const store = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "models-store.json");
  const walk = (o: any): any => {
    if (o && typeof o === "object") {
      if (o["opencode-go"]?.models) return o["opencode-go"].models;
      for (const v of Object.values(o)) {
        const r = walk(v);
        if (r) return r;
      }
    }
    return null;
  };
  try {
    return walk(JSON.parse(readFileSync(store, "utf8"))) ?? [];
  } catch {
    return [];
  }
}

export default async function (pi: ExtensionAPI) {
  if (!process.env.OPENCODE_GO_2_API_KEY) return; // account 2 not configured here

  const models = opencodeGoModels();
  if (!models.length) {
    console.error("[opencode-go-2] opencode-go catalogue unreadable; not registering");
    return;
  }

  pi.registerProvider("opencode-go-2", {
    baseUrl: "https://opencode.ai/zen/go",
    apiKey: "$OPENCODE_GO_2_API_KEY",
    api: "openai-completions",
    models,
  });
}
TS
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
  "npm:pi-intercom",
  "npm:@narumitw/pi-statusline",
  "npm:pi-antigravity@0.5.2",
];
if (JSON.stringify(configured) !== JSON.stringify(expectedSources)) throw new Error("settings packages differ");
console.log(`settings-packages=${configured.length}`);
const expected = new Map([
  ["@tintinweb/pi-subagents", "0.19.0"],
  ["pi-intercom", "0.12.1"],
  ["@narumitw/pi-statusline", "0.50.0"],
  ["pi-antigravity", "0.5.2"],
]);
for (const [name, want] of expected) {
  const file = path.join(root, "node_modules", ...name.split("/"), "package.json");
  const got = JSON.parse(fs.readFileSync(file, "utf8")).version;
  if (got !== want) throw new Error(`${name}: expected ${want}, got ${got}`);
  console.log(`${name}@${got}`);
}
const local = path.join(process.env.HOME, ".pi", "agent", "extensions", "opencode-go-2.ts");
const source = fs.readFileSync(local, "utf8");
if (!source.includes('registerProvider("opencode-go-2"')) throw new Error("opencode-go-2 provider registration missing");
console.log("local:opencode-go-2.ts=ready");
NODE
pi list
```

Expected: `settings-packages=4`, four exact npm `name@version` lines, `local:opencode-go-2.ts=ready`, and the four npm packages under `User packages`. Local files are auto-discovered and therefore do not appear in `pi list`. Runtime registration is verified in step 8 after its Keychain-backed environment variable exists.

## 3. Put API keys in macOS Keychain

This is an operator handoff. The prompts do not echo input. The values exist only in shell memory until `security` moves them into the login Keychain; they are then unset.

**Command — operator-only, UNVERIFIED in this documentation pass**

Replaying credential-entry prompts during a documentation edit would be unsafe. The no-secret verification below was run successfully.

```bash
read -r -s -p "Paste the first OpenCode Go API key, then press Return: " OPENCODE_GO_KEY
printf '\n'
/usr/bin/security add-generic-password -U -a "$USER" -s opencode-go-key -w "$OPENCODE_GO_KEY" >/dev/null
unset OPENCODE_GO_KEY

read -r -s -p "Paste the second OpenCode Go API key, then press Return: " OPENCODE_GO_2_KEY
printf '\n'
/usr/bin/security add-generic-password -U -a "$USER" -s opencode-go-key-2 -w "$OPENCODE_GO_2_KEY" >/dev/null
unset OPENCODE_GO_2_KEY

read -r -s -p "Paste the OpenRouter API key, then press Return: " OPENROUTER_KEY
printf '\n'
/usr/bin/security add-generic-password -U -a "$USER" -s openrouter-api-key -w "$OPENROUTER_KEY" >/dev/null
unset OPENROUTER_KEY
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

Keep the three API-key bytes in Keychain. Merge these four objects into `~/.pi/agent/auth.json`; do not replace OAuth objects already present. Both `opencode` (used by `cheap-ro`) and `opencode-go` use account 1. The local `opencode-go-2` provider reads `OPENCODE_GO_2_API_KEY` at runtime, while the matching command-backed entry keeps the provider/account mapping explicit in the auth store.

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

## 5. Perform the three OAuth logins by hand

This is the second operator handoff. Pi's OAuth flows open a browser and require the account owner. The executing agent starts pi, then the operator performs exactly these inputs:

1. Type `/login` and select **ChatGPT Codex**; complete the browser flow.
2. Type `/login xai`, select **Use a subscription**, and complete the browser flow.
3. Type `/login antigravity` and complete Google sign-in.
4. Type `/exit` and press Return.

Pi 0.84.4 stores OAuth access/refresh state in `auth.json`; the `!security` value form applies to API-key `key` fields, not OAuth credential objects. Keep `auth.json` at `0600` and never print its OAuth objects.

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
assert data.get("antigravity", {}).get("type") == "oauth"
print("antigravity oauth=ready")
PY
zsh -lc 'pi --offline --no-session --list-models antigravity' | awk '$1 == "antigravity" { found=1 } END { if (!found) exit 1; print "provider:antigravity=ready" }'
```

Expected: ready markers for Codex, xAI, the Antigravity OAuth object, and the Antigravity provider catalogue. `pi auth check` only knows built-in providers, so the local Antigravity check uses its OAuth object plus runtime model registration.

## 6. Write `subagents.json`

These are global defaults for the installed subagent extension.

**Command**

```bash
python3 - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".pi" / "agent" / "subagents.json"
data = {
    "maxConcurrent": 64,
    "workflowsEnabled": True,
    "fallbackSubagent": "none",
    "strictAgentFiles": True,
}
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
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
    "workflowsEnabled": True,
    "fallbackSubagent": "none",
    "strictAgentFiles": True,
}
assert data == expected, data
print(json.dumps(data, sort_keys=True))
PY
```

Expected: one JSON line containing all four exact values.

## 7. Write `pi-statusline.json`

The ordered segments expose provider/model selection, reasoning level, checkout, active tools, context pressure, token/cache/cost use, and elapsed time without opening another view.

**Command**

```bash
python3 - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".pi" / "agent" / "pi-statusline.json"
data = {
    "segments": [
        "provider", "model", "thinking", "cwd", "branch", "tools",
        "context", "tokens", "cache", "cost", "time",
    ]
}
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
```

**Verify**

```bash
python3 - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".pi" / "agent" / "pi-statusline.json"
data = json.loads(path.read_text(encoding="utf-8"))
expected = [
    "provider", "model", "thinking", "cwd", "branch", "tools",
    "context", "tokens", "cache", "cost", "time",
]
assert data == {"segments": expected}, data
print("segments=" + ",".join(data["segments"]))
PY
```

Expected: `segments=provider,model,thinking,cwd,branch,tools,context,tokens,cache,cost,time`.

## 8. Configure account 2 and a durable pi worktree root

Add this exact configuration to `~/.zshenv`. The key stays in Keychain; command substitution places it only in the process environment. Keep `PI_CODING_AGENT_DIR` unset so pi continues to use `~/.pi/agent`.

```zsh
export OPENCODE_GO_2_API_KEY=$(security find-generic-password -a "$USER" -s "opencode-go-key-2" -w 2>/dev/null)

pi() {
  TMPDIR="$HOME/.trellis/pi-worktrees" command pi "$@"
}
```

Pi's subagent extension places worktrees under Node's `os.tmpdir()`. On macOS the default is the volatile per-boot `/var/folders/...` root; unmerged agent work there can disappear. The shell function pins interactive pi launches to `~/.trellis/pi-worktrees`. A Herdr launcher must independently scope the same `TMPDIR` for the sessions it starts.

**Command**

```bash
mkdir -p "$HOME/.trellis/pi-worktrees"
```

**Verify**

```bash
zsh -lc '
  test -z "${PI_CODING_AGENT_DIR+x}"
  test -n "$OPENCODE_GO_2_API_KEY"
  test "$(TMPDIR="$HOME/.trellis/pi-worktrees" node -p '\''require("node:os").tmpdir()'\'')" = "$HOME/.trellis/pi-worktrees"
  functions pi | grep -F '\''TMPDIR="$HOME/.trellis/pi-worktrees" command pi "$@"'\'' >/dev/null
  printf "OPENCODE_GO_2_API_KEY=loaded tmpdir=%s pi_function=ready\n" "$HOME/.trellis/pi-worktrees"
'
zsh -lc 'pi --offline --no-session --list-models opencode-go-2' | awk '$1 == "opencode-go-2" { found=1 } END { if (!found) exit 1; print "provider:opencode-go-2=ready" }'
```

Expected: one line with `OPENCODE_GO_2_API_KEY=loaded`, the durable path, and `pi_function=ready`, followed by `provider:opencode-go-2=ready`; the key itself is never printed.

## 9. Author and materialize your agent roster

Pi discovers agent files **only** under `<cwd>/.pi/agents/`, `<cwd>/.agents/agents/`, or `$PI_CODING_AGENT_DIR/agents/`. It never reads a repository source directory directly. So the roster needs two things: a source of truth you edit, and a launcher that copies it into pi's discovery root immediately before pi starts.

Keep the source at `core-rules/pi/agents/*.md` in your Trellis checkout, and copy it to `<worktree>/.pi/agents/` at launch time. Do **not** substitute inheritance seeding into `.agents/agents`: launch-time materialization is the authority, because a worktree created after seeding would otherwise start with no roster and named dispatch would silently fall back.

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
| `isolation` | `off` or `worktree` | read-only: `off`, stated explicitly. Mutating: `worktree` |

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

Mutating seat: same shape with `tools: read, grep, find, ls, bash, edit, write` and `isolation: worktree`.

A useful roster is a small matrix — one read-only and one mutating seat per provider account you hold, plus a dedicated `security-reviewer` that is always read-only. Name the read-only ones with a `-ro` suffix and the mutating ones `-rw`; the verify below keys off that convention.

### Materialize before launch

Your launcher must do this fail-closed — if the copy fails, do not start pi.

**Command**

```bash
TRELLIS_REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE="${WORKTREE:-$TRELLIS_REPO_ROOT}"
mkdir -p "$WORKTREE/.pi/agents"
cp "$TRELLIS_REPO_ROOT"/core-rules/pi/agents/*.md "$WORKTREE/.pi/agents/"
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
destination = root / ".pi" / "agents"
source_files = sorted(source.glob("*.md"))
assert source_files, f"no agent files under {source}"
for src in source_files:
    dst = destination / src.name
    assert dst.is_file(), f"agent not materialized into a pi discovery root: {dst}"
    assert dst.read_bytes() == src.read_bytes(), f"materialized bytes differ: {dst}"
    text = src.read_text(encoding="utf-8")
    assert f"\nname: {src.stem}\n" in text, f"name must equal the filename stem: {src.name}"
    assert "\nisolated: true\n" not in text, f"isolated:true unloads extensions: {src.name}"
    if src.stem.endswith("-ro") or src.stem == "security-reviewer":
        assert "\nisolation: off\n" in text, f"read-only isolation veto absent: {src.name}"
        tools = next(line for line in text.splitlines() if line.startswith("tools:"))
        for forbidden in ("bash", "write", "edit"):
            assert forbidden not in tools.split(":", 1)[1].replace(",", " ").split(), (
                f"read-only tool {forbidden} present: {src.name}"
            )
    else:
        assert "\nisolation: worktree\n" in text, f"mutating worktree policy absent: {src.name}"
print(f"discovery=.pi/agents source={len(source_files)} materialized={len(source_files)} boundaries=pass")
PY
```

Expected: equal non-zero source/materialized counts ending in `boundaries=pass`.

## 10. Implement the Herdr placement policy

This is a rule about where a launcher puts a new pane, not a pi setting. Trellis's own launcher is not published here; implement the policy in yours.

A tab fills as a 2x2 grid before overflowing into a new tab: pane 1 splits right, pane 2 splits down from the left pane, and pane 3 splits down from the right pane. A fourth pane completes the grid; only the fifth needs another tab.

| New pane | Split target | Direction |
|---:|---|---|
| 2 | pane 1 | right |
| 3 | pane 1 | down |
| 4 | pane 2 | down |
| 5 | — | new tab, carrying the requested label |

`--tab <label>` means **preference plus overflow label**, not "always create a tab." Placement order is:

1. an existing tab with that label in the same workspace, if it has fewer than four panes;
2. otherwise the caller's tab, if it has fewer than four panes;
3. otherwise a new overflow tab, carrying the requested label.

**Verify**

Against your own launcher: start five panes with the same `--tab` label and assert the first four land in one tab and the fifth opens a second tab with that label.

## 11. Understand `trellis-remote-compact`

`trellis-remote-compact` is provider-side compaction for Codex Responses sessions. Pi's built-in local compaction asks a model for a prose summary and discards the prior transcript, including encrypted GPT reasoning blocks. The remote extension captures pi's already-assembled native request and headers, posts them to OpenAI's `/responses/compact`, persists the returned opaque compaction item, and replays it with turns after the compaction boundary. GPT sessions need this to preserve reasoning state instead of paying to reconstruct it after every local summary.

**It is not installed by step 2 and no implementation ships here.** The design is settled; implementation and live runtime acceptance are pending. This section is the contract to build against, not a component you can install today.

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

## 12. Fire pi and verify all nine active tools register

This probe loads the real pi profile and all installed extensions. It exits from `session_start` before a model request, so tool enumeration is runtime registration evidence rather than model prose or source inspection.

**Command**

```bash
PROBE_PATH="$HOME/.trellis/pi-worktrees/trellis-pi-tool-probe.$$.ts"
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
actual="$(env -u PI_CODING_AGENT_DIR TMPDIR="$HOME/.trellis/pi-worktrees" \
  pi --offline --no-session -e "$PROBE_PATH" -p "unused")"
expected='TRELLIS_TOOLS=Agent,SubagentWorkflow,bash,edit,get_subagent_result,intercom,read,steer_subagent,write'
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
TRELLIS_TOOLS=Agent,SubagentWorkflow,bash,edit,get_subagent_result,intercom,read,steer_subagent,write
```

The four default coding tools are `read`, `bash`, `edit`, `write`; `@tintinweb/pi-subagents` adds `Agent`, `SubagentWorkflow`, `get_subagent_result`, and `steer_subagent`; `pi-intercom` adds `intercom`. The statusline, Antigravity provider, and local account-2 provider intentionally add no tools.

## Why each customization exists

Each line below names the measured failure, not a preference.

### `PI_CODING_AGENT_DIR` stays unset

**Customization:** launch pi with `PI_CODING_AGENT_DIR` absent; the launcher must explicitly unset it for pi children.

**What breaks without it:** pi stops using the canonical `~/.pi/agent` profile, so local extensions, auth, sessions, and OpenUsage accounting can resolve from different roots. The roster's global discovery fallback also moves to the wrong `$PI_CODING_AGENT_DIR/agents` directory.

**Demonstration:** step 8 requires the variable to be absent while loading the local account-2 provider; step 12 unsets it explicitly while loading the full tool surface; step 9 documents the three actual discovery roots.

### The second OpenCode Go account is a second provider

**Customization:** retrieve `opencode-go-key-2` from Keychain into `OPENCODE_GO_2_API_KEY`, then let `opencode-go-2.ts` register the independent `opencode-go-2` provider.

**What breaks without it:** key rotation is invisible to the quota resolver. It can report account A's headroom while a rotating credential command actually selects account B, so dispatch appears healthy while using the wrong quota. Without the named second provider, `cheap-2-ro`, `glm-flash-go-ro`, and `glm-flash-go-rw` cannot route on account 2's real headroom.

**Demonstration:** step 3 checks the second Keychain entry without printing it; step 8 proves both that the env value loads and that the runtime provider catalogue registers.

### Interactive pi pins a durable `TMPDIR`

**Customization:** the `pi()` function sets `TMPDIR=$HOME/.trellis/pi-worktrees`; foreman scopes the same value to Herdr pi launches.

**What breaks without it:** pi-subagents creates worktrees under `os.tmpdir()`. On macOS that is the volatile `/var/folders` root, so reboot or OS cleanup can erase a worktree containing unmerged agent changes.

**Demonstration:** step 8 makes Node report the durable root and verifies the exact shell function body; step 12 uses that root for its runtime probe.

### Read-only agents say `isolation: off` explicitly

**Customization:** every `*-ro` agent and `security-reviewer` carries `isolation: off`.

**What breaks without it:** an absent field does not veto the caller. `invocation-config.ts:123` resolves `agentConfig?.isolation ?? params.isolation`, so a caller request for `worktree` passes through and creates a worktree for a read-only task.

**Demonstration:** step 9 fails if any read-only file omits the explicit veto.

### No agent uses `isolated: true`

**Customization:** use `isolation: off` or `isolation: worktree`; never add `isolated: true`.

**What breaks without it:** `agent-runner.ts:636` forces `extensions: false`, unloading every extension for that child, including the subagent and intercom surfaces the harness depends on.

**Demonstration:** step 9 fails on a literal `isolated: true`; step 12 then proves the parent extension surface still loads.

### Read-only agents omit `bash`

**Customization:** read-only `tools:` lists contain only `read`, `grep`, `find`, and `ls`.

**What breaks without it:** the package computes `hasWriteTools` as `write || edit` at `agent-runner.ts:658`. `bash` is uncounted, so a nominally read-only child with `bash` can still mutate through redirects, heredocs, or commands such as `echo x > sentinel`.

**Demonstration:** step 9 rejects `bash`, `write`, or `edit` in every read-only file. The live sentinel failure is recorded in [`../evidence/t8-sentinel-fence.txt`](../evidence/t8-sentinel-fence.txt).

### `maxConcurrent` is 64

**Customization:** set the ordinary background-agent pool to 64.

**What breaks without it:** the intended 36–63 agent fan-out queues behind the extension default instead of filling the workstation. This does not raise workflow concurrency: `SubagentWorkflow` uses a separate pool capped at `max(1, min(16, cpus-2))`, which is 12 on the measured 14-CPU host.

**Demonstration:**

```bash
node -e 'const os=require("node:os"); const n=Math.max(1,Math.min(16,os.cpus().length-2)); console.log(`cpus=${os.cpus().length} workflowConcurrency=${n}`)'
```

Expected on the measured host: `cpus=14 workflowConcurrency=12`. Step 6 separately proves `maxConcurrent=64`; the two values are intentionally independent.

### Reinstall npm extensions with `npm ci --legacy-peer-deps`, never `npm install`

**Customization:** preserve `~/.pi/agent/npm/package-lock.json` and run `npm ci --legacy-peer-deps` from that directory. The flag is required because these extensions declare pi peer packages that are supplied by the global pi installation and intentionally absent from this local lockfile.

**What breaks without it:** `npm install` may float the caret-ranged declarations to newer extension versions; plain npm 12 `npm ci` instead fails by trying to add the globally supplied pi peers to the local lock. Either path prevents a reproducible reinstall.

**Demonstration:** step 2 fires the measured `npm ci --legacy-peer-deps`, which installs from the lockfile and verifies tarball integrity, then reads all four npm versions back from `node_modules`.

### The five active add-ons

**Customization:** install `@tintinweb/pi-subagents@0.19.0`, `pi-intercom@0.12.1`, `@narumitw/pi-statusline@0.50.0`, `pi-antigravity@0.5.2`, and local `opencode-go-2.ts`.

**What breaks without it:** omitting subagents removes four active tools and makes the roster undispatchable; omitting intercom removes session-to-session messaging; omitting statusline removes the provider/model/tool/context/usage footer; omitting Antigravity makes `flash-ro`'s `antigravity/gemini-3.7-flash` unavailable; omitting the local provider removes the separate account-2 lanes used by three roster files.

**Demonstration:** step 2 checks all four npm versions and the local account-2 registration source; step 8 checks its runtime catalogue; step 5 checks the Antigravity catalogue; step 12 proves the tool-producing registrations remain active.

### Fail-closed subagent settings

**Customization:** pin `maxConcurrent:64`, `workflowsEnabled:true`, `fallbackSubagent:"none"`, and `strictAgentFiles:true`.

**What breaks without it:** ordinary fan-out queues too early; workflow collision auto-detection may withdraw `SubagentWorkflow`; unknown names may silently fall back to `general-purpose`; malformed agent files may be skipped instead of refusing dispatch.

**Demonstration:** step 6 compares the complete four-field JSON object, and step 12 proves `SubagentWorkflow` remains active.

### The launcher materializes the agent roster

**Customization:** own definitions under `core-rules/pi/agents/`, then have the launcher copy them into each target worktree's `.pi/agents/` before pi starts.

**What breaks without it:** pi never reads `core-rules/pi/agents/`. If the launcher does not copy the files into one of pi's three discovery roots, named dispatch refuses or falls back despite the roster existing on disk.

**Demonstration:** step 9 checks the copy hook and compares every `.pi/agents` file byte-for-byte with its release source.

### Herdr fills a 2x2 grid before overflow

**Customization:** reuse a labelled tab with room, otherwise fill the caller's tab to four panes, and only then create an overflow tab; `--tab <label>` is a preference and overflow label.

**What breaks without it:** every dispatch can force tab sprawl, split geometry stops being deterministic, and callers using `--tab` can mistake a label request for guaranteed new-tab isolation.

**Demonstration:** step 10 states all three split transitions, labelled-tab preference, and labelled overflow movement as the rule your launcher must satisfy.

### Codex uses remote compaction after it lands

**Customization:** add `trellis-remote-compact` once an implementation exists, preserving the remote compaction item and replay history rather than discarding reasoning state on every local summary.

**What breaks without it:** local summary compaction discards encrypted GPT reasoning blocks. Long Codex sessions lose reasoning state at each boundary and spend tokens reconstructing context; silent remote failure would make that degradation look like success.

**Demonstration:** step 11 verifies the branch design and all six observable fallback reasons. Live success remains explicitly unverified until the implementation exists; after landing, require a remote-success log, non-empty encrypted content, and replay beginning with `replacementHistory`.
