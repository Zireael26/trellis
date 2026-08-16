#!/usr/bin/env bats
# Public mirror safety contracts. Fixtures contain only synthetic paths and
# never inspect an operator machine configuration or home directory.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LINT_LIB="$REPO_ROOT/scripts/lib/mirror-lint.sh"

# --- pairing-contract extraction ------------------------------------------
# Shared by the pairing test and its own vacuity guard, so the reject-term
# list and the guard that proves the list is real can never drift apart.

# The structural reject block only: it starts at the `.trellis` term and ends
# at its `-not -path` guard. The `.git` traversal prunes in the later content
# scans are not reject terms and must stay outside the range.
lint_reject_block() {
  sed -n '/\\( -path "\$mirror_pat\/\.trellis"/,/-not -path/p' "$1"
}

# Anchored reject roots: `-path` terms with no trailing `/*` companion glob.
# `/` is inside the segment repetition so a multi-segment root such as
# `state/attachments` is extracted whole. A single-segment-only pattern would
# match neither the whole term nor any prefix of it, so the term would vanish
# from the pairing check entirely — the silent miss this test exists to catch.
lint_reject_roots() {
  lint_reject_block "$1" \
    | grep -oE '\$mirror_pat/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*"' \
    | sed -e 's|\$mirror_pat/||' -e 's|"$||'
}

# The reject roots this test expects `mirror-lint.sh` to carry, written out as
# a literal rather than derived. This is the whole point of the pairing test:
# an extraction compared only against itself proves nothing, and count
# arithmetic over the same extraction is satisfied by an empty range. Sorted
# with `LC_ALL=C sort -u`, the same way the actual list is normalised below.
#
# Changing `mirror-lint.sh`'s reject terms is therefore a two-place edit — this
# literal and the `delist_prune` array in `sync-to-template.sh` — which is the
# intended cost of adding or retiring a private root.
expected_lint_reject_roots() {
  LC_ALL=C sort -u <<'EOF'
.trellis
config.json
locks
local
registry.json
releases
scheduled-tasks
state
tasks
EOF
}

# The quoted entries of the `delist_prune` array literal and nothing else. The
# counterpart lookup must not be satisfiable by an unrelated two-space-indented
# quoted token elsewhere in `sync-to-template.sh`.
sync_prune_entries() {
  awk -v q="'" '
    /^delist_prune=\(/ { inside = 1; next }
    inside && /^\)/    { inside = 0 }
    inside {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (length(line) >= 2 && substr(line, 1, 1) == q && substr(line, length(line), 1) == q) {
        print substr(line, 2, length(line) - 2)
      }
    }
  ' "$1"
}

# Assert that every structural finding in `$output` is attributed to root $1.
# Non-vacuous in both directions: it fails when a finding names a different
# root, and it fails when there are no structural findings at all.
assert_all_findings_under() {
  local root="$1" paths stray
  paths="$(printf '%s\n' "$output" \
    | sed -n 's/: private Trellis machine state must not publish$//p')"
  [ -n "$paths" ] || { echo "no structural findings at all:"; echo "$output"; false; }
  stray="$(printf '%s\n' "$paths" | grep -vE "^$root(/|\$)" || true)"
  [ -z "$stray" ] || { echo "findings outside $root:"; echo "$stray"; false; }
}

setup() {
  MIRROR="$(mktemp -d "${TMPDIR:-/tmp}/trellis-mirror-lint.XXXXXX")"
  VICTIM=""
  . "$LINT_LIB"
}

teardown() {
  rm -rf "$MIRROR"
  [ -z "$VICTIM" ] || rm -rf "$VICTIM"
}

@test "clean portable mirror passes without local redaction inputs" {
  printf '# Public policy\nUse $HOME/.trellis after local configure.\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "private Trellis release attachment and task state are rejected structurally" {
  mkdir -p "$MIRROR/.trellis/releases/1.2.3" \
    "$MIRROR/state/attachments" "$MIRROR/state/tasks" \
    "$MIRROR/scheduled-tasks"
  printf '{}\n' > "$MIRROR/.trellis/config.json"
  printf '{}\n' > "$MIRROR/config.json"
  printf '{}\n' > "$MIRROR/registry.json"
  printf 'private task\n' > "$MIRROR/scheduled-tasks/prompt.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'.trellis: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'registry.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'scheduled-tasks: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'config.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'state: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
}

