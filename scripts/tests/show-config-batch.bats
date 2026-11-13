#!/usr/bin/env bats
# Spec 074 T5: show-config's release audit runs in one process
# (scripts/lib/release_verify.py), stays a full audit, and never answers from a
# release stamp. Every refusal the shell pass makes, the batch pass makes with
# the same finding, or reaches no verdict and leaves it to the shell pass.
# Duplicate, unsafe and unknown-mode manifest rows never reach either pass:
# release_store_json_valid refuses them first.

load release-store-common
load helpers/native-render-fixture

LIB="$REPO_ROOT/scripts/lib"

setup() {
  export TRELLIS_ATTACH_POSTJOB=off
  GROUP_PLAN_CASE_LOCK_HELD=false
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/show-config-batch.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  STORE="$SANDBOX/store-home"
  mkdir -p "$STORE/releases" "$SANDBOX/user" "$SANDBOX/tmp"
  chmod 700 "$STORE" "$STORE/releases"
}

# Seal $STORE/releases/<version>/payload: release.json from one git
# hash-object pass, everything a-w.
seal_small_release() {
  local version="$1" rel="$STORE/releases/$1" work path full idx=0
  work="$(mktemp -d "$SANDBOX/manifest.XXXXXX")"
  (CDPATH='' cd "$rel/payload" && find . -mindepth 1 \( -type f -o -type l \) -print | sed 's|^\./||' | /usr/bin/env LC_ALL=C sort) > "$work/paths"
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
      commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", remote: "fixture://show-config-batch",
      tree: [inputs | select(length > 0) | split("\t") | {mode: .[0], oid: .[1], path: .[2]}]
    }' > "$rel/release.json"
  rm -rf "$work"
  find "$rel" -type f -exec chmod a-w {} +
  find "$rel" -type d -exec chmod a-w {} +
}

# VERSION and CLAUDE.md are the same size, for the swap cases.
install_small_release() {
  local version="${1:-1.0.0}" rel="$STORE/releases/${1:-1.0.0}"
  mkdir -p "$rel/payload/core-rules" "$rel/payload/bin"
  printf '1.0.0\n' > "$rel/payload/core-rules/VERSION"
  printf 'rules\n' > "$rel/payload/core-rules/CLAUDE.md"
  printf '#!/bin/sh\nexit 0\n' > "$rel/payload/bin/tool"
  chmod 755 "$rel/payload/bin/tool"
  ln -s core-rules/VERSION "$rel/payload/AGENTS.md"
  seal_small_release "$version"
  printf '%s\n' "$rel"
}

unseal() { find "$1" -type d -exec chmod u+w {} +; }
reseal() { find "$1" -type d -exec chmod a-w {} +; }

# Rewrite a file's bytes in place, same size, then put its mtime back: only the
# content (Git blob ID) differs from what release.json records.
tamper_keeping_size_and_mtime() {
  python3 -I - "$1" <<'PY'
import os, sys
path = sys.argv[1]
info = os.stat(path)
os.chmod(path, 0o600)
with open(path, "r+b") as handle:
    data = handle.read()
    handle.seek(0)
    handle.write(bytes([data[0] ^ 0x20]) + data[1:])
os.chmod(path, info.st_mode & 0o7777)
os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
PY
}

# Apply one named change to a sealed release.
apply_case() {
  local rel="$1" name="$2" p="$1/payload"
  case "$name" in
    intact) ;;
    content) tamper_keeping_size_and_mtime "$p/core-rules/CLAUDE.md" ;;
    exec-added) chmod a+x "$p/core-rules/VERSION" ;;
    exec-removed) chmod a-x "$p/bin/tool" ;;
    setuid) chmod u+s "$p/core-rules/VERSION" ;;
    file-to-link) unseal "$rel"; rm -f "$p/core-rules/CLAUDE.md"; ln -s VERSION "$p/core-rules/CLAUDE.md"; reseal "$rel" ;;
    link-to-file) unseal "$rel"; rm -f "$p/AGENTS.md"; printf '1.0.0\n' > "$p/AGENTS.md"; chmod a-w "$p/AGENTS.md"; reseal "$rel" ;;
    link-escapes) unseal "$rel"; rm -f "$p/AGENTS.md"; ln -s ../../escape "$p/AGENTS.md"; reseal "$rel" ;;
    link-retargeted) unseal "$rel"; rm -f "$p/AGENTS.md"; ln -s core-rules/CLAUDE.md "$p/AGENTS.md"; reseal "$rel" ;;
    added-file) unseal "$rel"; printf 'x\n' > "$p/core-rules/extra"; chmod a-w "$p/core-rules/extra"; reseal "$rel" ;;
    added-dir) unseal "$rel"; mkdir "$p/core-rules/empty"; reseal "$rel" ;;
    removed-file) unseal "$rel"; rm -f "$p/core-rules/CLAUDE.md"; reseal "$rel" ;;
    writable-file) chmod u+w "$p/core-rules/VERSION" ;;
    writable-dir) chmod u+w "$p/core-rules" ;;
    writable-record) chmod u+w "$rel/release.json" ;;
    top-level-entry) chmod u+w "$rel"; printf 'x\n' > "$rel/extra"; chmod a-w "$rel/extra" "$rel" ;;
    symlinked-parent) unseal "$rel"; mv "$p/core-rules" "$p/real"; ln -s real "$p/core-rules"; reseal "$rel" ;;
    fifo) unseal "$rel"; mkfifo "$p/core-rules/fifo"; reseal "$rel" ;;
    dir-for-file) unseal "$rel"; rm -f "$p/core-rules/VERSION"; mkdir "$p/core-rules/VERSION"; reseal "$rel" ;;
    file-for-dir) unseal "$rel"; rm -rf "$p/bin"; printf 'x\n' > "$p/bin"; chmod a-w "$p/bin"; reseal "$rel" ;;
    *) return 1 ;;
  esac
}

CASES="intact content exec-added exec-removed setuid file-to-link link-to-file link-escapes
link-retargeted added-file added-dir removed-file writable-file writable-dir writable-record
top-level-entry symlinked-parent fifo dir-for-file file-for-dir"

# One pass over $1 (a canonical release dir). Prints, sorted, the exit status,
# the "trellis release:" findings and the -/+ path lines of a membership diff. batch calls release_verify.py through the
# library and fails the test unless it reached a verdict; shell runs the
# per-entry pass with the program unset.
verify_with() {
  local pass="$1" rel="$2" skip="$3"
  env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" bash -c '
    . "$1/release-store.sh"
    if [ "$2" = batch ]; then
      release_store_verify_batch "$3" "$4" 2>&1
      rc=$?
      [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || rc=99
    else
      _RELEASE_STORE_VERIFY_PROGRAM=""
      release_store_verify_path "$3" 1.0.0 "$4" 0 2>&1
      rc=$?
    fi
    echo "status=$rc"
  ' verify "$LIB" "$pass" "$rel" "$skip" | grep -E '^(trellis release: |status=|[-+][^-+])' | LC_ALL=C sort
}

@test "batch and shell passes give the same verdict and findings for every change" {
  local name skip rel batch shell expected
  for name in $CASES; do
    for skip in 0 1; do
      rm -rf "$STORE/releases/1.0.0" 2>/dev/null || { unseal "$STORE/releases/1.0.0"; rm -rf "$STORE/releases/1.0.0"; }
      rel="$(install_small_release 1.0.0)"
      apply_case "$rel" "$name"
      batch="$(verify_with batch "$rel" "$skip")"
      shell="$(verify_with shell "$rel" "$skip")"
      [ "$batch" = "$shell" ] || {
        printf 'case %s skip=%s\n--- batch\n%s\n--- shell\n%s\n' "$name" "$skip" "$batch" "$shell"
        false
      }
      case "$name:$skip" in
        intact:*|writable-*:1) expected='status=0' ;;
        *) expected='status=4' ;;
      esac
      printf '%s\n' "$batch" | grep -qx "$expected" || {
        printf 'case %s skip=%s: want %s\n%s\n' "$name" "$skip" "$expected" "$batch"
        false
      }
    done
    unseal "$rel"
    rm -rf "$rel"
  done
}

# The shell pass reads an ACL only through `ls -ld`, where a macOS xattr's "@"
# hides the "+". The batch pass asks for the ACL itself, so it refuses every
# ACL the shell pass refuses, and the ones that "@" hides from it.
@test "batch pass refuses an ACL on a file, a directory or release.json, xattr or not" {
  local target rel out
  for target in payload/core-rules/CLAUDE.md payload/core-rules release.json; do
    rel="$(install_small_release 1.0.0)"
    case "$(uname -s)" in
      Darwin)
        chmod u+w "$rel/$target"
        xattr -w com.trellis.fixture 1 "$rel/$target"
        chmod a-w "$rel/$target"
        chmod +a "$(id -un) allow read" "$rel/$target" 2>/dev/null || skip 'chmod +a is unsupported here'
        ;;
      *)
        command -v setfacl >/dev/null 2>&1 || skip 'setfacl is missing'
        setfacl -m "u:$(id -un):r" "$rel/$target" 2>/dev/null || skip 'setfacl is unsupported here'
        ;;
    esac
    out="$(verify_with batch "$rel" 0)"
    printf '%s\n' "$out" | grep -qx status=4 || { echo "$target: $out"; false; }
    case "$target" in
      release.json) [[ "$out" == *'writable release record: release.json'* ]] ;;
      payload/core-rules) [[ "$out" == *'writable release directory: payload/core-rules'* ]] ;;
      *) [[ "$out" == *"writable release content: core-rules/CLAUDE.md"* ]] ;;
    esac || { echo "$target: $out"; false; }
    out="$(verify_with batch "$rel" 1)"
    [ "$out" = status=0 ] || { echo "$target skip: $out"; false; }
    unseal "$rel"
    rm -rf "$rel"
  done
}

