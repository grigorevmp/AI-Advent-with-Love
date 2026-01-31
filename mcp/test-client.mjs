import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import {
  ListToolsResultSchema,
  CallToolResultSchema,
} from "@modelcontextprotocol/sdk/types.js";

async function main() {
  const transport = new StdioClientTransport({
    command: "node",
    args: ["server.mjs"],
  });

  const client = new Client(
    { name: "day12-test-client", version: "1.0.0" },
    { capabilities: {} }
  );

  try {
    await client.connect(transport);

    const tools = await client.request(
      { method: "tools/list" },
      ListToolsResultSchema
    );

    console.log("TOOLS:");
    for (const t of tools.tools ?? []) console.log("-", t.name);

    const countRes = await client.request(
      { method: "tools/call", params: { name: "tasks_count_open", arguments: {} } },
      CallToolResultSchema
    );

    console.log("\nOPEN COUNT RESULT:");
    console.log(countRes.content?.map((c) => c.text).join("\n") ?? "(no content)");

    const addRes = await client.request(
      {
        method: "tools/call",
        params: { name: "tasks_add", arguments: { title: "Новая задача из теста" } },
      },
      CallToolResultSchema
    );

    console.log("\nADD RESULT:");
    console.log(addRes.content?.map((c) => c.text).join("\n") ?? "(no content)");

    const countRes2 = await client.request(
      { method: "tools/call", params: { name: "tasks_count_open", arguments: {} } },
      CallToolResultSchema
    );

    console.log("\nOPEN COUNT AFTER ADD:");
    console.log(countRes2.content?.map((c) => c.text).join("\n") ?? "(no content)");
  } finally {
    await transport.close();
  }
}

main().catch((e) => {
  console.error("Failed:", e);
  process.exit(1);
});
