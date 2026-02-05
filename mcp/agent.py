import argparse
import asyncio
import json
from contextlib import AsyncExitStack
from datetime import datetime, timezone
from pathlib import Path
import re
from typing import Any, Dict, List, Tuple

try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency: install python MCP SDK first, for example: pip install mcp"
    ) from exc


def content_to_text(result: Any) -> str:
    """Extract text payload from MCP call_tool response."""
    content = getattr(result, "content", None)
    if content is None and isinstance(result, dict):
        content = result.get("content")

    if not isinstance(content, list):
        return str(content or "")

    parts = []
    for item in content:
        if isinstance(item, dict):
            if item.get("type") == "text":
                parts.append(str(item.get("text", "")))
        else:
            item_type = getattr(item, "type", None)
            if item_type == "text":
                parts.append(str(getattr(item, "text", "")))

    return "\n".join(p for p in parts if p).strip()


def resolve_image_from_query(query: str, default_image: str) -> str:
    """Extract Docker image from query text. Supported: image=<name>, docker=<name>, image:<name>."""
    pattern = re.compile(r"(?:image|docker)\s*[:=]\s*([A-Za-z0-9._/\-:]+)", re.IGNORECASE)
    match = pattern.search(query or "")
    if match:
        image = (match.group(1) or "").strip()
        if image:
            return image

    # Free-form extraction: "в образе alpine:3.20", "образ ubuntu:24.04", "using image node:20-alpine"
    loose_patterns = [
        r"(?:образ(?:е)?|image)\s+([A-Za-z0-9._/\-:]+)",
        r"(?:в|на)\s+([A-Za-z0-9._/\-:]+)\s+(?:образе|контейнере)",
    ]
    for raw in loose_patterns:
        loose_match = re.search(raw, query or "", re.IGNORECASE)
        if loose_match:
            candidate = (loose_match.group(1) or "").strip(" ,.;:!?")
            if candidate and not candidate.lower().startswith(("docker", "докер")):
                return candidate

    # Last fallback: first token that looks like docker image with tag.
    token_match = re.search(r"\b([a-z0-9]+(?:[._/-][a-z0-9]+)*:[A-Za-z0-9._-]+)\b", (query or "").lower())
    if token_match:
        return token_match.group(1)
    return default_image


def resolve_command_from_query(query: str) -> str:
    """Extract runtime command from query text. Supported: cmd=<...>, command:<...>."""
    clause_tail = re.compile(
        r"\s*(?:,|;)\s*(?=(?:text|input|payload|текст|image|образ(?:е)?|runtime|mode)\b)",
        re.IGNORECASE,
    )

    pattern = re.compile(r"(?:cmd|command)\s*[:=]\s*(.+)$", re.IGNORECASE)
    match = pattern.search(query or "")
    if match:
        raw = (match.group(1) or "").strip()
        raw = clause_tail.split(raw, maxsplit=1)[0].strip()
        if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")):
            return raw[1:-1].strip()
        return raw

    # Free-form extraction: "команда wc -c", "запусти cat", "run with command: ..."
    loose = re.search(
        r"(?:команд[аоуы]?|command|run(?:\s+with)?)\s+(?:внутри\s+контейнера\s+)?(?:[:=])?\s*([`\"']?[^`\"']+[`\"']?)",
        query or "",
        re.IGNORECASE,
    )
    if loose:
        raw = (loose.group(1) or "").strip(" ,.;:!?")
        raw = clause_tail.split(raw, maxsplit=1)[0].strip(" ,.;:!?")
        if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")) or (
            raw.startswith("`") and raw.endswith("`")
        ):
            raw = raw[1:-1].strip()
        return raw
    return ""


def resolve_runtime_from_query(query: str, default_runtime: str) -> str:
    """Extract runtime from text. Supported: runtime=<auto|docker|emulator>, mode:<...>."""
    pattern = re.compile(r"(?:runtime|mode)\s*[:=]\s*(auto|docker|emulator)\b", re.IGNORECASE)
    match = pattern.search(query or "")
    if match:
        return match.group(1).lower()
    if re.search(r"\b(docker|докер)\b", query or "", re.IGNORECASE):
        return "docker"
    return default_runtime


