#!/usr/bin/env bats
# Spec 069 lane DW: the janitor's dehydrate action (D1), the orphans scope (D5)
# and the Claude Code `cc-*` sweep (A7), from scripts/lib/disk-janitor-dehydrate.sh.
#
# Safety is the point of these cases, so every rule is checked both ways: a
# fixture where the rule holds and the path goes, and the same fixture with the
# rule inverted where the path stays. The filesystem is the verification:
# survivors are asserted with `[ -e ]`, removals with `[ ! -e ]`.
#
# Hermetic: HOME, TRELLIS_HOME, the worktree root and every repository live in
# a fresh sandbox under BATS_TEST_TMPDIR. Merge checks use DJ_MERGED_OVERRIDE.
# Idle time is git activity, so fixtures backdate the per-worktree HEAD, index
# and logs/HEAD; nothing here runs `git status` on a backdated tree without
# GIT_OPTIONAL_LOCKS=0, which would refresh the index and reset the clock.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"
OLD_STAMP="202001010000"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-dehydrate.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  OUTSIDE="$SANDBOX/outside"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$CANON/audits" "$PROJECTS" "$OUTSIDE"
  chmod 700 "$TRELLIS_HOME"
  export HOME TRELLIS_HOME
  export TRELLIS_WORKTREE_ROOT="$HOME/projects/worktrees"
  export GIT_CONFIG_NOSYSTEM=1
  unset TRELLIS_CONFIG_PATH
  write_config '{}'
}

teardown() {
  if [ -n "${LIVE_PID:-}" ]; then
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -e "$SANDBOX" ]; then
    chmod -R u+rwX "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

# write_config DISK_JANITOR_JSON [WORKTREES_JSON] — portable policy, machine
# home and an empty registry.
write_config() {
  jq -n --argjson dj "$1" --argjson wt "${2:-{\}}" \
    '{schema_version: 2, maintainer_name: "T", github_user: "t", harnesses: ["claude"],
      disk_janitor: $dj, worktrees: $wt}' > "$CANON/trellis.config.json"
  cat > "$TRELLIS_HOME/config.json" <<JSON
{"schema_version":1,"source_root":"$CANON","release_remote":"https://example.invalid/t.git","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$PROJECTS"]}}}
JSON
  chmod 600 "$TRELLIS_HOME/config.json"
  [ -f "$TRELLIS_HOME/registry.json" ] ||
    printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

register() {
  bash -c '
    . "$1/scripts/lib/trellis-home.sh"
    . "$1/scripts/lib/local-registry.sh"
    local_registry_register_worktree "$2" personal "$3" "$4" 1.2.3 "[\"claude\"]" ""
  ' _ "$REPO_ROOT" "$TRELLIS_HOME" "$2" "$1" >/dev/null
}

run_dj() {
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash "$DJ" "$@" </dev/null
}

# A JS project: package.json, a tracked lockfile and the usual ignores.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
  printf '{"name":"fixture"}\n' > "$dir/package.json"
  printf 'lockfileVersion: 9\n' > "$dir/pnpm-lock.yaml"
  printf 'node_modules\n.env\ndist/\nbuild/\n*.o\n' > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
}

# add_wt REPO WT BRANCH — a linked worktree on a new branch.
add_wt() {
  mkdir -p "$(dirname "$2")"
  git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1
}

# backdate WT — move WT's git activity (HEAD, index, logs/HEAD and the
# checked-out branch ref) to 2020 so hy_last_git_activity reads idle.
backdate() {
  local gd common ref
  gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  touch -t "$OLD_STAMP" "$gd/HEAD" "$gd/index" "$gd/logs/HEAD"
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  if ref="$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null)"; then
    if [ -f "$common/$ref" ]; then
      touch -t "$OLD_STAMP" "$common/$ref"
    elif [ -f "$common/packed-refs" ]; then
      touch -t "$OLD_STAMP" "$common/packed-refs"
    fi
  fi
}

fill() {
  mkdir -p "$1"
  dd if=/dev/zero of="$1/blob" bs=1024 count=16 >/dev/null 2>&1
}

# classify TREE [SNAPSHOT] — run dj_dehydrate_classify with idle 7 days.
classify() {
  local snapshot="${2:-$SANDBOX/lsof-ok}"
  [ -n "${2:-}" ] || printf 'ok\n' > "$snapshot"
  run bash -c '
    . "$1/scripts/lib/disk-janitor-lib.sh"
    . "$1/scripts/lib/hygiene-common.sh"
    . "$1/scripts/lib/disk-janitor-dehydrate.sh"
    dj_dehydrate_classify "$2" 7 "$(date +%s)" "$3"
  ' _ "$REPO_ROOT" "$1" "$snapshot"
}

# row VERDICT PATH — the classify output holds exactly this verdict for PATH.
has_row() {
  printf '%s\n' "$output" | awk -F'\t' -v v="$1" -v p="$2" '$1==v && $3==p { f=1 } END { exit !f }'
}

