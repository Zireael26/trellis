#!/usr/bin/env bash
# Shared slop pattern set + carve-out globs for the anti-slop tier.
# Sourced by hooks/slop-tripwire.sh, skills/anti-slop/scripts/audit-slop.sh and
# skills/process-gate/scripts/check-slop.sh — the ONE source those three share,
# so a tuned pattern or a new carve-out lands in every consumer at once.
#
# Spec task: 037-anti-slop T1 (pattern set v1, plan §3).
#
# Ship rules:
#   - sync-hooks.sh / sync-codex-hooks.sh copy this file alongside *.sh.
#   - onboard-project.sh seeds .claude/hooks/lib/ + .codex/hooks/lib/.
#   - Functions are prefixed slop_ (slop__ for internals) to avoid clashing
#     with consumer scripts. Bash 3.2 safe; sourcing has no side effects.
#
# Contract:
#   slop_lang_for_ext <ext>       -> ts|py|go|rs on stdout, status 1 if unknown
#   slop_lang_for_path <path>     -> same, keyed off the path's extension
#   slop_patterns_for_lang <lang> -> TSV rows: <id> <match-ERE> <suppress-ERE|->
#   slop_carve_out_globs          -> one glob per line
#   slop_path_carved_out <path>   -> status 0 when the path is carved out
#   slop_scan_text <lang>         -> scans stdin, prints <line> <id> <text>,
#                                    grep-like status (0 = matched, 1 = clean)
#
# `slop_path_carved_out` takes a REPO-RELATIVE path. It has to: the globs match
# directory names anywhere in the path, so handing it an absolute path lets a
# checkout under a `build/`, `tests/` or `vendor/` ancestor carve out the whole
# project silently. Callers that start from an absolute path (the tripwire) strip
# the work-tree root first.
#
# Detection is line-oriented ERE and deliberately grep-approximate (plan §8:
# approximations lie, which is why every consumer is advisory or warn-class).
# A row's suppress-ERE is tested against the matched line, the line before it,
# and the contiguous run of comment lines above it — that is how the uniform
# `SAFETY:` escape-hatch convention is honored even when the invariant wraps
# over several comment lines, and how a same-line `satisfies` / `, ok :=` idiom
# stays quiet.
#
# Bash only, deliberately: `slop_path_carved_out` needs a variable in a `case`
# pattern to glob, which zsh does not do without GLOB_SUBST. Test consumers in
# bash, not from an interactive shell.
# shellcheck disable=SC2034 # the SLOP_* values are consumed by the callers.

SLOP_LANGS="ts py go rs"
SLOP_DOCTRINE_REF="core-rules/references/anti-slop.md"

# --- native-engine contract ------------------------------------------------
# The pattern set above is the fallback lane. Where a profile is installed the
# native linter runs instead — but ONLY over the profile's own rules. A native
# engine invoked with the project's whole rule set reports the project's entire
# lint configuration under the anti-slop label, which double-reports findings the
# project's own lint gate already owns and manufactures the warning-fatigue
# failure the spec is designed against (spec §4 non-goal: no general slop tier).
#
# These four values are the single source for that narrowing, shared by
# skills/anti-slop/scripts/audit-slop.sh, skills/process-gate/scripts/check-slop.sh
# and doctor's hc_anti_slop_profile presence row. Keep them in step with
# skills/anti-slop/profiles/python/{ruff,mypy}-fragment.* and
# profiles/typescript/oxlint.config.ts — a rule added to a fragment and not here
# is a rule the gate never enforces.
SLOP_RUFF_RULES="ANN401,PGH004"
SLOP_MYPY_CODES="no-any-return,no-untyped-def,ignore-without-code"
# The vendored Oxlint plugin's name. It is both the marker that distinguishes an
# installed profile from any other oxlint config AND the prefix of every rule id
# the profile owns, so it narrows detection and findings with one string.
SLOP_OXLINT_PLUGIN="anti-slop"

