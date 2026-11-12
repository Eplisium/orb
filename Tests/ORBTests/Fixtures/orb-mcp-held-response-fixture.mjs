// Offline held-response fixture. No files, network, credentials or children.
import readline from "node:readline";
const heldMethod = process.argv[2];
const marker = process.argv[3];
let held;
const lifetime = setTimeout(() => process.exit(0), 20000);
process.stdin.on("end", () => process.exit(0));
process.stdout.on("error", () => process.exit(0));
process.on("exit", () => clearTimeout(lifetime));
const text = value => ({ content: [{ type: "text", text: value }] });
function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function resultFor(method) {
  if (method === "initialize") return { protocolVersion: "2024-11-05", capabilities: { tools: {}, resources: {}, prompts: {} }, serverInfo: { name: marker, version: "1" } };
  if (method === "tools/list") return { tools: [{ name: "identity", description: marker, inputSchema: { type: "object", properties: {} } }] };
  if (method === "resources/list") return { resources: [{ uri: "fixture://identity", name: marker }] };
  if (method === "prompts/list") return { prompts: [{ name: "identity", description: marker }] };
  if (method === "resources/read") return { contents: [{ uri: "fixture://identity", text: marker }] };
  if (method === "prompts/get") return { messages: [{ role: "user", content: { type: "text", text: marker } }] };
  return text(marker);
}
readline.createInterface({ input: process.stdin }).on("line", line => {
  const { id, method, params } = JSON.parse(line);
  if (id === undefined) return;
  if (method === "tools/call" && params.name === "state") return reply(id, text(held?.method ?? ""));
  if (method === "tools/call" && params.name === "release") {
    reply(id, text("released"));
    if (held) {
      if (params.arguments?.fail) process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: held.id, error: { code: -32603, message: "held fixture failure" } }) + "\n");
      else reply(held.id, resultFor(held.method));
      held = undefined;
    }
    return;
  }
  if (method === heldMethod) { held = { id, method }; return; }
  reply(id, resultFor(method));
});