idle_tree() {
  make_repo "$PROJECTS/app"
  WT="$PROJECTS/app-wt/feat"
  add_wt "$PROJECTS/app" "$WT" feat/x
  fill "$WT/node_modules/pkg"
  printf 'TOKEN=secret\n' > "$WT/.env"
  backdate "$WT"
}

# ---------------------------------------------------------------------------
# DW.1 — the D1 split
# ---------------------------------------------------------------------------

@test "classify: node_modules + .env in an idle clean tree -> node_modules delete, .env keep" {
  idle_tree
  classify "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  has_row delete "$WT/node_modules" || { echo "$output"; false; }
  has_row keep "$WT/.env" || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ] || { echo "$output"; false; }
}

@test "classify: recent git activity holds every regenerable path (inverse of the idle case)" {
  idle_tree
  git -C "$WT" commit -q --allow-empty -m touch
  classify "$WT"
  [ "$status" -eq 0 ]
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"recent git activity"* ]] || { echo "$output"; false; }
  ! has_row delete "$WT/node_modules"
}

@test "classify: idle is git activity, not directory mtime" {
  idle_tree
  # A freshly touched directory does not make an idle tree active ...
  touch "$WT" "$WT/node_modules"
  classify "$WT"
  has_row delete "$WT/node_modules" || { echo "$output"; false; }
  # ... and an ancient directory does not make an active tree idle.
  git -C "$WT" commit -q --allow-empty -m touch
  touch -t "$OLD_STAMP" "$WT" "$WT/node_modules"
  classify "$WT"
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
}

@test "classify: an untracked file holds the tree; removing it releases it" {
  idle_tree
  printf 'wip\n' > "$WT/notes.md"
  classify "$WT"
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"tracked or untracked changes"* ]] || { echo "$output"; false; }
  rm "$WT/notes.md"
  classify "$WT"
  has_row delete "$WT/node_modules" || { echo "$output"; false; }
}

@test "classify: a modified tracked file holds the tree" {
  idle_tree
  printf '{"name":"changed"}\n' > "$WT/package.json"
  classify "$WT"
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  ! has_row delete "$WT/node_modules"
}

@test "classify: a tracked build/ is kept; an untracked build/ beside package.json goes" {
  idle_tree
  mkdir -p "$WT/build"
  printf 'checked in\n' > "$WT/build/release.txt"
  git -C "$WT" add -f build/release.txt
  git -C "$WT" commit -q -m "track build"
  printf 'obj\n' > "$WT/build/tmp.o"
  backdate "$WT"
  classify "$WT"
  ! has_row delete "$WT/build"
  ! has_row hold "$WT/build"
  has_row keep "$WT/build/tmp.o" || { echo "$output"; false; }
  has_row delete "$WT/node_modules" || { echo "$output"; false; }

  # Inverse: the same directory untracked is regenerable.
  git -C "$WT" rm -q --cached build/release.txt
  git -C "$WT" commit -q -m "untrack build"
  backdate "$WT"
  classify "$WT"
  has_row delete "$WT/build" || { echo "$output"; false; }
}

@test "classify: dist without a build manifest beside it is kept; with one it goes" {
  idle_tree
  fill "$WT/tools/dist"
  fill "$WT/web/dist"
  printf '{}\n' > "$WT/web/package.json"
  git -C "$WT" add web/package.json
  git -C "$WT" commit -q -m web
  backdate "$WT"
  classify "$WT"
  has_row keep "$WT/tools/dist" || { echo "$output"; false; }
  has_row delete "$WT/web/dist" || { echo "$output"; false; }
}

@test "classify: a symlinked node_modules is a link row and its target is never walked" {
  idle_tree
  rm -rf "$WT/node_modules"
  fill "$OUTSIDE/store/node_modules/pkg"
  ln -s "$OUTSIDE/store/node_modules" "$WT/node_modules"
  classify "$WT"
  printf '%s\n' "$output" | awk -F'\t' -v p="$WT/node_modules" '$1=="delete" && $2=="link:node_modules" && $3==p { f=1 } END { exit !f }' ||
    { echo "$output"; false; }
  [[ "$output" != *"$OUTSIDE"* ]] || { echo "$output"; false; }
}

@test "classify: a live handle holds the tree (real lsof); without it the tree goes" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  idle_tree
  ( cd "$WT/node_modules" && exec sleep 300 ) &
  LIVE_PID=$!
  run bash -c '. "$1/scripts/lib/disk-janitor-lib.sh"; dj_capture_lsof_snapshot "$2" 10' _ \
    "$REPO_ROOT" "$SANDBOX/lsof-live"
  classify "$WT" "$SANDBOX/lsof-live"
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"in use"* ]] || { echo "$output"; false; }

  kill "$LIVE_PID"; wait "$LIVE_PID" 2>/dev/null || true; LIVE_PID=""
  run bash -c '. "$1/scripts/lib/disk-janitor-lib.sh"; dj_capture_lsof_snapshot "$2" 10' _ \
    "$REPO_ROOT" "$SANDBOX/lsof-idle"
  classify "$WT" "$SANDBOX/lsof-idle"
  has_row delete "$WT/node_modules" || { echo "$output"; false; }
}

