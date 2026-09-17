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
  # The identity guard reads the machine-local registry by default. Point it at
  # a synthetic fixture so the suite keeps its promise never to inspect an
  # operator's real machine configuration, and so a machine with no registry
  # does not turn every case into a fail-closed error.
  IDENTITY_SOURCE="$MIRROR.registry.json"
  cat > "$IDENTITY_SOURCE" <<'JSON'
{
  "projects": {
    "personal/fixtureproj": { "project_id": "fixtureproj" },
    "work/otherfixture": { "project_id": "otherfixture" }
  }
}
JSON
  export TRELLIS_MIRROR_IDENTITY_SOURCE="$IDENTITY_SOURCE"
  . "$LINT_LIB"
}

teardown() {
  rm -rf "$MIRROR"
  rm -f "${IDENTITY_SOURCE:-}"
  unset TRELLIS_MIRROR_IDENTITY_SOURCE
  [ -z "$VICTIM" ] || rm -rf "$VICTIM"
}

@test "clean portable mirror passes without local redaction inputs" {
  printf '# Public policy\nUse $HOME/.trellis after local configure.\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the portable pi subset lints clean beside the published inheritance manifest" {
  # The pi export is a positive allowlist carve-out: `core-rules/pi/agents` is
  # withheld and everything else under `core-rules/pi` publishes. That subset
  # plus the projected manifest is now ordinary mirror content, so it has to
  # pass this lint with no widened token list and no new exemption path.
  mkdir -p "$MIRROR/core-rules/pi/extensions" "$MIRROR/core-rules/pi/hooks" \
    "$MIRROR/core-rules/pi/patches/tests"
  printf 'import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";\n' \
    > "$MIRROR/core-rules/pi/extensions/trellis.ts"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexec "$HOME/.pi/hooks/$1"\n' \
    > "$MIRROR/core-rules/pi/hooks/dispatch.sh"
  printf 'pi install npm:pi-antigravity@0.5.2\n/login antigravity\n' \
    > "$MIRROR/core-rules/pi/patches/COMPACTION.md"
  printf -- '--- a/dist/index.js\n+++ b/dist/index.js\n' \
    > "$MIRROR/core-rules/pi/patches/pi-coding-agent-0.85.0-compaction-integrity.patch"
  printf 'process.exit(0);\n' \
    > "$MIRROR/core-rules/pi/patches/tests/pi-compaction-integrity.mjs"
  cat > "$MIRROR/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 2,
  "harnesses": {
    "pi": {
      "links": [
        {
          "source": "core-rules/pi/extensions/trellis.ts",
          "destination": ".pi/extensions/trellis.ts"
        }
      ],
      "render": []
    }
  }
}
JSON

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ]
}

@test "049 user skill store public surface lints clean at mirror paths" {
  # Spec 049 classifies the computer-use pi link, skills.sh, skill-roots.sh,
  # the doctor check and the docs as PUBLIC: they publish through the existing
  # allowlist entries (core-rules/pi/, scripts/, docs/, core-rules/) with no
  # new prune entry. A public file must therefore pass this lint at its mirror
  # path with no widened token list and no new exemption path.
  mkdir -p "$MIRROR/scripts/lib" "$MIRROR/docs" \
    "$MIRROR/core-rules/pi/computer-use"
  cp "$REPO_ROOT/scripts/skills.sh" "$MIRROR/scripts/skills.sh"
  cp "$REPO_ROOT/scripts/lib/skill-roots.sh" "$MIRROR/scripts/lib/skill-roots.sh"
  cp "$REPO_ROOT/scripts/lib/health-checks.sh" "$MIRROR/scripts/lib/health-checks.sh"
  cp "$REPO_ROOT/docs/UPGRADING.md" "$MIRROR/docs/UPGRADING.md"
  cp "$REPO_ROOT/docs/PI-COMPUTER-USE.md" "$MIRROR/docs/PI-COMPUTER-USE.md"
  cp "$REPO_ROOT/core-rules/inheritance.md" "$MIRROR/core-rules/inheritance.md"
  cp "$REPO_ROOT/core-rules/pi/computer-use/SKILL.md" \
    "$MIRROR/core-rules/pi/computer-use/SKILL.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ]
}

