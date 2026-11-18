-- Fellowstep: GrailData
-- Quest chain data for retail from the Grail addon (optional). Grail keeps a code string
-- per quest ("FA L1 A:963 T:963 P:123+456 O:239 ..."); we read the parts Chains needs
-- (prerequisites, breadcrumbs, pick-one alternatives, faction) and answer with the same
-- names and shapes as QuestieDB's Quest API, so Chains doesn't care which one it talks to.
-- Names, levels and quest giver spots come from Grail's own functions.

local _, QM = ...

local GD = {}
QM.GrailData = GD

local G -- the Grail addon object
local myFaction

--- True when Grail is loaded and has quest data worth using (its retail data; on Forever
--- it has almost no prerequisites, so QuestieDB or the storylines do better there).
function GD.Available()
    local grail = _G.Grail
    if type(grail) ~= "table" or type(grail.questCodes) ~= "table" then return false end
    if (select(4, GetBuildInfo()) or 0) < 100000 then return false end
    return next(grail.questCodes) ~= nil
end

---------------------------------------------------------------------------
-- Reading Grail's code strings
---------------------------------------------------------------------------
local function exists(id)
    return type(id) == "number" and G.questCodes[id] ~= nil
end

local function idList(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for n in text:gmatch("%d+") do
        local id = tonumber(n)
        if exists(id) then out[#out + 1] = id end
    end
    return out
end

-- One prerequisite item: a quest that has to be turned in (bare id, or A/C/E codes).
-- Other codes (reputation, level, items, "must be in your log", ...) aren't chain links.
local function prereqQuest(item)
    local id = tonumber(item:match("^[ACE]?(%d+)$") or "")
    if exists(id) then return id end
    return nil
end

--- P: pattern -> group (all of these), single (any one of these).
--- "," separates alternatives, "+" joins requirements, "|" is a choice inside one requirement.
local function parsePrereqs(text)
    local group, single = {}, {}
    if type(text) ~= "string" or text == "" then return group, single end
    -- qualified forms ("a:b;c:d") hold alternatives for special cases: use the first, plain part
    text = text:match("^[^;]*") or ""
    text = text:match("^[^:]*") or ""
    local alternatives = {}
    for alt in text:gmatch("[^,]+") do
        local needs = {}
        for need in alt:gmatch("[^+]+") do
            local id = prereqQuest(need:match("^[^|]*") or "")
            if id then needs[#needs + 1] = id end
        end
        if #needs > 0 then alternatives[#alternatives + 1] = needs end
    end
    if #alternatives == 1 then
        group = alternatives[1]
    else
        for _, needs in ipairs(alternatives) do single[#single + 1] = needs[1] end
    end
    return group, single
end

local function parse(id)
    local text = G.questCodes[id]
    if type(text) ~= "string" then return nil end
    local c = {}
    for token in text:gmatch("%S+") do
        local key, value = token:match("^(%u%u?):(.*)$")
        if key then
            c[key] = value
        elseif token == "FA" or token == "FH" then
            c.F = token:sub(2)
        end
    end
    local q = {}
    q.group, q.single = parsePrereqs(c.P)
    q.breadcrumbs = idList(c.O)
    q.breadcrumbFor = idList(c.B)[1]
    q.exclusive = idList(c.I)
    q.faction = c.F
    return q
end

local cache, cached = {}, 0
local function info(id)
    local q = cache[id]
    if q ~= nil then return q or nil end
    q = parse(id) or false
    if cached > 3000 then wipe(cache); cached = 0 end
    cache[id], cached = q, cached + 1
    return q or nil
end

local function forMe(q)
    return not q.faction or not myFaction or q.faction == myFaction
end

---------------------------------------------------------------------------
-- The questions Chains asks
---------------------------------------------------------------------------
local Quest = {}
GD.Quest = Quest

function Quest.GetAllIds()
    local ids = {}
    for id in pairs(G.questCodes) do
        if type(id) == "number" and id > 0 then ids[#ids + 1] = id end
    end
    return ids
end

function Quest.Exists(id)
    local q = exists(id) and info(id)
    return q and forMe(q) or false
end

function Quest.name(id)
    local ok, name = pcall(G.QuestName, G, id)
    if ok and type(name) == "string" then return name end
    return C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id) or nil
end

function Quest.requiredLevel(id)
    local ok, level = pcall(G.QuestLevelRequired, G, id)
    return ok and type(level) == "number" and level or 0
end

function Quest.preQuestGroup(id) local q = info(id); return q and q.group or {} end
function Quest.preQuestSingle(id) local q = info(id); return q and q.single or {} end
function Quest.breadcrumbs(id) local q = info(id); return q and q.breadcrumbs or nil end
function Quest.breadcrumbForQuestId(id) local q = info(id); return q and q.breadcrumbFor or nil end
function Quest.exclusiveTo(id) local q = info(id); return q and q.exclusive or {} end
function Quest.nextQuestInChain() return 0 end -- Grail only knows "needs", not "leads to"
function Quest.requiredClasses() return 0 end
function Quest.requiredRaces() return 0 end
function Quest.startedBy() return nil end
function Quest.zoneOrSort() return nil end
function Quest.questLevel() return nil end

--- Where the quest giver stands: { name, uiMapID, x, y } (x, y 0-100), or nil.
function GD.StartLocation(id)
    local ok, list = pcall(G.QuestLocationsAccept, G, id, false, false)
    if not ok or type(list) ~= "table" then return nil end
    local here = C_Map.GetBestMapForUnit("player")
    local pick
    for _, npc in ipairs(list) do
        if type(npc) == "table" and type(npc.mapArea) == "number" and npc.mapArea > 0 and npc.x and npc.y then
            if not pick or npc.mapArea == here then pick = npc end
        end
    end
    if not pick then return nil end
    local okName, name = pcall(G.NPCName, G, pick.id)
    return { name = okName and name or nil, uiMapID = pick.mapArea, x = tonumber(pick.x), y = tonumber(pick.y) }
end

function Quest.uiMapID(id)
    local loc = GD.StartLocation(id)
    return loc and loc.uiMapID or nil
end

function Quest.GetAll(id, fields)
    local out = {}
    for i, f in ipairs(fields) do
        local fn = Quest[f]
        if fn then out[i] = fn(id) end
    end
    return out
end

function GD.Start()
    if not GD.Available() then return false end
    G = _G.Grail
    myFaction = UnitFactionGroup("player") == "Horde" and "H" or "A"
    return true
end
