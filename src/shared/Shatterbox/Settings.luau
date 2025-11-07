
local Settings = {}


-- Set this to false if you don't want to use client-server functionality (false = fully server side destructions)
-- This is not a hot-setting, so you can't change it at runtime
Settings.USE_CLIENT_SERVER = true

-- whether or not to use ObjectCache (I don't actually think it improves performance by very much at all because of all of the properties that have to be set)
Settings.USE_OBJECTCACHE = false

-- The initial size of the part Caches
Settings.CACHE_INITIAL_SIZE = 10000





Settings.SkipInstanceCheck = function(i : Instance)

	-- return true if you want to skip the instance "i"

	return false
end




-- Smooth cleanup settings

Settings.UseSmoothCleanup = false -- If false, the CleanupDelay will be ignored and no smooth cleanups will happen at all.

Settings.DefaultSmoothCleanupDelay = 60

--Settings.UseDynamicReset = true -- If true, Shatterbox.Reset() will be called when there are no destructions on the map. (turning the hierarchy back to normal)

--Settings.DynamicResetDelay = 3 -- How long Shatterbox will wait after there are no destructions to call Shatterbox.Reset()




-- Part division settings

Settings.DefaultGridSize = 1

Settings.MaxDivisionsPerFrame = 200 -- Limits the count of part subdivisions per frame using `Destroy` (1 division = up to 8 new parts)

--Settings.MaxEncapsulatedVoxelsPerFrame = 3000 -- Limits the number of voxels created by encapsulated parts per frame

Settings.MaxOpsPerFrame = 10 -- Limits the number of calls to GetPartsInPart every frame using `Destroy`

Settings.UsePriorityQueue = true -- If true, newer operations take precedence over old ones, if false, round-robin processing is used

Settings.PrioritizeRecentN = 10 -- If using priority queue, the most recent N (default 10) operations are prioritized using round-robin

--Settings.ImaginaryCreatedStaticPartsPerFrame = 50 

--Settings.ImaginaryDestroyedStaticsPartsPerFrame = 200




-- Puppet voxel settings

Settings.PuppetReplicationFrequency = 20 -- How frequently puppet CFrames are sent to each client (default 20 fps/Hz target replication frequency)

Settings.ClientTweenPuppets = true -- If true, the client will tween between puppet CFrame replications (Client-side only setting)

Settings.PuppetReplicationFrameLimit = 10 -- How many puppets can be created and sent to clients per frame

Settings.PuppetSleepVelocity = 0.1 -- How slow a puppet has to be moving to not get replicated




-- Greedy meshing settings

Settings.UseGreedyMeshing = false

Settings.GMTraversalsPerFrame = 500 -- How many times greedy meshing can iterate through a 3D grid for each worker. Effectively limits the number of visited cells per frame

Settings.GMPartCreationsPerFrame = 5 -- How many parts greedy meshing should try to make every frame once the worker is finished traversing. This is a soft-limit, not a hard-limit, for smooth visual display

Settings.GMWorkerCount = 5 -- How many greedy meshing workers there are. Each worker performs calculations for a single `dirtyParent` model







return Settings