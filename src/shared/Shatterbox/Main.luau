--!native
--!optimize 2


-- Shatterbox release 8


--#selene: allow(multiple_statements)
--#selene: allow(unused_variable)
--#selene: allow(incorrect_standard_library_use)
--#selene: allow(shadowing)

local IndestructibleTag = "Indestructible"
local FallingGroupTag = "FallingGroup"

local DebrisTag = "ShatterboxDebris"
local DirtyGroupIDAttribute = "DirtyGroupID"
local FallingGroupIDAttribute = "FallingGroupID"


local src = script.Parent
local lib = src:WaitForChild("lib")
-- Shatterbox uses Blink for Client-Server communications
local PathToClient = lib:WaitForChild("Client")
local PathToServer = lib:WaitForChild("Server")

--[[ IF YOU ALSO USE BLINK:

	These steps ensure events are properly batched using Blink, saving performance.
	I don't think anything bad happens if you don't set up batching using these steps.

	1. Import the "Shatterbox.blink" file to your Blink config:		import "PATH_TO_SHATTERBOX/Shatterbox.blink"

	2. Rebuild your blink files

	3. Re-define PathToServer and PathToClient local variables defined above to the location of your blink files
]]

--[[ ROBLOX STUDIO BLINK USERS:

	You can run this in the command line to populate/update the Shatterbox blink file, then you can continue above from Step 1 (use  import "Shatterbox" ):

	local HS = game:GetService("HttpService");
	local O = HS.HttpEnabled;
	HS.HttpEnabled = true;
	local S = HS:GetAsync("https://raw.githubusercontent.com/azavier-a/Shatterbox/refs/heads/main/src/shared/Shatterbox/Shatterbox.blink");
	HS.HttpEnabled = O;
	local SS = game:GetService("ServerStorage");
	local F = SS:FindFirstChild("BLINK_CONFIGURATION_FILES");
	if not F then
		F = Instance.new("Folder");
		F.Name = "BLINK_CONFIGURATION_FILES";
		F.Parent = SS;
	end
	local SV = F:FindFirstChild("Shatterbox");
	if not SV then
		SV = Instance.new("StringValue");
		SV.Name = "Shatterbox";
		SV.Parent = F;
	end
	SV.Value = S;
]]

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local isServer, isClient = RunService:IsServer(), RunService:IsClient()

local Settings = require(src:WaitForChild("Settings"))


local function FindHumanoidAsAncestorChild(i : Instance)
	while i do
		local hum = i:FindFirstChildWhichIsA("Humanoid")
		if hum then return hum end
		i = i.Parent
	end
	return nil
end
-- Returns true if an instance should NOT be considered for voxel destruction
local function ShouldSkipInstance(i : Instance)
	-- skip anything that passed the SkipInstanceCheck
	if Settings.SkipInstanceCheck(i) then return true end
	-- skip anything that isnt a block part
	if isClient and (not i:IsA("Part") or i.Shape ~= Enum.PartType.Block) then return true end
	-- skip anything with the "Indestructible" tag
	if i:HasTag(IndestructibleTag) then return true end
	-- skip anything which has a Humanoid child, or if any of its ancestors have a Humanoid child.
	if FindHumanoidAsAncestorChild(i) then return true end

	return false
end


--!!!! If you modify any code below here, you are at serious risk of breaking the module. It probably already has a way to do what you need to do. !!!!--


local Types = require(src:WaitForChild("Types"))

local USE_CLIENT_SERVER = Settings.USE_CLIENT_SERVER

local IMAGINARY, NORMAL = "IMAGINARY", "NORMAL"
type DestructionTypes = ("IMAGINARY"|"NORMAL")

local EPSILON = 1e-3

--- @class Shatterbox
local Shatterbox = {}

local OnVoxelDestructRegistry = setmetatable({}, {
	__index = function(tbl, k) return (k and rawget(tbl, k:lower())) end -- or rawget(tbl, "default") end
}) :: { [string] : Types.OnVoxelDestruct }

local StepReplication, ClientEvents, ServerEvents, mapContainer
if isServer then
	ServerEvents = require(PathToServer)
	StepReplication = ServerEvents.StepReplication

	mapContainer = workspace.CurrentCamera

	local serverEffects = require(src.effects.Server)
	serverEffects:SetReference(Shatterbox)
	serverEffects.SetReference = nil
	for name, func in pairs(serverEffects) do OnVoxelDestructRegistry[name:lower()] = func end
elseif isClient then
	ClientEvents = require(PathToClient)
	StepReplication = ClientEvents.StepReplication

	mapContainer = workspace:FindFirstChild("ClientMap")
	if not mapContainer then
		mapContainer = Instance.new("Folder")
		mapContainer.Parent = workspace
		mapContainer.Name = "ClientMap"
	end

	local clientEffects = require(src:WaitForChild("effects"):WaitForChild("Client"))
	clientEffects:SetReference(Shatterbox)
	clientEffects.SetReference = nil
	for name, func in pairs(clientEffects) do OnVoxelDestructRegistry[name:lower()] = func end
end

local ObjectCache, CachedParts
--[[
if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then

	local TemplatePart = Instance.new("Part")
	TemplatePart.Anchored = true

	ObjectCache = require(lib:WaitForChild("ObjectCache"))

	local cacheContainer = mapContainer

	CachedParts = ObjectCache.new(TemplatePart, CACHE_INITIAL_SIZE, cacheContainer)
end
--]]

-- Shorthands for commonly used functions
local VertexMath = require(lib:WaitForChild("VertexMath"))
local PartEncapsulatesBlockPart = VertexMath.PartEncapsulatesBlockPart
local GetVerts, GetNormals = VertexMath.GetVerts, VertexMath.GetNormals
local BlockVerts, BlockNormals = GetVerts.Block, GetNormals.Block
local PartContainsAVert, PartContainsAllVerts = VertexMath.PartContainsAVert, VertexMath.PartContainsAllVerts

local PartOperations = require(lib:WaitForChild("PartOperations"))
local PartFromTemplate = PartOperations.PartFromTemplate
local DeserializedPartInstance = PartOperations.DeserializedPartInstance
local SerializedPartInstance = PartOperations.SerializedPartInstance
local GridInfo = PartOperations.GridInfo
local ImaginaryVoxelize = PartOperations.ImaginaryVoxelize
local Voxelize = PartOperations.Voxelize

local SubdivideFunctions = {
	KD = PartOperations.SubdivideKD,
	MOT = PartOperations.SubdivideOctree
}


--[[ Contains information about each dirty group, indexed with DirtyGroupID:
	 * OriginalPart is the original part before any destruction took place. This part is never destroyed, just has its parent set to `nil`
	 * OriginalParent is the original parent of the OriginalPart before any destruction took place. This is used in the client-server algorithm
	 * GridSize is the GridSize attribute of the OriginalPart if it has one supplied
]]
local DirtyGroupData = {} :: {
	[string] : {
		OriginalPart : Part,
		OriginalParent : Instance,
		GridSize : number
	}
}
-- Contains dynamic maps of dirty group members indexed with DirtyGroupID
local DirtyGroupMembers = {} :: { [string] : { [Part] : boolean } }

-- Smooth cleanup map [DirtyGroupID] : secondsUntilCleanup
local SmoothCleanupQueue = {} :: { [string] : number }

local ImaginaryCreateQueue = {} :: { Types.ImaginaryBox }
local ImaginaryDestroyQueue = {} :: { [Part] : boolean }

-- Ongoing operations array
local ShatterQueue = {} :: { Types.DestructionParams }
-- Falling groups being processed by an ongoing operation [DestructionID] : { [FallingGroupID] : boolean }
local ChangedFallingGroups = {} :: { [string] : boolean }

-- Dirty groups waiting to be greedy meshed [DirtyGroupID] : GridSize
local GreedyMeshingQueue = {} :: { [string] : number }
local GreedyMeshedImaginaryParts = {} :: { Types.ImaginaryBox }

local NewPlayerStateReplicationQueue = {} :: {Player}

-- Elements of the Puppets array are of the form {Part, boolean} where the Part is the puppet master/slave (server side master, client side slave) and the boolean is whether or not that puppet is getting interpolated.
local Puppets = {} :: { {} }
local ClientPuppetStepDelta = 1 -- How many replication steps the client thinks it will take for a single puppet to recieve its next update.
-- Stores the interpolation start/end for the corresponding element of the Puppets array. On the server side this is the state replication queue
local PuppetsLerpData = {} :: { {CFrame} }
-- Index that increments every time a puppet is created if the Puppets array is full, and loops back to 1 when the maximum puppet count is reached.
-- When this happens, the oldest puppets are destroyed as new ones spawn in
local PuppetNextIndex = 1
local PuppetNextReplicationIndex = 1

local CreatePuppetQueue = {}

-- Falling groups [FallingGroupID] : { [DirtyGroupID] : boolean }
local FallingGroupMembers = {} :: { [string] : { [string] : boolean } }
local FallingGroupSectionAnchors = {} :: { [string] : { Part }}

-- Pre-allocated OverlapParams used when FilterTagged is supplied
local overlapParams = OverlapParams.new()

-- Pre-allocated RaycastParams when SkipWalls or SkipFloors is enabled
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include

-- pre-allocated part instance which is used to get the parts whenever `GetPartsInPart` is needed
local IntersectingPart = Instance.new("Part")

local puppetTimeAccumulation = 0
local frameDivs = 0

local clientInitComplete = false -- flag used to pause replicating events until the server has replicated it's state


local ci, cd = 0, 0

local textUVMap = {
	[0] = Vector3.new( 0,  1,  1),
	[1] = Vector3.new( 1,  0,  1),
	[2] = Vector3.new(-1,  1,  0),
	[3] = Vector3.new( 0,  1, -1),
	[4] = Vector3.new(-1,  0,  1),
	[5] = Vector3.new( 1,  1,  0)
}

local axisUVMap = {
	[0] = { "Z", "Y" },
	[1] = { "X", "Z" },
	[2] = { "X", "Y" },
	[3] = { "Z", "Y" },
	[4] = { "X", "Z" },
	[5] = { "X", "Y" }
}

--Instantiates a new member of a dirty group using the group ID and a given CFrame and Size
local function InstantiatePart(DirtyGroupID, cframe, size)
	--debug.profilebegin("InstantiatePart")
	local dirtyGroupData, dirtyGroupMembers = DirtyGroupData[DirtyGroupID], DirtyGroupMembers[DirtyGroupID]

	local part = PartFromTemplate(dirtyGroupData.OriginalPart, cframe, CachedParts)
	part.Size = size

	local partIsDivisible = part:IsA("Part") and part.Shape == Enum.PartType.Block

	if not USE_CLIENT_SERVER or not partIsDivisible then
		part.Parent = dirtyGroupData.OriginalParent
	else
		part.Parent = mapContainer
	end

	if partIsDivisible and part:FindFirstChildWhichIsA("Texture") then
		local OriginalPart = dirtyGroupData.OriginalPart
		local HalfSizeOriginal = OriginalPart.Size * 0.5
		local HalfSizePart = part.Size * 0.5

		for _, texture in ipairs(part:GetChildren()) do
			if not texture:IsA("Texture") then continue end
			local Face = texture.Face.Value
			local TowardOrigin = textUVMap[Face]

			local GroupOrigin = OriginalPart.CFrame + OriginalPart.CFrame:VectorToWorldSpace(TowardOrigin * HalfSizeOriginal)
			local partOrigin = part.CFrame + part.CFrame:VectorToWorldSpace(TowardOrigin * HalfSizePart)

			local Offset = partOrigin:VectorToObjectSpace(GroupOrigin.Position - partOrigin.Position):Abs()

			texture.OffsetStudsU += Offset[axisUVMap[Face][1]]
			texture.OffsetStudsV += Offset[axisUVMap[Face][2]]
		end
	end

	dirtyGroupMembers[part] = true

	--debug.profileend()
	ci += 1
	return part
end
--Destroys a member of a dirty group using the part itself
local function DestroyPart(part)
	--debug.profilebegin("DestroyPart")
	local DirtyGroupID = part:GetAttribute(DirtyGroupIDAttribute)
	if not DirtyGroupID then return end

	local dirtyGroupData, dirtyGroupMembers = DirtyGroupData[DirtyGroupID], DirtyGroupMembers[DirtyGroupID]

	if part == dirtyGroupData.OriginalPart then
		part.Parent = nil
	else
		dirtyGroupMembers[part] = nil
		part:Destroy()
	end

	cd += 1
	--debug.profileend()
end

local HalfVector = Vector3.one * 0.5
local MAXU32 = 0xFFFFFFFF
local function InitGreedyState(part, GridSize, groupMin, State, DIMYSTATEDIMZ, STATEDIMZ)

	local minCFrame, _, S, _, _, _, NVX, NVY, NVZ = GridInfo(part.CFrame, part.Size, GridSize)

	if not minCFrame.Rotation:FuzzyEq(groupMin.Rotation, EPSILON) then return nil end

	local Offset = groupMin:PointToObjectSpace(minCFrame.Position) / S
	local RoundedOffset = (Offset + HalfVector):Floor()

	if not Offset:FuzzyEq(RoundedOffset, EPSILON) then return nil end

	local DX, DY, DZ = RoundedOffset.X, RoundedOffset.Y, RoundedOffset.Z

	local ZBitOffset = DZ % 32
	local ZLayerOffset = DZ // 32

	local InitialWriteWidth = math.min(32 - ZBitOffset, NVZ)
	local CountLeftAfterInitial = NVZ - InitialWriteWidth

	local FullLayerSpanCount = CountLeftAfterInitial // 32
	local FinalWriteWidth = CountLeftAfterInitial % 32

	-- Initialize the 3d state volume.   index = (X - 1)*DIMY*STATE_DIMZ + (Y - 1)*STATE_DIMZ + STATE_Z
	for X = 1, NVX do
		local dixz = (X + DX - 1)*DIMYSTATEDIMZ
		for Y = 1, NVY do
			local di = dixz + (Y + DY - 1)*STATEDIMZ + ZLayerOffset + 1

			if InitialWriteWidth > 0 then State[di] = bit32.bor(State[di], bit32.lshift(bit32.lshift(1, InitialWriteWidth) - 1, ZBitOffset)) end

			for i = 1, FullLayerSpanCount do State[di + i] = MAXU32 end

			if FinalWriteWidth > 0 then State[di + FullLayerSpanCount + 1] = bit32.bor(State[di + FullLayerSpanCount + 1], bit32.lshift(1, FinalWriteWidth) - 1) end
		end
	end

	return NVX * NVY * NVZ
