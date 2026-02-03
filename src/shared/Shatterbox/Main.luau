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


local Shatterbox = {}

local OnVoxelDestructRegistry = setmetatable({}, {
	__index = function(tbl, k) return (k and rawget(tbl, k:lower())) end -- or rawget(tbl, "default") end
}) :: { [string] : Types.OnVoxelDestruct }

local ClientEvents, ServerEvents, mapContainer
if isServer then
	ServerEvents = require(PathToServer).Shatterbox

	mapContainer = workspace.CurrentCamera

	local serverEffects = require(src.effects.Server)
	serverEffects:SetReference(Shatterbox)
	serverEffects.SetReference = nil
	for name, func in pairs(serverEffects) do OnVoxelDestructRegistry[name:lower()] = func end
elseif isClient then
	ClientEvents = require(PathToClient).Shatterbox

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

-- Ongoing operations array
local ShatterQueue = {} :: { Types.DestructionParams }
-- Dirty groups involved in ongoing operations map [DirtyGroupID] : { [DestructionID] : boolean }
local CountOperationsProcessing = {} :: { [string] : { [string] : boolean } }
-- Dirty groups affected by an ongoing operation map [DestructionID] : { [DirtyGroupID] : boolean }
local OperationAffectedDirtyGroups = {} :: { [string] : { [string] : boolean } }
-- Voxels blacklisted by an ongoing operation (one destruction cannot re-destroy a voxel that it created)
local OperationBlacklistedVoxels = {} :: { [Part] : boolean }
-- Falling groups being processed by an ongoing operation [DestructionID] : { [FallingGroupID] : boolean }
local OperationAffectedFallingGroups = {} :: { [string] : { [string] : boolean }}

-- Dirty groups waiting to be greedy meshed [DirtyGroupID] : GridSize
local GreedyMeshingQueue = {} :: { [string] : number }
local GreedyWorkers = {} :: { [string] : thread }
local GreedyWorkersTerminationFlags = {} :: { [string] : boolean }
local ActiveGMWorkerCount = 0
local ActiveGMWorkerGridSize = {} :: { [string] : number }

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


-- Flags a dirty group for GreedyMeshing processing
local function QueueGreedyMeshing(DirtyGroupID : string, GridSize : number)

	-- If this group is already being meshed, schedule termination for the coroutine
	if GreedyWorkers[DirtyGroupID] then GreedyWorkersTerminationFlags[DirtyGroupID] = true end

	-- If this group was already flagged for greedy meshing, take the minimum of the grid sizes (for a higher level of compatibility)
	local previousGridSize = GreedyMeshingQueue[DirtyGroupID]
	GreedyMeshingQueue[DirtyGroupID] = previousGridSize and math.min(GridSize, previousGridSize) or GridSize
end

local function InitGreedyState(part, GridSize, groupMin, State, DIMYDIMZ, DIMZ)

	local minCFrame, _, S, _, _, _, NVX, NVY, NVZ = GridInfo(part.CFrame:Orthonormalize(), part.Size, GridSize)

	if not minCFrame.Rotation:FuzzyEq(groupMin.Rotation, EPSILON) then
		return 0
	end

	local off = minCFrame.Position - groupMin.Position

	local ODX, ODY, ODZ = off:Dot(groupMin.XVector) / S.X,
					      off:Dot(groupMin.YVector) / S.Y,
					      off:Dot(groupMin.ZVector) / S.Z
	local DX, DY, DZ = math.floor(ODX + 0.5),
					   math.floor(ODY + 0.5),
					   math.floor(ODZ + 0.5)

	if math.abs(DX - ODX) > EPSILON or math.abs(DY - ODY) > EPSILON or math.abs(DZ - ODZ) > EPSILON then
		return 0
	end

	DX -= 1
	DY -= 1

	local traversed = 0
	-- Initialize the 3d state volume
	for X = 1, NVX do
		local dixz = (X + DX)*DIMYDIMZ + DZ
		for Y = 1, NVY do
			local di = dixz + (Y + DY)*DIMZ
			for Z = 1, NVZ do
				if traversed == Settings.GMTraversalsPerFrame then
					coroutine.yield()
					traversed = 0
				end

				State[di + Z] = true

				traversed += 1
			end
		end
	end

	DX += 1
	DY += 1

	return {1 + DX, 1 + DY, 1 + DZ, DX + NVX, DY + NVY, DZ + NVZ}, NVX * NVY * NVZ
end

