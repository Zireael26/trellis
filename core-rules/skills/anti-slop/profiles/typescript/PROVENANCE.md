# TypeScript profile provenance

Vendored from [dmmulroy/anti-slop](https://github.com/dmmulroy/anti-slop) (MIT, vendoring
intended by the author). `LICENSE` in this directory is upstream's, retained verbatim.

| Field | Value |
|---|---|
| Upstream commit | `446268e5d15baa968eaec669ff65358d36ae6259` (2026-08-14, "Ignore agent tooling when installing anti-slop") |
| Vendored from | `src/` — upstream's `AGENTS.md` names it the canonical plugin implementation |
| `oxlint` | `1.78.0` (exact) |
| `@oxlint/plugins` | `1.78.0` (exact) |
| Rules vendored | 15, all enabled at `error` in `oxlint.config.ts` |

## What was and was not copied

- Copied: `src/index.ts`, `src/rules/*.ts`, `src/shared/*.ts` → `anti-slop/`.
- Excluded: `src/rules/*.test.ts` (~22 KB). Those are upstream's own RuleTester harness and
  need `tsx` + `typescript` dev dependencies this profile does not ship. The fixture pair in
  `fixtures/` is this profile's self-test instead.
- Excluded: upstream's `skills/install-anti-slop/` (its `assets/` copy of the same rules, plus
  an install script). The install steps below replace it; a second copy of the rules would be a
  drift surface for no gain.

## Re-sync posture (plan 037 D5)

This is an **owned fork**, not a mirror. Consequences:

1. Re-sync only deliberately — never on a schedule, never as a side effect of another task.
2. Diff by hand against a fresh upstream clone at the new SHA, rule by rule; do not overwrite
   the tree wholesale.
3. Bump the pinned pair (`oxlint` and `@oxlint/plugins` move together upstream) only together
   with the rule sources, and re-run the self-test below before the change lands.
4. Update this file's SHA, date, and version rows in the same commit as the rules.

Deliberate divergence: upstream's install skill tells the installer to query `npm view` for the
latest `oxlint`/`@oxlint/plugins` and install those. This profile pins the upstream-matched pair
instead — `jsPlugins` is a young API and a floating pin turns an upstream release into a
fleet-wide breakage. Do not "fix" the pin back to floating during a re-sync.

## Install into a project

1. Copy `anti-slop/` to `tools/oxlint/anti-slop/` in the target repo (or another path in its
   established tooling layout — then adjust the specifier and ignore pattern in step 3).
2. Add the pinned dev dependencies with the repo's own package manager:
   `oxlint@1.78.0` and `@oxlint/plugins@1.78.0`, both exact.
3. Merge `oxlint.config.ts` into the repo's existing Oxlint config — keep every existing
   ignore and rule; Vite+ projects nest the lint fields under `lint` and repeat the ignores
   under `fmt`.
4. The repo's `package.json` needs `"type": "module"`. Oxlint loads a `.ts` config through
   Node, which rejects `export default` in a CommonJS package with
   `SyntaxError: Unexpected token 'export'`.
5. Set `gate_profiles.anti_slop.posture` in the project's `.trellis.json` (`"advisory"` first).

Findings in owned source are a cleanup-session input, not a reason to weaken severity, add
suppressions, or launder types.

## Self-test

Run in a scratch directory, never inside a fleet project — it installs npm dependencies:

1. `npm init -y`, add `"type": "module"`, `npm i -D -E oxlint@1.78.0 @oxlint/plugins@1.78.0`.
2. Copy `anti-slop/` to `tools/oxlint/anti-slop/`, `oxlint.config.ts` to the root, and both
   fixtures to `src/`.
3. `npx oxlint src/red.ts` → 7 findings, exit 1. `npx oxlint src/green.ts` → 0 findings, exit 0.

Recorded 2026-08-18 at the pinned pair above: red 7 / green 0. Negative control (same red
fixture, config with no `jsPlugins`) reports 0 findings and exit 0, which is what proves the
findings come from these vendored rules rather than Oxlint's default set.

The red fixture's `Record<string, boolean>` line reports `no-known-value-widening`, not
`no-unsafe-dictionary-type` — that rule claims the annotated-literal case first. Expect the
count to shift on re-sync; the assertion that matters is red ≥ 1, green = 0.
