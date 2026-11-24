-- ============================================================
--  Cyberslop Backpack 1.0.1 (2026-11-01, built for game 2.31)
--  Use backpack items without opening the (pausing) backpack screen.
-- ============================================================
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

local VERSION = "1.0.1"
local OPEN_GUARD = 0.25            -- seconds after the overlay opens in which no click counts
local BLOCK_LOG_GAP = 2.0          -- same "not used" reason for the same item: log / show it at most this often
local CONFIG_FILE = "config.json"
local REFRESH_SECONDS = 1.0       -- list rebuild interval while a list is visible
local EAT_SOUND = "ui_loot_eat_ui" -- the sound the backpack plays on use

local CATEGORIES = {
    { key = "all",   label = "All" },
    { key = "food",  label = "Food" },
    { key = "drink", label = "Drinks" },
    { key = "drug",  label = "Drugs and boosters" },
    { key = "learn", label = "Shards and recipes" },
    { key = "funds", label = "Eddie shards" },
}
local CAT_LABEL = {}
for _, c in ipairs(CATEGORIES) do CAT_LABEL[c.key] = c.label end

-- Action getter (ItemActionsHelper static) -> category. First match wins.
local ACTIONS = {
    { "GetEatAction", "food" },
    { "GetDrinkAction", "drink" },
    { "GetConsumeAction", "drug" },
    { "GetLearnAction", "learn" },
    { "GetDownloadFunds", "funds" },
}
local SORTS = { { key = "name", label = "Name" }, { key = "count", label = "Count" }, { key = "category", label = "Category" } }

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
}

local M = { version = VERSION }
local cfg = {}
local st = {
    clock = 0.0, overlay = false,
    entries = {}, view = {},          -- all usable entries / filtered + sorted view
    refreshTimer = 0.0, forceRefresh = true,
    selKey = nil, sel = 1,            -- on-screen list selection
    search = "",
    cooldownUntil = 0.0,
    lastResult = "",
    ruleMode = nil,                   -- "game" or "lua" (which restriction check worked last)
    overlayOpenedAt = 0.0,
    prevClicked = {},                 -- row keys that reported a click on the previous frame (edge check)
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
    if not CAT_LABEL[cfg.category] then cfg.category = "all" end
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
                c.cat = a[2]
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
    local catOrder = {}
    for i, c in ipairs(CATEGORIES) do catOrder[c.key] = i end
    table.sort(st.view, function(a, b)
        if by == "count" and a.qty ~= b.qty then return a.qty > b.qty end
        if by == "category" and a.cat ~= b.cat then return catOrder[a.cat] < catOrder[b.cat] end
        if a.lname ~= b.lname then return a.lname < b.lname end
        return a.key < b.key
    end)
end

local function rebuildView()
    local view = {}
    local needle = st.search ~= "" and st.search:lower() or nil
    for _, e in ipairs(st.entries) do
        if (cfg.category == "all" or e.cat == cfg.category) and (not needle or e.lname:find(needle, 1, true)) then
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
                    e = { key = key, id = id, name = c.name, lname = c.lname, cat = c.cat, qty = q, consumable = c.consumable }
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

function M.list()
    rebuild()
    for i, e in ipairs(st.view) do print(string.format("%3d  %-20s x%-4d %s", i, CAT_LABEL[e.cat], e.qty, e.name)) end
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

    ImGui.SetNextItemWidth(170)
    local ci, cc = ImGui.Combo("##cbcat", catIndex(), CAT_NAMES, #CAT_NAMES)
    if cc then cfg.category = CATEGORIES[ci + 1].key saveConfig() rebuildView() end
    ImGui.SameLine()
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
    for i, e in ipairs(st.view) do
        local label
        if cfg.category == "all" then
            label = string.format("%s  x%d   [%s]##cb%s", e.name, e.qty, CAT_LABEL[e.cat], e.key)
        else
            label = string.format("%s  x%d##cb%s", e.name, e.qty, e.key)
        end
        -- CET returns the selected state, not "clicked": always pass false, so it is true only on the
        -- frame of a click. The selection is shown by colour instead.
        local isSel = st.selKey == e.key
        if isSel then ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.85, 0.3, 1.0) end
        local clicked = ImGui.Selectable(label, false) == true
        if isSel then ImGui.PopStyleColor(1) end
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
    st.prevClicked = clickedNow
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
    ImGui.Text(string.format("%s  (%d)", CAT_LABEL[cfg.category], n))
    ImGui.Separator()
    if n == 0 then
        ImGui.TextDisabled("nothing usable")
    else
        local rows = cfg.hudRows
        local first = math.max(1, st.sel - math.floor(rows / 2))
        local last = math.min(n, first + rows - 1)
        first = math.max(1, last - rows + 1)
        if first > 1 then ImGui.TextDisabled("  ...") end
        for i = first, last do
            local e = st.view[i]
            local line = string.format("%s x%d", e.name, e.qty)
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
