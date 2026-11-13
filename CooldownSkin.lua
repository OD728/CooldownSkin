-- Cooldown Skin: restyles the game's Cooldown Manager icons (Essential, Utility and
-- Tracked Buff icons). The viewers, their layout and their spells stay the game's.
--
--  * Square icons, cropped, inside a black border (2 px by default). The game's round mask and
--    frame art are removed (art only by alpha).
--  * While your debuff (or buff) is up, the game normally paints a yellow swipe over
--    the whole icon. Instead the icon stays bright, the border takes your class
--    color, and a dark swipe grows as the debuff runs out.
--  * On cooldown: a plain dark square swipe.
--  * Outlined timer numbers sized to the icon.
--  * A thin class-colored timer bar above the icon while the debuff is up.
--
-- Nothing secret is read or compared. Whether the debuff is up comes from the icon's
-- wasSetFromAura flag, or, when that is secret, from the swipe color the game just
-- set (yellow = aura, black = cooldown).

local ADDON = ...

local VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer" }
local SQUARE = "Interface\\Buttons\\WHITE8X8"
local CROP = 0.08            -- trims the icon's own rounded edge
local SCAN = 0.5             -- seconds between checks for new icons

local DEFAULTS = {
    activeColor = "class",   -- border while the debuff/buff is up: "class" or { r, g, b }
    activeSwipe = 0.6,       -- darkness of the swipe while it's up
    cdSwipe = 0.75,          -- darkness of the cooldown swipe
    reverse = true,          -- while it's up, the dark part grows as it runs out
    border = 2,              -- border thickness in screen pixels
    textScale = 0.45,        -- timer size as a share of the icon's height
    font = "Fonts\\FRIZQT__.TTF",
    hideBling = true,        -- no flash when a cooldown finishes
    bar = "top",             -- timer bar while the debuff/buff is up: "top", "bottom" or "off"
    barHeight = 4,           -- its height in screen pixels (plus a 1 px border)
}

local db
local skins = setmetatable({}, { __mode = "k" })   -- item -> { border, art, blizzAura }
local mine = setmetatable({}, { __mode = "k" })    -- our own textures, never hidden
local pending = setmetatable({}, { __mode = "k" }) -- items to lay out after combat
local guard = false                                -- our own calls into hooked methods

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end

local function accent()
    local c = db.activeColor
    if type(c) == "table" then return c[1], c[2], c[3] end
    local _, class = UnitClass("player")
    local cc = class and ((C_ClassColor and C_ClassColor.GetClassColor(class)) or RAID_CLASS_COLORS[class])
    if cc then return cc.r, cc.g, cc.b end
    return 1, 0.82, 0
end

-- Laying out a protected frame's pieces is blocked in combat; it waits until after.
local function canLayout(item)
    return not (InCombatLockdown() and item.IsProtected and item:IsProtected())
end

local function pixels(item, n)
    if PixelUtil and PixelUtil.GetNearestPixelSize then
        return PixelUtil.GetNearestPixelSize(n, item:GetEffectiveScale(), n)
    end
    return n
end

-- Is the icon showing its debuff/buff rather than its cooldown?
local function isActive(item, p)
    local v = item.wasSetFromAura
    if type(v) == "boolean" and not secret(v) then return v end
    return p.blizzAura == true
end

-- Timer bar ----------------------------------------------------------------
-- The client fills the bar from a duration object (StatusBar:SetTimerDuration), so
-- no time is read here, secret or not. The duration is whatever the game just gave
-- the icon's cooldown: its debuff/buff time while that's up.

local function timerArgs()
    local E = type(Enum) == "table" and Enum or {}
    return E.StatusBarInterpolation and E.StatusBarInterpolation.Immediate,
        E.StatusBarTimerDirection and E.StatusBarTimerDirection.RemainingTime
end

local function feedDuration(p, d)
    if type(d) == "nil" or not p.bar or type(p.bar.SetTimerDuration) ~= "function" then
        p.hasTime = false
        return
    end
    local I, D = timerArgs()
    p.hasTime = pcall(p.bar.SetTimerDuration, p.bar, d, I, D)
end

