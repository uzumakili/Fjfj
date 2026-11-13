-- NEON CANVAS: client script (goes in StarterPlayer > StarterPlayerScripts).
--
-- Everything the player sees and touches: the top-down camera, aiming and input, the glowing
-- floor, effects, sounds, the HUD, the menu and the results card. All rules live in the server
-- script; this one only draws and sends requests.
--
-- Written in plain Lua 5.1 syntax so the offline test harness in roblox/test can run it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local shared = ReplicatedStorage:WaitForChild("NeonCanvas")
local world = workspace:WaitForChild("NeonCanvas")
local CONFIG = HttpService:JSONDecode(shared:WaitForChild("Config").Value)
local actEvent = shared:WaitForChild("Act")
local requestEvent = shared:WaitForChild("Request")
local fxEvent = shared:WaitForChild("FX")
local feedEvent = shared:WaitForChild("Feed")
local hurtEvent = shared:WaitForChild("Hurt")
local resultsEvent = shared:WaitForChild("Results")

local SOUND_ON = true            -- set to false to silence the game
local FLOOR = CONFIG.floorY

---------------------------------------------------------------------------------------------------
-- Theme and small helpers
---------------------------------------------------------------------------------------------------

local function rgb(t)
	return Color3.fromRGB(t[1], t[2], t[3])
end

local C = {
	ink = Color3.fromRGB(13, 15, 28),
	card = Color3.fromRGB(32, 36, 64),
	cardHi = Color3.fromRGB(54, 60, 102),
	text = Color3.fromRGB(245, 246, 255),
	muted = Color3.fromRGB(150, 156, 196),
	gold = Color3.fromRGB(255, 214, 102),
	good = Color3.fromRGB(110, 236, 160),
	bad = Color3.fromRGB(255, 92, 110),
	white = Color3.fromRGB(255, 255, 255),
	team = { rgb(CONFIG.teamColors[1]), rgb(CONFIG.teamColors[2]) },
}
local BLACK, BOLD, MEDIUM = Enum.Font.GothamBlack, Enum.Font.GothamBold, Enum.Font.GothamMedium
local SMOOTH, NEON = Enum.Material.SmoothPlastic, Enum.Material.Neon
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
local CENTER = Enum.TextXAlignment.Center

local UI, Sfx, Tiles, BotView, Fx, Cam, Input, Hud, Menu, Results = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}

-- the local player's character, refreshed every time they respawn
local me = { character = nil, root = nil, hum = nil, diedAt = 0, killer = nil }

local function serverNow()
	return workspace:GetServerTimeNow()
end

local function phase()
	return shared:GetAttribute("State") or "Boot"
end

local function myTeam()
	return player:GetAttribute("Team") or 0
end

local function alive()
	return me.hum ~= nil and me.root ~= nil and me.root.Parent ~= nil and me.hum.Health > 0
end

local function hex(color)
	return string.format("#%02x%02x%02x", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5))
end

local function escape(text)
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

local function teamColor(team)
	return C.team[team] or C.white
end

local warned = 0
local function guard(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and warned < 20 then
		warned = warned + 1
		warn("[NeonCanvas] " .. label .. ": " .. tostring(err))
	end
end

local function bindCharacter(character)
	me.character, me.root, me.hum = character, nil, nil
	task.spawn(function()
		local hum = character:WaitForChild("Humanoid", 15)
		local root = character:WaitForChild("HumanoidRootPart", 15)
		if me.character ~= character or not hum or not root then
			return
		end
		me.hum, me.root = hum, root
		hum.Died:Connect(function()
			if me.hum == hum then
				me.diedAt = os.clock()
			end
		end)
	end)
end

---------------------------------------------------------------------------------------------------
-- UI building blocks
---------------------------------------------------------------------------------------------------

function UI.new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

function UI.corner(inst, radius)
	return UI.new("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

function UI.round(inst)
	return UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, inst)
end

function UI.stroke(inst, color, thickness, transparency)
	return UI.new("UIStroke", {
		Color = color or C.white,
		Thickness = thickness or 1,
		Transparency = transparency or 0.86,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
end

function UI.frame(parent, props)
	props.BorderSizePixel = 0
	if props.BackgroundColor3 == nil and props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	return UI.new("Frame", props, parent)
end

-- dark glass panel
function UI.panel(parent, props, radius)
	props.BackgroundColor3 = props.BackgroundColor3 or C.ink
	props.BackgroundTransparency = props.BackgroundTransparency or 0.14
	local f = UI.frame(parent, props)
	UI.corner(f, radius or 18)
	UI.stroke(f)
	return f
end

function UI.label(parent, text, size, font, color, props)
	local base = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = text,
		TextSize = size,
		Font = font or MEDIUM,
		TextColor3 = color or C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, size + 6),
	}
	if props then
		for k, v in pairs(props) do
			base[k] = v
		end
	end
	return UI.new("TextLabel", base, parent)
end

function UI.button(parent, text, props, fill)
	local base = {
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = text,
		TextSize = 13,
		Font = BOLD,
		TextColor3 = fill and C.ink or C.text,
		BackgroundColor3 = fill or C.card,
		Size = UDim2.new(0, 110, 0, 32),
	}
	if props then
		for k, v in pairs(props) do
			base[k] = v
		end
	end
	local b = UI.new("TextButton", base, parent)
	UI.round(b)
	if not fill then
		UI.stroke(b)
	end
	b.Activated:Connect(function()
		Sfx.play("click")
	end)
	return b
end

-- Small pictograms drawn from dots, bars and rings, so no image files are needed.
-- Coordinates run from -1 to 1 across the holder.
local ICONS = {
	bolt = { { "bar", -0.2, 0.2, 1.0, 0.24, -45 }, { "dot", 0.4, -0.4, 0.32 } },
	scatter = { { "dot", -0.55, -0.3, 0.2 }, { "dot", 0, -0.55, 0.2 }, { "dot", 0.55, -0.3, 0.2 }, { "dot", 0, 0.45, 0.3 } },
	lob = { { "dot", 0.5, -0.15, 0.32 }, { "dot", -0.65, 0.55, 0.1 }, { "dot", -0.38, 0.08, 0.13 }, { "dot", 0, -0.3, 0.16 } },
	dash = { { "bar", -0.1, -0.42, 1.2, 0.18, 0 }, { "bar", 0.15, 0, 1.2, 0.18, 0 }, { "bar", -0.1, 0.42, 1.2, 0.18, 0 } },
	nova = { { "ring", 0, 0, 0.85 }, { "dot", 0, 0, 0.3 } },
	shield = { { "ring", 0, 0, 0.9 }, { "ring", 0, 0, 0.5 } },
	mine = { { "bar", 0, 0, 1.6, 0.16, 0 }, { "bar", 0, 0, 1.6, 0.16, 90 }, { "bar", 0, 0, 1.3, 0.16, 45 },
		{ "bar", 0, 0, 1.3, 0.16, -45 }, { "dot", 0, 0, 0.44 } },
	vortex = { { "ring", 0, 0, 0.9 }, { "ring", 0.12, 0.08, 0.55 }, { "dot", 0.2, 0.14, 0.16 } },
	beam = { { "bar", 0.1, -0.1, 1.7, 0.32, -45 }, { "dot", -0.6, 0.6, 0.24 } },
	blink = { { "dot", -0.5, 0.5, 0.22 }, { "bar", 0, 0, 0.5, 0.12, -45 }, { "dot", 0.5, -0.5, 0.36 } },
	mend = { { "bar", 0, 0, 1.4, 0.4, 0 }, { "bar", 0, 0, 0.4, 1.4, 0 } },
	overdrive = { { "bar", -0.24, -0.3, 0.75, 0.2, -45 }, { "bar", 0.24, -0.3, 0.75, 0.2, 45 },
		{ "bar", -0.24, 0.3, 0.75, 0.2, -45 }, { "bar", 0.24, 0.3, 0.75, 0.2, 45 } },
	ult = { { "bar", 0, 0, 1.9, 0.16, 0 }, { "bar", 0, 0, 1.9, 0.16, 90 }, { "bar", 0, 0, 1.5, 0.16, 45 },
		{ "bar", 0, 0, 1.5, 0.16, -45 }, { "dot", 0, 0, 0.42 } },
}

function UI.icon(holder, kind, color)
	holder:ClearAllChildren()
	local shapes = ICONS[kind]
	if not shapes then
		return
	end
	for _, s in ipairs(shapes) do
		local what, x, y = s[1], s[2], s[3]
		local props = {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5 + x / 2, 0, 0.5 + y / 2, 0),
			BackgroundColor3 = color,
		}
		if what == "bar" then
			props.Size = UDim2.new(s[4] / 2, 0, s[5] / 2, 0)
			props.Rotation = s[6]
		else
			props.Size = UDim2.new(s[4], 0, s[4], 0)
		end
		if what == "ring" then
			props.BackgroundTransparency = 1
		end
		local f = UI.frame(holder, props)
		UI.round(f)
		if what == "ring" then
			UI.stroke(f, color, 2.5, 0)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Sounds: only files that ship inside every Roblox client
---------------------------------------------------------------------------------------------------

Sfx.defs = {
	fire = { "snap", 1.7, 0.22 },
	pellets = { "snap", 1.2, 0.26 },
	lob = { "swordlunge", 1.25, 0.3 },
	dash = { "swordslash", 1.5, 0.3 },
	cast = { "unsheath", 1.35, 0.35 },
	splat = { "splat", 1.4, 0.12 },
	boom = { "collide", 1, 0.32 },
	ult = { "bass", 0.7, 0.6 },
	hit = { "hit", 1.7, 0.3 },
	hurt = { "hit", 0.85, 0.45 },
	ping = { "electronicpingshort", 1.25, 0.35 },
	tick = { "electronicpingshort", 0.8, 0.3 },
	go = { "electronicpingshort", 1.6, 0.45 },
	click = { "button", 1.3, 0.25 },
	win = { "victory", 1, 0.45 },
	lose = { "bass", 0.55, 0.5 },
}
Sfx.last = {}

function Sfx.play(name)
	local def = Sfx.defs[name]
	if not SOUND_ON or not def then
		return
	end
	local t = os.clock()
	if Sfx.last[name] and t - Sfx.last[name] < 0.07 then
		return
	end
	Sfx.last[name] = t
	local sound = UI.new("Sound", {
		SoundId = "rbxasset://sounds/" .. def[1] .. ".mp3",
		PlaybackSpeed = def[2] * (0.96 + math.random() * 0.08),
		Volume = def[3],
	}, SoundService)
	sound:Play()
	task.delay(3, function()
		sound:Destroy()
	end)
end

---------------------------------------------------------------------------------------------------
-- Tiles: the floor. The server only says who owns each dot; colours and animation happen here.
---------------------------------------------------------------------------------------------------

Tiles.recs = {}        -- [part] = record
Tiles.anims = {}
Tiles.show = false     -- true between matches, when the floor plays patterns
Tiles.off = Color3.fromRGB(48, 52, 86)
Tiles.acc = 0
Tiles.folder = world:WaitForChild("Tiles")

