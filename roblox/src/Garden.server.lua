-- Lumen Garden: server script (put in ServerScriptService).
-- Builds the world from code, owns all player data, flower genetics and saving.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Lighting = game:GetService("Lighting")

---------------------------------------------------------------- settings

local ISLAND_SLOTS = 12
local RING_RADIUS = 240
local ISLAND_Y = 60
local ISLAND_R = 46
local COLS, ROWS, SPACING = 5, 4, 7.5
local MAX_PLOTS = COLS * ROWS
local START_PLOTS = 6
local START_PETALS = 30
local BASE_BAG = 12
local WILD_COST = 8
local LENS_COST = 300
local REROLL_COST = 25

local FAMILY_NAMES = { "Crimson", "Amber", "Jade", "Aqua", "Azure", "Orchid" }
local SHAPE_NAMES = { "Bloom", "Lily", "Star" }
local LOCI = { "glow", "double", "giant", "shape" }

---------------------------------------------------------------- remotes

local function remote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = ReplicatedStorage
	return r
end

local stateEvent = remote("GardenState")
local actionEvent = remote("GardenAction")
local toastEvent = remote("GardenToast")

local rng = Random.new()

---------------------------------------------------------------- genetics

local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local function family(hue)
	return math.floor(((hue + 1 / 12) % 1) * 6) + 1
end

local function traits(genes)
	return {
		family = family(genes.hue),
		shape = genes.shape[1] + genes.shape[2] + 1, -- 1 round, 2 oval, 3 pointed
		glow = genes.glow[1] + genes.glow[2] == 2,
		double = genes.double[1] + genes.double[2] == 2,
		giant = genes.giant[1] + genes.giant[2] == 2,
	}
end

local function rareCount(t)
	local n = 0
	if t.glow then n = n + 1 end
	if t.double then n = n + 1 end
	if t.giant then n = n + 1 end
	if t.shape == 3 then n = n + 1 end
	return n
end

local function varietyKey(t)
	return t.family .. "_" .. t.shape .. "_" .. (t.glow and 1 or 0) .. (t.double and 1 or 0) .. (t.giant and 1 or 0)
end

local function flowerName(genes)
	local t = traits(genes)
	local parts = {}
	if t.giant then table.insert(parts, "Giant") end
	if t.glow then table.insert(parts, "Glowing") end
	if t.double then table.insert(parts, "Double") end
	table.insert(parts, FAMILY_NAMES[t.family])
	table.insert(parts, SHAPE_NAMES[t.shape])
	return table.concat(parts, " ")
end

local function flowerValue(genes)
	local t = traits(genes)
	local mult = 1
	if t.glow then mult = mult * 3 end
	if t.double then mult = mult * 2.5 end
	if t.giant then mult = mult * 3 end
	if t.shape == 3 then mult = mult * 1.6 elseif t.shape == 2 then mult = mult * 1.2 end
	return math.floor((4 + genes.petals) * mult)
end

local function growSeconds(genes, growthLevel)
	local t = traits(genes)
	return math.max(5, math.floor((14 + genes.petals + 12 * rareCount(t)) * 0.92 ^ growthLevel))
end

local function wildGenes(hueBase)
	local bases = { 0, 1 / 6, 4 / 6 }
	local genes = {
		hue = ((hueBase or bases[rng:NextInteger(1, 3)]) + rng:NextNumber(-0.03, 0.03)) % 1,
		petals = rng:NextInteger(4, 6),
		height = rng:NextNumber(0.8, 1.1),
	}
	for _, locus in ipairs(LOCI) do
		if rng:NextNumber() < 0.12 then
			genes[locus] = { 0, 1 }
		else
			genes[locus] = { 0, 0 }
		end
	end
	return genes
end

-- one allele from each parent; crossing a flower with itself is allowed and can reveal hidden traits
local function cross(a, b, mutation)
	local diff = (b.hue - a.hue + 0.5) % 1 - 0.5
	local hue = (a.hue + diff * rng:NextNumber(0.3, 0.7) + rng:NextNumber(-0.02, 0.02)) % 1
	if rng:NextNumber() < mutation then
		hue = (hue + rng:NextNumber(-0.2, 0.2)) % 1
	end
	local child = {
		hue = hue,
		petals = clamp(math.floor((a.petals + b.petals) / 2 + rng:NextNumber(-1.2, 1.2) + 0.5), 3, 12),
		height = clamp((a.height + b.height) / 2 + rng:NextNumber(-0.1, 0.1), 0.6, 1.6),
	}
	for _, locus in ipairs(LOCI) do
		local pair = { a[locus][rng:NextInteger(1, 2)], b[locus][rng:NextInteger(1, 2)] }
		for k = 1, 2 do
			if rng:NextNumber() < mutation then
				pair[k] = 1 - pair[k]
			end
		end
		child[locus] = pair
	end
	return child
end

local function validGenes(g)
	if type(g) ~= "table" or type(g.hue) ~= "number" or type(g.petals) ~= "number" or type(g.height) ~= "number" then
		return false
	end
	for _, locus in ipairs(LOCI) do
		local p = g[locus]
		if type(p) ~= "table" or (p[1] ~= 0 and p[1] ~= 1) or (p[2] ~= 0 and p[2] ~= 1) then
			return false
		end
	end
	return true
