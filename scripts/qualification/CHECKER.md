# Consume qualification evidence (T73b / T45)

The checker reads evidence and Git; it does not run an oracle, bench, build,
installer, suite-discovery program or code from a receipt. Supply a reviewed
requirements file explicitly. Its bytes must equal the file committed at
`specs/074-fast-hooks/evidence/qualification-requirements.json` in the resolved
checked head; an uncommitted or weakened local copy cannot replace that policy.
The output identifies that canonical path and its SHA256. There is no implicit074
policy data in a mirrored tool.

```sh
python3 -I scripts/qualification/check.py \
  --requirements specs/074-fast-hooks/evidence/qualification-requirements.json \
  --repo "$FRESH_CANDIDATE" --head "$APPROVED_T45_SHA" \
  --receipt "$RECEIPTS/artifacts.md" \
  --receipt "$RECEIPTS/arm64-macos.md" \
  --receipt "$RECEIPTS/x86_64-macos.md" \
  --receipt "$RECEIPTS/x86_64-linux.md" \
  --receipt "$RECEIPTS/aarch64-linux.md" \
  --receipt "$RECEIPTS/macos-fallback-fs.md" \
  --receipt "$RECEIPTS/harness-conformance.md" \
  --receipt "$BENCH/macos-apfs.md" \
  --receipt "$BENCH/macos-nonapfs.md" \
  --receipt "$BENCH/linux.md" \
  --run-record "$RUNS/first.json" --run-record "$RUNS/second.json"
```

For **T45**, replace the illustrative `--run-record` arguments above with
`--evidence-dir specs/074-fast-hooks/evidence/runs` (relative to `--repo`).
Commit the complete recorder-output directory first: run JSON, adjacent logs and
hash-named acquisition policy snapshots, including nested platform directories.
The checker enumerates every run record and requires the entire directory's
physical inventory, bytes and modes to equal checked HEAD. Missing, untracked,
changed or symlinked files refuse; unknown JSON refuses rather than being silently
ignored. This makes omitting an acquisition a visible committed-evidence change.
T45 output belongs outside that input directory. Receipt files remain explicit.

`--run-record` remains for explicit unit/diagnostic use and cannot be combined
with directory mode. Pass **every** referenced after/before/build/oracle run;
the two names above are illustrative, not a sufficient battery. Preserve adjacent
stdout/stderr and policy-<sha256>.json snapshots. Never supply sc13-early.md.
Receipt files start with a fenced JSON block conforming to receipt.schema.json.
The checker emits deterministic JSON with head, final requirements hash, T71
source and manifest generation, per-cell/criterion outcomes, errors, and two
separate booleans. Exit0 means release_eligible, NOT necessarily all_criteria_pass.
SC13 alone may be BLOCKED by a VALID measured miss; missing/unmeasured/failed SC13
is FAIL. T45 owns writing qualification.md from this output and its evidence links.

**Deferred cells (T73b).** A runtime cell listed in the requirements'
`deferred_cells` (closed rows: cell, task, decision, reason) is not
hardware-qualified. Its `--receipt` file instead starts with a closed
`trellis-qualification-deferral/1` block: exactly {schema, cell, task, deferred:
true, decision, reason, existing_proof}, the first four equal to its row and
existing_proof a non-empty list. In 1.5.0 these are `x86_64-macos.md` (T36) and
`aarch64-linux.md` (T38). The checker refuses a deferred cell with no block, a
block for a cell that is not deferred, and any receipt or run for a deferred
cell, whatever its verdict. The cell reports DEFERRED and the output lists it
under `deferred`. The release may be eligible, but all_criteria_pass is false
while any cell is deferred. Rule 5 is unchanged: a deferred cell is not
qualified on another platform.

**Deferred benches (T42-T44).** Owner ruling 2026-11-10: the release benches
run after 1.5.0. A bench listed in `deferred_benches` (closed rows: bench, task,
decision, reason) is evidenced by a closed deferral block with `bench` in place
of `cell`: exactly {schema, bench, task, deferred: true, decision, reason,
existing_proof}. In 1.5.0 these are `bench/macos-apfs.md` (T42),
`bench/macos-nonapfs.md` (T43) and `bench/linux.md` (T44). The cell rules apply
unchanged: a deferred bench with no block, a block for a bench that is not
deferred, and any bench receipt for a deferred bench are each refused. The bench
reports DEFERRED and is listed under `deferred_benches`.
- A cell's bench command whose unique budget owner is a deferred bench is not
  required (T39 keeps its oracles). The output names it under
  `deferred_bench_commands`, and a run for it is refused as unknown or uncited.
- Every criterion with case rows budgeted by a deferred bench (SC1-SC10 and
  SC13 in 1.5.0) reports DEFERRED, never PASS. A functional FAIL stays FAIL.
- release_eligible needs no errors, every undeferred cell PASS, and every
  criterion PASS or DEFERRED by that policy (SC13 may still be BLOCKED when
  measured). all_criteria_pass stays false.
- When eligible with deferred benches, `summary` reads "functional
  qualification complete; timing criteria SC1-SC10 and SC13 deferred:
  post-release measurement". T45's qualification.md carries that line and never
  says the timing criteria passed.

## Acquisition / policy bindings

Use record.py --phase build for T71, --phase after for final benches, and --phase
before against the genuine pinned3661cb5f2 runtime. Default oracle phase is for
functional commands. Follow RUNBOOK.md: fresh clones, private homes/configuration,
outputs outside source, owned scratch on the measured filesystem.

Every run's exact original policy snapshot is hashed and schema-checked. Its
command ID/argv/cwd/suite/filter/format/exit/input-set binding must agree with the
explicit final requirements. Thus T34's formerly-null identity or a reviewed
catalog can be added later WITHOUT relabelling a T71 build or accepting an
unverifiable hash string. The final cutover_commit must be set and integrated;
unset always fails closed. Acquisition error, non-clean/non-stable runtime,
explicit generation, timeout or exec error never qualifies, even with child exit0.

