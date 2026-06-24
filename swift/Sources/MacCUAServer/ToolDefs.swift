import Foundation

// Verbatim port of `TOOL_DEFS` from `app/server.py`. The model relies on these
// names, descriptions and JSON input schemas, so the text is copied exactly.
// Each entry mirrors one `mcp.types.Tool(name=, description=, inputSchema=)`.
//
// `inputSchema` is held as `[String: Any]` (the JSON-schema object) and can be
// rendered to JSON via `inputSchemaJSON()` / `inputSchemaJSONData()` using
// Foundation `JSONSerialization`.

/// A single MCP tool definition. Mirrors `mcp.types.Tool`.
public struct ToolDef {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// The input schema serialized to JSON data (sorted keys for stability).
    public func inputSchemaJSONData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: inputSchema,
            options: [.sortedKeys]
        )
    }

    /// The input schema serialized to a JSON string.
    public func inputSchemaJSON() throws -> String {
        String(decoding: try inputSchemaJSONData(), as: UTF8.self)
    }
}

/// The tools exposed by the server. The original 9 are in `server.py` order with
/// names, descriptions and schemas copied verbatim from `TOOL_DEFS`; `batch`
/// (Codex parity §D3) is appended.
///
/// Exposed as a computed property (rather than a stored global) because each
/// `inputSchema` is `[String: Any]`, which is not `Sendable`; recomputing avoids
/// shared mutable global state under Swift 6 strict concurrency.
public var toolDefs: [ToolDef] {[
    ToolDef(
        name: "list_apps",
        description: (
            "List the apps on this computer. Returns the set of apps that are currently "
            + "running, as well as any that have been used in the last 14 days, including "
            + "details on usage frequency. Running entries include concrete window_id values "
            + "for window-level targeting."
        ),
        inputSchema: [
            "type": "object",
            "properties": [String: Any](),
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "get_app_state",
        description: (
            "Get the state of a specific window and return a screenshot and "
            + "accessibility tree. Prefer window_id from a prior snapshot or "
            + "list_apps. app remains available for cold-start launch and initial "
            + "window selection."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from a previous snapshot or list_apps"],
            ],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "click",
        description: (
            "Click an element by index or screenshot coordinates. Prefer "
            + "element_index when available; coordinates are best for visually "
            + "obvious targets or when AX is incomplete. All clicks stay "
            + "background-targeted and do not activate the window."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "element_index": ["type": "string", "description": "Element index from accessibility tree"],
                "x": ["type": "number", "description": "X coordinate in the screenshot's pixel space (origin at top-left)"],
                "y": ["type": "number", "description": "Y coordinate in the screenshot's pixel space (origin at top-left)"],
                "click_count": ["type": "integer", "description": "Number of clicks (default 1)", "default": 1],
                "mouse_button": [
                    "type": "string",
                    "enum": ["left", "right", "middle"],
                    "description": "Mouse button (default left)",
                    "default": "left",
                ],
            ],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "drag",
        description: (
            "Drag from one point to another using screenshot coordinates. "
            + "Best used when the exact gesture matters and no direct AX action "
            + "or set_value path exists."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "from_x": ["type": "number", "description": "Start X coordinate in the screenshot's pixel space (origin at top-left)"],
                "from_y": ["type": "number", "description": "Start Y coordinate in the screenshot's pixel space (origin at top-left)"],
                "to_x": ["type": "number", "description": "End X coordinate in the screenshot's pixel space (origin at top-left)"],
                "to_y": ["type": "number", "description": "End Y coordinate in the screenshot's pixel space (origin at top-left)"],
            ],
            "required": ["from_x", "from_y", "to_x", "to_y"],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "press_key",
        description: (
            "Press a key or key-combination on the keyboard, including modifier "
            + "and navigation keys. Supports xdotool-style key syntax such as "
            + "Return, Tab, super+c, Up, and KP_0. element_index is optional and "
            + "can be used to target a control before sending the key."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "key": ["type": "string", "description": "Key combo in xdotool syntax"],
                "element_index": ["type": "string", "description": "Element index to target with the key press"],
            ],
            "required": ["key"],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "type_text",
        description: (
            "Type literal text using background key input. Requires the correct "
            + "control to already have focus unless element_index is supplied to "
            + "target a field first. Prefer set_value when direct AX value setting "
            + "is available."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "text": ["type": "string", "description": "Text to type"],
                "element_index": ["type": "string", "description": "Element index to type into"],
            ],
            "required": ["text"],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "set_value",
        description: (
            "Set the value of a settable accessibility element. Prefer this over "
            + "type_text for text fields -- more reliable, doesn't depend on focus."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "element_index": ["type": "string", "description": "Element index from accessibility tree"],
                "value": ["type": "string", "description": "Value to set"],
            ],
            "required": ["element_index", "value"],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "scroll",
        description: "Scroll an element in a direction by a number of pages.",
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "element_index": ["type": "string", "description": "Element index of scrollable element"],
                "x": ["type": "number", "description": "X coordinate in screenshot pixel coordinates"],
                "y": ["type": "number", "description": "Y coordinate in screenshot pixel coordinates"],
                "direction": [
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "Scroll direction: up, down, left, or right",
                ],
                "pages": ["type": "integer", "description": "Number of page scroll actions. Defaults to 1", "default": 1],
            ],
            "required": ["direction"],
            "additionalProperties": false,
        ]
    ),
    ToolDef(
        name: "perform_secondary_action",
        description: "Invoke a secondary accessibility action exposed by an element.",
        inputSchema: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "description": "App name or bundle identifier"],
                "window_id": ["type": "integer", "description": "Target window ID from the latest get_app_state; preferred over app"],
                "element_index": ["type": "string", "description": "Element index from accessibility tree"],
                "action": ["type": "string", "description": "Action name from element's secondary_actions list"],
            ],
            "required": ["element_index", "action"],
            "additionalProperties": false,
        ]
    ),
    // NEW (Codex parity §D3): N actions in one MCP call. Linear, stop-on-first-
    // failure, one final snapshot — removes N-1 round-trips. Not in server.py.
    ToolDef(
        name: "batch",
        description: (
            "Execute several actions in one call. Actions run sequentially in the "
            + "order given and STOP at the first failure; one final screenshot + "
            + "accessibility-tree snapshot is returned along with a per-step outcome "
            + "list. Each action is an object with a 'tool' field (one of click, "
            + "type_text, set_value, press_key, scroll, drag, "
            + "perform_secondary_action) plus that tool's own parameters. An action "
            + "may carry its own window_id/app to retarget; otherwise it reuses the "
            + "previous action's target. Use this to save round-trips when the next "
            + "action does not depend on seeing the result of the previous one."
        ),
        inputSchema: [
            "type": "object",
            "properties": [
                "actions": [
                    "type": "array",
                    "description": "Ordered list of action items to run sequentially.",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "properties": [
                            "tool": [
                                "type": "string",
                                "enum": [
                                    "click", "type_text", "set_value", "press_key",
                                    "scroll", "drag", "perform_secondary_action",
                                ],
                                "description": "The action tool to run for this step",
                            ],
                            "app": ["type": "string", "description": "Optional retarget: app name or bundle identifier"],
                            "window_id": ["type": "integer", "description": "Optional retarget: target window ID"],
                            "element_index": ["type": "string", "description": "Element index from the accessibility tree"],
                            "value": ["type": "string", "description": "Value for set_value"],
                            "text": ["type": "string", "description": "Text for type_text"],
                            "key": ["type": "string", "description": "Key combo for press_key"],
                            "action": ["type": "string", "description": "Action name for perform_secondary_action"],
                            "direction": ["type": "string", "description": "Scroll direction"],
                            "pages": ["type": "integer", "description": "Scroll pages"],
                            "x": ["type": "number", "description": "X coordinate (screenshot pixel space)"],
                            "y": ["type": "number", "description": "Y coordinate (screenshot pixel space)"],
                            "from_x": ["type": "number", "description": "Drag start X"],
                            "from_y": ["type": "number", "description": "Drag start Y"],
                            "to_x": ["type": "number", "description": "Drag end X"],
                            "to_y": ["type": "number", "description": "Drag end Y"],
                            "click_count": ["type": "integer", "description": "Number of clicks"],
                            "mouse_button": ["type": "string", "description": "Mouse button"],
                        ],
                        "required": ["tool"],
                    ],
                ],
            ],
            "required": ["actions"],
            "additionalProperties": false,
        ]
    ),
]}
