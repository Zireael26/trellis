#!/bin/sh
# The source wrapper is deliberately non-authoritative. It crosses an explicit
# env -i boundary before Bash parses its body, then admits only the canonical
# payload identity minted by the stable launcher after release verification.
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
mirror_bootstrap_home=${HOME-}
mirror_bootstrap_trellis_home=${TRELLIS_HOME-}
mirror_bootstrap_payload=${TRELLIS_VERIFIED_PAYLOAD-}
mirror_bootstrap_release_version=${TRELLIS_VERIFIED_RELEASE_VERSION-}
mirror_bootstrap_ssh_auth_sock=${TRELLIS_VERIFIED_SSH_AUTH_SOCK-}
# Carry ambient TMPDIR only as untrusted data until containment admission.
mirror_bootstrap_scratch=${TMPDIR-}
# shellcheck disable=SC2093  # nothing after this exec runs in the outer shell:
# the trusted body below the marker is read as DATA by the re-exec'd bootstrap.
exec /usr/bin/env -i \
  "HOME=$mirror_bootstrap_home" "TRELLIS_HOME=$mirror_bootstrap_trellis_home" \
  "TRELLIS_VERIFIED_PAYLOAD=$mirror_bootstrap_payload" \
  "TRELLIS_VERIFIED_RELEASE_VERSION=$mirror_bootstrap_release_version" \
  "TRELLIS_VERIFIED_SSH_AUTH_SOCK=$mirror_bootstrap_ssh_auth_sock" \
  "TRELLIS_MIRROR_SCRATCH_CANDIDATE=$mirror_bootstrap_scratch" \
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash --noprofile --norc -c '
set -u
umask 077
mirror_source="$1"
shift
case "$mirror_source" in
  /*) ;;
  *) mirror_source="$(/bin/pwd -P)/$mirror_source" ;;
esac
mirror_source_name="$(/usr/bin/basename "$mirror_source")"
mirror_source_dir="$(CDPATH= cd "$(/usr/bin/dirname "$mirror_source")" && /bin/pwd -P)" || {
  /usr/bin/printf "%s\n" "trellis mirror: could not resolve source wrapper" >&2
  exit 5
}
[ "$mirror_source_name" = "sync-to-template.sh" ] &&
  [ ! -L "$mirror_source_dir/$mirror_source_name" ] &&
  [ -f "$mirror_source_dir/$mirror_source_name" ] || {
  /usr/bin/printf "%s\n" "trellis mirror: invalid source wrapper" >&2
  exit 5
}
mirror_bootstrap_clean_absolute_path() {
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
# Byte-identical copy of trellis_home_snapshot_payload_matches (see
# scripts/lib/trellis-home.sh for the normative definition and the reason the
# version segment must be matched whole rather than as a prefix). This gate
# runs before the bootstrap re-execs into the verified payload, so no library
# is available to call and the body is pinned by
# scripts/tests/release-snapshot-predicate.bats instead.
mirror_bootstrap_payload_matches() {
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
mirror_bootstrap_reject_source() {
  /usr/bin/printf "%s\n" "trellis mirror: direct source execution is unsupported; run trellis mirror from the installed stable launcher" >&2
  exit 2
}
mirror_bootstrap_clean_absolute_path "${TRELLIS_HOME:-}" &&
  mirror_bootstrap_clean_absolute_path "${TRELLIS_VERIFIED_PAYLOAD:-}" &&
  [ -n "${TRELLIS_VERIFIED_RELEASE_VERSION:-}" ] &&
  [ "${TRELLIS_VERIFIED_RELEASE_VERSION#*/}" = "${TRELLIS_VERIFIED_RELEASE_VERSION}" ] &&
  [ ! -L "$TRELLIS_VERIFIED_PAYLOAD" ] &&
  [ -d "$TRELLIS_VERIFIED_PAYLOAD" ] || mirror_bootstrap_reject_source
mirror_canonical_home="$(CDPATH= cd "$TRELLIS_HOME" && /bin/pwd -P)" ||
  mirror_bootstrap_reject_source
mirror_canonical_payload="$(CDPATH= cd "$TRELLIS_VERIFIED_PAYLOAD" && /bin/pwd -P)" ||
  mirror_bootstrap_reject_source
mirror_bootstrap_payload_matches "$mirror_canonical_home" "$mirror_canonical_payload" "$TRELLIS_VERIFIED_RELEASE_VERSION" &&
  [ "$mirror_source_dir" = "$mirror_canonical_payload/scripts" ] ||
  mirror_bootstrap_reject_source
# No library is sourced yet. Keep this containment predicate equivalent to
# release_entry_private_directory/release_entry_scratch_is_admissible.
# Admission proves private ownership and containment, NOT launcher authentication.
mirror_bootstrap_private_directory() {
  local path="${1:-}" permissions private_bits listing
  [ -n "$path" ] && [ ! -L "$path" ] && [ -d "$path" ] && [ -O "$path" ] || return 1
  case "$(/usr/bin/uname -s)" in
    Darwin)
      # Extended attributes can hide the ACL marker behind @. Read ACL rows,
      # not just the mode suffix; canonical input paths contain no newlines.
      listing="$(LC_ALL=C /bin/ls -lde "$path" 2>/dev/null)" || return 1
      case "$listing" in *"
"*) return 1 ;; esac
      ;;
    *) listing="$(LC_ALL=C /bin/ls -ld "$path" 2>/dev/null)" || return 1 ;;
  esac
  permissions="${listing%% *}"
  case "$permissions" in *+*) return 1 ;; esac
  private_bits="$(/usr/bin/printf "%s" "$permissions" | /usr/bin/awk "{p=substr(\$0, 1, 10); print substr(p, 5, 6)}")"
  [ "$private_bits" = "------" ]
}
mirror_bootstrap_scratch_is_admissible() {
  local candidate="${1:-}" home="${2:-}" root parent base canonical_root canonical_candidate
  mirror_bootstrap_clean_absolute_path "$candidate" &&
    mirror_bootstrap_clean_absolute_path "$home" || return 1
  parent="${candidate%/*}"
  base="${candidate##*/}"
  case "$base" in .cmd.?*) ;; *) return 1 ;; esac
  case "${base#.cmd.}" in *[!0-9A-Za-z._-]*) return 1 ;; esac
  root="$home/state/scratch"
  [ "$parent" = "$root" ] || return 1
  mirror_bootstrap_private_directory "$home" &&
    mirror_bootstrap_private_directory "$home/state" &&
    mirror_bootstrap_private_directory "$root" &&
    mirror_bootstrap_private_directory "$candidate" || return 1
  canonical_root="$(CDPATH= cd "$root" && /bin/pwd -P)" || return 1
  [ "$canonical_root" = "$root" ] || return 1
  canonical_candidate="$(CDPATH= cd "$candidate" && /bin/pwd -P)" || return 1
  [ "$canonical_candidate" = "$candidate" ]
}
mirror_bootstrap_scratch_is_admissible "${TRELLIS_MIRROR_SCRATCH_CANDIDATE:-}" "$mirror_canonical_home" || {
  /usr/bin/printf "%s\n" "trellis mirror: command scratch directory is missing or not an admissible private Trellis temp directory" >&2
  exit 4
}
export TMPDIR="$TRELLIS_MIRROR_SCRATCH_CANDIDATE"
unset TRELLIS_MIRROR_SCRATCH_CANDIDATE
export TRELLIS_HOME="$mirror_canonical_home"
export TRELLIS_VERIFIED_PAYLOAD="$mirror_canonical_payload"
export TRELLIS_MIRROR_SOURCE_DIR="$mirror_source_dir"
# Capture must finish successfully before any body command runs. This shell is
# already clean; builtin eval avoids a global tempfile and preserves caller stdin.
if ! mirror_body="$(/usr/bin/awk "body { print } /^# -- trellis mirror body --\$/ { body = 1 }" "$mirror_source_dir/$mirror_source_name")" ||
  [ -z "$mirror_body" ]; then
  /usr/bin/printf "%s\n" "trellis mirror: could not prepare trusted bootstrap" >&2
  exit 5
