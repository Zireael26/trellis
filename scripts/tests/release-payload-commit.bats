#!/usr/bin/env bats
# Spec 055 Unit 3: the release payload commit and its two-stage identity gate.
#
#   A3.2  scripts/release-payload-commit.sh builds a deterministic payload commit.
#   A3.3  No runtime reference in the kept tree points into an excluded path, and
#         packaging the real tree leaves no test files behind.
#   A3.7  --verify-candidate (before any tag exists) and --verify-tag.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/payload-fixture

setup() {
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/trellis-gate-state"
  SRC="$BATS_TEST_TMPDIR/src"
  payload_fixture_source "$SRC" 7.7.7
}

g() { payload_fixture_git -C "$SRC" "$@"; }

tool() { payload_fixture_tool "$SRC" "$@"; }

# variant <from> <parent|-> <op>...: a commit whose tree is <from>'s tree with
# each op applied. rm:<path> drops every file under <path>; put:<path>=<text>
# writes one file. <parent> "-" makes a root commit.
variant() {
  local from="$1" parent="$2" index="$BATS_TEST_TMPDIR/variant.index" op path blob tree
  shift 2
  rm -f "$index"
  GIT_INDEX_FILE="$index" g read-tree "$from"
  for op in "$@"; do
    case "$op" in
      rm:*)
        g ls-tree -r -z --name-only "$from" -- "${op#rm:}" |
          GIT_INDEX_FILE="$index" g update-index -z --force-remove --stdin
        ;;
      put:*)
        path="${op#put:}"
        path="${path%%=*}"
        blob="$(printf '%s\n' "${op#*=}" | g hash-object -w --stdin)"
        GIT_INDEX_FILE="$index" g update-index --add --cacheinfo "100644,$blob,$path"
        ;;
    esac
  done
  tree="$(GIT_INDEX_FILE="$index" g write-tree)"
  if [ "$parent" = - ]; then
    g commit-tree "$tree" -m variant
  else
    g commit-tree "$tree" -p "$parent" -m variant
  fi
}

refused() {
  [ "$status" -eq 1 ] || { echo "expected refusal (1), got $status: $output"; false; }
  [[ "$output" == *"refused: $1"* ]] || { echo "expected refusal naming '$1': $output"; false; }
}

no_tags() {
  [ -z "$(g tag -l)" ] || { echo "a tag exists: $(g tag -l)"; false; }
}

# ---------------------------------------------------------------------------
# A3.2 — deterministic packaging
# ---------------------------------------------------------------------------

@test "A3.2 packaging keeps the release commit as sole parent and drops only the listed paths" {
  run tool "$PAYLOAD_FIXTURE_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  payload="$output"

  [ "$(g rev-list --parents -n1 "$payload")" = "$payload $PAYLOAD_FIXTURE_RELEASE" ]
  run g ls-tree -r --name-only "$payload"
  [ "$output" = "core-rules/VERSION
core-rules/hooks/x.sh
core-rules/payload-exclude.txt
docs/readme.md
scripts/tool.sh
scripts/trellis" ] || { echo "$output"; false; }
  [ "$(g cat-file blob "$payload:core-rules/VERSION")" = 7.7.7 ]
}

@test "A3.2 two runs give the same SHA, with author and committer copied and nothing else touched" {
  before_refs="$(g for-each-ref)"
  before_status="$(g status --porcelain=v1 --untracked-files=all)"
  first="$(tool "$PAYLOAD_FIXTURE_RELEASE")"
  second="$(tool "$PAYLOAD_FIXTURE_RELEASE")"
  [ -n "$first" ] && [ "$first" = "$second" ]

  [ "$(g show -s --format='%an <%ae> %ad|%cn <%ce> %cd' --date=raw "$first")" = \
    "$(g show -s --format='%an <%ae> %ad|%cn <%ce> %cd' --date=raw "$PAYLOAD_FIXTURE_RELEASE")" ]
  [ "$(g for-each-ref)" = "$before_refs" ]
  [ "$(g status --porcelain=v1 --untracked-files=all)" = "$before_status" ]
}

@test "A3.2 a list entry naming a path that does not exist is refused" {
  printf 'specs/\ndocs/missing/\n' > "$SRC/core-rules/payload-exclude.txt"
  g commit -qam 'list names a missing path'
  run tool "$(g rev-parse HEAD)"
  refused 'listed path is absent'
  [[ "$output" == *"docs/missing/"* ]] || { echo "$output"; false; }
}

@test "A3.2 a VERSION that is not exactly one version line is refused" {
  printf '7.7.7\ninjected\n' > "$SRC/core-rules/VERSION"
  g commit -qam 'version with a second line'
  run tool "$(g rev-parse HEAD)"
  refused "core-rules/VERSION in $(g rev-parse HEAD) is not one version line"

  printf 'latest\n' > "$SRC/core-rules/VERSION"
  g commit -qam 'version that is not a version'
  run tool "$(g rev-parse HEAD)"
  refused "core-rules/VERSION in $(g rev-parse HEAD) is not one version line"
}

@test "A3.2 packaging removes its scratch directory when TMPDIR holds an apostrophe" {
  local tmp="$BATS_TEST_TMPDIR/it's tmp"
  mkdir -p "$tmp"
  expected="$(tool "$PAYLOAD_FIXTURE_RELEASE")"
  TMPDIR="$tmp" run tool "$PAYLOAD_FIXTURE_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$expected" ] || { echo "$output"; false; }
  [ -z "$(ls -A "$tmp")" ] || { echo "scratch left behind: $(ls -A "$tmp")"; false; }
}