@test "canonical google-antigravity provider id remains publishable" {
  printf 'flash: google-antigravity/gemini-3.8-flash:high\n' > "$MIRROR/omp-config.yml"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "live pi provider tokens are publishable" {
  # The pi provider extension package and the bare lowercase pi provider id
  # name live, current things — the retired harness was always prose-cased.
  printf 'pi install npm:pi-antigravity@0.5.2\n' > "$MIRROR/install.md"
  printf 'Type `/login antigravity` and complete sign-in.\n' > "$MIRROR/login.md"
  printf 'pi --offline --list-models antigravity\n' > "$MIRROR/probe.sh"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prose-cased Antigravity is still rejected beside live pi tokens" {
  # Case is the discriminator: allowing the lowercase id must not let the
  # retired harness back in through the same file.
  printf 'npm:pi-antigravity@0.5.2 is live; Google Antigravity is not\n' > "$MIRROR/mixed.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"mixed.md: stale 'antigravity' in current operator surface"* ]] || { echo "$output"; false; }
}

@test "bare pi provider id must not be embedded in a longer identifier" {
  printf 'antigravity-harness is retired\n' > "$MIRROR/suffixed.md"
  printf 'myantigravity shim\n' > "$MIRROR/prefixed.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"suffixed.md: stale 'antigravity' in current operator surface"* ]] || { echo "$output"; false; }
  [[ "$output" == *"prefixed.md: stale 'antigravity' in current operator surface"* ]] || { echo "$output"; false; }
}

@test "bare retired AntiGravity token is rejected beside the provider id" {
  printf 'google-antigravity is current; the AntiGravity harness is retired\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: stale 'antigravity' in current operator surface"* ]] || { echo "$output"; false; }
}

@test "provider identifier must be lowercase and unembedded" {
  printf 'flash: GOOGLE-ANTIGRAVITY/gemini\n' > "$MIRROR/uppercase.yml"
  printf 'flash: proxy-google-antigravity/gemini\n' > "$MIRROR/embedded.yml"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"uppercase.yml: stale 'antigravity' in current operator surface"* ]] || { echo "$output"; false; }
  [[ "$output" == *"embedded.yml: stale 'antigravity' in current operator surface"* ]] || { echo "$output"; false; }
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

# --- fleet identity + infrastructure leak guards --------------------------
# These exist because a payload that every earlier check called clean still
# carried 80 project-name references and 13 routable IP literals into the
# public mirror. Narrative files were the carrier, so the identity guard
# deliberately grants no historical-record exemption.

@test "a fleet project identifier is rejected in ordinary policy prose" {
  printf 'The fixtureproj rollout landed.\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'README.md: local fleet project identifier must not publish' <<<"$output"
}

@test "a fleet project identifier is rejected in an ADR and the changelog too" {
  mkdir -p "$MIRROR/docs/adr"
  printf 'Verified live on otherfixture.\n' > "$MIRROR/docs/adr/0001-example.md"
  printf 'Backfilled onto fixtureproj.\n' > "$MIRROR/CHANGELOG.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'docs/adr/0001-example.md: local fleet project identifier must not publish' <<<"$output"
  grep -qF 'CHANGELOG.md: local fleet project identifier must not publish' <<<"$output"
}

