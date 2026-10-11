#!/usr/bin/env bash
# Bats run supplies status/output; fixture out-parameters are read by the suite.
# shellcheck disable=SC2034,SC2154
# Actual released surfaces, not a hand-built approximation of the six leaves.
# Build, seal and historically adopt once per file. Each case receives an
# independent physical copy; every fixed adoption/sync/add still runs for real.
group_plan_build_release_repo() {
  local version="$1" repo="$2" ref="v$1" file
  [ "$version" != 1.3.10 ] || ref=HEAD
  mkdir -p "$repo" || return 1
  git -C "$REPO_ROOT" archive "$ref" core-rules scripts | tar -x -C "$repo" || return 1
  if [ "$version" = 1.3.10 ]; then
    for file in release.sh attach-project.sh seed-inheritance-symlinks.sh; do
      cp "$REPO_ROOT/scripts/$file" "$repo/scripts/$file" || return 1
    done
    printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  fi
  payload_fixture_git -C "$repo" init -q || return 1
  payload_fixture_git -C "$repo" add -A || return 1
  payload_fixture_git -C "$repo" commit -qm "historical surface $version" || return 1
  payload_fixture_git -C "$repo" tag -a "v$version" -m "$version" || return 1
}

group_plan_build_release_cache() (
  local cache="$1" version repo
  mkdir -p "$cache/trellis-home" "$cache/operator-home" || return 1
  export HOME="$cache/operator-home"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  for version in 1.3.6 1.3.7 1.3.8 1.3.9 1.3.10; do
    repo="$cache/historical-$version"
    group_plan_build_release_repo "$version" "$repo" || return 1
    # The same library seam as the suite bootstrap; no fixture hook or machine
    # binding is embedded in these releases. Normal adopts reverify each copy.
    TRELLIS_HOME="$cache/trellis-home" bash -c '. "$1"; release_store_install "$2" "$3" "" >/dev/null' \
      group-plan-cache "$RELEASE_STORE_LIB" "$version" "$repo" || return 1
  done
)

group_plan_release() {
  local version="$1"
  [ -d "$GROUP_PLAN_RELEASE_CACHE/trellis-home/releases/$version" ] || return 1
  mkdir -p "$TRELLIS_HOME_FIX/releases" || return 1
  chmod 700 "$TRELLIS_HOME_FIX/releases" || return 1
  cp -Rp "$GROUP_PLAN_RELEASE_CACHE/trellis-home/releases/$version" "$TRELLIS_HOME_FIX/releases/" || return 1
  RELEASE_DIR="$TRELLIS_HOME_FIX/releases/$version"
}

group_plan_setup_group() {
  # setup restored a physical copy of the real historical machine to the SAME
  # pathname. Even non-history controls therefore start after all three adopts.
  GROUP_PLAN_MAIN="$SANDBOX/adopted group"
  GROUP_PLAN_SIBLING="$SANDBOX/sibling"
  GROUP_PLAN_NEW="$SANDBOX/new worktree"
  GROUP_PLAN_EXCLUDE="$GROUP_PLAN_MAIN/.git/info/exclude"
  GROUP_PLAN_OWNER="$(owner_for_root "$GROUP_PLAN_MAIN")" || return 1
  cmp "$SANDBOX/stale.exclude" "$GROUP_PLAN_EXCLUDE" || return 1
  jq -e '.release == "1.3.9"' "$GROUP_PLAN_OWNER"
}

