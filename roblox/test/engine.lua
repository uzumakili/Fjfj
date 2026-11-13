-- A small imitation of the Roblox engine, enough to run the Neon Canvas scripts offline.
--
-- Every class, property, method, event and enum is checked against Roblox's published API dump,
-- so a misspelt property, a wrong value type or a call that does not exist fails here instead of
-- in Studio. On top of that it simulates time, players, characters, simple physics and the
-- network, so whole matches can be played by scripted testers.
--
-- Loaded by run_tests.py:  local M = dofile("engine.lua")(types, classes, enums)

return function(T, SCHEMA_CLASSES, SCHEMA_ENUMS)

local M = { errors = {}, warnings = {}, prints = {}, deprecated = {}, options = { deferred = false, charAddedFirst = true } }
local typeof = T.typeof
local Vector3, Vector2, CFrame, Color3, UDim2, UDim = T.Vector3, T.Vector2, T.CFrame, T.Color3, T.UDim2, T.UDim
local unpack = unpack

-- engine state
local S = {
	clock = 0,
	ctx = nil,          -- who is running right now: the server, or one client
	timers = {},
	seq = 0,
	threadCtx = setmetatable({}, { __mode = "k" }),
	depth = 0,
	deferred = {},
	net = {},           -- remote events waiting to be delivered
	bodies = {},        -- [humanoid] = simple physics body for a player character
	cells = nil,        -- spatial index of things characters can stand on
	renderSteps = {},
	pendingSpawns = {},
	removals = {},
	lastInput = nil,
	mouse = Vector2.new(640, 360),
	keysDown = {},
	device = { mouse = true, keyboard = true, touch = false, gamepad = false },
	viewport = Vector2.new(1280, 720),
}
M.S = S

local D = setmetatable({}, { __mode = "k" })   -- [instance] = its private data
local Enum
local game, workspaceInst
local services = {}

---------------------------------------------------------------------------------------------------
-- Threads, time and signals
---------------------------------------------------------------------------------------------------

local function fail(co, err)
	local trace = co and debug.traceback(co, tostring(err)) or debug.traceback(tostring(err), 2)
	table.insert(M.errors, "[" .. (S.ctx and S.ctx.name or "engine") .. "] " .. trace)
end

local flushDeferred

local function resume(co, ...)
	local prev = S.ctx
	S.ctx = S.threadCtx[co] or prev
	S.depth = S.depth + 1
	local ok, err = coroutine.resume(co, ...)
	S.depth = S.depth - 1
	if not ok then
		fail(co, err)
	end
	S.ctx = prev
	if S.depth == 0 then
		flushDeferred()
	end
	return ok
end

local function spawnIn(context, fn, ...)
	local co = coroutine.create(fn)
	S.threadCtx[co] = context
	resume(co, ...)
	return co
end

local task = {}
function task.spawn(fn, ...)
	if type(fn) == "thread" then
		resume(fn, ...)
		return fn
	end
	if type(fn) ~= "function" then
		error("task.spawn: function expected, got " .. typeof(fn), 2)
	end
	return spawnIn(S.ctx, fn, ...)
end
function task.defer(fn, ...)
	if type(fn) ~= "function" then
		error("task.defer: function expected, got " .. typeof(fn), 2)
	end
	S.seq = S.seq + 1
	table.insert(S.timers, { at = S.clock, fn = fn, args = { n = select("#", ...), ... }, ctx = S.ctx, seq = S.seq })
end
function task.delay(t, fn, ...)
	if type(t) ~= "number" then
		error("task.delay: number expected, got " .. typeof(t), 2)
	end
	if type(fn) ~= "function" then
		error("task.delay: function expected, got " .. typeof(fn), 2)
	end
	S.seq = S.seq + 1
	table.insert(S.timers, { at = S.clock + math.max(t, 0), fn = fn, args = { n = select("#", ...), ... }, ctx = S.ctx, seq = S.seq })
end
function task.wait(t)
	local co = coroutine.running()
	if not co then
		error("task.wait called outside of a script thread", 2)
	end
	if t ~= nil and type(t) ~= "number" then
		error("task.wait: number expected, got " .. typeof(t), 2)
	end
	local started = S.clock
	S.seq = S.seq + 1
	table.insert(S.timers, { at = S.clock + math.max(t or 0, 0), co = co, seq = S.seq })
	coroutine.yield()
	return S.clock - started
end
function task.cancel(co)
	for i = #S.timers, 1, -1 do
		if S.timers[i].co == co then
			table.remove(S.timers, i)
		end
	end
end

local Signal = { __type = "RBXScriptSignal" }
Signal.__index = Signal
local Connection = { __type = "RBXScriptConnection" }
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local conns = self.signal.conns
	for i, c in ipairs(conns) do
		if c == self then
			table.remove(conns, i)
			break
		end
	end
end

local function newSignal(name, clientOnly, serverOnly)
	return setmetatable({ name = name, conns = {}, waiting = {}, clientOnly = clientOnly, serverOnly = serverOnly }, Signal)
end

function Signal:Connect(fn)
	if typeof(self) ~= "RBXScriptSignal" then
		error("Expected ':' not '.' calling member function Connect", 2)
	end
	if type(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 2)
	end
	if self.clientOnly and S.ctx and S.ctx.isServer then
		error(self.name .. " event can only be used from local scripts", 2)
	end
	if self.serverOnly and S.ctx and not S.ctx.isServer then
		error(self.name .. " can only be used on the server", 2)
	end
	local conn = setmetatable({ fn = fn, ctx = S.ctx, Connected = true, signal = self }, Connection)
	table.insert(self.conns, conn)
	return conn
end
function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end
function Signal:Wait()
	local co = coroutine.running()
	table.insert(self.waiting, co)
	return coroutine.yield()
end
-- filter(conn) may limit who hears it (used for remote events aimed at one client)
function Signal:Fire(...)
	return self:FireFor(nil, ...)
end
function Signal:FireFor(filter, ...)
	local conns = {}
	for i, c in ipairs(self.conns) do
		conns[i] = c
	end
	local n = select("#", ...)
	local args = { ... }
	for _, c in ipairs(conns) do
		if c.Connected and (not filter or filter(c)) then
			if M.options.deferred then
				table.insert(S.deferred, function()
					if c.Connected then
						spawnIn(c.ctx, c.fn, unpack(args, 1, n))
					end
				end)
			else
				spawnIn(c.ctx, c.fn, unpack(args, 1, n))
			end
		end
	end
	if not filter and #self.waiting > 0 then
		local waiting = self.waiting
		self.waiting = {}
		for _, co in ipairs(waiting) do
			resume(co, unpack(args, 1, n))
		end
	end
	if S.depth == 0 then
		flushDeferred()
	end
end
function Signal:DisconnectAll()
	for _, c in ipairs(self.conns) do
		c.Connected = false
	end
	self.conns = {}
end

local flushing = false
flushDeferred = function()
	if flushing then
		return
	end
	flushing = true
	local guard = 0
	while #S.deferred > 0 do
		local queue = S.deferred
		S.deferred = {}
		for _, fn in ipairs(queue) do
			fn()
		end
		guard = guard + 1
		if guard > 200 then
			table.insert(M.errors, "[engine] deferred events keep firing each other (more than 200 rounds)")
			S.deferred = {}
			break
		end
	end
	flushing = false
end

---------------------------------------------------------------------------------------------------
-- Enums
---------------------------------------------------------------------------------------------------

local EnumItemMT = { __type = "EnumItem" }
EnumItemMT.__index = function(item, k)
	error(tostring(k) .. " is not a valid member of EnumItem " .. tostring(item), 2)
end
EnumItemMT.__tostring = function(item)
	return "Enum." .. item.EnumType.name .. "." .. item.Name
end
local EnumTypeMT = { __type = "Enum" }
EnumTypeMT.__index = function(e, k)
	if k == "GetEnumItems" then
		return function()
			local out = {}
			for i, item in ipairs(rawget(e, "list")) do
				out[i] = item
			end
			return out
		end
	end
	local item = rawget(e, "items")[k]
	if item then
		return item
	end
	error(tostring(k) .. " is not a valid member of \"Enum." .. rawget(e, "name") .. "\"", 2)
end
EnumTypeMT.__tostring = function(e)
	return rawget(e, "name")
end

local enumTypes = {}
Enum = setmetatable({}, {
	__type = "Enums",
	__index = function(_, name)
		local e = enumTypes[name]
		if e then
			return e
		end
		local def = SCHEMA_ENUMS[name]
		if not def then
			error(tostring(name) .. " is not a valid member of \"Enum\"", 2)
		end
		e = { name = name, items = {}, list = {} }
		for _, pair in ipairs(def) do
			local item = setmetatable({ Name = pair[1], Value = pair[2], EnumType = e }, EnumItemMT)
			e.items[pair[1]] = item
			table.insert(e.list, item)
			for i = 3, #pair do
				e.items[pair[i]] = item   -- renamed items keep answering to their old name
			end
		end
		setmetatable(e, EnumTypeMT)
		enumTypes[name] = e
		return e
	end,
})

---------------------------------------------------------------------------------------------------
-- Class information, taken from the API dump
---------------------------------------------------------------------------------------------------

local infoCache = {}
local function classInfo(name)
	local info = infoCache[name]
	if info ~= nil then
		return info or nil
	end
	local def = SCHEMA_CLASSES[name]
	if not def then
		infoCache[name] = false
		return nil
	end
	info = { name = name, super = def.super, isA = {}, members = {}, chain = { name }, tags = {}, defaults = {}, hooks = {} }
	for _, tag in ipairs(def.tags) do
		info.tags[tag] = true
	end
	local parent = classInfo(def.super)
	if parent then
		for k, v in pairs(parent.members) do
			info.members[k] = v
		end
		for k in pairs(parent.isA) do
			info.isA[k] = true
		end
		for _, c in ipairs(parent.chain) do
			table.insert(info.chain, c)
		end
	end
	info.isA[name] = true
	for pname, p in pairs(def.props) do
		info.members[pname] = { kind = "prop", def = p, owner = name }
	end
	for fname, f in pairs(def.funcs) do
		info.members[fname] = { kind = "func", def = f, owner = name }
	end
	for ename, e in pairs(def.events) do
		info.members[ename] = { kind = "event", def = e, owner = name }
	end
	for cname in pairs(def.callbacks) do
		info.members[cname] = { kind = "callback", owner = name }
	end
	infoCache[name] = info
	return info
