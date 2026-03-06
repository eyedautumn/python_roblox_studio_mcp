-- Tools/StudioTools.luau
-- Tools for play mode control, code execution, model insertion, and console output

local HttpService         = game:GetService("HttpService")
local InsertService       = game:GetService("InsertService")
local LogService          = game:GetService("LogService")
local RunService          = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local StudioTestService   = game:GetService("StudioTestService")

local History     = require(script.Parent.Parent.Utils.History)

---------------------------------------------------------------------------
-- Shared workspace attributes used by in-session stop monitors
---------------------------------------------------------------------------
local MCP_SESSION_ATTRIBUTE = "MCP_PLAY_SESSION_ID"

---------------------------------------------------------------------------
-- Insert model helpers
---------------------------------------------------------------------------
local INSERT_MAX_SEARCH_DEPTH  = 2048
local INSERT_MAX_DISTANCE_AWAY = 20

local function getInsertPosition()
	local camera  = workspace.CurrentCamera
	local vp      = camera.ViewportSize / 2
	local unitRay = camera:ViewportPointToRay(vp.X, vp.Y, 0)
	local params  = RaycastParams.new()
	params.BruteForceAllSlow = true
	local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * INSERT_MAX_SEARCH_DEPTH, params)
	return result and result.Position
		or camera.CFrame.Position + unitRay.Direction * INSERT_MAX_DISTANCE_AWAY
end

local function toTitleCase(str)
	return (str:gsub("(%a)([%w_']*)", function(f, r) return f:upper() .. r:lower() end):gsub("%s+", ""))
end

local function collapseIntoContainer(objects)
	if #objects == 0 then return nil end
	local hasPhysical = false
	for _, obj in ipairs(objects) do
		if obj:IsA("PVInstance") then hasPhysical = true; break end
	end
	if hasPhysical then
		local model = Instance.new("Model")
		for _, obj in ipairs(objects) do obj.Parent = model end
		return model
	end
	if #objects > 1 then
		local folder = Instance.new("Folder")
		for _, obj in ipairs(objects) do obj.Parent = folder end
		return folder
	end
	return objects[1]
end

local function loadAssetById(assetId)
	return collapseIntoContainer(game:GetObjects("rbxassetid://" .. tostring(assetId)))
end

local function searchFreeModels(query)
	local ok, results = pcall(function() return InsertService:GetFreeModels(query, 0) end)
	if not ok or not results or not results[1] then return {} end
	local ids = {}
	for i, item in ipairs(results[1].Results or {}) do
		if i > 6 then break end
		table.insert(ids, item.AssetId)
	end
	return ids
end

local function uniqueWorkspaceName(base)
	if not workspace:FindFirstChild(base) then return base end
	local i = 1
	while workspace:FindFirstChild(base .. i) do i += 1 end
	return base .. i
end

---------------------------------------------------------------------------
-- Console log buffer
---------------------------------------------------------------------------
local CONSOLE_LOG_LIMIT = 400
local PLAYTEST_LOG_LIMIT = 400
local STUDIO_MODE = "stop"
local consoleLogs = {}
local playtestLogs = {}
local playSessionToken = 0

LogService.MessageOut:Connect(function(message, messageType)
	local entry = {
		text      = tostring(message or ""),
		type      = messageType and tostring(messageType.Name) or "Unknown",
		timestamp = time(),
	}
	table.insert(consoleLogs, entry)
	if #consoleLogs > CONSOLE_LOG_LIMIT then table.remove(consoleLogs, 1) end

	if STUDIO_MODE ~= "stop" then
		table.insert(playtestLogs, entry)
		if #playtestLogs > PLAYTEST_LOG_LIMIT then table.remove(playtestLogs, 1) end
	end
end)

---------------------------------------------------------------------------
-- Play mode state
---------------------------------------------------------------------------
local function currentRunMode()
	if RunService:IsRunning() then
		return STUDIO_MODE == "run_server" and "run_server" or "start_play"
	end
	return "stop"
end
local function isStudioPlayMode(mode) return (mode or currentRunMode()) == "start_play" end

