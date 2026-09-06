#!/usr/bin/env bats
# Tests for scripts/seed-inheritance-symlinks.sh
#
# FULLY ISOLATED — every test builds its own fixture in a mktemp dir.
# No absolute paths are hardcoded; all paths derived from $BATS_TEST_DIRNAME.
#
# Fixture layout:
#   $SANDBOX/root/         — fake TRELLIS_ROOT with core-rules/
#   $SANDBOX/main/         — fake MAIN git checkout with inheritance symlinks
#                            (.claude/ and .agents/ surfaces)
#   $SANDBOX/wt/           — fake linked worktree (via git worktree add)

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/seed-inheritance-symlinks.sh"
load helpers/t14-worktree

setup() {
  SANDBOX="$(mktemp -d)"
  # Resolve through real path so /var vs /private/var cannot diverge
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"

  ROOT="$SANDBOX/root"
  MAIN="$SANDBOX/main"
  WT="$SANDBOX/wt"

  # ---- Build fake TRELLIS_ROOT ----
  mkdir -p \
    "$ROOT/core-rules/skills/process-gate" \
    "$ROOT/core-rules/skills/security-gate" \
    "$ROOT/core-rules/agents" \
    "$ROOT/core-rules/commands"
  printf '# Trellis rules\n' > "$ROOT/core-rules/CLAUDE.md"
  printf 'x\n' > "$ROOT/core-rules/skills/process-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/skills/security-gate/SKILL.md"
  printf 'x\n' > "$ROOT/core-rules/agents/verify-agent.md"
  printf 'x\n' > "$ROOT/core-rules/commands/primer.md"

  # ---- Build fake MAIN checkout ----
  mkdir -p "$MAIN"
  (
    cd "$MAIN"
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"
    git config commit.gpgsign false

    # .gitignore — ignore the inheritance symlink directories.
    printf '.claude/rules\n.claude/skills\n.claude/commands\n.claude/agents\n.agents/rules\n.agents/skills\n' > .gitignore

    # Tracked files so git worktree add works and the worktree gets its own
    # CLAUDE.md.
    printf 'tracked\n' > README.md
    printf '# project overlay\n' > CLAUDE.md
    git add README.md CLAUDE.md .gitignore
    git commit -q -m "init"
  )

  # Create inheritance symlinks in MAIN
  mkdir -p \
    "$MAIN/.claude/rules" \
    "$MAIN/.claude/skills" \
    "$MAIN/.claude/commands" \
    "$MAIN/.claude/agents"
  ln -s "$ROOT/core-rules/CLAUDE.md"              "$MAIN/.claude/rules/trellis.md"
  ln -s "$ROOT/core-rules/skills/process-gate"    "$MAIN/.claude/skills/process-gate"
  ln -s "$ROOT/core-rules/skills/security-gate"   "$MAIN/.claude/skills/security-gate"
  ln -s "$ROOT/core-rules/commands/primer.md"     "$MAIN/.claude/commands/primer.md"
  ln -s "$ROOT/core-rules/agents/verify-agent.md" "$MAIN/.claude/agents/verify-agent.md"

  # Non-inheritance symlink that must NOT be mirrored
  ln -s "/tmp" "$MAIN/.claude/other"

  # Create the linked worktree
  git -C "$MAIN" worktree add --detach "$WT" >/dev/null 2>&1
}

teardown() {
  if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ]; then
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
  t14_teardown_sandbox
}

# ---------------------------------------------------------------------------
# Cutover (v1.0.0-rc.25): legacy direct-link mirroring is REMOVED.
#
# These four cases replace the thirteen that exercised the mirror writer. They
# pin the contract that replaced it: both spellings that selected the mirror
# (`--legacy-mirror` and `--root`) refuse with the usage class, name the
# migration, and — the part that actually matters — leave the worktree exactly
# as they found it. The fixture below is the same one the mirror tests used, so
# a regression that re-seeded links would be visible here immediately.
#
# The reconciliation path that replaced the mirror is covered by the T14 cases
# further down ("unregistered clone remains inert" onward), which drive the
# unflagged command against real local registry state.
# ---------------------------------------------------------------------------

