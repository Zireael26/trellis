import { accessSync, chmodSync, constants, existsSync, lstatSync, mkdtempSync, readFileSync, realpathSync, rmdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { basename, delimiter, dirname, extname, relative, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import type {
  AgentBeforeSettleEvent,
  BoundaryResult,
  ExtensionAPI,
  ExtensionContext,
  ToolCallEvent,
  ToolResultEvent,
  UserBashEvent,
} from "@earendil-works/pi-coding-agent";

type Target = { operation: "read" | "create" | "update" | "delete" | "rename"; path: string; destination?: string };
type NormalizedAction = {
  schema_version: 1;
  harness: "pi";
  phase: "pre_action" | "post_action";
  native_event: "tool_call" | "tool_result" | "user_bash";
  cwd: string;
  session_id: string;
  session_file?: string;
  action: {
    id: string;
    tool_name: string;
    family: "shell" | "file_read" | "file_mutation" | "mcp" | "local_tool" | "unknown";
    target_coverage: "complete" | "partial" | "none";
    targets: Target[];
    input: Record<string, unknown>;
  };
  result: null | { status: "succeeded" | "failed" | "unknown"; is_error: boolean | null; output: unknown };
};
type Decision = { schema_version: 1; capability_status: "enforced" | "advisory" | "unsupported" | "disabled" | "unknown"; decision: "allow" | "deny" | "warn"; reason?: string; context?: string };
type ReadState = { known: Set<string>; warns: Map<string, number> };
type RuleEngine = "claude" | "codex";
type GuardExemption = {
  engines: RuleEngine[]; allowed_commands: string[]; command_prefixes: string[];
  refuse_if_line_matches: string[]; refuse_short_flags: string[]; boundaries: string;
  identifier: string; identifier_boundary: string; replacement: string; why?: string;
};
type GuardRule = {
  id: string; effect: "warn" | "deny"; reason?: string; message?: string;
  message_by_engine?: Partial<Record<RuleEngine, string>>;
  ignore_case?: boolean; match: string[]; unless?: string[]; exempt?: GuardExemption;
};
type GuardRules = ReturnType<typeof loadGuardRules>;

const asciiLower = (text: string) => text.replace(/[A-Z]/g, letter => letter.toLowerCase());

// Match LF-delimited lines without JS's Unicode case folding or multiline mode.
// C-locale character classes and all policy patterns stay in the shared JSON.
function rulePattern(pattern: string, ignoreCase = false): RegExp {
  return new RegExp(ignoreCase ? asciiLower(pattern) : pattern);
}

// Mirror the generator's closed key sets: a new policy field needs an explicit
// implementation, never a successful load that silently drops its semantics.
function checkKeys(value: unknown, required: string[], optional: string[] = []) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || required.some(key => !Object.hasOwn(value, key))
      || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) throw new Error("invalid Trellis guard rule keys");
}

function compileExemption(exempt: GuardExemption, ignoreCase: boolean) {
  checkKeys(exempt, ["engines", "allowed_commands", "command_prefixes", "refuse_if_line_matches", "refuse_short_flags", "boundaries", "identifier", "identifier_boundary", "replacement"], ["why"]);
  const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(item => typeof item === "string" && item.length > 0);
  if (!strings(exempt.engines) || !exempt.engines.length || exempt.engines.some(engine => !["claude", "codex"].includes(engine))
      || !strings(exempt.allowed_commands) || !exempt.allowed_commands.length || exempt.allowed_commands.some(command => !/^[A-Za-z0-9_.-]+( [A-Za-z0-9_.-]+)*$/.test(command))
      || !strings(exempt.command_prefixes) || exempt.command_prefixes.some(prefix => !/^[A-Za-z0-9_.-]+$/.test(prefix))
      || !strings(exempt.refuse_if_line_matches) || !strings(exempt.refuse_short_flags) || exempt.refuse_short_flags.some(flag => !/^-[A-Za-z0-9]$/.test(flag))
      || typeof exempt.boundaries !== "string" || !/^[!-~]+$/.test(exempt.boundaries) || new Set(exempt.boundaries).size !== exempt.boundaries.length
      || typeof exempt.identifier !== "string" || !exempt.identifier || typeof exempt.identifier_boundary !== "string" || !/^\[.*\]$/.test(exempt.identifier_boundary)
      || typeof exempt.replacement !== "string" || !/^[!-~]+$/.test(exempt.replacement) || exempt.replacement.includes("/")) throw new Error("invalid Trellis guard exemption");
  const fold = (text: string) => ignoreCase ? asciiLower(text) : text;
  return {
    ...exempt, boundaries: fold(exempt.boundaries), replacement: fold(exempt.replacement),
    allowedWords: exempt.allowed_commands.map(command => fold(command).split(" ")),
    prefixes: exempt.command_prefixes.map(fold), shortFlags: exempt.refuse_short_flags.map(fold),
    refusals: exempt.refuse_if_line_matches.map(pattern => rulePattern(pattern, ignoreCase)),
    identifierPattern: rulePattern(`(${exempt.identifier_boundary})(${exempt.identifier})`, ignoreCase),
  };
}

// pi loads an attached project's extension through its .pi/extensions symlink,
// so import.meta.url names the symlink, not the release file. Resolve it first:
// the rules live beside the real file, under the release's core-rules/hooks.
export function guardRulesDirectory(moduleUrl: string | URL = import.meta.url) {
  return resolve(dirname(realpathSync(fileURLToPath(moduleUrl))), "../../hooks/rules");
}

export function loadGuardRules(directory = guardRulesDirectory()) {
  const destructive = JSON.parse(readFileSync(resolve(directory, "destructive.json"), "utf8"));
  const reread = JSON.parse(readFileSync(resolve(directory, "reread.json"), "utf8"));
  checkKeys(destructive, ["schema_version", "guard", "description", "semantics", "rules"]);
  checkKeys(reread, ["schema_version", "guard", "description", "warn_budget", "messages", "edit_failure_markers"]);
  checkKeys(reread.warn_budget, ["default", "by_level"]);
  checkKeys(reread.warn_budget.by_level, [], ["1", "2", "3", "4", "5"]);
  checkKeys(reread.messages, ["warn", "block"]);
  checkKeys(reread.edit_failure_markers, ["ignore_case", "pattern"], ["why"]);
  if (destructive.schema_version !== 1 || destructive.guard !== "block-destructive" || !Array.isArray(destructive.rules) || destructive.rules.length === 0
      || reread.schema_version !== 1 || reread.guard !== "reread-guard"
      || !Number.isInteger(reread.warn_budget?.default) || reread.warn_budget.default < 1
      || !reread.warn_budget.by_level || Object.values(reread.warn_budget.by_level).some(value => !Number.isInteger(value) || Number(value) < 1)
      || typeof reread.messages?.warn !== "string" || typeof reread.messages?.block !== "string"
      || typeof reread.edit_failure_markers?.pattern !== "string") throw new Error("invalid Trellis guard rules");
  const seen = new Set<string>();
  const rules = (destructive.rules as GuardRule[]).map(rule => {
    checkKeys(rule, ["id", "effect", "match"], ["reason", "message", "message_by_engine", "ignore_case", "unless", "exempt"]);
    if (typeof rule.id !== "string" || !/^[a-z0-9-]+$/.test(rule.id) || seen.has(rule.id) || !["warn", "deny"].includes(rule.effect)
        || (rule.ignore_case !== undefined && typeof rule.ignore_case !== "boolean") || !Array.isArray(rule.match) || !rule.match.length
        || !rule.match.every(pattern => typeof pattern === "string" && pattern.length > 0)
        || (rule.unless !== undefined && (!Array.isArray(rule.unless) || !rule.unless.every(pattern => typeof pattern === "string" && pattern.length > 0)))
        || typeof (rule.effect === "deny" ? rule.reason : rule.message) !== "string") throw new Error("invalid destructive rule");
    seen.add(rule.id);
    if (rule.message_by_engine !== undefined) checkKeys(rule.message_by_engine, [], ["claude", "codex"]);
    return {
      ...rule,
      matches: rule.match.map(pattern => rulePattern(pattern, rule.ignore_case)),
      exceptions: (rule.unless ?? []).map(pattern => rulePattern(pattern, rule.ignore_case)),
      exemption: rule.exempt !== undefined ? compileExemption(rule.exempt, rule.ignore_case ?? false) : undefined,
    };
  });
  return { rules, reread, editFailure: rulePattern(reread.edit_failure_markers.pattern, reread.edit_failure_markers.ignore_case) };
}

// POSIX chooses the longest span at the first matching position; JS chooses
// the first alternative. End-bound probes force JS to consider longer paths,
// without slicing the input (which would change the meaning of ^ and $).
function identifierMatch(pattern: RegExp, text: string): RegExpExecArray | null {
  let best = pattern.exec(text);
  if (!best) return null;
  let low = best.index + best[0].length, high = text.length;
  while (low < high) {
    const end = Math.ceil((low + high) / 2);
    const probe = new RegExp(`(?:${pattern.source})(?=[\\s\\S]{0,${text.length - end}}$)`, "y");
    probe.lastIndex = best.index;
    const longer = probe.exec(text);
    if (longer) { best = longer; low = longer.index + longer[0].length; }
    else high = end - 1;
  }
  return best;
}

