#!/usr/bin/env bats
# A successful relink must not erase unrelated row errors.
load doctor-fix-common
umask 077

# The legacy helper uses bare mktemp -d, which ignores TMPDIR on macOS.
mktemp() {
  if [ "$#" -eq 1 ] && [ "$1" = -d ]; then
    command mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/doctor-relink.XXXXXX"
  else
    command mktemp "$@"
  fi
}

@test "doctor relink preserves failed attachment checks but permits a clean repair" {
  local status_dir status_file attachment owner_sha
  hooks_fix_attach null

  # Control: the ordinary missing-runtime repair remains successful.
  mv "$PORTABLE_PROJECT/.trellis/runtime" "$SANDBOX/runtime-first"
  run_portable_doctor_fix --fix
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"safe repair delegated through trellis relink and passed strict post-repair verification"* ]] || { echo "$output"; false; }
  [ -L "$PORTABLE_PROJECT/.trellis/runtime" ]

  # A failed post-attach check is independent of the runtime link and remains
  # reported as an error even if the relink itself verifies.
  status_dir="$PORTABLE_HOME/state/attachment-status/$PORTABLE_CHECKOUT_ID"
  status_file="$status_dir/$PORTABLE_WORKTREE_ID.json"
  mkdir -p "$status_dir"
  chmod 700 "$PORTABLE_HOME/state/attachment-status" "$status_dir"
  attachment="$(jq -r '.attachment_id' "$HF_OWNER")"
  owner_sha="$(sha_of "$HF_OWNER")"
  jq -n --arg checkout "$PORTABLE_CHECKOUT_ID" --arg worktree "$PORTABLE_WORKTREE_ID" \
    --arg attachment "$attachment" --arg sha "$owner_sha" --argjson at "$(date +%s)" \
    --arg release "$(jq -r '.release' "$HF_OWNER")" --arg root "$(jq -r '.worktree_root' "$HF_OWNER")" \
    '{schema_version:2,state:"failed",checkout_id:$checkout,worktree_id:$worktree,
      attachment_id:$attachment,owner_sha256:$sha,release:$release,worktree_root:$root,updated_at:$at,checks:[],
      failure:{check:"exclude",code:3,remedy:"restore the recorded exclude block"}}' > "$status_file"
  chmod 600 "$status_file"
  mv "$PORTABLE_PROJECT/.trellis/runtime" "$SANDBOX/runtime-second"

  run_portable_doctor_fix --fix
  [[ "$output" == *"attachment checks FAILED at exclude"* ]] || { echo "$output"; false; }
  [[ "$output" == *"safe repair delegated through trellis relink and passed strict post-repair verification"* ]] || { echo "$output"; false; }
  [ -L "$PORTABLE_PROJECT/.trellis/runtime" ]
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" != *"0 error(s)"* ]] || { echo "$output"; false; }
}
