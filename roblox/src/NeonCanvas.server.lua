-- NEON CANVAS: server script (goes in ServerScriptService).
--
-- A team paint-brawler. Two teams fight over a floor of glowing dots: every dot you step on or
-- splash turns your colour. This script owns every rule: the dot grid, fighters, computer
-- opponents, abilities, rounds, rewards and saving. The client script only draws and sends input.
--
-- Written in plain Lua 5.1 syntax on purpose, so the offline test harness in roblox/test can run
-- it outside Roblox.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

---------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------

local S = 7.2                    -- distance between dot centres
local RINGS = 12                 -- the grid is a hexagon this many dots from centre to edge
local ARENA_R = RINGS * S
local SQ3 = math.sqrt(3)
local FLOOR_Y = 50               -- height of the walking surface
local BODY_Y = FLOOR_Y + 3       -- height of a standing fighter's middle
local BOT_REST = FLOOR_Y + 2
local KILL_Y = FLOOR_Y - 40      -- falling below this is a knock-out
local DECK_Y = FLOOR_Y + 18      -- the glass waiting deck above the arena
local BODY_R = 2
local TEAM_SIZE = 4              -- computer players fill each team up to this size
local WALK = 18
local RESPAWN = 4
local MAX_HP = 120
local TIME = { intermission = 16, countdown = 4, match = 150, results = 12, rush = 25 }
local TEAM_COLOR = { Color3.fromRGB(255, 138, 44), Color3.fromRGB(62, 160, 255) }
local NEUTRAL = Color3.fromRGB(235, 236, 250)
local MODE_ORDER = { "Turf", "Beacons", "KO" }
local GOAL = { Turf = 0, Beacons = 200, KO = 25 }
local SLOTS = { "a1", "a2" }
local BOT_NAMES = { "Mochi", "Pixel", "Nori", "Boba", "Tofu", "Kiwi", "Pesto", "Miso", "Dango", "Yuzu", "Soba", "Taro",
	"Udon", "Sesame", "Matcha", "Peach" }

-- Everything the client needs to draw menus and predict cooldowns. Sent as JSON.
local CONFIG = {
	spacing = S,
	floorY = FLOOR_Y,
	walk = WALK,
	respawn = RESPAWN,
	teamNames = { "EMBER", "TIDE" },
	teamColors = { { 255, 138, 44 }, { 62, 160, 255 } },
	xpBase = 80,
	xpStep = 40,
	levelCap = 40,
	primaryOrder = { "bolt", "scatter", "lob" },
	abilityOrder = { "nova", "shield", "mine", "vortex", "beam", "blink", "mend", "overdrive" },
	titleOrder = { "rookie", "dotter", "splash", "bandit", "knight", "thief", "king", "prism" },
	primaries = {
		bolt = { name = "Bolt", cd = 0.4, unlock = 1, range = 60, desc = "Quick paint shot that lands where you aim." },
		scatter = { name = "Scatter", cd = 0.75, unlock = 3, range = 34, desc = "Five-shot fan. Brutal up close." },
		lob = { name = "Lob", cd = 1.05, unlock = 7, range = 55, desc = "Arcing shell that bursts on landing." },
	},
	abilities = {
		nova = { name = "Nova", cd = 9, unlock = 1, range = 0, desc = "Blast and repaint everything around you." },
		shield = { name = "Shield", cd = 12, unlock = 1, range = 0, desc = "Block all damage for 3 seconds." },
		mine = { name = "Mine", cd = 7, unlock = 2, range = 0, desc = "Drop a trap that bursts under enemies." },
		vortex = { name = "Vortex", cd = 13, unlock = 4, range = 42, desc = "Whirlpool that drags enemies in." },
		beam = { name = "Beam", cd = 10, unlock = 6, range = 60, desc = "Charged ray that pierces a whole line." },
		blink = { name = "Blink", cd = 8, unlock = 8, range = 34, desc = "Teleport and burst on arrival." },
		mend = { name = "Mend", cd = 16, unlock = 10, range = 0, desc = "Totem that heals nearby allies." },
		overdrive = { name = "Overdrive", cd = 14, unlock = 12, range = 0, desc = "Run faster and paint wider for 5 seconds." },
	},
	dash = { name = "Dash", cd = 3.5, desc = "Burst of speed. You cannot be hit mid-dash." },
	ult = { name = "Chroma Burst", desc = "Charge it by painting and fighting, then repaint a huge area." },
	titles = {
		rookie = { name = "Rookie", cost = 0 },
		dotter = { name = "Dotter", cost = 150 },
		splash = { name = "Splash Artist", cost = 400 },
		bandit = { name = "Brush Bandit", cost = 800 },
		knight = { name = "Neon Knight", cost = 1500 },
		thief = { name = "Colour Thief", cost = 2500 },
		king = { name = "Canvas King", cost = 4000 },
		prism = { name = "Prism Lord", cost = 7000 },
	},
	ranks = {
		{ name = "Bronze", at = 0 }, { name = "Silver", at = 120 }, { name = "Gold", at = 300 },
		{ name = "Platinum", at = 550 }, { name = "Diamond", at = 900 }, { name = "Prism", at = 1400 },
	},
	modes = {
		Turf = { name = "TURF", goal = "Paint the most dots" },
		Beacons = { name = "BEACONS", goal = "Hold the light beacons" },
		KO = { name = "KO RUSH", goal = "Knock out the other team" },
	},
}

---------------------------------------------------------------------------------------------------
-- Shared plumbing
---------------------------------------------------------------------------------------------------

local World, Grid, Fighters, Combat, Shots, Abilities = {}, {}, {}, {}, {}, {}
local Props, Power, Bots, Modes, Profiles, Match = {}, {}, {}, {}, {}, {}

-- G is the state of the current round.
local G = { state = "Boot", round = 0, mode = "Turf", endsAt = 0, rush = false, score = { 0, 0 }, goal = 0, secAcc = 0 }
local live = {}   -- [player] = { character, root, hum, fill } for characters that are alive right now

local rng = Random.new()

local function now()
	return workspace:GetServerTimeNow()
end

local function dist(x0, z0, x1, z1)
	local dx, dz = x1 - x0, z1 - z0
	return math.sqrt(dx * dx + dz * dz)
end

local function make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local shared = make("Folder", { Name = "NeonCanvas" }, nil)
local function remote(name)
	return make("RemoteEvent", { Name = name }, shared)
end
local actEvent = remote("Act")           -- client -> server: use an ability
local requestEvent = remote("Request")   -- client -> server: menu choices
local fxEvent = remote("FX")             -- server -> clients: things to draw
local feedEvent = remote("Feed")         -- server -> clients: knock-outs and announcements
local hurtEvent = remote("Hurt")         -- server -> one client: you were hit
local resultsEvent = remote("Results")   -- server -> one client: end-of-match card
make("StringValue", { Name = "Config", Value = HttpService:JSONEncode(CONFIG) }, shared)
shared:SetAttribute("State", "Boot")
shared:SetAttribute("EndsAt", 0)
shared:SetAttribute("Mode", "Turf")
shared:SetAttribute("MapName", "")
shared:SetAttribute("ScoreA", 0)
shared:SetAttribute("ScoreB", 0)
shared:SetAttribute("Goal", 0)
shared:SetAttribute("Total", 1)
shared:SetAttribute("Rush", false)
shared:SetAttribute("Round", 0)
shared.Parent = ReplicatedStorage

local function FX(...)
	fxEvent:FireAllClients(...)
end

local errorCount = 0
local function guard(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and errorCount < 30 then
		errorCount = errorCount + 1
		warn("[NeonCanvas] " .. label .. ": " .. tostring(err))
	end
end

---------------------------------------------------------------------------------------------------
-- World: lighting and the parts that never change
---------------------------------------------------------------------------------------------------

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

-- An upright cylinder. Roblox cylinders lie along X, so they are turned 90 degrees.
local function cyl(parent, x, y, z, radius, height, color, material, extra)
	local props = {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(x, y, z) * UPRIGHT,
		Color = color,
		Material = material or Enum.Material.SmoothPlastic,
		Anchored = true,
		CastShadow = false,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
	}
	if extra then
		for k, v in pairs(extra) do
			props[k] = v
		end
	end
	return make("Part", props, parent)
end

local function spawnPad(parent, name)
	return make("SpawnLocation", {
		Name = name,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Neutral = true,
		Duration = 0,
		Size = Vector3.new(10, 1, 10),
		Position = Vector3.new(0, DECK_Y + 0.5, 0),
		TopSurface = Enum.SurfaceType.Smooth,
	}, parent)
end

function World.build()
	local old = workspace:FindFirstChild("Baseplate")
	if old then
		old:Destroy()
	end
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj:IsA("SpawnLocation") then
			obj:Destroy()
		end
	end
	for _, obj in ipairs(Lighting:GetChildren()) do
		if obj:IsA("PostEffect") or obj:IsA("Atmosphere") then
			obj:Destroy()
		end
	end

	-- night, so the neon floor is the brightest thing on screen
	Lighting.ClockTime = 0
	Lighting.Brightness = 1.6
	Lighting.Ambient = Color3.fromRGB(96, 96, 134)
	Lighting.OutdoorAmbient = Color3.fromRGB(108, 108, 152)
	Lighting.GlobalShadows = false
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.3
	make("Atmosphere", {
		Density = 0.3,
		Offset = 0.1,
		Color = Color3.fromRGB(64, 70, 124),
		Decay = Color3.fromRGB(28, 26, 60),
		Glare = 0,
		Haze = 1.2,
	}, Lighting)
	make("BloomEffect", { Intensity = 0.6, Size = 24, Threshold = 1 }, Lighting)
	make("ColorCorrectionEffect", { Contrast = 0.1, Saturation = 0.18, TintColor = Color3.fromRGB(246, 242, 255) }, Lighting)

	local root = make("Folder", { Name = "NeonCanvas" }, workspace)
	for _, name in ipairs({ "Tiles", "Bases", "Pillars", "Bots", "Props", "Static" }) do
		World[name] = make("Folder", { Name = name }, root)
	end

	-- the glass deck where everyone waits between matches
	World.deck = cyl(World.Static, 0, DECK_Y - 0.6, 0, 22, 1.2, Color3.fromRGB(150, 170, 255), Enum.Material.Glass,
		{ Name = "Deck", Transparency = 0.55 })
	World.deckRim = cyl(World.Static, 0, DECK_Y - 1.5, 0, 22.8, 0.4, Color3.fromRGB(190, 170, 255), Enum.Material.Neon,
		{ Name = "DeckRim", CanCollide = false, Transparency = 0.2 })
	World.lobbyPad = spawnPad(World.Static, "LobbyPad")
	World.pad = { spawnPad(World.Static, "PadEmber"), spawnPad(World.Static, "PadTide") }

	-- a ring of light posts frames the canvas
	for i = 1, 18 do
		local a = i / 18 * math.pi * 2
		cyl(World.Static, math.cos(a) * (ARENA_R + 16), FLOOR_Y + 4, math.sin(a) * (ARENA_R + 16), 0.5, 30,
			Color3.fromRGB(190, 170, 255), Enum.Material.Neon, { Name = "Post", CanCollide = false, Transparency = 0.35 })
	end
	-- soft lights far below give the void some depth
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2 + 0.4
		local d = 60 + (i % 3) * 45
		make("Part", {
			Name = "Glow",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(90, 90, 90),
			Position = Vector3.new(math.cos(a) * d, FLOOR_Y - 230 - (i % 2) * 60, math.sin(a) * d),
			Color = Color3.fromHSV(0.62 + i * 0.045, 0.6, 0.4),
			Material = Enum.Material.Neon,
			Transparency = 0.8,
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		}, World.Static)
	end
end

function World.setDeck(visible)
	World.deck.Transparency = visible and 0.55 or 1
	World.deck.CanCollide = visible
	World.deckRim.Transparency = visible and 0.2 or 1
end

---------------------------------------------------------------------------------------------------
-- Grid: the dots. Axial hex coordinates (q, r) <-> world (x, z).
---------------------------------------------------------------------------------------------------

Grid.tiles = {}        -- every tile of the current map (floor and pillars)
Grid.at = {}           -- [key] = tile
Grid.floorCount = 0
Grid.count = { 0, 0 }  -- dots owned by each team
Grid.baseTile = {}
Grid.beacons = {}

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, -1 }, { -1, 1 } }

