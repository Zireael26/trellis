#!/usr/bin/env bats
#
# Spec 072 U5: the post-checkout current-worktree check covers what the full
# reconcile would have checked beyond the commit diff: the owned keys of the
# rendered harness settings, the managed hook set, and the portable manifest's
# working-tree state and declared identity.
#
# The release carries the real settings templates and a reconcile that only
# records that it ran (.reconciled in the worktree), so the witness is direct.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/u5-state.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 TRELLIS_ATTACH_POSTJOB=off
  local source="$SANDBOX/source" path
  mkdir -p "$HOME" "$TRELLIS_HOME" "$source/core-rules/templates" "$source/core-rules/githooks" "$source/scripts"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  # Owned Booleans, at a leaf and nested, that a number must not stand in for.
  jq '. + {"enableAllProjectMcpServers": true, "fixtureOwned": {"flags": [true, 0, {"on": false}]}}' \
    "$REPO_ROOT/core-rules/templates/claude-settings.local.json" > "$source/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" "$source/core-rules/templates/"
  printf '# fixture policy\n' > "$source/core-rules/CLAUDE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$source/core-rules/githooks/pre-push"
  cat > "$source/scripts/seed-inheritance-symlinks.sh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in --target) target="$2"; shift ;; esac
  shift
done
: > "$target/.reconciled"
SH
  chmod 755 "$source/core-rules/githooks/pre-push" "$source/scripts/seed-inheritance-symlinks.sh"
  printf '9.0.1\n' > "$source/core-rules/VERSION"
  while IFS= read -r path; do
    [ "$path" != scripts/seed-inheritance-symlinks.sh ] || continue
    mkdir -p "$source/${path%/*}"
    cp "$REPO_ROOT/$path" "$source/$path"
  done < <(sed -n '/^  local -a paths=($/,/^  )$/p' "$REPO_ROOT/scripts/lib/attachment.sh" | sed '1d;$d;s/^ *//')
  printf '%s\n' '{"schema_version":1,"harnesses":{"claude":{"links":[{"source":"core-rules/CLAUDE.md","destination":".claude/rules/trellis.md"}],"render":[{"template":"core-rules/templates/claude-settings.local.json","destination":".claude/settings.local.json","merge":"explicit-json","mode":"0600","required":true}]},"codex":{"links":[{"source":"core-rules/CLAUDE.md","destination":".agents/rules/trellis.md"}],"render":[{"template":"core-rules/templates/codex-hooks.local.json","destination":".codex/hooks.json","merge":"explicit-json","mode":"0600","required":true}]}}}' > "$source/core-rules/inheritance-manifest.json"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.0.1 "$source"
  PAYLOAD="$TRELLIS_HOME/releases/9.0.1/payload"

  PROJECT="$SANDBOX/project"
  git init -q "$PROJECT"
  git -C "$PROJECT" config user.name fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"u5-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  BASE="$(git -C "$PROJECT" symbolic-ref --short HEAD)"
  git -C "$PROJECT" checkout -q -b other
  printf 'other\n' > "$PROJECT/src.txt"
  git -C "$PROJECT" add src.txt
  git -C "$PROJECT" commit -qm other
  git -C "$PROJECT" checkout -q "$BASE"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  OWNER="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  MANAGED="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  stamp_release
}

teardown() {
  /usr/bin/python3 - "$SANDBOX" <<'PY'
import os, shutil, sys
for root, dirs, files in os.walk(sys.argv[1]):
    os.chmod(root, 0o700)
    for name in files:
        path = os.path.join(root, name)
        if not os.path.islink(path):
            os.chmod(path, 0o600)
shutil.rmtree(sys.argv[1])
PY
}

# What a full verify leaves behind: a stamp of the release as it is now.
stamp_release() {
  local release="${PAYLOAD%/payload}" token
  token="$(python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "$release")" && return 0
  python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" write "$TRELLIS_HOME" "$release" "$token"
}

