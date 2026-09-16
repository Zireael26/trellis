import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { join } from "node:path";
import test from "node:test";

const root = process.env.PI_MCP_ADAPTER_ROOT;
assert.ok(root, "set PI_MCP_ADAPTER_ROOT to the qualified adapter package");
const source = readFileSync(join(root, "tool-registrar.ts"), "utf8");
const code = stripTypeScriptTypes(source);
const { resolveMcpResultContent } = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);

test("Cua snapshot handles reach the model alongside display text and native images", () => {
  const image = { type: "image", mimeType: "image/png", data: "cG5n" };
  const structured = { snapshot_id: "s00000001", elements: [{ element_token: "s00000001:8" }] };
  const blocks = resolveMcpResultContent({
    content: [{ type: "text", text: '[8] AXButton "All Clear"' }, image],
    structuredContent: structured,
  });
  assert.deepEqual(JSON.parse(blocks[0].text), structured);
  assert.ok(blocks.some(block => block.type === "text" && block.text.includes("All Clear")));
  assert.deepEqual(blocks.filter(block => block.type === "image"), [image]);
});

test("frontmost app and browser capabilities survive human-readable summaries", () => {
  for (const structured of [
    { apps: [{ pid: 1, active: true }, { pid: 2, active: false }] },
    { target_id: "opaque-target", tab_id: "opaque-tab", snapshot_id: "current", refs: ["button-ref"] },
  ]) {
    const blocks = resolveMcpResultContent({ content: [{ type: "text", text: "summary" }], structuredContent: structured });
    assert.deepEqual(JSON.parse(blocks[0].text), structured);
  }
});

test("text-only, image-only, empty and structured-only results retain their content", () => {
  for (const content of [[], [{ type: "text", text: "hello" }], [{ type: "image", mimeType: "image/png", data: "cG5n" }]]) {
    assert.deepEqual(resolveMcpResultContent({ content }), content);
    assert.deepEqual(resolveMcpResultContent({ content, structuredContent: null }), content);
  }
  assert.deepEqual(resolveMcpResultContent({ structuredContent: { ok: true } }), [{ type: "text", text: '{\n  "ok": true\n}' }]);
});
