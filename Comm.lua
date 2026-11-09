-- Fellowstep: Comm
-- Our own small party protocol over hidden addon messages.
--
-- Message types (fields separated by ";"):
--   H;proto;version;quiet      hello, sent on joining a group and answered once per peer
--   R                          please send me your full quest log
--   S;seq;i;n;entry;entry...   full quest log snapshot, chunk i of n
--   A;entry;entry...           quests that were added or changed
--   X;questID;reason           quest left the log (reason "t" turned in, "a" anything else)
--   Q;req;id,id,...            which of these quests have you completed? (whispered)
--   C;req;id,id,...            the ones I have completed, answering request req (whispered)
--   P;questID                  please share this quest with me (whispered)
-- An entry is "questID:state:have/need.have/need".

local _, QM = ...

local Comm = {}
QM.Comm = Comm

local PREFIX = "Fellowstep"
local MAX_PAYLOAD = 190 -- leaves room for the "T;name;" header on directed messages

---------------------------------------------------------------------------
-- Throttled send queue (the server allows short bursts, then about 1 per second)
---------------------------------------------------------------------------
local queue = {}
local tokens, MAX_TOKENS, REGEN = 6, 6, 1.0
local lastRegen = GetTime()

local function groupChannel()
    return QM.GroupChannel()
end

local function pump()
    local now = GetTime()
    tokens = math.min(MAX_TOKENS, tokens + (now - lastRegen) * REGEN)
    lastRegen = now
    while tokens >= 1 and #queue > 0 do
        local item = table.remove(queue, 1)
        local channel, target = item.channel, item.target
        if channel == "GROUP" then channel = groupChannel() end
        if channel then
            local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, channel, target)
            QM:Debug("send", channel, target or "", item.text:sub(1, 30), "->", tostring(result))
            if not ok then
                QM:Debug("send failed", result)
            elseif type(result) == "number" and Enum and Enum.SendAddonMessageResult then
                local R = Enum.SendAddonMessageResult
                if result == R.AddonMessageThrottle or result == R.ChannelThrottle then
                    -- throttled: put it back and wait for the budget to refill
                    table.insert(queue, 1, item)
                    tokens = 0
                    return
                elseif result ~= R.Success then
                    QM:Debug("send refused", result)
                end
            end
        end
        tokens = tokens - 1
    end
end

C_Timer.NewTicker(0.25, pump)