end

---------------------------------------------------------------- parts

local function part(props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in pairs(props) do
		if k ~= "Parent" then
			p[k] = v
		end
	end
	p.Parent = props.Parent
	return p
end

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local function cylinder(parent, center, radius, height, color, material)
	return part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(center) * UPRIGHT,
		Color = color,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	})
end

local function ball(parent, center, diameter, color, material)
	return part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(diameter, diameter, diameter),
		Position = center,
		Color = color,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	})
end

local function ellipsoid(parent, size, cf, color, material)
	local p = part({
		Size = size,
		CFrame = cf,
		Color = color,
		Material = material or Enum.Material.SmoothPlastic,
		CanCollide = false,
		CastShadow = false,
		Parent = parent,
	})
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

---------------------------------------------------------------- atmosphere

local old = workspace:FindFirstChild("Baseplate")
if old then
	old:Destroy()
end
for _, obj in ipairs(workspace:GetChildren()) do
	if obj:IsA("SpawnLocation") then
		obj:Destroy()
	end
end

Lighting.ClockTime = 18.6
Lighting.Brightness = 2
Lighting.Ambient = Color3.fromRGB(95, 85, 130)
Lighting.OutdoorAmbient = Color3.fromRGB(120, 105, 150)
Lighting.ColorShift_Top = Color3.fromRGB(255, 190, 150)
Lighting.EnvironmentDiffuseScale = 0.6
Lighting.EnvironmentSpecularScale = 0.4
Lighting.FogColor = Color3.fromRGB(190, 150, 200)
Lighting.FogEnd = 1400

local atmosphere = Instance.new("Atmosphere")
atmosphere.Density = 0.32
atmosphere.Offset = 0.2
atmosphere.Color = Color3.fromRGB(225, 180, 205)
atmosphere.Decay = Color3.fromRGB(110, 90, 160)
atmosphere.Glare = 0.25
atmosphere.Haze = 1.6
atmosphere.Parent = Lighting

local bloom = Instance.new("BloomEffect")
bloom.Intensity = 0.7
bloom.Size = 32
bloom.Threshold = 0.9
bloom.Parent = Lighting

local grade = Instance.new("ColorCorrectionEffect")
grade.Saturation = 0.18
grade.Contrast = 0.08
grade.TintColor = Color3.fromRGB(255, 240, 248)
grade.Parent = Lighting

local rays = Instance.new("SunRaysEffect")
rays.Intensity = 0.12
rays.Spread = 0.8
rays.Parent = Lighting

-- slow day cycle that lingers around dusk and night, when the flowers glow
task.spawn(function()
	while true do
		local dt = task.wait(1)
		local t = Lighting.ClockTime
		local speed = 0.012
		if t > 7 and t < 16.5 then
			speed = 0.12
		end
		Lighting.ClockTime = (t + speed * dt) % 24
	end
end)

local world = Instance.new("Folder")
world.Name = "LumenGarden"
world.Parent = workspace

local GRASS = Color3.fromRGB(126, 196, 150)
local GRASS_LIGHT = Color3.fromRGB(160, 214, 170)
local ROCK = Color3.fromRGB(92, 84, 120)
local SOIL = Color3.fromRGB(74, 54, 62)
local TRUNK = Color3.fromRGB(96, 70, 82)
local CANOPY = {
	Color3.fromRGB(255, 176, 200),
	Color3.fromRGB(255, 205, 190),
	Color3.fromRGB(186, 160, 235),
	Color3.fromRGB(150, 220, 215),
}