fi
# Keep eval last: the body owns exit status and traps, with set -u and umask 077.
eval "$mirror_body"
' trellis-mirror-bootstrap "$0" "$@"

# -- trellis mirror body --
# Publish portable Trellis policy and tools to a public mirror.
#
# This command has publication authority only when the stable launcher has
# already verified an immutable installed release. A source checkout is never
# executed or sourced: its mutable bytes are not an input to publication.

set -euo pipefail
unset BASH_ENV ENV CDPATH
PATH='/usr/bin:/bin:/usr/sbin:/sbin'
export PATH

PAYLOAD_ROOT="${TRELLIS_VERIFIED_PAYLOAD:-}"
RELEASE_VERSION="${TRELLIS_VERIFIED_RELEASE_VERSION:-}"
TRELLIS_HOME_ROOT="${TRELLIS_HOME:-}"
[ -n "$PAYLOAD_ROOT" ] && [ -n "$RELEASE_VERSION" ] && [ -n "$TRELLIS_HOME_ROOT" ] || {
  printf 'trellis mirror: run trellis mirror from the verified stable launcher\n' >&2
  exit 2
}
case "$RELEASE_VERSION" in
  *$'\t'*|*$'\n'*|*$'\r'*|*'/'*|'.'|'..'|'')
    printf 'trellis mirror: run trellis mirror from the verified stable launcher\n' >&2
    exit 2
    ;;
esac
TRELLIS_HOME_ROOT="$(CDPATH='' cd -P -- "$TRELLIS_HOME_ROOT" && pwd -P)" || {
  printf 'trellis mirror: verified Trellis home is unavailable\n' >&2
  exit 5
}
PAYLOAD_ROOT="$(CDPATH='' cd -P -- "$PAYLOAD_ROOT" && pwd -P)" || {
  printf 'trellis mirror: verified release payload is unavailable\n' >&2
  exit 5
}
# Byte-identical copy of trellis_home_snapshot_payload_matches (see
# scripts/lib/trellis-home.sh for the normative definition and the reason the
# version segment must be matched whole rather than as a prefix). The mirror
# body re-decides the question the bootstrap already decided, in the separate
# process the bootstrap re-exec'd into, and it does so before it sources any
# library — so this is a second copy inside the same file, pinned by
# scripts/tests/release-snapshot-predicate.bats alongside the bootstrap's.
mirror_payload_matches_release() {
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
mirror_payload_is_verified_location() {
  mirror_payload_matches_release \
    "$TRELLIS_HOME_ROOT" "$PAYLOAD_ROOT" "$RELEASE_VERSION"
}
mirror_payload_is_verified_location || {
  printf 'trellis mirror: run trellis mirror from the verified stable launcher\n' >&2
  exit 2
}
SCRIPT_DIR="${TRELLIS_MIRROR_SOURCE_DIR:-}"
unset TRELLIS_MIRROR_SOURCE_DIR
case "$SCRIPT_DIR" in
  /*) ;;
  *)
    printf 'trellis mirror: verified release script directory is unavailable\n' >&2
    exit 5
    ;;
esac
[ -d "$SCRIPT_DIR" ] && [ ! -L "$SCRIPT_DIR" ] &&
  [ "$(CDPATH='' cd -P -- "$SCRIPT_DIR" && pwd -P)" = "$SCRIPT_DIR" ] &&
  [ "$SCRIPT_DIR" = "$PAYLOAD_ROOT/scripts" ] || {
  printf 'trellis mirror: run trellis mirror from the verified stable launcher\n' >&2
  exit 2
}
[ -f "$PAYLOAD_ROOT/../release.json" ] && [ ! -L "$PAYLOAD_ROOT/../release.json" ] || {
  printf 'trellis mirror: verified release record is unavailable\n' >&2
  exit 5
}
[ -f "$PAYLOAD_ROOT/../release.json" ] && [ ! -L "$PAYLOAD_ROOT/../release.json" ] || {
  printf 'trellis mirror: verified release record is unavailable\n' >&2
  exit 5
}

SOURCE_COMMIT_MATCH="$(/usr/bin/grep -oE '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' \
  "$PAYLOAD_ROOT/../release.json" 2>/dev/null || true)"
SOURCE_COMMIT="$(printf '%s\n' "$SOURCE_COMMIT_MATCH" | /usr/bin/sed -E 's/.*"([0-9a-f]{40})"/\1/')"
case "$SOURCE_COMMIT" in
  ''|*[!0-9a-f]*)
    printf 'trellis mirror: verified release commit identity is invalid\n' >&2
    exit 5
    ;;
esac
[ "${#SOURCE_COMMIT}" -eq 40 ] || {
  printf 'trellis mirror: verified release commit identity is invalid\n' >&2
  exit 5
}

mirror_git() {
  local home="${HOME:-/}"
  /usr/bin/env -i \
    "HOME=$home" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "GIT_CONFIG_NOSYSTEM=1" \
    "GIT_CONFIG_GLOBAL=/dev/null" \
    "GIT_CONFIG_COUNT=6" \
    "GIT_CONFIG_KEY_0=core.fsmonitor" \
    "GIT_CONFIG_VALUE_0=false" \
    "GIT_CONFIG_KEY_1=core.hooksPath" \
    "GIT_CONFIG_VALUE_1=/dev/null" \
    "GIT_CONFIG_KEY_2=core.sshCommand" \
    "GIT_CONFIG_VALUE_2=" \
    "GIT_CONFIG_KEY_3=credential.helper" \
    "GIT_CONFIG_VALUE_3=" \
    "GIT_CONFIG_KEY_4=protocol.ext.allow" \
    "GIT_CONFIG_VALUE_4=never" \
    "GIT_CONFIG_KEY_5=protocol.file.allow" \
    "GIT_CONFIG_VALUE_5=never" \
    /usr/bin/git "$@"
}

# Twin of launcher_verified_ssh_auth_sock (scripts/trellis-launcher.sh): the
# launcher mints the marker, this re-derives it rather than trusting it. Only
# the spelling of the path may differ — a symlinked directory above the socket
# is fine (stock macOS spells it /var/run/..., and /var is a symlink), but the
# socket itself must be a real socket, must not be a symlink, and the resolved
# path must name the same file. The canonical spelling is what gets pushed with.
mirror_require_verified_ssh_socket() {
  local socket="${TRELLIS_VERIFIED_SSH_AUTH_SOCK:-}" parent base canonical
  case "$socket" in
    /*) ;;
    *)
      printf 'trellis mirror: --push requires a verified SSH agent socket\n' >&2
      return 5
      ;;
  esac
  case "$socket" in
    *[[:cntrl:]]*|*//*|*/./*|*/../*|*/.|*/..|*/)
      printf 'trellis mirror: --push requires a verified SSH agent socket\n' >&2
      return 5
      ;;
  esac
  [ -S "$socket" ] && [ ! -L "$socket" ] || {
    printf 'trellis mirror: --push requires a verified SSH agent socket\n' >&2
    return 5
  }
  parent="${socket%/*}"
  base="${socket##*/}"
  [ -n "$parent" ] && [ -n "$base" ] || {
    printf 'trellis mirror: --push requires a verified SSH agent socket\n' >&2
    return 5
  }
  canonical="$(CDPATH='' cd -P -- "$parent" && pwd -P)/$base" || return 5
  [ -S "$canonical" ] && [ ! -L "$canonical" ] &&
    [ "$canonical" -ef "$socket" ] || {
    printf 'trellis mirror: --push requires a verified SSH agent socket\n' >&2
    return 5
  }
  printf '%s\n' "$canonical"
}

