#!/usr/bin/env bats

# Spec 053 Unit O: an owner record whose worktree Git no longer lists is named
# by attach, once per record, instead of surfacing as a vanished-root line plus
# a generic exclude-ownership line that points at the wrong cause.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
ATTACH="$REPO_ROOT/scripts/attach-project.sh"
load helpers/release-fixture
bats_require_minimum_version 1.5.0

canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}

make_release() {
  local release="$1" repo="$SANDBOX/release-source"
  mkdir -p "$repo/core-rules/commands/templates" "$repo/core-rules/templates" \
    "$repo/core-rules/husky" "$repo/core-rules/githooks" "$repo/scripts"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '# generated primer index\n' > "$repo/core-rules/commands/templates/primer-index-template.md"
  # The contextual SessionStart renders are validated against the real shipped
  # templates by path, so the fixture release carries the real bytes.
  cp "$REPO_ROOT/core-rules/templates/claude-settings.local.json" \
    "$repo/core-rules/templates/claude-settings.local.json"
  cp "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" \
    "$repo/core-rules/templates/codex-hooks.local.json"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/husky/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/core-rules/githooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/seed-inheritance-symlinks.sh"
  chmod 755 "$repo/core-rules/husky/pre-push" "$repo/core-rules/githooks/pre-push" "$repo/scripts/seed-inheritance-symlinks.sh"
  release_fixture_seal_executed_files "$repo" || return 1
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".claude/rules/trellis.md"}
      ],
      "render": [
        {"template": "core-rules/commands/templates/primer-index-template.md", "destination": ".claude/primers/INDEX.md", "merge": "replace", "mode": "0644", "required": true},
        {"template": "core-rules/templates/claude-settings.local.json", "destination": ".claude/settings.local.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    },
    "codex": {
      "links": [
        {"source": "core-rules/CLAUDE.md", "destination": ".agents/rules/trellis.md"}
      ],
      "render": [
        {"template": "core-rules/templates/codex-hooks.local.json", "destination": ".codex/hooks.json", "merge": "explicit-json", "mode": "0600", "required": true}
      ]
    }
  }
}
JSON
  printf '%s\n' "$release" > "$repo/core-rules/VERSION"
  # scripts/release.sh refuses pathname execution, so the fixture release is
  # sealed and installed through the bootstrap launcher instead.
  release_fixture_install "$HOME" "$TRELLIS_HOME" "$release" "$repo"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/attach-orphan-owner.XXXXXX")"
  SANDBOX="$(canonical_dir "$SANDBOX")"
  export HOME="$SANDBOX/user home"
  export TRELLIS_HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$TRELLIS_HOME"
  export HOME="$(canonical_dir "$HOME")"
  export TRELLIS_HOME="$(canonical_dir "$TRELLIS_HOME")"
  release_fixture_bootstrap "$HOME" "$TRELLIS_HOME" "$SANDBOX"
  make_release 1.2.3
  PROJECT="$SANDBOX/project with spaces"
  mkdir -p "$PROJECT"
  git init -q "$PROJECT"
  printf '{"schema_version":1,"project_id":"fixture-project"}\n' > "$PROJECT/.trellis.json"
  git -C "$PROJECT" add .trellis.json
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
  COMMON="$PROJECT/.git"
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

attach_root() {
  run --separate-stderr "$ATTACH" attach --home "$TRELLIS_HOME" --fleet personal --release 1.2.3 "$1"
}

add_worktree() {
  git -C "$PROJECT" worktree add -q -b "$2" "$1"
}