@test "classify: a failed lsof snapshot holds the tree (liveness unknown)" {
  idle_tree
  printf 'error\tlsof unavailable\n' > "$SANDBOX/lsof-error"
  classify "$WT" "$SANDBOX/lsof-error"
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"liveness unknown"* ]] || { echo "$output"; false; }
}

@test "classify: no tracked lockfile holds the tree; tracking one releases it" {
  idle_tree
  git -C "$WT" rm -q pnpm-lock.yaml
  git -C "$WT" commit -q -m "drop lockfile"
  backdate "$WT"
  classify "$WT"
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"no tracked lockfile"* ]] || { echo "$output"; false; }

  mkdir -p "$WT/svc"
  printf 'version = 1\n' > "$WT/svc/uv.lock"
  git -C "$WT" add svc/uv.lock
  git -C "$WT" commit -q -m "nested lockfile"
  backdate "$WT"
  classify "$WT"
  has_row delete "$WT/node_modules" || { echo "$output"; false; }
}

@test "classify: a corrupt .git is refused, never read as clean; repaired it plans again" {
  idle_tree
  cp "$WT/.git" "$SANDBOX/dotgit"
  printf 'not a gitdir pointer\n' > "$WT/.git"
  classify "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'hold\ttree\t%s\tgit error' "$WT")" ] || { echo "$output"; false; }

  cp "$SANDBOX/dotgit" "$WT/.git"
  classify "$WT"
  has_row delete "$WT/node_modules" || { echo "$output"; false; }
}

@test "classify: every always-regenerable kind is planned, nested ones too" {
  idle_tree
  local kind
  for kind in .venv .next .turbo .mypy_cache .pytest_cache .ruff_cache; do
    fill "$WT/$kind"
  done
  fill "$WT/pkg/mod/__pycache__"
  printf '%s\n' .venv .next .turbo .mypy_cache .pytest_cache .ruff_cache __pycache__ >> "$WT/.gitignore"
  git -C "$WT" commit -q -am "ignore python caches"
  backdate "$WT"
  classify "$WT"
  for kind in .venv .next .turbo .mypy_cache .pytest_cache .ruff_cache pkg/mod/__pycache__ node_modules; do
    has_row delete "$WT/$kind" || { echo "$kind: $output"; false; }
  done
}

@test "report: an idle registered worktree reads dehydrate with a per-reason split" {
  idle_tree
  register "$PROJECTS/app" app
  register "$WT" app
  backdate "$WT"
  make_repo "$PROJECTS/busy"
  local busy="$PROJECTS/busy-wt/feat"
  add_wt "$PROJECTS/busy" "$busy" feat/y
  fill "$busy/node_modules/pkg"
  register "$PROJECTS/busy" busy
  register "$busy" busy

  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[dehydrate] $WT ("* ]] || { echo "$output"; false; }
  [[ "$output" == *"[candidate] $busy ("*"dehydrate held: recent git activity"* ]] || { echo "$output"; false; }
  [[ "$output" == *"== Dehydrate: regenerable directories"* ]] || { echo "$output"; false; }
  [[ "$output" == *"reclaimable by dehydrate: 16.0 KB"* ]] || { echo "$output"; false; }
  [[ "$output" == *"recent git activity (idle <= 7d): 16.0 KB"* ]] || { echo "$output"; false; }

  # Report and a plain --apply never delete.
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$WT/node_modules/pkg" ]
  [ -f "$WT/.env" ]
}

@test "classify: a .venv ignored only by its own inner .gitignore is one path" {
  idle_tree
  fill "$WT/.venv/lib"
  fill "$WT/.venv/bin"
  printf '*\n' > "$WT/.venv/.gitignore"
  classify "$WT"
  has_row delete "$WT/.venv" || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c "$WT/.venv")" -eq 1 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# DW.2 — dehydrate apply
# ---------------------------------------------------------------------------

# registered_idle_tree — idle_tree, registered, so the worktrees scope scans it.
registered_idle_tree() {
  idle_tree
  register "$PROJECTS/app" app
  register "$WT" app
  backdate "$WT"
}

apply_dehydrate() {
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed \
    run_dj --apply --yes --dehydrate --scopes worktrees "$@"
}

@test "apply: node_modules + .env -> only node_modules goes, the tree and .env stay" {
  registered_idle_tree
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed: $WT/node_modules"* ]] || { echo "$output"; false; }
  [ ! -e "$WT/node_modules" ]
  [ "$(cat "$WT/.env")" = "TOKEN=secret" ]
  [ -f "$WT/package.json" ] && [ -f "$WT/pnpm-lock.yaml" ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
  [[ "$output" == *"dehydrated: 16.0 KB removed"* ]] || { echo "$output"; false; }
}

@test "apply: a declined prompt removes nothing" {
  registered_idle_tree
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed \
    run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    bash -c 'printf "n\n" | bash "$1" --apply --dehydrate --scopes worktrees' _ "$DJ"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"declined"* ]] || { echo "$output"; false; }
  [ -d "$WT/node_modules/pkg" ]
}

