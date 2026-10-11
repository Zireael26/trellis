#!/usr/bin/env bats
# Fixture runtime only; never attach or mutate installed artifacts.
setup() {
  SOURCE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
}

@test "installed-style pi extension preserves pre-action parity in process" {
  run node --test --test-reporter=tap "$SOURCE/core-rules/pi/tests/in-process-parity.test.mjs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "legacy dispatcher retains read tracking unless the extension records it" {
  project="$BATS_TEST_TMPDIR/project"
  mkdir -p "$project/.pi/hooks"
  printf '#!/bin/bash\nexit 0\n' > "$project/.pi/hooks/truncation-check.sh"
  printf '#!/bin/bash\nprintf track-sentinel >&2\n' > "$project/.pi/hooks/track-read.sh"
  chmod +x "$project/.pi/hooks/"*.sh
  for recorded in false true; do
    encoded="$(jq -nc --arg cwd "$project" --argjson recorded "$recorded" '{schema_version:1,harness:"pi",cwd:$cwd,phase:"post_action",native_event:"tool_result",in_process_read_tracking:$recorded,action:{family:"file_read",tool_name:"read",input:{path:"file"}},result:{status:"succeeded"}}' | base64)"
    run bash -c 'cd "$1" && exec bash "$2" --base64 "$3"' fixture "$project" "$SOURCE/core-rules/pi/hooks/dispatch.sh" "$encoded"
    [ "$status" -eq 0 ]
    if [ "$recorded" = true ]; then [[ "$output" != *track-sentinel* ]]; else [[ "$output" == *track-sentinel* ]]; fi
  done
}
