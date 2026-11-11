#!/usr/bin/env bash
# Compare the actual private batch, its canonical fallback and canonical owner
# predicates on a small real Git worktree. This is also a focused mutation
# target; no production environment variable selects a test fault.
set -u
repo=$1
base=$(mktemp -d "$TMPDIR/m4-owner.XXXXXX") || exit 1
root="$base/work"; home="$base/home"; mkdir -p "$root" "$home"
git init -q "$root" || exit 1
mkdir -p "$root/real" "$root/empty" "$root/parent"
printf 'abc\n' > "$root/real/file"; chmod 644 "$root/real/file"
printf 'second\n' > "$root/real/second"; chmod 644 "$root/real/second"
ln -s file "$root/real/link"
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,2]},"user":"untouched"}' > "$root/real/settings.json"
chmod 600 "$root/real/settings.json"
# shellcheck source=scripts/lib/attachment.sh
. "$repo/scripts/lib/attachment.sh" || exit 1
# shellcheck source=scripts/lib/health-checks.sh
. "$repo/scripts/lib/health-checks.sh" || exit 1
worktree_id=$(_attachment_hash_text "$root") || exit 1
checkout_id=$(_attachment_hash_text "$root/.git") || exit 1
file_hash=$(_attachment_hash "$root/real/file") || exit 1
second_hash=$(_attachment_hash "$root/real/second") || exit 1
render_hash=$(_attachment_hash "$root/real/settings.json") || exit 1
owner="$home/owner.json"
jq -n --arg root "$root" --arg work "$worktree_id" --arg checkout "$checkout_id" \
  --arg f "$file_hash" --arg s "$second_hash" --arg r "$render_hash" '
  {project_root:$root,worktree_root:$root,worktree_id:$work,checkout_id:$checkout,
   artifacts:[{path:"real/file",kind:"file",sha256:$f,mode:"0644"},
              {path:"real/second",kind:"file",sha256:$s,mode:"0644"},
              {path:"real/link",kind:"symlink",target:"file"},
              {path:"empty",kind:"directory"},{path:"parent",kind:"parent"},
              {path:"real/settings.json",kind:"file",sha256:$r,mode:"0600"}],
   renders:[{path:"real/settings.json",after_mode:"0600",after_sha256:$r,
             owned_keys:[{path:["one"],value:true},{path:["empty"],value:null},
                         {path:["nested","x"],value:[1,2]}]}]}' > "$owner" || exit 1
chmod 600 "$owner"
mkdir -p "$base/no-verdict"
printf '#!/bin/bash\nexit 0\n' > "$base/no-verdict/python3"
chmod 755 "$base/no-verdict/python3"

# Verdicts and diagnostic bytes must agree after fallback. When the fixture is
# supported, also require the batch itself to reach the expected verdict so a
# silently disabled optimization cannot satisfy the differential test.
run_pair() {
  local label=$1 expected=$2 batch_expected=$3 canonical batch actual canonical_output actual_output
  _hc_portable_clear_audit_scope
  _HC_DIAG_AUDIT_ACTIVE=1
  _hc_portable_owner_scope_begin "$home" "$owner" || return 1
  [ "$_HC_DIAG_OWNER_ACTIVE" = 1 ] || { echo "$label: no fine owner token"; return 1; }
  canonical=0; canonical_output="$(_attachment_verify_owner_artifacts "$owner" "$home" 2>&1)" || canonical=$?
  batch=0; _hc_portable_owner_artifacts_batch "$owner" "$home" >/dev/null 2>&1 || batch=$?
  actual=0; actual_output="$(_hc_portable_verify_owner_artifacts "$owner" "$home" 2>&1)" || actual=$?
  printf '%s canonical=%s batch=%s effective=%s\n' "$label" "$canonical" "$batch" "$actual"
  [ "$canonical" -eq "$expected" ] && [ "$actual" -eq "$canonical" ] &&
    [ "$actual_output" = "$canonical_output" ] || return 1
  case "$batch_expected" in
    verified) [ "$batch" -eq 0 ] ;;
    miss) [ "$batch" -ne 0 ] ;;
    *) return 1 ;;
  esac
}

