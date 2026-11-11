#!/usr/bin/env bats
# Availability and exclusion must be true of the same checkout row.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-scheduled.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  SNAPSHOT="$SANDBOX/snapshot.json" FUNCS="$SANDBOX/functions.sh"
  python3 -I - "$REPO_ROOT/scripts/materialize-scheduled-task.sh" "$FUNCS" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
start = source.index('excluded_unavailable_projects() {')
end = source.index('\n\nnonexcluded_project_count()', start)
Path(sys.argv[2]).write_text(source[start:end] + '\n')
PY
  jq -n '{entries:[
    {project_key:"personal/site",project_id:"site",status:"active",kind:"worktree",availability:"unavailable",excluded:false,root:"/a"},
    {project_key:"personal/site",project_id:"site",status:"active",kind:"worktree",availability:"available",excluded:true,root:"/b"}
  ]}' > "$SNAPSHOT"
}

check() {
  bash -c '. "$1"; eligible_active_project_count "$2"; excluded_unavailable_projects "$2"' _ "$FUNCS" "$SNAPSHOT"
}

@test "excluded available checkout cannot make an unavailable project eligible" {
  run check
  [ "$status" -eq 0 ]
  [ "$output" = $'0\n["site"]' ] || { echo "wrong eligibility: $output"; false; }
}

@test "a nonexcluded available checkout remains eligible" {
  jq '.entries[1].excluded = false' "$SNAPSHOT" > "$SANDBOX/next"
  mv "$SANDBOX/next" "$SNAPSHOT"
  run check
  [ "$status" -eq 0 ]
  [ "$output" = $'1\n[]' ] || { echo "$output"; false; }
}
