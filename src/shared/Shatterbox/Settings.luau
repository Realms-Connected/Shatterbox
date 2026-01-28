--#selene: allow(unused_variable)

local Settings = {}

-- These all-caps named settings cannot be changed at runtime. The rest are okay to do so.

Settings.USE_CLIENT_SERVER = true -- Set this to false if you don't want to use client-server functionality (false = fully server side destructions)

--Settings.USE_OBJECTCACHE = false -- whether or not to use ObjectCache (not fully implemented)
--	Settings.CACHE_INITIAL_SIZE = 10000 -- The initial size of the part Caches



Settings.SkipInstanceCheck = function(i : Instance)

	-- return true if you want to skip the instance "i"

	return false
end



Settings.NonDivisibleInteraction = "FALL" :: "FALL"|"DESTROY"|"NONE" -- What happens to destructible parts that cannot be divided by Shatterbox



-- Smooth cleanup settings

Settings.UseSmoothCleanup = true -- If false, the CleanupDelay will be ignored and no smooth cleanups will happen at all.

Settings.DefaultSmoothCleanupDelay = 60 -- the default smooth cleanup delay if none is provided. Setting the CleanupDelay to 0 or a negative number disables smooth cleanup for that destruction.


-- Part division settings

Settings.MaxDivisionsPerFrame = 1000 -- Limits the count of part subdivisions per frame using `Destroy` (1 division = up to 8 new parts before greedy meshing)

Settings.DefaultGridSize = 1

Settings.MaxOpsPerFrame = 10 -- Limits the number of calls to GetPartsInPart every frame using `Destroy`

Settings.UsePriorityQueue = true -- If true, newer operations take precedence over old ones, if false, round-robin processing is used
	Settings.PrioritizeRecentN = 10 -- If using priority queue, the most recent N (default 10) operations are prioritized using round-robin



-- Greedy meshing settings

Settings.UseGreedyMeshing = true

Settings.GMTraversalsPerFrame = 10000 -- How many times greedy meshing can iterate through a 3D grid for each worker. Effectively limits the number of visited cells per frame

Settings.GMPartCreationsPerFrame = 500 -- How many parts greedy meshing should try to make every frame once the worker is finished traversing. This is a soft-limit, not a hard-limit, for smooth visual display

Settings.GMWorkerCount = 5 -- How many greedy meshing workers there are. Each worker performs calculations for a single dirty group before displaying the meshed output



-- Puppet voxel settings

Settings.PuppetMaxCount = 8191 -- HARD CAP 8191

Settings.PuppetSleepVelocity = 0.1 -- How slow a puppet has to be moving to not get replicated (and eventually become anchored)

Settings.PuppetAnchorTimeout = 1 -- How long a puppet master moving slower than PuppetSleepVelocity has before becoming anchored (seconds)

Settings.PuppetReplicationFrequency = 20 -- How frequently puppet CFrames are sent to each client (default 20 fps/Hz target replication frequency)

Settings.ClientTweenPuppets = true -- If true, the client will tween between puppet CFrame replications (Client-side only setting)

Settings.ClientTweenDistanceLimit = 300 -- Voxels farther than 100 studs away don't get interpolated



return Settings