STATUS: DORMANT — no fleet Go project; fixtures are the only validation

# Go profile — anti-slop

Doctrine: `core-rules/references/anti-slop.md`. Spec task: 037-anti-slop T10 (plan §4 file 12).

Dormant means nothing here has run against a real project, and `golangci-lint` was not
available when it was authored. The fixture pair is the whole truth of this profile — the
first project to activate it is doing the verification, not inheriting it (spec §7:
dormant-template rot is accepted, fixtures are its only guard).

## What the fragment enables

| Linter | Evidence principle |
|---|---|
| `forcetypeassert` | Discarded evidence — `x.(T)` with no `, ok` panics instead of reporting. |
| `errcheck` (`check-type-assertions`, `check-blank`) | Discarded evidence — an unchecked error is a failure the caller never sees. |
| `forbidigo` (`^reflect\.`, `^any$`) | Obscured evidence — runtime shape inspection, and `any` in a contract. |

## Merge into a project

1. Merge `golangci-fragment.yml` into the repo's own `.golangci.yml` — add to `linters.enable`
   and `linters.settings`, keep every linter and setting already there. Never ship the fragment
   as the whole config.
2. The fragment is golangci-lint **v2** schema. On v1, move the settings to top-level
   `linters-settings` and rename forbidigo's `pattern:` to `p:`.
3. Set `gate_profiles.anti_slop.posture` in the project's `.trellis.json` (`"advisory"` first).
4. `post-edit-verify` and `stop-verify` already dispatch `golangci-lint` per touched file and
   repo-wide (plan §1 D1) — no new hook wiring, the config is what those hooks discover.

## Activation checklist — do these before trusting the fragment

1. **Probe the two `forbidigo` rows.** `forbidigo` matches identifiers in *expression*
   position. `^reflect\.` should hold. `^any$` against the `any` in a parameter list is a
   hypothesis, and `interface{}` is an `InterfaceType` AST node rather than an ident, so it is
   very likely not reached at all. Run the fragment over `fixtures/red.go` and count: the
   `interface{}` parameter on `Store` is the row that will show the gap.
2. If a signature-position row does not fire, do not weaken the doctrine to match the tool —
   route that pattern to review (the tripwire's `go-empty-interface` already reports it at
   turn-time) or find a linter that sees types, and record what you chose in this file.
3. Re-run the fixture pair and replace the receipts below with real `golangci-lint` numbers.

## Self-test

Fixtures are a `package fixtures` pair, compiled together:

- `fixtures/red.go` — one slop pattern per function, so inverting a rule breaks the file's
  expectation. Expect ≥1 finding per function.
- `fixtures/green.go` — parse-at-the-boundary, a checked `, ok` assertion, a type switch, and a
  behavioural (not empty) interface. Expect 0 findings.

Recorded 2026-08-18, without `golangci-lint`:

| Check | Result |
|---|---|
| `slop_scan_text go` over `red.go` | 7 hits, every `go-*` pattern id covered |
| `slop_scan_text go` over `green.go` | 0 hits |
| `go build ./...` (go1.26.5) | exit 0 |
| `go vet ./...` | exit 0 — `vet` catches none of these, which is why the linter is needed |
| `golangci-lint run` | **not run — toolchain absent** |

Escape hatch: `// SAFETY: <invariant>` above the line. Suppressions use `//nolint:<linter>` and
must carry a reason on the same or preceding line.
