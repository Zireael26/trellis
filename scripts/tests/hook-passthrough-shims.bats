#!/usr/bin/env bats

# Managed git-hooks pass-through shims: Trellis owns post-checkout/pre-push in
# the managed dir, and every other executable project hook under
# previous-hooks-path keeps running through a deterministic shim.

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hook-passthrough-shims.XXXXXX")"
  ROOT="$(CDPATH='' cd "$ROOT" && pwd -P)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/scripts/attach-project.sh"
  set +u
  HOME_FIX="$ROOT/home"
  PROJECT="$ROOT/project"
  PREVIOUS="$PROJECT/.previous-hooks"
  CHECKOUT_ID="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  MANAGED="$HOME_FIX/state/git-hooks/$CHECKOUT_ID"
  RELEASE="1.2.3"
  PAYLOAD="$HOME_FIX/releases/$RELEASE/payload"
  OWNER="$ROOT/owner.json"
  mkdir -p "$HOME_FIX" "$PROJECT"
  git init -q "$PROJECT"
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config user.name Fixture
}

teardown() {
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT"
}

make_previous_hooks() {
  mkdir -p "$PREVIOUS"
  cat > "$PREVIOUS/pre-commit" <<EOF
#!/bin/sh
record="$ROOT/record-pre-commit"
printf 'ARGC=%s\n' "\$#" > "\$record"
i=1
for arg in "\$@"; do
  printf 'ARG%s=%s\n' "\$i" "\$arg" >> "\$record"
  i=\$((i + 1))
done
printf 'PATH=%s\n' "\$PATH" >> "\$record"
printf 'HOME=%s\n' "\$HOME" >> "\$record"
printf 'TMPDIR=%s\n' "\${TMPDIR-__UNSET__}" >> "\$record"
printf 'TMP=%s\n' "\${TMP-__UNSET__}" >> "\$record"
printf 'TEMP=%s\n' "\${TEMP-__UNSET__}" >> "\$record"
printf 'LC_ALL=%s\n' "\${LC_ALL-__UNSET__}" >> "\$record"
printf 'ALLOW=%s\n' "\${TRELLIS_ALLOW_MAIN_PUSH-__UNSET__}" >> "\$record"
printf 'BASH_ENV=%s\n' "\${BASH_ENV-__UNSET__}" >> "\$record"
printf 'GIT_INDEX_FILE=%s\n' "\${GIT_INDEX_FILE-__UNSET__}" >> "\$record"
printf 'GIT_AUTHOR_NAME=%s\n' "\${GIT_AUTHOR_NAME-__UNSET__}" >> "\$record"
printf 'LEAK=%s\n' "\${LEAK-__UNSET__}" >> "\$record"
EOF
  chmod 700 "$PREVIOUS/pre-commit"
  cat > "$PREVIOUS/commit-msg" <<'SH'
#!/bin/sh
printf 'COMMIT_MSG_RAN\n'
SH
  chmod 700 "$PREVIOUS/commit-msg"
  # Trellis-owned names never get shims, even when the project has them.
  printf '#!/bin/sh\nexit 0\n' > "$PREVIOUS/pre-push"
  chmod 700 "$PREVIOUS/pre-push"
  # Executable but not a git hook name: must never get a shim.
  printf '#!/bin/sh\necho tool\n' > "$PREVIOUS/my-tool"
  chmod 700 "$PREVIOUS/my-tool"
  git -C "$PROJECT" config --local core.hooksPath .previous-hooks
}

write_shims_for_previous() {
  local name body
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    body="$(_attachment_hooks_passthrough_shim_body "$name")" || return 1
    printf '%s\n' "$body" > "$MANAGED/$name" || return 1
    chmod 700 "$MANAGED/$name" || return 1
  done <<<"$(_attachment_hooks_expected_passthrough_names "$PROJECT" ".previous-hooks")"
}

