#!/usr/bin/env bats
# SC1 guard for the current roster surface and its repository-wide history ledger.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME/../.." rev-parse --show-toplevel)"
ALLOWLIST="$REPO_ROOT/specs/052-gpt6-roster/record-allowlist.txt"
OLD_MODEL_RE='gpt-5[.]6'
OLD_NAME_RE='ter''ra'
LEGACY_MODEL='gpt-5''.''6'
HIT_PATTERN="(^|[^[:alnum:]_])(${OLD_MODEL_RE}|${OLD_NAME_RE})([^[:alnum:]_]|$)"

_live_set_files() {
  git -C "$REPO_ROOT" ls-files -- \
    'core-rules/skills/herdr-foreman/roles.json' \
    'core-rules/skills/herdr-foreman/SKILL.md' \
    'core-rules/skills/herdr-foreman/scripts' \
    'core-rules/skills/herdr-foreman/tests' \
    ':(glob)core-rules/pi/agents/*.md' \
    ':(glob)core-rules/skills/orchestrate/recipes/*.js' \
    ':(glob)core-rules/references/*.md' \
    'core-rules/loop-safety.md' \
    'docs/codex-routing.md' \
    ':(glob)local/*.sh' \
    'scripts/codex-effort-preflight.sh' \
    'scripts/tests/fixtures/codex-effort-preflight' \
    'core-rules/hooks/herdr-foreman-session.sh' \
    'core-rules/codex/hooks/herdr-foreman-session.sh' \
    'core-rules/hooks/lib/code-reviewer.sh' | LC_ALL=C sort -u
}

_scan_live_files() {
  local root="$1" file_list="$2" rel matches found=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$root/$rel" ] || continue
    if matches="$(grep -n -i -E "$HIT_PATTERN" "$root/$rel" 2>&1)"; then
      printf '%s\n' "$matches" | sed "s#^#$rel:#"
      found=1
    else
      grep_status=$?
      [ "$grep_status" -eq 1 ] || {
        printf 'grep failed for %s with status %s: %s\n' "$rel" "$grep_status" "$matches" >&2
        return 2
      }
    fi
  done < "$file_list"
  return "$found"
}

_is_live_path() {
  grep -Fqx -- "$1" "$2"
}