run_pair clean 0 verified || exit 11
chmod 644 "$root/real/settings.json"
run_pair render-mode 3 miss || exit 31
chmod 600 "$root/real/settings.json"
cp "$owner" "$base/owner-pairing-original"
jq '.renders[0].after_mode = "0644"' "$owner" > "$base/owner-pairing-next" && cp -f "$base/owner-pairing-next" "$owner"
run_pair pairing-invalid 3 miss || exit 32
cp -f "$base/owner-pairing-original" "$owner"; chmod 600 "$owner"
# The canonical B1 planner also needs Python; a silent interpreter makes it
# refuse, rather than making the owner valid. The batch must still fall back.
PATH="$base/no-verdict:$PATH" run_pair silent-interpreter-fallback 3 miss || exit 11
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,2]},"user":"changed"}' > "$root/real/settings.json"
run_pair unowned-change 0 verified || exit 12
printf '%s\n' '{"one":1,"empty":null,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair bool-number 3 miss || exit 13
printf '%s\n' '{"one":true,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair missing-null 3 miss || exit 14
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,"2"]}}' > "$root/real/settings.json"
run_pair array-element-type 3 miss || exit 15
# This malformed document would escape an unsafe raw-JSON batch envelope.
printf '%s' '{}],"owner":{"renders":[]},"documents":[' > "$root/real/settings.json"
run_pair framing-injection 3 miss || exit 16
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
printf x > "$root/empty/extra"
run_pair directory-extra 3 miss || exit 17
rm -f "${root:?}/empty/extra"
rm -f "${root:?}/real/link"; ln -s wrong "$root/real/link"
run_pair link-target 3 miss || exit 18
rm -f "${root:?}/real/link"; ln -s file "$root/real/link"
printf 'xyz\n' > "$root/real/file"
run_pair file-content 3 miss || exit 19
printf 'abc\n' > "$root/real/file"; chmod 600 "$root/real/file"
run_pair file-mode 3 miss || exit 20
chmod 644 "$root/real/file"
printf 'changed\n' > "$root/real/second"
run_pair second-artifact 3 miss || exit 21
printf 'second\n' > "$root/real/second"
# The canonical check accepts hardlinked regular files. The batch deliberately
# declines them and must let the legacy check decide, not report a finding.
ln "$root/real/file" "$root/hardlink"
run_pair hardlink-fallback 0 miss || exit 22
rm -f "${root:?}/hardlink"
run_pair restored 0 verified || exit 23

# B1 owns only the positional canonical prefix of each hooks event and each
# block's hook list. Appended project blocks and hooks are not owned. Compare
# positive and negative shapes with the canonical detail planner, including
# Python's strict numeric types and duplicate/overlapping path rejection.
cp "$owner" "$base/owner-before-prefix"
jq '.renders[0].owned_keys = [
  {path:["hooks","Stop"],value:[{matcher:"Bash",hooks:[{command:"owned-a"},{command:"owned-b"}]}]},
  {path:["number"],value:1}, {path:["nested","x"],value:[1,2]}]' \
  "$owner" > "$base/owner-prefix" && cp -f "$base/owner-prefix" "$owner"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-exact 0 verified || exit 35
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"},{"command":"project"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-appended-hook 0 verified || exit 36
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]},{"project":"block"}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-appended-block 0 verified || exit 37
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]},null,17]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-arbitrary-project-blocks 0 verified || exit 46
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"changed","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-matcher-drift 3 miss || exit 38
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","extra":true,"hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-block-field-drift 3 miss || exit 39
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-b"},{"command":"owned-a"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-reordered-hooks 3 miss || exit 40
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-shortened-hooks 3 miss || exit 41
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":{}}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-hooks-not-array 3 miss || exit 47
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"nested":{"x":[1,2,3]}}' > "$root/real/settings.json"
run_pair ordinary-array-not-prefix 3 miss || exit 48
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1.0,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair int-versus-float 3 miss || exit 42
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair duplicate-live-json-key 3 miss || exit 43
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
jq '.renders[0].owned_keys += [{path:["hooks"],value:{"Stop":[]}}]' \
  "$base/owner-prefix" > "$base/owner-overlap" && cp -f "$base/owner-overlap" "$owner"
run_pair overlapping-owned-paths 3 miss || exit 44
jq '.renders[0].owned_keys[0].value += [{matcher:"Read",hooks:[{command:"owned-c"}]}]' \
  "$base/owner-prefix" > "$base/owner-multiblock" && cp -f "$base/owner-multiblock" "$owner"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Read","hooks":[{"command":"owned-c"}]},{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-reordered-blocks 3 miss || exit 49
