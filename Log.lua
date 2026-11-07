-- Fellowstep: Log
-- A snapshot of this character's quest log, kept current from native events.

local _, QM = ...

local Log = {}
QM.Log = Log

Log.active = {}  -- [questID] = { title, level, state, objectives = { {have, need, done, text}, ... } }

-- Quest states shared with the protocol
Log.STATE_PROGRESS = 0
Log.STATE_READY = 1
Log.STATE_FAILED = 2

local function readObjectives(questID)
    local list = {}
    local objectives = C_QuestLog.GetQuestObjectives(questID)
    if type(objectives) ~= "table" then return list end
    for i, o in ipairs(objectives) do
        list[i] = {
            have = tonumber(o.numFulfilled) or 0,
            need = tonumber(o.numRequired) or 0,
            done = o.finished and true or false,
            text = o.text,
        }
    end
    return list
end

local function readState(questID)
    if C_QuestLog.IsFailed and C_QuestLog.IsFailed(questID) then return Log.STATE_FAILED end
    if C_QuestLog.ReadyForTurnIn and C_QuestLog.ReadyForTurnIn(questID) then return Log.STATE_READY end
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID) then return Log.STATE_READY end
    return Log.STATE_PROGRESS
end

local function sameQuest(a, b)
    if not a or not b then return false end
    if a.state ~= b.state or #a.objectives ~= #b.objectives then return false end
    for i = 1, #a.objectives do
        local x, y = a.objectives[i], b.objectives[i]
        if x.have ~= y.have or x.need ~= y.need or x.done ~= y.done then return false end
    end
    return true
end

--- Rescan the native quest log and report what changed.
function Log:Scan()
    local fresh = {}
    local n = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID and info.questID > 0 and not info.isHidden and not info.isTask then
            local id = info.questID
            fresh[id] = {
                title = info.title,
                level = info.level,
                state = readState(id),
                objectives = readObjectives(id),
            }
        end
    end

    local changed, removed = {}, {}
    for id, q in pairs(fresh) do
        if not sameQuest(q, self.active[id]) then changed[#changed + 1] = id end
    end
    for id in pairs(self.active) do
        if not fresh[id] then removed[#removed + 1] = id end
    end
    self.active = fresh
    if #changed > 0 or #removed > 0 then
        QM:Fire("QM_LOG_CHANGED", changed, removed)
    end
end

function Log:Has(questID)
    return self.active[questID] ~= nil
end

function Log:IsCompleted(questID)
    return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
end

--- Protocol encoding for one quest: "id:state:have/need.have/need"
function Log:Encode(questID)
    local q = self.active[questID]
    if not q then return nil end
    local objs = {}
    for i, o in ipairs(q.objectives) do
        objs[i] = o.have .. "/" .. o.need
    end
    return questID .. ":" .. q.state .. ":" .. table.concat(objs, ".")
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local scanPending = false
local function requestScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(0.3, function()
        scanPending = false
        Log:Scan()
    end)
end

QM:RegisterEvent("QUEST_LOG_UPDATE", requestScan)
QM:RegisterEvent("PLAYER_ENTERING_WORLD", requestScan)

QM:RegisterEvent("QUEST_ACCEPTED", function(_, questID)
    requestScan()
    if questID then QM:Fire("QM_QUEST_ACCEPTED", questID) end
end)

QM:RegisterEvent("QUEST_TURNED_IN", function(_, questID)
    requestScan()
    if questID then QM:Fire("QM_QUEST_TURNED_IN", questID) end
end)

QM:RegisterEvent("QUEST_REMOVED", function(_, questID)
    requestScan()
end)
