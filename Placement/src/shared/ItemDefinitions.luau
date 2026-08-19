-- Item definition schema + example catalog, shared by client and server.
--
-- This is the DATA half of the catalog: per-item placement rules (surface,
-- category, overlap rules, snap points, etc). The runtime MODEL instances are
-- supplied separately through the injected `modelsSource` folder (see README).
--
-- The example entries (Chunks / Baseplate / Barricade) are placeholders meant to
-- be replaced or extended by the host game.

export type ItemData = {
	Type: string,
	PlacementSurface: string,
	Category: string,
	AllowOverlapWith: { string },
	PlacementType: string?,
	TouchAllowedObjects: {}?,
	PlacementAnchorType: string?,
	Origin: string?,
	RotationCorrection: CFrame?,
	IgnorePointerOnSnap: boolean?,
	SnapSearchDistanceThresholdOverride: number?,
	SnapDistanceThresholdOveride: number?,
	FixedOrientationOnSnap: Vector3?,
	SnapPoints: {
		[string]: {
			Position: Vector3,
			CompatibleWith: { string },
			SnapTo: { string },
		},
	}?,
}
-- IMPORTANT: IF YOU ADD ANY VARIABLES TO TYPE STRUCT THEN UPDATE CLONE ITEM METHOD

type ItemDefinitionsType = {
	[string]: ItemData,
}

-- `primaryPart` is optional: pass a model's PrimaryPart to derive SnapPoint
-- positions from live geometry (attachments named per snap, relative to a
-- "Center" attachment). When omitted, the authored `SnapPoints[*].Position` is
-- used verbatim. The example catalog passes nil, so authored positions win.
local function cloneItem(item: ItemData, primaryPart: BasePart?): ItemData
	local clonedSnapPoints = nil
	if item.SnapPoints then
		clonedSnapPoints = {}
		for snapName, snapData in pairs(item.SnapPoints) do
			clonedSnapPoints[snapName] = {
				Position = if primaryPart and primaryPart:FindFirstChild(snapName)
					then primaryPart[snapName].WorldCFrame.Position - primaryPart.Center.WorldCFrame.Position
					else snapData.Position,
				CompatibleWith = table.clone(snapData.CompatibleWith),
				SnapTo = table.clone(snapData.SnapTo),
			}
		end
	end

	return {
		Type = item.Type,
		PlacementSurface = item.PlacementSurface,
		Category = item.Category,
		AllowOverlapWith = table.clone(item.AllowOverlapWith),
		PlacementType = item.PlacementType,
		TouchAllowedObjects = if item.TouchAllowedObjects then table.clone(item.TouchAllowedObjects) else nil,
		PlacementAnchorType = item.PlacementAnchorType,
		Origin = item.Origin,
		RotationCorrection = item.RotationCorrection,
		SnapPoints = clonedSnapPoints,
		IgnorePointerOnSnap = item.IgnorePointerOnSnap,
		SnapSearchDistanceThresholdOverride = item.SnapSearchDistanceThresholdOverride,
		SnapDistanceThresholdOveride = item.SnapDistanceThresholdOveride,
		FixedOrientationOnSnap = item.FixedOrientationOnSnap,
	}
end

local BasicItemDefinitions: ItemDefinitionsType = {
	Chunks = {
		Type = "Floor",
		PlacementSurface = "Floor",
		Category = "Floor",
		AllowOverlapWith = {},
	},
	Baseplate = {
		Type = "Floor",
		PlacementSurface = "Floor",
		Category = "Floor",
		AllowOverlapWith = {},
	},
	Barricade = {
		Type = "Barricade",
		PlacementSurface = "Floor",
		Category = "Barricade",
		AllowOverlapWith = { "Barricade" },
		TouchAllowedObjects = { "Barricade" },
		PlacementType = "HorizontalSurface",
		IgnorePointerOnSnap = true,
		SnapSearchDistanceThresholdOverride = 15,
		SnapDistanceThresholdOveride = 12.5,
		FixedOrientationOnSnap = Vector3.new(0, 1, 0),
		SnapPoints = {
			-- 2x4x8 part: length (8) runs along local Z, so the ends sit at ±4 on Z.
			Left = {
				Position = Vector3.new(0, 0, -4),
				CompatibleWith = { "Barricade" },
				SnapTo = { "Right" },
			},
			Right = {
				Position = Vector3.new(0, 0, 4),
				CompatibleWith = { "Barricade" },
				SnapTo = { "Left" },
			},
		},
	},
}

local ItemDefinitions: ItemDefinitionsType = {
	Chunks = cloneItem(BasicItemDefinitions.Chunks),
	Baseplate = cloneItem(BasicItemDefinitions.Baseplate),
	Barricade = cloneItem(BasicItemDefinitions.Barricade),
}

return ItemDefinitions
