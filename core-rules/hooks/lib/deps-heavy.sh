#!/usr/bin/env bash
# Heavy shared helpers for Trellis hooks, split from lib/deps.sh so the hooks
# that never call them do not parse them. Loaded only by _se_load_heavy in
# lib/deps.sh (eagerly by the hooks that use these functions, lazily by its
# first-call stubs); never sourced directly.


# A failed state lookup is silent only when Git positively identifies a
# non-worktree. Missing Git, inaccessible repositories and other errors are
# indeterminate and must retain the prompt's degraded warning.
_se_turn_confirm_non_git() {
  local result rc
  if declare -F git >/dev/null; then
    # A caller may wrap git as a function; keep that dispatch and its locale.
    result=$({ export LC_ALL=C && git -C "$1" rev-parse --is-inside-work-tree; } 2>&1); rc=$?
  else
    result=$(/usr/bin/env LC_ALL=C git -C "$1" rev-parse --is-inside-work-tree 2>&1); rc=$?
  fi
  case "$rc:$result" in
    0:false|128:'fatal: not a git repository'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Posix-quote one native registration operand without evaluating it. This is
# the same always-quoted representation used by the contextual renderer.
_se_turn_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

# Reject duplicate keys and non-finite constants; jq otherwise accepts the
# last duplicate, which can disagree with the registering client.
_se_turn_json_strict() {
  [ -x /usr/bin/python3 ] || return 1
  /usr/bin/python3 -I - "$@" <<'PY'
import json, sys
def pairs(items):
    out = {}
    for key, value in items:
        if key in out: raise ValueError('duplicate JSON key')
        out[key] = value
    return out
def bad(_): raise ValueError('non-finite JSON number')
try:
    for path in sys.argv[1:]:
        with open(path, 'rb') as stream:
            json.load(stream, object_pairs_hook=pairs, parse_constant=bad)
except (OSError, ValueError, UnicodeError, RecursionError):
    raise SystemExit(1)
PY
}

# _se_turn_json_strict_each <file>... — one interpreter for several files:
# prints one character per file, 1 when it passes _se_turn_json_strict's
# checks and 0 otherwise (unreadable or absent included).
_se_turn_json_strict_each() {
  [ -x /usr/bin/python3 ] || return 1
  /usr/bin/python3 -I - "$@" <<'STRICT'
import json, sys
def pairs(items):
    out = {}
    for key, value in items:
        if key in out: raise ValueError('duplicate JSON key')
        out[key] = value
    return out
def bad(_): raise ValueError('non-finite JSON number')
marks = []
for path in sys.argv[1:]:
    try:
        with open(path, 'rb') as stream:
            json.load(stream, object_pairs_hook=pairs, parse_constant=bad)
        marks.append('1')
    except (OSError, ValueError, UnicodeError, RecursionError):
        marks.append('0')
sys.stdout.write(''.join(marks))
STRICT
}

# Check ancestors in order without an external process, so a path hidden by
# an unsearchable ancestor is not mistaken for an ordinary missing path. The
# inspected directory itself must also be readable.
_se_turn_directory_inspectable() {
  local path="${1:-}" rest part current=/
  case "$path" in /*) rest="${path#/}" ;; *) return 1 ;; esac
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=''; else rest="${rest#*/}"; fi
    case "$part" in ''|.) continue ;; ..) return 1 ;; esac
    if [ "$current" = / ]; then current="/$part"; else current="$current/$part"; fi
    if [ -e "$current" ] || [ -L "$current" ]; then
      [ -d "$current" ] && [ -x "$current" ] || return 1
    else
      return 0
    fi
  done
  [ -r "$current" ] && [ -x "$current" ]
}

