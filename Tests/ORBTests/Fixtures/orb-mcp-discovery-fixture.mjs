// Offline discovery cancellation fixture: no files, network or credentials.
import readline from "node:readline";
const heldMethod = process.argv[2];
const errorMode = process.argv[3] === "error";
let seen = "";
const lifetime = setTimeout(() => process.exit(0), 20000);
function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
process.stdin.on("end", () => process.exit(0));
process.stdout.on("error", () => process.exit(0));
process.on("exit", () => clearTimeout(lifetime));
readline.createInterface({ input: process.stdin }).on("line", line => {
  const { id, method, params } = JSON.parse(line);
  if (id === undefined) return;
  if (method === "initialize") {
    reply(id, { protocolVersion: "2024-11-05", capabilities: { tools: {}, resources: {}, prompts: {} }, serverInfo: { name: "discovery-fixture", version: "1" } });
  } else if (method === "tools/list") {
    reply(id, { tools: [{ name: "state", inputSchema: { type: "object", properties: {} } }] });
  } else if (method === "resources/list" || method === "prompts/list") {
    seen = method;
    if (method === heldMethod) {
      if (errorMode) process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "optional fixture error" } }) + "\n");
      // Otherwise hold the reply while still serving test-state RPCs.
    } else reply(id, method === "resources/list" ? { resources: [] } : { prompts: [] });
  } else if (method === "tools/call" && params.name === "state") {
    reply(id, { content: [{ type: "text", text: seen }] });
  }
});
