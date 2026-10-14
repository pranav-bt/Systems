-- Default uniform voxel grid used when the host does not inject its own grid.
--
-- Replaces the game's `ReplicatedStorage.Shared.Map` dependency. The
-- placement system only ever calls `grid.positionToCoord(pos)` and reads
-- `grid.voxelSize`, so that is all this provides. Coordinates are integer
-- Vector3s derived by flooring `(position - origin) / voxelSize` per axis.
--
-- Inject a custom grid (e.g. the host's Map module) instead of this whenever
-- placement must share voxel occupancy with another system; it only needs a
-- `positionToCoord` dot-function and a `voxelSize` field.

local DefaultGrid = {}

export type Config = {
	voxelSize: number?,
	origin: Vector3?,
	-- Optional world bounds; accepted for host use but not required by the
	-- placement logic (only positionToCoord is consumed).
	bounds: { min: Vector3, max: Vector3 }?,
}

function DefaultGrid.new(config: Config?)
	local resolved = config or {}
	local voxelSize = resolved.voxelSize or 3
	local origin = resolved.origin or Vector3.zero

	local grid = {
		voxelSize = voxelSize,
		origin = origin,
		bounds = resolved.bounds,
	}

	function grid.positionToCoord(position: Vector3): Vector3
		return Vector3.new(
			math.floor((position.X - origin.X) / voxelSize),
			math.floor((position.Y - origin.Y) / voxelSize),
			math.floor((position.Z - origin.Z) / voxelSize)
		)
	end

	return grid
end

return DefaultGrid