# Switch to <branch> and back with hooks on; leaves the reconcile witness.
round_trip() {
  rm -f "$PROJECT/.reconciled"
  run git -C "$PROJECT" switch -q other
  [ "$status" -eq 0 ] || { printf 'switch: %s\n%s\n' "$status" "$output"; return 1; }
  git -C "$PROJECT" -c core.hooksPath=/dev/null switch -q "$BASE"
}

assert_fast() {
  round_trip
  [ ! -e "$PROJECT/.reconciled" ] || { echo 'full reconcile ran'; false; }
}

assert_full() {
  round_trip
  [ -e "$PROJECT/.reconciled" ] || { echo 'fast path taken'; false; }
}

# The fast path not taken: the reconcile ran, or the hook failed loudly before
# it could (a sidecar that names no usable payload).
assert_missed() {
  rm -f "$PROJECT/.reconciled"
  run git -C "$PROJECT" switch -q other
  git -C "$PROJECT" -c core.hooksPath=/dev/null switch -q "$BASE"
  [ -e "$PROJECT/.reconciled" ] && return 0
  [ "$status" -ne 0 ] && [[ "$output" == *"attachment reconciliation failed"* ]] ||
    { printf 'fast path taken (switch %s)\n%s\n' "$status" "$output"; false; }
}

# Sets the first owned key of the render at <path> to <json>, keeping the mode.
drift_render() {
  local file="$PROJECT/$1" key
  key="$(jq -c --arg path "$1" '.renders[] | select(.path == $path) | .owned_keys[0].path' "$OWNER")"
  [ -n "$key" ] || { echo "no owned key for $1"; return 1; }
  jq --argjson key "$key" --argjson value "$2" 'setpath($key; $value)' "$file" > "$SANDBOX/drift.json"
  cat "$SANDBOX/drift.json" > "$file"
}

@test "a current worktree with rendered settings takes the fast path, and keeps project keys" {
  assert_fast
  for path in .claude/settings.local.json .codex/hooks.json; do
    jq '.projectOwned = {"kept": true}' "$PROJECT/$path" > "$SANDBOX/added.json"
    cat "$SANDBOX/added.json" > "$PROJECT/$path"
  done
  assert_fast
}

@test "an owned key drifted in either rendered settings file takes the full reconcile" {
  for path in .claude/settings.local.json .codex/hooks.json; do
    cp -p "$PROJECT/$path" "$SANDBOX/saved.json"
    drift_render "$path" '[]'
    assert_full
    cat "$SANDBOX/saved.json" > "$PROJECT/$path"
    assert_fast
  done
  # The guard list emptied, mode unchanged: the finding's exact scenario.
  jq '.hooks.PreToolUse = []' "$PROJECT/.claude/settings.local.json" > "$SANDBOX/drift.json"
  cat "$SANDBOX/drift.json" > "$PROJECT/.claude/settings.local.json"
  assert_full
}

@test "an owned Boolean read back as a number, or a number as a Boolean, takes the full reconcile" {
  local file="$PROJECT/.claude/settings.local.json" drift
  jq -e '.enableAllProjectMcpServers == true and .fixtureOwned.flags == [true, 0, {"on": false}]' "$file" >/dev/null
  cp -p "$file" "$SANDBOX/saved.json"
  assert_fast
  for drift in '.enableAllProjectMcpServers = 1' '.fixtureOwned.flags[0] = 1' \
      '.fixtureOwned.flags[1] = false' '.fixtureOwned.flags[2].on = 0'; do
    jq "$drift" "$SANDBOX/saved.json" > "$SANDBOX/drift.json"
    cat "$SANDBOX/drift.json" > "$file"
    assert_full
  done
  cat "$SANDBOX/saved.json" > "$file"
  assert_fast
}

# The owner-bound verifier a full attach runs, from the attached payload.
owner_verifier() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
_attachment_hooks_state_owned_matches "$2" "$3"' owner-verifier "$PAYLOAD" "$TRELLIS_HOME" "$OWNER"
}

