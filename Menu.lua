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
	info.text = "Add New Bar"
	info.notCheckable = true
	info.func = function() BTV:AddNewBar() end
	UIDropDownMenu_AddButton(info)
end

UIDropDownMenu_Initialize(BTV.menuFrame, InitializeMenu, "MENU")

function BTV:ToggleMainMenu()
	ToggleDropDownMenu(1, nil, self.menuFrame, "BTVanillaMinimapButton", 0, 0)
end