function Tiles.color(rec)
	if rec.team > 0 then
		return teamColor(rec.team)
	end
	if rec.beacon then
		return Tiles.off:Lerp(C.white, 0.32)
	end
	return Tiles.off
end

function Tiles.animate(rec, delay)
	if #Tiles.anims > 500 then
		rec.part.Color = Tiles.color(rec)
		rec.part.Material = rec.team > 0 and NEON or SMOOTH
		return
	end
	table.insert(Tiles.anims, {
		rec = rec, from = rec.part.Color, to = Tiles.color(rec), t = -(delay or 0), neon = rec.team > 0,
	})
end

function Tiles.hook(part)
	if not part:IsA("BasePart") or Tiles.recs[part] then
		return
	end
	local p = part.Position
	local rec = {
		part = part, x = p.X, z = p.Z, d = math.sqrt(p.X * p.X + p.Z * p.Z), ang = math.atan2(p.Z, p.X),
		phase = math.random() * 6.28, size = part.Size,
		team = part:GetAttribute("T") or 0, beacon = part:GetAttribute("B") == true,
	}
	Tiles.recs[part] = rec
	part:GetAttributeChangedSignal("T"):Connect(function()
		rec.team = part:GetAttribute("T") or 0
		if not Tiles.show then
			Tiles.animate(rec)
		end
	end)
	part:GetAttributeChangedSignal("B"):Connect(function()
		rec.beacon = part:GetAttribute("B") == true
		if not Tiles.show then
			Tiles.animate(rec)
		end
	end)
	if Tiles.show then
		part.Material = NEON
	else
		part.Color = Tiles.color(rec)
		part.Material = rec.team > 0 and NEON or SMOOTH
	end
end

function Tiles.setShow(on)
	if Tiles.show == on then
		return
	end
	Tiles.show = on
	for _, a in ipairs(Tiles.anims) do
		if a.rec.part.Parent then
			a.rec.part.Size = a.rec.size
		end
	end
	Tiles.anims = {}
	for part, rec in pairs(Tiles.recs) do
		if on then
			part.Material = NEON
		else
			Tiles.animate(rec, rec.d / 220)   -- the real colours roll out from the centre
		end
	end
end

-- Generative patterns for the intermission. A different one every round.
function Tiles.pattern()
	local t = os.clock()
	local kind = (shared:GetAttribute("Round") or 0) % 4
	local a, b = teamColor(1), teamColor(2)
	for part, rec in pairs(Tiles.recs) do
		local color
		if kind == 0 then
			local v = math.max(0, math.sin(rec.d * 0.09 - t * 2.2))
			color = Color3.fromHSV(0.6 + 0.1 * math.sin(rec.d * 0.02 + t * 0.3), 0.6, 0.2 + 0.8 * v * v)
		elseif kind == 1 then
			local v = math.sin(rec.x * 0.05 + t * 1.3) * math.cos(rec.z * 0.06 - t * 0.9)
			color = Color3.fromHSV(0.5 + 0.22 * v, 0.6, 0.25 + 0.75 * math.abs(v))
		elseif kind == 2 then
			local v = math.sin(rec.ang * 3 + rec.d * 0.07 - t * 2)
			color = Tiles.off:Lerp(v > 0 and a or b, math.abs(v))
		else
			local v = math.max(0, math.sin(t * 1.7 + rec.phase)) ^ 6
			color = Color3.fromHSV(0.72 + 0.14 * math.sin(rec.phase), 0.55, 0.22 + 0.78 * v)
		end
		part.Color = color
	end
end

function Tiles.update(dt)
	local anims = Tiles.anims
	local i = 1
	while i <= #anims do
		local a = anims[i]
		local part = a.rec.part
		a.t = a.t + dt
		local done = false
		if not part.Parent then
			done = true
		elseif a.t >= 0 then
			if not a.started then
				a.started = true
				part.Material = a.neon and NEON or SMOOTH
			end
			local k = a.t / 0.3
			local size = a.rec.size
			if k >= 1 then
				part.Color = a.to
				part.Size = size
				done = true
			else
				local pop = 1 + 0.4 * math.sin(k * math.pi)
				part.Color = a.from:Lerp(a.to, k)
				part.Size = Vector3.new(size.X, size.Y * pop, size.Z * pop)
			end
		end
		if done then
			anims[i] = anims[#anims]
			anims[#anims] = nil
		else
			i = i + 1
		end
	end
	Tiles.acc = Tiles.acc + dt
	if Tiles.acc >= 0.1 then
		Tiles.acc = 0
		if Tiles.show then
			Tiles.pattern()
		elseif phase() == "Results" then
			-- the finished painting twinkles while the results are up
			local n = 0
			for _, rec in pairs(Tiles.recs) do
				if rec.team > 0 and math.random() < 0.012 then
					Tiles.animate(rec)
					n = n + 1
					if n >= 8 then
						break
					end
				end
			end
		end
	end
end

function Tiles.init()
	local function readOff()
		local off = Tiles.folder:GetAttribute("Off")
		if typeof(off) == "Color3" then
			Tiles.off = off
		end
	end
	readOff()
	Tiles.folder:GetAttributeChangedSignal("Off"):Connect(readOff)
	Tiles.folder.ChildAdded:Connect(Tiles.hook)
	Tiles.folder.ChildRemoved:Connect(function(part)
		Tiles.recs[part] = nil
	end)
	for _, part in ipairs(Tiles.folder:GetChildren()) do
		Tiles.hook(part)
	end
	Tiles.setShow(phase() == "Intermission" or phase() == "Boot")
end

---------------------------------------------------------------------------------------------------
-- Effects: everything that flashes, flies or bursts
---------------------------------------------------------------------------------------------------

Fx.folder = UI.new("Folder", { Name = "NeonFx" }, workspace)
Fx.list = {}      -- running effects
Fx.bolts = {}     -- [id] = flying paint bolt
Fx.shake = 0

local function fxPart(shape, color, transparency, size)
	return UI.new("Part", {
		Shape = shape,
		Size = size or Vector3.new(1, 1, 1),
		Color = color,
		Material = NEON,
		Transparency = transparency or 0,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
	}, nil)
end

-- Runs step(part, k) every frame with k going 0 -> 1, then removes the part.
function Fx.run(part, dur, step, delay)
	table.insert(Fx.list, { part = part, t = -(delay or 0), dur = dur, step = step, on = false })
end

function Fx.disc(x, z, r0, r1, color, dur, y, alpha, delay)
	alpha = alpha or 0.35
	local part = fxPart(Enum.PartType.Cylinder, color, alpha, Vector3.new(0.2, r0 * 2, r0 * 2))
	part.CFrame = CFrame.new(x, y or (FLOOR + 0.6), z) * UPRIGHT
	Fx.run(part, dur, function(p, k)
		local r = r0 + (r1 - r0) * (1 - (1 - k) * (1 - k))
		p.Size = Vector3.new(0.2, r * 2, r * 2)
		p.Transparency = alpha + (1 - alpha) * k
	end, delay)
end

function Fx.orb(x, y, z, r0, r1, color, dur)
	local part = fxPart(Enum.PartType.Ball, color, 0.45, Vector3.new(r0 * 2, r0 * 2, r0 * 2))
	part.Position = Vector3.new(x, y, z)
	Fx.run(part, dur, function(p, k)
		local r = r0 + (r1 - r0) * (1 - (1 - k) * (1 - k))
		p.Size = Vector3.new(r * 2, r * 2, r * 2)
		p.Transparency = 0.45 + 0.55 * k
	end)
end

function Fx.line(x0, z0, x1, z1, width, color, dur, y)
	local a = Vector3.new(x0, y or (FLOOR + 2.4), z0)
	local b = Vector3.new(x1, y or (FLOOR + 2.4), z1)
	local length = (b - a).Magnitude
	if length < 0.1 then
		return
	end
	local part = fxPart(Enum.PartType.Block, color, 0.1, Vector3.new(width, width * 0.4, length))
	part.CFrame = CFrame.new((a + b) / 2, b)
	Fx.run(part, dur, function(p, k)
		p.Size = Vector3.new(width * (1 - k), width * 0.4 * (1 - k), length)
		p.Transparency = 0.1 + 0.9 * k
	end)
end

function Fx.sparks(x, y, z, color, count)
	local anchor = fxPart(Enum.PartType.Block, color, 1, Vector3.new(0.4, 0.4, 0.4))
	anchor.Position = Vector3.new(x, y, z)
	local emitter = UI.new("ParticleEmitter", {
		Enabled = false,
		Color = ColorSequence.new(color),
		LightEmission = 1,
		Lifetime = NumberRange.new(0.3, 0.7),
		Speed = NumberRange.new(12, 30),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 3,
		Acceleration = Vector3.new(0, -40, 0),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) }),
	}, anchor)
	anchor.Parent = Fx.folder
	emitter:Emit(count)
	task.delay(1.2, function()
		anchor:Destroy()
	end)
end

function Fx.number(x, y, z, text, color, size)
	local anchor = fxPart(Enum.PartType.Block, color, 1, Vector3.new(0.2, 0.2, 0.2))
	anchor.Position = Vector3.new(x + (math.random() - 0.5) * 2, y + 2, z + (math.random() - 0.5) * 2)
	local gui = UI.new("BillboardGui", {
		Size = UDim2.new(0, 90, 0, 30),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 400,
	}, anchor)
	local label = UI.new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Font = BLACK,
		TextSize = size,
		TextColor3 = color,
		TextStrokeTransparency = 0.2,
		Text = text,
	}, gui)
	Fx.run(anchor, 0.7, function(_, k)
		gui.StudsOffset = Vector3.new(0, k * 3, 0)
		label.TextTransparency = k * k
		label.TextStrokeTransparency = 0.2 + 0.8 * k
	end)
end

-- how far something is from where the camera is looking, to decide if it should be heard or felt
function Fx.distance(x, z)
	local f = Cam.focus
	return math.sqrt((x - f.X) ^ 2 + (z - f.Z) ^ 2)
end

function Fx.fighterPos(fid)
	for _, p in ipairs(Players:GetPlayers()) do
		if p:GetAttribute("FID") == fid then
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				return root.Position
			end
		end
	end
	for part, rec in pairs(BotView.recs) do
		if part:GetAttribute("FID") == fid then
			return rec.pos
		end
	end
	return nil
end

function Fx.boltStart(id, x, z, dx, dz, speed, range, team, kind)
	local size = kind == "pellet" and 0.9 or 1.3
	local part = fxPart(Enum.PartType.Cylinder, teamColor(team), 0, Vector3.new(size * 2.8, size, size))
	part.Parent = Fx.folder
	Fx.bolts[id] = { part = part, x = x, z = z, dx = dx, dz = dz, speed = speed, left = range, late = 0 }
end

function Fx.boltEnd(id, x, z, how, team, splash)
	local bolt = Fx.bolts[id]
	if bolt then
		bolt.part:Destroy()
		Fx.bolts[id] = nil
	end
	local color = teamColor(team)
	if how == 1 then
		Fx.disc(x, z, 1, splash * 0.75, color, 0.3)
	elseif how == 2 then
		Fx.disc(x, z, 0.5, splash * 0.6, color, 0.25)
	else
		Fx.disc(x, z, splash * 0.3, splash, color, 0.32)
	end
	if Fx.distance(x, z) < 60 then
		Sfx.play("splat")
	end
