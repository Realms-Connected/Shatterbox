--#selene: allow(incorrect_standard_library_use)
--#selene: allow(multiple_statements)

-- PartOperations contains functions that perform operations on an individual part (subdivide, voxelize, etc.)

local Settings = require(script.Parent.Parent:WaitForChild("Settings"))


type PartType = {CFrame : CFrame, Size : Vector3}


local localAxisVectors = { X = "RightVector", Y = "UpVector", Z = "ZVector" }

local WHITE = Color3.new(1, 1, 1)
local MEDIUMSTONEGREY = Color3.fromRGB(163, 162, 165)


-- Serializes the given decal instance
local function SerializedDecalInstance(decal : Decal)
	local serialDecal = {}

	local prop = decal.Color3
	if prop ~= WHITE then serialDecal.Color3 = prop end

	prop = #decal.ColorMap > 0 and decal.ColorMap or decal.Texture
	if #prop > 0 then serialDecal.ColorMap = prop end

	prop = decal.Transparency
	if prop ~= 0 then serialDecal.Transparency = prop end

	prop = decal.UVOffset
	if prop ~= Vector2.zero then serialDecal.UVOffset = prop end
	prop = decal.UVScale
	if prop ~= Vector2.one then serialDecal.UVScale = prop end

	prop = decal.ZIndex
	if prop ~= 1 then serialDecal.ZIndex = prop end

	prop = decal.Face.Value
	if prop ~= 5 then serialDecal.Face = prop end

	return serialDecal
end

local function DeserializedDecalInstance(serialDecal, ClassName)

	local decal = Instance.new(ClassName)

	local prop = serialDecal.Color3
	if prop then decal.Color3 = prop end

	prop = serialDecal.ColorMap
	if prop then decal.ColorMap = prop end

	prop = serialDecal.Transparency
	if prop then decal.Transparency = prop end

	prop = serialDecal.UVOffset
	if prop then decal.UVOffset = prop end
	prop = serialDecal.UVScale
	if prop then decal.UVScale = prop end

	prop = serialDecal.ZIndex
	if prop then decal.ZIndex = prop end

	prop = serialDecal.Face
	if prop then decal.Face = Enum.NormalId:FromValue(prop) end

	return decal
end




--[[
    Creates a new part using the supplied `template`, which is either a Part instance or a serialized Part instance

    A CFrame can be supplied which is where the part will be placed.
]]
local function PartFromTemplate(template, cframe, provider)

	if not template:IsA("Part") or template.Shape ~= Enum.PartType.Block then
		local cloned = template:Clone()
		if cframe then cloned.CFrame = cframe end
		return cloned
	end

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

    if not part.Anchored then part.Anchored = true end

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

	-- copy surface property values
	prop = template.RightSurface
    if prop ~= part.RightSurface then part.RightSurface = prop end
	prop = template.LeftSurface
    if prop ~= part.LeftSurface then part.LeftSurface = prop end
	prop = template.FrontSurface
    if prop ~= part.FrontSurface then part.FrontSurface = prop end
	prop = template.BackSurface
    if prop ~= part.BackSurface then part.BackSurface = prop end
	prop = template.TopSurface
    if prop ~= part.TopSurface then part.TopSurface = prop end
	prop = template.BottomSurface
    if prop ~= part.BottomSurface then part.BottomSurface = prop end

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

	-- deserialize properties
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

	-- deserialize surface property values
	prop = p.RightSurface
    if prop then part.RightSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.LeftSurface
    if prop then part.LeftSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.FrontSurface
    if prop then part.FrontSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.BackSurface
    if prop then part.BackSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.TopSurface
    if prop then part.TopSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.BottomSurface
    if prop then part.BottomSurface = Enum.SurfaceType:FromValue(prop) end

	-- deserialize tags
	for _, tag in ipairs(p.Tags) do part:AddTag(tag) end

	-- deserialize attributes
	for k, v in pairs(p.Attributes) do part:SetAttribute(k, v) end

	-- deserialize decals
	if p.Decals then
		for _, serialDecal in ipairs(p.Decals) do
			local instancedDecal = DeserializedDecalInstance(serialDecal, "Decal")
			instancedDecal.Parent = part
		end
	end

	-- deserialize textures
	if p.Textures then
		for _, serialTexture in ipairs(p.Textures) do
			local instancedTexture = DeserializedDecalInstance(serialTexture, "Texture")
			prop = serialTexture.OffsetStudsU
			if prop then instancedTexture.OffsetStudsU = prop end
			prop = serialTexture.OffsetStudsV
			if prop then instancedTexture.OffsetStudsV = prop end
			prop = serialTexture.StudsPerTileU
			if prop then instancedTexture.StudsPerTileU = prop end
			prop = serialTexture.StudsPerTileV
			if prop then instancedTexture.StudsPerTileV = prop end

			instancedTexture.Parent = part
		end
	end

	-- deserialize lights
	if p.Lights then
		for _, serialLight in ipairs(p.Lights) do
			local light = Instance.new(serialLight.ClassName)

			if serialLight.Shadows then light.Shadows = true end
			prop = serialLight.Brightness
			if prop then light.Brightness = prop end
			prop = serialLight.Color
			if prop then light.Color = prop end
			prop = serialLight.Range
			if prop then light.Range = prop end

			if serialLight.ClassName ~= "PointLight" then
				prop = serialLight.Angle
				if prop then light.Angle = prop end
				prop = serialLight.Face
				if prop then light.Face = Enum.NormalId:FromValue(prop) end
			end

			light.Parent = part
		end
	end

	return part
