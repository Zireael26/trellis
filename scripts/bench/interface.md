# I-A4 bench interface (074 T2): partially frozen

## Frozen portions — apex Round 4 acceptance

The apex accepted these parts at `0f5450a91c3883ab9225b635e44d885daafd3016`,
with the authorized warmup-eligibility and deadline-cleanup errata below:

- observation schema, including `aggregation_eligible`;
- four-value status vocabulary and blocked/not-measured semantics;
- error, teardown-error, operation-timeout and callback-timeout semantics;
- sandbox quarantine, blocked rows and bounded drain/retention rules;
- the non-ok aggregation ban;
- definition of fast and `checkout_proof`/`hook_execution` evidence;
- `sc1_eligible`, `sc2_eligible`, `sc13_eligible` and the no-excuse rule.

**I-A4 errata — apex t1 ruling, 2026-11-04 (A4/B4 T17 coordination):**
the missing-only memo oracle below admits pre-T17 full reconciliation or a
verified generator rebuild with successful full reproof. Both require a
rewritten memo and positive full-proof evidence. This is the only change to
the frozen checkout contract; the definition/evidence of `fast` is unchanged.

**I-A4 additive re-freeze — apex T69 ruling, 2026-11-06:** an eligible
ordinary-push SC13 row is authorized without changing the existing deletion-ref
diagnostic or the observation/status contract. The current ordinary-push row
is disabled pending the evidence obligations below; authorization is not proof.

T42–T44 and B2 may build against **only** these frozen portions. Changes must
return through the A4 owner for re-freeze. The case/fixture descriptions below
remain candidate where they cross the explicitly open T2 boundaries. Matrix
`candidate-not-frozen` is not a revocation of the frozen observation contract.

## Case matrix and anchors

`python3 -I scripts/bench/trellis-latency.py --list-cases` returns a
`trellis-bench-case-matrix/1` object with `status: candidate-not-frozen` and
`cases[]`. Each expanded row has `id`, `fixture_id`, `boundary_id`, `variant`
and `owner`. IDs are unique. Existing IDs are retained; `claude R1 ...` and
`claude R2 ...` identify additional rendered-form comparisons.

`scripts/bench/cases.json` is `trellis-bench-case-table/1`, with exactly
`schema`, `status`, `hook_groups`, `pi_tools`, `pi_handler_events`, `anchors`.
Every anchored row contains exactly `id`, `fixture_id`, `boundary_id`,
`variant`. Anchors reserve independent extension sections for T2, T17, T48,
T49, T59 and T69. A matrix row is not evidence that its registration exists or that
its fixture was executed. Unregistered surfaces are `not-measured`, not zero.

## Payload corpora

`payloads/native-cases.json` has exactly `schema: trellis-native-cases/1` and
`cases`. A case has exactly `id`, `surfaces`, `event`, `tool`, `payload`,
`patch`, `fixture`, `decision`, `expected_exit_codes`:

- `id` is a unique lower-case `[a-z0-9-]+` suffix; `surfaces` is a nonempty
  array drawn from `claude`, `codex`, `pi-dispatch`.
- `event` is the event name, `tool` its matcher or null, and `payload` an
  existing JSON leaf under `payloads/`. `patch` is a top-level replacement,
  not recursive merge; `@PROJECT@` is substituted with the fixture project.
- `fixture` selects a closed recipe; `decision` is `allow`, `warn`, `deny`,
  or `unsupported`; `expected_exit_codes` is a nonempty integer array.

`payloads/skill-cases.json` has exactly `schema: trellis-skill-cases/1` and
`cases`. Each case has exactly `id`, `name`, `fixture`, `bytes`, `encoding`,
`decision`, `expected_exit_codes`. `bytes` is the whole manifest byte count,
including frontmatter, or null for unknown names; `encoding` is `utf8` or
`invalid-utf8`. Qualified names share the underlying unqualified manifest.

## Observation and receipt

Every executed observation includes:

```
case_id: string, fixture_id: string, boundary_id: string,
warmup: boolean, exit: integer|null, member_exits: integer[],
exec_error: boolean, readiness: boolean,
readiness_kind: "proven" | "no-denial", readiness_ms: number|null,
timeout: boolean, callback_timeout: boolean, wall_ms: number|null,
aggregation_eligible: boolean
```

