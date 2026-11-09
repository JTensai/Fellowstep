-- Fellowstep: Matrix
-- The "Fellowstep" window. Left (collapsible): every chain the group is on, each with a
-- little progress bar per player. Right: the selected chain drawn as a tree, top to bottom,
-- with a small class icon (or portrait) on each quest showing who is on it.

local _, QM = ...
local UI = QM.UI
local S = QM.Chains.S

local Matrix = {}
QM.Matrix = Matrix

local WIDTH, HEIGHT = 1000, 600
local LIST_WIDTH = 250
local NODE_W, NODE_H = 196, 46
local GAP_X, GAP_Y = 26, 40
local PAD = 24
local HUD_TOP = 8     -- room for the "earlier quests" pill at the top of the scrolling tree
local HEAD = 46       -- header band above the panels: chain title, legend, collapse button
local HUD_BOTTOM = 28 -- fixed catch-up line over the bottom
local AVATAR = 22

local OTHER_CLASS = "Not for your class"
local pinnedChain -- a chain opened from elsewhere that nobody in the group is on yet
local frame, list, tree, detail
local selectedKey
local chains = {}

---------------------------------------------------------------------------
-- Status presentation
---------------------------------------------------------------------------
local LOOK = {
    [S.DONE]      = { icon = "DONE",      label = "Completed" },
    [S.ACTIVE]    = { icon = "ACTIVE",    label = "In progress" },
    [S.READY]     = { icon = "READY",     label = "Ready to turn in" },
    [S.AVAILABLE] = { icon = "AVAILABLE", label = "Can pick it up" },
    [S.LEVEL]     = { icon = "LEVEL",     label = "Needs level %d" },
    [S.BLOCKED]   = { icon = "BLOCKED",   label = "Not unlocked yet" },
    [S.OTHER]     = { icon = nil,         label = "Took the other option" },
    [S.SKIPPED]   = { icon = nil,         label = "Skipped (optional)" },
    [S.CLASS]     = { icon = nil,         label = "For another class" },
    [S.UNKNOWN]   = { icon = "UNKNOWN",   label = "Unknown" },
}

local function statusLabel(status, info)
    local look = LOOK[status] or LOOK[S.UNKNOWN]
    if status == S.LEVEL then return look.label:format(info and info.level or 0) end
    if status == S.BLOCKED and info and info.missingName then return "Needs " .. info.missingName .. " first" end
    return look.label
end

local function objectiveSummary(quest)
    if not quest or not quest.objectives then return nil end
    local parts = {}
    for _, o in ipairs(quest.objectives) do
        if o.need and o.need > 0 then parts[#parts + 1] = o.have .. "/" .. o.need end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "  ")
end

local function isFinished(status)
    return status == S.DONE or status == S.SKIPPED or status == S.OTHER or status == S.CLASS
end

local function isOnIt(status)
    return status == S.ACTIVE or status == S.READY
end

local function memberName(m)
    return m.isPlayer and "You" or QM.ShortName(m.name)
end

local function classColor(m)
    local classFile = QM.Party:ClassFile(m)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function coloredName(m)
    local r, g, b = classColor(m)
    return ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, memberName(m))
end

---------------------------------------------------------------------------
-- Cursor helpers
---------------------------------------------------------------------------
local function cursor()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    return x / scale, y / scale
end

---------------------------------------------------------------------------
-- Vertical list scroller (chain list)
---------------------------------------------------------------------------
local function makeListScroller(parent)
    local s = CreateFrame("ScrollFrame", nil, parent)
    s.child = CreateFrame("Frame", nil, s)
    s.child:SetSize(10, 10)
    s:SetScrollChild(s.child)
    s.pos, s.target = 0, 0
    s.track = s:CreateTexture(nil, "OVERLAY")
    s.thumb = s:CreateTexture(nil, "OVERLAY", nil, 1)
    local tc = { 1, 0.82, 0, 0.45 }
    s.track:SetColorTexture(1, 1, 1, 0.06)
    s.thumb:SetColorTexture(tc[1], tc[2], tc[3], tc[4])
    s.track:SetPoint("TOPRIGHT", 6, 0)
    s.track:SetPoint("BOTTOMRIGHT", 6, 0)
    s.track:SetWidth(3)
    s.thumb:SetWidth(3)

    function s:Range() return math.max(0, self.child:GetHeight() - self:GetHeight()) end
    function s:Apply(value)
        local range = self:Range()
        value = math.max(0, math.min(range, value))
        self.pos = value
        self:SetVerticalScroll(value)
        local visible = self:GetHeight()
        if range <= 0 or visible <= 0 then self.track:Hide(); self.thumb:Hide() return end
        self.track:Show(); self.thumb:Show()
        local size = math.max(20, visible * visible / (visible + range))
        self.thumb:SetHeight(size)
        self.thumb:ClearAllPoints()
        self.thumb:SetPoint("TOP", self.track, "TOP", 0, -(visible - size) * (value / range))
    end
    function s:ScrollTo(value, instant)
        self.target = math.max(0, math.min(self:Range(), value))
        if instant then self:Apply(self.target) end
    end
    function s:BeginDrag()
        local _, y = cursor()
        self.drag = { start = y, from = self.pos, moved = false }
    end
    function s:EndDrag()
        local moved = self.drag and self.drag.moved
        self.drag = nil
        return moved
    end
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta) self:ScrollTo(self.target - delta * 60) end)
    s:EnableMouse(true)
    s:SetScript("OnMouseDown", function(self) self:BeginDrag() end)
    s:SetScript("OnMouseUp", function(self) self:EndDrag() end)
    s:SetScript("OnUpdate", function(self, elapsed)
        if self.drag then
            if not IsMouseButtonDown("LeftButton") then self.drag = nil return end
            local _, y = cursor()
            local delta = y - self.drag.start
            if math.abs(delta) > 4 then self.drag.moved = true end
            self.target = math.max(0, math.min(self:Range(), self.drag.from + delta))
            self:Apply(self.target)
        elseif math.abs(self.target - self.pos) > 0.5 then
            self:Apply(self.pos + (self.target - self.pos) * math.min(1, elapsed * 14))
        end
    end)
    return s
end

---------------------------------------------------------------------------
-- Two-axis panning viewport (the tree). Drag to pan, wheel scrolls down,
-- Shift + wheel scrolls sideways. Edges fade where there's more to see.
---------------------------------------------------------------------------
local function setGradient(tex, orientation, fromAlpha, toAlpha)
    tex:SetColorTexture(1, 1, 1, 1)
    local ok = CreateColor and pcall(tex.SetGradient, tex, orientation,
        CreateColor(0, 0, 0, fromAlpha), CreateColor(0, 0, 0, toAlpha))
    if not ok then
        tex:SetColorTexture(0, 0, 0, math.max(fromAlpha, toAlpha) * 0.5)
    end
end

