#!/usr/bin/env python3
"""Roblox Studio MCP adapter (stdio) that forwards tool jobs to the bridge daemon."""
import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib import parse, request

DEFAULT_CLIENT_ID = "studio"
DEFAULT_HTTP_PORT = 28650
DEFAULT_JOB_TIMEOUT_SEC = 30
DEFAULT_BRIDGE_URL = f"http://localhost:{DEFAULT_HTTP_PORT}"
PID_FILE = Path.home() / ".roblox-mcp-bridge.pid"


def _http_json(url, method="GET", payload=None, timeout=5):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = request.Request(url, data=data, headers=headers, method=method)
    with request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _is_pid_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _bridge_is_running(bridge_url: str) -> bool:
    try:
        data = _http_json(f"{bridge_url}/status", timeout=1)
        return bool(data.get("ok"))
    except Exception:
        return False


def _autostart_bridge(bridge_url: str) -> bool:
    bridge_script = Path(__file__).with_name("roblox_bridge_server.py")
    if not bridge_script.exists():
        return False

    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text(encoding="utf-8").strip())
            if _is_pid_running(pid) and _bridge_is_running(bridge_url):
                return True
        except Exception:
            pass

    subprocess.Popen(
        [sys.executable, str(bridge_script)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    for _ in range(30):
        time.sleep(0.1)
        if _bridge_is_running(bridge_url):
            return True
    return False


class McpServer:
    def __init__(self, bridge_url: str, job_timeout_sec: int):
        self.bridge_url = bridge_url.rstrip("/")
        self.job_timeout_sec = job_timeout_sec

    def run(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            if "method" in msg:
                self._handle_request(msg)

    def _send(self, payload):
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()

    def _handle_request(self, msg):
        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            result = {
                "protocolVersion": "2024-11-05",
                "serverInfo": {
                    "name": "roblox-mcp-bridge",
                    "version": "0.6",
                },
                "capabilities": {"tools": {}},
            }
            self._send({"jsonrpc": "2.0", "id": msg_id, "result": result})
            return

        if method == "notifications/initialized":
            return

        if method == "tools/list":
            tools = _build_tools()
            self._send({"jsonrpc": "2.0", "id": msg_id, "result": {"tools": tools}})
            return

        if method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            arguments = params.get("arguments") or {}
            result = self._call_tool(name, arguments)
            self._send({"jsonrpc": "2.0", "id": msg_id, "result": result})
            return

        if msg_id is not None:
            self._send(
                {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {"code": -32601, "message": "Method not found"},
                }
            )

    def _call_tool(self, name, arguments):
        if name == "studio_get_connection_status":
            return _tool_result(_get_connection_status(self.bridge_url, arguments))

        client_id = arguments.get("client_id") or DEFAULT_CLIENT_ID
        if not _is_client_connected(self.bridge_url, client_id):
            return _tool_error(
                "Studio is not connected. Make sure the Roblox Studio plugin "
                "is installed and 'Start Bridge Polling' has been clicked."
            )

        job = _build_job(name, arguments)
        if job is None:
            return _tool_error(f"Unknown tool: {name}")

        try:
            result = self._call_studio(job["type"], job["args"], client_id)
        except TimeoutError:
            return _tool_error(
                "Timed out waiting for Studio to respond. "
                "Check that the plugin is running and connected."
            )
        except Exception as exc:
            return _tool_error(f"Bridge request failed: {exc}")

        if not result.get("ok", False):
            return _tool_error(result.get("error") or "Studio error")

        return _tool_result(result.get("result"))

    def _call_studio(self, action: str, params: dict, client_id: str = DEFAULT_CLIENT_ID):
        job_id = str(uuid.uuid4())
        _http_json(
            f"{self.bridge_url}/job",
            method="POST",
            payload={
                "job_id": job_id,
                "client_id": client_id,
                "action": action,
                "params": params,
            },
            timeout=5,
        )

        deadline = time.time() + self.job_timeout_sec
        while time.time() < deadline:
            data = _http_json(f"{self.bridge_url}/result/{job_id}", timeout=5)
            if data.get("ready"):
                return data["result"]
            time.sleep(0.2)
        raise TimeoutError(f"Studio did not respond within {self.job_timeout_sec}s")


def _tool_result(payload):
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    return {"content": [{"type": "text", "text": text}]}


def _tool_error(message):
    return {"isError": True, "content": [{"type": "text", "text": message}]}


def _build_job(name, arguments):
    job_id = f"job_{uuid.uuid4().hex[:12]}"
    tool_to_job = {
        # Instance tools
        "roblox_analyze_script": "analyze_script",
        "roblox_list_services": "list_services",
        "roblox_get_children": "get_children",
        "roblox_get_descendants": "get_descendants",
        "roblox_get_instance": "get_instance",
        "roblox_find_instances": "find_instances",
        "roblox_search_by_property": "search_by_property",
        "roblox_create_instance": "create_instance",
        "roblox_delete_instance": "delete_instance",
        "roblox_clone_instance": "clone_instance",
        "roblox_smart_duplicate": "smart_duplicate",
        "roblox_reparent_instance": "reparent_instance",
        "roblox_set_name": "set_name",
        "roblox_select_instance": "select_instance",
        "roblox_get_tree": "get_tree",
        # Property / Attribute tools
        "roblox_get_attributes": "get_attributes",
        "roblox_set_attributes": "set_attributes",
        "roblox_get_properties": "get_properties",
        "roblox_set_properties": "set_properties",
        "roblox_get_class_info": "get_class_info",
        # Tag tools
        "roblox_get_tags": "get_tags",
        "roblox_add_tag": "add_tag",
        "roblox_remove_tag": "remove_tag",
        # Script tools
        "roblox_read_script": "read_script",
        "roblox_write_script": "write_script",
        "roblox_patch_script": "patch_script",
        "roblox_get_script_lines": "get_script_lines",
        "roblox_search_script": "search_script",
        "roblox_get_script_functions": "get_script_functions",
        "roblox_search_across_scripts": "search_across_scripts",
        # Selection
        "roblox_get_selection": "get_selection",
        # ScriptEditorService
        "roblox_open_script": "open_script",
        "roblox_get_open_scripts": "get_open_scripts",
        "roblox_close_script": "close_script",
        # ChangeHistoryService
        "roblox_undo": "undo",
        "roblox_redo": "redo",
        "roblox_set_waypoint": "set_waypoint",
        "roblox_get_all_properties": "get_all_properties",
        "roblox_run_code": "run_code",
        "roblox_insert_model": "insert_model",
        "roblox_get_console_output": "get_console_output",
        "roblox_get_playtest_output": "get_playtest_output",
        "roblox_start_stop_play": "start_stop_play",
        "roblox_run_script_in_play_mode": "run_script_in_play_mode",
        "roblox_get_studio_mode": "get_studio_mode",
        # ── NEW v0.6: Terrain tools ────────────────────────────────────────
        "roblox_terrain_fill_block":       "terrain_fill_block",
        "roblox_terrain_fill_ball":        "terrain_fill_ball",
        "roblox_terrain_fill_cylinder":    "terrain_fill_cylinder",
        "roblox_terrain_replace_material": "terrain_replace_material",
        "roblox_terrain_read_voxels":      "terrain_read_voxels",
        "roblox_terrain_clear_region":     "terrain_clear_region",
        # ── NEW v0.6: Bulk tools ───────────────────────────────────────────
        "roblox_bulk_create_instances":        "bulk_create_instances",
        "roblox_bulk_set_properties":          "bulk_set_properties",
        "roblox_bulk_delete_instances":        "bulk_delete_instances",
        "roblox_bulk_get_properties":          "bulk_get_properties",
        "roblox_find_and_replace_in_scripts":  "find_and_replace_in_scripts",
        # ── NEW v0.6: DataModel tools ──────────────────────────────────────
        "roblox_get_place_info":       "get_place_info",
        "roblox_set_lighting":         "set_lighting",
        "roblox_get_workspace_info":   "get_workspace_info",
        "roblox_get_team_list":        "get_team_list",
        "roblox_get_lighting_effects": "get_lighting_effects",
        "roblox_export_build":         "export_build",
        "roblox_import_build":         "import_build",
    }

    if name not in tool_to_job:
        return None

    job_type = tool_to_job[name]
    job_args = dict(arguments)
    if job_type in {"run_code", "run_script_in_play_mode"}:
        if not job_args.get("code"):
            job_args["code"] = job_args.get("script") or job_args.get("source")
    return {
        "job_id": job_id,
        "type": job_type,
        "args": job_args,
        "created_at": time.time(),
    }


def _get_connection_status(bridge_url, arguments):
    client_id = arguments.get("client_id") or DEFAULT_CLIENT_ID
    try:
        query = parse.urlencode({"client_id": client_id})
        data = _http_json(f"{bridge_url}/status?{query}", timeout=3)
        if data.get("connected") is not None:
            return {
                "connected": bool(data.get("connected")),
                "client_id": client_id,
                "last_seen_seconds": data.get("last_seen_seconds"),
            }
    except Exception:
        pass
    return {"connected": False, "client_id": client_id}


def _is_client_connected(bridge_url, client_id):
    try:
        query = parse.urlencode({"client_id": client_id})
        data = _http_json(f"{bridge_url}/status?{query}", timeout=3)
        return bool(data.get("connected"))
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Shared schema fragments
# ---------------------------------------------------------------------------

_INSTANCE_REF_PROPS = {
    "path": {
        "type": "string",
        "description": "Dot-separated path, e.g. 'Workspace.Baseplate'.",
    },
    "pathArray": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Path as array of names, e.g. ['Workspace','Baseplate'].",
    },
    "id": {
        "type": "string",
        "description": "Debug id returned by a previous call.",
    },
    "client_id": {"type": "string"},
}

_REGION_PROPS = {
    "regionMin": {"type": "object", "description": '{"x":0,"y":0,"z":0} minimum corner of the region.'},
    "regionMax": {"type": "object", "description": '{"x":100,"y":50,"z":100} maximum corner.'},
    "resolution": {"type": "integer", "description": "Voxel resolution in studs (multiple of 4, default 4)."},
    "client_id":  {"type": "string"},
}


def _ref_schema(extra_props=None, required=None):
    props = dict(_INSTANCE_REF_PROPS)
    if extra_props:
        props.update(extra_props)
    schema = {"type": "object", "properties": props}
    if required:
        schema["required"] = required
    return schema


def _build_tools():
    return [
        # -- Meta ---------------------------------------------------------------
        {
            "name": "studio_get_connection_status",
            "description": "Check if the Roblox Studio plugin is connected to the bridge.",
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        # -- Instance tools -----------------------------------------------------
        {
            "name": "roblox_list_services",
            "description": "List top-level services in the current place.",
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        {
            "name": "roblox_get_children",
            "description": "Get the direct children of an instance.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_get_descendants",
            "description": "Get all descendants of an instance. Can be large - prefer get_tree for an overview.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_get_instance",
            "description": "Get info (name, className, fullName) for a single instance.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_find_instances",
            "description": "Find instances matching name, className, and/or tag under an ancestor.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Exact Name match."},
                    "className": {"type": "string", "description": "Exact ClassName match."},
                    "tag": {"type": "string", "description": "Must have this CollectionService tag."},
                    "ancestorPath": {"type": "string"},
                    "ancestorPathArray": {"type": "array", "items": {"type": "string"}},
                    "client_id": {"type": "string"},
                },
            },
        },

        {
            "name": "roblox_search_by_property",
            "description": "Find instances under an ancestor where a specific property equals a given value.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "propertyName": {"type": "string"},
                    "propertyValue": {"description": "Property value to compare (supports rich _type values)."},
                    "className": {"type": "string"},
                    "ancestorPath": {"type": "string"},
                    "ancestorPathArray": {"type": "array", "items": {"type": "string"}},
                    "client_id": {"type": "string"},
                },
                "required": ["propertyName", "propertyValue"],
            },
        },
        {
            "name": "roblox_get_tree",
            "description": (
                "Get a compact recursive tree of an instance hierarchy. "
                "Returns name, className, and for scripts the line count. "
                "Use maxDepth to limit depth (default 5) and maxChildren to cap children per node (default 50)."
            ),
            "inputSchema": _ref_schema(
                extra_props={
                    "maxDepth": {"type": "integer", "description": "Max tree depth (default 5)."},
                    "maxChildren": {"type": "integer", "description": "Max children per node (default 50)."},
                }
            ),
        },
        {
            "name": "roblox_create_instance",
            "description": (
                "Create a new instance. Set properties (including Name, Source for scripts) "
                "via the properties dict. Supports rich types via _type objects."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "className": {"type": "string"},
                    "parentPath": {"type": "string"},
                    "parentPathArray": {"type": "array", "items": {"type": "string"}},
                    "properties": {"type": "object", "description": "Key/value map of properties to set. Use _type objects for rich types."},
                    "client_id": {"type": "string"},
                },
                "required": ["className"],
            },
        },
        {
            "name": "roblox_delete_instance",
            "description": "Destroy an instance and all its descendants. Undoable via Ctrl+Z.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_clone_instance",
            "description": "Clone an instance (and its descendants). Optionally place under a new parent and rename. Undoable.",
            "inputSchema": _ref_schema(
                extra_props={
                    "newParentPath": {"type": "string"},
                    "newParentPathArray": {"type": "array", "items": {"type": "string"}},
                    "newName": {"type": "string", "description": "Rename the clone."},
                }
            ),
        },

        {
            "name": "roblox_smart_duplicate",
            "description": "Clone an instance multiple times and optionally apply a per-clone Vector3 offset.",
            "inputSchema": _ref_schema(
                extra_props={
                    "count": {"type": "integer"},
                    "offset": {"type": "object", "description": '{"_type":"Vector3","x":5,"y":0,"z":0}'},
                    "newParentPath": {"type": "string"},
                    "newParentPathArray": {"type": "array", "items": {"type": "string"}},
                },
                required=["count"],
            ),
        },
        {
            "name": "roblox_reparent_instance",
            "description": "Move an instance to a new parent. Undoable.",
            "inputSchema": _ref_schema(
                extra_props={
                    "newParentPath": {"type": "string"},
                    "newParentPathArray": {"type": "array", "items": {"type": "string"}},
                },
                required=["newParentPath"],
            ),
        },
        {
            "name": "roblox_set_name",
            "description": "Rename an instance. Undoable.",
            "inputSchema": _ref_schema(
                extra_props={"name": {"type": "string"}},
                required=["name"],
            ),
        },
        {
            "name": "roblox_select_instance",
            "description": "Select an instance in the Studio Explorer (for visibility).",
            "inputSchema": _ref_schema(),
        },
        # -- Selection ----------------------------------------------------------
        {
            "name": "roblox_get_selection",
            "description": "Get the instances currently selected in the Studio Explorer.",
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        # -- Property / Attribute tools -----------------------------------------
        {
            "name": "roblox_get_properties",
            "description": (
                "Read specific properties from an instance. Returns rich type objects with _type field "
                "for complex types (Color3, Vector3, CFrame, UDim2, BrickColor, EnumItem, etc.)."
            ),
            "inputSchema": _ref_schema(
                extra_props={
                    "properties": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Property names to read.",
                    }
                },
                required=["properties"],
            ),
        },
        {
            "name": "roblox_set_properties",
            "description": (
                "Set properties on an instance. Undoable. For complex types, use _type objects: "
                '{"_type":"Color3","r":255,"g":0,"b":0}, '
                '{"_type":"Vector3","x":1,"y":2,"z":3}, etc.'
            ),
            "inputSchema": _ref_schema(
                extra_props={
                    "properties": {
                        "type": "object",
                        "description": "Key/value map of properties to set. Use _type objects for rich types.",
                    }
                },
                required=["properties"],
            ),
        },
        {
            "name": "roblox_get_attributes",
            "description": "Get all custom attributes on an instance. Returns rich type objects for complex attribute values.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_set_attributes",
            "description": "Set custom attributes on an instance. Undoable. Supports rich type objects.",
            "inputSchema": _ref_schema(
                extra_props={"attributes": {"type": "object"}},
                required=["attributes"],
            ),
        },
        # -- Tag tools ----------------------------------------------------------
        {
            "name": "roblox_get_tags",
            "description": "Get all CollectionService tags on an instance.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_add_tag",
            "description": "Add a CollectionService tag to an instance. Undoable.",
            "inputSchema": _ref_schema(
                extra_props={"tag": {"type": "string"}},
                required=["tag"],
            ),
        },
        {
            "name": "roblox_remove_tag",
            "description": "Remove a CollectionService tag from an instance. Undoable.",
            "inputSchema": _ref_schema(
                extra_props={"tag": {"type": "string"}},
                required=["tag"],
            ),
        },
        # -- Script tools -------------------------------------------------------
        {
            "name": "roblox_read_script",
            "description": (
                "Read the full Source of a Script/LocalScript/ModuleScript. "
                "For large scripts prefer get_script_lines to read a specific range."
            ),
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_write_script",
            "description": (
                "Overwrite the full Source of a script. Undoable. "
                "WARNING: For partial edits use patch_script instead."
            ),
            "inputSchema": _ref_schema(
                extra_props={"source": {"type": "string"}},
                required=["source"],
            ),
        },
        {
            "name": "roblox_patch_script",
            "description": (
                "Apply line-based patches to a script without rewriting the entire source. Undoable. "
                "Ops: insert, replace, delete, append, prepend. "
                "ALWAYS provide expectedContent for replace/delete and expectedContext for insert."
            ),
            "inputSchema": _ref_schema(
                extra_props={
                    "patches": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "op": {"type": "string", "enum": ["insert", "replace", "delete", "append", "prepend"]},
                                "lineStart": {"type": "integer"},
                                "lineEnd": {"type": "integer"},
                                "content": {"type": "string"},
                                "expectedContent": {"type": "string"},
                                "expectedContext": {"type": "string"},
                            },
                            "required": ["op"],
                        },
                    }
                },
                required=["patches"],
            ),
        },
        {
            "name": "roblox_get_script_lines",
            "description": "Read a specific line range from a script. Omit startLine/endLine to get line count only.",
            "inputSchema": _ref_schema(
                extra_props={
                    "startLine": {"type": "integer"},
                    "endLine": {"type": "integer"},
                }
            ),
        },
        {
            "name": "roblox_search_script",
            "description": "Search a script's source for a string or Lua pattern.",
            "inputSchema": _ref_schema(
                extra_props={
                    "query": {"type": "string"},
                    "usePattern": {"type": "boolean"},
                    "caseSensitive": {"type": "boolean"},
                    "contextLines": {"type": "integer"},
                    "maxResults": {"type": "integer"},
                },
                required=["query"],
            ),
        },
        {
            "name": "roblox_get_script_functions",
            "description": "List all function definitions in a script with line numbers and types.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_search_across_scripts",
            "description": "Search ALL scripts under an ancestor for a query string.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "ancestorPath": {"type": "string"},
                    "ancestorPathArray": {"type": "array", "items": {"type": "string"}},
                    "usePattern": {"type": "boolean"},
                    "caseSensitive": {"type": "boolean"},
                    "maxScripts": {"type": "integer"},
                    "maxMatchesPerScript": {"type": "integer"},
                    "client_id": {"type": "string"},
                },
                "required": ["query"],
            },
        },
        # -- Studio helpers ------------------------------------------------------
        {
            "name": "roblox_run_code",
            "description": "Execute arbitrary Lua code within Studio and return a serialized result.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "code": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["code"],
            },
        },
        {
            "name": "roblox_insert_model",
            "description": "Insert a Marketplace asset into Workspace using InsertService.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "assetId": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["assetId"],
            },
        },
        {
            "name": "roblox_get_console_output",
            "description": "Read the buffered Studio Output log captured by the plugin.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "since": {"type": "number"},
                    "maxEntries": {"type": "integer"},
                    "client_id": {"type": "string"},
                },
            },
        },

        {
            "name": "roblox_get_playtest_output",
            "description": "Read buffered playtest/run output logs separately from general Studio logs.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "since": {"type": "number"},
                    "maxEntries": {"type": "integer"},
                    "client_id": {"type": "string"},
                },
            },
        },
        {
            "name": "roblox_start_stop_play",
            "description": "Switch Studio between Edit, Play, Run, or Test modes.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "mode": {"type": "string"},
                    "action": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["mode"],
            },
        },
        {
            "name": "roblox_get_studio_mode",
            "description": "Query the current Studio run mode and whether play mode is active.",
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        {
            "name": "roblox_run_script_in_play_mode",
            "description": "Run a Lua snippet while Studio is in Play or Run mode.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "code": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["code"],
            },
        },
        # -- ScriptEditorService ------------------------------------------------
        {
            "name": "roblox_open_script",
            "description": "Open a script in the Studio script editor tab and optionally navigate to a line.",
            "inputSchema": _ref_schema(
                extra_props={"line": {"type": "integer"}}
            ),
        },
        {
            "name": "roblox_get_open_scripts",
            "description": "List all scripts currently open in the Studio script editor.",
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        {
            "name": "roblox_close_script",
            "description": "Close a script's tab in the Studio script editor.",
            "inputSchema": _ref_schema(),
        },
        # -- ChangeHistoryService -----------------------------------------------
        {
            "name": "roblox_undo",
            "description": "Undo the last action in Studio. Equivalent to Ctrl+Z.",
            "inputSchema": {"type": "object", "properties": {"client_id": {"type": "string"}}},
        },
        {
            "name": "roblox_redo",
            "description": "Redo the last undone action in Studio. Equivalent to Ctrl+Y.",
            "inputSchema": {"type": "object", "properties": {"client_id": {"type": "string"}}},
        },
        {
            "name": "roblox_set_waypoint",
            "description": "Set a named undo/redo waypoint.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "client_id": {"type": "string"},
                },
            },
        },

        {
            "name": "roblox_get_class_info",
            "description": "Read class property metadata from ReflectionService by class name.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "className": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["className"],
            },
        },
        {
            "name": "roblox_get_all_properties",
            "description": (
                "Read ALL properties from an instance using ReflectionService. "
                "Returns every readable, non-deprecated property with its current value."
            ),
            "inputSchema": _ref_schema(),
        },

        # ── NEW v0.6: Terrain tools ────────────────────────────────────────────
        {
            "name": "roblox_terrain_fill_block",
            "description": (
                "Fill a box-shaped volume with a terrain material. Undoable. "
                "cframe specifies the centre (position + optional rotation). "
                "size specifies the bounding box in studs. "
                "Common materials: Grass, Rock, Water, Sand, Snow, Ground, Mud, Asphalt, Brick, Concrete, Ice, Salt, Sandstone, Slate, SmoothPlastic, WoodPlanks."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cframe": {
                        "type": "object",
                        "description": 'Position as {"x":0,"y":0,"z":0} or full 12-component CFrame {"components":[…]}.',
                    },
                    "size": {"type": "object", "description": '{"x":10,"y":5,"z":10} in studs.'},
                    "material": {"type": "string", "description": "Terrain material name."},
                    "client_id": {"type": "string"},
                },
                "required": ["cframe", "size", "material"],
            },
        },
        {
            "name": "roblox_terrain_fill_ball",
            "description": "Fill a sphere of terrain material at a given centre and radius. Undoable.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "center":   {"type": "object", "description": '{"x":0,"y":0,"z":0}'},
                    "radius":   {"type": "number",  "description": "Radius in studs."},
                    "material": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["center", "radius", "material"],
            },
        },
        {
            "name": "roblox_terrain_fill_cylinder",
            "description": (
                "Fill a cylinder of terrain material. Undoable. "
                "The cylinder axis is aligned with the CFrame's Y axis."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cframe":    {"type": "object", "description": 'Centre of the cylinder {"x":0,"y":0,"z":0}.'},
                    "height":    {"type": "number", "description": "Height of the cylinder in studs."},
                    "radius":    {"type": "number", "description": "Radius of the cylinder in studs."},
                    "material":  {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["cframe", "height", "radius", "material"],
            },
        },
        {
            "name": "roblox_terrain_replace_material",
            "description": (
                "Replace every voxel of one terrain material with another inside a Region3. Undoable. "
                "Great for large-scale reskins, e.g. swap all Sand → Ground across a level."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    **_REGION_PROPS,
                    "from": {"type": "string", "description": "Material to replace (e.g. Sand)."},
                    "to":   {"type": "string", "description": "Replacement material (e.g. Ground)."},
                },
                "required": ["regionMin", "regionMax", "from", "to"],
            },
        },
        {
            "name": "roblox_terrain_read_voxels",
            "description": (
                "Read terrain voxel data (material + occupancy) from a region. "
                "For regions ≤4096 voxels: returns full per-voxel list. "
                "For larger regions: returns a material-frequency summary only. "
                "Use a higher resolution (16 or 32) to sample large areas without hitting the limit."
            ),
            "inputSchema": {
                "type": "object",
                "properties": dict(_REGION_PROPS),
                "required": ["regionMin", "regionMax"],
            },
        },
        {
            "name": "roblox_terrain_clear_region",
            "description": "Remove all terrain (fill with Air) within a Region3. Undoable.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "regionMin": {"type": "object"},
                    "regionMax": {"type": "object"},
                    "client_id": {"type": "string"},
                },
                "required": ["regionMin", "regionMax"],
            },
        },

        # ── NEW v0.6: Bulk tools ───────────────────────────────────────────────
        {
            "name": "roblox_bulk_create_instances",
            "description": (
                "Create up to 200 instances in a single round-trip, all in one undo waypoint. "
                "Each entry needs className; optionally parentPath/parentPathArray and a properties dict "
                "that supports _type rich-type objects. "
                "Much faster than calling create_instance N times for large batch work."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "instances": {
                        "type": "array",
                        "maxItems": 200,
                        "description": "Array of instance specs to create.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "className":       {"type": "string"},
                                "parentPath":      {"type": "string"},
                                "parentPathArray": {"type": "array", "items": {"type": "string"}},
                                "properties":      {"type": "object"},
                            },
                            "required": ["className"],
                        },
                    },
                    "client_id": {"type": "string"},
                },
                "required": ["instances"],
            },
        },
        {
            "name": "roblox_bulk_set_properties",
            "description": (
                "Set properties on up to 200 instances in one round-trip, wrapped in one undo waypoint. "
                "Each operation is an instance ref (path/pathArray/id) plus a properties dict. "
                "Supports rich _type objects. Much faster than N individual set_properties calls."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "operations": {
                        "type": "array",
                        "maxItems": 200,
                        "items": {
                            "type": "object",
                            "properties": {
                                "path":       {"type": "string"},
                                "pathArray":  {"type": "array", "items": {"type": "string"}},
                                "id":         {"type": "string"},
                                "properties": {"type": "object"},
                            },
                            "required": ["properties"],
                        },
                    },
                    "client_id": {"type": "string"},
                },
                "required": ["operations"],
            },
        },
        {
            "name": "roblox_bulk_delete_instances",
            "description": (
                "Delete multiple instances in one round-trip, wrapped in one undo waypoint. "
                "All descendants are destroyed. Provide an array of instance refs."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "instances": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "path":      {"type": "string"},
                                "pathArray": {"type": "array", "items": {"type": "string"}},
                                "id":        {"type": "string"},
                            },
                        },
                    },
                    "client_id": {"type": "string"},
                },
                "required": ["instances"],
            },
        },

        {
            "name": "roblox_bulk_get_properties",
            "description": "Read a single property from many instances in one round-trip.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "instances": {
                        "type": "array",
                        "items": _ref_schema(),
                    },
                    "property": {"type": "string"},
                    "client_id": {"type": "string"},
                },
                "required": ["instances", "property"],
            },
        },
        {
            "name": "roblox_find_and_replace_in_scripts",
            "description": (
                "Find a plain string in all scripts under an ancestor and replace it everywhere. "
                "All changes wrapped in one undo waypoint. "
                "Set dryRun=true to preview matches without modifying. "
                "caseSensitive defaults to true. maxScripts caps modifications (default 50, max 200). "
                "Great for renaming a variable, function, or module require path across a codebase."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "find":              {"type": "string",  "description": "Plain string to find."},
                    "replace":           {"type": "string",  "description": "Replacement string."},
                    "ancestorPath":      {"type": "string"},
                    "ancestorPathArray": {"type": "array",   "items": {"type": "string"}},
                    "caseSensitive":     {"type": "boolean"},
                    "maxScripts":        {"type": "integer", "description": "Max scripts to modify (default 50)."},
                    "dryRun":            {"type": "boolean", "description": "Preview without modifying if true."},
                    "client_id":         {"type": "string"},
                },
                "required": ["find", "replace"],
            },
        },

        # ── NEW v0.6: DataModel tools ──────────────────────────────────────────
        {
            "name": "roblox_get_place_info",
            "description": (
                "Return metadata about the currently open place: PlaceId, GameId, name, "
                "PlaceVersion, gravity, StreamingEnabled, all Lighting service properties, "
                "and a summary of child counts for each major service."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        {
            "name": "roblox_set_lighting",
            "description": (
                "Set one or more Lighting service properties. Undoable. "
                "Supports rich _type objects for Color3 values. "
                "Useful properties: TimeOfDay ('14:00:00'), Brightness, FogEnd, FogStart, "
                "FogColor, GlobalShadows, Technology (EnumItem with enumType='Technology')."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "properties": {
                        "type": "object",
                        "description": "Key/value map of Lighting properties to set.",
                    },
                    "client_id": {"type": "string"},
                },
                "required": ["properties"],
            },
        },
        {
            "name": "roblox_get_workspace_info",
            "description": (
                "Return key Workspace-level settings useful for level design: "
                "Gravity, StreamingEnabled, streaming radii, wind settings, and the current camera CFrame."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
        {
            "name": "roblox_get_team_list",
            "description": "Return all teams in the Teams service with their BrickColor and AutoAssignable setting.",
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },

        {
            "name": "roblox_export_build",
            "description": "Serialize an instance subtree into JSON including class, name, properties, and children.",
            "inputSchema": _ref_schema(),
        },
        {
            "name": "roblox_import_build",
            "description": "Recreate an instance hierarchy from exported JSON under a parent in one undo waypoint.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "json": {"type": "string"},
                    "buildJson": {"type": "string"},
                    "parentPath": {"type": "string"},
                    "parentPathArray": {"type": "array", "items": {"type": "string"}},
                    "parentId": {"type": "string"},
                    "client_id": {"type": "string"},
                },
            },
        },
        {
            "name": "roblox_analyze_script",
            "description": (
                "Statically analyse a Luau script and return categorised diagnostics. "
                "Does not execute any code — analysis runs entirely inside the plugin. "
                "\n\nReturns three severity levels:\n"
                "  error   — high-confidence defects (indexing literal nil/false, assignment "
                "instead of comparison in 'if' condition, concatenating nil, require(nil), etc.)\n"
                "  warning — likely bugs needing review (unused locals, possible nil access on "
                "FindFirstChild/Find* results without a guard, deprecated globals like wait()/spawn()/delay(), "
                "shadowed locals, unreachable code after return/error/break)\n"
                "  hint    — style / best-practice nudges (functions > 80 lines, implicit globals)\n"
                "\nPass noHints=true to suppress hints and receive only errors and warnings.\n"
                "\nEach diagnostic object has: kind ('error'|'warning'|'hint'), line (1-indexed), message.\n"
                "\nThe response also includes: scriptName, totalLines, errorCount, warningCount, "
                "hintCount, totalCount."
            ),
            "inputSchema": _ref_schema(
                extra_props={
                    "noHints": {
                        "type": "boolean",
                        "description": "If true, omit hint-level diagnostics (default false).",
                    }
                }
            ),
        },
        {
            "name": "roblox_get_lighting_effects",
            "description": (
                "Return all post-processing and lighting effects under the Lighting service "
                "(Bloom, DepthOfField, ColorCorrection, SunRays, etc.) including their key property values."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"client_id": {"type": "string"}},
            },
        },
    ]


