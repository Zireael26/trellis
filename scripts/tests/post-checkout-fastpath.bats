#!/usr/bin/env bats
#
# Spec 072 U5: post-checkout fast paths. A file checkout runs only the prior
# hook, before the private command scratch exists. A branch checkout in a
# worktree already attached to the verified release, that touches none of its
# attachment, skips the reconcile. Anything else takes the full reconcile.
#
# Witnesses: the full reconcile ends in attach, which records a pending
# attachment status (the attach in setup runs with the postjob off, so none
# exists before) or, on a refusal, reports the failed reconciliation. A file
# checkout's witness is the scratch root, which allocation creates.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/t14-worktree

setup() {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  BASE="$(git -C "$T14_PROJECT" symbolic-ref --short HEAD)"
  make_branch other src.txt 'other'
  make_branch owned .claude/rules/trellis.md 'tracked over the owned link'
  make_branch manifest .trellis.json '{"schema_version":1,"project_id":"fixture-project","extra":1}'
  TRELLIS_ATTACH_POSTJOB=off t14_attach >/dev/null
  OWNER="$(t14_owner_for_root "$T14_PROJECT")"
  MANAGED="$(jq -r '.git_hooks.managed_hooks_path' "$OWNER")"
  PAYLOAD="$TRELLIS_HOME/releases/$T14_RELEASE/payload"
  MARKER="$T14_SANDBOX/prior"
  write_prior_hook 0
  stamp_release
  [ -z "$(status_records)" ]
}

teardown() {
  t14_teardown_sandbox
}

make_branch() {
  local branch="$1" path="$2" content="$3"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null checkout -q -b "$branch" "$BASE"
  mkdir -p "$(dirname "$T14_PROJECT/$path")"
  printf '%s\n' "$content" > "$T14_PROJECT/$path"
  git -C "$T14_PROJECT" add -f "$path"
  git -C "$T14_PROJECT" commit -qm "fixture $branch"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null checkout -q "$BASE"
}

write_prior_hook() {
  mkdir -p "$T14_PROJECT/.git/hooks"
  cat > "$T14_PROJECT/.git/hooks/post-checkout" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$MARKER"
exit $1
EOF
  chmod +x "$T14_PROJECT/.git/hooks/post-checkout"
}

# What a full verify leaves behind: a stamp of the release as it is now.
stamp_release() {
  local release="$TRELLIS_HOME/releases/$T14_RELEASE" token
  token="$(python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" check "$TRELLIS_HOME" "$release")" && return 0
  python3 -I "$PAYLOAD/scripts/lib/release_stamp.py" write "$TRELLIS_HOME" "$release" "$token"
}

status_records() {
  find "$TRELLIS_HOME/state/attachment-status" -name '*.json' -print 2>/dev/null
}

switch_to() {
  rm -f "$MARKER"
  run git -C "$T14_PROJECT" switch -q "$@"
}

assert_fast() {
  [ -f "$MARKER" ] || { echo 'prior hook did not run'; false; }
  [ "$(sed -n 3p "$MARKER")" = 1 ]
  [ -z "$(status_records)" ] || { echo "full reconcile ran: $(status_records)"; printf '%s\n' "$output"; false; }
  [[ "$output" != *'attachment reconciliation failed'* ]] || { printf '%s\n' "$output"; false; }
}

assert_full() {
  [ -f "$MARKER" ] || { echo 'prior hook did not run'; false; }
  if [ -z "$(status_records)" ] && [[ "$output" != *'attachment reconciliation failed'* ]]; then
    echo "fast path taken: status=$status"
    printf '%s\n' "$output"
    false
  fi
}

# A full reconcile also starts a detached postjob that rewrites the status
# record when it ends; let it end before the witness is cleared.
reset_witness() {
  local tries=0
  while pgrep -f "$TRELLIS_HOME/releases/.*/attach-postjob.sh" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 600 ] || { echo 'postjob did not finish'; return 1; }
    sleep 0.1
  done
  rm -rf "$TRELLIS_HOME/state/attachment-status"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null checkout -q -f "$BASE"
}

@test "a file checkout runs the prior hook with its status before any scratch exists" {
  rm -rf "$TRELLIS_HOME/state/scratch"
  printf 'changed\n' > "$T14_PROJECT/README.md"
  rm -f "$MARKER"
  run git -C "$T14_PROJECT" checkout -- README.md
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ "$(cat "$T14_PROJECT/README.md")" = fixture ]
  [ "$(sed -n 3p "$MARKER")" = 0 ]
  [ ! -e "$TRELLIS_HOME/state/scratch" ] || { echo 'file checkout allocated a scratch'; false; }

  write_prior_hook 23
  head="$(git -C "$T14_PROJECT" rev-parse HEAD)"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" "$3" "$3" 0' \
    _ "$T14_PROJECT" "$MANAGED/post-checkout" "$head"
  [ "$status" -eq 23 ] || { printf 'status=%s\n%s\n' "$status" "$output"; false; }
  [ ! -e "$TRELLIS_HOME/state/scratch" ]

  # The witness works: a branch checkout allocates (and cleans) the scratch.
  write_prior_hook 0
  switch_to other
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  [ -d "$TRELLIS_HOME/state/scratch" ]
  [ -z "$(find "$TRELLIS_HOME/state/scratch" -mindepth 1 -print)" ]
}

