-- Test scenarios for Neon Canvas. Each one boots the game inside the mock engine, lets scripted
-- testers play, and checks that nothing broke.

local Scenarios = { names = {}, defs = {} }
local DT = 1 / 30

local function scenario(name, fn)
	table.insert(Scenarios.names, name)
	Scenarios.defs[name] = fn
end

---------------------------------------------------------------------------------------------------
-- Harness: helpers shared by every scenario
---------------------------------------------------------------------------------------------------

local function newHarness(M, serverSrc, clientSrc)
	local H = { M = M, failures = {}, notes = {}, states = {}, feed = {}, results = {}, brains = {} }

	function H.check(cond, msg)
		if not cond then
			table.insert(H.failures, msg)
		end
		return cond
	end

	function H.note(msg)
		table.insert(H.notes, msg)
	end

	function H.shared()
		return M.find("ReplicatedStorage/NeonCanvas")
	end

	function H.attr(name)
		local s = H.shared()
		return s and s:GetAttribute(name)
	end

	function H.state()
		return H.attr("State")
	end

	function H.startServer()
		M.run(serverSrc, "NeonCanvas.server", M.server)
		local s = H.shared()
		if H.check(s ~= nil, "the server script did not create ReplicatedStorage.NeonCanvas") then
			s:GetAttributeChangedSignal("State"):Connect(function()
				table.insert(H.states, { t = M.now(), state = s:GetAttribute("State") })
			end)
		end
	end

	-- adds a player; with `client` true their client script runs too
	function H.join(name, userId, client)
		local player, context = M.addPlayer(name, userId)
		if client then
			M.run(clientSrc, "NeonCanvas.client", context)
		end
		-- listen the way a client would, to record what the server announces
		M.as(context, function()
			local s = H.shared()
			s.Feed.OnClientEvent:Connect(function(kind, ...)
				table.insert(H.feed, { t = M.now(), kind = kind, args = { ... }, to = name })
			end)
			s.Results.OnClientEvent:Connect(function(data)
				table.insert(H.results, { t = M.now(), data = data, to = name })
			end)
		end)
		return player, context
	end

	function H.advance(seconds, each)
		local steps = math.floor(seconds / DT + 0.5)
		for _ = 1, steps do
			local t = M.now()
			for _, brain in ipairs(H.brains) do
				brain(t)
			end
			if each then
				each(t)
			end
			M.step(DT)
		end
	end

	-- steps until the match state becomes `state`; returns false on time-out
	function H.waitFor(state, timeout)
		local limit = M.now() + timeout
		while M.now() < limit do
			if H.state() == state then
				return true
			end
			H.advance(DT)
		end
		return H.check(false, "timed out after " .. timeout .. "s waiting for state " .. state .. " (stuck in " .. tostring(H.state()) .. ")")
	end

	function H.dots()
		local folder = M.find("Workspace/NeonCanvas/Tiles")
		return folder and folder:GetChildren() or {}
	end

	-- A tester who walks between random dots and jumps now and then.
	function H.walker(player)
		local target, retarget = nil, 0
		table.insert(H.brains, function(t)
			local pos = M.position(player)
			if not pos then
				return
			end
			if not target or t >= retarget then
				local dots = H.dots()
				if #dots > 0 then
					target = dots[math.random(#dots)].Position
				end
				retarget = t + 2 + math.random() * 4
			end
			if target then
				local dx, dz = target.X - pos.X, target.Z - pos.Z
				local d = math.sqrt(dx * dx + dz * dz)
				if d > 2 then
					M.move(player, dx / d, dz / d)
				else
					M.move(player, 0, 0)
					target = nil
				end
			end
			if math.random() < 0.01 then
				M.jump(player)
			end
		end)
	end

	-- A tester who uses mouse and keyboard through the real client script.
	function H.keyboardPlayer()
		local Enum = M.Enum
		local keys = { Enum.KeyCode.Q, Enum.KeyCode.LeftShift, Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.F }
		local nextAct, held = 0, false
		table.insert(H.brains, function(t)
			if t < nextAct then
				return
			end
			nextAct = t + 0.15 + math.random() * 0.4
			M.mouseMove(200 + math.random() * 880, 120 + math.random() * 480)
			local roll = math.random()
			if roll < 0.25 then
				held = not held
				M.mouseButton(held)
			elseif roll < 0.5 then
				local key = keys[math.random(#keys)]
				M.key(key, true)
				M.key(key, false)
			elseif roll < 0.53 then
				M.wheel(math.random() < 0.5 and 1 or -1)
			end
		end)
	end

	-- A tester who taps any button currently on screen, like a curious (or careless) player.
	function H.clicker(player, every)
		local nextClick = 0
		table.insert(H.brains, function(t)
			if t < nextClick then
				return
			end
			nextClick = t + every * (0.5 + math.random())
			local buttons = M.visibleButtons(player.PlayerGui)
			if #buttons > 0 then
				M.click(buttons[math.random(#buttons)])
			end
		end)
	end

	-- A tester with no client script: sends actions straight to the server.
	function H.remotePlayer(player, context)
		local nextAct = 0
		local actions = { "primary", "primary", "primary", "dash", "a1", "a2", "ult" }
		table.insert(H.brains, function(t)
			if t < nextAct then
				return
			end
			nextAct = t + 0.2 + math.random() * 0.3
			local pos = M.position(player)
			if pos and H.state() == "Playing" then
				M.as(context, function()
					H.shared().Act:FireServer(actions[math.random(#actions)],
						pos.X + (math.random() - 0.5) * 80, pos.Z + (math.random() - 0.5) * 80)
				end)
			end
		end)
	end

	-- Reads every piece of text on a player's screen now and then. Text such as "nil" or "nan"
	-- means a value was missing when the label was written.
	function H.textWatch(player)
		local nextLook, reported = 0, false
		table.insert(H.brains, function(t)
			if t < nextLook or reported then
				return
			end
			nextLook = t + 1.7
			for _, inst in ipairs(M.descendants(player.PlayerGui)) do
				if inst:IsA("TextLabel") or inst:IsA("TextButton") then
					local text = string.lower(inst.Text)
					if string.find(text, "%f[%a]nil%f[%A]") or string.find(text, "%f[%a]nan%f[%A]") or string.find(text, "%f[%a]inf%f[%A]")
						or string.find(text, "table: ", 1, true) or string.find(text, "function: ", 1, true) then
						reported = true
						H.check(false, "suspicious text on screen in " .. inst:GetFullName() .. ": \"" .. inst.Text .. "\"")
						return
					end
				end
			end
		end)
	end

	function H.countFeed(kind)
		local n = 0
		for _, f in ipairs(H.feed) do
			if f.kind == kind then
				n = n + 1
			end
		end
		return n
	end

	-- the usual end-of-scenario checks
	function H.finish()
		for _, w in ipairs(M.warnings) do
			if string.find(w, "NeonCanvas", 1, true) or string.find(w, "Infinite yield", 1, true) then
				H.check(false, "warning: " .. string.sub(w, 1, 200))
				break
			end
		end
		local used = {}
		for id, n in pairs(M.deprecated) do
			table.insert(used, id .. " x" .. n)
		end
		if #used > 0 then
			table.sort(used)
			H.note("deprecated API used: " .. table.concat(used, ", "))
		end
		return { failures = H.failures, notes = H.notes }
	end

	function H.bots()
		local folder = M.find("Workspace/NeonCanvas/Bots")
		return folder and folder:GetChildren() or {}
	end

	function H.ownedDots()
		local a, b = 0, 0
		for _, dot in ipairs(H.dots()) do
			local team = dot:GetAttribute("T")
			if team == 1 then
				a = a + 1
			elseif team == 2 then
				b = b + 1
			end
		end
		return a, b
	end

	-- Plays one whole cycle (countdown, match, results, back to intermission) and checks it.
	-- `humans` is the list of players expected to take part.
	function H.playRound(humans, opts)
		opts = opts or {}
		local tag = "round " .. tostring(H.attr("Round")) .. ": "
		if not H.waitFor("Countdown", 60) then
			return nil
		end
		local mode, map = H.attr("Mode"), H.attr("MapName")
		tag = "round " .. tostring(H.attr("Round")) .. " (" .. tostring(mode) .. " on " .. tostring(map) .. "): "
		H.advance(1)
		local fighters = #H.bots() + #humans
		H.check(fighters >= 8, tag .. "only " .. fighters .. " fighters at countdown")
		H.check(fighters % 2 == 0 or #humans > 8, tag .. "teams are uneven: " .. fighters .. " fighters")
		for _, p in ipairs(humans) do
			local team = p:GetAttribute("Team")
			H.check(team == 1 or team == 2, tag .. p.Name .. " has no team at countdown (Team=" .. tostring(team) .. ")")
		end
		local a0, b0 = H.ownedDots()
		H.check(a0 > 5 and b0 > 5, tag .. "bases were not pre-painted (" .. a0 .. ", " .. b0 .. ")")
		if not H.waitFor("Playing", 15) then
			return nil
		end
		local started = M.now()
		local feedStart, resultStart = #H.feed, #H.results
		local maxFx, maxProps, aliveSamples, samples = 0, 0, 0, 0
		local limit = M.now() + 175
		while H.state() == "Playing" and M.now() < limit do
			H.advance(1)
			local fx = M.find("Workspace/NeonFx")
			if fx then
				maxFx = math.max(maxFx, #fx:GetChildren())
			end
			maxProps = math.max(maxProps, #M.find("Workspace/NeonCanvas/Props"):GetChildren())
			samples = samples + 1
			if humans[1] and M.isAlive(humans[1]) then
				aliveSamples = aliveSamples + 1
			end
		end
		H.check(H.state() == "Results", tag .. "the match did not end (state " .. tostring(H.state()) .. ")")
		local duration = M.now() - started
		H.advance(1.5)
		local card = humans[1] and humans[1].PlayerGui:FindFirstChild("NeonCanvasResults")
		if card then
			H.check(card.Enabled, tag .. "the results card is not showing")
		end
		local a, b, total = H.attr("ScoreA"), H.attr("ScoreB"), H.attr("Total")
		if mode == "Turf" then
			local da, db = H.ownedDots()
			H.check(da == a and db == b, tag .. "scoreboard says " .. tostring(a) .. "/" .. tostring(b) .. " but the floor has " .. da .. "/" .. db)
			H.check(a + b <= total, tag .. "more dots owned than exist")
			H.check(a + b > total * 0.5, tag .. "less than half the floor was painted (" .. (a + b) .. " of " .. tostring(total) .. ")")
		else
			H.check(a + b > 0, tag .. "nobody scored")
		end
		local kos, fell, pickups, ults = 0, 0, 0, 0
		local seen = {}
		for i = feedStart + 1, #H.feed do
			local f = H.feed[i]
			if f.to == H.feed[feedStart + 1].to then   -- count each announcement once
				if f.kind == "ko" then
					kos = kos + 1
				elseif f.kind == "fell" then
					fell = fell + 1
				elseif f.kind == "pickup" then
					pickups = pickups + 1
				elseif f.kind == "ult" then
					ults = ults + 1
				end
				seen[f.kind] = true
			end
		end
		H.check(seen.start, tag .. "no start announcement reached the clients")
		H.check(seen["end"], tag .. "no end announcement reached the clients")
		if not opts.quiet then
			H.check(kos > 0, tag .. "no knock-outs in a whole match")
		end
		local row = nil
		local got = 0
		for i = resultStart + 1, #H.results do
			local r = H.results[i]
			got = got + 1
			local data = r.data
			H.check(type(data) == "table" and type(data.rows) == "table", tag .. "results payload is malformed")
			if type(data) == "table" and type(data.rows) == "table" then
				local wantWinner = 0
				if a > b then
					wantWinner = 1
				elseif b > a then
					wantWinner = 2
				end
				H.check(data.winner == wantWinner, tag .. "winner " .. tostring(data.winner) .. " does not match the score " .. tostring(a) .. "/" .. tostring(b))
				H.check(#data.rows >= 8, tag .. "results list has only " .. #data.rows .. " rows")
				H.check(type(data.reward) == "table" and data.reward.xp > 0, tag .. "no reward in results for " .. r.to)
				if humans[1] and r.to == humans[1].Name then
					for _, entry in ipairs(data.rows) do
						if entry.id == data.me then
							row = entry
						end
					end
					H.lastResult = data
				end
			end
		end
		H.check(got == #humans, tag .. got .. " result cards sent for " .. #humans .. " players")
		H.note(string.format("%s%ds, score %s-%s of %s, %d KOs, %d falls, %d pickups, %d ults, fx<=%d props<=%d, tester alive %d%%%s",
			tag, math.floor(duration), tostring(a), tostring(b), tostring(total), kos, fell, pickups, ults, maxFx, maxProps,
			samples > 0 and math.floor(aliveSamples / samples * 100) or 0,
			row and (", tester row: dots " .. tostring(row.d) .. " KOs " .. tostring(row.k) .. " deaths " .. tostring(row.x)) or ""))
		H.check(maxFx < 900, tag .. "effects pile up on the client (" .. maxFx .. " at once)")
		if not H.waitFor("Intermission", 30) then
			return nil
		end
		H.advance(1)
		if card then
			H.check(not card.Enabled, tag .. "the results card is still showing in the intermission")
		end
		H.check(#H.bots() == 0, tag .. #H.bots() .. " bots left over after the match")
		H.check(#M.find("Workspace/NeonCanvas/Props"):GetChildren() == 0, tag .. "props left over after the match")
		for _, p in ipairs(humans) do
			H.check(p:GetAttribute("Team") == 0, tag .. p.Name .. " still has a team in the intermission")
		end
		return { mode = mode, map = map, a = a, b = b, total = total, kos = kos, fell = fell, row = row, duration = duration }
	end

	return H
end

---------------------------------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------------------------------

scenario("smoke", function(H, M)
	H.startServer()
	H.advance(1)
	local player = H.join("Tester", 101, true)
	H.advance(6)
	H.check(H.state() == "Intermission", "expected Intermission shortly after start, got " .. tostring(H.state()))
	H.check(#H.dots() > 100, "the arena has only " .. #H.dots() .. " dots")
	H.check(M.position(player) ~= nil, "the player has no living character after 6 seconds")
	local gui = player.PlayerGui
	H.check(gui:FindFirstChild("NeonCanvasHud") ~= nil, "the client did not build its HUD")
	H.check(gui:FindFirstChild("NeonCanvasMenu") ~= nil, "the client did not build its menu")
	local pos = M.position(player)
	H.check(pos and pos.Y > 60, "the player is not standing on the waiting deck (y=" .. tostring(pos and pos.Y) .. ")")
	H.note("dots: " .. #H.dots() .. ", workspace instances: " .. M.count(M.workspace) .. ", gui instances: " .. M.count(gui))
end)

-- One player on keyboard and mouse plays three matches in a row: one of each mode.
scenario("solo_pc_three_modes", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player = H.join("Tester", 101, true)
	H.walker(player)
	H.keyboardPlayer()
	H.clicker(player, 5)
	H.textWatch(player)
	local modes = {}
	local matches0 = nil
	for _ = 1, 3 do
		local r = H.playRound({ player })
		if not r then
			return
		end
		modes[r.mode] = true
		H.check(r.row ~= nil, "the tester is missing from the results list")
	end
	H.check(modes.Turf and modes.Beacons and modes.KO, "not every mode was played")
	H.check(player:GetAttribute("Matches") == 3, "Matches attribute is " .. tostring(player:GetAttribute("Matches")) .. " after 3 matches")
	H.check((player:GetAttribute("Lvl") or 0) >= 2, "the tester did not level up after 3 matches (Lvl " .. tostring(player:GetAttribute("Lvl")) .. ")")
	H.note("after 3 matches: level " .. tostring(player:GetAttribute("Lvl")) .. ", rating " .. tostring(player:GetAttribute("Rating"))
		.. ", coins " .. tostring(player:GetAttribute("Coins")) .. ", loadout " .. tostring(player:GetAttribute("Primary")) .. "/"
		.. tostring(player:GetAttribute("A1")) .. "/" .. tostring(player:GetAttribute("A2")))
end)

-- The same on a phone: touch buttons instead of keys, automatic aim.
scenario("solo_touch", function(H, M)
	M.setDevice("touch")
	M.setViewport(844, 390)
	H.startServer()
	H.advance(0.5)
	local player = H.join("Phone", 102, true)
	H.walker(player)
	H.clicker(player, 0.35)
	H.textWatch(player)
	local r = H.playRound({ player })
	if r then
		H.check(player.PlayerGui:FindFirstChild("NeonCanvasTouch") ~= nil, "no touch buttons were built on a touch device")
		H.check(r.row and r.row.d > 0, "the phone tester painted nothing")
	end
end)

-- A player who never touches anything. The match must still run and reward them.
scenario("idle_player", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player = H.join("Sleepy", 103, true)
	local r = H.playRound({ player })
	if r then
		H.check(player:GetAttribute("Matches") == 1, "an idle player got no match credit")
	end
end)

-- Every map once, with a wandering tester, to check the layouts and how often anyone falls off.
scenario("all_maps", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player = H.join("Tester", 104, true)
	H.walker(player)
	H.keyboardPlayer()
	local maps = {}
	for _ = 1, 5 do
		local r = H.playRound({ player })
		if not r then
			return
		end
		maps[r.map] = true
		H.check(r.total >= 150, r.map .. " has only " .. tostring(r.total) .. " dots")
	end
	local n = 0
	for _ in pairs(maps) do
		n = n + 1
	end
	H.check(n == 5, "expected 5 different maps, saw " .. n)
end)

-- People arriving and leaving at awkward moments.
scenario("join_and_leave", function(H, M)
	H.startServer()
	H.advance(0.5)
	local alice = H.join("Alice", 201, true)
	H.walker(alice)
	H.keyboardPlayer()
	H.waitFor("Playing", 60)
	H.advance(20)
	-- Bob arrives mid-match and should take a bot's place
	local before = #H.bots()
	local bob, bobCtx = H.join("Bob", 202, false)
	H.walker(bob)
	H.remotePlayer(bob, bobCtx)
	H.advance(8)
	H.check(#H.bots() == before - 1, "a late joiner should replace one bot (bots " .. before .. " -> " .. #H.bots() .. ")")
	local team = bob:GetAttribute("Team")
	H.check(team == 1 or team == 2, "the late joiner has no team (Team=" .. tostring(team) .. ")")
	H.check(team ~= alice:GetAttribute("Team"), "two humans were put on the same team while the other had none")
	local pos = M.position(bob)
	H.check(pos and pos.Y < 60, "the late joiner was not moved into the arena (y=" .. tostring(pos and pos.Y) .. ")")
	H.waitFor("Results", 170)
	H.waitFor("Intermission", 30)
	-- next match: Bob leaves in the middle and a bot should take over
	H.waitFor("Playing", 60)
	H.advance(15)
	local botsBefore = #H.bots()
	M.removePlayer(bob)
	H.advance(3)
	H.check(#H.bots() == botsBefore + 1, "a bot should replace a player who leaves (bots " .. botsBefore .. " -> " .. #H.bots() .. ")")
	H.waitFor("Results", 170)
	H.advance(3)
	-- Alice leaves during the results; the server is now empty and should idle without errors
	M.removePlayer(alice)
	H.brains = {}
	H.advance(120)
	H.check(H.state() == "Intermission", "an empty server should wait in Intermission, got " .. tostring(H.state()))
	-- somebody new arrives: a fresh intermission, then a normal match
	local carol = H.join("Carol", 203, true)
	H.walker(carol)
	H.advance(2)
	local left = (H.attr("EndsAt") or 0) - M.workspace:GetServerTimeNow()
	H.check(left > 5, "a player joining an empty server should get time to read the menu (only " .. string.format("%.1f", left) .. "s left)")
	H.playRound({ carol })
end)

-- Ten humans and no client scripts: team sizes, no bots needed, everyone gets results.
scenario("ten_humans", function(H, M)
	H.startServer()
	H.advance(0.5)
	local humans = {}
	for i = 1, 10 do
		local p, context = H.join("P" .. i, 300 + i, false)
		H.walker(p)
		H.remotePlayer(p, context)
		table.insert(humans, p)
	end
	H.waitFor("Countdown", 60)
	H.advance(1)
	local counts = { 0, 0 }
	for _, p in ipairs(humans) do
		local team = p:GetAttribute("Team")
		if team == 1 or team == 2 then
			counts[team] = counts[team] + 1
		end
	end
	H.check(counts[1] == 5 and counts[2] == 5, "ten humans should split 5 and 5, got " .. counts[1] .. " and " .. counts[2])
	H.check(#H.bots() == 0, "no bots are needed with ten humans, found " .. #H.bots())
	H.playRound(humans)
end)

-- Saving: progress survives leaving and coming back; a broken data store never breaks the game.
scenario("saving", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player = H.join("Saver", 401, true)
	H.walker(player)
	H.keyboardPlayer()
	H.playRound({ player })
	local lvl, xp, coins = player:GetAttribute("Lvl"), player:GetAttribute("XP"), player:GetAttribute("Coins")
	H.check(coins and coins > 0, "no coins after a match")
	M.removePlayer(player)
	H.brains = {}
	H.advance(2)
	H.check(M.datastore.writes > 0, "nothing was written to the data store")
	local again = H.join("Saver", 401, true)
	H.advance(3)
	H.check(again:GetAttribute("Lvl") == lvl and again:GetAttribute("XP") == xp and again:GetAttribute("Coins") == coins,
		"progress was not restored: level " .. tostring(again:GetAttribute("Lvl")) .. " xp " .. tostring(again:GetAttribute("XP"))
		.. " coins " .. tostring(again:GetAttribute("Coins")) .. ", expected " .. tostring(lvl) .. " / " .. tostring(xp) .. " / " .. tostring(coins))
	-- now the data store starts failing
	M.datastore.failing = true
	local other = H.join("Unlucky", 402, true)
	H.walker(other)
	H.advance(3)
	H.check(other:GetAttribute("Lvl") == 1, "a player whose data cannot be loaded should start at level 1")
	H.playRound({ again, other })
	M.removePlayer(other)
	H.advance(2)
end)

scenario("no_datastore", function(H, M)
	M.datastore.unavailable = true   -- an unpublished place: GetDataStore itself throws
	H.startServer()
	H.advance(0.5)
	local player = H.join("Local", 501, true)
	H.walker(player)
	H.playRound({ player })
end)

-- Roblox can deliver events late ("deferred"); the game must not depend on the order.
scenario("deferred_events", function(H, M)
	M.options.deferred = true
	H.startServer()
	H.advance(0.5)
	local player = H.join("Tester", 601, true)
	H.walker(player)
	H.keyboardPlayer()
	H.clicker(player, 5)
	H.playRound({ player })
end)

-- Roblox may put the character in the world before or after telling scripts about it.
scenario("character_order", function(H, M)
	M.options.charAddedFirst = false
	H.startServer()
	H.advance(0.5)
	local player = H.join("Tester", 602, true)
	H.walker(player)
	H.keyboardPlayer()
	H.playRound({ player })
end)

-- A cheater (or a bug) sending nonsense to the server must not break it.
scenario("hostile_client", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player, context = H.join("Griefer", 701, true)
	H.walker(player)
	local junk = { 0 / 0, math.huge, -math.huge, "", "primary", string.rep("x", 5000), true, false, {}, { 1, 2 }, { a = 1 }, 1e300, -1 }
	local function pick()
		return junk[math.random(#junk)]
	end
	local names = { "primary", "dash", "a1", "a2", "ult", "loadout", "title", "", "nope", 5 }
	table.insert(H.brains, function()
		M.as(context, function()
			local s = H.shared()
			s.Act:FireServer(names[math.random(#names)], pick(), pick())
			s.Act:FireServer()
			s.Request:FireServer(names[math.random(#names)], pick(), pick())
			s.Request:FireServer("loadout", "a1", "overdrive")
			s.Request:FireServer("loadout", "primary", "lob")
			s.Request:FireServer("title", "prism")
			s.Request:FireServer("loadout", "a1", "shield")
			s.Request:FireServer("loadout", "a2", "shield")
		end)
	end)
	H.playRound({ player }, { quiet = true })
	H.check(player:GetAttribute("A1") ~= player:GetAttribute("A2"), "both ability slots hold " .. tostring(player:GetAttribute("A1")))
	H.check(player:GetAttribute("A1") ~= "overdrive" and player:GetAttribute("Primary") ~= "lob", "a level 1 player equipped a locked item")
	H.check(player:GetAttribute("Title") == "rookie", "a player with no coins bought a title")
end)

-- The client script starting late, in the middle of a match.
scenario("late_client", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player, context = M.addPlayer("Slow", 801)
	H.walker(player)
	H.waitFor("Playing", 60)
	H.advance(20)
	local player2, context2 = H.join("Slower", 802, true)
	H.advance(5)
	H.check(player2.PlayerGui:FindFirstChild("NeonCanvasHud") ~= nil, "a client that starts mid-match did not build its HUD")
	H.waitFor("Results", 170)
	H.waitFor("Intermission", 30)
end)

-- A veteran with everything unlocked uses each primary and each ability as a real player would.
scenario("veteran_loadouts", function(H, M)
	M.datastore.data["NeonCanvas_v1/p_1001"] = {
		lvl = 20, xp = 10, rating = 640, coins = 5000, wins = 30, matches = 50, kos = 200, dots = 9000,
		primary = "lob", a1 = "blink", a2 = "overdrive", title = "dotter", titles = { rookie = true, dotter = true },
	}
	H.startServer()
	H.advance(0.5)
	local player, context = H.join("Veteran", 1001, true)
	H.walker(player)
	H.keyboardPlayer()
	H.textWatch(player)
	H.advance(3)
	H.check(player:GetAttribute("Lvl") == 20 and player:GetAttribute("Primary") == "lob" and player:GetAttribute("A1") == "blink",
		"saved profile was not loaded: level " .. tostring(player:GetAttribute("Lvl")) .. ", primary " .. tostring(player:GetAttribute("Primary")))
	H.check(player:GetAttribute("Title") == "dotter", "saved title was not loaded")
	local sets = {
		{ "lob", "blink", "overdrive" },
		{ "scatter", "vortex", "beam" },
		{ "bolt", "mine", "mend" },
	}
	for i, set in ipairs(sets) do
		M.as(context, function()
			local request = H.shared().Request
			request:FireServer("loadout", "primary", set[1])
			request:FireServer("loadout", "a1", set[2])
			request:FireServer("loadout", "a2", set[3])
			if i == 2 then
				request:FireServer("title", "king")
			end
		end)
		H.advance(0.5)
		H.check(player:GetAttribute("Primary") == set[1] and player:GetAttribute("A1") == set[2] and player:GetAttribute("A2") == set[3],
			"loadout request " .. i .. " was not applied: " .. tostring(player:GetAttribute("Primary")) .. "/"
			.. tostring(player:GetAttribute("A1")) .. "/" .. tostring(player:GetAttribute("A2")))
		if not H.playRound({ player }) then
			return
		end
	end
	H.check(player:GetAttribute("Title") == "king", "buying a title with enough coins failed (title " .. tostring(player:GetAttribute("Title")) .. ")")
	H.check(player:GetAttribute("Coins") < 5000 + 400, "coins were not spent on the title")
end)

-- Six matches in a row: nothing may pile up.
scenario("soak", function(H, M)
	H.startServer()
	H.advance(0.5)
	local player = H.join("Tester", 901, true)
	H.walker(player)
	H.keyboardPlayer()
	H.clicker(player, 6)
	local sizes = {}
	local wins = { 0, 0, 0 }
	for i = 1, 6 do
		local r = H.playRound({ player }, { quiet = true })
		if not r then
			return
		end
		local winner = r.a > r.b and 1 or (r.b > r.a and 2 or 3)
		wins[winner] = wins[winner] + 1
		local fx = M.find("Workspace/NeonFx")
		table.insert(sizes, {
			gui = M.count(player.PlayerGui), fx = fx and M.count(fx) or 0, timers = M.timerCount(),
			static = M.count(M.find("Workspace/NeonCanvas/Static")), lighting = M.count(M.service("Lighting")),
			sound = M.count(M.service("SoundService")),
		})
	end
	local first, last = sizes[2], sizes[#sizes]
	H.check(last.gui <= first.gui + 40, "the GUI keeps growing: " .. first.gui .. " -> " .. last.gui .. " instances")
	H.check(last.fx <= first.fx + 60, "client effects keep growing: " .. first.fx .. " -> " .. last.fx)
	H.check(last.timers <= first.timers + 30, "pending timers keep growing: " .. first.timers .. " -> " .. last.timers)
	H.check(last.static == first.static and last.lighting == first.lighting, "static world parts changed between rounds")
	H.check(last.sound <= first.sound + 20, "sounds pile up: " .. first.sound .. " -> " .. last.sound)
	H.note("team wins over 6 matches: EMBER " .. wins[1] .. ", TIDE " .. wins[2] .. ", draws " .. wins[3])
	H.note("sizes after round 2: gui " .. first.gui .. " fx " .. first.fx .. " timers " .. first.timers
		.. "; after round 6: gui " .. last.gui .. " fx " .. last.fx .. " timers " .. last.timers)
end)

-- A bare harness for tools (such as preview.py) that want to drive a session themselves.
function Scenarios.session(M, serverSrc, clientSrc)
	return newHarness(M, serverSrc, clientSrc)
end

function Scenarios.run(M, name, serverSrc, clientSrc)
	local H = newHarness(M, serverSrc, clientSrc)
	local fn = Scenarios.defs[name]
	fn(H, M)
	return H.finish()
end

return Scenarios
