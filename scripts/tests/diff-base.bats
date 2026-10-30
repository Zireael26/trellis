#!/usr/bin/env bats
# diff-base.bats — resolver tiers, refinement, CLI and receipt (spec 067 T3/T4).
# Each case names the resolver branch whose removal or inversion makes it fail.
# Style: one assertion per line; no `[ ] && [ ]` chains.

DB="$BATS_TEST_DIRNAME/../../core-rules/skills/process-gate/scripts/lib/diff-base.sh"
RECEIPT_RE='^diff-base: ([0-9a-f]{12}|-) ([^ ]+) via (explicit|pr-cache|recorded|reflog|upstream|default|refused) \(.*\) range=([^ ]+) head=([^ ]+)$'

mk() {
  R="$BATS_TEST_TMPDIR/repo-$BATS_TEST_NUMBER"
  rm -rf "$R"
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.invalid
  git -C "$R" config user.name t
  REPO="$R"
  cd "$R" || return 1
}

snap() {
  printf '%s\n' "$1" > "$REPO/$1.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}

assert_receipt() {
  printf '%s' "$1" | grep -Eq "$RECEIPT_RE"
}

rr() {
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
}

@test "stacked B on A resolves to A tip, range covers b1 only" {
  # Inversion: removing tier 2 makes this fall to main and include a1 a2.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  snap a2 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b feature/a
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  printf '%s' "$output" | grep -q "DB_SOURCE=recorded"
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  [ "$(git -C "$REPO" log --oneline "$ATIP..HEAD" | wc -l | tr -d ' ')" = "1" ]
}

@test "main advanced: SHA range hides m2, log and diff agree" {
  # Inversion: using ref..HEAD (two-dot tree diff) lists m2 as a deletion.
  mk
  snap m0 >/dev/null
  M0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/a "$M0"
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  git -C "$REPO" checkout -q main
  printf 'm2\n' > "$REPO/m2.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm m1
  git -C "$REPO" checkout -q feature/b
  RANGE="$(bash "$DB" resolve --format=kv | grep DB_RANGE | cut -d= -f2)"
  [ -n "$RANGE" ]
  case "$RANGE" in *..HEAD|main..*|*main*) false ;; *) true ;; esac
  run git -C "$REPO" diff --name-only "$RANGE"
  [ "$status" -eq 0 ]
  case "$output" in *m2.txt*) false ;; *) true ;; esac
  [ "$(git -C "$REPO" diff --name-only "$RANGE" | sort | tr '\n' ',')" = "$(git -C "$REPO" log --format= --name-only "$RANGE" | grep . | sort -u | tr '\n' ',')" ]
  rr
}

@test "parent amended: fork-point excludes old a2" {
  # Inversion: dropping --fork-point loses the fork-point reason (step 4 gives recorded-newer instead).
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  snap a2 >/dev/null
  AOLD="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$AOLD"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$AOLD"
  git -C "$REPO" checkout -q feature/a
  printf 'amended\n' >> "$REPO/a2.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit --amend -qm "a2 amended"
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$AOLD"
  [ "$(git -C "$REPO" log --oneline "$AOLD..HEAD" | wc -l | tr -d ' ')" = "1" ]
  rr
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "fork-point"
}

@test "parent regular-merged and kept gives default" {
  # Inversion: removing step 2b keeps source recorded instead of default.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  snap a2 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff feature/a -m "merge a" -q
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "via default"
  printf '%s' "$output" | grep -q "merged → default"
}

@test "parent regular-merged and deleted gives default" {
  # Inversion: removing step 2a first arm loses the merged→default reason.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --no-ff feature/a -m "merge a" -q
  git -C "$REPO" branch -D feature/a
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "via default"
  printf '%s' "$output" | grep -q "merged → default"
}

