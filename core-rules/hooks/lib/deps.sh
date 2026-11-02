#!/usr/bin/env bash
# Shared dependency helpers for Trellis hooks.
# Sourced by each hook. Sibling location: lib/ alongside the hook scripts.
#
# Plan task: P3.5 (extract shared hook utilities).
#
# Ship rules:
#   - sync-hooks.sh / sync-codex-hooks.sh copy this file alongside *.sh.
#   - onboard-project.sh seeds .claude/hooks/lib/ + .codex/hooks/lib/.
#   - Functions are prefixed _se_ to avoid clashing with consumer scripts.

# _se_require_jq <hook-name> [block]
#   - if jq is available → return 0
#   - if TRELLIS_NO_JQ_DEGRADE=1   → write a stderr breadcrumb + exit 0
#   - otherwise                    → write stderr install help + exit 1, or with
#     `block` (bright-line PreToolUse guards) exit 2, Claude's blocking code,
#     because Claude treats exit 1 as a non-blocking error and runs the tool.
#
# Replaces the inline `if ! command -v jq ...; then exit 0; fi` pattern that
# silently dropped enforcement on jq-less environments (audit §3.2 / P1.5).
_se_require_jq() {
  local hook="${1:-hook}"
  if command -v jq >/dev/null 2>&1; then return 0; fi
  if [ "${TRELLIS_NO_JQ_DEGRADE:-0}" = "1" ]; then
    echo "${hook}: jq not found; TRELLIS_NO_JQ_DEGRADE=1 — degrading to no-op (install jq: brew install jq | apt-get install -y jq)" >&2
    exit 0
  fi
  if [ "${2:-}" = block ]; then
    echo "${hook}: jq required but not found; refusing — install jq (brew install jq | apt-get install -y jq) or set TRELLIS_NO_JQ_DEGRADE=1 to allow degradation" >&2
    exit 2
  fi
  echo "${hook}: jq required but not found — install jq (brew install jq | apt-get install -y jq) or set TRELLIS_NO_JQ_DEGRADE=1 to allow degradation" >&2
  exit 1
}

# _se_project_dir
#   - prints CODEX_PROJECT_DIR if set, else CLAUDE_PROJECT_DIR if set, else $PWD
#   - replaces the duplicated `${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}`
#     fallback in 6+ hooks across both harnesses.
_se_project_dir() {
  printf '%s' "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
}

