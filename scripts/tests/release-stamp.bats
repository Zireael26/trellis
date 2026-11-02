#!/usr/bin/env bats
# Spec 072 D-A release stamp (T2) and its wiring (T3). Every change a stamp
# must notice falls back to the full verify, and that verify's verdict decides.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/lib"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/release-stamp.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  STAMPS="$TRELLIS_HOME/state/release-stamps"
  mkdir -p "$TRELLIS_HOME/releases" "$SANDBOX/user" "$SANDBOX/tmp"
  chmod 700 "$TRELLIS_HOME" "$TRELLIS_HOME/releases"
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
    rm -rf "$SANDBOX"
  fi
}

sha256_of() {
  python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

mode_of() {
  python3 -I -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$1"
}

# Seal $TRELLIS_HOME/releases/<version>/payload as a release the full verifies
# accept: release.json from one git hash-object pass, everything a-w.
seal_release() {
  local version="$1" rel="$TRELLIS_HOME/releases/$1" work path full idx=0
  work="$(mktemp -d "$SANDBOX/manifest.XXXXXX")"
  (CDPATH='' cd "$rel/payload" && find . -mindepth 1 \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort) > "$work/paths"
  : > "$work/hash"
  : > "$work/modes"
  while IFS= read -r path; do
    full="$rel/payload/$path"
    if [ -L "$full" ]; then
      idx=$((idx + 1))
      printf '%s' "$(readlink "$full")" > "$work/link.$idx"
      printf '%s\n' "$work/link.$idx" >> "$work/hash"
      printf '120000\n' >> "$work/modes"
    else
      printf '%s\n' "$full" >> "$work/hash"
      if [ -x "$full" ]; then printf '100755\n'; else printf '100644\n'; fi >> "$work/modes"
    fi
  done < "$work/paths"
  git hash-object --no-filters --stdin-paths < "$work/hash" > "$work/oids"
  paste -d '	' "$work/modes" "$work/oids" "$work/paths" |
    jq -Rn --arg version "$version" '{
      schema_version: 1, version: $version, tag: ("v" + $version),
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", remote: "fixture://release-stamp",
      tree: [inputs | select(length > 0) | split("\t") | {mode: .[0], oid: .[1], path: .[2]}]
    }' > "$rel/release.json"
  rm -rf "$work"
  find "$rel" -type f -exec chmod a-w {} +
  find "$rel" -type d -exec chmod a-w {} +
}

# VERSION and CLAUDE.md are the same size, for the swap case.
install_release() {
  local version="${1:-1.0.0}" rel="$TRELLIS_HOME/releases/${1:-1.0.0}"
  mkdir -p "$rel/payload/core-rules" "$rel/payload/bin"
  printf '1.0.0\n' > "$rel/payload/core-rules/VERSION"
  printf 'rules\n' > "$rel/payload/core-rules/CLAUDE.md"
  printf '#!/bin/sh\nexit 0\n' > "$rel/payload/bin/tool"
  chmod 755 "$rel/payload/bin/tool"
  ln -s core-rules/VERSION "$rel/payload/AGENTS.md"
  seal_release "$version"
  printf '%s\n' "$rel"
}

# The caller pattern from release-stamp.sh, with release_store_verify_path as
# the full verify. Prints stamp-hit, or full-verify and then stamp-written when
# the verify passed. STAMP_LIB swaps in a mutated stamp library.
stamped_verify() {
  env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/release-store.sh"
    . "$2/release-stamp.sh"
    if release_stamp_check "$3" "$4"; then echo stamp-hit; exit 0; fi
    echo full-verify
    release_store_verify_path "$4" "${4##*/}" || exit $?
    release_stamp_write "$3" "$4" && echo stamp-written
  ' stamped-verify "$LIB" "${STAMP_LIB:-$LIB}" "$TRELLIS_HOME" "$1"
}

# A fresh release, stamped by its first full verify and hit by the second.
stamped_release() {
  local rel
  rel="$(install_release "${1:-1.0.0}")"
  run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = $'full-verify\nstamp-written' ] || { echo "first: $output"; return 1; }
  run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = stamp-hit ] || { echo "second: $output"; return 1; }
  printf '%s\n' "$rel"
}

stamp_file() {
  printf '%s/%s-%s.json\n' "$STAMPS" "${1##*/}" "$(sha256_of "$1/release.json")"
}

writable() { chmod u+w "$@"; }
sealed() { chmod a-w "$@"; }

# The verdict after a change: the stamp missed and the full verify refused.
refused_by_full_verify() {
  [ "$status" -ne 0 ] && [ "$output" != stamp-hit ] && [[ "$output" == full-verify* ]] &&
    [[ "$output" != *stamp-written* ]] || { echo "status=$status output=$output"; return 1; }
}

