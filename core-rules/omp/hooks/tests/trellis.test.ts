/**
 * trellis.test.ts — focused unit tests for the OMP Trellis adapter
 * (core-rules/omp/hooks/pre/trellis.ts).
 *
 * Covers, per the inheritance plan: envelope translation, destructive denial,
 * safe pass-through, output parsing, fail-closed tool_call behavior,
 * child-context injection, context-log save on compaction/shutdown, stop-hook
 * continuation, and unsupported/missing-setup failure.
 *
 * The adapter is dependency-light (Node builtins only, no @oh-my-pi imports),
 * so these tests run under plain Node type stripping:
 *   node --test core-rules/omp/hooks/tests/trellis.test.ts
 * Canonical scripts are never executed — a fake spawn returns canned stdout per
 * script name, so behavior is deterministic and offline.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createHash } from "node:crypto";

import trellisExtension, {
	buildTranscriptJsonl,
	canonicalToolName,
	createTrellisAdapter,
	editPatchPaths,
	normalizeToolInput,
	parseHookOutput,
	policyMarker,
	resolveTrellisRoot,
	resolveTrellisRuntime,
	runCanonicalHook,
	slashCommandName,
	systemPromptHasPolicy,
	toolResponseText,
	trellisPresetPolicies,
	type OmpApi,
	type OmpBeforeAgentStartEvent,
	type OmpContext,
	type OmpInputEvent,
	type OmpSessionStopEvent,
	type OmpToolCallEvent,
	type OmpToolResultEvent,
	type SpawnFn,
	type TrellisAdapter,
} from "../pre/trellis.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

interface SpawnCall {
	script: string;
	args: string[];
	options: {
		input: string;
		env: Record<string, string>;
	};
	transcript?: string;
}

interface PayloadFixtureEntry {
	path: string;
	content?: string;
	mode?: number;
	symlinkTarget?: string;
}

interface ReleaseFixture {
	releaseDir: string;
	payloadRoot: string;
	hooksDir: string;
}

function fixtureGitBlobOid(content: Buffer): string {
	return createHash("sha1").update(`blob ${content.length}\0`).update(content).digest("hex");
}

function fixtureMode(stat: fs.Stats): "100644" | "100755" | "120000" {
	if (stat.isSymbolicLink()) return "120000";
	if (!stat.isFile()) throw new Error(`unexpected payload fixture entry mode: ${stat.mode}`);
	return (stat.mode & 0o111) === 0 ? "100644" : "100755";
}

function fixtureTree(payloadRoot: string): Array<{ path: string; mode: "100644" | "100755" | "120000"; oid: string }> {
	const tree: Array<{ path: string; mode: "100644" | "100755" | "120000"; oid: string }> = [];
	function visit(directory: string): void {
		for (const name of fs.readdirSync(directory).sort()) {
			const fullPath = path.join(directory, name);
			const stat = fs.lstatSync(fullPath);
			if (stat.isDirectory()) {
				visit(fullPath);
				continue;
			}
			const relativePath = path.relative(payloadRoot, fullPath).split(path.sep).join("/");
			const content = stat.isSymbolicLink() ? Buffer.from(fs.readlinkSync(fullPath)) : fs.readFileSync(fullPath);
			tree.push({ path: relativePath, mode: fixtureMode(stat), oid: fixtureGitBlobOid(content) });
		}
	}
	visit(payloadRoot);
	return tree;
}

function setFixtureWritable(root: string, writable: boolean): void {
	const stat = fs.lstatSync(root);
	if (stat.isSymbolicLink()) return;
	if (stat.isDirectory()) {
		fs.chmodSync(root, writable ? (stat.mode & 0o777) | 0o200 : (stat.mode & 0o777) & ~0o222);
		for (const name of fs.readdirSync(root)) {
			setFixtureWritable(path.join(root, name), writable);
		}
		return;
	}
	fs.chmodSync(root, writable ? (stat.mode & 0o777) | 0o200 : (stat.mode & 0o777) & ~0o222);
}

function sealRelease(releaseDir: string): void {
	setFixtureWritable(releaseDir, false);
}

function makeReleaseWritable(releaseDir: string): void {
	setFixtureWritable(releaseDir, true);
}

function writeFixtureReleaseRecord(payloadRoot: string): void {
	const releaseDir = path.dirname(payloadRoot);
	fs.writeFileSync(
		path.join(releaseDir, "release.json"),
		JSON.stringify({
			schema_version: 1,
			version: "1.0.0",
			tag: "v1.0.0",
			commit: "0".repeat(40),
			remote: "https://example.test/trellis.git",
			tree: fixtureTree(payloadRoot),
		}),
	);
}

function rewriteFixtureReleaseRecord(payloadRoot: string, update: (record: Record<string, unknown>) => void): void {
	const releaseDir = path.dirname(payloadRoot);
	makeReleaseWritable(releaseDir);
	const releaseJson = path.join(releaseDir, "release.json");
	const record = JSON.parse(fs.readFileSync(releaseJson, "utf8")) as Record<string, unknown>;
	update(record);
	fs.writeFileSync(releaseJson, JSON.stringify(record));
	sealRelease(releaseDir);
}

function makeReleaseFixture(entries: PayloadFixtureEntry[]): ReleaseFixture {
	const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-release-")));
	const releaseDir = path.join(root, "releases", "1.0.0");
	const payloadRoot = path.join(releaseDir, "payload");
	for (const entry of entries) {
		const fullPath = path.join(payloadRoot, entry.path);
		fs.mkdirSync(path.dirname(fullPath), { recursive: true });
		if (entry.symlinkTarget !== undefined) {
			fs.symlinkSync(entry.symlinkTarget, fullPath);
		} else {
			fs.writeFileSync(fullPath, entry.content ?? "", { mode: entry.mode ?? 0o644 });
		}
	}
	writeFixtureReleaseRecord(payloadRoot);
	sealRelease(releaseDir);
	return { releaseDir, payloadRoot, hooksDir: path.join(payloadRoot, "core-rules", "hooks") };
}

/** Temp immutable payload with the given canonical script names. */
function makeHooksDir(scripts: string[], extraEntries: PayloadFixtureEntry[] = []): string {
	return makeReleaseFixture([
		{ path: "core-rules/omp/hooks/pre/trellis.ts", content: "// installed OMP adapter\n" },
		{ path: "core-rules/hooks/.keep", content: "" },
		...scripts.map((script) => ({ path: `core-rules/hooks/${script}`, content: "" })),
		...extraEntries,
	]).hooksDir;
}

/** Temp project dir with an optional CLAUDE.md. */
function makeProjectDir(claudeMd: string): string {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-project-"));
	fs.writeFileSync(path.join(dir, "CLAUDE.md"), claudeMd, "utf8");
	return dir;
}

/** Project carrying the managed OMP adapter leaf, before runtime adoption. */
function makeOmpSurfaceProject(): string {
	const projectDir = makeProjectDir(PROJECT_CLAUDE_MD);
	const adapterLeaf = path.join(projectDir, ".omp", "hooks", "pre", "trellis.ts");
	fs.mkdirSync(path.dirname(adapterLeaf), { recursive: true });
	fs.symlinkSync("../../../.trellis/runtime/core-rules/omp/hooks/pre/trellis.ts", adapterLeaf);
	fs.symlinkSync("../CLAUDE.md", path.join(projectDir, ".omp", "AGENTS.md"));
	return projectDir;
}

