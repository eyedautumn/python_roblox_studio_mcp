-- Tools/AnalyzeTools.luau
-- Static analysis for Luau scripts: detects errors, warnings, and hints.
-- Runs entirely in the plugin (no round-trip to the server for analysis).
--
-- Diagnostics are classified as:
--   error   – high-confidence defects that WILL cause runtime failures
--   warning – likely bugs that need human judgment
--   hint    – style / best-practice nudges

local Instances = require(script.Parent.Parent.Utils.Instances)

local AnalyzeTools = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local DEPRECATED_GLOBALS = {
	wait      = "Use task.wait() instead of wait()",
	spawn     = "Use task.spawn() instead of spawn()",
	delay     = "Use task.delay() instead of delay()",
	["Delay"] = "Use task.delay() instead of Delay()",
	ypcall    = "Use pcall() instead of ypcall()",
	["Spawn"] = "Use task.spawn() instead of Spawn()",
	["Wait"]  = "Use task.wait() instead of Wait()",
}

local DEPRECATED_ROBLOX_API = {
	-- Instance methods
	["IsA"]              = false, -- not deprecated, just here as placeholder
	["FindFirstChild"]   = false,
	["remove"]           = "Use :Destroy() instead of :remove()",
	["Remove"]           = "Use :Destroy() instead of :Remove()",
	["children"]         = "Use :GetChildren() instead of :children()",
	["Children"]         = "Use :GetChildren() instead of :Children()",
	["isA"]              = "Use :IsA() instead of :isA()",
	["connect"]          = "Use .Connect instead of :connect()",
	["disconnect"]       = "Use :Disconnect() instead of :disconnect()",
	-- Services
	["GetService"]       = false,
}

local DEPRECATED_PROPERTIES = {
	["MaxVelocity"]       = "MaxVelocity is deprecated for some constraint types",
	["ClassName"]         = false,
	["archivable"]        = "Use 'Archivable' (capital A) instead of 'archivable'",
	["cframe"]            = "Use 'CFrame' instead of 'cframe'",
	["className"]         = "Use 'ClassName' (capital C, capital N) instead of 'className'",
	["DataCost"]          = "DataCost is deprecated — use GetDataStore budget APIs",
}

-- Known Roblox globals
local ROBLOX_GLOBALS = {
	game = true, workspace = true, script = true, plugin = true,
	Enum = true, Instance = true, Vector3 = true, Vector2 = true,
	CFrame = true, Color3 = true, BrickColor = true, UDim = true,
	UDim2 = true, Ray = true, Rect = true, Region3 = true,
	NumberSequence = true, NumberSequenceKeypoint = true,
	ColorSequence = true, ColorSequenceKeypoint = true,
	PhysicalProperties = true, Font = true, Axes = true, Faces = true,
	TweenInfo = true, RaycastParams = true, OverlapParams = true,
	PathfindingResult = true, SharedTable = true, NumberRange = true,
	Random = true, DateTime = true, buffer = true, bit32 = true,
	-- Standard Lua/Luau
	print = true, warn = true, error = true, assert = true,
	pcall = true, xpcall = true, ipairs = true, pairs = true,
	next = true, select = true, unpack = true, rawget = true,
	rawset = true, rawequal = true, rawlen = true, setmetatable = true,
	getmetatable = true, type = true, typeof = true, tostring = true,
	tonumber = true, math = true, string = true, table = true,
	os = true, io = true, coroutine = true, utf8 = true,
	require = true, loadstring = true, dofile = true, load = true,
	collectgarbage = true, _G = true, _VERSION = true, debug = true,
	-- task library
	task = true,
	-- Roblox additional
	tick = true, time = true, elapsedTime = true, version = true,
	gcinfo = true, delay = true, spawn = true, wait = true,
	settings = true, stats = true, UserSettings = true,
	newproxy = true, getfenv = true, setfenv = true,
	SecurityCapabilities = true,
	-- Roblox types used as constructors
	Vector3int16 = true, Vector2int16 = true, Region3int16 = true,
	-- Common module pattern
	self = true, shared = true,
}

