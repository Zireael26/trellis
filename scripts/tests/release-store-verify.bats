#!/usr/bin/env bats
# Batched payload verification and per-process memoization for the release store.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
RELEASE_STORE_LIB="$REPO_ROOT/scripts/lib/release-store.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/release-store-verify.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  mkdir -p "$TRELLIS_HOME/releases"
  chmod 700 "$TRELLIS_HOME" "$TRELLIS_HOME/releases"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

seal_release_tree() {
  local root="$1"
  find "$root" -type f -exec chmod a-w {} \;
  find "$root" -type d -exec chmod a-w {} \;
}

make_tree_writable() {
  local root="$1"
  find "$root" -depth -type d -exec chmod u+w {} \;
  find "$root" -type f -exec chmod u+w {} \;
}

write_release_json() {
  local dest="$1" version="$2" tsv="$3"
  jq -Rn --arg version "$version" --arg tag "v$version" \
    --arg commit "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    --arg remote "fixture://release-store-verify" \
    '{
      schema_version: 1,
      version: $version,
      tag: $tag,
      commit: $commit,
      remote: $remote,
      tree: [
        inputs
        | select(length > 0)
        | split("\t")
        | {mode: .[0], oid: .[1], path: .[2]}
      ]
    }' < "$tsv" > "$dest"
}

# Build a sealed store entry at $TRELLIS_HOME/releases/$version from payload files
# already present under that directory. Hashes with one git hash-object spawn.
seal_payload_as_release() {
  local version="$1"
  local rel="$TRELLIS_HOME/releases/$version"
  local payload="$rel/payload"
  local work tsv paths abs hash_paths modes oids
  work="$(mktemp -d "$SANDBOX/manifest.XXXXXX")"
  tsv="$work/tree.tsv"
  paths="$work/paths"
  abs="$work/abs"
  hash_paths="$work/hash.paths"
  modes="$work/modes"
  oids="$work/oids"
  (
    CDPATH='' cd "$payload" || exit 1
    find . -mindepth 1 \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort
  ) > "$paths"
  [ -s "$paths" ] || return 1
  : > "$abs"
  : > "$hash_paths"
  : > "$modes"
  mkdir "$work/link-targets"
  local path full mode target idx=0
  while IFS= read -r path; do
    full="$payload/$path"
    if [ -L "$full" ]; then
      mode="120000"
      idx=$((idx + 1))
      target="$(readlink "$full")" || return 1
      printf '%s' "$target" > "$work/link-targets/$idx"
      printf '%s\n' "$work/link-targets/$idx" >> "$hash_paths"
    elif [ -f "$full" ]; then
      if [ -x "$full" ]; then
        mode="100755"
      else
        mode="100644"
      fi
      printf '%s\n' "$full" >> "$hash_paths"
    else
      return 1
    fi
    printf '%s\n' "$mode" >> "$modes"
    printf '%s\n' "$path" >> "$abs"
  done < "$paths"
  git hash-object --no-filters --stdin-paths < "$hash_paths" > "$oids" || return 1
  paste -d '	' "$modes" "$oids" "$abs" > "$tsv" || return 1
  write_release_json "$rel/release.json" "$version" "$tsv" || return 1
  rm -rf "$work"
  seal_release_tree "$rel"
}

install_small_release() {
  local version="${1:-1.0.0}"
  local rel="$TRELLIS_HOME/releases/$version"
  mkdir -p "$rel/payload/core-rules" "$rel/payload/bin"
  printf '1.0.0\n' > "$rel/payload/core-rules/VERSION"
  printf '#!/bin/sh\nexit 0\n' > "$rel/payload/bin/tool"
  chmod 755 "$rel/payload/bin/tool"
  ln -s core-rules/VERSION "$rel/payload/AGENTS.md"
  printf 'rules\n' > "$rel/payload/core-rules/CLAUDE.md"
  seal_payload_as_release "$version"
  printf '%s\n' "$rel"
}

