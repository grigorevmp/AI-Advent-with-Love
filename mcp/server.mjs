import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";

/**
 * Writes a log line to stderr without touching stdout.
 * StdIO MCP transport requires stdout to be reserved for protocol messages.
 * @param  {...any} args
 */
function logErr(...args) {
  process.stderr.write(args.map(String).join(" ") + "\n");
}

const TASKS_PATH = path.resolve(process.cwd(), "tasks.json");

const REMINDERS_PATH = path.resolve(process.cwd(), "reminders.json");

/**
 * Ensures that reminders.json exists and has a valid structure.
 * Called on server startup.
 */
async function ensureRemindersFile() {
  try {
    const raw = await fs.readFile(REMINDERS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.reminders)) {
      throw new Error("Invalid structure");
    }
  } catch {
    await fs.writeFile(
      REMINDERS_PATH,
      JSON.stringify({ reminders: [] }, null, 2),
      "utf8"
    );
  }
}

/**
 * Reads a JSON file and returns a fallback object on any error.
 * @param {string} filePath
 * @param {any} fallback
 * @returns {Promise<any>}
 */
async function readJson(filePath, fallback) {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

/**
 * Writes an object into a JSON file with stable formatting.
 * @param {string} filePath
 * @param {any} value
 * @returns {Promise<void>}
 */
async function writeJson(filePath, value) {
  await fs.writeFile(filePath, JSON.stringify(value, null, 2), "utf8");
}

/**
 * Loads tasks.json in a normalized shape.
 * @returns {Promise<{tasks: Array<{id:number,title:string,status:string}>}>}
 */
async function loadTasks() {
  const parsed = await readJson(TASKS_PATH, { tasks: [] });
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.tasks)) return { tasks: [] };
  return { tasks: parsed.tasks.filter(Boolean) };
}

/**
 * Persists tasks.json in a normalized shape.
 * @param {{tasks: any[]}} data
 * @returns {Promise<void>}
 */
async function saveTasks(data) {
  const normalized = { tasks: Array.isArray(data?.tasks) ? data.tasks : [] };
  await writeJson(TASKS_PATH, normalized);
}

/**
 * Loads reminders.json in a normalized shape.
 * @returns {Promise<{reminders: Array<any>}>}
 */
async function loadReminders() {
  const parsed = await readJson(REMINDERS_PATH, { reminders: [] });
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.reminders)) return { reminders: [] };
  return { reminders: parsed.reminders.filter(Boolean) };
}

/**
 * Persists reminders.json in a normalized shape.
 * @param {{reminders: any[]}} data
 * @returns {Promise<void>}
 */
async function saveReminders(data) {
  const normalized = { reminders: Array.isArray(data?.reminders) ? data.reminders : [] };
  await writeJson(REMINDERS_PATH, normalized);
}

/**
 * Builds a human-readable summary based on current tasks.
 * @returns {Promise<string>}
 */
async function buildTasksSummary() {
  const data = await loadTasks();
  const open = data.tasks.filter((t) => t && t.status === "open");
  const openCount = open.length;
  const titles = open.slice(0, 10).map((t) => `- ${t.title ?? "(no title)"}`).join("\n");
  const more = openCount > 10 ? `\n…и ещё ${openCount - 10}` : "";
  return `Открытых задач: ${openCount}\n${titles}${more}`.trim();
}

/**
 * Returns due reminders and advances their nextAt field.
 * @returns {Promise<Array<{id:number,title:string,summary:string,scheduledAt:string,nextAt:string}>>}
 */
async function pollDueReminders() {
  const now = Date.now();
  const store = await loadReminders();
  const due = [];

  for (const r of store.reminders) {
    if (!r) continue;
    const nextAt = typeof r.nextAt === "number" ? r.nextAt : 0;
    const everyMinutes = typeof r.everyMinutes === "number" ? r.everyMinutes : 0;
    if (everyMinutes <= 0) continue;

    if (nextAt <= now) {
      const summary = await buildTasksSummary();
      due.push({
        id: r.id,
        title: r.title ?? "reminder",
        summary,
        scheduledAt: new Date(nextAt).toISOString(),
        nextAt: new Date(now + everyMinutes * 60_000).toISOString(),
      });
      r.lastSentAt = now;
      r.nextAt = now + everyMinutes * 60_000;
    }
  }

  if (due.length) await saveReminders(store);
  return due;
}

