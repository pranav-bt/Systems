--!strict

-- Cross-server mutual exclusion so exactly one Lobby server runs the
-- matchmaking scan loop at a time. Adapted from MechBattlegrounds's
-- Matchmaking/LeaderElection.lua (game-agnostic: a MemoryStoreHashMap
-- compare-and-swap keyed on game.JobId).

local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")

local MemoryStore = require(script.Parent.MemoryStore)

local EXPIRATION = 40
local CLAIM_INTERVAL = 15

local LeaderElection = {}

function LeaderElection.start(producesPromise: () -> any)
	if game.GameId == 0 then
		return
	end

	local memoryStore = MemoryStoreService:GetHashMap(`{MemoryStore.PREFIX}MatchmakingLeader`)

	local connection: RBXScriptConnection
	local startClaimLoop: () -> ()

	local leading = false
	local leadPromise

	local function startLead()
		leading = true
		leadPromise = producesPromise()

		-- Re-claim more often than EXPIRATION so another server can't steal the lock before we renew it.
		local updateAt = os.clock() + EXPIRATION / 2
		connection = RunService.Heartbeat:Connect(function()
			if os.clock() >= updateAt then
				updateAt = os.clock() + EXPIRATION / 2

				local ok, leader = pcall(function()
					return memoryStore:UpdateAsync("Leader", function(currentLeader)
						if currentLeader ~= game.JobId then
							return nil
						else
							return game.JobId
						end
					end, EXPIRATION)
				end)

				if ok and leader ~= game.JobId then
					connection:Disconnect()
					startClaimLoop()
				end
			end
		end)
	end

	function startClaimLoop()
		leading = false

		if leadPromise ~= nil then
			leadPromise:cancel()
			leadPromise = nil
		end

		local attemptClaimAt = os.clock()
		connection = RunService.Heartbeat:Connect(function()
			if os.clock() >= attemptClaimAt then
				attemptClaimAt += CLAIM_INTERVAL

				local ok, leader = pcall(function()
					return memoryStore:UpdateAsync("Leader", function(oldLeader)
						if oldLeader == nil then
							return game.JobId
						else
							return nil
						end
					end, EXPIRATION)
				end)

				if ok and leader == game.JobId then
					connection:Disconnect()
					startLead()
				end
			end
		end)
	end

	startClaimLoop()

	game:BindToClose(function()
		connection:Disconnect()

		if leading then
			memoryStore:RemoveAsync("Leader")
		end
	end)
end

return LeaderElection
