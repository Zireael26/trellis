#!/usr/bin/env bash
# trellis heavy — a machine-wide slot gate for heavy test runs (spec 054).
#
#   trellis heavy [--light] [--lane NAME] [--timeout SECONDS] -- <cmd...>
#   trellis heavy --check     exit 0 when the config is usable, 78 otherwise
#   trellis heavy --status    list every slot of both pools, retired included
#
# Waits for one of N slots (`heavy_slots` in $TRELLIS_HOME/config.json, default
# 2; with --light, one of `heavy_light_slots`, default 4), runs the command in its own process group, and holds the slot until that
# whole group has exited. --timeout counts from launch, not from the wait. This
# file validates the argument shape and then execs the perl supervisor, which
# never returns; see scripts/lib/heavy-supervisor.pl for the lock and teardown.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SUPERVISOR="$SCRIPT_DIR/lib/heavy-supervisor.pl"

usage() {
  cat <<'EOF'
Usage: trellis heavy [--light] [--lane NAME] [--timeout SECONDS] -- <cmd...>
       trellis heavy --check
       trellis heavy --status

Runs <cmd> once one of the machine's heavy slots is free, and holds the slot
until every process in the command's process group has exited.

  --light            use the light pool (heavy_light_slots, default 4): single-file
                     or targeted runs expected under 2 minutes; a light run that
                     passes 120 s prints one advisory line and keeps running
  --lane NAME        label shown to waiting callers (letters, digits, . _ -)
  --timeout SECONDS  TERM the workload this long after launch (then KILL after
                     TRELLIS_HEAVY_KILL_AFTER, default 10); exit 124
  --check            validate heavy_slots and the slot directory; exit 78 if not
  --status           show each slot of both pools, including retired slots

Exit: the command's status; 128+N when interrupted by signal N; 124 on timeout;
2 on a usage error; 78 on a configuration error.
EOF
}

usage_error() {
  printf 'trellis heavy: %s\n' "$1" >&2
  printf 'trellis heavy: run: trellis heavy --help\n' >&2
  exit 2
}

mode=run
pool=heavy
lane=-
timeout=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) mode=check; shift ;;
    --status) mode=status; shift ;;
    --light) pool=light; shift ;;
    --lane)
      [ "$#" -ge 2 ] || usage_error '--lane requires a value'
      lane="$2"; shift 2 ;;
    --lane=*) lane="${1#--lane=}"; shift ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error '--timeout requires a value'
      timeout="$2"; shift 2 ;;
    --timeout=*) timeout="${1#--timeout=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) usage_error "unexpected argument: $1 (put the command after --)" ;;
  esac
done

[[ "$lane" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || usage_error "invalid --lane: $lane"
[[ "$timeout" =~ ^[0-9]{1,7}$ ]] || usage_error "--timeout must be a whole number of seconds: $timeout"
case "$mode" in
  run) [ "$#" -gt 0 ] || usage_error 'a command is required after --' ;;
  *)
    [ "$#" -eq 0 ] || usage_error "--$mode takes no command"
    [ "$pool" = heavy ] || usage_error "--$mode covers both pools; drop --light"
    ;;
esac

# The stable launcher starts every command under `env -i`. The heavy route is
# the one that must hand the caller's environment to the wrapped command, so a
# launcher that predates it would silently strip PATH, DOCKER_HOST and the rest.
if [ -n "${TRELLIS_VERIFIED_PAYLOAD:-}" ] && [ -z "${TRELLIS_HEAVY_CALLER_ENV+x}" ]; then
  printf '%s\n' 'trellis heavy: the installed launcher predates trellis heavy and drops the caller environment; reinstall it with trellis configure' >&2
  exit 78
fi

command -v perl >/dev/null 2>&1 || {
  printf '%s\n' 'trellis heavy: perl is required' >&2
  exit 5
}
if [ "$mode" = run ]; then
  exec perl -- "$SUPERVISOR" run "$pool" "$lane" "$timeout" "$@"
fi
exec perl -- "$SUPERVISOR" "$mode"
