-- Tools/BuildTools.luau
-- Export and import instance hierarchies as JSON payloads

local HttpService = game:GetService("HttpService")

local Instances = require(script.Parent.Parent.Utils.Instances)
local PropertyTools = require(script.Parent.PropertyTools)
local Types = require(script.Parent.Parent.Utils.Types)
local History = require(script.Parent.Parent.Utils.History)

local BuildTools = {}

local function exportNode(inst)
	local propInfo = PropertyTools.get_all_properties({ id = Instances.registerInstance(inst) })
	local props = (type(propInfo) == "table" and propInfo.properties) or {}
	local children = {}
	for _, child in ipairs(inst:GetChildren()) do
		table.insert(children, exportNode(child))
	end
	return {
		className = inst.ClassName,
		name = inst.Name,
		properties = props,
		children = children,
	}
end

function BuildTools.export_build(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end

	local payload = exportNode(inst)
	return {
		json = HttpService:JSONEncode(payload),
		nodeCount = #inst:GetDescendants() + 1,
		root = inst:GetFullName(),
	}
end

local function importNode(spec, parent)
	if type(spec) ~= "table" then
		return nil, "Invalid node"
	end
	if not spec.className then
		return nil, "Missing className"
	end

	local okNew, inst = pcall(function()
		return Instance.new(spec.className)
	end)
	if not okNew or not inst then
		return nil, "Failed to create class: " .. tostring(spec.className)
	end

	inst.Name = spec.name or inst.Name
	for key, rawValue in pairs(spec.properties or {}) do
		if key ~= "Parent" and key ~= "Name" then
			pcall(function()
				inst[key] = Types.deserializeValue(rawValue)
			end)
		end
	end
	inst.Parent = parent

	local created = { inst }
	for _, childSpec in ipairs(spec.children or {}) do
		local child, err, childCreated = importNode(childSpec, inst)
		if not child then
			for _, made in ipairs(created) do
				pcall(function() made:Destroy() end)
			end
			return nil, err
		end
		for _, made in ipairs(childCreated) do
			table.insert(created, made)
		end
	end

	return inst, nil, created
end

function BuildTools.import_build(args)
	local parent = Instances.resolveInstance({ path = args.parentPath, pathArray = args.parentPathArray, id = args.parentId })
	if not parent then parent = workspace end

	local jsonPayload = args.json or args.buildJson
	if type(jsonPayload) ~= "string" or jsonPayload == "" then
		return nil, "Missing json"
	end

	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(jsonPayload)
	end)
	if not okDecode then
		return nil, "Invalid JSON payload"
	end

	local recording = History.recordUndo("MCP: Import build")
	local root, err = importNode(payload, parent)
	if not root then
		History.finishUndo(recording, false)
		return nil, err
	end
	History.finishUndo(recording, true)

	return {
		root = Instances.serializeInstance(root),
		createdCount = #root:GetDescendants() + 1,
	}
end

return BuildTools
