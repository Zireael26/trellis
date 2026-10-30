#!/usr/bin/env bats
# run-all diff base (spec 067 T5): one resolver call feeds every row and the
# receipt under the verdict header. The aggregator, common.sh and diff-base.sh
# are real; each check-*.sh is a stub that logs the range it was handed and the
# commit subjects in it.

RECEIPT_RE='^diff-base: ([0-9a-f]{12}|-) ([^ ]+) via (explicit|pr-cache|recorded|reflog|upstream|default|fallback|refused) \(.*\) range=([^ ]+) head=([^ ]+)$'
ROWS="check-pr.sh check-secrets.sh check-bypass.sh check-tests.sh check-docs.sh check-security-diff.sh check-analyze.sh check-slop.sh"

setup() {
  export TRELLIS_GATE_STATE_DIR="$BATS_TEST_TMPDIR/trellis-gate-state"
  local real name
  real="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts"
  STUB="$BATS_TEST_TMPDIR/skill"
  LOGS="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$STUB/scripts/lib" "$LOGS"
  cp "$real/run-all.sh" "$STUB/scripts/run-all.sh"
  cp "$real/lib/common.sh" "$real/lib/diff-base.sh" "$STUB/scripts/lib/"
  for name in $ROWS; do
    cat > "$STUB/scripts/$name" <<EOF
#!/usr/bin/env bash
range="\${1#--range=}"
{ printf 'range=%s\n' "\$range"; git log --format=%s "\$range"; } > "$LOGS/$name"
echo "info $name"
EOF
  done
  export PROCESS_GATE_STACK_PROFILE=n-a
  unset CODEX_PROJECT_DIR TRELLIS_ROOT
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@t.invalid
  git -C "$REPO" config user.name t
  commit m0
  git -C "$REPO" checkout -qb feature/a
  commit a1
  commit a2
  ATIP="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -qb feature/b
  commit b1
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" config branch.feature/b.trellisParent feature/a
  git -C "$REPO" config branch.feature/b.trellisBase "$ATIP"
  export CLAUDE_PROJECT_DIR="$REPO"
}

commit() {
  printf '%s\n' "$1" > "$REPO/$1.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$1"
}

run_all() {
  run bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$STUB/scripts/run-all.sh" "$@"
}

# The line two below the verdict header.
receipt_line() {
  printf '%s\n' "$output" | awk '/^## process-gate verdict/ { n = NR + 2 } NR == n { print; exit }'
}

@test "stacked branch: every row is handed the recorded parent's SHA range, b1 only" {
  # Inversion: restoring main..HEAD in pg_parse_range hands every row a1 a2 b1.
  run_all --mode=push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local name
  for name in $ROWS; do
    [ "$(cat "$LOGS/$name")" = "$(printf 'range=%s..%s\nb1' "$ATIP" "$HEAD_SHA")" ] || { echo "$name:"; cat "$LOGS/$name"; false; }
  done
}

@test "the receipt is the line under the verdict header and names the range the rows got" {
  # Inversion: dropping the receipt printf, or moving it, fails the shape match.
  run_all --mode=push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  receipt_line | grep -Eq "$RECEIPT_RE" || { echo "$output"; false; }
  [[ "$(receipt_line)" == *"via recorded (parent feature/a) range=${ATIP:0:12}..${HEAD_SHA:0:12} head=feature/b" ]] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | grep -c '^diff-base: ')" -eq 1 ] || { echo "$output"; false; }
}

@test "--base=main in merge mode gates merge-base(main, HEAD)..HEAD" {
  # Inversion: a guard that rejects --base, or an unresolved ref range, fails.
  local m0
  m0="$(git -C "$REPO" rev-parse main)"
  run_all --mode=merge --base=main
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -n 1 "$LOGS/check-pr.sh")" = "range=$m0..$HEAD_SHA" ] || { cat "$LOGS/check-pr.sh"; false; }
  [ "$(sed 1d "$LOGS/check-pr.sh" | tr '\n' ' ')" = "b1 a2 a1 " ] || { cat "$LOGS/check-pr.sh"; false; }
  [[ "$(receipt_line)" == *"via explicit (explicit --base main)"* ]] || { echo "$output"; false; }
}

