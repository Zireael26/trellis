#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
RECIPES_DIR="$REPO/core-rules/skills/orchestrate/recipes"

@test "recipe bodies do not read stripped meta and mirrors match its literal values" {
  run node - "$RECIPES_DIR" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const recipesDir = process.argv[2]
const recipePaths = fs.readdirSync(recipesDir)
  .filter((name) => name.endsWith('.wf.js'))
  .sort()
  .map((name) => path.join(recipesDir, name))

function fail(file, message) {
  console.error(path.basename(file) + ': ' + message)
  process.exit(1)
}

function findMetaDeclaration(source, file) {
  const declaration = /(^|\n)[ \t]*export[ \t]+const[ \t]+meta[ \t]*=[ \t]*\{/
  const match = declaration.exec(source)
  if (!match) fail(file, 'export const meta literal not found')

  const open = match.index + match[0].length - 1
  let depth = 0
  let context = null
  let close = -1

  for (let index = open; index < source.length; index += 1) {
    const char = source[index]
    const next = source[index + 1]

    if (context === '//') {
      if (char === '\n') context = null
      continue
    }
    if (context === '/*') {
      if (char === '*' && next === '/') { context = null; index += 1 }
      continue
    }
    if (context) {
      if (char === '\\') { index += 1; continue }
      if (char === context) context = null
      continue
    }

    if (char === '/' && next === '/') { context = '//'; index += 1; continue }
    if (char === '/' && next === '*') { context = '/*'; index += 1; continue }
    if (char === "'" || char === '"' || char === '`') { context = char; continue }
    if (char === '{') depth += 1
    if (char === '}') {
      depth -= 1
      if (depth === 0) { close = index; break }
    }
  }

  if (close < 0) fail(file, 'unterminated meta literal')
  let end = close + 1
  if (source[end] === ';') end += 1
  const start = match.index + (match[1] ? match[1].length : 0)
  return { start, end, literal: source.slice(open, close + 1) }
}

function evaluateLiteral(expression, file, label) {
  try {
    return vm.runInNewContext('(' + expression.trim() + ')', Object.create(null), { timeout: 100 })
  } catch (error) {
    fail(file, 'could not parse ' + label + ': ' + error.message)
  }
}

for (const file of recipePaths) {
  const source = fs.readFileSync(file, 'utf8')
  const declaration = findMetaDeclaration(source, file)
  const meta = evaluateLiteral(declaration.literal, file, 'meta literal')
  const body = source.slice(0, declaration.start) + source.slice(declaration.end)
  const nonCommentBody = body.split('\n')
    .filter((line) => !line.trimStart().startsWith('//'))
    .join('\n')

  if (/\bmeta\s*\./.test(nonCommentBody)) {
    fail(file, 'body dereferences meta outside a full-line comment; the Workflow engine strips meta')
  }

  const requiresMirrors = /\bfunction\s+resolveMutationParallelism\s*\(/.test(nonCommentBody)
  const hasAnyMirror = /\bconst\s+(?:RECIPE_NAME|SAFETY_MAX_ITERATIONS|SAFETY_BUDGET_CEILING_USD)\s*=/.test(nonCommentBody)
  if (!requiresMirrors && !hasAnyMirror) continue

  const afterMeta = source.slice(declaration.end)
  const mirrors = afterMeta.match(/^\s*(?:(?:\/\/[^\n]*)\n)*const RECIPE_NAME = ([^\n]+)\nconst SAFETY_MAX_ITERATIONS = ([^\n]+)\nconst SAFETY_BUDGET_CEILING_USD = ([^\n]+)(?:\n|$)/)
  if (!mirrors) {
    fail(file, 'mirror constants must be declared together immediately after meta')
  }

  const actual = {
    name: evaluateLiteral(mirrors[1], file, 'RECIPE_NAME'),
    maxIterations: evaluateLiteral(mirrors[2], file, 'SAFETY_MAX_ITERATIONS'),
    budgetCeilingUsd: evaluateLiteral(mirrors[3], file, 'SAFETY_BUDGET_CEILING_USD'),
  }
  const expected = {
    name: meta.name,
    maxIterations: meta.safety?.max_iterations,
    budgetCeilingUsd: meta.safety?.budget_ceiling_usd,
  }

  for (const key of Object.keys(expected)) {
    if (!Object.is(actual[key], expected[key])) {
      fail(file, key + ' mirror mismatch: expected ' + String(expected[key]) + ', got ' + String(actual[key]))
    }
  }
}
NODE
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
  fi
  [ "$status" -eq 0 ]
}