# Config candidates per engine — the same lists in every consumer, so a row can
# never claim "profile config present" for a file the gate does not look at.
SLOP_OXLINT_CONFIGS="oxlint.config.ts oxlint.config.mts oxlint.config.cts oxlint.config.js oxlint.config.mjs oxlint.config.cjs oxlint.config.json .oxlintrc.json"
SLOP_RUFF_CONFIGS="ruff.toml .ruff.toml pyproject.toml"
SLOP_MYPY_CONFIGS="mypy.ini .mypy.ini setup.cfg pyproject.toml"

# slop_lang_for_ext <ext>
#   - the four extension groups of plan §3; anything else is out of scope for
#     the pattern set (status 1, no output) and consumers skip the file.
slop_lang_for_ext() {
  case "${1:-}" in
    ts|tsx|js|jsx) printf 'ts\n' ;;
    py) printf 'py\n' ;;
    go) printf 'go\n' ;;
    rs) printf 'rs\n' ;;
    *) return 1 ;;
  esac
}

# slop_lang_for_path <path>
#   - extension-only resolution; a dotless basename is unknown (status 1).
slop_lang_for_path() {
  local path="${1:-}" base
  base="${path##*/}"
  case "$base" in
    *.*) ;;
    *) return 1 ;;
  esac
  slop_lang_for_ext "${base##*.}"
}

# slop_patterns_for_lang <lang>
#   - tab-separated rows, one per tripwire pattern: id, match ERE, suppress ERE
#     ('-' when the pattern has no escape hatch). Order is the plan §3 order.
#   - printf reuses the 3-field format per row, so the tabs are literal and the
#     patterns stay single-quoted (no shell expansion of `$`, `\` or `*`).
slop_patterns_for_lang() {
  case "${1:-}" in
    ts)
      printf '%s\t%s\t%s\n' \
        'ts-as-any' '(^|[^A-Za-z0-9_])as[[:space:]]+any([^A-Za-z0-9_]|$)' '-' \
        'ts-as-unknown-as' '(^|[^A-Za-z0-9_])as[[:space:]]+unknown[[:space:]]+as[[:space:]]' '-' \
        'ts-any-signature' '(\([^)]*:[[:space:]]*any([^A-Za-z0-9_]|$)|\)[[:space:]]*:[[:space:]]*any([^A-Za-z0-9_]|$))' '-' \
        'ts-record-literal' ':[[:space:]]*Record<string,[[:space:]]*[A-Za-z]+>[[:space:]]*=[[:space:]]*\{' 'satisfies' \
        'ts-module-mock' '(^|[^A-Za-z0-9_])(vi|jest)\.mock\(' '-'
      ;;
    py)
      # py-any-annotation has three alternatives, not one: the single-line `def`,
      # plus the two shapes a wrapped (black-formatted) signature splits into —
      # a lone `x: Any,` parameter line and a lone `) -> Any:` return line. The
      # `=`-free anchor on the parameter alternative is what keeps an assignment
      # (`cfg: Any = load()`) out; a bare `field: Any` in a class body is an
      # escape hatch in a contract and reports on purpose.
      printf '%s\t%s\t%s\n' \
        'py-any-annotation' '(^[[:space:]]*(async[[:space:]]+)?def[[:space:]].*(:|->)[[:space:]]*Any([^A-Za-z0-9_]|$)|^[[:space:]]*\*{0,2}[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*Any[[:space:]]*,?[[:space:]]*$|^[[:space:]]*\)[[:space:]]*->[[:space:]]*Any([^A-Za-z0-9_]|$))' '-' \
        'py-unjustified-cast' '(^|[^A-Za-z0-9_.])cast\(' 'SAFETY:' \
        'py-bare-type-ignore' '#[[:space:]]*type:[[:space:]]*ignore([^[]|$)' '-'
      # The module-patch row carries a quote class, so it needs double quotes.
      printf '%s\t%s\t%s\n' \
        'py-module-patch' "(^|[^A-Za-z0-9_])(mock\.)?patch\([[:space:]]*[\"'][A-Za-z_][A-Za-z0-9_]*\." '-'
      ;;
    go)
      printf '%s\t%s\t%s\n' \
        'go-empty-interface' '(interface\{\}|^[[:space:]]*func[^(]*\(.*[[:space:]]any([,)]|[[:space:]]))' '-' \
        'go-unchecked-assert' '\.\(\*?[A-Za-z_][A-Za-z0-9_.]*\)' '(,[[:space:]]*ok[[:space:]]*:?=|\.\(type\))' \
        'go-reflect' '(^|[^A-Za-z0-9_.])reflect\.' '-'
      ;;
    rs)
      printf '%s\t%s\t%s\n' \
        'rs-unwrap' '\.unwrap\(\)' '-' \
        'rs-expect' '\.expect\(' '-' \
        'rs-unsafe-block' '(^|[^A-Za-z0-9_])unsafe[[:space:]]*\{' 'SAFETY:'
      ;;
    *) return 1 ;;
  esac
}