local function feedStart(p, start, dur)
    local U = _G.C_DurationUtil
    if type(U) ~= "table" or type(U.CreateDuration) ~= "function" then p.hasTime = false; return end
    p.span = p.span or U.CreateDuration()
    if not pcall(p.span.SetTimeFromStart, p.span, start, dur) then p.hasTime = false; return end
    feedDuration(p, p.span)
end

local function makeBar(item, p)
    local h = CreateFrame("Frame", nil, item)
    h:SetFrameLevel(item:GetFrameLevel() + 5)
    local edge = h:CreateTexture(nil, "BACKGROUND", nil, -8)
    edge:SetAllPoints(h)
    edge:SetColorTexture(0, 0, 0, 1)
    local bar = CreateFrame("StatusBar", nil, h)
    bar:SetStatusBarTexture(SQUARE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local back = bar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints(bar)
    back:SetColorTexture(0.12, 0.12, 0.12, 0.9)
    h:Hide()
    p.barFrame, p.bar = h, bar
end

local function placeBar(item, p)
    local h = p.barFrame
    if not h then return end
    local px = pixels(item, 1)
    h:ClearAllPoints()
    if db.bar == "bottom" then
        h:SetPoint("TOPLEFT", item, "BOTTOMLEFT", 0, -px)
        h:SetPoint("TOPRIGHT", item, "BOTTOMRIGHT", 0, -px)
    else
        h:SetPoint("BOTTOMLEFT", item, "TOPLEFT", 0, px)
        h:SetPoint("BOTTOMRIGHT", item, "TOPRIGHT", 0, px)
    end
    h:SetHeight(pixels(item, db.barHeight) + 2 * px)
    p.bar:ClearAllPoints()
    p.bar:SetPoint("TOPLEFT", h, "TOPLEFT", px, -px)
    p.bar:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -px, px)
end

-- Swipe and border for the current state.
local function paint(item)
    local p = skins[item]
    local cd = item.Cooldown
    if not p or type(cd) ~= "table" then return end
    guard = true
    local active = isActive(item, p)
    if p.barFrame then
        p.barFrame:SetShown(db.bar ~= "off" and active and p.hasTime == true)
    end
    if active then
        local r, g, b = accent()
        p.border:SetColorTexture(r, g, b, 1)
        if p.bar then p.bar:SetStatusBarColor(r, g, b, 1) end
        pcall(cd.SetSwipeColor, cd, 0, 0, 0, db.activeSwipe)
        if cd.SetReverse then pcall(cd.SetReverse, cd, db.reverse) end
    else
        p.border:SetColorTexture(0, 0, 0, 1)
        pcall(cd.SetSwipeColor, cd, 0, 0, 0, db.cdSwipe)
        if cd.SetReverse then pcall(cd.SetReverse, cd, false) end
    end
    guard = false
end

-- The game's art on the icon: every texture except the icon, its out-of-range tint
-- and ours. Hidden by alpha, so nothing of the game's moves or hides.
local function hideArt(item)
    for _, r in ipairs({ item:GetRegions() }) do
        if r ~= item.Icon and r ~= item.OutOfRange and not mine[r]
            and r.GetObjectType and r:GetObjectType() == "Texture" then
            r:SetAlpha(0)
        end
    end
    if item.DebuffBorder and item.DebuffBorder.SetAlpha then item.DebuffBorder:SetAlpha(0) end
end

local function styleFont(fs, size)
    if type(fs) ~= "table" or not fs.SetFont then return end
    fs:SetFont(db.font, size, "OUTLINE")
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
end

local function styleText(item)
    local h = item:GetHeight()
    if type(h) ~= "number" or secret(h) or h <= 0 then h = 36 end
    local size = math.max(9, math.floor(h * db.textScale + 0.5))
    local cd = item.Cooldown
    local fs = cd and cd.GetCountdownFontString and cd:GetCountdownFontString()
    if fs then
        styleFont(fs, size)
        fs:SetTextColor(1, 1, 1, 1)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", cd, "CENTER", 0, 0)
    end
    -- Stacks and charges sit in the corner, smaller.
    local small = math.max(8, math.floor(size * 0.7 + 0.5))
    if type(item.Applications) == "table" then styleFont(item.Applications.Applications, small) end
    if type(item.ChargeCount) == "table" then styleFont(item.ChargeCount.Current, small) end