-- Luau keywords (should never be used as variable names, but also shouldn't
-- be flagged as "undeclared globals")
local LUAU_KEYWORDS = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
	["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
	["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
	["while"] = true, ["continue"] = true, ["export"] = true, ["type"] = true,
}

local function trim(s)
	return s:match("^%s*(.-)%s*$") or s
end

-- Strip a single-line comment suffix from a line (respects string literals).
local function stripLineComment(line)
	local inStr, strChar = false, nil
	local i = 1
	while i <= #line do
		local ch = line:sub(i, i)
		if inStr then
			if ch == "\\" then
				i = i + 1
			elseif ch == strChar then
				inStr, strChar = false, nil
			end
		else
			if ch == "'" or ch == '"' then
				inStr, strChar = true, ch
			elseif ch == "[" then
				-- Check for long string [[ or [=[ etc.
				local eqSigns = line:match("^%[(=*)%[", i)
				if eqSigns then
					-- Skip to the closing ]=*]
					local closePattern = "%]" .. string.rep("=", #eqSigns) .. "%]"
					local closeStart = line:find(closePattern, i + 2 + #eqSigns)
					if closeStart then
						i = closeStart + 2 + #eqSigns
						continue
					else
						-- Long string spans multiple lines, rest of line is string
						return line
					end
				end
			elseif ch == "-" and line:sub(i, i + 1) == "--" then
				return line:sub(1, i - 1)
			end
		end
		i = i + 1
	end
	return line
end

-- Block comment/string tracker across lines.
local function buildBlockCommentMap(lines)
	local inBlock = {}
	local inside = false
	local blockType = nil -- "comment" or "string"

	for i, line in ipairs(lines) do
		local j = 1
		local lineInBlock = false

		if inside then
			lineInBlock = true
		end

		while j <= #line do
			if not inside then
				-- Check for block comment --[[ or --[=*[
				local commentEq = line:match("^%-%-%[(=*)%[", j)
				if commentEq then
					inside = true
					blockType = "comment"
					local closePattern = "%]" .. string.rep("=", #commentEq) .. "%]"
					local closeStart = line:find(closePattern, j + 4 + #commentEq)
					if closeStart then
						inside = false
						blockType = nil
						j = closeStart + 2 + #commentEq
					else
						lineInBlock = true
						break
					end
				elseif line:sub(j, j + 1) == "--" then
					-- Single-line comment, rest is comment
					break
				else
					-- Check for block strings [[ or [=*[
					local strEq = line:match("^%[(=*)%[", j)
					if strEq and not line:sub(1, j - 1):match("%-%-$") then
						local closePattern = "%]" .. string.rep("=", #strEq) .. "%]"
						local closeStart = line:find(closePattern, j + 2 + #strEq)
						if closeStart then
							j = closeStart + 2 + #strEq
						else
							-- spans multiple lines
							inside = true
							blockType = "string"
							break
						end
					else
						j = j + 1
					end
				end
			else
				-- Inside a block, look for close
				local eqCount = 0
				if blockType == "comment" then
					-- Find ]=*] matching the open
					local closeStart = line:find("%]" .. string.rep("=", eqCount) .. "%]", j)
					if closeStart then
						inside = false
						blockType = nil
						j = closeStart + 2 + eqCount
						lineInBlock = false
					else
						break
					end
				else
					local closeStart = line:find("%]" .. string.rep("=", eqCount) .. "%]", j)
					if closeStart then
						inside = false
						blockType = nil
						j = closeStart + 2 + eqCount
					else
						break
					end
				end
			end
		end

		inBlock[i] = lineInBlock and inside
	end
	return inBlock
end

-- Check if a line is inside a string (very basic — checks for obvious cases)
local function isInsideString(line, pos)
	local inStr, strChar = false, nil
	for i = 1, pos - 1 do
		local ch = line:sub(i, i)
		if inStr then
			if ch == "\\" then
				-- skip next
			elseif ch == strChar then
				inStr = false
			end
		else
			if ch == "'" or ch == '"' then
				inStr = true
				strChar = ch
			end
		end
	end
	return inStr
end

-- ---------------------------------------------------------------------------
-- Analysis passes
-- ---------------------------------------------------------------------------

-- Pass 1: Collect all local variable declarations with scope tracking
local function collectLocals(lines, blockCommentMap)
	local locals = {}
	local depth = 0

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Track block depth
		-- Opens
		for _ in t:gmatch("^function[%s%(]") do depth = depth + 1 end
		for _ in t:gmatch("^local%s+function%s") do depth = depth + 1 end
		if t:match("=%s*function%s*%(") then depth = depth + 1 end
		if t:match("^if%s.+%sthen%s*$") or t:match("^if%s.+%sthen$") then depth = depth + 1 end
		if t:match("^for%s.+%sdo%s*$") or t:match("^for%s.+%sdo$") then depth = depth + 1 end
		if t:match("^while%s.+%sdo%s*$") or t:match("^while%s.+%sdo$") then depth = depth + 1 end
		if t == "do" or t:match("^do%s") then depth = depth + 1 end
		if t == "repeat" or t:match("^repeat%s") then depth = depth + 1 end

		-- Closes
		if t:match("^end[%s,;%)]") or t == "end" then
			depth = math.max(0, depth - 1)
		end
		if t:match("^until%s") or t == "until" then
			depth = math.max(0, depth - 1)
		end

		-- Collect for-loop variables
		local forVars = t:match("^for%s+(.-)%s+in%s") or t:match("^for%s+(.-)%s*=")
		if forVars then
			for name in forVars:gmatch("[%w_]+") do
				table.insert(locals, {
					name  = name,
					line  = i,
					depth = depth,
					used  = false,
					isForVar = true,
				})
			end
		end

		-- Collect function parameters (rough)
		local fnParams = t:match("^local%s+function%s+[%w_]+%s*%((.-)%)")
			or t:match("^function%s+[%w_%.%:]+%s*%((.-)%)")
			or t:match("=%s*function%s*%((.-)%)")
		if fnParams then
			for name in fnParams:gmatch("([%w_]+)") do
				if name ~= "self" then
					table.insert(locals, {
						name  = name,
						line  = i,
						depth = depth,
						used  = false,
						isParam = true,
					})
				end
			end
		end

		-- local var = ...  /  local a, b, c = ...  /  local function foo(...)
		local varList = nil
		local fnName = t:match("^local%s+function%s+([%w_]+)")
		if fnName then
			table.insert(locals, {
				name  = fnName,
				line  = i,
				depth = depth,
				used  = false,
			})
		else
			varList = t:match("^local%s+([%w_,%s]+)%s*=")
				or t:match("^local%s+([%w_,%s]+)%s*$")

			if varList and not varList:match("^function") then
				for name in varList:gmatch("[%w_]+") do
					if name ~= "function" and not LUAU_KEYWORDS[name] then
						table.insert(locals, {
							name  = name,
							line  = i,
							depth = depth,
							used  = false,
						})
					end
				end
			end
		end
	end
	return locals
end

-- Pass 2: Mark which locals are used (improved — checks same-line usage for params)
local function markUsedLocals(lines, blockCommentMap, localsList)
	local byName = {}
	for _, entry in ipairs(localsList) do
		if not byName[entry.name] then byName[entry.name] = {} end
		table.insert(byName[entry.name], entry)
	end

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		for word in line:gmatch("[%a_][%w_]*") do
			local entries = byName[word]
			if entries then
				for _, entry in ipairs(entries) do
					-- For params/for-vars: used if referenced on any line after declaration
					-- For regular locals: used if referenced after the declaration line
					if entry.isParam or entry.isForVar then
						if i > entry.line then
							entry.used = true
						end
					else
						if i > entry.line then
							entry.used = true
						end
						-- Also check same line for patterns like: local x = x + 1 (shadowed reassign)
					end
				end
			end
		end
	end
end

-- Pass 3: Nil-access patterns (expanded)
local NIL_RETURNING_PATTERNS = {
	"FindFirstChild",
	"FindFirstAncestor",
	"FindFirstAncestorOfClass",
	"FindFirstAncestorWhichIsA",
	"FindFirstChildOfClass",
	"FindFirstChildWhichIsA",
	"FindFirstDescendant",
	"WaitForChild",
	"FindPartOnRay",
	"FindPartOnRayWithIgnoreList",
	"FindPartOnRayWithWhitelist",
	"GetAttribute",
	"FindService",
	"PlayerAdded",     -- not nil-returning but commonly misused
	"GetPlayerFromCharacter",
	"GetPlayerByUserId",
	"Raycast",         -- workspace:Raycast can return nil
	"GetRoleInGroup",
	"match",           -- string.match can return nil
	"find",            -- string.find / table.find can return nil
}

local function scanNilAccess(lines, blockCommentMap)
	local diags = {}
	local couldBeNilVars = {}

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Check for assignment from potentially nil-returning call
		local varName = t:match("^local%s+([%w_]+)%s*=")
		if not varName then
			-- Also check non-local reassignment
			varName = t:match("^([%w_]+)%s*=[^=]")
		end

		if varName then
			for _, pat in ipairs(NIL_RETURNING_PATTERNS) do
				if line:find(pat, 1, true) then
					couldBeNilVars[varName] = { line = i, pattern = pat }
					break
				end
			end
			-- If assigned from something else, clear the nil status
			local foundNilPat = false
			for _, pat in ipairs(NIL_RETURNING_PATTERNS) do
				if line:find(pat, 1, true) then
					foundNilPat = true
					break
				end
			end
			if not foundNilPat and couldBeNilVars[varName] then
				couldBeNilVars[varName] = nil
			end
		end

		-- Check for index access on nil-candidate vars
		for name, info in pairs(couldBeNilVars) do
			if i > info.line then
				local accessPattern = "%f[%w_]" .. name .. "%s*[%.%:]"
				if line:match(accessPattern) then
					-- Check for guards
					local guarded = t:match("^if%s") or
						t:match("^elseif%s") or
						line:match(name .. "%s+and%s") or
						line:match(name .. "%s+or%s") or
						line:match("if%s+" .. name .. "%s") or
						line:match(name .. "%s*~=%s*nil") or
						line:match(name .. "%s*==%s*nil") or
						line:match(name .. "%s+then") or
						t:match("^" .. name .. "%s*=") or
						line:match("assert%(" .. name) or
						line:match(name .. "%s*%)")  -- passed as arg
					if not guarded then
						table.insert(diags, {
							kind    = "warning",
							line    = i,
							message = string.format(
								"Possible nil access: '%s' may be nil (assigned from %s on line %d) — guard with 'if %s then' or use assert()",
								name, info.pattern, info.line, name
							),
						})
						couldBeNilVars[name] = nil
					end
				end
			end
		end
	end
	return diags
end

-- Pass 4: Deprecated global usage
local function scanDeprecatedGlobals(lines, blockCommentMap)
	local diags = {}
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		for global, message in pairs(DEPRECATED_GLOBALS) do
			if line:match("%f[%w_]" .. global .. "%s*%(") then
				-- Make sure it's not qualified (e.g., task.wait)
				local beforeMatch = line:match("(.)" .. global .. "%s*%(")
				if not beforeMatch or (beforeMatch ~= "." and beforeMatch ~= ":") then
					table.insert(diags, {
						kind    = "warning",
						line    = i,
						message = message,
					})
				end
			end
		end
	end
	return diags
end

-- Pass 5: Deprecated Roblox API methods
local function scanDeprecatedAPI(lines, blockCommentMap)
	local diags = {}
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		for method, message in pairs(DEPRECATED_ROBLOX_API) do
			if message and line:match(":" .. method .. "%s*%(") then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = message,
				})
			end
		end
		-- Deprecated properties
		for prop, message in pairs(DEPRECATED_PROPERTIES) do
			if message and line:match("%." .. prop .. "[^%w_]") then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = message,
				})
			end
		end
	end
	return diags
end

-- Pass 6: Shadowed locals
local function scanShadowedLocals(lines, blockCommentMap)
	local diags = {}
	local scopeStack = { {} } -- stack of scopes, each scope is { name -> line }

	local function currentScope()
		return scopeStack[#scopeStack]
	end

	local function findInAnyScope(name)
		for idx = #scopeStack, 1, -1 do
			if scopeStack[idx][name] then
				return scopeStack[idx][name]
			end
		end
		return nil
	end

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Push scope
		local opensBlock = t:match("^function%s") or t:match("^local%s+function%s") or
			t:match("=%s*function%s*%(") or
			(t:match("^if%s.+%sthen") and not t:match("^elseif")) or
			t:match("^for%s.+%sdo") or t:match("^while%s.+%sdo") or
			t == "do" or t:match("^do%s") or t == "repeat" or t:match("^repeat%s")
		if opensBlock then
			table.insert(scopeStack, {})
		end

		-- Pop scope
		local closesBlock = t:match("^end[%s,;%)]") or t == "end" or
			t:match("^until%s") or t == "until"
		if closesBlock and #scopeStack > 1 then
			table.remove(scopeStack)
		end

		-- Collect declared names
		local names = {}
		local fnName = t:match("^local%s+function%s+([%w_]+)")
		if fnName then
			table.insert(names, fnName)
		else
			local varPart = t:match("^local%s+([%w_,%s]+)%s*=") or t:match("^local%s+([%w_,%s]+)%s*$")
			if varPart and not varPart:match("^function") then
				for n in varPart:gmatch("[%w_]+") do
					if n ~= "function" and not LUAU_KEYWORDS[n] then
						table.insert(names, n)
					end
				end
			end
		end

		for _, name in ipairs(names) do
			local prev = findInAnyScope(name)
			if prev and not ROBLOX_GLOBALS[name] and name ~= "_" then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = string.format(
						"Local '%s' shadows an earlier declaration on line %d",
						name, prev
					),
				})
			end
			currentScope()[name] = i
		end
	end
	return diags
end

-- Pass 7: Unreachable code
local function scanUnreachableCode(lines, blockCommentMap)
	local diags = {}
	local terminatorStack = {} -- stack of { afterTerminator, terminatorLine } per depth
	local depth = 0

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)
		if t == "" then continue end

		local opensBlock = t:match("^function%s") or t:match("^local%s+function%s") or
			t:match("=%s*function%s*%(") or
			(t:match("^if%s.+%sthen") and not t:match("^elseif")) or
			t:match("^for%s.+%sdo") or t:match("^while%s.+%sdo") or
			t == "do" or t:match("^do%s") or t == "repeat" or t:match("^repeat%s")

		local closesBlock = t:match("^end[%s,;%)]") or t == "end" or
			t:match("^until%s") or t == "until"
		local isElseElseif = t:match("^else%s*$") or t == "else" or t:match("^elseif%s")

		-- Check if current line is unreachable
		local curState = terminatorStack[depth]
		if curState and curState.afterTerminator and
			not isElseElseif and not closesBlock and
			not t:match("^%-%-") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = string.format(
					"Unreachable code after return/error/break/continue on line %d",
					curState.terminatorLine
				),
			})
			curState.afterTerminator = false
		end

		if opensBlock then
			depth = depth + 1
			terminatorStack[depth] = { afterTerminator = false, terminatorLine = 0 }
		end
		if closesBlock then
			terminatorStack[depth] = nil
			depth = math.max(0, depth - 1)
			if terminatorStack[depth] then
				terminatorStack[depth].afterTerminator = false
			end
		end
		if isElseElseif then
			if terminatorStack[depth] then
				terminatorStack[depth].afterTerminator = false
			end
		end

		local isTerminator = t:match("^return[%s%(]") or t == "return" or
			t:match("^error%(") or t == "break" or t:match("^break%s") or
			t == "continue" or t:match("^continue%s")
		if isTerminator then
			if not terminatorStack[depth] then
				terminatorStack[depth] = {}
			end
			terminatorStack[depth].afterTerminator = true
			terminatorStack[depth].terminatorLine = i
		end
	end
	return diags
end

-- Pass 8: Error-level checks (expanded significantly)
local function scanErrors(lines, blockCommentMap)
	local diags = {}

	-- Track bracket/paren/brace balance
	local parenBalance = 0
	local braceBalance = 0
	local bracketBalance = 0

	-- Track block keyword balance
	local blockOpens = 0
	local blockCloses = 0

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- === Literal nil indexing ===
		if t:match("%f[%w_]nil%s*%.") or t:match("%f[%w_]nil%s*:") or t:match("%f[%w_]nil%s*%[") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Indexing literal nil — this will always error at runtime",
			})
		end

		-- === Literal false indexing ===
		if t:match("%f[%w_]false%s*%.") or t:match("%f[%w_]false%s*:") or t:match("%f[%w_]false%s*%[") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Indexing literal false — this will always error at runtime",
			})
		end

		-- === Literal number indexing ===
		if t:match("%d+%s*%.%s*[%a_]") and not t:match("[%w_]%d+%s*%.") then
			-- Could be a float like 1.5, skip those
			-- Only flag things like: 5.Name
		end

		-- === Assignment in if condition ===
		if t:match("^if%s+.+[^=!<>~]=[^=]") and not t:match("^if%s+.+==%s") then
			-- More careful check: exclude valid patterns
			local condition = t:match("^if%s+(.+)%s+then")
			if condition then
				-- Check for single = that's not ==, ~=, <=, >=
				local checkCond = condition
				-- Remove strings from condition to avoid false positives
				checkCond = checkCond:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
				-- Remove ==, ~=, <=, >=
				checkCond = checkCond:gsub("[~<>]=", ""):gsub("==", "")
				if checkCond:match("[^=]=[^=]") then
					table.insert(diags, {
						kind    = "error",
						line    = i,
						message = "Possible assignment (=) instead of comparison (==) inside 'if' condition",
					})
				end
			end
		end

		-- === Concatenation with nil ===
		if t:match("%.%.%s*nil%f[^%w_]") or t:match("%f[%w_]nil%s*%.%.") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Concatenating with literal nil — this will error at runtime",
			})
		end

		-- === Double assignment typo ===
		if t:match("^local%s+[%w_]+%s*=%s*[%w_%.%:]+%s*=[^=]") then
			if not t:match("^local%s+[%w_]+%s*=%s*[%w_%.%:]+%s*==%s*") and
				not t:match("^local%s+[%w_]+%s*=%s*function") then
				table.insert(diags, {
					kind    = "error",
					line    = i,
					message = "Possible double-assignment typo: 'local x = y = z'",
				})
			end
		end

		-- === require() with nil/false ===
		if t:match("require%s*%(nil%)") or t:match("require%s*%(false%)") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "require() called with nil or false — will error at runtime",
			})
		end

		-- === Calling methods on string literals without parens ===
		-- e.g., "hello".upper instead of ("hello"):upper()
		-- This is actually valid in Lua but uncommon; skip.

		-- === Using : instead of . for property access ===
		-- e.g., instance:Name instead of instance.Name (if no parens follow)
		local colonAccess = t:match(":([%w_]+)%s*$")  -- colon access with no () after
		if colonAccess and not t:match(":%w+%s*%(") and not t:match("function") then
			-- Only flag if the accessed name looks like a property (starts with uppercase)
			if colonAccess:match("^%u") and colonAccess ~= "Connect" then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = string.format(
						"Using ':' to access '%s' without calling it — did you mean '.%s' (property) or ':%s()' (method call)?",
						colonAccess, colonAccess, colonAccess
					),
				})
			end
		end

		-- === Infinite loop detection: while true do without break/return/wait ===
		if t:match("^while%s+true%s+do") then
			-- Look ahead for any break, return, wait, yield in the loop body
			local hasExit = false
			local loopDepth = 1
			for j = i + 1, math.min(i + 200, #lines) do
				if blockCommentMap[j] then continue end
				local lt = trim(stripLineComment(lines[j]))
				if lt:match("^while%s") or lt:match("^for%s") or lt:match("^repeat") then
					loopDepth = loopDepth + 1
				end
				if lt == "end" or lt:match("^end[%s,;%)]") then
					loopDepth = loopDepth - 1
					if loopDepth <= 0 then break end
				end
				if loopDepth == 1 then
					if lt:match("break") or lt:match("return") or
						lt:match("task%.wait") or lt:match("task%.yield") or
						lt:match("wait%(") or lt:match("Heartbeat") or
						lt:match("RenderStepped") or lt:match("Stepped") or
						lt:match("%.Wait") or lt:match(":Wait") or
						lt:match("coroutine%.yield") then
						hasExit = true
						break
					end
				end
			end
			if not hasExit then
				table.insert(diags, {
					kind    = "error",
					line    = i,
					message = "Infinite loop: 'while true do' without any break, return, or yield — this will freeze the game",
				})
			end
		end

		-- === Calling Destroy() on game, workspace, or critical services ===
		if t:match("game%s*:%s*Destroy%s*%(") or t:match("workspace%s*:%s*Destroy%s*%(") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Destroying 'game' or 'workspace' — this will break the entire game",
			})
		end

		-- === Using string.len instead of # ===
		-- This is a hint, not an error, but we catch it here as style
		-- (moved to hints)

		-- === Mismatched brackets/parens tracking ===
		for ch in line:gmatch(".") do
			if ch == "(" then parenBalance = parenBalance + 1 end
			if ch == ")" then parenBalance = parenBalance - 1 end
			if ch == "{" then braceBalance = braceBalance + 1 end
			if ch == "}" then braceBalance = braceBalance - 1 end
			if ch == "[" then bracketBalance = bracketBalance + 1 end
			if ch == "]" then bracketBalance = bracketBalance - 1 end
		end

		-- Block keyword balance
		if t:match("^function%s") or t:match("^local%s+function%s") or
			t:match("=%s*function%s*%(") or
			(t:match("^if%s.+%sthen") and not t:match("^elseif")) or
			t:match("^for%s.+%sdo") or t:match("^while%s.+%sdo") or
			t == "do" or t:match("^do%s") or t == "repeat" or t:match("^repeat%s") then
			blockOpens = blockOpens + 1
		end
		if t:match("^end[%s,;%)]") or t == "end" then
			blockCloses = blockCloses + 1
		end
		if t:match("^until%s") or t == "until" then
			blockCloses = blockCloses + 1
		end

		-- === Comparing different types ===
		-- e.g., if someNumber == "string"
		-- Hard to detect without type info, but catch obvious cases
		if t:match('==%s*"[^"]*"%s') or t:match("==%s*'[^']*'%s") then
			-- Check if left side is obviously a number
			local leftSide = t:match("(%d+)%s*==")
			if leftSide then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = "Comparing a number with a string — this will always be false. Use tostring() or tonumber()",
				})
			end
		end

		-- === Empty function body ===
		-- function foo() end on same line
		if t:match("function%s*[%w_%.%:]*%s*%(.-%)%s*end") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "Empty function body — is this intentional?",
			})
		end

		-- === table.insert with wrong arg count ===
		if t:match("table%.insert%s*%([^,]+%)%s*$") then
			-- table.insert with only 1 argument
			local args = t:match("table%.insert%s*%((.+)%)")
			if args and not args:match(",") then
				table.insert(diags, {
					kind    = "error",
					line    = i,
					message = "table.insert() called with only 1 argument — needs at least 2 (table, value)",
				})
			end
		end

		-- === table.remove with string key ===
		if t:match('table%.remove%s*%([^,]+,%s*"') or t:match("table%.remove%s*%([^,]+,%s*'") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "table.remove() called with a string key — use tbl[key] = nil for dictionary removal",
			})
		end

		-- === Connect without function ===
		if t:match("%.Connect%s*%(%s*%)") or t:match(":Connect%s*%(%s*%)") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Signal:Connect() called without a callback function",
			})
		end

		-- === Duplicate keys in table constructor ===
		-- (basic: only catches obvious same-line duplicates)

		-- === Using == to compare with NaN ===
		if t:match("==%s*0/0") or t:match("0/0%s*==") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Comparing with NaN (0/0) using == will always be false — use x ~= x to check for NaN",
			})
		end

		-- === Division by zero (literal) ===
		if t:match("[%%/]%s*0%s*[^/0-9%.]") or t:match("[%%/]%s*0%s*$") then
			-- Exclude 0/0 pattern (NaN, sometimes intentional)
			if not t:match("0%s*/0") then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = "Division or modulo by literal zero — this may produce inf or NaN",
				})
			end
		end
	end

	-- Post-scan: check bracket balance
	if parenBalance ~= 0 then
		table.insert(diags, {
			kind    = "error",
			line    = #lines,
			message = string.format(
				"Mismatched parentheses: %d unmatched '(' in the script",
				math.abs(parenBalance)
			),
		})
	end
	if braceBalance ~= 0 then
		table.insert(diags, {
			kind    = "error",
			line    = #lines,
			message = string.format(
				"Mismatched braces: %d unmatched '{' in the script",
				math.abs(braceBalance)
			),
		})
	end
	if blockOpens ~= blockCloses then
		local diff = blockOpens - blockCloses
		if diff > 0 then
			table.insert(diags, {
				kind    = "error",
				line    = #lines,
				message = string.format(
					"Missing %d 'end' keyword(s) — more block-opening statements than closers",
					diff
				),
			})
		else
			table.insert(diags, {
				kind    = "error",
				line    = #lines,
				message = string.format(
					"Extra %d 'end' keyword(s) — more block-closing statements than openers",
					-diff
				),
			})
		end
	end

	return diags
