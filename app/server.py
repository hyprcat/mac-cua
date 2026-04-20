from __future__ import annotations

import asyncio
import logging
import traceback
import sys

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    TextContent,
    ImageContent,
    Tool,
)

from app.response import ToolResponse, format_response_header
from app.session import SessionManager
from app._lib.tracing import server_tracer
from main import check_permissions_with_retry_guidance

logger = logging.getLogger(__name__)

server = Server("mac-cua")
session_mgr = SessionManager()

TOOL_DEFS = [
    Tool(
        name="list_apps",
        description=(
            "List the apps on this computer. Returns the set of apps that are currently "
            "running, as well as any that have been used in the last 14 days, including "
            "details on usage frequency. Running entries include concrete window_id values "
            "for window-level targeting."
        ),
        inputSchema={
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    ),
    Tool(
        name="get_app_state",
        description=(
            "Get the state of a specific window and return a screenshot and "
            "accessibility tree. Prefer window_id from a prior snapshot or "
            "list_apps. app remains available for cold-start launch and initial "
            "window selection."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from a previous snapshot or list_apps"},
            },
            "additionalProperties": False,
        },
    ),
    Tool(
        name="click",
        description=(
            "Click an element by index or screenshot coordinates. Prefer "
            "element_index when available; coordinates are best for visually "
            "obvious targets or when AX is incomplete. All clicks stay "
            "background-targeted and do not activate the window."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "element_index": {"type": "string", "description": "Element index from accessibility tree"},
                "x": {"type": "number", "description": "X coordinate in the screenshot's pixel space (origin at top-left)"},
                "y": {"type": "number", "description": "Y coordinate in the screenshot's pixel space (origin at top-left)"},
                "click_count": {"type": "integer", "description": "Number of clicks (default 1)", "default": 1},
                "mouse_button": {
                    "type": "string",
                    "enum": ["left", "right", "middle"],
                    "description": "Mouse button (default left)",
                    "default": "left",
                },
            },
            "additionalProperties": False,
        },
    ),
    Tool(
        name="drag",
        description=(
            "Drag from one point to another using screenshot coordinates. "
            "Best used when the exact gesture matters and no direct AX action "
            "or set_value path exists."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "from_x": {"type": "number", "description": "Start X coordinate in the screenshot's pixel space (origin at top-left)"},
                "from_y": {"type": "number", "description": "Start Y coordinate in the screenshot's pixel space (origin at top-left)"},
                "to_x": {"type": "number", "description": "End X coordinate in the screenshot's pixel space (origin at top-left)"},
                "to_y": {"type": "number", "description": "End Y coordinate in the screenshot's pixel space (origin at top-left)"},
            },
            "required": ["from_x", "from_y", "to_x", "to_y"],
            "additionalProperties": False,
        },
    ),
    Tool(
        name="press_key",
        description=(
            "Press a key or key-combination on the keyboard, including modifier "
            "and navigation keys. Supports xdotool-style key syntax such as "
            "Return, Tab, super+c, Up, and KP_0. element_index is optional and "
            "can be used to target a control before sending the key."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "key": {"type": "string", "description": "Key combo in xdotool syntax"},
                "element_index": {"type": "string", "description": "Element index to target with the key press"},
            },
            "required": ["key"],
            "additionalProperties": False,
        },
    ),
    Tool(
        name="type_text",
        description=(
            "Type literal text using background key input. Requires the correct "
            "control to already have focus unless element_index is supplied to "
            "target a field first. Prefer set_value when direct AX value setting "
            "is available."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "text": {"type": "string", "description": "Text to type"},
                "element_index": {"type": "string", "description": "Element index to type into"},
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    ),
    Tool(
        name="set_value",
        description=(
            "Set the value of a settable accessibility element. Prefer this over "
            "type_text for text fields -- more reliable, doesn't depend on focus."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "element_index": {"type": "string", "description": "Element index from accessibility tree"},
                "value": {"type": "string", "description": "Value to set"},
            },
            "required": ["element_index", "value"],
            "additionalProperties": False,
        },
    ),
    Tool(
        name="scroll",
        description="Scroll an element in a direction by a number of pages.",
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "element_index": {"type": "string", "description": "Element index of scrollable element"},
                "x": {"type": "number", "description": "X coordinate in screenshot pixel coordinates"},
                "y": {"type": "number", "description": "Y coordinate in screenshot pixel coordinates"},
                "direction": {
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "Scroll direction: up, down, left, or right",
                },
                "pages": {"type": "integer", "description": "Number of page scroll actions. Defaults to 1", "default": 1},
            },
            "required": ["direction"],
            "additionalProperties": False,
        },
    ),
    Tool(
        name="perform_secondary_action",
        description="Invoke a secondary accessibility action exposed by an element.",
        inputSchema={
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "App name or bundle identifier"},
                "window_id": {"type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"},
                "element_index": {"type": "string", "description": "Element index from accessibility tree"},
                "action": {"type": "string", "description": "Action name from element's secondary_actions list"},
            },
            "required": ["element_index", "action"],
            "additionalProperties": False,
        },
    ),
]