worktree_surface_snapshot() {
  # Every path the mirror used to create, plus its link target when present.
  local target="$1" path
  for path in \
    .claude/rules/trellis.md .claude/skills/process-gate \
    .claude/skills/security-gate .claude/commands/primer.md \
    .claude/agents/verify-agent.md .claude/other; do
    if [ -L "$target/$path" ]; then
      printf '%s\tlink\t%s\n' "$path" "$(readlink "$target/$path")"
    elif [ -e "$target/$path" ]; then
      printf '%s\tpresent\n' "$path"
    else
      printf '%s\tabsent\n' "$path"
    fi
  done
}

@test "--legacy-mirror refuses with exit 2 and seeds nothing" {
  local before after
  before="$(worktree_surface_snapshot "$WT")"

  run bash "$SCRIPT" --legacy-mirror --target "$WT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis migrate --prepare"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach --fleet"* ]] || { echo "$output"; false; }

  after="$(worktree_surface_snapshot "$WT")"
  [ "$before" = "$after" ]
  [ ! -L "$WT/.claude/rules/trellis.md" ]
  [ ! -e "$WT/.claude/rules/trellis.md" ]
}

@test "--root is the mirror's other spelling and refuses identically" {
  local before after
  before="$(worktree_surface_snapshot "$WT")"

  run bash "$SCRIPT" --target "$WT" --root "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }

  after="$(worktree_surface_snapshot "$WT")"
  [ "$before" = "$after" ]
  [ ! -L "$WT/.claude/skills/process-gate" ]
}

@test "--root=DIR refuses before consuming a value" {
  run bash "$SCRIPT" --target "$WT" --root="$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--root"* ]] || { echo "$output"; false; }
  [ ! -L "$WT/.claude/rules/trellis.md" ]
}

@test "--verify-only does not resurrect the mirror through a refused flag" {
  # The refusal must win over every other flag: an operator scripting the old
  # verify-the-mirror invocation gets the usage class, not a silent portable
  # verification of a different thing.
  run bash "$SCRIPT" --target "$WT" --root "$ROOT" --verify-only
  [ "$status" -eq 2 ]
  [[ "$output" == *"removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
}

@test "--help names the removal and the replacement commands" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed in v1.0.0-rc.25"* ]] || { echo "$output"; false; }
  [[ "$output" == *"--legacy-mirror"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis attach"* ]] || { echo "$output"; false; }
}

# T14 local attachment reconciliation: ordinary clones must not inherit any
# behavior merely because this script exists.
@test "unregistered clone remains inert and Git-clean" {
  t14_setup_sandbox
  t14_make_project
  before="$(git -C "$T14_PROJECT" status --porcelain)"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$T14_PROJECT"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$T14_PROJECT/.trellis/runtime" ]
  [ ! -e "$TRELLIS_HOME/registry.json" ]
  [ "$(git -C "$T14_PROJECT" status --porcelain)" = "$before" ]
}

@test "corrupt local registry fails without mutating an otherwise inert clone" {
  t14_setup_sandbox
  t14_make_project
  chmod 700 "$TRELLIS_HOME"
  printf '{not json\n' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  before="$(git -C "$T14_PROJECT" status --porcelain)"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$T14_PROJECT"

  [ "$status" -eq 4 ]
  [ ! -e "$T14_PROJECT/.trellis/runtime" ]
  [ "$(git -C "$T14_PROJECT" status --porcelain)" = "$before" ]
}

@test "verify-only catches a deleted owned attachment surface" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  rm "$T14_PROJECT/.claude/rules/trellis.md"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$T14_PROJECT" --verify-only --quiet

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing its local Trellis attachment"* ]] || { echo "$output"; false; }
  [ ! -e "$T14_PROJECT/.claude/rules/trellis.md" ]
}

@test "verify-only rejects a repointed immutable runtime anchor" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  rm "$T14_PROJECT/.trellis/runtime"
  ln -s "$T14_SANDBOX/project-controlled runtime" "$T14_PROJECT/.trellis/runtime"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$T14_PROJECT" --verify-only --quiet

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing its local Trellis attachment"* ]] || { echo "$output"; false; }
  [ "$(readlink "$T14_PROJECT/.trellis/runtime")" = "$T14_SANDBOX/project-controlled runtime" ]
}

