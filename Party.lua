-- Fellowstep: Party
-- Who is in the group and what we know about each member's quests.
-- Members with Fellowstep send exact data. Members without it fall back to the
-- stock client, which can only tell whether they are on a quest.

local _, QM = ...

local Party = {}
QM.Party = Party

Party.peers = {}   -- [fullName] = { hasAddon, quiet, version, quests = {}, completed = {}, asked = {} }
Party.order = {}   -- array of member records for the current group, you first

--- Match a sender to the roster name. Names should match exactly, but fall back to
--- the short name so a realm spelled differently can't hide a party member.
local function resolve(name)
    for _, m in ipairs(Party.order) do
        if m.name == name then return name end
    end
    for _, m in ipairs(Party.order) do
        if not m.isPlayer and not m.fake and QM.SameName(m.name, name) then return m.name end
    end
    return name
end
Party.Resolve = resolve

local function peer(name)
    name = resolve(name)
    local p = Party.peers[name]
    if not p then
        p = { quests = {}, completed = {}, asked = {} }
        Party.peers[name] = p
    end
    return p
end

---------------------------------------------------------------------------
-- Change notifications (debounced so a burst of messages redraws once)
---------------------------------------------------------------------------
local changePending = false
local function changed()
    if changePending then return end
    changePending = true
    C_Timer.After(0.2, function()
        changePending = false
        QM:Fire("QM_PARTY_CHANGED")
    end)
end
Party.NotifyChanged = changed

