# Reference — Anti-slop

Authoritative source: `core-rules/references/anti-slop.md` (the evidence doctrine itself). This gate only enforces the doctrine's greppable subset, and only on lines the diff adds.

Opt-in per project, off everywhere until declared. The gate is the *only* place in the anti-slop tier that can block; the turn-time `slop-tripwire` hook stays advisory at every posture.

## Posture

Declared in the project's tracked `.trellis.json` — it validates against the existing schema, which accepts open per-profile objects under `gate_profiles`:

```json
{ "gate_profiles": { "anti_slop": { "posture": "advisory" } } }
```

| Posture | Row | Blocks? |
|---|---|---|
| key absent, or `"off"` | `➖ n/a` — nothing is scanned | no |
| `"advisory"` | `⚠️ warn` when findings exist | no (`NEEDS CHANGES`) |
| `"enforced"` | `❌ fail` when findings exist | yes (`BLOCKED`) |
| malformed (bad JSON, wrong type, unknown value) | `⚠️ warn` plus one line naming the breakage | no |

Malformed posture is **fail-open** — treated as `advisory` — unlike `mandatory_pipeline`, which fails closed. v1 of the tier is advisory-by-design, so a typo in the declaration must not block a branch. Revisit that choice when the first project sets `enforced`.

## Scope: the ratchet

Only lines the range **adds** are reported. A pre-existing violation in a file the diff touches is not a finding — enumerating and clearing those is the de-slop cleanup sessions' job, driven by the `anti-slop` skill's audit mode. This holds for both detection modes: when a native linter reports a whole file, its findings are filtered down to the range's added lines before the verdict.

**Moved code counts as added.** Relocating an existing `as any` into a new file produces a finding, because the line is new to that file and the gate has no rename tracking. This is accepted behavior, not a bug (plan D4): the posture is advisory until a project opts into `enforced`, and native suppression syntax with a reason covers the intended cases. No bespoke cross-language suppression marker exists.

## Detection ladder

Per language, in order:

1. **The profile is installed** → run the native linter, on the changed files only, **restricted to the profile's own rules**. TypeScript: an `oxlint.config.*` / `.oxlintrc.json` naming the vendored `anti-slop` plugin, plus an `oxlint` binary (project-local `node_modules/.bin` first); findings are filtered to that plugin's rule ids, since oxlint has no per-plugin select flag. Python: a ruff config mentioning `ANN401` → `ruff check --select ANN401,PGH004`; a mypy config enabling `ignore-without-code` → mypy filtered to `no-any-return`, `no-untyped-def`, `ignore-without-code`. ruff and mypy own disjoint halves (plan D3) and both run when installed.
2. **Otherwise** → grep the added lines against the shared pattern set in `core-rules/hooks/lib/slop-patterns.sh`, the same source the tripwire and the audit mode read.

**"Installed" means the profile's own marker is in the config, not that a config file exists.** A project with an unrelated `oxlint.config.ts` or ruff config is on the pattern lane. Keying step 1 off file existence made the gate report the project's whole lint configuration under the anti-slop label — double-reporting what the project's own lint gate owns, and pulling in the general slop tier that spec §4 puts out of scope for v1. The markers, the narrowed rule sets and the config candidate lists are single-sourced in the pattern lib (`SLOP_OXLINT_PLUGIN`, `SLOP_RUFF_RULES`, `SLOP_MYPY_CODES`, `SLOP_*_CONFIGS`) so this gate, the audit mode and doctor's presence row cannot disagree.

Go and Rust are pattern-only in v1; their profiles ship dormant. A declared profile with no runnable linter falls back to the pattern set rather than reporting a false clean — the `detection:` line in the output names the mode actually used per language.

**A native engine that fails to run is a warn, never a pass.** Exit ≥ 2 from oxlint/ruff/mypy means the tool itself failed (broken config, missing plugin); its empty output would otherwise render as a clean row — a fallback presented as measured. The row degrades that language to the pattern set and names the engine and its rc in the findings. For Python, a failure in *either* half discards both halves' native findings rather than keeping the survivor's, so the row can never claim coverage for rules nothing checked.

Carve-out globs come from the same lib, so test code (including `__tests__/`, `__mocks__/`, `e2e/`, `cypress/`, `playwright/`), generated files, fixtures, migrations, vendored trees, and lockfiles are never scanned. Grep cannot see `#[cfg(test)]` or a decorator, so the carve-outs are path-based and uniform across languages.

## Exit codes

Deliberately unlike the other validators, which use the shared `pg_exit_code` (`0` pass / `2` warn / `1` fail):

- `0` — n/a, pass, **and** advisory-with-findings. The gate never blocks below `enforced`.
- `1` — `enforced` with findings.

The exit code carries only *whether the gate blocks*; the level is the first token of the first printed line (`pass` / `warn` / `fail` / `info`, where `info` is the n/a row). `run-all.sh` reads that token, because `n/a` is a state no exit code can express. Anyone calling `check-slop.sh` directly should read the token, not the rc.

## What this gate does NOT cover

- Repo-wide cleanliness. Use the `anti-slop` skill's `audit-slop.sh` for that; this gate is diff-scoped by design.
- Turn-time feedback. The `slop-tripwire` hook covers that, advisory-only, and never blocks even at `enforced`.
- The git boundary. `pre-push` is untouched by the anti-slop tier in v1.
- General slop (bare `except:`, empty `catch {}`, commented-out code). Deferred tier.
- Prose slop. The `writing` skill owns that.

## Remediation

For a `⚠️ warn` or `❌ fail`:

1. **Fix the evidence gap.** Parse at the boundary, narrow the type, use a real seam instead of a module mock — the six principles are in `core-rules/references/anti-slop.md`.
2. **If the pattern is genuinely intended:** suppress with the linter's own syntax (`// oxlint-disable-next-line`, `# noqa: <code>`, `//nolint:<linter>`, `#[allow(...)]`) and a reason on the same or preceding line, or attach the uniform `SAFETY:` comment where the pattern honors it.
3. **If the gate is wrong** — an idiomatic line the pattern set misreads — tune the ERE in `slop-patterns.sh` against its green sample and re-run `bash slop-patterns.sh --self-test`. Don't silence the row.
4. **If a whole area is out of scope:** add a carve-out glob to the lib, not a per-project exception.