# slop_carve_out_globs
#   - path-glob carve-outs, uniform across languages because grep cannot see
#     `#[cfg(test)]` or a decorator (spec §5). Test code, generated code,
#     fixtures, migrations, vendored trees and lockfiles are never slop.
#   - The JS/TS test-directory spellings are enumerated rather than folded into
#     `**/tests/**`: a `*` in a `case` glob crosses '/', so `**/tests/**` does
#     NOT match `src/__tests__/foo.ts`, and `__tests__/` is exactly where
#     `vi.mock(` and `as any` legitimately live. Missing them is the
#     warning-fatigue failure persona (spec §2), not a missed finding.
#   - `**/fixtures/**` and `**/anti-slop/**` carve out deliberate-slop payloads:
#     this tier's own red fixtures, and the vendored Oxlint plugin tree that
#     PROVENANCE.md installs to `tools/oxlint/anti-slop/` — upstream code whose
#     own rule sources necessarily spell the patterns they forbid.
slop_carve_out_globs() {
  printf '%s\n' \
    '**/tests/**' \
    '**/test/**' \
    '**/__tests__/**' \
    '**/__mocks__/**' \
    '**/e2e/**' \
    '**/cypress/**' \
    '**/playwright/**' \
    '**/fixtures/**' \
    '**/*_test.*' \
    '**/*.spec.*' \
    '**/*.test.*' \
    '**/test_*.py' \
    '**/conftest.py' \
    '**/dist/**' \
    '**/build/**' \
    '**/*.gen.*' \
    '**/*_pb2.py' \
    '**/migrations/**' \
    '**/vendor/**' \
    '**/anti-slop/**' \
    '**/package-lock.json' \
    '**/pnpm-lock.yaml' \
    '**/yarn.lock' \
    '**/Cargo.lock' \
    '**/go.sum' \
    '**/poetry.lock' \
    '**/uv.lock'
}

# slop_path_carved_out <path>
#   - status 0 when the path matches a carve-out glob, 1 otherwise. Accepts
#     absolute or repo-relative paths; a relative path is probed with a leading
#     '/' so a `**/x/**` glob still anchors on the first segment.
#   - `case` globs already let `*` cross '/', so `**` collapses to `*`.
slop_path_carved_out() {
  local path="${1:-}" probe glob
  [ -n "$path" ] || return 1
  case "$path" in
    /*) probe="$path" ;;
    *) probe="/$path" ;;
  esac
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    glob="${glob//\*\*/*}"
    # shellcheck disable=SC2254 # unquoted on purpose: $glob is the pattern.
    case "$probe" in
      $glob) return 0 ;;
    esac
  done <<EOF
$(slop_carve_out_globs)
EOF
  return 1
}

