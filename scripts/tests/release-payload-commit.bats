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

@test "A3.2 packaging from a subdirectory produces the same filtered payload" {
  local from_root from_subdir
  from_root="$(tool "$PAYLOAD_FIXTURE_RELEASE")"
  run bash -c 'cd "$1/scripts" && bash "$2/scripts/release-payload-commit.sh" "$3"' \
    _ "$SRC" "$REPO_ROOT" "$PAYLOAD_FIXTURE_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  from_subdir="$output"
  [ "$from_subdir" = "$from_root" ] || { echo "subdirectory built a different payload"; false; }
  payload_fixture_origin_main "$SRC" "$PAYLOAD_FIXTURE_RELEASE"
  run bash -c 'cd "$1/scripts" && bash "$2/scripts/release-payload-commit.sh" --verify-candidate "$3" "$4" 7.7.7' \
    _ "$SRC" "$REPO_ROOT" "$from_subdir" "$PAYLOAD_FIXTURE_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # Relative invocation must still find its usage text after changing cwd.
  cp "$REPO_ROOT/scripts/release-payload-commit.sh" "$SRC/scripts/payload-tool.sh"
  run bash -c 'cd "$1/scripts" && bash payload-tool.sh --verify-candidate' _ "$SRC"
  [ "$status" -eq 2 ] && [[ "$output" == *'Usage:'* ]] || { echo "$output"; false; }
}

@test "A3.7 an unfiltered payload is refused when verification starts in a subdirectory" {
  local tree unfiltered
  payload_fixture_origin_main "$SRC" "$PAYLOAD_FIXTURE_RELEASE"
  tree="$(g rev-parse "$PAYLOAD_FIXTURE_RELEASE^{tree}")"
  unfiltered="$(g commit-tree "$tree" -p "$PAYLOAD_FIXTURE_RELEASE" -m unfiltered)"
  run bash -c 'cd "$1/scripts" && bash "$2/scripts/release-payload-commit.sh" --verify-candidate "$3" "$4" 7.7.7' \
    _ "$SRC" "$REPO_ROOT" "$unfiltered" "$PAYLOAD_FIXTURE_RELEASE"
  refused 'listed file is not deleted'
}

