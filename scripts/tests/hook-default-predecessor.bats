#!/usr/bin/env bats
#
# Spec 074 T68: with no previous core.hooksPath recorded, git ran the default
# hooks dir (<common dir>/hooks) before attach. Attach treats it as the
# predecessor and shims its executable hooks, so they keep running while
# core.hooksPath names the managed dir; detach leaves core.hooksPath unset.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/t68-default-hooks.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/user" TRELLIS_HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 TRELLIS_ATTACH_POSTJOB=off
  local source="$SANDBOX/source" path
  SOURCE="$source"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$source/core-rules/templates" "$source/core-rules/githooks" "$source/scripts"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  mkdir -p "$source/core-rules/legacy-hooks"
  cp -R "$REPO_ROOT/core-rules/legacy-hooks/." "$source/core-rules/legacy-hooks/"
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$source/core-rules/templates/"
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
  printf '%s\n' '{"schema_version":1,"harnesses":{"claude":{"links":[{"source":"core-rules/CLAUDE.md","destination":".claude/rules/trellis.md"}],"render":[{"template":"core-rules/templates/claude-settings.local.json","destination":".claude/settings.local.json","merge":"explicit-json","mode":"0600","required":true}]},"codex":{"links":[{"source":"core-rules/CLAUDE.md","destination":".agents/rules/trellis.md"}],"render":[{"template":"core-rules/templates/codex-hooks.local.json","destination":".codex/hooks.json","merge":"explicit-json","mode":"0600","required":true}]}}}' \
    > "$source/core-rules/inheritance-manifest.json"
  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.0.1 "$source"
  PAYLOAD="$TRELLIS_HOME/releases/9.0.1/payload"

  PROJECT="$SANDBOX/project"
  git init -q "$PROJECT"
  git -C "$PROJECT" config user.name fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" config commit.gpgsign false
  printf '{"schema_version":1,"project_id":"t68-fixture"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" commit -qm initial
  BASE="$(git -C "$PROJECT" symbolic-ref --short HEAD)"
  git -C "$PROJECT" checkout -q -b other
  printf 'other\n' > "$PROJECT/src.txt"
  git -C "$PROJECT" add src.txt
  git -C "$PROJECT" commit -qm other
  git -C "$PROJECT" checkout -q "$BASE"
  HOOKS="$PROJECT/.git/hooks"
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

# A hook that records its name, argv and the directory it ran in.
recording_hook() {
  printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "%s" "$#" "$PWD" >> "%s"\n' "$2" "$SANDBOX/ran" > "$1"
}

attach() {
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  OWNER="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  MANAGED="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  [ "$(jq -r '.git_hooks.previous_hooks_path' "$OWNER")" = null ]
  [ "$(git -C "$PROJECT" config --local --get-all core.hooksPath)" = "$MANAGED" ]
}

stamp_release() {
  local release="${PAYLOAD%/payload}" token
  token="$(python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "$release")" && return 0
  python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" write "$TRELLIS_HOME" "$release" "$token"
}

managed_entries() {
  ls -A "$MANAGED" | LC_ALL=C sort | tr '\n' ' '
}

# Runs <code> with the attached payload's library loaded and P set to it.
payload_lib() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
P=$1
eval "$2"' payload-lib "$PAYLOAD" "$1"
}

# The owner-bound verifier a full attach runs, from the attached payload.
owner_verifier() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/dev/null LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null TRELLIS_LIBS_PRELOADED=1 "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" \
    /bin/bash --noprofile --norc -c '. "$1/scripts/lib/attachment.sh" >/dev/null 2>&1 || exit 9
_attachment_hooks_state_owned_matches "$2" "$3"' owner-verifier "$PAYLOAD" "$TRELLIS_HOME" "$OWNER"
}

sha() {
  shasum -a 256 "$1" | cut -c1-64
}