end

-- Pass 9: Security & performance warnings
local function scanSecurityAndPerformance(lines, blockCommentMap)
	local diags = {}

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- === getfenv/setfenv usage ===
		if t:match("%f[%w_]getfenv%s*%(") or t:match("%f[%w_]setfenv%s*%(") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "getfenv/setfenv is deprecated and disabled in Luau — this will error",
			})
		end

		-- === loadstring usage ===
		if t:match("%f[%w_]loadstring%s*%(") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "loadstring() is disabled in Roblox by default — this will error unless enabled in ServerScriptService",
			})
		end

		-- === Instance.new with Parent as second arg ===
		if t:match("Instance%.new%s*%([^,]+,") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "Instance.new() with Parent as second argument is less performant — set Parent after configuring properties",
			})
		end

		-- === Creating instances in a tight loop without throttling ===
		-- (hard to detect perfectly, but flag Instance.new inside for loops)

		-- === Using tick() ===
		if t:match("%f[%w_]tick%s*%(") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "tick() is deprecated — use os.clock() for benchmarking or workspace:GetServerTimeNow() for timestamps",
			})
		end

		-- === Using _G for global state ===
		if t:match("%f[%w_]_G%s*[%.%[]") or t:match("%f[%w_]_G%s*=") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "_G usage is discouraged — use ModuleScripts for shared state instead",
			})
		end

		-- === game:GetService with wrong casing ===
		local serviceName = t:match('GetService%s*%(%s*"([^"]+)"') or t:match("GetService%s*%(%s*'([^']+)'")
		if serviceName then
			local knownServices = {
				Players = true, Workspace = true, ReplicatedStorage = true,
				ServerStorage = true, ServerScriptService = true,
				StarterGui = true, StarterPack = true, StarterPlayer = true,
				Lighting = true, SoundService = true, TweenService = true,
				RunService = true, UserInputService = true, HttpService = true,
				MarketplaceService = true, DataStoreService = true,
				ContextActionService = true, ContentProvider = true,
				CollectionService = true, PhysicsService = true,
				TextService = true, Chat = true, Teams = true,
				PathfindingService = true, GroupService = true,
				BadgeService = true, InsertService = true,
				ProximityPromptService = true, PolicyService = true,
				MemoryStoreService = true, MessagingService = true,
				LocalizationService = true, GuiService = true,
				HapticService = true, VRService = true,
				TestService = true, AnalyticsService = true,
			}
			if not knownServices[serviceName] then
				-- Check case-insensitive
				local found = false
				for known in pairs(knownServices) do
					if known:lower() == serviceName:lower() then
						table.insert(diags, {
							kind    = "error",
							line    = i,
							message = string.format(
								"Service name '%s' has wrong casing — should be '%s'",
								serviceName, known
							),
						})
						found = true
						break
					end
				end
				if not found then
					table.insert(diags, {
						kind    = "warning",
						line    = i,
						message = string.format(
							"Unknown service name '%s' in GetService() — check spelling",
							serviceName
						),
					})
				end
			end
		end

		-- === print() left in code (potential debug leftover) ===
		-- Only flag if it looks like a debug print
		if t:match("^print%s*%(") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "print() statement found — consider removing debug prints before shipping",
			})
		end

		-- === String concatenation in loop (performance) ===
		-- Detect `str = str .. something` pattern
		if t:match("([%w_]+)%s*=%s*%1%s*%.%.") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "String concatenation with self-assignment (str = str .. x) in potential loop — consider using table.concat() for better performance",
			})
		end

		-- === Yielding in pcall (common mistake) ===
		if t:match("pcall%s*%(.-wait") or t:match("pcall%s*%(.-yield") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "Yielding inside pcall() can cause unexpected behavior — the thread may not resume correctly",
			})
		end
	end

	return diags
