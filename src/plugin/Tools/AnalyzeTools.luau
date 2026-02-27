-- Tools/AnalyzeTools.luau
-- Static analysis for Luau scripts: detects errors, warnings, and hints.
-- Runs entirely in the plugin (no round-trip to the server for analysis).
--
-- Diagnostics are classified as:
--   error   – high-confidence defects (shadowed local overwriting itself,
--              accessing an index on a literal nil/false, deprecated globals, etc.)
--   warning – likely bugs that need human judgment (unused locals, possible nil
--             index, deprecated API, raw wait() usage, etc.)
--   hint    – style / best-practice nudges (missing local, long function, etc.)

local Instances = require(script.Parent.Parent.Utils.Instances)

local AnalyzeTools = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local DEPRECATED_GLOBALS = {
	wait     = "Use task.wait() instead of wait()",
	spawn    = "Use task.spawn() instead of spawn()",
	delay    = "Use task.delay() instead of delay()",
	["Delay"] = "Use task.delay() instead of Delay()",
	ypcall   = "Use pcall() instead of ypcall()",
}

-- Known Roblox globals (not exhaustive, but covers common ones so we don't
-- flag them as "undeclared").
local ROBLOX_GLOBALS = {
	game = true, workspace = true, script = true, plugin = true,
	Enum = true, Instance = true, Vector3 = true, Vector2 = true,
	CFrame = true, Color3 = true, BrickColor = true, UDim = true,
	UDim2 = true, Ray = true, Rect = true, Region3 = true,
	NumberSequence = true, NumberSequenceKeypoint = true,
	ColorSequence = true, ColorSequenceKeypoint = true,
	PhysicalProperties = true, Font = true, Axes = true, Faces = true,
	TweenInfo = true, RaycastParams = true, OverlapParams = true,
	PathfindingResult = true, SharedTable = true,
	-- Standard Lua
	print = true, warn = true, error = true, assert = true,
	pcall = true, xpcall = true, ipairs = true, pairs = true,
	next = true, select = true, unpack = true, rawget = true,
	rawset = true, rawequal = true, rawlen = true, setmetatable = true,
	getmetatable = true, type = true, typeof = true, tostring = true,
	tonumber = true, math = true, string = true, table = true,
	os = true, io = true, coroutine = true, utf8 = true,
	require = true, loadstring = true, dofile = true, load = true,
	collectgarbage = true, _G = true, _VERSION = true,
	-- task library
	task = true,
	-- Roblox additional
	tick = true, time = true, elapsedTime = true, version = true,
	gcinfo = true, delay = true, spawn = true, wait = true,
	settings = true, stats = true, UserSettings = true,
	newproxy = true, getstenv = true, getfenv = true, setfenv = true,
	SecurityCapabilities = true,
}

local function trim(s)
	return s:match("^%s*(.-)%s*$") or s
end

-- Strip a single-line comment suffix from a line (naive, ignores strings).
-- Returns the code portion only.
local function stripLineComment(line)
	-- Find "--" that is NOT inside a string literal.
	local inStr, strChar = false, nil
	local i = 1
	while i <= #line do
		local ch = line:sub(i, i)
		if inStr then
			if ch == "\\" then i = i + 1
			elseif ch == strChar then inStr, strChar = false, nil end
		else
			if ch == "'" or ch == '"' then
				inStr, strChar = true, ch
			elseif ch == "-" and line:sub(i, i + 1) == "--" then
				return line:sub(1, i - 1)
			end
		end
		i = i + 1
	end
	return line
end