end
M.classInfo = classInfo
M.Enum = Enum

-- Defaults the dump cannot tell us (it has none for abstract base classes).
local OVERRIDES
local function buildOverrides()
	OVERRIDES = {
		Instance = { Archivable = true },
		BasePart = {
			Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, CastShadow = true, Transparency = 0,
			Reflectance = 0, Massless = false, Locked = false, LocalTransparencyModifier = 0,
			Color = Color3.fromRGB(163, 162, 165), Material = Enum.Material.Plastic, Size = Vector3.new(4, 1.2, 2),
			CFrame = CFrame.new(), Position = Vector3.new(), AssemblyLinearVelocity = Vector3.new(),
			AssemblyAngularVelocity = Vector3.new(), CollisionGroup = "Default",
		},
		GuiObject = { Visible = true, Interactable = true, BackgroundTransparency = 0, BorderSizePixel = 1, ZIndex = 1,
			BackgroundColor3 = Color3.fromRGB(163, 162, 165) },
		LayerCollector = { Enabled = true, ResetOnSpawn = true },
		GuiButton = { AutoButtonColor = true },
		Constraint = { Enabled = true },
		Light = { Enabled = true, Brightness = 1 },
		PostEffect = { Enabled = true },
		Players = { CharacterAutoLoads = true, RespawnTime = 5 },
		Workspace = { Gravity = 196.2, FallenPartsDestroyHeight = -500 },
		Lighting = { ClockTime = 14, Brightness = 3, GlobalShadows = true },
		Player = { DevEnableMouseLock = true },
		UIListLayout = { FillDirection = Enum.FillDirection.Vertical, HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Top },
		UIGridLayout = { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Top },
	}
end

local function parseDefault(p)
	local s, cat, t = p.default, p.cat, p.type
	if type(s) == "string" and string.sub(s, 1, 10) == "__api_dump" then
		s = nil
	end
	if cat == "Primitive" then
		if t == "bool" then
			return s == "true"
		elseif t == "string" then
			return s or ""
		end
		if s == "INF" then
			return math.huge
		elseif s == "-INF" then
			return -math.huge
		end
		return tonumber(s) or 0
	elseif cat == "Enum" then
		local e = Enum[t]
		return (s and rawget(e, "items")[s]) or rawget(e, "list")[1]
	elseif cat == "DataType" then
		local n = {}
		if s then
			for x in string.gmatch(s, "-?[%d%.]+e?-?%d*") do
				table.insert(n, tonumber(x))
			end
		end
		if t == "Vector3" then
			return Vector3.new(n[1] or 0, n[2] or 0, n[3] or 0)
		elseif t == "Vector2" then
			return Vector2.new(n[1] or 0, n[2] or 0)
		elseif t == "Color3" then
			return Color3.new(n[1] or 0.64, n[2] or 0.64, n[3] or 0.65)
		elseif t == "UDim2" then
			return UDim2.new(n[1] or 0, n[2] or 0, n[3] or 0, n[4] or 0)
		elseif t == "UDim" then
			return UDim.new(n[1] or 0, n[2] or 0)
		elseif t == "CFrame" then
			if #n == 12 then
				return CFrame.new(unpack(n))
			end
			return CFrame.new()
		elseif t == "NumberRange" then
			return T.NumberRange.new(n[1] or 0, math.max(n[1] or 0, n[2] or 0))
		elseif t == "Rect" then
			return T.Rect.new(n[1], n[2], n[3], n[4])
		elseif t == "ColorSequence" then
			return T.ColorSequence.new(Color3.new(1, 1, 1))
		elseif t == "NumberSequence" then
			return T.NumberSequence.new(1)
		elseif t == "Content" or t == "ContentId" then
			return s or ""
		end
	end
	return nil
end

local function defaultFor(info, key, member)
	local cached = info.defaults[key]
	if cached ~= nil then
		if cached == info.defaults then   -- marker for "the default really is nil"
			return nil
		end
		return cached
	end
	local value = nil
	for _, cls in ipairs(info.chain) do
		local o = OVERRIDES[cls]
		if o and o[key] ~= nil then
			value = o[key]
			break
		end
	end
	if value == nil then
		value = parseDefault(member.def)
	end
	info.defaults[key] = value == nil and info.defaults or value
	return value
end

---------------------------------------------------------------------------------------------------
-- Instances
---------------------------------------------------------------------------------------------------

local InstanceMT = { __type = "Instance" }
local methods = {}   -- [className][methodName] = implementation
local getters = {}   -- [className][propName] = function(inst, d)
local setters = {}   -- [className][propName] = function(inst, d, value)

local function fullName(inst)
	local parts = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(parts, 1, D[cur].name)
		cur = D[cur].parent
	end
	return table.concat(parts, ".")
end

local function resolveHook(info, tbl, key)
	local cacheKey = tbl == getters and "g" or (tbl == setters and "s" or "m")
	local cache = info.hooks[cacheKey]
	if not cache then
		cache = {}
		info.hooks[cacheKey] = cache
	end
	local hit = cache[key]
	if hit ~= nil then
		return hit or nil
	end
	for _, cls in ipairs(info.chain) do
		local t = tbl[cls]
		if t and t[key] then
			cache[key] = t[key]
			return t[key]
		end
	end
	cache[key] = false
	return nil
end

local function signalFor(d, key, clientOnly, serverOnly)
	local s = d.signals[key]
	if not s then
		s = newSignal(key, clientOnly, serverOnly)
		d.signals[key] = s
	end
	return s
end

local function fire(inst, eventName, ...)
	local s = D[inst].signals[eventName]
	if s then
		s:Fire(...)
	end
end

local CLIENT_EVENTS = { RenderStepped = true, OnClientEvent = true, PreRender = true }
local SERVER_EVENTS = { OnServerEvent = true }

local function checkType(def, value, key, level)
	local cat, t = def.cat, def.type
	local got = typeof(value)
	local ok = true
	if cat == "Primitive" then
		if t == "bool" then
			ok = got == "boolean"
		elseif t == "string" then
			ok = got == "string"
		else
			ok = got == "number"
		end
	elseif cat == "Enum" then
		ok = got == "EnumItem" and value.EnumType.name == t
		if not ok and got == "EnumItem" then
			error("Unable to assign property " .. key .. ". Enum." .. t .. " expected, got Enum." .. value.EnumType.name, level + 1)
		end
	elseif cat == "Class" then
		ok = value == nil or (got == "Instance" and D[value].info.isA[t] == true)
	elseif cat == "DataType" then
		if t == "Content" or t == "ContentId" then
			ok = got == "string"
		else
			ok = got == t
		end
	end
	if not ok then
		error("Unable to assign property " .. key .. ". " .. t .. " expected, got " .. got, level + 1)
	end
end

local function noteDeprecated(owner, key)
	local id = owner .. "." .. key
	M.deprecated[id] = (M.deprecated[id] or 0) + 1
end

InstanceMT.__index = function(inst, key)
	local d = D[inst]
	if key == "Name" then
		return d.name
	elseif key == "Parent" then
		return d.parent
	elseif key == "ClassName" then
		return d.class
	end
	local info = d.info
	local m = info.members[key]
	if m then
		local kind = m.kind
		if kind == "prop" then
			local def = m.def
			if def.ns or def.rsec ~= "None" then
				error(tostring(key) .. " is not a valid member of " .. d.class .. " \"" .. fullName(inst) .. "\" (not scriptable)", 2)
			end
			if def.dep then
				noteDeprecated(m.owner, key)
			end
			local getter = resolveHook(info, getters, key)
			if getter then
				return getter(inst, d)
			end
			local v = d.props[key]
			if v == nil then
				return defaultFor(info, key, m)
			end
			return v
		elseif kind == "func" then
			local impl = resolveHook(info, methods, key)
			local def = m.def
			if def.dep then
				noteDeprecated(m.owner, key)
			end
			if def.sec ~= "None" then
				error("The current thread cannot call '" .. key .. "' (lacking capability " .. tostring(def.sec) .. ")", 2)
			end
			if not impl then
				return function()
					error("MOCK: " .. m.owner .. ":" .. key .. " is real but not implemented in the test engine", 2)
				end
			end
			local cached = d.info.hooks["w" .. key]
			if not cached then
				local req, max = def.req, def.n
				cached = function(self, ...)
					if typeof(self) ~= "Instance" then
						error("Expected ':' not '.' calling member function " .. key, 2)
					end
					local n = select("#", ...)
					if n < req then
						error("Argument " .. (n + 1) .. " missing or nil in call to " .. key, 2)
					end
					if n > max then
						error(key .. " takes at most " .. max .. " arguments, got " .. n, 2)
					end
					return impl(self, ...)
				end
				d.info.hooks["w" .. key] = cached
			end
			return cached
		elseif kind == "event" then
			if m.def.dep then
				noteDeprecated(m.owner, key)
			end
			return signalFor(d, key, CLIENT_EVENTS[key], SERVER_EVENTS[key])
		else
			return d.props[key]
		end
	end
	for _, child in ipairs(d.children) do
		if D[child].name == key then
			return child
		end
	end
	error(tostring(key) .. " is not a valid member of " .. d.class .. " \"" .. fullName(inst) .. "\"", 2)
end

local setParent

local COLLISION_PROPS = { CFrame = true, Position = true, Size = true, CanCollide = true, Anchored = true, Shape = true }