-- coroutine based greedy meshing with smooth display of results
local function GreedyMeshWorker(DirtyGroupID : string, GridSize : number?)

	local dirtyGroupData = DirtyGroupData[DirtyGroupID]
	local dirtyGroupMembers = DirtyGroupMembers[DirtyGroupID]

	local Original = dirtyGroupData.OriginalPart

	-- The bounding area of Greedy Meshing, defined by the original part before it was ever destroyed
	local groupMin, _, VoxelSize, _, _, _, DIMX, DIMY, DIMZ = GridInfo(Original.CFrame, Original.Size, GridSize)
	local DIMYDIMZ = DIMY*DIMZ
	local VSX, VSY, VSZ = VoxelSize.X, VoxelSize.Y, VoxelSize.Z

	-- flat 3d state/visited array : index = (X - 1)*DIMYDIMZ + (Y - 1)*DIMZ + Z
	local State, Visited = {}, {}

	-- information about the original parts, used for smoothly displaying the output of greedy meshing
	local OriginalPartsInfo = {} :: {
		{
			Part : Part,
			PartGridInfo : {any},
			Contributed : {number}
		}
	}

	-- the total number of voxels in the State array
	local count = 0

	for member in pairs(dirtyGroupMembers) do
		if member:HasTag(DebrisTag) then continue end

		local gridInfo, n = InitGreedyState(member, GridSize, groupMin, State, DIMYDIMZ, DIMZ)
		if n > 0 then
			count += n

			table.insert(OriginalPartsInfo, {
				Part = member,
				PartGridInfo = gridInfo,

				Contributed = {}
			})
		end
	end

	local meshed = {}

	local traversed = 0

	local sx, sy, sz = 1, 1, 1
	while count > 0 do
		local X, Y, Z = sx, sy, sz
		local iyz = (Y - 1)*DIMZ + Z
		local si = (X - 1)*DIMYDIMZ + iyz
		-- find first unvisited and active state position
		while Visited[si] or not State[si] do
			if traversed == Settings.GMTraversalsPerFrame then
				coroutine.yield()
				traversed = 0
			end

			if X < DIMX then
				X += 1
			else
				X = 1
				if Y < DIMY then
					Y += 1
				else
					Y = 1
					if Z < DIMZ then
						Z += 1
					else
						Z = 1
					end
				end
				iyz = (Y - 1)*DIMZ + Z
			end

			traversed += 1
			si = (X - 1)*DIMYDIMZ + iyz
		end
		sx, sy, sz = X, Y, Z

		Visited[si] = true

		-- planar expansion along X axis
		while X < DIMX do
			local DX = X + 1

			if traversed == Settings.GMTraversalsPerFrame then
				coroutine.yield()
				traversed = 0
			end

			local index = (DX - 1)*DIMYDIMZ + (Y - 1)*DIMZ + Z
			if Visited[index] or not State[index] then break end

			Visited[index] = true
			traversed += 1

			X = DX
		end

		-- planar expansion along Y axis
		while Y < DIMY do
			local DY = Y + 1
			local iyz = (DY - 1)*DIMZ + Z
			local breakExpansion = false

			local indices = {}

			for ix = sx, X do
				if traversed == Settings.GMTraversalsPerFrame then
					coroutine.yield()
					traversed = 0
				end

				local index = (ix - 1)*DIMYDIMZ + iyz
				if Visited[index] or not State[index] then
					breakExpansion = true
					break
				end

				indices[index] = true
				traversed += 1
			end

			if breakExpansion then break end

			for index in pairs(indices) do
				Visited[index] = true
			end

			Y = DY
		end

		-- planar expansion along Z axis
		while Z < DIMZ do
			local DZ = Z + 1
			local breakExpansion = false

			local indices = {}

			for ix = sx, X do
				local ixz = (ix - 1)*DIMYDIMZ + DZ
				for iy = sy, Y do
					if traversed == Settings.GMTraversalsPerFrame then
						coroutine.yield()
						traversed = 0
					end

					local index = ixz + (iy - 1)*DIMZ
					if Visited[index] or not State[index] then
						breakExpansion = true
						break
					end

					indices[index] = true
					traversed += 1
				end

				if breakExpansion then break end
			end

			if breakExpansion then break end

			for index in pairs(indices) do
				Visited[index] = true
			end

			Z = DZ
		end

		-- the number of voxels in the meshed span on every axis
		local NX, NY, NZ = X - sx + 1, Y - sy + 1, Z - sz + 1
		-- subtract the total number of voxels in the meshed span
		count -= NX * NY * NZ

		-- define a cuboid using the start and end positions.
		table.insert(meshed, {
			CFrame = ( groupMin + groupMin.XVector*VSX*((X + sx)*0.5 - 1) + groupMin.YVector*VSY*((Y + sy)*0.5 - 1) + groupMin.ZVector*VSZ*((Z + sz)*0.5 - 1) ):Orthonormalize(),
			Size = VoxelSize * Vector3.new(NX, NY, NZ),

			Contributed = {},

			MINX = sx,
			MINY = sy,
			MINZ = sz,

			MAXX = X,
			MAXY = Y,
			MAXZ = Z
		})
	end

	-- process voxel count contributions (for smooth display of greedy meshing)
	for meshedIndex, MI in ipairs(meshed) do
		local contributedToMeshed, MINX, MINY, MINZ, MAXX, MAXY, MAXZ = MI.Contributed, MI.MINX, MI.MINY, MI.MINZ, MI.MAXX, MI.MAXY, MI.MAXZ

		for i, partInfo in ipairs(OriginalPartsInfo) do
			local PMINX, PMINY, PMINZ, PMAXX, PMAXY, PMAXZ = unpack(partInfo.PartGridInfo)

			-- SAT test in voxel coordinate space??
			if math.max(PMINX, MINX) > math.min(PMAXX, MAXX) or math.max(PMINY, MINY) > math.min(PMAXY, MAXY) or math.max(PMINZ, MINZ) > math.min(PMAXZ, MAXZ) then continue end

			table.insert(contributedToMeshed, i)
			table.insert(partInfo.Contributed, meshedIndex)
		end
	end

	local InstancedMeshIDs, numInstanced, numMeshed = {}, 0, #meshed

	count = 0

	-- Expertly performing dual DFS for smooth display of meshing (visual groups are instantiated one by one)
	while numInstanced < numMeshed do
		if count >= Settings.GMPartCreationsPerFrame then
			coroutine.yield()
			count = 0
		end

		local startIndex
		for i, meshedInfo in ipairs(meshed) do
			if InstancedMeshIDs[i] then continue end
			if #meshedInfo.Contributed == 1 then -- do not re-create parts that didn't change
				InstancedMeshIDs[i] = true
				numInstanced += 1
				continue
			end
			startIndex = i
			break
		end

		local visitedOriginals, visitedMeshed, pathStack = {}, { [startIndex] = true }, {startIndex}

		while #pathStack > 0 do
			local mi = table.remove(pathStack)
			local meshedInfo = meshed[mi]

			for _, io in ipairs(meshedInfo.Contributed) do
				if visitedOriginals[io] then continue end
				visitedOriginals[io] = true

				local partInfo = OriginalPartsInfo[io]

				for _, im in ipairs(partInfo.Contributed) do
					if visitedMeshed[im] then continue end
					visitedMeshed[im] = true

					table.insert(pathStack, im)
				end
			end
		end

		for meshedID in pairs(visitedMeshed) do
			InstancedMeshIDs[meshedID] = true
			numInstanced += 1

			local meshedInfo = meshed[meshedID]

			InstantiatePart(DirtyGroupID, meshedInfo.CFrame, meshedInfo.Size)

			count += 1
		end

		--[[
		if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then
			for originalID in pairs(visitedOriginals) do
				CachedParts:ReturnPart(OriginalPartsInfo[originalID].Part)
			end
		else--]]
			for originalID in pairs(visitedOriginals) do
				DestroyPart(OriginalPartsInfo[originalID].Part)
			end
		--end
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
local function ModelQueueBehavior(funcToUse, intersectingPart, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, UserData, ExcludePlayersReplication, SkipFloors, SkipWalls)
	local cuttingPart = if typeof(intersectingPart) == "table" then intersectingPart.CuttingPart else intersectingPart
	local retA, retB = {}, {}
	if cuttingPart and typeof(cuttingPart) == "Instance" and cuttingPart:IsA("Model") then
		for _, desc in ipairs(cuttingPart:GetDescendants()) do
			if not desc:IsA("Part") then continue end
			local rA, rB = funcToUse(desc, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, UserData, ExcludePlayersReplication, SkipFloors, SkipWalls)
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

