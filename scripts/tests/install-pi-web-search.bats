#!/usr/bin/env bats
# Spec 056 R14: the pi web-search installer. Every case runs in a temp HOME;
# nothing here touches the real ~/.pi.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-pi-web-search.sh"
BLOCK_LIST="$REPO_ROOT/core-rules/pi/extensions/trellis-web-search.blocked.sha256"

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/install-pi-web-search.XXXXXX")"
  H="$SANDBOX/home"
  EXT="$H/.pi/agent/extensions"
  mkdir -p "$EXT"
  printf '// live build\n' >"$EXT/trellis-web-search.ts"
  printf '// good build\n' >"$SANDBOX/good.ts"
  printf '// blocked build\n' >"$SANDBOX/blocked.ts"
  printf '# test block list\n%s  blocked fixture\n' "$(shasum -a 256 "$SANDBOX/blocked.ts" | awk '{print $1}')" >"$SANDBOX/blocked.sha256"
}

teardown() {
  rm -rf "$SANDBOX"
}

@test "R14: the block list names the pre-056 build" {
  grep -q '^a1fbe3c94fd5e84df0e29c857668deb76c410d1769f5a96af9672f276342bb93 ' "$BLOCK_LIST"
}

@test "R14: a blocked source is refused and the live file is untouched" {
  before="$(shasum -a 256 "$EXT/trellis-web-search.ts")"
  TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/blocked.ts"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refused"* ]]
  [ "$(shasum -a 256 "$EXT/trellis-web-search.ts")" = "$before" ]
  [ ! -e "$H/.pi/agent/backups" ]
}

@test "R14: the real pre-056 build is refused by the shipped block list" {
  git -C "$REPO_ROOT" cat-file -e 60c62b7e:core-rules/pi/extensions/trellis-web-search.ts 2>/dev/null ||
    skip "the pre-056 blob is not in this clone's history"
  git -C "$REPO_ROOT" show 60c62b7e:core-rules/pi/extensions/trellis-web-search.ts >"$SANDBOX/pre-056.ts"
  run "$INSTALLER" --home "$H" install "$SANDBOX/pre-056.ts"
  [ "$status" -eq 3 ]
  [ "$(cat "$EXT/trellis-web-search.ts")" = "// live build" ]
}

@test "R14: a good source installs 0644, backs up the old file outside extensions/, and verifies" {
  old_sha="$(shasum -a 256 "$EXT/trellis-web-search.ts" | awk '{print $1}')"
  TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -eq 0 ]
  cmp "$SANDBOX/good.ts" "$EXT/trellis-web-search.ts"
  [ "$(stat -f '%Lp' "$EXT/trellis-web-search.ts")" = "644" ]
  backups=("$H"/.pi/agent/backups/extensions/trellis-web-search.ts.*)
  [ "${#backups[@]}" -eq 1 ]
  [ "$(shasum -a 256 "${backups[0]}" | awk '{print $1}')" = "$old_sha" ]
  # Nothing but the new file is left where pi loads extensions from.
  [ "$(ls -A "$EXT")" = "trellis-web-search.ts" ]
  [[ "$output" == *"before: $old_sha"* ]]
  [[ "$output" == *"after: $(shasum -a 256 "$SANDBOX/good.ts" | awk '{print $1}')"* ]]
}

@test "R14: two installs in the same second keep both backups" {
  TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -eq 0 ]
  TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -eq 0 ]
  backups=("$H"/.pi/agent/backups/extensions/trellis-web-search.ts.*)
  [ "${#backups[@]}" -eq 2 ]
}

@test "R14: remove leaves extensions/ without the file and keeps a backup" {
  run "$INSTALLER" --home "$H" remove
  [ "$status" -eq 0 ]
  [ ! -e "$EXT/trellis-web-search.ts" ]
  [ -z "$(ls -A "$EXT")" ]
  backups=("$H"/.pi/agent/backups/extensions/trellis-web-search.ts.*)
  [ "${#backups[@]}" -eq 1 ]
  [ "$(cat "${backups[0]}")" = "// live build" ]
}

@test "R14: usage errors exit 2 and change nothing" {
  run "$INSTALLER" --home "$H"
  [ "$status" -eq 2 ]
  run "$INSTALLER" --home "$H" upgrade
  [ "$status" -eq 2 ]
  run "$INSTALLER" --home "$H" install "$SANDBOX/missing.ts"
  [ "$status" -eq 2 ]
  [ "$(cat "$EXT/trellis-web-search.ts")" = "// live build" ]
}

# --- T11 review fixes -------------------------------------------------------

