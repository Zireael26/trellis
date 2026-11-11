#!/usr/bin/env bats
# Historical blacklist tables must not silently drop malformed exclusion rows.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-blacklist.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  BLACKLIST="$SANDBOX/blacklist.md"
  cat > "$BLACKLIST" <<'EOF'
# Blacklist
## 1. Temporarily excluded (registered projects)
Context prose is allowed.
| Project | Reason | Added | Review after |
|---|---|---|---|
| good | maintenance | 2026-01-01 | 2026-02-01 |
## 2. Permanently excluded from management
| Path | Reason |
|---|---|
| `/offline/good` | fixture |
This explanatory prose may mention a | b without being a table row.
EOF
}

parse() {
  run bash -c '. "$1"; legacy_blacklist_records "$2" "$3" "$4"' _ \
    "$REPO_ROOT/scripts/registry.sh" "$BLACKLIST" "$SANDBOX/names" "$SANDBOX/ignores"
}

@test "permanent row without leading pipe is refused" {
  printf '%s\n' '`/offline/lost` | retired' >> "$BLACKLIST"
  parse
  [ "$status" -eq 4 ] || { echo "dropped permanent row: $output"; false; }
}

@test "temporary row without leading pipe is refused" {
  python3 -I - "$BLACKLIST" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = path.read_text()
data = data.replace('## 2. Permanently excluded', 'lost | maintenance | 2026-01-01 | 2026-02-01\n## 2. Permanently excluded')
path.write_text(data)
PY
  parse
  [ "$status" -eq 4 ] || { echo "dropped temporary row: $output"; false; }
}

@test "indented table rows are refused" {
  printf '%s\n' '  | `/offline/lost` | retired |' >> "$BLACKLIST"
  parse
  [ "$status" -eq 4 ] || { echo "dropped indented row: $output"; false; }
}

@test "well-formed rows and explanatory prose remain accepted" {
  parse
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -s -e 'length == 1 and .[0].project_id == "good"' "$SANDBOX/names" >/dev/null
  jq -s -e 'length == 1 and .[0].path == "/offline/good"' "$SANDBOX/ignores" >/dev/null
}
