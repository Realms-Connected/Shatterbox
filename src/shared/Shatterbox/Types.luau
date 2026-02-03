export type WorldInfo = {
	CFrame : CFrame,
	Size : Vector3,
}

export type Hitbox = WorldInfo & {
	Shape : Enum.PartType
}

export type DestroyedVoxelInfo = {
	DirtyGroupID : string,

	CuttingPart : Hitbox,

	IsEdge : boolean,
	IsAlreadyDebris : boolean,

	UserData : {any}
}

export type OnDestructCompleted = (DestroyedVoxelCount : number, AffectedDirtyGroupIDs : { [string] : boolean }) -> ()

export type OnVoxelDestruct = (voxel : Part, info : DestroyedVoxelInfo) -> ()

export type ImaginaryBox = WorldInfo & {

	DirtyGroupID : string, -- the dirty group ID for this box
	GridSize : number -- the GridSize that was applied to this box
}

export type ImaginaryVoxel = ImaginaryBox & {

	isEdge : boolean -- whether or not this box lies along the edge of the intersection
}

type SharedDestructionParams = {

	FilterTagged : (string | {string})?,
	GridSize : number?,
	CleanupDelay : number?,
	SkipEncapsulatedVoxels : boolean?,
	SkipWalls : boolean?,
	SkipFloors : boolean?,
	ExcludePlayersReplication : {Player}?
}

type UsesOnVoxelDestruct = {
	OnVoxelDestruct : string?,
	DestructParameters : { any },

	OnDestructCompleted : OnDestructCompleted?
}

export type InternalImaginaryParams = SharedDestructionParams & { CuttingPart : Hitbox }
export type ImaginaryDestructionParams = SharedDestructionParams & {

	CuttingPart : ((Part?) | (Model?) | (Hitbox?))?,

	CFrame : CFrame?,
	Size : Vector3?,
	Shape : Enum.PartType?
}

export type InternalDestructionParams = InternalImaginaryParams & UsesOnVoxelDestruct
export type DestructionParams = ImaginaryDestructionParams & UsesOnVoxelDestruct

return {}