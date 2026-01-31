import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ListToolsResultSchema } from "@modelcontextprotocol/sdk/types.js";

/**
 * День 11 — минимальный MCP-клиент:
 * 1) Поднимает MCP-сервер как subprocess (stdio)
 * 2) Коннектится
 * 3) Дёргает tools/list
 * 4) Печатает список tool.name
 *
 * Сервер: @modelcontextprotocol/server-everything (тестовый сервер для клиентов)
 */
async function main() {
  const transport = new StdioClientTransport({
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-everything"],
  });

  const client = new Client(
    { name: "day11-client", version: "1.0.0" },
    { capabilities: {} }
  );

  try {
    await client.connect(transport);

    const response = await client.request(
      { method: "tools/list" },
      ListToolsResultSchema
    );

    const tools = response.tools ?? [];
    console.log(`MCP tools count: ${tools.length}`);
    for (const t of tools) {
      console.log(`- ${t.name}`);
    }
  } finally {
    // аккуратно закрываем transport, чтобы subprocess завершился
    await transport.close();
  }
}

main().catch((err) => {
  console.error("Failed:", err);
  process.exit(1);
});
