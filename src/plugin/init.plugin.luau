-- src/plugin/init.plugin.luau
-- Roblox Studio MCP Bridge Plugin v0.6
-- Entry point: builds UI, registers handlers, and runs the polling loop.

local HttpService = game:GetService("HttpService")

local Logger        = require(script.Parent.Utils.Logger)
local InstanceTools = require(script.Parent.Tools.InstanceTools)
local PropertyTools = require(script.Parent.Tools.PropertyTools)
local TagTools      = require(script.Parent.Tools.TagTools)
local ScriptTools   = require(script.Parent.Tools.ScriptTools)
local EditorTools   = require(script.Parent.Tools.EditorTools)
local HistoryTools  = require(script.Parent.Tools.HistoryTools)
local StudioTools   = require(script.Parent.Tools.StudioTools)
-- v0.6 additions
local TerrainTools   = require(script.Parent.Tools.TerrainTools)
local BulkTools      = require(script.Parent.Tools.BulkTools)
local DataModelTools = require(script.Parent.Tools.DataModelTools)
local AnalyzeTools = require(script.Parent.Tools.AnalyzeTools)

local BRIDGE_URL         = "http://127.0.0.1:28650"
local CLIENT_ID          = "studio"
local POLL_DELAY         = 0.05
local ERROR_DELAY        = 2
local RESULT_RETRY_MAX   = 3
local RESULT_RETRY_DELAY = 0.5

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local pluginToolbar    = plugin:CreateToolbar("Roblox MCP")
local openWidgetButton = pluginToolbar:CreateButton("Roblox MCP", "Open Roblox MCP bridge widget", "")
openWidgetButton.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 320, 300, 240, 200)
local widget     = plugin:CreateDockWidgetPluginGuiAsync("RobloxMcpBridgeWidget", widgetInfo)
widget.Title     = "Roblox MCP Bridge"

local uiPadding = Instance.new("UIPadding")
uiPadding.PaddingTop    = UDim.new(0, 8)
uiPadding.PaddingBottom = UDim.new(0, 8)
uiPadding.PaddingLeft   = UDim.new(0, 8)
uiPadding.PaddingRight  = UDim.new(0, 8)
uiPadding.Parent        = widget

local layout = Instance.new("UIListLayout")
layout.Padding   = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent    = widget

local statusLabel = Instance.new("TextLabel")
statusLabel.Size                   = UDim2.new(1, 0, 0, 24)
statusLabel.BackgroundTransparency = 1
statusLabel.TextXAlignment         = Enum.TextXAlignment.Left
statusLabel.Font                   = Enum.Font.SourceSans
statusLabel.TextSize               = 14
statusLabel.TextColor3             = Color3.new(1, 1, 1)
statusLabel.Text                   = "Status: stopped"
statusLabel.LayoutOrder            = 1
statusLabel.Parent                 = widget

local jobCountLabel = Instance.new("TextLabel")
jobCountLabel.Size                   = UDim2.new(1, 0, 0, 18)
jobCountLabel.BackgroundTransparency = 1
jobCountLabel.TextXAlignment         = Enum.TextXAlignment.Left
jobCountLabel.Font                   = Enum.Font.SourceSans
jobCountLabel.TextSize               = 12
jobCountLabel.TextColor3             = Color3.fromRGB(180, 180, 180)
jobCountLabel.Text                   = "Jobs completed: 0"
jobCountLabel.LayoutOrder            = 2
jobCountLabel.Parent                 = widget

local startButton = Instance.new("TextButton")
startButton.Size        = UDim2.new(1, 0, 0, 28)
startButton.Text        = "Start Bridge Polling"
startButton.Font        = Enum.Font.SourceSans
startButton.TextSize    = 14
startButton.LayoutOrder = 3
startButton.Parent      = widget

local stopButton = Instance.new("TextButton")
stopButton.Size        = UDim2.new(1, 0, 0, 28)
stopButton.Text        = "Stop Bridge Polling"
stopButton.Font        = Enum.Font.SourceSans
stopButton.TextSize    = 14
stopButton.LayoutOrder = 4
stopButton.Parent      = widget