-- Validates destruction parameters
local function ValidateDestructionParams(intersectingPart : Part | Model | Types.WorldInfo | Types.DestructionParams | Types.ImaginaryDestructionParams, FilterTagged : (string | {string})?, CleanupDelay : number?, OnVoxelDestruct : string?, GridSize : number?, SkipEncapsulatedVoxels : boolean?, OnDestructCompleted : (() -> ())?, UserData : {any}?, ExcludePlayersReplication : (Player | {Player})?, SkipFloors : boolean?, SkipWalls : boolean?)

	local CuttingPart = {} :: Types.Hitbox
	local params = {} :: Types.InternalDestructionParams | Types.InternalImaginaryParams
	local tbl = {} :: Types.DestructionParams | Types.ImaginaryDestructionParams

	if typeof(intersectingPart) == "table" then
		tbl = intersectingPart
		if tbl.CuttingPart then
			local cp = tbl.CuttingPart
			if typeof(cp) == "table" or (typeof(cp) == "Instance" and cp:IsA("Part")) then
				assert(cp.CFrame and cp.Size and cp.Shape, "You must provide a CFrame, Size, and Shape for the '{ CuttingPart : { CFrame : CFrame, Size : Vector3, Shape : Enum.PartType } }' syntax.")
				CuttingPart.CFrame = cp.CFrame
				CuttingPart.Size = cp.Size
				CuttingPart.Shape = cp.Shape
			end
		else
			assert(tbl.CFrame and tbl.Size and tbl.Shape, "You must provide a CFrame, Size, and Shape for the '{ CFrame : CFrame, Size : Vector3, Shape : Enum.PartType }' syntax.")
			CuttingPart.CFrame = tbl.CFrame
			CuttingPart.Size = tbl.Size
			CuttingPart.Shape = tbl.Shape
		end
	elseif intersectingPart:IsA("Part") then
		CuttingPart.CFrame = intersectingPart.CFrame
		CuttingPart.Size = intersectingPart.Size
		CuttingPart.Shape = intersectingPart.Shape
	end

	local filterTagged = tbl.FilterTagged or FilterTagged
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

	local playerExclusions = tbl.ExcludePlayersReplication or ExcludePlayersReplication
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
				 params.CleanupDelay = tbl.CleanupDelay		         or CleanupDelay or Settings.DefaultSmoothCleanupDelay
			  params.OnVoxelDestruct = tbl.OnVoxelDestruct 	         or OnVoxelDestruct
					 params.GridSize = tbl.GridSize 			     or GridSize
	   params.SkipEncapsulatedVoxels = tbl.SkipEncapsulatedVoxels    or SkipEncapsulatedVoxels
				   params.SkipFloors = tbl.SkipFloors 				 or SkipFloors
				    params.SkipWalls = tbl.SkipWalls 				 or SkipWalls
		  params.OnDestructCompleted = tbl.OnDestructCompleted       or OnDestructCompleted
					 params.UserData = tbl.UserData    		         or UserData or {}
	params.ExcludePlayersReplication = playerExclusions or {}
		                   params.ID = tbl.ID 					     or HttpService:GenerateGUID(false)

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

	-- schedule greedy meshing termination if it is happening for this dirty group
	if Settings.UseGreedyMeshing and GreedyWorkers[DirtyGroupID] then
		GreedyWorkersTerminationFlags[DirtyGroupID] = true
		repeat RunService.Heartbeat:Wait() until not GreedyWorkers[DirtyGroupID]
	end

	local OriginalPart = groupData.OriginalPart
	if not USE_CLIENT_SERVER or not OriginalPart:IsA("Part") or OriginalPart.Shape ~= Enum.PartType.Block then
		OriginalPart.Parent = groupData.OriginalParent
	else
		OriginalPart.Parent = mapContainer
	end

	for member in pairs(groupMembers) do DestroyPart(member) end
	DirtyGroupMembers[DirtyGroupID] = {}
end


local function PopulateDirtyGroup(Part : Part, DirtyGroupID : string?)
	-- populate the initial dirty group information if there is no group associated with this part
	DirtyGroupID = DirtyGroupID or HttpService:GenerateGUID(false)
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

	local GridSize = Part:GetAttribute("GridSize")

	local PartDirtyGroupID = Part:GetAttribute(DirtyGroupIDAttribute)

	local CreatedFallingGroupID
	local fallingGroupContainer = FindFirstAncestorGroupWithTag(Part, FallingGroupTag)

	local PartIsDivisible = Part:IsA("Part") and Part.Shape == Enum.PartType.Block
	local NonDivisibleInteraction = Settings.NonDivisibleInteraction

	if not Part:GetAttribute(FallingGroupIDAttribute) and fallingGroupContainer then

		CreatedFallingGroupID = HttpService:GenerateGUID(false)
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
		PartDirtyGroupID = PopulateDirtyGroup(Part, nil)

		if PartIsDivisible then
			CreatedDirtyGroups[PartDirtyGroupID] = true
		end
	end

	if PartDirtyGroupID then
		VisitedDirtyGroups[PartDirtyGroupID] = true
		if Settings.UseGreedyMeshing and not Part:GetAttribute(FallingGroupIDAttribute) and Part:IsA("Part") and Part.Shape == Enum.PartType.Block then
			QueueGreedyMeshing(PartDirtyGroupID, GridSize or destructionParams.GridSize or Settings.DefaultGridSize)
		end
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

	local skipFloors, skipWalls = destructionParams.SkipFloors, destructionParams.SkipWalls
	local skipFloorsOrWalls = skipFloors or skipWalls

	local partsInPart, createdDirtyGroups, createdFallingGroups = {}, {}, {}

	IntersectingPart.CFrame = cuttingPart.CFrame
	IntersectingPart.Size = cuttingPart.Size
	IntersectingPart.Shape = cuttingPart.Shape

	local AffectedFallingGroups = OperationAffectedFallingGroups[destructionParams.ID] or {}

	for _, part in ipairs( workspace:GetPartsInPart(IntersectingPart, destructionParams.FilterTagged and OverlapParamsOfTagged(destructionParams.FilterTagged)) ) do

		if (replicated and not part:IsDescendantOf(mapContainer)) or ShouldSkipInstance(part) then continue end

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

		if fallingGroupID then createdFallingGroups[fallingGroupID] = true end

		fallingGroupID = part:GetAttribute(FallingGroupIDAttribute)
		if fallingGroupID then
			AffectedFallingGroups[fallingGroupID] = true
		end

		if part:IsA("Part") and part.Shape == Enum.PartType.Block then
			table.insert(partsInPart, part)
		end
	end

	if USE_CLIENT_SERVER and not replicated and isClient then
		local ToSendToServer = {}
		for DirtyGroupID in pairs(createdDirtyGroups) do
			local groupData = DirtyGroupData[DirtyGroupID]
			local PartToSend = groupData.OriginalPart
			ToSendToServer[DirtyGroupID] = PartToSend
			PartToSend.Parent = nil
			groupData.OriginalPart = PartFromTemplate(PartToSend, PartToSend.CFrame)
			groupData.OriginalPart.Parent = mapContainer
		end
		ClientEvents.CreateDirtyGroupsFromClient.Fire(ToSendToServer)
	end

	OperationAffectedFallingGroups[destructionParams.ID] = AffectedFallingGroups

	return partsInPart, createdDirtyGroups, createdFallingGroups
end