# The verdict after a harmless change: the stamp missed, the full verify passed
# and restamped, and the next call hits again.
restamped_by_full_verify() {
  local rel="$1"
  [ "$status" -eq 0 ] && [ "$output" = $'full-verify\nstamp-written' ] || { echo "status=$status output=$output"; return 1; }
  run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = stamp-hit ] || { echo "after: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# T2: what the stamp records and when it misses
# ---------------------------------------------------------------------------

@test "an absent stamp never passes, and the first full verify writes a private stamp" {
  rel="$(install_release)"
  [ ! -e "$STAMPS" ]
  run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = $'full-verify\nstamp-written' ] || { echo "$output"; false; }
  stamp="$(stamp_file "$rel")"
  [ -f "$stamp" ]
  [ "$(mode_of "$stamp")" = 600 ]
  [ "$(mode_of "$STAMPS")" = 700 ]
  jq -e --arg root "$rel" --arg digest "$(sha256_of "$rel/release.json")" '
    .schema_version == 2 and .version == "1.0.0" and .root == $root
    and .release_json_sha256 == $digest
    and ([.entries[].path] | sort) == ["payload/AGENTS.md", "payload/bin/tool", "payload/core-rules/CLAUDE.md", "payload/core-rules/VERSION", "release.json"]
    and ([.directories[].path] | sort) == [".", "payload", "payload/bin", "payload/core-rules"]
    and all(.entries[], .directories[]; keys == ["ctime_ns", "dev", "ino", "mode", "mtime_ns", "path", "size", "type"])
  ' "$stamp"
  run stamped_verify "$rel"
  [ "$output" = stamp-hit ]
}

@test "changed content falls back to the full verify, which refuses" {
  rel="$(stamped_release)"
  writable "$rel/payload/core-rules/CLAUDE.md"
  printf 'tampered rules\n' > "$rel/payload/core-rules/CLAUDE.md"
  sealed "$rel/payload/core-rules/CLAUDE.md"
  run stamped_verify "$rel"
  refused_by_full_verify
  [[ "$output" == *'changed release content: core-rules/CLAUDE.md'* ]]
}

@test "chmod falls back to the full verify, which refuses the new mode" {
  rel="$(stamped_release)"
  chmod a+x "$rel/payload/core-rules/CLAUDE.md"
  run stamped_verify "$rel"
  refused_by_full_verify
}

@test "replace-by-rename with the same bytes falls back, and the full verify passes and restamps" {
  rel="$(stamped_release)"
  writable "$rel/payload/core-rules"
  printf 'rules\n' > "$rel/payload/core-rules/.next"
  sealed "$rel/payload/core-rules/.next"
  mv "$rel/payload/core-rules/.next" "$rel/payload/core-rules/CLAUDE.md"
  sealed "$rel/payload/core-rules"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
}

@test "an added file falls back to the full verify, which refuses" {
  rel="$(stamped_release)"
  writable "$rel/payload/bin"
  printf 'extra\n' > "$rel/payload/bin/extra"
  sealed "$rel/payload/bin/extra" "$rel/payload/bin"
  run stamped_verify "$rel"
  refused_by_full_verify
}

@test "a deleted file falls back to the full verify, which refuses" {
  rel="$(stamped_release)"
  writable "$rel/payload/bin"
  rm -f "$rel/payload/bin/tool"
  sealed "$rel/payload/bin"
  run stamped_verify "$rel"
  refused_by_full_verify
}

# Same size, mtime put back to the nanosecond: only ctime still differs.
tamper_keeping_size_and_mtime() {
  local file="$1"
  python3 -I -c '
import os, sys
path = sys.argv[1]
before = os.stat(path)
os.chmod(path, 0o644)
with open(path, "r+b") as handle:
    handle.write(b"RULES\n")
os.chmod(path, before.st_mode & 0o7777)
os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
after = os.stat(path)
assert (after.st_size, after.st_mtime_ns, after.st_ino) == (before.st_size, before.st_mtime_ns, before.st_ino)
assert after.st_ctime_ns != before.st_ctime_ns
' "$file"
}

@test "a same-size change touched back to its old mtime still moves ctime, and the full verify refuses" {
  rel="$(stamped_release)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  run stamped_verify "$rel"
  refused_by_full_verify
  [[ "$output" == *'changed release content: core-rules/CLAUDE.md'* ]]
}