const server = new Server(
  { name: "ai-advent-mcp", version: "1.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "tasks_count_open",
        description: "Count tasks with status=open from local tasks.json",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      },
      {
        name: "tasks_add",
        description: "Add a new task into local tasks.json. Returns created task.",
        inputSchema: {
          type: "object",
          properties: { title: { type: "string", minLength: 1 } },
          required: ["title"],
          additionalProperties: false,
        },
      },
      {
        name: "reminders_add",
        description: "Create a periodic reminder that returns task summary when it is due.",
        inputSchema: {
          type: "object",
          properties: {
            title: { type: "string", minLength: 1 },
            everyMinutes: { type: "number", minimum: 0.1 },
          },
          required: ["title", "everyMinutes"],
          additionalProperties: false,
        },
      },
      {
        name: "reminders_list",
        description: "List configured reminders.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      },
      {
        name: "reminders_poll",
        description: "Return due reminders with a summary and advance their schedule.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      },
      {
        name: "reminders_clear",
        description: "Remove all reminders.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      },
      {
        name: "summary_tasks",
        description: "Build a current summary over tasks.json.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;

  if (name === "tasks_count_open") {
    const data = await loadTasks();
    const openCount = data.tasks.filter((t) => t && t.status === "open").length;
    return { content: [{ type: "text", text: String(openCount) }] };
  }

  if (name === "tasks_add") {
    const title = typeof args?.title === "string" ? args.title.trim() : "";
    if (!title) return { content: [{ type: "text", text: "Error: title is required" }], isError: true };

    const data = await loadTasks();
    const maxId = data.tasks.reduce((m, t) => Math.max(m, typeof t?.id === "number" ? t.id : 0), 0);
    const newTask = { id: maxId + 1, title, status: "open" };
    data.tasks.push(newTask);
    await saveTasks(data);
    return { content: [{ type: "text", text: JSON.stringify(newTask) }] };
  }

  if (name === "summary_tasks") {
    const summary = await buildTasksSummary();
    return { content: [{ type: "text", text: summary }] };
  }

  if (name === "reminders_add") {
    const title = typeof args?.title === "string" ? args.title.trim() : "";
    const everyMinutes = typeof args?.everyMinutes === "number" ? args.everyMinutes : 0;
    if (!title) return { content: [{ type: "text", text: "Error: title is required" }], isError: true };
    if (!(everyMinutes > 0)) return { content: [{ type: "text", text: "Error: everyMinutes must be > 0" }], isError: true };

    const store = await loadReminders();
    const maxId = store.reminders.reduce((m, r) => Math.max(m, typeof r?.id === "number" ? r.id : 0), 0);
    const now = Date.now();
    const reminder = {
      id: maxId + 1,
      title,
      everyMinutes,
      createdAt: now,
      nextAt: now + everyMinutes * 60_000,
      lastSentAt: null,
    };
    store.reminders.push(reminder);
    await saveReminders(store);
    return { content: [{ type: "text", text: JSON.stringify(reminder) }] };
  }

  if (name === "reminders_list") {
    const store = await loadReminders();
    return { content: [{ type: "text", text: JSON.stringify(store) }] };
  }

  if (name === "reminders_clear") {
    await saveReminders({ reminders: [] });
    return { content: [{ type: "text", text: "ok" }] };
  }

  if (name === "reminders_poll") {
    const due = await pollDueReminders();
    return { content: [{ type: "text", text: JSON.stringify({ due }) }] };
  }

  return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
});

async function main() {
  const transport = new StdioServerTransport();
  await ensureRemindersFile();
  await server.connect(transport);
  logErr("MCP server started:", "ai-advent-mcp (stdio)");
  logErr("Tasks file:", TASKS_PATH);
  logErr("Reminders file:", REMINDERS_PATH);
}

main().catch((e) => {
  logErr("Fatal:", e?.stack || String(e));
  process.exit(1);
});
