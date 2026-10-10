-- Deep Fishing hub for Matcha, UI by INSUI
-- loadstring(game:HttpGet("https://raw.githubusercontent.com/<you>/<repo>/main/main.lua"))()

-- a previous copy stops its loops here; its menu removes itself once the
-- fresh library below registers as the new instance
if _G.DeepFishHub and _G.DeepFishHub.Unload then
    pcall(_G.DeepFishHub.Unload, true)
end

local Lib = loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua"))() or INSUI

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")
local hud = pg:WaitForChild("HUD")
local camera = workspace.CurrentCamera
local mouse = lp:GetMouse()

local Hub = { running = true, conns = {}, drawings = {} }
_G.DeepFishHub = Hub

-- settings, written by the menu
local S = {
    autoCast = false,
    throwQuality = "Perfect",
    timingOffset = 0,
    castCooldown = 1.5,
    autoFight = true,
    clickRate = 11,
    autoSteer = true,
    steerItems = true,
    avoidJunk = true,
    steerSmooth = 0.45,
    fishEsp = false,
    espJunk = false,
    eventAlerts = true,
    rareEventsOnly = false,
    catchAlerts = true,
    catchAlertMin = 300,
    antiAfk = true,
}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function findLabel(root, name, parentName)
    if not root then return nil end
    for _, d in ipairs(root:GetDescendants()) do
        if d.Name == name and d.ClassName == "TextLabel" and (not parentName or (d.Parent and d.Parent.Name == parentName)) then
            return d
        end
    end
end

local function txt(label)
    if not label then return nil end
    local ok, v = pcall(function() return label.Text end)
    if ok then return v end
end

local function num(s)
    if not s then return nil end
    s = s:gsub(",", "")
    local n, suf = s:match("([%d%.]+)%s*([KkMmBb]?)")
    n = tonumber(n)
    if not n then return nil end
    suf = suf and suf:lower() or ""
    if suf == "k" then n = n * 1e3 elseif suf == "m" then n = n * 1e6 elseif suf == "b" then n = n * 1e9 end
    return n
end

