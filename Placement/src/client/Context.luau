-- Mutable injection context for the client placement system.
--
-- The client init (`init.luau`) populates these fields from the host-supplied
-- config BEFORE requiring the runtime sub-modules (Items / PreviewManager /
-- PlacementInput). Those sub-modules read from here instead of hardcoding
-- ReplicatedStorage paths, a game-specific Map, or an external scheduler.

export type Grid = {
	-- Maps a world position to an integer voxel coordinate (Vector3 of ints).
	positionToCoord: (position: Vector3) -> Vector3,
	voxelSize: number,
}

export type Scheduler = {
	-- Registers `callback` to run every frame in the named phase; returns a
	-- disconnect function. Phases used by this library: "Input", "PostSimulation".
	schedule: (phase: string, name: string, callback: (deltaTime: number) -> ()) -> () -> (),
}

local Context = {
	grid = nil :: Grid?,
	modelsSource = nil :: Instance?,
	scheduler = nil :: Scheduler?,
}

return Context
