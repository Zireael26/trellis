# source-driven-development — verify framework claims against the source

Anti-stale-pattern discipline: a decision about how a framework, library, API, or
tool behaves is verified against its **official documentation or source**, and
the verification is **cited**, before it is relied on. Folded in from the
`addyosmani/agent-skills` `source-driven-development` skill + its `sdd-cache`
hook (2026-07). It is `doubt-driven-development` specialized to the one claim
class that ages fastest: "the framework does X."

## The rule

Before you write code that depends on external behavior — a config key, a
default, a lifecycle order, a deprecation, an API signature — **check the current
official source, and cite it** (URL + the line/section, or the installed
version's own type/definition). Model recall of a framework's behavior is a
hypothesis, not a fact; frameworks change, and training data lags.

Cite inline where the decision lives:

```
// per Next.js 16 docs (nextjs.org/docs/app/api-reference/config, 2026-07): `dynamic` defaults to 'auto'
```

An uncited framework claim in a plan or a diff is a DOUBT trigger (see
`doubt-driven-development`): extract the claim, verify it against the source,
reconcile.

## The sdd-cache freshness pattern

The addyosmani `sdd-cache` hook caches a fetched doc **only after an HTTP 304
revalidation** — i.e. it never serves a cached doc it has not confirmed is still
current against the origin. The principle worth borrowing: **a cached source is
only as good as its last revalidation.** When you rely on a previously-fetched
doc, revalidate (conditional request / freshness check) rather than trusting an
old copy; a 200 means re-read, a 304 means the cache is still authoritative.
Trellis does not ship the hook, but the discipline applies to any doc-caching an
agent does within a run.

## When to use

- Framework/library/API decisions in `plan` and `execute`.
- Any "the default is…", "X is deprecated", "the signature is…" claim.
- Pairs with the `claude-api` skill's "read before answering" ethos — the same
  rule, generalized from the Anthropic API to every dependency.

Not for the project's own code (read that directly) or for stable language
built-ins. Reserve it for the fast-moving external surface.

## Relationship to other surfaces

- `doubt-driven-development` — the general primitive; this is its framework-claim specialization.
- `plan` / `execute` skills — where framework decisions are made and should carry citations.
- `deprecation-and-migration` — the flip side: when *your* code makes a promise others verify against.
