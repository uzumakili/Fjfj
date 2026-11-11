-- Lumen Garden: client script (put in StarterPlayer > StarterPlayerScripts).
-- Draws the whole interface and sends the player's choices to the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local stateEvent = ReplicatedStorage:WaitForChild("GardenState")
local actionEvent = ReplicatedStorage:WaitForChild("GardenAction")
local toastEvent = ReplicatedStorage:WaitForChild("GardenToast")

---------------------------------------------------------------- theme

local INK = Color3.fromRGB(22, 18, 38)
local CARD = Color3.fromRGB(40, 33, 66)
local CARD_HI = Color3.fromRGB(62, 52, 100)
local TEXT = Color3.fromRGB(244, 240, 252)
local MUTED = Color3.fromRGB(166, 156, 194)
local GOLD = Color3.fromRGB(255, 222, 150)
local ROSE = Color3.fromRGB(255, 158, 196)
local VIOLET = Color3.fromRGB(176, 148, 255)
local AQUA = Color3.fromRGB(128, 224, 236)
local FAMILY_HUE = { 0, 1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6 }
local FAMILY_NAMES = { "Crimson", "Amber", "Jade", "Aqua", "Azure", "Orchid" }

local BOLD = Enum.Font.GothamBold
local MEDIUM = Enum.Font.GothamMedium

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function corner(inst, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius) }, inst)
end

local function round(inst)
	return new("UICorner", { CornerRadius = UDim.new(1, 0) }, inst)
end

local function stroke(inst, color, thickness, transparency)
	return new("UIStroke", {
		Color = color or Color3.new(1, 1, 1),
		Thickness = thickness or 1,
		Transparency = transparency or 0.86,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
end

local function accent(inst, rotation)
	return new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, ROSE),
			ColorSequenceKeypoint.new(0.5, VIOLET),
			ColorSequenceKeypoint.new(1, AQUA),
		}),
		Rotation = rotation or 0,
	}, inst)
end

local function panel(props, parent)
	props.BackgroundColor3 = props.BackgroundColor3 or INK
	props.BackgroundTransparency = props.BackgroundTransparency or 0.1
	props.BorderSizePixel = 0
	local f = new("Frame", props, parent)
	corner(f, 18)
	stroke(f)
	return f
end

local function label(parent, text, size, font, color, props)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		Font = font or MEDIUM,
		TextColor3 = color or TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, size + 6),
	}, parent)
	if props then
		for k, v in pairs(props) do
			l[k] = v
		end
	end
	return l
end

-- a pill button; `filled` buttons use the accent gradient
local function button(parent, text, props, filled)
	local b = new("TextButton", {
		AutoButtonColor = false,
		Text = text,
		TextSize = 14,
		Font = BOLD,
		TextColor3 = filled and INK or TEXT,
		BackgroundColor3 = filled and Color3.new(1, 1, 1) or CARD,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 120, 0, 34),
	}, parent)
	for k, v in pairs(props or {}) do
		b[k] = v
	end
	round(b)
	if filled then
		accent(b, 20)
	else
		stroke(b)
	end
	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = filled and 0.12 or 0.25 }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 0 }):Play()
	end)
	return b
end

---------------------------------------------------------------- flower icon

local function traitsOf(genes)
	return {
		shape = genes.shape[1] + genes.shape[2] + 1,
		glow = genes.glow[1] + genes.glow[2] == 2,
		double = genes.double[1] + genes.double[2] == 2,
		giant = genes.giant[1] + genes.giant[2] == 2,
	}
end

