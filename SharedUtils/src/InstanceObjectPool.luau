local InstanceObjectPool = {
	instances = {},
	free = {},
	active = {},
	activeObjectCounts = {},
	tags = {},
	emissions = {},
	parentOverrides = {},
	currentObjectCounts = {},
	maxObjectCounts = {},
	isVfx = {},
}

-- Debug reporting is fully decoupled from any game infrastructure.
-- Originally this pool logged through the game Debugger and was triggered
-- by a client remote (ReplicatedStorage.Remotes.DebugVfxObjectPool_RS).
-- Both are gone. Warnings are gated behind DEBUG (off by default) and emit
-- via plain `warn`, or via an optional injectable reporter callback.
-- To inspect free-object counts, optionally assign `DebugReporter` and call
-- `InstanceObjectPool.ReportFreeObjectCounts()` yourself.
InstanceObjectPool.DEBUG = false
InstanceObjectPool.DebugReporter = nil :: ((message: string) -> ())?

local CurrentTagCount = 0
local PoolCFrame = CFrame.new(0, -1000, 0)
local DEFAULT_MAX_OBJECT_COUNT_CAP = 20
local PooledObjectsFolder = workspace:FindFirstChild("PooledObjects")

if not (PooledObjectsFolder and PooledObjectsFolder:IsA("Folder")) then
	local folder = Instance.new("Folder")
	folder.Name = "PooledObjects"
	folder.Parent = workspace
	PooledObjectsFolder = folder
end

local function report(message: string)
	if InstanceObjectPool.DebugReporter then
		InstanceObjectPool.DebugReporter(message)
	else
		warn(message)
	end
end

function InstanceObjectPool.InitializeObjectPool(
	object: Instance,
	params: {
		overrideParent: Instance?,
		overrideMaxObjectCountCap: number?,
	}?
)
	if InstanceObjectPool.tags[object] then
		if InstanceObjectPool.DEBUG then
			report(`Object pool already initialized for {object:GetFullName()}`)
		end
		return
	end

	CurrentTagCount += 1
	InstanceObjectPool.tags[object] = CurrentTagCount
	InstanceObjectPool.instances[CurrentTagCount] = object
	InstanceObjectPool.free[CurrentTagCount] = {}
	InstanceObjectPool.currentObjectCounts[CurrentTagCount] = 0
	InstanceObjectPool.activeObjectCounts[CurrentTagCount] = 0
	InstanceObjectPool.maxObjectCounts[CurrentTagCount] = (params and params.overrideMaxObjectCountCap)
		or DEFAULT_MAX_OBJECT_COUNT_CAP
	if string.find(object:GetFullName(), "VFX") then
		InstanceObjectPool.isVfx[CurrentTagCount] = true
	end

	if params and params.overrideParent then
		InstanceObjectPool.parentOverrides[CurrentTagCount] = params.overrideParent
	end

	return InstanceObjectPool.tags[object]
end

function InstanceObjectPool.GetObjectTag(object)
	if not InstanceObjectPool.tags[object] then
		InstanceObjectPool.InitializeObjectPool(object)
	end

	return InstanceObjectPool.tags[object]
end

function InstanceObjectPool.DoesTagExist(tag)
	return if InstanceObjectPool.instances[tag] then true else false
end

function InstanceObjectPool.Get(tag)
	local objectData
	if #InstanceObjectPool.free[tag] > 0 then
		objectData = table.remove(InstanceObjectPool.free[tag])
	else
		if InstanceObjectPool.currentObjectCounts[tag] >= InstanceObjectPool.maxObjectCounts[tag] then
			return nil
		end
		debug.profilebegin(`ObjectPoolCreating_{InstanceObjectPool.instances[tag].Name}`)
		local instance = InstanceObjectPool.instances[tag]:Clone()

		objectData = { instance = instance, emissions = {} }
		for _, child in instance:GetDescendants() do
			if child:IsA("ParticleEmitter") then
				objectData.emissions[child] = child:GetAttribute("EmitCount") or 1
			end
		end

		InstanceObjectPool.currentObjectCounts[tag] += 1
		instance.Parent = InstanceObjectPool.parentOverrides[tag] or PooledObjectsFolder
		debug.profileend()
	end

	InstanceObjectPool.active[objectData] = tag
	InstanceObjectPool.activeObjectCounts[tag] += 1
	return objectData :: { instance: Instance, emissions: {} }?
end

function InstanceObjectPool.Release(objectData)
	local tag = InstanceObjectPool.active[objectData]
	table.insert(InstanceObjectPool.free[tag], objectData)
	InstanceObjectPool.active[objectData] = nil
	InstanceObjectPool.activeObjectCounts[tag] -= 1
	objectData.instance:PivotTo(PoolCFrame)
end

function InstanceObjectPool.ReleaseBillboard(objectData)
	local tag = InstanceObjectPool.active[objectData]
	table.insert(InstanceObjectPool.free[tag], objectData)
	InstanceObjectPool.active[objectData] = nil
	InstanceObjectPool.activeObjectCounts[tag] -= 1
	objectData.instance.Adornee = nil
	objectData.instance.Enabled = false
end

-- Manual replacement for the old DebugVfxObjectPool_RS client remote handler.
-- No-op unless invoked. Reports each pool's free-object count via the injectable
-- DebugReporter callback, or `warn` if none is set.
function InstanceObjectPool.ReportFreeObjectCounts()
	for object, tag in InstanceObjectPool.tags do
		report(`Free objects for {object:GetFullName()}: {#InstanceObjectPool.free[tag]}`)
	end
end

return InstanceObjectPool