def resolve_text_from_query(query: str) -> str:
    """Extract runtime payload from query text. Supported: text=<...>, input:<...>, текст:<...>."""
    clause_tail = re.compile(
        r"\s*(?:,|;)\s*(?=(?:cmd|command|команд[аоуы]?|runtime|mode|image|образ(?:е)?|docker)\b)",
        re.IGNORECASE,
    )

    pattern = re.compile(r"(?:text|input|payload|текст)\s*[:=]\s*(.+)$", re.IGNORECASE)
    match = pattern.search(query or "")
    if match:
        raw = (match.group(1) or "").strip()
        raw = clause_tail.split(raw, maxsplit=1)[0].strip()
        if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")):
            return raw[1:-1].strip()
        return raw

    # Free-form extraction: "с текстом 'hello world'" / "прогони текст hello"
    loose = re.search(
        r"(?:с\s+текстом|текстом|текст|text)\s+([`\"']?[^`\"']+[`\"']?)",
        query or "",
        re.IGNORECASE,
    )
    if loose:
        raw = (loose.group(1) or "").strip(" ,.;:!?")
        if (raw.startswith('"') and raw.endswith('"')) or (raw.startswith("'") and raw.endswith("'")) or (
            raw.startswith("`") and raw.endswith("`")
        ):
            raw = raw[1:-1].strip()
        return raw
    return ""


def is_help_request(query: str) -> bool:
    lowered = (query or "").lower()
    triggers = ("как работать", "help", "помощ", "инструкц", "что умеешь")
    return any(t in lowered for t in triggers) or lowered in {"/h", "/help"}


def is_server_discovery_request(query: str) -> bool:
    lowered = (query or "").lower()
    triggers = ("сервер", "tools", "инструмент", "какие команды", "список команд")
    return lowered.startswith("/tools") or any(t in lowered for t in triggers)


def is_runtime_request(query: str) -> bool:
    lowered = (query or "").lower().strip()
    if lowered.startswith("/docker"):
        return True
    if "docker" in lowered or "докер" in lowered:
        return True
    if re.search(r"(запусти|подними|run|start).*(docker|докер)", lowered):
        return True
    if re.search(r"(в\s+контейнере|через\s+контейнер|в\s+docker)", lowered):
        return True
    return bool(re.search(r"(runtime|mode|image|docker|cmd|command)\s*[:=]", lowered))


def parse_call_command(user_text: str) -> Tuple[str, Dict[str, Any]]:
    """Parse '/call toolName {json}'. Returns (tool_name, args)."""
    payload = user_text[len("/call") :].strip()
    if not payload:
        raise ValueError("Usage: /call <tool_name> <json_args>")

    parts = payload.split(maxsplit=1)
    tool_name = parts[0].strip()
    if not tool_name:
        raise ValueError("Usage: /call <tool_name> <json_args>")

    if len(parts) == 1:
        return tool_name, {}

    raw_json = parts[1].strip()
    if not raw_json:
        return tool_name, {}

    try:
        parsed = json.loads(raw_json)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON arguments: {exc}") from exc

    if not isinstance(parsed, dict):
        raise ValueError("JSON arguments must be an object")

    return tool_name, parsed


def resolve_summary_query_from_text(query: str) -> str:
    """Extract optional summary topic/query from chat text."""
    patterns = [
        re.compile(r"(?:query|поиск)\s*[:=]\s*([A-Za-z0-9А-Яа-я._/\-]+)", re.IGNORECASE),
        re.compile(r"(?:по|о|про)\s+(?:групп[еы]|теме)\s+([A-Za-z0-9А-Яа-я._/\-]+)", re.IGNORECASE),
    ]
    for pattern in patterns:
        match = pattern.search(query or "")
        if match:
            topic = (match.group(1) or "").strip(" ,.;:!?")
            if topic:
                return topic
    return ""


def is_summary_request(query: str) -> bool:
    lowered = (query or "").lower()
    triggers = ("суммар", "summary", "summarize", "резюм", "кратк")
    return any(token in lowered for token in triggers)


