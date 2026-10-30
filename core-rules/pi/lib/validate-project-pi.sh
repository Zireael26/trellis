#!/usr/bin/env bash
# validate-project-pi.sh — refuse to start pi over branch-controlled project
# configuration in <cwd>/.pi and <cwd>/.agents.
#
# pi trusts the project directory by default and loads from <cwd>/.pi:
# settings.json, mcp.json, extensions/ (code it executes), skills/, prompts/,
# themes/, SYSTEM.md, APPEND_SYSTEM.md, npm/ and git/ (project packages);
# pi-subagents adds agents/, workflows/, subagents.json (24 keys that override
# the user's global, fail-closed settings), agent-tool-description.md and
# settings.json. From .agents, pi-subagents loads agents/ and workflows/, and pi
# loads skills/ in <cwd> and every ancestor up to the repository root. A branch
# can therefore widen tools, models and isolation for whoever starts pi in its
# worktree. Every Trellis pi launcher runs this first.
#
# Default deny. An entry in those locations passes only when it is:
#   - .pi/subagents.json holding exactly the launcher's own payload
#     (--foreman: {"workflowsEnabled": true, "toolDescriptionMode": "compact"};
#     other launchers write none, so for them it must be absent);
#   - .pi/.gitignore (read by git, never by pi);
#   - pi output: .pi/generated-images/** (pi-antigravity, never loaded) and
#     .pi/subagent-schedules/** (pi-subagents reads only the file named for the
#     session being resumed, and a launcher starts a fresh session; accepted as
#     output by the B0-6 ruling);
#   - an agent file in .pi/agents/ or .agents/agents/ byte-identical to the
#     release roster beside this script (../agents/<name>.md), the copy
#     foreman-start.sh materializes;
#   - a Trellis-managed attachment link: listed in the managed block of the
#     clone's info/exclude (machine-local, not branch content), carrying the
#     exact ../.trellis/runtime/<source> text attach writes, with an untracked
#     .trellis/runtime symlink into $TRELLIS_HOME/releases/ and the link
#     resolving inside it;
#   - a source-checkout .agents/skills/<name> link with exact
#     ../../core-rules/skills/<name> text, when that canonical source tree is
#     unchanged at the protected base and has no untracked files, symlinks or
#     hardlinks;
#   - otherwise, tracked and byte-identical at the protected base: the remote
#     default branch tip, resolved as pre-push's default_branch_ref does. If it
#     merged there, it went through the owner-approved gate.
# Any other symlink, any hardlink, anything unlistable, and anything else
# refuses. Empty directories load nothing and pass. <cwd> equal to the
# account's home (its passwd entry, never $HOME) is the user's own profile, not
# a project, and is not checked.
#
# The caller's environment can come from a branch's .envrc. GIT_* variables are
# cleared, so it cannot point git at another repository's index, refs or
# exclude block; tools run from the system directories only, plus jq's own
# directory when jq lives elsewhere; and HOME, TRELLIS_HOME (other than the
# account's own values), PI_CODING_AGENT_DIR or that jq resolving inside the
# checkout refuses before anything is scanned. Launchers start this script with
# a clean environment, since BASH_ENV or SHELLOPTS act before its first line.
#
# Usage: validate-project-pi.sh [--foreman] <dir>
# Exit: 0 pass; 1 refused (reasons on stderr); 2 usage.
set -euo pipefail

caller_path="${PATH:-}"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
jq_dir=""
if ! command -v jq >/dev/null 2>&1; then
  while IFS= read -r -d : entry; do
    [ -n "$entry" ] || entry=.
    if [ -f "$entry/jq" ] && [ -x "$entry/jq" ]; then
      jq_dir="$(cd -P "$entry" 2>/dev/null && pwd)" && break
    fi
  done <<<"$caller_path:"
  [ -n "$jq_dir" ] || { echo 'validate-project-pi: jq not found' >&2; exit 1; }
  PATH="$PATH:$jq_dir"
