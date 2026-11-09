-- Fellowstep: Chains
-- Builds quest chains from QuestieDB and works out each member's status on every step.

local _, QM = ...

local Chains = {}
QM.Chains = Chains

local DB, Q
local REQUIRED_CONTRACT = 4
local MAX_CHAIN_NODES = 24

Chains.ready = false
Chains.failed = nil

-- Step status values
local S = {
    DONE = "DONE",
    ACTIVE = "ACTIVE",
    READY = "READY",          -- ready to turn in
    AVAILABLE = "AVAILABLE",  -- can pick up now
    LEVEL = "LEVEL",          -- prereqs met, level too low
    BLOCKED = "BLOCKED",      -- an earlier step is missing
    OTHER = "OTHER",          -- took a mutually exclusive alternative
    SKIPPED = "SKIPPED",      -- optional breadcrumb, or passed by
    CLASS = "CLASS",          -- not for this class
    UNKNOWN = "UNKNOWN",
}
Chains.S = S

---------------------------------------------------------------------------
-- Index (built in small slices after login so it never hitches the game)
---------------------------------------------------------------------------
local children = {}   -- [questID] = { questID, ... } quests that list it as a prerequisite
local previous = {}   -- [questID] = { questID, ... } quests whose nextQuestInChain is it
local factionMask, raceMask

local INDEX_FIELDS = { "preQuestSingle", "preQuestGroup", "nextQuestInChain", "breadcrumbForQuestId" }

