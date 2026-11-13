// M03 only: offline stdio peer with explicit startup barriers. No network,
// files, credentials, children, or timed release of a held response.
import readline from "node:readline";

const heldMethod = process.argv[2];
let held;
let initializeCount = 0;
let initializedCount = 0;
const lifetime = setTimeout(() => process.exit(70), 20000);
process.stdin.on("end", () => process.exit(0));
process.stdout.on("error", () => process.exit(0));
process.on("exit", () => clearTimeout(lifetime));

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function failure(id, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id,
    error: { code: -32603, message } }) + "\n");
}
function resultFor(method) {
  switch (method) {
    case "initialize": return {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {}, resources: {}, prompts: {} },
      serverInfo: { name: "m03-ready", version: "1" }
    };
    case "tools/list": return { tools: [{ name: "identity", description: "m03-ready",
      inputSchema: { type: "object", properties: {} } }] };
    case "resources/list": return { resources: [{ uri: "fixture://m03", name: "m03-resource" }] };
    case "prompts/list": return { prompts: [{ name: "m03-prompt" }] };
    default: return { content: [{ type: "text", text: "m03-ready" }] };
  }
}

readline.createInterface({ input: process.stdin }).on("line", line => {
  let request;
  try { request = JSON.parse(line); } catch { process.exit(71); }
  const { id, method, params } = request;
  if (method === "notifications/initialized") { initializedCount++; return; }
  if (method === "notifications/m03-release") {
    const pending = held;
    held = undefined; // clear before replying; never overwrite another request
    if (!pending) return;
    if (params?.fail) failure(pending.id, "m03 held startup failure");
    else reply(pending.id, resultFor(pending.method));
    return;
  }
  if (id === undefined) return;
  // A test-only control RPC intentionally works before MCP initialization.
  if (method === "tools/call" && params?.name === "m03-state") {
    reply(id, { content: [{ type: "text", text: JSON.stringify({
      held: held?.method ?? "", initializeCount, initializedCount
    }) }] });
    return;
  }
  if (method === "initialize") initializeCount++;
  if (method === heldMethod) {
    if (held) failure(id, "duplicate startup request while barrier held");
    else held = { id, method };
    return;
  }
  reply(id, resultFor(method));
});
