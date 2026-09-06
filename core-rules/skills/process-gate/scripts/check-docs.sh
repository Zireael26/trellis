#!/usr/bin/env bash
# Gate 5: Docs discipline — CHANGELOG, gotchas, ADR triggers.
# Usage: check-docs.sh [--range=<gitspec>]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SKILL_DIR/scripts/lib/common.sh"

pg_load_config
RANGE="$(pg_parse_range "$@")"
PROJECT_DIR="$(pg_project_dir)"
cd "$PROJECT_DIR"

worst="pass"
findings=()

# Defaults — overridable via local.config.sh
DEFAULT_CHANGELOG_PATHS=("src/" "app/" "lib/" "components/" "packages/" "scripts/" "content/")
CHANGELOG_PATHS=("${PROCESS_GATE_CHANGELOG_PATHS[@]:-${DEFAULT_CHANGELOG_PATHS[@]}}")
CHANGELOG_FILE="${PROCESS_GATE_CHANGELOG_FILE:-CHANGELOG.md}"
ADR_DIR="${PROCESS_GATE_ADR_DIR:-docs/adr}"
DEFAULT_ADR_TRIGGERS=("next.config." "middleware." "package.json" "tsconfig.json" "drizzle.config." "prisma/schema.prisma" "vite.config.")
ADR_TRIGGERS=("${PROCESS_GATE_ADR_TRIGGERS[@]:-${DEFAULT_ADR_TRIGGERS[@]}}")
PROJECT_EPM="${PROCESS_GATE_PROJECT_EPM:-}"

# Get changed files
changed_files="$(pg_diff_files "$RANGE" || true)"
# ADR triggers also consider deletions. The shared changed-file helper omits
# them because most gates cannot validate deleted content, but deleting an
# architectural manifest/config is itself an architectural change.
adr_changed_files=""
adr_diff_failed=false
case "$RANGE" in
  -*) adr_diff_failed=true ;;
  *)
    if ! adr_changed_files="$(git diff --name-only --no-renames --diff-filter=ACMRDT "$RANGE" 2>/dev/null)"; then
      adr_diff_failed=true
    fi
    ;;
esac
if $adr_diff_failed; then
  findings+=("ADR: unable to enumerate trigger paths for range '$RANGE' — verify the range and retry")
  worst="fail"
fi

# Return 0 only when a modified package.json is semantically unchanged except
# for version-value updates inside the four dependency maps, and every changed
# range admits the same semver majors. Any parser/tooling uncertainty returns 1
# so the normal ADR trigger remains fail-closed.
package_json_has_maintenance_only_changes() {
  local manifest="$1"

  command -v node >/dev/null 2>&1 || return 1

  node - "$RANGE" "$manifest" >/dev/null 2>&1 <<'NODE'
const { execFileSync } = require('node:child_process')

const [range, manifest] = process.argv.slice(2)
const dependencyMaps = new Set([
  'dependencies',
  'devDependencies',
  'optionalDependencies',
  'peerDependencies',
])

function fail() {
  process.exit(1)
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function deepEqual(left, right) {
  if (Object.is(left, right)) return true
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false
    return left.every((value, index) => deepEqual(value, right[index]))
  }
  if (!isPlainObject(left) || !isPlainObject(right)) return false

  const leftKeys = Object.keys(left).sort()
  const rightKeys = Object.keys(right).sort()
  if (!deepEqual(leftKeys, rightKeys)) return false
  return leftKeys.every((key) => deepEqual(left[key], right[key]))
}

function parseVersionToken(token, allowOperator = true) {
  const match = token.match(/^(\^|~|>=|<=|>|<|=)?(v?)(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*|[xX*]))?(?:\.(0|[1-9][0-9]*|[xX*]))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/)
  if (!match) return null

  const [, operator = '', vPrefix = '', major, minor, patch, prerelease, build] = match
  if (!allowOperator && operator) return null
  const wildcard = (part) => part === 'x' || part === 'X' || part === '*'
  if (minor !== undefined && wildcard(minor) && patch !== undefined) return null
  if ((prerelease || build) && (
    minor === undefined || patch === undefined || wildcard(minor) || wildcard(patch)
  )) return null
  if (prerelease && prerelease.split('.').some((part) => /^[0-9]+$/.test(part) && part.length > 1 && part[0] === '0')) return null

  const numericParts = [major, minor, patch]
    .filter((part) => part !== undefined && !wildcard(part))
    .map(Number)
  if (numericParts.some((part) => !Number.isSafeInteger(part))) return null

  return {
    operator,
    major,
    majorNumber: Number(major),
    minor,
    minorNumber: minor !== undefined && !wildcard(minor) ? Number(minor) : null,
    patch,
    patchNumber: patch !== undefined && !wildcard(patch) ? Number(patch) : null,
    prerelease,
    shape: [
      operator,
      vPrefix,
      minor === undefined ? 'major-only' : wildcard(minor) ? 'minor-wildcard' : 'minor',
      patch === undefined ? 'no-patch' : wildcard(patch) ? 'patch-wildcard' : 'patch',
    ].join('|'),
  }
}

