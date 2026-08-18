#!/usr/bin/env bats

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
MIGRATE="$REPO_ROOT/scripts/migrate-project.sh"
TRELLIS="$REPO_ROOT/scripts/trellis"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# BSD and GNU stat are probed in SEPARATE captures: GNU `stat -f` is
# --file-system and prints a filesystem block before failing, which a chained
# substitution would concatenate onto the mode.
file_mode() {
  local candidate
  candidate="$(stat -f '%Lp' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

# Emit regular-file bytes, link targets, and directories below a project. The
# Git administrative directory is deliberately excluded: HEAD and index have
# their own exact assertions, while this catches every observable project edit.
project_tree_state() {
  local root="$1" path rel
  while IFS= read -r path; do
    rel="${path#"$root"}"
    [ -n "$rel" ] || rel="."
    if [ -L "$path" ]; then
      printf 'L %s -> %s\n' "$rel" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'F %s %s\n' "$rel" "$(sha256_file "$path")"
    elif [ -d "$path" ]; then
      printf 'D %s\n' "$rel"
    fi
  done < <(LC_ALL=C find "$root" -path "$root/.git" -prune -o -print | LC_ALL=C sort)
}

# Exact rollback is concerned with bytes and link targets. Empty parent
# directories are implementation detail, so they do not hide a file/link
# restoration failure in the rollback oracle.
project_content_state() {
  local root="$1" path rel
  while IFS= read -r path; do
    rel="${path#"$root"}"
    if [ -L "$path" ]; then
      printf 'L %s -> %s\n' "$rel" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'F %s %s\n' "$rel" "$(sha256_file "$path")"
    fi
  done < <(LC_ALL=C find "$root" -path "$root/.git" -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort)
}

snapshot_from_output() {
  printf '%s\n' "$1" | awk '/^snapshot: / { sub(/^snapshot: /, ""); print; exit }'
}

assert_git_metadata_unchanged() {
  local expected_head="$1" expected_index="$2"
  [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$expected_head" ]
  [ "$(git -C "$PROJECT" write-tree)" = "$expected_index" ]
  git -C "$PROJECT" diff --cached --quiet
}

assert_portable_manifest() {
  jq -e --arg project_id "$PROJECT_ID" '
    .schema_version == 1
    and .project_id == $project_id
    and .presets == ["web-app", "api"]
    and .autonomy == 4
    and .package_manager == "pnpm"
    and .loop_safety == {
      max_iterations: 70,
      no_progress_iterations: 4,
      budget_ceiling_usd: 50,
      usd_per_mtok: 12.5,
      codex_usd_per_mtok: 8
    }
    and .mandatory_pipeline == {
      enabled: true,
      spec_required_diff_lines: 90,
      surgical_max_diff_lines: 180
    }
    and .gate_profiles == {web: {required: true}}
    and ((keys - [
      "$schema", "schema_version", "project_id", "presets", "autonomy",
      "package_manager", "loop_safety", "mandatory_pipeline", "gate_profiles"
    ]) | length == 0)
    and ((has("$schema") | not) or ."$schema" == "https://trellis.local/schemas/trellis.project.schema.json")
  ' "$PROJECT/.trellis.json"
  [ "$(grep -cF "$SANDBOX" "$PROJECT/.trellis.json")" -eq 0 ] || { cat "$PROJECT/.trellis.json"; false; }
}

assert_exact_legacy_cleanup() {
  [ -f "$PROJECT/.trellis.json" ]
  [ ! -e "$PROJECT/.trellis.config.json" ]
  [ ! -L "$PROJECT/.trellis.config.json" ]

  for path in \
    "$PROJECT/.claude/rules/trellis.md" \
    "$PROJECT/.agents/rules/trellis.md" \
    "$PROJECT/.omp/skills"; do
    [ ! -e "$path" ]
    [ ! -L "$path" ]
  done

  grep -Fx '# Project instructions remain.' "$PROJECT/CLAUDE.md"
  grep -Fx 'Project-owned closing instruction.' "$PROJECT/CLAUDE.md"
  [ "$(grep -cF "$CANONICAL/core-rules/CLAUDE.md" "$PROJECT/CLAUDE.md")" -eq 0 ] || { cat "$PROJECT/CLAUDE.md"; false; }

  grep -Fx 'vendor/' "$PROJECT/.gitignore"
  grep -Fx 'build/' "$PROJECT/.gitignore"
  [ "$(grep -cF 'Trellis inheritance symlinks' "$PROJECT/.gitignore")" -eq 0 ] || { cat "$PROJECT/.gitignore"; false; }
  [ "$(grep -cF 'Trellis local runtime state' "$PROJECT/.gitignore")" -eq 0 ] || { cat "$PROJECT/.gitignore"; false; }
  [ "$(grep -cF "$CANONICAL" "$PROJECT/.gitignore")" -eq 0 ] || { cat "$PROJECT/.gitignore"; false; }
}

write_portable_legacy_config() {
  cat > "$PROJECT/.trellis.config.json" <<'JSON'
{
  "presets": ["web-app", "api"],
  "autonomy": 4,
  "package_manager": "pnpm",
  "loop_safety": {
    "max_iterations": 70,
    "no_progress_iterations": 4,
    "budget_ceiling_usd": 50,
    "usd_per_mtok": 12.5,
    "codex_usd_per_mtok": 8
  },
  "mandatory_pipeline": {
    "enabled": true,
    "spec_required_diff_lines": 90,
    "surgical_max_diff_lines": 180
  },
  "gate_profiles": {
    "web": {"required": true}
  }
}
JSON
}

prepare_exact_legacy_project() {
  mkdir -p \
    "$PROJECT/.claude/rules" \
    "$PROJECT/.agents/rules" \
    "$PROJECT/.omp"

  ln -s "$CANONICAL/core-rules/CLAUDE.md" \
    "$PROJECT/.claude/rules/trellis.md"
  ln -s "$CANONICAL/core-rules/CLAUDE.md" \
    "$PROJECT/.agents/rules/trellis.md"
  ln -s "$CANONICAL/core-rules/skills" "$PROJECT/.omp/skills"

  cat > "$PROJECT/CLAUDE.md" <<EOF
# Project instructions remain.
@$CANONICAL/core-rules/CLAUDE.md
Project-owned closing instruction.
EOF

  cat > "$PROJECT/.gitignore" <<EOF
vendor/
# --- Trellis inheritance symlinks (per-machine; regenerated by onboard-project.sh) ---
# Generated local Trellis state.
.claude/rules/trellis.md
.agents/rules/trellis.md
.omp/skills

# --- Trellis local runtime state ---
/context-log.md
# --- end Trellis local runtime state ---
# --- end Trellis fragment ---
build/
EOF

  write_portable_legacy_config
  git -C "$PROJECT" add -A
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm 'legacy Trellis layout'
}

run_prepare() {
  run env HOME="$HOME_DIR" TRELLIS_HOME="$TRELLIS_HOME" \
    bash "$MIGRATE" --prepare --home "$TRELLIS_HOME" \
    --project-id "$PROJECT_ID" --legacy-root "$CANONICAL" "$PROJECT"
}

run_rollback() {
  local snapshot="$1"
  run env HOME="$HOME_DIR" TRELLIS_HOME="$TRELLIS_HOME" \
    bash "$MIGRATE" --rollback "$snapshot"
}

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/migrate-local-fleets.XXXXXX")"
  SANDBOX="$(CDPATH= cd "$SANDBOX" && pwd -P)"
  HOME_DIR="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis home"
  PROJECT="$SANDBOX/project with spaces"
  PROJECT_ID="portable-project"
  CANONICAL="$SANDBOX/legacy machine/trellis-instance"

  mkdir -p "$HOME_DIR" "$PROJECT" \
    "$CANONICAL/core-rules/skills"
  printf '# canonical Trellis rules\n' > "$CANONICAL/core-rules/CLAUDE.md"
  printf '# canonical skill\n' > "$CANONICAL/core-rules/skills/SKILL.md"

  git init -q "$PROJECT"
  git -C "$PROJECT" config user.name fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  printf 'fixture project\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" commit -qm initial
}

teardown() {
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

@test "dispatcher forwards migrate argv verbatim and preserves engine status" {
  local bin argv
  bin="$SANDBOX/dispatcher bin"
  argv="$SANDBOX/migrate.argv"
  mkdir -p "$bin"
  cp "$TRELLIS" "$bin/trellis"
  cat > "$bin/migrate-project.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MIGRATE_ARGV"
exit "${MIGRATE_EXIT:-0}"
EOF
  chmod +x "$bin/trellis" "$bin/migrate-project.sh"

  run env MIGRATE_ARGV="$argv" MIGRATE_EXIT=5 "$bin/trellis" migrate \
    --prepare --home "$TRELLIS_HOME" --project-id "$PROJECT_ID" "$PROJECT"

  [ "$status" -eq 5 ]
  [ "$(sed -n '1p' "$argv")" = '--prepare' ]
  [ "$(sed -n '2p' "$argv")" = '--home' ]
  [ "$(sed -n '3p' "$argv")" = "$TRELLIS_HOME" ]
  [ "$(sed -n '4p' "$argv")" = '--project-id' ]
  [ "$(sed -n '5p' "$argv")" = "$PROJECT_ID" ]
  [ "$(sed -n '6p' "$argv")" = "$PROJECT" ]
}

@test "migration CLI rejects incomplete prepare and rollback calls with usage status" {
  run env HOME="$HOME_DIR" TRELLIS_HOME="$TRELLIS_HOME" \
    bash "$MIGRATE" --prepare --home "$TRELLIS_HOME" --project-id "$PROJECT_ID"
  [ "$status" -eq 2 ]
  [ ! -e "$PROJECT/.trellis.json" ]

  run env HOME="$HOME_DIR" TRELLIS_HOME="$TRELLIS_HOME" \
    bash "$MIGRATE" --rollback
  [ "$status" -eq 2 ]
  [ ! -e "$PROJECT/.trellis.json" ]
}

@test "prepare removes exact legacy ownership, carries portable fields, and never stages or commits" {
  local head index
  prepare_exact_legacy_project
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"snapshot:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"rollback:"* ]] || { echo "$output"; false; }
  assert_exact_legacy_cleanup
  assert_portable_manifest
  assert_git_metadata_unchanged "$head" "$index"
}

@test "forbidden machine fields fail before every project write" {
  local before head index
  prepare_exact_legacy_project
  jq '.trellis_root = "/Users/example/trellis-instance" | .fleet = "personal" | .installed_release = "9.9.9"' \
    "$PROJECT/.trellis.config.json" > "$PROJECT/.trellis.config.json.tmp"
  mv "$PROJECT/.trellis.config.json.tmp" "$PROJECT/.trellis.config.json"
  before="$(project_tree_state "$PROJECT")"
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ ! -e "$PROJECT/.trellis.json" ]
  assert_git_metadata_unchanged "$head" "$index"
}

@test "a divergent legacy candidate preserves every project byte and link" {
  local before head index
  prepare_exact_legacy_project
  rm "$PROJECT/.claude/rules/trellis.md"
  printf 'project-owned rule; never delete\n' > "$PROJECT/.claude/rules/trellis.md"
  before="$(project_tree_state "$PROJECT")"
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ "$(cat "$PROJECT/.claude/rules/trellis.md")" = 'project-owned rule; never delete' ]
  [ ! -e "$PROJECT/.trellis.json" ]
  assert_git_metadata_unchanged "$head" "$index"
}