jq '.renders[0].owned_keys = [{path:["hooks","Stop","nested"],value:[1,2]}]' \
  "$base/owner-prefix" > "$base/owner-deep-path" && cp -f "$base/owner-deep-path" "$owner"
printf '%s\n' '{"hooks":{"Stop":{"nested":[1,2,3]}}}' > "$root/real/settings.json"
run_pair deep-hooks-path-not-prefix 3 miss || exit 50
cp -f "$base/owner-before-prefix" "$owner"; chmod 600 "$owner"
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
run_pair prefix-fixture-restored 0 verified || exit 45

# Modify a file only after the batch has read every leaf and compared its jq
# documents, but before its postflight. The fault exists only in this test's
# in-memory copy of the function, not in production or a request parameter.
export M4_TEST_RACE_FILE="$root/real/file"
original_batch="$(declare -f _hc_portable_owner_artifacts_batch)"
instrumented="$(printf '%s\n' "$original_batch" | python3 -I -c '
import sys
source = sys.stdin.read()
needle = "    for fd, parent_fd, name, expected, qualified in held:\n"
if source.count(needle) != 1:
    raise SystemExit(1)
injection = """    race_file = os.environ[\"M4_TEST_RACE_FILE\"]
    previous = os.stat(race_file)
    os.chmod(race_file, 0o600)
    with open(race_file, \"wb\") as changed:
        changed.write(b\"xyz\\n\")
    os.chmod(race_file, 0o644)
    os.utime(race_file, ns=(previous.st_atime_ns, previous.st_mtime_ns))
"""
sys.stdout.write(source.replace(needle, injection + needle))
')" || exit 24
[ -n "$instrumented" ] || exit 24
eval "$instrumented" || exit 24
batch=0; _hc_portable_owner_artifacts_batch "$owner" "$home" >/dev/null 2>&1 || batch=$?
canonical=0; _attachment_verify_owner_artifacts "$owner" "$home" >/dev/null 2>&1 || canonical=$?
actual=0; _hc_portable_verify_owner_artifacts "$owner" "$home" >/dev/null 2>&1 || actual=$?
printf 'in-pass-old-mtime canonical=%s batch=%s effective=%s\n' "$canonical" "$batch" "$actual"
[ "$canonical" -eq 3 ] && [ "$batch" -ne 0 ] && [ "$actual" -eq 3 ] || exit 25

