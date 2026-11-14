-- Cooldown Skin: restyles the game's Cooldown Manager icons (Essential, Utility and
-- Tracked Buff icons) and Tracked Bars. The viewers, their layout and their spells
-- stay the game's.
--
--  * Square icons, cropped, inside a black border (2 px by default). The game's round
--    mask and frame art are removed (art only by alpha).
--  * While your debuff (or buff) is up, the game normally paints a yellow swipe over
--    the whole icon. Instead the icon stays bright and a dark swipe grows as the
--    debuff runs out. The border stays black (or takes your class color, /cskin
--    highlight).
--  * On cooldown: a plain dark square swipe.
--  * Outlined timer numbers sized to the icon.
--  * A thin class-colored timer bar above the icon while the debuff is up.
--
-- Nothing secret is read or compared. Whether the debuff is up comes from the icon's
-- wasSetFromAura flag, or, when that is secret, from the swipe color the game just
-- set (yellow = aura, black = cooldown). The timer bar is the client's own: aura
-- containers watch the spell's debuff on the target, your HoT or buff on a friendly
-- target, and its buff on you (any rank you know), and the client fills
-- the bar itself, since in combat the times are secret and an addon may not pass
-- them on.

local ADDON = ...

local VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer", "BuffBarCooldownViewer" }
local SQUARE = "Interface\\Buttons\\WHITE8X8"
local CROP = 0.08            -- trims the icon's own rounded edge
local SCAN = 0.5             -- seconds between checks for new icons

local DEFAULTS = {
    highlight = false,       -- color the border while the debuff/buff is up (else it stays black)
    activeColor = "class",   -- that color and the timer bar's: "class" or { r, g, b }
    activeSwipe = 0.6,       -- darkness of the swipe while it's up
    cdSwipe = 0.75,          -- darkness of the cooldown swipe
    reverse = true,          -- while it's up, the dark part grows as it runs out
    border = 2,              -- border thickness in screen pixels
    textScale = 0.45,        -- timer size as a share of the icon's height
    font = "Fonts\\FRIZQT__.TTF",
    hideBling = true,        -- no flash when a cooldown finishes
    bar = "top",             -- timer bar while the debuff/buff is up: "top", "bottom" or "off"
    barHeight = 4,           -- its height in screen pixels (plus a 1 px border)
    barColor = "mix",        -- a BAR_PALETTES name, "class", or "mix" (each spell its own)
    barGlow = true,          -- spark at the bar's moving end
}

-- Gradient pairs for the timer bar, left to right.
local BAR_PALETTES = {
    neon   = { { 0.00, 1.00, 1.00 }, { 1.00, 0.00, 1.00 } },   -- cyan to magenta
    toxic  = { { 0.60, 1.00, 0.00 }, { 0.00, 1.00, 0.60 } },   -- lime to mint
    sunset = { { 1.00, 0.45, 0.00 }, { 1.00, 0.00, 0.55 } },   -- orange to hot pink
    void   = { { 0.65, 0.00, 1.00 }, { 0.00, 0.55, 1.00 } },   -- violet to electric blue
    fel    = { { 0.15, 1.00, 0.10 }, { 0.85, 1.00, 0.00 } },   -- fel green to yellow
    ice    = { { 0.70, 0.95, 1.00 }, { 0.15, 0.40, 1.00 } },   -- frost to deep blue
}
local MIX = { "neon", "toxic", "sunset", "void", "fel", "ice" }

local db
local skins = setmetatable({}, { __mode = "k" })   -- item -> parts and state
local mine = setmetatable({}, { __mode = "k" })    -- our own textures, never hidden
local pending = setmetatable({}, { __mode = "k" }) -- items to lay out after combat
local guard = false                                -- our own calls into hooked methods

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function plain(v) return type(v) == "number" and not secret(v) and v or nil end

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
-- A client AuraContainer per unit (your debuffs on the target, your buffs on you),
-- matched by the icon's spell ids. While the aura is up the client shows one button
-- and fills the StatusBar handed to it (SetDurationBar); the addon never touches the
-- time. The button locks once initializeFrame returns, so it's dressed there.