local function tileKey(q, r)
	return (q + 64) * 128 + (r + 64)
end

function Grid.toWorld(q, r)
	return S * (q + r / 2), S * r * SQ3 / 2
end

function Grid.tileAt(x, z)
	local fr = z / (S * SQ3 / 2)
	local fq = x / S - fr / 2
	local fy = -fq - fr
	local q, r, y = math.floor(fq + 0.5), math.floor(fr + 0.5), math.floor(fy + 0.5)
	local dq, dr, dy = math.abs(q - fq), math.abs(r - fr), math.abs(y - fy)
	if dq > dr and dq > dy then
		q = -r - y
	elseif dr > dy then
		r = -q - y
	end
	return Grid.at[tileKey(q, r)]
end

function Grid.floorAt(x, z)
	local t = Grid.tileAt(x, z)
	if t and t.kind == 1 then
		return t
	end
	return nil
end

-- true when no pillar blocks the straight line
function Grid.clear(x0, z0, x1, z1)
	local dx, dz = x1 - x0, z1 - z0
	local n = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / 3.2))
	for i = 1, n - 1 do
		local t = Grid.tileAt(x0 + dx * i / n, z0 + dz * i / n)
		if t and t.kind == 2 then
			return false
		end
	end
	return true
end

-- true when every step of the straight line is floor
function Grid.walkable(x0, z0, x1, z1)
	local dx, dz = x1 - x0, z1 - z0
	local n = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / 2.4))
	for i = 1, n do
		local t = Grid.tileAt(x0 + dx * i / n, z0 + dz * i / n)
		if not t or t.kind ~= 1 then
			return false
		end
	end
	return true
end

local function near(x, z, px, pz, radius)
	local dx, dz = x - px, z - pz
	return dx * dx + dz * dz <= radius * radius
end

local function ringPoints(radius, angles)
	local points = {}
	for _, deg in ipairs(angles) do
		table.insert(points, { math.cos(math.rad(deg)) * radius, math.sin(math.rad(deg)) * radius })
	end
	return points
end

-- Maps. Every layout is mirrored left-to-right so both teams get the same ground.
local R = ARENA_R
local MAPS = {
	{
		name = "Plaza",
		off = Color3.fromRGB(48, 52, 86),
		base = Color3.fromRGB(20, 22, 38),
		pillars = ringPoints(0.42 * R, { 30, 90, 150, 210, 270, 330 }),
		layout = function(x, z, ring)
			return ring <= 11
		end,
	},
	{
		name = "Donut",
		off = Color3.fromRGB(58, 46, 84),
		base = Color3.fromRGB(26, 18, 40),
		pillars = ringPoints(0.66 * R, { 45, 135, 225, 315 }),
		layout = function(x, z, ring)
			return ring <= 12 and not near(x, z, 0, 0, 3.3 * S)
		end,
	},
	{
		name = "Twin Isles",
		off = Color3.fromRGB(40, 60, 84),
		base = Color3.fromRGB(16, 26, 38),
		pillars = { { 0.5 * R, 0.2 * R }, { 0.5 * R, -0.2 * R }, { -0.5 * R, 0.2 * R }, { -0.5 * R, -0.2 * R } },
		layout = function(x, z)
			local ax, az = math.abs(x), math.abs(z)
			if near(ax, z, 0.5 * R, 0, 0.47 * R) then
				return true
			end
			return ax <= 0.2 * R and (az <= 1.6 * S or math.abs(az - 0.36 * R) <= 1.1 * S)
		end,
	},
	{
		name = "Clover",
		off = Color3.fromRGB(44, 66, 70),
		base = Color3.fromRGB(16, 30, 32),
		pillars = { { 0.26 * R, 0.26 * R }, { 0.26 * R, -0.26 * R }, { -0.26 * R, 0.26 * R }, { -0.26 * R, -0.26 * R } },
		layout = function(x, z)
			local ax, az = math.abs(x), math.abs(z)
			return near(ax, z, 0.48 * R, 0, 0.36 * R) or near(x, az, 0, 0.48 * R, 0.36 * R) or near(x, z, 0, 0, 0.2 * R)
		end,
	},
	{
		name = "Lattice",
		off = Color3.fromRGB(62, 52, 70),
		base = Color3.fromRGB(28, 22, 32),
		pillars = {},
		layout = function(x, z, ring, q, r)
			return ring <= 12 and not (q % 4 == 0 and r % 4 == 0)
		end,
	},
}

local function nearestFloor(list, x, z)
	local best, bestD = nil, math.huge
	for _, t in ipairs(list) do
		if t.kind == 1 then
			local d = dist(t.x, t.z, x, z)
			if d < bestD then
				best, bestD = t, d
			end
		end
	end
	return best
end

local function linkNeighbours(list)
	for _, t in ipairs(list) do
		t.nb = {}
		for _, d in ipairs(NEIGHBOURS) do
			local n = Grid.at[tileKey(t.q + d[1], t.r + d[2])]
			if n then
				table.insert(t.nb, n)
			end
		end
	end
end

-- Works out which dots exist for a map. Returns false if the map came out broken.
function Grid.plan(def)
	Grid.at = {}
	local list = {}
	for q = -RINGS, RINGS do
		for r = -RINGS, RINGS do
			local ring = math.max(math.abs(q), math.abs(r), math.abs(q + r))
			if ring <= RINGS then
				local x, z = Grid.toWorld(q, r)
				if def.layout(x, z, ring, q, r) then
					local kind = 1
					for _, p in ipairs(def.pillars) do
						if near(x, z, p[1], p[2], S * 0.55) then
							kind = 2
						end
					end
					local t = { q = q, r = r, x = x, z = z, kind = kind, owner = 0, nb = {} }
					Grid.at[tileKey(q, r)] = t
					table.insert(list, t)
				end
			end
		end
	end
	linkNeighbours(list)
	local baseA = nearestFloor(list, -0.84 * R, 0)
	local baseB = nearestFloor(list, 0.84 * R, 0)
	if not baseA or not baseB then
		return false
	end
	-- keep only the floor that can be walked to from the first base
	local reached = { [baseA] = true }
	local queue, head = { baseA }, 1
	while head <= #queue do
		local t = queue[head]
		head = head + 1
		for _, n in ipairs(t.nb) do
			if n.kind == 1 and not reached[n] then
				reached[n] = true
				table.insert(queue, n)
			end
		end
	end
	if not reached[baseB] then
		return false
	end
	local kept = {}
	Grid.at = {}
	for _, t in ipairs(list) do
		local keep = reached[t]
		if t.kind == 2 then
			for _, n in ipairs(t.nb) do
				if reached[n] then
					keep = true
				end
			end
		end
		if keep then
			Grid.at[tileKey(t.q, t.r)] = t
			table.insert(kept, t)
		end
	end
	linkNeighbours(kept)
	Grid.tiles = kept
	Grid.baseTile = { baseA, baseB }
	Grid.floorCount = 0
	for i, t in ipairs(kept) do
		t.idx = i
		if t.kind == 1 then
			Grid.floorCount = Grid.floorCount + 1
		end
	end
	return Grid.floorCount >= 40
end

function Grid.build(def)
	World.Tiles:ClearAllChildren()
	World.Bases:ClearAllChildren()
	World.Pillars:ClearAllChildren()
	World.Props:ClearAllChildren()
	if not Grid.plan(def) then
		warn("[NeonCanvas] map " .. def.name .. " is broken, using Plaza instead")
		def = MAPS[1]
		Grid.plan(def)
	end
	Grid.map = def
	Grid.count = { 0, 0 }
	Grid.beacons = {}
	World.Tiles:SetAttribute("Off", def.off)
	for _, t in ipairs(Grid.tiles) do
		if t.kind == 1 then
			cyl(World.Bases, t.x, FLOOR_Y - 1.5, t.z, 4.2, 3, def.base)
			local dot = cyl(nil, t.x, FLOOR_Y - 0.05, t.z, 3.3, 0.6, def.off, nil, { Name = "Dot" })
			dot:SetAttribute("T", 0)
			dot.Parent = World.Tiles
			t.dot = dot
		else
			cyl(World.Pillars, t.x, FLOOR_Y + 4, t.z, 3.7, 14, Color3.fromRGB(206, 210, 236))
			cyl(World.Pillars, t.x, FLOOR_Y + 11.2, t.z, 3.9, 0.4, Color3.fromRGB(255, 255, 255), Enum.Material.Neon,
				{ CanCollide = false })
		end
	end
	for team = 1, 2 do
		local base = Grid.baseTile[team]
		World.pad[team].Position = Vector3.new(base.x, FLOOR_Y + 1, base.z)
	end
	shared:SetAttribute("MapName", def.name)
	shared:SetAttribute("Total", Grid.floorCount)
end

