---
description: Audit all primers — check pinned SHAs, verify referenced files exist, surface stale ones
argument-hint:
---

# Primer audit

You are auditing every primer in `<canonical-root>/.claude/primers/` to surface staleness before it bites. This is a fast structural check, not a content review.

## Steps

### 0. Resolve the canonical project root

Run `git rev-parse --git-common-dir` and take its parent — that is the canonical repo root. All primer file operations happen at `<canonical-root>/.claude/primers/`. Same pattern as the three context-log hooks (see `gotchas.md` 2026-05-11 entry).

### 1. Enumerate primers

List all `*.md` files under `<canonical-root>/.claude/primers/` except `INDEX.md`. If the directory doesn't exist or only contains `INDEX.md`, report that and exit cleanly — "no primers, nothing to audit".

### 2. For each primer, check

Run these checks in order. The goal is fast triage — don't read full primer contents unless something fails.

**a. Frontmatter sanity.** The primer must have:
- `pinned_to: <sha>` (40-char or short SHA)
- `slug: <feature-slug>` matching the filename
- A `purpose:` line under 200 characters

Missing or malformed frontmatter → flag as `BROKEN`.

**b. Pinned SHA reachable.** `git cat-file -e <sha>^{commit}` — failure means the SHA was rebased or force-pushed away. Flag as `UNREACHABLE_PIN`.

**c. Entry points exist.** Parse the `## Entry points` section. For each file path listed, run `test -e <path>`. Missing files → flag as `MISSING_PATHS` and list which.

**d. Drift volume since pin.** Run `git rev-list --count <pinned_sha>..HEAD -- <entry-point files>` to count commits touching entry points since the pin. Bucket:
- 0 commits → `FRESH`
- 1–10 commits → `WARM`
- 11+ commits → `STALE`

**e. INDEX consistency.** Verify every primer file has a line in `INDEX.md`, and every line in `INDEX.md` points to an existing primer file. Flag mismatches as `INDEX_DRIFT`.

### 3. Report

Output a compact table. Group by status, most-broken first:

```
BROKEN          —  primer-x         (no pinned_to frontmatter)
UNREACHABLE_PIN —  primer-y         (sha abc1234 not in repo)
MISSING_PATHS   —  primer-z         (src/old/foo.py, src/old/bar.py)
INDEX_DRIFT     —  primer-w         (file exists but not in INDEX)
STALE           —  primer-a         (47 commits since pin)
WARM            —  primer-b         (3 commits since pin)
FRESH           —  primer-c, ...

Suggested actions:
- BROKEN/UNREACHABLE_PIN/MISSING_PATHS: run /primer-refresh, may need full /primer rewrite
- STALE: run /primer-refresh when next working in this area
- WARM: probably fine, refresh opportunistically
- FRESH: nothing to do
```

### 4. Do not auto-fix

This command reports only. The user decides what to refresh, and refreshes happen through `/primer-refresh` so they can confirm changes.

## Constraints

- Do not modify any primer file.
- Do not modify INDEX.md (even if it has drift — surface, don't fix).
- Cap report length. If there are 50+ primers, summarize counts and show only the non-FRESH ones in detail.
- This should be fast. If a check is taking long (e.g., entry-points list is huge), skip it for that primer and note the skip.

<!--
Canonical-root lineage: `git rev-parse --git-common-dir`, parallel to
`_se_repo_root` in `core-rules/hooks/lib/deps.sh`.
-->
