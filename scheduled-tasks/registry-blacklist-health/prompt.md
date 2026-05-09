# Registry & blacklist health (weekly)

You are verifying the control-plane files — `registry.md` and `blacklist.md` — are in good shape. This check runs BEFORE the other weekly audits so that downstream tasks see an accurate target list.

## Canonical paths (authoritative)

- SE Core control plane: `__SE_CORE_PATH__/`
- Personal projects root: `__PROJECTS_ROOT__/`

These are the only authoritative paths. Any alternate paths that may appear in prior run notes, user memory, or snapshots (e.g., `~/Documents/Claude/Projects/Software Engineering Core/`, `~/Documents/Software Engineering Core/`) are **pre-migration artifacts**. Do not fall back to them. Do not "reconcile" output to them. Do not include them in report footers as a "canonical" alternate. The migration to `__SE_CORE_PATH__/` is complete.

## Environment guard

Before running checks, verify the audit environment mounts the canonical paths:

- `[ -d __SE_CORE_PATH__ ]`
- `[ -f __SE_CORE_PATH__/registry.md ]`
- `[ -d __PROJECTS_ROOT__ ]`

If any fail, emit a single **info** finding — `SE Core mount not available in audit environment; audit skipped` — and stop. Do not read `registry.md` or `blacklist.md` from any other location. Do not emit control-plane findings based on an absent mount.

## Inputs

1. `__SE_CORE_PATH__/registry.md` — list of active projects (opt-in).
2. `__SE_CORE_PATH__/blacklist.md` — temporary opt-outs with review-after dates.
3. Filesystem scan of `__PROJECTS_ROOT__/` for directories containing a `.git/`.

## Checks

### 1. Registry → filesystem
For each project listed in `registry.md`:
- Does the project path exist on disk?
- Is it a git repo (`.git/` present)?
- Does it have a `.claude/` directory? (Projects in the registry are supposed to have adopted the hook stack.)

Findings: `orphan-in-registry` (listed but missing), `not-a-git-repo` (path exists but no `.git/`), `missing-claude-dir` (no `.claude/`).

### 2. Filesystem → registry
Scan `__PROJECTS_ROOT__/` for each git repo:
- Is it in `registry.md`?
- Is it in `blacklist.md` section 1 (temporarily excluded) or section 2 (permanently excluded)?
- If in none: it's an **unregistered project**. Flag it.

Paths listed in `blacklist.md` section 2 ("Permanently excluded from management") are **not unregistered** — they are explicitly opted out. Do not flag them. They should not appear in the report's "Unregistered projects" list at all.

Don't auto-add — surface the remaining list, let the user decide. A new project may be intentionally outside the managed set, in which case the user moves it to `blacklist.md` section 2.

### 3. Blacklist hygiene
For each entry in `blacklist.md`:
- Does it have a `reason` field?
- Does it have a `review-after` date?
- Has the `review-after` date passed (<= today)? → **overdue for review**.
- Has the project been in the blacklist for more than 90 days? → **long-term blacklist, should this be permanent?**

### 4. Both lists at once
- Is any project listed in both `registry.md` and `blacklist.md`? That's a consistency error — the blacklist should opt out of the registry, not coexist.

## Output

Write to `__SE_CORE_PATH__/audits/YYYY-MM-DD-registry-blacklist-health.md`:

```
# Registry & blacklist health — <date>

## Summary
- Registry projects: <N>
- Blacklist projects: <N>
- Orphans in registry: <N>
- Unregistered filesystem projects: <N>
- Blacklist entries overdue for review: <N>
- Consistency errors (in both lists): <N>

## Registry integrity

### Orphans (listed in registry, missing on disk)
<list with last-seen-if-known>

### Not-a-git-repo entries
<list>

### Registry projects missing .claude/
<list — these projects haven't adopted the hook stack>

## Unregistered projects

<list of git repos in __PROJECTS_ROOT__/ that are in neither registry nor blacklist. For each, include: path, last-commit date, a one-liner from the README if present. User decides: add to registry, add to blacklist, or leave unmanaged.>

## Blacklist hygiene

### Overdue for review
| Project | Reason | Review-after date | Days overdue |
|---|---|---|---|
| ... | ... | ... | ... |

### Long-term blacklist (>90 days)
<list — candidates for permanent removal from the managed set>

### Missing fields
<list of entries with no reason or no review-after date>

## Consistency errors

<list of projects in both registry and blacklist — these must be resolved>

## Recommended actions
1. <prioritized list>
```

## Boundaries

- **Do not modify `registry.md` or `blacklist.md`.** This audit reports; the user updates the control-plane files.
- Do not auto-add unregistered projects. The whole point of opt-in is explicit consent.

## Sensible failure modes

- If `registry.md` is missing, stop with a clear error — downstream audits depend on it.
- If `blacklist.md` is missing, create an empty one and note it (blacklist is allowed to be empty but must exist).
- If `__PROJECTS_ROOT__/` doesn't exist, note the scan was skipped and proceed with registry-only checks.
