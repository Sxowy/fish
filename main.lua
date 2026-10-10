-- Deep Fishing hub for Matcha, UI by INSUI
-- loadstring(game:HttpGet("https://raw.githubusercontent.com/Sxowy/fish/main/main.lua"))()

-- Startup is serialized. Two copies starting at once both load the menu
-- library and draw at the same time while one tears itself down, which has
-- crashed Matcha; two copies running both steer the same bait. So:
--   * every execute takes a ticket; only the newest ticket may start
--   * wait half a second first, so a double execute collapses into one
--   * if another copy is still loading (the library download takes a second
--     or two, before it registers), wait for it, then replace it normally:
--     unload it, give its menu time to close and tear down, then start
_G.DeepFishLoadId = (_G.DeepFishLoadId or 0) + 1
local myLoad = _G.DeepFishLoadId

local function main()

-- The menu library, patched so an error inside one of its frames can't end
-- its loop (that froze the menu and blocked game input). Our copy comes from
-- this PC when present, else this repo, else the original as a last resort.
local function loadLib()
    local sources = {
        function() return isfile and isfile("deepfish/uilib.lua") and readfile("deepfish/uilib.lua") end,
        function() return game:HttpGet("https://raw.githubusercontent.com/Sxowy/fish/main/uilib.lua") end,
        function() return game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua") end,
    }
    for _, get in ipairs(sources) do
        local ok, src = pcall(get)
        if ok and type(src) == "string" and #src > 100000 then
            local fn = loadstring(src)
            if fn then
                local okRun, lib = pcall(fn)
                if okRun then return lib or INSUI end
            end
        end
    end
    return INSUI
end
local Lib = loadLib()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")
local hud = pg:WaitForChild("HUD")
local camera = workspace.CurrentCamera
local mouse = lp:GetMouse()

local Hub = { running = true, conns = {}, drawings = {}, spawnSeen = {} }
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
    autoEquip = true,
    fullGuard = true,
    staffGuard = true,
    webhook = false,
    webhookUrl = "",
    summaryMins = 0,
    spawnAlert = true,
    spawnAlertMin = 100000,
    keyCast = "F6",
    keySteer = "F7",
    keyEsp = "F8",
    keyPanic = "End",
    avoidJunk = true,
    steerSpeed = 4,
    steerMode = "Direct", -- the only steering mode
    goForItems = true,
    targetMode = "Value",
    minValue = 0, -- 0 = Auto: no fixed floor, the planner keeps the best fish for the slots
    fishEsp = false,
    espJunk = false,
    eventAlerts = true,
    rareEventsOnly = false,
    catchAlerts = true,
    catchAlertMin = 100000,
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

-- set by the staff detector; menu handles are filled in once the menu exists
local Guard = { staff = nil }
local UI = {}

-- automation only acts while Roblox is focused and the menu is closed
-- (the menu holds game input back while it is open), and never while a
-- staff member is in the server with the staff guard on
local function canAct()
    if S.staffGuard and Guard.staff then return false end
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
    R.nextEvent = findLabel(header, "NextEvent")
    R.event = findLabel(header, "EventName")
    R.location = findLabel(header, "LocationName")
    R.cash = left and findLabel(left:FindFirstChild("Stats"), "Amount")
    local right = hud:FindFirstChild("Right")
    R.notifs = right and right:FindFirstChild("FishesReceivedNotification")
    local footer = hud:FindFirstChild("Footer")
    R.hotbar = footer and footer:FindFirstChild("Hotbar")
    local inv = pg:FindFirstChild("Interfaces")
    inv = inv and inv:FindFirstChild("Inventory")
    R.invFish = nil
    if inv then
        for _, d in ipairs(inv:GetDescendants()) do
            if d.Name == "Amount" and d.ClassName == "TextLabel" and d.Parent and d.Parent.Name == "Fish" then
                R.invFish = d
                break
            end
        end
    end
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
-- fish database: sell price and rarity per fish, odds from the Index menu
---------------------------------------------------------------------------

-- sell price and rarity per fish, dumped from the game's item data.
-- "Refresh prices" in the menu rescans memory if the game adds fish.
local BuiltinPrices = {
    ["Anchorbone Reaper"] = { 120000000000, "Exotic" },
    ["Anglerfish"] = { 2000000, "Mythic" },
    ["Anvilhead Forgeshark"] = { 19000000000, "Secret" },
    ["Archerfish"] = { 20200, "Epic" },
    ["Arctic Grayling"] = { 170000, "Uncommon" },
    ["Ashback Carp"] = { 5000000, "Uncommon" },
    ["Atollwake Leviathan"] = { 2000000, "Secret" },
    ["Aurorift Humpback"] = { 500000000, "Secret" },
    ["Barracuda"] = { 11200, "Legendary" },
    ["Basalt Goby"] = { 3000000, "Common" },
    ["Bass"] = { 79, "" },
    ["Big Mouth"] = { 12000000, "Exclusive" },
    ["Blacktip Shark"] = { 1800000, "Secret" },
    ["Blaze Seahorse"] = { 70000000, "Legendary" },
    ["Blazewing Glider"] = { 90000000, "Legendary" },
    ["Bloodtide Megamaw"] = { 2100000, "Secret" },
    ["Bloomspike Behemoth"] = { 120000, "Mythic" },
    ["Blue Tang"] = { 280, "" },
    ["Blue Whale"] = { 400000000, "" },
    ["Bonewake Coelacanth"] = { 60000000, "Exotic" },
    ["Borealis Guppy"] = { 400000, "Epic" },
    ["Boxfish"] = { 1350, "Epic" },
    ["Brimstone Barracuda"] = { 12000000, "Epic" },
    ["Brown Trout"] = { 8980, "Uncommon" },
    ["Bull Orca"] = { 70000000, "Mythic" },
    ["Bull Shark"] = { 2810000, "Mythic" },
    ["Butterflyfish"] = { 1120, "Epic" },
    ["Caldera Leviathan"] = { 1200000000, "Mythic" },
    ["Carp"] = { 26, "Common" },
    ["Catfish"] = { 10100, "Uncommon" },
    ["Cathedral Nautilus"] = { 450000000, "Secret" },
    ["Cinder Minnow"] = { 2700000, "Common" },
    ["Cinderclaw Sovereign"] = { 14000000000, "Secret" },
    ["Cinderjaw Piranha"] = { 8000000, "Rare" },
    ["Cindermaw Angler"] = { 50000000000, "Exotic" },
    ["Clownfish"] = { 247, "Rare" },
    ["Coalback Sturgeon"] = { 11000000, "Epic" },
    ["Coalspark Dart"] = { 8000000, "Rare" },
    ["Coinback Grouper"] = { 10000, "Legendary" },
    ["Collosal Kraken"] = { 0, "Exclusive" },
    ["Coral Goby"] = { 1180, "Epic" },
    ["Coralcoil Kraken"] = { 2400000, "Secret" },
    ["Coralflare Batfish"] = { 11000, "Legendary" },
    ["Corona Phoenixfin"] = { 16000000000, "Secret" },
    ["Cowfish"] = { 1400, "Epic" },
    ["Crab"] = { 65, "Uncommon" },
    ["Crestbreaker Thresher"] = { 130000, "Mythic" },
    ["Crestwake Oarfish"] = { 9000000, "Exotic" },
    ["Crocodile"] = { 2700000, "" },
    ["Crownbreaker Leviathan"] = { 5000000000, "Exclusive" },
    ["Crownreef Manta"] = { 150000, "Mythic" },
    ["Cushion Star"] = { 112000, "Legendary" },
    ["Dreadwake Basilosaur"] = { 24000000, "Secret" },
    ["Duck"] = { 7850, "" },
    ["Dune Glowgoby"] = { 12500, "Rare" },
    ["Duneband Sole"] = { 21000, "Epic" },
    ["Duneblade Guitarfish"] = { 2600000, "Mythic" },
    ["Dunecrown Scyllarid"] = { 23000000, "Secret" },
    ["Duneworm Colossus"] = { 90000000, "Exotic" },
    ["Duskfang Scorpion"] = { 230000000, "Exotic" },
    ["Eagle Ray"] = { 146000, "Legendary" },
    ["Eel"] = { 1800, "Epic" },
    ["Emberback Caldera"] = { 12000000000, "Secret" },
    ["Emberfin"] = { 2400000, "Common" },
    ["Emberscale Turtle"] = { 15000000, "Epic" },
    ["Emberthrone Koi"] = { 1800000000, "Mythic" },
    ["Firecoral Lionfish"] = { 12000000, "Epic" },
    ["Firefly Tetra"] = { 1200, "Epic" },
    ["Flounder"] = { 13500, "Rare" },
    ["Flying Fish"] = { 350000, "Epic" },
    ["Frog"] = { 4490, "Common" },
    ["Frost Serpent"] = { 600000000, "Secret" },
    ["Frostbite Sprat"] = { 275000, "Rare" },
    ["Frostcrown Beluga"] = { 50000000, "Mythic" },
    ["Frostglass Fangtooth"] = { 2300000, "Legendary" },
    ["Frostspine"] = { 400000, "" },
    ["Frozen Warden"] = { 10000000000, "Exotic" },
    ["Giant Squid"] = { 180000, "Legendary" },
    ["Gilded Crownurchin"] = { 26000000, "Secret" },
    ["Gilded Gaper"] = { 130000, "Legendary" },
    ["Glacierback Ankylos"] = { 4500000000, "Exotic" },
    ["Glassjaw Smelt"] = { 400000, "Epic" },
    ["Glasswing Sphinx"] = { 1100000000, "Exotic" },
    ["Goldfish"] = { 17, "Common" },
    ["Grand Vizier Angler"] = { 2150000, "Secret" },
    ["Great White Shark"] = { 160000, "Mythic" },
    ["Grouper"] = { 28100, "Epic" },
    ["Hammerhead Shark"] = { 400000, "Epic" },
    ["Hawkfish"] = { 19100, "Epic" },
    ["Hearthsun Mola"] = { 15000000000, "Secret" },
    ["Herald Ray"] = { 135000, "Mythic" },
    ["Hoarfrost Curldancer"] = { 2600000, "" },
    ["Icebreaker Wolffish"] = { 60000000, "Mythic" },
    ["Icefish"] = { 100000, "Common" },
    ["Ironjaw Dunkleost"] = { 17000000, "Exotic" },
    ["Jackal Nightpike"] = { 2650000, "Mythic" },
    ["Jellyfish"] = { 135000, "Legendary" },
    ["Jester Lionfish"] = { 10000, "Legendary" },
    ["Kelpcrown Seadragon"] = { 30000000, "Exotic" },
    ["King Crab"] = { 146000, "Legendary" },
    ["Knightfin Swordfish"] = { 135000, "Mythic" },
    ["Kraken"] = { 2500000, "Legendary" },
    ["Lanternjaw"] = { 2000000, "" },
    ["Lavalamp Jelly"] = { 60000000, "Legendary" },
    ["Leviathan"] = { 40000000, "" },
    ["Lionfish"] = { 1570, "" },
    ["Lobster"] = { 1680, "Epic" },
    ["Lotusdream Axolotl"] = { 450000000, "Secret" },
    ["Lullaby Lanternfish"] = { 10000, "Legendary" },
    ["Magma Mantis"] = { 80000000, "Legendary" },
    ["Magma Puffer"] = { 6000000, "" },
    ["Magmafang Basilisk"] = { 300000000000, "Exotic" },
    ["Magmaw Snapper"] = { 12000000, "Epic" },
    ["Mandarinfish"] = { 13500, "Rare" },
    ["Manta Ray"] = { 12000, "Legendary" },
    ["Megalodon"] = { 29000000, "" },
    ["Mirage Djinn Eel"] = { 23500000, "Secret" },
    ["Mirage Mantis"] = { 140000, "Legendary" },
    ["Moon Jelly"] = { 123000, "Legendary" },
    ["Moonbeam Minnow"] = { 235, "Rare" },
    ["Moorish Idol"] = { 23600, "Epic" },
    ["Mosaic Parrotfin"] = { 1100, "Epic" },
    ["Mosasaurus"] = { 3000000, "Legendary" },
    ["Nightcap Dreamer"] = { 145000, "Mythic" },
    ["Northstar Wyrm"] = { 475000000, "Secret" },
    ["Nurse Shark"] = { 450000, "Epic" },
    ["Oasis Moon Koi"] = { 125000, "Legendary" },
    ["Obelisk Cuirass"] = { 120000, "Legendary" },
    ["Obsidian Eel"] = { 7000000, "Rare" },
    ["Obsidian Moth-Ray"] = { 80000000, "Legendary" },
    ["Obsidian Swordtyrant"] = { 2000000000, "Mythic" },
    ["Orca"] = { 2500000, "Secret" },
    ["Page Puffer"] = { 1300, "Epic" },
    ["Pearlblossom Empress"] = { 1800000, "Secret" },
    ["Pearlfish"] = { 11200, "Uncommon" },
    ["Penguin"] = { 350000, "Epic" },
    ["Pike"] = { 450000, "Epic" },
    ["Pilchard"] = { 80000, "Common" },
    ["Plesiosaur"] = { 21000000, "Secret" },
    ["Polar Owlfish"] = { 2400000, "Legendary" },
    ["Polarstar Angler"] = { 500000000, "Secret" },
    ["Prismveil Cuttlefish"] = { 9000, "Legendary" },
    ["Pufferfish"] = { 1290, "Epic" },
    ["Pumice Ray"] = { 9000000, "Rare" },
    ["Purple Tang"] = { 15700, "Rare" },
    ["Pygmy Seahorse"] = { 190000, "Uncommon" },
    ["Pyre Hydra"] = { 17000000000, "Secret" },
    ["Pyroclast Kraken"] = { 1400000000, "Mythic" },
    ["Rainbow Trout"] = { 290000, "Rare" },
    ["Red Snapper"] = { 25800, "Epic" },
    ["Redmoon Salamander"] = { 1500000000, "Mythic" },
    ["Reef Squid"] = { 210000, "Uncommon" },
    ["Reefmaw Goliath"] = { 150000, "Mythic" },
    ["Regal Tang"] = { 14600, "Rare" },
    ["Rekin"] = { 10000000, "Exclusive" },
    ["Ribboncrest Hogfish"] = { 1200, "Epic" },
    ["Rimecrown Stag"] = { 23000000000, "Exotic" },
    ["Rimefang Greenland"] = { 45000000, "Mythic" },
    ["Rimeplate Lumpsucker"] = { 350000, "" },
    ["Roselight Medusa"] = { 10000, "Legendary" },
    ["Sailfish"] = { 11200, "Legendary" },
    ["Sardine"] = { 19, "Common" },
    ["Scarab Nightfin"] = { 20500, "Epic" },
    ["Scorchtail Darter"] = { 6000000, "Uncommon" },
    ["Sea Turtle"] = { 230000, "Rare" },
    ["Seahorse"] = { 213, "Rare" },
    ["Seal"] = { 500000, "Epic" },
    ["Sepulcher Gulper"] = { 27000000, "Secret" },
    ["Shrimp"] = { 55, "Uncommon" },
    ["Siltwhisker Goatfish"] = { 18000, "Epic" },
    ["Slagfin Snapper"] = { 11000000, "Epic" },
    ["Smokestack Catfish"] = { 16000000, "Epic" },
    ["Snapping Turtle"] = { 260000, "Rare" },
    ["Snowglobe Puffer"] = { 47500000, "Mythic" },
    ["Snowruff Sculpin"] = { 450000, "Epic" },
    ["Spiny Lobster"] = { 140000, "Legendary" },
    ["Squid"] = { 110000, "Mythic" },
    ["Starfall Moonray"] = { 2050000, "Secret" },
    ["Starfish"] = { 90, "" },
    ["Stingray"] = { 10100, "Legendary" },
    ["Sulphur Perch"] = { 5000000, "Uncommon" },
    ["Sunken King"] = { 0, "Exclusive" },
    ["Sunken Pharaoh"] = { 500000000, "Exotic" },
    ["Sunspine Sturgeon"] = { 2700000, "Mythic" },
    ["Sunspot Triggerfin"] = { 1400, "Epic" },
    ["Sunwheel Stingaree"] = { 110000, "Legendary" },
    ["Surgeonfish"] = { 18000, "Epic" },
    ["Swordfish"] = { 12300, "Legendary" },
    ["Tempest Sawfin"] = { 1900000, "Secret" },
    ["The Sunken Queen"] = { 0, "Exclusive" },
    ["Tideforge Archelon"] = { 2300000, "" },
    ["Tidesong Ribbonjaw"] = { 10000, "Legendary" },
    ["Tiger Shark"] = { 140000, "Mythic" },
    ["Trumpetfish"] = { 23600, "Epic" },
    ["Tuna"] = { 8980, "Legendary" },
    ["Tuskbreaker Narwhal"] = { 1700000000, "Exotic" },
    ["Vent Crab"] = { 8000000, "Rare" },
    ["Volcrown Megalodon"] = { 700000000000, "Exotic" },
    ["Vulcanheart Wyrm"] = { 1600000000, "Mythic" },
    ["Wels Catfish"] = { 2200000, "Legendary" },
    ["Whale"] = { 3500000, "" },
    ["Wobbegong"] = { 3250000, "Mythic" },
    ["Wrasse"] = { 22400, "Epic" },
    ["Wrathclaw Warlord"] = { 22000000, "Secret" },
    ["Wreckback Hermit"] = { 4000000, "Exotic" },
    ["Yellow Tang"] = { 314, "Rare" },
}

