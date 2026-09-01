---
name: wiki-maintain
description: Explicit, project-local maintenance for the evidence-backed wiki pattern catalog. Use only when the operator explicitly asks to qualify a gotcha or create, merge and retire, explicitly retire, or stale-mark a wiki pattern. Patch-edits only wiki/index.md and wiki/patterns/*.md, proves the change with the read-only validator, and never creates or edits skills, gotchas, impact records, hooks, release payloads, or user-global paths.
---

# wiki-maintain

Maintain the project wiki as durable, on-demand evidence. A pattern records a
qualified operational lesson; it is not a skill, is not injected at session
start, and grants no runtime or promotion authority.

This skill runs only after an explicit operator invocation. A post-edit
suggestion after `gotchas.md` changes is advisory: it does not invoke this skill,
block the edit, or authorize any write.

## Authority boundary

Run from the project root. Read only the project-local evidence needed for the
requested transition:

- `gotchas.md`
- `context-log.md`
- `decisions-log.md`
- `wiki/index.md`
- linked pages under `wiki/patterns/`
- an operator-supplied related HTTPS pull-request link

The only durable paths this skill may create or patch are:

- `wiki/index.md`
- `wiki/patterns/<slug>.md`

Everything else is outside its write authority. In particular, never create,
edit, delete, rename, retire, or promote:

- any skill, `SKILL.md`, `PURPOSE.md`, candidate, benchmark, or evaluation receipt
- `gotchas.md`, `context-log.md`, `decisions-log.md`, or `CHANGELOG`
- `wiki/skill-impact.md`, anything under `wiki/skill-impact/`, or `wiki/logs.md`
- hooks, session-context paths, templates, manifests, configuration, protected
  refs, immutable release payloads, user-global skill paths, or fleet state

Do not run Git or GitHub mutation commands. Do not create a branch, commit, push,
open or merge a PR, publish, synchronize, or land a candidate. Do not invoke
`skill-creator` or the wiki-fed proposer. Human merge remains the only promotion
transition.

## Validator surfaces

The validator is bundled beside this file. Resolve the loaded skill directory
with the process-gate precedent; the same relative script path applies when the
skill is inherited into an attached project.

```sh
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$SKILL_DIR/scripts/validate_wiki.py" qualify \
  --evidence "$EVIDENCE_JSON"

python3 "$SKILL_DIR/scripts/validate_wiki.py" check \
  --root "$PROJECT_ROOT"

python3 "$SKILL_DIR/scripts/validate_wiki.py" check-change \
  --before "$BEFORE_ROOT" --after "$PROJECT_ROOT"
```

`qualify`, `check`, and `check-change` are read-only. Treat exit `0` as accepted,
exit `1` as a negative decision, and exit `2` as malformed input. Preserve their
JSON output for the completion report; do not reinterpret a nonzero result as a
warning.

`BEFORE_ROOT` must be a distinct, trustworthy snapshot of `PROJECT_ROOT` from
before this invocation. Establish it before the first edit through the invoking
workflow. Never point both arguments at the same mutable tree, and never invent a
passing before tree after editing. If no trustworthy before root is available,
stop before writing: the required change-scope proof cannot be produced.

## Qualification

Qualification is required before a create or a merge that incorporates a new
gotcha. It is not required merely to mark broken evidence stale or to retire an
already fully subsumed page.

1. Read the source gotcha and its cited local history. Do not mine the wiki at
   session start or scan unrelated records.
2. Assemble an ephemeral JSON evidence file with `schema_version`, anchored
   `source`, `pattern_key`, recorded `occurrences`, `preconditions`,
   `inputs_needed`, `inputs`, ordered `steps`, observable `result`, observable
   `verification`, and `secret_values_present`.
3. Put no secret value, credential, transient incident value, or unsupported
   claim in that file. Remove the ephemeral file after the read-only decision;
   it is not a fourth project record.
4. Run `qualify --evidence`. Continue only when its JSON verdict is `qualify`
   and the command exits `0`.

A pattern qualifies through either of these predicates:

- at least two separately recorded occurrences of the same pattern; or
- a reusable path with at least three ordered operations, named preconditions,
  named inputs when inputs are needed, an observable result, and an observable
  verification step.

Two mentions are not two occurrences. A single fact, one-line correction,
arbitrary three-item list, unverified guess, one unverified occurrence, secret,
or transient value remains a gotcha. On `retain-as-gotcha` or malformed input,
make no wiki edit and leave the source untouched.

## Pattern and index contract

Use a lower-case slug matching `^[a-z0-9][a-z0-9-]*$`. The index slug cell links
`patterns/<slug>.md`; its source cell links the matching anchor in
`../gotchas.md`; status is exactly `active`, `stale`, or `retired`; updated is an
ISO `YYYY-MM-DD` date. Preserve the one-row-per-slug table shape and never add a
second catalog or ledger table.

Each pattern page has only the contract frontmatter fields:

```yaml
---
slug: <slug>
status: active
---
```

Its title is `# Pattern: <slug>` and it contains non-empty `## Failure mode`,
`## Root cause`, `## Working path`, `## Dead ends`, and `## Evidence` sections.
The working path preserves the qualifying preconditions, inputs, operations,
result, and verification. Evidence contains:

- one resolving link to the source `gotchas.md` anchor;
- at least one resolving, relevant `context-log.md` or `decisions-log.md` anchor;
- the related HTTPS pull-request link.

Write only claims supported by those records. Do not invent prose to fill a
required section. Pattern text must contain no secret values.

## Choose exactly one transition

Inspect `wiki/index.md` and only the linked relevant pages, then select one of the
four transitions accepted by `check-change`. If none fits, make no edit.

### Create

Create one new `active` pattern page and its matching index row. First rule out
an overlapping active page: update and consolidate rather than creating a
second authority. Do not create a production page from synthetic or
nonqualifying evidence.

### Merge with superseded retirement

Use this when overlapping pages must become one durable pattern in the same
change. Patch the surviving active page with the consolidated, evidence-backed
content; preserve the relevant source/history/PR links. Change every superseded
page from `active` to `retired`, retain the page as history, and update all
corresponding index statuses and dates. Do not delete pages or index rows.

A change that both patches the survivor and retires one or more superseded pages
is a merge-with-retirement. Do not report it as an explicit retirement.

### Explicit superseded retirement

Use this only when an active page is already fully subsumed and no survivor is
being consolidated in this change. Change that retained page and its index row
from `active` to `retired`, update the index date, and preserve its evidence.
This records an already-established supersession; it does not create, modify, or
promote the replacement and cannot make any skill authoritative.

Do not use retirement for broken evidence. Broken required local evidence is a
stale transition.

### Mark stale

When at least one required local evidence link on an active page no longer
resolves, patch that page and its index row from `active` to `stale` and update
the index date. Preserve the broken link so the reason remains reviewable. Do not
rewrite missing history, fabricate a replacement link, or retire the page.

The agent performs this patch directly; the validator does not author wiki
prose.

## Patch discipline

- Patch the smallest existing sections and table cells that implement the chosen
  transition. Preserve unrelated rows, pages, evidence, and user changes.
- Keep page frontmatter and the index row synchronized in the same edit set.
- Never change a source gotcha's authority or disposition. Failed evaluation,
  rejection, and pre-merge states leave it untouched.
- Never delete wiki history because a proposal failed or was rejected.
- Do not combine transition types or unrelated cleanup in one maintainer run.

## Required completion proof

After patching:

1. Run read-only `check --root "$PROJECT_ROOT"`. Repair only the two allowed path
   families if it reports a schema, link, status, duplicate-slug, or secret
   failure.
2. Run read-only `check-change --before "$BEFORE_ROOT" --after "$PROJECT_ROOT"`.
   It must identify the intended create, merge-with-retirement, explicit
   superseded-retirement, or stale transition and report no changed path outside
   `wiki/index.md` and `wiki/patterns/*.md`.
3. If either command remains nonzero, restore only this run's allowed-path edits
   and report that maintenance did not complete. Never fix a failure by touching
   a forbidden path or weakening the evidence.
4. Report the transition, qualification predicate or `not applicable`, exact
   changed paths, both validator exits and JSON verdicts, and any residual broken
   evidence. State explicitly that no skill was authored or promoted.

Do not write this report to the repository. `wiki/logs.md` is forbidden; existing
decision history and pull-request review remain the history surfaces.