@test "parent squash-merged and deleted uses recorded SHA" {
  # Inversion: falling back to default here puts all of A back in the range.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  snap a2 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --squash feature/a >/dev/null 2>&1
  git -C "$REPO" commit -qm "squash a"
  git -C "$REPO" branch -D feature/a
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  printf '%s' "$output" | grep -q "DB_SOURCE=recorded"
  printf '%s' "$output" | grep -q "gone; recorded sha"
  [ "$(git -C "$REPO" log --oneline "$ATIP..HEAD" | wc -l | tr -d ' ')" = "1" ]
  rr
}

@test "parent squash-merged and kept uses P tip" {
  # Inversion: misreading squash-kept as merged gives main merge-base, not A tip.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge --squash feature/a >/dev/null 2>&1
  git -C "$REPO" commit -qm "squash a"
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  printf '%s' "$output" | grep -q "DB_SOURCE=recorded"
  rr
}

@test "parent deleted with no record gives default with no-record reason" {
  # Inversion: removing step 2a third arm refuses instead of using default.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  git -C "$REPO" checkout -qb feature/b feature/a
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" branch -D feature/a
  # No recorder hook is installed in this fixture, so no trellisBase was ever
  # written; tolerate an already-absent key while ensuring no record remains.
  git -C "$REPO" config --unset branch.feature/b.trellisBase 2>/dev/null || true
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "via default"
  printf '%s' "$output" | grep -q "deleted; no record"
}

@test "B rebased: stale recorded base ignored" {
  # Inversion: using the stale base builds a range from a non-ancestor SHA.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" checkout -q main
  snap m1 >/dev/null
  M1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q feature/b
  git -C "$REPO" config branch.feature/b.trellisBase "$M1"
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "recorded base stale (branch rebased)"
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  case "$output" in *"DB_BASE_SHA=$M1"*) false ;; *) true ;; esac
}

@test "detached HEAD skips tiers 1-3" {
  # Inversion: trying tiers with no branch reads empty config and misresolves.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  git -C "$REPO" checkout --detach HEAD
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "detached HEAD"
  printf '%s' "$output" | grep -q "head=detached"
}

@test "scratch clone: merge refuses, export reproduces the range" {
  # Inversion: allowing tier 4 in merge mode would silently gate the wrong base.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b feature/a
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  EXP="$(bash "$DB" export)"
  case "$EXP" in --range=*) true ;; *) false ;; esac
  git clone -q --branch feature/b "$REPO" "$BATS_TEST_TMPDIR/clone-$BATS_TEST_NUMBER" 2>/dev/null
  cd "$BATS_TEST_TMPDIR/clone-$BATS_TEST_NUMBER"
  git config user.email t@t.invalid
  git config user.name t
  run bash "$DB" resolve --mode=merge --format=receipt
  [ "$status" -ne 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "via refused"
  RNG="${EXP#--range=}"
  run bash "$DB" resolve --mode=merge --range="$RNG" --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "via explicit"
  printf '%s' "$output" | grep -q "range=$RNG"
}

@test "push -u upstream-is-self is skipped" {
  # Inversion: using self-upstream gives an empty range instead of default.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/b
  snap b1 >/dev/null
  git -C "$REPO" config remote.origin.url https://example.invalid/r.git
  git -C "$REPO" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$REPO" update-ref refs/remotes/origin/feature/b HEAD
  git -C "$REPO" update-ref refs/remotes/origin/main main
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$REPO" config branch.feature/b.remote origin
  git -C "$REPO" config branch.feature/b.merge refs/heads/feature/b
  rm -f "$REPO/.git/logs/refs/heads/feature/b"
  git checkout -q feature/b
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_SOURCE=default"
  case "$output" in *DB_SOURCE=upstream*) false ;; *) true ;; esac
  rr
}

@test "upstream naming another branch is used" {
  # Inversion: removing tier 3 falls to default instead of the upstream parent.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  rm -f "$REPO/.git/logs/refs/heads/feature/b"
  git -C "$REPO" config remote.origin.url https://example.invalid/r.git
  git -C "$REPO" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  git -C "$REPO" update-ref refs/remotes/origin/feature/a "$ATIP"
  git -C "$REPO" config branch.feature/b.remote origin
  git -C "$REPO" config branch.feature/b.merge refs/heads/feature/a
  git checkout -q feature/b
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_SOURCE=upstream"
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  rr
  git -C "$REPO" branch --set-upstream-to=feature/a
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_SOURCE=upstream"
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  rr
}