function compareVersions(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] < right[index]) return -1
    if (left[index] > right[index]) return 1
  }
  return 0
}

function incrementVersion(version, part) {
  if (version[part] >= Number.MAX_SAFE_INTEGER) return null
  const incremented = [...version]
  incremented[part] += 1
  for (let index = part + 1; index < incremented.length; index += 1) {
    incremented[index] = 0
  }
  return incremented
}

function tokenVersion(token) {
  return [token.majorNumber, token.minorNumber ?? 0, token.patchNumber ?? 0]
}

function tokenHasWildcard(token) {
  const wildcard = (part) => part === 'x' || part === 'X' || part === '*'
  return wildcard(token.minor) || wildcard(token.patch)
}

function tokenInterval(token) {
  const version = tokenVersion(token)
  const wildcard = (part) => part === 'x' || part === 'X' || part === '*'
  const minorMissing = token.minor === undefined
  const patchMissing = token.patch === undefined
  const minorPartial = minorMissing || wildcard(token.minor)
  const patchPartial = patchMissing || wildcard(token.patch)

  if (token.prerelease || (token.operator && tokenHasWildcard(token))) return null

  switch (token.operator) {
    case '':
    case '=':
      if (minorPartial) {
        const upper = incrementVersion(version, 0)
        return upper && { lower: { version, inclusive: true }, upper: { version: upper, inclusive: false } }
      }
      if (patchPartial) {
        const upper = incrementVersion(version, 1)
        return upper && { lower: { version, inclusive: true }, upper: { version: upper, inclusive: false } }
      }
      return {
        lower: { version, inclusive: true },
        upper: { version, inclusive: true },
      }
    case '^': {
      let upper
      if (token.majorNumber > 0 || minorMissing) {
        upper = incrementVersion(version, 0)
      } else if (token.minorNumber > 0 || patchMissing) {
        upper = incrementVersion(version, 1)
      } else {
        upper = incrementVersion(version, 2)
      }
      return upper && { lower: { version, inclusive: true }, upper: { version: upper, inclusive: false } }
    }
    case '~': {
      const upper = incrementVersion(version, minorMissing ? 0 : 1)
      return upper && { lower: { version, inclusive: true }, upper: { version: upper, inclusive: false } }
    }
    case '>=':
      return { lower: { version, inclusive: true }, upper: null }
    case '>':
      if (minorMissing) {
        const lower = incrementVersion(version, 0)
        return lower && { lower: { version: lower, inclusive: true }, upper: null }
      }
      if (patchMissing) {
        const lower = incrementVersion(version, 1)
        return lower && { lower: { version: lower, inclusive: true }, upper: null }
      }
      return { lower: { version, inclusive: false }, upper: null }
    case '<':
      return { lower: null, upper: { version, inclusive: false } }
    case '<=':
      if (minorMissing) {
        const upper = incrementVersion(version, 0)
        return upper && { lower: null, upper: { version: upper, inclusive: false } }
      }
      if (patchMissing) {
        const upper = incrementVersion(version, 1)
        return upper && { lower: null, upper: { version: upper, inclusive: false } }
      }
      return { lower: null, upper: { version, inclusive: true } }
    default:
      return null
  }
}

