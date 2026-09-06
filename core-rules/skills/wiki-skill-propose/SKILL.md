---
name: wiki-skill-propose
description: Read-only, wiki-fed review gate for an existing project-local skill candidate. Use explicitly when qualifying one create-or-patch skill proposal from active wiki patterns, checking rejected-set history and new evidence, validating skill-creator benchmark and process-gate receipts, and producing the PR-ready report. It never authors the candidate or invokes Git or GitHub.
---

# wiki-skill-propose

Assess one existing skill candidate against the project wiki and promotion gate, then emit a review report. This skill is a reader and coordinator, not a candidate author or publisher: `skill-creator` owns candidate authorship and benchmarking, the validator checks supplied artifacts, an authorized product pipeline may prepare a proposal branch and PR, and only a human merge promotes the skill.

Invoke this skill explicitly from the project root. The wiki remains on-demand input; never inject it into session startup or treat a pattern as runtime authority.

## Inputs

Collect these paths and values before starting. All paths consumed by `validate_proposal.py check` are read-only inputs.

| Input | Contract |
|---|---|
| project root | Root containing `wiki/index.md` and `wiki/skill-impact.md`. |
| candidate | The one existing candidate directory, beneath the configured tracked project-local skill root. |
| patterns | Comma-separated selected pattern slugs. |
| benchmark | A real standard `skill-creator` aggregate `benchmark.json`, never a self-report or Phase 1–4 fixture presented as a real run. |
| receipt | Machine receipt JSON for this candidate and benchmark. A new evaluated proposal requires the `schema_version: 2` form carrying the `evaluation` cohort evidence object. |
| process-gate receipt | Text receipt proving exit `0` and `Overall: MERGEABLE` for the proposal range. The process that supplies it, not this skill or the validator, runs the gate. |
| proposal diff | JSON file containing the PR-wide set of repository-relative changed paths. The validator uses the complete set to enforce one-skill atomicity. |
| qualification | JSON qualification decision for the selected evidence. It must prove a qualifying recurrence or complete repeatable path. |
| skill root | Repository-relative tracked project-local skill root; defaults to `core-rules/skills`. Immutable release payloads and user-global skill roots are invalid. |
| new evidence | Optional repeatable evidence link. Supply each link as a separate `--new-evidence`; it is not a free-form bypass. |

`--proposal-diff` has exactly this JSON shape:

```json
{
  "base": "<40-lowercase-hex>",
  "head": "<40-lowercase-hex>",
  "changed_paths": [
    "<repository-relative-path>"
  ]
}
```

`head` must equal the receipt's `proposal_sha`. `base` and `head` supply the ledger's `diff=<base>..<head>` value without Git discovery; `changed_paths` is the complete PR-wide path set, not a candidate-only subset.

The validator parses these inputs with the Python standard library. It does not call subprocesses, Git, GitHub, or the network, and it does not discover or mutate a global skill path.

## Authority boundaries

This skill may:

- read `wiki/index.md`, `wiki/skill-impact.md`, selected pattern pages, and their linked evidence;
- read the existing candidate, qualification decision, proposal-diff manifest, benchmark, machine receipt, process-gate receipt, ledger, and linked sidecars;
- run the read-only `validate_proposal.py check` command; and
- emit the report and PR-body block defined below.

This skill must not:

- create, draft, patch, rename, or delete a candidate, `PURPOSE.md`, wiki page, gotcha, ledger row, or sidecar;
- run the validator's mutating `record` operation;
- invoke `git`, `gh`, GitHub APIs, merge or publication commands, or a network service;
- commit, push, open or merge a PR, write a protected branch, publish globally, or sync a skill to a release payload or user-global path; or
- describe an unmerged candidate as promoted or authoritative.

`skill-creator` is the only candidate author and benchmark producer in this route. After a successful read-only `check`, an authorized product-pipeline record step may use `validate_proposal.py record` with the same inputs plus `--pr <https-url|not-opened>` to create the new ledger row and sidecar. After human merge or rejection, that step may forward-finalize only the same row and sidecar. `record` authors no candidate or wiki prose and invokes no Git, GitHub, subprocess, or network operation. The product pipeline may separately commit on a proposal branch, push it, and open the proposal PR. Neither that pipeline, this skill, a validator, an evaluator, an advisory hook, nor a green receipt may land the candidate. Human merge after review is the sole promotion transition.

## Procedure

### 1. Read the catalog and evidence on demand

Read `wiki/index.md` and `wiki/skill-impact.md`, then open only the selected pattern pages and their evidence links. Every selected page must be indexed, resolve, and have `status: active`.