# Switch away and back with hooks on: 0 when the full reconcile ran, 1 when
# the fast path was taken, 2 when a switch failed.
reconciled_on_switch() {
  rm -f "$PROJECT/.reconciled"
  git -C "$PROJECT" switch -q other || return 2
  git -C "$PROJECT" -c core.hooksPath=/dev/null switch -q "$BASE" || return 2
  [ -e "$PROJECT/.reconciled" ]
}

assert_fast() {
  local rc=0
  reconciled_on_switch || rc=$?
  [ "$rc" -eq 1 ] || { echo "expected the fast path: $rc"; return 1; }
}

assert_full() {
  local rc=0
  reconciled_on_switch || rc=$?
  [ "$rc" -eq 0 ] || { echo "expected the full reconcile: $rc"; return 1; }
}

@test "a pre-existing executable .git/hooks/pre-commit still runs after attach, from every worktree" {
  local linked="$SANDBOX/linked"
  recording_hook "$HOOKS/pre-commit" pre-commit
  recording_hook "$HOOKS/commit-msg" commit-msg
  chmod 755 "$HOOKS/pre-commit" "$HOOKS/commit-msg"
  attach
  [ "$(managed_entries)" = "commit-msg post-checkout pre-commit pre-push pre-push-source previous-hooks-path release-payload " ]
  grep -Fxq '# trellis-managed-passthrough-default: pre-commit' "$MANAGED/pre-commit"
  owner_verifier

  printf 'one\n' > "$PROJECT/one.txt"
  git -C "$PROJECT" add one.txt
  git -C "$PROJECT" commit -qm one
  [ "$(cat "$SANDBOX/ran")" = "$(printf 'pre-commit 0 %s\ncommit-msg 1 %s' "$PROJECT" "$PROJECT")" ]

  # A linked worktree shares core.hooksPath and the common dir's hooks.
  git -C "$PROJECT" -c core.hooksPath=/dev/null worktree add -q -b linked "$linked"
  linked="$(CDPATH= cd "$linked" && pwd -P)"
  : > "$SANDBOX/ran"
  printf 'two\n' > "$linked/two.txt"
  git -C "$linked" add two.txt
  git -C "$linked" commit -qm two
  [ "$(cat "$SANDBOX/ran")" = "$(printf 'pre-commit 0 %s\ncommit-msg 1 %s' "$linked" "$linked")" ]
}

@test "a failing default hook still blocks the commit through its shim" {
  printf '#!/bin/sh\necho refused >&2\nexit 7\n' > "$HOOKS/pre-commit"
  chmod 755 "$HOOKS/pre-commit"
  attach
  printf 'one\n' > "$PROJECT/one.txt"
  git -C "$PROJECT" add one.txt
  run git -C "$PROJECT" commit -qm one
  [ "$status" -ne 0 ]
  [[ "$output" == *refused* ]]
  [ "$(git -C "$PROJECT" rev-list --count HEAD)" -eq 1 ]
}

@test "sample hooks, non-hook names, symlinked and non-executable hooks get no shim and never run" {
  local outside="$SANDBOX/outside-hook"
  [ -e "$HOOKS/pre-commit.sample" ]
  chmod 755 "$HOOKS/pre-commit.sample" "$HOOKS/commit-msg.sample"
  recording_hook "$HOOKS/my-tool" my-tool
  chmod 755 "$HOOKS/my-tool"
  recording_hook "$outside" outside
  chmod 755 "$outside"
  ln -s "$outside" "$HOOKS/pre-commit"
  recording_hook "$HOOKS/commit-msg" commit-msg
  chmod 644 "$HOOKS/commit-msg"
  attach
  [ "$(managed_entries)" = "post-checkout pre-push pre-push-source previous-hooks-path release-payload " ]
  owner_verifier
  printf 'one\n' > "$PROJECT/one.txt"
  git -C "$PROJECT" add one.txt
  git -C "$PROJECT" commit -qm one
  [ ! -e "$SANDBOX/ran" ]

  # A shim never follows a symlink swapped in after attach.
  rm "$HOOKS/pre-commit"
  recording_hook "$HOOKS/pre-commit" pre-commit
  chmod 755 "$HOOKS/pre-commit"
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  [ -f "$MANAGED/pre-commit" ]
  mv "$HOOKS/pre-commit" "$SANDBOX/aside"
  ln -s "$outside" "$HOOKS/pre-commit"
  ( cd "$PROJECT" && "$MANAGED/pre-commit" )
  [ ! -e "$SANDBOX/ran" ]
  run owner_verifier
  [ "$status" -ne 0 ]
  [ "$status" -ne 9 ]
}