# slop_scan_text <lang>
#   - reads the text to scan on stdin (a whole file, or just a diff's added
#     lines — the caller owns line accounting) and prints one finding per line:
#     <stdin-line-number>\t<pattern-id>\t<matched-text>.
#   - grep-like status: 0 when at least one pattern matched, 1 when clean, so a
#     `set -o pipefail` caller must guard the clean case (`|| true`).
#   - one awk pass over the text with the row set read first, so cost is O(text)
#     regardless of how many patterns a language carries.
slop_scan_text() {
  local lang="${1:-}"
  [ -n "$lang" ] || return 1
  awk '
    BEGIN { FS = "\t" }
    NR == FNR {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      rows++
      id[rows] = $1
      match_re[rows] = $2
      suppress_re[rows] = $3
      next
    }
    {
      for (i = 1; i <= rows; i++) {
        if ($0 !~ match_re[i]) continue
        if (suppress_re[i] != "-" \
            && ($0 ~ suppress_re[i] || prev ~ suppress_re[i] || cmt ~ suppress_re[i])) continue
        printf "%d\t%s\t%s\n", FNR, id[i], $0
        hits++
      }
      prev = $0
      # `cmt` accumulates the contiguous run of comment lines immediately above
      # the current line, so a `SAFETY:` invariant that wraps over two or three
      # comment lines still suppresses. Any non-comment line resets it — the
      # escape hatch has to sit ON the construct it justifies.
      if ($0 ~ /^[[:space:]]*(#|\/\/|\/\*|\*)/) { cmt = cmt " " $0 } else { cmt = "" }
    }
    END { exit (hits > 0 ? 0 : 1) }
  ' <(slop_patterns_for_lang "$lang") -
}

# --- self-check ------------------------------------------------------------
# `bash slop-patterns.sh --self-test` proves every row of the set still fires
# against a red sample and that an idiomatic green sample stays silent — the
# only guard against a typo'd ERE that quietly matches nothing forever.

slop__red_sample() {
  case "$1" in
    ts) cat <<'EOF'
const raw = JSON.parse(body) as any;
const widget = raw as unknown as Widget;
function apply(input: any): void {}
const table: Record<string, Widget> = {
vi.mock('./client');
EOF
      ;;
    py) cat <<'EOF'
def coerce(payload: Any) -> Widget:
def widen(payload: dict) -> Any:
def wrapped(
    payload: Any,
) -> Widget:
def widened(
    payload: dict,
) -> Any:
    return cast(Widget, payload)
value = payload["id"]  # type: ignore
mock.patch("app.client.fetch")
EOF
      ;;
    go) cat <<'EOF'
func handle(payload interface{}) error {
func widen(v any) error {
	name := payload.(Widget).Name
	ptr := payload.(*Widget)
	kind := reflect.TypeOf(payload).Kind()
EOF
      ;;
    rs) cat <<'EOF'
let widget = parse(raw).unwrap();
let name = widget.name.expect("name present");
unsafe { ptr::read(handle) };
EOF
      ;;
  esac
}

slop__green_sample() {
  case "$1" in
    ts) cat <<'EOF'
const widget: Widget = WidgetSchema.parse(JSON.parse(body));
function apply(input: unknown): void {}
const table = { alpha: widget } satisfies Record<string, Widget>;
import { createClient } from './client';
const label = value as AnyLabel;
const many = collect(rows);
EOF
      ;;
    py) cat <<'EOF'
def coerce(payload: Mapping[str, object]) -> Widget:
    return Widget.model_validate(payload)


def widen(payload: dict[str, str]) -> AnyStr:
    # SAFETY: key presence checked by model_validate above.
    return cast(Widget, payload).name


def wrapped(
    payload: Mapping[str, object],
) -> Widget:
    # SAFETY: model_validate has already rejected any payload whose shape
    # does not match, so the narrowed type holds for the whole call.
    return cast(Widget, payload)


