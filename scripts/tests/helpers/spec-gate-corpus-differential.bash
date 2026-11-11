#!/usr/bin/env bash
# Run the existing spec-gate fixtures with both config resolvers on every call.
# Usage: bash scripts/tests/helpers/spec-gate-corpus-differential.bash NEW_OUTPUT_DIR [CORE_OVERRIDE]
# Run once with Bash 3.2 first on PATH and again with Bash 5 first on PATH.
# The optional override is for mutation testing only. The private source tree is
# an archive of HEAD, with the current core and the frozen oracle overlaid.
set -eu
set -o pipefail
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'expected new output directory and optional core override' >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
parent=$(cd -- "$(dirname -- "$1")" && pwd -P)
out="$parent/${1##*/}"
core=${2:-"$repo/core-rules/hooks/lib/spec-gate-core.sh"}
[ -f "$core" ] || { echo 'core not found' >&2; exit 2; }
mkdir -m 700 "$out"
mkdir -m 700 "$out/tree" "$out/home" "$out/trellis" "$out/tmp" "$out/comparisons"
export HOME="$out/home" TRELLIS_HOME="$out/trellis" TMPDIR="$out/tmp"
export GIT_CONFIG_GLOBAL="$out/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
git -C "$repo" archive HEAD | tar -xf - -C "$out/tree"
cp "$core" "$out/tree/core-rules/hooks/lib/spec-gate-core.sh"
file="$out/tree/core-rules/hooks/lib/spec-gate-core.sh"

# Instrument only a disposable copy, never the production file. Both resolvers
# run in the SAME fixture, with the SAME object bindings, and raw stdout, stderr
# and exit status are compared. The candidate's bytes and status still go to
# the original Bats assertion. Any difference persists outside Bats' temp dir.
cat >> "$file" <<'SH'
_sg_diff_definition=$(declare -f sg_resolve_cfg)
eval "${_sg_diff_definition/sg_resolve_cfg/_sg_diff_candidate}"
unset _sg_diff_definition
SH
awk '/^sg_verdict\(\) \{/ {exit} {sub(/^sg_resolve_cfg\(\)/, "_sg_diff_reference()"); print}' \
  "$repo/scripts/tests/helpers/spec-gate-reference.bash" >> "$file"
cat >> "$file" <<'SH'
sg_resolve_cfg() {
  local _sg_diff_dir _sg_diff_c _sg_diff_r
  _sg_diff_dir=$(/usr/bin/mktemp -d "$SG_SPEC_DIFF_ROOT/case.XXXXXXXX") || return 2
  if _sg_diff_candidate "$@" >"$_sg_diff_dir/candidate.out" 2>"$_sg_diff_dir/candidate.err"; then _sg_diff_c=0; else _sg_diff_c=$?; fi
  if _sg_diff_reference "$@" >"$_sg_diff_dir/reference.out" 2>"$_sg_diff_dir/reference.err"; then _sg_diff_r=0; else _sg_diff_r=$?; fi
  if [ "$_sg_diff_c" -eq "$_sg_diff_r" ] &&
    /usr/bin/cmp -s "$_sg_diff_dir/candidate.out" "$_sg_diff_dir/reference.out" &&
    /usr/bin/cmp -s "$_sg_diff_dir/candidate.err" "$_sg_diff_dir/reference.err"; then
    printf 'match\n' >> "$SG_SPEC_DIFF_ROOT/events.log"
    /bin/cat "$_sg_diff_dir/candidate.out"
    /bin/cat "$_sg_diff_dir/candidate.err" >&2
    /bin/rm -rf "$_sg_diff_dir"
  else
    printf 'MISMATCH %s candidate=%s reference=%s\n' "$_sg_diff_dir" "$_sg_diff_c" "$_sg_diff_r" >> "$SG_SPEC_DIFF_ROOT/events.log"
    /bin/cat "$_sg_diff_dir/candidate.out"
    /bin/cat "$_sg_diff_dir/candidate.err" >&2
  fi
  return "$_sg_diff_c"
}
SH

cd "$out/tree"
result=0
for suite in scripts/tests/spec-gate.bats scripts/tests/spec-gate-diff-base.bats; do
  name=${suite##*/}; name=${name%.bats}
  export SG_SPEC_DIFF_ROOT="$out/comparisons/$name"
  mkdir -m 700 "$SG_SPEC_DIFF_ROOT"
  : > "$SG_SPEC_DIFF_ROOT/events.log"
  if bats "$suite" > "$out/$name.tap" 2>&1; then rc=0; else rc=$?; result=1; fi
  matches=$(grep -c '^match$' "$SG_SPEC_DIFF_ROOT/events.log" || :)
  mismatches=$(grep -c '^MISMATCH ' "$SG_SPEC_DIFF_ROOT/events.log" || :)
  printf '%s bats_exit=%s byte_matches=%s mismatches=%s\n' "$suite" "$rc" "$matches" "$mismatches"
  if [ "$matches" -eq 0 ] || [ "$mismatches" -ne 0 ]; then result=1; fi
done
exit "$result"