local function tree(parent, base, scale)
	local h = 9 * scale
	cylinder(parent, base + Vector3.new(0, h / 2, 0), 0.7 * scale, h, TRUNK)
	local color = CANOPY[rng:NextInteger(1, #CANOPY)]
	for _ = 1, 4 do
		local offset = Vector3.new(rng:NextNumber(-2.5, 2.5), rng:NextNumber(-1, 2.5), rng:NextNumber(-2.5, 2.5)) * scale
		local b = ball(parent, base + Vector3.new(0, h, 0) + offset, rng:NextNumber(5, 8) * scale, color)
		b.CanCollide = false
	end
end

local function fireflies(parent, center, radius)
	local holder = part({
		Size = Vector3.new(radius * 1.6, 10, radius * 1.6),
		Position = center + Vector3.new(0, 8, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		Parent = parent,
	})
	local e = Instance.new("ParticleEmitter")
	e.Rate = 10
	e.Lifetime = NumberRange.new(5, 9)
	e.Speed = NumberRange.new(0.3, 1.2)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Color = ColorSequence.new(Color3.fromRGB(255, 240, 170))
	e.LightEmission = 1
	e.Parent = holder
end

local function buildIsland(parent, center, radius)
	cylinder(parent, center - Vector3.new(0, 2, 0), radius, 4, GRASS, Enum.Material.Grass)
	local y = center.Y - 4
	local r = radius * 0.92
	for step = 1, 5 do
		local h = 5 + step * 1.5
		cylinder(parent, Vector3.new(center.X, y - h / 2, center.Z), r, h, ROCK, Enum.Material.Slate)
		y = y - h
		r = r * 0.68
	end
end

-- central hub: where players first appear, with a great glowing tree
local hub = Instance.new("Folder")
hub.Name = "Hub"
hub.Parent = world
local HUB_CENTER = Vector3.new(0, ISLAND_Y + 30, 0)
buildIsland(hub, HUB_CENTER, 34)
cylinder(hub, HUB_CENTER + Vector3.new(0, 14, 0), 3.2, 28, TRUNK)
for i = 1, 9 do
	local a = i / 9 * math.pi * 2
	local pos = HUB_CENTER + Vector3.new(math.cos(a) * 11, 30 + rng:NextNumber(-4, 5), math.sin(a) * 11)
	local leaf = ball(hub, pos, rng:NextNumber(11, 16), Color3.fromHSV(0.78 + i * 0.02, 0.35, 1), Enum.Material.Neon)
	leaf.Transparency = 0.35
	leaf.CanCollide = false
end
local hubLight = Instance.new("PointLight")
hubLight.Range = 60
hubLight.Brightness = 1.2
hubLight.Color = Color3.fromRGB(230, 180, 255)
hubLight.Parent = ball(hub, HUB_CENTER + Vector3.new(0, 30, 0), 2, Color3.new(1, 1, 1), Enum.Material.Neon)
fireflies(hub, HUB_CENTER, 34)

local spawnPad = Instance.new("SpawnLocation")
spawnPad.Anchored = true
spawnPad.Neutral = true
spawnPad.Duration = 0
spawnPad.Transparency = 1
spawnPad.CanCollide = false
spawnPad.Size = Vector3.new(8, 1, 8)
spawnPad.Position = HUB_CENTER + Vector3.new(0, 1, 16)
spawnPad.Parent = hub

---------------------------------------------------------------- flowers

local function flowerColor(genes)
	return Color3.fromHSV(genes.hue, 0.62, 1)
end

local function buildFlower(parent, genes, base)
	local t = traits(genes)
	local model = Instance.new("Model")
	model.Name = "Flower"
	local s = t.giant and 1.6 or 1
	local color = flowerColor(genes)
	local material = t.glow and Enum.Material.Neon or Enum.Material.SmoothPlastic
	local stemH = 3.4 * genes.height * s
	local green = Color3.fromRGB(86, 170, 110)

	part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(stemH, 0.3 * s, 0.3 * s),
		CFrame = base * CFrame.new(0, stemH / 2, 0) * UPRIGHT,
		Color = green,
		CanCollide = false,
		Parent = model,
	})
	for side = -1, 1, 2 do
		ellipsoid(model, Vector3.new(0.7 * s, 0.12 * s, 1.5 * s),
			base * CFrame.new(0, stemH * 0.38, 0) * CFrame.Angles(0, side * math.rad(90), 0)
				* CFrame.Angles(math.rad(25), 0, 0) * CFrame.new(0, 0, -0.8 * s), green)
	end

	local head = base * CFrame.new(0, stemH, 0)
	local length, width = 1.5, 1.25
	if t.shape == 2 then
		length, width = 2.0, 0.95
	elseif t.shape == 3 then
		length, width = 2.7, 0.6
	end
	length, width = length * s, width * s

	local function ring(count, len, wid, pitch, offset, col)
		for k = 1, count do
			local yaw = (k + offset) / count * math.pi * 2
			ellipsoid(model, Vector3.new(wid, 0.16 * s, len),
				head * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(pitch), 0, 0)
					* CFrame.new(0, 0, -(len / 2 + 0.25 * s)), col, material)
		end
	end
	ring(genes.petals, length, width, 18, 0, color)
	if t.double then
		ring(genes.petals, length * 0.62, width * 0.8, 46, 0.5, Color3.fromHSV(genes.hue, 0.32, 1))
	end

	local heart = ball(model, head.Position + Vector3.new(0, 0.1 * s, 0), 0.95 * s,
		Color3.fromRGB(255, 222, 130), t.glow and Enum.Material.Neon or Enum.Material.SmoothPlastic)
	heart.CanCollide = false
	if t.glow then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 16 * s
		light.Brightness = 1.6
		light.Parent = heart
		local e = Instance.new("ParticleEmitter")
		e.Rate = 5
		e.Lifetime = NumberRange.new(1.5, 2.5)
		e.Speed = NumberRange.new(0.6, 1.4)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 0),
		})
		e.Color = ColorSequence.new(color)
		e.LightEmission = 1
		e.Parent = heart
	end
	model.Parent = parent
	return model
end

local function buildSprout(parent, base, progress)
	local model = Instance.new("Model")
	model.Name = "Sprout"
	local h = 0.6 + 2.2 * progress
	local green = Color3.fromRGB(110, 200, 130)
	part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(h, 0.22, 0.22),
		CFrame = base * CFrame.new(0, h / 2, 0) * UPRIGHT,
		Color = green,
		CanCollide = false,
		Parent = model,
	})
	local bud = ball(model, (base * CFrame.new(0, h, 0)).Position, 0.45 + 0.5 * progress, green)
	bud.CanCollide = false
	model.Parent = parent
	return model