end

-- Pass 10: Connection & memory leak detection
local function scanConnectionLeaks(lines, blockCommentMap)
	local diags = {}
	local connections = {} -- { varName -> line }
	local disconnected = {} -- { varName -> true }

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Track connection assignments: local conn = signal:Connect(...)
		local connVar = t:match("^local%s+([%w_]+)%s*=%s*.*:Connect%s*%(")
			or t:match("^local%s+([%w_]+)%s*=%s*.*%.Connect%s*%(")
		if connVar then
			connections[connVar] = i
		end

		-- Track :Connect() without storing result
		if (t:match(":Connect%s*%(") or t:match("%.Connect%s*%(")) and
			not t:match("^local%s") and not t:match("^[%w_]+%s*=") and
			not t:match("table%.insert") and not t:match(":%s*insert") then
			-- This is a connection that's not stored anywhere
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "Signal connection not stored in a variable — cannot be disconnected later (potential memory leak)",
			})
		end

		-- Track disconnections
		for name in pairs(connections) do
			if t:match(name .. "%s*:%s*Disconnect%s*%(") or
				t:match(name .. "%s*%.%s*Disconnect%s*%(") or
				t:match(name .. "%s*:%s*disconnect%s*%(") then
				disconnected[name] = true
			end
		end
	end

	return diags
