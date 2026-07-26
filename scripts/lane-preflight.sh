#!/usr/bin/env bash
# lane-preflight.sh — fail-closed foreign model lane probe.
#
# THE SCRIPT ONLY REPORTS; CALLERS DECIDE. It always exits 0 with one JSON
# report on stdout. A host with no local lane router gets a fully fail-closed
# report, never an error exit. Unknown state, probe errors, and timeouts all
# resolve to available: false.
#
# Environment:
#   TRELLIS_LANE_BASE_URL       local router base URL
#                               (default: empty; the operator supplies it)
#   TRELLIS_LANE_HEALTH_PATH    state endpoint below the base URL (default: /)
#   TRELLIS_LANE_MODEL          optional model name, forwarded to a model-aware
#                               state endpoint in the x-trellis-lane-model header
#                               (default: empty; no header)
#   TRELLIS_LANE_TIMEOUT_SECONDS
#                               positive integer probe timeout (default: 3)
#
# The state endpoint must return HTTP 2xx and JSON containing "state":"ok".
# Any other response is unavailable. The endpoint URL is never emitted.
#
# Output JSON shape (exactly these four fields):
#   {"available":bool,"reason":"","endpoint_configured":bool,"probe_ms":int}
#
# Bash 3.2 / macOS compatible. No jq and no timeout(1).

set -u

BASE_URL="${TRELLIS_LANE_BASE_URL:-}"
HEALTH_PATH="${TRELLIS_LANE_HEALTH_PATH:-/}"
LANE_MODEL="${TRELLIS_LANE_MODEL:-}"
TIMEOUT_SECONDS="${TRELLIS_LANE_TIMEOUT_SECONDS:-3}"

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_report() {
  available="$1"
  reason="$2"
  endpoint_configured="$3"
  probe_ms="$4"
  printf '{"available":%s,"reason":"%s","endpoint_configured":%s,"probe_ms":%s}\n' \
    "$available" \
    "$(json_escape "$reason")" \
    "$endpoint_configured" \
    "$probe_ms"
  exit 0
}

if [ -z "$BASE_URL" ]; then
  emit_report false "endpoint_unset" false 0
fi

endpoint_configured=true

case "$BASE_URL" in
  http://*|https://*) ;;
  *) emit_report false "endpoint_invalid" "$endpoint_configured" 0 ;;
esac

case "$HEALTH_PATH" in
  /*) ;;
  *) emit_report false "health_path_invalid" "$endpoint_configured" 0 ;;
esac

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0) emit_report false "timeout_invalid" "$endpoint_configured" 0 ;;
esac

case "$LANE_MODEL" in
  *[![:print:]]*) emit_report false "model_invalid" "$endpoint_configured" 0 ;;
esac

CURL_BIN="$(command -v curl 2>/dev/null || true)"
PERL_BIN="$(command -v perl 2>/dev/null || true)"
if [ -z "$CURL_BIN" ] || [ -z "$PERL_BIN" ]; then
  emit_report false "probe_tool_unavailable" "$endpoint_configured" 0
fi

PROBE_URL="${BASE_URL%/}${HEALTH_PATH}"
CURL_ARGS=(
  --silent
  --show-error
  --request GET
  --header "accept: application/json"
  --write-out $'\n%{http_code}'
)
if [ -n "$LANE_MODEL" ]; then
  CURL_ARGS+=(--header "x-trellis-lane-model: $LANE_MODEL")
fi

start_ms="$("$PERL_BIN" -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null)"
probe_output="$({
  "$PERL_BIN" -e 'alarm shift; exec @ARGV' "$TIMEOUT_SECONDS" \
    "$CURL_BIN" "${CURL_ARGS[@]}" "$PROBE_URL"
} 2>/dev/null)"
probe_status=$?
end_ms="$("$PERL_BIN" -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null)"

probe_ms=0
case "$start_ms:$end_ms" in
  *[!0-9:]*|:*) ;;
  *)
    if [ "$end_ms" -ge "$start_ms" ] 2>/dev/null; then
      probe_ms=$((end_ms - start_ms))
    fi
    ;;
esac

case "$probe_status" in
  0) ;;
  124|142) emit_report false "probe_timeout" "$endpoint_configured" "$probe_ms" ;;
  *) emit_report false "endpoint_unreachable" "$endpoint_configured" "$probe_ms" ;;
esac

http_code="${probe_output##*$'\n'}"
body="${probe_output%$'\n'*}"
if [ "$body" = "$probe_output" ]; then
  emit_report false "response_invalid" "$endpoint_configured" "$probe_ms"
fi

case "$http_code" in
  2??) ;;
  [0-9][0-9][0-9]) emit_report false "http_$http_code" "$endpoint_configured" "$probe_ms" ;;
  *) emit_report false "response_invalid" "$endpoint_configured" "$probe_ms" ;;
esac

state="$(printf '%s\n' "$body" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | sed -n '1p')"
case "$state" in
  ok) emit_report true "" "$endpoint_configured" "$probe_ms" ;;
  '') emit_report false "state_unknown" "$endpoint_configured" "$probe_ms" ;;
  *[!A-Za-z0-9_-]*) emit_report false "state_unknown" "$endpoint_configured" "$probe_ms" ;;
  *) emit_report false "state_$state" "$endpoint_configured" "$probe_ms" ;;
esac

exit 0
