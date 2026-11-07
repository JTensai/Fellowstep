-- Fellowstep: Test mode
-- Fills the group with pretend players whose quests are built from your own character's,
-- with deliberate differences: one is behind, one matches you, one is ahead, one is off
-- doing other quests. Lets you try every screen while playing solo.

local _, QM = ...

local Test = {}
QM.Test = Test

local FAKES = {
    { name = "Brynn-Test", classID = 1, classFile = "WARRIOR", levelOffset = -2, distance = 28,  offsets = { -1, -2, -1 } },
    { name = "Kel-Test",   classID = 8, classFile = "MAGE",    levelOffset = 0,  distance = 12,  offsets = { 0, 0, -1 } },
    { name = "Toma-Test",  classID = 3, classFile = "HUNTER",  levelOffset = 1,  distance = 64,  offsets = { 1, 0, 1 } },
    { name = "Wren-Test",  classID = 5, classFile = "PRIEST",  levelOffset = -1, distance = 240, offsets = { "off", -1, "off" } },
}

function Test:IsOn()
    return QM.char and QM.char.testMode and true or false
end

--- Pretend members to append after the real ones (realCount includes you).
function Test:Members(realCount)
    local wanted = math.max(2, math.min(5, QM.char.testSize or 5))
    local out = {}
    local myLevel = UnitLevel("player") or 1
    local zone
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    zone = info and info.name or "?"
    for i = 1, wanted - realCount do
        local def = FAKES[i]
        if not def then break end
        out[#out + 1] = {
            name = def.name,
            fake = true,
            classID = def.classID,
            classFile = def.classFile,
            level = math.max(1, myLevel + def.levelOffset),
            distance = def.distance,
            zone = zone,
            fakeIndex = i,
        }
    end
    return out
end

local function copyObjectives(q, fraction)
    local list = {}
    for i, o in ipairs(q and q.objectives or {}) do
        local have = math.floor(o.need * fraction + 0.5)
        list[i] = { have = have, need = o.need, done = have >= o.need }
    end
    if #list == 0 then list[1] = { have = math.floor(8 * fraction), need = 8, done = fraction >= 1 } end
    return list
end

--- Rebuild every pretend player's quest data from your current log.
function Test:Generate()
    for name, p in pairs(QM.Party.peers) do
        if p.fake then QM.Party.peers[name] = nil end
    end
    if not self:IsOn() then return end
    local Chains = QM.Chains
    if not Chains.ready then return end

    local peers = {}
    for i, def in ipairs(FAKES) do
        peers[i] = { fake = true, hasAddon = true, version = "test", quests = {}, completed = {}, asked = {} }
        QM.Party.peers[def.name] = peers[i]
    end

    local seen, chainIndex = {}, 0
    local me = { isPlayer = true, name = QM.playerName, unit = "player" }
    for questID in pairs(QM.Log.active) do
        local chain = Chains:ForQuest(questID)
        if chain and not seen[chain.key] then
            seen[chain.key] = true
            chainIndex = chainIndex + 1
            -- where you are in this chain: your active step, or the first one not done
            local pos
            for k, step in ipairs(chain.steps) do
                if QM.Log.active[step.id] then pos = k break end
            end
            if not pos then
                pos = #chain.steps + 1
                for k, step in ipairs(chain.steps) do
                    if not QM.Log:IsCompleted(step.id) then pos = k break end
                end
            end
            for i, def in ipairs(FAKES) do
                local p = peers[i]
                local offset = def.offsets[(chainIndex - 1) % #def.offsets + 1]
                if offset == "off" then
                    -- not on this chain at all, but has something you could pick up
                    for _, step in ipairs(chain.steps) do
                        if not QM.Log.active[step.id] and Chains:Status(chain, step, me) == Chains.S.AVAILABLE then
                            p.quests[step.id] = { state = QM.Log.STATE_PROGRESS, objectives = copyObjectives(nil, 0.25) }
                            break
                        end
                    end
                else
                    local target = math.max(1, math.min(#chain.steps + 1, pos + offset))
                    for k = 1, target - 1 do
                        local step = chain.steps[k]
                        local taken = false
                        for _, x in ipairs(step.exclusive) do if p.completed[x] then taken = true end end
                        if not taken and not step.breadcrumbFor then p.completed[step.id] = true end
                    end
                    local step = chain.steps[target]
                    if step then
                        local mine = QM.Log.active[step.id]
                        local fraction = ({ 0.3, 0.6, 1, 0.5 })[i]
                        p.quests[step.id] = {
                            state = fraction >= 1 and QM.Log.STATE_READY or QM.Log.STATE_PROGRESS,
                            objectives = copyObjectives(mine, fraction),
                        }
                    end
                end
            end
        end
    end
    QM.Party.NotifyChanged()
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
local pending = false
local function regenerate()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        Test:Generate()
        QM.Party:Rebuild()
    end)
end

function Test:SetOn(on)
    QM.char.testMode = on and true or false
    QM:Print(on and "test mode on: pretend players fill your group." or "test mode off.")
    regenerate()
end

QM:On("QM_LOG_CHANGED", function() if Test:IsOn() then regenerate() end end)
QM:On("QM_CHAINS_READY", function() if Test:IsOn() then regenerate() end end)
QM:On("QM_TEST_CHANGED", regenerate)