// Same simple-command walk as _gr_exempt: one refused command anywhere cancels
// the whole exemption. Command names, prefixes, refusals and rewrites are data.
function exemptLines(lines: string[], exempt: ReturnType<typeof compileExemption>): string[] {
  if (exempt.refusals.some(pattern => lines.some(line => pattern.test(line)))) return lines;
  const commands = lines.map(line => {
    const segments: { text: string; separator: string }[] = [];
    let start = 0;
    for (let index = 0; index < line.length; index++) if (exempt.boundaries.includes(line[index])) {
      segments.push({ text: line.slice(start, index), separator: line[index] }); start = index + 1;
    }
    segments.push({ text: line.slice(start), separator: "" });
    return segments;
  });
  for (const segments of commands) for (const { text } of segments) {
    const words = text.split(/[ \t\v\f\r]+/).filter(Boolean);
    if (!words.length) continue;
    const offset = exempt.prefixes.includes(words[0]) ? 1 : 0;
    if (!exempt.allowedWords.some(allowed => allowed.every((word, index) => words[offset + index] === word))) return lines;
    let previous = "";
    for (const word of words.slice(offset + 1)) {
      if (exempt.shortFlags.some(flag => word.startsWith(flag))
          || (word.startsWith("-") && word.includes("=") && exempt.identifierPattern.test(` ${word.slice(word.indexOf("=") + 1)}`))
          || (previous.startsWith("--") && previous.length > 2 && !previous.includes("=") && exempt.identifierPattern.test(` ${word}`))) return lines;
      previous = word;
    }
  }
  return commands.map(segments => segments.map(({ text, separator }) => {
    let remaining = ` ${text}`, rewritten = "";
    for (let match; (match = identifierMatch(exempt.identifierPattern, remaining));) {
      rewritten += remaining.slice(0, match.index) + match[1] + exempt.replacement;
      remaining = remaining.slice(match.index + match[0].length);
    }
    return (rewritten + remaining).slice(1) + separator;
  }).join(""));
}

export function destructiveMatches(policy: GuardRules, command: string, engine: RuleEngine = "codex") {
  const events: { id: string; effect: "warn" | "deny"; reason: string }[] = [];
  for (const rule of policy.rules) {
    let lines = command.split("\n");
    if (rule.ignore_case) lines = lines.map(asciiLower);
    if (rule.exemption?.engines.includes(engine)) lines = exemptLines(lines, rule.exemption);
    if (!rule.matches.every(pattern => lines.some(line => pattern.test(line)))
        || rule.exceptions.some(pattern => lines.some(line => pattern.test(line)))) continue;
    events.push({ id: rule.id, effect: rule.effect, reason: (rule.effect === "deny" ? rule.reason : rule.message_by_engine?.[engine] ?? rule.message)! });
    if (rule.effect === "deny") break;
  }
  return events;
}

export function rereadDecision(policy: GuardRules, path: string, state: ReadState, budget: number, override = false): Decision {
  if (override) return { schema_version: 1, capability_status: "enforced", decision: "allow", reason: `reread-guard: TRELLIS_REREAD_OVERRIDE=1 logged-escape for ${path}` };
  if (!existsSync(path) || state.known.has(path)) return { schema_version: 1, capability_status: "enforced", decision: "allow" };
  const count = state.warns.get(path) ?? 0;
  const blocked = count >= budget;
  if (!blocked) state.warns.set(path, count + 1);
  const template: string = policy.reread.messages[blocked ? "block" : "warn"];
  const values: Record<string, string> = { path, count: String(count + 1), budget: String(budget) };
  return { schema_version: 1, capability_status: "enforced", decision: blocked ? "deny" : "warn",
    reason: template.replace(/\{(path|count|budget)\}/g, (_, key) => values[key]) };
}

export function responseFailed(policy: GuardRules, response: unknown, toolName: string): boolean {
  if (response && typeof response === "object") {
    const data = response as Record<string, unknown>;
    return data.is_error === true || data.isError === true
      || [data.error, data.tool_use_error].some(value => value != null && value !== false && value !== "");
  }
  if (typeof response !== "string" || response.startsWith("Success. Updated the following files:")) return false;
  if (response.startsWith("Error") || response.startsWith("No files were modified.")) return true;
  return toolName !== "Read" && response.split("\n").some(line => policy.editFailure.test(policy.reread.edit_failure_markers.ignore_case ? asciiLower(line) : line));
}

export function recordReadTargets(state: ReadState, targets: Target[], cwd: string, failed: boolean) {
  if (failed) return;
  for (const target of targets) {
    const path = target.operation === "rename" ? target.destination : target.operation === "delete" ? undefined : target.path;
    if (path && !/[\0\t\r\n]/.test(path)) state.known.add(resolve(cwd, path));
  }
}

function deny(reason: string): Decision {
  return { schema_version: 1, capability_status: "unknown", decision: "deny", reason };
}

// Match _se_repo_root's git-common-dir parent without adding a hot-path process.
function autonomyRoot(root: string): string {
  let candidate = root;
  for (;;) {
    const marker = resolve(candidate, ".git");
    const stat = lstatSync(marker, { throwIfNoEntry: false });
    if (stat) {
      if (statSync(marker).isDirectory()) return resolve(realpathSync.native(marker), "..");
      const gitdir = readFileSync(marker, "utf8").split(/\r?\n/)[0].match(/^gitdir: (.+)$/)?.[1];
      if (!gitdir) throw new Error("invalid Git worktree declaration");
      const directory = resolve(candidate, gitdir);
      const commonFile = resolve(directory, "commondir");
      const common = lstatSync(commonFile, { throwIfNoEntry: false })
        ? resolve(directory, readFileSync(commonFile, "utf8").replace(/\n+$/, "")) : directory;
      return resolve(realpathSync.native(common), "..");
    }
    const parent = resolve(candidate, "..");
    if (parent === candidate) return root;
    candidate = parent;
  }
}

// Port of the shared autonomy resolver, using only project data and runtime presets.
// Malformed/unreadable state refuses instead of restoring a permissive default.
export function rereadBudget(root: string, rules: GuardRules): number {
  const json = (path: string): Record<string, unknown> | undefined => {
    if (!lstatSync(path, { throwIfNoEntry: false })) return undefined;
    const value: unknown = JSON.parse(readFileSync(path, "utf8"), (key: string, value: unknown, context?: { source?: string }) => {
      // jq preserves numeric lexemes: 3.0 is not the shell's accepted token 3.
      if ((key === "autonomy" || key === "autonomy_default") && typeof value === "number") {
        if (!context?.source) throw new Error("autonomy numeric spelling unavailable");
        return context.source;
      }
      return value;
    });
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid autonomy policy");
    return value as Record<string, unknown>;
  };
  const valid = (value: unknown): value is number | string => (typeof value === "number" || typeof value === "string") && /^[1-5]$/.test(String(value).replace(/\n+$/, ""));
  const projectRoot = autonomyRoot(root);
  const runtime = json(resolve(root, ".trellis/runtime/trellis.config.json"));
  const canonical = json(resolve(projectRoot, ".trellis.json"));
  const legacy = json(resolve(projectRoot, ".trellis.config.json"));
  const project = canonical && "autonomy" in canonical ? canonical : legacy;
  const presets = canonical && "presets" in canonical ? canonical.presets : legacy?.presets;
  let level = valid(runtime?.autonomy_default) ? Number(runtime.autonomy_default) : 3;
  let ceiling = 5;
  let presetDefault: number | undefined;
  if (Array.isArray(presets)) for (const preset of presets) {
    if (typeof preset !== "string" || !/^[A-Za-z0-9._-]+$/.test(preset)) continue;
    const path = resolve(root, ".trellis/runtime/core-rules/presets", `${preset}.md`);
    if (!lstatSync(path, { throwIfNoEntry: false })) continue;
    const frontmatter = (readFileSync(path, "utf8").match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)?.[1] ?? "").replace(/\r$/gm, "");
    const field = (name: string) => frontmatter.match(new RegExp(`^[ \\t]*${name}:[ \\t]*([^\\r\\n]*?)[ \\t]*$`, "m"))?.[1];
    const def = field("autonomy_default"), cap = field("autonomy_ceiling");
    if (presetDefault === undefined && valid(def)) presetDefault = Number(def);
    if (valid(cap)) ceiling = Math.min(ceiling, Number(cap));
  }
  if (!(project && "autonomy" in project) && presetDefault !== undefined) level = presetDefault;
  if (valid(project?.autonomy)) level = Number(project.autonomy);
  const sessionPath = resolve(projectRoot, ".claude/session-autonomy");
  if (lstatSync(sessionPath, { throwIfNoEntry: false })) {
    const override = readFileSync(sessionPath, "utf8").split(/\r?\n/)[0].replace(/[ \t\r\n\f\v]/g, "");
    if (valid(override)) level = Number(override);
  }
  return rules.reread.warn_budget.by_level[String(Math.min(level, ceiling))] ?? rules.reread.warn_budget.default;
}

function skillManifestReason(path: string): string | undefined {
  try {
    const stat = statSync(path);
    if (!stat.isFile()) throw new Error("manifest is not a regular file");
    if (stat.size > 65_536) return `Skill root exceeds 65536-byte inline budget: ${path} (${stat.size} bytes); refusing pre-load before body injection`;
    new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(path));
  } catch {
    return `Skill manifest is unreadable or invalid UTF-8: ${path}; refusing pre-load before body injection`;
  }
}

function nativeSkillReason(pi: ExtensionAPI, path: string): string | undefined {
  // Resolve aliases too: an innocuous filename must not hide a SKILL.md preload.
  let physical: string | undefined;
  try { physical = realpathSync.native(path); } catch { /* named manifests still refuse below */ }
  const skills = pi.getCommands?.().filter(command => command.source === "skill") ?? [];
  const declared = skills.some(command => {
    const source = command.sourceInfo.path;
    if (source === path) return true;
    try { return physical !== undefined && realpathSync.native(source) === physical; } catch { return false; }
  });
  return basename(path) === "SKILL.md" || (physical && basename(physical) === "SKILL.md") || declared ? skillManifestReason(path) : undefined;
}

function isSubagentControl(pi: ExtensionAPI, name: string): boolean {
  if (!["get_subagent_result", "steer_subagent"].includes(name)) return false;
  const source = pi.getAllTools().find(tool => tool.name === name)?.sourceInfo;
  if (source?.origin !== "package" || !/^npm:@tintinweb\/pi-subagents(?:@[^/\s:]+)?$/.test(source.source)) return false;
  try {
    const entry = realpathSync.native(source.path);
    if (!statSync(entry).isFile()) return false;
    let directory = resolve(entry, "..");
    for (;;) {
      const manifest = resolve(directory, "package.json");
      // The nearest package owns the entry; never inherit an enclosing identity.
      if (lstatSync(manifest, { throwIfNoEntry: false })) {
        return JSON.parse(readFileSync(manifest, "utf8")).name === "@tintinweb/pi-subagents";
      }
      const parent = resolve(directory, "..");
      if (parent === directory) return false;
      directory = parent;
    }
  } catch { return false; }
}

