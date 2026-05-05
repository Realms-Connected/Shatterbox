--#selene: allow(incorrect_standard_library_use)
--#selene: allow(multiple_statements)

-- PartOperations contains functions that perform operations on an individual part (subdivide, voxelize, etc.)

local Settings = require(script.Parent.Parent:WaitForChild("Settings"))

local Types = require(script.Parent.Parent:WaitForChild("Types"))


local localAxisVectors = { X = "RightVector", Y = "UpVector", Z = "ZVector" }

local splitInHalfVectors = { X = Vector3.new(0.5,1,1), Y = Vector3.new(1,0.5,1), Z = Vector3.new(1,1,0.5) }

local axisNameArray = { "X", "Y", "Z" }

local WHITE = Color3.new(1, 1, 1)


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
local function PartFromTemplate(template, cframe, CachedParts)

	if not template:IsA("Part") or template.Shape ~= Enum.PartType.Block then
		local cloned = template:Clone()
		if cframe then cloned.CFrame = cframe end
		return cloned
	end

	local part

	--debug.profilebegin("create part")

	if CachedParts then
		part = CachedParts:GetPart(cframe)
		part.CanCollide = true
	else
		part = Instance.new("Part")
		if cframe then part.CFrame = cframe end
	end

	-- Set properties if they are not their defaults
	local prop

    if not part.Anchored then part.Anchored = true end

	prop = template.Size
    if prop ~= part.Size then part.Size = prop end

	--
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
	prop = template.CanCollide
    if prop ~= part.CanCollide then part.CanCollide = prop end

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
	--]]

	-- copy tags
	for _, tag in ipairs(template:GetTags()) do part:AddTag(tag) end

	-- copy attributes
	for k, v in pairs(template:GetAttributes()) do
		if k:sub(1, 3) == "RBX" then continue end
		part:SetAttribute(k, v)
	end

	--
	-- copy textures
	for _, child in ipairs(template:GetChildren()) do
		if child:IsA("Texture") then child:Clone().Parent = part end
	end
	--]]

	--debug.profileend()

	return part
end




--[[
    Deserializes the given serialized part instance `p`
]]
local function DeserializedPartInstance(p, CachedParts)

	local part

	if CachedParts then
		part = CachedParts:GetPart(p.CFrame)
		part.CanCollide = true
	else
		part = Instance.new("Part")
		if p.CFrame then part.CFrame = p.CFrame end
	end

	if not part.Anchored then part.Anchored = true end

	-- deserialize properties
	local prop

	prop = p.Size
	if prop and part.Size ~= prop then part.Size = prop end

	--
	--part.Color = Color3.fromHSV(math.random(), 1, 1)
	prop = p.Color
    if prop and part.Color ~= prop then part.Color = prop end
	prop = p.Transparency
    if prop and part.Transparency ~= prop then part.Transparency = prop end
	prop = p.Reflectance
    if prop and part.Reflectance ~= prop then part.Reflectance = prop end
	prop = p.Material
    if prop and part.Material.Value ~= prop then part.Material = Enum.Material:FromValue(prop) end
	prop = p.MaterialVariant
    if prop and part.MaterialVariant ~= prop then part.MaterialVariant = prop end
	prop = p.CollisionGroup
    if prop and part.CollisionGroup ~= prop then part.CollisionGroup = prop end
	prop = p.CanCollide
    if part.CanCollide ~= prop then part.CanCollide = prop end

	-- deserialize surface property values
	prop = p.RightSurface
    if prop and part.RightSurface.Value ~= prop then part.RightSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.LeftSurface
    if prop and part.LeftSurface.Value ~= prop then part.LeftSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.FrontSurface
    if prop and part.FrontSurface.Value ~= prop then part.FrontSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.BackSurface
    if prop and part.BackSurface.Value ~= prop then part.BackSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.TopSurface
    if prop and part.TopSurface.Value ~= prop then part.TopSurface = Enum.SurfaceType:FromValue(prop) end
	prop = p.BottomSurface
    if prop and part.BottomSurface.Value ~= prop then part.BottomSurface = Enum.SurfaceType:FromValue(prop) end
	--]]

	-- deserialize tags
	for _, tag in ipairs(p.Tags) do part:AddTag(tag) end

	-- deserialize attributes
	for k, v in pairs(p.Attributes) do part:SetAttribute(k, v) end

	--
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
	--]]

	return part
