interface ShatterWorldInfo
{
    CFrame: CFrame;
    Size: Vector3;
}

interface ShatterHitbox extends ShatterWorldInfo
{
    Shape: Enum.PartType;
}

interface ShatterDestroyedVoxelInfo
{
    DirtyGroupID: string;
    CuttingPart: ShatterHitbox;
    IsEdge: boolean;
    IsAlreadyDebris: boolean;
    UserData: unknown[];
}

interface ShatterImaginaryVoxel extends ShatterWorldInfo
{
    DirtyGroupID: string;
    GridSize: number;
    isEdge: boolean;
}

interface ShatterDestructionParams
{
    CuttingPart?: Part | Model | ShatterHitbox;
    CFrame?: CFrame;
    Size?: Vector3;
    Shape?: Enum.PartType;
    FilterTagged?: string | string[];
    GridSize?: number;
    CleanupDelay?: number;
    SkipEncapsulatedVoxels?: boolean;
    SkipWalls?: boolean;
    SkipFloors?: boolean;
    ExcludePlayersReplication?: Player[];
    OnVoxelDestruct?: string;
    DestructParameters?: unknown[];
    OnDestructCompleted?: (count: number, affected: Map<string, boolean>) => void;
}

interface ShatterSettings
{
    SkipInstanceCheck: (i: Instance) => boolean;
    [key: string]: unknown;
}

interface Shatterbox
{
    Settings: ShatterSettings;

    Destroy(
        this: void,
        intersectingPart: Part | Model | ShatterHitbox | ShatterDestructionParams,
        FilterTagged?: string | string[],
        CleanupDelay?: number,
        OnVoxelDestruct?: string,
        GridSize?: number,
        SkipEncapsulatedVoxels?: boolean,
        OnDestructCompleted?: () => void,
        UserData?: unknown[],
        ExcludePlayersReplication?: Player[],
        SkipFloors?: boolean,
        SkipWalls?: boolean,
    ): void;

    ImaginaryVoxels(
        this: void,
        intersectingPart: Part | Model | ShatterWorldInfo,
        FilterTagged?: string | string[],
        CleanupDelay?: number,
        GridSize?: number,
        SkipEncapsulatedVoxels?: boolean,
        ExcludePlayersReplication?: Player[],
        SkipFloors?: boolean,
        SkipWalls?: boolean,
    ): LuaTuple<[ShatterImaginaryVoxel[], Part[]]>;

    InstantiateImaginaryVoxel(this: void, voxel: ShatterImaginaryVoxel, doNotGiveDebrisTag?: boolean): LuaTuple<[Part, Instance]>

    MapContainer?: Folder;

    ResetArea(this: void, area: Part | ShatterWorldInfo): void;
    Reset(this: void, doNotRevertOwnership?: boolean, replicated?: boolean): void;
    ClearQueue(this: void): void;

    RegisterOnVoxelDestruct(this: void, name: string, callback: (voxel: Part, info: ShatterDestroyedVoxelInfo) => void): void;

    RegisterClientImaginaryHandler(this: void, callback: ((voxels: ShatterImaginaryVoxel[], params: ShatterDestructionParams) => void) | undefined): void;

    GetOriginalPart(this: void, DirtyGroupID: string): Part | undefined;

    VoxelDistanceVector(this: void, voxel: Part, point: Vector3): Vector3;
    VoxelCountVector(this: void, voxel: Part, boxSize: Vector3): Vector3;
    PartEncapsulatesBlockPart(this: void, part: Part, contains: Part): boolean;

    PrintState(this: void): void;
}

declare namespace Shatterbox
{
    type WorldInfo = ShatterWorldInfo;
    type Hitbox = ShatterHitbox;
    type DestroyedVoxelInfo = ShatterDestroyedVoxelInfo;
    type ImaginaryVoxel = ShatterImaginaryVoxel;
    type DestructionParams = ShatterDestructionParams;
    type Settings = ShatterSettings;
}

declare const Shatterbox: Shatterbox;
export = Shatterbox;
