#!/usr/bin/env bats
# The release-store execution-payload predicate: one normative definition and
# SIX pinned copies (seven definitions in total).
#
# `trellis_home_snapshot_payload_matches` in `scripts/lib/trellis-home.sh` is
# the normative definition and the only one exercised behaviourally, below.
# Five direct-source gates ask exactly the same question:
#
#   scripts/show-config.sh              show_config_payload_matches_release
#   scripts/upgrade.sh       (body)     upgrade_payload_matches_release
#   scripts/sync-to-template.sh (boot)  mirror_bootstrap_payload_matches
#   scripts/sync-to-template.sh (body)  mirror_payload_matches_release
#   scripts/trellis-launcher.sh (body)  launcher_snapshot_payload_matches
#
# and one library carries it for a different reason:
#
#   scripts/lib/release-store.sh        release_store_snapshot_payload_matches
#
# `sync-to-template.sh` carries two because its bootstrap and its body run in
# different processes either side of an `env -i` re-exec, and each re-decides
# the question for itself. `trellis-launcher.sh` carries one because the
# launcher is copied verbatim to a user-owned executable and, by design, never
# depends on a source checkout for its verification logic; its
# `launcher_snapshot_name_is_safe` wrapper delegates the parse to the copy so
# the launcher cannot answer the question differently from the library.
# `release-store.sh` carries one because its own file header declares that it
# depends on nothing above `semver.sh` so it can stand alone; sourcing
# `trellis-home.sh` to reach the shared function would break that. Its
# `release_store_snapshot_name_is_safe` wrapper delegates the parse to the copy
# for the same reason the launcher's does.
#
# WHY THEY ARE COPIES AND NOT CALLS. Each of the five gates runs its predicate
# at the moment it is deciding whether this copy of Trellis may execute at all —
# before any library has been sourced, and in three of the five before the
# bootstrap has even re-exec'd into the verified payload. `sync-to-template.sh`
# and `upgrade.sh` evaluate it inside a `bash -c` bootstrap string running under
# `env -i` with an absolute-path-only PATH, `show-config.sh` evaluates it
# above its own `. "$SCRIPT_DIR/lib/…"` block under the documented invariant
# "a refused copy must not run its own libraries either", and
# `trellis-launcher.sh` evaluates it while sealing the execution snapshot that
# every later library load is read from. Sourcing the shared library to reach
# the shared function would mean running library code from the very copy the
# gate has not yet cleared, which inverts each gate's trust order.
# Verified 2026-08-15: none of the five sources `trellis-home.sh` at gate time,
# and the bootstraps source nothing at all. `release-store.sh` is not a gate —
# it is a library whose stated contract is to have no dependency on the later
# trellis-home/local-registry libraries, and a call would create exactly that.
#
# So the duplication is structural, and the drift risk is handled mechanically
# instead. Two mechanical checks below:
#
#   1. THE PIN CHECKS BODY IDENTITY. It extracts each function body — every line
#      between the `NAME() {` opener and the first column-0 `}` — and requires
#      each copy to be byte-identical to the normative body once the function
#      NAME is stripped. Only the name may differ; a single changed character
#      anywhere in a body goes red. Editing the normative definition without
#      updating all six copies goes red here.
#   2. A WIRING CHECK. Body identity alone would still pass if a carrier file
#      held a pristine copy it never invoked, so each file must also contain
#      at least one CALL of its own copy — an occurrence of the name that is not
#      the definition line.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
HOME_LIB="$REPO_ROOT/scripts/lib/trellis-home.sh"

# The body of shell function $2 in file $1: everything between the opening
# `NAME() {` line and the first line that is exactly `}` at column 0.
extract_function_body() {
  awk -v name="$2" '
    $0 == name "() {" { inside = 1; next }
    inside && $0 == "}" { exit }
    inside { print }
  ' "$1"
}