install_perf_release() {
  local version="9.9.9"
  local rel="$TRELLIS_HOME/releases/$version"
  local n="${1:-2800}"
  mkdir -p "$rel/payload/d"
  python3 - "$rel/payload/d" "$n" <<'PY'
import os, sys
root, n = sys.argv[1], int(sys.argv[2])
os.makedirs(root, exist_ok=True)
for i in range(n):
    path = os.path.join(root, "f%04d" % i)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("payload-%d\n" % i)
PY
  printf 'perf\n' > "$rel/payload/README"
  ln -s README "$rel/payload/LINK"
  printf '#!/bin/sh\nexit 0\n' > "$rel/payload/run"
  chmod 755 "$rel/payload/run"
  seal_payload_as_release "$version"
  printf '%s\n' "$rel"
}

verify_release() {
  local rel="$1" version="$2"
  env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    release_store_verify_path "$2" "$3"
  ' release-store-verify "$RELEASE_STORE_LIB" "$rel" "$version"
}

# Verify with a chosen TMPDIR ("unset" removes it) while recording every
# directory template handed to mktemp. The allocation site is observed directly
# because the EXIT trap removes the directory before the test could look for it.
verify_release_scratch() {
  local rel="$1" version="$2" record="$3" tmp="$4"
  local -a envcmd
  if [ "$tmp" = "unset" ]; then
    envcmd=(env -u TMPDIR "TRELLIS_HOME=$TRELLIS_HOME")
  else
    envcmd=(env "TMPDIR=$tmp" "TRELLIS_HOME=$TRELLIS_HOME")
  fi
  "${envcmd[@]}" bash -c '
    . "$1"
    record="$4"
    mktemp() {
      [ "${1:-}" = "-d" ] && printf "%s\n" "$2" >> "$record"
      command mktemp "$@"
    }
    release_store_verify_path "$2" "$3"
  ' release-store-verify-scratch "$RELEASE_STORE_LIB" "$rel" "$version" "$record"
}

verify_scratch_entries() {
  find "$TRELLIS_HOME/releases" -mindepth 1 -maxdepth 1 -name '.tmp.*.verify.*' -print
}

# Content plus mode plus link targets, so a verification that rewrote or
# unsealed anything under the release entry shows up as a fingerprint change.
release_fingerprint() {
  local root="$1" entry
  (
    CDPATH='' cd "$root" || exit 1
    find . -mindepth 1 | LC_ALL=C sort |
      while IFS= read -r entry; do
        if [ -L "$entry" ]; then
          printf '%s\tlink\t%s\t%s\n' "$entry" "$(ls -ld "$entry" | cut -c1-10)" "$(readlink "$entry")"
        elif [ -d "$entry" ]; then
          printf '%s\tdir\t%s\n' "$entry" "$(ls -ld "$entry" | cut -c1-10)"
        else
          printf '%s\tfile\t%s\t%s\n' "$entry" "$(ls -ld "$entry" | cut -c1-10)" \
            "$(git hash-object --no-filters "$entry")"
        fi
      done
  )
}