function hyphenInterval(tokens) {
  const [lowerToken, upperToken] = tokens
  if (
    tokens.some((token) => token.operator || tokenHasWildcard(token) || token.prerelease)
  ) return null

  const lower = { version: tokenVersion(lowerToken), inclusive: true }
  const upperVersion = tokenVersion(upperToken)
  if (upperToken.minor === undefined) {
    const upper = incrementVersion(upperVersion, 0)
    return upper && { lower, upper: { version: upper, inclusive: false } }
  }
  if (upperToken.patch === undefined) {
    const upper = incrementVersion(upperVersion, 1)
    return upper && { lower, upper: { version: upper, inclusive: false } }
  }
  return { lower, upper: { version: upperVersion, inclusive: true } }
}

function mergeLower(current, candidate) {
  if (!candidate) return current
  if (!current) return candidate
  const comparison = compareVersions(candidate.version, current.version)
  if (comparison > 0) return candidate
  if (comparison < 0) return current
  return { version: current.version, inclusive: current.inclusive && candidate.inclusive }
}

function mergeUpper(current, candidate) {
  if (!candidate) return current
  if (!current) return candidate
  const comparison = compareVersions(candidate.version, current.version)
  if (comparison < 0) return candidate
  if (comparison > 0) return current
  return { version: current.version, inclusive: current.inclusive && candidate.inclusive }
}

function alternativeHasSatisfyingVersion(tokens, separator) {
  if (tokens.some(({ prerelease }) => prerelease)) {
    return separator === ' ' && tokens.length === 1 && tokens[0].operator === '' &&
      tokens[0].minorNumber !== null && tokens[0].patchNumber !== null
  }

  const intervals = separator === ' - '
    ? [hyphenInterval(tokens)]
    : tokens.map(tokenInterval)
  if (intervals.some((interval) => interval === null)) return false

  let lower = null
  let upper = null
  for (const interval of intervals) {
    lower = mergeLower(lower, interval.lower)
    upper = mergeUpper(upper, interval.upper)
  }

  let candidate = lower ? lower.version : [0, 0, 0]
  if (lower && !lower.inclusive) {
    candidate = incrementVersion(candidate, 2)
    if (!candidate) return false
  }
  if (!upper) return true

  const comparison = compareVersions(candidate, upper.version)
  return comparison < 0 || (comparison === 0 && upper.inclusive)
}

function majorCoverage(tokens, separator) {
  if (tokens.some(({ majorNumber }) => !Number.isSafeInteger(majorNumber))) return null

  if (separator === ' - ') {
    const [lower, upper] = tokens
    if (lower.majorNumber > upper.majorNumber) return null
    return `${lower.majorNumber}:${upper.majorNumber}`
  }

  let lowerMajor = 0
  let upperMajor = Infinity
  for (const token of tokens) {
    const { operator, majorNumber, minor, patch, prerelease } = token
    const wildcard = (part) => part === 'x' || part === 'X' || part === '*'

    // Comparator wildcards and prerelease bounds have npm-specific expansion
    // rules. Treat changes involving them as parser uncertainty instead of
    // guessing and accidentally widening the maintenance carve-out.
    if (operator && ((minor !== undefined && wildcard(minor)) || (patch !== undefined && wildcard(patch)) || prerelease)) {
      return null
    }

    switch (operator) {
      case '':
      case '=':
      case '^':
      case '~':
        lowerMajor = Math.max(lowerMajor, majorNumber)
        upperMajor = Math.min(upperMajor, majorNumber)
        break
      case '>':
        lowerMajor = Math.max(lowerMajor, minor === undefined ? majorNumber + 1 : majorNumber)
        break
      case '>=':
        lowerMajor = Math.max(lowerMajor, majorNumber)
        break
      case '<': {
        const startsMajor = minor === undefined ||
          (minor === '0' && (patch === undefined || patch === '0'))
        upperMajor = Math.min(upperMajor, startsMajor ? majorNumber - 1 : majorNumber)
        break
      }
      case '<=':
        upperMajor = Math.min(upperMajor, majorNumber)
        break
      default:
        return null
    }
  }

  if (lowerMajor > upperMajor) return null
  return `${lowerMajor}:${upperMajor === Infinity ? 'infinity' : upperMajor}`
}