group_plan_build_group() {
  local version old="$TRELLIS_HOME_FIX/releases/1.3.9/payload" versions='1.3.9'
  [ "${1:-}" != history ] || versions='1.3.7 1.3.8 1.3.9'
  group_plan_release 1.3.6 || return 1
  for version in $versions; do group_plan_release "$version" || return 1; done
  group_plan_release 1.3.10 || return 1
  GROUP_PLAN_MAIN="$SANDBOX/adopted group"
  GROUP_PLAN_SIBLING="$SANDBOX/sibling"
  GROUP_PLAN_NEW="$SANDBOX/new worktree"
  make_portable_project "$GROUP_PLAN_MAIN" group-plan || return 1
  mkdir -p "$GROUP_PLAN_MAIN/.claude/primers" "$GROUP_PLAN_MAIN/.codex/primers" || return 1
  printf '# Authored Claude primer\n' > "$GROUP_PLAN_MAIN/.claude/primers/INDEX.md" || return 1
  printf '# Authored Codex primer\n' > "$GROUP_PLAN_MAIN/.codex/primers/INDEX.md" || return 1
  payload_fixture_git -C "$GROUP_PLAN_MAIN" add .claude/primers .codex/primers || return 1
  payload_fixture_git -C "$GROUP_PLAN_MAIN" commit -qm primers || return 1
  group_plan_attach "$GROUP_PLAN_MAIN" || return 1
  payload_fixture_git -C "$GROUP_PLAN_MAIN" worktree add --detach "$GROUP_PLAN_SIBLING" || return 1
  group_plan_attach "$GROUP_PLAN_SIBLING" || return 1
  GROUP_PLAN_EXCLUDE="$GROUP_PLAN_MAIN/.git/info/exclude"
  printf '# external tail without newline' >> "$GROUP_PLAN_EXCLUDE" || return 1
  cp "$GROUP_PLAN_EXCLUDE" "$SANDBOX/stale.exclude" || return 1
  GROUP_PLAN_OWNER="$(owner_for_root "$GROUP_PLAN_MAIN")" || return 1
  for version in $versions; do
    run env TRELLIS_HOME="$TRELLIS_HOME_FIX" TRELLIS_VERIFIED_PAYLOAD="$old" \
      TRELLIS_VERIFIED_RELEASE_VERSION=1.3.9 bash "$old/scripts/release.sh" adopt "$version" --project group-plan
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
  cmp "$SANDBOX/stale.exclude" "$GROUP_PLAN_EXCLUDE" || return 1
  jq -e '.release == "1.3.9"' "$GROUP_PLAN_OWNER"
}