@test "identifier matching is word-anchored, not substring" {
  printf 'The fixtureprojection module is unrelated.\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A registry row written by the real `local-registry.sh` writer, in the exact
# `jq -S` two-space shape the public-identity parser reads by indentation. The
# `legacy` note carries literal braces inside a JSON string on purpose: that is
# the real-world content which makes a brace-depth parser miscount, and the
# reason this one keys on indentation instead.
write_annotated_registry() {
  local public_flag="$1"
  cat > "$IDENTITY_SOURCE" <<JSON
{
  "projects": {
    "personal/fixtureproj.org": {
      "fleet": "personal",
      "metadata": {
        "legacy": {
          "shared_services": "\`services: {}\`"
        },
        "public_identity": $public_flag
      },
      "project_id": "fixtureproj.org",
      "status": "active"
    },
    "work/otherfixture": {
      "fleet": "work",
      "metadata": {},
      "project_id": "otherfixture",
      "status": "active"
    }
  }
}
JSON
}

@test "a project annotated public_identity may publish its own identifier" {
  write_annotated_registry true
  printf 'Built and maintained by [Someone](https://fixtureproj.org).\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a public_identity annotation frees only the row it is set on" {
  write_annotated_registry true
  printf 'See https://fixtureproj.org and the otherfixture rollout.\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'README.md: local fleet project identifier must not publish' <<<"$output"
}

@test "public identity defaults closed when the row does not claim it" {
  write_annotated_registry false
  printf 'Built and maintained by [Someone](https://fixtureproj.org).\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'README.md: local fleet project identifier must not publish' <<<"$output"
}

# `sync-to-template.sh` — the only real caller — runs under `set -o pipefail`,
# and bats does not. A stage that exits non-zero on the ordinary no-annotations
# path is therefore invisible to every other case in this file and fails only
# in production, which is exactly how it first shipped. Assert the contract in
# the caller's shell options, not this suite's.
@test "identity tokens survive pipefail when no row claims public identity" {
  set -o pipefail
  run lint_mirror "$MIRROR"
  set +o pipefail

  [ "$status" -eq 0 ]
  ! grep -qF 'refusing to certify' <<<"$output"
}

@test "an unreadable identity source refuses to certify instead of passing" {
  export TRELLIS_MIRROR_IDENTITY_SOURCE="$MIRROR/absent-registry.json"
  printf '# Public policy\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'refusing to certify' <<<"$output"
}

@test "a routable IP literal is rejected" {
  printf 'Origin is 139.99.130.129 in Sydney.\n' > "$MIRROR/docs.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'docs.md: routable IP literal must not publish' <<<"$output"
}

@test "private, loopback and documentation ranges stay publishable" {
  printf 'Try 127.0.0.1, 10.1.2.3, 192.168.0.1, 172.16.0.1 or 203.0.113.7.\n' \
    > "$MIRROR/examples.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "content checks still run when a symlink is unresolvable" {
  ln -s /etc/passwd "$MIRROR/escape.md"
  printf 'The fixtureproj rollout landed.\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  grep -qF 'escape.md: symlink target leaks absolute path' <<<"$output"
  grep -qF 'README.md: local fleet project identifier must not publish' <<<"$output"
}

# --- Spec 047 adapter: path-scoped public-contract allowance ---------------
# The adapter's own public contract is unavoidably capitalised. The allowance
# is scoped to its paths and enumerates exact tokens, so these tests exist in
# pairs: what the allowance must let through, and what it must still catch.
# A widened allowance passes the positives and fails the negatives — which is
# the only way this pair is worth having.

@test "047 adapter public contract publishes inside its own paths" {
  mkdir -p "$MIRROR/core-rules/pi/web-search/tests" "$MIRROR/scripts"
  printf 'import { createAntigravityTransport } from "./antigravity.ts";\n' \
    > "$MIRROR/core-rules/pi/web-search/index.ts"
  printf 'export const ANTIGRAVITY_API = "antigravity-api";\n' \
    >> "$MIRROR/core-rules/pi/web-search/index.ts"
  printf 'const o = deps.env("ANTIGRAVITY_BASE_URL");\n' \
    >> "$MIRROR/core-rules/pi/web-search/index.ts"
  printf '// Antigravity-backed Google Search grounding.\n' \
    >> "$MIRROR/core-rules/pi/web-search/index.ts"
  printf '{"ideType":"ANTIGRAVITY"}\n' \
    > "$MIRROR/core-rules/pi/web-search/tests/transport.test.ts"
  printf 'env -u ANTIGRAVITY_HUB_VERSION -u ANTIGRAVITY_HUB_CL -u ANTIGRAVITY_HUB_OS\n' \
    > "$MIRROR/scripts/pi-web-search-tests.sh"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the retired harness spelling still fails INSIDE the allowed adapter paths" {
  # The widest point of the allowance is where a stale reference would hide.
  mkdir -p "$MIRROR/core-rules/pi/web-search"
  printf 'The AntiGravity harness was retired.\n' \
    > "$MIRROR/core-rules/pi/web-search/notes.ts"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"core-rules/pi/web-search/notes.ts: stale 'antigravity'"* ]]
}

