-- Fellowstep: Stick Together
-- For groups that want to do the same quests at the same pace. A small panel next to the
-- quest tracker lists only what is out of step (someone is missing a quest, someone can turn
-- in while others can't, someone wandered off), and gentle alerts point it out as it happens.
-- Off by default; turn it on in settings or with /fs together.

local _, QM = ...
local UI = QM.UI

local Together = {}
QM.Together = Together

local ROW_HEIGHT = 34
local WIDTH = 270

local RED, GREY, WHITE, GREEN, GOLD = "|cffff5050", "|cffa0a0a0", "|cffffffff", "|cff40c040", "|cffffd100"
local function pickColors()
end

local function enabled()
    return QM.char.syncEnabled and not QM:IsQuiet()
end

--- Everyone in the group except you.
local function others()
    local list = {}
    for _, m in ipairs(QM.Party:Members()) do
        if not m.isPlayer then list[#list + 1] = m end
    end
    return list
end

--- "Kel", "Kel and Toma", "Kel, Toma and Wren"
local function nameList(members)
    local names = {}
    for _, m in ipairs(members) do names[#names + 1] = QM.ShortName(m.name) end
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function verb(members, one, many)
    return #members == 1 and one or many
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
local panel, header, rows = nil, nil, {}

local function placePanel()
    panel:ClearAllPoints()
    local p = QM.char.syncPoint
    if p then
        panel:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    elseif ObjectiveTrackerFrame then
        panel:SetPoint("TOPRIGHT", ObjectiveTrackerFrame, "TOPLEFT", -16, 0)
    else
        panel:SetPoint("RIGHT", UIParent, "RIGHT", -300, 120)
    end
end

local function createRow(index)
    local row = CreateFrame("Button", nil, panel)
    row:SetSize(WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4 - (index - 1) * ROW_HEIGHT)
    row.icon = UI.StatusIcon(row, 18)
    row.icon:SetPoint("TOPLEFT", 2, -2)
    row.title = UI.Text(row, "quest")
    row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
    row.title:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    row.sub = UI.Text(row, "small")
    row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    row.action = UI.Button(row, "Share", 58, 20)
    row.action:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -4)
    row.action:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(self:GetText(), 1, 1, 1)
        GameTooltip:AddLine(self.tip, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    row.action:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if self.loc then UI.SetWaypoint(self.loc) end
    end)
    row:SetScript("OnEnter", function(self)
        if not self.tooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        for i, line in ipairs(self.tooltip) do
            if i == 1 then GameTooltip:SetText(line, 1, 0.82, 0) else GameTooltip:AddLine(line, 1, 1, 1, true) end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function createPanel()
    panel = CreateFrame("Frame", "FellowstepTogetherFrame", UIParent)
    panel:SetSize(WIDTH, 30)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    placePanel()

    header = CreateFrame("Button", nil, panel)
    header:SetSize(WIDTH, 26)
    header:SetPoint("TOPLEFT")
    UI.HeaderBar(header)
    header.name = UI.Text(header, "header")
    header.name:SetPoint("LEFT", 8, 0)
    header.name:SetText("Stick Together")
    header.status = UI.Text(header, "small")
    header.status:SetPoint("RIGHT", -26, 0)
    header.status:SetJustifyH("RIGHT")
    header.toggle = UI.Text(header, "title")
    header.toggle:SetPoint("RIGHT", -8, 1)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() panel:StartMoving() end)
    header:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
        local point, _, relPoint, x, y = panel:GetPoint(1)
        QM.char.syncPoint = { point, relPoint, x, y }
    end)
    header:SetScript("OnClick", function()
        QM.char.syncCollapsed = not QM.char.syncCollapsed
        Together:Refresh()
    end)
    header:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Stick Together", 1, 0.82, 0)
        GameTooltip:AddLine("Lists anything where your group is out of step: a quest someone is missing, someone ready to turn in early, or someone far away.", 1, 1, 1, true)
        GameTooltip:AddLine("Click to collapse. Drag to move. Turn it off in Fellowstep settings.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    header:SetScript("OnLeave", function() GameTooltip:Hide() end)

    panel.footer = UI.Text(panel, "muted")
    panel.footer:SetWordWrap(true)
    panel.footer:SetWidth(WIDTH - 8)
    panel:Hide()
end

---------------------------------------------------------------------------
-- What's out of step
---------------------------------------------------------------------------
local function questLabel(id, level)
    local name = QM.Chains:QuestName(id)
    if level and level > 0 then return ("[%d] %s"):format(level, name) end
    return name
end

local function starterLoc(questID)
    local chain = QM.Chains:ForQuest(questID)
    local step = chain and chain.byId[questID]
    return step and QM.Chains:StarterLocation(step)
end

--- Members (other than you) who lack a quest you have and haven't done it already.
local function lacking(questID, group)
    local list = {}
    for _, m in ipairs(group) do
        local theirs = QM.Party:GetQuest(m, questID)
        if theirs == false and QM.Party:IsCompleted(m, questID) ~= true then list[#list + 1] = m end
    end
    return list
end

--- Rows describing where the group is out of step. Returns rows, problemCount.
function Together:Compare()
    local Party, Log = QM.Party, QM.Log
    local group = others()
    local missing, turnIn, theirsOnly = {}, {}, {}

    for id, mine in pairs(Log.active) do
        local without = lacking(id, group)
        if #without > 0 then
            missing[#missing + 1] = { id = id, level = mine.level, kind = "AVAILABLE", share = true,
                sub = RED .. nameList(without) .. " " .. verb(without, "doesn't", "don't") .. " have this|r" }
        else
            -- everyone has it: flag when some can turn in and others can't
            local ready, notReady = {}, {}
            if mine.state == Log.STATE_READY then ready[#ready + 1] = { name = "You" } else notReady[#notReady + 1] = { name = "You" } end
            for _, m in ipairs(group) do
                local q, known = Party:GetQuest(m, id)
                if q and known then
                    if q.state == Log.STATE_READY then ready[#ready + 1] = m else notReady[#notReady + 1] = m end
                end
            end
            if #ready > 0 and #notReady > 0 then
                turnIn[#turnIn + 1] = { id = id, level = mine.level, kind = "READY",
                    sub = GOLD .. nameList(ready) .. " can turn in. Wait for " .. nameList(notReady) .. ".|r" }
            end
        end
    end

    -- quests others have that you don't
    local seen = {}
    for _, m in ipairs(group) do
        local p = Party.peers[m.name]
        for id in pairs(p and p.quests or {}) do
            if not seen[id] and not Log.active[id] and not Log:IsCompleted(id) then
                seen[id] = true
                local who = {}
                for _, other in ipairs(group) do
                    local q = Party:GetQuest(other, id)
                    if q then who[#who + 1] = other end
                end
                theirsOnly[#theirsOnly + 1] = { id = id, kind = "THEIRS", map = true,
                    sub = GREY .. nameList(who) .. " " .. verb(who, "has", "have") .. " this. You don't.|r" }
            end
        end
    end

    local function byId(a, b) return a.id < b.id end
    table.sort(missing, byId); table.sort(turnIn, byId); table.sort(theirsOnly, byId)
    local all = {}
    for _, list in ipairs({ missing, turnIn, theirsOnly }) do
        for _, r in ipairs(list) do all[#all + 1] = r end
    end
    return all, #all
end

--- Members further away than the far-distance setting.
local function farAway()
    local list = {}
    for _, m in ipairs(others()) do
        local d = QM.Party:Distance(m)
        if d and d > QM.char.farDistance then list[#list + 1] = { member = m, distance = d } end
    end
    return list
end

function Together:Refresh()
    if not panel then return end
    if not enabled() or #others() == 0 then
        panel:Hide()
        return
    end
    panel:Show()

    local list, problems = self:Compare()
    local far = farAway()

    if problems == 0 and #far == 0 then
        header.status:SetText(GREEN .. "In step|r")
    elseif problems == 0 then
        header.status:SetText(RED .. "Someone's far away|r")
    else
        header.status:SetText(GOLD .. ("%d out of step|r"):format(problems))
    end
    header.toggle:SetText(QM.char.syncCollapsed and "+" or "-")

    local shown = QM.char.syncCollapsed and 0 or #list
    for i = 1, math.max(shown, #rows) do
        local row = rows[i]
        if i <= shown then
            row = row or createRow(i)
            rows[i] = row
            local r = list[i]
            row.icon:SetKind(r.kind)
            row.title:SetText(questLabel(r.id, r.level))
            local tc = r.kind == "THEIRS" and UI.C.muted or UI.QuestTitleColor()
            row.title:SetTextColor(tc[1], tc[2], tc[3])
            row.sub:SetText(r.sub or "")
            row.loc = starterLoc(r.id)
            row.tooltip = { QM.Chains:QuestName(r.id), "Click to mark where this quest starts on your map." }
            local questID = r.id
            if r.share then
                row.action:SetText("Share")
                row.action.tip = "Offers your copy of this quest to the group."
                row.action:SetScript("OnClick", function()
                    if not UI.ShareQuest(questID) then UI.SetWaypoint(starterLoc(questID)) end
                end)
                row.action:Show()
            elseif r.map and row.loc then
                local loc = row.loc
                row.action:SetText("Map")
                row.action.tip = "Marks the quest giver on your map so you can go get it."
                row.action:SetScript("OnClick", function() UI.SetWaypoint(loc) end)
                row.action:Show()
            else
                row.action:Hide()
            end
            row:Show()
        elseif row then
            row:Hide()
        end
    end

    local parts = {}
    for _, f in ipairs(far) do
        parts[#parts + 1] = ("%s is %d yards away"):format(QM.ShortName(f.member.name), math.floor(f.distance + 0.5))
    end
    if shown == 0 and not QM.char.syncCollapsed and #parts == 0 then
        parts[1] = "Everyone has the same quests."
    end
    panel.footer:ClearAllPoints()
    panel.footer:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8 - shown * ROW_HEIGHT)
    panel.footer:SetText(table.concat(parts, " · "))
    local footerH = (#parts > 0) and ((panel.footer:GetStringHeight() or 12) + 6) or 0
    panel:SetHeight(26 + 8 + shown * ROW_HEIGHT + footerH + 6)
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------
local toast

local function createToast()
    toast = UI.Panel(UIParent, "FellowstepToast")
    toast:SetSize(380, 92)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -140)
    toast:SetFrameStrata("DIALOG")
    toast.icon = UI.StatusIcon(toast, 34)
    toast.icon:SetPoint("TOPLEFT", 14, -14)
    toast.title = UI.Text(toast, "title")
    toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, 0)
    toast.title:SetPoint("RIGHT", -30, 0)
    toast.body = UI.Text(toast, "body")
    toast.body:SetWordWrap(true)
    toast.body:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -4)
    toast.body:SetPoint("RIGHT", -30, 0)
    toast.primary = UI.Button(toast, "Share Quest", 120, 22, "primary")
    toast.primary:SetPoint("BOTTOMLEFT", toast.icon, "BOTTOMRIGHT", 10, -34)
    toast.secondary = UI.Button(toast, "Show on Map", 120, 22)
    toast.secondary:SetPoint("LEFT", toast.primary, "RIGHT", 8, 0)
    toast.close = UI.CloseButton(toast, function() toast:Hide() end)
    toast.close:SetPoint("TOPRIGHT", 0, 0)
    toast:Hide()
end

--- Show an alert. opts: title, body, icon, primary = {text, fn}, secondary = {text, fn}
function Together:Alert(opts)
    if not enabled() or not QM.char.alerts then return end
    if not toast then createToast() end
    toast.title:SetText(opts.title)
    toast.body:SetText(opts.body or "")
    toast.icon:SetKind(opts.icon or "AVAILABLE")
    local function wire(button, spec)
        if spec then
            button:SetText(spec.text)
            button:SetScript("OnClick", function() spec.fn(); toast:Hide() end)
            button:Show()
        else
            button:Hide()
        end
    end
    wire(toast.primary, opts.primary)
    wire(toast.secondary, opts.secondary)
    toast:Show()
    if QM.char.alertSound and SOUNDKIT then
        pcall(PlaySound, SOUNDKIT.UI_QUEST_ROLLING_FORWARD_01 or SOUNDKIT.IG_QUEST_LIST_OPEN)
    end
    local shownAt = GetTime()
    toast.shownAt = shownAt
    C_Timer.After(25, function()
        if toast.shownAt == shownAt then toast:Hide() end
    end)
end

-- You picked up a quest: give everyone a moment, then check they have it too.
QM:On("QM_QUEST_ACCEPTED", function(_, questID)
    C_Timer.After(QM.char.shareGrace or 20, function()
        if not enabled() or not QM.Log.active[questID] then return end
        local without = lacking(questID, others())
        if #without == 0 then return end
        local q = QM.Log.active[questID]
        Together:Alert({
            title = nameList(without) .. " " .. verb(without, "doesn't", "don't") .. " have this quest",
            body = questLabel(questID, q.level),
            icon = "AVAILABLE",
            primary = { text = "Share Quest", fn = function() UI.ShareQuest(questID) end },
            secondary = { text = "Show on Map", fn = function() UI.SetWaypoint(starterLoc(questID)) end },
        })
    end)
end)

-- Someone wandered off.
local farSince, farAlerted = {}, {}
C_Timer.NewTicker(2, function()
    if panel and panel:IsShown() then Together:Refresh() end
    if not enabled() then wipe(farSince); wipe(farAlerted) return end
    local now = GetTime()
    local still = {}
    for _, f in ipairs(farAway()) do
        local name = f.member.name
        still[name] = true
        farSince[name] = farSince[name] or now
        if not farAlerted[name] and now - farSince[name] > 15 and not InCombatLockdown() then
            farAlerted[name] = true
            local m = f.member
            Together:Alert({
                title = QM.ShortName(name) .. " is far away",
                body = ("%s · %d yards. Kills and quest items won't count for both of you."):format(
                    QM.Party:ZoneName(m) or "?", math.floor(f.distance + 0.5)),
                icon = "UNKNOWN",
                primary = m.unit and { text = "Mark on Map", fn = function()
                    local mapID = C_Map.GetBestMapForUnit(m.unit)
                    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, m.unit)
                    if pos then UI.SetWaypoint({ uiMapID = mapID, x = pos.x * 100, y = pos.y * 100 }) end
                end },
            })
        end
    end
    for name in pairs(farSince) do
        if not still[name] then farSince[name], farAlerted[name] = nil, nil end
    end
end)

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
QM:On("QM_LOGIN", function()
    pickColors()
    createPanel()
    Together:Refresh()
end)
QM:On("QM_PARTY_CHANGED", function() Together:Refresh() end)
QM:On("QM_SETTINGS_CHANGED", function() Together:Refresh() end)
QM:On("QM_CHAINS_READY", function() Together:Refresh() end)
QM:On("QM_RESET_POSITIONS", function()
    if panel then placePanel() end
end)
