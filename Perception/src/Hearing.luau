--!strict

-- The stimulus bus Roblox doesn't give AI: game code EMITS sounds (gunshots,
-- footsteps, explosions -- one line at the site that makes the noise) and
-- registered listeners within range get their onHeard callback, with geometry
-- occlusion attenuating how far sound carries through walls.
--
-- A sound reaches a listener when
--     distance <= radius * listener.acuity * (occluded and occludedScale or 1)
-- so occlusion shrinks the effective radius rather than hard-blocking --
-- muffled, not silenced.
--
-- COST, per emit, per listener -- a funnel ordered cheapest-rejection-first,
-- because a fleet-wide sound touches every ear:
--   1. AUDIENCE  emit's optional audience skips whole listeners outright. Given
--                an ARRAY of refs this doesn't even walk the registry -- it
--                walks the audience, so emit is O(audience), not O(listeners).
--   2. KINDS     a listener with `kinds` set ignores every other kind for free.
--   3. RANGE     pure math; out of earshot even unoccluded costs no ray.
--   4. BAND      the occlusion ray only changes AUDIBILITY between the muffled
--                radius and the full radius. A listener closer than
--                radius * occludedScale hears the sound either way, so no ray
--                is cast (set preciseOcclusion to force one; see below).
--   5. BUDGET    an optional shared Budget meters what survives. A refused ray
--                is treated as UNOCCLUDED -- the listener hears it. Going deaf
--                under load is far worse than occasionally hearing through a
--                wall, and reacting to events that can't wait is the whole
--                point of this bus.
--   6. RAY       one raycast, sound position -> that ear.
--
-- OCCLUDERS. `occluders = { workspace.Walls }` builds an INCLUDE filter, so
-- only listed geometry muffles: far cheaper per ray than excluding everything
-- else, and it says what it means. It fails OPEN -- anything unlisted is
-- acoustically transparent -- so a building you forget to list won't muffle.
-- Note this filter is the opposite polarity to the one Vision wants (which
-- EXCLUDES characters so everything else blocks sight), so a game using
-- `occluders` should not share one RaycastParams between the two.
--
-- Listener callbacks are isolated (an error is warned; other listeners still
-- hear). The natural callback body is a Bots stimulate --
-- `bot:stimulate({ heardSound = sound })` -- so even a slow-ticking bot
-- reacts to a gunshot the instant it happens; see the README. Nothing here
-- knows Bots exists.

local Raycaster = require(script.Parent.Raycaster)
local Types = require(script.Parent.Types)

local Hearing = {}

export type Config = {
	raycast: Types.RaycastFn?, -- occlusion probe (default: Raycaster.new from params/occluders)
	params: RaycastParams?, -- filter for the DEFAULT raycast only
	-- Instances that MUFFLE sound, as an Include filter (default raycast only).
	-- Mutually exclusive with `params`. See OCCLUDERS above.
	occluders: { Instance }?,
	occludedScale: number?, -- effective-radius multiplier through geometry (default 0.5; 1 disables occlusion rays)
	budget: Types.Budget?, -- optional shared raycast budget; refused ray = heard unoccluded
	-- Cast the occlusion ray even when it cannot change audibility, so the
	-- delivered sound's `occluded` flag is exact for close listeners too
	-- (default false -- see BAND above).
	preciseOcclusion: boolean?,
}

-- Everything delivery needs, built once per bus so the hot loop passes one
-- reference instead of six arguments.
type Context = {
	raycast: Types.RaycastFn,
	occludedScale: number,
	budget: Types.Budget?,
	precise: boolean,
}

-- One listener's delivery, at module scope: this used to be a closure built
-- per listener per emit, which made allocation scale as sounds x listeners.
-- Returns nothing; a rejection at any stage is just an early return.
local function deliver(
	listener: Types.Listener,
	ctx: Context,
	kind: string,
	position: any,
	radius: number,
	data: any?,
	filter: ((ref: any) -> boolean)?
)
	-- Stage 1 (predicate form): consumer code, so it runs inside the caller's
	-- pcall like every other hook -- a throwing filter can't break the broadcast.
	if filter and not filter(listener.ref) then
		return
	end

	local ear = listener.position()
	local offset = ear - position
	local distance = offset.Magnitude
	local effective = radius * (listener.acuity or 1)
	if distance > effective then
		return -- stage 3: out of earshot even unoccluded, no ray spent
	end

	-- Stage 4: below this distance the sound is audible whether or not geometry
	-- is in the way, so the ray cannot change the outcome.
	local muffledRange = effective * ctx.occludedScale
	local occluded = false
	if ctx.occludedScale < 1 and distance > 1e-4 and (ctx.precise or distance > muffledRange) then
		local budget = ctx.budget
		if budget == nil or budget:take(1) then
			occluded = ctx.raycast(position, offset) ~= nil
			if occluded and distance > muffledRange then
				return -- muffled below audibility
			end
		end
		-- Stage 5: starved. `occluded` stays false and the listener hears it.
	end

	listener.onHeard({
		kind = kind,
		position = position,
		radius = radius,
		distance = distance,
		occluded = occluded,
		data = data,
	})
end

-- A listener with `kinds` set hears only those kinds. Checked before anything
-- that costs a call, so an ear that ignores footsteps pays nothing for them.
local function accepts(listener: Types.Listener, kind: string): boolean
	local kinds = listener.kinds
	return kinds == nil or kinds[kind] == true
end