@test "Created from HEAD uses the HEAD checkout source" {
  # Inversion: unanchored HEAD match takes feature/b-extra; dropping tier 2b falls to main.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" checkout -qb feature/b-extra
  snap extra >/dev/null
  git -C "$REPO" checkout -q feature/a
  git -C "$REPO" checkout -qb feature/b
  snap b1 >/dev/null
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_SOURCE=reflog"
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  rr
}

@test "no remote uses local main labelled no remote" {
  # Inversion: preferring origin/main here would refuse with no remote present.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/b main
  snap b1 >/dev/null
  rm -f "$REPO/.git/logs/refs/heads/feature/b"
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "no remote"
  printf '%s' "$output" | grep -q "via default"
}

@test "origin HEAD differing from policy prefers policy" {
  # Inversion: reading origin/HEAD first would pick main instead of trunk.
  # The policy is the remote default's, so it is committed under m0.
  mk
  printf '{"template":{"branch":"trunk"}}' > "$REPO/.trellis.json"
  snap m0 >/dev/null
  M0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb trunk "$M0"
  snap t1 >/dev/null
  TTIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" update-ref refs/remotes/origin/main "$M0"
  git -C "$REPO" update-ref refs/remotes/origin/trunk "$TTIP"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$REPO" checkout -qb feature/b "$M0"
  snap b1 >/dev/null
  rm -f "$REPO/.git/logs/refs/heads/feature/b"
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_REF=origin/trunk"
  printf '%s' "$output" | grep -q "policy trunk"
  rr
}

@test "PR cache wins and prints both when it differs" {
  # Inversion: removing tier 1 uses recorded main instead of pr-cache feature/a.
  mk
  snap m0 >/dev/null
  M0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/a "$M0"
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
  git -C "$REPO" checkout -qb feature/b "$ATIP"
  snap b1 >/dev/null
  git -C "$REPO" config branch.feature/b.trellisParent main
  git -C "$REPO" config branch.feature/b.trellisBase "$M0"
  git -C "$REPO" config branch.feature/b.trellisPrBase feature/a
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_SOURCE=pr-cache"
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "pr-cache feature/a (recorded: main)"
}

@test "explicit range stays verbatim and flags non-ancestor start" {
  # Inversion: merge-base normalizing would rewrite main..HEAD to SHA..HEAD.
  mk
  snap m0 >/dev/null
  M0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$M0"
  snap b1 >/dev/null
  git -C "$REPO" checkout -q main
  snap m1 >/dev/null
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --range=main..HEAD --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_RANGE=main..HEAD"
  printf '%s' "$output" | grep -q "DB_SOURCE=explicit"
  run bash "$DB" resolve --range=main..HEAD --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "start not ancestor of head"
  printf '%s' "$output" | grep -q "range=main..HEAD"
}

@test "explicit base resolves to merge-base" {
  # Inversion: using the base tip directly would include main's new commits.
  mk
  snap m0 >/dev/null
  M0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b "$M0"
  snap b1 >/dev/null
  git -C "$REPO" checkout -q main
  snap m1 >/dev/null
  MB="$(git -C "$REPO" merge-base main feature/b)"
  git -C "$REPO" checkout -q feature/b
  run bash "$DB" resolve --base=main --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$MB"
  printf '%s' "$output" | grep -q "DB_SOURCE=explicit"
  case "$output" in *"DB_RANGE=main..HEAD"*) false ;; *) true ;; esac
  rr
}

