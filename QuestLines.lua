-- Fellowstep: QuestLines
-- Quest chain data for retail, where QuestieDB has no data. Blizzard's own quest lines
-- (the storylines the world map shows) tell us which quests form a chain and in what
-- order. This file answers the same questions Chains asks QuestieDB, so Chains doesn't
-- need to know which one it is talking to.
--
-- Unlike QuestieDB we can't list every quest up front: chains are learned as quests turn
-- up (your log, the group's logs, the storylines on the map you're in).

local _, QM = ...

local QL = {}
QM.QuestLines = QL

local lineOf = {}     -- [questID] = questLineID, or false when it isn't in one (retried later)
local triedAt = {}    -- [questID] = time of the last failed lookup
local lines = {}      -- [questLineID] = { id, name, quests = { questID, ... }, pos = { [questID] = index }, mapID }
local where = {}      -- [questID] = { mapID, x, y } (x, y 0-1) where the quest starts, when the map said
local RETRY = 30

--- True on clients that have quest lines.
function QL.Available()
    return type(C_QuestLine) == "table" and type(C_QuestLine.GetQuestLineInfo) == "function"
        and type(C_QuestLine.GetQuestLineQuests) == "function"
end

---------------------------------------------------------------------------
-- Learning
---------------------------------------------------------------------------
local changed = false
local function changedSoon()
    if changed then return end
    changed = true
    C_Timer.After(1, function()
        changed = false
        QM:Fire("QM_CHAINS_READY")
    end)
end

local function wantName(id)
    if C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id) then return end
    if C_QuestLog.RequestLoadQuestByID then pcall(C_QuestLog.RequestLoadQuestByID, id) end
end

local function learnLine(lineID, name, mapID)
    if type(lineID) ~= "number" or lineID <= 0 then return nil end
    local line = lines[lineID]
    if line then
        if not line.name and name then line.name = name end
        if not line.mapID and mapID and mapID > 0 then line.mapID = mapID end
        return line
    end
    local ok, quests = pcall(C_QuestLine.GetQuestLineQuests, lineID)
    if not ok or type(quests) ~= "table" or #quests == 0 then return nil end
    line = { id = lineID, name = name, quests = {}, pos = {}, mapID = mapID and mapID > 0 and mapID or nil }
    for _, q in ipairs(quests) do
        if type(q) == "number" and not line.pos[q] then
            line.quests[#line.quests + 1] = q
            line.pos[q] = #line.quests
            -- a quest in two lines keeps the first one we saw
            if not lineOf[q] then lineOf[q] = lineID end
            wantName(q)
        end
    end
    lines[lineID] = line
    changedSoon()
    return line
end

local function mapForQuest(id)
    local m
    if C_TaskQuest and C_TaskQuest.GetQuestZoneID then m = C_TaskQuest.GetQuestZoneID(id) end
    if (not m or m == 0) and GetQuestUiMapID then m = GetQuestUiMapID(id) end
    if not m or m == 0 then m = C_Map.GetBestMapForUnit("player") end
    return m
end

local function remember(info, mapID)
    if type(info) ~= "table" or not info.questLineID then return nil end
    local line = learnLine(info.questLineID, info.questLineName, info.startMapID or mapID)
    if info.questID and info.x and info.y and (info.x > 0 or info.y > 0) and not where[info.questID] then
        where[info.questID] = { mapID = mapID, x = info.x, y = info.y }
    end
    return line
end

--- The quest line a quest belongs to, looked up once (and again later if the game didn't know yet).
local function lineFor(id)
    if type(id) ~= "number" then return nil end
    local known = lineOf[id]
    if known then return lines[known] end
    if known == false and GetTime() - (triedAt[id] or 0) < RETRY then return nil end
    local mapID = mapForQuest(id)
    local ok, info = pcall(C_QuestLine.GetQuestLineInfo, id, mapID)
    local line = ok and remember(info, mapID)
    if line and line.pos[id] then
        lineOf[id] = line.id
        return line
    end
    lineOf[id], triedAt[id] = false, GetTime()
    wantName(id)
    return nil
end

--- Read the storylines the current map offers.
local function scanMap()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or not C_QuestLine.GetAvailableQuestLines then return end
    local ok, list = pcall(C_QuestLine.GetAvailableQuestLines, mapID)
    if ok and type(list) == "table" then
        for _, info in ipairs(list) do remember(info, mapID) end
    end
end

local function requestMap()
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID and C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, mapID) end
    scanMap()
end

---------------------------------------------------------------------------
-- The questions Chains asks (same names and shapes as QuestieDB's Quest API)
---------------------------------------------------------------------------
local Quest = {}
QL.Quest = Quest

local function lineAndPos(id)
    local line = lineFor(id)
    return line, line and line.pos[id]
end

function Quest.GetAllIds() return {} end -- nothing to index up front

function Quest.Exists(id)
    return lineFor(id) ~= nil
end

function Quest.name(id)
    return C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id) or nil
end

function Quest.preQuestSingle(id)
    local line, i = lineAndPos(id)
    if line and i and i > 1 then return { line.quests[i - 1] } end
    return {}
end

function Quest.nextQuestInChain(id)
    local line, i = lineAndPos(id)
    return line and i and line.quests[i + 1] or 0
end

function Quest.questLineName(id)
    local line = lineFor(id)
    return line and line.name or nil
end

function Quest.uiMapID(id)
    local line = lineFor(id)
    local w = where[id]
    return (w and w.mapID) or (line and line.mapID) or nil
end

function Quest.requiredLevel() return 0 end -- retail scales quests to you
function Quest.requiredClasses() return 0 end
function Quest.requiredRaces() return 0 end
function Quest.preQuestGroup() return {} end
function Quest.exclusiveTo() return {} end
function Quest.breadcrumbs() return nil end
function Quest.breadcrumbForQuestId() return nil end
function Quest.startedBy() return nil end
function Quest.zoneOrSort() return nil end
function Quest.questLevel() return nil end

function Quest.GetAll(id, fields)
    local out = {}
    for i, f in ipairs(fields) do
        local fn = Quest[f]
        out[i] = fn and fn(id) or nil
    end
    return out
end

--- { uiMapID, x, y } (x, y 0-100) where the quest starts, when the map told us.
function QL.StartLocation(id)
    local w = where[id]
    if not w or not w.mapID then return nil end
    return { uiMapID = w.mapID, x = w.x * 100, y = w.y * 100 }
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "QUESTLINE_UPDATE" then
        scanMap()
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        local id, ok = ...
        if ok and (lineOf[id] or lineOf[id] == false) then changedSoon() end
    else
        requestMap()
    end
end)

function QL.Start()
    if not QL.Available() then return false end
    for _, e in ipairs({ "QUESTLINE_UPDATE", "QUEST_DATA_LOAD_RESULT", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
        pcall(frame.RegisterEvent, frame, e)
    end
    requestMap()
    return true
end
