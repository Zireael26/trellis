#!/bin/sh
# The source wrapper is deliberately non-authoritative. It crosses an explicit
# env -i boundary before Bash parses its body, then the body accepts only the
# canonical payload identity minted by the stable launcher after verification.
# shellcheck shell=bash
# The `#!/bin/sh` line above is a POSIX bootstrap: it does nothing but `exec` a
# clean `/bin/bash --noprofile --norc` through `env -i`, so every line of this
# file after the bootstrap is Bash and must be linted as Bash. Without this
# directive ShellCheck believed the shebang and buried ~30 real findings under
# ~250 SC30xx dialect complaints about a dialect that never runs.
#
# ShellCheck only honours `shell=` at the top of a file, so the directive covers
# the POSIX prologue too. `scripts/tests/posix-bootstrap-prologue.bats` re-checks
# each prologue as `sh` to keep that guarantee, since this line removes it here.
upgrade_home=${HOME-}
upgrade_trellis_home=${TRELLIS_HOME-}
upgrade_verified_payload=${TRELLIS_VERIFIED_PAYLOAD-}
upgrade_verified_release_version=${TRELLIS_VERIFIED_RELEASE_VERSION-}
upgrade_verified_ssh_auth_sock=${TRELLIS_VERIFIED_SSH_AUTH_SOCK-}
# shellcheck disable=SC2093  # Deliberate: the POSIX bootstrap must not continue after handing
# control to the clean Bash. Continuing here would run the body under the wrong shell.
exec /usr/bin/env -i \
  "HOME=$upgrade_home" "TRELLIS_HOME=$upgrade_trellis_home" \
  "TRELLIS_VERIFIED_PAYLOAD=$upgrade_verified_payload" \
  "TRELLIS_VERIFIED_RELEASE_VERSION=$upgrade_verified_release_version" \
  "TRELLIS_VERIFIED_SSH_AUTH_SOCK=$upgrade_verified_ssh_auth_sock" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash --noprofile --norc -c '
