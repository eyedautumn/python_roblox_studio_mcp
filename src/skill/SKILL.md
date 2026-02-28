---
name: roblox-studio-mcp
description: Bridge any MCP client to Roblox Studio via MCP tools and a local Studio plugin. Use when you need to read or edit Roblox instances, scripts, attributes, properties, or tags in a live Studio session, or to automate place changes from a local MCP client. Includes setup steps for Vinegar/Wine environments on Linux.
---

# Roblox Studio MCP

## Overview
Connect to a running Roblox Studio session through a local MCP server and a Studio plugin. The plugin polls a local HTTP bridge and exposes tools for reading and editing instances, scripts, attributes, properties, and tags. All mutations are tracked by ChangeHistoryService and can be undone with Ctrl+Z or the `roblox_undo` tool.

## Core Capabilities
1. Connect and verify Studio status
2. Read instance trees, attributes, properties, and tags
3. Edit scripts (full rewrite or surgical line-level patches with content validation)
4. Search scripts and read specific line ranges to minimize context usage
5. Search across ALL scripts in the codebase for a string or pattern
6. List function definitions in a script for structural understanding
7. Create, delete, clone, and reparent instances
8. Get compact tree views of the instance hierarchy
9. Select instances in Studio and read current selection
10. Open, close, and list scripts in the Studio script editor (ScriptEditorService)
11. Undo/redo changes and set named waypoints (ChangeHistoryService)
12. Rich type support for properties: Color3, Vector3, Vector2, CFrame, UDim, UDim2, BrickColor, EnumItem, NumberRange, NumberSequence, ColorSequence, Rect, PhysicalProperties, Ray, Font, Axes, Faces
13. Execute ad-hoc Lua with `roblox_run_code` or `roblox_run_script_in_play_mode` and get the serialized return value plus any Output log messages.
14. Control Studio (insert assets, toggle run modes, stream console output) with `roblox_insert_model`, `roblox_start_stop_play`, `roblox_get_console_output`, `roblox_get_playtest_output`, and `roblox_get_studio_mode`.
15. Use advanced hierarchy workflows: property-based instance search (`roblox_search_by_property`), reflection metadata (`roblox_get_class_info`), smart duplication (`roblox_smart_duplicate`), bulk property reads (`roblox_bulk_get_properties`), and build export/import (`roblox_export_build`, `roblox_import_build`).

## Quick Start
1. Start the MCP bridge server (stdio + HTTP bridge):
   - `python3 /home/dani/.codex/skills/roblox-studio-mcp/scripts/roblox_mcp_server.py`
2. Install the Studio plugin into the Wine/Vinegar Plugins folder:
   - `python3 /home/dani/.codex/skills/roblox-studio-mcp/scripts/find_plugin_dir.py`
   - `python3 /home/dani/.codex/skills/roblox-studio-mcp/scripts/install_plugin.py --plugin-dir <path>`
3. Open Roblox Studio via Vinegar.
4. Open the "Roblox MCP" widget from the Plugins toolbar and click "Start Bridge Polling".
5. Verify connection:
   - Use tool `studio.get_connection_status` (expects `connected: true`).

## Architecture & Reliability
The bridge uses a **threaded HTTP server** so that long-poll requests from the plugin don't block result submissions. Key design choices:

- **Short poll timeout (5s):** The server holds `/poll` requests for at most 5 seconds before returning an empty response. This avoids exhausting Roblox Studio's limited HTTP request budget.
- **Result post retries:** The plugin retries failed result POST requests up to 3 times with a 0.5s delay between attempts, preventing silent job loss.
- **Pre-flight connection check:** When a tool is called, the server checks whether Studio has polled recently before enqueuing a job. If Studio is disconnected, the tool fails immediately with a clear error.
- **UUID-based job IDs:** Jobs use `uuid4` hex strings to eliminate ID collisions under concurrent use.
- **Stale instance cleanup:** The plugin validates that cached debug IDs still reference live instances before using them.
- **Exponential backoff on errors:** The plugin increases delay between polls when the bridge is unreachable.
- **Undo integration:** Every mutation (create, delete, rename, set properties, write/patch scripts, tags, attributes) creates a ChangeHistoryService recording that can be undone with Ctrl+Z.