# jq's @tsv doubles a backslash and its decoder replaces a lone surrogate
# escape, so the shell pass looks for another name than the manifest holds.
# The batch pass reaches no verdict on such a manifest and the shell pass
# decides it, so the two never disagree.
@test "a manifest path the shell pass reads differently gets no batch verdict" {
  local name rel full shell
  for name in 'back\slash' surrogate; do
    rel="$STORE/releases/1.0.0"
    [ ! -d "$rel" ] || { unseal "$rel"; rm -rf "$rel"; }
    mkdir -p "$rel/payload/core-rules"
    printf 'rules\n' > "$rel/payload/core-rules/CLAUDE.md"
    if [ "$name" = surrogate ]; then
      [ "$(uname -s)" != Darwin ] || continue  # APFS refuses a name that is not UTF-8
      printf 'x\n' > "$rel/payload/core-rules/$(printf '\200')"
      seal_small_release 1.0.0
      unseal "$rel"; chmod u+w "$rel/release.json"
      # jq -R wrote the name's 0x80 byte as U+FFFD; name it by the escape the
      # filesystem name round-trips through in python instead.
      python3 -I - "$rel/release.json" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace("core-rules/�", "core-rules/\\udc80"))
PY
      chmod a-w "$rel/release.json"; reseal "$rel"
      grep -q 'core-rules/\\udc80' "$rel/release.json" || { echo 'fixture: no escape'; false; }
    else
      printf 'x\n' > "$rel/payload/core-rules/$name"
      seal_small_release 1.0.0
    fi
    full="$(verify_with batch "$rel" 0)"
    [ "$full" = status=99 ] || { echo "$name batch: $full"; false; }
    shell="$(verify_with shell "$rel" 0)"
    printf '%s\n' "$shell" | grep -qx status=4 || { echo "$name shell: $shell"; false; }
    run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" bash -c \
      '. "$1/release-store.sh"; release_store_verify_path "$2" 1.0.0' verify "$LIB" "$rel"
    [ "$status" -eq 4 ] || { echo "$name: $output"; false; }
  done
}

# An interpreter that decides nothing hands the verdict to the shell pass; it
# can never pass a release by failing.
@test "no verdict from the batch pass falls back to the shell pass" {
  rel="$(install_small_release 1.0.0)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  for python in /usr/bin/false /usr/bin/true "$SANDBOX/missing-python"; do
    run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" TRELLIS_PYTHON="$python" \
      bash -c '. "$1/release-store.sh"; release_store_verify_batch "$2" 0; echo "batch=$?"
        release_store_verify_path "$2" 1.0.0' verify "$LIB" "$rel"
    [ "$status" -eq 4 ] || { echo "$python: $output"; false; }
    [[ "$output" == *'changed release content: core-rules/CLAUDE.md'* ]] || { echo "$python: $output"; false; }
  done
  # false and true decide nothing; a missing TRELLIS_PYTHON falls through to
  # python3 on PATH, which refuses.
  run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" TRELLIS_PYTHON=/usr/bin/true \
    bash -c '. "$1/release-store.sh"; release_store_verify_batch "$2" 0' verify "$LIB" "$rel"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

# --- hc_portable_release: the audit show-config and doctor run --------------

# Run hc_portable_release with logging shims for git and python3 on PATH.
# Prints the health line, then counts of `git hash-object` and of
# release_verify.py runs.
hc_release() {
  local version="$1"
  mkdir -p "$SANDBOX/bin"
  REAL_GIT="$(command -v git)" REAL_PY="$(command -v python3)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/git.log"\nexec "%s" "$@"\n' "$SANDBOX" "$REAL_GIT" > "$SANDBOX/bin/git"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/python.log"\nexec "%s" "$@"\n' "$SANDBOX" "$REAL_PY" > "$SANDBOX/bin/python3"
  chmod 755 "$SANDBOX/bin/git" "$SANDBOX/bin/python3"
  : > "$SANDBOX/git.log"
  : > "$SANDBOX/python.log"
  env -u TRELLIS_PYTHON HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" \
    PATH="$SANDBOX/bin:$PATH" bash -c '
    lib="$1"
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    hc_portable_release "$2" "$3"
    echo "rc=$?"
  ' hc "$LIB" "$STORE" "$version"
  printf 'hash-object=%s\n' "$(grep -c 'hash-object' "$SANDBOX/git.log")"
  printf 'release_verify=%s\n' "$(grep -cE 'release_verify.py .* [01]$' "$SANDBOX/python.log")"
}

stamp_now() {
  local rel="$1" token
  token="$(python3 -I "$LIB/release_stamp.py" check "$STORE" "$rel")" && return 0
  python3 -I "$LIB/release_stamp.py" write "$STORE" "$rel" "$token"
  python3 -I "$LIB/release_stamp.py" check "$STORE" "$rel" >/dev/null
}

stamp_count() {
  find "$STORE/state/release-stamps" -type f 2>/dev/null | wc -l | tr -d ' '
}

@test "hc_portable_release: missing stamp, intact release, one batch audit and no stamp written" {
  rel="$(install_small_release 1.0.0)"
  [ "$(stamp_count)" = 0 ]
  run hc_release 1.0.0
  [ "${lines[0]}" = 'immutable release: 1.0.0 passed installed payload integrity verification' ] || { echo "$output"; false; }
  [ "${lines[1]}" = rc=0 ] && [ "${lines[2]}" = hash-object=0 ] && [ "${lines[3]}" = release_verify=1 ] ||
    { echo "$output"; false; }
  [ "$(stamp_count)" = 0 ] || { echo 'the audit wrote a stamp'; false; }
}

@test "hc_portable_release: missing stamp, tampered release, refused by the batch audit" {
  rel="$(install_small_release 1.0.0)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  run hc_release 1.0.0
  [[ "${lines[0]}" == 'immutable release: 1.0.0 is corrupt or unsafe'* ]] || { echo "$output"; false; }
  [ "${lines[1]}" = rc=1 ] && [ "${lines[2]}" = hash-object=0 ] && [ "${lines[3]}" = release_verify=1 ] ||
    { echo "$output"; false; }
}

# A stale stamp (written, then the release changed) misses; the audit decides.
@test "hc_portable_release: stale stamp, tampered release, refused by the batch audit" {
  rel="$(install_small_release 1.0.0)"
  stamp_now "$rel"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  run python3 -I "$LIB/release_stamp.py" check "$STORE" "$rel"
  [ "$status" -eq 1 ] || { echo 'fixture: the stamp still matches'; false; }
  run hc_release 1.0.0
  [[ "${lines[0]}" == 'immutable release: 1.0.0 is corrupt or unsafe'* ]] || { echo "$output"; false; }
  [ "${lines[1]}" = rc=1 ] && [ "${lines[2]}" = hash-object=0 ] && [ "${lines[3]}" = release_verify=1 ] ||
    { echo "$output"; false; }
}

@test "hc_portable_release: stale stamp, intact release, passes by the batch audit" {
  rel="$(install_small_release 1.0.0)"
  stamp_now "$rel"
  chmod u+w "$rel/payload/core-rules/VERSION"
  chmod a-w "$rel/payload/core-rules/VERSION"
  run python3 -I "$LIB/release_stamp.py" check "$STORE" "$rel"
  [ "$status" -eq 1 ] || { echo 'fixture: the stamp still matches'; false; }
  run hc_release 1.0.0
  [ "${lines[1]}" = rc=0 ] && [ "${lines[2]}" = hash-object=0 ] && [ "${lines[3]}" = release_verify=1 ] ||
    { echo "$output"; false; }
}

# A stamp written over the tampered release matches it (spec 072 D-A: the same
# user can). show-config's audit must still refuse: it never reads a stamp.
@test "hc_portable_release: a stamp that matches a tampered release does not vouch for it" {
  rel="$(install_small_release 1.0.0)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  stamp_now "$rel"
  run python3 -I "$LIB/release_stamp.py" check "$STORE" "$rel"
  [ "$status" -eq 0 ] && [ "$output" = hit ] || { echo 'fixture: no stamp hit'; false; }
  run hc_release 1.0.0
  [[ "${lines[0]}" == 'immutable release: 1.0.0 is corrupt or unsafe'* ]] || { echo "$output"; false; }
  [ "${lines[1]}" = rc=1 ] && [ "${lines[2]}" = hash-object=0 ] && [ "${lines[3]}" = release_verify=1 ] ||
    { echo "$output"; false; }
}

# release_store_locate records a stamp hit in this shell's memo (spec 072 D-A),
# and a plain release_store_verify accepts it. The audit behind show-config's
# and doctor's "verified" rows must not: it answers only from a full verify,
# whichever call ran first in the shell.
@test "a same-shell stamp hit does not stand in for the full audit" {
  rel="$(install_small_release 1.0.0)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  stamp_now "$rel"
  run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" bash -c '
    lib="$1"
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    release_store_locate 1.0.0 >/dev/null 2>&1 || exit 71
    release_store_verify 1.0.0 >/dev/null 2>&1; echo "verify=$?"
    release_store_audit 1.0.0 >/dev/null 2>&1; echo "audit=$?"
    hc_portable_release "$2" 1.0.0; echo "hc=$?"
  ' memo "$LIB" "$STORE"
  [ "${lines[0]}" = verify=0 ] || { echo "fixture: the stamp entry was not taken: $output"; false; }
  [ "${lines[1]}" = audit=4 ] || { echo "$output"; false; }
  [[ "${lines[2]}" == 'immutable release: 1.0.0 is corrupt or unsafe'* ]] && [ "${lines[3]}" = hc=1 ] ||
    { echo "$output"; false; }
}

# The whole-store verify (`trellis release verify`, doctor's store row) is an
# audit too: a stamp entry for one of its releases does not answer it.
@test "a whole-store verify does not take a same-shell stamp hit" {
  rel="$(install_small_release 1.0.0)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  stamp_now "$rel"
  run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" bash -c '
    lib="$1"
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    release_store_locate 1.0.0 >/dev/null 2>&1 || exit 71
    release_store_verify >/dev/null 2>&1; echo "store=$?"
    hc_portable_release_store "$2"; echo "hc=$?"
  ' memo "$LIB" "$STORE"
  [ "${lines[0]}" = store=4 ] || { echo "$output"; false; }
  [[ "${lines[1]}" == 'immutable releases: installed release store is unavailable, corrupt, or unsafe'* ]] &&
    [ "${lines[2]}" = hc=1 ] || { echo "$output"; false; }
}

# A full verify's own entry still serves the next audit in the same shell, so
# show-config's active-release audit covers its attachment row: one batch run.
@test "a full audit's memo entry serves the next audit; a stamp entry does not" {
  rel="$(install_small_release 1.0.0)"
  stamp_now "$rel"
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/python.log"\nexec "%s" "$@"\n' "$SANDBOX" "$(command -v python3)" > "$SANDBOX/bin/python3"
  chmod 755 "$SANDBOX/bin/python3"
  : > "$SANDBOX/python.log"
  run env -u TRELLIS_PYTHON HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" \
    PATH="$SANDBOX/bin:$PATH" bash -c '
    . "$1/release-store.sh"
    release_store_locate 1.0.0 >/dev/null || exit 71
    echo "after-locate=$(grep -cE "release_verify.py .* [01]\$" "$2/python.log")"
    release_store_audit 1.0.0 || exit 72
    echo "after-audit=$(grep -cE "release_verify.py .* [01]\$" "$2/python.log")"
    release_store_audit 1.0.0 || exit 73
    echo "after-second=$(grep -cE "release_verify.py .* [01]\$" "$2/python.log")"
  ' memo "$LIB" "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = $'after-locate=0\nafter-audit=1\nafter-second=1' ] || { echo "$output"; false; }
}

# release_store_locate refuses an ACL on every call, stamp hit or not. The batch
# program now answers that question in one process; it must still refuse an
# ACL a matching stamp would otherwise cover, xattr or not.
locate_logged() {
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/python.log"\nexec "%s" "$@"\n' "$SANDBOX" "$(command -v python3)" > "$SANDBOX/bin/python3"
  chmod 755 "$SANDBOX/bin/python3"
  : > "$SANDBOX/python.log"
  env -u TRELLIS_PYTHON HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" \
    PATH="$SANDBOX/bin:$PATH" bash -c '. "$1/release-store.sh"; release_store_locate 1.0.0' locate "$LIB"
  echo "status=$?"
  printf 'acl-checks=%s\n' "$(grep -c 'release_verify.py .* acl$' "$SANDBOX/python.log")"
}

@test "locate's ACL refusal is answered in one process and still refuses behind a stamp hit" {
  rel="$(install_small_release 1.0.0)"
  stamp_now "$rel"
  run locate_logged
  [ "${lines[0]}" = "$rel" ] && [ "${lines[1]}" = status=0 ] && [ "${lines[2]}" = acl-checks=1 ] ||
    { echo "intact: $output"; false; }
  file="$rel/payload/core-rules/CLAUDE.md"
  case "$(uname -s)" in
    Darwin)
      chmod u+w "$file"
      xattr -w com.trellis.fixture 1 "$file"
      chmod a-w "$file"
      chmod +a "$(id -un) allow read" "$file" 2>/dev/null || skip 'chmod +a is unsupported here'
      ;;
    *)
      command -v setfacl >/dev/null 2>&1 || skip 'setfacl is missing'
      setfacl -m "u:$(id -un):r" "$file" 2>/dev/null || skip 'setfacl is unsupported here'
      ;;
  esac
  stamp_now "$rel"
  run python3 -I "$LIB/release_stamp.py" check "$STORE" "$rel"
  [ "$output" = hit ] || { echo 'fixture: no stamp hit over the ACL'; false; }
  run locate_logged
  [[ "$output" == *'release content carries an ACL'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'status=4\nacl-checks=1'* ]] || { echo "$output"; false; }
}

