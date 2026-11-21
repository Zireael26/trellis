#!/usr/bin/env bash
# Gate 3: Bypass markers — override env vars, hook tampering, persistent config drift.
# Usage: check-bypass.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

# Git's exported identity knobs must not redirect project/config discovery or
# owner lookup to another checkout. Local config is data and cannot set them;
# the inherited environment can.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
pg_load_config "$@" || exit 1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"

worst="pass"
findings=()

# A harness/config-supplied plain subdirectory is not a worktree identity.
# Nested Git toplevels must also match any ancestor owner found below.
project_root="$(CDPATH='' cd "$PROJECT_DIR" && pwd -P)" || project_root=""
git_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
if [ -n "$git_root" ]; then
  git_root="$(CDPATH='' cd "$git_root" && pwd -P)" || git_root=""
fi
if [ -z "$project_root" ] || [ "$project_root" != "$git_root" ]; then
  pg_log fail "Bypass markers (range=$RANGE)"
  pg_finding "PROJECT_DIR: project root must equal the Git worktree top level — attachment identity cannot be verified"
  pg_exit_code fail
fi
PROJECT_DIR="$git_root"

# 1. TRELLIS_ALLOW_MAIN_PUSH=1 in commit trailers within range -> warn (must be justified)
if git log --format='%B' "$RANGE" 2>/dev/null | grep -E 'TRELLIS_ALLOW_MAIN_PUSH=1' >/dev/null; then
  findings+=("commit-trailer: TRELLIS_ALLOW_MAIN_PUSH=1 found — must be justified in gotchas.md")
  [ "$worst" = "pass" ] && worst="warn"
fi

# 1a. PROCESS_GATE_SKIP=1 in commit trailers within range -> warn (must be justified)
if git log --format='%B' "$RANGE" 2>/dev/null | grep -E 'PROCESS_GATE_SKIP=1' >/dev/null; then
  findings+=("commit-trailer: PROCESS_GATE_SKIP=1 found — must be justified in gotchas.md")
  [ "$worst" = "pass" ] && worst="warn"
fi