---------------------------------------------------------------------------
-- run_code – loadstring + getfenv output capture
---------------------------------------------------------------------------
local function getTableType(arg)
	local hasArray, hasTable = false, false
	for key in arg do
		if typeof(key) == "number" then hasArray = true else hasTable = true end
		if hasArray and hasTable then break end
	end
	return hasArray, hasTable
end

local function serializeArg(arg): any
	if typeof(arg) == "table" then
		local _, isTable = getTableType(arg)
		local out = {}
		for k, v in arg do
			local nk = serializeArg(k)
			out[if isTable then tostring(nk) else nk] = serializeArg(v)
		end
		return out
	elseif type(arg) == "userdata" then
		return tostring(arg) or "UNABLE_TO_SERIALIZE"
	end
	return arg
end

local function deepClone(t, cache)
	local clone = {}
	for key, value in t do
		local nk = key
		if typeof(key) == "table" then
			if not cache[key] then cache[key] = deepClone(key, cache) end
			nk = cache[key]
		end
		local nv = value
		if typeof(value) == "table" then
			if not cache[value] then cache[value] = deepClone(value, cache) end
			nv = cache[value]
		end
		clone[nk] = nv
	end
	return clone
end

local function toStrTable(t: { any }): { string }
	local cloned = deepClone(t, {})
	local out    = table.create(#cloned)
	for i, arg in cloned do
		local s = serializeArg(arg)
		out[i]  = if typeof(s) == "table" then HttpService:JSONEncode(s) else tostring(s)
	end
	return out
end

local function addToOutput(output: string, header: string, ...): string
	return output .. header .. " " .. table.concat(toStrTable(table.pack(...)), "\t") .. "\n"
end

local function runCodeWithOutput(command: string): string
	local output = ""
	local function executeCode()
		local chunk = loadstring(command) :: any
		local env   = getfenv(chunk)

		local oldPrint = env.print or print
		env.print = function(...)
			oldPrint(...)
			output = addToOutput(output, "[OUTPUT]", ...)
		end

		local oldWarn = env.warn or warn
		env.warn = function(...)
			oldWarn(...)
			output = addToOutput(output, "[WARNING]", ...)
		end

		local oldError = env.error or error
		env.error = function(...)
			oldError(...)
			output = addToOutput(output, "[ERROR]", ...)
		end

		local results = table.pack(chunk())
		if results.n > 0 then
			output = addToOutput(output, "[RETURNED RESULTS]", table.unpack(results, 1, results.n))
		end
	end
	local ok, err = pcall(executeCode)
	if not ok then output = addToOutput(output, "[UNEXPECTED ERROR]", err) end
	return output
end

---------------------------------------------------------------------------
-- run_script_in_play_mode – script injection + in-session stop monitor
---------------------------------------------------------------------------
local TEST_SCRIPT_NAME = "AssistantTestScript"
local CONTROL_SCRIPT_NAME = "AssistantPlayControlScript"

local function buildStopMonitorSource(sessionId: string): string
	return string.format([[
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")
if not RunService:IsRunning() then return end

local sessionId = %q
while true do
	if workspace:GetAttribute(%q) ~= sessionId then
		StudioTestService:EndTest({ success = false, error = "Stopped by MCP" })
		return
	end
	task.wait(0.2)
end
]], sessionId, MCP_SESSION_ATTRIBUTE)
end

local function buildTestRunnerSource(userCode: string, timeout: number, sessionId: string): string
	local timeoutStr = tostring(timeout)
	return string.format([[
local StudioTestService = game:GetService("StudioTestService")
local LogService        = game:GetService("LogService")
local RunService        = game:GetService("RunService")
if not RunService:IsRunning() then return end

-- ── Stop-signal monitor ──────────────────────────────────────────────────
task.spawn(function()
	while true do
		if workspace:GetAttribute(%q) ~= %q then
			StudioTestService:EndTest({ success = false, error = "Stopped by MCP" })
			return
		end
		task.wait(0.2)
	end
end)

-- ── Log capture ─────────────────────────────────────────────────────────
local capturedLogs = {}
local logConnection

local MESSAGE_TYPE_MAP = {
	[Enum.MessageType.MessageOutput]  = "output",
	[Enum.MessageType.MessageInfo]    = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError]   = "error",
}

logConnection = LogService.MessageOut:Connect(function(message, messageType)
	if string.sub(message, 1, 5) == "[MCP]" then return end
	table.insert(capturedLogs, {
		level   = MESSAGE_TYPE_MAP[messageType] or "output",
		message = message,
		ts      = os.clock(),
	})
end)

local startTime = os.clock()
local isTimeout = false
local isFinished = false

local function endTest(ok, result)
	if isFinished then return end
	isFinished = true
	local duration = os.clock() - startTime
	task.wait(0.1)
	if logConnection then logConnection:Disconnect() end
	local errors = {}
	for _, log in ipairs(capturedLogs) do
		if log.level == "error" or log.level == "warning" then
			table.insert(errors, log)
		end
	end
	StudioTestService:EndTest({
		success   = ok,
		value     = if ok then tostring(result) else nil,
		error     = if not ok then tostring(result) else nil,
		logs      = capturedLogs,
		errors    = errors,
		duration  = duration,
		isTimeout = isTimeout,
	})
end

-- ── Timeout watchdog ────────────────────────────────────────────────────
task.spawn(function()
	task.wait(%s)
	isTimeout = true
	endTest(false, "timeout")
end)

-- ── User code ───────────────────────────────────────────────────────────
local ok, result = pcall(function()
%s
end)
endTest(ok, result)
]], MCP_SESSION_ATTRIBUTE, sessionId, timeoutStr, userCode)
end

