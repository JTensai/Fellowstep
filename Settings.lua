-- Fellowstep: Settings
-- A page in the game's own Options window (Esc > Options > AddOns > Fellowstep).
-- Falls back to a standalone window if the client has no Settings API.

local _, QM = ...
local UI = QM.UI

local SettingsPage = {}
QM.SettingsPage = SettingsPage

local page, category, fallbackWindow

local function changed()
    QM:Fire("QM_SETTINGS_CHANGED")
end

---------------------------------------------------------------------------
-- Building the page
---------------------------------------------------------------------------
local function sectionHeader(parent, text, anchor, gap)
    local fs = UI.Text(parent, "header")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 18))
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -4)
    line:SetSize(560, 1)
    line:SetColorTexture(1, 0.82, 0, 0.25)
    return line
end

local function place(widget, anchor, x, y)
    widget:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x or 0, y or -8)
    return widget
end

local function buildPage(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()

    local title = UI.Text(f, "title")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Fellowstep")
    local version = UI.Text(f, "muted")
    version:SetPoint("LEFT", title, "RIGHT", 8, -1)
    version:SetText("v" .. QM.version)
    local intro = UI.Text(f, "small")
    intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    intro:SetText("Keeps your group's quests in sync. These settings are per character.")

    -- General
    local h3 = sectionHeader(f, "General", intro, 16)
    local mini = place(UI.Check(f, "Minimap button",
        function() return not QM.char.minimapHidden end,
        function(v) QM.char.minimapHidden = not v; QM:Fire("QM_MINIMAP_CHANGED") end,
        "Left-click opens Fellowstep, right-click opens these settings, drag to move it."), h3, -4, -8)
    local quiet = place(UI.Check(f, "Companion mode (no windows on this character, still syncs)",
        function() return QM.char.quiet end,
        function(v) QM.char.quiet = v; changed(); QM:Fire("QM_MINIMAP_CHANGED") end,
        "For a kid's character: the group still sees their quests, but nothing pops up for them."), mini, 0, -4)
    local spoilers
    local condense = place(UI.Check(f, "Condense quest chains to the quests your party is on",
        function() return QM.char.condense ~= false end,
        function(v) QM.char.condense = v; spoilers:SetAlpha(v and 0.45 or 1); changed() end,
        "Hides quests everyone has already finished and quests nobody has reached yet. The chain says how many are tucked away above and below."), quiet, 0, -4)
    spoilers = place(UI.Check(f, "Hide spoilers (future quests show as blank boxes)",
        function() return QM.char.hideSpoilers ~= false end,
        function(v) QM.char.hideSpoilers = v; changed() end,
        "When the chain isn't condensed, quests nobody has reached yet show as empty boxes: no name, no details, and they can't be clicked."), condense, 24, -4)
    spoilers:SetAlpha((QM.char.condense ~= false) and 0.45 or 1)
    local portraits = place(UI.Check(f, "Quest tree: character portraits instead of class icons",
        function() return QM.char.portraits end,
        function(v) QM.char.portraits = v; changed() end,
        "Pretend players and anyone out of range still show their class icon."), spoilers, -24, -4)

    -- Stick Together
    local h2 = sectionHeader(f, "Stick Together", portraits, 14)
    local about = UI.Text(f, "small")
    about:SetPoint("TOPLEFT", h2, "BOTTOMLEFT", 0, -8)
    about:SetWidth(560)
    about:SetWordWrap(true)
    about:SetText("For groups that want to do every quest together. A small panel next to your quest tracker lists only what's out of step: a quest someone is missing, someone ready to turn in before the others, or someone who wandered off. Alerts point it out as it happens.")
    local subOptions = {}
    local function dimSubOptions()
        for _, w in ipairs(subOptions) do w:SetAlpha(QM.char.syncEnabled and 1 or 0.45) end
    end
    local duo = place(UI.Check(f, "Turn on Stick Together",
        function() return QM.char.syncEnabled end,
        function(v) QM.char.syncEnabled = v; dimSubOptions(); changed() end), about, -4, -8)
    local alerts = place(UI.Check(f, "Pop-up alerts when someone is missing a quest or far away",
        function() return QM.char.alerts end,
        function(v) QM.char.alerts = v; changed() end), duo, 0, -4)
    local sound = place(UI.Check(f, "Play a sound with alerts",
        function() return QM.char.alertSound end,
        function(v) QM.char.alertSound = v end), alerts, 0, -4)
    local far = place(UI.Stepper(f, "Far away after",
        function() return QM.char.farDistance end,
        function(v) QM.char.farDistance = v; changed() end, 50, 400, 25, "%d yards"), sound, 4, -8)
    local grace = place(UI.Stepper(f, "Missing-quest alert after",
        function() return QM.char.shareGrace end,
        function(v) QM.char.shareGrace = v end, 5, 60, 5, "%d sec"), far, 0, -6)
    subOptions = { alerts, sound, far, grace }
    dimSubOptions()

    -- Test mode
    local h4 = sectionHeader(f, "Test mode", grace, 14)
    local test = place(UI.Check(f, "Fill my group with pretend players",
        function() return QM.Test:IsOn() end,
        function(v) QM.Test:SetOn(v); changed() end,
        "Adds made-up party members based on your own quests: one behind, one in step, one ahead, one off doing something else."), h4, -4, -8)
    local size = place(UI.Stepper(f, "Group size",
        function() return QM.char.testSize or 5 end,
        function(v) QM.char.testSize = v; QM:Fire("QM_TEST_CHANGED") end, 2, 5, 1, "%d players"), test, 8, -6)

    -- Buttons
    local open = UI.Button(f, "Open Fellowstep", 150, 22)
    open:SetPoint("TOPLEFT", size, "BOTTOMLEFT", -4, -20)
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if fallbackWindow then fallbackWindow:Hide() end
        QM:Fire("QM_TOGGLE_MATRIX")
    end)
    local reset = UI.Button(f, "Reset Window Positions", 170, 22)
    reset:SetPoint("LEFT", open, "RIGHT", 8, 0)
    reset:SetScript("OnClick", function()
        QM.char.syncPoint, QM.char.matrixPoint = nil, nil
        QM:Fire("QM_RESET_POSITIONS")
    end)

    f:SetScript("OnShow", function()
        dimSubOptions()
    end)
    return f