---------------------------------------------------------------------------
-- Roster
---------------------------------------------------------------------------
function Party:Rebuild()
    local order = {}
    order[1] = { name = QM.playerName or QM.FullName("player"), unit = "player", isPlayer = true }
    if IsInGroup() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = QM.FullName(unit)
                if name then order[#order + 1] = { name = name, unit = unit } end
            end
        end
    end
    if QM.Test and QM.Test:IsOn() then
        for _, fake in ipairs(QM.Test:Members(#order)) do order[#order + 1] = fake end
    end
    self.order = order
    -- peers heard from before they showed up in the roster: move them to the roster name
    for key, p in pairs(self.peers) do
        local name = resolve(key)
        if name ~= key and not self.peers[name] then
            self.peers[name] = p
            self.peers[key] = nil
        end
    end
    changed()
end

function Party:Members()
    return self.order
end

function Party:Partner()
    -- duo mode partner: the only other member of a two-person group
    if #self.order == 2 then return self.order[2] end
    return nil
end

function Party:Find(name)
    for _, m in ipairs(self.order) do
        if m.name == name then return m end
    end
    return nil
end

function Party:HasAddon(member)
    if member.isPlayer or member.fake then return true end
    local p = self.peers[member.name]
    return p and p.hasAddon or false
end

---------------------------------------------------------------------------
-- Quest knowledge
---------------------------------------------------------------------------

--- Returns quest record { state, objectives } if the member has the quest active, false if
--- they don't, or nil if we can't tell. Second return says whether objectives are known.
function Party:GetQuest(member, questID)
    if member.isPlayer then
        local q = QM.Log.active[questID]
        return q or false, true
    end
    local p = self.peers[member.name]
    if p and p.hasAddon then
        return p.quests[questID] or false, true
    end
    -- stock client fallback
    local ok, onQuest = pcall(C_QuestLog.IsUnitOnQuest, member.unit, questID)
    if ok and onQuest ~= nil then
        if onQuest then return { state = QM.Log.STATE_PROGRESS, objectives = {} }, false end
        return false, false
    end
    return nil, false
end

--- true / false, or nil when unknown.
function Party:IsCompleted(member, questID)
    if member.isPlayer then return QM.Log:IsCompleted(questID) end
    local p = self.peers[member.name]
    if member.fake then return p and p.completed[questID] or false end
    if not p or not p.hasAddon then return nil end
    return p.completed[questID]
end

--- Ask members with the addon about any of these quests we haven't asked about yet.
-- Requests from every chain on screen pile up here for a moment and go out together:
-- one question to the whole group instead of one per chain per player.
local wanted, flushPending = {}, false
local RETRY = 45 -- seconds before asking again about an id nobody answered

local function flushCompleted()
    flushPending = false
    local now = GetTime()
    local groupIds, groupSeen = {}, {}
    for _, m in ipairs(Party.order) do
        if not m.isPlayer and not m.fake then
            local p = Party.peers[m.name]
            if p and p.hasAddon then
                local need = {}
                for id in pairs(wanted) do
                    if p.completed[id] == nil and (not p.asked[id] or now - p.asked[id] > RETRY) then
                        p.asked[id] = now
                        need[#need + 1] = id
                    end
                end
                if #need > 0 then
                    if (p.proto or 1) >= 2 then
                        for _, id in ipairs(need) do
                            if not groupSeen[id] then groupSeen[id] = true; groupIds[#groupIds + 1] = id end
                        end
                    else
                        table.sort(need)
                        QM.Comm:QueryCompleted(m.name, need) -- older copy: the old way
                    end
                end
            end
        end
    end
    wipe(wanted)
    if #groupIds > 0 then QM.Comm:QueryCompletedGroup(groupIds) end
end

function Party:RequestCompleted(ids)
    for _, id in ipairs(ids) do wanted[id] = true end
    if flushPending then return end
    flushPending = true
    C_Timer.After(0.3, flushCompleted)
end

---------------------------------------------------------------------------
-- Level, class, position
---------------------------------------------------------------------------
function Party:Level(member)
    if member.fake then return member.level end
    return UnitLevel(member.unit) or 0
end

function Party:ClassID(member)
    if member.fake then return member.classID end
    local _, _, classID = UnitClass(member.unit)
    return classID
end

function Party:ClassFile(member)
    if member.fake then return member.classFile end
    local _, classFile = UnitClass(member.unit)
    return classFile
end

function Party:ZoneName(member)
    if member.fake then return member.zone end
    local mapID = C_Map.GetBestMapForUnit(member.unit)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or nil
end

local function unitPosition(unit)
    local ok, y, x, _, instance = pcall(UnitPosition, unit)
    if ok and type(x) == "number" and type(y) == "number" then return x, y, instance end
    return nil
end

--- Yards between you and the member, or nil if it can't be measured (other zone, instance).
function Party:Distance(member)
    if member.isPlayer then return 0 end
    if member.fake then return member.distance end
    local x1, y1, i1 = unitPosition("player")
    local x2, y2, i2 = unitPosition(member.unit)
    if x1 and x2 and i1 == i2 then
        return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
    end
    -- fallback through the map
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local a = C_Map.GetPlayerMapPosition(mapID, "player")
    local b = C_Map.GetPlayerMapPosition(mapID, member.unit)
    if not a or not b then return nil end
    local _, wa = C_Map.GetWorldPosFromMapPos(mapID, a)
    local _, wb = C_Map.GetWorldPosFromMapPos(mapID, b)
    if not wa or not wb then return nil end
    local dx, dy = wa.x - wb.x, wa.y - wb.y
    return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
QM:On("QM_LOGIN", function() Party:Rebuild() end)
QM:RegisterEvent("GROUP_ROSTER_UPDATE", function() Party:Rebuild() end)
QM:RegisterEvent("GROUP_LEFT", function()
    for name, p in pairs(Party.peers) do
        if not p.fake then Party.peers[name] = nil end
    end
    Party:Rebuild()
end)
QM:RegisterEvent("UNIT_QUEST_LOG_CHANGED", function(_, unit)
    if unit and unit ~= "player" then changed() end
end)
QM:RegisterEvent("UNIT_LEVEL", changed)
QM:On("QM_LOG_CHANGED", changed)

QM:On("QM_PEER_HELLO", function(_, sender, proto, version, quiet)
    local p = peer(sender)
    p.hasAddon = true
    p.quiet = quiet
    p.version = version
    p.proto = proto
    changed()
end)

QM:On("QM_PEER_SNAPSHOT", function(_, sender, quests)
    local p = peer(sender)
    p.hasAddon = true
    p.quests = quests
    changed()
end)

QM:On("QM_PEER_UPDATE", function(_, sender, quests)
    local p = peer(sender)
    p.hasAddon = true
    for id, q in pairs(quests) do p.quests[id] = q end
    changed()
end)

QM:On("QM_PEER_REMOVED", function(_, sender, questID, turnedIn)
    local p = peer(sender)
    p.quests[questID] = nil
    if turnedIn then p.completed[questID] = true end
    changed()
end)

QM:On("QM_PEER_COMPLETED", function(_, sender, result)
    local p = peer(sender)
    for id, done in pairs(result) do
        p.completed[id] = done
        p.asked[id] = nil
    end
    changed()
end)

QM:On("QM_PRINT_STATUS", function()
    if #Party.order < 2 then
        QM:Print("you're not in a group.")
        return
    end
    for _, m in ipairs(Party.order) do
        if m.fake then
            QM:Print(QM.ShortName(m.name) .. ": test mode player")
        elseif not m.isPlayer then
            local p = Party.peers[m.name]
            if p and p.hasAddon then
                QM:Print(QM.ShortName(m.name) .. ": Fellowstep " .. tostring(p.version) .. (p.quiet and " (companion mode)" or ""))
            else
                QM:Print(QM.ShortName(m.name) .. ": no Fellowstep (limited info)")
            end
        end
    end
end)