# Typed arming, never an authorization from a filename substring alone:
#   unarmed / legacy / native / unknown
# A native registration, or a native candidate in the attached release,
# requires the exact contextual prompt route and digest-pinned companion.
# Unknown never becomes unarmed. This is deliberately identical in both twins.
_se_turn_baseline_arming() {
  local dir="$1" harness="$2" file template runtime native=0 template_native=0 legacy=0 f user home
  local target version digest companion adapter adapter_digest shell command platform
  local root common ids checkout worktree owner relative owner_present=0 owner_harness=0 owner_render=0 owner_evidence anchor_target rc
  local harness_attached=0 managed settings_flags legacy_hit native_hit IFS=$' \t\n'
  local strict='' owner_native=0 owner_release='' template_flags launcher_hit prompt_hit host_target=''
  local art='' art_selectable=0 art_version='' art_digest='' art_adapter='' hashes companion_sum adapter_sum
  local -a managed_names=(turn-baseline stop-verify block-destructive reread-guard skill-preload-guard skill-slash-guard
    code-review-subagent decision-receipt env-echo inject-primer-index post-compact-context post-edit-verify
    pr-gate-shiftleft save-context-log session-context session-start slop-tripwire spec-gate stamp-turn track-read ui-verify)
  case "$harness" in
    claude) file="$dir/.claude/settings.local.json"; template=claude-settings.local.json ;;
    codex) file="$dir/.codex/hooks.json"; template=codex-hooks.local.json ;;
    # Pi's compatibility Stop historically inspects the Codex registration.
    pi) harness=codex; file="$dir/.codex/hooks.json"; template=codex-hooks.local.json ;;
    *) printf 'unknown\n'; return 0 ;;
  esac
  runtime="$dir/.trellis/runtime"
  home="${TRELLIS_HOME:-${HOME:-}/.trellis}"
  _se_turn_directory_inspectable "$dir/.$harness" &&
    _se_turn_directory_inspectable "$dir/.$harness/hooks" &&
    _se_turn_directory_inspectable "$home/state" &&
    _se_turn_directory_inspectable "$home/state/attachments" || { printf 'unknown\n'; return 0; }
  for f in "$file" "$dir/.claude/settings.json"; do
    [ "$harness" = claude ] || [ "$f" = "$file" ] || continue
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
    # An existing settings entry that cannot be inspected is not evidence of
    # an unarmed project, even when its owner record has disappeared.
    [ -f "$f" ] && [ -r "$f" ] || { printf 'unknown\n'; return 0; }
    command -v jq >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    # One read: exactly one object, then its legacy and native evidence.
    settings_flags=$(jq -ser '
      if length == 1 and (.[0] | type == "object") then .[0] |
      [(any(.hooks.UserPromptSubmit[]?.hooks[]?; (.type == "command" or .type == null) and
         (([.command // ""] + (.args // [])) | any(.[]; type == "string" and contains("turn-baseline.sh")))) | if . then "1" else "0" end),
       (any(.. | strings; contains("/bin/native/")) | if . then "1" else "0" end)] | @tsv
      else error("not one object") end' "$f" 2>/dev/null) || { printf 'unknown\n'; return 0; }
    read -r legacy_hit native_hit <<< "$settings_flags"
    case "$legacy_hit:$native_hit" in 0:0|0:1|1:0|1:1) ;; *) printf 'unknown\n'; return 0 ;; esac
    if [ "$legacy_hit" = 1 ]; then legacy=1; harness_attached=1; fi
    # Inspect decoded values as well as raw bytes: JSON may escape slashes.
    if [ "$native_hit" = 1 ] || grep -qF '/bin/native/' "$f" 2>/dev/null; then
      native=1; harness_attached=1
    else
      rc=$?; [ "$rc" -eq 1 ] || { printf 'unknown\n'; return 0; }
    fi
    if [ "$harness_attached" = 0 ]; then
      if jq -e --arg h "$harness" --arg names "${managed_names[*]}" '
        [.hooks? // {} | .. | objects | (.command? // empty), (.args[]? // empty) | strings]
        | any(.[]; contains("/.trellis/runtime/") or
            test("\\." + $h + "/hooks/(" + ($names | split(" ") | join("|")) + ")\\.sh($|[^A-Za-z0-9_.-])"))' "$f" >/dev/null 2>&1; then
        harness_attached=1
      else
        rc=$?; [ "$rc" -eq 1 ] || { printf 'unknown\n'; return 0; }
      fi
    fi
  done
  # The harness directory itself is not evidence: an unrelated harness may
  # be attached. A known managed hook or a matching owner path is evidence.
  for managed in "${managed_names[@]}"; do
    f="$dir/.$harness/hooks/$managed.sh"
    if [ -e "$f" ] || [ -L "$f" ]; then harness_attached=1; break; fi
  done
  # The attachment owner retains the expected render if settings and even
  # the runtime anchor have disappeared. Without this check a broken native
  # attachment could masquerade as an unattached/unarmed legacy checkout.
  if [ -d "${TRELLIS_HOME:-${HOME:-}/.trellis}/state/attachments" ]; then
    home=$(CDPATH='' cd "${TRELLIS_HOME:-${HOME:-}/.trellis}" 2>/dev/null && pwd -P) || { printf 'unknown\n'; return 0; }
    if ! root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
      if [ "$native" = 1 ] || { [ "$harness_attached" = 1 ] && [ "$legacy" = 0 ]; }; then printf 'unknown\n'
      elif [ "$legacy" = 1 ]; then printf 'legacy\n'
      else printf 'unarmed\n'; fi
      return 0
    fi
    root=$(CDPATH='' cd "$root" 2>/dev/null && pwd -P) || { printf 'unknown\n'; return 0; }
    common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || { printf 'unknown\n'; return 0; }
    case "$common" in /*) ;; *) common="$root/$common" ;; esac
    common=$(CDPATH='' cd "$common" 2>/dev/null && pwd -P) || { printf 'unknown\n'; return 0; }
    ids=$(/usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB /usr/bin/perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])," ",sha256_hex($ARGV[1])' "$common" "$root" 2>/dev/null) || { printf 'unknown\n'; return 0; }
    read -r checkout worktree <<< "$ids"
    _se_turn_directory_inspectable "$home/state/attachments/$checkout" || { printf 'unknown\n'; return 0; }
    owner="$home/state/attachments/$checkout/$worktree.json"
    relative="${file#"$dir"/}"
    if [ -e "$owner" ] || [ -L "$owner" ]; then
      [ -f "$owner" ] && [ ! -L "$owner" ] || { printf 'unknown\n'; return 0; }
      /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB /usr/bin/perl -e '
        my ($file,@dirs)=@ARGV;
        for my $dir (@dirs) { my @s=lstat($dir); exit 1 unless @s && ($s[2] & 0170000)==0040000 && $s[4]==$< && ($s[2] & 07777)==0700 }
        my @s=lstat($file); exit !(@s && ($s[2] & 0170000)==0100000 && $s[4]==$< && ($s[2] & 07777)==0600)' \
        "$owner" "$home" "$home/state" "$home/state/attachments" "$home/state/attachments/$checkout" 2>/dev/null || { printf 'unknown\n'; return 0; }
      # One interpreter checks the owner now and, for the native inspection
      # below, the registration, template and artifact manifest.
      strict=$(_se_turn_json_strict_each "$owner" "$file" "$runtime/core-rules/templates/$template" \
        "$runtime/core-rules/native/artifacts.json") || { printf 'unknown\n'; return 0; }
      [ "${strict:0:1}" = 1 ] || { printf 'unknown\n'; return 0; }
      # One read: the committed binding, then harness, render and native-key
      # evidence (a key that cannot be read is no evidence) and the release.
      owner_evidence=$(jq -er --arg root "$root" --arg co "$checkout" --arg wt "$worktree" --arg prefix ".$harness/" --arg p "$relative" '
        if type == "object" and .status == "committed" and .project_root == $root and .worktree_root == $root
          and .checkout_id == $co and .worktree_id == $wt and (.renders | type == "array") then
        [(any((.renders[]?, .artifacts[]?, .pre_existing[]?);
           (.path? | type == "string") and (.path | startswith($prefix))) | if . then "1" else "0" end),
         (any(.renders[]; .path == $p) | if . then "1" else "0" end),
         (try (any(.renders[] | select(.path == $p) | .owned_keys[]?.value | .. | strings; contains("/bin/native/"))
           | if . then "1" else "0" end) catch "0"),
         (.release | tojson)] | @tsv
        else error("not a committed owner") end' "$owner" 2>/dev/null) || { printf 'unknown\n'; return 0; }
      owner_present=1
      IFS=$'\t' read -r owner_harness owner_render owner_native owner_release <<< "$owner_evidence"
      case "$owner_harness:$owner_render" in 0:0|1:0|1:1) ;; *) printf 'unknown\n'; return 0 ;; esac
      [ "$owner_harness" = 0 ] || harness_attached=1
      [ "$owner_native" != 1 ] || native=1
    fi
  fi
  template="$runtime/core-rules/templates/$template"
  if [ "$harness_attached" = 1 ]; then
    if [ -f "$template" ]; then
      # One read: exactly one object, then its launcher entries; "e" marks a
      # template that could not be inspected.
      { [ -r "$template" ] && command -v jq >/dev/null 2>&1 &&
        template_flags=$(jq -ser --arg h "$harness" '
          if length == 1 and (.[0] | type == "object") then .[0] |
          [(try (any(.. | objects; .command? == "__TRELLIS_LAUNCHER__") | if . then "1" else "0" end) catch "e"),
           (try (any(.. | objects; .command? == "__TRELLIS_LAUNCHER__" and .args? == ["hook","event",$h,"UserPromptSubmit"])
             | if . then "1" else "0" end) catch "e")] | @tsv
          else error("not one object") end' "$template" 2>/dev/null); } || { printf 'unknown\n'; return 0; }
      read -r launcher_hit prompt_hit <<< "$template_flags"
      # A template is evidence only for a harness independently attached to
      # this worktree; releases routinely ship templates for other harnesses.
      # T34: its native placeholders are evidence only when the payload ships
      # this host's asset; otherwise attach rendered the legacy surface.
      case "$(uname -sm 2>/dev/null)" in
        'Darwin arm64') host_target=aarch64-apple-darwin ;;
        'Linux x86_64') host_target=x86_64-unknown-linux-musl ;;
        'Linux aarch64') host_target=aarch64-unknown-linux-musl ;;
      esac
      # One read of the artifact manifest: host asset present, version, host
      # digest and adapter digest; a field that cannot be used is empty. The
      # unit separator keeps an empty field in place (a tab IFS would merge
      # it); a version holding a control character is unusable (empty).
      if [ -n "$host_target" ] && [ -f "$runtime/core-rules/native/artifacts.json" ]; then
        art=$(jq -j --arg t "$host_target" '
          def hex: strings | select(test("^[0-9a-f]{64}$"));
          [(try ([.assets[$t].sha256 | strings] | length > 0 | if . then "1" else "0" end) catch "0"),
           (try (first(.version | strings | select(length > 0 and (test("[\u0000-\u001f]") | not))) // "") catch ""),
           (try (first(.assets[$t].sha256 | hex) // "") catch ""),
           (try (first(.adapter.sha256 | hex) // "") catch "")] | join("\u001f")' \
          "$runtime/core-rules/native/artifacts.json" 2>/dev/null) || art=''
        IFS=$'\037' read -r art_selectable art_version art_digest art_adapter <<< "$art"
      fi
      if [ "$art_selectable" = 1 ]; then
        case "$launcher_hit" in 1) native=1 ;; 0) ;; *) printf 'unknown\n'; return 0 ;; esac
        case "$prompt_hit" in 1) native=1; template_native=1 ;; 0) ;; *) printf 'unknown\n'; return 0 ;; esac
      fi
    elif [ "$legacy" = 0 ] || [ "$owner_harness" = 1 ] || [ -e "$dir/.trellis" ] || [ -L "$dir/.trellis" ]; then
      printf 'unknown\n'; return 0
    fi
  fi
  # If every harness-specific trace is removed, a stripped registration is
  # indistinguishable from intentional unarming (the accepted same-UID limit).
  if [ "$native" = 0 ]; then
    if [ "$legacy" = 1 ]; then printf 'legacy\n'; else printf 'unarmed\n'; fi
    return 0
  fi
  # Everything below is a conservative native inspection. Missing/malformed
  # inputs return unknown before Stop consumes/reuses any receipt.
  [ "$template_native" = 1 ] && [ "$owner_present" = 1 ] && [ "$owner_harness" = 1 ] && [ "$owner_render" = 1 ] || { printf 'unknown\n'; return 0; }
  [ -L "$runtime" ] || { printf 'unknown\n'; return 0; }
  anchor_target=$(readlink "$runtime") || { printf 'unknown\n'; return 0; }
  jq -e --arg target "$anchor_target" '
    [.artifacts[]? | select(.kind == "symlink" and .path == ".trellis/runtime" and .target == $target)] | length == 1' "$owner" >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  [ -f "$file" ] && [ ! -L "$file" ] && [ -f "$runtime/core-rules/native/artifacts.json" ] || { printf 'unknown\n'; return 0; }
  [ "$strict" = 1111 ] || { printf 'unknown\n'; return 0; }
  user=$(CDPATH='' cd "${HOME:-}" 2>/dev/null && pwd -P) || { printf 'unknown\n'; return 0; }
  home=$(CDPATH='' cd "${TRELLIS_HOME:-$user/.trellis}" 2>/dev/null && pwd -P) || { printf 'unknown\n'; return 0; }
  platform=$(uname -s) || { printf 'unknown\n'; return 0; }
  case "$platform:$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) printf 'unknown\n'; return 0 ;;
  esac
  [ "$target" = "$host_target" ] || { printf 'unknown\n'; return 0; }
  version=$art_version digest=$art_digest
  case "$version" in *[!0-9A-Za-z.+-]*|.*|'') printf 'unknown\n'; return 0 ;; esac
  [ "$owner_release" = "\"$version\"" ] && [ -n "$digest" ] || { printf 'unknown\n'; return 0; }
  companion="$home/bin/native/$version/$target/$digest/trellis-hooks"
  [ -f "$companion" ] && [ ! -L "$companion" ] && [ -x "$companion" ] || { printf 'unknown\n'; return 0; }
  # One process: the companion's ownership and modes, then the companion's
  # and the adapter's digests ("-" when the adapter cannot be read).
  hashes=$(/usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB /usr/bin/perl -MDigest::SHA -e '
    my ($file,$adapter,@dirs)=@ARGV;
    for my $dir (@dirs) { my @s=lstat($dir); exit 1 unless @s && ($s[2] & 0170000)==0040000 && $s[4]==$< && ($s[2] & 07777)==0700 }
    my @s=lstat($file); exit 1 unless @s && ($s[2] & 0170000)==0100000 && $s[4]==$< && ($s[2] & 07777)==0500;
    my $c = Digest::SHA->new(256); eval { $c->addfile($file, "b"); 1 } or exit 1;
    my $a = -f $adapter && Digest::SHA->new(256);
    $a = undef if $a && !eval { $a->addfile($adapter, "b"); 1 };
    print $c->hexdigest, " ", ($a ? $a->hexdigest : "-");' \
    "$companion" "$runtime/core-rules/native/hook-adapter.sh" \
    "$home/bin" "$home/bin/native" "$home/bin/native/$version" "$home/bin/native/$version/$target" "$home/bin/native/$version/$target/$digest" 2>/dev/null) || { printf 'unknown\n'; return 0; }
  read -r companion_sum adapter_sum <<< "$hashes"
  _se_paths_no_acl "$platform" "$home" "$home/state" "$home/state/attachments" "$home/state/attachments/$checkout" "$owner" \
    "$home/bin" "$home/bin/native" "$home/bin/native/$version" "$home/bin/native/$version/$target" \
    "$home/bin/native/$version/$target/$digest" "$companion" || { printf 'unknown\n'; return 0; }
  [ "$companion_sum" = "$digest" ] || { printf 'unknown\n'; return 0; }
  if [ "$harness" = claude ] && jq -e --arg u "$user" --arg th "$home" --arg c "$companion" --arg h "$harness" --arg d "$dir" '
    [.hooks.UserPromptSubmit[]?.hooks[]? | select(.type == "command" and .command == "/usr/bin/env"
      and .args == ["-i",("HOME="+$u),("TRELLIS_HOME="+$th),"PATH=/usr/bin:/bin:/usr/sbin:/sbin",$c,"event-client",$h,"UserPromptSubmit",$d]
      and (.timeout | type == "number" and . >= 30 and floor == .) and .onFailure == "block")] | length == 1' "$file" >/dev/null 2>&1; then
    printf 'native\n'; return 0
  fi
  [ -f "$runtime/core-rules/native/hook-adapter.sh" ] && [ ! -L "$runtime/core-rules/native/hook-adapter.sh" ] || { printf 'unknown\n'; return 0; }
  adapter_digest=$art_adapter
  [ -n "$adapter_digest" ] && [ "$adapter_sum" = "$adapter_digest" ] || { printf 'unknown\n'; return 0; }
  adapter=$(grep -vE '^[[:space:]]*#' "$runtime/core-rules/native/hook-adapter.sh") || { printf 'unknown\n'; return 0; }
  shell=/bin/sh; [ ! -x /bin/dash ] || shell=/bin/dash
  command="HOME=$(_se_turn_quote "$user") TRELLIS_HOME=$(_se_turn_quote "$home") $(_se_turn_quote "$shell") -c $(_se_turn_quote "$adapter") trellis-hooks $(_se_turn_quote "$companion") $(_se_turn_quote "$harness") $(_se_turn_quote UserPromptSubmit) $(_se_turn_quote "$dir")" || { printf 'unknown\n'; return 0; }
  if jq -e --arg c "$command" '
    [.hooks.UserPromptSubmit[]?.hooks[]? | select(.type == "command" and .command == $c
      and (.timeout | type == "number" and . >= 30 and floor == .) and (has("onFailure") | not))] | length == 1' "$file" >/dev/null 2>&1; then
    printf 'native\n'; return 0
  fi
  printf 'unknown\n'
}

# Legacy Boolean compatibility: unknown is conservatively armed, never an
# unarmed result. Stop uses the typed result to block unknown before reuse.
_se_turn_baseline_armed() {
  case "$(_se_turn_baseline_arming "$1" "$2")" in legacy|native|unknown) return 0 ;; *) return 1 ;; esac
}

# _se_fp_classify — NUL-separated root-relative paths on stdin; one record per
# path on stdout ("F" regular file, "L" symlink + hex of the raw target bytes,
# "X" absent). Fails on anything whose content it cannot cover: a directory
# (submodule or nested repo), a special file, or a path holding a newline or
# tab. The target is hex-encoded because $(readlink) would drop trailing
# newlines and make distinct targets collide.
_se_fp_classify() {
  local p target
  while IFS= read -r -d '' p; do
    case "$p" in *$'\n'*|*$'\t'*) return 1 ;; esac
    if [ -L "$p" ]; then
      target=$(readlink "$p" | od -An -tx1 | tr -d ' \n') || return 1
      [ -n "$target" ] || return 1
      printf 'L\t%s\t%s\n' "$p" "$target"
    elif [ -f "$p" ]; then
      printf 'F\t%s\n' "$p"
    elif [ -e "$p" ]; then
      return 1
    else
      printf 'X\t%s\n' "$p"
    fi
  done
}

# Restrict Git's view at the source, including tracked hook-state files and
# porcelain metadata (filtering only the content hash would still churn).
# .pi/subagent-schedules is pi's own session output (validate-project-pi.sh),
# which another agent in a shared checkout writes while this turn edits nothing.
# Both harnesses leave state in a shared checkout: exclude the same narrow
# state paths for either harness, while keeping real rules and nested paths.
__se_hook_state_pathspec=(':/'
  ':(exclude,top).claude/.fail-counter'
  ':(exclude,top).codex/.fail-counter'
  ':(exclude,top).codex/.reread-state'
  ':(exclude,top,glob).codex/.review-done-*'
  ':(exclude,top).claude/.reread-state'
  ':(exclude,top,glob).claude/.review-done-*'
  ':(exclude,top).claude/session-surgical'
  ':(exclude,top).claude/spec-gate-audit.log'
  ':(exclude,top).pi/.reread-state'
  ':(exclude,top).pi/subagent-schedules')
_se_hook_state_git() {
  git "$@" -- "${__se_hook_state_pathspec[@]}"
}

# Filter Git's NUL-delimited index tags in one process. Only paths needing
# inspection reach the shell; sparse absences are filtered there too. If Perl
# is unavailable, retain the slower shell fallback instead of refusing a
# benign no-flags worktree.
_se_flagged_candidates() {
  local sparse="$1" mode="${2:-paths}" record="" tag path seen=0
  if command -v perl >/dev/null 2>&1; then
    /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -0e '
      use strict; binmode STDIN; binmode STDOUT; my ($sparse, $mode) = @ARGV;
      my $seen = 0;
      while (1) {
        $! = 0;
        my $row = <STDIN>;
        if (!defined($row)) { exit 1 if $!; last }
        my ($tag, $path);
        if ($mode eq "cached") {
          if ($row eq "trellis-stop-flags-cache-v1\0") { exit 1 if $seen; $seen=1; next }
          exit 1 if $seen;
          $row =~ /\A([Ss]|[a-z]) (.+)\0\z/s or exit 1;
          ($tag, $path) = ($1, $2);
        } else {
          next unless $row =~ /\A([Ss]|[a-z]) (.*)\0\z/s;
          ($tag, $path) = ($1, $2);
        }
        if ($mode eq "tagged") { print $row or exit 1; next }
        next if $sparse eq "true" && ($tag eq "S" || $tag eq "s") && !-e $path && !-l $path;
        print $path, "\0" or exit 1;
      }
      exit 1 if $mode eq "cached" && !$seen;
      close(STDIN) or exit 1;
      close(STDOUT) or exit 1;
    ' "$sparse" "$mode"
  else
    while IFS= read -r -d '' record; do
      if [ "$mode" = cached ] && [ "$record" = trellis-stop-flags-cache-v1 ]; then
        [ "$seen" -eq 0 ] || return 1
        seen=1
        continue
      fi
      [ "$mode" != cached ] || [ "$seen" -eq 0 ] || return 1
      tag=${record:0:1}; path=${record:2}
      case "$record" in
        S\ *|s\ *|[abcdefghijklmnopqrstuvwxyz]\ *) ;;
        *) [ "$mode" != cached ] || return 1; continue ;;
      esac
      [ "$mode" != cached ] || [ -n "$path" ] || return 1
      if [ "$mode" = tagged ]; then
        printf '%s\0' "$record" || return 1
        continue
      fi
      case "$tag" in
        S|s) [ "$sparse" != true ] || [ -e "$path" ] || [ -L "$path" ] || continue ;;
      esac
      printf '%s\0' "$path" || return 1
    done
    if [ "$mode" = cached ]; then
      [ "$seen" -eq 1 ] && [ -z "$record" ] || return 1
    fi
  fi
}

# An old index's inode/size and high-resolution mtime/ctime let Stop recognize
# an unchanged index. Recent timestamps are never trusted (the same racy-time
# protection used by the content fingerprint cache).
_se_index_stamp() {
  local stamp
  case "${__se_stat_style:-auto}" in
    bsd) stamp=$(/usr/bin/stat -L -f '%d:%i:%z:%m:%c:%.9Fm:%.9Fc' "$1" 2>/dev/null) || return 1 ;;
    gnu) stamp=$(/usr/bin/stat -L -c '%d:%i:%s:%Y:%Z:%y:%z' "$1" 2>/dev/null) || return 1 ;;
    *) stamp=$(/usr/bin/stat -L -c '%d:%i:%s:%Y:%Z:%y:%z' "$1" 2>/dev/null) \
         || stamp=$(/usr/bin/stat -L -f '%d:%i:%z:%m:%c:%.9Fm:%.9Fc' "$1" 2>/dev/null) || return 1 ;;
  esac
  [[ "$stamp" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+: ]] || return 1
  printf '%s' "$stamp"
}

# _se_unmasked_index <dir> [known-top] — print a private temporary directory
# holding an index with visibility flags cleared and a NUL-delimited list of
# those paths, or nothing when none need inspection. The caller removes it.
# Missing sparse-checkout paths are intentionally left masked. Internal callers
# that just resolved the Git root can pass known-top to avoid resolving it twice.
_se_unmasked_index() (
  set -o pipefail
  local top path complete=0 sparse real tmp names result index_id after keytmp recordtmp
  # This function runs in a subshell. Bash 3.2 drops local variables before
  # its EXIT trap, so keep the cleanup path in subshell scope instead.
  __se_unmask_work=""
  local cached_top="" cached_real="" cached_id="" cached_seal="" seal="" actual="" marker="" trailing=""
  local stamp="" after_stamp="" cutoff=0
  local -a flagged=()
  if [ "${2:-}" = known-top ]; then top="$1"; else top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || exit 1; fi
  [ -n "$top" ] && cd "$top" || exit 1
  if [ -n "${__se_flag_cache:-}" ] && [ -d "$__se_flag_cache" ]; then
    # Cache candidate tags, not sparse-file existence. Recent or unstatable
    # indexes are hashed; an old stable index is identified by its metadata.
    # A normal worktree root has its index here; any explicit Git routing or
    # linked-worktree layout takes Git's authoritative resolver instead.
    if [ -d .git ] && [ -z "${GIT_INDEX_FILE+x}${GIT_DIR+x}${GIT_COMMON_DIR+x}${GIT_WORK_TREE+x}" ]; then
      real=.git/index
    else
      real=$(git rev-parse --git-path index 2>/dev/null) && [ -n "$real" ] || exit 1
    fi
    keytmp="$__se_flag_cache/key.$$"; recordtmp="$__se_flag_cache/records.$$"
    if [ -e "$__se_flag_cache/records" ] || [ -L "$__se_flag_cache/records" ]; then
      [ -f "$__se_flag_cache/records" ] && [ ! -L "$__se_flag_cache/records" ] \
        && [ -r "$__se_flag_cache/records" ] || exit 1
    fi
    if [ -f "$__se_flag_cache/key" ]; then
      { IFS= read -r -d '' cached_top && IFS= read -r -d '' cached_real && IFS= read -r -d '' cached_id \
        && IFS= read -r -d '' cached_seal; } < "$__se_flag_cache/key" || cached_id=""
    fi
    if [ "$cached_seal" != none ] && ! [[ "$cached_seal" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then cached_id=""; fi
    if [ -f "$real" ]; then
      stamp=$(_se_index_stamp "$real") || stamp=""
      case "${__se_cache_epoch:-}" in ''|*[!0-9]*) ;; *) cutoff=$((__se_cache_epoch - 2)) ;; esac
      if [[ "$stamp" =~ ^[0-9]+:[0-9]+:[0-9]+:([0-9]+):([0-9]+): ]] \
         && [ "${BASH_REMATCH[1]}" -lt "$cutoff" ] && [ "${BASH_REMATCH[2]}" -lt "$cutoff" ]; then
        index_id="stamp:$stamp"
      else
        index_id=$(git hash-object --no-filters -- "$real" 2>/dev/null) && [ -n "$index_id" ] || exit 1
        after_stamp=$(_se_index_stamp "$real") || after_stamp=""
        [ -z "$stamp" ] || [ "$stamp" = "$after_stamp" ] || exit 1
      fi
    elif [ ! -e "$real" ] && [ ! -L "$real" ]; then
      index_id=missing
    else
      exit 1
    fi
    if [ "$cached_top" != "$top" ] || [ "$cached_real" != "$real" ] || [ "$cached_id" != "$index_id" ] \
       || [ ! -f "$__se_flag_cache/records" ]; then
      # Cache the on-disk visibility flags, not Git's transient clearing of
      # present sparse paths. A later config-only change must not hide them.
      ( umask 077 && _se_hook_state_git -c core.sparseCheckout=false ls-files -v -z 2>/dev/null \
        | _se_flagged_candidates false tagged > "$recordtmp" ) || exit 1
      # An explicit terminal record distinguishes a valid empty scan from a
      # truncated or erased file. Seal nonempty candidate sets so removing or
      # replacing otherwise well-formed rows cannot look like a valid cache.
      if [ -s "$recordtmp" ]; then seal=flagged; else seal=none; fi
      ( umask 077 && printf 'trellis-stop-flags-cache-v1\0' >> "$recordtmp" ) || exit 1
      if [ "$seal" = flagged ]; then
        seal=$(git hash-object --no-filters -- "$recordtmp" 2>/dev/null) || exit 1
        [[ "$seal" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || exit 1
      fi
      case "$index_id" in
        stamp:*)
          after_stamp=$(_se_index_stamp "$real") || exit 1
          [ "$after_stamp" = "$stamp" ] || exit 1 ;;
        *)
          if [ -f "$real" ]; then
            after=$(git hash-object --no-filters -- "$real" 2>/dev/null) || exit 1
          elif [ ! -e "$real" ] && [ ! -L "$real" ]; then
            after=missing
          else
            exit 1
          fi
          [ "$after" = "$index_id" ] || exit 1 ;;
      esac
      ( umask 077 && printf '%s\0' "$top" "$real" "$index_id" "$seal" > "$keytmp" ) || exit 1
      mv -f "$recordtmp" "$__se_flag_cache/records" && mv -f "$keytmp" "$__se_flag_cache/key" || exit 1
      cached_seal="$seal"
    fi
    [ -f "$__se_flag_cache/records" ] && [ ! -L "$__se_flag_cache/records" ] \
      && [ -r "$__se_flag_cache/records" ] || exit 1
    if [ "$cached_seal" = none ]; then
      # Validate the singleton marker without starting Perl in the common
      # unflagged case; trailing complete or partial rows are errors.
      { IFS= read -r -d '' marker && [ "$marker" = trellis-stop-flags-cache-v1 ] \
        && ! IFS= read -r -d '' trailing && [ -z "$trailing" ]; } < "$__se_flag_cache/records" || exit 1
      exit 0
    fi
    actual=$(git hash-object --no-filters -- "$__se_flag_cache/records" 2>/dev/null) || exit 1
    [ "$actual" = "$cached_seal" ] || exit 1
    sparse=$(git config --bool core.sparseCheckout 2>/dev/null || true)
    while IFS= read -r -d '' path; do
      if [ -z "$path" ]; then complete=1; continue; fi
      flagged+=("$path")
    done < <(if _se_flagged_candidates "$sparse" cached < "$__se_flag_cache/records"; then printf '\0'; fi)
  else
    sparse=$(git config --bool core.sparseCheckout 2>/dev/null || true)
    while IFS= read -r -d '' path; do
      if [ -z "$path" ]; then complete=1; continue; fi
      flagged+=("$path")
    done < <(if _se_hook_state_git ls-files -v -z 2>/dev/null | _se_flagged_candidates "$sparse"; then printf '\0'; fi)
  fi
  [ "$complete" -eq 1 ] || exit 1
  [ "${#flagged[@]}" -gt 0 ] || exit 0
  [ -n "${real:-}" ] || real=$(git rev-parse --git-path index 2>/dev/null) || exit 1
  [ -f "$real" ] || exit 1
  __se_unmask_work=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/trellis-flags.XXXXXX") || exit 1
  trap '[ -z "$__se_unmask_work" ] || rm -rf "${__se_unmask_work:?}"' EXIT
  tmp="$__se_unmask_work/index"; names="$__se_unmask_work/paths"
  cp "$real" "$tmp" || exit 1
  printf '%s\0' "${flagged[@]}" > "$names" || exit 1
  # Reinsert the same mode, object ID and stage into the copied index. This
  # clears both flags AND cached stat data, forcing a content comparison even
  # for same-size edits inside Git's filesystem timestamp resolution.
  if ! GIT_INDEX_FILE="$tmp" git ls-files --stage -z 2>/dev/null \
    | /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -0e '
        use strict; binmode STDIN; binmode STDOUT;
        open(my $f, "<", shift) or exit 1; binmode $f;
        my %wanted; while (defined(my $p = <$f>)) { chomp $p; $wanted{$p}=1 }
        close($f) or exit 1;
        while (defined(my $row = <STDIN>)) {
          $row =~ /\A[0-7]{6} [0-9a-f]{40,64} [0-3]\t(.*)\0\z/s or exit 1;
          print $row if $wanted{$1};
        }
      ' "$names" | GIT_INDEX_FILE="$tmp" git -c core.fsmonitor=false update-index -z --index-info 2>/dev/null; then
    exit 1
  fi
  result="$__se_unmask_work"; __se_unmask_work=""
  printf '%s' "$result"
)

# Print only changed paths hidden by visibility flags. Git compares against the
# private index; the real index and its flags remain untouched.
_se_flagged_changed_files() (
  set -o pipefail
  local top
  # Like the allocator, keep cleanup state in this subshell, not a local that
  # Bash 3.2 can discard on an errexit-triggered EXIT trap.
  __se_flagged_work=""
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && cd "$top" || exit 1
  __se_flagged_work=$(_se_unmasked_index "$top" known-top) || exit 1
  [ -n "$__se_flagged_work" ] || exit 0
  trap 'rm -rf "${__se_flagged_work:?}"' EXIT
  GIT_INDEX_FILE="$__se_flagged_work/index" _se_hook_state_git -c core.fsmonitor=false diff --no-renames --name-only -z 2>/dev/null \
    | /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -0e '
        use strict; binmode STDIN; binmode STDOUT;
        open(my $f, "<", shift) or exit 1; binmode $f;
        my %wanted; while (defined(my $p = <$f>)) { chomp $p; $wanted{$p}=1 }
        close($f) or exit 1;
        while (defined(my $p = <STDIN>)) { chomp $p; print $p, "\0" if $wanted{$p} }
      ' "$__se_flagged_work/paths"
)

# A conservative line-oriented view for existing receipt/subtree consumers.
# Control-byte paths are encoded so they cannot forge rows or look like docs.
_se_flagged_changed_lines() (
  set -o pipefail
  _se_flagged_changed_files "$1" | while IFS= read -r -d '' path; do
    case "$path" in
      *$'\n'*|*$'\r'*|*$'\t'*) printf '.trellis-encoded-path-%s\n' "$(printf '%s' "$path" | od -An -tx1 | tr -d ' \n')" ;;
      *) printf '%s\n' "$path" ;;
    esac
  done
)

# The fingerprint's hashing half, run by perl so one process replaces awk,
# `git hash-object` and shasum. argv: <cache-file|""> <head> <git status argv>;
# stdin: the classified path records. It hashes the same byte stream the shell
# pipeline always hashed, so fingerprints are unchanged. With a cache file, a
# file whose lstat identity (device, inode, mode, size, mtime, ctime) matches
# its cached entry keeps its cached blob id and only the rest are hashed. An
# entry is cached only when its mtime and ctime are over two seconds older than
# the moment hashing began, so a later same-size write inside one timestamp
# tick can never reuse a stale id. The cache is read only when it is a regular
# file owned by this user with no group or other bits, and replaced atomically.
# shellcheck disable=SC2016  # perl source, expanded by perl
__se_fp_perl='use strict; use Fcntl; use Digest::SHA;
my ($cache, $head, @status) = @ARGV;
binmode STDIN; binmode STDOUT;
my $paths = do { local $/; <STDIN> };
$paths = "" unless defined $paths;
open(my $g, "-|", @status) or exit 1;
binmode $g;
my $st = do { local $/; <$g> };
close($g) or exit 1;
$st = "" unless defined $st;
my $hr = eval { require Time::HiRes; 1 };
my $t0 = time;
my @f = map { /^F\t(.*)$/ ? $1 : () } split /\n/, $paths;
my (%old, %id, %key, %fresh, @miss);
if (length $cache) {
  my @c = lstat $cache;
  if (@c && ($c[2] & 0170000) == 0100000 && $c[4] == $< && ($c[2] & 077) == 0 && open(my $in, "<", $cache)) {
    my $hdr = <$in>;
    if (defined $hdr && $hdr eq "trellis-fp-cache v1\n") {
      while (my $l = <$in>) {
        chomp $l;
        my ($k, $i, $p) = split /\t/, $l, 3;
        $old{$p} = [$k, $i] if defined $p && $i =~ /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
      }
    }
    close $in;
  }
}
for my $p (@f) {
  my @s = $hr ? Time::HiRes::lstat($p) : lstat($p);
  exit 1 unless @s && ($s[2] & 0170000) == 0100000;
  $key{$p} = sprintf "%d %d %o %d %.9f %.9f", @s[0, 1, 2, 7, 9, 10];
  $fresh{$p} = $s[9] < $t0 - 2 && $s[10] < $t0 - 2;
  if ($old{$p} && $old{$p}[0] eq $key{$p}) { $id{$p} = $old{$p}[1] } else { push @miss, $p }
}
while (my @chunk = splice @miss, 0, 256) {
  open(my $h, "-|", "git", "hash-object", "--no-filters", "--", @chunk) or exit 1;
  my @ids = <$h>;
  close($h) or exit 1;
  exit 1 unless @ids == @chunk;
  for my $n (0 .. $#chunk) {
    chomp(my $i = $ids[$n]);
    exit 1 unless $i =~ /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
    $id{$chunk[$n]} = $i;
  }
}
my $d = Digest::SHA->new(256);
$d->add("head\t$head\n", $st, "\n", $paths, map { "$id{$_}\n" } @f);
print $d->hexdigest, "\n";
if (length $cache) {
  my $tmp = "$cache.tmp.$$";
  if (sysopen(my $o, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
    print $o "trellis-fp-cache v1\n";
    print $o "$key{$_}\t$id{$_}\t$_\n" for grep { $fresh{$_} } @f;
    if (close $o) { rename($tmp, $cache) or unlink $tmp } else { unlink $tmp }
  }
}'

# _se_tree_fingerprint <dir> [cache-file]
#   - prints "<head|unborn> <sha256>" over HEAD, the full porcelain-v2 status
#     (HEAD and index object ids, modes, renames, untracked paths) and the
#     content of every non-ignored path that differs from the index or is
#     untracked. Any failed git call or uncoverable path → non-zero, never a
#     partial hash. Ignored files are out of scope, as for the dirty-tree check.
#   - With a cache file (beside the turn baseline), content that has not
#     changed since the last call is not re-read (see __se_fp_perl).
_se_tree_fingerprint() (
  set -o pipefail
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && cd "$top" || exit 1
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=unborn
  visible_index=$(_se_unmasked_index "$top" known-top) || exit 1
  if [ -n "$visible_index" ]; then
    export GIT_INDEX_FILE="$visible_index/index"
    trap 'rm -rf "${visible_index:?}"' EXIT
  fi
  paths=$( { _se_hook_state_git -c core.fileMode=true diff --ignore-submodules=none --no-ext-diff --name-only -z && _se_hook_state_git ls-files --others --exclude-standard -z; } \
    | _se_fp_classify) || exit 1
  sum=$(printf '%s\n' "$paths" | /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -e "$__se_fp_perl" "${2:-}" "$head" \
    git -c core.fileMode=true --no-optional-locks status --ignore-submodules=none --porcelain=v2 -z --untracked-files=all -- "${__se_hook_state_pathspec[@]}") || exit 1
  [ "${#sum}" -eq 64 ] || exit 1
  printf '%s %s\n' "$head" "$sum"
)

# C01 uses the same mkdir/rmdir lock primitive as UI-v3. The lock is shared
# across sessions because nonces.log is rewritten as a whole; generations and
# poison markers remain per session. A killed owner leaves the directory for
# doctor, never a guessed-stale removal. Only contended attempts sleep.
_se_state_lock_try() { ( umask 077 && mkdir "$1" ) 2>/dev/null; }
_se_turn_lock() {
  local dir="$1" attempt=0
  while ! _se_state_lock_try "$dir/.nonces.lock"; do
    [ "$attempt" -lt 4 ] || return 1
    attempt=$((attempt + 1))
    sleep 0.02
  done
}
_se_turn_unlock() { rmdir "$1/.nonces.lock" 2>/dev/null; }
# One immutable marker per failure: a publisher removes only the markers it
# observed under lock, so a newer failed prompt cannot be accidentally cleared.
_se_turn_poison() {
  ( umask 077 && mktemp -d "$1/.poison.$2.$$.XXXXXXXX" >/dev/null ) 2>/dev/null
}
_se_turn_is_poisoned() {
  local marker
  for marker in "$1/.poison.$2".*; do
    if [ -e "$marker" ] || [ -L "$marker" ]; then return 0; fi
  done
  return 1
}
_se_turn_clear_poison() {
  local marker
  for marker in "$@"; do
    [ -d "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || return 1
    rmdir "$marker" 2>/dev/null || return 1
  done
}
_se_turn_generation_read() {
  local file="$1/generation.$2" value info mode links size
  __se_generation_value=0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then printf 0; return 0; fi
  [ -f "$file" ] && [ ! -L "$file" ] && [ -O "$file" ] || return 1
  # Bash has no builtin for private mode or hard-link count. Keep one stat
  # rather than trusting a group/world-accessible or multiply linked file.
  info=$(/usr/bin/stat -c '%a %h %s' "$file" 2>/dev/null) \
    || info=$(/usr/bin/stat -f '%Lp %l %z' "$file" 2>/dev/null) || return 1
  [[ "$info" =~ ^([0-7]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)$ ]] || return 1
  mode=${BASH_REMATCH[1]}; links=${BASH_REMATCH[2]}; size=${BASH_REMATCH[3]}
  [ "$links" = 1 ] && [ "$((8#$mode & 077))" -eq 0 ] || return 1
  IFS= read -r value < "$file" || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#value}" -le 18 ] && [ "$size" -eq "$((${#value} + 1))" ] || return 1
  __se_generation_value="$value"
  printf '%s' "$value"
}
# Called only under the nonce lock. Publish the generation before state, so a
# killed writer can invalidate an intent but can never hide a publication.
_se_turn_generation_bump() {
  local dir="$1" id="$2" old next tmp __se_generation_value
  # Dynamic scope passes the validated value without an extra shell fork.
  _se_turn_generation_read "$dir" "$id" >/dev/null || return 1
  old="$__se_generation_value"
  [ "$old" != 999999999999999999 ] || return 1
  next=$((10#$old + 1))
  # The lock directory was freshly made under umask 077. Noclobber refuses an
  # existing or symlinked temp; never remove one that this call did not make.
  tmp="$dir/.nonces.lock/.generation.$$.tmp"
  ( umask 077; set -C
    exec 3> "$tmp" || exit 1
    if ! printf '%s\n' "$next" >&3; then
      exec 3>&-; /bin/rm -f "$tmp"; exit 1
    fi
    exec 3>&-
  ) 2>/dev/null || return 1
  if ! /bin/mv -f "$tmp" "$dir/generation.$id"; then
    /bin/rm -f "$tmp"; return 1
  fi
  printf '%s' "$next"
}
# _se_turn_nonce — prints 32 random hex digits, or fails.
_se_turn_nonce() {
  local n
  n=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$n" in *[!0-9a-f]*|"") return 1 ;; esac
  [ "${#n}" -eq 32 ] || return 1
  printf '%s' "$n"
}

# _se_turn_start_append <turn-start-file> <line>
#   - turn-start holds the current turn only: the first prompt after a passed
#     Stop's carry starts it afresh, so an earlier turn's lines never count.
#     decision-receipt reads it without nonces.log, which stop-verify consumes
#     at every Stop. A failed append removes the file, so the next Stop reads
#     no baseline and runs the gate.
_se_turn_start_append() {
  case "$(tail -n 1 "$1" 2>/dev/null)" in
    'trellis-turn-carry '*) rm -f "${1:?}" 2>/dev/null ;;
  esac
  ( umask 077 && printf '%s\n' "$2" >> "$1" ) 2>/dev/null || rm -f "${1:?}" 2>/dev/null
  chmod 600 "$1" 2>/dev/null
  return 0
}

# _se_turn_baseline_publish <dir> <claude|codex|pi> <session-id>
# Publish synchronously before UserPromptSubmit returns. An invalid session
# invalidates all earlier prompt lines for this harness, never another harness.
# The native Stage writes this same v2 format; keep these twins byte-identical.
# A nonzero result means a failure could not be recorded durably; the prompt
# wrapper must surface a non-blocking warning to the model.
_se_turn_baseline_publish() {
  local dir="$1" harness="$2" sid="$3" state key="" file tstart nonce="" fp="" id good=0 rc=0 unobservable=0 gen name marker
  local -a markers=()
  case "$harness" in claude|codex|pi) ;; *) return 1 ;; esac
  state=$(_se_turn_state_dir "$dir") || { _se_turn_confirm_non_git "$dir" && return 0; return 1; }
  [ -z "$sid" ] || key=$(_se_state_key "" "$sid") || key=""
  if [ -z "$key" ]; then
    [ -d "$state" ] || return 0
    for marker in "$state/.poison.$harness."*; do
      [ -e "$marker" ] || [ -L "$marker" ] || continue
      markers[${#markers[@]}]="$marker"
    done
    if _se_turn_lock "$state"; then
      for gen in "$state/generation.$harness".*; do
        [ -f "$gen" ] || continue
        name=${gen##*/}; id=${name#generation.}
        _se_turn_generation_bump "$state" "$id" >/dev/null || _se_turn_poison "$state" "$id" || rc=1
      done
      if rm -f "${state:?}/$harness".* "${state:?}/ui.$harness".* "${state:?}/turn-start.$harness".* 2>/dev/null; then
        _se_turn_clear_poison ${markers[@]+"${markers[@]}"} || rc=1
      else
        rc=1
      fi
      _se_turn_unlock "$state" || rc=1
    else
      for gen in "$state/generation.$harness".*; do
        [ -f "$gen" ] || continue
        name=${gen##*/}; _se_turn_poison "$state" "${name#generation.}" || true
      done
      rm -f "${state:?}/turn-start.$harness".* 2>/dev/null
      rc=1
    fi
    return "$rc"
  fi
  id="$harness.$key"; file="$state/$id"; tstart="$state/turn-start.$id"
  ( umask 077 && mkdir -p "$state" ) 2>/dev/null || return 1
  # Snapshot before waiting for the lock: a later failed prompt must survive
  # even when it poisons while this older publisher is waiting.
  for marker in "$state/.poison.$id".*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    markers[${#markers[@]}]="$marker"
  done
  if nonce=$(_se_turn_nonce) && fp=$(_se_tree_fingerprint "$dir" "$state/fp-cache"); then good=1; fi
  if ! _se_turn_lock "$state"; then
    _se_turn_start_append "$tstart" 'trellis-turn-baseline v2 unknown'
    _se_turn_poison "$state" "$id" || unobservable=1
    _se_ui_baseline_append "$state/ui.$id" "" "" || true
    return "$unobservable"
  fi
  _se_turn_generation_bump "$state" "$id" >/dev/null || rc=1
  if [ "$rc" = 0 ] && [ "${#markers[@]}" -gt 0 ]; then
    rm -f "$file" && _se_turn_nonce_take_locked "$state" "$id" >/dev/null || rc=1
  fi
  if [ "$rc" = 0 ] && [ "$good" = 1 ]; then
    ( umask 077 && printf '%s %s\n' "$id" "$nonce" >> "$state/nonces.log" \
      && printf 'trellis-turn-baseline v2 %s %s\n' "$nonce" "$fp" >> "$file" ) 2>/dev/null || rc=1
    [ "$rc" != 0 ] || _se_turn_clear_poison ${markers[@]+"${markers[@]}"} || rc=1
  elif [ "$rc" = 0 ]; then
    ( umask 077 && printf 'trellis-turn-baseline v2 unknown\n' >> "$file" ) 2>/dev/null || rc=1
  fi
  if [ "$rc" = 0 ] && [ "$good" = 1 ]; then
    _se_turn_start_append "$tstart" "trellis-turn-baseline v2 $nonce $fp"
  else
    _se_turn_start_append "$tstart" 'trellis-turn-baseline v2 unknown'
  fi
  [ "$rc" = 0 ] || _se_turn_poison "$state" "$id" || unobservable=1
  _se_turn_unlock "$state" || { _se_turn_poison "$state" "$id" || unobservable=1; rc=1; }
  if [ "$rc" = 0 ] && [ "$good" = 1 ]; then
    chmod 600 "$file" "$state/nonces.log" 2>/dev/null
    _se_ui_baseline_append "$state/ui.$id" "$nonce" "$fp" || true
  else
    _se_ui_baseline_append "$state/ui.$id" "" "" || true
  fi
  return "$unobservable"
}

# _se_turn_carry_write <state-dir> <harness>.<KEY> <dir> [stage] [expected-fingerprint]
#   - appends the current end state as a carry line (fresh nonce, logged
#     first) for the next turn. Any failure writes nothing usable, so the next
#     promptless turn reads unknown. An expected fingerprint binds a no-op
#     shortcut's carry to the state actually inspected, not a later edit.
_se_turn_carry_write() {
  local sdir="$1" id="$2" nonce fp rc=0
  nonce=$(_se_turn_nonce) || return 0
  fp=$(_se_tree_fingerprint "$3" "$sdir/fp-cache") || return 0
  [ -z "${5:-}" ] || [ "$fp" = "$5" ] || return 0
  ( umask 077 && mkdir -p "$sdir" ) 2>/dev/null || return 0
  # Deferred candidates are private scratch, not publication into the log.
  if [ "${4:-}" = stage ]; then
    ( umask 077 && printf '%s %s\n' "$id" "$nonce" >> "$sdir/nonces.log" \
      && printf 'trellis-turn-carry v2 %s %s\n' "$nonce" "$fp" >> "$sdir/$id" ) 2>/dev/null || return 0
    chmod 600 "$sdir/$id" "$sdir/nonces.log" 2>/dev/null
    return 0
  fi
  if ! _se_turn_lock "$sdir"; then
    rm -f "${sdir:?}/turn-start.$id" 2>/dev/null
    _se_turn_poison "$sdir" "$id" || true
    printf 'stop-verify: nonce state degraded; re-verification required; armed unknown turn requires a receipt; lock %s/.nonces.lock\n' "$sdir" >&2
    return 0
  fi
  if _se_turn_is_poisoned "$sdir" "$id" \
     || ! _se_turn_generation_bump "$sdir" "$id" >/dev/null; then rc=1; fi
  if [ "$rc" = 0 ]; then
    ( umask 077 && printf '%s %s\n' "$id" "$nonce" >> "$sdir/nonces.log" \
      && printf 'trellis-turn-carry v2 %s %s\n' "$nonce" "$fp" >> "$sdir/$id" ) 2>/dev/null || rc=1
  fi
  if [ "$rc" = 0 ]; then
    ( umask 077 && printf 'trellis-turn-carry v2 %s %s\n' "$nonce" "$fp" >> "$sdir/turn-start.$id" ) 2>/dev/null \
      || rm -f "${sdir:?}/turn-start.$id" 2>/dev/null
  else
    rm -f "${sdir:?}/turn-start.$id" 2>/dev/null
  fi
  [ "$rc" = 0 ] || _se_turn_poison "$sdir" "$id" || true
  _se_turn_unlock "$sdir" || { _se_turn_poison "$sdir" "$id" || true; rc=1; }
  [ "$rc" = 0 ] || printf 'stop-verify: nonce state degraded; re-verification required; armed unknown turn requires a receipt; lock %s/.nonces.lock\n' "$sdir" >&2
  chmod 600 "$sdir/$id" "$sdir/turn-start.$id" "$sdir/nonces.log" 2>/dev/null
  return 0
}

# _se_turn_baseline_select <baseline-lines>
#   - prints the lines in force: the prompt lines when there are any (they take
#     precedence), else the carry lines.
_se_turn_baseline_select() {
  local rest="$1"$'\n' line selected=''
  while [ -n "$rest" ]; do
    line=${rest%%$'\n'*}
    rest=${rest#*$'\n'}
    case "$line" in 'trellis-turn-baseline '*) selected="$selected$line"$'\n' ;; esac
  done
  if [ -n "$selected" ]; then
    printf '%s' "$selected"
  else
    printf '%s\n' "$1"
  fi
}

# _se_turn_baseline_state <baseline-lines> <current-fingerprint> <logged-nonces>
#   - prints same | changed | unknown. Empty input, any malformed line (incl.
#     the writer's "unknown" poison line), a nonce missing from the hook's log,
#     or an empty fingerprint → unknown.
_se_turn_baseline_state() {
  local lines="$1" now="$2" nonces="$3" n
  [ -n "$lines" ] && [ -n "$now" ] && [ -n "$nonces" ] || { echo unknown; return; }
  if printf '%s\n' "$lines" \
       | grep -Evq '^trellis-turn-(baseline|carry) v2 [0-9a-f]{32} (unborn|[0-9a-f]{40}|[0-9a-f]{64}) [0-9a-f]{64}$'; then
    echo unknown
    return
  fi
  for n in $(printf '%s\n' "$lines" | awk '{ print $3 }'); do
    case $'\n'"$nonces"$'\n' in *$'\n'"$n"$'\n'*) ;; *) echo unknown; return ;; esac
  done
  if _se_turn_baseline_select "$lines" | awk '{ print $4, $5 }' | grep -vqxF "$now"; then
    echo changed
  else
    echo same
  fi
}

# UI verification keeps its own nonce-validated prompt HEADs. Bound this copy
# even when the UI hook is never registered: keep at most 64 entries, each at
# most 24 hours old, oldest evicted first. Any eviction or invalid old state
# leaves a poison marker, so the retained suffix is never guessed to represent
# the entire turn. The marker persists until a non-blocking UI verdict.
_se_ui_baseline_append() {
  local file="$1" nonce="${2:-}" fp="${3:-}" now tmp ntmp lock ambiguous
  local limit=64 max_age=86400
  lock="$file.lock"; ambiguous="$file.ambiguous"
  # Rewrites must not lose a concurrent prompt. A contending or interrupted
  # writer leaves a separate poison marker, which no writer may clear.
  if ! _se_state_lock_try "$lock"; then
    if ! ( umask 077; set -C; : > "$ambiguous" ) 2>/dev/null \
       && [ ! -e "$ambiguous" ] && [ ! -L "$ambiguous" ]; then
      rm -f "${file:?}" "${file:?}.nonces" 2>/dev/null
    fi
    return 1
  fi
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in ''|*[!0-9]*)
    rm -f "${file:?}" "${file:?}.nonces" 2>/dev/null
    rmdir "$lock" 2>/dev/null || true
    return 1 ;;
  esac
  tmp="$file.$$"; ntmp="$file.nonces.$$"
  if ! ( umask 077
    set -o pipefail
    {
      if [ -f "$file" ] && [ ! -L "$file" ]; then
        cat "$file" || exit 1
      elif [ -e "$file" ] || [ -L "$file" ]; then
        printf 'trellis-turn-baseline v3 unknown\n'
      fi
      if [ -n "$nonce" ] && [ -n "$fp" ]; then
        printf 'trellis-turn-baseline v3 %s %s %s\n' "$nonce" "$now" "$fp"
      else
        printf 'trellis-turn-baseline v3 unknown\n'
      fi
    } | awk -v now="$now" -v age="$max_age" -v limit="$limit" '
      NF != 6 || $1 != "trellis-turn-baseline" || $2 != "v3" ||
        length($3) != 32 || $3 ~ /[^0-9a-f]/ || $4 !~ /^[0-9]+$/ ||
        ($5 != "unborn" && (length($5) != 40 && length($5) != 64 || $5 ~ /[^0-9a-f]/)) ||
        length($6) != 64 || $6 ~ /[^0-9a-f]/ { bad=1; next }
      $4 + 0 > now || now - ($4 + 0) > age { bad=1; next }
      {
        # Sort by timestamp, preserving arrival order when timestamps tie.
        i=++n
        while (i > 1 && times[i-1] > $4 + 0) {
          rows[i]=rows[i-1]; times[i]=times[i-1]; i--
        }
        rows[i]=$0; times[i]=$4 + 0
      }
      END {
        start=1
        if (n > limit) { start=n-limit+1; bad=1 }
        if (bad) print "trellis-turn-baseline v3 unknown"
        for (i=start; i<=n; i++) print rows[i]
      }
    ' > "$tmp" || exit 1
    if [ -f "$file.nonces" ] && [ ! -L "$file.nonces" ]; then
      awk -v new="$nonce" 'NR == FNR { if (NF == 6) keep[$3]=1; next } ($0 in keep) && $0 != new && !seen[$0]++ { print }' "$tmp" "$file.nonces" > "$ntmp" || exit 1
    else
      : > "$ntmp" || exit 1
    fi
    if [ -n "$nonce" ] && [ -n "$fp" ]; then printf '%s\n' "$nonce" >> "$ntmp" || exit 1; fi
    chmod 600 "$tmp" "$ntmp" && mv -f "$tmp" "$file" && mv -f "$ntmp" "$file.nonces"
  ) 2>/dev/null; then
    rm -f "${tmp:?}" "${ntmp:?}" "${file:?}" "${file:?}.nonces" 2>/dev/null
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi
  rmdir "$lock" 2>/dev/null || return 1
}

# _se_ui_baseline_load <file> sets UI_TURN_STATUS=known|unknown and, when
# valid and fresh, UI_TURN_HEADS to the prompt HEADs. Old v2 state, eviction,
# stale timestamps, clock reversal, or corrupt state stays unknown.
# shellcheck disable=SC2034 # UI_TURN_* are outputs consumed by the wrappers.
_se_ui_baseline_load() {
  local file="$1" lines nonces state zeros now
  local limit=64 max_age=86400
  UI_TURN_STATUS=unknown UI_TURN_HEADS=""
  command -v awk >/dev/null 2>&1 && command -v grep >/dev/null 2>&1 && command -v sort >/dev/null 2>&1 || return 0
  [ ! -e "$file.ambiguous" ] && [ ! -L "$file.ambiguous" ] && [ ! -d "$file.lock" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] && [ -f "$file.nonces" ] && [ ! -L "$file.nonces" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  lines=$(cat "$file" 2>/dev/null) && nonces=$(cat "$file.nonces" 2>/dev/null) || return 0
  [ ! -e "$file.ambiguous" ] && [ ! -L "$file.ambiguous" ] && [ ! -d "$file.lock" ] || return 0
  [ -n "$lines" ] || return 0
  if printf '%s\n' "$lines" | grep -Evq '^trellis-turn-baseline v3 [0-9a-f]{32} [0-9]+ (unborn|[0-9a-f]{40}|[0-9a-f]{64}) [0-9a-f]{64}$'; then return 0; fi
  printf '%s\n' "$lines" | awk -v now="$now" -v age="$max_age" -v limit="$limit" '
    $4 + 0 > now || now - ($4 + 0) > age { bad=1 }
    END { exit (bad || NR > limit) }
  ' || return 0
  lines=$(printf '%s\n' "$lines" | awk '{print $1, "v2", $3, $5, $6}') || return 0
  zeros=$(printf '%064d' 0)
  state=$(_se_turn_baseline_state "$lines" "unborn $zeros" "$nonces") || return 0
  case "$state" in same|changed) ;; *) return 0 ;; esac
  UI_TURN_HEADS=$(set -o pipefail; _se_turn_baseline_select "$lines" | awk '{print $4}' | sort -u) || return 0
  [ -n "$UI_TURN_HEADS" ] || return 0
  UI_TURN_STATUS=known
}

# _se_turn_nonce_take_locked <state-dir> <harness>.<KEY>
#   - under the nonce lock, prints the nonces for that baseline and removes them from the log
#     (the baseline is single use). A failed rewrite leaves stale entries,
#     which only ever match the baseline file that is deleted alongside.
_se_turn_nonce_take_locked() {
  local log="$1/nonces.log" tmp
  [ -f "$log" ] || return 0
  awk -v k="$2" '$1 == k { print $2 }' "$log" 2>/dev/null || return 1
  tmp="$log.$$"
  if ( umask 077 && awk -v k="$2" '$1 != k' "$log" > "$tmp" ) 2>/dev/null \
     && mv -f "$tmp" "$log" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
# Atomically capture and consume one baseline plus its nonce set. Outputs are
# shell globals because the caller needs both exact bytes and the generation.
_se_turn_consume() {
  local dir="$1" id="$2" file="$1/$2" rc=0
  __se_consumed=0 __se_baseline="" __se_nonces="" __se_generation=""
  ( umask 077 && mkdir -p "$dir" ) 2>/dev/null || return 1
  if ! _se_turn_lock "$dir"; then _se_turn_poison "$dir" "$id" || true; return 1; fi
  if _se_turn_is_poisoned "$dir" "$id"; then
    rc=1
  elif ! __se_generation=$(_se_turn_generation_bump "$dir" "$id"); then
    _se_turn_poison "$dir" "$id" || true; rc=1
  elif [ -f "$file" ]; then
    __se_consumed=1
    __se_baseline=$(cat "$file" 2>/dev/null) || __se_baseline=""
    rm -f "$file" || __se_baseline=""
    __se_nonces=$(_se_turn_nonce_take_locked "$dir" "$id") || { _se_turn_poison "$dir" "$id" || true; rc=1; }
  fi
  _se_turn_unlock "$dir" || { _se_turn_poison "$dir" "$id" || true; rc=1; }
  return "$rc"
}

# An unarmed Stop without a baseline still binds the existing session
# generation. If a prompt appeared before this lock, consume it normally.
_se_turn_observe_unarmed() {
  local dir="$1" id="$2" rc=0
  if ! _se_turn_lock "$dir"; then _se_turn_poison "$dir" "$id" || true; return 1; fi
  if [ -e "$dir/$id" ] || [ -L "$dir/$id" ]; then
    _se_turn_unlock "$dir" || { _se_turn_poison "$dir" "$id" || true; return 1; }
    _se_turn_consume "$dir" "$id"
    return $?
  fi
  if _se_turn_is_poisoned "$dir" "$id"; then
    rc=1
  elif ! __se_generation=$(_se_turn_generation_read "$dir" "$id"); then
    _se_turn_poison "$dir" "$id" || true; rc=1
  fi
  _se_turn_unlock "$dir" || { _se_turn_poison "$dir" "$id" || true; rc=1; }
  return "$rc"
}

# A stop_hook_active reentry is not a fresh verification, but a baseline it
# sees must still be single-use. Leave other sessions and the nested-review
# early guard alone; a failed lock records poison and is visible on stderr.
_se_turn_discard_reentrant() {
  local project="$1" harness="$2" input="$3" sid key state id
  sid=$(printf '%s' "$input" | jq -er 'if type == "object" and (.session_id | type == "string") then .session_id else empty end' 2>/dev/null) || return 0
  [ -n "$sid" ] || return 0
  key=$(_se_state_key "" "$sid") || return 0
  state=$(_se_turn_state_dir "$project") || return 0
  id="$harness.$key"
  [ -e "$state/$id" ] || [ -L "$state/$id" ] || return 0
  if ! _se_turn_consume "$state" "$id"; then
    printf 'stop-verify: nonce state degraded; re-verification required; armed unknown turn requires a receipt; lock %s/.nonces.lock\n' "$state" >&2
    return 1
  fi
}

# _se_turn_range_files <dir> <current-head> <baseline-lines>
#   - prints the paths changed between each entry HEAD in force and the current
#     HEAD (a turn that committed). Fails when any range cannot be read.
_se_turn_range_files() {
  local dir="$1" now="$2" h from
  for h in $(_se_turn_baseline_select "$3" | awk '{ print $4 }' | sort -u); do
    [ "$h" = "$now" ] && continue
    [ "$now" != unborn ] || return 1
    if [ "$h" = unborn ]; then
      from=$(git -C "$dir" hash-object -t tree /dev/null) || return 1
    else
      from="$h"
    fi
    git -C "$dir" diff --no-ext-diff --no-renames --name-only "$from" "$now" || return 1
  done
}

# --- Stop check reuse (spec 072 U8) -------------------------------------------
# stop-verify skips its typecheck/lint/test run when a pass receipt's key
# matches: the tree fingerprint plus every planned command, the identity of
# each tool, install state, exported environment, project policy and the hook
# files. A receipt is written only after every check exits 0 on a tree that did
# not change while they ran, so a failure is never reused. Receipts live in
# <TRELLIS_HOME|~/.trellis>/state/stop-receipts/ (dir 0700, files 0600) and are
# honoured only from a regular single-link file this user owns with no group or
# other bits, in a directory with the same properties, on an exact key match.
# Anything else is a miss and the checks run. Same-user forgery is the accepted
# residual (hooks.md § stop-verify): that user can already edit the hook, and
# the merge gate never reads a receipt.

# _se_stat_lines <l:path|s:path>...
#   - prints "<arg>\t<path> <dev> <ino> <mode> <uid> <nlink> <size> <mtime>
#     <ctime>" per argument, or "<arg>\t-" when it cannot be stat'ed. "l:" uses
#     lstat; "s:" follows symlinks and prints the resolved path. Times keep
#     sub-second digits when Time::HiRes loads.
_se_stat_lines() {
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MCwd=abs_path -e '
    my $hr = eval { require Time::HiRes; 1 };
    for my $a (@ARGV) {
      my ($m, $p) = $a =~ /^([ls]):(.*)$/s;
      my @s = !defined $m ? () : $hr ? ($m eq "l" ? Time::HiRes::lstat($p) : Time::HiRes::stat($p))
                                     : ($m eq "l" ? lstat($p) : stat($p));
      if (!@s) { print "$a\t-\n"; next }
      my $r = $m eq "s" ? (abs_path($p) // "?") : $p;
      printf "%s\t%s %d %d %o %d %d %d %.9f %.9f\n", $a, $r, @s[0, 1, 2, 4, 3, 7, 9, 10];
    }' "$@"
}

# _se_find_eslint_config <file> — find the nearest applicable config between
# the touched file and its worktree root. Return its directory, an absolute
# target and the nearest hoisted eslint executable via SE_ESLINT_* globals.
# Never walk outside the worktree (or project directory outside Git).
# shellcheck disable=SC2034 # SE_ESLINT_* are outputs consumed by hook callers.
_se_find_eslint_config() {
  local file="$1" dir root bin_dir parent
  SE_ESLINT_DIR="" SE_ESLINT_BIN="" SE_ESLINT_FILE=""
  case "$file" in /*) ;; *) file="$PWD/$file" ;; esac
  dir=$(CDPATH='' cd -P -- "$(dirname -- "$file")" 2>/dev/null && pwd -P) || return 1
  SE_ESLINT_FILE="$dir/$(basename -- "$file")"
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || root=$(_se_project_dir)
  root=$(CDPATH='' cd -P -- "$root" 2>/dev/null && pwd -P) || return 1
  if [ "$root" != / ]; then
    case "$dir" in "$root"|"$root/"*) ;; *) return 1 ;; esac
  fi
  while :; do
    if [ -f "$dir/.eslintrc" ] || [ -f "$dir/.eslintrc.js" ] || [ -f "$dir/.eslintrc.cjs" ] \
       || [ -f "$dir/.eslintrc.json" ] || [ -f "$dir/.eslintrc.yml" ] || [ -f "$dir/.eslintrc.yaml" ] \
       || [ -f "$dir/eslint.config.js" ] || [ -f "$dir/eslint.config.mjs" ] || [ -f "$dir/eslint.config.cjs" ] \
       || [ -f "$dir/eslint.config.ts" ] || [ -f "$dir/eslint.config.mts" ] || [ -f "$dir/eslint.config.cts" ]; then
      SE_ESLINT_DIR="$dir"
      break
    fi
    [ "$dir" != "$root" ] && [ "$dir" != / ] || return 1
    parent=${dir%/*}; dir=${parent:-/}
  done
  bin_dir="$SE_ESLINT_DIR"
  while :; do
    if [ -f "$bin_dir/node_modules/.bin/eslint" ] && [ -x "$bin_dir/node_modules/.bin/eslint" ]; then
      SE_ESLINT_BIN="$bin_dir/node_modules/.bin/eslint"
      break
    fi
    [ "$bin_dir" != "$root" ] && [ "$bin_dir" != / ] || break
    parent=${bin_dir%/*}; bin_dir=${parent:-/}
  done
  return 0
}

# _se_node_bin <tool> <dir>
#   - prints <ancestor>/node_modules/.bin/<tool> for the nearest ancestor of
#     <dir>, up to its worktree root, holding an executable one: the copy
#     `npx --no-install <tool>` would run. Fails when there is none inside the
#     worktree, or when its path holds whitespace (argv-form checks split on
#     it); the caller then keeps the npx form.
_se_node_bin() {
  local top dir
  top=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] \
    && top=$(CDPATH='' cd -P "$top" 2>/dev/null && pwd -P) \
    && dir=$(CDPATH='' cd -P "$2" 2>/dev/null && pwd -P) || return 1
  while :; do
    if [ -x "$dir/node_modules/.bin/$1" ] && [ ! -d "$dir/node_modules/.bin/$1" ]; then
      case "$dir" in *[[:space:]]*) return 1 ;; esac
      printf '%s' "$dir/node_modules/.bin/$1"
      return 0
    fi
    [ "$dir" != "$top" ] && [ "${dir#"$top"/}" != "$dir" ] || return 1
    dir=${dir%/*}
  done
}

# _se_stop_receipt_file <dir> <harness>
#   - prints <home>/state/stop-receipts/<worktree key>.<harness>, beside the
#     turn baseline. Fails as _se_turn_state_dir does.
_se_stop_receipt_file() {
  local sdir
  sdir=$(_se_turn_state_dir "$1") || return 1
  printf '%s/stop-receipts/%s.%s' "${sdir%/turn-baseline/*}" "${sdir##*/}" "$2"
}

# _se_stop_receipt_match <file> <key>
#   - succeeds only when <file> passes the checks above and its first line is
#     the pass line for <key>.
_se_stop_receipt_match() {
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MFcntl -e '
    my ($f, $k) = @ARGV;
    (my $d = $f) =~ s{/[^/]*$}{};
    my @d = lstat $d;
    exit 1 unless @d && ($d[2] & 0170000) == 0040000 && $d[4] == $< && ($d[2] & 077) == 0;
    sysopen(my $h, $f, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @s = stat $h;
    exit 1 unless @s && ($s[2] & 0170000) == 0100000 && $s[4] == $< && ($s[2] & 077) == 0 && $s[3] == 1;
    my $l = <$h>;
    exit(defined $l && $l eq "trellis-stop-pass v1 $k\n" ? 0 : 1);' "$1" "$2"
}

# _se_stop_receipt_write <file> <key> <body>
#   - publishes the pass receipt atomically. Creates its directory 0700 but
#     never repairs an existing one; a receipt in a directory that fails the
#     read checks is simply never honoured. Best effort: a failed write only
#     costs the next Stop a full run.
_se_stop_receipt_write() {
  local dir="${1%/*}" tmp
  ( umask 077 && mkdir -p "$dir" ) 2>/dev/null || return 0
  tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || return 0
  if printf 'trellis-stop-pass v1 %s\n%s\n' "$2" "$3" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 0
}

# _se_kill_tree <pid>...
#   - sends TERM to each pid and all its descendants. Each layer is stopped
#     before the table is read again, so a check that forks between the read
#     and the signal is still found; the whole tree is then sent TERM and
#     CONT. Records the signalled pids and their start times for
#     _se_kill_wait. Fails, signalling nothing, when the table is unreadable.
__SE_KILL_VICTIMS=""; __SE_KILL_STARTS=""
_se_kill_tree() {
  local table new victims="" round=0
  __SE_KILL_VICTIMS=""; __SE_KILL_STARTS=""
  while [ "$round" -lt 16 ]; do
    round=$((round + 1))
    table=$(ps -A -o pid= -o ppid= 2>/dev/null) || {
      [ -n "$victims" ] && break
      return 1
    }
    new=$(printf '%s\n' "$table" | awk -v roots="$* $victims" -v known=" $victims " '
      { kids[$2] = kids[$2] " " $1 }
      END {
        n = split(roots, q, " ")
        for (i = 1; i <= n; i++) {
          if (q[i] in seen) continue
          seen[q[i]] = 1
          if (index(known, " " q[i] " ") == 0) print q[i]
          m = split(kids[q[i]], c, " ")
          for (j = 1; j <= m; j++) q[++n] = c[j]
        }
      }')
    [ -n "$new" ] || break
    # shellcheck disable=SC2086  # one pid per word
    kill -STOP $new 2>/dev/null
    victims="$victims $(printf '%s ' $new)"
  done
  __SE_KILL_STARTS=$(_se_kill_identities "$victims")
  # shellcheck disable=SC2086  # one pid per word
  kill -TERM $victims 2>/dev/null
  # shellcheck disable=SC2086
  kill -CONT $victims 2>/dev/null
  __SE_KILL_VICTIMS=$victims
  return 0
}

# _se_kill_identities <pid>... : "pid start-time" per live pid, whitespace
# normalized (ps pads pids to the widest in each call).
_se_kill_identities() {
  local list
  # shellcheck disable=SC2048,SC2086  # pids split on whitespace by design
  list=$(printf '%s\n' $* | awk 'NF { printf "%s%s", sep, $1; sep = "," }')
  [ -n "$list" ] || return 0
  ps -o pid= -o lstart= -p "$list" 2>/dev/null | awk 'NF { $1 = $1; print }'
  return 0
}

# _se_kill_wait [grace-seconds]
#   - after _se_kill_tree, waits until none of the processes it signalled is
#     still alive (same pid and start time), at most <grace> seconds (default
#     5), then sends KILL to any survivor and waits up to one more second.
#     Returns 1 when a signalled process still survives.
_se_kill_survivors() {
  local now
  now=$(_se_kill_identities "$(printf '%s\n' "$__SE_KILL_STARTS" | awk '{ print $1 }')")
  { printf '%s\n' "$now" | sed 's/^/N /'; printf '%s\n' "$__SE_KILL_STARTS" | sed 's/^/S /'; } | awk '
    { tag = $1; sub(/^[NS] /, "") }
    tag == "N" && NF { live[$0] = 1; next }
    tag == "S" && NF && ($0 in live) { printf "%s ", $1 }'
}
_se_kill_wait() {
  local grace="${1:-5}" deadline alive
  [ -n "$__SE_KILL_STARTS" ] || return 0
  deadline=$((SECONDS + grace))
  while :; do
    alive=$(_se_kill_survivors)
    [ -n "$alive" ] || return 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.05
  done
  # shellcheck disable=SC2086  # one pid per word
  kill -KILL $alive 2>/dev/null
  deadline=$((SECONDS + 1))
  while :; do
    alive=$(_se_kill_survivors)
    [ -n "$alive" ] || return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

# _se_stop_fast_config <dir> [uid]
#   - prints projects.<canonical root>.stop_checks.fast from the machine config
#     <TRELLIS_HOME|~/.trellis>/config.json: a one-line string of 1–1024
#     printable characters naming a faster suite that replaces the Stop test
#     step. The key is the physical path of <dir>'s main checkout, so every
#     linked worktree of a project shares one entry. Nothing in the checkout
#     can set it: a repo-side value is writable by any same-user agent.
#   - honoured only when config.json is a regular file owned by the effective
#     uid (perl $>, not the inheritable $EUID) with mode 0600 or stricter, in
#     a directory with no group or other write bit. [uid] replaces $> for
#     tests only; production passes one argument, so perl supplies $>.
#   - prints nothing (status 0) when there is no config or no value for this
#     project; status 1 when the config cannot be read or the value is
#     malformed; status 2 when a value is set but the file fails the checks
#     above. Callers run the detected suite on any non-zero status.
_se_stop_fast_config() {
  local cfg out root want
  if [ -n "${TRELLIS_HOME:-}" ]; then
    cfg="$TRELLIS_HOME/config.json"
  elif [ -n "${HOME:-}" ]; then
    cfg="$HOME/.trellis/config.json"
  else
    return 0
  fi
  [ -e "$cfg" ] || [ -L "$cfg" ] || return 0
  # One open: the trust verdict and the bytes parsed come from the same file.
  # Prints "trusted" or "refused", then the content; nothing when the content
  # never mentions stop_checks, so most Stops skip jq and git entirely.
  out=$(perl -MFcntl -e '
    my ($f, $uid) = (@ARGV, $>);
    my @l = lstat $f or exit 1;
    sysopen(my $h, $f, O_RDONLY | O_NONBLOCK) or exit 1;
    my @s = stat $h;
    exit 1 unless @s && ($s[2] & 0170000) == 0100000;
    local $/;
    my $c = <$h> // "";
    exit 0 if index($c, "stop_checks") < 0;
    (my $d = $f) =~ s{/[^/]*$}{};
    my @d = stat $d;
    my $ok = ($l[2] & 0170000) == 0100000 && $l[0] == $s[0] && $l[1] == $s[1]
      && $s[4] == $uid && ($s[2] & 07177) == 0
      && @d && ($d[2] & 022) == 0;
    print $ok ? "trusted\n" : "refused\n", $c;' "$cfg" ${2:+"$2"} 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  root=$(_se_repo_root "$1")
  root=$(CDPATH='' cd -P "$root" 2>/dev/null && pwd -P) || return 1
  want=$(printf '%s' "${out#*$'\n'}" | jq -er --arg r "$root" '
    def safe: type == "string" and length >= 1 and length <= 1024
      and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def obj_or_null: type == "object" or type == "null";
    if (.projects | obj_or_null) and (.projects[$r] | obj_or_null)
       and (.projects[$r].stop_checks | obj_or_null)
       and ((.projects[$r].stop_checks.fast == null) or (.projects[$r].stop_checks.fast | safe))
    then .projects[$r].stop_checks.fast // ""
    else error("malformed stop_checks") end' 2>/dev/null) || return 1
  [ -n "$want" ] || return 0
  [ "${out%%$'\n'*}" = trusted ] || return 2
  printf '%s' "$want"
}

# _se_ignored_digest <dir>
#   - prints a sha256 over every git-ignored and untracked input of <dir>'s
#     worktree and every tracked symlink, so a link that leaves the worktree
#     is caught wherever it sits.
#     `git status --ignored=matching` lists ignored files and the top of each
#     ignored directory (not descended, so it stays cheap); each is then walked
#     here, symlinks not followed, and every entry's lstat identity (device,
#     inode, mode, size, mtime, ctime) is hashed, so an in-place edit at any
#     depth of node_modules, .venv or build output changes the digest.
#   - Nothing is skipped by name: caches (__pycache__, .mypy_cache,
#     .ruff_cache) are inputs like any other entry, so a run that rewrites
#     them earns no receipt until they settle. .pytest_cache, which pytest
#     rewrites with the same bytes on every run, is bound by content.
#     vitest's results cache (.vite/vitest/<hash>/results.json), rewritten
#     with new durations on every run, is bound by its version, sorted file
#     list and each file's failed flag, written as canonical JSON so no file
#     name can pass for a record separator: durations only order files. A
#     file that does not parse to exactly that shape (a string version, each
#     name a string holding : or /, as vitest writes them) refuses reuse.
#   - A symlink is bound by its target text and the physical path its whole
#     chain resolves to (realpath, never a lexical reading of the text). That
#     path must be inside the worktree (outside .git/, so the fingerprint or
#     this walk covers it), inside one Trellis release payload
#     (<TRELLIS_HOME|~/.trellis>/releases/<version>/payload, where
#     .trellis/runtime points; the hooks themselves run from there), which
#     also binds that release's version and the sha256 of its release.json,
#     or a native Mach-O/ELF executable such as a .venv's python, whose
#     identity is then bound too. Anything else under TRELLIS_HOME, another
#     part of a release, a release without a release.json, or hook state the
#     fingerprint leaves out (__se_hook_state_pathspec) is refused.
#   - fails, so the caller refuses reuse, when git fails, an entry cannot be
#     read, a path or link holds a tab or newline, a symlink dangles or
#     resolves anywhere else, or the walk passes 300000 entries: an
#     incomplete walk never stands in for a complete one.
_se_ignored_digest() (
  set -o pipefail
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] \
    && top=$(CDPATH='' cd -P "$top" 2>/dev/null && pwd -P) && cd "$top" || exit 1
  releases="${TRELLIS_HOME:-${HOME:-/nonexistent}/.trellis}/releases"
  releases=$(CDPATH='' cd -P "$releases" 2>/dev/null && pwd -P) || releases=/nonexistent
  { git --no-optional-locks status --ignore-submodules=none --porcelain=v2 -z --ignored=matching --untracked-files=normal \
      && printf 'LS\0' && git --no-optional-locks ls-files -s -z; } 2>/dev/null \
    | /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MDigest::SHA -MFcntl=:mode -MCwd=abs_path -MJSON::PP -MB -e '
        my ($top, $rel, @state) = @ARGV;
        my ($max, $n) = (300000, 0);
        sub tree { my $a = "$_[0]/"; index($a, "$top/") == 0 && index($a, "$top/.git/") != 0 }
        # The hook state the fingerprint leaves out (:(exclude,top[,glob])x).
        # A literal path covers what lies beneath it, as in git; a glob
        # matches one whole path, and a directory it matches refuses reuse
        # (what git would leave out beneath it is not modelled). A symlink
        # among hook state refuses too: hooks write plain files there.
        my (@skip, @glob);
        for (@state) {
          next unless m{^:\(exclude,top(,glob)?\)(.+)$};
          my ($g, $x) = ($1, $2);
          if ($g) { push @glob, "^" . join("", map { $_ eq "*" ? "[^/]*" : quotemeta } split /(\*)/, $x) . "\$" }
          else { push @skip, "^" . quotemeta($x) . "(?:/|\$)" }
        }
        sub hookstate {
          my $r = length($_[0]) > length($top) ? substr($_[0], length($top) + 1) : "";
          for (@glob) { next unless $r =~ $_; exit 3 if -d $_[0] || -l $_[0]; return 1 }
          return 0 unless grep { $r =~ $_ } @skip;
          exit 3 if -l $_[0];
          return 1;
        }
        my %relid;
        sub release {
          my ($v) = "$_[0]/" =~ m{^\Q$rel\E/([^/]+)/payload/} or return undef;
          return $relid{$v} //= do {
            my $j = "$rel/$v/release.json";
            my @j = lstat $j;
            my $fh;
            (@j && S_ISREG($j[2]) && open($fh, "<", $j))
              ? do { binmode $fh; "$v " . Digest::SHA->new(256)->addfile($fh)->hexdigest } : "";
          };
        }
        sub native {
          open(my $fh, "<", $_[0]) or return 0;
          binmode $fh;
          my $m = "";
          read($fh, $m, 4);
          return $m =~ /^(\x7fELF|\xfe\xed\xfa[\xce\xcf]|[\xce\xcf]\xfa\xed\xfe|\xca\xfe\xba[\xbe\xbf])$/;
        }
        # A JSON string, never a number that reads the same.
        sub str { defined $_[0] && !ref $_[0]
          && (B::svref_2object(\$_[0])->FLAGS & (B::SVp_POK | B::SVp_IOK | B::SVp_NOK)) == B::SVp_POK }
        my $hr = eval { require Time::HiRes; 1 };
        my $d = Digest::SHA->new(256);
        sub walk {
          # $nodir: an untracked walk, where a directory comes and goes with
          # the hook state inside it; only its entries are bound.
          my ($p, $content, $nodir) = @_;
          my ($base) = $p =~ m{([^/]+)$};
          $content ||= $base eq ".pytest_cache";
          exit 3 if ++$n > $max || $p =~ /[\t\n]/;
          # Hook state is written by the hooks themselves, never an input.
          return if hookstate("$top/$p");
          my @s = $hr ? Time::HiRes::lstat($p) : lstat($p);
          exit 3 unless @s;
          if (S_ISLNK($s[2])) {
            my $t = readlink $p;
            my $real = abs_path("$top/$p");
            exit 3 unless defined $t && defined $real && -e $real && "$t$real" !~ /[\t\n]/;
            $d->add("L\t$p\t$t\t$real\n");
            if (tree($real)) { exit 3 if hookstate($real); return }
            my $r = release($real);
            if (defined $r) {
              exit 3 unless length $r;
              $d->add("R\t$r\n");
              return;
            }
            my @r = $hr ? Time::HiRes::stat($real) : stat($real);
            exit 3 unless @r && S_ISREG($r[2]) && native($real);
            $d->add(sprintf "T\t%s\t%d %d %o %d %.9f %.9f\n", $real, @r[0, 1, 2, 7, 9, 10]);
            return;
          }
          if (S_ISDIR($s[2])) {
            $d->add(sprintf "D\t%s\t%o\n", $p, $s[2]) unless $nodir;
            opendir(my $dh, $p) or exit 3;
            my @c = sort grep { $_ ne "." && $_ ne ".." } readdir $dh;
            closedir $dh;
            walk("$p/$_", $content, $nodir) for @c;
            return;
          }
          if (S_ISREG($s[2]) && $p =~ m{(?:^|/)\.vite/vitest/[^/]+/results\.json$}) {
            open(my $fh, "<", $p) or exit 3;
            my $j = eval { local $/; JSON::PP->new->decode(<$fh> // "") };
            close $fh;
            exit 3 unless ref $j eq "HASH" && str($j->{version}) && ref $j->{results} eq "ARRAY";
            my @r;
            for my $e (@{$j->{results}}) {
              exit 3 unless ref $e eq "ARRAY" && @$e == 2 && str($e->[0]) && $e->[0] =~ m{[:/]}
                && ref $e->[1] eq "HASH" && JSON::PP::is_bool($e->[1]{failed})
                && !grep { $_ ne "duration" && $_ ne "failed" } keys %{$e->[1]};
              push @r, [$e->[0], $e->[1]{failed} ? 1 : 0];
            }
            @r = sort { $a->[0] cmp $b->[0] || $a->[1] <=> $b->[1] } @r;
            $d->add("V\t$p\t", JSON::PP->new->canonical->encode([$j->{version}, \@r]), "\n");
            return;
          }
          if ($content && S_ISREG($s[2])) {
            open(my $fh, "<", $p) or exit 3;
            binmode $fh;
            my $h = Digest::SHA->new(256)->addfile($fh)->hexdigest;
            close $fh;
            $d->add(sprintf "C\t%s\t%o %d %s\n", $p, $s[2], $s[7], $h);
            return;
          }
          $d->add(sprintf "F\t%s\t%d %d %o %d %.9f %.9f\n", $p, @s[0, 1, 2, 7, 9, 10]);
        }
        local $/ = "\0";
        my ($ls, $orig) = (0, 0);
        while (my $r = <STDIN>) {
          chomp $r;
          if ($orig) { $orig = 0; next }
          if ($r eq "LS") { $ls = 1; next }
          # A merge conflict or changed gitlink is never a verified state.
          # The walk cannot bind the submodule worktree or ignored inputs.
          exit 3 if !$ls && ($r =~ /^u / || $r =~ /^[12] \S+ S\S{3} /);
          # Every tracked symlink, so one that leaves the worktree is seen.
          if ($ls) { walk($1, 0) if $r =~ /^120000 [0-9a-f]+ [0-3]\t(.+)$/s; next }
          # A tracked file replaced by a symlink and not staged: the index
          # still calls it a file. Refused rather than modelled.
          exit 3 if $r =~ /^[12] \S+ \S+ \d+ (\d+) (\d+) / && $2 eq "120000" && $1 ne "120000";
          if ($r =~ /^2 /) { $orig = 1; next }
          next unless $r =~ s/^([!?]) //;
          my $untracked = $1 eq "?";
          $r =~ s{/$}{};
          walk($r, 0, $untracked);
        }
        print $d->hexdigest, "\n";' "$top" "$releases" "${__se_hook_state_pathspec[@]}"
)

# _se_tool_closure <top> [--shell] <path>...
#   - prints "<kind>\t<path>\t<real path>\t<identity>\t<interpreter>" per
#     planned program. Reuse needs every program's code to be bound, so kind
#     is "tree" when its physical path is inside the worktree <top> (the
#     fingerprint and ignored digest cover it) and "native" for a Mach-O or
#     ELF binary elsewhere, recognised by its magic number. A native binary,
#     in the tree or not, is admitted only as a listed interpreter (its
#     physical name node, nodejs, python* or perl*), whose scripts are bound
#     in the tree; any other (cargo, go, ruff, a compiled tool) reads code
#     or configuration the key cannot see and is kind "unlisted". With
#     --shell, each path is the shell npm runs scripts with: native, kind
#     "native", else "unlisted"; nothing else is asked of it.
#     A tree script is bound only as a pnpm node_modules/.bin shim matching
#     the templates pnpm 8 to 11 write byte for byte (shim, below), or by a
#     #! line naming node, nodejs, python* or perl*, directly or through
#     env with no other word, that is native (a script by that name is not). No shell script is
#     parsed: any other #! (a shell included) or text with no #! is kind
#     "interpreter". The #! rule holds for "pm" scripts too.
#     An npm or pnpm #! script is "pm" when the nearest ancestor of its real
#     path holding a package.json named for it (npm; pnpm or corepack) is
#     found: that package root follows as a sixth field, and for corepack's
#     pnpm shim so does the corepack home it dispatches into (COREPACK_HOME,
#     else <XDG_CACHE_HOME|~/.cache>/node/corepack), for _se_pkg_digest to
#     bind. npx, pnpx and yarn are never "pm". Anything else outside the
#     tree is "foreign": a script, text without a #! (bash runs it anyway),
#     or a file that cannot be read. "missing" when it does not resolve. Fails only when perl
#     cannot run.
_se_tool_closure() {
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MCwd=abs_path -MJSON::PP -e '
    my ($top, @p) = @ARGV;
    my $shell = @p && $p[0] eq "--shell" ? shift @p : "";
    my %pm = (npm => [qw(npm)], pnpm => [qw(pnpm corepack)]);
    sub pkgroot {
      my ($a, $names) = @_;
      (my $d = $a) =~ s{/[^/]*$}{};
      while (length $d) {
        if (-f "$d/package.json" && open(my $fh, "<", "$d/package.json")) {
          local $/;
          my $j = eval { decode_json(<$fh>) };
          my $n = ref $j eq "HASH" ? $j->{name} // "" : "";
          return ($d, $n) if grep { $_ eq $n } @$names;
        }
        $d =~ s{/[^/]*$}{};
      }
      return ();
    }
    my $hr = eval { require Time::HiRes; 1 };
    sub id { my @s = $hr ? Time::HiRes::stat($_[0]) : stat($_[0]); return "-" unless @s;
             sprintf "%d %d %o %d %.9f %.9f", @s[0, 1, 2, 7, 9, 10] }
    sub which { for my $d (split /:/, $ENV{PATH} // "") { return "$d/$_[0]" if length $d && -x "$d/$_[0]" && !-d _ } return undef }
    sub head { open(my $fh, "<", $_[0]) or return undef; binmode $fh; my $m = ""; read($fh, $m, 256); return $m }
    sub native { my $m = head($_[0]); defined $m && $m =~ /^(\x7fELF|\xfe\xed\xfa[\xce\xcf]|[\xce\xcf]\xfa\xed\xfe|\xca\xfe\xba[\xbe\xbf])/ }
    sub tree { index("$_[0]/", "$top/") == 0 && index("$_[0]/", "$top/.git/") != 0 }
    # The first line of a file, read whole within 4096 bytes, else undef.
    sub line1 { open(my $fh, "<", $_[0]) or return undef; binmode $fh; my $b = ""; read($fh, $b, 4096); $b =~ /\A([^\n]*)\n/ ? $1 : undef }
    # bound <path>: its identity when it is a native binary, "absent" when
    # nothing is there, else undef (a script here would run unseen code).
    sub bound {
      return "absent" unless -e $_[0] || -l $_[0];
      my $r = abs_path($_[0]);
      return defined $r && -f $r && native($r) ? "$r " . id($r) : undef;
    }
    # The physical path a not-yet-existing absolute path would land on.
    sub land {
      my ($x, $rest) = ($_[0], "");
      return undef if $x !~ m{^/} || grep { $_ eq ".." } split m{/}, $x;
      until (!length $x || -e $x || -l $x) {
        $x =~ s{/([^/]*)$}{} or return undef;
        $rest = "/$1$rest";
      }
      my $r = abs_path(length $x ? $x : "/");
      return defined $r ? "$r$rest" : undef;
    }
    # shim <path> <real path>: the bound closure of a pnpm node_modules/.bin
    # shim, matched byte for byte against the templates pnpm 8 to 11 write
    # (only its NODE_PATH and target vary), else undef. Its $basedir is the
    # directory of <path>, which must be absolute and physically the
    # directory of <real path>, each path in plain bytes
    # ([A-Za-z0-9_@%+=:,./-]). The target must be a file in the tree, each
    # NODE_PATH entry must land in the tree, and every program it can start
    # (/bin/sh, $basedir/node, then node, dirname, sed and uname on PATH)
    # must be native or absent.
    sub shim {
      my ($p, $a) = @_;
      open(my $fh, "<", $a) or return undef;
      binmode $fh;
      my $body = "";
      my $got = read($fh, $body, 65537);
      close $fh;
      return undef unless defined $got && $got <= 65536;
      my $head = "#!/bin/sh\nbasedir=\$(dirname \"\$(echo \"\$0\" | sed -e \x27s,\\\\,/,g\x27)\")\n\n";
      my @cyg = ("case `uname` in\n    *CYGWIN*) basedir=`cygpath -w \"\$basedir\"`;;\nesac\n\n",
        "case `uname` in\n    *CYGWIN*|*MINGW*|*MSYS*)\n        if command -v cygpath > /dev/null 2>&1; then\n"
        . "            basedir=`cygpath -w \"\$basedir\"`\n        fi\n    ;;\nesac\n\n");
      return undef unless substr($body, 0, length $head, "") eq $head;
      return undef unless grep { substr($body, 0, length $_) eq $_ && substr($body, 0, length $_, "") } @cyg;
      $body =~ m{\A(?:if \[ -z "\$NODE_PATH" \]; then\n  export NODE_PATH="([^"\$`\\\n]*)"\nelse\n  export NODE_PATH="\1:\$NODE_PATH"\nfi\n)?if \[ -x "\$basedir/node" \]; then\n  exec "\$basedir/node"  "\$basedir/([^"\$`\\\n]+)" "\$\@"\nelse\n  exec node  "\$basedir/\2" "\$\@"\nfi\n(?:\# cmd-shim-target=[^\n]*\n)?\z}
        or return undef;
      my ($np, $t) = ($1 // "", $2);
      (my $dir = $a) =~ s{/[^/]*$}{};
      (my $pd = $p) =~ s{/[^/]*$}{};
      # The shell and this code must read every path alike: plain bytes only.
      return undef if grep { !m{^[A-Za-z0-9_\@%+=:,./-]+$} } $p, $a, $t, split /:/, $np;
      return undef unless $p =~ m{^/[^/]} && length $pd;
      my $pr = abs_path($pd);
      return undef unless defined $pr && $pr eq $dir;
      my $ta = abs_path("$dir/$t");
      return undef unless defined $ta && -f $ta && tree($ta);
      my @out = ("shim $ta");
      for my $e (grep { length } split /:/, $np) {
        my $l = land($e);
        return undef unless defined $l && tree($l);
        push @out, "path $l";
      }
      for my $x (["sh", "/bin/sh"], ["basedir/node", "$dir/node"], map { [$_, which($_)] } qw(node dirname sed uname)) {
        my $b = defined $x->[1] ? bound($x->[1]) : "absent";
        return undef unless defined $b;
        push @out, "$x->[0] $b";
      }
      return join " | ", @out;
    }
    for my $p (@p) {
      my $a = abs_path($p);
      if (!defined $a || !-f $a) { print "missing\t$p\t-\t-\t-\n"; next }
      my $kind = tree($a) ? "tree" : native($a) ? "native" : "foreign";
      my ($interp, @roots) = ("-");
      if ($shell) {
        print join("\t", native($a) ? "native" : "unlisted", $p, $a, id($a), "-"), "\n";
        next;
      }
      # A native program reads code and configuration only its maker knows:
      # only the listed interpreters, whose scripts the tree holds, pass.
      $kind = "unlisted" if native($a) && $a !~ m{/(?:node|nodejs|python[0-9.]*|perl[0-9.]*)$};
      my $m = head($a) // "";
      my ($base) = $p =~ m{([^/]+)$};
      if ($kind eq "foreign" && $pm{$base} && $m =~ /^#!/) {
        my ($root, $name) = pkgroot($a, $pm{$base});
        if (defined $root) {
          $kind = "pm";
          @roots = ($root);
          if ($name eq "corepack") {
            my $h = $ENV{COREPACK_HOME} // (($ENV{XDG_CACHE_HOME} // "$ENV{HOME}/.cache") . "/node/corepack");
            my $hr2 = abs_path($h);
            if (defined $hr2 && -d $hr2) { push @roots, $hr2 } else { $kind = "foreign" }
          }
        }
      }
      # A script runs code its interpreter reads: only a pnpm shim (bound
      # whole, above), or a first line (whole within 4096 bytes) that is
      # #!<interpreter> or #!<path>/env <name> and nothing more, naming
      # node, nodejs, python* or perl* that is itself native.
      # Any other #! (a shell included, whatever it runs), or text with no
      # #! (sh runs it), is unbound.
      if ($kind ne "foreign" && !native($a)) {
        my $s = $kind eq "tree" ? shim($p, $a) : undef;
        if (defined $s) { $interp = $s }
        else {
          my $l = line1($a);
          my ($i, $w) = defined $l && $l =~ /\A#![ \t]*(\S+)(?:[ \t]+(\S+))?[ \t]*\z/ ? ($1, $2) : ();
          my $env = "";
          if (defined $i && defined $w) {
            if ($i =~ m{(^|/)env$} && $w =~ /^[A-Za-z][A-Za-z0-9._+-]*$/) {
              my $eb = bound($i);
              $env = defined $eb && $eb ne "absent" ? "env $eb | " : undef;
              $i = which($w);
            }
            else { $i = undef }
          }
          my $ia = defined $i && defined $env ? abs_path($i) : undef;
          if (defined $ia && -f $ia && native($ia) && $ia =~ m{/(?:node|nodejs|python[0-9.]*|perl[0-9.]*)$}) {
            $interp = "$env$ia " . id($ia);
          }
          else { $kind = "interpreter"; $interp = "unbound " . ($i // "-") }
        }
      }
      print join("\t", $kind, $p, $a, id($a), $interp, @roots), "\n";
    }' "$@"
}

# _se_pkg_digest <root>...
#   - prints a sha256 over every entry of each package tree <root> (a package
#     manager's installation), by the same lstat identity as the ignored
#     digest, so any byte change in the code that runs changes it. Fails, so
#     the caller refuses reuse, when a root has more than 20000 entries, an
#     entry cannot be read, or a symlink dangles or resolves outside its root.
_se_pkg_digest() {
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MDigest::SHA -MFcntl=:mode -MCwd=abs_path -e '
    my $hr = eval { require Time::HiRes; 1 };
    my $d = Digest::SHA->new(256);
    for my $root (@ARGV) {
      my $n = 0;
      my @q = ($root);
      while (defined(my $p = shift @q)) {
        exit 3 if ++$n > 20000 || $p =~ /[\t\n]/;
        my @s = $hr ? Time::HiRes::lstat($p) : lstat($p);
        exit 3 unless @s;
        if (S_ISLNK($s[2])) {
          my $t = readlink $p;
          my $real = abs_path($p);
          exit 3 unless defined $t && defined $real && -e $real && index("$real/", "$root/") == 0 && $t !~ /[\t\n]/;
          $d->add("L\t$p\t$t\t$real\n");
        } elsif (S_ISDIR($s[2])) {
          $d->add(sprintf "D\t%s\t%o\n", $p, $s[2]);
          opendir(my $dh, $p) or exit 3;
          push @q, map { "$p/$_" } sort grep { $_ ne "." && $_ ne ".." } readdir $dh;
          closedir $dh;
        } else {
          $d->add(sprintf "F\t%s\t%d %d %o %d %.9f %.9f\n", $p, @s[0, 1, 2, 7, 9, 10]);
        }
      }
    }
    print $d->hexdigest, "\n";' "$@"
}

# _se_pm_progs <top> <dir> <word>...
#   - for a check that runs npm or pnpm (<word>... is its command), prints
#     every program the run would start, one path per line, for
#     _se_tool_closure to classify: the package manager itself and, through
#     the package.json scripts (pre<name>, <name>, post<name>, recursively
#     through nested npm/pnpm runs), each command's program as npm resolves
#     it (node_modules/.bin of the package and its ancestors, then PATH). An
#     absolute path argument admitted as a release payload prints as
#     "arg\t<realpath>\t<version> <release.json sha256>" for the key; one
#     admitted as a native binary prints as a program, so its identity is
#     bound.
#   - admission is an allowlist grammar; anything else fails, and the
#     caller runs the checks with no reuse:
#       command  the planned one, or a script: simple commands joined only
#                by && (no other operator, quote, $, backquote, backslash,
#                brace, parenthesis, redirection, # or newline)
#       word     ^[A-Za-z0-9_@%+=:,./-]+$ (no ~ * ? [ ]), never containing
#                :// and never a leading VAR=value
#       program  true, false or : (no-ops); npm/pnpm with `run <script>`,
#                `run-script <script>` or `test`, no flag after the script
#                name except past a literal --, four runs deep at most; the
#                words after the name, less the first --, join the script's
#                last command, as npm appends them, and take that program's
#                rules (refused when that command is npm or pnpm); anything
#                else resolves the npm way and must then pass the closure
#                rule. Refused: npx, pnpx, bunx, dlx (as any
#                word, not only the program), yarn,
#                yarnpkg, corepack, bun, deno, cargo, go, rustc, rustup,
#                gofmt, golangci-lint; the wrappers env, nice,
#                nohup, time, xargs, command, exec, timeout, gtimeout,
#                stdbuf, sudo, doas; the builtins cd, export, set, source,
#                ., eval, unset.
#       options  for node, python*, perl*, ruby and the shells (sh, bash,
#                zsh, dash, ksh, mksh, yash, ash, fish, csh, tcsh, busybox),
#                judged by the physical binary as well as the word (a link
#                named runner to perl is perl; one to npm or pnpm refuses),
#                every option before the first operand must be on a short
#                allowlist, value-taking ones only attached (-Wignore); a
#                flag cluster with c or e, or for python any -...[cmEI]
#                word, refuses anywhere in the command. For every program,
#                -c, -e, -r, -p, --eval, --print, --require, --import,
#                --loader, --experimental-loader or --input-type anywhere
#                refuses.
#       paths    every word, and the value of --flag=value or -Xvalue, that
#                holds a / is a relative path with no .. segment resolving
#                inside the worktree (outside .git/), existing or not, or an
#                absolute path admitted as native or a release payload; any
#                word naming an existing entry must resolve inside the
#                worktree too.
_se_pm_progs() {
  local releases
  releases="${TRELLIS_HOME:-${HOME:-/nonexistent}/.trellis}/releases"
  releases=$(CDPATH='' cd -P "$releases" 2>/dev/null && pwd -P) || releases=/nonexistent
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MJSON::PP -MCwd=abs_path -MDigest::SHA -e '
    my ($top, $rel, $dir, @argv) = @ARGV;
    my %noop = map { $_ => 1 } qw(true false :);
    my %refuse = map { $_ => 1 } qw(npx pnpx bunx dlx yarn yarnpkg corepack bun deno
      cargo go rustc rustup gofmt golangci-lint
      env nice nohup time xargs command exec timeout gtimeout stdbuf sudo doas
      cd export set source . eval unset);
    # Flags each family may take before its first operand. A value-taking
    # option is accepted only attached (python -Wignore, -Xdev), so the
    # next word can never hide behind it.
    my %opts = (
      node => { map { $_ => 1 } qw(--test --no-warnings --enable-source-maps --trace-warnings --trace-uncaught) },
      python => { map { $_ => 1 } qw(-u -B -O -s) },
      perl => { map { $_ => 1 } qw(-w) },
      ruby => { map { $_ => 1 } qw(-w) },
      sh => { map { $_ => 1 } qw(-u -x) },
    );
    my %attached = (python => qr/^-[WX][^-].*$/);
    my (%seen, @out);
    sub native {
      open(my $fh, "<", $_[0]) or return 0;
      binmode $fh;
      my $m = "";
      read($fh, $m, 4);
      return $m =~ /^(\x7fELF|\xfe\xed\xfa[\xce\xcf]|[\xce\xcf]\xfa\xed\xfe|\xca\xfe\xba[\xbe\xbf])$/;
    }
    sub base { (my $b = $_[0]) =~ s{.*/}{}; $b }
    sub tree { my $a = "$_[0]/"; index($a, "$top/") == 0 && index($a, "$top/.git/") != 0 }
    sub which { for my $d (split /:/, $ENV{PATH} // "") { return "$d/$_[0]" if length $d && -x "$d/$_[0]" && !-d _ } undef }
    sub family {
      my $b = shift;
      return "node" if $b eq "node" || $b eq "nodejs";
      return "python" if $b =~ /^python[0-9.]*$/;
      return "sh" if $b =~ /^(sh|bash|zsh|dash|ksh|mksh|yash|ash|fish|csh|tcsh|busybox)$/;
      return "perl" if $b =~ /^perl[0-9.]*$/;
      return $b if $b eq "ruby";
      return undef;
    }
    # The physical path of <p>, or of its nearest existing ancestor with
    # the rest appended: what a not-yet-existing path would land on.
    sub land {
      my $p = shift;
      my $rest = "";
      until (-e $p || -l $p) {
        $p =~ s{/([^/]*)$}{} or return undef;
        $rest = "/$1$rest";
        return undef unless length $p;
      }
      my $r = abs_path($p);
      return defined $r ? "$r$rest" : undef;
    }
    sub token {
      my ($pd, $t) = @_;
      exit 1 if index($t, "://") >= 0;
      if ($t =~ m{^/}) {
        my $r = abs_path($t);
        exit 1 unless defined $r && -e $r;
        if (my ($v) = "$r/" =~ m{^\Q$rel\E/([^/]+)/payload/}) {
          open(my $fh, "<", "$rel/$v/release.json") or exit 1;
          binmode $fh;
          push @out, "arg\t$r\t$v " . Digest::SHA->new(256)->addfile($fh)->hexdigest;
          return;
        }
        exit 1 unless -f $r && native($r);
        push @out, $r;
        return;
      }
      if (index($t, "/") >= 0) {
        exit 1 if grep { $_ eq ".." } split m{/}, $t;
        my $r = land("$pd/$t");
        exit 1 unless defined $r && tree($r);
        return;
      }
      exit 1 if $t eq "..";
      if (-e "$pd/$t" || -l "$pd/$t") {
        my $r = abs_path("$pd/$t");
        exit 1 unless defined $r && tree($r);
      }
    }
    sub word {
      my ($pd, $w) = @_;
      exit 1 unless $w =~ m{^[A-Za-z0-9_\@%+=:,./-]+$};
      token($pd, $w);
      if ($w =~ /^--[^=]+=(.*)$/s) { token($pd, $1) if length $1 }
      elsif ($w =~ /^-[A-Za-z](.+)$/s) { token($pd, $1) }
    }
    sub resolve {
      my ($w, $pd) = @_;
      return abs_path("$pd/$w") if $w =~ m{/};
      for (my $d = $pd; length $d; $d =~ s{/[^/]*$}{}) {
        return "$d/node_modules/.bin/$w" if -x "$d/node_modules/.bin/$w" && !-d _;
      }
      return which($w);
    }
    sub commands {
      my $s = shift;
      exit 1 unless $s =~ m{^[A-Za-z0-9_\@%+=:,./ &-]+$};
      my @cmds;
      for my $c (split /&&/, $s, -1) {
        exit 1 if index($c, "&") >= 0;
        my @w = grep { length } split / +/, $c;
        exit 1 unless @w;
        push @cmds, [@w];
      }
      return @cmds;
    }
    sub check {
      my ($pd, $depth, @w) = @_;
      exit 1 if $depth > 4 || !@w;
      exit 1 if $w[0] =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
      word($pd, $_) for @w;
      exit 1 if grep { /^(npx|pnpx|bunx|dlx)$/ } map { base($_) } @w;
      my $b = base($w[0]);
      exit 1 if $refuse{$b};
      return if $noop{$w[0]};
      if ($b eq "npm" || $b eq "pnpm") {
        my $p = resolve($w[0], $pd);
        exit 1 unless defined $p;
        push @out, $p;
        my ($script, @fwd);
        if (@w == 2 && $w[1] eq "test") { $script = "test" }
        elsif (@w >= 3 && ($w[1] eq "run" || $w[1] eq "run-script") && $w[2] !~ /^-/) { ($script, @fwd) = @w[2 .. $#w] }
        else { exit 1 }
        for my $x (@fwd) { last if $x eq "--"; exit 1 if $x =~ /^-/ }
        # pnpm passes -- on to the script where npm consumes it: refused
        # rather than modelled.
        exit 1 if $b eq "pnpm" && grep { $_ eq "--" } @fwd;
        # npm consumes the first -- and appends the rest to the script, so
        # they reach its last command and take the rules of its program.
        my $sep = 0;
        @fwd = grep { $sep || $_ ne "--" || !($sep = 1) } @fwd;
        runscript($pd, $script, $depth, @fwd);
        return;
      }
      my $p = resolve($w[0], $pd);
      exit 1 unless defined $p;
      push @out, $p;
      # The rules follow the binary that runs, not the word that names it: a
      # link called runner may be perl.
      my $rp = abs_path($p);
      exit 1 unless defined $rp;
      my $rb = base($rp);
      exit 1 if $refuse{$rb} || $rb =~ /^(?:npm|pnpm|npx|pnpx|yarn|corepack)(?:-cli)?(?:\.[cm]?js)?$/;
      # Backstop for any program, known or not: an inline-code or preload
      # flag anywhere refuses (a legitimate tool flag of the same spelling
      # only costs a full run).
      exit 1 if grep { /^-[cerp]$/ || /^--(?:eval|print|require|import|loader|experimental-loader|input-type)(?:=|$)/ } @w[1 .. $#w];
      if (my $f = family($rb) // family($b)) {
        exit 1 if grep { /^-[A-Za-z]*[ce][A-Za-z]*$/ && !($attached{$f} && $_ =~ $attached{$f}) } @w[1 .. $#w];
        exit 1 if $f eq "python" && grep { /^-[A-Za-z]*[cmEI]/ } @w[1 .. $#w];
        for my $x (@w[1 .. $#w]) {
          last unless $x =~ /^-/;
          exit 1 unless $opts{$f}{$x} || ($attached{$f} && $x =~ $attached{$f});
        }
      }
    }
    sub runscript {
      my ($pd, $name, $depth, @fwd) = @_;
      return if $seen{join "\0", $pd, $name, @fwd}++;
      open(my $fh, "<", "$pd/package.json") or exit 1;
      my $j = eval { local $/; decode_json(<$fh>) };
      exit 1 unless ref $j eq "HASH";
      my $s = ref $j->{scripts} eq "HASH" ? $j->{scripts} : {};
      exit 1 unless defined $s->{$name};
      for my $n ("pre$name", $name, "post$name") {
        next unless defined $s->{$n};
        exit 1 if ref $s->{$n};
        my @c = commands($s->{$n});
        # Forwarded into another npm or pnpm run, they would meet a second
        # reading of -- and flags: refused rather than modelled.
        exit 1 if @fwd && $n eq $name && base($c[-1][0]) =~ /^p?npm$/;
        push @{$c[-1]}, @fwd if $n eq $name;
        check($pd, $depth + 1, @$_) for @c;
      }
    }
    my $pd = abs_path($dir);
    exit 1 unless defined $pd;
    until (-f "$pd/package.json") {
      exit 1 if $pd eq $top || !tree($pd);
      $pd =~ s{/[^/]*$}{};
    }
    exit 1 unless tree($pd);
    check($pd, 0, @argv);
    print "$_\n" for @out;' "$1" "$releases" "${@:2}"
}

# _se_pm_config <dir>
#   - prints a sha256 over every configuration file npm and pnpm read for a
#     run in <dir>, each bound by content or as absent: .npmrc,
#     pnpm-workspace.yaml and .pnpmfile.cjs/.mjs in <dir> and every ancestor;
#     the user ~/.npmrc; the global npmrc <prefix>/etc/npmrc for PREFIX and
#     the prefix of node on PATH, linked and real (a userconfig, globalconfig
#     or prefix setting refuses, below); and pnpm's rc, auth.ini, config.yaml and global_pnpmfile.cjs under
#     XDG_CONFIG_HOME|~/.config and ~/Library/Preferences. npm's builtin
#     npmrc sits in its package tree, which _se_pkg_digest binds.
#   - fails, so the caller refuses reuse, when one of them is not a regular
#     file, when an ini file (.npmrc, npmrc, pnpm rc) or YAML file
#     (pnpm-workspace.yaml, config.yaml) has a line outside a strict simple
#     grammar (ini and yaml, below: no escape, quoted key, section, ? key,
#     flow collection, anchor, alias, merge, ${ in a key or multi-line
#     scalar), or when one of them or the environment (npm_config_* or
#     pnpm_config_*, any case) sets a key that moves configuration or code
#     elsewhere (pnpmfile, global-pnpmfile, globalconfig, userconfig,
#     prefix, script-shell, shell-emulator, node-options, use-node-version,
#     node-version, executionEnv, dir, workspace(s), include-workspace-root,
#     recursive, filter, filter-prod, workspace-root, config-dir,
#     npmrc-auth-file, modules-dir, (global-)virtual-store-dir, global-dir,
#     global-bin-dir, pnpm-home-dir, node-gyp, init-module), in any
#     spelling: those paths could not be enumerated here. In the
#     environment every npm_config_*/pnpm_config_* refuses but loglevel,
#     color, fund, audit, progress, yes and update-notifier; a .corepack.env
#     in <dir> or an ancestor refuses too.
_se_pm_config() {
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MDigest::SHA -MCwd=abs_path -e '
    my ($dir) = @ARGV;
    my $h = $ENV{HOME} // "/nonexistent";
    sub which { for my $d (split /:/, $ENV{PATH} // "") { return "$d/$_[0]" if length $d && -x "$d/$_[0]" && !-d _ } undef }
    sub prefix { my $p = shift; return () unless defined $p; $p =~ s{/[^/]*/[^/]*$}{}; return ($p) }
    my @f;
    my $d = abs_path($dir) // exit 1;
    while (1) {
      push @f, map { "$d/$_" } qw(.npmrc pnpm-workspace.yaml .pnpmfile.cjs .pnpmfile.mjs);
      # Corepack loads variables from a .corepack.env: refused, not read.
      exit 2 if -e "$d/.corepack.env" || -l "$d/.corepack.env";
      last if $d eq "";
      $d =~ s{/[^/]*$}{};
    }
    # One set of keys that move configuration or code, spelt any way.
    my %move = map { $_ => 1 } qw(pnpmfile globalpnpmfile globalconfig userconfig prefix scriptshell
      shellemulator nodeoptions usenodeversion nodeversion executionenv dir workspace workspaces
      includeworkspaceroot recursive filter filterprod workspaceroot configdir npmrcauthfile modulesdir
      virtualstoredir globalvirtualstoredir globaldir globalbindir pnpmhomedir nodegyp initmodule);
    # In the environment, only settings that move nothing are taken.
    my %envsafe = map { $_ => 1 } qw(loglevel color fund audit progress yes updatenotifier);
    sub norm { (my $k = lc shift) =~ tr/-_//d; $k }
    # Neither ini nor YAML is parsed: a file is read only when every line
    # fits a grammar both readers agree on, else reuse is refused (exit 1).
    # ini: blank, a # or ; comment, or key=value / key: value with a plain
    # key at column 0 and a value with no control byte or backslash.
    sub ini {
      for my $l (split /\n/, $_[0], -1) {
        next if $l =~ /^[ ]*$/ || $l =~ /^[ ]*[#;][^\x00-\x1f]*$/;
        exit 1 unless $l =~ m{^([A-Za-z0-9_.\@/-]+)[ ]*[=:][ ]*[^\x00-\x1f\\]*$};
        exit 2 if $move{norm($1)};
      }
    }
    # YAML: blank, a # comment, "key: scalar" or a bare "key:" at column 0,
    # and "  - scalar" items under packages: alone. A scalar is plain (no
    # indicator, quote, #, flow or block character) or quoted with no
    # escape. No anchor, alias, merge, ? key, flow collection, tag or
    # multi-line scalar fits.
    my $sc = qr{(?:[A-Za-z0-9_./\@=+~^%,-](?:[A-Za-z0-9_./\@=+~^%, -]|:(?![ ]|$))*|\x27[^\x27\x00-\x1f]*\x27|"[^"\\\x00-\x1f]*")};
    my $cm = qr{(?:[ ]+#[^\x00-\x1f]*)?[ ]*};
    sub yaml {
      my $block = "";
      for my $l (split /\n/, $_[0], -1) {
        next if $l =~ /^[ ]*$/ || $l =~ /^[ ]*#[^\x00-\x1f]*$/;
        if ($l =~ m{^([A-Za-z0-9_./-]+):(?:[ ]+$sc$cm|[ ]*)$}) {
          my $k = $1;
          exit 2 if $move{norm($k)};
          $block = $l =~ /^[^:]+:[ ]*$/ ? $k : "";
          next;
        }
        exit 1 unless $block eq "packages" && $l =~ m{^[ ]+-[ ]+$sc$cm$};
      }
    }
    for my $n (keys %ENV) {
      exit 2 if $n =~ /^p?npm_config_(.+)$/i && !$envsafe{norm($1)};
    }
    push @f, "$h/.npmrc";
    my $node = which("node");
    push @f, map { "$_/etc/npmrc" } grep { defined }
      $ENV{PREFIX}, prefix($node), prefix(defined $node ? abs_path($node) : undef);
    for my $c ($ENV{XDG_CONFIG_HOME} // "$h/.config", "$h/Library/Preferences") {
      push @f, map { "$c/pnpm/$_" } qw(rc auth.ini config.yaml global_pnpmfile.cjs);
    }
    my $sum = Digest::SHA->new(256);
    my %done;
    for my $f (@f) {
      next if $done{$f}++;
      if (!lstat $f) { $sum->add("A\t$f\n"); next }
      exit 1 unless -f _ && !-l $f;
      open(my $fh, "<", $f) or exit 1;
      my $c = do { local $/; <$fh> } // "";
      close $fh;
      if ($f =~ m{/(?:\.npmrc|npmrc|rc|auth\.ini)$}) { ini($c) }
      elsif ($f =~ m{\.yaml$}) { yaml($c) }
      $sum->add("C\t$f\t", Digest::SHA::sha256_hex($c), "\n");
    }
    print $sum->hexdigest, "\n";' "$@"
}

# _se_env_moves_code <top>
#   - succeeds (so the caller refuses reuse) when the environment selects
#     code or configuration the key cannot bind: the key hashes each
#     variable's text, never the files a path or option in it names. Within
#     each tool family every variable refuses unless it is on a short list
#     that selects nothing:
#       set at all, even empty: XDG_CONFIG_HOME, XDG_CACHE_HOME (tools fall
#         back differently on ""), LOCALAPPDATA, APPDATA; COREPACK_HOME
#         unless an absolute path
#       NODE_*: but NODE_ENV, NODE_NO_WARNINGS, and NODE_OPTIONS made only
#         of memory and warning flags (--max-old-space-size=N,
#         --max-semi-space-size=N, --stack-trace-limit=N, --no-warnings,
#         --no-deprecation, --enable-source-maps, --trace-warnings,
#         --trace-uncaught, --trace-deprecation, --throw-deprecation)
#       PYTHON*: but PYTHONUNBUFFERED, PYTHONDONTWRITEBYTECODE,
#         PYTHONIOENCODING, PYTHONHASHSEED, PYTHONUTF8, PYTHONNOUSERSITE,
#         PYTHONFAULTHANDLER; VIRTUAL_ENV only inside the worktree <top>
#       PYTEST_*, MYPY*, PERL*, RUBY*, GEM_*, TS_NODE_*, JAVA_*, _JAVA_*,
#         JDK_*, LD_*, DYLD_*: every one
#       COREPACK_*: but COREPACK_ENABLE_AUTO_PIN,
#         COREPACK_ENABLE_DOWNLOAD_PROMPT and an absolute COREPACK_HOME
#       CARGO_*, *RUSTFLAGS, RUSTDOCFLAGS, RUSTC*, GO*, GIT_*: but
#         CARGO_TERM_*, CARGO_INCREMENTAL, GOOS, GOARCH, GOAMD64, GOARM,
#         GOARM64, GO111MODULE, GOPROXY, GOOGLE_* (not Go settings) and
#         GIT_EDITOR set to true or :, and GIT_OPTIONAL_LOCKS=0 (every hook
#         entry exports it; it disables optional index writes, selects no code)
#       CLASSPATH, BASH_ENV, ENV, ZDOTDIR: every one
#     npm and pnpm settings are _se_pm_config's. Read raw (%ENV), so a name
#     bash would not list counts too; LD_* and DYLD_* are also read from
#     bash, which sees what a protected perl is not given.
#   - a false alarm costs a full run, never a wrong reuse; so does a perl
#     that does not run.
_se_env_moves_code() {
  local n
  for n in $(compgen -e); do
    case "$n" in (LD_*|DYLD_*) [ -z "${!n}" ] || return 0 ;; esac
  done
  /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -MCwd=abs_path -e '
    my $top = shift;
    my %safe = map { $_ => 1 } qw(NODE_ENV NODE_NO_WARNINGS PYTHONUNBUFFERED PYTHONDONTWRITEBYTECODE
      PYTHONIOENCODING PYTHONHASHSEED PYTHONUTF8 PYTHONNOUSERSITE PYTHONFAULTHANDLER
      COREPACK_ENABLE_AUTO_PIN COREPACK_ENABLE_DOWNLOAD_PROMPT CARGO_INCREMENTAL
      GOOS GOARCH GOAMD64 GOARM GOARM64 GO111MODULE GOPROXY);
    for my $n (keys %ENV) {
      my $v = $ENV{$n};
      exit 0 if $n =~ /^(?:XDG_CONFIG_HOME|XDG_CACHE_HOME|LOCALAPPDATA|APPDATA)$/;
      exit 0 if $n eq "COREPACK_HOME" && $v !~ m{^/};
      next unless length $v;
      next if $safe{$n} || $n =~ /^(?:CARGO_TERM_|GOOGLE_)/ || $n eq "COREPACK_HOME";
      if ($n eq "GIT_EDITOR") { exit 0 unless $v eq "true" || $v eq ":"; next }
      if ($n eq "GIT_OPTIONAL_LOCKS") { exit 0 unless $v eq "0"; next }
      if ($n eq "VIRTUAL_ENV") {
        my $r = abs_path($v);
        exit 0 unless defined $r && index("$r/", "$top/") == 0;
        next;
      }
      if ($n eq "NODE_OPTIONS") {
        for (split " ", $v) {
          exit 0 unless /^--(?:max[-_]old[-_]space[-_]size|max[-_]semi[-_]space[-_]size|stack-trace-limit)=[0-9]+$/
            || /^--(?:no-warnings|no-deprecation|enable-source-maps|trace-warnings|trace-uncaught|trace-deprecation|throw-deprecation)$/;
        }
        next;
      }
      exit 0 if $n =~ /^(?:NODE_|PYTHON|PYTEST_|MYPY|PERL|RUBY|GEM_|TS_NODE_|JAVA_|_JAVA_|JDK_|LD_|DYLD_|COREPACK_|CARGO_|RUSTC|GO|GIT_)/
        || $n =~ /RUSTFLAGS$/ || $n =~ /^(?:RUSTDOCFLAGS|CLASSPATH|BASH_ENV|ENV|ZDOTDIR)$/;
    }
    exit 1;' "$1"
  [ "$?" -ne 1 ]
}

__se_heavy_loaded=1