_is_historical_star_path() {
  local path="$1" remainder
  case "$path" in
    audits/*|receipts/*|research/*|docs/plans/*|docs/specs/*) return 0 ;;
    CHANGELOG.md|decisions-log.md) return 0 ;;
    docs/adr/*)
      [ "$path" != 'docs/adr/2026-09-27-gpt6-roster.md' ] && return 0
      return 1
      ;;
    scripts/tests/fixtures/usage-federation/*) return 0 ;;
    specs/*)
      remainder="${path#specs/}"
      remainder="${remainder#*/}"
      case "$remainder" in receipts/*) return 0 ;; esac
      [ "$path" = 'specs/011-gpt-5-6-effort-reground/research/gpt-5-6-raw-v3.md' ] && return 0
      ;;
  esac
  return 1
}

_validate_allowlist() {
  local live_files="$1" target reason path line live_entries
  while IFS=$'\t' read -r target reason; do
    [ -n "$target" ] || continue
    [ -n "$reason" ] || { echo "allowlist row has no reason: $target"; return 1; }
    case "$target" in
      *:*) ;;
      *) echo "allowlist target must be path:line-or-*: $target"; return 1 ;;
    esac
    path="${target%:*}"
    line="${target##*:}"
    if [ "$line" = '*' ]; then
      _is_historical_star_path "$path" || {
        echo "path-level wildcard is not permitted here: $target"
        return 1
      }
    else
      case "$line" in
        ''|*[!0-9]*) echo "allowlist line must be numeric or *: $target"; return 1 ;;
      esac
    fi
  done < "$ALLOWLIST"

  live_entries="$(awk -F '\t' '
    NR == FNR { live[$0] = 1; next }
    {
      target = $1
      colon = index(target, ":")
      path = substr(target, 1, colon - 1)
      if (path in live) print target
    }
  ' "$live_files" "$ALLOWLIST")"
  [ -z "$live_entries" ] || {
    printf 'live-set paths must not be allowlisted:\n%s\n' "$live_entries" >&2
    return 1
  }
}

@test "the SC1 live set contains no retired model identifiers" {
  live_files="$BATS_TEST_TMPDIR/gpt6-roster-live-files.txt"
  _live_set_files > "$live_files"

  run _scan_live_files "$REPO_ROOT" "$live_files"
  [ "$status" -eq 0 ] || {
    printf 'live-set hits (path:line:content):\n%s\n' "$output" >&2
    return 1
  }
}

@test "every repository hit outside the live set is covered by the ledger" {
  live_files="$BATS_TEST_TMPDIR/gpt6-roster-live-files.txt"
  all_hits="$BATS_TEST_TMPDIR/gpt6-roster-all-hits.txt"
  outside_hits="$BATS_TEST_TMPDIR/gpt6-roster-outside-hits.txt"
  _live_set_files > "$live_files"

  if git -C "$REPO_ROOT" grep -n -i -E "$HIT_PATTERN" -- . \
    ':!specs/052-gpt6-roster/record-allowlist.txt' > "$all_hits"; then
    :
  else
    grep_status=$?
    [ "$grep_status" -eq 1 ] || {
      echo "repository grep failed with status $grep_status" >&2
      return 1
    }
  fi

  awk -F ':' '
    NR == FNR { live[$0] = 1; next }
    !($1 in live) { print }
  ' "$live_files" "$all_hits" > "$outside_hits"

  _validate_allowlist "$live_files" || return 1

  uncovered="$(awk -F '\t' '
    FNR == NR {
      target = $1
      if (target ~ /:\*$/) {
        path = target
        sub(/:\*$/, "", path)
        wildcard[path] = 1
      } else if (target != "") {
        listed[target] = 1
      }
      next
    }
    {
      first = index($0, ":")
      path = substr($0, 1, first - 1)
      rest = substr($0, first + 1)
      second = index(rest, ":")
      line = substr(rest, 1, second - 1)
      key = path ":" line
      if (!(key in listed) && !(path in wildcard)) print $0
    }
  ' "$ALLOWLIST" "$outside_hits")"
  [ -z "$uncovered" ] || {
    printf 'uncovered repository hits (path:line:content):\n%s\n' "$uncovered" >&2
    return 1
  }

  total="$(wc -l < "$all_hits" | tr -d ' ')"
  outside="$(wc -l < "$outside_hits" | tr -d ' ')"
  entries="$(wc -l < "$ALLOWLIST" | tr -d ' ')"
  printf 'repository hits=%s; outside-live hits=%s; allowlist entries=%s\n' \
    "$total" "$outside" "$entries"
}

@test "the live-set scanner rejects a hit in a temporary fixture copy" {
  fixture_root="$BATS_TEST_TMPDIR/gpt6-roster-fixture"
  rel='core-rules/skills/herdr-foreman/roles.json'
  mkdir -p "$fixture_root/core-rules/skills/herdr-foreman"
  cp "$REPO_ROOT/$rel" "$fixture_root/$rel"
  printf '%s\n' "$LEGACY_MODEL" >> "$fixture_root/$rel"
  printf '%s\n' "$rel" > "$BATS_TEST_TMPDIR/gpt6-roster-fixture-files.txt"

  run _scan_live_files "$fixture_root" "$BATS_TEST_TMPDIR/gpt6-roster-fixture-files.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$rel:"* ]]
}

@test "word boundaries ignore unrelated provider names and embedded fragments" {
  fixture_root="$BATS_TEST_TMPDIR/gpt6-roster-boundary-fixture"
  rel='core-rules/skills/herdr-foreman/roles.json'
  mkdir -p "$fixture_root/core-rules/skills/herdr-foreman"
  cp "$REPO_ROOT/$rel" "$fixture_root/$rel"
  printf '%s\n' 'Terraform' 'prefixterraSuffix' > "$fixture_root/$rel"
  printf '%s\n' "$rel" > "$BATS_TEST_TMPDIR/gpt6-roster-boundary-files.txt"

  run _scan_live_files "$fixture_root" "$BATS_TEST_TMPDIR/gpt6-roster-boundary-files.txt"
  [ "$status" -eq 0 ]
}
