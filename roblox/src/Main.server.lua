-- Chaos Arena: server script.
-- Builds the whole map from code, then runs survival rounds forever.
-- Put this in ServerScriptService.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Lighting = game:GetService("Lighting")

---------------------------------------------------------------- settings

local GRID = 10             -- arena is GRID x GRID tiles
local TILE = 14             -- tile size in studs
local ARENA_Y = 40          -- height of the arena floor
local HALF = GRID * TILE / 2
local FLOOR_TOP = ARENA_Y + 1
local LAVA_BASE_Y = ARENA_Y - 24
local LOBBY_POS = Vector3.new(0, ARENA_Y + 36, -HALF - 55)

local INTERMISSION = 12     -- seconds between rounds
local EVENTS_PER_ROUND = 3
local COINS_PER_EVENT = 10
local COINS_PER_WIN = 50
local SPEED_PRICE = 150
local TRAIL_PRICE = 100

---------------------------------------------------------------- remotes

local status = Instance.new("StringValue")
status.Name = "Status"
status.Value = "Loading..."
status.Parent = ReplicatedStorage

local bannerEvent = Instance.new("RemoteEvent")
bannerEvent.Name = "Banner"
bannerEvent.Parent = ReplicatedStorage

local flingEvent = Instance.new("RemoteEvent")
flingEvent.Name = "Fling"
flingEvent.Parent = ReplicatedStorage

local function banner(title, subtitle)
	bannerEvent:FireAllClients(title, subtitle or "")
end

---------------------------------------------------------------- helpers

local rng = Random.new()

local function newPart(props)
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
	p.Parent = props.Parent or workspace
	return p
end

local function addSign(part, face, text, color)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Parent = gui
	return label
end

local function getRoot(player)
	local char = player.Character
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then
		return root, hum
	end
	return nil
end

local function kill(player)
	local _, hum = getRoot(player)
	if hum then
		hum.Health = 0
	end
end

local lastFling = {}
local function fling(player, velocity)
	local now = os.clock()
	if lastFling[player] and now - lastFling[player] < 0.5 then
		return
	end
	lastFling[player] = now
	flingEvent:FireClient(player, velocity)
end

local function shuffle(list)
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

---------------------------------------------------------------- world

local old = workspace:FindFirstChild("Baseplate")
if old then
	old:Destroy()
end
for _, obj in ipairs(workspace:GetChildren()) do
	if obj:IsA("SpawnLocation") then
		obj:Destroy()
	end
end

Lighting.ClockTime = 17.5
Lighting.Brightness = 2.5
Lighting.Ambient = Color3.fromRGB(90, 80, 110)

local world = Instance.new("Folder")
world.Name = "ChaosArena"
world.Parent = workspace

-- lava
local lava = newPart({
	Name = "Lava",
	Size = Vector3.new(700, 4, 700),
	Position = Vector3.new(0, LAVA_BASE_Y, 0),
	Color = Color3.fromRGB(255, 90, 20),
	Material = Enum.Material.Neon,
	CanCollide = false,
	Parent = world,
})

local function lavaTop()
	return lava.Position.Y + 2
end

-- arena tiles
local tiles = {}
local tileFolder = Instance.new("Folder")
tileFolder.Name = "Tiles"
tileFolder.Parent = world

local COLOR_A = Color3.fromRGB(90, 200, 255)
local COLOR_B = Color3.fromRGB(245, 245, 255)

for i = 1, GRID do
	for j = 1, GRID do
		local pos = Vector3.new((i - 0.5) * TILE - HALF, ARENA_Y, (j - 0.5) * TILE - HALF)
		local color = COLOR_B
		if (i + j) % 2 == 0 then
			color = COLOR_A
		end
		local part = newPart({
			Name = "Tile",
			Size = Vector3.new(TILE - 0.2, 2, TILE - 0.2),
			Position = pos,
			Color = color,
			Parent = tileFolder,
		})
		table.insert(tiles, { part = part, home = pos, color = color, i = i, j = j, gone = false })
	end
end