mirror_git_push() {
  local socket="$1"
  shift
  /usr/bin/env -i \
    "HOME=${HOME:-/}" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "SSH_AUTH_SOCK=$socket" \
    "GIT_CONFIG_NOSYSTEM=1" \
    "GIT_CONFIG_GLOBAL=/dev/null" \
    "GIT_CONFIG_COUNT=7" \
    "GIT_CONFIG_KEY_0=core.fsmonitor" \
    "GIT_CONFIG_VALUE_0=false" \
    "GIT_CONFIG_KEY_1=core.hooksPath" \
    "GIT_CONFIG_VALUE_1=/dev/null" \
    "GIT_CONFIG_KEY_2=core.sshCommand" \
    "GIT_CONFIG_VALUE_2=/usr/bin/ssh -oBatchMode=yes" \
    "GIT_CONFIG_KEY_3=credential.helper" \
    "GIT_CONFIG_VALUE_3=" \
    "GIT_CONFIG_KEY_4=protocol.ext.allow" \
    "GIT_CONFIG_VALUE_4=never" \
    "GIT_CONFIG_KEY_5=protocol.file.allow" \
    "GIT_CONFIG_VALUE_5=never" \
    "GIT_CONFIG_KEY_6=credential.useHttpPath" \
    "GIT_CONFIG_VALUE_6=true" \
    /usr/bin/git "$@"
}

# shellcheck source=lib/mirror-lint.sh
. "$SCRIPT_DIR/lib/mirror-lint.sh"

usage() {
  cat <<'EOF'
Usage:
  trellis mirror --template-dir PATH [--dry-run|--apply|--push]

Stages portable policy/tools from the verified immutable release into PATH.
--dry-run is the default and validates a simulated post-sync mirror without
changing PATH. --apply writes only after staged and simulated whole-tree lint
passes. --push also offers an interactive commit and push after apply.
EOF
}

mirror_require_real_root() {
  local root="${1:-}" remaining component current="/" canonical
  case "$root" in
    /*) ;;
    *)
      printf 'trellis mirror: template directory must be an absolute canonical path: %s\n' "$root" >&2
      return 2
      ;;
  esac
  case "$root" in
    ''|*'//'|*$'\t'*|*$'\n'*|*$'\r'*|*/./*|*/../*|*/.|*/..)
      printf 'trellis mirror: template directory must be an absolute canonical path: %s\n' "$root" >&2
      return 2
      ;;
  esac
  while [ "${root%/}" != "$root" ] && [ "$root" != "/" ]; do root="${root%/}"; done
  remaining="${root#/}"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    current="${current%/}/$component"
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
      printf 'trellis mirror: template directory has a symlink or non-directory ancestor: %s\n' "$current" >&2
      return 4
    fi
    [ -d "$current" ] || {
      printf 'trellis mirror: template directory is unavailable: %s\n' "$current" >&2
      return 5
    }
  done
  canonical="$(CDPATH='' cd "$root" && pwd -P)" || return 5
  [ "$canonical" = "$root" ] || {
    printf 'trellis mirror: template directory is not canonical: %s\n' "$root" >&2
    return 4
  }
  printf '%s\n' "$canonical"
}

apply=false
push=false
template_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) apply=false; push=false ;;
    --apply) apply=true; push=false ;;
    --push) apply=true; push=true ;;
    --template-dir)
      shift
      [ "$#" -gt 0 ] || { printf 'trellis mirror: --template-dir requires PATH\n' >&2; exit 2; }
      template_dir="$1"
      ;;
    --template-dir=*) template_dir="${1#--template-dir=}" ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'trellis mirror: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$template_dir" ] || {
  printf 'trellis mirror: --template-dir PATH is required\n' >&2
  exit 2
}
template_dir="$(mirror_require_real_root "$template_dir")" || exit "$?"
[ -d "$template_dir/.git" ] && [ ! -L "$template_dir/.git" ] || {
  printf 'trellis mirror: template repository not found at %s\n' "$template_dir" >&2
  exit 5
}
if "$push" && [ -n "$(mirror_git -C "$template_dir" status --porcelain=v1 --untracked-files=all)" ]; then
  printf 'trellis mirror: --push requires a clean template checkout before publication\n' >&2
  exit 3
fi

# Positive publication allowlist. A payload path must be deliberately listed to
# become public; state directories are absent by design.
sync_paths=(
  'engineering-process.md'
  'AGENT_SETUP.md'
  'AGENT_UPGRADE.md'
  'AGENT_ONBOARD_PROJECT.md'
  'AGENT_PI_SETUP.md'
  'docs/PI-COMPUTER-USE.md'
  'docs/PI-COMPUTER-USE-UPGRADE-PROMPT.md'
  'CHANGELOG.md'
  'dependency-baseline.json'
  'audits/fleet-remediation-ledger.json'
  'docs/local-development-infrastructure.md'
  'core-rules/CLAUDE.md'
  'core-rules/AGENTS.md'
  'core-rules/agents/'
  'core-rules/VERSION'
  'core-rules/codex/'
  # The portable pi surface: extension, hook dispatcher, version-pinned patch
  # bundle and its tests. `core-rules/pi/agents` is carved back out below --
  # only the roster is private, and the rest of the subtree is the machinery a
  # mirror user needs to install pi at all.
  'core-rules/pi/'
  'core-rules/inheritance-manifest.json'
  'core-rules/hooks.md'
  'core-rules/inheritance.md'
  'core-rules/deferred.md'
  'core-rules/primers.md'
  'core-rules/hooks/'
  'core-rules/husky/'
  'core-rules/githooks/'
  'core-rules/skills/'
  'core-rules/commands/'
  'core-rules/templates/'
  'core-rules/references/'
  'core-rules/autonomy.md'
  'core-rules/loop-safety.md'
  'core-rules/presets/'
  'docs/adr/'
  'docs/primers/'
  'docs/references/'
  'docs/legacy/'
  'docs/UPGRADING.md'
  'docs/MIGRATING-1.0.0.md'
  'docs/claude-steering.md'
  'docs/gpt-5.x-steering.md'
  'docs/codex-routing.md'
  'docs/specs/2026-05-20-trellis-autonomy-design.md'
  'docs/specs/2026-06-02-trellis-process-enforcement-design.md'
  'docs/specs/2026-06-09-loop-safety-contract-design.md'
  'docs/specs/2026-07-21-reference-token-handoff-spike.md'
  'docs/specs/2026-07-21-public-dependency-bootstrap-design.md'
  'docs/research/2026-07-25-claude-5-prompting-corpus.md'
  'scripts/'
  'trellis.config.json'
)


