#!/usr/bin/env bats
# Tests for the pre-push merge-gate re-sync (Gap B) — the load-bearing target
# resolver in scripts/lib/prepush-target.sh (resolve_prepush_target), plus the
# overwrite + idempotency behavior driven through the lib.
#
# FULLY PORTABLE — every test builds a throwaway git repo in $BATS_TEST_TMPDIR.
# No absolute operator paths are hardcoded (the public mirror does not
# placeholder-substitute .bats files, so any hardcoded home-dir path literal
# would trip the redaction tripwire). Canonical pre-push sources are the real
# core-rules/husky/pre-push and core-rules/githooks/pre-push, resolved relative
# to $BATS_TEST_DIRNAME.
#
# DL-P5-11 discipline (EMPIRICALLY-CORRECT RULE): under bats `set -eET`, a
# NON-FINAL simple command that fails — `[ ]`, grep, cmp, jq, diff — DOES abort
# the test, but a NON-FINAL compound `[[ ]]` does NOT (its non-zero status is
# swallowed). So a load-bearing assertion must NEVER be a non-final `[[ ]]`:
# make it the FINAL statement, or write it as a set-e-catchable simple command
# (prefer `grep -qF <<<"$output"`). Every discriminating (post-state) assertion
# below is the FINAL enforced statement or a set-e-catchable simple command.

# shellcheck source=../lib/prepush-target.sh
source "$BATS_TEST_DIRNAME/../lib/prepush-target.sh"

setup() {
  SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CANON_HUSKY="$SRC_ROOT/core-rules/husky/pre-push"
  CANON_GITHOOKS="$SRC_ROOT/core-rules/githooks/pre-push"
  # HERMETICITY: resolve_prepush_target reads MERGED git config, so a global
  # core.hooksPath on the operator/CI box would leak into the "plain per-clone"
  # decision. Pin an empty per-test global config and disable the system one so
  # the resolver sees only the repo-local config we set explicitly. Use a temp
  # path (mirror-clean: no hardcoded operator path literal).
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : > "$GIT_CONFIG_GLOBAL"
  WORK="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$WORK"
  # Resolve through realpath so /var vs /private/var cannot diverge in the
  # inside/outside-worktree comparison.
  WORK="$(cd "$WORK" && pwd -P)"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email "ci-bats@trellis.test"
  git -C "$WORK" config user.name "trellis ci"
}

# _make_mg_instance — assemble a minimal Trellis instance to drive the REAL
# sync-merge-gate.sh binary (the sync_one overwrite-safety branch lives there,
# NOT in resolve_prepush_target, so the marker tests MUST go through the binary).
# Registry rows are passed as args. Exports MG_ROOT / MG_PROJECTS.
_make_mg_instance() {
  MG_ROOT="$BATS_TEST_TMPDIR/instance"
  MG_PROJECTS="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$MG_ROOT/core-rules/husky" "$MG_ROOT/core-rules/githooks" "$MG_ROOT/scripts/lib" "$MG_PROJECTS"
  cp "$CANON_HUSKY" "$MG_ROOT/core-rules/husky/pre-push"
  cp "$CANON_GITHOOKS" "$MG_ROOT/core-rules/githooks/pre-push"
  cp "$SRC_ROOT/scripts/sync-merge-gate.sh" "$MG_ROOT/scripts/sync-merge-gate.sh"
  cp "$SRC_ROOT/scripts/lib/blacklist-parser.sh" "$MG_ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/config-load.sh" "$MG_ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/prepush-target.sh" "$MG_ROOT/scripts/lib/"
  cp "$SRC_ROOT/scripts/lib/trellis.config.schema.json" "$MG_ROOT/scripts/lib/"
  {
    printf '%s\n' '## Active projects' '' '| Project | Path | Class | Notes |' '|---|---|---|---|'
    local n
    for n in "$@"; do printf '| %s | `/personal/%s` | x | y |\n' "$n" "$n"; done
    printf '%s\n' '' '---'
  } > "$MG_ROOT/registry.md"
  cat > "$MG_ROOT/trellis.config.json" <<EOF
{
  "trellis_root": "$MG_ROOT",
  "projects_root": "$MG_PROJECTS",
  "user_home": "$BATS_TEST_TMPDIR",
  "maintainer_name": "Test Maintainer",
  "github_user": "testuser",
  "harnesses": ["claude"]
}
EOF
}

# _seed_husky_project <name> <pre-push-body>  — husky project with a given
# pre-push content (so resolve_prepush_target picks the husky carrier).
_seed_husky_project() {
  local name="$1" body="$2"
  mkdir -p "$MG_PROJECTS/$name/.husky"
  git -C "$MG_PROJECTS/$name" init -q
  git -C "$MG_PROJECTS/$name" config user.email "ci-bats@trellis.test"
  git -C "$MG_PROJECTS/$name" config user.name "trellis ci"
  printf '%s' "$body" > "$MG_PROJECTS/$name/.husky/pre-push"
}

# Tab-field extractor (the resolver emits tab-separated ACTION\tTARGET\tKIND).
_field() { printf '%s' "$1" | cut -f"$2"; }