# --- show-config through the stable launcher ------------------------------

# A same-size change to a payload file show-config never runs, with a stamp
# over the changed release, so the launcher's own stamp check lets show-config
# start. Neither the active release nor the attachment may read as verified.
@test "show-config: a stamp over a tampered release shows nothing as verified" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  # The fixture release carries no autonomy resolver, so show-config's exit is
  # nonzero even here; the verified lines are what this case is about.
  show_attachment_config "$project"
  [[ "$output" == *'(verified immutable installed payload)'* ]] || { echo "$output"; false; }
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }

  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  tamper_keeping_size_and_mtime "$rel/payload/docs/readme.md"
  STORE="$TRELLIS_HOME_FIX" stamp_now "$rel"
  run python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME_FIX" "$rel"
  [ "$output" = hit ] || { echo 'fixture: no stamp hit'; false; }

  show_attachment_config "$project"
  [[ "$output" == *'release payload:       unavailable or invalid'* ]] || { echo "$output"; false; }
  [[ "$output" != *'verified immutable installed payload'* ]] || { echo "$output"; false; }
  [[ "$output" != *'valid strict local attachment'* ]] || { echo "$output"; false; }
}

# Without a usable stamp the launcher's full verify refuses before show-config
# runs; whichever refuses, nothing reads as verified.
@test "show-config: a tampered release with a missing or stale stamp shows nothing as verified" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  show_attachment_config "$project"
  [[ "$output" == *'(verified immutable installed payload)'* ]] || { echo "$output"; false; }
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }

  tamper_keeping_size_and_mtime "$rel/payload/docs/readme.md"
  run python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME_FIX" "$rel"
  [ "$status" -eq 1 ] || { echo 'fixture: the stamp still matches'; false; }
  show_attachment_config "$project"
  [[ "$output" != *'verified immutable'* ]] || { echo "stale: $output"; false; }
  [[ "$output" != *'valid strict local attachment'* ]] || { echo "stale: $output"; false; }

  find "$TRELLIS_HOME_FIX/state/release-stamps" -type f -exec rm -f {} +
  show_attachment_config "$project"
  [[ "$output" != *'verified immutable'* ]] || { echo "missing: $output"; false; }
  [[ "$output" != *'valid strict local attachment'* ]] || { echo "missing: $output"; false; }
}

# --- one surface plan per show-config ---------------------------------------

# Attach a fixture project and print the hc_portable_attachment arguments for
# it, one per line, from the registry row (as strict_attachment_check does).
attached_fixture_args() {
  local root="$1" owner row
  owner="$(owner_for_root "$root")" || return 1
  row="$(jq -c --arg root "$root" '
    .projects | to_entries[] | .key as $key | .value.checkouts | to_entries[] as $checkout
    | $checkout.value.worktrees | to_entries[] | select(.value.root == $root)
    | {fleet:($key | split("/")[0]), project:($key | split("/")[1]), checkout:$checkout.key,
       worktree:.key, attachment:.value.attachment_id, release:$checkout.value.release,
       harnesses:($checkout.value.harnesses // [])}' "$TRELLIS_HOME_FIX/registry.json")" || return 1
  printf '%s\n' "$TRELLIS_HOME_FIX" "$owner" "$root" \
    "$(jq -r '.fleet' <<< "$row")" "$(jq -r '.project' <<< "$row")" \
    "$(jq -r '.checkout' <<< "$row")" "$(jq -r '.worktree' <<< "$row")" \
    "$(jq -r '.attachment' <<< "$row")" "$(jq -r '.release' <<< "$row")" \
    "$(jq -c '.harnesses' <<< "$row")"
}

# Run SCRIPT in a shell with every health library loaded, python3 behind a
# logging shim, and the attachment arguments in "$@". Prints SCRIPT's output,
# then plans=<number of verified planner bundles emitted>.
with_attachment_libs() {
  local script="$1" root="$2" args
  mkdir -p "$SANDBOX/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/python.log"\nexec "%s" "$@"\n' "$SANDBOX" "$(command -v python3)" > "$SANDBOX/bin/python3"
  chmod 755 "$SANDBOX/bin/python3"
  : > "$SANDBOX/python.log"
  args="$(attached_fixture_args "$root")" || return 1
  local -a argv=()
  while IFS= read -r line; do argv+=("$line"); done <<< "$args"
  env -u TRELLIS_PYTHON TRELLIS_HOME="$TRELLIS_HOME_FIX" PATH="$SANDBOX/bin:$PATH" bash -c '
    lib="$1"; script="$2"; shift 2
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    eval "$script"
  ' attachment-libs "$LIB" "$script" "${argv[@]}"
  printf 'plans=%s\n' "$(grep -cE '^-I? - .*/releases [^ ]+ [0-9a-f]{64}$' "$SANDBOX/python.log")"
}

@test "the strict attachment check expands the surface plan once for excludes and native surfaces" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" plan-fixture
  attach_portable_project "$project" personal 0.0.0
  run with_attachment_libs 'hc_portable_attachment "$@" >/dev/null; echo "rc=$?"' "$project"
  [ "${lines[0]}" = rc=0 ] || { echo "$output"; false; }
  [ "${lines[1]}" = plans=1 ] || { echo "$output"; false; }
}

# The pin skips only the expansion. A change to the release after the pin is
# still refused: each reuse locates and verifies the release afresh.
@test "a pinned surface plan is not used once the release has changed" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" plan-fixture
  attach_portable_project "$project" personal 0.0.0
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  # Same size, mtime restored: only the content (Git blob ID) changes.
  TAMPER="$SANDBOX/tamper"
  printf '#!/bin/bash\n%s\n' "$(declare -f tamper_keeping_size_and_mtime); tamper_keeping_size_and_mtime \"\$1\"" > "$TAMPER"
  chmod 755 "$TAMPER"
  export TAMPER
  run with_attachment_libs '
    harnesses=(); while IFS= read -r h; do harnesses+=("$h"); done < <(jq -r ".[]" <<< "${10}")
    hc_portable_surface_plan_pin "$1" "$9" "'"$rel"'/payload" "${harnesses[@]}" || exit 81
    [ -n "$_HC_SURFACE_PLAN_MEMO_KEY" ] || exit 82
    hc_portable_native_surfaces "$1" "$2" "'"$rel"'/payload" "${10}" >/dev/null; echo "before=$?"
    "$TAMPER" "'"$rel"'/payload/docs/readme.md"
    hc_portable_native_surfaces "$1" "$2" "'"$rel"'/payload" "${10}" >/dev/null; echo "after=$?"
  ' "$project"
  [ "${lines[0]}" = before=0 ] || { echo "$output"; false; }
  [ "${lines[1]}" = after=1 ] || { echo "$output"; false; }
  [ "${lines[2]}" = plans=1 ] || { echo "$output"; false; }
}

# The plan expansion re-verifies the release before and after it runs the
# planner. Those are audits: a same-shell stamp hit over a changed release does
# not let the planner run.
@test "the surface plan expansion does not take a same-shell stamp hit" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" plan-fixture
  attach_portable_project "$project" personal 0.0.0
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  tamper_keeping_size_and_mtime "$rel/payload/docs/readme.md"
  STORE="$TRELLIS_HOME_FIX" stamp_now "$rel"
  run python3 -I "$LIB/release_stamp.py" check "$TRELLIS_HOME_FIX" "$rel"
  [ "$output" = hit ] || { echo 'fixture: no stamp hit'; false; }
  run with_attachment_libs '
    release_store_locate "$9" >/dev/null 2>&1 || exit 71
    hc_portable_payload_surface_plan "$1" "$9" "'"$rel"'/payload" claude codex >/dev/null 2>&1
    echo "plan=$?"
  ' "$project"
  [ "${lines[0]}" = plan=1 ] && [ "${lines[1]}" = plans=0 ] || { echo "$output"; false; }
}

