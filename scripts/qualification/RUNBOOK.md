# Qualification acquisition preflight (T71 and T42–T44)

**Start every qualification runtime AND recorder checkout from a fresh clone.**
Do not use a development lane worktree or an archive over an existing directory.
Ignored inputs now refuse too: `.mypy_cache/`, `.ruff_cache/`, `__pycache__/`,
`.DS_Store`, local settings and other stray files cannot silently escape the
executed-input digest. This is a fail-closed requirement, not a request to clean
or waive an existing working tree (Claude Round11, I-R11-2).

1. Obtain the approved candidate/source SHA and explicit requirements file from
   the apex. T71 uses its frozen native-build source; runtime/bench qualification
   follows the actual T34 cutover. An unset cutover must never qualify a release.
2. Create fresh private clones, with private HOME, TRELLIS_HOME0700, TMPDIR and
   Git configuration established before any Git write. Keep outputs outside the
   clones. `git status --porcelain --ignored` must show no residue before starting;
   the recorder itself remains the authoritative qualified-input check. Do not
   open the clones in tools that generate caches or local settings first.
3. Put the runtime clone and the private scratch parent on the filesystem being
   qualified. Set TMPDIR there or use `record.py --scratch-base <private-parent>`.
   The recorder owns a new0700 child, binds its device to the runtime, passes it as
   child TMPDIR and bench --sandbox-base, and records filesystem/ctime there.
   Moving only --out or the checkout is not a filesystem qualification.
4. For T71, use the pre-provisioned pinned build tools, preserve their actual
   identity/output records, and do not relabel the build source when T34 lands.
   The immutable acquisition policy snapshot verifies the original command even
   when the final reviewed policy later binds T34's identity.
5. For T42–T44, take both after and pinned3661cb5f2 before runtimes from fresh
   clones on the SAME host/filesystem and fixture boundary. The recorder checkout
   is independently fresh/current; its acquired bench/helper inputs must match
   the final matrix/harness pins. Preserve two warmups and at least30 successful
   observations; cold/full-repair/coarse-ctime are required variants, not excuses
   to drop cases as diagnostics. Observe the apex's quiet/load/liveness rules.
6. Retain each run JSON, both logs and `policy-<sha256>.json`, plus quarantined
   bench evidence. Feed them explicitly to T73b with the reviewed requirements.
   Never turn an acquisition error, dirty generation, timeout, contended run or
   unsupported boundary into a PASS claim.

Recorder import-cache and owned scratch directories may remain in TMPDIR,
including after a refusal (Round11 I-R11-1, deferred cleanup follow-up). Keep
quarantined evidence; do not remove a sandbox while children/postjobs may run.
No instructions here authorize live-home cleanup, policy waivers, task ticks,
release timing claims, merges or pushes.
