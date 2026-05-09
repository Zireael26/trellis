#!/usr/bin/env bash
# lint-prompt-shell-blocks.sh — extract `bash` / `sh` fenced code blocks
# from scheduled-task prompt files and `bash -n` syntax-check each.
#
# Plan task P3.9 (audit §2.3 fourth bullet).
#
# Usage:
#   scripts/lint-prompt-shell-blocks.sh [path...]
# Defaults to scheduled-tasks/ if no path given.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

paths=("$@")
[ ${#paths[@]} -eq 0 ] && paths=("$ROOT/scheduled-tasks")

fail_count=0
file_count=0
block_count=0

for p in "${paths[@]}"; do
  while IFS= read -r md; do
    file_count=$((file_count + 1))
    # Extract bash/sh blocks. awk state machine: enter on ```bash / ```sh,
    # exit on ```. For each block, write to a temp file, bash -n, report.
    awk '
      /^```(bash|sh)([[:space:]]|$)/ { in_block=1; block=""; next }
      /^```/ && in_block { print "---END---\n" block; in_block=0; next }
      in_block { block = block $0 "\n" }
    ' "$md" | awk -v file="$md" '
      /^---END---$/ { close_block=1; next }
      { buf = buf $0 "\n" }
      END { if (length(buf)) printf "%s", buf }
    ' > /tmp/_prompt_block_$$.sh

    if [ -s /tmp/_prompt_block_$$.sh ]; then
      block_count=$((block_count + 1))
      if ! bash -n /tmp/_prompt_block_$$.sh 2>/tmp/_prompt_err_$$; then
        echo "fail: $md — bash -n syntax error:" >&2
        sed 's/^/  /' /tmp/_prompt_err_$$ >&2
        fail_count=$((fail_count + 1))
      fi
    fi
    rm -f /tmp/_prompt_block_$$.sh /tmp/_prompt_err_$$
  done < <(find "$p" -name '*.md' -type f)
done

if [ "$fail_count" -gt 0 ]; then
  echo "lint-prompt-shell-blocks: $fail_count failures across $file_count files ($block_count blocks scanned)" >&2
  exit 1
fi
echo "lint-prompt-shell-blocks: clean ($file_count files, $block_count bash/sh blocks scanned)"
