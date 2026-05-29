# Reference — Secrets in diff

Authoritative source: `engineering-process.md` §13.1 (Secrets).

## Hard rules

- Never commit `.env*` files (except `.env.example` with placeholder values, no real secrets).
- Never commit `secrets/**`, `*.pem`, `*.key`, `*.keystore`, `*.p12`, `*.pfx`.
- Never commit cloud credentials (`~/.aws/credentials`, GCP service account JSON with private keys, Cloudflare API tokens).
- Never commit OAuth client secrets, JWT signing keys, or database connection strings with embedded passwords.

Any of the above in the diff: **fail**.

## Patterns the validator scans

The `check-secrets.sh` script greps the diff for these patterns. False positives are common; review carefully before dismissing.

| Pattern | Match |
|---|---|
| AWS access key | `AKIA[0-9A-Z]{16}` |
| AWS secret | `aws_secret_access_key\s*=\s*['"]?[A-Za-z0-9/+=]{40}` |
| Generic API key in code | `(api[_-]?key\|secret[_-]?key\|access[_-]?token)\s*[:=]\s*['"][A-Za-z0-9_\-]{20,}['"]` |
| Private key block | `-----BEGIN [A-Z ]*PRIVATE KEY-----` |
| GitHub token | `ghp_[A-Za-z0-9]{36}`, `github_pat_[A-Za-z0-9_]{82}` |
| Slack token | `xox[baprs]-[A-Za-z0-9-]{10,}` |
| Stripe live key | `sk_live_[A-Za-z0-9]{24,}` |
| Anthropic key | `sk-ant-[A-Za-z0-9_\-]{40,}` |
| OpenAI key | `sk-[A-Za-z0-9]{48}` |
| Connection string with password | `(postgres\|postgresql\|mysql\|mongodb\|redis)://[^:@/]+:[^@/]+@` |

A match: **fail** with the file:line and the pattern name. The contributor is expected to remove the file from the diff and rotate the secret immediately.

## False-positive handling

If a match is a documented test fixture, example placeholder, or pattern that genuinely matches non-secret content, add it to `<project>/.claude/skills/process-gate/secrets-allowlist.txt`:

```
# One pattern per line. Lines starting with # are comments.
# Format: <relative-path>:<exact-match-regex>
docs/examples/api.md:sk_live_FAKE_PLACEHOLDER_DOCS_ONLY
fixtures/test-keys.txt:.*
```

Allowlisting is auditable in git history. Reviewers should challenge new entries.

## Environment variable names

Names alone (`DATABASE_URL=`, `STRIPE_SECRET_KEY=`) without values are fine. The validator only flags actual values that look like secrets.

`.env.example` files SHOULD list keys with placeholder values:

```bash
DATABASE_URL=postgres://user:password@localhost:5432/db
STRIPE_SECRET_KEY=sk_test_replace_with_your_test_key
```

Real keys in `.env.example`: **fail**.

## Lockfiles, build artifacts, generated configs

Lockfiles can contain registry tokens. The validator skips known lockfiles by default (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `go.sum`). If your project commits a lockfile that the validator doesn't recognize, add a path-glob exclusion in `local.config.sh`:

```bash
PROCESS_GATE_SECRETS_SKIP_PATHS=(
  "vendor/lockfile.lock"
  "build/output/manifest.json"
)
```

## Remediation

If a secret was committed:

1. Stop. Don't push if you haven't already.
2. Rotate the secret in the source-of-truth system (cloud console, GitHub settings, etc.).
3. Remove from the diff and recommit. If already pushed, the secret is leaked — rotation is the only mitigation; rewriting history won't help (caches, mirrors, scrapers).
4. Document in `gotchas.md` with `**Detection:**` describing how it was caught.

## Anti-patterns that broke earlier runs (do NOT repeat)

- **`producer | consumer-with-early-exit` under `set -e + pipefail`** is a SIGPIPE hazard. The consumer's `exit` closes its stdin while the producer is still emitting; the producer receives SIGPIPE (exit 141); `pipefail` propagates the non-zero; `set -e` aborts the script. The pre-v0.5.0 `check-secrets.sh` ran `loc=$(git diff … | awk '… exit')` per pattern hit and silently degraded to zero findings on diffs above ~5KB (full RCA in the v0.5.0 meta-audit addendum 2026-05-20; fix shipped in v0.5.0 via lookup-table refactor). When the consumer must exit early, land the pattern through a temp-file intermediary (compute the producer's output once into `mktemp`, then `awk` over the file), or guard the consumer with `|| true` so the non-zero from SIGPIPE doesn't trip the script. Never as a raw pipe under `set -e + pipefail` with an early `exit` on the consumer side.
