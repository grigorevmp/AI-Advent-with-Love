import asyncio
import json
import os
from contextlib import AsyncExitStack
from typing import Any, Dict, List, Optional, Tuple

from anthropic import Anthropic
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def as_dict(block: Any) -> Dict[str, Any]:
    """Convert an Anthropic content block to a plain dict."""
    if isinstance(block, dict):
        return block
    if hasattr(block, "model_dump"):
        return block.model_dump()
    out: Dict[str, Any] = {}
    for k in ("type", "id", "name", "input", "text"):
        if hasattr(block, k):
            out[k] = getattr(block, k)
    return out


def extract_text(blocks: List[Any]) -> str:
    """Extract concatenated assistant text from content blocks."""
    parts: List[str] = []
    for b in blocks:
        d = as_dict(b)
        if d.get("type") == "text" and isinstance(d.get("text"), str):
            parts.append(d["text"])
    return "\n".join(parts).strip()


def tool_result_to_text(mcp_result: Any) -> str:
    """Convert MCP call_tool result to a single text payload for tool_result."""
    content = getattr(mcp_result, "content", None)
    if content is None and isinstance(mcp_result, dict):
        content = mcp_result.get("content")

    if content is None:
        return json.dumps(as_dict(mcp_result), ensure_ascii=False)

    out: List[str] = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    out.append(item["text"])
                else:
                    out.append(json.dumps(item, ensure_ascii=False))
            else:
                t = getattr(item, "type", None)
                if t == "text":
                    out.append(getattr(item, "text", "") or "")
                else:
                    out.append(str(item))
    else:
        out.append(str(content))

    text = "\n".join([x for x in out if x is not None]).strip()
    return text if text else json.dumps(as_dict(mcp_result), ensure_ascii=False)