@test "apply: tracked build/ and a manifest-less dist survive; dist beside package.json goes" {
  idle_tree
  mkdir -p "$WT/build"
  printf 'checked in\n' > "$WT/build/release.txt"
  git -C "$WT" add -f build/release.txt
  git -C "$WT" commit -q -m "track build"
  printf 'obj\n' > "$WT/build/tmp.o"
  fill "$WT/dist"
  fill "$WT/tools/dist"
  register "$PROJECTS/app" app
  register "$WT" app
  backdate "$WT"
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$WT/build/release.txt")" = "checked in" ]
  [ -f "$WT/build/tmp.o" ]
  [ -f "$WT/tools/dist/blob" ]
  [ ! -e "$WT/dist" ]
  [ ! -e "$WT/node_modules" ]
  [ -z "$(git -C "$WT" ls-files --deleted)" ]
}

@test "apply: a symlinked node_modules is unlinked and its outside target is untouched" {
  idle_tree
  rm -rf "$WT/node_modules"
  fill "$OUTSIDE/store/node_modules/pkg"
  ln -s "$OUTSIDE/store/node_modules" "$WT/node_modules"
  register "$PROJECTS/app" app
  register "$WT" app
  backdate "$WT"
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"unlinked: $WT/node_modules"* ]] || { echo "$output"; false; }
  [ ! -e "$WT/node_modules" ] && [ ! -L "$WT/node_modules" ]
  [ -f "$OUTSIDE/store/node_modules/pkg/blob" ]
}

@test "apply: a busy tree (live cwd under it) keeps everything" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  registered_idle_tree
  ( cd "$WT/node_modules/pkg" && exec sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$WT/node_modules/pkg/blob" ]
  [[ "$output" == *"in use"* ]] || { echo "$output"; false; }
}

@test "apply: a recently active tree keeps everything" {
  registered_idle_tree
  git -C "$WT" commit -q --allow-empty -m touch
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$WT/node_modules/pkg/blob" ]
}

@test "apply: a tree that changes after the plan is re-validated and kept" {
  registered_idle_tree
  mkfifo "$SANDBOX/answer"
  ( DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed \
      env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
      bash "$DJ" --apply --dehydrate --scopes worktrees <"$SANDBOX/answer" >"$SANDBOX/out" 2>&1
    echo "$?" > "$SANDBOX/rc" ) &
  exec 8>"$SANDBOX/answer"
  local tries=0
  until grep -q 'Delete these regenerable directories' "$SANDBOX/out" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 600 ] || { exec 8>&-; cat "$SANDBOX/out"; false; }
    sleep 0.2
  done
  # Between plan and confirmation the operator starts work in the tree.
  printf 'wip\n' > "$WT/notes.md"
  printf 'y\n' >&8
  exec 8>&-
  wait
  [ "$(cat "$SANDBOX/rc")" -eq 0 ] || { cat "$SANDBOX/out"; false; }
  grep -q "skipped (plan changed): $WT/node_modules — tracked or untracked changes" "$SANDBOX/out" ||
    { cat "$SANDBOX/out"; false; }
  [ -f "$WT/node_modules/pkg/blob" ]
}

@test "classify: target/ beside requirements.txt is kept; beside Cargo.toml it goes" {
  idle_tree
  mkdir -p "$WT/py" "$WT/rs"
  printf 'requests\n' > "$WT/py/requirements.txt"
  printf '[package]\n' > "$WT/rs/Cargo.toml"
  printf 'target/\n' >> "$WT/.gitignore"
  git -C "$WT" add -A py rs .gitignore
  git -C "$WT" commit -q -m "py and rust"
  fill "$WT/py/target"
  fill "$WT/rs/target"
  backdate "$WT"
  classify "$WT"
  has_row keep "$WT/py/target" || { echo "$output"; false; }
  ! has_row delete "$WT/py/target"
  has_row delete "$WT/rs/target" || { echo "$output"; false; }
}