local function fmtMoney(n)
    local s = tostring(math.floor(math.abs(n) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-$" or "$") .. out
end

local function fmtTime(sec)
    sec = math.floor(sec)
    return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

local function focused()
    local ok, v = pcall(isrbxactive)
    return not ok or v ~= false
end

local function menuOpen()
    local ok, v = pcall(function() return Lib:IsOpen() end)
    return ok and v == true
end

-- automation only acts while Roblox is focused and the menu is closed,
-- because the menu holds game input back while it is open
local function canAct()
    return focused() and not menuOpen()
end

---------------------------------------------------------------------------
-- game references
---------------------------------------------------------------------------

local R = {}

local function resolveRefs()
    local fishingHud = hud:FindFirstChild("Fishing")
    local header = hud:FindFirstChild("Header")
    local left = hud:FindFirstChild("Left")
    R.depth = fishingHud and findLabel(fishingHud:FindFirstChild("DepthDisplay"), "TextLabel", "MeterDisplay")
    R.fight = fishingHud and findLabel(fishingHud:FindFirstChild("CatchMinigame"), "Amount")
    R.fishAmount = fishingHud and findLabel(fishingHud:FindFirstChild("FishAmount"), "Amount")
    R.throwDist = findLabel(header, "ThrowDistance")
    R.event = findLabel(header, "EventName")
    R.location = findLabel(header, "LocationName")
    R.cash = left and findLabel(left:FindFirstChild("Stats"), "Amount")
    local right = hud:FindFirstChild("Right")
    R.notifs = right and right:FindFirstChild("FishesReceivedNotification")
    -- hook meter: count the step frames to find where Perfect sits
    local hook = fishingHud and fishingHud:FindFirstChild("Hook")
    local edge = hook and hook:FindFirstChild("LeftEdge")
    local steps = 0
    if edge then
        for _, c in ipairs(edge:GetChildren()) do
            local n = tonumber(c.Name)
            if n and n > steps then steps = n end
        end
    end
    R.hookSteps = steps >= 2 and steps or 21
end

resolveRefs()

---------------------------------------------------------------------------
-- fish database: odds from the Index menu, rarity learned from catches
---------------------------------------------------------------------------

local Odds = {}
local RarityOf = {}
local ItemNames = {}
local JunkNames = {}

local RarityOrder = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6, Secret = 7, Exotic = 8, Exclusive = 9 }
local RarityColor = {
    Common = Color3.fromRGB(190, 190, 190),
    Uncommon = Color3.fromRGB(90, 220, 110),
    Rare = Color3.fromRGB(80, 160, 255),
    Epic = Color3.fromRGB(180, 100, 255),
    Legendary = Color3.fromRGB(255, 200, 60),
    Mythic = Color3.fromRGB(255, 80, 80),
    Secret = Color3.fromRGB(255, 120, 220),
    Exotic = Color3.fromRGB(80, 255, 230),
    Exclusive = Color3.fromRGB(255, 255, 255),
}
local ItemColor = Color3.fromRGB(255, 170, 60)

local function rarityFromOdds(n)
    if not n then return nil end
    if n < 10 then return "Common" end
    if n < 80 then return "Uncommon" end
    if n < 800 then return "Rare" end
    if n < 8000 then return "Epic" end
    if n < 80000 then return "Legendary" end
    if n < 800000 then return "Mythic" end
    return "Secret"
end

local function loadDatabase()
    local index = pg:FindFirstChild("Interfaces")
    index = index and index:FindFirstChild("Index")
    local list = index and index:FindFirstChild("Content")
    list = list and list:FindFirstChild("ScrollingFrame")
    if list then
        for _, frame in ipairs(list:GetChildren()) do
            local oddsLabel = findLabel(frame, "Odds")
            local n = oddsLabel and num((txt(oddsLabel) or ""):match("in%s+([%d%.,]+%s*[KkMmBb]?)"))
            if n then Odds[frame.Name] = n end
        end
    end
    local items = game:GetService("ReplicatedStorage"):FindFirstChild("Prefabs")
    items = items and items:FindFirstChild("Items")
    if items then
        for _, folder in ipairs({ "Consumables", "Bait", "Chests", "Keys", "Summons", "Potions", "Cages" }) do
            local f = items:FindFirstChild(folder)
            if f then for _, c in ipairs(f:GetChildren()) do ItemNames[c.Name] = true end end
        end
        local junk = items:FindFirstChild("Junk")
        if junk then for _, c in ipairs(junk:GetChildren()) do JunkNames[c.Name] = true end end
    end
end

loadDatabase()

local function fishRarity(name)
    return RarityOf[name] or rarityFromOdds(Odds[name])
end

-- higher is more worth chasing
local function targetScore(name)
    if JunkNames[name] then return S.avoidJunk and -1 or 0 end
    if ItemNames[name] then return S.steerItems and 1e9 or 0 end
    local o = Odds[name]
    if o then return o end
    return nil
end

---------------------------------------------------------------------------
-- session stats
---------------------------------------------------------------------------

local Stats = {
    start = os.clock(),
    casts = 0, perfects = 0, catches = 0, fights = 0, fightsWon = 0,
    earned = 0, spent = 0,
    byRarity = {},
    best = nil, bestOdds = 0,
    lastCash = nil,
}

local seenNotifs = {}

local function scanCatches(report)
    local root = R.notifs
    if not root then return end
    for _, c in ipairs(root:GetChildren()) do
        if c.Name == "Notification" then
            local cont = c:FindFirstChild("Container")
            if cont then
                local name = txt(findLabel(cont, "ItemName")) or "?"
                local rarity = txt(findLabel(cont, "Rarity")) or "?"
                local mut = txt(findLabel(cont, "Mutation")) or ""
                local weight = txt(findLabel(cont, "Weight")) or ""
                local key = name .. "|" .. rarity .. "|" .. mut .. "|" .. weight
                if not seenNotifs[key] then
                    seenNotifs[key] = true
                    if report then
                        Stats.catches = Stats.catches + 1
                        Stats.byRarity[rarity] = (Stats.byRarity[rarity] or 0) + 1
                        if RarityOrder[rarity] then RarityOf[name] = rarity end
                        local o = Odds[name] or 0
                        if o >= Stats.bestOdds then
                            Stats.bestOdds = o
                            Stats.best = name .. " (" .. rarity .. ")"
                        end
                        if S.catchAlerts and o >= S.catchAlertMin then
                            Lib:Notify("Nice catch", string.format("%s  %s  %s  1 in %s", name, rarity, mut, tostring(o)), 5, "success")
                        end
                    end
                end
            end
        end
    end
end

scanCatches(false)
Stats.lastCash = num(txt(R.cash))

---------------------------------------------------------------------------
-- cast state, read off the HUD
---------------------------------------------------------------------------

local Cast = {
    lastActive = 0,     -- last time something showed a cast in progress
    lastRelease = -1e9,
    lastThrowText = nil,
    fighting = false,
}

local function depthNow()
    return num(txt(R.depth)) or 0
end

local function rodHeld()
    local ch = lp.Character
    local tool = ch and ch:FindFirstChildOfClass("Tool")
    return tool ~= nil and tostring(tool.Name):find("Rod") ~= nil
end

local function castBusy()
    local now = os.clock()
    if Cast.fighting then return true end
    if now - Cast.lastRelease < 3 then return true end
    return now - Cast.lastActive < S.castCooldown
end

-- seconds to hold the mouse so HookT lands in the middle of the chosen zone.
-- HookT rises 0 -> 1 over 0.75s; zone index = 1 + HookT * (steps - 1);
-- Perfect is [9, 12), Good is [3, 19)
local function holdTime()
    local steps = R.hookSteps
    local mid = S.throwQuality == "Perfect" and 10.5 or 6
    local t = (mid - 1) / (steps - 1)
    return math.clamp(t, 0, 1) * 0.75 + S.timingOffset / 1000
end

local function doCast()
    if not (rodHeld() and canAct()) then return end
    mouse1press()
    task.wait(holdTime())
    mouse1release()
    Cast.lastRelease = os.clock()
    Cast.lastActive = os.clock()
    Stats.casts = Stats.casts + 1
end

---------------------------------------------------------------------------
-- fight: the "Click Fast (n)" counter resets to 0 when a fight starts
-- and goes up on every click the game accepts
---------------------------------------------------------------------------

local function fightCount()
    local t = txt(R.fight)
    return t and tonumber(t:match("%((%d+)%)")), t
end

local function runFight()
    if Cast.fighting then return end
    Cast.fighting = true
    Stats.fights = Stats.fights + 1
    local started = os.clock()
    local misses = 0
    local lastCount = fightCount() or 0
    while Hub.running and S.autoFight and os.clock() - started < 56 do
        if canAct() then
            mouse1click()
        end
        task.wait(1 / math.clamp(S.clickRate, 4, 12))
        local c = fightCount() or lastCount
        if c > lastCount then
            misses = 0
        else
            misses = misses + 1
        end
        lastCount = c
        -- clicks stopped counting: the fight is over
        if misses >= 6 then break end
    end
    if lastCount > 0 then Stats.fightsWon = Stats.fightsWon + 1 end
    Cast.fighting = false
    Cast.lastActive = os.clock()
end

---------------------------------------------------------------------------
-- world scan for the cast's fish school (collector, 5 Hz)
---------------------------------------------------------------------------

local School = {}   -- { name, part, score, rarity }
local MyBait = nil

local function collectSchool()
    local out = {}
    local camPos = camera.CFrame.Position
    local bestBait, bestDist = nil, math.huge
    for _, c in ipairs(workspace:GetChildren()) do
        local cls = c.ClassName
        if cls == "Part" and c.Name == "Bait" then
            local d = (c.Position - camPos).Magnitude
            if d < bestDist then bestBait, bestDist = c, d end
        elseif cls == "Model" then
            local name = c.Name
            local score = targetScore(name)
            if score ~= nil and not Players:FindFirstChild(name) then
                local part = c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart")
                if part then
                    out[#out + 1] = {
                        name = name,
                        part = part,
                        score = score,
                        rarity = ItemNames[name] and "Item" or JunkNames[name] and "Junk" or fishRarity(name),
                        odds = Odds[name],
                    }
                end
            end
        end
    end
    MyBait = bestBait
    School = out
end

---------------------------------------------------------------------------
-- steering: the bait follows the mouse's X position on screen,
-- so point the mouse at the best fish above the bait
---------------------------------------------------------------------------

local steerTarget = nil

local function pickTarget(baitY)
    local best, bestScore = nil, 0
    for _, f in ipairs(School) do
        local ok, pos = pcall(function() return f.part.Position end)
        if ok and pos and f.score > 0 and pos.Y >= baitY - 2 then
            if f.score > bestScore then
                best, bestScore = f, f.score
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- ESP drawing pool
---------------------------------------------------------------------------

local POOL = 24
local espPool = {}
for i = 1, POOL do
    local t = Drawing.new("Text")
    t.Size = 14
    t.Center = true
    t.Outline = true
    t.Visible = false
    espPool[i] = t
    Hub.drawings[#Hub.drawings + 1] = t
end
local targetRing = Drawing.new("Circle")
targetRing.Radius = 18
targetRing.Thickness = 2
targetRing.NumSides = 24
targetRing.Filled = false
targetRing.Color = Color3.fromRGB(255, 255, 255)
targetRing.Visible = false
Hub.drawings[#Hub.drawings + 1] = targetRing

---------------------------------------------------------------------------
-- loops
---------------------------------------------------------------------------

-- state loop: HUD reads, fights, auto cast
task.spawn(function()
    local lastFightText = select(2, fightCount())
    while Hub.running do
        local ok, err = pcall(function()
            local now = os.clock()
            local d = depthNow()
            local th = txt(R.throwDist)
            if d > 0 or th ~= Cast.lastThrowText then
                Cast.lastActive = now
            end
            Cast.lastThrowText = th

            local count, ftext = fightCount()
            if ftext ~= lastFightText then
                if count == 0 and S.autoFight then
                    task.spawn(runFight)
                end
                lastFightText = ftext
            end

            if S.autoCast and not castBusy() and d == 0 then
                doCast()
            end
        end)
        if not ok then warn("[DeepFish] state loop: " .. tostring(err)) end
        task.wait(0.05)
    end
end)

-- collector + stats + alerts, 5 Hz
task.spawn(function()
    local lastEvent = txt(R.event)
    local quietEvents = { Day = true, Night = true, Rain = true }
    while Hub.running do
        local ok, err = pcall(function()
            if S.autoSteer or S.fishEsp then collectSchool() else School = {} end
            scanCatches(true)

            local cash = num(txt(R.cash))
            if cash and Stats.lastCash then
                local diff = cash - Stats.lastCash
                if diff > 0 then Stats.earned = Stats.earned + diff elseif diff < 0 then Stats.spent = Stats.spent - diff end
            end
            if cash then Stats.lastCash = cash end

            local ev = txt(R.event)
            if ev and ev ~= lastEvent then
                local base = ev:match("^([%a ]+)") or ev
                base = base:gsub("%s+$", "")
                if S.eventAlerts and not (S.rareEventsOnly and quietEvents[base]) then
                    Lib:Notify("Event", ev .. " started", 6, "info")
                end
                lastEvent = ev
            end
        end)
        if not ok then warn("[DeepFish] collector: " .. tostring(err)) end
        task.wait(0.2)
    end
end)

-- database refresh, the Index can fill in late
task.spawn(function()
    while Hub.running do
        task.wait(30)
        pcall(loadDatabase)
    end
end)

-- anti afk: a 1px nudge every 4 minutes when nothing else is clicking
task.spawn(function()
    while Hub.running do
        task.wait(240)
        if S.antiAfk and not S.autoCast and focused() then
            pcall(mousemoverel, 1, 0)
            task.wait(0.05)
            pcall(mousemoverel, -1, 0)
        end
    end
end)

-- renderer: steering and ESP, reads only
Hub.conns[#Hub.conns + 1] = RunService.RenderStepped:Connect(function()
    if not Hub.running then return end
    local bait = MyBait
    local baitPos = nil
    if bait then
        local ok, p = pcall(function() return bait.Position end)
        if ok then baitPos = p end
    end
    local casting = baitPos ~= nil and depthNow() > 0

    -- steering
    steerTarget = nil
    if S.autoSteer and casting and not Cast.fighting and canAct() then
        local t = pickTarget(baitPos.Y)
        if t then
            local ok, pos = pcall(function() return t.part.Position end)
            if ok and pos then
                local scr, vis = WorldToScreen(pos)
                if vis then
                    steerTarget = { x = scr.X, y = scr.Y }
                    local dx = scr.X - mouse.X
                    if math.abs(dx) > 3 then
                        pcall(mousemoverel, math.floor(dx * S.steerSmooth + 0.5), 0)
                    end
                end
            end
        end
    end

    if steerTarget and S.fishEsp then
        targetRing.Position = Vector2.new(steerTarget.x, steerTarget.y)
        targetRing.Visible = true
    else
        targetRing.Visible = false
    end

    -- ESP
    local n = 0
    if S.fishEsp and casting then
        for _, f in ipairs(School) do
            if n >= POOL then break end
            if f.rarity ~= "Junk" or S.espJunk then
                local ok, pos = pcall(function() return f.part.Position end)
                if ok and pos then
                    local scr, vis = WorldToScreen(pos)
                    if vis then
                        n = n + 1
                        local e = espPool[n]
                        local label = f.name
                        if f.odds then label = label .. "  1/" .. tostring(f.odds) end
                        e.Text = label
                        e.Position = Vector2.new(scr.X, scr.Y - 22)
                        e.Color = f.rarity == "Item" and ItemColor or RarityColor[f.rarity] or RarityColor.Common
                        e.Visible = true
                    end
                end
            end
        end
    end
    for i = n + 1, POOL do espPool[i].Visible = false end
end)

---------------------------------------------------------------------------
-- menu
---------------------------------------------------------------------------

local win = Lib:CreateWindow({
    title = "Deep Fishing",
    subtitle = "auto",
    size = Vector2.new(660, 500),
    menuKey = "p",
    checkboxStyle = true,
    configName = "deepfishing",
    configFolder = "deepfishing",
    autoSave = true,
})

Lib:Category("FISHING")
local tFish = win:Tab("Fishing", "target")

local sCast = tFish:Section("Auto cast", "Left", "casts for you when idle")
sCast:Toggle("Auto cast", S.autoCast, function(on)
    S.autoCast = on
    if on then Lib:Notify("Auto cast", "on - close the menu (P) so clicks reach the game", 4, "success") end
end):AddKeybind("f6", "Toggle")
sCast:Dropdown("Throw quality", { S.throwQuality }, { "Perfect", "Good" }, false, function(v)
    S.throwQuality = (type(v) == "table" and v[1]) or v or "Perfect"
end)
sCast:Slider("Timing offset", S.timingOffset, 5, -150, 150, "ms", function(v) S.timingOffset = v end, "raise if throws come out early, lower if late")
sCast:Slider("Cooldown", S.castCooldown, 0.1, 0.5, 5, "s", function(v) S.castCooldown = v end)
sCast:Label(function() return string.format("Hold time: %d ms  (%d steps)", math.floor(holdTime() * 1000), R.hookSteps) end)

local sFight = tFish:Section("Catch fight", "Left")
sFight:Toggle("Auto fight", S.autoFight, function(on) S.autoFight = on end, "clicks for you while a fish fights back")
sFight:Slider("Click rate", S.clickRate, 1, 4, 12, "/s", function(v) S.clickRate = v end, "the game caps credit at 12/s")
sFight:Label(function() return "Fighting: " .. (Cast.fighting and "yes" or "no") end)

local sSteer = tFish:Section("Steering", "Right", "aims the bait at the rarest fish")
sSteer:Toggle("Auto steer", S.autoSteer, function(on) S.autoSteer = on end)
sSteer:Toggle("Chase items", S.steerItems, function(on) S.steerItems = on end, "enchant stones, baits, chests, keys")
sSteer:Toggle("Avoid junk", S.avoidJunk, function(on) S.avoidJunk = on end)
sSteer:Slider("Smoothness", S.steerSmooth, 0.05, 0.1, 1, "", function(v) S.steerSmooth = v end)
sSteer:Label(function()
    local t = pickTarget(-1e9)
    return "Best in school: " .. (t and t.name or "-")
end)

local sEsp = tFish:Section("Fish ESP", "Right")
sEsp:Toggle("Show fish", S.fishEsp, function(on) S.fishEsp = on end, "name and odds over the school while you cast")
sEsp:Toggle("Show junk", S.espJunk, function(on) S.espJunk = on end)

Lib:Category("INFO")
local tInfo = win:Tab("Session", "gauge")

local sStats = tInfo:Section("Session", "Left")
sStats:Label(function() return "Time: " .. fmtTime(os.clock() - Stats.start) end)
sStats:Label(function() return string.format("Casts: %d   Catches: %d", Stats.casts, Stats.catches) end)
sStats:Label(function() return string.format("Fights won: %d / %d", Stats.fightsWon, Stats.fights) end)
sStats:Label(function() return "Earned: " .. fmtMoney(Stats.earned) .. "   Spent: " .. fmtMoney(Stats.spent) end)
sStats:Label(function()
    local h = math.max((os.clock() - Stats.start) / 3600, 1 / 3600)
    return string.format("Per hour: %s   %d fish", fmtMoney(Stats.earned / h), math.floor(Stats.catches / h))
end)
sStats:Label(function() return "Best: " .. (Stats.best or "-") end)
sStats:Button("Reset session", function()
    Stats.start = os.clock()
    Stats.casts, Stats.catches, Stats.fights, Stats.fightsWon, Stats.earned, Stats.spent = 0, 0, 0, 0, 0, 0
    Stats.byRarity, Stats.best, Stats.bestOdds = {}, nil, 0
end)

local sRar = tInfo:Section("By rarity", "Right")
for _, r in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Exotic" }) do
    sRar:Label(function() return r .. ": " .. tostring(Stats.byRarity[r] or 0) end)
end

local sAlerts = tInfo:Section("Alerts", "Right")
sAlerts:Toggle("Event alerts", S.eventAlerts, function(on) S.eventAlerts = on end)
sAlerts:Toggle("Rare events only", S.rareEventsOnly, function(on) S.rareEventsOnly = on end, "skip day, night and rain")
sAlerts:Toggle("Rare catch alerts", S.catchAlerts, function(on) S.catchAlerts = on end)
sAlerts:Slider("Alert at odds", S.catchAlertMin, 50, 50, 20000, "", function(v) S.catchAlertMin = v end, "1 in N or rarer")

Lib:Category("SYSTEM")
local tMisc = win:Tab("Misc", "three-dots-horizontal")
local sMisc = tMisc:Section("Misc", "Left")
sMisc:Toggle("Anti AFK", S.antiAfk, function(on) S.antiAfk = on end)
sMisc:Button("Rescan game", function()
    resolveRefs()
    loadDatabase()
    local n = 0 for _ in pairs(Odds) do n = n + 1 end
    Lib:Notify("Rescan", n .. " fish in database", 3, "info")
end)
sMisc:Label(function()
    local n = 0 for _ in pairs(Odds) do n = n + 1 end
    return "Fish known: " .. n
end)
sMisc:Button("Unload", function()
    Lib:Dialog({
        title = "Unload?",
        text = "Stop everything and remove the menu?",
        confirm = "Unload",
        onConfirm = function() Hub.Unload() end,
    })
end):SetRisk()

win:AddSettingsTab("gear")

-- box lines only render plain values, so a loop rewrites line.Value
local box = Lib:CreateBox({ title = "Deep Fishing", position = Vector2.new(20, 160), width = 210 })
local boxLines = {
    { line = box:Text(""), get = function() return "Auto: " .. (S.autoCast and "ON" or "off") .. (menuOpen() and "  (menu open)" or "") end },
    { line = box:Stat(""), get = function() return string.format("Casts: %d   Catches: %d", Stats.casts, Stats.catches) end },
    { line = box:Stat(""), get = function()
        local h = math.max((os.clock() - Stats.start) / 3600, 1 / 3600)
        return "Per hour: " .. fmtMoney(Stats.earned / h)
    end },
    { line = box:Text(""), get = function() return "Best: " .. (Stats.best or "-") end },
}
task.spawn(function()
    while Hub.running do
        for _, b in ipairs(boxLines) do
            local ok, v = pcall(b.get)
            if ok and b.line then b.line.Value = v end
        end
        task.wait(0.5)
    end
end)

-- Never call Lib:Destroy() directly: it frees drawings the menu may still be
-- mid-frame on, which crashes Matcha. Swapping the instance marker makes the
-- menu tear itself down at the top of its next frame instead.
function Hub.Unload(keepMenu)
    if not Hub.running then return end
    Hub.running = false
    for _, c in ipairs(Hub.conns) do pcall(function() c:Disconnect() end) end
    for _, d in ipairs(Hub.drawings) do pcall(function() d.Visible = false end) end
    local drawings = Hub.drawings
    Hub.drawings = {}
    task.delay(0.5, function()
        for _, d in ipairs(drawings) do pcall(function() d:Remove() end) end
    end)
    if not keepMenu then _G.INSuiInstance = {} end
    if _G.DeepFishHub == Hub then _G.DeepFishHub = nil end
end

Hub.debug = { S = S, R = R, Odds = Odds, Stats = Stats, Cast = Cast, School = function() return School end, holdTime = holdTime }

local fishKnown = 0 for _ in pairs(Odds) do fishKnown = fishKnown + 1 end
Lib:Notify("Deep Fishing", "Loaded - P opens the menu, F6 toggles auto cast. " .. fishKnown .. " fish known.", 6, "success")