# Applies one hook-state mutation (a shell snippet), requires the owner-bound
# verifier to reject it and the switch to take the full reconcile, then
# restores the saved state and requires both to accept again.
mutation_misses() {
  eval "$1"
  run owner_verifier
  [ "$status" -ne 0 ] || { echo "verifier accepted: $1"; return 1; }
  [ "$status" -ne 9 ] || { echo "verifier did not load"; return 1; }
  assert_missed || { echo "after: $1"; return 1; }
  restore_hook_state
  owner_verifier || { echo "verifier rejects the restored state: $1"; return 1; }
  assert_fast
}

restore_hook_state() {
  local name
  for name in previous-hooks-path release-payload pre-push-source; do
    cp -p "$SANDBOX/saved-hooks/$name" "$MANAGED/$name"
  done
  cp -p "$SANDBOX/saved-hooks/owner.json" "$OWNER"
}

# Rewrites the owner record through jq, keeping its mode.
edit_owner() {
  jq "$1" "$SANDBOX/saved-hooks/owner.json" > "$SANDBOX/owner.json"
  cat "$SANDBOX/owner.json" > "$OWNER"
}

@test "every hook-state change the owner-bound verifier rejects takes the full reconcile" {
  local name release="${PAYLOAD%/payload}"
  mkdir "$SANDBOX/saved-hooks" "$SANDBOX/prior-hooks"
  for name in previous-hooks-path release-payload pre-push-source; do
    cp -p "$MANAGED/$name" "$SANDBOX/saved-hooks/$name"
  done
  cp -p "$OWNER" "$SANDBOX/saved-hooks/owner.json"
  [ -z "$(jq -r '.git_hooks.previous_hooks_path // empty' "$OWNER")" ]
  [ "$(jq -r '.git_hooks.pre_push_source' "$OWNER")" = core-rules/githooks/pre-push ]
  owner_verifier
  assert_fast

  # Each sidecar, rewritten in place (mode 0600 kept) to a coherent value the
  # owner record does not name.
  mutation_misses 'printf "%s\n" "$SANDBOX/prior-hooks" > "$MANAGED/previous-hooks-path"'
  mutation_misses 'printf "%s\n" "$release/./payload" > "$MANAGED/release-payload"'
  mutation_misses 'printf "%s\n" core-rules/husky/pre-push > "$MANAGED/pre-push-source"'
  # The owner record's side of the same bindings.
  mutation_misses 'edit_owner ".git_hooks.managed_hooks_path = \"$SANDBOX/elsewhere\""'
  mutation_misses 'edit_owner ".git_hooks.previous_hooks_path = \"$SANDBOX/prior-hooks\""'
  # Not as a sidecar: the dispatcher runs the prior hook it names before any
  # check, so a sidecar naming the managed dir would run itself without end.
  mutation_misses 'edit_owner ".git_hooks.previous_hooks_path = \"$MANAGED\""'
  mutation_misses 'edit_owner ".git_hooks.pre_push_source = \"core-rules/husky/pre-push\""'

  # Hooks recorded as disabled: the verifier does not read the flag, but a
  # disabled record never vouches for a managed hook set, so this misses too.
  edit_owner '.git_hooks.enabled = false'
  assert_full
  restore_hook_state
  assert_fast

  # release.json changed and stamped again, as if a full verify had passed:
  # only the manifest the dispatchers were generated from can tell.
  cp -p "$release/release.json" "$SANDBOX/saved-hooks/release.json"
  chmod u+w "$release/release.json"
  printf '\n' >> "$release/release.json"
  chmod a-w "$release/release.json"
  stamp_release
  python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "$release" >/dev/null
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_missed
}

# Runs <code> with the attached payload's library loaded and P set to it.
payload_lib() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
P=$1
eval "$2"' payload-lib "$PAYLOAD" "$1"
}

hook_memo() {
  find "$TRELLIS_HOME/state/hook-digests" -name '*.json' -type f
}