@test "A3.2 a list entry that would drop core-rules/VERSION is refused" {
  printf 'core-rules/\n' > "$SRC/core-rules/payload-exclude.txt"
  g commit -qam 'list drops the version'
  run tool "$(g rev-parse HEAD)"
  refused 'exclusion entry would drop core-rules/VERSION'
}

# ---------------------------------------------------------------------------
# A3.3 — runtime references and the HEAD packaging check (R3.4, R3.5)
# ---------------------------------------------------------------------------

# Whole files exempt from the reference scan. The first six are the spec's
# source-checkout tools (R3.4). The pre-seal checker also stages source tests,
# not installed payload tests. The last two were found by this scan on the real
# tree and are exempt for the same reason (R3.4, accepted 2026-09-28):
#   scripts/harness-conformance.py  its header says "source-only adapter fixture
#                                   corpus"; run-tests.sh drives it, no command does.
#   scripts/lint-shell-tree.sh      lints the source checkout's own roots.
SCAN_EXEMPT_FILES='scripts/run-tests.sh
scripts/lib/test-suites.sh
scripts/lib/mirror-lint.sh
scripts/sync-to-template.sh
scripts/check-mirror-preseal.sh
scripts/pi-web-search-tests.sh
core-rules/skills/process-gate/scripts/check-tests.sh
scripts/harness-conformance.py
scripts/lint-shell-tree.sh'

# <file>|<prefix> pairs exempt for ONE prefix only, so any other excluded prefix
# in the same file still fails. Each names the attached PROJECT's own specs/
# tree, resolved against a project root (or describes it in a config comment),
# never the payload's specs/, which a payload has never needed.
SCAN_EXEMPT_PAIRS='core-rules/hooks/lib/spec-gate-core.sh|specs/
scripts/check-gate-inventory.sh|scripts/tests/
core-rules/skills/process-gate/scripts/check-analyze.sh|specs/
core-rules/skills/orchestrate/recipes/conductor.wf.js|specs/
core-rules/skills/orchestrate/recipes/digest-adopt.wf.js|specs/
scripts/verify-conductor-spec-inventory.mjs|specs/
scripts/lib/trellis.config.schema.json|specs/
trellis.config.json|specs/'

list_prefixes() {
  sed -e '/^#/d' -e '/^$/d' "$1/core-rules/payload-exclude.txt"
}

under_listed_prefix() {
  local path="$1" prefix
  while IFS= read -r prefix; do
    case "$path" in "$prefix"*) return 0 ;; esac
  done <<EOF
$PREFIXES
EOF
  return 1
}

# scan_references <root> <pathlist>: print "<path>: <prefix>: <line>" for every
# runtime reference to a listed prefix in the kept tree of <root>. Whole-line
# comments are stripped first; a reference is a listed prefix at a path-token
# boundary, `(^|[^A-Za-z0-9_.-])<prefix>`.
scan_references() {
  local root="$1" list="$2" path prefix pattern base any lines
  PREFIXES="$(list_prefixes "$root")"
  any="(^|[^A-Za-z0-9_.-])($(printf '%s\n' "$PREFIXES" | sed 's/[.]/\\./g' | paste -sd '|' -))"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    under_listed_prefix "$path" && continue
    # Records directories hold captured data, not code a payload runs.
    payload_fixture_is_record "$path" && continue
    case $'\n'"$SCAN_EXEMPT_FILES"$'\n' in *$'\n'"$path"$'\n'*) continue ;; esac
    case "$path" in
      *.sh|*.py|*.js|*.mjs|*.ts|*.json) ;;
      core-rules/githooks/*)
        base="${path##*/}"
        case "$base" in *.*) continue ;; esac
        ;;
      *) continue ;;
    esac
    [ -f "$root/$path" ] || continue
    lines="$(grep -vE '^[[:space:]]*(#|//|/\*|\*)' "$root/$path" | grep -E -- "$any")" || continue
    while IFS= read -r prefix; do
      case $'\n'"$SCAN_EXEMPT_PAIRS"$'\n' in *$'\n'"$path|$prefix"$'\n'*) continue ;; esac
      pattern="(^|[^A-Za-z0-9_.-])$(printf '%s' "$prefix" | sed 's/[.]/\\./g')"
      printf '%s\n' "$lines" | grep -E -- "$pattern" | sed "s#^#$path: $prefix: #" || true
    done <<EOF