# Does file $1 CALL function $2 anywhere outside its own definition line?
# Comment lines do not count — a name that survives only in prose is not wiring.
function_is_called() {
  awk -v name="$2" '
    $0 == name "() {" { next }
    /^[[:space:]]*#/ { next }
    index($0, name) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

@test "the seven snapshot-payload predicates are one definition" {
  local normative copy
  normative="$(extract_function_body "$HOME_LIB" trellis_home_snapshot_payload_matches)"
  [ -n "$normative" ] || { echo 'normative definition not found'; false; }
  # Guard the extractor itself: a body that no longer contains the delimiter
  # strip is not this predicate, and comparing two empty strings would pass.
  case "$normative" in
    *'suffix="${rest#"$version".exec.}"'*) ;;
    *) echo "extracted body is not the snapshot predicate:"; echo "$normative"; false ;;
  esac

  # SINGLE-QUOTE SAFETY. Two of the copies sit inside `bash -c '…'` bootstrap
  # strings, where a literal '' closes and reopens the quote instead of writing
  # an empty pattern — `case … in ''|…` there is a parse error, not an empty
  # match. The normative body therefore spells the empty pattern "" so that one
  # text is valid in every position a copy has to live in. Caught in flight
  # 2026-08-15: the first byte-identical copy used '' and broke the mirror
  # bootstrap at parse time.
  case "$normative" in
    *"''"*) echo "normative body contains a literal '' and cannot be embedded in a bash -c '…' bootstrap:"; echo "$normative"; false ;;
  esac

  copy="$(extract_function_body "$REPO_ROOT/scripts/show-config.sh" show_config_payload_matches_release)"
  [ "$copy" = "$normative" ] || {
    printf 'show-config.sh copy drifted\n--- normative\n%s\n--- copy\n%s\n' "$normative" "$copy" >&2
    false
  }

  copy="$(extract_function_body "$REPO_ROOT/scripts/upgrade.sh" upgrade_payload_matches_release)"
  [ "$copy" = "$normative" ] || {
    printf 'upgrade.sh copy drifted\n--- normative\n%s\n--- copy\n%s\n' "$normative" "$copy" >&2
    false
  }

  copy="$(extract_function_body "$REPO_ROOT/scripts/sync-to-template.sh" mirror_bootstrap_payload_matches)"
  [ "$copy" = "$normative" ] || {
    printf 'sync-to-template.sh bootstrap copy drifted\n--- normative\n%s\n--- copy\n%s\n' "$normative" "$copy" >&2
    false
  }

  copy="$(extract_function_body "$REPO_ROOT/scripts/sync-to-template.sh" mirror_payload_matches_release)"
  [ "$copy" = "$normative" ] || {
    printf 'sync-to-template.sh body copy drifted\n--- normative\n%s\n--- copy\n%s\n' "$normative" "$copy" >&2
    false
  }

  copy="$(extract_function_body "$REPO_ROOT/scripts/trellis-launcher.sh" launcher_snapshot_payload_matches)"
  [ "$copy" = "$normative" ] || {
    printf 'trellis-launcher.sh copy drifted\n--- normative\n%s\n--- copy\n%s\n' "$normative" "$copy" >&2
    false
  }

  copy="$(extract_function_body "$REPO_ROOT/scripts/lib/release-store.sh" release_store_snapshot_payload_matches)"
  [ "$copy" = "$normative" ] || {
    printf 'release-store.sh copy drifted\n--- normative\n%s\n--- copy\n%s\n' "$normative" "$copy" >&2
    false
  }
}

@test "every carrier file calls the copy it carries" {
  # Body identity is satisfied by a pristine copy nobody invokes. Require a call
  # site per file so a carrier cannot be silently unwired while staying green
  # above. `trellis-home.sh` is deliberately NOT in this list: it publishes the
  # normative definition for the pin to compare against and has no gate of its
  # own to run it in, so it has no call site to require.
  function_is_called "$REPO_ROOT/scripts/show-config.sh" show_config_payload_matches_release ||
    { echo 'show-config.sh never calls show_config_payload_matches_release'; false; }
  function_is_called "$REPO_ROOT/scripts/upgrade.sh" upgrade_payload_matches_release ||
    { echo 'upgrade.sh never calls upgrade_payload_matches_release'; false; }
  function_is_called "$REPO_ROOT/scripts/sync-to-template.sh" mirror_bootstrap_payload_matches ||
    { echo 'sync-to-template.sh never calls mirror_bootstrap_payload_matches'; false; }
  function_is_called "$REPO_ROOT/scripts/sync-to-template.sh" mirror_payload_matches_release ||
    { echo 'sync-to-template.sh never calls mirror_payload_matches_release'; false; }
  function_is_called "$REPO_ROOT/scripts/trellis-launcher.sh" launcher_snapshot_payload_matches ||
    { echo 'trellis-launcher.sh never calls launcher_snapshot_payload_matches'; false; }
  function_is_called "$REPO_ROOT/scripts/lib/release-store.sh" release_store_snapshot_payload_matches ||
    { echo 'release-store.sh never calls release_store_snapshot_payload_matches'; false; }

  # Guard the guard: a name no file carries must NOT report as called.
  if function_is_called "$HOME_LIB" definitely_not_a_function_name_here; then
    echo 'function_is_called reported a call for a name that does not appear'
    false
  fi
}

