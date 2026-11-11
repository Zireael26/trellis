#!/usr/bin/env bats
load helpers

# A synthetic Pi 0.85.1 package: SDK files holding the patch's preimage and a
# bundle chunk written here as the shipped bundle spells it, with the
# truncate marker's newlines as backslash-n escapes inside a template literal.
make_package() {
  local root="$1" patch="$2"
  mkdir -p "$root/dist/core/compaction" "$root/dist/bundle/chunks"
  printf '{"name":"@earendil-works/pi-coding-agent","version":"0.85.1"}\n' > "$root/package.json"
  # Each hunk's context and removed lines, at the line the hunk names.
  awk -v root="$root" '
    /^--- a\// { file = root "/" substr($2, 3); n = 0; next }
    /^\+\+\+ / { next }
    /^@@/ { start = substr($2, 2); sub(/,.*/, "", start); while (n < start - 1) { print "" > file; n++ } next }
    file != "" && /^[ -]/ { print substr($0, 2) > file; n++ }
  ' "$patch"
  cat > "$root/dist/bundle/chunks/chunk-JVUZSMYM.js" <<'BUNDLE'
function failure(label,response){if(response.stopReason==="length")return`${label} failed: generation hit the token cap and the summary is incomplete`}
async function compactHistory(){let historyText="No prior history.",historyUsage;if(messagesToSummarize.length>0){let historyResult=await generateSummaryWithUsage(messagesToSummarize)}}
function truncateForSummary(text,maxChars){if(text.length<=maxChars)return text;let truncatedChars=text.length-maxChars;return`${text.slice(0,maxChars)}\n\n[... ${truncatedChars} more characters truncated]`}
BUNDLE
}

@test "sweep-fx1-L4: installer applies the truncate rewrite to a bundle with escaped newlines" {
  local patches="$HOOKS_DIR/../pi/patches" root="$BATS_TEST_TMPDIR/pkg" bundle
  make_package "$root" "$patches/pi-coding-agent-0.85.1-compaction-integrity.patch"
  bundle="$root/dist/bundle/chunks/chunk-JVUZSMYM.js"

  run bash "$patches/apply-pi-compaction-patches.sh" "$root"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "applied: "* ]] || { echo "$output"; false; }

  # The rewrite landed in place, still one line, with its escapes intact.
  [ "$(grep -c '' "$bundle")" -eq 3 ]
  grep -qF 'marker=`\n\n[... ${truncatedChars} middle characters truncated ...]\n\n`' "$bundle"
  [ "$(grep -cF 'more characters truncated' "$bundle")" -eq 0 ]
  grep -qF 'generation was aborted' "$bundle"
  grep -qF 'let historyText=previousSummary??"No prior history."' "$bundle"

  run bash "$patches/apply-pi-compaction-patches.sh" "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == "already applied: "* ]] || { echo "$output"; false; }
}
