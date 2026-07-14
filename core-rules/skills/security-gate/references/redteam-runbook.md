# Red-team runbook (Mode 3)

Mode 3 of the security-gate skill. Static chained-exploit reasoning over the project's latest baseline. No live DAST. No production traffic. Local/dev only.

## When to run

- **Pre-release.** Before cutting a major version, after a feature lands that touches authentication, multi-tenancy, RAG retrieval, or any payment/IAP flow.
- **Post-incident.** After a near-miss or a CVE disclosure that affects the project's surface — re-baseline first (Mode 1), then run red-team to find chains the disclosed primitive enables.
- **Post-architectural-change.** Major refactors of the authz layer, the LLM tool-call router, the multi-tenant boundary, or the IAP receipt flow.

## When NOT to run

- Routine commits / per-PR review. That is Mode 2 (diff). Mode 3 is heavy and the output is sensitive.
- A project that has not yet been baselined. The chain composer reads from `audits/<date>-baseline-<project>.json`. Run Mode 1 first.
- Without an LLM provider configured. The OSS engine alone cannot compose chains; without `LLM_PROVIDER` set the script falls back to listing baseline findings — useful, but not the same as a chain narrative.

## Per-run sign-off

The run prints a sign-off banner naming the project, target class, and output path, then waits for the operator to type `yes` (interactive) or pass `--confirm` (non-interactive). The sign-off is required because:

- The output narrative contains concrete attacker steps. It is sensitive and must be treated like CVE pre-disclosure material.
- Re-running on a project not currently being remediated wastes LLM cost and increases the surface of leaked attack documents.
- The skill is designed to leave a paper trail: `<project>/audits/<date>-redteam-<project>-<class>.md` is the artifact of record. The sign-off is the human acknowledgement of intent.

The non-interactive `--confirm` path exists for scheduled / CI integrations. Today, no such integration ships — Mode 3 is on-demand only. If a future scheduled audit composes red-team narratives, it must use `--confirm` and write the output to a path under `audits/` that is **redacted** in template sync (`trellis.config.json` already lists `audits/` under `redact_paths`).

## Output handling

- Path: `<project>/audits/<YYYY-MM-DD>-redteam-<project>-<target-class>.md`.
- Stays under `audits/` — git-ignored / template-redacted in every registered project. Never commit a redteam narrative to a public branch.
- Share with humans only on a need-to-know basis. The narrative explicitly lists working chains; sharing it casually creates a window where a malicious insider has a roadmap.
- After remediation lands, the narrative is still useful as a regression artifact ("did the fix actually break the chain?"). Re-run after each fix to confirm; archive the prior file if you want a historical record of what existed.

## Target classes (recap from `prompts/redteam.md`)

| Class | Question | Typical primitives |
|---|---|---|
| `data-exfil` | Can the attacker read data they shouldn't? | unauthorized GET endpoints, SSRF to internal services, missing tenant scoping in DB queries |
| `priv-esc` | Can the attacker move from low-priv to admin? | role-check missing, admin-only endpoints reachable via parameter pollution, JWT signature confusion |
| `account-takeover` | Can the attacker control a user account they don't own? | session-fixation, weak password reset, OAuth callback misuse, JWT none-alg |
| `tenant-break` | Can one tenant see another tenant's data? | missing `WHERE tenant_id = ?`, shared cache keys, asset URLs guessable across tenants |
| `model-jailbreak` | Can the LLM be coerced past its guardrails? | system-prompt concat with user input, retrieval poisoning, MCP tool-call privilege |

## Methodology

The script does not perform composition itself. It:

1. Reads the latest baseline JSON for the project.
2. Filters out `triage: dropped` findings (those were already ruled false positives by the baseline triage).
3. Pipes the kept findings as JSONL into the model with `prompts/redteam.md` as the system prompt.
4. Captures the model's markdown narrative.
5. Wraps it in a sign-off header and writes to the canonical audit path.

The model is therefore the load-bearing component. **The narrative quality is bounded by the model's reasoning quality** — a stronger model finds more real chains and rejects more speculative ones. Use the strongest available model for Mode 3 even if Mode 1 baselines run on a cheaper one.

## Validation discipline

After receiving a chain narrative:

1. **Reproduce the PoC locally.** Each chain claims a concrete reproduction. If it doesn't actually run, the model hallucinated a primitive — file a counter-example as a triage update.
2. **Verify the cheapest break.** Apply the suggested patch, re-run Mode 1 baseline, re-run Mode 3 with the same target class. The chain should disappear.
3. **Update `triage` in the baseline JSON.** If a finding the chain depends on is actually a false positive (model misread), set `triage: dropped` with reason; the chain narrative for the next run will recompose without it.

## Failure modes (logged here for posterity)

These are observed Mode 3 anti-patterns; this section grows over time.

- **Speculative chains.** Model invents a "supposed" primitive that the baseline didn't actually detect. Always cross-reference each Chain N's `Primitives:` list against the baseline JSON's `findings[].id`. Reject any that don't match.
- **Severity inflation.** Model claims a Low + Low + Low chain reaches Critical impact. Sometimes correct (chain composition raises severity), often not. The "Defensive priorities" section is the more reliable signal — the fix-cost ranking is harder for the model to fabricate than the severity.
- **Auth/crypto over-confidence.** The skill explicitly forbids auto-applying fixes in those areas. Treat any narrative finding in this band as a starting point for a human design review, not a diff to merge.

## Status (Phase 6)

Phase 6 ships the runbook, the prompt, and the runner. No live integration tests run yet — Mode 3 requires an LLM provider, and the validation host has none configured. The first real run lands once the operator wires `LLM_PROVIDER` + the corresponding `llm` plugin and exercises the script against a project with a representative kept-findings baseline containing both SAST and dependency findings.
