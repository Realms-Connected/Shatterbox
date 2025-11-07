--!native
--!optimize 2


-- Shatterbox release 7.8 beta 5


--#selene: allow(multiple_statements)
--#selene: allow(unused_variable)
--#selene: allow(incorrect_standard_library_use)
--#selene: allow(shadowing)

local IndestructibleTag = "Indestructible"
local DynamicWeldTag = "Falling"

local DebrisTag = "ShatterboxDebris"
local DirtyParentTag = "ShatterboxInstance"


local lib = script.Parent:WaitForChild("lib")
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
local TaggingService = require(lib:WaitForChild("TaggingService"))
local RunService = game:GetService("RunService")
local isServer, isClient = RunService:IsServer(), RunService:IsClient()


local Settings = require(script.Parent:WaitForChild("Settings"))
local USE_CLIENT_SERVER, USE_OBJECTCACHE, CACHE_INITIAL_SIZE = Settings.USE_CLIENT_SERVER, Settings.USE_OBJECTCACHE, Settings.CACHE_INITIAL_SIZE


local ClientEvents, ServerEvents, clientMapFolder, tmpFolder
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
	if not i:IsA("Part") or i.Shape ~= Enum.PartType.Block then return true end
	-- skip anything with the "Indestructible" tag
	--if i:HasTag(IndestructibleTag) then return true end
	if TaggingService.HasTag(i, IndestructibleTag) then return true end
	-- skip anything that is a descendant of the "ShatterboxTemporary" folder
	if i:IsDescendantOf(tmpFolder) then return true end
	-- skip anything which has a Humanoid child, or if any of its ancestors have a Humanoid child.
	if FindHumanoidAsAncestorChild(i) then return true end

	return false
end



-- The ShatterboxTemporary folder, which contains things like debris
tmpFolder = workspace:FindFirstChild("ShatterboxTemporary") or Instance.new("Folder")
tmpFolder.Parent = workspace
tmpFolder.Name = "ShatterboxTemporary"



-- If you modify any code below here, you are at serious risk of breaking the module. It probably already has a way to do what you need to do.

local Shatterbox = {}

local Types = require(script.Parent:WaitForChild("Types"))

local OnVoxelDestructRegistry = setmetatable({}, {
	__index = function(tbl, k) return (k and rawget(tbl, k:lower())) or rawget(tbl, "default") end
}) :: { [string] : Types.OnVoxelDestruct }

local function RegisterOnVoxelDestruct(name : string, client : Types.OnVoxelDestruct?, server : Types.OnVoxelDestruct?)
	assert(typeof(name) == "string", "You must register the OnVoxelDestruct callback with a string as the name")
	local id = name:lower()
	assert(not rawget(OnVoxelDestructRegistry, id), `Callback with name {id} already exists in the registry`)
	OnVoxelDestructRegistry[id] = isClient and client or server
end

if isServer then
	ServerEvents = require(PathToServer).Shatterbox

	local serverEffects = require(script.Parent.effects.Server)
	serverEffects:SetReference(Shatterbox)
	serverEffects.SetReference = nil
	for name, func in pairs(serverEffects) do OnVoxelDestructRegistry[name:lower()] = func end
elseif isClient then
	if USE_CLIENT_SERVER then
		clientMapFolder = workspace:FindFirstChild("ClientMap") or Instance.new("Folder")
		clientMapFolder.Parent = workspace
		clientMapFolder.Name = "ClientMap"
	end
	ClientEvents = require(PathToClient).Shatterbox

	local clientEffects = require(script.Parent:WaitForChild("effects"):WaitForChild("Client"))
	clientEffects:SetReference(Shatterbox)
	clientEffects.SetReference = nil
	for name, func in pairs(clientEffects) do OnVoxelDestructRegistry[name:lower()] = func end
end

--
local ObjectCache, CachedParts

if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then

	local TemplatePart = Instance.new("Part")
	TemplatePart.Anchored = true

	ObjectCache = require(lib:WaitForChild("ObjectCache"))

	local cacheContainer =
		if isClient then
			clientMapFolder
		else
			tmpFolder

	CachedParts = ObjectCache.new(TemplatePart, CACHE_INITIAL_SIZE, cacheContainer)
end
--]]

local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

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

local defaultOverlapParams = OverlapParams.new()
defaultOverlapParams.FilterType = Enum.RaycastFilterType.Exclude
defaultOverlapParams.FilterDescendantsInstances = { tmpFolder }

local overlapParams = OverlapParams.new()

local opDirties = {} :: {
	[string]: {

		CuttingPart : Types.Hitbox,

		dirties : { { Part : Part, OriginalParent : Instance, model : Model, GridSize : number } }
	}
}

local FlaggedDirty = {} :: {
	[string] : { {DirtyParent : Model, GridSize : number} }
}

local DynamicWeldGroups = {} :: {
	{Model}
}

local GreedyWorkers = {} :: { [Model] : thread }
local GreedyWorkersTerminationFlags = {} :: { [Model] : boolean }
local ActiveGMWorkerCount = 0

local ShatterQueue = {} :: { Types.DestructionParams }
local frameDivs, frameEncapsulated = 0, 0

local Puppets = {} :: { [string] : Part }
local CreatePuppetQueue = {}

--[[
local ImaginaryCreateQueue = {} :: { Types.ImaginaryBox }
local ImaginaryWorkQueue = {} :: { Types.ImaginaryBox }
local ImaginaryDestroyQueue = {} :: { Part }
--]]

local ToReset = {} :: { [string] : {{Part : Part, OriginalParent : Instance, model : Model}}}

-- pre-allocated part instance which is used to get the parts whenever `GetPartsInPart` is needed
local IntersectingPart = Instance.new("Part")

--local activeReset = false
--local lastOpTick = nil

local accum = 0



