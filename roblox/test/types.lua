-- Roblox value types for the offline test harness: Vector3, CFrame, Color3, UDim2 and friends.
-- Only what the game scripts (and the mock engine) need, but done properly: wrong operand types
-- raise errors the way Roblox does, so mistakes show up here instead of in Studio.

local T = {}
local sqrt, floor, abs, sin, cos = math.sqrt, math.floor, math.abs, math.sin, math.cos

function T.typeof(v)
	local t = type(v)
	if t == "table" then
		local mt = getmetatable(v)
		if mt then
			local name = rawget(mt, "__type")
			if name then
				return name
			end
		end
	end
	return t
end
local typeof = T.typeof

local function bad(op, a, b)
	error("attempt to perform arithmetic (" .. op .. ") on " .. typeof(a) .. " and " .. typeof(b), 3)
end

local function num(v, what, level)
	if type(v) ~= "number" then
		error(what .. ": number expected, got " .. typeof(v), (level or 2) + 1)
	end
	return v
end

---------------------------------------------------------------------------------------------------
-- Vector3
---------------------------------------------------------------------------------------------------

local V3 = { __type = "Vector3" }
local V3m = {}

local function vec3(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, V3)
end

V3.__index = function(v, k)
	if k == "Magnitude" then
		return sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		return vec3(v.X / m, v.Y / m, v.Z / m)   -- a zero vector gives NaN, as in Roblox
	end
	local f = V3m[k]
	if f then
		return f
	end
	error(tostring(k) .. " is not a valid member of Vector3", 2)
end
V3.__newindex = function(_, k)
	error(tostring(k) .. " cannot be assigned to", 2)