@test "receipt regex enforces field order" {
  # Inversion: loosening the regex would accept a reordered receipt line.
  mk
  snap m0 >/dev/null
  run bash "$DB" resolve --format=receipt
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  SWAPPED="$(printf '%s' "$output" | sed 's/via \(.*\) range=/range=X via \1 /')"
  SWAPPED_FILE="$BATS_TEST_TMPDIR/swapped-$BATS_TEST_NUMBER"
  printf '%s' "$SWAPPED" > "$SWAPPED_FILE"
  run grep -Eq "$RECEIPT_RE" "$SWAPPED_FILE"
  [ "$status" -ne 0 ]
}

@test "set overrides tier 2 and clear removes it" {
  # Inversion: set writing the wrong key leaves tier 2 unchanged; dash refs need exact parsing.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/a
  snap a1 >/dev/null
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  # Stack B on A: set records the fork point (merge-base), which equals the
  # parent tip only when B contains A. A sibling branched from main would
  # record main instead of ATIP.
  git -C "$REPO" checkout -qb feature/b feature/a
  snap b1 >/dev/null
  run bash "$DB" set feature/a --ref feature/b
  [ "$status" -eq 0 ]
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "DB_BASE_SHA=$ATIP"
  printf '%s' "$output" | grep -q "DB_SOURCE=recorded"
  run bash "$DB" show --ref feature/b
  [ "$status" -eq 0 ]
  assert_receipt "$output"
  run bash "$DB" set main --ref --feature
  [ "$status" -eq 0 ]
  run git -C "$REPO" config --get branch.--feature.trellisParent
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  run bash "$DB" set -- main --ref feature/b
  [ "$status" -eq 0 ]
  run bash "$DB" clear --ref feature/b
  [ "$status" -eq 0 ]
  run git -C "$REPO" config --get branch.feature/b.trellisParent
  [ "$status" -ne 0 ]
}

@test "clear preserves upstream remote and merge configuration" {
  # Inversion: git config --remove-section deletes branch tracking metadata.
  mk
  snap m0 >/dev/null
  git -C "$REPO" checkout -qb feature/b
  git -C "$REPO" config branch.feature/b.remote origin
  git -C "$REPO" config branch.feature/b.merge refs/heads/feature/b
  run bash "$DB" set main --ref feature/b
  [ "$status" -eq 0 ]
  run bash "$DB" clear --ref feature/b
  [ "$status" -eq 0 ]
  run git -C "$REPO" config --get branch.feature/b.trellisParent
  [ "$status" -ne 0 ]
  run git -C "$REPO" config --get branch.feature/b.remote
  [ "$status" -eq 0 ]
  [ "$output" = "origin" ]
  run git -C "$REPO" config --get branch.feature/b.merge
  [ "$status" -eq 0 ]
  [ "$output" = "refs/heads/feature/b" ]
}

@test "sourcing does not enable set -u" {
  # Inversion: unconditional set -u would add u to $- when sourced from set +u.
  run bash -c 'set +u; . "$1"; case "$-" in *u*) exit 1 ;; *) exit 0 ;; esac' _ "$DB"
  [ "$status" -eq 0 ]
}

@test "nothing resolvable fails push and refuses merge" {
  # Inversion: falling back to HEAD~1 would silently pass instead of failing.
  mk
  git -C "$REPO" checkout -qb feature
  snap x >/dev/null
  rm -f "$REPO/.git/logs/refs/heads/feature"
  git -C "$REPO" branch -D main 2>/dev/null || true
  run bash "$DB" resolve --format=receipt
  [ "$status" -ne 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "via refused"
  printf '%s' "$output" | grep -q "range=-"
  run bash "$DB" resolve --mode=merge --format=receipt
  [ "$status" -ne 0 ]
  assert_receipt "$output"
  printf '%s' "$output" | grep -q "merge mode requires --range/--base"
}

# BGSEC-A: template.branch is read from the remote default's tree, never from
# the checkout under test, and must name a branch there; anything else refuses.
# bgsec_base <policy|->: s0 then m0 on main (m0 carries <policy>; `sha` and
# `short` name s0), origin/main at m0, then feature/x with the payload a1.
bgsec_base() {
  local pol="$1"
  mk || return 1
  S0="$(snap s0)" || return 1
  case "$pol" in sha) pol="$S0" ;; short) pol="${S0:0:7}" ;; esac
  if [ "$pol" != - ]; then
    printf '{"template":{"branch":"%s"}}\n' "$pol" > "$REPO/.trellis.json" || return 1
  fi
  M0="$(snap m0)" || return 1
  git -C "$REPO" update-ref refs/remotes/origin/main "$M0" || return 1
  git -C "$REPO" checkout -qb feature/x || return 1
  A="$(snap a1)" || return 1
}

