-- Fellowstep: Widgets
-- Every visual piece goes through here, built on Blizzard's own templates, fonts and
-- textures so it matches the game.
-- Templates are tried defensively: if a client lacks one we fall back instead of erroring.

local _, QM = ...

local UI = {}
QM.UI = UI

---------------------------------------------------------------------------
-- Palette
---------------------------------------------------------------------------
local C = {
    edge    = { 1, 1, 1, 0.09 },
    text    = { 0.91, 0.93, 0.95, 1 },
    muted   = { 0.60, 0.64, 0.70, 1 },
    dim     = { 0.45, 0.49, 0.55, 1 },
    blue    = { 0.35, 0.66, 1.00, 1 },
    green   = { 0.27, 0.76, 0.56, 1 },
    amber   = { 0.96, 0.73, 0.26, 1 },
    red     = { 0.94, 0.48, 0.42, 1 },
    purple  = { 0.79, 0.65, 1.00, 1 },
    gold    = { 1, 0.82, 0, 1 },
    white   = { 1, 1, 1, 1 },
    grey    = { 0.55, 0.55, 0.55, 1 },
    cellBg  = { 0.13, 0.10, 0.07, 0.95 },
    cellEdge = { 0.42, 0.31, 0.17, 1 },
}
UI.C = C

local function hex(c)
    return ("|cff%02x%02x%02x"):format(c[1] * 255, c[2] * 255, c[3] * 255)
end
UI.Hex = hex

---------------------------------------------------------------------------
-- Frame creation helpers
---------------------------------------------------------------------------

--- CreateFrame trying each template in turn; returns frame, templateUsed.
function UI.CreateFrame(frameType, name, parent, templates)
    for _, template in ipairs(templates or {}) do
        local ok, frame = pcall(CreateFrame, frameType, name, parent, template)
        if ok and frame then return frame, template end
        name = nil -- a failed attempt may have claimed the global name
    end
    return CreateFrame(frameType, nil, parent, "BackdropTemplate"), nil
end

function UI.Fill(frame, color, layer, sublevel)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
    t:SetAllPoints()
    t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return t
end

