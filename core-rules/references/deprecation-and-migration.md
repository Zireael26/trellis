# deprecation-and-migration — code is a liability, remove it on purpose

The lifecycle discipline Trellis lacked: how code is *retired*, not just added.
Folded in from the `addyosmani/agent-skills` `deprecation-and-migration` skill
(2026-07), and validated by the mid-2026 "build to last vs build to replace"
trend — churn is high, so removal has to be a first-class, safe operation.

## Code is a liability

Every line shipped is a line to maintain, secure, and reason about. Value is in
what code *does*, not in its existence, so the default posture toward code that
no longer earns its keep is **remove it** — not keep it "just in case." Dead code
is not free; it is a standing tax and a hiding place for bugs.

## Deprecate at design time

When you add a replacement for something, decide *then* how the old thing dies —
do not leave it for a future cleanup that never comes. At the moment you
introduce the new path:

1. Mark the old path deprecated (a `Deprecated` changelog entry, a code
   annotation, a doc note) with **what to use instead**.
2. Name the removal condition — a version (`removed in 2.0`), a date, or a
   migration milestone. "Deprecated forever" is just clutter with a label.
3. Provide the migration path: the mechanical steps (or codemod) a consumer runs
   to move off it.

Deprecation is a promise with a deadline, backed by semver: a `Deprecated` entry
signals a future MAJOR; the actual `Removed` lands in that MAJOR (see
`versioning.md`).

## The Churn Rule

Before building something new to replace something old, ask whether the churn is
worth it — a rewrite that replaces working code carries the full cost of
re-verification, migration, and lost battle-testing. Build-to-replace is
sometimes right, but it is a *decision with a cost*, not a default. When you do
choose it, the old code's removal is part of the same plan, not a someday.

## Migration is verified, not assumed

A migration path is a claim ("consumers can move off X by doing Y") — so it is
subject to `doubt-driven-development`: actually run the migration on a real
consumer (or a representative fixture) before declaring the old path safe to
remove. An unverified migration is how a "backward-compatible" removal breaks
production.

## When to use

- Any change that supersedes an existing interface, module, config, or pattern.
- Fleet-wide removals (a retired hook, a renamed doc — Trellis's own
  `DELIST_PRUNE` prune of de-listed mirror paths is this doctrine applied to
  the framework itself).
- Cite it in `plan` whenever the change list includes a "remove" or "replace."

## Relationship to other surfaces

- `versioning.md` — deprecation signals a MAJOR; removal lands in one.
- `doubt-driven-development` — the migration path is a claim to verify.
- `edit safety` (`core-rules/CLAUDE.md`) — never delete a file without verifying
  nothing references it; this doc is the *why* and the lifecycle around that rule.
