#!/usr/bin/env bash
# Machine-local Trellis registry primitives.
#
# Bash 3.2 compatible. Public entry points are deliberately sourceable:
#   local_registry_list_json HOME [FLEET]
#   local_registry_list_diagnostic_json HOME [FLEET]
#   local_registry_resolve_project HOME FLEET PROJECT_ID
#   local_registry_resolve_root HOME ROOT
#   local_registry_register_worktree HOME FLEET PROJECT_ID ROOT RELEASE \
#     HARNESSES_JSON ATTACHMENT_ID [METADATA_JSON]
#   local_registry_record_unavailable_root HOME FLEET PROJECT_ID ROOT \
#     [METADATA_JSON]
#   local_registry_load HOME OUTPUT; local_registry_write_locked HOME INPUT
#
# Registry writes require the T3 `registry` lock and use a same-directory
# atomic rename. Checkout IDs are SHA-256 of canonical real Git-common dirs;
# worktree IDs are SHA-256 of canonical real worktree roots.
#
# Listing availability is one of `available`, `unavailable` or `identity_error`,
# in BOTH listings. `identity_error` is a state error, never a merely absent
# root: the row stays visible so callers report it and keep processing their
# other rows. The vocabulary is named for exit classes, so a row classified from
# a validator result keeps that result's class: a state error (4) is
# `identity_error`, an environment failure (5) — an unreachable or
# uncanonicalizable root, an unusable hash command — is `unavailable`.
#
# `not-applicable` is an IDENTITY-state word (`.identity.state`, diagnostic
# listing only), never an availability word. A rootless `project` row has
# nothing to make unavailable, so both listings call its availability
# `available` and let `.identity.state` carry "there is no root to classify".
# The strict listing's availability enum is a published snapshot contract —
# `materialize-scheduled-task.sh` validates every entry against exactly those
# three words — so the two listings agree on `available` rather than on the
# fourth word one of them cannot emit.

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _LOCAL_REGISTRY_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=trellis-home.sh
  . "$_LOCAL_REGISTRY_LIB_DIR/trellis-home.sh"
else
  _LOCAL_REGISTRY_LIB_DIR=""
fi

# shellcheck disable=SC2034  # Public constant for sourcing callers, not used inside this lib.
LOCAL_REGISTRY_SCHEMA_VERSION=1

# Retired harness tokens dropped by the rc.46 registry migration. Rows written
# before rc.46 carry `omp` in checkout harnesses; loads drop it with a one-line
# stderr notice and the next registry write persists the clean form. This
# constant is the single source of truth for the tokens: pass it via
# jq --arg retired instead of spelling a literal elsewhere in this lib, and
# retire a harness by adding a token here rather than editing every jq program.
LOCAL_REGISTRY_RETIRED_HARNESSES="omp"

# The release launcher preloads every library into one shell for a verified
# command bundle, and a bundle deliberately has no payload pathname to read the
# schema from. This literal is the fallback for exactly that case; it is never
# consulted when the schema is readable. `scripts/tests/w2-registry-validation.bats`
# asserts it equals the schema enum, so a schema change without this list fails
# the suite instead of drifting.
LOCAL_REGISTRY_HARNESS_FALLBACK="antigravity claude codex opencode pi"

local_registry_err() {
  printf 'trellis registry: %s\n' "$*" >&2
}

# Terminal-safe rendering of registry-derived text before it reaches an
# operator's stderr. Every consumer that prints a registry root already funnels
# it through exactly this check — `safe_display_root` in the rollouts,
# `diagnostic_escape` in sync-hooks and sync-merge-gate — and the reason is the
# same here: the diagnostic reader reports ON state it does not get to assume is
# well formed, so a root it echoes must not be able to drive the terminal.
local_registry_safe_display() {
  local value="${1:-}"
  if trellis_home_has_unsafe_chars "$value"; then
    printf '<unsafe registry text>'
  else
    printf '%s' "$value"
  fi
}

local_registry_schema_path() {
  if [ "${TRELLIS_LIBS_PRELOADED:-}" = 1 ]; then
    printf '\n'
  else
    printf '%s/trellis.registry.schema.json\n' "$_LOCAL_REGISTRY_LIB_DIR"
  fi
}

# The admitted harness set is owned by `trellis.registry.schema.json#/$defs/harness`.
# Every consumer that has to decide whether a harness token is canonical asks
# this function instead of restating the union, because a restated union drifts:
# `antigravity` and `opencode` became first-class harnesses while two inline
# predicates still admitted only `claude|codex|pi`, which made every registry
# row fail materialization. Returns one compact JSON array of tokens.
local_registry_harness_union() {
  local schema union
  trellis_home_require_jq || return "$?"
  schema="$(local_registry_schema_path)"
  if [ -z "$schema" ]; then
    union="$(printf '%s\n' "$LOCAL_REGISTRY_HARNESS_FALLBACK" | jq -Rc 'split(" ") | map(select(length > 0))')" || {
      local_registry_err "could not read the preloaded harness union"
      return "$TRELLIS_EX_STATE"
    }
    printf '%s\n' "$union"
    return 0
  fi
  if [ -L "$schema" ] || [ ! -f "$schema" ]; then
    local_registry_err "registry schema is missing: $schema"
    return "$TRELLIS_EX_STATE"
  fi
  union="$(jq -ec '
    .["$defs"].harness.enum
    | if type == "array" and length > 0
        and all(.[]; type == "string" and test("^[a-z][a-z0-9-]{0,31}$"))
      then . else error("invalid registry harness union") end
  ' "$schema" 2>/dev/null)" || {
    local_registry_err "could not read the canonical harness union: $schema"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$union"
}

local_registry_require_project_id() {
  local project_id="${1:-}"
  if [[ "$project_id" == *$'\n'* ]] || ! printf '%s' "$project_id" | /usr/bin/env LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
    local_registry_err "invalid project ID $project_id; expected ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    return "$TRELLIS_EX_USAGE"
  fi
}

local_registry_project_key() {
  local fleet="${1:-}" project_id="${2:-}"
  trellis_home_require_fleet_name "$fleet" || return "$?"
  local_registry_require_project_id "$project_id" || return "$?"
  printf '%s/%s\n' "$fleet" "$project_id"
}

local_registry_require_absolute_safe_path() {
  local label="${1:-path}" path="${2:-}"
  trellis_home_require_absolute_safe_path "$label" "$path" || return "$?"
  case "$path" in
    *'//'*)
      local_registry_err "$label must not contain an empty path component: $path"
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
}

local_registry_normalize_absolute_safe_path() {
  local label="${1:-path}" path="${2:-}"
  local_registry_require_absolute_safe_path "$label" "$path" || return "$?"
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  local_registry_require_absolute_safe_path "$label" "$path" || return "$?"
  printf '%s\n' "$path"
}

local_registry_home() {
  local home
  home="$(trellis_home_resolve "${1:-}")" || return "$?"
  local_registry_normalize_absolute_safe_path "TRELLIS_HOME" "$home"
}

local_registry_path() {
  local home
  home="$(local_registry_home "${1:-}")" || return "$?"
  printf '%s/registry.json\n' "$home"
}

local_registry_empty_json() {
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}'
}

# SHA-256 of the empty string. A fixed, universally known answer is the only
# input whose correct digest this library can assert without trusting the tool
# it is testing.
LOCAL_REGISTRY_EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# ENVIRONMENT probe, run ONCE per listing or validation pass. No SHA-256
# command being on PATH is a property of the machine, not of any registered row:
# every row would fail identically, so classifying each one as a row-scoped
# `unavailable` would hand a consumer a listing that exits 0 with nothing usable
# in it. Callers that enumerate rows probe first and fail the whole read class 5.
# A hash failure on a REACHABLE command (unhashable input, unreadable path) is
# still row-scoped and keeps its own disposition.
#
# The probe is FUNCTIONAL, not a PATH lookup. A `shasum` that exists but cannot
# run — the classic broken-Perl install, a wrapper that prints a banner, a
# truncating shim — passed a presence check and then failed identically on every
# row, which is the machine-wide fault this probe exists to separate from
# registry state. It hashes the empty string once and compares against the known
# constant, and it probes the SAME command `local_registry_sha256` would pick, in
# the same preference order, so the probe cannot certify a tool the hasher will
# not use.
local_registry_require_hash_command() {
  local digest='' rc=0
  # Native tools avoid starting Perl for each of the thousands of hashes in a
  # registry walk. Probe the exact same preference order as the row hasher.
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' '' | sha256sum 2>/dev/null | awk '{print $1}')" || rc="$?"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' '' | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')" || rc="$?"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' '' | shasum -a 256 2>/dev/null | awk '{print $1}')" || rc="$?"
  else
    local_registry_err "a SHA-256 command (sha256sum, openssl, or shasum) is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$rc" -ne 0 ] || [ "$digest" != "$LOCAL_REGISTRY_EMPTY_SHA256" ]; then
    local_registry_err "the available SHA-256 command does not compute correct digests; registry identities cannot be verified"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
}

local_registry_sha256() {
  local value="${1:-}" digest
  trellis_home_require_safe_text "hash input" "$value" || return "$?"
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}')"
  else
    local_registry_err "a SHA-256 command (sha256sum, openssl, or shasum) is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if ! trellis_is_sha256_hex "$digest"; then
    local_registry_err "could not calculate a SHA-256 identity"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  printf '%s\n' "$digest"
}

local_registry_real_directory() {
  local label="${1:-directory}" path="${2:-}" real
  local_registry_require_absolute_safe_path "$label" "$path" || return "$?"
  if [ ! -d "$path" ]; then
    local_registry_err "$label is unavailable: $path"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  real="$(cd "$path" && pwd -P)" || {
    local_registry_err "could not canonicalize $label: $path"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  local_registry_require_absolute_safe_path "$label" "$real" || return "$?"
  printf '%s\n' "$real"
}

local_registry_git_common_dir() {
  local root="${1:-}" common record
  root="$(local_registry_real_directory "worktree root" "$root")" || return "$?"
  record="$(git -C "$root" rev-parse --is-inside-work-tree --git-common-dir 2>/dev/null)" || {
    local_registry_err "could not resolve Git common directory for $root"
    return "$TRELLIS_EX_STATE"
  }
  [ "${record%%$'\n'*}" = true ] && [ "$record" != "${record#*$'\n'}" ] || {
    local_registry_err "worktree root is not inside a Git worktree: $root"
    return "$TRELLIS_EX_STATE"
  }
  common="${record#*$'\n'}"
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  local_registry_real_directory "Git common directory" "$common"
}

local_registry_checkout_root_for_common_dir() {
  local common="${1:-}" member_root="${2:-}" records field candidate actual_common member_git_dir
  common="$(local_registry_real_directory "Git common directory" "$common")" || return "$?"
  member_root="$(local_registry_real_directory "worktree root" "$member_root")" || return "$?"
  records="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.worktrees.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! git -C "$member_root" worktree list --porcelain -z > "$records" 2>/dev/null; then
    rm -f "$records"
    local_registry_err "could not enumerate worktrees for Git common directory: $common"
    return "$TRELLIS_EX_STATE"
  fi
  if ! IFS= read -r -d '' field < "$records"; then
    rm -f "$records"
    local_registry_err "Git common directory has no primary worktree: $common"
    return "$TRELLIS_EX_STATE"
  fi
  rm -f "$records"
  case "$field" in
    'worktree '*) candidate="${field#worktree }" ;;
    *)
      local_registry_err "Git worktree metadata is malformed for: $common"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  candidate="$(local_registry_real_directory "checkout root" "$candidate")" || return "$?"
  if [ "$candidate" = "$common" ]; then
    member_git_dir="$(git -C "$member_root" rev-parse --absolute-git-dir 2>/dev/null)" || {
      local_registry_err "could not resolve Git directory for worktree: $member_root"
      return "$TRELLIS_EX_STATE"
    }
    member_git_dir="$(local_registry_real_directory "Git directory" "$member_git_dir")" || return "$?"
    if [ "$member_git_dir" != "$common" ] || [ "$member_root" = "$common" ]; then
      local_registry_err "external Git common directory does not identify its primary checkout: $common"
      return "$TRELLIS_EX_STATE"
    fi
    candidate="$member_root"
  fi
  actual_common="$(local_registry_git_common_dir "$candidate")" || return "$?"
  if [ "$actual_common" != "$common" ]; then
    local_registry_err "primary checkout does not match Git common directory: $common"
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$candidate"
}

# Emits a deterministic JSON identity object for a real Git worktree ROOT.
local_registry_identity_for_root() {
  local input_root="${1:-}" root common checkout_root checkout_id worktree_id top record
  root="$(local_registry_real_directory "worktree root" "$input_root")" || return "$?"
  # Both facts come from one Git observation; do not re-run rev-parse for
  # each field (or re-check inside-work-tree after show-toplevel succeeded).
  record="$(git -C "$root" rev-parse --show-toplevel --git-common-dir 2>/dev/null)" || {
    local_registry_err "worktree root is not a Git worktree: $root"
    return "$TRELLIS_EX_STATE"
  }
  [ "$record" != "${record#*$'\n'}" ] || return "$TRELLIS_EX_STATE"
  top="${record%%$'\n'*}"
  common="${record#*$'\n'}"
  top="$(local_registry_real_directory "Git worktree top level" "$top")" || return "$?"
  if [ "$top" != "$root" ]; then
    local_registry_err "project root must equal the Git worktree top level: $root"
    return "$TRELLIS_EX_STATE"
  fi
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  common="$(local_registry_real_directory "Git common directory" "$common")" || return "$?"
  checkout_root="$(local_registry_checkout_root_for_common_dir "$common" "$root")" || return "$?"
  checkout_id="$(local_registry_sha256 "$common")" || return "$?"
  worktree_id="$(local_registry_sha256 "$root")" || return "$?"
  jq -n -S \
    --arg root "$root" \
    --arg checkout_root "$checkout_root" \
    --arg git_common_dir "$common" \
    --arg checkout_id "$checkout_id" \
    --arg worktree_id "$worktree_id" \
    '{root: $root, checkout_root: $checkout_root, git_common_dir: $git_common_dir, checkout_id: $checkout_id, worktree_id: $worktree_id}'
}

local_registry_normalize_harnesses() {
  local harnesses="${1:-}" normalized union
  [ -n "$harnesses" ] || harnesses='[]'
  trellis_home_require_jq || return "$?"
  # rc.46 migration: the retired token is dropped, never rejected, so writes
  # against legacy rows succeed. Any other unknown token still errors.
  union="$(local_registry_harness_union)" || return "$?"
  normalized="$(printf '%s\n' "$harnesses" | jq -c --arg retired "$LOCAL_REGISTRY_RETIRED_HARNESSES" \
    --argjson union "$union" '
    ($retired | split(" ")) as $retired_tokens
    | def live: . as $token | ($retired_tokens | index($token)) == null;
    if type != "array" then error("harnesses must be an array")
    elif ([.[] | select(live)] | all(. as $token | ($union | index($token)) != null))
      then map(select(live)) | unique | sort
    else error("unsupported harness")
    end
  ' 2>/dev/null)" || {
    local_registry_err "harnesses must be JSON array values from the canonical harness set"
    return "$TRELLIS_EX_USAGE"
  }
  printf '%s\n' "$normalized"
}

local_registry_normalize_metadata() {
  local metadata="${1:-}" normalized
  [ -n "$metadata" ] || metadata='{}'
  trellis_home_require_jq || return "$?"
  normalized="$(printf '%s\n' "$metadata" | jq -cS 'if type == "object" then . else error("metadata must be object") end' 2>/dev/null)" || {
    local_registry_err "metadata must be a JSON object"
    return "$TRELLIS_EX_USAGE"
  }
  printf '%s\n' "$normalized"
}

local_registry_normalize_release() {
  local release="${1:-}"
  [ -z "$release" ] && { printf '\n'; return 0; }
  if ! trellis_home_is_valid_semver "$release"; then
    local_registry_err "release must be SemVer when supplied: $release"
    return "$TRELLIS_EX_USAGE"
  fi
  printf '%s\n' "$release"
}

local_registry_require_attachment_id() {
  local attachment_id="${1:-}"
  [ -z "$attachment_id" ] && return 0
  if ! printf '%s' "$attachment_id" | /usr/bin/env LC_ALL=C grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    local_registry_err "attachment ID must be a UUID when supplied: $attachment_id"
    return "$TRELLIS_EX_USAGE"
  fi
}

