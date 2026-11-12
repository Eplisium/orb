// Offline-only fixture for MCPBackendFixTests. No files, network, credentials,
// or subprocesses. Only the explicit ORB_MCP_FIXTURE_* variables are read.
import { randomUUID } from "node:crypto";

const instance = randomUUID();
const argumentMarker = process.argv[2] ?? "argument-A";
const environmentMarker = process.env.ORB_MCP_FIXTURE_MARKER ?? "environment-A";
const identity = { instance, argumentMarker, environmentMarker };
const extraTool = process.env.ORB_MCP_FIXTURE_LONG_TOOL;
const label = `${argumentMarker}/${environmentMarker}`;
let buffer = "";
let releaseTimer;
let stalled = false;
let executionCount = 0;

// A failed test/host cannot leave this mock running indefinitely. The stall
// itself is released by a DIFFERENT timer, before the lifetime watchdog.
const lifetime = setTimeout(() => process.exit(0), 12000);
process.stdin.on("end", () => process.exit(0));
process.stdin.on("error", () => process.exit(0));
process.stdout.on("error", () => process.exit(0));
process.on("exit", () => {
  clearTimeout(lifetime);
  clearTimeout(releaseTimer);
});

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function text(id, value) {
  reply(id, { content: [{ type: "text", text: value }] });
}
function handle(message) {
  const { id, method, params } = message;
  if (id === undefined) {
    if (method === "notifications/record_execution") executionCount += 1;
    return;
  }
  if (method === "initialize") {
    reply(id, {
      protocolVersion: "2024-11-05", capabilities: { tools: {} },
      serverInfo: { name: "orb-backend-fix-fixture", version: "1" },
    });
  } else if (method === "tools/list") {
    reply(id, { tools: ["identity", "arm_stall", "large_payload", ...(extraTool ? [extraTool] : [])].map(name => ({
      name, description: label, inputSchema: { type: "object", properties: {} },
    })) });
  } else if (method === "tools/call" && (params?.name === "identity" || (extraTool && params?.name === extraTool))) {
    text(id, JSON.stringify(identity));
  } else if (method === "tools/call" && params?.name === "arm_stall") {
    // Pause BEFORE acknowledging. Awaiting this reply proves the next write
    // encounters a reader which is not consuming stdin. No blocking sleep:
    // the independent release timer can always drain the full pipe again.
    process.stdin.pause();
    stalled = true;
    releaseTimer = setTimeout(() => {
      stalled = false;
      process.stdin.resume();
      drain();
    }, 3000);
    text(id, "stdin-paused-for-3000ms");
  } else if (method === "tools/call" && params?.name === "record_execution") {
    executionCount += 1;
    text(id, "recorded");
  } else if (method === "tools/call" && params?.name === "execution_count") {
    text(id, String(executionCount));
  } else if (method === "tools/call" && params?.name === "large_payload") {
    // Let cancellation queued on the actor win after the buggy write finally
    // unblocks; otherwise a fast success reply could obscure the latency bug.
    setTimeout(() => text(id, "fixture-payload-drained"), 250);
  } else {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0", id, error: { code: -32601, message: "fixture method missing" },
    }) + "\n");
  }
}
function drain() {
  while (!stalled) {
    const index = buffer.indexOf("\n");
    if (index === -1) break;
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (line.length) handle(JSON.parse(line));
  }
}
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { buffer += chunk; drain(); });
