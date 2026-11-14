-- Fellowstep: Tracker
-- A small badge next to each quest in Blizzard's objective tracker (and the quest list
-- beside the world map) that says where you
-- stand in that quest's chain compared with your group:
--   green check   everyone is on the same step
--   red  -N       you are N steps behind someone: focus this one
--   blue +N       you are N steps ahead of someone: hold off
-- Clicking the badge opens Fellowstep on that chain. Also answers "please share" requests.

local _, QM = ...
local UI = QM.UI

local Tracker = {}
QM.Tracker = Tracker

local badges = {} -- [block] = badge
local RED, BLUE, GREEN, GREY = { 1, 0.35, 0.3 }, { 0.35, 0.65, 1 }, { 0.3, 0.9, 0.3 }, { 0.6, 0.6, 0.6 }

local function inGroup()
    for _, m in ipairs(QM.Party:Members()) do
        if not m.isPlayer then return true end
    end
    return false
end

local function showTooltip(badge)
    local chain = badge.chain
    if not chain then return end
    GameTooltip:SetOwner(badge, "ANCHOR_LEFT")
    GameTooltip:SetText(chain.title, 1, 0.82, 0)
    local kind, n = badge.kind, badge.n
    if kind == "same" then
        GameTooltip:AddLine("Everyone is on the same step.", GREEN[1], GREEN[2], GREEN[3], true)
    elseif kind == "behind" then
        GameTooltip:AddLine(("You're %d %s behind. Focus on this one."):format(n, n == 1 and "step" or "steps"), RED[1], RED[2], RED[3], true)
    elseif kind == "ahead" then
        GameTooltip:AddLine(("You're %d %s ahead. Hold off so the others can catch up."):format(n, n == 1 and "step" or "steps"), BLUE[1], BLUE[2], BLUE[3], true)
    elseif kind == "waiting" then
        GameTooltip:AddLine(n > 0 and ("You need level %d for the next quest in this chain."):format(n)
            or "You need to finish an earlier quest before the next one in this chain.", GREY[1], GREY[2], GREY[3], true)
    else
        GameTooltip:AddLine("Still asking the group where they are.", GREY[1], GREY[2], GREY[3], true)
    end
    GameTooltip:AddLine(" ")
    local total = #chain.steps
    for _, r in ipairs(badge.rows or {}) do
        local name = r.member.isPlayer and "You" or QM.ShortName(r.member.name)
        local right
        if r.noAddon then
            right = "|cff999999no Fellowstep|r"
        elseif r.unknown then
            right = "|cff999999asking...|r"
        else
            right = ("%d/%d done%s"):format(r.count, total, r.where and (" · on " .. r.where) or (r.next and (" · " .. r.next) or ""))
        end
        GameTooltip:AddDoubleLine(name, right, 1, 1, 1, 0.85, 0.85, 0.85)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to open this chain in Fellowstep", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

--- Room to leave at the right of each quest title for other addons' buttons.
function Tracker.RightInset()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if loaded and (loaded("Spoken_Quests") or loaded("Spoken")) then return 18 end
    return 0
end

