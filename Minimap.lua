-- Minimap.lua
-- Minimap button that opens the main context menu on click. Standard
-- vanilla-era technique - angle-based positioning around the minimap's
-- circumference, draggable to reposition. Pattern confirmed against
-- ButtonForge Classic's own shipped Minimap.lua (MIT-licensed, same
-- project referenced throughout this addon's design), not invented from
-- scratch.

local BTV = BTVanilla

local MINIMAP_ICON_RADIUS = 80 -- distance from minimap center, in pixels

local function ApplyMinimapPosition(button)
	local angle = BTVanillaDB.minimapAngle or 200
	local rad = angle * (math.pi / 180)
	local x = math.cos(rad) * MINIMAP_ICON_RADIUS
	local y = math.sin(rad) * MINIMAP_ICON_RADIUS
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- OnUpdate handler while dragging: follows the cursor around the
-- minimap's circumference by angle, not raw pixel position, so the icon
-- stays on the ring regardless of cursor distance from center.
local function Minimap_OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	if not mx then return end
	local px, py = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	px, py = px / scale, py / scale
	local angle = math.deg(math.atan2(py - my, px - mx))
	BTVanillaDB.minimapAngle = angle
	ApplyMinimapPosition(this)
end

local function Minimap_OnDragStart()
	this:SetScript("OnUpdate", Minimap_OnDragUpdate)
end

local function Minimap_OnDragStop()
	this:SetScript("OnUpdate", nil)
end

local function Minimap_OnClick()
	BTV:ToggleMainMenu()
end

local function Minimap_OnEnter()
	GameTooltip:SetOwner(this, "ANCHOR_LEFT")
	GameTooltip:SetText("BTVanilla")
	GameTooltip:AddLine("Click for options.", 1, 1, 1)
	GameTooltip:Show()
end

local function Minimap_OnLeave()
	GameTooltip:Hide()
end

function BTV:CreateMinimapButton()
	if self.minimapButton then
		return self.minimapButton
	end
	if BTVanillaDB.minimapAngle == nil then
		BTVanillaDB.minimapAngle = 200
	end

	local button = CreateFrame("Button", "BTVanillaMinimapButton", Minimap)
	button:SetWidth(31)
	button:SetHeight(31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetWidth(20)
	icon:SetHeight(20)
	icon:SetPoint("CENTER", button, "CENTER", 0, 1)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Wrench_01")
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetWidth(54)
	border:SetHeight(54)
	border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnDragStart", Minimap_OnDragStart)
	button:SetScript("OnDragStop", Minimap_OnDragStop)
	button:SetScript("OnClick", Minimap_OnClick)
	button:SetScript("OnEnter", Minimap_OnEnter)
	button:SetScript("OnLeave", Minimap_OnLeave)

	ApplyMinimapPosition(button)

	self.minimapButton = button
	return button
end