set -u
umask 077
upgrade_source="$1"
shift
upgrade_name="$(/usr/bin/basename "$upgrade_source")"
upgrade_source_dir="$(CDPATH= cd "$(/usr/bin/dirname "$upgrade_source")" && /bin/pwd -P)" || {
  /usr/bin/printf "%s\n" "trellis upgrade: could not resolve source wrapper" >&2
  exit 5
}
[ "$upgrade_name" = "upgrade.sh" ] &&
  [ ! -L "$upgrade_source_dir/$upgrade_name" ] &&
  [ -f "$upgrade_source_dir/$upgrade_name" ] || {
  /usr/bin/printf "%s\n" "trellis upgrade: invalid source wrapper" >&2
  exit 5
}
upgrade_bootstrap_clean_absolute_path() {
  local path="${1:-}"
  [ -n "$path" ] && [ "$path" != "/" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *[[:cntrl:]]*|*//*|*/./*|*/../*|*/.|*/..|*/) return 1 ;;
  esac
  return 0
}
upgrade_bootstrap_reject_source() {
  /usr/bin/printf "%s\n" "trellis upgrade: direct source execution is unsupported; run trellis upgrade from the installed stable launcher" >&2
  exit 2
}
upgrade_bootstrap_clean_absolute_path "${TRELLIS_HOME:-}" &&
  upgrade_bootstrap_clean_absolute_path "${TRELLIS_VERIFIED_PAYLOAD:-}" &&
  [ -n "${TRELLIS_VERIFIED_RELEASE_VERSION:-}" ] &&
  [ "${TRELLIS_VERIFIED_RELEASE_VERSION#*/}" = "${TRELLIS_VERIFIED_RELEASE_VERSION}" ] &&
  [ ! -L "$TRELLIS_VERIFIED_PAYLOAD" ] &&
  [ -d "$TRELLIS_VERIFIED_PAYLOAD" ] || upgrade_bootstrap_reject_source
upgrade_canonical_home="$(CDPATH= cd "$TRELLIS_HOME" && /bin/pwd -P)" ||
  upgrade_bootstrap_reject_source
upgrade_canonical_payload="$(CDPATH= cd "$TRELLIS_VERIFIED_PAYLOAD" && /bin/pwd -P)" ||
  upgrade_bootstrap_reject_source
[ "$upgrade_canonical_payload" = "$upgrade_canonical_home/releases/$TRELLIS_VERIFIED_RELEASE_VERSION/payload" ] &&
  [ "$upgrade_source_dir" = "$upgrade_canonical_payload/scripts" ] ||
  upgrade_bootstrap_reject_source
upgrade_body="$(/usr/bin/mktemp /tmp/trellis-upgrade.XXXXXX)" || {
  /usr/bin/printf "%s\n" "trellis upgrade: could not prepare trusted bootstrap" >&2
  exit 5
}
upgrade_cleanup() {
  /bin/rm -f "$upgrade_body"
}
trap upgrade_cleanup EXIT
trap "upgrade_cleanup; exit 129" HUP
trap "upgrade_cleanup; exit 130" INT
trap "upgrade_cleanup; exit 143" TERM
if ! /usr/bin/awk "body { print } /^# -- trellis upgrade body --\$/ { body = 1 }" "$upgrade_source_dir/$upgrade_name" > "$upgrade_body" ||
  ! /bin/test -s "$upgrade_body" ||
  ! /bin/chmod 600 "$upgrade_body"; then
  /usr/bin/printf "%s\n" "trellis upgrade: could not prepare trusted bootstrap" >&2
  exit 5
fi
/usr/bin/env -i \
  "HOME=${HOME-}" "TRELLIS_HOME=$upgrade_canonical_home" \
  "TRELLIS_VERIFIED_PAYLOAD=$upgrade_canonical_payload" \
  "TRELLIS_VERIFIED_RELEASE_VERSION=${TRELLIS_VERIFIED_RELEASE_VERSION-}" \
  "TRELLIS_VERIFIED_SSH_AUTH_SOCK=${TRELLIS_VERIFIED_SSH_AUTH_SOCK-}" \
  "TRELLIS_UPGRADE_SOURCE_DIR=$upgrade_source_dir" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash --noprofile --norc "$upgrade_body" "$@"
upgrade_status=$?
exit "$upgrade_status"
' trellis-upgrade-bootstrap "$0" "$@"

# -- trellis upgrade body --
# Explicit immutable release upgrade convenience command.
#
# This command never reads a tracked version pin, scans tags, or writes mutable
# source configuration. It installs one named annotated release, verifies the
# installed payload, then performs one explicit registry-selected adoption.

set -u

# A stable launcher may feed this body as an already verified, in-memory command
# bundle alongside the release body. A pathname execution never accepts that
# mode: the pathname bootstrap always exports TRELLIS_UPGRADE_SOURCE_DIR across
# its env -i boundary, and the bundle attestation is available only to the clean
# Bash that receives the buffered libraries and command bodies from the launcher.
upgrade_bundle_mode=false
if [ -z "${TRELLIS_UPGRADE_SOURCE_DIR:-}" ] &&
  [ "${TRELLIS_VERIFIED_COMMAND_BUNDLE:-}" = upgrade ] &&
  command -v trellis_command_bundle_is_verified >/dev/null 2>&1 &&
  trellis_command_bundle_is_verified upgrade "${TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN:-}"; then
  upgrade_bundle_mode=true
fi

upgrade_absolute_path_is_clean() {
  local path="${1:-}"
  [ -n "$path" ] && [ "$path" != "/" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\t'*|*$'\n'*|*$'\r'*|*'//'*|*/./*|*/../*|*/.|*/..|*/) return 1 ;;
  esac
  return 0
}

# Byte-identical copy of trellis_home_snapshot_payload_matches (see
# scripts/lib/trellis-home.sh for the normative definition and the reason the
# version segment must be matched whole rather than as a prefix). This gate
# decides whether this copy may run its own libraries at all, so no library is
# available to call and the body is pinned by
# scripts/tests/release-snapshot-predicate.bats instead.
upgrade_payload_matches_release() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

upgrade_requires_verified_payload() {
  local payload="${TRELLIS_VERIFIED_PAYLOAD:-}" version="${TRELLIS_VERIFIED_RELEASE_VERSION:-}"
  local home="${TRELLIS_HOME:-}" canonical_home canonical_payload expected_payload

  upgrade_absolute_path_is_clean "$home" || return 1
  upgrade_absolute_path_is_clean "$payload" || return 1
  case "$version" in ''|*/*|*$'\t'*|*$'\n'*|*$'\r'*|.*) return 1 ;; esac
  canonical_home="$(CDPATH='' cd "$home" && pwd -P)" || return 1
  [ "$canonical_home" = "$home" ] || return 1
  canonical_payload="$(CDPATH='' cd "$payload" && pwd -P)" || return 1
  [ "$canonical_payload" = "$payload" ] || return 1
  if [ "$upgrade_bundle_mode" = true ]; then
    # The launcher executes a sealed private snapshot of the configured
    # release, so the verified payload is either the installed release
    # pathname or that release's own execution snapshot — never some other
    # release-store entry.
    upgrade_payload_matches_release "$home" "$payload" "$version" ||
      return 1
  else
    expected_payload="$home/releases/$version/payload"
    [ "$payload" = "$expected_payload" ] ||
      return 1
  fi
  [ "$SCRIPT_DIR" = "$payload/scripts" ] ||
    return 1
  [ ! -L "$payload" ] && [ -d "$payload" ] &&
    [ ! -L "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR" ] &&
    [ ! -L "$SCRIPT_DIR/upgrade.sh" ] && [ -f "$SCRIPT_DIR/upgrade.sh" ]
}

if [ "$upgrade_bundle_mode" = true ]; then
  SCRIPT_DIR="${TRELLIS_VERIFIED_PAYLOAD:-}/scripts"
else
  SCRIPT_DIR="${TRELLIS_UPGRADE_SOURCE_DIR:-}"
fi
upgrade_absolute_path_is_clean "$SCRIPT_DIR" &&
  [ -d "$SCRIPT_DIR" ] &&
  [ "$(CDPATH='' cd "$SCRIPT_DIR" && pwd -P)" = "$SCRIPT_DIR" ] || {
  printf '%s\n' 'trellis upgrade: invalid installed payload script directory' >&2
  exit 5
}
upgrade_requires_verified_payload || {
  printf '%s\n' 'trellis upgrade: direct source execution is unsupported; run trellis upgrade from the installed stable launcher' >&2
  exit 2
}
RELEASE="$SCRIPT_DIR/release.sh"

# Release work runs only as verified in-memory bytes. In a bundle the release
# body is already preloaded in this shell, so install, verify, and adopt are
# called in a subshell; no release-script pathname is ever executed.
#
# stdin is the bundle itself: the launcher pipes the command carrier into
# 'bash -s', so this shell's own not-yet-executed source (the verify and adopt
# calls below) is still queued on descriptor 0. Any descendant that reads stdin
# — git prompting, a hook, jq without a file operand — would swallow that
# source. Every release call therefore runs with stdin detached.
upgrade_release_command() {
  [ "$upgrade_bundle_mode" = true ] || {
    printf '%s\n' 'trellis upgrade: verified release execution is unavailable; run trellis upgrade from the installed stable launcher' >&2
    return 2
  }
  ( release_command_main "$@" ) </dev/null
}

# Named for the shell they share: a bundle loads the release body first, so a
# bare usage/usage_error here would shadow the release command's own helpers.
upgrade_usage() {
  cat <<'EOF'
Usage:
  trellis upgrade VERSION [--remote URL] --project ID [--fleet NAME]
  trellis upgrade VERSION [--remote URL] --fleet NAME
  trellis upgrade VERSION [--remote URL] --all

VERSION is required. The command installs and verifies immutable annotated
vVERSION before adoption. --remote is optional only when TRELLIS_HOME/config.json
contains release_remote. There is no latest-tag lookup, tracked pin rewrite,
--check, --opt-in, or implicit adoption.
EOF
}

upgrade_usage_error() {
  printf 'trellis upgrade: %s\n' "$*" >&2
  upgrade_usage >&2
  return 2
}

if [ "$upgrade_bundle_mode" = true ]; then
  command -v release_command_main >/dev/null 2>&1 ||
    { printf '%s\n' 'trellis upgrade: verified command bundle is incomplete' >&2; exit 5; }
else
  [ -x "$RELEASE" ] || { printf 'trellis upgrade: release CLI is unavailable: %s\n' "$RELEASE" >&2; exit 5; }
fi

version=''
remote=''
remote_seen=false
project=''
project_seen=false
fleet=''
fleet_seen=false
all=false

if [ "$#" -eq 0 ]; then
  upgrade_usage_error 'VERSION is required'
  exit $?
fi

case "$1" in
  --help|-h) upgrade_usage; exit 0 ;;
  -*) upgrade_usage_error 'VERSION is required before options'; exit $? ;;
  *) version="$1"; shift ;;
esac

[ -n "$version" ] || { upgrade_usage_error 'VERSION is required'; exit $?; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      shift
      [ "$#" -gt 0 ] || { upgrade_usage_error '--remote requires URL'; exit $?; }
      [ "$remote_seen" = false ] || { upgrade_usage_error 'upgrade accepts one --remote'; exit $?; }
      [ -n "$1" ] || { upgrade_usage_error '--remote requires URL'; exit $?; }
      remote="$1"
      remote_seen=true
      ;;
    --remote=*)
      [ "$remote_seen" = false ] || { upgrade_usage_error 'upgrade accepts one --remote'; exit $?; }
      remote="${1#--remote=}"
      [ -n "$remote" ] || { upgrade_usage_error '--remote requires URL'; exit $?; }
      remote_seen=true
      ;;
    --project)
      shift
      [ "$#" -gt 0 ] || { upgrade_usage_error '--project requires ID'; exit $?; }
      [ "$project_seen" = false ] || { upgrade_usage_error 'upgrade accepts one --project'; exit $?; }
      [ -n "$1" ] || { upgrade_usage_error '--project requires ID'; exit $?; }
      project="$1"
      project_seen=true
      ;;
    --project=*)
      [ "$project_seen" = false ] || { upgrade_usage_error 'upgrade accepts one --project'; exit $?; }
      project="${1#--project=}"
      [ -n "$project" ] || { upgrade_usage_error '--project requires ID'; exit $?; }
      project_seen=true
      ;;
    --fleet)
      shift
      [ "$#" -gt 0 ] || { upgrade_usage_error '--fleet requires NAME'; exit $?; }
      [ "$fleet_seen" = false ] || { upgrade_usage_error 'upgrade accepts one --fleet'; exit $?; }
      [ -n "$1" ] || { upgrade_usage_error '--fleet requires NAME'; exit $?; }
      fleet="$1"
      fleet_seen=true
      ;;
    --fleet=*)
      [ "$fleet_seen" = false ] || { upgrade_usage_error 'upgrade accepts one --fleet'; exit $?; }
      fleet="${1#--fleet=}"
      [ -n "$fleet" ] || { upgrade_usage_error '--fleet requires NAME'; exit $?; }
      fleet_seen=true
      ;;
    --all)
      [ "$all" = false ] || { upgrade_usage_error 'upgrade accepts one selector'; exit $?; }
      all=true
      ;;
    --help|-h)
      upgrade_usage_error '--help cannot be combined with an upgrade request'
      exit $?
      ;;
    *)
      upgrade_usage_error "unknown upgrade option: $1"
      exit $?
      ;;
  esac
  shift
done

if [ -n "$project" ]; then
  [ "$all" = false ] || { upgrade_usage_error '--all cannot be combined with --project'; exit $?; }
elif [ -n "$fleet" ]; then
  [ "$all" = false ] || { upgrade_usage_error '--all cannot be combined with --fleet'; exit $?; }
elif [ "$all" = false ]; then
  upgrade_usage_error 'upgrade requires --project, --fleet, or --all'
  exit $?
fi

install_args=(install "$version")
if [ -n "$remote" ]; then
  install_args+=(--remote "$remote")
fi
upgrade_release_command "${install_args[@]}" || exit $?
upgrade_release_command verify "$version" || exit $?

adopt_args=(adopt "$version")
if [ -n "$project" ]; then
  adopt_args+=(--project "$project")
  [ -z "$fleet" ] || adopt_args+=(--fleet "$fleet")
elif [ -n "$fleet" ]; then
  adopt_args+=(--fleet "$fleet")
else
  adopt_args+=(--all)
fi
upgrade_release_command "${adopt_args[@]}"
exit $?