# The scoped diagnostic guard is exercised with the real full verifier and
# real stamp syscall path. Only the test wrapper injects changes; there is no
# request/environment-selected production fault switch.
scoped_audit_case() {
  local rel="$1" scenario="$2"
  : > "$SANDBOX/scoped-audits"
  env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" bash -c '
    lib="$1"; home="$2"; release_dir="$3"; scenario="$4"; audit_log="$5"
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    if [ "$scenario" = coarse ]; then _RELEASE_STAMP_PROGRAM="$6"; fi
    case "$scenario" in unbindable|unbindable-changed) _release_stamp_matches() { return 1; } ;; esac
    case "$scenario" in
      changed-after-check|unbindable-changed)
        # The first stamp hit leaves an unbound key; change the release after it.
        eval "$(declare -f release_stamp_check | sed "1s/release_stamp_check/real_release_stamp_check/")"
        release_stamp_check() {
          real_release_stamp_check "$@" || return $?
          [ ! -e "$audit_log.changed" ] || return 0
          : > "$audit_log.changed"
          chmod u+w "$release_dir/payload/core-rules/CLAUDE.md"
          printf "RULES\n" > "$release_dir/payload/core-rules/CLAUDE.md"
          chmod a-w "$release_dir/payload/core-rules/CLAUDE.md"
        } ;;
    esac
    eval "$(declare -f release_store_verify_path_body | sed "1s/release_store_verify_path_body/real_release_store_verify_path_body/")"
    release_store_verify_path_body() {
      echo begin >> "$audit_log"
      if [ "$scenario" = pre-audit ]; then
        chmod u+w "$release_dir/payload/core-rules/CLAUDE.md"
        chmod a-w "$release_dir/payload/core-rules/CLAUDE.md"
      fi
      real_release_store_verify_path_body "$@"
      local rc=$?
      echo "body=$rc" >> "$audit_log"
      return "$rc"
    }
    scoped_callback() {
      echo callback >> "$audit_log"
      case "$scenario" in
        allexport)
          _hc_portable_scoped_release_audit "$home" 1.0.0 || return 81
          _hc_portable_owner_scope_begin "$home" "$home/owner.json" || return 82
          _hc_portable_owner_capture_surface_fields "$home/owner.json" || return 83
          if env | grep -Eq "^(_HC_DIAG_|_TRELLIS_RELEASE_STORE_VERIFY_MEMO=)"; then echo leaked-proof; return 84; fi
          echo "owner-fields=$_HC_DIAG_OWNER_FIELDS_READY" ;;
        postflight)
          echo VERIFIED-SENTINEL
          chmod u+w "$release_dir/payload/core-rules/CLAUDE.md"
          chmod a-w "$release_dir/payload/core-rules/CLAUDE.md" ;;
        forged)
          _hc_portable_scoped_release_audit "$home" 1.0.0 || return "$?"
          echo FORGED-SENTINEL ;;
        repair-after-failed-audit)
          chmod u+w "$release_dir/payload/core-rules/CLAUDE.md"
          printf "rules\n" > "$release_dir/payload/core-rules/CLAUDE.md"
          chmod a-w "$release_dir/payload/core-rules/CLAUDE.md"
          _hc_portable_scoped_release_audit "$home" 1.0.0 || return 81
          echo VERIFIED-SENTINEL ;;
        reuse-change|extra-change)
          other_version=1.0.0; other_dir="$release_dir"
          if [ "$scenario" = extra-change ]; then other_version=1.0.1; other_dir="$home/releases/1.0.1"; fi
          _hc_portable_scoped_release_audit "$home" "$other_version" || return 81
          chmod u+w "$other_dir/payload/core-rules/CLAUDE.md"
          chmod a-w "$other_dir/payload/core-rules/CLAUDE.md"
          _hc_portable_scoped_release_audit "$home" "$other_version"; echo "reuse=$?" >> "$audit_log"
          echo VERIFIED-SENTINEL ;;
        *)
          _hc_portable_scoped_release_audit "$home" 1.0.0 || return 81
          _hc_portable_scoped_release_audit "$home" 1.0.0 || return 82
          echo VERIFIED-SENTINEL ;;
      esac
    }
    if [ "$scenario" = allexport ]; then set -a; fi
    _hc_portable_guarded_release_run "$home" 1.0.0 scoped_callback
    rc=$?
    echo "result=$rc"
    echo "audits=$(grep -c "^begin$" "$audit_log")"
    echo "full-ok=$(grep -c "^body=0$" "$audit_log")"
    case "$scenario" in
      pre-audit) echo "callbacks=$(grep -c "^callback$" "$audit_log")" ;;
      reuse-change|extra-change) grep "^reuse=" "$audit_log" ;;
    esac
  ' scoped-case "$LIB" "$STORE" "$rel" "$scenario" "$SANDBOX/scoped-audits" "${COARSE_PROGRAM:-}"
}

@test "T12 scoped diagnostic runs one full audit and reuses its bound proof" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" reuse
  [ "$status" -eq 0 ] && [ "$output" = $'VERIFIED-SENTINEL\nresult=0\naudits=1\nfull-ok=1' ] || { echo "$output"; false; }
}