-- draws a small flower out of rotated rounded frames, so every seed shows what it will become
local function flowerIcon(parent, genes, size, props)
	local t = traitsOf(genes)
	local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, size, 0, size) }, parent)
	for k, v in pairs(props or {}) do
		holder[k] = v
	end
	local r = size / 2
	local color = Color3.fromHSV(genes.hue, 0.62, 1)
	if t.glow then
		local halo = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(1.15, 0, 1.15, 0),
			BackgroundColor3 = color,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
		}, holder)
		round(halo)
	end
	local lengthK, widthK = 0.62, 0.8
	if t.shape == 2 then
		lengthK, widthK = 0.72, 0.5
	elseif t.shape == 3 then
		lengthK, widthK = 0.84, 0.3
	end
	local heart = r * 0.2
	local function ring(len, wid, offset, col, z)
		for k = 1, genes.petals do
			local a = (k + offset) / genes.petals * math.pi * 2
			local d = heart * 0.5 + len / 2
			local petal = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, r + math.sin(a) * d, 0, r - math.cos(a) * d),
				Size = UDim2.new(0, wid, 0, len),
				Rotation = math.deg(a),
				BackgroundColor3 = col,
				BorderSizePixel = 0,
				ZIndex = z,
			}, holder)
			round(petal)
		end
	end
	local len = r * lengthK
	ring(len, len * widthK, 0, color, 2)
	if t.double then
		ring(len * 0.6, len * 0.6 * widthK, 0.5, Color3.fromHSV(genes.hue, 0.3, 1), 3)
	end
	local dot = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(0, heart * 2, 0, heart * 2),
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, holder)
	round(dot)
	return holder
end

local function geneText(genes)
	local function pair(p, dominant, recessive)
		local s = ""
		for k = 1, 2 do
			s = s .. (p[k] == 1 and recessive or dominant)
		end
		return s
	end
	return "Glow " .. pair(genes.glow, "G", "g") .. "   Double " .. pair(genes.double, "D", "d")
		.. "   Giant " .. pair(genes.giant, "T", "t") .. "   Shape " .. pair(genes.shape, "R", "P")
end

---------------------------------------------------------------- layout

local gui = new("ScreenGui", {
	Name = "LumenGarden",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, player:WaitForChild("PlayerGui"))

local state = nil
local openPanel = nil

-- petals (top left)
local wallet = panel({ Position = UDim2.new(0, 14, 0, 14), Size = UDim2.new(0, 168, 0, 46) }, gui)
local walletIcon = flowerIcon(wallet, {
	hue = 0.92, petals = 6, glow = { 0, 0 }, double = { 0, 0 }, giant = { 0, 0 }, shape = { 0, 0 },
}, 30, { Position = UDim2.new(0, 10, 0.5, -15) })
walletIcon.Name = "Icon"
local walletText = label(wallet, "0", 20, BOLD, TEXT, {
	Position = UDim2.new(0, 48, 0, 4), Size = UDim2.new(1, -56, 0, 24),
})
label(wallet, "petals", 11, MEDIUM, MUTED, { Position = UDim2.new(0, 48, 0, 25), Size = UDim2.new(1, -56, 0, 14) })

-- menu buttons (top right)
local menu = new("Frame", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -14, 0, 14),
	Size = UDim2.new(0, 220, 0, 46),
	BackgroundTransparency = 1,
}, gui)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 8),
}, menu)
local journalButton = button(menu, "Journal", { Size = UDim2.new(0, 100, 0, 40) })
local upgradeButton = button(menu, "Upgrades", { Size = UDim2.new(0, 100, 0, 40) })