# Every core-rules subtree is either published above or consciously private.
# Entries are relative to core-rules/. A private entry nested below a published
# parent is removed from the stage, and its exact public-tree counterpart must
# also appear in `delist_prune` so an existing mirror loses stale copies.
core_rules_no_sync=(
  'evals'
  'skills/herdr-foreman'
  # Both name this operator's LIVE provider routes. `pi/agents` pins models per
  # agent (including `opencode-go-2`, a second private account),
  # and `usage-federation/lane-catalog.json` enumerates `google-antigravity`,
  # `nous-portal` and `xai-oauth`. Neither carries a secret; both carry the
  # roster, which is what this list is for.
  #
  # The withheld unit is the roster directory, not the whole pi subtree: the
  # extension, hook dispatcher and patch bundle above it state no provider at
  # all, and withholding them made the public setup recipe unfollowable.
  'pi/agents'
  'usage-federation'
)

# Exact payload paths that a wholesale directory entry above would otherwise
# publish. A directory is allowlisted for its policy value while a single file
# inside it carries operator-specific detail, so the exclusion has to name the
# file rather than drop the whole subtree. Every entry here must also appear in
# `delist_prune` so an existing mirror loses the file instead of keeping a stale
# published copy forever.
payload_no_publish=(
  'docs/adr/2026-08-07-fleet-hosting-substrate-policy.md'
  # Withheld for the same reason as core-rules/pi and core-rules/usage-federation:
  # it names this operator's live provider routes. quota/ carries one module per
  # provider -- antigravity, xai, opencode, openrouter -- so the package structure
  # IS the roster. `scripts/` is allowlisted wholesale for its policy value, which
  # is exactly what this list exists to carve into.
  'scripts/lib/usage_federation'
  # Its test suite names the same provider modules, so it is withheld with it.
  'scripts/tests/usage-federation.bats'
)

# Paths removed from an existing mirror. These are public-tree relative and
# validated before deletion. They include all possible TRELLIS_HOME state that
# might have been copied by an earlier implementation.
#
# The private-state roots below are paired one-for-one with the structural
# reject terms in `lint_mirror` (`scripts/lib/mirror-lint.sh`). Keep them in
# sync in both directions: a term the lint rejects with no entry here leaves a
# mirror permanently unpublishable, and an entry here with no lint term deletes
# silently instead of failing loudly.
delist_prune=(
  'scripts/lib/usage_federation'
  'scripts/tests/usage-federation.bats'
  'core-rules/pi/agents'
  'core-rules/usage-federation'
  'docs/antigravity-steering.md'
  'docs/gpt-5.5-steering.md'
  'docs/opus-4.8-steering.md'
  'core-rules/skills/herdr-foreman'
  'scheduled-tasks'
  'local'
  '.trellis'
  'config.json'
  'state'
  'tasks'
  'locks'
  'releases'
  'registry.json'
  'registry.md'
  'blacklist.md'
  'recon.md'
  'docs/adr/2026-08-07-fleet-hosting-substrate-policy.md'
  'AGENT_ONBOARD_GPTX.md'
  'docs/gptx.md'
  'docs/gptx-security.md'
  'docs/gptx-session-policy-matrix.md'
  'docs/gptx-model-override-matrix.md'
)

safe_prune_path() {
  case "$1" in
    ''|'.'|'..'|/*|*'//'*|*$'\t'*|*$'\n'*|*$'\r'*|./*|../*|*'/./'*|*'/../'*|*/|*/.|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

preflight_payload_no_publish_prunes() {
  # The `payload_no_publish` header states that every entry must also appear in
  # `delist_prune`, or an already-published copy is never deleted. Nothing enforced it
  # -- the invariant lived in a comment, and a comment does not fail a build. Keep
  # the executable pairing check so the next entry cannot skip its prune silently.
  local path prune found
  for path in "${payload_no_publish[@]}"; do
    safe_prune_path "$path" || {
      printf 'trellis mirror: unsafe payload_no_publish path: %s\n' "$path" >&2
      return 1
    }
    found=
    for prune in "${delist_prune[@]}"; do
      [ "$prune" = "$path" ] && { found=1; break; }
    done
    [ -n "$found" ] || {
      printf 'trellis mirror: payload_no_publish entry is missing its exact delist prune pair: %s\n' "$path" >&2
      return 1
    }
  done
}

preflight_core_rules_private_prunes() {
  local private prune expected
  for private in "${core_rules_no_sync[@]}"; do
    safe_prune_path "$private" || {
      printf 'trellis mirror: unsafe private core-rules path: %s\n' "$private" >&2
      return 1
    }
    case "$private" in
      */*)
        expected="core-rules/$private"
        for prune in "${delist_prune[@]}"; do
          [ "$prune" = "$expected" ] && continue 2
        done
        printf 'trellis mirror: nested private core-rules path is missing exact delist prune pair: %s -> %s\n' \
          "$private" "$expected" >&2
        return 1
        ;;
    esac
  done
}

mirror_require_real_parent() {
  local root="$1" relative="$2" parent rest component current
  safe_prune_path "$relative" || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || {
    printf 'trellis mirror: destination root is not a real directory: %s\n' "$root" >&2
    return 1
  }
  case "$relative" in
    */*) parent="${relative%/*}" ;;
    *) return 0 ;;
  esac
  current="$root"
  rest="$parent"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
      *) component="$rest"; rest="" ;;
    esac
    current="$current/$component"
    if [ -L "$current" ]; then
      printf 'trellis mirror: destination parent is a symlink: %s\n' "${current#"$root"/}" >&2
      return 1
    fi
    if [ -e "$current" ] && [ ! -d "$current" ]; then
      printf 'trellis mirror: destination parent is not a directory: %s\n' "${current#"$root"/}" >&2
      return 1
    fi
  done
}