end
V3.__add = function(a, b)
	if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
		bad("add", a, b)
	end
	return vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a, b)
	if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
		bad("sub", a, b)
	end
	return vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		return vec3(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return vec3(a.X * b, a.Y * b, a.Z * b)
	elseif typeof(a) == "Vector3" and typeof(b) == "Vector3" then
		return vec3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end
	bad("mul", a, b)
end
V3.__div = function(a, b)
	if type(b) == "number" then
		return vec3(a.X / b, a.Y / b, a.Z / b)
	elseif typeof(a) == "Vector3" and typeof(b) == "Vector3" then
		return vec3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
	end
	bad("div", a, b)
end
V3.__unm = function(a)
	return vec3(-a.X, -a.Y, -a.Z)
end
V3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3.__tostring = function(a)
	return a.X .. ", " .. a.Y .. ", " .. a.Z
end

function V3m.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V3m.Cross(a, b)
	return vec3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V3m.Lerp(a, b, t)
	if typeof(b) ~= "Vector3" then
		error("Vector3:Lerp: Vector3 expected, got " .. typeof(b), 2)
	end
	num(t, "Vector3:Lerp alpha")
	return vec3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end
function V3m.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	return abs(a.X - b.X) <= eps and abs(a.Y - b.Y) <= eps and abs(a.Z - b.Z) <= eps
end

T.Vector3 = {
	new = function(x, y, z)
		return vec3(num(x or 0, "Vector3.new"), num(y or 0, "Vector3.new"), num(z or 0, "Vector3.new"))
	end,
	zero = vec3(0, 0, 0),
	one = vec3(1, 1, 1),
	xAxis = vec3(1, 0, 0),
	yAxis = vec3(0, 1, 0),
	zAxis = vec3(0, 0, 1),
}

---------------------------------------------------------------------------------------------------
-- Vector2
---------------------------------------------------------------------------------------------------

local V2 = { __type = "Vector2" }
local function vec2(x, y)
	return setmetatable({ X = x, Y = y }, V2)
end
V2.__index = function(v, k)
	if k == "Magnitude" then
		return sqrt(v.X * v.X + v.Y * v.Y)
	elseif k == "Unit" then
		local m = sqrt(v.X * v.X + v.Y * v.Y)
		return vec2(v.X / m, v.Y / m)
	elseif k == "Lerp" then
		return function(a, b, t)
			return vec2(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t)
		end
	end
	error(tostring(k) .. " is not a valid member of Vector2", 2)
end
V2.__add = function(a, b)
	if typeof(a) ~= "Vector2" or typeof(b) ~= "Vector2" then
		bad("add", a, b)
	end
	return vec2(a.X + b.X, a.Y + b.Y)
end
V2.__sub = function(a, b)
	if typeof(a) ~= "Vector2" or typeof(b) ~= "Vector2" then
		bad("sub", a, b)
	end
	return vec2(a.X - b.X, a.Y - b.Y)
end
V2.__mul = function(a, b)
	if type(a) == "number" then
		return vec2(a * b.X, a * b.Y)
	elseif type(b) == "number" then
		return vec2(a.X * b, a.Y * b)
	end
	return vec2(a.X * b.X, a.Y * b.Y)
end
V2.__div = function(a, b)
	if type(b) == "number" then
		return vec2(a.X / b, a.Y / b)
	end
	return vec2(a.X / b.X, a.Y / b.Y)
end
V2.__unm = function(a)
	return vec2(-a.X, -a.Y)
end
V2.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
V2.__tostring = function(a)
	return a.X .. ", " .. a.Y
end
T.Vector2 = {
	new = function(x, y)
		return vec2(num(x or 0, "Vector2.new"), num(y or 0, "Vector2.new"))
	end,
	zero = vec2(0, 0),
	one = vec2(1, 1),
}

---------------------------------------------------------------------------------------------------
-- CFrame: position plus a 3x3 rotation, stored row by row
---------------------------------------------------------------------------------------------------

local CF = { __type = "CFrame" }
local CFm = {}

local function cframe(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return setmetatable({ x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }, CF)
end

local function lookAt(px, py, pz, tx, ty, tz)
	local bx, by, bz = px - tx, py - ty, pz - tz
	local bm = sqrt(bx * bx + by * by + bz * bz)
	if bm < 1e-9 then
		return cframe(px, py, pz, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	bx, by, bz = bx / bm, by / bm, bz / bm
	-- right = up x back, with world up (0, 1, 0)
	local rx, ry, rz = bz, 0, -bx
	local rm = sqrt(rx * rx + rz * rz)
	if rm < 1e-6 then
		rx, ry, rz, rm = 1, 0, 0, 1   -- looking straight up or down
	end
	rx, rz = rx / rm, rz / rm
	local ux, uy, uz = by * rz - bz * ry, bz * rx - bx * rz, bx * ry - by * rx
	return cframe(px, py, pz, rx, ux, bx, ry, uy, by, rz, uz, bz)
end

CF.__index = function(c, k)
	if k == "Position" then
		return vec3(c[1], c[2], c[3])
	elseif k == "X" then
		return c[1]
	elseif k == "Y" then
		return c[2]
	elseif k == "Z" then
		return c[3]
	elseif k == "LookVector" then
		return vec3(-c[6], -c[9], -c[12])
	elseif k == "RightVector" or k == "XVector" then
		return vec3(c[4], c[7], c[10])
	elseif k == "UpVector" or k == "YVector" then
		return vec3(c[5], c[8], c[11])
	elseif k == "ZVector" then
		return vec3(c[6], c[9], c[12])
	elseif k == "Rotation" then
		return cframe(0, 0, 0, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	end
	local f = CFm[k]
	if f then
		return f
	end
	error(tostring(k) .. " is not a valid member of CFrame", 2)
end

local function cfMul(a, b)
	return cframe(
		a[4] * b[1] + a[5] * b[2] + a[6] * b[3] + a[1],
		a[7] * b[1] + a[8] * b[2] + a[9] * b[3] + a[2],
		a[10] * b[1] + a[11] * b[2] + a[12] * b[3] + a[3],
		a[4] * b[4] + a[5] * b[7] + a[6] * b[10], a[4] * b[5] + a[5] * b[8] + a[6] * b[11], a[4] * b[6] + a[5] * b[9] + a[6] * b[12],
		a[7] * b[4] + a[8] * b[7] + a[9] * b[10], a[7] * b[5] + a[8] * b[8] + a[9] * b[11], a[7] * b[6] + a[8] * b[9] + a[9] * b[12],
		a[10] * b[4] + a[11] * b[7] + a[12] * b[10], a[10] * b[5] + a[11] * b[8] + a[12] * b[11], a[10] * b[6] + a[11] * b[9] + a[12] * b[12])
end

CF.__mul = function(a, b)
	if typeof(a) ~= "CFrame" then
		bad("mul", a, b)
	end
	local tb = typeof(b)
	if tb == "CFrame" then
		return cfMul(a, b)
	elseif tb == "Vector3" then
		return vec3(
			a[4] * b.X + a[5] * b.Y + a[6] * b.Z + a[1],
			a[7] * b.X + a[8] * b.Y + a[9] * b.Z + a[2],
			a[10] * b.X + a[11] * b.Y + a[12] * b.Z + a[3])
	end
	bad("mul", a, b)
end
CF.__add = function(a, b)
	if typeof(a) ~= "CFrame" or typeof(b) ~= "Vector3" then
		bad("add", a, b)
	end
	return cframe(a[1] + b.X, a[2] + b.Y, a[3] + b.Z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
end
CF.__sub = function(a, b)
	if typeof(a) ~= "CFrame" or typeof(b) ~= "Vector3" then
		bad("sub", a, b)
	end
	return cframe(a[1] - b.X, a[2] - b.Y, a[3] - b.Z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
end
CF.__eq = function(a, b)
	for i = 1, 12 do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end
CF.__tostring = function(a)
	return table.concat(a, ", ")
end

function CFm.Inverse(c)
	local x, y, z = c[1], c[2], c[3]
	return cframe(
		-(c[4] * x + c[7] * y + c[10] * z), -(c[5] * x + c[8] * y + c[11] * z), -(c[6] * x + c[9] * y + c[12] * z),
		c[4], c[7], c[10], c[5], c[8], c[11], c[6], c[9], c[12])
end
function CFm.ToWorldSpace(c, other)
	return cfMul(c, other)
end
function CFm.ToObjectSpace(c, other)
	return cfMul(CFm.Inverse(c), other)
end
function CFm.PointToWorldSpace(c, v)
	return c * v
end
function CFm.PointToObjectSpace(c, v)
	return CFm.Inverse(c) * v
end
function CFm.VectorToWorldSpace(c, v)
	return vec3(c[4] * v.X + c[5] * v.Y + c[6] * v.Z, c[7] * v.X + c[8] * v.Y + c[9] * v.Z, c[10] * v.X + c[11] * v.Y + c[12] * v.Z)
end
function CFm.VectorToObjectSpace(c, v)
	return vec3(c[4] * v.X + c[7] * v.Y + c[10] * v.Z, c[5] * v.X + c[8] * v.Y + c[11] * v.Z, c[6] * v.X + c[9] * v.Y + c[12] * v.Z)
end
function CFm.GetComponents(c)
	return unpack(c, 1, 12)
end
function CFm.Lerp(a, b, t)
	-- positions blend exactly; the rotation is blended and re-squared, close enough for tests
	local out = {}
	for i = 1, 12 do
		out[i] = a[i] + (b[i] - a[i]) * t
	end
	local fixed = lookAt(0, 0, 0, -out[6], -out[9], -out[12])
	return cframe(out[1], out[2], out[3], fixed[4], fixed[5], fixed[6], fixed[7], fixed[8], fixed[9], fixed[10], fixed[11], fixed[12])
end

local function angles(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = cos(rx), sin(rx), cos(ry), sin(ry), cos(rz), sin(rz)
	-- R = Rx * Ry * Rz
	return cframe(0, 0, 0,
		cy * cz, -cy * sz, sy,
		sx * sy * cz + cx * sz, -sx * sy * sz + cx * cz, -sx * cy,
		-cx * sy * cz + sx * sz, cx * sy * sz + sx * cz, cx * cy)
end

T.CFrame = {
	new = function(...)
		local n = select("#", ...)
		local a, b = ...
		if n == 0 then
			return cframe(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		elseif n == 1 then
			if typeof(a) ~= "Vector3" then
				error("CFrame.new: Vector3 expected, got " .. typeof(a), 2)
			end
			return cframe(a.X, a.Y, a.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		elseif n == 2 then
			if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
				error("CFrame.new: two Vector3 expected, got " .. typeof(a) .. " and " .. typeof(b), 2)
			end
			return lookAt(a.X, a.Y, a.Z, b.X, b.Y, b.Z)
		elseif n == 3 then
			local x, y, z = ...
			return cframe(num(x, "CFrame.new"), num(y, "CFrame.new"), num(z, "CFrame.new"), 1, 0, 0, 0, 1, 0, 0, 0, 1)
		elseif n == 12 then
			for i = 1, 12 do
				num((select(i, ...)), "CFrame.new")
			end
			return cframe(...)
		end
		error("CFrame.new: unsupported number of arguments (" .. n .. ")", 2)
	end,
	lookAt = function(at, target)
		if typeof(at) ~= "Vector3" or typeof(target) ~= "Vector3" then
			error("CFrame.lookAt: two Vector3 expected", 2)
		end
		return lookAt(at.X, at.Y, at.Z, target.X, target.Y, target.Z)
	end,
	Angles = function(rx, ry, rz)
		return angles(num(rx, "CFrame.Angles"), num(ry, "CFrame.Angles"), num(rz, "CFrame.Angles"))
	end,
	fromEulerAnglesXYZ = function(rx, ry, rz)
		return angles(rx, ry, rz)
	end,
	identity = cframe(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1),
}

---------------------------------------------------------------------------------------------------
-- Color3
---------------------------------------------------------------------------------------------------

local C3 = { __type = "Color3" }
local C3m = {}
local function color3(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, C3)
end
C3.__index = function(_, k)
	local f = C3m[k]
	if f then
		return f
	end
	error(tostring(k) .. " is not a valid member of Color3", 2)
end
C3.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
C3.__tostring = function(a)
	return a.R .. ", " .. a.G .. ", " .. a.B
end
function C3m.Lerp(a, b, t)
	if typeof(b) ~= "Color3" then
		error("Color3:Lerp: Color3 expected, got " .. typeof(b), 2)
	end
	num(t, "Color3:Lerp alpha")
	return color3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
function C3m.ToHSV(c)
	local mx, mn = math.max(c.R, c.G, c.B), math.min(c.R, c.G, c.B)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == c.R then
			h = ((c.G - c.B) / d) % 6
		elseif mx == c.G then
			h = (c.B - c.R) / d + 2
		else
			h = (c.R - c.G) / d + 4
		end
		h = h / 6
	end
	return h, mx == 0 and 0 or d / mx, mx
end
T.Color3 = {
	new = function(r, g, b)
		return color3(num(r or 0, "Color3.new"), num(g or 0, "Color3.new"), num(b or 0, "Color3.new"))
	end,
	fromRGB = function(r, g, b)
		return color3(num(r, "Color3.fromRGB") / 255, num(g, "Color3.fromRGB") / 255, num(b, "Color3.fromRGB") / 255)
	end,
	fromHSV = function(h, s, v)
		num(h, "Color3.fromHSV")
		num(s, "Color3.fromHSV")
		num(v, "Color3.fromHSV")
		if h ~= h or s ~= s or v ~= v then
			error("Color3.fromHSV: NaN component", 2)
		end
		local i = floor(h * 6)
		local f = h * 6 - i
		local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
		i = i % 6
		if i == 0 then
			return color3(v, t, p)
		elseif i == 1 then
			return color3(q, v, p)
		elseif i == 2 then
			return color3(p, v, t)
		elseif i == 3 then
			return color3(p, q, v)
		elseif i == 4 then
			return color3(t, p, v)
		end
		return color3(v, p, q)
	end,
}

---------------------------------------------------------------------------------------------------
-- UDim, UDim2
---------------------------------------------------------------------------------------------------

local UD = { __type = "UDim" }
local function udim(s, o)
	return setmetatable({ Scale = s, Offset = o }, UD)
end
UD.__index = function(_, k)
	error(tostring(k) .. " is not a valid member of UDim", 2)
end
UD.__eq = function(a, b)
	return a.Scale == b.Scale and a.Offset == b.Offset
end
UD.__add = function(a, b)
	return udim(a.Scale + b.Scale, a.Offset + b.Offset)
end
UD.__sub = function(a, b)
	return udim(a.Scale - b.Scale, a.Offset - b.Offset)
end
T.UDim = {
	new = function(s, o)
		return udim(num(s or 0, "UDim.new"), num(o or 0, "UDim.new"))
	end,
}

local UD2 = { __type = "UDim2" }
local function udim2(xs, xo, ys, yo)
	return setmetatable({ X = udim(xs, xo), Y = udim(ys, yo) }, UD2)
end
UD2.__index = function(u, k)
	if k == "Width" then
		return u.X
	elseif k == "Height" then
		return u.Y
	elseif k == "Lerp" then
		return function(a, b, t)
			return udim2(a.X.Scale + (b.X.Scale - a.X.Scale) * t, a.X.Offset + (b.X.Offset - a.X.Offset) * t,
				a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t, a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t)
		end
	end
	error(tostring(k) .. " is not a valid member of UDim2", 2)
end
UD2.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
UD2.__add = function(a, b)
	return udim2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
end
UD2.__sub = function(a, b)
	return udim2(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
end
T.UDim2 = {
	new = function(a, b, c, d)
		if typeof(a) == "UDim" then
			if typeof(b) ~= "UDim" then
				error("UDim2.new: UDim expected, got " .. typeof(b), 2)
			end
			return udim2(a.Scale, a.Offset, b.Scale, b.Offset)
		end
		return udim2(num(a or 0, "UDim2.new"), num(b or 0, "UDim2.new"), num(c or 0, "UDim2.new"), num(d or 0, "UDim2.new"))
	end,
	fromScale = function(x, y)
		return udim2(num(x, "UDim2.fromScale"), 0, num(y, "UDim2.fromScale"), 0)
	end,
	fromOffset = function(x, y)
		return udim2(0, num(x, "UDim2.fromOffset"), 0, num(y, "UDim2.fromOffset"))
	end,
}

---------------------------------------------------------------------------------------------------
-- Small value types
---------------------------------------------------------------------------------------------------

local function simple(name)
	local mt = { __type = name }
	mt.__index = function(_, k)
		error(tostring(k) .. " is not a valid member of " .. name, 2)
	end
	return mt
end

local NR = simple("NumberRange")
T.NumberRange = {
	new = function(a, b)
		num(a, "NumberRange.new")
		if b ~= nil then
			num(b, "NumberRange.new")
			if b < a then
				error("NumberRange: invalid range", 2)
			end
		end
		return setmetatable({ Min = a, Max = b or a }, NR)
	end,
}

local NSK = simple("NumberSequenceKeypoint")
T.NumberSequenceKeypoint = {
	new = function(time, value, envelope)
		return setmetatable({ Time = num(time, "NumberSequenceKeypoint.new"), Value = num(value, "NumberSequenceKeypoint.new"),
			Envelope = envelope or 0 }, NSK)
	end,
}
local NS = simple("NumberSequence")
T.NumberSequence = {
	new = function(a, b)
		local points
		if type(a) == "number" then
			points = { T.NumberSequenceKeypoint.new(0, a), T.NumberSequenceKeypoint.new(1, b or a) }
		elseif type(a) == "table" and typeof(a) == "table" then
			points = a
			if #points < 2 then
				error("NumberSequence: requires at least 2 keypoints", 2)
			end
			for i, p in ipairs(points) do
				if typeof(p) ~= "NumberSequenceKeypoint" then
					error("NumberSequence: keypoint " .. i .. " is a " .. typeof(p), 2)
				end
			end
			if points[1].Time ~= 0 or points[#points].Time ~= 1 then
				error("NumberSequence: must start at 0 and end at 1", 2)
			end
		else
			error("NumberSequence.new: number or table expected, got " .. typeof(a), 2)
		end
		return setmetatable({ Keypoints = points }, NS)
	end,
}

local CSK = simple("ColorSequenceKeypoint")
T.ColorSequenceKeypoint = {
	new = function(time, color)
		if typeof(color) ~= "Color3" then
			error("ColorSequenceKeypoint.new: Color3 expected, got " .. typeof(color), 2)
		end
		return setmetatable({ Time = num(time, "ColorSequenceKeypoint.new"), Value = color }, CSK)
	end,
}
local CS = simple("ColorSequence")
T.ColorSequence = {
	new = function(a, b)
		local points
		if typeof(a) == "Color3" then
			if b ~= nil and typeof(b) ~= "Color3" then
				error("ColorSequence.new: Color3 expected, got " .. typeof(b), 2)
			end
			points = { T.ColorSequenceKeypoint.new(0, a), T.ColorSequenceKeypoint.new(1, b or a) }
		elseif typeof(a) == "table" then
			points = a
			if #points < 2 then
				error("ColorSequence: requires at least 2 keypoints", 2)
			end
			for i, p in ipairs(points) do
				if typeof(p) ~= "ColorSequenceKeypoint" then
					error("ColorSequence: keypoint " .. i .. " is a " .. typeof(p), 2)
				end
			end
			if points[1].Time ~= 0 or points[#points].Time ~= 1 then
				error("ColorSequence: must start at 0 and end at 1", 2)
			end
		else
			error("ColorSequence.new: Color3 or table expected, got " .. typeof(a), 2)
		end
		return setmetatable({ Keypoints = points }, CS)
	end,
}

local RECT = simple("Rect")
T.Rect = {
	new = function(a, b, c, d)
		return setmetatable({ Min = vec2(a or 0, b or 0), Max = vec2(c or 0, d or 0) }, RECT)
	end,
}

local RAY = simple("Ray")
T.Ray = {
	new = function(origin, direction)
		if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
			error("Ray.new: two Vector3 expected", 2)
		end
		return setmetatable({ Origin = origin, Direction = direction }, RAY)
	end,
}

local TI = simple("TweenInfo")
T.TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delay)
		return setmetatable({ Time = time or 1, EasingStyle = style, EasingDirection = direction,
			RepeatCount = repeatCount or 0, Reverses = reverses or false, DelayTime = delay or 0 }, TI)
	end,
}

local FONT = simple("Font")
T.Font = {
	new = function(family, weight, style)
		return setmetatable({ Family = family, Weight = weight, Style = style }, FONT)
	end,
	fromEnum = function(item)
		return setmetatable({ Family = tostring(item), Weight = false, Style = false }, FONT)
	end,
}

local BC = simple("BrickColor")
T.BrickColor = {
	new = function(name)
		return setmetatable({ Name = tostring(name), Color = color3(0.64, 0.64, 0.65), Number = 194 }, BC)
	end,
}

local PP = simple("PhysicalProperties")
T.PhysicalProperties = {
	new = function(density, friction, elasticity, frictionWeight, elasticityWeight)
		return setmetatable({ Density = density, Friction = friction or 0.3, Elasticity = elasticity or 0.5,
			FrictionWeight = frictionWeight or 1, ElasticityWeight = elasticityWeight or 1 }, PP)
	end,
}

-- Random: every generator draws from one seeded stream, so a test run can be repeated exactly.
local RND = { __type = "Random" }
RND.__index = RND
function RND:NextInteger(a, b)
	num(a, "Random:NextInteger")
	num(b, "Random:NextInteger")
	if a ~= floor(a) or b ~= floor(b) then
		error("Random:NextInteger: arguments must be integers", 2)
	end
	if b < a then
		error("Random:NextInteger: empty interval", 2)
	end
	return math.random(a, b)
end
function RND:NextNumber(a, b)
	if a == nil then
		return math.random()
	end
	num(a, "Random:NextNumber")
	num(b, "Random:NextNumber")
	return a + (b - a) * math.random()
end
function RND:NextUnitVector()
	local v
	repeat
		v = vec3(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
	until v.Magnitude > 0.01 and v.Magnitude <= 1
	return v.Unit
end
T.Random = {
	new = function()
		return setmetatable({}, RND)
	end,
}

-- which type names count as data types when checking a property assignment
T.vec3, T.vec2, T.cframe, T.color3, T.udim2 = vec3, vec2, cframe, color3, udim2

return T
