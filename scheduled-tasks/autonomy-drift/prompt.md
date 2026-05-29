# Autonomy drift (weekly)

You are checking whether each registered project's actual autonomy usage matches its declared configuration, and whether the decision-log discipline is being honored at L4/L5.

This audit is read-only. Remediation goes through editing `trellis.config.json` / project-local config, or operator-level review.

## Canonical paths (authoritative)

- Trellis control plane: `__TRELLIS_PATH__/`
- Personal projects root: `__PROJECTS_ROOT__/`

If `__TRELLIS_PATH__/` is not mounted, emit a single **info** finding — `Trellis mount not available in audit environment; audit skipped` — and stop.

## Inputs

1. Fleet config: `__TRELLIS_PATH__/trellis.config.json` — read `.autonomy_default` (default 3 if absent).
2. Registry: `__TRELLIS_PATH__/registry.md`.
3. Blacklist: `__TRELLIS_PATH__/blacklist.md`.
4. Per-project: `<project>/.trellis.config.json` `.autonomy` and `.presets`. `<project>/.claude/session-autonomy`. `<project>/decisions-log.md`.
5. Preset frontmatter ceilings: `__TRELLIS_PATH__/core-rules/presets/*.md`.

## Checks per project

### 1. Default vs session-override divergence

If `<project>/.claude/session-autonomy` exists and its level differs from the project's resolved default by ≥ 2 levels for three consecutive weekly runs, flag `chronic-override` (**warning**) — the per-project default is probably mis-set.

(Three-week history check requires reading the last 3 weekly audit reports under `audits/`; if fewer than 3 prior reports exist, just record the divergence without flagging.)

### 2. Silent L4/L5

If the resolved active level (config + session override + ceiling clamp) is ≥ 4, AND `<project>/decisions-log.md` has zero entries dated within the last 7 days, AND the project has commits in the last 7 days, flag `silent-high-autonomy` (**critical**) — the agent should be logging decisions but isn't.

### 3. Ceiling friction

If the project's session-autonomy file value differs from what's recorded (e.g., user tried `/autonomy 5` but ceiling clamped to 2), and this happens repeatedly, flag `ceiling-friction` (**warning**) — operator may need to remove the preset or revisit the ceiling.

(Detection: compare session-autonomy file content to the project's effective ceiling; mismatch indicates a recent clamp event. Tracking repetition requires history; if no history, just record the single event.)

### 4. Schema sanity

For each project's `.trellis.config.json`:

- `.autonomy` present but outside [1,5] → `invalid-autonomy` (**critical**).
- `.autonomy_default` at fleet level outside [1,5] → `invalid-fleet-default` (**critical**).
- Preset frontmatter `autonomy_ceiling` or `autonomy_default` outside [1,5] → `invalid-preset-frontmatter` (**critical**).

### 5. Decisions-log hygiene

If `<project>/decisions-log.md` exists:

- File present but contains no entries matching the expected format (`- YYYY-MM-DDT..Z [L\d] [...] ...`) → `malformed-decisions-log` (**warning**).
- File grown beyond 100 entries → `decisions-log-overflow` (info, recommend archiving).

## Output

Write to `__TRELLIS_PATH__/audits/YYYY-MM-DD-autonomy-drift.md`:

```
# Autonomy drift — <date>

## Summary
- Fleet default: L<n>
- Projects checked: <N>
- Standard (L3): <count>
- High-autonomy (L4/L5): <count>
- Low-autonomy (L1/L2 forced by preset): <count>
- Chronic override (warning): <count>
- Silent L4/L5 (critical): <count>
- Ceiling friction (warning): <count>
- Schema issues (critical): <count>

## Critical findings

### Silent high-autonomy
| Project | Level | Last commit | Last decision |

### Schema issues
| Project | File | Field | Value | Expected |

## Warnings

### Chronic override
| Project | Configured | Session | Weeks divergent |

### Ceiling friction
| Project | Requested | Clamped to | Limiting preset |

### Malformed decisions log
| Project | Issue |

## Informational

### Decisions-log overflow (≥100 entries)
| Project | Entry count | Recommendation |

### High-autonomy projects (informational)
| Project | Configured | Session-override | Resolved | Decisions logged (7d) |

## Recommended actions

1. For silent L4/L5: investigate — the agent should be writing decisions but isn't. Possible causes: hook not synced, agent not reading autonomy.md, or session-autonomy file unwritable.
2. For chronic override: raise the project's default to match operator's habitual override.
3. For schema issues: edit config to a valid integer 1–5.
4. For decisions-log overflow: rotate to `decisions-log.archive.md` and truncate the live file to last 50 entries.
```

## Severity rollup

- **critical**: silent L4/L5, invalid-autonomy, invalid-fleet-default, invalid-preset-frontmatter.
- **warning**: chronic-override, ceiling-friction, malformed-decisions-log.
- **info**: decisions-log-overflow, project at L3 (no finding).

## Boundaries

- **Read-only.** Never edit any project's config, session-autonomy file, or decisions-log.
- **No remediation script.** Findings go to the operator; fixes are conscious edits.

## Sensible failure modes

- Project directory missing → skip the row (registry-blacklist-health will already flag).
- `core-rules/autonomy.md` missing → stop with a clear error. Audit assumes the canonical doc exists.
- `decisions-log.md` missing on a high-autonomy project → fold into `silent-high-autonomy` check.