function Grid.spawnPoint(team, n)
	local base = Grid.baseTile[team]
	local spots = { base }
	for _, nb in ipairs(base.nb) do
		if nb.kind == 1 then
			table.insert(spots, nb)
		end
	end
	local t = spots[n % #spots + 1]
	return t.x, t.z
end

function Grid.setOwner(t, team, f)
	if t.kind ~= 1 or t.owner == team then
		return false
	end
	if t.owner ~= 0 then
		Grid.count[t.owner] = Grid.count[t.owner] - 1
	end
	t.owner = team
	Grid.count[team] = Grid.count[team] + 1
	t.dot:SetAttribute("T", team)
	if f then
		f.stats.tiles = f.stats.tiles + 1
		Combat.addUlt(f, 0.2)
	end
	return true
end

function Grid.paintCircle(team, x, z, radius, f)
	local r2 = radius * radius
	for _, t in ipairs(Grid.tiles) do
		if t.kind == 1 and t.owner ~= team then
			local dx, dz = t.x - x, t.z - z
			if dx * dx + dz * dz <= r2 then
				Grid.setOwner(t, team, f)
			end
		end
	end
end

-- Paints along a line. With radius 0 only the dots directly under the line change.
function Grid.paintLine(team, x0, z0, x1, z1, radius, f)
	local dx, dz = x1 - x0, z1 - z0
	local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / 3))
	for i = 0, steps do
		local x, z = x0 + dx * i / steps, z0 + dz * i / steps
		if radius > 0 then
			Grid.paintCircle(team, x, z, radius, f)
		else
			local t = Grid.floorAt(x, z)
			if t then
				Grid.setOwner(t, team, f)
			end
		end
	end
end

-- Three beacons on the centre line, the same distance from both bases.
function Grid.placeBeacons()
	local onAxis = {}
	for _, t in ipairs(Grid.tiles) do
		if t.kind == 1 and math.abs(t.x) < S * 0.3 then
			table.insert(onAxis, t)
		end
	end
	local used = {}
	for _, targetZ in ipairs({ 0, -0.5 * R, 0.5 * R }) do
		local best, bestScore = nil, math.huge
		for _, t in ipairs(onAxis) do
			local blocked = used[t]
			for _, n in ipairs(t.nb) do
				if used[n] then
					blocked = true
				end
			end
			if not blocked then
				local floors = 0
				for _, n in ipairs(t.nb) do
					if n.kind == 1 then
						floors = floors + 1
					end
				end
				local score = math.abs(t.z - targetZ) + (6 - floors) * 6
				if score < bestScore then
					best, bestScore = t, score
				end
			end
		end
		if best then
			local cluster = { best }
			used[best] = true
			for _, n in ipairs(best.nb) do
				if n.kind == 1 then
					table.insert(cluster, n)
					used[n] = true
				end
			end
			local beacon = { tile = best, cluster = cluster, owner = 0 }
			beacon.pole = cyl(World.Props, best.x, FLOOR_Y + 20, best.z, 0.7, 40, NEUTRAL, Enum.Material.Neon,
				{ Name = "Beacon", CanCollide = false, Transparency = 0.35 })
			for _, t in ipairs(cluster) do
				t.beacon = beacon
				t.dot:SetAttribute("B", true)
			end
			table.insert(Grid.beacons, beacon)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Fighters: human players and computer players share one shape
---------------------------------------------------------------------------------------------------

Fighters.list = {}
Fighters.byPlayer = {}
Fighters.nextId = 1

function Fighters.new(team, player, botName)
	local f = {
		id = Fighters.nextId,
		team = team,
		player = player,
		isBot = player == nil,
		name = player and player.DisplayName or botName,
		alive = false,
		loadout = { primary = "bolt", a1 = "nova", a2 = "shield" },
		ready = { primary = 0, dash = 0, a1 = 0, a2 = 0 },
		ult = 0,
		shieldUntil = 0,
		invulnUntil = 0,
		hasteUntil = 0,
		surgeUntil = 0,
		overdriveUntil = 0,
		dashPaintUntil = 0,
		dashUntil = 0,
		lastHitAt = -100,
		respawnAt = 0,
		nextThink = 0,
		faceX = team == 1 and 1 or -1,
		faceZ = 0,
		velX = 0,
		velZ = 0,
		kvx = 0,
		kvz = 0,
		vy = 0,
		hp = MAX_HP,
		skill = 0.5,
		stats = { tiles = 0, kos = 0, deaths = 0, damage = 0, streak = 0 },
		mines = {},
	}
	Fighters.nextId = Fighters.nextId + 1
	table.insert(Fighters.list, f)
	if player then
		Fighters.byPlayer[player] = f
		player:SetAttribute("Team", team)
		player:SetAttribute("FID", f.id)
		player:SetAttribute("Ult", 0)
	end
	return f
end

function Fighters.remove(f)
	for i, v in ipairs(Fighters.list) do
		if v == f then
			table.remove(Fighters.list, i)
			break
		end
	end
	if f.player and Fighters.byPlayer[f.player] == f then
		Fighters.byPlayer[f.player] = nil
	end
	f.alive = false
	if f.part then
		f.part:Destroy()
		f.part = nil
	end
	for i = #Props.list, 1, -1 do
		local p = Props.list[i]
		if p and p.owner == f then
			Props.remove(p)
		end
	end
end

-- Returns x, y, z of a living fighter, or nil.
function Fighters.pos(f)
	if not f.alive then
		return nil
	end
	if f.isBot then
		return f.x, f.y, f.z
	end
	local root = f.root
	if root and root.Parent then
		local p = root.Position
		return p.X, p.Y, p.Z
	end
	return nil
end

-- Name tag with a health bar. Returns the gui and the bar's fill frame.
function Fighters.plate(parent, name, color, sub, offset)
	local gui = make("BillboardGui", {
		Name = "Plate",
		Size = UDim2.new(0, 130, 0, 44),
		StudsOffset = Vector3.new(0, offset, 0),
		AlwaysOnTop = true,
		MaxDistance = 320,
		LightInfluence = 0,
	}, nil)
	make("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 12),
		Font = Enum.Font.GothamMedium,
		TextSize = 10,
		TextColor3 = Color3.fromRGB(200, 204, 230),
		TextStrokeTransparency = 0.5,
		Text = sub or "",
	}, gui)
	make("TextLabel", {
		Name = "Name",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 12),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = color,
		TextStrokeTransparency = 0.3,
		Text = name,
	}, gui)
	local back = make("Frame", {
		Name = "Bar",
		Position = UDim2.new(0.5, -34, 0, 33),
		Size = UDim2.new(0, 68, 0, 6),
		BackgroundColor3 = Color3.fromRGB(14, 16, 28),
		BorderSizePixel = 0,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, back)
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, back)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
	gui.Parent = parent
	return gui, fill
end

local function setFill(fill, fraction)
	if fill and fill.Parent then
		fill.Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
	end
end

-- Name tag and team outline for a player's character.
function Fighters.decorate(info, player, team)
	local character = info.character
	local glow = character:FindFirstChild("TeamGlow")
	if glow then
		glow:Destroy()
	end
	local head = character:FindFirstChild("Head") or info.root
	if info.plate then
		info.plate:Destroy()
	end
	local color = team > 0 and TEAM_COLOR[team] or NEUTRAL
	local profile = Profiles.data[player]
	local title = ""
	if profile and profile.title ~= "rookie" then
		title = CONFIG.titles[profile.title].name
	end
	info.plate, info.fill = Fighters.plate(head, player.DisplayName, color, title, 2.6)
	setFill(info.fill, info.hum.Health / math.max(1, info.hum.MaxHealth))
	if team > 0 then
		make("Highlight", {
			Name = "TeamGlow",
			FillColor = color,
			FillTransparency = 0.78,
			OutlineColor = color,
			OutlineTransparency = 0.05,
			DepthMode = Enum.HighlightDepthMode.Occluded,
		}, character)
	end
end

-- Puts a player where they belong right now: their base during a match, the deck otherwise.
function Fighters.place(player)
	local info = live[player]
	if not info or info.hum.Health <= 0 or not info.root.Parent then
		return
	end
	local f = Fighters.byPlayer[player]
	local inMatch = f ~= nil and (G.state == "Countdown" or G.state == "Playing")
	local x, y, z
	if f and (inMatch or G.state == "Results") then
		x, z = Grid.spawnPoint(f.team, f.id)
		y = FLOOR_Y + 4
	else
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(2, 12)
		x, y, z = math.cos(a) * d, DECK_Y + 4, math.sin(a) * d
	end
	info.character:PivotTo(CFrame.new(Vector3.new(x, y, z), Vector3.new(0, y, 0.01)))
	info.root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	if inMatch then
		f.character, f.root, f.hum = info.character, info.root, info.hum
		f.alive = true
		f.lastX, f.lastZ = nil, nil
		f.velX, f.velZ = 0, 0
		Fighters.decorate(info, player, f.team)
		if G.state == "Playing" then
			Combat.protect(f, 2.5)
			Grid.paintCircle(f.team, x, z, 8.5, nil)
			info.hum.WalkSpeed = WALK
		else
			info.hum.WalkSpeed = 0
		end
	else
		Fighters.decorate(info, player, f and f.team or 0)
		info.hum.WalkSpeed = WALK
	end
end

-- Called for every new character. Waits until Roblox has finished spawning it.
function Fighters.bindCharacter(player, character)
	local hum = character:WaitForChild("Humanoid", 15)
	local root = character:WaitForChild("HumanoidRootPart", 15)
	if not hum or not root then
		return
	end
	character:WaitForChild("Head", 5)
	local waited = 0
	while character.Parent ~= workspace and waited < 15 do
		waited = waited + task.wait()
	end
	task.wait(0.1)
	if player.Character ~= character or hum.Health <= 0 or not player.Parent then
		return
	end
	local regen = character:FindFirstChild("Health")
	if regen and regen:IsA("BaseScript") then
		regen:Destroy()
	end
	character.ChildAdded:Connect(function(child)
		if child.Name == "Health" and child:IsA("BaseScript") then
			task.defer(function()
				child:Destroy()
			end)
		end
	end)
	hum.MaxHealth = MAX_HP
	hum.Health = MAX_HP
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	local info = { character = character, root = root, hum = hum }
	live[player] = info
	hum.HealthChanged:Connect(function(health)
		setFill(info.fill, health / math.max(1, hum.MaxHealth))
	end)
	hum.Died:Connect(function()
		if live[player] == info then
			live[player] = nil
		end
		local f = Fighters.byPlayer[player]
		if f and f.character == character then
			Combat.down(f)
		end
	end)
	Fighters.place(player)
end

function Fighters.spawnBot(f)
	local x, z = Grid.spawnPoint(f.team, f.id)
	f.x, f.y, f.z = x, BOT_REST, z
	f.kvx, f.kvz, f.vy = 0, 0, 0
	f.velX, f.velZ = 0, 0
	f.hp = MAX_HP
	f.alive = true
	f.wayX, f.wayZ = nil, nil
	f.lastX, f.lastZ = nil, nil
	f.dashUntil = 0
	if not f.part then
		local color = TEAM_COLOR[f.team]
		local part = make("Part", {
			Name = "Bot",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(3.6, 3.6, 3.6),
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Material = Enum.Material.Neon,
			Color = color,
			TopSurface = Enum.SurfaceType.Smooth,
			BottomSurface = Enum.SurfaceType.Smooth,
		}, nil)
		part:SetAttribute("Team", f.team)
		part:SetAttribute("FID", f.id)
		part:SetAttribute("BotName", f.name)
		f.plate, f.fill = Fighters.plate(part, f.name, color, "BOT", 3)
		f.part = part
		part.CFrame = CFrame.new(f.x, f.y, f.z)
		part.Parent = World.Bots
	end
	f.part.CFrame = CFrame.new(f.x, f.y, f.z)
	f.part.Transparency = 0
	f.part:SetAttribute("Alive", true)
	f.plate.Enabled = true
	setFill(f.fill, 1)
	if G.state == "Playing" then
		Combat.protect(f, 2)
		Grid.paintCircle(f.team, x, z, 8.5, nil)
	end