timeout: Any = load_timeout()
value = payload["id"]  # type: ignore[index]
monkeypatch.setattr(client, "fetch", fake_fetch)
EOF
      ;;
    go) cat <<'EOF'
func handle(payload Widget) error {
	widget, ok := raw.(Widget)
	switch t := raw.(type) {
	name := manyNames[0]
	return json.Unmarshal(data, &payload)
EOF
      ;;
    rs) cat <<'EOF'
let widget = parse(raw).map_err(Error::Parse)?;
let name = widget.name.ok_or(Error::Missing)?;
// SAFETY: handle stays non-null for the caller's lifetime.
unsafe { ptr::read(handle) };
EOF
      ;;
  esac
}

# slop__shape_probes — one `<lang>|<expected-id>|<line>` row per shape that a
# whole-sample scan cannot distinguish: the red samples hit every id, so an id
# stays "covered" even when one of its ERE alternatives matches nothing. Every
# row here is a shape that WAS a blind spot; a probe that stops firing is a
# regression the sample scan would not report.
slop__shape_probes() {
  cat <<'EOF'
go|go-unchecked-assert|	ptr := raw.(*Widget)
py|py-any-annotation|    payload: Any,
py|py-any-annotation|) -> Any:
ts|ts-as-any|	const raw = JSON.parse(body) as any;
EOF
}

slop__self_test() {
  local rc=0 lang found id missing green path probe expected line got

  for lang in $SLOP_LANGS; do
    found=$(slop__red_sample "$lang" | slop_scan_text "$lang" | cut -f2 || true)
    missing=""
    for id in $(slop_patterns_for_lang "$lang" | cut -f1); do
      printf '%s\n' "$found" | grep -qx "$id" || missing="$missing $id"
    done
    if [ -n "$missing" ]; then
      echo "FAIL ${lang}: red sample missed:${missing}"
      rc=1
    else
      echo "ok   ${lang}: red sample hit every pattern"
    fi

    green=$(slop__green_sample "$lang" | slop_scan_text "$lang" || true)
    if [ -n "$green" ]; then
      echo "FAIL ${lang}: green sample tripped:"
      printf '%s\n' "$green"
      rc=1
    else
      echo "ok   ${lang}: green sample silent"
    fi
  done

  while IFS='|' read -r lang expected line; do
    [ -n "$lang" ] || continue
    got=$(printf '%s\n' "$line" | slop_scan_text "$lang" | cut -f2 || true)
    if printf '%s\n' "$got" | grep -qx "$expected"; then
      echo "ok   shape: $expected <- $line"
    else
      echo "FAIL shape: $expected did not fire on: $line"
      rc=1
    fi
  done <<EOF
$(slop__shape_probes)
EOF

  for path in tests/helpers/build.ts src/__tests__/widget.ts src/__mocks__/client.ts \
    test/setup.ts e2e/checkout.ts cypress/support/index.ts playwright/global.ts \
    src/lib/foo_test.go app/test_client.py \
    conftest.py dist/bundle.js src/schema.gen.ts proto/thing_pb2.py \
    api/migrations/0001_init.py vendor/x/y.go tools/oxlint/anti-slop/index.ts \
    profiles/typescript/fixtures/red.ts src/foo.spec.ts pnpm-lock.yaml; do
    if slop_path_carved_out "$path"; then
      echo "ok   carve-out: $path"
    else
      echo "FAIL carve-out: $path should be carved out"
      rc=1
    fi
  done

  for path in src/app/main.ts app/client.py internal/handle.go src/lib.rs; do
    if slop_path_carved_out "$path"; then
      echo "FAIL carve-out: $path should NOT be carved out"
      rc=1
    else
      echo "ok   scanned: $path"
    fi
  done

  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--self-test" ]; then
  # pipefail here on purpose: the self-check is the one place that proves the
  # grep-like status of slop_scan_text survives a strict caller's shell options.
  set -o pipefail
  slop__self_test
  exit $?
fi