function parseSemverSpecifier(value) {
  if (typeof value !== 'string') return null

  let source = value.trim()
  let protocol = ''
  if (source.startsWith('workspace:')) {
    protocol = 'workspace:'
    source = source.slice(protocol.length)
  } else if (source.startsWith('npm:')) {
    const versionSeparator = source.lastIndexOf('@')
    if (versionSeparator <= 'npm:'.length) return null
    const alias = source.slice('npm:'.length, versionSeparator)
    const packagePart = '[a-z0-9][a-z0-9._~-]*'
    const packageName = new RegExp(`^(?:${packagePart}|@${packagePart}/${packagePart})$`)
    if (!packageName.test(alias)) return null
    protocol = source.slice(0, versionSeparator + 1)
    source = source.slice(versionSeparator + 1)
  }

  const alternatives = source.split(/\s*\|\|\s*/)
  if (alternatives.some((alternative) => alternative.length === 0)) return null

  const parsedAlternatives = []
  for (const alternative of alternatives) {
    const hyphenRange = alternative.split(/\s+-\s+/)
    let tokens
    let separator
    if (hyphenRange.length === 2) {
      tokens = hyphenRange.map((token) => parseVersionToken(token, false))
      separator = ' - '
    } else if (hyphenRange.length === 1) {
      tokens = alternative.trim().split(/\s+/).map((token) => parseVersionToken(token))
      separator = ' '
    } else {
      return null
    }
    if (tokens.length === 0 || tokens.some((token) => token === null)) return null
    if (!alternativeHasSatisfyingVersion(tokens, separator)) return null
    const coverage = majorCoverage(tokens, separator)
    if (coverage === null) return null
    parsedAlternatives.push({ tokens, separator, coverage })
  }

  return {
    majors: parsedAlternatives.flatMap(({ tokens }) => tokens.map(({ major }) => major)).join('|'),
    coverage: parsedAlternatives.map(({ coverage }) => coverage).join(' || '),
    shape: [
      protocol,
      ...parsedAlternatives.map(({ tokens, separator }) =>
        tokens.map(({ shape }) => shape).join(separator),
      ),
    ].join(' || '),
  }
}

let raw
try {
  raw = execFileSync(
    'git',
    ['diff', '--raw', '-z', '--no-renames', '--abbrev=40', range, '--', manifest],
    { encoding: 'utf8' },
  )
} catch {
  fail()
}

const record = raw.split('\0').filter(Boolean)
if (record.length !== 2 || record[1] !== manifest) fail()
const metadata = record[0].trim().split(/\s+/)
if (metadata.length !== 5 || metadata[4] !== 'M') fail()

let before
let after
try {
  before = JSON.parse(execFileSync('git', ['cat-file', 'blob', metadata[2]], { encoding: 'utf8' }))
  after = JSON.parse(execFileSync('git', ['cat-file', 'blob', metadata[3]], { encoding: 'utf8' }))
} catch {
  fail()
}
if (!isPlainObject(before) || !isPlainObject(after)) fail()

const topLevelKeys = new Set([...Object.keys(before), ...Object.keys(after)])
for (const key of topLevelKeys) {
  if (dependencyMaps.has(key)) continue
  if (!deepEqual(before[key], after[key])) fail()
}

for (const mapName of dependencyMaps) {
  const oldMap = before[mapName]
  const newMap = after[mapName]
  if (oldMap === undefined && newMap === undefined) continue
  if (!isPlainObject(oldMap) || !isPlainObject(newMap)) fail()

  const oldNames = Object.keys(oldMap).sort()
  const newNames = Object.keys(newMap).sort()
  if (!deepEqual(oldNames, newNames)) fail()

  for (const name of oldNames) {
    if (oldMap[name] === newMap[name]) continue
    const oldSpecifier = parseSemverSpecifier(oldMap[name])
    const newSpecifier = parseSemverSpecifier(newMap[name])
    if (!oldSpecifier || !newSpecifier) fail()
    if (
      oldSpecifier.majors !== newSpecifier.majors ||
      oldSpecifier.coverage !== newSpecifier.coverage ||
      oldSpecifier.shape !== newSpecifier.shape
    ) fail()
  }
}
NODE
}

