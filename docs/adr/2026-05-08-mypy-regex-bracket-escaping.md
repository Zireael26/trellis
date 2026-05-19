# ADR: mypy detector regex — escaped brackets are literal

## Status
Accepted (recorded 2026-05-08 per plan task P3.10)

## Context

The 2026-05-08 Trellis meta-audit's first draft flagged `stop-verify.sh`
mypy detector as a third regex defect — the audit author read
`grep -q '\[tool.mypy\]'` as a character class match. Independent verification
caught this as a fabricated finding: the brackets are escaped (`\[` and
`\]`), so they match literal `[` and `]` characters. The mypy gate is
correct. No code change.

The audit explicitly logged this as "a reason to land the bats fixture
suite proposed in P3.1: regex behavior is exactly what a fixture catches
and a human reviewer doesn't."

## Decision

Two outcomes documented as policy:

1. **No code change to `stop-verify.sh:97`.** The existing regex
   `'\[tool.mypy\]'` is correct as written.

2. **Bats fixtures matter — invest in them.** Plan task P3.1 lands a
   bats regression suite covering exactly this kind of regex behavior
   (fixtures reproduce the input strings + assert the expected match
   outcome). A fixture for `[tool.mypy]` detection should be added to
   the suite at the same time the broader stop-verify coverage lands
   (P3.1a follow-up).

## Lesson

Audit reviewers reading hook regexes can mis-classify escaped vs.
character-class behavior. Especially in shell-quoted contexts where
`\[` looks like an escape but is actually two characters that ERE then
treats as literal-`[`. Bats fixtures externalize the truth: each
fixture string + expected outcome is ground truth, not interpretation.

## Consequences

- P3.1 bats suite landed (PR #32) with stop-verify coverage. P3.1a
  follow-up will add a fixture for the mypy detector specifically.
- Future audits that flag a regex finding should be paired with a
  fixture demonstrating the failure before claiming the regex is
  broken.

## References

- `core-rules/hooks/stop-verify.sh:97`
- Audit §3.3 / §3.4 (the verifier's note about the fabricated finding)
- Plan task P3.1 + P3.1a
