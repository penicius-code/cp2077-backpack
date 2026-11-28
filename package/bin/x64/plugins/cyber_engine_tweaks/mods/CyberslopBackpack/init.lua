-- ============================================================
--  Cyberslop Backpack 1.2.2 (2026-11-01; 1.1.0 2026-11-25; 1.2.0 - 1.2.2 2026-11-26; for game 2.5)
--  Use backpack items without opening the (pausing) backpack screen.
-- ============================================================
-- 1.2.2: Merc Stims 1.2.0 humanity items (Anchor, Tether, Lumen, Circuit Breaker, Kill Switch) go to
--        Medical > Mind and humanity next to the neuroblockers, with notes.
-- 1.2.1: the hover box shows the effect lines the inventory tooltip shows (the item's UIData packages with their
--        numbers filled in, e.g. Addiquit "-40 Energy" and its status), above the flavour text. Lines with a
--        negative number (side effects, costs) are red, so nothing potent gets used by accident.
-- 1.2.0: own "Boosters" tab (category box) for boosters and Cyberslop Merc Stims, sorted into Wake and energy,
--        Combat, Nerve and sleep, Netrunning, Oxygen and stamina, Performance food and drink, Chrome
--        maintenance, Specialist kit, Other boosters. "All" leaves them out and shows one line pointing to the
--        tab, so the main list stays short. Fix: street drugs (Crank, Mr. Whitey, Black Lace ...) no longer
--        land under boosters because they are long-lasting items too; they go to Vices > Street drugs.
-- 1.1.0: items are grouped by what they are, under collapsible headers in the same window (Medical:
--        Clinic cures, Injury care, Mind and humanity, Addiction and recovery, Boosters; Vices: Smokes,
--        Alcohol, Street drugs; Drinks: Coffee and energy, Nutrition drinks, Water and soft drinks; Food:
--        Snacks, Light meals, Meals, Big meals; Shards ...). Groups come from the item records (Dark Future,
--        Injuries, Clinic Meds, Drug Dealer and vanilla tags, consumable base name, item type), not names.
--        Each row shows what the item is for in grey; hovering shows the game's own description.
--        The category box now picks a section (All, Medical, Vices, Drinks, Food, Shards, Eddie shards,
--        Other); headers remember open / closed in config.json. Sort: Name or Count inside each group.
-- 1.0.1: fixes items being used by themselves. CET's ImGui.Selectable(label, selected) returns the
--        row's SELECTED STATE every frame, not "clicked": 1.0.0 passed "is the selected row", so the
--        selected row counted as clicked on every frame (the first item right after a load, then whatever
--        was clicked last). Rows now pass false (true only on the frame of a click), a click must also
--        be a new press (edge check), no click counts in the first 0.25 s after the overlay opens, and
--        the selection is shown by colour only. Repeated "not used" lines are throttled; the log names
--        the record ID; console GetMod("CyberslopBackpack").find("name") / .restore("name", count).
-- What: lists every backpack item the vanilla backpack lets you "Use" (food, drinks, drugs / boosters,
--       skill shards / recipes, eddie shards; inhalers and injectors are excluded like in the backpack)
--       and uses one on click. The game keeps running: nothing here touches time dilation.
-- Two ways to use it:
--   1. CET overlay (`) > window "Backpack": category, sort, search, click an item to use it.
--      The overlay takes the mouse, so V stands still while it is open, but the world does not pause.
--   2. On-screen list (overlay closed, fully hands-free): hotkeys in CET Bindings > CyberslopBackpack
--      "Backpack list on/off", "next", "previous", "use selected", "next category". The list is drawn
--      without taking any input, so you keep moving, aiming and driving.
-- Use path: exactly the backpack's own "use_item" path (backpack_main.swift, 2.31): an item counts as
--   usable when it has a Consume / Eat / Drink / Learn / DownloadFunds action and is not an inhaler or
--   injector; using it calls ItemActionsHelper.PerformItemAction. Dark Future's consume hook sits on
--   ProcessItemAction, which PerformItemAction calls, so DF counts the item as usual.
-- Rules: "Follow the backpack's use rules" (on by default) asks the game's InventoryGPRestrictionHelper.CanUse,
--   the check the backpack runs before using an item (vanilla: no consumables in combat; Dark Future replaces
--   it: inhalers / injectors / DF combat-allowed items in combat, no food or drink with nausea). If that call
--   fails in CET, a Lua copy of the vanilla combat rule is used. Always blocked: no game session, a menu, a
--   scene (tier 3 to 5). "World checks" (on by default): carrying a body, a melee attack, fist fight.
-- Config: config.json next to this file. Log: CyberslopBackpack.log.
-- Console: GetMod("CyberslopBackpack").list() / .use("name part") / .status()

local VERSION = "1.2.2"
local OPEN_GUARD = 0.25            -- seconds after the overlay opens in which no click counts
local BLOCK_LOG_GAP = 2.0          -- same "not used" reason for the same item: log / show it at most this often
local CONFIG_FILE = "config.json"
local REFRESH_SECONDS = 1.0       -- list rebuild interval while a list is visible
local EAT_SOUND = "ui_loot_eat_ui" -- the sound the backpack plays on use

-- Sections = the category box. Every group below belongs to one section.
local CATEGORIES = {
    { key = "all",     label = "All" },
    { key = "medical", label = "Medical" },
    { key = "vices",   label = "Vices" },
    { key = "drinks",  label = "Drinks" },
    { key = "food",    label = "Food" },
    { key = "learn",   label = "Shards and recipes" },
    { key = "funds",   label = "Eddie shards" },
    { key = "other",   label = "Other" },
}
local CAT_LABEL = {}
for _, c in ipairs(CATEGORIES) do CAT_LABEL[c.key] = c.label end

-- Action getter (ItemActionsHelper static) -> use action kind. First match wins.
local ACTIONS = {
    { "GetEatAction", "food" },
    { "GetDrinkAction", "drink" },
    { "GetConsumeAction", "drug" },
    { "GetLearnAction", "learn" },
    { "GetDownloadFunds", "funds" },
}

-- Groups in display order. test(c) gets the classification: c.tags (set of tag strings), c.id (record
-- name), c.itype (item type), c.base (consumable base name), c.act (use action kind). First match wins.
local function anyTag(c, ...)
    for _, t in ipairs({ ... }) do if c.tags[t] then return true end end
    return false
end
local function idStarts(c, prefix) return c.id:sub(1, #prefix) == prefix end
local BOOSTER_BASES = { HealthBooster = true, StaminaBooster = true, MemoryBooster = true, CarryCapacityBooster = true, OxyBooster = true }
-- 1.2.0: Cyberslop Merc Stims items carry the tag CyberslopStims.<Id>
local function stim(c, ...)
    for _, id in ipairs({ ... }) do if c.tags["CyberslopStims." .. id] then return true end end
    return false
end
local function narcotic(c)
    return anyTag(c, "DrugDealerDrug", "DarkFutureConsumableAddictiveNarcotic", "DarkFutureManagedConsumableNarcotic")
        or (c.tags.IllegalItem and c.tags.Drug) or false
end

local GROUPS = {
    -- 1.2.0 Boosters tab (first: Merc Stims food / injectors must not fall into food or medical groups)
    { key = "b_wake",  section = "boosters", label = "Wake and energy",
      about = "Hold Dark Future Energy up so you can skip sleep; sleep debt afterwards.",
      test = function(c) return stim(c, "Vigil", "HoldFast", "Surge") end },
    { key = "b_combat", section = "boosters", label = "Combat",
      about = "Taken before or during a fight: reflexes, no knockdown, poison protection.",
      test = function(c) return stim(c, "Kagami", "Hardline", "Antitox") end },
    { key = "b_nerve", section = "boosters", label = "Nerve and sleep",
      about = "Nerve control without euphoria, and a proper night's sleep.",
      test = function(c) return stim(c, "Steady", "Serene", "ZeroPoint", "Lull") end },
    { key = "b_net",   section = "boosters", label = "Netrunning",
      about = "RAM and quickhack performance.",
      test = function(c) return stim(c, "Boost") or c.base == "MemoryBooster" end },
    { key = "b_oxy",   section = "boosters", label = "Oxygen and stamina",
      about = "Oxygen reserve (Cyberslop Endurance) and stamina.",
      test = function(c) return stim(c, "Respirocyte", "Bronchodilator") or c.base == "StaminaBooster" or c.base == "OxyBooster" end },
    { key = "b_perf",  section = "boosters", label = "Performance food and drink",
      about = "High-grade meals, drinks and supplements with a stat buff on top of Dark Future needs.",
      test = function(c) return stim(c, "ProteoMax", "Electra", "CorpoDaily", "Ketone", "ColdBrew", "HydraSalt", "NutriGel") end },
    { key = "b_chrome", section = "boosters", label = "Chrome maintenance",
      about = "Upkeep for a heavily chromed body.",
      test = function(c) return stim(c, "NeuroSync", "OsteoCal", "BioCoolant", "Rejectol") end },
    { key = "b_kit",   section = "boosters", label = "Specialist kit",
      about = "Off the grid, nicotine primer, rapid detox.",
      test = function(c) return stim(c, "Ghostline", "Emberline", "Rapidetox") end },

    { key = "clinic",  section = "medical", label = "Clinic cures",
      about = "Clinic-grade one-shot cures (Cyberslop Clinic Meds). Expensive, instant, short after-effect.",
      test = function(c) return anyTag(c, "CyberslopMeds.Item", "CyberslopNeuroMend.Ampoule") end },
    { key = "injury",  section = "medical", label = "Injury care",
      about = "Dressings, pain blockers and trauma kits: mask or treat injuries.",
      test = function(c) return anyTag(c, "Injuries.MedicalItem", "DarkFutureInjuryCure") end },
    { key = "mind",    section = "medical", label = "Mind and humanity",
      about = "Humanity loss and cyberpsychosis care (Dark Future, Wannabe Edgerunner).",
      test = function(c) return anyTag(c, "DarkFutureConsumableEndotrisineDrug", "DarkFutureConsumableImmunosuppressantDrug") or idStarts(c, "Items.RipperdocMed")
          or stim(c, "Anchor", "Tether", "Lumen", "CircuitBreaker", "KillSwitch") end },
    { key = "recovery", section = "medical", label = "Addiction and recovery",
      about = "Withdrawal, overdose and hangover treatment (Dark Future).",
      test = function(c) return anyTag(c, "DarkFutureConsumableAddictionTreatmentDrug", "DarkFutureConsumableOverdoseCureDrug", "DarkFutureConsumableHangoverTreatmentDrug") end },
    { key = "boost",   section = "boosters", label = "Other boosters",
      about = "Long-lasting stat boosters.",
      test = function(c) return not narcotic(c) and (c.itype == "Con_LongLasting" or BOOSTER_BASES[c.base or ""] == true) end },
    { key = "smokes",  section = "vices", label = "Smokes",
      about = "Cigarettes and cigars: nicotine (Dark Future addiction).",
      test = function(c) return anyTag(c, "DarkFutureCigarette", "DarkFutureConsumableAddictiveNicotine", "DarkFutureManagedConsumableNicotine") end },
    { key = "alcohol", section = "vices", label = "Alcohol",
      about = "Booze: drunk effect, Dark Future alcohol addiction.",
      test = function(c) return c.base == "Alcohol" or anyTag(c, "Alcohol", "DarkFutureConsumableAddictiveAlcohol") end },
    { key = "street",  section = "vices", label = "Street drugs",
      about = "Narcotics and street-grade drugs: addictive, often illegal.",
      test = function(c) return anyTag(c, "DrugDealerDrug", "DarkFutureConsumableAddictiveNarcotic", "DarkFutureManagedConsumableNarcotic") or (c.tags.IllegalItem and c.tags.Drug) end },
    { key = "ddmat",   section = "vices", label = "Drug-making materials",
      about = "Drug Dealer ingredients.",
      test = function(c) return anyTag(c, "DrugDealer.Material") end },
    { key = "medicine", section = "medical", label = "Other medicine",
      about = "Medical items without a more specific group.",
      test = function(c) return c.tags.Medical == true end },
    { key = "coffee",  section = "drinks", label = "Coffee and energy drinks",
      about = "Caffeine: keeps you awake (Dark Future energy), some ease a hangover.",
      test = function(c) return anyTag(c, "DarkFutureManagedConsumableCaffeine") end },
    { key = "nutdrink", section = "drinks", label = "Nutrition drinks",
      about = "Drinks that count as food (Dark Future nutrition).",
      test = function(c) return c.act == "drink" and anyTag(c, "DarkFutureConsumableNutrition") end },
    { key = "drinks",  section = "drinks", label = "Water and soft drinks",
      about = "Hydration.",
      test = function(c) return c.act == "drink" end },
    { key = "snack",   section = "food", label = "Snacks",
      about = "Small bites: a little nutrition.",
      test = function(c) return c.act == "food" and (anyTag(c, "DarkFutureConsumableNutritionTier1") or (c.tags.Small and not c.dfNut)) end },
    { key = "light",   section = "food", label = "Light meals",
      about = "Some nutrition.",
      test = function(c) return c.act == "food" and (anyTag(c, "DarkFutureConsumableNutritionTier2") or (c.tags.Medium and not c.dfNut)) end },
    { key = "meal",    section = "food", label = "Meals",
      about = "Good nutrition.",
      test = function(c) return c.act == "food" and (anyTag(c, "DarkFutureConsumableNutritionTier3") or (c.tags.Large and not c.dfNut)) end },
    { key = "bigmeal", section = "food", label = "Big meals",
      about = "Full nutrition.",
      test = function(c) return c.act == "food" and anyTag(c, "DarkFutureConsumableNutritionTier4") end },
    { key = "food",    section = "food", label = "Other food",
      about = "Food without a size tag.",
      test = function(c) return c.act == "food" end },
    { key = "drug",    section = "other", label = "Other consumables",
      about = "Usable items without a more specific group.",
      test = function(c) return c.act == "drug" end },
    { key = "learn",   section = "learn", label = "Shards and recipes",
      about = "Skill shards and crafting specs.",
      test = function(c) return c.act == "learn" end },
    { key = "funds",   section = "funds", label = "Eddie shards",
      about = "Shards that pay out eddies.",
      test = function(c) return c.act == "funds" end },
}
local GROUP_BY_KEY, GROUP_ORDER = {}, {}
for i, g in ipairs(GROUPS) do GROUP_BY_KEY[g.key] = g GROUP_ORDER[g.key] = i end

-- Short "what it is for" notes, shown in grey on the row. Tag or record-name prefix -> text. First match wins.
local HINTS = {
    { tag = "CyberslopNeuroMend.Ampoule", text = "cures concussion" },
    { tag = "CyberslopMeds.HemoSeal", text = "stops bleeding" },
    { tag = "CyberslopMeds.OsteoWeld", text = "mends broken bones" },
    { tag = "CyberslopMeds.ReGen9", text = "cures every injury" },
    { tag = "CyberslopMeds.Quell", text = "ends withdrawal for now" },
    { tag = "CyberslopMeds.CleanSlate", text = "cures all addictions" },
    { tag = "CyberslopMeds.ChelaTox", text = "cures poison" },
    { tag = "Injuries.MedKit", text = "masks bleeding one level" },
    { tag = "Injuries.ConcussionPill", text = "masks concussion one level" },
    { tag = "Injuries.Painkiller", text = "masks broken bones, flare-up later" },
    { tag = "DarkFutureInjuryCure", text = "treats the Injury condition" },
    { tag = "DarkFutureConsumableEndotrisineDrug", text = "faster humanity recovery, 24 h" },
    { tag = "DarkFutureConsumableImmunosuppressantDrug", text = "humanity loss treatment" },
    { prefix = "Items.RipperdocMed", text = "cyberpsychosis suppressant" },
    { tag = "DarkFutureConsumableAddictionTreatmentDrug", text = "suppresses withdrawal" },
    { tag = "DarkFutureConsumableOverdoseCureDrug", text = "overdose cure, restores Nerve" },
    { tag = "DarkFutureConsumableHangoverTreatmentDrug", text = "hangover cure" },
    { tag = "DarkFutureConsumableAddictiveNicotine", text = "nicotine" },
    { tag = "DrugDealerDrug", text = "street drug" },
    -- 1.2.0 Cyberslop Merc Stims (game hours)
    { tag = "CyberslopStims.Vigil", text = "awake 12 h, small sleep debt" },
    { tag = "CyberslopStims.HoldFast", text = "awake 6 h, stamina" },
    { tag = "CyberslopStims.Surge", text = "awake 4 h, full sleep debt" },
    { tag = "CyberslopStims.Kagami", text = "combat reflexes 1.5 h" },
    { tag = "CyberslopStims.Hardline", text = "no knockdown 10 min" },
    { tag = "CyberslopStims.Antitox", text = "poison immunity 1 h" },
    { tag = "CyberslopStims.Steady", text = "Nerve held 4 h, steady aim" },
    { tag = "CyberslopStims.Serene", text = "+30 Nerve over 1 h" },
    { tag = "CyberslopStims.ZeroPoint", text = "+25 Nerve now" },
    { tag = "CyberslopStims.Lull", text = "sleep aid, sleep within 1 h" },
    { tag = "CyberslopStims.Boost", text = "RAM + quickhacks 2 h" },
    { tag = "CyberslopStims.Respirocyte", text = "oxygen +30 % 6 h" },
    { tag = "CyberslopStims.Bronchodilator", text = "oxygen refill 1 h" },
    { tag = "CyberslopStims.ProteoMax", text = "big meal, stamina 6 h" },
    { tag = "CyberslopStims.Electra", text = "hydration 3/3, stamina regen" },
    { tag = "CyberslopStims.CorpoDaily", text = "slower need drain 24 h" },
    { tag = "CyberslopStims.Ketone", text = "stamina regen 2 h" },
    { tag = "CyberslopStims.ColdBrew", text = "caffeine, focus 2 h" },
    { tag = "CyberslopStims.HydraSalt", text = "hydration 2/3, in combat" },
    { tag = "CyberslopStims.NutriGel", text = "nutrition 2/4, in combat" },
    { tag = "CyberslopStims.NeuroSync", text = "Sandevistan recharge 12 h" },
    { tag = "CyberslopStims.OsteoCal", text = "carry + melee resist 24 h" },
    { tag = "CyberslopStims.BioCoolant", text = "RAM regen, heat 6 h" },
    { tag = "CyberslopStims.Rejectol", text = "humanity damage -15 % 24 h" },
    { tag = "CyberslopStims.Anchor", text = "humanity damage -40 %, +10, +1/h, 24 h" },
    { tag = "CyberslopStims.Tether", text = "humanity damage -20 %, +3, 8 h" },
    { tag = "CyberslopStims.Lumen", text = "+15 humanity over 2 h, dazed" },
    { tag = "CyberslopStims.CircuitBreaker", text = "EMERGENCY: stops an episode, 15 min" },
    { tag = "CyberslopStims.KillSwitch", text = "LAST RESORT: stops any episode, 1 h, heavy crash" },
    { tag = "CyberslopStims.Ghostline", text = "no car-sleep ambush 12 h" },
    { tag = "CyberslopStims.Emberline", text = "smoking = focus, 24 h" },
    { tag = "CyberslopStims.Rapidetox", text = "instantly sober" },
}

-- Grey note for a classified item: curated text, else what Dark Future's tags say it does.
local function hintFor(c)
    for _, h in ipairs(HINTS) do
        if (h.tag and c.tags[h.tag]) or (h.prefix and idStarts(c, h.prefix)) then return h.text end
    end
    local parts = {}
    for n = 1, 4 do
        if c.tags["DarkFutureConsumableNutritionTier" .. n] then parts[#parts + 1] = "nutrition " .. n .. "/4" end
    end
    for n = 1, 3 do
        if c.tags["DarkFutureConsumableHydrationTier" .. n] then parts[#parts + 1] = "hydration " .. n .. "/3" end
    end
    if c.tags.DarkFutureManagedConsumableCaffeine then parts[#parts + 1] = "caffeine" end
    if c.tags.DarkFutureConsumableHangoverTreatmentFood or c.tags.DarkFutureConsumableHangoverTreatmentDrink then parts[#parts + 1] = "eases hangover" end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

local SORTS = { { key = "name", label = "Name" }, { key = "count", label = "Count" } }

local DEFAULTS = {
    showWithOverlay = true,   -- draw the "Backpack" window whenever the CET overlay is open
    hudOpen = false,          -- on-screen list visible (toggled by hotkey)
    category = "all",
    sortBy = "name",
    followGameRules = true,
    worldChecks = true,
    playSound = true,
    showMessage = true,
    closeHudAfterUse = false,
    hudRows = 10,
    hudAlpha = 0.55,
    useCooldown = 0.6,        -- seconds between two uses (stops a double click from eating twice)
    collapsed = {},           -- group key -> true when its header is closed
    showHints = true,         -- grey "what it is for" note on each row
}

local M = { version = VERSION }
local cfg = {}
local st = {
    clock = 0.0, overlay = false,
    tab = "items", boosterCount = 0,  -- 1.2.0: "items" (All tab) or "boosters"
    entries = {}, view = {},          -- all usable entries / filtered + sorted view
    refreshTimer = 0.0, forceRefresh = true,
    selKey = nil, sel = 1,            -- on-screen list selection
    search = "",
    cooldownUntil = 0.0,
    lastResult = "",
    ruleMode = nil,                   -- "game" or "lua" (which restriction check worked last)
    overlayOpenedAt = 0.0,
    prevClicked = {},                 -- row keys that reported a click on the previous frame (edge check)
    prevHeader = {}, headerNow = {},  -- same for group headers (fallback headers only)
    lastBlockMsg = nil, lastBlockAt = -100.0,
}
local cache = {}                      -- TDBID key -> classification (records do not change in a session)

-- ---------------------------------------------------------------- helpers

local function log(fmt, ...)
    spdlog.info(string.format(fmt, ...))
end

local function enumName(e)
    if e == nil then return nil end
    local ok, v = pcall(function() return e.value end)
    if ok and type(v) == "string" then return v end
    local s = tostring(e)
    return s:match(":%s*([%w_]+)") or s
end

local function defined(x)
    if x == nil then return false end
    local ok, r = pcall(IsDefined, x)
    if ok then return r and true or false end
    return true
end

local function tdbKey(tdbid)
    local ok, s = pcall(function() return TDBID.ToStringDEBUG(tdbid) end)
    if ok and type(s) == "string" and s ~= "" then return s end
    local ok2, s2 = pcall(function() return string.format("%u:%u", tdbid.hash, tdbid.length) end)
    if ok2 then return s2 end
    return tostring(tdbid)
end

local function loadConfig()
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    cfg.collapsed = {}
    local f = io.open(CONFIG_FILE, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then
        log("config.json unreadable, defaults used")
        return
    end
    for k in pairs(DEFAULTS) do
        if data[k] ~= nil and type(data[k]) == type(DEFAULTS[k]) then cfg[k] = data[k] end
    end
    if not CAT_LABEL[cfg.category] then cfg.category = "all" end   -- 1.0.x keys food / drink / drug ... -> All
    local clean = {}
    for k, v in pairs(cfg.collapsed) do if type(k) == "string" and v == true then clean[k] = true end end
    cfg.collapsed = clean
    local sortOk = false
    for _, s in ipairs(SORTS) do if s.key == cfg.sortBy then sortOk = true end end
    if not sortOk then cfg.sortBy = "name" end
    cfg.hudRows = math.floor(math.max(3, math.min(30, cfg.hudRows)))
    cfg.hudAlpha = math.max(0.0, math.min(1.0, cfg.hudAlpha))
    cfg.useCooldown = math.max(0.0, math.min(5.0, cfg.useCooldown))
end

local function saveConfig()
    local f = io.open(CONFIG_FILE, "w")
    if not f then return end
    f:write(json.encode(cfg))
    f:close()
end

local function notify(msg)
    if not cfg.showMessage then return end
    pcall(function()
        local m = SimpleScreenMessage.new()
        m.isShown = true
        m.duration = 2.0
        m.message = tostring(msg)
        m.isInstant = true
        local defs = Game.GetAllBlackboardDefs()
        Game.GetBlackboardSystem():Get(defs.UI_Notifications):SetVariant(defs.UI_Notifications.WarningMessage, ToVariant(m), true)
    end)
end

local function getPlayer()
    local ok, p = pcall(Game.GetPlayer)
    if ok and defined(p) then return p end
    return nil
end

local function inMenu()
    local ok, v = pcall(function()
        local defs = Game.GetAllBlackboardDefs()
        return Game.GetBlackboardSystem():Get(defs.UI_System):GetBool(defs.UI_System.IsInMenu)
    end)
    return ok and v == true
end

local function psmInt(player, field)
    local ok, v = pcall(function()
        local defs = Game.GetAllBlackboardDefs()
        return player:GetPlayerStateMachineBlackboard():GetInt(defs.PlayerStateMachine[field])
    end)
    if ok and type(v) == "number" then return v end
    return 0
end

local function psmBool(player, field)
    local ok, v = pcall(function()
        local defs = Game.GetAllBlackboardDefs()
        return player:GetPlayerStateMachineBlackboard():GetBool(defs.PlayerStateMachine[field])
    end)
    return ok and v == true
end

local function hasTag(player, tag)
    local ok, v = pcall(function() return StatusEffectSystem.ObjectHasStatusEffectWithTag(player, tag) end)
    return ok and v == true
end

local function inScene(player)
    local tier = psmInt(player, "HighLevel")
    return tier >= 3 and tier <= 5   -- gamePSMHighLevel SceneTier3..5 (same test as InventoryGPRestrictionHelper.BlockedBySceneTier)
end

-- ---------------------------------------------------------------- inventory

-- 1.2.1: effect lines of an item, as the inventory tooltip builds them: every OnAttach / OnEquip package with UIData,
-- its localized description with {int_N} / {float_N} / {name_N} filled in, rich-text tags removed.
local function fmtFloat(v)
    if type(v) ~= "number" then return tostring(v) end
    if math.abs(v - math.floor(v + 0.5)) < 0.001 then return tostring(math.floor(v + 0.5)) end
    return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end

local function fillUIText(ui)
    local text = Game.GetLocalizedTextByKey(ui:LocalizedDescription())
    if type(text) ~= "string" or text == "" or text == "None" then return nil end
    local ints, floats, names = {}, {}, {}
    pcall(function() ints = ui:IntValues() or {} end)
    pcall(function() floats = ui:FloatValues() or {} end)
    pcall(function() names = ui:NameValues() or {} end)
    text = text:gsub("{(%a+)_(%d+)[^}]*}", function(kind, n)
        local i = tonumber(n) + 1
        if kind == "int" and ints[i] ~= nil then return tostring(ints[i]) end
        if kind == "float" and floats[i] ~= nil then return fmtFloat(floats[i]) end
        if kind == "name" and names[i] ~= nil then
            local nm = names[i]
            local okL, l = pcall(function() return Game.GetLocalizedTextByKey(nm) end)
            if okL and type(l) == "string" and l ~= "" then return l end
            local okS, ss = pcall(function() return Game.NameToString(nm) end)
            return okS and ss or "?"
        end
        return nil
    end)
    text = text:gsub("<[^>]*>", "")
    return text
end

local function effectLines(rec)
    local out = {}
    for _, getter in ipairs({ "OnAttach", "OnEquip" }) do
        pcall(function()
            for _, pkg in ipairs(rec[getter](rec) or {}) do
                pcall(function()
                    local ui = pkg:UIData()
                    if not defined(ui) then return end
                    local t = fillUIText(ui)
                    if not t then return end
                    for line in (t .. "\n"):gmatch("([^\n]*)\n") do
                        line = line:gsub("^%s+", ""):gsub("%s+$", "")
                        if line ~= "" then
                            out[#out + 1] = { text = line, bad = line:find("%-%d") ~= nil or line:find("^%-") ~= nil }
                        end
                    end
                end)
            end
        end)
    end
    return #out > 0 and out or nil
end

-- Classifies an item record once: usable in the backpack sense, category, display name.
local function classify(id)
    local tdbid = ItemID.GetTDBID(id)
    local key = tdbKey(tdbid)
    local c = cache[key]
    if c then return c, key end
    c = { usable = false }
    local ok, err = pcall(function()
        local rec = TweakDBInterface.GetItemRecord(tdbid)
        if not defined(rec) then return end
        c.itype = enumName(rec:ItemType():Type())
        if c.itype == "Con_Inhaler" or c.itype == "Con_Injector" then return end   -- the backpack refuses these too
        for _, a in ipairs(ACTIONS) do
            local r = ItemActionsHelper[a[1]](id)
            if defined(r) then
                c.act = a[2]
                c.usable = true
                break
            end
        end
        if not c.usable then return end
        local name = Game.GetLocalizedTextByKey(rec:DisplayName())
        if type(name) ~= "string" or name == "" then name = key end
        c.name = name
        c.lname = name:lower()
        pcall(function() c.consumable = enumName(rec:ItemCategory():Type()) == "Consumable" end)
        -- grouping data
        c.id = key
        c.tags = {}
        pcall(function()
            for _, t in ipairs(rec:Tags() or {}) do
                local s = enumName(t)
                if s and s ~= "" then c.tags[s] = true end
            end
        end)
        for n = 1, 4 do if c.tags["DarkFutureConsumableNutritionTier" .. n] then c.dfNut = true end end
        pcall(function() c.base = enumName(rec:ConsumableBaseName():Type()) end)
        if not c.base then
            pcall(function() c.base = enumName(TweakDBInterface.GetConsumableItemRecord(tdbid):ConsumableBaseName():Type()) end)
        end
        c.group = "drug"
        for _, g in ipairs(GROUPS) do
            local okT, hit = pcall(g.test, c)
            if okT and hit then c.group = g.key break end
        end
        c.cat = GROUP_BY_KEY[c.group].section
        c.hint = hintFor(c)
        pcall(function()
            local d = Game.GetLocalizedTextByKey(rec:LocalizedDescription())
            if type(d) == "string" and d ~= "" and d ~= "None" then c.desc = d end
        end)
        c.effects = effectLines(rec)   -- 1.2.1
    end)
    if not ok then
        log("classify failed for %s: %s", key, tostring(err))
        c.usable = false
    end
    cache[key] = c
    return c, key
end

local function sortView()
    local by = cfg.sortBy
    table.sort(st.view, function(a, b)
        local ga, gb = GROUP_ORDER[a.group] or 999, GROUP_ORDER[b.group] or 999
        if ga ~= gb then return ga < gb end   -- always grouped; the sort applies inside a group
        if by == "count" and a.qty ~= b.qty then return a.qty > b.qty end
        if a.lname ~= b.lname then return a.lname < b.lname end
        return a.key < b.key
    end)
end

local function rebuildView()
    local view = {}
    local needle = st.search ~= "" and st.search:lower() or nil
    st.boosterCount = 0
    for _, e in ipairs(st.entries) do
        if e.cat == "boosters" then st.boosterCount = st.boosterCount + 1 end
        -- 1.2.0: two tabs. Boosters tab = section "boosters" only; All tab = everything else, filtered by the
        -- category box (a search in the All tab still finds boosters)
        local show
        if st.tab == "boosters" then
            show = e.cat == "boosters"
        else
            show = (cfg.category == "all" and (e.cat ~= "boosters" or needle ~= nil)) or e.cat == cfg.category
        end
        if show
            and (not needle or e.lname:find(needle, 1, true) or (e.hint and e.hint:lower():find(needle, 1, true))
                 or GROUP_BY_KEY[e.group].label:lower():find(needle, 1, true)) then
            view[#view + 1] = e
        end
    end
    st.view = view
    sortView()
    -- keep the on-screen selection on the same item
    st.sel = 1
    if st.selKey then
        for i, e in ipairs(view) do if e.key == st.selKey then st.sel = i break end end
    end
    if view[st.sel] then st.selKey = view[st.sel].key end
end

local function rebuild()
    local player = getPlayer()
    if not player then
        st.entries = {}
        rebuildView()
        return
    end
    local ok, items = pcall(function()
        local success, list = Game.GetTransactionSystem():GetItemList(player)
        if not success then return nil end
        return list
    end)
    if not ok or type(items) ~= "table" then
        if not ok then log("GetItemList failed: %s", tostring(items)) end
        return
    end
    local byKey, list = {}, {}
    for _, item in ipairs(items) do
        local okItem, id = pcall(function() return item:GetID() end)
        if okItem and id then
            local c, key = classify(id)
            if c.usable then
                local q = 1
                pcall(function() q = item:GetQuantity() end)
                local e = byKey[key]
                if e then
                    e.qty = e.qty + q
                else
                    e = { key = key, id = id, name = c.name, lname = c.lname, cat = c.cat, qty = q, consumable = c.consumable,
                          group = c.group, hint = c.hint, desc = c.desc, effects = c.effects }
                    byKey[key] = e
                    list[#list + 1] = e
                end
            end
        end
    end
    st.entries = list
    rebuildView()
end

-- ---------------------------------------------------------------- use

-- Lua copy of the vanilla rule (InventoryGPRestrictionHelper.CanUse, 2.31) for when the game call fails.
local function luaCanUse(player, e)
    if e.consumable and psmInt(player, "Combat") == 1 then   -- gamePSMCombat.InCombat
        local allowed = false
        pcall(function()
            local data = Game.GetTransactionSystem():GetItemData(player, e.id)
            allowed = data:HasTag("DarkFutureConsumableCombatUseAllowed")
        end)
        return allowed
    end
    return true
end

-- The game's own check, the one the backpack runs before "use_item" (Dark Future replaces it).
local function gameCanUse(player, e)
    local ok, res = pcall(function()
        local data = Game.GetTransactionSystem():GetItemData(player, e.id)
        if not defined(data) then return nil end
        local ui = UIInventoryItem.Make(player, data)
        if not defined(ui) then return nil end
        return InventoryGPRestrictionHelper.CanUse(ui, player)
    end)
    if ok and type(res) == "boolean" then
        if st.ruleMode ~= "game" then log("use rule: game check (InventoryGPRestrictionHelper.CanUse) works") end
        st.ruleMode = "game"
        return res
    end
    if st.ruleMode ~= "lua" then log("use rule: game check failed (%s), Lua copy of the vanilla rule used", tostring(res)) end
    st.ruleMode = "lua"
    return luaCanUse(player, e)
end

-- Returns nil when the item may be used now, otherwise a short reason.
local function blockedReason(player, e)
    if not player then return "no game loaded" end
    if inMenu() then return "a menu is open" end
    if inScene(player) then return "in a scene" end
    if cfg.worldChecks then
        if psmBool(player, "Carrying") or hasTag(player, "BodyCarryingGeneric") then return "carrying a body" end
        if psmInt(player, "Melee") == 1 then return "mid melee attack" end   -- gamePSMMelee.Attack
        if hasTag(player, "FistFight") then return "fist fight" end
    end
    if cfg.followGameRules and not gameCanUse(player, e) then
        if psmInt(player, "Combat") == 1 then return "in combat" end
        return "the backpack would refuse it now"
    end
    return nil
end

local function useEntry(e)
    if not e then return false end
    if st.clock < st.cooldownUntil then return false end
    local player = getPlayer()
    local reason = blockedReason(player, e)
    if reason then
        st.lastResult = string.format("%s: not used (%s)", e.name, reason)
        if st.lastResult ~= st.lastBlockMsg or st.clock - st.lastBlockAt >= BLOCK_LOG_GAP then
            st.lastBlockMsg = st.lastResult
            st.lastBlockAt = st.clock
            notify("Can't use " .. e.name .. ": " .. reason)
            log("%s", st.lastResult)
        end
        return false
    end
    local ok, err = pcall(function() ItemActionsHelper.PerformItemAction(player, e.id) end)
    if not ok then
        st.lastResult = string.format("%s: use failed (%s)", e.name, tostring(err))
        log("%s", st.lastResult)
        return false
    end
    if cfg.playSound then
        pcall(function() GameObject.PlaySoundEvent(player, EAT_SOUND) end)
    end
    st.cooldownUntil = st.clock + cfg.useCooldown
    st.lastResult = string.format("Used %s (had %d)", e.name, e.qty)
    log("Used %s [%s] (had %d)", e.name, e.key, e.qty)
    notify(e.name)
    -- the inventory may update a frame later: refresh soon and once more after a second
    st.refreshTimer = 0.2
    st.secondRefresh = 1.0
    if cfg.closeHudAfterUse then cfg.hudOpen = false saveConfig() end
    return true
end

-- ---------------------------------------------------------------- on-screen list control

local function hudAllowed()
    local player = getPlayer()
    return player ~= nil and not inMenu() and not inScene(player)
end

local function moveSel(d)
    local n = #st.view
    if n == 0 then return end
    st.sel = ((st.sel - 1 + d) % n) + 1
    st.selKey = st.view[st.sel].key
end

local function nextCategory()
    local idx = 1
    for i, c in ipairs(CATEGORIES) do if c.key == cfg.category then idx = i end end
    idx = idx % #CATEGORIES + 1
    cfg.category = CATEGORIES[idx].key
    saveConfig()
    rebuildView()
end

local function openHud()
    if cfg.hudOpen then return false end
    cfg.hudOpen = true
    saveConfig()
    rebuild()
    return true
end

-- ---------------------------------------------------------------- console API

-- 1.2.0: console / mock: GetMod("CyberslopBackpack")._setTab("boosters") or ("items")
function M._setTab(key)
    if key ~= "boosters" and key ~= "items" then return false end
    st.tab = key
    rebuildView()
    return true
end

function M.list()
    rebuild()
    for i, e in ipairs(st.view) do
        print(string.format("%3d  %-26s x%-4d %s%s", i, GROUP_BY_KEY[e.group].label, e.qty, e.name, e.hint and ("  (" .. e.hint .. ")") or ""))
    end
    print(string.format("%d usable items shown (%d total, category %s)", #st.view, #st.entries, cfg.category))
end

function M.use(part)
    rebuild()
    part = tostring(part or ""):lower()
    for _, e in ipairs(st.entries) do
        if e.lname:find(part, 1, true) then return useEntry(e) end
    end
    print("no usable item matches '" .. part .. "'")
    return false
end

-- Records (consumables first, then all items) whose display name equals `name` (case-insensitive).
local function findRecords(name)
    name = tostring(name or ""):lower()
    local found, seen = {}, {}
    for _, recType in ipairs({ "gamedataConsumableItem_Record", "gamedataItem_Record" }) do
        local ok, recs = pcall(function() return TweakDB:GetRecords(recType) end)
        if ok and type(recs) == "table" then
            for _, rec in ipairs(recs) do
                pcall(function()
                    local id = TDBID.ToStringDEBUG(rec:GetID())
                    if not seen[id] then
                        seen[id] = true
                        local n = Game.GetLocalizedTextByKey(rec:DisplayName())
                        if type(n) == "string" and n:lower() == name then found[#found + 1] = { id = id, name = n } end
                    end
                end)
            end
        end
        if #found > 0 then break end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    return found
end

function M.find(name)
    local found = findRecords(name)
    for i, r in ipairs(found) do print(string.format("%d  %s  (%s)", i, r.id, r.name)) end
    print(string.format("%d record(s) named '%s'", #found, tostring(name)))
    return found
end

-- Gives `count` of the item named `name` (exact display name). Several records with that name:
-- pass `pick` (the number from .find) to choose one; without it nothing is given.
function M.restore(name, count, pick)
    count = math.floor(tonumber(count) or 1)
    local found = findRecords(name)
    if #found == 0 then print("no item named '" .. tostring(name) .. "'") return false end
    local r = found[tonumber(pick) or 0]
    if not r then
        if #found == 1 then r = found[1] else
            M.find(name)
            print("several records share that name: call restore(name, count, number) with the number from the list")
            return false
        end
    end
    local ok, err = pcall(function() Game.AddToInventory(r.id, count) end)
    log("restore %s x%d [%s]: %s", r.name, count, r.id, ok and "given" or tostring(err))
    print(ok and string.format("gave %d x %s (%s)", count, r.name, r.id) or ("failed: " .. tostring(err)))
    st.forceRefresh = true
    return ok
end

function M.status()
    print(string.format("CyberslopBackpack %s: %d usable items, %d records cached, rule check %s, last: %s",
        VERSION, #st.entries, (function() local n = 0 for _ in pairs(cache) do n = n + 1 end return n end)(),
        tostring(st.ruleMode), st.lastResult))
end

-- ---------------------------------------------------------------- events

registerForEvent("onInit", function()
    loadConfig()
    log("CyberslopBackpack %s loaded (overlay window %s, list %s)", VERSION, tostring(cfg.showWithOverlay), tostring(cfg.hudOpen))
end)

registerForEvent("onUpdate", function(dt)
    st.clock = st.clock + dt
    local visible = (st.overlay and cfg.showWithOverlay) or cfg.hudOpen
    if st.secondRefresh then
        st.secondRefresh = st.secondRefresh - dt
        if st.secondRefresh <= 0 then st.secondRefresh = nil st.forceRefresh = true end
    end
    if not visible and not st.forceRefresh then return end
    st.refreshTimer = st.refreshTimer - dt
    if st.forceRefresh or st.refreshTimer <= 0 then
        st.forceRefresh = false
        st.refreshTimer = REFRESH_SECONDS
        rebuild()
    end
end)

registerForEvent("onOverlayOpen", function()
    st.overlay = true
    st.overlayOpenedAt = st.clock
    st.prevClicked = {}
    st.forceRefresh = true
end)

registerForEvent("onOverlayClose", function()
    st.overlay = false
end)

registerHotkey("BackpackList", "Backpack list on/off", function()
    cfg.hudOpen = not cfg.hudOpen
    saveConfig()
    if cfg.hudOpen then rebuild() end
end)

registerHotkey("BackpackNext", "Backpack list: next item (opens the list)", function()
    if openHud() then return end
    moveSel(1)
end)

registerHotkey("BackpackPrev", "Backpack list: previous item (opens the list)", function()
    if openHud() then return end
    moveSel(-1)
end)

registerHotkey("BackpackUse", "Backpack list: use selected item (opens the list)", function()
    if openHud() then return end
    useEntry(st.view[st.sel])
end)

registerHotkey("BackpackCategory", "Backpack list: next category (opens the list)", function()
    if openHud() then return end
    nextCategory()
end)

-- ---------------------------------------------------------------- drawing

local function catIndex()
    for i, c in ipairs(CATEGORIES) do if c.key == cfg.category then return i - 1 end end
    return 0
end

local function sortIndex()
    for i, s in ipairs(SORTS) do if s.key == cfg.sortBy then return i - 1 end end
    return 0
end

local CAT_NAMES, SORT_NAMES = {}, {}
for i, c in ipairs(CATEGORIES) do CAT_NAMES[i] = c.label end
for i, s in ipairs(SORTS) do SORT_NAMES[i] = s.label end

local function drawOptions()
    local changed = false
    local v, c
    v, c = ImGui.Checkbox("Follow the backpack's use rules (combat, Dark Future)", cfg.followGameRules)
    if c then cfg.followGameRules = v changed = true end
    v, c = ImGui.Checkbox("World checks (carrying a body, melee attack, fist fight)", cfg.worldChecks)
    if c then cfg.worldChecks = v changed = true end
    v, c = ImGui.Checkbox("Play the backpack's eat sound", cfg.playSound)
    if c then cfg.playSound = v changed = true end
    v, c = ImGui.Checkbox("Show the item name on screen after use", cfg.showMessage)
    if c then cfg.showMessage = v changed = true end
    v, c = ImGui.Checkbox("Close the on-screen list after a use", cfg.closeHudAfterUse)
    if c then cfg.closeHudAfterUse = v changed = true end
    v, c = ImGui.Checkbox("Show this window when the CET overlay opens", cfg.showWithOverlay)
    if c then cfg.showWithOverlay = v changed = true end
    v, c = ImGui.Checkbox("Show what each item is for (grey note)", cfg.showHints)
    if c then cfg.showHints = v changed = true end
    if ImGui.Button("Open all groups") then cfg.collapsed = {} changed = true end
    ImGui.SameLine()
    if ImGui.Button("Close all groups") then
        cfg.collapsed = {}
        for _, g in ipairs(GROUPS) do cfg.collapsed[g.key] = true end
        changed = true
    end
    ImGui.SetNextItemWidth(150)
    v, c = ImGui.SliderInt("On-screen list rows", cfg.hudRows, 3, 30)
    if c then cfg.hudRows = v changed = true end
    ImGui.SetNextItemWidth(150)
    v, c = ImGui.SliderFloat("On-screen list background", cfg.hudAlpha, 0.0, 1.0, "%.2f")
    if c then cfg.hudAlpha = v changed = true end
    ImGui.SetNextItemWidth(150)
    v, c = ImGui.SliderFloat("Seconds between uses", cfg.useCooldown, 0.0, 3.0, "%.1f")
    if c then cfg.useCooldown = v changed = true end
    if changed then saveConfig() end
end

-- Collapsible group header; returns true when open. Open / closed is kept in cfg.collapsed.
local HAS_SET_OPEN = nil
local function drawGroupHeader(g, count)
    if HAS_SET_OPEN == nil then
        HAS_SET_OPEN = type(ImGui.SetNextItemOpen) == "function" and ImGuiCond ~= nil and ImGuiCond.Always ~= nil
        log("group headers: %s", HAS_SET_OPEN and "CollapsingHeader" or "fallback rows")
    end
    local wantOpen = not cfg.collapsed[g.key]
    local label = string.format("%s  (%d)##cbg_%s", g.label, count, g.key)
    local open
    if HAS_SET_OPEN then
        ImGui.SetNextItemOpen(wantOpen, ImGuiCond.Always)
        open = ImGui.CollapsingHeader(label) == true
    else   -- fallback: a plain row that toggles on click (edge-checked like the item rows)
        local clicked = ImGui.Selectable((wantOpen and "[-] " or "[+] ") .. label, false) == true
        local k = "grp:" .. g.key
        if clicked then
            st.headerNow[k] = true
            if not st.prevHeader[k] then open = not wantOpen end
        end
        if open == nil then open = wantOpen end
    end
    if ImGui.IsItemHovered() and g.about then ImGui.SetTooltip(g.about) end
    if open ~= wantOpen then
        cfg.collapsed[g.key] = (not open) or nil
        saveConfig()
    end
    return open
end

-- Hover box: the grey note, the effect lines the inventory tooltip shows (1.2.1; negative ones red) and the game's
-- own description of the item.
local function drawItemTooltip(e)
    ImGui.BeginTooltip()
    ImGui.PushTextWrapPos(ImGui.GetFontSize() * 28)
    ImGui.Text(e.name)
    if e.hint then ImGui.TextDisabled(e.hint) end
    local fx = e.effects
    if fx == nil and e.key and cache[e.key] then fx = cache[e.key].effects end
    if fx then
        ImGui.Separator()
        for _, l in ipairs(fx) do
            if l.bad then
                ImGui.TextColored(1.0, 0.42, 0.36, 1.0, l.text)
            else
                ImGui.TextColored(0.55, 0.9, 1.0, 1.0, l.text)
            end
        end
    end
    if e.desc then
        ImGui.Separator()
        ImGui.TextWrapped(e.desc)
    end
    ImGui.PopTextWrapPos()
    ImGui.EndTooltip()
end

local function drawWindow()
    ImGui.SetNextWindowSize(420, 520, ImGuiCond.FirstUseEver)
    if not ImGui.Begin("Backpack") then
        ImGui.End()
        return
    end
    if not getPlayer() then
        ImGui.TextDisabled("No game loaded.")
        ImGui.End()
        return
    end

    -- 1.2.0: All | Boosters tabs side by side (### keeps the tab ID stable while the count changes)
    local newTab = st.tab
    if ImGui.BeginTabBar("##cbtabs") then
        if ImGui.BeginTabItem("All###cbtaball") then newTab = "items" ImGui.EndTabItem() end
        if ImGui.BeginTabItem(string.format("Boosters (%d)###cbtabboost", st.boosterCount or 0)) then newTab = "boosters" ImGui.EndTabItem() end
        ImGui.EndTabBar()
    end
    if newTab ~= st.tab then st.tab = newTab rebuildView() end

    if st.tab ~= "boosters" then
        ImGui.SetNextItemWidth(170)
        local ci, cc = ImGui.Combo("##cbcat", catIndex(), CAT_NAMES, #CAT_NAMES)
        if cc then cfg.category = CATEGORIES[ci + 1].key saveConfig() rebuildView() end
        ImGui.SameLine()
    end
    ImGui.SetNextItemWidth(100)
    local si, sc = ImGui.Combo("##cbsort", sortIndex(), SORT_NAMES, #SORT_NAMES)
    if sc then cfg.sortBy = SORTS[si + 1].key saveConfig() rebuildView() end
    ImGui.SameLine()
    local hudLabel = cfg.hudOpen and "List on" or "List off"
    if ImGui.Button(hudLabel, 70, 0) then
        cfg.hudOpen = not cfg.hudOpen
        saveConfig()
    end

    ImGui.SetNextItemWidth(-1)
    local s = ImGui.InputTextWithHint("##cbsearch", "Search", st.search, 64)
    if type(s) == "string" and s ~= st.search then st.search = s rebuildView() end

    if ImGui.CollapsingHeader("Options") then drawOptions() end

    ImGui.TextDisabled(string.format("%d items. Click one to use it.", #st.view))
    if st.lastResult ~= "" then ImGui.TextWrapped(st.lastResult) end
    ImGui.Separator()

    ImGui.BeginChild("cblist", 0, 0)
    local clickedNow = {}
    local guard = st.clock - st.overlayOpenedAt < OPEN_GUARD
    local counts = {}
    for _, e in ipairs(st.view) do counts[e.group] = (counts[e.group] or 0) + 1 end
    local curGroup, groupOpen = nil, true
    for i, e in ipairs(st.view) do
        if e.group ~= curGroup then
            if curGroup and groupOpen then ImGui.Unindent(10) end
            curGroup = e.group
            groupOpen = drawGroupHeader(GROUP_BY_KEY[e.group], counts[e.group] or 0)
            if groupOpen then ImGui.Indent(10) end
        end
        if groupOpen then
            local text = string.format("%s  x%d", e.name, e.qty)
            local x0 = ImGui.GetCursorPosX()
            -- CET returns the selected state, not "clicked": always pass false, so it is true only on the
            -- frame of a click. The selection is shown by colour instead.
            local isSel = st.selKey == e.key
            if isSel then ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.85, 0.3, 1.0) end
            local clicked = ImGui.Selectable(text .. "##cb" .. e.key, false) == true
            if isSel then ImGui.PopStyleColor(1) end
            if ImGui.IsItemHovered() and (e.desc or e.hint or e.effects) then drawItemTooltip(e) end
            if cfg.showHints and e.hint then
                local w = ImGui.CalcTextSize(text)
                ImGui.SameLine(x0 + (tonumber(w) or 0) + 14)
                ImGui.TextDisabled(e.hint)
            end
            if clicked then
                clickedNow[e.key] = true
                -- edge check: a row that reports a click on consecutive frames counts once
                if not st.prevClicked[e.key] and not guard then
                    st.selKey = e.key
                    st.sel = i
                    useEntry(e)
                end
            end
        end
    end
    if curGroup and groupOpen then ImGui.Unindent(10) end
    if #st.view == 0 then ImGui.TextDisabled(st.search ~= "" and "Nothing matches the search." or "Nothing usable in this section.") end
    st.prevClicked = clickedNow
    st.prevHeader = st.headerNow
    st.headerNow = {}
    ImGui.EndChild()
    ImGui.End()
end

local function drawHud()
    local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoCollapse
        + (ImGuiWindowFlags.NoFocusOnAppearing or 0) + (ImGuiWindowFlags.NoNav or 0)
    if not st.overlay then flags = flags + (ImGuiWindowFlags.NoInputs or 0) end
    ImGui.SetNextWindowPos(40, 320, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(cfg.hudAlpha)
    if not ImGui.Begin("Backpack list", flags) then
        ImGui.End()
        return
    end
    local n = #st.view
    ImGui.Text(string.format("%s  (%d)", st.tab == "boosters" and "Boosters" or CAT_LABEL[cfg.category], n))
    ImGui.Separator()
    if n == 0 then
        ImGui.TextDisabled("nothing usable")
    else
        local rows = cfg.hudRows
        local first = math.max(1, st.sel - math.floor(rows / 2))
        local last = math.min(n, first + rows - 1)
        first = math.max(1, last - rows + 1)
        if first > 1 then ImGui.TextDisabled("  ...") end
        local lastGroup = nil
        for i = first, last do
            local e = st.view[i]
            if e.group ~= lastGroup then
                lastGroup = e.group
                ImGui.TextDisabled(GROUP_BY_KEY[e.group].label)
            end
            local line = string.format("%s x%d", e.name, e.qty)
            if i == st.sel and cfg.showHints and e.hint then line = line .. "  - " .. e.hint end
            if i == st.sel then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.85, 0.3, 1.0)
                ImGui.Text("> " .. line)
                ImGui.PopStyleColor(1)
            else
                ImGui.Text("  " .. line)
            end
        end
        if last < n then ImGui.TextDisabled("  ...") end
    end
    if st.overlay then ImGui.TextDisabled("Drag to move. Keys: CET Bindings > CyberslopBackpack") end
    ImGui.End()
end

registerForEvent("onDraw", function()
    if st.overlay and cfg.showWithOverlay then drawWindow() end
    if cfg.hudOpen and hudAllowed() then drawHud() end
end)

return M