--- Queue one raw message. channel is "GROUP" or "WHISPER" (with target).
--- "WHISPER" never becomes a real whisper: the server refuses whispers to some
--- names (ones with spaces, for one), so directed messages go to the group as
--- "T;target;message" and everyone but the target ignores them.
function Comm:SendRaw(text, channel, target)
    if channel == "WHISPER" then
        if not target then return end
        text = "T;" .. target .. ";" .. text
        channel, target = "GROUP", nil
    end
    if #text > 250 then
        QM:Debug("dropping oversize message", #text)
        return
    end
    if channel == "GROUP" and not IsInGroup() then return end
    -- collapse duplicate pending group messages
    for _, item in ipairs(queue) do
        if item.text == text and item.channel == channel and item.target == target then return end
    end
    queue[#queue + 1] = { text = text, channel = channel, target = target }
end

--- Send a header plus as many entries as fit in each message.
local function sendBatched(header, entries, channel, target)
    local current = header
    local count = 0
    for _, e in ipairs(entries) do
        if #current + 1 + #e > MAX_PAYLOAD and count > 0 then
            Comm:SendRaw(current, channel, target)
            current = header
            count = 0
        end
        current = current .. ";" .. e
        count = count + 1
    end
    if count > 0 then Comm:SendRaw(current, channel, target) end
end

---------------------------------------------------------------------------
-- Outgoing
---------------------------------------------------------------------------
function Comm:SendHello(channel, target)
    self:SendRaw(("H;%d;%s;%d"):format(QM.protocolVersion, QM.version, QM:IsQuiet() and 1 or 0), channel or "GROUP", target)
end

local snapshotSeq = 0
function Comm:SendSnapshot(channel, target)
    local entries = {}
    for id in pairs(QM.Log.active) do
        entries[#entries + 1] = QM.Log:Encode(id)
    end
    -- chunk first so every chunk knows the total
    local chunks, current = {}, {}
    local size = 0
    for _, e in ipairs(entries) do
        if size + #e + 1 > MAX_PAYLOAD - 24 and #current > 0 then
            chunks[#chunks + 1] = current
            current, size = {}, 0
        end
        current[#current + 1] = e
        size = size + #e + 1
    end
    chunks[#chunks + 1] = current -- may be empty: an empty log is still a snapshot
    snapshotSeq = (snapshotSeq % 999) + 1
    for i, chunk in ipairs(chunks) do
        local text = ("S;%d;%d;%d"):format(snapshotSeq, i, #chunks)
        if #chunk > 0 then text = text .. ";" .. table.concat(chunk, ";") end
        self:SendRaw(text, channel or "GROUP", target)
    end
end

function Comm:SendChanges(ids)
    local entries = {}
    for _, id in ipairs(ids) do
        local e = QM.Log:Encode(id)
        if e then entries[#entries + 1] = e end
    end
    if #entries > 0 then sendBatched("A", entries, "GROUP") end
end

function Comm:SendRemoved(questID, reason)
    self:SendRaw(("X;%d;%s"):format(questID, reason or "a"), "GROUP")
end

function Comm:RequestSnapshot()
    self:SendRaw("R", "GROUP")
end

function Comm:AskToShare(target, questID)
    self:SendRaw(("P;%d"):format(questID), "WHISPER", target)
end

local nextRequest = 0
local pendingQueries = {} -- [req] = { target, ids }

--- Ask one player which of these quests they have completed.
function Comm:QueryCompleted(target, ids)
    local header
    local batch = {}
    local function flush()
        if #batch == 0 then return end
        nextRequest = (nextRequest % 9999) + 1
        pendingQueries[nextRequest] = { target = target, ids = batch }
        self:SendRaw(("Q;%d;%s"):format(nextRequest, table.concat(batch, ",")), "WHISPER", target)
        batch = {}
    end
    local size = 0
    for _, id in ipairs(ids) do
        local s = tostring(id)
        if size + #s + 1 > MAX_PAYLOAD - 12 then flush(); size = 0 end
        batch[#batch + 1] = s
        size = size + #s + 1
    end
    flush()
end

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------
local function split(text)
    local out = {}
    for piece in (text .. ";"):gmatch("([^;]*);") do out[#out + 1] = piece end
    return out
end

--- Decode "id:state:h/n.h/n" into id, { state, objectives }
function Comm.DecodeEntry(entry)
    local id, state, objs = entry:match("^(%d+):(%d+):?(.*)$")
    id, state = tonumber(id), tonumber(state)
    if not id then return nil end
    local objectives = {}
    if objs and objs ~= "" then
        for have, need in objs:gmatch("(%d+)/(%d+)") do
            objectives[#objectives + 1] = { have = tonumber(have), need = tonumber(need), done = tonumber(have) >= tonumber(need) }
        end
    end
    return id, { state = state, objectives = objectives }
end

function Comm.IsMe(name)
    if not name or not QM.playerName then return false end
    return QM.SameName(name, QM.playerName)
end

local snapshots = {} -- [sender] = { seq, got, n, quests }

local handlers = {}

handlers.H = function(sender, f, channel)
    QM:Fire("QM_PEER_HELLO", sender, tonumber(f[2]) or 0, f[3], f[4] == "1", channel)
end

handlers.R = function(sender)
    Comm:SendSnapshot("WHISPER", sender)
end

handlers.S = function(sender, f)
    local seq, i, n = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    if not (seq and i and n) then return end
    local s = snapshots[sender]
    if not s or s.seq ~= seq then
        s = { seq = seq, got = 0, n = n, quests = {} }
        snapshots[sender] = s
    end
    for k = 5, #f do
        local id, q = Comm.DecodeEntry(f[k])
        if id then s.quests[id] = q end
    end
    s.got = s.got + 1
    if s.got >= s.n then
        snapshots[sender] = nil
        QM:Fire("QM_PEER_SNAPSHOT", sender, s.quests)
    end
end

handlers.A = function(sender, f)
    local quests = {}
    for k = 2, #f do
        local id, q = Comm.DecodeEntry(f[k])
        if id then quests[id] = q end
    end
    QM:Fire("QM_PEER_UPDATE", sender, quests)
end

handlers.X = function(sender, f)
    local id = tonumber(f[2])
    if id then QM:Fire("QM_PEER_REMOVED", sender, id, f[3] == "t") end
end

handlers.Q = function(sender, f)
    local req = tonumber(f[2])
    if not req or not f[3] then return end
    local done = {}
    for idText in f[3]:gmatch("%d+") do
        local id = tonumber(idText)
        if id and QM.Log:IsCompleted(id) then done[#done + 1] = idText end
    end
    Comm:SendRaw(("C;%d;%s"):format(req, table.concat(done, ",")), "WHISPER", sender)
end

local lastAsk = {}
handlers.P = function(sender, f)
    local id = tonumber(f[2])
    if not id or not QM.Log.active[id] then return end
    local key = sender .. id
    if lastAsk[key] and GetTime() - lastAsk[key] < 10 then return end
    lastAsk[key] = GetTime()
    QM:Fire("QM_SHARE_REQUESTED", sender, id)
end

handlers.C = function(sender, f)
    local req = tonumber(f[2])
    local pending = req and pendingQueries[req]
    if not pending then return end
    pendingQueries[req] = nil
    local done = {}
    for idText in (f[3] or ""):gmatch("%d+") do done[tonumber(idText)] = true end
    local result = {}
    for _, idText in ipairs(pending.ids) do
        local id = tonumber(idText)
        result[id] = done[id] or false
    end
    QM:Fire("QM_PEER_COMPLETED", sender, result)
end

QM:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
    if prefix ~= PREFIX or type(text) ~= "string" then return end
    local raw = sender
    sender = QM.NormalizeSender(sender)
    if QM.SameName(sender, QM.playerName) then return end
    Comm.lastHeard = Comm.lastHeard or {}
    Comm.lastHeard[sender] = raw
    QM:Debug("got", channel, raw, text:sub(1, 40))
    local to, inner = text:match("^T;([^;]+);(.*)$")
    if to then
        if not Comm.IsMe(to) then return end
        text, channel = inner, "WHISPER" -- a directed answer, handled like a whisper
    end
    local f = split(text)
    local handler = handlers[f[1]]
    if handler then handler(sender, f, channel) end
end)

QM:On("QM_LOADED", function()
    local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    Comm.prefixResult = ok and tostring(result) or ("error " .. tostring(result))
end)

QM:On("QM_PRINT_STATUS", function()
    if not QM.db or not QM.db.debug then return end
    QM:Print("prefix " .. PREFIX .. " registered: " .. tostring(Comm.prefixResult) .. ", channel: " .. tostring(groupChannel()))
    for name, raw in pairs(Comm.lastHeard or {}) do
        QM:Print("heard from " .. raw .. " (as " .. name .. ")")
    end
end)

---------------------------------------------------------------------------
-- When to talk
---------------------------------------------------------------------------
local recentlyTurnedIn = {}
QM:On("QM_QUEST_TURNED_IN", function(_, questID)
    recentlyTurnedIn[questID] = GetTime()
end)

QM:On("QM_LOG_CHANGED", function(_, changed, removed)
    if not IsInGroup() then return end
    if #changed > 0 then Comm:SendChanges(changed) end
    for _, id in ipairs(removed) do
        local t = recentlyTurnedIn[id]
        local turnedIn = (t and GetTime() - t < 10) or QM.Log:IsCompleted(id)
        Comm:SendRemoved(id, turnedIn and "t" or "a")
    end
end)

-- Say hello again while anyone in the group still hasn't answered. A hello can be
-- lost (sent a moment before the server finished adding us to the group, a reload
-- on the other end), and one missed hello used to leave both sides blind.
local retryTimer
local function scheduleRetries()
    if retryTimer then retryTimer:Cancel() end
    local tries = 0
    local t
    t = C_Timer.NewTicker(10, function()
        tries = tries + 1
        if not IsInGroup() or tries > 6 then t:Cancel() return end
        local missing = false
        for _, m in ipairs(QM.Party:Members()) do
            if not m.isPlayer and not m.fake and not QM.Party:HasAddon(m) then missing = true end
        end
        if not missing then t:Cancel() return end
        Comm:SendHello("GROUP")
    end)
    retryTimer = t
end

local announcePending = false
local function announce()
    if announcePending then return end
    announcePending = true
    C_Timer.After(2, function()
        announcePending = false
        if not IsInGroup() then return end
        Comm:SendHello("GROUP")
        Comm:SendSnapshot("GROUP")
        Comm:RequestSnapshot()
        scheduleRetries()
    end)
end
Comm.Announce = announce

-- Announce whenever someone new shows up, not only when we join: either side may
-- have missed the other's hello.
local known = {}
local function rosterNames()
    local names = {}
    if IsInGroup() then
        for i = 1, 4 do
            local n = UnitExists("party" .. i) and QM.FullName("party" .. i)
            if n then names[n] = true end
        end
    end
    return names
end

QM:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    if not IsInGroup() then wipe(known) return end
    local names, fresh = rosterNames(), false
    for n in pairs(names) do
        if not known[n] then fresh = true end
    end
    known = names
    if fresh then announce() end
end)

QM:On("QM_LOGIN", function()
    known = rosterNames()
    if IsInGroup() then announce() end
end)

-- Someone said hello to the group: answer them directly so they learn about us too.
-- Answer every group hello (they may have reloaded and forgotten us), but never a
-- whispered one, which is itself an answer.
local greeted = {}
QM:On("QM_PEER_HELLO", function(_, sender, _, _, _, channel)
    if channel == "WHISPER" then return end
    local last = greeted[sender]
    if last and GetTime() - last < 5 then return end
    greeted[sender] = GetTime()
    Comm:SendHello("WHISPER", sender)
    Comm:SendSnapshot("WHISPER", sender)
end)

QM:RegisterEvent("GROUP_LEFT", function()
    wipe(greeted)
    wipe(snapshots)
end)
