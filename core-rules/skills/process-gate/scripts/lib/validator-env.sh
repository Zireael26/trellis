# shellcheck shell=bash
# Loaded through BASH_ENV into every stack validator run-all.sh runs, and into
# the bash processes those validators start. Not for direct use.
#
# A validator may source code only from the trusted roots run-all.sh sets for
# it: PG_TRUSTED_ROOT (the range base's materialised validator tree and
# declared dependencies) or PG_SKILL_ROOT (this skill). A missing file, a
# symlink, or a file outside those roots — a cwd-relative or project helper —
# fails the validator at once instead of letting it run code from the range
# under review or carry on without its helper.
#
# Supported helper API (bash 3.2 cannot hand a wrapper its caller's
# positional parameters):
#   - `. file args...` / `source file args...` behave natively.
#   - `. file` / `source file` with no arguments gives the sourced file the
#     validator's own arguments (`--range=<range>`, from PG_GATE_RANGE), as at
#     the validator's top level. Inside a function, or after `set --`/`shift`,
#     pass the arguments explicitly.
#   - The file runs in the caller's variable scope: the wrapper declares no
#     locals, so the sourced code's assignments land where native source would
#     put them. It can also see one global, __pg_vs_path. A sourced file's own
#     `set --`/`shift` does not reach the caller.
# Not intercepted: `builtin source`, `builtin .`, `command .`, helpers that a
# validator executes rather than sources, and other interpreters. Those are
# the reviewed-code boundary (see SKILL.md and LB-6).
# Toolchain programs outside the trusted roots and the checkout are not
# guarded at all (see pg_validator_guarded).

# pg_validator_path <file>: print the physical path of a trusted file to
# source; on refusal print why (stderr) and fail. Runs in a subshell.
pg_validator_path() {
  local file="${1:-}" dir name phys root
  case "$file" in
    */*) dir="${file%/*}"; name="${file##*/}"; [ -n "$dir" ] || dir=/ ;;
    *) dir=.; name="$file" ;;
  esac
  if [ -z "$name" ] || ! phys="$(cd -P "$dir" 2>/dev/null && pwd -P)" ||
     [ ! -f "$phys/$name" ] || [ -L "$phys/$name" ]; then
    printf 'fail: validator dependency %s is missing from the trusted validator tree\n' "$file" >&2
    return 1
  fi
  for root in "${PG_TRUSTED_ROOT:-}" "${PG_SKILL_ROOT:-}"; do
    [ -n "$root" ] || continue
    root="$(cd -P "$root" 2>/dev/null && pwd -P)" || continue
    case "$phys/" in
      "$root"/*) printf '%s\n' "$phys/$name"; return 0 ;;
    esac
  done
  printf 'fail: validator dependency %s is outside the trusted validator tree\n' "$file" >&2
  return 1
}

# No locals here: the sourced file must see the caller's variables, not ours.
# The positional parameters are set to what the sourced file should see and
# the file is sourced with none, so it gets exactly those. The one global it
# can also see is __pg_vs_path, the path being sourced.
pg_validator_source() {
  __pg_vs_path="$(pg_validator_path "${1:-}")" || exit 1
  if [ "$#" -gt 1 ]; then
    shift
  elif [ -n "${PG_GATE_RANGE:-}" ]; then
    set -- "--range=$PG_GATE_RANGE"
  else
    set --
  fi
  builtin source "$__pg_vs_path"
}

# pg_validator_guarded: true when this bash process runs validator or project
# code, which is what the guard polices: a script inside a trusted root or the
# checkout under review, or inline code (`bash -c`, stdin) a validator started.
# A program from the toolchain outside all of those, such as the bash program
# behind a pyenv shim sourcing its own pyenv.d hooks, is left alone.
pg_validator_guarded() {
  local self="$0" phys root
  case "$self" in */*) ;; *) return 0 ;; esac
  [ -f "$self" ] || return 0
  phys="$(cd -P "${self%/*}" 2>/dev/null && pwd -P)" || return 0
  phys="$phys/${self##*/}"
  for root in "${PG_TRUSTED_ROOT:-}" "${PG_SKILL_ROOT:-}" "${PROCESS_GATE_PROJECT_DIR:-}"; do
    [ -n "$root" ] || continue
    root="$(cd -P "$root" 2>/dev/null && pwd -P)" || continue
    case "$phys" in "$root"/*) return 0 ;; esac
  done
  return 1
}

if pg_validator_guarded; then
  source() { pg_validator_source "$@"; }
  .() { pg_validator_source "$@"; }
fi
