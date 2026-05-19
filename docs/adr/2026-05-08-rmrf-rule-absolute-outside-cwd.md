# ADR: rm -rf rule means "any absolute path outside cwd"

## Status
Accepted (plan decision D3, recorded 2026-05-08 per plan task P3.10)

## Context

`core-rules/hooks/block-destructive.sh` line 42 has a regex blocking
`rm -rf <target>` for certain dangerous targets. Pre-2026-05-08 the
regex was:

```
rm[[:space:]]+(-[a-zA-Z]*f[a-zA-Z]*[[:space:]]+|(-[a-zA-Z]+[[:space:]]+)*)(/|~|\$HOME|\.\.)(/|[[:space:]]|$)
```

The tail char-class `(/|[[:space:]]|$)` required the start char (`/`,
`~`, `$HOME`, `..`) to be followed by `/`, whitespace, or EOL. In
practice that meant `rm -rf /` and `rm -rf /etc` blocked, but
`rm -rf /Users/me/foo` did not.

The spec at `core-rules/hooks.md:21` was ambiguous: "rm with force flags
targeting `/`, `~`, `$HOME`, or `..`" can be read as either "rooted at
`/`" (the implementation) or "any absolute path" (the likely intent).

## Decision

The rule means **any absolute path, `~`, `$HOME`, or `..`** — not
"rooted at `/`". `rm -rf /Users/me/foo` blocks; `rm -rf .`,
`rm -rf ./build`, `rm -rf node_modules` allow.

## Rationale

- **The threat model is "rm -rf hits something the operator did not
  intend".** Absolute paths are dangerous *because* they reach outside
  the current working directory. A relative-cwd target is bounded;
  `node_modules` deletion is an annoyance, not a disaster.
- **Build scripts use relative cleanups.** `rm -rf .`, `rm -rf dist`,
  `rm -rf node_modules` are common. The rule must allow them.
- **The original regex was tighter than needed in one direction
  (rooted-at-/) and looser than needed in another (didn't catch
  `~/foo`).** The fix unifies the threat model.

## Implementation

P1.1 (PR #23) replaced the regex with:

```
rm[[:space:]]+(-[a-zA-Z]*f[a-zA-Z]*[[:space:]]+|(-[a-zA-Z]+[[:space:]]+)*)((/|~|\$HOME)[^[:space:]]*|\.\.(/[^[:space:]]*)?)([[:space:]]|$)
```

Same change in Codex copy. Spec at `hooks.md:21` rewritten to match.
Bats coverage in `core-rules/hooks/tests/block-destructive.bats` (P3.1).

## Consequences

- `rm -rf /Users/me/anything` is now blocked. Operator must run it
  manually if intentional.
- The hook can't *know* the cwd at evaluation time — it sees only the
  command string. So any absolute path is a deny; operators with a
  legitimate absolute-path use case need to bypass via direct shell
  invocation outside the agent.
- **Trade-off**: relative paths starting with `..` block too (`rm -rf
  ../foo`). Acceptable: `..` always escapes cwd; that's the behavior
  the rule wants to catch.

## References

- `core-rules/hooks/block-destructive.sh:42`
- `core-rules/codex/hooks/block-destructive.sh:43`
- `core-rules/hooks.md:21`
- Plan decision D3, plan task P1.1, PR [#23](https://github.com/__GITHUB_USER__/se-core/pull/23)
- Audit §3.3 first bullet