// Mirrors read_state.rs is_override_record_path and _gr_reread_override_path,
// case-folded (macOS volumes usually are) and also through the real path of the
// deepest existing ancestor, so a symlinked spelling cannot reach the records.
function isOverrideRecordPath(path: string): boolean {
  const named = (spelling: string) => {
    const folded = spelling.toLowerCase();
    return folded.endsWith("/state/reread-overrides") || folded.includes("/state/reread-overrides/");
  };
  if (named(path)) return true;
  for (let ancestor = path, rest = ""; ; rest = rest ? `${basename(ancestor)}/${rest}` : basename(ancestor), ancestor = dirname(ancestor)) {
    try { return named(rest ? `${realpathSync.native(ancestor)}/${rest}` : realpathSync.native(ancestor)); }
    catch { if (dirname(ancestor) === ancestor) return false; }
  }
}

function localPreAction(pi: ExtensionAPI, action: NormalizedAction["action"], cwd: string, root: string, state: ReadState, rules: GuardRules): Decision {
  if (action.tool_name === "powershell") return deny("Trellis PowerShell destructive protection is unavailable; refusing pre-action execution");
  if (action.tool_name === "bash") {
    if (typeof action.input.command !== "string") return deny("Trellis shell command is unavailable; refusing pre-action execution");
    const matches = destructiveMatches(rules, action.input.command);
    return { schema_version: 1, capability_status: "enforced",
      decision: matches.some(match => match.effect === "deny") ? "deny" : matches.length ? "warn" : "allow",
      ...(matches.length ? { reason: matches.map(match => match.reason).join("\n") } : {}) };
  }
  if (action.family === "mcp" || action.family === "local_tool" || action.family === "unknown") {
    // Child guard loading is a launcher/roster contract, not parent argument parsing.
    if (action.tool_name === "Agent" || action.tool_name === "SubagentWorkflow") return unhandledDecision("pre_action", action.family);
    if (action.family === "local_tool" && isSubagentControl(pi, action.tool_name)) return unhandledDecision("pre_action", action.family);
    const builtin = ["grep", "find", "ls"].includes(action.tool_name)
      && pi.getAllTools().some(tool => tool.name === action.tool_name && tool.sourceInfo.source === "builtin");
    if (!builtin) return deny(`Trellis refuses unmediated ${action.family} tool '${action.tool_name}': shell/mutation protection is unavailable`);
  }
  if (action.family !== "file_read" && action.family !== "file_mutation") return unhandledDecision("pre_action", action.family);
  const target = action.targets[0];
  if (action.family === "file_read") {
    const reason = target ? nativeSkillReason(pi, resolve(cwd, target.path)) : undefined;
    return reason ? deny(reason) : { schema_version: 1, capability_status: "unsupported", decision: "allow", reason: "pre_action/file_read: unsupported — no pre-action handler" };
  }
  if (!target || action.target_coverage !== "complete" || /[\0\t\r\n]/.test(target.path)) return deny("reread-guard: mutation target is unavailable or unsafe; Read it first");
  const path = resolve(cwd, target.path);
  // Override records authorize stale edits for Claude/Codex/native guards, so
  // they are refused before the create and already-read exemptions.
  for (const named of action.targets.flatMap(t => [t.path, t.destination])) {
    if (named !== undefined && isOverrideRecordPath(resolve(cwd, named))) {
      return { schema_version: 1, capability_status: "enforced", decision: "deny",
        reason: `reread-guard: BLOCKED edit of ${resolve(cwd, named)} — reread override records are written only by trellis reread override --session <id> --reason <why>.` };
    }
  }
  try {
    // Only genuine absence is a create exemption; dangling links/state errors deny.
    if (!lstatSync(path, { throwIfNoEntry: false })) return { schema_version: 1, capability_status: "enforced", decision: "allow" };
    if (!statSync(path).isFile()) return deny("reread-guard: mutation target is not a regular file");
    if (state.known.has(path)) return { schema_version: 1, capability_status: "enforced", decision: "allow" };
    // Native Pi deliberately does not honor an ambient shell override.
    return rereadDecision(rules, path, state, rereadBudget(root, rules));
  } catch {
    return deny("reread-guard: target or autonomy state is unreadable; refusing mutation");
  }
}

// HEAD is metadata, not an authorization token. Include the worktree-local
// branch spelling in read identity without launching Git on ordinary tools.
// Detached HEAD deliberately binds the commit: rebase/bisect can rewrite file
// contents, so a changed commit requires a fresh read rather than stale credit.
function readBinding(cwd: string): string {
  const root = attachedRoot(cwd);
  let candidate = resolve(cwd);
  for (;;) {
    const marker = resolve(candidate, ".git");
    if (lstatSync(marker, { throwIfNoEntry: false })) {
      const directory = statSync(marker).isDirectory() ? marker
        : resolve(candidate, readFileSync(marker, "utf8").split(/\r?\n/)[0].match(/^gitdir: (.+)$/)?.[1] ?? "invalid-gitdir");
      return JSON.stringify([root, realpathSync.native(directory), readFileSync(resolve(directory, "HEAD"), "utf8").trim()]);
    }
    const parent = resolve(candidate, "..");
    if (parent === candidate) return JSON.stringify([root, "no-git"]);
    candidate = parent;
  }
}

function policyPath(cwd: string) {
  return resolve(cwd, ".agents/rules/trellis.md");
}

function readPolicy(cwd: string): string | undefined {
  try {
    const policy = readFileSync(policyPath(cwd), "utf8").trim();
    return policy || undefined;
  } catch {
    return undefined;
  }
}

const runtimeUnavailable = "Trellis runtime capability is unknown: .trellis/runtime is missing or invalid; the nearest declared anchor must resolve to a directory containing a regular trellis.config.json. Actions are blocked.";

function attachedRoot(cwd: string): string | undefined {
  let candidate = resolve(cwd);
  for (;;) {
    const runtime = resolve(candidate, ".trellis/runtime");
    try {
      // A broken nearer declaration must never inherit an ancestor's runtime.
      if (lstatSync(runtime, { throwIfNoEntry: false })) {
        return statSync(runtime).isDirectory() && statSync(resolve(runtime, "trellis.config.json")).isFile() ? candidate : undefined;
      }
    } catch {
      return undefined;
    }
    const parent = resolve(candidate, "..");
    if (parent === candidate) break;
    candidate = parent;
  }
  return undefined;
}

function targetPath(cwd: string, value: unknown, read = false): string | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  // Match Pi's native tool path rules, not just shell-relative spelling.
  let path = value.replace(/[\u00a0\u2000-\u200a\u202f\u205f\u3000]/g, " ").replace(/^@/, "");
  if (path === "~") path = homedir();
  else if (path.startsWith("~/")) path = resolve(homedir(), path.slice(2));
  if (path.startsWith("file://")) {
    try { path = fileURLToPath(path); } catch { return undefined; }
  }
  path = resolve(cwd, path);
  if (read && !existsSync(path)) {
    const nfd = path.normalize("NFD");
    const variants = [path.replace(/ (AM|PM)\./gi, "\u202f$1."), nfd, path.replace(/'/g, "\u2019"), nfd.replace(/'/g, "\u2019")];
    path = variants.find(candidate => existsSync(candidate)) ?? path;
  }
  return relative(cwd, path) || ".";
}

function classify(pi: ExtensionAPI, name: string): NormalizedAction["action"]["family"] {
  if (name === "bash" || name === "powershell") return "shell";
  if (name === "read") return "file_read";
  if (name === "edit" || name === "write") return "file_mutation";
  const source = pi.getAllTools().find((tool) => tool.name === name)?.sourceInfo.source.toLowerCase() ?? "";
  if (source.includes("mcp")) return "mcp";
  return source ? "local_tool" : "unknown";
}

function actionFor(pi: ExtensionAPI, cwd: string, id: string, name: string, input: Record<string, unknown>) {
  const family = classify(pi, name);
  const path = targetPath(cwd, input.path ?? input.file_path ?? input.filePath, family === "file_read");
  let targets: Target[] = [];
  let target_coverage: "complete" | "partial" | "none" = "none";
  if (path && family === "file_read") {
    targets = [{ operation: "read", path }];
    target_coverage = "complete";
  } else if (path && family === "file_mutation") {
    const operation = name === "write" && !existsSync(resolve(cwd, path)) ? "create" : "update";
    targets = [{ operation, path }];
    target_coverage = "complete";
    const aliases = [input.path, input.file_path, input.filePath].filter(value => value !== undefined && value !== null);
    const indirect = ["targets", "files", "paths", "destination", "destination_path", "destinationPath", "patch", "notebook_path", "notebookPath"].some(key => key in input);
    const editTargets = Array.isArray(input.edits) && input.edits.some(edit => edit && typeof edit === "object"
      && ["path", "file_path", "filePath", "target", "destination"].some(key => key in edit));
    if (aliases.some(value => targetPath(cwd, value) !== path) || indirect || editTargets) target_coverage = "partial";
  }
  return { id, tool_name: name, family, target_coverage, targets, input: structuredClone(input) } as NormalizedAction["action"];
}

type HandlerContext = {
  cwd: string; signal: ExtensionContext["signal"]; session_id: string; session_file?: string;
  notify: ExtensionContext["ui"]["notify"];
  postDeadline?: number;
};