Refuse before candidate evaluation if any selected page is `stale` or `retired`, is absent or inconsistent with the index, has unresolved required evidence, or lacks a qualifying decision. New evidence does not revive a stale or retired page and does not replace qualification.

### 2. Compare final rejected pattern sets

Normalize the selected slugs as an exact sorted set and compare it with the `patterns=` set in every ledger row whose final verdict is `rejected`. Do this before asking `skill-creator` to author or evaluate anything.

- If an exact final-rejected set matches and no fresh link is supplied, refuse the proposal without evaluation and without another ledger row.
- If the set matches and at least one supplied `--new-evidence` link is absent from the rejected row, a new proposal may proceed. It still needs a fresh candidate evaluation, receipt, and ledger row. Preserve the rejected row and sidecar unchanged, and carry the new links in the new row's `new-evidence=` token.
- A different pattern set may proceed normally, but receives no relaxation of provenance or gate requirements.

### 3. Hand candidate authorship and benchmarking to `skill-creator`

After the evidence preflight passes, hand the selected patterns and requirements to `skill-creator`. Do not write the candidate in this skill.

The returned proposal must be atomic across the whole PR:

- create exactly one skill directory or patch exactly one existing skill directory, never both and never two skills;
- keep it below the configured repository-relative `--skill-root`;
- include `SKILL.md` and a sibling `PURPOSE.md`; and
- give `PURPOSE.md` exactly one resolving backlink for every selected pattern slug, with no missing, duplicate, or extra motivating-pattern links.

The complete repository-relative changed-path set goes in `--proposal-diff`. A candidate-directory-only listing is insufficient because atomicity is PR-wide.

Accept only the standard aggregated `benchmark.json` produced by the real `skill-creator` benchmark flow. The candidate score is `run_summary.with_skill.pass_rate.mean`. The comparison is exact decimal arithmetic over **every** accepted version of the skill, not merely the most convenient one:

1. If no accepted sidecar exists for the skill, `best_before` is the same benchmark's `run_summary.without_skill.pass_rate.mean`.
2. Otherwise every accepted row must be covered, and `best_before` is the maximum of the covered scores. An accepted v2 sidecar measured in the same cohort is covered by revalidating its own bound evidence; one measured in another cohort is covered only by a bound same-cohort re-evaluation in `evaluation.incumbents`, whose re-evaluated score is the one used.
3. Any uncovered accepted row is NOT-READY. An accepted v1 sidecar is NOT-READY with a migration-required reason: it has no verifiable candidate-content binding, so it is historical data rather than a comparable incumbent. Never compare against the incomparable old number, and never fall back to the baseline to route around an uncovered row.
4. Require `score > best_before`; equality and regression fail. Exclude `eval-passed`, `rejected`, and `failed` sidecars from the comparison entirely.

### 4. Require the exact machine sidecar

The sidecar path is:

```text
wiki/skill-impact/<skill>/<YYYY-MM-DD>-<short-sha>.json
```

A new evaluated proposal is version 2: the nine historical fields plus `schema_version: 2` and one `evaluation` object, and no others. `core-rules/evals/SCHEMA.md` is the canonical grammar for `evaluation` — its exact nested fields, the tree-digest and canonical-JSON encodings, the run-directory path rules, and the terminal raw run receipt. Read it before producing or reviewing evidence.

```json
{
  "schema_version": 2,
  "skill": "<skill>",
  "proposal_sha": "<proposal-sha>",
  "eval_cmd": "<exact-skill-creator-command>",
  "score": "<finite-decimal>",
  "best_before": "<finite-decimal>",
  "baseline": "<finite-decimal>",
  "verdict": "<eval-passed|accepted|rejected|failed>",
  "run_at": "<RFC-3339-UTC>",
  "runner_model": {
    "proposer": "<family>::<provider/model>",
    "evaluator": "<family>::<provider/model>",
    "judge": "<family>::<provider/model>"
  },
  "evaluation": { "...": "see core-rules/evals/SCHEMA.md" }
}
```

Existing unversioned nine-field receipts remain valid v1 history. Any other shape — a different `schema_version`, a missing key, an extra key — is malformed, not a legacy fallback. There is no new v1 promotion.

`runner_model` contains exactly the three string keys shown. Every route uses canonical `<family>::<provider/model>` grammar. Compare the family prefix before `::`: evaluator and judge must each differ from proposer. Evaluator and judge may use the same family or the same full route as each other.

The sidecar must match the candidate skill, proposal SHA, benchmark values, exact evaluation command, and ledger row. A new proposal has exactly one eight-column ledger row and one linked sidecar. Finalization moves that same row and sidecar only forward: `eval-passed` to `accepted` after human merge or to `rejected` after human rejection, and `not-opened` to an HTTPS PR URL. Finalization preserves every field except `verdict`, including `schema_version` and the whole `evaluation` object. A legacy v1 row may still be finalized to `rejected` or have its PR advanced; it may never be newly `accepted`. Never delete history, add a second row for the same proposal, move a terminal verdict backward, or use rejection to roll back wiki evidence.

