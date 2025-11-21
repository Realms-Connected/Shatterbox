--#selene: allow(unused_variable)
--#selene: allow(multiple_statements)

local Shatterbox
local Types = require(script.Parent.Parent:WaitForChild("Types"))

local ServerEffects = {} :: { [string] : Types.OnVoxelDestruct }

-- Do not use this function, it just lets you use the Shatterbox functions in this module (avoiding a cyclic dependancy)
function ServerEffects:SetReference(shatterbox) Shatterbox = shatterbox end




-- define your server side effects here. Defining the same effect name on both sides causes the effect to do different things on server and client sides.
--[[

ServerEffects.EffectName = function(voxel, dirtyParent, cuttingPart, isEdge)


end

]]








-- The default client behavior (for when an OnVoxelDestruct callback does not exist)
ServerEffects.Default = function(voxel) voxel:Destroy() end




ServerEffects.FlyingDebris = function(voxel, DirtyGroupID, cuttingPart, isEdge, isAlreadyDebris)
    voxel.Anchored = false
    voxel.CanCollide = false
    voxel.AssemblyLinearVelocity = (Vector3.new(math.random(), math.random(), math.random()) - Vector3.one * 0.5) * 80
    voxel.AssemblyAngularVelocity = (Vector3.new(math.random(), math.random(), math.random()) - Vector3.one * 0.5) * 20

    game.Debris:AddItem(voxel, 3)
end





-- An example effect that attempts to re-create the M1 destructions from JJS.
-- Debris is tweened by clients, having the CFrames replicateed from the server.
-- Only non-floors turn into debris (a floor has a vertical normal when casting toward it from the cuttingPart).
-- Floors have a separate effect that makes them appear "broken".

-- Pre-allocated RaycastParams instance
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
ServerEffects.BumpyFloorBreakWalls = function(voxel, DirtyGroupID, cuttingPart, isEdge, isAlreadyDebris)
    local O = cuttingPart.CFrame.Position
    -- retrieves the untouched original part, to check if the voxel should be considered a floor
    local castTo = Shatterbox.GetOriginalPart(DirtyGroupID)

    raycastParams.FilterDescendantsInstances = { castTo }

    castTo.Parent = workspace
    local hitResult = workspace:Raycast(O, voxel.Position - O, raycastParams)
    castTo.Parent = nil

    if isAlreadyDebris then

        voxel.AssemblyLinearVelocity = -hitResult.Normal * (math.random() * 25 + 50)

    elseif hitResult.Normal:FuzzyEq(Vector3.yAxis, 0.01) then -- if the normal is facing up, it is a floor

        voxel.Position += Vector3.yAxis * (math.random() - 0.5) -- add some random vertical offset to floor voxels

    else -- everything else becomes a falling voxel using puppeteer
        voxel.Anchored = false

        Shatterbox.Puppeteer(voxel) -- start controlled replication of "voxel" to clients (tween between replication of CFrames)

        voxel.AssemblyLinearVelocity = -hitResult.Normal * (math.random() * 25 + 50)
    end
end





return ServerEffects