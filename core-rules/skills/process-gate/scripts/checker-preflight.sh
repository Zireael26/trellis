#!/usr/bin/env bash
# Fail-closed identity check for binaries delegated to by process-gate.
# Usage: checker-preflight.sh

set -uo pipefail

CHECKERS=(gitleaks semgrep osv-scanner jq)
failed=0

for checker in "${CHECKERS[@]}"; do
  path="$(type -P "$checker" 2>/dev/null || true)"
  if [ -z "$path" ] || [ ! -x "$path" ]; then
    printf 'fail checker-preflight: %s not found on PATH\n' "$checker" >&2
    failed=1
    continue
  fi

  if ! version="$("$path" --version 2>&1)"; then
    printf 'fail checker-preflight: %s version check failed at %s\n' "$checker" "$path" >&2
    failed=1
    continue
  fi
  version="${version%%$'\n'*}"
  if [ -z "$version" ]; then
    printf 'fail checker-preflight: %s returned an empty version at %s\n' "$checker" "$path" >&2
    failed=1
    continue
  fi

  printf 'pass checker-preflight: %s=%s version=%s\n' "$checker" "$path" "$version"
done

[ "$failed" -eq 0 ] || exit 4