# Mutation check: a stamp that ignores ctime is fooled by the case above, so
# that case is what makes ctime load-bearing.
@test "mutation: a check that ignores ctime passes the old-mtime tamper" {
  mutant="$SANDBOX/mutant-lib"
  mkdir -p "$mutant"
  cp "$LIB/release-stamp.sh" "$mutant/"
  # A zero ctime is also coarse, so the mutant drops the coarse-ctime refusal.
  sed -e 's/info\.st_ctime_ns/0/' -e 's/^    return all(entry\[4\] % 1000000 .*/    return True/' \
    "$LIB/release_stamp.py" > "$mutant/release_stamp.py"
  [ "$(grep -c 'info\.st_ctime_ns' "$LIB/release_stamp.py")" -eq 1 ]
  [ "$(grep -c 'info\.st_ctime_ns' "$mutant/release_stamp.py")" -eq 0 ]
  [ "$(diff "$LIB/release_stamp.py" "$mutant/release_stamp.py" | grep -c '^>')" -eq 2 ]
  rel="$(STAMP_LIB="$mutant" stamped_release)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  STAMP_LIB="$mutant" run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = stamp-hit ] || { echo "mutant was not fooled: $output"; false; }
  # The real check, over the mutant's stamp of the same release, still misses.
  run stamped_verify "$rel"
  refused_by_full_verify
}

# HFS+ keeps ctime in whole seconds and exFAT in 10 ms, so a change and restore
# within one tick could leave a sweep unchanged. A copy whose sweep rounds
# ctime to each tick models those filesystems: nothing is stamped or hit.
@test "on a filesystem with coarse ctime nothing is stamped or hit, and the full verify decides" {
  rel="$(install_release)"
  for tick in 1000000000 10000000; do
    coarse="$SANDBOX/coarse-$tick"
    mkdir -p "$coarse"
    cp "$LIB/release-stamp.sh" "$coarse/"
    sed "s|info\.st_ctime_ns|(info.st_ctime_ns // $tick * $tick)|" "$LIB/release_stamp.py" > "$coarse/release_stamp.py"
    [ "$(grep -c "st_ctime_ns // $tick \* $tick" "$coarse/release_stamp.py")" -eq 1 ]
    for attempt in 1 2; do
      STAMP_LIB="$coarse" run stamped_verify "$rel"
      [ "$status" -ne 0 ] && [ "$output" = full-verify ] || { echo "tick=$tick attempt=$attempt status=$status output=$output"; false; }
    done
    [ -z "$(ls -A "$STAMPS" 2>/dev/null)" ]
  done
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  STAMP_LIB="$coarse" run stamped_verify "$rel"
  refused_by_full_verify
}

# A copy of the stamp library whose program differs by one sed edit, which
# must change exactly one line.
mutant_lib() {  # <dir> <sed expression>
  mkdir -p "$1"
  cp "$LIB/release-stamp.sh" "$1/"
  sed "$2" "$LIB/release_stamp.py" > "$1/release_stamp.py"
  [ "$(diff "$LIB/release_stamp.py" "$1/release_stamp.py" | grep -c '^>')" -eq 1 ] ||
    { echo "sed $2 did not change exactly one line"; return 1; }
}

# Two calls through the caller pattern both take the full verify, and no stamp
# is ever written.
never_stamped() {  # <stamp lib> <release>
  local attempt
  for attempt in 1 2; do
    STAMP_LIB="$1" run stamped_verify "$2"
    [ "$status" -ne 0 ] && [ "$output" = full-verify ] ||
      { echo "attempt=$attempt status=$status output=$output"; return 1; }
  done
  [ -z "$(ls -A "$STAMPS" 2>/dev/null)" ]
}

# The executable bin/tool stands for an entry on a coarser or second device.
ONE_ENTRY='info.st_mode \& 0o100 and stat.S_ISREG(info.st_mode)'

@test "one coarse-ctime entry among fine ones is never stamped, and the full verify decides" {
  rel="$(install_release)"
  mutant_lib "$SANDBOX/mixed" \
    "s|info\\.st_ctime_ns|(info.st_ctime_ns // 1000000000 * 1000000000 if $ONE_ENTRY else info.st_ctime_ns)|"
  never_stamped "$SANDBOX/mixed" "$rel"
  tamper_keeping_size_and_mtime "$rel/payload/bin/tool"
  STAMP_LIB="$SANDBOX/mixed" run stamped_verify "$rel"
  refused_by_full_verify
}

@test "a release on two devices, or with its stamp directory on another, is never stamped" {
  rel="$(install_release)"
  mutant_lib "$SANDBOX/two-devices" "s|info\\.st_dev)\$|info.st_dev + (1 if $ONE_ENTRY else 0))|"
  never_stamped "$SANDBOX/two-devices" "$rel"
  mutant_lib "$SANDBOX/stamp-device" 's|os\.fstat(fd)\.st_dev|(os.fstat(fd).st_dev + 1)|'
  never_stamped "$SANDBOX/stamp-device" "$rel"
  tamper_keeping_size_and_mtime "$rel/payload/bin/tool"
  STAMP_LIB="$SANDBOX/two-devices" run stamped_verify "$rel"
  refused_by_full_verify
}

# Fine digits are not proof on their own: a kernel stamping ctime from a coarse
# clock writes full-precision values that only move once a tick.
@test "a filesystem whose metadata changes do not move ctime is never stamped" {
  rel="$(install_release)"
  mutant_lib "$SANDBOX/still-ctime" 's|^        os\.fchmod(fd, mode)$|        pass|'
  never_stamped "$SANDBOX/still-ctime" "$rel"
}

@test "two equal-size files swapped by rename fall back to the full verify, which refuses" {
  rel="$(stamped_release)"
  dir="$rel/payload/core-rules"
  [ "$(wc -c < "$dir/VERSION")" -eq "$(wc -c < "$dir/CLAUDE.md")" ]
  writable "$dir"
  mv "$dir/VERSION" "$dir/.swap"
  mv "$dir/CLAUDE.md" "$dir/VERSION"
  mv "$dir/.swap" "$dir/CLAUDE.md"
  sealed "$dir"
  run stamped_verify "$rel"
  refused_by_full_verify
}

@test "a truncated stamp falls back, and the full verify passes and restamps" {
  rel="$(stamped_release)"
  stamp="$(stamp_file "$rel")"
  head -c 100 "$stamp" > "$stamp.part"
  cat "$stamp.part" > "$stamp"
  rm -f "$stamp.part"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
}

@test "a garbage stamp falls back, and the full verify passes and restamps" {
  rel="$(stamped_release)"
  stamp="$(stamp_file "$rel")"
  printf '\0\377not json at all\n' > "$stamp"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
}

@test "a FIFO stamp is a miss at once, and the full verify passes and restamps" {
  rel="$(stamped_release)"
  stamp="$(stamp_file "$rel")"
  rm -f "$stamp"
  mkfifo -m 600 "$stamp"
  # Opening a FIFO with no writer blocks; the alarm turns a wait into a failure.
  run env HOME="$SANDBOX/user" perl -e 'alarm shift; exec @ARGV or exit 127' 10 \
    python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 1 ] || { echo "status=$status $output"; false; }
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
  [ -f "$stamp" ] && [ ! -p "$stamp" ]
}