-- current order (top centre)
local orderChip = new("TextButton", {
	AutoButtonColor = false,
	Text = "",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 14),
	Size = UDim2.new(0.5, 0, 0, 46),
	BackgroundColor3 = INK,
	BackgroundTransparency = 0.1,
	BorderSizePixel = 0,
}, gui)
corner(orderChip, 18)
stroke(orderChip)
new("UISizeConstraint", { MaxSize = Vector2.new(470, 46), MinSize = Vector2.new(220, 46) }, orderChip)
local orderDot = new("Frame", {
	Position = UDim2.new(0, 14, 0.5, -7), Size = UDim2.new(0, 14, 0, 14), BorderSizePixel = 0,
	BackgroundColor3 = ROSE,
}, orderChip)
round(orderDot)
label(orderChip, "THE LANTERN ASKS FOR", 10, BOLD, MUTED, {
	Position = UDim2.new(0, 38, 0, 5), Size = UDim2.new(1, -120, 0, 14),
})
local orderText = label(orderChip, "", 15, BOLD, TEXT, {
	Position = UDim2.new(0, 38, 0, 20), Size = UDim2.new(1, -120, 0, 20),
	TextTruncate = Enum.TextTruncate.AtEnd,
})
local orderReward = label(orderChip, "", 15, BOLD, GOLD, {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.new(0, 70, 0, 20),
	TextXAlignment = Enum.TextXAlignment.Right,
})

-- toasts
local toasts = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 70),
	Size = UDim2.new(0, 380, 0, 300),
	BackgroundTransparency = 1,
}, gui)
new("UIListLayout", {
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, toasts)
local toastOrder = 0

local function showToast(title, detail, hue)
	toastOrder = toastOrder + 1
	local t = new("CanvasGroup", {
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.06,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		LayoutOrder = toastOrder,
	}, toasts)
	corner(t, 16)
	stroke(t)
	local dot = new("Frame", {
		Position = UDim2.new(0, 16, 0.5, -6), Size = UDim2.new(0, 12, 0, 12), BorderSizePixel = 0,
		BackgroundColor3 = hue and Color3.fromHSV(hue, 0.6, 1) or VIOLET,
	}, t)
	round(dot)
	label(t, title, 15, BOLD, TEXT, { Position = UDim2.new(0, 40, 0, 7), Size = UDim2.new(1, -52, 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd })
	label(t, detail, 12, MEDIUM, MUTED, { Position = UDim2.new(0, 40, 0, 27), Size = UDim2.new(1, -52, 0, 16),
		TextTruncate = Enum.TextTruncate.AtEnd })
	TweenService:Create(t, TweenInfo.new(0.25), { GroupTransparency = 0 }):Play()
	task.delay(3.4, function()
		local fade = TweenService:Create(t, TweenInfo.new(0.4), { GroupTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		t:Destroy()
	end)
end

-- seed tray (bottom)
local tray = panel({
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -12),
	Size = UDim2.new(1, -24, 0, 124),
}, gui)
new("UISizeConstraint", { MaxSize = Vector2.new(780, 124) }, tray)
local trayTitle = label(tray, "SEEDS", 11, BOLD, MUTED, { Position = UDim2.new(0, 16, 0, 8), Size = UDim2.new(0, 200, 0, 16) })
local wildButton = button(tray, "+ Wild seed", {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 6), Size = UDim2.new(0, 150, 0, 24), TextSize = 12,
})
local seedList = new("ScrollingFrame", {
	Position = UDim2.new(0, 12, 0, 34),
	Size = UDim2.new(1, -24, 0, 84),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = MUTED,
	ScrollingDirection = Enum.ScrollingDirection.X,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.X,
}, tray)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, seedList)
local emptyHint = label(tray, "No seeds. Harvest a flower or buy a wild seed.", 13, MEDIUM, MUTED, {
	Position = UDim2.new(0, 16, 0, 60), Size = UDim2.new(1, -32, 0, 20), Visible = false,
})

-- selected seed details (above the tray)
local detail = panel({
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -146),
	Size = UDim2.new(1, -24, 0, 112),
	Visible = false,
}, gui)
new("UISizeConstraint", { MaxSize = Vector2.new(440, 112) }, detail)
local detailIcon = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 14), Size = UDim2.new(0, 64, 0, 64) }, detail)
local detailName = label(detail, "", 16, BOLD, TEXT, { Position = UDim2.new(0, 92, 0, 10), Size = UDim2.new(1, -200, 0, 22),
	TextTruncate = Enum.TextTruncate.AtEnd })