# --- Changelog presence ----------------------------------------------------
if [ ! -f "$CHANGELOG_FILE" ]; then
  findings+=("$CHANGELOG_FILE: missing — seed via Keep a Changelog 1.1.0 format")
  worst="fail"
else
  # Did any code-trigger path change?
  code_changed=false
  for f in $changed_files; do
    for prefix in "${CHANGELOG_PATHS[@]}"; do
      case "$f" in
        "$prefix"*) code_changed=true; break 2 ;;
      esac
    done
  done

  if $code_changed; then
    if ! printf "%s\n" "$changed_files" | grep -Fxq "$CHANGELOG_FILE"; then
      findings+=("$CHANGELOG_FILE: not updated despite code changes under: ${CHANGELOG_PATHS[*]}")
      worst="fail"
    else
      # Invariant: a touched changelog must add a new '- ' bullet or '### ' impact subhead;
      # whitespace/heading-only touches do not count. WARN only (never fail) — advisory, and
      # a diff hiccup must not wedge the gate. Doctrine: core-rules/references/versioning.md.
      if ! git diff "$RANGE" -- "$CHANGELOG_FILE" 2>/dev/null | grep -Eq '^\+[[:space:]]*(- |### )'; then
        findings+=("$CHANGELOG_FILE: touched but no new entry added — add a '- ' bullet under the right impact group (Added/Changed/Fixed/Deprecated/Removed/Security); see core-rules/references/versioning.md")
        [ "$worst" = "pass" ] && worst="warn"
      fi
    fi
  fi
fi

# --- ADR triggers ----------------------------------------------------------
adr_trigger_changed=false
while IFS= read -r f; do
  [ -n "$f" ] || continue
  for trigger in "${ADR_TRIGGERS[@]}"; do
    case "$f" in
      *"$trigger"*)
        if [ "$trigger" = "package.json" ]; then
          case "$f" in
            package.json|*/package.json)
              package_json_has_maintenance_only_changes "$f" && continue
              ;;
          esac
        fi
        adr_trigger_changed=true
        break 2
        ;;
    esac
  done
done <<< "$adr_changed_files"

if $adr_trigger_changed; then
  # Either a new/modified file in $ADR_DIR, OR a commit body referencing an existing ADR
  adr_diff="$(printf "%s\n" "$changed_files" | grep -E "^${ADR_DIR}/" || true)"
  body_ref="$(git log --format='%B' "$RANGE" 2>/dev/null | grep -oE 'ADR-[0-9]+' | head -1 || true)"
  if [ -z "$adr_diff" ] && [ -z "$body_ref" ]; then
    findings+=("ADR: trigger paths changed without new/updated ADR or commit-body reference")
    worst="fail"
  fi
fi

# --- gotchas.md hint -------------------------------------------------------
gotcha_phrases='turns out|surprised|took two hours|weird interaction|incompatible with|silently'
if git log --format='%B' "$RANGE" 2>/dev/null | grep -qiE "$gotcha_phrases"; then
  if ! printf "%s\n" "$changed_files" | grep -qE '^gotchas\.md$'; then
    findings+=("gotchas.md: commit message hints suggest a gotcha entry might be useful (warn only)")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

# --- Project EPM -----------------------------------------------------------
if [ -n "$PROJECT_EPM" ] && [ -f "$PROJECT_EPM" ]; then
  process_change=false
  for f in $changed_files; do
    case "$f" in
      .husky/*|.githooks/*|.claude/hooks/*|.claude/skills/*) process_change=true; break ;;
    esac
  done
  if $process_change && ! printf "%s\n" "$changed_files" | grep -qF "$PROJECT_EPM"; then
    findings+=("$PROJECT_EPM: process trigger paths changed without EPM update")
    [ "$worst" = "pass" ] && worst="warn"
  fi
fi

case "$worst" in
  pass) pg_log pass "Docs discipline (range=$RANGE)" ;;
  warn) pg_log warn "Docs discipline (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
  fail) pg_log fail "Docs discipline (range=$RANGE)"; for f in "${findings[@]}"; do pg_finding "$f"; done ;;
esac

pg_exit_code "$worst"
