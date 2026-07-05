#!/usr/bin/env bats
# Tests that the code-reviewer prompt stays byte-identical across its two copies:
#   core-rules/hooks/agents/code-reviewer.md  — the fenced prompt block (source of truth)
#   core-rules/hooks/lib/code-reviewer.sh     — the embedded heredoc (runtime copy)
#
# The .md file's own contract says "if you change one, change both." Nothing
# enforced that until now; a drift means the shipped reviewer (the .sh heredoc)
# diverges from the documented contract silently. This test is the enforcement.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
MD="$REPO/core-rules/hooks/agents/code-reviewer.md"
SH="$REPO/core-rules/hooks/lib/code-reviewer.sh"

# Extract the first fenced code block AFTER the "## Prompt" heading in the .md.
_md_prompt() {
  awk '
    /^## Prompt/            {inprompt=1; next}
    inprompt && /^```/ && !incode {incode=1; next}
    inprompt && /^```/ && incode  {exit}
    incode                  {print}
  ' "$MD"
}

# Extract the heredoc body between `cat <<'PROMPT_EOF'` and `PROMPT_EOF` in the .sh.
_sh_prompt() {
  awk '
    /cat <<.PROMPT_EOF./ {f=1; next}
    /^PROMPT_EOF/         {f=0}
    f                     {print}
  ' "$SH"
}

@test "both reviewer-prompt copies exist" {
  [ -f "$MD" ]
  [ -f "$SH" ]
}

@test "the .md fenced block is non-empty and starts with the reviewer preamble" {
  run _md_prompt
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == "You are a code reviewer for a single turn's diff."* ]]
}

@test "the .md prompt block and the .sh heredoc are byte-identical" {
  diff <(_md_prompt) <(_sh_prompt)
}

@test "the coverage line is present in both copies (A1)" {
  _md_prompt | grep -q "coverage is your job, filtering is not"
  _sh_prompt | grep -q "coverage is your job, filtering is not"
}