/** Attach an OMP surface to an installed immutable payload. */
function makeAttachedOmpProject(payloadRoot: string): string {
	const projectDir = makeOmpSurfaceProject();
	fs.mkdirSync(path.join(projectDir, ".trellis"), { recursive: true });
	fs.symlinkSync(payloadRoot, path.join(projectDir, ".trellis", "runtime"), "dir");
	return projectDir;
}

function makeExtensionApi(): {
	api: OmpApi;
	handlers: Map<string, (event: unknown, ctx: OmpContext) => unknown>;
	labels: string[];
	errors: string[];
} {
	const handlers = new Map<string, (event: unknown, ctx: OmpContext) => unknown>();
	const labels: string[] = [];
	const errors: string[] = [];
	return {
		api: {
			on(event, handler): void {
				handlers.set(event, handler);
			},
			setLabel(label): void {
				labels.push(label);
			},
			logger: {
				warn(..._args: unknown[]): void {},
				error(...args: unknown[]): void {
					errors.push(args.map(String).join(" "));
				},
			},
		},
		handlers,
		labels,
		errors,
	};
}

/** Fake spawn returning canned stdout per script; records calls for assertions. */
function makeSpawn(
	responses: Record<string, { stdout?: string; stderr?: string; status?: number }>,
): { spawn: SpawnFn; calls: SpawnCall[] } {
	const calls: SpawnCall[] = [];
	const spawn: SpawnFn = (_command, args, options) => {
		const script = path.basename(args[0] ?? "");
		const response = responses[script] ?? {};
		const env = (options.env ?? {}) as Record<string, string>;
		const transcriptPath = env.CLAUDE_TRANSCRIPT_PATH;
		calls.push({
			script,
			args: [...args],
			options: {
				input: options.input ?? "",
				env,
			},
			transcript:
				transcriptPath && fs.existsSync(transcriptPath)
					? fs.readFileSync(transcriptPath, "utf8")
					: undefined,
		});
		return {
			pid: 1,
			output: [],
			stdout: response.stdout ?? "",
			stderr: response.stderr ?? "",
			status: response.status ?? 0,
			signal: null,
			error: undefined,
		};
	};
	return { spawn, calls };
}

const PROJECT_CLAUDE_MD = `# Celeste project policy
First overlay line.
@/opt/trellis/core-rules/CLAUDE.md
Second overlay line.`;

const PROJECT_POLICY_MARKER = "# Celeste project policy";

function makeCtx(overrides: Partial<OmpContext> = {}): OmpContext {
	return {
		cwd: makeProjectDir(PROJECT_CLAUDE_MD),
		sessionManager: { getSessionId: () => "sess-main" },
		getSystemPrompt: () => ["system prompt without policy marker"],
		...overrides,
	};
}

function makeAdapter(
	options: { spawn?: SpawnFn; hooksDir?: string; tmpDir?: string; trellisRoot?: string } = {},
): { adapter: TrellisAdapter; spawn: SpawnFn; calls: SpawnCall[] } {
	const hooksDir = options.hooksDir ?? makeHooksDir(ALL_CANONICAL_SCRIPTS);
	const trellisRoot = options.trellisRoot ?? path.dirname(path.dirname(hooksDir));
	const spawnSetup = makeSpawn({});
	const spawn = options.spawn ?? spawnSetup.spawn;
	const calls = options.spawn ? [] : spawnSetup.calls;
	const adapter = createTrellisAdapter({
		trellisRoot,
		hooksDir,
		spawn,
		tmpDir: options.tmpDir ?? fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-tmp-")),
	});
	return { adapter, spawn, calls };
}

const ALL_CANONICAL_SCRIPTS = [
	"block-destructive.sh",
	"skill-preload-guard.sh",
	"reread-guard.sh",
	"skill-slash-guard.sh",
	"post-edit-verify.sh",
	"truncation-check.sh",
	"track-read.sh",
	"session-context.sh",
	"inject-primer-index.sh",
	"skill-size-preflight.sh",
	"save-context-log.sh",
	"post-compact-context.sh",
	"spec-gate.sh",
	"decision-receipt.sh",
	"stop-verify.sh",
	"code-review-subagent.sh",
	"propose-rules.sh",
	"ui-verify.sh",
	"stamp-turn.sh",
];

// ---------------------------------------------------------------------------
// Path and envelope translation
// ---------------------------------------------------------------------------

describe("resolveTrellisRoot", () => {
	it("ignores TRELLIS_ROOT and only accepts an immutable payload ancestor", () => {
		const hooksDir = makeHooksDir(["block-destructive.sh"]);
		const payloadRoot = path.dirname(path.dirname(hooksDir));
		const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-source-"));
		fs.mkdirSync(path.join(sourceRoot, "core-rules", "hooks"), { recursive: true });
		const adapterDir = path.join(payloadRoot, "core-rules", "omp", "hooks", "pre");

		assert.equal(resolveTrellisRoot(adapterDir, { TRELLIS_ROOT: sourceRoot }), payloadRoot);
	});

	it("rejects a mutable checkout even when it contains canonical hooks", () => {
		const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-source-"));
		fs.mkdirSync(path.join(sourceRoot, "core-rules", "hooks"), { recursive: true });

		assert.equal(resolveTrellisRoot(path.join(sourceRoot, "core-rules", "omp", "hooks", "pre"), {}), undefined);
	});

	it("returns undefined when no immutable payload exists", () => {
		assert.equal(resolveTrellisRoot("/nonexistent/a/b/c", {}), undefined);
	});
});