end



--[[
    Serializes the given part instance `p`
]]
local function SerializedPartInstance(p, ignoreWorldState)
	local serial = {
		Tags = p:GetTags(),
		Attributes = p:GetAttributes()
	}

	-- serialize properties if they are not their defaults
	local prop

	serial.Anchored = p.Anchored

	prop = p.Color
	if prop ~= MEDIUMSTONEGREY then serial.Color = prop end
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

	-- serialize surface property values if they are not their defaults
	prop = p.RightSurface.Value
    if prop ~= 0 then serial.RightSurface = prop end
	prop = p.LeftSurface.Value
    if prop ~= 0 then serial.LeftSurface = prop end
	prop = p.FrontSurface.Value
    if prop ~= 0 then serial.FrontSurface = prop end
	prop = p.BackSurface.Value
    if prop ~= 0 then serial.BackSurface = prop end
	prop = p.TopSurface.Value
    if prop ~= 3 then serial.TopSurface = prop end
	prop = p.BottomSurface.Value
    if prop ~= 4 then serial.BottomSurface = prop end

	-- serialize decals, textures, and lights
	local decals, textures, lights = {}, {}, {}
	for _, child in ipairs(p:GetChildren()) do
		if child:IsA("Texture") then
			local serialTexture = SerializedDecalInstance(child)
			prop = child.OffsetStudsU
			if prop ~= 0 then serialTexture.OffsetStudsU = prop end
			prop = child.OffsetStudsV
			if prop ~= 0 then serialTexture.OffsetStudsV = prop end
			prop = child.StudsPerTileU
			if prop ~= 2 then serialTexture.StudsPerTileU = prop end
			prop = child.StudsPerTileV
			if prop ~= 2 then serialTexture.StudsPerTileV = prop end

			table.insert(textures, serialTexture)
		elseif child:IsA("Decal") then
			table.insert(decals, SerializedDecalInstance(child))
		elseif child:IsA("Light") then
			local className = child.ClassName
			local isAPointLight = className == "PointLight"

			local serialLight = { ClassName = className }

			if child.Shadows then serialLight.Shadows = true end
			prop = child.Brightness
			if prop ~= 1 then serialLight.Brightness = prop end
			prop = child.Color
			if prop ~= WHITE then serialLight.Color = prop end
			prop = child.Range
			if (isAPointLight and prop ~= 8) or (not isAPointLight and prop ~= 16) then serialLight.Range = prop end

			if not isAPointLight then
				prop = child.Angle
				if prop ~= 90 then serialLight.Angle = prop end
				prop = child.Face.Value
				if prop ~= 5 then serialLight.Face = prop end
			end

			table.insert(lights, serialLight)
		end
	end
	if #decals > 0 then serial.Decals = decals end
	if #textures > 0 then serial.Textures = textures end
	if #lights > 0 then serial.Lights = lights end

	if ignoreWorldState then return serial end

	serial.CFrame = p.CFrame
	serial.Size = p.Size

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