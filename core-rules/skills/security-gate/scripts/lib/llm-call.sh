#!/usr/bin/env bash
# Provider-neutral LLM driver.
# Usage: llm-call.sh <prompt-path> <input-path> <out-path>
# Env:
#   LLM_PROVIDER  anthropic | openai | gemini | ollama | none   (default: anthropic if `llm` available)
#   LLM_MODEL     provider-specific model id                    (default: claude-opus-5 for anthropic; required for openai/gemini/ollama)
#   SECURITY_GATE_LLM_TIMEOUT_S  per-call timeout in seconds    (default: 120)
#
# Default backend: simonw/llm CLI. The wrapper just sets the model and pipes
# (prompt + input) to stdin. Replace this script if a project needs to talk
# direct to a provider API — interface stays the same.

# Inherited shell functions never answer for a tool. Every command name can be
# shadowed, `builtin` included, but an assignment cannot: POSIXLY_CORRECT turns
# on POSIX mode, where the special builtins `unset` and `set` are found before
# functions, so the first purge cannot be intercepted (see run-diff.sh).
POSIXLY_CORRECT=y
unset -f builtin command type set unset compgen
set +o posix
builtin unset POSIXLY_CORRECT
for _sg_fn in $(builtin compgen -A function 2>/dev/null); do builtin unset -f "$_sg_fn"; done
builtin unset -f llm timeout gtimeout
builtin unset _sg_fn

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

LLM_BIN="$(builtin type -P llm)" || LLM_BIN=""
if [ -z "$LLM_BIN" ]; then
  echo "warn: llm CLI not found on PATH — skipping triage" >&2
  : > "$OUT"
  exit 2
fi

# Provider-default model selection. Only Anthropic has a default; openai/
# gemini/ollama must provide an explicit LLM_MODEL to avoid silently pinning
# a stale model id. Callers get the standard no-LLM exit (2) with an
# actionable warning so they can set the model explicitly.
if [ -z "$MODEL" ]; then
  case "$PROVIDER" in
    anthropic|"") MODEL="claude-opus-5"; PROVIDER="anthropic" ;;
    openai|gemini|ollama)
      echo "warn: LLM_PROVIDER=$PROVIDER requires LLM_MODEL to be set — no default (set LLM_MODEL explicitly)" >&2
      : > "$OUT"
      exit 2
      ;;
  esac
fi
# Compose the call. simonw/llm reads stdin as the user message; -s sets the system prompt.
SYSTEM_PROMPT="$(cat "$PROMPT")"

# Honor `timeout` when available (GNU coreutils / brew).
if TIMEOUT_BIN="$(builtin type -P timeout)"; then
  RUNNER=("$TIMEOUT_BIN" --preserve-status "$TIMEOUT")
elif TIMEOUT_BIN="$(builtin type -P gtimeout)"; then
  RUNNER=("$TIMEOUT_BIN" --preserve-status "$TIMEOUT")
else
  echo "warn: neither timeout nor gtimeout is available — refusing to invoke llm without a deadline" >&2
  : > "$OUT"
  exit 2
fi

# Try the call. If it fails (auth, network, model unknown), surface a `warn`
# and write an empty out so the caller falls through to no-LLM mode.
DIAGNOSTIC_TEMPLATE="${TMPDIR:-/tmp}/security-gate-llm.XXXXXX"
if ! DIAGNOSTIC="$(umask 077; mktemp "$DIAGNOSTIC_TEMPLATE")"; then
  echo "warn: unable to allocate private llm diagnostic at $DIAGNOSTIC_TEMPLATE" >&2
  : > "$OUT"
  exit 2
fi
CMD=("${RUNNER[@]}" "$LLM_BIN" prompt -m "$MODEL" -s "$SYSTEM_PROMPT")

# SAFETY: SECURITY_GATE_LLM_TIMEOUT_S, default 120 seconds per the env contract above, bounds external provider I/O.
if ! "${CMD[@]}" < "$INPUT" > "$OUT" 2>"$DIAGNOSTIC"; then
  echo "warn: llm call failed (model=$MODEL provider=$PROVIDER) — see $DIAGNOSTIC" >&2
  : > "$OUT"
  exit 2
fi
rm -f "$DIAGNOSTIC"

if [ ! -s "$OUT" ]; then
  echo "warn: llm returned empty output — treating as no-LLM run" >&2
  exit 2
fi