$PREFIXES
EOF
  done < "$list"
}

# tests_dirs_unlisted <pathlist>: every tests/ directory that is neither listed
# nor on the keep list.
KEEP_TESTS='core-rules/skills/anti-slop/profiles/rust/fixtures/tests/'
tests_dirs_unlisted() {
  local path dir
  while IFS= read -r path; do
    case "/$path" in */tests/*) ;; *) continue ;; esac
    dir="$(printf '/%s\n' "$path" | sed -E 's#^/##; s#^((.*/)?tests/).*#\1#')"
    under_listed_prefix "$dir" && continue
    case "$dir" in "$KEEP_TESTS"*) continue ;; esac
    printf '%s\n' "$dir"
  done < "$1" | LC_ALL=C sort -u
}

repo_file_list() {
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard) > "$BATS_TEST_TMPDIR/files"
}

@test "A3.3 no runtime reference in the real kept tree points into an excluded path" {
  repo_file_list
  run scan_references "$REPO_ROOT" "$BATS_TEST_TMPDIR/files"
  [ -z "$output" ] || { echo "runtime references into excluded paths:"; echo "$output"; false; }
}

@test "A3.3 the scan fails on a real reference and passes on comments, markdown and the list itself" {
  local root="$BATS_TEST_TMPDIR/scan-root"
  mkdir -p "$root/core-rules" "$root/scripts/lib" "$root/docs"
  cp "$REPO_ROOT/core-rules/payload-exclude.txt" "$root/core-rules/"
  printf '#!/usr/bin/env bash\n# see scripts/tests/x.bats for coverage\n  # also scripts/tests/y.bats\necho ok\n' \
    > "$root/scripts/lib/commented.sh"
  printf 'Run scripts/tests/x.bats to check.\n' > "$root/docs/guide.md"
  printf '%s\n' core-rules/payload-exclude.txt scripts/lib/commented.sh docs/guide.md > "$root/list"
  run scan_references "$root" "$root/list"
  [ -z "$output" ] || { echo "harmless mentions were reported: $output"; false; }

  printf '#!/usr/bin/env bash\nbash "$ROOT/scripts/tests/x.bats"\n' > "$root/scripts/lib/real.sh"
  printf '%s\n' scripts/lib/real.sh >> "$root/list"
  run scan_references "$root" "$root/list"
  [[ "$output" == *'scripts/lib/real.sh: scripts/tests/: bash "$ROOT/scripts/tests/x.bats"'* ]] ||
    { echo "a real reference was missed: $output"; false; }
}

@test "A3.3 the scan skips the records directories R3.8 skips, nested receipts included" {
  local root="$BATS_TEST_TMPDIR/records-root" path
  mkdir -p "$root/core-rules"
  # specs/ is off this list, so only the records rule can skip a specs/ path.
  printf 'scripts/tests/\n' > "$root/core-rules/payload-exclude.txt"
  : > "$root/list"
  for path in specs/047-x/receipts/probe.sh specs/047-x/web-search/receipts/t21/probe.sh \
    audits/probe.sh specs/047-x/tool.sh; do
    mkdir -p "$root/${path%/*}"
    printf 'bash "$ROOT/scripts/tests/x.bats"\n' > "$root/$path"
    printf '%s\n' "$path" >> "$root/list"
  done
  run scan_references "$root" "$root/list"
  [ "$output" = 'specs/047-x/tool.sh: scripts/tests/: bash "$ROOT/scripts/tests/x.bats"' ] ||
    { echo "$output"; false; }
}