@test "a schema 1 stamp from before the ctime proof is a miss, and the full verify restamps at schema 2" {
  rel="$(stamped_release)"
  stamp="$(stamp_file "$rel")"
  # The bytes the schema 1 writer rendered for this very release: same sweep,
  # same order, only the version differs.
  sed 's/"schema_version":[0-9]*,/"schema_version":1,/' "$stamp" > "$stamp.next"
  cat "$stamp.next" > "$stamp"
  rm -f "$stamp.next"
  [ "$(mode_of "$stamp")" = 600 ]
  run env HOME="$SANDBOX/user" python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 1 ] && [ "$output" != hit ] || { echo "status=$status $output"; false; }
  run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = $'full-verify\nstamp-written' ] || { echo "status=$status output=$output"; false; }
  jq -e '.schema_version == 2' "$stamp"
  run stamped_verify "$rel"
  [ "$status" -eq 0 ] && [ "$output" = stamp-hit ] || { echo "after: $output"; false; }
}

@test "a stamp for another release.json digest falls back, and the full verify decides" {
  rel="$(stamped_release)"
  stamp="$(stamp_file "$rel")"
  jq -c '.release_json_sha256 = ("0" * 64)' "$stamp" > "$stamp.next"
  cat "$stamp.next" > "$stamp"
  rm -f "$stamp.next"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"

  # A stamp left under another digest's name is never read for this release.
  mv "$stamp" "$STAMPS/1.0.0-$(printf '1%.0s' $(seq 64)).json"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
}

@test "a stamp that is not private, or a symlink, is a miss" {
  rel="$(stamped_release)"
  stamp="$(stamp_file "$rel")"
  chmod 644 "$stamp"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
  [ "$(mode_of "$stamp")" = 600 ]

  mv "$stamp" "$SANDBOX/real-stamp"
  ln -s "$SANDBOX/real-stamp" "$stamp"
  run stamped_verify "$rel"
  restamped_by_full_verify "$rel"
  [ ! -L "$stamp" ]
}

@test "write refuses when the release changed after the check" {
  rel="$(install_release)"
  run env HOME="$SANDBOX/user" bash -c '
    . "$1/release-stamp.sh"
    release_stamp_check "$2" "$3" && exit 90
    chmod u+w "$3/payload/core-rules/CLAUDE.md"
    chmod a-w "$3/payload/core-rules/CLAUDE.md"
    release_stamp_write "$2" "$3" && exit 91
    exit 0
  ' write-race "$LIB" "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ ! -e "$(stamp_file "$rel")" ]
}

@test "write refuses a release that is not sealed, whatever the caller verified" {
  rel="$(install_release)"
  writable "$rel/payload/bin/tool"
  run env HOME="$SANDBOX/user" bash -c '
    . "$1/release-stamp.sh"
    release_stamp_check "$2" "$3" && exit 90
    release_stamp_write "$2" "$3" && exit 91
    exit 0
  ' unsealed "$LIB" "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ ! -e "$(stamp_file "$rel")" ]
}