# 2. .husky/* tampering: short-circuit at top
if [ -d "$PROJECT_DIR/.husky" ]; then
  while IFS= read -r -d '' hook; do
    [ -f "$hook" ] || continue
    # Skip comments and bare no-ops; a shebang-less first command still counts.
    hook_head="$(awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
      /^[[:space:]]*(true|:)[[:space:]]*(;[[:space:]]*)?(#.*)?$/ {noop=1; next}
      {printf "cmd:%s\n", $0; found=1; exit}
      END {if (!found && noop) print "noop:"}
    ' "$hook" 2>/dev/null || true)"
    first=""
    short_circuit=false
    case "$hook_head" in
      noop:) first="only no-op commands"; short_circuit=true ;;
      cmd:*)
        first="${hook_head#cmd:}"
        if [[ "$first" =~ ^[[:space:]]*exit[[:space:]]+0([[:space:]]*($|\;|\#)) ]]; then
          short_circuit=true
        fi
        ;;
    esac
    if $short_circuit; then
      findings+=("${hook#"$PROJECT_DIR"/}: short-circuit (first effective line: $first)")
      worst="fail"
    fi
  done < <(find -L "$PROJECT_DIR/.husky" -maxdepth 1 -type f \( -name 'pre-*' -o -name 'commit-msg' -o -name 'post-*' \) -print0 2>/dev/null)
fi

# 3. Native-githooks projects: core.hooksPath set?
if [ ! -f "$PROJECT_DIR/package.json" ]; then
  hp="$(git -C "$PROJECT_DIR" config --get core.hooksPath 2>/dev/null || true)"
  if [ -z "$hp" ]; then
    # Only flag if .githooks/ exists in the tree (project intends to use it)
    if [ -d "$PROJECT_DIR/.githooks" ]; then
      findings+=("git-config: core.hooksPath unset but .githooks/ present — hooks will not run")
      worst="fail"
    fi
  fi
fi

# 3a. core.hooksPath actively disabled: persistent config pointing hooks to /dev/null.
# Distinguish "key set" from "key unset" via exit code — `git config --get` returns 1 when unset.
if git -C "$PROJECT_DIR" config --get core.hooksPath >/dev/null 2>&1; then
  hp_active="$(git -C "$PROJECT_DIR" config --get core.hooksPath 2>/dev/null || true)"
  case "$hp_active" in
    /dev/null|/dev/zero|"")
      display="$hp_active"
      [ -z "$display" ] && display="<empty>"
      findings+=("core.hooksPath: actively set to disable hooks (value: $display)")
      worst="fail"
      ;;
  esac
fi

# 3b. commit.gpgsign actively disabled via persistent config.
# Policy-level — many projects legitimately disable signing; warn rather than fail.
if git -C "$PROJECT_DIR" config --get commit.gpgsign >/dev/null 2>&1; then
  gp="$(git -C "$PROJECT_DIR" config --get commit.gpgsign 2>/dev/null || true)"
  if [ "$gp" = "false" ]; then
    findings+=("commit.gpgsign: actively disabled via persistent config")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

# Undetectable bypasses (no trace post-hoc):
#   - `git -c commit.gpgsign=false commit ...` (one-shot config override)
#   - `git commit --no-gpg-sign ...` (flag does not appear in reflog)
# These can only be caught by either pre-commit-hook trapping or by
# tracking expected-signed-commit policy via branch protection. Out of
# scope for this gate — flagging here so future readers don't reinvent
# an undetectable check.

# 4. Local attachment state, not .trellis.json, determines required harnesses.
# Mirror the read-only identity and owner-harness rules in local-registry.sh
# and attach-project.sh: checkout ID hashes the canonical Git common directory;
# worktree ID hashes the canonical worktree root. Never create local state.
bypass_hash() {
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 | awk '{print $1}')" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum | awk '{print $1}')" || return 1
  else
    return 1
  fi
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

# Open once without following the leaf, then validate/read that descriptor.
# This avoids check-then-open symlink substitution of a private owner.
bypass_read_owner() {
  python3 -I -c '
import os, stat, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
with os.fdopen(fd) as owner:
    mode = os.fstat(owner.fileno()).st_mode
    if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o600:
        sys.exit(1)
    sys.stdout.write(owner.read())
' "$1" 2>/dev/null
}

# 0 = attached (emit harnesses/artifacts); 2 = not attached; 1 = invalid state.
bypass_attachment_state() {
  local home root common checkout_id worktree_id owner record
  [ -n "${TRELLIS_HOME:-}" ] || [ -n "${HOME:-}" ] || return 1
  home="${TRELLIS_HOME:-${HOME}/.trellis}"
  case "$home" in /*) ;; *) return 1 ;; esac
  root="$(CDPATH='' cd "$PROJECT_DIR" && pwd -P)" || return 1
  # An unattached nested Git repo must not hide its attached ancestor. Walk
  # physical ancestors until an owner/anchor is found, then bind to that owner.
  while :; do
    common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || common=""
    if [ -n "$common" ]; then
      case "$common" in /*) ;; *) common="$root/$common" ;; esac
      common="$(CDPATH='' cd "$common" && pwd -P)" || return 1
      checkout_id="$(printf '%s' "$common" | bypass_hash)" || return 1
      worktree_id="$(printf '%s' "$root" | bypass_hash)" || return 1
      owner="$home/state/attachments/$checkout_id/$worktree_id.json"
      if [ -e "$owner" ] || [ -L "$owner" ]; then
        break
      fi
    fi
    if [ -e "$root/.trellis/runtime" ] || [ -L "$root/.trellis/runtime" ]; then
      # Without its owner the expected harness set is unknown. Fail closed.
      return 1
    fi
    [ "$root" != / ] || return 2
    root="$(dirname "$root")"
  done
  record="$(bypass_read_owner "$owner")" || return 1
  jq -ec --arg root "$root" --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
    def valid_harness: . == "antigravity" or . == "claude" or . == "codex" or . == "opencode" or . == "pi";
    if type != "object"
      or ((.schema_version == 1 and (has("harnesses") | not))
          or (.schema_version == 2 and (.harnesses | type == "array" and length > 0 and all(.[]; valid_harness) and (unique | length) == length)) | not)
      or .status != "committed"
      or .worktree_root != $root or .checkout_id != $checkout or .worktree_id != $worktree
      or (.artifacts | type) != "array" or (has("pre_existing") and (.pre_existing | type) != "array")
      or (has("renders") and (.renders | type) != "array")
    then error("invalid attachment owner") else . end
    | . as $owner
    | (if .schema_version == 2 then
         (.harnesses | unique | sort)
       else
         (.artifacts + (.pre_existing // [])) as $owned
         | (any($owned[]; .path | startswith(".pi/"))) as $has_pi
         | [$owned[]
           | if (.path | startswith(".codex/")) then "codex"
             elif (.path | startswith(".pi/")) then "pi"
             elif (.path | startswith(".claude/")) then "claude"
             elif (($has_pi | not) and (.path == "AGENTS.md" or (.path | startswith(".agents/")))) then "codex"
             else empty end] | unique
       end) as $harnesses
    | if ($harnesses | length) == 0 then error("attachment has no harnesses")
      else {worktree_root:$owner.worktree_root,checkout_id:$owner.checkout_id,harnesses:$harnesses,
        artifacts:$owner.artifacts,pre_existing:($owner.pre_existing // []),
        renders:($owner.renders // []),git_hooks:($owner.git_hooks // {})} end
  ' <<< "$record" 2>/dev/null || return 1
}

attached_harnesses=""
attachment_state=""
if attachment_state="$(bypass_attachment_state)"; then
  if [ "$PROJECT_DIR" != "$(jq -r '.worktree_root' <<< "$attachment_state")" ]; then
    pg_log fail "Bypass markers (range=$RANGE)"
    pg_finding "PROJECT_DIR: project root must equal the owner-recorded worktree path — attachment identity cannot be verified"
    pg_exit_code fail
  fi
  attached_harnesses="$(jq -r '.harnesses[]' <<< "$attachment_state")"
else
  attachment_status="$?"
  attachment_state=""
  if [ "$attachment_status" -eq 2 ]; then
    if [ -f "$PROJECT_DIR/.trellis.json" ]; then
      findings+=(".trellis.json: not attached in this checkout — native hook registration not required before attachment")
      [ "$worst" = "pass" ] && worst="warn"
    fi
  else
    findings+=("local attachment state: owner record unavailable or invalid — attached harnesses cannot be verified")
    worst="fail"
  fi
fi

# core.hooksPath is shared by linked worktrees. A disabled worktree record
# does not make the checkout unmanaged: its sibling may own the dispatcher.
# 0 = managed (emit path); 2 = truly unmanaged; 1 = invalid sibling state.
bypass_managed_hooks_path() {
  local home checkout owner owner_id record sibling_root managed="" candidate
  if [ "$(jq -r '.git_hooks.enabled // false' <<< "$attachment_state")" = true ]; then
    jq -r '.git_hooks.managed_hooks_path // empty' <<< "$attachment_state"
    return 0
  fi
  home="${TRELLIS_HOME:-${HOME}/.trellis}"
  checkout="$(jq -r '.checkout_id' <<< "$attachment_state")"
  for owner in "$home/state/attachments/$checkout/"*.json; do
    [ -e "$owner" ] || [ -L "$owner" ] || continue
    record="$(bypass_read_owner "$owner")" || return 1
    owner_id="${owner##*/}"; owner_id="${owner_id%.json}"
    [[ "$owner_id" =~ ^[a-f0-9]{64}$ ]] || return 1
    jq -e --arg checkout "$checkout" --arg worktree "$owner_id" '
      (if has("git_hooks") then .git_hooks else {} end) as $hooks
      | (.schema_version == 1 or .schema_version == 2) and .status == "committed" and .checkout_id == $checkout
        and .worktree_id == $worktree and (.worktree_root | type == "string" and startswith("/"))
        and (.artifacts | type == "array")
        and ((has("pre_existing") | not) or (.pre_existing | type == "array"))
        and ((has("renders") | not) or (.renders | type == "array"))
        and ($hooks | type == "object")
        and ((has("git_hooks") | not) or (($hooks | has("enabled")) and ($hooks.enabled | type == "boolean")))
    ' <<< "$record" >/dev/null 2>&1 || return 1
    sibling_root="$(jq -r '.worktree_root' <<< "$record")" || return 1
    [ "$(printf '%s' "$sibling_root" | bypass_hash)" = "$owner_id" ] || return 1
    if [ "$(jq -r '.git_hooks.enabled // false' <<< "$record")" = true ]; then
      candidate="$(jq -r '.git_hooks.managed_hooks_path // empty' <<< "$record")"
      [ -n "$candidate" ] && { [ -z "$managed" ] || [ "$managed" = "$candidate" ]; } || return 1
      managed="$candidate"
    fi
  done
  if [ -n "$managed" ]; then
    printf '%s\n' "$managed"
  elif [ -d "$home/state/git-hooks/$checkout" ]; then
    printf '%s\n' "$home/state/git-hooks/$checkout"
  else
    return 2
  fi
}

# Package installs can reset Git hook authority without changing any native
# harness registration. Read local config (not one-shot harness -c overrides),
# resolve relative paths from the worktree, and require the checkout's managed
# dispatcher, including projects with package.json and non-manager worktrees.
if [ -n "$attachment_state" ]; then
  managed_status=0
  managed_hooks_path="$(bypass_managed_hooks_path)" || managed_status=$?
  case "$managed_status" in
    0)
      if ! hooks_finding="$(pg_check_managed_hooks_path "$PROJECT_DIR" "$managed_hooks_path" --local)"; then
        findings+=("$hooks_finding")
        worst="fail"
      fi
      ;;
    2) ;; # genuinely unmanaged
    *) findings+=("local attachment state: sibling owner unavailable or invalid — managed hooks cannot be verified"); worst="fail" ;;
  esac