@test "classify: a symlinked dist out of the tree is never followed or planned" {
  idle_tree
  printf 'dist\n' >> "$WT/.gitignore"
  git -C "$WT" commit -q -am "ignore a dist link"
  fill "$OUTSIDE/artifacts"
  ln -s "$OUTSIDE/artifacts" "$WT/dist"
  backdate "$WT"
  classify "$WT"
  has_row keep "$WT/dist" || { echo "$output"; false; }
  [[ "$output" != *"$OUTSIDE"* ]] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# Hostile path names: plan rows are tab-separated lines, so a name carrying a
# tab, a newline or arithmetic text must never shift a field into a number
# that bash evaluates, or forge a row.
# ---------------------------------------------------------------------------

@test "classify: an ignored path with a tab or newline holds the whole tree" {
  idle_tree
  local evil
  evil="$WT/x"$'\t''a[$(touch '"$SANDBOX"'/PWNED)]'
  fill "$evil/node_modules"
  classify "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'hold\ttree\t%s\tcontrol character in an ignored path name' "$WT")" ] ||
    { echo "$output"; false; }

  rm -rf "$evil"
  fill "$WT/y"$'\n'"dehydrate"$'\t'"delete/node_modules"
  classify "$WT"
  [ "$output" = "$(printf 'hold\ttree\t%s\tcontrol character in an ignored path name' "$WT")" ] ||
    { echo "$output"; false; }
}

@test "apply: hostile names never execute and never delete" {
  registered_idle_tree
  local evil
  evil="$WT/x"$'\t''a[$(touch '"$SANDBOX"'/PWNED)]'
  fill "$evil/node_modules"
  fill "$WT/a[\$(touch $SANDBOX/PWNED2)]/node_modules"
  backdate "$WT"
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/PWNED" ] && [ ! -e "$SANDBOX/PWNED2" ]
  [ -f "$evil/node_modules/blob" ]
  [ -f "$WT/node_modules/pkg/blob" ]
  [ -f "$WT/a[\$(touch $SANDBOX/PWNED2)]/node_modules/blob" ]
  [ -f "$WT/.env" ]
  [[ "$output" == *"control character in an ignored path name"* ]] || { echo "$output"; false; }

  # Without the tab, the arithmetic-looking name is just a name: its
  # node_modules is regenerable, and nothing it spells is ever evaluated.
  rm -rf "$evil"
  backdate "$WT"
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/PWNED" ] && [ ! -e "$SANDBOX/PWNED2" ]
  [ ! -e "$WT/a[\$(touch $SANDBOX/PWNED2)]/node_modules" ]
  [ ! -e "$WT/node_modules" ]
  [ -f "$WT/.env" ]
}

# ---------------------------------------------------------------------------
# DW.3 — the cache scope reports the D1 kinds and never deletes them
# ---------------------------------------------------------------------------

@test "caches scope: a stale node_modules is a candidate, never a cache delete" {
  registered_idle_tree
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --report --scopes caches
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[candidate] node_modules $WT/node_modules"*"reclaimed only by --dehydrate"* ]] ||
    { echo "$output"; false; }
  DJ_MERGED_OVERRIDE=unmerged DJ_PUSHED_OVERRIDE=unpushed run_dj --apply --yes --scopes caches
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$WT/node_modules/pkg/blob" ]
}

# ---------------------------------------------------------------------------
# DW.5 — orphans: worktree directories whose gitdir is gone
# ---------------------------------------------------------------------------

# orphan_tree — an idle worktree under the central root whose gitdir is then
# deleted: node_modules (ignored), .env (ignored), dist beside package.json,
# an untracked note. Sets ORPHAN.
orphan_tree() {
  make_repo "$PROJECTS/app"
  ORPHAN="$TRELLIS_WORKTREE_ROOT/_unregistered/app/feat"
  add_wt "$PROJECTS/app" "$ORPHAN" feat/o
  fill "$ORPHAN/node_modules/pkg"
  fill "$ORPHAN/dist"
  printf 'TOKEN=secret\n' > "$ORPHAN/.env"
  printf 'unsaved\n' > "$ORPHAN/notes.md"
  rm -rf "$(git -C "$ORPHAN" rev-parse --absolute-git-dir)"
  find "$ORPHAN" -exec touch -t "$OLD_STAMP" {} + 2>/dev/null || true
  touch -t "$OLD_STAMP" "$ORPHAN" "$ORPHAN/.git"
}