end



--[[
    Serializes the given part instance `p`
]]
local function SerializedPartInstance(p, ignoreWorldState)
	local serial = {
		Tags = p:GetTags()
	}

	local Attributes = {}
	for k, v in pairs(p:GetAttributes()) do
		if k:sub(1, 3) == "RBX" then continue end -- seriously Roblox why do I have to check for this? Become better.
		Attributes[k] = v
	end
	serial.Attributes = Attributes

	serial.Color = p.Color
	serial.Transparency = p.Transparency
	serial.Reflectance = p.Reflectance
	serial.Material = p.Material.Value
	serial.MaterialVariant = p.MaterialVariant
	serial.CollisionGroup = p.CollisionGroup
	serial.CanCollide = p.CanCollide

	serial.RightSurface = p.RightSurface.Value
	serial.LeftSurface = p.LeftSurface.Value
	serial.FrontSurface = p.FrontSurface.Value
	serial.BackSurface = p.BackSurface.Value
	serial.TopSurface = p.TopSurface.Value
	serial.BottomSurface = p.BottomSurface.Value

	-- serialize decals, textures, and lights
	local decals, textures, lights = {}, {}, {}
	for _, child in ipairs(p:GetChildren()) do
		local prop = nil
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
local function ExtentInfo(PartCFrame : CFrame, VoxelSize : Vector3, GridLength : number)
	local lsx, lsy, lsz = PartCFrame.XVector*VoxelSize.X, PartCFrame.YVector*VoxelSize.Y, PartCFrame.ZVector*VoxelSize.Z

	local ExtentOffset = 0.5*( lsx*(GridLength.X - 1) + lsy*(GridLength.Y - 1) + lsz*(GridLength.Z - 1) )

	return (PartCFrame - ExtentOffset)--[[:Orthonormalize()]],
		   (PartCFrame + ExtentOffset)--[[:Orthonormalize()]],
		   lsx, lsy, lsz
end