@test "a hit is memoized for the process and runs no second python; a child sweeps again" {
  rel="$(stamped_release)"
  shim="$SANDBOX/shim"
  mkdir -p "$shim"
  printf '#!/bin/sh\necho run >> "%s/runs"\nexec "%s" "$@"\n' "$SANDBOX" "$(command -v python3)" > "$shim/python3"
  chmod 755 "$shim/python3"
  # The gate runner exports TRELLIS_PYTHON, which would bypass the counting shim.
  run env -u TRELLIS_PYTHON HOME="$SANDBOX/user" PATH="$shim:$PATH" bash -c '
    . "$1/release-stamp.sh"
    release_stamp_check "$2" "$3" || exit 90
    release_stamp_check "$2" "$3" || exit 91
    first="$(wc -l < "$4/runs")"
    export _TRELLIS_RELEASE_STAMP_MEMO
    bash -c ". \"$1/release-stamp.sh\"; release_stamp_check \"$2\" \"$3\"" || exit 92
    printf "first=%s total=%s\n" "$first" "$(wc -l < "$4/runs")"
  ' memo "$LIB" "$TRELLIS_HOME" "$rel" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$(printf '%s' "$output" | tr -d ' ')" = "first=1total=2" ] || { echo "$output"; false; }
}

# A stamp check would miss forever on a stamp past STAMP_LIMIT, so write must
# refuse one too rather than rewrite it on every call. The limit is lowered to
# the size of release.json, which check must still read, in a copy.
@test "write refuses a stamp larger than check would read" {
  rel="$(install_release)"
  small="$SANDBOX/small-limit-lib"
  mkdir -p "$small"
  cp "$LIB/release-stamp.sh" "$small/"
  sed "s/^STAMP_LIMIT = .*/STAMP_LIMIT = $(wc -c < "$rel/release.json" | tr -d ' ')/" "$LIB/release_stamp.py" > "$small/release_stamp.py"
  [ "$(grep -c '^STAMP_LIMIT = 64 \* 1024 \* 1024$' "$small/release_stamp.py")" -eq 0 ]
  STAMP_LIB="$small" run stamped_verify "$rel"
  [ "$status" -ne 0 ] && [ "$output" = full-verify ] || { echo "status=$status output=$output"; false; }
  [ ! -e "$(stamp_file "$rel")" ]
  [ -z "$(ls -A "$STAMPS" 2>/dev/null)" ]
}

@test "an absolute executable TRELLIS_PYTHON runs the stamp program instead of PATH python3" {
  rel="$(stamped_release)"
  mkdir -p "$SANDBOX/shim" "$SANDBOX/chosen"
  printf '#!/bin/sh\necho shim >> "%s/runs"\nexit 97\n' "$SANDBOX" > "$SANDBOX/shim/python3"
  printf '#!/bin/sh\necho chosen >> "%s/runs"\nexec "%s" "$@"\n' "$SANDBOX" "$(command -v python3)" > "$SANDBOX/chosen/python"
  chmod 755 "$SANDBOX/shim/python3" "$SANDBOX/chosen/python"
  run env HOME="$SANDBOX/user" PATH="$SANDBOX/shim:$PATH" TRELLIS_PYTHON="$SANDBOX/chosen/python" bash -c \
    '. "$1/release-stamp.sh"; release_stamp_check "$2" "$3"' chosen "$LIB" "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
  [ "$(cat "$SANDBOX/runs")" = chosen ]

  # Relative or missing: PATH decides, here the failing shim, so the check misses.
  for choice in python "$SANDBOX/absent/python"; do
    : > "$SANDBOX/runs"
    run env HOME="$SANDBOX/user" PATH="$SANDBOX/shim:$PATH" TRELLIS_PYTHON="$choice" bash -c \
      '. "$1/release-stamp.sh"; release_stamp_check "$2" "$3"' fallback "$LIB" "$TRELLIS_HOME" "$rel"
    [ "$status" -ne 0 ] && [ "$(cat "$SANDBOX/runs")" = shim ] || { echo "$choice: status=$status runs=$(cat "$SANDBOX/runs")"; false; }
  done
}

@test "a TRELLIS_PYTHON that exits 0 without the hit line is a miss, and the full verify refuses" {
  rel="$(stamped_release)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  # /bin/true as a stub (macOS has none there), and one printing garbage. Each
  # logs its runs, so a fall back to PATH python3 cannot pass for a miss.
  printf '#!/bin/sh\necho silent >> "%s/runs"\nexit 0\n' "$SANDBOX" > "$SANDBOX/silent"
  printf '#!/bin/sh\necho garbage >> "%s/runs"\necho garbage\n' "$SANDBOX" > "$SANDBOX/garbage"
  chmod 755 "$SANDBOX/silent" "$SANDBOX/garbage"
  for choice in silent garbage; do
    : > "$SANDBOX/runs"
    export TRELLIS_PYTHON="$SANDBOX/$choice"
    run stamped_verify "$rel"
    refused_by_full_verify || { echo "TRELLIS_PYTHON=$choice"; false; }
    [ "$(sort -u "$SANDBOX/runs")" = "$choice" ] || { echo "$choice: runs=$(cat "$SANDBOX/runs")"; false; }
  done
}

