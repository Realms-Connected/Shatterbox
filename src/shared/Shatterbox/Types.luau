export type WorldInfo = {
	CFrame : CFrame,
	Size : Vector3,
}

export type Hitbox = WorldInfo & {
	Shape : Enum.PartType
}

export type OnDestructCompleted = () -> ()

export type OnVoxelDestruct = (voxel : Part, dirtyParent : Model, cuttingPart : Hitbox, isEdge : boolean, isAlreadyDebris : boolean, any...) -> ()

export type ImaginaryBox = WorldInfo & {

	Original : Part, -- the original part before this iteration of Imaginary touched it

	DirtyParent : Model, -- the target of smooth cleanup for this box
	GridSize : number -- the GridSize that was applied to this box
}

export type ImaginaryVoxel = ImaginaryBox & {

	isEdge : boolean -- whether or not this box lies along the edge of the intersection
}

type SharedDestructionParams = {

	FilterTagged : (string | {string})?,
	GridSize : number?,
	CleanupDelay : number?,
	SkipEncapsulatedVoxels : boolean?
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