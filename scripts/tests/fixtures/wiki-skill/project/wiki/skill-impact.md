# Skill impact ledger

Durable record of every evaluated create or patch proposal.

| date | skill | diff ref | eval score | best-before | verdict | PR | run receipt |
|---|---|---|---:|---|---|---|---|
| 2026-08-20 | one-skill | diff=0000000000000000000000000000000000000000..1111111111111111111111111111111111111111; patterns=valid; new-evidence=none | 0.75 | 0.70 | rejected | https://github.com/example/project/pull/123 | [run receipt](skill-impact/one-skill/2026-08-20-111111111111.json) |

This fixture row records a final human rejection. It remains durable and its
pattern set must not be proposed again without genuinely new evidence.