prepare_managed_with_shims() {
  local carrier carrier_oid manifest
  make_previous_hooks
  mkdir -p "$MANAGED" "$PAYLOAD/core-rules/githooks"
  chmod 700 "$HOME_FIX/state" "$HOME_FIX/state/git-hooks" "$MANAGED" 2>/dev/null || {
    mkdir -p "$HOME_FIX/state/git-hooks"
    chmod 700 "$HOME_FIX/state" "$HOME_FIX/state/git-hooks" "$MANAGED"
  }
  carrier="$PAYLOAD/core-rules/githooks/pre-push"
  printf '#!/bin/sh\nexit 0\n' > "$carrier"
  chmod 700 "$carrier"
  carrier_oid="$(git hash-object "$carrier")" || return 1
  jq -n --arg release "$RELEASE" --arg oid "$carrier_oid" \
    '{schema_version:1,version:$release,tag:("v" + $release),commit:"0000000000000000000000000000000000000000",remote:"fixture",tree:[{path:"core-rules/githooks/pre-push",mode:"100755",oid:$oid}]}' \
    > "${PAYLOAD%/payload}/release.json" || return 1
  manifest="$(_attachment_hooks_release_manifest_sha256 "$PAYLOAD")" || return 1
  printf '%s\n' "$(_attachment_hooks_post_checkout_dispatcher_body "$PAYLOAD" "$manifest")" > "$MANAGED/post-checkout" || return 1
  printf '%s\n' "$(_attachment_hooks_pre_push_dispatcher_body "$PAYLOAD" 'core-rules/githooks/pre-push' "$manifest")" > "$MANAGED/pre-push" || return 1
  printf '%s\n' ".previous-hooks" > "$MANAGED/previous-hooks-path" || return 1
  printf '%s\n' "$PAYLOAD" > "$MANAGED/release-payload" || return 1
  printf '%s\n' 'core-rules/githooks/pre-push' > "$MANAGED/pre-push-source" || return 1
  chmod 700 "$MANAGED/post-checkout" "$MANAGED/pre-push"
  chmod 600 "$MANAGED/previous-hooks-path" "$MANAGED/release-payload" "$MANAGED/pre-push-source"
  write_shims_for_previous || return 1
  git -C "$PROJECT" config --local core.hooksPath "$MANAGED"
  jq -n --arg checkout "$CHECKOUT_ID" --arg root "$PROJECT" --arg release "$RELEASE" \
    --arg managed "$MANAGED" \
    '{checkout_id:$checkout,worktree_root:$root,release:$release,
      git_hooks:{enabled:true,managed_hooks_path:$managed,previous_hooks_path:".previous-hooks",
        pre_push_source:"core-rules/githooks/pre-push"}}' > "$OWNER" || return 1
}

@test "shims are written only for real hook names" {
  make_previous_hooks
  names="$(_attachment_hooks_expected_passthrough_names "$PROJECT" ".previous-hooks")"
  [ "$names" = "$(printf 'commit-msg\npre-commit')" ] || {
    printf 'unexpected shim set:\n%s\n' "$names"
    false
  }
  # Absolute previous paths enumerate the same set.
  absolute="$(_attachment_hooks_expected_passthrough_names "$PROJECT" "$PREVIOUS")"
  [ "$absolute" = "$names" ]
  # Empty or missing previous dirs yield no shims.
  [ -z "$(_attachment_hooks_expected_passthrough_names "$PROJECT" "")" ]
  [ -z "$(_attachment_hooks_expected_passthrough_names "$PROJECT" ".no-such-dir")" ]
  mkdir -p "$MANAGED"
  chmod 700 "$MANAGED"
  for core in post-checkout pre-push previous-hooks-path release-payload pre-push-source; do
    : > "$MANAGED/$core"
  done
  write_shims_for_previous
  [ -f "$MANAGED/pre-commit" ]
  [ -f "$MANAGED/commit-msg" ]
  [ ! -e "$MANAGED/my-tool" ]
  # The Trellis-owned pre-push dispatcher is left untouched: no shim overwrote it.
  [ "$(cat "$MANAGED/pre-push")" = "" ]
  _attachment_hooks_has_only_state_files "$MANAGED" || {
    echo "managed dir with shims rejected by allowlist"
    false
  }
}

@test "shim execs the previous hook with the caller env and argv" {
  make_previous_hooks
  mkdir -p "$MANAGED"
  chmod 700 "$MANAGED"
  printf '%s\n' ".previous-hooks" > "$MANAGED/previous-hooks-path"
  write_shims_for_previous
  run env -i PATH="/caller/bin:/usr/bin:/bin" HOME="$ROOT/caller-home" TMPDIR="$ROOT/caller-tmp" \
    TRELLIS_ALLOW_MAIN_PUSH=leaked BASH_ENV=/tmp/evil \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$PROJECT" "$MANAGED/pre-commit" hello "world arg"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  grep -Fx 'ARGC=2' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'ARG1=hello' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'ARG2=world arg' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx "PATH=/caller/bin:/usr/bin:/bin" "$ROOT/record-pre-commit" >/dev/null
  grep -Fx "HOME=$ROOT/caller-home" "$ROOT/record-pre-commit" >/dev/null
  grep -Fx "TMPDIR=$ROOT/caller-tmp" "$ROOT/record-pre-commit" >/dev/null
  grep -Fx "TMP=$ROOT/caller-tmp" "$ROOT/record-pre-commit" >/dev/null
  grep -Fx "TEMP=$ROOT/caller-tmp" "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'LC_ALL=C' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'ALLOW=__UNSET__' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'BASH_ENV=__UNSET__' "$ROOT/record-pre-commit" >/dev/null
}

@test "shim forwards GIT_* but strips unrelated vars" {
  make_previous_hooks
  mkdir -p "$MANAGED"
  chmod 700 "$MANAGED"
  printf '%s\n' ".previous-hooks" > "$MANAGED/previous-hooks-path"
  write_shims_for_previous
  run env -i PATH="/caller/bin:/usr/bin:/bin" HOME="$ROOT/caller-home" TMPDIR="$ROOT/caller-tmp" \
    GIT_INDEX_FILE="/tmp/git index file" GIT_AUTHOR_NAME="Fixture Author" LEAK=1 \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$PROJECT" "$MANAGED/pre-commit" hello
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  grep -Fx 'GIT_INDEX_FILE=/tmp/git index file' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'GIT_AUTHOR_NAME=Fixture Author' "$ROOT/record-pre-commit" >/dev/null
  grep -Fx 'LEAK=__UNSET__' "$ROOT/record-pre-commit" >/dev/null
}