fi

# Every attached harness runs through this owner-recorded runtime anchor.
# Pin its kind, literal target, physical parent and resolved payload directory
# before authenticating any harness registration; JSON command text alone is not
# enough to detect a stale or retargeted anchor.
bypass_runtime_registered() {
  python3 -I -c '
import json, os, stat, sys
root = sys.argv[1]
owned = json.load(sys.stdin)["artifacts"]
anchors = [entry for entry in owned if entry["path"] == ".trellis/runtime"]
if len(anchors) != 1:
    sys.exit(1)
anchor = anchors[0]
payload = anchor.get("target")
if (anchor["kind"] != "symlink" or not isinstance(payload, str) or not payload
        or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in payload) or not os.path.isabs(payload)):
    sys.exit(1)
if not stat.S_ISDIR(os.lstat(os.path.join(root, ".trellis")).st_mode):
    sys.exit(1)
runtime = os.path.join(root, ".trellis/runtime")
if os.readlink(runtime) != payload or os.path.realpath(payload) != payload or not os.path.isdir(payload):
    sys.exit(1)
print(payload)
' "$PROJECT_DIR" <<< "$attachment_state" 2>/dev/null
}

runtime_payload=""
if [ -n "$attached_harnesses" ]; then
  if ! runtime_payload="$(bypass_runtime_registered)"; then
    findings+=(".trellis/runtime: runtime anchor missing or does not match owner — attached hooks cannot be verified")
    worst="fail"
  fi