# range_policy <policy>: commit B, which sets template.branch in the range.
range_policy() {
  printf '{"template":{"branch":"%s"}}\n' "$1" > "$REPO/.trellis.json" || return 1
  git -C "$REPO" add .trellis.json || return 1
  git -C "$REPO" commit -qm policy || return 1
  B="$(git -C "$REPO" rev-parse HEAD)" || return 1
}

kv() {
  printf '%s\n' "$output" | sed -n "s/^DB_$1=//p"
}

@test "BGSEC-A a range-carried template.branch of HEAD cannot empty the resolved range" {
  # Inversion: reading the checkout's policy resolves B..B, an empty range.
  bgsec_base -
  range_policy HEAD
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = "$M0..$B" ]
  [ "$(kv BASE_REF)" = origin/main ]
}

@test "BGSEC-A a range-carried template.branch naming an in-range sha cannot narrow the range" {
  # Inversion: accepting a revspec as the policy branch resolves A..B.
  bgsec_base -
  range_policy "$A"
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = "$M0..$B" ]
}

@test "BGSEC-A a range-carried template.branch naming an existing remote branch is ignored" {
  # Inversion: the checkout's policy picks origin/side, which holds a1.
  bgsec_base -
  git -C "$REPO" update-ref refs/remotes/origin/side "$A"
  range_policy side
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = "$M0..$B" ]
  [ "$(kv BASE_REF)" = origin/main ]
}

@test "BGSEC-A no range-carried @, abbreviated sha or option-shaped policy narrows the range" {
  # Inversion: any of them read from the checkout gives B..B or A..B.
  local pol
  for pol in @ short --all; do
    bgsec_base - || return 1
    case "$pol" in short) range_policy "${A:0:7}" ;; *) range_policy "$pol" ;; esac || return 1
    run bash "$DB" resolve --format=kv
    [ "$status" -eq 0 ] || { echo "policy $pol: $output"; return 1; }
    [ "$(kv RANGE)" = "$M0..$B" ] || { echo "policy $pol: $output"; return 1; }
  done
}

@test "BGSEC-A a base template.branch that is not a branch on the remote refuses" {
  # Inversion: resolving it as a revspec, or falling back, yields a range.
  local pol
  for pol in HEAD @ sha short --all refs/pull/1/head main~0 develop; do
    bgsec_base "$pol" || return 1
    case "$pol" in
      refs/pull/1/head) git -C "$REPO" update-ref refs/pull/1/head "$A" || return 1 ;;
      develop) git -C "$REPO" branch develop "$A" || return 1 ;;
    esac
    run bash "$DB" resolve --format=kv
    [ "$status" -eq 1 ] || { echo "policy $pol: $output"; return 1; }
    [ "$(kv SOURCE)" = refused ] || { echo "policy $pol: $output"; return 1; }
    [ -z "$(kv RANGE)" ] || { echo "policy $pol: $output"; return 1; }
    [[ "$output" == *"no diff base resolvable; pass --range"* ]] || { echo "policy $pol: $output"; return 1; }
  done
}

@test "BGSEC-A an explicit --range stays verbatim when the base policy is not a branch" {
  # Inversion: consulting the policy before an explicit range refuses it.
  bgsec_base HEAD
  run bash "$DB" resolve --range=origin/main..HEAD --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = origin/main..HEAD ]
}

