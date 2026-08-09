#!/usr/bin/env bash
# lint-recipe-routing.sh — require every orchestrate recipe agent() call to
# declare an agentType or carry an explicit main-loop inheritance reason.
#
# The embedded lexical scan blanks JavaScript strings, regular-expression
# literals, and line/block comments while preserving line numbers before it
# looks for agent(...). That is how commented-out examples (including
# template.wf.js's fan-out sample) are ignored.
# The default scan is deliberately limited to the non-recursive canonical recipe
# directory; other *.wf.js surfaces are outside this lint's scope.
#
# Usage:
#   scripts/lint-recipe-routing.sh [--list] [file-or-directory ...]
#
# With no paths, scans core-rules/skills/orchestrate/recipes/*.wf.js. Directory
# arguments are also non-recursive. --list prints one classification per call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

list_mode=false
if [ "${1:-}" = "--list" ]; then
  list_mode=true
  shift
fi

paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
  paths=("$ROOT/core-rules/skills/orchestrate/recipes")
fi

node - "$ROOT" "$list_mode" "${paths[@]}" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')

const [root, listModeText, ...inputs] = process.argv.slice(2)
const listMode = listModeText === 'true'
const markerPattern = /\/\/[ \t]*routing: inherit — [^\s].*$/

function recipeFiles(entries) {
  const files = []
  for (const entry of entries) {
    const stat = fs.statSync(entry)
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(entry).sort()) {
        const candidate = path.join(entry, name)
        if (name.endsWith('.wf.js') && fs.statSync(candidate).isFile()) files.push(candidate)
      }
    } else if (stat.isFile() && entry.endsWith('.wf.js')) {
      files.push(entry)
    }
  }
  return [...new Set(files.map((file) => path.resolve(file)))].sort()
}

function blankStringsAndComments(source) {
  const out = source.split('')
  const regexPrefixKeywords = new Set([
    'await', 'case', 'delete', 'do', 'else', 'in', 'instanceof', 'of', 'return',
    'throw', 'typeof', 'void', 'yield',
  ])
  let state = 'code'
  let canStartRegex = true

  function blank(index) {
    if (source[index] !== '\n' && source[index] !== '\r') out[index] = ' '
  }

  for (let i = 0; i < source.length; i += 1) {
    const ch = source[i]
    const next = source[i + 1]

    if (state === 'line-comment') {
      if (ch === '\n' || ch === '\r') state = 'code'
      else blank(i)
      continue
    }
    if (state === 'block-comment') {
      blank(i)
      if (ch === '*' && next === '/') {
        blank(i + 1)
        i += 1
        state = 'code'
      }
      continue
    }
    if (state !== 'code') {
      blank(i)
      if (ch === '\\') {
        if (i + 1 < source.length) {
          blank(i + 1)
          i += 1
        }
      } else if (
        (state === 'single-quote' && ch === "'")
        || (state === 'double-quote' && ch === '"')
        || (state === 'template' && ch === '`')
      ) {
        state = 'code'
        canStartRegex = false
      }
      continue
    }

    if (/\s/.test(ch)) continue

    if (ch === '/' && next === '/') {
      blank(i)
      blank(i + 1)
      i += 1
      state = 'line-comment'
      continue
    }
    if (ch === '/' && next === '*') {
      blank(i)
      blank(i + 1)
      i += 1
      state = 'block-comment'
      continue
    }
    if (ch === "'") {
      blank(i)
      state = 'single-quote'
      continue
    }
    if (ch === '"') {
      blank(i)
      state = 'double-quote'
      continue
    }
    if (ch === '`') {
      blank(i)
      state = 'template'
      continue
    }

    if (ch === '/' && canStartRegex) {
      blank(i)
      let inClass = false
      let closed = false
      for (let j = i + 1; j < source.length; j += 1) {
        const regexChar = source[j]
        blank(j)
        if (regexChar === '\n' || regexChar === '\r') break
        if (regexChar === '\\') {
          if (j + 1 < source.length) {
            blank(j + 1)
            j += 1
          }
          continue
        }
        if (regexChar === '[') inClass = true
        else if (regexChar === ']') inClass = false
        else if (regexChar === '/' && !inClass) {
          closed = true
          i = j
          while (/[A-Za-z]/.test(source[i + 1] ?? '')) {
            blank(i + 1)
            i += 1
          }
          break
        }
      }
      if (!closed) throw new Error('unterminated regular expression literal; lexical scan is unreliable')
      canStartRegex = false
      continue
    }

    if (/[A-Za-z_$]/.test(ch)) {
      let end = i + 1
      while (/[A-Za-z0-9_$]/.test(source[end] ?? '')) end += 1
      const word = source.slice(i, end)
      canStartRegex = regexPrefixKeywords.has(word)
      i = end - 1
      continue
    }
    if (/[0-9]/.test(ch)) {
      let end = i + 1
      while (/[A-Za-z0-9_.]/.test(source[end] ?? '')) end += 1
      canStartRegex = false
      i = end - 1
      continue
    }

    if (ch === ')' || ch === ']' || ch === '}') canStartRegex = false
    else if ((ch === '+' || ch === '-') && next === ch) {
      canStartRegex = false
      i += 1
    } else if (ch === '.' && source.slice(i, i + 3) !== '...') canStartRegex = false
    else if (ch === '.') {
      canStartRegex = true
      i += 2
    } else {
      canStartRegex = true
    }
  }

  if (state === 'single-quote' || state === 'double-quote' || state === 'template' || state === 'block-comment') {
    throw new Error(`unterminated ${state}; lexical scan is unreliable`)
  }
  return out.join('')
}