## Notes
- If you change the HTTP port, update both:
  - Server flag: `--http-port <port>`
  - Plugin constant: `BRIDGE_URL` in `assets/roblox_mcp_plugin.lua`
- Server flags for tuning: `--poll-timeout <sec>` (default 5), `--job-timeout <sec>` (default 30), `--quiet` (suppress HTTP request logs).
- Prefer `http://127.0.0.1:<port>` in the plugin to avoid IPv6 `localhost` resolution issues in Wine/Vinegar.
- Ensure Studio allows HTTP requests in game settings (`HttpService.HttpEnabled = true`).

## Usage Guidance

### Instance navigation
- Use `roblox_get_tree` for an efficient overview of the hierarchy instead of chaining `get_children` calls. Tune `maxDepth` and `maxChildren` to control size.
- Use `roblox_find_instances` to locate objects by name, className, or tag, then operate by returned `id`.
- Use `roblox_search_by_property` when you need value equality matching (e.g. all parts where `Material == Neon`) and optionally restrict with `className`.
- Use `roblox_get_selection` to see what the user has selected in the Explorer panel.
- Prefer `pathArray` over `path` for reliable instance targeting.

### Rich type properties
When reading properties with `roblox_get_properties`, complex types are returned as objects with a `_type` field:
```json
{
  "Color": {"_type": "Color3", "r": 255, "g": 128, "b": 0},
  "Position": {"_type": "Vector3", "x": 10, "y": 5, "z": 0},
  "Material": {"_type": "EnumItem", "enumType": "Material", "name": "Neon", "value": 288}
}
```
When setting properties with roblox_set_properties, pass the same format:
```json
{
  "properties": {
    "Color": {"_type": "Color3", "r": 255, "g": 0, "b": 0},
    "Size": {"_type": "Vector3", "x": 4, "y": 1, "z": 2},
    "Material": {"_type": "EnumItem", "enumType": "Material", "name": "Neon"},
    "Anchored": true,
    "Name": "LavaPart"
  }
}
```

Supported _type values: Color3, Vector3, Vector2, CFrame, UDim, UDim2, BrickColor, EnumItem, NumberRange, NumberSequence, ColorSequence, Rect, PhysicalProperties, Ray, Font, Axes, Faces. Simple types (string, number, boolean) are passed directly without _type.

### Script editing – safe workflow (IMPORTANT)
##### NEVER use roblox_write_script on existing scripts with more than ~30 lines. Use roblox_patch_script instead.
##### ALWAYS provide expectedContent on replace and delete patch ops. This prevents blind overwrites and catches stale line numbers.
##### ALWAYS provide expectedContext on insert patch ops. This is REQUIRED to prevent unsafe insertions inside functions.
##### ALWAYS read the lines you plan to edit (get_script_lines or search_script) immediately before patching. Do not rely on line numbers from earlier in the conversation.
When making multiple patches in one call, work bottom-to-top (highest line numbers first) to avoid line-number shift issues, OR account for the shift in subsequent patches.
If a patch fails with CONTENT MISMATCH or CONTEXT MISMATCH, re-read the affected lines and retry with corrected line numbers and expectedContent/expectedContext.

