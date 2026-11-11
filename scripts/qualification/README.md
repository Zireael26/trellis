# Source-checkout qualification tools

These tools do not ship in a sealed release. There is no implicit spec policy.
Use isolated HOME, TRELLIS_HOME (0700), TMPDIR and Git configuration. No command
here publishes, installs into the caller's home, ticks tasks, or qualifies a
release merely by collecting a record.

## Acquire a run (T73a)

T71 and T42–T44 must start from **fresh recorder/runtime clones**, not a lane
worktree with ignored caches. Follow [RUNBOOK.md](RUNBOOK.md); ignored residue
refuses by design (Round11 I-R11-2).

```sh
python3 -I scripts/qualification/record.py \
  --requirements specs/074-fast-hooks/evidence/qualification-requirements.json \
  --requirement delivery-linux --runtime /private/runtime-checkout \
  --out /private/retained-runs --run-id linux-delivery-01
```

The command comes from the selected requirement. A trailing command, if supplied,
must match it exactly. The runtime must be a checkout root, or (with
`--runtime-kind installed`) the actual active versioned `releases/<version>`
directory. The recorder's own HEAD is **not** the candidate. `cwd` is relative to
the selected runtime (`cwd_base: runtime`); expanded command paths are relative to
that directory, preserving portable fixture records. `{recorder}`, `{runtime}`,
`{candidate_sha}` and `{variant}` are the only command substitutions.

`recorder_input_digest` and `harness_inputs` bind the recorder implementation AND
its executed bench runner, case table, payloads, Pi runner, release packager and
liveness helper. Dirty or untracked inputs in that scope refuse; identity is
checked again after the command. Recorder-local imports use a fresh private cache
prefix before loading any local module: -B alone does not stop reading old .pyc.
Stray ignored bytecode in the recorder tree also refuses acquisition.

A fresh run ID reserves new files exclusively. Full stdout and stderr are kept,
with SHA-256 hashes. The exact acquisition policy bytes are retained separately
as `policy-<requirements_sha256>.json`, named by `requirements_snapshot`. A future
T34 identity or T72 selection amendment need not relabel an old T71 build:
T73b checks the retained policy hash and original command binding against the
explicit final policy, rather than accepting an unverifiable digest string. `exit` is the actual process return code, including negative
signal codes; exec failure is separately flagged. Timeout kills and joins the
owned process group, records the actual exit and timeout flag, and returns124.
An acquisition failure returns2; it never turns the child's actual exit into a
success. Interrupts retain available evidence and return130. The process does
not claim to bound or certify detached descendants that escape its process group.

Runtime input records include content hashes and Git modes. The same predicate
selects committed, untracked AND Gitignored inputs, including rendered
registrations, native build inputs and the bound suite. An uncommitted qualified
input (including a stray __pycache__) is refused by default. `--generation NAME` explicitly retains a
diagnostic generation with its own actual input digest and `clean: false`;
that label does not qualify it. Inputs are checked again after the invocation.
Build commands bind only native build inputs; their records separately capture
manifest provenance, toolchain identity and independently hashed output bytes.

The recorder creates a private0700 scratch directory under TMPDIR, or an explicit
`--scratch-base`. The runtime and scratch must have the same device identity;
otherwise acquisition refuses (choose a private scratch base on the target
volume). The child's TMPDIR and the bench's explicit --sandbox-base point there.
`platform.filesystem` and its ctime proof describe this ACTUALLY MEASURED directory,
not --out or a convenient checkout. `measurement` retains the matching device
facts. Non-APFS requirements explicitly exclude APFS; unknown target filesystem
names require an explicit reviewed policy update, never an automatic fallback.
Shared oracles are checked against their chosen cell's filesystem by T73b.

Host load is acquired before and after, not provided by the author: normal means
load1 below logical cores and no detected concurrent battery. `--variant cold`
does not alter `load`. Ctime probes write only in the owned measured scratch directory and prove
capability on that same device. `--emulated` can add an emulation label,
never remove one detected on macOS. Real hardware provenance remains essential
for Linux emulators that do not self-identify to the guest.

## Explicit 074 policy

The explicitly supplied requirements file is per-spec data, not a mirrored tool
default. The recorder tests compare it with I-A4 `--list-cases`, without measuring.
The checked-in policy maps every current I-A4 identity (not the release-note
subset), adds cold/full-repair and proof-dependent coarse-ctime regression rows,
and pins exact native build inputs and the three rule8b exclusions. Applicability
is explicit by bench platform, route and ctime capability. Legacy rows make no
accelerated claim; coarse-ctime full verification uses the same-host relative
bound even on legacy routes. Independent in-process/metadata paths retain numeric
budgets. Active-work walls are report-only, never assigned a fabricated25ms bound.

T34's cutover identity is deliberately null until known: the checker must refuse
release qualification until it is bound. When T17/T48/T49/T59 extend the matrix,
update and review this explicit policy before T45. Final suite filters and installed
harness-version coverage must likewise be reviewed by their qualification owners;
a zero-test filter, skipped oracle or absent required row is never a pass.

`bench-log.py` transports the actual bench JSON into the retained stdout log. It
runs30 iterations plus two warmups against the selected source runtime. A variant
label never manufactures missing observations or overrides frozen I-A4 status or
eligibility. Thus current diagnostic proxies and open timing boundaries cannot
qualify until their measurement owners supply eligible evidence.

## Schemas and fixture boundary

`schema.py --schema receipt|run-record|requirements <file>` validates the closed
schemas without a third-party package, including duplicate-key, finite-number,
strict-type and unknown-field refusals. This is acquisition validation, not a
qualification verdict. The checker is the separate T73b task; see [CHECKER.md](CHECKER.md) for its
explicit CLI, policy/catalog bindings and T71/T34/T72 provenance rules.

The recorder test suite never invokes the checker. Its explicit fixture producer
runs the real recorder from private committed checkout A against independent B,
a genuine object/tree copy of pinned3661cb5f2, and a dirty B generation. Only host
telemetry is controlled to make synthetic unit fixtures portable. Child execution,
input identities, exits, output bytes and hashes are real. These are **test-only
records**, not measured release receipts; see the fixture README for regeneration.