@test "the attach records a hook digest memo equal to the generator's output for every hook file" {
  local memo manifest source expected
  memo="$(hook_memo)"
  [ -n "$memo" ] && [ "$(printf '%s\n' "$memo" | wc -l)" -eq 1 ]
  [ "$(python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$memo")" = 600 ]
  manifest="$(shasum -a 256 "${PAYLOAD%/payload}/release.json" | cut -c1-64)"
  source="$(jq -r '.git_hooks.pre_push_source' "$OWNER")"
  [ "${memo##*/}" = "$manifest-$(printf '%s' "$source" | shasum -a 256 | cut -c1-64).json" ]
  jq -e --arg m "$manifest" --arg p "$PAYLOAD" --arg s "$source" \
    '.schema_version == 1 and .manifest_sha256 == $m and .payload == $p and .pre_push_source == $s' "$memo" >/dev/null

  # The names the library passes through, as the case pattern spells them,
  # are the list the memo is built from and exactly the memo's shim keys.
  expected="$(sed -n '/^_attachment_hooks_is_passthrough_name() {/,/^}/p' "$PAYLOAD/scripts/lib/attachment.sh" |
    sed -n 's/^ *\([a-z0-9|-]*\)) return 0 ;;$/\1/p' | tr '|' '\n' | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$expected" | wc -l)" -ge 20 ]
  [ "$(payload_lib _attachment_hooks_passthrough_names | LC_ALL=C sort)" = "$expected" ]
  [ "$(jq -r '.shims | keys[]' "$memo" | LC_ALL=C sort)" = "$expected" ]

  # Every digest is the regeneration path's own output, hashed as installed.
  expected="$(payload_lib '
manifest="$(_attachment_hooks_release_manifest_sha256 "$P")" || exit 1
digest() { python3 -I -c "import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"; }
printf "post_checkout %s\n" "$(printf "%s\n" "$(_attachment_hooks_post_checkout_dispatcher_body "$P" "$manifest")" | digest)"
printf "pre_push %s\n" "$(printf "%s\n" "$(_attachment_hooks_pre_push_dispatcher_body "$P" core-rules/githooks/pre-push "$manifest")" | digest)"
for name in $(_attachment_hooks_passthrough_names); do
  printf "shim:%s %s\n" "$name" "$(printf "%s\n" "$(_attachment_hooks_passthrough_shim_body "$name")" | digest)"
done' | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$expected" | wc -l)" -ge 22 ]
  [ "$(jq -r '"post_checkout \(.post_checkout)", "pre_push \(.pre_push)", (.shims | to_entries[] | "shim:\(.key) \(.value)")' "$memo" |
    LC_ALL=C sort)" = "$expected" ]
  [ "$(shasum -a 256 "$MANAGED/post-checkout" | cut -c1-64)" = "$(jq -r .post_checkout "$memo")" ]
  [ "$(shasum -a 256 "$MANAGED/pre-push" | cut -c1-64)" = "$(jq -r .pre_push "$memo")" ]

  # A re-attach rebuilds the memo from the generator, even where the installed
  # files cannot vouch for an entry (no update hook is installed here).
  cp -p "$memo" "$SANDBOX/memo.json"
  jq '.shims.update = ("0" * 64)' "$SANDBOX/memo.json" > "$SANDBOX/memo-edit.json"
  cat "$SANDBOX/memo-edit.json" > "$memo"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  cmp "$memo" "$SANDBOX/memo.json"
}

