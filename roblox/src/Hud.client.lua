-- Chaos Arena: client script.
-- Shows the status bar and big announcements, and applies knockback.
-- Put this in StarterPlayer > StarterPlayerScripts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local status = ReplicatedStorage:WaitForChild("Status")
local bannerEvent = ReplicatedStorage:WaitForChild("Banner")
local flingEvent = ReplicatedStorage:WaitForChild("Fling")

local gui = Instance.new("ScreenGui")
gui.Name = "ChaosHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local bar = Instance.new("TextLabel")
bar.AnchorPoint = Vector2.new(0.5, 0)
bar.Position = UDim2.new(0.5, 0, 0, 44)
bar.Size = UDim2.new(0.6, 0, 0, 40)
bar.BackgroundColor3 = Color3.fromRGB(20, 16, 40)
bar.BackgroundTransparency = 0.25
bar.TextColor3 = Color3.new(1, 1, 1)
bar.Font = Enum.Font.FredokaOne
bar.TextScaled = true
bar.Text = status.Value
bar.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = bar

status.Changed:Connect(function(value)
	bar.Text = value
end)

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.new(0.5, 0, 0.3, 0)
title.Size = UDim2.new(0.9, 0, 0.12, 0)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(255, 220, 90)
title.TextStrokeTransparency = 0
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.TextTransparency = 1
title.Text = ""
title.Parent = gui

local subtitle = Instance.new("TextLabel")
subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
subtitle.Position = UDim2.new(0.5, 0, 0.4, 0)
subtitle.Size = UDim2.new(0.9, 0, 0.06, 0)
subtitle.BackgroundTransparency = 1
subtitle.TextColor3 = Color3.new(1, 1, 1)
subtitle.TextStrokeTransparency = 0
subtitle.Font = Enum.Font.FredokaOne
subtitle.TextScaled = true
subtitle.TextTransparency = 1
subtitle.Text = ""
subtitle.Parent = gui

local bannerId = 0
bannerEvent.OnClientEvent:Connect(function(text, sub)
	bannerId = bannerId + 1
	local id = bannerId
	title.Text = text
	subtitle.Text = sub or ""
	for _, label in ipairs({ title, subtitle }) do
		label.TextTransparency = 0
		label.TextStrokeTransparency = 0
	end
	task.wait(2.2)
	if id ~= bannerId then
		return
	end
	for _, label in ipairs({ title, subtitle }) do
		TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
end)

flingEvent.OnClientEvent:Connect(function(velocity)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if root and hum and hum.Health > 0 then
		hum:ChangeState(Enum.HumanoidStateType.FallingDown)
		root.AssemblyLinearVelocity = velocity
		task.delay(1.2, function()
			if hum.Health > 0 then
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	end
end)