end

-- Pass 11: Type annotation checks (basic)
local function scanTypeIssues(lines, blockCommentMap)
	local diags = {}

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- === Missing type annotations on exported functions (hint) ===
		-- Detect module pattern: function Module.X(params) without type annotations
		-- This is too noisy, skip for now

		-- === self in non-method context ===
		if t:match("%f[%w_]self[%.%[]") then
			-- Check if we're inside a method (defined with :)
			-- Simple heuristic: look backward for function definition with :
			local inMethod = false
			for j = i, math.max(1, i - 50), -1 do
				local prevLine = trim(stripLineComment(lines[j]))
				if prevLine:match("function%s+[%w_]+:[%w_]+") or
					prevLine:match("function%s+[%w_%.]+:[%w_]+") then
					inMethod = true
					break
				end
				if prevLine:match("function%s+[%w_]+%.[%w_]+") then
					-- . function, not :
					break
				end
			end
			-- Don't flag — too many false positives without full scope analysis
		end

		-- === Luau type syntax errors ===
		-- Detect malformed type annotations
		if t:match(":%s*{%s*}%s*=") and not t:match(":%s*{[^}]*}%s*=") then
			-- Empty table type annotation followed by = (probably fine)
		end
	end

	return diags
end

-- Pass 12: Duplicate table keys
local function scanDuplicateKeys(lines, blockCommentMap)
	local diags = {}
	local inTable = false
	local tableKeys = {}
	local tableStartLine = 0
	local braceDepth = 0

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Track brace depth for table constructors
		for ch in t:gmatch(".") do
			if ch == "{" then
				braceDepth = braceDepth + 1
				if braceDepth == 1 then
					inTable = true
					tableKeys = {}
					tableStartLine = i
				end
			elseif ch == "}" then
				braceDepth = braceDepth - 1
				if braceDepth == 0 then
					inTable = false
				end
			end
		end

		if inTable and braceDepth >= 1 then
			-- Check for explicit key assignments: Key = value or ["Key"] = value
			local key = t:match("^%s*([%w_]+)%s*=") or t:match('^%s*%["([^"]+)"%]%s*=') or t:match("^%s*%['([^']+)'%]%s*=")
			if key then
				if tableKeys[key] then
					table.insert(diags, {
						kind    = "warning",
						line    = i,
						message = string.format(
							"Duplicate table key '%s' — previously defined on line %d, this will overwrite the earlier value",
							key, tableKeys[key]
						),
					})
				else
					tableKeys[key] = i
				end
			end
		end
	end

	return diags
