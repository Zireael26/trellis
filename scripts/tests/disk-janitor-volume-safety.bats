#!/usr/bin/env bats
# Spec 059 R1/R2/R4: scripts/disk-janitor.sh never deletes a Docker volume, in
# any mode, with any flag, and reports unattached anonymous volume IDs instead.
#
# Dynamic cases put a stub `docker` first on PATH. The stub answers the
# janitor's read-only queries from a fixture holding two unattached anonymous
# volumes, one attached anonymous volume and one named volume, and appends the
# FULL argv of every invocation to a log, one invocation per line with the
# arguments separated by US (0x1f). Each case then applies the spec's forbidden
# list to every logged argv as tokens. `pnpm` and `npm` are stubbed too, so the
# host-global `stores` scope under the default scopes never measures a real
# store. Every path lives under a fresh per-test sandbox.
#
# The static case applies the same token denylist to every non-comment line of
# disk-janitor.sh that invokes `docker`.
#
# bash 3.2 / bats 1.x. `[[ ]]` is fine in bats (not shellcheck-gated).

REPO_ROOT="$( cd "$BATS_TEST_DIRNAME/../.." && pwd )"
DJ="$REPO_ROOT/scripts/disk-janitor.sh"

UNATTACHED_ONE="1111111111111111111111111111111111111111111111111111111111111111"
UNATTACHED_TWO="2222222222222222222222222222222222222222222222222222222222222222"
ATTACHED="3333333333333333333333333333333333333333333333333333333333333333"
REPORT_ONLY_HEADING="report-only — the janitor never deletes volumes (PROTOCOL §10)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-volumes.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  CANON="$SANDBOX/canonical"
  PROJECTS="$SANDBOX/projects"
  TRELLIS_HOME="$SANDBOX/.trellis"
  CFG="$CANON/trellis.config.json"
  FAKE_BIN="$SANDBOX/fake-bin"
  DOCKER_ARGV_LOG="$SANDBOX/docker-argv.log"
  mkdir -p "$CANON/audits" "$PROJECTS" "$TRELLIS_HOME" "$FAKE_BIN" \
    "$SANDBOX/pnpm-store" "$SANDBOX/npm-cache"
  chmod 700 "$TRELLIS_HOME"
  export TRELLIS_CONFIG="$CFG" TRELLIS_HOME
  export DJ_BUILD_ACTIVE_OVERRIDE=0
  write_config
  write_stubs
}

teardown() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

write_config() {
  cat > "$CFG" <<EOF
{
  "schema_version": 2,
  "maintainer_name": "Test Maintainer",
  "github_user": "tester",
  "harnesses": ["claude"]
}
EOF
  cat > "$TRELLIS_HOME/config.json" <<EOF
{
  "schema_version": 1,
  "source_root": "$CANON",
  "release_remote": "https://example.invalid/trellis.git",
  "active_cli_release": "1.2.3",
  "default_fleet": "personal",
  "fleets": {"personal": {"discovery_roots": ["$PROJECTS"]}}
}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

# The stub succeeds for every command so that no forbidden call can hide behind
# an earlier failure; only the read-only queries return fixture data.
write_stubs() {
  cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/sh
{
  for arg in "$@"; do printf '%s\037' "$arg"; done
  printf '\n'
} >> "$DJ_DOCKER_ARGV_LOG"
case "${1:-}:${2:-}" in
  info:) exit 0 ;;
  version:--format) printf '27.4.0\n' ;;
  system:df)
    if [ "${3:-}" = "-v" ]; then
      printf '{"Volumes":[{"Name":"%s","Links":"0","Size":"1MB"},{"Name":"%s","Links":"0","Size":"2MB"},{"Name":"%s","Links":"1","Size":"5MB"},{"Name":"named_data","Links":"0","Size":"3MB"}]}\n' \
        "$DJ_UNATTACHED_ONE" "$DJ_UNATTACHED_TWO" "$DJ_ATTACHED"
    else
      printf '%s\n' '{"Type":"Images","TotalCount":"2"}'
    fi
    ;;
  buildx:du) printf '%s\n' '{"Reclaimable":true,"Size":"3MB"}' ;;
esac
exit 0
EOF
  cat > "$FAKE_BIN/pnpm" <<EOF
#!/bin/sh
printf '%s\n' "$SANDBOX/pnpm-store"
EOF
  cat > "$FAKE_BIN/npm" <<EOF