@test "orphans: reported with the repair route; nothing removed without --dehydrate" {
  orphan_tree
  run_dj --report --scopes orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[orphan] $ORPHAN ("*"is gone"*"trellis worktree migrate"*"never removed whole"* ]] ||
    { echo "$output"; false; }
  run_dj --apply --yes --scopes orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
}

@test "orphans --dehydrate: only ignored always-regenerable dirs go; dist, .env and work stay" {
  orphan_tree
  run_dj --apply --yes --dehydrate --scopes orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$ORPHAN/node_modules" ]
  [ -f "$ORPHAN/dist/blob" ]
  [ "$(cat "$ORPHAN/.env")" = "TOKEN=secret" ]
  [ "$(cat "$ORPHAN/notes.md")" = "unsaved" ]
  [ -f "$ORPHAN/package.json" ] && [ -f "$ORPHAN/.git" ]
}

@test "orphans --dehydrate: a node_modules its own .gitignore does not ignore is kept" {
  orphan_tree
  printf '.env\n' > "$ORPHAN/.gitignore"
  touch -t "$OLD_STAMP" "$ORPHAN"
  run_dj --apply --yes --dehydrate --scopes orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
}

@test "orphans --dehydrate: recent directory activity, no lockfile or a live handle hold it" {
  command -v lsof >/dev/null 2>&1 || skip "lsof not installed"
  orphan_tree
  touch "$ORPHAN"
  run_dj --apply --yes --dehydrate --scopes orphans
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
  [[ "$output" == *"recent activity"* ]] || { echo "$output"; false; }

  rm "$ORPHAN/pnpm-lock.yaml"
  touch -t "$OLD_STAMP" "$ORPHAN"
  run_dj --apply --yes --dehydrate --scopes orphans
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
  [[ "$output" == *"no lockfile"* ]] || { echo "$output"; false; }

  printf 'lockfileVersion: 9\n' > "$ORPHAN/pnpm-lock.yaml"
  touch -t "$OLD_STAMP" "$ORPHAN"
  ( cd "$ORPHAN/node_modules/pkg" && exec sleep 300 ) >/dev/null 2>&1 &
  LIVE_PID=$!
  run_dj --apply --yes --dehydrate --scopes orphans
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
  [[ "$output" == *"in use"* ]] || { echo "$output"; false; }
}

@test "orphans: a repaired gitdir is no longer an orphan and is not touched" {
  orphan_tree
  printf 'gitdir: %s\n' "$PROJECTS/app/.git" > "$ORPHAN/.git"
  run_dj --apply --yes --dehydrate --scopes orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"[orphan] $ORPHAN"* ]] || { echo "$output"; false; }
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
}

# ---------------------------------------------------------------------------
# DW.6 — the A7 cc-* sweep under the central root
# ---------------------------------------------------------------------------

# cc_tree — a Claude Code worktree (branch worktree-t1) of an unregistered repo,
# idle since 2020, holding only regenerable ignored content. Sets CC and MAIN.
cc_tree() {
  MAIN="$PROJECTS/app"
  make_repo "$MAIN"
  CC="$TRELLIS_WORKTREE_ROOT/_unregistered/app/cc-t1"
  add_wt "$MAIN" "$CC" worktree-t1
  fill "$CC/node_modules/pkg"
  backdate "$CC"
}

sweep() {
  DJ_MERGED_OVERRIDE="$1" run_dj --apply --yes "${@:2}" --scopes worktrees
}

@test "cc sweep: merged and clean -> worktree removed and its merged branch deleted" {
  cc_tree
  DJ_MERGED_OVERRIDE=merged run_dj --dry-run --scopes worktrees
  [[ "$output" == *"git worktree remove  $CC"*"merged"* ]] || { echo "$output"; false; }
  sweep merged
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$CC" ]
  ! git -C "$MAIN" rev-parse -q --verify refs/heads/worktree-t1
  [ -z "$(git -C "$MAIN" worktree list --porcelain | grep "$CC")" ]
}

@test "cc sweep: unmerged but no unique commits -> removed, branch kept" {
  cc_tree
  sweep unmerged
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$CC" ]
  git -C "$MAIN" rev-parse -q --verify refs/heads/worktree-t1
}

@test "cc sweep: a unique unmerged commit keeps it" {
  cc_tree
  git -C "$CC" commit -q --allow-empty -m "agent work"
  backdate "$CC"
  sweep unmerged
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$CC/node_modules/pkg" ]
  DJ_MERGED_OVERRIDE=unmerged run_dj --report --scopes worktrees
  [[ "$output" == *"$CC"*"cc sweep held: unmerged with 1 unique commit(s)"* ]] || { echo "$output"; false; }
}

@test "cc sweep: untracked work, a .env, recent activity or a lock each keep it" {
  cc_tree
  printf 'wip\n' > "$CC/notes.md"
  sweep merged
  [ -f "$CC/notes.md" ]
  rm "$CC/notes.md"

  printf 'TOKEN=secret\n' > "$CC/.env"
  sweep merged
  [ "$(cat "$CC/.env")" = "TOKEN=secret" ]
  rm "$CC/.env"

  git -C "$CC" checkout -q -b worktree-t1-tmp && git -C "$CC" checkout -q worktree-t1
  sweep merged
  [ -d "$CC" ]
  [[ "$output" != *"removed worktree"* ]] || { echo "$output"; false; }

  backdate "$CC"
  git -C "$MAIN" worktree lock "$CC"
  sweep merged
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$CC" ]
  [[ "$output" != *"removed worktree"* ]] || { echo "$output"; false; }
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [[ "$output" == *"cc sweep held: locked"* ]] || { echo "$output"; false; }
  git -C "$MAIN" worktree unlock "$CC"

  # Inverse: with every hold gone, the same tree goes.
  sweep merged
  [ ! -e "$CC" ]
}

