#!/usr/bin/env bats
# Spec 055 R3.8 / A3.8: the off-main tag consumer gate, run before a release cut.
#
# From 1.3.7 a release tag names a payload commit that is NOT on main: its first
# parent is. Any code that finds a release by walking main (describe, ancestry,
# --contains, shallow or single-branch fetches, ls-remote, a refs/tags walk)
# would stop seeing it. The audit in spec 055 found no such consumer; this suite
# keeps it that way. Every hit line of the patterns below, outside the records
# directories, must sit on the reviewed allowlist, and each allowlist entry pins
# the hit lines under it by count and by a digest of their content, so a new,
# changed or extended hit anywhere fails.
#
# The second half proves the one path the audit left unproven: pushing a
# deletions-only payload tag through the managed pre-push, without --no-verify.

setup() {
  local sandbox
  sandbox="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$sandbox/home" TRELLIS_HOME="$sandbox/trellis" TMPDIR="$sandbox/tmp"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$TMPDIR"
}

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
load helpers/payload-fixture

CONSUMER_PATTERNS=(
  'git describe' 'describe --contains' 'is-ancestor' 'branch --contains'
  'tag --contains' '--single-branch' '--depth' 'refs/tags' 'ls-remote'
)

# <path prefix>|<hit lines>|<digest>|<reason>. The longest matching prefix owns
# a hit. <digest> is consumer_digest over the entry's hits: each hit is its path
# and its matched line with the indentation trimmed, so moving a hit is free but
# changing, adding or removing one fails until the entry is re-reviewed. The
# failure prints every hit under the entry and the digest it now has.
CONSUMER_ALLOWLIST='scripts/trace-release-metadata.py|1|23f572761adf933a|audit parser: conservatively recognizes tag-reference file probes in captured logs; no tag discovery or release selection
scripts/lib/release-store.sh|2|b842673ff8b25bae|installer: fetches refs/tags/<tag>:refs/tags/<tag> into a fresh repository, full history, no branch, not shallow
scripts/trellis-launcher.sh|2|056f774f16eb9aa8|launcher bootstrap install: the same explicit tag refspec as the store
scripts/sync-to-template.sh|2|85c7d99542690d3c|mirror: fetches the installed tag by explicit refspec and main beside it (R3.6)
scripts/release-payload-commit.sh|4|44ff032b8536bb6b|identity gate: resolves refs/tags/<tag>; is-ancestor checks the approved commit against the fetched origin/main, never the tag
scripts/lib/push-test-map.py|1|c29d4f80f37d2d3d|push test selection: ancestor check between range endpoint commits, never discovers a release
scripts/lib/worktree-migrate-classify.sh|1|8e5d9e2d3e948a28|migrate classify: merged-PR check between a head and a remote branch tip, no tag discovery
scripts/lib/worktree-migrate-preserve.sh|1|91755fab79e70b04|migrate preserve: reads one refs/heads ref to confirm the preserve push landed, never lists tags
core-rules/githooks/pre-push|4|2cc110527a78aaf2|gate dispatch: verifies only the explicitly pushed release tag before reuse; existing per-ref ranges and containment remain; never discovers a release
core-rules/husky/pre-push|4|658cea39ec0609f9|husky twin: verifies only the explicitly pushed release tag before reuse; existing per-ref ranges and containment remain; never discovers a release
scripts/lib/tag_push_reuse.py|1|4b7a5022032454fa|T31: validates the explicit pushed tag namespace; no latest-tag discovery or ancestry-based release choice
scripts/tests/test_tag_push_reuse.py|2|bf6d6c6fae0f6146|T31 fixtures: one valid explicit release tag and one VERSION-mismatched tag
scripts/tests/test_full_trace.py|2|6dd620a2450f57ea|T32 fixtures: captured fd and relative tag-path operands; no tag discovery or release choice
core-rules/hooks/trellis-worktree-remove.sh|1|97d070632a511735|worktree remove gate: merged-branch check between HEAD and a commit, never walks tags
core-rules/hooks/code-review-subagent.sh|1|b02b974cd3a615a3|delta review: is-ancestor between the last reviewed HEAD and HEAD, never reads a tag
core-rules/codex/hooks/code-review-subagent.sh|1|5a01dade2475be86|codex twin: the same delta-review ancestry check between two commits
core-rules/hooks/tests/spec-gate-cache.bats|1|240120e0d4f4acb3|fixture: creates an unrelated tag ref to prove any ref change invalidates the spec-gate cache key; no release read
core-rules/skills/herdr-foreman/scripts/accept-branch.sh|1|abcaa62ca08b5f1f|is-ancestor between two branch SHAs, no tag involved
core-rules/skills/process-gate/scripts/lib/diff-base.sh|1|f2894e8dac5d879b|is-ancestor between two commits for base refinement, no tag involved
scripts/verify-conductor-spec-inventory.mjs|2|b24ec11275dc1812|is-ancestor between main refs, no tag involved
scripts/tests/helpers/git-fence/git|4|37ec6942f05001b9|test fence: parses --depth and ls-remote as argv shapes, fetches nothing
scripts/tests/helpers/payload-fixture.bash|3|638b0793f379ead0|fixture: pushes fixture tags by explicit refspec; checks refs/tags/v1.3.6 exists before git show
scripts/tests/helpers/historical-releases.bash|1|e545ee0acc6ff758|historical fixture key: resolves only the five explicitly listed old version tags; never discovers a latest release
scripts/tests/pre-push-range.bats|12|82a791dac3bda4db|fixtures: simulated tag ref updates exercise per-tag ranges, branch containment, fail-closed underivable ranges and the unsupported-ref refusal in both carriers
scripts/tests/pre-push-diff-base.bats|3|2d82a0e5e490f878|fixtures: simulated tag ref updates prove a tag-only push skips spec-gate and a branch+tag push hands spec-gate the branch, never the tag
scripts/tests/sync-to-template-dry-run.bats|2|8fbb38a541f590d7|fixture: pushes a fixture tag by explicit refspec
scripts/tests/release-payload-commit.bats|1|652b7a5664ff9f9c|fixture: points the fixture tag ref at a hand-built tag object so --verify-tag reads its header
scripts/tests/user-surface.bats|1|506af448a3090479|fixture: checks the v1.3.9 release tag exists before archiving its shipped runtime
.github/workflows/bats.yml|2|5d6f3d57d87a557c|CI: fetches the v1.3.6 and v1.3.9 tags by explicit refspec, depth 1, for old-runtime probes
CHANGELOG.md|2|1ce69640c1afdd81|prose: the 1.3.11 pre-push notes name the refs/heads/* and refs/tags/* refusal, and the 1.4.0 notes name the T32 trace tools; no consumer
docs/UPGRADING.md|3|b6deba7648e8cf62|prose: tag refs classify push ranges, not release discovery; git describe on main no longer names the newest release, which is cosmetic; the 1.3.11 unsupported-ref refusal names refs/tags/*
AGENT_PI_SETUP.md|1|d115d46558230798|npm list --depth=0, not git
specs/043-pi-harness-adoption/guide/SETUP.md|1|cba8efcdb8435007|npm list --depth=0, not git
specs/019-claude-5-alignment/audit/E-rollout-surface.md|1|5d5738a672fdf831|audit prose: an ls-remote run once by hand
specs/035-repository-debloat/dod-receipt.json|2|0433c9efd3446694|recorded receipt: is-ancestor between two fixed SHAs
specs/047-session-efficiency-cost-transparency/|31|b69fdc0eb6c65f91|spec 047 records: captured URLs and prose about published tags, nothing executed
specs/055-routed-defects/|9|fd1a5e0fc66683eb|this spec: the audit and the pattern list themselves'

# consumer_hits <root> <pathlist>: "<path>\t<hit line, indentation trimmed>" for
# every hit line in each scanned file.
consumer_hits() {
  local root="$1" list="$2" path lines pattern
  local -a args=()
  for pattern in "${CONSUMER_PATTERNS[@]}"; do args+=(-e "$pattern"); done
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    payload_fixture_is_record "$path" && continue
    [ "$path" = scripts/tests/release-tag-consumers.bats ] && continue
    [ -f "$root/$path" ] || continue
    lines="$(grep -IhF "${args[@]}" "$root/$path" 2>/dev/null)" || continue
    printf '%s\n' "$lines" |
      awk -v p="$path" '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print p "\t" $0 }'
  done < "$list"
}

# consumer_digest: the first 16 hex digits of the SHA-256 of the sorted hit
# records on stdin.
consumer_digest() {
  LC_ALL=C sort | shasum -a 256 | cut -c1-16
}

# consumer_verdict <hits-file>: print every unallowlisted hit and every entry
# whose hits moved from what was reviewed; succeed only when there are none.
consumer_verdict() {
  local hits="$1" path line prefix count digest best rc=0 owned found found_count found_digest tab
  tab="$(printf '\t')"
  owned="$(mktemp "$BATS_TEST_TMPDIR/owned.XXXXXX")"
  while IFS= read -r line; do
    path="${line%%"$tab"*}"
    best=""
    while IFS='|' read -r prefix _; do
      case "$path" in "$prefix"*) [ "${#prefix}" -gt "${#best}" ] && best="$prefix" ;; esac
    done <<EOF
$CONSUMER_ALLOWLIST
EOF
    if [ -z "$best" ]; then
      printf 'unallowlisted consumer hit: %s: %s\n' "$path" "${line#*"$tab"}"
      rc=1
      continue
    fi
    printf '%s\t%s\n' "$best" "$line" >> "$owned"
  done < "$hits"
  while IFS='|' read -r prefix count digest _; do
    found="$(awk -F'\t' -v p="$prefix" '$1 == p' "$owned" | cut -f2- | LC_ALL=C sort)"
    found_count="$(printf '%s' "$found" | awk 'END { print NR }')"
    found_digest="$(printf '%s' "$found" | consumer_digest)"
    if [ "$found_count" != "$count" ] || [ "$found_digest" != "$digest" ]; then
      printf 'allowlist entry %s pins %s hit line(s) at %s, found %s at %s: review these hits\n' \
        "$prefix" "$count" "$digest" "$found_count" "$found_digest"
      printf '%s\n' "$found" | sed 's/^/  /'
      rc=1
    fi
  done <<EOF
$CONSUMER_ALLOWLIST
EOF
  return "$rc"
}

repo_hits() {
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard) > "$BATS_TEST_TMPDIR/files"
  consumer_hits "$REPO_ROOT" "$BATS_TEST_TMPDIR/files" > "$BATS_TEST_TMPDIR/hits"
}

# overlay_hits <path> <awk program>: the repository's hits, with <path>'s own
# hits replaced by those of a copy of <path> rewritten by <awk program>.
overlay_hits() {
  local path="$1" program="$2" overlay="$BATS_TEST_TMPDIR/overlay"
  repo_hits
  mkdir -p "$overlay/${path%/*}"
  awk "$program" "$REPO_ROOT/$path" > "$overlay/$path"
  printf '%s\n' "$path" > "$overlay/list"
  awk -F'\t' -v p="$path" '$1 != p' "$BATS_TEST_TMPDIR/hits" > "$BATS_TEST_TMPDIR/hits.overlay"
  consumer_hits "$overlay" "$overlay/list" >> "$BATS_TEST_TMPDIR/hits.overlay"
}

@test "A3.8 every off-main tag consumer pattern in the repository is reviewed" {
  repo_hits
  run consumer_verdict "$BATS_TEST_TMPDIR/hits"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$BATS_TEST_TMPDIR/hits" ]
}

@test "A3.8 an unallowlisted git describe under scripts/ fails the gate" {
  local overlay="$BATS_TEST_TMPDIR/overlay"
  repo_hits
  mkdir -p "$overlay/scripts"
  printf '#!/usr/bin/env bash\nlatest="$(git describe --tags --abbrev=0)"\n' > "$overlay/scripts/latest-release.sh"
  printf 'scripts/latest-release.sh\n' > "$overlay/list"
  consumer_hits "$overlay" "$overlay/list" >> "$BATS_TEST_TMPDIR/hits"
  run consumer_verdict "$BATS_TEST_TMPDIR/hits"
  [ "$status" -eq 1 ]
  [[ "$output" == *'unallowlisted consumer hit: scripts/latest-release.sh: latest="$(git describe --tags --abbrev=0)"'* ]] ||
    { echo "$output"; false; }
}

@test "A3.8 a new hit inside an allowlisted file moves its pinned count and fails" {
  overlay_hits scripts/lib/release-store.sh '{ print } END { print "git fetch --depth=1 origin main" }'
  run consumer_verdict "$BATS_TEST_TMPDIR/hits.overlay"
  [ "$status" -eq 1 ]
  [[ "$output" == *'allowlist entry scripts/lib/release-store.sh pins 2 hit line(s) at '*', found 3 at '* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'  scripts/lib/release-store.sh	git fetch --depth=1 origin main'* ]] || { echo "$output"; false; }
}

@test "A3.8 swapping a reviewed hit for git describe keeps the count and still fails" {
  overlay_hits scripts/lib/release-store.sh \
    '!done && index($0, "refs/tags/$tag:refs/tags/$tag") { print "  latest=\"$(git describe --tags --abbrev=0)\""; done = 1; next } { print }'
  run consumer_verdict "$BATS_TEST_TMPDIR/hits.overlay"
  [ "$status" -eq 1 ]
  [[ "$output" == *'allowlist entry scripts/lib/release-store.sh pins 2 hit line(s) at '*', found 2 at '* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'git describe --tags --abbrev=0'* ]] || { echo "$output"; false; }
}

@test "A3.8 a consumer added to an already-hit line keeps the count and still fails" {
  overlay_hits scripts/lib/release-store.sh \
    '!done && index($0, "refs/tags/$tag:refs/tags/$tag") { print $0 " && git describe --tags --abbrev=0"; done = 1; next } { print }'
  run consumer_verdict "$BATS_TEST_TMPDIR/hits.overlay"
  [ "$status" -eq 1 ]
  [[ "$output" == *'allowlist entry scripts/lib/release-store.sh pins 2 hit line(s) at '*', found 2 at '* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'&& git describe --tags --abbrev=0'* ]] || { echo "$output"; false; }
}

@test "A3.8 the records directories are skipped and nothing else is" {
  local path
  for path in audits/x.md notes/x.md research/x.md receipts/x.json conductor/slate.json \
    specs/047-x/receipts/r.json specs/047-x/web-search/receipts/t21/live.jsonl; do
    payload_fixture_is_record "$path" || { echo "not skipped: $path"; false; }
  done
  for path in scripts/x.sh core-rules/x.sh specs/047-x/context.md docs/audits.md; do
    ! payload_fixture_is_record "$path" || { echo "wrongly skipped: $path"; false; }
  done
}

# The managed pre-push gates a non-main ref by the range it adds: for a new tag
# that is <merge-base with origin/main>..<tag>, here exactly the deletions-only
# payload commit. The real hook and the real process-gate aggregator run, and no
# gate row is stubbed: the fixture declares no typecheck, lint or test command,
# so the Tests row takes its own undeclared-command path. One stack validator is
# configured only to record the range the aggregator hands every gate. The
# instance's own suite is not what this proves: check-tests runs it on the
# working tree on every push, whatever ref is pushed. The real security-gate
# has a committed empty baseline for this clean fixture: a deletions-only range
# is an empty scan, not a missing-gate or missing-baseline skip. The gate reads
# the baseline from the range base, so TAG_FIXTURE_BASELINE=0 leaves it out of
# that commit. Process-gate config is read at the range base too, so it is
# committed there; $1 is an optional extra config line.
tag_push_setup() {
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/trellis-gate-state"
  local hooks="$BATS_TEST_TMPDIR/hooks" gate_local
  WORK="$BATS_TEST_TMPDIR/work"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  GATED_RANGE="$BATS_TEST_TMPDIR/gated-range"
  payload_fixture_source "$WORK" 7.7.7
  if [ "${TAG_FIXTURE_BASELINE:-1}" = 1 ]; then
    mkdir -p "$WORK/audits"
    printf '{"schema":"security-gate.baseline.v2","findings":[],"historical_findings":[]}\n' \
      > "$WORK/audits/2026-01-01-baseline-work.json"
    payload_fixture_git -C "$WORK" add audits
  fi
  gate_local="$WORK/.claude/skills/process-gate-local"
  mkdir -p "$gate_local"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" > %q\n' "$GATED_RANGE" > "$gate_local/record-range.sh"
  printf 'PROCESS_GATE_STACK_PROFILE=range-probe\nPROCESS_GATE_STACK_VALIDATORS=(record-range.sh)\n%s' \
    "${1:+$1
}" > "$gate_local/local.config.sh"
  payload_fixture_git -C "$WORK" add .claude/skills/process-gate-local
  payload_fixture_git -C "$WORK" commit -qm 'commit security baseline and gate config'
  PAYLOAD_FIXTURE_RELEASE="$(payload_fixture_git -C "$WORK" rev-parse HEAD)"
  payload_fixture_git init -q --bare "$REMOTE"
  payload_fixture_git -C "$WORK" remote add origin "$REMOTE"
  payload_fixture_git -C "$WORK" push -q origin main
  payload_fixture_git -C "$WORK" fetch -q origin
  payload_fixture_package "$WORK"
  payload_fixture_tag "$WORK" 7.7.7 "$PAYLOAD_FIXTURE_PAYLOAD"
  run payload_fixture_tool "$WORK" --verify-tag v7.7.7 "$PAYLOAD_FIXTURE_RELEASE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  mkdir -p "$hooks"
  cp "$REPO_ROOT/core-rules/githooks/pre-push" "$hooks/pre-push"
  chmod 755 "$hooks/pre-push"
  cp -R "$REPO_ROOT/core-rules/skills/process-gate" "$WORK/.claude/skills/process-gate"
  cp -R "$REPO_ROOT/core-rules/skills/security-gate" "$WORK/.claude/skills/security-gate"
  mkdir -p "$WORK/.claude/skills/security-gate-local"
  printf 'SECURITY_GATE_PROJECT_NAME=work\n' > "$WORK/.claude/skills/security-gate-local/local.config.sh"
  printf '/.claude/\n' >> "$WORK/.git/info/exclude"
  HOOKS="$hooks"
}

# tag_push: push v7.7.7 through the managed pre-push, never with --no-verify.
# Harness project variables are dropped so the gate judges the fixture, not the
# checkout running this suite.
tag_push() {
  run env -u CLAUDE_PROJECT_DIR -u CODEX_PROJECT_DIR -u SECURITY_GATE_SKIP GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c core.hooksPath="$HOOKS" -C "$WORK" push origin v7.7.7
}

# tag_push_passed: the gate ran on exactly the payload commit, its verdict did
# not block, and the tag reached the remote. Reads $status and $output from
# tag_push.
tag_push_passed() {
  local tag_object
  tag_object="$(payload_fixture_git -C "$WORK" rev-parse v7.7.7)"
  [ "$status" -eq 0 ] || { echo "push exited $status"; return 1; }
  [[ "$output" == *'[pre-push] Trellis verification starting (mode=push)'* ]] || { echo 'the hook did not run'; return 1; }
  [[ "$output" == *'## process-gate verdict (mode=push)'* ]] || { echo 'no gate verdict'; return 1; }
  printf '%s\n' "$output" | grep -Eq '^Security \(diff\):.*✅ pass$' ||
    { echo 'the real security diff did not pass'; return 1; }
  printf '%s\n' "$output" | grep -Eqx 'Overall: (MERGEABLE|NEEDS CHANGES)' ||
    { echo 'the verdict is neither MERGEABLE nor NEEDS CHANGES'; return 1; }
  [ "$(cat "$GATED_RANGE" 2>/dev/null)" = "--range=$PAYLOAD_FIXTURE_RELEASE..$tag_object" ] ||
    { echo "the gate judged $(cat "$GATED_RANGE" 2>/dev/null), not $PAYLOAD_FIXTURE_RELEASE..$tag_object"; return 1; }
  [ "$(payload_fixture_git -C "$WORK" rev-list "$PAYLOAD_FIXTURE_RELEASE..$tag_object")" = "$PAYLOAD_FIXTURE_PAYLOAD" ] ||
    { echo 'the gated range is not exactly the payload commit'; return 1; }
  [ "$(payload_fixture_git --git-dir="$REMOTE" rev-parse -q --verify 'v7.7.7^{commit}')" = "$PAYLOAD_FIXTURE_PAYLOAD" ] ||
    { echo 'the tag is not on the remote'; return 1; }
  [ "$(payload_fixture_git --git-dir="$REMOTE" cat-file -t v7.7.7)" = tag ] || { echo 'the remote tag is not annotated'; return 1; }
}

@test "A3.8 a payload tag pushes through the managed pre-push and its real gate verdict does not block" {
  tag_push_setup
  tag_push
  echo "$output"
  tag_push_passed
}

@test "A3.8 a BLOCKED gate verdict on the payload tag push fails the proof" {
  tag_push_setup 'PROCESS_GATE_TEST_CMD=false'
  tag_push
  [[ "$output" == *'Overall: BLOCKED'* ]] || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -Eq '^Security \(diff\):.*✅ pass$'
  run tag_push_passed
  [ "$status" -ne 0 ] || { echo 'a blocked push passed the proof'; false; }
  [[ "$output" == 'push exited 1' ]] || { echo "$output"; false; }
  run payload_fixture_git --git-dir="$REMOTE" rev-parse -q --verify refs/tags/v7.7.7
  [ "$status" -ne 0 ]
}

@test "A3.8 a payload tag push without its security baseline is blocked" {
  TAG_FIXTURE_BASELINE=0 tag_push_setup
  tag_push
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  grep -qF 'baseline required (BLOCKED)' <<<"$output"
  printf '%s\n' "$output" | grep -Eq '^Security \(diff\):.*❌ fail$'
  run payload_fixture_git --git-dir="$REMOTE" rev-parse -q --verify refs/tags/v7.7.7
  [ "$status" -ne 0 ]
}
