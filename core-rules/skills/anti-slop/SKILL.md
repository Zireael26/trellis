---
name: anti-slop
description: Evidence-doctrine tooling for any registered Trellis project. Use to audit a repo for slop patterns before a de-slop cleanup session, and to install a per-language profile (TypeScript, Python, and Java live; Go and Rust dormant) so the project's own lint hooks enforce it. Not for turn-time enforcement — the tripwire hook and the process-gate row own that.
---

# anti-slop

Annotations, casts and mocks are evidence. Slop keeps the claim and drops the proof: it
compiles, it passes, and it has stopped telling the truth. This skill is the audit plus
the per-language configs that make the native linters enforce the doctrine — no
enforcement of its own.

Doctrine: [`core-rules/references/anti-slop.md`](../../references/anti-slop.md). The
executable source of truth for the pattern layer is
[`hooks/lib/slop-patterns.sh`](../../hooks/lib/slop-patterns.sh); if prose and lib
disagree, the lib wins.

## When to use

- **Auditing a repo before a de-slop session.** `scripts/audit-slop.sh` enumerates every
  violation in tracked files; that list is the session's scope contract.
- **Installing a language profile.** Merge the fragments, set the posture, prove it
  against the profile's own fixture pair.
- **Deciding what a profile catches.** Each profile README records its measured red/green
  result and its known gaps.

## When NOT to use

- **Turn-time enforcement.** Hooks own that lane: `slop-tripwire` adds one advisory
  context line per hit on an edited file, and `post-edit-verify` / `stop-verify` run the
  native linters once a profile config is installed. Do not re-audit per turn.
- **Pre-PR gating.** That is process-gate row 9
  ([`check-slop.sh`](../process-gate/scripts/check-slop.sh)) — diff-scoped and driven by
  `gate_profiles.anti_slop.posture`. The audit is repo-scoped and never gates.
- **Prose slop.** The `writing` skill owns that vocabulary.

## Layout

`scripts/audit-slop.sh` is the audit; `profiles/<lang>/` carries one language's fragments,
install steps and `fixtures/{red,green}.*` pair. Profiles and fixtures are sibling assets
read on demand — only this file is injected, which is why the doctrine is not inlined.

## Audit

```sh
bash scripts/audit-slop.sh                 # whole repo
bash scripts/audit-slop.sh src/api         # one subtree or file
bash scripts/audit-slop.sh --json          # machine output
```

- Tracked files only (`git ls-files`), carve-outs honored, runs from anywhere in the work
  tree. Exit status is always 0 — findings are output, not a verdict.
- Ladder per language: the native linter when the profile config is installed **and** its
  binary resolves, otherwise the pattern set. "Installed" means the profile's own marker is
  in the config (the vendored plugin name, `ANN401`, `ignore-without-code`) — an unrelated
  oxlint or ruff config is not this profile, and the native lane runs the profile's rules
  only, never the project's whole config. Degradation prints as a note, never as a clean
  result; a native engine that exits ≥ 2 discards that language's native findings rather
  than letting an unrun tool read as clean.
- Java reports from the pattern layer only, but its rows are live and counted; it has
  no native lane because every Java engine is a build-time plugin. Go and Rust also
  report from the pattern layer only, and their profiles ship dormant.

The output is a work list, not a score — deliberately no slop score anywhere.

## Installing a profile

| Language | Fragments | Install steps | Status |
|---|---|---|---|
| TypeScript | `oxlint.config.ts` + vendored `anti-slop/` plugin | `profiles/typescript/PROVENANCE.md` § Install | live, vendored fork |
| Python | `ruff-fragment.toml`, `mypy-fragment.ini` | `profiles/python/README.md` § Install | live |
| Go | `golangci-fragment.yml` | `profiles/go/README.md` | dormant |
| Rust | `cargo-lints-fragment.toml` | `profiles/rust/README.md` | dormant |
| Java | rows in `hooks/lib/slop-patterns.sh` | `profiles/java/README.md` | live, pattern layer only |

Every install follows the same shape:

1. **Merge, never replace** — a fragment dropped in as the whole config shadows the
   project's own settings. Keep every rule and ignore already there.
2. **Set the posture** in `.trellis.json` — `gate_profiles.anti_slop.posture: "advisory"`
   first, `"enforced"` only after a clean week.
3. **Self-test against the merged config**, not the fragment.
4. **Then audit** and hand the list to the cleanup session.

No hook wiring: `post-edit-verify` and `stop-verify` discover the config. Findings in
owned source are cleanup input — weakening a severity, adding an unexplained suppression,
or laundering a type to clear one defeats the profile.