group_plan_attach() {
  # The historical attach runs that release's own attach code, as the seeder
  # does: a payload's contextual template is only valid to its own renderer.
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$TRELLIS_HOME_FIX/releases/1.3.6/payload/scripts/attach-project.sh" \
    attach --home "$TRELLIS_HOME_FIX" \
    --fleet personal --release 1.3.6 --harness claude --harness codex --harness pi "$1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

group_plan_adopt() {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash "$RELEASE" adopt 1.3.10 --project group-plan
}

group_plan_state() {
  shasum -a 256 "$TRELLIS_HOME_FIX/registry.json" "$GROUP_PLAN_EXCLUDE" \
    "$TRELLIS_HOME_FIX"/state/attachments/*/*.json
}

group_plan_assert_no_journal() {
  [ -z "$(find "$TRELLIS_HOME_FIX/state/attachment-journals" -type f -name '*.json' -print)" ]
  [ -z "$(find "$TRELLIS_HOME_FIX/state/release-adoptions" -mindepth 1 -print 2>/dev/null)" ]
}

group_plan_sync() {
  run env TRELLIS_HOME="$TRELLIS_HOME_FIX" bash -c 'exec bash "$1" sync "$2" 2>"$3"' _ \
    "$REPO_ROOT/scripts/worktree.sh" "$1" "$SANDBOX/sync.err"
}

group_plan_case_lease__start_time() {
  local pid raw state
  pid="$1"
  case "$pid" in
    ""|*[!0-9]*) return 1 ;;
  esac
  state="$(LC_ALL=C ps -o state= -p "$pid" 2>/dev/null)" || return 1
  [ -n "$state" ] || return 1
  case "$state" in
    *Z*) return 1 ;;
  esac
  raw="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  raw="$(printf '%s\n' "$raw" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}

group_plan_case_lease__is_number() {
  case "$1" in
    ""|*[!0-9.]*|.*|*.) return 1 ;;
    *.*.*) return 1 ;;
    *[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

group_plan_case_lease__poll_count() {
  local seconds poll count
  seconds="$1"
  poll="$2"
  group_plan_case_lease__is_number "$seconds" || return 1
  group_plan_case_lease__is_number "$poll" || return 1
  count="$(awk -v s="$seconds" -v p="$poll" 'BEGIN { if ((p + 0) <= 0) exit 1; c = (s + 0) / (p + 0); if (c < 1) c = 1; printf "%d", c + 0.5 }' 2>/dev/null)" || return 1
  case "$count" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [ "$count" -ge 1 ] 2>/dev/null || return 1
  printf '%s\n' "$count"
}

# A dead holder proves only that the holder the waiter READ is gone. Under
# load it may have released and exited between that read and the liveness
# probe; the lease is then free or re-taken, a normal handoff between two
# concurrent holders (P1g, R39). It is stale only while that same identity is
# still published.
group_plan_case_lease__still_held_by() {
  local pid start extra
  [ -f "$1" ] || return 1
  pid=""; start=""; extra=""
  { IFS= read -r pid; IFS= read -r start; IFS= read -r extra; } < "$1" 2>/dev/null || true
  [ "$pid" = "$2" ] && [ "$start" = "$3" ] && [ -z "$extra" ]
}

# R10 group-plan case lease: holder-liveness wait for the one fixed working
# pathname ($GROUP_PLAN_RELEASE_CACHE/machine, via case.lock).
# The fixed path must stay: the baseline copy keeps owner IDs, Git worktree
# bindings, render hashes, hooks and snapshots stable, so cases cannot use
# private temp dirs. The old try-cap (9000 x 0.1 s) turned a slow holder into
# a setup failure for the waiter. This wait has NO try cap while the holder
# is provably alive; it fails fast only when the lease is provably stale.
# We never auto-break (rm) someone else's lock: breaking it could let two
# cases share the fixed path at once, corrupting the machine copy and
# producing flaky adopt/sync failures. Failing visibly keeps the ownership
# violation obvious instead of hiding it as cross-case interference.
# Returns: 0 acquired, 1 stale/malformed, 2 test-only observe window elapsed.
# Test seams (all inert unless set; release-store.bats never sets them):
#   GROUP_PLAN_LEASE_POLL              poll sleep, default 0.1
#   GROUP_PLAN_LEASE_GRACE              missing/malformed grace, default 5
#   GROUP_PLAN_LEASE_PROGRESS_INTERVAL  heartbeat every N whole wall-clock s, default 60
#                                       (sub-second: every poll). Wall clock, not
#                                       poll count, so a slow poll under load still
#                                       beats well inside 5 min (P1g, R39 Q2).
#   GROUP_PLAN_LEASE_OBSERVE_MAX        bounded wait then return 2, unset = wait forever
group_plan_case_lease_acquire() {
  local lock_dir identity tmp_file
  local poll grace progress_every observe_max
  local grace_polls observe_polls progress_secs started_at beat_at
  local missing_polls elapsed_polls
  local holder_pid holder_start holder_extra live_start self_start
  local elapsed_txt
  if [ -z "${GROUP_PLAN_RELEASE_CACHE:-}" ]; then
    printf 'group-plan case lease: GROUP_PLAN_RELEASE_CACHE is not set\n' >&2
    return 1
  fi
  if [ ! -d "$GROUP_PLAN_RELEASE_CACHE" ]; then
    printf 'group-plan case lease: GROUP_PLAN_RELEASE_CACHE does not exist: %s\n' "$GROUP_PLAN_RELEASE_CACHE" >&2
    return 1
  fi
  lock_dir="$GROUP_PLAN_RELEASE_CACHE/case.lock"
  identity="$lock_dir/holder"
  GROUP_PLAN_CASE_LOCK_HELD=false
  GROUP_PLAN_CASE_LEASE_PID=""
  GROUP_PLAN_CASE_LEASE_START=""
  poll="${GROUP_PLAN_LEASE_POLL:-0.1}"
  grace="${GROUP_PLAN_LEASE_GRACE:-5}"
  progress_every="${GROUP_PLAN_LEASE_PROGRESS_INTERVAL:-60}"
  observe_max="${GROUP_PLAN_LEASE_OBSERVE_MAX:-}"
  group_plan_case_lease__is_number "$poll" || poll="0.1"
  group_plan_case_lease__is_number "$grace" || grace="5"
  group_plan_case_lease__is_number "$progress_every" || progress_every="60"
  grace_polls="$(group_plan_case_lease__poll_count "$grace" "$poll")" || grace_polls="50"
  progress_secs="${progress_every%%.*}"
  observe_polls=""
  if [ -n "$observe_max" ]; then
    observe_polls="$(group_plan_case_lease__poll_count "$observe_max" "$poll")" || observe_polls=""
  fi
  missing_polls=0
  elapsed_polls=0
  started_at=$SECONDS
  beat_at=$SECONDS
  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      self_start="$(group_plan_case_lease__start_time "$$")" || {
        printf 'group-plan case lease: cannot read own start time for pid %s\n' "$$" >&2
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
      }
      tmp_file="$lock_dir/.holder.$$.$RANDOM.tmp"
      if ! printf '%s\n%s\n' "$$" "$self_start" > "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        printf 'group-plan case lease: cannot write identity at %s\n' "$identity" >&2
        return 1
      fi
      if ! mv "$tmp_file" "$identity"; then
        rm -f "$tmp_file" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        printf 'group-plan case lease: cannot publish identity at %s\n' "$identity" >&2
        return 1
      fi
      GROUP_PLAN_CASE_LEASE_PID="$$"
      GROUP_PLAN_CASE_LEASE_START="$self_start"
      GROUP_PLAN_CASE_LOCK_HELD=true
      return 0
    fi
    if [ ! -d "$lock_dir" ]; then
      continue
    fi
    if [ ! -f "$identity" ]; then
      missing_polls=$((missing_polls + 1))
      if [ "$missing_polls" -ge "$grace_polls" ]; then
        printf 'group-plan case lease: malformed lease at %s: identity file missing after %ss grace\n' "$lock_dir" "$grace" >&2
        return 1
      fi
      sleep "$poll"
      elapsed_polls=$((elapsed_polls + 1))
      if [ -n "$observe_polls" ] && [ "$elapsed_polls" -ge "$observe_polls" ]; then
        elapsed_txt="$(awk -v n="$elapsed_polls" -v p="$poll" 'BEGIN { printf "%.1f", (n + 0) * (p + 0) }' 2>/dev/null)"
        [ -n "$elapsed_txt" ] || elapsed_txt="$elapsed_polls"
        printf 'group-plan case lease: still waiting for lease at %s after %ss (test observe window)\n' "$lock_dir" "$elapsed_txt" >&2
        return 2
      fi
      continue
    fi
    holder_pid=""; holder_start=""; holder_extra=""
    { IFS= read -r holder_pid; IFS= read -r holder_start; IFS= read -r holder_extra; } < "$identity" 2>/dev/null || true
    if [ -z "$holder_pid" ] || [ -z "$holder_start" ] || [ -n "$holder_extra" ]; then
      missing_polls=$((missing_polls + 1))
      if [ "$missing_polls" -ge "$grace_polls" ]; then
        printf 'group-plan case lease: malformed lease at %s: identity file is malformed after %ss grace\n' "$lock_dir" "$grace" >&2
        return 1
      fi
      sleep "$poll"
      elapsed_polls=$((elapsed_polls + 1))
      if [ -n "$observe_polls" ] && [ "$elapsed_polls" -ge "$observe_polls" ]; then
        elapsed_txt="$(awk -v n="$elapsed_polls" -v p="$poll" 'BEGIN { printf "%.1f", (n + 0) * (p + 0) }' 2>/dev/null)"
        [ -n "$elapsed_txt" ] || elapsed_txt="$elapsed_polls"
        printf 'group-plan case lease: still waiting for lease at %s after %ss (test observe window)\n' "$lock_dir" "$elapsed_txt" >&2
        return 2
      fi
      continue
    fi
    case "$holder_pid" in
      *[!0-9]*)
        missing_polls=$((missing_polls + 1))
        if [ "$missing_polls" -ge "$grace_polls" ]; then
          printf 'group-plan case lease: malformed lease at %s: holder pid is not numeric after %ss grace\n' "$lock_dir" "$grace" >&2
          return 1
        fi
        sleep "$poll"
        elapsed_polls=$((elapsed_polls + 1))
        if [ -n "$observe_polls" ] && [ "$elapsed_polls" -ge "$observe_polls" ]; then
          elapsed_txt="$(awk -v n="$elapsed_polls" -v p="$poll" 'BEGIN { printf "%.1f", (n + 0) * (p + 0) }' 2>/dev/null)"
          [ -n "$elapsed_txt" ] || elapsed_txt="$elapsed_polls"
          printf 'group-plan case lease: still waiting for lease at %s after %ss (test observe window)\n' "$lock_dir" "$elapsed_txt" >&2
          return 2
        fi
        continue
        ;;
    esac
    missing_polls=0
    if ! kill -0 "$holder_pid" 2>/dev/null; then
      group_plan_case_lease__still_held_by "$identity" "$holder_pid" "$holder_start" || continue
      printf 'group-plan case lease: stale lease at %s: holder pid %s is dead; not breaking lease\n' "$lock_dir" "$holder_pid" >&2
      return 1
    fi
    live_start="$(group_plan_case_lease__start_time "$holder_pid")" || {
      group_plan_case_lease__still_held_by "$identity" "$holder_pid" "$holder_start" || continue
      printf 'group-plan case lease: stale lease at %s: holder pid %s is dead; not breaking lease\n' "$lock_dir" "$holder_pid" >&2
      return 1
    }
    if [ "$live_start" != "$holder_start" ]; then
      group_plan_case_lease__still_held_by "$identity" "$holder_pid" "$holder_start" || continue
      printf 'group-plan case lease: stale lease at %s: holder pid %s pid reuse detected (recorded start differs); not breaking lease\n' "$lock_dir" "$holder_pid" >&2
      return 1
    fi
    sleep "$poll"
    elapsed_polls=$((elapsed_polls + 1))
    if [ -n "$observe_polls" ] && [ "$elapsed_polls" -ge "$observe_polls" ]; then
      elapsed_txt="$(awk -v n="$elapsed_polls" -v p="$poll" 'BEGIN { printf "%.1f", (n + 0) * (p + 0) }' 2>/dev/null)"
      [ -n "$elapsed_txt" ] || elapsed_txt="$elapsed_polls"
      printf 'group-plan case lease: still waiting for holder pid %s after %ss (test observe window)\n' "$holder_pid" "$elapsed_txt" >&2
      return 2
    fi
    if [ $((SECONDS - beat_at)) -ge "$progress_secs" ]; then
      beat_at=$SECONDS
      printf 'group-plan case lease: waiting for holder pid %s (elapsed %ss, lock %s)\n' "$holder_pid" "$((SECONDS - started_at))" "$lock_dir" >&2
    fi
  done
}

# Release only our own lease: remove the identity file and lock dir only when
# the recorded pid/start still match our own pid/start. Never removes another
# holder's lock (see acquire comment: two cases must never share the path).
group_plan_case_lease_release() {
  local lock_dir identity holder_pid holder_start self_start
  if [ "${GROUP_PLAN_CASE_LOCK_HELD:-false}" != true ]; then
    return 0
  fi
  if [ -z "${GROUP_PLAN_RELEASE_CACHE:-}" ]; then
    GROUP_PLAN_CASE_LOCK_HELD=false
    return 0
  fi
  lock_dir="$GROUP_PLAN_RELEASE_CACHE/case.lock"
  identity="$lock_dir/holder"
  if [ ! -d "$lock_dir" ]; then
    GROUP_PLAN_CASE_LOCK_HELD=false
    GROUP_PLAN_CASE_LEASE_PID=""
    GROUP_PLAN_CASE_LEASE_START=""
    return 0
  fi
  if [ ! -f "$identity" ]; then
    printf 'group-plan case lease: not releasing lease at %s: identity is not ours\n' "$lock_dir" >&2
    GROUP_PLAN_CASE_LOCK_HELD=false
    return 0
  fi
  holder_pid=""; holder_start=""
  { IFS= read -r holder_pid; IFS= read -r holder_start; } < "$identity" 2>/dev/null || true
  self_start="$(group_plan_case_lease__start_time "$$" 2>/dev/null)" || self_start=""
  if [ "$holder_pid" = "$$" ] && [ -n "$self_start" ] && [ "$holder_start" = "$self_start" ]; then
    rm -f "$identity" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
  else
    printf 'group-plan case lease: not releasing lease at %s: not ours (holder pid %s)\n' "$lock_dir" "$holder_pid" >&2
  fi
  GROUP_PLAN_CASE_LOCK_HELD=false
  GROUP_PLAN_CASE_LEASE_PID=""
  GROUP_PLAN_CASE_LEASE_START=""
  return 0
}
