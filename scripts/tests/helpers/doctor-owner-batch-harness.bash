#!/usr/bin/env bash
# Exercise doctor's real prepass and health-check dispatch with a controlled
# verdict producer. The owner files and their stat tokens are real.
set -u
root=$1
scenario=$2
sandbox=$3
home="$sandbox/parent/home"
hex=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
one=1111111111111111111111111111111111111111111111111111111111111111
two=2222222222222222222222222222222222222222222222222222222222222222
owner1="$home/state/attachments/$hex/$one.json"
owner2="$home/state/attachments/$hex/$two.json"
mkdir -p "$home/state/attachments/$hex" "$home/state/attachment-journals" "$home/state/locks" "$sandbox/scratch"
chmod 700 "$home" "$home/state" "$home/state/attachments" "$home/state/attachments/$hex" \
  "$home/state/attachment-journals" "$home/state/locks" "$sandbox/scratch"
jq -n --arg root "$sandbox/project1" --arg c "$hex" --arg w "$one" \
  '{project_root:$root,worktree_root:$root,checkout_id:$c,worktree_id:$w,fleet:"personal",project_id:"fixture",attachment_id:"id-1",release:"1.2.3",status:"committed",schema_marker:true}' > "$owner1"
jq -n --arg root "$sandbox/project2" --arg c "$hex" --arg w "$two" \
  '{project_root:$root,worktree_root:$root,checkout_id:$c,worktree_id:$w,fleet:"personal",project_id:"fixture",attachment_id:"id-2",release:"1.2.3",status:"committed",schema_marker:true}' > "$owner2"
case "$scenario" in
  foreign) filter='.worktree_root = "/a/foreign/worktree"' ;;
  project_root) filter='.project_root = "/a/foreign/worktree"' ;;
  wrong_fleet) filter='.fleet = "other"' ;;
  wrong_project) filter='.project_id = "other"' ;;
  wrong_attachment) filter='.attachment_id = "other"' ;;
  wrong_release) filter='.release = "2.3.4"' ;;
  wrong_status) filter='.status = "pending"' ;;
  wrong_schema) filter='.schema_marker = false' ;;
  *) filter='' ;;
esac
if [ -n "$filter" ]; then
  jq "$filter" "$owner2" > "$sandbox/foreign"
  cp "$sandbox/foreign" "$owner2"
fi
jq -n --arg r1 "$sandbox/project1" --arg r2 "$sandbox/project2" --arg c "$hex" --arg w1 "$one" --arg w2 "$two" \
  '{entries:[{kind:"worktree",availability:"available",identity:{state:"verified"},root:$r1,checkout_id:$c,worktree_id:$w1,fleet:"personal",project_id:"fixture",attachment_id:"id-1",release:"1.2.3"},
             {kind:"worktree",availability:"available",identity:{state:"verified"},root:$r2,checkout_id:$c,worktree_id:$w2,fleet:"personal",project_id:"fixture",attachment_id:"id-2",release:"1.2.3"}]}' > "$sandbox/snapshot"
chmod 600 "$owner1" "$owner2"
[ "$scenario" != wrong_mode ] || chmod 644 "$owner2"
if [ "$scenario" = ancestor_swap ]; then
  cp -Rp "$sandbox/parent" "$sandbox/alternate"
fi
: > "$sandbox/events"
export home owner1 owner2 scenario sandbox
# A caller cannot inject or export a doctor proof through the environment.
export _HC_DOCTOR_OWNER_HOME=forged _HC_DOCTOR_OWNER_COUNT=100

. "$root/scripts/lib/attachment.sh"
. "$root/scripts/lib/local-registry.sh"
. "$root/scripts/lib/health-checks.sh"
# Unit fixtures exercise binding and dispatch; real schema validation is
# exercised separately with sealed, attached owners in the integration suite.
_attachment_owner_schema_filter='(.schema_marker == true)'
# The prepass lives in doctor.sh; avoid running the doctor's CLI on source.
prepass="$(awk '/^doctor_owner_artifacts_prepare\(\)/ {p=1} p {print} p && /^}/ {exit}' "$root/scripts/doctor.sh")"
[ -n "$prepass" ] || { echo 'doctor prepass not present'; exit 89; }
eval "$prepass"