owner_for_root() {
  local owner
  while IFS= read -r owner; do
    [ "$(jq -r '.worktree_root' "$owner")" = "$1" ] && printf '%s\n' "$owner"
  done < <(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json' -print)
  return 0
}

# Keep a healthy shared-state manager and a non-managing sibling. The latter
# must retain worktree identity checks even though its native leaves may drift.
attach_identity_sibling() {
  local root="$1"
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  add_worktree "$root" identity-sibling
  attach_root "$root"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  SIBLING_OWNER="$(owner_for_root "$root")"
  [ -f "$SIBLING_OWNER" ]
  [ "$(jq -r '.git_hooks.enabled' "$SIBLING_OWNER")" = false ]
}

assert_owner_identity_refusal() {
  [ "$status" -eq 3 ] || {
    printf 'expected attach exit 3, got %s\nstdout: %s\nstderr: %s\n' "$status" "$output" "$stderr"
    return 1
  }
  [[ "$stderr" == *"$1: $SIBLING_OWNER"* ]] || { echo "$stderr"; return 1; }
}

# The uv-migration shape: the worktree is pruned and its registry row dropped,
# but the owner record stays behind. `kept` leaves the pruned directory on disk.
orphan_worktree() {
  local root="$1" shape="$2" worktree_id
  worktree_id="$(jq -r '.worktree_id' "$(owner_for_root "$root")")"
  mv "$root" "$SANDBOX/parked"
  git -C "$PROJECT" worktree prune
  [ "$shape" = missing ] || mv "$SANDBOX/parked" "$root"
  jq --arg worktree "$worktree_id" 'del(.projects[].checkouts[].worktrees[$worktree])' \
    "$TRELLIS_HOME/registry.json" > "$TRELLIS_HOME/registry.next"
  chmod 600 "$TRELLIS_HOME/registry.next"
  mv "$TRELLIS_HOME/registry.next" "$TRELLIS_HOME/registry.json"
}

# The date is read on both sides of the command so a run across midnight holds.
assert_orphan_line() {
  local line="$1" record="$2" root="$3" reason="$4" day
  for day in "$DAY_BEFORE" "$(date +%Y%m%d)"; do
    [ "$line" != "trellis attach: refused (orphan-owner-record): $record (worktree_root $root $reason); move it to $TRELLIS_HOME/backups/stale-owner-records-$day/" ] || return 0
  done
  echo "unexpected line: $line"
  false
}

move_aside() {
  mkdir -p "$SANDBOX/backup"
  mv "$1" "$SANDBOX/backup/"
}

classify() {
  bash -c '. "$1"; attachment_owner_orphan_reason "$2"' _ "$ATTACH" "$1"
}

write_record() {
  jq -n --arg root "$2" --arg common "$3" '{worktree_root:$root,exclude:{git_common_dir:$common}}' > "$1"
}

@test "a missing orphan beside a live sibling refuses by name until it is moved aside" {
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  add_worktree "$SANDBOX/wt one" one
  attach_root "$SANDBOX/wt one"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  orphan="$(owner_for_root "$SANDBOX/wt one")"
  orphan_worktree "$SANDBOX/wt one" missing
  add_worktree "$SANDBOX/wt two" two

  DAY_BEFORE="$(date +%Y%m%d)"
  attach_root "$SANDBOX/wt two"

  [ "$status" -eq 3 ]
  [ "${#stderr_lines[@]}" -eq 1 ] || { echo "$stderr"; false; }
  assert_orphan_line "${stderr_lines[0]}" "$orphan" "$SANDBOX/wt one" missing
  [ -f "$orphan" ]
  [ -z "$(owner_for_root "$SANDBOX/wt two")" ]

  move_aside "$orphan"
  attach_root "$SANDBOX/wt two"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
}

@test "a pruned worktree directory kept on disk is a not-a-worktree orphan" {
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  add_worktree "$SANDBOX/wt kept" kept
  attach_root "$SANDBOX/wt kept"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  orphan="$(owner_for_root "$SANDBOX/wt kept")"
  orphan_worktree "$SANDBOX/wt kept" kept
  [ -d "$SANDBOX/wt kept" ]
  add_worktree "$SANDBOX/wt next" next

  DAY_BEFORE="$(date +%Y%m%d)"
  attach_root "$SANDBOX/wt next"

  [ "$status" -eq 3 ]
  [ "${#stderr_lines[@]}" -eq 1 ] || { echo "$stderr"; false; }
  assert_orphan_line "${stderr_lines[0]}" "$orphan" "$SANDBOX/wt kept" not-a-worktree
  [ -f "$orphan" ]
}

@test "a sole orphan with the managed block present also names the ownerless block" {
  add_worktree "$SANDBOX/wt only" only
  attach_root "$SANDBOX/wt only"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  orphan="$(owner_for_root "$SANDBOX/wt only")"
  orphan_worktree "$SANDBOX/wt only" missing
  add_worktree "$SANDBOX/wt new" new

  DAY_BEFORE="$(date +%Y%m%d)"
  attach_root "$SANDBOX/wt new"

  [ "$status" -eq 3 ]
  [ "${#stderr_lines[@]}" -eq 2 ] || { echo "$stderr"; false; }
  assert_orphan_line "${stderr_lines[0]}" "$orphan" "$SANDBOX/wt only" missing
  [ "${stderr_lines[1]}" = "trellis attach: refused (orphan-owner-sole): managed exclude block in $COMMON/info/exclude has no other owner; see docs/UPGRADING.md \"Ownerless exclude block\"" ]

  # Moving the record aside alone still leaves the block without an owner.
  move_aside "$orphan"
  attach_root "$SANDBOX/wt new"
  [ "$status" -eq 3 ]

  # The docs/UPGRADING.md recovery: drop the block, keep every other line.
  printf 'project-local\n' >> "$COMMON/info/exclude"
  cp -p "$COMMON/info/exclude" "$SANDBOX/backup/info-exclude.before"
  sed -e '/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/d' \
    "$SANDBOX/backup/info-exclude.before" > "$COMMON/info/exclude"
  attach_root "$SANDBOX/wt new"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -Fxq 'project-local' "$COMMON/info/exclude"
}

@test "a sole orphan without the managed block is only an orphan" {
  add_worktree "$SANDBOX/wt only" only
  attach_root "$SANDBOX/wt only"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  orphan="$(owner_for_root "$SANDBOX/wt only")"
  orphan_worktree "$SANDBOX/wt only" missing
  cp "$COMMON/info/exclude" "$SANDBOX/exclude.with-block"
  sed -e '/^# --- Trellis local attachment exclude block ---$/,/^# --- end Trellis local attachment exclude block ---$/d' \
    "$SANDBOX/exclude.with-block" > "$COMMON/info/exclude"
  add_worktree "$SANDBOX/wt new" new

  DAY_BEFORE="$(date +%Y%m%d)"
  attach_root "$SANDBOX/wt new"

  [ "$status" -eq 3 ]
  [ "${#stderr_lines[@]}" -eq 1 ] || { echo "$stderr"; false; }
  assert_orphan_line "${stderr_lines[0]}" "$orphan" "$SANDBOX/wt only" missing

  move_aside "$orphan"
  attach_root "$SANDBOX/wt new"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
}

@test "an undetermined record keeps today's refusal and gets no orphan line" {
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  add_worktree "$SANDBOX/wt one" one
  attach_root "$SANDBOX/wt one"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  orphan_worktree "$SANDBOX/wt one" missing
  add_worktree "$SANDBOX/wt two" two
  # Git fails only for the orphan predicate's worktree listing.
  mkdir -p "$SANDBOX/stub"
  cat > "$SANDBOX/stub/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" safe.directory=* worktree list "*) exit 128 ;; esac
exec "$(command -v git)" "\$@"
EOF
  chmod 755 "$SANDBOX/stub/git"

  run --separate-stderr env PATH="$SANDBOX/stub:$PATH" "$ATTACH" attach --home "$TRELLIS_HOME" \
    --fleet personal --release 1.2.3 "$SANDBOX/wt two"

  [ "$status" -eq 3 ]
  [[ "$stderr" != *orphan-owner-record* ]] || { echo "$stderr"; false; }
  [[ "$stderr" == *"shared exclude owner has no live worktree"* ]] || { echo "$stderr"; false; }
}

@test "owner identity: an undetermined pruned worktree with a retained registry row refuses" {
  sibling="$SANDBOX/wt one"
  target="$SANDBOX/wt two"
  attach_identity_sibling "$sibling"
  cp "$TRELLIS_HOME/registry.json" "$SANDBOX/registry-before-prune"
  orphan_worktree "$sibling" kept
  # Retain the row: dropping it would let a later registry check mask the
  # missing identity check while the dangling Git file passed the entry test.
  cp "$SANDBOX/registry-before-prune" "$TRELLIS_HOME/registry.json"
  [ -d "$sibling" ] && [ -f "$sibling/.git" ]
  run git -C "$sibling" rev-parse --git-common-dir
  [ "$status" -ne 0 ]
  [ "$(classify "$SIBLING_OWNER")" = not-a-worktree ]
  add_worktree "$target" identity-target

  mkdir "$SANDBOX/stub"
  printf '#!/usr/bin/env bash\ncase " $* " in *" safe.directory=* worktree list "*) exit 128 ;; esac\nexec %q "$@"\n' \
    "$(command -v git)" > "$SANDBOX/stub/git"
  chmod 755 "$SANDBOX/stub/git"
  run env PATH="$SANDBOX/stub:$PATH" bash -c \
    '. "$1"; attachment_owner_orphan_reason "$2"' _ "$ATTACH" "$SIBLING_OWNER"
  [ "$status" -eq 0 ]
  [[ "$output" == "undetermined "* ]]

  run --separate-stderr env PATH="$SANDBOX/stub:$PATH" "$ATTACH" attach --home "$TRELLIS_HOME" \
    --fleet personal --release 1.2.3 "$target"

  assert_owner_identity_refusal "shared exclude owner no longer names its canonical worktree in this checkout"
  [[ "$stderr" != *orphan-owner-record* ]]
  [ -z "$(owner_for_root "$target")" ]
}

@test "owner identity: a still-listed root pointing at another checkout refuses" {
  sibling="$SANDBOX/wt one"
  target="$SANDBOX/wt two"
  attach_identity_sibling "$sibling"
  add_worktree "$target" identity-target
  git init -q "$SANDBOX/foreign"
  printf 'gitdir: %s/.git\n' "$SANDBOX/foreign" > "$sibling/.git"
  # The old checkout still lists this path; the orphan predicate cannot catch
  # its Git file now resolving to a different checkout.
  [ "$(classify "$SIBLING_OWNER")" = live ]

  attach_root "$target"

  assert_owner_identity_refusal "shared exclude owner no longer names its canonical worktree in this checkout"
  [ -z "$(owner_for_root "$target")" ]
}

@test "owner identity: a still-listed root behind a symlinked ancestor refuses" {
  sibling="$SANDBOX/parent/wt one"
  target="$SANDBOX/wt two"
  mkdir "$SANDBOX/parent"
  attach_identity_sibling "$sibling"
  add_worktree "$target" identity-target
  mv "$SANDBOX/parent" "$SANDBOX/moved-parent"
  ln -s "$SANDBOX/moved-parent" "$SANDBOX/parent"
  [ -d "$sibling" ] && [ ! -L "$sibling" ] && [ -L "$SANDBOX/parent" ]
  [ "$(classify "$SIBLING_OWNER")" = live ]

  attach_root "$target"

  assert_owner_identity_refusal "shared exclude owner no longer names its canonical worktree in this checkout"
  [ -z "$(owner_for_root "$target")" ]
}

@test "owner identity: current attach refuses a sibling now pointing at another checkout" {
  sibling="$SANDBOX/wt one"
  attach_identity_sibling "$sibling"
  git init -q "$SANDBOX/foreign"
  printf 'gitdir: %s/.git\n' "$SANDBOX/foreign" > "$sibling/.git"
  [ "$(classify "$SIBLING_OWNER")" = live ]

  # Already-current attach returns before shared-exclude preflight. This must
  # exercise the non-target branch of _attach_reconcile_verify_owners instead.
  attach_root "$PROJECT"

  assert_owner_identity_refusal "exact-owner reconcile refused: owner no longer names its canonical worktree in this checkout"
}

@test "owner identity: unrelated native drift still permits sibling attach and current retry" {
  sibling="$SANDBOX/wt one"
  target="$SANDBOX/wt two"
  attach_identity_sibling "$sibling"
  printf 'unrelated native drift\n' >> "$sibling/.claude/settings.local.json"
  run bash -c '. "$1"; attachment_verify "$2" "$3"' _ \
    "$REPO_ROOT/scripts/lib/attachment.sh" "$TRELLIS_HOME" "$SIBLING_OWNER"
  [ "$status" -eq 3 ]
  add_worktree "$target" identity-target

  attach_root "$target"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ -f "$(owner_for_root "$target")" ]
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [[ "$output" == *"already attached:"* ]]
}