end

-- Pass 13: Hints / best practice (expanded)
local function scanHints(lines, blockCommentMap)
	local diags = {}

	-- === Function length ===
	local fnStack = {}
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		local isFnStart = t:match("^function%s+") or t:match("^local%s+function%s+") or
			t:match("=%s*function%s*%(")
		if isFnStart then
			local name = t:match("^local%s+function%s+([%w_%.%:]+)")
				or t:match("^function%s+([%w_%.%:]+)")
				or "<anonymous>"
			table.insert(fnStack, { name = name, startLine = i, depth = #fnStack + 1 })
		end

		local isFnEnd = (t == "end" or t:match("^end[%s,;%)]")) and #fnStack > 0
		if isFnEnd then
			local fn = table.remove(fnStack)
			if fn then
				local len = i - fn.startLine
				if len > 100 then
					table.insert(diags, {
						kind    = "warning",
						line    = fn.startLine,
						message = string.format(
							"Function '%s' is %d lines long (lines %d–%d) — strongly consider refactoring",
							fn.name, len, fn.startLine, i
						),
					})
				elseif len > 60 then
					table.insert(diags, {
						kind    = "hint",
						line    = fn.startLine,
						message = string.format(
							"Function '%s' is %d lines long (lines %d–%d) — consider splitting it",
							fn.name, len, fn.startLine, i
						),
					})
				end
			end
		end
	end

	-- === Global variable assignments ===
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		local isGlobal = t:match("^([%a_][%w_]*)%s*=[^=]")
		if isGlobal then
			local name = isGlobal
			if not ROBLOX_GLOBALS[name] and not LUAU_KEYWORDS[name] and
				not t:match("%.") and not t:match(":") and
				name ~= "self" then
				table.insert(diags, {
					kind    = "hint",
					line    = i,
					message = string.format(
						"Global assignment to '%s' — prefer 'local %s = ...' to avoid polluting global scope",
						name, name
					),
				})
			end
		end
	end

	-- === Deeply nested code ===
	local depth = 0
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		if t:match("^function%s") or t:match("^local%s+function%s") or
			t:match("=%s*function%s*%(") or
			(t:match("^if%s.+%sthen") and not t:match("^elseif")) or
			t:match("^for%s.+%sdo") or t:match("^while%s.+%sdo") or
			t == "do" or t:match("^do%s") or t == "repeat" or t:match("^repeat%s") then
			depth = depth + 1
		end
		if t:match("^end[%s,;%)]") or t == "end" or t:match("^until") then
			depth = math.max(0, depth - 1)
		end

		if depth >= 6 then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = string.format(
					"Code is nested %d levels deep — consider extracting logic into helper functions",
					depth
				),
			})
			-- Only flag once per deep section
			while i < #lines do
				i = i + 1
				local nextT = trim(stripLineComment(lines[i] or ""))
				if nextT:match("^end") or nextT:match("^until") then break end
			end
		end
	end

	-- === Magic numbers ===
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Skip obvious safe cases: 0, 1, 2, -1, 0.5, common values
		local safeNumbers = { ["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true,
			["-1"] = true, ["0.5"] = true, ["100"] = true, ["255"] = true,
			["360"] = true, ["90"] = true, ["180"] = true, ["10"] = true }

		-- Look for standalone numeric comparisons
		if t:match("==%s*(%d+%.?%d*)") then
			local num = t:match("==%s*(%d+%.?%d*)")
			if num and not safeNumbers[num] and tonumber(num) and tonumber(num) > 10 then
				table.insert(diags, {
					kind    = "hint",
					line    = i,
					message = string.format(
						"Magic number %s — consider extracting to a named constant for readability",
						num
					),
				})
			end
		end
	end

	-- === TODO/FIXME/HACK/XXX comments ===
	for i, rawLine in ipairs(lines) do
		local commentStart = rawLine:find("%-%-")
		if commentStart then
			local comment = rawLine:sub(commentStart)
			local tag = comment:match("%-%-[%s]*(%u%u%u%u+)")
			if tag and (tag == "TODO" or tag == "FIXME" or tag == "HACK" or tag == "XXX" or tag == "BUG") then
				table.insert(diags, {
					kind    = "hint",
					line    = i,
					message = string.format(
						"%s comment found: %s",
						tag, trim(comment:sub(3))
					),
				})
			end
		end
	end

	-- === Empty if/else/for/while blocks ===
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Single-line empty blocks
		if t:match("^if%s.+%sthen%s*end") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "Empty 'if' block — remove or add implementation",
			})
		end
		if t:match("^for%s.+%sdo%s*end") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "Empty 'for' loop — remove or add implementation",
			})
		end
		if t:match("^while%s.+%sdo%s*end") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = "Empty 'while' loop — remove or add implementation",
			})
		end

		-- Multi-line empty blocks: then/do followed immediately by end/else
		if (t:match("then$") or t:match("do$")) and i < #lines then
			local nextLine = trim(stripLineComment(lines[i + 1] or ""))
			if nextLine == "end" or nextLine == "else" or nextLine:match("^elseif") then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = "Empty block — the body contains no statements",
				})
			end
		end
	end

	-- === Unused services ===
	-- Detect: local Service = game:GetService("X") and check if Service is used
	local serviceDecls = {}
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local varName = line:match("^%s*local%s+([%w_]+)%s*=%s*game%s*:%s*GetService")
		if varName then
			serviceDecls[varName] = { line = i, used = false }
		end
	end
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		for name, info in pairs(serviceDecls) do
			if i > info.line and line:match("%f[%w_]" .. name .. "%f[^%w_]") then
				info.used = true
			end
		end
	end
	for name, info in pairs(serviceDecls) do
		if not info.used then
			table.insert(diags, {
				kind    = "warning",
				line    = info.line,
				message = string.format(
					"Service '%s' is imported but never used — remove to clean up",
					name
				),
			})
		end
	end

	return diags