@test "cc sweep: an attached worktree (owner record names it) is held" {
  cc_tree
  mkdir -p "$TRELLIS_HOME/state/attachments/abc"
  jq -n --arg p "$CC" '{worktree_root: $p}' > "$TRELLIS_HOME/state/attachments/abc/owner.json"
  sweep merged
  [ -d "$CC/node_modules/pkg" ]
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [[ "$output" == *"cc sweep held: attached"* ]] || { echo "$output"; false; }
}

@test "cc sweep: --safe-only needs a merged branch" {
  cc_tree
  sweep unmerged --safe-only
  [ -d "$CC" ]
  sweep merged --safe-only
  [ ! -e "$CC" ]
}

@test "cc sweep: a cc-* worktree outside the central root is never swept" {
  MAIN="$PROJECTS/app"
  make_repo "$MAIN"
  CC="$MAIN/.claude/worktrees/cc-t2"
  add_wt "$MAIN" "$CC" worktree-t2
  backdate "$CC"
  write_config '{}' "$(jq -n --arg p "$MAIN/.claude/worktrees" '{known_parents: [$p]}')"
  sweep merged
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$CC" ]
}

# ---------------------------------------------------------------------------
# Review fixes: nested git inside a candidate must hold, never delete (P1)
# ---------------------------------------------------------------------------

@test "classify: node_modules holding a nested git repo is held, never deleted" {
  idle_tree
  mkdir -p "$WT/node_modules/nested"
  git -C "$WT/node_modules/nested" init -q -b main
  git -C "$WT/node_modules/nested" config user.email t@example.com
  git -C "$WT/node_modules/nested" config user.name t
  git -C "$WT/node_modules/nested" config commit.gpgsign false
  printf 'secret\n' > "$WT/node_modules/nested/secret.txt"
  git -C "$WT/node_modules/nested" add -A
  git -C "$WT/node_modules/nested" commit -q -m nested
  backdate "$WT"
  classify "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"nested git"* ]] || { echo "$output"; false; }
  ! has_row delete "$WT/node_modules"
}

@test "classify: build holding a linked worktree is held, never deleted" {
  idle_tree
  mkdir -p "$WT/build"
  git -C "$WT" worktree add -q -b feat/nested "$WT/build/wt" >/dev/null 2>&1
  printf 'uncommitted\n' > "$WT/build/wt/work.txt"
  backdate "$WT"
  classify "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  has_row hold "$WT/build" || { echo "$output"; false; }
  [[ "$output" == *"nested git"* ]] || { echo "$output"; false; }
  ! has_row delete "$WT/build"
}

@test "apply: a candidate holding nested git is kept, its commits survive" {
  registered_idle_tree
  mkdir -p "$WT/node_modules/nested"
  git -C "$WT/node_modules/nested" init -q -b main
  git -C "$WT/node_modules/nested" config user.email t@example.com
  git -C "$WT/node_modules/nested" config user.name t
  git -C "$WT/node_modules/nested" config commit.gpgsign false
  printf 'secret\n' > "$WT/node_modules/nested/secret.txt"
  git -C "$WT/node_modules/nested" add -A
  git -C "$WT/node_modules/nested" commit -q -m nested
  backdate "$WT"
  apply_dehydrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$WT/node_modules/nested/secret.txt" ]
  [ -d "$WT/node_modules/nested/.git" ]
  [ -f "$WT/node_modules/pkg/blob" ]
}

@test "cc sweep: dirty with no ignored files is held, never swept" {
  MAIN="$PROJECTS/app"
  make_repo "$MAIN"
  CC="$TRELLIS_WORKTREE_ROOT/_unregistered/app/cc-dirty"
  add_wt "$MAIN" "$CC" worktree-dirty
  printf 'work\n' > "$CC/untracked.txt"
  backdate "$CC"
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"cc sweep held: tracked or untracked changes"* ]] || { echo "$output"; false; }
  [[ "$output" != *"git worktree remove  $CC"* ]] || { echo "$output"; false; }
}

@test "orphan gitdir: CRLF in .git still resolves a live worktree" {
  make_repo "$PROJECTS/app"
  WT="$PROJECTS/app-wt/crlf"
  add_wt "$PROJECTS/app" "$WT" feat/crlf
  real="$(git -C "$WT" rev-parse --absolute-git-dir)"
  printf 'gitdir: %s\r\n' "$real" > "$WT/.git"
  run bash -c '
    . "$1/scripts/lib/disk-janitor-lib.sh"
    . "$1/scripts/lib/hygiene-common.sh"
    . "$1/scripts/lib/disk-janitor-dehydrate.sh"
    _dw_orphan_gitdir "$2"
  ' _ "$REPO_ROOT" "$WT"
  [ "$status" -ne 0 ] || { echo "claimed orphan: $output"; false; }
}

