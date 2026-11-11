#!/bin/bash
# trellis reread override --session <id> --reason <why>
#
# Writes a short-lived reread-guard override for one agent session (decision 3,
# option c). The native hook starts under env -i, so TRELLIS_REREAD_OVERRIDE
# cannot reach it; this record can, and the legacy shell guards read it too.
#
# Record: $TRELLIS_HOME/state/reread-overrides/<key>, one line
#   "<expires>\t<created>\t<reason>\n"
# where <key> is the reread state key of the session id (the first 16 hex of
# its SHA-256, as _se_state_key derives it). Readers ignore any record that has
# expired or claims more than the TTL from the moment they read it.
# Breadcrumb: one "<created>\t<key>\t<expires>\t<reason>" row appended to
# log.tsv in the same directory before the record is published (no audit row,
# no override), plus a line on stderr.
#
# Agents cannot write the record directly: block-destructive denies shell
# writes that name the directory and reread-guard denies edits inside it.

set -euo pipefail

TTL=600

usage() {
  printf '%s\n' 'Usage: trellis reread override --session <id> --reason <why>' >&2
  exit 2
}

[ "${1:-}" = override ] || usage
shift
session='' reason=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || usage; session=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$session" ] && [ -n "$reason" ] || usage
case "$session$reason" in
  *[[:cntrl:]]*)
    printf '%s\n' 'trellis reread: --session and --reason must not contain control characters' >&2
    exit 2 ;;
esac
[ "${#reason}" -le 500 ] || { printf '%s\n' 'trellis reread: --reason is longer than 500 characters' >&2; exit 2; }

home=${TRELLIS_HOME:-}
if [ -z "$home" ]; then
  [ -n "${HOME:-}" ] || { printf '%s\n' 'trellis reread: TRELLIS_HOME or HOME is required' >&2; exit 2; }
  home=${HOME%/}/.trellis
fi
[ -d "$home" ] && [ ! -L "$home" ] || {
  printf 'trellis reread: Trellis home is unavailable: %s\n' "$home" >&2
  exit 5
}

if command -v sha256sum >/dev/null 2>&1; then
  key=$(printf '%s' "$session" | sha256sum)
else
  key=$(printf '%s' "$session" | shasum -a 256)
fi
key=${key%%[[:space:]]*}
key=${key:0:16}
case "$key" in
  *[!0-9a-f]*|'') printf '%s\n' 'trellis reread: could not derive the session key' >&2; exit 5 ;;
esac
[ "${#key}" -eq 16 ] || { printf '%s\n' 'trellis reread: could not derive the session key' >&2; exit 5; }

umask 077
dir=$home/state/reread-overrides
for d in "$home/state" "$dir"; do
  if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
    printf 'trellis reread: refusing non-directory state path: %s\n' "$d" >&2
    exit 5
  fi
  [ -d "$d" ] || mkdir "$d"
done

created=$(date +%s)
expires=$((created + TTL))
tmp=$(mktemp "$dir/.record.XXXXXX")
trap 'rm -f -- "${tmp:?}"' EXIT
printf '%s\t%s\t%s\n' "$expires" "$created" "$reason" > "$tmp"
# Audit before publication: a failed append must leave no new authority
# behind (the trap drops the unpublished record). A row whose publication then
# fails is an audited unsuccessful issuance, which is the safe direction.
if ! printf '%s\t%s\t%s\t%s\n' "$created" "$key" "$expires" "$reason" >> "$dir/log.tsv"; then
  printf 'trellis reread: could not append the audit breadcrumb to %s; no override issued\n' "$dir/log.tsv" >&2
  exit 5
fi
mv -f -- "$tmp" "$dir/$key"
trap - EXIT
printf 'trellis reread: override for session key %s active for %ss (until epoch %s); logged to %s\n' \
  "$key" "$TTL" "$expires" "$dir/log.tsv" >&2
