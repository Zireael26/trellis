import { accessSync, chmodSync, constants, existsSync, lstatSync, mkdtempSync, readFileSync, realpathSync, rmdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, relative, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import type {
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

export function loadGuardRules(directory = fileURLToPath(new URL("../../hooks/rules/", import.meta.url))) {
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
    result = await pi.exec(script, ["--event-file", eventFile], { cwd: root, timeout: 300_000, signal: ctx.signal });
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
  const lines = result.stdout.trim().split(/\r?\n/).filter(Boolean);
  try {
    const parsed: unknown = JSON.parse(lines.at(-1) ?? "");
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
  return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: result.stderr.trim() || `Trellis Pi dispatcher failed with exit ${result.code}` };
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

export default function trellisPiExtension(pi: ExtensionAPI) {
  // Keep initialization failures in the execution gate, not the factory. Pi
  // >=1.4 blocks thrown handlers; explicit block returns also protect older hosts.
  let rules: GuardRules;
  let ruleError: unknown;
  try { rules = loadGuardRules(); } catch (error) { ruleError = error; }
  function guardRules(): GuardRules {
    if (ruleError) throw new Error("Trellis guard rules are unavailable; refusing execution", { cause: ruleError });
    return rules;
  }
  const pending = new Map<string, { action: NormalizedAction["action"]; input: object; cwd: string; context: string; capabilityOnly: boolean; state: ReadState }>();
  const callGenerations = new WeakMap<object, number>();
  const readStates = new Map<string, ReadState>();
  let generation = 0;
  let userBashSequence = 0;

  function readState(ctx: HandlerContext): ReadState {
    const key = JSON.stringify([attachedRoot(ctx.cwd), ctx.session_id]);
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
  let pendingContext: string | undefined;
  const deliveredReasons = new Set<string>();

  function advisoryContext(decision: Decision): string {
    let reason = decision.reason;
    if (reason && decision.decision === "allow" && (decision.capability_status === "unsupported" || decision.capability_status === "advisory")) {
      const key = JSON.stringify([decision.capability_status, reason]);
      if (deliveredReasons.has(key)) reason = undefined;
      else deliveredReasons.add(key);
    }
    return [decision.context, reason].filter(Boolean).join("\n\n");
  }

  function resetSession() {
    pending.clear();
    resetReads();
    pendingContext = undefined;
    deliveredReasons.clear();
    userBashSequence = 0;
  }

  pi.on("resources_discover", (event) => {
    const root = attachedRoot(event.cwd);
    return root ? { skillPaths: [resolve(root, ".agents/skills")], promptPaths: [resolve(root, ".agents/commands")] } : undefined;
  });

  async function toolCall(event: ToolCallEvent, context: ExtensionContext) {
    const ctx = snapshot(context), epoch = generation, policy = guardRules();
    const action = actionFor(pi, ctx.cwd, event.toolCallId, event.toolName, event.input as Record<string, unknown>);
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
    pending.set(pendingKey(epoch, ctx, event.toolCallId), { action, input: event.input, cwd: ctx.cwd, state, capabilityOnly: isCapabilityOnly(decision), context: advisory ? `[Trellis pre-action advisory; capability: ${decision.capability_status}]\n${advisory}` : "" });
  }

  pi.on("tool_call", async (event, ctx) => {
    try { return await toolCall(event, ctx); }
    catch (error) { return { block: true, reason: `Trellis policy failed; refusing execution: ${error instanceof Error ? error.message : String(error)}` }; }
  });

  pi.on("tool_result", async (event: ToolResultEvent, nativeContext) => {
    const ctx = snapshot(nativeContext), epoch = callGenerations.get(event.input) ?? generation;
    if (epoch !== generation) return;
    const key = pendingKey(epoch, ctx, event.toolCallId), candidate = pending.get(key);
    // Pi carries the same parsed args object through pre/post; a late nested
    // result with a reused id must not consume a newer call's state.
    const pre = candidate?.input === event.input ? candidate : undefined;
    if (pre) pending.delete(key);
    const action = pre?.action ?? actionFor(pi, ctx.cwd, event.toolCallId, event.toolName, event.input as Record<string, unknown>);
    const failed = resultFailed(event, action.family, guardRules());
    const envelope: NormalizedAction = {
      schema_version: 1, harness: "pi", phase: "post_action", native_event: "tool_result", ...session(ctx), action,
      result: { status: failed ? "failed" : "succeeded", is_error: failed, output: event.content },
    };
    if (pre && (action.family === "file_read" || action.family === "file_mutation")) {
      recordReadTargets(pre.state, action.targets, pre.cwd, failed);
    }
    const handled = action.family === "file_read" || action.family === "shell" || (action.family === "file_mutation" && !failed);
    const decision = handled ? await dispatch(pi, { ...envelope, in_process_read_tracking: true }, ctx)
      : action.family === "file_mutation" ? { schema_version: 1 as const, capability_status: "unsupported" as const, decision: "allow" as const, reason: "post_action/file_mutation: unsupported — checks skipped due to failed result" }
      : unhandledDecision("post_action", action.family);
    if (epoch !== generation) return;
    show(ctx, { ...decision, decision: decision.decision === "deny" ? "warn" : decision.decision });
    const postContext = advisoryContext(decision);
    const postAdvisory = postContext ? `[Trellis post-action advisory; capability: ${decision.capability_status}]\n${postContext}` : "";
    const successfulRead = action.family === "file_read" && !failed;
    const separatePre = successfulRead && pre?.capabilityOnly;
    const separatePost = successfulRead && isCapabilityOnly(decision);
    const capabilityContext = [separatePre ? pre?.context : undefined, separatePost ? postAdvisory : undefined].filter(Boolean).join("\n\n");
    if (capabilityContext) {
      // Pi flushes context-only messages at turn_end after tool results, without steering or another turn.
      pi.sendMessage({ customType: "trellis-context", content: capabilityContext, display: false }, { triggerTurn: false });
    }
    const context = [separatePre ? undefined : pre?.context, separatePost ? undefined : postAdvisory].filter(Boolean).join("\n\n");
    if (context) return { content: [...event.content, { type: "text" as const, text: context }] };
  });

  async function userBash(event: UserBashEvent, context: ExtensionContext) {
    const ctx = snapshot(context), policy = guardRules();
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
    resetReads();
    const root = attachedRoot(cwd);
    const policy = root ? readPolicy(root) : undefined;
    const policyBlock = policy ? `<trellis_parent_policy>\n${policy}\n</trellis_parent_policy>` : undefined;
    const systemPrompt = policyBlock && !event.systemPrompt.includes(policyBlock)
      ? `${event.systemPrompt}\n\n${policyBlock}`
      : event.systemPrompt;
    const context = pendingContext;
    pendingContext = undefined;
    const policyContext = !root ? runtimeUnavailable : policy
      ? undefined
      : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md; shell, file mutation, Agent, SubagentWorkflow, and steer_subagent tools are blocked.";
    return {
      systemPrompt,
      ...((context || policyContext) ? { message: { customType: "trellis-context", content: [policyContext, context].filter(Boolean).join("\n\n"), display: false } } : {}),
    };
  });

  pi.on("session_start", async (event, context) => {
    const ctx = snapshot(context);
    resetSession();
    const decision = await lifecycle("session_start", ctx, { reason: event.reason });
    pendingContext = [pendingContext, advisoryContext(decision)].filter(Boolean).join("\n\n");
    show(ctx, decision);
  });
  pi.on("session_before_compact", async (event, nativeContext) => {
    const ctx = snapshot(nativeContext);
    const decision = await lifecycle("session_before_compact", ctx, { reason: event.reason, will_retry: event.willRetry });
    show(ctx, { ...decision, decision: decision.decision === "deny" ? "warn" : decision.decision });
    const context = advisoryContext(decision);
    if (context) pi.sendMessage({ customType: "trellis-context", content: context, display: false }, { deliverAs: "nextTurn" });
  });
  pi.on("session_compact", async (event, context) => {
    const ctx = snapshot(context);
    const decision = await lifecycle("session_compact", ctx, { reason: event.reason, will_retry: event.willRetry });
    pendingContext = [pendingContext, advisoryContext(decision)].filter(Boolean).join("\n\n");
    show(ctx, decision);
  });
  pi.on("agent_settled", async (_event, nativeContext) => {
    const ctx = snapshot(nativeContext);
    resetReads();
    const decision = await lifecycle("agent_settled", ctx);
    show(ctx, decision);
    const context = advisoryContext(decision);
    if (context) pi.sendMessage({ customType: "trellis-context", content: context, display: false }, { deliverAs: "nextTurn" });
  });
  pi.on("session_shutdown", async (event, context) => {
    const ctx = snapshot(context);
    resetSession();
    const decision = await lifecycle("session_shutdown", ctx, { reason: event.reason });
    show(ctx, decision);
  });
}