@test "a missing, private-mode-broken or mismatched hook digest memo takes the full reconcile" {
  local memo edit
  memo="$(hook_memo)"
  cp -p "$memo" "$SANDBOX/memo.json"
  assert_fast
  rm "$memo"
  assert_full
  cp -p "$SANDBOX/memo.json" "$memo"
  assert_fast
  chmod 644 "$memo"
  assert_full
  chmod 600 "$memo"
  for edit in '.post_checkout = ("0" * 64)' '.pre_push = ("0" * 64)' '.payload = "/elsewhere/payload"' \
      '.manifest_sha256 = ("0" * 64)' '.pre_push_source = "core-rules/husky/pre-push"' '.schema_version = 2' \
      '.schema_version = true' '.shims = []' '.shims["pre-commit"] = "not-a-digest"' '.extra = 1' 'del(.shims)'; do
    jq "$edit" "$SANDBOX/memo.json" > "$SANDBOX/memo-edit.json"
    cat "$SANDBOX/memo-edit.json" > "$memo"
    assert_full || { echo "after: $edit"; false; }
  done
  # Valid JSON with the right digests, but over the 64 KiB cap.
  { cat "$SANDBOX/memo.json"; head -c 70000 /dev/zero | tr '\0' ' '; } > "$SANDBOX/memo-edit.json"
  cat "$SANDBOX/memo-edit.json" > "$memo"
  assert_full
  cat "$SANDBOX/memo.json" > "$memo"
  assert_fast

  # A link to a good memo, never followed.
  cp -p "$SANDBOX/memo.json" "$SANDBOX/memo-target.json"
  rm "$memo"
  ln -s "$SANDBOX/memo-target.json" "$memo"
  assert_full
  rm "$memo"
  cp -p "$SANDBOX/memo.json" "$memo"
  # The directory: another mode, or a link to a good copy.
  chmod 755 "${memo%/*}"
  assert_full
  chmod 700 "${memo%/*}"
  mv "${memo%/*}" "$SANDBOX/hook-digests"
  ln -s "$SANDBOX/hook-digests" "${memo%/*}"
  assert_full
  rm "${memo%/*}"
  mv "$SANDBOX/hook-digests" "${memo%/*}"
  assert_fast
}

@test "with a predecessor, the attach installs exactly the shims it calls for, as the memo and the generator have them" {
  local second="$SANDBOX/second" prior="$SANDBOX/second-hooks" owner managed memo base name expected
  mkdir "$prior"
  for name in pre-commit commit-msg; do
    printf '#!/bin/sh\nexit 0\n' > "$prior/$name"
    chmod 755 "$prior/$name"
  done
  printf '#!/bin/sh\nexit 0\n' > "$prior/not-a-hook"
  chmod 755 "$prior/not-a-hook"
  git init -q "$second"
  git -C "$second" config user.name fixture
  git -C "$second" config user.email fixture@example.invalid
  git -C "$second" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"u5-second"}\n' > "$second/.trellis.json"
  git -C "$second" add .trellis.json
  git -C "$second" -c core.hooksPath=/dev/null commit -qm initial
  base="$(git -C "$second" symbolic-ref --short HEAD)"
  git -C "$second" -c core.hooksPath=/dev/null checkout -q -b other
  printf 'other\n' > "$second/src.txt"
  git -C "$second" add src.txt
  git -C "$second" -c core.hooksPath=/dev/null commit -qm other
  git -C "$second" -c core.hooksPath=/dev/null checkout -q "$base"
  git -C "$second" config core.hooksPath "$prior"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$second" >/dev/null
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f -exec jq -r --arg root "$second" \
    'select(.worktree_root == $root) | input_filename' {} \;)"
  [ -n "$owner" ]
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$owner")" = "$prior" ]
  managed="$(jq -r '.git_hooks.managed_hooks_path' "$owner")"
  [ "$(ls -A "$managed" | LC_ALL=C sort | tr '\n' ' ')" = \
    "commit-msg post-checkout pre-commit pre-push pre-push-source previous-hooks-path release-payload " ]

  # One memo serves both checkouts: same release, same source.
  memo="$(hook_memo)"
  [ "$(printf '%s\n' "$memo" | wc -l)" -eq 1 ]
  expected="$(payload_lib '
digest() { python3 -I -c "import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"; }
for name in commit-msg pre-commit; do
  printf "%s %s\n" "$name" "$(printf "%s\n" "$(_attachment_hooks_passthrough_shim_body "$name")" | digest)"
done')"
  [ "$(jq -r '.shims | to_entries[] | select(.key == "commit-msg" or .key == "pre-commit") | "\(.key) \(.value)"' "$memo" |
    LC_ALL=C sort)" = "$expected" ]
  for name in commit-msg pre-commit; do
    [ "$name $(shasum -a 256 "$managed/$name" | cut -c1-64)" = "$(printf '%s\n' "$expected" | grep "^$name ")" ]
  done
  [ "$(shasum -a 256 "$managed/post-checkout" | cut -c1-64)" = "$(jq -r .post_checkout "$memo")" ]
  [ "$(shasum -a 256 "$managed/pre-push" | cut -c1-64)" = "$(jq -r .pre_push "$memo")" ]

  # And that layout takes the fast path.
  rm -f "$second/.reconciled"
  git -C "$second" switch -q other
  git -C "$second" -c core.hooksPath=/dev/null switch -q "$base"
  [ ! -e "$second/.reconciled" ]
}