@test "reconcile executes only the verified immutable release, never project source poison" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  linked="$T14_SANDBOX/poison-resistant linked worktree"
  marker="$T14_SANDBOX/project-source-ran"
  mkdir -p "$T14_PROJECT/scripts"
  cat > "$T14_PROJECT/scripts/attach-project.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
exit 97
EOF
  chmod +x "$T14_PROJECT/scripts/attach-project.sh"
  git -C "$T14_PROJECT" worktree add -q -b t14-source-poison "$linked"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$linked" --quiet

  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [ -L "$linked/.trellis/runtime" ]
  [ -L "$linked/.claude/rules/trellis.md" ]
  git -C "$T14_PROJECT" worktree remove --force "$linked"
}

# A registered sibling row whose recorded root exists but is not a Git worktree.
# Its stored hashes still verify, so it is an identity_error row rather than a
# merely unavailable one — exactly the shape the whole-file identity validator
# used to abort on, blocking `git worktree add` seeding for every OTHER project
# on the machine.
t14_add_broken_sibling_row() {
  local sibling="$T14_SANDBOX/broken sibling checkout" checkout_id worktree_id next
  mkdir -p "$sibling"
  checkout_id="$(t14_sha256_text "$sibling/.git")"
  worktree_id="$(t14_sha256_text "$sibling")"
  next="$T14_SANDBOX/registry.next"
  jq --arg root "$sibling" --arg common "$sibling/.git" \
    --arg checkout "$checkout_id" --arg worktree "$worktree_id" '
      .projects["personal/broken-sibling"] = {
        fleet: "personal",
        project_id: "broken-sibling",
        status: "active",
        metadata: {},
        checkouts: {
          ($checkout): {
            root: $root,
            git_common_dir: $common,
            harnesses: ["claude"],
            release: "1.2.3",
            worktrees: {($worktree): {root: $root}}
          }
        }
      }' "$TRELLIS_HOME/registry.json" > "$next" || return 1
  mv -f "$next" "$TRELLIS_HOME/registry.json" || return 1
  chmod 600 "$TRELLIS_HOME/registry.json"
}

@test "seeding a healthy worktree survives an unrelated broken registry row" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  t14_add_broken_sibling_row
  linked="$T14_SANDBOX/healthy linked worktree"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t14-healthy-sibling "$linked"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$linked" --quiet

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ -L "$linked/.trellis/runtime" ]
  [ -L "$linked/.claude/rules/trellis.md" ]
  git -C "$T14_PROJECT" worktree remove --force "$linked"
}

@test "seeding refuses when the row it binds is itself broken" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  linked="$T14_SANDBOX/own-drift linked worktree"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t14-own-drift "$linked"

  # Repoint the bound checkout row at a present directory that is not this
  # (or any) Git worktree. Only the row being bound is corrupted.
  moved="$T14_SANDBOX/moved checkout"
  mkdir -p "$moved"
  jq --arg moved "$moved" '
    .projects["personal/fixture-project"].checkouts |= with_entries(.value.root = $moved)
  ' "$TRELLIS_HOME/registry.json" > "$T14_SANDBOX/registry.next"
  mv -f "$T14_SANDBOX/registry.next" "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$linked" --quiet

  [ "$status" -eq 4 ]
  [ ! -e "$linked/.trellis/runtime" ]
  [ ! -e "$linked/.claude/rules/trellis.md" ]
  git -C "$T14_PROJECT" worktree remove --force "$linked"
}

@test "reconcile refuses a new worktree with a missing sibling donor owner" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  primary_owner="$(t14_owner_for_root "$T14_PROJECT")"
  rm "$primary_owner"
  linked="$T14_SANDBOX/missing donor linked worktree"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t14-missing-donor "$linked"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$linked" --quiet

  [ "$status" -eq 4 ]
  [ ! -e "$linked/.trellis/runtime" ]
  [ ! -e "$linked/.claude/rules/trellis.md" ]
  git -C "$T14_PROJECT" worktree remove --force "$linked"
}