commit_project_fixture() {
  git -C "$PROJECT" add -A
  git -C "$PROJECT" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm "$1"
}

@test "authored AGENTS.md files survive prepare and never enter the snapshot plan" {
  local head index snapshot agents_before omp_before
  prepare_exact_legacy_project
  cat > "$PROJECT/AGENTS.md" <<'EOF'
# Project directives

Authored by the project owner; never Trellis output.
EOF
  printf '# authored OMP directives\n' > "$PROJECT/.omp/AGENTS.md"
  agents_before="$(sha256_file "$PROJECT/AGENTS.md")"
  omp_before="$(sha256_file "$PROJECT/.omp/AGENTS.md")"
  commit_project_fixture 'authored harness directives'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT/AGENTS.md" ] && [ ! -L "$PROJECT/AGENTS.md" ]
  [ -f "$PROJECT/.omp/AGENTS.md" ] && [ ! -L "$PROJECT/.omp/AGENTS.md" ]
  [ "$(sha256_file "$PROJECT/AGENTS.md")" = "$agents_before" ]
  [ "$(sha256_file "$PROJECT/.omp/AGENTS.md")" = "$omp_before" ]
  [[ "$output" == *"left in place, ownership not provable: AGENTS.md"* ]] || { echo "$output"; false; }
  [[ "$output" == *"left in place, ownership not provable: .omp/AGENTS.md"* ]] || { echo "$output"; false; }
  snapshot="$(snapshot_from_output "$output")"
  [ -n "$snapshot" ]
  ! jq -e '[.entries[].path] | any(. == "AGENTS.md" or . == ".omp/AGENTS.md")' \
    "$snapshot/manifest.json" >/dev/null
  assert_exact_legacy_cleanup
  assert_portable_manifest
  assert_git_metadata_unchanged "$head" "$index"
}

