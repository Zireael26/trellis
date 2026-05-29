# Parent-hook drift (weekly)

You are verifying that the canonical parent-layer artifacts —
hook scripts in `__TRELLIS_PATH__/core-rules/hooks/`
Codex hook assets in `__TRELLIS_PATH__/core-rules/codex/`
**and** canonical skills in `__TRELLIS_PATH__/core-rules/skills/` —
are **byte-identical** to their deployed copies in each registered project.
The parent layer only has teeth if projects actually inherit the current
version — silent drift defeats the whole point.

This audit covers two artifact classes:

1. **Hook drift** — files copied into `<project>/.claude/hooks/` (must be byte-identical copies of canonical).
2. **Codex hook drift** — files copied into `<project>/.codex/` (must be byte-identical copies of canonical when Codex is enabled).
3. **Skill drift** — symlinks at `<project>/.claude/skills/<name>/` (and `<project>/.agents/skills/<name>/` if Codex-enabled) MUST resolve to the canonical directory under `__TRELLIS_PATH__/core-rules/skills/<name>/`. Symlink target verification, not byte-content (the symlink IS the inheritance).

## Inputs

1. Canonical hook source:
   `__TRELLIS_PATH__/core-rules/hooks/*.sh`
2. Canonical Codex hook source:
   `__TRELLIS_PATH__/core-rules/codex/hooks.json` and `__TRELLIS_PATH__/core-rules/codex/hooks/*.sh`
3. Canonical skills source:
   `__TRELLIS_PATH__/core-rules/skills/*/`
4. Read `__TRELLIS_PATH__/registry.md`
5. Read `__TRELLIS_PATH__/blacklist.md`
6. Target set = `registry \ blacklist`.

## Canonical hook manifest

There are two authoritative sources, by design — one for names and tiers,
one for event/matcher wiring:

- **Hook names + tiers + origin** — `core-rules/hooks/README.md` (Tier 1 +
  Tier 2 tables). This is the single source of truth for "which hooks
  exist" and "which are experimental".
- **Event + matcher wiring** — `core-rules/templates/claude-settings.json`
  (the `hooks` block). This is the canonical `settings.json` snippet that
  every project must register. Compare each project's
  `.claude/settings.json` against this template.

**Audit-runtime enumeration.** Do not maintain a manifest inline here.
Instead:

1. Enumerate canonical hook scripts from `core-rules/hooks/*.sh` on disk —
   that is the actual canonical set the project must mirror.