end

local function build(parent)
    -- scrollable, so the page never runs off the bottom of the Options window
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(640, 860)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = math.max(0, (content:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 50)))
    end)
    return buildPage(content)
end

---------------------------------------------------------------------------
-- Registering and opening
---------------------------------------------------------------------------
local function register()
    if category or fallbackWindow then return end
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        page = CreateFrame("Frame")
        page.name = "Fellowstep"
        build(page)
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, page, "Fellowstep")
        if ok and cat then
            category = cat
            Settings.RegisterAddOnCategory(category)
            return
        end
    end
    -- fallback: our own window
    fallbackWindow = UI.Window("FellowstepSettingsFrame", "Fellowstep Settings", 620, 640)
    fallbackWindow:SetPoint("CENTER")
    build(fallbackWindow.Inset)
end

function SettingsPage:Open()
    register()
    if category then
        if InCombatLockdown() then
            QM:Print("settings open after combat.")
            if not SettingsPage.hooked then
                SettingsPage.hooked = true
                QM:RegisterEvent("PLAYER_REGEN_ENABLED", function()
                    if SettingsPage.waiting then SettingsPage.waiting = false; SettingsPage:Open() end
                end)
            end
            SettingsPage.waiting = true
            return
        end
        local id = category.GetID and category:GetID() or category.ID
        Settings.OpenToCategory(id)
    elseif fallbackWindow then
        fallbackWindow:SetShown(not fallbackWindow:IsShown())
    end
end

QM:On("QM_LOGIN", register)
QM:On("QM_OPEN_SETTINGS", function() SettingsPage:Open() end)