local function removeTestScript()
	local s = ServerScriptService:FindFirstChild(TEST_SCRIPT_NAME)
	if s then s:Destroy() end
end

local function removeControlScript()
	local s = ServerScriptService:FindFirstChild(CONTROL_SCRIPT_NAME)
	if s then s:Destroy() end
end

local function injectTestScript(code: string, timeout: number, sessionId: string)
	removeTestScript()
	local s    = Instance.new("Script")
	s.Name     = TEST_SCRIPT_NAME
	s.Source   = buildTestRunnerSource(code, timeout, sessionId)
	s.Parent   = ServerScriptService
end

local function injectControlScript(sessionId: string)
	removeControlScript()
	local s  = Instance.new("Script")
	s.Name   = CONTROL_SCRIPT_NAME
	s.Source = buildStopMonitorSource(sessionId)
	s.Parent = ServerScriptService
end

local function newSessionId()
	return HttpService:GenerateGUID(false)
end

local function setSessionId(id: string)
	workspace:SetAttribute(MCP_SESSION_ATTRIBUTE, id)
end

local function stopPlayViaSignal()
	setSessionId(newSessionId())
end

local function resetPlayState()
	removeTestScript()
	removeControlScript()
	workspace:SetAttribute(MCP_SESSION_ATTRIBUTE, nil)
	STUDIO_MODE = "stop"
end

local function startManualPlaySession(mode: string, executeAsync: () -> any)
	playSessionToken += 1
	local token = playSessionToken

	local sessionId = newSessionId()
	setSessionId(sessionId)
	STUDIO_MODE = mode
	playtestLogs = {}
	injectControlScript(sessionId)

	task.spawn(function()
		local success, err = pcall(executeAsync)
		if token ~= playSessionToken then return end
		if not success then
			warn("[MCP] Failed to start " .. tostring(mode) .. ": " .. tostring(err))
		end
		resetPlayState()
	end)
end

---------------------------------------------------------------------------
-- Public tool functions
---------------------------------------------------------------------------

local StudioTools = {}

function StudioTools.run_code(args)
	local code = args.code or args.script or args.source
	if not code or code == "" then return nil, "Missing code argument" end
	return { result = runCodeWithOutput(code) }
end

function StudioTools.run_script_in_play_mode(args)
	local code = args.code or args.script or args.source
	if not code or code == "" then return nil, "Missing code argument" end

	local timeout = args.timeout or 1_000_000
	if type(timeout) ~= "number" or timeout < 0 then
		return nil, "Timeout must be a positive number"
	end

	local sessionId = newSessionId()
	setSessionId(sessionId)
	playtestLogs = {}

	injectTestScript(code, timeout, sessionId)

	local success, result = pcall(function()
		if args.mode == "run_server" then
			STUDIO_MODE = "run_server"
			return StudioTestService:ExecuteRunModeAsync({})
		else
			STUDIO_MODE = "start_play"
			return StudioTestService:ExecutePlayModeAsync({})
		end
	end)

	STUDIO_MODE = "stop"
	resetPlayState()

	if not success then
		return nil, "Failed to run script in play mode: " .. tostring(result)
	end

	return { result = HttpService:JSONEncode(result) }