fi
while IFS= read -r var; do unset "$var"; done < <(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p')
export GIT_LITERAL_PATHSPECS=1

FOREMAN=false
if [ "${1:-}" = --foreman ]; then FOREMAN=true; shift; fi
[ "$#" -eq 1 ] || { echo 'usage: validate-project-pi.sh [--foreman] <dir>' >&2; exit 2; }

FOREMAN_PAYLOAD='{"workflowsEnabled": true, "toolDescriptionMode": "compact"}'
REMEDY='remove it, or merge it through a PR with owner approval'
EXCLUDE_BEGIN='# --- Trellis local attachment exclude block ---'
EXCLUDE_END='# --- end Trellis local attachment exclude block ---'
ROSTER="$(cd -P "$(dirname "$0")/../agents" 2>/dev/null && pwd)" || ROSTER=""

root="$(cd -P "$1" 2>/dev/null && pwd)" || { echo "validate-project-pi: cannot resolve '$1'" >&2; exit 1; }
real_home="$(python3 -Ic 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null)" &&
  real_home="$(cd -P "$real_home" 2>/dev/null && pwd)" || real_home=""
[ -z "$real_home" ] || [ "$root" != "$real_home" ] || exit 0

failures=0
refuse() {
  echo "validate-project-pi: refusing to start pi: $1" >&2
  failures=$((failures + 1))
}
link_count() { stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null; }

in_git=false top="$root" managed=""
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  in_git=true
  top="$(cd -P "$(git -C "$root" rev-parse --show-toplevel)" && pwd)"
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
  if [ -f "$common/info/exclude" ]; then
    managed="$(awk -v b="$EXCLUDE_BEGIN" -v e="$EXCLUDE_END" '$0 == b { on = 1; next } $0 == e { on = 0 } on' "$common/info/exclude")"
  fi
fi
# Paths below are relative to the repository root (or <dir> outside git).
relpath() { printf '%s' "${1#"$top"/}"; }

# An environment path made absolute against <dir>, as pi would take it, with
# symlinks resolved; a missing tail is kept as written. A symlink or '..' in
# that tail cannot be judged, so it fails.
resolve_env_path() {
  local p="$1" tail=""
  case "$p" in /*) ;; *) p="$root/$p" ;; esac
  while [ ! -d "$p" ]; do
    [ ! -L "$p" ] || return 1
    case "${p##*/}" in ..) return 1 ;; esac
    tail="/${p##*/}$tail"
    p="$(dirname "$p")"
  done
  p="$(cd -P "$p" 2>/dev/null && pwd)" || return 1
  [ "$p" != / ] || [ -z "$tail" ] || p=""
  printf '%s%s\n' "$p" "$tail"
}
inside_checkout() { case "$1/" in "$top"/*) return 0 ;; esac; return 1; }
check_env() {
  local name="$1" trusted="$2" value="${!1-}" resolved
  [ -n "$value" ] || return 0
  if ! resolved="$(resolve_env_path "$value")"; then
    refuse "$name ('$value') cannot be resolved; unset it, or point it outside '$top'"
    return
  fi
  [ -z "$trusted" ] || [ "$resolved" != "$trusted" ] || return 0
  if inside_checkout "$resolved"; then
    refuse "$name ('$value') resolves inside '$top', where a branch's .envrc can aim it; unset it, or point it outside"
  fi
}
check_env HOME "$real_home"
check_env TRELLIS_HOME "${real_home:+$real_home/.trellis}"
check_env PI_CODING_AGENT_DIR ""
if [ -n "$jq_dir" ] && inside_checkout "$jq_dir"; then
  refuse "jq resolves inside '$top' ($jq_dir/jq); install jq outside the checkout"
fi
[ "$failures" -eq 0 ] || exit 1

base_ref="" base_tried=false
protected_base() {
  if ! $base_tried; then
    base_tried=true
    if head_ref="$(git -C "$top" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" &&
       git -C "$top" rev-parse -q --verify "$head_ref^0" >/dev/null 2>&1; then
      base_ref="$head_ref"
    else
      for candidate in main master; do
        if git -C "$top" rev-parse -q --verify "refs/remotes/origin/$candidate^0" >/dev/null 2>&1; then
          base_ref="refs/remotes/origin/$candidate"
          break
        fi
      done
    fi
  fi
  [ -n "$base_ref" ]
}

# The attachment anchor: an untracked symlink resolving into a release payload.
runtime_p=""
runtime_anchor() {
  local releases
  [ -z "$runtime_p" ] || return 0
  [ -L "$top/.trellis/runtime" ] || return 1
  ! git -C "$top" ls-files --error-unmatch -- .trellis/runtime >/dev/null 2>&1 || return 1
  releases="$(cd -P "${TRELLIS_HOME:-$real_home/.trellis}/releases" 2>/dev/null && pwd)" || return 1
  runtime_p="$(cd -P "$top/.trellis/runtime" 2>/dev/null && pwd)" || return 1
  case "$runtime_p" in "$releases"/*) return 0 ;; esac
  runtime_p=""
  return 1
}

managed_link() {
  local rel="$1" text depth up="" i target
  $in_git || return 1
  printf '%s\n' "$managed" | grep -Fxq -- "/$rel" || return 1
  text="$(readlink "$top/$rel")" || return 1
  depth="$(printf '%s' "$rel" | tr -cd '/' | wc -c | tr -d ' ')"
  for ((i = 0; i < depth; i++)); do up="../$up"; done
  case "$text" in "$up.trellis/runtime/"*) ;; *) return 1 ;; esac
  case "${text#"$up"}" in *'/../'*|*'/..') return 1 ;; esac
  runtime_anchor || return 1
  if [ -d "$top/$rel" ]; then
    target="$(cd -P "$top/$rel" 2>/dev/null && pwd)" || return 1
  else
    target="$(cd -P "$(dirname "$top/$rel")/$(dirname "$text")" 2>/dev/null && pwd)/$(basename "$text")" || return 1
  fi
  case "$target" in "$runtime_p"/*) return 0 ;; esac
  return 1
}

# A source-checkout link is trusted only when it names the exact canonical
# sibling, and that entire skill directory still matches the protected base.
source_skill_link() {
  local rel="$1" name text source_rel source untracked symlinks hardlinks
  $in_git || return 1
  case "$rel" in .agents/skills/*) name="${rel#.agents/skills/}" ;; *) return 1 ;; esac
  case "$name" in ''|.|..|*/*) return 1 ;; esac
  text="$(readlink "$top/$rel")" || return 1
  [ "$text" = "../../core-rules/skills/$name" ] || return 1
  [ ! -L "$top/core-rules" ] && [ ! -L "$top/core-rules/skills" ] || return 1
  source_rel="core-rules/skills/$name"
  source="$top/$source_rel"
  [ -d "$source" ] && [ ! -L "$source" ] && [ -f "$source/SKILL.md" ] && [ ! -L "$source/SKILL.md" ] || return 1
  protected_base || return 1
  git -C "$top" cat-file -e "$base_ref:$source_rel/SKILL.md" 2>/dev/null || return 1
  git -C "$top" diff --quiet "$base_ref" -- "$source_rel" || return 1
  untracked="$(git -C "$top" ls-files --others -- "$source_rel")" || return 1
  [ -z "$untracked" ] || return 1
  symlinks="$(find "$source" -type l -print -quit 2>/dev/null)" || return 1
  [ -z "$symlinks" ] || return 1
  hardlinks="$(find "$source" -type f -links +1 -print -quit 2>/dev/null)" || return 1
  [ -z "$hardlinks" ] || return 1
  return 0
}