def format_mcp(response: ToolResponse) -> list[TextContent | ImageContent]:
    blocks: list[TextContent | ImageContent] = []

    if response.tree_text is None:
        if response.result:
            blocks.append(TextContent(type="text", text=response.result))
        if response.error:
            blocks.append(TextContent(type="text", text=response.error))
        return blocks

    parts = []
    parts.append(format_response_header())
    if response.result:
        parts.append(response.result)
    if response.error:
        parts.append(response.error)

    app_state_parts = []
    app_state_parts.append(response.tree_text)

    if response.guidance:
        guidance_block = response.guidance
        # Wrap guidance in XML tags
        wrapped_guidance = (
            f"<app_specific_instructions>\n{guidance_block}\n</app_specific_instructions>"
        )
        header_end = response.tree_text.find("\n\n")
        if header_end != -1:
            header = response.tree_text[:header_end]
            tree_body = response.tree_text[header_end + 2:]
            app_state_parts = [f"{header}\n\n{wrapped_guidance}\n\n{tree_body}"]
        else:
            app_state_parts = [f"{wrapped_guidance}\n\n{response.tree_text}"]

    # Append system selection if present
    if response.system_selection:
        app_state_parts.append("")
        app_state_parts.append(response.system_selection)

    parts.append("")
    parts.append("<app_state>")
    parts.extend(app_state_parts)
    parts.append("</app_state>")

    blocks.append(TextContent(type="text", text="\n".join(parts)))

    if response.screenshot:
        blocks.append(ImageContent(
            type="image",
            data=response.screenshot,
            mimeType="image/png",
        ))

    return blocks


@server.list_tools()
async def handle_list_tools() -> list[Tool]:
    return TOOL_DEFS


TOOL_TIMEOUT_S = 150


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict | None) -> list[TextContent | ImageContent]:
    # Step 4: Check permissions before executing any tool
    pending_msg = check_permissions_with_retry_guidance()
    if pending_msg is not None:
        return [TextContent(type="text", text=pending_msg)]

    loop = asyncio.get_running_loop()
    try:
        with server_tracer.interval(f"MCP:{name}"):
            response = await asyncio.wait_for(
                loop.run_in_executor(None, session_mgr.execute, name, arguments or {}),
                timeout=TOOL_TIMEOUT_S,
            )
        return format_mcp(response)
    except asyncio.TimeoutError:
        msg = f"Tool '{name}' timed out after {TOOL_TIMEOUT_S}s"
        logger.error(msg)
        return [TextContent(type="text", text=msg)]
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        return [TextContent(type="text", text=f"Error in tool '{name}': {exc}")]


async def run_server():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())