-- Very lightweight string-block-comment tracker across lines.
-- Returns true if the given 1-indexed line is inside a --[[ ]] block.
local function buildBlockCommentMap(lines)
	local inBlock = {}
	local inside = false
	for i, line in ipairs(lines) do
		-- Check if block comment opens on this line (and hasn't closed)
		local codePart = line
		local j = 1
		while j <= #codePart do
			if not inside then
				if codePart:sub(j, j + 3) == "--[[" then
					inside = true
					j = j + 4
				elseif codePart:sub(j, j) == "-" and codePart:sub(j, j + 1) == "--" then
					-- single-line comment, rest of line is comment
					break
				else
					j = j + 1
				end
			else
				if codePart:sub(j, j + 1) == "]]" then
					inside = false
					j = j + 2
				else
					j = j + 1
				end
			end
		end
		inBlock[i] = inside
	end
	return inBlock
end

-- ---------------------------------------------------------------------------
-- Analysis passes
-- ---------------------------------------------------------------------------

-- Pass 1: Collect all local variable declarations with their scope depth.
-- Returns array of { name, line, col, used=false, depth }.
local function collectLocals(lines, blockCommentMap)
	local locals = {}
	local depth = 0

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Track block depth (very rough)
		if t:match("^function%s") or t:match("^local%s+function%s") or
			t:match("=%s*function%s*%(") or t:match("^if%s.+%sthen%s*$") or
			t:match("^for%s.+%sdo%s*$") or t:match("^while%s.+%sdo%s*$") or
			t:match("^do%s*$") or t:match("^repeat%s*$") then
			depth = depth + 1
		end
		if t == "end" or t:match("^end%s*%-%-") or t == "end," or t == "end)" or t == "end;" or t:match("^end$") then
			depth = math.max(0, depth - 1)
		end
		if t:match("^until%s") then
			depth = math.max(0, depth - 1)
		end

		-- local var = ...
		-- local a, b, c = ...
		-- local function foo(...)
		local varList = t:match("^local%s+function%s+([%w_]+)")
			or t:match("^local%s+([%w_,%s]+)%s*=")
			or t:match("^local%s+([%w_,%s]+)%s*$")

		if varList and not varList:match("^function") then
			for name in varList:gmatch("[%w_]+") do
				if name ~= "function" then
					table.insert(locals, {
						name  = name,
						line  = i,
						depth = depth,
						used  = false,
					})
				end
			end
		elseif t:match("^local%s+function%s+([%w_]+)") then
			local name = t:match("^local%s+function%s+([%w_]+)")
			table.insert(locals, {
				name  = name,
				line  = i,
				depth = depth,
				used  = false,
			})
		end
	end
	return locals
end

-- Pass 2: Mark which locals are used.
local function markUsedLocals(lines, blockCommentMap, localsList)
	-- Build a fast lookup of { [name] = list of local entries }
	local byName = {}
	for _, entry in ipairs(localsList) do
		if not byName[entry.name] then byName[entry.name] = {} end
		table.insert(byName[entry.name], entry)
	end

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		-- Walk every identifier token
		for word in line:gmatch("[%a_][%w_]*") do
			local entries = byName[word]
			if entries then
				for _, entry in ipairs(entries) do
					if i > entry.line then
						entry.used = true
					end
				end
			end
		end
	end
end

-- Pass 3: Scan for nil-index patterns.
-- Patterns we look for:
--   local x = something_that_may_return_nil
--   x.Field  or  x:Method()  on the very next reference
-- Simple heuristic: flag `variable.Something` when `variable` was assigned
-- from a call whose name ends in Find*, Get*, FindFirstChild, etc.
local NIL_RETURNING_PATTERNS = {
	"FindFirstChild",
	"FindFirstAncestor",
	"FindFirstAncestorOfClass",
	"FindFirstAncestorWhichIsA",
	"FindFirstChildOfClass",
	"FindFirstChildWhichIsA",
	"FindFirstDescendant",
	"WaitForChild",   -- can return nil on timeout
	"FindPartOnRay",
	"FindPartOnRayWithIgnoreList",
	"FindPartOnRayWithWhitelist",
	":FindFirstChild",
}

local function scanNilAccess(lines, blockCommentMap)
	local diags = {}
	-- Track: varName -> {line, couldBeNil}
	local couldBeNilVars = {}

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Check for assignment from potentially nil-returning call
		-- local varName = expr:FindFirstChild(...)
		local varName = t:match("^local%s+([%w_]+)%s*=")
		if varName then
			for _, pat in ipairs(NIL_RETURNING_PATTERNS) do
				if line:find(pat, 1, true) then
					couldBeNilVars[varName] = { line = i, pattern = pat }
					break
				end
			end
		end

		-- Check for index access on a var we know could be nil
		for name, info in pairs(couldBeNilVars) do
			if i > info.line then
				-- Pattern: name.Something or name:Something but NOT `if name` or `name == nil`
				local accessPattern = name .. "%s*[%.%:]"
				if line:match(accessPattern) then
					local guardedByIf = t:match("^if%s+" .. name) or
						t:match("and%s+" .. name) or
						t:match("or%s+" .. name) or
						line:match("if%s+" .. name) or
						line:match(name .. "%s*~=%s*nil") or
						line:match(name .. "%s*==%s*nil") or
						t:match("^" .. name .. "%s*=")  -- reassignment, not access
					if not guardedByIf then
						table.insert(diags, {
							kind    = "warning",
							line    = i,
							message = string.format(
								"Possible nil access: '%s' may be nil (assigned from %s on line %d) — guard with 'if %s then'",
								name, info.pattern, info.line, name
							),
						})
						-- Only report once per var to avoid spam
						couldBeNilVars[name] = nil
					end
				end
				-- If the variable is reassigned, reset its nil status
				if t:match("^" .. name .. "%s*=") or t:match("^local%s+" .. name .. "%s*=") then
					couldBeNilVars[name] = nil
				end
			end
		end
	end
	return diags
end

-- Pass 4: Deprecated global usage.
local function scanDeprecatedGlobals(lines, blockCommentMap)
	local diags = {}
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		for global, message in pairs(DEPRECATED_GLOBALS) do
			-- Match global used as a call: wait( spawn( etc.
			if line:match("%f[%w_]" .. global .. "%s*%(") then
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

-- Pass 5: Shadowed locals (a local declared with the same name as an outer local).
local function scanShadowedLocals(lines, blockCommentMap)
	local diags = {}
	local seen = {} -- name -> first declaration line

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		local names = {}
		local fnName = t:match("^local%s+function%s+([%w_]+)")
		if fnName then
			table.insert(names, fnName)
		else
			local varPart = t:match("^local%s+([%w_,%s]+)%s*=") or t:match("^local%s+([%w_,%s]+)%s*$")
			if varPart and not varPart:match("^function") then
				for n in varPart:gmatch("[%w_]+") do
					if n ~= "function" then table.insert(names, n) end
				end
			end
		end

		for _, name in ipairs(names) do
			if seen[name] and not ROBLOX_GLOBALS[name] then
				table.insert(diags, {
					kind    = "warning",
					line    = i,
					message = string.format(
						"Local '%s' shadows an outer declaration on line %d",
						name, seen[name]
					),
				})
			end
			seen[name] = i
		end

		-- Reset scope on end (crude: only outer level)
		if t == "end" or t:match("^end%-%-") then
			-- We can't properly track scope here without a full parser,
			-- so we leave seen intact to avoid false negatives.
		end
	end
	return diags
end

-- Pass 6: Unreachable code after return/error/break at the same block level.
local function scanUnreachableCode(lines, blockCommentMap)
	local diags = {}
	local afterTerminator = false
	local terminatorLine = 0
	local depth = 0

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Track depth
		local opensBlock = t:match("^function%s") or t:match("^local%s+function%s") or
			t:match("=%s*function%s*%(") or (t:match("^if%s.+%sthen%s*$") and not t:match("^elseif")) or
			t:match("^for%s.+%sdo%s*$") or t:match("^while%s.+%sdo%s*$") or
			t:match("^do%s*$") or t:match("^repeat%s*$")

		local closesBlock = t == "end" or t:match("^end%s") or t == "until" or t:match("^until%s")
		local isElseElseif = t:match("^else%s*$") or t:match("^else%-%-") or t:match("^elseif%s")

		if afterTerminator and depth == terminatorLine and
			not isElseElseif and not closesBlock and
			t ~= "" and not t:match("^%-%-") then
			table.insert(diags, {
				kind    = "warning",
				line    = i,
				message = string.format(
					"Unreachable code: this line follows a return/error/break on line %d",
					terminatorLine
				),
			})
			afterTerminator = false
		end

		if opensBlock then depth = depth + 1 end
		if closesBlock then
			depth = math.max(0, depth - 1)
			afterTerminator = false
		end
		if isElseElseif then
			afterTerminator = false
		end

		local isTerminator = t:match("^return%s") or t == "return" or
			t:match("^error%(") or t == "break" or t:match("^break%s*%-%-")
		if isTerminator then
			afterTerminator = true
			terminatorLine = depth
		end
	end
	return diags
end

-- Pass 7: Error-level checks.
local function scanErrors(lines, blockCommentMap)
	local diags = {}

	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Indexing literal nil: nil.Something
		if t:match("nil%s*%.") or t:match("nil%s*:") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Indexing literal nil — this will always error at runtime",
			})
		end

		-- Indexing literal false: false.Something
		if t:match("%Wfalse%s*%.") or t:match("%Wfalse%s*:") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Indexing literal false — this will always error at runtime",
			})
		end

		-- Comparing with ~= or == against a function call without parens
		-- e.g.  if x == math.huge  (ok)  vs  common mistake: if x = y (assignment in if)
		-- Detect: if <expr> = <expr> (missing second =)
		if t:match("^if%s+.+[^=!<>~]=[^=].+%sthen") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Possible assignment (=) instead of comparison (==) inside 'if' condition",
			})
		end

		-- String concatenation with number directly without tostring
		-- e.g.  "foo" .. 123 is fine in Lua; flag "foo" .. nil
		if t:match('".+"[%s]*%.%.[%s]*nil') or t:match("'.+'[%s]*%.%.[%s]*nil") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "Concatenating a string with literal nil — this will error at runtime",
			})
		end

		-- Double assignment: local x = x = something (common typo)
		if t:match("^local%s+[%w_]+%s*=%s*[%w_]+%s*=%s*") then
			-- Allow patterns like: local x = x == y
			if not t:match("^local%s+[%w_]+%s*=%s*[%w_]+%s*==%s*") then
				table.insert(diags, {
					kind    = "error",
					line    = i,
					message = "Possible double-assignment typo: 'local x = y = z' — did you mean 'local x = y'?",
				})
			end
		end

		-- Calling a non-function: literal .. ()
		-- e.g.  (123)()  or  ("string")()
		if t:match("%d+%s*%(") and not t:match("[%w_]%s*%(") and not t:match("function") then
			-- Very rough: skip if there's an identifier just before
		end

		-- require() with a non-string argument (common mistake in large scripts)
		if t:match("require%(nil%)") or t:match("require%(false%)") then
			table.insert(diags, {
				kind    = "error",
				line    = i,
				message = "require() called with nil or false — will error at runtime",
			})
		end
	end

	return diags