end

function Fx.lob(x0, z0, x1, z1, flight, team)
	local color = teamColor(team)
	local ball = fxPart(Enum.PartType.Ball, color, 0, Vector3.new(2.4, 2.4, 2.4))
	Fx.run(ball, flight, function(p, k)
		p.Position = Vector3.new(x0 + (x1 - x0) * k, FLOOR + 3 + math.sin(k * math.pi) * 20, z0 + (z1 - z0) * k)
	end)
	Fx.disc(x1, z1, 11, 11, color, flight, nil, 0.8)
end

function Fx.burst(x, z, radius, team, kind)
	local color = teamColor(team)
	local close = Fx.distance(x, z)
	if kind == "pickup" then
		Fx.disc(x, z, 1, radius, C.white, 0.3)
		Fx.sparks(x, FLOOR + 3, z, C.white, 10)
		if close < 70 then
			Sfx.play("ping")
		end
		return
	end
	Fx.disc(x, z, radius * 0.25, radius, color, 0.4)
	Fx.orb(x, FLOOR + 2, z, radius * 0.2, radius * 0.7, color, 0.32)
	Fx.sparks(x, FLOOR + 2, z, color, math.clamp(math.floor(radius), 6, 30))
	if kind == "ult" then
		Fx.disc(x, z, radius * 0.1, radius, C.white, 0.5, FLOOR + 0.8, 0.5, 0.08)
		Fx.disc(x, z, radius * 0.1, radius * 0.8, color, 0.6, FLOOR + 0.9, 0.3, 0.16)
		if close < 110 then
			Fx.shake = math.max(Fx.shake, 2.2)
			Sfx.play("ult")
			Sfx.play("boom")
		end
	elseif kind == "ko" then
		Fx.disc(x, z, 1, radius * 0.6, C.white, 0.3, FLOOR + 0.8, 0.4)
		if close < 80 then
			Fx.shake = math.max(Fx.shake, 1)
			Sfx.play("boom")
		end
	elseif kind == "fall" or kind == "overdrive" then
		if close < 60 then
			Sfx.play("splat")
		end
	elseif close < 80 then
		Fx.shake = math.max(Fx.shake, 0.5)
		Sfx.play("boom")
	end
end

function Fx.handle(kind, ...)
	local a, b, c, d, e, f, g, h, i = ...
	if kind == "bolt" then
		Fx.boltStart(a, b, c, d, e, f, g, h, i)
	elseif kind == "boltEnd" then
		Fx.boltEnd(a, b, c, d, e, f)
	elseif kind == "lob" then
		Fx.lob(a, b, c, d, e, f)
	elseif kind == "burst" then
		Fx.burst(a, b, c, d, e)
	elseif kind == "telegraph" then
		-- a, b = position, c = radius, d = team, e = seconds until it goes off
		Fx.disc(a, b, c, c, teamColor(d), e, nil, 0.8)
		Fx.disc(a, b, 0.5, c, teamColor(d), e, FLOOR + 0.7, 0.55)
		Fx.sparks(a, FLOOR + 3, b, teamColor(d), 16)
	elseif kind == "charge" then
		local pos = Fx.fighterPos(a)
		if pos then
			Fx.orb(pos.X, FLOOR + 3, pos.Z, 0.8, 3.6, teamColor(c), b)
		end
	elseif kind == "beam" then
		Fx.line(a, b, c, d, 3.6, teamColor(e), 0.42)
		Fx.line(a, b, c, d, 1.3, C.white, 0.26, FLOOR + 2.6)
		Fx.sparks(c, FLOOR + 2.4, d, teamColor(e), 14)
		if Fx.distance(a, b) < 90 then
			Fx.shake = math.max(Fx.shake, 0.6)
			Sfx.play("boom")
		end
	elseif kind == "dash" then
		Fx.line(a, b, a + c * 16, b + d * 16, 1.8, teamColor(e), 0.3)
	elseif kind == "hit" then
		-- a, b, c = position, d = amount, e = attacker id, f = victim id
		local mine = e == player:GetAttribute("FID")
		local onMe = f == player:GetAttribute("FID")
		Fx.sparks(a, b, c, C.white, 5)
		if mine then
			Fx.number(a, b, c, tostring(d), C.gold, 22)
			Sfx.play("hit")
		elseif onMe then
			Fx.number(a, b, c, tostring(d), C.bad, 20)
		else
			Fx.number(a, b, c, tostring(d), C.muted, 13)
		end
	elseif kind == "block" then
		Fx.disc(a, b, 2, 5.5, C.white, 0.25, FLOOR + 3, 0.3)
	elseif kind == "heal" then
		Fx.orb(a, FLOOR + 4, b, 0.6, 1.7, C.good, 0.5)
	end
end

