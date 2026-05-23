# Shatterbox integration notes

Local wrapper around upstream [azavier-a/Shatterbox](https://github.com/azavier-a/Shatterbox). Upstream not modified. Wrapper consumed by `DestructionService` as `DestructionBackend.SHATTERBOX`.

## Wrapper layout

- `init.luau` — re-exports `src/shared/Shatterbox/Main`.
- `index.d.ts` — TypeScript bindings (subset of upstream API).
- `package.json` / `tsconfig.json` — match `voxbreaker` convention.

Adding files at the submodule root makes the directory a `ModuleScript` once compiled. Original files become children of that ModuleScript. Shatterbox's internal `script.Parent` paths still resolve because the `src/shared/Shatterbox` directory layout is preserved.

## Conversion approach

**Wrapper, not port.** Lua source stays as-is; only TS declarations were added. Matches existing `voxbreaker` pattern. A full Lua → TS port (~2700 lines) was intentionally avoided — behavior drift risk + every upstream release would require re-porting.

## Backend caveats

### Only Block-shape parts are destroyed (client-side)

`Main.luau:88`:
```lua
if isClient and (not i:IsA("Part") or i.Shape ~= Enum.PartType.Block) then return true end
```

Non-Block geometry (Cylinder, Ball, MeshPart, PartOperation) is silently skipped by Shatterbox.

### Hard-coded tag gates

- `Indestructible` tag → skip entirely.
- Anything with a `Humanoid` ancestor → skip.
- Anything passing `Settings.SkipInstanceCheck` → skip.

To allow a part to be destroyed by Shatterbox, ensure none of the above apply.

### Server-init requirement

Upstream README step 2: "Require the `Shatterbox.Main` module at *server initialization* to properly initialize client-server features."

Auto-handled by `import Shatterbox from "lib/fx/shatterbox"` at the top of `destruction.service.ts` — the require fires on module load (server boot).

### Blink batching not configured

Upstream optional steps 3-6 wire Shatterbox's events into a Blink config for batching. Skipped — Shatterbox falls back to a non-batched code path. Performance is acceptable; revisit if event traffic becomes hot.

### `onComplete` returns no fragments

`Shatterbox.Destroy` is fire-and-forget (`coroutine.wrap`). The service's `onComplete?: (fragments) => void` callback fires with an empty array on completion. For per-voxel data, use `BreakOptions.onVoxelDestruct`:

```ts
this.destructionService.BreakWithinVolume(DestructionBackend.SHATTERBOX, cf, size, undefined, {
    onVoxelDestruct: (voxel, info) => {
        voxel.Anchored = false;
        voxel.AssemblyLinearVelocity = ...;
    },
});
```

Service plumbing: registers one global `Shatterbox.RegisterOnVoxelDestruct` handler at construction; per-call closures keyed by GUID in `UserData[0]`. Map entry cleaned on `OnDestructCompleted`. Inside the callback the voxel is still live — Shatterbox tags `ShatterboxDebris` after callback returns, then cleans up per `fragmentTTL`.

### `BreakPart` not wired

`Shatterbox.Destroy` takes an intersecting volume Part/Model/WorldInfo. The `BreakPart(SHATTERBOX, ...)` path is not implemented — use `BreakWithinVolume` with SHATTERBOX backend instead.

### Replication model differs

Shatterbox replicates destruction to clients automatically via its own Blink events. The service's `task.spawn` "outside simulation thread" guarantee still applies (we never enter sim thread), but server rollback behavior with Shatterbox-spawned voxels is *unverified* — Shatterbox owns voxel lifecycle.

### Grid sizing

`shatterGridSize` option maps to Shatterbox's `GridSize` parameter — voxel cell size. Default is Shatterbox's internal default (~`Settings.DefaultGridSize`). Smaller = more voxels = more work. Tune per situation.

### Tag filter

`shatterFilterTagged` maps to Shatterbox's `FilterTagged` parameter. Restricts destruction to parts with the named tag(s). Different from the service's `broadphaseTagFilter` (which uses `OverlapParams` — not used in SHATTERBOX path).

## Maintenance

Updating Shatterbox upstream:

```bash
git submodule update --remote src/lib/fx/shatterbox
```

After update, re-check `index.d.ts` against any new public methods in `Main.luau`. The bindings here are a *subset* of the upstream API.