@test "BGSEC-A a base template.branch of main resolves as before and the checkout's is never read" {
  # Inversion: reading the worktree's .trellis.json resolves A..A.
  bgsec_base main
  rm -f "$REPO/.git/logs/refs/heads/feature/x"
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = "$M0..$A" ]
  [ "$(kv REASON)" = "policy main" ]
  printf '{"template":{"branch":"HEAD"}}\n' > "$REPO/.trellis.json"
  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = "$M0..$A" ]
  [ "$(kv REASON)" = "policy main" ]
}

@test "BGSEC-A the runtime's template.branch, absent on a master-only remote, defers to the remote default" {
  # Inversion: refusing the undeclared runtime default refuses every first push
  # of a master-only project; accepting a non-branch runtime value resolves it.
  mk
  git -C "$REPO" branch -m main master
  M0="$(snap m0)"
  git -C "$REPO" update-ref refs/remotes/origin/master "$M0"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  git -C "$REPO" checkout -qb feature/x
  A="$(snap a1)"
  rm -f "$REPO/.git/logs/refs/heads/feature/x"
  mkdir -p "$BATS_TEST_TMPDIR/runtime"
  printf '{"template":{"branch":"main"}}' > "$BATS_TEST_TMPDIR/runtime/trellis.config.json"
  run env TRELLIS_ROOT="$BATS_TEST_TMPDIR/runtime" bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv RANGE)" = "$M0..$A" ]
  [ "$(kv BASE_REF)" = origin/master ]
  printf '{"template":{"branch":"HEAD"}}' > "$BATS_TEST_TMPDIR/runtime/trellis.config.json"
  run env TRELLIS_ROOT="$BATS_TEST_TMPDIR/runtime" bash "$DB" resolve --format=kv
  [ "$status" -eq 1 ]
  [ "$(kv SOURCE)" = refused ]
}

@test "origin HEAD beats the runtime main default even when origin main exists" {
  mk
  M0="$(snap m0)"
  git update-ref refs/remotes/origin/main "$M0"
  git checkout -qb feat/slice-1-contracts
  TRUNK="$(snap contracts)"
  git update-ref refs/remotes/origin/feat/slice-1-contracts "$TRUNK"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat/slice-1-contracts
  git checkout -qb feature/x
  A="$(snap child)"
  git config branch.feature/x.trellisParent main
  git config branch.feature/x.trellisBase "$M0"
  mkdir -p "$BATS_TEST_TMPDIR/runtime"
  printf '{"template":{"branch":"main"}}\n' > "$BATS_TEST_TMPDIR/runtime/trellis.config.json"

  run env TRELLIS_ROOT="$BATS_TEST_TMPDIR/runtime" bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv BASE_REF)" = origin/feat/slice-1-contracts ]
  [ "$(kv RANGE)" = "$TRUNK..$A" ]
  [ "$(kv REASON)" = 'parent main merged → default' ]

  # A deliberate caller policy still outranks the remote default.
  run env TRELLIS_ROOT="$BATS_TEST_TMPDIR/runtime" bash "$DB" resolve --policy main --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv BASE_REF)" = origin/main ]
  [ "$(kv RANGE)" = "$M0..$A" ]
}

@test "origin HEAD does not override a main policy declared by the protected base" {
  mk
  M0="$(snap m0)"
  git update-ref refs/remotes/origin/main "$M0"
  git checkout -qb feat/slice-1-contracts
  printf '{"template":{"branch":"main"}}\n' > "$REPO/.trellis.json"
  snap contracts >/dev/null
  git update-ref refs/remotes/origin/feat/slice-1-contracts HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat/slice-1-contracts
  git checkout -qb feature/x
  A="$(snap child)"
  git config branch.feature/x.trellisParent main
  git config branch.feature/x.trellisBase "$M0"

  run bash "$DB" resolve --format=kv
  [ "$status" -eq 0 ]
  [ "$(kv BASE_REF)" = origin/main ]
  [ "$(kv RANGE)" = "$M0..$A" ]
}