@test "orphans --dehydrate: recent content inside node_modules holds it" {
  orphan_tree
  find "$ORPHAN" -exec touch -t "$OLD_STAMP" {} + 2>/dev/null || true
  touch -t "$OLD_STAMP" "$ORPHAN" "$ORPHAN/.git"
  printf 'fresh\n' > "$ORPHAN/node_modules/pkg/fresh.js"
  run_dj --apply --yes --dehydrate --scopes orphans
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$ORPHAN/node_modules/pkg/blob" ]
  [ -f "$ORPHAN/node_modules/pkg/fresh.js" ]
  [[ "$output" == *"recent activity"* ]] || { echo "$output"; false; }
}

@test "cc sweep: no tracked lockfile is held, never swept" {
  MAIN="$PROJECTS/app"
  make_repo "$MAIN"
  CC="$TRELLIS_WORKTREE_ROOT/_unregistered/app/cc-nolock"
  add_wt "$MAIN" "$CC" worktree-nolock
  fill "$CC/node_modules/pkg"
  git -C "$CC" rm -q pnpm-lock.yaml
  git -C "$CC" commit -q -m "drop lockfile"
  backdate "$CC"
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"cc sweep held: no tracked lockfile"* ]] || { echo "$output"; false; }
  [[ "$output" != *"git worktree remove  $CC"* ]] || { echo "$output"; false; }
}

@test "seed dirs: registry paths with control characters are filtered" {
  local targets="$SANDBOX/targets" evil1 evil2
  evil1="$PROJECTS/app"$'\x01'"evil"
  evil2="$PROJECTS/app"$'\t'"evil"
  printf 'fleet\tproj\tco\twt\t%s\t%s\n' "$PROJECTS/app" "/common" > "$targets"
  printf 'fleet\tproj\tco\twt\t%s\t%s\n' "$evil1" "/common" >> "$targets"
  printf 'fleet\tproj\tco\twt\t%s\t%s\n' "$evil2" "/common" >> "$targets"
  write_config '[]'
  mkdir -p "$SANDBOX/empty-root"
  run bash -c '
    . "$1/scripts/lib/disk-janitor-lib.sh"
    . "$1/scripts/lib/hygiene-common.sh"
    . "$1/scripts/lib/disk-janitor-dehydrate.sh"
    CFG="$2" TARGETS_TMP="$3" TRELLIS_WORKTREE_ROOT="$4" _dw_seed_dirs
  ' _ "$REPO_ROOT" "$CANON/trellis.config.json" "$targets" "$SANDBOX/empty-root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$PROJECTS/app"* ]] || { echo "$output"; false; }
  [[ "$output" != *"evil"* ]] || { echo "$output"; false; }
}

@test "enumerate: a bracket root still sweeps cc-* and skips _codex" {
  local broot="$SANDBOX/brack[et]/worktrees"
  mkdir -p "$broot"
  export TRELLIS_WORKTREE_ROOT="$broot"
  MAIN="$PROJECTS/app"
  make_repo "$MAIN"
  CC="$broot/_unregistered/app/cc-brack"
  add_wt "$MAIN" "$CC" worktree-brack
  fill "$CC/node_modules/pkg"
  backdate "$CC"
  local codex="$broot/_codex/1a2b/app"
  add_wt "$MAIN" "$codex" codex/brack
  fill "$codex/node_modules/pkg"
  backdate "$codex"
  DJ_MERGED_OVERRIDE=merged run_dj --report --scopes worktrees
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"git worktree remove  $CC"* ]] || { echo "$output"; false; }
  [[ "$output" == *"[skip] $codex ("*"Codex app worktree"* ]] || { echo "$output"; false; }
}

@test "classify: unreadable dir hiding nested git holds (scan fails closed)" {
  idle_tree
  mkdir -p "$WT/node_modules/locked/nested"
  git -C "$WT/node_modules/locked/nested" init -q -b main
  git -C "$WT/node_modules/locked/nested" config user.email t@example.com
  git -C "$WT/node_modules/locked/nested" config user.name t
  git -C "$WT/node_modules/locked/nested" config commit.gpgsign false
  printf 'secret\n' > "$WT/node_modules/locked/nested/secret.txt"
  git -C "$WT/node_modules/locked/nested" add -A
  git -C "$WT/node_modules/locked/nested" commit -q -m nested
  backdate "$WT"
  chmod 000 "$WT/node_modules/locked"
  classify "$WT"
  chmod 755 "$WT/node_modules/locked"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  has_row hold "$WT/node_modules" || { echo "$output"; false; }
  [[ "$output" == *"could not scan for nested git"* ]] || { echo "$output"; false; }
  ! has_row delete "$WT/node_modules"
}