# Fixtures below use the exact on-disk layouts the product writes under
# TRELLIS_HOME, so each one fails if its structural term is dropped:
#   state/attachments/<checkout>/<worktree>.json  scripts/lib/attachment.sh:1227
#   state/git-hooks/<checkout>/pre-push           scripts/lib/attachment.sh:918
#   tasks/<fleet>/<task>/snapshot.json            scripts/materialize-scheduled-task.sh:1166
#   locks/registry.lock                           scripts/lib/local-registry.sh:423
#   releases/<version>/release.json               scripts/lib/release-store.sh:606

@test "attachment ownership and managed hook state are rejected under state/" {
  mkdir -p "$MIRROR/state/attachments/0f1e2d3c" \
    "$MIRROR/state/attachment-journals" \
    "$MIRROR/state/git-hooks/0f1e2d3c" \
    "$MIRROR/state/locks"
  printf '{}\n' > "$MIRROR/state/attachments/0f1e2d3c/worktree-a.json"
  printf '{}\n' > "$MIRROR/state/attachment-journals/detach-0f1e2d3c.json"
  printf '#!/bin/sh\nexit 0\n' > "$MIRROR/state/git-hooks/0f1e2d3c/pre-push"
  printf '1234\n' > "$MIRROR/state/locks/attachment-checkout-0f1e2d3c.lock"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'state/attachments/0f1e2d3c/worktree-a.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'state/attachment-journals/detach-0f1e2d3c.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'state/git-hooks/0f1e2d3c/pre-push: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'state/locks/attachment-checkout-0f1e2d3c.lock: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
}

@test "materialized task state is rejected independently of scheduled-tasks" {
  mkdir -p "$MIRROR/tasks/parent/conductor/output"
  printf '{}\n' > "$MIRROR/tasks/parent/conductor/snapshot.json"
  printf '{}\n' > "$MIRROR/tasks/parent/conductor/manifest.json"
  printf '{}\n' > "$MIRROR/tasks/parent/conductor/backlog.json"
  printf 'private prompt\n' > "$MIRROR/tasks/parent/conductor/prompt.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'tasks: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'tasks/parent/conductor/snapshot.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'tasks/parent/conductor/backlog.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  # `tasks` is a root of its own, not a sub-case of `scheduled-tasks` (the
  # repository's source directory, absent here). Asserting that the word
  # `scheduled-tasks` does not appear would be vacuous — nothing in the fixture
  # could produce it. The real claim is that every finding is attributed to the
  # `tasks` root, which fails the moment a finding arrives under another name.
  assert_all_findings_under tasks
}

@test "TRELLIS_HOME lock root is rejected independently of state/locks" {
  mkdir -p "$MIRROR/locks/registry.lock"
  printf '4321\n' > "$MIRROR/locks/registry.lock/pid"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'locks: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'locks/registry.lock/pid: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  # `locks` is the TRELLIS_HOME lock root, not `state/locks`. Asserting that
  # `state:` is absent would be vacuous — the fixture never creates a `state`
  # directory, so no term could report one. The real claim is that every
  # finding is attributed to the `locks` root.
  assert_all_findings_under locks
}

@test "release store records and payloads are rejected structurally" {
  mkdir -p "$MIRROR/releases/1.2.3/payload"
  printf '{}\n' > "$MIRROR/releases/1.2.3/release.json"
  printf 'policy\n' > "$MIRROR/releases/1.2.3/payload/CLAUDE.md"
  printf '1234\n' > "$MIRROR/releases/1.2.3.lock"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'releases/1.2.3/release.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'releases/1.2.3/payload/CLAUDE.md: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'releases/1.2.3.lock: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
}

