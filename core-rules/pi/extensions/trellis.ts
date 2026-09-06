import { existsSync, lstatSync, readFileSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";
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

function targetPath(cwd: string, value: unknown): string | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  return relative(cwd, resolve(cwd, value)) || ".";
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
  const path = targetPath(cwd, input.path ?? input.file_path ?? input.filePath);
  let targets: Target[] = [];
  let target_coverage: "complete" | "partial" | "none" = "none";
  if (path && family === "file_read") {
    targets = [{ operation: "read", path }];
    target_coverage = "complete";
  } else if (path && family === "file_mutation") {
    const operation = name === "write" && !existsSync(resolve(cwd, path)) ? "create" : "update";
    targets = [{ operation, path }];
    target_coverage = "complete";
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

async function dispatch(pi: ExtensionAPI, event: NormalizedAction | Record<string, unknown>, ctx: ExtensionContext, cwd = ctx.cwd): Promise<Decision> {
  const root = attachedRoot(cwd);
  if (!root) return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: runtimeUnavailable };
  const script = resolve(root, ".trellis/runtime/core-rules/pi/hooks/dispatch.sh");
  if (!existsSync(script)) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: "Trellis Pi dispatcher is missing from the attached immutable runtime" };
  }
  const encoded = Buffer.from(JSON.stringify(event), "utf8").toString("base64");
  let result;
  try {
    result = await pi.exec(script, ["--base64", encoded], { cwd: root ?? cwd, timeout: 300_000, signal: ctx.signal });
  } catch (error) {
    return { schema_version: 1, capability_status: "unknown", decision: "deny", reason: `Trellis Pi dispatcher could not run: ${error instanceof Error ? error.message : String(error)}` };
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

function show(ctx: ExtensionContext, decision: Decision) {
  if (decision.reason && decision.decision !== "allow") {
    ctx.ui.notify(decision.reason, decision.decision === "deny" ? "error" : "warning");
  }
}

export default function trellisPiExtension(pi: ExtensionAPI) {
  const pending = new Map<string, { action: NormalizedAction["action"]; context: string }>();
  let userBashSequence = 0;
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
    if ((action.family === "file_mutation" || action.family === "shell" || event.toolName === "Agent" || event.toolName === "SubagentWorkflow") && (!root || !readPolicy(root))) {
      return { block: true, reason: !root ? runtimeUnavailable : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md" };
    }
    const envelope: NormalizedAction = { schema_version: 1, harness: "pi", phase: "pre_action", native_event: "tool_call", ...session(ctx), action, result: null };
    const decision = await dispatch(pi, envelope, ctx);
    show(ctx, decision);
    if (decision.decision === "deny") return { block: true, reason: decision.reason ?? "Blocked by Trellis" };
    const context = advisoryContext(decision);
    pending.set(event.toolCallId, { action, context: context ? `[Trellis pre-action advisory; capability: ${decision.capability_status}]\n${context}` : "" });
  });

  pi.on("tool_result", async (event: ToolResultEvent, ctx) => {
    const pre = pending.get(event.toolCallId);
    const action = pre?.action ?? actionFor(pi, ctx.cwd, event.toolCallId, event.toolName, event.input as Record<string, unknown>);
    pending.delete(event.toolCallId);
    const envelope: NormalizedAction = {
      schema_version: 1, harness: "pi", phase: "post_action", native_event: "tool_result", ...session(ctx), action,
      result: { status: event.isError ? "failed" : "succeeded", is_error: event.isError, output: event.content },
    };
    const decision = await dispatch(pi, envelope, ctx);
    show(ctx, { ...decision, decision: decision.decision === "deny" ? "warn" : decision.decision });
    const postContext = advisoryContext(decision);
    const context = [pre?.context, postContext ? `[Trellis post-action advisory; capability: ${decision.capability_status}]\n${postContext}` : undefined].filter(Boolean).join("\n\n");
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

  pi.on("before_agent_start", (event, ctx) => {
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
      : "Trellis parent policy is missing or unreadable at .agents/rules/trellis.md; shell, file mutation, Agent, and SubagentWorkflow tools are blocked.";
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
