#!/usr/bin/env bash
# Provider-neutral LLM driver.
# Usage: llm-call.sh <prompt-path> <input-path> <out-path>
# Env:
#   LLM_PROVIDER  anthropic | openai | gemini | ollama | none   (default: anthropic if `llm` available)
#   LLM_MODEL     provider-specific model id                    (default per-provider below)
#   SECURITY_GATE_LLM_TIMEOUT_S  per-call timeout in seconds    (default: 120)
#
# Default backend: simonw/llm CLI. The wrapper just sets the model and pipes
# (prompt + input) to stdin. Replace this script if a project needs to talk
# direct to a provider API — interface stays the same.

set -euo pipefail

PROMPT="${1:?prompt-path required}"
INPUT="${2:?input-path required}"
OUT="${3:?out-path required}"

PROVIDER="${LLM_PROVIDER:-}"
MODEL="${LLM_MODEL:-}"
TIMEOUT="${SECURITY_GATE_LLM_TIMEOUT_S:-120}"

if [ "${PROVIDER}" = "none" ]; then
  echo "info: LLM_PROVIDER=none — skipping triage" >&2
  : > "$OUT"
  exit 2
fi

if ! command -v llm >/dev/null 2>&1; then
  echo "warn: llm CLI not found on PATH — skipping triage" >&2
  : > "$OUT"
  exit 2
fi

# Provider-default model selection.
if [ -z "$MODEL" ]; then
  case "$PROVIDER" in
    anthropic|"") MODEL="claude-opus-4-7"; PROVIDER="anthropic" ;;
    openai)       MODEL="gpt-4o" ;;
    gemini)       MODEL="gemini-2.0-flash" ;;
    ollama)       MODEL="llama3.1:8b" ;;
  esac
fi

# Compose the call. simonw/llm reads stdin as the user message; -s sets the system prompt.
SYSTEM_PROMPT="$(cat "$PROMPT")"

# Honor `timeout` if available (gnu coreutils / brew). On bare macOS, fall back.
if command -v timeout >/dev/null 2>&1; then
  RUNNER=(timeout --preserve-status "$TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then
  RUNNER=(gtimeout --preserve-status "$TIMEOUT")
else
  RUNNER=()
fi

# Try the call. If it fails (auth, network, model unknown), surface a `warn`
# and write an empty out so the caller falls through to no-LLM mode.
if [ "${#RUNNER[@]}" -gt 0 ]; then
  CMD=("${RUNNER[@]}" llm prompt -m "$MODEL" -s "$SYSTEM_PROMPT")
else
  CMD=(llm prompt -m "$MODEL" -s "$SYSTEM_PROMPT")
fi

if ! "${CMD[@]}" < "$INPUT" > "$OUT" 2>/tmp/security-gate-llm.err; then
  echo "warn: llm call failed (model=$MODEL provider=$PROVIDER) — see /tmp/security-gate-llm.err" >&2
  : > "$OUT"
  exit 2
fi

if [ ! -s "$OUT" ]; then
  echo "warn: llm returned empty output — treating as no-LLM run" >&2
  exit 2
fi