def resolve_summary_output_path_from_text(query: str, default_output_path: str) -> str:
    """Extract output path from chat text: 'в файл x.txt', 'out=x.txt', 'output: x.txt'."""
    patterns = [
        re.compile(r"(?:out|output|filePath)\s*[:=]\s*['\"]?([A-Za-z0-9_./\-]+\.[A-Za-z0-9_-]+)['\"]?", re.IGNORECASE),
        re.compile(r"(?:в|into)\s+файл\s+['\"]?([A-Za-z0-9_./\-]+\.[A-Za-z0-9_-]+)['\"]?", re.IGNORECASE),
        re.compile(r"(?:в|into)\s+['\"]?([A-Za-z0-9_./\-]+\.[A-Za-z0-9_-]+)['\"]?", re.IGNORECASE),
        re.compile(r"(?:save\s+to)\s+['\"]?([A-Za-z0-9_./\-]+\.[A-Za-z0-9_-]+)['\"]?", re.IGNORECASE),
    ]
    for pattern in patterns:
        match = pattern.search(query or "")
        if match:
            path_value = (match.group(1) or "").strip()
            if path_value:
                return path_value
    return default_output_path


def resolve_summary_files_from_text(query: str, output_path: str, default_files: List[str]) -> List[str]:
    """Extract input files from chat text."""
    file_token = re.compile(r"[A-Za-z0-9_./\-]+\.[A-Za-z0-9_-]+")

    scoped_patterns = [
        re.compile(r"(?:из\s+файл(?:а|ов)?|из\s+файла|files?)\s+(.+?)(?=(?:\s+(?:в\s+файл|в\s+[A-Za-z0-9_./\-]+\.[A-Za-z0-9_-]+|по\s+\d+\s+(?:предлож|строч)|по\s+(?:групп[еы]|теме)|$)))", re.IGNORECASE),
    ]
    for pattern in scoped_patterns:
        match = pattern.search(query or "")
        if not match:
            continue
        scoped = match.group(1) or ""
        matches = [item.strip() for item in file_token.findall(scoped) if item.strip()]
        if matches:
            deduped = []
            seen = set()
            for item in matches:
                if item == output_path or item in seen:
                    continue
                seen.add(item)
                deduped.append(item)
            if deduped:
                return deduped

    all_files = [item.strip() for item in file_token.findall(query or "") if item.strip()]
    if not all_files:
        return default_files

    deduped = []
    seen = set()
    for item in all_files:
        if item == output_path or item in seen:
            continue
        seen.add(item)
        deduped.append(item)
    return deduped or default_files


def resolve_summary_sentences_from_text(query: str, default_sentences: int) -> int:
    """Extract max sentence count from text: 'по 3 предложения', 'sentences=4'."""
    patterns = [
        re.compile(r"(?:sentences?|предложен\w*)\s*[:=]?\s*(\d+)", re.IGNORECASE),
        re.compile(r"(?:по|в|до|на)\s*(\d+)\s*(?:предложен\w*|sentences?)", re.IGNORECASE),
        re.compile(r"\b(\d+)\s*(?:предложен\w*|sentences?)", re.IGNORECASE),
        re.compile(r"(?:по|в|до|на)\s*(\d+)\s*(?:строк\w*|строч\w*)", re.IGNORECASE),
        re.compile(r"\b(\d+)\s*(?:строк\w*|строч\w*)", re.IGNORECASE),
    ]
    for pattern in patterns:
        match = pattern.search(query or "")
        if not match:
            continue
        try:
            value = int((match.group(1) or "").strip())
        except ValueError:
            continue
        return min(max(value, 1), 10)
    return default_sentences


def resolve_summary_compression_from_text(query: str, default_compression: str) -> str:
    """Extract compression level from text."""
    match = re.search(
        r"(?:compression|compress|компресс(?:ия|ии)?|сжатие)\s*[:=]?\s*(low|medium|high|низк\w*|средн\w*|высок\w*)",
        query or "",
        re.IGNORECASE,
    )
    if not match:
        return default_compression
    raw = (match.group(1) or "").lower()
    if raw.startswith("low") or raw.startswith("низк"):
        return "low"
    if raw.startswith("high") or raw.startswith("высок"):
        return "high"
    return "medium"