InstanceMT.__newindex = function(inst, key, value)
	local d = D[inst]
	if key == "Parent" then
		setParent(inst, value, 2)
		return
	elseif key == "Name" then
		if type(value) ~= "string" then
			error("Unable to assign property Name. string expected, got " .. typeof(value), 2)
		end
		d.name = value
		return
	end
	local info = d.info
	local m = info.members[key]
	if not m then
		error(tostring(key) .. " is not a valid member of " .. d.class .. " \"" .. fullName(inst) .. "\"", 2)
	end
	if m.kind == "callback" then
		d.props[key] = value
		return
	elseif m.kind ~= "prop" then
		error(tostring(key) .. " cannot be assigned to", 2)
	end
	local def = m.def
	if def.ns or def.wsec ~= "None" then
		error("The current thread cannot write '" .. key .. "' (lacking capability " .. tostring(def.wsec) .. ")", 2)
	end
	if def.ro then
		error("Unable to assign property " .. key .. ". Property is read only", 2)
	end
	if def.dep then
		noteDeprecated(m.owner, key)
	end
	checkType(def, value, key, 2)
	local old = d.props[key]
	if old == nil then
		old = defaultFor(info, key, m)
	end
	local setter = resolveHook(info, setters, key)
	if setter then
		setter(inst, d, value)
	else
		if old == value then
			return
		end
		d.props[key] = value
	end
	if info.isA.BasePart and COLLISION_PROPS[key] and (not S.ctx or S.ctx.isServer) then
		S.cells = nil
	end
	local ps = d.propSignals[key]
	if ps then
		ps:Fire()
	end
	local changed = d.signals.Changed
	if changed then
		if info.isA.ValueBase then
			if key == "Value" then
				changed:Fire(value)
			end
		else
			changed:Fire(key)
		end
	end
end

InstanceMT.__tostring = function(inst)
	return D[inst].name
end

local function create(className)
	local info = classInfo(className)
	if not info then
		error("Unable to create an Instance of type \"" .. tostring(className) .. "\"", 3)
	end
	local inst = setmetatable({}, InstanceMT)
	D[inst] = {
		class = className, info = info, name = className, props = {}, children = {}, attrs = {},
		signals = {}, propSignals = {}, attrSignals = {},
	}
	return inst
end
M.create = create

-- set a property without any checks (for read-only ones the engine itself maintains)
local function raw(inst, key, value)
	D[inst].props[key] = value
end
M.raw = raw

local function isInWorkspace(inst)
	local cur = inst
	while cur do
		if cur == workspaceInst then
			return true
		end
		cur = D[cur].parent
	end
	return false
end

local function descendants(inst, out)
	out = out or {}
	for _, c in ipairs(D[inst].children) do
		table.insert(out, c)
		descendants(c, out)
	end
	return out
end

setParent = function(inst, parent, level)
	local d = D[inst]
	level = (level or 1) + 1
	if parent ~= nil and typeof(parent) ~= "Instance" then
		error("Unable to assign property Parent. Instance expected, got " .. typeof(parent), level)
	end
	if d.locked then
		if parent ~= nil then
			error("The Parent property of " .. d.name .. " is locked, current parent: NULL, new parent " .. D[parent].name, level)
		end
		return
	end
	local old = d.parent
	if old == parent then
		return
	end
	if parent then
		local cur = parent
		while cur do
			if cur == inst then
				error("Attempt to set " .. d.name .. " as its own parent", level)
			end
			cur = D[cur].parent
		end
	end
	if old then
		local kids = D[old].children
		for i = #kids, 1, -1 do
			if kids[i] == inst then
				table.remove(kids, i)
				break
			end
		end
	end
	d.parent = parent
	if parent then
		table.insert(D[parent].children, inst)
	end
	if d.info.isA.BasePart or #d.children > 0 then
		S.cells = nil
	end
	if old then
		fire(old, "ChildRemoved", inst)
	end
	if parent then
		fire(parent, "ChildAdded", inst)
		local cur = parent
		while cur do
			local s = D[cur].signals.DescendantAdded
			if s then
				s:Fire(inst)
				for _, sub in ipairs(descendants(inst)) do
					s:Fire(sub)
				end
			end
			cur = D[cur].parent
		end
	end
	fire(inst, "AncestryChanged", inst, parent)
	if #d.children > 0 then
		for _, sub in ipairs(descendants(inst)) do
			fire(sub, "AncestryChanged", inst, parent)
		end
	end
	local ps = d.propSignals.Parent
	if ps then
		ps:Fire()
	end
end

local function destroy(inst, detached)
	local d = D[inst]
	if d.destroyed then
		return
	end
	fire(inst, "Destroying")
	d.destroyed = true
	if detached then
		d.parent = nil
	else
		setParent(inst, nil)
	end
	d.locked = true
	local kids = d.children
	d.children = {}
	for _, c in ipairs(kids) do
		destroy(c, true)
	end
	for _, s in pairs(d.signals) do
		s:DisconnectAll()
	end
	for _, s in pairs(d.propSignals) do
		s:DisconnectAll()
	end
	for _, s in pairs(d.attrSignals) do
		s:DisconnectAll()
	end
	S.bodies[inst] = nil
end

local function cloneTree(inst, map)
	local d = D[inst]
	if d.props.Archivable == false then
		return nil
	end
	local copy = create(d.class)
	local cd = D[copy]
	cd.name = d.name
	for k, v in pairs(d.props) do
		cd.props[k] = v
	end
	for k, v in pairs(d.attrs) do
		cd.attrs[k] = v
	end
	map[inst] = copy
	for _, child in ipairs(d.children) do
		local c = cloneTree(child, map)
		if c then
			D[c].parent = copy
			table.insert(cd.children, c)
		end
	end
	return copy
end

local function findChild(inst, name)
	for _, c in ipairs(D[inst].children) do
		if D[c].name == name then
			return c
		end
	end
	return nil
end

local function isA(inst, className)
	return D[inst].info.isA[className] == true
end

local ATTRIBUTE_TYPES = {
	string = true, boolean = true, number = true, UDim = true, UDim2 = true, BrickColor = true, Color3 = true,
	Vector2 = true, Vector3 = true, CFrame = true, NumberSequence = true, ColorSequence = true, NumberRange = true,
	Rect = true, Font = true, EnumItem = true, ["nil"] = true,
}

methods.Instance = {
	Destroy = function(self)
		destroy(self)
	end,
	Clone = function(self)
		local map = {}
		local copy = cloneTree(self, map)
		if copy then
			for _, new in pairs(map) do
				local props = D[new].props
				for k, v in pairs(props) do
					if typeof(v) == "Instance" and map[v] then
						props[k] = map[v]
					end
				end
			end
		end
		return copy
	end,
	ClearAllChildren = function(self)
		local d = D[self]
		local kids = d.children
		d.children = {}
		for _, c in ipairs(kids) do
			D[c].parent = nil
			fire(self, "ChildRemoved", c)
			destroy(c, true)
		end
		S.cells = nil
	end,
	GetChildren = function(self)
		local out = {}
		for i, c in ipairs(D[self].children) do
			out[i] = c
		end
		return out
	end,
	GetDescendants = function(self)
		return descendants(self)
	end,
	FindFirstChild = function(self, name, recursive)
		if type(name) ~= "string" then
			error("FindFirstChild: string expected, got " .. typeof(name), 2)
		end
		local found = findChild(self, name)
		if found or not recursive then
			return found
		end
		for _, sub in ipairs(descendants(self)) do
			if D[sub].name == name then
				return sub
			end
		end
		return nil
	end,
	FindFirstChildOfClass = function(self, className)
		for _, c in ipairs(D[self].children) do
			if D[c].class == className then
				return c
			end
		end
		return nil
	end,
	FindFirstChildWhichIsA = function(self, className, recursive)
		local list = recursive and descendants(self) or D[self].children
		for _, c in ipairs(list) do
			if isA(c, className) then
				return c
			end
		end
		return nil
	end,
	FindFirstAncestor = function(self, name)
		local cur = D[self].parent
		while cur do
			if D[cur].name == name then
				return cur
			end
			cur = D[cur].parent
		end
		return nil
	end,
	FindFirstAncestorOfClass = function(self, className)
		local cur = D[self].parent
		while cur do
			if D[cur].class == className then
				return cur
			end
			cur = D[cur].parent
		end
		return nil
	end,
	FindFirstAncestorWhichIsA = function(self, className)
		local cur = D[self].parent
		while cur do
			if isA(cur, className) then
				return cur
			end
			cur = D[cur].parent
		end
		return nil
	end,
	WaitForChild = function(self, name, timeout)
		if type(name) ~= "string" then
			error("WaitForChild: string expected, got " .. typeof(name), 2)
		end
		if timeout ~= nil and type(timeout) ~= "number" then
			error("WaitForChild: number expected for the time-out, got " .. typeof(timeout), 2)
		end
		local found = findChild(self, name)
		if found then
			return found
		end
		local started, warned = S.clock, false
		while true do
			task.wait()
			found = findChild(self, name)
			if found then
				return found
			end
			if timeout and S.clock - started >= timeout then
				return nil
			end
			if not timeout and not warned and S.clock - started > 5 then
				warned = true
				table.insert(M.warnings, "Infinite yield possible on '" .. fullName(self) .. ":WaitForChild(\"" .. name .. "\")'")
			end
		end
	end,
	IsA = function(self, className)
		if type(className) ~= "string" then
			error("IsA: string expected, got " .. typeof(className), 2)
		end
		if not classInfo(className) then
			table.insert(M.warnings, "IsA called with a class that does not exist: " .. className)
		end
		return isA(self, className)
	end,
	IsDescendantOf = function(self, ancestor)
		local cur = D[self].parent
		while cur do
			if cur == ancestor then
				return true
			end
			cur = D[cur].parent
		end
		return false
	end,
	IsAncestorOf = function(self, other)
		local cur = D[other].parent
		while cur do
			if cur == self then
				return true
			end
			cur = D[cur].parent
		end
		return false
	end,
	GetFullName = function(self)
		return fullName(self)
	end,
	GetAttribute = function(self, name)
		if type(name) ~= "string" then
			error("GetAttribute: string expected, got " .. typeof(name), 2)
		end
		return D[self].attrs[name]
	end,
	GetAttributes = function(self)
		local out = {}
		for k, v in pairs(D[self].attrs) do
			out[k] = v
		end
		return out
	end,
	SetAttribute = function(self, name, value)
		if type(name) ~= "string" or name == "" or #name > 100 or string.find(name, "[^%w_]") or string.sub(name, 1, 3) == "RBX" then
			error("Attribute name '" .. tostring(name) .. "' is not valid", 2)
		end
		if not ATTRIBUTE_TYPES[typeof(value)] then
			error("Attributes cannot hold a " .. typeof(value) .. " (" .. name .. ")", 2)
		end
		local d = D[self]
		if d.attrs[name] == value then
			return
		end
		d.attrs[name] = value
		local s = d.attrSignals[name]
		if s then
			s:Fire()
		end
		fire(self, "AttributeChanged", name)
	end,
	GetAttributeChangedSignal = function(self, name)
		if type(name) ~= "string" then
			error("GetAttributeChangedSignal: string expected, got " .. typeof(name), 2)
		end
		local d = D[self]
		local s = d.attrSignals[name]
		if not s then
			s = newSignal("AttributeChanged:" .. name)
			d.attrSignals[name] = s
		end
		return s
	end,
	GetPropertyChangedSignal = function(self, name)
		local d = D[self]
		if name ~= "Name" and name ~= "Parent" then
			local m = d.info.members[name]
			if not m or m.kind ~= "prop" then
				error(tostring(name) .. " is not a valid property name.", 2)
			end
		end
		local s = d.propSignals[name]
		if not s then
			s = newSignal("Changed:" .. name)
			d.propSignals[name] = s
		end
		return s
	end,
}