local EPSILON = 1e-3

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
local function GreedyMeshWorker(DirtyParent : Model, GridSize : number?)

	local Original = Shatterbox.GetOriginalPart(DirtyParent)

	-- The bounding area of Greedy Meshing, defined by the original part before it was ever destroyed
	local groupMin, _, VoxelSize, _, _, _, DIMX, DIMY, DIMZ = GridInfo(Original.CFrame, Original.Size, GridSize)
	local DIMYDIMZ = DIMY*DIMZ
	local VSX, VSY, VSZ = VoxelSize.X, VoxelSize.Y, VoxelSize.Z

	-- flat 3d state/visited array : index = (X - 1)*DIMYDIMZ + (Y - 1)*DIMZ + Z
	local State, Visited = {}, {}

	-- information about the original parts, used for smoothly displaying the output of greedy meshing
	local OriginalPartsInfo = {} :: {
		{Part : Part, PartGridInfo : {any}, Contributed : {number}}
	}

	-- the total number of voxels in the State array
	local count = 0

	for _, child in ipairs(DirtyParent:GetChildren()) do
		--if child:HasTag(DebrisTag) then continue end
		if TaggingService.HasTag(child, DebrisTag) then continue end

		local gridInfo, n = InitGreedyState(child, GridSize, groupMin, State, DIMYDIMZ, DIMZ)
		if n > 0 then
			count += n

			table.insert(OriginalPartsInfo, {
				Part = child,
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
		for i in ipairs(meshed) do
			if InstancedMeshIDs[i] then continue end
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

			local newStatic = PartFromTemplate(Original, meshedInfo.CFrame, CachedParts)
			newStatic.Size = meshedInfo.Size
			newStatic.Parent = DirtyParent

			count += 1
		end

		--[[
		if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then
			for originalID in pairs(visitedOriginals) do
				CachedParts:ReturnPart(OriginalPartsInfo[originalID].Part)
			end
		else--]]
			for originalID in pairs(visitedOriginals) do
				OriginalPartsInfo[originalID].Part:Destroy()
			end
		--end
	end
end




local function SerializedCuttingPart(p)
	return {
		CFrame = p.CFrame,
		Size = p.Size,
		Shape = p.Shape.Value
	}
end

-- Returns all of the tags of every ancestor as an array
local function AncestorGroupTags(i : Instance, tags) : {string}
	tags = tags or {}

	local ancestor = i:FindFirstAncestorWhichIsA("Folder")
	if not ancestor then
		ancestor = i:FindFirstAncestorWhichIsA("Model")
		if not ancestor then return tags end
	end

	local t = ancestor:GetTags()
	if #t > 0 then
		table.move(t, 1, #t, #tags + 1, tags)
	end

	return AncestorGroupTags(ancestor, tags)
end

-- returns OverlapParams including all instances with the given tags.
local function OverlapParamsOfTagged(tags : { string }) : OverlapParams
	local arr

	if #tags == 1 then
		arr = TaggingService.GetTagged(tags[1])
	else
		arr = {}
		for _, tag in ipairs(tags) do
			local taggedArray = TaggingService.GetTagged(tag)
			table.move(taggedArray, 1, #taggedArray, #arr + 1, arr)
		end
	end

	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = arr

	return overlapParams
end

-- What happens when a model is passed in as the `CuttingPart`
local function ModelQueueBehavior(funcToUse, intersectingPart, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, ...)
	local cuttingPart = if typeof(intersectingPart) == "table" then intersectingPart.CuttingPart else intersectingPart
	local ret = {}
	if cuttingPart and typeof(cuttingPart) == "Instance" and cuttingPart:IsA("Model") then
		for _, desc in ipairs(cuttingPart:GetDescendants()) do
			if not desc:IsA("Part") then continue end
			local r = funcToUse(desc, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, ...)
			if typeof(r) == "table" then
				table.move(r, 1, #r, #ret + 1, ret)
			end
		end
		return true, ret
	end
	return false, ret
end

-- Does the behavior for turning a voxel into debris and calling a particular effect
local function VoxelDebrisThread(callbackName : string?, voxel : Part, dirtyParent : Model, intersectingPart : BasePart, isEdge : boolean, ... : any)
	local isAlreadyDebris = TaggingService.HasTag(voxel, DebrisTag)

	if not isAlreadyDebris then voxel.Parent = tmpFolder end

	local s, e = pcall(OnVoxelDestructRegistry[callbackName], voxel, dirtyParent, intersectingPart, isEdge, isAlreadyDebris, ...)

	if not s then warn("Voxel destruction failed: " .. e) end

	--voxel:AddTag(DebrisTag)
	if not isAlreadyDebris then TaggingService.AddTag(voxel, DebrisTag) end
end

-- Uses the given callback from the OnVoxelDestruct registry to destroy the given voxel
local function HandleVoxelDestruction(callbackName : string?, voxel : Part, dirtyParent : Model, intersectingPart : BasePart, isEdge : boolean, ... : any)

	coroutine.wrap(VoxelDebrisThread)(callbackName, voxel, dirtyParent, intersectingPart, isEdge, ...)
end

-- Retrieves all of the original parts that the server moved into the camera (so it only works if client-server is enabled)
local function GetMapParts(ID)
	local tr = ToReset[ID]
	if not tr then return nil end

	local mapParts = {}

	for _, dirtied in ipairs(tr) do
		table.insert(mapParts, SerializedPartInstance(dirtied.Part))
	end

	return mapParts
end

-- Validates destruction parameters
local function ValidateDestructionParams(intersectingPart : Part | Model | Types.Hitbox | Types.DestructionParams | Types.ImaginaryDestructionParams, FilterTagged : (string | {string})?, CleanupDelay : number?, OnVoxelDestruct : string?, GridSize : number?, SkipEncapsulatedVoxels : boolean?, OnDestructCompleted : (() -> ())?, ... : any)

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

			   params.CuttingPart = CuttingPart
			  params.FilterTagged = filterTagged
			  params.CleanupDelay = tbl.CleanupDelay		   or CleanupDelay   		 or Settings.DefaultSmoothCleanupDelay
		   params.OnVoxelDestruct = tbl.OnVoxelDestruct 	   or OnVoxelDestruct
				  params.GridSize = tbl.GridSize 			   or GridSize
	params.SkipEncapsulatedVoxels = tbl.SkipEncapsulatedVoxels or SkipEncapsulatedVoxels
	   params.OnDestructCompleted = tbl.OnDestructCompleted    or OnDestructCompleted
		params.DestructParameters = tbl.DestructParameters     or { ... }
		       params.finalOpTick = tbl.finalOpTick
		                params.ID = tbl.ID or HttpService:GenerateGUID(false)

	assert(typeof(params.CleanupDelay) == "number", "CleanupDelay must be a number.")
	assert(not params.OnVoxelDestruct or typeof(params.OnVoxelDestruct) == "string", "OnVoxelDestruct must be a string indicating the name of the OnVoxelDestruct callback.")
	assert(not params.GridSize or typeof(params.GridSize) == "number", "GridSize must be a number.")
	assert(not params.SkipEncapsulatedVoxels or typeof(params.SkipEncapsulatedVoxels) == "boolean", "SkipEncapsulatedVoxels must be a boolean.")
	assert(not params.OnDestructCompleted or typeof(params.OnDestructCompleted) == "function", "OnDestructCompleted must be a function.")
	assert(typeof(params.DestructParameters) == "table", "DestructParameters must be an ARRAY (ordered by increasing number index).")

	return params :: (Types.InternalImaginaryParams | Types.InternalDestructionParams)
end

--

local DFSWeldSearchXSizeOffset = Vector3.new(1 + EPSILON, 1 - EPSILON, 1 - EPSILON)
local DFSWeldSearchYSizeOffset = Vector3.new(1 - EPSILON, 1 + EPSILON, 1 - EPSILON)
local DFSWeldSearchZSizeOffset = Vector3.new(1 - EPSILON, 1 - EPSILON, 1 + EPSILON)
--[[ DFSWeld algorithm:

	Starting with some part, a state graph is created with the following properties:
	* each node represents a Part bounded by this greedy welding (all connected parts until non-destructibles are reached)
	* each node has a link to all other destructibles that are touching the faces of it, or are inside of it
--]]
-- Starting with some part, DFS all "connected" parts, until we reach some part that is non-destructible.
local function DFSWeld(dirtyParents)

	if not dirtyParents then return end

	local toProcess = {}

	for _, dirtyParent in ipairs(dirtyParents) do
		for _, child in ipairs(dirtyParent:GetChildren()) do
			if ShouldSkipInstance(child) then continue end

			table.insert(toProcess, child)
		end
	end

	while #toProcess > 0 do
		local StartingPart = table.remove(toProcess)

		local welds = {} :: { [Instance] : { [Instance] : boolean } }

		local visited, pathStack = { [StartingPart] = true }, {StartingPart}

		while #pathStack > 0 do
			local currentPart = table.remove(pathStack)
			local c, s = currentPart.CFrame, currentPart.Size

			local nodeVisited = {}
			local connections = welds[currentPart] or {}

			for _, inAxis in ipairs(workspace:GetPartBoundsInBox(c, s + DFSWeldSearchXSizeOffset)) do -- gather touching parts on X axis
				if inAxis == currentPart then continue end

				if not welds[inAxis] or not welds[inAxis][currentPart] then connections[inAxis] = true end

				if visited[inAxis] or ShouldSkipInstance(inAxis) then continue end -- or (TaggingService.HasTag(inAxis, DebrisTag) and inAxis.Anchored)

				table.insert(pathStack, inAxis)
				visited[inAxis] = true
				nodeVisited[inAxis] = true
			end

			for _, inAxis in ipairs(workspace:GetPartBoundsInBox(c, s + DFSWeldSearchYSizeOffset)) do -- gather touching parts on Y axis
				if nodeVisited[inAxis] or inAxis == currentPart then continue end

				if not welds[inAxis] or not welds[inAxis][currentPart] then connections[inAxis] = true end

				if visited[inAxis] or ShouldSkipInstance(inAxis) then continue end -- or (TaggingService.HasTag(inAxis, DebrisTag) and inAxis.Anchored)

				table.insert(pathStack, inAxis)
				visited[inAxis] = true
				nodeVisited[inAxis] = true
			end

			for _, inAxis in ipairs(workspace:GetPartBoundsInBox(c, s + DFSWeldSearchZSizeOffset)) do -- gather touching parts on Z axis
				if nodeVisited[inAxis] or inAxis == currentPart then continue end

				if not welds[inAxis] or not welds[inAxis][currentPart] then connections[inAxis] = true end

				if visited[inAxis] or ShouldSkipInstance(inAxis) then continue end -- or (TaggingService.HasTag(inAxis, DebrisTag) and inAxis.Anchored)

				table.insert(pathStack, inAxis)
				visited[inAxis] = true
			end

			welds[currentPart] = connections
		end

		for partA, connections in pairs(welds) do

			--if not TaggingService.HasTag(partA, IndestructibleTag) then partA.Anchored = false end
			if not ShouldSkipInstance(partA) then partA.Anchored = false end

			local found = table.find(toProcess, partA)
			if found then table.remove(toProcess, found) end

			for partB in pairs(connections) do

				--if not TaggingService.HasTag(partB, IndestructibleTag) then partB.Anchored = false end
				if not ShouldSkipInstance(partB) then partB.Anchored = false end

				found = table.find(toProcess, partB)
				if found then table.remove(toProcess, found) end

				local weld = Instance.new("WeldConstraint")
				weld.Part0 = partA
				weld.Part1 = partB
				weld.Parent = partA

				TaggingService.AddTag(weld, "ShatterboxWeld")
			end
		end

	end
end

--]]


-- Undoes the given destruction identified by it's DestructionID. `replicated` is true only if the server is telling a client to undo a destruction
local function UndoDirtyOp(ID : string, replicated : boolean?)

	if USE_CLIENT_SERVER and isServer then ServerEvents.SignalUndo.FireAll(ID) end

	local intersectedDirties = opDirties[ID]
	if not intersectedDirties then
		if replicated then
			local reset = false
			local disconnect = ClientEvents.SignalReset.On(function() reset = true end)
			repeat RunService.Heartbeat:Wait() until opDirties[ID] or reset
			disconnect()
			if reset then return end
			intersectedDirties = opDirties[ID]
		else return end
	end
	opDirties[ID] = nil

	local found
	for i, v in ipairs(ShatterQueue) do
		if v.ID ~= ID then continue end
		found = i;
		break
	end
	if found then table.remove(ShatterQueue, found) end

	for _, dirtied in ipairs(intersectedDirties.dirties) do
		local DirtyParent = dirtied.model
		if GreedyWorkers[DirtyParent] then
			GreedyWorkersTerminationFlags[DirtyParent] = true
			while GreedyWorkers[DirtyParent] do RunService.Heartbeat:Wait() end
		end

		--[[
		if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then
			for _, child in ipairs(DirtyParent:GetChildren()) do
				CachedParts:ReturnPart(child)
			end
		end
		--]]

		local restored = PartFromTemplate(dirtied.Part, dirtied.Part.CFrame, CachedParts)
		restored.Parent = DirtyParent.Parent

		DirtyParent:Destroy()
	end

	--[[
	local processed = {}
	while #ImaginaryCreateQueue > 0 do
		local v = table.remove(ImaginaryCreateQueue)
		if v.DestructionID == ID then
			continue
		end
		table.insert(processed, v)
	end
	ImaginaryCreateQueue = processed
	--]]

	--[[
	if isServer then
		if next(opDirties) then
			ServerEvents.SignalUndo.FireAll(ID)
		elseif Settings.UseDynamicReset and not activeReset then
			lastOpTick = os.time()
			activeReset = true
			while os.time() - lastOpTick < Settings.DynamicResetDelay do
				RunService.Heartbeat:Wait()
			end
			activeReset = false
			Shatterbox.Reset()
		end
	end
	--]]
end

-- Flags a dirtyParent for GreedyMeshing processing
local function FlagDirty(ID, GridSize : number, dirtyParent : Model)
	if not dirtyParent then return end

	GridSize = GridSize or dirtyParent:GetAttribute("GridSize") or Settings.DefaultGridSize
	--GridSize = GridSize or TaggingService.GetAttribute(dirtyParent, "GridSize") or Settings.DefaultGridSize

	if GreedyWorkers[dirtyParent] then
		GreedyWorkersTerminationFlags[dirtyParent] = true
	end

	for _, dirtied in pairs(FlaggedDirty) do
		local found
		for i, v in ipairs(dirtied) do
			if v.DirtyParent == dirtyParent then
				found = table.remove(dirtied, i)
				GridSize = math.min(GridSize, v.GridSize)
				break
			end
		end
		if found then break end
	end

	if FlaggedDirty[ID] then
		table.insert(FlaggedDirty[ID], {GridSize = GridSize, DirtyParent = dirtyParent})
	else
		FlaggedDirty[ID] = { {GridSize = GridSize, DirtyParent = dirtyParent} }
	end
end

-- creates a dirtyParent model for a part if it doesn't exist, then calls FlagDirty on the dirtyParent
local function MarkDirty(ID, GridSize : number, Part : Part, CuttingPart : Types.Hitbox)

	--if Part:HasTag(DebrisTag) then return end
	if TaggingService.HasTag(Part, DebrisTag) then return end

	local PartParent = Part.Parent

	--if PartParent and not PartParent:HasTag(DirtyParentTag) then
	if PartParent and not TaggingService.HasTag(PartParent, DirtyParentTag) then
		local model = Instance.new("Model")

		if USE_CLIENT_SERVER and isServer then
			for _, tag in ipairs(AncestorGroupTags(Part)) do
				--model:AddTag(tag)
				--Part:AddTag(tag)
				TaggingService.AddTag(model, tag)
				TaggingService.AddTag(Part, tag)
			end

			if not Part:IsDescendantOf(workspace.CurrentCamera) then
				--if activeReset then lastOpTick = os.time() end
				ToReset[ID] = ToReset[ID] or {}
				table.insert(ToReset[ID], {
					Part = Part,
					OriginalParent = PartParent,
					model = model
				})
			end

			model.Parent = workspace.CurrentCamera
		elseif USE_CLIENT_SERVER then
			model.Parent = clientMapFolder
		else
			model.Parent = PartParent
		end

		model.Name = Part.Name
		--model:AddTag(DirtyParentTag)
		TaggingService.AddTag(model, DirtyParentTag)
		--TaggingService.SetAttribute(model, "GridSize", Part:GetAttribute("GridSize"))
		model:SetAttribute("GridSize", Part:GetAttribute("GridSize"))
		for _, tag in ipairs(TaggingService.GetTags(Part)) do
			--model:AddTag(tag)
			TaggingService.AddTag(model, tag)
		end

		Part.Parent = model

		opDirties[ID] = opDirties[ID] or {
			dirties = {},
			CuttingPart = CuttingPart
		}

		table.insert(opDirties[ID].dirties, {
			Part = Part:Clone(),
			OriginalParent = PartParent,
			model = model,
			GridSize = GridSize
		})

		return true
	end

	local AncestorWithDynamicWeldTag = TaggingService.FindFirstAncestorWithTag(Part, DynamicWeldTag)
	if AncestorWithDynamicWeldTag then
		
	end

	if Settings.UseGreedyMeshing then
		FlagDirty(ID, GridSize, Part.Parent)
	end

	return false
end




--[[
local function GetImaginaryDestructibleParts(cuttingPart, verts, normals) -- I am simply goated
	local iBa, iC = cuttingPart.Shape.Name == "Ball", cuttingPart.Shape.Name == "Cylinder"

	local processed = {}
	local destructibles = {}

	while #ImaginaryCreateQueue > 0 do
		local ivox = table.remove(ImaginaryCreateQueue)
		local intersected

		if iBa then
			intersected = VertexMath.BallIntersectsBlock(cuttingPart.CFrame, cuttingPart.Size, ivox.CFrame, ivox.Size)
		elseif iC then
			intersected = VertexMath.CylinderIntersectsBlock(cuttingPart.CFrame, cuttingPart.Size, verts, normals, ivox.CFrame, ivox.Size, BlockVerts(ivox.CFrame, ivox.Size), BlockNormals(ivox.CFrame))
		else
			intersected = PartContainsAVert(cuttingPart, verts) or VertexMath.SAT(verts, normals, BlockVerts(ivox.CFrame, ivox.Size), BlockNormals(ivox.CFrame))
		end

		table.insert(intersected and destructibles or processed, ivox)
	end

	ImaginaryCreateQueue = processed

	processed = {}
	--[[
	while #ImaginaryWorkQueue > 0 do
		local ivox = table.remove(ImaginaryWorkQueue)
		local intersected

		if iBa then
			intersected = VertexMath.BallIntersectsBlock(cuttingPart.CFrame, cuttingPart.Size, ivox.CFrame, ivox.Size)
		elseif iC then
			intersected = VertexMath.CylinderIntersectsBlock(cuttingPart.CFrame, cuttingPart.Size, verts, normals, ivox.CFrame, ivox.Size, BlockVerts(ivox.CFrame, ivox.Size), BlockNormals(ivox.CFrame))
		else
			intersected = PartContainsAVert(cuttingPart, verts) or VertexMath.SAT(verts, normals, BlockVerts(ivox.CFrame, ivox.Size), BlockNormals(ivox.CFrame))
		end

		table.insert(intersected and destructibles or processed, ivox)
	end

	ImaginaryWorkQueue = processed
	--]

	return destructibles
end
--]]

-- Returns all of the destructible parts that intersect the cuttingPart, calling MarkDirty on them
local function GetDestructibleParts(ID, cuttingPart, GridSize, filterTagged, replicated)
	local partsInPart = {}

	local op =
		if filterTagged then
			OverlapParamsOfTagged(filterTagged)
		else
			defaultOverlapParams

	IntersectingPart.CFrame = cuttingPart.CFrame
	IntersectingPart.Size = cuttingPart.Size
	IntersectingPart.Shape = cuttingPart.Shape

	for _, part in ipairs( workspace:GetPartsInPart(IntersectingPart, op) ) do

		if (replicated and not part:IsDescendantOf(clientMapFolder)) or ShouldSkipInstance(part) then continue end

		-- adds this part to the smooth cleanup for this destruction, if it's not already destroyed by something else
		MarkDirty(ID, GridSize, part, cuttingPart)

		table.insert(partsInPart, part)
	end

	return partsInPart
end

--Performs voxel destruction according to the parameters, returning an array of un-created voxels
local function ImaginaryVoxels(params, frameLimit, toDestroy)
	local voxels = {} :: {Types.ImaginaryVoxel}
	local voxelCount = 0

	--debug.profilebegin("GetDestructibleParts")

	toDestroy = toDestroy or GetDestructibleParts(params.ID, params.CuttingPart, params.GridSize, params.FilterTagged, params.replicated)
	local doNotDestroy = {}

	--debug.profileend()

	if #toDestroy == 0 then return voxels end

	--debug.profilebegin("InitializeImaginaryState")

	local partsInPart = table.create(#toDestroy)
	for i, part in ipairs(toDestroy) do
		part.CanQuery = false
		partsInPart[i] = {
			CFrame = part.CFrame,
			Size = part.Size,

			Original = Shatterbox.GetOriginalPart(part.Parent),
			DestructionID = params.ID,

			DirtyParent = part.Parent,
			GridSize = params.GridSize or part:GetAttribute("GridSize") or part.Parent:GetAttribute("GridSize") or Settings.DefaultGridSize,
			--GridSize = params.GridSize or TaggingService.GetAttribute(part, "GridSize") or TaggingService.GetAttribute(part.Parent, "GridSize") or Settings.DefaultGridSize
			OriginalIndex = i
		}
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

	--[[
	local imaginaryDestructibles = GetImaginaryDestructibleParts(cuttingPart, intersectingVerts, intersectingNormals)
	if #imaginaryDestructibles > 0 then
		table.move(imaginaryDestructibles, 1, #imaginaryDestructibles, #partsInPart + 1, partsInPart)
	end
	--]]

	local dividing = partsInPart :: {Types.ImaginaryBox}
	partsInPart = nil

	local creating = {}

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
			local s, o, gridSize, dirtyParent, destructionID = toDivide.Size, toDivide.Original, toDivide.GridSize, toDivide.DirtyParent, toDivide.DestructionID

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
					created.Original = o
					created.GridSize = gridSize
					created.DirtyParent = dirtyParent
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
						v.Original = o
						v.GridSize = gridSize
						v.DirtyParent = dirtyParent
						v.DestructionID = destructionID
					end
					-- add these new voxels to the list of voxels
					table.move(newVoxels, 1, #newVoxels, #voxels + 1, voxels)

					continue
				end
				--]]

				created.Original = o
				created.GridSize = gridSize
				created.DirtyParent = dirtyParent
				created.DestructionID = destructionID
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
		local newStatic = PartFromTemplate(ibox.Original, ibox.CFrame, CachedParts)
		newStatic.Size = ibox.Size
		newStatic.Parent = ibox.DirtyParent
	end

	-- destroy original parts
	for i, part in ipairs(toDestroy) do
		if doNotDestroy[i] then continue end
		
		if TaggingService.HasTag(part, "ObjectCache") then
			CachedParts:ReturnPart(part)
		else
			part:Destroy()
		end
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

	--DFSWeld(opDirties[params.ID])

	--debug.profileend()

	return setmetatable(voxels, { __len = function() return voxelCount end }) :: {Types.ImaginaryVoxel}
end
--]]

--[[
local function ImaginaryVoxels(params, frameLimit, toDestroy)
	local voxels = {} :: {Types.ImaginaryVoxel}
	local voxelCount = 0

	--debug.profilebegin("GetDestructibleParts")

	toDestroy = toDestroy or GetDestructibleParts(params.ID, params.CuttingPart, params.GridSize, params.FilterTagged, params.replicated)

	--debug.profileend()

	if #toDestroy == 0 then return voxels end

	debug.profilebegin("InitializeImaginaryState")

	-- base division step
	local partsInPart = {}
	for _, part in ipairs(toDestroy) do
		part.CanQuery = false

		local s = part.Size
		local sx,sy,sz = s.X, s.Y, s.Z
		local minsize, maxsize = math.min(sx, sy, sz), math.max(sx, sy, sz)

		local gridSize = params.GridSize or part:GetAttribute("GridSize") or part.Parent:GetAttribute("GridSize") or Settings.DefaultGridSize
		--GridSize = params.GridSize or TaggingService.GetAttribute(part, "GridSize") or TaggingService.GetAttribute(part.Parent, "GridSize") or Settings.DefaultGridSize

		if frameLimit then frameDivs += 1 end

		local baseDividedChildren = SubdivideFunctions[(maxsize > 2 * minsize) and "KD" or "MOT"](part, gridSize)

		if baseDividedChildren then
			for _, created in ipairs(baseDividedChildren) do
				table.insert(partsInPart, {
					CFrame = created.CFrame,
					Size = created.Size,

					Original = Shatterbox.GetOriginalPart(part.Parent),
					DestructionID = params.ID,

					DirtyParent = part.Parent,
					GridSize = gridSize
				})
			end
		else
			table.insert(voxels, {
				CFrame = part.CFrame,
				Size = part.Size,

				Original = Shatterbox.GetOriginalPart(part.Parent),
				DestructionID = params.ID,

				DirtyParent = part.Parent,
				GridSize = gridSize
			})
		end
	end

	local cuttingPart = params.CuttingPart

	--[[
	local imaginaryDestructibles = GetImaginaryDestructibleParts(cuttingPart, intersectingVerts, intersectingNormals)
	if #imaginaryDestructibles > 0 then
		table.move(imaginaryDestructibles, 1, #imaginaryDestructibles, #partsInPart + 1, partsInPart)
	end
	--]-]

	local dividing = partsInPart :: {Types.ImaginaryBox}
	partsInPart = nil

	local creating = {}

	debug.profileend()

	debug.profilebegin("ImaginaryDivisionStep")

	-- imaginary division step
	while #dividing > 0 do

		if frameLimit and frameDivs > Settings.MaxDivisionsPerFrame then
			table.move(dividing, 1, #dividing, #creating + 1, creating)
			break
		end

		--debug.profilebegin("IntersectionTest")

		local toDivide = table.remove(dividing)
		local verts = BlockVerts(toDivide.CFrame, toDivide.Size)

		local intersected = PartContainsAVert(cuttingPart, verts)

		--debug.profileend()

		if frameLimit then frameDivs += 1 end

		--debug.profilebegin("ProcessIntersection")

		if intersected then
			table.remove(verts, intersected)

			local s, o, gridSize, dirtyParent, destructionID = toDivide.Size, toDivide.Original, toDivide.GridSize, toDivide.DirtyParent, toDivide.DestructionID

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
			if PartContainsAllVerts(cuttingPart, verts) then

				-- The encapsulated part contributes this many voxels
				voxelCount += toDivideVoxelContributions

				-- if SkipEncapsulatedVoxels, do nothing and skip the encapsulated part
				if params.SkipEncapsulatedVoxels then continue end

				-- otherwise, use ImaginaryVoxelize to turn the encapsulated part into it's constituent voxels
				local newVoxels = ImaginaryVoxelize(toDivide, gridSize)
				for _, created in ipairs(newVoxels) do
					created.Original = o
					created.GridSize = gridSize
					created.DirtyParent = dirtyParent
					created.DestructionID = destructionID
				end

				-- add them to the list of voxels
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
						v.Original = o
						v.GridSize = gridSize
						v.DirtyParent = dirtyParent
						v.DestructionID = destructionID
					end
					-- add these new voxels to the list of voxels
					table.move(newVoxels, 1, #newVoxels, #voxels + 1, voxels)

					continue
				end
				--]-]

				created.Original = o
				created.GridSize = gridSize
				created.DirtyParent = dirtyParent
				created.DestructionID = destructionID
				table.insert(dividing, created)
			end
		else
			-- if the toDivide part is not intersecting the CuttingPart, it is a static part
			table.insert(creating, toDivide)
		end

		--debug.profileend()
	end

	debug.profileend()

	debug.profilebegin("CreateNewState")

	--[[
	if #creating > 0 then
		table.move(creating, 1, #creating, #ImaginaryCreateQueue + 1, ImaginaryCreateQueue)
	end

	if #toDestroy > 0 then
		--table.move(toDestroy, 1, #toDestroy, #ImaginaryDestroyQueue + 1, ImaginaryDestroyQueue)
	end
	--]-]

	-- create new static parts
	--
	for _, ibox in ipairs(creating) do
		local newStatic = PartFromTemplate(ibox.Original, ibox.CFrame, CachedParts)
		newStatic.Size = ibox.Size
		newStatic.Parent = ibox.DirtyParent
	end
	--]]

	--[[ destroy original parts
	if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then
		for _, part in ipairs(toDestroy) do
			CachedParts:ReturnPart(part)
		end
	else--]-]
		for _, part in ipairs(toDestroy) do
			part:Destroy()
		end
	--end

	debug.profileend()

	-- recursive convergence step
	if not frameLimit or frameDivs < Settings.MaxDivisionsPerFrame then
		local rvoxels = ImaginaryVoxels(params, frameLimit)
		table.move(rvoxels, 1, #rvoxels, #voxels + 1, voxels)
	end


	return setmetatable(voxels, { __len = function() return voxelCount end }) :: {Types.ImaginaryVoxel}
end
--]]

-- pops an element from the ShatterQueue, removing the completed operations that it might find before finding one to complete.
local function PopShatterQueue()
	local popped, shatterPart, partsInPart
	local v = table.remove(ShatterQueue)

	while v and not popped do

		shatterPart, partsInPart = v.CuttingPart, {}

		for _, part in ipairs( GetDestructibleParts(v.ID, shatterPart, v.GridSize, v.FilterTagged, v.replicated) ) do

			--if part:HasTag(DebrisTag) then
			if TaggingService.HasTag(part, DebrisTag) then
				HandleVoxelDestruction(v.OnVoxelDestruct, part, part.Parent, shatterPart, not PartEncapsulatesBlockPart(shatterPart, part.CFrame, part.Size), unpack(v.DestructParameters))
				continue
			end

			table.insert(partsInPart, part)
		end

		if #partsInPart == 0 then
			if v.OnDestructCompleted then v.OnDestructCompleted(v.DestroyedVoxels) end
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

	local OnVoxelDestruct, CuttingPart, DestructParameters = popped.OnVoxelDestruct, popped.CuttingPart, popped.DestructParameters

	local ivoxels = ImaginaryVoxels(popped, true, partsInPart)

	popped.DestroyedVoxels += #ivoxels

	for _, ivoxel in ipairs(ivoxels) do
		local voxel = PartFromTemplate(ivoxel.Original, ivoxel.CFrame, CachedParts)
		voxel.Size = ivoxel.Size
		HandleVoxelDestruction(OnVoxelDestruct, voxel, ivoxel.DirtyParent, CuttingPart, ivoxel.isEdge, unpack(DestructParameters))
	end

	return true
end




-- Creates all of the original map parts associated with a destruction for the clients.
-- This allows the clients to process their own destructions alongside the server.
local function CreateReplicatedMapParts(ID, mapParts, cuttingPart)
	if not mapParts then return end

	for _, serialPart in ipairs(mapParts) do
		local Part = DeserializedPartInstance(serialPart, CachedParts)
		Part.Parent = clientMapFolder

		if ID then MarkDirty(ID, serialPart.GridSize, Part, cuttingPart) end
	end
end

local function ReplicateDestructionToClients(destructionParams : Types.DestructionParams, event)
	destructionParams = table.clone(destructionParams)
	destructionParams.CuttingPart = SerializedCuttingPart(destructionParams.CuttingPart)

	event.FireAll(destructionParams, GetMapParts(destructionParams.ID))
end

local function ReplicateDestructionFromServer(params, mapParts)
	params.CuttingPart.Shape = Enum.PartType:FromValue(params.CuttingPart.Shape)

	local dParams = ValidateDestructionParams(params)

 	CreateReplicatedMapParts(dParams.ID, mapParts, dParams.CuttingPart)

	dParams.replicated = true

	dParams.DestroyedVoxels = 0

	table.insert(ShatterQueue, dParams)
end

local function ReplicateImaginaryFromServer(params, mapParts)
	params.CuttingPart.Shape = Enum.PartType:FromValue(params.CuttingPart.Shape)
	params.SkipEncapsulatedVoxels = true

	local dParams = ValidateDestructionParams(params)

	CreateReplicatedMapParts(dParams.ID, mapParts, dParams.CuttingPart)

	dParams.replicated = true

	RunService.Heartbeat:Wait()

	ImaginaryVoxels(dParams)
end




local function CreatePuppets(puppets)
	for _, puppet in ipairs(puppets) do
		local Part = DeserializedPartInstance(puppet, CachedParts)

		--Part:AddTag(IndestructibleTag)
		TaggingService.AddTag(Part, IndestructibleTag)

		Part.Parent = tmpFolder

		Puppets[puppet.GUID] = Part
	end
end

local function ReplicatePuppetStates(puppetStates)
	local numPuppets = 0
	for _ in pairs(Puppets) do numPuppets += 1 end
    for _, state in ipairs(puppetStates) do
        local voxel = Puppets[state.GUID]
		if not voxel then continue end

		if Settings.ClientTweenPuppets then
			TweenService:Create(voxel, TweenInfo.new(1 / Settings.PuppetReplicationFrequency, Enum.EasingStyle.Linear), {
				CFrame = state.CFrame
			}):Play()
		else
			voxel.CFrame = state.CFrame
		end
    end
end

local function DestroyPuppet(guid)
	local found = Puppets[guid]
	if not found then return end
	--[[
	if USE_OBJECTCACHE and not (USE_CLIENT_SERVER and isServer) then
		CachedParts:ReturnPart(found)
	else--]]
		found:Destroy()
	--end

	Puppets[guid] = nil
end




local function ReplicateMapToNewPlayer(plr)
	local visitiedIDs = {}
	local replicatedDirties = {}
	local replicatedResets = {}

	local filterDesc = {}

	for ID, opDirty in pairs(opDirties) do
		visitiedIDs[ID] = true
		local serialDirties = {}

		for _, dirty in ipairs(opDirty.dirties) do
			local serialChildren = {}
			for _, p in ipairs(dirty.model:GetChildren()) do
				table.insert(serialChildren, {
					CFrame = p.CFrame,
					Size = p.Size,
				})
			end
			table.insert(filterDesc, dirty.model)
			local p = dirty.Part
			local serialDirtied = SerializedPartInstance(p, true)
			serialDirtied.OriginalPart = { CFrame = p.CFrame, Size = p.Size }
			serialDirtied.Children = serialChildren

			table.insert(serialDirties, serialDirtied)
		end
		table.insert(replicatedDirties, {
			ID = ID,
			CuttingPart = opDirty.CuttingPart,
			Dirties = serialDirties
		})
	end

	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = filterDesc

	for ID, toReset in pairs(ToReset) do
		if visitiedIDs[ID] then continue end

		for _, dirtied in ipairs(toReset) do
			if #workspace:GetPartsInPart(dirtied.Part, overlapParams) > 0 then continue end
			table.insert(replicatedResets, SerializedPartInstance(dirtied.Part))
		end
	end

	if #replicatedDirties == 0 and #replicatedResets == 0 then return end

	ServerEvents.ReplicateMap.Fire(plr, replicatedDirties, replicatedResets)
end

local function ReplicateMapFromServer(SerialOpDirties, mapParts)

	for _, serialOpDirty in ipairs(SerialOpDirties) do
		local dirtied = {}

		local ID = serialOpDirty.ID

		for _, serialDirtied in ipairs(serialOpDirty.Dirties) do

			local replicatedOriginal = DeserializedPartInstance(serialDirtied, CachedParts)
			replicatedOriginal.CFrame = serialDirtied.OriginalPart.CFrame
			replicatedOriginal.Size = serialDirtied.OriginalPart.Size

			local model = Instance.new("Model")
			--model:AddTag(DirtyParentTag)
			TaggingService.AddTag(model, DirtyParentTag)
			model:SetAttribute("GridSize", serialDirtied.Attributes.GridSize)
			--TaggingService.SetAttribute(model, "GridSize", serialDirtied.Attributes.GridSize)
			for _, tag in ipairs(serialDirtied.Tags) do
				--model:AddTag(tag)
				TaggingService.AddTag(model, tag)
			end

			for _, serialChild in ipairs(serialDirtied.Children) do
				local Part = DeserializedPartInstance(serialDirtied, CachedParts)
				Part.CFrame = serialChild.CFrame
				Part.Size = serialChild.Size
				Part.Parent = model
			end

			if Settings.UseGreedyMeshing then
				FlagDirty(ID, serialDirtied.Attributes.GridSize, model)
			end

			model.Parent = clientMapFolder
			table.insert(dirtied, { model = model, Part = replicatedOriginal })
		end

		opDirties[ID] = {
			CuttingPart = serialOpDirty.CuttingPart,
			dirties = dirtied
		}
	end

	CreateReplicatedMapParts(nil, mapParts)
end










local function HeartbeatWorker(deltaTime)
	--[[
	local frameCreated = 0

	while #ImaginaryCreateQueue > 0 and frameCreated < Settings.ImaginaryCreatedStaticPartsPerFrame do
		local ibox = table.remove(ImaginaryCreateQueue)
		local P = ibox.Original

		local newStatic = Instance.new("Part")
		newStatic.Material = P.Material
		newStatic.Transparency = P.Transparency
		newStatic.Reflectance = P.Reflectance
		newStatic.Color = P.Color
		newStatic.Anchored = P.Anchored
		newStatic.CFrame = ibox.CFrame
		newStatic.Size = ibox.Size
		newStatic.Parent = ibox.DirtyParent

		frameCreated += 1
	end

	--if #ImaginaryCreateQueue == 0 then
		local frameDestroyed = 0
		while #ImaginaryDestroyQueue > 0 and frameDestroyed < Settings.ImaginaryDestroyedStaticsPartsPerFrame do
			local v = table.remove(ImaginaryDestroyQueue)
			v:Destroy()

			frameDestroyed += 1
		end
	--end
	--]]

	--
	if Settings.UseGreedyMeshing and ActiveGMWorkerCount < Settings.GMWorkerCount then

		local AvailableDirtyGroups = {}

		for DestructionID, dirties in pairs(FlaggedDirty) do
			local found = false
			for _, info in ipairs(ShatterQueue) do
				if info.ID == DestructionID then
					found = true
					break
				end
			end
			if found then continue end

			found = false
			for _, dirty in ipairs(dirties) do
				if GreedyWorkers[dirty.DirtyParent] then
					found = true
					break
				end
			end
			if found then continue end

			AvailableDirtyGroups[DestructionID] = dirties
		end

		local DestructionID, Dirties = next(AvailableDirtyGroups)

		while DestructionID and ActiveGMWorkerCount < Settings.GMWorkerCount do

			if #Dirties == 0 then
				FlaggedDirty[DestructionID] = nil
				DestructionID, Dirties = next(AvailableDirtyGroups, DestructionID)
				continue
			end

			local dirtyInfo = table.remove(Dirties)
			local DirtyParent = dirtyInfo.DirtyParent

			if #DirtyParent:GetChildren() == 0 then continue end

			local thr = coroutine.create(GreedyMeshWorker)

			GreedyWorkers[DirtyParent] = thr
			ActiveGMWorkerCount += 1

			coroutine.resume(thr, DirtyParent, dirtyInfo.GridSize)
		end
	end

	if Settings.UseGreedyMeshing then
		for DirtyParent, worker in pairs(GreedyWorkers) do
			local status = coroutine.status(worker)

			if status == "dead" or (status == "suspended" and GreedyWorkersTerminationFlags[DirtyParent]) then
				GreedyWorkersTerminationFlags[DirtyParent] = nil
				GreedyWorkers[DirtyParent] = nil
				ActiveGMWorkerCount -= 1

			elseif status == "suspended" then
				coroutine.resume(worker)
			end
		end
	end
	--]]


	frameDivs, frameEncapsulated = 0, 0
	local ops = 0

	while #ShatterQueue > 0 and frameDivs < Settings.MaxDivisionsPerFrame and ops < Settings.MaxOpsPerFrame do
		ShatterWorker()
		ops += 1
	end


	if isClient then return end

	local PQL = #CreatePuppetQueue
	if PQL > 0 then
		local toReplicate = {}
		for _ = 1, math.min(PQL, Settings.PuppetReplicationFrameLimit) do
			local info = table.remove(CreatePuppetQueue)
			local serial = SerializedPartInstance(info[2])
			serial.GUID = info[1]
			table.insert(toReplicate, serial)
		end
		ServerEvents.CreatePuppets.FireAll(toReplicate)
	end

	accum += deltaTime
	local P = 1 / Settings.PuppetReplicationFrequency
	if accum > P then
		while accum > P do accum -= P end

		local puppetStates = {}
		for guid, puppetVoxel in pairs(Puppets) do

			local found
			for _, toCreate in ipairs(CreatePuppetQueue) do
				if toCreate[1] == guid then found = true break end
			end
			if found then continue end

			if puppetVoxel.AssemblyLinearVelocity.Magnitude <= Settings.PuppetSleepVelocity then continue end

			table.insert(puppetStates, {
				GUID = guid,
				CFrame = puppetVoxel.CFrame
			})
		end

		if #puppetStates > 0 then
			ServerEvents.ReplicatePuppetStates.FireAll(puppetStates)
		end
	end
end










Shatterbox.Settings = Settings


function Shatterbox.Puppeteer(voxel : Part)
	assert(isServer, "This function can only be called from the server")

	voxel.Anchored = false

	voxel.Parent = workspace.CurrentCamera

	local s, e = pcall(voxel.SetNetworkOwner, voxel, nil)
	if not s then
		warn("Failed to set the network owner of the Puppet, is it welded to an anchored part?\n" .. e)
	end

	local noSleepCon : RBXScriptConnection
	noSleepCon = RunService.Heartbeat:Connect(function(deltaTime)
		voxel:ApplyImpulse(Vector3.yAxis * -0.00001)
	end)

	local guid = HttpService:GenerateGUID(false)

	Puppets[guid] = voxel

	table.insert(CreatePuppetQueue, { guid, voxel })
	voxel.Destroying:Connect(function()
		noSleepCon:Disconnect()
		Puppets[guid] = nil

		local found
		for i, toCreate in ipairs(CreatePuppetQueue) do
			if toCreate[1] == guid then found = i break end
		end
		if found then table.remove(CreatePuppetQueue, found) end

		ServerEvents.DestroyPuppet.FireAll(guid)
	end)
end



-- Performs voxel destruction around the 'intersectingPart' according to the FilterTagged supplied.
--
-- if no FilterTagged is given, everything except IndestructibleTag tagged Block parts are considered for destruction.
function Shatterbox.Destroy(intersectingPart : Part | Model | Types.DestructionParams, FilterTagged : (string | {string})?, CleanupDelay : number?, OnVoxelDestruct : string?, GridSize : number?, SkipEncapsulatedVoxels : boolean?, OnDestructCompleted : (() -> ())?, ... : any)

	if ModelQueueBehavior(Shatterbox.Destroy, intersectingPart, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, ...) then
		return
	end

	local params = ValidateDestructionParams(intersectingPart, FilterTagged, CleanupDelay, OnVoxelDestruct, GridSize, SkipEncapsulatedVoxels, OnDestructCompleted, ...)

	params.DestroyedVoxels = 0

	task.defer(function()

		RunService.Heartbeat:Wait()

		if params.CleanupDelay < 0 then return end

		if #GetDestructibleParts(params.ID, params.CuttingPart, params.GridSize, params.FilterTagged) == 0 then
			return
		end

		-- starts the smooth cleanup counter
		if params.CleanupDelay > 0 and Settings.UseSmoothCleanup then task.delay(params.CleanupDelay, UndoDirtyOp, params.ID) end

		if USE_CLIENT_SERVER and isServer then
			ReplicateDestructionToClients(params, ServerEvents.ReplicateDestruction)
		end

		table.insert(ShatterQueue, params)
	end)
end


--*Yields until the NEXT Heartbeat to perform instant destruction.* <br>
--
--Performs voxel destruction around 'intersectingPart', skipping as many intermediate parts as possible. <br>
--
-- Returns an array of imaginary voxels for you to optionally create as debris.
function Shatterbox.ImaginaryVoxels(intersectingPart : Part | Model | Types.ImaginaryDestructionParams, FilterTagged : (string | {string})?, CleanupDelay : number?, GridSize : number?, SkipEncapsulatedVoxels : boolean?) : {Types.ImaginaryVoxel}

	local did, voxels = ModelQueueBehavior(Shatterbox.ImaginaryVoxels, intersectingPart, FilterTagged, CleanupDelay, nil, GridSize, SkipEncapsulatedVoxels, nil)
	if did then
		return voxels
	end

	local params = ValidateDestructionParams(intersectingPart, FilterTagged, CleanupDelay, nil, GridSize, SkipEncapsulatedVoxels)

	if params.CleanupDelay < 0 then return {} end

	voxels = voxels :: {Types.ImaginaryVoxel}

	if #GetDestructibleParts(params.ID, params.CuttingPart, params.GridSize, params.FilterTagged) == 0 then
		return voxels
	end

	if USE_CLIENT_SERVER and isServer then
		ReplicateDestructionToClients(params, ServerEvents.ReplicateImaginary)
	end

	RunService.Heartbeat:Wait()

	-- starts the smooth cleanup counter
	if params.CleanupDelay > 0 and Settings.UseSmoothCleanup then task.delay(params.CleanupDelay, UndoDirtyOp, params.ID) end

	return ImaginaryVoxels(params)
end

-- Will return a created voxel using the supplied ImaginaryVoxel, will automatically parent the voxel to the ShatterboxTemporary folder and give it the DebrisTag tag
function Shatterbox.InstantiateImaginaryVoxel(ImaginaryVoxel : Types.ImaginaryVoxel)

	local voxel = PartFromTemplate(ImaginaryVoxel.Original, ImaginaryVoxel.CFrame, CachedParts)
	voxel.Size = ImaginaryVoxel.Size
	--voxel:AddTag(DebrisTag)
	TaggingService.AddTag(voxel, DebrisTag)
	voxel.Parent = tmpFolder

	return voxel
end


--Resets an area rather than everything at once, without reverting the ownership of those parts
function Shatterbox.ResetArea(area : Part | Types.WorldInfo)

	local ACF, AS = area.CFrame, area.Size
	local AreaVerts = VertexMath.GetVerts.Block(ACF, AS)
	local AreaNormals = VertexMath.GetNormals.Block(ACF)

	local toResetIDs, toTerminate = {}, {}

	for ID, opDirty in pairs(opDirties) do

		local doResetWithThisID = false

		for _, dirtied in ipairs(opDirty.dirties) do --intersection test between the area and the original part that was destroyed (the original part can be of any shape for future compatibility)

			local originalPart = dirtied.Part
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
				doResetWithThisID = true
				break
			end
		end

		if doResetWithThisID then
			-- remove the operation from the queue if it is going to be reset and is still ongoing
			for i, op in ipairs(ShatterQueue) do
				if op.ID == ID then
					table.remove(ShatterQueue, i)
					break
				end
			end
			-- track all of the active greedy meshing workers that are a result of this destruction
			for _, dirtied in ipairs(opDirty.dirties) do
				if GreedyWorkers[dirtied.model] then
					table.insert(toTerminate, dirtied.model)
				end
			end
			-- flag this id for resetting
			table.insert(toResetIDs, ID)
		end
	end

	-- terminate all active greedy meshing workers in the area, then wait for them to terminate
	if #toTerminate > 0 then
		for _, dirtyParent in ipairs(toTerminate) do
			GreedyWorkersTerminationFlags[dirtyParent] = true
		end

		local doneWaiting = false
		repeat
			RunService.Heartbeat:Wait()

			for _, dirtyParent in ipairs(toTerminate) do
				if GreedyWorkers[dirtyParent] then continue end
				doneWaiting = true
			end
		until doneWaiting
	end

	-- revert all destructions bounded by the area
	for _, ID in pairs(toResetIDs) do UndoDirtyOp(ID, USE_CLIENT_SERVER and isClient) end
end


-- resets all modified parts to where they originally were (turning the map back to normal)
function Shatterbox.Reset(doNotRevertOwnership : boolean?)

	ShatterQueue = {}

	for dirtyParent in pairs(GreedyWorkers) do
		GreedyWorkersTerminationFlags[dirtyParent] = true
	end
	while ActiveGMWorkerCount > 0 do RunService.Heartbeat:Wait() end

	tmpFolder:ClearAllChildren()

	for ID in pairs(opDirties) do UndoDirtyOp(ID, USE_CLIENT_SERVER and isClient) end

	opDirties = {}

	if USE_CLIENT_SERVER and not doNotRevertOwnership then
		if isServer then
			workspace.CurrentCamera:ClearAllChildren()
			for _, toReset in pairs(ToReset) do
				for _, toRestore in ipairs(toReset) do
					local cloned = PartFromTemplate(toRestore.Part, toRestore.Part.CFrame, CachedParts)
					cloned.Parent = toRestore.OriginalParent
				end
			end
			ToReset = {}
			ServerEvents.SignalReset.FireAll()
		elseif isClient then
			clientMapFolder:ClearAllChildren()
		end
	end
end


-- Cancels any ongoing operations
function Shatterbox.ClearQueue()
	ShatterQueue = {}

	if USE_CLIENT_SERVER and isServer then ServerEvents.SignalClearQueue.FireAll() end
end


-- Creates a "Hitbox" object which can be used in place of the destruction functions, and has additional functionality. (like VoxBreaker moveable hitbox)
function Shatterbox.CreateHitbox()

	local hitbox = {}
	hitbox.CFrame = CFrame.new() :: CFrame
	hitbox.Size = Vector3.new(1, 1, 1) :: Vector3
	hitbox.Shape = Enum.PartType.Ball :: Enum.PartType

	hitbox.DestructDelay = nil :: number?

	hitbox.FilterTagged = nil :: (string | {string})?

	hitbox.OnVoxelDestruct = nil :: string?
	hitbox.DestructParameters = {} :: {any}

	hitbox.OnDestructCompleted = nil :: (() -> ())?

	hitbox.CleanupDelay = nil :: number?
	hitbox.GridSize = nil :: number?
	hitbox.SkipEncapsulatedVoxels = false :: boolean

	hitbox.DestructionType = "DEFAULT" :: ("DEFAULT"|"IMAGINARY")
	hitbox.ImaginaryCallback = nil :: ( (imaginaryVoxels : {Types.ImaginaryVoxel}) -> () )?

	hitbox.PollingEvent = RunService.Heartbeat -- the event that polls with a deltaTime parameter

	-- Performs voxel destruction around the hitbox
	function hitbox:Destroy() Shatterbox.Destroy(hitbox) end

	--*Yields until the NEXT Heartbeat to perform instant destruction.* <br>
	--
	-- returns the imaginary voxels bounded by the hitbox as an array, for you to optionally create
	function hitbox:ImaginaryVoxels() return Shatterbox.ImaginaryVoxels(hitbox) :: {Types.ImaginaryVoxel} end


	local wcon : RBXScriptConnection?
	local dcon : RBXScriptConnection?

	-- will "weld" the hitbox to the given part, continously setting its CFrame to be equal to the parts CFrame.
	-- If the Part is destroyed using ":Destroy()", the hitbox will be automatically stopped and disconnected.
	function hitbox:WeldTo(Part : BasePart)
		if wcon then wcon:Disconnect() end
		if dcon then dcon:Disconnect() end
		hitbox.CFrame = Part.CFrame
		wcon = RunService.PostSimulation:Connect(function() hitbox.CFrame = Part.CFrame end)
		dcon = Part.Destroying:Connect(hitbox.Destroy)
	end

	-- will "unweld" the hitbox
	function hitbox:Unweld()
		if wcon then wcon:Disconnect() end
		if dcon then dcon:Disconnect() end
		wcon, dcon = nil, nil
	end

	local ccon : RBXScriptConnection?
	local lastCut : number

	local function DestroyConnection()
		local t = time()
		if lastCut and t - lastCut < (hitbox.DestructDelay or 0.1) then return end
		lastCut = t

		if hitbox.DestructionType == "DEFAULT" then
			hitbox:Destroy()
		else
			local voxels = hitbox:ImaginaryVoxels()
			if hitbox.ImaginaryCallback then
				hitbox.ImaginaryCallback(voxels)
			end
		end
	end

	-- will continuously cut around the hitbox every hitbox.DestructDelay seconds, which defaults to 0.1
	function hitbox:Start()
		if ccon then return end
		ccon = hitbox.PollingEvent:Connect(DestroyConnection)
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


local cachedOriginalClones = {} :: { [Model] : Part }

local function deleteClone(model)
	cachedOriginalClones[model]:Destroy()
	cachedOriginalClones[model] = nil
end

-- Returns a clone of the original, untouched part (before it was ever voxelized).
--
-- This is used for effects like JJS where they obliterate walls but only minorly destroy what you are standing on.
--
-- If you use this within an OnVoxelDestruct callback, it is guaranteed to work.
--
-- Clones are cached for 5 seconds, so calling this function multiple times within that timeframe returns the same instance.
function Shatterbox.GetOriginalPart(dirtyParent : Model) : Part?
	local found = cachedOriginalClones[dirtyParent]
	if found then return found end

	for _, opDirty in pairs(opDirties) do
		for _, dirtied in ipairs(opDirty.dirties) do
			if dirtied.model == dirtyParent then
				local clone = dirtied.Part:Clone()
				cachedOriginalClones[dirtyParent] = clone
				task.delay(5, deleteClone, dirtyParent)
				return clone
			end
		end
	end

	return nil
end


-- Will return true if "contains" is FULLY contained by "part", otherwise false
function Shatterbox.PartEncapsulatesBlockPart(part : Part, contains : Part)
	assert(part:IsA("Part"), "You can only use this function when a Part is the container.")
	assert(contains:IsA("Part") and contains.Shape == Enum.PartType.Block, "You can only use this function when a Block Part is the contained object.")	
	return PartEncapsulatesBlockPart(part, contains.CFrame, contains.Size)
end


-- Will register the given callback to the given name. It's suggested you do this at the top of the module instead, otherwise it is only registered on the side you called this function from.
function Shatterbox.RegisterOnVoxelDestruct(name : string, callback : Types.OnVoxelDestruct) RegisterOnVoxelDestruct(name, callback, callback) end


-- Will wait for the given OnVoxelDestruct callback to be registered with a default timeout of 5 seconds
function Shatterbox.WaitForRegistry(name : string, timeout : number?) : string
	timeout = timeout or 5
	local elapsed, start = 0, time()	
	while elapsed < timeout and not rawget(OnVoxelDestructRegistry, name:lower()) do
		RunService.Heartbeat:Wait()
		elapsed = time() - start
	end
	if elapsed > timeout then warn(`Infinite yield possible on WaitForRegistry("{name}")`) end
	return name
end

Shatterbox.Voxelize = Voxelize

Shatterbox.OnVoxelDestruct = HandleVoxelDestruction

Shatterbox.VertexMath = VertexMath




--[[
local function recursivePrint(x, k, spacing)

	spacing = spacing or ""

	if type(x) ~= "table" then

		print(`{spacing}[{k}] = {x}`)

		return
	end

	print(spacing .. (k and `[{k}] = ` or "") .. "{")

	for k, v in pairs(x) do recursivePrint(v, k, spacing .. "  ") end

	print(spacing .. "}")
end
--]]

-- Debug function to print the state of all of the local variables
local function PrintState()

	local str = `SHATTERBOX ({isServer and "SERVER" or "CLIENT"})`

	str = str .. "\n|\n| ShatterQueue length: " .. #ShatterQueue

	str = str .. "\n|\n| opDirties = {"
	for ID in pairs(opDirties) do
		str = str .."\n|   " .. ID
	end
	str = str .. "\n| }"

	print(str)
end

function Shatterbox.PrintState()

	if isServer then ServerEvents.SignalPrintState.FireAll() end

	PrintState()
end



-- Create connections

if isServer then

	if USE_CLIENT_SERVER then
		ServerEvents.ClientInitComplete.On(ReplicateMapToNewPlayer)
	end

elseif isClient then

	if USE_CLIENT_SERVER then
		ClientEvents.SignalUndo.On(function(ID : string) UndoDirtyOp(ID, true) end)
		ClientEvents.SignalClearQueue.On(Shatterbox.ClearQueue)
		ClientEvents.SignalReset.On(Shatterbox.Reset)

		ClientEvents.ReplicateMap.On(ReplicateMapFromServer)
		ClientEvents.ReplicateDestruction.On(ReplicateDestructionFromServer)
		ClientEvents.ReplicateImaginary.On(ReplicateImaginaryFromServer)

		ClientEvents.ClientInitComplete.Fire()
	end

	ClientEvents.CreatePuppets.On(CreatePuppets)
	ClientEvents.ReplicatePuppetStates.On(ReplicatePuppetStates)
	ClientEvents.DestroyPuppet.On(DestroyPuppet)

	ClientEvents.SignalPrintState.On(PrintState)
end

RunService.Heartbeat:Connect(HeartbeatWorker)



return Shatterbox