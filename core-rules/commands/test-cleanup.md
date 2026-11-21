---
description: Audit and consolidate bloated, mock-only, or redundant tests in one subsystem while preserving behavioral coverage and Trellis suite-coverage invariants.
argument-hint: <subsystem-or-test-path> [--goal]
---

# Test Cleanup: $ARGUMENTS

You are running a targeted **test-diet audit and consolidation pass** on `$ARGUMENTS` (`P51`, adapted from Vincent Koc's OpenClaw subsystem-by-subsystem test cleanup for local Mac Studio and connected Linux laptop execution).

Agent-generated test suites steadily accumulate duplicate micro-tests, mock-wiring assertions, and repeated full-checkout setup ceremony. Left unchecked, net test LOC outgrows production code while missing real behavioral regressions. This command shrinks runtime and net test LOC **without** sacrificing behavioral coverage.

## Scope & Loop Safety

- **One subsystem or suite slice per pass.** Never rewrite tests across unrelated subsystems in a single unverified batch.
- When invoked with `--goal` across multiple subsystems, declare the three mandatory loop ceilings up front (`core-rules/loop-safety.md`): `max_iterations`, `no_progress_iterations`, and `budget_ceiling_usd`, and commit each green subsystem slice independently before advancing.

## Steps

### 1. Baseline timing, LOC, and coverage

1. Identify the target suite(s) and production module(s) for `$ARGUMENTS`.
2. Measure baseline wall-clock duration and line/branch coverage before editing:
   - Trellis repository suites: `bash scripts/run-tests.sh --test-file=<suite>` (or `bash scripts/run-tests.sh --changed` / `python3 scripts/lib/push-test-map.py --explain <base>..<head>`).
   - Attached project suites: run the project's test/coverage command scoped to the target directory.
3. Record baseline test count, test LOC (`wc -l`), and elapsed seconds.

### 2. Classify every test in the target slice

Group each test case into one of four dispositions:

1. **Keep (load-bearing behavioral contract):** Exercises real production code paths, boundary conditions, security/containment invariants, or regression reproducers that fail when business intent breaks.
2. **Consolidate (duplicate micro-tests → table-driven):** Multiple nearly identical tests varying only an input flag, status code, or string. Collapse into a single parameterized / table-driven test (`test.each`, `pytest.mark.parametrize`, Go table subtests, or a Bats `for` case loop) sharing one setup block.
3. **Prune (mock-only / tautological / wording-mirror):** Tests that mock the unit under test and assert mock call counts, re-assert static constants, or grep prose wording that carries no runtime contract. Delete outright or replace with one real behavioral assertion.
4. **Lighten setup (ceremony reduction, `P50`):** Tests cloning full repositories or re-initializing heavy fixtures per case when an in-memory input, shared read-only `setup_file` fixture, or stateless runner mode (Vitest `isolate: false` / Node `--test`) suffices.

### 3. Execute surgical consolidation

- Apply consolidations and deletions in small, reviewable hunks matching neighbor idioms.
- **Trellis repository invariants (non-negotiable when running inside Trellis):**
  - `scripts/tests/suite-coverage.bats`: every `scripts/tests/*.bats`, `core-rules/hooks/tests/*.bats`, `core-rules/skills/*/tests/*.bats`, `core-rules/pi/tests/*.test.mjs`, and `native/trellis-hooks/tests/*.rs` file is inventoried automatically. Prefer consolidating `@test` blocks *inside* an existing suite; if retiring an entire `.bats` file, verify nothing references it (`scripts/lib/test-suites.sh`, `scripts/lib/push-test-map.py`, `scripts/tests/stage-weights.tsv`) and run `bats scripts/tests/suite-coverage.bats`.
  - `scripts/tests/bats-conditionals-lint.bats`: never write a bare `[[ ... ]]` statement inside Bats `@test` or helper functions on Bash 3.2 — guard with `|| false`.
  - Respect the `+400` net test-LOC ratchet (`PROCESS_GATE_TEST_NET_BUDGET` in `core-rules/skills/process-gate/scripts/check-tests.sh`); a cleanup pass should produce a **negative** net test-LOC diff.

### 4. Prove discriminating power (invert-to-verify)

Green execution alone is not proof that consolidated tests still guard behavior:

1. Re-run the target suite and confirm all cases pass with equal or non-regressed behavioral coverage.
2. Temporarily invert one core production condition covered by the consolidated table test (or run `PROCESS_GATE_MUTATION_SPOTCHECK=1` against `core-rules/skills/process-gate/scripts/check-tests.sh`) and verify the consolidated test **fails**, then restore the production line.
3. Measure after-pass test count, net LOC delta (`git diff --stat`), and wall-clock speedup.

### 5. Report receipt

Emit a concise summary table:

- **Target:** `<subsystem-or-path>`
- **Cases:** `<before> → <after>` (consolidated `<M>`, pruned `<K>`)
- **Net test LOC:** `+<added> / -<deleted>` (net `-<delta>`)
- **Wall-clock:** `<before_s>s → <after_s>s`
- **Verification:** exact test + mutation/inversion command and exit code (`0`)

## What this command does NOT do

- It does not delete security, containment, or regression tests merely because they are slow — optimize their fixture setup instead, or convert combinatorial permutations to property/differential tests (`P38`).
- It does not lower coverage floors (`PROCESS_GATE_COVERAGE_FLOOR`) or disable `PROCESS_GATE_TEST_NET_BUDGET` to force a green gate.
