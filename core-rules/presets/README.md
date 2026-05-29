# Presets

Presets are opt-in rule layers that sit on top of Trellis's parent rules. Each preset is a single markdown file under `core-rules/presets/<name>.md`. Projects declare which presets they want via the `presets` array in their `trellis.config.json` (or root-level project config), and `onboard-project.sh` seeds parallel symlinks under both `.claude/rules/` and `.agents/rules/` so the harness loads them alongside the canonical `trellis.md`.

Presets exist for one reason: **two projects under Trellis sometimes need genuinely different rules**, and the right answer is neither "duplicate the rules in every project's local `CLAUDE.md`" nor "stuff every option into `core-rules/CLAUDE.md`". Presets are the middle ground — opt-in profiles a project chooses.

---

## Priority order (conceptual — rules are additive)

Claude Code and Codex both load every file under `<project>/.claude/rules/` and `<project>/.agents/rules/` and concatenate the content into the agent's prompt. There is no engine-level override; the "priority" below describes how an agent should resolve apparent conflicts between layers, not a mechanical last-wins rule.

1. **Parent rules** (`core-rules/CLAUDE.md`) — the canonical Trellis discipline. Always loaded.
2. **Presets** (`core-rules/presets/<name>.md`) — opt-in layers. Array order in the project config is also conceptual (later entries are more specific).
3. **Project-local** (`<project>/CLAUDE.md`) — most specific; the agent should give it the most weight when prose contradicts a higher-up layer.

In practice, presets *extend* parent rules with extra discipline (compliance-strict) or *carve out* explicit relaxations (experimental-loose). They never silently contradict — every relaxation is named under "Carve-outs" with a cited reason.

---

## Available presets

| Preset | Posture | Use when |
|---|---|---|
| [`compliance-strict.md`](./compliance-strict.md) | Tighter discipline | Project handles regulated data, audited deploys, or a customer contract that mandates specific controls. |
| [`experimental-loose.md`](./experimental-loose.md) | Lighter ceremony | Throwaway prototype, hackathon project, internal-only spike — the surgical-default is overkill. |

More presets land here over time as different projects' needs surface. Two-project minimum before a new preset is shipped (matches the Rule of Three for parent rules, scaled down because presets are opt-in).

---

## Adding a preset to a project

1. Pick a preset from the table above (or write a new one — see "Authoring a new preset" below).
2. Add its name to the `presets` array in the project's `trellis.config.json`:

   ```json
   {
     "trellis_root": "/abs/path/to/trellis-instance",
     "projects_root": "/abs/path/to/projects",
     "...": "...",
     "presets": ["compliance-strict"]
   }
   ```

3. Run `scripts/rollout-presets.sh <project-name>` (or re-run `onboard-project.sh` on a freshly-onboarded project).

The script seeds `<project>/.claude/rules/preset-<name>.md` and `<project>/.agents/rules/preset-<name>.md` as symlinks pointing at `core-rules/presets/<name>.md`. Both harnesses load every file under their rules directory, so the preset's content composes with `trellis.md` automatically.

Remove a preset by deleting its entry from the array and re-running `rollout-presets.sh`. The script removes any preset symlinks no longer declared in the config (idempotent).

---

## Authoring a new preset

Presets are short, opinionated, scoped. A good preset:

- Is **single-purpose** — covers one axis of discipline (compliance, experimentation, performance, accessibility). Two unrelated changes belong in two presets.
- Is **short** — under 50 lines. Anything longer probably belongs in `engineering-process.md` or a project-local rule.
- **Cites a reason** — what's the customer contract / risk / experiment context that justifies the layer? Future-you needs the context.
- **Doesn't fight the parent** — extends or carves out, never directly contradicts. If you find yourself overriding a parent rule wholesale, the parent rule itself probably needs revision.

Conventional structure:

```markdown
# Preset: <name>

**Posture:** strict | loose | balanced
**Purpose:** one-sentence reason this preset exists
**Use when:** the conditions a project should match before enabling this

---

## Additions

Rules that extend the parent discipline. Each rule has a one-line *why*.

## Carve-outs

Parent rules this preset relaxes or makes optional. Each carve-out names the parent rule by section and gives the reason.

## Notes

Anything that doesn't fit elsewhere. Refer to ADRs or `gotchas.md` entries that motivated this preset, if any.
```

Drop the new preset at `core-rules/presets/<name>.md`. Add a row to the "Available presets" table in this README. Open a PR; reviewers check that the preset is single-purpose, short, doesn't contradict the parent, and has a real reason to exist.

---

## Autonomy ceiling / default in presets (optional)

Presets MAY declare optional YAML frontmatter at the top of their file to participate in the autonomy slider (`core-rules/autonomy.md`):

```yaml
---
autonomy_ceiling: 2
autonomy_default: 3
---
```

- `autonomy_ceiling` (integer 1–5) — clamp ceiling for any session running this preset. If multiple presets are active, the **lowest** ceiling wins (most restrictive). Session overrides via `/autonomy N` are clamped to ceiling and the command warns on clamp.
- `autonomy_default` (integer 1–5) — the level used when no fleet `autonomy_default` is set and no project-local override exists. Lower priority than project-local `.trellis.config.json.autonomy`.

Both fields are optional. A preset without frontmatter has no autonomy effect. See `core-rules/autonomy.md` for the full resolution algorithm.

| Preset | autonomy_ceiling | autonomy_default |
|---|---|---|
| `compliance-strict` | 2 | (none) |
| `experimental-loose` | 5 | 4 |

---

## Drift audit

`scheduled-tasks/preset-drift/` runs weekly. For each registered project, it compares the `presets` array in the project's `trellis.config.json` against the preset symlinks actually present under `.claude/rules/` and `.agents/rules/`. Mismatches are reported:

- **critical** — config declares a preset but the symlink is missing (or points somewhere unexpected). The preset's discipline isn't loading.
- **warning** — symlink exists but the config doesn't list the preset (stale; should be removed by `rollout-presets.sh`).
- **info** — project has no `presets` array. Acceptable; most projects don't need a preset.

The drift audit is read-only; remediation goes through `rollout-presets.sh`.
