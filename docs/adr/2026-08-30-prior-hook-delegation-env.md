# ADR: delegate prior hooks with the caller environment

**Status:** Accepted
**Date:** 2026-08-30

## Context

Trellis's managed hook dispatcher can chain a prior third-party hook installed by
Husky, Git LFS, lint-staged, or an nvm-managed toolchain. The dispatcher enters
its managed body through an outer `/usr/bin/env -i` boundary. Before this change,
the delegated hook reused that sanitized `PATH`, `HOME`, and `TMPDIR`, so tools
available to Git's caller could disappear before the prior hook ran.

The failure is especially confusing when Husky and Git LFS compose with a
Trellis-managed dispatcher: the chained hook can report
`this repository is configured for Git LFS but 'git-lfs' was not found on your path`
even though `git-lfs` is installed outside the sanitized path. `HOME=/dev/null`
can similarly break Husky or nvm lookups.

Hermeticity is required for Trellis's own managed payload, but applying that
boundary to third-party code Trellis merely delegates changes the prior hook's
caller contract. A prior hook is user-installed and user-authorized code whose
plain-Git contract includes the caller's global and system Git configuration.
Delegation must preserve the environment that Git supplied to the dispatcher
without allowing those caller values into Trellis's managed execution.

Delegated `TMP` and `TEMP` must likewise follow the captured caller `TMPDIR`,
not a hardcoded `/tmp`.

## Decision

Capture the caller's `PATH`, `HOME`, and `TMPDIR` at the dispatcher head, before
the outer `/usr/bin/env -i` boundary, and carry them as quoted positional
arguments into the inner Bash process. Bind them to the non-exported inner
names `caller_path`, `caller_home`, and `caller_tmpdir`; captured bytes are data
and are never evaluated as shell code.

`trellis_run_prior_hook` reconstructs only those required caller values with
`/usr/bin/env -i` when invoking the selected third-party prior hook. Because
that hook is user-installed and user-authorized code whose plain-Git contract
includes the caller's global and system configuration, Trellis removes
`GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null` isolation from this
third-party delegation. It sets delegated `TMP` and `TEMP` to
`caller_tmpdir`, so they follow the captured caller `TMPDIR` rather than a
hardcoded `/tmp`.

In contrast, Trellis's `trellis_run_managed_payload` retains both Git-config
pins, `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null`, and remains
under its existing `/usr/bin/env -i` hermetic boundary. It receives no
caller-only value. Prior-hook selection and allowlist behavior remain
unchanged.

## Consequences

- Husky, Git LFS, lint-staged, and nvm-backed prior hooks can resolve the tools
  and home/temp locations available to the Git caller, preserving their native
  composition contract.
- The managed Trellis payload remains hermetic: caller-only environment values
  are not smuggled into its execution.
- Third-party delegation is transparent to the caller's plain-Git global/system
  configuration: the two Git-config isolation pins are removed there, while
  the managed Trellis payload retains both pins and its `env -i` hermeticity.
- Delegated `TMP` and `TEMP` consistently use the captured caller `TMPDIR`;
  they are not redirected to a hardcoded `/tmp`.
- If the caller has no `TMPDIR`, the capture is an empty string, so delegated
  `TMPDIR`, `TMP`, and `TEMP` are set-but-empty instead of unset. This narrow
  divergence is accepted because standard `${TMPDIR:-/tmp}` behavior is
  unchanged and conditional argument construction would add more shell-boundary
  risk than it removes.
- The dispatcher must safely quote the captured values and pass them through
  positional arguments; no `eval`-based reconstruction is permitted.
- This decision changes only the delegated third-party environment. It adds no
  configuration switch and does not change which prior hook is selected.
- Rollout, attached-project re-rendering, and process-gate status are outside
  this ADR; none is claimed here.
