#!/usr/bin/env node
// Minimal stdio MCP server used to verify ORB's MCPConnection end-to-end.
// Speaks JSON-RPC 2.0 over newline-delimited stdin/stdout.

let buffer = "";

// Deliberately emit a non-JSON banner line on stdout first: real servers do
// this, and the client must skip it rather than choke.
process.stdout.write("mock-mcp starting up\n");

process.stdin.on("data", (chunk) => {
  buffer += chunk.toString();
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (line) handle(line);
  }
});

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function handle(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  const { id, method, params } = msg;

  if (method === "initialize") {
    return send({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {}, resources: {}, prompts: {} },
        serverInfo: { name: "mock-mcp", version: "0.1.0" },
      },
    });
  }

  if (method === "notifications/initialized") return; // notification, no reply

  if (method === "resources/list") {
    return send({
      jsonrpc: "2.0",
      id,
      result: {
        resources: [
          {
            uri: "mock://readme",
            name: "Readme",
            description: "Project readme",
            mimeType: "text/plain",
          },
          { uri: "mock://binary", name: "Binary blob", mimeType: "image/png" },
        ],
      },
    });
  }

  if (method === "resources/read") {
    const uri = params?.uri;
    if (uri === "mock://readme") {
      return send({
        jsonrpc: "2.0",
        id,
        result: {
          contents: [{ uri, mimeType: "text/plain", text: "ORB resource body" }],
        },
      });
    }
    if (uri === "mock://binary") {
      // Exercises the blob path: base64 must not be inlined verbatim.
      return send({
        jsonrpc: "2.0",
        id,
        result: {
          contents: [{ uri, mimeType: "image/png", blob: "iVBORw0KGgo=" }],
        },
      });
    }
    return send({
      jsonrpc: "2.0",
      id,
      error: { code: -32602, message: "unknown resource" },
    });
  }

  if (method === "prompts/list") {
    return send({
      jsonrpc: "2.0",
      id,
      result: {
        prompts: [
          {
            name: "greet",
            description: "Greet someone",
            arguments: [
              { name: "who", description: "Name", required: true },
              { name: "times", description: "Repeat count", required: false },
            ],
          },
        ],
      },
    });
  }

  if (method === "prompts/get") {
    const who = params?.arguments?.who ?? "world";
    const times = params?.arguments?.times ?? "1";
    return send({
      jsonrpc: "2.0",
      id,
      result: {
        messages: [
          {
            role: "user",
            content: { type: "text", text: `Hello ${who} x${times}` },
          },
        ],
      },
    });
  }

  if (method === "tools/list") {
    return send({
      jsonrpc: "2.0",
      id,
      result: {
        tools: [
          {
            name: "echo",
            description: "Echo a message back.",
            inputSchema: {
              type: "object",
              properties: {
                message: { type: "string" },
                // Nested + enum: proves schemas are not flattened.
                opts: {
                  type: "object",
                  properties: {
                    mode: { type: "string", enum: ["upper", "lower"] },
                  },
                },
              },
              required: ["message"],
            },
          },
          {
            name: "fail",
            description: "Always returns a tool error.",
            inputSchema: { type: "object", properties: {} },
          },
        ],
      },
    });
  }

  if (method === "tools/call") {
    const name = params?.name;
    const args = params?.arguments ?? {};
    if (name === "echo") {
      let text = String(args.message ?? "");
      const mode = args?.opts?.mode;
      if (mode === "upper") text = text.toUpperCase();
      if (mode === "lower") text = text.toLowerCase();
      return send({
        jsonrpc: "2.0",
        id,
        result: { content: [{ type: "text", text }] },
      });
    }
    if (name === "fail") {
      return send({
        jsonrpc: "2.0",
        id,
        result: { isError: true, content: [{ type: "text", text: "intentional failure" }] },
      });
    }
    return send({
      jsonrpc: "2.0",
      id,
      error: { code: -32602, message: `unknown tool ${name}` },
    });
  }

  send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
}