local logFrame = Instance.new("ScrollingFrame")
logFrame.Size                = UDim2.new(1, 0, 1, -120)
logFrame.BackgroundColor3    = Color3.fromRGB(30, 30, 30)
logFrame.BorderSizePixel     = 1
logFrame.ScrollBarThickness  = 6
logFrame.CanvasSize          = UDim2.new(0, 0, 0, 0)
logFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
logFrame.LayoutOrder         = 5
logFrame.Parent              = widget

local logLayout = Instance.new("UIListLayout")
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Parent    = logFrame

local logger = Logger.new(logFrame)
local function log(msg) logger:log(msg) end

openWidgetButton.Click:Connect(function() widget.Enabled = not widget.Enabled end)

---------------------------------------------------------------------------
-- HttpService check
---------------------------------------------------------------------------
local function ensureHttpEnabled()
	if HttpService.HttpEnabled then log("HttpEnabled is already true"); return true end
	local ok = pcall(function() HttpService.HttpEnabled = true end)
	if ok and HttpService.HttpEnabled then log("HttpEnabled set to true"); return true end
	log("ERROR: Could not enable HttpService! Enable it in Game Settings → Security.")
	return false
end

---------------------------------------------------------------------------
-- HTTP helper
---------------------------------------------------------------------------
local function request(method, url, body)
	local req = { Url = url, Method = method }
	if body ~= nil then
		req.Headers = { ["Content-Type"] = "application/json" }
		req.Body    = HttpService:JSONEncode(body)
	end
	return HttpService:RequestAsync(req)
end

---------------------------------------------------------------------------
-- Handler dispatch table
---------------------------------------------------------------------------
local handlers = {
	-- Instance
	list_services     = InstanceTools.list_services,
	get_children      = InstanceTools.get_children,
	get_descendants   = InstanceTools.get_descendants,
	get_instance      = InstanceTools.get_instance,
	find_instances    = InstanceTools.find_instances,
	get_tree          = InstanceTools.get_tree,
	create_instance   = InstanceTools.create_instance,
	delete_instance   = InstanceTools.delete_instance,
	clone_instance    = InstanceTools.clone_instance,
	reparent_instance = InstanceTools.reparent_instance,
	set_name          = InstanceTools.set_name,
	select_instance   = InstanceTools.select_instance,
	get_selection     = InstanceTools.get_selection,
	-- Properties / Attributes
	get_properties    = PropertyTools.get_properties,
	get_all_properties = PropertyTools.get_all_properties,
	set_properties    = PropertyTools.set_properties,
	get_attributes    = PropertyTools.get_attributes,
	set_attributes    = PropertyTools.set_attributes,
	-- Tags
	get_tags   = TagTools.get_tags,
	add_tag    = TagTools.add_tag,
	remove_tag = TagTools.remove_tag,
	-- Scripts
	read_script           = ScriptTools.read_script,
	write_script          = ScriptTools.write_script,
	patch_script          = ScriptTools.patch_script,
	get_script_lines      = ScriptTools.get_script_lines,
	search_script         = ScriptTools.search_script,
	get_script_functions  = ScriptTools.get_script_functions,
	search_across_scripts = ScriptTools.search_across_scripts,
	-- ScriptEditor
	open_script      = EditorTools.open_script,
	get_open_scripts = EditorTools.get_open_scripts,
	close_script     = EditorTools.close_script,
	-- History
	undo         = HistoryTools.undo,
	redo         = HistoryTools.redo,
	set_waypoint = HistoryTools.set_waypoint,
	-- Studio / Execution
	run_code                = StudioTools.run_code,
	insert_model            = StudioTools.insert_model,
	get_console_output      = StudioTools.get_console_output,
	start_stop_play         = StudioTools.start_stop_play,
	get_studio_mode         = StudioTools.get_studio_mode,
	run_script_in_play_mode = StudioTools.run_script_in_play_mode,

	-- ── v0.6: Terrain ──────────────────────────────────────────────────────
	terrain_fill_block       = TerrainTools.terrain_fill_block,
	terrain_fill_ball        = TerrainTools.terrain_fill_ball,
	terrain_fill_cylinder    = TerrainTools.terrain_fill_cylinder,
	terrain_replace_material = TerrainTools.terrain_replace_material,
	terrain_read_voxels      = TerrainTools.terrain_read_voxels,
	terrain_clear_region     = TerrainTools.terrain_clear_region,

	-- ── v0.6: Bulk ─────────────────────────────────────────────────────────
	bulk_create_instances       = BulkTools.bulk_create_instances,
	bulk_set_properties         = BulkTools.bulk_set_properties,
	bulk_delete_instances       = BulkTools.bulk_delete_instances,
	find_and_replace_in_scripts = BulkTools.find_and_replace_in_scripts,

	-- ── v0.6: DataModel ────────────────────────────────────────────────────
	get_place_info       = DataModelTools.get_place_info,
	set_lighting         = DataModelTools.set_lighting,
	get_workspace_info   = DataModelTools.get_workspace_info,
	get_team_list        = DataModelTools.get_team_list,
	get_lighting_effects = DataModelTools.get_lighting_effects,
    analyze_script = AnalyzeTools.analyze_script
}