# Tracked and byte-identical at the protected base, or a refusal naming why.
check_at_base() {
  local rel="$1" why="$2" blob
  if ! $in_git; then
    refuse "'$rel' $why and is untracked (not in a git worktree); $REMEDY"
    return
  fi
  if ! git -C "$top" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    refuse "'$rel' $why and is untracked; $REMEDY"
    return
  fi
  if ! protected_base; then
    refuse "'$rel' $why and is tracked, but the protected base (origin's default branch) cannot be resolved; fetch it, or $REMEDY"
    return
  fi
  if ! blob="$(git -C "$top" rev-parse -q --verify "$base_ref:$rel" 2>/dev/null)"; then
    refuse "'$rel' $why and is not on the protected base $base_ref; $REMEDY"
    return
  fi
  if [ "$(git -C "$top" hash-object --no-filters -- "$rel")" != "$blob" ]; then
    refuse "'$rel' $why and differs from the protected base $base_ref; $REMEDY"
  fi
}

check_subagents() {
  local rel="$1" extra
  # -s: a file holding several JSON values is never "the payload".
  if $FOREMAN && jq -se --argjson want "$FOREMAN_PAYLOAD" 'length == 1 and .[0] == $want' "$top/$rel" >/dev/null 2>&1; then
    return
  fi
  if extra="$(jq -sr --argjson want "$FOREMAN_PAYLOAD" \
      'if length != 1 then "several JSON values" elif (.[0] | type) != "object" then "not a JSON object"
       else [.[0] | keys[] as $k | select(($want | has($k)) | not) | $k] | join(", ") end' \
      "$top/$rel" 2>/dev/null)"; then
    [ -n "$extra" ] || extra="values other than this launcher's own"
  else
    extra="not valid JSON"
  fi
  if $FOREMAN; then
    check_at_base "$rel" "holds more than the foreman payload ($extra)"
  else
    check_at_base "$rel" "overrides subagent settings ($extra)"
  fi
}