end

-- Pass 8: Hints / best practice
local function scanHints(lines, blockCommentMap)
	local diags = {}

	-- Detect functions longer than 80 lines
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

		local isFnEnd = (t == "end" or t:match("^end%s")) and #fnStack > 0
		if isFnEnd then
			local fn = table.remove(fnStack)
			if fn then
				local len = i - fn.startLine
				if len > 80 then
					table.insert(diags, {
						kind    = "hint",
						line    = fn.startLine,
						message = string.format(
							"Function '%s' is %d lines long (starts line %d, ends line %d) — consider splitting it",
							fn.name, len, fn.startLine, i
						),
					})
				end
			end
		end
	end

	-- Detect `wait()` calls without task.
	-- Already covered by deprecated globals pass, but add a hint for bare wait(n)
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		if line:match("%f[%w_]wait%s*%(") and not line:match("task%.wait") then
			-- already covered as warning; skip duplicate hint
		end
	end

	-- Detect global variable assignments (not prefixed with local)
	for i, rawLine in ipairs(lines) do
		if blockCommentMap[i] then continue end
		local line = stripLineComment(rawLine)
		local t = trim(line)

		-- Skip: starts with local, starts with self/module., inside function args, etc.
		local isGlobal = t:match("^([%a_][%w_]*)%s*=[^=]")
		if isGlobal then
			local name = isGlobal
			-- Skip known globals, keywords, and names with dots/colons
			if not ROBLOX_GLOBALS[name] and not t:match("%.") and
				name ~= "function" and name ~= "if" and name ~= "while" and
				name ~= "for" and name ~= "return" and name ~= "break" then
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
	local lines  = string.split(source, "\n")

	-- Shared block-comment map so all passes skip commented lines
	local blockCommentMap = buildBlockCommentMap(lines)

	-- Collect all diagnostics from every pass
	local allDiags = {}

	-- Errors
	for _, d in ipairs(scanErrors(lines, blockCommentMap)) do
		table.insert(allDiags, d)
	end

	-- Warnings
	local localsList = collectLocals(lines, blockCommentMap)
	markUsedLocals(lines, blockCommentMap, localsList)

	-- Unused locals
	for _, entry in ipairs(localsList) do
		-- Skip _ prefix (intentionally unused convention)
		if not entry.used and not entry.name:match("^_") then
			table.insert(allDiags, {
				kind    = "warning",
				line    = entry.line,
				message = string.format("Local '%s' is declared but never used", entry.name),
			})
		end
	end

	for _, d in ipairs(scanNilAccess(lines, blockCommentMap)) do
		table.insert(allDiags, d)
	end
	for _, d in ipairs(scanDeprecatedGlobals(lines, blockCommentMap)) do
		table.insert(allDiags, d)
	end
	for _, d in ipairs(scanShadowedLocals(lines, blockCommentMap)) do
		table.insert(allDiags, d)
	end
	for _, d in ipairs(scanUnreachableCode(lines, blockCommentMap)) do
		table.insert(allDiags, d)
	end

	-- Hints
	if not args.noHints then
		for _, d in ipairs(scanHints(lines, blockCommentMap)) do
			table.insert(allDiags, d)
		end
	end

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

	return {
		scriptName     = inst:GetFullName(),
		totalLines     = #lines,
		diagnostics    = allDiags,
		errorCount     = counts.error,
		warningCount   = counts.warning,
		hintCount      = counts.hint,
		totalCount     = #allDiags,
	}
end

return AnalyzeTools