end

-- Shows a timed effect on a fighter (shield bubble, speed, ...). The client draws it.
function Fighters.mark(f, name, untilTime)
	if f.isBot then
		if f.part then
			f.part:SetAttribute(name, untilTime)
		end
	elseif f.player then
		f.player:SetAttribute(name, untilTime)
	end
end

---------------------------------------------------------------------------------------------------
-- Combat: damage, healing, knock-outs
---------------------------------------------------------------------------------------------------

function Combat.addUlt(f, amount)
	if f.ult < 100 and not f.ultLock then
		f.ult = math.min(100, f.ult + amount)
	end
end

function Combat.protect(f, seconds)
	local t = now()
	f.invulnUntil = math.max(f.invulnUntil, t + seconds)
	if f.isBot then
		Fighters.mark(f, "SafeT", t + seconds)
	elseif f.character then
		local field = make("ForceField", { Visible = true }, f.character)
		task.delay(seconds, function()
			field:Destroy()
		end)
	end
end

function Combat.surge(f)
	if f and f.surgeUntil > now() then
		return 1.35
	end
	return 1
end

function Combat.heal(f, amount)
	if not f.alive then
		return
	end
	if f.isBot then
		local before = math.floor(f.hp)
		f.hp = math.min(MAX_HP, f.hp + amount)
		if math.floor(f.hp) ~= before then
			setFill(f.fill, f.hp / MAX_HP)
		end
	else
		local hum = f.hum
		if hum and hum.Health > 0 and hum.Health < hum.MaxHealth then
			hum.Health = math.min(hum.MaxHealth, hum.Health + amount)
		end
	end
end

-- kx, kz: sideways push. kup: upward push. Returns true if the hit landed.
function Combat.damage(victim, amount, attacker, kx, kz, kup)
	if not victim.alive or G.state ~= "Playing" then
		return false
	end
	local t = now()
	local x, y, z = Fighters.pos(victim)
	if not x or victim.invulnUntil > t then
		return false
	end
	if victim.shieldUntil > t then
		FX("block", x, z)
		return false
	end
	amount = math.floor(amount + 0.5)
	victim.lastHitAt = t
	if attacker and attacker ~= victim then
		victim.lastHitBy = attacker
		attacker.stats.damage = attacker.stats.damage + amount
		Combat.addUlt(attacker, amount * 0.2)
	end
	FX("hit", x, y, z, amount, attacker and attacker.id or 0, victim.id)
	if victim.isBot then
		victim.hp = victim.hp - amount
		victim.kvx = victim.kvx + kx
		victim.kvz = victim.kvz + kz
		if kup > 0 then
			victim.vy = math.max(victim.vy, kup * 0.6)
		end
		setFill(victim.fill, victim.hp / MAX_HP)
		if victim.hp <= 0 then
			Combat.down(victim)
		end
	else
		local hum = victim.hum
		hum:TakeDamage(amount)
		if victim.player then
			hurtEvent:FireClient(victim.player, kx, kup, kz, amount)
		end
		if hum.Health <= 0 then
			Combat.down(victim)
		end
	end
	return true
end

-- A fighter is knocked out. Safe to call twice.
function Combat.down(f)
	if not f.alive then
		return
	end
	local x, _, z = Fighters.pos(f)
	local t = now()
	f.alive = false
	f.stats.deaths = f.stats.deaths + 1
	f.stats.streak = 0
	f.respawnAt = t + RESPAWN
	f.dashUntil = 0
	local killer = f.lastHitBy
	if killer and (t - f.lastHitAt > 8 or killer.team == f.team) then
		killer = nil
	end
	f.lastHitBy = nil
	local counted = G.state == "Playing"
	if killer then
		killer.stats.kos = killer.stats.kos + 1
		killer.stats.streak = killer.stats.streak + 1
		Combat.addUlt(killer, 10)
		if x then
			FX("burst", x, z, 17, killer.team, "ko")
			if counted then
				Grid.paintCircle(killer.team, x, z, 17, killer)
			end
		end
		feedEvent:FireAllClients("ko", killer.name, killer.team, f.name, f.team, killer.id, f.id)
		if killer.stats.streak >= 3 then
			feedEvent:FireAllClients("streak", killer.name, killer.team, killer.stats.streak)
		end
		if counted then
			Modes.onKO(killer.team)
		end
	else
		if x then
			FX("burst", x, z, 8, f.team, "fall")
		end
		feedEvent:FireAllClients("fell", f.name, f.team, f.id)
		if counted then
			Modes.onKO(3 - f.team)
		end
	end
	if f.isBot then
		if f.part then
			f.part.Transparency = 1
			f.part:SetAttribute("Alive", false)
			f.plate.Enabled = false
		end
	else
		local hum = f.hum
		if hum and hum.Health > 0 then
			hum.Health = 0
		end
	end
end

-- Hurts enemies of `team` in a circle and paints it.
function Combat.explode(owner, team, x, z, radius, dmg, kb, paintRadius, kind)
	FX("burst", x, z, radius, team, kind)
	if dmg > 0 then
		for _, v in ipairs(Fighters.list) do
			if v.alive and v.team ~= team then
				local vx, vy, vz = Fighters.pos(v)
				if vx and math.abs(vy - BODY_Y) < 14 then
					local dx, dz = vx - x, vz - z
					local d = math.sqrt(dx * dx + dz * dz)
					if d <= radius + BODY_R then
						if d < 0.05 then
							local a = rng:NextNumber(0, math.pi * 2)
							dx, dz, d = math.cos(a), math.sin(a), 1
						end
						Combat.damage(v, dmg, owner, dx / d * kb, dz / d * kb, kb * 0.55)
					end
				end
			end
		end
	end
	if paintRadius > 0 and G.state == "Playing" then
		Grid.paintCircle(team, x, z, paintRadius * Combat.surge(owner), owner)
	end
end

---------------------------------------------------------------------------------------------------
-- Shots: paint bolts flying across the floor
---------------------------------------------------------------------------------------------------

Shots.list = {}
Shots.nextId = 1

function Shots.fire(owner, x, z, dx, dz, speed, range, dmg, kb, splash, kind)
	local id = Shots.nextId
	Shots.nextId = id + 1
	table.insert(Shots.list, {
		id = id, owner = owner, team = owner.team, x = x, z = z, dx = dx, dz = dz,
		speed = speed, left = range, dmg = dmg, kb = kb, splash = splash,
	})
	FX("bolt", id, x, z, dx, dz, speed, range, owner.team, kind)
end