function Fx.update(dt)
	local list = Fx.list
	local i = 1
	while i <= #list do
		local a = list[i]
		a.t = a.t + dt
		local done = false
		if a.t >= 0 then
			if not a.on then
				a.on = true
				a.part.Parent = Fx.folder
			end
			local k = math.min(1, a.t / a.dur)
			a.step(a.part, k)
			done = k >= 1
		end
		if done then
			a.part:Destroy()
			list[i] = list[#list]
			list[#list] = nil
		else
			i = i + 1
		end
	end
	for id, bolt in pairs(Fx.bolts) do
		local step = math.min(bolt.left, bolt.speed * dt)
		bolt.x, bolt.z, bolt.left = bolt.x + bolt.dx * step, bolt.z + bolt.dz * step, bolt.left - step
		local pos = Vector3.new(bolt.x, FLOOR + 2.6, bolt.z)
		bolt.part.CFrame = CFrame.new(pos, pos + Vector3.new(bolt.dx, 0, bolt.dz)) * CFrame.Angles(0, math.rad(90), 0)
		if bolt.left <= 0 then
			-- the server normally says when a bolt ends; this is only a safety net
			bolt.late = bolt.late + dt
			if bolt.late > 0.4 then
				bolt.part:Destroy()
				Fx.bolts[id] = nil
			end
		end
	end
	Fx.shake = math.max(0, Fx.shake - dt * 4)
end

---------------------------------------------------------------------------------------------------
-- Bot bodies. The server moves an invisible ball; a smooth, livelier body is drawn here.
---------------------------------------------------------------------------------------------------

BotView.recs = {}
BotView.bubbles = {}   -- [player] = shield bubble part
BotView.folder = world:WaitForChild("Bots")

local function bodyPiece(size, color, material)
	return UI.new("Part", {
		Shape = Enum.PartType.Ball,
		Size = size,
		Color = color,
		Material = material,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
	}, Fx.folder)
end

function BotView.hook(part)
	if not part:IsA("BasePart") or BotView.recs[part] then
		return
	end
	local color = teamColor(part:GetAttribute("Team"))
	local rec = {
		part = part,
		pos = part.Position,
		face = Vector3.new(0, 0, -1),
		phase = math.random() * 6,
		body = bodyPiece(Vector3.new(3.6, 3.6, 3.6), color, NEON),
		cap = bodyPiece(Vector3.new(1.5, 1.5, 1.5), C.white, NEON),
		eyeL = bodyPiece(Vector3.new(0.8, 0.8, 0.8), C.ink, SMOOTH),
		eyeR = bodyPiece(Vector3.new(0.8, 0.8, 0.8), C.ink, SMOOTH),
		bubble = bodyPiece(Vector3.new(6.2, 6.2, 6.2), color, Enum.Material.ForceField),
	}
	part.LocalTransparencyModifier = 1
	local plate = part:FindFirstChild("Plate")
	if plate and plate:IsA("BillboardGui") then
		plate.Adornee = rec.body
	end
	BotView.recs[part] = rec
end

function BotView.unhook(part)
	local rec = BotView.recs[part]
	if rec then
		BotView.recs[part] = nil
		rec.body:Destroy()
		rec.cap:Destroy()
		rec.eyeL:Destroy()
		rec.eyeR:Destroy()
		rec.bubble:Destroy()
	end
end

function BotView.update(dt)
	local t = serverNow()
	local clock = os.clock()
	for part, rec in pairs(BotView.recs) do
		if not part.Parent then
			BotView.unhook(part)
		else
			local shown = part:GetAttribute("Alive") == true
			local delta = part.Position - rec.pos
			if delta.Magnitude > 22 then
				rec.pos = part.Position
			else
				rec.pos = rec.pos + delta * (1 - math.exp(-dt * 16))
			end
			local flat = Vector3.new(delta.X, 0, delta.Z)
			if flat.Magnitude > 0.15 then
				local turned = rec.face:Lerp(flat.Unit, math.min(1, dt * 10))
				if turned.Magnitude > 0.05 then
					rec.face = turned.Unit
				end
			end
			local bob = math.sin(clock * 10 + rec.phase) * 0.22 * math.min(1, flat.Magnitude * 2)
			local at = rec.pos + Vector3.new(0, bob, 0)
			local cf = CFrame.new(at, at + rec.face)
			local hidden = shown and 0 or 1
			rec.body.CFrame = cf
			rec.body.Transparency = hidden
			rec.cap.CFrame = cf * CFrame.new(0, 1.5, 0)
			rec.cap.Transparency = hidden
			rec.eyeL.CFrame = cf * CFrame.new(-0.62, 0.35, -1.5)
			rec.eyeL.Transparency = hidden
			rec.eyeR.CFrame = cf * CFrame.new(0.62, 0.35, -1.5)
			rec.eyeR.Transparency = hidden
			local safe = shown and (t < (part:GetAttribute("ShieldT") or 0) or t < (part:GetAttribute("SafeT") or 0))
			rec.bubble.CFrame = cf
			rec.bubble.Transparency = safe and 0 or 1
		end
	end
	-- shield bubbles around human players
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local on = root ~= nil and t < (p:GetAttribute("ShieldT") or 0)
		local bubble = BotView.bubbles[p]
		if on then
			if not bubble then
				bubble = bodyPiece(Vector3.new(8, 8, 8), teamColor(p:GetAttribute("Team")), Enum.Material.ForceField)
				BotView.bubbles[p] = bubble
			end
			bubble.Position = root.Position
			bubble.Transparency = 0
		elseif bubble then
			bubble.Transparency = 1
		end
	end
end

function BotView.init()
	BotView.folder.ChildAdded:Connect(BotView.hook)
	BotView.folder.ChildRemoved:Connect(BotView.unhook)
	for _, part in ipairs(BotView.folder:GetChildren()) do
		BotView.hook(part)
	end
	Players.PlayerRemoving:Connect(function(p)
		local bubble = BotView.bubbles[p]
		if bubble then
			bubble:Destroy()
			BotView.bubbles[p] = nil
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Camera: fixed angle from above, so the painted floor is always in view
---------------------------------------------------------------------------------------------------

Cam.dist = 96
Cam.focus = Vector3.new(0, FLOOR + 18, 0)
Cam.eye = Vector3.new(0, FLOOR + 90, 46)
Cam.target = nil

function Cam.update(dt)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local wantFocus, wantEye
	if phase() == "Results" then
		-- gallery view: the finished painting from straight above, slowly turning
		local a = os.clock() * 0.12
		wantFocus = Vector3.new(0, FLOOR, 0)
		wantEye = Vector3.new(math.sin(a) * 40, FLOOR + 205, math.cos(a) * 40)
	else
		if alive() then
			Cam.target = me.root.Position
		end
		local tgt = Cam.target or Vector3.new(0, FLOOR + 21, 0)
		wantFocus = Vector3.new(tgt.X, math.max(FLOOR - 4, tgt.Y - 3), tgt.Z)
		wantEye = wantFocus + Vector3.new(0, 0.848 * Cam.dist, 0.53 * Cam.dist)
	end
	local k = 1 - math.exp(-math.min(dt, 0.1) * 9)
	Cam.focus = Cam.focus:Lerp(wantFocus, k)
	Cam.eye = Cam.eye:Lerp(wantEye, k)
	local eye, focus = Cam.eye, Cam.focus
	if Fx.shake > 0.01 then
		local jolt = Vector3.new((math.random() - 0.5) * Fx.shake, (math.random() - 0.5) * Fx.shake, 0)
		eye, focus = eye + jolt, focus + jolt
	end
	camera.CFrame = CFrame.new(eye, focus)
	camera.Focus = CFrame.new(focus)
	camera.FieldOfView = 50
end

---------------------------------------------------------------------------------------------------
-- Input: aiming and actions
---------------------------------------------------------------------------------------------------

Input.firing = false
Input.cool = { primary = 0, dash = 0, a1 = 0, a2 = 0 }   -- os.clock() time when each is ready again

function Input.device()
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "touch"
	elseif last == Enum.UserInputType.Gamepad1 then
		return "pad"
	elseif UserInputService.MouseEnabled then
		return "mouse"
	end
	return "touch"
end

-- positions of every living enemy
function Input.enemies()
	local list = {}
	local team = myTeam()
	for _, p in ipairs(Players:GetPlayers()) do
		local theirs = p:GetAttribute("Team") or 0
		if p ~= player and theirs > 0 and theirs ~= team then
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 then
				table.insert(list, root.Position)
			end
		end
	end
	for part in pairs(BotView.recs) do
		if part:GetAttribute("Alive") == true and part:GetAttribute("Team") ~= team then
			table.insert(list, part.Position)
		end
	end
	return list
end

-- Where the player is aiming on the floor. With a mouse it is the cursor; on touch and gamepad
-- it snaps to the nearest enemy, or straight ahead when nobody is close.
function Input.aim()
	local root = me.root
	local pos = root.Position
	local camera = workspace.CurrentCamera
	if camera and Input.device() == "mouse" then
		local m = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(m.X, m.Y)
		if ray.Direction.Y < -0.02 then
			local hit = ray.Origin + ray.Direction * ((FLOOR + 0.3 - ray.Origin.Y) / ray.Direction.Y)
			return hit.X, hit.Z
		end
	end
	local best, bestD = nil, 82
	for _, p in ipairs(Input.enemies()) do
		local d = math.sqrt((p.X - pos.X) ^ 2 + (p.Z - pos.Z) ^ 2)
		if d < bestD then
			best, bestD = p, d
		end
	end
	if best then
		return best.X, best.Z
	end
	local look = root.CFrame.LookVector
	return pos.X + look.X * 40, pos.Z + look.Z * 40
end

function Input.dash(root, dir)
	local attachment = UI.new("Attachment", {}, root)
	local mover = UI.new("LinearVelocity", {
		Attachment0 = attachment,
		MaxForce = 1e7,
		VectorVelocity = dir * 95,
		RelativeTo = Enum.ActuatorRelativeTo.World,
	}, root)
	task.delay(0.17, function()
		mover:Destroy()
		attachment:Destroy()
		if root.Parent then
			root.AssemblyLinearVelocity = dir * CONFIG.walk
		end
	end)
end

function Input.act(action)
	if phase() ~= "Playing" or myTeam() == 0 or not alive() then
		return
	end
	local t = os.clock()
	if action == "ult" then
		if (player:GetAttribute("Ult") or 0) < 100 then
			return
		end
	elseif t < Input.cool[action] then
		return
	end
	local root = me.root
	local ax, az = Input.aim()
	if action == "primary" then
		local id = player:GetAttribute("Primary") or "bolt"
		local def = CONFIG.primaries[id] or CONFIG.primaries.bolt
		Input.cool.primary = t + def.cd
		Sfx.play(id == "scatter" and "pellets" or (id == "lob" and "lob" or "fire"))
	elseif action == "dash" then
		local move = me.hum.MoveDirection
		local dir = Vector3.new(move.X, 0, move.Z)
		if dir.Magnitude < 0.1 then
			dir = Vector3.new(ax - root.Position.X, 0, az - root.Position.Z)
		end
		if dir.Magnitude < 0.1 then
			return
		end
		dir = dir.Unit
		Input.cool.dash = t + CONFIG.dash.cd
		Input.dash(root, dir)
		ax, az = root.Position.X + dir.X * 10, root.Position.Z + dir.Z * 10
		Sfx.play("dash")
	elseif action == "a1" or action == "a2" then
		local id = player:GetAttribute(action == "a1" and "A1" or "A2")
		local def = CONFIG.abilities[id]
		if not def then
			return
		end
		Input.cool[action] = t + def.cd
		Sfx.play("cast")
	else
		Sfx.play("cast")
	end
	actEvent:FireServer(action, ax, az)
end

function Input.update()
	if Input.firing then
		Input.act("primary")
	end
end

function Input.init()
	local K = Enum.KeyCode
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local key = input.KeyCode
		if input.UserInputType == Enum.UserInputType.MouseButton1 or key == K.ButtonR2 then
			Input.firing = true
		elseif key == K.Q or key == K.LeftShift or key == K.ButtonL2 then
			Input.act("dash")
		elseif key == K.E or key == K.ButtonX then
			Input.act("a1")
		elseif key == K.R or key == K.ButtonY then
			Input.act("a2")
		elseif key == K.F or key == K.ButtonR1 then
			Input.act("ult")
		elseif key == K.M then
			Menu.toggle()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == K.ButtonR2 then
			Input.firing = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if not processed and input.UserInputType == Enum.UserInputType.MouseWheel then
			Cam.dist = math.clamp(Cam.dist - input.Position.Z * 7, 60, 128)
		end
	end)
	hurtEvent.OnClientEvent:Connect(function(kx, kup, kz, amount)
		if type(kx) ~= "number" or type(kup) ~= "number" or type(kz) ~= "number" then
			return
		end
		if alive() and (math.abs(kx) + math.abs(kz) + kup) > 1 then
			local v = me.root.AssemblyLinearVelocity
			me.root.AssemblyLinearVelocity = Vector3.new(kx, math.max(v.Y, kup), kz)
		end
		Hud.flash = 1
		Fx.shake = math.max(Fx.shake, 0.6)
		Sfx.play("hurt")
	end)
end

---------------------------------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------------------------------

Hud.flash = 0
Hud.phase = nil
Hud.lastCount = nil
Hud.fa, Hud.fb = 0, 0
Hud.feed = {}
Hud.slots = {}
Hud.ann = { t = 99, hold = 1 }

local SLOT_KEYS = { primary = "LMB", dash = "SHIFT", a1 = "E", a2 = "R", ult = "F" }

-- One ability button. Used both for the bar at the bottom and for the touch buttons.
function Hud.slot(parent, action, size, props, touch)
	props.Size = UDim2.new(0, size, 0, size)
	props.AutoButtonColor = false
	props.Text = ""
	props.BorderSizePixel = 0
	props.BackgroundColor3 = C.ink
	props.BackgroundTransparency = touch and 0.3 or 0.14
	local button = UI.new("TextButton", props, parent)
	if touch then
		UI.round(button)
	else
		UI.corner(button, 16)
	end
	local border = UI.stroke(button)
	local fill = UI.frame(button, {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = C.gold, BackgroundTransparency = 0.72,
	})
	if touch then
		UI.round(fill)
	else
		UI.corner(fill, 16)
	end
	local icon = UI.frame(button, {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, touch and 0.5 or 0.42, 0),
		Size = UDim2.new(0.46, 0, 0.46, 0),
	})
	local name = UI.label(button, "", 9, BOLD, C.muted, {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -5), Size = UDim2.new(1, -4, 0, 11),
		TextXAlignment = CENTER, Visible = not touch,
	})
	local shade = UI.frame(button, {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.45,
	})
	if touch then
		UI.round(shade)
	else
		UI.corner(shade, 16)
	end
	local count = UI.label(button, "", touch and 20 or 22, BLACK, C.text, {
		Size = UDim2.new(1, 0, 1, 0), TextXAlignment = CENTER, TextStrokeTransparency = 0.5,
	})
	if not touch then
		local chip = UI.frame(button, {
			Position = UDim2.new(0, -6, 0, -8), Size = UDim2.new(0, #SLOT_KEYS[action] * 7 + 12, 0, 18),
			BackgroundColor3 = C.card, BackgroundTransparency = 0,
		})
		UI.round(chip)
		UI.stroke(chip)
		UI.label(chip, SLOT_KEYS[action], 10, BOLD, C.text, { Size = UDim2.new(1, 0, 1, 0), TextXAlignment = CENTER })
	end
	local slot = { action = action, button = button, border = border, fill = fill, icon = icon, name = name,
		shade = shade, count = count, kind = nil }
	table.insert(Hud.slots, slot)
	if action == "primary" then
		button.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
				Input.firing = true
			end
		end)
		button.InputEnded:Connect(function(input)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
				Input.firing = false
			end
		end)
	else
		button.Activated:Connect(function()
			Input.act(action)
		end)
	end
	return slot
end