# shellcheck disable=SC2034  # Read by the extracted doctor prepass.
doctor_scratch_require() { DOCTOR_SCRATCH_DIR="$sandbox/scratch"; }
case "$scenario" in
  scratch_*)
    # Check the environment seen by the actual transport, then restore its
    # original implementation inside this subshell.
    trellis_jq() (
      [ "${TMPDIR-}" = "$sandbox/scratch" ] &&
        [ "$(/usr/bin/printenv TMPDIR)" = "$sandbox/scratch" ] || exit 1
      printf 'jq scratch\n' >> "$sandbox/events"
      . "$root/scripts/lib/trellis-home.sh"
      trellis_jq "$@"
    )
    ;;
esac
attachment_owner_artifact_verdicts() {
  case "$scenario" in
    scratch_*)
      [ "${TMPDIR-}" = "$sandbox/scratch" ] &&
        [ "$(/usr/bin/printenv TMPDIR)" = "$sandbox/scratch" ] || return 10
      printf 'verdict scratch\n' >> "$sandbox/events"
      ;;
  esac
  printf 'batch\n' >> "$sandbox/events"
  _attachment_state_readonly_ok "$1" || return 10
  shift
  printf 'input %s\n' "$@" >> "$sandbox/events"
  case "$scenario" in
    status10) printf '0\t%s\n0\t%s\n' "$owner1" "$owner2"; return 10 ;;
    partial) printf '0\t%s\n' "$owner1" ;;
    extra) printf '0\t%s\n0\t%s\n0\t%s\n' "$owner1" "$owner2" "$owner2" ;;
    blank) printf '0\t%s\n0\t%s\n\n' "$owner1" "$owner2" ;;
    unterminated) printf '0\t%s\n0\t%s' "$owner1" "$owner2" ;;
    reordered) printf '0\t%s\n0\t%s\n' "$owner2" "$owner1" ;;
    malformed) printf '0\t%s\n2\t%s\n' "$owner1" "$owner2" ;;
    mixed) printf '0\t%s\n1\t%s\n' "$owner1" "$owner2" ;;
    batch_changed)
      printf '0\t%s\n0\t%s\n' "$owner1" "$owner2"
      printf ' ' >> "$owner2"
      ;;
    ancestor_swap)
      # Simulate a batch that reads another ancestor tree, then restore the
      # original before T2. The accepted reporting window cannot detect it.
      local original_inode alternate_inode
      original_inode="$(stat -c %i "$owner1" 2>/dev/null || stat -f %i "$owner1")" || return 10
      mv "$sandbox/parent" "$sandbox/parent-away"
      mv "$sandbox/alternate" "$sandbox/parent"
      [ -f "$owner1" ] && [ -f "$owner2" ] || return 10
      alternate_inode="$(stat -c %i "$owner1" 2>/dev/null || stat -f %i "$owner1")" || return 10
      [ "$original_inode" != "$alternate_inode" ] || return 10
      printf '0\t%s\n' "$@"
      mv "$sandbox/parent" "$sandbox/alternate"
      mv "$sandbox/parent-away" "$sandbox/parent"
      ;;
    ancestor_churn)
      printf '0\t%s\n' "$@"
      printf x > "$sandbox/unrelated"; rm "$sandbox/unrelated"
      printf x > "$sandbox/parent/unrelated"; rm "$sandbox/parent/unrelated"
      # Optional only in an isolated container: exercise churn in its actual
      # /tmp, not in a shared host test-runner directory.
      if [ "${DOCTOR_TEST_TMP_CHURN_DIR:-}" = /tmp ]; then
        local tmp_churn
        tmp_churn="$(mktemp /tmp/doctor-batch.XXXXXXXX)" || return 10
        rm "$tmp_churn" || return 10
        printf 'actual tmp churn\n' >> "$sandbox/events"
      fi
      ;;
    *) printf '0\t%s\n' "$@" ;;
  esac
}
_attachment_verify_owner_artifacts() {
  printf 'scalar %s\n' "$1" >> "$sandbox/events"
  printf 'scalar diagnostic for %s\n' "${1##*/}"
  return 23
}