@test "the stamp program is quote-free so the dispatcher can carry it" {
  [ "$(grep -c "'" "$LIB/release_stamp.py")" -eq 0 ]
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$LIB/release_stamp.py"
}

# ---------------------------------------------------------------------------
# T3: the managed dispatcher and the attachment postjob
# ---------------------------------------------------------------------------

# A release whose payload carries every file trellis_verify_release_executed
# lists, so both dispatcher checks can pass against it.
install_executed_release() {
  local rel="$TRELLIS_HOME/releases/2.0.0" path
  mkdir -p "$rel/payload"
  while IFS= read -r path; do
    mkdir -p "$rel/payload/${path%/*}"
    cp "$REPO_ROOT/$path" "$rel/payload/$path"
  done < <(sed -n '/^  local -a paths=($/,/^  )$/p' "$LIB/attachment.sh" | sed '1d;$d;s/^ *//')
  seal_release 2.0.0
  printf '%s\n' "$rel"
}

# The generated dispatcher's release checks, run in its own clean environment:
# managed_home, the pinned payload and release.json digest, a private TMPDIR.
# DISPATCHER_PATH replaces its PATH.
dispatcher_check() {
  local fn="$1" rel="$2" body functions
  body="$(env HOME="$SANDBOX/user" bash -c '
    . "$1/trellis-home.sh"; . "$1/release-store.sh"; . "$1/local-registry.sh"
    . "$1/surface-plan.sh"; . "$1/attachment.sh"
    _attachment_hooks_pre_push_dispatcher_body_in_process "$2" core-rules/husky/pre-push "$3"
  ' generate "$LIB" "$rel/payload" "$(sha256_of "$rel/release.json")")" || return 90
  functions="$(printf '%s\n' "$body" | awk '/^expected_payload=/ { on = 1 } /^trellis_prior_hook\(\) \{$/ { exit } on { print }')"
  [ -n "$functions" ] || return 91
  env -i PATH="${DISPATCHER_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" HOME=/dev/null LC_ALL=C TMPDIR="$SANDBOX/tmp" \
    /bin/bash --noprofile --norc -c 'managed_home="$1"; eval "$2"; "$3" "$4"' \
    dispatcher "$TRELLIS_HOME" "$functions" "$fn" "$rel/payload"
}

@test "dispatcher: the full verify writes the stamp, an unchanged release hits it, a change falls back" {
  rel="$(install_executed_release)"
  run dispatcher_check trellis_verify_release "$rel"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  stamp="$(stamp_file "$rel")"
  [ -f "$stamp" ]
  before="$(cat "$stamp")"
  run dispatcher_check trellis_verify_release "$rel"
  [ "$status" -eq 0 ]
  [ "$(cat "$stamp")" = "$before" ]

  tamper_keeping_size_and_mtime "$rel/payload/scripts/lib/semver.sh"
  run dispatcher_check trellis_verify_release "$rel"
  [ "$status" -ne 0 ]
  run dispatcher_check trellis_verify_release_executed "$rel"
  [ "$status" -ne 0 ]
}

@test "dispatcher: a python3 that exits 0 without the hit line is a miss, and the full verify refuses" {
  local real
  rel="$(install_executed_release)"
  tamper_keeping_size_and_mtime "$rel/payload/scripts/lib/semver.sh"
  real="$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v python3)"
  # Silent exit 0 for the stamp check only; the full verify runs real python3.
  mkdir -p "$SANDBOX/stub"
  printf '#!/bin/sh\nif [ "$4" = check ]; then echo check >> "%s/runs"; exit 0; fi\nexec "%s" "$@"\n' \
    "$SANDBOX" "$real" > "$SANDBOX/stub/python3"
  chmod 755 "$SANDBOX/stub/python3"
  export DISPATCHER_PATH="$SANDBOX/stub:/usr/bin:/bin:/usr/sbin:/sbin"
  for fn in trellis_verify_release trellis_verify_release_executed; do
    : > "$SANDBOX/runs"
    run dispatcher_check "$fn" "$rel"
    [ "$status" -ne 0 ] || { echo "$fn took a silent exit 0 as a hit"; false; }
    [ "$(cat "$SANDBOX/runs")" = check ] || { echo "$fn: runs=$(cat "$SANDBOX/runs")"; false; }
  done
}

# The full verify that writes stamps reads ACLs only through `ls -ld`, where a
# macOS xattr's "@" hides the "+". A stamp therefore never vouches for ACLs, and
# the executed check runs its own ACL refusal on every call, stamp hit or not.
@test "dispatcher: the executed check refuses an ACL the stamping full verify missed" {
  rel="$(install_executed_release)"
  file="$rel/payload/scripts/lib/semver.sh"
  case "$(uname -s)" in
    Darwin)
      chmod u+w "$file"
      xattr -w com.trellis.fixture 1 "$file"
      chmod a-w "$file"
      chmod +a "$(id -un) allow write" "$file" 2>/dev/null || skip 'chmod +a is unsupported here'
      ;;
    *)
      command -v setfacl >/dev/null 2>&1 || skip 'setfacl is missing'
      setfacl -m "u:$(id -un):w" "$file" 2>/dev/null || skip 'setfacl is unsupported here'
      ;;
  esac
  run dispatcher_check trellis_verify_release "$rel"
  [ "$status" -eq 0 ] || skip 'the full verify already refuses this ACL, so no stamp can cover it'
  [ -f "$(stamp_file "$rel")" ]
  run dispatcher_check trellis_verify_release_executed "$rel"
  [ "$status" -ne 0 ] || { echo 'the stamp hit skipped the ACL refusal'; false; }
}