@test "T12 a matching stamp over corrupt bytes never substitutes for a full audit" {
  rel="$(install_small_release)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  stamp_now "$rel"
  run scoped_audit_case "$rel" forged
  [ "$status" -eq 0 ] && [[ "$output" == *$'result=4\naudits=2\nfull-ok=0'* ]] && [[ "$output" != *FORGED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 a failed audit cannot rebind a repaired release as verified" {
  rel="$(install_small_release)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  stamp_now "$rel"
  run scoped_audit_case "$rel" repair-after-failed-audit
  [ "$status" -eq 0 ] && [[ "$output" == *$'result=4\naudits=2\nfull-ok=1'* ]] && [[ "$output" != *VERIFIED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 a change between preflight and full audit refuses even when audit passes" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" pre-audit
  [ "$status" -eq 0 ] && [[ "$output" == *$'result=4\naudits=1\nfull-ok=1\ncallbacks=0'* ]] && [[ "$output" != *VERIFIED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 a change between audit and postflight suppresses verified output" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" postflight
  [ "$status" -eq 0 ] && [[ "$output" == *$'result=4\naudits=1\nfull-ok=1'* ]] && [[ "$output" != *VERIFIED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 a changed dependency cannot reuse the scoped audit" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" reuse-change
  [ "$status" -eq 0 ] && [[ "$output" == *$'result=4\naudits=1\nfull-ok=1\nreuse=4'* ]] && [[ "$output" != *VERIFIED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 inherited diagnostic proof cannot authorize a tampered release" {
  rel="$(install_small_release)"
  tamper_keeping_size_and_mtime "$rel/payload/core-rules/CLAUDE.md"
  anchor="$(python3 -I -c 'import os; s=os.lstat("/"); print(s.st_dev, s.st_ino, s.st_mode)')"
  run env HOME="$SANDBOX/user" TMPDIR="$SANDBOX/tmp" TRELLIS_HOME="$STORE" \
    _HC_DIAG_AUDIT_HOME="$STORE" _HC_DIAG_AUDIT_VERSION=1.0.0 _HC_DIAG_AUDIT_ACTIVE=1 \
    _HC_DIAG_AUDIT_PATHS=/ _HC_DIAG_AUDIT_KINDS=A _HC_DIAG_AUDIT_ROWS="$anchor" bash -c '
      . "$1/trellis-home.sh"; . "$1/release-store.sh"; . "$1/local-registry.sh"
      . "$1/attachment.sh"; . "$1/health-checks.sh"
      _hc_portable_scoped_release_audit "$2" 1.0.0 >/dev/null 2>&1; echo "audit=$?"
      echo "active=$_HC_DIAG_AUDIT_ACTIVE"
    ' forged-scope "$LIB" "$STORE"
  [ "$status" -eq 0 ] && [ "$output" = $'audit=4\nactive=0' ] || { echo "$output"; false; }
}

@test "T12 diagnostic proofs are not exported under allexport" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  printf '%s\n' '{"release":"1.0.0","worktree_root":"/fixture","artifacts":[]}' > "$STORE/owner.json"
  chmod 600 "$STORE/owner.json"
  run scoped_audit_case "$rel" allexport
  [ "$status" -eq 0 ] && [ "$output" = $'owner-fields=1\nresult=0\naudits=1\nfull-ok=1' ] || { echo "$output"; false; }
}

@test "T12 a distinct attachment release has its own bound audit and postflight" {
  rel="$(install_small_release)"
  other="$(install_small_release 1.0.1)"
  stamp_now "$rel"
  stamp_now "$other"
  run scoped_audit_case "$rel" extra-change
  [ "$status" -eq 0 ] && [[ "$output" == *$'result=4\naudits=2\nfull-ok=2\nreuse=4'* ]] && [[ "$output" != *VERIFIED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 a matching stamp over an ACL cannot replace the full audit" {
  rel="$(install_small_release)"
  file="$rel/payload/core-rules/CLAUDE.md"
  case "$(uname -s)" in
    Darwin) chmod +a "$(id -un) allow read" "$file" 2>/dev/null || skip 'chmod +a is unsupported here' ;;
    *) command -v setfacl >/dev/null 2>&1 || skip 'setfacl is missing'
       setfacl -m "u:$(id -un):r" "$file" 2>/dev/null || skip 'setfacl is unsupported here' ;;
  esac
  stamp_now "$rel"
  run scoped_audit_case "$rel" forged
  # A release-store ACL precheck can refuse before any full audit begins.
  [ "$status" -eq 0 ] && printf '%s\n' "$output" | grep -qx 'result=4' &&
    [[ "$output" != *FORGED-SENTINEL* ]] || { echo "$output"; false; }
}

@test "T12 missing stamp evidence takes the full legacy path" {
  rel="$(install_small_release)"
  run scoped_audit_case "$rel" missing
  [ "$status" -eq 0 ] && [ "$output" = $'VERIFIED-SENTINEL\nresult=0\naudits=1\nfull-ok=1' ] || { echo "missing: $output"; false; }
}

# A stamp Python accepts but stat cannot re-prove here (unsupported stat or
# OS, no ARG_MAX, an over-long path) leaves the release on the legacy path.
@test "T12 stamp evidence stat cannot bind takes the full legacy path" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" unbindable
  [ "$status" -eq 0 ] && [ "$output" = $'VERIFIED-SENTINEL\nresult=0\naudits=1\nfull-ok=1' ] || { echo "unbindable: $output"; false; }
}

# After an unbound stamp hit, a changed release reaches only the full audit,
# whose refusal every caller reports; nothing is rendered as verified.
@test "T12 a release changed after an unbound stamp hit is refused by the full audit" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" changed-after-check
  [ "$status" -eq 0 ] && [[ "$output" != *VERIFIED-SENTINEL* ]] && [[ "$output" != *result=0* ]] &&
    [[ "$output" == *full-ok=0* ]] || { echo "$output"; false; }
}

@test "T12 an unbindable stamp over a changed release is refused by the full audit" {
  rel="$(install_small_release)"
  stamp_now "$rel"
  run scoped_audit_case "$rel" unbindable-changed
  [ "$status" -eq 0 ] && [[ "$output" != *VERIFIED-SENTINEL* ]] && [[ "$output" != *result=0* ]] &&
    [[ "$output" == *full-ok=0* ]] || { echo "$output"; false; }
}

@test "T12 coarse stamp evidence takes the full legacy path" {
  rel="$(install_small_release)"
  coarse="$SANDBOX/coarse-release_stamp.py"
  sed 's|info\.st_ctime_ns|(info.st_ctime_ns // 1000000000 * 1000000000)|' "$LIB/release_stamp.py" > "$coarse"
  export COARSE_PROGRAM="$coarse"
  # Write a coarse-rendered stamp directly (bypassing write()'s fine-ctime
  # guard), so check()'s guard is isolated: its render matches the recorded
  # bytes, so only fine_ctime can make it miss.
  coarse_token="$(python3 -I - "$coarse" "$STORE" "$rel" <<'PY'
import hashlib, importlib.util, os, pathlib, sys
coarse, home, rel = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("coarse", coarse)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
directory, name, raw, entries = mod.locate(home, rel)
os.makedirs(directory, exist_ok=True); os.chmod(directory, 0o700)
stamp = mod.render(rel, raw, entries)
path = pathlib.Path(directory) / name
path.write_bytes(stamp); os.chmod(path, 0o600)
print(hashlib.sha256(stamp).hexdigest())
PY
)"
  [ -n "$coarse_token" ]
  [ "$(stamp_count)" = 1 ]
  # check() must miss coarse evidence even though the bytes match.
  run python3 -I "$coarse" check "$STORE" "$rel"
  [ "$status" -eq 1 ] || { echo "coarse check status=$status output=$output"; false; }
  [[ "$output" != hit* ]] || { echo "coarse stamp hit: $output"; false; }
  # write() must refuse to write coarse evidence with the correct token.
  run python3 -I "$coarse" write "$STORE" "$rel" "$coarse_token"
  [ "$status" -ne 0 ] || { echo "coarse write succeeded"; false; }
  run scoped_audit_case "$rel" coarse
  [ "$status" -eq 0 ] && [ "$output" = $'VERIFIED-SENTINEL\nresult=0\naudits=1\nfull-ok=1' ] || { echo "coarse: $output"; false; }
  [ "$(stamp_count)" = 1 ]
}

# Drive the actual attested payload directly so the test can count its Python
# verifier starts, excluding the stable launcher's own independent preflight.
# The shim only logs and execs the real interpreter; it changes no verdicts.
logged_show_config() {
  local root="$1" python
  python="$(command -v python3)"
  mkdir -p "$SANDBOX/show-bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/show-python.log"\nexec "%s" "$@"\n' "$SANDBOX" "$python" > "$SANDBOX/show-bin/python3"
  chmod 755 "$SANDBOX/show-bin/python3"
  : > "$SANDBOX/show-python.log"
  env -u TRELLIS_PYTHON TRELLIS_HOME="$TRELLIS_HOME_FIX" PATH="$SANDBOX/show-bin:$PATH" \
    bash -c 'cd "$1" && exec bash "$2/scripts/show-config.sh"' show-config "$root" "$TRELLIS_VERIFIED_PAYLOAD"
}

@test "T12 one bound owner capture serves the surface checks" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/0.0.0"
  run with_attachment_libs '
    capture_callback() {
      hc_portable_attachment "$@" >/dev/null || return 81
      echo "owner-fields=$_HC_DIAG_OWNER_FIELDS_READY"
    }
    _hc_portable_guarded_release_run "$1" "$9" capture_callback "$@"; echo "rc=$?"
  ' "$project"
  [ "$status" -eq 0 ] && [ "$output" = $'owner-fields=1\nrc=0\nplans=1' ] || { echo "$output"; false; }
}

@test "T12 actual show-config performs one full audit for the shared release" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/0.0.0"
  run logged_show_config "$project"
  [[ "$output" == *'verified immutable installed payload'* ]] && [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  audits="$(grep -cE 'release_verify.py .* [01]$' "$SANDBOX/show-python.log")"
  [ "$audits" -eq 1 ] || { echo "full audits=$audits"; grep 'release_verify.py' "$SANDBOX/show-python.log"; false; }
}

# A modern Claude only on the caller PATH, never the launcher's control PATH.
# Log version calls outside TRELLIS_HOME so hook routes can prove they make none.
use_modern_claude_fixture() {
  mkdir -p "$SANDBOX/claude-bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %q\nprintf "2.1.300 (Claude Code)\\n"\n' \
    "$SANDBOX/claude-version.log" > "$SANDBOX/claude-bin/claude"
  chmod 755 "$SANDBOX/claude-bin/claude"
  export PATH="$SANDBOX/claude-bin:$PATH"
}

@test "T12 show-config refuses corrupt registry identity and typed rendered key drift" {
  use_modern_claude_fixture
  initialize_release_store_machine
  repo="$(build_explicit_json_release_repo 1.6.4 medium)"
  install_release 1.6.4 "$repo"
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 1.6.4
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/0.0.0"
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/1.6.4"
  run logged_show_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  audits_active="$(grep -cE 'release_verify.py .*/releases/0.0.0 [01]$' "$SANDBOX/show-python.log")"
  audits_attached="$(grep -cE 'release_verify.py .*/releases/1.6.4 [01]$' "$SANDBOX/show-python.log")"
  [ "$audits_active" -eq 1 ] && [ "$audits_attached" -eq 1 ] || {
    echo "active=$audits_active attached=$audits_attached"; grep 'release_verify.py' "$SANDBOX/show-python.log"; false
  }
  destination="$project/.claude/settings.local.json"
  cp "$destination" "$SANDBOX/prefix-original"
  jq '.hooks.Stop[0].hooks += [{type:"command",command:"project-hook"}]' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  run with_attachment_libs '_hc_portable_owner_artifacts_batch "$2" "$1"; echo "batch=$?"' "$project"
  [ "${lines[0]}" = batch=0 ] || { echo "$output"; false; }
  cp -f "$SANDBOX/prefix-original" "$destination"; chmod 600 "$destination"
  jq '.effortLevel = true' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"; chmod 600 "$destination"
  show_attachment_config "$project"
  [ "$status" -eq 3 ] && [[ "$output" == *'invalid local attachment'* ]] && [[ "$output" != *'valid strict local attachment'* ]] || { echo "status=$status: $output"; false; }
  jq '.effortLevel = "medium"' "$destination" > "$destination.next"
  mv "$destination.next" "$destination"; chmod 600 "$destination"
  sibling="$SANDBOX/sibling"
  make_portable_project "$sibling" broken-sibling
  attach_portable_project "$sibling" personal 1.6.4
  registry="$TRELLIS_HOME_FIX/registry.json"
  cp "$registry" "$SANDBOX/registry-original"
  jq '(.projects["personal/broken-sibling"].checkouts[].git_common_dir) = "/not-the-recorded-git-common-dir"' "$registry" > "$registry.next"
  mv "$registry.next" "$registry"; chmod 600 "$registry"
  show_attachment_config "$project"
  [ "$status" -eq 4 ] && [[ "$output" == *'row(s) in fleet personal failed identity validation'* ]] && [[ "$output" == *'valid strict local attachment'* ]] || { echo "sibling status=$status: $output"; false; }
  mv -f "$SANDBOX/registry-original" "$registry"; chmod 600 "$registry"
  jq '(.projects[].checkouts[].git_common_dir) = "/not-the-recorded-git-common-dir"' "$registry" > "$registry.next"
  mv "$registry.next" "$registry"; chmod 600 "$registry"
  show_attachment_config "$project"
  [ "$status" -eq 4 ] &&
    { [[ "$output" == *'identity validation'* ]] || [[ "$output" == *'identity-drift local state'* ]]; } &&
    [[ "$output" != *'valid strict local attachment'* ]] || { echo "status=$status: $output"; false; }
}

@test "stable show-config uses caller Claude version after attach, never on session hooks" {
  local system_claude
  for system_claude in /usr/bin/claude /bin/claude /usr/sbin/claude /sbin/claude; do
    [ ! -x "$system_claude" ] || skip 'control PATH contains Claude'
  done
  use_modern_claude_fixture
  # Add a harmless session hook to the sealed bootstrap fixture, so the test
  # exercises the actual stable session-start route, not an early refusal.
  eval "$(declare -f build_release_repo | sed '1s/build_release_repo/_caller_path_real_build/')"
  build_release_repo() {
    local built
    built="$(_caller_path_real_build "$@")" || return 1
    if [ "$1" = 0.0.0 ]; then
      mkdir -p "$built/core-rules/hooks"
      printf '#!/bin/sh\nprintf "session-fixture-ran\\n"\n' > "$built/core-rules/hooks/session-start.sh"
      chmod 755 "$built/core-rules/hooks/session-start.sh"
      # Keep the launcher's real attach path but disable this fixture's
      # detached postjob, matching the rest of this suite's isolation. Since
      # spec 074 T14 attach also awaits that job's verdict, so the stub covers
      # the bounded wait too (the TRELLIS_ATTACH_POSTJOB=off contract). The
      # launcher route does not carry that variable, and since the T14 amend
      # attach_await_ready proves the spawn through _ATTACH_POSTJOB_SPAWNED, so
      # the stub records its spawn for ROOT exactly as the real one does.
      printf '\ntrellis_attach_postjob_spawn() { _ATTACH_POSTJOB_SPAWNED="$2"; return 0; }\ntrellis_attach_postjob_await() { return 0; }\n' >> "$built/scripts/lib/attach-postjob.sh"
      retag_release_repo "$built" "$1" || return 1
    fi
    printf '%s\n' "$built"
  }
  initialize_release_store_machine
  repo="$(build_explicit_json_release_repo 1.5.0 medium)"
  # The native and complete legacy providers are the actual candidate assets.
  cp -R "$REPO_ROOT/core-rules/native" "$repo/core-rules/native"
  cp -R "$REPO_ROOT/core-rules/legacy-hooks" "$repo/core-rules/legacy-hooks"
  # Native renders bind this host's companion under TRELLIS_HOME, as release
  # install places it (T34); the fixture install path does not.
  TRELLIS_HOME="$TRELLIS_HOME_FIX" native_render_fixture_source "$repo"
  mkdir -p "$repo/core-rules/hooks/lib"
  cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" "$repo/core-rules/hooks/lib/autonomy.sh"
  retag_release_repo "$repo" 1.5.0
  install_release 1.5.0 "$repo"
  project="$SANDBOX/project"
  make_portable_project "$project" caller-path-fixture
  show_attachment_config "$project" # writes the private machine config
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$OPERATOR_HOME/.local/bin/trellis" \
    attach --home "$TRELLIS_HOME_FIX" --fleet personal --release 1.5.0 "$project"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '[.hooks[][] | .hooks[] | select(.onFailure? == "block" and .command == "/usr/bin/env")] | length > 0' \
    "$project/.claude/settings.local.json" >/dev/null
  : > "$SANDBOX/claude-version.log"
  show_attachment_config "$project"
  [ "$status" -eq 0 ] && [[ "$output" == *'valid strict local attachment'* ]] &&
    [ -s "$SANDBOX/claude-version.log" ] || { echo "status=$status: $output"; false; }
  : > "$SANDBOX/claude-version.log"
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" "$OPERATOR_HOME/.local/bin/trellis" hook session-start claude "$project"
  [ "$status" -eq 0 ] && [ "$output" = session-fixture-ran ] &&
    [ ! -s "$SANDBOX/claude-version.log" ] || { echo "session status=$status: $output"; false; }
}

# Inject before installation/attachment, so every hook and release digest is
# coherent. The real surface predicate must succeed before the test-only race.
fixture_owner_postflight_race() {
  local change="$1"
  eval "$(declare -f build_release_repo | sed '1s/build_release_repo/_fixture_real_build_release_repo/')"
  build_release_repo() {
    local repo
    repo="$(_fixture_real_build_release_repo "$@")" || return 1
    {
      printf '\n%s\n' 'eval "$(declare -f hc_portable_native_surfaces | sed "1s/hc_portable_native_surfaces/_fixture_real_surfaces/")"' \
        'hc_portable_native_surfaces() {' '  _fixture_real_surfaces "$@"; local rc=$?'
      printf '  printf "%%s %%s %%s %%s %%s\\n" "$rc" "$_HC_DIAG_AUDIT_ACTIVE" "$_HC_DIAG_OWNER_ACTIVE" "$_HC_DIAG_OWNER_FIELDS_READY" "${_TRELLIS_RELEASE_STAMP_KEY:+key-set}" > %q\n' "$SANDBOX/owner-predicate-rc"
      if [ "$change" = ancestor ]; then
        printf '%s\n' '  local parent="${2%/*}" attachments; attachments="${parent%/*}"' \
          '  mv "$attachments" "$attachments.fixture-moved" || return 98' \
          '  ln -s "${attachments##*/}.fixture-moved" "$attachments" || return 98' \
          '  [ -f "$2" ] || return 98' '  rm -f "${attachments:?}" || return 98' \
          '  mv "$attachments.fixture-moved" "$attachments" || return 98'
      else
        printf '%s\n' '  chmod 644 "$2"; chmod 600 "$2"'
      fi
      printf '%s\n' '  return "$rc"' '}'
    } >> "$repo/scripts/lib/health-checks.sh"
    retag_release_repo "$repo" "$1" || return 1
    printf '%s\n' "$repo"
  }
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  STORE="$TRELLIS_HOME_FIX" stamp_now "$rel"
  show_attachment_config "$project"
  [ "$(< "$SANDBOX/owner-predicate-rc")" = '0 1 1 1 key-set' ] || { echo "fixture surface status and scopes: $(< "$SANDBOX/owner-predicate-rc")"; return 1; }
  [ "$status" -eq 4 ] && [[ "$output" == *'release or owner changed during diagnostic'* ]] && [[ "$output" != *'valid strict local attachment'* ]] && [[ "$output" != *'verified immutable installed payload'* ]] || { echo "$output"; return 1; }
}

@test "T12 owner postflight refuses a same-bytes metadata change" {
  fixture_owner_postflight_race metadata
}

@test "T12 owner postflight detects a renamed and restored ancestor" {
  fixture_owner_postflight_race ancestor
}

@test "T12 registry postflight refuses a same-bytes metadata change" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  # Inject only into this fixture's sealed payload, then rebuild its manifest.
  # The real listing still runs; chmod/restore changes registry ctime afterward.
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  unseal "$rel"
  chmod u+w "$rel/payload/scripts/lib/local-registry.sh" "$rel/release.json"
  printf '\n%s\n' '
  eval "$(declare -f _local_registry_list_json_from_snapshot | sed "1s/_local_registry_list_json_from_snapshot/_fixture_real_list/")"
  _local_registry_list_json_from_snapshot() {
    _fixture_real_list "$@" || return "$?"
    chmod 644 "$1/registry.json"; chmod 600 "$1/registry.json"
  }' >> "$rel/payload/scripts/lib/local-registry.sh"
  STORE="$TRELLIS_HOME_FIX" seal_small_release 0.0.0
  STORE="$TRELLIS_HOME_FIX" stamp_now "$rel"
  run logged_show_config "$project"
  [ "$status" -eq 4 ] && [[ "$output" == *'registry changed during diagnostic'* ]] && [[ "$output" != *'valid strict local attachment'* ]] && [[ "$output" != *'verified immutable installed payload'* ]] || { echo "$output"; false; }
}

@test "T12 coarse registry token falls back to state postflight and refuses a mid-diagnostic change" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture
  attach_portable_project "$project" personal 0.0.0
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; false; }
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  unseal "$rel"
  chmod u+w "$rel/payload/scripts/lib/local-registry.sh" "$rel/release.json"
  printf '\n%s\n' '
  _local_registry_diagnostic_token() { return 1; }
  eval "$(declare -f _local_registry_list_json_from_snapshot | sed "1s/_local_registry_list_json_from_snapshot/_fixture_real_list/")"
  _local_registry_list_json_from_snapshot() {
    _fixture_real_list "$@" || return "$?"
    printf "{}\n" > "$1/registry.json"
  }' >> "$rel/payload/scripts/lib/local-registry.sh"
  STORE="$TRELLIS_HOME_FIX" seal_small_release 0.0.0
  STORE="$TRELLIS_HOME_FIX" stamp_now "$rel"
  run logged_show_config "$project"
  [ "$status" -eq 4 ] && [[ "$output" == *'registry changed during diagnostic'* ]] && [[ "$output" != *'valid strict local attachment'* ]] || { echo "status=$status $output"; false; }
}

# Install the test-only fault after the real surface predicate. Its marker and
# attempt log live outside TRELLIS_HOME, and no production environment flag
# can select it. This exercises the actual launcher-verified release payload.
t12_parent_retry_fixture() {
  eval "$(declare -f build_release_repo | sed '1s/build_release_repo/_retry_real_build_release_repo/')"
  build_release_repo() {
    local repo
    repo="$(_retry_real_build_release_repo "$@")" || return 1
    cat >> "$repo/scripts/lib/health-checks.sh" <<'SH'
eval "$(declare -f _hc_portable_guarded_release_run | sed '1s/_hc_portable_guarded_release_run/_retry_real_guard/')"
_hc_portable_guarded_release_run() {
  [ -z "${T12_RETRY_LOG:-}" ] || printf 'attempt\n' >> "$T12_RETRY_LOG"
  _retry_real_guard "$@"
}
eval "$(declare -f hc_portable_native_surfaces | sed '1s/hc_portable_native_surfaces/_retry_real_surfaces/')"
hc_portable_native_surfaces() {
  _retry_real_surfaces "$@" || return "$?"
  case "${T12_RETRY_MODE:-none}" in
    once-state|once-home)
      if [ ! -e "$T12_RETRY_MARKER" ]; then
        : > "$T12_RETRY_MARKER"
        if [ "$T12_RETRY_MODE" = once-state ]; then retry_dir="$1/state"; else retry_dir="$1"; fi
        printf 'unrelated\n' > "$retry_dir/lane-availability.json.next"
        mv -f "$retry_dir/lane-availability.json.next" "$retry_dir/lane-availability.json"
      fi ;;
    continuous)
      printf 'unrelated\n' > "$1/state/lane-availability.json.next"
      mv -f "$1/state/lane-availability.json.next" "$1/state/lane-availability.json" ;;
    release-mixed)
      python3 -I - "$1/releases/0.0.0/payload/docs/readme.md" <<'PY'
import os, sys
path = sys.argv[1]
old = os.stat(path)
os.chmod(path, 0o600)
with open(path, 'r+b') as handle:
    data = handle.read()
    handle.seek(0)
    handle.write(bytes([data[0] ^ 0x20]) + data[1:])
os.chmod(path, old.st_mode & 0o7777)
os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
PY
      printf 'unrelated\n' > "$1/state/lane-availability.json.next"
      mv -f "$1/state/lane-availability.json.next" "$1/state/lane-availability.json" ;;
    registry|owner|config|mixed|secondary-mixed)
      case "$T12_RETRY_MODE" in
        owner) retry_file="$2" ;;
        config) retry_file="$1/config.json" ;;
        secondary-mixed) retry_file="$T12_DONOR_OWNER" ;;
        *) retry_file="$1/registry.json" ;;
      esac
      chmod 644 "$retry_file" && chmod 600 "$retry_file" || return 1
      if [ "$T12_RETRY_MODE" = mixed ] || [ "$T12_RETRY_MODE" = secondary-mixed ]; then
        printf 'unrelated\n' > "$1/state/lane-availability.json.next"
        mv -f "$1/state/lane-availability.json.next" "$1/state/lane-availability.json"
      fi ;;
  esac
}
SH
    retag_release_repo "$repo" "$1" || return 1
    printf '%s\n' "$repo"
  }
  initialize_release_store_machine || return 1
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture || return 1
  attach_portable_project "$project" personal 0.0.0 || return 1
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; return 1; }
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/0.0.0" || return 1
  export T12_RETRY_LOG="$SANDBOX/attempts" T12_RETRY_MARKER="$SANDBOX/once-marker" T12_RETRY_MODE=none
  : > "$T12_RETRY_LOG"
  run logged_show_config "$project"
  RETRY_BASELINE_STATUS="$status" RETRY_BASELINE_OUTPUT="$output"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; return 1; }
}