local function add(map, key, value)
    local list = map[key]
    if not list then list = {}; map[key] = list end
    list[#list + 1] = value
end

local function indexQuest(id)
    local v = Q.GetAll(id, INDEX_FIELDS)
    if not v then return end
    local single, group, nextId = v[1], v[2], v[3]
    if type(single) == "table" then
        for _, p in ipairs(single) do add(children, math.abs(p), id) end
    end
    if type(group) == "table" then
        for _, p in ipairs(group) do add(children, math.abs(p), id) end
    end
    if type(nextId) == "number" and nextId > 0 then add(previous, nextId, id) end
end

local function buildIndex()
    local ids = Q.GetAllIds()
    local i, total = 1, #ids
    local ticker
    ticker = C_Timer.NewTicker(0, function()
        local stop = math.min(i + 300, total)
        for k = i, stop do
            local ok, err = pcall(indexQuest, ids[k])
            if not ok then QM:Debug("index error", ids[k], err) end
        end
        i = stop + 1
        if i > total then
            ticker:Cancel()
            Chains.ready = true
            QM:Debug("chain index built:", total, "quests")
            QM:Fire("QM_CHAINS_READY")
        end
    end)
end

QM:On("QM_LOGIN", function()
    DB = _G.LibQuestieDB
    if not DB or not DB.Quest then
        Chains.failed = "QuestieDB isn't loaded, so quest chains are unavailable."
        QM:Print(Chains.failed)
        return
    end
    local ok, message = DB.RequireContract(REQUIRED_CONTRACT)
    if not ok then
        Chains.failed = message
        QM:Print(message)
        return
    end
    Q = DB.Quest
    local faction = UnitFactionGroup("player")
    factionMask = DB.Enum and DB.Enum.factionRaceMasks and DB.Enum.factionRaceMasks[faction]
    local _, _, raceID = UnitRace("player")
    if type(raceID) == "number" and raceID > 0 then raceMask = 2 ^ (raceID - 1) end
    C_Timer.After(3, buildIndex)
end)

---------------------------------------------------------------------------
-- Field helpers
---------------------------------------------------------------------------
local function field(id, name)
    local ok, value = pcall(Q[name], id)
    if ok then return value end
    return nil
end

-- Race masks can use bits above 32 (newer races), so avoid the 32-bit bit library here.
local function shareBit(a, b)
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then return true end
        a, b = math.floor(a / 2), math.floor(b / 2)
    end
    return false
end

-- Many starting-zone quests exist once per race (each race's own "The Great Outdoors", say).
-- Keep only the version meant for your race; fall back to your faction if the race is unknown.
local function forMyFaction(id)
    local races = field(id, "requiredRaces")
    if not races or races == 0 then return true end
    if raceMask then return shareBit(races, raceMask) end
    if not factionMask then return true end
    return shareBit(races, factionMask)
end

function Chains:QuestName(id)
    local name = Q and field(id, "name")
    if not name and C_QuestLog.GetTitleForQuestID then name = C_QuestLog.GetTitleForQuestID(id) end
    return name or ("Quest " .. id)
end

local HUB_CHILDREN = 3
local isHub
--- A quest that unlocks several separate follow-ups, like a zone's intro quest.
isHub = function(id)
    local kids = children[id]
    return kids ~= nil and #kids >= HUB_CHILDREN
end


---------------------------------------------------------------------------
-- Building a chain
---------------------------------------------------------------------------
local chainCache = {}  -- [questID] = chain

local function buildNode(id)
    local starter, starterKind
    local startedBy = field(id, "startedBy")
    if type(startedBy) == "table" then
        if startedBy[1] and startedBy[1][1] then starter, starterKind = startedBy[1][1], "npc"
        elseif startedBy[2] and startedBy[2][1] then starter, starterKind = startedBy[2][1], "object"
        elseif startedBy[3] and startedBy[3][1] then starter, starterKind = startedBy[3][1], "item" end
    end
    local exclusive = {}
    for _, x in ipairs(field(id, "exclusiveTo") or {}) do exclusive[#exclusive + 1] = x end
    local group, single = {}, {}
    for _, p in ipairs(field(id, "preQuestGroup") or {}) do group[#group + 1] = math.abs(p) end
    for _, p in ipairs(field(id, "preQuestSingle") or {}) do single[#single + 1] = math.abs(p) end
    return {
        id = id,
        name = Chains:QuestName(id),
        requiredLevel = field(id, "requiredLevel") or 0,
        questLevel = field(id, "questLevel"),
        requiredClasses = field(id, "requiredClasses") or 0,
        zone = field(id, "zoneOrSort"),
        preGroup = group,
        preSingle = single,
        exclusive = exclusive,
        nextId = field(id, "nextQuestInChain"),
        breadcrumbFor = field(id, "breadcrumbForQuestId"),
        starter = starter,
        starterKind = starterKind,
    }
end

--- The chain a quest belongs to: { key, title, zoneName, nodes = {...}, columns = { {node,...}, ... } }
function Chains:ForQuest(questID)
    if not Q then return nil end
    if chainCache[questID] then return chainCache[questID] end

    -- Walk only straight up (prerequisites) and straight down (follow-ups) from this quest,
    -- never sideways into siblings. A "hub" quest that unlocks many others (a zone's intro
    -- quest, say) is a boundary: going up we stop below it, going down we don't fan out from
    -- it. Without this, a starting zone where everything hangs off one intro quest turns into
    -- one giant chain.
    local seen, members = {}, {}
    local downSet = {}
    local function usable(id) return id == questID or (forMyFaction(id) and Q.Exists(id)) end
    local function addMember(id)
        if seen[id] or #members >= MAX_CHAIN_NODES or not usable(id) then return false end
        seen[id] = true
        members[#members + 1] = id
        return true
    end

    local function climb(id, depth)
        if depth > MAX_CHAIN_NODES then return end
        local parents = {}
        local function push(x) if type(x) == "number" and x > 0 then parents[#parents + 1] = x end end
        for _, p in ipairs(field(id, "preQuestSingle") or {}) do push(math.abs(p)) end
        for _, p in ipairs(field(id, "preQuestGroup") or {}) do push(math.abs(p)) end
        for _, p in ipairs(previous[id] or {}) do push(p) end
        for _, p in ipairs(parents) do
            if not isHub(p) and addMember(p) then climb(p, depth + 1) end
        end
        -- breadcrumbs lead into this quest; include them but don't climb above them
        for _, b in ipairs(field(id, "breadcrumbs") or {}) do addMember(b) end
    end

    local function descend(id, depth)
        downSet[id] = true
        if depth > MAX_CHAIN_NODES then return end
        local kids = {}
        local nextId = field(id, "nextQuestInChain")
        if type(nextId) == "number" and nextId > 0 then kids[#kids + 1] = nextId end
        local crumbFor = field(id, "breadcrumbForQuestId")
        if type(crumbFor) == "number" and crumbFor > 0 then kids[#kids + 1] = crumbFor end
        if not isHub(id) then
            for _, c in ipairs(children[id] or {}) do kids[#kids + 1] = c end
        end
        for _, c in ipairs(kids) do
            if addMember(c) then
                -- a pick-one alternative sits beside its partner
                for _, x in ipairs(field(c, "exclusiveTo") or {}) do
                    if addMember(x) then downSet[x] = true end
                end
                descend(c, depth + 1)
            end
        end
    end

    addMember(questID)
    climb(questID, 1)
    descend(questID, 1)

    local nodes, byId = {}, {}
    for _, id in ipairs(members) do
        local node = buildNode(id)
        nodes[#nodes + 1] = node
        byId[id] = node
    end

    -- predecessor lists inside the chain
    for _, node in ipairs(nodes) do node.parents = {} end
    local function link(fromId, toNode)
        if byId[fromId] and fromId ~= toNode.id then table.insert(toNode.parents, fromId) end
    end
    for _, node in ipairs(nodes) do
        for _, p in ipairs(node.preGroup) do link(p, node) end
        for _, p in ipairs(node.preSingle) do link(p, node) end
        if node.nextId and byId[node.nextId] then link(node.id, byId[node.nextId]) end
        if node.breadcrumbFor and byId[node.breadcrumbFor] then link(node.id, byId[node.breadcrumbFor]) end
    end

    -- depth = longest path from a start; bounded passes guard against bad data loops
    for _, node in ipairs(nodes) do node.depth = 0 end
    for _ = 1, #nodes do
        local moved = false
        for _, node in ipairs(nodes) do
            for _, p in ipairs(node.parents) do
                local d = byId[p].depth + 1
                if d > node.depth and d <= #nodes then node.depth = d; moved = true end
            end
        end
        if not moved then break end
    end

    local columns, maxDepth = {}, 0
    for _, node in ipairs(nodes) do
        maxDepth = math.max(maxDepth, node.depth)
        columns[node.depth + 1] = columns[node.depth + 1] or {}
        table.insert(columns[node.depth + 1], node)
    end
    local flat = {}
    for d = 1, maxDepth + 1 do
        local col = columns[d]
        if col then
            table.sort(col, function(a, b) return a.id < b.id end)
            for _, n in ipairs(col) do flat[#flat + 1] = n end
        end
    end

    -- mark pick-one groups so the UI can draw a shared header
    for _, node in ipairs(flat) do
        for _, x in ipairs(node.exclusive) do
            if byId[x] then node.pickOne = true end
        end
    end

    local key = members[1]
    for _, id in ipairs(members) do key = math.min(key, id) end
    local root
    for _, node in ipairs(flat) do
        if not node.breadcrumbFor then root = node; break end
    end
    root = root or flat[1]
    local zoneName
    local zone = root and root.zone
    if zone and zone > 0 and C_Map.GetAreaInfo then zoneName = C_Map.GetAreaInfo(zone) end

    local levels = {}
    for _, n in ipairs(flat) do
        if n.requiredLevel and n.requiredLevel > 0 then levels[#levels + 1] = n.requiredLevel end
    end
    table.sort(levels)

    local chain = {
        key = key,
        title = root and root.name or "?",
        zoneName = zoneName or "Other",
        steps = flat,
        byId = byId,
        minLevel = levels[1],
        maxLevel = levels[#levels],
    }
    -- quests further down see the same chain; ancestors build their own view
    for id in pairs(downSet) do chainCache[id] = chain end
    chainCache[questID] = chain
    return chain
end

--- Every chain touched by a quest any group member currently has.
function Chains:ForGroup()
    local questIds = {}
    for id in pairs(QM.Log.active) do questIds[id] = true end
    for _, m in ipairs(QM.Party:Members()) do
        if not m.isPlayer then
            local p = QM.Party.peers[m.name]
            if p and p.hasAddon then
                for id in pairs(p.quests) do questIds[id] = true end
            end
        end
    end
    local list, seen = {}, {}
    for id in pairs(questIds) do
        local chain = self:ForQuest(id)
        if chain and not seen[chain.key] then
            seen[chain.key] = true
            list[#list + 1] = chain
        end
    end
    table.sort(list, function(a, b)
        if a.zoneName ~= b.zoneName then return a.zoneName < b.zoneName end
        return a.title < b.title
    end)
    return list
end

function Chains:InvalidateCache()
    wipe(chainCache)
end

---------------------------------------------------------------------------
-- Status of one member on one step
---------------------------------------------------------------------------
local function classAllowed(mask, classID)
    if not mask or mask == 0 or not classID then return true end
    return bit.band(mask, bit.lshift(1, classID - 1)) ~= 0
end

--- Returns status, info. info may hold: quest (active record), objectivesKnown, level.
function Chains:Status(chain, step, member)
    local Party = QM.Party
    local id = step.id
    local hasAddon = Party:HasAddon(member)

    local done = Party:IsCompleted(member, id)
    if done then return S.DONE end

    local q, known = Party:GetQuest(member, id)
    if q then
        if q.state == QM.Log.STATE_READY then return S.READY, { quest = q, objectivesKnown = known } end
        return S.ACTIVE, { quest = q, objectivesKnown = known }
    end

    -- Their copy hasn't told us yet whether they finished this one. Guessing "not started"
    -- here made a finished chain look like everyone was on step one, so say we don't know.
    if done == nil and hasAddon and not member.isPlayer and not member.fake then
        return S.UNKNOWN
    end

    local function doneOrActive(otherId)
        if Party:IsCompleted(member, otherId) then return true end
        local other = Party:GetQuest(member, otherId)
        return other and true or false
    end

    for _, x in ipairs(step.exclusive) do
        if doneOrActive(x) then return S.OTHER end
    end
    if step.breadcrumbFor and doneOrActive(step.breadcrumbFor) then return S.SKIPPED end
    if step.nextId and chain.byId[step.nextId] and doneOrActive(step.nextId) then return S.SKIPPED end

    if not classAllowed(step.requiredClasses, Party:ClassID(member)) then return S.CLASS end

    if not hasAddon then return S.UNKNOWN end

    -- prerequisites (remember which one is missing, so we can name it)
    local missing
    for _, p in ipairs(step.preGroup) do
        if not missing and not Party:IsCompleted(member, p) then missing = p end
    end
    if not missing and #step.preSingle > 0 then
        local any = false
        for _, p in ipairs(step.preSingle) do
            if Party:IsCompleted(member, p) then any = true end
        end
        if not any then missing = step.preSingle[1] end
    end
    if missing then return S.BLOCKED, { missing = missing, missingName = self:QuestName(missing) } end

    local level = Party:Level(member)
    if step.requiredLevel and level < step.requiredLevel then
        return S.LEVEL, { level = step.requiredLevel }
    end
    return S.AVAILABLE
end

--- Every quest id the status of this chain depends on.
function Chains:AllIds(chain)
    if chain.allIds then return chain.allIds end
    local ids, seen = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    for _, step in ipairs(chain.steps) do
        add(step.id)
        for _, p in ipairs(step.preGroup) do add(p) end
        for _, p in ipairs(step.preSingle) do add(p) end
        for _, x in ipairs(step.exclusive) do add(x) end
        add(step.nextId)
        add(step.breadcrumbFor)
    end
    chain.allIds = ids
    return ids
end

--- Ask everyone with the addon which of this chain's quests they've finished.
function Chains:AskAbout(chain)
    QM.Party:RequestCompleted(self:AllIds(chain))
end

--- Can this member ever do any quest in the chain? (Class-only chains are not for everyone.)
function Chains:CanDo(chain, member)
    local classID = QM.Party:ClassID(member)
    for _, step in ipairs(chain.steps) do
        if classAllowed(step.requiredClasses, classID) then return true end
    end
    return false
end

--- The members to compare in this chain: you first, then everyone else who can do it.
--- You stay in even when it isn't for you, so you can still see where the others are.
function Chains:MembersFor(chain)
    local out = {}
    for _, m in ipairs(QM.Party:Members()) do
        if m.isPlayer or self:CanDo(chain, m) then out[#out + 1] = m end
    end
    return out
end

--- Quests outside the chain that a step needs first: { id, name, child = stepId }.
function Chains:OutsidePrereqs(chain)
    local out, seen = {}, {}
    for _, step in ipairs(chain.steps) do
        for _, list in ipairs({ step.preGroup, step.preSingle }) do
            for _, p in ipairs(list) do
                if not chain.byId[p] and not seen[p] then
                    seen[p] = true
                    out[#out + 1] = { id = p, name = self:QuestName(p), child = step.id }
                end
            end
        end
    end
    return out
end

local function finishedStatus(status)
    return status == S.DONE or status == S.SKIPPED or status == S.OTHER or status == S.CLASS
end

--- Where you stand in a chain compared with the rest of the group.
--- Returns kind ("same", "behind", "ahead", "unknown" or nil when there's nobody to
--- compare with), how many steps, and a per-member list { member, count, where }.
function Chains:Standing(chain)
    local members = QM.Party:Members()
    local rows, mine = {}, 0
    local unknown, lo, hi = false, nil, nil
    for _, m in ipairs(members) do
        if not m.isPlayer and not self:CanDo(chain, m) then
            -- a class quest they can't take: leave them out of the comparison
        elseif QM.Party:HasAddon(m) then
            local count, where, memberUnknown = 0, nil, false
            for _, step in ipairs(chain.steps) do
                local st = self:Status(chain, step, m)
                if finishedStatus(st) then count = count + 1 end
                if st == S.UNKNOWN then memberUnknown = true end
                if not where and (st == S.ACTIVE or st == S.READY) then where = step.name end
            end
            rows[#rows + 1] = { member = m, count = count, where = where, unknown = memberUnknown }
            if m.isPlayer then
                mine = count
            else
                if memberUnknown then unknown = true end
                lo = math.min(lo or count, count)
                hi = math.max(hi or count, count)
            end
        else
            rows[#rows + 1] = { member = m, noAddon = true }
        end
    end
    if not lo then return nil, 0, rows end
    if unknown then return "unknown", 0, rows end
    if hi > mine then return "behind", hi - mine, rows end
    if lo < mine then return "ahead", mine - lo, rows end
    return "same", 0, rows
end

--- Which prerequisite (by name) is the member missing? For "Missing X" sublabels.
function Chains:MissingPrereq(step, member)
    for _, p in ipairs(step.preGroup) do
        if not QM.Party:IsCompleted(member, p) then return self:QuestName(p) end
    end
    return nil
end

---------------------------------------------------------------------------
-- Where a step starts (for waypoints)
---------------------------------------------------------------------------
local areaToMap, subZoneParent

local function decodeSupport(text)
    if type(text) == "table" then return text end
    if type(text) ~= "string" then return {} end
    local fn = loadstring(text)
    if not fn then return {} end
    local ok, result = pcall(fn)
    return ok and type(result) == "table" and result or {}
end

local function loadZoneMaps()
    if areaToMap then return end
    areaToMap, subZoneParent = {}, {}
    local zone = DB and DB.Support and DB.Support.Get and DB.Support.Get("ZoneDB")
    local private = zone and zone.private
    if not private then return end
    for k, v in pairs(decodeSupport(private.areaIdToUiMapId)) do areaToMap[k] = v end
    for k, v in pairs(decodeSupport(private.areaIdToUiMapIdOverride)) do areaToMap[k] = v end
    for k, v in pairs(decodeSupport(private.subZoneToParentZone)) do subZoneParent[k] = v end
    for k, v in pairs(decodeSupport(private.subZoneToParentZoneOverride)) do subZoneParent[k] = v end
end

local function uiMapForArea(areaId)
    loadZoneMaps()
    local mapID = areaToMap[areaId]
    if (not mapID or mapID == 0) and subZoneParent[areaId] then mapID = areaToMap[subZoneParent[areaId]] end
    if mapID == 0 then return nil end
    return mapID
end

--- { name, uiMapID, x, y } (x, y in 0-100) for the step's quest giver, or nil.
function Chains:StarterLocation(step)
    if not DB or not step.starter then return nil end
    local entity = (step.starterKind == "npc" and DB.Npc) or (step.starterKind == "object" and DB.Object)
    if not entity then return nil end
    local okName, name = pcall(entity.name, step.starter)
    local okSpawns, spawns = pcall(entity.spawns, step.starter)
    if not okSpawns or type(spawns) ~= "table" then return { name = okName and name or nil } end
    local area = (step.zone and step.zone > 0 and spawns[step.zone]) and step.zone or next(spawns)
    local points = area and spawns[area]
    local point = points and points[1]
    if not point or point[1] == -1 then return { name = okName and name or nil } end
    return {
        name = okName and name or nil,
        uiMapID = uiMapForArea(area),
        areaName = C_Map.GetAreaInfo and C_Map.GetAreaInfo(area) or nil,
        x = point[1],
        y = point[2],
    }
end

-- chains built before the index finished would be missing follow-ups
QM:On("QM_CHAINS_READY", function() Chains:InvalidateCache() end)
