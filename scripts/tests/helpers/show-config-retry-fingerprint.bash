#!/usr/bin/env bash
# Exercise the actual retry token classifier with the frozen stat-token API.
set -u
repo=$1
base=$(mktemp -d "$TMPDIR/t12-retry-token.XXXXXX") || exit 1
home="$base/home"; parent="$home/state/attachments/checkout"; file="$parent/owner.json"
mkdir -p "$parent" || exit 1
chmod 700 "$home/state"
printf '{"ok":true}\n' > "$file"; chmod 600 "$file"
# shellcheck source=scripts/lib/local-registry.sh
. "$repo/scripts/lib/local-registry.sh" || exit 1
classifier=$(python3 -I - "$repo/scripts/show-config.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('_show_config_token_delta() {\n')
end = source.index('\n_show_config_release_rows_match() {', start)
print(source[start:end])
PY
) || exit 1
eval "$classifier" || exit 1
capture() { _local_registry_file_token "$parent" "$file" "$home"; }
check() {
  local label=$1 before=$2 after=$3 expected=$4 rc=0
  _show_config_token_delta "$before" "$after" "$parent" "$home" "$home" || rc=$?
  printf '%s=%s\n' "$label" "$rc"
  [ "$rc" -eq "$expected" ]
}
before=$(capture) || exit 2
check unchanged "$before" "$before" 0 || exit 3
printf 'unrelated\n' > "$home/state/lane-availability.json"
after=$(capture) || exit 4
check state-only "$before" "$after" 10 || exit 5
before=$after
printf 'unrelated\n' > "$home/unrelated"
after=$(capture) || exit 6
check home-only "$before" "$after" 10 || exit 7
before=$after
chmod 644 "$file"; chmod 600 "$file"
after=$(capture) || exit 8
check owner-ctime "$before" "$after" 4 || exit 9
before=$after
printf 'more\n' > "$home/state/unrelated-next"
chmod 644 "$file"; chmod 600 "$file"
after=$(capture) || exit 10
check owner-plus-parent "$before" "$after" 4 || exit 11
before=$after
mv "$home/state/attachments" "$home/state/attachments.moved"
mv "$home/state/attachments.moved" "$home/state/attachments"
after=$(capture) || exit 12
check other-ancestor "$before" "$after" 4 || exit 13
before=$after
chmod 755 "$home/state"
after=$(capture) || exit 14
check state-mode "$before" "$after" 4 || exit 15
check malformed "$before" invalid 4 || exit 16

# The show-config-owned scan records the selected owner first, then all other
# candidates, before hc_portable_attachment can read them. The first token also
# binds directory membership if a candidate appears after the glob.
checkout=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
owner_dir="$home/state/attachments/$checkout"; primary="$owner_dir/primary.json"; secondary="$owner_dir/secondary.json"
mkdir -p "$owner_dir"; printf '{}\n' > "$primary"; printf '{}\n' > "$secondary"; chmod 600 "$primary" "$secondary"
_SC_RETRY_SAFE=1; _SC_LEDGER_PATHS=(); _SC_LEDGER_TOKENS=(); _HC_DIAG_AUDIT_ACTIVE=1
_show_config_record_checkout_owners_for_retry "$home" "$checkout" "$primary"
[ "${#_SC_LEDGER_PATHS[@]}" -eq 2 ] && [ "${_SC_LEDGER_PATHS[0]}" = "$primary" ] &&
  [ "${_SC_LEDGER_PATHS[1]}" = "$secondary" ] && [ "$_SC_RETRY_SAFE" = 1 ] || exit 17
primary_before="${_SC_LEDGER_TOKENS[0]}"; secondary_before="${_SC_LEDGER_TOKENS[1]}"
chmod 644 "$secondary"; chmod 600 "$secondary"
secondary_after="$(_local_registry_file_token "$owner_dir" "$secondary" "$home")" || exit 18
rc=0; _show_config_token_delta "$secondary_before" "$secondary_after" "$owner_dir" "$home" "$home" || rc=$?
printf 'candidate-owner-ctime=%s\n' "$rc"
[ "$rc" -eq 4 ] || exit 19
printf '{}\n' > "$owner_dir/added.json"; chmod 600 "$owner_dir/added.json"
primary_after="$(_local_registry_file_token "$owner_dir" "$primary" "$home")" || exit 20
rc=0; _show_config_token_delta "$primary_before" "$primary_after" "$owner_dir" "$home" "$home" || rc=$?
printf 'owner-directory-membership=%s\n' "$rc"
[ "$rc" -eq 4 ] || exit 21
_SC_LEDGER_PATHS=(); _SC_LEDGER_TOKENS=(); _HC_DIAG_AUDIT_ACTIVE=0
_show_config_record_checkout_owners_for_retry "$home" "$checkout" "$primary"
[ "${_SC_LEDGER_PATHS[0]+set}" != set ] || exit 22
_HC_DIAG_AUDIT_ACTIVE=1; _SC_RETRY_SAFE=1
_show_config_record_checkout_owners_for_retry "$home" '../invalid' "$primary"
[ "$_SC_RETRY_SAFE" = 0 ] && [ "${_SC_LEDGER_PATHS[0]+set}" != set ] || exit 23
printf '%s\n' 'candidate-scan=ok'
