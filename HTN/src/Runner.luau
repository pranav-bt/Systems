--!strict

-- The standalone executor, for consumers not running Bots: same planning,
-- monitoring, and replan semantics as HTN.goal (both sit on Execution.luau),
-- driven by your own loop. `owner` plays the role the bot plays under Bots --
-- it is handed to state() and to every operator hook.
--
--   local runner = HTN.Runner.new({ domain, root, state, operators, owner })
--   runner:start()                    -- plan + drive as far as possible now
--   RunService.Heartbeat -> runner:update(dt)   -- until Success/Failure
--   runner:stop()                     -- interrupt: in-flight operator exits

local Execution = require(script.Parent.Execution)
local Types = require(script.Parent.Types)

local Runner = {}

export type Status = "Idle" | "Running" | "Success" | "Failure"

export type Config = {
	name: string?, -- for warnings (default "runner")
	domain: Types.Domain,
	root: string,
	state: (owner: any) -> Types.WorldState,
	operators: { [string]: Types.Operator },
	owner: any?, -- handed to state() and every operator hook
	replanLimit: number?, -- default 3
	maxDepth: number?,
	maxSteps: number?,
	maxExpansions: number?, -- decompose() calls allowed per plan (default 2000)
	traceLimit: number?, -- decomposition-trace entries kept per plan (default 64; 0 = off)
}

export type RunnerInstance = {
	start: (self: RunnerInstance) -> Status, -- (re)plan and drive; safe to call again after any terminal status
	update: (self: RunnerInstance, dt: number?) -> Status, -- drive while "Running"; terminal statuses are sticky
	stop: (self: RunnerInstance) -> (), -- interrupt: in-flight operator exits with "Interrupted"; status -> "Idle"
	status: (self: RunnerInstance) -> Status,
	inspect: (self: RunnerInstance) -> Types.RunState, -- live plan / step / replans / lastTrace
}

function Runner.new(config: Config): RunnerInstance
	assert(type(config) == "table", "HTN.Runner.new: a config table is required")
	local label = `HTN.Runner "{config.name or "runner"}"`
	assert(
		type(config.domain) == "table" and config.domain.primitives ~= nil and config.domain.compounds ~= nil,
		`{label}: config.domain must be an HTN.Domain`
	)
	assert(
		type(config.root) == "string"
			and (config.domain.primitives[config.root] ~= nil or config.domain.compounds[config.root] ~= nil),
		`{label}: config.root must name a task in the domain`
	)
	assert(type(config.state) == "function", `{label}: config.state(owner) -> WorldState is required`)
	Execution.validateOperators(config.domain, config.operators, label)

	local ctx: Types.ExecutionContext = {
		label = label,
		domain = config.domain,
		root = config.root,
		state = config.state,
		operators = config.operators,
		replanLimit = config.replanLimit or 3,
		planOptions = {
			maxDepth = config.maxDepth,
			maxSteps = config.maxSteps,
			maxExpansions = config.maxExpansions,
			traceLimit = config.traceLimit,
		},
	}
	local owner = config.owner

	local run = Execution.newRun()
	local status: Status = "Idle"

	local runner = {} :: RunnerInstance

	function runner.start(_): Status
		if status == "Running" then
			Execution.interrupt(ctx, owner, run, "Interrupted")
		end
		run = Execution.newRun()
		status = Execution.start(ctx, owner, run) :: Status
		return status
	end

	function runner.update(_, dt: number?): Status
		if status ~= "Running" then
			return status
		end
		status = Execution.step(ctx, owner, run, dt or 0) :: Status
		return status
	end

	function runner.stop(_)
		if status == "Running" then
			Execution.interrupt(ctx, owner, run, "Interrupted")
		end
		status = "Idle"
	end

	function runner.status(_): Status
		return status
	end

	function runner.inspect(_): Types.RunState
		return run
	end

	return runner
end

return Runner
