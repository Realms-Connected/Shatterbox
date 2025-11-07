--#selene: allow(multiple_statements)

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local TaggingService = {}

local InstanceAttributes = {} :: { [Instance] : { [string] : any } }

local InstanceTags = {} :: { [Instance] : {string} }

local TaggedInstances = {} :: { [string] : {Instance} }

local GameTagListeners = {} :: { [string] : {Added : RBXScriptConnection, Removed : RBXScriptConnection} }


local function AddTag(i : Instance, tag : string)
	local found = InstanceTags[i]
	if found then table.insert(found, tag) else
		InstanceTags[i] = {tag}
		i.Destroying:Once(function() InstanceTags[i] = nil end)
	end

	found = TaggedInstances[tag]
	if found then table.insert(found, i) else
		TaggedInstances[tag] = {i}
	end
end

local function RemoveTag(i : Instance, tag : string)
	local found = InstanceTags[i]
	if found then
		local index = table.find(found, tag)
		if index then table.remove(found, index) end
	end

	found = TaggedInstances[tag]
	if found then
		local index = table.find(found, i)
		if index then table.remove(found, index) end
	end
end

-- auto-populate tags from CollectionService for compatibility
local function PopulateTagListeners()
	for _, tag in ipairs(CollectionService:GetAllTags()) do
		if GameTagListeners[tag] then continue end

		GameTagListeners[tag] = {
			Added = CollectionService:GetInstanceAddedSignal(tag):Connect(function(i : Instance) AddTag(i, tag) end),
			Removed = CollectionService:GetInstanceRemovedSignal(tag):Connect(function(i : Instance) RemoveTag(i, tag) end)
		}

		for _, i in ipairs(CollectionService:GetTagged(tag)) do AddTag(i, tag) end
	end
end

PopulateTagListeners()

RunService.Heartbeat:Connect(PopulateTagListeners)

-- Deep cloning of tables
local function DeepishCopy(x : any)
	local t = typeof(x)
	if t == "table" then
		local ret = {}
		for k, v in pairs(x) do ret[k] = DeepishCopy(v) end
		return ret
	else return x end
end


-- TAGGING FUNCTIONALITY

TaggingService.AddTag = AddTag
TaggingService.RemoveTag = RemoveTag

-- returns the array of all instances with a given tag
function TaggingService.GetTagged(tag : string) return ( TaggedInstances[tag] or {} ) :: {Instance} end

-- returns the array of tags a given instance has
function TaggingService.GetTags(i : Instance) return ( InstanceTags[i] or {} ) :: {string} end

-- returns the index of the tag in the instances tag array if it exists
function TaggingService.HasTag(i : Instance, tag : string) : number?
	local found = InstanceTags[i]
	return found and table.find(found, tag)
end

function TaggingService.ClearTags(i : Instance)
	InstanceTags[i] = nil
	for _, instances in pairs(TaggedInstances) do
		local found = table.find(instances, i)
		if found then table.remove(instances, found) end
	end
end

function TaggingService.CloneTags(from : Instance, to : Instance)
	local fromTags = InstanceTags[from]
	if fromTags then
		local toTags = InstanceTags[to]
		if toTags then
			for _, tag in ipairs(fromTags) do
				if table.find(toTags, tag) then continue end
				table.insert(toTags, tag)
			end
		else
			InstanceTags[to] = DeepishCopy(fromTags)
		end
	end
end

function TaggingService.FindFirstAncestorWithTag(i : Instance, tag : string) : Instance?
	local Ancestor = i.Parent

	while Ancestor and not TaggingService.HasTag(Ancestor, tag) do Ancestor = Ancestor.Parent end

	return Ancestor
end



-- ATTRIBUTE FUNCTIONALITY

function TaggingService.SetAttribute(i : Instance, att : string, val : any?)
	local found = InstanceAttributes[i]
	if found then
		found[att] = val
		if next(found) then return end
		InstanceAttributes[i] = nil
	elseif val then
		InstanceAttributes[i] = { [att] = val }
		i.Destroying:Once(function() InstanceAttributes[i] = nil end)
	end
end

function TaggingService.SetAttributes(i : Instance, attributes : { [string] : any })
	local found = InstanceAttributes[i]
	if found then
		for att, val in pairs(attributes) do found[att] = val end
	else
		InstanceAttributes[i] = attributes
		i.Destroying:Once(function() InstanceAttributes[i] = nil end)
	end
end

function TaggingService.GetAttribute(i : Instance, att : string) : any?
	local found = InstanceAttributes[i]
	return found and found[att]
end

function TaggingService.GetAttributes(i : Instance) return ( InstanceAttributes[i] or {} ) :: { [string] : any } end

function TaggingService.ClearAttributes(i : Instance) InstanceAttributes[i] = nil end

function TaggingService.CloneAttributes(from : Instance, to : Instance)
	local fromAtts = InstanceAttributes[from]
	if fromAtts then
		local toAtts = InstanceAttributes[to]
		if toAtts then
			for att, val in pairs(fromAtts) do toAtts[att] = DeepishCopy(val) end
		else
			InstanceAttributes[to] = DeepishCopy(fromAtts)
		end
	end
end


return TaggingService