describe("immutable runtime resolution", () => {
	it("resolves an installed payload from the attached project runtime anchor", () => {
		const hooksDir = makeHooksDir(["block-destructive.sh"]);
		const payloadRoot = path.dirname(path.dirname(hooksDir));
		const projectDir = makeAttachedOmpProject(payloadRoot);
		const nestedDir = path.join(projectDir, "src", "nested");
		fs.mkdirSync(nestedDir, { recursive: true });

		assert.deepEqual(resolveTrellisRuntime(nestedDir), {
			projectDir,
			trellisRoot: path.join(projectDir, ".trellis", "runtime"),
			hooksDir: path.join(projectDir, ".trellis", "runtime", "core-rules", "hooks"),
		});
	});

	it("keeps effective OMP hooks on the installed payload after the source checkout is dirtied and moved", async () => {
		const hooksDir = makeHooksDir(["block-destructive.sh"]);
		const payloadRoot = path.dirname(path.dirname(hooksDir));
		const projectDir = makeAttachedOmpProject(payloadRoot);
		const runtime = resolveTrellisRuntime(projectDir);
		if (!runtime) throw new Error("expected attached immutable runtime");

		const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-source-"));
		const sourceHook = path.join(sourceRoot, "core-rules", "hooks", "block-destructive.sh");
		fs.mkdirSync(path.dirname(sourceHook), { recursive: true });
		fs.writeFileSync(sourceHook, "# mutable source policy\n");
		fs.writeFileSync(sourceHook, "# dirty mutable source policy\n");
		const movedSourceRoot = `${sourceRoot}-moved`;
		fs.renameSync(sourceRoot, movedSourceRoot);

		const spawnSetup = makeSpawn({});
		const { adapter } = makeAdapter({
			trellisRoot: runtime.trellisRoot,
			hooksDir: runtime.hooksDir,
			spawn: spawnSetup.spawn,
		});
		const result = await adapter.onToolCall(
			{ type: "tool_call", toolCallId: "call-runtime", toolName: "bash", input: { command: "printf runtime" } },
			makeCtx({ cwd: projectDir }),
		);
		const [call] = spawnSetup.calls;
		if (!call) throw new Error("expected installed canonical hook invocation");

		assert.equal(result, undefined);
		assert.equal(call.args[0], path.join(payloadRoot, "core-rules", "hooks", "block-destructive.sh"));
		assert.equal(call.options.env.TRELLIS_ROOT, runtime.trellisRoot);
		assert.notEqual(call.args[0], path.join(movedSourceRoot, "core-rules", "hooks", "block-destructive.sh"));
	});

	it("rejects mutable source inputs passed through the explicit adapter contract", () => {
		const sourceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-source-"));
		const sourceHooksDir = path.join(sourceRoot, "core-rules", "hooks");
		fs.mkdirSync(sourceHooksDir, { recursive: true });

		assert.throws(
			() => createTrellisAdapter({ trellisRoot: sourceRoot, hooksDir: sourceHooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);
	});

	it("fails closed for an attached OMP surface with a missing runtime anchor", () => {
		const projectDir = makeOmpSurfaceProject();
		const { api, handlers } = makeExtensionApi();
		trellisExtension(api);
		const onToolCall = handlers.get("tool_call");
		if (!onToolCall) throw new Error("expected OMP tool-call handler");

		assert.throws(
			() => {
				onToolCall(
					{ type: "tool_call", toolCallId: "call-missing-runtime", toolName: "bash", input: { command: "true" } },
					makeCtx({ cwd: projectDir }),
				);
			},
			/missing immutable runtime anchor/,
		);
	});

	it("fails closed for an attached OMP surface with a wrong runtime payload", () => {
		const projectDir = makeOmpSurfaceProject();
		const mutableRoot = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-source-"));
		fs.mkdirSync(path.join(mutableRoot, "core-rules", "hooks"), { recursive: true });
		fs.mkdirSync(path.join(projectDir, ".trellis"), { recursive: true });
		fs.symlinkSync(mutableRoot, path.join(projectDir, ".trellis", "runtime"), "dir");

		assert.throws(() => resolveTrellisRuntime(projectDir), /does not resolve to an immutable payload/);
	});

	it("keeps a raw non-Trellis project inert and warning-free", async () => {
		const rawProjectDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-raw-"));
		fs.mkdirSync(path.join(rawProjectDir, ".trellis"), { recursive: true });
		fs.writeFileSync(path.join(rawProjectDir, ".trellis", "runtime"), "not an OMP attachment\n");
		const { api, handlers, labels, errors } = makeExtensionApi();
		trellisExtension(api);
		const onToolCall = handlers.get("tool_call");
		if (!onToolCall) throw new Error("expected OMP tool-call handler");

		const result = await onToolCall(
			{ type: "tool_call", toolCallId: "call-raw", toolName: "bash", input: { command: "true" } },
			makeCtx({ cwd: rawProjectDir }),
		);

		assert.equal(result, undefined);
		assert.deepEqual(labels, []);
		assert.deepEqual(errors, []);
	});

	it("rejects forged, empty, and incomplete release records", () => {
		const forged = makeReleaseFixture([{ path: "core-rules/hooks/block-destructive.sh", content: "approved\n" }]);
		rewriteFixtureReleaseRecord(forged.payloadRoot, (record) => {
			record.commit = "not-a-commit";
		});
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: forged.payloadRoot, hooksDir: forged.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);

		const empty = makeReleaseFixture([{ path: "core-rules/hooks/block-destructive.sh", content: "approved\n" }]);
		rewriteFixtureReleaseRecord(empty.payloadRoot, (record) => {
			record.tree = [];
		});
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: empty.payloadRoot, hooksDir: empty.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);

		const incomplete = makeReleaseFixture([
			{ path: "core-rules/hooks/block-destructive.sh", content: "approved\n" },
			{ path: "core-rules/hooks/reread-guard.sh", content: "approved\n" },
		]);
		rewriteFixtureReleaseRecord(incomplete.payloadRoot, (record) => {
			record.tree = (record.tree as unknown[]).slice(0, 1);
		});
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: incomplete.payloadRoot, hooksDir: incomplete.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);
	});

	it("rejects modified, added, and writable payload state", () => {
		const changed = makeReleaseFixture([{ path: "core-rules/hooks/block-destructive.sh", content: "approved\n" }]);
		makeReleaseWritable(changed.releaseDir);
		fs.writeFileSync(path.join(changed.hooksDir, "block-destructive.sh"), "changed\n");
		sealRelease(changed.releaseDir);
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: changed.payloadRoot, hooksDir: changed.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);

		const added = makeReleaseFixture([{ path: "core-rules/hooks/block-destructive.sh", content: "approved\n" }]);
		makeReleaseWritable(added.releaseDir);
		fs.writeFileSync(path.join(added.hooksDir, "unrecorded.sh"), "extra\n");
		sealRelease(added.releaseDir);
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: added.payloadRoot, hooksDir: added.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);

		const writable = makeReleaseFixture([{ path: "core-rules/hooks/block-destructive.sh", content: "approved\n" }]);
		assert.equal(resolveTrellisRoot(writable.payloadRoot, {}), writable.payloadRoot);
		fs.chmodSync(path.join(writable.hooksDir, "block-destructive.sh"), 0o644);
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: writable.payloadRoot, hooksDir: writable.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);
	});

	it("rejects hooks directory and script symlink escapes", () => {
		const outside = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-outside-"));
		const outsideHooks = path.join(outside, "hooks");
		fs.mkdirSync(outsideHooks);
		fs.writeFileSync(path.join(outsideHooks, "block-destructive.sh"), "outside\n");
		const hooksEscape = makeReleaseFixture([{ path: "core-rules/hooks", symlinkTarget: outsideHooks }]);
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: hooksEscape.payloadRoot, hooksDir: hooksEscape.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);

		const outsideScript = path.join(outside, "block-destructive.sh");
		const scriptEscape = makeReleaseFixture([
			{ path: "core-rules/hooks/block-destructive.sh", symlinkTarget: outsideScript },
		]);
		assert.throws(
			() => createTrellisAdapter({ trellisRoot: scriptEscape.payloadRoot, hooksDir: scriptEscape.hooksDir }),
			/canonical hooks directory missing or not from immutable payload/,
		);
	});

	it("keeps regular and unrelated OMP leaves in raw projects inert", async () => {
		for (const kind of ["regular", "unrelated-symlink"] as const) {
			const rawProjectDir = makeProjectDir(PROJECT_CLAUDE_MD);
			const adapterLeaf = path.join(rawProjectDir, ".omp", "hooks", "pre", "trellis.ts");
			fs.mkdirSync(path.dirname(adapterLeaf), { recursive: true });
			if (kind === "regular") {
				fs.writeFileSync(adapterLeaf, "// project-owned OMP adapter\n");
			} else {
				fs.symlinkSync("./project-owned.ts", adapterLeaf);
			}
			const { api, handlers, labels, errors } = makeExtensionApi();
			trellisExtension(api);
			const onToolCall = handlers.get("tool_call");
			if (!onToolCall) throw new Error("expected OMP tool-call handler");
			assert.equal(
				await onToolCall(
					{ type: "tool_call", toolCallId: `call-${kind}`, toolName: "task", input: { task: "raw" } },
					makeCtx({ cwd: rawProjectDir }),
				),
				undefined,
			);
			assert.deepEqual(labels, []);
			assert.deepEqual(errors, []);
		}
	});

	it("stops at nested Git roots and linked-worktree Git files", async () => {
		const hooksDir = makeHooksDir(["block-destructive.sh"]);
		const attachedProject = makeAttachedOmpProject(path.dirname(path.dirname(hooksDir)));
		const rawClone = path.join(attachedProject, "vendor", "raw-clone");
		const rawCwd = path.join(rawClone, "src");
		fs.mkdirSync(path.join(rawClone, ".git"), { recursive: true });
		fs.mkdirSync(rawCwd, { recursive: true });
		const linkedWorktree = path.join(attachedProject, "vendor", "linked-worktree");
		const linkedCwd = path.join(linkedWorktree, "src");
		fs.mkdirSync(linkedCwd, { recursive: true });
		fs.writeFileSync(path.join(linkedWorktree, ".git"), "gitdir: /tmp/linked-worktree.git\n");

		assert.equal(resolveTrellisRuntime(rawCwd), undefined);
		assert.equal(resolveTrellisRuntime(linkedCwd), undefined);
		const { api, handlers, labels, errors } = makeExtensionApi();
		trellisExtension(api);
		const onToolCall = handlers.get("tool_call");
		if (!onToolCall) throw new Error("expected OMP tool-call handler");
		assert.equal(
			await onToolCall(
				{ type: "tool_call", toolCallId: "call-nested-raw", toolName: "task", input: { task: "raw" } },
				makeCtx({ cwd: rawCwd }),
			),
			undefined,
		);
		assert.deepEqual(labels, []);
		assert.deepEqual(errors, []);
	});
});