function Hud.build()
	local gui = UI.new("ScreenGui", {
		Name = "NeonCanvasHud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)
	Hud.gui = gui
	Hud.scale = UI.new("UIScale", { Scale = 1 }, gui)

	-- hurt flash sits behind everything else
	Hud.flashFrame = UI.frame(gui, {
		Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.bad, BackgroundTransparency = 1, Active = false,
	})

	-- scoreboard, top centre
	local board = UI.panel(gui, {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10), Size = UDim2.new(0, 540, 0, 78),
	})
	Hud.nameA = UI.label(board, "", 12, BOLD, teamColor(1), { Position = UDim2.new(0, 20, 0, 9), Size = UDim2.new(0, 180, 0, 14) })
	Hud.scoreA = UI.label(board, "0", 28, BLACK, C.text, { Position = UDim2.new(0, 20, 0, 23), Size = UDim2.new(0, 180, 0, 32) })
	Hud.nameB = UI.label(board, "", 12, BOLD, teamColor(2), {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 9), Size = UDim2.new(0, 180, 0, 14),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	Hud.scoreB = UI.label(board, "0", 28, BLACK, C.text, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 23), Size = UDim2.new(0, 180, 0, 32),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	Hud.chip = UI.frame(board, {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 9), Size = UDim2.new(0, 104, 0, 36),
		BackgroundColor3 = C.card,
	})
	UI.corner(Hud.chip, 12)
	Hud.timer = UI.label(Hud.chip, "0:00", 22, BLACK, C.text, { Size = UDim2.new(1, 0, 1, 0), TextXAlignment = CENTER })
	Hud.modeText = UI.label(board, "", 10, BOLD, C.muted, {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 47), Size = UDim2.new(0, 200, 0, 12),
		TextXAlignment = CENTER,
	})
	local track = UI.frame(board, {
		Position = UDim2.new(0, 20, 0, 63), Size = UDim2.new(1, -40, 0, 6), BackgroundColor3 = C.card,
	})
	UI.round(track)
	Hud.fillA = UI.frame(track, { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = teamColor(1) })
	UI.round(Hud.fillA)
	Hud.fillB = UI.frame(track, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = teamColor(2),
	})
	UI.round(Hud.fillB)
	Hud.goal = UI.label(gui, "", 13, MEDIUM, C.text, {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 94), Size = UDim2.new(0, 520, 0, 20),
		TextXAlignment = CENTER, TextStrokeTransparency = 0.55,
	})

	-- announcements, upper middle
	Hud.annTitle = UI.label(gui, "", 46, BLACK, C.text, {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.27, 0), Size = UDim2.new(1, 0, 0, 56),
		TextXAlignment = CENTER, TextTransparency = 1, TextStrokeTransparency = 1,
	})
	Hud.annSub = UI.label(gui, "", 18, MEDIUM, C.text, {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.27, 40), Size = UDim2.new(1, 0, 0, 24),
		TextXAlignment = CENTER, TextTransparency = 1, TextStrokeTransparency = 1,
	})

	-- knock-out feed, top right
	Hud.feedBox = UI.frame(gui, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 56), Size = UDim2.new(0, 340, 0, 200),
	})
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, Hud.feedBox)

	local menuButton = UI.button(gui, "MENU  [M]", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 12), Size = UDim2.new(0, 104, 0, 34),
		BackgroundColor3 = C.ink, BackgroundTransparency = 0.14,
	})
	menuButton.Activated:Connect(function()
		Menu.toggle()
	end)

	-- player card, bottom left
	local card = UI.panel(gui, {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -18), Size = UDim2.new(0, 262, 0, 70),
	})
	Hud.card = card
	UI.label(card, player.DisplayName, 14, BOLD, C.text, {
		Position = UDim2.new(0, 16, 0, 9), Size = UDim2.new(1, -96, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local lvl = UI.frame(card, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 9), Size = UDim2.new(0, 58, 0, 18),
		BackgroundColor3 = C.card,
	})
	UI.round(lvl)
	Hud.lvl = UI.label(lvl, "LV 1", 10, BOLD, C.gold, { Size = UDim2.new(1, 0, 1, 0), TextXAlignment = CENTER })
	local hpTrack = UI.frame(card, { Position = UDim2.new(0, 16, 0, 33), Size = UDim2.new(1, -32, 0, 14), BackgroundColor3 = C.card })
	UI.round(hpTrack)
	Hud.hpFill = UI.frame(hpTrack, { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.good })
	UI.round(Hud.hpFill)
	Hud.hpText = UI.label(hpTrack, "100", 10, BOLD, C.text, {
		Size = UDim2.new(1, 0, 1, 0), TextXAlignment = CENTER, TextStrokeTransparency = 0.6,
	})
	local xpTrack = UI.frame(card, { Position = UDim2.new(0, 16, 0, 54), Size = UDim2.new(1, -32, 0, 4), BackgroundColor3 = C.card })
	UI.round(xpTrack)
	Hud.xpFill = UI.frame(xpTrack, { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.gold })
	UI.round(Hud.xpFill)
	Hud.buffs = UI.label(gui, "", 12, BOLD, C.gold, {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 20, 1, -94), Size = UDim2.new(0, 400, 0, 16),
		TextStrokeTransparency = 0.5,
	})

	-- ability bar, bottom centre (keyboard and gamepad)
	Hud.bar = UI.frame(gui, {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -22), Size = UDim2.new(0, 390, 0, 70),
	})
	local order = { "primary", "dash", "a1", "a2", "ult" }
	for i, action in ipairs(order) do
		Hud.slot(Hud.bar, action, 70, { Position = UDim2.new(0, (i - 1) * 80, 0, 0) }, false)
	end

	-- knocked-out notice
	Hud.down = UI.panel(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.62, 0), Size = UDim2.new(0, 320, 0, 76),
		Visible = false,
	})
	UI.label(Hud.down, "KNOCKED OUT", 20, BLACK, C.bad, { Position = UDim2.new(0, 0, 0, 12), Size = UDim2.new(1, 0, 0, 24), TextXAlignment = CENTER })
	Hud.downText = UI.label(Hud.down, "", 13, MEDIUM, C.text, { Position = UDim2.new(0, 0, 0, 42), Size = UDim2.new(1, 0, 0, 18), TextXAlignment = CENTER })

	-- Touch buttons sit in their own layer, finger sized, hugging Roblox's jump button
	-- (bottom right: 70 px on phones, 120 px on tablets).
	if UserInputService.TouchEnabled then
		local touch = UI.new("ScreenGui", {
			Name = "NeonCanvasTouch", ResetOnSpawn = false, DisplayOrder = 6, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, playerGui)
		Hud.touch = touch
		Hud.touchScale = UI.new("UIScale", { Scale = 1 }, touch)
		local a = Vector2.new(1, 1)
		Hud.slot(touch, "primary", 84, { AnchorPoint = a, Position = UDim2.new(1, -110, 1, -18) }, true)
		Hud.slot(touch, "dash", 58, { AnchorPoint = a, Position = UDim2.new(1, -206, 1, -24) }, true)
		Hud.slot(touch, "a1", 56, { AnchorPoint = a, Position = UDim2.new(1, -178, 1, -112) }, true)
		Hud.slot(touch, "a2", 56, { AnchorPoint = a, Position = UDim2.new(1, -108, 1, -118) }, true)
		Hud.slot(touch, "ult", 56, { AnchorPoint = a, Position = UDim2.new(1, -32, 1, -106) }, true)
		-- the thumbstick lives bottom left, so the player card moves up out of its way
		Hud.card.AnchorPoint = Vector2.new(0, 0)
		Hud.card.Position = UDim2.new(0, 16, 0, 60)
		Hud.buffs.AnchorPoint = Vector2.new(0, 0)
		Hud.buffs.Position = UDim2.new(0, 20, 0, 136)
	end
end

function Hud.announce(title, sub, hold, color)
	Hud.annTitle.Text = title
	Hud.annSub.Text = sub or ""
	Hud.annTitle.TextColor3 = color or C.text
	Hud.ann.t = 0
	Hud.ann.hold = hold or 1.6
end

function Hud.addFeed(richText)
	local row = UI.frame(Hud.feedBox, {
		Size = UDim2.new(0, 320, 0, 26), BackgroundColor3 = C.ink, BackgroundTransparency = 0.2,
		LayoutOrder = #Hud.feed + math.floor(os.clock() * 10),
	})
	UI.round(row)
	local label = UI.label(row, richText, 12, MEDIUM, C.text, {
		Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -24, 1, 0), RichText = true,
		TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd,
	})
	table.insert(Hud.feed, { row = row, label = label, t = 0 })
	if #Hud.feed > 5 then
		Hud.feed[1].row:Destroy()
		table.remove(Hud.feed, 1)
	end
end

local function named(name, team)
	return '<font color="' .. hex(teamColor(team)) .. '"><b>' .. escape(tostring(name)) .. "</b></font>"
end

function Hud.onFeed(kind, a, b, c, d, e, f)
	if kind == "ko" then
		-- a, b = killer name and team; c, d = victim name and team; e, f = their ids
		Hud.addFeed(named(a, b) .. "  knocked out  " .. named(c, d))
		local mine = player:GetAttribute("FID")
		if e == mine then
			Hud.announce("KNOCK-OUT", tostring(c) .. " is down", 1.1, C.gold)
			Sfx.play("go")
		elseif f == mine then
			me.killer = tostring(a)
		end
	elseif kind == "fell" then
		Hud.addFeed(named(a, b) .. "  fell off the canvas")
		if c == player:GetAttribute("FID") then
			me.killer = nil
		end
	elseif kind == "streak" then
		Hud.addFeed(named(a, b) .. "  is on a " .. tostring(c) .. " knock-out streak")
	elseif kind == "ult" then
		Hud.addFeed(named(a, b) .. "  unleashed " .. CONFIG.ult.name)
	elseif kind == "pickup" then
		Hud.addFeed(named(a, b) .. "  grabbed " .. string.upper(tostring(c)))
	elseif kind == "start" then
		local mode = CONFIG.modes[a]
		Hud.announce("PAINT!", mode and mode.goal or "", 1.8, C.gold)
		Sfx.play("go")
	elseif kind == "rush" then
		Hud.announce("FINAL RUSH", "Everything counts double", 2.2, C.gold)
		Sfx.play("go")
	end
end

function Hud.refreshLoadout()
	local ids = {
		primary = player:GetAttribute("Primary") or "bolt",
		dash = "dash",
		a1 = player:GetAttribute("A1") or "nova",
		a2 = player:GetAttribute("A2") or "shield",
		ult = "ult",
	}
	for _, slot in ipairs(Hud.slots) do
		local id = ids[slot.action]
		if slot.kind ~= id then
			slot.kind = id
			local def = CONFIG.primaries[id] or CONFIG.abilities[id]
			if slot.action ~= "ult" then
				slot.name.Text = string.upper(def and def.name or CONFIG.dash.name)
			end
			UI.icon(slot.icon, id, slot.action == "ult" and C.gold or C.text)
		end
	end
end

function Hud.onPhase(now, before)
	if now == "Intermission" or now == "Boot" then
		Tiles.setShow(true)
		Results.hide()
		if not Menu.seen then
			Menu.seen = true
			Menu.open()
		end
	else
		Tiles.setShow(false)
	end
	if now == "Countdown" then
		Menu.close()
		Results.hide()
		Input.cool = { primary = 0, dash = 0, a1 = 0, a2 = 0 }
		Hud.lastCount = nil
	elseif now == "Results" then
		Input.firing = false
	end
	if before == "Results" then
		Results.hide()
	end
end