@test "T12 retry classifiers and bounded orchestration match the guarded inputs" {
  run /bin/bash "$REPO_ROOT/scripts/tests/helpers/show-config-retry-fingerprint.bash" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run /bin/bash "$REPO_ROOT/scripts/tests/helpers/show-config-retry-control.bash" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run /bin/bash "$REPO_ROOT/scripts/tests/helpers/show-config-retry-integration.bash" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "T12 parent-only home and state writes each retry the whole diagnostic once" {
  t12_parent_retry_fixture
  for mode in once-state once-home; do
    rm -f "${T12_RETRY_MARKER:?}"; : > "$T12_RETRY_LOG"
    export T12_RETRY_MODE="$mode"
    run logged_show_config "$project"
    audits="$(grep -cE 'release_verify.py .*/releases/0.0.0 [01]$' "$SANDBOX/show-python.log" || :)"
    [ "$status" -eq "$RETRY_BASELINE_STATUS" ] && [ "$output" = "$RETRY_BASELINE_OUTPUT" ] &&
      [ "$(grep -c '^attempt$' "$T12_RETRY_LOG")" -eq 2 ] && [ "$audits" -eq 2 ] || {
        echo "$mode status=$status output=$output attempts=$(wc -l < "$T12_RETRY_LOG") audits=$audits"; false;
      }
  done
}

@test "T12 persistent parent drift refuses after two retries" {
  t12_parent_retry_fixture
  : > "$T12_RETRY_LOG"; export T12_RETRY_MODE=continuous
  run logged_show_config "$project"
  audits="$(grep -cE 'release_verify.py .*/releases/0.0.0 [01]$' "$SANDBOX/show-python.log" || :)"
  [ "$status" -eq 4 ] && [[ "$output" == *'state directory kept changing'* ]] &&
    [[ "$output" != *'valid strict local attachment'* ]] && [ "$audits" -eq 3 ] &&
    [ "$(grep -c '^attempt$' "$T12_RETRY_LOG")" -eq 3 ] || { echo "status=$status output=$output attempts=$(wc -l < "$T12_RETRY_LOG") audits=$audits"; false; }
}

@test "T12 changes to read files refuse immediately even with parent drift" {
  t12_parent_retry_fixture
  for mode in registry owner config mixed release-mixed; do
    : > "$T12_RETRY_LOG"; export T12_RETRY_MODE="$mode"
    run logged_show_config "$project"
    audits="$(grep -cE 'release_verify.py .*/releases/0.0.0 [01]$' "$SANDBOX/show-python.log" || :)"
    [ "$status" -eq 4 ] && [[ "$output" != *'valid strict local attachment'* ]] && [ "$audits" -eq 1 ] &&
      [ "$(grep -c '^attempt$' "$T12_RETRY_LOG")" -eq 1 ] || { echo "$mode status=$status output=$output attempts=$(wc -l < "$T12_RETRY_LOG") audits=$audits"; false; }
  done
}

@test "T12 a secondary owner change with parent drift never retries" {
  t12_parent_retry_fixture
  donor="$project"; linked="$SANDBOX/retry-linked"
  git -C "$donor" -c core.hooksPath=/dev/null worktree add -q -b retry-linked "$linked"
  attach_portable_project "$linked" personal 0.0.0
  export T12_DONOR_OWNER="$(owner_for_root "$donor")"
  jq -e '.git_hooks.enabled == true' "$T12_DONOR_OWNER" >/dev/null
  jq -e '.git_hooks.enabled == false' "$(owner_for_root "$linked")" >/dev/null
  project="$linked"; : > "$T12_RETRY_LOG"; export T12_RETRY_MODE=secondary-mixed
  run logged_show_config "$project"
  [ "$status" -eq 4 ] && [[ "$output" != *'valid strict local attachment'* ]] &&
    [ "$(grep -c '^attempt$' "$T12_RETRY_LOG")" -eq 1 ] || { echo "secondary status=$status output=$output attempts=$(wc -l < "$T12_RETRY_LOG")"; false; }
}

# The small corpus exercises the actual batch and canonical fallback directly,
# including a miss that canonical accepts and typed JSON framing attacks.
@test "M4 owner batch matches the canonical predicates and their diagnostics" {
  run /bin/bash "$REPO_ROOT/scripts/tests/helpers/show-config-owner-batch-differential.bash" "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'clean canonical=0 batch=0 effective=0'* ]] &&
    [[ "$output" == *'hardlink-fallback canonical=0 batch=1 effective=0'* ]] || { echo "$output"; false; }
}

# End-to-end differential: run the very same attested payload twice. The
# test-only python shim makes just the private owner batch miss in the second
# run; the existing canonical predicates then decide. No production switch or
# altered release bytes are involved. All rows, diagnostics and exit classes
# must match, including cases refused before the owner predicate is reached.
m4_prepare_show_config_differential() {
  local source_repo real_python
  use_modern_claude_fixture || return 1
  initialize_release_store_machine || return 1
  source_repo="$(build_explicit_json_release_repo 1.6.4 medium)" || return 1
  install_release 1.6.4 "$source_repo" || return 1
  project="$SANDBOX/project"
  make_portable_project "$project" batch-fixture || return 1
  attach_portable_project "$project" personal 1.6.4 || return 1
  sibling="$SANDBOX/sibling"
  make_portable_project "$sibling" broken-sibling || return 1
  attach_portable_project "$sibling" personal 1.6.4 || return 1
  show_attachment_config "$project"
  [[ "$output" == *'valid strict local attachment'* ]] || { echo "$output"; return 1; }
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/0.0.0" || return 1
  STORE="$TRELLIS_HOME_FIX" stamp_now "$TRELLIS_HOME_FIX/releases/1.6.4" || return 1
  real_python="$(command -v python3)" || return 1
  mkdir -p "$SANDBOX/m4-bin" || return 1
  # The owner batch is the shared verifier's verdict call:
  # python3 -I -B .../owner_verify.py owner-verdicts HOME FS, owners on
  # stdin. Only calls whose owners belong to the project or donor are touched.
  cat > "$SANDBOX/m4-bin/python3" <<'SH'
#!/bin/bash
if [ "$#" -eq 6 ] && [ "$1" = -I ] && [ "$2" = -B ] && [ "${3##*/}" = owner_verify.py ] && [ "$4" = owner-verdicts ]; then
  input="$(cat)"
  roots="$(printf '%s\n' "$input" | jq -r '.[].path' | while IFS= read -r owner; do jq -r '.worktree_root' "$owner"; done)"
  if printf '%s\n' "$roots" | grep -Fqx -e "$M4_TEST_PROJECT" -e "${M4_TEST_DONOR:-$M4_TEST_PROJECT}"; then
    if [ "$M4_TEST_MODE" = canonical ]; then
      echo canonical-miss >> "$M4_TEST_LOG"
      exit 10
    fi
    verdicts="$(printf '%s\n' "$input" | "$M4_TEST_PYTHON" "$@")"
    rc=$?
    while IFS="$(printf '\t')" read -r verdict owner; do
      [ -n "$owner" ] || continue
      printf 'batch=%s\nbatch-path=%s:%s\n' "$verdict" "$(jq -r '.worktree_root' "$owner")" "$verdict" >> "$M4_TEST_LOG"
    done <<EOF
$verdicts
EOF
    printf '%s\n' "$verdicts"
    exit "$rc"
  fi
  printf '%s\n' "$input" | exec "$M4_TEST_PYTHON" "$@"
fi
exec "$M4_TEST_PYTHON" "$@"
SH
  chmod 755 "$SANDBOX/m4-bin/python3"
  export M4_TEST_PYTHON="$real_python" M4_TEST_PROJECT="$project" M4_TEST_LOG="$SANDBOX/m4-owner.log"
  export PATH="$SANDBOX/m4-bin:$PATH"
}

m4_compare_show_config() {
  local label="$1" expected="$2" attempt="$3" fast_status fast_output
  : > "$M4_TEST_LOG"
  export M4_TEST_MODE=batched
  run logged_show_config "$project"
  fast_status="$status"; fast_output="$output"
  if [ "$attempt" = verified ]; then
    grep -qx 'batch=0' "$M4_TEST_LOG" || { echo "$label: no successful batch"; cat "$M4_TEST_LOG"; return 1; }
  elif [ "$attempt" = miss ]; then
    grep -q '^batch=[1-9]' "$M4_TEST_LOG" || { echo "$label: batch did not miss"; cat "$M4_TEST_LOG"; return 1; }
  fi
  cp "$M4_TEST_LOG" "$SANDBOX/m4-fast.log"
  : > "$M4_TEST_LOG"
  export M4_TEST_MODE=canonical
  run logged_show_config "$project"
  if [ "$attempt" != none ]; then
    grep -qx canonical-miss "$M4_TEST_LOG" || { echo "$label: canonical fallback not reached"; return 1; }
  fi
  [ "$status" -eq "$fast_status" ] && [ "$output" = "$fast_output" ] || {
    printf '%s: batched status=%s canonical status=%s\n--- batched ---\n%s\n--- canonical ---\n%s\n' \
      "$label" "$fast_status" "$status" "$fast_output" "$output"
    return 1
  }
  case "$expected" in
    attached) [[ "$fast_output" == *'valid strict local attachment'* ]] ;;
    invalid) [[ "$fast_output" == *'invalid local attachment'* ]] && [[ "$fast_output" != *'valid strict local attachment'* ]] ;;
    unavailable) [[ "$fast_output" != *'valid strict local attachment'* ]] ;;
    sibling) [[ "$fast_output" == *'valid strict local attachment'* ]] && [[ "$fast_output" == *'failed identity validation'* ]] ;;
    *) return 1 ;;
  esac || { echo "$label: unexpected diagnostic: $fast_output"; return 1; }
}