local function resetTiles(duration)
	for _, t in ipairs(tiles) do
		t.gone = false
		t.part.Color = t.color
		t.part.Material = Enum.Material.SmoothPlastic
		t.part.Transparency = 0
		t.part.CanCollide = true
		if duration and duration > 0 then
			TweenService:Create(t.part, TweenInfo.new(duration), { Position = t.home }):Play()
		else
			t.part.Position = t.home
		end
	end
	if duration and duration > 0 then
		task.wait(duration)
	end
end

local function dropTile(t, warnTime)
	if t.gone then
		return
	end
	t.gone = true
	task.spawn(function()
		t.part.Color = Color3.fromRGB(255, 60, 60)
		t.part.Material = Enum.Material.Neon
		task.wait(warnTime)
		if not t.gone then
			return
		end
		t.part.CanCollide = false
		TweenService:Create(t.part, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = t.part.Position - Vector3.new(0, 25, 0), Transparency = 1 }):Play()
	end)
end

local function nearestTile(pos)
	local best, bestDist = nil, math.huge
	for _, t in ipairs(tiles) do
		if not t.gone then
			local d = (Vector3.new(t.home.X, 0, t.home.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
			if d < bestDist then
				best, bestDist = t, d
			end
		end
	end
	return best
end

-- lobby
local lobby = Instance.new("Folder")
lobby.Name = "Lobby"
lobby.Parent = world

local LOBBY_W, LOBBY_D, WALL_H = 80, 40, 14
newPart({
	Name = "Floor",
	Size = Vector3.new(LOBBY_W, 2, LOBBY_D),
	Position = LOBBY_POS,
	Color = Color3.fromRGB(70, 60, 110),
	Parent = lobby,
})
local wallY = LOBBY_POS.Y + 1 + WALL_H / 2
-- glass front so people in the lobby can watch the round
newPart({
	Name = "Glass",
	Size = Vector3.new(LOBBY_W, WALL_H, 1),
	Position = Vector3.new(LOBBY_POS.X, wallY, LOBBY_POS.Z + LOBBY_D / 2),
	Color = Color3.fromRGB(180, 230, 255),
	Material = Enum.Material.Glass,
	Transparency = 0.7,
	Parent = lobby,
})
local backWall = newPart({
	Name = "BackWall",
	Size = Vector3.new(LOBBY_W, WALL_H, 1),
	Position = Vector3.new(LOBBY_POS.X, wallY, LOBBY_POS.Z - LOBBY_D / 2),
	Color = Color3.fromRGB(50, 40, 90),
	Parent = lobby,
})
for _, side in ipairs({ -1, 1 }) do
	newPart({
		Name = "SideWall",
		Size = Vector3.new(1, WALL_H, LOBBY_D),
		Position = Vector3.new(LOBBY_POS.X + side * LOBBY_W / 2, wallY, LOBBY_POS.Z),
		Color = Color3.fromRGB(50, 40, 90),
		Parent = lobby,
	})
end
addSign(backWall, Enum.NormalId.Back, "CHAOS ARENA\nSurvive 3 disasters. Last ones standing win!",
	Color3.fromRGB(255, 220, 90))

local spawnPad = Instance.new("SpawnLocation")
spawnPad.Name = "LobbySpawn"
spawnPad.Anchored = true
spawnPad.Neutral = true
spawnPad.Duration = 0
spawnPad.Size = Vector3.new(12, 1, 12)
spawnPad.Position = LOBBY_POS + Vector3.new(0, 1.5, 0)
spawnPad.Color = Color3.fromRGB(120, 255, 170)
spawnPad.Material = Enum.Material.Neon
spawnPad.TopSurface = Enum.SurfaceType.Smooth
spawnPad.Parent = lobby

local function lobbyPoint()
	return LOBBY_POS + Vector3.new(rng:NextNumber(-20, 20), 6, rng:NextNumber(-10, 10))
end

---------------------------------------------------------------- player data

local store = nil
pcall(function()
	store = DataStoreService:GetDataStore("ChaosArena_v1")
end)

local data = {} -- [player] = { coins, wins, speed, trail }

local function applyPerks(player)
	local d = data[player]
	local root, hum = getRoot(player)
	if not d or not root then
		return
	end
	if d.speed then
		hum.WalkSpeed = 22
	end
	if d.trail and not root:FindFirstChild("ChaosTrail") then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 1, 0)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -1, 0)
		a1.Parent = root
		local trail = Instance.new("Trail")
		trail.Name = "ChaosTrail"
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.7
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 230, 80)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(80, 255, 140)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 160, 255)),
		})
		trail.Parent = root
	end