local Price = {}     -- name -> sell price
local RarityOf = {}  -- name -> rarity
local Odds = {}      -- name -> 1 in N, from the Index
local ItemNames = {}
local JunkNames = {}
local PRICE_FILE = "deepfishing/prices.json"

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

local function applyPrices(list)
    for name, v in pairs(list) do
        local p, r = v[1] or v.p, v[2] or v.r
        if tonumber(p) then Price[name] = tonumber(p) end
        if r and r ~= "" then RarityOf[name] = r end
    end
end

applyPrices(BuiltinPrices)
pcall(function()
    if isfile(PRICE_FILE) then
        applyPrices(game:GetService("HttpService"):JSONDecode(readfile(PRICE_FILE)))
    end
end)

-- full heap scan for every item table with a SellPrice. Slow (~5s), so it
-- only runs from the menu, and the result is cached to a file
local function refreshPrices()
    local res = getgc({ "SellPrice", "UIName", "Rarity" })
    local byTbl = {}
    for _, e in ipairs(res) do
        local key = tostring(e.tbl)
        byTbl[key] = byTbl[key] or {}
        byTbl[key][e.key] = e.value
    end
    local function unquote(s) return (tostring(s or ""):gsub('^"', ""):gsub('"$', "")) end
    local out, n = {}, 0
    for _, f in pairs(byTbl) do
        local price = tonumber(tostring(f.SellPrice))
        if price and f.UIName then
            local name = unquote(f.UIName)
            if not out[name] then
                out[name] = { p = price, r = unquote(f.Rarity) }
                n = n + 1
            end
        end
    end
    applyPrices(out)
    pcall(makefolder, "deepfishing")
    pcall(writefile, PRICE_FILE, game:GetService("HttpService"):JSONEncode(out))
    return n
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
    return RarityOf[name]
end

-- Items (enchant stones, scrolls, chests, keys, baits...) have no sell price
-- in the game data. With "Go for items" on they simply outrank every fish:
-- this number only orders the route planner, it is never shown as money
local ITEM_PRIORITY = 1e13

-- what a target is worth chasing. nil means not tracked at all
local function targetScore(name)
    if JunkNames[name] then return 0 end
    if ItemNames[name] then return S.goForItems and ITEM_PRIORITY or 0 end
    return Price[name]
end

local function fmtShort(n)
    if not n then return "?" end
    for _, u in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= u[1] then
            local v = n / u[1]
            local s = v >= 100 and string.format("%.0f", v) or string.format("%.1f", v)
            return "$" .. s:gsub("%.0$", "") .. u[2]
        end
    end
    return "$" .. string.format("%.0f", n)
end

---------------------------------------------------------------------------
-- session stats
---------------------------------------------------------------------------

local Stats = {
    start = os.clock(),
    casts = 0, perfects = 0, catches = 0, fights = 0, fightsWon = 0,
    earned = 0, spent = 0, caughtValue = 0,
    byRarity = {},
    best = nil, bestValue = 0,
    lastCash = nil,
}

local CatchLog = {}       -- newest first, capped
local CATCH_LOG_MAX = 100

-- Discord webhook: only discord.com webhook URLs are accepted, so a typo
-- can't send catch data somewhere else
local function validWebhook(url)
    return type(url) == "string"
        and (url:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+$")
            or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w_%-]+$")) ~= nil
end

local function sendWebhook(text)
    local url = S.webhookUrl
    if not (S.webhook and validWebhook(url)) then return false end
    task.spawn(function()
        local body = game:GetService("HttpService"):JSONEncode({ content = text })
        local ok, err = pcall(httppost, url, body, "application/json")
        if not ok then warn("[DeepFish] webhook: " .. tostring(err)) end
    end)
    return true
end

local function logCatch(name, rarity, mut, weight, value)
    table.insert(CatchLog, 1, {
        t = os.date("%H:%M:%S"), name = name, rarity = rarity, mut = mut, weight = weight, value = value,
    })
    if #CatchLog > CATCH_LOG_MAX then table.remove(CatchLog) end
end