check_entry() {
  local path="$1" rel links name
  rel="$(relpath "$path")"
  if [ -L "$path" ]; then
    managed_link "$rel" || source_skill_link "$rel" || refuse "'$rel' is a symlink; $REMEDY"
    return
  fi
  [ ! -d "$path" ] || return 0
  if [ ! -f "$path" ]; then
    refuse "'$rel' is not a regular file; $REMEDY"
    return
  fi
  links="$(link_count "$path")" || { refuse "cannot read the link count of '$rel'"; return; }
  if [ "$links" -ne 1 ]; then
    refuse "'$rel' has link count $links (hardlinked); $REMEDY"
    return
  fi
  name="$(basename "$path")"
  case "$path" in
    "$root/.pi/subagents.json") check_subagents "$rel"; return ;;
    "$root/.pi/.gitignore"|"$root/.pi/generated-images/"*|"$root/.pi/subagent-schedules/"*) return ;;
    "$root/.pi/agents/$name"|"$root/.agents/agents/$name")
      if [ -n "$ROSTER" ] && [ -f "$ROSTER/$name" ] && cmp -s "$ROSTER/$name" "$path"; then
        return
      fi
      ;;
  esac
  check_at_base "$rel" "is loaded by pi or its packages"
}

# Scan one loader location: refuse a symlinked or unlistable one, then judge
# every entry beneath it. find's own failure is a refusal, not an empty list.
scan() {
  local dir="$1" list status=0
  if [ -L "$dir" ]; then
    check_entry "$dir"
    return
  fi
  [ -e "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    refuse "'$(relpath "$dir")' is not a directory; $REMEDY"
    return
  fi
  list="$(mktemp "${TMPDIR:-/tmp}/validate-project-pi.XXXXXX")"
  find "$dir" -mindepth 1 -print0 >"$list" 2>/dev/null || status=$?
  if [ "$status" -ne 0 ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    refuse "'$(relpath "$dir")' cannot be fully listed (check its permissions); $REMEDY"
  fi
  while IFS= read -r -d '' path; do check_entry "$path"; done <"$list"
  rm -f "$list"
}

scan "$root/.pi"
if [ -L "$root/.agents" ]; then
  refuse "'$(relpath "$root/.agents")' is a symlink; $REMEDY"
else
  scan "$root/.agents/agents"
  scan "$root/.agents/workflows"
fi
dir="$root"
while :; do
  if [ ! -L "$dir/.agents" ]; then
    scan "$dir/.agents/skills"
  elif [ "$dir" != "$root" ]; then
    refuse "'$(relpath "$dir/.agents")' is a symlink; $REMEDY"
  fi
  [ "$dir" != "$top" ] && [ "$dir" != / ] || break
  $in_git || break
  dir="$(dirname "$dir")"
done

[ "$failures" -eq 0 ] || exit 1