---------------------------------------------------------------------------
-- Polling loop
---------------------------------------------------------------------------
local running       = false
local connected     = false
local jobsCompleted = 0

local function updateStatus(text) statusLabel.Text = text end
local function updateJobCount() jobCountLabel.Text = "Jobs completed: " .. tostring(jobsCompleted) end

local function postResultWithRetry(payload)
	for attempt = 1, RESULT_RETRY_MAX do
		local ok, resp = pcall(function() return request("POST", BRIDGE_URL .. "/result", payload) end)
		if ok and resp and resp.Success then return true end
		if attempt < RESULT_RETRY_MAX then
			log("POST result attempt " .. attempt .. " failed, retrying...")
			task.wait(RESULT_RETRY_DELAY)
		else
			log("POST result FAILED after " .. RESULT_RETRY_MAX .. " attempts")
			if not ok then log("  Error: " .. tostring(resp)) elseif resp then log("  HTTP " .. tostring(resp.StatusCode)) end
		end
	end
	return false
end

local function pollLoop()
	local consecutiveErrors = 0

	while running do
		local ok, resp = pcall(function()
			return request("GET", BRIDGE_URL .. "/poll?client_id=" .. CLIENT_ID)
		end)

		if ok and resp and resp.Success then
			consecutiveErrors = 0
			if not connected then
				connected = true
				updateStatus("Status: running (connected)")
				log("Connected to bridge")
			end

			local decodeOk, payload = pcall(function() return HttpService:JSONDecode(resp.Body) end)
			if decodeOk and payload and payload.job then
				local job = payload.job
				log("Job: " .. tostring(job.type) .. " [" .. tostring(job.job_id) .. "]")

				local handler = handlers[job.type]
				local result, err
				if handler then
					local okH, hResult, hErr = pcall(handler, job.args or {})
					if okH then result, err = hResult, hErr
					else err = tostring(hResult); log("Handler error (" .. tostring(job.type) .. "): " .. err) end
				else
					err = "Unknown job type: " .. tostring(job.type)
					log(err)
				end

				postResultWithRetry({ job_id = job.job_id, ok = err == nil, result = result, error = err })
				jobsCompleted = jobsCompleted + 1
				updateJobCount()
			end
			task.wait(POLL_DELAY)
		else
			consecutiveErrors = consecutiveErrors + 1
			if connected then
				connected = false
				if not ok then log("Connection lost: " .. tostring(resp))
				elseif resp then log("Connection lost (HTTP " .. tostring(resp.StatusCode) .. ")") end
				updateStatus("Status: running (connection lost)")
			end
			task.wait(math.min(ERROR_DELAY * consecutiveErrors, 10))
		end
	end
	updateStatus("Status: stopped")
end

local function startPolling()
	if running then log("Already running"); return end
	if not ensureHttpEnabled() then updateStatus("Status: ERROR – HttpEnabled is false"); return end
	running   = true
	connected = false
	updateStatus("Status: starting...")
	log("Starting → " .. BRIDGE_URL)
	task.spawn(pollLoop)
end

local function stopPolling()
	if not running then return end
	running = false
	log("Polling stopped")
end

startButton.MouseButton1Click:Connect(startPolling)
stopButton.MouseButton1Click:Connect(stopPolling)

log("MCP Bridge plugin v0.6 loaded. Press 'Start Bridge Polling' to begin.")