@test "the orphan predicate classifies every O1 fixture" {
  mkdir -p "$SANDBOX/records"

  write_record "$SANDBOX/records/missing.json" "$SANDBOX/never here" "$COMMON"
  [ "$(classify "$SANDBOX/records/missing.json")" = missing ]

  add_worktree "$SANDBOX/wt kept" kept
  mv "$SANDBOX/wt kept" "$SANDBOX/parked"
  git -C "$PROJECT" worktree prune
  mv "$SANDBOX/parked" "$SANDBOX/wt kept"
  write_record "$SANDBOX/records/kept.json" "$SANDBOX/wt kept" "$COMMON"
  [ "$(classify "$SANDBOX/records/kept.json")" = not-a-worktree ]

  # The record reaches the common dir through a symlink; git lists the sibling
  # by the symlinked path.
  ln -s "$PROJECT" "$SANDBOX/project link"
  git -C "$SANDBOX/project link" worktree add -q -b sym "$SANDBOX/wt sym"
  write_record "$SANDBOX/records/sym.json" "$SANDBOX/wt sym" "$SANDBOX/project link/.git"
  [ "$(classify "$SANDBOX/records/sym.json")" = live ]

  write_record "$SANDBOX/records/main.json" "$PROJECT" "$COMMON"
  [ "$(classify "$SANDBOX/records/main.json")" = live ]

  # Listed but absent, named through a symlinked ancestor: still live. Git
  # lists the physical path, so only canonicalisation of the absent path matches.
  mkdir "$SANDBOX/real"
  ln -s real "$SANDBOX/alias"
  git -C "$PROJECT" worktree add -q -b away "$SANDBOX/alias/wt away"
  mv "$SANDBOX/real/wt away" "$SANDBOX/away parked"
  write_record "$SANDBOX/records/away.json" "$SANDBOX/alias/wt away" "$COMMON"
  [ "$(classify "$SANDBOX/records/away.json")" = live ]

  write_record "$SANDBOX/records/nocommon.json" "$SANDBOX/never here" "$SANDBOX/no such checkout/.git"
  [ "$(classify "$SANDBOX/records/nocommon.json")" = "undetermined git common dir $SANDBOX/no such checkout/.git is missing" ]

  mkdir -p "$SANDBOX/stub"
  printf '#!/usr/bin/env bash\nexit 128\n' > "$SANDBOX/stub/git"
  chmod 755 "$SANDBOX/stub/git"
  run env PATH="$SANDBOX/stub:$PATH" bash -c '. "$1"; attachment_owner_orphan_reason "$2"' _ "$ATTACH" "$SANDBOX/records/missing.json"
  [ "$status" -eq 0 ]
  [ "$output" = "undetermined git worktree list failed for $COMMON" ]
}