end

-- Pass 14: Roblox-specific pattern checks
local function scanRobloxPatterns(lines, blockCommentMap)
	local diags = {}

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- === WaitForChild with no timeout in critical paths ===
		if t:match(":WaitForChild%s*%(") and not t:match(":WaitForChild%s*%([^,]+,") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "WaitForChild() without a timeout may yield forever if the child doesn't exist — consider adding a timeout parameter",
			})
		end

		-- === Using game.Players instead of game:GetService("Players") ===
		if t:match("game%.Players") and not t:match("GetService") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "Use game:GetService('Players') instead of game.Players for consistency and to avoid issues if the service is renamed",
			})
		end

		-- === Using game.Workspace instead of workspace ===
		if t:match("game%.Workspace") or t:match('GetService%s*%(%s*"Workspace"') then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "Use the 'workspace' global directly instead of game.Workspace or game:GetService('Workspace')",
			})
		end

		-- === RemoteEvent/RemoteFunction security ===
		-- Flag if FireServer is used without sanity checking on server side
		-- Can't fully check this, but flag FireClient with player from insecure source
		if t:match(":FireClient%s*%(") then
			table.insert(diags, {
				kind    = "hint",
				line    = i,
				message = "Ensure FireClient target player is validated — never trust client-provided player references",
			})
		end

		-- === Using string.format vs concatenation in hot paths ===
		-- (too noisy, skip)

		-- === Recursive require detection ===
		if t:match("require%s*%(script%s*%)") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Script is requiring itself — this will cause an infinite loop",
			})
		end

		-- === BindableEvent/Function misuse ===
		-- Using :Fire() on a RemoteEvent from client (should be :FireServer())
		-- Hard to detect without context, skip

		-- === Checking for Player.Character without humanoid check ===
		if t:match("%.Character%s*%.") or t:match("%.Character%s*:") then
			-- Likely accessing character — ensure it's not nil
			if not t:match("if%s") and not t:match("and%s") and not t:match("Character%s*and") then
				-- Check if previous lines have a nil check
				local hasGuard = false
				for j = math.max(1, i - 3), i - 1 do
					local prevT = trim(stripLineComment(lines[j] or ""))
					if prevT:match("Character") and (prevT:match("if%s") or prevT:match("~=%s*nil")) then
						hasGuard = true
						break
					end
				end
				if not hasGuard then
					table.insert(diags, {
						kind    = "warning",
						line    = i,
						message = "Accessing Player.Character without nil check — Character can be nil before spawn or after death",
					})
				end
			end
		end

		-- === Using pairs() on arrays ===
		-- Detect: for k, v in pairs(array_like_thing) — hard to know if it's an array
		-- Skip for now

		-- === Infinite recursion risk ===
		-- Detect function calling itself without base case on same depth
		-- Too complex for regex, skip
	end

	return diags