matches() {
  bash -c '. "$1"; trellis_home_snapshot_payload_matches "$2" "$3" "$4"' _ \
    "$HOME_LIB" "$1" "$2" "$3"
}

# Reconstruct the launcher's two snapshot functions from their extracted bodies
# and answer `launcher_snapshot_name_is_safe <releases> <name> <version>`. The
# launcher body cannot simply be sourced (it installs EXIT/HUP/INT/TERM traps
# and runs `launcher_main`), so the functions are rebuilt in isolation.
launcher_name_is_safe() {
  local defs="$BATS_TEST_TMPDIR/launcher-snapshot-fns.sh" launcher
  launcher="$REPO_ROOT/scripts/trellis-launcher.sh"
  {
    printf 'launcher_snapshot_payload_matches() {\n'
    extract_function_body "$launcher" launcher_snapshot_payload_matches
    printf '}\nlauncher_snapshot_name_is_safe() {\n'
    extract_function_body "$launcher" launcher_snapshot_name_is_safe
    printf '}\n'
  } > "$defs"
  bash -c 'set -u; . "$1"; launcher_snapshot_name_is_safe "$2" "$3" "$4"' _ \
    "$defs" "$1" "$2" "$3"
}

@test "the launcher name gate binds the snapshot name to its own release" {
  run launcher_name_is_safe /h/releases .tmp.1.2.3.exec.Ab3xY9 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # THE GREEDY HOLE. `.tmp.1.2.3.exec.9.exec.Ab3xY9` is release 1.2.3.exec.9's
  # own snapshot. A `${name##*.exec.}` parse strips to `Ab3xY9` and calls it
  # safe under version 1.2.3; the delimiter-exact parse refuses it.
  run launcher_name_is_safe /h/releases .tmp.1.2.3.exec.9.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a foreign release snapshot name'; false; }
  run launcher_name_is_safe /h/releases .tmp.1.2.3.exec.9.exec.Ab3xY9 1.2.3.exec.9
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # A plain installed release directory is not an execution snapshot name.
  run launcher_name_is_safe /h/releases 1.2.3 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted an installed release dir as a snapshot'; false; }

  # Missing marker, empty and non-alphanumeric suffixes, path separators.
  run launcher_name_is_safe /h/releases 1.2.3.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a snapshot name without .tmp.'; false; }
  run launcher_name_is_safe /h/releases .tmp.1.2.3.exec. 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted an empty suffix'; false; }
  run launcher_name_is_safe /h/releases .tmp.1.2.3.exec.a-b 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a non-alphanumeric suffix'; false; }
  run launcher_name_is_safe /h/releases .tmp.1.2.3.exec.a/b 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a suffix carrying a path separator'; false; }

  # Another release's snapshot, and the version is not a glob.
  run launcher_name_is_safe /h/releases .tmp.9.9.9.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted another release snapshot'; false; }
  run launcher_name_is_safe /h/releases .tmp.1x2x3.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'treated the version as a glob'; false; }
}

# Same reconstruction for the release-store twin. `release-store.sh` CAN be
# sourced (it is a library and installs no traps), but the two functions are
# rebuilt from their extracted bodies anyway so this test and the pin above are
# reading exactly the same text — sourcing would let the pin go red while this
# stayed green off some other definition.
release_store_name_is_safe() {
  local defs="$BATS_TEST_TMPDIR/release-store-snapshot-fns.sh" lib
  lib="$REPO_ROOT/scripts/lib/release-store.sh"
  {
    printf 'release_store_snapshot_payload_matches() {\n'
    extract_function_body "$lib" release_store_snapshot_payload_matches
    printf '}\nrelease_store_snapshot_name_is_safe() {\n'
    extract_function_body "$lib" release_store_snapshot_name_is_safe
    printf '}\n'
  } > "$defs"
  bash -c 'set -u; . "$1"; release_store_snapshot_name_is_safe "$2" "$3" "$4"' _ \
    "$defs" "$1" "$2" "$3"
}

