#!/usr/bin/env bash
export GIT_OPTIONAL_LOCKS=0
# Stop boundary for forward-only L4/L5 decision receipts.

INPUT=$(cat 2>/dev/null || true)

# Self-contained because an infrastructure failure can include the shared lib.
# Parse the complete envelope; a nested key or message string is not the guard.
# Never run a project-supplied python shim while deciding whether to suppress a
# block. Resolve a native interpreter owned by root or this user, not writable
# by others, and outside the configured project and current working directory.
_stop_trusted_python() {
  local candidate="$1" resolve resolved info uid mode magic root physical me
  [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  if [ -x /bin/realpath ]; then resolve=/bin/realpath
  elif [ -x /usr/bin/realpath ]; then resolve=/usr/bin/realpath
  else return 1; fi
  resolved=$("$resolve" "$candidate" 2>/dev/null) || return 1
  for root in "${CLAUDE_PROJECT_DIR:-}" "${CODEX_PROJECT_DIR:-}" "$PWD"; do
    [ -n "$root" ] || continue
    physical=$("$resolve" "$root" 2>/dev/null) || continue
    if [ "$physical" = / ]; then
      if [ "$root" = "$PWD" ] && [ -n "${CLAUDE_PROJECT_DIR:-}${CODEX_PROJECT_DIR:-}" ] \
         && [ "${CLAUDE_PROJECT_DIR:-}" != "$root" ] && [ "${CODEX_PROJECT_DIR:-}" != "$root" ]; then continue; fi
      return 1
    fi
    case "$resolved/" in "$physical/"*) return 1 ;; esac
  done
  info=$(/usr/bin/stat -c '%u %a' "$resolved" 2>/dev/null) \
    || info=$(/usr/bin/stat -f '%u %Lp' "$resolved" 2>/dev/null) || return 1
  [[ "$info" =~ ^([0-9]+)[[:space:]]+([0-7]+)$ ]] || return 1
  uid=${BASH_REMATCH[1]}; mode=${BASH_REMATCH[2]}
  me=$(/usr/bin/id -u 2>/dev/null) || return 1
  [ "$uid" = 0 ] || [ "$uid" = "$me" ] || return 1
  [ "$((8#$mode & 022))" -eq 0 ] || return 1
  magic=$(/usr/bin/od -An -tx1 -N4 "$resolved" 2>/dev/null | /usr/bin/tr -d ' \n') || return 1
  case "$magic" in 7f454c46|cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca|cafebabf|bfbafeca) ;; *) return 1 ;; esac
  printf '%s' "$resolved"
}

_stop_active_raw() {
  local rc candidate python selected=""
  if [ -x /usr/bin/perl ]; then
    ( unset PERL5OPT PERL5LIB PERLLIB PERL5DB
      printf '%s' "$1" | /usr/bin/perl -MJSON::PP -0777 -e '
        my $data = eval { decode_json(<STDIN>) };
        exit 1 if $@ || ref($data) ne "HASH";
        my $active = $data->{stop_hook_active};
        exit !(defined($active) && JSON::PP::is_bool($active) && $active);
      ' 2>/dev/null
    )
    rc=$?
    case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  fi
  selected=$(type -P python3 2>/dev/null) || selected=""
  for candidate in "$selected" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    python=$(_stop_trusted_python "$candidate") || continue
    printf '%s' "$1" | "$python" -I -c '
import json, sys
def reject_constant(_):
    raise ValueError("invalid JSON constant")
try:
    data = json.loads(sys.stdin.buffer.read().decode("utf-8"), parse_constant=reject_constant)
except (ValueError, UnicodeError, RecursionError):
    sys.exit(1)
sys.exit(0 if isinstance(data, dict) and data.get("stop_hook_active") is True else 1)
' 2>/dev/null
    rc=$?
    case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  done
  # No usable parser: only this exact, unambiguous envelope is recognized.
  [ "$1" = '{"stop_hook_active":true}' ]
}

_dr_wrapper_infrastructure_block() {
  _stop_active_raw "$INPUT" && exit 0
  echo "decision-receipt: $1" >&2
  exit 2
}
DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd) || _dr_wrapper_infrastructure_block "hook directory unavailable"
CORE="$DIR/lib/decision-receipt-core.sh"
[ -r "$CORE" ] || _dr_wrapper_infrastructure_block "missing shared core — re-run sync-hooks"
# shellcheck source=lib/decision-receipt-core.sh disable=SC1091
. "$CORE" || _dr_wrapper_infrastructure_block "unable to load shared core — re-run sync-hooks"

_dr_infrastructure_block() { _dr_wrapper_infrastructure_block "$1"; }
decision_receipt_run claude <<<"$INPUT"
