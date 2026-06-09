# Recipe manifest

One row per recipe. Recipes are generic, parametric skeletons — specifics enter through `args`, never as baked literals. The capability and degrade columns echo the two-level graceful degrade in `SKILL.md`.

| Recipe | Intent | Inputs (`args`) | Capability needs | Degrade note |
|---|---|---|---|---|
| `fanout-verify` | Fan out one verified-change agent per target, push + PR each, return verdicts for the main loop to merge/hold. | `targets[]` (`{name,path}`; falls back to the registry), `task`, `branchPrefix`. | Workflow tool ideal; subagents + isolated worktrees required for parallel fan-out. | No workflow tool → dispatch the per-target stage sequentially per this row + `SKILL.md`. No subagents → run targets inline, one at a time, preserving change → verify → verdict. |
| `template` | Blank starting skeleton for authoring a new recipe — `meta`, a schema stub, and fan-out/verify scaffolding to fill in. | none (copy + edit). | none — authoring artifact, not runnable as-is. | n/a (scaffold; the recipe you write from it carries its own degrade behavior). |
