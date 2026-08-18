STATUS: DORMANT — no fleet Rust project; fixtures are the only validation

# Rust profile — anti-slop

Doctrine: `core-rules/references/anti-slop.md`. Spec task: 037-anti-slop T10 (plan §4 file 12).

Dormant means no fleet project installs this, so the fixture pair is the whole truth of the
profile (spec §7: dormant-template rot is accepted, fixtures are its only guard). Unlike the Go
sibling, the lints here *were* exercised against a real Clippy — receipts below.

## What the fragment enables

| Lint | Evidence principle |
|---|---|
| `unwrap_used` | Discarded evidence — a panic replaces the error the callee handed you. |
| `expect_used` | Discarded evidence — a nicer panic message is still a panic. |
| `as_conversions` | Fabricated evidence — `as` truncates silently; `try_from` reports it. |
| `undocumented_unsafe_blocks` | Unaccounted escape hatch — state the invariant you rely on. |

All four are `warn`, matching the v1 advisory-only posture (spec §4).

## Merge into a project

1. Merge `cargo-lints-fragment.toml` into the crate's `Cargo.toml`. In a workspace, put the
   table under `[workspace.lints.clippy]` once and give every member `lints.workspace = true`.
2. Needs Rust 1.74+ — older toolchains ignore `[lints]` silently, which reads exactly like a
   clean run. Check `cargo --version` before believing a zero.
3. Set `gate_profiles.anti_slop.posture` in the project's `.trellis.json` (`"advisory"` first).
4. `post-edit-verify` and `stop-verify` already dispatch `clippy` (plan §1 D1) — the manifest
   table is what those hooks pick up, no new hook wiring.

## Test code: the carve-out does the work, not a lint exception

`.expect(` in a test is idiomatic — a test's panic *is* its failure report. Two mechanisms cover
it, and neither is a grep exception:

- **Clippy** reaches test targets only under `--all-targets`. Plain `cargo clippy` lints the
  lib/bin targets, so `#[cfg(test)]` code and `tests/` files are simply not compiled.
- **The tripwire** has no escape hatch on `rs-expect` by design; the path-glob carve-outs
  (`**/tests/**`, `**/*_test.*`) are what keep test code quiet.

That is why `fixtures/tests/parse.rs` exists: it is the `.expect(` demonstration, parked in a
path the carve-out globs actually match. `fixtures/green.rs` keeps its own `#[cfg(test)]` module
free of `unwrap`/`expect` (its tests return `Result` and use `?`), so green stays silent under
*both* mechanisms rather than only one.

If a project wants Clippy on test code too, run `--all-targets` and add
`#[allow(clippy::expect_used)]` on the test module **with a reason** — never widen the fragment.

## Self-test

- `fixtures/red.rs` — one lint per function, so inverting a lint breaks the file's expectation.
- `fixtures/green.rs` — parse at the boundary with `?`, `u32::try_from` instead of `as`, and a
  `// SAFETY:`-documented `unsafe` block.
- `fixtures/tests/parse.rs` — the carved-out integration test described above.

Reproduce in a scratch directory, never inside a project:

1. `cargo init --lib` a throwaway crate named `anti-slop-fixtures` (the integration test imports
   `anti_slop_fixtures`).
2. Prepend a `[package]` block to `cargo-lints-fragment.toml` and use it as `Cargo.toml`
   verbatim — that proves the fragment itself applies, not a hand-written flag list.
3. `green.rs` → `src/lib.rs`, `tests/parse.rs` → `tests/parse.rs`; run `cargo clippy`.
4. Swap `red.rs` → `src/lib.rs`; run `cargo clippy` again.

Recorded 2026-08-18 with cargo 1.97.1 / clippy 0.1.97:

| Check | Result |
|---|---|
| `cargo clippy` with `red.rs` as the crate root | 4 warnings — one per fragment lint, each `note`-attributed to its lint |
| `cargo clippy` with `green.rs` as the crate root | 0 warnings, exit 0 |
| `cargo clippy --all-targets`, green root | 1 warning, `expect_used` at `tests/parse.rs` — the carve-out case, as documented above |
| `cargo test` | 3 passed (2 in green's `#[cfg(test)]` module, 1 integration) |
| `slop_scan_text rs` over `red.rs` / `green.rs` | 3 hits, every `rs-*` pattern id covered / 0 hits |

The assertion that matters is red ≥ 1 and green = 0; expect the exact counts to move when the
fragment or Clippy changes.

Escape hatch: `// SAFETY: <invariant>` directly above the block — the same comment satisfies
`undocumented_unsafe_blocks` and the tripwire's `rs-unsafe-block` suppression. Suppressions use
`#[allow(...)]` and must carry a reason on the same or preceding line.
