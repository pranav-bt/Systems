-- Zone.query: the same geometry the sweep uses, without a Zone.
--
-- The point of these being public is that a caller asking directly gets the SAME answer a
-- Zone would give. So every containment check here is also run through a real Zone and the
-- two are required to agree -- which is the assertion that stops the two drifting apart.
local rbx = require("./shim/roblox")
local Zone = require("./shim/library")("Zone")

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
		print(("  ok   %s"):format(name))
	else
		failed += 1
		print(("  FAIL %s -- %s"):format(name, tostring(detail)))
	end
end

-- A bare Part, only so pointInPart has a real `.Shape` and `.Size` to dispatch on. Zones are
-- built with Zone.new(CFrame, Size, Shape) and provision their own part.
local function part(shape, size, position)
	local p = rbx.Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.CFrame = rbx.CFrame.new(position or rbx.Vector3.new(0, 0, 0))
	p.Parent = rbx.workspace
	return p
end

local V = rbx.Vector3.new
local Block, Ball, Cylinder = rbx.Enum.PartType.Block, rbx.Enum.PartType.Ball, rbx.Enum.PartType.Cylinder

print("point in a box")
do
	local cf = rbx.CFrame.new(V(0, 0, 0))
	local size = V(10, 4, 6)
	check("the centre is inside", Zone.query.pointInBox(V(0, 0, 0), cf, size))
	check("just inside a face", Zone.query.pointInBox(V(4.9, 0, 0), cf, size))
	check("exactly on a face counts", Zone.query.pointInBox(V(5, 0, 0), cf, size))
	check("just outside is out", not Zone.query.pointInBox(V(5.1, 0, 0), cf, size))
	-- The size is FULL size, not half-extents: a caller passing half would get a box half as
	-- big and no error to say so.
	check("the short axis is respected", not Zone.query.pointInBox(V(0, 2.1, 0), cf, size))
	check("and the third", not Zone.query.pointInBox(V(0, 0, 3.1), cf, size))
end

print("point in a ball, as an ELLIPSOID")
do
	local cf = rbx.CFrame.new(V(0, 0, 0))
	-- Not a sphere: 10 x 4 x 4. Testing it as one radius accepts points well outside.
	local size = V(10, 4, 4)
	check("the centre is inside", Zone.query.pointInBall(V(0, 0, 0), cf, size))
	check("along the long axis, inside", Zone.query.pointInBall(V(4.9, 0, 0), cf, size))
	check("past the long axis, outside", not Zone.query.pointInBall(V(5.1, 0, 0), cf, size))
	check("along the short axis, inside", Zone.query.pointInBall(V(0, 1.9, 0), cf, size))
	-- The whole reason the ellipsoid form exists: a single-radius test would accept this.
	check("past the SHORT axis, outside", not Zone.query.pointInBall(V(0, 2.1, 0), cf, size))
	--[[
		THE CORNER. Every probe above sits on an axis, where a BOX of the same size gives the
		same answer -- so none of them can tell an ellipsoid from its own bounding box. This
		one can: (1.9/2)^2 + (1.9/2)^2 = 1.8, comfortably outside the ellipsoid and comfortably
		inside the box.
	]]
	check("the bounding-box corner is outside the ellipsoid", not Zone.query.pointInBall(V(0, 1.9, 1.9), cf, size))
end

print("point in a cylinder, whose height runs along X")
do
	local cf = rbx.CFrame.new(V(0, 0, 0))
	local size = V(10, 4, 4)
	check("the centre is inside", Zone.query.pointInCylinder(V(0, 0, 0), cf, size))
	-- Roblox runs a cylinder's height along X. A caller guessing Y gets this backwards.
	check("along the height, inside", Zone.query.pointInCylinder(V(4.9, 0, 0), cf, size))
	check("past the height, outside", not Zone.query.pointInCylinder(V(5.1, 0, 0), cf, size))
	check("inside the cross-section", Zone.query.pointInCylinder(V(0, 1.9, 0), cf, size))
	check("outside the cross-section", not Zone.query.pointInCylinder(V(0, 2.1, 0), cf, size))
	-- The corner of the bounding box is outside the round cross-section.
	check("the bounding-box corner is NOT inside", not Zone.query.pointInCylinder(V(0, 1.9, 1.9), cf, size))
