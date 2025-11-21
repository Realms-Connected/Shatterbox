--#selene: allow(incorrect_standard_library_use)
--#selene: allow(multiple_statements)

-- PartOperations contains functions that perform operations on an individual part (subdivide, voxelize, etc.)

local Settings = require(script.Parent.Parent:WaitForChild("Settings"))


type PartType = {CFrame : CFrame, Size : Vector3}


local localAxisVectors = { X = "RightVector", Y = "UpVector", Z = "ZVector" }


--[[
    Creates a new part using the supplied `template`, which is either a Part instance or a serialized Part instance

    A CFrame can be supplied which is where the part will be placed.
]]
local function PartFromTemplate(template, cframe, provider)
	local part

	--debug.profilebegin("create part")

	if provider and #provider._FreeObjects > 0 then
		part = provider:GetPart(cframe)
	else
		--if provider then warn("cache length exceeded : " .. #provider._FreeObjects) end
		part = Instance.new("Part")
		if cframe then
			part.CFrame = cframe
		end
	end

	-- Set properties if they are not their defaults
	local prop

	prop = template.Anchored
    if prop ~= part.Anchored then part.Anchored = prop end

	prop = template.Size
    if prop ~= part.Size then part.Size = prop end

	--part.Color = Color3.fromHSV(math.random(), 1, 1)
	prop = template.Color
    if prop ~= part.Color then part.Color = prop end

	prop = template.Transparency
    if prop ~= part.Transparency then part.Transparency = prop end

	prop = template.Reflectance
    if prop ~= part.Reflectance then part.Reflectance = prop end

	prop = template.Material
    if prop ~= part.Material then part.Material = prop end

	prop = template.MaterialVariant
    if prop ~= part.MaterialVariant then part.MaterialVariant = prop end

	prop = template.CollisionGroup
    if prop ~= part.CollisionGroup then part.CollisionGroup = prop end

	-- copy tags
	for _, tag in ipairs(template:GetTags()) do part:AddTag(tag) end

	-- copy attributes
	for k, v in pairs(template:GetAttributes()) do part:SetAttribute(k, v) end

	-- copy textures
	for _, child in ipairs(template:GetChildren()) do
		if child:IsA("Texture") then child:Clone().Parent = part end
	end

	--debug.profileend()

	return part
end




--[[
    Deserializes the given serialized part instance `p`
]]
local function DeserializedPartInstance(p, provider)

	local part

	if provider and #provider._FreeObjects > 0 then
		part = provider:GetPart(p.CFrame)
	else
		--if provider then warn("cache length exceeded : " .. #provider._FreeObjects) end
		part = Instance.new("Part")
		if p.CFrame then
			part.CFrame = p.CFrame
		end
	end

	if p.Anchored then part.Anchored = true end

	-- Set properties if they are not their defaults
	local prop

	prop = p.Size
	if prop then part.Size = prop end

	--part.Color = Color3.fromHSV(math.random(), 1, 1)
	prop = p.Color
    if prop then part.Color = prop end

	prop = p.Transparency
    if prop then part.Transparency = prop end

	prop = p.Reflectance
    if prop then part.Reflectance = prop end

	prop = p.Material
    if prop then part.Material = Enum.Material:FromValue(prop) end

	prop = p.MaterialVariant
    if prop then part.MaterialVariant = prop end

	prop = p.CollisionGroup
    if prop then part.CollisionGroup = prop end

	-- deserialize tags
	for _, tag in ipairs(p.Tags) do part:AddTag(tag) end

	-- deserialize attributes
	for k, v in pairs(p.Attributes) do part:SetAttribute(k, v) end

	-- deserialize textures
	for _, serialTexture in ipairs(p.Textures) do
		local instancedTexture = Instance.new("Texture")
		instancedTexture.Color3 = serialTexture.Color3
		instancedTexture.OffsetStudsU = serialTexture.OffsetStudsU
		instancedTexture.OffsetStudsV = serialTexture.OffsetStudsV
		instancedTexture.StudsPerTileU = serialTexture.StudsPerTileU
		instancedTexture.StudsPerTileV = serialTexture.StudsPerTileV
		instancedTexture.Texture = serialTexture.Texture
		instancedTexture.Transparency = serialTexture.Transparency
		instancedTexture.ZIndex = serialTexture.ZIndex
		instancedTexture.Face = Enum.NormalId:FromValue(serialTexture.Face)
		instancedTexture.Parent = part
	end

	return part
end




--[[
    Serializes the given part instance `p`
]]
local function SerializedPartInstance(p, ignoreWorldState)
	local serial = {
		Color = p.Color,

		Tags = p:GetTags(),
		Attributes = p:GetAttributes()
	}

	-- serialize properties if they are not their defaults
	local prop

	serial.Anchored = p.Anchored

	prop = p.Transparency
    if prop ~= 0 then serial.Transparency = prop end

	prop = p.Reflectance
    if prop ~= 0 then serial.Reflectance = prop end

	prop = p.Material
    if prop ~= Enum.Material.Plastic then serial.Material = prop.Value end

	prop = p.MaterialVariant
    if #prop > 0 then serial.MaterialVariant = prop end

	prop = p.CollisionGroup
    if prop ~= "Default" then serial.CollisionGroup = prop end

	-- serialize textures
	local textures = {}
	for _, child in ipairs(p:GetChildren()) do
		if child:IsA("Texture") then
			local serialTexture = {}
			serialTexture.Color3 = child.Color3
			serialTexture.OffsetStudsU = child.OffsetStudsU
			serialTexture.OffsetStudsV = child.OffsetStudsV
			serialTexture.StudsPerTileU = child.StudsPerTileU
			serialTexture.StudsPerTileV = child.StudsPerTileV
			serialTexture.Texture = child.Texture
			serialTexture.Transparency = child.Transparency
			serialTexture.ZIndex = child.ZIndex
			serialTexture.Face = child.Face.Value

			table.insert(textures, serialTexture)
		end
	end
	serial.Textures = textures

	if not ignoreWorldState then
		serial.CFrame = p.CFrame
		serial.Size = p.Size
	end

	return serial
end




--[[
    Returns all of the relevant information to construct a grid of voxels using the specified parameters

    Return values (in order):

    \> Minimum cframe (first voxel) : CFrame

    \> Maximum cframe (last voxel) : CFrame


    \> Voxel size : Vector3


    \> Local axis X scaled by voxel size X : Vector3

    \> Local axis Y scaled by voxel size Y : Vector3

    \> Local axis Z scaled by voxel size Z : Vector3


    \> Voxel count X : number

    \> Voxel count Y : number

    \> Voxel count Z : number
]]
local function GridInfo(PartCFrame : CFrame, PartSize : Vector3, GridSize : number)
	local DIM = Vector3.one:Max(PartSize // GridSize)
	local NVX, NVY, NVZ = DIM.X, DIM.Y, DIM.Z

	local VoxelSize = PartSize / DIM
	local VSX, VSY, VSZ = VoxelSize.X, VoxelSize.Y, VoxelSize.Z

	local lsx, lsy, lsz = PartCFrame.XVector*VSX, PartCFrame.YVector*VSY, PartCFrame.ZVector*VSZ

	local ExtentOffset = 0.5*( lsx*(NVX - 1) + lsy*(NVY - 1) + lsz*(NVZ - 1) )

	return (PartCFrame - ExtentOffset):Orthonormalize(),
		   (PartCFrame + ExtentOffset):Orthonormalize(),
		   VoxelSize,
		   lsx, lsy, lsz,
		   NVX, NVY, NVZ
end




--[[ I wonder if anyone has done this before.

    Voxelizes a part (or imaginary part) completely according to the GridSize supplied. Returns an array of imaginary box parts.

    The returned table is created with proper allocation size using `table.create`
]]
local function ImaginaryVoxelize(Part : PartType, GridSize : number?) : {PartType}

	GridSize = GridSize or Settings.DefaultGridSize

    local count = Vector3.one:Max(Part.Size // GridSize)
	if count.X*count.Y*count.Z == 1 then
		return {Part}
	end

	local O, _, S, lsx, lsy, lsz, NVX, NVY, NVZ = GridInfo(Part.CFrame, Part.Size, GridSize)

	local imaginaryParts, index = table.create(NVX*NVY*NVZ), 0

	for X = 0, NVX - 1 do
		local dx = X*lsx
		for Y = 0, NVY - 1 do
			local dy = Y*lsy
			for Z = 0, NVZ - 1 do
				index += 1
				imaginaryParts[index] = {
					CFrame = (O + dx + dy + Z*lsz):Orthonormalize(),
					Size = S
				}
			end
		end
	end

	return imaginaryParts
end




--[[
    Completely voxelizes a given part down to a specified GridSize, or uses the default GridSize specified in the Settings.

    Returns the created voxels as an array.

    Optimized by using math to fully subdivide a part before creating only the final voxels. However, it effectively has an O(N^3) runtime due to the nature of 3D grids.
]]
local function Voxelize(Part : Part, GridSize : number?) : {Part}

    GridSize = GridSize or Settings.DefaultGridSize

    local count = Vector3.one:Max(Part.Size // GridSize)
	if count.X*count.Y*count.Z == 1 then
		return {Part}
	end

    local O, _, S, lsx, lsy, lsz, NVX, NVY, NVZ = GridInfo(Part.CFrame, Part.Size, GridSize)

	local createdParts, index = table.create(NVX*NVY*NVZ), 0

    for X = 0, NVX - 1 do
		local dx = X*lsx
		for Y = 0, NVY - 1 do
			local dy = Y*lsy
			for Z = 0, NVZ - 1 do
				index += 1

                local created = PartFromTemplate(Part, O + dx + dy + Z*lsz)
                created.Size = S
                created.Parent = Part.Parent

                createdParts[index] = created
			end
		end
	end

    Part:Destroy()

	return createdParts
end




--[[ Modified Octree Subdivide

    Does not mutate the supplied Part reference, which is meant to be an object with the structure {Size : Vector3, CFrame : CFrame}

    Returns an array with the structure { {Size : Vector3, CFrame : CFrame} }

    If possible, calculates the division of a part into 2, 4, or 8 pieces.

    Maintains grid structure for odd parity divisions.
]]
local function SubdivideOctree(Part : PartType, GridSize : number)
	local PartSize = Part.Size
	local Axis = {}

    -- gather all valid subdivision axis
	for axis in pairs(localAxisVectors) do
		if PartSize[axis] * 0.5 < GridSize then continue end
		table.insert(Axis, axis)
	end

	if #Axis == 0 then return nil end

	local createdParts = { { CFrame = Part.CFrame, Size = PartSize } }
	local tmpParts = {}

    -- Subdivide all createdParts along each valid axis, updating the createdParts array.
	for _, axis in pairs(Axis) do
		local ax, ay, az = axis == "X", axis == "Y", axis == "Z"
		local l_axis = localAxisVectors[axis]

		for _, part in pairs(createdParts) do
			local size = part.Size
            local hs, cframe = size[axis] * 0.5, part.CFrame
            local la = cframe[l_axis]

            local numVoxels = size[axis] // GridSize
            if numVoxels % 2 == 0 then

                local hla = la * 0.5 * hs
                local ps = Vector3.new( (ax and hs or size.X), (ay and hs or size.Y), (az and hs or size.Z) )
                table.insert(tmpParts, {
                    CFrame = (cframe + hla):Orthonormalize(),
                    Size = ps
                })
                table.insert(tmpParts, {
                    CFrame = (cframe - hla):Orthonormalize(),
                    Size = ps
                })
            else
                local vs = size[axis] / numVoxels
                local FHV, CHV = vs * math.floor(numVoxels * 0.5), vs * math.ceil(numVoxels * 0.5)

                local off = CHV * 0.5
                table.insert(tmpParts, {
                    CFrame = (cframe - off * la):Orthonormalize(),
                    Size = Vector3.new(
                        ax and FHV or size.X,
                        ay and FHV or size.Y,
                        az and FHV or size.Z
                    )
                })
                off = FHV * 0.5
                table.insert(tmpParts, {
                    CFrame = (cframe + off * la):Orthonormalize(),
                    Size = Vector3.new(
                        ax and CHV or size.X,
                        ay and CHV or size.Y,
                        az and CHV or size.Z
                    )
                })
            end
		end

		createdParts = tmpParts
		tmpParts = {}
	end

	return createdParts
end




--[[ Modified KD-tree Subdivide

    Does not mutate the supplied Part reference, which is meant to be an object with the structure {Size : Vector3, CFrame : CFrame}

    Returns an array with the structure { {Size : Vector3, CFrame : CFrame} }

    If possible, calculates the division of a part into 2 pieces.

    Maintains grid structure for odd parity divisions.
]]
local function SubdivideKD(Part : PartType, GridSize : number)
	local PartSize = Part.Size
	local axis, maxSize

	for a in pairs(localAxisVectors) do
		local PartSizeAxis = PartSize[a]
		if PartSizeAxis * 0.5 < GridSize then continue end
		if axis and maxSize > PartSizeAxis then continue end
		axis, maxSize = a, PartSizeAxis
	end

    if not axis then return nil end

    local hs = PartSize[axis] * 0.5
    local cframe = Part.CFrame

    local numVoxels = PartSize[axis] // GridSize
    if numVoxels % 2 == 0 then

        local hla = cframe[localAxisVectors[axis]] * 0.5 * hs

        local ps = Vector3.new(
            axis == "X" and hs or PartSize.X,
            axis == "Y" and hs or PartSize.Y,
            axis == "Z" and hs or PartSize.Z
        )

        return { { CFrame = (cframe + hla):Orthonormalize(), Size = ps }, { CFrame = (cframe - hla):Orthonormalize(), Size = ps } }
    else
        local AX, AY, AZ = axis == "X", axis == "Y", axis == "Z"
        local la = cframe[localAxisVectors[axis]]
        local vs = PartSize[axis] / numVoxels

        local createdParts = table.create(2)

        local FHV, CHV = vs * math.floor(numVoxels * 0.5), vs * math.ceil(numVoxels * 0.5)

        local off = CHV * 0.5
        createdParts[1] = {
            CFrame = (cframe - off * la):Orthonormalize(),
            Size = Vector3.new(
                AX and FHV or PartSize.X,
                AY and FHV or PartSize.Y,
                AZ and FHV or PartSize.Z
            )
        }

        off = FHV * 0.5
        createdParts[2] = {
            CFrame = (cframe + off * la):Orthonormalize(),
            Size = Vector3.new(
                AX and CHV or PartSize.X,
                AY and CHV or PartSize.Y,
                AZ and CHV or PartSize.Z
            )
        }

        return createdParts
    end
end




local PartOperations = {}

PartOperations.PartFromTemplate = PartFromTemplate

PartOperations.DeserializedPartInstance = DeserializedPartInstance

PartOperations.SerializedPartInstance = SerializedPartInstance

PartOperations.GridInfo = GridInfo

PartOperations.ImaginaryVoxelize = ImaginaryVoxelize

PartOperations.Voxelize = Voxelize

PartOperations.SubdivideOctree = SubdivideOctree

PartOperations.SubdivideKD = SubdivideKD

return PartOperations