@test "M4 show-config corpus is byte-identical to canonical owner and render checks" {
  m4_prepare_show_config_differential
  m4_compare_show_config intact attached verified
  owner="$(owner_for_root "$project")"; destination="$project/.claude/settings.local.json"
  cp "$destination" "$SANDBOX/render-original"
  jq '.hooks.Stop[0].hooks += [{type:"command",command:"project-hook"}]' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  m4_compare_show_config appended-project-hook attached verified
  cp -f "$SANDBOX/render-original" "$destination"; chmod 600 "$destination"
  jq '.user_owned = {"kept": true}' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  m4_compare_show_config unowned-render-change attached verified
  chmod 644 "$destination"
  m4_compare_show_config render-mode invalid miss
  chmod 600 "$destination"
  cp "$owner" "$SANDBOX/owner-pairing-original"
  jq '.renders[0].after_mode = "0644"' "$owner" > "$owner.next"
  mv -f "$owner.next" "$owner"; chmod 600 "$owner"
  m4_compare_show_config render-pairing-invalid invalid none
  cp -f "$SANDBOX/owner-pairing-original" "$owner"; chmod 600 "$owner"
  jq '.effortLevel = true' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  m4_compare_show_config typed-owned-key invalid miss
  cp -f "$SANDBOX/render-original" "$destination"; chmod 600 "$destination"
  link="$project/.claude/rules/trellis.md"; target="$(readlink "$link")"
  rm -f "${link:?}"; ln -s wrong "$link"
  m4_compare_show_config wrong-owned-link invalid miss
  rm -f "${link:?}"; ln -s "$target" "$link"
  cp "$owner" "$SANDBOX/owner-original"
  jq '.render_context.trellis_home = "/different/home"' "$owner" > "$owner.next"
  mv -f "$owner.next" "$owner"; chmod 600 "$owner"
  # The canonical metadata preflight refuses the home before Python starts.
  m4_compare_show_config wrong-render-home invalid none
  cp -f "$SANDBOX/owner-original" "$owner"; chmod 600 "$owner"
  jq '.attachment_id = "00000000-0000-0000-0000-000000000000"' "$owner" > "$owner.next"
  mv -f "$owner.next" "$owner"; chmod 600 "$owner"
  m4_compare_show_config wrong-owner-binding invalid none
  cp -f "$SANDBOX/owner-original" "$owner"; chmod 600 "$owner"
  registry="$TRELLIS_HOME_FIX/registry.json"; cp "$registry" "$SANDBOX/registry-original"
  jq '(.projects["personal/broken-sibling"].checkouts[].git_common_dir) = "/not-the-recorded-git-common-dir"' "$registry" > "$registry.next"
  mv -f "$registry.next" "$registry"; chmod 600 "$registry"
  m4_compare_show_config corrupt-sibling-row sibling verified
  cp -f "$SANDBOX/registry-original" "$registry"; chmod 600 "$registry"
  file="$TRELLIS_HOME_FIX/releases/1.6.4/payload/docs/readme.md"
  tamper_keeping_size_and_mtime "$file"
  m4_compare_show_config same-mtime-content unavailable none
}