end

function StudioTools.insert_model(args)
	local query   = args.query or args.name or args.search
	local assetId = tonumber(args.assetId or args.asset_id or args.id or args.asset)

	if not query and not assetId then
		return nil, "Provide either 'query' (search string) or 'assetId' (numeric ID)"
	end

	local recording = History.recordUndo("MCP: Insert model")

	if not assetId then
		local ids = searchFreeModels(query)
		if #ids == 0 then
			History.finishUndo(recording, false)
			return nil, "No free models found for query: " .. tostring(query)
		end
		assetId = ids[1]
	end

	local ok, instance = pcall(loadAssetById, assetId)
	if not ok or not instance then
		History.finishUndo(recording, false)
		return nil, "Failed to load asset " .. tostring(assetId) .. ": " .. tostring(instance)
	end

	local baseName   = query and toTitleCase(query) or ("Asset" .. tostring(assetId))
	instance.Name    = uniqueWorkspaceName(baseName)
	instance.Parent  = workspace

	if instance:IsA("Model") then
		pcall(function() instance:PivotTo(CFrame.new(getInsertPosition())) end)
	end

	History.finishUndo(recording, true)

	local Instances = require(script.Parent.Parent.Utils.Instances)
	local info      = Instances.serializeInstance(instance)
	info.assetId    = assetId
	return info
end

function StudioTools.get_console_output(args)
	local since      = args.since or 0
	local maxEntries = math.min(args.maxEntries or CONSOLE_LOG_LIMIT, CONSOLE_LOG_LIMIT)
	local result = {}
	for i = #consoleLogs, 1, -1 do
		local entry = consoleLogs[i]
		if entry and entry.timestamp >= since then
			table.insert(result, 1, entry)
		end
		if #result >= maxEntries then break end
	end
	return {
		logs            = result,
		count           = #result,
		latestTimestamp = consoleLogs[#consoleLogs] and consoleLogs[#consoleLogs].timestamp,
	}
end


function StudioTools.get_playtest_output(args)
	local since      = args.since or 0
	local maxEntries = math.min(args.maxEntries or PLAYTEST_LOG_LIMIT, PLAYTEST_LOG_LIMIT)
	local result = {}
	for i = #playtestLogs, 1, -1 do
		local entry = playtestLogs[i]
		if entry and entry.timestamp >= since then
			table.insert(result, 1, entry)
		end
		if #result >= maxEntries then break end
	end
	return {
		logs            = result,
		count           = #result,
		latestTimestamp = playtestLogs[#playtestLogs] and playtestLogs[#playtestLogs].timestamp,
	}
end

function StudioTools.start_stop_play(args)
	local requested = args.mode or args.action or args.state or args.command or args.name
	if not requested then
		return nil, "Unknown Studio mode (supported: start_play, stop, run_server)"
	end

	if requested == "start_play" then
		if STUDIO_MODE ~= "stop" then
			return nil, "Studio is already transitioning or running a play session"
		end
		startManualPlaySession("start_play", function()
			StudioTestService:ExecutePlayModeAsync({})
		end)
		return { mode = "start_play", message = "Started play" }

	elseif requested == "run_server" then
		if STUDIO_MODE ~= "stop" then
			return nil, "Studio is already transitioning or running a play session"
		end
		startManualPlaySession("run_server", function()
			StudioTestService:ExecuteRunModeAsync({})
		end)
		return { mode = "run_server", message = "Ran server" }

	elseif requested == "stop" then
		playSessionToken += 1
		stopPlayViaSignal()
		pcall(function() StudioTestService:EndTest({}) end)
		resetPlayState()
		return { mode = "stop", message = "Stop signal sent" }
	end

	return nil, "Unknown Studio mode (supported: start_play, stop, run_server)"
end

function StudioTools.get_studio_mode()
	local mode = currentRunMode()
	return { mode = mode or "Unknown", isPlay = isStudioPlayMode(mode) }
end

return StudioTools