end

print("pointInPart dispatches on the part's own shape")
do
	local ball = part(Ball, V(10, 4, 4))
	local box = part(Block, V(10, 4, 4))
	local probe = V(0, 1.9, 1.9)

	-- The same point, the same size: only the SHAPE differs. A caller that read .Size and
	-- guessed "box" would get this wrong, which is exactly why the dispatch is exposed.
	check("the box contains the corner probe", Zone.query.pointInPart(probe, box))
	check("the ball does not", not Zone.query.pointInPart(probe, ball))

	local cyl = part(Cylinder, V(10, 4, 4))
	check("and the cylinder does not either", not Zone.query.pointInPart(probe, cyl))

	--[[
		A part AWAY FROM THE ORIGIN. Everything above sits at (0,0,0), where world space and
		the part's own space are the same numbers -- so none of it can tell whether the point
		is being transformed at all.
	]]
	local moved = part(Block, V(10, 4, 4), V(100, 0, 0))
	check("its own centre is inside", Zone.query.pointInPart(V(100, 0, 0), moved))
	check("and the world origin is not", not Zone.query.pointInPart(V(0, 0, 0), moved))
end

print("a query agrees with a real Zone, which is the whole point")
do
	--[[
		Two copies of containment maths that agree only until someone edits one is the failure
		this API exists to avoid. Asserting the agreement is what keeps that true.
	]]
	local shapes = {
		{ name = "block", shape = Block },
		{ name = "ball", shape = Ball },
		{ name = "cylinder", shape = Cylinder },
	}
	local probes = {
		V(0, 0, 0),
		V(4.9, 0, 0),
		V(5.1, 0, 0),
		V(0, 1.9, 1.9),
		V(0, 2.1, 0),
		V(3, 1, 1),
		V(-4.5, -1.5, 0),
	}

	for _, entry in shapes do
		local size = V(10, 4, 4)
		local cf = rbx.CFrame.new(V(0, 0, 0))
		local p = part(entry.shape, size, V(0, 0, 0))
		local zone = Zone.new(cf, size, entry.shape)
		local agreed = 0
		for _, probe in probes do
			if zone:Contains(probe) == Zone.query.pointInPart(probe, p) then
				agreed += 1
			end
		end
		check(`a {entry.name} zone agrees with the query on every probe`, agreed == #probes, `{agreed}/{#probes}`)
		zone:Destroy()
	end
end

print("a rotated box is tested in its own space")
do
	-- Rotated 90 degrees about Y: the long axis now runs along world Z.
	local cf = rbx.CFrame.yaw(V(0, 0, 0), math.pi / 2)
	local size = V(10, 4, 4)
	check("a point along world Z is inside", Zone.query.pointInBox(V(0, 0, 4.9), cf, size))
	check("and along world X is outside", not Zone.query.pointInBox(V(4.9, 0, 0), cf, size))
end

print("box vs sphere is exact")
do
	local centre, size = V(0, 0, 0), V(10, 10, 10)
	check("a sphere at the centre touches", Zone.query.boxTouchesSphere(centre, size, V(0, 0, 0), 1))
	check("one reaching a face touches", Zone.query.boxTouchesSphere(centre, size, V(6, 0, 0), 1.1))
	check("one just short does not", not Zone.query.boxTouchesSphere(centre, size, V(6.2, 0, 0), 1))

	--[[
		THE CORNER CASE, which is why this is not a centre-distance test. The sphere at
		(6,6,6) is 1.73 studs from the corner (5,5,5) diagonally, so a radius of 1 does not
		reach it -- but every axis is individually within range, and an axis-wise test says
		yes.
	]]
	check("a sphere near a corner but not reaching it does NOT touch", not Zone.query.boxTouchesSphere(centre, size, V(6, 6, 6), 1))
	check("and one that does reach the corner touches", Zone.query.boxTouchesSphere(centre, size, V(6, 6, 6), 1.8))

	check("a zero radius at the centre still touches", Zone.query.boxTouchesSphere(centre, size, V(0, 0, 0), 0))

	-- Separated on Z ALONE. Every probe above is separated on X, so a test that dropped the Z
	-- term entirely would agree with all of them.
	check("a sphere clear on Z only does not touch", not Zone.query.boxTouchesSphere(centre, size, V(0, 0, 6.2), 1))
	check("and one reaching on Z does", Zone.query.boxTouchesSphere(centre, size, V(0, 0, 5.5), 1))
end

print("box vs oriented box is conservative -- no false NEGATIVES")
do
	local unrotated = rbx.CFrame.new(V(0, 0, 0))
	local size = V(10, 10, 10)

	check("concentric boxes touch", Zone.query.boxTouchesOrientedBox(V(0, 0, 0), V(2, 2, 2), unrotated, size))
	check("a far box does not", not Zone.query.boxTouchesOrientedBox(V(100, 0, 0), V(2, 2, 2), unrotated, size))
	check("one just overlapping a face touches", Zone.query.boxTouchesOrientedBox(V(5.9, 0, 0), V(2, 2, 2), unrotated, size))
	check("one just clear of it does not", not Zone.query.boxTouchesOrientedBox(V(6.1, 0, 0), V(2, 2, 2), unrotated, size))

	-- Rotated: the test must work in the oriented box's space, not the world's.
	local rotated = rbx.CFrame.yaw(V(0, 0, 0), math.pi / 4)
	check("a box at the rotated volume's centre touches", Zone.query.boxTouchesOrientedBox(V(0, 0, 0), V(1, 1, 1), rotated, V(10, 10, 2)))
	--[[
		A thin volume rotated 45 degrees: a probe out along world X is beyond the thin axis
		once the rotation is accounted for. Getting this wrong -- testing in world space --
		reports a hit.
	]]
	check("and one off its thin axis does not", not Zone.query.boxTouchesOrientedBox(V(6, 0, 6), V(1, 1, 1), rotated, V(10, 10, 2)))

	--[[
		THE ASYMMETRY THAT PROVES THE TRANSFORM HAPPENS. The volume is 10 x 10 x 2 turned 45
		degrees, so one XZ diagonal runs along its LONG axis and the other along its THIN one.
		A probe on each diagonal must therefore get DIFFERENT answers.

		Tested as "exactly one of them", not by naming which: that holds whichever way the
		rotation is signed, and the property being asserted is the transform, not the
		handedness. Skip the rotation and both probes are |4|,|4| from the centre -- identical
		by symmetry, and every assertion about them passes either way.
	]]
	local onOneDiagonal = Zone.query.boxTouchesOrientedBox(V(4, 0, 4), V(1, 1, 1), rotated, V(10, 10, 2))
	local onTheOther = Zone.query.boxTouchesOrientedBox(V(4, 0, -4), V(1, 1, 1), rotated, V(10, 10, 2))
	check(
		"the two diagonals of a turned volume disagree",
		onOneDiagonal ~= onTheOther,
		`both said {tostring(onOneDiagonal)}`
	)

	--[[
		CONSERVATIVE, and documented as such: only the oriented box's three axes are tested,
		not the fifteen a full separating-axis test needs. So `false` is always trustworthy
		and `true` may be optimistic. A zero-size probe reduces to point containment, which
		IS exact -- so the two must agree there, and that is the strongest correctness
		statement available for this function.
	]]
	local agreed = 0
	local probes = { V(0, 0, 0), V(4.9, 0, 0), V(5.1, 0, 0), V(0, 5.1, 0), V(20, 20, 20), V(-4, 2, -3) }
	for _, probe in probes do
		local asPoint = Zone.query.pointInBox(probe, unrotated, size)
		local asZeroBox = Zone.query.boxTouchesOrientedBox(probe, V(0, 0, 0), unrotated, size)
		if asPoint == asZeroBox then
			agreed += 1
		end
	end
	check("a zero-size box matches point containment exactly", agreed == #probes, `{agreed}/{#probes}`)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("zone query tests failed", 0)
end