function Shots.step(dt)
	local list = Shots.list
	local i = 1
	while i <= #list do
		local s = list[i]
		local step = math.min(s.left, s.speed * dt)
		local nx, nz = s.x + s.dx * step, s.z + s.dz * step
		local surge = Combat.surge(s.owner)
		-- the first enemy touched along this step
		local hit, hitT = nil, 2
		for _, v in ipairs(Fighters.list) do
			if v.alive and v.team ~= s.team then
				local vx, vy, vz = Fighters.pos(v)
				if vx and math.abs(vy - BODY_Y) < 5.5 then
					local along = 0
					if step > 0 then
						along = math.clamp(((vx - s.x) * s.dx + (vz - s.z) * s.dz) / step, 0, 1)
					end
					local cx, cz = s.x + s.dx * step * along, s.z + s.dz * step * along
					if near(vx, vz, cx, cz, BODY_R + 1.3) and along < hitT then
						hit, hitT = v, along
					end
				end
			end
		end
		local done, how = false, 0
		if hit then
			nx, nz = s.x + s.dx * step * hitT, s.z + s.dz * step * hitT
			Combat.damage(hit, s.dmg, s.owner, s.dx * s.kb, s.dz * s.kb, s.kb * 0.35)
			Grid.paintCircle(s.team, nx, nz, s.splash * 0.75 * surge, s.owner)
			done, how = true, 1
		else
			local tile = Grid.tileAt(nx, nz)
			if tile and tile.kind == 2 then
				nx, nz = s.x, s.z
				Grid.paintCircle(s.team, nx, nz, s.splash * 0.6, s.owner)
				done, how = true, 2
			elseif s.left - step <= 0.001 then
				Grid.paintCircle(s.team, nx, nz, s.splash * surge, s.owner)
				done, how = true, 0
			end
		end
		if done then
			FX("boltEnd", s.id, nx, nz, how, s.team, s.splash)
			list[i] = list[#list]
			list[#list] = nil
		else
			s.x, s.z, s.left = nx, nz, s.left - step
			i = i + 1
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Props: mines, whirlpools and healing totems that sit on the floor for a while
---------------------------------------------------------------------------------------------------

Props.list = {}

function Props.add(p)
	local color = TEAM_COLOR[p.team]
	if p.kind == "mine" then
		p.part = cyl(World.Props, p.x, FLOOR_Y + 0.5, p.z, 1.5, 0.4, color, Enum.Material.Neon,
			{ Name = "Mine", CanCollide = false })
	elseif p.kind == "vortex" then
		p.part = cyl(World.Props, p.x, FLOOR_Y + 0.45, p.z, 16, 0.2, color, Enum.Material.Neon,
			{ Name = "Vortex", CanCollide = false, Transparency = 0.8 })
	else
		p.part = cyl(World.Props, p.x, FLOOR_Y + 3.2, p.z, 0.8, 6, color, Enum.Material.Neon,
			{ Name = "Totem", CanCollide = false })
	end
	p.part:SetAttribute("Team", p.team)
	table.insert(Props.list, p)
	return p
end

function Props.remove(p)
	for i, v in ipairs(Props.list) do
		if v == p then
			table.remove(Props.list, i)
			break
		end
	end
	if p.owner then
		for i, v in ipairs(p.owner.mines) do
			if v == p then
				table.remove(p.owner.mines, i)
				break
			end
		end
	end
	if p.part then
		p.part:Destroy()
		p.part = nil
	end
end

-- Calls fn(fighter, distance, x, z) for living fighters within radius. enemies=true picks the other team.
local function eachNear(team, enemies, x, z, radius, fn)
	for _, v in ipairs(Fighters.list) do
		if v.alive and (v.team ~= team) == enemies then
			local vx, vy, vz = Fighters.pos(v)
			if vx and math.abs(vy - BODY_Y) < 10 then
				local d = dist(x, z, vx, vz)
				if d <= radius then
					fn(v, d, vx, vz)
				end
			end
		end
	end
end

function Props.step(t)
	for i = #Props.list, 1, -1 do
		local p = Props.list[i]
		if p.kind == "mine" then
			if t >= p.dieAt then
				Props.remove(p)
			elseif t >= p.armAt then
				local tripped = false
				eachNear(p.team, true, p.x, p.z, 6.5, function()
					tripped = true
				end)
				if tripped then
					Props.remove(p)
					Combat.explode(p.owner, p.team, p.x, p.z, 12, 36, 44, 12, "mine")
				end
			end
		elseif p.kind == "vortex" then
			if t >= p.dieAt then
				Props.remove(p)
				Combat.explode(p.owner, p.team, p.x, p.z, 11, 0, 0, 11, "vortexEnd")
			elseif t >= p.nextPulse then
				p.nextPulse = t + 0.25
				eachNear(p.team, true, p.x, p.z, 16, function(v, d, vx, vz)
					if d > 1.5 then
						Combat.damage(v, 5, p.owner, (p.x - vx) / d * 30, (p.z - vz) / d * 30, 10)
					else
						Combat.damage(v, 5, p.owner, 0, 0, 0)
					end
				end)
			end
		else
			if t >= p.dieAt then
				Props.remove(p)
			elseif t >= p.nextPulse then
				p.nextPulse = t + 0.5
				eachNear(p.team, false, p.x, p.z, 14, function(v, _, vx, vz)
					Combat.heal(v, 7)
					FX("heal", vx, vz)
				end)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Power-ups that appear on the floor
---------------------------------------------------------------------------------------------------

Power.list = {}
Power.nextAt = 0
local POWER_ORDER = { "surge", "haste", "mend", "charge" }
local POWER_COLOR = {
	surge = Color3.fromRGB(255, 110, 200),
	haste = Color3.fromRGB(255, 226, 90),
	mend = Color3.fromRGB(110, 240, 150),
	charge = Color3.fromRGB(184, 132, 255),
}

function Power.spawn()
	local baseA, baseB = Grid.baseTile[1], Grid.baseTile[2]
	for _ = 1, 20 do
		local t = Grid.tiles[rng:NextInteger(1, #Grid.tiles)]
		if t.kind == 1 and dist(t.x, t.z, baseA.x, baseA.z) > 26 and dist(t.x, t.z, baseB.x, baseB.z) > 26 then
			local taken = false
			for _, p in ipairs(Power.list) do
				if p.tile == t then
					taken = true
				end
			end
			if not taken then
				local kind = POWER_ORDER[rng:NextInteger(1, #POWER_ORDER)]
				local part = make("Part", {
					Name = "Power",
					Shape = Enum.PartType.Ball,
					Size = Vector3.new(2.8, 2.8, 2.8),
					Position = Vector3.new(t.x, FLOOR_Y + 3.2, t.z),
					Color = POWER_COLOR[kind],
					Material = Enum.Material.Neon,
					Anchored = true,
					CanCollide = false,
					CanQuery = false,
					CanTouch = false,
					CastShadow = false,
				}, nil)
				part:SetAttribute("Kind", kind)
				make("PointLight", { Color = POWER_COLOR[kind], Range = 14, Brightness = 2 }, part)
				local gui = make("BillboardGui", {
					Size = UDim2.new(0, 90, 0, 18),
					StudsOffset = Vector3.new(0, 2.6, 0),
					AlwaysOnTop = true,
					MaxDistance = 220,
					LightInfluence = 0,
				}, part)
				make("TextLabel", {
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 1, 0),
					Font = Enum.Font.GothamBold,
					TextSize = 12,
					TextColor3 = POWER_COLOR[kind],
					TextStrokeTransparency = 0.3,
					Text = string.upper(kind),
				}, gui)
				part.Parent = World.Props
				table.insert(Power.list, { tile = t, x = t.x, z = t.z, kind = kind, part = part })
				return
			end
		end
	end
end

function Power.step(t)
	if t >= Power.nextAt then
		Power.nextAt = t + 13
		if #Power.list < 3 then
			Power.spawn()
		end
	end
	for i = #Power.list, 1, -1 do
		local p = Power.list[i]
		local taker = nil
		eachNear(0, true, p.x, p.z, 4.4, function(v)
			taker = taker or v
		end)
		if taker then
			table.remove(Power.list, i)
			p.part:Destroy()
			if p.kind == "surge" then
				taker.surgeUntil = t + 9
				Fighters.mark(taker, "SurgeT", t + 9)
			elseif p.kind == "haste" then
				taker.hasteUntil = t + 9
				Fighters.mark(taker, "HasteT", t + 9)
			elseif p.kind == "mend" then
				Combat.heal(taker, 45)
			else
				Combat.addUlt(taker, 35)
			end
			FX("burst", p.x, p.z, 6, taker.team, "pickup")
			feedEvent:FireAllClients("pickup", taker.name, taker.team, p.kind)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Abilities
---------------------------------------------------------------------------------------------------

-- Runs fn after a delay, but only if the same match is still being played.
function Match.later(delay, fn)
	local round = G.round
	task.delay(delay, function()
		if G.round == round and G.state == "Playing" then
			guard("delayed effect", fn)
		end
	end)
end

Abilities.primary = {
	bolt = function(f, x, z, dx, dz, d)
		Shots.fire(f, x + dx * 2.2, z + dz * 2.2, dx, dz, 125, math.clamp(d, 10, 60) - 2.2, 20, 16, 7.6, "bolt")
	end,
	scatter = function(f, x, z, dx, dz)
		for i = -2, 2 do
			local a = math.rad(i * 9)
			local c, s = math.cos(a), math.sin(a)
			local rx, rz = dx * c - dz * s, dx * s + dz * c
			Shots.fire(f, x + rx * 2.2, z + rz * 2.2, rx, rz, 105, 32, 8, 9, 5.4, "pellet")
		end
	end,
	lob = function(f, x, z, dx, dz, d)
		local range = math.clamp(d, 10, 55)
		local tx, tz = x + dx * range, z + dz * range
		local flight = 0.5 + range / 110
		FX("lob", x, z, tx, tz, flight, f.team)
		Match.later(flight, function()
			Combat.explode(f, f.team, tx, tz, 11, 24, 30, 11, "lob")
		end)
	end,
}

-- Each returns false if it could not be used (the cooldown is then not spent).
Abilities.use = {
	nova = function(f, x, z)
		Combat.explode(f, f.team, x, z, 15, 28, 58, 15, "nova")
	end,
	shield = function(f)
		local t = now()
		f.shieldUntil = t + 3
		Fighters.mark(f, "ShieldT", t + 3)
	end,
	mine = function(f, x, z)
		local tile = Grid.floorAt(x, z)
		if not tile then
			return false
		end
		if #f.mines >= 2 then
			Props.remove(f.mines[1])
		end
		local t = now()
		table.insert(f.mines, Props.add({
			kind = "mine", owner = f, team = f.team, x = tile.x, z = tile.z, armAt = t + 0.9, dieAt = t + 45,
		}))
	end,
	vortex = function(f, x, z, dx, dz, d)
		local range = math.clamp(d, 4, 42)
		local t = now()
		Props.add({
			kind = "vortex", owner = f, team = f.team, x = x + dx * range, z = z + dz * range,
			dieAt = t + 2.6, nextPulse = t,
		})
	end,
	beam = function(f, _, _, dx, dz)
		FX("charge", f.id, 0.45, f.team)
		Match.later(0.45, function()
			local px, _, pz = Fighters.pos(f)
			if not px then
				return
			end
			local length = 60
			for step = 3, 60, 3 do
				local tile = Grid.tileAt(px + dx * step, pz + dz * step)
				if tile and tile.kind == 2 then
					length = step - 2
					break
				end
			end
			local ex, ez = px + dx * length, pz + dz * length
			FX("beam", px, pz, ex, ez, f.team)
			for _, v in ipairs(Fighters.list) do
				if v.alive and v.team ~= f.team then
					local vx, vy, vz = Fighters.pos(v)
					if vx and math.abs(vy - BODY_Y) < 8 then
						local along = math.clamp((vx - px) * dx + (vz - pz) * dz, 0, length)
						if near(vx, vz, px + dx * along, pz + dz * along, 3.4 + BODY_R) then
							Combat.damage(v, 36, f, dx * 34, dz * 34, 16)
						end
					end
				end
			end
			Grid.paintLine(f.team, px, pz, ex, ez, 4.4, f)
		end)
	end,
	blink = function(f, x, z, dx, dz, d)
		local range = math.clamp(d, 8, 34)
		local tx, tz = nil, nil
		for back = range, 4, -3 do
			if Grid.floorAt(x + dx * back, z + dz * back) then
				tx, tz = x + dx * back, z + dz * back
				break
			end
		end
		if not tx then
			return false
		end
		FX("burst", x, z, 5, f.team, "blink")
		if f.isBot then
			f.x, f.z = tx, tz
			f.wayX, f.wayZ = nil, nil
			f.nextThink = 0
		else
			local rotation = f.root.CFrame - f.root.Position
			f.character:PivotTo(CFrame.new(tx, FLOOR_Y + 3.2, tz) * rotation)
		end
		f.lastX, f.lastZ = tx, tz
		f.invulnUntil = math.max(f.invulnUntil, now() + 0.25)
		Combat.explode(f, f.team, tx, tz, 9, 14, 24, 9, "blink")
	end,
	mend = function(f, x, z)
		local t = now()
		Props.add({ kind = "totem", owner = f, team = f.team, x = x, z = z, dieAt = t + 5, nextPulse = t })
	end,
	overdrive = function(f, x, z)
		local t = now()
		f.overdriveUntil = t + 5
		Fighters.mark(f, "OverT", t + 5)
		FX("burst", x, z, 6, f.team, "overdrive")
	end,
}

-- The one entry point for every action, used by players and computer players alike.
function Abilities.act(f, action, ax, az)
	if G.state ~= "Playing" or not f.alive then
		return false
	end
	local x, _, z = Fighters.pos(f)
	if not x then
		return false
	end
	local t = now()
	local dx, dz = ax - x, az - z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 0.5 then
		dx, dz, d = f.faceX, f.faceZ, 0.5
	else
		dx, dz = dx / d, dz / d
	end
	if action == "primary" then
		if t < f.ready.primary - 0.12 then
			return false
		end
		f.ready.primary = t + CONFIG.primaries[f.loadout.primary].cd
		Abilities.primary[f.loadout.primary](f, x, z, dx, dz, d)
	elseif action == "dash" then
		if t < f.ready.dash - 0.12 then
			return false
		end
		f.ready.dash = t + CONFIG.dash.cd
		f.invulnUntil = math.max(f.invulnUntil, t + 0.28)
		f.dashPaintUntil = t + 0.45
		if f.isBot then
			f.dashUntil = t + 0.17
			f.dashX, f.dashZ = dx, dz
		end
		FX("dash", x, z, dx, dz, f.team, f.id)
	elseif action == "a1" or action == "a2" then
		if t < f.ready[action] - 0.12 then
			return false
		end
		local id = f.loadout[action]
		if Abilities.use[id](f, x, z, dx, dz, d) == false then
			return false
		end
		f.ready[action] = t + CONFIG.abilities[id].cd
	elseif action == "ult" then
		if f.ult < 100 then
			return false
		end
		f.ult = 0
		FX("telegraph", x, z, 30, f.team, 0.7)
		feedEvent:FireAllClients("ult", f.name, f.team)
		Match.later(0.7, function()
			f.ultLock = true
			Combat.explode(f, f.team, x, z, 30, 50, 72, 30, "ult")
			f.ultLock = false
		end)
	else
		return false
	end
	f.faceX, f.faceZ = dx, dz
	return true
end

actEvent.OnServerEvent:Connect(function(player, action, ax, az)
	local f = Fighters.byPlayer[player]
	if not f or type(action) ~= "string" or type(ax) ~= "number" or type(az) ~= "number" then
		return
	end
	if ax ~= ax or az ~= az or math.abs(ax) > 5000 or math.abs(az) > 5000 then
		return
	end
	guard("action", Abilities.act, f, action, ax, az)
end)

---------------------------------------------------------------------------------------------------
-- Bots: computer players. They are simple points moved by this script, not Roblox characters,
-- so they can never get stuck on geometry. The client draws a body for each one.
---------------------------------------------------------------------------------------------------

Bots.stamp = 0

-- Breadth-first search over floor dots from where the bot stands. Returns the first step and the goal.
function Bots.route(f, accept)
	local start = Grid.floorAt(f.x, f.z)
	if not start then
		return nil
	end
	local stamp = Bots.stamp + 1
	Bots.stamp = stamp
	start.seen = stamp
	start.from = nil
	local queue, head = { start }, 1
	while head <= #queue do
		local t = queue[head]
		head = head + 1
		if t ~= start and accept(t) then
			local step = t
			while step.from and step.from ~= start do
				step = step.from
			end
			return step, t
		end
		local nb = t.nb
		local count = #nb
		local offset = rng:NextInteger(0, 5)
		for i = 1, count do
			local n = nb[(i + offset) % count + 1]
			if n.kind == 1 and n.seen ~= stamp then
				n.seen = stamp
				n.from = t
				queue[#queue + 1] = n
			end
		end
	end
	return nil
end

-- Where to shoot to hit a moving target, with a miss that shrinks as skill grows.
function Bots.aim(f, v)
	local vx, _, vz = Fighters.pos(v)
	local err = 2 + (1 - f.skill) * 11
	return vx + v.velX * 0.25 + rng:NextNumber(-err, err), vz + v.velZ * 0.25 + rng:NextNumber(-err, err)
end

function Bots.paintTarget(f, range)
	for _ = 1, 12 do
		local t = Grid.tiles[rng:NextInteger(1, #Grid.tiles)]
		if t.kind == 1 and t.owner ~= f.team then
			local d = dist(f.x, f.z, t.x, t.z)
			if d > 14 and d < range then
				return t
			end
		end
	end
	return nil
end

function Bots.fight(f, t, enemy, ed)
	local x, z = f.x, f.z
	local lo = f.loadout
	if f.ult >= 100 then
		f.ultHold = f.ultHold or t
		if (enemy and ed < 22) or t - f.ultHold > 7 then
			f.ultHold = nil
			Abilities.act(f, "ult", x, z)
			return
		end
	end
	if enemy then
		local ex, _, ez = Fighters.pos(enemy)
		local ax, az = Bots.aim(f, enemy)
		for _, slot in ipairs(SLOTS) do
			if t >= f.ready[slot] and rng:NextNumber() < 0.5 then
				local id = lo[slot]
				local use = false
				if id == "nova" then
					use = ed < 13
				elseif id == "shield" then
					use = t - f.lastHitAt < 0.6 and f.hp < MAX_HP * 0.75
				elseif id == "mine" then
					use = ed < 28
				elseif id == "vortex" then
					use = ed < 38
				elseif id == "beam" then
					use = ed < 52
				elseif id == "blink" then
					use = f.hp < MAX_HP * 0.45 and ed < 25
				elseif id == "mend" then
					use = f.hp < MAX_HP * 0.6
				elseif id == "overdrive" then
					use = ed > 30
				end
				if use then
					if id == "blink" then
						Abilities.act(f, slot, x + (x - ex) * 3, z + (z - ez) * 3)
					else
						Abilities.act(f, slot, ax, az)
					end
				end
			end
		end
		if ed <= CONFIG.primaries[lo.primary].range and t >= f.ready.primary and rng:NextNumber() < 0.2 + f.skill * 0.4 then
			Abilities.act(f, "primary", ax, az)
		end
		if t >= f.ready.dash and ((f.hp < MAX_HP * 0.4 and rng:NextNumber() < 0.3) or rng:NextNumber() < 0.06 * f.skill) then
			local d = math.max(1, ed)
			local sx, sz = -(ez - z) / d, (ex - x) / d
			if rng:NextNumber() < 0.5 then
				sx, sz = -sx, -sz
			end
			if Grid.walkable(x, z, x + sx * 17, z + sz * 17) then
				Abilities.act(f, "dash", x + sx * 10, z + sz * 10)
			end
		end
	else
		if t >= f.ready.primary and rng:NextNumber() < 0.22 then
			local target = Bots.paintTarget(f, CONFIG.primaries[lo.primary].range)
			if target then
				Abilities.act(f, "primary", target.x, target.z)
			end
		end
		for _, slot in ipairs(SLOTS) do
			if t >= f.ready[slot] then
				local id = lo[slot]
				if (id == "overdrive" and rng:NextNumber() < 0.25) or (id == "mend" and f.hp < MAX_HP * 0.6)
					or (id == "mine" and rng:NextNumber() < 0.04) then
					Abilities.act(f, slot, x, z)
				end
			end
		end
	end
end

function Bots.think(f, t)
	f.nextThink = t + 0.22 + rng:NextNumber() * 0.2
	local x, z = f.x, f.z
	local enemy, ed = nil, 58
	for _, v in ipairs(Fighters.list) do
		if v.alive and v.team ~= f.team then
			local vx, _, vz = Fighters.pos(v)
			if vx then
				local d = dist(x, z, vx, vz)
				if d < ed and Grid.clear(x, z, vx, vz) then
					enemy, ed = v, d
				end
			end
		end
	end

	local step, goal = nil, nil
	if f.hp < MAX_HP * 0.35 and enemy and ed < 30 and f.skill > 0.5 then
		local base = Grid.baseTile[f.team]
		step, goal = Bots.route(f, function(tile)
			return tile == base
		end)
	end
	if not step then
		for _, p in ipairs(Power.list) do
			if dist(x, z, p.x, p.z) < 34 then
				step, goal = Bots.route(f, function(tile)
					return tile == p.tile
				end)
				break
			end
		end
	end
	if not step and G.mode == "KO" and enemy and ed > 22 then
		local ex, _, ez = Fighters.pos(enemy)
		local target = Grid.floorAt(ex, ez)
		if target then
			step, goal = Bots.route(f, function(tile)
				return tile == target
			end)
		end
	end
	if not step and G.mode == "Beacons" then
		step, goal = Bots.route(f, function(tile)
			return tile.beacon ~= nil and tile.owner ~= f.team
		end)
	end
	if not step then
		step, goal = Bots.route(f, function(tile)
			return tile.owner ~= f.team
		end)
	end
	if not step then
		local here = Grid.floorAt(x, z)
		if here then
			local options = {}
			for _, n in ipairs(here.nb) do
				if n.kind == 1 then
					table.insert(options, n)
				end
			end
			if #options > 0 then
				step = options[rng:NextInteger(1, #options)]
				goal = step
			end
		end
	end
	if step then
		if dist(x, z, goal.x, goal.z) < 45 and Grid.walkable(x, z, goal.x, goal.z) then
			f.wayX, f.wayZ = goal.x, goal.z
		else
			f.wayX, f.wayZ = step.x, step.z
		end
	end
	Bots.fight(f, t, enemy, ed)
end

-- Moves one bot for one frame.
function Bots.move(f, dt, t)
	local speed = WALK
	if t < f.overdriveUntil then
		speed = speed * 1.4
	end
	if t < f.hasteUntil then
		speed = speed * 1.35
	end
	local mx, mz = 0, 0
	if t < f.dashUntil then
		mx, mz = f.dashX * 95, f.dashZ * 95
	elseif f.wayX then
		local dx, dz = f.wayX - f.x, f.wayZ - f.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d > 0.7 then
			mx, mz = dx / d * speed, dz / d * speed
			f.faceX, f.faceZ = dx / d, dz / d
		else
			f.wayX, f.wayZ = nil, nil
			f.nextThink = 0
		end
	end
	local decay = math.exp(-4 * dt)
	f.kvx, f.kvz = f.kvx * decay, f.kvz * decay
	local pushed = math.abs(f.kvx) + math.abs(f.kvz) > 6
	local nx, nz = f.x + (mx + f.kvx) * dt, f.z + (mz + f.kvz) * dt
	local grounded = f.y <= BOT_REST + 0.05 and f.vy <= 0
	local tile = Grid.tileAt(nx, nz)
	if tile and tile.kind == 2 and f.y < FLOOR_Y + 11 then
		-- pillars are walls
		nx, nz = f.x, f.z
		f.kvx, f.kvz = 0, 0
		f.wayX, f.wayZ = nil, nil
		tile = Grid.tileAt(nx, nz)
	elseif not tile and grounded and not pushed then
		-- bots never step off an edge on their own: only a knock-back can throw them out
		nx, nz = f.x, f.z
		f.wayX, f.wayZ = nil, nil
		f.dashUntil = 0
		tile = Grid.tileAt(nx, nz)
	end
	f.x, f.z = nx, nz
	local overFloor = tile ~= nil and tile.kind == 1
	if f.vy ~= 0 or not overFloor or f.y > BOT_REST then
		f.vy = f.vy - 150 * dt
		f.y = f.y + f.vy * dt
		if overFloor and f.vy <= 0 and f.y <= BOT_REST and f.y > BOT_REST - 2.5 then
			f.y = BOT_REST
			f.vy = 0
		end
	end
	if f.y < KILL_Y then
		Combat.down(f)
		return
	end
	f.part.CFrame = CFrame.new(f.x, f.y, f.z)
end

function Bots.frame(dt)
	local t = now()
	for _, f in ipairs(Fighters.list) do
		if f.isBot and f.alive then
			Bots.move(f, dt, t)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Modes: how each kind of match is scored
---------------------------------------------------------------------------------------------------

function Modes.start(mode)
	G.mode = mode
	G.score = { 0, 0 }
	G.rush = false
	G.goal = GOAL[mode]
	G.secAcc = 0
	if mode == "Beacons" then
		Grid.placeBeacons()
	end
	shared:SetAttribute("Mode", mode)
	shared:SetAttribute("Goal", G.goal)
	shared:SetAttribute("Rush", false)
end

function Modes.onKO(team)
	if G.mode == "KO" then
		G.score[team] = G.score[team] + (G.rush and 2 or 1)
	end
end

-- Once a second while a match is on.
function Modes.second()
	if G.mode ~= "Beacons" then
		return
	end
	for _, b in ipairs(Grid.beacons) do
		local c1, c2 = 0, 0
		for _, t in ipairs(b.cluster) do
			if t.owner == 1 then
				c1 = c1 + 1
			elseif t.owner == 2 then
				c2 = c2 + 1
			end
		end
		local need = math.floor(#b.cluster / 2) + 1
		local owner = 0
		if c1 >= need then
			owner = 1
		elseif c2 >= need then
			owner = 2
		end
		if owner ~= b.owner then
			b.owner = owner
			b.pole.Color = owner > 0 and TEAM_COLOR[owner] or NEUTRAL
		end
		if owner > 0 then
			G.score[owner] = G.score[owner] + (G.rush and 2 or 1)
		end
	end
end

function Modes.scores()
	if G.mode == "Turf" then
		return Grid.count[1], Grid.count[2]
	end
	return G.score[1], G.score[2]
end

function Modes.finished()
	if G.goal <= 0 then
		return false
	end
	local a, b = Modes.scores()
	return a >= G.goal or b >= G.goal
end

---------------------------------------------------------------------------------------------------
-- Profiles: what is saved for each player
---------------------------------------------------------------------------------------------------

Profiles.data = {}
Profiles.store = nil
pcall(function()
	Profiles.store = DataStoreService:GetDataStore("NeonCanvas_v1")
end)

local NUMBER_FIELDS = { "lvl", "xp", "rating", "coins", "wins", "matches", "kos", "dots" }

function Profiles.need(lvl)
	return CONFIG.xpBase + CONFIG.xpStep * (lvl - 1)
end

function Profiles.unlocked(profile, def)
	return def ~= nil and profile.lvl >= def.unlock
end

function Profiles.load(player)
	local p = {
		lvl = 1, xp = 0, rating = 0, coins = 0, wins = 0, matches = 0, kos = 0, dots = 0,
		primary = "bolt", a1 = "nova", a2 = "shield", title = "rookie", titles = { rookie = true },
	}
	if not Profiles.store then
		return p
	end
	local ok, saved = pcall(function()
		return Profiles.store:GetAsync("p_" .. player.UserId)
	end)
	if not ok or type(saved) ~= "table" then
		return p
	end
	for _, key in ipairs(NUMBER_FIELDS) do
		local v = tonumber(saved[key])
		if v and v == v and v >= 0 and v < 1e9 then
			p[key] = math.floor(v)
		end
	end
	p.lvl = math.clamp(p.lvl, 1, CONFIG.levelCap)
	if type(saved.titles) == "table" then
		for id, owned in pairs(saved.titles) do
			if owned == true and CONFIG.titles[id] then
				p.titles[id] = true
			end
		end
	end
	if type(saved.title) == "string" and p.titles[saved.title] then
		p.title = saved.title
	end
	if type(saved.primary) == "string" and Profiles.unlocked(p, CONFIG.primaries[saved.primary]) then
		p.primary = saved.primary
	end
	if type(saved.a1) == "string" and Profiles.unlocked(p, CONFIG.abilities[saved.a1]) then
		p.a1 = saved.a1
	end
	if type(saved.a2) == "string" and saved.a2 ~= p.a1 and Profiles.unlocked(p, CONFIG.abilities[saved.a2]) then
		p.a2 = saved.a2
	end
	if p.a1 == p.a2 then
		p.a2 = p.a1 == "nova" and "shield" or "nova"
	end
	return p
end

function Profiles.save(player)
	local p = Profiles.data[player]
	if not p or not Profiles.store then
		return
	end
	local out = { primary = p.primary, a1 = p.a1, a2 = p.a2, title = p.title, titles = p.titles }
	for _, key in ipairs(NUMBER_FIELDS) do
		out[key] = p[key]
	end
	pcall(function()
		Profiles.store:SetAsync("p_" .. player.UserId, out)
	end)
end

-- Copies a profile onto the player as attributes, which is how the client reads it.
function Profiles.sync(player)
	local p = Profiles.data[player]
	if not p then
		return
	end
	player:SetAttribute("Lvl", p.lvl)
	player:SetAttribute("XP", p.xp)
	player:SetAttribute("XPNeed", Profiles.need(p.lvl))
	player:SetAttribute("Rating", p.rating)
	player:SetAttribute("Coins", p.coins)
	player:SetAttribute("Wins", p.wins)
	player:SetAttribute("Matches", p.matches)
	player:SetAttribute("KOs", p.kos)
	player:SetAttribute("Dots", p.dots)
	player:SetAttribute("Primary", p.primary)
	player:SetAttribute("A1", p.a1)
	player:SetAttribute("A2", p.a2)
	player:SetAttribute("Title", p.title)
	local owned = {}
	for _, id in ipairs(CONFIG.titleOrder) do
		if p.titles[id] then
			table.insert(owned, id)
		end
	end
	player:SetAttribute("Titles", table.concat(owned, ","))
end

function Profiles.applyLoadout(player)
	local p = Profiles.data[player]
	local f = Fighters.byPlayer[player]
	if p and f then
		f.loadout.primary, f.loadout.a1, f.loadout.a2 = p.primary, p.a1, p.a2
	end
end

-- Gives match rewards and returns what changed, for the results card.
function Profiles.reward(player, f, outcome)
	local p = Profiles.data[player]
	if not p then
		return nil
	end
	local xp = 30 + math.min(160, math.floor(f.stats.tiles * 0.35)) + f.stats.kos * 12
	local ratingDelta
	if outcome == "win" then
		xp = xp + 50
		ratingDelta = 20
		p.wins = p.wins + 1
	elseif outcome == "draw" then
		xp = xp + 25
		ratingDelta = 5
	else
		xp = xp + 12
		ratingDelta = 0 - math.min(12, p.rating)
	end
	local coins = math.floor(xp / 4)
	local before = p.lvl
	p.matches = p.matches + 1
	p.kos = p.kos + f.stats.kos
	p.dots = p.dots + f.stats.tiles
	p.coins = p.coins + coins
	p.rating = p.rating + ratingDelta
	p.xp = p.xp + xp
	local unlocks = {}
	while p.lvl < CONFIG.levelCap and p.xp >= Profiles.need(p.lvl) do
		p.xp = p.xp - Profiles.need(p.lvl)
		p.lvl = p.lvl + 1
		for _, id in ipairs(CONFIG.primaryOrder) do
			if CONFIG.primaries[id].unlock == p.lvl then
				table.insert(unlocks, CONFIG.primaries[id].name)
			end
		end
		for _, id in ipairs(CONFIG.abilityOrder) do
			if CONFIG.abilities[id].unlock == p.lvl then
				table.insert(unlocks, CONFIG.abilities[id].name)
			end
		end
	end
	Profiles.sync(player)
	return { xp = xp, coins = coins, ratingDelta = ratingDelta, rating = p.rating, lvl0 = before, lvl1 = p.lvl, unlocks = unlocks }
end

requestEvent.OnServerEvent:Connect(function(player, kind, a, b)
	local p = Profiles.data[player]
	if not p or type(kind) ~= "string" or type(a) ~= "string" then
		return
	end
	if kind == "loadout" and type(b) == "string" then
		if a == "primary" then
			if Profiles.unlocked(p, CONFIG.primaries[b]) then
				p.primary = b
			end
		elseif a == "a1" or a == "a2" then
			if Profiles.unlocked(p, CONFIG.abilities[b]) then
				local other = a == "a1" and "a2" or "a1"
				if p[other] == b then
					p[other] = p[a]
				end
				p[a] = b
			end
		end
		Profiles.applyLoadout(player)
		local f = Fighters.byPlayer[player]
		if f and G.state == "Playing" then
			-- no swapping to dodge a cooldown
			local t = now()
			f.ready.a1 = math.max(f.ready.a1, t + 3)
			f.ready.a2 = math.max(f.ready.a2, t + 3)
		end
		Profiles.sync(player)
	elseif kind == "title" then
		local def = CONFIG.titles[a]
		if def then
			if not p.titles[a] and p.coins >= def.cost then
				p.coins = p.coins - def.cost
				p.titles[a] = true
			end
			if p.titles[a] then
				p.title = a
				local info = live[player]
				if info then
					local f = Fighters.byPlayer[player]
					Fighters.decorate(info, player, f and f.team or 0)
				end
			end
			Profiles.sync(player)
		end
	end
end)

---------------------------------------------------------------------------------------------------
-- Match: the round loop
---------------------------------------------------------------------------------------------------

function Match.setState(state, duration)
	G.state = state
	G.endsAt = now() + duration
	shared:SetAttribute("EndsAt", G.endsAt)
	shared:SetAttribute("State", state)
end

function Match.syncScore()
	local a, b = Modes.scores()
	if a ~= G.sentA then
		G.sentA = a
		shared:SetAttribute("ScoreA", a)
	end
	if b ~= G.sentB then
		G.sentB = b
		shared:SetAttribute("ScoreB", b)
	end
end

function Match.teamCount(team, humansOnly)
	local n = 0
	for _, f in ipairs(Fighters.list) do
		if f.team == team and (not humansOnly or not f.isBot) then
			n = n + 1
		end
	end
	return n
end

function Match.addBot(team)
	local used = {}
	for _, f in ipairs(Fighters.list) do
		used[f.name] = true
	end
	local name = "Bot"
	for _ = 1, 40 do
		local candidate = BOT_NAMES[rng:NextInteger(1, #BOT_NAMES)]
		if not used[candidate] then
			name = candidate
			break
		end
	end
	local f = Fighters.new(team, nil, name)
	local base = Match.botSkill()
	f.skill = math.clamp(base + rng:NextNumber(-0.18, 0.18), 0.1, 0.95)
	local a = rng:NextInteger(1, #CONFIG.abilityOrder)
	local b = rng:NextInteger(1, #CONFIG.abilityOrder - 1)
	if b >= a then
		b = b + 1
	end
	f.loadout.primary = CONFIG.primaryOrder[rng:NextInteger(1, #CONFIG.primaryOrder)]
	f.loadout.a1 = CONFIG.abilityOrder[a]
	f.loadout.a2 = CONFIG.abilityOrder[b]
	Fighters.spawnBot(f)
	return f
end

-- How good the computer players are. New players meet easy ones; it rises with level and rating.
function Match.botSkill()
	local total, n = 0, 0
	for _, p in pairs(Profiles.data) do
		total = total + 0.28 + p.lvl * 0.03 + p.rating / 2500
		n = n + 1
	end
	if n == 0 then
		return 0.4
	end
	return math.clamp(total / n, 0.28, 0.78)
end

function Match.addHuman(player, team)
	local f = Fighters.new(team, player)
	Profiles.applyLoadout(player)
	player.RespawnLocation = World.pad[team]
	return f
end

function Match.assignTeams()
	local humans = Players:GetPlayers()
	for i = #humans, 2, -1 do
		local j = rng:NextInteger(1, i)
		humans[i], humans[j] = humans[j], humans[i]
	end
	local first = rng:NextInteger(1, 2)
	for i, player in ipairs(humans) do
		local team = (i % 2 == 1) and first or (3 - first)
		Match.addHuman(player, team)
	end
	local size = math.max(TEAM_SIZE, math.ceil(#humans / 2))
	for team = 1, 2 do
		for _ = Match.teamCount(team) + 1, size do
			Match.addBot(team)
		end
	end
end

-- A player who arrives in the middle of a match takes over a computer player's seat.
function Match.joinLate(player)
	if Fighters.byPlayer[player] then
		return
	end
	local a, b = Match.teamCount(1, true), Match.teamCount(2, true)
	local team
	if a ~= b then
		team = a < b and 1 or 2
	else
		team = rng:NextInteger(1, 2)
	end
	local weakest = nil
	for _, f in ipairs(Fighters.list) do
		if f.isBot and f.team == team and (not weakest or f.stats.tiles < weakest.stats.tiles) then
			weakest = f
		end
	end
	if weakest then
		Fighters.remove(weakest)
	end
	Match.addHuman(player, team)
	Fighters.place(player)
end

function Match.cleanup()
	for i = #Fighters.list, 1, -1 do
		local f = Fighters.list[i]
		if f then
			Fighters.remove(f)
		end
	end
	Fighters.list = {}
	Fighters.byPlayer = {}
	Shots.list = {}
	Props.list = {}
	Power.list = {}
	World.Props:ClearAllChildren()
	World.Bots:ClearAllChildren()
	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute("Team", 0)
		player:SetAttribute("Ult", 0)
		player.RespawnLocation = World.lobbyPad
	end
end

-- Works out the winner, hands out rewards and sends everyone their results card.
function Match.finish()
	local a, b = Modes.scores()
	local winner = 0
	if a > b then
		winner = 1
	elseif b > a then
		winner = 2
	end
	local rows = {}
	for _, f in ipairs(Fighters.list) do
		table.insert(rows, {
			id = f.id, n = f.name, t = f.team, b = f.isBot, d = f.stats.tiles, k = f.stats.kos, x = f.stats.deaths,
			s = f.stats.tiles + f.stats.kos * 12,
		})
	end
	table.sort(rows, function(p, q)
		if p.s ~= q.s then
			return p.s > q.s
		end
		return p.id < q.id
	end)
	if rows[1] then
		rows[1].mvp = true
	end
	for _, f in ipairs(Fighters.list) do
		if f.player and f.player.Parent then
			local outcome = "loss"
			if winner == 0 then
				outcome = "draw"
			elseif winner == f.team then
				outcome = "win"
			end
			local reward = Profiles.reward(f.player, f, outcome)
			resultsEvent:FireClient(f.player, {
				winner = winner, a = a, b = b, mode = G.mode, total = Grid.floorCount, team = f.team, me = f.id,
				rows = rows, reward = reward,
			})
			task.spawn(Profiles.save, f.player)
		end
	end
	feedEvent:FireAllClients("end", winner)
end

function Match.wait()
	while now() < G.endsAt do
		task.wait(0.2)
	end
end

function Match.cycle()
	G.round = G.round + 1
	shared:SetAttribute("Round", G.round)
	local def = MAPS[(G.round - 1) % #MAPS + 1]
	local mode = MODE_ORDER[(G.round - 1) % #MODE_ORDER + 1]

	-- intermission: fresh map, everyone waits on the deck
	Match.cleanup()
	Grid.build(def)
	G.mode = mode
	G.score = { 0, 0 }
	G.rush = false
	G.goal = GOAL[mode]
	shared:SetAttribute("Mode", mode)
	shared:SetAttribute("Goal", G.goal)
	shared:SetAttribute("Rush", false)
	World.setDeck(true)
	Match.setState("Intermission", TIME.intermission)
	for _, player in ipairs(Players:GetPlayers()) do
		Fighters.place(player)
	end
	Match.wait()
	if #Players:GetPlayers() == 0 then
		-- an empty server idles here until somebody arrives, then gives them time to read the menu
		while #Players:GetPlayers() == 0 do
			task.wait(1)
		end
		Match.setState("Intermission", 10)
		Match.wait()
	end

	-- countdown: teams are made and everyone stands at their base
	Modes.start(mode)
	Match.assignTeams()
	for team = 1, 2 do
		local base = Grid.baseTile[team]
		Grid.paintCircle(team, base.x, base.z, 15, nil)
	end
	Match.setState("Countdown", TIME.countdown)
	for _, player in ipairs(Players:GetPlayers()) do
		Fighters.place(player)
	end
	World.setDeck(false)
	Match.wait()

	-- the match itself
	Power.nextAt = now() + 8
	Match.setState("Playing", TIME.match)
	feedEvent:FireAllClients("start", mode)
	while now() < G.endsAt and not Modes.finished() do
		if not G.rush and G.endsAt - now() <= TIME.rush then
			G.rush = true
			shared:SetAttribute("Rush", true)
			feedEvent:FireAllClients("rush")
		end
		task.wait(0.2)
	end

	-- results: the finished painting is shown from above, so name tags of bots step aside
	Match.setState("Results", TIME.results)
	Shots.list = {}
	for _, f in ipairs(Fighters.list) do
		if f.isBot and f.plate then
			f.plate.Enabled = false
		end
	end
	Match.syncScore()
	Match.finish()
	Match.wait()
end

-- Ten times a second: painting by walking, healing, falls, respawns and bot decisions.
function Match.slowTick(step)
	local t = now()
	local playing = G.state == "Playing"
	for _, f in ipairs(Fighters.list) do
		if f.alive then
			local x, y, z = Fighters.pos(f)
			if x then
				if f.lastX then
					f.velX, f.velZ = (x - f.lastX) / step, (z - f.lastZ) / step
					if not f.isBot then
						local sp = f.velX * f.velX + f.velZ * f.velZ
						if sp > 4 then
							local m = math.sqrt(sp)
							f.faceX, f.faceZ = f.velX / m, f.velZ / m
						end
					end
				end
				if playing then
					if y > FLOOR_Y - 1 and y < FLOOR_Y + 5.5 then
						local boosts = 0
						if t < f.overdriveUntil then
							boosts = boosts + 1
						end
						if t < f.surgeUntil then
							boosts = boosts + 1
						end
						if G.rush then
							boosts = boosts + 1
						end
						local wide = 0
						if boosts >= 2 then
							wide = 11
						elseif boosts == 1 then
							wide = 7.4
						elseif t < f.dashPaintUntil then
							wide = 4.6
						end
						if f.lastX and dist(f.lastX, f.lastZ, x, z) < 30 then
							Grid.paintLine(f.team, f.lastX, f.lastZ, x, z, wide, f)
						else
							Grid.paintLine(f.team, x, z, x, z, wide, f)
						end
					end
					if t - f.lastHitAt > 4 then
						Combat.heal(f, 6 * step)
					end
					if not f.isBot and y < KILL_Y then
						Combat.down(f)
					end
				end
				f.lastX, f.lastZ = x, z
				if not f.isBot and f.hum and f.alive then
					local want = WALK
					if G.state == "Countdown" then
						want = 0
					else
						if t < f.overdriveUntil then
							want = want * 1.4
						end
						if t < f.hasteUntil then
							want = want * 1.35
						end
					end
					if math.abs(f.hum.WalkSpeed - want) > 0.01 then
						f.hum.WalkSpeed = want
					end
				end
			end
		elseif f.isBot and playing and t >= f.respawnAt then
			Fighters.spawnBot(f)
		end
		if f.player then
			local u = math.floor(f.ult)
			if u ~= f.ultSent then
				f.ultSent = u
				f.player:SetAttribute("Ult", u)
			end
		end
		if playing and f.isBot and f.alive and t >= f.nextThink then
			guard("bot", Bots.think, f, t)
		end
	end
	if playing then
		Props.step(t)
		Power.step(t)
		G.secAcc = G.secAcc + step
		if G.secAcc >= 1 then
			G.secAcc = G.secAcc - 1
			Modes.second()
		end
	end
	if G.state ~= "Intermission" and G.state ~= "Boot" then
		Match.syncScore()
	end
	-- outside a match nobody can be knocked out: anyone who falls is simply put back
	if not playing then
		for player, info in pairs(live) do
			if info.root.Parent and info.root.Position.Y < KILL_Y then
				Fighters.place(player)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Players joining and leaving
---------------------------------------------------------------------------------------------------

local function onPlayerAdded(player)
	player:SetAttribute("Team", 0)
	player:SetAttribute("Ult", 0)
	player.RespawnLocation = World.lobbyPad
	if G.state == "Countdown" or G.state == "Playing" then
		Match.joinLate(player)
	end
	player.CharacterAdded:Connect(function(character)
		Fighters.bindCharacter(player, character)
	end)
	if player.Character then
		task.spawn(Fighters.bindCharacter, player, player.Character)
	end
	local profile = Profiles.load(player)
	if not player.Parent then
		return
	end
	Profiles.data[player] = profile
	Profiles.sync(player)
	Profiles.applyLoadout(player)
	local info = live[player]
	if info then
		local f = Fighters.byPlayer[player]
		Fighters.decorate(info, player, f and f.team or 0)   -- now that the title is known
	end
end

Players.PlayerRemoving:Connect(function(player)
	local f = Fighters.byPlayer[player]
	if f then
		local team = f.team
		Fighters.remove(f)
		if G.state == "Countdown" or G.state == "Playing" then
			Match.addBot(team)
		end
	end
	live[player] = nil
	Profiles.save(player)
	Profiles.data[player] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		Profiles.save(player)
	end
end)

---------------------------------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------------------------------

Players.RespawnTime = RESPAWN
World.build()
Grid.build(MAPS[1])

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

local slowAcc = 0
RunService.Heartbeat:Connect(function(dt)
	if dt > 0.1 then
		dt = 0.1
	end
	if G.state == "Playing" then
		guard("shots", Shots.step, dt)
		guard("bots", Bots.frame, dt)
	end
	slowAcc = slowAcc + dt
	if slowAcc >= 0.1 then
		local step = slowAcc
		slowAcc = 0
		guard("tick", Match.slowTick, step)
	end
end)

while true do
	local ok, err = pcall(Match.cycle)
	if not ok then
		warn("[NeonCanvas] round error: " .. tostring(err))
		task.wait(3)
	end
end