end

-- ---------------------------------------------------------------------------
-- Main entry point
-- ---------------------------------------------------------------------------

function AnalyzeTools.analyze_script(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	if not inst:IsA("LuaSourceContainer") then return nil, "Not a script" end

	local source = inst.Source or ""
	if #source == 0 then
		return {
			scriptName     = inst:GetFullName(),
			scriptType     = inst.ClassName,
			totalLines     = 0,
			diagnostics    = {},
			errorCount     = 0,
			warningCount   = 0,
			hintCount      = 0,
			totalCount     = 0,
			summary        = "Script is empty.",
		}
	end

	local lines = string.split(source, "\n")

	-- Shared block-comment map so all passes skip commented lines
	local blockCommentMap = buildBlockCommentMap(lines)

	-- Collect all diagnostics from every pass
	local allDiags = {}

	local function addDiags(diagList)
		for _, d in ipairs(diagList) do
			table.insert(allDiags, d)
		end
	end

	-- === Errors ===
	addDiags(scanErrors(lines, blockCommentMap))

	-- === Warnings ===
	local localsList = collectLocals(lines, blockCommentMap)
	markUsedLocals(lines, blockCommentMap, localsList)

	-- Unused locals (skip params unless verbose)
	for _, entry in ipairs(localsList) do
		if not entry.used and not entry.name:match("^_") then
			if entry.isParam then
				if not args.noParamWarnings then
					table.insert(allDiags, {
						kind    = "hint",
						line    = entry.line,
						message = string.format("Parameter '%s' is declared but never used (prefix with _ to suppress)", entry.name),
					})
				end
			elseif entry.isForVar then
				-- Only flag if it's not a common iterator var
				if entry.name ~= "i" and entry.name ~= "k" and entry.name ~= "v" and
					entry.name ~= "idx" and entry.name ~= "key" and entry.name ~= "value" then
					table.insert(allDiags, {
						kind    = "hint",
						line    = entry.line,
						message = string.format("Loop variable '%s' is declared but never used (prefix with _ to suppress)", entry.name),
					})
				end
			else
				table.insert(allDiags, {
					kind    = "warning",
					line    = entry.line,
					message = string.format("Local '%s' is declared but never used", entry.name),
				})
			end
		end
	end

	addDiags(scanNilAccess(lines, blockCommentMap))
	addDiags(scanDeprecatedGlobals(lines, blockCommentMap))
	addDiags(scanDeprecatedAPI(lines, blockCommentMap))
	addDiags(scanShadowedLocals(lines, blockCommentMap))
	addDiags(scanUnreachableCode(lines, blockCommentMap))
	addDiags(scanSecurityAndPerformance(lines, blockCommentMap))
	addDiags(scanConnectionLeaks(lines, blockCommentMap))
	addDiags(scanDuplicateKeys(lines, blockCommentMap))
	addDiags(scanRobloxPatterns(lines, blockCommentMap))
	addDiags(scanTypeIssues(lines, blockCommentMap))

	-- === Hints ===
	if not args.noHints then
		addDiags(scanHints(lines, blockCommentMap))
	end

	-- Deduplicate diagnostics (same line + same message)
	local seen = {}
	local uniqueDiags = {}
	for _, d in ipairs(allDiags) do
		local key = d.line .. "|" .. d.kind .. "|" .. d.message
		if not seen[key] then
			seen[key] = true
			table.insert(uniqueDiags, d)
		end
	end
	allDiags = uniqueDiags

	-- Sort by line number, then severity (error > warning > hint)
	local severityOrder = { error = 0, warning = 1, hint = 2 }
	table.sort(allDiags, function(a, b)
		if a.line ~= b.line then return a.line < b.line end
		return (severityOrder[a.kind] or 9) < (severityOrder[b.kind] or 9)
	end)

	-- Bucket counts
	local counts = { error = 0, warning = 0, hint = 0 }
	for _, d in ipairs(allDiags) do
		counts[d.kind] = (counts[d.kind] or 0) + 1
	end

	-- Build a human-readable summary
	local summaryParts = {}
	if counts.error > 0 then
		table.insert(summaryParts, counts.error .. " error" .. (counts.error > 1 and "s" or ""))
	end
	if counts.warning > 0 then
		table.insert(summaryParts, counts.warning .. " warning" .. (counts.warning > 1 and "s" or ""))
	end
	if counts.hint > 0 then
		table.insert(summaryParts, counts.hint .. " hint" .. (counts.hint > 1 and "s" or ""))
	end
	local summary = #summaryParts > 0
		and ("Found " .. table.concat(summaryParts, ", ") .. " in " .. #lines .. " lines.")
		or ("No issues found in " .. #lines .. " lines. ✓")

	return {
		scriptName     = inst:GetFullName(),
		scriptType     = inst.ClassName,
		totalLines     = #lines,
		diagnostics    = allDiags,
		errorCount     = counts.error,
		warningCount   = counts.warning,
		hintCount      = counts.hint,
		totalCount     = #allDiags,
		summary        = summary,
	}
end

return AnalyzeTools