@test "a branch switch in a current worktree runs the prior hook first and skips the reconcile" {
  switch_to other
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  assert_fast
  [ -f "$T14_PROJECT/src.txt" ]

  # The prior hook's status is still the dispatcher's (git reports any
  # failing post-checkout as 1, so run the dispatcher as git would).
  write_prior_hook 23
  rm -f "$MARKER"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c 'cd "$1" && "$2" "$3" "$4" 1' \
    _ "$T14_PROJECT" "$MANAGED/post-checkout" \
    "$(git -C "$T14_PROJECT" rev-parse "$BASE")" "$(git -C "$T14_PROJECT" rev-parse other)"
  [ "$status" -eq 23 ] || { printf 'status=%s\n%s\n' "$status" "$output"; false; }
  assert_fast

  # Creating a branch at the same commit is current too.
  write_prior_hook 0
  switch_to -c fresh
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  assert_fast
}

@test "a branch switch that changes the project manifest or an owned path takes the full reconcile" {
  switch_to manifest
  assert_full
  reset_witness

  # Git overwrites the ignored owned link with the tracked file.
  switch_to owned
  assert_full
  reset_witness
}

@test "a retargeted or swapped runtime link, a stale stamp or a pending adoption takes the full reconcile" {
  runtime="$T14_PROJECT/.trellis/runtime"

  # Same release through an aliased path: the link text is not the payload.
  ln -s "$TRELLIS_HOME/releases" "$T14_SANDBOX/releases alias"
  ln -sfn "$T14_SANDBOX/releases alias/$T14_RELEASE/payload" "$runtime"
  switch_to other
  assert_full
  ln -sfn "$PAYLOAD" "$runtime"
  reset_witness

  # .trellis swapped for a symlink to a directory holding an exact link.
  mv "$T14_PROJECT/.trellis" "$T14_SANDBOX/moved trellis"
  ln -s "$T14_SANDBOX/moved trellis" "$T14_PROJECT/.trellis"
  switch_to other
  assert_full
  rm "$T14_PROJECT/.trellis"
  mv "$T14_SANDBOX/moved trellis" "$T14_PROJECT/.trellis"
  reset_witness

  # A payload file whose ctime moved since the stamp: the stamp misses.
  chmod u+w "$PAYLOAD/core-rules/CLAUDE.md"
  chmod u-w "$PAYLOAD/core-rules/CLAUDE.md"
  switch_to other
  assert_full
  stamp_release
  reset_witness

  checkout="$(t14_checkout_id "$T14_PROJECT")"
  mkdir -p "$TRELLIS_HOME/state/release-adoptions/$checkout"
  switch_to other
  assert_full
  rmdir "$TRELLIS_HOME/state/release-adoptions/$checkout"
  reset_witness

  # Restored: current again.
  switch_to other
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  assert_fast
}

# Commits <path> on a new branch at BASE without touching the worktree, so a
# case variant can be committed on a case-insensitive volume.
commit_branch() {
  local index="$T14_SANDBOX/index.$1" blob tree commit
  blob="$(printf '%s\n' "$3" | git -C "$T14_PROJECT" hash-object -w --stdin)"
  GIT_INDEX_FILE="$index" git -C "$T14_PROJECT" read-tree "$BASE"
  GIT_INDEX_FILE="$index" git -C "$T14_PROJECT" update-index --add --cacheinfo "100644,$blob,$2"
  tree="$(GIT_INDEX_FILE="$index" git -C "$T14_PROJECT" write-tree)"
  commit="$(git -C "$T14_PROJECT" commit-tree "$tree" -p "$BASE" -m "fixture $1")"
  git -C "$T14_PROJECT" update-ref "refs/heads/$1" "$commit"
}

# On a case-insensitive volume (the macOS default) Git writes these over the
# real files; a case-sensitive one keeps them apart, and the fold still counts
# them, which only costs a full reconcile.
@test "a case or Unicode variant of the manifest or an owned path takes the full reconcile" {
  commit_branch manifest-case .Trellis.json '{"schema_version":1,"project_id":"other-project"}'
  commit_branch owned-case .claude/rules/TRELLIS.md 'tracked over the owned link'
  commit_branch accented "$(printf 'caf\303\251.txt')" 'accented'

  # Owned-case last: it replaces the owned link, so every later switch misses.
  switch_to accented
  assert_full
  reset_witness

  switch_to manifest-case
  assert_full
  reset_witness

  switch_to owned-case
  assert_full
  reset_witness
}

@test "an owned artifact that drifted on disk takes the full reconcile when the diff misses it" {
  link="$T14_PROJECT/.claude/rules/trellis.md"
  target="$(readlink "$link")"
  rm "$link"
  switch_to other
  assert_full
  ln -s "$target" "$link"
  reset_witness

  # Retargeted to the same file by another spelling.
  ln -s "$TRELLIS_HOME/releases" "$T14_SANDBOX/releases alias"
  ln -sfn "$T14_SANDBOX/releases alias/${target#"$TRELLIS_HOME/releases/"}" "$link"
  switch_to other
  assert_full
  ln -sfn "$target" "$link"
  reset_witness

  switch_to other
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
  assert_fast
}
