#!/usr/bin/env bash
# Resolve a real CPython for hooks without a Python start on the hot path.
#
# Public function:
#   trellis_python   sets and exports TRELLIS_PYTHON to an absolute python3;
#                    returns 1 when no candidate runs
#
# A version-manager shim (pyenv, asdf and mise put python3 in a shims/
# directory) re-resolves the version in bash on every call: about 0.4 s against
# about 20 ms for the real binary (spec 072, B4 §1). So the order is:
#   1. TRELLIS_PYTHON when it is already an absolute executable file: an
#      operator override, or the resolution an ancestor hook exported;
#   2. the choice cached in $TRELLIS_HOME/state/python, when it passes the
#      trust check below;
#   3. /opt/homebrew/bin/python3, /usr/local/bin/python3, /usr/bin/python3
#      (TRELLIS_PYTHON_CANDIDATES, colon-separated, replaces this list);
#   4. the first python3 in an absolute PATH entry that is not a shims/ dir;
#   5. a shim, last, so a host whose only python3 is a shim still works.
#
# Steps 3-5 run only on a cache miss: each existing candidate is probed once
# with `--version` under a 5 s alarm, so the macOS /usr/bin/python3 install
# stub (no Command Line Tools) is skipped. A step-3 candidate must first pass
# the interpreter half of the trust check below, so one owned by another user
# or writable by others is skipped unrun. Only a step-3 choice is cached (temp
# file + mv, 0600), and only into an existing state directory. A PATH or shim
# result serves this process alone: one process's PATH never becomes every
# later hook's interpreter.
#
# The cache is used only when it names a step-3 candidate, the cache file is a
# regular 0600 file owned by this user, and every link on the way to the
# interpreter and the interpreter itself are owned by root or this user, with
# the interpreter not group- or other-writable. That check is one perl start
# (about 4 ms); without perl the cache is ignored and step 3 is skipped.
#
# Bash 3.2 compatible; sourcing this file has no side effects.

# _trellis_python_take <candidate> <cache-or-empty> — probe; on success export
# it and, given a cache path, persist it. Status 1 when it does not run.
_trellis_python_take() {
  local candidate="$1" cache="$2" tmp
  [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  if command -v perl >/dev/null 2>&1; then
    # alarm survives exec: a hung interpreter dies of SIGALRM.
    perl -e 'alarm shift; exec @ARGV or exit 127' 5 "$candidate" --version >/dev/null 2>&1 || return 1
  else
    # Unbounded without perl; hooks already need perl for guard-supervise.pl.
    "$candidate" --version >/dev/null 2>&1 || return 1
  fi
  TRELLIS_PYTHON="$candidate"
  export TRELLIS_PYTHON
  [ -n "$cache" ] || return 0
  tmp="$cache.$$.tmp"
  ( umask 077 && printf '%s\n' "$candidate" >"$tmp" && mv -f "$tmp" "$cache" ) 2>/dev/null ||
    rm -f "$tmp" 2>/dev/null
  return 0
}

# _trellis_python_trusted <cache-or-empty> <interpreter> [<cache-uid> <owner-uid>]
# — the ownership and mode check described above; an empty cache checks the
# interpreter alone. Status 0 only when every condition holds. The uids default
# to this user's effective uid from perl's $>: bash's $EUID is taken from an
# inherited environment, so it is never used. trellis_python never passes them;
# tests pass another to reach the foreign-owner branches.
_trellis_python_trusted() {
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    my ($cache, $path, $cache_uid, $uid) = (@ARGV, $>, $>);
    if ($cache ne "") {
      my @c = lstat $cache or exit 1;
      exit 1 unless -f _ && $c[4] == $cache_uid && ($c[2] & 07777) == 0600;
    }
    for (my $hops = 0; -l $path; $hops++) {
      my @l = lstat $path or exit 1;
      exit 1 unless $l[4] == 0 || $l[4] == $uid;
      exit 1 if $hops > 40;
      my $next = readlink $path;
      defined $next or exit 1;
      if ($next !~ m{^/}) { (my $dir = $path) =~ s{/[^/]*\z}{}; $next = "$dir/$next"; }
      $path = $next;
    }
    my @t = stat $path or exit 1;
    exit 1 unless -f _ && -x _ && ($t[4] == 0 || $t[4] == $uid) && !($t[2] & 022);
    exit 0;
  ' "$@" 2>/dev/null
}

trellis_python() {
  local home cache="" cached="" candidates candidate dir rest shims=""
  case "${TRELLIS_PYTHON:-}" in
    /*)
      if [ -f "$TRELLIS_PYTHON" ] && [ -x "$TRELLIS_PYTHON" ]; then
        export TRELLIS_PYTHON
        return 0
      fi
      ;;
  esac
  candidates="${TRELLIS_PYTHON_CANDIDATES:-/opt/homebrew/bin/python3:/usr/local/bin/python3:/usr/bin/python3}"
  home="${TRELLIS_HOME:-}"
  if [ -z "$home" ] && [ -n "${HOME:-}" ]; then home="$HOME/.trellis"; fi
  case "$home" in
    /*) if [ -d "$home/state" ] && [ ! -L "$home/state" ]; then cache="$home/state/python"; fi ;;
  esac
  if [ -n "$cache" ] && [ -f "$cache" ] && [ ! -L "$cache" ]; then
    IFS= read -r cached <"$cache" || cached=""
    case "$cached" in
      /*)
        case ":$candidates:" in
          *":$cached:"*)
            if [ -f "$cached" ] && [ -x "$cached" ] && _trellis_python_trusted "$cache" "$cached"; then
              TRELLIS_PYTHON="$cached"
              export TRELLIS_PYTHON
              return 0
            fi
            ;;
        esac
        ;;
    esac
  fi

  rest="$candidates:"
  while [ -n "$rest" ]; do
    candidate="${rest%%:*}"
    rest="${rest#*:}"
    case "$candidate" in /*) ;; *) continue ;; esac
    [ -f "$candidate" ] && _trellis_python_trusted "" "$candidate" || continue
    _trellis_python_take "$candidate" "$cache" && return 0
  done
  # Relative entries (an empty one means the cwd) are never searched.
  rest="${PATH:-}:"
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"
    rest="${rest#*:}"
    case "$dir" in /*) ;; *) continue ;; esac
    candidate="${dir%/}/python3"
    case "${dir%/}" in
      */shims) shims="$shims$candidate:" ;;
      *) _trellis_python_take "$candidate" "" && return 0 ;;
    esac
  done
  while [ -n "$shims" ]; do
    candidate="${shims%%:*}"
    shims="${shims#*:}"
    _trellis_python_take "$candidate" "" && return 0
  done
  return 1
}