local function exportCatchLog()
    local lines = { "time,name,rarity,mutation,weight,value" }
    for i = #CatchLog, 1, -1 do
        local c = CatchLog[i]
        lines[#lines + 1] = table.concat({ c.t, c.name, c.rarity, c.mut, c.weight, tostring(c.value) }, ",")
    end
    pcall(makefolder, "deepfishing")
    local file = "deepfishing/catches_" .. os.date("%Y%m%d_%H%M%S") .. ".csv"
    writefile(file, table.concat(lines, "\n"))
    return file, #CatchLog
end

-- Record one catch: stats, log, alerts, webhook. Items have no price, so
-- they count as $0 here.
local function recordCatch(name, rarity, value)
    value = value or 0
    Stats.catches = Stats.catches + 1
    Stats.byRarity[rarity] = (Stats.byRarity[rarity] or 0) + 1
    Stats.caughtValue = Stats.caughtValue + value
    logCatch(name, rarity, "", "", value)
    if value > 0 and value >= Stats.bestValue then
        Stats.bestValue = value
        Stats.best = name .. " " .. fmtShort(value)
    end
    if value > 0 and value >= S.catchAlertMin then
        local line = string.format("%s  %s  %s", name, rarity, fmtShort(value))
        if S.catchAlerts then Lib:Notify("Nice catch", line, 5, "success") end
        sendWebhook("Deep Fishing: caught " .. line)
    end
end
Stats.lastCash = num(txt(R.cash))

---------------------------------------------------------------------------
-- cast state, read off the HUD
---------------------------------------------------------------------------

local Cast = {
    castNo = 0,
    lastActive = 0,     -- last time something showed a cast in progress
    lastRelease = -1e9,
    lastThrowText = nil,
    fighting = false,
}

-- plain number parse: the label reads "28m" (metres), which num() would
-- take as 28 million
local function depthNow()
    return tonumber((txt(R.depth) or ""):match("[%d%.]+")) or 0
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
    -- Stay on the bait we were already following: during catch animations
    -- the camera swings and "nearest the camera" jumped to other players'
    -- baits. Only fall back to the camera when we have no bait yet or ours
    -- vanished (more than 40 studs from where it was).
    local okPrev, prev = pcall(function() return MyBait and MyBait.Position end)
    prev = okPrev and prev or nil
    local bestBait, bestDist = nil, math.huge
    for _, c in ipairs(workspace:GetChildren()) do
        local cls = c.ClassName
        if cls == "Part" and c.Name == "Bait" then
            local okP, p = pcall(function() return c.Position end)
            if okP and p then
                local d = prev and (p - prev).Magnitude or (p - camPos).Magnitude
                if d < bestDist then bestBait, bestDist = c, d end
            end
        elseif cls == "Model" then
            local name = c.Name
            local score = targetScore(name)
            if score ~= nil and not Players:FindFirstChild(name) then
                -- PrimaryPart comes back as an unreadable object in Matcha,
                -- so use the fish's Hitbox (or its first real part)
                local part = c:FindFirstChild("Hitbox")
                if not part then
                    for _, k in ipairs(c:GetChildren()) do
                        local kc = k.ClassName
                        if kc == "Part" or kc == "MeshPart" or kc == "UnionOperation" then part = k break end
                    end
                end
                local okPos, pos = pcall(function() return part and part.Position end)
                if part and okPos and pos then
                    local okSize, size = pcall(function() return part.Size end)
                    -- The game's own price tag on the fish (a RarityTag billboard
                    -- with a Price label) is its real sell value: base price x
                    -- size^3 x mutation, worked out by the game. Use it when it's
                    -- there; the species' base price is only the fallback.
                    local tag = nil
                    for _, k in ipairs(c:GetChildren()) do
                        tag = k:FindFirstChild("RarityTag")
                        if tag then break end
                    end
                    local tagPrice = tag and num(txt(tag:FindFirstChild("Price")))
                    local mutation = tag and txt(tag:FindFirstChild("Mutation"))
                    local price = tagPrice or Price[name]
                    -- planner worth; items have no real price (see ITEM_PRIORITY)
                    local worth = price
                    if ItemNames[name] then worth = S.goForItems and ITEM_PRIORITY or nil end
                    -- useless: junk, or a fish worth less than the minimum.
                    -- Never a target, and the bait steers around it
                    local useless = JunkNames[name] == true
                        or (not ItemNames[name] and price ~= nil and price < S.minValue)
                    -- wrappers never compare equal in Matcha, the address does
                    local okId, id = pcall(function() return part.Address end)
                    out[#out + 1] = {
                        id = okId and id or nil,
                        name = name,
                        part = part,
                        score = useless and 0 or (ItemNames[name] and score) or price or score,
                        useless = useless,
                        -- the game grabs when the bait is inside the hitbox,
                        -- padded to at least 1.25 studs a side
                        halfWidth = math.max(okSize and size and math.max(size.X, size.Z) / 2 or 1.25, 1.25),
                        rarity = ItemNames[name] and "Item" or JunkNames[name] and "Junk" or fishRarity(name),
                        price = price,
                        realPrice = tagPrice ~= nil,
                        mutation = mutation,
                        worth = worth,
                    }
                end
            end
        end
    end
    if prev and bestDist > 40 then
        -- ours is gone (new cast): pick again by distance to the camera
        bestBait, bestDist = nil, math.huge
        for _, c in ipairs(workspace:GetChildren()) do
            if c.ClassName == "Part" and c.Name == "Bait" then
                local okP, p = pcall(function() return c.Position end)
                if okP and p and (p - camPos).Magnitude < bestDist then
                    bestBait, bestDist = c, (p - camPos).Magnitude
                end
            end
        end
    end
    -- between casts forget it, so the next cast starts fresh
    if (Cast.depth or 0) <= 0 then bestBait = nil end
    MyBait = bestBait
    School = out
end

---------------------------------------------------------------------------
-- steering: the bait follows the mouse's X position on screen,
-- so point the mouse at the best fish above the bait
---------------------------------------------------------------------------