--Performs voxel destruction according to the parameters, returning an array of un-created voxels as well as any existing debris as a second returned array.
local function ImaginaryVoxels(params, frameLimit, toDestroy)
	local voxels, existingDebris = {} :: {Types.ImaginaryVoxel}, {} :: {BasePart}
	local voxelCount = 0

	toDestroy = toDestroy or GetDestructibleParts(params)

	if #toDestroy == 0 then return voxels end

	--debug.profilebegin("FindDestructibleParts")
	local partsInPart = {}
	for i, part in ipairs(toDestroy) do
		if part:HasTag(DebrisTag) then
			table.insert(existingDebris, part)
			continue
		end

		part.CanQuery = false

		local DirtyGroupID = part:GetAttribute(DirtyGroupIDAttribute)

		table.insert(partsInPart, {
			CFrame = part.CFrame,
			Size = part.Size,

			DestructionID = params.ID,

			DirtyGroupID = DirtyGroupID,
			GridSize = params.GridSize or DirtyGroupData[DirtyGroupID].GridSize or Settings.DefaultGridSize
		})
	end

	--debug.profileend()

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

	--[[
	local imaginaryDestructibles = GetImaginaryDestructibleParts(cuttingPart, intersectingVerts, intersectingNormals)
	if #imaginaryDestructibles > 0 then
		table.move(imaginaryDestructibles, 1, #imaginaryDestructibles, #partsInPart + 1, partsInPart)
	end
	--]]

	local dividing = partsInPart :: {Types.ImaginaryBox}
	partsInPart = nil

	local creating = {} :: {Types.ImaginaryBox}

	--debug.profileend()

	--debug.profilebegin("ImaginaryDivisionStep")

	-- imaginary division step
	while #dividing > 0 do

		if frameLimit and frameDivs > Settings.MaxDivisionsPerFrame then
			table.move(dividing, 1, #dividing, #creating + 1, creating)
			--table.move(dividing, 1, #dividing, #ImaginaryWorkQueue + 1, ImaginaryWorkQueue)
			break
		end

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
			local s, gridSize, DirtyGroupID, destructionID = toDivide.Size, toDivide.GridSize, toDivide.DirtyGroupID, toDivide.DestructionID

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
					created.DestructionID = destructionID
				end
				-- add them to the list of voxels
				table.move(newVoxels, 1, #newVoxels, #voxels + 1, voxels)

				-- toDivide is done being processed
				continue
			end
			--debug.profileend()

			if frameLimit then frameDivs += 1 end

			-- if toDivide is not encapsulated within CuttingPart, it lies along the edge of the destruction
			toDivide.isEdge = true

			local sx,sy,sz = s.X, s.Y, s.Z
			local minsize, maxsize = math.min(sx, sy, sz), math.max(sx, sy, sz)

			-- use Subdivide (either KD or MOT to subdivide toDivide)
			for _, created in ipairs(SubdivideFunctions[(maxsize > 2 * minsize) and "KD" or "MOT"](toDivide, gridSize)) do
				--
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
						v.DestructionID = destructionID
					end
					-- add these new voxels to the list of voxels
					table.move(newVoxels, 1, #newVoxels, #voxels + 1, voxels)

					continue
				end
				--]]

				created.GridSize = gridSize
				created.DirtyGroupID = DirtyGroupID
				created.DestructionID = destructionID
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

	--[[
	if #creating > 0 then
		table.move(creating, 1, #creating, #ImaginaryCreateQueue + 1, ImaginaryCreateQueue)
	end

	if #toDestroy > 0 then
		table.move(toDestroy, 1, #toDestroy, #ImaginaryDestroyQueue + 1, ImaginaryDestroyQueue)
	end
	--]]

	-- create new static parts
	--
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

	for FallingGroupID in pairs(OperationAffectedFallingGroups[params.ID]) do
		DFSWeld(FallingGroupID)
	end

	--debug.profileend()

	return setmetatable(voxels, { __len = function() return voxelCount end }) :: {Types.ImaginaryVoxel}, existingDebris :: {BasePart}
end
--]]


-- Uses the given callback from the OnVoxelDestruct registry to destroy the given voxel
local function HandleVoxelDestruction(callbackName : string?, voxel : Part, info : Types.DestroyedVoxelInfo?)
	if not info then info = {} end

	local s, e = pcall(OnVoxelDestructRegistry[callbackName], voxel, info)

	if not s then warn("Voxel destruction failed: " .. e) end

	if not info.IsAlreadyDebris then voxel:AddTag(DebrisTag) end
end

-- pops an element from the ShatterQueue, removing the completed operations that it might find before finding one to complete.
local function PopShatterQueue()
	local popped, shatterPart, partsInPart
	local v = table.remove(ShatterQueue)

	while v and not popped do
		local DestructionID = v.ID
		local AffectedDirtyGroupIDs = OperationAffectedDirtyGroups[DestructionID]
		local BlacklistedVoxels = OperationBlacklistedVoxels[DestructionID]

		shatterPart, partsInPart = v.CuttingPart, {}

		for _, part in ipairs( GetDestructibleParts(v) ) do

			if part:HasTag(DebrisTag) then
				if not BlacklistedVoxels[part] then
					BlacklistedVoxels[part] = true
					HandleVoxelDestruction(v.OnVoxelDestruct, part, {
						DirtyGroupID = part:GetAttribute(DirtyGroupIDAttribute),
						CuttingPart = shatterPart,
						IsEdge = not PartEncapsulatesBlockPart(shatterPart, part.CFrame, part.Size),
						IsAlreadyDebris = true,
						UserData = v.UserData
					})
				end
				continue
			end


			table.insert(partsInPart, part)
		end

		if #partsInPart == 0 then
			if v.OnDestructCompleted then v.OnDestructCompleted(v.DestroyedVoxels, AffectedDirtyGroupIDs) end

			for DirtyGroupID in pairs(AffectedDirtyGroupIDs) do
				local count = CountOperationsProcessing[DirtyGroupID] - 1
				CountOperationsProcessing[DirtyGroupID] = count > 0 and count or nil
			end
			OperationAffectedDirtyGroups[DestructionID] = nil
			OperationAffectedFallingGroups[DestructionID] = nil
			OperationBlacklistedVoxels[DestructionID] = nil

			v = table.remove(ShatterQueue)
		else
			popped = v
			table.insert(ShatterQueue, Settings.UsePriorityQueue and math.max(1, #ShatterQueue + 1 - Settings.PrioritizeRecentN) or 1, popped)
		end
	end

	return popped, partsInPart
end

-- processes one of the operations in the ShatterQueue, removing it if the operation is finished. It queues all divisions for this step of the operation.
-- returns true if an operation step was procesed.
local function ShatterWorker()
	local popped, partsInPart = PopShatterQueue()
	if not popped then return false end

	local blacklistedVoxels = OperationBlacklistedVoxels[popped.ID]

	local ivoxels = ImaginaryVoxels(popped, true, partsInPart)
	popped.DestroyedVoxels += #ivoxels -- count voxel contributions

	local OnVoxelDestruct = popped.OnVoxelDestruct
	if OnVoxelDestructRegistry[OnVoxelDestruct] then
		local CuttingPart, UserData = popped.CuttingPart, popped.UserData
		for _, ivoxel in ipairs(ivoxels) do
			local voxel = Shatterbox.InstantiateImaginaryVoxel(ivoxel, true)

			blacklistedVoxels[voxel] = true

			HandleVoxelDestruction(OnVoxelDestruct, voxel, {
				DirtyGroupID = ivoxel.DirtyGroupID,
				CuttingPart = CuttingPart,
				IsEdge = ivoxel.isEdge,
				IsAlreadyDebris = false,
				UserData = UserData
			})
		end
	end

	return true
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


local function ReplicateDestructionToClients(destructionType : DestructionTypes, destructionParams : Types.DestructionParams, createdDirtyGroups : { [string] : boolean })

	local serialNewDirtyGroups = {}
	for DirtyGroupID in pairs(createdDirtyGroups) do
		serialNewDirtyGroups[DirtyGroupID] = SerializedPartInstance(DirtyGroupData[DirtyGroupID].OriginalPart)
	end

	local exclusions = destructionParams.ExcludePlayersReplication
	if #exclusions > 0 then
		local PlayerList = Players:GetPlayers()
		for _, plr in ipairs(exclusions) do
			local found = table.find(PlayerList, plr)
			if found then table.remove(PlayerList, found) end
		end

		ServerEvents.ReplicateDestruction.FireList(PlayerList, destructionType, SerializedDestructionParams(destructionParams), serialNewDirtyGroups, OperationAffectedDirtyGroups[destructionParams.ID])
	else
		ServerEvents.ReplicateDestruction.FireAll(destructionType, SerializedDestructionParams(destructionParams), serialNewDirtyGroups, OperationAffectedDirtyGroups[destructionParams.ID])
	end
end

local function ReplicateDestructionFromServer(destructionType, serialParams, serialNewDirtyGroups, affectedDirtyGroupIDs)
	local destructionParams = DeserializedDestructionParams(serialParams)

	CreateSerialDirtyGroups(serialNewDirtyGroups)

	while not clientInitComplete do RunService.Heartbeat:Wait() end

	if destructionType == IMAGINARY then
		destructionParams.SkipEncapsulatedVoxels = true
		RunService.Heartbeat:Wait()
		ImaginaryVoxels(destructionParams)

	elseif destructionType == NORMAL then
		local DestructionID = destructionParams.ID

		OperationAffectedDirtyGroups[DestructionID] = affectedDirtyGroupIDs
		for DirtyGroupID in pairs(affectedDirtyGroupIDs) do
			CountOperationsProcessing[DirtyGroupID] = (CountOperationsProcessing[DirtyGroupID] or 0) + 1
		end
		OperationBlacklistedVoxels[DestructionID] = {}

		destructionParams.DestroyedVoxels = 0
		table.insert(ShatterQueue, destructionParams)
	end
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

local function CreatePuppets(puppets)
	for _, serialPuppet in ipairs(puppets) do
		local Part = DeserializedPuppet(serialPuppet)

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

	if i > 1 then workspace:BulkMoveTo(updatedPuppets, updatedStates, Enum.BulkMoveMode.FireCFrameChanged) end
end
if isClient then -- Client side interpolation loop that "tweens" every puppet voxel and moves them in bulk
	RunService.PreRender:Connect(function(deltaTime)
		if not next(PuppetsLerpData) then return end

		local P = ClientPuppetStepDelta / Settings.PuppetReplicationFrequency

		--local i = 1
		local puppets, interpolatedPositions, finishedLerps = nil, nil, {}
		for index, lerpData in pairs(PuppetsLerpData) do
			local d = lerpData[3] + deltaTime
			if d >= P then
				table.insert(finishedLerps, index)
				--interpolatedPositions[i] = lerpData[2]
				Puppets[index][1].CFrame = lerpData[2]
			else
				--interpolatedPositions[i] = lerpData[1]:Lerp(lerpData[2], d / P)
				Puppets[index][1].CFrame = lerpData[1]:Lerp(lerpData[2], d / P)
				lerpData[3] = d
			end

			--puppets[i] = Puppets[index][1]
			--i += 1
		end

		for _, index in ipairs(finishedLerps) do PuppetsLerpData[index] = nil end

		--workspace:BulkMoveTo(puppets, interpolatedPositions, Enum.BulkMoveMode.FireCFrameChanged)
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

	local serialShatterQueue = {}
	for _, destructionParams in ipairs(ShatterQueue) do
		table.insert(serialShatterQueue, SerializedDestructionParams(destructionParams))
	end

	local serialPuppets = {}
	for puppetID, puppetData in pairs(Puppets) do
		serialPuppets[puppetID] = SerializedPartInstance(puppetData[1])
	end

	ServerEvents.ReplicateState.Fire(plr,
		serialDirtyGroupData,
		serialDirtyGroupMembers,
		destroyedDirtyGroups,

		serialShatterQueue,
		CountOperationsProcessing,
		OperationAffectedDirtyGroups,

		SmoothCleanupQueue,

		GreedyMeshingQueue,
		ActiveGMWorkerGridSize,

		serialPuppets,
		PuppetNextIndex
	)
end

local function ReplicateStateFromServer(serialDirtyGroupData, serialDirtyGroupMembers, destroyedDirtyGroups, serialShatterQueue, serverCountOperationsProcessing, serverOperationAffectedDirtyGroups, serverSmoothCleanupQueue, serverGreedyMeshingQueue, serverActiveGMWorkerGridSize, serialPuppets, serverPuppetsNextIndex)

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

	for _, serialDestructionParams in ipairs(serialShatterQueue) do
		table.insert(ShatterQueue, DeserializedDestructionParams(serialDestructionParams))
	end
	CountOperationsProcessing = serverCountOperationsProcessing
	OperationAffectedDirtyGroups = serverOperationAffectedDirtyGroups

	SmoothCleanupQueue = serverSmoothCleanupQueue

	GreedyMeshingQueue = serverGreedyMeshingQueue
	for DirtyGroupID, GridSize in pairs(serverActiveGMWorkerGridSize) do
		local thr = coroutine.create(GreedyMeshWorker)

		GreedyWorkers[DirtyGroupID] = thr
		ActiveGMWorkerCount += 1
		ActiveGMWorkerGridSize[DirtyGroupID] = GridSize

		coroutine.resume(thr, DirtyGroupID, GridSize)
	end

	PuppetNextIndex = serverPuppetsNextIndex
	for puppetID, serialPuppet in pairs(serialPuppets) do
		Puppets[puppetID] = { DeserializedPuppet(serialPuppet) }
	end

	clientInitComplete = true
end



-- Heartbeat behavior functions

local function SmoothCleanupBehavior(deltaTime)
	local toReset = {}

	for DirtyGroupID, countdown in pairs(SmoothCleanupQueue) do
		countdown -= deltaTime
		if countdown > 0 then
			SmoothCleanupQueue[DirtyGroupID] = countdown
		else
			table.insert(toReset, DirtyGroupID)
		end
	end

	local waitingToTerminate = {}

	for _, DirtyGroupID in ipairs(toReset) do
		if CountOperationsProcessing[DirtyGroupID] then continue end

		if GreedyMeshingQueue[DirtyGroupID] then GreedyMeshingQueue[DirtyGroupID] = nil end
		if GreedyWorkers[DirtyGroupID] then
			waitingToTerminate[DirtyGroupID] = true
			continue
		end

		SmoothCleanupQueue[DirtyGroupID] = nil
		UndoDirtyGroup(DirtyGroupID)
	end

	while RunService.Heartbeat:Wait() do
		local allDone = true
		for DirtyGroupID in pairs(waitingToTerminate) do
			if GreedyWorkers[DirtyGroupID] then
				allDone = false
				break
			end
		end
		if allDone then break end
	end

	for DirtyGroupID in pairs(waitingToTerminate) do
		SmoothCleanupQueue[DirtyGroupID] = nil
		UndoDirtyGroup(DirtyGroupID)
	end
end

local function GreedyMeshingBehavior()
	-- Start more greedy meshing coroutines if there is space to do so
	if ActiveGMWorkerCount < Settings.GMWorkerCount then
		-- Start greedy meshing coroutines until the limit is reached or there are no more flagged groups
		local toRemove = {}
		for DirtyGroupID, GridSize in pairs(GreedyMeshingQueue) do
			if CountOperationsProcessing[DirtyGroupID] or GreedyWorkers[DirtyGroupID] then continue end
			if not next(DirtyGroupMembers[DirtyGroupID]) then -- groups that have no members should not be greedy meshed
				toRemove[DirtyGroupID] = true
				continue
			end
			local thr = coroutine.create(GreedyMeshWorker)

			toRemove[DirtyGroupID] = true
			GreedyWorkers[DirtyGroupID] = thr
			ActiveGMWorkerCount += 1
			ActiveGMWorkerGridSize[DirtyGroupID] = GridSize

			coroutine.resume(thr, DirtyGroupID, GridSize)

			if ActiveGMWorkerCount >= Settings.GMWorkerCount then break end
		end
		for DirtyGroupID in pairs(toRemove) do GreedyMeshingQueue[DirtyGroupID] = nil end
	end
	-- Manage the lifecycle of all of the coroutines, terminating or resuming where required
	for DirtyGroupID, thr in pairs(GreedyWorkers) do
		local status = coroutine.status(thr)

		if status == "dead" or (status == "suspended" and GreedyWorkersTerminationFlags[DirtyGroupID]) then
			GreedyWorkersTerminationFlags[DirtyGroupID] = nil
			GreedyWorkers[DirtyGroupID] = nil
			ActiveGMWorkerCount -= 1
			ActiveGMWorkerGridSize[DirtyGroupID] = nil

		elseif status == "suspended" then
			coroutine.resume(thr)
		end
	end
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

	frameDivs = 0
	local ops = 0

	while #ShatterQueue > 0 and frameDivs < Settings.MaxDivisionsPerFrame and ops < Settings.MaxOpsPerFrame do
		ShatterWorker()
		ops += 1
	end

	if Settings.UseGreedyMeshing then GreedyMeshingBehavior() end

	if isServer then PuppeteerBehavior(deltaTime) end
end










Shatterbox.Settings = Settings


function Shatterbox.Puppeteer(voxel : Part)
	assert(isServer, "This function can only be called from the server")

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



-- Performs voxel destruction around the 'intersectingPart' according to the FilterTagged supplied.
--
-- if no FilterTagged is given, everything except IndestructibleTag tagged Block parts are considered for destruction.
function Shatterbox.Destroy(intersectingPart : Part | Model | Types.WorldInfo | Types.DestructionParams, FilterTagged : (string | {string})?, CleanupDelay : number?, OnVoxelDestruct : string?, GridSize : number?, SkipEncapsulatedVoxels : boolean?, OnDestructCompleted : (() -> ())?, UserData : {any}?, ExcludePlayersReplication : {Player}?, SkipFloors : boolean?, SkipWalls : boolean?)
	coroutine.wrap(function()
		if ModelQueueBehavior(Shatterbox.Destroy, intersectingPart, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, UserData, ExcludePlayersReplication, SkipFloors, SkipWalls) then
			return
		end

		local params = ValidateDestructionParams(intersectingPart, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, UserData, ExcludePlayersReplication, SkipFloors, SkipWalls)

		params.DestroyedVoxels = 0

		local destructibleParts, createdDirtyGroups, createdFallingGroups = GetDestructibleParts(params)
		if #destructibleParts == 0 then return end

		local DestructionID = params.ID

		local AffectedDirtyGroups = {}
		for _, part in ipairs(destructibleParts) do
			local DirtyGroupID = part:GetAttribute(DirtyGroupIDAttribute)
			if AffectedDirtyGroups[DirtyGroupID] then continue end
			AffectedDirtyGroups[DirtyGroupID] = true
			CountOperationsProcessing[DirtyGroupID] = (CountOperationsProcessing[DirtyGroupID] or 0) + 1
		end
		OperationAffectedDirtyGroups[DestructionID] = AffectedDirtyGroups
		OperationBlacklistedVoxels[DestructionID] = {}

		if USE_CLIENT_SERVER and isServer then
			ReplicateDestructionToClients(NORMAL, params, createdDirtyGroups)
		end

		table.insert(ShatterQueue, params)
	end)()
end


--*Yields until the NEXT Heartbeat to perform instant destruction.* <br>
--
--Performs voxel destruction around 'intersectingPart', skipping as many intermediate parts as possible. <br>
--
-- Returns an array of imaginary voxels for you to optionally create as debris, as well as any existing debris as a second returned array.
function Shatterbox.ImaginaryVoxels(intersectingPart : Part | Model | Types.WorldInfo | Types.ImaginaryDestructionParams, FilterTagged : (string | {string})?, CleanupDelay : number?, GridSize : number?, SkipEncapsulatedVoxels : boolean?, ExcludePlayersReplication : {Player}?, SkipFloors : boolean?, SkipWalls : boolean?) : {Types.ImaginaryVoxel}

	local did, voxels, existingDebris = ModelQueueBehavior(Shatterbox.ImaginaryVoxels, intersectingPart, FilterTagged, CleanupDelay, nil, GridSize, SkipEncapsulatedVoxels, nil, nil, ExcludePlayersReplication, SkipFloors, SkipWalls)
	if did then return voxels, existingDebris end

	local params = ValidateDestructionParams(intersectingPart, FilterTagged, CleanupDelay, nil, GridSize, SkipEncapsulatedVoxels, nil, nil, ExcludePlayersReplication, SkipFloors, SkipWalls)

	local destructibleParts, createdDirtyGroups, createdFallingGroups = GetDestructibleParts(params)
	if #destructibleParts == 0 then return voxels, existingDebris end

	if USE_CLIENT_SERVER and isServer then
		ReplicateDestructionToClients(IMAGINARY, params, createdDirtyGroups)
	end

	voxels, existingDebris = ImaginaryVoxels(params, false, destructibleParts)

	OperationAffectedFallingGroups[params.ID] = nil

	return voxels, existingDebris
end

-- Will return a created voxel using the supplied ImaginaryVoxel, will automatically parent the voxel to the ShatterboxTemporary folder and give it the DebrisTag tag
function Shatterbox.InstantiateImaginaryVoxel(ImaginaryVoxel : Types.ImaginaryVoxel, doNotGiveDebrisTag : boolean?)
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


--Resets an area rather than everything at once, without reverting the ownership of those parts
function Shatterbox.ResetArea(area : Part | Types.WorldInfo)

	local ACF, AS = area.CFrame, area.Size
	if isServer then ServerEvents.SignalResetArea.FireAll(ACF, AS) end

	local AreaVerts = VertexMath.GetVerts.Block(ACF, AS)
	local AreaNormals = VertexMath.GetNormals.Block(ACF)

	local toResetIDs, toTerminate = {}, {}

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


		if intersected then
			-- if this DirtyGroupID is going to be reset and still has operations processing it, cancel those operations
			local countProcessing = CountOperationsProcessing[DirtyGroupID]
			if countProcessing then
				local toCancel, countFound = {}, 0
				for DestructionID, AffectedIDs in pairs(OperationAffectedDirtyGroups) do
					if not AffectedIDs[DirtyGroupID] then continue end
					toCancel[DestructionID] = true
					countFound += 1
					if countFound == countProcessing then break end
				end
				for DestructionID in pairs(toCancel) do
					for i, destructionParams in ipairs(ShatterQueue) do
						if destructionParams.ID == DestructionID then
							table.remove(ShatterQueue, i)
							break
						end
					end
					OperationAffectedDirtyGroups[DestructionID] = nil
				end
			end
			-- if this DirtyGroupID is being greedy meshed, flag the thread for termination before resetting
			if GreedyWorkers[DirtyGroupID] then
				toTerminate[DirtyGroupID] = true
			else
				-- flag this id for resetting
				toResetIDs[DirtyGroupID] = true
			end
		end
	end

	for DirtyGroupID in pairs(toResetIDs) do UndoDirtyGroup(DirtyGroupID) end

	-- terminate all active greedy meshing workers in the area, then wait for them to terminate
	if next(toTerminate) then
		for DirtyGroupID in pairs(toTerminate) do
			GreedyWorkersTerminationFlags[DirtyGroupID] = true
		end
		while RunService.Heartbeat:Wait() do
			local allDone = true
			for DirtyGroupID in pairs(toTerminate) do
				if GreedyWorkers[DirtyGroupID] then
					allDone = false
					break
				end
			end
			if allDone then break end
		end
	end

	-- revert all destructions bounded by the area
	for DirtyGroupID in pairs(toTerminate) do UndoDirtyGroup(DirtyGroupID) end
end


-- resets all modified parts to where they originally were (turning the map back to normal) and re-allocating system queues and maps
function Shatterbox.Reset(doNotRevertOwnership : boolean?, replicated : boolean?)
	-- stop all queued destructions
	ShatterQueue = {}
	CountOperationsProcessing = {}
	OperationAffectedDirtyGroups = {}

	-- wait for all greedy meshing coroutines to terminate
	for DirtyGroupID in pairs(GreedyWorkers) do
		GreedyWorkersTerminationFlags[DirtyGroupID] = true
	end
	while ActiveGMWorkerCount > 0 do RunService.Heartbeat:Wait() end

	SmoothCleanupQueue = {}

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

	GreedyMeshingQueue = {}
	GreedyWorkers = {}
	GreedyWorkersTerminationFlags = {}
	ActiveGMWorkerCount = 0
	ActiveGMWorkerGridSize = {}

	Puppets = {}
	PuppetsLerpData = {}
	PuppetNextIndex = 1
	PuppetNextReplicationIndex = 1
	CreatePuppetQueue = {}
end


-- Cancels any ongoing operations
function Shatterbox.ClearQueue()
	ShatterQueue = {}

	if isServer then ServerEvents.SignalClearQueue.FireAll() end
end


-- Creates a "Hitbox" object which can be used in place of the destruction functions, and has additional functionality. (like VoxBreaker moveable hitbox)
-- If you use ExcludePlayersReplication, that will be cleared after every destruction automatically, for convenience.
function Shatterbox.CreateHitbox()

	local hitbox = {}
	hitbox.CFrame = CFrame.new() :: CFrame
	hitbox.Size = Vector3.new(1, 1, 1) :: Vector3
	hitbox.Shape = Enum.PartType.Ball :: Enum.PartType

	hitbox.DestructDelay = nil :: number?

	hitbox.FilterTagged = nil :: (string | {string})?

	hitbox.OnVoxelDestruct = nil :: string?
	hitbox.UserData = {} :: {any}
	hitbox.ExcludePlayersReplication = {} :: {Player}

	hitbox.OnDestructCompleted = nil :: (() -> ())?

	hitbox.CleanupDelay = nil :: number?
	hitbox.GridSize = nil :: number?

	hitbox.SkipEncapsulatedVoxels = nil :: boolean?
	hitbox.SkipWalls = nil :: boolean?
	hitbox.SkipFloors = nil :: boolean?

	hitbox.DestructionType = "DEFAULT" :: ("DEFAULT"|"IMAGINARY")
	hitbox.ImaginaryCallback = nil :: ( (imaginaryVoxels : {Types.ImaginaryVoxel}, existingDebris : {BasePart}) -> () )?

	hitbox.StartConnectionEvent = RunService.Heartbeat -- the event that the hitbox connects to when using Start(), needs to have a deltaTime parameter
	hitbox.WeldConnectionEvent = RunService.PostSimulation -- the event that the hitbox connects to when using WeldTo()

	hitbox.VelocityPrediction = false :: boolean
	hitbox.VelocityBias = 1 :: number?

	-- Performs voxel destruction around the hitbox
	function hitbox:Destroy()
		Shatterbox.Destroy(hitbox)
		hitbox.ExcludePlayersReplication = {} -- QOL automatically clear the exlcusion after the destruction is performed
	end

	--*Yields until the NEXT Heartbeat to perform instant destruction.* <br>
	--
	-- returns the imaginary voxels bounded by the hitbox as an array, for you to optionally create, as well as any existing debris as a second returned array.
	function hitbox:ImaginaryVoxels()
		local voxels, existingDebris = Shatterbox.ImaginaryVoxels(hitbox)
		hitbox.ExcludePlayersReplication = {} -- QOL automatically clear the exlcusion after the destruction is performed
		return voxels, existingDebris
	end


	local wcon : RBXScriptConnection?
	local dcon : RBXScriptConnection?

	-- will "weld" the hitbox to the given part, continously setting its CFrame to be equal to the parts CFrame.
	-- If the Part is destroyed using ":Destroy()", the hitbox will be automatically stopped and disconnected.
	-- If workspace.PlayerCharacterDestroyBehavior is not set to true, the hitbox wont be automatically stopped when that Player respawns.
	function hitbox:WeldTo(Part : BasePart)
		if wcon then wcon:Disconnect() end
		if dcon then dcon:Disconnect() end
		hitbox.CFrame = Part.CFrame
		wcon = hitbox.WeldConnectionEvent:Connect(function(deltaTime)
			if hitbox.VelocityPrediction then
				hitbox.CFrame = Part.CFrame + Part.AssemblyLinearVelocity * hitbox.VelocityBias * deltaTime
			else
				hitbox.CFrame = Part.CFrame
			end
		end)
		dcon = Part.Destroying:Once(hitbox.DestroyHitbox)
	end

	-- will "unweld" the hitbox
	function hitbox:Unweld()
		if wcon then wcon:Disconnect() end
		if dcon then dcon:Disconnect() end
		wcon, dcon = nil, nil
	end

	local ccon : RBXScriptConnection?
	local lastCut : number

	local function DestructionStartConnection()
		if hitbox.DestructDelay then
			local t = time()
			if lastCut and t - lastCut < hitbox.DestructDelay then return end
			lastCut = t
		end

		if hitbox.DestructionType == "DEFAULT" then
			hitbox:Destroy()
		else
			local voxels, existingDebris = hitbox:ImaginaryVoxels()
			if hitbox.ImaginaryCallback then
				hitbox.ImaginaryCallback(voxels, existingDebris)
			end
		end
	end

	-- will continuously cut around the hitbox every hitbox.DestructDelay seconds, which defaults to 0.1
	function hitbox:Start()
		if ccon then return end
		ccon = hitbox.StartConnectionEvent:Connect(DestructionStartConnection)
	end

	-- will stop continuous destruction
	function hitbox:Stop()
		if ccon then ccon:Disconnect() end
		ccon = nil
	end

	-- will disconnect all connections.
	function hitbox:DestroyHitbox()
		hitbox:Unweld()
		hitbox:Stop()
	end

	return hitbox
end


-- Returns the original part that is associated with this DirtyGroupID. It was never destroyed, just had its parent set to `nil`
function Shatterbox.GetOriginalPart(DirtyGroupID : string)
	local groupData = DirtyGroupData[DirtyGroupID]
	if not groupData then return nil end
	return groupData.OriginalPart
end


-- Takes a point and converts it to the voxel space distance relative to "voxel".
-- This is a vector which tells you how many voxels away the point is on each local axis, as fractional quantities.
-- It is possible for an axis to be less than one, but never negative.
function Shatterbox.VoxelDistanceVector(voxel, point : Vector3) : Vector3
	return voxel.CFrame:PointToObjectSpace(point):Abs() / voxel.Size
end


-- Returns a vector that tells you how many voxels a box determined by "size" has on each local axis, as fractional quantities.
-- It is not possible for an axis to be less than one, because there is always at least one voxel on every axis.
function Shatterbox.VoxelCountVector(voxel, boxSize : Vector3) : Vector3
	return Vector3.one:Max(boxSize / voxel.Size)
end


-- Will return true if "contains" is FULLY contained by "part", otherwise false
function Shatterbox.PartEncapsulatesBlockPart(part : Part, contains : Part)
	assert(part:IsA("Part"), "You can only use this function when a Part is the container.")
	assert(contains:IsA("Part") and contains.Shape == Enum.PartType.Block, "You can only use this function when a Block Part is the contained object.")	
	return PartEncapsulatesBlockPart(part, contains.CFrame, contains.Size)
end


-- Will register the given callback to the given name. It's suggested you do this at the top of the module instead, otherwise it is only registered on the side you called this function from.
function Shatterbox.RegisterOnVoxelDestruct(name : string, callback : Types.OnVoxelDestruct)
	assert(typeof(name) == "string", "You must register the OnVoxelDestruct callback with a string as the name")
	local id = name:lower()
	assert(not rawget(OnVoxelDestructRegistry, id), `Callback with name {id} already exists in the registry`)
	OnVoxelDestructRegistry[id] = callback
end


Shatterbox.Voxelize = Voxelize

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

	str = P .. "CountOperationsProcessing: {"
	for DirtyGroupID, processing in pairs(CountOperationsProcessing) do
		local count = 0
		for _ in pairs(processing) do count += 1 end
		str = str..P.. "  [" .. DirtyGroupID .. "] = " .. count
	end
	str = str..P.. "}"
	print(str)

	str = P .. "OperationAffectedDirtyGroups: {"
	for DestructionID, AffectedIDs in pairs(OperationAffectedDirtyGroups) do
		str = str..P.. "  [" .. DestructionID .. "] = {"
		for DirtyGroupID in pairs(AffectedIDs) do
			str = str..P.. "    " .. DirtyGroupID
		end
		str = str..P.. "  }"
	end
	str = str..P.. "}"
	print(str)

	--print("Instanced: " .. ci)
	--print("Destroyed: " .. cd)

	str = P .. "GreedyWorkers: {"
	for DirtyGroupID in pairs(GreedyWorkers) do
		str = str..P.. "  " .. DirtyGroupID
	end
	str = str..P.. "}"
	print(str)

	str = P .. "GreedyWorkersTerminationFlags: {"
	for DirtyGroupID in pairs(GreedyWorkersTerminationFlags) do
		str = str..P.. "  " .. DirtyGroupID
	end
	str = str..P.. "}"
	print(str)

	str = P .. "GreedyMeshingQueue: {"
	for DirtyGroupID in pairs(GreedyMeshingQueue) do
		str = str..P.. "  " .. DirtyGroupID
	end
	str = str..P.. "}"
	print(str)

	print(P .. "ActiveGMWorkerCount: " .. ActiveGMWorkerCount)
end

function Shatterbox.PrintState()

	if isServer then ServerEvents.SignalPrintState.FireAll() end

	PrintState()
end



-- Create connections

RunService.Heartbeat:Connect(HeartbeatWorker)

if isServer then

	if USE_CLIENT_SERVER then
		ServerEvents.ClientInitComplete.On(ReplicateStateToPlayer)

		ServerEvents.CreateDirtyGroupsFromClient.On(function(plr, DirtyGroups)

			local SerialDirtyGroups = {}
			for DirtyGroupID, part in pairs(DirtyGroups) do
				PopulateDirtyGroup(part, DirtyGroupID)
				SerialDirtyGroups[DirtyGroupID] = SerializedPartInstance(part)
			end

			ServerEvents.CreateDirtyGroupsFromServer.FireExcept(plr, SerialDirtyGroups)
		end)
	end

elseif isClient then

	if USE_CLIENT_SERVER then
		ClientEvents.ReplicateState.On(ReplicateStateFromServer)

		ClientEvents.ReplicateDestruction.On(ReplicateDestructionFromServer)

		ClientEvents.CreateDirtyGroupsFromServer.On(CreateSerialDirtyGroups)

		ClientEvents.ClientInitComplete.Fire()
	end

	ClientEvents.SignalClearQueue.On(Shatterbox.ClearQueue)
	ClientEvents.SignalReset.On(function(doNotRevertOwnership) Shatterbox.Reset(doNotRevertOwnership, true) end)
	ClientEvents.SignalResetArea.On(function(cframe, size) Shatterbox.ResetArea({ CFrame = cframe, Size = size }) end)

	ClientEvents.CreatePuppets.On(CreatePuppets)
	ClientEvents.ReplicatePuppetStates.On(ReplicatePuppetStates)
	ClientEvents.DestroyPuppet.On(DestroyPuppet)

	ClientEvents.SignalPrintState.On(PrintState)
end

return Shatterbox