# The removal rule is asymmetric by leaf: root AGENTS.md may only ever be a copy
# of the project's own CLAUDE.md, exactly as its static link rule allows. A copy
# of the canonical parent rules is an ownership claim migration cannot honour.
@test "a root AGENTS.md copying the canonical parent rules is preserved and named" {
  local head index snapshot before
  prepare_exact_legacy_project
  cp "$CANONICAL/core-rules/CLAUDE.md" "$PROJECT/AGENTS.md"
  before="$(sha256_file "$PROJECT/AGENTS.md")"
  commit_project_fixture 'root AGENTS.md copied from the parent rules'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT/AGENTS.md" ] && [ ! -L "$PROJECT/AGENTS.md" ]
  [ "$(sha256_file "$PROJECT/AGENTS.md")" = "$before" ]
  [[ "$output" == *"left in place, ownership not provable: AGENTS.md"* ]] || { echo "$output"; false; }
  snapshot="$(snapshot_from_output "$output")"
  [ -n "$snapshot" ]
  ! jq -e '[.entries[].path] | any(. == "AGENTS.md")' "$snapshot/manifest.json" >/dev/null
  assert_exact_legacy_cleanup
  assert_git_metadata_unchanged "$head" "$index"
}

# Byte-equality against the compared roots decays: rules output materialized by
# some third release matches neither, so it is left in place. The left-alone
# path must still be named, or stale generated rules become an invisible no-op.
@test "an .omp/AGENTS.md from an uncompared release is left in place and named" {
  local head index before
  prepare_exact_legacy_project
  printf '# canonical Trellis rules (earlier release vintage)\n' > "$PROJECT/.omp/AGENTS.md"
  before="$(sha256_file "$PROJECT/.omp/AGENTS.md")"
  commit_project_fixture 'stale generated OMP context leaf'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$PROJECT/.omp/AGENTS.md" ] && [ ! -L "$PROJECT/.omp/AGENTS.md" ]
  [ "$(sha256_file "$PROJECT/.omp/AGENTS.md")" = "$before" ]
  [[ "$output" == *"left in place, ownership not provable: .omp/AGENTS.md"* ]] || { echo "$output"; false; }
  assert_exact_legacy_cleanup
  assert_git_metadata_unchanged "$head" "$index"
}