end

local function syncStats(player)
	local d = data[player]
	local stats = player:FindFirstChild("leaderstats")
	if d and stats then
		stats.Wins.Value = d.wins
		stats.Coins.Value = d.coins
	end
end

local function savePlayer(player)
	local d = data[player]
	if not d or not store then
		return
	end
	pcall(function()
		store:SetAsync("p_" .. player.UserId, d)
	end)
end

local function onPlayerAdded(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = stats
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = stats
	stats.Parent = player

	local d = { coins = 0, wins = 0, speed = false, trail = false }
	if store then
		local ok, saved = pcall(function()
			return store:GetAsync("p_" .. player.UserId)
		end)
		if ok and type(saved) == "table" then
			d.coins = tonumber(saved.coins) or 0
			d.wins = tonumber(saved.wins) or 0
			d.speed = saved.speed == true
			d.trail = saved.trail == true
		end
	end
	data[player] = d
	syncStats(player)

	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		applyPerks(player)
	end)
	if player.Character then
		applyPerks(player)
	end
end

local alive = {} -- [player] = true while they are still in the round

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

Players.PlayerRemoving:Connect(function(player)
	savePlayer(player)
	data[player] = nil
	alive[player] = nil
	lastFling[player] = nil
end)

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do
		savePlayer(p)
	end
end)

local function addCoins(player, amount)
	local d = data[player]
	if d then
		d.coins = d.coins + amount
		syncStats(player)
	end
end

---------------------------------------------------------------- shop

local function shopPad(offsetX, color, name, price, key)
	local pad = newPart({
		Name = name,
		Size = Vector3.new(8, 1, 8),
		Position = LOBBY_POS + Vector3.new(offsetX, 1.5, -LOBBY_D / 2 + 8),
		Color = color,
		Material = Enum.Material.Neon,
		Parent = lobby,
	})
	local board = newPart({
		Name = name .. "Sign",
		Size = Vector3.new(10, 5, 0.5),
		Position = pad.Position + Vector3.new(0, 6, -4),
		Color = Color3.fromRGB(30, 25, 50),
		Parent = lobby,
	})
	addSign(board, Enum.NormalId.Back, name .. "\n" .. price .. " coins", color)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Buy"
	prompt.ObjectText = name .. " (" .. price .. " coins)"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad
	prompt.Triggered:Connect(function(player)
		local d = data[player]
		if not d then
			return
		end
		if d[key] then
			bannerEvent:FireClient(player, "Already owned", name)
		elseif d.coins < price then
			bannerEvent:FireClient(player, "Not enough coins", "You need " .. price)
		else
			d.coins = d.coins - price
			d[key] = true
			syncStats(player)
			applyPerks(player)
			bannerEvent:FireClient(player, "Purchased!", name)
			task.spawn(savePlayer, player)
		end
	end)
end

shopPad(-28, Color3.fromRGB(90, 220, 255), "Speed Boost", SPEED_PRICE, "speed")
shopPad(28, Color3.fromRGB(255, 120, 220), "Rainbow Trail", TRAIL_PRICE, "trail")

---------------------------------------------------------------- round state

local function aliveList()
	local list = {}
	for p in pairs(alive) do
		table.insert(list, p)
	end
	return list
end

local function anyAlive()
	return next(alive) ~= nil
end

-- every frame: drop dead / fallen players out of the round
RunService.Heartbeat:Connect(function()
	local top = lavaTop()
	for _, p in ipairs(Players:GetPlayers()) do
		local root = getRoot(p)
		if root then
			if root.Position.Y - 3 < top or root.Position.Y < ARENA_Y - 60 then
				kill(p)
				alive[p] = nil
			end
		elseif alive[p] then
			alive[p] = nil
		end
	end
end)