end

local function GreedyMeshBehavior(DirtyGroupID : string, ImaginaryParts : { Types.ImaginaryBox })
	local GridSize = GreedyMeshingQueue[DirtyGroupID]

	local dirtyGroupData = DirtyGroupData[DirtyGroupID]
	local dirtyGroupMembers = DirtyGroupMembers[DirtyGroupID]

	local Original = dirtyGroupData.OriginalPart

	-- The bounding area of Greedy Meshing, defined by the original part before it was ever destroyed
	local groupMin, _, VoxelSize, _, _, _, DIMX, DIMY, DIMZ = GridInfo(Original.CFrame, Original.Size, GridSize)
	local STATEDIMZ = math.ceil(DIMZ / 32)
	local DIMYSTATEDIMZ = DIMY*STATEDIMZ
	local VSX, VSY, VSZ = VoxelSize.X, VoxelSize.Y, VoxelSize.Z

	-- local stateBitCount = DIMX*DIMYDIMZ

	-- flat 3d state array : index = (X - 1)*DIMY*STATE_DIMZ + (Y - 1)*STATE_DIMZ + STATE_Z
	local State = table.create(DIMX*DIMYSTATEDIMZ, 0)

	-- information about the original parts, used for smoothly displaying the output of greedy meshing
	local OriginalParts = {} :: { Part }

	-- the total number of voxels in the State array
	local count = 0

	for member in pairs(dirtyGroupMembers) do
		if member:HasTag(DebrisTag) then continue end

		table.insert(OriginalParts, member)

		if ImaginaryDestroyQueue[member] then continue end

		local n = InitGreedyState(member, GridSize, groupMin, State, DIMYSTATEDIMZ, STATEDIMZ)
		if n then
			count += n
			ImaginaryDestroyQueue[member] = true
		end
	end

	for _, imaginaryMember in ipairs(ImaginaryParts) do
		local n = InitGreedyState(imaginaryMember, GridSize, groupMin, State, DIMYSTATEDIMZ, STATEDIMZ)
		if n then count += n end
	end

	if count == 0 then return end

	local meshed = {}

	local searchIndex = 1
	local StateSize = #State

	while count > 0 do
		while searchIndex <= StateSize and State[searchIndex] == 0 do
			searchIndex += 1
		end
		if searchIndex > StateSize then break end

		local state = State[searchIndex]

		local startBit = bit32.countrz(state)
		local shifted = bit32.rshift(state, startBit)

		local run = bit32.countrz(bit32.bnot(shifted))
		if run > (32 - startBit) then run = 32 - startBit end

		local firstMask = bit32.lshift(bit32.lshift(1, run) - 1, startBit)

		local StartX, rem = ((searchIndex - 1) // DIMYSTATEDIMZ) + 1, (searchIndex - 1) % DIMYSTATEDIMZ
		local StartY, StartLayerZ = (rem // STATEDIMZ) + 1, (rem % STATEDIMZ) + 1
		local StartZ = 32*(StartLayerZ - 1) + startBit + 1

		local EndLayerZ = StartLayerZ
		local EndBit = startBit + run - 1
		local layerIndex = searchIndex
		local lastMask

		while EndBit == 31 and EndLayerZ < STATEDIMZ do
			local nextIndex = layerIndex + 1
			local nextLayer = State[nextIndex]
			if not nextLayer or nextLayer == 0 then break end

			if nextLayer == MAXU32 then
				layerIndex = nextIndex
				EndLayerZ += 1
				EndBit = 31
				run += 32
			else
				local r = bit32.countrz(bit32.bnot(nextLayer))
				if r == 0 then break end

				layerIndex = nextIndex
				EndLayerZ += 1
				EndBit = r - 1
				run += r
				lastMask = bit32.lshift(1, r) - 1
				break
			end
		end

		local EndLayerOffset = EndLayerZ - StartLayerZ

		local masks = {}
		for layer = 0, EndLayerOffset do
			if layer == 0 then
				masks[layer] = firstMask
			elseif layer == EndLayerOffset then
				masks[layer] = lastMask or MAXU32
			else
				masks[layer] = MAXU32
			end
		end

		local EndY = StartY
		while EndY < DIMY do
			local nextY = EndY + 1
			local valid = true
			for layer = 0, EndLayerOffset do
				local idx = (StartX - 1)*DIMYSTATEDIMZ + (nextY - 1)*STATEDIMZ + StartLayerZ + layer
				local mask = State[idx]
				local req = masks[layer]
				if not mask or bit32.band(mask, req) ~= req then
					valid = false
					break
				end
			end
			if not valid then break end
			EndY += 1
		end

		local EndX = StartX
		while EndX < DIMX do
			local nextX = EndX + 1
			local valid = true
			for Y = StartY, EndY do
				for layer = 0, EndLayerOffset do
					local idx = (nextX - 1)*DIMYSTATEDIMZ + (Y - 1)*STATEDIMZ + StartLayerZ + layer
					local mask = State[idx]
					local req = masks[layer]
					if not mask or bit32.band(mask, req) ~= req then
						valid = false
						break
					end
				end
				if not valid then break end
			end
			if not valid then break end
			EndX += 1
		end

		for X = StartX, EndX do
			for Y = StartY, EndY do
				local I = (X - 1)*DIMYSTATEDIMZ + (Y - 1)*STATEDIMZ + StartLayerZ
				local EndLayerIndex = I + EndLayerOffset

				State[I] = bit32.band(State[I], bit32.bnot(firstMask))
				for i = 1, EndLayerOffset - 1 do State[I + i] = 0 end
				if lastMask then
					State[EndLayerIndex] = bit32.band(State[EndLayerIndex], bit32.bnot(lastMask))
				elseif EndLayerOffset > 0 then
					State[EndLayerIndex] = 0
				end
			end
		end

		local EndZ = 32*(EndLayerZ - 1) + EndBit + 1

		local NX = EndX - StartX + 1
		local NY = EndY - StartY + 1
		local NZ = EndZ - StartZ + 1

		count -= NX * NY * NZ

		table.insert(meshed, {
			DirtyGroupID = DirtyGroupID,
			CFrame = groupMin + groupMin.XVector * VSX * ((StartX + EndX)*0.5 - 1) + groupMin.YVector * VSY * ((StartY + EndY)*0.5 - 1) + groupMin.ZVector * VSZ * ((StartZ + EndZ)*0.5 - 1),
			Size = VoxelSize * Vector3.new(NX, NY, NZ)
		})
	end

	for _, meshedInfo in ipairs(meshed) do
		local index, found = nil, nil
		for i, original in ipairs(OriginalParts) do
			if original.CFrame:FuzzyEq(meshedInfo.CFrame, 0.001) and original.Size:FuzzyEq(meshedInfo.Size, 0.001) then
				index, found = i, original
				break
			end
		end
		if index then
			table.remove(OriginalParts, index)
			ImaginaryDestroyQueue[found] = nil
		else
			table.insert(GreedyMeshedImaginaryParts, meshedInfo)
		end
	end
end


-- Returns the first occurance of an ancestor that is a Folder or a Model
local function FindFirstAncestorGroup(i : Instance) : (Folder|Model)?
	local Ancestor = i.Parent

	while Ancestor and not (Ancestor:IsA("Folder") or Ancestor:IsA("Model")) do Ancestor = Ancestor.Parent end

	return Ancestor
end

-- Returns all of the tags of every ancestor group instance (folder/model) as an array
local function AncestorGroupTags(i : Instance) : {string}
	local tags = {}

	local Ancestor = FindFirstAncestorGroup(i)
	while Ancestor do
		local t = Ancestor:GetTags()

		local found = table.find(t, FallingGroupTag)
		if found then table.remove(t, found) end

		if #t > 0 then
			table.move(t, 1, #t, #tags + 1, tags)
		end
		Ancestor = FindFirstAncestorGroup(Ancestor)
	end

	return tags
end

-- Finds the first occurance of an ancestor group instance (folder/model) with a given tag
local function FindFirstAncestorGroupWithTag(i : Instance, tag : string) : Instance?
	local Ancestor = FindFirstAncestorGroup(i)

	while Ancestor and not Ancestor:HasTag(tag) do Ancestor = FindFirstAncestorGroup(Ancestor) end

	return Ancestor
end

-- returns OverlapParams including all instances with the given tags.
local function OverlapParamsOfTagged(tags : { string }) : OverlapParams
	local arr

	if #tags == 1 then
		arr = CollectionService:GetTagged(tags[1])
	else
		arr = {}
		for _, tag in ipairs(tags) do
			local taggedArray = CollectionService:GetTagged(tag)
			table.move(taggedArray, 1, #taggedArray, #arr + 1, arr)
		end
	end

	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = arr

	return overlapParams
end


local function SerializedCuttingPart(p)
	return {
		CFrame = p.CFrame,
		Size = p.Size,
		Shape = p.Shape.Value
	}
end


-- What happens when a model is passed in as the `CuttingPart`
local function ModelQueueBehavior(funcToUse, params)
	local cuttingPart = params.CuttingPart or params
	local retA, retB = {}, {}
	if cuttingPart and typeof(cuttingPart) == "Instance" and cuttingPart:IsA("Model") then
		for _, desc in ipairs(cuttingPart:GetDescendants()) do
			if not desc:IsA("Part") then continue end
			params.CuttingPart = desc
			local rA, rB = funcToUse(desc, params)
			if rA then
				table.move(rA, 1, #rA, #retA + 1, retA)
			end
			if rB then
				table.move(rB, 1, #rB, #retB + 1, retB)
			end
		end
		return true, retA, retB
	end
	return false, retA, retB
end


local function GetCondensedGUID()
	return string.gsub(HttpService:GenerateGUID(false), '-', '')
end


--[=[
	@class DestructionParameters

	A table that specifies information needed for destruction to happen, as well as all of the optional per-destruction parameters.

	:::warning
	If you do not supply `params.CuttingPart` then you must assign `params.CFrame`, `params.Size`, and `params.Shape` (and vice-versa).
	:::
]=]
local DestructionParamsMT = {}
DestructionParamsMT.__index = DestructionParamsMT

--[=[
	The virtual/physical hitbox that the destruction will use.

	If this is not provided, [CFrame](../DestructionParameters#CFrame), [Size](../DestructionParameters#Size), and [Shape](../DestructionParameters#Shape), will be used. *You must provide one or the other.*

	If this is a Model, a destruction will be queued for every Part descendant of that Model

	@prop CuttingPart (ImaginaryPart|Part|Model)?
	@within DestructionParameters
]=]
DestructionParamsMT.CuttingPart = nil :: (Types.WorldInfo | Part | Model)?

--[=[
	@prop CFrame CFrame?
	@within DestructionParameters
]=]
DestructionParamsMT.CFrame = CFrame.identity :: CFrame?

--[=[
	@prop Size Vector3?
	@within DestructionParameters
]=]
DestructionParamsMT.Size = Vector3.zero :: Vector3?

--[=[
	@prop Shape PartType?
	@within DestructionParameters
]=]
DestructionParamsMT.Shape = Enum.PartType.Ball :: Enum.PartType?

--[=[
	Only instances with the given tag(s) are considered for voxel destruction.

	If this is not passed, every BasePart without the `"Indestructible"` tag is considered.

	@prop FilterTagged (string | {string})?
	@within DestructionParameters
]=]
DestructionParamsMT.FilterTagged = nil :: (string | {string})?

--[=[
	The amount of time in seconds before this destruction is cleaned up.

	:::note
	Set this to 0 to disable cleanups per-destruction
	:::

	:::note
	New destructions can reset the cleanup timer of existing dirty groups, *only if the new reset time would extend the time until cleanup.*

	#### Example

	You destroy with a `CleanupDelay` of 10, wait 4 seconds, and then with a `CleanupDelay` of 2 in the same spot. You will have to wait 6 seconds for it to come back because 6 is greater than 2.

	If you instead waited 9 seconds, the time until cleanup would get extended to 2 seconds because 1 is less than 2.
	:::

	@prop CleanupDelay number?
	@within DestructionParameters
]=]
DestructionParamsMT.CleanupDelay = nil :: number?

--[=[
	What GridSize this hitbox will divide parts down to.

	This can cause issues with greedy meshing if you destroy a part using multiple grid sizes.

	You should instead give parts a GridSize number attribute so each Part only has one GridSize.

	@prop GridSize number?
	@within DestructionParameters
	@deprecated Release 7
]=]
DestructionParamsMT.GridSize = nil :: number?

--[=[
	*This makes larger destructions an entire **order of magnitude** faster.*

	Whether or not to intelligently skip voxels fully contained by the hitbox.

	If this is false, these fully contained parts are Voxelized entirely using math.

	Otherwise, they are directly deleted.

	:::note
	If you use this parameter you will only recieve "edge" voxels.
	:::

	@prop SkipEncapsulatedVoxels boolean?
	@within DestructionParameters
]=]
DestructionParamsMT.SkipEncapsulatedVoxels = nil :: boolean?

--[=[
	@prop SkipFloors boolean?
	@within DestructionParameters
]=]
DestructionParamsMT.SkipFloors = nil :: boolean?

--[=[
	@prop SkipWalls boolean?
	@within DestructionParameters
]=]
DestructionParamsMT.SkipWalls = nil :: boolean?

--[=[
	The name of the OnVoxelDestruct effect you want to use for this destruction.

	You can register these effects either with [Shatterbox.RegisterOnVoxelDestruct] or by making an entry in the desired `Shatterbox/effects` module.

	Client side effects should be registered on the client side, while server side effects should be registered on the server side. Client side effects only work with Client-Server enabled.

	*You should register any given effect only once in a static context, which you are then free to use anywhere else - even in other scripts.*

	```lua
	Shatterbox.RegisterOnVoxelDestruct("SomeName", function(voxel, info)

		voxel.Anchored = false

		return
	end)

	-- later or in another script
	hb.OnVoxelDestruct = "SomeName"
	```

	@prop OnVoxelDestruct string?
	@within DestructionParameters
]=]
DestructionParamsMT.OnVoxelDestruct = nil :: string?

--[=[
	A callback that runs when the destruction is finished processing 

	:::warning
	This only works with `Shatterbox.Destroy` or `hitbox:Destroy()`.

	For ImaginaryVoxels, you can use the array of imaginary voxels to obtain the same information.
	:::
	@prop OnDestructCompleted OnDestructCompleted?
	@within DestructionParameters
]=]
DestructionParamsMT.OnDestructCompleted = nil :: Types.OnDestructCompleted?

--[=[
	A table that is passed to the OnVoxelDestruct effect as `info.UserData`.

	You can put variables in this table that are to be used in your effect.

	@prop UserData {any}?
	@within DestructionParameters
]=]
DestructionParamsMT.UserData = nil :: {any}?

--[=[
	If set, how many seconds the server will wait at max for each client to recieve their static map parts.

	This only works with Client-Server enabled.

	Use this if you see the ground flashing due to the size of your destruction.

	:::danger
	If you use it, be sure to keep this set to a low value like 0.1 or 0.2, as exploiters/laggy players can force every destruction to take this maximum amount of time.
	:::
	@prop WaitForClientTimeout number?
	@within DestructionParameters
]=]
DestructionParamsMT.WaitForClientTimeout = nil :: number?

--[=[
	A player or a list of players that will not recieve the destruction.

	This only works with Client-Server enabled.

	Use this on the server side if you have a client-initiated destruction, so the originating player doesn't recieve the same destruction they started.

	Server:
	```lua
	SomeEvent.OnServerEvent:Connect(function(plr, destructionCFrame)
		-- make sure you add sanity checks so you don't get hacked.

		hitbox.CFrame = destructionCFrame

		-- do not replicate the destruction back to "plr"
		hitbox.ExcludePlayersReplication = plr

		-- make sure the server side hitbox and the client side hitbox are identical when you do this. Otherwise the destructon won't be synchronized.
		hitbox:Destroy()
	end)
	```

	Client:
	```lua
	hitbox:Destroy()
	SomeEvent:FireServer(hitbox.CFrame)
	```

	@prop ExcludePlayersReplication (Player | {Player})?
	@within DestructionParameters
	@server
]=]
DestructionParamsMT.ExcludePlayersReplication = nil :: (Player | {Player})?



-- Validates destruction parameters
local function ValidateDestructionParams(Parameters : Types.DestructionParams | Types.ImaginaryDestructionParams)

	local CuttingPart = {} :: Types.Hitbox
	local params = {} :: Types.InternalDestructionParams | Types.InternalImaginaryParams
	local tbl = {} :: Types.DestructionParams | Types.ImaginaryDestructionParams

	assert(typeof(Parameters) == "table" or (typeof(Parameters) == "Instance" and Parameters:IsA("Part")), "Parameters must be a table or a Part")
	if typeof(Parameters) == "table" then
		tbl = Parameters
		if tbl.CuttingPart then
			local cp = tbl.CuttingPart
			assert(typeof(cp) == "table" or (typeof(cp) == "Instance" and cp:IsA("Part")), "Parameters.CuttingPart must be a table or a Part.")
			assert(cp.CFrame and cp.Size and cp.Shape, "You must provide a CFrame, Size, and Shape for the 'Parameters.CuttingPart : { CFrame : CFrame, Size : Vector3, Shape : Enum.PartType }' syntax.")
			CuttingPart.CFrame = cp.CFrame
			CuttingPart.Size = cp.Size
			CuttingPart.Shape = cp.Shape
		else
			assert(tbl.CFrame and tbl.Size and tbl.Shape, "You must provide a CFrame, Size, and Shape for the 'Parameters.CFrame : CFrame, Parameters.Size : Vector3, Parameters.Shape : Enum.PartType' syntax.")
			CuttingPart.CFrame = tbl.CFrame
			CuttingPart.Size = tbl.Size
			CuttingPart.Shape = tbl.Shape
		end
	elseif Parameters:IsA("Part") then
		CuttingPart.CFrame = Parameters.CFrame
		CuttingPart.Size = Parameters.Size
		CuttingPart.Shape = Parameters.Shape
	end

	local filterTagged = tbl.FilterTagged
	if filterTagged then
		if typeof(filterTagged) == "table" then
			for _, k in pairs(filterTagged) do
				assert(typeof(k) == "string", "FilterTagged must be an array of strings only")
			end
		else
			assert(typeof(filterTagged) == "string", "FilterTagged must be a string or an array of strings")
			filterTagged = { filterTagged }
		end
	end

	local playerExclusions = tbl.ExcludePlayersReplication
	if playerExclusions then
		if typeof(playerExclusions) == "table" then
			for _, plr in ipairs(playerExclusions) do
				assert(typeof(plr) == "Instance" and plr:IsA("Player"), "If ExcludePlayersReplication is an array, it must only contain Players.")
			end
		else
			assert(typeof(playerExclusions) == "Instance" and playerExclusions:IsA("Player"), "If ExcludePlayersReplication is not an array, it must be a Player.")
			playerExclusions = { playerExclusions }
		end
	end

				  params.CuttingPart = CuttingPart
				 params.FilterTagged = filterTagged
				 params.CleanupDelay = tbl.CleanupDelay		         or Settings.DefaultSmoothCleanupDelay
			  params.OnVoxelDestruct = tbl.OnVoxelDestruct
					 params.GridSize = tbl.GridSize
	   params.SkipEncapsulatedVoxels = tbl.SkipEncapsulatedVoxels
				   params.SkipFloors = tbl.SkipFloors
				    params.SkipWalls = tbl.SkipWalls
		  params.OnDestructCompleted = tbl.OnDestructCompleted
					 params.UserData = tbl.UserData    		         or {}
		 params.WaitForClientTimeout = tbl.WaitForClientTimeout
	params.ExcludePlayersReplication = playerExclusions 			 or {}
		                   params.ID = tbl.ID 					     or GetCondensedGUID()

	assert(not params.CleanupDelay or typeof(params.CleanupDelay) == "number", "CleanupDelay must be a number if it is set.")
	assert(not params.OnVoxelDestruct or typeof(params.OnVoxelDestruct) == "string", "OnVoxelDestruct must be a string indicating the name of the OnVoxelDestruct callback.")
	assert(not params.GridSize or typeof(params.GridSize) == "number", "GridSize must be a number.")
	assert(not params.SkipEncapsulatedVoxels or typeof(params.SkipEncapsulatedVoxels) == "boolean", "SkipEncapsulatedVoxels must be a boolean.")
	assert(not params.OnDestructCompleted or typeof(params.OnDestructCompleted) == "function", "OnDestructCompleted must be a function.")

	return params :: (Types.InternalImaginaryParams | Types.InternalDestructionParams)
end

local function SerializedDestructionParams(destructionParams)
	destructionParams = table.clone(destructionParams)
	destructionParams.CuttingPart = SerializedCuttingPart(destructionParams.CuttingPart)
	return destructionParams
end

local function DeserializedDestructionParams(serialDestructionParams)
	serialDestructionParams.CuttingPart.Shape = Enum.PartType:FromValue(serialDestructionParams.CuttingPart.Shape)
	local destructionParams = ValidateDestructionParams(serialDestructionParams)
	destructionParams.replicated = true
	return destructionParams
end



local DFSWeldSearchXSizeOffset = Vector3.new(1 + EPSILON, 1 - EPSILON, 1 - EPSILON)
local DFSWeldSearchYSizeOffset = Vector3.new(1 - EPSILON, 1 + EPSILON, 1 - EPSILON)
local DFSWeldSearchZSizeOffset = Vector3.new(1 - EPSILON, 1 - EPSILON, 1 + EPSILON)

local function DFSWeld(FallingGroupID)

	-- destroy original welds if they exist, instantiate the section anchors array
	local sectionAnchors = FallingGroupSectionAnchors[FallingGroupID] or {}
	for _, part in ipairs(sectionAnchors) do
		part:Destroy()
	end

	-- add all of the falling group members to a processing queue
	local toProcess = {}
	for DirtyGroupID in pairs(FallingGroupMembers[FallingGroupID]) do
		for Part in pairs(DirtyGroupMembers[DirtyGroupID]) do
			table.insert(toProcess, Part)
		end
	end

	-- Perform DFS starting at the first member of the processing queue, while there are still elements in the processing queue.
	--  * contiguous members of the processing queue are considered a "section", with each section having a "section anchor" part that holds all of the welds for the section
	while #toProcess > 0 do
		local StartingPart = table.remove(toProcess)

		local SectionMembers = {}

		local visited, pathStack = { [StartingPart] = true }, {StartingPart}

		while #pathStack > 0 do
			local currentPart = table.remove(pathStack)
			local c, s = currentPart.CFrame, currentPart.Size

			table.insert(SectionMembers, currentPart)

			local nodeVisited = {}

			-- gather touching parts on X axis
			for _, inAxis in ipairs(workspace:GetPartBoundsInBox(c, s + DFSWeldSearchXSizeOffset)) do
				local inAxisFallingGroup = inAxis:GetAttribute(FallingGroupIDAttribute)
				if (inAxisFallingGroup and inAxisFallingGroup ~= FallingGroupID) or visited[inAxis] or inAxis == currentPart or FindHumanoidAsAncestorChild(inAxis) then continue end
				visited[inAxis] = true
				table.insert(SectionMembers, inAxis)
				nodeVisited[inAxis] = true

				if not inAxisFallingGroup or ShouldSkipInstance(inAxis) then continue end
				table.insert(pathStack, inAxis)
			end

			-- gather touching parts on Y axis
			for _, inAxis in ipairs(workspace:GetPartBoundsInBox(c, s + DFSWeldSearchYSizeOffset)) do
				local inAxisFallingGroup = inAxis:GetAttribute(FallingGroupIDAttribute)
				if (inAxisFallingGroup and inAxisFallingGroup ~= FallingGroupID) or visited[inAxis] or nodeVisited[inAxis] or inAxis == currentPart or FindHumanoidAsAncestorChild(inAxis) then continue end
				visited[inAxis] = true
				table.insert(SectionMembers, inAxis)
				nodeVisited[inAxis] = true

				if not inAxisFallingGroup or ShouldSkipInstance(inAxis) then continue end
				table.insert(pathStack, inAxis)
			end

			-- gather touching parts on Z axis
			for _, inAxis in ipairs(workspace:GetPartBoundsInBox(c, s + DFSWeldSearchZSizeOffset)) do
				local inAxisFallingGroup = inAxis:GetAttribute(FallingGroupIDAttribute)
				if (inAxisFallingGroup and inAxisFallingGroup ~= FallingGroupID) or visited[inAxis] or nodeVisited[inAxis] or inAxis == currentPart or FindHumanoidAsAncestorChild(inAxis) then continue end
				visited[inAxis] = true
				table.insert(SectionMembers, inAxis)

				if not inAxisFallingGroup or ShouldSkipInstance(inAxis) then continue end
				table.insert(pathStack, inAxis)
			end

		end

		-- Create section anchor and weld section members to it, unanchoring them in the process
		local SectionAnchor = Instance.new("Part")
		SectionAnchor.Size = Vector3.one
		SectionAnchor.Transparency = 1
		SectionAnchor.CanCollide = false
		SectionAnchor.CanQuery = false
		SectionAnchor.Parent = workspace

		-- Calculate average position and remove section members from toProcess queue
		local avgPos = Vector3.zero
		for _, Part in ipairs(SectionMembers) do
			avgPos += Part.Position

			local found = table.find(toProcess, Part)
			if found then table.remove(toProcess, found) end
		end
		avgPos /= #SectionMembers

		SectionAnchor.CFrame = CFrame.new(avgPos)
		local InverseSectionAnchorCF = SectionAnchor.CFrame:Inverse()

		-- Weld all of the section members to the section anchor
		for _, Part in ipairs(SectionMembers) do
			local weld = Instance.new("Weld")
			weld.C0 = InverseSectionAnchorCF
			weld.C1 = Part.CFrame:Inverse()
			weld.Part0 = SectionAnchor
			weld.Part1 = Part
			weld.Parent = SectionAnchor
		end

		-- Unanchor all of the section members
		for _, Part in ipairs(SectionMembers) do
			if Part:GetAttribute(FallingGroupIDAttribute) then Part.Anchored = false end
		end

		table.insert(sectionAnchors, SectionAnchor)
	end

	FallingGroupSectionAnchors[FallingGroupID] = sectionAnchors
end


-- Undoes the given destruction identified by it's DestructionID. `replicated` is true only if the server is telling a client to undo a destruction
local function UndoDirtyGroup(DirtyGroupID : string)
	-- Restore the original part and delete all current members
	local groupData = DirtyGroupData[DirtyGroupID]
	local groupMembers = DirtyGroupMembers[DirtyGroupID]

	local OriginalPart = groupData.OriginalPart
	if not USE_CLIENT_SERVER or not OriginalPart:IsA("Part") or OriginalPart.Shape ~= Enum.PartType.Block then
		OriginalPart.Parent = groupData.OriginalParent
	else
		OriginalPart.Parent = mapContainer
	end

	for member in pairs(groupMembers) do DestroyPart(member) end
	DirtyGroupMembers[DirtyGroupID] = {}

	GreedyMeshingQueue[DirtyGroupID] = nil
	SmoothCleanupQueue[DirtyGroupID] = nil
end


local function PopulateDirtyGroup(Part : Part, DirtyGroupID : string?)
	-- populate the initial dirty group information if there is no group associated with this part
	DirtyGroupID = DirtyGroupID or GetCondensedGUID()
	Part:SetAttribute(DirtyGroupIDAttribute, DirtyGroupID)
	DirtyGroupData[DirtyGroupID] = {
		OriginalPart = Part,
		OriginalParent = Part.Parent,
		GridSize = Part:GetAttribute("GridSize")
	}
	DirtyGroupMembers[DirtyGroupID] = {}

	if USE_CLIENT_SERVER and Part:IsA("Part") and Part.Shape == Enum.PartType.Block then
		-- Inheritance of ancestor tags (hierarchy only changes with client server enabled)
		for _, tag in ipairs(AncestorGroupTags(Part)) do Part:AddTag(tag) end
		-- Put the part into the mapContainer (client side is "ClientMap" folder, server side is `workspace.CurrentCamera`)
		Part.Parent = mapContainer
	end

	return DirtyGroupID
end

--[[ Does 2 things:

	* If `Part` does not have an associated dirty group, one is created for it.
	  * With client server enabled, this is where the hierarchy is managed (server side parts go into the camera, client side parts go into the client map folder)

	* Begins the smooth cleanup counter if CleanupDelay is supplied
]]
local function MarkDirty(Part : Part, destructionParams : Types.InternalImaginaryParams | Types.InternalDestructionParams)

	local CreatedDirtyGroups = {}

	if Part:HasTag(DebrisTag) then return CreatedDirtyGroups end

	local VisitedDirtyGroups = {}

	local PartDirtyGroupID = Part:GetAttribute(DirtyGroupIDAttribute)

	local CreatedFallingGroupID
	local fallingGroupContainer = FindFirstAncestorGroupWithTag(Part, FallingGroupTag)

	local PartIsDivisible = Part:IsA("Part") and Part.Shape == Enum.PartType.Block
	local NonDivisibleInteraction = Settings.NonDivisibleInteraction

	if not Part:GetAttribute(FallingGroupIDAttribute) and fallingGroupContainer then

		CreatedFallingGroupID = GetCondensedGUID()
		local fallingGroupMembers = {}

		for _, part in ipairs(fallingGroupContainer:GetDescendants()) do
			if not part:IsA("BasePart") then continue end

			part:SetAttribute(FallingGroupIDAttribute, CreatedFallingGroupID)
			local DirtyGroupID = PopulateDirtyGroup(part, nil)
			VisitedDirtyGroups[DirtyGroupID] = true

			if part:IsA("Part") and part.Shape == Enum.PartType.Block then
				CreatedDirtyGroups[DirtyGroupID] = true
			end

			part.Parent = nil
			InstantiatePart(DirtyGroupID, part.CFrame, part.Size)

			fallingGroupMembers[DirtyGroupID] = true
		end
		FallingGroupMembers[CreatedFallingGroupID] = fallingGroupMembers

	elseif not PartDirtyGroupID and (PartIsDivisible or NonDivisibleInteraction ~= "NONE") then
		PartDirtyGroupID = PopulateDirtyGroup(Part)

		if PartIsDivisible then
			CreatedDirtyGroups[PartDirtyGroupID] = true
		end
	end

	if PartDirtyGroupID then
		VisitedDirtyGroups[PartDirtyGroupID] = true
		if not PartIsDivisible and NonDivisibleInteraction ~= "NONE" and not next(DirtyGroupMembers[PartDirtyGroupID]) then
			Part.Parent = nil
			if NonDivisibleInteraction == "FALL" then
				local cloned = InstantiatePart(PartDirtyGroupID, Part.CFrame, Part.Size)
				cloned.Anchored = false
			end
		end
	end

	-- Take the maximum value of this cleanup delay and the previous ones if it exists
	local CleanupDelay = destructionParams.CleanupDelay
	if Settings.UseSmoothCleanup and CleanupDelay > 0 then
		for DirtyGroupID in pairs(VisitedDirtyGroups) do
			local prev = SmoothCleanupQueue[DirtyGroupID]
			SmoothCleanupQueue[DirtyGroupID] = prev and math.max(prev, CleanupDelay) or CleanupDelay
		end
	end

	return CreatedDirtyGroups, CreatedFallingGroupID
end


-- Returns all of the destructible parts that intersect the cuttingPart, calling MarkDirty on them
local function GetDestructibleParts(destructionParams : Types.InternalImaginaryParams | Types.InternalDestructionParams)
	local cuttingPart, replicated = destructionParams.CuttingPart, destructionParams.replicated

	local ParameterGridSize = destructionParams.GridSize

	local skipFloors, skipWalls = destructionParams.SkipFloors, destructionParams.SkipWalls
	local skipFloorsOrWalls = skipFloors or skipWalls

	local partsInPart, createdDirtyGroups, createdFallingGroups = {}, {}, {}

	IntersectingPart.CFrame = cuttingPart.CFrame
	IntersectingPart.Size = cuttingPart.Size
	IntersectingPart.Shape = cuttingPart.Shape

	local AffectedDirtyGroups = {}

	for _, part in ipairs( workspace:GetPartsInPart(IntersectingPart, destructionParams.FilterTagged and OverlapParamsOfTagged(destructionParams.FilterTagged)) ) do
		if ImaginaryDestroyQueue[part] then continue end

		if (replicated and not part:IsDescendantOf(mapContainer)) or ShouldSkipInstance(part) then continue end

		if part:HasTag(DebrisTag) then
			table.insert(partsInPart, part)
			continue
		end

		if skipFloorsOrWalls then
			raycastParams.FilterDescendantsInstances = { part }
			local res = workspace:Raycast(cuttingPart.CFrame.Position, part.Position - cuttingPart.CFrame.Position, raycastParams)
			if res then
				local isFloor = res.Normal:FuzzyEq(Vector3.yAxis, 0.001)
				if (skipFloors and isFloor) or (skipWalls and not isFloor) then continue end
			end
		end

		local dirtyGroups, fallingGroupID = MarkDirty(part, destructionParams)
		for DirtyGroupID in pairs(dirtyGroups) do
			createdDirtyGroups[DirtyGroupID] = true
		end

		if fallingGroupID then
			ChangedFallingGroups[fallingGroupID] = true
			createdFallingGroups[fallingGroupID] = true
		else
			fallingGroupID = part:GetAttribute(FallingGroupIDAttribute)
			if fallingGroupID then ChangedFallingGroups[fallingGroupID] = true end
		end

		if part:IsA("Part") and part.Shape == Enum.PartType.Block then
			table.insert(partsInPart, part)

			local DirtyGroupID = part:GetAttribute(DirtyGroupIDAttribute)
			if Settings.UseGreedyMeshing then
				local groupData = DirtyGroupData[DirtyGroupID]

				local newGridSize = ParameterGridSize or groupData.GridSize or Settings.DefaultGridSize
				local oldGridSize = GreedyMeshingQueue[DirtyGroupID]

				GreedyMeshingQueue[DirtyGroupID] = oldGridSize and math.min(oldGridSize, newGridSize) or newGridSize
			end

			AffectedDirtyGroups[DirtyGroupID] = true
		end
	end

	return partsInPart, createdDirtyGroups, createdFallingGroups, AffectedDirtyGroups
end

-- Returns all of the imaginary destructible parts that intersect the cuttingPart, removing them from the ImaginaryCreateQueue when that happens.
local function GetImaginaryDestructibleParts(cuttingPart, verts, normals)
	local iBa, iC = cuttingPart.Shape.Name == "Ball", cuttingPart.Shape.Name == "Cylinder"

	local processed = {}
	local destructibles = {}

	while #ImaginaryCreateQueue > 0 do
		local ivox = table.remove(ImaginaryCreateQueue)
		local voxVerts = BlockVerts(ivox.CFrame, ivox.Size)

		local intersected = PartContainsAVert(cuttingPart, voxVerts)
		if not intersected then
			if iBa then
				intersected = VertexMath.BallIntersectsBlock(cuttingPart.CFrame, cuttingPart.Size, ivox.CFrame, ivox.Size)
			elseif iC then
				intersected = VertexMath.CylinderIntersectsBlock(cuttingPart.CFrame, cuttingPart.Size, verts, normals, ivox.CFrame, ivox.Size, BlockVerts(ivox.CFrame, ivox.Size), BlockNormals(ivox.CFrame))
			else
				intersected = PartContainsAVert(cuttingPart, verts) or VertexMath.SAT(verts, normals, voxVerts, BlockNormals(ivox.CFrame))
			end
		end

		table.insert(intersected and destructibles or processed, ivox)
	end

	ImaginaryCreateQueue = processed
	return destructibles
end


--Performs voxel destruction according to the parameters, returning an array of un-created voxels as well as any existing debris as a second returned array.
local function ImaginaryVoxels(params, destructibleParts, dirtyGroups)
	local toDestroy, AffectedDirtyGroups
	if destructibleParts then
		toDestroy, AffectedDirtyGroups = destructibleParts, dirtyGroups
	else
		toDestroy, _, _, AffectedDirtyGroups = GetDestructibleParts(params)
	end

	local voxels, existingDebris = {} :: {Types.ImaginaryVoxel}, {} :: {BasePart}
	local voxelCount = 0

	--debug.profilebegin("FindDestructibleParts")
	local partsInPart = {}
	for _, part in ipairs(toDestroy) do
		if part:HasTag(DebrisTag) then
			table.insert(existingDebris, part)
			continue
		end

		ImaginaryDestroyQueue[part] = true

		local DirtyGroupID = part:GetAttribute(DirtyGroupIDAttribute)

		table.insert(partsInPart, {
			CFrame = part.CFrame,
			Size = part.Size,

			DirtyGroupID = DirtyGroupID,

			GridSize = params.GridSize or DirtyGroupData[DirtyGroupID].GridSize or Settings.DefaultGridSize
		})
	end

	local cuttingPart = params.CuttingPart
	local cpcf, cps, cpsh = cuttingPart.CFrame, cuttingPart.Size, cuttingPart.Shape.Name
	local iBl, iBa, iC = cpsh == "Block", cpsh == "Ball", cpsh == "Cylinder"

	local intersectingVerts, intersectingNormals
	if iBl or iC then
		intersectingVerts = BlockVerts(cpcf, cps)
		intersectingNormals = BlockNormals(cpcf)
	elseif not iBa then
		intersectingVerts = GetVerts[cpsh](cpcf, cps)
		intersectingNormals = GetNormals[cpsh](cpcf, cps)
	end

	if #ImaginaryCreateQueue > 0 then
		local ImaginaryDestructibleParts = GetImaginaryDestructibleParts(params.CuttingPart, intersectingVerts, intersectingNormals)
		if #ImaginaryDestructibleParts > 0 then table.move(ImaginaryDestructibleParts, 1, #ImaginaryDestructibleParts, #partsInPart + 1, partsInPart) end
	end

	if #partsInPart == 0 then return nil, existingDebris end

	--debug.profileend()

	local dividing = partsInPart :: {Types.ImaginaryBox}
	partsInPart = nil

	local creating = {} :: {Types.ImaginaryBox}

	--debug.profileend()

	--debug.profilebegin("ImaginaryDivisionStep")

	-- imaginary division step
	while #dividing > 0 do

		--debug.profilebegin("IntersectionTest")

		local toDivide = table.remove(dividing, 1)
		local verts = BlockVerts(toDivide.CFrame, toDivide.Size)

		local intersected = PartContainsAVert(cuttingPart, verts)
		if not intersected then
			if iBa then
				intersected = VertexMath.BallIntersectsBlock(cpcf, cps, toDivide.CFrame, toDivide.Size)
			elseif iC then
				intersected = VertexMath.CylinderIntersectsBlock(cpcf, cps, intersectingVerts, intersectingNormals, toDivide.CFrame, toDivide.Size, verts, BlockNormals(toDivide.CFrame))
			else
				intersected = VertexMath.SAT(intersectingVerts, intersectingNormals, verts, BlockNormals(toDivide.CFrame))
			end
		else
			table.remove(verts, intersected)
		end

		--debug.profileend()

		--debug.profilebegin("ProcessIntersection")

		if intersected then
			local s, gridSize, DirtyGroupID = toDivide.Size, toDivide.GridSize, toDivide.DirtyGroupID

			local voxelCountAxis = Vector3.one:Max(s // gridSize)
			local toDivideVoxelContributions = voxelCountAxis.X*voxelCountAxis.Y*voxelCountAxis.Z

			-- if toDivide is literally only a single voxel large and cannot divide, add it as a voxel
			if toDivideVoxelContributions == 1 then

				voxelCount += toDivideVoxelContributions
				table.insert(voxels, toDivide)

				-- toDivide is done being procesed
				continue
			end

			--debug.profilebegin("EncapsulationCheck")
			-- if toDivide is encapsulated within CuttingPart, there is no need to run expensive division algorithm
			if PartContainsAllVerts(cuttingPart, verts or BlockVerts(toDivide.CFrame, toDivide.Size)) then
				-- The encapsulated part contributes this many voxels
				voxelCount += toDivideVoxelContributions

				-- if SkipEncapsulatedVoxels, do nothing and skip the encapsulated part
				if params.SkipEncapsulatedVoxels then continue end

				-- otherwise, use ImaginaryVoxelize to turn the encapsulated part into it's constituent voxels
				local newVoxels = ImaginaryVoxelize(toDivide, gridSize)
				for _, created in ipairs(newVoxels) do
					created.GridSize = gridSize
					created.DirtyGroupID = DirtyGroupID
				end
				table.move(newVoxels, 1, #newVoxels, #voxels + 1, voxels)

				-- toDivide is done being processed
				continue
			end
			--debug.profileend()

			-- if toDivide is not encapsulated within CuttingPart, it lies along the edge of the destruction
			toDivide.isEdge = true

			local sx,sy,sz = s.X, s.Y, s.Z
			local minsize, maxsize = math.min(sx, sy, sz), math.max(sx, sy, sz)

			-- use Subdivide (either KD or MOT to subdivide toDivide)
			for _, created in ipairs(SubdivideFunctions[(maxsize > 2 * minsize) and "KD" or "MOT"](toDivide, gridSize)) do
				--[[
				-- early encapsulation check on the children parts because encapsulation checks are faster than intersection checks
				if PartContainsAllVerts(cuttingPart, BlockVerts(created.CFrame, created.Size)) then

					local countAxis = Vector3.one:Max(created.Size // gridSize)
					-- the encapsulated child contributes this many voxels
					voxelCount += countAxis.X*countAxis.Y*countAxis.Z

					if params.SkipEncapsulatedVoxels then continue end

					-- if not SkipEncapsulatedVoxels, use ImaginaryVoxelize to turn the child into its constituent voxels
					local newVoxels = ImaginaryVoxelize(created, gridSize)
					for _, v in ipairs(newVoxels) do
						v.GridSize = gridSize
						v.DirtyGroupID = DirtyGroupID
					end
					table.move(newVoxels, 1, #newVoxels, #voxels + 1, voxels)

					continue
				end
				--]]

				created.GridSize = gridSize
				created.DirtyGroupID = DirtyGroupID
				created.isEdge = true
				table.insert(dividing, created)
			end
		else
			-- if the toDivide part is not intersecting the CuttingPart, it is a static part
			table.insert(creating, toDivide)
		end

		--debug.profileend()
	end

	--debug.profileend()

	--debug.profilebegin("CreateNewState")

	if #creating > 0 then table.move(creating, 1, #creating, #ImaginaryCreateQueue + 1, ImaginaryCreateQueue) end

	-- create new static parts
	--[[
	for _, ibox in ipairs(creating) do
		InstantiatePart(ibox.DirtyGroupID, ibox.CFrame, ibox.Size)
	end

	--debug.profileend()

	--debug.profilebegin("DestroyOldState")

	-- destroy original parts
	for _, part in ipairs(toDestroy) do
		if table.find(existingDebris, part) then continue end
		DestroyPart(part)
	end
	--]]

	--[[
	if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then
		for _, part in ipairs(toDestroy) do
			CachedParts:ReturnPart(part)
		end
	else

	end
	--]]

	--[[
	for FallingGroupID in pairs(OperationAffectedFallingGroups[params.ID]) do
		DFSWeld(FallingGroupID)
	end
	--]]

	--debug.profileend()

	return setmetatable(voxels, { __len = function() return voxelCount end }) :: {Types.ImaginaryVoxel}, existingDebris :: {BasePart}, AffectedDirtyGroups :: {[string] : boolean}
end
--]]


-- Uses the given callback from the OnVoxelDestruct registry to destroy the given voxel
local function HandleVoxelDestruction(callbackName : string?, voxel : Part, info : Types.DestroyedVoxelInfo?)
	if not info then info = {} end

	local s, e = pcall(OnVoxelDestructRegistry[callbackName], voxel, info)

	if not s then warn("Voxel destruction failed: " .. e) end

	if not info.IsAlreadyDebris then voxel:AddTag(DebrisTag) end
end



-- processes one of the operations in the ShatterQueue, removing it if the operation is finished. It queues all divisions for this step of the operation.
-- returns true if an operation step was procesed.
local function ProcessShatterQueue()
	if #ShatterQueue == 0 then return end
	repeat
		local popped = table.remove(ShatterQueue)
		local OnVoxelDestruct = popped.OnVoxelDestruct
		local CuttingPart, UserData = popped.CuttingPart, popped.UserData

		local ivoxels, existingDebris, affectedIDs = ImaginaryVoxels(popped)

		if ivoxels then
			if OnVoxelDestructRegistry[OnVoxelDestruct] then
				for _, ivoxel in ipairs(ivoxels) do
					HandleVoxelDestruction(OnVoxelDestruct, Shatterbox.InstantiateImaginaryVoxel(ivoxel, true), {
						DirtyGroupID = ivoxel.DirtyGroupID,
						CuttingPart = CuttingPart,
						IsEdge = ivoxel.isEdge,
						IsAlreadyDebris = false,
						UserData = UserData
					})
				end
			end
		end

		if #existingDebris > 0 then
			if OnVoxelDestructRegistry[OnVoxelDestruct] then
				for _, debris in ipairs(existingDebris) do
					HandleVoxelDestruction(OnVoxelDestruct, debris, {
						DirtyGroupID = debris:GetAttribute(DirtyGroupIDAttribute),
						CuttingPart = CuttingPart,
						IsEdge = not PartEncapsulatesBlockPart(CuttingPart, debris.CFrame, debris.Size),
						IsAlreadyDebris = true,
						UserData = UserData
					})
				end
			else
				for _, debris in ipairs(existingDebris) do DestroyPart(debris) end
			end
		end

		if popped.OnDestructCompleted then popped.OnDestructCompleted(ivoxels and #ivoxels or 0, affectedIDs) end

	until #ShatterQueue == 0
end




-- Creates all of the original map parts associated with a destruction for the clients.
-- This allows the clients to process their own destructions alongside the server.
local function CreateSerialDirtyGroups(SerialDirtyGroups)
	for DirtyGroupID, serialOriginal in pairs(SerialDirtyGroups) do
		local newPart = DeserializedPartInstance(serialOriginal)
		newPart.Parent = mapContainer

		DirtyGroupData[DirtyGroupID] = {
			OriginalPart = newPart,
			OriginalParent = mapContainer,
			GridSize = serialOriginal.Attributes.GridSize
		}
		DirtyGroupMembers[DirtyGroupID] = {}
	end
end

-- Creates dirty groups for the server and every player except "plr"
local function CreateDirtyGroupsFromClient(plr, DirtyGroups)
	local SerialDirtyGroups = {}
	for DirtyGroupID, part in pairs(DirtyGroups) do
		PopulateDirtyGroup(part, DirtyGroupID)
		SerialDirtyGroups[DirtyGroupID] = SerializedPartInstance(part)
	end

	ServerEvents.CreateDirtyGroupsFromServer.FireExcept(plr, SerialDirtyGroups)
end

local function SendDirtyGroupsToServer(DirtyGroups)
	if not next(DirtyGroups) then return end

	local ToSendToServer = {}
	for DirtyGroupID in pairs(DirtyGroups) do
		local groupData = DirtyGroupData[DirtyGroupID]
		local PartToSend = groupData.OriginalPart
		local newClientPart = PartFromTemplate(PartToSend, PartToSend.CFrame)
		groupData.OriginalPart = newClientPart
		PartToSend.Parent = nil
		newClientPart.Parent = mapContainer
		ToSendToServer[DirtyGroupID] = PartToSend
	end
	ClientEvents.CreateDirtyGroupsFromClient.Fire(ToSendToServer)
	StepReplication()
end


local function ReplicateDestructionToClients(destructionType : DestructionTypes, destructionParams : Types.DestructionParams, createdDirtyGroups : { [string] : boolean }, skipClientWaiting : boolean?)

	local serialNewDirtyGroups = {}
	for DirtyGroupID in pairs(createdDirtyGroups) do
		serialNewDirtyGroups[DirtyGroupID] = SerializedPartInstance(DirtyGroupData[DirtyGroupID].OriginalPart)
	end

	local PlayerList = Players:GetPlayers()
	local exclusions = destructionParams.ExcludePlayersReplication
	if #exclusions > 0 then
		for _, plr in ipairs(exclusions) do
			local found = table.find(PlayerList, plr)
			if found then table.remove(PlayerList, found) end
		end

		if #PlayerList == 0 then return end

		ServerEvents.ReplicateDestruction.FireList(PlayerList, destructionType, SerializedDestructionParams(destructionParams), serialNewDirtyGroups)
	else
		ServerEvents.ReplicateDestruction.FireAll(destructionType, SerializedDestructionParams(destructionParams), serialNewDirtyGroups)
	end

	if not destructionParams.WaitForClientTimeout or destructionType == IMAGINARY then return end

	local disconnect
	disconnect = ServerEvents.ClientRecievedMapParts.On(function(fromPlr, DestructionID)
		if destructionParams.ID ~= DestructionID then return end
		local found = table.find(PlayerList, fromPlr)
		if found then table.remove(PlayerList, found) end
	end)
	local elapsed = 0
	local waitingOnPlayersConnection
	waitingOnPlayersConnection = RunService.Heartbeat:Connect(function(deltaTime)
		elapsed += deltaTime
		if elapsed >= destructionParams.WaitForClientTimeout or #PlayerList == 0 then
			waitingOnPlayersConnection:Disconnect()
			waitingOnPlayersConnection = nil
			disconnect()
		end
	end)
	while waitingOnPlayersConnection do RunService.Heartbeat:Wait() end
end

local function ReplicateDestructionFromServer(destructionType, serialParams, serialNewDirtyGroups)

	local destructionParams = DeserializedDestructionParams(serialParams)

	CreateSerialDirtyGroups(serialNewDirtyGroups)

	if destructionType == IMAGINARY then
		destructionParams.SkipEncapsulatedVoxels = true
		RunService.Heartbeat:Wait()
		ImaginaryVoxels(destructionParams)

	elseif destructionType == NORMAL then
		if destructionParams.WaitForClientTimeout and destructionParams.WaitForClientTimeout > 0 then
			ClientEvents.ClientRecievedMapParts.Fire(destructionParams.ID)
		end

		table.insert(ShatterQueue, destructionParams)
	end
end



local function IsPuppet(instance : Instance) : boolean
	for _, puppetData in pairs(Puppets) do
		if puppetData[1] == instance then return true end
	end
	return false
end

local function GetActivePuppets()

	local puppets = {}

	for i, puppetData in pairs(Puppets) do -- every time the period is reached, push all available voxel CFrames to their state replication queue
		local puppetVoxel = puppetData[1]

		if puppetVoxel.Anchored then continue end

		if puppetVoxel.AssemblyLinearVelocity.Magnitude <= Settings.PuppetSleepVelocity then continue end

		table.insert(puppets, puppetVoxel)
	end

	return puppets
end

local function GetActivePuppetCount()

	local puppetCount = 0

	for i, puppetData in pairs(Puppets) do -- every time the period is reached, push all available voxel CFrames to their state replication queue
		local puppetVoxel = puppetData[1]

		if puppetVoxel.Anchored then continue end

		if puppetVoxel.AssemblyLinearVelocity.Magnitude <= Settings.PuppetSleepVelocity then continue end

		puppetCount += 1
	end

	return puppetCount
end

local FakePuppetOverrideIndex = 1

local function DeserializedPuppet(serialPuppet)
	local Part = DeserializedPartInstance(serialPuppet, CachedParts)

	Part.Anchored = true

	Part:AddTag(IndestructibleTag)

	Part.Parent = mapContainer

	return Part
end

local WorldAnchor = Instance.new("Part")
WorldAnchor.CanCollide = false
WorldAnchor.CanTouch = false
WorldAnchor.CanQuery = false
WorldAnchor.Anchored = true
WorldAnchor.Transparency = 1
WorldAnchor.CFrame = CFrame.identity
WorldAnchor.Parent = workspace

local function CreatePuppets(puppets)
	--debug.profilebegin("Create Puppets")
	for _, serialPuppet in ipairs(puppets) do
		local Part = DeserializedPuppet(serialPuppet)

		--
		local Motor6D = Instance.new("Motor6D")
		Motor6D.Transform = serialPuppet.CFrame
		Motor6D.Part0 = WorldAnchor
		Motor6D.Part1 = Part
		Motor6D.Parent = Part

		Part.Anchored = false
		--]]

		local OldPuppetData = Puppets[PuppetNextIndex]
		if OldPuppetData then
			OldPuppetData[1]:Destroy()
			PuppetsLerpData[PuppetNextIndex] = nil
		end

		Puppets[PuppetNextIndex] = { Part }

		PuppetNextIndex += 1
		if PuppetNextIndex > Settings.PuppetMaxCount then
			PuppetNextIndex = 1
		end
	end
	FakePuppetOverrideIndex = PuppetNextIndex
	--debug.profileend()
end


local U82RAD = 0.0246399423811
local PRECISE_45_DEGREES = {}
PRECISE_45_DEGREES[32] = math.pi * 0.25
PRECISE_45_DEGREES[64] = math.pi * 0.5
PRECISE_45_DEGREES[96] = math.pi * 0.75
PRECISE_45_DEGREES[128] = math.pi
PRECISE_45_DEGREES[159] = -PRECISE_45_DEGREES[96]
PRECISE_45_DEGREES[191] = -PRECISE_45_DEGREES[64]
PRECISE_45_DEGREES[223] = -PRECISE_45_DEGREES[32]
PRECISE_45_DEGREES[255] = 0

local function ReadRadianU8(b, bitOff)
	local X = buffer.readbits(b, bitOff, 8)
	return PRECISE_45_DEGREES[X] or (X * U82RAD)
end

local function ReadFloatI25(b, bitOff)
	local X = buffer.readbits(b, bitOff + 1, 24) * 0.001
	return buffer.readbits(b, bitOff, 1) == 0 and X or -X
end

local function ReplicatePuppetStates(puppetStatesBuffer, stepDelta)
	ClientPuppetStepDelta = stepDelta

	local bitLength = buffer.len(puppetStatesBuffer)

	local i = 1
	local updatedPuppets, updatedStates = {}, {}

	bitLength *= 8
	local bitOffset = 0

	local clientCamPos = workspace.CurrentCamera.CFrame.Position

	local sqLimit = Settings.ClientTweenDistanceLimit ^ 2
	local doNotTweenPuppets = not Settings.ClientTweenPuppets
	while bitOffset < bitLength do
		local index = buffer.readbits(puppetStatesBuffer, bitOffset + 99, 13)
		local puppetData = Puppets[index]
		if puppetData then
			local cframe = CFrame.new(
				ReadFloatI25(puppetStatesBuffer, bitOffset),
				ReadFloatI25(puppetStatesBuffer, bitOffset + 25),
				ReadFloatI25(puppetStatesBuffer, bitOffset + 50)
			) * CFrame.fromEulerAngles(
				ReadRadianU8(puppetStatesBuffer, bitOffset + 75),
				ReadRadianU8(puppetStatesBuffer, bitOffset + 83),
				ReadRadianU8(puppetStatesBuffer, bitOffset + 91)
			)

			local toPlr = clientCamPos - cframe.Position
			if doNotTweenPuppets or (toPlr.X^2 + toPlr.Y^2 + toPlr.Z^2 >= sqLimit) then
				-- Puppets outside of the interpolation distance limit are moved directly to their updated position in bulk (or if the interpolation setting is disabled)
				if PuppetsLerpData[index] then PuppetsLerpData[index] = nil end
				--puppetData[1].CFrame = cframe
				updatedPuppets[i] = puppetData[1]
				updatedStates[i] = cframe
				i += 1
			else
				-- change the interpolation target of this Puppet index
				PuppetsLerpData[index] = {
					puppetData[1].CFrame,
					cframe,
					0
				}
			end
		end

		bitOffset += 112
	end

	--debug.profilebegin("BulkMoveTo Puppets")
	if i > 1 then workspace:BulkMoveTo(updatedPuppets, updatedStates, Enum.BulkMoveMode.FireCFrameChanged) end
	--debug.profileend()
end
if isClient then -- Client side interpolation loop that "tweens" every puppet voxel and moves them in bulk
	RunService.PreRender:Connect(function(deltaTime)
		if not next(PuppetsLerpData) then return end

		--debug.profilebegin("Direct set CFrame Puppets")
		local P = ClientPuppetStepDelta / Settings.PuppetReplicationFrequency

		--local i = 1
		local puppets, interpolatedPositions, finishedLerps = nil, nil, {}
		for index, lerpData in pairs(PuppetsLerpData) do
			local d = lerpData[3] + deltaTime
			local Motor6D = Puppets[index][1]:FindFirstChildWhichIsA("Motor6D")
			if d >= P then
				table.insert(finishedLerps, index)
				--interpolatedPositions[i] = lerpData[2]
				--Puppets[index][1].CFrame = lerpData[2]
				Motor6D.Transform = lerpData[2]
			else
				--interpolatedPositions[i] = lerpData[1]:Lerp(lerpData[2], d / P)
				--Puppets[index][1].CFrame = lerpData[1]:Lerp(lerpData[2], d / P)
				Motor6D.Transform = lerpData[1]:Lerp(lerpData[2], d / P)
				lerpData[3] = d
			end

			--puppets[i] = Puppets[index][1]
			--i += 1
		end

		for _, index in ipairs(finishedLerps) do PuppetsLerpData[index] = nil end

		--workspace:BulkMoveTo(puppets, interpolatedPositions, Enum.BulkMoveMode.FireCFrameChanged)
		--debug.profileend()
	end)
end

--[[
RunService.PostSimulation:Connect(function(dt)
    local activePuppets = GetActivePuppets()
    local puppetNum = #activePuppets

	if puppetNum < 71 then return end

	local ReplicationSteps = puppetNum // 71 - 1

    for _, puppet in pairs(activePuppets) do
		local a = Vector3.new(puppet.CFrame:ToEulerAngles()) + puppet.AssemblyAngularVelocity * dt * ReplicationSteps
		puppet.CFrame = CFrame.new(puppet.Position + puppet.AssemblyLinearVelocity * dt * ReplicationSteps) * CFrame.fromEulerAngles(a.X, a.Y, a.Z)
    end
end)
--]]

local function DestroyPuppet(index)
	Puppets[index][1]:Destroy()
	Puppets[index] = nil
	PuppetsLerpData[index] = nil
end




local function ReplicateStateToPlayer(plr)

	local serialDirtyGroupData = {}
	for DirtyGroupID, groupData in pairs(DirtyGroupData) do
		local OriginalPart = groupData.OriginalPart

		if OriginalPart:IsA("Part") and OriginalPart.Shape == Enum.PartType.Block then
			-- only send the original part because OriginalParent doesn't matter in this case and GridSize can be derived
			serialDirtyGroupData[DirtyGroupID] = SerializedPartInstance(OriginalPart)
		end
	end

	local serialDirtyGroupMembers, destroyedDirtyGroups = {}, {}
	for DirtyGroupID in pairs(serialDirtyGroupData) do
		local groupMembers = DirtyGroupMembers[DirtyGroupID]

		local OriginalPart = DirtyGroupData[DirtyGroupID].OriginalPart

		local serialMembers = {}
		serialDirtyGroupMembers[DirtyGroupID] = serialMembers

		if next(groupMembers) then
			for member in pairs(groupMembers) do
				if member:HasTag(DebrisTag) then
					local found = false
					for _, puppetData in pairs(Puppets) do
						if puppetData[1] == member then found = true break end
					end
					if found then continue end
				end
				table.insert(serialMembers, SerializedPartInstance(member))
			end
		elseif not OriginalPart.Parent then
			destroyedDirtyGroups[DirtyGroupID] = true
		end
	end

	local serialPuppets = {}
	for puppetID, puppetData in pairs(Puppets) do
		serialPuppets[puppetID] = SerializedPartInstance(puppetData[1])
	end

	ServerEvents.ReplicateState.Fire(plr,
		serialDirtyGroupData,
		serialDirtyGroupMembers,
		destroyedDirtyGroups,

		SmoothCleanupQueue,

		GreedyMeshingQueue,

		serialPuppets,
		PuppetNextIndex
	)
end

local function ReplicateStateFromServer(serialDirtyGroupData, serialDirtyGroupMembers, destroyedDirtyGroups, serverSmoothCleanupQueue, serverGreedyMeshingQueue, serialPuppets, serverPuppetsNextIndex)

	for DirtyGroupID, serializedPart in pairs(serialDirtyGroupData) do
		DirtyGroupData[DirtyGroupID] = {
			OriginalPart = DeserializedPartInstance(serializedPart),
			OriginalParent = mapContainer,
			GridSize = serializedPart.Attributes.GridSize
		}
	end

	for DirtyGroupID, serialGroupMembers in pairs(serialDirtyGroupMembers) do
		local groupMembers = {}
		DirtyGroupMembers[DirtyGroupID] = groupMembers

		if destroyedDirtyGroups[DirtyGroupID] then continue end

		if #serialGroupMembers == 0 then
			DirtyGroupData[DirtyGroupID].OriginalPart.Parent = mapContainer
			continue
		end

		for _, serialMember in ipairs(serialGroupMembers) do
			local part = DeserializedPartInstance(serialMember, CachedParts)
			if not part.Parent then part.Parent = mapContainer end
			groupMembers[part] = true
		end
	end

	SmoothCleanupQueue = serverSmoothCleanupQueue

	GreedyMeshingQueue = serverGreedyMeshingQueue

	PuppetNextIndex = serverPuppetsNextIndex
	for puppetID, serialPuppet in pairs(serialPuppets) do
		Puppets[puppetID] = { DeserializedPuppet(serialPuppet) }
	end

	clientInitComplete = true
end

local function QueueNewPlayerStateReplication(plr) table.insert(NewPlayerStateReplicationQueue, plr) end



-- Heartbeat behavior functions

local function SmoothCleanupBehavior(deltaTime)
	local toReset = {}

	for DirtyGroupID, countdown in pairs(SmoothCleanupQueue) do
		countdown -= deltaTime
		if countdown > 0 then
			SmoothCleanupQueue[DirtyGroupID] = countdown
		else
			toReset[DirtyGroupID] = true
		end
	end

	for DirtyGroupID in pairs(toReset) do UndoDirtyGroup(DirtyGroupID) end
end


local TAU = 2*math.pi
local RAD2U8 = 40.5845104884

local function WriteFloatI25(b, bitOff, x)
	local S = 0
	if x < 0 then
		S = 1
		x = -x
	end
	buffer.writebits(b, bitOff, 1, S)
	buffer.writebits(b, bitOff + 1, 24, math.round(x * 1000))
end

local function PuppeteerBehavior(deltaTime)

	puppetTimeAccumulation += deltaTime
	local P = 1 / Settings.PuppetReplicationFrequency
	if puppetTimeAccumulation >= P then
		repeat puppetTimeAccumulation -= P until puppetTimeAccumulation < P

		for i, puppetData in pairs(Puppets) do -- every time the period is reached, push all available voxel CFrames to their state replication queue
			local puppetVoxel = puppetData[1]

			if puppetVoxel.Anchored then continue end

			if puppetVoxel.AssemblyLinearVelocity.Magnitude <= Settings.PuppetSleepVelocity then
				local d = puppetData[4] + deltaTime
				if d >= Settings.PuppetAnchorTimeout then
					puppetVoxel.Anchored = true
					table.insert(PuppetsLerpData[i], 1, puppetVoxel.CFrame) -- replicate the final resting state of this voxel
					puppetData[4] = 0
				else
					puppetData[4] = d
				end
				continue
			end

			puppetData[4] = 0

			table.insert(PuppetsLerpData[i], 1, puppetVoxel.CFrame)
		end

		local AvailablePuppets = {}
		local StartIndex = PuppetNextReplicationIndex
		while #AvailablePuppets < 70 do
			local ReplicationIndex = PuppetNextReplicationIndex
			PuppetNextReplicationIndex += 1
			if PuppetNextReplicationIndex > Settings.PuppetMaxCount then
				PuppetNextReplicationIndex = 1
			end
			if PuppetNextReplicationIndex == StartIndex then break end

			local puppetData = Puppets[ReplicationIndex]
			if not puppetData then continue end

			if #PuppetsLerpData[ReplicationIndex] == 0 then continue end

			if table.find(CreatePuppetQueue, puppetData[1]) then continue end

			table.insert(AvailablePuppets, ReplicationIndex)
		end

		local countToReplicate = #AvailablePuppets
		if countToReplicate > 0 then
			local puppetStates = buffer.create(countToReplicate * 14)

			for i, ReplicationIndex in ipairs(AvailablePuppets) do
				--local puppetVoxel = Puppets[ReplicationIndex][1]

				local bufferBitOffset = (i - 1) * 112

				local cframe = table.remove(PuppetsLerpData[ReplicationIndex])
				WriteFloatI25(puppetStates, bufferBitOffset, cframe.X)
				WriteFloatI25(puppetStates, bufferBitOffset + 25, cframe.Y)
				WriteFloatI25(puppetStates, bufferBitOffset + 50, cframe.Z)

				local rX, rY, rZ = cframe:ToEulerAngles()
				buffer.writebits(puppetStates, bufferBitOffset + 75, 8, math.round((rX % TAU) * RAD2U8))
				buffer.writebits(puppetStates, bufferBitOffset + 83, 8, math.round((rY % TAU) * RAD2U8))
				buffer.writebits(puppetStates, bufferBitOffset + 91, 8, math.round((rZ % TAU) * RAD2U8))

				buffer.writebits(puppetStates, bufferBitOffset + 99, 13, ReplicationIndex)
			end

			local stepDelta = 0
			for _, queuedCFrames in pairs(PuppetsLerpData) do
				if #queuedCFrames == 0 then continue end
				stepDelta += 1
			end
			stepDelta = stepDelta > 70 and stepDelta // 70 or 1

			ServerEvents.ReplicatePuppetStates.FireAll(puppetStates, stepDelta)
		end
	end

	local PQL = #CreatePuppetQueue
	if PQL > 0 then
		local toReplicate = table.create(PQL)
		for i, puppetToCreate in ipairs(CreatePuppetQueue) do
			toReplicate[i] = SerializedPartInstance(puppetToCreate)
		end
		CreatePuppetQueue = {}
		ServerEvents.CreatePuppets.FireAll(toReplicate)
	end
end

local function HeartbeatWorker(deltaTime)

	if Settings.UseSmoothCleanup then coroutine.wrap(SmoothCleanupBehavior)(deltaTime) end

	--debug.profilebegin("Process ShatterQueue")

	ProcessShatterQueue()

	--debug.profileend()

	if #ImaginaryCreateQueue > 0 then
		if Settings.UseGreedyMeshing then
			--debug.profilebegin("Process GreedyMesh")
			local DirtyGroupImaginaryParts = {}

			for _, toCreate in ipairs(ImaginaryCreateQueue) do
				local DirtyGroupID = toCreate.DirtyGroupID
				local ImaginaryParts = DirtyGroupImaginaryParts[DirtyGroupID]
				if not ImaginaryParts then
					ImaginaryParts = {}
					DirtyGroupImaginaryParts[DirtyGroupID] = ImaginaryParts
				end

				table.insert(ImaginaryParts, toCreate)
			end

			for DirtyGroupID, ImaginaryParts in pairs(DirtyGroupImaginaryParts) do
				local countMembers = #ImaginaryParts
				for _ in pairs(DirtyGroupMembers[DirtyGroupID]) do
					countMembers += 1
					if countMembers > 1 then break end
				end
				if countMembers <= 1 then
					table.move(ImaginaryParts, 1, #ImaginaryParts, #GreedyMeshedImaginaryParts + 1, GreedyMeshedImaginaryParts)
					continue
				end
				GreedyMeshBehavior(DirtyGroupID, ImaginaryParts)
			end
			--debug.profileend()

			--debug.profilebegin("Display GreedyMesh")
			for _, toCreate in ipairs(GreedyMeshedImaginaryParts) do
				InstantiatePart(toCreate.DirtyGroupID, toCreate.CFrame, toCreate.Size)
			end

			GreedyMeshedImaginaryParts = {}
			--debug.profileend()
		else
			--debug.profilebegin("Create New Parts")
			for _, toCreate in ipairs(ImaginaryCreateQueue) do
				InstantiatePart(toCreate.DirtyGroupID, toCreate.CFrame, toCreate.Size)
			end
			--debug.profileend()
		end

		ImaginaryCreateQueue = {}
	end

	--debug.profilebegin("Destroy old parts")
	if next(ImaginaryDestroyQueue) then
		for toDestroy in pairs(ImaginaryDestroyQueue) do
			DestroyPart(toDestroy)
		end
		ImaginaryDestroyQueue = {}
	end

	for FallingGroupID in pairs(ChangedFallingGroups) do
		DFSWeld(FallingGroupID)
	end
	ChangedFallingGroups = {}
	--debug.profileend()

	if #NewPlayerStateReplicationQueue > 0 then
		for _, plr in ipairs(NewPlayerStateReplicationQueue) do ReplicateStateToPlayer(plr) end
		NewPlayerStateReplicationQueue = {}
	end

	if isServer then PuppeteerBehavior(deltaTime) end

	StepReplication()
end




--[=[
	A function that defines behavior to happen after a destruction is finished processing.

	### voxelCount

	A number that dictates how many voxels this destruction destroyed. This number is identical whether or not [DestructionParameters.SkipEncapsulatedVoxels] is true.

	### affectedIDs

	An array that contains every DirtyGroupID encountered during this destruction.

	Use this to obtain information such as the materials this destruction encountered.

	```lua
	hb.OnDestructCompleted = function(count, affectedIDs)
		local materials = {}

		for DirtyGroupID in pairs(affectedIDs) do
			local original = Shatterbox.GetOriginalPart(DirtyGroupID)
			materials[original.Material] = true
		end

		for material in pairs(materials) do
			-- do something once for every material the destruction encountered
		end
	end
	```

	@type OnDestructCompleted (voxelCount : number, affectedIDs : { [string] : boolean }) -> ()
	@within Shatterbox
]=]


--[=[
	A function that is run for every voxel the destruction encounters.

	see [DestructionParameters.OnVoxelDestruct] for a brief explanation on how to use it.

	@type OnVoxelDestructType (voxel : Part, info : VoxelInfo) -> ()
	@within Shatterbox
]=]


--[=[
	@interface VoxelInfo

	A table that contains information about the destroyed voxel

	### DirtyGroupID

	The ID of the dirty group this voxel is a part of.

	A dirty group is a group of parts that all originated from the same part.

	### CuttingPart

	The state of the hitbox as it was when the destruction was queued.

	### IsEdge

	Whether or not this voxel lies along the edge of the destruction.

	### IsAlreadyDebris

	Whether or not this voxel was already debris before this destruction destroyed it again.

	### UserData

	User supplied information to use in the OnVoxelDestruct effect.

	Equivalent to [DestructionParameters.UserData].

	.DirtyGroupID string
	.CuttingPart ImaginaryPart
	.IsEdge boolean
	.IsAlreadyDebris boolean
	.UserData {any}

	@within Shatterbox
]=]

--[=[
	@interface ImaginaryPart

	A table that represents a physical object

	.CFrame CFrame
	.Size Vector3
	.Shape PartType

	@within Shatterbox
]=]

--[=[
	@interface ImaginaryVoxel

	Represents a voxel that might be created.

	These are to be instantiated using [Shatterbox.InstantiateImaginaryVoxel]

	See [Shatterbox.VoxelInfo] for an explanation on these properties.

	.CFrame CFrame
	.Size Vector3
	.Shape PartType

	.DirtyGroupID string
	.IsEdge boolean
	.UserData {any}

	@within Shatterbox
]=]




Shatterbox.Settings = Settings

--[=[
	Server side function. Begins controlled replication of `voxel` to the clients according to the Puppeteer settings.

	When the part stops moving, it will become anchored to allow for a larger number of ground debris while still having good motion.

	It is safe to un-anchor these parts again in your destruction effects to have them start replicating again, they will still anchor themselves when they stop moving.

	@server
]=]
function Shatterbox.Puppeteer(voxel : Part)
	assert(isServer, "This function can only be called from the server")

	if IsPuppet(voxel) then return end

	voxel.Anchored = false

	voxel.Parent = mapContainer

	local s, e = pcall(voxel.SetNetworkOwner, voxel, nil)
	if not s then
		warn("Failed to set the network owner of the Puppet, is it welded to an anchored part?\n" .. e)
	end

	local noSleepCon : RBXScriptConnection
	noSleepCon = RunService.Heartbeat:Connect(function(deltaTime)
		voxel:ApplyImpulse(Vector3.yAxis * -0.00001)
	end)


	local OldPuppetData = Puppets[PuppetNextIndex]

	if OldPuppetData then
		OldPuppetData[3]:Disconnect()
		OldPuppetData[2](true)
		DestroyPart(OldPuppetData[1])
	end

	table.insert(CreatePuppetQueue, voxel)
	local QueueInsertedIndex = #CreatePuppetQueue
	local PuppetInsertedIndex = PuppetNextIndex

	local PuppetData = {
		voxel,
		function(doNotSignal) -- I know i shouldn't be using an anonymous function, ill change it later
			noSleepCon:Disconnect()

			-- if this server side voxel is queued for client-side creation, remove it from that queue
			local found
			for i = 1, QueueInsertedIndex do
				if CreatePuppetQueue[i] == voxel then found = i break end
			end
			if found then table.remove(CreatePuppetQueue, found) end

			if doNotSignal then return end

			-- signal to the client that the puppet needs to be destroyed and remove it (probably will batch these in the future)

			Puppets[PuppetInsertedIndex] = nil
			PuppetsLerpData[PuppetInsertedIndex] = nil
			ServerEvents.DestroyPuppet.FireAll(PuppetInsertedIndex)
		end
	}

	PuppetData[3] = voxel.Destroying:Once(PuppetData[2])

	PuppetData[4] = 0 -- The sleep anchoring timeout


	Puppets[PuppetInsertedIndex] = PuppetData
	PuppetsLerpData[PuppetInsertedIndex] = {}
	PuppetNextIndex += 1
	if PuppetNextIndex > Settings.PuppetMaxCount then
		PuppetNextIndex = 1
	end
end

--[=[
	Returns true if the passed in part has had [Shatterbox.Puppeteer] called on it before.

	On the client side, this will always be false because the client sided puppets are indestructible.

	@function IsPuppet
	@param voxel Part
	@return boolean
	@within Shatterbox
	@server
]=]
Shatterbox.IsPuppet = IsPuppet


function Shatterbox.FakeClientPuppets(fakePuppets : { Part })
	for _, fake in ipairs(fakePuppets) do
		local OldPuppetData = Puppets[FakePuppetOverrideIndex]
		if OldPuppetData then
			OldPuppetData[1]:Destroy()
			PuppetsLerpData[FakePuppetOverrideIndex] = nil
		end

		Puppets[FakePuppetOverrideIndex] = { fake }

		FakePuppetOverrideIndex += 1
		if FakePuppetOverrideIndex > Settings.PuppetMaxCount then
			FakePuppetOverrideIndex = 1
		end
	end
end


--[=[
	Queues voxel destruction to be performed around the hitbox according to the `params` supplied.

	@param params DestructionParameters | Hitbox
]=]
function Shatterbox.Destroy(params : Types.DestructionParams)
	if ModelQueueBehavior(Shatterbox.Destroy, params) then return end

	local Parameters = ValidateDestructionParams(params)

	if USE_CLIENT_SERVER then
		local _, createdDirtyGroups = GetDestructibleParts(Parameters)

		if isServer then
			ReplicateDestructionToClients(NORMAL, Parameters, createdDirtyGroups)
		else
			SendDirtyGroupsToServer(createdDirtyGroups)
		end
	end

	table.insert(ShatterQueue, Parameters)
end



--[=[
	Instantly performs voxel destruction around the hitbox according to the `params` supplied.

	Returns the imaginary voxels to be created as well as any existing debris encountered.

	These are to be instantiated using [Shatterbox.InstantiateImaginaryVoxel].

	:::warning
	If you use SkipEncapsulatedVoxels, the #length of the imaginary voxels array will show up as larger than it really is.

	This is to give the same functionality as [OnDestructCompleted voxelCount](../Shatterbox#OnDestructCompleted) without the need for a third return value.

	Use `ipairs` or generalized iteration to iterate over this array.
	:::
	@param params DestructionParameters | Hitbox
	@return {ImaginaryVoxel}
	@return {BasePart}
]=]
function Shatterbox.ImaginaryVoxels(params : Types.ImaginaryDestructionParams) : ({Types.ImaginaryVoxel}, {BasePart})

	local did, voxels, existingDebris = ModelQueueBehavior(Shatterbox.ImaginaryVoxels, params)
	if did then return voxels, existingDebris end

	local Parameters = ValidateDestructionParams(params)

	local destructibleParts, createdDirtyGroups, _, affectedIDs = GetDestructibleParts(Parameters)

	if USE_CLIENT_SERVER then
		if isServer then
			ReplicateDestructionToClients(IMAGINARY, Parameters, createdDirtyGroups)
		else
			SendDirtyGroupsToServer(createdDirtyGroups)
		end
	end

	voxels, existingDebris = ImaginaryVoxels(Parameters, destructibleParts, affectedIDs)

	return voxels or {}, existingDebris
end

--[=[
	Returns a created voxel using the supplied `ImaginaryVoxel`.

	Will automatically parent the voxel to the original parent of the group.

	Will also automatically give the voxel the `"ShatterboxDebris"` tag unless you pass in `doNotGiveDebrisTag`.

	:::tip
	You would want to pass in `doNotGiveDebrisTag` if you're going to use the static function [Shatterbox.OnVoxelDestruct] to use/extend an existing effect.
	:::
	@param ImaginaryVoxel ImaginaryVoxel
	@param doNotGiveDebrisTag boolean?
]=]
function Shatterbox.InstantiateImaginaryVoxel(ImaginaryVoxel : Types.ImaginaryVoxel, doNotGiveDebrisTag : boolean?) : Part
	local DirtyGroupID = ImaginaryVoxel.DirtyGroupID

	local voxel = InstantiatePart(DirtyGroupID, ImaginaryVoxel.CFrame, ImaginaryVoxel.Size)

	if not doNotGiveDebrisTag then voxel:AddTag(DebrisTag) end

	voxel.Destroying:Once(function()
		local members = DirtyGroupMembers[DirtyGroupID]
		if not members then return end
		members[voxel] = nil
	end)

	voxel.Parent = DirtyGroupData[DirtyGroupID].OriginalParent

	return voxel
end


--[=[
	Resets an area. Currently only supports Box shaped areas.

	Does not revert the ownership of parts with Client-Server enabled.

	@param area Part|ImaginaryPart
]=]
function Shatterbox.ResetArea(area : Part | Types.WorldInfo)

	local ACF, AS = area.CFrame, area.Size
	if isServer then ServerEvents.SignalResetArea.FireAll(ACF, AS) end

	local AreaVerts = VertexMath.GetVerts.Block(ACF, AS)
	local AreaNormals = VertexMath.GetNormals.Block(ACF)

	-- Check all of the dirty groups to see if any of them intersect the area
	for DirtyGroupID, groupData in pairs(DirtyGroupData) do

		-- intersection test between the area and the original part that was destroyed (the original part can be of any shape for future compatibility)
		local originalPart = groupData.OriginalPart
		local cpcf, cps, cpsh = originalPart.CFrame, originalPart.Size, originalPart.Shape.Name
		local iBl, iBa, iC = cpsh == "Block", cpsh == "Ball", cpsh == "Cylinder"

		local intersectingVerts, intersectingNormals
		if iBl or iC then
			intersectingVerts = BlockVerts(cpcf, cps)
			intersectingNormals = BlockNormals(cpcf)
		elseif not iBa then
			intersectingVerts = GetVerts[cpsh](cpcf, cps)
			intersectingNormals = GetNormals[cpsh](cpcf, cps)
		end

		local intersected = PartContainsAVert(originalPart, AreaVerts)
		if not intersected then
			if iBa then
				intersected = VertexMath.BallIntersectsBlock(cpcf, cps, ACF, AS)
			elseif iC then
				intersected = VertexMath.CylinderIntersectsBlock(cpcf, cps, intersectingVerts, intersectingNormals, ACF, AS, AreaVerts, AreaNormals)
			else
				intersected = VertexMath.SAT(intersectingVerts, intersectingNormals, AreaVerts, AreaNormals)
			end
		end

		if intersected then UndoDirtyGroup(DirtyGroupID) end
	end
end


--[=[
	Resets all modified parts and re-allocates system queues/maps.

	If `doNotRevertOwnership` is `true` with Client-Server enabled, the clients do not delete their owned map parts.

	@function Reset
	@param doNotRevertOwnership boolean?
	@within Shatterbox
]=]
function Shatterbox.Reset(doNotRevertOwnership : boolean?, replicated)
	-- stop all queued destructions
	ShatterQueue = {}

	SmoothCleanupQueue = {}

	GreedyMeshingQueue = {}

	if isServer then
		for _, puppetData in pairs(Puppets) do
			puppetData[3]:Disconnect()
			puppetData[2](true)
			DestroyPart(puppetData[1])
		end

		ServerEvents.SignalReset.FireAll(doNotRevertOwnership)
	else
		for _, puppetData in pairs(Puppets) do
			puppetData[1]:Destroy()
		end
	end

	Puppets = {}
	PuppetsLerpData = {}
	PuppetNextReplicationIndex = 1
	CreatePuppetQueue = {}
	PuppetNextIndex = 1

	if doNotRevertOwnership and USE_CLIENT_SERVER then
		-- every operation is undone if the ownership is not meant to be reverted
		for DirtyGroupID in pairs(DirtyGroupData) do UndoDirtyGroup(DirtyGroupID) end
	else
		for DirtyGroupID, groupData in pairs(DirtyGroupData) do
			local OriginalPart = groupData.OriginalPart
			if replicated then
				OriginalPart:Destroy()
			else
				-- clear the dirty group information
				OriginalPart:SetAttribute(DirtyGroupIDAttribute)
				-- put the original part back where it was before Shatterbox touched it
				OriginalPart.Parent = groupData.OriginalParent
			end
			-- destroy all members of the dirty group
			for member in pairs(DirtyGroupMembers[DirtyGroupID]) do member:Destroy() end
		end

		DirtyGroupData = {}
		DirtyGroupMembers = {}
	end
end


-- Cancels any ongoing operations
function Shatterbox.ClearQueue()
	ShatterQueue = {}

	if isServer then ServerEvents.SignalClearQueue.FireAll() end
end


--[=[
	@class Hitbox

	Helper class which represents a virtual hitbox. Contains all [destruction parameters](../DestructionParameters) as well as some unique parameters.
]=]
local HitboxMT = setmetatable({}, DestructionParamsMT)
HitboxMT.__index = HitboxMT

--[=[
	The delay in seconds between destructions when using [Hitbox:Start]

	@prop DestructDelay number?
	@within Hitbox
]=]
HitboxMT.DestructDelay = nil :: number?

--[=[
	Determines what kind of destruction is performed while using [Hitbox:Start].

	If set to "IMAGINARY", then [Hitbox.ImaginaryCallback] is used to give you the imaginary voxels and existing debris.

	@prop DestructionType "DEFAULT"|"IMAGINARY"
	@within Hitbox
]=]
HitboxMT.DestructionType = "DEFAULT" :: ("DEFAULT"|"IMAGINARY")

--[=[
	A callback that runs if [Hitbox.DestructionType] is set to `"IMAGINARY"` while using [Hitbox:Start].

	It supplies you the imaginary voxels and any existing debris.

	@prop ImaginaryCallback ( (imaginaryVoxels : {ImaginaryVoxel}, existingDebris : {BasePart}) -> () )?
	@within Hitbox
]=]
HitboxMT.ImaginaryCallback = nil :: ( (imaginaryVoxels : {Types.ImaginaryVoxel}, existingDebris : {BasePart}) -> () )?

--[=[
	Polling event for [Hitbox:Start].

	@prop StartConnectionEvent RBXScriptSignal
	@within Hitbox
]=]
HitboxMT.StartConnectionEvent = RunService.Heartbeat :: RBXScriptSignal-- the event that the hitbox connects to when using Start(), needs to have a deltaTime parameter

--[=[
	Polling event for [Hitbox:WeldTo].

	@prop WeldConnectionEvent RBXScriptSignal
	@within Hitbox
]=]
HitboxMT.WeldConnectionEvent = RunService.PostSimulation :: RBXScriptSignal -- the event that the hitbox connects to when using WeldTo()

--[=[
	Whether or not to predict the velocity of the part the hitbox is welded to.

	Only works if the hitbox is welded to a BasePart using [Hitbox:WeldTo].

	@prop VelocityPrediction boolean
	@within Hitbox
]=]
HitboxMT.VelocityPrediction = false :: boolean

--[=[
	How many frames ahead to predict when using [Hitbox.VelocityPrediction].

	@prop VelocityBias number
	@within Hitbox
]=]
HitboxMT.VelocityBias = 1 :: number

--[=[
	Equivalent to [Shatterbox.Destroy(Hitbox)](../Shatterbox#Destroy).

	Clears [Hitbox.ExcludePlayersReplication](../DestructionParameters#ExcludePlayersReplication).

	@within Hitbox
]=]
function HitboxMT:Destroy()
	Shatterbox.Destroy(self)
	self.ExcludePlayersReplication = {} -- QOL automatically clear the exlcusion after the destruction is performed
end

--[=[
	Equivalent to [Shatterbox.ImaginaryVoxels(Hitbox)](../Shatterbox#ImaginaryVoxels).

	Clears [Hitbox.ExcludePlayersReplication](../DestructionParameters#ExcludePlayersReplication).

	@return {ImaginaryVoxel}
	@return {BasePart}

	@within Hitbox
]=]
function HitboxMT:ImaginaryVoxels() : ({Types.ImaginaryVoxel}, {BasePart})
	local voxels, existingDebris = Shatterbox.ImaginaryVoxels(self)
	self.ExcludePlayersReplication = {} -- QOL automatically clear the exlcusion after the destruction is performed
	return voxels, existingDebris
end

--[=[
	Will "weld" the hitbox to the given part, setting `Hitbox.CFrame` to be equal to `Part.CFrame` whenever [Hitbox.WeldConnectionEvent] fires.

	If `Part` is destroyed using `Instance:Destroy()`, the hitbox will automatically call [Hitbox:DestroyHitbox]

	If `workspace.PlayerCharacterDestroyBehavior` is false, the hitbox *will not* be automatically stopped when that Player respawns if you have welded to their root part.

	@within Hitbox
]=]
function HitboxMT:WeldTo(Part : BasePart)
	if self.wcon then self.wcon:Disconnect() end
	if self.dcon then self.dcon:Disconnect() end
	self.CFrame = Part.CFrame
	self.wcon = self.WeldConnectionEvent:Connect(function(deltaTime)
		if self.VelocityPrediction then
			self.CFrame = Part.CFrame + Part.AssemblyLinearVelocity * self.VelocityBias * deltaTime
		else
			self.CFrame = Part.CFrame
		end
	end)
	self.dcon = Part.Destroying:Once(self.DestroyHitbox)
end

--[=[
	Will "unweld" the hitbox if it has been welded after using [Hitbox:WeldTo].

	@within Hitbox
]=]
function HitboxMT:Unweld()
	if self.wcon then self.wcon:Disconnect() end
	if self.dcon then self.dcon:Disconnect() end
	self.wcon, self.dcon = nil, nil
end

--[=[
	Will start to cut around the hitbox every [Hitbox.DestructDelay] seconds, which defaults to 0 (every frame).

	The hitbox updates every time the [Hitbox.StartConnectionEvent] fires, which is expected to supply a `deltaTime` parameter.

	If [Hitbox.DestructionType] is set to `"IMAGINARY"`, then [Hitbox.ImaginaryCallback] is used to give you the imaginary voxels and existing debris.

	@within Hitbox
]=]
function HitboxMT:Start()
	if self.ccon then return end
	self.ccon = self.StartConnectionEvent:Connect(function()
		if self.DestructDelay then
			local t = time()
			if self.lastCut and t - self.lastCut < self.DestructDelay then return end
			self.lastCut = t
		end

		if self.DestructionType == "DEFAULT" then
			self:Destroy()
		else
			local voxels, existingDebris = self:ImaginaryVoxels()
			if self.ImaginaryCallback then
				self.ImaginaryCallback(voxels, existingDebris)
			end
		end
	end)
end

--[=[
	Will stop cutting around the hitbox if the hitbox is active after using [Hitbox:Start].

	@within Hitbox
]=]
function HitboxMT:Stop()
	if self.ccon then self.ccon:Disconnect() end
	self.ccon = nil
end

--[=[
	Will call [Hitbox:Unweld] and then [Hitbox:Stop].

	Calling each individually is equivalent to calling this function.

	@within Hitbox
]=]
function HitboxMT:DestroyHitbox()
	self:Unweld()
	self:Stop()
end



--[=[
	Creates a Hitbox object which can be used in place of the destruction functions, and has additional functionality. (like VoxBreaker moveable hitbox)

	If you use ExcludePlayersReplication, that will be cleared after every destruction automatically, for convenience.

	@return Hitbox
]=]
function Shatterbox.CreateHitbox()

	local hitbox = setmetatable({}, HitboxMT)

	hitbox.UserData = {}

	return hitbox
end


--[=[
	Returns the original part that is associated with this DirtyGroupID.

	This part is never destroyed, just has its parent set to `nil`.
]=]
function Shatterbox.GetOriginalPart(DirtyGroupID : string) : BasePart
	local groupData = DirtyGroupData[DirtyGroupID]
	if not groupData then return nil end
	return groupData.OriginalPart
end


--[=[
	Takes a `point` and converts it to the voxel space distance relative to `voxel`.

	This is a vector which tells you how many voxels away `point` is on each local axis, as fractional quantities.

	It is possible for an axis to be less than one, but never negative.

	:::tip
	See `Shatterbox/effects/Server/MappingVoxelSpace` for an example on how to use VoxelDistanceVector
	:::
	@param voxel Part|ImaginaryPart
	@param point Vector3
]=]
function Shatterbox.VoxelDistanceVector(voxel : Part|Types.ImaginaryBox, point : Vector3) : Vector3
	return voxel.CFrame:PointToObjectSpace(point):Abs() / voxel.Size
end


--[=[
	Returns a vector that tells you how many voxels (relative to `voxel`) a box determined by `boxSize` has on each local axis, as fractional quantities.

	It is *not* possible for an axis to be less than one, because there is always at least one voxel on every axis.

	:::tip
	See `Shatterbox/effects/Server/MappingVoxelSpace` for an example on how to use VoxelCountVector
	:::
	@param voxel Part|ImaginaryPart
	@param boxSize Vector3
]=]
function Shatterbox.VoxelCountVector(voxel : Part|Types.ImaginaryBox, boxSize : Vector3) : Vector3
	return Vector3.one:Max(boxSize / voxel.Size)
end


--[=[
	Will register the given callback to the given name.

	If you call this function on the server side, you are creating a server-side effect. Vice-versa for registering on the client side.

	Consider using `Shatterbox/effects` modules for effect definitions.

	:::warning
	Register any given effect only once, you are free to use it by name in scripts other than the one it is defined in.
	:::

	@param name string
	@param callback OnVoxelDestructType
]=]
function Shatterbox.RegisterOnVoxelDestruct(name : string, callback : Types.OnVoxelDestruct)
	assert(typeof(name) == "string", "You must register the OnVoxelDestruct callback with a string as the name")
	local id = name:lower()
	assert(not rawget(OnVoxelDestructRegistry, id), `Callback with name {id} already exists in the registry`)
	OnVoxelDestructRegistry[id] = callback
end


Shatterbox.Voxelize = Voxelize

--[=[
	A function to manually call a registered OnVoxelDestruct effect.

	:::tip
	This can be used as a way to constructively build on top of any existing effects, saving you time.

	#### Example
	```lua
	-- BumpyFloorBreakWalls but it makes every voxel black
	Shatterbox.RegisterOnVoxelDestruct("ExtendingAnEffect", function(voxel, info)
		voxel.Color = Color3.new()
		Shatterbox.OnVoxelDestruct("BumpyFloorBreakWalls", voxel, info)
	end)
	```
	:::

	@function OnVoxelDestruct
	@param name string
	@param voxel Part
	@param info VoxelInfo
	@within Shatterbox
]=]
Shatterbox.OnVoxelDestruct = HandleVoxelDestruction

Shatterbox.VertexMath = VertexMath





-- Debug function to print the state of local variables
local function PrintState()
	local P, str = "\n|\n| ", nil

	print(P .. `SHATTERBOX ({isServer and "SERVER" or "CLIENT"})`)

	print(P .. "ShatterQueue length: " .. #ShatterQueue)

	str = P .. "SmoothCleanupQueue: {"
	for DirtyGroupID, countdown in pairs(SmoothCleanupQueue) do
		str = str..P.. "  [" .. DirtyGroupID .. "] = " .. countdown
	end
	str = str..P.. "}"
	print(str)

	str = P .. "DirtyGroupMembers length: {"
	for DirtyGroupID, members in pairs(DirtyGroupMembers) do
		--if not next(members) then continue end
		local count = 0
		for _ in pairs(members) do count += 1 end
		str = str..P.. "  [" .. DirtyGroupID .. "] = " .. count
	end
	str = str..P.. "}"
	print(str)


	--print("Instanced: " .. ci)
	--print("Destroyed: " .. cd)

	str = P .. "GreedyMeshingQueue: {"
	for DirtyGroupID, GridSize in pairs(GreedyMeshingQueue) do
		str = str..P.. "  " .. DirtyGroupID .. ": " .. GridSize
	end
	str = str..P.. "}"
	print(str)
end

function Shatterbox.PrintState()

	if isServer then ServerEvents.SignalPrintState.FireAll() end

	PrintState()
end



-- Create connections

RunService.Heartbeat:Connect(HeartbeatWorker)

if isServer then

	if USE_CLIENT_SERVER then
		ServerEvents.ClientInitComplete.On(QueueNewPlayerStateReplication)

		ServerEvents.CreateDirtyGroupsFromClient.On(CreateDirtyGroupsFromClient)
	end

elseif isClient then

	if USE_CLIENT_SERVER then
		ClientEvents.ReplicateState.On(ReplicateStateFromServer)

		ClientEvents.ReplicateDestruction.On(function(destructionType, serialParams, serialNewDirtyGroups)
			if not clientInitComplete then return end
			ReplicateDestructionFromServer(destructionType, serialParams, serialNewDirtyGroups)
		end)

		ClientEvents.CreateDirtyGroupsFromServer.On(function(SerialDirtyGroups)
			if not clientInitComplete then return end
			CreateSerialDirtyGroups(SerialDirtyGroups)
		end)

		ClientEvents.ClientInitComplete.Fire()
	end

	ClientEvents.SignalClearQueue.On(function()
		if USE_CLIENT_SERVER and not clientInitComplete then return end
		Shatterbox.ClearQueue()
	end)
	ClientEvents.SignalReset.On(function(doNotRevertOwnership)
		if USE_CLIENT_SERVER and not clientInitComplete then return end
		Shatterbox.Reset(doNotRevertOwnership, true)
	end)
	ClientEvents.SignalResetArea.On(function(cframe, size)
		if USE_CLIENT_SERVER and not clientInitComplete then return end
		Shatterbox.ResetArea({ CFrame = cframe, Size = size })
	end)

	ClientEvents.CreatePuppets.On(function(serialPuppets)
		if USE_CLIENT_SERVER and not clientInitComplete then return end
		CreatePuppets(serialPuppets)
	end)
	ClientEvents.ReplicatePuppetStates.On(function(puppetStates, stepDelta)
		if USE_CLIENT_SERVER and not clientInitComplete then return end
		ReplicatePuppetStates(puppetStates, stepDelta)
	end)
	ClientEvents.DestroyPuppet.On(function(index)
		if USE_CLIENT_SERVER and not clientInitComplete then return end
		DestroyPuppet(index)
	end)

	ClientEvents.SignalPrintState.On(PrintState)
end

return Shatterbox