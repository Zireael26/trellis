---
description: Render the §14.8-layered rule stack (parent → presets → project-local) to stdout with provenance labels — assembles, never adjudicates
argument-hint:
---

# Constitution — render the layered rule stack

You are rendering the effective rule "constitution" for THIS repo: the §14.8 layer stack (parent → presets → project-local) exactly as the harness loads it, each rule labelled with the layer it came from. This is a render-only surfacing command. It **assembles, never adjudicates**, and it **writes nothing** — pure stdout, no audit file, git stays clean after a run.

The point is to make the otherwise-invisible composition visible: every session silently concatenates parent rules + any opt-in presets + the project-local `CLAUDE.md`, and an operator can't easily see which layer a given rule lives in. This command prints that stack with `[parent]` / `[preset:<name>]` / `[project]` provenance so a human can read the whole inherited constitution in one place.

It does **not** decide which layer wins a conflict. Per `engineering-process.md` §14.8 and `inheritance.md` (the Presets-inheritance section), rules are **additive, not last-wins** — there is no engine-level override. "Priority" is only a *conceptual deference hint* for how an agent should resolve apparent prose conflicts (later/more-specific layers in the parent < preset < project-local chain should carry the most weight), not a directive the engine enforces. So this command surfaces all layers, points at where two layers both speak to the same topic, cites the deference hint, and stops. It never declares a winner, never rewrites a rule, never emits a verdict.

## Steps

### 0. Resolve the canonical project root

Run `git rev-parse --git-common-dir` and take its parent — that is the canonical repo root (call it `<canonical-root>` below). All file reads happen relative to it. This is the same canonical-root resolution `primer-check` uses, and it makes the command worktree-robust: a linked worktree resolves to the main checkout's root, where the inheritance symlinks actually live.

Do not hardcode any absolute path to the parent/`trellis` control plane. The parent rules are reached only by *following the symlink target*, never by typing a path (see step 2a).

### 1. Confirm there is a stack to render

The rules directory is `<canonical-root>/.claude/rules/`. If it does not exist, or contains no `trellis.md`, report that this repo is not parented (no inheritance symlink present — likely unonboarded or a worktree that lost its seed) and exit cleanly. Do not attempt to repair — that is `doctor`'s job, not this command's.

### 2. Assemble the layers — in §14.8 order

Read the actual files the harness loads, in the layer order from `engineering-process.md` §14.8. Read the rules **directory directly** — that is literally what the engine concatenates. Do **not** read the project's `.trellis.config.json` `presets` array and reconcile it against what's on disk: declared-vs-present is drift detection, which `scheduled-tasks/preset-drift/` owns, and reconciling would drift this command toward adjudication. Render what is loaded, not what is declared.

**a. `[parent]` — the base layer.**
`<canonical-root>/.claude/rules/trellis.md` is a symlink into the control plane. Follow it to its target and read the target file's contents. Label everything from it `[parent]`. Render it as-is: if the parent `CLAUDE.md` contains `@`-imports (e.g. to `engineering-process.md`), **do not recursively expand them** — print the parent file's own text and let its internal pointers stand. Expanding would explode the output and isn't the stack the §14.8 contract is talking about.

**b. `[preset:<name>]` — opt-in layers.**
For each `<canonical-root>/.claude/rules/preset-*.md` (these are symlinks into `core-rules/presets/`), the `<name>` is the filename stem after `preset-` (e.g. `preset-compliance-strict.md` → `compliance-strict`). Follow each symlink, read the target, label its rules `[preset:<name>]`. There may be zero, one, or several. List them in filename order and say so (array/order is conceptual only — §14.8).

**c. `[project]` — most-specific layer.**
`<canonical-root>/CLAUDE.md` (the project-root file, if present). Label its rules `[project]`. If the project has no root `CLAUDE.md`, note "no project-local layer" and move on.

### 3. Render the stack to stdout

Print the three layers in order (parent → presets → project), each under a clear heading carrying its provenance label, e.g.:

```
## [parent]  (via .claude/rules/trellis.md → <symlink target>)
<the parent rules text, as-is, @-imports left unexpanded>

## [preset:compliance-strict]  (via .claude/rules/preset-compliance-strict.md → <symlink target>)
<the preset text, as-is>

## [project]  (<canonical-root>/CLAUDE.md)
<the project-local rules text, as-is, or "no project-local layer">
```

Keep the layer *contents* faithful — you are surfacing the loaded text, not summarizing or editing it. If a layer is very long, you may fold purely structural noise (e.g. a long table of contents) but never alter or paraphrase a rule's wording.

### 4. Surface overlaps — do NOT adjudicate

After the stack, optionally add a short `## Where layers overlap` note. For any topic that more than one layer speaks to (e.g. parent says "secrets findings warn"; `compliance-strict` says "secrets findings hard-fail"), state plainly that **both** layers address it, cite which layers, and stop. Frame it as "the operator reads both," not as a resolution:

```
## Where layers overlap (deference hint, not a ruling)
- Secrets-scan severity: addressed by [parent] and [preset:compliance-strict].
  §14.8 / inheritance.md deference hint: the more-specific layer
  (preset > parent here) carries the most weight when prose conflicts —
  but rules are ADDITIVE, both are in the agent's context, and this
  command does not pick a winner. Read both.
```

Never write "so X wins" as a conclusion of your own — only restate the §14.8 deference hint and attribute it to the contract. The deference semantics are defined in `engineering-process.md` §14.8 and `inheritance.md`; cite them, do not redefine them here.

## Constraints

- **Writes nothing.** No audit file (unlike `disk-janitor` / `doctor`, this does not write to `audits/`), no edits to any rule file, no symlink changes. Output is stdout only; `git status` is unchanged after a run.
- **Assembles, never adjudicates.** Surface every layer + label provenance + note overlaps and cite the deference hint. Never declare a winner, never rewrite or "resolve" a rule, never merge layers into one collapsed ruling.
- **No verdict line.** This command emits no PASS / NEEDS-REVISION / BLOCKED — that is the `analyze` skill's advisory verdict, a different surface. constitution just prints the stack.
- **Reach the parent by symlink, never by path.** The parent layer is whatever `.claude/rules/trellis.md` resolves to on this machine; do not hardcode a control-plane path.
- **Don't recursively expand `@`-imports.** Render each layer's own file text; leave its internal pointers (`@…/engineering-process.md`, etc.) as text.
- **Render loaded, not declared.** Read `.claude/rules/`; do not reconcile against `.trellis.config.json`. Declared-vs-present drift belongs to `preset-drift`.

<!--
Canonical-root lineage: `git rev-parse --git-common-dir` → parent, same as
`primer-check` and `_se_repo_root` in `core-rules/hooks/lib/deps.sh`.
Layer order + additive/deference contract: engineering-process.md §14.8 and
inheritance.md (Presets inheritance). Both are cited, not redefined, above.
-->