@test "the shims a predecessor calls for are checked against the memo, as the owner-bound verifier checks them" {
  local prior="$SANDBOX/prior-hooks"
  mkdir "$prior"
  printf '#!/bin/sh\nexit 0\n' > "$prior/pre-commit"
  chmod 755 "$prior/pre-commit"
  jq --arg prior "$prior" '.git_hooks.previous_hooks_path = $prior' "$OWNER" > "$SANDBOX/owner.json"
  cat "$SANDBOX/owner.json" > "$OWNER"
  printf '%s\n' "$prior" > "$MANAGED/previous-hooks-path"
  (umask 077 && payload_lib 'printf "%s\n" "$(_attachment_hooks_passthrough_shim_body pre-commit)"' > "$MANAGED/pre-commit")
  chmod 700 "$MANAGED/pre-commit"
  cp -p "$MANAGED/pre-commit" "$SANDBOX/pre-commit"
  owner_verifier
  assert_fast

  printf '# drift\n' >> "$MANAGED/pre-commit"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full
  cp -p "$SANDBOX/pre-commit" "$MANAGED/pre-commit"
  assert_fast

  # A predecessor hook no longer executable: its shim is now unexpected.
  chmod 644 "$prior/pre-commit"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full
  chmod 755 "$prior/pre-commit"

  # A predecessor hook with no shim yet.
  printf '#!/bin/sh\nexit 0\n' > "$prior/commit-msg"
  chmod 755 "$prior/commit-msg"
  run owner_verifier
  [ "$status" -ne 0 ] && [ "$status" -ne 9 ]
  assert_full
}

@test "a missing, changed or non-executable managed pre-push takes the full reconcile" {
  cp -p "$MANAGED/pre-push" "$SANDBOX/pre-push"
  rm "$MANAGED/pre-push"
  assert_full
  cp -p "$SANDBOX/pre-push" "$MANAGED/pre-push"
  assert_fast

  printf '# drift\n' >> "$MANAGED/pre-push"
  assert_full
  cp -p "$SANDBOX/pre-push" "$MANAGED/pre-push"

  chmod 600 "$MANAGED/pre-push"
  assert_full
  chmod 700 "$MANAGED/pre-push"
  assert_fast

  git -C "$PROJECT" config --local --add core.hooksPath "$MANAGED"
  assert_full
}

@test "an unstaged or staged manifest change, or a committed identity change, takes the full reconcile" {
  # Same identity, other policy: only the working-tree state can tell.
  printf '{"schema_version":1,"project_id":"u5-fixture","gate":{"env_passthrough":["APP_MODE"]}}\n' \
    > "$PROJECT/.trellis.json"
  assert_full

  git -C "$PROJECT" add .trellis.json
  assert_full
  git -C "$PROJECT" reset -q -- .trellis.json
  git -C "$PROJECT" checkout -- .trellis.json
  assert_fast

  printf '{"schema_version":1,"project_id":"different-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json

  # Committed on both sides of the switch: the diff is silent, the identity is not.
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm 'fixture identity'
  git -C "$PROJECT" -c core.hooksPath=/dev/null branch -f other HEAD
  git -C "$PROJECT" -c core.hooksPath=/dev/null checkout -q other
  printf 'other\n' > "$PROJECT/src.txt"
  git -C "$PROJECT" add src.txt
  git -C "$PROJECT" -c core.hooksPath=/dev/null commit -qm other
  git -C "$PROJECT" -c core.hooksPath=/dev/null checkout -q "$BASE"
  [ -z "$(git -C "$PROJECT" status --porcelain -- .trellis.json)" ]
  assert_full
}