`wall_ms` is completion of the measured process group or handler. A separate
verification-only readiness probe occurs after that timestamp and is recorded
as `readiness_ms`; teardown is excluded. Its result still rejects an incomplete
observation. Warmups and failed observations are retained, but do not enter
statistics. `aggregation_eligible` is true **only** when the row is `ok` and the
observation has `warmup:false`; warmups on otherwise-ok rows are still false. Each process group and its setup/readiness/teardown callbacks share
an independent deadline. If that deadline interrupts the hook proof, its
cleanup does not start a new branch restoration or postjob join after the alarm
has fired; the timeout propagates and quarantine retains the tree instead.
`exit` and `member_exits` always describe the measured
operation: an operation timeout is `exit: 124`, `timeout: true`. A later setup,
readiness or teardown timeout sets `callback_timeout: true` and
`callback_timeout_phase`; it does **not** change an already observed operation
exit or set the operation's `timeout` flag. An unstarted operation has null exit.
`exec_error: true` distinguishes a failed spawn from a real exit 127. Error
records include their phase, exception type and message; the first error is
preserved, with a later teardown error separately in `teardown_error`. A no-denial result is
not positive evidence of payload recognition and must not qualify as proven.

Each case record has closed status `ok`, `failed`, `diagnostic`, or
`not-measured`. Every non-`ok` record carries null aggregate wall/CPU/serial and
per-member wall statistics and never feeds summaries or p50 logging. `diagnostic`
means the operation ran but lacks an eligible acceptance boundary or supported
capability; it is **not N/A** and cannot excuse a required SC1, SC2 or SC13 case.
Raw `observations[].wall_ms` on **every non-ok row** are forensic evidence only:
consumers MUST NOT calculate percentiles, aggregate them or use them for a
criterion, headline, reference turn or regression claim. Such observations have
`aggregation_eligible:false`, irrespective of their raw numeric values.
`not-measured` is not automatically N/A: it can identify an absent registration
or unsupported host, but a quarantined sandbox produces blocked skipped rows
with `blocked:true` and phase `skipped-after-sandbox-integrity-failure`. Those
rows cannot excuse any required case. Logging occurs after final status and
cleanup outcome are known. `fixture_id`, `boundary_id`, `variant`, `load` and expected outcomes
remain attached to failures. `--condition normal` is downgraded to
`load-contended` when host load or a gate is observed; `declared_condition`
retains the request. Percentiles use linear interpolation between adjacent
ranks, rounded to 0.1 ms.

Pi pre/post/lifecycle samples retain per-handler exec calls, result transport
and proof strength. `pi tool_call edit/write failed/native` rows are labelled
with `alias_of` the corresponding plain tool-call row: their result shape only
changes the post-action. A missing `agent_before_settle` handler is N/A until
registered. A valid independent TypeScript probe may establish an unsupported
host; extension import/initialization errors and missing required handlers fail.

## Registration and boundary caveats

Claude R1 and R2 use the selected release's renderer with its form-selection
predicate forced in private fixtures. Each records `claude_version`, version
probe exit, registration form, render selection, the R1 minimum version and
the historical 1.4.0 R2 label. A forced renderer fixture does not establish host
support or a live harness execution trace.