local detailInfo = label(detail, "", 12, MEDIUM, MUTED, { Position = UDim2.new(0, 92, 0, 32), Size = UDim2.new(1, -104, 0, 16) })
local detailGenes = label(detail, "", 12, MEDIUM, AQUA, { Position = UDim2.new(0, 92, 0, 50), Size = UDim2.new(1, -104, 0, 16),
	TextTruncate = Enum.TextTruncate.AtEnd })
label(detail, "Walk to empty soil and press E to plant. Neighbouring blooms cross-breed.", 11, MEDIUM, MUTED, {
	Position = UDim2.new(0, 14, 0, 86), Size = UDim2.new(1, -28, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd,
})
local sellButton = button(detail, "Sell", {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.new(0, 96, 0, 28), TextSize = 12,
})

---------------------------------------------------------------- panels

local function makePanel(title)
	local p = new("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.46, 0),
		Size = UDim2.new(0.92, 0, 0.72, 0),
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		Visible = false,
	}, gui)
	corner(p, 22)
	stroke(p)
	new("UISizeConstraint", { MaxSize = Vector2.new(440, 500) }, p)
	local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 4), BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1) }, p)
	accent(bar)
	label(p, title, 20, BOLD, TEXT, { Position = UDim2.new(0, 22, 0, 18), Size = UDim2.new(1, -90, 0, 26) })
	local close = button(p, "Close", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 16), Size = UDim2.new(0, 66, 0, 28), TextSize = 12,
	})
	local body = new("Frame", { Position = UDim2.new(0, 22, 0, 58), Size = UDim2.new(1, -44, 1, -76), BackgroundTransparency = 1 }, p)
	return p, body, close
end

local journalPanel, journalBody, journalClose = makePanel("Journal")
local upgradePanel, upgradeBody, upgradeClose = makePanel("Upgrades")
local orderPanel, orderBody, orderClose = makePanel("The Lantern's Order")

local function setPanel(target)
	if openPanel == target then
		target = nil
	end
	for _, p in ipairs({ journalPanel, upgradePanel, orderPanel }) do
		if p == target then
			p.Visible = true
			TweenService:Create(p, TweenInfo.new(0.2), { GroupTransparency = 0 }):Play()
		elseif p.Visible then
			p.GroupTransparency = 1
			p.Visible = false
		end
	end
	openPanel = target
end

journalButton.Activated:Connect(function() setPanel(journalPanel) end)
upgradeButton.Activated:Connect(function() setPanel(upgradePanel) end)
orderChip.Activated:Connect(function() setPanel(orderPanel) end)
journalClose.Activated:Connect(function() setPanel(nil) end)
upgradeClose.Activated:Connect(function() setPanel(nil) end)
orderClose.Activated:Connect(function() setPanel(nil) end)