# Execute a mutation while the destination parent is the process's current
# directory. `cd -P` plus the expected physical path binds later relative
# operations to that directory even if an attacker renames a pathname parent
# after preflight. Missing components are created one-at-a-time from that bound
# directory; a raced symlink or non-directory is rejected before descent.
mirror_run_in_real_parent() {
  local root="$1" relative="$2" action="$3" parent rest component leaf expected actual
  shift 3
  safe_prune_path "$relative" || return 1
  mirror_require_real_parent "$root" "$relative" || return 1
  case "$relative" in
    */*) parent="${relative%/*}"; leaf="${relative##*/}" ;;
    *) parent=""; leaf="$relative" ;;
  esac
  (
    CDPATH='' cd -P -- "$root" || exit 1
    actual="$(pwd -P)" || exit 1
    [ "$actual" = "$root" ] || {
      printf 'trellis mirror: destination root changed during mutation: %s\n' "$root" >&2
      exit 1
    }
    expected="$root"
    rest="$parent"
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
        *) component="$rest"; rest="" ;;
      esac
      if [ ! -e "$component" ] && [ ! -L "$component" ]; then
        mkdir "$component" || exit 1
      fi
      [ ! -L "$component" ] && [ -d "$component" ] || {
        printf 'trellis mirror: destination parent is not a real directory: %s\n' "$component" >&2
        exit 1
      }
      CDPATH='' cd -P -- "$component" || exit 1
      expected="$expected/$component"
      actual="$(pwd -P)" || exit 1
      [ "$actual" = "$expected" ] || {
        printf 'trellis mirror: destination parent changed during mutation: %s\n' "$expected" >&2
        exit 1
      }
    done
    "$action" "$leaf" "$relative" "$@"
  )
}

# A destination symlink is refused because a mutation must never be written
# THROUGH a link an attacker controls. One destination link is not that: the
# one this flow itself published on an earlier run. Recognise it and only it —
# both sides links, link TEXT equal byte-for-byte, and that text relative and
# lexically contained in the mirror. `readlink` and `-L` are lstat-only, so the
# link is never followed and a hostile target buys nothing. Absolute targets,
# escaping targets, mismatched text, and a link facing a non-link staged source
# all still fall through to the refusal.
#
# Preflight has to accept it or it rejects its own output: `mirror_copy_staged_paths`
# and `mirror_remove_pruned_paths` each re-run `mirror_preflight_mutations`, and
# any already-published mirror hands the first preflight a link it installed
# itself. The re-runs are deliberate — they catch a tree raced between the two
# passes — so the invariant to hold is that preflight is idempotent over the
# flow's own output, not that the second preflight looks at less.
mirror_destination_is_staged_link() {
  local relative="$1" source="$2" destination="$3" source_target destination_target
  [ -L "$source" ] && [ -L "$destination" ] || return 1
  source_target="$(readlink "$source")" || return 1
  destination_target="$(readlink "$destination")" || return 1
  [ -n "$source_target" ] && [ "$source_target" = "$destination_target" ] || return 1
  mirror_link_target_is_contained "$relative" "$source_target" || return 1
}

mirror_install_file_in_parent() {
  local leaf="$1" relative="$2" source="$3" temporary target
  if [ -L "$leaf" ]; then
    mirror_destination_is_staged_link "$relative" "$source" "$leaf" || {
      printf 'trellis mirror: destination is a symlink: %s\n' "$relative" >&2
      return 1
    }
    return 0
  fi
  if [ -L "$source" ]; then
    target="$(readlink "$source")" || return 1
    mirror_link_target_is_contained "$relative" "$target" || {
      printf 'trellis mirror: staged source link escapes destination: %s\n' "$relative" >&2
      return 1
    }
    if [ -e "$leaf" ] || [ -L "$leaf" ]; then
      [ -f "$leaf" ] && [ ! -L "$leaf" ] || {
        printf 'trellis mirror: destination is not a regular file: %s\n' "$relative" >&2
        return 1
      }
      rm -f "$leaf" || return 1
    fi
    [ ! -e "$leaf" ] && [ ! -L "$leaf" ] || return 1
    ln -s "$target" "$leaf"
    return
  fi
  [ -f "$source" ] || {
    printf 'trellis mirror: staged source is not a regular file: %s\n' "$relative" >&2
    return 1
  }
  temporary="$(mktemp ".trellis-mirror-file.XXXXXX")" || return 1
  if ! cp -P "$source" "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  [ ! -L "$leaf" ] || {
    rm -f "$temporary"
    printf 'trellis mirror: destination is a symlink: %s\n' "$relative" >&2
    return 1
  }
  if [ -e "$leaf" ]; then
    [ -f "$leaf" ] || {
      rm -f "$temporary"
      printf 'trellis mirror: destination is not a regular file: %s\n' "$relative" >&2
      return 1
    }
    rm -f "$leaf" || {
      rm -f "$temporary"
      return 1
    }
  fi
  if ! ln "$temporary" "$leaf"; then
    rm -f "$temporary"
    return 1
  fi
  rm -f "$temporary"
}

mirror_install_directory_in_parent() {
  local leaf="$1" relative="$2" source="$3" temporary temporary_path expected actual
  [ -d "$source" ] && [ ! -L "$source" ] || {
    printf 'trellis mirror: staged source is not a real directory: %s\n' "$relative" >&2
    return 1
  }
  temporary_path="$(mktemp -d ".trellis-mirror-dir.XXXXXX")" || return 1
  temporary="$(CDPATH='' cd -P -- "$temporary_path" && pwd -P)" || {
    rm -rf "$temporary_path"
    return 1
  }
  if ! rsync -a --delete --links --safe-links "${source}/" "${temporary}/"; then
    rm -rf "$temporary"
    return 1
  fi
  [ ! -L "$leaf" ] || {
    rm -rf "$temporary"
    printf 'trellis mirror: destination is a symlink: %s\n' "$relative" >&2
    return 1
  }
  if [ -e "$leaf" ]; then
    [ -d "$leaf" ] || {
      rm -rf "$temporary"
      printf 'trellis mirror: destination is not a directory: %s\n' "$relative" >&2
      return 1
    }
    rm -rf "$leaf" || {
      rm -rf "$temporary"
      return 1
    }
  fi
  if ! mkdir "$leaf"; then
    rm -rf "$temporary"
    return 1
  fi
  expected="$PWD/$leaf"
  if ! (
    CDPATH='' cd -P -- "$leaf" || exit 1
    actual="$(pwd -P)" || exit 1
    [ "$actual" = "$expected" ] || {
      printf 'trellis mirror: destination changed during mutation: %s\n' "$relative" >&2
      exit 1
    }
    rsync -a --links --safe-links "${temporary}/" ./
  ); then
    rm -rf "$temporary"
    return 1
  fi
  rm -rf "$temporary"
}

mirror_prune_in_parent() {
  local leaf="$1" relative="$2"
  [ ! -L "$leaf" ] || {
    printf 'trellis mirror: refusing symlinked prune target: %s\n' "$relative" >&2
    return 1
  }
  [ -e "$leaf" ] || return 0
  if [ -d "$leaf" ]; then
    rm -rf "$leaf"
  else
    rm -f "$leaf"
  fi
}

mirror_preflight_mutations() {
  local root="$1" path source destination
  mirror_validate_symlinks "$root" || return 1
  for path in "${sync_paths[@]}"; do
    source="$stage/${path%/}"
    [ -e "$source" ] || [ -L "$source" ] || continue
    mirror_validate_copy_target "$root" "${path%/}" "$source" || return 1
  done
  for path in "${delist_prune[@]}"; do
    safe_prune_path "$path" || {
      printf 'trellis mirror: unsafe prune path: %s\n' "$path" >&2
      return 1
    }
    mirror_require_real_parent "$root" "$path" || return 1
    destination="$root/$path"
    [ ! -L "$destination" ] || {
      printf 'trellis mirror: refusing symlinked prune target: %s\n' "$path" >&2
      return 1
    }
  done
}