2. Cross-reference `core-rules/hooks/README.md` to identify which scripts
   are **experimental** (currently `propose-rules.sh`, marked as "Stop
   (opt-in, experimental)" in the Tier 2 table). Experimental hooks are
   excluded from the registration check below.
3. Load `core-rules/templates/claude-settings.json` and treat its `hooks`
   block as the authoritative event/matcher wiring. For every
   non-experimental canonical hook, the template must register it; for
   every entry the template registers, each project's
   `.claude/settings.json` must match (same event, same matcher, same
   command path under `$CLAUDE_PROJECT_DIR/.claude/hooks/`).

These two enumeration sources should agree by construction: any
non-experimental script under `core-rules/hooks/*.sh` should appear in
the template, and vice versa. A divergence between disk and template is
itself a finding — flag it as **critical: canonical manifest disagreement
between `core-rules/hooks/` and `core-rules/templates/claude-settings.json`**.

The project may have **additional** hooks beyond these — that's fine and
expected (e.g., msme-neev has `check-module-boundary.sh`). Additional hooks
are not checked by this task.

**Experimental hooks (opt-in, no registration check):**
`propose-rules.sh` is shipped to projects by `sync-hooks` automatically, so
the byte-identity and executable-bit checks still apply, but registration
in `settings.json` is project-discretion (opt-in via
`PROCESS_GATE_PROPOSE_RULES=1`). Absence of a settings.json entry for an
experimental hook is **not** drift. The authoritative experimental list
lives in the Tier 2 table of `core-rules/hooks/README.md`.

## Canonical Codex hook manifest

When parent `trellis.config.json` includes `"codex"` in `harnesses`, each project must carry:

- `<project>/.codex/hooks.json`, byte-identical to `__TRELLIS_PATH__/core-rules/codex/hooks.json`
- `<project>/.codex/hooks/*.sh`, byte-identical to `__TRELLIS_PATH__/core-rules/codex/hooks/*.sh`
- all `.sh` files executable

The manifest must use environment-relative commands such as `${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}/.codex/hooks/...`; hardcoded project paths are drift.

## Checks per project

### 1. Presence

Enumerate canonical scripts from `core-rules/hooks/*.sh`. For each, does
the project have a file at the expected path?
- `<project>/.claude/hooks/<hook-name>.sh`

Missing file → **critical: hook missing from deployment**.

### 2. Byte-identity

For each present canonical hook, compute SHA256 of the canonical source and
of the project's deployed copy. Compare.

Mismatch → **critical: hook drift** (record both hashes, and a `diff -u` of
the two files, capped at 50 lines).

### 3. Settings.json registration

Load `core-rules/templates/claude-settings.json` and iterate its `hooks`
block — this is the canonical event/matcher wiring. Read
`<project>/.claude/settings.json`. For each entry in the template, verify
the project's settings.json carries an equivalent registration: same event
(SessionStart / PreCompact / PreToolUse / PostToolUse / Stop), same
matcher, command pointing to
`$CLAUDE_PROJECT_DIR/.claude/hooks/<hook-name>.sh`.

Unregistered canonical hook → **critical: hook file exists but is not wired
into settings.json** (this is silent failure — the hook will never run).

Experimental hooks (per the Tier 2 table in `core-rules/hooks/README.md`,
currently `propose-rules.sh`) are excluded from this check — they are
project-discretion to register.

### 4. Executable bit

Each deployed `.sh` file must be executable (`chmod +x`). Stat the mode
bits. Not executable → **warning: hook will fail to run when invoked**.

### 5. Extra hooks (informational)

List any `.sh` file in `.claude/hooks/` that is not in the canonical
manifest. This is not a problem — it's a project-specific hook. Just note
it so we know each project's local extensions.

### 5b. Codex hook assets

If Codex is enabled:

- Compare `.codex/hooks.json` to the canonical manifest.
- Compare each `.codex/hooks/*.sh` to the canonical script with the same filename.
- Report missing files, byte drift, non-executable scripts, and hardcoded absolute project paths.

If Codex is not enabled, this check is `n/a`.

### 6. Skill symlink presence

Canonical skills currently shipped: `process-gate`.

For each canonical skill, verify the project carries the inheritance symlink:

- `<project>/.claude/skills/<name>/` exists AND is a symlink
- `readlink <project>/.claude/skills/<name>/` resolves to `__TRELLIS_PATH__/core-rules/skills/<name>/` (or the equivalent canonical path)

Missing or wrong target → **critical: skill not inherited**. The skill will silently not load.

Lume carve-out: Lume (Unity) is currently expected to carry the `process-gate` symlink. The canonical six gates apply regardless of stack. Stack-specific validators are project-local (`PROCESS_GATE_STACK_PROFILE="unity"` declared in `local.config.sh` is expected).

### 7. Skill symlink (Codex parity)

For projects with `harnesses` including `"codex"` in `<project>/.claude/trellis.config.json` (project-local override) OR in the parent `trellis.config.json` (Phase B; until that lands, infer from presence of `<project>/.agents/`):

- `<project>/.agents/skills/<name>/` exists AND is a symlink
- Target matches `<project>/.claude/skills/<name>/` target

Missing → **critical: Codex harness lacks skill inheritance**.
Drift between `.claude/` and `.agents/` skill targets → **critical: harness divergence**.

If Codex is not declared for the project, this check is `n/a`.

### 8. local.config.sh sanity

For each project, the project-local `<project>/.claude/skills/process-gate-local/local.config.sh` is OPTIONAL but recommended. If Codex is enabled, also check `<project>/.agents/skills/process-gate-local/local.config.sh`.

- File present: parse it. Verify `PROCESS_GATE_STACK_PROFILE` is one of the documented values (`web-next`, `web-vite`, `monorepo-pnpm`, `unity`, `native-other`, `n-a`).
- File absent: **info** (the skill uses sensible defaults; not a failure).
- File present but unparseable bash: **warning**.

## Output

Write to `__TRELLIS_PATH__/audits/YYYY-MM-DD-parent-hook-drift.md`:

```
# Parent-hook drift — <date>

## Summary
- Projects checked: <N>
- Fully synced (all canonical hooks present + identical + registered + +x; all skills symlinked correctly): <count>
- Drifted hooks: <count>
- Missing hooks: <count>
- Registration gaps: <count>
- Skill symlink missing or wrong target: <count>
- Codex hook drift or missing assets: <count>
- Codex skill divergence (where Codex enabled): <count>

## Drifted hooks

### <project-name> / <hook-name>.sh
- Canonical SHA256: <hash>
- Deployed SHA256: <hash>
- Diff (unified, last-edit on deployed side):
  ```
  <up to 50 lines of diff -u>
  ```
- Likely cause: <your read — usually either "someone edited the project copy" or "parent was updated and rollout didn't happen yet">

## Missing hooks (file absent from .claude/hooks/)

| Project | Missing hooks |
|---|---|
| ... | ... |

## Registration gaps (file exists but not in settings.json)

| Project | Hook | Event expected |
|---|---|---|
| ... | ... | ... |

## Executable-bit issues
<list>

## Codex hook status

| Project | hooks.json | Scripts | Executable | Status |
|---|---|---|---|---|
| <project> | ✅ / ❌ | ✅ / ❌ | ✅ / ❌ | ✅ / ❌ |

## Per-project extras (informational)

| Project | Local-only hooks |
|---|---|
| neev | check-module-boundary.sh |
| ... | ... |

## Skill symlink status

| Project | Skill | .claude target | .agents target (if Codex) | Status |
|---|---|---|---|---|
| <project> | process-gate | <readlink> | <readlink> | ✅ / ❌ |

## Recommended actions

1. <prioritized — usually: "rsync canonical hooks to project X", "update settings.json to register run-lint.sh", or "create symlink .claude/skills/process-gate -> canonical in project Y">
```

## Severity

- **critical**: hook drift, hook missing from disk, registered-but-missing-file, file-exists-but-not-registered.
- **warning**: hook not executable, stale last-modified-time (>6 months old suggests deployment is forgotten).
- **info**: project-specific extra hooks (just a list).

## Boundaries

- **Do not modify any project's hooks or settings.json.** This audit
  reports; the user (or a separate rollout task) does the syncing.
- Do not modify the canonical source to match a drifted project — that's
  backwards. If a project's version is better, the user decides whether to
  pull it up to canonical.

## Sensible failure modes

- If a project directory doesn't exist on disk, note it and defer to
  `registry-blacklist-health` (which will have already flagged it).
- If a project has no `.claude/` directory at all, note it and defer to
  `cross-project-process-audit`.
- If the canonical hooks directory itself is missing, stop with a clear
  error — nothing to compare against.
