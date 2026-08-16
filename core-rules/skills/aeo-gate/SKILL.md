---
name: aeo-gate
description: Deterministic AEO scanner for mapped public sites. Provides a full baseline, warn-only pull-request diff, and optional citability review while preserving pinned raw evidence and separate SEO/AEO impacts.
---

# aeo-gate

Trellis-owned, harness-neutral AEO gate. It wraps `geo-optimizer-skill==4.16` and adds checkout/domain proof, crawler probes, raw no-JavaScript inspection, full-graph JSON-LD analysis, evidence grading, triage, stable deltas, and checksummed evidence.

The accepted contract is `specs/033-aeo-gate/spec.md`. That spec wins if this file drifts.

## Status

| Mode | Command | Status |
|---|---|---|
| Baseline | `scripts/run-baseline.sh` | shipped |
| Diff | `scripts/run-diff.sh` | shipped, warn only |
| Deep citability review | `scripts/run-deep.sh` | shipped, optional |
| Fleet baseline | `scripts/run-fleet.sh` | shipped; scheduler wrapper pending |

## Invariants

1. Step 0 proves that the scored checkout builds the live domain. Unproven mapping is `INDETERMINATE`, not a finding or pass.
2. Raw scanner output is evidence input, never a public work order.
3. Public output has separate SEO and AEO impacts and no blended or standalone composite score.
4. Every finding carries `STRONG`, `MODERATE`, or `SPECULATIVE` evidence.
5. `llms.txt` cannot change status or produce remediation.
6. JSON-LD checks walk nested objects, arrays, and `@graph`, and distinguish absent, vacuous, and populated values.
7. Presentation, aria-hidden, and deliberate empty-alt images never receive alt-text remediation.
8. Failed stages retain raw output. Any incomplete required stage makes the run `INDETERMINATE`.
9. Initial diff rollout is non-blocking for every internal status.

## Toolchain

- Python 3.11+ standard library.
- `uvx --from geo-optimizer-skill==4.16 geo audit ...` for the pinned upstream scan.
- Optional `llm` CLI for bounded finding triage and deep review. Both are disabled unless explicitly requested, local inference is the default, and a remote provider requires a mode-specific confirmation flag. Scheduled execution never invokes either model path.

Missing or wrong tool versions fail closed. Tests use fixture scanner JSON and local HTML, never production domains.

## Mode 1: Baseline

```bash
bash core-rules/skills/aeo-gate/scripts/run-baseline.sh \
  --project <registry-name> \
  --url https://example.com \
  --checkout /path/to/checkout \
  --output audits/evidence/<run-id>/<project> \
  --marker-file path/in/checkout \
  --marker '<stable marker>'
```

Optional operational inputs:

- `--baseline <path>`: compute a delta against an exact-identity, manifest-valid, non-fixture `PASS` baseline.
- `--timeout <seconds>`: per network/scanner ceiling.
- `--triage`: opt into bounded local Ollama finding triage; omitted by default in baseline, diff, and fleet runs.
- `--triage-provider ollama` / `--triage-model <model>`: bind live triage to the local `ollama` executable.

`--html-file`, `--scanner-json`, `--triage-response-file`, `--response-file`, and fleet fixture directories are test-only. The CLI rejects them unless `AEO_GATE_ALLOW_FIXTURES=1`; their baseline output is marked `fixture: true` and cannot become accepted comparison evidence.

Outputs in the run directory:

- `baseline.json`: `aeo-gate.baseline.v1` normalized contract.
- `baseline.md`: human rendering of the same validated records.
- `raw/`: attributable probe and scanner artifacts.
- `manifest.json`: relative paths, byte counts, and SHA-256 checksums.

Exit `0` means a complete run. Exit `2` means `INDETERMINATE` or an invocation/contract error.

## Mode 2: Diff

```bash
bash core-rules/skills/aeo-gate/scripts/run-diff.sh \
  --project <registry-name> \
  --url https://example.com \
  --checkout /path/to/checkout \
  --output <run-dir> \
  --marker-file <path> \
  --marker '<marker>' \
  --baseline <accepted-baseline.json> \
  --range origin/main..HEAD
```

Diff records affected page files, repeats mapping and deterministic probes, and emits new, unchanged, and resolved fingerprints. The internal result is `PASS`, `REGRESSION`, or `INDETERMINATE`; the rollout adapter always exits `0` after a valid invocation and prints `AEO GATE (WARN ONLY)`.

## Mode 3: Deep review

```bash
bash core-rules/skills/aeo-gate/scripts/run-deep.sh \
  --html <pinned-rendered.html> \
  --baseline <accepted-baseline.json> \
  --output <run-dir> \
  --provider ollama \
  --model <local-model>
```

Deep review accepts at most 12,000 visible-content characters plus a bounded, manifest-validated deterministic baseline context. It only reviews answer-first structure, statistics, quotations, and external authority citations. Its output is marked `MODEL_DERIVED`; it cannot set deterministic grades, fingerprints, or raw-evidence references.

Local execution is bound to loopback `ollama run`; proxy/credential environment is removed and Ollama cloud model tags are rejected. Public probes use default ports, reject credentials/query strings/private addresses, pin validated DNS addresses into direct sockets, and prohibit cross-host redirects or HTTPS downgrade. A remote provider requires a provider-qualified model ID, `--confirm-remote`, an interactive TTY, and an exact `provider:model` confirmation immediately before the provider-neutral wrapper runs. Non-interactive scheduled execution never invokes deep review.

## Manifest verification

```bash
python3 core-rules/skills/aeo-gate/scripts/aeo_gate.py verify-manifest <run-dir>/manifest.json
```

Absolute paths, path escapes, symlinks, missing files, byte-count drift, and checksum drift fail verification.

## Fleet schedule

`scheduled-tasks/aeo-baseline/` is scheduler-ready for a monthly macOS-host run. The
tracked `targets.md` is a contract document carrying no roster; the roster, registry
and exclusion inputs are machine-local and rendered by
`scripts/materialize-scheduled-task.sh` into `$TRELLIS_HOME/tasks/<fleet>/aeo-baseline/`:

```bash
TASK_ROOT="${TRELLIS_HOME:-$HOME/.trellis}/tasks/<fleet>/aeo-baseline"
bash core-rules/skills/aeo-gate/scripts/run-fleet.sh \
  --targets "$TASK_ROOT/aeo-targets.md" \
  --registry "$TASK_ROOT/registry.md" \
  --blacklist "$TASK_ROOT/blacklist.md" \
  --output audits/aeo-baseline/YYYY-MM-DD \
  [--previous-root audits/aeo-baseline/<previous-date>]
```

`--registry`/`--blacklist` name materialized local inputs, not tracked fleet inventory:
the tracked `registry.md`/`blacklist.md` were removed at `v1.0.0-rc.25`. The target set
accounts for `registry minus blacklist` through active and explicit-skip tables. The fleet command invokes Mode 1 with no LLM, isolates domain failures, validates every target manifest, and writes a dated fleet rollup plus a fleet manifest. Scheduler registration remains a separate operational step; do not describe the cadence as active until the wrapper exists.

## Multi-harness surface

The same canonical directory is linked into project-local Claude Code and Codex skill roots by the existing Trellis rollout mechanism. Do not fork the implementation per harness.

## Boundaries

- Reads public pages and local source; never modifies source, deployment, DNS, or Cloudflare.
- Does not ingest GSC, run prompt panels, track customer citations, or store per-workspace state.
- Does not scan a domain whose checkout mapping is unproven.
- Does not enable blocking enforcement without a later measured operator decision.