@test "valid sealed fixture verifies" {
  rel="$(install_small_release 1.0.0)"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "tampered payload byte is refused" {
  rel="$(install_small_release 1.0.0)"
  make_tree_writable "$rel"
  printf 'tampered\n' > "$rel/payload/core-rules/CLAUDE.md"
  seal_release_tree "$rel"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"changed release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "tampered oid in release.json is refused" {
  rel="$(install_small_release 1.0.0)"
  make_tree_writable "$rel"
  jq '(.tree[] | select(.path == "core-rules/CLAUDE.md") | .oid) = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$rel/release.json" > "$rel/release.json.next"
  mv "$rel/release.json.next" "$rel/release.json"
  seal_release_tree "$rel"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"changed release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "added extra payload file is refused" {
  rel="$(install_small_release 1.0.0)"
  make_tree_writable "$rel"
  printf 'extra\n' > "$rel/payload/core-rules/extra.md"
  seal_release_tree "$rel"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release payload has missing or added paths"* ]] || { echo "$output"; false; }
}

@test "second verify in the same process agrees" {
  rel="$(install_small_release 1.0.0)"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    release_store_verify_path "$2" "$3"
    first=$?
    release_store_verify_path "$2" "$3"
    second=$?
    printf "first=%s second=%s\n" "$first" "$second"
    exit "$second"
  ' release-store-verify-memo "$RELEASE_STORE_LIB" "$rel" "1.0.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first=0 second=0"* ]] || { echo "$output"; false; }
}

@test "a failed verification is not memoized" {
  rel="$(install_small_release 1.0.0)"
  make_tree_writable "$rel"
  printf 'tampered\n' > "$rel/payload/core-rules/CLAUDE.md"
  seal_release_tree "$rel"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    release_store_verify_path "$2" "$3"
    first=$?
    chmod u+w "$2/payload/core-rules/CLAUDE.md"
    printf "rules\n" > "$2/payload/core-rules/CLAUDE.md"
    chmod a-w "$2/payload/core-rules/CLAUDE.md"
    release_store_verify_path "$2" "$3"
    second=$?
    printf "first=%s second=%s\n" "$first" "$second"
    exit "$second"
  ' release-store-verify-fail-memo "$RELEASE_STORE_LIB" "$rel" "1.0.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first=4 second=0"* ]] || { echo "$output"; false; }
}

@test "an inherited memo from another process is ignored" {
  # The memo is never exported and each key carries the owning shell's $$, so
  # the child must re-verify -- otherwise a stale success verdict would survive
  # across a process boundary and mask a tamper.
  rel="$(install_small_release 1.0.0)"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    release_store_verify_path "$2" "$3" || exit 90
    [ -n "$_TRELLIS_RELEASE_STORE_VERIFY_MEMO" ] || exit 91
    chmod -R u+w "$2"
    printf "tampered\n" > "$2/payload/core-rules/CLAUDE.md"
    chmod -R a-w "$2"
    # Even a memo exported by the caller must not be honoured by a child.
    export _TRELLIS_RELEASE_STORE_VERIFY_MEMO
    bash -c ". \"$1\"; release_store_verify_path \"$2\" \"$3\""
    printf "child=%s\n" "$?"
  ' release-store-verify-inherit-memo "$RELEASE_STORE_LIB" "$rel" "1.0.0"
  [[ "$output" == *"child=4"* ]] || { echo "$output"; false; }
}

@test "a memo handed over by same-PID exec is discarded when the library loads" {
  # exec keeps $$, so only the load-time reset stops this stale verdict.
  rel="$(install_small_release 1.0.0)"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    release_store_verify_path "$2" "$3" || exit 90
    [ -n "$_TRELLIS_RELEASE_STORE_VERIFY_MEMO" ] || exit 91
    chmod -R u+w "$2"
    printf "tampered\n" > "$2/payload/core-rules/CLAUDE.md"
    chmod -R a-w "$2"
    export _TRELLIS_RELEASE_STORE_VERIFY_MEMO
    exec bash -c ". \"$1\"; release_store_verify_path \"$2\" \"$3\"; printf \"exec=%s\n\" \"\$?\""
  ' release-store-verify-exec-memo "$RELEASE_STORE_LIB" "$rel" "1.0.0"
  [[ "$output" == *"exec=4"* ]] || { echo "$output"; false; }
  [[ "$output" == *"changed release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

@test "fresh process re-verifies and refuses tamper" {
  rel="$(install_small_release 1.0.0)"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 0 ]
  make_tree_writable "$rel"
  printf 'tampered\n' > "$rel/payload/core-rules/CLAUDE.md"
  seal_release_tree "$rel"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 4 ]
  [[ "$output" == *"changed release content: core-rules/CLAUDE.md"* ]] || { echo "$output"; false; }
}

# Verification scratch is store-adjacent like launcher_verify_release_body's.
# The launcher drops TMPDIR under `env -i`; the verification sandbox, not that
# sanitization, denies the resulting global-temp fallback. Direct library
# callers also lose TMPDIR selection for verifier scratch, by design.
@test "verifier scratch is allocated in the store, not in ambient TMPDIR" {
  rel="$(install_small_release 1.0.0)"
  outside="$SANDBOX/outside-tmp"
  mkdir -p "$outside"
  record="$SANDBOX/templates.log"
  : > "$record"
  run verify_release_scratch "$rel" "1.0.0" "$record" "$outside"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(wc -l < "$record" | tr -d ' ')" -eq 1 ] || { cat "$record"; false; }
  [ "$(cat "$record")" = "$TRELLIS_HOME/releases/.tmp.1.0.0.verify.XXXXXX" ] || { cat "$record"; false; }
  [ -z "$(ls -A "$outside")" ] || { ls -A "$outside"; false; }
}

@test "unset, hostile, missing and symlinked TMPDIR do not divert verifier scratch" {
  rel="$(install_small_release 1.0.0)"
  outside="$SANDBOX/outside-tmp"
  mkdir -p "$outside"
  ln -s "$outside" "$SANDBOX/tmp-link"
  record="$SANDBOX/templates.log"
  local candidate
  for candidate in unset "$SANDBOX/tmp-link" "$SANDBOX/no-such-tmp" "$rel/payload"; do
    : > "$record"
    run verify_release_scratch "$rel" "1.0.0" "$record" "$candidate"
    [ "$status" -eq 0 ] || { echo "$candidate: $output"; false; }
    [ "$(cat "$record")" = "$TRELLIS_HOME/releases/.tmp.1.0.0.verify.XXXXXX" ] || { echo "$candidate: $(cat "$record")"; false; }
  done
  [ -z "$(ls -A "$outside")" ] || { ls -A "$outside"; false; }
  [ -z "$(verify_scratch_entries)" ] || { verify_scratch_entries; false; }
}

@test "verifier scratch is removed after success and after a content failure" {
  rel="$(install_small_release 1.0.0)"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$(verify_scratch_entries)" ] || { verify_scratch_entries; false; }
  # The injected error is a payload byte, which is compared long after the
  # allocation -- a malformed-entry preflight would never reach it.
  make_tree_writable "$rel"
  printf 'tampered\n' > "$rel/payload/core-rules/CLAUDE.md"
  seal_release_tree "$rel"
  run verify_release "$rel" "1.0.0"
  [ "$status" -eq 4 ]
  [ -z "$(verify_scratch_entries)" ] || { verify_scratch_entries; false; }
}

@test "a containment refusal happens before any scratch is allocated" {
  rel="$(TRELLIS_HOME="$SANDBOX/outside-store" install_small_release 1.0.0)"
  record="$SANDBOX/templates.log"
  : > "$record"
  run verify_release_scratch "$rel" "1.0.0" "$record" "$SANDBOX/outside-tmp"
  [ "$status" -eq 4 ]
  [[ "$output" == *"release directory escapes canonical store:"* ]] || { echo "$output"; false; }
  [ ! -s "$record" ] || { cat "$record"; false; }
}

@test "a private store path with spaces verifies and leaves the sealed release unchanged" {
  TRELLIS_HOME="$SANDBOX/store with spaces/trellis home"
  mkdir -p "$TRELLIS_HOME/releases"
  chmod 700 "$TRELLIS_HOME" "$TRELLIS_HOME/releases"
  rel="$(install_small_release 1.0.0)"
  before="$(release_fingerprint "$rel")"
  record="$SANDBOX/templates.log"
  : > "$record"
  run verify_release_scratch "$rel" "1.0.0" "$record" "$SANDBOX/outside-tmp"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$record")" = "$TRELLIS_HOME/releases/.tmp.1.0.0.verify.XXXXXX" ] || { cat "$record"; false; }
  [ "$(release_fingerprint "$rel")" = "$before" ] || { diff <(printf '%s\n' "$before") <(release_fingerprint "$rel"); false; }
  [ -z "$(verify_scratch_entries)" ] || { verify_scratch_entries; false; }
}

@test "an unwritable store parent refuses with exit 5 and does not fall back outside" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory write permission"
  rel="$(install_small_release 1.0.0)"
  outside="$SANDBOX/outside-tmp"
  mkdir -p "$outside"
  before="$(release_fingerprint "$rel")"
  record="$SANDBOX/templates.log"
  : > "$record"
  chmod a-w "$TRELLIS_HOME/releases"
  locked_mode="$(ls -ld "$TRELLIS_HOME/releases" | cut -c1-10)"
  run verify_release_scratch "$rel" "1.0.0" "$record" "$outside"
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [ "$(cat "$record")" = "$TRELLIS_HOME/releases/.tmp.1.0.0.verify.XXXXXX" ] || { cat "$record"; false; }
  [ "$(ls -ld "$TRELLIS_HOME/releases" | cut -c1-10)" = "$locked_mode" ]
  [ -z "$(ls -A "$outside")" ] || { ls -A "$outside"; false; }
  [ "$(release_fingerprint "$rel")" = "$before" ]
  chmod u+w "$TRELLIS_HOME/releases"
}