Until an event-driven ready-worktree completion boundary exists, attached
`git-worktree-add`, attach-current/new and callback observations have status
`diagnostic` with `sc1_eligible: false`, not SC1 timing evidence. Readiness joins
the relevant postjob with a deadline **after** the operation timestamp; this
verification cost is only `readiness_ms`, never `wall_ms`. A failed lifecycle row
is retained and later requested items still run, in request order; receipt status
is `failed` when any contained row fails, rather than an aborted section.
Only ordinary row failures may continue. A `TeardownError`, callback/operation
timeout or secondary teardown error quarantines the sandbox: remaining requested
rows are emitted as blocked `not-measured`, never measured there or summarized.
The sandbox is retained, with the quarantine reason in its receipt. Ordinary
cleanup confirms a bounded process drain before deletion; unavailable or
incomplete drainage retains the tree and revises the receipt to failure.
KeyboardInterrupt stops the run through the outer abort path; case boundaries
do not convert interrupts or SystemExit into ordinary row failures.
Both `git-switch` and `git-switch-fast` retain `checkout_proof` binding the real
hook/memo digests and owner/audit state before and after the switch. An untimed
`GIT_TRACE2_EVENT` proof must show successful execution of the expected actual
post-checkout hook using the **same member argv**; its trace/source hashes are
retained. The timed launch must match that verified argv, and carries no trace
instrumentation. Only that positive hook proof plus unchanged valid memo and
audit state can be labelled `fast`; no hook execution is not fast. A regenerated
memo plus a new audit proves full reconciliation. The `-fast` row rejects full reconciliation;
the missing-only memo row admits exactly `full-reconcile` (pre-T17) or
`verified-generator-rebuild` (T17). Both require an absent-before/valid-after
rewritten memo, positive hook execution, a successful full current-worktree
reproof and agreement with independently regenerated verified-generator memo
bytes. Its `memo_repair` evidence records `full_proof_ran`,
`full_proof_succeeded`, `generator_verified`, `memo_rewritten`, source hashes
and retained probe logs. This full reproof and generator check run as untimed
readiness, outside `wall_ms`; they do not claim observed internal T17 spans.
A malformed, present-but-mismatched or drifted memo never qualifies as a
missing-only rebuild: it still requires full reconciliation. A generator
rebuild without a successful full reproof fails.
The multi-root diagnostic runs two complete installed show-config invocations
and requires their output to report both exact roots. It is explicitly
`sc2_eligible:false`: concurrent invocations are not the required SC2
single-command boundary in a two-attached-root fixture. The `pre-push-dispatcher` runs a private xtrace-only dispatcher
copy to prove both checks, carrier classification and no battery invocation;
it is `sc13_eligible: false` and never supplies timing evidence. The separate
`pre-push-dispatcher-ordinary` row below is also currently ineligible.
Instrumented active-Python fixtures are functional diagnostics, not qualified
linter or reviewer measurements.

### SC13 ordinary-push dispatcher row

`pre-push-dispatcher-ordinary` is currently `not-measured` with
`sc13_eligible: false`: requesting it starts no SC13 fixture or operation and
produces no observations or aggregates. The internal measurement helper also
refuses to run; finalization cannot promote this row to an eligible or `ok`
result. The existing deletion diagnostic remains unchanged.

The proposed boundary directly invokes the installed managed hook with a
representative branch-update ref and remote arguments; it does not include Git's
launch or network transport. Any eventual baseline must use the same boundary.
The private fixture code and pinned-baseline fixture test are retained for
further work, not as qualification evidence. Before enabling the row, establish:

- untimed positive execution evidence, bound to the measured fixture and asset
  identities, for both actual postjob invocations and the carrier, with
  behavioral mutants that remove each invocation;
- independently bound source identity (installed/reused metadata alone is not
  a source commit), with negative tests for unverified identities;
- a realistic local remote and `origin/HEAD`, plus evidence that the chosen Git
  hook ABI and ref stream represent the intended ordinary-push boundary; no Git
  push, including dry-run, is authorized by this task;
- safe process-group drainage and quarantine, or durable fail-closed quarantine,
  for fixture setup timeouts that prevents later rows from proceeding.

The retained fixture's gate-marker output and generator byte comparison do not
prove those execution obligations. The qualification requirements matrix also
needs its owner's separate update. This temporary `not-measured` state is not a
measured SC13 miss or a release-qualification claim; T42/T44 remain responsible
for qualified measurements and the final SC13 result.

## Explicit open T2 boundaries — not frozen; no consumer dependency

SC1, SC2 multi-root, SC13 qualification, variants, traces and the quiet
baseline remain open. T42–T44 and B2 must not treat diagnostic or disabled rows
as qualification. The approved additive SC13 re-freeze does not make the
current implementation eligible or close the remaining T2 scope.

- **SC1:** event-driven ready-worktree/attachment completion boundary.
- **SC2 multi-root:** an eligible single full show-config invocation in a
  two-attached-root fixture; the current two-invocation diagnostic is not it.
- **SC13 qualification:** the ordinary-push proof obligations above, then a
  same-boundary pinned baseline and host-qualified measurements.
- **Variants:** real toolchain/reviewer, cold and full-repair variants and
  outstanding native-parser/memo-span/complete attachment-proof coverage.
- **Traces:** actual U1 and E2–E4 launched-process evidence.
- **Quiet baseline:** same-host pinned `3661cb5f2` baseline, with no timing
  claim before the authorized T42–T44 qualification runs.