# Reopen a sealed release, run "$@" inside its payload, and seal it again.
reseal_release() {
  local rel="$1"
  shift
  find "$rel" -type d -exec chmod u+w {} +
  rm -f "$rel/release.json"
  (CDPATH='' cd "$rel/payload" && "$@")
  seal_release "${rel##*/}"
}

# The full verify accepts a listed file as a link, and its lexical link check
# accepts one that resolves outside the release, so its stamp must not let the
# executed check skip its own no-link rule.
@test "dispatcher: a stamp never covers a listed file the executed check refuses as a link" {
  local layout
  for layout in sibling escape; do
    find "$TRELLIS_HOME/releases" -type d -exec chmod u+w {} +
    rm -rf "$TRELLIS_HOME/releases/2.0.0" "$STAMPS"
    rel="$(install_executed_release)"
    case "$layout" in
      sibling)
        reseal_release "$rel" sh -c 'mv scripts/lib/semver.sh scripts/lib/semver-copy.sh &&
          ln -s semver-copy.sh scripts/lib/semver.sh' ;;
      escape)
        cp "$rel/payload/scripts/lib/semver.sh" "$TRELLIS_HOME/evil.sh"
        reseal_release "$rel" sh -c 'ln -s ../.. scripts/lib/alias && rm -f scripts/lib/semver.sh &&
          ln -s alias/../../../evil.sh scripts/lib/semver.sh' ;;
    esac
    [ -L "$rel/payload/scripts/lib/semver.sh" ]
    run dispatcher_check trellis_verify_release_executed "$rel"
    [ "$status" -ne 0 ] || { echo "$layout: unstamped executed check accepted the link"; false; }
    run dispatcher_check trellis_verify_release "$rel"
    [ "$status" -eq 0 ] || skip "$layout: the full verify refuses this layout, so no stamp can cover it"
    [ -f "$(stamp_file "$rel")" ]
    run dispatcher_check trellis_verify_release_executed "$rel"
    [ "$status" -ne 0 ] || { echo "$layout: the stamp hit skipped the no-link rule"; false; }
  done
}

# The executed check writes no stamp (it is not a full verify). A stamp that
# matches the release skips its hashing: shown with a stamp forged over a
# tampered listed file, which D-A accepts from the same user. release_store_locate
# reads the same stamp, so it accepts the forgery too; the explicit full verify
# (release_store_verify: `trellis release verify`, doctor's integrity rows) still
# refuses that release.
@test "dispatcher: the executed check reads the stamp but never writes one" {
  rel="$(install_executed_release)"
  run dispatcher_check trellis_verify_release_executed "$rel"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$STAMPS" ]

  tamper_keeping_size_and_mtime "$rel/payload/scripts/lib/semver.sh"
  run dispatcher_check trellis_verify_release_executed "$rel"
  [ "$status" -ne 0 ]
  run python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 1 ]
  python3 -I "$LIB/release_stamp.py" write "$TRELLIS_HOME" "$rel" "$output"
  run dispatcher_check trellis_verify_release_executed "$rel"
  [ "$status" -eq 0 ]
  run locate 2.0.0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1/release-store.sh"; release_store_verify 2.0.0' verify "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *'changed release content: scripts/lib/semver.sh'* ]] || { echo "$output"; false; }
}

# attach_postjob_verify's release leg, with release_store_locate wrapped to log
# each call. Prints the leg's verdict line, then the number of locate calls.
postjob_release_leg() {
  local rel="$1" owner="$SANDBOX/owner.json"
  jq -n --arg target "$rel/payload" \
    '{release: "1.0.0", artifacts: [{path: ".trellis/runtime", kind: "symlink", target: $target}]}' > "$owner"
  : > "$SANDBOX/locates"
  env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/trellis-home.sh"; . "$1/release-store.sh"; . "$1/local-registry.sh"
    . "$1/surface-plan.sh"; . "$1/attachment.sh"; . "$1/attach-postjob.sh"
    eval "$(declare -f release_store_locate | sed "1s/release_store_locate/real_release_store_locate/")"
    locates="$4/locates"
    release_store_locate() { echo locate >> "$locates"; real_release_store_locate "$@"; }
    attach_postjob_verify "$2" "$3" "$4/project" 2>/dev/null | head -n 1
    wc -l < "$locates" | tr -d " "
  ' postjob "$LIB" "$TRELLIS_HOME" "$owner" "$SANDBOX"
}

