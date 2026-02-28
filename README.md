# Roblox Studio MCP Bridge
![Build](https://github.com/eyedautumn/codex_python_studio_mcp/actions/workflows/build.yml/badge.svg)
![Version](https://img.shields.io/github/v/release/eyedautumn/python_roblox_studio_mcp?style=flat-square&display_name=tag)

A Roblox Studio plugin that bridges Studio to an external MCP (Model Context Protocol) server over HTTP, enabling AI tools to read and manipulate your game's hierarchy, scripts, properties, and more.

The runtime is split into two processes:
- `roblox_bridge_server.py`: a single long-lived HTTP daemon on port `28650` that Studio polls.
- `roblox_mcp_server.py`: a per-agent MCP stdio adapter that forwards tool calls to the bridge.

## Installation

### Option A — Installer script (recommended)

1. Go to the [**Releases**](../../releases) page and download `install.py` (requires Python 3.8+) **or** a standalone executable for your platform:
   - **Linux:** `install-linux`
   - **macOS:** `install-macos` *(right-click → Open on first run to bypass Gatekeeper)*
   - **Windows:** `install-windows.exe`
2. Run the installer — it will walk you through plugin placement and MCP server registration for Claude Desktop, Claude Code, OpenAI Codex, or OpenCode.
   - Advanced: pass `--server-script /absolute/path/to/roblox_mcp_server.py` (or `--server-path`) to choose where scripts are installed; installer now places both `roblox_mcp_server.py` and sibling `roblox_bridge_server.py`.
   - Claude Desktop advanced: pass `--claude-desktop-config /absolute/path/to/claude_desktop_config.json` to use a custom config location.
3. Open Roblox Studio. The **Roblox MCP** toolbar button will appear.
4. Enable **HTTP Requests** in *Game Settings → Security* (the plugin will attempt this automatically).
5. Click **Start Bridge Polling** in the plugin widget.

### Option B — Auto-updater wizard (new)

Use this when you want to always pull the latest installer wizard before setup.

1. Download `update.py` from [**Releases**](../../releases) (Python 3.8+ required).
2. Run it:
   - **Linux/macOS:** `python3 update.py`
   - **Windows:** `py update.py` (or `python update.py`)
3. The updater fetches the latest `install.py` from the newest release and launches the full interactive installer so you can pick your preferred setup options.
   - You can also set `--server-script /absolute/path/to/roblox_mcp_server.py` when running `update.py`; it installs both adapter + bridge scripts in that folder.

You can pass installer flags through the updater too:

```bash
python3 update.py --server-script /opt/roblox-mcp/roblox_mcp_server.py --claude-desktop-config ~/.config/Claude/claude_desktop_config.json -- --non-interactive --skip-skill --agent codex
```

### Option C — Manual plugin install

1. Go to the [**Releases**](../../releases) page and download `RobloxMcpBridge.rbxm`.  
   — or —  
   Download the latest build artifact from [**Actions**](../../actions) (no release required).
2. Place `RobloxMcpBridge.rbxm` in your Roblox **Plugins** folder:
   - **Windows:** `%LOCALAPPDATA%\Roblox\Plugins\`
   - **macOS:** `~/Documents/Roblox/Plugins/`
   - **Linux (Sober/Flatpak):** `~/.var/app/org.vinegarhq.Sober/data/roblox/Plugins/`
   - **Linux (Vinegar/Wine):** `~/.var/app/org.vinegarhq.Vinegar/data/prefixes/studio/drive_c/users/<user>/AppData/Local/Roblox/Plugins/`
3. Open Roblox Studio. The **Roblox MCP** toolbar button will appear.
4. Enable **HTTP Requests** in *Game Settings → Security* (the plugin will attempt this automatically).
5. Start the bridge daemon once: `python3 /path/to/roblox_bridge_server.py` (optional if adapter auto-start is enabled).
6. Click **Start Bridge Polling** in the plugin widget and confirm the `client_id` text box value (defaults to your `PlaceId`).

### Option D — Register MCP server manually

If you already have the plugin installed, add this to your AI client's config:

```json
{
  "mcpServers": {
    "Roblox_Studio": {
      "command": "python3",
      "args": ["/path/to/roblox_mcp_server.py"]
    }
  }
}
```

- **Claude Desktop:** `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows)
- **Claude Code:** `claude mcp add Roblox_Studio --scope user -- python3 /path/to/roblox_mcp_server.py`
- **OpenAI Codex:** `~/.codex/config.toml`
- **OpenCode:** `~/.config/opencode/mcp.json` (fallback when CLI registration is unavailable)


### Bridge startup modes

You can run in either mode:

1. **Auto-start (default)**: each MCP adapter process tries to start the bridge if `http://localhost:28650/status` is unavailable.
2. **Manual bridge**: run `python3 /path/to/roblox_bridge_server.py` yourself, then launch one or more MCP adapter processes with `python3 /path/to/roblox_mcp_server.py --no-autostart`.

If the bridge is unavailable and auto-start is disabled, the adapter exits with:
`Bridge not running. Start it with: python roblox_bridge_server.py`.

### Multi-agent usage patterns

- **Multiple Studio places open at once**: each Studio window defaults `client_id` to its `PlaceId`. Use `studio_get_connection_status` / `GET /clients` to discover active clients, then pass `client_id` in tool calls to target a specific place.
- **Multiple agents → one place**: point all agents at the same `client_id` (typically the place id). Jobs serialize through the shared bridge queue.
- **Custom grouping**: type any string in the plugin `Client ID` box (for example `map-editor` or `scripting`) to route jobs to that logical Studio target.

## Building locally (Rojo)

```bash
# Install Rojo (https://rojo.space)
rojo build default.project.json --output RobloxMcpBridge.rbxm
```

The `default.project.json` maps `src/plugin/init.plugin.luau` as the plugin root script, with `Tools/` and `Utils/` as child ModuleScripts — matching how `require(script.Tools.*)` resolves at runtime.

## Project Structure

```
src/plugin/
├── init.plugin.luau         # Entry point: toolbar UI, polling loop, handler dispatch
├── Tools/
│   ├── InstanceTools.luau   # Instance hierarchy: create/delete/clone/reparent/tree/selection
│   ├── PropertyTools.luau   # Properties + attributes get/set
│   ├── TagTools.luau        # CollectionService tags
│   ├── ScriptTools.luau     # Read/write/patch/search/functions/find+replace
│   ├── EditorTools.luau     # ScriptEditorService open/list/close
│   ├── HistoryTools.luau    # Undo/redo/waypoints
│   ├── StudioTools.luau     # Run code, insert model, console output, run mode
│   ├── TerrainTools.luau    # Terrain fill/replace/read/clear tools
│   ├── BulkTools.luau       # Bulk create/set/delete/get-property operations
│   ├── BuildTools.luau      # Export/import instance subtrees as JSON
│   ├── AnalyzeTools.luau    # Analyze scripts / other instances.
│   └── DataModelTools.luau  # Place/workspace/team/lighting metadata tools
└── Utils/
    ├── Types.luau           # Rich type serialization / deserialization
    ├── Instances.luau       # Instance ID map and path resolution helpers
    ├── History.luau         # ChangeHistoryService recording helpers
    ├── Syntax.luau          # Lua syntax validation utilities
    ├── Logger.luau          # Widget log panel helper
    └── PluginUtils.luau     # Shared plugin-side utility helpers
```

## Supported Tools

| Category | Tools |
|---|---|
| Connection | `studio_get_connection_status`, `studio_list_connections` |
| Instance | `roblox_list_services`, `roblox_get_children`, `roblox_get_descendants`, `roblox_get_instance`, `roblox_find_instances`, `roblox_search_by_property`, `roblox_get_tree`, `roblox_create_instance`, `roblox_delete_instance`, `roblox_clone_instance`, `roblox_smart_duplicate`, `roblox_reparent_instance`, `roblox_set_name`, `roblox_select_instance`, `roblox_get_selection` |
| Properties & Attributes | `roblox_get_properties`, `roblox_get_all_properties`, `roblox_get_class_info`, `roblox_set_properties`, `roblox_get_attributes`, `roblox_set_attributes` |
| Tags | `roblox_get_tags`, `roblox_add_tag`, `roblox_remove_tag` |
| Scripts | `roblox_read_script`, `roblox_write_script`, `roblox_patch_script`, `roblox_get_script_lines`, `roblox_search_script`, `roblox_get_script_functions`, `roblox_search_across_scripts`, `roblox_find_and_replace_in_scripts` |
| Editor | `roblox_open_script`, `roblox_get_open_scripts`, `roblox_close_script` |
| History | `roblox_undo`, `roblox_redo`, `roblox_set_waypoint` |
| Studio | `roblox_run_code`, `roblox_insert_model`, `roblox_get_console_output`, `roblox_get_playtest_output`, `roblox_start_stop_play`, `roblox_get_studio_mode`, `roblox_run_script_in_play_mode` |
| Terrain | `roblox_terrain_fill_block`, `roblox_terrain_fill_ball`, `roblox_terrain_fill_cylinder`, `roblox_terrain_replace_material`, `roblox_terrain_read_voxels`, `roblox_terrain_clear_region` |
| Bulk | `roblox_bulk_create_instances`, `roblox_bulk_set_properties`, `roblox_bulk_delete_instances`, `roblox_bulk_get_properties` |
| DataModel | `roblox_get_place_info`, `roblox_set_lighting`, `roblox_get_workspace_info`, `roblox_get_team_list`, `roblox_get_lighting_effects` |
| Build | `roblox_export_build`, `roblox_import_build` |
| Analyze | `roblox_analyze_script` |

## Adding New Tools

1. Create (or edit) the appropriate module in `src/plugin/Tools/`.
2. Export your handler as a named function from the module.
3. Register it in the `handlers` table in `init.plugin.luau`.
