# versioning — semver as a promise, the tag as source of truth

Versioning doctrine for the fleet of semver-released, public-tagged projects
Trellis manages. Folded in from the versioning half of the
`addyosmani/agent-skills` `git-workflow-and-versioning` skill (2026-07).
`process-gate` already checks that a CHANGELOG *entry exists*; this is the
missing *doctrine* behind the number.

## Semver is a promise, not a counter

`MAJOR.MINOR.PATCH` is a contract with everyone who depends on you:

- **MAJOR** — you broke the published interface. A consumer must read a migration
  note before upgrading. Never bump MAJOR silently; pair it with a migration path
  (see `deprecation-and-migration`).
- **MINOR** — you added capability, backward-compatibly. Existing callers keep working.
- **PATCH** — you fixed behavior without changing the interface.

The question that sets the bump is always *"what did I promise the consumer,"*
not *"how big did the diff feel."* A one-line change that alters a default is a
MAJOR; a thousand-line internal refactor with no interface change is a PATCH.

Pre-release (`-rc.N`, `-alpha.N`) means the promise is not yet firm — use it while
an interface is still settling, and drop the suffix when you commit to it.

## The tag is the source of truth

The released artifact is the **annotated git tag**, not the branch tip. A version
exists when it is tagged; "it's on main" is not a release. Tags are immutable —
never move a published tag to new content (cut a new one). For Trellis's
private→public model, tags are public-only (the mirror carries the released
history).

## The changelog is curated by impact, written with the change

`CHANGELOG.md` follows Keep-a-Changelog: entries grouped by **impact**, not by
commit —

- **Added** — new capability (→ MINOR)
- **Changed** — behavior change in existing capability
- **Fixed** — bug fix (→ PATCH)
- **Deprecated** — still works, slated for removal (→ signals a future MAJOR)
- **Removed** — gone (→ MAJOR)
- **Security** — a fix with a security dimension

Two rules make the changelog trustworthy: **write the entry with the change**
(in the same commit, while you remember *why* — not reconstructed at release),
and **curate by impact** (a reader scanning "Removed" must find every removal).
A changelog assembled from `git log` at release time is a commit list, not a
changelog.

## What process-gate enforces vs. what this doctrine adds

`process-gate` / `check-docs.sh` enforces the mechanical floor: a `CHANGELOG.md`
exists and was touched when code changed. This doc is the judgment the gate
cannot check — the right bump for the promise, the entry in the right impact
group, the tag as the real release. Cite it when a plan or PR involves a version
bump or a public interface change.