---------------------------------------------------------------------------------------------------
-- Parts, models and the things characters stand on
---------------------------------------------------------------------------------------------------

setters.BasePart = {
	CFrame = function(_, d, value)
		d.props.CFrame = value
		d.props.Position = value.Position
	end,
	Position = function(inst, d, value)
		local cf = d.props.CFrame or CFrame.new()
		d.props.CFrame = cf - cf.Position + value
		d.props.Position = value
		local ps = d.propSignals.CFrame
		if ps then
			ps:Fire()
		end
	end,
	AssemblyLinearVelocity = function(inst, d, value)
		d.props.AssemblyLinearVelocity = value
		-- a script throwing a character around: hand the velocity to its physics body
		local model = d.parent
		if model then
			for _, c in ipairs(D[model].children) do
				local body = S.bodies[c]
				if body and findChild(model, "HumanoidRootPart") == inst then
					body.vx, body.vy, body.vz = value.X, value.Y, value.Z
					if value.Y > 1 then
						body.grounded = false
					end
				end
			end
		end
	end,
}

methods.BasePart = {
	SetNetworkOwner = function(self, owner)
		local d = D[self]
		if d.props.Anchored then
			error("Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.", 2)
		end
		if not isInWorkspace(self) then
			error("Can only call Network Ownership API on a part that is descendant of Workspace", 2)
		end
		if owner ~= nil and not (typeof(owner) == "Instance" and isA(owner, "Player")) then
			error("SetNetworkOwner: Player expected", 2)
		end
		d.owner = owner
	end,
	GetNetworkOwner = function(self)
		return D[self].owner
	end,
	GetMass = function(self)
		local size = self.Size
		return size.X * size.Y * size.Z * 0.7
	end,
	ApplyImpulse = function(self, impulse)
		if typeof(impulse) ~= "Vector3" then
			error("ApplyImpulse: Vector3 expected, got " .. typeof(impulse), 2)
		end
	end,
}

local function pivotOf(model)
	local d = D[model]
	local primary = d.props.PrimaryPart
	if primary then
		return primary.CFrame
	end
	for _, c in ipairs(descendants(model)) do
		if isA(c, "BasePart") then
			return c.CFrame
		end
	end
	return CFrame.new()
end

methods.PVInstance = {
	GetPivot = function(self)
		if isA(self, "BasePart") then
			return self.CFrame
		end
		return pivotOf(self)
	end,
	PivotTo = function(self, target)
		if typeof(target) ~= "CFrame" then
			error("PivotTo: CFrame expected, got " .. typeof(target), 2)
		end
		if isA(self, "BasePart") then
			self.CFrame = target
			return
		end
		local delta = target * pivotOf(self):Inverse()
		for _, c in ipairs(descendants(self)) do
			if isA(c, "BasePart") then
				local cd = D[c]
				local cf = delta * (cd.props.CFrame or CFrame.new())
				cd.props.CFrame = cf
				cd.props.Position = cf.Position
			end
		end
		S.cells = nil
	end,
}

-- Footprint of an anchored, collidable part: a circle or a box seen from above.
local function footprint(part)
	local d = D[part]
	local props = d.props
	local size = props.Size or Vector3.new(4, 1.2, 2)
	local cf = props.CFrame or CFrame.new()
	local shape = props.Shape
	local f = { x = cf.X, z = cf.Z }
	if shape == Enum.PartType.Cylinder and math.abs(cf.RightVector.Y) > 0.9 then
		f.r = size.Y / 2
		f.top = cf.Y + size.X / 2
		f.bottom = cf.Y - size.X / 2
	elseif shape == Enum.PartType.Ball then
		f.r = size.X / 2
		f.top = cf.Y + size.X / 2
		f.bottom = cf.Y - size.X / 2
	else
		f.hx, f.hz = size.X / 2, size.Z / 2
		f.r = math.max(f.hx, f.hz)
		f.top = cf.Y + size.Y / 2
		f.bottom = cf.Y - size.Y / 2
	end
	return f
end

local CELL = 16
local function buildCells()
	local cells = {}
	local function visit(inst)
		for _, c in ipairs(D[inst].children) do
			local d = D[c]
			if d.info.isA.BasePart then
				local props = d.props
				if props.Anchored and props.CanCollide ~= false then
					local f = footprint(c)
					for cx = math.floor((f.x - f.r) / CELL), math.floor((f.x + f.r) / CELL) do
						for cz = math.floor((f.z - f.r) / CELL), math.floor((f.z + f.r) / CELL) do
							local key = cx * 4096 + cz
							local list = cells[key]
							if not list then
								list = {}
								cells[key] = list
							end
							list[#list + 1] = f
						end
					end
				end
			end
			if #d.children > 0 and not d.info.isA.Humanoid then
				visit(c)
			end
		end
	end
	visit(workspaceInst)
	S.cells = cells
end

local function covers(f, x, z)
	if f.hx then
		return math.abs(x - f.x) <= f.hx and math.abs(z - f.z) <= f.hz
	end
	local dx, dz = x - f.x, z - f.z
	return dx * dx + dz * dz <= f.r * f.r
end

-- highest surface under (x, z) that feet at height `feet` could be standing on or stepping up to
local function groundAt(x, z, feet)
	if not S.cells then
		buildCells()
	end
	local list = S.cells[math.floor(x / CELL) * 4096 + math.floor(z / CELL)]
	local best = nil
	if list then
		for _, f in ipairs(list) do
			if f.top <= feet + 1.5 and (not best or f.top > best) and covers(f, x, z) then
				best = f.top
			end
		end
	end
	return best
end

-- true when something tall stands at (x, z) and blocks a body whose feet are at `feet`
local function wallAt(x, z, feet)
	local list = S.cells[math.floor(x / CELL) * 4096 + math.floor(z / CELL)]
	if list then
		for _, f in ipairs(list) do
			if f.top > feet + 1.6 and f.bottom < feet + 4 and covers(f, x, z) then
				return true
			end
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Humanoids and player characters
---------------------------------------------------------------------------------------------------

local function characterOf(hum)
	return D[hum].parent
end

local function killHumanoid(hum)
	local d = D[hum]
	if d.dead then
		return
	end
	d.dead = true
	d.diedAt = S.clock
	fire(hum, "Died")
end

setters.Humanoid = {
	Health = function(inst, d, value)
		if d.dead then
			return
		end
		local max = d.props.MaxHealth or 100
		value = math.max(0, math.min(max, value))
		local old = d.props.Health or 100
		d.props.Health = value
		if value ~= old then
			fire(inst, "HealthChanged", value)
		end
		if value <= 0 then
			killHumanoid(inst)
		end
	end,
	MaxHealth = function(inst, d, value)
		d.props.MaxHealth = value
		if (d.props.Health or 100) > value then
			d.props.Health = value
		end
	end,
}

getters.Humanoid = {
	MoveDirection = function(inst)
		local body = S.bodies[inst]
		if body then
			return Vector3.new(body.mx, 0, body.mz)
		end
		return Vector3.new()
	end,
	RootPart = function(inst)
		local model = characterOf(inst)
		return model and findChild(model, "HumanoidRootPart") or nil
	end,
	FloorMaterial = function(inst)
		local body = S.bodies[inst]
		if body and not body.grounded then
			return Enum.Material.Air
		end
		return Enum.Material.Plastic
	end,
}

methods.Humanoid = {
	TakeDamage = function(self, amount)
		if type(amount) ~= "number" then
			error("TakeDamage: number expected, got " .. typeof(amount), 2)
		end
		local model = characterOf(self)
		if model then
			for _, c in ipairs(D[model].children) do
				if D[c].class == "ForceField" then
					return
				end
			end
		end
		self.Health = self.Health - amount
	end,
	ChangeState = function() end,
	GetState = function(self)
		if D[self].dead then
			return Enum.HumanoidStateType.Dead
		end
		local body = S.bodies[self]
		if body and not body.grounded then
			return Enum.HumanoidStateType.Freefall
		end
		return Enum.HumanoidStateType.Running
	end,
	SetStateEnabled = function() end,
	Move = function(self, direction)
		local body = S.bodies[self]
		if body then
			body.mx, body.mz = direction.X, direction.Z
		end
	end,
	MoveTo = function(self, location)
		local body = S.bodies[self]
		if body then
			body.moveTo = location
		end
	end,
}

local function makePart(name, size, parent, transparency)
	local p = create("Part")
	local d = D[p]
	d.name = name
	d.props.Size = size
	d.props.Transparency = transparency or 0
	d.props.CanCollide = false
	d.parent = parent
	table.insert(D[parent].children, p)
	return p
end

local function spawnPoint(player)
	local chosen = D[player].props.RespawnLocation
	if chosen and (D[chosen].destroyed or not isInWorkspace(chosen) or D[chosen].props.Enabled == false) then
		chosen = nil
	end
	if not chosen then
		for _, c in ipairs(descendants(workspaceInst)) do
			if D[c].class == "SpawnLocation" and D[c].props.Enabled ~= false then
				chosen = c
				break
			end
		end
	end
	if chosen then
		local pos = chosen.Position
		return Vector3.new(pos.X, pos.Y + chosen.Size.Y / 2 + 3, pos.Z), chosen
	end
	return Vector3.new(0, 100, 0), nil
end

-- Builds a character the way Roblox does: set Player.Character, fire CharacterAdded,
-- then put it in the Workspace and move it to the spawn point.
local function loadCharacter(player)
	local pd = D[player]
	if pd.destroyed then
		return
	end
	local old = pd.props.Character
	if old then
		fire(player, "CharacterRemoving", old)
		destroy(old)
		pd.props.Character = nil
	end
	local model = create("Model")
	D[model].name = pd.name
	local root = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), model, 1)
	makePart("Head", Vector3.new(2, 1, 1), model)
	makePart("UpperTorso", Vector3.new(2, 1.6, 1), model)
	makePart("LowerTorso", Vector3.new(2, 0.4, 1), model)
	D[model].props.PrimaryPart = root
	local hum = create("Humanoid")
	D[hum].props.RigType = Enum.HumanoidRigType.R15
	D[hum].parent = model
	table.insert(D[model].children, hum)
	for _, pair in ipairs({ { "Script", "Health" }, { "LocalScript", "Animate" } }) do
		local s = create(pair[1])
		D[s].name = pair[2]
		D[s].parent = model
		table.insert(D[model].children, s)
	end
	local body = { hum = hum, root = root, player = player, mx = 0, mz = 0, vx = 0, vy = 0, vz = 0, grounded = false }
	local function place()
		setParent(model, workspaceInst)
		local at, pad = spawnPoint(player)
		methods.PVInstance.PivotTo(model, CFrame.new(at))
		S.bodies[hum] = body
		if pad and (D[pad].props.Duration or 10) > 0 then
			local field = create("ForceField")
			setParent(field, model)
			local seconds = D[pad].props.Duration or 10
			task.delay(seconds, function()
				destroy(field)
			end)
		end
	end
	pd.props.Character = model
	if M.options.charAddedFirst then
		fire(player, "CharacterAdded", model)
		place()
	else
		place()
		fire(player, "CharacterAdded", model)
	end
	fire(player, "CharacterAppearanceLoaded", model)