end

---------------------------------------------------------------- profiles

local store = nil
pcall(function()
	store = DataStoreService:GetDataStore("LumenGarden_v1")
end)

local profiles = {} -- [player] = profile
local slots = {}    -- [slot] = player

local UPGRADES = {
	{ key = "plots", name = "New Plot", desc = "One more place to plant", max = MAX_PLOTS - START_PLOTS, base = 40, growth = 1.45 },
	{ key = "growth", name = "Rich Soil", desc = "Flowers grow 8% faster", max = 10, base = 60, growth = 1.6 },
	{ key = "mutation", name = "Wild Pollen", desc = "More mutations when breeding", max = 10, base = 80, growth = 1.6 },
	{ key = "bag", name = "Seed Pouch", desc = "+4 seed slots", max = 6, base = 50, growth = 1.7 },
}

local function upgradeCost(def, level)
	return math.floor(def.base * def.growth ^ level)
end

local function mutationRate(profile)
	return 0.03 + 0.015 * profile.up.mutation
end

local function bagSize(profile)
	return BASE_BAG + 4 * profile.up.bag
end

local function plotCount(profile)
	return START_PLOTS + profile.up.plots
end

local function newOrder(profile)
	local tier = profile.ordersDone
	local fam
	if tier < 2 then
		local starters = { 1, 2, 5 }
		fam = starters[rng:NextInteger(1, 3)]
	else
		fam = rng:NextInteger(1, 6)
	end
	local order = { family = fam, minPetals = 0, glow = false, double = false, giant = false, pointed = false }
	if tier >= 1 then
		order.minPetals = rng:NextInteger(5, math.min(12, 5 + math.floor(tier / 2)))
	end
	local want = 0
	if tier >= 14 then
		want = rng:NextInteger(2, 3)
	elseif tier >= 8 then
		want = rng:NextInteger(1, 2)
	elseif tier >= 3 then
		want = 1
	end
	local pool = { "glow", "double", "giant", "pointed" }
	for _ = 1, want do
		local i = rng:NextInteger(1, #pool)
		order[pool[i]] = true
		table.remove(pool, i)
	end
	order.reward = 60 + 40 * tier + 90 * want
	profile.order = order
end

local function matchesOrder(order, genes)
	local t = traits(genes)
	if t.family ~= order.family or genes.petals < order.minPetals then
		return false
	end
	if order.glow and not t.glow then return false end
	if order.double and not t.double then return false end
	if order.giant and not t.giant then return false end
	if order.pointed and t.shape ~= 3 then return false end
	return true
end

local function orderText(order)
	local words = {}
	if order.giant then table.insert(words, "Giant") end
	if order.glow then table.insert(words, "Glowing") end
	if order.double then table.insert(words, "Double") end
	table.insert(words, FAMILY_NAMES[order.family])
	table.insert(words, order.pointed and "Star" or "flower")
	local text = table.concat(words, " ")
	if order.minPetals > 0 then
		text = text .. " with " .. order.minPetals .. "+ petals"
	end
	return text
end

local function newProfile()
	local profile = {
		petals = START_PETALS,
		seeds = {},
		nextId = 1,
		plots = {},
		up = { plots = 0, growth = 0, mutation = 0, bag = 0 },
		journal = {},
		ordersDone = 0,
		lens = false,
	}
	for _, hue in ipairs({ 0, 1 / 6, 4 / 6 }) do
		table.insert(profile.seeds, { id = profile.nextId, genes = wildGenes(hue) })
		profile.nextId = profile.nextId + 1
	end
	newOrder(profile)
	return profile
end

local function loadProfile(player)
	local profile = newProfile()
	if not store then
		return profile
	end
	local ok, saved = pcall(function()
		return store:GetAsync("p_" .. player.UserId)
	end)
	if not ok or type(saved) ~= "table" then
		return profile
	end
	profile.petals = tonumber(saved.petals) or profile.petals
	profile.ordersDone = tonumber(saved.ordersDone) or 0
	profile.lens = saved.lens == true
	if type(saved.up) == "table" then
		for _, def in ipairs(UPGRADES) do
			profile.up[def.key] = clamp(tonumber(saved.up[def.key]) or 0, 0, def.max)
		end
	end
	if type(saved.journal) == "table" then
		for key, v in pairs(saved.journal) do
			if v == true then
				profile.journal[tostring(key)] = true
			end
		end
	end
	if type(saved.seeds) == "table" then
		profile.seeds = {}
		profile.nextId = 1
		for _, seed in ipairs(saved.seeds) do
			if type(seed) == "table" and validGenes(seed.genes) then
				table.insert(profile.seeds, { id = profile.nextId, genes = seed.genes })
				profile.nextId = profile.nextId + 1
			end
		end
	end
	if type(saved.plots) == "table" then
		for key, rec in pairs(saved.plots) do
			local index = tonumber(string.match(tostring(key), "%d+"))
			if index and index >= 1 and index <= MAX_PLOTS and type(rec) == "table" and validGenes(rec.genes) then
				profile.plots[index] = {
					genes = rec.genes,
					plantedAt = tonumber(rec.plantedAt) or os.time(),
					growTime = tonumber(rec.growTime) or 20,
				}
			end
		end
	end
	if type(saved.order) == "table" and tonumber(saved.order.family) and tonumber(saved.order.reward) then
		profile.order = {
			family = clamp(math.floor(saved.order.family), 1, 6),
			minPetals = tonumber(saved.order.minPetals) or 0,
			glow = saved.order.glow == true,
			double = saved.order.double == true,
			giant = saved.order.giant == true,
			pointed = saved.order.pointed == true,
			reward = saved.order.reward,
		}
	end
	return profile
end

local function saveProfile(player)
	local profile = profiles[player]
	if not profile or not store then
		return
	end
	local out = {
		petals = profile.petals,
		ordersDone = profile.ordersDone,
		lens = profile.lens,
		up = profile.up,
		journal = profile.journal,
		order = profile.order,
		seeds = {},
		plots = {},
	}
	for _, seed in ipairs(profile.seeds) do
		table.insert(out.seeds, { genes = seed.genes })
	end
	for index, rec in pairs(profile.plots) do
		out.plots["p" .. index] = { genes = rec.genes, plantedAt = rec.plantedAt, growTime = rec.growTime }
	end
	pcall(function()
		store:SetAsync("p_" .. player.UserId, out)
	end)
end

local function journalCount(profile)
	local n = 0
	for _ in pairs(profile.journal) do
		n = n + 1
	end
	return n
end

local function sendState(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local seeds = {}
	for _, seed in ipairs(profile.seeds) do
		table.insert(seeds, {
			id = seed.id,
			genes = seed.genes,
			name = flowerName(seed.genes),
			value = flowerValue(seed.genes),
			grow = growSeconds(seed.genes, profile.up.growth),
		})
	end
	local upgrades = {}
	for _, def in ipairs(UPGRADES) do
		local level = profile.up[def.key]
		table.insert(upgrades, {
			key = def.key, name = def.name, desc = def.desc, level = level, max = def.max,
			cost = upgradeCost(def, level),
		})
	end
	table.insert(upgrades, {
		key = "lens", name = "Gene Lens", desc = "See hidden genes on seeds",
		level = profile.lens and 1 or 0, max = 1, cost = LENS_COST,
	})
	local journal = {}
	for key in pairs(profile.journal) do
		table.insert(journal, key)
	end
	stateEvent:FireClient(player, {
		petals = profile.petals,
		seeds = seeds,
		selected = profile.selected,
		bag = bagSize(profile),
		upgrades = upgrades,
		journal = journal,
		journalTotal = 144,
		lens = profile.lens,
		wildCost = WILD_COST,
		rerollCost = REROLL_COST,
		ordersDone = profile.ordersDone,
		order = { text = orderText(profile.order), reward = profile.order.reward, family = profile.order.family },
	})
end

local function toast(player, title, detail, hue)
	toastEvent:FireClient(player, title, detail or "", hue)
end

---------------------------------------------------------------- plots

local function plotCell(index)
	local col = (index - 1) % COLS
	local row = math.floor((index - 1) / COLS)
	return col, row
end

-- plots unlock from the middle of the bed outwards
local UNLOCK_ORDER = {}
for index = 1, MAX_PLOTS do
	table.insert(UNLOCK_ORDER, index)
end
table.sort(UNLOCK_ORDER, function(a, b)
	local ac, ar = plotCell(a)
	local bc, br = plotCell(b)
	local da = (ac - (COLS - 1) / 2) ^ 2 + (ar - (ROWS - 1) / 2) ^ 2
	local db = (bc - (COLS - 1) / 2) ^ 2 + (br - (ROWS - 1) / 2) ^ 2
	if da == db then
		return a < b
	end
	return da < db
end)

local function isBloomed(rec)
	return rec ~= nil and os.time() >= rec.plantedAt + rec.growTime
end

local function neighbours(profile, index)
	local col, row = plotCell(index)
	local list = {}
	for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
		local c, r = col + d[1], row + d[2]
		if c >= 0 and c < COLS and r >= 0 and r < ROWS then
			local rec = profile.plots[r * COLS + c + 1]
			if isBloomed(rec) then
				table.insert(list, rec)
			end
		end
	end
	return list
end

local function clearVisual(profile, index)
	local v = profile.visual[index]
	if v then
		v:Destroy()
		profile.visual[index] = nil
	end
end

local function refreshPlot(profile, index)
	local spot = profile.spots[index]
	if not spot then
		return
	end
	local rec = profile.plots[index]
	if not rec then
		spot.main.Enabled = true
		spot.main.ActionText = "Plant"
		spot.main.ObjectText = "Empty soil"
		spot.deliver.Enabled = false
		spot.bar.Enabled = false
		spot.label.Enabled = false
	elseif isBloomed(rec) then
		spot.main.Enabled = true
		spot.main.ActionText = "Harvest"
		spot.main.ObjectText = flowerName(rec.genes)
		spot.deliver.Enabled = matchesOrder(profile.order, rec.genes)
		spot.bar.Enabled = false
		spot.label.Enabled = true
		spot.labelText.Text = flowerName(rec.genes)
		spot.labelText.TextColor3 = Color3.fromHSV(rec.genes.hue, 0.35, 1)
	else
		spot.main.Enabled = false
		spot.deliver.Enabled = false
		spot.bar.Enabled = true
		spot.label.Enabled = false
	end
end

local function refreshAllPlots(profile)
	for index in pairs(profile.spots) do
		refreshPlot(profile, index)
	end
end

local function discover(player, profile, genes)
	local t = traits(genes)
	local key = varietyKey(t)
	if profile.journal[key] then
		return
	end
	profile.journal[key] = true
	local bonus = 10 + 25 * rareCount(t)
	profile.petals = profile.petals + bonus
	toast(player, "New variety: " .. flowerName(genes), "+" .. bonus .. " petals  -  " .. journalCount(profile) .. " / 144 discovered", genes.hue)
end

local function showBloom(player, profile, index)
	local rec = profile.plots[index]
	local spot = profile.spots[index]
	if not rec or not spot then
		return
	end
	clearVisual(profile, index)
	profile.visual[index] = buildFlower(profile.folder, rec.genes, spot.base)
	rec.shown = "bloom"
	discover(player, profile, rec.genes)
	refreshPlot(profile, index)
end

local function showGrowth(profile, index)
	local rec = profile.plots[index]
	local spot = profile.spots[index]
	if not rec or not spot then
		return
	end
	local progress = clamp((os.time() - rec.plantedAt) / rec.growTime, 0, 1)
	spot.fill.Size = UDim2.new(progress, 0, 1, 0)
	local stage = math.floor(progress * 4)
	if rec.shown ~= stage then
		rec.shown = stage
		clearVisual(profile, index)
		profile.visual[index] = buildSprout(profile.folder, spot.base, progress)
	end
end

local function addSeed(player, profile, genes)
	if #profile.seeds >= bagSize(profile) then
		local refund = math.floor(flowerValue(genes) * 0.4)
		profile.petals = profile.petals + refund
		toast(player, "Seed pouch is full", "Extra seed sold for " .. refund .. " petals")
		return
	end
	table.insert(profile.seeds, { id = profile.nextId, genes = genes })
	profile.nextId = profile.nextId + 1
end

local function plant(player, profile, index)
	if profile.plots[index] then
		return
	end
	local seedIndex = nil
	for i, seed in ipairs(profile.seeds) do
		if seed.id == profile.selected then
			seedIndex = i
		end
	end
	if not seedIndex then
		toast(player, "Pick a seed first", "Tap a seed at the bottom of the screen")
		return
	end
	local seed = table.remove(profile.seeds, seedIndex)
	profile.selected = nil
	profile.plots[index] = {
		genes = seed.genes,
		plantedAt = os.time(),
		growTime = growSeconds(seed.genes, profile.up.growth),
	}
	showGrowth(profile, index)
	refreshPlot(profile, index)
	sendState(player)
end

local function harvest(player, profile, index)
	local rec = profile.plots[index]
	if not isBloomed(rec) then
		return
	end
	local value = flowerValue(rec.genes)
	profile.petals = profile.petals + value
	local near = neighbours(profile, index)
	local count = 1
	if rng:NextNumber() < 0.25 then
		count = 2
	end
	local hybrid = false
	for _ = 1, count do
		local other = rec
		if #near > 0 then
			other = near[rng:NextInteger(1, #near)]
			hybrid = true
		end
		addSeed(player, profile, cross(rec.genes, other.genes, mutationRate(profile)))
	end
	profile.plots[index] = nil
	clearVisual(profile, index)
	refreshPlot(profile, index)
	toast(player, "+" .. value .. " petals", (hybrid and "Hybrid seed" or "Seed") .. (count > 1 and "s x2" or "") .. " collected", rec.genes.hue)
	sendState(player)
end

local function deliver(player, profile, index)
	local rec = profile.plots[index]
	if not isBloomed(rec) or not matchesOrder(profile.order, rec.genes) then
		return
	end
	local reward = profile.order.reward
	profile.petals = profile.petals + reward
	profile.ordersDone = profile.ordersDone + 1
	profile.plots[index] = nil
	clearVisual(profile, index)
	newOrder(profile)
	refreshAllPlots(profile)
	toast(player, "Order delivered!", "+" .. reward .. " petals", rec.genes.hue)
	sendState(player)
end

local function addSpot(player, profile, index)
	local col, row = plotCell(index)
	local offset = Vector3.new((col - (COLS - 1) / 2) * SPACING, 0, (row - (ROWS - 1) / 2) * SPACING)
	local pos = profile.center + offset
	local soil = cylinder(profile.folder, pos + Vector3.new(0, 0.25, 0), 2.3, 0.7, SOIL, Enum.Material.Ground)
	soil.Name = "Soil" .. index
	cylinder(profile.folder, pos + Vector3.new(0, 0.05, 0), 2.9, 0.3, GRASS_LIGHT)

	local main = Instance.new("ProximityPrompt")
	main.KeyboardKeyCode = Enum.KeyCode.E
	main.HoldDuration = 0
	main.MaxActivationDistance = 9
	main.RequiresLineOfSight = false
	main.Parent = soil
	local deliverPrompt = Instance.new("ProximityPrompt")
	deliverPrompt.KeyboardKeyCode = Enum.KeyCode.F
	deliverPrompt.ActionText = "Deliver to order"
	deliverPrompt.ObjectText = "Matches the Lantern's order"
	deliverPrompt.HoldDuration = 0.4
	deliverPrompt.MaxActivationDistance = 9
	deliverPrompt.RequiresLineOfSight = false
	deliverPrompt.UIOffset = Vector2.new(0, -90)
	deliverPrompt.Enabled = false
	deliverPrompt.Parent = soil

	local bar = Instance.new("BillboardGui")
	bar.Size = UDim2.new(0, 64, 0, 8)
	bar.StudsOffset = Vector3.new(0, 4.2, 0)
	bar.MaxDistance = 70
	bar.Enabled = false
	bar.Parent = soil
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, 0, 1, 0)
	back.BackgroundColor3 = Color3.fromRGB(24, 20, 44)
	back.BackgroundTransparency = 0.3
	back.BorderSizePixel = 0
	back.Parent = bar
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(190, 255, 200)
	fill.BorderSizePixel = 0
	fill.Parent = back
	for _, f in ipairs({ back, fill }) do
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = f
	end

	local label = Instance.new("BillboardGui")
	label.Size = UDim2.new(0, 220, 0, 24)
	label.StudsOffset = Vector3.new(0, 8.5, 0)
	label.MaxDistance = 34
	label.Enabled = false
	label.Parent = soil
	local labelText = Instance.new("TextLabel")
	labelText.Size = UDim2.new(1, 0, 1, 0)
	labelText.BackgroundTransparency = 1
	labelText.Font = Enum.Font.GothamMedium
	labelText.TextSize = 15
	labelText.TextStrokeTransparency = 0.6
	labelText.Text = ""
	labelText.Parent = label

	profile.spots[index] = {
		base = CFrame.new(pos + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
		main = main, deliver = deliverPrompt, bar = bar, fill = fill, label = label, labelText = labelText,
	}
	main.Triggered:Connect(function(who)
		if who ~= player or profiles[player] ~= profile then
			return
		end
		if profile.plots[index] then
			harvest(player, profile, index)
		else
			plant(player, profile, index)
		end
	end)
	deliverPrompt.Triggered:Connect(function(who)
		if who == player and profiles[player] == profile then
			deliver(player, profile, index)
		end
	end)
	refreshPlot(profile, index)
end

local function syncSpots(player, profile)
	for n = 1, plotCount(profile) do
		local index = UNLOCK_ORDER[n]
		if not profile.spots[index] then
			addSpot(player, profile, index)
		end
	end
end

---------------------------------------------------------------- islands

local function buildGarden(player, profile, slot)
	local angle = (slot - 1) / ISLAND_SLOTS * math.pi * 2
	local center = Vector3.new(math.cos(angle) * RING_RADIUS, ISLAND_Y, math.sin(angle) * RING_RADIUS)
	local folder = Instance.new("Folder")
	folder.Name = "Garden_" .. player.Name
	folder.Parent = world
	profile.folder = folder
	profile.center = center
	profile.spots = {}
	profile.visual = {}

	buildIsland(folder, center, ISLAND_R)
	for i = 1, 5 do
		local a = angle + math.rad(60 + i * 48)
		tree(folder, center + Vector3.new(math.cos(a) * (ISLAND_R - 9), 0, math.sin(a) * (ISLAND_R - 9)), rng:NextNumber(0.8, 1.3))
	end
	for _ = 1, 6 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(ISLAND_R - 14, ISLAND_R - 4)
		ball(folder, center + Vector3.new(math.cos(a) * d, 0.4, math.sin(a) * d), rng:NextNumber(1.5, 3.5), ROCK, Enum.Material.Slate)
	end
	-- the Lantern
	local lanternPos = center + Vector3.new(0, 0, -(ROWS * SPACING / 2 + 7))
	cylinder(folder, lanternPos + Vector3.new(0, 3.5, 0), 0.35, 7, TRUNK)
	local lamp = ball(folder, lanternPos + Vector3.new(0, 8, 0), 2.6, Color3.fromRGB(255, 214, 150), Enum.Material.Neon)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 200, 140)
	light.Range = 46
	light.Brightness = 1.4
	light.Parent = lamp
	fireflies(folder, center, ISLAND_R)

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.new(0, 260, 0, 30)
	sign.StudsOffset = Vector3.new(0, 4, 0)
	sign.MaxDistance = 400
	sign.Parent = lamp
	local signText = Instance.new("TextLabel")
	signText.Size = UDim2.new(1, 0, 1, 0)
	signText.BackgroundTransparency = 1
	signText.Font = Enum.Font.GothamBold
	signText.TextSize = 18
	signText.TextColor3 = Color3.fromRGB(255, 236, 210)
	signText.TextStrokeTransparency = 0.5
	signText.Text = player.DisplayName .. "'s Garden"
	signText.Parent = sign

	syncSpots(player, profile)
	for index, rec in pairs(profile.plots) do
		if profile.spots[index] then
			if isBloomed(rec) then
				showBloom(player, profile, index)
			else
				showGrowth(profile, index)
				refreshPlot(profile, index)
			end
		else
			profile.plots[index] = nil
		end
	end
end

local function sendHome(player)
	local profile = profiles[player]
	local char = player.Character
	if profile and profile.center and char then
		char:PivotTo(CFrame.new(profile.center + Vector3.new(0, 5, ROWS * SPACING / 2 + 9), profile.center + Vector3.new(0, 5, 0)))
	end
end

---------------------------------------------------------------- players

local function onPlayerAdded(player)
	local slot = nil
	for i = 1, ISLAND_SLOTS do
		if not slots[i] then
			slot = i
			break
		end
	end
	if not slot then
		player:Kick("All gardens on this server are taken. Please join another server.")
		return
	end
	slots[slot] = player

	local profile = loadProfile(player)
	if not player.Parent then
		slots[slot] = nil
		return
	end
	profile.slot = slot
	profiles[player] = profile
	buildGarden(player, profile, slot)

	player.CharacterAdded:Connect(function()
		task.wait(0.3)
		sendHome(player)
	end)
	if player.Character then
		sendHome(player)
	end
	sendState(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

Players.PlayerRemoving:Connect(function(player)
	local profile = profiles[player]
	if profile then
		saveProfile(player)
		if profile.folder then
			profile.folder:Destroy()
		end
		slots[profile.slot] = nil
	else
		for i = 1, ISLAND_SLOTS do
			if slots[i] == player then
				slots[i] = nil
			end
		end
	end
	profiles[player] = nil
end)

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do
		saveProfile(p)
	end
end)

---------------------------------------------------------------- actions from the client

local function findSeed(profile, id)
	for i, seed in ipairs(profile.seeds) do
		if seed.id == id then
			return i, seed
		end
	end
	return nil
end

actionEvent.OnServerEvent:Connect(function(player, action, arg)
	local profile = profiles[player]
	if not profile or type(action) ~= "string" then
		return
	end
	if action == "ready" then
		sendState(player)
	elseif action == "select" then
		if findSeed(profile, arg) then
			profile.selected = arg
		else
			profile.selected = nil
		end
		sendState(player)
	elseif action == "sell" then
		local i, seed = findSeed(profile, arg)
		if i then
			local price = math.floor(flowerValue(seed.genes) * 0.4)
			table.remove(profile.seeds, i)
			if profile.selected == arg then
				profile.selected = nil
			end
			profile.petals = profile.petals + price
			toast(player, "Seed sold", "+" .. price .. " petals", seed.genes.hue)
			sendState(player)
		end
	elseif action == "wild" then
		local free = #profile.seeds == 0 and next(profile.plots) == nil
		if #profile.seeds >= bagSize(profile) then
			toast(player, "Seed pouch is full", "Plant or sell a seed first")
		elseif not free and profile.petals < WILD_COST then
			toast(player, "Not enough petals", "A wild seed costs " .. WILD_COST)
		else
			if not free then
				profile.petals = profile.petals - WILD_COST
			end
			addSeed(player, profile, wildGenes())
			sendState(player)
		end
	elseif action == "reroll" then
		if profile.petals < REROLL_COST then
			toast(player, "Not enough petals", "A new order costs " .. REROLL_COST)
		else
			profile.petals = profile.petals - REROLL_COST
			newOrder(profile)
			refreshAllPlots(profile)
			sendState(player)
		end
	elseif action == "upgrade" then
		if arg == "lens" then
			if profile.lens then
				return
			end
			if profile.petals < LENS_COST then
				toast(player, "Not enough petals", "The Gene Lens costs " .. LENS_COST)
				return
			end
			profile.petals = profile.petals - LENS_COST
			profile.lens = true
			toast(player, "Gene Lens unlocked", "Seeds now show their hidden genes")
			sendState(player)
			return
		end
		for _, def in ipairs(UPGRADES) do
			if def.key == arg then
				local level = profile.up[def.key]
				local cost = upgradeCost(def, level)
				if level >= def.max then
					return
				end
				if profile.petals < cost then
					toast(player, "Not enough petals", def.name .. " costs " .. cost)
					return
				end
				profile.petals = profile.petals - cost
				profile.up[def.key] = level + 1
				if def.key == "plots" then
					syncSpots(player, profile)
				end
				toast(player, def.name .. " upgraded", "Level " .. (level + 1))
				sendState(player)
				return
			end
		end
	end
end)

---------------------------------------------------------------- main loop

local lastSave = os.clock()

while true do
	task.wait(1)
	for player, profile in pairs(profiles) do
		if profile.spots then
			local changed = false
			for index, rec in pairs(profile.plots) do
				if rec.shown ~= "bloom" then
					if isBloomed(rec) then
						showBloom(player, profile, index)
						changed = true
					else
						showGrowth(profile, index)
					end
				end
			end
			if changed then
				sendState(player)
			end
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root.Position.Y < ISLAND_Y - 45 then
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			sendHome(player)
		end
	end
	if os.clock() - lastSave > 120 then
		lastSave = os.clock()
		for _, p in ipairs(Players:GetPlayers()) do
			task.spawn(saveProfile, p)
		end
	end
end
