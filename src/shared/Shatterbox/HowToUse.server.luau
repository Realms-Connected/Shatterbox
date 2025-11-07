--[[

HowToUse Table of contents:


1. Getting started


2. Destruction function parameters explained

]]




--[[(1)  How to use:

	Place Shatterbox anywhere as a descendant of ReplicatedStorage (or in the "shared" directory if you are using Rojo)

	Require the Shatterbox.Main module at initalization on the server side. (You can use client-only features afterward if you want)

	This library assumes STATIC objects (i.e, buildings, the ground, walls). Not yet fully supporting moving objects.

	Giving a part the GridSize attribute will override the default GridSize.
	| the GridSize passed to destruction functions will override this attribute.

	To create your own debris effects, use Shatterbox.RegisterOnVoxelDestruct(name, func)
	| if you need one effect to do different things on server side and client side
	| you have to register it in this scipt using the local function RegisterOnVoxelDestruct(name, clientFunc, serverFunc)
	| see below (around line 120) for an example.

	Using a debris effect requires you to set OnVoxelDestruct = name

	CreateHitbox() will create a hitbox object very similar to a VoxBreaker Hitbox.
	I suggest you use this to get a feel for the module, it is very user-friendly.

	OnVoxelDestruct parameters explained (anything past the 3rd is supplied via DestructParams, examples are above):

		- voxel is the part that is to be destroyed

		- dirtyParent is the source model which is affected by smooth cleanup. See "Rough" for an example on the usage.

		- cuttingPart is the cloned hitbox which destroyed "voxel" in the state that it was in when it queued the operation. See "Rough" for an example on the usage.

		- isEdge is true if the voxel is along the edge of the intersection.

		- any parameters past isEdge are defined by the DestructParams array.
]]




--[[(2)  Destruction function parameters explained

	World intersection (REQUIRED)
	  | CuttingPart : Part
	  OR
	  | CFrame : CFrame
	  | Size : Vector3
	  | Shape : Enum.PartType


	Smooth cleanup delay (otherwise uses the set default)
	  | CleanupDelay = nil :: number?


	Optional destructible parts filter by tag. (string or an array of strings)
	  | FilterTagged : ( string | {string} )?
		* Parts are dynamically tagged with Client-Server enabled, so you can feel free to tag just your "Destructible" folder/model instead of all descendants of it.

	Voxel destruction effect name (otherwise uses the set default)
	  | OnVoxelDestruct : string?


	Additional parameters that get passed into OnVoxelDestruct as a variardic (after the fourth parameter)
	| DestructParameters : {any}?


	Callback for when the operation is fully completed
	| OperationCompletedCallback : ( () -> () )?


	(Hitbox object only) The amount of time in between calls to "Destroy" when using the "Start" function. (otherwise uses 0.1 as the default)
	  | DestructDelay : number?


	The grid size to divide parts down to (otherwise uses the set default)
	  | GridSize : number?


	Whether or not to immediately destroy encapsulated voxels, returning only the edge voxels (saves loads of performance)
	  | SkipEncapsulatedVoxels = false :: boolean


	Example:

	Shatterbox.Destroy({
		CFrame = CFrame.new(),
		Size = Vector3.one * 12,
		Shape = Enum.PartType.Ball,

		FilterTagged = {"Tier1", "Tier2"},

		OnVoxelDestruct = "Fall",
		DestructParameters = {}
	})
]]