describe("canonicalToolName", () => {
	it("maps managed OMP tools to Claude tool names", () => {
		assert.equal(canonicalToolName("bash"), "Bash");
		assert.equal(canonicalToolName("read"), "Read");
		assert.equal(canonicalToolName("write"), "Write");
		assert.equal(canonicalToolName("edit"), "Edit");
		assert.equal(canonicalToolName("grep"), "Grep");
		assert.equal(canonicalToolName("glob"), "Glob");
		assert.equal(canonicalToolName("skill"), "Skill");
	});

	it("leaves unmanaged tools unmapped", () => {
		assert.equal(canonicalToolName("task"), undefined);
		assert.equal(canonicalToolName("mcp__github_search"), undefined);
	});
});

describe("normalizeToolInput", () => {
	it("extracts the bash command", () => {
		assert.deepEqual(normalizeToolInput("bash", { command: "rm -rf /tmp/x" }), {
			command: "rm -rf /tmp/x",
		});
	});

	it("maps OMP path to canonical file_path for edit/write", () => {
		assert.deepEqual(normalizeToolInput("edit", { path: "src/a.ts", old_string: "x" }), {
			file_path: "src/a.ts",
		});
		assert.deepEqual(normalizeToolInput("write", { filePath: "src/b.ts", content: "y" }), {
			file_path: "src/b.ts",
		});
	});

	it("passes the grep pattern through", () => {
		assert.deepEqual(normalizeToolInput("grep", { pattern: "foo.*", path: "src" }), {
			file_path: "src",
			pattern: "foo.*",
		});
	});

	it("extracts the skill name for skill preload", () => {
		assert.deepEqual(normalizeToolInput("skill", { skill: "process-gate" }), { skill: "process-gate" });
		assert.deepEqual(normalizeToolInput("skill", { name: "process-gate" }), { skill: "process-gate" });
	});

	it("returns an empty object when nothing maps", () => {
		assert.deepEqual(normalizeToolInput("read", { limit: 40 }), {});
	});

	it("extracts every unique hashline edit path", () => {
		const patch = [
			"*** Begin Patch",
			"[src/a.ts#A1B2]",
			"PUT 1.=1:",
			"+a",
			"[src/b.ts#C3D4]",
			"PUT 2.=2:",
			"+b",
			"[src/a.ts#A1B2]",
			"PUT >1:",
			"+again",
			"*** End Patch",
		].join("\n");
		assert.deepEqual(editPatchPaths({ input: patch }), ["src/a.ts", "src/b.ts"]);
	});
});

describe("toolResponseText", () => {
	it("joins text blocks and ignores non-text content", () => {
		const content = [
			{ type: "text", text: "line one" },
			{ type: "image", source: { data: "abc" } },
			{ type: "text", text: "line two" },
			"not a block",
		];
		assert.equal(toolResponseText(content), "line one\nline two");
	});

	it("handles empty or missing content", () => {
		assert.equal(toolResponseText(undefined), "");
		assert.equal(toolResponseText([]), "");
	});
});

// ---------------------------------------------------------------------------
// Output parsing
// ---------------------------------------------------------------------------