#!/bin/sh
printf '%s\n' "$SANDBOX/npm-cache"
EOF
  chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/pnpm" "$FAKE_BIN/npm"
}

run_dj_stubbed() {
  : > "$DOCKER_ARGV_LOG"
  run env PATH="$FAKE_BIN:$PATH" DJ_DOCKER_ARGV_LOG="$DOCKER_ARGV_LOG" \
    DJ_UNATTACHED_ONE="$UNATTACHED_ONE" DJ_UNATTACHED_TWO="$UNATTACHED_TWO" \
    DJ_ATTACHED="$ATTACHED" bash "$DJ" "$@" </dev/null
}

# volume_delete_form TOKEN... — succeed, printing the form, when the tokens
# after `docker` are one of spec 059 R1's forbidden commands, in any argument
# order. Any -v/--volumes token (or a short-option cluster holding v) counts.
volume_delete_form() {
  local t volume=0 rm=0 remove=0 prune=0 system=0 container=0 compose=0 down=0 vflag=0
  for t in "$@"; do
    case "$t" in
      volume) volume=1 ;;
      rm) rm=1 ;;
      remove) remove=1 ;;
      prune) prune=1 ;;
      system) system=1 ;;
      container) container=1 ;;
      compose) compose=1 ;;
      down) down=1 ;;
      -v|--volumes|--volumes=*) vflag=1 ;;
      --*) ;;
      -*v*) vflag=1 ;;
    esac
  done
  if [ "$volume" -eq 1 ] && { [ "$rm" -eq 1 ] || [ "$remove" -eq 1 ] || [ "$prune" -eq 1 ]; }; then
    echo "docker volume rm/remove/prune"; return 0
  fi
  if [ "$system" -eq 1 ] && [ "$prune" -eq 1 ]; then echo "docker system prune"; return 0; fi
  if [ "$container" -eq 1 ] && [ "$prune" -eq 1 ]; then echo "docker container prune"; return 0; fi
  if [ "$compose" -eq 1 ] && { [ "$rm" -eq 1 ] || [ "$down" -eq 1 ]; } && [ "$vflag" -eq 1 ]; then
    echo "docker compose rm/down with volumes"; return 0
  fi
  if [ "$compose" -eq 0 ] && [ "$rm" -eq 1 ] && [ "$vflag" -eq 1 ]; then
    echo "docker rm/container rm with volumes"; return 0
  fi
  return 1
}

# assert_no_volume_delete_in_log — apply the denylist to every logged argv and
# fail on the first forbidden one. Also fails on an empty log, so a run that
# never reached Docker cannot pass vacuously.
assert_no_volume_delete_in_log() {
  local line form calls=0
  local -a argv
  while IFS= read -r line; do
    IFS=$'\037' read -r -a argv <<< "$line"
    calls=$((calls + 1))
    if form="$(volume_delete_form ${argv[@]+"${argv[@]}"})"; then
      echo "forbidden volume-deleting docker call ($form): $(printf '%s' "$line" | tr '\037' ' ')"
      return 1
    fi
  done < "$DOCKER_ARGV_LOG"
  [ "$calls" -gt 0 ] || { echo "docker stub was never invoked"; return 1; }
  grep -q "^system"$'\037'"df"$'\037'"-v"$'\037' "$DOCKER_ARGV_LOG" ||
    { echo "janitor never enumerated volumes"; cat "$DOCKER_ARGV_LOG"; return 1; }
}

assert_volumes_reported() {
  [[ "$output" == *"$REPORT_ONLY_HEADING"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"    $UNATTACHED_ONE"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"    $UNATTACHED_TWO"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"$ATTACHED"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"anonymous volumes: 3 total; 2 unattached (Links == 0)"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"volume rm"* ]] || { echo "$output"; return 1; }
}

# run_matrix MODE-ARGS... — the three scope settings of R4 for one mode.
run_matrix() {
  local scopes
  for scopes in default docker caches,worktrees,stores,docker,releases; do
    if [ "$scopes" = default ]; then
      run_dj_stubbed "$@"
    else
      run_dj_stubbed "$@" --scopes "$scopes"
    fi
    [ "$status" -eq 0 ] || { echo "scopes=$scopes status=$status"; echo "$output"; false; }
    assert_no_volume_delete_in_log || { echo "scopes=$scopes"; false; }
    assert_volumes_reported || { echo "scopes=$scopes"; false; }
  done
}