mirror_validate_copy_target() {
  local root="$1" relative="$2" source="$3" destination
  mirror_require_real_parent "$root" "$relative" || return 1
  destination="$root/$relative"
  if [ -L "$destination" ]; then
    mirror_destination_is_staged_link "$relative" "$source" "$destination" || {
      printf 'trellis mirror: destination is a symlink: %s\n' "$relative" >&2
      return 1
    }
    return 0
  fi
  if [ -L "$source" ] || [ -f "$source" ]; then
    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
      printf 'trellis mirror: destination is not a regular file: %s\n' "$relative" >&2
      return 1
    fi
  elif [ -d "$source" ]; then
    if [ -e "$destination" ] && [ ! -d "$destination" ]; then
      printf 'trellis mirror: destination is not a directory: %s\n' "$relative" >&2
      return 1
    fi
  else
    printf 'trellis mirror: staged source is not publishable: %s\n' "$relative" >&2
    return 1
  fi
}

mirror_copy_staged_paths() {
  local root="$1" path source
  mirror_preflight_mutations "$root" || return 1
  for path in "${sync_paths[@]}"; do
    source="$stage/${path%/}"
    [ -e "$source" ] || [ -L "$source" ] || continue
    mirror_validate_copy_target "$root" "${path%/}" "$source" || return 1
    if [ -L "$source" ] || [ -f "$source" ]; then
      mirror_run_in_real_parent "$root" "${path%/}" mirror_install_file_in_parent "$source" || return 1
    else
      mirror_run_in_real_parent "$root" "${path%/}" mirror_install_directory_in_parent "$source" || return 1
    fi
  done
}

mirror_remove_pruned_paths() {
  local root="$1" path destination
  mirror_preflight_mutations "$root" || return 1
  for path in "${delist_prune[@]}"; do
    destination="$root/$path"
    [ -e "$destination" ] || [ -L "$destination" ] || continue
    mirror_run_in_real_parent "$root" "$path" mirror_prune_in_parent || return 1
  done
}
sync_path_covers_ref() {
  local ref="$1" path
  for path in "${sync_paths[@]}"; do
    [ "$path" = "$ref" ] && return 0
    case "$path" in */) case "$ref" in "$path"*) return 0 ;; esac ;; esac
  done
  return 1
}

core_rules_private_ref() {
  local ref="$1" name
  for name in "${core_rules_no_sync[@]}"; do
    case "$ref" in "core-rules/$name/"*) return 0 ;; esac
  done
  return 1
}

ref_integrity_check() {
  local root="${1:-}" refs files path source file ref failed=0
  [ "$#" -eq 1 ] || return 2
  refs="$(mktemp "${TMPDIR:-/tmp}/trellis-mirror-refs.XXXXXX")"
  files="$(mktemp "${TMPDIR:-/tmp}/trellis-mirror-files.XXXXXX")"
  for path in "${sync_paths[@]}"; do
    source="$root/${path%/}"
    if [ -f "$source" ]; then
      case "$source" in *.md) printf '%s\n' "$source" > "$files" ;; *) continue ;; esac
    elif [ -d "$source" ]; then
      find "$source" -type f -name '*.md' -print > "$files"
    else
      continue
    fi
    while IFS= read -r file; do
      grep -oE 'core-rules/[A-Za-z0-9._/-]*\.md' "$file" 2>/dev/null | sort -u > "$refs" || true
      while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        core_rules_private_ref "$ref" && continue
        if ! sync_path_covers_ref "$ref"; then
          printf 'trellis mirror: unsatisfied public reference: %s -> %s\n' "${file#"$root"/}" "$ref" >&2
          failed=1
        fi
      done < "$refs"
    done < "$files"
  done
  rm -f "$refs" "$files"
  [ "$failed" -eq 0 ]
}

# The verified payload is the only source. Inspect its tree directly rather
# than consulting a mutable checkout or an ambient Git worktree.
check_payload_core_rules_coverage() {
  local dir name path private rc=0
  for dir in "$PAYLOAD_ROOT"/core-rules/*/; do
    [ -d "$dir" ] || continue
    [ ! -L "${dir%/}" ] || {
      printf '%s\n' "${dir#"$PAYLOAD_ROOT"/}"
      rc=1
      continue
    }
    name="${dir%/}"
    name="${name##*/}"
    for path in "${sync_paths[@]}"; do
      case "$path" in
        "core-rules/$name"|"core-rules/$name/") continue 2 ;;
      esac
    done
    for private in "${core_rules_no_sync[@]}"; do
      [ "$private" = "$name" ] && continue 2
    done
    printf 'core-rules/%s/\n' "$name"
    rc=1
  done
  return "$rc"
}