@test "reconcile refuses a new worktree with a corrupt sibling donor owner" {
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  primary_owner="$(t14_owner_for_root "$T14_PROJECT")"
  printf '{broken\n' > "$primary_owner"
  chmod 600 "$primary_owner"
  linked="$T14_SANDBOX/corrupt donor linked worktree"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b t14-corrupt-donor "$linked"

  run env TRELLIS_HOME="$TRELLIS_HOME" bash "$SCRIPT" --target "$linked" --quiet

  [ "$status" -eq 4 ]
  [ ! -e "$linked/.trellis/runtime" ]
  [ ! -e "$linked/.claude/rules/trellis.md" ]
  git -C "$T14_PROJECT" worktree remove --force "$linked"
}

assert_stale_donor_binding_rejected() {
  local mutation="$1" linked barrier output_file pid rc attempt checkout worktree tmp entered
  local target_attachment="33333333-3333-4333-8333-333333333333"
  t14_setup_sandbox
  t14_make_runtime_release
  t14_make_project
  t14_attach
  [ "$?" -eq 0 ]
  linked="$T14_SANDBOX/concurrent donor $mutation worktree"
  barrier="$T14_SANDBOX/expected-binding-barrier"
  output_file="$T14_SANDBOX/reconcile.out"
  mkdir "$barrier"
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree add -q -b "t14-race-$mutation" "$linked"
  linked="$(t14_canonical_dir "$linked")"

  env TRELLIS_HOME="$TRELLIS_HOME" \
    ATTACHMENT_TEST_EXPECTED_BINDING_BARRIER_DIR="$barrier" \
    bash "$SCRIPT" --target "$linked" --quiet > "$output_file" 2>&1 &
  pid=$!
  entered=0
  for ((attempt = 0; attempt < 500; attempt++)); do
    if [ -e "$barrier/entered" ]; then
      entered=1
      break
    fi
    sleep 0.01
  done
  if [ "$entered" -ne 1 ]; then
    : > "$barrier/release"
    wait "$pid" || true
    false
  fi

  checkout="$(t14_checkout_id "$T14_PROJECT")"
  worktree="$(t14_sha256_text "$linked")"
  tmp="$TRELLIS_HOME/registry.concurrent.json"
  case "$mutation" in
    detach)
      jq '
        .projects["personal/fixture-project"].status = "detached"
      ' "$TRELLIS_HOME/registry.json" > "$tmp"
      ;;
    blacklist)
      jq '
        .projects["personal/fixture-project"].metadata.legacy =
          ((.projects["personal/fixture-project"].metadata.legacy // {}) + {blacklisted:true})
      ' "$TRELLIS_HOME/registry.json" > "$tmp"
      ;;
    adoption)
      jq --arg checkout "$checkout" '
        .projects["personal/fixture-project"].checkouts[$checkout].release = "2.0.0"
      ' "$TRELLIS_HOME/registry.json" > "$tmp"
      ;;
    target-appears)
      jq --arg checkout "$checkout" --arg worktree "$worktree" --arg root "$linked" \
        --arg attachment "$target_attachment" '
          .projects["personal/fixture-project"].checkouts[$checkout].worktrees[$worktree] =
            {root:$root,attachment_id:$attachment}
        ' "$TRELLIS_HOME/registry.json" > "$tmp"
      ;;
    *) false ;;
  esac
  chmod 600 "$tmp"
  mv "$tmp" "$TRELLIS_HOME/registry.json"
  : > "$barrier/release"
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -eq 3 ]
  [[ "$(cat "$output_file")" == *"expected repair target or donor binding"* ]] || { cat "$output_file"; false; }
  [ ! -e "$linked/.trellis/runtime" ]
  [ ! -e "$linked/.claude/rules/trellis.md" ]
  git -C "$T14_PROJECT" -c core.hooksPath=/dev/null worktree remove --force "$linked"
}

@test "reconcile rejects concurrent donor detach after its snapshot" {
  assert_stale_donor_binding_rejected detach
}

@test "reconcile rejects concurrent donor blacklist after its snapshot" {
  assert_stale_donor_binding_rejected blacklist
}

@test "reconcile rejects concurrent release adoption after its snapshot" {
  assert_stale_donor_binding_rejected adoption
}

@test "reconcile rejects an attached target that appears after its snapshot" {
  assert_stale_donor_binding_rejected target-appears
}