@test "detach restores core.hooksPath to unset and leaves the default hooks to git" {
  recording_hook "$HOOKS/pre-commit" pre-commit
  chmod 755 "$HOOKS/pre-commit"
  run git -C "$PROJECT" config --local --get-all core.hooksPath
  [ "$status" -eq 1 ]
  attach
  [ -f "$MANAGED/pre-commit" ]
  run "$ATTACH" detach --home "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  run git -C "$PROJECT" config --get-all core.hooksPath
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$MANAGED" ]
  [ -x "$HOOKS/pre-commit" ]
  printf 'one\n' > "$PROJECT/one.txt"
  git -C "$PROJECT" add one.txt
  git -C "$PROJECT" commit -qm one
  [ "$(cat "$SANDBOX/ran")" = "pre-commit 0 $PROJECT" ]
}

@test "the hook digest memo carries the default shims, and the fast path checks them as the verifier does" {
  local memo expected
  recording_hook "$HOOKS/pre-commit" pre-commit
  chmod 755 "$HOOKS/pre-commit"
  attach
  stamp_release
  memo="$(find "$TRELLIS_HOME/state/hook-digests" -name '*.json' -type f)"
  [ -n "$memo" ]
  [ "$(printf '%s\n' "$memo" | wc -l)" -eq 1 ]
  jq -e '.schema_version == 2' "$memo" >/dev/null
  # Both shim maps cover every pass-through name, each as its generator has it.
  expected="$(payload_lib '
digest() { python3 -I -c "import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"; }
for name in $(_attachment_hooks_passthrough_names); do
  printf "%s %s\n" "$name" "$(printf "%s\n" "$(_attachment_hooks_default_passthrough_shim_body "$name")" | digest)"
done' | LC_ALL=C sort)"
  [ "$(printf '%s\n' "$expected" | wc -l)" -ge 20 ]
  [ "$(jq -r '.default_shims | to_entries[] | "\(.key) \(.value)"' "$memo" | LC_ALL=C sort)" = "$expected" ]
  [ "$(jq -r '.shims | keys[]' "$memo" | LC_ALL=C sort)" = "$(jq -r '.default_shims | keys[]' "$memo" | LC_ALL=C sort)" ]
  [ "$(sha "$MANAGED/pre-commit")" = "$(jq -r '.default_shims["pre-commit"]' "$memo")" ]
  [ "$(jq -r '.default_shims["pre-commit"]' "$memo")" != "$(jq -r '.shims["pre-commit"]' "$memo")" ]
  assert_fast

  # A new executable default hook with no shim yet: both reject.
  recording_hook "$HOOKS/post-merge" post-merge
  chmod 755 "$HOOKS/post-merge"
  run owner_verifier
  [ "$status" -ne 0 ]
  [ "$status" -ne 9 ]
  assert_full
  # Re-attach adds it; a symlinked or non-executable one changes nothing.
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.1 "$PROJECT" >/dev/null
  [ "$(sha "$MANAGED/post-merge")" = "$(jq -r '.default_shims["post-merge"]' "$memo")" ]
  ln -s "$HOOKS/pre-commit" "$HOOKS/post-commit"
  recording_hook "$HOOKS/pre-rebase" pre-rebase
  owner_verifier
  assert_fast

  # The recorded-predecessor shim in place of the default one: both reject.
  cp -p "$MANAGED/pre-commit" "$SANDBOX/pre-commit"
  payload_lib 'printf "%s\n" "$(_attachment_hooks_passthrough_shim_body pre-commit)"' > "$MANAGED/pre-commit"
  run owner_verifier
  [ "$status" -ne 0 ]
  [ "$status" -ne 9 ]
  assert_full
  cp -p "$SANDBOX/pre-commit" "$MANAGED/pre-commit"
  assert_fast

  # A default hook gone: its shim is now unexpected.
  mv "$HOOKS/pre-commit" "$SANDBOX/aside"
  run owner_verifier
  [ "$status" -ne 0 ]
  [ "$status" -ne 9 ]
  assert_full
}

