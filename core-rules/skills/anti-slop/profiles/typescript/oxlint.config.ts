// Anti-slop Oxlint profile template. Merge these fields into the project's own
// oxlint config; never replace an existing one. Adjust the jsPlugins specifier and
// the matching ignorePattern when the plugin is copied somewhere other than
// tools/oxlint/anti-slop. Vite+ projects nest lint fields under `lint` and repeat
// the ignores under `fmt`. Requires `"type": "module"` in package.json — Oxlint
// loads a .ts config through Node, which rejects ESM syntax in a CJS package.
export default {
	ignorePatterns: [
		".agent/**",
		".agents/**",
		".claude/**",
		".codex/**",
		".cursor/**",
		".gemini/**",
		".opencode/**",
		"tools/oxlint/anti-slop/**",
	],
	jsPlugins: [{ name: "anti-slop", specifier: "./tools/oxlint/anti-slop/index.ts" }],
	rules: {
		"anti-slop/no-chained-type-assertions": "error",
		"anti-slop/no-conditional-empty-object-spread": "error",
		"anti-slop/no-known-value-widening": "error",
		"anti-slop/no-module-mocking": "error",
		"anti-slop/no-object-parameters": "error",
		"anti-slop/no-reflect-apply": "error",
		"anti-slop/no-reflect-get": "error",
		"anti-slop/no-runtime-typeof": "error",
		"anti-slop/no-shape-in-symbol-names": "error",
		"anti-slop/no-unknown-parameters": "error",
		"anti-slop/no-unknown-returns": "error",
		"anti-slop/no-unknown-type-aliases": "error",
		"anti-slop/no-unsafe-dictionary-type": "error",
		"anti-slop/no-widen-then-assert": "error",
		"anti-slop/require-safety-comment-for-type-assertion": "error",
	},
};