end
M.loadCharacter = loadCharacter

local function stepBodies(dt)
	if not S.cells then
		buildCells()
	end
	local gravity = 196.2
	for hum, body in pairs(S.bodies) do
		local hd = D[hum]
		local root = body.root
		local rd = D[root]
		if hd.destroyed or rd.destroyed then
			S.bodies[hum] = nil
		elseif not hd.dead then
			local cf = rd.props.CFrame or CFrame.new()
			local x, y, z = cf.X, cf.Y, cf.Z
			local speed = hd.props.WalkSpeed or 16
			local wx, wz = body.mx * speed, body.mz * speed
			-- a LinearVelocity constraint on the root overrides everything (that is how dashes work)
			local held = false
			for _, c in ipairs(rd.children) do
				local cd = D[c]
				if cd.class == "LinearVelocity" and cd.props.Attachment0 and cd.props.Enabled ~= false then
					local v = cd.props.VectorVelocity or Vector3.new()
					wx, wz = v.X, v.Z
					body.vx, body.vz = 0, 0
					body.vy = v.Y
					held = true
				end
			end
			local feet = y - 3
			local nx, nz = x + (wx + body.vx) * dt, z + (wz + body.vz) * dt
			if wallAt(nx, nz, feet) then
				nx, nz = x, z
				body.vx, body.vz = 0, 0
			end
			local friction = body.grounded and 8 or 1
			local decay = math.exp(-friction * dt)
			body.vx, body.vz = body.vx * decay, body.vz * decay
			if not held then
				body.vy = body.vy - gravity * dt
			end
			local ny = y + body.vy * dt
			local ground = groundAt(nx, nz, feet)
			if ground and ny - 3 <= ground and body.vy <= 0 then
				ny = ground + 3
				body.vy = 0
				body.grounded = true
			else
				body.grounded = false
			end
			if body.jump and body.grounded then
				body.vy = hd.props.JumpPower or 50
				body.grounded = false
			end
			body.jump = false
			local look = cf.LookVector
			if wx * wx + wz * wz > 1 then
				local m = math.sqrt(wx * wx + wz * wz)
				look = Vector3.new(wx / m, 0, wz / m)
			end
			local at = Vector3.new(nx, ny, nz)
			local new = CFrame.new(at, at + Vector3.new(look.X, 0, look.Z))
			-- the rest of the body follows the root, as welded parts do
			local shift = new * cf:Inverse()
			for _, sibling in ipairs(D[rd.parent].children) do
				local sd = D[sibling]
				if sibling ~= root and sd.info.isA.BasePart then
					local moved = shift * (sd.props.CFrame or CFrame.new())
					sd.props.CFrame = moved
					sd.props.Position = moved.Position
				end
			end
			rd.props.CFrame = new
			rd.props.Position = at
			rd.props.AssemblyLinearVelocity = Vector3.new(wx + body.vx, body.vy, wz + body.vz)
			if ny < -500 then
				hum.Health = 0
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Services
---------------------------------------------------------------------------------------------------

local function getService(name)
	local s = services[name]
	if s then
		return s
	end
	local info = classInfo(name)
	if not info or not info.tags.Service then
		error("'" .. tostring(name) .. "' is not a valid Service name", 3)
	end
	s = create(name)
	D[s].name = name == "RunService" and "Run Service" or name
	D[s].parent = game
	table.insert(D[game].children, s)
	services[name] = s
	return s
end

methods.ServiceProvider = {
	GetService = function(_, name)
		if type(name) ~= "string" then
			error("GetService: string expected, got " .. typeof(name), 2)
		end
		return getService(name)
	end,
	FindService = function(_, name)
		return services[name]
	end,
}
methods.DataModel = {
	BindToClose = function(_, fn)
		if type(fn) ~= "function" then
			error("BindToClose: function expected", 2)
		end
		if S.ctx and not S.ctx.isServer then
			error("BindToClose can only be called on the server.", 2)
		end
		table.insert(S.closers, { fn = fn, ctx = S.ctx })
	end,
	IsLoaded = function()
		return true
	end,
}
S.closers = {}

methods.Workspace = {
	GetServerTimeNow = function()
		return 1700000000 + S.clock
	end,
	Raycast = function()
		return nil
	end,
}

getters.Players = {
	LocalPlayer = function()
		if S.ctx and not S.ctx.isServer then
			return S.ctx.player
		end
		return nil
	end,
}
methods.Players = {
	GetPlayers = function(self)
		local out = {}
		for _, c in ipairs(D[self].children) do
			if D[c].class == "Player" then
				table.insert(out, c)
			end
		end
		return out
	end,
	GetPlayerFromCharacter = function(self, character)
		for _, c in ipairs(D[self].children) do
			if D[c].class == "Player" and D[c].props.Character == character then
				return c
			end
		end
		return nil
	end,
}
methods.Player = {
	Kick = function(self)
		table.insert(S.removals, self)
	end,
}

methods.RunService = {
	IsServer = function()
		return S.ctx == nil or S.ctx.isServer
	end,
	IsClient = function()
		return S.ctx ~= nil and not S.ctx.isServer
	end,
	IsStudio = function()
		return true
	end,
	IsRunning = function()
		return true
	end,
	BindToRenderStep = function(_, name, priority, fn)
		if S.ctx and S.ctx.isServer then
			error("BindToRenderStep can only be called from a LocalScript", 2)
		end
		if type(name) ~= "string" or type(priority) ~= "number" or type(fn) ~= "function" then
			error("BindToRenderStep(name, priority, function): wrong argument types", 2)
		end
		table.insert(S.renderSteps, { name = name, priority = priority, fn = fn, ctx = S.ctx })
		table.sort(S.renderSteps, function(a, b)
			return a.priority < b.priority
		end)
	end,
	UnbindFromRenderStep = function(_, name)
		for i = #S.renderSteps, 1, -1 do
			if S.renderSteps[i].name == name then
				table.remove(S.renderSteps, i)
			end
		end
	end,
}

getters.UserInputService = {
	MouseEnabled = function()
		return S.device.mouse
	end,
	KeyboardEnabled = function()
		return S.device.keyboard
	end,
	TouchEnabled = function()
		return S.device.touch
	end,
	GamepadEnabled = function()
		return S.device.gamepad
	end,
}
methods.UserInputService = {
	GetMouseLocation = function()
		return S.mouse
	end,
	GetLastInputType = function()
		return S.lastInput or Enum.UserInputType.MouseMovement
	end,
	IsKeyDown = function(_, key)
		return S.keysDown[key] == true
	end,
	IsMouseButtonPressed = function(_, button)
		return S.keysDown[button] == true
	end,
	GetFocusedTextBox = function()
		return nil
	end,
}

getters.Camera = {
	ViewportSize = function()
		return S.viewport
	end,
}
methods.Camera = {
	ViewportPointToRay = function(self, x, y, depth)
		if type(x) ~= "number" or type(y) ~= "number" then
			error("ViewportPointToRay: numbers expected", 2)
		end
		local size = S.viewport
		local half = math.tan(math.rad(self.FieldOfView) / 2)
		local dir = Vector3.new((x / size.X * 2 - 1) * half * size.X / size.Y, (1 - y / size.Y * 2) * half, -1).Unit
		local cf = self.CFrame
		local world = cf:VectorToWorldSpace(dir)
		return T.Ray.new(cf.Position + world * (depth or 0), world)
	end,
	WorldToViewportPoint = function(self, point)
		local size = S.viewport
		local rel = self.CFrame:PointToObjectSpace(point)
		local half = math.tan(math.rad(self.FieldOfView) / 2)
		local depth = -rel.Z
		local sx = (rel.X / (depth * half * size.X / size.Y) + 1) / 2 * size.X
		local sy = (1 - rel.Y / (depth * half)) / 2 * size.Y
		return Vector3.new(sx, sy, depth), depth > 0 and sx >= 0 and sx <= size.X and sy >= 0 and sy <= size.Y
	end,
}