end

-- Icon inside the border, cooldown over the icon.
local function place(item)
    if not canLayout(item) then pending[item] = true; return end
    pending[item] = nil
    local icon, cd = item.Icon, item.Cooldown
    local b = pixels(item, db.border)
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", item, "TOPLEFT", b, -b)
    icon:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", -b, b)
    icon:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)
    if type(cd) == "table" then
        cd:ClearAllPoints()
        cd:SetAllPoints(icon)
        guard = true
        pcall(cd.SetSwipeTexture, cd, SQUARE)
        guard = false
        if cd.SetDrawEdge then cd:SetDrawEdge(false) end
        if cd.SetDrawBling then cd:SetDrawBling(not db.hideBling) end
    end
    local range = item.OutOfRange
    if type(range) == "table" and range.SetAllPoints then
        range:ClearAllPoints()
        range:SetAllPoints(icon)
    end
    placeBar(item, skins[item])
    styleText(item)
end

local function refresh(item)
    if not skins[item] then return end
    hideArt(item)
    place(item)
    paint(item)
end

local function hookCooldown(item, p)
    local cd = item.Cooldown
    if type(cd) ~= "table" then return end
    -- The game sets the swipe color as it switches between aura and cooldown:
    -- remember which it chose, then put ours on.
    hooksecurefunc(cd, "SetSwipeColor", function(_, r, g)
        if guard then return end
        if type(r) == "number" and type(g) == "number" and not secret(r) and not secret(g) then
            p.blizzAura = (r + g) > 0.5
        end
        paint(item)
    end)
    -- The time the game gives the swipe also feeds the timer bar.
    if type(cd.SetCooldown) == "function" then
        hooksecurefunc(cd, "SetCooldown", function(_, start, dur)
            if guard then return end
            feedStart(p, start, dur)
            paint(item)
        end)
    end
    if type(cd.SetCooldownFromDurationObject) == "function" then
        hooksecurefunc(cd, "SetCooldownFromDurationObject", function(_, d)
            if guard then return end
            feedDuration(p, d)
            paint(item)
        end)
    end
    if type(cd.Clear) == "function" then
        hooksecurefunc(cd, "Clear", function()
            if guard then return end
            p.hasTime = false
            paint(item)
        end)
    end
end

local function skin(item)
    if type(item) ~= "table" or skins[item] then return end
    local icon = item.Icon
    -- Icon views only: the bar view's Icon is a frame, not a texture.
    if type(icon) ~= "table" or not icon.GetObjectType or icon:GetObjectType() ~= "Texture" then return end
    local p = {}
    skins[item] = p
    if icon.GetNumMaskTextures then
        for i = icon:GetNumMaskTextures(), 1, -1 do
            local m = icon:GetMaskTexture(i)
            if m then pcall(icon.RemoveMaskTexture, icon, m) end
        end
    end
    p.border = item:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.border:SetAllPoints(item)
    p.border:SetColorTexture(0, 0, 0, 1)
    mine[p.border] = true
    makeBar(item, p)
    hookCooldown(item, p)
    item:HookScript("OnSizeChanged", function() place(item) end)
    item:HookScript("OnShow", function() refresh(item) end)
    refresh(item)
end

local function eachItem(viewer, fn)
    local pool = viewer.itemFramePool
    if type(pool) == "table" and pool.EnumerateActive then
        for item in pool:EnumerateActive() do fn(item) end
        return
    end
    for _, child in ipairs({ viewer:GetChildren() }) do
        if type(child) == "table" and child.Icon then fn(child) end
    end
end

local hookedViewers = {}
local function scan()
    for _, name in ipairs(VIEWERS) do
        local v = _G[name]
        if type(v) == "table" then
            if not hookedViewers[v] then
                hookedViewers[v] = true
                v:HookScript("OnShow", function(self) eachItem(self, function(i) skin(i); refresh(i) end) end)
            end
            eachItem(v, skin)
        end
    end
end

local function refreshAll()
    for item in pairs(skins) do refresh(item) end
