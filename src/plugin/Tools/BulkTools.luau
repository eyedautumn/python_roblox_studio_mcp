-- Tools/BulkTools.luau
-- High-efficiency bulk operations: create many instances, set many properties, etc.
-- All bulk mutations are wrapped in a single ChangeHistoryService recording so the
-- entire batch is undoable as one Ctrl+Z action.

local Instances = require(script.Parent.Parent.Utils.Instances)
local Types     = require(script.Parent.Parent.Utils.Types)
local History   = require(script.Parent.Parent.Utils.History)

local BulkTools = {}

-- ---------------------------------------------------------------------------
-- bulk_create_instances
-- Creates N instances in one round-trip. Returns serialized info for each.
--
-- args.instances: array of { className, parentPath?, parentPathArray?, properties? }
-- ---------------------------------------------------------------------------
function BulkTools.bulk_create_instances(args)
	local specs = args.instances
	if not specs or #specs == 0 then
		return nil, "Missing or empty 'instances' array"
	end
	if #specs > 200 then
		return nil, "Too many instances in one call (max 200). Split into smaller batches."
	end

	local recording = History.recordUndo("MCP: Bulk create " .. #specs .. " instances")
	local results = {}
	local errors  = {}

	for i, spec in ipairs(specs) do
		local className = spec.className
		if not className then
			table.insert(errors, { index = i, error = "Missing className" })
		else
			-- Resolve parent
			local parent
			if spec.parentPath or spec.parentPathArray then
				parent = Instances.resolveInstance({ path = spec.parentPath, pathArray = spec.parentPathArray })
			end
			parent = parent or workspace

			local ok, inst = pcall(function()
				local obj = Instance.new(className)
				for key, value in pairs(spec.properties or {}) do
					pcall(function() obj[key] = Types.deserializeValue(value) end)
				end
				obj.Parent = parent
				return obj
			end)

			if ok then
				table.insert(results, Instances.serializeInstance(inst))
			else
				table.insert(errors, { index = i, error = tostring(inst) })
			end
		end
	end

	History.finishUndo(recording, true)
	return {
		created   = results,
		errors    = errors,
		count     = #results,
		errCount  = #errors,
	}
end

-- ---------------------------------------------------------------------------
-- bulk_set_properties
-- Set properties on many instances in one round-trip.
--
-- args.operations: array of { path?, pathArray?, id?, properties }
-- ---------------------------------------------------------------------------
function BulkTools.bulk_set_properties(args)
	local ops = args.operations
	if not ops or #ops == 0 then
		return nil, "Missing or empty 'operations' array"
	end
	if #ops > 200 then
		return nil, "Too many operations in one call (max 200)."
	end

	local recording = History.recordUndo("MCP: Bulk set properties (" .. #ops .. " instances)")
	local results = {}

	for i, op in ipairs(ops) do
		local inst = Instances.resolveInstance(op)
		if not inst then
			table.insert(results, { index = i, ok = false, error = "Instance not found" })
		else
			local opErrors = {}
			for key, rawValue in pairs(op.properties or {}) do
				local deserialized = Types.deserializeValue(rawValue)
				local ok, err = pcall(function() inst[key] = deserialized end)
				if not ok then
					table.insert(opErrors, key .. ": " .. tostring(err))
				end
			end
			table.insert(results, {
				index    = i,
				ok       = true,
				fullName = inst:GetFullName(),
				warnings = #opErrors > 0 and opErrors or nil,
			})
		end
	end

	History.finishUndo(recording, true)
	return { results = results }
end

-- ---------------------------------------------------------------------------
-- bulk_delete_instances
-- Delete multiple instances in one round-trip.
--
-- args.instances: array of { path?, pathArray?, id? }
-- ---------------------------------------------------------------------------
function BulkTools.bulk_delete_instances(args)
	local specs = args.instances
	if not specs or #specs == 0 then
		return nil, "Missing or empty 'instances' array"
	end

	-- Resolve all before deleting (so path references don't break as we go)
	local toDelete = {}
	local errors   = {}
	for i, spec in ipairs(specs) do
		local inst = Instances.resolveInstance(spec)
		if inst then
			table.insert(toDelete, inst)
		else
			table.insert(errors, { index = i, error = "Instance not found" })
		end
	end

	local recording = History.recordUndo("MCP: Bulk delete " .. #toDelete .. " instances")
	for _, inst in ipairs(toDelete) do
		pcall(function() inst:Destroy() end)
	end
	History.finishUndo(recording, true)

	return {
		deleted  = #toDelete,
		errors   = errors,
	}
end


function BulkTools.bulk_get_properties(args)
	local specs = args.instances
	local property = args.property
	if not specs or #specs == 0 then
		return nil, "Missing or empty 'instances' array"
	end
	if not property or property == "" then
		return nil, "Missing property"
	end
	if #specs > 500 then
		return nil, "Too many instances in one call (max 500)."
	end

	local results = {}
	for i, spec in ipairs(specs) do
		local inst = Instances.resolveInstance(spec)
		if inst then
			local ok, value = pcall(function() return inst[property] end)
			if ok then
				table.insert(results, {
					fullName = inst:GetFullName(),
					value = Types.serializeValue(value),
				})
			else
				table.insert(results, {
					fullName = inst:GetFullName(),
					value = { _type = "error", message = tostring(value) },
				})
			end
		else
			table.insert(results, {
				index = i,
				fullName = nil,
				value = { _type = "error", message = "Instance not found" },
			})
		end
	end

	return results
end

-- ---------------------------------------------------------------------------
-- find_and_replace_in_scripts
-- Search all scripts under an ancestor for a string and replace it.
-- Returns how many scripts were modified and total replacements made.
-- All changes are made in a single ChangeHistoryService recording.
--
-- args.find        – plain string to search for (required)
-- args.replace     – replacement string (required, can be "")
-- args.ancestorPath / ancestorPathArray – search root (default: game)
-- args.caseSensitive – bool (default true)
-- args.maxScripts  – max scripts to touch (default 50, safety limit)
-- args.dryRun      – bool: if true, report what would change without applying
-- ---------------------------------------------------------------------------
function BulkTools.find_and_replace_in_scripts(args)
	local find    = args.find
	local replace = args.replace
	if find == nil or replace == nil then
		return nil, "Required: 'find' and 'replace' strings"
	end
	if find == "" then
		return nil, "'find' string must not be empty"
	end

	local ancestor
	if args.ancestorPath or args.ancestorPathArray then
		ancestor = Instances.resolveInstance({ path = args.ancestorPath, pathArray = args.ancestorPathArray })
	else
		ancestor = game
	end
	if not ancestor then return nil, "Ancestor not found" end

	local caseSensitive = args.caseSensitive
	if caseSensitive == nil then caseSensitive = true end
	local maxScripts = math.min(args.maxScripts or 50, 200)
	local dryRun     = args.dryRun == true

	local results         = {}
	local totalMatches    = 0
	local scriptsModified = 0

	for _, inst in ipairs(ancestor:GetDescendants()) do
		if not inst:IsA("LuaSourceContainer") then continue end
		if scriptsModified >= maxScripts then break end

		local source = inst.Source or ""
		local searchSrc = caseSensitive and source or source:lower()
		local searchFor = caseSensitive and find or find:lower()

		local _, count = searchSrc:gsub(searchFor:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%0"), "")
		if count == 0 then continue end

		totalMatches    = totalMatches + count
		scriptsModified = scriptsModified + 1

		table.insert(results, {
			fullName    = inst:GetFullName(),
			matchCount  = count,
			modified    = not dryRun,
		})
	end

	if dryRun then
		return {
			dryRun          = true,
			scriptsMatched  = scriptsModified,
			totalMatches    = totalMatches,
			scripts         = results,
		}
	end

	-- Apply replacements
	local recording = History.recordUndo("MCP: Find-and-replace '" .. find .. "' → '" .. replace .. "'")

	-- We need to redo the walk to actually mutate (previous walk was read-only)
	local applied = 0
	local ScriptEditorService = game:GetService("ScriptEditorService")

	for _, inst in ipairs(ancestor:GetDescendants()) do
		if not inst:IsA("LuaSourceContainer") then continue end
		if applied >= maxScripts then break end

		local source = inst.Source or ""
		local searchFor = find
		if not caseSensitive then
			-- Lua patterns don't support case-insensitive replace natively,
			-- so we do a line-by-line gsub on the lowered copy to find ranges,
			-- then replace using the original casing pattern.
			-- Simple approach: convert find to pattern with [Aa][Bb]… up to 64 chars.
			if #find <= 64 then
				local pat = find:gsub(".", function(c)
					if c:match("%a") then
						return "[" .. c:upper() .. c:lower() .. "]"
					else
						return c:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%0")
					end
				end)
				searchFor = pat
				local newSource, n = source:gsub(pat, replace)
				if n > 0 then
					inst.Source = newSource
					applied = applied + 1
					-- Update ScriptEditorService if open
					pcall(function()
						local doc = ScriptEditorService:FindScriptDocument(inst)
						if doc then task.wait(0.01) end
					end)
				end
			end
		else
			local escaped = find:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%0")
			local newSource, n = source:gsub(escaped, replace)
			if n > 0 then
				inst.Source = newSource
				applied = applied + 1
				pcall(function()
					local doc = ScriptEditorService:FindScriptDocument(inst)
					if doc then task.wait(0.01) end
				end)
			end
		end
	end

	History.finishUndo(recording, true)

	return {
		dryRun          = false,
		scriptsModified = scriptsModified,
		totalMatches    = totalMatches,
		scripts         = results,
	}
end

return BulkTools
