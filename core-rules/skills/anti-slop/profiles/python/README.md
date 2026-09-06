# Python profile

Evidence-doctrine config for Python projects: escape-hatch types out of contracts,
boundary data parsed rather than laundered, suppressions that name what they suppress.
Doctrine and the cross-language pattern tables live in `core-rules/references/anti-slop.md`.

Unlike the TypeScript profile this is **not vendored** — upstream anti-slop is
TypeScript-only, so there is no provenance to track and nothing to re-sync. Both files
are fragments authored here against ruff's and mypy's own rule sets.

| File | Owns | Lane |
|---|---|---|
| `ruff-fragment.toml` | Per-line pattern rules | `post-edit-verify` (per file), `stop-verify` (repo) |
| `mypy-fragment.ini` | Type-flow rules | `stop-verify` (repo) |
| `fixtures/{red,green}.py` | The profile's self-test | § Self-test |

## Ownership

Plan 037 D3: **ruff owns what is decidable from the line; mypy owns what needs type
flow. No rule is enabled in both fragments.** Without that split a project reports the
same defect twice and agents learn to skim findings.

| Pattern | Owner | Rule | Why not the other tool |
|---|---|---|---|
| `Any` in an annotation | ruff | `ANN401` | mypy's `disallow_any_explicit` reports the identical lines |
| Blanket `# noqa` | ruff | `PGH004` | mypy has no view of lint suppressions |
| Bare `# type: ignore` | mypy | `ignore-without-code` | ruff's `PGH003` collides — measured below |
| `Any` returned from a typed function | mypy | `warn_return_any` | needs flow; the line looks fine |
| Missing annotations | mypy | `disallow_untyped_defs` | ruff's `ANN001`/`ANN2xx` report the same defs |

Two collisions are avoided by deliberate omission, both measured against
`fixtures/red.py`:

- `PGH003` would report `red.py:39` — the exact line mypy reports as
  `ignore-without-code`. Hence `ANN401`-centred, not the `PGH` family.
- `disallow_any_explicit` would report `red.py:15` twice — the lines `ANN401` already
  holds. Hence it stays unset, with the nested-`Any` consequence in § Known gaps.

Before adding a rule to either fragment: run it against `fixtures/red.py` alongside the
other tool and confirm the reported line sets stay disjoint.

## Install

Merge the fragments; never copy them in as-is. A `ruff-fragment.toml` dropped at a repo
root as `ruff.toml` shadows the project's own settings, which is why neither file is
named like a config.

1. **ruff** — add the two codes to the project's existing `extend-select`, and the
   generated-tree entries to its `per-file-ignores`. In `ruff.toml` the sections are
   `[lint]` and `[lint.per-file-ignores]`; in `pyproject.toml` they are
   `[tool.ruff.lint]` and `[tool.ruff.lint.per-file-ignores]`. Keep every code and
   ignore the project already has.
2. **mypy** — copy the three keys into the existing `[mypy]` section of `mypy.ini` /
   `setup.cfg`. `enable_error_code` is a list: append `ignore-without-code` to what is
   there rather than replacing it. In `pyproject.toml` the section is `[tool.mypy]`,
   values are TOML (`true`, and `enable_error_code = ["ignore-without-code"]`), and the
   per-module carve-out becomes an override block:

   ```toml
   [[tool.mypy.overrides]]
   module = ["conftest", "*.conftest", "tests.*", "*.tests.*"]
   disallow_untyped_defs = false
   ```

3. Run the self-test below against the merged config, not against the fragments, so the
   project's own rules are part of the result.
4. **Flat test layouts** need one more step — see § Test carve-outs.
5. Set `gate_profiles.anti_slop.posture` in the project's `.trellis.json`, starting at
   `"advisory"`.

Findings in owned source are a cleanup-session input. Weakening a severity, adding a
suppression, or laundering a type to clear one defeats the profile.

## Test carve-outs

`disallow_untyped_defs` reports **every** unannotated test function, so an ordinary
`def test_parses_user():` becomes a finding. That is the warning-fatigue failure the
spec designs against, so a carve-out is mandatory, not optional. mypy's two mechanisms
each cover only part of the ground — all four rows below are measured:

| Layout | Repo-wide lane (`mypy .`) | Per-file lane (explicit path) |
|---|---|---|
| `tests/` **with** `__init__.py` | shipped per-module section | shipped per-module section |
| flat `test_*.py`, no `__init__.py` | `exclude` regex (step below) | neither — inline directive needed |

Two mechanism limits cause that split:

- **Per-module sections match module names, not paths.** Without `__init__.py`,
  `tests/test_a.py` is module `test_a`, so `tests.*` never matches it. mypy also rejects
  a partial-component wildcard — `test_*` fails config parsing with "Patterns must be
  fully-qualified module names" — so flat test modules cannot be named this way at all.
- **`exclude` is ignored for explicitly-passed files.** It filters directory recursion
  only, so it covers `stop-verify`'s repo-wide run and does nothing for
  `post-edit-verify`'s per-file run.

For a flat layout, add to the project's `[mypy]` section:

```ini
exclude = (^|/)(tests?/|conftest\.py$|test_[^/]*\.py$)
```

`exclude` is left out of the shipped fragment on purpose: it is a single-value key, so
it collides on merge, and it stops a project checking files it may deliberately check.
For the per-file lane on a flat layout the remaining option is a file-level directive at
the top of the test module:

```python
# mypy: disable-error-code="no-untyped-def"
```

Both pattern rules stay enabled in test code either way. An `Any` contract or an unnamed
suppression is worth reporting in a test double too, and neither fires on ordinary test
code — `fixtures/green.py` is the guard for that.

The canonical carve-out glob list for the script lane is `core-rules/hooks/lib/slop-patterns.sh`.
The fragments repeat only the globs a linter config can express; they are not a second
source of truth.

## Known gaps

- **Nested `Any` is invisible to both fragments.** `dict[str, Any]` is measured as
  reporting nothing from `ANN401` — the rule inspects the annotation itself, not its
  parameters. Closing it means `disallow_any_explicit`, which double-reports every
  plain `Any`, so the gap is accepted rather than patched. `fixtures/red.py:27` carries
  the case, where mypy catches the *consequence* (`no-any-return`) but not the
  annotation.
- **`cast()` without a `# SAFETY:` comment and `mock.patch("dotted.module")` have no
  ruff or mypy rule.** Neither tool expresses "this needs a stated invariant" or
  "prefer a real seam". Both are pattern-layer findings, owned by
  `core-rules/hooks/lib/slop-patterns.sh` and reported by the tripwire, audit, and gate scripts.
  `fixtures/red.py` includes both so the fixture stays honest about what the profile
  does and does not catch on its own.

## Self-test

Run from this directory; both tools are read-only and install nothing.

```sh
ruff check --config ruff-fragment.toml --no-cache fixtures/red.py     # 3 findings, exit 1
ruff check --config ruff-fragment.toml --no-cache fixtures/green.py   # 0 findings, exit 0
mypy --config-file mypy-fragment.ini --no-incremental --cache-dir=/dev/null fixtures/red.py    # 3 errors, exit 1
mypy --config-file mypy-fragment.ini --no-incremental --cache-dir=/dev/null fixtures/green.py  # 0 errors, exit 0
```

Recorded 2026-08-18 with `ruff 0.15.5` and `mypy 1.20.2`:

| Fixture | ruff | mypy |
|---|---|---|
| `red.py` | 3 (`ANN401` ×2 at :15, `PGH004` at :44) | 3 (`no-untyped-def` :20, `no-any-return` :27, `ignore-without-code` :39) |
| `green.py` | 0 | 0 |

The assertion that matters is **red ≥ 1 from each tool, green = 0 from both**; exact
counts shift with tool versions.

Two controls make the red result attributable, both recorded the same day:

- **Negative control** — both tools at default settings report **0** findings on
  `red.py`. Every finding above comes from these fragments, not from a default rule set.
- **Disjointness** — the reported line sets are `{15, 44}` for ruff and `{20, 27, 39}`
  for mypy, with no line in both. This is the D3 receipt; re-run it whenever either
  fragment gains a rule.

Piping either command through `tail` reports **`tail`'s** exit code, not the linter's.
Read exit codes from an unpiped run.
