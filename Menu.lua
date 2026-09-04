-- Menu.lua
-- Context menu opened by the minimap button, built on vanilla's native
-- UIDropDownMenuTemplate system.

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

	if BTV:IsDefaultProfileActive() then
		info.disabled = 1
		info.tooltipWhileDisabled = 1
		info.tooltipOnButton = 1
		info.tooltipTitle = "Configure Layout"
		info.tooltipText = "A profile other than the Default profile needs to be active to use Edit Layout mode."
	end

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
end

UIDropDownMenu_Initialize(BTV.menuFrame, InitializeMenu, "MENU")

function BTV:ToggleMainMenu()
	ToggleDropDownMenu(1, nil, self.menuFrame, "BTVanillaMinimapButton", 0, 0)
end