@test "shim recreation aborts when the managed dir identity changes" {
  prepare_managed_with_shims
  rm -f "$MANAGED/pre-commit"
  [ ! -e "$MANAGED/pre-commit" ]
  manifest="$(_attachment_hooks_release_manifest_sha256 "$PAYLOAD")"
  SHIM_PIN_MANAGED="$MANAGED"
  SHIM_PIN_MARKER="$ROOT/identity-marker"
  rm -f "$SHIM_PIN_MARKER"
  release_store_directory_identity() {
    local path="$1" real=""
    if [ ! -e "$SHIM_PIN_MARKER" ]; then
      : > "$SHIM_PIN_MARKER"
      [ -d "$path" ] && [ ! -L "$path" ] || return 1
      real="$(/usr/bin/stat -f '%d:%i' "$path" 2>/dev/null)" || real=""
      case "$real" in ''|*[!0-9:]*|*:*:*|:*|*:) real="" ;; esac
      if [ -z "$real" ]; then
        real="$(/usr/bin/stat -c '%d:%i' "$path" 2>/dev/null)" || return 1
      fi
      [ -n "$real" ] || return 1
      printf '%s\n' "$real"
    else
      printf '%s\n' "1:1"
    fi
  }
  run attach_hooks_recreate_missing_dispatchers "$MANAGED" ".previous-hooks" "$PAYLOAD" "core-rules/githooks/pre-push" "$manifest" "$PROJECT"
  [ "$status" -eq 3 ] || { printf '%s\n' "$output"; false; }
  [ ! -e "$MANAGED/pre-commit" ]
}

@test "missing or non-executable previous hook exits 0" {
  make_previous_hooks
  mkdir -p "$MANAGED"
  chmod 700 "$MANAGED"
  printf '%s\n' ".previous-hooks" > "$MANAGED/previous-hooks-path"
  body="$(_attachment_hooks_passthrough_shim_body sendemail-validate)"
  printf '%s\n' "$body" > "$MANAGED/sendemail-validate"
  chmod 700 "$MANAGED/sendemail-validate"
  run bash -c 'cd "$1" && "$2" some-arg' _ "$PROJECT" "$MANAGED/sendemail-validate"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  write_shims_for_previous
  chmod 644 "$PREVIOUS/pre-commit"
  run bash -c 'cd "$1" && "$2"' _ "$PROJECT" "$MANAGED/pre-commit"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  chmod 700 "$PREVIOUS/pre-commit"
}

@test "validators accept the shimmed dir and reject stale or tampered shims" {
  prepare_managed_with_shims
  owner="$(cat "$OWNER")"
  _attachment_hooks_state_owned_matches_data "$HOME_FIX" "$owner" || {
    echo "strict validator rejected the shimmed dir"
    false
  }
  _attachment_hooks_present_shims_match "$MANAGED"
  # A stale shim (valid bytes, hook gone from previous) fails strict validation.
  body="$(_attachment_hooks_passthrough_shim_body sendemail-validate)"
  printf '%s\n' "$body" > "$MANAGED/sendemail-validate"
  chmod 700 "$MANAGED/sendemail-validate"
  if _attachment_hooks_state_owned_matches_data "$HOME_FIX" "$owner"; then
    echo "strict validator accepted a stale shim"
    false
  fi
  rm -f "$MANAGED/sendemail-validate"
  _attachment_hooks_state_owned_matches_data "$HOME_FIX" "$owner"
  # A tampered shim fails even the lenient content check.
  printf '#!/bin/sh\nexit 1\n' > "$MANAGED/pre-commit"
  chmod 700 "$MANAGED/pre-commit"
  if _attachment_hooks_state_owned_matches_data "$HOME_FIX" "$owner" false; then
    echo "lenient validator accepted a tampered shim"
    false
  fi
}

@test "detach removes the shims with the managed dir" {
  prepare_managed_with_shims
  owner="$(cat "$OWNER")"
  [ -f "$MANAGED/pre-commit" ]
  [ -f "$MANAGED/commit-msg" ]
  attach_hooks_remove "$HOME_FIX" "$owner"
  [ ! -e "$MANAGED/pre-commit" ]
  [ ! -e "$MANAGED/commit-msg" ]
  [ ! -e "$MANAGED" ]
  # Detach stays drift-tolerant: a deleted previous dir does not block it.
  prepare_managed_with_shims
  owner="$(cat "$OWNER")"
  rm -rf "$PREVIOUS"
  attach_hooks_remove "$HOME_FIX" "$owner"
  [ ! -e "$MANAGED" ]
}
