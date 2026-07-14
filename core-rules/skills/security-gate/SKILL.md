---
name: security-gate
description: Security scanner for any registered Trellis project. All three modes ship: project-wide baseline, per-PR diff, and chained-exploit red-team reasoning. Composes OSS engines (Semgrep, OSV-scanner, Gitleaks) under a provider-neutral LLM triage layer.
---

# security-gate

Harness-agnostic security scanner for the Trellis engineering process. The engine is OSS tooling; the LLM is a swappable triage and remediation layer. Authoritative scope, threat model, and phasing live in `security-gate-plan.md` at the Trellis root.

When in doubt, that document and `engineering-process.md` win. If a rule here contradicts either, fix the rule here.

## Status

| Mode | Phase | Status |
|---|---|---|
| 1 — Baseline (project-wide, primary scan) | 1 | shipped |
| 2 — Diff (between baselines, per push) | 2 | shipped |
| 3 — Red-team (chained-exploit reasoning) | 6 | shipped |

## When to use

- **At onboarding.** First run after wiring a project into `registry.md` — establishes the ground-truth findings JSON that every later diff scan reads.
- **On a slow cadence.** Operators should run a private quarterly baseline. Drift between baselines is normal; the roll-up records new vs. recurring vs. resolved.
- **Pre-release.** Before cutting a major version, re-run baseline to catch latent issues that diff scans skipped because no PR touched them.
- **Post-incident.** After a CVE disclosure or near-miss, re-run baseline so the next diff has a clean reference.

## When NOT to use

- Per-PR review. That is Mode 2 (diff), Phase 2.
- Live DAST against production. The skill is local/dev only.
- Auth, crypto, payment-handling rewrites. Skill flags; humans fix.
- Architectural decisions. Use an ADR.

## Toolchain

OSS-only engines. Pin versions for reproducibility — re-running an unchanged tree must produce the same findings JSON.