end

local function paintAll()
    for item in pairs(skins) do paint(item) end
end

-- Options ------------------------------------------------------------------

local function say(msg) print("|cffcca3ffCooldown Skin:|r " .. msg) end

local function parseColor(a, b, c)
    local r, g, bl = tonumber(a), tonumber(b), tonumber(c)
    if not (r and g and bl) then return nil end
    if r > 1 or g > 1 or bl > 1 then r, g, bl = r / 255, g / 255, bl / 255 end
    return { r, g, bl }
end

SLASH_COOLDOWNSKIN1 = "/cskin"
SLASH_COOLDOWNSKIN2 = "/cooldownskin"
SlashCmdList.COOLDOWNSKIN = function(msg)
    local cmd, a, b, c = strsplit(" ", strtrim(msg or ""):lower())
    if cmd == "color" and a == "class" then
        db.activeColor = "class"
        say("border while up: class color")
    elseif cmd == "color" then
        local col = parseColor(a, b, c)
        if not col then return say("usage: /cskin color class  or  /cskin color 150 80 230") end
        db.activeColor = col
        say("border while up: custom color")
    elseif cmd == "reverse" then
        db.reverse = not db.reverse
        say(db.reverse and "the swipe grows as the debuff runs out" or "the swipe shrinks as the debuff runs out")
    elseif cmd == "border" and tonumber(a) then
        db.border = math.max(0, math.min(4, math.floor(tonumber(a))))
        say("border: " .. db.border .. " px")
    elseif cmd == "text" and tonumber(a) then
        db.textScale = math.max(0.2, math.min(0.8, tonumber(a)))
        say("timer size: " .. db.textScale .. " of the icon's height")
    elseif cmd == "dark" and tonumber(a) then
        db.activeSwipe = math.max(0, math.min(1, tonumber(a)))
        say("swipe darkness while up: " .. db.activeSwipe)
    elseif cmd == "bar" and (a == "top" or a == "bottom" or a == "off") then
        db.bar = a
        say(a == "off" and "timer bar: off" or ("timer bar: " .. a))
    elseif cmd == "barheight" and tonumber(a) then
        db.barHeight = math.max(1, math.min(12, math.floor(tonumber(a))))
        say("timer bar height: " .. db.barHeight .. " px")
    elseif cmd == "reset" then
        CooldownSkinDB = CopyTable(DEFAULTS)
        db = CooldownSkinDB
        say("settings reset")
    else
        say("/cskin color class | color r g b  - border while your debuff is up")
        say("/cskin reverse  - flip which way the debuff swipe runs")
        say("/cskin border 0-4  - border thickness in pixels")
        say("/cskin bar top | bottom | off  - timer bar while your debuff is up")
        say("/cskin barheight 1-12  - timer bar height in pixels")
        say("/cskin text 0.2-0.8  - timer size")
        say("/cskin dark 0-1  - swipe darkness while up")
        say("/cskin reset")
        return
    end
    refreshAll()
end

-- Startup ------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterUnitEvent("UNIT_AURA", "target", "player")

local queued = false
local function paintSoon()
    if queued then return end
    queued = true
    C_Timer.After(0, function() queued = false; paintAll() end)
end

f:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg == ADDON then
            CooldownSkinDB = CooldownSkinDB or {}
            db = CooldownSkinDB
            -- v2: the action-bar frame style is gone and the border went from 1 to 2 px.
            if (db.v or 1) < 2 then
                db.style = nil
                if db.border == 1 then db.border = 2 end
                db.v = 2
            end
            for k, v in pairs(DEFAULTS) do
                if db[k] == nil then db[k] = type(v) == "table" and CopyTable(v) or v end
            end
            C_Timer.NewTicker(SCAN, scan)
        end
        if arg == ADDON or arg == "Blizzard_CooldownViewer" then
            if db then scan() end
        end
    elseif not db then
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        scan()
        refreshAll()
    elseif event == "PLAYER_REGEN_ENABLED" then
        for item in pairs(pending) do refresh(item) end
    else
        -- Target or aura changes: the game updates its icons, then we repaint.
        paintSoon()
    end
end)