fi

# Render owned_keys are the recorded event/group/command values, including
# matchers and hook options. Compare all recorded hook keys, not just any command.
# Older file-only records can instead authenticate the full recorded SHA-256.
# A deferred/project-authored render with no recorded expectations fails closed.
bypass_owned_hooks_registered() {
  local harness="$1" expectations expectation keys digest s matched
  shift
  expectations="$(jq -ce --arg harness "$harness" '
    def registration_path:
      if $harness == "claude" then . == ".claude/settings.json" or . == ".claude/settings.local.json"
      elif $harness == "antigravity" then . == ".agents/hooks.json"
      else . == ".codex/hooks.json" end;
    def root_key:
      if $harness == "antigravity" then "trellis" else "hooks" end;
    def commands:
      if $harness == "antigravity" then
        .trellis | objects
        | ((.SessionStart // []), (.PreInvocation // []), (.Stop // []),
           ((.PreToolUse // []) | map(objects | .hooks // []) | add // []),
           ((.PostToolUse // []) | map(objects | .hooks // []) | add // []))
        | arrays | .[] | objects
        | select(.type == "command" and (.command | type == "string" and test("\\S")))
      else
        .hooks | objects | to_entries[] | select(.key | test("\\S"))
        | .value | arrays | .[] | objects | .hooks | arrays | .[] | objects
        | select(.type == "command" and (.command | type == "string" and test("\\S")))
      end;
    .renders as $renders
    | [$renders[] | select(.path | registration_path)
        | [.owned_keys[] | select(.path[0] == root_key)] as $keys
        | if ($keys | length) > 0
            and (all($keys[]; .path | type == "array" and length > 0 and all(.[]; type == "string")))
            and ([reduce $keys[] as $key ({}; setpath($key.path; $key.value)) | commands] | length) > 0
          then {keys:$keys} else error("render has no recorded hook commands") end]
      + [.artifacts[] | select(.path | registration_path)
          | select(.kind == "file" and (.sha256 | type == "string" and test("^[a-f0-9]{64}$")))
          | select(.path as $path | any($renders[]; .path == $path) | not)
          | {sha256:.sha256}]
    | if length > 0 then . else error("no recorded registration expectations") end
  ' <<< "$attachment_state" 2>/dev/null)" || return 1
  while IFS= read -r expectation; do
    keys="$(jq -c '.keys // []' <<< "$expectation")" || return 1
    digest="$(jq -r '.sha256 // empty' <<< "$expectation")" || return 1
    matched=""
    for s in "$@"; do
      [ -f "$PROJECT_DIR/$s" ] && [ ! -L "$PROJECT_DIR/$s" ] || continue
      # Attachment rejects symlinked surface parents; do not authenticate a decoy.
      [ "$(CDPATH='' cd "$(dirname "$PROJECT_DIR/$s")" && pwd -P)" = "$(dirname "$PROJECT_DIR/$s")" ] || continue
      if [ -n "$digest" ]; then
        [ "$(bypass_hash < "$PROJECT_DIR/$s")" = "$digest" ] || continue
        if [ "$harness" = "antigravity" ]; then
          jq -e '
            .trellis | objects
            | ((.SessionStart // []), (.PreInvocation // []), (.Stop // []),
               ((.PreToolUse // []) | map(objects | .hooks // []) | add // []),
               ((.PostToolUse // []) | map(objects | .hooks // []) | add // []))
            | arrays | .[] | objects
            | select(.type == "command" and (.command | type == "string" and test("\\S")))
          ' "$PROJECT_DIR/$s" >/dev/null 2>&1 || continue
        else
          jq -e '
            .hooks | objects | to_entries[] | select(.key | test("\\S"))
            | .value | arrays | .[] | objects | .hooks | arrays | .[] | objects
            | select(.type == "command" and (.command | type == "string" and test("\\S")))
          ' "$PROJECT_DIR/$s" >/dev/null 2>&1 || continue
        fi
      else
        jq -e --argjson keys "$keys" '
          . as $settings | all($keys[]; . as $key | $settings | getpath($key.path) == $key.value)
        ' "$PROJECT_DIR/$s" >/dev/null 2>&1 || continue
      fi
      matched="yes"
      break
    done
    [ -n "$matched" ] || return 1
  done <<< "$(jq -c '.[]' <<< "$expectations")"
}

for harness in claude codex antigravity; do
  harness_required=""
  grep -Fxq "$harness" <<< "$attached_harnesses" && harness_required="yes"
  # Preserve the existing Claude settings tampering check even on raw clones.
  [ "$harness" = "claude" ] || [ -n "$harness_required" ] || continue
  case "$harness" in
    claude) hook_files=(".claude/settings.json" ".claude/settings.local.json") ;;
    codex) hook_files=(".codex/hooks.json") ;;
    antigravity) hook_files=(".agents/hooks.json") ;;
  esac
  settings_seen=""
  hooks_registered=""
  for s in "${hook_files[@]}"; do
    [ -e "$PROJECT_DIR/$s" ] || [ -L "$PROJECT_DIR/$s" ] || continue
    settings_seen="yes"
    [ -f "$PROJECT_DIR/$s" ] || continue
    if [ "$harness" = "antigravity" ]; then
      if jq -e '
        .trellis | objects
        | ((.SessionStart // []), (.PreInvocation // []), (.Stop // []),
           ((.PreToolUse // []) | map(objects | .hooks // []) | add // []),
           ((.PostToolUse // []) | map(objects | .hooks // []) | add // []))
        | arrays | .[] | objects
        | select(.type == "command" and (.command | type == "string" and test("\\S")))
      ' "$PROJECT_DIR/$s" >/dev/null 2>&1; then
        hooks_registered="yes"
      fi
    elif jq -e '
      .hooks | objects | to_entries[] | select(.key | test("\\S"))
      | .value | arrays | .[] | objects | .hooks | arrays | .[] | objects
      | select(.type == "command" and (.command | type == "string" and test("\\S")))
    ' "$PROJECT_DIR/$s" >/dev/null 2>&1; then
      hooks_registered="yes"
    fi
  done
  if [ -n "$harness_required" ]; then
    if [ -n "$hooks_registered" ] && bypass_owned_hooks_registered "$harness" "${hook_files[@]}"; then
      hooks_registered="yes"
    else
      hooks_registered=""
    fi
  fi
  [ -n "$harness_required" ] || [ -n "$settings_seen" ] || continue
  [ -z "$hooks_registered" ] || continue
  case "$harness" in
    claude)
      if [ -n "$settings_seen" ]; then
        findings+=(".claude/settings.json / .claude/settings.local.json: no \"hooks\" event with a command entry matching the required registration in either — Tier 1+2 hooks not registered")
      else
        findings+=(".claude/settings.json / .claude/settings.local.json: neither file exists in a Claude-attached project — Tier 1+2 hooks not registered")
      fi
      ;;
    codex)
      if [ -n "$settings_seen" ]; then
        findings+=(".codex/hooks.json: no \"hooks\" event with a command entry matching owner-recorded Trellis hooks — Tier 1+2 hooks not registered")
      else
        findings+=(".codex/hooks.json: file missing in a Codex-attached project — Tier 1+2 hooks not registered")
      fi
      ;;
    antigravity)
      if [ -n "$settings_seen" ]; then
        findings+=(".agents/hooks.json: no \"trellis\" event with a command entry matching owner-recorded Trellis hooks — Tier 1+2 hooks not registered")
      else
        findings+=(".agents/hooks.json: file missing in an antigravity attached project — Tier 1+2 hooks not registered")
      fi
      ;;
  esac
  worst="fail"
done

if grep -Fxq antigravity <<< "$attached_harnesses" || grep -Fxq opencode <<< "$attached_harnesses"; then
  expected_agents_target="$(jq -er '.artifacts[] | select(.path == ".agents/AGENTS.md" and .kind == "symlink") | .target' <<< "$attachment_state" 2>/dev/null || true)"
  if [ -z "$expected_agents_target" ] || [ ! -L "$PROJECT_DIR/.agents/AGENTS.md" ] ||
     [ "$(readlink "$PROJECT_DIR/.agents/AGENTS.md" 2>/dev/null || true)" != "$expected_agents_target" ] ||
     [ "$(unset CDPATH; cd "$(dirname "$PROJECT_DIR/.agents/AGENTS.md")" 2>/dev/null && pwd -P)" != "$PROJECT_DIR/.agents" ]; then
    findings+=(".agents/AGENTS.md: required parent rules symlink missing or tampered")
    worst="fail"
  fi
fi

if grep -Fxq opencode <<< "$attached_harnesses"; then
  if [ -e "$PROJECT_DIR/.opencode/opencode.jsonc" ] || [ -L "$PROJECT_DIR/.opencode/opencode.jsonc" ]; then
    findings+=(".opencode/opencode.jsonc: sibling JSONC file shadows .opencode/opencode.json")
    worst="fail"
  fi
  opencode_keys="$(jq -ce '[.renders[] | select(.path == ".opencode/opencode.json")][0].owned_keys | select(type == "array" and length > 0)' <<< "$attachment_state" 2>/dev/null || true)"
  if [ -z "$opencode_keys" ] || [ ! -f "$PROJECT_DIR/.opencode/opencode.json" ] || [ -L "$PROJECT_DIR/.opencode/opencode.json" ] ||
     [ "$(unset CDPATH; cd "$PROJECT_DIR/.opencode" 2>/dev/null && pwd -P)" != "$PROJECT_DIR/.opencode" ] ||
     ! jq -e --argjson keys "$opencode_keys" '. as $doc | all($keys[]; . as $k | $doc | getpath($k.path) == $k.value) and ((.instructions // []) | index(".agents/AGENTS.md") != null)' "$PROJECT_DIR/.opencode/opencode.json" >/dev/null 2>&1; then
    findings+=(".opencode/opencode.json: required OpenCode instructions render missing or tampered")
    worst="fail"
  fi
fi

# Authenticate every owner-recorded Pi auxiliary, including dormant executables
# and literal parent directories. The validator filters historical dispatcher
# requirements by the pinned manifest: current delivery links only trellis.ts,
# but still requires its sealed runtime rules. Doctor/show-config share it.
if grep -Fxq pi <<< "$attached_harnesses"; then
  if ! pi_findings="$(python3 -I "$SKILL_DIR/scripts/lib/pi-artifacts.py" \
      "$PROJECT_DIR" "$runtime_payload" .pi/extensions/trellis.ts .pi/hooks/dispatch.sh \
      <<< "$attachment_state" 2>&1)"; then
    while IFS= read -r line; do
      findings+=("$line")
    done <<< "${pi_findings:-native Pi hook artifacts could not be verified}"
    worst="fail"
  fi
fi

# Git reflog records commit subjects, not invocation flags; a subject containing
# "no-verify" is not evidence that hooks were skipped.
case "$worst" in
  pass) pg_log pass "Bypass markers (range=$RANGE)" ;;
  warn) pg_log warn "Bypass markers (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "Bypass markers (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac
pg_finding "Bypass coverage: Git reflog does not record --no-verify; hook execution cannot be verified post-hoc by this check"
pg_finding "Husky coverage: short-circuit detection is a heuristic, not a full shell analysis"

pg_exit_code "$worst"