S.coreGui = {}
methods.StarterGui = {
	SetCoreGuiEnabled = function(_, kind, enabled)
		if S.ctx and S.ctx.isServer then
			error("SetCoreGuiEnabled can only be called from a LocalScript", 2)
		end
		if typeof(kind) ~= "EnumItem" or kind.EnumType.name ~= "CoreGuiType" or type(enabled) ~= "boolean" then
			error("SetCoreGuiEnabled(Enum.CoreGuiType, boolean): wrong argument types", 2)
		end
		S.coreGui[kind.Name] = enabled
	end,
	GetCoreGuiEnabled = function(_, kind)
		return S.coreGui[kind.Name] ~= false
	end,
	SetCore = function() end,
}

S.sounds = 0
methods.Sound = {
	Play = function(self)
		local id = self.SoundId
		if id == "" then
			table.insert(M.warnings, "Sound played without a SoundId")
		end
		S.sounds = S.sounds + 1
		S.soundIds = S.soundIds or {}
		S.soundIds[id] = (S.soundIds[id] or 0) + 1
	end,
	Stop = function() end,
	Pause = function() end,
	Resume = function() end,
}
methods.SoundService = {
	PlayLocalSound = function(_, sound)
		methods.Sound.Play(sound)
	end,
}
methods.ParticleEmitter = {
	Emit = function(_, count)
		if count ~= nil and type(count) ~= "number" then
			error("Emit: number expected, got " .. typeof(count), 2)
		end
	end,
	Clear = function() end,
}