@test "an unenumerated capitalised form fails inside the allowed adapter paths" {
  mkdir -p "$MIRROR/core-rules/pi/web-search"
  printf 'const s = "AntigravityFoo";\n' > "$MIRROR/core-rules/pi/web-search/x.ts"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"core-rules/pi/web-search/x.ts: stale 'antigravity'"* ]]
}

@test "an adapter contract token fails OUTSIDE the allowed adapter paths" {
  # This is what a global token allowance would have broken.
  printf 'const x = "ANTIGRAVITY_BASE_URL";\n' > "$MIRROR/README.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"README.md: stale 'antigravity'"* ]]
}

@test "an unenumerated ANTIGRAVITY_ env name fails inside the allowed adapter paths" {
  # The adjacency rule must keep ANTIGRAVITY_ from acting as a prefix class:
  # enumerating the names the adapter reads must not silently cover every
  # future ANTIGRAVITY_* name, including one carrying a secret.
  mkdir -p "$MIRROR/core-rules/pi/web-search"
  printf 'const k = deps.env("ANTIGRAVITY_SECRET_KEY");\n' \
    > "$MIRROR/core-rules/pi/web-search/leak.ts"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"core-rules/pi/web-search/leak.ts: stale 'antigravity'"* ]]
}

@test "the public web-search guide publishes with its env contract" {
  # The guide carries the same ANTIGRAVITY_ env names as the adapter, so it is
  # in the same path scope. Prose uses the lowercase provider id.
  mkdir -p "$MIRROR/docs"
  printf '# Web search in Pi (opt-in, backed by antigravity)\n' \
    > "$MIRROR/docs/pi-web-search.md"
  printf 'Set `ANTIGRAVITY_BASE_URL` only to a matching origin.\n' \
    >> "$MIRROR/docs/pi-web-search.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "another docs page still fails on the same env name" {
  # The guide's scope must not become a docs-wide allowance.
  mkdir -p "$MIRROR/docs"
  printf 'Set `ANTIGRAVITY_BASE_URL` here too.\n' > "$MIRROR/docs/other-guide.md"

  run lint_mirror "$MIRROR"

  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/other-guide.md: stale 'antigravity'"* ]]
}

@test "the public web-search guide is in the sync allowlist (GUARD ONLY)" {
  # SUPPLEMENTARY GUARD, NOT THE PROOF. This asserts on source text, so it
  # cannot fail in the way a projection failure would: it still passes if a
  # later exclusion, a payload_no_publish entry or a prune rule removes the
  # file from the staged mirror. The behavioural proof that the guide reaches
  # the mirror is the complete official projection, which lists
  # docs/pi-web-search.md in the staged output by name; see the release
  # rehearsal receipt. This test exists only so the allowlist entry cannot be
  # dropped silently.
  run grep -qxF "  'docs/pi-web-search.md'" \
    "$BATS_TEST_DIRNAME/../sync-to-template.sh"

  [ "$status" -eq 0 ]
}
