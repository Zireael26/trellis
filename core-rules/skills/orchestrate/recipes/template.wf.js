// Recipe template — copy this file to start a new workflow recipe.
//
// A recipe is plain ES-module JS. The engine injects a fixed set of globals;
// you never import or define them yourself:
//   agent(prompt, opts?)  -> returns text, or a validated object when opts.schema is set
//   parallel(thunks)      -> runs an array of () => agent(...) thunks, barrier-joins
//   pipeline(items, ...s) -> streams items through stages, no barrier
//   phase(title)          -> marks a phase boundary (matches a meta.phases title)
//   log(msg)              -> structured progress line
//   args                  -> caller-supplied inputs (the ONLY place specifics enter)
//   budget                -> remaining run budget
//
// FORBIDDEN — the engine rejects scripts that call non-deterministic globals:
// the current-time call, the random call, and the argless date constructor.
// Need a timestamp or seed? Take it from `args`.
//
// Authoring rules of thumb:
//   - Keep `meta` a PURE LITERAL (no function calls, no concatenation).
//   - Put every specific (targets, paths, dates, scope) in `args` — never bake
//     literals. This file ships in the public mirror; keep it path-neutral.
//   - Agents do the work and RETURN a verdict; the main loop decides/merges.

export const meta = {
  // <fill-in> short kebab-case identifier, unique across recipes.
  name: 'my-recipe',
  // <fill-in> one line: what this recipe accomplishes and for whom.
  description: 'One-line intent — what this recipe produces and verifies.',
  // <fill-in> optional ordered phases; each title should match a phase() call.
  phases: [
    { title: 'Work', detail: 'what the agents in this phase do' },
  ],
}

// Structured-output schema for an agent's verdict. Setting opts.schema makes
// agent() return a validated object instead of free text. Keep
// additionalProperties:false so the agent can't smuggle unexpected keys.
const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['ok', 'summary'],
  properties: {
    ok: { type: 'boolean', description: '<fill-in> the pass/fail predicate for this unit of work' },
    summary: { type: 'string', description: '<fill-in> what changed / what was found, concise' },
    // <fill-in> add the fields the main loop needs to act on the result.
  },
}

// Build the prompt as an array of lines joined with newlines — easy to read in
// diffs, and the array doubles as a readable spec for a harness with no workflow
// tool. Pull every specific from `args`; do not hardcode.
function workPrompt(item) {
  return [
    'You are doing <fill-in: the task> for "' + item.name + '".',
    'Verify on-host before you report (add isolation:"worktree" to the agent opts when the agent mutates a repo).',
    'Return the VERDICT object describing the outcome.',
  ].join('\n')
}

phase('Work')

// One live agent call. opts: { label, phase, schema } — and isolation:'worktree'
// when the agent mutates a repo checkout.
const result = await agent(workPrompt(args.item ?? { name: 'subject' }), {
  label: 'work',
  phase: 'Work',
  schema: VERDICT,
})

// Fan-out example (commented). Map each input to a thunk and parallel() them;
// the barrier resolves when every agent returns. Filter out any empty results.
//
// const items = args.items ?? []
// const results = await parallel(
//   items.map((it) => () => agent(workPrompt(it), {
//     label: 'work:' + it.name, phase: 'Work', schema: VERDICT, isolation: 'worktree',
//   }))
// )

// The main loop receives this return value and acts on the verdicts (e.g. merge
// the green ones, hold the rest). Agents never merge.
return { result }