# Apply the lib decision the way sync-merge-gate.sh's sync_one does: sha-compare
# then overwrite. Kept tiny so tests exercise the real resolver + overwrite path
# without spinning up registry/config plumbing.
_apply() {
  local proj="$1" decision verb target kind src
  decision="$(resolve_prepush_target "$proj")"
  verb="$(_field "$decision" 1)"
  [ "$verb" = "WRITE" ] || return 0
  target="$(_field "$decision" 2)"
  kind="$(_field "$decision" 3)"
  case "$kind" in
    husky)    src="$CANON_HUSKY" ;;
    githooks) src="$CANON_GITHOOKS" ;;
  esac
  if [ ! -f "$target" ] || ! cmp -s "$src" "$target"; then
    mkdir -p "$(dirname "$target")"
    cp "$src" "$target"
    chmod +x "$target"
  fi
}

# ---------------------------------------------------------------------------
# HUSKY: .husky/pre-push is a stale copy -> after apply, file == canonical
# husky/pre-push (assert the run-all reference present as the FINAL check).
# ---------------------------------------------------------------------------
@test "husky: stale .husky/pre-push overwritten with canonical" {
  mkdir -p "$WORK/.husky"
  printf '#!/usr/bin/env sh\n# STALE husky pre-push\nexit 0\n' > "$WORK/.husky/pre-push"

  _apply "$WORK"
  # Byte-identical to canonical, AND the run-all carrier reference is present.
  cmp -s "$CANON_HUSKY" "$WORK/.husky/pre-push" \
    && grep -q "run-all.sh" "$WORK/.husky/pre-push"
}

# ---------------------------------------------------------------------------
# NATIVE: core.hooksPath=.githooks + stale .githooks/pre-push -> after apply,
# .githooks/pre-push == canonical githooks/pre-push.
# ---------------------------------------------------------------------------
@test "native: hooksPath=.githooks stale pre-push overwritten with canonical" {
  mkdir -p "$WORK/.githooks"
  printf '#!/usr/bin/env sh\n# STALE native pre-push\nexit 0\n' > "$WORK/.githooks/pre-push"
  git -C "$WORK" add .githooks/pre-push
  git -C "$WORK" commit -qm "seed githooks"
  git -C "$WORK" config core.hooksPath .githooks

  _apply "$WORK"
  # FINAL: byte-identical to canonical githooks source.
  cmp -s "$CANON_GITHOOKS" "$WORK/.githooks/pre-push"
}

@test "native: resolver picks the githooks source kind for in-repo hooksPath" {
  mkdir -p "$WORK/.githooks"
  : > "$WORK/.githooks/pre-push"
  git -C "$WORK" add .githooks/pre-push
  git -C "$WORK" commit -qm "seed githooks"
  git -C "$WORK" config core.hooksPath .githooks

  decision="$(resolve_prepush_target "$WORK")"
  # FINAL: verb WRITE, target under .githooks, kind githooks.
  [ "$(_field "$decision" 1)" = "WRITE" ] \
    && [ "$(_field "$decision" 3)" = "githooks" ] \
    && [ "$(basename "$(dirname "$(_field "$decision" 2)")")" = ".githooks" ]
}

# ---------------------------------------------------------------------------
# CLUSTERBID MISCONFIG: core.hooksPath = absolute .git/hooks AND a tracked
# .githooks/ present -> tool WARNs + SKIPs (pre-push NOT written to the absolute
# .git/hooks path) as the FINAL check.
# ---------------------------------------------------------------------------
@test "clusterbid misconfig: WARN + SKIP, no pre-push written to .git/hooks" {
  mkdir -p "$WORK/.githooks"
  : > "$WORK/.githooks/pre-push"
  git -C "$WORK" add .githooks/pre-push
  git -C "$WORK" commit -qm "seed githooks"
  # hooksPath pinned at the per-clone .git/hooks (absolute) while .githooks is tracked.
  git -C "$WORK" config core.hooksPath "$WORK/.git/hooks"

  decision="$(resolve_prepush_target "$WORK")"
  # Resolver must WARN (so the caller skips) and NOT instruct a write.
  [ "$(_field "$decision" 1)" = "WARN" ]
  # Run the apply path (which must be a no-op for WARN) and confirm nothing was
  # written into .git/hooks/pre-push.
  _apply "$WORK"
  # FINAL: no pre-push materialized at the absolute .git/hooks path.
  [ ! -f "$WORK/.git/hooks/pre-push" ]
}

@test "hooksPath outside worktree: WARN + SKIP" {
  git -C "$WORK" config core.hooksPath "$BATS_TEST_TMPDIR/external-hooks"
  decision="$(resolve_prepush_target "$WORK")"
  # FINAL: resolver warns rather than writing outside the worktree.
  [ "$(_field "$decision" 1)" = "WARN" ]
}

@test "plain per-clone: no husky, no hooksPath -> .git/hooks/pre-push target" {
  decision="$(resolve_prepush_target "$WORK")"
  # FINAL: WRITE into .git/hooks via the githooks source.
  [ "$(_field "$decision" 1)" = "WRITE" ] \
    && [ "$(_field "$decision" 3)" = "githooks" ] \
    && [ "$(basename "$(dirname "$(_field "$decision" 2)")")" = "hooks" ]
}

