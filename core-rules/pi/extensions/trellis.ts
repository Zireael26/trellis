import { accessSync, chmodSync, constants, existsSync, lstatSync, mkdtempSync, readFileSync, realpathSync, rmdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, relative, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
  ToolCallEvent,
  ToolResultEvent,
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
function rereadBudget(root: string): number {
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
  return Math.min(level, ceiling) >= 4 ? 1 : 2;
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

function localPreAction(pi: ExtensionAPI, action: NormalizedAction["action"], cwd: string, root: string, state: ReadState): Decision | undefined {
  if (action.tool_name === "powershell") return deny("Trellis PowerShell destructive protection is unavailable; refusing pre-action execution");
  if (action.family === "mcp" || action.family === "local_tool" || action.family === "unknown") {
    // Child guard loading is a launcher/roster contract, not parent argument parsing.
    if (action.tool_name === "Agent" || action.tool_name === "SubagentWorkflow") return undefined;
    if (action.family === "local_tool" && isSubagentControl(pi, action.tool_name)) return undefined;
    const builtin = ["grep", "find", "ls"].includes(action.tool_name)
      && pi.getAllTools().some(tool => tool.name === action.tool_name && tool.sourceInfo.source === "builtin");
    if (!builtin) return deny(`Trellis refuses unmediated ${action.family} tool '${action.tool_name}': shell/mutation protection is unavailable`);
  }
  if (action.family !== "file_read" && action.family !== "file_mutation") return undefined;
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
    const budget = rereadBudget(root), count = state.warns.get(path) ?? 0;
    if (count >= budget) return { schema_version: 1, capability_status: "enforced", decision: "deny", reason: `reread-guard: BLOCKED edit of ${path} — it was not Read this turn and the re-read warn budget is exhausted. Read it first.` };
    state.warns.set(path, count + 1);
    return { schema_version: 1, capability_status: "enforced", decision: "warn", reason: `reread-guard: about to edit ${path} not Read this turn (warn ${count + 1}/${budget}). Read it first. Repeated FAILED stale edits will BLOCK.` };
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

function session(ctx: ExtensionContext) {
  return {
    cwd: ctx.cwd,
    session_id: ctx.sessionManager.getSessionId(),
    ...(ctx.sessionManager.getSessionFile() ? { session_file: ctx.sessionManager.getSessionFile() } : {}),
  };
}

const MAX_DISPATCH_EVENT_BYTES = 64 * 1024 * 1024;

function missingPath(error: unknown): boolean {
  return !!error && typeof error === "object" && "code" in error && error.code === "ENOENT";
}

async function dispatch(pi: ExtensionAPI, event: NormalizedAction | Record<string, unknown>, ctx: ExtensionContext, cwd = ctx.cwd): Promise<Decision> {
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
function resultFailed(event: ToolResultEvent, family: NormalizedAction["action"]["family"]): boolean {
  if (event.isError) return true;
  if (family !== "file_mutation" && family !== "file_read") return false;
  const details: unknown = event.details;
  if (details && typeof details === "object") {
    if (("is_error" in details && details.is_error === true) || ("isError" in details && details.isError === true)) return true;
    if (("error" in details && details.error != null && details.error !== "") || ("tool_use_error" in details && details.tool_use_error != null && details.tool_use_error !== "")) return true;
    return false; // Code echoed inside an object may legitimately say Error/ENOENT.
  }
  if (family === "file_mutation") {
    const text = event.content.filter(block => block.type === "text").map(block => block.text).join("\n");
    return /does not match|String to replace|no changes|Error:|tool_use_error|ENOENT|not found|has not been read|^Error|^No files were modified\./i.test(text);
  }
  return false; // Successful reads contain arbitrary file text, never failure evidence.
}

function isCapabilityOnly(decision: Decision): boolean {
  return decision.decision === "allow"
    && (decision.capability_status === "unsupported" || decision.capability_status === "advisory")
    && !decision.context;
}

function show(ctx: ExtensionContext, decision: Decision) {
  if (decision.reason && decision.decision !== "allow") {
    ctx.ui.notify(decision.reason, decision.decision === "deny" ? "error" : "warning");
  }
}

export default function trellisPiExtension(pi: ExtensionAPI) {
  const pending = new Map<string, { action: NormalizedAction["action"]; context: string; capabilityOnly: boolean; state: ReadState; generation: number }>();
  const readStates = new Map<string, ReadState>();
  let generation = 0;
  let userBashSequence = 0;

  function readState(ctx: ExtensionContext): ReadState {
    const key = JSON.stringify([attachedRoot(ctx.cwd), ctx.sessionManager.getSessionId()]);
    let state = readStates.get(key);
    if (!state) { state = { known: new Set(), warns: new Map() }; readStates.set(key, state); }
    return state;
  }

  function resetReads() {
    readStates.clear();
    generation++;
  }
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

  pi.on("tool_call", async (event: ToolCallEvent, ctx) => {
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
    const decision = localPreAction(pi, action, ctx.cwd, root, state) ?? await dispatch(pi, envelope, ctx);
    show(ctx, decision);
    if (decision.decision === "deny") return { block: true, reason: decision.reason ?? "Blocked by Trellis" };
    const context = advisoryContext(decision);
    pending.set(event.toolCallId, { action, state, generation, capabilityOnly: isCapabilityOnly(decision), context: context ? `[Trellis pre-action advisory; capability: ${decision.capability_status}]\n${context}` : "" });
  });

  pi.on("tool_result", async (event: ToolResultEvent, ctx) => {
    const pre = pending.get(event.toolCallId);
    const action = pre?.action ?? actionFor(pi, ctx.cwd, event.toolCallId, event.toolName, event.input as Record<string, unknown>);
    pending.delete(event.toolCallId);
    const failed = resultFailed(event, action.family);
    const envelope: NormalizedAction = {
      schema_version: 1, harness: "pi", phase: "post_action", native_event: "tool_result", ...session(ctx), action,
      result: { status: failed ? "failed" : "succeeded", is_error: failed, output: event.content },
    };
    if (pre && pre.generation === generation && !failed && (action.family === "file_read" || action.family === "file_mutation")) {
      for (const target of action.targets) if (!/[\0\t\r\n]/.test(target.path)) pre.state.known.add(resolve(ctx.cwd, target.path));
    }
    const decision = await dispatch(pi, { ...envelope, in_process_read_tracking: true }, ctx);
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

  pi.on("user_bash", async (event, ctx) => {
    const root = attachedRoot(event.cwd);
    if (!root || !readPolicy(root)) {
      return { result: { output: !root ? runtimeUnavailable : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md", exitCode: 1, cancelled: false, truncated: false } };
    }
    const action = actionFor(pi, event.cwd, `user-bash:${++userBashSequence}`, "bash", { command: event.command });
    const envelope: NormalizedAction = { schema_version: 1, harness: "pi", phase: "pre_action", native_event: "user_bash", ...session(ctx), cwd: event.cwd, action, result: null };
    const decision = await dispatch(pi, envelope, ctx, event.cwd);
    show(ctx, decision);
    if (decision.decision === "deny") {
      return { result: { output: decision.reason ?? "Blocked by Trellis", exitCode: 1, cancelled: false, truncated: false } };
    }
    if (!event.excludeFromContext) {
      const context = advisoryContext(decision);
      if (context) pi.sendMessage({ customType: "trellis-context", content: `[Trellis pre-action advisory; capability: ${decision.capability_status}]\n${context}`, display: false }, { deliverAs: "nextTurn" });
    }
  });

  const lifecycle = (native_event: string, ctx: ExtensionContext, extra: Record<string, unknown> = {}) =>
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
    resetReads();
    const root = attachedRoot(ctx.cwd);
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

  pi.on("session_start", async (event, ctx) => {
    resetSession();
    const decision = await lifecycle("session_start", ctx, { reason: event.reason });
    pendingContext = [pendingContext, advisoryContext(decision)].filter(Boolean).join("\n\n");
    show(ctx, decision);
  });
  pi.on("session_before_compact", async (event, ctx) => {
    const decision = await lifecycle("session_before_compact", ctx, { reason: event.reason, will_retry: event.willRetry });
    show(ctx, { ...decision, decision: decision.decision === "deny" ? "warn" : decision.decision });
    const context = advisoryContext(decision);
    if (context) pi.sendMessage({ customType: "trellis-context", content: context, display: false }, { deliverAs: "nextTurn" });
  });
  pi.on("session_compact", async (event, ctx) => {
    const decision = await lifecycle("session_compact", ctx, { reason: event.reason, will_retry: event.willRetry });
    pendingContext = [pendingContext, advisoryContext(decision)].filter(Boolean).join("\n\n");
    show(ctx, decision);
  });
  pi.on("agent_settled", async (_event, ctx) => {
    resetReads();
    const decision = await lifecycle("agent_settled", ctx);
    show(ctx, decision);
    const context = advisoryContext(decision);
    if (context) pi.sendMessage({ customType: "trellis-context", content: context, display: false }, { deliverAs: "nextTurn" });
  });
  pi.on("session_shutdown", async (event, ctx) => {
    resetSession();
    const decision = await lifecycle("session_shutdown", ctx, { reason: event.reason });
    show(ctx, decision);
  });
}