@test "an explicit --range is handed over verbatim and the receipt flags a non-ancestor start" {
  # Inversion: merge-base normalising the range hands the rows a SHA range.
  git -C "$REPO" checkout -q main
  commit m2
  git -C "$REPO" checkout -q feature/b
  run_all --mode=merge --range=main..HEAD
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -n 1 "$LOGS/check-docs.sh")" = "range=main..HEAD" ] || { cat "$LOGS/check-docs.sh"; false; }
  [[ "$(receipt_line)" == *"via explicit (explicit; start not ancestor of head (tree diff)) range=main..HEAD "* ]] || { echo "$output"; false; }
}

@test "--range with --base is refused before any row runs" {
  run_all --mode=merge --range=main..HEAD --base=main
  [ "$status" -eq 2 ]
  [[ "$output" == *"pass --range or --base, not both"* ]] || { echo "$output"; false; }
  [ -z "$(ls "$LOGS")" ] || { ls "$LOGS"; false; }
}

@test "nothing resolvable stops the run before any row, with no HEAD~1 fallback" {
  # Inversion: a HEAD~1..HEAD fallback runs the rows and renders a verdict.
  git -C "$REPO" checkout -q --orphan lone
  git -C "$REPO" commit -qm lone
  git -C "$REPO" branch -D main feature/a feature/b >/dev/null
  run_all --mode=push
  [ "$status" -eq 1 ]
  [[ "$output" == *"run-all.sh: no diff base resolvable; pass --base"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Overall:"* ]] || { echo "$output"; false; }
  [ -z "$(ls "$LOGS")" ] || { ls "$LOGS"; false; }
}

# --- coordinator ruling D1 (1.3.12-a): the resolver's base, else main..HEAD, else refuse

@test "D1: an underivable two-commit push refuses and no row runs, never HEAD~1..HEAD" {
  # Inversion: 1.3.11's HEAD~1..HEAD fallback hands every row lone2 only.
  git -C "$REPO" checkout -q --orphan lone
  git -C "$REPO" commit -qm lone1
  commit lone2
  git -C "$REPO" branch -D main feature/a feature/b >/dev/null
  run_all --mode=push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"run-all.sh: no diff base resolvable; pass --base"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Overall:"* ]] || { echo "$output"; false; }
  [ -z "$(ls "$LOGS")" ] || { ls "$LOGS"; false; }
}

# The staged resolver refuses every call, so only the D1 fallback can supply a range.
stub_refusing_resolver() {
  cat >> "$STUB/scripts/lib/diff-base.sh" <<'STUB'
db_resolve() { DB_BASE_SHA=""; DB_BASE_REF="-"; DB_SOURCE="refused"; DB_REASON="no diff base resolvable; pass --base"; DB_RANGE=""; return 1; }
STUB
}

# assert_fallback <branch> <subjects>: every row got <branch>..HEAD and its
# commits, and the receipt names <branch> via fallback at its tip.
assert_fallback() {
  local tip name
  tip="$(git -C "$REPO" rev-parse "$1")"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for name in $ROWS; do
    [ "$(cat "$LOGS/$name")" = "$(printf 'range=%s..HEAD\n%s' "$1" "$2")" ] || { echo "$name:"; cat "$LOGS/$name"; return 1; }
  done
  [[ "$(receipt_line)" == *" $1 via fallback ("*") range=${tip:0:12}..${HEAD_SHA:0:12} "* ]] || { echo "$output"; return 1; }
}

@test "D1: a resolver that cannot derive a base falls back to exactly main..HEAD" {
  # Inversion: spec 067 as written refuses here; HEAD~1..HEAD hands b1 only.
  stub_refusing_resolver
  run_all --mode=push
  assert_fallback main "$(printf 'b1\na2\na1')"
}

@test "D1: a master-only repo falls back to exactly the local master..HEAD" {
  # Inversion: dropping the master arm refuses; a remote-tracking ref has none here.
  git -C "$REPO" branch -m main master
  stub_refusing_resolver
  run_all --mode=push
  assert_fallback master "$(printf 'b1\na2\na1')"
}

@test "D1: with both main and master, main..HEAD wins" {
  # Inversion: master first hands b1 only (master sits at feature/a's tip).
  git -C "$REPO" branch master "$ATIP"
  stub_refusing_resolver
  run_all --mode=push
  assert_fallback main "$(printf 'b1\na2\na1')"
}

@test "D1: an unresolvable --base refuses with main present; the fallback never covers a flag" {
  # Inversion: a fallback that also catches a refused --base gates main..HEAD.
  run_all --mode=push --base=no-such-ref
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"run-all.sh: explicit base unresolvable; pass --base"* ]] || { echo "$output"; false; }
  [ -z "$(ls "$LOGS")" ] || { ls "$LOGS"; false; }
}