function snapshot(ctx: ExtensionContext): HandlerContext {
  const cwd = ctx.cwd, signal = ctx.signal, ui = ctx.ui;
  const session_id = ctx.sessionManager.getSessionId(), session_file = ctx.sessionManager.getSessionFile();
  return { cwd, signal, session_id, ...(session_file ? { session_file } : {}), notify: ui.notify.bind(ui) };
}

function session(ctx: HandlerContext) {
  return { cwd: ctx.cwd, session_id: ctx.session_id, ...(ctx.session_file ? { session_file: ctx.session_file } : {}) };
}

const MAX_DISPATCH_EVENT_BYTES = 64 * 1024 * 1024;

function missingPath(error: unknown): boolean {
  return !!error && typeof error === "object" && "code" in error && error.code === "ENOENT";
}

async function dispatch(pi: ExtensionAPI, event: NormalizedAction | Record<string, unknown>, ctx: HandlerContext, cwd = ctx.cwd): Promise<Decision> {
  const root = attachedRoot(cwd);
  if (!root) return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: runtimeUnavailable };
  const script = resolve(root, ".trellis/runtime/core-rules/pi/hooks/dispatch.sh");
  if (!existsSync(script)) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: "Trellis Pi dispatcher is missing from the attached immutable runtime" };
  }
  let payload: Buffer;
  try {
    const serialized = JSON.stringify(event);
    if (serialized === undefined) throw new Error("event is not JSON serializable");
    payload = Buffer.from(serialized, "utf8");
  } catch {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: "Trellis Pi event could not be serialized; refusing dispatcher call" };
  }
  if (payload.byteLength > MAX_DISPATCH_EVENT_BYTES) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: `Trellis Pi event exceeds the ${MAX_DISPATCH_EVENT_BYTES}-byte dispatcher transport limit; refusing event` };
  }

  const nonce = randomBytes(32).toString("hex");
  let eventDirectory: string | undefined;
  let eventFile: string | undefined;
  let result: Awaited<ReturnType<ExtensionAPI["exec"]>> | undefined;
  let dispatchError: string | undefined;
  const cleanupErrors: string[] = [];
  try {
    eventDirectory = mkdtempSync(resolve(tmpdir(), "trellis-pi-event-"));
    chmodSync(eventDirectory, 0o700);
    eventFile = resolve(eventDirectory, "event.json");
    writeFileSync(eventFile, payload, { flag: "wx", mode: 0o600 });
    chmodSync(eventFile, 0o600);
    // Pi exec has no env option. env sets this invocation's nonce without
    // mutating process.env (dispatches can overlap). An explicit executable
    // keeps env from interpreting a script path containing '=' as an assignment.
    result = await pi.exec("/usr/bin/env", [`TRELLIS_PI_DISPATCH_NONCE=${nonce}`, "/bin/bash", script, "--event-file", eventFile], { cwd: root, timeout: 300_000, signal: ctx.signal });
  } catch (error) {
    dispatchError = `Trellis Pi dispatcher could not run: ${error instanceof Error ? error.message : String(error)}`;
  } finally {
    if (eventFile) {
      try { unlinkSync(eventFile); } catch (error) {
        if (!missingPath(error)) cleanupErrors.push(`event file: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (eventDirectory) {
      try { rmdirSync(eventDirectory); } catch (error) {
        if (!missingPath(error)) cleanupErrors.push(`private directory: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
  if (cleanupErrors.length) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: `Trellis Pi dispatcher event transport cleanup failed: ${cleanupErrors.join("; ")}` };
  }
  if (dispatchError) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: dispatchError };
  }
  if (!result) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: "Trellis Pi dispatcher returned no result" };
  }
  // A killed/abnormal dispatcher cannot authorize an action with partial output.
  if (result.killed || result.truncated || !Number.isInteger(result.code) || result.code < 0 || result.code > 127) {
    return deny(`Trellis Pi dispatcher ${result.killed ? "was killed" : result.truncated ? "was truncated" : "returned an invalid or signal status"} (status ${String(result.code)}); refusing partial output`);
  }
  // Pi 1.5.0 maps an external signal death to code 0/killed false. Require
  // positive completion: exactly one decision then the call-bound final record.
  const records = /^([^\r\n]+)\n([^\r\n]+)\n$/.exec(result.stdout);
  try {
    const terminal: unknown = JSON.parse(records?.[2] ?? "");
    if (!terminal || typeof terminal !== "object" || Array.isArray(terminal)
        || Object.keys(terminal).length !== 4
        || !("schema_version" in terminal) || terminal.schema_version !== 1
        || !("type" in terminal) || terminal.type !== "trellis_dispatch_complete"
        || !("complete" in terminal) || terminal.complete !== true
        || !("nonce" in terminal) || terminal.nonce !== nonce) {
      throw new Error("missing or invalid completion record");
    }
    const parsed: unknown = JSON.parse(records?.[1] ?? "");
    if (isDecision(parsed)) {
      if (result.code !== 0 && parsed.decision === "allow") throw new Error("nonzero dispatcher returned allow");
      const stderr = result.stderr.trim();
      return stderr ? {
        ...parsed,
        decision: parsed.decision === "allow" ? "warn" : parsed.decision,
        reason: [parsed.reason, `Trellis Pi dispatcher stderr: ${stderr}`].filter(Boolean).join("\n"),
      } : parsed;
    }
  } catch { /* converted to a visible fail-closed decision below */ }
  return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: result.stderr.trim() || `Trellis Pi dispatcher failed completion or decision validation (status ${String(result.code)})` };
}

function isDecision(value: unknown): value is Decision {
  if (!value || typeof value !== "object") return false;
  return "schema_version" in value && value.schema_version === 1
    && "decision" in value && (value.decision === "allow" || value.decision === "deny" || value.decision === "warn")
    && "capability_status" in value && (value.capability_status === "enforced" || value.capability_status === "advisory" || value.capability_status === "unsupported" || value.capability_status === "disabled" || value.capability_status === "unknown")
    && (!("reason" in value) || typeof value.reason === "string")
    && (!("context" in value) || typeof value.context === "string");
}

// Native result details are structured response data, not edited source text.
function resultFailed(event: ToolResultEvent, family: NormalizedAction["action"]["family"], rules: GuardRules): boolean {
  if (event.isError) return true;
  if (family !== "file_mutation" && family !== "file_read") return false;
  const details: unknown = event.details;
  if (details && typeof details === "object") {
    return responseFailed(rules, details, event.toolName); // Echoed source text is not failure evidence.
  }
  if (family === "file_mutation") {
    const text = event.content.filter(block => block.type === "text").map(block => block.text).join("\n");
    const head = asciiLower(text);
    return head.startsWith("error") || head.startsWith("no files were modified.") || responseFailed(rules, text, event.toolName);
  }
  return false; // Successful reads contain arbitrary file text, never failure evidence.
}

function unhandledDecision(phase: string, family: string): Decision {
  return { schema_version: 1, capability_status: "unsupported", decision: "allow", reason: `${phase}/${family}: unsupported — no ${phase === "pre_action" ? "pre" : "post"}-action handler` };
}

