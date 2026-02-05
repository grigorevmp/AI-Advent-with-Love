import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

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
const WORKSPACE_PATH = process.cwd();
const SEARCH_IGNORED_DIRS = new Set([".git", "node_modules", ".venv"]);
const SEARCH_EXTENSIONS = new Set([".md", ".txt", ".json", ".js", ".mjs", ".py"]);

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
 * Checks that the target path stays inside the workspace.
 * @param {string} absolutePath
 * @returns {boolean}
 */
function isInsideWorkspace(absolutePath) {
  const rel = path.relative(WORKSPACE_PATH, absolutePath);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

/**
 * Recursively collects searchable files from workspace.
 * @param {string} dirPath
 * @returns {Promise<string[]>}
 */
async function collectSearchFiles(dirPath) {
  /** @type {string[]} */
  const out = [];
  const entries = await fs.readdir(dirPath, { withFileTypes: true });

  for (const entry of entries) {
    if (!entry) continue;
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      if (SEARCH_IGNORED_DIRS.has(entry.name)) continue;
      out.push(...(await collectSearchFiles(fullPath)));
      continue;
    }
    if (!entry.isFile()) continue;
    const ext = path.extname(entry.name).toLowerCase();
    if (SEARCH_EXTENSIONS.has(ext)) out.push(fullPath);
  }

  return out;
}

/**
 * Searches local workspace files by text query.
 * @param {string} query
 * @param {number} limit
 * @param {boolean} caseSensitive
 * @param {string[]} selectedFiles
 * @returns {Promise<{query:string,totalMatches:number,results:any[],combinedText:string,missingFiles:string[]}>}
 */
async function searchDocs(query, limit, caseSensitive, selectedFiles = []) {
  const normalizedQuery = caseSensitive ? query : query.toLowerCase();
  let files = [];
  const missingFiles = [];
  if (Array.isArray(selectedFiles) && selectedFiles.length) {
    for (const rel of selectedFiles) {
      if (typeof rel !== "string" || !rel.trim()) continue;
      const absolute = path.resolve(WORKSPACE_PATH, rel.trim());
      if (!isInsideWorkspace(absolute)) {
        missingFiles.push(rel.trim());
        continue;
      }
      files.push(absolute);
    }
  } else {
    files = await collectSearchFiles(WORKSPACE_PATH);
  }

  /** @type {Array<{path:string,matches:number,snippet:string}>} */
  const results = [];
  let totalMatches = 0;

  for (const filePath of files) {
    let content = "";
    try {
      content = await fs.readFile(filePath, "utf8");
    } catch {
      missingFiles.push(path.relative(WORKSPACE_PATH, filePath));
      continue;
    }

    const hasQuery = Boolean(query);
    let matches = 1;
    let snippet = content.slice(0, 240).replace(/\s+/g, " ").trim();

    if (hasQuery) {
      const haystack = caseSensitive ? content : content.toLowerCase();
      if (!haystack.includes(normalizedQuery)) continue;

      let index = haystack.indexOf(normalizedQuery);
      let firstIndex = index;
      matches = 0;
      while (index !== -1) {
        matches += 1;
        index = haystack.indexOf(normalizedQuery, index + normalizedQuery.length);
      }

      const start = Math.max(0, firstIndex - 120);
      const end = Math.min(content.length, firstIndex + query.length + 120);
      snippet = content.slice(start, end).replace(/\s+/g, " ").trim();
    }

    totalMatches += matches;
    results.push({
      path: path.relative(WORKSPACE_PATH, filePath),
      matches,
      snippet,
    });
  }

  results.sort((a, b) => b.matches - a.matches || a.path.localeCompare(b.path));
  const top = results.slice(0, Math.min(Math.max(limit, 1), 20));
  const combinedParts = [];
  for (const item of top) {
    const absolute = path.resolve(WORKSPACE_PATH, item.path);
    let content = "";
    try {
      content = await fs.readFile(absolute, "utf8");
    } catch {
      content = item.snippet;
    }
    const excerpt = query ? item.snippet : content.slice(0, 4000).trim();
    combinedParts.push(`File: ${item.path}\nContent: ${excerpt}`);
  }
  const combinedText = combinedParts.join("\n\n");

  return { query, totalMatches, results: top, combinedText, missingFiles };
}

/**
 * Creates a short extractive summary from text.
 * @param {string} text
 * @param {number} maxSentences
 * @param {"low"|"medium"|"high"} compressionLevel
 * @returns {string}
 */