def parse_tools_from_server_source(server_path: str) -> List[Tuple[str, str]]:
    try:
        source = Path(server_path).read_text(encoding="utf-8")
    except OSError:
        return []

    pattern = re.compile(
        r'name:\s*"(?P<name>[A-Za-z0-9_:-]+)"\s*,\s*description:\s*"(?P<desc>[^"]+)"',
        re.MULTILINE,
    )
    seen = set()
    tools: List[Tuple[str, str]] = []
    for match in pattern.finditer(source):
        name = match.group("name").strip()
        desc = match.group("desc").strip()
        if not name or name in seen:
            continue
        seen.add(name)
        tools.append((name, desc))
    return tools


class MCPPipelineAgent:
    """MCP agent with pipeline mode and interactive tool dialogue."""

    def __init__(self, server_path: str):
        self.server_path = server_path
        self.exit_stack = AsyncExitStack()
        self.session: ClientSession | None = None

    async def connect(self) -> None:
        params = StdioServerParameters(command="node", args=[self.server_path])
        read_stream, write_stream = await self.exit_stack.enter_async_context(stdio_client(params))
        self.session = await self.exit_stack.enter_async_context(ClientSession(read_stream, write_stream))
        await self.session.initialize()

    async def close(self) -> None:
        await self.exit_stack.aclose()

    async def call_tool(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        if self.session is None:
            raise RuntimeError("MCP session is not connected")

        result = await self.session.call_tool(name, arguments)
        text = content_to_text(result)
        is_error = bool(getattr(result, "isError", False) or getattr(result, "is_error", False))
        if is_error:
            raise RuntimeError(f"Tool {name} failed: {text}")

        try:
            return json.loads(text) if text else {}
        except json.JSONDecodeError:
            return {"text": text}

    async def get_tools(self) -> List[Tuple[str, str]]:
        if self.session is None:
            raise RuntimeError("MCP session is not connected")

        tools: List[Tuple[str, str]] = []
        list_tools_method = getattr(self.session, "list_tools", None)
        if callable(list_tools_method):
            try:
                raw = await list_tools_method()
                raw_tools = getattr(raw, "tools", None)
                if raw_tools is None and isinstance(raw, dict):
                    raw_tools = raw.get("tools")
                if isinstance(raw_tools, list):
                    for item in raw_tools:
                        if isinstance(item, dict):
                            name = str(item.get("name", "")).strip()
                            desc = str(item.get("description", "")).strip()
                        else:
                            name = str(getattr(item, "name", "")).strip()
                            desc = str(getattr(item, "description", "")).strip()
                        if name:
                            tools.append((name, desc))
            except Exception:
                tools = []

        if tools:
            return tools
        return parse_tools_from_server_source(self.server_path)

    async def run_chain(
        self,
        query: str,
        input_files: List[str],
        output_path: str,
        limit: int,
        max_sentences: int,
        compression_level: str,
        runtime: str,
        docker_image: str,
    ) -> Dict[str, Any]:
        resolved_image = resolve_image_from_query(query, docker_image)
        resolved_command = resolve_command_from_query(query)
        search_payload: Dict[str, Any] = {"limit": limit}
        if query:
            search_payload["query"] = query
        if input_files:
            search_payload["files"] = input_files

        search_result = await self.call_tool("searchDocs", search_payload)

        combined_text = str(search_result.get("combinedText", "")).strip()
        if not combined_text:
            raise RuntimeError("searchDocs returned no matches")
        missing_files = search_result.get("missingFiles", [])

        summarize_result = await self.call_tool(
            "summarize",
            {
                "text": combined_text,
                "maxSentences": max_sentences,
                "compressionLevel": compression_level,
            },
        )
        summary = str(summarize_result.get("summary", "")).strip()
        if not summary:
            raise RuntimeError("summarize returned empty summary")
        runtime_result = await self.call_tool(
            "runInRuntime",
            {
                "text": summary,
                "runtime": runtime,
                "image": resolved_image,
                "command": resolved_command,
            },
        )

        now = datetime.now(timezone.utc).isoformat()
        report = (
            f"Query: {query}\n"
            f"InputFiles: {', '.join(input_files) if input_files else '(workspace scan)'}\n"
            f"MissingFiles: {', '.join(missing_files) if missing_files else '(none)'}\n"
            f"CompressionLevel: {compression_level}\n"
            f"RuntimeRequested: {runtime}\n"
            f"RuntimeUsed: {runtime_result.get('runtime', 'unknown')}\n"
            f"DockerImage: {resolved_image}\n"
            f"RuntimeCommand: {resolved_command or '(default)'}\n"
            f"CreatedAtUTC: {now}\n"
            f"TotalMatches: {search_result.get('totalMatches', 0)}\n\n"
            f"Summary:\n{summary}\n"
            f"\nRuntimeOutput:\n{runtime_result.get('stdout', '')}\n"
            f"\nRuntimeError:\n{runtime_result.get('stderr', '')}\n"
            f"\nSourceExtract:\n{combined_text}\n"
        )

        save_result = await self.call_tool(
            "saveToFile",
            {
                "filePath": output_path,
                "content": report,
                "append": False,
            },
        )

        return {
            "query": query,
            "summary": summary,
            "saved": save_result,
            "runtime": runtime_result,
            "dockerImage": resolved_image,
            "runtimeCommand": resolved_command,
            "search": {
                "totalMatches": search_result.get("totalMatches", 0),
                "results": search_result.get("results", []),
            },
        }

    async def chat_loop(
        self,
        input_files: List[str],
        output_path: str,
        limit: int,
        max_sentences: int,
        compression_level: str,
        runtime: str,
        docker_image: str,
    ) -> None:
        print("Chat mode. Enter request text (or /help, /exit).")
        while True:
            user_text = (await asyncio.to_thread(input, "YOU> ")).strip()
            if not user_text:
                continue
            if user_text.lower() in {"/exit", "exit", "quit", "/quit"}:
                print("Bye.")
                break

            if is_help_request(user_text):
                print("BOT> Я могу:")
                print("BOT> 1) Собирать отчёт: searchDocs -> summarize -> runInRuntime -> saveToFile")
                print("BOT> 2) Показать инструменты сервера: /tools")
                print("BOT> 3) Вызвать любой tool напрямую: /call <tool> <json>")
                print("BOT> 4) Из диалога поднять docker: /docker text='hello' image=alpine:3.20 cmd='cat'")
                print("BOT> Можно и свободно: 'подними докер, образ alpine:3.20, команда wc -c, текст привет'")
                continue

            if user_text.lower().startswith("/tools") or is_server_discovery_request(user_text):
                try:
                    tools = await self.get_tools()
                except Exception as exc:
                    print(f"BOT> Error: {exc}")
                    continue

                if not tools:
                    print("BOT> Не нашёл tools в сервере.")
                    continue
                print("BOT> Tools from server.mjs:")
                for name, desc in tools:
                    suffix = f" — {desc}" if desc else ""
                    print(f"BOT> - {name}{suffix}")
                continue

            if user_text.lower().startswith("/call"):
                try:
                    tool_name, args = parse_call_command(user_text)
                    result = await self.call_tool(tool_name, args)
                    print(f"BOT> {tool_name}: {json.dumps(result, ensure_ascii=False, indent=2)}")
                except Exception as exc:
                    print(f"BOT> Error: {exc}")
                continue

            if is_runtime_request(user_text):
                requested_runtime = resolve_runtime_from_query(user_text, runtime)
                resolved_image = resolve_image_from_query(user_text, docker_image)
                resolved_command = resolve_command_from_query(user_text)
                extracted_text = resolve_text_from_query(user_text)
                payload_text = extracted_text or user_text
                if user_text.lower().startswith("/docker"):
                    docker_tail = user_text[len("/docker") :].strip()
                    if not extracted_text:
                        payload_text = docker_tail or payload_text
                    if requested_runtime == "auto":
                        requested_runtime = "docker"

                try:
                    runtime_result = await self.call_tool(
                        "runInRuntime",
                        {
                            "text": payload_text,
                            "runtime": requested_runtime,
                            "image": resolved_image,
                            "command": resolved_command,
                        },
                    )
                    print(f"BOT> Runtime used: {runtime_result.get('runtime', 'unknown')}")
                    print(f"BOT> Image: {resolved_image}")
                    print(f"BOT> Command: {resolved_command or '(default)'}")
                    print(f"BOT> Stdout: {runtime_result.get('stdout', '')}")
                    if runtime_result.get("stderr"):
                        print(f"BOT> Stderr: {runtime_result.get('stderr', '')}")
                except Exception as exc:
                    print(f"BOT> Error: {exc}")
                continue

            try:
                summary_intent = is_summary_request(user_text)
                summary_query = resolve_summary_query_from_text(user_text)
                summary_output_path = resolve_summary_output_path_from_text(user_text, output_path)
                summary_files = resolve_summary_files_from_text(user_text, summary_output_path, input_files)
                summary_sentences = resolve_summary_sentences_from_text(user_text, max_sentences)
                summary_compression = resolve_summary_compression_from_text(user_text, compression_level)
                effective_query = summary_query if summary_query else ("" if summary_intent else user_text)
                result = await self.run_chain(
                    query=effective_query,
                    input_files=summary_files,
                    output_path=summary_output_path,
                    limit=limit,
                    max_sentences=summary_sentences,
                    compression_level=summary_compression,
                    runtime=runtime,
                    docker_image=docker_image,
                )
                print("BOT> Done.")
                print(f"BOT> Runtime: {result['runtime'].get('runtime', 'unknown')}")
                print(f"BOT> Saved: {result['saved'].get('filePath', summary_output_path)}")
                print(f"BOT> Summary: {result.get('summary', '')}")
            except Exception as exc:
                print(f"BOT> Error: {exc}")


async def async_main() -> None:
    parser = argparse.ArgumentParser(description="MCP pipeline agent: searchDocs -> summarize -> saveToFile")
    parser.add_argument("--query", default="", help="Search query (optional if --file is used)")
    parser.add_argument("--file", action="append", default=[], help="Input text file (repeatable)")
    parser.add_argument("--chat", action="store_true", help="Interactive dialogue mode")
    parser.add_argument("--out", required=True, help="Output file path inside workspace")
    parser.add_argument("--limit", type=int, default=5, help="Max number of files used by searchDocs")
    parser.add_argument("--sentences", type=int, default=3, help="Max number of sentences in summary")
    parser.add_argument(
        "--compression",
        choices=["low", "medium", "high"],
        default="medium",
        help="Summary compression level",
    )
    parser.add_argument(
        "--runtime",
        choices=["auto", "docker", "emulator"],
        default="auto",
        help="Where to execute compressed output",
    )
    parser.add_argument(
        "--docker-image",
        default="alpine:3.20",
        help="Docker image for runtime=docker|auto",
    )
    parser.add_argument(
        "--server",
        default=str((Path(__file__).resolve().parent / "server.mjs")),
        help="Path to MCP server.mjs",
    )
    args = parser.parse_args()
    query = args.query.strip()
    input_files = [f for f in args.file if isinstance(f, str) and f.strip()]
    if not args.chat and not query and not input_files:
        raise SystemExit("Provide --query or at least one --file")

    agent = MCPPipelineAgent(server_path=args.server)
    await agent.connect()
    try:
        if args.chat:
            await agent.chat_loop(
                input_files=input_files,
                output_path=args.out,
                limit=args.limit,
                max_sentences=args.sentences,
                compression_level=args.compression,
                runtime=args.runtime,
                docker_image=args.docker_image,
            )
            return

        result = await agent.run_chain(
            query=query,
            input_files=input_files,
            output_path=args.out,
            limit=args.limit,
            max_sentences=args.sentences,
            compression_level=args.compression,
            runtime=args.runtime,
            docker_image=args.docker_image,
        )
    finally:
        await agent.close()

    print("Done.")
    print(f"- Query: {result['query']}")
    print(f"- Files: {', '.join(input_files) if input_files else '(workspace scan)'}")
    print(f"- Total matches: {result['search']['totalMatches']}")
    print(f"- Docker image: {result.get('dockerImage', args.docker_image)}")
    print(f"- Runtime command: {result.get('runtimeCommand', '') or '(default)'}")
    print(f"- Runtime used: {result['runtime'].get('runtime', 'unknown')}")
    print(f"- Saved: {result['saved'].get('filePath', args.out)}")


if __name__ == "__main__":
    asyncio.run(async_main())
