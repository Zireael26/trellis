#!/usr/bin/env bash
# Portable sed -i wrapper. Source this file, then call:
#   sed_inplace -e 's/foo/bar/' file.txt
# It detects BSD (macOS) vs GNU sed and adjusts the -i invocation.
#
# Usage:
#   . "$(dirname "$0")/lib/sed-portable.sh"
#   sed_inplace -e 's/__TRELLIS_PATH__/'"$TRELLIS_ROOT"'/g' some-file.md

set -euo pipefail

if [ -z "${_PG_SED_FLAVOR:-}" ]; then
  if sed --version >/dev/null 2>&1; then
    _PG_SED_FLAVOR="gnu"
  else
    _PG_SED_FLAVOR="bsd"
  fi
fi

sed_inplace() {
  if [ "$_PG_SED_FLAVOR" = "gnu" ]; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}