describe("parseHookOutput", () => {
	it("parses a Claude PreToolUse denial", () => {
		const result = parseHookOutput(
			{
				stdout: JSON.stringify({
					hookSpecificOutput: {
						hookEventName: "PreToolUse",
						permissionDecision: "deny",
						permissionDecisionReason: "Blocked destructive rm",
					},
				}),
				stderr: "",
				status: 0,
			},
			"block-destructive.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "Blocked destructive rm" });
	});

	it("parses a decision block with exit 2", () => {
		const result = parseHookOutput(
			{ stdout: JSON.stringify({ decision: "block", reason: "lint failed" }), stderr: "", status: 2 },
			"post-edit-verify.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "lint failed" });
	});

	it("parses a decision block even when the script exits 0 (slash guard)", () => {
		const result = parseHookOutput(
			{ stdout: JSON.stringify({ decision: "block", reason: "oversized skill" }), stderr: "", status: 0 },
			"skill-slash-guard.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "oversized skill" });
	});

	it("parses top-level and hookSpecificOutput advisory context", () => {
		const direct = parseHookOutput(
			{ stdout: JSON.stringify({ additionalContext: "Result was truncated." }), stderr: "", status: 0 },
			"truncation-check.sh",
		);
		assert.deepEqual(direct, { kind: "context", context: "Result was truncated." });

		const nested = parseHookOutput(
			{
				stdout: JSON.stringify({
					hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "Branch: main" },
				}),
				stderr: "",
				status: 0,
			},
			"session-context.sh",
		);
		assert.deepEqual(nested, { kind: "context", context: "Branch: main" });
	});

	it("passes when a script exits 0 with no output", () => {
		assert.deepEqual(parseHookOutput({ stdout: "", stderr: "", status: 0 }, "track-read.sh"), { kind: "pass" });
	});

	it("blocks on exit 2 with stderr when stdout is not JSON", () => {
		const result = parseHookOutput({ stdout: "", stderr: "boom\nline two", status: 2 }, "stop-verify.sh");
		assert.deepEqual(result, { kind: "block", reason: "boom" });
	});

	it("errors on other non-zero exits with the script name", () => {
		const result = parseHookOutput({ stdout: "", stderr: "jq missing", status: 1 }, "block-destructive.sh");
		assert.deepEqual(result, { kind: "error", message: "block-destructive.sh: exit 1: jq missing" });
	});

	it("errors on a null status carrying the exact script path", () => {
		const result = parseHookOutput({ stdout: "", stderr: "missing canonical hook: /x/hooks/a.sh", status: null }, "a.sh");
		assert.deepEqual(result, { kind: "error", message: "a.sh: missing canonical hook: /x/hooks/a.sh" });
	});

	it("ignores warning lines preceding the JSON decision", () => {
		const result = parseHookOutput(
			{
				stdout: `note to stderr-capturing readers\n${JSON.stringify({ decision: "block", reason: "no receipt" })}`,
				stderr: "",
				status: 2,
			},
			"stop-verify.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "no receipt" });
	});
});

describe("buildTranscriptJsonl", () => {
	it("emits Claude-shaped JSONL lines with roles", () => {
		const messages = [
			{ role: "user", content: "ask" },
			{ role: "assistant", content: [{ type: "text", text: "answer" }] },
		];
		const jsonl = buildTranscriptJsonl(messages);
		const lines = jsonl.trimEnd().split("\n");
		assert.equal(lines.length, 2);
		assert.deepEqual(JSON.parse(lines[0] ?? "{}"), { type: "user", message: messages[0] });
		assert.deepEqual(JSON.parse(lines[1] ?? "{}"), { type: "assistant", message: messages[1] });
	});

	it("normalizes OMP content arrays to the Claude transcript shapes hooks parse", () => {
		const jsonl = buildTranscriptJsonl([
			{
				role: "user",
				content: [
					{ type: "text", text: "first" },
					{ type: "image", data: "ignored" },
					{ type: "text", text: "second" },
				],
			},
			{ role: "assistant", content: "answer" },
		]);
		const lines = jsonl.trimEnd().split("\n");
		assert.equal(JSON.parse(lines[0] ?? "{}").message.content, "first\nsecond");
		assert.deepEqual(JSON.parse(lines[1] ?? "{}").message.content, [{ type: "text", text: "answer" }]);
	});

	it("tolerates non-message entries", () => {
		const jsonl = buildTranscriptJsonl([null, "raw", { role: "user", content: "x" }]);
		const lines = jsonl.trimEnd().split("\n");
		assert.equal(JSON.parse(lines[0] ?? "{}").type, "unknown");
		assert.equal(JSON.parse(lines[1] ?? "{}").type, "unknown");
		assert.equal(JSON.parse(lines[2] ?? "{}").type, "user");
	});

	it("returns empty string for no messages", () => {
		assert.equal(buildTranscriptJsonl([]), "");
	});
});

describe("policy marker detection", () => {
	it("derives a marker from the first non-empty line", () => {
		assert.equal(policyMarker(PROJECT_CLAUDE_MD), PROJECT_POLICY_MARKER);
	});

	it("returns undefined for empty policy text", () => {
		assert.equal(policyMarker(""), undefined);
		assert.equal(policyMarker("   \n\t\n"), undefined);
	});

	it("reports the policy present only when the system prompt contains the marker", () => {
		const marker = policyMarker(PROJECT_CLAUDE_MD);
		assert.equal(systemPromptHasPolicy([PROJECT_CLAUDE_MD, "other"], marker), true);
		assert.equal(systemPromptHasPolicy(["no policy here"], marker), false);
		assert.equal(systemPromptHasPolicy(undefined, marker), false);
		assert.equal(systemPromptHasPolicy(["anything"], undefined), true);
	});
});

describe("Trellis preset policy discovery", () => {
	it("loads only managed preset links resolving inside the canonical preset root", () => {
		const strictPolicy = "# Compliance strict preset\nCanonical preset body.";
		const hooksDir = makeHooksDir([], [{ path: "core-rules/presets/compliance-strict.md", content: strictPolicy }]);
		const trellisRoot = path.dirname(path.dirname(hooksDir));
		const presetsDir = path.join(trellisRoot, "core-rules", "presets");
		const projectDir = makeProjectDir(PROJECT_CLAUDE_MD);
		const rulesDir = path.join(projectDir, ".claude", "rules");
		fs.mkdirSync(rulesDir, { recursive: true });

		const strictPath = path.join(presetsDir, "compliance-strict.md");
		fs.symlinkSync(strictPath, path.join(rulesDir, "preset-compliance-strict.md"));

		const outsidePath = path.join(projectDir, "outside.md");
		fs.writeFileSync(outsidePath, "# User-owned lookalike");
		fs.symlinkSync(outsidePath, path.join(rulesDir, "preset-lookalike.md"));

		assert.deepEqual(trellisPresetPolicies(projectDir, trellisRoot), [strictPolicy]);
	});
});

describe("slashCommandName", () => {
	it("extracts the command from slash input", () => {
		assert.equal(slashCommandName("/primer-refresh"), "primer-refresh");
		assert.equal(slashCommandName("/compact now"), "compact");
	});
	it("ignores plain text and bare slashes", () => {
		assert.equal(slashCommandName("just text"), undefined);
		assert.equal(slashCommandName("//"), undefined);
		assert.equal(slashCommandName("/"), undefined);
	});
});

// ---------------------------------------------------------------------------
// tool_call: destructive denial, pass-through, fail-closed
// ---------------------------------------------------------------------------

describe("tool_call", () => {
	it("blocks a destructive bash command with the canonical reason", async () => {
		const deny = JSON.stringify({
			hookSpecificOutput: {
				hookEventName: "PreToolUse",
				permissionDecision: "deny",
				permissionDecisionReason: "Blocked destructive rm targeting absolute path",
			},
		});
		const { spawn, calls } = makeSpawn({ "block-destructive.sh": { stdout: deny } });
		const { adapter } = makeAdapter({ spawn });

		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c1",
			toolName: "bash",
			input: { command: "rm -rf /Users/me/important" },
		};
		const ctx = makeCtx();
		const result = await adapter.onToolCall(event, ctx);

		assert.deepEqual(result, { block: true, reason: "Blocked destructive rm targeting absolute path" });
		assert.equal(calls.length, 1);
		assert.equal(calls[0]?.script, "block-destructive.sh");
		const envelope = JSON.parse(calls[0]?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.tool_name, "Bash");
		assert.deepEqual(envelope.tool_input, { command: "rm -rf /Users/me/important" });
		assert.equal(calls[0]?.options.env.CLAUDE_PROJECT_DIR, ctx.cwd);
	});

	it("passes through unmanaged tools untouched", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();

		const taskCall: OmpToolCallEvent = { type: "tool_call", toolCallId: "t", toolName: "task", input: { task: "x" } };
		assert.equal(await adapter.onToolCall(taskCall, ctx), undefined);

		const mcpCall: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "m",
			toolName: "mcp__github_search",
			input: {},
		};
		assert.equal(await adapter.onToolCall(mcpCall, ctx), undefined);
		assert.equal(calls.length, 0);
	});

	it("passes through when the canonical gate allows", async () => {
		const { spawn, calls } = makeSpawn({ "block-destructive.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c2",
			toolName: "bash",
			input: { command: "npm test" },
		};
		assert.equal(await adapter.onToolCall(event, makeCtx()), undefined);
		assert.equal(calls.length, 1);
	});

	it("fails closed when the canonical script is missing", async () => {
		const { spawn, calls } = makeSpawn({});
		const hooksDir = makeHooksDir(["reread-guard.sh"]); // no block-destructive.sh
		const { adapter } = makeAdapter({ spawn, hooksDir });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c3",
			toolName: "bash",
			input: { command: "rm -rf /" },
		};
		const result = await adapter.onToolCall(event, makeCtx());
		assert.ok(result?.block === true, "expected a block");
		assert.match(result?.reason ?? "", /block-destructive\.sh/);
		assert.equal(calls.length, 0); // existence check failed before spawn
	});

	it("fails closed when the canonical script errors", async () => {
		const { spawn, calls } = makeSpawn({ "reread-guard.sh": { stdout: "", stderr: "jq missing", status: 1 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c4",
			toolName: "write",
			input: { path: "src/x.ts", content: "y" },
		};
		const result = await adapter.onToolCall(event, makeCtx());
		assert.ok(result?.block === true);
		assert.match(result?.reason ?? "", /reread-guard\.sh/);
		assert.equal(calls.length, 1);
	});

	it("runs the reread guard for edits with a normalized file_path", async () => {
		const { spawn, calls } = makeSpawn({ "reread-guard.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c5",
			toolName: "edit",
			input: { path: "src/a.ts" },
		};
		assert.equal(await adapter.onToolCall(event, makeCtx()), undefined);
		const envelope = JSON.parse(calls[0]?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.tool_name, "Edit");
		assert.deepEqual(envelope.tool_input, { file_path: "src/a.ts" });
	});

	it("runs the reread guard once for every file in a hashline edit", async () => {
		const { spawn, calls } = makeSpawn({ "reread-guard.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c6",
			toolName: "edit",
			input: {
				input: [
					"*** Begin Patch",
					"[src/a.ts#A1B2]",
					"PUT 1.=1:",
					"+a",
					"[src/b.ts#C3D4]",
					"PUT 1.=1:",
					"+b",
					"*** End Patch",
				].join("\n"),
			},
		};
		assert.equal(await adapter.onToolCall(event, makeCtx()), undefined);
		const toolInputs = calls.map((call) => {
			const envelope: unknown = JSON.parse(call.options.input);
			assert.ok(envelope !== null && typeof envelope === "object" && "tool_input" in envelope);
			return envelope.tool_input;
		});
		assert.deepEqual(toolInputs, [{ file_path: "src/a.ts" }, { file_path: "src/b.ts" }]);
	});

	it("resolves a nested cwd to the project carrying the OMP surface", async () => {
		const { spawn, calls } = makeSpawn({ "block-destructive.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-project-root-"));
		fs.mkdirSync(path.join(projectDir, ".omp"), { recursive: true });
		fs.writeFileSync(path.join(projectDir, ".omp", "AGENTS.md"), "policy");
		const nested = path.join(projectDir, "src", "nested");
		fs.mkdirSync(nested, { recursive: true });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c7",
			toolName: "bash",
			input: { command: "npm test" },
		};
		assert.equal(await adapter.onToolCall(event, makeCtx({ cwd: nested })), undefined);
		assert.equal(calls[0]?.options.env.CLAUDE_PROJECT_DIR, projectDir);
	});
});

// ---------------------------------------------------------------------------
// tool_result: post-edit gate, truncation advisory, read tracking
// ---------------------------------------------------------------------------

describe("tool_result", () => {
	it("marks a post-edit gate block as an error with the reason in content", async () => {
		const { spawn, calls } = makeSpawn({
			"post-edit-verify.sh": { stdout: JSON.stringify({ decision: "block", reason: "eslint: no-unused-vars" }), status: 2 },
			"track-read.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r1",
			toolName: "edit",
			input: { path: "src/a.ts" },
			content: [{ type: "text", text: "edit applied" }],
			isError: false,
		};
		const result = await adapter.onToolResult(event, makeCtx());
		assert.ok(result, "expected a patch");
		assert.equal(result.isError, true);
		assert.equal(result.content?.[0]?.type, "text");
		assert.equal(result.content?.[0]?.text, "eslint: no-unused-vars");
		assert.equal(result.content?.at(-1)?.text, "edit applied");
		const scripts = calls.map((call) => call.script);
		assert.ok(scripts.includes("post-edit-verify.sh"));
		assert.ok(scripts.includes("track-read.sh"));
		assert.ok(!scripts.includes("truncation-check.sh"), "edit is not in the truncation matcher");
	});

	it("appends a truncation advisory without marking an error", async () => {
		const { spawn, calls } = makeSpawn({
			"truncation-check.sh": { stdout: JSON.stringify({ additionalContext: "Result was truncated. Re-run with narrower scope." }), status: 0 },
			"track-read.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r2",
			toolName: "read",
			input: { path: "big.ts" },
			content: [{ type: "text", text: "lots of output" }],
			isError: false,
		};
		const result = await adapter.onToolResult(event, makeCtx());
		assert.ok(result, "expected a patch");
		assert.equal(result.isError, false);
		assert.equal(result.content?.at(-1)?.text, "Result was truncated. Re-run with narrower scope.");
		assert.ok(calls.some((call) => call.script === "truncation-check.sh"));
		assert.ok(calls.some((call) => call.script === "track-read.sh"));
	});

	it("passes through when every gate allows", async () => {
		const { spawn } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r3",
			toolName: "read",
			input: { path: "ok.ts" },
			content: [{ type: "text", text: "fine" }],
			isError: false,
		};
		assert.equal(await adapter.onToolResult(event, makeCtx()), undefined);
	});

	it("passes through unmanaged tools", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r4",
			toolName: "mcp__x",
			input: {},
			content: [],
			isError: false,
		};
		assert.equal(await adapter.onToolResult(event, makeCtx()), undefined);
		assert.equal(calls.length, 0);
	});
});

// ---------------------------------------------------------------------------
// input: slash-skill size guard
// ---------------------------------------------------------------------------

describe("input", () => {
	it("consumes a slash command denied by the skill-size guard", async () => {
		const { spawn, calls } = makeSpawn({
			"skill-slash-guard.sh": { stdout: JSON.stringify({ decision: "block", reason: "oversized skill: process-gate" }), status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpInputEvent = { type: "input", text: "/process-gate run", source: "interactive" };
		const result = await adapter.onInput(event, makeCtx());
		assert.deepEqual(result, { handled: true, text: "" });
		const envelope = JSON.parse(calls[0]?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.hook_event_name, "UserPromptExpansion");
		assert.equal(envelope.expansion_type, "slash_command");
		assert.equal(envelope.command_name, "process-gate");
	});

	it("passes through plain text and allowed slash commands", async () => {
		const { spawn, calls } = makeSpawn({
			"skill-slash-guard.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();
		assert.equal(await adapter.onInput({ type: "input", text: "hello there", source: "interactive" }, ctx), undefined);
		assert.equal(await adapter.onInput({ type: "input", text: "/status", source: "interactive" }, ctx), undefined);
		assert.equal(calls.length, 1, "plain text must not invoke the guard");
	});

	it("passes through when the guard errors (logged, not swallowed)", async () => {
		const { spawn, calls } = makeSpawn({
			"skill-slash-guard.sh": { stdout: "", stderr: "jq missing", status: 1 },
		});
		const { adapter } = makeAdapter({ spawn });
		const result = await adapter.onInput({ type: "input", text: "/surgical fix", source: "interactive" }, makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, 1);
	});
});

// ---------------------------------------------------------------------------
// before_agent_start: session context + child policy injection
// ---------------------------------------------------------------------------

describe("before_agent_start", () => {
	const sessionContextOut = JSON.stringify({
		hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "Branch: main\nDirty files: 2" },
	});

	function agentStartEvent(): OmpBeforeAgentStartEvent {
		return { type: "before_agent_start", prompt: "do the thing", systemPrompt: ["base system prompt"] };
	}

	it("injects live project CLAUDE.md into a session whose prompt lacks it (child)", async () => {
		const { spawn, calls } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
			"inject-primer-index.sh": { stdout: "", status: 0 },
			"skill-size-preflight.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx({ getSystemPrompt: () => ["task child prompt without policy"] });

		const result = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);

		assert.ok(result, "expected an injection result");
		// Session context rides as a hidden custom message.
		assert.equal(result.message?.customType, "trellis-session-context");
		assert.match(result.message?.content ?? "", /Branch: main/);
		assert.equal(result.message?.display, false);
		// Live project policy appended to the system prompt for the child.
		assert.ok(result.systemPrompt, "expected policy appended to systemPrompt");
		assert.deepEqual(result.systemPrompt, ["task child prompt without policy", PROJECT_CLAUDE_MD]);
		assert.ok(calls.some((call) => call.script === "session-context.sh"));
		assert.ok(calls.some((call) => call.script === "inject-primer-index.sh"));
		assert.ok(calls.some((call) => call.script === "skill-size-preflight.sh"));
	});

	it("does not duplicate policy when the system prompt already carries it (main session)", async () => {
		const { spawn } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx({
			getSystemPrompt: () => ["header", PROJECT_CLAUDE_MD, "tail"], // native .omp/AGENTS.md content
		});

		const result = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		assert.ok(result, "session context still injected");
		assert.equal(result.systemPrompt, undefined, "no policy duplication");
		assert.match(result.message?.content ?? "", /Branch: main/);
	});

	it("injects canonical Trellis presets that OMP does not discover natively", async () => {
		const preset = "# Compliance strict preset\nAdditional canonical constraints.";
		const hooksDir = makeHooksDir(ALL_CANONICAL_SCRIPTS, [
			{ path: "core-rules/presets/compliance-strict.md", content: preset },
		]);
		const trellisRoot = path.dirname(path.dirname(hooksDir));
		const presetsDir = path.join(trellisRoot, "core-rules", "presets");
		const projectDir = makeProjectDir(PROJECT_CLAUDE_MD);
		const rulesDir = path.join(projectDir, ".claude", "rules");
		fs.mkdirSync(rulesDir, { recursive: true });
		const presetPath = path.join(presetsDir, "compliance-strict.md");
		fs.symlinkSync(presetPath, path.join(rulesDir, "preset-compliance-strict.md"));

		const { spawn } = makeSpawn({ "session-context.sh": { stdout: sessionContextOut, status: 0 } });
		const { adapter } = makeAdapter({ spawn, hooksDir, trellisRoot });
		const result = await adapter.onBeforeAgentStart(
			agentStartEvent(),
			makeCtx({ cwd: projectDir, getSystemPrompt: () => [PROJECT_CLAUDE_MD] }),
		);

		assert.deepEqual(result?.systemPrompt, [PROJECT_CLAUDE_MD, preset]);
	});

	it("injects only once per session", async () => {
		const { spawn, calls } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();

		const first = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		const second = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		assert.ok(first, "first agent start injects");
		assert.equal(second, undefined, "later agent starts are untouched");
		assert.equal(calls.filter((call) => call.script === "session-context.sh").length, 1);
	});

	it("injects the canonical policy in the private control-plane checkout", async () => {
		const canonicalPolicy = "# Canonical Trellis control plane\nLoad-bearing policy.";
		const hooksDir = makeHooksDir(ALL_CANONICAL_SCRIPTS, [
			{ path: "core-rules/CLAUDE.md", content: canonicalPolicy },
		]);
		const trellisRoot = path.dirname(path.dirname(hooksDir));
		const { spawn } = makeSpawn({ "session-context.sh": { stdout: sessionContextOut, status: 0 } });
		const { adapter } = makeAdapter({ spawn, hooksDir, trellisRoot });
		const result = await adapter.onBeforeAgentStart(
			agentStartEvent(),
			makeCtx({ cwd: trellisRoot, getSystemPrompt: () => ["base"] }),
		);
		assert.deepEqual(result?.systemPrompt, ["base", canonicalPolicy]);
	});

	it("uses immutable payload policy when an attached project has no CLAUDE.md", async () => {
		const canonicalPolicy = "# Immutable release policy\nNo source checkout fallback.";
		const hooksDir = makeHooksDir(ALL_CANONICAL_SCRIPTS, [
			{ path: "core-rules/CLAUDE.md", content: canonicalPolicy },
		]);
		const payloadRoot = path.dirname(path.dirname(hooksDir));
		const projectDir = makeAttachedOmpProject(payloadRoot);
		fs.rmSync(path.join(projectDir, "CLAUDE.md"));
		const runtime = resolveTrellisRuntime(projectDir);
		if (!runtime) throw new Error("expected attached immutable runtime");
		const { spawn } = makeSpawn({ "session-context.sh": { stdout: sessionContextOut, status: 0 } });
		const { adapter } = makeAdapter({
			spawn,
			hooksDir: runtime.hooksDir,
			trellisRoot: runtime.trellisRoot,
		});

		const result = await adapter.onBeforeAgentStart(
			agentStartEvent(),
			makeCtx({ cwd: projectDir, getSystemPrompt: () => ["base"] }),
		);

		assert.deepEqual(result?.systemPrompt, ["base", canonicalPolicy]);
	});

	it("skips policy injection when the project has no CLAUDE.md", async () => {
		const { spawn } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx({ cwd: fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-nopolicy-")) });
		const result = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		assert.ok(result);
		assert.equal(result.systemPrompt, undefined);
	});
});

// ---------------------------------------------------------------------------
// session_before_compact / session_shutdown: context-log preservation
// ---------------------------------------------------------------------------

describe("context-log preservation", () => {
	it("runs save-context-log.sh on session_before_compact", async () => {
		const { spawn, calls } = makeSpawn({ "save-context-log.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();
		const result = await adapter.onBeforeCompact({ type: "session_before_compact" }, ctx);
		assert.equal(result, undefined, "compaction is never cancelled");
		assert.equal(calls.length, 1);
		assert.equal(calls[0]?.script, "save-context-log.sh");
		assert.equal(calls[0]?.options.env.CLAUDE_PROJECT_DIR, ctx.cwd);
	});

	it("passes the compaction conversation to save-context-log.sh", async () => {
		const { spawn, calls } = makeSpawn({ "save-context-log.sh": { stdout: "", status: 0 } });
		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-compact-"));
		const { adapter } = makeAdapter({ spawn, tmpDir });
		const messages = [
			{ role: "user", content: "preserve this ask" },
			{ role: "assistant", content: [{ type: "text", text: "preserve this decision" }] },
		];
		await adapter.onBeforeCompact(
			{
				type: "session_before_compact",
				preparation: { messagesToSummarize: messages, turnPrefixMessages: [], recentMessages: [] },
			},
			makeCtx(),
		);
		const call = calls[0];
		assert.equal(call?.transcript, buildTranscriptJsonl(messages));
		const transcriptPath = call?.options.env.CLAUDE_TRANSCRIPT_PATH;
		assert.ok(transcriptPath);
		assert.ok(!fs.existsSync(transcriptPath), "compaction transcript is removed after the hook");
	});

	it("returns canonical post-compact context for hidden injection", async () => {
		const contextOut = JSON.stringify({
			hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "restored context" },
		});
		const { spawn, calls } = makeSpawn({ "post-compact-context.sh": { stdout: contextOut, status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		assert.equal(await adapter.onCompact({ type: "session_compact" }, makeCtx()), "restored context");
		assert.equal(calls[0]?.script, "post-compact-context.sh");
	});

	it("runs save-context-log.sh on session_shutdown", async () => {
		const { spawn, calls } = makeSpawn({ "save-context-log.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		await adapter.onShutdown({ type: "session_shutdown" }, makeCtx());
		assert.equal(calls.length, 1);
		assert.equal(calls[0]?.script, "save-context-log.sh");
	});
});

// ---------------------------------------------------------------------------
// session_stop: receipt gates and continuation
// ---------------------------------------------------------------------------

describe("session_stop", () => {
	const messages = [
		{ role: "user", content: "fix the build" },
		{
			role: "assistant",
			content: [
				{ type: "text", text: 'done <!-- dod-receipt cmd="npm test" exit=0 diff="+2/-1 (1 files)" -->' },
			],
		},
	];

	function stopEvent(overrides: Partial<OmpSessionStopEvent> = {}): OmpSessionStopEvent {
		return {
			type: "session_stop",
			messages,
			turn_id: 7,
			session_id: "sess-abc",
			session_file: "/tmp/sess-abc.jsonl",
			stop_hook_active: false,
			...overrides,
		};
	}

	it("propagates a decision-receipt block before general verification", async () => {
		const { spawn, calls } = makeSpawn({
			"decision-receipt.sh": {
				stdout: JSON.stringify({ decision: "block", reason: "decision-receipt: missing decision block" }),
				status: 2,
			},
		});
		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-stop-"));
		const { adapter } = makeAdapter({ spawn, tmpDir });

		const result = await adapter.onStop(stopEvent(), makeCtx());
		assert.deepEqual(result, { decision: "block", reason: "decision-receipt: missing decision block" });

		const scripts = calls.map((call) => call.script);
		assert.deepEqual(scripts, ["spec-gate.sh", "decision-receipt.sh"]);
		assert.ok(!scripts.includes("stop-verify.sh"), "general verification does not run after the decision block");
		assert.ok(!scripts.includes("stamp-turn.sh"), "stops at the first block");

		// Transcript: adapter-produced Claude JSONL, exported via env, cleaned up.
		const stopCall = calls.find((call) => call.script === "decision-receipt.sh");
		const transcriptPath = stopCall?.options.env.CLAUDE_TRANSCRIPT_PATH;
		assert.ok(transcriptPath, "CLAUDE_TRANSCRIPT_PATH must be set");
		assert.equal(stopCall?.transcript, buildTranscriptJsonl(messages));
		const envelope = JSON.parse(stopCall?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.transcript_path, transcriptPath);
		assert.equal(envelope.session_id, "sess-abc");
		assert.equal(envelope.session_file, "/tmp/sess-abc.jsonl");
		assert.equal(envelope.stop_hook_active, false);
		assert.ok(!fs.existsSync(transcriptPath), "temp transcript is removed after the blocked stop pass");
	});

	it("fails closed when decision-receipt cannot run", async () => {
		const { spawn, calls } = makeSpawn({
			"decision-receipt.sh": { stderr: "jq missing", status: 1 },
		});
		const { adapter } = makeAdapter({ spawn });

		const result = await adapter.onStop(stopEvent(), makeCtx());
		assert.deepEqual(result, {
			decision: "block",
			reason: "decision-receipt.sh: exit 1: jq missing",
		});
		assert.deepEqual(
			calls.map((call) => call.script),
			["spec-gate.sh", "decision-receipt.sh"],
		);
	});

	it("continues quietly when every receipt gate passes", async () => {
		const { spawn, calls } = makeSpawn({});
		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-stop-"));
		const { adapter } = makeAdapter({ spawn, tmpDir });

		const result = await adapter.onStop(stopEvent(), makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, STOP_SCRIPTS_EXPECTED.length);
	});

	it("skips the whole pass on a continuation (stop_hook_active)", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const result = await adapter.onStop(stopEvent({ stop_hook_active: true }), makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, 0);
	});

	it("skips the whole pass when the settle is aborted", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const controller = new AbortController();
		controller.abort();
		const result = await adapter.onStop(stopEvent({ signal: controller.signal }), makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, 0);
	});
});

const STOP_SCRIPTS_EXPECTED = [
	"spec-gate.sh",
	"decision-receipt.sh",
	"stop-verify.sh",
	"code-review-subagent.sh",
	"propose-rules.sh",
	"ui-verify.sh",
	"stamp-turn.sh",
];

// ---------------------------------------------------------------------------
// Unsupported setup: refuse to run without canonical hooks
// ---------------------------------------------------------------------------

describe("adapter setup refusal", () => {
	it("throws when the canonical hooks directory is missing", () => {
		const missing = path.join(os.tmpdir(), "trellis-omp-no-hooks");
		assert.throws(() => createTrellisAdapter({ trellisRoot: "/tmp", hooksDir: missing }), /canonical hooks directory missing/);
	});

	it("runs a real script through runCanonicalHook with the envelope on stdin", () => {
		const hooksDir = makeHooksDir([], [
			{ path: "core-rules/hooks/echo-hook.sh", content: "#!/usr/bin/env bash\ncat\n", mode: 0o755 },
		]);
		const result = runCanonicalHook(
			{
				hooksDir,
				trellisRoot: path.dirname(path.dirname(hooksDir)),
				script: "echo-hook.sh",
				projectDir: "/tmp/project",
				envelope: { tool_name: "Bash", tool_input: { command: "ls" } },
				timeoutMs: 5_000,
			},
			undefined, // real spawnSync — exercises the live execution path
		);
		assert.equal(result.status, 0);
		assert.deepEqual(JSON.parse(result.stdout), { tool_name: "Bash", tool_input: { command: "ls" } });
	});
});