class MCPClaudeAgent:
    """Claude Messages API agent that executes tools via an MCP stdio server."""

    def __init__(self, api_key: str, model: str, server_mjs_path: str):
        self._anthropic = Anthropic(api_key=api_key)
        self._model = model
        self._server_path = server_mjs_path

        self._exit_stack = AsyncExitStack()
        self._session: Optional[ClientSession] = None
        self._tools: List[Dict[str, Any]] = []
        self._messages: List[Dict[str, Any]] = []

        self._system = (
            "Ты агент. У тебя есть инструменты через MCP. "
            "Для напоминаний используй tool reminders_add/reminders_poll. "
            "ВАЖНО: reminders_add принимает everyMinutes (минуты). "
            "Если пользователь просит секунды, конвертируй: 10 секунд = 0.1667 минуты (10/60). "
            "Если просит 'через минуту' или 'каждую минуту' — everyMinutes=1. "
            "После добавления напоминания не выдумывай: можешь проверить через reminders_list. "
        )

    async def connect(self) -> None:
        """Start MCP server as a subprocess (stdio) and load available tools."""
        params = StdioServerParameters(command="node", args=[self._server_path])
        read_stream, write_stream = await self._exit_stack.enter_async_context(stdio_client(params))
        self._session = await self._exit_stack.enter_async_context(ClientSession(read_stream, write_stream))
        await self._session.initialize()

        tools = await self._session.list_tools()
        converted: List[Dict[str, Any]] = []
        for t in tools.tools:
            name = getattr(t, "name", None)
            desc = getattr(t, "description", "") or ""
            schema = getattr(t, "inputSchema", None) or getattr(t, "input_schema", None)
            if schema is None and hasattr(t, "model_dump"):
                d = t.model_dump()
                name = name or d.get("name")
                desc = desc or d.get("description", "")
                schema = d.get("inputSchema") or d.get("input_schema")

            if not name:
                continue

            converted.append(
                {
                    "name": name,
                    "description": desc,
                    "input_schema": schema if schema is not None else {"type": "object", "properties": {}},
                }
            )

        self._tools = converted

    async def close(self) -> None:
        """Close MCP session and terminate the MCP server subprocess."""
        await self._exit_stack.aclose()

    async def call_mcp_tool(self, name: str, arguments: Dict[str, Any]) -> Tuple[str, bool]:
        """Invoke an MCP tool and return a (text, is_error) pair."""
        if self._session is None:
            return json.dumps({"error": "mcp session is not connected"}, ensure_ascii=False), True
        try:
            if name == "reminders_add" and isinstance(arguments, dict):
                        # Поддержка секунд в тексте: everySeconds -> everyMinutes
                        if "everySeconds" in arguments and "everyMinutes" not in arguments:
                            try:
                                sec = float(arguments["everySeconds"])
                                if sec > 0:
                                    arguments["everyMinutes"] = sec / 60.0
                            except Exception:
                                pass

            res = await self._session.call_tool(name, arguments)
            return tool_result_to_text(res), False
        except Exception as e:
            return json.dumps({"error": str(e)}, ensure_ascii=False), True

    async def poll_reminders_forever(self, every_seconds: float = 2.0) -> None:
        """Periodically poll reminders and print due summaries to stdout."""
        if self._session is None:
            return
        tool_names = {t["name"] for t in self._tools}
        if "reminders_poll" not in tool_names:
            return

        while True:
            payload, is_error = await self.call_mcp_tool("reminders_poll", {})
            if not is_error:
                try:
                    obj = json.loads(payload)
                    due = obj.get("due", [])
                    if isinstance(due, list) and due:
                        for item in due:
                            title = item.get("title", "reminder")
                            summary = item.get("summary", "")
                            scheduled_at = item.get("scheduledAt", "")
                            print(f"\n[REMINDER] {title} ({scheduled_at})\n{summary}\n")
                except Exception:
                    pass
            await asyncio.sleep(every_seconds)

    async def chat_forever(self) -> None:
        """Interactive loop: user input -> Claude -> MCP tool execution -> Claude."""
        reminder_task = asyncio.create_task(self.poll_reminders_forever(2.0))
        try:
            while True:
                user_text = (await asyncio.to_thread(input, "YOU> ")).strip()
                if not user_text:
                    continue

                self._messages.append({"role": "user", "content": user_text})

                while True:
                    resp = self._anthropic.messages.create(
                        model=self._model,
                        max_tokens=900,
                        system=self._system,
                        tools=self._tools,
                        messages=self._messages,
                    )

                    assistant_text = extract_text(resp.content)
                    if assistant_text:
                        print(f"\nCLAUDE> {assistant_text}\n")

                    if resp.stop_reason == "tool_use":
                        tool_results_blocks: List[Dict[str, Any]] = []

                        for block in resp.content:
                            d = as_dict(block)
                            if d.get("type") != "tool_use":
                                continue
                            tool_name = d.get("name")
                            tool_use_id = d.get("id")
                            tool_input = d.get("input") if isinstance(d.get("input"), dict) else {}

                            result_text, is_error = await self.call_mcp_tool(tool_name, tool_input)
                            tool_results_blocks.append(
                                {
                                    "type": "tool_result",
                                    "tool_use_id": tool_use_id,
                                    "content": result_text,
                                    "is_error": is_error,
                                }
                            )

                        self._messages.append({"role": "assistant", "content": [as_dict(b) for b in resp.content]})
                        self._messages.append({"role": "user", "content": tool_results_blocks})
                        continue

                    self._messages.append({"role": "assistant", "content": [as_dict(b) for b in resp.content]})
                    break
        finally:
            reminder_task.cancel()


async def main() -> None:
    """Entry point for Day 13: interactive agent + background reminder polling."""
    api_key = os.getenv("ANTHROPIC_API_KEY", "").strip()

    model = os.getenv("ANTHROPIC_MODEL", "claude-sonnet-4-5-20250929")
    server_path = os.getenv("SERVER_MJS_PATH", "").strip()
    if not server_path:
        server_path = "/Users/grigorevmp/Documents/AI-Advent-with-Love/mcp/server.mjs"

    agent = MCPClaudeAgent(api_key=api_key, model=model, server_mjs_path=server_path)
    await agent.connect()

    print("MCP tools:")
    for t in agent._tools:
        print("-", t["name"])
    print("\nType in chat. Reminders will appear automatically.\n")

    try:
        await agent.chat_forever()
    finally:
        await agent.close()


if __name__ == "__main__":
    asyncio.run(main())