@test "the release-store name gate binds the snapshot name to its own release" {
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec.Ab3xY9 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # THE GREEDY HOLE, in the seventh definition. `.tmp.1.2.3.exec.9.exec.Ab3xY9`
  # is release 1.2.3.exec.9's own snapshot; a `${name##*.exec.}` parse strips it
  # to `Ab3xY9` and calls it safe under version 1.2.3. This gate guards snapshot
  # creation, cleanup, and verified attachment-bundle emission, so accepting a
  # foreign release's snapshot there removes and emits from the wrong release.
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec.9.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a foreign release snapshot name'; false; }
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec.9.exec.Ab3xY9 1.2.3.exec.9
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # A plain installed release directory is not an execution snapshot name.
  run release_store_name_is_safe /h/releases 1.2.3 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted an installed release dir as a snapshot'; false; }

  # Missing marker, empty and non-alphanumeric suffixes, path separators.
  run release_store_name_is_safe /h/releases 1.2.3.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a snapshot name without .tmp.'; false; }
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec. 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted an empty suffix'; false; }
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec.a-b 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a non-alphanumeric suffix'; false; }
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec.a/b 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a suffix carrying a path separator'; false; }

  # Another release's snapshot, and the version is not a glob.
  run release_store_name_is_safe /h/releases .tmp.9.9.9.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted another release snapshot'; false; }
  run release_store_name_is_safe /h/releases .tmp.1x2x3.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'treated the version as a glob'; false; }

  # An unbound version cannot open the gate: callers thread the release through,
  # and a missing one must refuse rather than fall back to a name-only parse.
  run release_store_name_is_safe /h/releases .tmp.1.2.3.exec.Ab3xY9 ''
  [ "$status" -ne 0 ] || { echo 'accepted a snapshot name with no version bound'; false; }
}

@test "the installed release payload and its own execution snapshot are accepted" {
  run matches /h /h/releases/1.2.3/payload 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run matches /h /h/releases/.tmp.1.2.3.exec.Ab3xY9/payload 1.2.3
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a snapshot of a dot-bearing release is not accepted under a prefix version" {
  # THE HOLE THIS SHAPE CLOSES. Release '1.2.3.exec.9' is a legal version, and
  # its own execution snapshot is '.tmp.1.2.3.exec.9.exec.SUFFIX'. That name
  # shares the entire '.tmp.1.2.3.exec.' prefix with a snapshot of release
  # 1.2.3, and a greedy '##*.exec.' strip leaves the alphanumeric SUFFIX — so a
  # prefix-glob implementation accepts it under the 1.2.3 attestation.
  run matches /h /h/releases/.tmp.1.2.3.exec.9.exec.Ab3xY9/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a foreign release snapshot under a prefix version'; false; }

  # It is of course accepted under its own version.
  run matches /h /h/releases/.tmp.1.2.3.exec.9.exec.Ab3xY9/payload 1.2.3.exec.9
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "everything else in and around the release store is refused" {
  # Wrong home.
  run matches /h /other/releases/1.2.3/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a payload under another home'; false; }

  # Another release's installed payload.
  run matches /h /h/releases/9.9.9/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted another release'; false; }

  # Another release's snapshot.
  run matches /h /h/releases/.tmp.9.9.9.exec.Ab3xY9/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted another release snapshot'; false; }

  # Missing the .tmp. marker.
  run matches /h /h/releases/1.2.3.exec.Ab3xY9/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a snapshot name without .tmp.'; false; }

  # Empty and non-alphanumeric suffixes.
  run matches /h /h/releases/.tmp.1.2.3.exec./payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted an empty suffix'; false; }
  run matches /h /h/releases/.tmp.1.2.3.exec.a-b/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a non-alphanumeric suffix'; false; }
  run matches /h /h/releases/.tmp.1.2.3.exec.a/b/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a suffix carrying a path separator'; false; }

  # Nested one level deeper than the store.
  run matches /h /h/releases/nested/.tmp.1.2.3.exec.Ab3xY9/payload 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a snapshot below the release store'; false; }

  # Not a payload directory at all.
  run matches /h /h/releases/.tmp.1.2.3.exec.Ab3xY9 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a snapshot root without its payload'; false; }
  run matches /h /h/releases/.tmp.1.2.3.exec.Ab3xY9/payload/scripts 1.2.3
  [ "$status" -ne 0 ] || { echo 'accepted a path below the payload'; false; }

  # The version is not a glob: a metacharacter must stay literal.
  run matches /h '/h/releases/.tmp.1x2x3.exec.Ab3xY9/payload' '1.2.3'
  [ "$status" -ne 0 ] || { echo 'treated the version as a glob'; false; }
}