@test "AGENTS.md copies of project and legacy rules are still removed" {
  local head index
  prepare_exact_legacy_project
  cp "$PROJECT/CLAUDE.md" "$PROJECT/AGENTS.md"
  cp "$CANONICAL/core-rules/CLAUDE.md" "$PROJECT/.omp/AGENTS.md"
  commit_project_fixture 'materialized rule copies'
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$PROJECT/AGENTS.md" ]
  [ ! -L "$PROJECT/AGENTS.md" ]
  [ ! -e "$PROJECT/.omp/AGENTS.md" ]
  [ ! -L "$PROJECT/.omp/AGENTS.md" ]
  assert_exact_legacy_cleanup
  assert_git_metadata_unchanged "$head" "$index"
}

@test "an ambiguous AGENTS.md symlink still conflicts without writes" {
  local before custom
  prepare_exact_legacy_project
  custom="$SANDBOX/custom-agents"
  mkdir -p "$custom"
  printf '# unrelated rules\n' > "$custom/CLAUDE.md"
  ln -s "$custom/CLAUDE.md" "$PROJECT/AGENTS.md"
  before="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ "$(readlink "$PROJECT/AGENTS.md")" = "$custom/CLAUDE.md" ]
  [ ! -e "$PROJECT/.trellis.json" ]
}