@test "postjob: an unchanged stamped release skips release_store_locate; a change takes it" {
  rel="$(install_release)"
  run postjob_release_leg "$rel"
  [ "$output" = $'pass\trelease\n1' ] || { echo "$output"; false; }
  [ -f "$(stamp_file "$rel")" ]
  run postjob_release_leg "$rel"
  [ "$output" = $'pass\trelease\n0' ] || { echo "$output"; false; }

  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  run postjob_release_leg "$rel"
  [[ "${lines[0]}" == $'fail\trelease\t'* ]] || { echo "$output"; false; }
  [ "${lines[1]}" = 1 ]
}

# ---------------------------------------------------------------------------
# release_store_locate reads the stamp (show-config, doctor, attach, configure)
# ---------------------------------------------------------------------------

locate() {
  env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$TRELLIS_HOME" bash -c \
    '. "$1/release-store.sh"; release_store_locate "$2"' locate "$LIB" "$1"
}

# A full verify allocates its scratch in the release store, so with the store
# read-only any full verify fails, and a locate that passes there took no full
# verify.
@test "locate: a stamp hit skips the full verify, a miss takes it, and locate writes no stamp" {
  rel="$(install_release)"
  run locate 1.0.0
  [ "$status" -eq 0 ] && [ "$output" = "$rel" ] || { echo "$output"; false; }
  [ ! -e "$STAMPS" ] || { echo 'locate wrote a stamp'; false; }

  # No stamp: a read-only store refuses, because the miss takes the full verify.
  chmod 500 "$TRELLIS_HOME/releases"
  run locate 1.0.0
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  chmod 700 "$TRELLIS_HOME/releases"

  run stamped_verify "$rel"
  [ "$output" = $'full-verify\nstamp-written' ] || { echo "$output"; false; }
  chmod 500 "$TRELLIS_HOME/releases"
  run locate 1.0.0
  [ "$status" -eq 0 ] && [ "$output" = "$rel" ] || { echo "stamp hit: $output"; false; }

  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  run locate 1.0.0
  [ "$status" -eq 5 ] || { echo "miss took no full verify: $output"; false; }
  chmod 700 "$TRELLIS_HOME/releases"
  run locate 1.0.0
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'changed release content: core-rules/CLAUDE.md'* ]] || { echo "$output"; false; }
}

@test "locate: a stamp hit counts as the shell's verify, as a full verify would" {
  rel="$(install_release)"
  run stamped_verify "$rel"
  [ "$output" = $'full-verify\nstamp-written' ] || { echo "$output"; false; }
  chmod 500 "$TRELLIS_HOME/releases"
  run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$TRELLIS_HOME" bash -c '
    . "$1/release-store.sh"
    release_store_locate 1.0.0 >/dev/null || exit 71
    release_store_verify 1.0.0 || exit 72
  ' memo "$LIB"
  [ "$status" -eq 0 ] || { echo "status=$status $output"; false; }
}

# The full verify reads ACLs only through `ls -ld`, where a macOS xattr's "@"
# hides the "+", so a stamp cannot vouch for ACLs: the refusal runs first.
@test "locate: an ACL is refused before any stamp hit" {
  rel="$(install_release)"
  file="$rel/payload/core-rules/CLAUDE.md"
  case "$(uname -s)" in
    Darwin)
      chmod u+w "$file"
      xattr -w com.trellis.fixture 1 "$file"
      chmod a-w "$file"
      chmod +a "$(id -un) allow write" "$file" 2>/dev/null || skip 'chmod +a is unsupported here'
      ;;
    *)
      command -v setfacl >/dev/null 2>&1 || skip 'setfacl is missing'
      # A write ACL also sets the POSIX group-write mask on Linux, which the
      # stamp's sealed-mode check refuses before the ACL refusal is exercised.
      setfacl -m "u:$(id -un):r" "$file" 2>/dev/null || skip 'setfacl is unsupported here'
      ;;
  esac
  # A stamp over the release exactly as it now is (D-A: the same user can).
  run python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 1 ]
  python3 -I "$LIB/release_stamp.py" write "$TRELLIS_HOME" "$rel" "$output"
  run python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME" "$rel"
  [ "$status" -eq 0 ] || { echo 'fixture: the stamp does not match'; false; }

  run locate 1.0.0
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'release content carries an ACL'* ]] || { echo "$output"; false; }
}