--- One-pixel edge made of four textures. Returns a table with :SetColor(r, g, b, a).
function UI.Border(frame, color, size)
    size = size or 1
    local e = {}
    local function edge(p1, p2, horizontal)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horizontal then t:SetHeight(size) else t:SetWidth(size) end
        e[#e + 1] = t
    end
    edge("TOPLEFT", "TOPRIGHT", true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)
    function e:SetColor(c)
        for _, t in ipairs(self) do t:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
    end
    e:SetColor(color)
    return e
end

--- A soft, beveled game border (the tooltip/panel edge art) tinted to color.
--- Returns a table with :SetColor(c) like UI.Border.
function UI.Bevel(frame, color, edgeSize)
    local target = frame
    if not target.SetBackdrop then
        if BackdropTemplateMixin and Mixin then
            Mixin(target, BackdropTemplateMixin)
            if target.HookScript and target.OnBackdropSizeChanged then
                target:HookScript("OnSizeChanged", target.OnBackdropSizeChanged)
            end
        else
            -- older clients: draw the edge on a child frame laid over this one
            target = CreateFrame("Frame", nil, frame, "BackdropTemplate")
            target:SetAllPoints()
        end
    end
    local ok = target.SetBackdrop and pcall(target.SetBackdrop, target, {
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = edgeSize or 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    if not ok then return UI.Border(frame, color) end
    local e = {}
    function e:SetColor(c)
        target:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
    end
    e:SetColor(color)
    return e
end

--- A box with the same recessed border as the window's inset panels (InsetFrameTemplate).
--- Falls back to UI.Bevel if the template is missing.
--- Returns the frame; content drawn on it should stay a few pixels in from the edges.
function UI.InsetBox(frameType, parent, fillColor)
    local f, template = UI.CreateFrame(frameType, nil, parent, { "InsetFrameTemplate" })
    if not template then
        UI.InsideBevel(UI.Fill(f, { 0, 0, 0, 0.6 }))
        f.edge = UI.Bevel(f, { 0.80, 0.65, 0.40, 1 })
    end
    return f
end

--- Inset a texture so it sits inside a UI.Bevel edge (no square corners poking out).
function UI.InsideBevel(texture, pad)
    pad = pad or 3
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", pad, -pad)
    texture:SetPoint("BOTTOMRIGHT", -pad, pad)
    return texture
end

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------
local function nativeFont(...)
    for i = 1, select("#", ...) do
        local f = _G[(select(i, ...))]
        if f then return f end
    end
    return GameFontNormal
end

-- role -> the game font used for it
local FONT_ROLES = {
    title   = { "GameFontNormalLarge" },
    header  = { "ObjectiveTrackerHeaderFont", "GameFontNormalMed2", "GameFontNormal" },
    name    = { "GameFontNormal" },
    quest   = { "ObjectiveTrackerLineFont", "GameFontNormal" },
    body    = { "GameFontHighlight" },
    small   = { "GameFontHighlightSmall" },
    muted   = { "GameFontDisableSmall" },
    gold    = { "GameFontNormalSmall" },
    red     = { "GameFontRedSmall" },
    label   = { "GameFontDisableSmall" },
    button  = { "GameFontNormal" },
}

function UI.Font(role)
    return nativeFont(unpack(FONT_ROLES[role] or FONT_ROLES.body))
end

function UI.Text(parent, role, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFontObject(UI.Font(role))
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

--- Color for quest titles.
function UI.QuestTitleColor()
    return C.gold
end

---------------------------------------------------------------------------
-- Textures and status marks
---------------------------------------------------------------------------
local function atlasExists(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

--- Point a texture at the first atlas or file that exists. Returns true on success.
function UI.SetTextureFrom(texture, candidates)
    for _, c in ipairs(candidates) do
        if c.atlas and atlasExists(c.atlas) then
            texture:SetAtlas(c.atlas)
            return true
        elseif c.file then
            texture:SetTexture(c.file)
            if texture:GetTexture() then
                texture:SetTexCoord(0, 1, 0, 1)
                return true
            end
        end
    end
    return false
end

-- glyph fallback, game texture candidates
local ICONS = {
    AVAILABLE = { glyph = "!", color = C.amber, solid = true, candidates = {
        { atlas = "QuestNormal" }, { file = "Interface\\GossipFrame\\AvailableQuestIcon" } } },
    READY = { glyph = "?", color = C.amber, candidates = {
        { atlas = "QuestTurnin" }, { file = "Interface\\GossipFrame\\ActiveQuestIcon" } } },
    ACTIVE = { glyph = "•", color = C.blue, candidates = {
        { atlas = "Quest-In-Progress-Icon-yellow" }, { atlas = "QuestActive" }, { file = "Interface\\GossipFrame\\IncompleteQuestIcon" } } },
    DONE = { glyph = "v", color = C.green, candidates = {
        { atlas = "common-icon-checkmark-yellow" }, { atlas = "common-icon-checkmark" }, { file = "Interface\\RaidFrame\\ReadyCheck-Ready" } } },
    MISSING = { glyph = "!", color = C.red, candidates = {
        { file = "Interface\\RaidFrame\\ReadyCheck-NotReady" } } },
    UNKNOWN = { glyph = "–", color = C.dim, candidates = {
        { file = "Interface\\RaidFrame\\ReadyCheck-Waiting" } } },
    LEVEL = { glyph = "Lv", color = C.red, candidates = {} },
    BLOCKED = { glyph = "…", color = C.dim, candidates = {} },
    THEIRS = { glyph = "+", color = C.purple, candidates = {} },
}
UI.ICONS = ICONS

--- A small icon showing a quest status mark.
function UI.StatusIcon(parent, size)
    size = size or 16
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.chip = f:CreateTexture(nil, "BACKGROUND")
    f.chip:SetAllPoints()
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.glyph = f:CreateFontString(nil, "OVERLAY")
    f.glyph:SetPoint("CENTER", 0, 0)
    f.glyph:SetFont(STANDARD_TEXT_FONT, math.floor(size * 0.72), "OUTLINE")
    function f:SetKind(kind)
        local def = ICONS[kind]
        if not def then self:Hide() return end
        self:Show()
        self.tex:SetDesaturated(false)
        self.tex:SetAlpha(1)
        if UI.SetTextureFrom(self.tex, def.candidates) then
            self.tex:SetVertexColor(1, 1, 1)
            self.chip:Hide()
            self.tex:Show()
            self.glyph:Hide()
        else
            self.chip:Hide()
            self.tex:Hide()
            self.glyph:SetText(def.glyph)
            local c = (kind == "LEVEL" or kind == "MISSING") and C.red or ((kind == "BLOCKED" or kind == "UNKNOWN") and C.grey or C.gold)
            self.glyph:SetTextColor(c[1], c[2], c[3])
            self.glyph:Show()
        end
    end
    function f:SetDimmed(dim)
        local a = dim and 0.5 or 1
        self.tex:SetDesaturated(dim and true or false)
        self.tex:SetAlpha(a)
        self.glyph:SetAlpha(a)
        self.chip:SetAlpha(a)
    end
    return f
end

--- Color used for a status in the chain list's little progress bars.
local SEGMENT = {
    DONE = C.green, ACTIVE = C.blue, READY = C.amber, AVAILABLE = C.amber,
    LEVEL = C.red, BLOCKED = { 1, 1, 1, 0.12 }, OTHER = { 1, 1, 1, 0.12 }, SKIPPED = { 1, 1, 1, 0.12 },
    CLASS = { 1, 1, 1, 0.06 }, UNKNOWN = { 1, 1, 1, 0.05 },
}
function UI.SegmentColor(status)
    return SEGMENT[status] or SEGMENT.UNKNOWN
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------

--- A standard red game button.
function UI.Button(parent, text, width, height)
    width, height = width or 110, height or 22
    local b = UI.CreateFrame("Button", nil, parent, { "UIPanelButtonTemplate" })
    b:SetSize(width, height)
    b:SetText(text)
    return b
end

--- The window close button.
function UI.CloseButton(parent, onClick)
    local b
    b = UI.CreateFrame("Button", nil, parent, { "UIPanelCloseButton" })
    b:SetScript("OnClick", onClick or function() parent:Hide() end)
    return b
end

--- A small square icon button (used for the gear).
function UI.IconButton(parent, texture, size, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 22, size or 22)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexture(texture)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    if tooltip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end

--- A checkbox with a label. get() returns the value, set(v) stores it.
function UI.Check(parent, label, get, set, tip)
    local b
    b = UI.CreateFrame("CheckButton", nil, parent, { "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate" })
    b:SetSize(26, 26)
    b.label = UI.Text(b, "body")
    b.label:SetPoint("LEFT", b, "RIGHT", 6, 0)
    b.label:SetText(label)
    if type(b.text) == "table" and b.text.SetText then b.text:SetText("") end
    if type(b.Text) == "table" and b.Text.SetText then b.Text:SetText("") end
    b:SetScript("OnShow", function(self) self:SetChecked(get() and true or false) end)
    b:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    if tip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    b:SetChecked(get() and true or false)
    return b
end

--- A "- value +" stepper for numbers.
function UI.Stepper(parent, label, get, set, minValue, maxValue, step, format)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(320, 26)
    f.label = UI.Text(f, "body")
    f.label:SetPoint("LEFT", 0, 0)
    f.label:SetText(label)
    f.minus = UI.Button(f, "-", 26, 22)
    f.minus:SetPoint("LEFT", 190, 0)
    f.value = UI.Text(f, "body")
    f.value:SetPoint("LEFT", f.minus, "RIGHT", 4, 0)
    f.value:SetWidth(64)
    f.value:SetJustifyH("CENTER")
    f.plus = UI.Button(f, "+", 26, 22)
    f.plus:SetPoint("LEFT", f.value, "RIGHT", 4, 0)
    local function show() f.value:SetText((format or "%d"):format(get())) end
    f.minus:SetScript("OnClick", function() set(math.max(minValue, get() - step)); show() end)
    f.plus:SetScript("OnClick", function() set(math.min(maxValue, get() + step)); show() end)
    f:SetScript("OnShow", show)
    show()
    return f
end

---------------------------------------------------------------------------
-- Panels and windows
---------------------------------------------------------------------------

--- A recessed box inside a window.
function UI.Inset(parent)
    return (UI.CreateFrame("Frame", nil, parent, { "InsetFrameTemplate" }))
end

--- A small floating panel (alerts, popups).
function UI.Panel(parent, name)
    local f = UI.CreateFrame("Frame", name, parent or UIParent, { "TooltipBackdropTemplate", "BackdropTemplate" })
    if f.SetBackdrop and not f.NineSlice then
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0.06, 0.05, 0.04, 0.95)
    end
    return f
end

--- A main window with title, close button and a content inset (f.Inset).
function UI.Window(name, title, width, height, portrait)
    local f
    local template
    f, template = UI.CreateFrame("Frame", name, UIParent, { "ButtonFrameTemplate", "PortraitFrameTemplate" })
    if f.SetTitle then f:SetTitle(title) elseif f.TitleText then f.TitleText:SetText(title) end
    if portrait then
        if f.SetPortraitToAsset then
            pcall(f.SetPortraitToAsset, f, portrait)
        elseif f.PortraitContainer and f.PortraitContainer.portrait then
            f.PortraitContainer.portrait:SetTexture(portrait)
        end
    end
    if not template then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
        f.TitleText = UI.Text(f, "name")
        f.TitleText:SetPoint("TOP", 0, -10)
        f.TitleText:SetText(title)
        local close = UI.CloseButton(f)
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    if not f.Inset then
        f.Inset = UI.Inset(f)
        f.Inset:SetPoint("TOPLEFT", 10, -60)
        f.Inset:SetPoint("BOTTOMRIGHT", -10, 30)
    end
    f:SetSize(width, height)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.OnMoved then self:OnMoved() end
    end)
    f:Hide()
    if name then tinsert(UISpecialFrames, name) end -- Escape closes it
    return f
end

--- Section header bar like the objective tracker's "Quests" bar.
function UI.HeaderBar(target)
    -- borrow the texture the live tracker header uses, so it matches the game's skin
    local sources = {}
    local function addSource(f) if f and f.GetRegions then sources[#sources + 1] = f end end
    if _G.QuestObjectiveTracker then addSource(_G.QuestObjectiveTracker.Header) end
    if _G.ObjectiveTrackerFrame then addSource(_G.ObjectiveTrackerFrame.Header) end
    if _G.ObjectiveTrackerBlocksFrame then addSource(_G.ObjectiveTrackerBlocksFrame.QuestHeader) end
    for _, source in ipairs(sources) do
        local best, bestWidth
        for _, region in ipairs({ source:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "Texture" then
                local w = region:GetWidth() or 0
                if (region:GetAtlas() or region:GetTexture()) and (not bestWidth or w > bestWidth) then
                    best, bestWidth = region, w
                end
            end
        end
        if best then
            local tex = target:CreateTexture(nil, "BACKGROUND")
            tex:SetAllPoints()
            local atlas = best:GetAtlas()
            if atlas then
                tex:SetAtlas(atlas)
            else
                tex:SetTexture(best:GetTexture())
                tex:SetTexCoord(best:GetTexCoord())
            end
            tex:SetVertexColor(best:GetVertexColor())
            return
        end
    end
    UI.Fill(target, { 0.16, 0.12, 0.08, 0.9 })
    local line = target:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(0.55, 0.42, 0.24, 1)
end

---------------------------------------------------------------------------
-- Grid cells: a fill and edge tinted by status so cells stand out from the window
---------------------------------------------------------------------------
local CELL_LOOK = {
        DONE      = { fill = { 0.10, 0.16, 0.08, 0.95 }, edge = { 0.55, 0.45, 0.30, 1 } },
        ACTIVE    = { fill = { 0.16, 0.12, 0.07, 0.95 }, edge = { 0.80, 0.65, 0.40, 1 } },
        READY     = { fill = { 0.22, 0.16, 0.06, 0.95 }, edge = { 1.00, 0.82, 0.35, 1 } },
        AVAILABLE = { fill = { 0.26, 0.18, 0.05, 0.95 }, edge = { 1.00, 0.86, 0.10, 1 } },
        LEVEL     = { fill = { 0.18, 0.07, 0.06, 0.95 }, edge = { 0.75, 0.30, 0.22, 1 } },
        SPOILER   = { fill = { 0.06, 0.05, 0.05, 0.80 }, edge = { 0.40, 0.36, 0.32, 1 } },
        default   = { fill = { 0.08, 0.07, 0.06, 0.85 }, edge = { 0.45, 0.40, 0.34, 1 } },
}

function UI.CellBackground(cell)
    cell.fill = cell:CreateTexture(nil, "BACKGROUND")
    UI.InsideBevel(cell.fill)
    cell.edge = UI.Bevel(cell, C.edge)
end

function UI.PaintCell(cell, status)
    local look = CELL_LOOK[status] or CELL_LOOK.default
    cell.fill:SetColorTexture(look.fill[1], look.fill[2], look.fill[3], look.fill[4])
    cell.edge:SetColor(look.edge)
end

---------------------------------------------------------------------------
-- Actions shared by duo and matrix
---------------------------------------------------------------------------

--- Put a native map waypoint on the step's quest giver and track it.
function UI.SetWaypoint(loc)
    if not loc or not loc.uiMapID or not loc.x then
        QM:Print("I don't know where that quest starts.")
        return false
    end
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(loc.uiMapID) then
        QM:Print("the game doesn't allow waypoints on that map.")
        return false
    end
    local point = UiMapPoint.CreateFromCoordinates(loc.uiMapID, loc.x / 100, loc.y / 100)
    C_Map.SetUserWaypoint(point)
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
    return true
end

--- Tell the party something, with a clickable map pin when possible.
function UI.TellParty(text, loc)
    local message = "[Fellowstep] " .. text
    if loc and UI.SetWaypoint(loc) and C_Map.GetUserWaypointHyperlink then
        local link = C_Map.GetUserWaypointHyperlink()
        if link then message = message .. " " .. link end
    elseif loc and loc.x then
        message = message .. (" (%.1f, %.1f)"):format(loc.x, loc.y)
    end
    local channel = IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or (IsInRaid() and "RAID") or (IsInGroup() and "PARTY")
    if not channel or (QM.Test and QM.Test:IsOn()) then
        -- solo, or test mode (pretend names shouldn't reach real party chat): only you see it
        QM:Print(message .. (channel and " |cff888888(test mode: only you see this)|r" or ""))
        return
    end
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        C_ChatInfo.SendChatMessage(message, channel)
    else
        SendChatMessage(message, channel)
    end
end

--- Share a quest you have with the party (must be called from a click).
function UI.ShareQuest(questID)
    if C_QuestLog.IsPushableQuest and not C_QuestLog.IsPushableQuest(questID) then
        QM:Print("that quest can't be shared. The quest giver is marked on your map instead.")
        return false
    end
    if QM.Test and QM.Test:IsOn() then
        QM:Print("test mode: pretending to share the quest.")
    end
    C_QuestLog.SetSelectedQuest(questID)
    QuestLogPushQuest()
    return true
end
