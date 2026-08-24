-- Menu.lua
-- Right-click-style context menu opened by the minimap button, using
-- vanilla's native UIDropDownMenu system (a genuine, long-standing part
-- of FrameXML - the same mechanism Blizzard's own chat channel and
-- friends-list menus use), not a custom-built dropdown.

local BTV = BTVanilla

BTV.menuFrame = CreateFrame("Frame", "BTVanillaDropDownMenu", UIParent, "UIDropDownMenuTemplate")

local function InitializeMenu()
	local info = {}

	info.text = "Settings"
	info.notCheckable = true
	info.func = function() BTV:ToggleSettingsFrame() end
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = "Configure Layout"
	info.isNotRadio = true
	info.checked = BTV:IsEditMode()
	info.func = function() BTV:ToggleEditMode() end
	info.keepShownOnClick = true
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = "Lock Action Bars"
	info.isNotRadio = true
	info.checked = BTV:IsLockActionBars()
	info.func = function() BTV:ToggleLockActionBars() end
	info.keepShownOnClick = true
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = "Hoverbind"
	info.isNotRadio = true
	info.checked = BTV:IsHoverBindMode()
	info.func = function() BTV:ToggleHoverBindMode() end
	info.keepShownOnClick = true
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = "Always Show Action Bars"
	info.isNotRadio = true
	info.checked = BTV:IsAlwaysShowMultibars()
	info.func = function() BTV:ToggleAlwaysShowMultibars() end
	info.keepShownOnClick = true
	UIDropDownMenu_AddButton(info)

	-- "Add New Bar" - REMOVED (Stance/Page Bar Assignment feature, Part 1).
	-- Custom-bar capacity is now fixed at exactly 4 permanent Extra Bars
	-- (Settings.lua's bar list, ids 6-9), each toggled on/off via its own
	-- inline checkbox rather than added/removed - see Bar.lua's
	-- IsExtraBarId/SetExtraBarEnabled and Core.lua's EnsureExtraBars.
end

UIDropDownMenu_Initialize(BTV.menuFrame, InitializeMenu, "MENU")

function BTV:ToggleMainMenu()
	ToggleDropDownMenu(1, nil, self.menuFrame, "BTVanillaMinimapButton", 0, 0)
end