Functional oracle/build records may honestly be contended: no timing claim is
inferred from them. ALL counted bench runs, envelopes, rows and before runs must
be normal-load and quiet. Counts, exactly two discarded warmups, individual exits,
readiness, eligibility, and linear-interpolated percentiles rounded to0.1ms are
re-derived from raw observations. Non-ok walls, including member walls, are never
used. Parent aggregate/summary numbers are not authoritative.

Ctime classification is re-derived from the retained three-sample same-device
probe using the recorder's exact predicate. Coarse evidence must positively fail
the fine predicate; an empty or contradictory probe cannot exempt a budget.
Unknown ctime is diagnostic only: the qualifying recorder path cannot produce it,
so it cannot justify N/A. Valid measured coarse evidence and its required
fallback/regression budgets remain supported. This verifies evidence consistency,
not cryptographic host attestation; the checker never re-probes its own host.

Every consumed build, oracle, after and pinned-before record must name a real
recorder commit ancestral to the checked head. Its complete acquired harness map
(paths, modes and SHA256 values) must equal that commit's Git objects, not merely
its own recomputed digest. Recorder implementation code/data under
`scripts/qualification/` must also match checked HEAD: `record.py`, `model.py`,
`schema.py`, `bench-log.py`, all schemas and any additional non-Markdown files.
`check.py` and Markdown documentation are excluded only from that HEAD
implementation comparison; their original acquired hashes still must match the
named recorder commit. There is no implicit historical-recorder allowlist.
A recorder implementation change therefore requires fresh acquisition even when
the separately scoped runtime inputs did not change.

The recorder's acquired bench/helper map must match final Git and matrix pins,
independently of runtime inputs. Bench schema, source commit, host cardinality,
battery flag and raw load are checked where required by bench_schema. The actual
074 policy requires the complete I-A4 envelope. A matching displayed percentile,
variant label or receipt verdict cannot repair missing proof.

Every supplied run record must be explicitly cited by a receipt or an applicable
case's before-run list; uncited passing and failing acquisitions both refuse.
For each after case, all supplied same-command/same-host before runs containing
that case must be cited. Each before invocation is independently validated;
its discarded warmups never pool. All retained measured before observations are
then pooled for the baseline p50/p90, so a slower invocation cannot be selected
while hiding a faster supplied one. Duplicate case rows within one run refuse.

A cell's benchmark applicability/budgets come from the unique release-bench
owner of its required bench commands; missing or ambiguous ownership refuses.
There is no implicit macos-nonapfs budget for arbitrary cells. Literal T39
SC13 cell BLOCKED semantics are unchanged pending the owner's target decision.

Filesystem reads are bounded: 8 MiB for run records, receipt blocks, requirements
and acquisition snapshots; 128 MiB per retained log. Oversize input refuses
before parsing. The private import-cache directory is removed on process exit.

## T40: source-bound Node oracle catalogs

Bats names are derived from the suite/filter at candidate_sha. Dynamic Node test
factories cannot be evaluated safely by a read-only checker. T40 must populate
reviewed **expected** catalog data in each explicit Node command requirement:

```json
{
  "tests_source_sha256": "<sha256 of that suite's exact Git bytes>",
  "tests": ["outer test"],
  "nested_tests": {"[\"outer test\"]": ["first child", "second child"]}
}
```

The fixture records actual Node TAP, but the checker itself NEVER executes Node
or suite code to discover names. Catalog all selected top-level and nested tests,
with nested parent paths encoded as canonical JSON arrays. Every group's names,
ordinals and plan must match; failure, skip, todo, absent child, substituted suite
and uncatalogued nested output fail. Node's '# todo 0' summary is NOT a directive.
A missing/stale catalog refuses. Final T40 versions/source are not known yet;
current074 Node commands deliberately have no invented catalog or PASS fallback.
Apex explicitly accepted this final-data obligation before T73b integration.

## T71 versus T34 / T72

Build provenance checks only frozen native inputs, toolchain identities and exact
output bindings. T34 payload/template/render changes do not stale T71. Build-host
OS must match the target family; Linux cross-architecture compilation is build
provenance, NOT native runtime qualification. Runtime cells separately require
the actual target architecture and reject emulated native qualification.

T72 keeps original T71 run IDs, source and built-output bindings, including the
removed target. Its recorded single-parent change may remove only the aarch64
selection plus explicitly byte/mode-bound pin/render inputs. Per apex ruling,
it may also DELETE exactly that removed entry's former asset path: its old hash
and size must match the pre-change manifest, with no replacement and no other
asset edit. Remaining shipped bytes and entries stay identical; the final native
directory must remain closed. The exception never grants a path-wide exemption.
requirements.input_sets.selection_only_inputs records each allowed pin/render
path, before/after SHA256 AND modes, target, and role. Empty means no such change
is permitted. An exempt executed input must match the exact T72 parent bytes
and mode at acquisition, and the exact T72 result bytes and mode at final HEAD;
a later edit, deletion or chmod is not exempt. Every other runtime input
add/remove/content/mode change stales qualification. Only the three named rule8b exclusions are unconditional.

## Still not release evidence

Unit fixtures and their passing booleans are synthetic, not a qualified release.
T34 identity, final T71/T72 artifacts, T40 catalogs and platform/version receipts,
updated I-A4 policy when row owners extend it, and T42–T44 eligible quiet baselines,
variants and traces (post-release, owner 2026-11-10) remain release-owner obligations. No tool here creates those
measurements, approves an exception, ticks a task, pushes or merges.