**Enhanced Safety Features:**
- **Global variable protection**: Delete operations warn if they would delete code containing global variables (prevents breaking other code)
- **Enhanced syntax validation**: Validates bracket/parenthesis matching AND function/end block pairing after all patches are applied (catches syntax errors before they're committed)
- **Indentation preservation**: Automatically preserves proper indentation when inserting or replacing code
- **Context validation**: Insert operations require `expectedContext` to ensure you're inserting at the correct location

All script mutations are undoable via Ctrl+Z or roblox_undo.
Scripts are automatically updated in ScriptEditorService if open - you don't need to close and reopen them.
Safe editing workflow:
search_script query="function onDamage" → find line 142
get_script_lines startLine=140 endLine=160 → read actual content
patch_script patches=[{
op: "replace",
lineStart: 145,
lineEnd: 150,
expectedContent: "<the 6 lines you just read>",
content: "<your replacement>"
}]

Safe insert workflow:
get_script_lines startLine=50 endLine=52 → read lines around insertion point
patch_script patches=[{
op: "insert",
lineStart: 51,
expectedContext: "<exact content of line 50>",
content: "<new code to insert>"
}]

### Studio helpers
- Run lightweight Lua with `roblox_run_code`. Watch the buffered Output log with `roblox_get_console_output` if you need to capture what `print` or `warn` emitted.
- Use `roblox_get_playtest_output` for logs emitted specifically during Play/Run sessions, independent from the general Studio buffer.
- Drop a published asset directly into Workspace with `roblox_insert_model`, then inspect the serialized instance to continue working with it.
- Switch Studio between Play/Run/Edit via `roblox_start_stop_play`, use `roblox_get_studio_mode` to confirm the current mode, and execute gameplay-only snippets through `roblox_run_script_in_play_mode` while run mode is active.

Script editor management
Use roblox_open_script to open a script in Studio's editor and jump to a specific line. Useful after finding something with search_script or search_across_scripts.
Use roblox_get_open_scripts to see what tabs are open in the editor.
Use roblox_close_script to close a script's editor tab.
Undo/Redo
All mutations automatically create ChangeHistoryService waypoints with descriptive names (e.g., "MCP: Create Part", "MCP: Patch script DamageHandler").
Use roblox_undo / roblox_redo to programmatically undo/redo changes.
Use roblox_set_waypoint to add an explicit named waypoint, e.g., before a batch of related changes you want to undo as a group.
The user can also undo all MCP changes manually with Ctrl+Z in Studio.
Understanding code structure
Use roblox_get_script_functions to list all function definitions with line numbers before editing.
Use roblox_search_across_scripts to find where a function, variable, or string is used across the entire codebase.
Properties, attributes, and tags
Use roblox_get_properties / roblox_set_properties for built-in properties (now with rich type support).
Use roblox_get_class_info to inspect a class definition (property names/types/deprecation) without needing a live instance.
Use roblox_get_attributes / roblox_set_attributes for custom attributes.
Use roblox_get_tags, roblox_add_tag, roblox_remove_tag for CollectionService tags.
Creating and duplicating
Use roblox_create_instance to create new instances with properties set in one call (supports rich types).
Use roblox_clone_instance to duplicate an existing instance (with optional reparent and rename).
Use roblox_smart_duplicate for N clones in one undo step with optional per-clone Vector3 offset and optional new parent.
Use roblox_bulk_get_properties when reading one property across many instances to reduce round-trips.
Use roblox_export_build / roblox_import_build to snapshot and reconstruct an entire subtree as JSON.

### Performance Best Practices & Preventing Lag

#### Memory Management & Cleanup with Trove

**ALWAYS use Trove for cleanup** - It's the industry standard for managing connections, threads, and instances in roblox_

**What is Trove?**
Trove is a cleanup library that automatically disconnects connections, cancels threads, and destroys instances when the parent is destroyed. It prevents memory leaks and connection buildup.

**Basic Trove Usage:**
```lua
local Trove = require(path.to.Trove)

local MyModule = {}
MyModule.__index = MyModule

function MyModule.new()
    local self = setmetatable({}, MyModule)
    self._trove = Trove.new() -- Create a new Trove
    
    -- Add connections to Trove (auto-disconnects on cleanup)
    self._trove:Connect(SomeEvent, function()
        -- event handler
    end)
    
    -- Add threads to Trove (auto-cancels on cleanup)
    self._trove:Add(task.spawn(function()
        while true do
            -- loop code
            task.wait(1)
        end
    end))
    
    -- Add instances to Trove (auto-destroys on cleanup)
    local part = Instance.new("Part")
    self._trove:Add(part)
    
    -- Cleanup everything when done
    self._trove:Clean()
    
    return self
end
```

**Trove Methods:**
- `trove:Connect(signal, callback)` - Connect to an event (auto-disconnects)
- `trove:Add(item)` - Add connection, thread, or instance to cleanup
- `trove:AddPromise(promise)` - Cleanup promise chains
- `trove:Clean()` - Manually trigger cleanup (usually not needed if parent is destroyed)
- `trove:Extend()` - Create a child Trove that cleans up when parent does

**When to Use Trove:**
- ✅ Module scripts that create connections or threads
- ✅ Controllers that manage game systems
- ✅ UI components that have event listeners
- ✅ Any code that creates instances, connections, or threads that need cleanup
- ❌ DON'T use for simple utility functions that don't create resources

#### Connection Management

**NEVER leave connections active without cleanup:**
```lua
-- ❌ BAD - Connection never disconnects, causes memory leak
SomeEvent:Connect(function()
    -- handler
end)

-- ✅ GOOD - Connection is managed by Trove
local trove = Trove.new()
trove:Connect(SomeEvent, function()
    -- handler
end)
```

**For temporary connections, disconnect manually:**
```lua
local connection = SomeEvent:Connect(function()
    -- handler
end)

-- Later, when done:
connection:Disconnect()
```

#### Thread Management

**NEVER create infinite loops without cleanup:**
```lua
-- ❌ BAD - Thread runs forever, can't be stopped
task.spawn(function()
    while true do
        -- code
        task.wait(1)
    end
end)

-- ✅ GOOD - Thread is managed by Trove
local trove = Trove.new()
trove:Add(task.spawn(function()
    while true do
        -- code
        task.wait(1)
    end
end))
```

**Use RunService for frame-based loops:**
```lua
local RunService = game:GetService("RunService")
local trove = Trove.new()

-- Heartbeat runs every frame (60 FPS)
trove:Connect(RunService.Heartbeat, function(deltaTime)
    -- frame-based code
end)

-- RenderStepped runs before rendering (better for visual updates)
trove:Connect(RunService.RenderStepped, function(deltaTime)
    -- rendering code
end)
```

#### Instance Management

**Destroy instances when no longer needed:**
```lua
-- ✅ GOOD - Instance is managed by Trove
local part = Instance.new("Part")
trove:Add(part)
-- Automatically destroyed when trove cleans up

-- ✅ ALTERNATIVE - Manual cleanup
local part = Instance.new("Part")
-- Later:
part:Destroy()
```

**Avoid creating instances in loops without cleanup:**
```lua
-- ❌ BAD - Creates many instances without cleanup
for i = 1, 100 do
    local part = Instance.new("Part")
    part.Parent = workspace
end

-- ✅ GOOD - Instances are tracked and cleaned up
local trove = Trove.new()
for i = 1, 100 do
    local part = Instance.new("Part")
    part.Parent = workspace
    trove:Add(part)
end
```

#### Performance Optimization Tips

**1. Minimize Property Changes**
- Batch property changes when possible
- Avoid changing properties every frame (use debouncing/throttling)
- Cache frequently accessed properties

**2. Optimize Loops**
- Use `task.wait()` instead of `wait()` (more efficient)
- Use `task.spawn()` for async operations
- Avoid tight loops that run every frame unless necessary
- Use RunService events (Heartbeat, RenderStepped) for frame-based updates

**3. Reduce Instance Count**
- Reuse instances when possible (object pooling)
- Destroy unused instances immediately
- Use `:Clone()` sparingly - prefer reusing existing instances

**4. Optimize String Operations**
- Cache string concatenations
- Use `string.format()` for complex strings
- Avoid string operations in tight loops

**5. Minimize Remote Events**
- Batch data when sending over remotes
- Use rate limiting to prevent spam
- Cache remote event references

**6. UI Performance**
- Use `AutomaticSize` instead of manual sizing when possible
- Minimize UI updates (update only when data changes)
- Use `TextScaled` instead of `TextSize` for responsive text
- Avoid updating UI every frame (use events/data binding)

**7. Physics Optimization**
- Set `Anchored = true` for static parts
- Use `CanCollide = false` when collision isn't needed
- Minimize `CanTouch` events (use Region3 or spatial queries instead)
- Use `AssemblyLinearVelocity` and `AssemblyAngularVelocity` for moving parts instead of TweenService when possible

**8. Memory Management**
- Clear large tables when no longer needed: `table.clear(largeTable)`
- Use weak references for caches: `setmetatable(cache, {__mode = "v"})`
- Avoid storing references to destroyed instances

**9. Event Optimization**
- Disconnect events when not needed
- Use Trove for automatic cleanup
- Avoid connecting to events in loops
- Cache event references instead of looking them up repeatedly

**10. Script Organization**
- Use ModuleScripts to avoid code duplication
- Lazy-load modules (require only when needed)
- Avoid global variables (use modules for shared state)

#### Common Performance Anti-Patterns

**❌ DON'T:**
- Create connections in loops without cleanup
- Use `wait()` in loops (use `task.wait()`)
- Update UI every frame unnecessarily
- Create instances without destroying them
- Leave threads running indefinitely
- Use `:FindFirstChild()` repeatedly (cache the result)
- Change properties every frame
- Use `:GetChildren()` in tight loops (cache the result)

**✅ DO:**
- Use Trove for all cleanup
- Cache frequently accessed instances/properties
- Use RunService events for frame-based updates
- Destroy instances when done
- Disconnect events when done
- Use `task.spawn()` and `task.wait()` instead of `spawn()` and `wait()`
- Batch property changes
- Use object pooling for frequently created/destroyed instances

#### Example: Proper Module with Trove

```lua
local Trove = require(ReplicatedStorage.Packages.Trove)
local RunService = game:GetService("RunService")

local MyController = {}
MyController.__index = MyController

function MyController.new()
    local self = setmetatable({}, MyController)
    self._trove = Trove.new()
    
    -- Connect to events
    self._trove:Connect(workspace.ChildAdded, function(child)
        -- handle child added
    end)
    
    -- Create managed instances
    local part = Instance.new("Part")
    part.Parent = workspace
    self._trove:Add(part)
    
    -- Frame-based update loop
    self._trove:Connect(RunService.Heartbeat, function(deltaTime)
        -- update logic
    end)
    
    -- Cleanup when parent is destroyed
    self._trove:Connect(part.AncestryChanged, function()
        if not part.Parent then
            self._trove:Clean()
        end
    end)
    
    return self
end

return MyController
```

### Common Mistakes to Avoid
Using write_script on large existing scripts — use patch_script with expectedContent.
Patching without reading first — line numbers shift as the script is edited.
Omitting expectedContent — a replace/delete op blindly overwrites whatever is at those line numbers.
Multiple patches without accounting for shifts — work bottom-to-top to avoid this.
Using path with names containing dots — use pathArray instead.
Passing raw numbers for Color3 — use {"_type": "Color3", "r": 255, "g": 0, "b": 0} format.
Forgetting that changes are undoable — if something goes wrong, use roblox_undo to revert.
When Things Fail
If connected: false, make sure the plugin is installed and Studio is running with "Start Bridge Polling" clicked.
If a tool returns "Studio is not connected", the plugin hasn't polled recently.
Ensure HttpService.HttpEnabled is allowed in Studio game settings.
Make sure the MCP server is running on 127.0.0.1:28650.
If a patch_script returns CONTENT MISMATCH, re-read the lines and retry.
If a mutation went wrong, use roblox_undo to revert it.
Check the plugin's widget log (including the job counter) and Studio Output for error details.

### Resources
scripts/
 - roblox_mcp_server.py: MCP server + HTTP bridge
 
references/

- protocol.md: MCP tools, job format, instance resolution, rich types, and patch operations
- rlab.md: RLAB (Roblox Luau AI Benchmark) instructions for exercising tool-based Luau editing