# --- BGSEC-A: a template.branch carried by the range never picks the rows' range

# creds_feature <policy>: origin/main at main's tip M0, then feature/x off main
# with a synthetic key in commit A and template.branch=<policy> in commit B
# (`sha` and `short` name A; `side` is a remote branch holding A).
creds_feature() {
  local pol="$1"
  git -C "$REPO" checkout -q main || return 1
  git -C "$REPO" branch -D feature/x >/dev/null 2>&1 || true
  M0="$(git -C "$REPO" rev-parse main)" || return 1
  git -C "$REPO" update-ref refs/remotes/origin/main "$M0" || return 1
  git -C "$REPO" checkout -qb feature/x main || return 1
  printf 'AWS_ACCESS_KEY_ID=%s%s\n' AKIA QYLPMN5HFIQR7XYZ > "$REPO/creds.env" || return 1
  git -C "$REPO" add creds.env || return 1
  git -C "$REPO" commit -qm creds || return 1
  A="$(git -C "$REPO" rev-parse HEAD)" || return 1
  case "$pol" in
    sha) pol="$A" ;;
    short) pol="${A:0:7}" ;;
    side) git -C "$REPO" update-ref refs/remotes/origin/side "$A" || return 1 ;;
  esac
  printf '{"template":{"branch":"%s"}}\n' "$pol" > "$REPO/.trellis.json" || return 1
  git -C "$REPO" add .trellis.json || return 1
  git -C "$REPO" commit -qm policy || return 1
  B="$(git -C "$REPO" rev-parse HEAD)" || return 1
}

@test "BGSEC-A no range-carried template.branch empties or narrows a push run's rows" {
  # Inversion: the checkout's policy hands every row B..B (HEAD, @) or A..B.
  local pol name
  for pol in HEAD @ sha short side --all; do
    rm -f "$LOGS"/*
    creds_feature "$pol" || return 1
    run_all --mode=push
    [ "$status" -eq 0 ] || { echo "policy $pol: $output"; return 1; }
    for name in check-secrets.sh check-security-diff.sh; do
      [ "$(cat "$LOGS/$name")" = "$(printf 'range=%s..%s\npolicy\ncreds' "$M0" "$B")" ] || { echo "policy $pol $name:"; cat "$LOGS/$name"; return 1; }
    done
  done
}

@test "BGSEC-A a base template.branch that is not a branch stops the run, with no D1 fallback" {
  # Inversion: resolving HEAD as the policy runs every row on B..B; the D1
  # fallback would run them on main..HEAD instead of refusing.
  printf '{"template":{"branch":"HEAD"}}\n' > "$REPO/.trellis.json"
  git -C "$REPO" checkout -q main
  git -C "$REPO" add .trellis.json
  git -C "$REPO" commit -qm 'base policy'
  creds_feature @
  run_all --mode=push
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"no diff base resolvable; pass --range"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Overall:"* ]] || { echo "$output"; false; }
  [ -z "$(ls "$LOGS")" ] || { ls "$LOGS"; false; }
}

@test "BGSEC-A merge mode: no range refuses, and an explicit range hands the rows the key" {
  # The key policy stays on the base: a gate-config change inside the range
  # would need merge approval (its own gate), pre-empting the range handoff.
  git -C "$REPO" checkout -q main || return 1
  printf '{"template":{"branch":"HEAD"}}\n' > "$REPO/.trellis.json" || return 1
  git -C "$REPO" add .trellis.json || return 1
  git -C "$REPO" commit -qm policy || return 1
  M0="$(git -C "$REPO" rev-parse main)" || return 1
  git -C "$REPO" update-ref refs/remotes/origin/main "$M0" || return 1
  git -C "$REPO" checkout -qb feature/x main || return 1
  printf 'AWS_ACCESS_KEY_ID=%s%s\n' AKIA QYLPMN5HFIQR7XYZ > "$REPO/creds.env" || return 1
  git -C "$REPO" add creds.env || return 1
  git -C "$REPO" commit -qm creds || return 1
  run_all --mode=merge
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"merge mode requires --range/--base"* ]] || { echo "$output"; false; }
  [ -z "$(ls "$LOGS")" ] || { ls "$LOGS"; false; }
  run_all --mode=merge --range=origin/main..HEAD
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$LOGS/check-secrets.sh")" = "$(printf 'range=origin/main..HEAD\ncreds')" ] || { cat "$LOGS/check-secrets.sh"; false; }
}
