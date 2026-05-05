-- WIP REFACTORING

local lib = script.Parent
local src = lib.Parent

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local isServer, isClient = RunService:IsServer(), RunService:IsClient()

local Settings = require(src:WaitForChild("Settings"))

local Types = require(src:WaitForChild("Types"))

local USE_CLIENT_SERVER = Settings.USE_CLIENT_SERVER
local USE_OBJECT_CACHE = Settings.USE_OBJECT_CACHE
local PUPPET_TWEEN_MODE = Settings.PUPPET_TWEEN_MODE

local IMAGINARY, NORMAL = "IMAGINARY", "NORMAL"
type DestructionTypes = ("IMAGINARY"|"NORMAL")

local EPSILON = 1e-3

local State = {}

local OnVoxelDestructRegistry = setmetatable({}, {
	__index = function(tbl, k) return (k and rawget(tbl, k:lower())) end
}) :: { [string] : Types.OnVoxelDestruct }

local OnDestructCompletedRegistry = setmetatable({}, {
	__index = function(tbl, k) return (k and rawget(tbl, k:lower())) end
}) :: { [string] : Types.OnDestructCompleted }


local StepReplication, ClientEvents, ServerEvents, mapContainer
if isServer then
	ServerEvents = require(lib.Blink.Server)
	StepReplication = ServerEvents.StepReplication

	mapContainer = workspace.CurrentCamera

	local serverCallbacks = require(src.effects.Server)
	serverCallbacks:SetReference(Shatterbox)
	for name, func in pairs(serverCallbacks.OnVoxelDestruct) do OnVoxelDestructRegistry[name:lower()] = func end
	for name, func in pairs(serverCallbacks.OnDestructCompleted) do OnDestructCompletedRegistry[name:lower()] = func end
elseif isClient then
	ClientEvents = require(lib:WaitForChild("Blink"):WaitForChild("Client"))
	StepReplication = ClientEvents.StepReplication

	mapContainer = workspace:FindFirstChild("ClientMap")
	if not mapContainer then
		mapContainer = Instance.new("Folder")
		mapContainer.Parent = workspace
		mapContainer.Name = "ClientMap"
	end

	local clientCallbacks = require(src:WaitForChild("effects"):WaitForChild("Client"))
	clientCallbacks:SetReference(Shatterbox)
	for name, func in pairs(clientCallbacks.OnVoxelDestruct) do OnVoxelDestructRegistry[name:lower()] = func end
	for name, func in pairs(clientCallbacks.OnDestructCompleted) do OnDestructCompletedRegistry[name:lower()] = func end
end

local ObjectCache, CachedParts
if USE_OBJECT_CACHE then

	local TemplatePart = Instance.new("Part")
	TemplatePart.Anchored = true
	TemplatePart.CanCollide = false

	ObjectCache = require(lib:WaitForChild("ObjectCache"))

	local cacheContainer = mapContainer

	CachedParts = ObjectCache.new(TemplatePart, Settings.CACHE_INITIAL_SIZE, cacheContainer)
end



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

-- Dirty groups waiting to be greedy meshed [DirtyGroupID] : GridSize
local GreedyMeshingQueue = {} :: { [string] : number }
local GreedyMeshedImaginaryParts = {} :: { Types.ImaginaryBox }

local NewPlayerStateReplicationQueue = {} :: {Player}


local PuppeteerState = {}
State.PuppeteerState = PuppeteerState
-- Elements of the Puppets array are of the form {Part, boolean} where the Part is the puppet master/slave (server side master, client side slave) and the boolean is whether or not that puppet is getting interpolated.
PuppeteerState.Puppets = {} :: { {} }
-- How many replication steps the client thinks it will take for a single puppet to recieve its next update.
PuppeteerState.StepDelta = 1
-- Stores the interpolation start/end for the corresponding element of the Puppets array. On the server side this is the state replication queue
PuppeteerState.LerpData = {} :: { {CFrame} }
-- Index that increments every time a puppet is created if the Puppets array is full, and loops back to 1 when the maximum puppet count is reached.
-- When this happens, the oldest puppets are destroyed as new ones spawn in
PuppeteerState.NextIndex = 1
-- Which puppet is next in line to recieve a CFrame update.
PuppeteerState.NextReplicationIndex = 1
-- A queue of parts waiting to replicate to each client as Puppets.
PuppeteerState.CreatePuppetQueue = {}


State.ChangedDirtyGroups = {}

State.FallingGroupSectionAnchors = {} :: { Part }

-- accumulation variable to manage the puppeteer loop
State.puppetTimeAccumulation = 0


local PreAllocated = {}
State.PreAllocated = PreAllocated
-- Pre-allocated OverlapParams used when FilterTagged is supplied
PreAllocated.OverlapParams = OverlapParams.new()
-- Pre-allocated RaycastParams when SkipWalls or SkipFloors is enabled
local raycastParams = RaycastParams.new()
PreAllocated.RaycastParams = raycastParams
raycastParams.FilterType = Enum.RaycastFilterType.Include
-- pre-allocated part instance which is used to get the parts whenever `GetPartsInPart` is needed
PreAllocated.IntersectingPart = Instance.new("Part")






-- flag used to pause replicating events until the server has replicated it's state
State.clientInitComplete = false


-- boolean used to determine whether or not to update the cache (I have modified ObjectCache to manually do these calls)
State.ScheduledUpdate = false



return State