@test "owned AGENTS.md symlinks are still removed" {
  prepare_exact_legacy_project
  ln -s "$PROJECT/CLAUDE.md" "$PROJECT/AGENTS.md"
  ln -s "$CANONICAL/core-rules/CLAUDE.md" "$PROJECT/.omp/AGENTS.md"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$PROJECT/AGENTS.md" ]
  [ ! -L "$PROJECT/AGENTS.md" ]
  [ ! -e "$PROJECT/.omp/AGENTS.md" ]
  [ ! -L "$PROJECT/.omp/AGENTS.md" ]
  assert_exact_legacy_cleanup
}

@test "prepare uses private snapshot storage under the requested home and is byte-idempotent" {
  local first_state head index snapshot
  prepare_exact_legacy_project
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  snapshot="$(snapshot_from_output "$output")"
  [ -n "$snapshot" ]
  case "$snapshot" in "$TRELLIS_HOME"/*) ;; *) false ;; esac
  [ -d "$TRELLIS_HOME" ]
  [ "$(file_mode "$TRELLIS_HOME")" = '700' ]
  [ -d "$snapshot" ]
  [ "$(file_mode "$snapshot")" = '700' ]
  first_state="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"snapshot:"* ]] || { echo "$output"; false; }
  [[ "$output" == *"rollback:"* ]] || { echo "$output"; false; }
  [ "$(project_tree_state "$PROJECT")" = "$first_state" ]
  assert_git_metadata_unchanged "$head" "$index"
}

@test "rollback restores exact file bytes, link targets, and absent manifest" {
  local before head index snapshot
  prepare_exact_legacy_project
  before="$(project_content_state "$PROJECT")"
  head="$(git -C "$PROJECT" rev-parse HEAD)"
  index="$(git -C "$PROJECT" write-tree)"
  [ ! -e "$PROJECT/.trellis.json" ]
  [ ! -L "$PROJECT/.trellis.json" ]

  run_prepare
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  snapshot="$(snapshot_from_output "$output")"
  [ -n "$snapshot" ]

  run_rollback "$snapshot"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(project_content_state "$PROJECT")" = "$before" ]
  [ ! -e "$PROJECT/.trellis.json" ]
  [ ! -L "$PROJECT/.trellis.json" ]
  [ "$(readlink "$PROJECT/.claude/rules/trellis.md")" = "$CANONICAL/core-rules/CLAUDE.md" ]
  [ "$(readlink "$PROJECT/.agents/rules/trellis.md")" = "$CANONICAL/core-rules/CLAUDE.md" ]
  [ "$(readlink "$PROJECT/.omp/skills")" = "$CANONICAL/core-rules/skills" ]
  assert_git_metadata_unchanged "$head" "$index"
}

@test "prepare rejects a Trellis home inside the project before creating it" {
  local before
  prepare_exact_legacy_project
  TRELLIS_HOME="$PROJECT/local Trellis state"
  before="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ ! -e "$TRELLIS_HOME" ]
}

@test "symlinked legacy parents fail before project or external mutation" {
  local before outside_before
  prepare_exact_legacy_project
  mv "$PROJECT/.claude" "$SANDBOX/outside-claude"
  ln -s "$SANDBOX/outside-claude" "$PROJECT/.claude"
  before="$(project_tree_state "$PROJECT")"
  outside_before="$(project_content_state "$SANDBOX/outside-claude")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ "$(project_content_state "$SANDBOX/outside-claude")" = "$outside_before" ]
  [ ! -e "$PROJECT/.trellis.json" ]
}

add_generated_ignore_path() {
  local rel="$1" tmp="$PROJECT/.gitignore.migrate.$$"
  awk -v rel="$rel" '
    $0 == "# --- end Trellis fragment ---" { print rel }
    { print }
  ' "$PROJECT/.gitignore" > "$tmp" && mv "$tmp" "$PROJECT/.gitignore"
}

@test "prepare removes exact generated Claude and Codex skill command and preset links" {
  local rel
  prepare_exact_legacy_project
  mkdir -p \
    "$CANONICAL/core-rules/skills/process-gate" \
    "$CANONICAL/core-rules/skills/security-gate" \
    "$CANONICAL/core-rules/commands" \
    "$CANONICAL/core-rules/presets" \
    "$PROJECT/.claude/skills" \
    "$PROJECT/.agents/skills" \
    "$PROJECT/.claude/commands" \
    "$PROJECT/.agents/commands"
  printf '# skill\n' > "$CANONICAL/core-rules/skills/process-gate/SKILL.md"
  printf '# skill\n' > "$CANONICAL/core-rules/skills/security-gate/SKILL.md"
  printf '# command\n' > "$CANONICAL/core-rules/commands/primer.md"
  printf '# command\n' > "$CANONICAL/core-rules/commands/explore.md"
  printf '# preset\n' > "$CANONICAL/core-rules/presets/web-app.md"
  printf '# preset\n' > "$CANONICAL/core-rules/presets/api.md"
  ln -s "$CANONICAL/core-rules/skills/process-gate" "$PROJECT/.claude/skills/process-gate"
  ln -s "$CANONICAL/core-rules/skills/security-gate" "$PROJECT/.agents/skills/security-gate"
  ln -s "$CANONICAL/core-rules/commands/primer.md" "$PROJECT/.claude/commands/primer.md"
  ln -s "$CANONICAL/core-rules/commands/explore.md" "$PROJECT/.agents/commands/explore.md"
  ln -s "$CANONICAL/core-rules/presets/web-app.md" "$PROJECT/.claude/rules/preset-web-app.md"
  ln -s "$CANONICAL/core-rules/presets/api.md" "$PROJECT/.agents/rules/preset-api.md"
  for rel in \
    .claude/skills/process-gate \
    .agents/skills/security-gate \
    .claude/commands/primer.md \
    .agents/commands/explore.md \
    .claude/rules/preset-web-app.md \
    .agents/rules/preset-api.md; do
    add_generated_ignore_path "$rel"
  done

  run_prepare

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for rel in \
    .claude/skills/process-gate \
    .agents/skills/security-gate \
    .claude/commands/primer.md \
    .agents/commands/explore.md \
    .claude/rules/preset-web-app.md \
    .agents/rules/preset-api.md; do
    [ ! -e "$PROJECT/$rel" ]
    [ ! -L "$PROJECT/$rel" ]
  done
}

@test "unlisted generated family symlink conflicts without writes" {
  local before
  prepare_exact_legacy_project
  mkdir -p "$CANONICAL/core-rules/skills/process-gate" "$PROJECT/.claude/skills"
  printf '# skill\n' > "$CANONICAL/core-rules/skills/process-gate/SKILL.md"
  ln -s "$CANONICAL/core-rules/skills/process-gate" "$PROJECT/.claude/skills/process-gate"
  before="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ -L "$PROJECT/.claude/skills/process-gate" ]
  [ ! -e "$PROJECT/.trellis.json" ]
}

@test "custom core-rules suffix candidate conflicts without writes" {
  local before custom
  prepare_exact_legacy_project
  custom="$SANDBOX/custom-core-rules"
  mkdir -p "$custom"
  printf '# project-owned rules\n' > "$custom/CLAUDE.md"
  rm "$PROJECT/.claude/rules/trellis.md"
  ln -s "$custom/CLAUDE.md" "$PROJECT/.claude/rules/trellis.md"
  before="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ "$(readlink "$PROJECT/.claude/rules/trellis.md")" = "$custom/CLAUDE.md" ]
  [ ! -e "$PROJECT/.trellis.json" ]
}

@test "ambiguous absolute CLAUDE import conflicts without writes" {
  local before custom
  prepare_exact_legacy_project
  custom="$SANDBOX/custom-core-rules"
  mkdir -p "$custom"
  printf '# project-owned rules\n' > "$custom/CLAUDE.md"
  cat > "$PROJECT/CLAUDE.md" <<EOF
# Project instructions remain.
@$custom/CLAUDE.md
Project-owned closing instruction.
EOF
  before="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ ! -e "$PROJECT/.trellis.json" ]
}

@test "nested gate profile machine paths fail before every project write" {
  local before
  prepare_exact_legacy_project
  jq '.gate_profiles.web.nested = {path: "/Users/example/secret"}' \
    "$PROJECT/.trellis.config.json" > "$PROJECT/.trellis.config.json.tmp"
  mv "$PROJECT/.trellis.config.json.tmp" "$PROJECT/.trellis.config.json"
  before="$(project_tree_state "$PROJECT")"

  run_prepare

  [ "$status" -eq 3 ]
  [ "$(project_tree_state "$PROJECT")" = "$before" ]
  [ ! -e "$PROJECT/.trellis.json" ]
}
