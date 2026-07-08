# ADR: Interactive executor delegation (spec 009)

**Date:** 2026-07-08
**Status:** Accepted

## Context

Trellis's dual-harness routing (rc.4) only fired inside orchestrated fan-outs; plain interactive turns ran entirely on the orchestrator even for bounded work orders. Steinberger's `codex-first` skill demonstrated the missing surface — default delegation of implementation work with crisp route heuristics — but carried claims we could not adopt neutrally: a model-quality overclaim (benchmarks show near-parity implementation, orchestrator-leg edge on review/planning) and a flat-rate economics rationale stale since both vendors moved automation to metered pools (2026-04/2026-06). Anthropic's plan-big/execute-small results (Sonnet executor + Fable advisor ≈ 92% quality at 63% cost; Fable orchestrator + Sonnet workers ≈ 96% at 46%) independently validated the topology and showed the delegation dividend is executor-agnostic. Separately, `core-rules/loop-safety.md` was found missing from the public-mirror SYNC_PATHS while 13 synced files reference it — the second occurrence of the synced-file-references-unsynced-file class.

## Decision

- Widen the capability clause: bounded work-order units may route to an available executor node from any turn, advisory-first during the pilot (`specs/009-interactive-codex-delegation/pilot-ledger.md`, flip criteria recorded there).
- Executor leg generalized: Codex (companion contract) or cheap Claude worker (native subagent), picked by unit type then quota headroom; interface table in `docs/codex-routing.md §6`.
- Route predicate: delegate work orders; keep home spec-writing-as-work, tiny edits (~20 changed lines, soft), session-tool needs, bright-lines. Review of executor output is never delegated.
- Dispatch stays full-auto without dropping the sandbox: companion pins `approvalPolicy: "never"`; `network_access = true` handles the sandbox's main friction; sandboxless `codex exec --dangerously-bypass-approvals-and-sandbox` is a Codex-leg-only escape hatch confined to seeded worktrees, never the canonical checkout. Flipping sandboxless-by-default would require its own ADR.
- Dispatch-time effort ladder replaces blanket xhigh for interactive units (xhigh hard/verify, high standard implementation, medium/low mechanical); workflow recipes keep xhigh — threading per-unit effort through recipes is a named follow-up.
- Two-failed-rounds takeover per unit id with a six-signal failure taxonomy; per-dispatch tracking receipt.
- Rider: `core-rules/loop-safety.md` added to SYNC_PATHS + a ref-integrity check in `sync-to-template.sh` fails any sync where a synced file references an unsynced `core-rules/*.md`.

## Consequences

- Token-heavy bulk can leave the orchestrator from any turn; quality-sensitive minority (plan/review/synthesis) stays home. Two metered pools load-balance structurally.
- Advisory pilot week produces ledger data before auto-routing; under-trigger signal (≥3 manual delegation requests) reopens the deferred `/delegate` command.
- Strength-table claims re-ground via spec 008's model-launch trigger (GPT-5.6 imminent at decision time); no hand edits on launch claims.
- Public forks stop seeing dangling `loop-safety.md` references; the ref-integrity guard prevents the class recurring.