function summarizeText(text, maxSentences, compressionLevel = "medium") {
  const clean = String(text || "").replace(/\s+/g, " ").trim();
  if (!clean) return "";
  const sentences = clean.match(/[^.!?]+[.!?]?/g) || [clean];
  const level = ["low", "medium", "high"].includes(compressionLevel) ? compressionLevel : "medium";
  const ratio = level === "low" ? 0.6 : level === "high" ? 0.2 : 0.35;
  const byLevel = Math.max(1, Math.ceil(sentences.length * ratio));
  const byMax = Math.min(Math.max(maxSentences, 1), 10);
  const target = Math.min(byLevel, byMax);
  const limited = sentences.slice(0, target);
  return limited.map((s) => s.trim()).join(" ");
}

/**
 * Runs a process, writes text to stdin, and captures output.
 * @param {string} command
 * @param {string[]} args
 * @param {string} input
 * @param {number} timeoutMs
 * @returns {Promise<{stdout:string,stderr:string,exitCode:number}>}
 */
async function runProcessWithInput(command, args, input, timeoutMs = 15_000) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let finished = false;

    const timeout = setTimeout(() => {
      if (!finished) child.kill("SIGTERM");
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });

    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    child.on("error", (err) => {
      clearTimeout(timeout);
      if (finished) return;
      finished = true;
      reject(err);
    });

    child.on("close", (code) => {
      clearTimeout(timeout);
      if (finished) return;
      finished = true;
      resolve({ stdout, stderr, exitCode: typeof code === "number" ? code : 1 });
    });

    child.stdin.write(input);
    child.stdin.end();
  });
}

/**
 * Runs a process and captures output without stdin payload.
 * @param {string} command
 * @param {string[]} args
 * @param {number} timeoutMs
 * @returns {Promise<{stdout:string,stderr:string,exitCode:number}>}
 */
async function runProcess(command, args, timeoutMs = 10_000) {
  return await runProcessWithInput(command, args, "", timeoutMs);
}

/**
 * Checks if Docker daemon is reachable.
 * @returns {Promise<boolean>}
 */
async function isDockerReady() {
  try {
    const probe = await runProcess("docker", ["ps"], 5000);
    return probe.exitCode === 0;
  } catch {
    return false;
  }
}

/**
 * Attempts to start Docker app/daemon and waits until it is ready.
 * @returns {Promise<boolean>}
 */
async function tryStartDockerDaemon() {
  if (await isDockerReady()) return true;

  const attempts = process.platform === "darwin"
    ? [
        ["open", ["-a", "OrbStack"]],
        ["open", ["-a", "Docker"]],
      ]
    : [["docker", ["context", "ls"]]];

  for (const [command, args] of attempts) {
    try {
      await runProcess(command, args, 4000);
    } catch {
      // Ignore and continue probing readiness.
    }
  }

  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (await isDockerReady()) return true;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  return false;
}

/**
 * Runs compressed text in Docker or in a local emulator.
 * @param {string} text
 * @param {"auto"|"docker"|"emulator"} runtime
 * @param {string} image
 * @param {string} command
 * @returns {Promise<{runtime:string,stdout:string,stderr:string,exitCode:number}>}
 */