stage_verified_payload() {
  local path source destination staged_path
  for path in "${sync_paths[@]}"; do
    source="$PAYLOAD_ROOT/${path%/}"
    destination="$stage/${path%/}"
    case "$path" in
      */)
        if [ ! -e "$source" ] && [ ! -L "$source" ]; then
          printf '  skip missing: %s\n' "$path"
        elif [ -d "$source" ] && [ ! -L "$source" ]; then
          mkdir -p "$destination" || return 5
          rsync -a --delete --links --safe-links \
            --exclude='.DS_Store' --exclude='__pycache__/' --exclude='*.swp' \
            --exclude='check-secrets.bats' --exclude='/workflows/' \
            --exclude='/full-audit-sweep-ledger.mjs' \
            "${source}/" "${destination}/" || return 5
        else
          printf 'trellis mirror: verified payload directory is not publishable: %s\n' "$path" >&2
          return 4
        fi
        ;;
      *)
        if [ ! -e "$source" ] && [ ! -L "$source" ]; then
          printf '  skip missing: %s\n' "$path"
        elif [ -L "$source" ] || [ -f "$source" ]; then
          mkdir -p "$(dirname "$destination")" || return 5
          cp -P "$source" "$destination" || return 5
        else
          printf 'trellis mirror: verified payload file is not publishable: %s\n' "$path" >&2
          return 4
        fi
        ;;
    esac
  done
  mirror_validate_symlinks "$stage" || {
    printf 'trellis mirror: verified payload contains unsafe symlinks\n' >&2
    return 4
  }
  # The verified release is intentionally read-only. Its copied stage is
  # private scratch space, so make only non-link entries writable before
  # deterministic redaction and eventual cleanup; find -P never traverses
  # payload links.
  find -P "$stage" -type d -exec chmod u+rwx {} + || return 5
  find -P "$stage" -type f -exec chmod u+rw {} + || return 5
  while IFS= read -r -d '' staged_path; do
    rm -f "$staged_path" || return 5
  done < <(find -P "$stage" \( -type f -o -type l \) \( -name '.DS_Store' -o -name '*.swp' -o -name 'check-secrets.bats' \) -print0)
  while IFS= read -r -d '' staged_path; do
    rm -rf "$staged_path" || return 5
  done < <(find -P "$stage" -type d -name '__pycache__' -prune -print0)
  for path in "${sync_paths[@]}"; do
    [ -d "$stage/${path%/}" ] && [ ! -L "$stage/${path%/}" ] || continue
    rm -rf "$stage/${path%/}/workflows" || return 5
    rm -f "$stage/${path%/}/full-audit-sweep-ledger.mjs" || return 5
  done
  # Drop consciously private core-rules subtrees pulled in by a published
  # parent. The register is relative to core-rules/; validate each entry before
  # removal so a malformed future entry cannot broaden the deletion.
  for path in "${core_rules_no_sync[@]}"; do
    safe_prune_path "$path" || {
      printf 'trellis mirror: unsafe private core-rules path: %s\n' "$path" >&2
      return 4
    }
    rm -rf "${stage:?}/core-rules/${path:?}" || return 5
  done
  # Drop the named exclusions a wholesale directory entry pulled in. These are
  # exact relative paths, never globs, so nothing outside the list can be removed
  # by a surprising expansion. An entry may name a directory -- a package whose
  # structure is itself operator-specific -- so remove recursively; the target is
  # always inside the disposable stage, never the source tree.
  for path in "${payload_no_publish[@]}"; do
    case "$path" in
      /*|*..*) printf 'trellis mirror: unsafe no-publish path: %s\n' "$path" >&2; return 4 ;;
    esac
    rm -rf "${stage:?}/${path:?}" || return 5
  done
}

# Project the STAGED inheritance manifest into the one a mirror user can
# actually satisfy. The verified payload's manifest is read-only input and stays
# byte-identical; only the disposable stage is rewritten.
#
# Two of its link entries name sources the positive allowlist deliberately
# withholds -- `core-rules/pi/agents` (the provider roster) and
# `core-rules/skills/herdr-foreman` (the executable skill that encodes it). A
# published manifest that still declared them would hand every mirror user a
# planner that fails closed on `required source is missing from immutable
# payload` for a source they can never obtain.
#
# This is emphatically NOT "drop entries whose source is absent". A dangling
# source the allowlist did not intend to withhold is a real publication defect,
# and `ref_integrity_check` plus the closure tests exist to catch it; a blanket
# filter here would swallow exactly that signal. So each private entry is
# matched by its full declared shape and removed only then. Adding a key to
# either entry in `core-rules/inheritance-manifest.json` is therefore a
# two-place edit -- the manifest and the expectations below -- which is the same
# deliberate cost the `delist_prune` pairing already charges.
#
# `python3` rather than `jq`: the mirror body runs under `env -i` with
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, the same restricted PATH the stable
# launcher already depends on python3 from. Round-tripping through
# `json.dumps(indent=2)` reproduces this repository's manifest byte-for-byte,
# so the projection's only diff is the removals.
project_staged_inheritance_manifest() {
  local manifest="$stage/core-rules/inheritance-manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
    printf 'trellis mirror: staged inheritance manifest is not a regular file\n' >&2
    return 4
  }
  python3 -I - "$manifest" <<'PROJECT_MANIFEST' || return 4
import json
import sys

# (harness, full expected entry shape). The source string is read back out of
# the shape, so the identity predicate and the shape check cannot drift.
PRIVATE_ENTRIES = (
    (
        "shared_agents",
        {
            "source_children": "core-rules/pi/agents",
            "destination_dir": ".agents/agents",
            "entry_type": "file",
            "suffix": ".md",
        },
    ),
    (
        "user",
        {
            "source": "core-rules/skills/herdr-foreman",
            "destination": ".claude/skills/herdr-foreman",
            "destination_home": True,
        },
    ),
)
SOURCE_KEYS = ("source", "source_children", "fallback_source")


def refuse(message):
    sys.stderr.write("trellis mirror: %s\n" % message)
    raise SystemExit(4)


path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
except ValueError as error:
    refuse("staged inheritance manifest is not valid JSON: %s" % error)

if not isinstance(document, dict) or document.get("schema_version") != 2:
    refuse("staged inheritance manifest is not schema_version 2")

harnesses = document.get("harnesses")
if not isinstance(harnesses, dict):
    refuse("staged inheritance manifest has no harnesses object")

for name, section in harnesses.items():
    if not isinstance(section, dict) or not isinstance(section.get("links"), list):
        refuse("staged inheritance manifest has no %s.links array" % name)

for harness, expected in PRIVATE_ENTRIES:
    section = harnesses.get(harness)
    if not isinstance(section, dict):
        refuse("staged inheritance manifest has no %s harness object" % harness)
    links = section.get("links")
    if not isinstance(links, list):
        refuse("staged inheritance manifest has no %s.links array" % harness)

    private_source = next(
        expected[key] for key in SOURCE_KEYS if key in expected
    )
    matched = [
        (name, index, entry)
        for name, candidate in harnesses.items()
        for index, entry in enumerate(candidate["links"])
        if isinstance(entry, dict)
        and any(entry.get(key) == private_source for key in SOURCE_KEYS)
    ]
    # Absent is the already-portable input: projection is idempotent over its
    # own output, so a re-published mirror is not a second, different manifest.
    if not matched:
        continue
    if any(name != harness for name, _, _ in matched):
        refuse("staged inheritance manifest has misplaced or cross-array private source %s" % private_source)
    if len(matched) > 1:
        refuse(
            "staged inheritance manifest names private source %s %d times in %s.links"
            % (private_source, len(matched), harness)
        )
    _, index, entry = matched[0]
    if (entry.keys() != expected.keys()
            or any(type(entry[key]) is not type(value) or entry[key] != value
                   for key, value in expected.items())):
        refuse(
            "staged inheritance manifest entry for private source %s in %s.links "
            "does not match the withheld shape" % (private_source, harness)
        )
    del links[index]

with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
PROJECT_MANIFEST
}

printf '==> Checking private core-rules prune pairing\n'
preflight_core_rules_private_prunes || exit 4
preflight_payload_no_publish_prunes || exit 4

printf '==> Verifying immutable publication payload\n'
[ -d "$PAYLOAD_ROOT" ] && [ ! -L "$PAYLOAD_ROOT" ] || {
  printf 'trellis mirror: verified release payload is unavailable\n' >&2
  exit 5
}

printf '==> Checking core-rules publication coverage\n'
if uncovered="$(check_payload_core_rules_coverage)"; then
  :
else
  coverage_status=$?
  [ "$coverage_status" -eq 1 ] || {
    printf 'trellis mirror: unable to inspect verified core-rules payload\n' >&2
    exit 5
  }
fi
if [ -n "$uncovered" ]; then
  printf 'trellis mirror: core-rules paths are neither published nor private:\n%s\n' "$uncovered" >&2
  exit 4
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/trellis-mirror-stage.XXXXXX")" || {
  printf 'trellis mirror: unable to create staging directory\n' >&2
  exit 5
}
stage_tmp="$stage"
stage="$(CDPATH='' cd -P -- "$stage_tmp" && pwd -P)" || {
  rm -rf "$stage_tmp"
  printf 'trellis mirror: unable to canonicalize staging directory\n' >&2
  exit 5
}
trap 'rm -rf "$stage"' EXIT INT TERM
printf '==> Staging portable policy from verified commit %s\n' "$SOURCE_COMMIT"
stage_verified_payload || exit "$?"

printf '==> Projecting staged inheritance manifest\n'
project_staged_inheritance_manifest || exit "$?"

printf '==> Checking staged markdown references\n'
ref_integrity_check "$stage" || exit 4

# Publish a deterministic tracked policy shell, not the immutable payload's
# machine configuration. Machine-specific roots/remotes/release state belong
# only in TRELLIS_HOME/config.json and are not a configurable redaction feature.
[ ! -L "$stage/trellis.config.json" ] || {
  printf 'trellis mirror: verified payload config must not be a symlink\n' >&2
  exit 4
}
cat > "$stage/trellis.config.json" <<'EOF'
{
  "$schema": "./scripts/lib/trellis.config.schema.json",
  "schema_version": 2,
  "comment": "Tracked portable Trellis policy. Configure machine roots, fleet settings, release remote, and attachment state in TRELLIS_HOME, never in this file.",
  "maintainer_name": "__MAINTAINER_NAME__",
  "github_user": "__GITHUB_USER__",
  "harnesses": ["claude"],
  "template": {
    "remote": "https://example.invalid/trellis.git",
    "branch": "main"
  }
}
EOF

# Fleet observations are local. Public bootstrap shells remain deterministic and
# empty so a fresh mirror can populate its own local state without inheriting
# another operator's project or finding inventory.
if [ -L "$stage/dependency-baseline.json" ]; then
  printf 'trellis mirror: verified payload dependency baseline must not be a symlink\n' >&2
  exit 4
fi
if [ -f "$stage/dependency-baseline.json" ]; then
  cat > "$stage/dependency-baseline.json" <<'EOF'
{
  "$schema": "./scripts/lib/fleet-dependency-baseline.schema.json",
  "schema_version": 1,
  "source_ref": "origin/main",
  "policy": {
    "shared_project_minimum": 2,
    "direct_versions": "exact-per-lane",
    "peer_versions": "compatible-range",
    "expired_exceptions": "fail"
  },
  "toolchains": [],
  "packages": [],
  "security_floors": [],
  "exceptions": []
}
EOF
fi
if [ -L "$stage/audits" ] || [ -L "$stage/audits/fleet-remediation-ledger.json" ]; then
  printf 'trellis mirror: verified payload remediation ledger must not use a symlink\n' >&2
  exit 4
fi
if [ -f "$stage/audits/fleet-remediation-ledger.json" ]; then
  cat > "$stage/audits/fleet-remediation-ledger.json" <<'EOF'
{
  "$schema": "../scripts/lib/fleet-remediation-ledger.schema.json",
  "schema_version": 1,
  "audit_date": "2026-08-13",
  "source_reports": [],
  "findings": []
}
EOF
fi

printf '==> Linting staged portable policy\n'
if ! lint_out="$(lint_mirror "$stage")"; then
  printf 'trellis mirror: staged policy contains forbidden content:\n%s\n' "$lint_out" >&2
  exit 4
fi

template_snapshot="$stage/.template-snapshot"
simulated="$stage/.simulated-mirror"
printf '==> Preflighting template mutation paths for simulation\n'
mirror_preflight_mutations "$template_dir" || {
  printf 'trellis mirror: template destination has unsafe mutation path\n' >&2
  exit 4
}
mkdir -p "$template_snapshot" "$simulated" || {
  printf 'trellis mirror: unable to create simulated mirror\n' >&2
  exit 5
}
printf '==> Building simulated post-sync mirror\n'
if ! rsync -a --delete --links --safe-links --exclude='.git' "$template_dir/" "$template_snapshot/"; then
  printf 'trellis mirror: unable to snapshot template for simulation\n' >&2
  exit 5
fi
if ! rsync -a --delete --links --safe-links "$template_snapshot/" "$simulated/"; then
  printf 'trellis mirror: unable to build simulated mirror\n' >&2
  exit 5
fi
mirror_copy_staged_paths "$simulated" || {
  printf 'trellis mirror: simulated destination has unsafe mutation path\n' >&2
  exit 4
}
mirror_remove_pruned_paths "$simulated" || {
  printf 'trellis mirror: simulated destination has unsafe prune path\n' >&2
  exit 4
}

printf '==> Linting simulated post-sync mirror\n'
if ! lint_out="$(lint_mirror "$simulated")"; then
  printf 'MIRROR LINT FAILED — forbidden content in simulated public mirror:\n%s\n' "$lint_out" >&2
  exit 4
fi
printf '  simulated mirror clean.\n'

printf '==> Diff vs %s\n' "$template_dir"
diff_out="$(mktemp "${TMPDIR:-/tmp}/trellis-mirror-diff.XXXXXX")" || {
  printf 'trellis mirror: unable to create diff output\n' >&2
  exit 5
}
{
  for path in "${sync_paths[@]}"; do
    source="$stage/${path%/}"
    destination="$template_snapshot/${path%/}"
    if [ -d "$source" ] || [ -d "$destination" ]; then
      diff -urN --exclude='.git' "$destination" "$source" 2>/dev/null || true
    elif [ -f "$source" ] || [ -f "$destination" ]; then
      diff -uN "$destination" "$source" 2>/dev/null || true
    fi
  done
} > "$diff_out"
if [ -s "$diff_out" ]; then
  printf '  %s diff lines\n' "$(wc -l < "$diff_out")"
  if ! "$apply"; then
    printf '===== DIFF (first 200 lines) =====\n'
    head -200 "$diff_out"
    printf '===== END DIFF =====\n'
  fi
else
  printf '  no changes.\n'
fi
rm -f "$diff_out"

if ! "$apply"; then
  exit 0
fi

printf '==> Rechecking template mutation paths before apply\n'
mirror_preflight_mutations "$template_dir" || {
  printf 'trellis mirror: template destination has unsafe mutation path\n' >&2
  exit 4
}

printf '==> Writing to %s\n' "$template_dir"
mirror_copy_staged_paths "$template_dir" || {
  printf 'trellis mirror: destination has unsafe mutation path\n' >&2
  exit 4
}
mirror_remove_pruned_paths "$template_dir" || {
  printf 'trellis mirror: destination has unsafe prune path\n' >&2
  exit 4
}
printf '  applied.\n'

if "$push"; then
  origin="$(mirror_git -C "$template_dir" remote get-url origin 2>/dev/null)" || {
    printf 'trellis mirror: --push requires an SSH origin remote\n' >&2
    exit 5
  }
  case "$origin" in
    ssh://*|*@*:* ) ;;
    *)
      printf 'trellis mirror: --push requires an SSH origin remote\n' >&2
      exit 4
      ;;
  esac
  verified_socket="$(mirror_require_verified_ssh_socket)" || exit "$?"
  printf '==> Committing in template repository\n'
  mirror_git -C "$template_dir" add -A
  if mirror_git -C "$template_dir" diff --cached --quiet; then
    printf '  no staged changes — nothing to commit.\n'
  else
    printf 'Commit + push? [y/N] '
    read -r answer
    if [ "$answer" = y ] || [ "$answer" = Y ]; then
      mirror_git -C "$template_dir" commit -m "chore: sync portable Trellis policy ($(date +%Y-%m-%d))"
      mirror_git_push "$verified_socket" -C "$template_dir" push origin main
    else
      printf '  aborted before commit.\n'
    fi
  fi
fi
