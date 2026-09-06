import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

// Manual version qualification: explicitly supply a pristine 0.85.1 fixture.
// Only the listed files are copied; assertions never mutate the input package.
const source = process.env.PI_CODING_AGENT_PACKAGE_ROOT;
assert.ok(source, "set PI_CODING_AGENT_PACKAGE_ROOT to a pristine Pi 0.85.1 package fixture");
const patchesDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const installer = join(patchesDir, "apply-pi-compaction-patches.sh");
const patchFile = join(patchesDir, "pi-coding-agent-0.85.1-compaction-integrity.patch");
const files = [
	"package.json",
	"dist/core/compaction/compaction.js",
	"dist/core/compaction/utils.js",
	"dist/bundle/chunks/chunk-JVUZSMYM.js",
];
const bundlePreimage = 'if(response.stopReason==="length")return`${label} failed: generation hit the token cap and the summary is incomplete`}';

function run(command, args, options = {}) {
	const result = spawnSync(command, args, { encoding: "utf8", ...options });
	assert.ifError(result.error);
	return result;
}

function patch(root, args = []) {
	return run("patch", ["-d", root, "-p1", "--fuzz=0", "-f", "-s", ...args, "-i", patchFile]);
}

function snapshot(root) {
	return Object.fromEntries(files.map((file) => {
		try {
			return [file, createHash("sha256").update(readFileSync(join(root, file))).digest("hex")];
		} catch (error) {
			if (error.code === "ENOENT") return [file, null];
			throw error;
		}
	}));
}

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "pi0851-compaction-installer-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	for (const file of files) {
		mkdirSync(dirname(join(root, file)), { recursive: true });
		copyFileSync(join(source, file), join(root, file));
	}
	assert.equal(JSON.parse(readFileSync(join(root, "package.json"))).version, "0.85.1");
	assert.equal(readFileSync(join(root, files[3]), "utf8").split(bundlePreimage).length, 2);
	assert.equal(patch(root, ["--dry-run"]).status, 0);
	return root;
}

function install(root, options = {}) {
	return run("bash", [installer, root], options);
}

function assertApplied(root) {
	assert.equal(patch(root, ["-R", "--dry-run"]).status, 0);
	const bundle = readFileSync(join(root, files[3]), "utf8");
	assert.equal(bundle.includes(bundlePreimage), false);
	assert.equal(bundle.includes("generation was aborted"), true);
	assert.equal(bundle.includes("middle characters truncated"), true);
}

test("0.85.1 applies SDK and exact JVUZSMYM bundle, then is idempotent", (t) => {
	const root = fixture(t);
	const first = install(root);
	assert.equal(first.status, 0, first.stdout + first.stderr);
	assertApplied(root);
	const after = snapshot(root);
	const second = install(root);
	assert.equal(second.status, 0, second.stdout + second.stderr);
	assert.match(second.stdout, /already applied/);
	assert.deepEqual(snapshot(root), after);
});

test("partial SDK state refuses before changing the bundle", (t) => {
	const root = fixture(t);
	assert.equal(patch(root).status, 0);
	const before = snapshot(root);
	const result = install(root);
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /source drifted|refusing/);
	assert.deepEqual(snapshot(root), before);
});

test("unknown version refuses before any target bytes change", (t) => {
	const root = fixture(t);
	const packagePath = join(root, "package.json");
	const pkg = JSON.parse(readFileSync(packagePath));
	pkg.version = "0.85.2";
	writeFileSync(packagePath, JSON.stringify(pkg));
	const before = snapshot(root);
	const result = install(root);
	assert.equal(result.status, 65);
	assert.match(result.stderr, /unsupported/);
	assert.deepEqual(snapshot(root), before);
});

test("missing exact 0.85.1 bundle refuses before SDK writes", (t) => {
	const root = fixture(t);
	unlinkSync(join(root, files[3]));
	const before = snapshot(root);
	const result = install(root);
	assert.equal(result.status, 66);
	assert.match(result.stderr, /missing the exact SDK or bundle files/);
	assert.deepEqual(snapshot(root), before);
});

test("ambiguous exact bundle preimage refuses before SDK writes", (t) => {
	const root = fixture(t);
	const bundlePath = join(root, files[3]);
	const bundle = readFileSync(bundlePath, "utf8");
	writeFileSync(bundlePath, bundle + bundlePreimage);
	const before = snapshot(root);
	const result = install(root);
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /source drifted|preflight/);
	assert.deepEqual(snapshot(root), before);
});

test("mutation-time bundle failure reports an explicit partial-state status", (t) => {
	const root = fixture(t);
	const shimDir = mkdtempSync(join(tmpdir(), "pi0851-compaction-node-shim-"));
	t.after(() => rmSync(shimDir, { recursive: true, force: true }));
	const shim = join(shimDir, "node");
	writeFileSync(shim, `#!/bin/sh
if [ "$4" = apply ]; then rm -f -- "$3"; fi
exec ${process.execPath} "$@"
`, { mode: 0o755 });
	const result = install(root, { env: { ...process.env, PATH: `${shimDir}:${process.env.PATH}` } });
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /bundled apply failed.*partially patched and was not rolled back/);
});