--[[ I wonder if anyone has done this before.

    Voxelizes a part (or imaginary part) completely according to the GridSize supplied. Returns an array of imaginary box parts.

    The returned table is created with proper allocation size using `table.create`
]]
--[[
local function ImaginaryVoxelize(Part : Types.WorldInfo, VoxelSize : Vector3, GridLength : Vector3) : {Types.WorldInfo}
	local lenX, lenY, lenZ = GridLength.X, GridLength.Y, GridLength.Z

	local O, _, lsx, lsy, lsz = ExtentInfo(Part.CFrame, VoxelSize, GridLength)

	local imaginaryParts, index = table.create(lenX*lenY*lenZ), 0

	for X = 0, lenX - 1 do
		local xPos = O + X*lsx
		for Y = 0, lenY - 1 do
			local yPos = xPos + Y*lsy
			for Z = 0, lenZ - 1 do
				index += 1
				imaginaryParts[index] = {
					CFrame = (yPos + Z*lsz)--[[:Orthonormalize(),
					Size = VoxelSize
				}
			end
		end
	end

	return imaginaryParts
end
--]]

local function ImaginaryVoxelize(Part : Types.WorldInfo, VoxelSize : Vector3, GridLength : Vector3) : {PartType}
	local lenX, lenY, lenZ = GridLength.X, GridLength.Y, GridLength.Z

	local O, _, lsx, lsy, lsz = ExtentInfo(Part.CFrame, VoxelSize, GridLength)

	local imaginaryParts, index = table.create(lenX*lenY*lenZ), 0

	for X = 0, lenX - 1 do
		local dx = X*lsx
		for Y = 0, lenY - 1 do
			local dy = Y*lsy
			for Z = 0, lenZ - 1 do
				index += 1
				imaginaryParts[index] = {
					CFrame = (O + dx + dy + Z*lsz)--[[:Orthonormalize()]],
					Size = VoxelSize
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
local function Voxelize(Part : Part, VoxelSize : Vector3, GridLength : Vector3) : {Part}
	local NVX, NVY, NVZ = GridLength.X, GridLength.Y, GridLength.Z
	if NVX*NVY*NVZ == 1 then return {Part} end

	local O, _, lsx, lsy, lsz = ExtentInfo(Part.CFrame, VoxelSize, GridLength)

	local createdParts, index = table.create(NVX*NVY*NVZ), 0

    for X = 0, NVX - 1 do
		local dx = X*lsx
		for Y = 0, NVY - 1 do
			local dy = Y*lsy
			for Z = 0, NVZ - 1 do
				index += 1

                local created = PartFromTemplate(Part, O + dx + dy + Z*lsz)
                created.Size = VoxelSize
                created.Parent = Part.Parent

                createdParts[index] = created
			end
		end
	end

    Part:Destroy()

	return createdParts
end


local EPSILON = 1e-3




--[[ Modified Octree Subdivide

    Does not mutate the supplied Part reference, which is meant to be an object with the structure {Size : Vector3, CFrame : CFrame}

    Returns an array with the structure { {Size : Vector3, CFrame : CFrame} }

    Calculates the division of a part into 2, 4, or 8 pieces along its longest axis in voxel coordinates.

    Maintains grid structure according to the VoxelSize and GroupMinimumCorner supplied.
]]
local function SubdivideOctree(Part : Types.WorldInfo, PartGridLength : Vector3, VoxelSize : Vector3, GroupMinimumCornerPosition : Vector3, DirtyGroupID : string)
	local Axis, i = table.create(3), 1
	for _, axis in ipairs(axisNameArray) do
		if PartGridLength[axis] == 1 then continue end
		Axis[i] = axis
		i += 1
	end

	local PartCFrame = Part.CFrame

	local createdParts = { { CFrame = PartCFrame, Size = Part.Size } }
	local tmpParts = {}

    -- Subdivide all createdParts along each valid axis, updating the createdParts array.
	for _, axis in ipairs(Axis) do
		local ax, ay = axis == "X", axis == "Y"

		local worldAxisVector = (ax and PartCFrame.XVector) or (ay and PartCFrame.YVector) or PartCFrame.ZVector

		for _, part in ipairs(createdParts) do
			local size = part.Size
            local hs, cframe = size[axis] * 0.5, part.CFrame

			local centerOnAxis = worldAxisVector:Dot(cframe.Position - GroupMinimumCornerPosition)

			local gridStep : number = VoxelSize[axis]
			local toSplitPoint = gridStep*math.round(centerOnAxis/gridStep) - centerOnAxis

			if math.abs(toSplitPoint) < EPSILON then
				local newSize = size*splitInHalfVectors[axis]
				local off = worldAxisVector*newSize[axis]*0.5
				table.insert(tmpParts, {
					CFrame = cframe - off,
					Size = newSize,
					DirtyGroupID = DirtyGroupID,
					Verts = false,
					isEdge = false
				})
				table.insert(tmpParts, {
					CFrame = cframe + off,
					Size = newSize,
					DirtyGroupID = DirtyGroupID,
					Verts = false,
					isEdge = false
				})
				continue
			end

			local minSize = hs + toSplitPoint
			local maxSize = hs - toSplitPoint

			local splitPointCF = cframe + worldAxisVector*toSplitPoint
			local splitWorldAxisVector = worldAxisVector*0.5

			local minSizeVec, maxSizeVec
			if ax then
				local ySize, zSize = size.Y, size.Z
				minSizeVec = Vector3.new(minSize, ySize, zSize)
				maxSizeVec = Vector3.new(maxSize, ySize, zSize)
			elseif ay then
				local xSize, zSize = size.X, size.Z
				minSizeVec = Vector3.new(xSize, minSize, zSize)
				maxSizeVec = Vector3.new(xSize, maxSize, zSize)
			else
				local xSize, ySize = size.X, size.Y
				minSizeVec = Vector3.new(xSize, ySize, minSize)
				maxSizeVec = Vector3.new(xSize, ySize, maxSize)
			end
			table.insert(tmpParts, {
				CFrame = splitPointCF - splitWorldAxisVector*minSize,
				Size = minSizeVec,
				DirtyGroupID = DirtyGroupID,
				Verts = false,
				isEdge = false
			})
			table.insert(tmpParts, {
				CFrame = splitPointCF + splitWorldAxisVector*maxSize,
				Size = maxSizeVec,
				DirtyGroupID = DirtyGroupID,
				Verts = false,
				isEdge = false
			})
		end

		createdParts = tmpParts
		tmpParts = {}
	end

	return createdParts
end



--[[ Modified KD-tree Subdivide

    Does not mutate the supplied Part reference, which is meant to be an object with the structure {Size : Vector3, CFrame : CFrame}

    Returns an array with the structure { {Size : Vector3, CFrame : CFrame} }

    Calculates the division of a part into 2 pieces along its longest axis in voxel coordinates.

    Maintains grid structure according to the VoxelSize and GroupMinimumCorner supplied.
]]
local function SubdivideKD(Part : Types.WorldInfo, PartGridLength : Vector3, VoxelSize : Vector3, GroupMinimumCornerPosition : Vector3, DirtyGroupID : string)
	local lenX, lenY, lenZ = PartGridLength.X, PartGridLength.Y, PartGridLength.Z
	local maxSize = math.max(lenX, lenY, lenZ)
	local axis = (lenX == maxSize and "X") or (lenY == maxSize and "Y") or "Z"
	local PartSize = Part.Size

	local PartCFrame = Part.CFrame
	local worldAxisVector = (axis == "X" and PartCFrame.XVector) or (axis == "Y" and PartCFrame.YVector) or PartCFrame.ZVector

	local centerOnAxis = worldAxisVector:Dot(PartCFrame.Position - GroupMinimumCornerPosition)

	local gridStep : number = VoxelSize[axis]
	local toSplitPoint = gridStep*math.round(centerOnAxis/gridStep) - centerOnAxis

	local createdParts = table.create(2)

	if math.abs(toSplitPoint) < EPSILON then
		local newSize = PartSize*splitInHalfVectors[axis]
		local off = worldAxisVector*newSize[axis]*0.5
		createdParts[1] = {
			CFrame = PartCFrame - off,
			Size = newSize,
			DirtyGroupID = DirtyGroupID,
			Verts = false,
			isEdge = false
		}
		createdParts[2] = {
			CFrame = PartCFrame + off,
			Size = newSize,
			DirtyGroupID = DirtyGroupID,
			Verts = false,
			isEdge = false
		}
		return createdParts
	end
	maxSize = PartSize[axis] * 0.5

	local minSize = maxSize + toSplitPoint
	maxSize -= toSplitPoint

	local splitPointCF = PartCFrame + worldAxisVector*toSplitPoint
	local splitWorldAxisVector = worldAxisVector*0.5

	local minSizeVec, maxSizeVec
	if axis == "X" then
		local ySize, zSize = PartSize.Y, PartSize.Z
		minSizeVec = Vector3.new(minSize, ySize, zSize)
		maxSizeVec = Vector3.new(maxSize, ySize, zSize)
	elseif axis == "Y" then
		local xSize, zSize = PartSize.X, PartSize.Z
		minSizeVec = Vector3.new(xSize, minSize, zSize)
		maxSizeVec = Vector3.new(xSize, maxSize, zSize)
	else
		local xSize, ySize = PartSize.X, PartSize.Y
		minSizeVec = Vector3.new(xSize, ySize, minSize)
		maxSizeVec = Vector3.new(xSize, ySize, maxSize)
	end
	createdParts[1] = {
		CFrame = splitPointCF - splitWorldAxisVector*minSize,
		Size = minSizeVec,
		DirtyGroupID = DirtyGroupID,
		Verts = false,
		isEdge = false
	}
	createdParts[2] = {
		CFrame = splitPointCF + splitWorldAxisVector*maxSize,
		Size = maxSizeVec,
		DirtyGroupID = DirtyGroupID,
		Verts = false,
		isEdge = false
	}
	return createdParts
end



local PartOperations = {}

PartOperations.PartFromTemplate = PartFromTemplate

PartOperations.DeserializedPartInstance = DeserializedPartInstance

PartOperations.SerializedPartInstance = SerializedPartInstance

PartOperations.ExtentInfo = ExtentInfo

PartOperations.ImaginaryVoxelize = ImaginaryVoxelize

PartOperations.Voxelize = Voxelize

PartOperations.SubdivideOctree = SubdivideOctree

PartOperations.SubdivideKD = SubdivideKD

return PartOperations