// A conservative no-op filter, not a shell parser. The release-owned
// core-rules/codex/hooks/pr-gate-shiftleft.sh owns detection; keep this superset
// aligned when its scanner learns spellings. Prose can trigger a harmless fork.
function mayCreatePr(command: unknown): boolean {
  if (typeof command !== "string") return false;
  const text = command.replace(/\\\n/g, "").replace(/['"\\]/g, "");
  return text.includes("gh") && text.includes("pr") && text.includes("create");
}

function isCapabilityOnly(decision: Decision): boolean {
  return decision.decision === "allow"
    && (decision.capability_status === "unsupported" || decision.capability_status === "advisory")
    && !decision.context;
}

function show(ctx: HandlerContext, decision: Decision) {
  if (decision.reason && decision.decision !== "allow") {
    ctx.notify(decision.reason, decision.decision === "deny" ? "error" : "warning");
  }
}

type SlopRow = { id: string; match: string; suppress: string };

// Consume literal data from the shared advisory policy, never execute it or
// maintain a second copy of its patterns. Refuse an unfamiliar shell encoding.
export function slopPolicy(source: string, language: string): { rows: SlopRow[]; globs: string[]; doctrine: string } {
  const literalWords = (body: string): string[] => {
    const words: string[] = [];
    for (const line of body.split("\n")) {
      if (/^\s*(#|$)/.test(line)) continue;
      let rest = line.trim().replace(/^printf\s+'%s(?:\\t%s\\t%s)?\\n'\s*/, "");
      while (rest && rest !== "\\") {
        const token = rest.match(/^'([^']*)'|^"((?:\\.|[^"\\])*)"/);
        if (!token) throw new Error("unsupported shared slop policy literal");
        if (token[2] !== undefined && /(?<!\\)[`$]/.test(token[2])) throw new Error("nonliteral shared slop policy");
        words.push(token[1] ?? token[2].replace(/\\([\\"$`])/g, "$1"));
        rest = rest.slice(token[0].length).trim();
      }
    }
    return words;
  };
  const body = source.match(/slop_patterns_for_lang\(\) \{([\s\S]*?)\n\}/)?.[1];
  const section = body?.match(new RegExp(`^    ${language}\\)\\n([\\s\\S]*?)^      ;;`, "m"))?.[1];
  const carve = source.match(/slop_carve_out_globs\(\) \{([\s\S]*?)\n\}/)?.[1];
  const doctrine = source.match(/^SLOP_DOCTRINE_REF="([^"$`]+)"$/m)?.[1];
  if (!section || !carve || !doctrine) throw new Error("shared slop policy is unavailable");
  const words = literalWords(section);
  if (!words.length || words.length % 3) throw new Error("invalid shared slop rows");
  const rows: SlopRow[] = [];
  for (let i = 0; i < words.length; i += 3) rows.push({ id: words[i], match: words[i + 1], suppress: words[i + 2] });
  return { rows, globs: literalWords(carve), doctrine };
}

export function scanSlop(rows: SlopRow[], lines: { number: number; text: string }[]) {
  const ere = (pattern: string) => new RegExp(pattern.replaceAll("[[:space:]]", "[ \\t\\r\\n\\v\\f]"));
  const rules = rows.map(row => ({ ...row, pattern: ere(row.match), escape: row.suppress === "-" ? undefined : ere(row.suppress) }));
  const findings: { id: string; line: number }[] = [];
  let previous = "", comments = "";
  for (const line of lines) {
    for (const rule of rules) if (rule.pattern.test(line.text) && ![line.text, previous, comments].some(text => rule.escape?.test(text))) findings.push({ id: rule.id, line: line.number });
    previous = line.text;
    comments = /^[ \t\r\v\f]*(#|\/\/|\/\*|\*)/.test(line.text) ? `${comments} ${line.text}` : "";
  }
  return findings;
}

function executable(command: string, cwd: string): string | undefined {
  const paths = command.includes("/") ? [resolve(cwd, command)] : (process.env.PATH ?? "").split(delimiter).map(dir => resolve(dir || cwd, command));
  return paths.find(path => {
    try { accessSync(path, constants.X_OK); return statSync(path).isFile(); } catch { return false; }
  });
}

// Match the previous dispatcher's whole-event 300 s envelope, not a new
// per-linter 20 s cutoff. Each awaited subprocess gets the remaining budget.
function postTimeout(ctx: HandlerContext): number {
  const remaining = (ctx.postDeadline ?? Date.now() + 300_000) - Date.now();
  if (remaining <= 0) throw new Error("post-action batch deadline exceeded (300000 ms)");
  return remaining;
}

async function gitRead(pi: ExtensionAPI, cwd: string, args: string[], ctx: HandlerContext) {
  const unset = new Set(["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", ...Object.keys(process.env).filter(key => key.startsWith("GIT_CONFIG_"))]);
  const result = await pi.exec("env", [...[...unset].flatMap(key => ["-u", key]), "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", ...args], { cwd, timeout: postTimeout(ctx), signal: ctx.signal });
  if (result.killed) throw new Error("Git snapshot did not complete");
  return result;
}

async function lintPostTargets(pi: ExtensionAPI, paths: string[], ctx: HandlerContext, onError: (error: unknown) => void, onWarning: (warning: string) => void): Promise<string | undefined> {
  const errors: string[] = [];
  let rustChecked = false;
  const run = async (command: string, args: string[], cwd: string, label: string, localEslint = false) => {
    const result = await pi.exec(command, args, { cwd, timeout: postTimeout(ctx), signal: ctx.signal });
    if (result.killed) throw new Error(`${label}: linter did not complete`);
    if (result.code !== 0) {
      if (localEslint && (await pi.exec(command, ["--version"], { cwd, timeout: postTimeout(ctx), signal: ctx.signal })).code !== 0) return;
      errors.push(`${label}\n${[result.stdout, result.stderr].filter(Boolean).join("\n").trimEnd()}\n`);
    }
  };
  for (const path of paths) {
    try {
    const extension = extname(path);
    if ([".ts", ".tsx", ".js", ".jsx"].includes(extension)) {
      if (![".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yml", ".eslintrc.yaml", "eslint.config.js", "eslint.config.mjs", "eslint.config.ts"].some(file => existsSync(resolve(ctx.cwd, file)))) continue;
      const npx = executable("npx", ctx.cwd);
      const local = npx && executable("./node_modules/.bin/eslint", ctx.cwd);
      if (local) await run(local, ["--quiet", path], ctx.cwd, `eslint: ${path}`, true);
      else if (npx) {
        // Existing canonical linter resolution only, never install a package.
        const probe = await pi.exec(npx, ["--no-install", "eslint", "--version"], { cwd: ctx.cwd, timeout: postTimeout(ctx), signal: ctx.signal });
        if (probe.killed) throw new Error("eslint discovery did not complete");
        if (probe.code === 0) await run(npx, ["--no-install", "eslint", "--quiet", path], ctx.cwd, `eslint: ${path}`);
      }
    } else if (extension === ".py") {
      const ruff = executable("ruff", ctx.cwd);
      if (ruff) await run(ruff, ["check", path], ctx.cwd, `ruff: ${path}`);
    } else if (extension === ".rs" && !rustChecked && existsSync(resolve(ctx.cwd, "Cargo.toml"))) {
      const cargo = executable("cargo", ctx.cwd);
      if (cargo) { rustChecked = true; await run(cargo, ["clippy", "--quiet", "--message-format=short", "--", "-D", "warnings"], ctx.cwd, "clippy: (project-wide)"); }
    } else if (extension === ".go") {
      let root = dirname(path);
      while (!existsSync(resolve(root, "go.mod")) && dirname(root) !== root) root = dirname(root);
      if (!existsSync(resolve(root, "go.mod"))) {
        onWarning(`post-edit-verify: skipping Go lint for ${path}: no owning go.mod found`);
        continue;
      }
      const golangci = executable("golangci-lint", ctx.cwd), go = executable("go", ctx.cwd);
      if (golangci) await run(golangci, ["run", `./${relative(root, path)}`], root, `golangci-lint: ${path}`);
      else if (go) await run(go, ["vet", `./${relative(root, dirname(path))}${root === dirname(path) ? "" : "/"}...`], root, `go vet: ${dirname(path)}`);
    }
    } catch (error) { onError(error); }
  }
  return errors.length ? `Lint failed — fix before continuing:\n${errors.join("\n").trimEnd().split("\n").slice(0, 50).join("\n")}` : undefined;
}

async function slopPostTargets(pi: ExtensionAPI, paths: string[], root: string, ctx: HandlerContext, onError: (error: unknown) => void): Promise<string | undefined> {
  if (process.env.SLOP_TRIPWIRE === "off") return;
  const messages: string[] = [];
  let total = 0, doctrine = "", source: string | undefined;
  const policies = new Map<string, ReturnType<typeof slopPolicy>>();
  for (const path of paths) {
    const language = ({ ".ts": "ts", ".tsx": "ts", ".js": "ts", ".jsx": "ts", ".py": "py", ".go": "go", ".rs": "rs", ".java": "java" } as Record<string, string>)[extname(path)];
    if (!language) continue;
    try {
    source ??= readFileSync(resolve(root, ".trellis/runtime/core-rules/hooks/lib/slop-patterns.sh"), "utf8");
    let policy = policies.get(language);
    if (!policy) { policy = slopPolicy(source, language); policies.set(language, policy); }
    doctrine = policy.doctrine;
    const directory = dirname(path), leaf = `./${basename(path)}`;
    const prefix = await gitRead(pi, directory, ["rev-parse", "--show-prefix"], ctx);
    const probe = prefix.code === 0 ? `/${prefix.stdout.trimEnd()}${basename(path)}` : path;
    if (policy.globs.some(glob => new RegExp(`^${glob.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*+/g, ".*")}$`).test(probe))) continue;
    let lines: { number: number; text: string }[];
    const head = await gitRead(pi, directory, ["rev-parse", "--verify", "HEAD"], ctx);
    const tracked = head.code === 0 && (await gitRead(pi, directory, ["ls-files", "--error-unmatch", "--", leaf], ctx)).code === 0;
    if (tracked) {
      const diff = await gitRead(pi, directory, ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U0", "HEAD", "--", leaf], ctx);
      if (diff.code !== 0 || diff.killed) throw new Error("Git added-line snapshot failed");
      lines = [];
      let number = 0, hunk = false;
      for (const line of diff.stdout.split("\n")) {
        const match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
        if (match) { number = Number(match[1]); hunk = true; }
        else if (hunk && line.startsWith("+")) lines.push({ number: number++, text: line.slice(1) });
      }
    } else {
      const content = readFileSync(path, "utf8").replace(/\n$/, "");
      lines = content ? content.split("\n").map((text, index) => ({ number: index + 1, text })) : [];
    }
    for (const finding of scanSlop(policy.rows, lines)) {
      total++;
      if (messages.length < 5) messages.push(`slop-tripwire: ${finding.id} at ${path}:${finding.line}`);
    }
    } catch (error) { onError(error); }
  }
  if (messages.length) return `${messages.join("\n")}${total > messages.length ? ` (+${total - messages.length} more)` : ""} — evidence doctrine: ${doctrine}`;
}

// One captured ordered batch; each stage is awaited even after another fails.
// The tracking callback is omitted when the native caller already gave credit.
export async function localPostAction(pi: ExtensionAPI, event: NormalizedAction & { in_process_read_tracking?: boolean }, ctx: HandlerContext, trackRead?: () => void | Promise<void>,
  onVerify?: (paths: string[], failure: string | undefined, unknown: boolean) => void): Promise<Decision> {
  ctx = { ...ctx, postDeadline: Date.now() + 300_000 };
  const root = attachedRoot(ctx.cwd);
  if (!root) return deny(runtimeUnavailable);
  if (event.result?.status === "failed") return { schema_version: 1, capability_status: "unsupported", decision: "allow", reason: "post_action/file_mutation: unsupported — checks skipped due to failed result" };
  const captureErrors: string[] = [];
  const paths = [...new Set(event.action.targets.flatMap(target => {
    const path = target.operation === "rename" ? target.destination : ["create", "update"].includes(target.operation) ? target.path : undefined;
    if (!path || /[\0\t\r\n]/.test(path)) return [];
    const absolute = resolve(ctx.cwd, path);
    try { return existsSync(absolute) && statSync(absolute).isFile() ? [absolute] : []; }
    catch (error) { captureErrors.push(`post-action target: unknown — ${error instanceof Error ? error.message : String(error)}`); return []; }
  }))];
  const reasons: string[] = captureErrors, contexts: string[] = [];
  let capability: Decision["capability_status"] = captureErrors.length ? "unknown" : "advisory";
  // Mandatory post-edit-verify outcome (T33): a lint finding or an unknown
  // verifier failure latches completion; display stays advisory below.
  const verifyFailures: string[] = [];
  let verifyUnknown = false;
  const failure = (name: string, error: unknown) => {
    capability = "unknown";
    const text = `${name}: unknown — ${error instanceof Error ? error.message : String(error)}`;
    reasons.push(text);
    if (name === "post-edit-verify.sh") { verifyFailures.push(text); verifyUnknown = true; }
  };
  const stage = async (name: string, work: () => Promise<void> | void) => {
    try { await work(); } catch (error) { failure(name, error); }
  };
  await stage("post-edit-verify.sh", async () => { const reason = await lintPostTargets(pi, paths, ctx, error => failure("post-edit-verify.sh", error), warning => reasons.push(`post-edit-verify.sh stderr: ${warning}`)); if (reason) { reasons.push(`post-edit-verify.sh: ${reason}`); verifyFailures.push(`post-edit-verify.sh: ${reason}`); } });
  onVerify?.(paths, verifyFailures.length ? verifyFailures.join("\n") : undefined, verifyUnknown);
  await stage("slop-tripwire.sh", async () => { const context = await slopPostTargets(pi, paths, root, ctx, error => failure("slop-tripwire.sh", error)); if (context) contexts.push(context); });
  if (!event.in_process_read_tracking) await stage("track-read.sh", async () => {
    if (!trackRead) throw new Error("tracking callback unavailable");
    await trackRead();
  });
  await stage("wiki-skill-suggest.sh", async () => {
    if (!executable("git", ctx.cwd)) {
      reasons.push("wiki-skill-suggest.sh stderr: wiki-skill-suggest: git not found; degrading to no-op");
      return;
    }
    // Compatibility normalization carries the original input spelling and no
    // native cwd into this advisory. Keep its bare-basename exclusion.
    const spelling = event.action.input.path ?? event.action.input.file_path ?? event.action.input.filePath;
    if (typeof spelling !== "string" || !spelling.includes("/")) return;
    const canonical = autonomyRoot(ctx.cwd), gotchas = resolve(canonical, "gotchas.md");
    if (!existsSync(gotchas)) return;
    const identity = statSync(gotchas);
    if (!paths.some(path => { const stat = statSync(path); return stat.dev === identity.dev && stat.ino === identity.ino; })) return;
    if ((await gitRead(pi, ctx.cwd, ["rev-parse", "--is-inside-work-tree"], ctx)).code === 0) contexts.push("wiki-skill-suggest: project-root gotchas.md changed; consider running wiki-maintain explicitly for any qualifying procedure.");
  });
  return { schema_version: 1, capability_status: capability, decision: reasons.length ? "warn" : "allow", ...(reasons.length ? { reason: reasons.join("\n") } : {}), ...(contexts.length ? { context: contexts.join("\n\n") } : {}) };
}

export function decisionContext(decision: Decision, deliveredReasons: Set<string>): string {
  let reason = decision.reason;
  if (reason && decision.decision === "allow" && (decision.capability_status === "unsupported" || decision.capability_status === "advisory")) {
    const key = JSON.stringify([decision.capability_status, reason]);
    if (deliveredReasons.has(key)) reason = undefined;
    else deliveredReasons.add(key);
  }
  return [decision.context, reason].filter(Boolean).join("\n\n");
}

// Keep result delivery independent from the evaluator (local or compatibility).
// Pi partial patches preserve native details/isError/usage and binary blocks.
export function deliverPostResult(pi: ExtensionAPI, ctx: HandlerContext, event: ToolResultEvent,
  pre: { context: string; capabilityOnly: boolean } | undefined, decision: Decision, deliveredReasons: Set<string>) {
  show(ctx, { ...decision, decision: decision.decision === "deny" ? "warn" : decision.decision });
  const postContext = decisionContext(decision, deliveredReasons);
  const postAdvisory = postContext ? `[Trellis post-action advisory; capability: ${decision.capability_status}]\n${postContext}` : "";
  const successfulRead = event.toolName === "read" && !event.isError;
  const separatePre = successfulRead && pre?.capabilityOnly;
  const separatePost = successfulRead && isCapabilityOnly(decision);
  const capabilityContext = [separatePre ? pre?.context : undefined, separatePost ? postAdvisory : undefined].filter(Boolean).join("\n\n");
  if (capabilityContext) pi.sendMessage({ customType: "trellis-context", content: capabilityContext, display: false }, { triggerTurn: false });
  const context = [separatePre ? undefined : pre?.context, separatePost ? undefined : postAdvisory].filter(Boolean).join("\n\n");
  if (context) return { content: [...event.content, { type: "text" as const, text: context }] };
}

export default function trellisPiExtension(pi: ExtensionAPI) {
  // Keep initialization failures in the execution gate, not the factory. Pi
  // >=1.4 blocks thrown handlers; explicit block returns also protect older hosts.
  let rules: GuardRules | undefined;
  let ruleError: unknown;
  let rulesInitialized = false;
  function guardRules(): GuardRules {
    if (!rulesInitialized) {
      rulesInitialized = true;
      try { rules = loadGuardRules(); } catch (error) { ruleError = error; }
    }
    if (!rules) throw new Error("Trellis guard rules are unavailable; refusing execution", { cause: ruleError });
    return rules;
  }
  const pending = new Map<string, { action: NormalizedAction["action"]; input: object; cwd: string; binding: string; context: string; capabilityOnly: boolean; state: ReadState }>();
  const callGenerations = new WeakMap<object, number>();
  const readStates = new Map<string, ReadState>();
  let generation = 0;
  let userBashSequence = 0;

  function readState(ctx: HandlerContext): ReadState {
    const key = JSON.stringify([readBinding(ctx.cwd), ctx.session_id]);
    let state = readStates.get(key);
    if (!state) { state = { known: new Set(), warns: new Map() }; readStates.set(key, state); }
    return state;
  }

  function resetReads() {
    pending.clear();
    readStates.clear();
    generation++;
  }

  const pendingKey = (epoch: number, ctx: HandlerContext, id: string) => JSON.stringify([epoch, ctx.session_id, ctx.cwd, id]);
  let pendingContext: { identity: string; text: string } | undefined;
  let lifecycleEpoch = 0;
  let shutdownTask: { identity: string; task: Promise<void> } | undefined;
  const deliveredReasons = new Set<string>();

  function lifecycleIdentity(ctx: HandlerContext): string | undefined {
    try {
      const root = attachedRoot(ctx.cwd);
      return root ? JSON.stringify([ctx.session_id, readBinding(ctx.cwd), realpathSync.native(resolve(root, ".trellis/runtime"))]) : undefined;
    } catch { return undefined; }
  }

  function currentLifecycle(ctx: HandlerContext, identity: string | undefined, epoch: number): boolean {
    // Lifecycle output is intended for the next prompt too. Read-generation
    // changes do not invalidate checks that ran in the same bound session.
    return epoch === lifecycleEpoch && identity === lifecycleIdentity(ctx);
  }

  function queueContext(identity: string | undefined, decision: Decision) {
    if (!identity) return;
    const text = advisoryContext(decision);
    pendingContext = { identity, text: [pendingContext?.identity === identity ? pendingContext.text : undefined, text].filter(Boolean).join("\n\n") };
  }

  function advisoryContext(decision: Decision): string {
    return decisionContext(decision, deliveredReasons);
  }

  function resetSession() {
    lifecycleEpoch++;
    shutdownTask = undefined;
    pending.clear();
    resetReads();
    pendingContext = undefined;
    deliveredReasons.clear();
    userBashSequence = 0;
  }

  // T33 completion state: needs_check | blocked | accepted, kept apart from
  // read maps so no read/session reset can clear it. Persisted as a custom
  // session entry; a missing or malformed entry on reload is needs_check.
  type CompletionState = { status: "needs_check" | "blocked" | "accepted"; unknown: boolean; reason: string;
    postFailures: Record<string, string>; continuations: number; noProgress: number; binding: string; turn: number };
  const COMPLETION_ENTRY = "trellis-completion", MAX_CONTINUATIONS = 3, MAX_NO_PROGRESS = 2;
  const freshCompletion = (binding = ""): CompletionState =>
    ({ status: "needs_check", unknown: false, reason: "", postFailures: {}, continuations: 0, noProgress: 0, binding, turn: 0 });
  let completion = freshCompletion();

  function validCompletion(data: unknown): data is CompletionState {
    if (!data || typeof data !== "object") return false;
    const d = data as Record<string, unknown>;
    return (d.status === "needs_check" || d.status === "blocked" || d.status === "accepted")
      && typeof d.unknown === "boolean" && typeof d.reason === "string" && typeof d.binding === "string"
      && Number.isInteger(d.continuations) && Number.isInteger(d.noProgress) && Number.isInteger(d.turn)
      && !!d.postFailures && typeof d.postFailures === "object" && !Array.isArray(d.postFailures)
      && Object.values(d.postFailures as object).every(v => typeof v === "string");
  }

  function persistCompletion() {
    // Persistence failure keeps the in-memory latch; it never accepts a turn.
    try { pi.appendEntry(COMPLETION_ENTRY, { ...completion, postFailures: { ...completion.postFailures } }); } catch { /* latch stays in memory */ }
  }

  function restoreCompletion(context: ExtensionContext, cwd: string) {
    const binding = readBinding(cwd);
    let restored: CompletionState | undefined;
    try {
      const manager = context.sessionManager as Partial<Pick<ExtensionContext["sessionManager"], "getBranch" | "getEntries">>;
      const entries = manager.getBranch?.() ?? manager.getEntries?.() ?? [];
      for (let i = entries.length - 1; i >= 0 && !restored; i--) {
        const entry = entries[i] as { type?: string; customType?: string; data?: unknown };
        if (entry?.type !== "custom" || entry.customType !== COMPLETION_ENTRY) continue;
        restored = validCompletion(entry.data) && entry.data.binding === binding ? { ...entry.data, postFailures: { ...entry.data.postFailures } } : freshCompletion(binding);
      }
    } catch { restored = undefined; }
    completion = restored ?? freshCompletion(binding);
  }

  // A verifier that could not run is unknown enforcement, not a lint finding;
  // it stays unknown until a fresh completion check passes.
  function latchPost(ctx: HandlerContext, paths: string[], failure: string | undefined, unknown = false) {
    if (!paths.length) return;
    const before = JSON.stringify(completion.postFailures);
    for (const path of paths) {
      if (failure) completion.postFailures[path] = failure;
      else delete completion.postFailures[path];
    }
    if (failure) completion = { ...completion, status: "blocked", unknown: unknown || (completion.status === "blocked" && completion.unknown), reason: failure, binding: readBinding(ctx.cwd) };
    if (JSON.stringify(completion.postFailures) !== before || failure) persistCompletion();
  }

  async function recheckPost(ctx: HandlerContext) {
    const paths = Object.keys(completion.postFailures);
    const errors: string[] = [];
    const present = paths.filter(path => { try { return statSync(path).isFile(); } catch { return false; } });
    const reason = await lintPostTargets(pi, present, { ...ctx, postDeadline: Date.now() + 300_000 },
      error => errors.push(`post-edit-verify.sh: unknown — ${error instanceof Error ? error.message : String(error)}`), () => {});
    const failure = errors.length ? errors.join("\n") : reason ? `post-edit-verify.sh: ${reason}` : undefined;
    // Removed targets have nothing left to verify. The rerun decides: a
    // verifier that ran turns the latch into a known, repairable finding.
    for (const path of paths) if (!present.includes(path)) delete completion.postFailures[path];
    completion = { ...completion, unknown: false };
    if (present.length) latchPost(ctx, present, failure, errors.length > 0);
    else persistCompletion();
  }

  // Unknown enforcement denies covered actions; a known project-check failure
  // permits ordinary guarded repairs (per-call guards still run).
  function completionGate(covered: boolean): string | undefined {
    if (!covered || completion.status !== "blocked" || !completion.unknown) return;
    return `Trellis completion enforcement is unavailable; covered actions are blocked until a completion check succeeds: ${completion.reason}`;
  }

  function lastAssistantText(event: AgentBeforeSettleEvent): string {
    const messages = (event.context?.contextMessages ?? []) as Array<{ role?: string; content?: unknown }>;
    for (let i = messages.length - 1; i >= 0; i--) {
      const message = messages[i];
      if (message?.role !== "assistant") continue;
      if (typeof message.content === "string") return message.content;
      if (Array.isArray(message.content)) return message.content.filter(b => b && b.type === "text").map(b => String(b.text)).join("\n");
      return "";
    }
    return "";
  }

  function blockSettle(event: AgentBeforeSettleEvent, ctx: HandlerContext | undefined, reason: string, unknown: boolean): BoundaryResult {
    const same = completion.status === "blocked" && completion.reason === reason;
    completion = { ...completion, status: "blocked", unknown, reason, noProgress: same ? completion.noProgress + 1 : 0 };
    const canContinue = event.context?.canContinue === true && completion.continuations < MAX_CONTINUATIONS && completion.noProgress < MAX_NO_PROGRESS;
    if (canContinue) completion.continuations++;
    const text = `[Trellis completion blocked; enforcement: ${unknown ? "unknown" : "known project-check failure"}]\n${reason}\n`
      + (canContinue ? "Resolve the failure; completion is checked again before the run settles."
        : "No further automatic continuation; completion stays blocked until a fresh check passes.");
    try { ctx?.notify(text, "error"); } catch { /* the published entries still carry it */ }
    // Publish the blocked state with (and before) any continuation request.
    const entries = [...(event.entries ?? []),
      { type: "custom" as const, customType: COMPLETION_ENTRY, data: { ...completion, postFailures: { ...completion.postFailures } } },
      { type: "custom_message" as const, customType: COMPLETION_ENTRY, content: text, display: true }];
    return canContinue ? { entries, continue: true } : { entries };
  }

  async function beforeSettle(event: AgentBeforeSettleEvent, nativeContext: ExtensionContext): Promise<BoundaryResult | undefined> {
    const ctx = snapshot(nativeContext);
    completion = { ...completion, status: completion.status === "blocked" ? "blocked" : "needs_check", binding: readBinding(ctx.cwd) };
    persistCompletion(); // needs_check (or the standing block) before fallible work
    // The unknown fence also blocks repair edits, so settling re-runs the
    // verifier on the latched targets; only a clean rerun clears them.
    if (completion.unknown && Object.keys(completion.postFailures).length) await recheckPost(ctx);
    const failures = Object.entries(completion.postFailures);
    if (failures.length) {
      return blockSettle(event, ctx, `Unresolved mandatory post-edit failures:\n${failures.map(([path, why]) => `${path}: ${why}`).join("\n")}`, completion.unknown);
    }
    const decision = await dispatch(pi, { schema_version: 1, harness: "pi", phase: "agent_before_settle", ...session(ctx),
      turn_id: `${ctx.session_id}:${completion.turn}`, generation: completion.turn,
      can_continue: event.context?.canContinue === true, last_assistant_message: lastAssistantText(event),
      // Pi has no host-reentrant Stop: a continuation this gate requested is a
      // fresh attempt, and reentry would short-circuit the mandatory checks.
      stop_hook_active: false }, ctx);
    if (decision.decision === "deny") {
      return blockSettle(event, ctx, decision.reason ?? "Trellis completion denied", decision.capability_status === "unknown");
    }
    // Accepted: finalized once here; the native batch already ran stamp-turn
    // only because it accepted. Settled notifications never change this.
    completion = { ...freshCompletion(readBinding(ctx.cwd)), status: "accepted", turn: completion.turn };
    persistCompletion();
    if (decision.decision === "warn") show(ctx, decision);
    return undefined;
  }

  pi.on("agent_before_settle", async (event, nativeContext) => {
    // A throw here is not a host gate: convert it to an explicit block.
    try { return await beforeSettle(event, nativeContext); }
    catch (error) {
      let ctx: HandlerContext | undefined;
      try { ctx = snapshot(nativeContext); } catch { ctx = undefined; }
      return blockSettle(event, ctx, `Trellis completion check failed; enforcement is unknown: ${error instanceof Error ? error.message : String(error)}`, true);
    }
  });

  pi.on("resources_discover", (event) => {
    const root = attachedRoot(event.cwd);
    return root ? { skillPaths: [resolve(root, ".agents/skills")], promptPaths: [resolve(root, ".agents/commands")] } : undefined;
  });

  async function toolCall(event: ToolCallEvent, context: ExtensionContext) {
    const ctx = snapshot(context), epoch = generation, policy = guardRules();
    const action = actionFor(pi, ctx.cwd, event.toolCallId, event.toolName, event.input as Record<string, unknown>);
    const blockedCompletion = completionGate(action.family === "file_mutation" || action.family === "shell" || ["Agent", "SubagentWorkflow", "steer_subagent"].includes(event.toolName));
    if (blockedCompletion) return { block: true, reason: blockedCompletion };
    // Pi permits extensions to replace built-ins by name. Their behavior is
    // not covered by the native file/shell guards, even with familiar inputs.
    if (["read", "edit", "write", "bash"].includes(event.toolName)) {
      const tools = pi.getAllTools().filter(tool => tool.name === event.toolName);
      if (tools.length !== 1 || tools[0].sourceInfo?.source !== "builtin") {
        return { block: true, reason: `Trellis refuses unmediated tool '${event.toolName}': builtin provenance is unavailable` };
      }
    }
    const root = attachedRoot(ctx.cwd);
    if ((action.family === "file_mutation" || action.family === "shell" || ["Agent", "SubagentWorkflow", "steer_subagent"].includes(event.toolName)) && (!root || !readPolicy(root))) {
      return { block: true, reason: !root ? runtimeUnavailable : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md" };
    }
    if (!root) return { block: true, reason: runtimeUnavailable };
    try {
      const script = resolve(root, ".trellis/runtime/core-rules/pi/hooks/dispatch.sh");
      if (!statSync(script).isFile()) throw new Error("not a regular dispatcher");
      accessSync(script, constants.X_OK);
    } catch { return { block: true, reason: "Trellis Pi dispatcher is missing or invalid in the attached immutable runtime" }; }
    const state = readState(ctx);
    const envelope: NormalizedAction = { schema_version: 1, harness: "pi", phase: "pre_action", native_event: "tool_call", ...session(ctx), action, result: null };
    let decision = localPreAction(pi, action, ctx.cwd, root, state, policy);
    if (decision.decision !== "deny" && action.tool_name === "bash" && mayCreatePr(action.input.command)) {
      const advisory = await dispatch(pi, envelope, ctx);
      decision = { ...advisory, reason: [decision.reason, advisory.reason].filter(Boolean).join("\n") };
    }
    show(ctx, decision);
    if (decision.decision === "deny") return { block: true, reason: decision.reason ?? "Blocked by Trellis" };
    if (epoch !== generation) return { block: true, reason: "Trellis turn changed during pre-action; retry the tool" };
    const advisory = advisoryContext(decision);
    callGenerations.set(event.input, epoch);
    pending.set(pendingKey(epoch, ctx, event.toolCallId), { action, input: event.input, cwd: ctx.cwd, binding: readBinding(ctx.cwd), state, capabilityOnly: isCapabilityOnly(decision), context: advisory ? `[Trellis pre-action advisory; capability: ${decision.capability_status}]\n${advisory}` : "" });
  }

  pi.on("tool_call", async (event, ctx) => {
    try { return await toolCall(event, ctx); }
    catch (error) { return { block: true, reason: `Trellis policy failed; refusing execution: ${error instanceof Error ? error.message : String(error)}` }; }
  });

  pi.on("tool_result", async (event: ToolResultEvent, nativeContext) => {
    const epoch = callGenerations.get(event.input) ?? generation;
    if (epoch !== generation) return;
    let ctx: HandlerContext | undefined, pre: ReturnType<typeof pending.get>;
    try {
    ctx = snapshot(nativeContext);
    const key = pendingKey(epoch, ctx, event.toolCallId), candidate = pending.get(key);
    // Pi carries the same parsed args object through pre/post; a late nested
    // result with a reused id must not consume a newer call's state.
    pre = candidate?.input === event.input ? candidate : undefined;
    if (pre) pending.delete(key);
    const action = pre?.action ?? actionFor(pi, ctx.cwd, event.toolCallId, event.toolName, event.input as Record<string, unknown>);
    const failed = resultFailed(event, action.family, guardRules());
    const envelope: NormalizedAction = {
      schema_version: 1, harness: "pi", phase: "post_action", native_event: "tool_result", ...session(ctx), action,
      result: { status: failed ? "failed" : "succeeded", is_error: failed, output: event.content },
    };
    if (pre && pre.binding === readBinding(ctx.cwd) && (action.family === "file_read" || action.family === "file_mutation")) {
      recordReadTargets(pre.state, action.targets, pre.cwd, failed);
    }
    // Native Pi output is a content-block array. The legacy truncation checker
    // deliberately ignores arrays, so Read/shell have no post work beyond the
    // captured in-process read update. Never fork just to return that no-op.
    const root = attachedRoot(ctx.cwd);
    const decision: Decision = !root ? deny(runtimeUnavailable)
      : action.family === "file_read" || action.family === "shell" ? { schema_version: 1, capability_status: "advisory", decision: "allow" }
      : action.family === "file_mutation" && !failed ? await localPostAction(pi, { ...envelope, in_process_read_tracking: true }, ctx, undefined, (paths, failure, unknown) => latchPost(ctx!, paths, failure, unknown))
      : action.family === "file_mutation" ? { schema_version: 1 as const, capability_status: "unsupported" as const, decision: "allow" as const, reason: "post_action/file_mutation: unsupported — checks skipped due to failed result" }
      : unhandledDecision("post_action", action.family);
    if (epoch !== generation) return;
    return deliverPostResult(pi, ctx, { ...event, isError: failed }, pre, decision, deliveredReasons);
    } catch (error) {
      if (epoch !== generation) return;
      const reason = `Trellis post-action evaluation failed; capability is unknown: ${error instanceof Error ? error.message : String(error)}`;
      try {
        if (ctx) return deliverPostResult(pi, ctx, { ...event, isError: true }, pre, deny(reason), deliveredReasons);
        nativeContext.ui.notify(reason, "warning");
      } catch { /* A broken notification API must not erase model-visible diagnostics. */ }
      const text = [pre?.context, `[Trellis post-action advisory; capability: unknown]\n${reason}`].filter(Boolean).join("\n\n");
      return { content: [...event.content, { type: "text" as const, text }] };
    }
  });

  async function userBash(event: UserBashEvent, context: ExtensionContext) {
    const ctx = snapshot(context), policy = guardRules();
    const blockedCompletion = completionGate(true);
    if (blockedCompletion) return { result: { output: blockedCompletion, exitCode: 1, cancelled: false, truncated: false } };
    const root = attachedRoot(event.cwd);
    if (!root || !readPolicy(root)) {
      return { result: { output: !root ? runtimeUnavailable : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md", exitCode: 1, cancelled: false, truncated: false } };
    }
    const action = actionFor(pi, event.cwd, `user-bash:${++userBashSequence}`, "bash", { command: event.command });
    const envelope: NormalizedAction = { schema_version: 1, harness: "pi", phase: "pre_action", native_event: "user_bash", ...session(ctx), cwd: event.cwd, action, result: null };
    let decision = localPreAction(pi, action, event.cwd, root, readState({ ...ctx, cwd: event.cwd }), policy);
    if (decision.decision !== "deny" && mayCreatePr(event.command)) {
      const advisory = await dispatch(pi, envelope, ctx, event.cwd);
      decision = { ...advisory, reason: [decision.reason, advisory.reason].filter(Boolean).join("\n") };
    }
    show(ctx, decision);
    if (decision.decision === "deny") {
      return { result: { output: decision.reason ?? "Blocked by Trellis", exitCode: 1, cancelled: false, truncated: false } };
    }
    if (!event.excludeFromContext) {
      const context = advisoryContext(decision);
      if (context) pi.sendMessage({ customType: "trellis-context", content: `[Trellis pre-action advisory; capability: ${decision.capability_status}]\n${context}`, display: false }, { deliverAs: "nextTurn" });
    }
  }

  pi.on("user_bash", async (event, ctx) => {
    try { return await userBash(event, ctx); }
    catch (error) { return { result: { output: `Trellis policy failed; refusing execution: ${error instanceof Error ? error.message : String(error)}`, exitCode: 1, cancelled: false, truncated: false } }; }
  });

  const lifecycle = (native_event: string, ctx: HandlerContext, extra: Record<string, unknown> = {}) =>
    dispatch(pi, { schema_version: 1, harness: "pi", phase: "lifecycle", native_event, ...session(ctx), ...extra }, ctx);

  // Pi emits input BEFORE /skill:name expansion, including queued RPC input.
  pi.on("input", (event, ctx) => {
    if (!event.text.startsWith("/skill:")) return;
    let reason: string | undefined;
    try {
      const name = event.text.split(" ", 1)[0].slice(1);
      const root = attachedRoot(ctx.cwd);
      if (!root) reason = runtimeUnavailable;
      else {
        const skills = pi.getCommands().filter(command => command.source === "skill" && command.name === name);
        const paths = new Set(skills.map(command => realpathSync.native(command.sourceInfo.path)));
        reason = paths.size !== 1 ? `Skill '${name}' is unavailable or ambiguous; refusing pre-load before body injection` : skillManifestReason([...paths][0]);
      }
    } catch { reason = "Skill resolution is unreadable; refusing pre-load before body injection"; }
    if (reason) {
      ctx.ui.notify(reason, "error");
      pi.sendMessage({ customType: "trellis-context", content: reason, display: true });
      return { action: "handled" as const };
    }
  });

  pi.on("before_agent_start", (event, ctx) => {
    if (event.messageType !== "user") return;
    const cwd = ctx.cwd;
    // A new prompt needs a fresh completion check; a standing block survives.
    completion = { ...completion, status: completion.status === "blocked" ? "blocked" : "needs_check",
      continuations: 0, noProgress: 0, turn: completion.turn + 1 };
    persistCompletion();
    resetReads();
    const root = attachedRoot(cwd);
    const policy = root ? readPolicy(root) : undefined;
    const policyBlock = policy ? `<trellis_parent_policy>\n${policy}\n</trellis_parent_policy>` : undefined;
    const systemPrompt = policyBlock && !event.systemPrompt.includes(policyBlock)
      ? `${event.systemPrompt}\n\n${policyBlock}`
      : event.systemPrompt;
    let identity: string | undefined, identityError: string | undefined;
    try { identity = lifecycleIdentity(snapshot(ctx)); }
    catch { identityError = "Trellis session identity unavailable; queued lifecycle context withheld."; }
    const context = pendingContext?.identity === identity ? pendingContext?.text : undefined;
    pendingContext = undefined;
    const policyContext = !root ? runtimeUnavailable : policy
      ? undefined
      : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md; shell, file mutation, Agent, SubagentWorkflow, and steer_subagent tools are blocked.";
    return {
      systemPrompt,
      ...((context || policyContext || identityError) ? { message: { customType: "trellis-context", content: [policyContext, identityError, context].filter(Boolean).join("\n\n"), display: false } } : {}),
    };
  });

  pi.on("session_start", async (event, context) => {
    const ctx = snapshot(context);
    resetSession();
    restoreCompletion(context, ctx.cwd);
    const epoch = lifecycleEpoch, identity = lifecycleIdentity(ctx);
    const decision = await lifecycle("session_start", ctx, { reason: event.reason });
    if (!currentLifecycle(ctx, identity, epoch)) return;
    queueContext(identity, decision);
    show(ctx, decision);
  });
  pi.on("session_before_compact", async (event, nativeContext) => {
    const ctx = snapshot(nativeContext);
    const epoch = lifecycleEpoch, identity = lifecycleIdentity(ctx);
    const decision = await lifecycle("session_before_compact", ctx, { reason: event.reason, will_retry: event.willRetry });
    if (!currentLifecycle(ctx, identity, epoch)) return;
    show(ctx, { ...decision, decision: decision.decision === "deny" ? "warn" : decision.decision });
    const context = advisoryContext(decision);
    if (context) pi.sendMessage({ customType: "trellis-context", content: context, display: false }, { deliverAs: "nextTurn" });
  });
  pi.on("session_compact", async (event, context) => {
    const ctx = snapshot(context);
    const epoch = lifecycleEpoch, identity = lifecycleIdentity(ctx);
    const decision = await lifecycle("session_compact", ctx, { reason: event.reason, will_retry: event.willRetry });
    if (!currentLifecycle(ctx, identity, epoch)) return;
    queueContext(identity, decision);
    show(ctx, decision);
  });
  pi.on("agent_settled", async (_event, nativeContext) => {
    const ctx = snapshot(nativeContext);
    resetReads();
    const epoch = lifecycleEpoch, identity = lifecycleIdentity(ctx);
    const decision = await lifecycle("agent_settled", ctx);
    if (!currentLifecycle(ctx, identity, epoch)) return;
    show(ctx, decision);
    const context = advisoryContext(decision);
    if (context) pi.sendMessage({ customType: "trellis-context", content: context, display: false }, { deliverAs: "nextTurn" });
  });
  pi.on("session_shutdown", (event, context) => {
    const ctx = snapshot(context);
    const identity = lifecycleIdentity(ctx), key = identity ?? JSON.stringify([ctx.session_id, ctx.cwd]);
    if (shutdownTask?.identity === key) return shutdownTask.task;
    resetSession();
    const epoch = lifecycleEpoch;
    const task = (async () => {
      const decision = await lifecycle("session_shutdown", ctx, { reason: event.reason });
      if (currentLifecycle(ctx, identity, epoch)) show(ctx, decision);
    })();
    shutdownTask = { identity: key, task };
    return task;
  });
}