# _se_repo_root <dir>
#   - prints the canonical repo root resolved via `git rev-parse --git-common-dir`
#     (one level up from the common dir), so worktree sessions still see
#     `context-log.md` and `gotchas.md` at the main checkout.
#   - falls back to <dir> when git is unavailable, the path is not a git repo,
#     or any step fails — never errors. Caller can treat the output as a
#     directory path regardless.
#
# Replaces the inline `__se_repo_root` block in the three context-log hooks
# (session-context, save-context-log, post-compact-context) on both harnesses.
# See `audits/2026-05-11-cross-project-process-audit.md` and the
# `0001-fix-hooks-context-log-canonical-root.patch` history.
_se_repo_root() {
  local dir="$1" common
  command -v git >/dev/null 2>&1 || { printf '%s' "$dir"; return; }
  # One git process: --git-common-dir fails outside a repository exactly where
  # a separate --is-inside-work-tree probe fails (both set up the repository
  # first and print "false"/a path with status 0 inside .git or a bare repo).
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || { printf '%s' "$dir"; return; }
  [ -n "$common" ] || { printf '%s' "$dir"; return; }
  case "$common" in
    /*) ;;
    *) common="${dir}/${common}" ;;
  esac
  ( cd "${common}/.." 2>/dev/null && pwd ) || printf '%s' "$dir"
}

# _se_state_key <transcript_path> <session_id>
#   - prints the 16-hex state key for the re-read guard's per-session state
#     files, or prints NOTHING (empty) on any failure (caller fails-open).
#   - SOURCE precedence: session_id PRIMARY, transcript_path FALLBACK,
#     literal "default" last. (DL-P5-09: session_id is reliably present on every
#     Claude/Codex event; transcript_path is NullableString with cross-event
#     population unconfirmed — keying off it first risked stamp-turn and the
#     guard deriving DIFFERENT keys → the guard reads a never-written .epoch →
#     permanent silent permit. One shared helper ELIMINATES the drift class.)
#   - SUM = SHA-256 of SRC; key = first 16 hex of the sum's first field. The
#     digest comes from sha256sum where it exists (coreutils; macOS 14+), one C
#     process against shasum's perl start, and from shasum otherwise or when
#     sha256sum prints anything but 64 lowercase hex.
_se_state_key() {
  local tp="${1:-}" sid="${2:-}" src sum=""
  if [ -n "$sid" ]; then
    src="$sid"
  elif [ -n "$tp" ]; then
    src="$tp"
  else
    src="default"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$src" | sha256sum 2>/dev/null) || sum=""
    sum=${sum%%[[:space:]]*}
    case "$sum" in *[!0-9a-f]*) sum="" ;; esac
    [ "${#sum}" -eq 64 ] || sum=""
  fi
  if [ -z "$sum" ]; then
    sum=$(printf '%s' "$src" | shasum -a 256 2>/dev/null) || return 1
    sum=${sum#"${sum%%[![:space:]]*}"}
    sum=${sum%%[[:space:]]*}
  fi
  [ -n "$sum" ] || return 1
  printf '%s' "${sum:0:16}"
}

# _se_normpath <path>
#   - prints a LEXICALLY normalized path. No file-existence required (must work
#     for new files). bash 3.2 / BSD-awk safe — pure string ops, NO realpath /
#     readlink -f (absent / non-portable on macOS).
#   - Normalize (DL-P5-10): strip a leading './'; collapse '//' to '/'; collapse
#     '/./' to '/'; resolve a real 'X/../' segment lexically; drop a trailing
#     '/' (but keep a bare '/'). The SAME normalized spelling must be produced
#     on the store side (track-read) and the compare side (reread-guard), so
#     './foo' ≡ 'foo' ≡ 'a/../foo'. A near-no-op for Claude's absolute paths;
#     this fixes the Codex relative-path IN_SET self-block.
_se_normpath() {
  local p="${1:-}"
  [ -n "$p" ] || { printf '%s' "$p"; return; }
  # Already normal (no empty, "." or ".." segment, no trailing "/"): the awk
  # pass below would print it unchanged, so skip that process.
  case "/${p#/}/" in
    *//*|*/./*|*/../*) ;;
    *) printf '%s' "$p"; return ;;
  esac
  # awk does the segment work so the '..' resolution is robust; it preserves a
  # leading '/' (absolute) and the './' / '//' / '/./' collapses lexically.
  printf '%s' "$p" | awk '
    {
      path = $0
      # remember whether the path is absolute, then split on "/".
      abs = (substr(path, 1, 1) == "/") ? 1 : 0
      n = split(path, parts, "/")
      top = 0            # stack depth of the resolved output segments
      for (i = 1; i <= n; i++) {
        seg = parts[i]
        if (seg == "" || seg == ".") {
          # empty segment (from "//" or leading/trailing "/") or "." → drop.
          continue
        }
        if (seg == "..") {
          if (top > 0 && stack[top] != "..") {
            # pop a real preceding segment (lexical X/.. resolution).
            top--
          } else if (abs) {
            # ".." at the root of an absolute path → drop (stays at root).
            continue
          } else {
            # leading ".." on a relative path has nothing to pop → keep it.
            stack[++top] = ".."
          }
          continue
        }
        stack[++top] = seg
      }
      out = ""
      for (i = 1; i <= top; i++) {
        out = (out == "") ? stack[i] : out "/" stack[i]
      }
      if (abs) {
        out = "/" out          # bare "/" survives (out == "" → just "/")
      } else if (out == "") {
        out = "."              # relative path that normalized to nothing → "."
      }
      printf "%s", out
    }
  '
}

# --- Turn-entry baseline (C01) ------------------------------------------------
# turn-baseline.sh (UserPromptSubmit) appends one line per prompt to
# <state>/<harness>.<KEY>:
#   trellis-turn-baseline v2 <nonce> <head|unborn> <sha256>
# and logs "<harness>.<KEY> <nonce>" to <state>/nonces.log. stop-verify consumes
# both at Stop and, when Stop passes (never after a block), writes the end
# state as a carry line for the next turn (trellis-turn-carry v2 ...), so a
# turn that starts without a prompt (a background notification) still has a
# baseline. Prompt lines take precedence
# over carry lines. A turn is "same" only when every line is well formed, every
# nonce is in the log, and the tree still matches every line in force; anything
# it cannot read, parse, match or recompute is "unknown". Same-uid files cannot be
# made unforgeable: an agent that deliberately rewrites both can still suppress
# the demand (accepted residual, hooks.md § stop-verify).

# _se_turn_sha256 — hash stdin in the selected utility's native output format.
# Prefer existing shasum (macOS); select before reading stdin, never retry a
# failed command against an already-consumed stream.
_se_turn_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    return 1
  fi
}

# _se_turn_state_dir <dir>
#   - prints <TRELLIS_HOME|~/.trellis>/state/turn-baseline/<16 hex of the
#     worktree's physical path>, outside any worktree, so recording a baseline
#     never dirties the tree it measures and linked worktrees stay separate.
#     Fails outside a git worktree or without TRELLIS_HOME/HOME. Creates nothing.
_se_turn_state_dir() {
  local home top sum
  if [ -n "${TRELLIS_HOME:-}" ]; then
    home="$TRELLIS_HOME"
  elif [ -n "${HOME:-}" ]; then
    home="$HOME/.trellis"
  else
    return 1
  fi
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || return 1
  top=$(CDPATH='' cd -P "$top" 2>/dev/null && pwd -P) || return 1
  sum=$(printf '%s' "$top" | _se_turn_sha256 2>/dev/null) || return 1
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || return 1
  printf '%s/state/turn-baseline/%s' "$home" "$(printf '%s' "$sum" | cut -c1-16)"
}

# _se_turn_baseline_armed <dir> <claude|codex>
#   - succeeds when the project's rendered or legacy hook settings register
#     turn-baseline.sh. Armed, an unknown baseline counts as a change on every
#     path; unarmed (not yet re-rendered), stop-verify keeps its old behaviour.
_se_turn_baseline_armed() {
  local f
  if [ "$2" = "claude" ]; then
    set -- "$1/.claude/settings.local.json" "$1/.claude/settings.json"
  else
    set -- "$1/.codex/hooks.json"
  fi
  for f in "$@"; do
    [ -f "$f" ] && grep -qF 'turn-baseline.sh' "$f" 2>/dev/null && return 0
  done
  return 1
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
# The :/ pathspec keeps the whole repository in view; the root-anchored
# excludes do not hide real changes elsewhere in .claude/.pi.
__se_hook_state_pathspec=(':/'
  ':(exclude,top).claude/.fail-counter'
  ':(exclude,top).claude/.reread-state'
  ':(exclude,top,glob).claude/.review-done-*'
  ':(exclude,top).claude/session-surgical'
  ':(exclude,top).claude/spec-gate-audit.log'
  ':(exclude,top).pi/.reread-state'
  ':(exclude,top).pi/subagent-schedules')
_se_hook_state_git() {
  git "$@" -- "${__se_hook_state_pathspec[@]}"
}

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
  paths=$( { _se_hook_state_git diff --no-ext-diff --name-only -z && _se_hook_state_git ls-files --others --exclude-standard -z; } \
    | _se_fp_classify) || exit 1
  sum=$(printf '%s\n' "$paths" | /usr/bin/env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB perl -e "$__se_fp_perl" "${2:-}" "$head" \
    git --no-optional-locks status --porcelain=v2 -z --untracked-files=all -- "${__se_hook_state_pathspec[@]}") || exit 1
  [ "${#sum}" -eq 64 ] || exit 1
  printf '%s %s\n' "$head" "$sum"
)

# _se_turn_nonce — prints 32 random hex digits, or fails.
_se_turn_nonce() {
  local n
  n=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$n" in *[!0-9a-f]*|"") return 1 ;; esac
  [ "${#n}" -eq 32 ] || return 1
  printf '%s' "$n"
}

# _se_turn_carry_write <state-dir> <harness>.<KEY> <dir>
#   - appends the current end state as a carry line (fresh nonce, logged
#     first) for the next turn. Any failure writes nothing usable, so the next
#     promptless turn reads unknown.
_se_turn_carry_write() {
  local sdir="$1" id="$2" nonce fp
  nonce=$(_se_turn_nonce) || return 0
  fp=$(_se_tree_fingerprint "$3" "$sdir/fp-cache") || return 0
  ( umask 077 && mkdir -p "$sdir" ) 2>/dev/null || return 0
  ( umask 077 && printf '%s %s\n' "$id" "$nonce" >> "$sdir/nonces.log" ) 2>/dev/null || return 0
  ( umask 077 && printf 'trellis-turn-carry v2 %s %s\n' "$nonce" "$fp" >> "$sdir/$id" ) 2>/dev/null \
    || rm -f "$sdir/$id" 2>/dev/null
  chmod 600 "$sdir/$id" "$sdir/nonces.log" 2>/dev/null
  return 0
}

# _se_turn_baseline_select <baseline-lines>
#   - prints the lines in force: the prompt lines when there are any (they take
#     precedence), else the carry lines.
_se_turn_baseline_select() {
  if printf '%s\n' "$1" | grep -q '^trellis-turn-baseline '; then
    printf '%s\n' "$1" | grep '^trellis-turn-baseline '
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
    printf '%s\n' "$nonces" | grep -qxF "$n" || { echo unknown; return; }
  done
  if _se_turn_baseline_select "$lines" | awk '{ print $4, $5 }' | grep -vqxF "$now"; then
    echo changed
  else
    echo same
  fi
}

# _se_turn_nonce_take <state-dir> <harness>.<KEY>
#   - prints the nonces logged for that baseline and removes them from the log
#     (the baseline is single use). A failed rewrite leaves stale entries,
#     which only ever match the baseline file that is deleted alongside.
_se_turn_nonce_take() {
  local log="$1/nonces.log" tmp
  [ -f "$log" ] || return 0
  awk -v k="$2" '$1 == k { print $2 }' "$log" 2>/dev/null
  tmp="$log.$$"
  if ( umask 077 && awk -v k="$2" '$1 != k' "$log" > "$tmp" ) 2>/dev/null; then
    mv -f "$tmp" "$log" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
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
#   - sends TERM to each pid and all its descendants, from one read of the
#     process table. Fails, signalling nothing, when the table is unreadable.
_se_kill_tree() {
  local table victims
  table=$(ps -A -o pid= -o ppid= 2>/dev/null) || return 1
  victims=$(printf '%s\n' "$table" | awk -v roots="$*" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      n = split(roots, q, " ")
      for (i = 1; i <= n; i++) {
        print q[i]
        m = split(kids[q[i]], c, " ")
        for (j = 1; j <= m; j++) q[++n] = c[j]
      }
    }')
  # shellcheck disable=SC2086  # one pid per word
  kill -TERM $victims 2>/dev/null
  return 0
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
  { git --no-optional-locks status --porcelain=v2 -z --ignored=matching --untracked-files=normal \
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
          # A merge conflict is never a verified state.
          exit 3 if !$ls && $r =~ /^u /;
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
#         GIT_EDITOR set to true or :
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
