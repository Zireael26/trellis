// gptx-lanes.js — the routing predicate, alone and importable.
//
// Split out of gptx-router.js for one reason: the router cannot be require()d
// while it is running. It reads the Keychain and calls listen(PORT) at module
// scope, so importing it to test the predicate either steals the port
// (EADDRINUSE) or fails on credentials. This file has no side effects, so
// gptx-doctor can assert the routing table offline, on every certify.
//
// That matters because probes 3-5 all send `gpt-5.6-sol`. They stay green on a
// router whose predicate has been broken by an edit — the predicate is the one
// piece of logic in the system with no runtime coverage.
//
// Public and side-effect free.

'use strict';

// Anthropic wins first, always. Without this, `claude-haiku-4-5-20251001-sol` matches the
// suffix branch below and a Claude request is handed to Codex with a Codex key —
// the worst failure this router has, because it looks like a model error, not a
// routing one. Every id CLIProxyAPI actually serves is `gpt-`/`codex-` prefixed
// (verified against /v1/models 2026-07-25), so the guard costs nothing real.
const ANTHROPIC_RE = /^claude[-.]/i;

// Suffix branch is kept for hand-typed aliases only. Real ids never need it.
const GPT_RE = /^(gpt-|codex-|o\d)|-(sol|terra|luna)$/i;

/**
 * @param {unknown} model the request body's `model` field, as received
 * @returns {'anthropic'|'codex'}
 */
const laneFor = (model) => {
  // Normalize before matching, or the guard is trivially bypassed: " claude-haiku-4-5-20251001-sol"
  // fails `^claude` on the leading space, falls through to the suffix branch, and lands on
  // Codex. NFKC folds homoglyph/compatibility forms into the same trap. Cheap, and it
  // removes the only way the Anthropic guard can be stepped around.
  const m = (typeof model === 'string' ? model : '').normalize('NFKC').trim();
  if (ANTHROPIC_RE.test(m)) return 'anthropic';
  if (GPT_RE.test(m)) return 'codex';
  return 'anthropic'; // default lane — unknown/absent models are Claude's
};

module.exports = { laneFor, ANTHROPIC_RE, GPT_RE };
