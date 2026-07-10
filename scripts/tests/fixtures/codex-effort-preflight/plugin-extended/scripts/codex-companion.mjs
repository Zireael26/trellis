// Fixture: a HYPOTHETICAL upgraded companion whose validator accepts the
// exception tiers. Proves the probe reads the installed surface's source
// (pattern-driven), never a hardcoded tier list (spec 011 §4).
const VALID_REASONING_EFFORTS = new Set(["medium", "high", "xhigh", "max", "ultra"]);

export function normalizeReasoningEffort(effort) {
  const normalized = String(effort).trim().toLowerCase();
  if (!VALID_REASONING_EFFORTS.has(normalized)) {
    throw new Error(`Unsupported reasoning effort "${effort}".`);
  }
  return normalized;
}