@test "every structural lint root has a sync-to-template prune counterpart" {
  local sync="$REPO_ROOT/scripts/sync-to-template.sh"
  local lint="$REPO_ROOT/scripts/lib/mirror-lint.sh"
  local root missing="" prune_entries actual expected

  # 1. The extracted reject roots are exactly the expected list. Compared as a
  #    sorted list against a literal written in this file, so all three
  #    mutations go red: deleting a term drops a line from `actual`, adding an
  #    unpaired term adds one, and an extraction that silently returns nothing
  #    (empty range, changed term shape) is the empty list against nine names.
  actual="$(lint_reject_roots "$lint" | LC_ALL=C sort -u)"
  expected="$(expected_lint_reject_roots)"
  [ "$actual" = "$expected" ] || {
    printf 'lint reject roots drifted from the expected list\n--- expected\n%s\n--- actual\n%s\n' \
      "$expected" "$actual" >&2
    false
  }

  # 2. Every one of those roots is inside the `delist_prune` array literal, and
  #    the counterpart lookup reads that array range only: a matching token
  #    elsewhere in `sync-to-template.sh` must not satisfy it, and `.trellis`
  #    must not be satisfied by a regex-dot match. Moving a root out of the
  #    array — deleting the entry, or relocating it past the closing `)` — goes
  #    red here.
  prune_entries="$(sync_prune_entries "$sync")"
  [ -n "$prune_entries" ] || { echo 'delist_prune array extraction returned nothing'; false; }

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    printf '%s\n' "$prune_entries" | grep -qxF -- "$root" || missing="$missing $root"
  done <<EOF
$actual
EOF

  [ -z "$missing" ] || {
    printf 'lint roots with no delist_prune entry:%s\n' "$missing" >&2
    false
  }
}

@test "structural scan still fires when the mirror path contains glob metacharacters" {
  # `find -path` matches with glob semantics, so an unescaped `[`, `*` or `?`
  # in the linted directory's own absolute path would turn every reject term
  # into a pattern that matches nothing — the scan would fail open and a
  # mirror full of private state would lint clean.
  local glob_root="$MIRROR/lint[a-z]*root"
  mkdir -p "$glob_root/state/attachments/0f1e2d3c" \
    "$glob_root/tasks/parent/conductor"
  printf '{}\n' > "$glob_root/config.json"
  printf '{}\n' > "$glob_root/state/attachments/0f1e2d3c/worktree-a.json"
  printf '{}\n' > "$glob_root/tasks/parent/conductor/snapshot.json"

  run lint_mirror "$glob_root"

  [ "$status" -eq 1 ]
  [[ "$output" == *'config.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'state/attachments/0f1e2d3c/worktree-a.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
  [[ "$output" == *'tasks/parent/conductor/snapshot.json: private Trellis machine state must not publish'* ]] || { echo "$output"; false; }
}

@test "unknown operator home paths fail without a configured source-root token" {
  operator_home="/Users/${BATS_TEST_NUMBER:-fixture}-operator/private/trellis"
  printf 'Leaked checkout: %s\n' "$operator_home" > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'README.md: absolute-path leak'* ]] || { echo "$output"; false; }
  [[ "$output" != *'portable-operator'* ]] || { echo "$output"; false; }
}

@test "generic documentation home examples remain portable" {
  printf 'Example: /Users/me/projects/trellis and /home/example/trellis\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
}

@test "absolute symlink targets are rejected" {
  operator_home="/Users/${BATS_TEST_NUMBER:-fixture}-operator/private/trellis"
  ln -s "$operator_home" "$MIRROR/runtime"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'runtime: symlink target leaks absolute path'* ]] || { echo "$output"; false; }
}

@test "relative symlink escapes are rejected without touching an external victim" {
  VICTIM="$(mktemp -d "${TMPDIR:-/tmp}/trellis-mirror-victim.XXXXXX")"
  printf 'external victim\n' > "$VICTIM/sentinel"
  before="$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)"
  ln -s "../$(basename "$VICTIM")" "$MIRROR/escape"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *'escape: symlink target escapes mirror'* ]] || { echo "$output"; false; }
  [ "$(shasum -a 256 "$VICTIM/sentinel" | cut -d ' ' -f 1)" = "$before" ]
}
