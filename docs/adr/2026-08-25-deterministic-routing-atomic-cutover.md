# ADR: keep deterministic routing as one atomic cutover

**Status:** Accepted
**Date:** 2026-08-25

## Context

OMP routing previously had two independent selectors: Trellis role prose/quota chains and OMP's generic retry fallback. That allowed an explicit `cheap`/Muse request to execute as DeepSeek and return 401 while the request label still said `cheap`; bounded first-pass reviews also defaulted to the Sol reviewer.

The replacement changes one contract across the catalog, resolver, tests, operating policy, and rendered configuration. The committed pre-ADR diff is 2,024 changed lines. The resolver is 796 changed lines by itself, fixture-driven Bats coverage is 456 added lines, and the accepted spec/plan/tasks/analyze artifacts are 319 added lines.

Splitting at the 800-line PR cap would create an unsafe intermediate state:

- The new `roles.json` removes provider/model duplication from role chains and moves family facts into the central per-agent catalog. The old resolver requires provider/model on each chain row and a separate family map, so catalog and resolver cannot land independently.
- Landing the classifier before its regression suite would leave exact-agent, family, quota, and runtime-mismatch behavior unguarded.
- Landing policy/configuration separately would either leave generic model fallback active after classification exists or disable fallback before a compatible pre-dispatch selector is available.
- A temporary compatibility shim would create the second routing authority this cutover removes and would violate the clean-cutover requirement.

## Decision

Land the deterministic routing change as one feature PR containing:

1. the accepted spec triad and analyze receipt;
2. the central agent catalog and integrated resolver classifier;
3. fixture-driven classifier and compatibility regressions;
4. foreman/delegation policy plus global and rendered-project OMP templates; and
5. the incident, decision, and changelog records.

Do not include the unfinished Usage Federation branch or fleet mutations in this PR. Release installation and fleet adoption remain post-merge operations with separate receipts.

## Consequences

- Review surface exceeds the generic 800-line cap, but no incompatible catalog, untested selector, or fallback-enabled transition reaches `main`.
- Risk is bounded by the targeted routing suite, independent cross-family audit, and full process/security gate.
- Rollback remains one coherent operation: restore the saved OMP configuration and reactivate/adopt the previously verified rc.32 release.
- Future routing changes should remain below the cap when they do not alter the catalog schema and dispatch/acceptance boundary together.
