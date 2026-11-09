-- Fellowstep: Core
-- Namespace, event dispatch, small utilities, settings and slash commands.

local ADDON_NAME, QM = ...
_G.Fellowstep = QM

-- the packager stamps the git tag into the TOC; an unpackaged copy still says @project-version@
do
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local v = getMeta and getMeta(ADDON_NAME, "Version")
    QM.version = (v and not v:find("@", 1, true)) and v or "dev"
end
QM.protocolVersion = 1

---------------------------------------------------------------------------
-- Messages between our own modules (not network)
---------------------------------------------------------------------------
local listeners = {}

--- Subscribe to an internal message. Handlers get (message, ...).
function QM:On(message, handler)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], handler)
end

function QM:Fire(message, ...)
    local list = listeners[message]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], message, ...)
        if not ok then QM:Debug("handler error for", message, err) end
    end
end

---------------------------------------------------------------------------
-- Game events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function QM:RegisterEvent(event, handler)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then QM:Debug("could not register event", event) end
    end
    table.insert(eventHandlers[event], handler)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then QM:Debug("event error", event, err) end
    end
end)

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local CHAT_PREFIX = "|cffffd100Fellowstep|r: "

function QM:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. table.concat(parts, " "))
end

function QM:Debug(...)
    if FellowstepDB and FellowstepDB.debug then
        QM:Print("|cff888888[debug]|r", ...)
    end
end

---------------------------------------------------------------------------
-- Player names
---------------------------------------------------------------------------

-- Realm names can arrive with or without spaces/dashes ("Some Realm" vs "SomeRealm")
-- depending on where they come from, so every key is built the same way.
local function canon(name, realm)
    if not realm or realm == "" then realm = GetNormalizedRealmName and GetNormalizedRealmName() end
    if not realm or realm == "" then return name end
    return name .. "-" .. (realm:gsub("[%s%-]", ""))
end

--- "Name-Realm" for a unit, always with realm, so it matches CHAT_MSG_ADDON senders.
function QM.FullName(unit)
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok or not name then return nil end
    return canon(name, realm)
end

function QM.NormalizeSender(sender)
    if not sender then return nil end
    local name, realm = sender:match("^([^%-]+)%-(.+)$")
    if name then return canon(name, realm) end
    return canon(sender, nil)
end

--- Do two names belong to the same character? Forever names have two parts
--- ("Clawdia Owlmighty"), but unit APIs can return only the first part while chat
--- senders carry both, so fall back to the short name and then its first word.
function QM.SameName(a, b)
    if not a or not b then return false end
    if QM.NormalizeSender(a) == QM.NormalizeSender(b) then return true end
    local sa, sb = QM.ShortName(a), QM.ShortName(b)
    if sa == sb then return true end
    local fa, fb = sa:match("^(%S+)"), sb:match("^(%S+)")
    return fa ~= nil and fa == fb
end

--- The chat channel that reaches the whole group, or nil when solo.
--- Careful: if the instance-category constant is missing, IsInGroup(nil) means
--- "in any group" and every message would go to INSTANCE_CHAT, which nobody gets.
local INSTANCE_CATEGORY = LE_PARTY_CATEGORY_INSTANCE
    or (Enum and Enum.PartyCategory and Enum.PartyCategory.Instance) or 2
local HOME_CATEGORY = LE_PARTY_CATEGORY_HOME
    or (Enum and Enum.PartyCategory and Enum.PartyCategory.Home) or 1
function QM.GroupChannel()
    if not IsInGroup() then return nil end
    if IsInGroup(INSTANCE_CATEGORY) and not IsInGroup(HOME_CATEGORY) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    return "PARTY"
end

--- Short display name (drops the realm).
function QM.ShortName(full)
    if not full then return "?" end
    return (full:match("^([^%-]+)")) or full
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local ACCOUNT_DEFAULTS = {
    debug = false,
}