# Installs 9.0.0 as a release from before T68: its library lacks the
# capability marker and, as 1.4.0 did, expects no default hooks dir shim.
install_pre_t68_release() {
  local old="$SANDBOX/source-old"
  cp -R "$SOURCE" "$old"
  printf '9.0.0\n' > "$old/core-rules/VERSION"
  python3 -I - "$old/scripts/lib/attachment.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
marker = "# trellis-capability: default-hooks-dir-shims\n"
head = "_attachment_hooks_payload_shims_default() {\n"
assert text.count(marker) == 1 and text.count(head) == 1
open(path, "w").write(text.replace(marker, "").replace(head, head + "  return 1\n"))
PY
  release_fixture_install "$HOME" "$TRELLIS_HOME" 9.0.0 "$old"
  OLD_PAYLOAD="$TRELLIS_HOME/releases/9.0.0/payload"
}

# release.sh runs only from an installed payload, so its hook adoption
# functions are loaded alone, as written there, over this library.
load_release_hook_functions() {
  local name
  set +u
  # shellcheck disable=SC1090
  source "$REPO_ROOT/scripts/attach-project.sh"
  set +u
  for name in release_err max_status hook_payload_matches write_hook_state_file; do
    eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$REPO_ROOT/scripts/release.sh")"
  done
  eval "$(sed -n '/^replace_hook_payload() ($/,/^)$/p' "$REPO_ROOT/scripts/release.sh")"
}

# Bytes and mode of every entry in the managed dir.
managed_snapshot() {
  ( cd "$MANAGED" && for f in * .[!.]*; do
      [ -e "$f" ] || continue
      printf '%s %s\n' "$(ls -ld "$f" | awk '{ print $1 }')" "$(shasum -a 256 "$f")"
    done )
}

@test "a release from before default shims gets none; adopting a current one adds them and rolling back removes them" {
  local snapshot
  recording_hook "$HOOKS/pre-commit" pre-commit
  chmod 755 "$HOOKS/pre-commit"
  install_pre_t68_release
  "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 9.0.0 "$PROJECT" >/dev/null
  OWNER="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  MANAGED="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  [ "$(managed_entries)" = "post-checkout pre-push pre-push-source previous-hooks-path release-payload " ]
  # The release's own verifier accepts what this attach wrote.
  PAYLOAD="$OLD_PAYLOAD" owner_verifier
  snapshot="$(managed_snapshot)"

  load_release_hook_functions
  hook_payload_matches "$MANAGED" "$OLD_PAYLOAD" "$PROJECT"
  run replace_hook_payload "$MANAGED" "$OLD_PAYLOAD" "$PAYLOAD" "$PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(managed_entries)" = "post-checkout pre-commit pre-push pre-push-source previous-hooks-path release-payload " ]
  grep -Fxq '# trellis-managed-passthrough-default: pre-commit' "$MANAGED/pre-commit"
  hook_payload_matches "$MANAGED" "$PAYLOAD" "$PROJECT"

  run replace_hook_payload "$MANAGED" "$PAYLOAD" "$OLD_PAYLOAD" "$PROJECT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(managed_snapshot)" = "$snapshot" ]
  PAYLOAD="$OLD_PAYLOAD" owner_verifier
  [ -z "$(find "${MANAGED%/*}" -mindepth 1 -maxdepth 1 -name '.*')" ]
}