-- Same model the game uses (ThrowCinematic aim code): the pointer's X maps
-- to a sideways offset from the landing spot,
--     offset = pointer * tan(fov/2) * cameraDistance * aspect, capped at +-50
-- where pointer = mouseX / width * 2 - 1, and the bait sits at
-- landing + offset along the cast line. Working in world space means a
-- fish's distance from the camera can't skew the aim, and the goal cursor
-- position is computed outright instead of chased, so nothing oscillates.
--
-- The landing spot isn't exposed, so it's estimated each frame from where
-- the bait actually is versus where the pointer says it should be, and
-- smoothed (it doesn't move during a cast).
local Steer = {
    target = nil,   -- School entry being chased
    lastPos = nil,  -- its last position, to find it again after a rescan
    cursor = nil,   -- where we believe the cursor is (screen X)
    carry = 0,      -- sub-pixel remainder of the last move
    clock = 0,
    landing = nil,  -- estimated sideways coordinate of the landing spot
    manualUntil = 0,
}
local STEER_DEADZONE = 6
-- the game's CatchBandScale: 1.5 with the Fish Magnet gamepass, 1 without
local FISH_MAGNET = 1
local MAX_OFFSET = 48       -- game caps the offset at 50 studs
local POINTER_LIMIT = 0.94  -- keep the cursor off the very edge
local SWITCH_RATIO = 1.5    -- a new fish must be worth this much more to switch
local BAIT_LAG = 0.1        -- the game eases the bait sideways over about this long
-- Fish dart: logged speeds jump between -20 and +20 studs/s inside half a
-- second, so a long lead extrapolates noise. Track the average lane until the
-- last stretch, then follow tightly with a short lead only.
local INTERCEPT_HORIZON = 0.8  -- seconds to arrival when tight tracking starts
local LEAD_MAX = 0.12          -- lead covers the bait's lag, nothing more
local FISH_SPEED_CAP = 25      -- studs/s; anything faster is a measurement spike

local function entryPos(f)
    local ok, p = pcall(function() return f.part.Position end)
    if ok then return p end
end

---------------------------------------------------------------------------
-- Direct steering. The game's throw controller keeps the bait's sideways
-- offset in a field, AimOffset, and stops reading the mouse while
-- AimLocked is true; its own auto-fish steers that way. We do the same:
-- lock the aim and write the offset, so the bait goes exactly where we say
-- with no cursor in between.
--
-- The controller's field storage moves whenever the game grows the table,
-- so slots are re-found by a memory scan (~2s, run when a cast starts) and
-- checked before every single write. A slot whose key no longer reads
-- AimOffset / AimLocked is never written to.
---------------------------------------------------------------------------

local AimMem = { aim = nil, ptr = nil, locating = false, lastLocate = -1e9, held = false, k = nil }

-- reads exactly one node at an address a scan returned; never a raw window
local function slotIs(addr, key, kind)
    if not addr then return false end
    local ok, t = pcall(readtbl, addr, 1)
    local e = ok and type(t) == "table" and t[1]
    return e ~= nil and tostring(e.key) == key and e.type == kind
end

-- Labels alone aren't enough: freed memory keeps its labels for a while,
-- and once it's reused the "AimOffset" there read as a 220-digit number.
-- Writing into reused memory could crash the game, so the values must be
-- sane too (the game caps AimOffset at 50, AimPointer is -1..1).
local function saneNum(addr, limit)
    local ok, v = pcall(memory_read, "double", addr)
    return ok and type(v) == "number" and v == v and math.abs(v) <= limit
end

function AimMem.valid()
    return slotIs(AimMem.aim, "AimOffset", "number") and slotIs(AimMem.ptr, "AimPointer", "number")
        and saneNum(AimMem.aim, 60) and saneNum(AimMem.ptr, 1.5)
end

-- Find AimOffset and AimPointer with Matcha's own scan, one field each.
-- An earlier version found AimLocked by reading a wide block of raw memory
-- around AimOffset; when that block ran past the table's memory Matcha tried
-- to decode garbage and crashed. Nothing here reads outside a scan result.
-- (The scan skips fields that are false or zero, hence a few anchors.)
-- Every scan walks the game's memory while the game is changing it, and
-- Windows logged Matcha dying with access violations while scans ran. So:
-- one anchor (ThrowDistance is filled in from the moment of the throw), at
-- most one search per cast, and a long pause after a failed one.
local AIM_ANCHORS = { "ThrowDistance" }

-- every match for a field: live table and dead copies alike
local function scanAll(field)
    local out = {}
    for _, anchor in ipairs(AIM_ANCHORS) do
        local ok, res = pcall(findgc, anchor, { [field] = "number" })
        if ok and type(res) == "table" then
            for _, e in ipairs(res) do
                if tostring(e.key) == field and e.addr then out[#out + 1] = e.addr end
            end
        end
        if #out > 0 then break end
    end
    return out
end

function AimMem.locate()
    local now = os.clock()
    local rescuing = AimMem.wantRescue == true
    -- the scan blocks this script for ~2s (not the game). After a failed scan
    -- wait a while; after a good one the table may simply have moved again
    local wait = AimMem.lastFailed and 10 or 0.5
    if AimMem.locating or now - AimMem.lastLocate < wait then return end
    if AimMem.searchedCast == Cast.castNo then
        -- already searched this cast: one more only if the slots went dead
        if not AimMem.wantRescue or AimMem.rescuedCast == Cast.castNo then return end
        AimMem.rescuedCast = Cast.castNo
    end
    AimMem.searchedCast, AimMem.wantRescue = Cast.castNo, false
    AimMem.locating, AimMem.lastLocate = true, now
    task.spawn(function()
        -- When the game reorganizes its throw table the old copies stay in
        -- memory with their labels, and the scan returns all of them; taking
        -- the first match often picked a dead copy. The live table's
        -- AimPointer is set from the real mouse at the start of each cast,
        -- while dead copies hold whatever was last written into them. So pair
        -- each pointer with the AimOffset stored next to it (same node array,
        -- within 32 KB) and keep the pair whose pointer matches the mouse.
        local aims = scanAll("AimOffset")
        local ptrs = #aims > 0 and scanAll("AimPointer") or {}
        local vp = camera.ViewportSize
        local mousePtr = math.clamp(mouse.X / math.max(vp.X, 1) * 2 - 1, -1, 1)
        -- mid-cast rescue: the live pointer holds what we last wrote, not the
        -- mouse
        local expect = (rescuing and AimMem.lastPtrWritten) or mousePtr
        local aim, ptr, bestErr = nil, nil, math.huge
        for _, p in ipairs(ptrs) do
            local okV, v = pcall(memory_read, "double", p)
            -- skip copies whose memory has been reused (garbage values)
            if okV and type(v) == "number" and v == v and math.abs(v) <= 1.5 then
                local nearA, nearD = nil, 32768
                for _, a in ipairs(aims) do
                    local d = math.abs(a - p)
                    local okA, av = pcall(memory_read, "double", a)
                    local sane = okA and type(av) == "number" and av == av and math.abs(av) <= 60
                    if sane and d < nearD then nearA, nearD = a, d end
                end
                local err = math.abs(v - expect)
                if nearA and err < bestErr then aim, ptr, bestErr = nearA, p, err end
            end
        end
        AimMem.candidates = #ptrs
        AimMem.aim, AimMem.ptr = aim, ptr
        AimMem.lastFailed = not (aim and ptr)
        AimMem.scans = (AimMem.scans or 0) + 1
        AimMem.lastScanTime = os.clock() - now
        AimMem.locating = false
    end)
end

local function readNum(addr)
    local ok, v = pcall(memory_read, "double", addr)
    if ok and type(v) == "number" and v == v then return v end
end

function AimMem.read() return readNum(AimMem.aim) end

-- Steer by writing AimPointer, where the game thinks the mouse is (-1..1).
-- While the real mouse is still the game keeps the stored pointer and eases
-- AimOffset toward pointer * k (k = studs per pointer unit, about the screen
-- half-width at the bait, sign included). No lock: moving the mouse hands
-- control straight back. One number slot, only when it changes.
--
-- k comes from the camera geometry (the game's own formula: screen half-width
-- at the bait), with the direction calibration measured. An earlier version
-- learned k from AimOffset / AimPointer, but while AimOffset is still easing
-- after a pointer change that ratio briefly has the wrong sign, and those
-- samples dragged k from about +25 to -4.6. Any leftover scale error is
-- trimmed by a slow correction toward the offset we actually asked for.
function AimMem.write(offset, half, sign, chasing)
    local ptr = readNum(AimMem.ptr)
    local cur = AimMem.read()
    local k = (half and half > 5 and half or 25) * (sign or 1)
    AimMem.k = k
    -- only while the goal holds steady: during a big move the game is still
    -- easing toward it, and that gap isn't a scale error
    if cur and AimMem.lastWant and math.abs(offset - AimMem.lastWant) < 0.5 then
        local miss = AimMem.lastWant - cur
        AimMem.corr = math.clamp((AimMem.corr or 0) + miss * 0.02, -15, 15)
    end
    local want = math.clamp((offset + (AimMem.corr or 0)) / k, -1, 1)
    -- Dead memory looks valid (see the cast counter): if AimOffset hasn't
    -- budged for a second while we keep asking for different positions,
    -- drop the slots and allow one rescue search this cast
    -- (only counts frames while chasing a fish: at the end of a cast the game
    -- holds the aim itself for the reel-in, and that isn't dead memory)
    if cur ~= AimMem.prevCur then
        AimMem.frozenFrames = 0
    elseif chasing and AimMem.prevWant and math.abs(want - AimMem.prevWant) > 0.01 then
        AimMem.frozenFrames = (AimMem.frozenFrames or 0) + 1
        if AimMem.frozenFrames > 30 then
            AimMem.aim, AimMem.ptr, AimMem.frozenFrames = nil, nil, 0
            AimMem.wantRescue = true
            return
        end
    end
    AimMem.prevCur, AimMem.prevWant = cur, want
    AimMem.lastWant = offset
    if not ptr or math.abs(ptr - want) > 0.002 then
        pcall(memory_write, "double", AimMem.ptr, want)
    end
    AimMem.lastPtrWritten = want
    AimMem.held = true
end

-- nothing is locked, so there is nothing to hand back
function AimMem.release()
    AimMem.held = false
end

-- Where the bait's base is and which way AimOffset pushes it.
--
-- The game places the bait at base + axis * AimOffset. The base is NOT
-- fixed: while the bait dives it slides along the cast line
-- (DiveTo:Lerp(ArcTo, t)), which on screen is the same left-right direction
-- the aim moves. Treating it as a fixed landing spot made every position
-- wander by tens of studs. So the base is re-measured every frame from where
-- the bait really is minus the offset it was given ~0.1s earlier (the bait
-- trails the offset by about that), lightly smoothed. That is a feedback
-- loop on the bait itself, and drift is absorbed as it happens.
--
-- Measured: one stud of bait per unit of offset, direction +1, in every
-- test. (An automatic direction flip used to live here; during a fight the
-- bait is pinned, so it read that as "steering backwards", flipped, and
-- carried the wrong direction into every later cast.)
--
-- The base only moves smoothly (the dive drift), so a sample that jumps far
-- from the estimate is a yank or a pinned bait, not drift. Those are ignored
-- unless they persist for a third of a second.
local AimFit = { hist = {}, slope = 1, landing = nil, oddFor = 0 }
local AIM_TRAIL = 0.1
local BASE_JUMP = 6

function AimFit.reset()
    AimFit.hist, AimFit.landing, AimFit.oddFor = {}, nil, 0
end

function AimFit.add(now, offset, baitLat, quiet, dt)
    local h = AimFit.hist
    h[#h + 1] = { t = now, v = offset }
    while #h > 2 and h[2].t <= now - AIM_TRAIL do table.remove(h, 1) end
    local est = baitLat - AimFit.slope * h[1].v
    if not AimFit.landing then
        AimFit.landing = est
    elseif quiet then
        dt = dt or 0.016
        if math.abs(est - AimFit.landing) > BASE_JUMP then
            AimFit.oddFor = AimFit.oddFor + dt
            if AimFit.oddFor < 0.33 then return end
        else
            AimFit.oddFor = 0
        end
        -- ~0.15s smoothing: follows the dive's drift, irons out jitter
        AimFit.landing = AimFit.landing + (est - AimFit.landing) * math.min(1, dt * 7)
    end
end


-- sideways axis (camera right, flattened) and studs from screen centre to
-- edge at the bait's distance
local function steerGeometry(baitPos)
    local cf = camera.CFrame
    local r = cf.RightVector
    local axis = Vector3.new(r.X, 0, r.Z)
    if axis.Magnitude < 0.2 then return nil end
    axis = axis.Unit
    local dist = (baitPos - cf.Position):Dot(cf.LookVector)
    if dist <= 1 then return nil end
    local vp = camera.ViewportSize
    local half = math.tan(math.rad(camera.FieldOfView) / 2) * dist * (vp.X / vp.Y)
    return axis, half, vp.X
end

-- pointer (-1..1) that puts the bait at this sideways coordinate, or nil if
-- out of reach
local function goalPointer(lat, half)
    if not Steer.landing then return nil end
    local offset = lat - Steer.landing
    if math.abs(offset) > MAX_OFFSET then return nil end
    -- Direct steers through the game's mouse pointer, which only reaches the
    -- screen edge: about half the screen's width at the bait (~25 studs), not
    -- the game's 50-stud cap. Anything further looked reachable, pinned the
    -- bait at the edge, and (items rank first) blocked the whole cast.
    if S.steerMode == "Direct" then
        if half and math.abs(offset) > POINTER_LIMIT * half then return nil end
        return offset
    end
    local p = offset / half
    if math.abs(p) > POINTER_LIMIT then return nil end
    return p
end

-- value discounted by how far the bait still has to rise to meet the fish,
-- so among similar fish the next one up wins; a far richer fish still does
local GAP_FALLOFF = 25
local function effectiveScore(f, pos, baitY)
    return f.score / (1 + math.max(pos.Y - baitY, 0) / GAP_FALLOFF)
end

-- a fish counts once it has popped up on screen: inside the camera view and
-- not below the bait (the same set the game shows markers for). Must run in
-- a render callback, WorldToScreen returns nothing anywhere else
local function onScreen(pos)
    local scr, vis = WorldToScreen(pos)
    if not vis then return false end
    local vp = camera.ViewportSize
    return scr.X >= 0 and scr.X <= vp.X and scr.Y >= 0 and scr.Y <= vp.Y
end

local function candidate(pos, baitY, axis, half)
    return pos.Y >= baitY - 2 and goalPointer(pos:Dot(axis), half) ~= nil and onScreen(pos)
end

-- fish already on the hook ride just under the bait and would otherwise
-- look like a perfect target forever; keyed by part address, per cast
Steer.caught = {}

local function sameFish(a, b)
    if not (a and b) then return false end
    if a.id and b.id then return a.id == b.id end
    return a.name == b.name
end

-- How many more fish this cast can take, from the cast HUD's "caught/cap"
-- counter. Rod and bait upgrades change cap, so it is read every plan.
-- Capacity as the Upgrades menu lists it ("13 Fishes"), the fallback when
-- the cast counter can't be read
local function upgradeCapacity()
    local up = pg:FindFirstChild("Interfaces")
    up = up and up:FindFirstChild("Upgrades")
    if not up then return nil end
    for _, d in ipairs(up:GetDescendants()) do
        if d.ClassName == "TextLabel" and d.Name == "UpgradeName" and txt(d) == "CAPACITY" then
            local amount = d.Parent and findLabel(d.Parent, "Amount")
            local n = amount and tonumber((txt(amount) or ""):match("(%d+)"))
            if n and n > 0 then return n end
        end
    end
end

local function slotsLeft()
    local a, b = (txt(R.fishAmount) or ""):match("(%d+)%s*/%s*(%d+)")
    a, b = tonumber(a), tonumber(b)
    if not (a and b and b > 0) then
        local cap = upgradeCapacity() or 3
        return cap, cap, 0
    end
    -- Right after a cast starts the counter can still show the last cast's
    -- count. Until this cast has caught something, every slot is free.
    -- (The third value stays the raw count: catch tracking diffs it.)
    if not Steer.caughtThisCast then return b, b, a end
    return math.max(b - a, 0), b, a
end

-- items outrank every fish here too, like in the other modes
local RarityRank = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6, Secret = 7, Exotic = 8, Exclusive = 9, Item = 10 }

-- what one fish adds to a route, by the chosen priority
local function routeWorth(f)
    local price = f.worth or 0
    if S.targetMode == "Rarity" then
        -- rarer always wins; price only breaks ties inside a rarity
        return (RarityRank[f.rarity] or 0) * 1e15 + price
    elseif S.targetMode == "Most fish" then
        -- every fish worth keeping counts the same; price breaks ties
        return 1e15 + price
    end
    return price
end

-- Plan the best set of fish for the slots left, in the order the rising bait
-- meets them (bottom to top), and steer for the first one. Recomputed a few
-- times a second, so the route adapts as fish swim and slots fill.
--
-- A route is feasible when the bait can get sideways from one fish to the
-- next in the time it takes to rise between them. The bait follows the aim
-- in ~0.1s, so the real limit is fish moving: ROUTE_SLACK studs of leeway.
--
-- Dynamic program over fish sorted by height: best[i][k] = best total worth
-- of a route of k fish ending at fish i.
local ROUTE_LAT_SPEED = 60 -- studs/s the bait can move sideways, conservatively
local ROUTE_SLACK = 3

-- Every fish's sideways swim speed, smoothed. Fish in this game cross the
-- school on set paths at a fairly steady speed, so this predicts well where
-- each one will be when the rising bait reaches its height.
local PREDICT_MAX = 2.5 -- seconds ahead; a fish's crossing doesn't last forever
local function fishVelocity(f, lat, now)
    Steer.fishVel = Steer.fishVel or {}
    local key = f.id or f.name
    local rec = Steer.fishVel[key]
    if not rec then
        rec = { lat = lat, t = now, v = 0 }
        Steer.fishVel[key] = rec
    elseif now - rec.t > 0.02 then
        local v = math.clamp((lat - rec.lat) / (now - rec.t), -FISH_SPEED_CAP, FISH_SPEED_CAP)
        rec.v = rec.v + (v - rec.v) * 0.3
        rec.lat, rec.t = lat, now
    end
    return rec.v
end

local function planRoute(baitPos, axis, half)
    local baitY, baitLat = baitPos.Y, baitPos:Dot(axis)
    local rise = math.max(Cast.rise or 10, 2)
    local left = slotsLeft()
    Steer.slotsLeft = left
    local cands = {}
    local why = { value = 0, below = 0, reach = 0, screen = 0, ok = 0 }
    Steer.why = why
    if left > 0 then
        for _, f in ipairs(School) do
            if f.score <= 0 or f.useless then why.value = why.value + 1 end
            if f.score > 0 and not f.useless and not Steer.caught[f.id or 0] then
                local pos = entryPos(f)
                if pos and pos.Y >= baitY - 1 then
                    -- every fish in the cast, on screen or not, at the lane it
                    -- will be in when the bait reaches its height
                    local now = os.clock()
                    local eta = math.max(pos.Y - baitY, 0) / rise
                    local lat = pos:Dot(axis) + fishVelocity(f, pos:Dot(axis), now) * math.min(eta, PREDICT_MAX)
                    local keep = goalPointer(lat, half) ~= nil
                    if not keep then why.reach = why.reach + 1 end
                    if keep then why.ok = why.ok + 1 end
                    if keep then
                        cands[#cands + 1] = { f = f, y = pos.Y, lat = lat, worth = routeWorth(f) }
                    end
                end
            end
        end
    end
    -- Jackpots: a fish worth far more than the rest of what's visible (5x the
    -- typical one, or over $50K) must be in the route whenever it can be
    -- reached, even if a string of cheaper fish adds up to more
    if #cands > 1 then
        local worths = {}
        for i, c in ipairs(cands) do worths[i] = c.worth end
        table.sort(worths)
        local typical = worths[math.ceil(#worths / 2)]
        for _, c in ipairs(cands) do
            local price = c.f.price or 0
            if c.worth >= typical * 5 or price >= 50000 then
                c.worth = c.worth * 10
                c.jackpot = true
            end
        end
    end
    table.sort(cands, function(p, q) return p.y < q.y end)

    local n, K = #cands, math.min(left, 12)
    local best, prevOf = {}, {}
    local topV, topI, topK = 0, nil, 0
    for i = 1, n do
        best[i], prevOf[i] = {}, {}
        local ci = cands[i]
        -- straight from the bait
        local reach0 = ROUTE_LAT_SPEED * math.max(ci.y - baitY, 0) / rise + ROUTE_SLACK
        if math.abs(ci.lat - baitLat) <= reach0 then
            best[i][1] = ci.worth
        end
        for j = 1, i - 1 do
            local cj = cands[j]
            local reach = ROUTE_LAT_SPEED * math.max(ci.y - cj.y, 0) / rise + ROUTE_SLACK
            if math.abs(ci.lat - cj.lat) <= reach then
                for k = 1, K - 1 do
                    local v = best[j][k]
                    if v and (not best[i][k + 1] or v + ci.worth > best[i][k + 1]) then
                        best[i][k + 1] = v + ci.worth
                        prevOf[i][k + 1] = j
                    end
                end
            end
        end
        for k = 1, K do
            local v = best[i][k]
            if v and v > topV then topV, topI, topK = v, i, k end
        end
    end

    -- walk back from the best end to recover the route, bottom first
    local route = {}
    local i, k = topI, topK
    while i do
        table.insert(route, 1, cands[i].f)
        local j = prevOf[i][k]
        i, k = j, k - 1
    end

    local ids = {}
    for _, f in ipairs(route) do ids[f.id or 0] = true end
    -- real money only: items have no price
    local money = 0
    for _, f in ipairs(route) do money = money + (f.price or 0) end
    Steer.route, Steer.routeIds, Steer.routeWorth = route, ids, money

    local cur = route[1]
    if not sameFish(cur, Steer.target) then
        -- a different fish: restart its motion tracking
        Steer.tLat, Steer.tRaw, Steer.tVel, Steer.hookedFor = nil, nil, 0, 0
    end
    Steer.target = cur
    Steer.lastPos = cur and entryPos(cur) or nil
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
-- guards: rod equip, full inventory, staff
---------------------------------------------------------------------------

-- number key of the hotbar's rod slot (a frame named "Rod" whose number
-- label sits inside it); falls back to 1, where the game puts the rod
local function rodSlotKey()
    local slot = R.hotbar and R.hotbar:FindFirstChild("Rod")
    if slot then
        for _, d in ipairs(slot:GetDescendants()) do
            if d.ClassName == "TextLabel" and d.Parent and d.Parent.Name == "Number" then
                local n = tonumber(txt(d))
                if n and n >= 1 and n <= 9 then return n end
            end
        end
    end
    return 1
end

local function inventoryFull()
    -- during a cast the HUD shows caught/capacity; capacity is 0 when full
    local a = txt(R.fishAmount)
    if a and a:match("/%s*0$") then return true end
    local inv = (txt(R.invFish) or ""):gsub(",", "")
    local used, cap = inv:match("(%d+)%s*/%s*(%d+)")
    used, cap = tonumber(used), tonumber(cap)
    return used ~= nil and cap ~= nil and cap > 0 and used >= cap
end

-- staff carry a Role attribute; it's empty for everyone else
local function findStaff()
    for _, p in ipairs(Players:GetPlayers()) do
        local ok, role = pcall(function() return p:GetAttribute("Role") end)
        if ok and type(role) == "string" and role ~= "" then
            return tostring(p.Name) .. " (" .. role .. ")"
        end
    end
end

local function setAutoCast(on)
    S.autoCast = on
    if UI.autoCast then pcall(function() UI.autoCast:Set(on) end) end
end

---------------------------------------------------------------------------
-- teleports
---------------------------------------------------------------------------

local function instPos(inst)
    if not inst then return nil end
    -- a Model has no Position: Matcha then returns nil (or a child named so)
    local ok, p = pcall(function() return inst.Position end)
    if ok and p ~= nil and pcall(function() return p.Magnitude end) then return p end
    local hrp = inst:FindFirstChild("HumanoidRootPart")
    if hrp then
        local okH, ph = pcall(function() return hrp.Position end)
        if okH then return ph end
    end
    for _, c in ipairs(inst:GetChildren()) do
        local kc = c.ClassName
        if kc == "Part" or kc == "MeshPart" then
            local okC, pc = pcall(function() return c.Position end)
            if okC then return pc end
        end
    end
end

-- the world you're in: the Interactable folder whose sell NPC is nearest
local function interactables()
    local worlds = workspace:FindFirstChild("World")
    if not worlds then return nil end
    local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local me = root and root.Position
    local best, bestD = nil, math.huge
    for _, w in ipairs(worlds:GetChildren()) do
        local inter = w:FindFirstChild("Interactable")
        local p = inter and instPos(inter:FindFirstChild("NPC_Sell"))
        if p then
            local d = me and (p - me).Magnitude or 0
            if d < bestD then best, bestD = inter, d end
        end
    end
    return best
end

local TeleportSpots = {
    { label = "Sell fish", child = "NPC_Sell" },
    { label = "Rod shop", child = "Rods" },
    { label = "Bait shop", child = "Baits" },
    { label = "Upgrades", child = "Upgrades" },
    { label = "Boats", child = "NPC_Boat" },
    { label = "World teleporter", child = "Teleport" },
}

-- one position write, landing a few studs short of the spot so you don't
-- end up inside an NPC
local function teleportTo(pos)
    local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (root and pos) then return false end
    local me = root.Position
    local flat = Vector3.new(me.X - pos.X, 0, me.Z - pos.Z)
    local back = flat.Magnitude > 0.1 and flat.Unit * 5 or Vector3.new(0, 0, 5)
    -- Position only. A full CFrame write with a facing direction crashed the
    -- game on a long jump; a plain position move is the lightest write there is
    local ok = pcall(function()
        root.Position = pos + back + Vector3.new(0, 3, 0)
        root.Velocity = Vector3.new(0, 0, 0)
    end)
    if not ok then return false end
    return true
end

local function teleportToSpot(spot)
    local inter = interactables()
    local pos = inter and instPos(inter:FindFirstChild(spot.child))
    if not pos then
        Lib:Notify("Teleport", spot.label .. " isn't in this world", 3, "error")
        return
    end
    if teleportTo(pos) then Lib:Notify("Teleport", spot.label, 2, "info") end
end

local function saveFishingSpot()
    local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if root then Hub.savedSpot = root.Position end
    return Hub.savedSpot
end

---------------------------------------------------------------------------
-- hotkeys. The menu library's own keybinds look keys up by lowercase name
-- while storing F-keys as "F6", so F-keys never fire; these poll directly
---------------------------------------------------------------------------

local VK = {
    None = false, Insert = 0x2D, Home = 0x24, End = 0x23, Delete = 0x2E, PageUp = 0x21, PageDown = 0x22,
}
for i = 1, 12 do VK["F" .. i] = 0x6F + i end
local HotkeyNames = { "None", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "Insert", "Home", "End", "Delete", "PageUp", "PageDown" }

local function toggleSetting(handle, key, label)
    local on = not S[key]
    if handle then pcall(function() handle:Set(on) end) else S[key] = on end
    Lib:Notify(label, on and "on" or "off", 1.5, on and "success" or "warning")
end

local function panic()
    setAutoCast(false)
    if UI.autoSteer then pcall(function() UI.autoSteer:Set(false) end) else S.autoSteer = false end
    S.autoFight = false
    if UI.autoFight then pcall(function() UI.autoFight:Set(false) end) end
    Lib:Notify("Panic", "all automation off", 3, "warning")
end

local Hotkeys = {
    { setting = "keyCast", run = function() toggleSetting(UI.autoCast, "autoCast", "Auto cast") end },
    { setting = "keySteer", run = function() toggleSetting(UI.autoSteer, "autoSteer", "Auto steer") end },
    { setting = "keyEsp", run = function() toggleSetting(UI.fishEsp, "fishEsp", "Fish ESP") end },
    { setting = "keyPanic", run = panic },
}

---------------------------------------------------------------------------
-- loops
---------------------------------------------------------------------------

-- hotkey loop, ~30 Hz, edge-triggered; only while Roblox has focus, since
-- iskeypressed sees keys pressed in any window
task.spawn(function()
    local held = {}
    while Hub.running do
        if focused() then
            for _, h in ipairs(Hotkeys) do
                local code = VK[S[h.setting]]
                local down = code and iskeypressed(code) or false
                if down and not held[h.setting] then
                    local ok, err = pcall(h.run)
                    if not ok then warn("[DeepFish] hotkey: " .. tostring(err)) end
                end
                held[h.setting] = down
            end
        end
        task.wait(0.03)
    end
end)

-- webhook session summary every N minutes
task.spawn(function()
    local last = os.clock()
    while Hub.running do
        task.wait(5)
        local every = (S.summaryMins or 0) * 60
        if every > 0 and os.clock() - last >= every then
            last = os.clock()
            local h = math.max((os.clock() - Stats.start) / 3600, 1 / 3600)
            sendWebhook(string.format(
                "Deep Fishing summary (%s): %d catches, %s caught, %s earned (%s/hr), best: %s",
                fmtTime(os.clock() - Stats.start), Stats.catches, fmtShort(Stats.caughtValue),
                fmtMoney(Stats.earned), fmtMoney(Stats.earned / h), Stats.best or "-"))
        elseif every <= 0 then
            last = os.clock()
        end
    end
end)

-- guard loop, 1 Hz
task.spawn(function()
    local lastEquip, fullWarned = 0, false
    while Hub.running do
        local ok, err = pcall(function()
            local staff = findStaff()
            if staff ~= Guard.staff then
                Guard.staff = staff
                if S.staffGuard then
                    if staff then
                        Lib:Notify("Staff in server", staff .. " - automation paused", 10, "warning")
                        sendWebhook("Deep Fishing: staff in server, automation paused: " .. staff)
                    else
                        Lib:Notify("Staff left", "automation resumed", 5, "info")
                    end
                end
            end

            local full = inventoryFull()
            if S.fullGuard and S.autoCast and full and not fullWarned then
                fullWarned = true
                setAutoCast(false)
                Lib:Notify("Inventory full", "auto cast stopped - sell some fish", 8, "warning")
                sendWebhook("Deep Fishing: inventory full, auto cast stopped")
            elseif not full then
                fullWarned = false
            end

            local now = os.clock()
            if S.autoEquip and S.autoCast and not rodHeld() and (Cast.depth or 0) == 0
                and not Cast.fighting and now - lastEquip > 3 and canAct() then
                local n = rodSlotKey()
                if n then
                    lastEquip = now
                    keypress(0x30 + n)
                    task.wait(0.05)
                    keyrelease(0x30 + n)
                end
            end
        end)
        if not ok then warn("[DeepFish] guards: " .. tostring(err)) end
        task.wait(1)
    end
end)

-- state loop: HUD reads, fights, auto cast
task.spawn(function()
    local lastFightText = select(2, fightCount())
    while Hub.running do
        local ok, err = pcall(function()
            local now = os.clock()
            local d = depthNow()
            Cast.depth = d
            -- bait rise speed from the depth readout (1 m = 1 stud), measured
            -- over half-second windows: the label only shows whole metres
            if d > 0 then
                if not Cast.riseAnchor then
                    Cast.riseAnchor = { d = d, t = now }
                elseif now - Cast.riseAnchor.t >= 0.5 then
                    local rate = (Cast.riseAnchor.d - d) / (now - Cast.riseAnchor.t)
                    -- The catch window rises at ~10/s. The reel-in at the end of
                    -- a cast shoots up much faster and used to drag this to 20+,
                    -- which then carried into the next cast, so only plausible
                    -- rates count
                    if rate > 4 and rate < 18 then
                        Cast.rise = (Cast.rise or 10) + (rate - (Cast.rise or 10)) * 0.3
                    end
                    Cast.riseAnchor = { d = d, t = now }
                end
            else
                Cast.riseAnchor = nil
                Cast.rise = 10
            end
            -- The bait came back up: this cast is over. Forget the aim
            -- addresses (the game reorganizes that table between casts) and
            -- count a new cast, however quickly the next throw follows.
            if d == 0 and Cast.wasDeep then
                Cast.castNo = (Cast.castNo or 0) + 1
                AimMem.aim, AimMem.ptr = nil, nil
            end
            Cast.wasDeep = d > 0
            local th = txt(R.throwDist)
            -- a throw starting after a pause is a new cast (used to allow
            -- one memory search per cast)
            if d == 0 and th ~= Cast.lastThrowText and now - Cast.lastActive > 1.5 then
                Cast.castNo = (Cast.castNo or 0) + 1
                -- The game reorganizes its throw table between casts and the
                -- abandoned copy keeps the old labels, so a slot can look valid
                -- while being dead memory. Don't trust last cast's addresses.
                AimMem.aim, AimMem.ptr = nil, nil
            end
            if d > 0 or th ~= Cast.lastThrowText then
                Cast.lastActive = now
            end
            -- a throw has started (the distance counter is moving, the bait
            -- isn't in the water yet): find the aim fields now, during the
            -- ~2s flight, so steering is ready at the splash
            if d == 0 and th ~= Cast.lastThrowText and S.autoSteer and S.steerMode == "Direct"
                and not AimMem.aim then
                AimMem.locate()
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
            if S.autoSteer or S.fishEsp or S.spawnAlert then collectSchool() else School = {} end

            -- something valuable turned up in this cast's school
            if (Cast.depth or 0) > 0 then
                if S.spawnAlert then
                    for _, f in ipairs(School) do
                        local key = f.id or f.name
                        if (f.price or 0) >= S.spawnAlertMin and not Hub.spawnSeen[key] then
                            Hub.spawnSeen[key] = true
                            local line = string.format("%s (%s, %s) is in your school", f.name, f.rarity or "?", fmtShort(f.price))
                            Lib:Notify("Rare fish!", line, 6, "success")
                            sendWebhook("Deep Fishing: " .. line)
                        end
                    end
                end
            elseif next(Hub.spawnSeen) then
                Hub.spawnSeen = {}
            end

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

-- Catches, counted off the cast HUD's caught/cap counter (the game no
-- longer pops a notification per catch). The fish riding just under the
-- bait when the counter ticks is the one that was caught.
Steer.logged = {}
local function trackCatches(baitPos)
    local _, _, caughtNow = slotsLeft()
    local prev = Steer.caughtCount
    Steer.caughtCount = caughtNow
    if not prev or caughtNow <= prev then return end
    Steer.lastHookAt = os.clock()
    Steer.caughtThisCast = true
    for _ = 1, caughtNow - prev do
        local best, bestD = nil, 6
        if baitPos then
            for _, f in ipairs(School) do
                if not Steer.logged[f.id or 0] then
                    local pos = entryPos(f)
                    local d = pos and (pos - baitPos).Magnitude
                    if d and d < bestD then best, bestD = f, d end
                end
            end
        end
        if best then Steer.logged[best.id or 0] = true end
        recordCatch(best and best.name or "Fish", best and best.rarity or "?", best and best.price or 0)
    end
end

-- renderer: steering and ESP
local function renderStep(dt)
    dt = math.min(dt or 0.016, 0.05)
    local casting = (Cast.depth or 0) > 0
    local baitPos = nil
    if casting and MyBait then
        local ok, p = pcall(function() return MyBait.Position end)
        if ok and p then baitPos = p end
    end

    if baitPos then trackCatches(baitPos) end

    local axis, half, width
    if S.autoSteer and baitPos then
        axis, half, width = steerGeometry(baitPos)
    end

    local direct = S.steerMode == "Direct"
    local aimLive = false
    if direct and axis then
        -- aim slots: found by a background scan when a cast starts, checked
        -- every frame before anything touches them
        aimLive = AimMem.valid()
        if not aimLive then
            -- The game can reorganize the table mid-cast too. A slot that was
            -- live and died earns one rescue search in this same cast;
            -- without it steering sat idle for the rest of the cast.
            if AimMem.aim then
                AimMem.aim, AimMem.ptr = nil, nil
                AimMem.wantRescue = true
            end
            AimMem.locate()
        end
    end
    -- a fish fighting on the line pins the bait: no steering, no learning
    local fightNow = Cast.fighting or false

    -- landing spot estimate. Direct: fitted from the offset we read back
    -- against where the bait really is. Mouse modes: bait position minus
    -- the offset the current pointer asks for.
    if axis and direct then
        local offset = aimLive and AimMem.read()
        if offset then
            -- A catch yanks the bait about: the caught counter going up, a
            -- fish riding under it, or a fight. Don't learn from those moments
            local quiet = not fightNow and (Steer.hookedFor or 0) == 0
                and os.clock() - (Steer.lastHookAt or -1e9) > 0.6
            AimFit.add(os.clock(), offset, baitPos:Dot(axis), quiet, dt)
            Steer.landing = AimFit.landing
        end
    elseif axis then
        local pointer = math.clamp(mouse.X / width * 2 - 1, -1, 1)
        local sample = baitPos:Dot(axis) - pointer * half
        if Steer.landing then
            Steer.landing = Steer.landing + (sample - Steer.landing) * math.min(1, dt * 2)
        else
            Steer.landing = sample
        end
    end
    if axis and Steer.landing then
        Steer.clock = Steer.clock + dt
        if Steer.clock >= 0.15 then
            Steer.clock = 0
            planRoute(baitPos, axis, half)
        end
    elseif not axis then
        Steer.target, Steer.lastPos, Steer.landing = nil, nil, nil
        Steer.route, Steer.routeIds, Steer.routeWorth = nil, nil, 0
        if not casting then
            Steer.caughtCount, Steer.caughtThisCast = nil, nil
            if next(Steer.logged) then Steer.logged = {} end
            Steer.fishVel = {}
            AimMem.corr, AimMem.lastWant = 0, nil
            if next(Steer.caught) then Steer.caught = {} end
            if AimFit.landing then AimFit.reset() end
        end
    end

    -- where the bait should be sideways (studs along the axis), or nil
    local goalLat = nil
    local idleLane = false
    local target = Steer.target
    local targetPos = target and entryPos(target)
    if axis and targetPos then
        local raw = targetPos:Dot(axis)
        local gap = targetPos.Y - baitPos.Y
        if Steer.tRaw then
            local v = math.clamp((raw - Steer.tRaw) / dt, -FISH_SPEED_CAP, FISH_SPEED_CAP)
            Steer.tVel = (Steer.tVel or 0) + (v - (Steer.tVel or 0)) * math.min(1, dt * 4)
        end
        Steer.tRaw = raw
        Steer.tLat = Steer.tLat and (Steer.tLat + (raw - Steer.tLat) * math.min(1, dt * 3)) or raw
        -- time until the rising bait reaches the fish's height, plus ~0.1s
        -- for the game's own smoothing of the bait's sideways move
        local eta = math.max(gap, 0) / math.max(Cast.rise or 10, 2) + BAIT_LAG
        Steer.targetGap = gap
        -- hooked: it sits 1-2 studs under the bait, in the same lane, and
        -- stays there. Mark it and move on to the next fish
        if gap < -0.4 and gap > -2.6 and math.abs(raw - baitPos:Dot(axis)) < 2 then
            Steer.hookedFor = (Steer.hookedFor or 0) + dt
            if Steer.hookedFor > 0.4 and target.id then
                Steer.caught[target.id] = true
                Steer.target, Steer.lastPos, Steer.clock = nil, nil, 1
            end
        else
            Steer.hookedFor = 0
        end
        if eta > INTERCEPT_HORIZON then
            -- still a way off: sit in its average lane, don't chase each dart
            goalLat = Steer.tLat
        else
            -- Final approach: sit on the fish, leading it only by the bait's own
            -- ~0.1s lag. Leading further meant extrapolating the fish's average
            -- speed, and fish turn often enough that it pointed the wrong way.
            -- The game grabs anything the bait overlaps for the ~quarter
            -- second it takes to rise through a hitbox, so being on it now wins
            goalLat = raw + (Steer.tVel or 0) * math.min(eta, LEAD_MAX)
        end
    elseif axis and S.avoidJunk then
        -- Nothing worth chasing: go back to the middle of the lane and dodge
        -- from there. Holding wherever the bait happened to be fed on itself
        -- (a dodge pushed it out, the hold kept it out, the next dodge pushed
        -- further) until the offset pinned at the cap.
        goalLat = Steer.landing or baitPos:Dot(axis)
        idleLane = true
    end

    -- Dodging: one lane picker instead of stacked rules. Every reachable lane
    -- (half a stud apart) gets a cost and the cheapest wins:
    --   * distance from where the plan wants the bait (the target's lane)
    --   * a fish the bait will reach soon sitting in that lane: heavy, and
    --     heavier the sooner it arrives
    --   * crossing such a fish's lane on the way there: the bait grabs
    --     whatever it touches sideways too, so that counts as hitting it
    -- Each fish's position is predicted to the moment the bait reaches its
    -- height, from how fast that fish is swimming; dodging where fish were
    -- let them swim into the path.
    if goalLat and Steer.landing and half then
        local hazards = {}
        local rise = math.max(Cast.rise or 10, 2)
        local window = rise * 1.2
        -- with a target, only fish the bait meets before it
        local limit = targetPos and math.min(window, (Steer.targetGap or window) - 1) or window
        local pad = 1.5
        local now = os.clock()
        Steer.fishVel = Steer.fishVel or {}
        local routeFull = Steer.route and #Steer.route > 0 and #Steer.route >= (Steer.slotsLeft or 99)
        for _, f in ipairs(School) do
            local inRoute = Steer.routeIds and Steer.routeIds[f.id or 0]
            -- anything the plan didn't choose is in the way ("Avoid useless"
            -- off: junk only when the route needs every slot)
            local obstacle = not inRoute and (S.avoidJunk or not f.useless or routeFull)
            if obstacle and not Steer.caught[f.id or 0] then
                local pos = entryPos(f)
                if pos then
                    local gap = pos.Y - baitPos.Y
                    local lat = pos:Dot(axis)
                    local vel = fishVelocity(f, lat, now)
                    -- still above the bait only: one riding just below is
                    -- already hooked and dodging it does nothing
                    if gap > -0.5 and gap < limit then
                        local eta = math.max(gap, 0) / rise
                        hazards[#hazards + 1] = {
                            lat = lat + vel * math.min(eta, 0.6),
                            r = f.halfWidth * FISH_MAGNET + pad,
                            eta = eta,
                        }
                    end
                end
            end
        end
        if #hazards > 0 then
            local lim = math.min(MAX_OFFSET, POINTER_LIMIT * half)
            local here = baitPos:Dot(axis)
            local want = goalLat
            -- idle (nothing to chase): barely care where, mostly care clear
            local pull = idleLane and 0.05 or 1
            local bestX, bestCost = goalLat, math.huge
            for x = Steer.landing - lim, Steer.landing + lim, 0.5 do
                local cost = math.abs(x - want) * pull + math.abs(x - here) * 0.02
                for _, h in ipairs(hazards) do
                    local urgency = 1 / (0.15 + h.eta)
                    local overlap = h.r - math.abs(x - h.lat)
                    if overlap > 0 then
                        cost = cost + (20 + overlap * 5) * urgency
                    end
                    if h.eta < 0.6 then
                        local lo, hi = h.lat - h.r, h.lat + h.r
                        local a, b = math.min(here, x), math.max(here, x)
                        local inside = here > lo and here < hi
                        if not inside and a < hi and b > lo then
                            cost = cost + 40 * urgency
                        end
                    end
                end
                if cost < bestCost then bestX, bestCost = x, cost end
            end
            goalLat = bestX
        end
    end

    -- a lead can overshoot past where the bait can go; hold it at the edge
    -- of reach instead of giving up on the fish
    if goalLat and Steer.landing and half then
        local lim = math.min(MAX_OFFSET, POINTER_LIMIT * half)
        goalLat = math.clamp(goalLat, Steer.landing - lim, Steer.landing + lim)
    end

    -- Direct: write the offset that puts the bait at goalLat. Needs no
    -- focus or closed menu (no input is sent), only the staff guard applies.
    -- During a fight the game holds the aim itself, so leave it alone.
    if direct then
        local paused = S.staffGuard and Guard.staff
        if goalLat and Steer.landing and aimLive and not fightNow and not paused then
            Steer.dbgGoal = goalLat
            local offset = math.clamp((goalLat - Steer.landing) / AimFit.slope, -MAX_OFFSET, MAX_OFFSET)
            AimMem.write(offset, half, AimFit.slope, targetPos ~= nil)
            if S.fishEsp and targetPos then
                local scr, vis = WorldToScreen(targetPos)
                targetRing.Visible = vis == true
                if vis then targetRing.Position = Vector2.new(scr.X, scr.Y) end
            else
                targetRing.Visible = false
            end
        else
            if not fightNow then AimMem.release() end
            targetRing.Visible = false
        end
    end

    -- mouse modes: move the cursor to the pointer that puts the bait at goalLat
    local steering = false
    local now = os.clock()
    local p = (not direct) and goalLat and goalPointer(goalLat, half)
    if p and not Cast.fighting and now >= Steer.manualUntil and canAct() then
        steering = true
        local goalX = (p + 1) / 2 * width
        if S.fishEsp and targetPos then
            local scr, vis = WorldToScreen(targetPos)
            targetRing.Visible = vis == true
            if vis then targetRing.Position = Vector2.new(scr.X, scr.Y) end
        end
        local mx = mouse.X
        if S.steerMode == "Instant" then
            -- Teleport with an absolute move. Relative moves get scaled by
            -- Windows pointer acceleration, so big jumps landed in the wrong
            -- place. Absolute coordinates may be offset from the game's
            -- viewport (window border, top bar), so the offset is learned from
            -- where the cursor actually lands.
            --
            -- Moves go out every frame the goal shifts. The offset is only
            -- re-learned when the goal has held still for 0.1s, since a
            -- reading taken mid-stream would compare against a stale move.
            local pend = Steer.pending
            if pend and now - pend.t >= 0.1 then
                Steer.offX = pend.sx - mx
                Steer.offY = pend.sy - mouse.Y
                Steer.pending = nil
                Steer.calibratedAt = now
            end
            -- the cursor sits away from where we put it with nothing in
            -- flight: the player has the mouse
            if Steer.offX and not Steer.pending and Steer.sentX
                and now - (Steer.sentAt or 0) > 0.15 and math.abs(mx - Steer.sentX) > 40 then
                Steer.manualUntil = now + 1.5
                Steer.sentX = nil
                targetRing.Visible = false
                return
            end
            if not Steer.sentX or math.abs(goalX - Steer.sentX) > 2 then
                local sx = goalX + (Steer.offX or 0)
                local sy = mouse.Y + (Steer.offY or 0)
                pcall(mousemoveabs, math.floor(sx + 0.5), math.floor(sy + 0.5))
                Steer.sentX, Steer.sentAt = goalX, now
                -- a newer move makes any pending calibration stale
                if not Steer.offX or now - (Steer.calibratedAt or 0) > 2 then
                    Steer.pending = { sx = sx, sy = sy, t = now }
                else
                    Steer.pending = nil
                end
            end
        else
            -- Smooth: eased relative moves, with our own idea of where the
            -- cursor is (mouse.X lags a frame behind what we send)
            if not Steer.cursor then Steer.cursor = mx end
            if math.abs(mx - Steer.cursor) > math.max(80, math.abs(Steer.lastMove or 0) * 3) then
                Steer.manualUntil = now + 1.5
                Steer.cursor, Steer.carry = nil, 0
                targetRing.Visible = false
                return
            end
            -- slow pull toward the real cursor corrects pointer acceleration
            Steer.cursor = Steer.cursor + (mx - Steer.cursor) * math.min(1, dt * 3)
            Steer.cursor = math.clamp(Steer.cursor, 0, width)
            local err = goalX - Steer.cursor
            local move = 0
            if math.abs(err) > STEER_DEADZONE then
                local speed = math.clamp(S.steerSpeed, 1, 10)
                local step = err * (1 - math.exp(-dt * speed * 2))
                local cap = 450 * speed * dt
                step = math.clamp(step, -cap, cap) + Steer.carry
                move = step >= 0 and math.floor(step) or math.ceil(step)
                Steer.carry = step - move
            else
                Steer.carry = 0
            end
            Steer.lastMove = move
            if move ~= 0 then
                pcall(mousemoverel, move, 0)
                Steer.cursor = Steer.cursor + move
            end
        end
    end
    if not steering then
        Steer.cursor, Steer.carry, Steer.pending, Steer.sentX = nil, 0, nil, nil
        if not direct then targetRing.Visible = false end
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
                        if f.mutation and f.mutation ~= "" then label = f.mutation .. " " .. label end
                        if f.price then label = label .. "  " .. fmtShort(f.price) end
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
end

-- errors in here would otherwise kill steering silently; log them, at most
-- once every 5 seconds
local lastRenderError = 0
Hub.conns[#Hub.conns + 1] = RunService.RenderStepped:Connect(function(dt)
    if not Hub.running then return end
    -- Not the current copy any more (replaced by a newer load): stop
    -- everything. keepMenu, because the menu on screen belongs to the newer
    -- copy and must not be torn down by this one.
    if _G.DeepFishHub ~= Hub then
        pcall(Hub.Unload, true)
        return
    end
    local ok, err = pcall(renderStep, dt)
    if not ok and os.clock() - lastRenderError > 5 then
        lastRenderError = os.clock()
        warn("[DeepFish] render: " .. tostring(err))
    end
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

-- The menu library calls widget callbacks straight from its own frame loop,
-- so one error in a callback kills the loop: the menu freezes on screen and,
-- since it was holding game input back, the game stops responding. (A bad
-- teleport did exactly that.) Every callback the script registers goes
-- through safe() instead, patched in once on the shared section class.
local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            warn("[DeepFish] menu action failed: " .. tostring(err))
            pcall(function() Lib:Notify("Error", tostring(err), 5, "error") end)
        end
    end
end

do
    local mt = getmetatable(sCast)
    local cls = mt and mt.__index
    if type(cls) == "table" and not rawget(cls, "__deepfishSafe") then
        cls.__deepfishSafe = true
        -- position of the callback among each method's arguments (after self)
        -- Labels too: the library calls a label's text function inside its own
        -- frame loop, so one error there froze the whole menu and the box
        local origLabel = cls.Label
        if type(origLabel) == "function" then
            cls.Label = function(self, text, ...)
                if type(text) == "function" then
                    local fn = text
                    text = function()
                        local ok, v = pcall(fn)
                        return ok and tostring(v) or "-"
                    end
                end
                return origLabel(self, text, ...)
            end
        end
        for name, at in pairs({ Toggle = 3, Button = 2, Slider = 7, Dropdown = 5, Textbox = 3, Keybind = 3 }) do
            local orig = cls[name]
            if type(orig) == "function" then
                cls[name] = function(self, ...)
                    local args = table.pack(...)
                    if type(args[at]) == "function" then args[at] = safe(args[at]) end
                    return orig(self, table.unpack(args, 1, args.n))
                end
            end
        end
    end
end
UI.autoCast = sCast:Toggle("Auto cast", S.autoCast, function(on)
    S.autoCast = on
    if on then
        saveFishingSpot()
        Lib:Notify("Auto cast", "on - close the menu (P) so clicks reach the game", 4, "success")
    end
end)
sCast:Toggle("Auto equip rod", S.autoEquip, function(on) S.autoEquip = on end, "presses the rod's hotbar key if auto cast finds your hands empty")
sCast:Dropdown("Throw quality", { S.throwQuality }, { "Perfect", "Good" }, false, function(v)
    S.throwQuality = (type(v) == "table" and v[1]) or v or "Perfect"
end)
sCast:Slider("Timing offset", S.timingOffset, 5, -150, 150, "ms", function(v) S.timingOffset = v end, "raise if throws come out early, lower if late")
sCast:Slider("Cooldown", S.castCooldown, 0.1, 0.5, 5, "s", function(v) S.castCooldown = v end)
sCast:Label(function() return string.format("Hold time: %d ms  (%d steps)", math.floor(holdTime() * 1000), R.hookSteps) end)

local sFight = tFish:Section("Catch fight", "Left")
UI.autoFight = sFight:Toggle("Auto fight", S.autoFight, function(on) S.autoFight = on end, "clicks for you while a fish fights back")
sFight:Slider("Click rate", S.clickRate, 1, 4, 12, "/s", function(v) S.clickRate = v end, "the game caps credit at 12/s")
sFight:Label(function() return "Fighting: " .. (Cast.fighting and "yes" or "no") end)

local sSteer = tFish:Section("Steering", "Right", "aims the bait at the most valuable fish on screen")
UI.autoSteer = sSteer:Toggle("Auto steer", S.autoSteer, function(on) S.autoSteer = on end)
sSteer:Toggle("Go for items", S.goForItems, function(on) S.goForItems = on end, "enchant stones, scrolls, chests, keys, baits, potions")
sSteer:Toggle("Avoid useless", S.avoidJunk, function(on) S.avoidJunk = on end, "steer around junk and fish under the minimum value")
-- "Min fish value" (renamed from "Min value" so the new Auto default applies
-- instead of an old saved number). Auto: no fixed floor. Slots come from the
-- game's own caught/cap counter, so upgrades need no setting change, and the
-- planner keeps the most valuable fish for them, dodging the rest.
sSteer:Dropdown("Min fish value", { S.minValue <= 0 and "Auto" or fmtShort(S.minValue) }, { "Auto", "$100", "$500", "$1K", "$10K", "$100K" }, false, function(v)
    v = (type(v) == "table" and v[1]) or v
    if v == "Auto" then
        S.minValue = 0
        return
    end
    local n = num(tostring(v or ""):gsub("%$", ""))
    if n then S.minValue = n end
end, "Auto fills your slots with the best fish on screen; a set value never chases anything cheaper")
-- Direct is the only steering mode (it moves the bait itself, no mouse)
sSteer:Dropdown("Go for", { S.targetMode }, { "Value", "Rarity", "Most fish" }, false, function(v)
    S.targetMode = (type(v) == "table" and v[1]) or v or "Value"
end, "Value: most money per cast. Rarity: rarest first. Most fish: fill every slot")
sSteer:Label(function()
    local r = Steer.route
    if not (r and #r > 0) then return "Route: -" end
    local names = {}
    for i, f in ipairs(r) do if i <= 3 then names[#names + 1] = f.name end end
    return "Route: " .. table.concat(names, " > ") .. (#r > 3 and " ..." or "")
end)
sSteer:Label(function()
    return string.format("Slots left: %s   Route worth: %s", tostring(Steer.slotsLeft or "?"),
        fmtShort(Steer.routeWorth or 0))
end)

local sEsp = tFish:Section("Fish ESP", "Right")
UI.fishEsp = sEsp:Toggle("Show fish", S.fishEsp, function(on) S.fishEsp = on end, "name and value over the school while you cast")
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
sStats:Label(function() return "Value caught: " .. fmtShort(Stats.caughtValue) end)
sStats:Label(function() return "Best: " .. (Stats.best or "-") end)
sStats:Button("Reset session", function()
    Stats.start = os.clock()
    Stats.casts, Stats.catches, Stats.fights, Stats.fightsWon, Stats.earned, Stats.spent = 0, 0, 0, 0, 0, 0
    Stats.byRarity, Stats.best, Stats.bestValue, Stats.caughtValue = {}, nil, 0, 0
end)

local sLog = tInfo:Section("Recent catches", "Left")
for i = 1, 8 do
    sLog:Label(function()
        local c = CatchLog[i]
        if not c then return i == 1 and "nothing yet" or " " end
        return string.format("%s  %s  %s", c.t, c.name, fmtShort(c.value))
    end)
end
sLog:Button("Export log", function()
    local ok, file, n = pcall(exportCatchLog)
    if ok then
        Lib:Notify("Catch log", n .. " catches saved to " .. file, 5, "success")
    else
        Lib:Notify("Catch log", "export failed: " .. tostring(file), 5, "error")
    end
end, "writes a CSV to the Matcha workspace folder")

local sRar = tInfo:Section("By rarity", "Right")
for _, r in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Exotic" }) do
    sRar:Label(function() return r .. ": " .. tostring(Stats.byRarity[r] or 0) end)
end

local sAlerts = tInfo:Section("Alerts", "Right")
sAlerts:Toggle("Event alerts", S.eventAlerts, function(on) S.eventAlerts = on end)
sAlerts:Toggle("Rare events only", S.rareEventsOnly, function(on) S.rareEventsOnly = on end, "skip day, night and rain")
sAlerts:Toggle("Rare catch alerts", S.catchAlerts, function(on) S.catchAlerts = on end)
sAlerts:Dropdown("Alert at value", { fmtShort(S.catchAlertMin) }, { "$1K", "$10K", "$100K", "$1M", "$10M", "$100M", "$1B" }, false, function(v)
    v = (type(v) == "table" and v[1]) or v
    local n = num(tostring(v or ""):gsub("%$", ""))
    if n then S.catchAlertMin = n end
end, "notify when a catch sells for this much or more")

sAlerts:Toggle("Rare fish spawn alert", S.spawnAlert, function(on) S.spawnAlert = on end, "tells you when a valuable fish shows up in your school, before you catch it")
sAlerts:Dropdown("Spawn alert at", { fmtShort(S.spawnAlertMin) }, { "$10K", "$100K", "$1M", "$10M", "$100M", "$1B" }, false, function(v)
    v = (type(v) == "table" and v[1]) or v
    local n = num(tostring(v or ""):gsub("%$", ""))
    if n then S.spawnAlertMin = n end
end)

local sHook = tInfo:Section("Discord webhook", "Right", "pings you for big catches")
sHook:Toggle("Enabled", S.webhook, function(on) S.webhook = on end, "uses the same value threshold as catch alerts")
sHook:Dropdown("Summary every", { S.summaryMins > 0 and (S.summaryMins .. " min") or "Off" }, { "Off", "15 min", "30 min", "60 min" }, false, function(v)
    v = (type(v) == "table" and v[1]) or v
    S.summaryMins = tonumber(tostring(v or ""):match("%d+")) or 0
end, "posts session totals on a timer")
sHook:Textbox("Webhook URL", S.webhookUrl, function(text)
    S.webhookUrl = tostring(text or ""):gsub("%s", "")
    if S.webhookUrl ~= "" and not validWebhook(S.webhookUrl) then
        Lib:Notify("Webhook", "that isn't a discord.com webhook URL", 4, "error")
    end
end)
sHook:Button("Send test", function()
    if not validWebhook(S.webhookUrl) then
        Lib:Notify("Webhook", "paste a discord.com webhook URL first", 4, "error")
    elseif not S.webhook then
        Lib:Notify("Webhook", "turn it on first", 3, "warning")
    else
        sendWebhook("Deep Fishing: webhook test")
        Lib:Notify("Webhook", "test sent", 3, "success")
    end
end)

Lib:Category("WORLD")
local tTp = win:Tab("Teleport", "location-pin")
local sTp = tTp:Section("Places", "Left", "experimental - one jump, in the world you're in")
for _, spot in ipairs(TeleportSpots) do
    sTp:Button(spot.label, function() teleportToSpot(spot) end)
end
local sSpot = tTp:Section("Fishing spot", "Right", "saved automatically when you turn auto cast on")
sSpot:Button("Save spot here", function()
    if saveFishingSpot() then Lib:Notify("Fishing spot", "saved", 2, "success") end
end)
sSpot:Button("Back to fishing spot", function()
    if not Hub.savedSpot then
        Lib:Notify("Fishing spot", "save a spot first", 3, "warning")
    elseif teleportTo(Hub.savedSpot) then
        Lib:Notify("Teleport", "fishing spot", 2, "info")
    end
end)
sSpot:Label(function()
    local p = Hub.savedSpot
    return p and string.format("Saved: %.0f, %.0f, %.0f", p.X, p.Y, p.Z) or "Saved: none"
end)
sSpot:Info("Teleporting moves your character instantly. Other players can see it, so use it sparingly.")

Lib:Category("SYSTEM")
local tMisc = win:Tab("Misc", "three-dots-horizontal")

local sKeys = tMisc:Section("Hotkeys", "Left", "work while the menu is closed")
for _, def in ipairs({
    { "Auto cast", "keyCast" }, { "Auto steer", "keySteer" }, { "Fish ESP", "keyEsp" }, { "Panic (all off)", "keyPanic" },
}) do
    local label, key = def[1], def[2]
    sKeys:Dropdown(label, { S[key] }, HotkeyNames, false, function(v)
        S[key] = (type(v) == "table" and v[1]) or v or "None"
    end)
end
local sSafety = tMisc:Section("Safety", "Right")
sSafety:Toggle("Pause for staff", S.staffGuard, function(on) S.staffGuard = on end, "stops all automation while a player with a staff role is in the server")
sSafety:Label(function() return "Staff: " .. (Guard.staff or "none") end)
sSafety:Toggle("Stop when full", S.fullGuard, function(on) S.fullGuard = on end, "turns auto cast off when your fish inventory is full")
sSafety:Label(function() return "Fish bag: " .. (txt(R.invFish) or "?") end)

local sMisc = tMisc:Section("Misc", "Left")
sMisc:Toggle("Anti AFK", S.antiAfk, function(on) S.antiAfk = on end)
sMisc:Button("Rescan game", function()
    resolveRefs()
    loadDatabase()
    local n = 0 for _ in pairs(Odds) do n = n + 1 end
    Lib:Notify("Rescan", n .. " fish in database", 3, "info")
end)
sMisc:Button("Refresh prices", function()
    Lib:Notify("Prices", "scanning memory, the game may freeze for a few seconds", 4, "warning")
    task.spawn(function()
        local ok, n = pcall(refreshPrices)
        if ok then
            Lib:Notify("Prices", n .. " items priced and saved", 4, "success")
        else
            Lib:Notify("Prices", "scan failed: " .. tostring(n), 5, "error")
        end
    end)
end, "only needed after a game update adds new fish")
sMisc:Label(function()
    local n = 0 for _ in pairs(Price) do n = n + 1 end
    return "Fish priced: " .. n
end)
sMisc:Button("Unload", function()
    Lib:Dialog({
        title = "Unload?",
        text = "Stop everything and remove the menu?",
        confirm = "Unload",
        onConfirm = safe(function() Hub.Unload() end),
    })
end):SetRisk()

win:AddSettingsTab("gear")

-- The status box is drawn by this script, not the menu library. A library
-- box is painted by the library's own frame loop, so whenever that loop
-- stopped, the box froze on whatever it last showed. These drawings are
-- created once and rewritten twice a second by a loop of ours.
local BOX_X, BOX_Y, BOX_W = 20, 160, 230
local BOX_ROW, BOX_PAD = 18, 8
local function onOff(v) return v and "ON" or "off" end
local boxRows = {
    function()
        if S.staffGuard and Guard.staff then return "PAUSED - staff in server", Color3.fromRGB(255, 120, 120) end
        if S.autoCast and menuOpen() then return "Close the menu so auto cast can click", Color3.fromRGB(255, 200, 90) end
        return nil
    end,
    function() return "Auto cast: " .. onOff(S.autoCast) end,
    function() return "Auto steer: " .. onOff(S.autoSteer) end,
    function()
        local r = Steer.route
        if not (r and #r > 0) then return "Route: -" end
        local money = 0
        for _, f in ipairs(r) do money = money + (f.price or 0) end
        return string.format("Route: %d fish, %s", #r, fmtShort(money))
    end,
    function()
        local t = Steer.target
        return "Next: " .. (t and (t.name .. (t.price and ("  " .. fmtShort(t.price)) or "")) or "-")
    end,
    function()
        local left, cap = slotsLeft()
        return string.format("Slots: %d / %d free", left, cap)
    end,
    function() return "Event: " .. (txt(R.event) or "?") end,
    function() return "Catches: " .. tostring(Stats.catches) end,
    function()
        local h = math.max((os.clock() - Stats.start) / 3600, 1 / 3600)
        return "Per hour: " .. fmtMoney(Stats.earned / h)
    end,
    function() return "Best: " .. (Stats.best or "-") end,
}

local boxBg = Drawing.new("Square")
boxBg.Filled = true
boxBg.Color = Color3.fromRGB(18, 18, 22)
boxBg.Transparency = 0.15
boxBg.Position = Vector2.new(BOX_X, BOX_Y)
boxBg.Visible = true
Hub.drawings[#Hub.drawings + 1] = boxBg

local boxTitle = Drawing.new("Text")
boxTitle.Text = "Deep Fishing"
boxTitle.Size = 15
boxTitle.Outline = true
boxTitle.Color = Color3.fromRGB(160, 150, 255)
boxTitle.Position = Vector2.new(BOX_X + BOX_PAD, BOX_Y + 6)
boxTitle.Visible = true
Hub.drawings[#Hub.drawings + 1] = boxTitle

local boxText = {}
for i = 1, #boxRows do
    local t = Drawing.new("Text")
    t.Size = 13
    t.Outline = true
    t.Color = Color3.fromRGB(220, 222, 230)
    t.Visible = false
    boxText[i] = t
    Hub.drawings[#Hub.drawings + 1] = t
end

local function drawBox()
    local y = BOX_Y + 6 + BOX_ROW + 4
    for i, row in ipairs(boxRows) do
        local ok, text, color = pcall(row)
        local t = boxText[i]
        if ok and text then
            t.Text = tostring(text)
            t.Color = color or Color3.fromRGB(220, 222, 230)
            t.Position = Vector2.new(BOX_X + BOX_PAD, y)
            t.Visible = true
            y = y + BOX_ROW
        else
            t.Visible = false
        end
    end
    boxBg.Size = Vector2.new(BOX_W, y - BOX_Y + 4)
end

task.spawn(function()
    while Hub.running do
        pcall(drawBox)
        task.wait(0.5)
    end
end)

-- Never call Lib:Destroy() directly: it frees drawings the menu may still be
-- mid-frame on, which crashes Matcha. Swapping the instance marker makes the
-- menu tear itself down at the top of its next frame instead.
function Hub.Unload(keepMenu)
    if not Hub.running then return end
    Hub.running = false
    -- give the aim back to the mouse before anything else stops
    pcall(AimMem.release)
    for _, c in ipairs(Hub.conns) do pcall(function() c:Disconnect() end) end
    for _, d in ipairs(Hub.drawings) do pcall(function() d.Visible = false end) end
    local drawings = Hub.drawings
    Hub.drawings = {}
    task.delay(0.5, function()
        for _, d in ipairs(drawings) do pcall(function() d:Remove() end) end
    end)
    if not keepMenu then
        -- The library's teardown deletes its shapes but not its pictures
        -- (profile picture, logo, backdrop): whatever is visible at that
        -- moment stays stuck on screen for good. Closing the menu first hides
        -- them, so once its close animation has run they're left invisible.
        pcall(function() Lib:SetOpen(false) end)
        task.delay(0.4, function() _G.INSuiInstance = {} end)
    end
    if _G.DeepFishHub == Hub then _G.DeepFishHub = nil end
end

Hub.debug = {
    S = S, R = R, Odds = Odds, Stats = Stats, Cast = Cast, Steer = Steer, Guard = Guard, CatchLog = CatchLog,
    AimMem = AimMem, AimFit = AimFit,
    School = function() return School end, holdTime = holdTime,
    rodSlotKey = rodSlotKey, inventoryFull = inventoryFull, findStaff = findStaff, validWebhook = validWebhook,
}

local fishKnown = 0 for _ in pairs(Price) do fishKnown = fishKnown + 1 end
Lib:Notify("Deep Fishing", "Loaded - P opens the menu, F6 toggles auto cast. " .. fishKnown .. " fish priced.", 6, "success")

end -- main

task.spawn(function()
    task.wait(0.5)
    if _G.DeepFishLoadId ~= myLoad then return end -- a newer execute took over
    local waited = 0
    while _G.DeepFishBusy and waited < 15 do
        task.wait(0.1)
        waited = waited + 0.1
    end
    if _G.DeepFishLoadId ~= myLoad then return end
    _G.DeepFishBusy = true
    local previous = _G.DeepFishHub
    _G.DeepFishHub = nil
    if previous and previous.Unload then
        pcall(previous.Unload)
        -- the old menu needs ~0.4s to close and ~0.1s more to tear down
        task.wait(1)
    end
    if _G.DeepFishLoadId == myLoad then
        local ok, err = pcall(main)
        if not ok then warn("[DeepFish] failed to load: " .. tostring(err)) end
    end
    _G.DeepFishBusy = false
end)
