# Public dependency bootstrap — design spec

**Date:** 2026-07-21
**Status:** IMPLEMENTED
**Scope:** public mirror publication for the fleet dependency validator

## Problem

Trellis owns a dependency baseline and a per-finding remediation ledger, but the
instance copies contain private fleet identities, workspace paths, audit report
names, and remediation receipts. The public mirror correctly excluded those
files while still publishing `scripts/fleet-dependencies.mjs` and the
`trellis deps` command. A fresh public clone therefore exposed a command whose
default inputs did not exist.

## Decision

Keep the instance baseline and ledger private. During mirror staging, copy the
two files only as exact allowlisted paths and replace their contents before leak
checking with deterministic, schema-valid public bootstrap shells:

- the baseline retains policy semantics but starts with empty toolchain,
  package, security-floor, and exception arrays;
- the ledger retains its schema and audit date but starts with empty report and
  finding arrays;
- `registry.md` and `blacklist.md` remain public-only empty templates;
- their placeholder rows are ignored by the validator;
- no audit report, project identity, compatibility lane, security exception, or
  evidence receipt crosses the mirror boundary.

After projects are registered, a public maintainer can run `trellis deps
snapshot --ref worktree --output <candidate>` and deliberately review their own
baseline. Snapshot generation never imports the private Trellis instance.

## Rejected alternatives

- Publishing the live baseline or ledger would disclose private fleet topology
  and security/audit evidence.
- Omitting the files leaves a documented command broken in every fresh clone.
- Generating public defaults at CLI runtime hides repository state and makes the
  baseline harder to review and version.

## Acceptance

- A simulated and real public mirror pass the full denylist lint.
- `trellis deps check --ref worktree` reports zero projects and zero findings in
  an untouched public clone.
- `trellis deps ledger-check` validates the public ledger.
- Mirror tests seed private markers in both source files and prove none reach the
  staged public files.
- Repeated syncs are deterministic and produce no follow-up diff.
