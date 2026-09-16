#!/usr/bin/env bash
# pi-web-search-tests.sh — reproducible offline runner for the Pi web-search
# adapter's deterministic tests (core-rules/pi/web-search/tests/*.test.ts).
#
# Method (Spec 047 T20 fenced run, made repeatable): copy the adapter directory
# into a fresh private fence under TMPDIR, prove every copied file is
# hash-identical to the source, strip provider/proxy/config environment so no
# test can reach a real endpoint or config, run Node's built-in test runner with
# type stripping from inside the fence, parse the summary, and remove the fence.
# Product code is never modified or imported from the working tree: the fence
# is the only cwd. No network is used; every transport in the tests is injected.
#
# Usage: scripts/pi-web-search-tests.sh [--source DIR] [--receipt FILE]
#   --source DIR    adapter directory to test (default: core-rules/pi/web-search)
#   --receipt FILE  write a JSON receipt (command, exit, counts, hashes, node)
# Exit: 0 all tests passed; 1 tests failed or summary unparseable;
#       2 bad arguments; 5 node or the source directory is unavailable.
set -euo pipefail

ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT/core-rules/pi/web-search"
RECEIPT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || { echo 'pi-web-search-tests: --source requires DIR' >&2; exit 2; }; SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#--source=}"; shift ;;
    --receipt) [ "$#" -ge 2 ] || { echo 'pi-web-search-tests: --receipt requires FILE' >&2; exit 2; }; RECEIPT="$2"; shift 2 ;;
    --receipt=*) RECEIPT="${1#--receipt=}"; shift ;;
    *) echo "pi-web-search-tests: unknown argument: $1" >&2; exit 2 ;;
  esac
done

NODE_BIN="${TRELLIS_NODE_BIN:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "pi-web-search-tests: node is not available (${NODE_BIN}); the adapter tests need Node >= 22.6 with --experimental-strip-types" >&2
  exit 5
fi
[ -d "$SOURCE" ] || { echo "pi-web-search-tests: source directory not found: $SOURCE" >&2; exit 5; }
SOURCE="$(CDPATH='' cd "$SOURCE" && pwd -P)"

# Hash from stdin, never by argument: shasum/sha256sum escape a file name that
# contains a backslash or newline and prefix the whole line with `\`, which
# shifted the recorded digest by one character. Reading stdin prints `<hash>  -`.
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | cut -c1-64
  else sha256sum < "$1" | cut -c1-64; fi
}

# Fresh private fence; cleaned up on every exit path. The rm target is a
# validated basename inside the parent mktemp chose, never a caller path.
FENCE_PARENT="${TMPDIR:-/tmp}"
FENCE="$(mktemp -d "$FENCE_PARENT/trellis-pi-web-search.XXXXXX")"
cleanup_fence() {
  local name="${FENCE##*/}"
  case "$name" in
    trellis-pi-web-search.*) (CDPATH='' cd "$(dirname "$FENCE")" && rm -rf -- "$name") ;;
  esac
}
trap cleanup_fence EXIT

WORK="$FENCE/web-search"
mkdir -p "$WORK"
# Copy the adapter directory verbatim (product modules, NOTICE, tests, fixtures).
# `cp -R dir/.` is portable across BSD and GNU cp; nothing is renamed.
cp -R "$SOURCE/." "$WORK/"
[ ! -d "$WORK/node_modules" ] || rm -rf "$WORK/node_modules"

# Prove the fence is the source, file by file, before anything runs.
HASH_LINES=""
COPIED=0
while IFS= read -r rel; do
  rel="${rel#./}"
  s="$(sha256_file "$SOURCE/$rel")"; f="$(sha256_file "$WORK/$rel")"
  if [ "$s" != "$f" ]; then echo "pi-web-search-tests: fence copy differs from source: $rel" >&2; exit 1; fi
  HASH_LINES="${HASH_LINES}${rel}"$'\t'"${s}"$'\n'
  COPIED=$((COPIED + 1))
done < <( CDPATH='' cd "$SOURCE" && find . -type f \( -name '*.ts' -o -name 'NOTICE' \) -not -path '*/node_modules/*' | LC_ALL=C sort )
[ "$COPIED" -gt 0 ] || { echo 'pi-web-search-tests: no adapter files found' >&2; exit 5; }

TEST_FILES=()
while IFS= read -r t; do [ -n "$t" ] && TEST_FILES+=("$t"); done < <( CDPATH='' cd "$WORK" && find tests -maxdepth 1 -type f -name '*.test.ts' | LC_ALL=C sort )
[ "${#TEST_FILES[@]}" -gt 0 ] || { echo 'pi-web-search-tests: no tests/*.test.ts files found' >&2; exit 5; }