| Tool | Role | Pinned (Phase 1) | Install |
|---|---|---|---|
| [Semgrep](https://semgrep.dev) | SAST (rule-based, multi-language) | `1.157.0` (≥ 1.140) | `brew install semgrep` |
| [OSV-scanner](https://github.com/google/osv-scanner) | SCA against OSV.dev | `2.3.8` (≥ 2.0) | `brew install osv-scanner` |
| [Gitleaks](https://github.com/gitleaks/gitleaks) | Secrets (current-tree gate + separate history) | `8.30.1` (≥ 8.21) | `brew install gitleaks` |
| [Garak](https://github.com/NVIDIA/garak) | LLM-app probes (prompt injection / jailbreak / leakage) — `web-rag-llm` only | optional | `pipx install garak` |
| [simonw/llm](https://github.com/simonw/llm) | Provider-neutral LLM driver | `0.31` (≥ 0.31) | `pipx install llm` |

If a host tool is missing the corresponding scanner stage emits `warn` and is skipped — the run still produces a partial baseline so the rest of the pipeline keeps moving.

## Modes

### Mode 1 — Baseline

```bash
bash core-rules/skills/security-gate/scripts/run-baseline.sh [<project-dir>] [--profile=<name>] [--no-llm]
```

- `<project-dir>` — defaults to the harness project dir (`CLAUDE_PROJECT_DIR` / `CODEX_PROJECT_DIR`) or `git rev-parse --show-toplevel`.
- `--profile=<name>` — overrides `SECURITY_GATE_STACK_PROFILE`. Phase 1 supports `web-next`. Other profiles ship in Phases 4–5.
- `--no-llm` — skips the triage and adversarial pass; emits raw findings only.

Outputs:

- `<project>/audits/<YYYY-MM-DD>-baseline-<project>.md` — narrative.
- `<project>/audits/<YYYY-MM-DD>-baseline-<project>.json` — schema v2 machine-readable output. `findings` is the current-tree gating set; `historical_findings` is separate history visibility with fingerprint-persisted dispositions. Diff mode dedupes against `findings` only.

Wall-clock: 10–60 min depending on project size and LLM provider.

### Mode 2 — Diff

```bash
bash core-rules/skills/security-gate/scripts/run-diff.sh [<project-dir>] [--range=<gitspec>] [--baseline=<path>] [--no-llm]
```

- Scopes scanners to files changed in the range. Defaults to `origin/main..HEAD`.
- Reads the latest `<project>/audits/*-baseline-<project>.json` to skip already-known current-tree findings. New finding = `(tool, rule, file, line)` not present in `findings` (excluding baseline `dropped` entries); v2 `historical_findings` never suppress a new diff finding.
- OSV runs only when a manifest changed in the range (deps changed). Gitleaks scopes via `--log-opts`.
- Emits a verdict block in the same shape as `process-gate`. Exit codes:
  - `0` MERGEABLE — no new Critical/High findings.
  - `2` NEEDS CHANGES — only new Medium/Low findings.
  - `1` BLOCKED — at least one new Critical/High finding.

Wired into `core-rules/husky/pre-push`. Override on a single push: `SECURITY_GATE_SKIP=1 git push`. Skipped (warn) when no baseline JSON exists.

Wall-clock: under 2 min on typical pushes.

### Mode 3 — Red-team

```bash
bash core-rules/skills/security-gate/scripts/run-redteam.sh <project-dir> <target-class> [--confirm] [--no-llm]
```

`target-class` ∈ `data-exfil | priv-esc | account-takeover | tenant-break | model-jailbreak`.

Static chained-exploit reasoning. Loads retained entries from both `findings` and `historical_findings` in the latest baseline JSON, asks the LLM to compose its primitives into kill chains targeting the named class, and skips dropped dispositions. Writes a narrative — chains, reproduction PoCs, cheapest-break patches — to `<project>/audits/<YYYY-MM-DD>-redteam-<project>-<target-class>.md`.

**Per-run sign-off required.** Output is sensitive (concrete attacker steps). Interactive runs prompt for `yes`; non-interactive runs must pass `--confirm`. Full discipline + runbook: [`references/redteam-runbook.md`](references/redteam-runbook.md).

## Audit JSON shape

```json
{
  "schema": "security-gate.baseline.v2",
  "project": "tgsc",
  "profile": "web-next",
  "generated_at": "2026-05-08T12:34:56Z",
  "tools": {"semgrep": "1.142.0", "osv-scanner": "1.9.2", "gitleaks": "8.21.0"},
  "llm": {"provider": "anthropic", "model": "claude-opus-4-7"},
  "findings": [
    {
      "id": "semgrep-001",
      "tool": "semgrep",
      "rule": "javascript.lang.security.audit.xss.direct-response-write",
      "severity": "high",
      "file": "app/api/foo/route.ts",
      "line": 42,
      "message": "User input rendered without escaping.",
      "triage": "kept",
      "triage_reason": "Reaches response body; attacker-controlled input via query param.",
      "exploit_steps": "GET /api/foo?msg=<svg/onload=alert(1)>",
      "suggested_fix": "Use Response.json() or escape via DOMPurify before string concat."
    }
  ],
  "historical_findings": [
    {
      "id": "gitleaks-history-a1b2c3d4e5f6",
      "tool": "gitleaks",
      "rule": "generic-api-key",
      "severity": "high",
      "file": "tests/fixtures/client.ts",
      "line": 17,
      "message": "Detected a Generic API Key. (commit=abc12345)",
      "fingerprint": "abc123...:tests/fixtures/client.ts:generic-api-key:17",
      "triage": "dropped",
      "triage_reason": "Synthetic fixture credential."
    }
  ],
  "summary": {
    "total_raw": 1,
    "kept": 1,
    "dropped": 0,
    "no_llm_pass": 0,
    "by_severity": {"critical": 0, "high": 1, "medium": 0, "low": 0},
    "historical": {"total_raw": 1, "kept": 0, "dropped": 1, "no_llm_pass": 0, "by_severity": {"critical": 0, "high": 0, "medium": 0, "low": 0}}
  }
}
```

`triage` ∈ `kept | dropped | no-llm-pass`. `dropped` findings are written into the JSON for traceability — they were considered and discarded with reason.

Gitleaks emits two JSONL buckets before aggregation: `bucket: findings` from `detect --no-git`, and `bucket: historical_findings` for history results absent from the current-tree scan. Historical entries retain Gitleaks severity (High). Once an LLM produces `kept` or `dropped`, that disposition is copied into later baselines by the exact Gitleaks `fingerprint`; `no-llm-pass` is not a disposition and is eligible for triage on a later run.

## Adversarial-verification pass

Per `security-gate-plan.md` §2, raw SAST output is ~98% noise. The triage prompt runs a two-pass discipline against every Semgrep/OSV finding:

1. **Pass A — keep/drop.** LLM rules out dead-code, test-only, framework-managed (e.g. Next.js auto-escape), confirmed FP patterns.
2. **Pass B — adversarial.** For each surviving `keep`, the LLM is asked to *produce a one-line attacker step that triggers the vulnerability*. If it cannot, the finding is downgraded to `dropped` with reason `no exploit path constructed`.

Gitleaks findings skip Pass A (a leaked secret is a leaked secret) but get Pass B — the LLM is asked whether the leak is a real credential or a placeholder/test fixture.

Every retained finding therefore carries an explicit reproduction step. Findings without `exploit_steps` were either dropped or are pre-LLM `no-llm-pass` records.

## Project-local configuration

The skill loads `security-gate-local/local.config.sh` beside the harness symlink. Claude Code uses `<project>/.claude/skills/security-gate-local/local.config.sh`; Codex uses `<project>/.agents/skills/security-gate-local/local.config.sh`. If both exist, the active harness wins — same convention as `process-gate-local`.

Minimal config:

```bash
SECURITY_GATE_STACK_PROFILE="web-next"     # web-next | web-static | web-rag-llm | monorepo-saas | unity-game
LLM_PROVIDER="anthropic"                    # anthropic | openai | gemini | ollama | none
LLM_MODEL="claude-opus-4-7"                 # provider-specific model id
SECURITY_GATE_AUDIT_DIR="audits"            # default; relative to project root
SECURITY_GATE_LLM_TIMEOUT_S=120             # per-call ceiling

# web-rag-llm only — declare which LLM endpoint Garak should probe.
# SECURITY_GATE_GARAK_TARGET="openai:gpt-4o-mini"
# SECURITY_GATE_GARAK_PROBES="promptinject.HijackHateHumans,latentinjection,leakreplay.LiteratureCloze"
# SECURITY_GATE_GARAK_TIMEOUT=600
```

Missing config → skill defaults to `web-next` with a `warn` line and runs `--no-llm` if `llm` is not on PATH.

## Provider neutrality

All LLM calls go through `scripts/lib/llm-call.sh`, which honors `LLM_PROVIDER` and `LLM_MODEL`. The default backend is the OSS `llm` CLI ([simonw/llm](https://github.com/simonw/llm)) which supports Anthropic, OpenAI, Gemini, Ollama, llama.cpp, and others via plugins. A project may swap to direct provider APIs by replacing the wrapper — interface contract is `llm_call <prompt-path> <input-path> <out-path>`.

Prompts live under `prompts/` as plain markdown. No model-specific syntax. Reproducible from CI, headless shell, or interactive session.

## Multi-harness support

Identical SKILL.md, prompts/, and scripts/ are surfaced to:

- **Claude Code** via `<project>/.claude/skills/security-gate/` symlink → canonical.
- **Codex** via `<project>/.agents/skills/security-gate/` symlink → canonical.

Project-local configuration and overrides live beside those symlinks in `security-gate-local/`. Onboarding (extended in Phase 2) will seed both when `harnesses` in `trellis.config.json` includes `"codex"`.

## Scope boundaries

- The skill **does not** modify project source files. It produces audits; humans (or follow-up sessions) write fixes on `claude/security-fix-<project>-<finding-id>` branches.
- The skill **does not** call production services or read secrets at runtime — only static analysis and git-history scans.
- The skill **does** read every file under the project tree, including untracked files when run locally.

## Updating this skill

The skill and `security-gate-plan.md` evolve together. Phasing is locked in §7 of the plan; deviations require updating the plan first. Every change to canonical (`$TRELLIS_ROOT/core-rules/skills/security-gate/`) is a PR against the Trellis canonical repo.