# Puts shims first on PATH. Each shim runs the real tool, then performs one
# test-controlled side effect, which lets a test land an action exactly
# between two steps of the installer.
make_shims() {
  SHIMS="$SANDBOX/shims"
  mkdir -p "$SHIMS"
  cat >"$SHIMS/shasum" <<'EOF'
#!/bin/bash
/usr/bin/shasum "$@"
rc=$?
# Swap the source the first time anything is hashed: after the vetting hash.
if [ -n "${SWAP_SRC:-}" ] && [ ! -e "$SWAP_SRC.swapped" ]; then
  /bin/cp "$SWAP_WITH" "$SWAP_SRC"; : >"$SWAP_SRC.swapped"
fi
exit $rc
EOF
  cat >"$SHIMS/install" <<'EOF'
#!/bin/bash
# Swap extensions/ for a symlink to somewhere else just before the write.
if [ -n "${SWAP_EXT:-}" ] && [ ! -e "$SWAP_EXT.swapped" ]; then
  /bin/mv "$SWAP_EXT" "$SWAP_EXT.moved" && /bin/ln -s "$SWAP_EXT_TO" "$SWAP_EXT"; : >"$SWAP_EXT.swapped"
fi
/usr/bin/install "$@" || exit $?
# Corrupt the installed copy, as a failing disk or a racing writer would.
if [ -n "${CORRUPT_INSTALL:-}" ]; then for last; do :; done; printf 'x' >>"$last"; fi
EOF
  cat >"$SHIMS/mkdir" <<'EOF'
#!/bin/bash
/bin/mkdir "$@" || exit $?
for last; do :; done
# Plant a symlink at the destination right after extensions/ is created.
if [ -n "${RACE_LINK:-}" ] && [ "$last" = "$RACE_DIR" ] && [ ! -e "$RACE_LINK.planted" ]; then
  /bin/ln -s "$RACE_TARGET" "$RACE_LINK"; : >"$RACE_LINK.planted"
fi
EOF
  cat >"$SHIMS/date" <<'EOF'
#!/bin/bash
# The backup stamp is computed after the backups directory was vetted and just
# before the move: swap that directory for a symlink into extensions/ here.
if [ -n "${SWAP_BACKUPS:-}" ] && [ ! -e "$SWAP_BACKUPS.swapped" ]; then
  /bin/mv "$SWAP_BACKUPS" "$SWAP_BACKUPS.moved" && /bin/ln -s "$SWAP_BACKUPS_TO" "$SWAP_BACKUPS"; : >"$SWAP_BACKUPS.swapped"
fi
exec /bin/date "$@"
EOF
  cat >"$SHIMS/mv" <<'EOF'
#!/bin/bash
# Swap extensions/ for a symlink to a decoy directory at the instant of the move.
if [ -n "${SWAP_EXT_AT_MV:-}" ] && [ ! -e "$SWAP_EXT_AT_MV.swapped" ]; then
  /bin/mv "$SWAP_EXT_AT_MV" "$SWAP_EXT_AT_MV.moved" && /bin/ln -s "$DECOY_DIR" "$SWAP_EXT_AT_MV"; : >"$SWAP_EXT_AT_MV.swapped"
fi
exec /bin/mv "$@"
EOF
  chmod +x "$SHIMS"/*
}

@test "R14 review: a source swapped after vetting is never installed (snapshot)" {
  make_shims
  PATH="$SHIMS:$PATH" SWAP_SRC="$SANDBOX/good.ts" SWAP_WITH="$SANDBOX/blocked.ts" TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" \
    run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ -e "$SANDBOX/good.ts.swapped" ]                           # the swap really happened
  [ "$(cat "$SANDBOX/good.ts")" = "// blocked build" ]
  [ "$status" -eq 0 ]
  [ "$(cat "$EXT/trellis-web-search.ts")" = "// good build" ]  # the vetted bytes, not the swapped ones
}

@test "R14 review: an installed file whose digest differs from the vetted one is removed" {
  make_shims
  PATH="$SHIMS:$PATH" CORRUPT_INSTALL=1 TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" \
    run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match vetted digest"* ]]
  [ ! -e "$EXT/trellis-web-search.ts" ]
}

@test "R14 review: a dangling live symlink is moved aside without hashing its target" {
  rm "$EXT/trellis-web-search.ts"
  ln -s "$SANDBOX/nowhere.ts" "$EXT/trellis-web-search.ts"
  run "$INSTALLER" --home "$H" remove
  [ "$status" -eq 0 ]
  # The receipt describes the link; nothing tried to read its missing target.
  [[ "$output" == *"before: symlink -> $SANDBOX/nowhere.ts"* ]]
  [[ "$output" != *"No such file"* ]]
  [ ! -e "$EXT/trellis-web-search.ts" ] && [ ! -L "$EXT/trellis-web-search.ts" ]
  backups=("$H"/.pi/agent/backups/extensions/trellis-web-search.ts.*)
  [ -L "${backups[0]}" ]
  ln -s "$SANDBOX/nowhere.ts" "$EXT/trellis-web-search.ts"
  TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -eq 0 ]
  [ "$(cat "$EXT/trellis-web-search.ts")" = "// good build" ]
}

@test "R14 review: a symlinked extensions directory is refused and nothing is written through it" {
  mkdir -p "$SANDBOX/elsewhere"
  rm -rf "$EXT"
  ln -s "$SANDBOX/elsewhere" "$EXT"
  TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -eq 4 ]
  [ -z "$(ls -A "$SANDBOX/elsewhere")" ]
  run "$INSTALLER" --home "$H" remove
  [ "$status" -eq 4 ]
}

@test "R14 review: a backups directory that is a symlink into extensions/ is refused" {
  ln -s "$EXT" "$H/.pi/agent/backups"
  run "$INSTALLER" --home "$H" remove
  [ "$status" -eq 4 ]
  [ "$(cat "$EXT/trellis-web-search.ts")" = "// live build" ]
  [ "$(ls -A "$EXT")" = "trellis-web-search.ts" ]
}

@test "R14 review: a symlink planted at the destination after mkdir is refused or made harmless" {
  make_shims
  rm -rf "$EXT"
  mkdir -p "$SANDBOX/outside"
  PATH="$SHIMS:$PATH" RACE_DIR="$EXT" RACE_LINK="$EXT/trellis-web-search.ts" RACE_TARGET="$SANDBOX/outside/target.ts" \
    TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ -e "$EXT/trellis-web-search.ts.planted" ]                  # the race really happened
  [ ! -e "$SANDBOX/outside/target.ts" ]                         # nothing written through the link
  if [ "$status" -ne 4 ]; then
    [ "$status" -eq 0 ]
    [ ! -L "$EXT/trellis-web-search.ts" ]
    [ "$(cat "$EXT/trellis-web-search.ts")" = "// good build" ]
  fi
}

@test "R14 confirm: backups swapped for a symlink into extensions/ after vetting is refused or harmless" {
  make_shims
  mkdir -p "$H/.pi/agent/backups/extensions"
  PATH="$SHIMS:$PATH" SWAP_BACKUPS="$H/.pi/agent/backups/extensions" SWAP_BACKUPS_TO="$EXT" \
    TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ -e "$H/.pi/agent/backups/extensions.swapped" ]             # the swap really happened
  # No backup ever lands where pi loads extensions from.
  [ -z "$(find "$EXT/" -name 'trellis-web-search.ts.*' -print)" ]
  [ "$status" -eq 4 ] || [ "$status" -eq 0 ]
}

@test "R14 confirm: extensions/ swapped at the instant of the backup move does not move the decoy" {
  make_shims
  mkdir -p "$SANDBOX/decoy"
  printf '// decoy\n' >"$SANDBOX/decoy/trellis-web-search.ts"
  PATH="$SHIMS:$PATH" SWAP_EXT_AT_MV="$EXT" DECOY_DIR="$SANDBOX/decoy" \
    TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ -e "$EXT.swapped" ]                                                  # the swap really happened
  [ "$(cat "$SANDBOX/decoy/trellis-web-search.ts")" = "// decoy" ]       # the move did not act on the decoy
  backups=0
  for backup in "$H"/.pi/agent/backups/extensions/trellis-web-search.ts.*; do
    [ -e "$backup" ] || continue
    backups=$((backups + 1))
    [ "$(cat "$backup")" = "// live build" ]                              # only the real live file was moved
  done
  if [ "$status" -eq 0 ]; then
    [ "$backups" -ge 1 ]                                                  # a completed install backed up the live file
  else
    [ "$status" -eq 4 ]
    [ "$backups" -ge 1 ] || [ "$(cat "$EXT.swapped/trellis-web-search.ts")" = "// live build" ]  # refused: live file not lost
  fi
}

@test "R14 confirm: extensions/ swapped for a symlink just before the write never writes through it" {
  make_shims
  mkdir -p "$SANDBOX/outside"
  PATH="$SHIMS:$PATH" SWAP_EXT="$EXT" SWAP_EXT_TO="$SANDBOX/outside" \
    TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ -e "$EXT.swapped" ]                                          # the swap really happened
  [ -z "$(ls -A "$SANDBOX/outside")" ]                           # nothing written outside
  [ "$status" -eq 4 ] || [ "$status" -eq 0 ]
}

@test "R14 review: sha256sum is used when shasum is absent" {
  PATHDIR="$SANDBOX/path"
  mkdir -p "$PATHDIR"
  for tool in bash env dirname awk grep mktemp chmod cp install mv mkdir date rm readlink sha256sum; do
    ln -s "$(PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin command -v "$tool")" "$PATHDIR/$tool"
  done
  PATH="$PATHDIR" TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/good.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after: $(shasum -a 256 "$SANDBOX/good.ts" | awk '{print $1}')"* ]]
  PATH="$PATHDIR" TWS_BLOCKED_LIST="$SANDBOX/blocked.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/blocked.ts"
  [ "$status" -eq 3 ]
}

@test "R14 review: the block list is compared case-insensitively" {
  printf '%s  upper-case entry\n' "$(shasum -a 256 "$SANDBOX/blocked.ts" | awk '{print toupper($1)}')" >"$SANDBOX/upper.sha256"
  TWS_BLOCKED_LIST="$SANDBOX/upper.sha256" run "$INSTALLER" --home "$H" install "$SANDBOX/blocked.ts"
  [ "$status" -eq 3 ]
  [ "$(cat "$EXT/trellis-web-search.ts")" = "// live build" ]
}
