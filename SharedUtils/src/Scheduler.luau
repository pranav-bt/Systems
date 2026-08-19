local Promise = require(script.Parent.Parent.Packages.Promise)

export type Scheduler<T, U = (deltaTime: number) -> ()> = {
	schedule: (schedule: T, name: string, callback: U) -> () -> (),
	promise: (schedule: T) -> any,
	interval: (schedule: T, name: string, interval: number, callback: () -> ()) -> () -> (),
}

local Scheduler = {}

function Scheduler.new<T, U>(events: { { schedules: { string }, event: RBXScriptSignal } }): Scheduler<T, U>
	local scheduler = {}

	local scheduled = {}

	local promises = {}

	function scheduler.schedule(schedule, name, callback)
		local function labeledCallback(...)
			debug.profilebegin(name)
			task.spawn(callback, ...)
			-- task.spawn(function()
			-- 	callback(...)
			-- end)
			debug.profileend()
		end

		scheduled[schedule][labeledCallback] = true

		return function()
			scheduled[schedule][labeledCallback] = nil
		end
	end

	function scheduler.promise(schedule)
		if promises[schedule] == nil then
			promises[schedule] = {}
		end

		return Promise.new(function(resolve)
			table.insert(promises[schedule], resolve)
		end)
	end

	function scheduler.interval(schedule, name, interval, callback)
		local accumulated = 0

		local function intervalCallback(deltaTime)
			accumulated += deltaTime

			if accumulated < interval then
				return
			end

			accumulated %= interval

			debug.profilebegin(name)
			task.spawn(callback)
			-- callback()
			debug.profileend()
		end

		scheduled[schedule][intervalCallback] = true

		return function()
			scheduled[schedule][intervalCallback] = nil
		end
	end

	for _, event in events do
		for _, schedule in event.schedules do
			if scheduled[schedule] then
				error(`Found duplicate schedule: {schedule}`)
			end

			scheduled[schedule] = {}
		end

		event.event:Connect(function(...)
			for _, schedule in event.schedules do
				if promises[schedule] ~= nil then
					for _, resolve in promises[schedule] do
						resolve()
					end

					promises[schedule] = nil
				end

				for callback in scheduled[schedule] do
					callback(...)
					-- task.spawn(callback, ...)
				end
			end
		end)
	end

	return scheduler
end

return Scheduler
