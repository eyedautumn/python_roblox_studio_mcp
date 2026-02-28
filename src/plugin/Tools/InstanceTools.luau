-- Tools/InstanceTools.luau
-- Tools for browsing, creating, and managing Instances

local CollectionService = game:GetService("CollectionService")
local Selection         = game:GetService("Selection")

local Instances = require(script.Parent.Parent.Utils.Instances)
local History   = require(script.Parent.Parent.Utils.History)
local Types     = require(script.Parent.Parent.Utils.Types)

local InstanceTools = {}

function InstanceTools.list_services()
	return Instances.serializeInstances(game:GetChildren())
end

function InstanceTools.get_children(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	return Instances.serializeInstances(inst:GetChildren())
end

function InstanceTools.get_descendants(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	return Instances.serializeInstances(inst:GetDescendants())
end

function InstanceTools.get_instance(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	return Instances.serializeInstance(inst)
end

function InstanceTools.find_instances(args)
	local ancestor
	if args.ancestorPathArray or args.ancestorPath then
		ancestor = Instances.resolveInstance({ path = args.ancestorPath, pathArray = args.ancestorPathArray })
	else
		ancestor = game
	end
	if not ancestor then return nil, "Ancestor not found" end

	local matches = {}
	for _, inst in ipairs(ancestor:GetDescendants()) do
		if args.name and inst.Name ~= args.name then continue end
		if args.className and inst.ClassName ~= args.className then continue end
		if args.tag and not CollectionService:HasTag(inst, args.tag) then continue end
		table.insert(matches, inst)
	end
	return Instances.serializeInstances(matches)
end

function InstanceTools.search_by_property(args)
	local propertyName = args.propertyName
	if not propertyName or propertyName == "" then
		return nil, "Missing propertyName"
	end

	local ancestor
	if args.ancestorPathArray or args.ancestorPath then
		ancestor = Instances.resolveInstance({ path = args.ancestorPath, pathArray = args.ancestorPathArray })
	else
		ancestor = game
	end
	if not ancestor then return nil, "Ancestor not found" end

	local targetValue = Types.deserializeValue(args.propertyValue)
	local matches = {}

	local function maybeInsert(inst)
		if args.className and inst.ClassName ~= args.className then return end
		local ok, value = pcall(function() return inst[propertyName] end)
		if not ok then return end
		if value == targetValue then
			table.insert(matches, inst)
		end
	end

	maybeInsert(ancestor)
	for _, inst in ipairs(ancestor:GetDescendants()) do
		maybeInsert(inst)
	end

	return Instances.serializeInstances(matches)
end

function InstanceTools.get_tree(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	local maxDepth    = args.maxDepth or 5
	local maxChildren = args.maxChildren or 50

	local function buildNode(obj, depth)
		local node = { name = obj.Name, className = obj.ClassName }
		if obj:IsA("LuaSourceContainer") then
			local src = obj.Source or ""
			node.scriptLineCount = select(2, src:gsub("\n", "")) + 1
		end
		local children = obj:GetChildren()
		if depth < maxDepth then
			if #children > 0 then
				node.children = {}
				local limit = math.min(#children, maxChildren)
				for i = 1, limit do
					table.insert(node.children, buildNode(children[i], depth + 1))
				end
				if #children > limit then node.truncatedChildren = #children - limit end
			end
		else
			if #children > 0 then node.childCount = #children end
		end
		return node
	end

	return buildNode(inst, 0)
end

function InstanceTools.create_instance(args)
	local className = args.className
	if not className then return nil, "Missing className" end
	local parent
	if args.parentPath or args.parentPathArray then
		parent = Instances.resolveInstance({ path = args.parentPath, pathArray = args.parentPathArray })
	else
		parent = workspace
	end
	if not parent then return nil, "Parent not found" end

	local Types = require(script.Parent.Parent.Utils.Types)
	local recording = History.recordUndo("MCP: Create " .. className)
	local inst = Instance.new(className)
	for key, value in pairs(args.properties or {}) do
		pcall(function() inst[key] = Types.deserializeValue(value) end)
	end
	inst.Parent = parent
	History.finishUndo(recording, true)
	return Instances.serializeInstance(inst)
end

function InstanceTools.delete_instance(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	local recording = History.recordUndo("MCP: Delete " .. inst.Name)
	inst:Destroy()
	History.finishUndo(recording, true)
	return { ok = true }
end

function InstanceTools.clone_instance(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end

	local recording = History.recordUndo("MCP: Clone " .. inst.Name)
	local clone = inst:Clone()
	if not clone then
		History.finishUndo(recording, false)
		return nil, "Clone failed (instance may be non-archivable)"
	end

	if args.newParentPath or args.newParentPathArray then
		local parent = Instances.resolveInstance({ path = args.newParentPath, pathArray = args.newParentPathArray })
		clone.Parent = parent or inst.Parent
	else
		clone.Parent = inst.Parent
	end

	if args.newName then clone.Name = args.newName end
	History.finishUndo(recording, true)
	return Instances.serializeInstance(clone)
end

function InstanceTools.smart_duplicate(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end

	local count = math.floor(tonumber(args.count) or 0)
	if count <= 0 then return nil, "count must be > 0" end
	if count > 200 then return nil, "count too large (max 200)" end

	local parent = inst.Parent
	if args.newParentPath or args.newParentPathArray then
		parent = Instances.resolveInstance({ path = args.newParentPath, pathArray = args.newParentPathArray })
	end
	if not parent then return nil, "New parent not found" end

	local offset = Types.deserializeValue(args.offset)
	if offset == nil then offset = Vector3.new(0, 0, 0) end
	if typeof(offset) ~= "Vector3" then
		return nil, "offset must be a Vector3 object"
	end

	local recording = History.recordUndo("MCP: Smart duplicate " .. inst.Name)
	local clones = {}

	for i = 1, count do
		local clone = inst:Clone()
		if not clone then
			History.finishUndo(recording, false)
			return nil, "Clone failed (instance may be non-archivable)"
		end

		clone.Parent = parent

		if offset.Magnitude > 0 and clone:IsA("PVInstance") then
			local step = offset * i
			pcall(function()
				clone:PivotTo(clone:GetPivot() + step)
			end)
		end

		table.insert(clones, clone)
	end

	History.finishUndo(recording, true)
	return Instances.serializeInstances(clones)
end

function InstanceTools.reparent_instance(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	local parent = Instances.resolveInstance({ path = args.newParentPath, pathArray = args.newParentPathArray })
	if not parent then return nil, "New parent not found" end
	local recording = History.recordUndo("MCP: Reparent " .. inst.Name)
	inst.Parent = parent
	History.finishUndo(recording, true)
	return { ok = true }
end

function InstanceTools.set_name(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	local recording = History.recordUndo("MCP: Rename " .. inst.Name .. " → " .. (args.name or ""))
	inst.Name = args.name or inst.Name
	History.finishUndo(recording, true)
	return { ok = true }
end

function InstanceTools.select_instance(args)
	local inst = Instances.resolveInstance(args)
	if not inst then return nil, "Instance not found" end
	Selection:Set({ inst })
	return { ok = true }
end

function InstanceTools.get_selection()
	return Instances.serializeInstances(Selection:Get())
end

return InstanceTools
