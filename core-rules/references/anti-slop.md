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