@test "denylist flags every forbidden form in any order and passes read-only calls" {
  local form
  for form in \
    "volume rm $UNATTACHED_ONE" "volume remove x" "volume prune -f" "volume prune --all -f" \
    "rm volume x" "prune volume" "system prune" "system prune -af --volumes" "--volumes system prune" \
    "rm -v c" "rm -fv c" "rm --volumes c" "-v rm c" "container rm -v c" "container rm --volumes=true c" \
    "container prune -f" "prune container" "compose rm -v" "compose rm -fsv" "compose down -v" \
    "compose down --volumes" "--volumes compose down" "compose -p lane down --volumes"; do
    # shellcheck disable=SC2086
    volume_delete_form $form >/dev/null || { echo "not flagged: docker $form"; false; }
  done
  for form in \
    "info" "version --format {{.Server.Version}}" "system df --format json" "system df -v --format json" \
    "buildx du --format json" "buildx prune -f --reserved-space 20GB" "volume ls" "volume inspect x" \
    "ps -a --filter volume=x" "rm c" "compose down" "compose rm -f" "image ls"; do
    # shellcheck disable=SC2086
    if volume_delete_form $form >/dev/null; then echo "wrongly flagged: docker $form"; false; fi
  done
}

@test "--report never issues a volume-deleting docker call and lists unattached IDs" {
  run_matrix --report
}

@test "--dry-run never issues a volume-deleting docker call and lists unattached IDs" {
  run_matrix --dry-run
}

@test "--apply --yes never issues a volume-deleting docker call and lists unattached IDs" {
  run_matrix --apply --yes
}

@test "--apply --yes --safe-only never issues a volume-deleting docker call and lists unattached IDs" {
  run_matrix --apply --yes --safe-only
}

@test "--apply --yes --scopes docker still prunes BuildKit with --reserved-space" {
  local expected confirmation
  run_dj_stubbed --apply --yes --scopes docker
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  expected="buildx"$'\037'"prune"$'\037'"-f"$'\037'"--reserved-space"$'\037'"20GB"$'\037'
  grep -Fxq "$expected" "$DOCKER_ARGV_LOG" || { tr '\037' ' ' < "$DOCKER_ARGV_LOG"; false; }
  [[ "$output" == *"Docker prune commands completed: buildkit=1"* ]] || { echo "$output"; false; }
  # The Docker category's confirmation label names only the BuildKit cache.
  confirmation="$(printf '%s\n' "$output" | grep -F '(--yes) proceeding with')"
  [[ "$confirmation" == *"proceeding with BuildKit cache"* ]] || { echo "$output"; false; }
  [[ "$confirmation" != *olume* ]] || { echo "$confirmation"; false; }
}

@test "--docker-volumes is a usage error" {
  run_dj_stubbed --apply --yes --docker-volumes
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: --docker-volumes"* ]] || { echo "$output"; false; }
  [ ! -s "$DOCKER_ARGV_LOG" ]
}

@test "disk-janitor.sh has no volume-deleting docker invocation outside comments" {
  local line joined="" form docker_lines=0 buildx_prune=0 i found
  local -a tokens rest
  while IFS= read -r line || [ -n "$line" ]; do
    # Join backslash continuations into one logical line.
    case "$line" in
      *\\) joined="$joined${line%\\} "; continue ;;
    esac
    line="$joined$line"
    joined=""
    case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
    # Quotes, backticks and command-substitution punctuation are not part of
    # a token; a `#` token starts a trailing comment.
    line="$(printf '%s' "$line" | tr "'\"\`();|&" '         ')"
    read -r -a tokens <<< "$line"
    found=0
    rest=()
    for i in ${tokens[@]+"${!tokens[@]}"}; do
      case "${tokens[$i]}" in '#'*) break ;; esac
      if [ "$found" -eq 1 ]; then
        rest+=("${tokens[$i]}")
      elif [ "${tokens[$i]}" = docker ]; then
        found=1
      fi
    done
    [ "$found" -eq 1 ] || continue
    docker_lines=$((docker_lines + 1))
    case " ${rest[*]+"${rest[*]}"} " in *" buildx prune "*) buildx_prune=1 ;; esac
    if form="$(volume_delete_form ${rest[@]+"${rest[@]}"})"; then
      echo "forbidden ($form): docker ${rest[*]}"
      false
    fi
  done < "$DJ"
  # Non-vacuous: the scan saw the janitor's real Docker calls.
  [ "$docker_lines" -ge 5 ] || { echo "only $docker_lines docker lines scanned"; false; }
  [ "$buildx_prune" -eq 1 ]
}