-- Every rank you know of each spell, by name, from the spellbook (it lists lower
-- ranks too). An aura carries the id of the rank that was cast. Cleared when your
-- spells change.
local rankMap
local function ranksByName()
    if rankMap then return rankMap end
    rankMap = {}
    local SB = _G.C_SpellBook
    if type(SB) ~= "table" or type(SB.GetNumSpellBookSkillLines) ~= "function" then return rankMap end
    local E = type(Enum) == "table" and Enum or {}
    local bank = E.SpellBookSpellBank and E.SpellBookSpellBank.Player or 0
    local spellType = E.SpellBookItemType and E.SpellBookItemType.Spell or 1
    local okN, lines = pcall(SB.GetNumSpellBookSkillLines)
    for line = 1, (okN and plain(lines)) or 0 do
        local okL, info = pcall(SB.GetSpellBookSkillLineInfo, line)
        local offset = okL and type(info) == "table" and plain(info.itemIndexOffset)
        local count = okL and type(info) == "table" and plain(info.numSpellBookItems)
        if offset and count then
            for i = 1, count do
                local okI, item = pcall(SB.GetSpellBookItemInfo, offset + i, bank)
                local id = okI and type(item) == "table" and plain(item.spellID)
                local name = id and item.name
                if id and item.itemType == spellType and type(name) == "string" and not secret(name) then
                    local list = rankMap[name] or {}
                    list[#list + 1] = id
                    rankMap[name] = list
                end
            end
        end
    end
    return rankMap
end

-- Every spell id the icon's cooldown stands for, as a set. nil if none can be read.
local function spellIDsOf(item)
    local cid = plain(item.cooldownID)
    local CV = _G.C_CooldownViewer
    if not cid or type(CV) ~= "table" or type(CV.GetCooldownViewerCooldownInfo) ~= "function" then return nil end
    local ok, info = pcall(CV.GetCooldownViewerCooldownInfo, cid)
    if not ok or type(info) ~= "table" then return nil end
    local ids, list = {}, {}
    local function add(s)
        s = plain(s)
        if s and s > 0 and not ids[s] then ids[s] = true; list[#list + 1] = s end
    end
    for _, k in ipairs({ "spellID", "overrideSpellID", "overrideTooltipSpellID", "linkedSpellID" }) do add(info[k]) end
    if type(info.linkedSpellIDs) == "table" then
        for _, s in ipairs(info.linkedSpellIDs) do add(s) end
    end
    -- Ranks: every rank you know of each spell, by name, so a lower rank you cast
    -- on purpose gets its bar too.
    if C_Spell and C_Spell.GetSpellName then
        local ranks = ranksByName()
        local n = #list
        for i = 1, n do
            local okN, name = pcall(C_Spell.GetSpellName, list[i])
            if okN and type(name) == "string" and not secret(name) then
                for _, s in ipairs(ranks[name] or {}) do add(s) end
                if C_Spell.GetSpellInfo then
                    local okI, si = pcall(C_Spell.GetSpellInfo, name)
                    if okI and type(si) == "table" then add(si.spellID) end
                end
            end
        end
    end
    if #list == 0 then return nil end
    local base = list[1]   -- the cooldown's own spell, for the bar's colors
    table.sort(list)
    return ids, cid .. ":" .. table.concat(list, ","), base
end

local function durationBarOptions()
    local opts = {}
    local D = type(Enum) == "table" and Enum.StatusBarTimerDirection
    if type(D) == "table" and D.RemainingTime then opts.direction = D.RemainingTime end
    local U = _G.C_AuraContainerUtil
    if type(U) == "table" and type(U.ProcessCustomAuraButtonDurationBarOptions) == "function" then
        local ok, o = pcall(U.ProcessCustomAuraButtonDurationBarOptions, opts)
        if ok and type(o) == "table" then opts = o end
    end
    return opts
end

-- The bar's two colors (left, right) for this icon.
local function barColors(p)
    local name = db.barColor
    if name == "mix" then
        -- By the cooldown's own spell, so learning a rank doesn't change it.
        name = MIX[((p.base or 0) % #MIX) + 1]
    end
    local pal = BAR_PALETTES[name]
    if pal then return pal[1], pal[2] end
    -- "class" (or a custom /cskin color): a darker shade into the full color.
    local r, g, b = accent()
    return { r * 0.55, g * 0.55, b * 0.55 }, { math.min(1, r * 1.15), math.min(1, g * 1.15), math.min(1, b * 1.15) }
end

local function gradient(tex, a, b)
    if CreateColor and tex.SetGradient then
        local ok = pcall(tex.SetGradient, tex, "HORIZONTAL", CreateColor(a[1], a[2], a[3], 1), CreateColor(b[1], b[2], b[3], 1))
        if ok then return end
    end
    pcall(tex.SetVertexColor, tex, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2, 1)
end

-- Dresses the client's button: thin black edge, a dark tint for the empty part, a
-- gradient fill, and a spark riding the fill's end. The client locks the button once
-- this returns, so a color change builds the buttons again (rebuildBars).
local function initBarButton(p, btn)
    local function try(fn, ...) return pcall(fn, ...) end
    p.made = (p.made or 0) + 1
    local w, h, px = p.barW, p.barH, p.px
    local left, right = barColors(p)
    try(btn.SetSize, btn, w, h)
    local edge = btn:CreateTexture(nil, "BACKGROUND", nil, -7)
    try(edge.SetPoint, edge, "TOPLEFT", btn, "TOPLEFT", 0, 0)
    try(edge.SetSize, edge, w, h)
    try(edge.SetColorTexture, edge, 0, 0, 0, 1)
    local bar = CreateFrame("StatusBar", nil, btn)
    try(bar.SetPoint, bar, "TOPLEFT", btn, "TOPLEFT", px, -px)
    try(bar.SetSize, bar, math.max(1, w - 2 * px), math.max(1, h - 2 * px))
    try(bar.SetStatusBarTexture, bar, SQUARE)
    try(bar.SetMinMaxValues, bar, 0, 1)
    local back = bar:CreateTexture(nil, "BACKGROUND")
    try(back.SetAllPoints, back, bar)
    try(back.SetColorTexture, back, left[1] * 0.15, left[2] * 0.15, left[3] * 0.15, 0.95)
    local fill = bar:GetStatusBarTexture()
    if fill then gradient(fill, left, right) end
    if db.barGlow and fill then
        -- Anchored to the fill's right edge, so it moves with the client's fill.
        local spark = bar:CreateTexture(nil, "OVERLAY")
        try(spark.SetTexture, spark, "Interface\\CastingBar\\UI-CastingBar-Spark")
        try(spark.SetBlendMode, spark, "ADD")
        try(spark.SetSize, spark, math.max(6, h * 1.6), math.max(8, h * 3))
        try(spark.SetPoint, spark, "CENTER", fill, "RIGHT", 0, 0)
        try(spark.SetVertexColor, spark, right[1], right[2], right[3], 1)
    end
    -- The client wants an icon; this one is never seen.
    local icon = btn:CreateTexture(nil, "ARTWORK")
    try(icon.SetSize, icon, 1, 1)
    try(icon.SetPoint, icon, "TOPLEFT", btn, "TOPLEFT", 0, 0)
    try(icon.SetAlpha, icon, 0)
    try(btn.SetIcon, btn, icon)
    local ok, err = try(btn.SetDurationBar, btn, bar, durationBarOptions())
    if not ok then p.barErr = "SetDurationBar: " .. tostring(err) end
    if btn.SetMouseMotionEnabled then try(btn.SetMouseMotionEnabled, btn, false) end
    if btn.EnableMouse then try(btn.EnableMouse, btn, false) end
end

local function buildContainer(p, unit, filter, ids)
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, p.barFrame, "CustomAuraContainerTemplate")
    if not ok or not c then p.barErr = "AuraContainer: " .. tostring(c); return end
    pcall(c.EnableMouse, c, false)
    pcall(c.SetAllPoints, c, p.barFrame)
    pcall(c.SetFlowLayoutAnchorPoint, c, "TOPLEFT")
    local fd = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    if type(fd) == "table" then pcall(c.SetFlowLayoutGrowthDirection, c, fd.Right, fd.Down) end
    pcall(c.SetFlowLayoutMaximumLineSize, c, p.barW)
    local SM, SD = _G.AuraContainerSortMethod, _G.AuraContainerSortDirection
    local opts = {
        candidateFilters = { includeSpellIDs = ids },
        maxFrameCount = 1,
        sortMethod = type(SM) == "table" and SM.ExpirationOnly or nil,
        sortDirection = type(SD) == "table" and SD.Normal or nil,
        layout = { layoutIndex = 1, elementWidth = p.barW, elementHeight = p.barH, elementSpacing = 0 },
        initializeFrame = function(btn) initBarButton(p, btn) end,
    }
    local ok2, err = pcall(c.AddAuraGroup, c, "a", filter, opts)
    if not ok2 then p.barErr = "AddAuraGroup: " .. tostring(err); return end
    pcall(c.SetUnit, c, unit)
    pcall(c.SetEnabled, c, true)
    c:Show()
    p.containers[#p.containers + 1] = { c = c, unit = unit }
end

local function dropContainers(p)
    for _, k in ipairs(p.containers or {}) do
        pcall(k.c.SetEnabled, k.c, false)
        k.c:Hide()
    end
    p.containers = {}
end

-- Builds the containers for the icon's current spell, or retargets them when the
-- game reused the icon for another spell. Out of combat only; waits otherwise.
local function setupBar(item, p)
    if db.bar == "off" then
        if p.barKey then dropContainers(p); p.barKey = nil end
        return
    end
    local ids, key, base = spellIDsOf(item)
    if not ids then p.barErr = "no spell ids for this icon"; return end
    p.base = base
    local size = p.barW .. "x" .. p.barH
    if p.barKey == key and p.barSize == size then return end
    if InCombatLockdown() then pending[item] = true; return end
    p.barErr = nil
    if p.barSize == size and p.containers and #p.containers > 0 then
        -- Same size, new spell: just swap the filter.
        local okAll = true
        for _, k in ipairs(p.containers) do
            if not pcall(k.c.SetAuraGroupCandidateFilters, k.c, "a", { includeSpellIDs = ids }) then okAll = false end
        end
        if okAll then p.barKey, p.ids = key, ids; return end
    end
    dropContainers(p)
    -- Your debuffs on the target, your HoTs and buffs on a friendly target, and the
    -- spell's buff on you. Targeting yourself, the last two show the same buff in
    -- the same spot.
    buildContainer(p, "target", "HARMFUL|PLAYER", ids)
    buildContainer(p, "target", "HELPFUL|PLAYER", ids)
    buildContainer(p, "player", "HELPFUL", ids)
    p.barKey, p.barSize, p.ids = key, size, ids
end

local function makeBar(item, p)
    local h = CreateFrame("Frame", nil, item)
    h:SetFrameLevel(item:GetFrameLevel() + 5)
    p.barFrame = h
    p.containers = {}
end

local function placeBar(item, p)
    local h = p.barFrame
    if not h then return end
    local px = pixels(item, 1)
    local w = item:GetWidth()
    if type(w) ~= "number" or secret(w) or w <= 0 then w = 36 end
    p.px, p.barW, p.barH = px, w, pixels(item, db.barHeight) + 2 * px
    h:ClearAllPoints()
    if db.bar == "bottom" then
        h:SetPoint("TOPLEFT", item, "BOTTOMLEFT", 0, -px)
    else
        h:SetPoint("BOTTOMLEFT", item, "TOPLEFT", 0, px)
    end
    h:SetSize(p.barW, p.barH)
    h:SetShown(db.bar ~= "off")
    setupBar(item, p)
end

local function retarget()
    for _, p in pairs(skins) do
        for _, k in ipairs(p.containers or {}) do
            if k.unit == "target" then
                pcall(k.c.SetUnit, k.c, "target")
                pcall(k.c.UpdateAllAuras, k.c)
            end
        end
    end
end

-- Swipe and border --------------------------------------------------------

local function paint(item)
    local p = skins[item]
    local cd = item.Cooldown
    if not p or p.isBar or type(cd) ~= "table" then return end
    guard = true
    if isActive(item, p) then
        if db.highlight then
            local r, g, b = accent()
            p.border:SetColorTexture(r, g, b, 1)
        else
            p.border:SetColorTexture(0, 0, 0, 1)
        end
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

-- Tracked Bars (BuffBarCooldownViewer) -----------------------------------
-- The game's bar items: an icon frame (item.Icon holding the Icon texture) and a
-- StatusBar the client fills itself (item.Bar, with Name and Duration texts). Kept
-- in the game's own size and spot; only their look changes. No hooks on the bar's
-- methods (hooking them broke the game's own calls in DaylightUI), so the look is
-- put back on every scan in case the game reset it.

local function isBarItem(item)
    local bar = item.Bar
    return type(bar) == "table" and bar.GetObjectType ~= nil and bar:GetObjectType() == "StatusBar"
end

local function barIconOf(item)
    local host = item.Icon
    local tex = type(host) == "table" and host.Icon
    if type(tex) == "table" and tex.GetObjectType and tex:GetObjectType() == "Texture" then return tex, host end
end

-- The game's art on the bar item: every texture but the icon, the fill and ours.
local function hideBarArt(item, p)
    for _, f in ipairs({ item, p.host, item.Bar }) do
        if type(f) == "table" and f.GetRegions then
            for _, r in ipairs({ f:GetRegions() }) do
                if r ~= p.icon and r ~= p.fill and not mine[r]
                    and r.GetObjectType and r:GetObjectType() == "Texture" then
                    r:SetAlpha(0)
                end
            end
        end
    end
    -- The debuff-type outline (blue for Magic, purple for Curse), on the item or its icon.
    for _, f in ipairs({ item, p.host }) do
        local rim = type(f) == "table" and f.DebuffBorder
        if type(rim) == "table" and rim.SetAlpha then rim:SetAlpha(0) end
    end
end

local function dressBar(item)
    local p = skins[item]
    local bar = item.Bar
    if not p or not bar then return end
    -- The game reuses its bars for other spells: colors follow the current one.
    local cid = plain(item.cooldownID)
    if cid ~= p.cid then
        p.cid = cid
        p.base = select(3, spellIDsOf(item))
    end
    -- Fill: our flat texture in the bar's gradient. Put back if the game swapped it.
    local fill = bar:GetStatusBarTexture()
    if fill ~= p.fill or (fill and fill:GetTexture() ~= p.fillTex) then
        pcall(bar.SetStatusBarTexture, bar, SQUARE)
        fill = bar:GetStatusBarTexture()
        p.fill, p.fillTex = fill, fill and fill:GetTexture()
        if p.spark and fill then
            p.spark:ClearAllPoints()
            p.spark:SetPoint("CENTER", fill, "RIGHT", 0, 0)
        end
    end
    local left, right = barColors(p)
    if fill then gradient(fill, left, right) end
    p.back:SetColorTexture(left[1] * 0.15, left[2] * 0.15, left[3] * 0.15, 0.95)
    if p.spark then
        p.spark:SetVertexColor(right[1], right[2], right[3], 1)
        p.spark:SetShown(db.barGlow and fill ~= nil)
    end
    hideBarArt(item, p)
    if not canLayout(item) then pending[item] = true; return end
    local b = pixels(item, db.border)
    -- Black edge around the bar, outside its fill.
    p.edge:ClearAllPoints()
    p.edge:SetPoint("TOPLEFT", bar, "TOPLEFT", -b, b)
    p.edge:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", b, -b)
    -- Square icon inside a black edge.
    if p.icon and p.host then
        p.icon:ClearAllPoints()
        p.icon:SetPoint("TOPLEFT", p.host, "TOPLEFT", b, -b)
        p.icon:SetPoint("BOTTOMRIGHT", p.host, "BOTTOMRIGHT", -b, b)
        p.icon:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)
    end
    local h = bar:GetHeight()
    if type(h) ~= "number" or secret(h) or h <= 0 then h = 18 end
    local size = math.max(9, math.floor(h * 0.6 + 0.5))
    styleFont(bar.Name, size)
    styleFont(bar.Duration, size)
    if p.spark then p.spark:SetSize(math.max(6, h * 0.8), h * 2.2) end
end

local function skinBar(item)
    local p = { isBar = true }
    skins[item] = p
    local icon, host = barIconOf(item)
    p.icon, p.host = icon, host
    if icon and icon.GetNumMaskTextures then
        for i = icon:GetNumMaskTextures(), 1, -1 do
            local m = icon:GetMaskTexture(i)
            if m then pcall(icon.RemoveMaskTexture, icon, m) end
        end
    end
    if host and host.CreateTexture then
        p.iconEdge = host:CreateTexture(nil, "BACKGROUND", nil, -8)
        p.iconEdge:SetAllPoints(host)
        p.iconEdge:SetColorTexture(0, 0, 0, 1)
        mine[p.iconEdge] = true
    end
    local bar = item.Bar
    p.edge = item:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.edge:SetColorTexture(0, 0, 0, 1)
    mine[p.edge] = true
    p.back = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.back:SetAllPoints(bar)
    mine[p.back] = true
    p.spark = bar:CreateTexture(nil, "OVERLAY", nil, 7)
    p.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    p.spark:SetBlendMode("ADD")
    mine[p.spark] = true
    item:HookScript("OnSizeChanged", function() dressBar(item) end)
    item:HookScript("OnShow", function() dressBar(item) end)
    dressBar(item)
end

local function refresh(item)
    local p = skins[item]
    if not p then return end
    if p.isBar then return dressBar(item) end
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
    for _, m in ipairs({ "SetCooldown", "SetCooldownFromDurationObject", "Clear" }) do
        if type(cd[m]) == "function" then
            hooksecurefunc(cd, m, function() if not guard then paint(item) end end)
        end
    end
end

local function skin(item)
    if type(item) ~= "table" or skins[item] then return end
    if isBarItem(item) then return skinBar(item) end
    local icon = item.Icon
    -- Icon views: the Icon is the texture itself.
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
            eachItem(v, function(item)
                if skins[item] then
                    -- The game may have reused this icon for another spell.
                    local p = skins[item]
                    if p.isBar then
                        if item:IsVisible() then dressBar(item) end
                    elseif p.barW and not InCombatLockdown() then
                        setupBar(item, p)
                    end
                else
                    skin(item)
                end
            end)
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

-- The bars' colors are set when the client makes their buttons, so a color change
-- builds them again (out of combat).
local function rebuildBars()
    for item, p in pairs(skins) do
        dropContainers(p)
        p.barKey, p.barSize = nil, nil
        refresh(item)
    end
end

SLASH_COOLDOWNSKIN1 = "/cskin"
SLASH_COOLDOWNSKIN2 = "/cooldownskin"
SlashCmdList.COOLDOWNSKIN = function(msg)
    local cmd, a, b, c = strsplit(" ", strtrim(msg or ""):lower())
    if cmd == "highlight" then
        db.highlight = not db.highlight
        say(db.highlight and "border while up: colored" or "border while up: black")
    elseif cmd == "color" and a == "class" then
        db.activeColor = "class"
        say("bar and highlight: class color")
        if not InCombatLockdown() then rebuildBars() end
        return refreshAll()
    elseif cmd == "color" then
        local col = parseColor(a, b, c)
        if not col then return say("usage: /cskin color class  or  /cskin color 150 80 230") end
        db.activeColor = col
        say("bar and highlight: custom color")
        if not InCombatLockdown() then rebuildBars() end
        return refreshAll()
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
    elseif cmd == "barcolor" and (a == "mix" or a == "class" or BAR_PALETTES[a]) then
        db.barColor = a
        say("timer bar colors: " .. a)
        if InCombatLockdown() then return say("shows after combat") end
        rebuildBars()
        return
    elseif cmd == "barcolor" then
        local names = {}
        for k in pairs(BAR_PALETTES) do names[#names + 1] = k end
        table.sort(names)
        return say("/cskin barcolor mix | class | " .. table.concat(names, " | "))
    elseif cmd == "barglow" then
        db.barGlow = not db.barGlow
        say(db.barGlow and "bar spark: on" or "bar spark: off")
        if InCombatLockdown() then return say("shows after combat") end
        rebuildBars()
        return
    elseif cmd == "barheight" and tonumber(a) then
        db.barHeight = math.max(1, math.min(12, math.floor(tonumber(a))))
        say("timer bar height: " .. db.barHeight .. " px")
    elseif cmd == "debug" then
        local n = 0
        for item, p in pairs(skins) do
            if item:IsVisible() then
                n = n + 1
                local ids = {}
                for s in pairs(p.ids or {}) do ids[#ids + 1] = s end
                table.sort(ids)
                local shown = 0
                for _, k in ipairs(p.containers or {}) do
                    for _, child in ipairs({ k.c:GetChildren() }) do
                        if child:IsShown() then shown = shown + 1 end
                    end
                end
                say(string.format("icon %d (cooldown %s): up=%s spells=%s containers=%d buttons made=%d shown=%d error=%s",
                    n, tostring(plain(item.cooldownID)), tostring(isActive(item, p)),
                    #ids > 0 and table.concat(ids, ",") or "none", #(p.containers or {}),
                    p.made or 0, shown, tostring(p.barErr)))
            end
        end
        say(string.format("%d icons shown, in combat=%s", n, tostring(InCombatLockdown())))
        return
    elseif cmd == "reset" then
        CooldownSkinDB = CopyTable(DEFAULTS)
        db = CooldownSkinDB
        db.v = 2
        say("settings reset")
        if not InCombatLockdown() then rebuildBars() end
    else
        say("/cskin highlight  - color the border while your debuff is up (on/off)")
        say("/cskin color class | color r g b  - color of the bar and highlight")
        say("/cskin reverse  - flip which way the debuff swipe runs")
        say("/cskin border 0-4  - border thickness in pixels")
        say("/cskin bar top | bottom | off  - timer bar while your debuff is up")
        say("/cskin barheight 1-12  - timer bar height in pixels")
        say("/cskin barcolor mix | class | neon | toxic | sunset | void | fel | ice")
        say("/cskin barglow  - spark at the bar's end (on/off)")
        say("/cskin text 0.2-0.8  - timer size")
        say("/cskin dark 0-1  - swipe darkness while up")
        say("/cskin debug  - why a timer bar isn't showing")
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
f:RegisterEvent("SPELLS_CHANGED")
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
    elseif event == "SPELLS_CHANGED" then
        -- A new rank learned: its id joins the icon's spells.
        rankMap = nil
        if not InCombatLockdown() then
            for item, p in pairs(skins) do
                if p.barW then p.barKey = nil; setupBar(item, p) end
            end
        end
    else
        if event == "PLAYER_TARGET_CHANGED" then retarget() end
        -- Target or aura changes: the game updates its icons, then we repaint.
        paintSoon()
    end
end)