function Hearing.new(config: Config?): Types.Hearing
	local cfg: Config = config or {}
	assert(
		cfg.occludedScale == nil
			or (type(cfg.occludedScale) == "number" and cfg.occludedScale > 0 and cfg.occludedScale <= 1),
		"Perception.Hearing.new: occludedScale must be in (0, 1] when set"
	)
	assert(
		cfg.params == nil or cfg.occluders == nil,
		"Perception.Hearing.new: pass params OR occluders, not both (occluders builds an Include filter)"
	)
	assert(
		cfg.occluders == nil or type(cfg.occluders) == "table",
		"Perception.Hearing.new: occluders must be an array of Instances when set"
	)

	local occludedScale = cfg.occludedScale or 0.5
	local params = cfg.params
	if params == nil and cfg.occluders ~= nil then
		local include = RaycastParams.new()
		include.FilterType = Enum.RaycastFilterType.Include
		include.FilterDescendantsInstances = cfg.occluders
		params = include
	end

	local ctx: Context = {
		raycast = cfg.raycast or Raycaster.new(params),
		occludedScale = occludedScale,
		budget = cfg.budget,
		precise = cfg.preciseOcclusion == true,
	}

	local listeners: { [Types.Listener]: boolean } = {}
	-- ref -> that ref's ears, so an array audience never walks the registry.
	local byRef: { [any]: { [Types.Listener]: boolean } } = {}
	local total = 0

	local bus = {} :: Types.Hearing

	-- Register an ear. Returns a disconnect function; calling it twice is fine.
	function bus.listen(_, listener: Types.Listener): () -> ()
		assert(type(listener) == "table", "Perception.Hearing: listen needs a listener table")
		assert(type(listener.position) == "function", "Perception.Hearing: listener.position() is required")
		assert(type(listener.onHeard) == "function", "Perception.Hearing: listener.onHeard(sound) is required")
		assert(
			listener.acuity == nil or (type(listener.acuity) == "number" and listener.acuity > 0),
			"Perception.Hearing: listener.acuity must be a number > 0 when set"
		)
		assert(
			listener.kinds == nil or type(listener.kinds) == "table",
			"Perception.Hearing: listener.kinds must be a { [kind]: true } table when set"
		)

		if not listeners[listener] then
			listeners[listener] = true
			total += 1
			local ref = listener.ref
			if ref ~= nil then
				local ears = byRef[ref]
				if not ears then
					ears = {}
					byRef[ref] = ears
				end
				ears[listener] = true
			end
		end

		return function()
			if not listeners[listener] then
				return -- already disconnected
			end
			listeners[listener] = nil
			total -= 1
			local ref = listener.ref
			if ref ~= nil then
				local ears = byRef[ref]
				if ears then
					ears[listener] = nil
					if next(ears) == nil then
						byRef[ref] = nil
					end
				end
			end
		end
	end

	local function isolate(listener: Types.Listener, kind: string, position: any, radius: number, data: any?, filter)
		local ok, err = pcall(deliver, listener, ctx, kind, position, radius, data, filter)
		if not ok then
			warn(`[Perception] Hearing listener errored on "{kind}":\n{err}`)
		end
	end

	-- Broadcast one sound. Call this AT the noisy event, from any script:
	-- bus:emit("gunshot", muzzle.Position, 80, { shooter = player }).
	--
	-- `audience` narrows WHO is even considered, before range or rays:
	--   nil                -- every registered listener (the default)
	--   { refA, refB, ... } -- only these refs; walks the audience, not the
	--                          registry, so cost is O(#audience). Reaches only
	--                          listeners that declared a matching `ref`.
	--   function(ref)      -- keep the listener when it returns true; `ref` is
	--                          nil for listeners that declared none. The natural
	--                          form for "not my own team".
	function bus.emit(_, kind: string, position: any, radius: number, data: any?, audience: Types.Audience?)
		assert(type(kind) == "string" and kind ~= "", "Perception.Hearing: emit needs a non-empty kind string")
		assert(position ~= nil, "Perception.Hearing: emit needs a position")
		assert(type(radius) == "number" and radius > 0, "Perception.Hearing: emit radius must be a number > 0")
		assert(
			audience == nil or type(audience) == "table" or type(audience) == "function",
			"Perception.Hearing: emit audience must be an array of refs or a (ref) -> boolean predicate"
		)

		if type(audience) == "table" then
			-- Walk the audience. A ref with no registered ear is simply skipped.
			--
			-- `delivered` dedupes: a caller assembling `{ ...squad, commander }` can
			-- easily list the same ref twice, and without this each duplicate fires
			-- onHeard again -- two stimulates, two plan steps, two rays, for one
			-- sound. One small table per targeted emit is worth that.
			local delivered: { [Types.Listener]: boolean } = {}
			for _, ref in audience :: { any } do
				local ears = byRef[ref]
				if ears then
					for listener in ears do
						if not delivered[listener] and accepts(listener, kind) then
							delivered[listener] = true
							isolate(listener, kind, position, radius, data, nil)
						end
					end
				end
			end
			return
		end

		local filter = audience :: ((ref: any) -> boolean)?
		for listener in listeners do
			if accepts(listener, kind) then
				isolate(listener, kind, position, radius, data, filter)
			end
		end
	end

	-- Drop every ear a ref registered. Listeners are held STRONGLY (a bus must
	-- keep an inline `bus:listen({ ... })` alive -- weak keys would collect a
	-- listener the caller never stored a reference to), so a despawning bot has to
	-- be unregistered explicitly. This is the version that does not require
	-- holding on to each disconnect closure.
	function bus.forget(_, ref: any)
		assert(ref ~= nil, "Perception.Hearing: forget needs a ref")
		local ears = byRef[ref]
		if not ears then
			return
		end
		for listener in ears do
			if listeners[listener] then
				listeners[listener] = nil
				total -= 1
			end
		end
		byRef[ref] = nil
	end

	function bus.count(_): number
		return total
	end

	return bus
end

return Hearing
