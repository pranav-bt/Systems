--!strict

local MemoryStoreService = game:GetService("MemoryStoreService")

local Promise = require(script.Parent.Parent.Promise)

local Config = require(script.Parent.Config)

-- The MemoryStore key prefix is injected once at boot via
-- MemoryStore.setKeyPrefix (fed from Matchmaking config.keyPrefix). Namespacing
-- keys by e.g. place-kind (Local/Workspace/Testing/Production) keeps Studio
-- testing, a staging place, and Production from ever sharing a queue/registry.
local MemoryStore = {
	PREFIX = "",
}

function MemoryStore.setKeyPrefix(keyPrefix: string)
	MemoryStore.PREFIX = keyPrefix
end

function MemoryStore.getQueue(region: string): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(`{MemoryStore.PREFIX}MMQueue{region}`)
end

function MemoryStore.getServerRegistry(region: string): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(`{MemoryStore.PREFIX}MMServers{region}`)
end

-- sortKey = joinTime, so the queue is scanned oldest-first (FIFO / fairness).
function MemoryStore.joinQueue(userId: number, region: string, joinTime: number, jobId: string)
	local queue = MemoryStore.getQueue(region)
	return Promise.try(function()
		queue:SetAsync(tostring(userId), jobId, Config.QUEUE_ENTRY_TTL, joinTime)
	end)
end

function MemoryStore.exitQueue(userId: number, region: string)
	local queue = MemoryStore.getQueue(region)
	return Promise.try(function()
		queue:RemoveAsync(tostring(userId))
	end)
end

-- sortKey = openSlots, so the registry is scanned fullest-open-capacity-first.
function MemoryStore.publishServerCapacity(accessCode: string, region: string, jobId: string, openSlots: number)
	local registry = MemoryStore.getServerRegistry(region)
	return Promise.try(function()
		registry:SetAsync(accessCode, jobId, Config.SERVER_REGISTRY_TTL, openSlots)
	end)
end

function MemoryStore.removeServerCapacity(accessCode: string, region: string)
	local registry = MemoryStore.getServerRegistry(region)
	return Promise.try(function()
		registry:RemoveAsync(accessCode)
	end)
end

return MemoryStore