def main():
    parser = argparse.ArgumentParser(description="Roblox Studio MCP adapter v0.8")
    parser.add_argument("--bridge-url", default=DEFAULT_BRIDGE_URL)
    parser.add_argument("--job-timeout", type=int, default=DEFAULT_JOB_TIMEOUT_SEC)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument(
        "--no-autostart",
        action="store_true",
        help="Don't auto-start the bridge daemon",
    )
    args = parser.parse_args()

    if not _bridge_is_running(args.bridge_url):
        if args.no_autostart:
            print(
                "[MCP Adapter] Bridge not running. Start it with: python roblox_bridge_server.py",
                file=sys.stderr,
            )
            sys.exit(1)
        if not args.quiet:
            print("[MCP Adapter] Bridge not running — starting it...", file=sys.stderr)
        if not _autostart_bridge(args.bridge_url):
            print(
                "[MCP Adapter] Failed to start bridge. Run manually: python roblox_bridge_server.py",
                file=sys.stderr,
            )
            sys.exit(1)
        if not args.quiet:
            print("[MCP Adapter] Bridge started.", file=sys.stderr)

    if not args.quiet:
        print(f"[MCP Adapter v0.8] Connected to bridge at {args.bridge_url}", file=sys.stderr)

    mcp = McpServer(bridge_url=args.bridge_url, job_timeout_sec=args.job_timeout)
    try:
        mcp.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