# ---------------------------------------------------------------------------
# IDEMPOTENT: 2nd apply is a no-op (file already byte-identical to canonical).
# ---------------------------------------------------------------------------
@test "idempotent: 2nd husky apply is a no-op (unchanged mtime-independent)" {
  mkdir -p "$WORK/.husky"
  printf 'STALE\n' > "$WORK/.husky/pre-push"
  _apply "$WORK"
  first_sha="$(shasum -a 256 "$WORK/.husky/pre-push" | awk '{print $1}')"
  _apply "$WORK"
  second_sha="$(shasum -a 256 "$WORK/.husky/pre-push" | awk '{print $1}')"
  canon_sha="$(shasum -a 256 "$CANON_HUSKY" | awk '{print $1}')"
  # FINAL: both runs converge to canonical (2nd run changed nothing).
  [ "$first_sha" = "$canon_sha" ] && [ "$second_sha" = "$canon_sha" ]
}

# ---------------------------------------------------------------------------
# OVERWRITE SAFETY (Pattern D) — these MUST drive the REAL sync-merge-gate.sh
# binary: the managed-marker check lives in sync_one, NOT in resolve_prepush_
# target / the _apply helper. Driving _apply would test nothing (green-while-
# broken). Two projects per run so we prove the unknown one is skipped WHILE the
# managed one still overwrites.
# ---------------------------------------------------------------------------
@test "binary overwrite-safety: unknown custom pre-push WARNs + SKIPs (not clobbered)" {
  _make_mg_instance unknownproj managedproj
  # unknownproj: NON-empty custom pre-push matching NO managed marker.
  _seed_husky_project unknownproj '#!/usr/bin/env sh
# my bespoke lint gate
exit 0
'
  # managedproj: stale-but-managed (contains the "Trellis" marker) -> overwrites.
  _seed_husky_project managedproj '#!/usr/bin/env sh
# Trellis canonical pre-push (OLD VERSION)
exit 0
'
  run env TRELLIS_CONFIG="$MG_ROOT/trellis.config.json" bash "$MG_ROOT/scripts/sync-merge-gate.sh" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qF "matches no managed marker" <<<"$output"
  # FINAL: the unknown custom hook was NOT clobbered (its bespoke marker remains).
  grep -qF "bespoke lint gate" "$MG_PROJECTS/unknownproj/.husky/pre-push"
}

@test "binary overwrite-safety: managed-marker (stale Trellis) pre-push is overwritten" {
  _make_mg_instance unknownproj managedproj
  _seed_husky_project unknownproj '#!/usr/bin/env sh
# my bespoke lint gate
exit 0
'
  _seed_husky_project managedproj '#!/usr/bin/env sh
# Trellis canonical pre-push (OLD VERSION)
exit 0
'
  run env TRELLIS_CONFIG="$MG_ROOT/trellis.config.json" bash "$MG_ROOT/scripts/sync-merge-gate.sh" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # FINAL: the managed (stale) hook now equals canonical (overwrite proceeded).
  cmp -s "$CANON_HUSKY" "$MG_PROJECTS/managedproj/.husky/pre-push"
}

# ---------------------------------------------------------------------------
# An EMPTY existing pre-push is a placeholder, not a custom hook: it overwrites
# normally (the [ -s "$target" ] guard treats zero-byte as overwritable).
# ---------------------------------------------------------------------------
@test "binary overwrite-safety: empty pre-push placeholder overwrites normally" {
  _make_mg_instance emptyproj
  _seed_husky_project emptyproj ''
  run env TRELLIS_CONFIG="$MG_ROOT/trellis.config.json" bash "$MG_ROOT/scripts/sync-merge-gate.sh" --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # FINAL: empty placeholder replaced with canonical.
  cmp -s "$CANON_HUSKY" "$MG_PROJECTS/emptyproj/.husky/pre-push"
}

# ---------------------------------------------------------------------------
# --from-main-only detached-HEAD guard (Pattern D LOW): when SOURCE_ROOT's HEAD
# is detached, --from-main-only must refuse (exit 1) BEFORE touching projects.
# Make SOURCE_ROOT itself a detached-HEAD repo so the guard fires on it.
# ---------------------------------------------------------------------------
@test "from-main-only: refuses to run on a detached-HEAD source" {
  _make_mg_instance someproj
  git -C "$MG_ROOT" init -q
  git -C "$MG_ROOT" config user.email "ci-bats@trellis.test"
  git -C "$MG_ROOT" config user.name "trellis ci"
  git -C "$MG_ROOT" add -A
  git -C "$MG_ROOT" commit -qm "seed"
  git -C "$MG_ROOT" checkout -q --detach HEAD
  run env TRELLIS_CONFIG="$MG_ROOT/trellis.config.json" bash "$MG_ROOT/scripts/sync-merge-gate.sh" --from-main-only --yes
  [ "$status" -eq 1 ]
  # FINAL: refusal reason printed (set-e-catchable simple command).
  grep -qF "HEAD is detached" <<<"$output"
}