# The summary parser below reads the `spec` reporter's "\u2139 <key> <n>" lines. Node's
# default reporter is not stable across versions and stdout here is a file, not a
# TTY, so the format is pinned rather than assumed. It is pinned by argument and
# NODE_OPTIONS is stripped above: a reporter inherited from NODE_OPTIONS is not
# overridden by this argument, it is *added* to it, and Node then rejects the run
# with ERR_INVALID_ARG_VALUE (reporters must match reporter-destinations).
REPORTER_ARGS=(--test-reporter=spec)

LOG="$FENCE/node-test.log"
START="$(date +%s)"
set +e
( CDPATH='' cd "$WORK" && env -u TRELLIS_WEB_SEARCH_CONFIG -u ANTIGRAVITY_BASE_URL -u NOAGY_BASE_URL \
    -u ANTIGRAVITY_USER_AGENT -u NOAGY_USER_AGENT -u ANTIGRAVITY_HUB_VERSION -u ANTIGRAVITY_HUB_CL \
    -u ANTIGRAVITY_HUB_OS -u ANTIGRAVITY_HUB_ARCH -u ANTIGRAVITY_PROJECT_ID -u ANTIGRAVITY_RUNTIME_MODEL \
    -u NOAGY_RUNTIME_MODEL -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY -u https_proxy -u http_proxy -u all_proxy \
    -u NODE_OPTIONS -u NODE_TEST_CONTEXT \
    "$NODE_BIN" --experimental-strip-types "${REPORTER_ARGS[@]}" --test "${TEST_FILES[@]}" ) > "$LOG" 2>&1
NODE_EXIT=$?
set -e
END="$(date +%s)"
cat "$LOG"

# Last matching summary value for KEY, empty if the summary is absent or
# unparseable. Must not fail: an unparseable summary is a reported result
# (exit 1 with a receipt), not an abort under `set -e` + `pipefail`.
count() { awk -v key="$1" '$1 == "ℹ" && $2 == key && $3 ~ /^[0-9]+$/ { v = $3 } END { if (v != "") print v }' "$LOG"; }
TESTS="$(count tests)"; PASS="$(count pass)"; FAIL="$(count fail)"
RESULT=1
if [ "$NODE_EXIT" -eq 0 ] && [ -n "$TESTS" ] && [ -n "$PASS" ] && [ "$FAIL" = "0" ] && [ "$PASS" -gt 0 ] && [ "$PASS" = "$TESTS" ]; then
  RESULT=0
fi
NODE_VERSION="$("$NODE_BIN" --version 2>/dev/null || echo unknown)"
printf 'pi-web-search-tests: node_exit=%s tests=%s pass=%s fail=%s elapsed=%ss files=%s fence=%s result=%s\n' \
  "$NODE_EXIT" "${TESTS:-?}" "${PASS:-?}" "${FAIL:-?}" "$((END - START))" "$COPIED" "$FENCE" "$RESULT"

# Minimal JSON string escaping for the receipt (quote and backslash). Tabs and
# newlines in adapter file names are out of scope: a tab would already have
# broken the tab-delimited hash list above.
json_escape() { printf '%s' "${1-}" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

if [ -n "$RECEIPT" ]; then
  {
    printf '{\n  "schema": "trellis-pi-web-search-tests/v1",\n'
    printf '  "source": "%s",\n  "fence": "%s",\n  "node_version": "%s",\n' \
      "$(json_escape "$SOURCE")" "$(json_escape "$FENCE")" "$(json_escape "$NODE_VERSION")"
    printf '  "command": ["%s"' "$(json_escape "$NODE_BIN")"
    for a in --experimental-strip-types "${REPORTER_ARGS[@]}" --test "${TEST_FILES[@]}"; do
      printf ', "%s"' "$(json_escape "$a")"
    done
    printf '],\n  "node_exit": %s,\n  "result_exit": %s,\n  "tests": %s,\n  "pass": %s,\n  "fail": %s,\n  "elapsed_seconds": %s,\n  "live_calls": 0,\n' \
      "$NODE_EXIT" "$RESULT" "${TESTS:-null}" "${PASS:-null}" "${FAIL:-null}" "$((END - START))"
    printf '  "fence_sha256": {\n'
    first=1
    while IFS=$'\t' read -r rel h; do
      [ -n "$rel" ] || continue
      if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
      printf '    "%s": "%s"' "$(json_escape "$rel")" "$h"
    done <<< "$HASH_LINES"
    printf '\n  }\n}\n'
  } > "$RECEIPT"
fi
exit "$RESULT"