-- journal
local journalCountText = label(journalBody, "0 / 144 varieties", 14, BOLD, TEXT, { Size = UDim2.new(1, 0, 0, 18) })
local journalTrack = new("Frame", {
	Position = UDim2.new(0, 0, 0, 24), Size = UDim2.new(1, 0, 0, 8), BorderSizePixel = 0, BackgroundColor3 = CARD,
}, journalBody)
round(journalTrack)
local journalFill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1) }, journalTrack)
round(journalFill)
accent(journalFill)
label(journalBody, "Each square is one variety: 3 shapes x Glowing x Double x Giant.", 11, MEDIUM, MUTED, {
	Position = UDim2.new(0, 0, 0, 38), Size = UDim2.new(1, 0, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd,
})
local journalScroll = new("ScrollingFrame", {
	Position = UDim2.new(0, 0, 0, 62), Size = UDim2.new(1, 0, 1, -62), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 3, ScrollBarImageColor3 = MUTED, CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, journalBody)
new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, journalScroll)

local journalCells = {}
for fam = 1, 6 do
	local section = new("Frame", { Size = UDim2.new(1, -6, 0, 78), BackgroundTransparency = 1, LayoutOrder = fam }, journalScroll)
	label(section, string.upper(FAMILY_NAMES[fam]), 11, BOLD, Color3.fromHSV(FAMILY_HUE[fam], 0.4, 1), { Size = UDim2.new(1, 0, 0, 14) })
	local grid = new("Frame", { Position = UDim2.new(0, 0, 0, 18), Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1 }, section)
	new("UIGridLayout", {
		CellSize = UDim2.new(0, 24, 0, 24), CellPadding = UDim2.new(0, 6, 0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	local order = 0
	for shape = 1, 3 do
		for bits = 0, 7 do
			order = order + 1
			local glow = bits % 2
			local double = math.floor(bits / 2) % 2
			local giant = math.floor(bits / 4) % 2
			local cell = new("Frame", { BackgroundColor3 = CARD, BorderSizePixel = 0, LayoutOrder = order }, grid)
			corner(cell, 7)
			journalCells[fam .. "_" .. shape .. "_" .. glow .. double .. giant] = {
				frame = cell,
				color = Color3.fromHSV(FAMILY_HUE[fam], 0.35 + 0.1 * (glow + double + giant), 1),
			}
		end
	end
end

-- upgrades
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, upgradeBody)
local upgradeRows = {}

local function upgradeRow(key, order)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 58), BackgroundColor3 = CARD, BorderSizePixel = 0, LayoutOrder = order }, upgradeBody)
	corner(row, 14)
	local name = label(row, "", 15, BOLD, TEXT, { Position = UDim2.new(0, 14, 0, 8), Size = UDim2.new(1, -150, 0, 20) })
	local desc = label(row, "", 12, MEDIUM, MUTED, { Position = UDim2.new(0, 14, 0, 30), Size = UDim2.new(1, -150, 0, 16),
		TextTruncate = Enum.TextTruncate.AtEnd })
	local buy = button(row, "", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.new(0, 110, 0, 34) }, true)
	buy.Activated:Connect(function()
		actionEvent:FireServer("upgrade", key)
	end)
	upgradeRows[key] = { name = name, desc = desc, buy = buy }
	return upgradeRows[key]
end

-- order panel
label(orderBody, "REQUEST", 11, BOLD, MUTED, { Size = UDim2.new(1, 0, 0, 14) })
local orderBig = label(orderBody, "", 20, BOLD, TEXT, {
	Position = UDim2.new(0, 0, 0, 20), Size = UDim2.new(1, 0, 0, 56), TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
})
local orderBigReward = label(orderBody, "", 16, BOLD, GOLD, { Position = UDim2.new(0, 0, 0, 82), Size = UDim2.new(1, 0, 0, 22) })
label(orderBody, "Grow a flower that matches, then stand by it and press F to deliver it. "
	.. "Colours you cannot buy are made by planting two colours side by side and harvesting.", 13, MEDIUM, MUTED, {
	Position = UDim2.new(0, 0, 0, 116), Size = UDim2.new(1, 0, 0, 80), TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
})
local orderDone = label(orderBody, "", 12, MEDIUM, MUTED, { Position = UDim2.new(0, 0, 0, 204), Size = UDim2.new(1, 0, 0, 16) })
local rerollButton = button(orderBody, "New order", { Position = UDim2.new(0, 0, 0, 232), Size = UDim2.new(0, 190, 0, 36) })

---------------------------------------------------------------- render

local function selectedSeed()
	if not state then
		return nil
	end
	for _, seed in ipairs(state.seeds) do
		if seed.id == state.selected then
			return seed
		end
	end
	return nil
end