# A second owner is checked under its own token while the primary owner's
# guarded scope remains active. The test-only wrappers record whether the
# original predicate or the batch actually ran; no production fault switch.
eval "$original_batch" || exit 26
printf 'abc\n' > "$root/real/file"; chmod 644 "$root/real/file"
primary="$home/primary.json"; printf '{}\n' > "$primary"; chmod 600 "$primary"
_hc_portable_clear_audit_scope; _HC_DIAG_AUDIT_ACTIVE=1
_hc_portable_owner_scope_begin "$home" "$primary" || exit 26
[ "$_HC_DIAG_OWNER_ACTIVE" = 1 ] || exit 26
eval "$(declare -f _attachment_verify_owner_artifacts | sed '1s/_attachment_verify_owner_artifacts/_m4_secondary_canonical/')" || exit 26
eval "$(declare -f _hc_portable_owner_artifacts_batch | sed '1s/_hc_portable_owner_artifacts_batch/_m4_secondary_batch/')" || exit 26
eval "$(declare -f _local_registry_file_token | sed '1s/_local_registry_file_token/_m4_secondary_token/')" || exit 26
M4_SECONDARY_RACE=0 M4_SECONDARY_COARSE=0
_attachment_verify_owner_artifacts() {
  printf 'fallback\n' >> "$base/fallback-log"
  _m4_secondary_canonical "$@"
}
_hc_portable_owner_artifacts_batch() {
  printf 'batch\n' >> "$base/batch-log"
  if env | grep -qE '^_hc_secondary_(before|after)='; then
    printf 'exported\n' >> "$base/batch-log"
    return 1
  fi
  _m4_secondary_batch "$@" || return 1
  if [ "$M4_SECONDARY_RACE" = 1 ]; then
    chmod 644 "$1" && chmod 600 "$1" || return 1
  fi
}
_local_registry_file_token() {
  if [ "$M4_SECONDARY_COARSE" = 1 ] && [ "$2" = "$owner" ]; then return 1; fi
  _m4_secondary_token "$@"
}
secondary_pair() {
  local label="$1" expected="$2" take_batch="$3" take_fallback="$4" c=0 a=0 co ao
  : > "$base/batch-log"; : > "$base/fallback-log"
  co="$(_m4_secondary_canonical "$owner" "$home" 2>&1)" || c=$?
  ao="$(_hc_portable_verify_secondary_owner_artifacts "$owner" "$home" 2>&1)" || a=$?
  printf '%s canonical=%s effective=%s batch=%s fallback=%s\n' "$label" "$c" "$a" \
    "$(wc -l < "$base/batch-log" | tr -d ' ')" "$(wc -l < "$base/fallback-log" | tr -d ' ')"
  [ "$c" -eq "$expected" ] && [ "$a" -eq "$c" ] && [ "$co" = "$ao" ] || return 1
  if [ "$take_batch" = yes ]; then [ -s "$base/batch-log" ] || return 1
  else [ ! -s "$base/batch-log" ] || return 1; fi
  if [ "$take_fallback" = yes ]; then [ -s "$base/fallback-log" ] || return 1
  else [ ! -s "$base/fallback-log" ] || return 1; fi
}
secondary_pair secondary-clean 0 yes no || exit 27
cp "$owner" "$base/secondary-before-prefix"
cp -f "$base/owner-prefix" "$owner"; chmod 600 "$owner"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"},{"command":"owned-b"},{"command":"project"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
secondary_pair secondary-prefix-appended 0 yes no || exit 51
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"command":"owned-a"}]}]},"number":1,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
secondary_pair secondary-prefix-drift 3 yes yes || exit 52
cp -f "$base/secondary-before-prefix" "$owner"; chmod 600 "$owner"
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
chmod 644 "$root/real/settings.json"
secondary_pair secondary-render-mode 3 yes yes || exit 33
chmod 600 "$root/real/settings.json"
cp "$owner" "$base/secondary-pairing-original"
jq '.renders[0].after_mode = "0644"' "$owner" > "$base/secondary-pairing-next" && cp -f "$base/secondary-pairing-next" "$owner"
secondary_pair secondary-pairing-invalid 3 yes yes || exit 34
cp -f "$base/secondary-pairing-original" "$owner"; chmod 600 "$owner"
set -a
secondary_pair secondary-allexport 0 yes no || exit 27
set +a
rm -f "${root:?}/real/link"; ln -s wrong "$root/real/link"
secondary_pair secondary-drift 3 yes yes || exit 28
rm -f "${root:?}/real/link"; ln -s file "$root/real/link"
printf '%s\n' '{"one":1,"empty":null,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
secondary_pair secondary-typed-key 3 yes yes || exit 28
printf '%s\n' '{"one":true,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
secondary_pair secondary-missing-null 3 yes yes || exit 28
printf '%s' '{}],"owner":{"renders":[]},"documents":[' > "$root/real/settings.json"
secondary_pair secondary-framing 3 yes yes || exit 28
printf '%s\n' '{"one":true,"empty":null,"nested":{"x":[1,2]}}' > "$root/real/settings.json"
printf x > "$root/empty/extra"
secondary_pair secondary-directory 3 yes yes || exit 28
rm -f "${root:?}/empty/extra"
printf 'changed\n' > "$root/real/second"
secondary_pair secondary-file-content 3 yes yes || exit 28
printf 'second\n' > "$root/real/second"
cp "$owner" "$base/owner-original"
jq '.render_context = {}' "$owner" > "$base/owner-next" && cp -f "$base/owner-next" "$owner"
secondary_pair secondary-home-binding 3 yes yes || exit 28
cp -f "$base/owner-original" "$owner"; chmod 600 "$owner"
ln "$root/real/file" "$root/hardlink"
secondary_pair secondary-hardlink 0 yes yes || exit 28
rm -f "${root:?}/hardlink"
M4_SECONDARY_RACE=1
secondary_pair secondary-owner-changed 0 yes yes || exit 29
M4_SECONDARY_RACE=0 M4_SECONDARY_COARSE=1
secondary_pair secondary-coarse-token 0 no yes || exit 30