@test "a control character in an orphan's root cannot split its refusal line" {
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  owner_dir="$(dirname "$(owner_for_root "$PROJECT")")"
  write_record "$owner_dir/crafted.json" "$SANDBOX/gone"$'\n'"line" "$COMMON"
  chmod 600 "$owner_dir/crafted.json"
  add_worktree "$SANDBOX/wt two" two

  DAY_BEFORE="$(date +%Y%m%d)"
  attach_root "$SANDBOX/wt two"

  [ "$status" -eq 3 ]
  [ "${#stderr_lines[@]}" -eq 1 ] || { echo "$stderr"; false; }
  assert_orphan_line "${stderr_lines[0]}" "$owner_dir/crafted.json" "$SANDBOX/gone\\nline" missing
}

@test "an owner directory that cannot be listed refuses instead of reading as empty" {
  [ "$(id -u)" -ne 0 ] || skip 'root reads a mode-000 directory'
  attach_root "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  owner_dir="$(dirname "$(owner_for_root "$PROJECT")")"
  add_worktree "$SANDBOX/wt two" two
  chmod 000 "$owner_dir"

  attach_root "$SANDBOX/wt two"
  chmod 700 "$owner_dir"

  [ "$status" -eq 4 ] || { echo "status $status: $stderr"; false; }
  [ "${#stderr_lines[@]}" -eq 1 ] || { echo "$stderr"; false; }
  [ "${stderr_lines[0]}" = "trellis attach: refused (owner-record-invalid): $owner_dir" ]
}

@test "the canonical form of the filesystem root is the root" {
  run bash -c '. "$1"; for p in / // /./ /.. /tmp/../; do _attachment_orphan_canonical "$p"; done' _ "$ATTACH"
  [ "$status" -eq 0 ]
  [ "$output" = $'/\n/\n/\n/\n/' ] || { echo "$output"; false; }
}