local CHAR_DEFAULTS = {
    quiet = false,          -- companion mode: no UI at all, still syncs
    syncEnabled = false,    -- "Stick Together" panel and alerts (off until you turn it on)
    alerts = true,
    alertSound = true,
    farDistance = 150,      -- yards before Stick Together warns that someone is far away
    shareGrace = 20,        -- seconds after you accept a quest before warning that the partner lacks it
    syncPoint = nil,
    matrixPoint = nil,
    testMode = false,       -- fill the group with pretend players
    testSize = 5,           -- group size test mode fills up to (2-5)
    minimapHidden = false,
    minimapAngle = 120,     -- degrees around the minimap (120 = the 11 o'clock spot)
    condense = false,       -- tree: only the quests the party is on (finished and unreached ones tucked away)
    hideSpoilers = true,    -- tree, when not condensed: future quests show as blank boxes
    portraits = false,      -- tree: character portraits instead of class icons
    listCollapsed = false,  -- chain list on the left hidden
}

local function applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then target[k] = v end
    end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
QM:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON_NAME then return end
    FellowstepDB = FellowstepDB or {}
    FellowstepCharDB = FellowstepCharDB or {}
    applyDefaults(FellowstepDB, ACCOUNT_DEFAULTS)
    applyDefaults(FellowstepCharDB, CHAR_DEFAULTS)
    -- 0.5: the full chain is the new default; move everyone over once
    if not FellowstepCharDB.fullChainDefault then
        FellowstepCharDB.fullChainDefault = true
        FellowstepCharDB.condense = false
    end
    -- the old default spot was 200 degrees; move characters still sitting there to the new one
    if FellowstepCharDB.minimapAngle == 200 then FellowstepCharDB.minimapAngle = 120 end
    QM.db = FellowstepDB
    QM.char = FellowstepCharDB
    QM:Fire("QM_LOADED")
end)

-- after QM_LOADED, so UI files can read saved settings when they build
QM:RegisterEvent("PLAYER_LOGIN", function()
    QM.playerName = QM.FullName("player")
    QM:Fire("QM_LOGIN")
end)

function QM:IsQuiet()
    return QM.char and QM.char.quiet
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function printHelp()
    QM:Print("commands:")
    QM:Print("  /fs  - open or close the Fellowstep window")
    QM:Print("  /fs settings  - open settings")
    QM:Print("  /fs test  - pretend players fill your group, to try every screen solo")
    QM:Print("  /fs together  - turn Stick Together on or off (panel + alerts when the group is out of step)")
    QM:Print("  /fs quiet  - companion mode: hide all Fellowstep UI on this character (still syncs)")
    QM:Print("  /fs alerts  - turn Stick Together alerts on or off")
    QM:Print("  /fs reset  - reset window positions")
    QM:Print("  /fs status  - show who in your group has Fellowstep")
    QM:Print("  /fs debug  - toggle debug output")
end

SLASH_FELLOWSTEP1 = "/fs"
SLASH_FELLOWSTEP2 = "/fellowstep"
SlashCmdList.QUESTMATRIX = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "" then
        if QM:IsQuiet() then
            QM:Print("companion mode is on, so the UI is hidden. Type /fs quiet to turn it off.")
            return
        end
        QM:Fire("QM_TOGGLE_MATRIX")
    elseif cmd == "settings" or cmd == "options" or cmd == "config" then
        QM:Fire("QM_OPEN_SETTINGS")
    elseif cmd == "test" then
        QM.Test:SetOn(not QM.Test:IsOn())
        QM:Fire("QM_SETTINGS_CHANGED")
    elseif cmd == "together" or cmd == "sync" or cmd == "duo" then
        QM.char.syncEnabled = not QM.char.syncEnabled
        QM:Print("Stick Together " .. (QM.char.syncEnabled and "on" or "off"))
        QM:Fire("QM_SETTINGS_CHANGED")
    elseif cmd == "quiet" then
        QM.char.quiet = not QM.char.quiet
        QM:Print("companion mode " .. (QM.char.quiet and "on: this character syncs silently and shows no UI" or "off"))
        QM:Fire("QM_SETTINGS_CHANGED")
    elseif cmd == "alerts" then
        QM.char.alerts = not QM.char.alerts
        QM:Print("Stick Together alerts " .. (QM.char.alerts and "on" or "off"))
    elseif cmd == "reset" then
        QM.char.syncPoint = nil
        QM.char.minimapAngle = 120
        QM:Fire("QM_MINIMAP_CHANGED")
        QM.char.matrixPoint = nil
        QM:Fire("QM_RESET_POSITIONS")
        QM:Print("window positions reset")
    elseif cmd == "status" then
        QM:Fire("QM_PRINT_STATUS")
    elseif cmd == "debug" then
        QM.db.debug = not QM.db.debug
        QM:Print("debug " .. (QM.db.debug and "on" or "off"))
    else
        printHelp()
    end
end

-- Addon compartment (the addon list button by the minimap)
function Fellowstep_OnAddonCompartmentClick(_, button)
    if button == "RightButton" then QM:Fire("QM_OPEN_SETTINGS") return end
    if QM:IsQuiet() then
        QM:Print("companion mode is on. Type /fs quiet to turn it off.")
        return
    end
    QM:Fire("QM_TOGGLE_MATRIX")
end
