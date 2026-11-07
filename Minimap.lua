-- Fellowstep: Minimap button
-- The standard round button on the minimap ring. Left-click: Fellowstep. Right-click: settings.
-- Drag to slide it around the ring.

local _, QM = ...

local button

local RADIUS_PAD = 10

local function position()
    local angle = math.rad(QM.char.minimapAngle or 120)
    local radius = (Minimap:GetWidth() / 2) + RADIUS_PAD
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function onDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    QM.char.minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
    position()
end

local function create()
    button = CreateFrame("Button", "FellowstepMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 6, -5)
    icon:SetTexture("Interface\\AddOns\\Fellowstep\\Media\\MinimapIcon64")
    icon:SetTexCoord(0, 1, 0, 1)
    if button.CreateMaskTexture then
        local mask = button:CreateMaskTexture()
        mask:SetAllPoints(icon)
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        icon:AddMaskTexture(mask)
    end
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 7, -6) end)
    button:SetScript("OnMouseUp", function() icon:SetPoint("TOPLEFT", 6, -5) end)
    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then
            QM:Fire("QM_OPEN_SETTINGS")
        else
            QM:Fire("QM_TOGGLE_MATRIX")
        end
    end)
    button:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self:SetScript("OnUpdate", onDragUpdate)
        GameTooltip:Hide()
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Fellowstep", 1, 0.82, 0)
        local partner = QM.Party and QM.Party:Partner()
        local count = QM.Party and #QM.Party.order or 1
        if partner then
            GameTooltip:AddLine("Questing with " .. QM.ShortName(partner.name), 1, 1, 1)
        elseif count > 1 then
            GameTooltip:AddLine(("%d in your group"):format(count), 1, 1, 1)
        end
        if QM.Test and QM.Test:IsOn() then GameTooltip:AddLine("Test mode is on", 0.6, 0.8, 1) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Left-click", "Fellowstep", 0.6, 0.6, 0.6, 1, 1, 1)
        GameTooltip:AddDoubleLine("Right-click", "Settings", 0.6, 0.6, 0.6, 1, 1, 1)
        GameTooltip:AddDoubleLine("Drag", "Move this button", 0.6, 0.6, 0.6, 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function refresh()
    if not Minimap then return end
    if not button then create() end
    position()
    button:SetShown(not QM.char.minimapHidden and not QM:IsQuiet())
end

QM:On("QM_LOGIN", refresh)
QM:On("QM_MINIMAP_CHANGED", refresh)
QM:On("QM_SETTINGS_CHANGED", refresh)