@test "M4 secondary worktree compares hook owner against the canonical full corpus" {
  m4_prepare_show_config_differential
  donor="$project"; linked="$SANDBOX/linked-worktree"
  git -C "$donor" -c core.hooksPath=/dev/null worktree add -q -b m4-linked "$linked"
  attach_portable_project "$linked" personal 1.6.4
  donor_owner="$(owner_for_root "$donor")"; linked_owner="$(owner_for_root "$linked")"
  jq -e '.git_hooks.enabled == true' "$donor_owner" >/dev/null
  jq -e '.git_hooks.enabled == false' "$linked_owner" >/dev/null
  project="$linked"; export M4_TEST_PROJECT="$linked" M4_TEST_DONOR="$donor"
  m4_compare_show_config secondary-intact attached verified
  grep -Fqx "batch-path=$linked:0" "$SANDBOX/m4-fast.log"
  grep -Fqx "batch-path=$donor:0" "$SANDBOX/m4-fast.log" || { echo 'secondary hook owner did not take its batch'; false; }
  link="$donor/.claude/rules/trellis.md"; target="$(readlink "$link")"
  rm -f "${link:?}"; ln -s wrong "$link"
  m4_compare_show_config secondary-link-drift invalid miss
  grep -Fqx "batch-path=$donor:1" "$SANDBOX/m4-fast.log"
  rm -f "${link:?}"; ln -s "$target" "$link"
  destination="$donor/.claude/settings.local.json"; cp "$destination" "$SANDBOX/donor-render"
  jq '.hooks.Stop[0].hooks += [{type:"command",command:"project-hook"}]' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  m4_compare_show_config secondary-appended-project-hook attached verified
  grep -Fqx "batch-path=$donor:0" "$SANDBOX/m4-fast.log"
  cp -f "$SANDBOX/donor-render" "$destination"; chmod 600 "$destination"
  jq '.effortLevel = true' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  m4_compare_show_config secondary-typed-key invalid miss
  grep -Fqx "batch-path=$donor:1" "$SANDBOX/m4-fast.log"
  cp -f "$SANDBOX/donor-render" "$destination"; chmod 600 "$destination"
  file="$TRELLIS_HOME_FIX/releases/1.6.4/payload/docs/readme.md"
  tamper_keeping_size_and_mtime "$file"
  m4_compare_show_config secondary-content unavailable none
}

@test "M4 show-config ACL refusal is byte-identical to canonical fallback" {
  m4_prepare_show_config_differential
  destination="$project/.claude/settings.local.json"
  jq '.hooks.Stop[0].hooks += [{type:"command",command:"project-hook"}]' "$destination" > "$destination.next"
  mv -f "$destination.next" "$destination"; chmod 600 "$destination"
  m4_compare_show_config pre-acl-project-hook attached verified
  file="$TRELLIS_HOME_FIX/releases/1.6.4/payload/docs/readme.md"
  case "$(uname -s)" in
    Darwin) chmod +a "$(id -un) allow read" "$file" 2>/dev/null || skip 'chmod +a is unsupported here' ;;
    *) command -v setfacl >/dev/null 2>&1 || skip 'setfacl is missing'
       setfacl -m "u:$(id -un):r" "$file" 2>/dev/null || skip 'setfacl is unsupported here' ;;
  esac
  m4_compare_show_config release-acl unavailable none
}

@test "a pinned surface plan serves only its own harness selection" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" plan-fixture
  attach_portable_project "$project" personal 0.0.0
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  run with_attachment_libs '
    hc_portable_surface_plan_pin "$1" "$9" "'"$rel"'/payload" claude codex || exit 81
    a="$(hc_portable_payload_surface_plan "$1" "$9" "'"$rel"'/payload" claude codex)" || exit 82
    b="$(hc_portable_payload_surface_plan "$1" "$9" "'"$rel"'/payload" claude)" || exit 83
    [ "$a" = "$_HC_SURFACE_PLAN_MEMO" ] && echo same-selection=memo
    [ "$b" != "$_HC_SURFACE_PLAN_MEMO" ] && echo other-selection=expanded
  ' "$project"
  [ "$output" = $'same-selection=memo\nother-selection=expanded\nplans=2' ] || { echo "$output"; false; }
}

# 1.5.1 (large-checkout doctor, 224 rows): a second pin under the same key keeps the plan,
# so rows of one release and harness selection expand it once per process; a
# changed selection still re-expands.
@test "a repeated pin under the same key does not re-expand the surface plan" {
  initialize_release_store_machine
  project="$SANDBOX/project"
  make_portable_project "$project" plan-fixture
  attach_portable_project "$project" personal 0.0.0
  rel="$TRELLIS_HOME_FIX/releases/0.0.0"
  run with_attachment_libs '
    hc_portable_surface_plan_pin "$1" "$9" "'"$rel"'/payload" claude codex || exit 81
    first="$_HC_SURFACE_PLAN_MEMO_KEY"
    hc_portable_surface_plan_pin "$1" "$9" "'"$rel"'/payload" claude codex || exit 82
    [ -n "$first" ] && [ "$_HC_SURFACE_PLAN_MEMO_KEY" = "$first" ] && echo kept
    hc_portable_surface_plan_pin "$1" "$9" "'"$rel"'/payload" claude || exit 83
    [ "$_HC_SURFACE_PLAN_MEMO_KEY" != "$first" ] && echo replaced
  ' "$project"
  [ "$output" = $'kept\nreplaced\nplans=2' ] || { echo "$output"; false; }
}

# 1.5.1: read-only doctor reuses one checkout's sibling-owner scan across its
# rows, but never across a change to any owner file in that checkout.
@test "the managed-hooks sibling scan memo is dropped when a sibling owner changes" {
  initialize_release_store_machine
  local project="$SANDBOX/project" sibling="$SANDBOX/sibling" owner sibling_owner
  make_portable_project "$project" plan-fixture
  attach_portable_project "$project" personal 0.0.0
  git -C "$project" worktree add -q --detach "$sibling"
  attach_portable_project "$sibling" personal 0.0.0
  owner="$(owner_for_root "$project")"
  sibling_owner="$(owner_for_root "$sibling")"
  jq -e '.git_hooks.enabled == false' "$sibling_owner" >/dev/null || skip 'fixture sibling owns the hooks'
  run env -u TRELLIS_PYTHON TRELLIS_HOME="$TRELLIS_HOME_FIX" HC_PORTABLE_SCAN_MEMO=1 bash -c '
    lib="$1"; home="$2"; sib="$3"; main="$4"
    . "$lib/trellis-home.sh"; . "$lib/release-store.sh"; . "$lib/local-registry.sh"
    . "$lib/attachment.sh"; . "$lib/health-checks.sh"
    hc_portable_managed_hooks "$home" "$sib"; echo "first=$? $HC_PORTABLE_HOOK_STATE"
    hc_portable_managed_hooks "$home" "$sib"; echo "memo=$? $HC_PORTABLE_HOOK_STATE"
    chmod 644 "$main"
    hc_portable_managed_hooks "$home" "$sib"; echo "changed=$? $HC_PORTABLE_HOOK_STATE"
    chmod 600 "$main"
  ' scan "$LIB" "$TRELLIS_HOME_FIX" "$sibling_owner" "$owner"
  [ "$output" = $'first=0 shared\nmemo=0 shared\nchanged=1 corrupt' ] || { echo "$output"; false; }
}