function lineNumberAt(source, index) {
  let line = 1
  for (let i = 0; i < index; i += 1) {
    if (source[i] === '\n') line += 1
  }
  return line
}

function matchingParen(masked, open) {
  let depth = 0
  for (let i = open; i < masked.length; i += 1) {
    if (masked[i] === '(') depth += 1
    else if (masked[i] === ')') {
      depth -= 1
      if (depth === 0) return i
    }
  }
  return -1
}

function firstArgumentComma(masked, open, close) {
  let parens = 1
  let braces = 0
  let brackets = 0
  for (let i = open + 1; i < close; i += 1) {
    const ch = masked[i]
    if (ch === '(') parens += 1
    else if (ch === ')') parens -= 1
    else if (ch === '{') braces += 1
    else if (ch === '}') braces -= 1
    else if (ch === '[') brackets += 1
    else if (ch === ']') brackets -= 1
    else if (ch === ',' && parens === 1 && braces === 0 && brackets === 0) return i
  }
  return -1
}

function displayPath(file) {
  const relative = path.relative(root, file)
  return relative !== '' && !relative.startsWith(`..${path.sep}`) && relative !== '..'
    ? relative
    : file
}

const files = recipeFiles(inputs)
let siteCount = 0
let typedCount = 0
let markedCount = 0
let missingCount = 0
let scanFailureCount = 0

for (const file of files) {
  const source = fs.readFileSync(file, 'utf8')
  let masked
  try {
    masked = blankStringsAndComments(source)
  } catch (error) {
    scanFailureCount += 1
    console.error(`fail: ${displayPath(file)} — ${error.message}`)
    continue
  }
  const rawLines = source.split('\n')
  const matcher = /\bagent\s*\(/g
  let match

  while ((match = matcher.exec(masked)) !== null) {
    siteCount += 1
    const open = match.index + match[0].lastIndexOf('(')
    const close = matchingParen(masked, open)
    const callLine = lineNumberAt(masked, match.index)
    const comma = close === -1 ? -1 : firstArgumentComma(masked, open, close)
    const optsText = comma === -1 || close === -1 ? '' : masked.slice(comma + 1, close)
    const typed = /\bagentType\s*:/.test(optsText)

    let optsLine = -1
    if (comma !== -1) {
      let optsStart = comma + 1
      while (optsStart < close && /\s/.test(masked[optsStart])) optsStart += 1
      optsLine = lineNumberAt(masked, optsStart)
    }

    const previousLineMarked = callLine > 1 && markerPattern.test(rawLines[callLine - 2] ?? '')
    const callLineMarked = markerPattern.test(rawLines[callLine - 1] ?? '')
    const optsLineMarked = optsLine > 0 && markerPattern.test(rawLines[optsLine - 1] ?? '')
    const marked = previousLineMarked || callLineMarked || optsLineMarked
    const display = displayPath(file)

    if (typed) {
      typedCount += 1
      if (listMode) console.log(`${display}:${callLine}:agentType`)
    } else if (marked) {
      markedCount += 1
      if (listMode) console.log(`${display}:${callLine}:inherit`)
    } else {
      missingCount += 1
      console.error(`fail: ${display}:${callLine} — agent() must set agentType or carry // routing: inherit — <reason> immediately above the call or on the opts line`)
      if (listMode) console.log(`${display}:${callLine}:missing`)
    }

    if (close !== -1) matcher.lastIndex = close + 1
  }
}

if (missingCount > 0 || scanFailureCount > 0) {
  console.error(`lint-recipe-routing: ${missingCount} unclassified site(s), ${scanFailureCount} scan failure(s) across ${files.length} file(s) (${siteCount} agent() call sites scanned)`)
  process.exit(1)
}

console.log(`lint-recipe-routing: clean (${files.length} files, ${siteCount} agent() call sites: ${typedCount} typed, ${markedCount} marked)`)
NODE