function Hud.update(dt)
	local ph = phase()
	if ph ~= Hud.phase then
		local before = Hud.phase
		Hud.phase = ph
		Hud.onPhase(ph, before)
	end
	local camera = workspace.CurrentCamera
	if camera then
		local size = camera.ViewportSize
		Hud.scale.Scale = math.clamp(size.Y / 760, 0.62, 1.3)
		if Hud.touchScale then
			Hud.touchScale.Scale = math.min(size.X, size.Y) > 500 and 1.6 or 1
		end
	end

	local team = myTeam()
	local mode = shared:GetAttribute("Mode") or "Turf"
	local modeDef = CONFIG.modes[mode] or CONFIG.modes.Turf
	local left = math.max(0, (shared:GetAttribute("EndsAt") or 0) - serverNow())
	local rush = shared:GetAttribute("Rush") == true and ph == "Playing"
	Hud.timer.Text = string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60))
	Hud.timer.TextColor3 = rush and C.gold or C.text
	Hud.modeText.Text = modeDef.name
	Hud.nameA.Text = CONFIG.teamNames[1] .. (team == 1 and "  ·  YOU" or "")
	Hud.nameB.Text = (team == 2 and "YOU  ·  " or "") .. CONFIG.teamNames[2]

	-- scores
	local a, b = shared:GetAttribute("ScoreA") or 0, shared:GetAttribute("ScoreB") or 0
	local wantA, wantB = 0, 0
	if ph == "Intermission" or ph == "Boot" then
		Hud.scoreA.Text, Hud.scoreB.Text = "-", "-"
		Hud.goal.Text = "NEXT UP  ·  " .. modeDef.name .. "  on  " .. tostring(shared:GetAttribute("MapName") or "")
		Hud.goal.TextColor3 = C.text
	else
		if mode == "Turf" then
			local total = math.max(1, shared:GetAttribute("Total") or 1)
			wantA, wantB = a / total, b / total
			Hud.scoreA.Text = tostring(math.floor(wantA * 100 + 0.5)) .. "%"
			Hud.scoreB.Text = tostring(math.floor(wantB * 100 + 0.5)) .. "%"
		else
			local goal = math.max(1, shared:GetAttribute("Goal") or 1)
			wantA, wantB = math.min(1, a / goal) * 0.5, math.min(1, b / goal) * 0.5
			Hud.scoreA.Text, Hud.scoreB.Text = tostring(a), tostring(b)
		end
		if rush then
			Hud.goal.Text = "FINAL RUSH  ·  everything counts double"
			Hud.goal.TextColor3 = C.gold
		elseif ph == "Results" then
			Hud.goal.Text = "MATCH OVER"
			Hud.goal.TextColor3 = C.text
		else
			Hud.goal.Text = modeDef.goal .. "  ·  " .. tostring(shared:GetAttribute("MapName") or "")
			Hud.goal.TextColor3 = C.text
		end
	end
	local ease = 1 - math.exp(-dt * 8)
	Hud.fa = Hud.fa + (wantA - Hud.fa) * ease
	Hud.fb = Hud.fb + (wantB - Hud.fb) * ease
	Hud.fillA.Size = UDim2.new(Hud.fa, 0, 1, 0)
	Hud.fillB.Size = UDim2.new(Hud.fb, 0, 1, 0)

	-- countdown numbers
	if ph == "Countdown" then
		local n = math.ceil(left)
		if n ~= Hud.lastCount and n >= 1 and n <= 3 then
			Hud.lastCount = n
			Hud.announce(tostring(n), team > 0 and ("You are on " .. CONFIG.teamNames[team]) or "", 0.8, teamColor(team))
			Sfx.play("tick")
		end
	end

	-- announcement fade
	local ann = Hud.ann
	if ann.t < ann.hold + 0.4 then
		ann.t = ann.t + dt
		local alpha
		if ann.t < 0.12 then
			alpha = 1 - ann.t / 0.12
		elseif ann.t < ann.hold then
			alpha = 0
		else
			alpha = math.min(1, (ann.t - ann.hold) / 0.4)
		end
		Hud.annTitle.TextTransparency = alpha
		Hud.annTitle.TextStrokeTransparency = 0.4 + 0.6 * alpha
		Hud.annSub.TextTransparency = alpha
		Hud.annSub.TextStrokeTransparency = 0.5 + 0.5 * alpha
	end

	-- feed fade
	local i = 1
	while i <= #Hud.feed do
		local entry = Hud.feed[i]
		entry.t = entry.t + dt
		if entry.t > 5.5 then
			entry.row:Destroy()
			table.remove(Hud.feed, i)
		else
			local fade = math.clamp((entry.t - 4.7) / 0.8, 0, 1)
			entry.row.BackgroundTransparency = 0.2 + 0.8 * fade
			entry.label.TextTransparency = fade
			i = i + 1
		end
	end

	-- hurt flash
	if Hud.flash > 0 then
		Hud.flash = math.max(0, Hud.flash - dt * 3)
	end
	Hud.flashFrame.BackgroundTransparency = 1 - 0.3 * Hud.flash

	-- player card
	local hp, maxHp = 0, 100
	if alive() then
		hp, maxHp = me.hum.Health, math.max(1, me.hum.MaxHealth)
	end
	Hud.hpFill.Size = UDim2.new(math.clamp(hp / maxHp, 0, 1), 0, 1, 0)
	Hud.hpFill.BackgroundColor3 = hp / maxHp > 0.35 and C.good or C.bad
	Hud.hpText.Text = tostring(math.floor(hp + 0.5))
	Hud.lvl.Text = "LV " .. tostring(player:GetAttribute("Lvl") or 1)
	Hud.xpFill.Size = UDim2.new(math.clamp((player:GetAttribute("XP") or 0) / math.max(1, player:GetAttribute("XPNeed") or 1), 0, 1), 0, 1, 0)
	local t = serverNow()
	local buffs = {}
	for _, pair in ipairs({ { "ShieldT", "SHIELD" }, { "SurgeT", "SURGE" }, { "HasteT", "HASTE" }, { "OverT", "OVERDRIVE" } }) do
		local untilT = player:GetAttribute(pair[1]) or 0
		if untilT > t then
			table.insert(buffs, pair[2] .. " " .. tostring(math.ceil(untilT - t)) .. "s")
		end
	end
	Hud.buffs.Text = table.concat(buffs, "   ")

	-- ability buttons
	local inMatch = team > 0 and (ph == "Countdown" or ph == "Playing")
	Hud.bar.Visible = inMatch and Input.device() ~= "touch"
	if Hud.touch then
		Hud.touch.Enabled = inMatch and Input.device() == "touch"
	end
	Hud.refreshLoadout()
	local clock = os.clock()
	local ult = player:GetAttribute("Ult") or 0
	for _, slot in ipairs(Hud.slots) do
		if slot.action == "ult" then
			slot.fill.Size = UDim2.new(1, 0, math.clamp(ult / 100, 0, 1), 0)
			slot.name.Visible = true
			if ult >= 100 then
				slot.name.Text = "READY"
				slot.name.TextColor3 = C.gold
				slot.border.Color = C.gold
				slot.border.Transparency = 0.2 + 0.4 * math.abs(math.sin(clock * 5))
				slot.border.Thickness = 2
			else
				slot.name.Text = tostring(math.floor(ult)) .. "%"
				slot.name.TextColor3 = C.muted
				slot.border.Color = C.white
				slot.border.Transparency = 0.86
				slot.border.Thickness = 1
			end
		else
			local total = 1
			if slot.action == "dash" then
				total = CONFIG.dash.cd
			else
				local def = CONFIG.primaries[slot.kind] or CONFIG.abilities[slot.kind]
				total = def and def.cd or 1
			end
			local remaining = math.max(0, Input.cool[slot.action] - clock)
			slot.shade.Size = UDim2.new(1, 0, math.clamp(remaining / total, 0, 1), 0)
			slot.count.Text = remaining > 0.5 and tostring(math.ceil(remaining)) or ""
		end
	end

	-- knocked-out notice
	local down = inMatch and ph == "Playing" and not alive()
	Hud.down.Visible = down
	if down then
		local back = math.max(0, math.ceil(CONFIG.respawn - (os.clock() - me.diedAt)))
		Hud.downText.Text = (me.killer and ("by " .. me.killer .. "  ·  ") or "") .. "back in " .. tostring(back) .. "s"
	end
end

---------------------------------------------------------------------------------------------------
-- Menu: how to play, loadout, profile
---------------------------------------------------------------------------------------------------

Menu.seen = false
Menu.tab = "play"
Menu.cards = {}
Menu.nextSlot = "a1"
Menu.dirty = true

local function rankOf(rating)
	local current, nextRank = CONFIG.ranks[1], nil
	for i, rank in ipairs(CONFIG.ranks) do
		if rating >= rank.at then
			current = rank
			nextRank = CONFIG.ranks[i + 1]
		end
	end
	return current, nextRank
end