@test "A3.2 a list naming only empty Git trees is refused" {
  local empty version list core tree release
  empty="$(g mktree < /dev/null)"
  version="$(g rev-parse "$PAYLOAD_FIXTURE_RELEASE:core-rules/VERSION")"
  list="$(printf 'empty/\n' | g hash-object -w --stdin)"
  core="$(printf '100644 blob %s\tVERSION\n100644 blob %s\tpayload-exclude.txt\n' "$version" "$list" | g mktree)"
  tree="$(printf '040000 tree %s\tcore-rules\n040000 tree %s\tempty\n' "$core" "$empty" | g mktree)"
  release="$(g commit-tree "$tree" -p "$PAYLOAD_FIXTURE_RELEASE" -m 'empty excluded tree')"
  run tool "$release"
  refused 'exclusion list contains no files'
  payload_fixture_origin_main "$SRC" "$release"
  unfiltered="$(g commit-tree "$tree" -p "$release" -m unfiltered)"
  run tool --verify-candidate "$unfiltered" "$release" 7.7.7
  refused 'exclusion list contains no files'
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
# The baseline was found by the 1.5.1 T45 battery, exempt for the same reason:
#   scripts/lint-shell-assignments-baseline.json
#                                   that lint's baseline: source paths it
#                                   scans, never read by an installed payload.
SCAN_EXEMPT_FILES='scripts/run-tests.sh
scripts/lib/test-suites.sh
scripts/lib/mirror-lint.sh
scripts/sync-to-template.sh
scripts/check-mirror-preseal.sh
scripts/pi-web-search-tests.sh
core-rules/skills/process-gate/scripts/check-tests.sh
scripts/harness-conformance.py
scripts/lint-shell-tree.sh
scripts/lint-shell-assignments-baseline.json'

# <file>|<prefix> pairs exempt for ONE prefix only, so any other excluded prefix
# in the same file still fails. Each names the attached PROJECT's own specs/
# tree, resolved against a project root (or describes it in a config comment),
# never the payload's specs/, which a payload has never needed. The checkout-only
# test selector and contained runner name source test inventory, not payload data;
# so do the runner's exact-input verdict, tag-push reuse (it reads the audit from
# the tag's Git tree) and the maintainer-run metadata trace and weight refresh,
# whose specs/ default is the source checkout's own timing evidence. The Bats
# conditional lint names scripts/tests/fixtures/ only to drop fixture suites from
# its own ls-files listing; it never reads that tree.
# The runner's verdict also binds the source checkout's native/trellis-hooks/
# Cargo.lock, only for scripts/run-tests-local.py (native_cargo_identity).
SCAN_EXEMPT_PAIRS='core-rules/hooks/lib/spec-gate-core.sh|specs/
scripts/check-gate-inventory.sh|scripts/tests/
scripts/lib/push-test-map.py|scripts/tests/
scripts/lint-bats-conditionals.py|scripts/tests/
scripts/run-tests-local.py|scripts/tests/
scripts/lib/gate_verdict.py|scripts/tests/
scripts/lib/gate_verdict.py|core-rules/hooks/tests/
scripts/lib/gate_verdict.py|core-rules/codex/hooks/tests/
scripts/lib/gate_verdict.py|native/
scripts/lib/tag_push_reuse.py|scripts/tests/
scripts/trace-release-metadata.py|scripts/tests/
scripts/refresh-stage-weights.py|scripts/tests/
scripts/refresh-stage-weights.py|specs/
core-rules/skills/process-gate/scripts/check-analyze.sh|specs/
core-rules/skills/orchestrate/recipes/conductor.wf.js|specs/
core-rules/skills/orchestrate/recipes/digest-adopt.wf.js|specs/
scripts/verify-conductor-spec-inventory.mjs|specs/
scripts/lib/trellis.config.schema.json|specs/
trellis.config.json|specs/
scripts/build-native-hooks.sh|native/'

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
  local root="$1" list="$2" path prefix pattern base any lines prefix_lines
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
      prefix_lines="$lines"
      # Source hashes are provenance, not runtime reads, whatever their prefix
      # (T71: include_str! edges include test-only data). Keep every other
      # manifest field in the scan, including the executable asset paths.
      if [ "$path" = core-rules/native/artifacts.json ]; then
        prefix_lines="$(jq 'del(.inputs)' "$root/$path")" || return 1
      fi
      if [ "$prefix" = native/ ]; then
        # These two nested directories are runtime assets/install entries,
        # never the excluded root workspace. Replace tokens, not whole lines:
        # a real root native/ reference on the same line must still fail.
        prefix_lines="$(printf '%s\n' "$prefix_lines" | sed -E 's#(core-rules|bin)/native/#\1/@native-runtime/#g')"
      fi
      printf '%s\n' "$prefix_lines" | grep -E -- "$pattern" | sed "s#^#$path: $prefix: #" || true
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

@test "A3.3 native runtime paths and source provenance do not hide real root source dependencies" {
  local root="$BATS_TEST_TMPDIR/native-scan"
  mkdir -p "$root/core-rules/native" "$root/scripts"
  printf 'native/\nscripts/tests/\n' > "$root/core-rules/payload-exclude.txt"
  printf '{"inputs":{"native/src/main.rs":"hash"},"install_path":"bin/native/hash/trellis-hooks","assets":{"arm":{"path":"arm/trellis-hooks"}}}\n' \
    > "$root/core-rules/native/artifacts.json"
  printf 'crate="native/src"\n' > "$root/scripts/build-native-hooks.sh"
  printf 'asset="$ROOT/core-rules/native/arm/trellis-hooks"; installed="$HOME/bin/native/hash/trellis-hooks"\n' \
    > "$root/scripts/runtime.sh"
  printf '%s\n' core-rules/native/artifacts.json scripts/build-native-hooks.sh scripts/runtime.sh > "$root/list"
  run scan_references "$root" "$root/list"
  [ -z "$output" ] || { echo "$output"; false; }

  printf 'asset="$ROOT/core-rules/native/arm/trellis-hooks"; . "$ROOT/native/src/helper.sh"\n' \
    >> "$root/scripts/runtime.sh"
  run scan_references "$root" "$root/list"
  [[ "$output" == *'scripts/runtime.sh: native/: '*'$ROOT/native/src/helper.sh'* ]] || { echo "$output"; false; }

  # Even the provenance manifest's actual executable path is not exempt.
  printf '{"inputs":{"native/src/main.rs":"hash"},"assets":{"arm":{"path":"native/src/helper.sh"}}}\n' \
    > "$root/core-rules/native/artifacts.json"
  printf 'tests="scripts/tests/injected.bats"\n' >> "$root/scripts/build-native-hooks.sh"
  run scan_references "$root" "$root/list"
  [[ "$output" == *'core-rules/native/artifacts.json: native/: '* ]] || { echo "$output"; false; }
  [[ "$output" == *'scripts/build-native-hooks.sh: scripts/tests/: '* ]] || { echo "$output"; false; }
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

@test "A3.3 source-checkout selectors exempt only their test inventory references" {
  local root="$BATS_TEST_TMPDIR/selector-root" path
  mkdir -p "$root/core-rules" "$root/scripts/lib"
  cp "$REPO_ROOT/core-rules/payload-exclude.txt" "$root/core-rules/"
  for path in scripts/lib/push-test-map.py scripts/run-tests-local.py scripts/lib/gate_verdict.py \
    scripts/lib/tag_push_reuse.py scripts/trace-release-metadata.py; do
    printf 'tests="scripts/tests/x.bats"\nother="specs/001/spec.md"\n' > "$root/$path"
    printf '%s\n' "$path" > "$root/list"
    run scan_references "$root" "$root/list"
    [ "$output" = "$path: specs/: other=\"specs/001/spec.md\"" ] || { echo "$output"; false; }
  done
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
