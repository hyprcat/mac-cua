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

/// The 8 tools exposed by the server, in `server.py` order. Names, descriptions
/// and schemas are copied verbatim from `TOOL_DEFS`.
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
]}