-- One selectable card for a primary or an ability.
function Menu.card(parent, slotKind, id, def, order)
	local button = UI.new("TextButton", {
		AutoButtonColor = false, Text = "", BorderSizePixel = 0, BackgroundColor3 = C.card, LayoutOrder = order,
		Size = UDim2.new(0, 166, 0, 84),
	}, parent)
	UI.corner(button, 14)
	local border = UI.stroke(button, C.white, 2, 1)
	local icon = UI.frame(button, { Position = UDim2.new(0, 12, 0, 12), Size = UDim2.new(0, 30, 0, 30) })
	UI.icon(icon, id, C.text)
	UI.label(button, def.name, 14, BOLD, C.text, { Position = UDim2.new(0, 52, 0, 10), Size = UDim2.new(1, -86, 0, 18) })
	UI.label(button, tostring(def.cd) .. "s", 10, BOLD, C.muted, { Position = UDim2.new(0, 52, 0, 28), Size = UDim2.new(1, -60, 0, 12) })
	UI.label(button, def.desc, 10, MEDIUM, C.muted, {
		Position = UDim2.new(0, 12, 0, 46), Size = UDim2.new(1, -24, 0, 32), TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local tag = UI.label(button, "", 10, BLACK, C.gold, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.new(0, 34, 0, 14),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local lock = UI.frame(button, {
		Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(20, 22, 40), BackgroundTransparency = 0.06, Visible = false,
	})
	UI.corner(lock, 14)
	UI.label(lock, def.name, 13, BOLD, C.muted, { Position = UDim2.new(0, 0, 0.5, -19), Size = UDim2.new(1, 0, 0, 18), TextXAlignment = CENTER })
	UI.label(lock, "UNLOCKS AT LEVEL " .. tostring(def.unlock), 10, BLACK, C.gold, {
		Position = UDim2.new(0, 0, 0.5, 2), Size = UDim2.new(1, 0, 0, 14), TextXAlignment = CENTER,
	})
	table.insert(Menu.cards, { slotKind = slotKind, id = id, def = def, border = border, tag = tag, lock = lock })
	button.Activated:Connect(function()
		Sfx.play("click")
		if (player:GetAttribute("Lvl") or 1) < def.unlock then
			return
		end
		if slotKind == "primary" then
			requestEvent:FireServer("loadout", "primary", id)
		elseif player:GetAttribute("A1") ~= id and player:GetAttribute("A2") ~= id then
			requestEvent:FireServer("loadout", Menu.nextSlot, id)
			Menu.nextSlot = Menu.nextSlot == "a1" and "a2" or "a1"
		end
	end)
end

function Menu.build()
	local gui = UI.new("ScreenGui", {
		Name = "NeonCanvasMenu", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 8, Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)
	Menu.gui = gui
	Menu.scale = UI.new("UIScale", { Scale = 1 }, gui)
	-- Active makes the backdrop swallow clicks, so choosing a card never fires a shot
	UI.frame(gui, { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.ink, BackgroundTransparency = 0.45, Active = true })
	local panel = UI.panel(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 760, 0, 470),
		BackgroundTransparency = 0.04,
	}, 24)

	-- left column: title and tabs
	local side = UI.frame(panel, { Size = UDim2.new(0, 190, 1, 0), BackgroundColor3 = C.card, BackgroundTransparency = 0.5 })
	UI.corner(side, 24)
	UI.label(side, "NEON", 30, BLACK, teamColor(1), { Position = UDim2.new(0, 22, 0, 22), Size = UDim2.new(1, -30, 0, 32) })
	UI.label(side, "CANVAS", 30, BLACK, teamColor(2), { Position = UDim2.new(0, 22, 0, 52), Size = UDim2.new(1, -30, 0, 32) })
	UI.label(side, "Paint the floor. Knock out the rest.", 11, MEDIUM, C.muted, {
		Position = UDim2.new(0, 22, 0, 90), Size = UDim2.new(1, -36, 0, 30), TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	Menu.tabs = {}
	Menu.pages = {}
	local names = { { "play", "HOW TO PLAY" }, { "loadout", "LOADOUT" }, { "profile", "PROFILE" } }
	for i, pair in ipairs(names) do
		local tab = UI.button(side, pair[2], {
			Position = UDim2.new(0, 18, 0, 130 + (i - 1) * 44), Size = UDim2.new(1, -36, 0, 36),
		})
		Menu.tabs[pair[1]] = tab
		tab.Activated:Connect(function()
			Menu.show(pair[1])
		end)
		Menu.pages[pair[1]] = UI.frame(panel, {
			Position = UDim2.new(0, 214, 0, 24), Size = UDim2.new(1, -238, 1, -48), Visible = false,
		})
	end
	Menu.status = UI.label(side, "", 11, MEDIUM, C.muted, {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 22, 1, -64), Size = UDim2.new(1, -36, 0, 30),
		TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
	})
	local close = UI.button(side, "CLOSE", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 18, 1, -18), Size = UDim2.new(1, -36, 0, 36),
	}, C.gold)
	close.Activated:Connect(function()
		Menu.close()
	end)

	-- how to play
	local play = Menu.pages.play
	UI.label(play, "HOW TO PLAY", 20, BLACK, C.text, { Size = UDim2.new(1, 0, 0, 26) })
	local lines = {
		{ "nova", "Every dot you walk over or splash turns your team's colour." },
		{ "bolt", "Shoot enemies to knock them out. Each knock-out repaints the floor around them." },
		{ "dash", "Dash to dodge. Falling off the canvas counts as a knock-out." },
		{ "ult", "Painting and fighting charge your Chroma Burst. Use it to flip a fight." },
		{ "overdrive", "Glowing orbs on the floor are power-ups. Grab them first." },
	}
	for i, line in ipairs(lines) do
		local row = UI.frame(play, { Position = UDim2.new(0, 0, 0, 40 + (i - 1) * 44), Size = UDim2.new(1, 0, 0, 38) })
		local icon = UI.frame(row, { Position = UDim2.new(0, 4, 0, 5), Size = UDim2.new(0, 26, 0, 26) })
		UI.icon(icon, line[1], i % 2 == 1 and teamColor(1) or teamColor(2))
		UI.label(row, line[2], 13, MEDIUM, C.text, {
			Position = UDim2.new(0, 46, 0, 0), Size = UDim2.new(1, -50, 1, 0), TextWrapped = true,
		})
	end
	local keys = UI.frame(play, { Position = UDim2.new(0, 0, 0, 272), Size = UDim2.new(1, 0, 0, 128), BackgroundColor3 = C.card })
	UI.corner(keys, 16)
	UI.label(keys, "CONTROLS", 11, BOLD, C.muted, { Position = UDim2.new(0, 16, 0, 10), Size = UDim2.new(1, -32, 0, 14) })
	local controls = {
		"WASD  move      ·      Mouse  aim      ·      Hold left click  shoot",
		"SHIFT or Q  dash      ·      E and R  abilities      ·      F  Chroma Burst",
		"Mouse wheel  zoom      ·      M  this menu      ·      SPACE  jump over shots",
		"On a phone: stick to move, buttons on the right. Aim is automatic.",
	}
	for i, text in ipairs(controls) do
		UI.label(keys, text, 12, MEDIUM, C.text, { Position = UDim2.new(0, 16, 0, 8 + i * 24), Size = UDim2.new(1, -32, 0, 18) })
	end

	-- loadout
	local load = Menu.pages.loadout
	UI.label(load, "LOADOUT", 20, BLACK, C.text, { Size = UDim2.new(1, 0, 0, 26) })
	UI.label(load, "PRIMARY", 11, BOLD, C.muted, { Position = UDim2.new(0, 0, 0, 36), Size = UDim2.new(1, 0, 0, 14) })
	local primaries = UI.frame(load, { Position = UDim2.new(0, 0, 0, 54), Size = UDim2.new(1, 0, 0, 84) })
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder,
	}, primaries)
	for i, id in ipairs(CONFIG.primaryOrder) do
		Menu.card(primaries, "primary", id, CONFIG.primaries[id], i)
	end
	UI.label(load, "ABILITIES  ·  pick two", 11, BOLD, C.muted, { Position = UDim2.new(0, 0, 0, 150), Size = UDim2.new(1, 0, 0, 14) })
	local abilities = UI.frame(load, { Position = UDim2.new(0, 0, 0, 168), Size = UDim2.new(1, 0, 0, 254) })
	UI.new("UIGridLayout", {
		CellSize = UDim2.new(0, 166, 0, 78), CellPadding = UDim2.new(0, 10, 0, 10), SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	}, abilities)
	for i, id in ipairs(CONFIG.abilityOrder) do
		Menu.card(abilities, "ability", id, CONFIG.abilities[id], i)
	end

	-- profile
	local prof = Menu.pages.profile
	UI.label(prof, "PROFILE", 20, BLACK, C.text, { Size = UDim2.new(1, 0, 0, 26) })
	Menu.level = UI.label(prof, "LEVEL 1", 26, BLACK, C.gold, { Position = UDim2.new(0, 0, 0, 38), Size = UDim2.new(0.5, 0, 0, 30) })
	Menu.rank = UI.label(prof, "Bronze", 26, BLACK, C.text, {
		Position = UDim2.new(0.5, 0, 0, 38), Size = UDim2.new(0.5, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Right,
	})
	local xpTrack = UI.frame(prof, { Position = UDim2.new(0, 0, 0, 76), Size = UDim2.new(1, 0, 0, 8), BackgroundColor3 = C.card })
	UI.round(xpTrack)
	Menu.xpFill = UI.frame(xpTrack, { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.gold })
	UI.round(Menu.xpFill)
	Menu.xpText = UI.label(prof, "", 11, MEDIUM, C.muted, { Position = UDim2.new(0, 0, 0, 90), Size = UDim2.new(1, 0, 0, 14) })
	Menu.stats = {}
	local statNames = { "Matches", "Wins", "KOs", "Dots", "Coins" }
	local statLabels = { "MATCHES", "WINS", "KNOCK-OUTS", "DOTS PAINTED", "COINS" }
	for i, key in ipairs(statNames) do
		local box = UI.frame(prof, {
			Position = UDim2.new((i - 1) / 5, i == 1 and 0 or 4, 0, 116), Size = UDim2.new(1 / 5, -4, 0, 58),
			BackgroundColor3 = C.card,
		})
		UI.corner(box, 12)
		Menu.stats[key] = UI.label(box, "0", 18, BLACK, C.text, { Position = UDim2.new(0, 0, 0, 9), Size = UDim2.new(1, 0, 0, 22), TextXAlignment = CENTER })
		UI.label(box, statLabels[i], 8, BOLD, C.muted, { Position = UDim2.new(0, 0, 0, 36), Size = UDim2.new(1, 0, 0, 12), TextXAlignment = CENTER })
	end
	UI.label(prof, "TITLES  ·  shown above your name", 11, BOLD, C.muted, { Position = UDim2.new(0, 0, 0, 190), Size = UDim2.new(1, 0, 0, 14) })
	local titles = UI.frame(prof, { Position = UDim2.new(0, 0, 0, 210), Size = UDim2.new(1, 0, 0, 210) })
	UI.new("UIGridLayout", {
		CellSize = UDim2.new(0, 166, 0, 44), CellPadding = UDim2.new(0, 10, 0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	}, titles)
	Menu.titles = {}
	for i, id in ipairs(CONFIG.titleOrder) do
		local def = CONFIG.titles[id]
		local button = UI.new("TextButton", {
			AutoButtonColor = false, Text = "", BorderSizePixel = 0, BackgroundColor3 = C.card, LayoutOrder = i,
		}, titles)
		UI.corner(button, 12)
		local border = UI.stroke(button, C.gold, 2, 1)
		UI.label(button, def.name, 13, BOLD, C.text, { Position = UDim2.new(0, 12, 0, 5), Size = UDim2.new(1, -24, 0, 18) })
		local note = UI.label(button, "", 10, MEDIUM, C.muted, { Position = UDim2.new(0, 12, 0, 24), Size = UDim2.new(1, -24, 0, 14) })
		Menu.titles[id] = { def = def, border = border, note = note }
		button.Activated:Connect(function()
			Sfx.play("click")
			requestEvent:FireServer("title", id)
		end)
	end
	Menu.show("play")
end

function Menu.show(tab)
	Menu.tab = tab
	for name, page in pairs(Menu.pages) do
		page.Visible = name == tab
		Menu.tabs[name].BackgroundColor3 = name == tab and C.cardHi or C.card
	end
	Menu.dirty = true
end

function Menu.refresh()
	Menu.dirty = false
	local lvl = player:GetAttribute("Lvl") or 1
	local primary, a1, a2 = player:GetAttribute("Primary"), player:GetAttribute("A1"), player:GetAttribute("A2")
	for _, card in ipairs(Menu.cards) do
		local chosen, tag = false, ""
		if card.slotKind == "primary" then
			chosen = card.id == primary
			tag = chosen and "LMB" or ""
		elseif card.id == a1 then
			chosen, tag = true, "E"
		elseif card.id == a2 then
			chosen, tag = true, "R"
		end
		card.border.Transparency = chosen and 0 or 1
		card.border.Color = teamColor(myTeam() > 0 and myTeam() or 1)
		card.tag.Text = tag
		card.lock.Visible = lvl < card.def.unlock
	end
	local xp, need = player:GetAttribute("XP") or 0, math.max(1, player:GetAttribute("XPNeed") or 1)
	local rating = player:GetAttribute("Rating") or 0
	local rank, nextRank = rankOf(rating)
	Menu.level.Text = "LEVEL " .. tostring(lvl)
	Menu.rank.Text = string.upper(rank.name) .. "  " .. tostring(rating)
	Menu.xpFill.Size = UDim2.new(math.clamp(xp / need, 0, 1), 0, 1, 0)
	Menu.xpText.Text = tostring(xp) .. " / " .. tostring(need) .. " XP"
		.. (nextRank and ("      ·      " .. tostring(nextRank.at - rating) .. " rating to " .. nextRank.name) or "")
	for key, label in pairs(Menu.stats) do
		label.Text = tostring(player:GetAttribute(key) or 0)
	end
	local owned = {}
	for id in string.gmatch(player:GetAttribute("Titles") or "", "[^,]+") do
		owned[id] = true
	end
	local equipped = player:GetAttribute("Title")
	local coins = player:GetAttribute("Coins") or 0
	for id, entry in pairs(Menu.titles) do
		entry.border.Transparency = id == equipped and 0 or 1
		if id == equipped then
			entry.note.Text = "Equipped"
			entry.note.TextColor3 = C.gold
		elseif owned[id] then
			entry.note.Text = "Owned  ·  tap to equip"
			entry.note.TextColor3 = C.muted
		else
			entry.note.Text = tostring(entry.def.cost) .. " coins"
			entry.note.TextColor3 = coins >= entry.def.cost and C.good or C.muted
		end
	end
end

function Menu.open()
	Menu.gui.Enabled = true
	Menu.dirty = true
end

function Menu.close()
	Menu.gui.Enabled = false
end

function Menu.toggle()
	if Menu.gui.Enabled then
		Menu.close()
	else
		Menu.open()
	end
end

function Menu.update()
	if not Menu.gui.Enabled then
		return
	end
	local camera = workspace.CurrentCamera
	if camera then
		local size = camera.ViewportSize
		Menu.scale.Scale = math.clamp(math.min(size.Y / 560, size.X / 820), 0.45, 1.3)
	end
	local ph = phase()
	local left = math.max(0, math.ceil((shared:GetAttribute("EndsAt") or 0) - serverNow()))
	if ph == "Intermission" then
		Menu.status.Text = "Next match starts in " .. tostring(left) .. "s"
	elseif ph == "Results" then
		Menu.status.Text = "Match over"
	else
		Menu.status.Text = "Match in progress. Changes apply right away."
	end
	if Menu.dirty then
		Menu.refresh()
	end
end

---------------------------------------------------------------------------------------------------
-- Results card
---------------------------------------------------------------------------------------------------

function Results.build()
	local gui = UI.new("ScreenGui", {
		Name = "NeonCanvasResults", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 7, Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)
	Results.gui = gui
	Results.scale = UI.new("UIScale", { Scale = 1 }, gui)
	local panel = UI.panel(gui, {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -24, 0.5, 10), Size = UDim2.new(0, 400, 0, 500),
		BackgroundTransparency = 0.08, Active = true,
	}, 24)
	Results.title = UI.label(panel, "", 38, BLACK, C.text, { Position = UDim2.new(0, 24, 0, 18), Size = UDim2.new(1, -48, 0, 44) })
	Results.score = UI.label(panel, "", 14, BOLD, C.text, { Position = UDim2.new(0, 24, 0, 64), Size = UDim2.new(1, -48, 0, 18), RichText = true })
	local head = UI.frame(panel, { Position = UDim2.new(0, 24, 0, 94), Size = UDim2.new(1, -48, 0, 16) })
	UI.label(head, "PLAYER", 9, BOLD, C.muted, { Size = UDim2.new(0.6, 0, 1, 0) })
	UI.label(head, "DOTS", 9, BOLD, C.muted, { Position = UDim2.new(0.6, 0, 0, 0), Size = UDim2.new(0.2, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
	UI.label(head, "KOs", 9, BOLD, C.muted, { Position = UDim2.new(0.8, 0, 0, 0), Size = UDim2.new(0.2, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
	Results.rows = UI.frame(panel, { Position = UDim2.new(0, 24, 0, 114), Size = UDim2.new(1, -48, 0, 250) })
	Results.listProps = {
		FillDirection = Enum.FillDirection.Vertical, HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
	}
	UI.new("UIListLayout", Results.listProps, Results.rows)
	local rewards = UI.frame(panel, {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 24, 1, -24), Size = UDim2.new(1, -48, 0, 96),
		BackgroundColor3 = C.card,
	})
	UI.corner(rewards, 16)
	Results.reward = UI.label(rewards, "", 14, BOLD, C.gold, { Position = UDim2.new(0, 16, 0, 12), Size = UDim2.new(1, -32, 0, 18) })
	Results.rating = UI.label(rewards, "", 12, MEDIUM, C.text, { Position = UDim2.new(0, 16, 0, 36), Size = UDim2.new(1, -32, 0, 16) })
	Results.unlock = UI.label(rewards, "", 12, BOLD, C.good, {
		Position = UDim2.new(0, 16, 0, 58), Size = UDim2.new(1, -32, 0, 30), TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
end

function Results.show(data)
	if type(data) ~= "table" or type(data.rows) ~= "table" then
		return
	end
	local won = data.winner ~= 0 and data.winner == data.team
	if data.winner == 0 then
		Results.title.Text = "DRAW"
		Results.title.TextColor3 = C.text
	elseif won then
		Results.title.Text = "VICTORY"
		Results.title.TextColor3 = C.gold
		Sfx.play("win")
	else
		Results.title.Text = "DEFEAT"
		Results.title.TextColor3 = C.muted
		Sfx.play("lose")
	end
	local a, b = tostring(data.a), tostring(data.b)
	if data.mode == "Turf" then
		local total = math.max(1, tonumber(data.total) or 1)
		a = tostring(math.floor((tonumber(data.a) or 0) / total * 100 + 0.5)) .. "%"
		b = tostring(math.floor((tonumber(data.b) or 0) / total * 100 + 0.5)) .. "%"
	end
	Results.score.Text = named(CONFIG.teamNames[1] .. "  " .. a, 1) .. "      " .. named(b .. "  " .. CONFIG.teamNames[2], 2)
	Results.rows:ClearAllChildren()
	UI.new("UIListLayout", Results.listProps, Results.rows)
	for i, row in ipairs(data.rows) do
		if i > 9 then
			break
		end
		local mine = row.id == data.me
		local line = UI.frame(Results.rows, {
			Size = UDim2.new(1, 0, 0, 24), LayoutOrder = i, BackgroundColor3 = mine and C.cardHi or C.card,
			BackgroundTransparency = mine and 0 or 0.5,
		})
		UI.corner(line, 8)
		local name = tostring(row.n) .. (row.b and "  (bot)" or "") .. (row.mvp and "   MVP" or "")
		UI.label(line, name, 12, mine and BOLD or MEDIUM, teamColor(row.t), {
			Position = UDim2.new(0, 10, 0, 0), Size = UDim2.new(0.6, -10, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd,
		})
		UI.label(line, tostring(row.d), 12, BOLD, C.text, { Position = UDim2.new(0.6, 0, 0, 0), Size = UDim2.new(0.2, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
		UI.label(line, tostring(row.k), 12, BOLD, C.text, { Position = UDim2.new(0.8, -8, 0, 0), Size = UDim2.new(0.2, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
	end
	local reward = data.reward
	if type(reward) == "table" then
		Results.reward.Text = "+" .. tostring(reward.xp) .. " XP      +" .. tostring(reward.coins) .. " coins"
		local delta = tonumber(reward.ratingDelta) or 0
		local rank = rankOf(tonumber(reward.rating) or 0)
		local change = delta > 0 and ("+" .. tostring(delta)) or (delta < 0 and tostring(delta) or "no change")
		Results.rating.Text = "Rating " .. tostring(reward.rating) .. "  (" .. change .. ")  ·  " .. rank.name
		local notes = {}
		if (tonumber(reward.lvl1) or 0) > (tonumber(reward.lvl0) or 0) then
			table.insert(notes, "LEVEL UP!  You are now level " .. tostring(reward.lvl1) .. ".")
		end
		if type(reward.unlocks) == "table" and #reward.unlocks > 0 then
			table.insert(notes, "Unlocked: " .. table.concat(reward.unlocks, ", "))
		end
		Results.unlock.Text = table.concat(notes, "  ")
	else
		Results.reward.Text = ""
		Results.rating.Text = ""
		Results.unlock.Text = ""
	end
	Results.gui.Enabled = true
	Menu.dirty = true
end

function Results.hide()
	if Results.gui then
		Results.gui.Enabled = false
	end
end

function Results.update()
	local camera = workspace.CurrentCamera
	if camera and Results.gui and Results.gui.Enabled then
		local size = camera.ViewportSize
		Results.scale.Scale = math.clamp(math.min(size.Y / 600, size.X / 900), 0.45, 1.3)
	end
end

---------------------------------------------------------------------------------------------------
-- Aim marker on the floor
---------------------------------------------------------------------------------------------------

local reticle = fxPart(Enum.PartType.Cylinder, C.white, 1, Vector3.new(0.15, 3, 3))
reticle.Name = "Reticle"
reticle.Parent = Fx.folder

local function updateReticle()
	if phase() ~= "Playing" or myTeam() == 0 or not alive() or Input.device() ~= "mouse" then
		reticle.Transparency = 1
		return
	end
	local ax, az = Input.aim()
	local pos = me.root.Position
	local id = player:GetAttribute("Primary") or "bolt"
	local def = CONFIG.primaries[id] or CONFIG.primaries.bolt
	local dx, dz = ax - pos.X, az - pos.Z
	local d = math.sqrt(dx * dx + dz * dz)
	if d > def.range then
		ax, az = pos.X + dx / d * def.range, pos.Z + dz / d * def.range
	end
	local radius = id == "lob" and 11 or 1.6
	reticle.Size = Vector3.new(0.15, radius * 2, radius * 2)
	reticle.CFrame = CFrame.new(ax, FLOOR + 0.75, az) * UPRIGHT
	reticle.Color = teamColor(myTeam())
	reticle.Transparency = id == "lob" and 0.8 or 0.35
end

---------------------------------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------------------------------

guard("core gui", function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	player.DevEnableMouseLock = false
end)

player.CharacterAdded:Connect(bindCharacter)
if player.Character then
	bindCharacter(player.Character)
end

guard("hud", Hud.build)
guard("menu", Menu.build)
guard("results", Results.build)
guard("tiles", Tiles.init)
guard("bots", BotView.init)
guard("input", Input.init)

fxEvent.OnClientEvent:Connect(function(kind, ...)
	guard("effect", Fx.handle, kind, ...)
end)
feedEvent.OnClientEvent:Connect(function(kind, ...)
	guard("feed", Hud.onFeed, kind, ...)
end)
resultsEvent.OnClientEvent:Connect(function(data)
	guard("results", Results.show, data)
end)
player.AttributeChanged:Connect(function()
	Menu.dirty = true
end)

RunService:BindToRenderStep("NeonCanvasCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	guard("camera", Cam.update, dt)
end)

RunService.RenderStepped:Connect(function(dt)
	guard("tiles", Tiles.update, dt)
	guard("bots", BotView.update, dt)
	guard("effects", Fx.update, dt)
	guard("input", Input.update)
	guard("reticle", updateReticle)
	guard("hud", Hud.update, dt)
	guard("menu", Menu.update)
	guard("results", Results.update)
end)