@test "A3.3 a one-prefix exemption does not hide a different excluded prefix in the same file" {
  local root="$BATS_TEST_TMPDIR/pair-root"
  mkdir -p "$root/core-rules/hooks/lib"
  cp "$REPO_ROOT/core-rules/payload-exclude.txt" "$root/core-rules/"
  printf 'x="specs/001/spec.md"\n. "$ROOT/core-rules/hooks/tests/helper.sh"\n' \
    > "$root/core-rules/hooks/lib/spec-gate-core.sh"
  printf '%s\n' core-rules/hooks/lib/spec-gate-core.sh > "$root/list"
  run scan_references "$root" "$root/list"
  [[ "$output" == *"core-rules/hooks/tests/"* ]] || { echo "$output"; false; }
  [[ "$output" != *": specs/: "* ]] || { echo "$output"; false; }
}

@test "A3.3 every tracked tests/ directory is listed or kept, and an unlisted one fails" {
  repo_file_list
  PREFIXES="$(list_prefixes "$REPO_ROOT")"
  run tests_dirs_unlisted "$BATS_TEST_TMPDIR/files"
  [ -z "$output" ] || { echo "unlisted tests/ directories:"; echo "$output"; false; }

  printf 'core-rules/skills/new-skill/tests/check.sh\n' >> "$BATS_TEST_TMPDIR/files"
  run tests_dirs_unlisted "$BATS_TEST_TMPDIR/files"
  [ "$output" = core-rules/skills/new-skill/tests/ ] || { echo "$output"; false; }
}

# Packaging "the real HEAD" means the tree this checkout would commit: tracked
# and untracked-but-not-ignored files as they stand. The files are copied into
# a scratch repository that borrows this repository's objects through
# alternates, so nothing is written to the real object store or refs, and no
# Git command is routed at the real work tree.
@test "A3.3 packaging the real tree leaves no test file outside the keep list" {
  local scratch="$BATS_TEST_TMPDIR/snapshot" paths="$BATS_TEST_TMPDIR/snapshot.paths"
  local common tree snapshot payload path leftovers=""
  common="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir)"
  payload_fixture_git init -q "$scratch"
  printf '%s\n' "$common/objects" > "$scratch/.git/objects/info/alternates"
  (
    cd "$REPO_ROOT" || exit 1
    git ls-files -co --exclude-standard -z | while IFS= read -r -d '' path; do
      if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\0' "$path"; fi
    done > "$paths"
    tar -cf - --null -T "$paths" | tar -xf - -C "$scratch"
  )
  payload_fixture_git -C "$scratch" update-index --add -z --stdin < "$paths"
  tree="$(payload_fixture_git --git-dir="$scratch/.git" write-tree)"
  snapshot="$(payload_fixture_git --git-dir="$scratch/.git" commit-tree "$tree" -m snapshot)"

  run payload_fixture_tool "$scratch" "$snapshot"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  payload="$output"

  while IFS= read -r path; do
    case "$path" in "$KEEP_TESTS"*) continue ;; esac
    case "${path##*/}" in
      *.test.*|*.spec.*|test_*.py|*_test.py|*.bats) leftovers="$leftovers$path"$'\n' ;;
    esac
  done < <(payload_fixture_git --git-dir="$scratch/.git" ls-tree -r --name-only "$payload")
  [ -z "$leftovers" ] || { echo "test files left in the payload:"; printf '%s' "$leftovers"; false; }
  payload_fixture_git --git-dir="$scratch/.git" cat-file -e "$payload:core-rules/VERSION"
  payload_fixture_git --git-dir="$scratch/.git" cat-file -e \
    "$payload:core-rules/skills/anti-slop/profiles/rust/fixtures/tests/parse.rs"
}

# ---------------------------------------------------------------------------
# A3.7 — the two-stage identity gate
# ---------------------------------------------------------------------------

candidate_setup() {
  payload_fixture_package "$SRC"
  PAYLOAD="$PAYLOAD_FIXTURE_PAYLOAD"
  RELEASE="$PAYLOAD_FIXTURE_RELEASE"
  payload_fixture_origin_main "$SRC" "$RELEASE"
}

@test "A3.7 --verify-candidate accepts the packaged candidate before any tag exists" {
  candidate_setup
  no_tags
  run tool --verify-candidate "$PAYLOAD" "$RELEASE" 7.7.7
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"candidate $PAYLOAD verified against $RELEASE"* ]] || { echo "$output"; false; }
}

@test "A3.7 --verify-candidate refuses a wrong first parent" {
  candidate_setup
  other="$(variant "$RELEASE" "$RELEASE" put:docs/other.md=other)"
  wrong="$(g commit-tree "$(g rev-parse "$PAYLOAD^{tree}")" -p "$other" -m wrong-parent)"
  no_tags
  run tool --verify-candidate "$wrong" "$RELEASE" 7.7.7
  refused 'the first parents of'
}

