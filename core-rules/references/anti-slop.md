# anti-slop — evidence doctrine for generated code

Type annotations, casts and mocks are *evidence*: claims the compiler and the
next reader rely on. Slop is code that keeps the claim and drops the proof — it
compiles, it passes, and it has stopped telling the truth. This doctrine names
the patterns so a session can avoid them at generation time instead of a
reviewer finding them a week later. Generalized from
[dmmulroy/anti-slop](https://github.com/dmmulroy/anti-slop) (MIT), which is
TypeScript-only; the fleet is polyglot.

## The six principles

1. **Don't obscure evidence.** An escape-hatch type in a contract — `any`,
   `interface{}`, bare `Any` — erases what the caller is allowed to pass. Widen
   to `unknown`/`object`/a generic and narrow explicitly; the boundary of a
   function is the last place to stay vague.
2. **Don't fabricate evidence.** A cast asserts a fact the checker could not
   derive. Either derive it (a guard, a schema, a discriminated union) or state
   the invariant that makes the assertion true — never assert silently.
3. **Don't discard evidence.** `.unwrap()`, `# type: ignore` without a code, an
   unchecked assertion, a swallowed error: each throws away a signal the
   language already produced. Propagate it.
4. **Parse at boundaries.** External data (HTTP bodies, files, env, DB rows,
   IPC) is untyped until validated. Parse once at the edge into a domain type,
   then stay typed inward — do not thread raw shapes through the call graph and
   cast at the point of use.
5. **Real seams over module mocking.** Patching a module by name mocks *your
   import graph*, not a dependency, and the test then passes on code that cannot
   work. Inject the collaborator, use a fake at the seam, or hit a real local
   instance.
6. **Escape-hatch accountability.** Every remaining hatch carries its reason,
   in a uniform greppable form: `SAFETY: <invariant>` on the line or the line
   above (`//` in TS/Go/Rust, `#` in Python). No reason, no hatch.

## Pattern tables

These mirror `core-rules/hooks/lib/slop-patterns.sh` — the executable source of
truth that the turn-time tripwire, `audit-slop.sh` and the gate row all read. If
a table and the lib disagree, the lib wins; fix the table.

**TypeScript / JavaScript** (`.ts .tsx .js .jsx`)

| id | fires on | instead |
|---|---|---|
| `ts-as-any` | `as any` | narrow from `unknown`, or fix the source type |
| `ts-as-unknown-as` | `as unknown as T` | a type guard or schema parse |
| `ts-any-signature` | `: any` in a parameter or return position | `unknown` + narrowing, or a generic |
| `ts-record-literal` | `Record<string, T>` annotation on a literal | `satisfies Record<string, T>` (keeps key literals) |
| `ts-module-mock` | `vi.mock(` / `jest.mock(` | inject the dependency; fake the seam |

**Python** (`.py`)

| id | fires on | instead |
|---|---|---|
| `py-any-annotation` | `Any` in a `def` parameter or return | `object`, a `Protocol`, a `TypeVar` |
| `py-unjustified-cast` | `cast(` with no `# SAFETY:` | validate (`model_validate`, `TypeGuard`) or justify |
| `py-bare-type-ignore` | `# type: ignore` without `[code]` | `# type: ignore[code]` — narrow the suppression |
| `py-module-patch` | `patch("pkg.mod.fn")` on a dotted path | `monkeypatch.setattr` on the object, or inject |

**Go** (`.go`) — profile dormant, patterns live

| id | fires on | instead |
|---|---|---|
| `go-empty-interface` | `interface{}` / `any` in a signature | a concrete type or a type parameter |
| `go-unchecked-assert` | `x.(T)` without `, ok` or a type switch | `v, ok := x.(T)`, or `switch x.(type)` |
| `go-reflect` | any `reflect.` use | generics; reflection needs a stated reason |

**Rust** (`.rs`) — profile dormant, patterns live

| id | fires on | instead |
|---|---|---|
| `rs-unwrap` | `.unwrap()` | `?`, `ok_or`, `map_err` |
| `rs-expect` | `.expect(` | same — an `expect` message is not a proof |
| `rs-unsafe-block` | `unsafe {` with no `// SAFETY:` | document the invariant you are upholding |

Test code, generated output, fixtures, migrations, vendored trees and lockfiles
are carved out by path glob (the lib's `slop_carve_out_globs`), uniformly across
languages — grep cannot see `#[cfg(test)]` or a decorator. `.unwrap()` in a test
is idiomatic and must not nag. The JS/TS test-directory spellings are enumerated
(`__tests__/`, `__mocks__/`, `test/`, `e2e/`, `cypress/`, `playwright/`) because a
glob's `*` crosses `/`, so `**/tests/**` does not reach `src/__tests__/foo.ts`.
Globs match the **repo-relative** path: a directory name above the work-tree root
cannot silence a whole checkout.

## State a threshold as a threshold

When a requirement *is* a threshold, express the threshold in the code. Never
approach it by computing an offset from something you measured.

Measured on the fleet, 2026-08-23: a nav touch target had to be at least 44px.

```
padding: 12px  -> 40.3px   shipped, wrong
padding: 14px  -> 43.3px   "the fix", still wrong
min-height: 44px -> 44.0px  correct
```

Both padding attempts were arithmetic against the measured height of the text
box. That height is not a constant: `line-height: normal` delegates it to the
font's own metrics, and the same page measured **16.3px once and 15.3px the
next time**. So the derived value was never going to be stable, and a passing
measurement was not evidence the next measurement passes.

The oracle was not the problem — it was a real live-device profile, and it
caught both wrong answers. The problem was deriving a value where the
requirement was a constraint. Any implementation that reaches a threshold by
offset arithmetic will be re-derived wrongly the moment anything upstream
moves: a font, a line-height, a parent's box model, a browser default.

Applies well beyond CSS — timeouts, retry budgets, buffer sizes, rate limits.
If the spec says "at least N", the code says at least N.

## A receipt covers the whole matrix, or names the subset

A test command that runs part of a configured matrix and reports green is the
same defect as a green pipeline that never executed the specs: the gate reports
success for work it did not do.

Measured the same day: a project's `playwright.config.ts` defines five
projects. Local runs had only ever exercised `chromium-desktop` and
`webkit-desktop`. The 44px defect above was invisible locally and failed on
`chromium-tablet` and `webkit-mobile` — two of the three that had never run —
and the suite had already been reported green in a DoD receipt.

So: before emitting a receipt for a suite, check what the suite is *configured*
to cover and either run all of it or state the subset and why in the receipt
itself. "Tests pass" is not a claim about the matrix; "5/5 projects pass" is.
A habitual subset is the most expensive kind of green, because it is trusted.

## Report the count you verified, not the count you configured

A roster, a panel, a matrix, a fleet: the number you intended is not evidence
for the number you got. Say which one you are quoting.

Three independent instances on 2026-08-23, all in the same afternoon:

- A refuter panel of three agents reported "3/3 independent families". Two of
  the seats resolved to the same family, so the real count was two, and the
  third seat returned the second seat's prior back as corroboration.
- The guard meant to catch that reads
  `if role in cross and impl_fam and fam.get(cand["agent"]) == impl_fam:`.
  `impl_fam` is `None` whenever the implementer's name is absent from the map,
  so the conjunction short-circuits and the cross-family filter is skipped for
  *every* candidate — one unmapped name silently disables collapse checking
  across the whole panel, and the roster still reports as examined.
- A CI suite reported failure on every job. Each job had run **zero steps**:
  the account was billing-blocked. A blocked job is marked failed, so `needs:`
  dependents skip, and a PR reads as though it broke a suite that never ran.

The common shape is a component reporting on work it did not do. It is not
detectable from the report, because a healthy report and an unexamined one are
the same string. It is only detectable by asking what the number is *of*.

So: quote the verified count, and when a lookup can come back empty, make the
empty case say so out loud rather than falling through to the silent branch.
A guard that cannot check something must report that it cannot check it — the
absence of a finding is a claim, and an unmapped, unrun, or unresolved input
is not entitled to make it.

## Suppression: native syntax, mandatory reason

There is no Trellis-specific suppression marker. Use the linter's own, and put a
reason on the same or the preceding line:

- `// oxlint-disable-next-line <rule> -- <reason>`
- `# noqa: <code>  # <reason>` / `# type: ignore[<code>]  # <reason>`
- `//nolint:<linter> // <reason>`
- `#[allow(<lint>)] // <reason>`

A suppression without a reason is itself slop: it hides the evidence *and* the
decision. `SAFETY:` is the reason convention for a hatch that stays in the code;
a linter suppression is for a rule that is wrong here, and it says why.

## How this is enforced

Advisory in v1, by design — a doctrine that nags on idiomatic code trains
sessions to ignore it. Turn-time `slop-tripwire` adds one context line per hit
and never blocks (`SLOP_TRIPWIRE=off` silences it). `audit-slop.sh` enumerates a
whole repo for cleanup sessions. The process-gate row reads
`gate_profiles.anti_slop.posture` from `.trellis.json`: absent/`off` → n/a,
`advisory` → warn, `enforced` → fail. Per-language profiles ship as skill
siblings, loaded on demand.

## Upstream

The TypeScript profile vendors dmmulroy/anti-slop (MIT) as an owned fork:
snapshot, pinned `oxlint` + `@oxlint/plugins` pair, provenance note beside the
rules. Re-sync is deliberate and diffed by hand — never fetch-at-install (a
network dependency the public mirror cannot carry). The Python, Go and Rust
pattern sets are Trellis's generalization, not upstream's.