# The per-entry spawn path took 57.8s on a /tmp copy of rc.40 (2834 entries);
# the batched verify took 5.8s. A wall-clock bound around that went red under
# shared gate load, so assert the batching itself: one --stdin-paths hash for
# the regular files, and a hash-object spawn count that does not grow with the
# 2800 entries. Synthetic files, never ~/.trellis.
@test "synthetic 2800-entry fixture verifies with one batched hash" {
  rel="$(install_perf_release 2800)"
  mkdir "$SANDBOX/bin"
  TEST_REAL_GIT="$(command -v git)"
  TEST_GIT_LOG="$SANDBOX/git-calls.log"
  export TEST_REAL_GIT TEST_GIT_LOG
  : > "$TEST_GIT_LOG"
  cat > "$SANDBOX/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GIT_LOG"
exec "$TEST_REAL_GIT" "$@"
SH
  chmod 755 "$SANDBOX/bin/git"
  export PATH="$SANDBOX/bin:$PATH"
  run verify_release "$rel" "9.9.9"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  batched="$(grep -c -- 'hash-object .*--stdin-paths' "$TEST_GIT_LOG")" || true
  hashes="$(grep -c 'hash-object' "$TEST_GIT_LOG")" || true
  [ "$batched" -eq 1 ] && [ "$hashes" -lt 10 ] || {
    echo "batched=$batched hash-object calls=$hashes; first calls:"
    sed -n '1,5p' "$TEST_GIT_LOG"
    false
  }
}