@test "A3.7 --verify-candidate refuses an extra modified file" {
  candidate_setup
  bad="$(variant "$PAYLOAD" "$RELEASE" put:core-rules/hooks/x.sh=tampered)"
  no_tags
  run tool --verify-candidate "$bad" "$RELEASE" 7.7.7
  refused 'payload changes more than deletions: M core-rules/hooks/x.sh'
}

@test "A3.7 --verify-candidate refuses an extra added file" {
  candidate_setup
  bad="$(variant "$PAYLOAD" "$RELEASE" put:scripts/added.sh=added)"
  no_tags
  run tool --verify-candidate "$bad" "$RELEASE" 7.7.7
  refused 'payload changes more than deletions: A scripts/added.sh'
}

@test "A3.7 --verify-candidate refuses a missing deletion and a deletion outside the list" {
  candidate_setup
  bad="$(variant "$RELEASE" "$RELEASE" rm:scripts/tests/ rm:core-rules/hooks/tests/)"
  no_tags
  run tool --verify-candidate "$bad" "$RELEASE" 7.7.7
  refused 'listed file is not deleted in the payload: specs/001-fixture/spec.md'

  bad="$(variant "$PAYLOAD" "$RELEASE" rm:docs/readme.md)"
  run tool --verify-candidate "$bad" "$RELEASE" 7.7.7
  refused 'payload deletes a file outside the listed paths: docs/readme.md'
}

@test "A3.7 --verify-candidate refuses a VERSION mismatch" {
  candidate_setup
  no_tags
  run tool --verify-candidate "$PAYLOAD" "$RELEASE" 7.7.8
  refused "core-rules/VERSION in $RELEASE is not 7.7.8"
}

@test "A3.7 --verify-candidate refuses an approved commit that is not on the fetched origin/main" {
  candidate_setup
  unrelated="$(variant "$RELEASE" - put:docs/unrelated.md=unrelated)"
  payload_fixture_origin_main "$SRC" "$unrelated"
  no_tags
  run tool --verify-candidate "$PAYLOAD" "$RELEASE" 7.7.7
  refused "approved commit $RELEASE is not on the fetched origin/main"

  g update-ref -d refs/remotes/origin/main
  run tool --verify-candidate "$PAYLOAD" "$RELEASE" 7.7.7
  refused 'refs/remotes/origin/main is absent; run git fetch origin main first'
}

@test "A3.7 --verify-tag accepts the correct annotated tag" {
  candidate_setup
  payload_fixture_tag "$SRC" 7.7.7 "$PAYLOAD"
  run tool --verify-tag v7.7.7 "$RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"tag v7.7.7 verified"* ]] || { echo "$output"; false; }
}

@test "A3.7 --verify-tag refuses a lightweight tag" {
  candidate_setup
  g tag v7.7.7 "$PAYLOAD"
  run tool --verify-tag v7.7.7 "$RELEASE"
  refused 'not an annotated tag: v7.7.7'
}

@test "A3.7 --verify-tag refuses a tag with the wrong name" {
  candidate_setup
  payload_fixture_tag "$SRC" 7.7.8 "$PAYLOAD"
  run tool --verify-tag v7.7.8 "$RELEASE"
  refused 'tag v7.7.8 is not named v7.7.7'

  g tag -a release-7.7.7 -m 'wrong shape' "$PAYLOAD"
  run tool --verify-tag release-7.7.7 "$RELEASE"
  refused 'tag is not named v<VERSION>: release-7.7.7'
}

@test "A3.7 --verify-tag reads the tag name from the header, never the message" {
  candidate_setup
  tag_object="$(printf 'object %s\ntype commit\ntag v7.7.8\ntagger Trellis Fixture <fixture@example.invalid> 1700000000 +0000\n\nrelease 7.7.7\ntag v7.7.7\n' \
    "$PAYLOAD" | g mktag)"
  g update-ref refs/tags/v7.7.7 "$tag_object"
  run tool --verify-tag v7.7.7 "$RELEASE"
  refused 'tag object is not named v7.7.7'
}

@test "A3.7 --verify-tag refuses an annotated tag on a bad candidate" {
  candidate_setup
  bad="$(variant "$PAYLOAD" "$RELEASE" put:scripts/added.sh=added)"
  payload_fixture_tag "$SRC" 7.7.7 "$bad"
  run tool --verify-tag v7.7.7 "$RELEASE"
  refused 'payload changes more than deletions: A scripts/added.sh'
}