### Three outcomes that are not each other

Keep these separate in every report; conflating them is how an unmeasured proposal acquires a score.

- **A historical score** is a number recorded by an earlier run. It stays in the ledger and stays true of that run. It is not automatically comparable to this one.
- **NOT-READY** means the evidence needed for a comparison is absent, unbound, or incomparable — a missing artifact, a cohort mismatch with no bound re-evaluation, a legacy v1 incumbent, a run receipt reporting an unavailable, failed, or incomplete execution. Nothing was measured against the gate. Do not record a row, do not substitute zero, and do not fall back to the baseline.
- **A `failed` evaluation** is a real measured outcome: the runs actually executed, and a genuine improvement, runner-family, or process gate failed. Only that may be recorded as `failed`. Missing execution evidence never becomes a failed row.

### 5. Validate the supplied artifacts

Resolve the validator relative to this skill directory and run only `check`:

```bash
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SKILL_DIR/scripts/validate_proposal.py" check \
  --root <project-root> \
  --candidate <candidate-dir> \
  --patterns <slug[,slug...]> \
  --benchmark <benchmark.json> \
  --receipt <machine-receipt.json> \
  --process-gate-receipt <process-gate-receipt.txt> \
  --proposal-diff <repo-relative-paths.json> \
  --qualification <qualification-decision.json> \
  --skill-root <repo-relative-skill-root> \
  [--new-evidence <link>]...
```

Omit `--skill-root` to use `core-rules/skills`. Repeat `--new-evidence` once per link; do not combine several links into one argument.

Interpret exits exactly:

- `0`: all evidence, provenance, atomicity, benchmark, receipt, family, process-gate, and ledger checks pass; emit the PR-ready report.
- `1`: refused or not review-ready; report the validator's reasons and do not emit a PR-ready block.
- `2`: malformed invocation or artifact; report the malformed input and do not continue.

After exit `0`, hand the unchanged inputs and report to the authorized product-pipeline record step. It may run `record` with every `check` argument plus required `--pr <https-url|not-opened>`. A record failure blocks publication; this skill must not retry by editing the candidate, receipt, ledger, or sidecar. The pipeline records the new row and sidecar before committing or opening the PR, and only records a same-row finalization after the human outcome.

Never substitute manual inspection for a failing validator and never let new evidence waive an unrelated failure.

## PR-ready report

Emit this block only after `check` exits `0`. Fill every field; do not omit a field or soften `CANDIDATE` status.

```markdown
## Wiki skill proposal

- Candidate authority: CANDIDATE (not authoritative until human merge)
- Review readiness: EVAL-PASSED
- Skill: <skill>
- Change: <create|patch exactly one skill>
- Skill root: <repository-relative root>
- Candidate directory: <repository-relative directory>
- Motivating patterns: <sorted slugs>
- New evidence: <links or none>
- Qualification: <decision file and qualifying predicate>
- Purpose backlinks: <validated exact set>
- Proposal diff: <JSON manifest path; PR-wide one-skill atomicity passed>
- Benchmark: <benchmark path>
- Score gate: <score> > <best_before> (<max covered accepted|same-run no-skill>)
- Runner models: proposer=<route>; evaluator=<route>; judge=<route>
- Process gate: MERGEABLE (<receipt path>)
- Ledger row: <exact row for the authorized record step>
- Machine receipt: <target linked sidecar path>
- Validator: EVAL-PASSED (exit 0)
- Source disposition: <retire only if fully subsumed, otherwise retain incident context with a short skill link; effective only on human merge>
- Publication boundary: authorized product automation may commit/push/open this proposal PR; human merge alone may promote it

### PR body

**CANDIDATE — not authoritative until human merge.**

This PR <creates|patches> exactly one project-local skill from the active motivating patterns above. Qualification, exact PURPOSE.md provenance, rejected-set/new-evidence handling, strict skill-creator improvement, runner-family separation, PR-wide atomicity, and a mergeable process-gate receipt were validated. The linked ledger row and machine sidecar remain durable on rejection. No validator, skill, evaluator, hook, or product automation may land this candidate; promotion requires human review and merge.
```

A report is evidence for review, not permission to merge. Before merge or after rejection, the source gotcha remains authoritative. On human merge, retire a source gotcha only when the candidate fully subsumes it; otherwise preserve useful incident context and replace only the procedure with a short link. A human revert restores any retired source in the same revert while wiki and ledger history remain durable.