# Spec 067 T16: verify scratch carries the exec-snapshot sibling owner record.
# The probe runs inside the verify body (its manifest-path read), after
# the scratch and its owner file exist and before the EXIT trap removes them.
@test "verify scratch has a sibling owner record while live and leaves nothing after exit" {
  rel="$(install_small_release 1.0.0)"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1"
    probe="$4"
    jq() {
      [ "$*" != "-r .tree[].path $TRELLIS_HOME/releases/1.0.0/release.json" ] ||
        ls -A "$TRELLIS_HOME/releases" > "$probe"
      command jq "$@"
    }
    release_store_verify_path "$2" "$3"
  ' verify-probe "$RELEASE_STORE_LIB" "$rel" 1.0.0 "$SANDBOX/probe"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -Eq '^\.tmp\.1\.0\.0\.verify\.[A-Za-z0-9]+$' "$SANDBOX/probe" || { cat "$SANDBOX/probe"; false; }
  grep -Eq '^\.tmp\.1\.0\.0\.verify\.[A-Za-z0-9]+\.owner\.json$' "$SANDBOX/probe" || { cat "$SANDBOX/probe"; false; }
  [ -z "$(verify_scratch_entries)" ] || { verify_scratch_entries; false; }
}

# A SIGKILL (the SessionStart timeout) skips the EXIT trap. The owner record
# names the killed shell, so reap-tmp removes the pair at 1 h, not 24 h.
@test "a SIGKILLed verify leaves scratch reap-tmp classifies by pid at 1 h" {
  rel="$(install_small_release 1.0.0)"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    top=$$
    . "$1"
    jq() {
      [ "$*" != "-r .tree[].path $TRELLIS_HOME/releases/1.0.0/release.json" ] ||
        sh -c "kill -9 \$PPID $top"
      command jq "$@"
    }
    release_store_verify_path "$2" "$3"
  ' verify-kill "$RELEASE_STORE_LIB" "$rel" 1.0.0
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  scratch="$(verify_scratch_entries | grep -v '\.owner\.json$')"
  [ -d "$scratch" ] || { verify_scratch_entries; false; }
  [ -f "$scratch.owner.json" ] || { verify_scratch_entries; false; }
  python3 -c 'import os, sys, time; t = time.time() - 3660; [os.utime(p, (t, t)) for p in sys.argv[1:]]' \
    "$scratch" "$scratch.owner.json"
  run env TRELLIS_HOME="$TRELLIS_HOME" bash -c '. "$1"; release_store_reap_tmp fix' reap "$RELEASE_STORE_LIB"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"removed dir ${scratch##*/} "*"owner=dead"* ]] || { echo "$output"; false; }
  [ -z "$(verify_scratch_entries)" ] || { verify_scratch_entries; false; }
}