local function makeViewport(parent)
    local v = CreateFrame("ScrollFrame", nil, parent)
    v.child = CreateFrame("Frame", nil, v)
    v.child:SetSize(10, 10)
    v:SetScrollChild(v.child)
    v.x, v.y, v.tx, v.ty = 0, 0, 0, 0
    if v.SetClipsChildren then v:SetClipsChildren(true) end

    -- fades sit in a frame above the content so they cover it
    local over = CreateFrame("Frame", nil, parent)
    over:SetAllPoints(v)
    over:SetFrameLevel(v:GetFrameLevel() + 20)
    v.over = over
    local F = 22
    v.fadeTop = over:CreateTexture(nil, "OVERLAY")
    v.fadeTop:SetPoint("TOPLEFT"); v.fadeTop:SetPoint("TOPRIGHT"); v.fadeTop:SetHeight(F)
    setGradient(v.fadeTop, "VERTICAL", 0, 0.75)
    v.fadeBottom = over:CreateTexture(nil, "OVERLAY")
    v.fadeBottom:SetPoint("BOTTOMLEFT"); v.fadeBottom:SetPoint("BOTTOMRIGHT"); v.fadeBottom:SetHeight(F)
    setGradient(v.fadeBottom, "VERTICAL", 0.75, 0)
    v.fadeLeft = over:CreateTexture(nil, "OVERLAY")
    v.fadeLeft:SetPoint("TOPLEFT"); v.fadeLeft:SetPoint("BOTTOMLEFT"); v.fadeLeft:SetWidth(F)
    setGradient(v.fadeLeft, "HORIZONTAL", 0.75, 0)
    v.fadeRight = over:CreateTexture(nil, "OVERLAY")
    v.fadeRight:SetPoint("TOPRIGHT"); v.fadeRight:SetPoint("BOTTOMRIGHT"); v.fadeRight:SetWidth(F)
    setGradient(v.fadeRight, "HORIZONTAL", 0, 0.75)

    function v:RangeX() return math.max(0, self.child:GetWidth() - self:GetWidth()) end
    function v:RangeY() return math.max(0, self.child:GetHeight() - self:GetHeight()) end
    function v:Apply(x, y)
        local rx, ry = self:RangeX(), self:RangeY()
        x = math.max(0, math.min(rx, x))
        y = math.max(0, math.min(ry, y))
        self.x, self.y = x, y
        self:SetHorizontalScroll(x)
        self:SetVerticalScroll(y)
        self.fadeLeft:SetShown(x > 1)
        self.fadeRight:SetShown(x < rx - 1)
        self.fadeTop:SetShown(y > 1)
        self.fadeBottom:SetShown(y < ry - 1)
        if self.OnMoved then self:OnMoved() end
    end
    function v:ScrollTo(x, y, instant)
        self.tx = math.max(0, math.min(self:RangeX(), x))
        self.ty = math.max(0, math.min(self:RangeY(), y))
        if instant then self:Apply(self.tx, self.ty) end
    end
    function v:BeginDrag()
        local cx, cy = cursor()
        self.drag = { cx = cx, cy = cy, x = self.x, y = self.y, moved = false }
    end
    function v:EndDrag()
        local moved = self.drag and self.drag.moved
        self.drag = nil
        return moved
    end
    v:EnableMouseWheel(true)
    v:SetScript("OnMouseWheel", function(self, delta)
        if self.OnWheel then self:OnWheel() end
        if IsShiftKeyDown() then
            self:ScrollTo(self.tx - delta * 90, self.ty)
        else
            self:ScrollTo(self.tx, self.ty - delta * 70)
        end
    end)
    v:EnableMouse(true)
    v:SetScript("OnMouseDown", function(self) self:BeginDrag() end)
    v:SetScript("OnMouseUp", function(self) self:EndDrag() end)
    v:SetScript("OnUpdate", function(self, elapsed)
        if self.drag then
            if not IsMouseButtonDown("LeftButton") then self.drag = nil return end
            local cx, cy = cursor()
            local dx, dy = cx - self.drag.cx, cy - self.drag.cy
            if math.abs(dx) + math.abs(dy) > 4 then self.drag.moved = true end
            self.tx = math.max(0, math.min(self:RangeX(), self.drag.x - dx))
            self.ty = math.max(0, math.min(self:RangeY(), self.drag.y + dy))
            self:Apply(self.tx, self.ty)
        elseif math.abs(self.tx - self.x) > 0.5 or math.abs(self.ty - self.y) > 0.5 then
            local k = math.min(1, elapsed * 14)
            self:Apply(self.x + (self.tx - self.x) * k, self.y + (self.ty - self.y) * k)
        end
    end)
    return v
end

---------------------------------------------------------------------------
-- Avatars: class icon (or portrait) in a status-colored ring
---------------------------------------------------------------------------
local RING = {
    ACTIVE = { 0.35, 0.66, 1.00 },
    READY = { 1.00, 0.82, 0.00 },
    NEXT = { 0.55, 0.55, 0.55 },
}

local function circleMask(frame, texture)
    if not frame.CreateMaskTexture then return end
    local mask = frame:CreateMaskTexture()
    mask:SetAllPoints(texture)
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    texture:AddMaskTexture(mask)
end