-- JSON, enough for configuration tables
local function jsonEncode(v, out)
	local t = type(v)
	if t == "nil" then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error("JSONEncode: cannot encode " .. tostring(v), 3)
		end
		out[#out + 1] = string.format("%.17g", v)
	elseif t == "string" then
		out[#out + 1] = '"' .. string.gsub(v, '[%c"\\]', function(c)
			if c == '"' then
				return '\\"'
			elseif c == "\\" then
				return "\\\\"
			end
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "table" and typeof(v) == "table" then
		local n = #v
		local count = 0
		for _ in pairs(v) do
			count = count + 1
		end
		if count == n then
			out[#out + 1] = "["
			for i = 1, n do
				if i > 1 then
					out[#out + 1] = ","
				end
				jsonEncode(v[i], out)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for k, val in pairs(v) do
				if type(k) ~= "string" then
					error("JSONEncode: tables must be arrays or have only string keys (found key " .. tostring(k) .. ")", 3)
				end
				if not first then
					out[#out + 1] = ","
				end
				first = false
				jsonEncode(k, out)
				out[#out + 1] = ":"
				jsonEncode(val, out)
			end
			out[#out + 1] = "}"
		end
	else
		error("JSONEncode: cannot encode a " .. typeof(v), 3)
	end
end

local function jsonDecode(s)
	local pos = 1
	local value
	local function ws()
		pos = string.find(s, "%S", pos) or #s + 1
	end
	local function str()
		local out = {}
		pos = pos + 1
		while true do
			local c = string.sub(s, pos, pos)
			if c == "" then
				error("JSONDecode: unterminated string", 3)
			elseif c == '"' then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(s, pos + 1, pos + 1)
				if e == "u" then
					out[#out + 1] = string.char(tonumber(string.sub(s, pos + 2, pos + 5), 16) % 256)
					pos = pos + 6
				else
					local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
					out[#out + 1] = map[e] or e
					pos = pos + 2
				end
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
	end
	function value()
		ws()
		local c = string.sub(s, pos, pos)
		if c == "{" then
			local obj = {}
			pos = pos + 1
			ws()
			if string.sub(s, pos, pos) == "}" then
				pos = pos + 1
				return obj
			end
			while true do
				ws()
				local k = str()
				ws()
				pos = pos + 1
				obj[k] = value()
				ws()
				local d = string.sub(s, pos, pos)
				pos = pos + 1
				if d == "}" then
					return obj
				end
			end
		elseif c == "[" then
			local arr = {}
			pos = pos + 1
			ws()
			if string.sub(s, pos, pos) == "]" then
				pos = pos + 1
				return arr
			end
			while true do
				arr[#arr + 1] = value()
				ws()
				local d = string.sub(s, pos, pos)
				pos = pos + 1
				if d == "]" then
					return arr
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif string.sub(s, pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif string.sub(s, pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		end
		local numText = string.match(s, "^-?[%d%.]+[eE]?[-+]?%d*", pos)
		if not numText then
			error("JSONDecode: unexpected character at " .. pos, 3)
		end
		pos = pos + #numText
		return tonumber(numText)
	end
	return value()
end

methods.HttpService = {
	JSONEncode = function(_, v)
		local out = {}
		jsonEncode(v, out)
		return table.concat(out)
	end,
	JSONDecode = function(_, s)
		if type(s) ~= "string" then
			error("JSONDecode: string expected, got " .. typeof(s), 2)
		end
		return jsonDecode(s)
	end,
	GenerateGUID = function()
		return string.format("%08x-mock-%08x", math.random(0, 2 ^ 31), math.random(0, 2 ^ 31))
	end,
}

---------------------------------------------------------------------------------------------------
-- Network: remote events cross from one side to the other a moment later, by value
---------------------------------------------------------------------------------------------------

local function netCopy(v, path)
	local t = typeof(v)
	if t == "table" then
		local n = #v
		local count = 0
		for _ in pairs(v) do
			count = count + 1
		end
		local out = {}
		if count == n then
			for i = 1, n do
				out[i] = netCopy(v[i], path .. "[" .. i .. "]")
			end
		else
			for k, val in pairs(v) do
				if type(k) ~= "string" then
					error("remote argument " .. path .. " mixes array and dictionary keys (key " .. tostring(k) .. "); Roblox would drop data", 4)
				end
				out[k] = netCopy(val, path .. "." .. k)
			end
		end
		return out
	elseif t == "function" or t == "thread" or t == "userdata" then
		error("remote argument " .. path .. " is a " .. t .. ", which cannot be sent", 4)
	elseif t == "number" and v ~= v then
		return v
	end
	return v
end

local function packArgs(...)
	local n = select("#", ...)
	local args = { n = n }
	for i = 1, n do
		args[i] = netCopy((select(i, ...)), "#" .. i)
	end
	return args
end

methods.RemoteEvent = {
	FireServer = function(self, ...)
		if not S.ctx or S.ctx.isServer then
			error("FireServer can only be called from the client", 2)
		end
		table.insert(S.net, { event = self, to = "server", from = S.ctx.player, args = packArgs(...) })
	end,
	FireClient = function(self, player, ...)
		if S.ctx and not S.ctx.isServer then
			error("FireClient can only be called from the server", 2)
		end
		if typeof(player) ~= "Instance" or not isA(player, "Player") then
			error("FireClient: player argument must be a Player object", 2)
		end
		table.insert(S.net, { event = self, to = player, args = packArgs(...) })
	end,
	FireAllClients = function(self, ...)
		if S.ctx and not S.ctx.isServer then
			error("FireAllClients can only be called from the server", 2)
		end
		local args = packArgs(...)
		for _, p in ipairs(methods.Players.GetPlayers(getService("Players"))) do
			table.insert(S.net, { event = self, to = p, args = args })
		end
	end,
}

local function deliverNet()
	local queue = S.net
	S.net = {}
	for _, msg in ipairs(queue) do
		local d = D[msg.event]
		if not d.destroyed then
			local args = msg.args
			if msg.to == "server" then
				local s = d.signals.OnServerEvent
				if s and not D[msg.from].destroyed then
					s:Fire(msg.from, unpack(args, 1, args.n))
				end
			else
				local s = d.signals.OnClientEvent
				local target = msg.to
				if s and not D[target].destroyed then
					s:FireFor(function(conn)
						return conn.ctx ~= nil and conn.ctx.player == target
					end, unpack(args, 1, args.n))
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Data stores, kept in memory
---------------------------------------------------------------------------------------------------

M.datastore = { data = {}, failing = false, unavailable = false, writes = 0, reads = 0 }

local function storeCheck(v, path)
	local t = typeof(v)
	if t == "table" then
		local n = #v
		local count = 0
		for k, val in pairs(v) do
			count = count + 1
			if type(k) ~= "string" and type(k) ~= "number" then
				error("DataStore: invalid key type at " .. path, 4)
			end
			storeCheck(val, path .. "." .. tostring(k))
		end
		if count ~= n then
			for k in pairs(v) do
				if type(k) ~= "string" then
					error("DataStore: cannot store a table with mixed keys at " .. path, 4)
				end
			end
		end
	elseif t ~= "string" and t ~= "number" and t ~= "boolean" and t ~= "nil" then
		error("DataStore: cannot store a " .. t .. " at " .. path, 4)
	elseif t == "number" and v ~= v then
		error("DataStore: cannot store NaN at " .. path, 4)
	end
end

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = deepCopy(val)
	end
	return out
end

methods.DataStoreService = {
	GetDataStore = function(_, name)
		if S.ctx and not S.ctx.isServer then
			error("DataStoreService can only be used on the server", 2)
		end
		if M.datastore.unavailable then
			error("You must publish this place to the web to access DataStore.", 2)
		end
		if type(name) ~= "string" then
			error("GetDataStore: string expected", 2)
		end
		local store = create("DataStore")
		D[store].name = name
		return store
	end,
}
methods.GlobalDataStore = {
	GetAsync = function(self, key)
		if type(key) ~= "string" then
			error("GetAsync: key must be a string", 2)
		end
		task.wait(0.05)
		if M.datastore.failing then
			error("502: API Services rejected request with error. HTTP 403 (Forbidden)", 2)
		end
		M.datastore.reads = M.datastore.reads + 1
		return deepCopy(M.datastore.data[D[self].name .. "/" .. key])
	end,
	SetAsync = function(self, key, value)
		if type(key) ~= "string" then
			error("SetAsync: key must be a string", 2)
		end
		storeCheck(value, "value")
		task.wait(0.05)
		if M.datastore.failing then
			error("502: API Services rejected request with error. HTTP 403 (Forbidden)", 2)
		end
		M.datastore.writes = M.datastore.writes + 1
		M.datastore.data[D[self].name .. "/" .. key] = deepCopy(value)
	end,
}

---------------------------------------------------------------------------------------------------
-- The global environment scripts run in
---------------------------------------------------------------------------------------------------

local InstanceLib = {
	new = function(className, parent)
		if type(className) ~= "string" then
			error("Instance.new: string expected, got " .. typeof(className), 2)
		end
		local info = classInfo(className)
		if not info or info.tags.NotCreatable or info.tags.Service then
			error("Unable to create an Instance of type \"" .. className .. "\"", 2)
		end
		if info.tags.Deprecated then
			noteDeprecated("class", className)
		end
		local inst = create(className)
		if parent ~= nil then
			setParent(inst, parent, 2)
		end
		return inst
	end,
}

local function copyLib(lib, names)
	local out = {}
	for _, n in ipairs(names) do
		out[n] = lib[n]
	end
	return out
end

local mathLib = copyLib(math, { "abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "cosh", "deg", "exp", "floor",
	"fmod", "frexp", "ldexp", "log", "log10", "max", "min", "modf", "pow", "rad", "random", "randomseed", "sin", "sinh",
	"sqrt", "tan", "tanh", "huge", "pi" })
function mathLib.clamp(x, lo, hi)
	if type(x) ~= "number" or type(lo) ~= "number" or type(hi) ~= "number" then
		error("math.clamp: numbers expected, got " .. typeof(x) .. ", " .. typeof(lo) .. ", " .. typeof(hi), 2)
	end
	if lo > hi then
		error("math.clamp: max must be greater than or equal to min", 2)
	end
	return x < lo and lo or (x > hi and hi or x)
end
function mathLib.round(x)
	return math.floor(x + 0.5)
end
function mathLib.sign(x)
	return x > 0 and 1 or (x < 0 and -1 or 0)
end

local tableLib = copyLib(table, { "concat", "insert", "remove", "sort", "maxn" })
tableLib.unpack = unpack
function tableLib.pack(...)
	return { n = select("#", ...), ... }
end
function tableLib.find(t, value, init)
	for i = init or 1, #t do
		if t[i] == value then
			return i
		end
	end
	return nil
end
function tableLib.clear(t)
	for k in pairs(t) do
		t[k] = nil
	end
end
function tableLib.create(n, value)
	local t = {}
	if value ~= nil then
		for i = 1, n do
			t[i] = value
		end
	end
	return t
end
function tableLib.clone(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return setmetatable(out, getmetatable(t))
end

local stringLib = copyLib(string, { "byte", "char", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep",
	"reverse", "sub", "upper" })
function stringLib.split(s, sep)
	local out = {}
	sep = sep or ","
	local start = 1
	while true do
		local a, b = string.find(s, sep, start, true)
		if not a then
			table.insert(out, string.sub(s, start))
			return out
		end
		table.insert(out, string.sub(s, start, a - 1))
		start = b + 1
	end
end

local function makeEnv(scriptInst)
	local env = {
		game = game, workspace = workspaceInst, script = scriptInst, Instance = InstanceLib, Enum = Enum,
		Vector3 = Vector3, Vector2 = Vector2, CFrame = CFrame, Color3 = Color3, UDim = UDim, UDim2 = UDim2,
		Rect = T.Rect, Ray = T.Ray, TweenInfo = T.TweenInfo, NumberRange = T.NumberRange,
		NumberSequence = T.NumberSequence, NumberSequenceKeypoint = T.NumberSequenceKeypoint,
		ColorSequence = T.ColorSequence, ColorSequenceKeypoint = T.ColorSequenceKeypoint, Random = T.Random,
		Font = T.Font, BrickColor = T.BrickColor, PhysicalProperties = T.PhysicalProperties,
		task = task, typeof = typeof, math = mathLib, table = tableLib, string = stringLib,
		os = {
			clock = function()
				return S.clock
			end,
			time = function()
				return 1700000000 + math.floor(S.clock)
			end,
			date = os.date,
		},
		coroutine = copyLib(coroutine, { "create", "resume", "yield", "status", "wrap", "running" }),
		pcall = pcall, xpcall = xpcall, error = error, assert = assert, select = select, type = type,
		tostring = tostring, tonumber = tonumber, ipairs = ipairs, pairs = pairs, next = next, unpack = unpack,
		rawget = rawget, rawset = rawset, rawequal = rawequal, setmetatable = setmetatable, getmetatable = getmetatable,
		tick = function()
			return 1700000000 + S.clock
		end,
		time = function()
			return S.clock
		end,
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			table.insert(M.prints, "[" .. (S.ctx and S.ctx.name or "?") .. "] " .. table.concat(parts, " "))
		end,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			table.insert(M.warnings, "[" .. (S.ctx and S.ctx.name or "?") .. "] " .. table.concat(parts, " "))
		end,
	}
	env._G = {}
	return setmetatable(env, {
		__index = function(_, k)
			error("unknown global '" .. tostring(k) .. "' (not part of Roblox Luau, or a typo)", 2)
		end,
		__newindex = function(_, k)
			error("assignment to undeclared global '" .. tostring(k) .. "' (missing 'local'?)", 2)
		end,
	})
end

---------------------------------------------------------------------------------------------------
-- Driving the simulation from tests
---------------------------------------------------------------------------------------------------

function M.boot(seed)
	math.randomseed(seed or 1)
	buildOverrides()
	game = create("DataModel")
	D[game].name = "Game"
	workspaceInst = getService("Workspace")
	local camera = create("Camera")
	setParent(camera, workspaceInst)
	raw(workspaceInst, "CurrentCamera", camera)
	for _, name in ipairs({ "Players", "Lighting", "ReplicatedStorage", "ServerScriptService", "ServerStorage",
		"StarterGui", "StarterPlayer", "SoundService", "RunService", "UserInputService", "HttpService" }) do
		getService(name)
	end
	M.game, M.workspace = game, workspaceInst
	M.server = { name = "server", isServer = true }
	M.clients = {}
end

function M.run(source, chunkName, context)
	local kind = context.isServer and "Script" or "LocalScript"
	local scriptInst = create(kind)
	D[scriptInst].name = chunkName
	local fn, err = loadstring(source, "=" .. chunkName)
	if not fn then
		error(err)
	end
	setfenv(fn, makeEnv(scriptInst))
	spawnIn(context, fn)
end

-- runs fn as if it were code on the server, or on one player's client
function M.as(context, fn, ...)
	local prev = S.ctx
	S.ctx = context
	local ok, err = pcall(fn, ...)
	S.ctx = prev
	if not ok then
		table.insert(M.errors, "[test helper] " .. tostring(err))
	end
	if S.depth == 0 then
		flushDeferred()
	end
end

function M.addPlayer(name, userId)
	local players = getService("Players")
	local player = create("Player")
	local d = D[player]
	d.name = name
	d.props.DisplayName = name
	d.props.UserId = userId
	for _, pair in ipairs({ { "PlayerGui", "PlayerGui" }, { "Backpack", "Backpack" }, { "PlayerScripts", "PlayerScripts" } }) do
		local c = create(pair[1])
		D[c].name = pair[2]
		D[c].parent = player
		table.insert(d.children, c)
	end
	local context = { name = "client:" .. name, isServer = false, player = player }
	M.clients[player] = context
	S.ctx = nil
	setParent(player, players)
	fire(players, "PlayerAdded", player)
	if players.CharacterAutoLoads then
		S.pendingSpawns[player] = S.clock + 0.3
	end
	return player, context
end

function M.removePlayer(player)
	local players = getService("Players")
	S.ctx = nil
	fire(players, "PlayerRemoving", player)
	local character = D[player].props.Character
	if character then
		fire(player, "CharacterRemoving", character)
		destroy(character)
	end
	S.pendingSpawns[player] = nil
	destroy(player)
	M.clients[player] = nil
end

function M.close()
	for _, c in ipairs(S.closers) do
		spawnIn(c.ctx, c.fn)
	end
end

local function bodyOf(player)
	local character = D[player].props.Character
	if not character then
		return nil
	end
	for _, c in ipairs(D[character].children) do
		if S.bodies[c] then
			return S.bodies[c]
		end
	end
	return nil
end

-- walk in a direction (unit vector on the ground), or stand still with (0, 0)
function M.move(player, mx, mz)
	local body = bodyOf(player)
	if body then
		body.mx, body.mz = mx, mz
	end
end
function M.jump(player)
	local body = bodyOf(player)
	if body then
		body.jump = true
	end
end
function M.position(player)
	local body = bodyOf(player)
	if body and not D[body.hum].dead then
		return D[body.root].props.Position
	end
	return nil
end

local function makeInput(kind, key, state, position)
	local input = create("InputObject")
	local props = D[input].props
	props.UserInputType = kind
	props.KeyCode = key or Enum.KeyCode.Unknown
	props.UserInputState = state
	props.Position = position or Vector3.new(S.mouse.X, S.mouse.Y, 0)
	props.Delta = Vector3.new()
	return input
end

local function uisFire(eventName, input, processed)
	S.ctx = nil
	local uis = getService("UserInputService")
	fire(uis, eventName, input, processed or false)
end

function M.key(keyCode, down)
	S.lastInput = Enum.UserInputType.Keyboard
	S.keysDown[keyCode] = down or nil
	uisFire(down and "InputBegan" or "InputEnded",
		makeInput(Enum.UserInputType.Keyboard, keyCode, down and Enum.UserInputState.Begin or Enum.UserInputState.End))
end
function M.mouseButton(down)
	S.lastInput = Enum.UserInputType.MouseButton1
	S.keysDown[Enum.UserInputType.MouseButton1] = down or nil
	uisFire(down and "InputBegan" or "InputEnded",
		makeInput(Enum.UserInputType.MouseButton1, nil, down and Enum.UserInputState.Begin or Enum.UserInputState.End))
end
function M.mouseMove(x, y)
	S.mouse = Vector2.new(x, y)
	S.lastInput = Enum.UserInputType.MouseMovement
	uisFire("InputChanged", makeInput(Enum.UserInputType.MouseMovement, nil, Enum.UserInputState.Change))
end
function M.wheel(direction)
	uisFire("InputChanged", makeInput(Enum.UserInputType.MouseWheel, nil, Enum.UserInputState.Change, Vector3.new(S.mouse.X, S.mouse.Y, direction)))
end
function M.setDevice(kind)
	if kind == "touch" then
		S.device = { mouse = false, keyboard = false, touch = true, gamepad = false }
		S.lastInput = Enum.UserInputType.Touch
	else
		S.device = { mouse = true, keyboard = true, touch = false, gamepad = false }
		S.lastInput = Enum.UserInputType.MouseMovement
	end
end
function M.setViewport(w, h)
	S.viewport = Vector2.new(w, h)
end

-- press and release a GUI button the way a player would
function M.click(button, hold)
	S.ctx = nil
	local kind = S.device.touch and Enum.UserInputType.Touch or Enum.UserInputType.MouseButton1
	local began = makeInput(kind, nil, Enum.UserInputState.Begin)
	local ended = makeInput(kind, nil, Enum.UserInputState.End)
	fire(button, "InputBegan", began)
	fire(button, "MouseButton1Down", S.mouse.X, S.mouse.Y)
	if hold then
		return function()
			fire(button, "InputEnded", ended)
			fire(button, "MouseButton1Up", S.mouse.X, S.mouse.Y)
		end
	end
	fire(button, "InputEnded", ended)
	fire(button, "MouseButton1Up", S.mouse.X, S.mouse.Y)
	fire(button, "MouseButton1Click")
	fire(button, "Activated", ended, 1)
end

-- every button a player could actually press right now
function M.visibleButtons(root)
	local out = {}
	local function visit(inst, shown)
		for _, c in ipairs(D[inst].children) do
			local d = D[c]
			local visible = shown
			if d.info.isA.LayerCollector then
				visible = visible and c.Enabled
			elseif d.info.isA.GuiObject then
				visible = visible and c.Visible
			end
			if visible then
				if d.info.isA.GuiButton then
					table.insert(out, c)
				end
				visit(c, visible)
			end
		end
	end
	visit(root, true)
	return out
end

function M.count(inst)
	return #descendants(inst)
end
function M.descendants(inst)
	return descendants(inst)
end
function M.find(path)
	local cur = game
	for name in string.gmatch(path, "[^/]+") do
		cur = findChild(cur, name)
		if not cur then
			return nil
		end
	end
	return cur
end
function M.service(name)
	return getService(name)
end
function M.now()
	return S.clock
end
function M.timerCount()
	return #S.timers
end
function M.isAlive(player)
	local body = bodyOf(player)
	return body ~= nil and not D[body.hum].dead
end
function M.listen(inst, eventName, fn, context)
	local prev = S.ctx
	S.ctx = context
	local conn = inst[eventName]:Connect(fn)
	S.ctx = prev
	return conn
end

-- Describes what one player would see, as plain data, so preview.py can draw it.
function M.snapshot(player)
	local camera = workspaceInst.CurrentCamera
	local out = {
		viewport = { S.viewport.X, S.viewport.Y }, camera = { camera.CFrame:GetComponents() }, fov = camera.FieldOfView,
		parts = {}, plates = {}, chars = {}, guis = {},
	}
	local function rgb(c)
		return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
	end
	local function ud2(u)
		return { u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset }
	end

	local function gui(inst)
		local d = D[inst]
		local isA = d.info.isA
		local node = { class = d.class, name = d.name, kids = {} }
		if isA.GuiObject then
			node.pos, node.size = ud2(inst.Position), ud2(inst.Size)
			node.anchor = { inst.AnchorPoint.X, inst.AnchorPoint.Y }
			node.bg, node.bgT = rgb(inst.BackgroundColor3), inst.BackgroundTransparency
			node.visible, node.rot, node.z, node.order = inst.Visible, inst.Rotation, inst.ZIndex, inst.LayoutOrder
			if isA.TextLabel or isA.TextButton then
				node.text, node.textSize, node.textColor = inst.Text, inst.TextSize, rgb(inst.TextColor3)
				node.textT, node.xa, node.ya = inst.TextTransparency, inst.TextXAlignment.Name, inst.TextYAlignment.Name
				node.font, node.rich, node.wrap = inst.Font.Name, inst.RichText, inst.TextWrapped
			end
		elseif isA.LayerCollector then
			node.enabled = inst.Enabled
			if d.class == "ScreenGui" then
				node.order, node.inset = inst.DisplayOrder, inst.IgnoreGuiInset
			end
		elseif d.class == "UICorner" then
			node.radius = { inst.CornerRadius.Scale, inst.CornerRadius.Offset }
		elseif d.class == "UIStroke" then
			node.color, node.thickness, node.strokeT = rgb(inst.Color), inst.Thickness, inst.Transparency
		elseif d.class == "UIScale" then
			node.scale = inst.Scale
		elseif d.class == "UIListLayout" then
			node.fill, node.pad = inst.FillDirection.Name, { inst.Padding.Scale, inst.Padding.Offset }
			node.ha, node.va = inst.HorizontalAlignment.Name, inst.VerticalAlignment.Name
		elseif d.class == "UIGridLayout" then
			node.cell, node.pad = ud2(inst.CellSize), ud2(inst.CellPadding)
		end
		for _, c in ipairs(d.children) do
			table.insert(node.kids, gui(c))
		end
		return node
	end

	local function walk(inst)
		for _, c in ipairs(D[inst].children) do
			local d = D[c]
			local props = d.props
			if d.info.isA.BasePart then
				local t = 1 - (1 - (props.Transparency or 0)) * (1 - (props.LocalTransparencyModifier or 0))
				if t < 0.99 then
					local cf, size = props.CFrame or CFrame.new(), props.Size or Vector3.new(4, 1.2, 2)
					table.insert(out.parts, {
						n = d.name, s = (props.Shape or Enum.PartType.Block).Name, sz = { size.X, size.Y, size.Z },
						cf = { cf:GetComponents() }, c = rgb(props.Color or Color3.fromRGB(163, 162, 165)),
						m = (props.Material or Enum.Material.Plastic).Name, t = t,
					})
				end
			elseif d.class == "BillboardGui" and props.Enabled ~= false then
				local adornee = props.Adornee or inst
				if D[adornee] and D[adornee].info.isA.BasePart and not D[adornee].destroyed then
					local at = adornee.Position + c.StudsOffset
					local plate = { at = { at.X, at.Y, at.Z }, w = c.Size.X.Offset, h = c.Size.Y.Offset, items = {} }
					for _, sub in ipairs(descendants(c)) do
						local sd = D[sub]
						if sd.class == "TextLabel" then
							table.insert(plate.items, { text = sub.Text, size = sub.TextSize, color = rgb(sub.TextColor3),
								y = sub.Position.Y.Offset, h = sub.Size.Y.Offset, a = 1 - sub.TextTransparency, full = sub.Size.Y.Scale })
						elseif sd.class == "Frame" and sd.name == "Fill" then
							local bar = sd.parent
							table.insert(plate.items, { bar = sub.Size.X.Scale, color = rgb(sub.BackgroundColor3),
								y = bar.Position.Y.Offset, w = bar.Size.X.Offset, h = bar.Size.Y.Offset })
						end
					end
					table.insert(out.plates, plate)
				end
			elseif d.class == "Model" then
				local hum, root, glow = nil, findChild(c, "HumanoidRootPart"), findChild(c, "TeamGlow")
				for _, sub in ipairs(d.children) do
					if D[sub].class == "Humanoid" then
						hum = sub
					end
				end
				if hum and root and not D[hum].dead then
					local at = root.Position
					local field = false
					for _, sub in ipairs(d.children) do
						if D[sub].class == "ForceField" then
							field = true
						end
					end
					table.insert(out.chars, { at = { at.X, at.Y, at.Z }, c = glow and rgb(glow.OutlineColor) or { 235, 236, 250 },
						field = field, me = D[player].props.Character == c })
				end
			end
			if d.class ~= "BillboardGui" then
				walk(c)
			end
		end
	end
	walk(workspaceInst)
	for _, c in ipairs(D[findChild(player, "PlayerGui")].children) do
		table.insert(out.guis, gui(c))
	end
	local buffer = {}
	jsonEncode(out, buffer)
	return table.concat(buffer)
end

function M.step(dt)
	S.clock = S.clock + dt
	S.ctx = nil
	deliverNet()

	-- player lifecycle: first spawns and respawns
	local players = getService("Players")
	for player, at in pairs(S.pendingSpawns) do
		if S.clock >= at then
			S.pendingSpawns[player] = nil
			if not D[player].destroyed then
				loadCharacter(player)
			end
		end
	end
	for hum, body in pairs(S.bodies) do
		local hd = D[hum]
		if hd.dead and not body.respawnQueued and not D[body.player].destroyed and players.CharacterAutoLoads then
			body.respawnQueued = true
			S.pendingSpawns[body.player] = S.clock + players.RespawnTime
		end
	end
	for _, player in ipairs(S.removals) do
		if not D[player].destroyed then
			M.removePlayer(player)
		end
	end
	S.removals = {}

	stepBodies(dt)

	-- timers that are due
	local due = {}
	local keep = {}
	for _, t in ipairs(S.timers) do
		if t.at <= S.clock then
			due[#due + 1] = t
		else
			keep[#keep + 1] = t
		end
	end
	S.timers = keep
	table.sort(due, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.seq < b.seq
	end)
	for _, t in ipairs(due) do
		if t.co then
			resume(t.co)
		else
			spawnIn(t.ctx, t.fn, unpack(t.args, 1, t.args.n))
		end
	end

	-- one frame for every script
	local run = getService("RunService")
	for _, r in ipairs(S.renderSteps) do
		spawnIn(r.ctx, r.fn, dt)
	end
	fire(run, "RenderStepped", dt)
	fire(run, "Stepped", S.clock, dt)
	fire(run, "Heartbeat", dt)
	flushDeferred()
end

return M
end