local function getBadge(block, centered)
    local b = badges[block]
    if b then return b end
    b = CreateFrame("Button", nil, block)
    b:SetSize(26, 14)
    b:SetFrameLevel(block:GetFrameLevel() + 5)
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint(centered and "CENTER" or "RIGHT")
    b.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint(centered and "CENTER" or "RIGHT")
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function(self)
        if self.questID then QM:Fire("QM_SHOW_CHAIN", self.questID) end
    end)
    b:SetScript("OnEnter", showTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badges[block] = b
    return b
end

--- Badge on one frame for one quest. place(badge, frame) positions it; centered draws
--- the mark centered in the badge instead of against its right edge.
local function paint(block, questID, place, centered)
    local chain = QM.Chains:ForQuest(questID)
    local kind, n, rows
    if chain then
        QM.Chains:AskAbout(chain)
        kind, n, rows = QM.Chains:Standing(chain)
    end
    local b = badges[block]
    if not kind then
        if b then b:Hide() end
        return
    end
    b = getBadge(block, centered)
    b.questID, b.chain, b.kind, b.n, b.rows = questID, chain, kind, n, rows
    b:ClearAllPoints()
    if place then
        place(b, block)
    else
        -- top right of the title, left of anything else in that corner
        -- (Spoken puts a 14px Play button at the block's top right)
        b:SetPoint("TOPRIGHT", block, "TOPRIGHT", -Tracker.RightInset(), 0)
    end
    if kind == "same" then
        b.icon:Show(); b.text:Hide()
    else
        b.icon:Hide(); b.text:Show()
        local c = kind == "behind" and RED or kind == "ahead" and BLUE or GREY
        local label = kind == "behind" and ("-" .. n) or kind == "ahead" and ("+" .. n) or "..."
        if kind == "waiting" then label = n > 0 and ("Lv" .. n) or "..." end
        b.text:SetText(label)
        b.text:SetTextColor(c[1], c[2], c[3])
    end
    b:Show()
end

-- Blizzard's tracker keeps its quest blocks in module.usedBlocks, either flat
-- ([id] = block) or by template ([template][id] = block) depending on the client.
local function eachBlock(fn)
    local modules = {
        _G.QuestObjectiveTracker, _G.CampaignQuestObjectiveTracker,
        _G.QUEST_TRACKER_MODULE, _G.CAMPAIGN_QUEST_TRACKER_MODULE,
    }
    for _, module in pairs(modules) do
        local used = type(module) == "table" and module.usedBlocks
        if type(used) == "table" then
            for k, v in pairs(used) do
                if type(v) == "table" and v.GetObjectType then
                    fn(v, v.id or k)
                elseif type(v) == "table" then
                    for id, block in pairs(v) do
                        if type(block) == "table" and block.GetObjectType then fn(block, block.id or id) end
                    end
                end
            end
        end
    end
end

-- The quest list beside the world map: pooled title rows with .questID. The badge sits in
-- the empty gutter under the row's quest icon, clear of the title, the checkbox and any
-- other addon's buttons at the row's right end.
local function placeInLog(b, row)
    b:SetPoint("TOP", row, "TOPLEFT", 14, -24)
end

local function eachLogRow(fn)
    local pool = _G.QuestScrollFrame and _G.QuestScrollFrame.titleFramePool
    if not (pool and pool.EnumerateActive) then return end
    for row in pool:EnumerateActive() do fn(row, row.questID) end
end

function Tracker:Refresh()
    for _, b in pairs(badges) do b:Hide() end
    if QM:IsQuiet() or not inGroup() then return end
    eachBlock(function(block, id)
        if type(id) == "number" and block:IsShown() then paint(block, id) end
    end)
    eachLogRow(function(row, id)
        if type(id) == "number" and row:IsShown() then paint(row, id, placeInLog, true) end
    end)
end

-- Redraw soon after anything changes, at most a few times a second.
local pending = false
local function refreshSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = false
        local ok, err = pcall(Tracker.Refresh, Tracker)
        if not ok then QM:Debug("tracker refresh failed", err) end
    end)
end
Tracker.RefreshSoon = refreshSoon

QM:On("QM_LOGIN", function()
    -- the tracker redraws on its own schedule; hook it so badges follow its blocks
    for _, name in ipairs({ "QuestObjectiveTracker", "CampaignQuestObjectiveTracker" }) do
        local module = _G[name]
        if type(module) == "table" then
            for _, method in ipairs({ "Update", "LayoutContents", "AddBlock" }) do
                if type(module[method]) == "function" then hooksecurefunc(module, method, refreshSoon) end
            end
        end
    end
    if type(_G.ObjectiveTracker_Update) == "function" then hooksecurefunc("ObjectiveTracker_Update", refreshSoon) end
    if type(_G.QuestLogQuests_Update) == "function" then hooksecurefunc("QuestLogQuests_Update", refreshSoon) end
    refreshSoon()
end)
QM:On("QM_PARTY_CHANGED", refreshSoon)
QM:On("QM_LOG_CHANGED", refreshSoon)
QM:On("QM_SETTINGS_CHANGED", refreshSoon)
QM:On("QM_CHAINS_READY", refreshSoon)

---------------------------------------------------------------------------
-- "Please share" requests from the group
---------------------------------------------------------------------------
StaticPopupDialogs["FELLOWSTEP_SHARE_REQUEST"] = {
    text = "%s asks you to share:\n|cffffd100%s|r",
    button1 = "Share",
    button2 = "Not now",
    OnAccept = function(_, data)
        if data and data.questID then UI.ShareQuest(data.questID) end
    end,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

QM:On("QM_SHARE_REQUESTED", function(_, sender, questID)
    local name = QM.Chains:QuestName(questID) or ("quest " .. questID)
    local popup = StaticPopup_Show("FELLOWSTEP_SHARE_REQUEST", QM.ShortName(sender), name)
    if popup then popup.data = { questID = questID } end
end)