# Semantic validation covers the JSON Schema and global ownership invariants.
# `jq` is intentionally the validation engine used by all local-state writers.
local_registry_json_is_valid() {
  local registry_json="${1:-}"
  jq -e -s '
    def safe_text:
      type == "string" and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def safe_path:
      safe_text and length >= 2 and startswith("/")
      and (contains("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def fleet_name: safe_text and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def project_id: safe_text and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def sha256: safe_text and test("^[a-f0-9]{64}$");
    def version: safe_text and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$");
    def uuid: safe_text and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    def closed($required; $optional):
      type == "object"
      and ((keys_unsorted - ($required + $optional)) | length == 0)
      and (($required - keys_unsorted) | length == 0);
    # `legacy_path` is the shorthand a resolved import came from, retained for
    # exactly the reason a resolved project row retains `legacy.legacy_path`:
    # the historical fact survives the resolution. It is inert reporting data,
    # never a second path this scanner honours.
    def discovery_ignore:
      closed(["path", "reason"]; ["legacy_path"])
      and (.path | safe_path)
      and ((has("legacy_path") | not) or (.legacy_path | safe_path))
      and (.reason | safe_text and length > 0);
    def worktree:
      closed(["root"]; ["attachment_id"])
      and (.root | safe_path)
      and ((has("attachment_id") | not) or (.attachment_id | uuid));
    def checkout:
      closed(["root", "git_common_dir", "harnesses", "worktrees"]; ["release"])
      and (.root | safe_path) and (.git_common_dir | safe_path)
      and ((has("release") | not) or (.release | version))
      and (.harnesses | type == "array"
           and all(.[]; . == "antigravity" or . == "claude" or . == "codex" or . == "opencode" or . == "pi")
           and ((unique | length) == length))
      and (.worktrees | type == "object"
           and all(keys[]; sha256)
           and all(.[]; worktree));
    def project($key):
      closed(["fleet", "project_id", "status", "metadata", "checkouts"]; ["unavailable_roots"])
      and (.fleet | fleet_name) and (.project_id | project_id)
      and ($key == (.fleet + "/" + .project_id))
      and (.status == "active" or .status == "unavailable" or .status == "detached")
      and (.metadata | type == "object")
      and (.checkouts | type == "object" and all(keys[]; sha256) and all(.[]; checkout))
      and ((has("unavailable_roots") | not) or
           (.unavailable_roots | type == "array" and all(.[]; safe_path)
            and ((unique | length) == length)));
    def checkouts:
      [ .projects | to_entries[] as $project
        | $project.value.checkouts | to_entries[] as $checkout
        | {owner: ($project.key + ":" + $checkout.key), checkout_id: $checkout.key,
           common: $checkout.value.git_common_dir, root: $checkout.value.root,
           worktrees: [$checkout.value.worktrees[]?.root]} ];
    def roots:
      [ checkouts[] as $checkout
        | {owner: $checkout.owner, root: $checkout.root},
          ($checkout.worktrees[]? | {owner: $checkout.owner, root: .}) ];
    def unavailable:
      [ .projects | to_entries[] as $project
        | ($project.value.unavailable_roots // [])[]
        | {owner: $project.key, root: .} ];
    def ignored:
      [ (.discovery_ignores // {}) | .[]? | .[]? | .path ];
    def overlaps($left; $right):
      $left == $right
      or ($left | startswith($right + "/"))
      or ($right | startswith($left + "/"));
    (if length == 1 then .[0] else null end) |
    closed(["schema_version", "projects"]; ["$schema", "discovery_ignores"])
    and ((has("$schema") | not) or (."$schema" | safe_text))
    and .schema_version == 1
    and (.projects | type == "object" and all(to_entries[]; .key | test("^[a-z0-9][a-z0-9._-]{0,63}/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
    and ([.projects | to_entries[] | (.key as $key | .value | project($key))] | all)
    and ((has("discovery_ignores") | not) or
         (.discovery_ignores | type == "object"
          and all(keys[]; fleet_name)
          and all(.[]; type == "array"
                  and all(.[]; discovery_ignore)
                  and ((map(.path) | unique | length) == length))))
    and (checkouts as $checkouts | roots as $roots | unavailable as $unavailable | ignored as $ignored
      | (($checkouts | map(.checkout_id) | unique | length) == ($checkouts | length))
      and (($checkouts | map(.common) | unique | length) == ($checkouts | length))
      and ($roots | group_by(.root) | all(.[]; ((map(.owner) | unique | length) == 1)))
      and (($unavailable | map(.root) | unique | length) == ($unavailable | length))
      and ([ $unavailable[] as $unavailable_root | $roots[]
           | select(.root == $unavailable_root.root) ] | length == 0)
      and ([ $ignored[] as $ignore | ($roots + $unavailable)[] as $owned
           | select(overlaps($ignore; $owned.root)) ] | length == 0)
    )
  ' "$registry_json" >/dev/null 2>&1
}

local_registry_mode() {
  local path="${1:-}" mode
  if mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
    :
  elif mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    :
  else
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  printf '%s\n' "$mode"
}

local_registry_require_private_state() {
  local registry_json="${1:-}" home mode
  home="$(dirname "$registry_json")"
  mode="$(local_registry_mode "$home")" || {
    local_registry_err "could not inspect TRELLIS_HOME permissions: $home"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  if [ "$mode" != 700 ]; then
    local_registry_err "TRELLIS_HOME permissions must be 0700, found $mode: $home"
    return "$TRELLIS_EX_STATE"
  fi
  mode="$(local_registry_mode "$registry_json")" || {
    local_registry_err "could not inspect registry permissions: $registry_json"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  if [ "$mode" != 600 ]; then
    local_registry_err "registry permissions must be 0600, found $mode: $registry_json"
    return "$TRELLIS_EX_STATE"
  fi
}

# rc.46 migration: drop the retired harness token from every checkout's
# harnesses array in FILE, which must be an already-copied registry snapshot
# (never the persisted registry.json). Emits exactly one stderr notice naming
# the affected checkout-row count when any row carried the token. Invalid JSON
# is left untouched so the schema-aware validator below reports it as before;
# only the retired token is ever removed. Unknown tokens still fail validation.
local_registry_drop_retired_harness_rows() {
  local file="${1:-}" count tmp token
  trellis_home_require_jq || return "$?"
  for token in $LOCAL_REGISTRY_RETIRED_HARNESSES; do
    count="$(jq -r --arg retired "$token" '[.projects[]?.checkouts[]?.harnesses | select(type == "array" and index($retired))] | length' "$file" 2>/dev/null)" || continue
    case "$count" in ''|*[!0-9]*) continue ;; esac
    [ "$count" -gt 0 ] || continue
    tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.migrate.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    if ! jq -S --arg retired "$token" '(.projects // {}) |= with_entries(.value.checkouts |= with_entries(.value.harnesses |= (if type == "array" then map(select(. != $retired)) else . end)))' "$file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      continue
    fi
    if ! cat "$tmp" > "$file"; then
      rm -f "$tmp"
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    rm -f "$tmp"
    local_registry_err "dropped retired harness \"$token\" from $count checkout row(s); rewrite with any registry write"
  done
}

local_registry_validate_file() {
  local registry_json="${1:-}" schema
  trellis_home_require_jq || return "$?"
  schema="$(local_registry_schema_path)"
  if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ] && [ ! -f "$schema" ]; then
    local_registry_err "registry schema is missing: $schema"
    return "$TRELLIS_EX_STATE"
  fi
  if [ -L "$registry_json" ] || [ ! -f "$registry_json" ]; then
    local_registry_err "registry must be a regular file: $registry_json"
    return "$TRELLIS_EX_STATE"
  fi
  if ! local_registry_json_is_valid "$registry_json"; then
    local_registry_err "registry failed schema-aware validation: $registry_json"
    return "$TRELLIS_EX_STATE"
  fi
}

local_registry_load() {
  local home="${1:-}" output="${2:-}" registry code validate_err
  [ -n "$output" ] || {
    local_registry_err "load requires an output file"
    return "$TRELLIS_EX_USAGE"
  }
  home="$(local_registry_home "$home")" || return "$?"
  registry="$(local_registry_path "$home")" || return "$?"
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    if [ -L "$registry" ] || [ ! -f "$registry" ]; then
      local_registry_err "registry must be a regular file: $registry"
      return "$TRELLIS_EX_STATE"
    fi
    local_registry_require_private_state "$registry" || return "$?"
    # Copy first: a read-only command must never rewrite the persisted file.
    # The loaded copy carries the rc.46 migration, so the next registry write
    # built from it persists the normalized form.
    cp "$registry" "$output" || return "$TRELLIS_EX_UNAVAILABLE"
    local_registry_drop_retired_harness_rows "$output" || return "$?"
    validate_err="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.validate.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    # NOTE: no `!` here: inside an `if ! cmd` branch `$?` is the negated
    # status (0), not cmd's exit, so capture it in the else branch instead.
    if local_registry_validate_file "$output" 2>"$validate_err"; then
      rm -f "$validate_err"
    else
      code="$?"
      if grep -q "schema-aware validation" "$validate_err" 2>/dev/null; then
        local_registry_err "registry failed schema-aware validation: $registry"
      else
        cat "$validate_err" >&2
      fi
      rm -f "$validate_err"
      return "$code"
    fi
  else
    local_registry_empty_json > "$output" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
}

local_registry_require_lock() {
  local home="${1:-}" expected pid
  home="$(local_registry_home "$home")" || return "$?"
  expected="$home/locks/registry.lock"
  if [ "${_TRELLIS_HOME_LOCK_DIR:-}" != "$expected" ]; then
    local_registry_err "registry write requires the registry lock"
    return "$TRELLIS_EX_CONFLICT"
  fi
  pid="$(trellis_home_lock_read_pid "$expected/pid")" || return "$?"
  if [ "$pid" != "$$" ]; then
    local_registry_err "registry lock is not owned by this process"
    return "$TRELLIS_EX_CONFLICT"
  fi
}

# Shared body for the registry writers. Whole-file SCHEMA/structural validation
# runs in every mode; MODE selects only the identity contract:
#
#   whole-file  Every registered row must identity-validate. Writers that lay
#               down arbitrary rows, or that depend on registry-wide identity
#               and path uniqueness, keep this.
#   bound-rows  Strict identity validation of ONLY the rows this write mutates,
#               named by BINDINGS: a JSON array of {checkout_id, worktree_id}.
#               Each named row is checked by the same
#               `local_registry_validate_identity_row` the whole-file validator
#               uses, so a bound row is exactly as strict — and keeps its own
#               4/5 exit class. An unrelated broken sibling row can no longer
#               fail a healthy row's write.
_local_registry_write_locked() {
  local home="${1:-}" proposal="${2:-}" mode="${3:-}" bindings="${4:-[]}"
  local registry dir base tmp code pairs state checkout worktree
  trellis_home_require_jq || return "$?"
  # ENVIRONMENT before rows, on the WRITE path too. Every identity contract this
  # writer enforces is a SHA-256 comparison, so a machine with no usable hash
  # command cannot validate anything it is about to persist. Probing ONCE here —
  # not once per bound row — separates that machine-wide fault (class 5) from
  # registry state, exactly as the listings do on the read path.
  local_registry_require_hash_command || return "$?"
  home="$(local_registry_home "$home")" || return "$?"
  registry="$(local_registry_path "$home")" || return "$?"
  local_registry_require_lock "$home" || return "$?"
  if [ -L "$registry" ] || { [ -e "$registry" ] && [ ! -f "$registry" ]; }; then
    local_registry_err "registry destination must be an ordinary file: $registry"
    return "$TRELLIS_EX_STATE"
  fi
  if [ -L "$proposal" ] || [ ! -f "$proposal" ]; then
    local_registry_err "registry proposal must be a regular file: $proposal"
    return "$TRELLIS_EX_STATE"
  fi
  dir="$(dirname "$registry")"
  base="$(basename "$registry")"
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    local_registry_err "registry directory is unavailable or symlinked: $dir"
    return "$TRELLIS_EX_STATE"
  fi
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! jq -S . "$proposal" > "$tmp"; then
    rm -f "$tmp"
    local_registry_err "refusing to write invalid registry JSON"
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_validate_file "$tmp" || {
    code="$?"
    rm -f "$tmp"
    return "$code"
  }
  if [ "$mode" = bound-rows ]; then
    state="$(jq -S . "$tmp")" || { rm -f "$tmp"; return "$TRELLIS_EX_STATE"; }
    # SHA-256 IDs never contain whitespace, so a two-field read is unambiguous.
    pairs="$(printf '%s\n' "$bindings" | jq -r '.[] | (.checkout_id // "") + " " + (.worktree_id // "")')" || {
      rm -f "$tmp"
      local_registry_err "refusing to write without a parseable bound-row list"
      return "$TRELLIS_EX_STATE"
    }
    while read -r checkout worktree; do
      [ -n "$checkout" ] || continue
      # The unprobed body: the hash-command probe above already ran once for
      # this write, and repeating it per binding would make an environment
      # probe scale with the row count.
      _local_registry_validate_bound_row_identity "$state" "$checkout" "$worktree" || {
        code="$?"
        rm -f "$tmp"
        return "$code"
      }
    done <<EOF
$pairs
EOF
  else
    local_registry_validate_available_identities "$tmp" || {
      code="$?"
      rm -f "$tmp"
      return "$code"
    }
  fi
  mv "$tmp" "$registry" || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
  chmod 600 "$registry" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
}

local_registry_write_locked() {
  _local_registry_write_locked "${1:-}" "${2:-}" whole-file
}

# Writers that mutate a known, bounded set of rows and must keep processing
# their other targets when an unrelated row is broken. BINDINGS is a JSON array
# of {checkout_id, worktree_id}; an empty worktree_id binds the checkout row
# only.
local_registry_write_locked_bound_rows() {
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  # FLOOR: a bound-row write with nothing bound has no identity contract at all
  # — it would silently degrade to a schema-only write that no row vouches for,
  # which is exactly the weakening this mode exists to avoid. An entry without a
  # checkout ID is the same hole one row at a time. Both are caller errors.
  #
  # WHITESPACE is the same hole by a different route: the binding list is
  # consumed by a two-field `read -r checkout worktree`, so a checkout ID
  # carrying a space or tab splits into a shorter ID plus a bogus worktree ID.
  # Neither names a real row, `local_registry_validate_bound_row_identity`
  # matches nothing, validates vacuously, and the write degrades to schema-only
  # — the exact silent weakening the floor exists to prevent. Real IDs are
  # SHA-256 hex and never contain whitespace, so rejecting it costs nothing.
  #
  # The WORKTREE ID is the same hole one field further right, and the two-field
  # read hides it better: `read -r checkout worktree` assigns the whole tail to
  # `worktree`, so `"abc def"` arrives intact as a worktree ID that names no
  # registered row. The bound-row validator then matches only the checkout row,
  # the worktree row it was supposed to vouch for is never checked, and the
  # write is silently weaker than the caller asked for. Same class-2 refusal.
  #
  # Audited alongside this floor: the other `read -r` splits in this library
  # (`local_registry_checkout_class_for` and the checkout-class loop in
  # `local_registry_list_json`) consume TAB-separated `project_key` and
  # `checkout_id` fields, both of which the whole-file schema constrains to
  # whitespace-free patterns, so neither can be split the same way.
  if ! printf '%s\n' "$3" | jq -e '
    type == "array" and length > 0
    and all(.[]; type == "object" and (.checkout_id | type) == "string" and (.checkout_id | length) > 0
                 and (.checkout_id | test("\\s") | not)
                 and ((has("worktree_id") | not) or .worktree_id == null
                      or ((.worktree_id | type) == "string" and (.worktree_id | test("\\s") | not))))
  ' >/dev/null 2>&1; then
    local_registry_err "bound-row write requires a non-empty binding array with whitespace-free checkout and worktree IDs on every entry"
    return "$TRELLIS_EX_USAGE"
  fi
  _local_registry_write_locked "$1" "$2" bound-rows "$3"
}

# ---------------------------------------------------------------------------
# THE row classifier. One ordered set of checks, one vocabulary, two callers.
#
# There used to be two of these, and their disagreement was the root cause of
# six rounds of scoped-run defects. The strict validator compared stored hashes
# BEFORE the reachability short-circuit; the diagnostic reporter short-circuited
# on reachability FIRST. The same row therefore classified class 4 strictly and
# `unavailable` diagnostically, so every diagnostic consumer — doctor's
# `--project` pre-pass most visibly — under-reported a registry the strict path
# had already condemned.
#
# The order below is the STRICT one, which is the authoritative one: a stored
# hash is a pure function of text already in the registry file, so it is
# verifiable while the volume is offline and must be checked before any
# reachability test is allowed to excuse the row.
#
#   1. row kind        non-row kinds classify without any identity work
#   2. sha256(git_common_dir) == checkout_id      (shared with the checkout row)
#   3. sha256(root)           == worktree_id      (worktree rows only)
#   4. reachability    an unreachable root stops here, class 0
#   5. live canonical Git identity == every recorded field
#
# VOCABULARY — one name per exit class, used by BOTH listings:
#
#   class 0 + `verified`        the row is exactly as registered
#   class 0 + `unavailable`     root not reachable; nothing contradicts the row
#   class 0 + `not-applicable`  project row: there is no root to classify
#   class 4 + `identity_error`  registry state contradicts the machine
#   class 5 + `unavailable`     the environment could not answer the question
#
# `identity_error` is the single name for class 4. It was already the word
# `local_registry_list_json` put in `availability`; the diagnostic listing
# called the same condition `drift` in `.identity.state` and now does not.
#
# SCOPE names which row a fault belongs to, so a consumer can print a
# worktree's own cause without repeating the checkout-level cause the checkout
# pre-pass already printed. Check 2 is the ONLY check a worktree row shares with
# its owning checkout row (same `git_common_dir`, same `checkout_id`); checks 3
# through 5 probe the WORKTREE's own path, so on a worktree row they are
# worktree-scoped — including every live-identity field, because a reparented
# worktree is exactly a worktree whose live checkout fields moved.
#
# The core never writes stderr and never aborts: it emits a verdict and leaves
# abort-vs-report to the caller. A non-zero RETURN is not a row state — it means
# the core could not classify at all (malformed row, or a helper class outside
# {4,5}), and the listing turns that into a class-4 listing failure naming the
# row.
# ---------------------------------------------------------------------------

local_registry_identity_verdict() {
  jq -cn --argjson class "${1:-0}" --arg state "${2:-}" --arg scope "${3:-row}" --arg detail "${4:-}" \
    '{class: $class, state: $state, scope: $scope, detail: $detail}'
}

# Projects a failed helper's exit CLASS onto the row vocabulary. 4 is registry
# state and 5 is the environment; anything else is not a row disposition at all
# and is handed back to the caller unchanged.
local_registry_identity_class_verdict() {
  local class="${1:-}" scope="${2:-row}" detail="${3:-}"
  case "$class" in
    "$TRELLIS_EX_STATE") local_registry_identity_verdict "$class" identity_error "$scope" "$detail" ;;
    "$TRELLIS_EX_UNAVAILABLE") local_registry_identity_verdict "$class" unavailable "$scope" "$detail" ;;
    *) return "$class" ;;
  esac
}

local_registry_classify_identity_row() {
  local row="${1:-}" kind checkout_id checkout_root common worktree_id root id rc scope
  local actual_identity actual_root actual_checkout_root actual_common actual_checkout_id actual_worktree_id fields
  kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
  case "$kind" in
    unavailable)
      local_registry_identity_verdict 0 unavailable row 'registered root is unavailable'
      return "$?"
      ;;
    project)
      local_registry_identity_verdict 0 not-applicable row 'project has no registered worktree root'
      return "$?"
      ;;
    worktree|checkout) ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
  # Decode once per record. Newlines are forbidden in identity fields, so a
  # line-delimited record is lossless (including spaces and backslashes). The
  # final sentinel preserves a nullable last field across command substitution.
  fields="$(printf '%s\n' "$row" | jq -r '
    [.checkout_id, .checkout_root, .git_common_dir, .root, (.worktree_id // "")]
    | if all(.[]; type == "string" and (contains("\n") | not))
      then .[], "." else error("invalid identity fields") end
  ')" || return "$TRELLIS_EX_STATE"
  { IFS= read -r checkout_id; IFS= read -r checkout_root; IFS= read -r common
    IFS= read -r root; IFS= read -r worktree_id; } <<EOF
$fields
EOF
  if [ "$kind" = worktree ]; then scope=worktree; else scope=checkout; fi

  # 2. Stored checkout hash. Identical to the check the owning checkout row
  #    runs, so a failure here is checkout-scoped on either kind of row.
  if id="$(local_registry_sha256 "$common" 2>/dev/null)"; then
    if [ "$id" != "$checkout_id" ]; then
      local_registry_identity_verdict "$TRELLIS_EX_STATE" identity_error checkout \
        'checkout ID does not match recorded Git common directory'
      return "$?"
    fi
  else
    rc="$?"
    local_registry_identity_class_verdict "$rc" checkout \
      'checkout ID could not be hashed from the registered row'
    return "$?"
  fi

  # 3. Stored worktree hash.
  if [ "$kind" = worktree ]; then
    if id="$(local_registry_sha256 "$root" 2>/dev/null)"; then
      if [ "$id" != "$worktree_id" ]; then
        local_registry_identity_verdict "$TRELLIS_EX_STATE" identity_error worktree \
          'worktree ID does not match recorded root'
        return "$?"
      fi
    else
      rc="$?"
      local_registry_identity_class_verdict "$rc" worktree \
        'worktree ID could not be hashed from the registered row'
      return "$?"
    fi
  fi

  # 4. Reachability. Only now — the stored hashes above already had their say.
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    local_registry_identity_verdict 0 unavailable "$scope" 'registered root is unavailable'
    return "$?"
  fi

  # 5. Live canonical Git identity.
  # `if cmd; then :; else rc=$?`, never `if ! cmd; then rc=$?` — `!` makes the
  # pipeline's own status the NEGATED one, so the failing class is lost.
  if actual_identity="$(local_registry_identity_for_root "$root" 2>/dev/null)"; then
    :
  else
    rc="$?"
    local_registry_identity_class_verdict "$rc" "$scope" \
      'reachable root cannot be resolved as a canonical Git worktree'
    return "$?"
  fi
  fields="$(printf '%s\n' "$actual_identity" | jq -r '
    [.root, .checkout_root, .git_common_dir, .checkout_id, .worktree_id]
    | if all(.[]; type == "string" and (contains("\n") | not))
      then .[], "." else error("invalid live identity fields") end
  ')" || return "$TRELLIS_EX_STATE"
  { IFS= read -r actual_root; IFS= read -r actual_checkout_root; IFS= read -r actual_common
    IFS= read -r actual_checkout_id; IFS= read -r actual_worktree_id; } <<EOF
$fields
EOF
  if [ "$actual_root" != "$root" ] || [ "$actual_checkout_root" != "$checkout_root" ] ||
     [ "$actual_common" != "$common" ] || [ "$actual_checkout_id" != "$checkout_id" ] ||
     { [ "$kind" = worktree ] && [ "$actual_worktree_id" != "$worktree_id" ]; }; then
    local_registry_identity_verdict "$TRELLIS_EX_STATE" identity_error "$scope" \
      'registered canonical Git identity no longer matches'
    return "$?"
  fi
  local_registry_identity_verdict 0 verified "$scope" 'current Git identity exactly matches the registered row'
}

# Strict identity validation for exactly ONE row. ROW is the flattened record
# {kind, checkout_id, checkout_root, git_common_dir, worktree_id, root} that
# `local_registry_validate_available_identities` builds. This is the ABORT
# projection of the classifier above: same ordered checks, same vocabulary, and
# the verdict's class becomes the exit class after its detail is reported.
# Callers that must not abort on an unrelated broken row validate only the rows
# they are about to bind, through `local_registry_validate_bound_row_identity`,
# and get identical strictness for those rows.
local_registry_validate_identity_row() {
  local row="${1:-}" verdict class detail root
  verdict="$(local_registry_classify_identity_row "$row")" || return "$?"
  class="$(printf '%s\n' "$verdict" | jq -r '.class // empty')" || return "$TRELLIS_EX_STATE"
  # Compared as TEXT, and any class outside the vocabulary fails CLOSED. An
  # `[ "$class" -ne 0 ]` here would error out on an empty class and the `||`
  # arm would then report the row clean — a missing verdict must never read as
  # a passing one.
  case "$class" in
    0) return 0 ;;
    "$TRELLIS_EX_STATE"|"$TRELLIS_EX_UNAVAILABLE") ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
  detail="$(printf '%s\n' "$verdict" | jq -r '.detail')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  local_registry_err "$detail: ${root:-<no recorded root>}"
  return "$class"
}

# Validate ONLY the rows a caller is about to bind: the checkout named by
# CHECKOUT_ID and, when WORKTREE_ID is non-empty, that worktree. Each is checked
# by `local_registry_validate_identity_row`, so the target is exactly as strict
# as the whole-file validator makes it — an identity_error target still fails
# class 4, and an unhashable or unresolvable one still returns its own 4/5
# class. A row that is absent validates vacuously; whether an absent row is
# legal is the caller's own comparison to make. No other project's rows are read,
# so one broken sibling cannot fail a healthy row's operation.
#
# The public entry point probes the hash command ONCE, for the same reason the
# listings do: every check below is a SHA-256 comparison, so an unusable hasher
# is a class-5 environment fault for the whole operation rather than a per-row
# verdict. Callers that have already probed for this operation — the bound-row
# writer, which probes once before its binding loop — use the unprobed body so
# an ENVIRONMENT probe never scales with the number of rows.
local_registry_validate_bound_row_identity() {
  local_registry_require_hash_command || return "$?"
  _local_registry_validate_bound_row_identity "$@"
}

_local_registry_validate_bound_row_identity() {
  local state="${1:-}" checkout_id="${2:-}" worktree_id="${3:-}" rows row rc=0
  [ "$#" -ge 2 ] || return "$TRELLIS_EX_USAGE"
  [ -n "$checkout_id" ] || return 0
  rows="$(printf '%s\n' "$state" | jq -c \
    --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
    .projects | to_entries[] as $project
    | $project.value.checkouts | to_entries[] as $entry
    | select($entry.key == $checkout)
    | {kind: "checkout", checkout_id: $entry.key,
       checkout_root: $entry.value.root,
       git_common_dir: $entry.value.git_common_dir,
       worktree_id: null, root: $entry.value.root},
      ($entry.value.worktrees | to_entries[]?
       | select($worktree != "" and .key == $worktree)
       | {kind: "worktree", checkout_id: $entry.key,
          checkout_root: $entry.value.root,
          git_common_dir: $entry.value.git_common_dir,
          worktree_id: .key, root: .value.root})
  ')" || return "$TRELLIS_EX_STATE"
  [ -n "$rows" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    local_registry_validate_identity_row "$row" || { rc="$?"; break; }
  done <<EOF
$rows
EOF
  return "$rc"
}

# local_registry_validate_bound_rows STATE CHECKOUT_ID WORKTREE_ID...: the
# strict identity validation local_registry_validate_bound_row_identity makes
# for each (checkout, worktree) pair, with the checkout row checked once and
# each named worktree row once (stage B item 3). From
# LOCAL_REGISTRY_BOUND_ROWS_BATCH_MIN rows up, the batch classifier
# (_local_registry_batch_run: positive-only proofs, observed twice) runs on
# exactly these rows; rows it proves verified skip the scalar classifier and
# every miss takes it in input order. After each scalar pass the proven rows
# are observed again, as the listing does (r152-registry M1): a row that lost
# its proof meanwhile takes the scalar classifier next, so a slow miss never
# lets an earlier proof stand. The first refusal, its diagnostic and its
# status are the scalar ones. Any batch or recheck failure validates every row
# scalar.
LOCAL_REGISTRY_BOUND_ROWS_BATCH_MIN=4
local_registry_validate_bound_rows() {
  local_registry_require_hash_command || return "$?"
  local state="${1:-}" checkout_id="${2:-}" rows row rc=0 count dir="" batch="" input
  [ "$#" -ge 2 ] || return "$TRELLIS_EX_USAGE"
  shift 2
  [ -n "$checkout_id" ] || return 0
  rows="$(printf '%s\n' "$state" | jq -c --arg checkout "$checkout_id" '
    ($ARGS.positional | map(select(. != "")) | reduce .[] as $w ([]; if index([$w]) then . else . + [$w] end)) as $wanted
    | .projects | to_entries[] as $project
    | $project.value.checkouts | to_entries[] as $entry
    | select($entry.key == $checkout)
    | {kind: "checkout", checkout_id: $entry.key,
       checkout_root: $entry.value.root,
       git_common_dir: $entry.value.git_common_dir,
       worktree_id: null, root: $entry.value.root},
      ($wanted[] as $worktree
       | $entry.value.worktrees | to_entries[]?
       | select(.key == $worktree)
       | {kind: "worktree", checkout_id: $entry.key,
          checkout_root: $entry.value.root,
          git_common_dir: $entry.value.git_common_dir,
          worktree_id: .key, root: .value.root})
  ' --args "$@")" || return "$TRELLIS_EX_STATE"
  # r152-create-3 (the r152-registry L3 class): a generator that succeeds
  # with a short or altered stream must not drop a candidate. Count the
  # selected rows independently and match every row to the state: exactly
  # the generator's fields, each (kind, worktree) once.
  # Both reach jq on stdin (the rows as one JSON string), never as an
  # argument, so a large candidate set cannot hit the exec size limit.
  if ! { printf '%s\n' "$state"; printf '%s' "$rows" | jq -Rs .; } | jq -e -s --arg checkout "$checkout_id" '
    .[0] as $s | .[1] as $raw
    | ($raw | type == "string") and (length == 2)
    | if . then $s else error("framing") end
    | (reduce ($ARGS.positional[] | select(. != "")) as $w ({}; .[$w] = true)) as $wanted
    | [ $s.projects[] | .checkouts | to_entries[] | select(.key == $checkout) ] as $entries
    | ($entries | map(1 + ([.value.worktrees | objects | keys[]
        | select($wanted[.] == true)] | length)) | add // 0) as $expected
    | (if $raw == "" then [] else ($raw | split("\n")) end) as $lines
    | ($lines | length) == $expected
      and ([$lines[] | try (fromjson | [.kind, .worktree_id]) catch null] | unique | map(select(. != null)) | length) == $expected
      and all($lines[]; try (fromjson as $r
        | ($r | type == "object" and (keys == ["checkout_id", "checkout_root", "git_common_dir", "kind", "root", "worktree_id"]))
        and any($entries[]; .value as $e
            | $r.checkout_id == .key and $r.checkout_root == $e.root
              and $r.git_common_dir == $e.git_common_dir
              and (if $r.kind == "checkout" then $r.worktree_id == null and $r.root == $e.root
                   elif $r.kind == "worktree" then ($r.worktree_id | type == "string")
                     and $wanted[$r.worktree_id] == true
                     and ($e.worktrees | objects | has($r.worktree_id))
                     and $r.root == $e.worktrees[$r.worktree_id].root
                   else false end))) catch false)
  ' --args "$@" >/dev/null 2>&1; then
    local_registry_err 'registry row generator produced an incomplete or invalid stream'
    return "$TRELLIS_EX_STATE"
  fi
  [ -n "$rows" ] || return 0
  input="$rows"
  count="$(printf '%s\n' "$rows" | grep -c .)"
  if [ "$count" -ge "$LOCAL_REGISTRY_BOUND_ROWS_BATCH_MIN" ] &&
     dir="$(mktemp -d "${TMPDIR:-/tmp}/trellis.registry.bound.XXXXXX" 2>/dev/null)"; then
    if printf '%s\n' "$state" > "$dir/state" && printf '%s\n' "$rows" > "$dir/rows" && mkdir "$dir/batch" &&
       _local_registry_batch_run "$dir/state" "$dir/rows" "$dir/batch" 2>/dev/null &&
       input="$(cat "$dir/batch/row-misses")"; then
      batch="$dir/batch"
    else
      input="$rows"
    fi
  fi
  while :; do
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      local_registry_validate_identity_row "$row" || { rc="$?"; break 2; }
    done <<EOF
$input
EOF
    [ -n "$batch" ] || break
    # Observe the proven rows again; those that lost their proof are next. A
    # recheck that cannot run sends every row to the scalar classifier.
    if cp "$batch/proof" "$batch/proof.previous" &&
       cmp -s "$batch/proof" "$batch/proof.previous" &&
       _local_registry_batch_recheck "$dir/rows" "$batch" 2>/dev/null &&
       _local_registry_batch_delta "$dir/rows" "$batch" 2>/dev/null &&
       input="$(cat "$batch/row-delta")"; then
      [ -n "$input" ] || break
    else
      input="$rows" batch=""
    fi
  done
  if [ -n "$dir" ]; then
    _local_registry_batch_cleanup "$dir/batch"
    rm -f "$dir/state" "$dir/rows"
    rmdir "$dir" 2>/dev/null || :
  fi
  return "$rc"
}

# Stored hashes remain verifiable even while a volume is unavailable. Reachable
# paths additionally must resolve to their recorded canonical Git identity.
local_registry_validate_available_identities() {
  local registry_json="${1:-}" row rc=0 rows
  local_registry_require_hash_command || return "$?"
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.identities.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if ! jq -c '
    .projects | to_entries[] as $project
    | $project.value.checkouts | to_entries[] as $checkout
    | {kind: "checkout", checkout_id: $checkout.key,
       checkout_root: $checkout.value.root,
       git_common_dir: $checkout.value.git_common_dir,
       root: $checkout.value.root},
      ($checkout.value.worktrees | to_entries[]?
       | {kind: "worktree", checkout_id: $checkout.key,
          checkout_root: $checkout.value.root,
          git_common_dir: $checkout.value.git_common_dir,
          worktree_id: .key, root: .value.root})
  ' "$registry_json" > "$rows"; then
    rm -f "$rows"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r row; do
    local_registry_validate_identity_row "$row" || { rc="$?"; break; }
  done < "$rows"
  rm -f "$rows"
  return "$rc"
}

local_registry_read_state() {
  local home="${1:-}" registry tmp rc=0
  home="$(local_registry_home "$home")" || return "$?"
  registry="$(local_registry_path "$home")" || return "$?"
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    # Load migrates the retired token into the temp copy (one stderr notice
    # when affected) and validates it, so strict readers tolerate legacy rows
    # without rewriting the persisted file.
    tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.read.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    local_registry_load "$home" "$tmp" || rc="$?"
    if [ "$rc" -eq 0 ]; then
      local_registry_validate_available_identities "$tmp" || rc="$?"
    fi
    if [ "$rc" -eq 0 ]; then
      jq -S . "$tmp" || rc="$TRELLIS_EX_STATE"
    fi
    rm -f "$tmp"
    return "$rc"
  else
    local_registry_empty_json | jq -S .
  fi
}

# Read persisted registry state for diagnostics without making globally strict
# identity validation hide independently inspectable rows.
local_registry_read_diagnostic_state() {
  local home="${1:-}" registry tmp rc=0
  home="$(local_registry_home "$home")" || return "$?"
  registry="$(local_registry_path "$home")" || return "$?"
  if [ -e "$registry" ] || [ -L "$registry" ]; then
    # Same migrated-load contract as the strict reader: legacy rows validate
    # after the retired token is dropped into the temp copy, never in place.
    tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.read.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    local_registry_load "$home" "$tmp" || rc="$?"
    if [ "$rc" -eq 0 ]; then
      jq -S . "$tmp" || rc="$TRELLIS_EX_STATE"
    fi
    rm -f "$tmp"
    return "$rc"
  else
    local_registry_empty_json | jq -S .
  fi
}

# A stat-only change detector for an operation's diagnostic registry snapshot.
# It is not a registry validity check. Bind both the registry and its parent,
# including the absent-file case, so rename/create/remove cannot go unnoticed.
# Coarse or unavailable ctime cannot support this optimization: the caller
# must instead re-read and compare the validated state. No path is followed.
_local_registry_diagnostic_token() {
  _local_registry_file_token "$1" "$1/registry.json"
}

# ls -lde (Darwin) also lists ACL entries on indented lines, even when an
# xattr's @ masks the + mode marker. GNU ls -ld marks ACLs with +. Accept only
# exactly the requested number of ordinary, ACL-free node lines.
_local_registry_acl_listing_clear() {
  local expected="$1" listing="$2" count=0 line mode
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  while IFS= read -r line; do
    case "$line" in ''|[[:space:]]*) return 1 ;; *' '*) ;; *) return 1 ;; esac
    mode="${line%% *}"
    [[ "$mode" =~ ^[-bcdlps][rwxstST-]{9}[@]?$ ]] || return 1
    count=$((count + 1))
  done <<< "$listing"
  [ "$count" -eq "$expected" ]
}

# Also used for the operation-local owner snapshot. Bind every directory from
# ROOT to the parent, not just the leaf: a renamed-and-restored ancestor can
# otherwise redirect a read while leaving the immediate parent inode unchanged.
_local_registry_file_token() {
  local parent="$1" file="$2" root="${3:-$1}" cursor present=0 os stat_bin rows
  local dev ino size mode mt ct owner_uid mode_bits fraction count=0 coarse_count=0 acl_listing
  local -a paths coarse_paths
  [ "${file%/*}" = "$parent" ] || return 1
  if [ "$root" = / ]; then
    case "$parent" in /*) ;; *) return 1 ;; esac
  else
    case "$parent" in "$root"|"$root"/*) ;; *) return 1 ;; esac
  fi
  paths=(); coarse_paths=()
  cursor="$parent"
  while :; do
    [ -d "$cursor" ] && [ ! -L "$cursor" ] || return 1
    paths+=("$cursor")
    [ "$cursor" = "$root" ] && break
    cursor="${cursor%/*}"
    [ -n "$cursor" ] || cursor=/
  done
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    present=1
    paths+=("$file")
  fi
  os="$(/usr/bin/uname -s 2>/dev/null)" || return 1
  if [ -x /usr/bin/stat ]; then stat_bin=/usr/bin/stat
  elif [ -x /bin/stat ]; then stat_bin=/bin/stat
  else return 1
  fi
  case "$os:$root" in
    Darwin:/) rows="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 "$stat_bin" -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc\t%u' -- "${paths[@]}" 2>/dev/null)" || return 1 ;;
    Linux:/) rows="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 "$stat_bin" --printf='%d\t%i\t%s\t%f\t%y\t%z\t%u\n' -- "${paths[@]}" 2>/dev/null)" || return 1 ;;
    Darwin:*) rows="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 "$stat_bin" -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc' -- "${paths[@]}" 2>/dev/null)" || return 1 ;;
    Linux:*) rows="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 "$stat_bin" --printf='%d\t%i\t%s\t%f\t%y\t%z\n' -- "${paths[@]}" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  while IFS=$'\t' read -r dev ino size mode mt ct owner_uid; do
    [ -n "$dev" ] && [ -n "$ino" ] && [ -n "$size" ] && [ -n "$mode" ] && [ -n "$mt" ] || return 1
    fraction="${ct##*.}"
    fraction="${fraction%% *}"
    case "$fraction" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#fraction}" -eq 9 ] || return 1
    if [ "${fraction#???}" = 000000 ]; then
      # Only the new root=/ form may tolerate a coarse, root-owned node:
      # non-root callers cannot write it through ordinary permission bits.
      # Its parent is also tokenized; callers that project away parent times
      # retain their own documented swap-and-restore reporting window.
      [ "$root" = / ] && [ "$EUID" -ne 0 ] && [ "$owner_uid" = 0 ] || return 1
      case "$os:$mode" in
        Darwin:*[!0-7]*|Linux:*[!0-9a-fA-F]*) return 1 ;;
        Darwin:*) mode_bits=$((8#$mode)) ;;
        Linux:*) mode_bits=$((16#$mode)) ;;
        *) return 1 ;;
      esac
      [ $((mode_bits & 8#022)) -eq 0 ] || return 1
      coarse_paths[$coarse_count]="${paths[$count]}"
      coarse_count=$((coarse_count + 1))
    fi
    count=$((count + 1))
  done <<EOF
$rows
EOF
  [ "$count" -eq "${#paths[@]}" ] || return 1
  if [ "$coarse_count" -gt 0 ]; then
    case "$os" in
      Darwin) acl_listing="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /bin/ls -lde -- "${coarse_paths[@]}" 2>/dev/null)" || return 1 ;;
      Linux) acl_listing="$(/usr/bin/env -i LC_ALL=C TZ=UTC0 /bin/ls -ld -- "${coarse_paths[@]}" 2>/dev/null)" || return 1 ;;
      *) return 1 ;;
    esac
    _local_registry_acl_listing_clear "$coarse_count" "$acl_listing" || return 1
  fi
  printf '%s\n%s\n' "$present" "$rows"
}

# Proposal primitive for CLIs and later attachment transactions. It does not
# lock or write machine state. INPUT and OUTPUT are regular JSON files.
# IDENTITY_SCOPE (optional 14th argument) selects which rows of the resulting
# proposal must identity-validate. `whole-file` (the default, and what the
# multi-row batch callers in registry.sh rely on) validates every registered
# row. `bound-row` validates only the checkout and worktree row this proposal
# writes, with the same strictness, so a single-row registration is not blocked
# by an unrelated project's broken row. The registry-wide collision, uniqueness
# and discovery-ignore checks below are STRUCTURAL and run in both scopes.
local_registry_propose_register_worktree() {
  local input="${1:-}" output="${2:-}" fleet="${3:-}" project_id="${4:-}"
  local checkout_root="${5:-}" common="${6:-}" checkout_id="${7:-}" worktree_root="${8:-}" worktree_id="${9:-}"
  local release="${10:-}" harnesses="${11:-}" attachment_id="${12:-}" metadata="${13:-}"
  local identity_scope="${14:-whole-file}" key
  if [ "$#" -lt 13 ] || [ "$#" -gt 14 ]; then
    local_registry_err "proposal register requires input output fleet project checkout-root common-dir checkout-id worktree-root worktree-id release harnesses attachment-id metadata [identity-scope]"
    return "$TRELLIS_EX_USAGE"
  fi
  case "$identity_scope" in
    whole-file|bound-row) ;;
    *) local_registry_err "invalid proposal identity scope: $identity_scope"; return "$TRELLIS_EX_USAGE" ;;
  esac
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  checkout_root="$(local_registry_normalize_absolute_safe_path "checkout root" "$checkout_root")" || return "$?"
  common="$(local_registry_normalize_absolute_safe_path "Git common directory" "$common")" || return "$?"
  worktree_root="$(local_registry_normalize_absolute_safe_path "worktree root" "$worktree_root")" || return "$?"
  if ! printf '%s' "$checkout_id" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$' || ! printf '%s' "$worktree_id" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'; then
    local_registry_err "checkout and worktree IDs must be SHA-256 values"
    return "$TRELLIS_EX_STATE"
  fi
  release="$(local_registry_normalize_release "$release")" || return "$?"
  harnesses="$(local_registry_normalize_harnesses "$harnesses")" || return "$?"
  local_registry_require_attachment_id "$attachment_id" || return "$?"
  metadata="$(local_registry_normalize_metadata "$metadata")" || return "$?"
  local_registry_validate_file "$input" || return "$?"

  if ! jq -e \
    --arg key "$key" --arg checkout_id "$checkout_id" --arg common "$common" \
    --arg checkout_root "$checkout_root" --arg root "$worktree_root" \
    --arg worktree_id "$worktree_id" '
      def roots:
        [ .projects | to_entries[] as $project
          | $project.value.checkouts | to_entries[] as $checkout
          | {owner: ($project.key + ":" + $checkout.key), root: $checkout.value.root},
            ($checkout.value.worktrees[]? | {owner: ($project.key + ":" + $checkout.key), root: .root}) ];
      def unavailable:
        [ .projects | to_entries[] as $project
          | ($project.value.unavailable_roots // [])[] | {project: $project.key, root: .} ];
      def ignored:
        [ (.discovery_ignores // {}) | .[]? | .[]? | .path ];
      def overlaps($left; $right):
        $left == $right
        or ($left | startswith($right + "/"))
        or ($right | startswith($left + "/"));
      (.projects[$key].checkouts[$checkout_id] // null) as $target
      | (($target == null) or ($target.git_common_dir == $common))
      and ([.projects | to_entries[] as $project | $project.value.checkouts | to_entries[]
             | select((.key == $checkout_id or .value.git_common_dir == $common)
                      and ($project.key + ":" + .key) != ($key + ":" + $checkout_id))] | length == 0)
      and ([roots[] | select(.root == $root and .owner != ($key + ":" + $checkout_id))] | length == 0)
      # STRUCTURAL uniqueness, in BOTH identity scopes. The `roots` check above
      # excludes the target owner wholesale (the checkout row legitimately
      # shares a root with its primary worktree), so it cannot see a SECOND
      # worktree row inside the same checkout holding this root. Whole-file
      # identity validation used to catch that by accident; under bound-row
      # scope nothing else does, so state it explicitly.
      and ([(.projects[$key].checkouts[$checkout_id].worktrees // {}) | to_entries[]
            | select(.key != $worktree_id and .value.root == $root)] | length == 0)
      # A worktree ID is the hash of one canonical root, so the same ID under
      # two different checkouts is corrupt by construction.
      and ([.projects | to_entries[] as $project
            | $project.value.checkouts | to_entries[]
            | select(($project.key + ":" + .key) != ($key + ":" + $checkout_id))
            | (.value.worktrees // {}) | keys[]
            | select(. == $worktree_id)] | length == 0)
      and ([unavailable[] | select(.root == $root and .project != $key)] | length == 0)
      and ([ignored[] as $ignore
            | select(overlaps($ignore; $root) or overlaps($ignore; $checkout_root))] | length == 0)
    ' "$input" >/dev/null 2>&1; then
    local_registry_err "identity or path collision for $key at $worktree_root"
    return "$TRELLIS_EX_CONFLICT"
  fi

  if ! trellis_jq \
    --arg key "$key" --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg checkout_root "$checkout_root" --arg common "$common" --arg checkout_id "$checkout_id" \
    --arg worktree_root "$worktree_root" --arg worktree_id "$worktree_id" \
    --arg release "$release" --arg attachment_id "$attachment_id" \
    --argjson harnesses "$harnesses" --argjson metadata "$metadata" '
      .projects = (.projects // {})
      | .projects[$key] = (.projects[$key] // {fleet: $fleet, project_id: $project_id, status: "active", metadata: {}, checkouts: {}})
      | .projects[$key].fleet = $fleet
      | .projects[$key].project_id = $project_id
      | .projects[$key].status = "active"
      | .projects[$key].metadata = ((.projects[$key].metadata // {}) + $metadata)
      | .projects[$key].unavailable_roots = ((.projects[$key].unavailable_roots // []) | map(select(. != $worktree_root)) | unique)
      | if (.projects[$key].unavailable_roots | length) == 0 then del(.projects[$key].unavailable_roots) else . end
      | .projects[$key].checkouts[$checkout_id] = (.projects[$key].checkouts[$checkout_id] // {root: $checkout_root, git_common_dir: $common, harnesses: [], worktrees: {}})
      | .projects[$key].checkouts[$checkout_id].root = $checkout_root
      | .projects[$key].checkouts[$checkout_id].git_common_dir = $common
      | if $release != "" then .projects[$key].checkouts[$checkout_id].release = $release else . end
      | if ($harnesses | length) > 0 then .projects[$key].checkouts[$checkout_id].harnesses = $harnesses else . end
      | .projects[$key].checkouts[$checkout_id].worktrees[$worktree_id] = (.projects[$key].checkouts[$checkout_id].worktrees[$worktree_id] // {root: $worktree_root})
      | .projects[$key].checkouts[$checkout_id].worktrees[$worktree_id].root = $worktree_root
      | if $attachment_id != "" then .projects[$key].checkouts[$checkout_id].worktrees[$worktree_id].attachment_id = $attachment_id else . end
    ' "$input" > "$output"; then
    local_registry_err "could not construct registry proposal"
    return "$TRELLIS_EX_STATE"
  fi
  local_registry_validate_file "$output" || return "$?"
  if [ "$identity_scope" = bound-row ]; then
    local_registry_validate_bound_row_identity "$(jq -c . "$output")" "$checkout_id" "$worktree_id"
  else
    local_registry_validate_available_identities "$output"
  fi
}

local_registry_propose_unavailable_root() {
  local input="${1:-}" output="${2:-}" fleet="${3:-}" project_id="${4:-}" root="${5:-}" metadata="${6:-}" key
  [ "$#" -eq 6 ] || {
    local_registry_err "proposal unavailable requires input output fleet project root metadata"
    return "$TRELLIS_EX_USAGE"
  }
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  root="$(local_registry_normalize_absolute_safe_path "unavailable root" "$root")" || return "$?"
  metadata="$(local_registry_normalize_metadata "$metadata")" || return "$?"
  local_registry_validate_file "$input" || return "$?"
  if [ -e "$root" ] || [ -L "$root" ]; then
    local_registry_err "cannot record an existing path as unavailable: $root"
    return "$TRELLIS_EX_CONFLICT"
  fi
  if ! jq -e --arg key "$key" --arg root "$root" '
    def roots:
      [ .projects | to_entries[] as $project
        | $project.value.checkouts | to_entries[] as $checkout
        | {project: $project.key, root: $checkout.value.root},
          ($checkout.value.worktrees[]? | {project: $project.key, root: .root}) ];
    def unavailable:
      [ .projects | to_entries[] as $project
        | ($project.value.unavailable_roots // [])[] | {project: $project.key, root: .} ];
    def ignored:
      [ (.discovery_ignores // {}) | .[]? | .[]? | .path ];
    def overlaps($left; $right):
      $left == $right
      or ($left | startswith($right + "/"))
      or ($right | startswith($left + "/"));
    ([roots[] | select(.root == $root)] | length == 0)
    and ([unavailable[] | select(.root == $root and .project != $key)] | length == 0)
    and ([ignored[] as $ignore | select(overlaps($ignore; $root))] | length == 0)
  ' "$input" >/dev/null 2>&1; then
    local_registry_err "identity or path collision for unavailable root $root"
    return "$TRELLIS_EX_CONFLICT"
  fi
  if ! trellis_jq \
    --arg key "$key" --arg fleet "$fleet" --arg project_id "$project_id" --arg root "$root" --argjson metadata "$metadata" '
      .projects = (.projects // {})
      | .projects[$key] = (.projects[$key] // {fleet: $fleet, project_id: $project_id, status: "unavailable", metadata: {}, checkouts: {}})
      | .projects[$key].fleet = $fleet
      | .projects[$key].project_id = $project_id
      | .projects[$key].metadata = ((.projects[$key].metadata // {}) + $metadata)
      | .projects[$key].unavailable_roots = ((.projects[$key].unavailable_roots // []) + [$root] | unique)
    ' "$input" > "$output"; then
    local_registry_err "could not construct unavailable registry proposal"
    return "$TRELLIS_EX_STATE"
  fi
  local_registry_validate_file "$output"
}

local_registry_propose_discovery_ignores() {
  local input="${1:-}" output="${2:-}" fleet="${3:-}" ignores="${4:-}" normalized
  [ "$#" -eq 4 ] || {
    local_registry_err "proposal discovery ignores requires input output fleet ignores-json"
    return "$TRELLIS_EX_USAGE"
  }
  trellis_home_require_fleet_name "$fleet" || return "$?"
  normalized="$(printf '%s\n' "$ignores" | jq -cS '
    def safe_text:
      type == "string" and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def safe_path:
      safe_text and length >= 2 and startswith("/")
      and (contains("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    if type != "array" then error("not an array")
    else map(.path |= sub("/+$"; "") | if has("legacy_path") then .legacy_path |= sub("/+$"; "") else . end)
      | if all(.[]; type == "object"
                       and ((keys | sort) == ["path", "reason"]
                            or (keys | sort) == ["legacy_path", "path", "reason"])
                       and (.path | safe_path)
                       and ((has("legacy_path") | not) or (.legacy_path | safe_path))
                       and (.reason | safe_text and length > 0))
           and ((map(.path) | unique | length) == length)
        then sort_by(.path) else error("invalid records") end
    end
  ' 2>/dev/null)" || {
    local_registry_err "discovery ignores must be unique safe path and reason records"
    return "$TRELLIS_EX_STATE"
  }
  local_registry_validate_file "$input" || return "$?"
  if ! trellis_jq -e --argjson ignores "$normalized" '
    def roots:
      [ .projects | to_entries[] as $project
        | $project.value.checkouts | to_entries[] as $checkout
        | $checkout.value.root, ($checkout.value.worktrees[]?.root) ];
    def unavailable:
      [ .projects | to_entries[] as $project
        | ($project.value.unavailable_roots // [])[] ];
    def overlaps($left; $right):
      $left == $right
      or ($left | startswith($right + "/"))
      or ($right | startswith($left + "/"));
    (roots + unavailable) as $owned
    | ([$ignores[] as $ignore | $owned[] as $root
         | select(overlaps($ignore.path; $root))] | length) == 0
  ' "$input" >/dev/null 2>&1; then
    local_registry_err "discovery ignore collides with a registered project path"
    return "$TRELLIS_EX_CONFLICT"
  fi
  if ! trellis_jq --arg fleet "$fleet" --argjson ignores "$normalized" '
    .discovery_ignores = (.discovery_ignores // {})
    | .discovery_ignores[$fleet] = $ignores
    | if (.discovery_ignores[$fleet] | length) == 0
      then del(.discovery_ignores[$fleet]) else . end
  ' "$input" > "$output"; then
    local_registry_err "could not construct discovery-ignore proposal"
    return "$TRELLIS_EX_STATE"
  fi
  local_registry_validate_file "$output"
}

local_registry_propose_status() {
  local input="${1:-}" output="${2:-}" fleet="${3:-}" project_id="${4:-}" status="${5:-}" key
  [ "$#" -eq 5 ] || return "$TRELLIS_EX_USAGE"
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  case "$status" in active|unavailable|detached) ;; *)
    local_registry_err "invalid project status: $status"; return "$TRELLIS_EX_USAGE" ;;
  esac
  if ! jq -e --arg key "$key" '.projects[$key] != null' "$input" >/dev/null; then
    local_registry_err "project is not registered: $key"; return "$TRELLIS_EX_UNAVAILABLE"
  fi
  jq --arg key "$key" --arg status "$status" '.projects[$key].status = $status' "$input" > "$output" || return "$TRELLIS_EX_STATE"
  local_registry_validate_file "$output"
}

# Sets machine-local metadata on one ALREADY REGISTERED project row. The merge
# is SHALLOW and deliberate: the supplied top-level keys replace their
# counterparts and every other key is retained, so annotating a row with local
# routing cannot silently drop the `legacy` block an import recorded. It creates
# no row — a project this machine has not registered is a class-5 refusal, not
# an invitation to invent inventory.
local_registry_propose_metadata() {
  local input="${1:-}" output="${2:-}" fleet="${3:-}" project_id="${4:-}" metadata="${5:-}" key
  [ "$#" -eq 5 ] || {
    local_registry_err "proposal metadata requires input output fleet project metadata-json"
    return "$TRELLIS_EX_USAGE"
  }
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  metadata="$(local_registry_normalize_metadata "$metadata")" || return "$?"
  local_registry_validate_file "$input" || return "$?"
  if ! jq -e --arg key "$key" '.projects[$key] != null' "$input" >/dev/null 2>&1; then
    local_registry_err "project is not registered: $key"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if ! trellis_jq --arg key "$key" --argjson metadata "$metadata" \
    '.projects[$key].metadata = (.projects[$key].metadata + $metadata)' "$input" > "$output"; then
    local_registry_err "could not construct metadata proposal for $key"
    return "$TRELLIS_EX_STATE"
  fi
  local_registry_validate_file "$output"
}

local_registry_register_worktree() {
  local home="${1:-}" fleet="${2:-}" project_id="${3:-}" root_input="${4:-}" release="${5:-}" harnesses="${6:-}" attachment_id="${7:-}" metadata="${8:-}"
  local identity checkout_root common checkout_id root worktree_id base proposal rc=0
  if [ "$#" -lt 7 ] || [ "$#" -gt 8 ]; then
    local_registry_err "register_worktree requires HOME FLEET PROJECT_ID ROOT RELEASE HARNESSES_JSON ATTACHMENT_ID [METADATA_JSON]"
    return "$TRELLIS_EX_USAGE"
  fi
  home="$(local_registry_home "$home")" || return "$?"
  [ -n "$metadata" ] || metadata='{}'
  # One functional hash probe per WRITE OPERATION, before the registry lock is
  # taken. Without it a machine-wide hasher fault surfaced only after the lock,
  # the proposal and the temp files, as an indistinguishable per-row failure.
  local_registry_require_hash_command || return "$?"
  identity="$(local_registry_identity_for_root "$root_input")" || return "$?"
  checkout_root="$(printf '%s\n' "$identity" | jq -r '.checkout_root')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  root="$(printf '%s\n' "$identity" | jq -r '.root')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  trellis_home_prepare_home "$home" || return "$?"
  trellis_home_registry_lock_acquire "$home" || return "$?"
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || { trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.proposal.XXXXXX")" || { rm -f "$base"; trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ]; then
    # This transaction binds exactly the checkout and worktree rows resolved from
    # the live Git identity of ROOT, so it validates exactly those rows — with
    # the whole-file validator's strictness — rather than aborting on some other
    # project's broken row. Structural and schema validation stay whole-file.
    local_registry_propose_register_worktree "$base" "$proposal" "$fleet" "$project_id" "$checkout_root" "$common" "$checkout_id" "$root" "$worktree_id" "$release" "$harnesses" "$attachment_id" "$metadata" bound-row || rc="$?"
  fi
  if [ "$rc" -eq 0 ]; then
    local_registry_write_locked_bound_rows "$home" "$proposal" \
      "$(jq -cn --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
        '[{checkout_id: $checkout, worktree_id: $worktree}]')" || rc="$?"
  fi
  rm -f "$base" "$proposal"
  if ! trellis_home_lock_release >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then rc="$TRELLIS_EX_UNAVAILABLE"; fi
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$identity"
}

# Machine-local metadata writer for one registered project row. It mutates
# exactly `.projects[KEY].metadata` and binds every checkout and worktree row
# that project owns, so an unrelated broken sibling elsewhere in the registry
# cannot block an annotation, and the annotated project's own rows are still
# validated with the whole-file validator's strictness.
#
# A project whose only inventory is `unavailable_roots` has no checkout or
# worktree row to bind. That case takes the whole-file contract for the same
# reason `local_registry_record_unavailable_root` does: there is nothing for
# `local_registry_write_locked_bound_rows` to vouch for, and a "project scope"
# binding would assert no identity at all.
local_registry_set_metadata() {
  local home="${1:-}" fleet="${2:-}" project_id="${3:-}" metadata="${4:-}"
  local key base proposal bindings rc=0
  [ "$#" -eq 4 ] || {
    local_registry_err "set_metadata requires HOME FLEET PROJECT_ID METADATA_JSON"
    return "$TRELLIS_EX_USAGE"
  }
  home="$(local_registry_home "$home")" || return "$?"
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  # One functional hash probe per WRITE OPERATION, before the registry lock.
  local_registry_require_hash_command || return "$?"
  trellis_home_prepare_home "$home" || return "$?"
  trellis_home_registry_lock_acquire "$home" || return "$?"
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || { trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.metadata.XXXXXX")" || { rm -f "$base"; trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ]; then
    local_registry_propose_metadata "$base" "$proposal" "$fleet" "$project_id" "$metadata" || rc="$?"
  fi
  if [ "$rc" -eq 0 ]; then
    bindings="$(jq -c --arg key "$key" '
      [ (.projects[$key].checkouts // {}) | to_entries[] as $checkout
        | if (($checkout.value.worktrees // {}) | length) == 0
          then {checkout_id: $checkout.key, worktree_id: ""}
          else ($checkout.value.worktrees | keys[]) as $worktree
            | {checkout_id: $checkout.key, worktree_id: $worktree}
          end ]
    ' "$proposal")" || rc="$TRELLIS_EX_STATE"
  fi
  if [ "$rc" -eq 0 ]; then
    if [ "$(printf '%s\n' "$bindings" | jq 'length')" -gt 0 ]; then
      local_registry_write_locked_bound_rows "$home" "$proposal" "$bindings" || rc="$?"
    else
      local_registry_write_locked "$home" "$proposal" || rc="$?"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    jq -S --arg key "$key" '{fleet: .projects[$key].fleet, project_id: .projects[$key].project_id, metadata: .projects[$key].metadata}' "$proposal" || rc="$TRELLIS_EX_STATE"
  fi
  rm -f "$base" "$proposal"
  if ! trellis_home_lock_release >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then rc="$TRELLIS_EX_UNAVAILABLE"; fi
  return "$rc"
}

# Compare-and-swap one checkout snapshot. Only harnesses may change; an exact
# after snapshot is the recovery receipt for a rename before the phase marker.
local_registry_update_harnesses() (
  local home="$1" fleet="$2" project="$3" checkout="$4" update="$5"
  local key base proposal current expected after bindings worktree rc=0
  [ "$#" -eq 5 ] || return "$TRELLIS_EX_USAGE"
  key="$(local_registry_project_key "$fleet" "$project")" || return "$?"
  printf '%s\n' "$update" | jq -e '
    type == "object" and (keys | sort) == ["after","expected"]
    and (.expected | type == "object") and (.after | type == "object")
    and (.expected | del(.harnesses)) == (.after | del(.harnesses))
    and (.after.harnesses | length) > 0
    and (.after.harnesses - .expected.harnesses | length) == 0
    and (.expected.harnesses - .after.harnesses | length) > 0
    and ([.expected.worktrees[] | select(has("attachment_id"))] | length) == 1
  ' >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  expected="$(printf '%s\n' "$update" | jq -cS '.expected')" || return "$TRELLIS_EX_STATE"
  after="$(printf '%s\n' "$update" | jq -cS '.after')" || return "$TRELLIS_EX_STATE"
  home="$(local_registry_home "$home")" || return "$?"
  trellis_home_registry_lock_acquire "$home" || return "$?"
  trap 'trellis_home_lock_release >/dev/null 2>&1' EXIT
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.proposal.XXXXXX")" || { rm -f "$base"; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ]; then
    current="$(jq -cS --arg key "$key" --arg checkout "$checkout" '.projects[$key].checkouts[$checkout]' "$base")" || rc="$TRELLIS_EX_STATE"
  fi
  if [ "$rc" -eq 0 ]; then
    if [ "$current" != "$expected" ] && [ "$current" != "$after" ]; then
      local_registry_err "checkout snapshot conflict while updating harnesses for $key"
      rc="$TRELLIS_EX_CONFLICT"
    else
      # Validate both snapshots against the full schema without replacing any
      # other row. Even the idempotent path must reject a malformed expected.
      for current in "$expected" "$after"; do
        trellis_jq --arg key "$key" --arg checkout "$checkout" --argjson snapshot "$current" \
          '.projects[$key].checkouts[$checkout] = $snapshot' "$base" > "$proposal" || { rc="$TRELLIS_EX_STATE"; break; }
        local_registry_validate_file "$proposal" || { rc="$?"; break; }
      done
      if [ "$rc" -eq 0 ]; then
        bindings="$(printf '%s\n' "$after" | jq -c --arg checkout "$checkout" '[.worktrees | keys[] | {checkout_id:$checkout,worktree_id:.}]')" || rc="$TRELLIS_EX_STATE"
      fi
      if [ "$rc" -eq 0 ]; then
        if trellis_jq -e --arg key "$key" --arg checkout "$checkout" --argjson after "$after" '.projects[$key].checkouts[$checkout] == $after' "$base" >/dev/null; then
          while IFS= read -r worktree; do
            local_registry_validate_bound_row_identity "$(jq -c . "$base")" "$checkout" "$worktree" || { rc="$?"; break; }
          done < <(printf '%s\n' "$after" | jq -r '.worktrees | keys[]')
        else
          trellis_jq --arg key "$key" --arg checkout "$checkout" --argjson after "$after" \
            '.projects[$key].checkouts[$checkout].harnesses = $after.harnesses' "$base" > "$proposal" || rc="$TRELLIS_EX_STATE"
          if [ "$rc" -eq 0 ]; then
            local_registry_write_locked_bound_rows "$home" "$proposal" "$bindings" || rc="$?"
          fi
        fi
      fi
    fi
  fi
  rm -f "$base" "$proposal"
  if ! trellis_home_lock_release >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then rc="$TRELLIS_EX_UNAVAILABLE"; fi
  trap - EXIT
  return "$rc"
)

# Clears only an exact attachment reference. The retained worktree/checkouts
# remain inventory so a detached checkout can be reattached without discovery.
local_registry_propose_clear_attachment() {
  local input="${1:-}" output="${2:-}" fleet="${3:-}" project_id="${4:-}" checkout_id="${5:-}" worktree_id="${6:-}" attachment_id="${7:-}" key
  [ "$#" -eq 7 ] || {
    local_registry_err "proposal clear attachment requires input output fleet project checkout-id worktree-id attachment-id"
    return "$TRELLIS_EX_USAGE"
  }
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  if ! printf '%s' "$checkout_id" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$' ||
    ! printf '%s' "$worktree_id" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'; then
    local_registry_err "checkout and worktree IDs must be SHA-256 values"
    return "$TRELLIS_EX_STATE"
  fi
  local_registry_require_attachment_id "$attachment_id" || return "$?"
  [ -n "$attachment_id" ] || return "$TRELLIS_EX_USAGE"
  local_registry_validate_file "$input" || return "$?"
  if ! jq --arg key "$key" --arg checkout "$checkout_id" --arg worktree "$worktree_id" --arg attachment "$attachment_id" '
    (.projects[$key] // null) as $project
    | if $project == null or ($project.checkouts[$checkout] // null) == null or ($project.checkouts[$checkout].worktrees[$worktree] // null) == null
      then .
      elif ($project.checkouts[$checkout].worktrees[$worktree].attachment_id // null) == null
      then .
      elif $project.checkouts[$checkout].worktrees[$worktree].attachment_id != $attachment
      then error("attachment identity conflict")
      else
        del(.projects[$key].checkouts[$checkout].worktrees[$worktree].attachment_id)
        | .projects[$key].status =
            (if any(.projects[$key].checkouts[]?.worktrees[]?; has("attachment_id")) then "active" else "detached" end)
      end
  ' "$input" > "$output"; then
    local_registry_err "attachment identity conflict while clearing $key"
    return "$TRELLIS_EX_CONFLICT"
  fi
  local_registry_validate_file "$output"
}

local_registry_clear_attachment() {
  local home="${1:-}" fleet="${2:-}" project_id="${3:-}" checkout_id="${4:-}" worktree_id="${5:-}" attachment_id="${6:-}"
  local base proposal rc=0
  [ "$#" -eq 6 ] || {
    local_registry_err "clear_attachment requires HOME FLEET PROJECT_ID CHECKOUT_ID WORKTREE_ID ATTACHMENT_ID"
    return "$TRELLIS_EX_USAGE"
  }
  home="$(local_registry_home "$home")" || return "$?"
  # One functional hash probe per WRITE OPERATION, before the registry lock.
  local_registry_require_hash_command || return "$?"
  trellis_home_prepare_home "$home" || return "$?"
  trellis_home_registry_lock_acquire "$home" || return "$?"
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || { trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.proposal.XXXXXX")" || { rm -f "$base"; trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ]; then
    local_registry_propose_clear_attachment "$base" "$proposal" "$fleet" "$project_id" "$checkout_id" "$worktree_id" "$attachment_id" || rc="$?"
  fi
  if [ "$rc" -eq 0 ]; then
    # This is the detach writer. It removes exactly one field — the
    # `attachment_id` of `.projects[KEY].checkouts[CHECKOUT].worktrees[WORKTREE]`
    # — and recomputes that project's own status; no other project's rows are
    # touched. Parity with attach/relink/seed/adopt: bind those rows and
    # validate them strictly, so one broken sibling elsewhere in the registry
    # can no longer block every detach on the machine. Whole-file SCHEMA and
    # structural validation still run.
    local_registry_write_locked_bound_rows "$home" "$proposal" \
      "$(jq -cn --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
        '[{checkout_id: $checkout, worktree_id: $worktree}]')" || rc="$?"
  fi
  rm -f "$base" "$proposal"
  if ! trellis_home_lock_release >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then rc="$TRELLIS_EX_UNAVAILABLE"; fi
  return "$rc"
}

# WHOLE-FILE identity strictness is deliberate here, and it is the one writer
# that cannot meet the bound-row floor: it mutates only `unavailable_roots`, a
# project-level array with no checkout or worktree row to bind, so there is
# nothing for `local_registry_write_locked_bound_rows` to vouch for. A
# project-scope binding mode was considered and rejected. Its floor would have to
# be "a non-empty project key plus a mode flag", which asserts no identity at
# all — a weaker contract than either existing scope, added to the writer set for
# no caller: the production path that records an unavailable root is
# `registry.sh import`, which calls `local_registry_propose_unavailable_root`
# directly and writes whole-file for its own reason (it lays down arbitrary rows
# across many projects in one transaction). Every caller of THIS function in the
# tree is a test fixture seeding a home it has just built, where whole-file
# validity holds by construction. A broken sibling blocking an unavailable-root
# recording is therefore an accepted, currently unreachable cost.
local_registry_record_unavailable_root() {
  local home="${1:-}" fleet="${2:-}" project_id="${3:-}" root="${4:-}" metadata="${5:-}"
  local base proposal rc=0
  if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
    local_registry_err "record_unavailable_root requires HOME FLEET PROJECT_ID ROOT [METADATA_JSON]"
    return "$TRELLIS_EX_USAGE"
  fi
  home="$(local_registry_home "$home")" || return "$?"
  [ -n "$metadata" ] || metadata='{}'
  # One functional hash probe per WRITE OPERATION, before the registry lock.
  # This writer validates whole-file identities, so every registered row's
  # hashes are recomputed here; an unusable hasher is a class-5 environment
  # fault for the operation, not a verdict about any row.
  local_registry_require_hash_command || return "$?"
  trellis_home_prepare_home "$home" || return "$?"
  trellis_home_registry_lock_acquire "$home" || return "$?"
  base="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.base.XXXXXX")" || { trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  proposal="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.proposal.XXXXXX")" || { rm -f "$base"; trellis_home_lock_release >/dev/null 2>&1 || true; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_load "$home" "$base" || rc="$?"
  if [ "$rc" -eq 0 ]; then local_registry_propose_unavailable_root "$base" "$proposal" "$fleet" "$project_id" "$root" "$metadata" || rc="$?"; fi
  if [ "$rc" -eq 0 ]; then local_registry_write_locked "$home" "$proposal" || rc="$?"; fi
  rm -f "$base" "$proposal"
  if ! trellis_home_lock_release >/dev/null 2>&1 && [ "$rc" -eq 0 ]; then rc="$TRELLIS_EX_UNAVAILABLE"; fi
  [ "$rc" -eq 0 ] || return "$rc"
  jq -n -S --arg fleet "$fleet" --arg project_id "$project_id" --arg root "$root" '{fleet: $fleet, project_id: $project_id, status: "unavailable", root: $root}'
}

# REPORT projection of `local_registry_classify_identity_row`: the same ordered
# checks and the same vocabulary as the strict validator, with the verdict
# emitted as JSON instead of becoming an exit class, and stderr left silent.
# It carries `class` and `scope` through untouched so a diagnostic consumer can
# recover the exact strict disposition of a row without re-deriving anything.
local_registry_diagnostic_identity() {
  local row="${1:-}" verdict
  verdict="$(local_registry_classify_identity_row "$row")" || return "$?"
  printf '%s\n' "$verdict" | jq -c '{state, detail, class, scope}'
}

# ---------------------------------------------------------------------------
# Checkout-row coverage for the listings.
#
# `local_registry_validate_available_identities` enumerates a CHECKOUT row for
# EVERY checkout plus one row per worktree; both listings emit a `checkout`
# entry only for a checkout that registers no worktree. That was a real coverage
# hole, not a cosmetic one. Worked example: a checkout whose registered worktree
# roots are all currently unreachable, on a reachable checkout root that has
# drifted. Each worktree row verifies its stored hashes, then
# `local_registry_classify_identity_row` short-circuits at its reachability
# check and the row classifies `unavailable`, class 0. The checkout row is
# the only row that resolves the live identity of the checkout root, so the
# whole-file validator returns class 4 on state that the listing reported clean.
#
# The fix runs the checkout row for every checkout and FOLDS its class onto that
# checkout's emitted rows, rather than emitting an extra entry. Reasons:
#
#   * `local_registry_validate_bound_row_identity` already validates the
#     checkout row alongside the worktree row for every bound-row write, so a
#     worktree under a drifted checkout is ALREADY unwritable. Reporting those
#     rows `identity_error` states in the listing what every writer would do.
#   * Emitting a `checkout` entry for populated checkouts changes the row SHAPE
#     for consumers that select rows explicitly. `release.sh` adopt is the
#     concrete regression: `select_rows` hands every selected entry to a loop
#     that flags any `kind != worktree` row as "unavailable adoption target
#     remains explicit" and raises class 5 — so an explicit `--project` adopt
#     against a perfectly healthy populated checkout would start failing.
#
# Folding also deduplicates by construction: one broken checkout reports its
# root cause once, from this pre-pass, instead of once per worktree row.
local_registry_checkout_rows() {
  local state_file="${1:-}"
  jq -c '
    .projects | to_entries[] as $project
    | $project.value.checkouts | to_entries[] as $checkout
    | {project_key: $project.key, kind: "checkout", checkout_id: $checkout.key,
       checkout_root: $checkout.value.root,
       git_common_dir: $checkout.value.git_common_dir,
       worktree_id: null, root: $checkout.value.root}
  ' "$state_file" || return "$TRELLIS_EX_STATE"
}

# Check generated streams against the independently counted, validated state.
# An exit-0 generator may still have produced a truncated file. Do not confuse
# that with a genuinely empty registry or trust a parallel proof of that file.
_local_registry_require_row_count() {
  local state="$1" rows="$2" mode="$3" fleet="${4:-}"
  if ! jq -en --arg mode "$mode" --arg fleet "$fleet" --slurpfile s "$state" --slurpfile r "$rows" --rawfile raw "$rows" '
    def complete_jsonl($text; $values):
      if $text == "" then ($values | length) == 0
      else ($text | split("\n")) as $lines
        | ($text | endswith("\n")) and (($lines | length) == (($values | length) + 1))
          and all(range(0; $values | length); . as $i | try (($lines[$i] | fromjson) == $values[$i]) catch false)
      end;
    if ($s | length) != 1 or (complete_jsonl($raw; $r) | not) then false
    elif $mode == "checkout" then
      ([ $s[0].projects[] | .checkouts | length ] | add // 0) == ($r | length)
    elif $mode == "listing" then
      ([ $s[0].projects[] | select($fleet == "" or .fleet == $fleet) | . as $p
         | ([ $p.checkouts[] | [(.worktrees | length), 1] | max ] | add // 0)
           + (($p.unavailable_roots // []) | length)
           + (if ($p.checkouts | length) == 0 and (($p.unavailable_roots // []) | length) == 0 then 1 else 0 end)
       ] | add // 0) == ($r | length)
    else false end
  ' >/dev/null 2>&1; then
    local_registry_err 'registry row generator produced an incomplete or invalid stream'
    return "$TRELLIS_EX_STATE"
  fi
}

# Emits `project_key<TAB>checkout_id<TAB>exit_class` for every checkout whose own
# checkout row does not validate. Both listings use THIS function, so the table
# they fold onto their rows is byte-identical; only MODE differs. `report` (the
# default) writes each failing checkout's cause to stderr exactly once, which is
# what `local_registry_list_json` wants and what the row loop then suppresses
# repeats of. `quiet` writes nothing, which is the diagnostic listing's
# silent-stderr contract. There is no second classifier behind either mode.
#
# FLEET narrows REPORTING only, never the table. The classes must be computed
# whole-file — a fold decision is a fact about the checkout, not about which
# fleet is being listed — but a fleet-scoped listing that printed another
# fleet's checkout causes to stderr contradicted the fleet-scoping contract
# documented on `local_registry_list_json`: that consumer cannot act on the
# other fleet's row, does not raise its class for it, and must not be handed its
# terminal text either. An empty FLEET reports every checkout, which is what the
# whole-machine consumers get.
local_registry_checkout_identity_classes() {
  local state_file="${1:-}" mode="${2:-report}" fleet="${3:-}" rows row key project_key rc owned=0
  if [ "$#" -ge 4 ]; then
    rows="$4"
  else
    rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.checkouts.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    owned=1
    if ! local_registry_checkout_rows "$state_file" > "$rows" ||
       ! _local_registry_require_row_count "$state_file" "$rows" checkout; then
      rm -f "$rows"
      return "$TRELLIS_EX_STATE"
    fi
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" || { [ "$owned" = 0 ] || rm -f "$rows"; return "$TRELLIS_EX_STATE"; }
    key="$(printf '%s\n' "$row" | jq -r '.project_key + "\t" + .checkout_id')" || { [ "$owned" = 0 ] || rm -f "$rows"; return "$TRELLIS_EX_STATE"; }
    # A project key is `fleet/project_id` and neither half can contain `/`.
    if [ "$mode" != quiet ] && { [ -z "$fleet" ] || [ "${project_key%%/*}" = "$fleet" ]; }; then
      local_registry_validate_identity_row "$row"
    else
      local_registry_validate_identity_row "$row" 2>/dev/null
    fi
    rc="$?"
    [ "$rc" -eq 0 ] || printf '%s\t%s\n' "$key" "$rc"
  done < "$rows"
  [ "$owned" = 0 ] || rm -f "$rows"
  return 0
}

# Rejects any checkout class outside the reportable row vocabulary {4, 5}.
# BOTH listings apply it to the same table, from one definition: a class the
# fold logic cannot interpret is a broken LISTING, not a row disposition, so it
# names the offending checkout and fails class 4 rather than being folded — or,
# worse, silently not folded — onto that checkout's rows. This is a
# listing-level fault, so it reports on stderr in both listings; the diagnostic
# listing's silent-stderr contract covers per-ROW identity causes, which this is
# not.
#
# FLEET scopes the DIAGNOSTIC, never the verdict — the same split
# `local_registry_checkout_identity_classes` applies to its own report-mode
# stderr. The table is computed whole-file, so on a fleet-scoped listing an
# unclassifiable checkout may belong to a fleet the caller cannot see; naming
# its project key would put another fleet's identifiers on this consumer's
# terminal, which is exactly what the fleet-scoping contract on
# `local_registry_list_json` forbids. The listing still fails class 4 either
# way; only the identifying half of the line is withheld. An empty FLEET names
# every checkout, which is what the whole-machine consumers get.
local_registry_require_checkout_class_vocabulary() {
  local table="${1:-}" fleet="${2:-}" key checkout cls
  while IFS=$'\t' read -r key checkout cls; do
    [ -n "$key" ] || continue
    case "$cls" in
      "$TRELLIS_EX_STATE"|"$TRELLIS_EX_UNAVAILABLE") ;;
      *)
        # A project key is `fleet/project_id` and neither half can contain `/`.
        if [ -z "$fleet" ] || [ "${key%%/*}" = "$fleet" ]; then
          local_registry_err "could not classify registry checkout row (exit $cls): $key $checkout"
        else
          local_registry_err "could not classify a registry checkout row outside fleet $fleet (exit $cls)"
        fi
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done <<EOF
$table
EOF
}

# Looks up a checkout key in a TAB-separated class table. Prints `0` when the
# checkout is absent from the table, which is the "checkout row validated"
# case.
local_registry_checkout_class_for() {
  local table="${1:-}" project_key="${2:-}" checkout_id="${3:-}" k c cls
  [ -n "$checkout_id" ] || { printf '0\n'; return 0; }
  while IFS=$'\t' read -r k c cls; do
    if [ "$k" = "$project_key" ] && [ "$c" = "$checkout_id" ]; then
      printf '%s\n' "${cls:-$TRELLIS_EX_STATE}"
      return 0
    fi
  done <<EOF
$table
EOF
  printf '0\n'
}

# Diagnostic inventory verifies persisted state integrity but intentionally
# retains independently reportable identity drift. Strict readers remain the
# only acceptable source for mutation decisions outside doctor.
#
# Row COVERAGE must match `local_registry_list_json` exactly, including the
# `checkout` rows for a checkout that currently registers no worktree —
# otherwise doctor and `registry list` disagree about which rows exist. Identity
# COVERAGE must additionally match the whole-file validator, which is what the
# checkout-row pre-pass above supplies.
local_registry_list_diagnostic_json() {
  local home="${1:-}" fleet="${2:-}" state rows output row root kind availability identity rc
  local checkout_classes row_project_key row_checkout_id checkout_class batchdir='' input_rows flat_rc
  local late_classes classes_file=/dev/null
  [ "$#" -le 2 ] || return "$TRELLIS_EX_USAGE"
  [ -z "$fleet" ] || trellis_home_require_fleet_name "$fleet" || return "$?"
  local_registry_require_hash_command || return "$?"
  state="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.state.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rows.XXXXXX")" || { rm -f "$state"; return "$TRELLIS_EX_UNAVAILABLE"; }
  output="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.output.XXXXXX")" || { rm -f "$state" "$rows"; return "$TRELLIS_EX_UNAVAILABLE"; }
  local_registry_read_diagnostic_state "$home" > "$state"
  rc="$?"
  if [ "$rc" -ne 0 ]; then rm -f "$state" "$rows" "$output"; return "$rc"; fi
  if jq -c --arg fleet "$fleet" '
    .projects | to_entries[] | select($fleet == "" or .value.fleet == $fleet)
    | .key as $key | .value as $project
    | ($project.checkouts | to_entries[]? as $checkout
       | $checkout.value.worktrees | to_entries[]?
       | {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
          registry_status: $project.status, kind: "worktree", checkout_id: $checkout.key,
          checkout_root: $checkout.value.root, worktree_id: .key,
          attachment_id: (.value.attachment_id // null), root: .value.root,
          git_common_dir: $checkout.value.git_common_dir,
          release: ($checkout.value.release // null), harnesses: $checkout.value.harnesses,
          metadata: $project.metadata}),
      ($project.checkouts | to_entries[]?
       | select((.value.worktrees | length) == 0)
       | {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
          registry_status: $project.status, kind: "checkout", checkout_id: .key,
          checkout_root: .value.root, worktree_id: null,
          attachment_id: null, root: .value.root,
          git_common_dir: .value.git_common_dir,
          release: (.value.release // null), harnesses: .value.harnesses,
          metadata: $project.metadata}),
      (($project.unavailable_roots // [])[]?
       | {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
          registry_status: $project.status, kind: "unavailable", checkout_id: null,
          checkout_root: null, worktree_id: null, attachment_id: null, root: .,
          git_common_dir: null, release: null, harnesses: [], metadata: $project.metadata}),
      (if ($project.checkouts | length) == 0 and (($project.unavailable_roots // []) | length) == 0 then
        {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
         registry_status: $project.status, kind: "project", checkout_id: null,
         checkout_root: null, worktree_id: null, attachment_id: null, root: null,
         git_common_dir: null, release: null, harnesses: [], metadata: $project.metadata}
       else empty end)
  ' "$state" > "$rows" 2> "$rows.err"; then flat_rc=0; else flat_rc=$?; fi
  if [ "$flat_rc" -ne 0 ]; then
    checkout_classes="$(local_registry_checkout_identity_classes "$state" quiet)"; rc="$?"
    if [ "$rc" -eq 0 ]; then local_registry_require_checkout_class_vocabulary "$checkout_classes" "$fleet"; rc="$?"; fi
    if [ "$rc" -eq 0 ]; then /bin/cat "$rows.err" >&2 || true; rc="$TRELLIS_EX_STATE"; fi
    rm -f "$state" "$rows" "$rows.err" "$output"; return "$rc"
  fi
  if ! _local_registry_require_row_count "$state" "$rows" listing "$fleet"; then
    rm -f "$state" "$rows" "$rows.err" "$output"; return "$TRELLIS_EX_STATE"
  fi
  batchdir="$(mktemp -d "${TMPDIR:-/tmp}/trellis.registry.batch.XXXXXX")" || batchdir=''
  if [ -n "$batchdir" ] && _local_registry_batch_run "$state" "$rows" "$batchdir"; then
    checkout_classes="$(local_registry_checkout_identity_classes "$state" quiet "$fleet" "$batchdir/checkout-misses")"
    rc="$?"; input_rows="$batchdir/row-misses"
  else
    _local_registry_batch_cleanup "$batchdir"; batchdir=''
    checkout_classes="$(local_registry_checkout_identity_classes "$state" quiet)"
    rc="$?"; input_rows="$rows"
  fi
  if [ "$rc" -ne 0 ]; then _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$rows.err" "$output"; return "$rc"; fi
  local_registry_require_checkout_class_vocabulary "$checkout_classes" "$fleet" || {
    rc="$?"; _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$rows.err" "$output"; return "$rc"
  }
  [ ! -s "$rows.err" ] || /bin/cat "$rows.err" >&2 || true
  rm -f "$rows.err"
  while :; do
  while IFS= read -r row; do
    root="$(printf '%s\n' "$row" | jq -r '.root // empty')"
    kind="$(printf '%s\n' "$row" | jq -r '.kind')"
    # A rootless `project` row has no root to be missing, so it is not
    # `unavailable`. It is `available` here for the same reason it is in
    # `local_registry_list_json`, and NOT the fourth word this listing used to
    # invent: the availability vocabulary is a published three-word contract on
    # the strict snapshot, the two listings must name the same row the same way,
    # and "nothing to classify" is already said — in both listings — by the
    # identity state below.
    if [ "$kind" = project ] && [ -z "$root" ]; then
      availability=available
    elif [ "$kind" = unavailable ] || [ -z "$root" ] || [ ! -d "$root" ]; then
      availability=unavailable
    else
      availability=available
    fi
    identity="$(local_registry_diagnostic_identity "$row")" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
    # Fold the owning checkout row's drift onto this row. A row cannot be
    # "verified" while the checkout it is filed under fails the same identity
    # check the whole-file validator applies to it.
    row_project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
    row_checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // ""')" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
    checkout_class="$(local_registry_checkout_class_for "$checkout_classes" "$row_project_key" "$row_checkout_id")"
    # Only class 4 folds down, exactly as in `local_registry_list_json`: a
    # class-5 checkout row (unreachable, unhashable) says nothing about a
    # reachable worktree, which keeps its own verdict.
    if [ "$checkout_class" = "$TRELLIS_EX_STATE" ]; then
      identity="$(local_registry_identity_verdict "$TRELLIS_EX_STATE" identity_error checkout \
        'the checkout this row is filed under failed identity validation' | jq -c '{state, detail, class, scope}')" ||
        { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
    fi
    printf '%s\n' "$row" | jq -c --arg availability "$availability" --argjson identity "$identity" '
      .availability = $availability
      | .excluded = (.metadata.legacy.blacklisted // false)
      | .status = (if $availability == "unavailable" then "unavailable" else .registry_status end)
      | .identity = $identity
      | del(.registry_status)
    ' >> "$output" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
  done < "$input_rows"
  [ -n "$batchdir" ] || break
  if ! cp "$batchdir/proof" "$batchdir/proof.previous" ||
     ! cmp -s "$batchdir/proof" "$batchdir/proof.previous" ||
     ! _local_registry_batch_recheck "$rows" "$batchdir" ||
     ! _local_registry_batch_delta "$rows" "$batchdir"; then
    _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"
  fi
  [ -s "$batchdir/checkout-delta" ] || [ -s "$batchdir/row-delta" ] || break
  late_classes="$(local_registry_checkout_identity_classes "$state" quiet "$fleet" "$batchdir/checkout-delta")"; rc="$?"
  if [ "$rc" -ne 0 ]; then _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$rc"; fi
  [ -z "$late_classes" ] || checkout_classes="${checkout_classes}${checkout_classes:+$'\n'}${late_classes}"
  local_registry_require_checkout_class_vocabulary "$checkout_classes" "$fleet" || {
    rc="$?"; _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$rc"
  }
  input_rows="$batchdir/row-delta"
  done
  if [ -n "$batchdir" ]; then
    printf '%s\n' "$checkout_classes" > "$batchdir/classes" || {
      _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"
    }
    classes_file="$batchdir/classes"
    jq -cn --slurpfile p "$batchdir/proof" --slurpfile r "$rows" --rawfile classes "$batchdir/classes" '
      ($classes | split("\n") | map(split("\t") | select(length == 3 and .[2] == "4") | .[0] + "\t" + .[1])) as $bad
      | range(0; $r | length) as $i | select($p[0].rows[$i]) | $r[$i]
      | (.project_key + "\t" + (.checkout_id // "")) as $key
      | (if .kind == "unavailable" then "unavailable" else "available" end) as $availability
      | (if ($bad | index($key)) != null then
           {state:"identity_error", detail:"the checkout this row is filed under failed identity validation", class:4, scope:"checkout"}
         elif .kind == "unavailable" then
           {state:"unavailable", detail:"registered root is unavailable", class:0, scope:"row"}
         elif .kind == "project" then
           {state:"not-applicable", detail:"project has no registered worktree root", class:0, scope:"row"}
         else
           {state:"verified", detail:"current Git identity exactly matches the registered row", class:0, scope:.kind}
         end) as $identity
      | .availability = $availability
      | .excluded = (.metadata.legacy.blacklisted // false)
      | .status = (if $availability == "unavailable" then "unavailable" else .registry_status end)
      | .identity = $identity
      | del(.registry_status)
    ' >> "$output" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
  fi
  if ! _local_registry_require_row_count "$state" "$output" listing "$fleet"; then
    _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"
  fi
  jq -s -S --slurpfile state "$state" --rawfile classes "$classes_file" --arg fleet "$fleet" '
    ($classes | split("\n") | map(split("\t") | select(length == 3 and .[2] == "4") | .[0] + "\t" + .[1])) as $bad
    | {schema_version: 1,
       entries: (map((.project_key + "\t" + (.checkout_id // "")) as $key
         | if ($bad | index($key)) != null then
             .identity = {state:"identity_error", detail:"the checkout this row is filed under failed identity validation", class:4, scope:"checkout"}
           else . end)
         | sort_by(.fleet, .project_id, (.checkout_id // ""), (.worktree_id // ""), (.root // ""))),
       discovery_ignores: (($state[0].discovery_ignores // {})
         | with_entries(select($fleet == "" or .key == $fleet)))}
  ' "$output"
  rc="$?"
  _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"
  return "$rc"
}

# Enumeration must not abort a whole run because one registered row cannot be
# identity-validated. A row is checked by exactly the validator the whole-file
# reader uses, `local_registry_validate_identity_row`, so strictness is
# identical; only the DISPOSITION differs — the failing row is degraded to a
# reported state instead of failing the whole read. Mutation paths keep using
# the strict readers, or bound-row validation, and revalidate under the lock.
#
# The validator's exit CLASS is carried through verbatim, because the state
# vocabulary is the one `local_registry_classify_identity_row` defines and it is
# named for those classes: a state error (4) is `identity_error`,
# an environment/hashing failure (5) is `unavailable` — the same word an
# unreachable root gets, which is the class-5 state. Collapsing a 5 into
# `identity_error` would report an environment failure as registry corruption.
# `checkout` rows (a checkout that currently registers no worktree) go through
# the same logic so their identity cannot go unreported.
#
# Only classes 0, 4 and 5 are reportable row states. Anything else (a usage
# error, a malformed row) is returned to the caller, which turns it into a
# listing-level class-4 failure naming the row — see `local_registry_list_json`.
# The MISSING-HASH-COMMAND case never reaches here: it is an environment fault
# that the listing probes for once, up front, and fails class 5 as a whole.

# DIAGNOSTICS ONLY for a worktree row whose owning CHECKOUT row has already
# reported its own failure. The checkout-level cause must be printed once, not
# once per worktree — but blanket-suppressing the row's stderr also threw away a
# worktree's DISTINCT root cause, leaving a non-clean row visible in the JSON
# with no terminal text naming it.
#
# BOTH failing classes are re-reported, not just class 4. A class-5 worktree
# cause — its root could not be hashed, or a reachable root would not resolve as
# a canonical Git worktree — surfaces in the listing as the word `unavailable`,
# which is exactly the word an absent root gets, so without its detail line an
# operator reads an environment fault as "that volume is not mounted". The
# checkout pre-pass never printed it (it is worktree-scoped) and nothing else
# would.
#
# The narrowing is the classifier's own SCOPE field, not a re-derivation and not
# a message-text filter. That matters: the hand-rolled subset this replaced
# compared only `actual_root` and `actual_worktree_id`, so a REPARENTED worktree
# — one whose live checkout fields moved while its own root and ID stayed put —
# had no cause printed at all.
#
# It never changes a class: the row's disposition is computed by the full
# validator either way.
local_registry_report_worktree_scoped_identity() {
  local row="${1:-}" kind verdict class scope detail root
  kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return 0
  [ "$kind" = worktree ] || return 0
  # Re-derive NOTHING. The verdict comes from the one classifier, so a cause it
  # can name — a re-keyed worktree ID, a REPARENTED worktree whose live checkout
  # fields moved out from under it — is reported here with the classifier's own
  # detail rather than a narrower hand-rolled subset that could not see it.
  verdict="$(local_registry_classify_identity_row "$row" 2>/dev/null)" || return 0
  class="$(printf '%s\n' "$verdict" | jq -r '.class')" || return 0
  case "$class" in
    "$TRELLIS_EX_STATE"|"$TRELLIS_EX_UNAVAILABLE") ;;
    # Class 0 covers `verified` and the benign absent-root `unavailable`: there
    # is no cause to print for either.
    *) return 0 ;;
  esac
  # SCOPE is the structural narrowing: `checkout` marks the one check a worktree
  # row shares verbatim with its owning checkout row, which the pre-pass has
  # already printed. Everything else is this worktree's own fact.
  scope="$(printf '%s\n' "$verdict" | jq -r '.scope')" || return 0
  [ "$scope" = worktree ] || return 0
  detail="$(printf '%s\n' "$verdict" | jq -r '.detail')" || return 0
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return 0
  local_registry_err "$detail: $(local_registry_safe_display "${root:-<no recorded root>}")"
}

local_registry_list_row_availability() {
  local row="${1:-}" kind root rc
  kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  case "$kind" in
    worktree|checkout) ;;
    *)
      if [ "$kind" = unavailable ] || { [ -n "$root" ] && [ ! -d "$root" ]; }; then
        printf 'unavailable\n'
      else
        printf 'available\n'
      fi
      return 0
      ;;
  esac
  local_registry_validate_identity_row "$row"
  rc="$?"
  case "$rc" in
    0)
      # Stored hashes verified. An absent root is still merely unavailable.
      if [ -z "$root" ] || [ ! -d "$root" ]; then printf 'unavailable\n'; else printf 'available\n'; fi
      ;;
    "$TRELLIS_EX_STATE") printf 'identity_error\n' ;;
    "$TRELLIS_EX_UNAVAILABLE") printf 'unavailable\n' ;;
    *) return "$rc" ;;
  esac
}

# FLEET SCOPING IS PART OF THE CONTRACT, not an accident of the row filter.
# `local_registry_list_json HOME FLEET` enumerates the rows of ONE fleet; an
# empty FLEET enumerates every fleet on the machine. A consumer that passes a
# fleet therefore sees state errors for that fleet only, and that is deliberate:
#
#   * The identity pre-passes above (`local_registry_checkout_identity_classes`
#     and the whole-file validator) COMPUTE over the WHOLE file regardless of
#     the fleet filter, so no cross-fleet fault can change how a listed row is
#     classified. Only VISIBILITY is fleet-scoped — including the checkout
#     pre-pass's own stderr, which is why it is handed the fleet: computing a
#     class for every checkout is required, printing another fleet's cause to a
#     fleet-scoped consumer is the exact leak this scoping rules out.
#   * Every WRITE re-validates under the registry lock — whole-file for the
#     batch writers, bound-row for the single-row writers — so a fault in
#     another fleet still blocks any write it could actually corrupt. Nothing
#     depends on a read-side listing to surface it.
#   * The fleet-scoped consumers (sync-hooks, sync-merge-gate, disk-janitor,
#     doctor, materialize-scheduled-task, `registry.sh list --fleet`) act only
#     within their fleet, so raising their exit class on another fleet's row
#     would report a fault they cannot act on and did not touch.
#
# Consumers that must see the whole machine — `release.sh` adopt, `show-config`,
# every rollout — already call this with no FLEET and get exactly that. The
# matrix pass over every consumer found no row needing cross-fleet state
# visibility, so the contract stands as documented rather than being widened.
# A positive-only batch is an optimization, never a new authority. Refuse it
# for overridden shell helpers or non-system hash tools: the scalar classifier
# deliberately honours those, while hashlib cannot reproduce arbitrary shims.
_local_registry_batch_helpers() {
  declare -f local_registry_sha256 local_registry_real_directory local_registry_git_common_dir \
    local_registry_checkout_root_for_common_dir local_registry_identity_for_root \
    local_registry_identity_verdict local_registry_identity_class_verdict \
    local_registry_classify_identity_row local_registry_validate_identity_row \
    local_registry_list_row_availability local_registry_diagnostic_identity \
    local_registry_checkout_identity_classes local_registry_checkout_class_for \
    local_registry_report_worktree_scoped_identity local_registry_require_absolute_safe_path \
    trellis_home_require_safe_text trellis_home_require_absolute_safe_path \
    trellis_home_has_unsafe_chars trellis_is_sha256_hex
}

_local_registry_batch_cleanup() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 0
  rm -f "$dir/checkouts" "$dir/proof" "$dir/checkout-misses" "$dir/row-misses" "$dir/classes" \
    "$dir/proof.next" "$dir/proof.fresh" "$dir/proof.previous" "$dir/python" "$dir/git" "$dir/bundled" \
    "$dir/delta" "$dir/checkout-delta" "$dir/row-delta" "$dir/demoted" "$dir/helper.err" "$dir/degraded"
  rmdir "$dir" 2>/dev/null || true
}

_local_registry_batch_run() {
  local state="$1" rows="$2" dir="$3" pin_home="${4:-}" pin_dir="${5:-}"
  local python_bin git_bin hash_bin awk_bin jq_bin tool description bundled=0
  if [ "${TRELLIS_LIBS_PRELOADED:-}" = 1 ]; then
    # The verified command bundle has no executable payload pathname. Both
    # programs must be manifest-attested data in that same bundle.
    [ -n "${_TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM:-}" ] &&
      [ -n "${_TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM:-}" ] &&
      declare -F trellis_command_bundle_is_verified >/dev/null &&
      trellis_command_bundle_is_verified "${TRELLIS_VERIFIED_COMMAND_BUNDLE:-}" "${TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN:-}" || return 1
    bundled=1
  fi
  [ "${TRELLIS_EX_STATE:-}" = 4 ] && [ "${TRELLIS_EX_UNAVAILABLE:-}" = 5 ] || return 1
  [ "$(_local_registry_batch_helpers)" = "${_LOCAL_REGISTRY_BATCH_HELPERS_ORIGINAL:-}" ] || return 1
  [ "$(type -t git)" = file ] && [ "$(type -t awk)" = file ] &&
    [ "$(type -t jq)" = file ] && [ "$(type -t python3)" = file ] || return 1
  git_bin="$(command -v git)"; awk_bin="$(command -v awk)"; jq_bin="$(command -v jq)"
  python_bin="$(command -v python3)" || return 1
  case "$git_bin" in /usr/bin/git|/usr/local/bin/git|/opt/homebrew/bin/git) ;; *) return 1 ;; esac
  case "$awk_bin" in /usr/bin/awk|/bin/awk) ;; *) return 1 ;; esac
  case "$jq_bin" in /usr/bin/jq|/usr/local/bin/jq|/opt/homebrew/bin/jq|/bin/jq) ;; *) return 1 ;; esac
  case "$python_bin" in /usr/bin/python3|/usr/local/bin/python3|/opt/homebrew/bin/python3) ;; *) return 1 ;; esac
  if command -v sha256sum >/dev/null 2>&1; then
    [ "$(type -t sha256sum)" = file ] || return 1
    hash_bin="$(command -v sha256sum)"
    case "$hash_bin" in /usr/bin/sha256sum|/bin/sha256sum|/sbin/sha256sum) ;; *) return 1 ;; esac
  elif command -v openssl >/dev/null 2>&1; then
    [ "$(type -t openssl)" = file ] || return 1
    hash_bin="$(command -v openssl)"
    [ "$hash_bin" = /usr/bin/openssl ] && [ -z "${OPENSSL_CONF:-}${OPENSSL_MODULES:-}" ] || return 1
  else
    return 1
  fi
  [ -z "${LD_PRELOAD:-}${LD_LIBRARY_PATH:-}${DYLD_INSERT_LIBRARIES:-}${DYLD_LIBRARY_PATH:-}" ] || return 1
  # PATH wrappers can lie while passing the empty-string hash probe. Admit
  # only native executables at the known paths, never shell or Python shims.
  for tool in "$git_bin" "$awk_bin" "$jq_bin" "$python_bin" "$hash_bin"; do
    description="$(/usr/bin/file -Lb "$tool" 2>/dev/null)" || return 1
    case "$description" in 'ELF '*executable*|Mach-O*executable*|Mach-O*'universal binary'*) ;; *) return 1 ;; esac
  done
  if [ "$bundled" = 0 ]; then
    [ -f "$_LOCAL_REGISTRY_LIB_DIR/registry_identity_batch.py" ] &&
      [ ! -L "$_LOCAL_REGISTRY_LIB_DIR/registry_identity_batch.py" ] &&
      [ -f "$_LOCAL_REGISTRY_LIB_DIR/attachment_fs.py" ] &&
      [ ! -L "$_LOCAL_REGISTRY_LIB_DIR/attachment_fs.py" ] || return 1
  fi
  _local_registry_batch_execute "$state" "$rows" "$dir" "$python_bin" "$git_bin" "$bundled" "$pin_home" "$pin_dir" || return 1
  _local_registry_batch_recheck "$rows" "$dir"
}

# Separate from tool admission so the fenced test runner can exercise this
# exact protocol with its mandatory Git wrapper, without bypassing that fence.
_local_registry_batch_execute() {
  local state="$1" rows="$2" dir="$3" python_bin="$4" git_bin="$5" bundled="${6:-0}"
  local pin_home="${7:-}" pin_dir="${8:-}"
  local_registry_checkout_rows "$state" > "$dir/checkouts" || return 1
  _local_registry_require_row_count "$state" "$dir/checkouts" checkout 2>/dev/null || return 1
  printf '%s' "$python_bin" > "$dir/python" && printf '%s' "$git_bin" > "$dir/git" &&
    printf '%s' "$bundled" > "$dir/bundled" || return 1
  _local_registry_batch_observe "$rows" "$dir" "$dir/proof" "$pin_home" "$pin_dir" || return 1
  _local_registry_batch_partition "$rows" "$dir"
}

_local_registry_batch_observe() {
  local rows="$1" dir="$2" output="$3" pin_home="${4:-}" pin_dir="${5:-}"
  local python_bin git_bin bundled rc=0
  python_bin="$(< "$dir/python")"; git_bin="$(< "$dir/git")"; bundled="$(< "$dir/bundled")"
  if [ "$bundled" = 1 ]; then
    TRELLIS_REGISTRY_PIN_HOME="$pin_home" TRELLIS_REGISTRY_PIN_DIR="$pin_dir" \
      TRELLIS_REGISTRY_BATCH_FS_PROGRAM="$_TRELLIS_BUNDLED_ATTACHMENT_FS_PROGRAM" \
      "$python_bin" -I -B -c "$_TRELLIS_BUNDLED_REGISTRY_BATCH_PROGRAM" ":bundle:" \
      "$dir/checkouts" "$rows" "$git_bin" > "$output" 2> "$dir/helper.err" || rc=$?
  else
    TRELLIS_REGISTRY_PIN_HOME="$pin_home" TRELLIS_REGISTRY_PIN_DIR="$pin_dir" \
      "$python_bin" -I -B "$_LOCAL_REGISTRY_LIB_DIR/registry_identity_batch.py" \
      "$_LOCAL_REGISTRY_LIB_DIR/attachment_fs.py" "$dir/checkouts" "$rows" "$git_bin" > "$output" 2> "$dir/helper.err" || rc=$?
  fi
  [ "$rc" -eq 0 ] || _local_registry_batch_degraded "$dir"
  return "$rc"
}

# The helper failed: every row still goes to the scalar classifier, which
# stays authoritative, but the lost speed is reported once instead of hiding
# (a slow, silent fallback is how a Python 3.9 incompatibility went unseen).
# Once per listing: a re-observation may fail again in the same batch
# directory, possibly in a subshell, so the marker is a file there.
_local_registry_batch_degraded() {
  local reason
  [ ! -e "$1/degraded" ] || return 0
  : > "$1/degraded" 2>/dev/null || :
  reason="$(tail -n 1 "$1/helper.err" 2>/dev/null | /usr/bin/env LC_ALL=C tr -cd '[:print:]' | cut -c1-200)"
  printf 'trellis registry: identity batch unavailable (%s); classifying rows one by one\n' "${reason:-exit status only}" >&2
}

_local_registry_batch_proof_valid() {
  local rows="$1" dir="$2" proof="$3"
  # Missing, extra or non-boolean answers discard the whole observation.
  jq -cn --slurpfile p "$proof" --slurpfile c "$dir/checkouts" --slurpfile r "$rows" '
    if ($p | length) != 1 or ($p[0] | type) != "object" or
       ($p[0] | keys) != ["checkouts", "rows"] or
       ($p[0].checkouts | type) != "array" or ($p[0].rows | type) != "array" or
       ($p[0].checkouts | length) != ($c | length) or ($p[0].rows | length) != ($r | length) or
       ([$p[0].checkouts[], $p[0].rows[]] | all(type == "boolean") | not)
    then error("invalid registry batch proof") else empty end
  ' >/dev/null 2>&1
}

_local_registry_batch_partition() {
  local rows="$1" dir="$2"
  _local_registry_batch_proof_valid "$rows" "$dir" "$dir/proof" || return 1
  jq -cn --slurpfile p "$dir/proof" --slurpfile c "$dir/checkouts" '
    range(0; $c | length) as $i | select($p[0].checkouts[$i] | not) | $c[$i]
  ' > "$dir/checkout-misses" || return 1
  jq -cn --slurpfile p "$dir/proof" --slurpfile r "$rows" '
    range(0; $r | length) as $i | select($p[0].rows[$i] | not) | $r[$i]
  ' > "$dir/row-misses" || return 1
  _local_registry_batch_verify_split "$rows" "$dir" misses
}

# Verify derived streams independently against the complete proof and input,
# including JSONL framing. An exit-0 producer or an EOF on a record boundary is
# not evidence that every miss or demotion was emitted.
_local_registry_batch_verify_split() {
  local rows="$1" dir="$2" mode="$3" old="$2/proof" checkout_out row_out
  case "$mode" in
    misses) checkout_out="$dir/checkout-misses"; row_out="$dir/row-misses" ;;
    delta) old="$dir/proof.previous"; checkout_out="$dir/checkout-delta"; row_out="$dir/row-delta" ;;
    *) return 1 ;;
  esac
  jq -en --arg mode "$mode" --slurpfile old "$old" --slurpfile new "$dir/proof" \
    --slurpfile c "$dir/checkouts" --slurpfile r "$rows" \
    --slurpfile co "$checkout_out" --slurpfile ro "$row_out" \
    --rawfile ct "$checkout_out" --rawfile rt "$row_out" '
    def complete_jsonl($text; $values):
      if $text == "" then ($values | length) == 0
      else ($text | split("\n")) as $lines
        | ($text | endswith("\n")) and (($lines | length) == (($values | length) + 1))
          and all(range(0; $values | length); . as $i | try (($lines[$i] | fromjson) == $values[$i]) catch false)
      end;
    [range(0; $c | length) as $i
     | if (($new[0].checkouts[$i] | not) and ($mode == "misses" or $old[0].checkouts[$i]))
       then $c[$i] else empty end] as $expected_checkouts
    | [range(0; $r | length) as $i
       | if (($new[0].rows[$i] | not) and ($mode == "misses" or $old[0].rows[$i]))
         then $r[$i] else empty end] as $expected_rows
    | complete_jsonl($ct; $co) and complete_jsonl($rt; $ro)
      and $co == $expected_checkouts and $ro == $expected_rows
  ' >/dev/null 2>&1
}

# Reobserve the full canonical Git identity, not just directory existence.
# Proofs are monotonic: a miss never becomes positive during this listing. A
# failed or malformed observation demotes everything to the shell classifier.
_local_registry_batch_recheck() {
  local rows="$1" dir="$2"
  _local_registry_batch_proof_valid "$rows" "$dir" "$dir/proof" || return 1
  if ! _local_registry_batch_observe "$rows" "$dir" "$dir/proof.fresh" ||
     ! _local_registry_batch_proof_valid "$rows" "$dir" "$dir/proof.fresh"; then
    jq -c '{checkouts: [.checkouts[] | false], rows: [.rows[] | false]}' "$dir/proof" > "$dir/proof.fresh" || return 1
  fi
  jq -cn --slurpfile old "$dir/proof" --slurpfile new "$dir/proof.fresh" '
    {checkouts: [range(0; $old[0].checkouts | length) as $i | $old[0].checkouts[$i] and $new[0].checkouts[$i]],
     rows: [range(0; $old[0].rows | length) as $i | $old[0].rows[$i] and $new[0].rows[$i]]}
  ' > "$dir/proof.next" || return 1
  if ! cmp -s "$dir/proof" "$dir/proof.next"; then : > "$dir/demoted" || return 1; fi
  mv "$dir/proof.next" "$dir/proof" || return 1
  _local_registry_batch_partition "$rows" "$dir"
}

# Identify only newly demoted rows, in input order. NUL-delimited triplets
# (array, index, JSON row) do not split on embedded newlines or backslashes.
_local_registry_batch_delta() {
  local rows="$1" dir="$2" kind index row
  # A successful copy can still be empty or truncated. Never let a missing old
  # positive turn a newly demoted row into an apparently empty delta.
  _local_registry_batch_proof_valid "$rows" "$dir" "$dir/proof.previous" || return 1
  jq -jn --slurpfile old "$dir/proof.previous" --slurpfile new "$dir/proof" \
    --slurpfile c "$dir/checkouts" --slurpfile r "$rows" '
    (range(0; $c | length) as $i | select($old[0].checkouts[$i] and ($new[0].checkouts[$i] | not))
     | "checkouts\u0000" + ($i | tostring) + "\u0000" + ($c[$i] | tojson) + "\u0000"),
    (range(0; $r | length) as $i | select($old[0].rows[$i] and ($new[0].rows[$i] | not))
     | "rows\u0000" + ($i | tostring) + "\u0000" + ($r[$i] | tojson) + "\u0000")
  ' > "$dir/delta" || return 1
  : > "$dir/checkout-delta" && : > "$dir/row-delta" || return 1
  while :; do
    kind=''
    if ! IFS= read -r -d '' kind; then [ -z "$kind" ] || return 1; break; fi
    IFS= read -r -d '' index && IFS= read -r -d '' row || return 1
    case "$index" in ''|*[!0-9]*) return 1 ;; esac
    case "$kind" in
      checkouts) printf '%s\n' "$row" >> "$dir/checkout-delta" || return 1 ;;
      rows) printf '%s\n' "$row" >> "$dir/row-delta" || return 1 ;;
      *) return 1 ;;
    esac
  done < "$dir/delta"
  _local_registry_batch_verify_split "$rows" "$dir" delta
}

local_registry_list_json() {
  [ "$#" -le 2 ] || return "$TRELLIS_EX_USAGE"
  _local_registry_list_json "${1:-}" "${2:-}" 0
}

# Sync can retain positive, stat-pinned worktree proofs from this same pass.
# A missing or invalid proof is never a negative verdict: sync resolves it with
# the ordinary live shell resolver. The caller owns the private directory.
_local_registry_list_json_for_sync() {
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  _LOCAL_REGISTRY_SYNC_PROOF_READY=0
  _local_registry_list_json "$1" "$2" 0 "" "$3"
}

# Sync's root proofs (fix/152-sync-batch-roots): one registry identity batch over
# every row, run in sync's own process at the start of its row loop, instead of
# one live resolve per row. OUT receives the registry token (several lines) as
# one JSON string on its first line, then one JSON line per proven worktree row whose root is unique among the
# worktree rows: {"root", "worktree_id", "checkout_root", "watch", "resolution"}.
# "resolution" is exactly what local_registry_resolve_root prints for that root;
# "watch" is the stat line of the root and its .git, equal before and after the
# batch. Positive-only: sync uses an entry only while the registry token and the
# watch line are unchanged and a use-time Git observation still agrees (see
# sync_root_proof); any other row resolves through the original resolver. 1 when
# the batch could not run (a failing helper says so once, on stderr).
local_registry_sync_root_proofs() {
  local home="$1" out="$2" state rows dir token after before_watch after_watch os rc=1
  local -a paths=()
  local root
  token="$(_local_registry_diagnostic_token "$home")" && [ -n "$token" ] || return 1
  state="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.state.XXXXXX")" || return 1
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rows.XXXXXX")" || { rm -f "$state"; return 1; }
  dir="$(mktemp -d "${TMPDIR:-/tmp}/trellis.registry.batch.XXXXXX")" || { rm -f "$state" "$rows"; return 1; }
  os="$(/usr/bin/uname -s 2>/dev/null)" || os=''
  if local_registry_read_diagnostic_state "$home" > "$state" 2>/dev/null &&
     jq -c --arg fleet "" "$_LOCAL_REGISTRY_FLAT_ROWS_FILTER" "$state" > "$rows" 2>/dev/null &&
     _local_registry_require_row_count "$state" "$rows" listing "" 2>/dev/null &&
     jq -r 'select(.kind == "worktree") | .root | if test("\n") then error("newline in root") else . end' "$rows" > "$dir/roots" 2>/dev/null; then
    while IFS= read -r root; do paths+=("$root" "$root/.git"); done < "$dir/roots"
    if [ "${#paths[@]}" -gt 0 ] && before_watch="$(_local_registry_sync_watch "$os" "${paths[@]}")" &&
       _local_registry_batch_run "$state" "$rows" "$dir" &&
       after_watch="$(_local_registry_sync_watch "$os" "${paths[@]}")" &&
       [ "$before_watch" = "$after_watch" ] &&
       after="$(_local_registry_diagnostic_token "$home")" && [ "$after" = "$token" ] &&
       { printf '%s' "$token" | jq -Rsc '.'
         printf '%s\n' "$before_watch" | jq -cRn --slurpfile p "$dir/proof" --rawfile rows "$rows" '
           [inputs] as $lines
           | ($rows | split("\n") | map(select(length > 0) | fromjson)) as $r
           | (reduce ($r[] | select(.kind == "worktree") | .root) as $x ({}; .[$x] += 1)) as $count
           | [range(0; $r | length) as $i | select($r[$i].kind == "worktree") | $i] as $worktrees
           | if ($lines | length) != 2 * ($worktrees | length) then error("watch lines") else . end
           | range(0; $worktrees | length) as $k | $worktrees[$k] as $i
           | select($p[0].rows[$i] and $count[$r[$i].root] == 1)
           | $r[$i] as $row
           | {root: $row.root, worktree_id: $row.worktree_id, checkout_root: $row.checkout_root,
              watch: ($lines[2 * $k] + "\n" + $lines[2 * $k + 1]),
              resolution: ($row | {fleet, project_id, project_key, checkout_id, worktree_id, root, git_common_dir})}'
       } > "$out"; then
      rc=0
    fi
  fi
  _local_registry_batch_cleanup "$dir"
  rm -f "$state" "$rows" "$dir/roots"
  rmdir "$dir" 2>/dev/null || true
  return "$rc"
}

# The stat line sync compares for a proven root: device, inode, size, mode,
# mtime and ctime of each PATH, one line each, in order. Callers run it inside
# $(...), so the locale is set through env, never a temporary assignment (the
# 1.5.1 locale-crash family; the lexical lint does not follow function calls).
_local_registry_sync_watch() {
  local os="$1"
  shift
  case "$os" in
    Darwin) /usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc' -- "$@" 2>/dev/null ;;
    Linux) /usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat --printf='%d\t%i\t%s\t%f\t%y\t%z\n' -- "$@" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# Internal diagnostic entry: SNAPSHOT is the already validated, migrated state
# captured for this operation. Public callers retain the ordinary fresh read.
_local_registry_list_json_from_snapshot() {
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  _local_registry_list_json "$1" "$2" 1 "$3"
}

# The listing's flattened rows, one JSON object per project, checkout, worktree
# or unavailable root, with checkout_root (the registry identity batch groups
# on it). One program for the listing and for sync's root proofs.
_LOCAL_REGISTRY_FLAT_ROWS_FILTER='
    .projects | to_entries[] | select($fleet == "" or .value.fleet == $fleet)
    | .key as $key | .value as $project
    | ($project.checkouts | to_entries[]? as $checkout
       | $checkout.value.worktrees | to_entries[]?
       | {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
          registry_status: $project.status, kind: "worktree", checkout_id: $checkout.key,
          checkout_root: $checkout.value.root,
          worktree_id: .key, attachment_id: (.value.attachment_id // null), root: .value.root,
          git_common_dir: $checkout.value.git_common_dir,
          release: ($checkout.value.release // null), harnesses: $checkout.value.harnesses,
          metadata: $project.metadata}),
      ($project.checkouts | to_entries[]?
       | select((.value.worktrees | length) == 0)
       | {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
          registry_status: $project.status, kind: "checkout", checkout_id: .key,
          checkout_root: .value.root,
          worktree_id: null, attachment_id: null, root: .value.root,
          git_common_dir: .value.git_common_dir,
          release: (.value.release // null), harnesses: .value.harnesses,
          metadata: $project.metadata}),
      (($project.unavailable_roots // [])[]?
       | {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
          registry_status: $project.status, kind: "unavailable", checkout_id: null, worktree_id: null,
          checkout_root: null,
          root: ., git_common_dir: null, release: null, harnesses: [], metadata: $project.metadata}),
      (if ($project.checkouts | length) == 0 and (($project.unavailable_roots // []) | length) == 0 then
        {fleet: $project.fleet, project_id: $project.project_id, project_key: $key,
         registry_status: $project.status, kind: "project", checkout_id: null, worktree_id: null,
         checkout_root: null,
         root: null, git_common_dir: null, release: null, harnesses: [], metadata: $project.metadata}
       else empty end)
'

_local_registry_list_json() {
  local home="$1" fleet="$2" use_snapshot="$3" snapshot="${4:-}" pin_dir="${5:-}" state rows output row availability label rc
  local checkout_classes row_project_key row_checkout_id checkout_class batchdir='' input_rows flat_rc
  local late_classes classes_file=/dev/null
  [ -z "$fleet" ] || trellis_home_require_fleet_name "$fleet" || return "$?"
  # ENVIRONMENT before rows: without a hash command EVERY row would classify the
  # same way, which is a fact about the machine and not about the registry.
  local_registry_require_hash_command || return "$?"
  state="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.state.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  rows="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.rows.XXXXXX")" || { rm -f "$state"; return "$TRELLIS_EX_UNAVAILABLE"; }
  output="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.output.XXXXXX")" || { rm -f "$state" "$rows"; return "$TRELLIS_EX_UNAVAILABLE"; }
  if [ "$use_snapshot" = 1 ]; then
    printf '%s\n' "$snapshot" > "$state"; rc="$?"
  else
    local_registry_read_diagnostic_state "$home" > "$state"; rc="$?"
  fi
  if [ "$rc" -ne 0 ]; then rm -f "$state" "$rows" "$output"; return "$rc"; fi
  if jq -c --arg fleet "$fleet" "$_LOCAL_REGISTRY_FLAT_ROWS_FILTER" "$state" > "$rows" 2> "$rows.err"; then flat_rc=0; else flat_rc=$?; fi
  if [ "$flat_rc" -ne 0 ]; then
    checkout_classes="$(local_registry_checkout_identity_classes "$state" report "$fleet")"; rc="$?"
    if [ "$rc" -eq 0 ]; then local_registry_require_checkout_class_vocabulary "$checkout_classes" "$fleet"; rc="$?"; fi
    if [ "$rc" -eq 0 ]; then /bin/cat "$rows.err" >&2 || true; rc="$TRELLIS_EX_STATE"; fi
    rm -f "$state" "$rows" "$rows.err" "$output"; return "$rc"
  fi
  if ! _local_registry_require_row_count "$state" "$rows" listing "$fleet"; then
    rm -f "$state" "$rows" "$rows.err" "$output"; return "$TRELLIS_EX_STATE"
  fi
  # Classify checkout pre-pass rows and emitted rows together. On any protocol
  # failure discard the entire pass; individual misses retain the old shell
  # classifier, diagnostic order and checkout-folding rules.
  batchdir="$(mktemp -d "${TMPDIR:-/tmp}/trellis.registry.batch.XXXXXX")" || batchdir=''
  if [ -n "$batchdir" ] && _local_registry_batch_run "$state" "$rows" "$batchdir" "$home" "$pin_dir"; then
    checkout_classes="$(local_registry_checkout_identity_classes "$state" report "$fleet" "$batchdir/checkout-misses")"
    rc="$?"
    input_rows="$batchdir/row-misses"
  else
    _local_registry_batch_cleanup "$batchdir"; batchdir=''
    checkout_classes="$(local_registry_checkout_identity_classes "$state" report "$fleet")"
    rc="$?"
    input_rows="$rows"
  fi
  if [ "$rc" -ne 0 ]; then _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$rows.err" "$output"; return "$rc"; fi
  local_registry_require_checkout_class_vocabulary "$checkout_classes" "$fleet" || {
    rc="$?"; _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$rows.err" "$output"; return "$rc"
  }
  [ ! -s "$rows.err" ] || /bin/cat "$rows.err" >&2 || true
  rm -f "$rows.err"
  while :; do
  while IFS= read -r row; do
    row_project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
    row_checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // ""')" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
    checkout_class="$(local_registry_checkout_class_for "$checkout_classes" "$row_project_key" "$row_checkout_id")"
    # Every reportable row state is already a string on stdout, so a non-zero
    # return here means a class OUTSIDE {0,4,5} — a malformed row or a bad
    # internal call. That is a broken LISTING, not a row disposition: name the
    # row and fail class 4. Never skip it silently, and never surface class 2,
    # which consumers read as "you passed bad arguments".
    #
    # DEDUPE, NARROWED: when the owning checkout row already failed, the pre-pass
    # has printed the checkout-level root cause once. The per-row validator would
    # repeat that same cause for each of the checkout's N worktrees, so its
    # stderr is dropped — but dropping ALL of it also silenced a worktree row's
    # OWN distinct class-4 cause, which the checkout pre-pass never reported and
    # nothing else would print. The suppression is therefore paired with a
    # worktree-scoped re-report that emits only the row's own facts. The row's
    # CLASS is computed by the same full validator in both branches.
    if [ "$checkout_class" = 0 ]; then
      availability="$(local_registry_list_row_availability "$row")"
      rc="$?"
    else
      availability="$(local_registry_list_row_availability "$row" 2>/dev/null)"
      rc="$?"
      local_registry_report_worktree_scoped_identity "$row"
    fi
    if [ "$rc" -ne 0 ]; then
      label="$(printf '%s\n' "$row" | jq -r '"\(.project_key // "?") \(.kind // "?") \(.root // "(no recorded root)")"' 2>/dev/null)" || label='(unreadable row)'
      local_registry_err "could not classify registry row (exit $rc): $label"
      _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"
      return "$TRELLIS_EX_STATE"
    fi
    # A row filed under a checkout whose own checkout row failed identity
    # validation is a state error even when the row's own fields verify: the
    # whole-file validator fails on that checkout row, and every bound-row write
    # binding this row validates the checkout row with it. Only the class-4
    # verdict folds down — a class-5 checkout row (unreachable, unresolvable)
    # says nothing about a reachable worktree, which keeps its own disposition.
    if [ "$checkout_class" = "$TRELLIS_EX_STATE" ]; then
      availability=identity_error
    fi
    printf '%s\n' "$row" | jq -c --arg availability "$availability" '
      .availability = $availability
      | .excluded = (.metadata.legacy.blacklisted // false)
      | .status = (if $availability == "unavailable" then "unavailable" else .registry_status end)
      | del(.registry_status, .checkout_root)
    ' >> "$output" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
  done < "$input_rows"
  [ -n "$batchdir" ] || break
  if ! cp "$batchdir/proof" "$batchdir/proof.previous" ||
     ! cmp -s "$batchdir/proof" "$batchdir/proof.previous" ||
     ! _local_registry_batch_recheck "$rows" "$batchdir" ||
     ! _local_registry_batch_delta "$rows" "$batchdir"; then
    _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"
  fi
  [ -s "$batchdir/checkout-delta" ] || [ -s "$batchdir/row-delta" ] || break
  late_classes="$(local_registry_checkout_identity_classes "$state" report "$fleet" "$batchdir/checkout-delta")"; rc="$?"
  if [ "$rc" -ne 0 ]; then _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$rc"; fi
  [ -z "$late_classes" ] || checkout_classes="${checkout_classes}${checkout_classes:+$'\n'}${late_classes}"
  local_registry_require_checkout_class_vocabulary "$checkout_classes" "$fleet" || {
    rc="$?"; _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$rc"
  }
  input_rows="$batchdir/row-delta"
  done
  if [ -n "$batchdir" ]; then
    printf '%s\n' "$checkout_classes" > "$batchdir/classes" || {
      _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"
    }
    classes_file="$batchdir/classes"
    jq -cn --slurpfile p "$batchdir/proof" --slurpfile r "$rows" --rawfile classes "$batchdir/classes" '
      ($classes | split("\n") | map(split("\t") | select(length == 3 and .[2] == "4") | .[0] + "\t" + .[1])) as $bad
      | range(0; $r | length) as $i | select($p[0].rows[$i]) | $r[$i]
      | (.project_key + "\t" + (.checkout_id // "")) as $key
      | (if .kind == "unavailable" then "unavailable"
         elif .kind == "project" then "available"
         elif ($bad | index($key)) != null then "identity_error"
         else "available" end) as $availability
      | .availability = $availability
      | .excluded = (.metadata.legacy.blacklisted // false)
      | .status = (if $availability == "unavailable" then "unavailable" else .registry_status end)
      | del(.registry_status, .checkout_root)
    ' >> "$output" || { _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"; }
  fi
  if ! _local_registry_require_row_count "$state" "$output" listing "$fleet"; then
    _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"; return "$TRELLIS_EX_STATE"
  fi
  jq -s -S --slurpfile state "$state" --rawfile classes "$classes_file" --arg fleet "$fleet" '
    ($classes | split("\n") | map(split("\t") | select(length == 3 and .[2] == "4") | .[0] + "\t" + .[1])) as $bad
    | {schema_version: 1,
       entries: (map(. as $row | (.project_key + "\t" + (.checkout_id // "")) as $key
         | if ($bad | index($key)) != null then
             .availability = "identity_error" | .status = $state[0].projects[$row.project_key].status
           else . end)
         | sort_by(.fleet, .project_id, (.checkout_id // ""), (.worktree_id // ""), (.root // ""))),
       discovery_ignores: (($state[0].discovery_ignores // {})
         | with_entries(select($fleet == "" or .key == $fleet)))}
  ' "$output"
  rc="$?"
  if [ "$rc" -eq 0 ] && [ -n "$batchdir" ] && [ -n "$pin_dir" ] && [ ! -e "$batchdir/demoted" ]; then
    _LOCAL_REGISTRY_SYNC_PROOF_READY=1
  fi
  _local_registry_batch_cleanup "$batchdir"; rm -f "$state" "$rows" "$output"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Selection-scoped state reporting, shared by every consumer that narrows a
# listing with `--project`, a bare project selector, or an adoption selector.
#
# A registry state error is a property of the REGISTRY, not of the caller's
# selection. Every consumer that filtered the listing first and only then looked
# for `identity_error` rows could exit 0 — or exit on a LOWER class, from a
# usage or unavailable preflight — over a registry it had just been shown to be
# corrupt. The rule these helpers encode is: compute the state class from the
# FULL listing, compute ACTIONS from the selection, and never let an exit path
# report below the state class already proven.
#
# Rows inside the selection are reported by the consumer's own row loop, so
# SELECTED (newline-delimited listing rows, possibly empty) suppresses those and
# leaves exactly the rows that would otherwise go unreported.
# ---------------------------------------------------------------------------

# Prints the higher of two exit classes.
local_registry_max_class() {
  local current="${1:-0}" candidate="${2:-0}"
  if [ "$candidate" -gt "$current" ]; then printf '%s\n' "$candidate"; else printf '%s\n' "$current"; fi
}

# local_registry_report_unselected_state_errors LISTING_JSON [SELECTED_ROWS]
#
# Reports every `identity_error` row of LISTING_JSON that is absent from
# SELECTED_ROWS and returns TRELLIS_EX_STATE when any was reported, 0 otherwise.
# Fails CLOSED: an unreadable listing is itself a state error, never a silent 0.
local_registry_report_unselected_state_errors() {
  local listing="${1:-}" selected="${2:-}" seen rows row_key row_kind row_root
  seen="$(printf '%s\n' "$selected" | jq -s -c '
    [ .[] | [(.project_key // ""), (.kind // ""), (.checkout_id // ""),
             (.worktree_id // ""), (.root // "")] ]
  ' 2>/dev/null)" || seen=''
  [ -n "$seen" ] || seen='[]'
  rows="$(printf '%s\n' "$listing" | trellis_jq -r --argjson seen "$seen" '
    def key: [(.project_key // ""), (.kind // ""), (.checkout_id // ""),
              (.worktree_id // ""), (.root // "")];
    .entries[]?
    | select(.availability == "identity_error")
    # Bind the row key BEFORE stepping into $seen: inside `map`, `.` is the
    # seen element, so an inline `key` would be evaluated against that array.
    | . as $row
    | ($row | key) as $k
    | select((($seen | map(. == $k)) | any) | not)
    # Emitted as FIELDS, not as one composed sentence, so the untrusted field can
    # be neutralized on its own below. `@tsv` also keeps one row on one line: it
    # renders an embedded tab, newline, or CR as its two-character escape instead
    # of letting it split the record.
    | [($row.project_key // "?"), ($row.kind // "?"),
       ($row.root // "(no recorded root)")] | @tsv
  ' 2>/dev/null)" || {
    local_registry_err "could not inspect the registry listing for identity-drift rows outside this selection"
    return "$TRELLIS_EX_STATE"
  }
  [ -n "$rows" ] || return 0
  # Escape the UNTRUSTED sub-field only. `local_registry_safe_display` collapses
  # its whole argument to a placeholder, so passing the composed line handed the
  # operator "<unsafe registry text>" and nothing else — the row's identity, the
  # one part that says WHICH row drifted, was destroyed by the field that made
  # the line unsafe. project_key and kind are schema-constrained; the root is the
  # free-form field, and it is the only one collapsed. Same shape as the
  # worktree-scoped re-report above.
  while IFS=$'\t' read -r row_key row_kind row_root; do
    [ -n "$row_key" ] || continue
    local_registry_err "registry row outside this selection failed identity validation: $row_key $row_kind $(local_registry_safe_display "${row_root:-(no recorded root)}")"
  done <<EOF
$rows
EOF
  return "$TRELLIS_EX_STATE"
}

local_registry_resolve_project() {
  local home="${1:-}" fleet="${2:-}" project_id="${3:-}" key state rc
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  key="$(local_registry_project_key "$fleet" "$project_id")" || return "$?"
  state="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.state.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  local_registry_read_state "$home" > "$state"
  rc="$?"
  if [ "$rc" -ne 0 ]; then rm -f "$state"; return "$rc"; fi
  if ! jq -e -S --arg key "$key" '.projects[$key] // empty' "$state"; then
    rm -f "$state"; local_registry_err "project is not registered: $key"; return "$TRELLIS_EX_UNAVAILABLE"
  fi
  rm -f "$state"
}

# Resolution binds ONE row and validates it in full: the checkout ID, Git common
# directory, checkout root, worktree ID, and worktree root all come from the live
# canonical Git identity of ROOT, so the match is exactly as strict as the global
# identity validator is for this row. It reads diagnostic state so that an
# unrelated broken row cannot hide a resolvable one; mutations still revalidate
# globally under the registry lock.
local_registry_resolve_root() {
  [ "$#" -eq 2 ] || return "$TRELLIS_EX_USAGE"
  _local_registry_resolve_root "$1" "$2" 0
}

_local_registry_resolve_root_from_snapshot() {
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  _local_registry_resolve_root "$1" "$2" 1 "$3"
}

_local_registry_resolve_root() {
  local home="$1" root_input="$2" use_snapshot="$3" snapshot="${4:-}"
  local identity root checkout_root common checkout_id worktree_id state matches rc
  identity="$(local_registry_identity_for_root "$root_input")" || return "$?"
  root="$(printf '%s\n' "$identity" | jq -r '.root')"
  checkout_root="$(printf '%s\n' "$identity" | jq -r '.checkout_root')"
  common="$(printf '%s\n' "$identity" | jq -r '.git_common_dir')"
  checkout_id="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree_id="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  state="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.state.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  if [ "$use_snapshot" = 1 ]; then
    printf '%s\n' "$snapshot" > "$state"; rc="$?"
  else
    local_registry_read_diagnostic_state "$home" > "$state"; rc="$?"
  fi
  if [ "$rc" -ne 0 ]; then rm -f "$state"; return "$rc"; fi
  matches="$(jq -c -S --arg root "$root" --arg checkout_root "$checkout_root" --arg common "$common" \
    --arg checkout_id "$checkout_id" --arg worktree_id "$worktree_id" '
    [ .projects | to_entries[] as $project
      | $project.value.checkouts[$checkout_id]? as $checkout | select($checkout != null)
      | select($checkout.root == $checkout_root and $checkout.git_common_dir == $common)
      | $checkout.worktrees[$worktree_id]? | select(.root == $root)
      | {fleet: $project.value.fleet, project_id: $project.value.project_id, project_key: $project.key,
         checkout_id: $checkout_id, worktree_id: $worktree_id, root: $root,
         git_common_dir: $checkout.git_common_dir} ]
  ' "$state")" || { rm -f "$state"; return "$TRELLIS_EX_STATE"; }
  rm -f "$state"
  case "$(printf '%s\n' "$matches" | jq 'length')" in
    0) local_registry_err "worktree root is not registered: $root"; return "$TRELLIS_EX_UNAVAILABLE" ;;
    1) printf '%s\n' "$matches" | jq -S '.[0]' ;;
    *) local_registry_err "worktree root resolves to multiple registry records: $root"; return "$TRELLIS_EX_STATE" ;;
  esac
}

# Validates the full portable project manifest boundary and emits project_id.
local_registry_manifest_project_id() {
  local manifest="${1:-}" project_id
  trellis_home_require_jq || return "$?"
  if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then
    local_registry_err "project manifest must be a regular file: $manifest"
    return "$TRELLIS_EX_STATE"
  fi
  if ! jq -e -s '
    def safe: type == "string" and all(explode[]; . >= 32 and (. < 127 or . > 159));
    def project: safe and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def preset: type == "string" and test("^[a-z0-9][a-z0-9-]*[a-z0-9]$") and length >= 2 and length <= 64;
    def loop: type == "object" and ((keys_unsorted - ["max_iterations", "no_progress_iterations", "budget_ceiling_usd", "usd_per_mtok", "codex_usd_per_mtok"]) | length == 0)
      and ((has("max_iterations") | not) or (.max_iterations | type == "number" and floor == . and . >= 1))
      and ((has("no_progress_iterations") | not) or (.no_progress_iterations | type == "number" and floor == . and . >= 1))
      and ((has("budget_ceiling_usd") | not) or (.budget_ceiling_usd | type == "number" and . >= 0))
      and ((has("usd_per_mtok") | not) or (.usd_per_mtok | type == "number" and . > 0))
      and ((has("codex_usd_per_mtok") | not) or (.codex_usd_per_mtok | type == "number" and . > 0));
    def pipeline: type == "object" and ((keys_unsorted - ["enabled", "spec_required_diff_lines", "surgical_max_diff_lines"]) | length == 0)
      and ((has("enabled") | not) or (.enabled | type == "boolean"))
      and ((has("spec_required_diff_lines") | not) or (.spec_required_diff_lines | type == "number" and floor == . and . >= 1))
      and ((has("surgical_max_diff_lines") | not) or (.surgical_max_diff_lines | type == "number" and floor == . and . >= 1));
    def env_name:
      type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")
      and (ascii_upcase as $name
        | ($name | test("TOKEN|SECRET|KEY|PASSWORD") | not)
        and (["PATH", "HOME", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "IFS", "CDPATH", "NODE_OPTIONS", "DOCKER_HOST", "DOCKER_CONTEXT", "POSIXLY_CORRECT", "ZDOTDIR", "RUBYOPT", "PERL5OPT", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "PWD", "OLDPWD", "SHLVL", "_", "LANG", "LANGUAGE", "TZ", "NODE_PATH", "NODE_REPL_EXTERNAL_MODULE", "NODE_EXTRA_CA_CERTS", "NODE_ICU_DATA", "NODE_V8_COVERAGE", "RANDOM", "SRANDOM", "SECONDS", "LINENO", "OPTIND", "OPTARG", "PPID", "UID", "EUID", "GROUPS", "DIRSTACK", "FUNCNAME", "PIPESTATUS", "SHELL", "PS1", "PS2", "PS3", "PS4"] | index($name) == null)
        and ($name | test("^(XDG_|TMP|TEMP|GIT_|TRELLIS_|PROCESS_GATE_|SECURITY_GATE_|PYTHON|BASH|LD_|DYLD_|CALLER_|LC_|DOCKER_|COREPACK_|PERL|RUBY|GEM_|GH_)") | not));
    def gate:
      type == "object" and ((keys_unsorted - ["env_passthrough", "verdict_reuse", "docs_only_tests"]) | length == 0)
      and ((has("verdict_reuse") | not) or (.verdict_reuse | type == "boolean"))
      and ((has("docs_only_tests") | not) or (.docs_only_tests | type == "boolean"))
      and ((has("env_passthrough") | not) or (.env_passthrough | type == "array" and all(.[]; env_name) and ((unique | length) == length)));
    def security_gate:
      type == "object" and ((keys_unsorted - ["semgrep_timeout"]) | length == 0)
      and ((has("semgrep_timeout") | not) or (.semgrep_timeout | type == "number" and floor == . and . >= 1 and . <= 600));
    (if length == 1 then .[0] else null end) |
    type == "object"
    and ((keys_unsorted - ["$schema", "schema_version", "project_id", "presets", "autonomy", "package_manager", "loop_safety", "mandatory_pipeline", "gate", "security_gate", "gate_profiles"]) | length == 0)
    and .schema_version == 1 and (.project_id | project)
    and ((has("$schema") | not) or (."$schema" | safe))
    and ((has("presets") | not) or (.presets | type == "array" and all(.[]; preset) and ((unique | length) == length)))
    and ((has("autonomy") | not) or (.autonomy | type == "number" and floor == . and . >= 1 and . <= 5))
    and ((has("package_manager") | not) or (.package_manager == "auto" or .package_manager == "pnpm" or .package_manager == "npm" or .package_manager == "bun" or .package_manager == "yarn"))
    and ((has("loop_safety") | not) or (.loop_safety | loop))
    and ((has("mandatory_pipeline") | not) or (.mandatory_pipeline | pipeline))
    and ((has("gate") | not) or (.gate | gate))
    and ((has("security_gate") | not) or (.security_gate | security_gate))
    and ((has("gate_profiles") | not) or (.gate_profiles | type == "object" and all(.[]; type == "object")))
  ' "$manifest" >/dev/null 2>&1; then
    local_registry_err "project manifest failed schema-aware validation: $manifest"
    return "$TRELLIS_EX_STATE"
  fi
  project_id="$(jq -r '.project_id' "$manifest")" || return "$TRELLIS_EX_STATE"
  local_registry_require_project_id "$project_id" || return "$?"
  printf '%s\n' "$project_id"
}

# Strict parser for the historical seven-column Active projects table. It emits
# safe TSV because it rejects control characters and ambiguous pipes: a `|` that
# belongs to a cell must be written escaped (`\|`), and this parser unescapes it
# back into that cell rather than treating it as a column break.
#
# Two failure scopes, deliberately distinct:
#   - structural (no Active projects section, or no seven-column header row)
#     fails the whole file, because no row can be trusted without them;
#   - a single ambiguous row is rejected on its own, named by line and cell,
#     and every other row still imports.
# Row-scoped rejection needs somewhere to record the rejects. A caller that
# passes REJECTS_OUTPUT receives `line<TAB>reason` records and owns the exit
# class; a caller that does not keeps the original whole-file refusal, so no
# caller can drop a row silently.
local_registry_parse_legacy_markdown() {
  local registry_file="${1:-}" output="${2:-}" rejects="${3:-}"
  local rejects_file own_rejects="" status tab line_no reason
  [ -n "$registry_file" ] && [ -n "$output" ] || return "$TRELLIS_EX_USAGE"
  if [ -L "$registry_file" ] || [ ! -f "$registry_file" ]; then
    local_registry_err "legacy registry source must be a regular file: $registry_file"
    return "$TRELLIS_EX_STATE"
  fi
  rejects_file="$rejects"
  if [ -z "$rejects_file" ]; then
    own_rejects="$(mktemp "${TMPDIR:-/tmp}/trellis.registry.legacy-rejects.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
    rejects_file="$own_rejects"
  fi
  : > "$rejects_file" || { rm -f "$own_rejects"; return "$TRELLIS_EX_UNAVAILABLE"; }
  awk -v rejects="$rejects_file" '
    function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
    function reject(line_no, reason) {
      rejected++
      printf("%d\t%s\n", line_no, reason) > (rejects)
    }
    BEGIN {
      split("Project,Path,Class,Shared services,Project-owned local infrastructure,Fixed-port status,Notes", column, ",")
    }
    /^## Active projects[[:space:]]*$/ { active=1; seen=1; next }
    active && /^## / { active=0 }
    !active { next }
    /^\|/ {
      line=$0
      # SUBSEP stands in for an escaped pipe while the row is split, so a row
      # already carrying it could smuggle a column break into a cell.
      if (index(line, SUBSEP) > 0) { reject(NR, "row contains a reserved control character"); next }
      gsub(/\\\|/, SUBSEP, line)
      sub(/^\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      count=split(line, fields, /[|]/)
      for (i=1; i<=count; i++) { fields[i]=trim(fields[i]); gsub(SUBSEP, "|", fields[i]) }
      if (fields[2] ~ /^`[^`]+`$/) { sub(/^`/, "", fields[2]); sub(/`$/, "", fields[2]) }
      if (count == 7 && fields[1] == "Project" && fields[2] == "Path") { header=1; next }
      if (count == 7 && fields[1] ~ /^-+$/) next
      if (count != 7) { reject(NR, sprintf("expected 7 cells, found %d; write a literal pipe as \\|", count)); next }
      if (fields[1] == "") { reject(NR, "cell 1 (Project) is empty"); next }
      if (fields[2] == "") { reject(NR, "cell 2 (Path) is empty"); next }
      row_bad=0
      for (i=1; i<=count; i++) {
        if (fields[i] ~ /[\t\r\n]/) {
          reject(NR, sprintf("cell %d (%s) contains a control character", i, column[i]))
          row_bad=1
          break
        }
      }
      if (row_bad) next
      print fields[1] "\t" fields[2] "\t" fields[3] "\t" fields[4] "\t" fields[5] "\t" fields[6] "\t" fields[7] "\t" NR
    }
    END {
      if (!seen || !header) exit 1
      # awk implementations also use exit 2 for fatal I/O errors. Reserve a
      # distinct status for the successfully parsed, row-rejected case.
      if (rejected) exit 42
    }
  ' "$registry_file" > "$output"
  status="$?"
  tab="$(printf '\t')"
  while IFS="$tab" read -r line_no reason; do
    [ -n "$line_no" ] || continue
    local_registry_err "legacy registry row rejected: $registry_file:$line_no: $reason"
  done < "$rejects_file"
  rm -f "$own_rejects"
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  # Rejected rows are the caller's to classify once it asked for the records.
  if [ "$status" -eq 42 ] && [ -n "$rejects" ]; then
    return 0
  fi
  rm -f "$output"
  local_registry_err "legacy registry Markdown is malformed: $registry_file"
  return "$TRELLIS_EX_STATE"
}

local_registry_legacy_metadata() {
  local registry_file="${1:-}" line_number="${2:-}" class="${3:-}" shared_services="${4:-}" project_infra="${5:-}" fixed_ports="${6:-}" notes="${7:-}" exclusion="${8:-null}" legacy_path="${9:-}"
  trellis_jq -n -cS \
    --arg registry_file "$registry_file" --arg class "$class" --arg shared_services "$shared_services" \
    --arg project_infra "$project_infra" --arg fixed_ports "$fixed_ports" --arg notes "$notes" \
    --arg legacy_path "$legacy_path" \
    --argjson line "$line_number" --argjson exclusion "$exclusion" '
      if ($exclusion != null and
          (($exclusion | type) != "object" or
           ($exclusion | keys | sort) != ["added", "project_id", "reason", "review_after"]))
      then error("invalid exclusion metadata")
      else
        {legacy: {registry_file: $registry_file, line: $line, class: $class, shared_services: $shared_services, project_owned_local_infrastructure: $project_infra, fixed_port_status: $fixed_ports, notes: $notes}}
        | if $legacy_path != "" then .legacy.legacy_path = $legacy_path else . end
        | if $exclusion != null then
            .legacy.blacklisted = true
            | .legacy.blacklist = {
                reason: $exclusion.reason,
                added: $exclusion.added,
                review_after: $exclusion.review_after
              }
          else . end
      end
    '
}

# Sourcing callers may replace helpers for tests or specialized behaviour. A
# batch must not bypass such a replacement; the scalar route observes it.
_LOCAL_REGISTRY_BATCH_HELPERS_ORIGINAL="$(_local_registry_batch_helpers)"
_LOCAL_REGISTRY_LIST_JSON_ORIGINAL="$(declare -f local_registry_list_json)"