local function createAvatar(parent)
    local a = CreateFrame("Button", nil, parent)
    a:SetSize(AVATAR, AVATAR)
    a.ring = a:CreateTexture(nil, "ARTWORK")
    a.ring:SetAllPoints()
    a.ring:SetColorTexture(1, 1, 1, 1)
    circleMask(a, a.ring)
    a.icon = a:CreateTexture(nil, "ARTWORK", nil, 1)
    a.icon:SetPoint("TOPLEFT", 2, -2)
    a.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    circleMask(a, a.icon)
    a:SetScript("OnEnter", function(self)
        if not self.member then return end
        local m = self.member
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(m.isPlayer and (QM.ShortName(m.name) .. " (you)") or QM.ShortName(m.name), classColor(m))
        local level = QM.Party:Level(m)
        local extra = m.fake and " · pretend player" or (not QM.Party:HasAddon(m) and " · no Fellowstep" or "")
        GameTooltip:AddLine(("Level %d%s"):format(level, extra), 0.8, 0.8, 0.8)
        GameTooltip:AddLine(self.text or "", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    a:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- let clicks and drags fall through to the node
    a:SetScript("OnMouseDown", function(self) if self:GetParent().OnMouseDownPass then self:GetParent():OnMouseDownPass() end end)
    a:SetScript("OnClick", function(self) local n = self:GetParent(); if n.OnClickPass then n:OnClickPass() end end)
    return a
end

local function paintAvatar(a, m, kind)
    a.member = m
    local c = RING[kind] or RING.NEXT
    a.ring:SetVertexColor(c[1], c[2], c[3], 1)
    local unit = m.unit
    if QM.char.portraits and unit and not m.fake and UnitExists and UnitExists(unit) and SetPortraitTexture then
        SetPortraitTexture(a.icon, unit)
        a.icon:SetTexCoord(0, 1, 0, 1)
    else
        local classFile = QM.Party:ClassFile(m)
        local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
        if coords then
            a.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
            a.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        elseif classFile then
            a.icon:SetTexture("Interface\\Icons\\ClassIcon_" .. classFile:sub(1, 1) .. classFile:sub(2):lower())
            a.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            a.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            a.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
    local faded = kind == "NEXT"
    a.icon:SetDesaturated(faded)
    a:SetAlpha(faded and 0.7 or 1)
end

---------------------------------------------------------------------------
-- Detail popup (opens when you click a quest)
---------------------------------------------------------------------------
local function buttonTip(button, title, text)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tipTitle or title, 1, 1, 1)
        GameTooltip:AddLine(self.tipText or text, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function createDetail()
    detail = UI.Panel(frame, "FellowstepStepDetail")
    detail:SetSize(300, 200)
    detail:SetFrameStrata("DIALOG")
    detail:EnableMouse(true)
    detail.title = UI.Text(detail, "name")
    detail.title:SetPoint("TOPLEFT", 14, -14)
    detail.title:SetPoint("RIGHT", -32, 0)
    detail.meta = UI.Text(detail, "muted")
    detail.meta:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
    detail.meta:SetPoint("RIGHT", -14, 0)
    detail.body = UI.Text(detail, "small")
    detail.body:SetPoint("TOPLEFT", detail.meta, "BOTTOMLEFT", 0, -8)
    detail.body:SetPoint("RIGHT", -14, 0)
    detail.body:SetWordWrap(true)
    detail.body:SetJustifyV("TOP")
    detail.body:SetSpacing(3)

    detail.waypoint = UI.Button(detail, "Mark Quest Giver on Map", 272, 22, "primary")
    buttonTip(detail.waypoint, "Mark Quest Giver on Map",
        "Puts a map pin on the person who gives this quest and turns on the arrow that points you there.")
    detail.tell = UI.Button(detail, "Tell Party Where to Get It", 272, 22)
    buttonTip(detail.tell, "Tell Party Where to Get It",
        "Posts the quest giver's name and a clickable map pin in party chat.")
    detail.share = UI.Button(detail, "Share Quest with Party", 272, 22)
    buttonTip(detail.share, "Share Quest with Party",
        "Offers your copy of this quest to everyone in the group who can take it, like the Share button in your quest log.")
    detail.close = UI.CloseButton(detail)
    detail.close:SetPoint("TOPRIGHT", 0, 0)
    detail:Hide()

    -- close when you click anywhere else
    QM:RegisterEvent("GLOBAL_MOUSE_DOWN", function()
        if not detail:IsShown() then return end
        if detail:IsMouseOver() then return end
        if detail.anchor and detail.anchor:IsMouseOver() then return end
        detail:Hide()
    end)
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------
local function applyCollapse()
    local collapsed = QM.char.listCollapsed
    list:SetShown(not collapsed)
    tree:ClearAllPoints()
    local top = -62
    -- the tree panel starts HEAD lower than the list, leaving room for its title row above it
    if collapsed then
        tree:SetPoint("TOPLEFT", 10, top - HEAD)
    else
        tree:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, -HEAD)
    end
    tree:SetPoint("BOTTOMRIGHT", -10, 34)
    tree.collapse:SetText(collapsed and ">>" or "<<")
end

local function createFrame()
    frame = UI.Window("FellowstepFrame", "Fellowstep", WIDTH, HEIGHT, "Interface\\AddOns\\Fellowstep\\Media\\IconRound256")
    frame.OnMoved = function(self)
        local point, _, relPoint, x, y = self:GetPoint(1)
        QM.char.matrixPoint = { point, relPoint, x, y }
    end
    local p = QM.char.matrixPoint
    if p then frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else frame:SetPoint("CENTER") end
    frame:SetScript("OnHide", function() if detail then detail:Hide() end end)

    local top = -62

    frame.gear = UI.IconButton(frame, "Interface\\Buttons\\UI-OptionsButton", 18, "Fellowstep settings")
    frame.gear:SetPoint("TOPRIGHT", -30, -3)
    frame.gear:SetFrameLevel(frame:GetFrameLevel() + 10)
    frame.gear:SetScript("OnClick", function() QM:Fire("QM_OPEN_SETTINGS") end)

    -- left: chain list
    list = UI.Inset(frame)
    list:SetPoint("TOPLEFT", 10, top)
    list:SetPoint("BOTTOMLEFT", 10, 34)
    list:SetWidth(LIST_WIDTH)
    list.label = UI.Text(list, "header")
    list.label:SetPoint("TOPLEFT", 12, -10)
    list.label:SetText("Party Quest Chains")
    list.label:SetTextColor(1, 0.82, 0)
    list.labelLine = list:CreateTexture(nil, "ARTWORK")
    list.labelLine:SetPoint("TOPLEFT", 8, -30)
    list.labelLine:SetPoint("TOPRIGHT", -8, -30)
    list.labelLine:SetHeight(1)
    list.labelLine:SetColorTexture(1, 0.82, 0, 0.3)
    -- search: filters the list by chain or quest name
    local ok, box = pcall(CreateFrame, "EditBox", "FellowstepSearchBox", list, "SearchBoxTemplate")
    if not ok then box = CreateFrame("EditBox", "FellowstepSearchBox", list, "InputBoxTemplate") end
    box:SetHeight(20)
    box:SetPoint("TOPLEFT", 16, -36)
    box:SetPoint("TOPRIGHT", -10, -36)
    box:SetAutoFocus(false)
    if type(box.Instructions) == "table" and box.Instructions.SetText then box.Instructions:SetText("Search quests") end
    box:HookScript("OnTextChanged", function(self)
        local text = (self:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        local filter = text ~= "" and text or nil
        if filter == list.filter then return end
        list.filter = filter
        if list.scroll then Matrix:Refresh() end
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    list.search = box
    list.empty = UI.Text(list, "muted")
    list.empty:SetPoint("TOPLEFT", 14, -66)
    list.empty:SetPoint("RIGHT", -14, 0)
    list.empty:SetWordWrap(true)
    list.empty:Hide()

    list.scroll = makeListScroller(list)
    list.scroll:SetPoint("TOPLEFT", 6, -62)
    list.scroll:SetPoint("BOTTOMRIGHT", -12, 6)
    list.scroll.child:SetWidth(LIST_WIDTH - 18)
    list.rows, list.headers = {}, {}

    -- right: tree panel
    tree = frame.Inset

    -- The whole tree panel is the scrollable area. The chain title, legend and collapse button
    -- sit in the header band above it; the pills and catch-up line float on a layer over it.
    local edge = 4 -- keep scrolled nodes inside the panel's beveled edge
    tree.box = CreateFrame("Frame", nil, tree)
    tree.box:SetPoint("TOPLEFT", edge, -edge)
    tree.box:SetPoint("BOTTOMRIGHT", -edge, edge)

    tree.view = makeViewport(tree.box)
    tree.view:SetAllPoints(tree.box)
    tree.view.OnMoved = function()
        if detail and detail:IsShown() and tree.view.drag and tree.view.drag.moved then detail:Hide() end
    end
    tree.view.OnWheel = function() if detail then detail:Hide() end end
    tree.nodes, tree.lines = {}, {}

    local hud = CreateFrame("Frame", nil, tree)
    hud:SetAllPoints(tree.box)
    hud:SetFrameLevel(tree.view.over:GetFrameLevel() + 5)
    tree.hud = hud
    -- soft dark band behind the fixed catch-up line so it reads over nodes
    local bottomShade = hud:CreateTexture(nil, "BACKGROUND")
    bottomShade:SetPoint("BOTTOMLEFT"); bottomShade:SetPoint("BOTTOMRIGHT"); bottomShade:SetHeight(HUD_BOTTOM + 4)
    setGradient(bottomShade, "VERTICAL", 0.8, 0)

    -- the same red game button as the footer buttons, raised so nothing on the window sits over it
    tree.collapse = UI.Button(frame, "<<", 32, 22)
    tree.collapse:SetPoint("BOTTOMLEFT", tree, "TOPLEFT", 0, 11)
    tree.collapse:SetFrameLevel(tree:GetFrameLevel() + 30)
    tree.collapse:RegisterForClicks("LeftButtonUp")
    tree.collapse:SetScript("OnClick", function()
        QM.char.listCollapsed = not QM.char.listCollapsed
        applyCollapse()
        Matrix:Refresh()
    end)
    tree.collapse:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(QM.char.listCollapsed and "Show the chain list" or "Hide the chain list", 1, 1, 1)
        GameTooltip:AddLine("Gives the quest tree more room.", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    tree.collapse:SetScript("OnLeave", function() GameTooltip:Hide() end)

    tree.title = UI.Text(tree, "title")
    -- centred over the chain area; equal side margins leave room for the button and party icons
    tree.title:SetPoint("TOPLEFT", tree, "TOPLEFT", 150, HEAD - 6)
    tree.title:SetPoint("TOPRIGHT", tree, "TOPRIGHT", -150, HEAD - 6)
    tree.title:SetJustifyH("CENTER")
    tree.title:SetWordWrap(false)
    tree.subtitle = UI.Text(tree, "muted")
    tree.subtitle:SetPoint("TOPLEFT", tree.title, "BOTTOMLEFT", 0, -4)
    tree.subtitle:SetPoint("TOPRIGHT", tree.title, "BOTTOMRIGHT", 0, -4)
    tree.subtitle:SetJustifyH("CENTER")

    -- party legend, top right: who's who
    tree.legend = CreateFrame("Frame", nil, tree)
    tree.legend:SetPoint("BOTTOMRIGHT", tree, "TOPRIGHT", -2, 10)
    tree.legend:SetSize(200, AVATAR)
    tree.legend.avatars = {}

    tree.message = UI.Text(hud, "body")
    tree.message:SetPoint("CENTER", tree.box, "CENTER")
    tree.message:SetWordWrap(true)
    tree.message:SetWidth(420)
    tree.message:SetJustifyH("CENTER")

    -- "N earlier / N more" notes at the top and bottom of a condensed chain
    local function makePill(point, y)
        local pill = UI.InsetBox("Frame", hud, { 1, 1, 1, 0.08 })
        pill:SetSize(280, 26)
        pill:SetPoint(point, tree.box, point, 0, y)
        UI.InsideBevel(UI.Fill(pill, { 0, 0, 0, 0.7 }, "BACKGROUND", -1), 2)
        pill.text = UI.Text(pill, "small")
        pill.text:SetPoint("CENTER")
        pill:EnableMouse(true)
        pill:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText("Condensed chain", 1, 1, 1)
            GameTooltip:AddLine("Only the quests your group is working on are shown. Turn off \"Condense quest chains\" in settings to see the whole chain.", 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        pill:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pill:Hide()
        return pill
    end
    tree.pill = makePill("TOP", -HUD_TOP)
    tree.morePill = makePill("BOTTOM", 6)

    tree.catchup = UI.Text(hud, "small")
    tree.catchup:SetPoint("BOTTOMLEFT", 14 - edge, 10 - edge)
    tree.catchup:SetPoint("RIGHT", -14, 0)

    frame.status = UI.Button(frame, "Tell Party Status", 150, 22)
    frame.status:SetScript("OnClick", function() Matrix:TellStatus() end)
    buttonTip(frame.status, "Tell Party Status",
        "Posts how far each person is in this chain to party chat, for example \"Kel 3/6, Toma 4/6\".")

    frame.settings = UI.Button(frame, "Settings", 96, 22)
    -- footer row centred both ways: Settings in the middle of the band between the inset
    -- panels (bottom at 34) and the frame's bottom border, the other two either side of it
    frame.settings:SetPoint("BOTTOM", frame, "BOTTOM", -5, 9) -- -5: side buttons are 140 and 150 wide
    frame.status:SetPoint("LEFT", frame.settings, "RIGHT", 6, 0)
    frame.settings:SetScript("OnClick", function() QM:Fire("QM_OPEN_SETTINGS") end)
    buttonTip(frame.settings, "Settings",
        "Stick Together alerts, test mode, the minimap button and more.")

    frame.testToggle = UI.Button(frame, "Toggle Test Mode", 140, 22)
    frame.testToggle:SetPoint("RIGHT", frame.settings, "LEFT", -6, 0)
    frame.testToggle:SetScript("OnClick", function()
        QM.Test:SetOn(not QM.Test:IsOn())
        QM:Fire("QM_SETTINGS_CHANGED")
    end)
    buttonTip(frame.testToggle, "Toggle Test Mode",
        "Fills your group with pretend players built from your own quests, so you can try everything solo. Click again to remove them.")

    -- how-to line in the empty band under the title bar
    frame.hint = UI.Text(frame, "label")
    frame.hint:SetPoint("TOPLEFT", 70, -36)
    frame.hint:SetText("Click a quest for options  ·  Drag to pan  ·  Mouse wheel scrolls (Shift for sideways)")

    -- resize grip, bottom right
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(820, 460, 1800, 1200)
    elseif frame.SetMinResize then
        frame:SetMinResize(820, 460)
    end
    local grip = CreateFrame("Button", "FellowstepResizeGrip", frame)
    grip:SetSize(20, 20)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameStrata("DIALOG")
    grip:EnableMouse(true)
    local function gripTexture(layer, file, alpha)
        local t = grip:CreateTexture(nil, layer)
        t:SetAllPoints()
        t:SetTexture(file)
        if not t:GetTexture() then
            -- art missing on this client: draw a small gold corner instead
            t:SetColorTexture(1, 0.82, 0, alpha)
        end
        return t
    end
    grip.normal = gripTexture("ARTWORK", "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up", 0.5)
    grip.highlight = gripTexture("HIGHLIGHT", "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight", 0.3)
    local function stopSizing()
        if not grip.sizing then return end
        grip.sizing = false
        grip:SetScript("OnUpdate", nil)
        frame:StopMovingOrSizing()
        QM.char.matrixSize = { frame:GetWidth(), frame:GetHeight() }
        frame.OnMoved(frame)
        Matrix:Refresh()
    end
    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.sizing = true
        frame:StartSizing("BOTTOMRIGHT")
        -- stop even if the button is released somewhere else
        self:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then stopSizing() end
        end)
    end)
    grip:SetScript("OnMouseUp", stopSizing)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Drag to resize", 1, 1, 1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- re-lay the tree while resizing (a few times a second, not every frame)
    local pending = false
    frame:SetScript("OnSizeChanged", function()
        if pending or not frame:IsShown() then return end
        pending = true
        C_Timer.After(0.1, function()
            pending = false
            if frame:IsShown() then Matrix:RefreshTree(false) end
        end)
    end)
    local size = QM.char.matrixSize
    if size and size[1] and size[2] then frame:SetSize(size[1], size[2]) end

    createDetail()
    applyCollapse()
end

---------------------------------------------------------------------------
-- Chain list
---------------------------------------------------------------------------
local function chainSummary(chain)
    local members = QM.Chains:MembersFor(chain)
    local playerOut = not QM.Chains:CanDo(chain, members[1])
    local statuses, counts = {}, {}
    local unknown = false
    for mi, m in ipairs(members) do
        statuses[mi] = {}
        local count = 0
        for si, step in ipairs(chain.steps) do
            local status = QM.Chains:Status(chain, step, m)
            statuses[mi][si] = status
            if isFinished(status) then count = count + 1 end
            if status == S.UNKNOWN then unknown = true end
        end
        counts[mi] = count
    end
    local top = 0
    for mi, c in ipairs(counts) do
        if not (playerOut and members[mi].isPlayer) then top = math.max(top, c) end
    end
    -- per-member detail for the hover preview
    local people, anyBehind = {}, false
    for mi, m in ipairs(members) do
        local p = { member = m, count = counts[mi], addon = QM.Party:HasAddon(m) }
        if playerOut and m.isPlayer then
            p.notForYou = true
        elseif counts[mi] < top and p.addon then
            p.behind = top - counts[mi]; anyBehind = true
        end
        for si, step in ipairs(chain.steps) do
            local st = statuses[mi][si]
            if isOnIt(st) then p.where = "On " .. (step.name or "?") break end
            if not p.where and not isFinished(st) then p.where = "Next: " .. (step.name or "?") break end
        end
        p.where = p.where or "Finished"
        people[mi] = p
    end
    local flag, flagColor
    if anyBehind then
        flag, flagColor = "Out of sync", UI.C.red
    elseif unknown then
        flag, flagColor = "Some unknown", UI.C.muted or { 0.6, 0.6, 0.6 }
    elseif #members - (playerOut and 1 or 0) < 2 then
        flag = nil
    else
        flag, flagColor = "In sync", UI.C.green
    end
    return statuses, flag, flagColor, people
end

-- Hover preview for a chain in the list: where everyone is, before you click it.
local function showChainTooltip(row)
    local chain, people = row.chain, row.people
    if not chain then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(chain.title, 1, 0.82, 0)
    if chain.zoneName then GameTooltip:AddLine(chain.zoneName, 0.7, 0.7, 0.7) end
    local first = chain.steps[1]
    if first and first.name and first.name ~= chain.title then
        GameTooltip:AddLine("Starts with " .. first.name, 0.7, 0.7, 0.7)
    end
    if people and #people > 0 then
        GameTooltip:AddLine(" ")
        for _, p in ipairs(people) do
            local right
            if p.notForYou then
                right = "|cff999999not for your class|r"
            elseif not p.addon and not p.member.isPlayer then
                right = "|cff999999no addon|r"
            else
                right = ("%d/%d · %s"):format(p.count, #chain.steps, p.where)
                if p.behind then right = right .. (" |cffff6655(-%d)|r"):format(p.behind) end
            end
            GameTooltip:AddDoubleLine(coloredName(p.member), right, 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to show this chain", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function listRow(index)
    local row = list.rows[index]
    if row then return row end
    local content = list.scroll.child
    row = CreateFrame("Button", nil, content)
    row:SetWidth(LIST_WIDTH - 18)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    row.sel:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
    row.sel:SetBlendMode("ADD")
    row.sel:SetVertexColor(1, 0.82, 0, 0.45)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    -- name on its own line (wraps rather than truncates), then quests/level, then the
    -- per-player grid, then the sync note under the grid with the full width to itself
    row.name = UI.Text(row, "name")
    row.name:SetPoint("TOPLEFT", 8, -6)
    row.name:SetWidth(LIST_WIDTH - 18 - 16) -- explicit width so wrapped height is right on first draw
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(true)
    row.meta = UI.Text(row, "muted")
    row.meta:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.segments = {}
    row:SetScript("OnMouseDown", function() list.scroll:BeginDrag() end)
    row:SetScript("OnEnter", showChainTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if list.scroll:EndDrag() then return end
        selectedKey = self.key
        if pinnedChain and pinnedChain.key ~= self.key then pinnedChain = nil end
        if detail then detail:Hide() end
        Matrix:Refresh(true)
    end)
    list.rows[index] = row
    return row
end

local function drawSegments(row, statuses, stepCount)
    for _, t in ipairs(row.segments) do t:Hide() end
    local width = LIST_WIDTH - 18 - 16
    local segW = math.max(3, math.min(18, math.floor((width - (stepCount - 1) * 2) / math.max(1, stepCount))))
    local k = 0
    for mi, memberStatuses in ipairs(statuses) do
        for si = 1, stepCount do
            k = k + 1
            local t = row.segments[k]
            if not t then
                t = row:CreateTexture(nil, "ARTWORK")
                row.segments[k] = t
            end
            local c = UI.SegmentColor(memberStatuses[si])
            t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
            t:SetSize(segW, 4)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", row.meta, "BOTTOMLEFT", (si - 1) * (segW + 2), -6 - (mi - 1) * 7)
            t:Show()
        end
    end
end

-- Zone header in the chain list: click to fold that zone's chains away.
local function zoneHeader(index, content)
    local h = list.headers[index]
    if h then return h end
    h = CreateFrame("Button", nil, content)
    h:SetSize(LIST_WIDTH - 18, 20)
    h.toggle = h:CreateTexture(nil, "ARTWORK")
    h.toggle:SetSize(14, 14)
    h.toggle:SetPoint("LEFT", 4, 0)
    h.text = UI.Text(h, "small")
    h.text:SetPoint("LEFT", h.toggle, "RIGHT", 4, 0)
    h.text:SetPoint("RIGHT", -6, 0)
    h.text:SetJustifyH("LEFT")
    h.text:SetTextColor(0.85, 0.85, 0.85) -- soft white, so it doesn't read as another yellow title
    local line = h:CreateTexture(nil, "BORDER")
    line:SetPoint("BOTTOMLEFT", 4, 0)
    line:SetPoint("BOTTOMRIGHT", -4, 0)
    line:SetHeight(1)
    line:SetColorTexture(0.55, 0.42, 0.24, 0.5)
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    h:SetScript("OnMouseDown", function() list.scroll:BeginDrag() end)
    h:SetScript("OnClick", function(self)
        if list.scroll:EndDrag() then return end
        if self.zone == OTHER_CLASS then
            QM.char.showOtherClass = not QM.char.showOtherClass or nil
        else
            local closed = QM.char.collapsedZones
            closed[self.zone] = not closed[self.zone] or nil
        end
        Matrix:RefreshList()
    end)
    h:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.zone == OTHER_CLASS then
            GameTooltip:SetText("Class quests your character can't take", 1, 1, 1)
            GameTooltip:AddLine("Here so you can still see where the rest of the group is on them.", 0.8, 0.8, 0.8, true)
        else
            GameTooltip:SetText(QM.char.collapsedZones[self.zone] and "Click to show this zone's chains" or "Click to hide this zone's chains", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list.headers[index] = h
    return h
end

--- Does a chain match the search text? Chain title or any quest in it.
local function matchesFilter(chain, filter)
    if not filter then return true end
    if (chain.title or ""):lower():find(filter, 1, true) then return true end
    for _, step in ipairs(chain.steps) do
        if (step.name or ""):lower():find(filter, 1, true) then return true end
    end
    return false
end

local function groupChains()
    local all = QM.Chains:ForGroup()
    if pinnedChain then
        local present = false
        for _, c in ipairs(all) do if c.key == pinnedChain.key then present = true end end
        if not present then table.insert(all, pinnedChain) end
    end
    for _, chain in ipairs(all) do QM.Chains:AskAbout(chain) end
    local filter = list and list.filter
    if not filter then return all end
    local out = {}
    for _, chain in ipairs(all) do
        if matchesFilter(chain, filter) then out[#out + 1] = chain end
    end
    return out
end

function Matrix:RefreshList()
    chains = groupChains()
    -- chains you can't do (another class's quests) go last, under their own folded header
    local mine, notMine = {}, {}
    local me = QM.Party:Members()[1]
    for _, chain in ipairs(chains) do
        chain.otherClass = (me and not QM.Chains:CanDo(chain, me)) or nil
        if chain.otherClass then notMine[#notMine + 1] = chain else mine[#mine + 1] = chain end
    end
    for _, chain in ipairs(notMine) do mine[#mine + 1] = chain end
    chains = mine
    if list.empty then
        list.empty:SetText(list.filter and ("No party quests match \"%s\"."):format(list.filter) or "")
        list.empty:SetShown(list.filter ~= nil and #chains == 0)
    end
    local content = list.scroll.child
    for _, r in ipairs(list.rows) do r:Hide() end
    for _, h in ipairs(list.headers) do h:Hide() end

    local members = QM.Party:Members()
    local y, ri, hi = 0, 0, 0
    local lastZone
    local found = false
    QM.char.collapsedZones = QM.char.collapsedZones or {}
    local closed = QM.char.collapsedZones
    local zoneCount = {}
    local function zoneOf(chain) return chain.otherClass and OTHER_CLASS or (chain.zoneName or "?") end
    for _, chain in ipairs(chains) do
        local z = zoneOf(chain)
        zoneCount[z] = (zoneCount[z] or 0) + 1
        if chain.key == selectedKey then found = true end
    end
    for _, chain in ipairs(chains) do
        local zone = zoneOf(chain)
        if zone ~= lastZone then
            lastZone = zone
            hi = hi + 1
            local h = zoneHeader(hi, content)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", 0, -y)
            h.zone = zone
            h.text:SetText(("%s (%d)"):format(zone, zoneCount[zone]))
            local isFolded = closed[zone]
            if zone == OTHER_CLASS then isFolded = not QM.char.showOtherClass end
            h.toggle:SetTexture(isFolded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
            h:Show()
            y = y + 24
        end
        local folded = closed[zone]
        if zone == OTHER_CLASS then folded = not QM.char.showOtherClass end
        if folded and not list.filter then
            -- zone folded away: skip its chains
        else
        ri = ri + 1
        local row = listRow(ri)
        local statuses, flag, flagColor, people = chainSummary(chain)
        row.key = chain.key
        row.chain, row.people = chain, people
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row.name:SetText(chain.title)
        local title = UI.QuestTitleColor()
        row.name:SetTextColor(title[1], title[2], title[3])
        local levels = chain.minLevel and (chain.minLevel == chain.maxLevel and (" · Lv %d"):format(chain.minLevel) or (" · Lv %d-%d"):format(chain.minLevel, chain.maxLevel)) or ""
        local sync = flag and (" · " .. UI.Hex(flagColor) .. flag .. "|r") or ""
        row.meta:SetText(("%d %s%s%s"):format(#chain.steps, #chain.steps == 1 and "quest" or "quests", levels, sync))
        drawSegments(row, statuses, #chain.steps)
        local gridH = #statuses * 7
        local nameH = math.max(14, row.name:GetStringHeight() or 14)
        local thisHeight = 6 + nameH + 3 + 12 + 6 + gridH + 8
        row:SetHeight(thisHeight)
        row.sel:SetShown(chain.key == selectedKey)
        row:Show()
        y = y + thisHeight + 2
        end
    end
    content:SetHeight(math.max(10, y))
    list.scroll:Apply(list.scroll.pos)
    if not found then
        selectedKey = chains[1] and chains[1].key or nil
        for _, r in ipairs(list.rows) do r.sel:SetShown(r:IsShown() and r.key == selectedKey) end
        return true
    end
end

local function selectedChain()
    for _, c in ipairs(chains) do
        if c.key == selectedKey then return c end
    end
    return nil
end

---------------------------------------------------------------------------
-- Tree
---------------------------------------------------------------------------
local function createNode(canvas)
    local n = CreateFrame("Button", nil, canvas)
    n:SetSize(NODE_W, NODE_H)
    UI.CellBackground(n)
    local hl = UI.InsideBevel(n:CreateTexture(nil, "HIGHLIGHT"))
    hl:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight")
    hl:SetBlendMode("ADD")
    n.icon = UI.StatusIcon(n, 18)
    n.icon:SetPoint("LEFT", 8, 0)
    n.name = UI.Text(n, "quest")
    n.name:SetPoint("TOPLEFT", 32, -8)
    n.name:SetPoint("RIGHT", -8, 0)
    n.meta = UI.Text(n, "muted")
    n.meta:SetPoint("TOPLEFT", n.name, "BOTTOMLEFT", 0, -3)
    n.meta:SetPoint("RIGHT", -8, 0)
    n.avatars = {}
    n:RegisterForClicks("LeftButtonUp")
    function n:OnMouseDownPass() tree.view:BeginDrag() end
    function n:OnClickPass()
        if tree.view:EndDrag() then return end -- that was a drag, not a click
        if self.external then
            Matrix:ShowChainFor(self.external)
            return
        end
        if detail:IsShown() and detail.anchor == self then detail:Hide() return end
        Matrix:ShowDetail(self)
    end
    n:SetScript("OnMouseDown", n.OnMouseDownPass)
    n:SetScript("OnClick", n.OnClickPass)
    n:SetScript("OnEnter", function(self)
        if not self.step then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.step.name, 1, 0.82, 0)
        for _, row in ipairs(self.rows or {}) do
            GameTooltip:AddDoubleLine(coloredName(row.member), row.text, 1, 1, 1, 1, 1, 1)
        end
        if self.external then
            GameTooltip:AddLine("Part of a different quest chain. It has to be done before the quest it points to.", 0.55, 0.75, 1, true)
            GameTooltip:AddLine("Click to open that chain", 0.6, 0.6, 0.6)
        else
            GameTooltip:AddLine("Click for options", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    n:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return n
end

local function getLine(i, canvas)
    local l = tree.lines[i]
    if l == false then return nil end
    if not l then
        if not canvas.CreateLine then tree.lines[i] = false return nil end
        l = canvas:CreateLine(nil, "BACKGROUND")
        l:SetThickness(3)
        tree.lines[i] = l
    end
    return l
end

local function hideTree()
    for _, n in ipairs(tree.nodes) do n:Hide() end
    for _, l in ipairs(tree.lines) do if l then l:Hide() end end
    tree.pill:Hide()
    tree.morePill:Hide()
    tree.morePill:SetPoint("BOTTOM", tree.box, "BOTTOM", 0, 6) -- hugs the bottom unless a catch-up line needs the space
    tree.catchup:SetText("")
end

local function message(text)
    tree.title:SetText("")
    tree.subtitle:SetText("")
    tree.message:SetText(text)
    tree.view:Hide()
    for _, a in ipairs(tree.legend.avatars) do a:Hide() end
end

local function drawLegend(members)
    local x = 0
    for i = #members, 1, -1 do
        local m = members[i]
        local a = tree.legend.avatars[i]
        if not a then
            a = createAvatar(tree.legend)
            tree.legend.avatars[i] = a
        end
        a:SetSize(AVATAR + 4, AVATAR + 4)
        a:ClearAllPoints()
        a:SetPoint("TOPRIGHT", -x, 0)
        paintAvatar(a, m, "ACTIVE")
        a.ring:SetVertexColor(classColor(m))
        a.text = "Small icons on each quest show where this player is."
        a:Show()
        x = x + AVATAR + 8
    end
    for i = #members + 1, #tree.legend.avatars do tree.legend.avatars[i]:Hide() end
end

function Matrix:RefreshTree(jump)
    hideTree()
    tree.message:SetText("")
    if QM.Chains.failed then return message(QM.Chains.failed) end
    if not QM.Chains.ready then return message("Reading quest data. This takes a few seconds after logging in.") end
    local chain = selectedChain()
    if not chain then
        return message("No quests yet. Chains show up here as soon as anyone in your group picks up a quest.\n\nPlaying solo? Turn on test mode in settings to see it with pretend players.")
    end
    tree.view:Show()

    -- you, plus everyone who can do this chain (class quests leave the others out)
    local members = QM.Chains:MembersFor(chain)
    drawLegend(members)

    tree.title:SetText(chain.title)
    local title = UI.QuestTitleColor()
    tree.title:SetTextColor(title[1], title[2], title[3])
    local levels = ""
    if chain.minLevel then
        levels = chain.minLevel == chain.maxLevel and (" · Level %d"):format(chain.minLevel) or (" · Level %d-%d"):format(chain.minLevel, chain.maxLevel)
    end
    tree.subtitle:SetText(("%s · %d %s%s"):format(chain.zoneName, #chain.steps, #chain.steps == 1 and "quest" or "quests", levels))

    -- ask anyone with the addon what they've completed in this chain
    local ids = {}
    for _, step in ipairs(chain.steps) do
        ids[#ids + 1] = step.id
        for _, p in ipairs(step.preGroup) do ids[#ids + 1] = p end
        for _, p in ipairs(step.preSingle) do ids[#ids + 1] = p end
        for _, x in ipairs(step.exclusive) do ids[#ids + 1] = x end
    end
    QM.Party:RequestCompleted(ids)

    -- everyone's status on every step
    local grid = {}
    local reachedDepth = -1
    for _, step in ipairs(chain.steps) do
        local row = { all = true, any = false }
        for mi, m in ipairs(members) do
            local status, info = QM.Chains:Status(chain, step, m)
            row[mi] = { status = status, info = info }
            if not isFinished(status) then row.all = false end
            if isOnIt(status) or status == S.DONE then row.any = true end
        end
        grid[step.id] = row
        if row.any then reachedDepth = math.max(reachedDepth, step.depth or 0) end
    end

    -- which steps to draw
    local condense = QM.char.condense == true
    local hideSpoilers = QM.char.hideSpoilers ~= false
    local frontier = math.max(reachedDepth, 0)
    local visible, hiddenDone, hiddenAhead = {}, 0, 0
    local spoiler = {}
    for _, step in ipairs(chain.steps) do
        local row = grid[step.id]
        local ahead = (step.depth or 0) > frontier and not row.any
        local show = true
        if condense and row.all and #members > 0 then
            show = false
            hiddenDone = hiddenDone + 1
        elseif condense and ahead then
            show = false
            hiddenAhead = hiddenAhead + 1
        elseif ahead and hideSpoilers then
            spoiler[step.id] = true
        end
        if show then visible[#visible + 1] = step end
    end

    if hiddenDone > 0 then
        tree.pill.text:SetText(("%d earlier %s finished by everyone"):format(hiddenDone, hiddenDone == 1 and "quest" or "quests"))
        tree.pill:Show()
    end
    if hiddenAhead > 0 then
        tree.morePill.text:SetText(("%d more %s ahead"):format(hiddenAhead, hiddenAhead == 1 and "quest" or "quests"))
        tree.morePill:Show()
    end
    if #visible == 0 then
        tree.message:SetText(hiddenDone > 0 and "Everyone has finished this chain." or "Nothing to show yet.")
        tree.view.child:SetSize(10, 10)
        tree.view:Apply(0, 0)
        return
    end

    -- layout: one row per depth, rows packed so hidden depths leave no gaps
    local depths, byDepth = {}, {}
    for _, step in ipairs(visible) do
        local d = step.depth or 0
        if not byDepth[d] then byDepth[d] = {}; depths[#depths + 1] = d end
        table.insert(byDepth[d], step)
    end
    table.sort(depths)
    local pos = {}
    local widest = 0
    for _, d in ipairs(depths) do widest = math.max(widest, #byDepth[d]) end
    local viewW = tree.view:GetWidth()
    if not viewW or viewW < 100 then viewW = (frame:GetWidth() or WIDTH) - (QM.char.listCollapsed and 40 or LIST_WIDTH + 46) end
    local contentW = math.max(viewW, widest * (NODE_W + GAP_X) - GAP_X + PAD * 2)
    local topPad = HUD_TOP + (tree.pill:IsShown() and PAD + 30 or PAD)
    for r, d in ipairs(depths) do
        local rowSteps = byDepth[d]
        -- order by where their parents sit, so lines cross as little as possible
        for _, step in ipairs(rowSteps) do
            local sum, n = 0, 0
            for _, pid in ipairs(step.parents or {}) do
                if pos[pid] then sum = sum + pos[pid].x; n = n + 1 end
            end
            step.sortX = n > 0 and sum / n or step.id
        end
        table.sort(rowSteps, function(a, b)
            if a.sortX ~= b.sortX then return a.sortX < b.sortX end
            return a.id < b.id
        end)
        local rowW = #rowSteps * (NODE_W + GAP_X) - GAP_X
        local x0 = (contentW - rowW) / 2
        for i, step in ipairs(rowSteps) do
            pos[step.id] = { x = x0 + (i - 1) * (NODE_W + GAP_X), y = topPad + (r - 1) * (NODE_H + GAP_Y) }
        end
    end
    -- quests from other chains that a step here needs first: a row above, linked in blue
    local outside = {}
    for _, o in ipairs(QM.Chains:OutsidePrereqs(chain)) do
        if pos[o.child] then outside[#outside + 1] = o end
    end
    if #outside > 0 then
        for _, step in ipairs(visible) do pos[step.id].y = pos[step.id].y + NODE_H + GAP_Y end
        table.sort(outside, function(a, b) return pos[a.child].x < pos[b.child].x end)
        local rowW = #outside * (NODE_W + GAP_X) - GAP_X
        if rowW + PAD * 2 > contentW then contentW = rowW + PAD * 2 end
        local x0 = (contentW - rowW) / 2
        for i, o in ipairs(outside) do
            o.x, o.y = x0 + (i - 1) * (NODE_W + GAP_X), topPad
        end
    end
    local rowsH = (#depths + (#outside > 0 and 1 or 0)) * (NODE_H + GAP_Y) - GAP_Y
    local contentH = topPad + rowsH + PAD + HUD_BOTTOM + (tree.morePill:IsShown() and 30 or 0)
    local canvas = tree.view.child
    canvas:SetSize(contentW, contentH)

    -- nodes
    local focus
    local nodeFor = {}
    for i, step in ipairs(visible) do
        local n = tree.nodes[i]
        if not n then
            n = createNode(canvas)
            tree.nodes[i] = n
        end
        nodeFor[step.id] = n
        n.external = nil
        local p = pos[step.id]
        n:ClearAllPoints()
        n:SetPoint("TOPLEFT", canvas, "TOPLEFT", p.x, -p.y)
        local row = grid[step.id]
        n.step, n.chain = step, chain
        n:EnableMouse(not spoiler[step.id])
        if spoiler[step.id] then
            -- a future quest: the box is there, but nothing about it
            UI.PaintCell(n, "SPOILER")
            n.icon:Hide()
            n.name:SetText("?")
            local mc = UI.C.muted
            n.name:SetTextColor(mc[1], mc[2], mc[3])
            n.meta:SetText("Later in the chain")
            n.rows = nil
            for _, a in ipairs(n.avatars) do a:Hide() end
            n:Show()
        else
        local mine = row[1] and row[1].status or S.UNKNOWN
        UI.PaintCell(n, mine)
        local look = LOOK[mine] or LOOK[S.UNKNOWN]
        n.icon:SetKind(look.icon)
        n.name:SetText(step.name)
        local tc = isFinished(mine) and UI.C.muted or UI.QuestTitleColor()
        n.name:SetTextColor(tc[1], tc[2], tc[3])
        local tags = {}
        if step.requiredLevel and step.requiredLevel > 0 then tags[#tags + 1] = "Lv " .. step.requiredLevel end
        if step.breadcrumbFor then tags[#tags + 1] = "Optional" end
        if step.pickOne then tags[#tags + 1] = "Pick one" end
        if mine == S.ACTIVE and row[1].info and row[1].info.quest then
            local o = objectiveSummary(row[1].info.quest)
            if o then tags[#tags + 1] = o end
        elseif mine ~= S.UNKNOWN then
            tags[#tags + 1] = statusLabel(mine, row[1].info)
        end
        n.meta:SetText(table.concat(tags, " · "))
        n.step, n.chain = step, chain

        -- avatars for everyone who is on this step, or could start it next
        n.rows = {}
        local shown = 0
        for mi, m in ipairs(members) do
            local cell = row[mi]
            local text = statusLabel(cell.status, cell.info)
            if isOnIt(cell.status) and cell.info and cell.info.quest then
                if cell.info.objectivesKnown then
                    local o = objectiveSummary(cell.info.quest)
                    if o then text = text .. " " .. o end
                else
                    text = text .. " (count unknown)"
                end
            end
            n.rows[#n.rows + 1] = { member = m, text = text }
            local kind
            if cell.status == S.READY then kind = "READY"
            elseif cell.status == S.ACTIVE then kind = "ACTIVE"
            elseif (cell.status == S.AVAILABLE or cell.status == S.LEVEL) then kind = "NEXT" end
            if kind then
                shown = shown + 1
                local a = n.avatars[shown]
                if not a then
                    a = createAvatar(n)
                    n.avatars[shown] = a
                end
                a:SetFrameLevel(n:GetFrameLevel() + 3)
                a:ClearAllPoints()
                a:SetPoint("CENTER", n, "BOTTOMRIGHT", -12 - (shown - 1) * (AVATAR - 4), 1)
                paintAvatar(a, m, kind)
                a.text = (kind == "NEXT" and "Next up: " or "") .. text
                a:Show()
            end
            if m.isPlayer and not focus and (isOnIt(cell.status) or cell.status == S.AVAILABLE) then focus = step.id end
        end
        for k = shown + 1, #n.avatars do n.avatars[k]:Hide() end
        n:Show()
        end
    end

    -- connecting lines
    local li = 0
    for _, step in ipairs(visible) do
        for _, pid in ipairs(step.parents or {}) do
            local from, to = nodeFor[pid], nodeFor[step.id]
            if from and to then
                li = li + 1
                local l = getLine(li, canvas)
                if l then
                    l:SetStartPoint("BOTTOM", from, 0, 0)
                    l:SetEndPoint("TOP", to, 0, 0)
                    local myChild = grid[step.id][1] and grid[step.id][1].status
                    local myParent = grid[pid][1] and grid[pid][1].status
                    if myChild and isFinished(myChild) then
                        l:SetColorTexture(0.25, 0.75, 0.30, 0.9)
                    elseif myParent and isFinished(myParent) then
                        l:SetColorTexture(1, 0.82, 0, 0.8)
                    else
                        l:SetColorTexture(0.5, 0.5, 0.5, 0.5)
                    end
                    l:Show()
                end
            end
        end
    end

    -- outside prerequisite nodes
    for oi, o in ipairs(outside) do
        local i = #visible + oi
        local n = tree.nodes[i]
        if not n then
            n = createNode(canvas)
            tree.nodes[i] = n
        end
        n:ClearAllPoints()
        n:SetPoint("TOPLEFT", canvas, "TOPLEFT", o.x, -o.y)
        n:EnableMouse(true)
        n.external, n.chain = o.id, nil
        n.step = { id = o.id, name = o.name }
        UI.PaintCell(n, "LINKED")
        local mineDone = QM.Party:IsCompleted(members[1], o.id)
        n.icon:SetKind(mineDone and "DONE" or (QM.Log.active[o.id] and "ACTIVE" or "BLOCKED"))
        n.name:SetText(o.name)
        local lc = UI.C.linked or { 0.55, 0.75, 1 }
        n.name:SetTextColor(lc[1], lc[2], lc[3])
        n.meta:SetText("From another chain · needed for this one")
        n.rows = {}
        local shown = 0
        for _, m in ipairs(members) do
            local done = QM.Party:IsCompleted(m, o.id)
            local q = QM.Party:GetQuest(m, o.id)
            local text = done and "Completed" or (q and "In progress") or (done == false and "Not done yet") or "Unknown"
            n.rows[#n.rows + 1] = { member = m, text = text }
            if q then
                shown = shown + 1
                local a = n.avatars[shown]
                if not a then a = createAvatar(n); n.avatars[shown] = a end
                a:SetFrameLevel(n:GetFrameLevel() + 3)
                a:ClearAllPoints()
                a:SetPoint("CENTER", n, "BOTTOMRIGHT", -12 - (shown - 1) * (AVATAR - 4), 1)
                paintAvatar(a, m, "ACTIVE")
                a.text = text
                a:Show()
            end
        end
        for k = shown + 1, #n.avatars do n.avatars[k]:Hide() end
        n:Show()
        local to = nodeFor[o.child]
        if to then
            li = li + 1
            local l = getLine(li, canvas)
            if l then
                l:SetStartPoint("BOTTOM", n, 0, 0)
                l:SetEndPoint("TOP", to, 0, 0)
                l:SetColorTexture(lc[1], lc[2], lc[3], 0.7)
                l:Show()
            end
        end
    end

    if jump then
        local p = focus and pos[focus]
        local vw, vh = tree.view:GetWidth() or viewW, tree.view:GetHeight() or 300
        if p then
            -- center on your current quest; near either end it settles at the top or bottom
            tree.view:ScrollTo(p.x + NODE_W / 2 - vw / 2, p.y + NODE_H / 2 - vh / 2, true)
        else
            tree.view:ScrollTo((contentW - vw) / 2, 0, true)
        end
    else
        tree.view:Apply(tree.view.x, tree.view.y)
    end

    -- a nudge to help the person furthest behind
    for _, step in ipairs(chain.steps) do
        local row = grid[step.id]
        for mi, m in ipairs(members) do
            if not m.isPlayer and row[mi].status == S.AVAILABLE then
                local loc = QM.Chains:StarterLocation(step)
                local gold = UI.Hex(UI.C.gold)
                tree.catchup:SetText(("%sCatch %s up:|r pick up %s%s."):format(gold, QM.ShortName(m.name), step.name,
                    loc and loc.name and (" from " .. loc.name .. (loc.areaName and (" in " .. loc.areaName) or "")) or ""))
                tree.morePill:SetPoint("BOTTOM", tree.box, "BOTTOM", 0, HUD_BOTTOM)
                return
            end
        end
    end
end

function Matrix:Refresh(jump)
    if not frame or not frame:IsShown() then return end
    local changedSelection
    if not QM.char.listCollapsed then
        changedSelection = self:RefreshList()
    else
        chains = groupChains()
        if not selectedChain() then selectedKey = chains[1] and chains[1].key; changedSelection = true end
    end
    self:RefreshTree(jump or changedSelection)
    frame.testToggle.tipText = QM.Test:IsOn()
        and "Test mode is on. Click to remove the pretend players and show only your real group."
        or "Fills your group with pretend players built from your own quests, so you can try everything solo."
end

---------------------------------------------------------------------------
-- Detail popup
---------------------------------------------------------------------------
function Matrix:ShowDetail(node)
    local step = node.step
    local loc = QM.Chains:StarterLocation(step)
    detail.anchor = node
    detail.title:SetText(step.name)
    local t = UI.QuestTitleColor()
    detail.title:SetTextColor(t[1], t[2], t[3])

    local meta = {}
    if step.requiredLevel and step.requiredLevel > 0 then meta[#meta + 1] = "Level " .. step.requiredLevel end
    if step.breadcrumbFor then meta[#meta + 1] = "Optional lead-in" end
    if step.pickOne then meta[#meta + 1] = "Pick one of the choices" end
    if loc and loc.name then
        meta[#meta + 1] = "From " .. loc.name .. (loc.areaName and (", " .. loc.areaName) or "")
    end
    detail.meta:SetText(table.concat(meta, " · "))
    detail.meta:SetWordWrap(true)

    local lines = {}
    local someoneNeeds = false
    for _, row in ipairs(node.rows or {}) do
        lines[#lines + 1] = coloredName(row.member) .. "  " .. row.text
    end
    detail.body:SetText(table.concat(lines, "\n"))
    for mi, m in ipairs(QM.Party:Members()) do
        if not m.isPlayer then
            local status = QM.Chains:Status(node.chain, step, m)
            if status == S.AVAILABLE or status == S.UNKNOWN then someoneNeeds = true end
        end
    end

    local giver = loc and loc.name or "the quest giver"
    detail.waypoint:SetText("Mark " .. (loc and loc.name or "Quest Giver") .. " on Map")
    detail.waypoint.tipText = loc and loc.uiMapID and
        ("Puts a map pin on %s%s and turns on the arrow that points you there."):format(giver, loc.areaName and (" in " .. loc.areaName) or "")
        or "We don't know where this quest starts, so there's nothing to mark."
    detail.waypoint:SetEnabled(loc ~= nil and loc.uiMapID ~= nil)
    detail.waypoint:SetScript("OnClick", function()
        UI.SetWaypoint(loc)
        detail:Hide()
    end)

    local tellText = ("%s starts with %s"):format(step.name, giver)
    detail.tell.tipText = ("Posts in party chat: \"%s\" with a clickable map pin."):format(tellText)
    detail.tell:SetScript("OnClick", function()
        UI.TellParty(tellText, loc)
        detail:Hide()
    end)

    local canShare = QM.Log.active[step.id] and someoneNeeds
    -- you don't have it but someone with the addon does: ask them to share it
    local holder
    if not QM.Log.active[step.id] and not QM.Log:IsCompleted(step.id) then
        for _, m in ipairs(QM.Party:Members()) do
            if not m.isPlayer and QM.Party:HasAddon(m) and QM.Party:GetQuest(m, step.id) then holder = m break end
        end
    end
    if canShare then
        detail.share:SetText("Share Quest with Party")
        detail.share.tipTitle = "Share Quest with Party"
        detail.share.tipText = "Offers your copy of this quest to everyone in the group who can take it, like the Share button in your quest log."
        detail.share:SetScript("OnClick", function()
            UI.ShareQuest(step.id)
            detail:Hide()
        end)
    elseif holder then
        local who = QM.ShortName(holder.name)
        detail.share:SetText("Ask " .. who .. " to Share")
        detail.share.tipTitle = "Ask " .. who .. " to Share"
        detail.share.tipText = ("Pops up a Share button on %s's screen for this quest."):format(who)
        detail.share:SetScript("OnClick", function()
            QM.Comm:AskToShare(holder.name, step.id)
            QM:Print(("asked %s to share %s."):format(who, step.name or "the quest"))
            detail:Hide()
        end)
    end
    canShare = (canShare or holder) and true or false
    detail.share:SetShown(canShare)

    -- size to fit
    detail:Show()
    local bodyH = (detail.body:GetStringHeight() or 14 * #lines)
    local metaH = detail.meta:GetStringHeight() or 12
    local buttons = canShare and 3 or 2
    local buttonsH = buttons * 26
    detail:SetHeight(14 + 16 + 4 + metaH + 8 + bodyH + 12 + buttonsH + 10)
    detail.waypoint:ClearAllPoints()
    detail.waypoint:SetPoint("BOTTOMLEFT", 14, 10 + (buttons - 1) * 26)
    detail.tell:ClearAllPoints()
    detail.tell:SetPoint("TOPLEFT", detail.waypoint, "BOTTOMLEFT", 0, -4)
    detail.share:ClearAllPoints()
    detail.share:SetPoint("TOPLEFT", detail.tell, "BOTTOMLEFT", 0, -4)

    detail:ClearAllPoints()
    detail:SetPoint("TOPLEFT", node, "TOPRIGHT", 6, 0)
end

---------------------------------------------------------------------------
-- Party status line
---------------------------------------------------------------------------
function Matrix:TellStatus()
    local chain = selectedChain()
    if not chain then return end
    local parts = {}
    for _, m in ipairs(QM.Party:Members()) do
        local done = 0
        for _, step in ipairs(chain.steps) do
            if isFinished(QM.Chains:Status(chain, step, m)) then done = done + 1 end
        end
        parts[#parts + 1] = ("%s %d/%d"):format(QM.ShortName(m.name), done, #chain.steps)
    end
    UI.TellParty(chain.title .. ": " .. table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
function Matrix:Toggle()
    if QM:IsQuiet() then
        QM:Print("companion mode is on, so the UI is hidden. Type /fs quiet to turn it off.")
        return
    end
    if not frame then createFrame() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:Refresh(true)
    end
end

--- Open the window on the chain a quest belongs to (from the objective tracker).
function Matrix:ShowChainFor(questID)
    if QM:IsQuiet() then return end
    local chain = QM.Chains:ForQuest(questID)
    if not chain then
        QM:Print("that quest isn't part of a chain I know about.")
        return
    end
    if not frame then createFrame() end
    if list.filter then list.search:SetText("") end
    pinnedChain = chain
    if not QM.Chains:CanDo(chain, QM.Party:Members()[1]) then QM.char.showOtherClass = true end
    if QM.char.collapsedZones then QM.char.collapsedZones[chain.zoneName or "?"] = nil end
    selectedKey = chain.key
    if detail then detail:Hide() end
    frame:Show()
    self:Refresh(true)
end

QM:On("QM_TOGGLE_MATRIX", function() Matrix:Toggle() end)
QM:On("QM_SHOW_CHAIN", function(_, questID) Matrix:ShowChainFor(questID) end)
QM:On("QM_PARTY_CHANGED", function() Matrix:Refresh() end)
QM:On("QM_CHAINS_READY", function() Matrix:Refresh(true) end)
QM:On("QM_SETTINGS_CHANGED", function()
    if frame and QM:IsQuiet() then frame:Hide() end
    Matrix:Refresh()
end)
QM:On("QM_RESET_POSITIONS", function()
    QM.char.matrixSize = nil
    if frame then
        frame:ClearAllPoints()
        frame:SetSize(WIDTH, HEIGHT)
        frame:SetPoint("CENTER")
    end
end)