async function runInRuntime(text, runtime, image, command = "") {
  const payload = String(text || "");
  const normalizedRuntime = ["auto", "docker", "emulator"].includes(runtime) ? runtime : "auto";
  const normalizedImage = typeof image === "string" && image.trim() ? image.trim() : "alpine:3.20";
  const normalizedCommand = typeof command === "string" && command.trim()
    ? command.trim()
    : "input=\"$(cat)\"; echo \"[docker] bytes: ${#input}\"; echo \"[docker] text:\"; printf \"%s\\n\" \"$input\"";

  if (normalizedRuntime !== "emulator") {
    try {
      const ready = await tryStartDockerDaemon();
      if (!ready) {
        if (normalizedRuntime === "docker") {
          return {
            runtime: "docker",
            stdout: "",
            stderr: "Docker daemon is not available after start attempt.",
            exitCode: 1,
          };
        }
        return {
          runtime: "emulator",
          stdout: `[emulator fallback] docker daemon is unavailable\n${payload}`,
          stderr: "",
          exitCode: 0,
        };
      }

      const dockerArgs = [
        "run",
        "--rm",
        "-i",
        normalizedImage,
        "sh",
        "-lc",
        normalizedCommand,
      ];
      const result = await runProcessWithInput("docker", dockerArgs, payload);
      if (result.exitCode === 0) {
        return { runtime: "docker", ...result };
      }
      if (normalizedRuntime === "docker") {
        return { runtime: "docker", ...result };
      }
      return {
        runtime: "emulator",
        stdout: `[emulator fallback] docker exit code ${result.exitCode}\n${payload}`,
        stderr: result.stderr,
        exitCode: 0,
      };
    } catch (err) {
      if (normalizedRuntime === "docker") throw err;
    }
  }

  return {
    runtime: "emulator",
    stdout: `[emulator] bytes: ${Buffer.byteLength(payload, "utf8")}\n[emulator] text:\n${payload}`,
    stderr: "",
    exitCode: 0,
  };
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
      {
        name: "searchDocs",
        description: "Search text in local workspace files and return matched snippets.",
        inputSchema: {
          type: "object",
          properties: {
            query: { type: "string", minLength: 1 },
            files: { type: "array", items: { type: "string", minLength: 1 }, minItems: 1 },
            limit: { type: "number", minimum: 1, maximum: 20 },
            caseSensitive: { type: "boolean" },
          },
          additionalProperties: false,
        },
      },
      {
        name: "summarize",
        description: "Build a short summary from provided text.",
        inputSchema: {
          type: "object",
          properties: {
            text: { type: "string", minLength: 1 },
            maxSentences: { type: "number", minimum: 1, maximum: 10 },
            compressionLevel: { type: "string", enum: ["low", "medium", "high"] },
          },
          required: ["text"],
          additionalProperties: false,
        },
      },
      {
        name: "saveToFile",
        description: "Save text into a workspace file path.",
        inputSchema: {
          type: "object",
          properties: {
            filePath: { type: "string", minLength: 1 },
            content: { type: "string" },
            append: { type: "boolean" },
          },
          required: ["filePath", "content"],
          additionalProperties: false,
        },
      },
      {
        name: "runInRuntime",
        description: "Run text in Docker (or emulator fallback) and return command output.",
        inputSchema: {
          type: "object",
          properties: {
            text: { type: "string", minLength: 1 },
            runtime: { type: "string", enum: ["auto", "docker", "emulator"] },
            image: { type: "string", minLength: 1 },
            command: { type: "string", minLength: 1 },
          },
          required: ["text"],
          additionalProperties: false,
        },
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

  if (name === "searchDocs") {
    const query = typeof args?.query === "string" ? args.query.trim() : "";
    const files = Array.isArray(args?.files) ? args.files : [];
    const limit = typeof args?.limit === "number" ? args.limit : 5;
    const caseSensitive = Boolean(args?.caseSensitive);
    if (!query && files.length === 0) {
      return { content: [{ type: "text", text: "Error: query or files is required" }], isError: true };
    }

    const result = await searchDocs(query, limit, caseSensitive, files);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  }

  if (name === "summarize") {
    const text = typeof args?.text === "string" ? args.text : "";
    const maxSentences = typeof args?.maxSentences === "number" ? args.maxSentences : 3;
    const compressionLevel =
      typeof args?.compressionLevel === "string" ? args.compressionLevel : "medium";
    if (!text.trim()) return { content: [{ type: "text", text: "Error: text is required" }], isError: true };

    const summary = summarizeText(text, maxSentences, compressionLevel);
    return { content: [{ type: "text", text: JSON.stringify({ summary }) }] };
  }

  if (name === "saveToFile") {
    const filePathRaw = typeof args?.filePath === "string" ? args.filePath.trim() : "";
    const content = typeof args?.content === "string" ? args.content : "";
    const append = Boolean(args?.append);
    if (!filePathRaw) return { content: [{ type: "text", text: "Error: filePath is required" }], isError: true };

    const absolutePath = path.resolve(WORKSPACE_PATH, filePathRaw);
    if (!isInsideWorkspace(absolutePath)) {
      return { content: [{ type: "text", text: "Error: filePath must be inside workspace" }], isError: true };
    }

    await fs.mkdir(path.dirname(absolutePath), { recursive: true });
    if (append) {
      await fs.appendFile(absolutePath, content, "utf8");
    } else {
      await fs.writeFile(absolutePath, content, "utf8");
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            ok: true,
            filePath: path.relative(WORKSPACE_PATH, absolutePath),
            bytes: Buffer.byteLength(content, "utf8"),
            append,
          }),
        },
      ],
    };
  }

  if (name === "runInRuntime") {
    const text = typeof args?.text === "string" ? args.text : "";
    const runtime = typeof args?.runtime === "string" ? args.runtime : "auto";
    const image = typeof args?.image === "string" ? args.image : "alpine:3.20";
    const command = typeof args?.command === "string" ? args.command : "";
    if (!text.trim()) return { content: [{ type: "text", text: "Error: text is required" }], isError: true };

    try {
      const result = await runInRuntime(text, runtime, image, command);
      return { content: [{ type: "text", text: JSON.stringify(result) }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Error: failed to run runtime: ${String(err)}` }],
        isError: true,
      };
    }
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