if [ "$scenario" = missing_state ]; then
  rmdir "$home/state/locks"
elif [ "$scenario" = unsafe_state ]; then
  chmod 755 "$home/state/attachments"
fi
case "$scenario" in
  scratch_exported|scratch_unexported)
    mkdir -p "$sandbox/caller-tmp"
    TMPDIR="$sandbox/caller-tmp"
    if [ "$scenario" = scratch_exported ]; then export TMPDIR; else export -n TMPDIR; fi
    ;;
  scratch_unset) unset TMPDIR ;;
esac
doctor_owner_artifacts_prepare "$home" "$sandbox/snapshot" "$owner1" "$owner2"
case "$scenario" in
  scratch_exported)
    [ "${TMPDIR-}" = "$sandbox/caller-tmp" ] &&
      [ "$(/usr/bin/printenv TMPDIR)" = "$sandbox/caller-tmp" ] || exit 1 ;;
  scratch_unexported)
    [ "${TMPDIR-}" = "$sandbox/caller-tmp" ] &&
      ! /usr/bin/printenv TMPDIR >/dev/null || exit 1 ;;
  scratch_unset) [ "${TMPDIR+x}" != x ] || exit 1 ;;
esac
case "$scenario" in
  scratch_*)
    grep -Fxq 'jq scratch' "$sandbox/events" &&
      grep -Fxq 'verdict scratch' "$sandbox/events" || exit 1
    printf 'scratch environment restored\n'
    ;;
esac
if env | grep -q '^_HC_DOCTOR_OWNER_'; then
  echo 'doctor cache leaked to child environment'
  exit 1
fi
if [ -n "$filter" ] && grep -Fxq "input $owner2" "$sandbox/events"; then
  echo 'unbound owner reached the artifact verifier'
  exit 1
fi
if [ "$scenario" = unrelated_use ]; then
  printf 'unrelated sibling\n' > "$sandbox/unrelated"
elif [ "$scenario" = ancestor_mode ]; then
  chmod g+w "$sandbox/parent"
elif [ "$scenario" = ancestor_symlink ]; then
  mv "$sandbox/parent" "$sandbox/parent-away"
  ln -s "$sandbox/parent-away" "$sandbox/parent"
elif [ "$scenario" = ancestor_replace ]; then
  mv "$sandbox/parent" "$sandbox/parent-away"
  cp -Rp "$sandbox/parent-away" "$sandbox/parent"
elif [ "$scenario" = use_changed ]; then
  # Keep size and mtime unchanged; only ctime proves the rewrite.
  python3 -I - "$owner2" <<'PY'
import os, sys
path = sys.argv[1]
s = os.stat(path)
with open(path, 'r+b') as f:
    data = f.read()
    f.seek(0)
    f.write(data.replace(b'project2', b'project3'))
os.utime(path, ns=(s.st_atime_ns, s.st_mtime_ns))
PY
fi
for owner in "$owner1" "$owner2"; do
  rc=0
  result="$(_hc_portable_verify_owner_artifacts "$owner" "$home")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'batch hit %s\n' "${owner##*/}"
  else
    printf 'fallback %s status=%s diagnostic=%s\n' "${owner##*/}" "$rc" "$result"
  fi
done
[ -d "$home/state/locks" ] && printf 'locks present\n' || printf 'locks absent\n'
printf 'batch calls=%s scalar calls=%s\n' \
  "$(grep -c '^batch$' "$sandbox/events" || :)" \
  "$(grep -c '^scalar ' "$sandbox/events" || :)"