local function renderSeeds()
	for _, child in ipairs(seedList:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	trayTitle.Text = "SEEDS  " .. #state.seeds .. " / " .. state.bag
	emptyHint.Visible = #state.seeds == 0
	for i, seed in ipairs(state.seeds) do
		local chosen = seed.id == state.selected
		local card = new("TextButton", {
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.new(0, 68, 0, 78),
			BackgroundColor3 = chosen and CARD_HI or CARD,
			BorderSizePixel = 0,
			LayoutOrder = i,
		}, seedList)
		corner(card, 14)
		if chosen then
			local s = stroke(card, Color3.new(1, 1, 1), 2, 0)
			accent(s, 45)
		end
		flowerIcon(card, seed.genes, 46, { Position = UDim2.new(0.5, -23, 0, 6) })
		label(card, tostring(seed.genes.petals) .. " petals", 10, MEDIUM, MUTED, {
			Position = UDim2.new(0, 0, 1, -19), Size = UDim2.new(1, 0, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		card.Activated:Connect(function()
			actionEvent:FireServer("select", seed.id)
		end)
	end

	local seed = selectedSeed()
	detail.Visible = seed ~= nil
	if seed then
		detailIcon:ClearAllChildren()
		flowerIcon(detailIcon, seed.genes, 64)
		detailName.Text = seed.name
		detailInfo.Text = "Worth " .. seed.value .. " petals   -   grows in " .. seed.grow .. "s"
		if state.lens then
			detailGenes.Text = geneText(seed.genes)
			detailGenes.TextColor3 = AQUA
		else
			detailGenes.Text = "Hidden genes unknown. Unlock the Gene Lens in Upgrades."
			detailGenes.TextColor3 = MUTED
		end
		sellButton.Text = "Sell  +" .. math.floor(seed.value * 0.4)
	end
end

local function render()
	walletText.Text = tostring(state.petals)
	orderText.Text = state.order.text
	orderReward.Text = "+" .. state.order.reward
	orderDot.BackgroundColor3 = Color3.fromHSV(FAMILY_HUE[state.order.family], 0.6, 1)
	orderBig.Text = state.order.text
	orderBigReward.Text = "Reward: " .. state.order.reward .. " petals"
	orderDone.Text = "Orders delivered: " .. state.ordersDone
	rerollButton.Text = "New order  -  " .. state.rerollCost .. " petals"
	wildButton.Text = "+ Wild seed  -  " .. state.wildCost

	renderSeeds()

	local found = {}
	for _, key in ipairs(state.journal) do
		found[key] = true
	end
	for key, cell in pairs(journalCells) do
		cell.frame.BackgroundColor3 = found[key] and cell.color or CARD
	end
	journalCountText.Text = #state.journal .. " / " .. state.journalTotal .. " varieties"
	journalFill.Size = UDim2.new(#state.journal / state.journalTotal, 0, 1, 0)

	for i, up in ipairs(state.upgrades) do
		local row = upgradeRows[up.key] or upgradeRow(up.key, i)
		row.name.Text = up.name .. (up.max > 1 and ("   Lv " .. up.level .. " / " .. up.max) or "")
		row.desc.Text = up.desc
		if up.level >= up.max then
			row.buy.Text = up.max > 1 and "MAX" or "OWNED"
			row.buy.BackgroundTransparency = 0.6
		else
			row.buy.Text = tostring(up.cost)
			row.buy.BackgroundTransparency = state.petals >= up.cost and 0 or 0.6
		end
	end
end

stateEvent.OnClientEvent:Connect(function(newState)
	state = newState
	render()
end)

toastEvent.OnClientEvent:Connect(showToast)

sellButton.Activated:Connect(function()
	if state and state.selected then
		actionEvent:FireServer("sell", state.selected)
	end
end)

wildButton.Activated:Connect(function()
	actionEvent:FireServer("wild")
end)

rerollButton.Activated:Connect(function()
	actionEvent:FireServer("reroll")
end)

-- ask for the first snapshot, and keep asking until the server has loaded our garden
task.spawn(function()
	while not state do
		actionEvent:FireServer("ready")
		task.wait(1)
	end
	showToast("Welcome to Lumen Garden", "Pick a seed below, then press E at a patch of soil")
end)