-- runs fn(elapsed, dt) every frame for `duration` seconds, stops early if nobody is left
local function forDuration(duration, fn)
	local elapsed = 0
	while elapsed < duration and anyAlive() do
		local dt = task.wait()
		elapsed = elapsed + dt
		fn(elapsed, dt)
	end
end

---------------------------------------------------------------- disasters

-- 1. tiles turn red and drop one by one
local function eventFallingTiles()
	local order = {}
	for _, t in ipairs(tiles) do
		table.insert(order, t)
	end
	shuffle(order)
	local keep = 10
	local index = 1
	local timer = 0
	forDuration(28, function(elapsed, dt)
		timer = timer - dt
		if timer <= 0 and index <= #order - keep then
			dropTile(order[index], 1.1)
			index = index + 1
			timer = math.max(0.12, 0.45 - elapsed * 0.012)
		end
	end)
end

-- 2. meteors land on red circles and blast players away
local METEOR_RADIUS = 9

local function meteor(target)
	local marker = newPart({
		Name = "MeteorWarning",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, METEOR_RADIUS * 2, METEOR_RADIUS * 2),
		CFrame = CFrame.new(target + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 40, 40),
		Material = Enum.Material.Neon,
		Transparency = 0.45,
		CanCollide = false,
		Parent = world,
	})
	local rock = newPart({
		Name = "Meteor",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(8, 8, 8),
		Position = target + Vector3.new(0, 130, 0),
		Color = Color3.fromRGB(255, 150, 40),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = world,
	})
	local fallTime = 1.3
	TweenService:Create(rock, TweenInfo.new(fallTime, Enum.EasingStyle.Linear), { Position = target }):Play()
	task.wait(fallTime)
	local boom = Instance.new("Explosion")
	boom.BlastPressure = 0
	boom.BlastRadius = METEOR_RADIUS
	boom.DestroyJointRadiusPercent = 0
	boom.Position = target
	boom.Parent = workspace
	for p in pairs(alive) do
		local root = getRoot(p)
		if root then
			local offset = root.Position - target
			if offset.Magnitude < METEOR_RADIUS + 1.5 then
				local flat = Vector3.new(offset.X, 0, offset.Z)
				if flat.Magnitude < 0.1 then
					flat = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
				end
				fling(p, flat.Unit * 75 + Vector3.new(0, 90, 0))
			end
		end
	end
	if rng:NextNumber() < 0.4 then
		local t = nearestTile(target)
		if t and (Vector3.new(t.home.X, 0, t.home.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude < TILE * 0.7 then
			dropTile(t, 0.2)
		end
	end
	marker:Destroy()
	rock:Destroy()
end

local function eventMeteors()
	local timer = 1
	forDuration(26, function(elapsed, dt)
		timer = timer - dt
		if timer > 0 then
			return
		end
		timer = math.max(0.22, 0.7 - elapsed * 0.02)
		local target = nil
		local list = aliveList()
		if #list > 0 and rng:NextNumber() < 0.55 then
			local root = getRoot(list[rng:NextInteger(1, #list)])
			if root then
				target = Vector3.new(root.Position.X + rng:NextNumber(-6, 6), FLOOR_TOP,
					root.Position.Z + rng:NextNumber(-6, 6))
			end
		end
		if not target then
			target = Vector3.new(rng:NextNumber(-HALF, HALF), FLOOR_TOP, rng:NextNumber(-HALF, HALF))
		end
		task.spawn(meteor, target)
	end)
	task.wait(1.6)
end

-- 3. a spinning bar you have to jump over; it speeds up and sometimes reverses
local function eventSweeper()
	local len = GRID * TILE * 1.02
	local bar = newPart({
		Name = "Sweeper",
		Size = Vector3.new(len, 3, 3),
		Color = Color3.fromRGB(255, 60, 90),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = world,
	})
	local angle = rng:NextNumber(0, math.pi)
	local dir = 1
	local flipAt = rng:NextNumber(8, 13)
	bar.CFrame = CFrame.new(0, FLOOR_TOP + 1.5, 0) * CFrame.Angles(0, angle, 0)
	task.wait(1)
	forDuration(30, function(elapsed, dt)
		local speed = 0.9 + elapsed * 0.05
		if elapsed > flipAt then
			dir = -dir
			flipAt = elapsed + rng:NextNumber(6, 10)
		end
		angle = angle + dir * speed * dt
		bar.CFrame = CFrame.new(0, FLOOR_TOP + 1.5, 0) * CFrame.Angles(0, angle, 0)
		for p in pairs(alive) do
			local root = getRoot(p)
			if root then
				local l = bar.CFrame:PointToObjectSpace(root.Position)
				local feet = root.Position.Y - 3
				if math.abs(l.X) < len / 2 and math.abs(l.Z) < 2.7 and feet < FLOOR_TOP + 2.6 then
					local side = 1
					if l.X < 0 then
						side = -1
					end
					fling(p, bar.CFrame.LookVector * (side * dir * 85) + Vector3.new(0, 55, 0))
				end
			end
		end
	end)
	bar:Destroy()
end

-- 4. the floor becomes a pyramid and the lava rises; only the top is safe
local function eventRisingLava()
	local STEP = 5
	local rings = GRID / 2 - 1
	for _, t in ipairs(tiles) do
		local c = (GRID + 1) / 2
		local ring = math.max(math.abs(t.i - c), math.abs(t.j - c)) - 0.5
		local h = (rings - ring) * STEP
		TweenService:Create(t.part, TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = t.home + Vector3.new(0, h, 0) }):Play()
	end
	task.wait(3.2)
	-- final lava surface sits just above the second-highest ring
	local finalTop = FLOOR_TOP + (rings - 1) * STEP + 1.5
	local rise = TweenService:Create(lava, TweenInfo.new(20, Enum.EasingStyle.Linear),
		{ Position = Vector3.new(0, finalTop - 2, 0) })
	rise:Play()
	forDuration(24, function() end)
	rise:Cancel()
	TweenService:Create(lava, TweenInfo.new(2), { Position = Vector3.new(0, LAVA_BASE_Y, 0) }):Play()
	task.wait(2)
end

-- 5. giant boulders roll down red lanes
local function boulder()
	local alongX = rng:NextNumber() < 0.5
	local lane = (rng:NextInteger(1, GRID) - 0.5) * TILE - HALF
	local dir = 1
	if rng:NextNumber() < 0.5 then
		dir = -1
	end
	local reach = HALF + 20
	local function at(d, y)
		if alongX then
			return Vector3.new(d, y, lane)
		end
		return Vector3.new(lane, y, d)
	end
	local stripSize = Vector3.new(TILE - 1, 0.3, GRID * TILE)
	if alongX then
		stripSize = Vector3.new(GRID * TILE, 0.3, TILE - 1)
	end
	local strip = newPart({
		Name = "BoulderWarning",
		Size = stripSize,
		Position = at(0, FLOOR_TOP + 0.2),
		Color = Color3.fromRGB(255, 40, 40),
		Material = Enum.Material.Neon,
		Transparency = 0.5,
		CanCollide = false,
		Parent = world,
	})
	task.wait(0.9)
	strip:Destroy()
	local ball = newPart({
		Name = "Boulder",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(12, 12, 12),
		Color = Color3.fromRGB(120, 110, 105),
		Material = Enum.Material.Slate,
		CanCollide = false,
		Parent = world,
	})
	local d = -dir * reach
	local push = Vector3.new(0, 0, dir)
	if alongX then
		push = Vector3.new(dir, 0, 0)
	end
	while d * dir <= reach do
		local dt = task.wait()
		d = d + dir * 75 * dt
		local roll = CFrame.Angles(d / 6, 0, 0)
		if alongX then
			roll = CFrame.Angles(0, 0, -d / 6)
		end
		ball.CFrame = CFrame.new(at(d, FLOOR_TOP + 6)) * roll
		for p in pairs(alive) do
			local root = getRoot(p)
			if root and (root.Position - ball.Position).Magnitude < 8.5 then
				fling(p, push * 90 + Vector3.new(0, 60, 0))
			end
		end
	end
	ball:Destroy()
end

local function eventBoulders()
	local timer = 0.5
	forDuration(26, function(elapsed, dt)
		timer = timer - dt
		if timer <= 0 then
			timer = math.max(0.55, 1.3 - elapsed * 0.03)
			task.spawn(boulder)
		end
	end)
	task.wait(3.2)
end

local EVENTS = {
	{ name = "FALLING TILES", tip = "Red tiles are about to drop!", run = eventFallingTiles },
	{ name = "METEOR SHOWER", tip = "Stay out of the red circles!", run = eventMeteors },
	{ name = "THE SWEEPER", tip = "Jump over the bar!", run = eventSweeper },
	{ name = "RISING LAVA", tip = "Climb to the top!", run = eventRisingLava },
	{ name = "BOULDERS", tip = "Get out of the red lanes!", run = eventBoulders },
}

---------------------------------------------------------------- rounds

local roundLabel = nil

task.spawn(function()
	while true do
		task.wait(0.3)
		if roundLabel then
			status.Value = roundLabel .. "  |  Alive: " .. #aliveList()
		end
	end
end)

local function runRound(contestants)
	resetTiles(0)
	lava.Position = Vector3.new(0, LAVA_BASE_Y, 0)

	local spots = {}
	for _, t in ipairs(tiles) do
		table.insert(spots, t)
	end
	shuffle(spots)
	for n, p in ipairs(contestants) do
		local root = getRoot(p)
		if root then
			local spot = spots[(n - 1) % #spots + 1]
			p.Character:PivotTo(CFrame.new(spot.home + Vector3.new(0, 5, 0)))
			alive[p] = true
		end
	end

	roundLabel = "Get ready"
	banner("ROUND START", "Survive " .. EVENTS_PER_ROUND .. " disasters")
	task.wait(3)

	local order = {}
	for _, e in ipairs(EVENTS) do
		table.insert(order, e)
	end
	shuffle(order)

	for n = 1, EVENTS_PER_ROUND do
		if not anyAlive() then
			break
		end
		local event = order[n]
		roundLabel = "Disaster " .. n .. "/" .. EVENTS_PER_ROUND .. ": " .. event.name
		banner(event.name, event.tip)
		task.wait(2.5)
		event.run()
		task.wait(1)
		lava.Position = Vector3.new(0, LAVA_BASE_Y, 0)
		resetTiles(1.5)
		for p in pairs(alive) do
			addCoins(p, COINS_PER_EVENT)
		end
	end

	roundLabel = nil
	local winners = aliveList()
	if #winners > 0 then
		local names = {}
		for _, p in ipairs(winners) do
			table.insert(names, p.DisplayName)
			local d = data[p]
			if d then
				d.wins = d.wins + 1
				d.coins = d.coins + COINS_PER_WIN
				syncStats(p)
			end
			local root = getRoot(p)
			if root then
				p.Character:PivotTo(CFrame.new(lobbyPoint()))
			end
			task.spawn(savePlayer, p)
		end
		banner("WINNERS!", table.concat(names, ", "))
	else
		banner("EVERYONE DIED", "Better luck next round")
	end
	for p in pairs(alive) do
		alive[p] = nil
	end
	status.Value = "Round over"
	task.wait(4)
end

while true do
	for t = INTERMISSION, 1, -1 do
		status.Value = "Next round in " .. t .. "s"
		task.wait(1)
	end
	local contestants = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if getRoot(p) then
			table.insert(contestants, p)
		end
	end
	if #contestants == 0 then
		status.Value = "Waiting for players..."
		task.wait(2)
	else
		local ok, err = pcall(runRound, contestants)
		if not ok then
			warn("Round error: " .. tostring(err))
			roundLabel = nil
			for p in pairs(alive) do
				alive[p] = nil
			end
			task.wait(3)
		end
	end
end
