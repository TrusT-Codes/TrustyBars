-- Settings.lua
-- BTVanilla per-bar settings window.
--
-- Editable settings:
--   x
--   y
--   buttonSize
--   rows
--   cols
--   slotStart
--
-- point / relativePoint are intentionally NOT exposed in the UI.
-- Their existing SavedVariable values remain unchanged.
--
-- All numeric settings use sliders rather than text input.
--
-- Rows and columns are coupled so every bar always contains exactly
-- 12 buttons:
--
--   1 x 12
--   2 x 6
--   3 x 4
--   4 x 3
--   6 x 2
--   12 x 1
--
-- Button size follows the same 2-pixel increments used by the edit-mode
-- mouse wheel scaling.

local BTV = BTVanilla

local settingsFrame

-------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------

local ROW_OPTIONS = {
	1,
	2,
	3,
	4,
	6,
	12,
}

local BUTTON_SIZE_MIN = 16
local BUTTON_SIZE_MAX = 64
local BUTTON_SIZE_STEP = 2

-------------------------------------------------------------------------
-- Basic helpers
-------------------------------------------------------------------------

local function SettingsFrame_OnDragStart()
	this:StartMoving()
end

local function SettingsFrame_OnDragStop()
	this:StopMovingOrSizing()
end

local function BarListButton_OnClick()
	BTV:ShowBarPage(this.barId)
end

-------------------------------------------------------------------------
-- Slider creation
-------------------------------------------------------------------------

local function CreateSettingSlider(parent, name, width)
	local slider = CreateFrame(
		"Slider",
		name,
		parent,
		"OptionsSliderTemplate"
	)

	slider:SetWidth(width or 230)
	slider:SetHeight(17)

	slider:SetOrientation("HORIZONTAL")

	return slider
end

-------------------------------------------------------------------------
-- Slider label
-------------------------------------------------------------------------

local function SetSliderLabel(slider, text)
	if slider.Text then
		slider.Text:SetText(text)
	end
end

-------------------------------------------------------------------------
-- Screen coordinate ranges
-------------------------------------------------------------------------

local function GetScreenCoordinateRange()
	local width = UIParent:GetWidth()
	local height = UIParent:GetHeight()

	if not width or width <= 0 then
		width = 1024
	end

	if not height or height <= 0 then
		height = 768
	end

	-- Allow the full screen coordinate space in either direction.
	return -width, width, -height, height
end

-------------------------------------------------------------------------
-- Row/column helpers
-------------------------------------------------------------------------

local function GetColsForRows(rows)
	if rows == 1 then
		return 12
	elseif rows == 2 then
		return 6
	elseif rows == 3 then
		return 4
	elseif rows == 4 then
		return 3
	elseif rows == 6 then
		return 2
	elseif rows == 12 then
		return 1
	end

	-- Should never happen, but keep the function safe.
	return 12
end

local function GetRowsForCols(cols)
	if cols == 12 then
		return 1
	elseif cols == 6 then
		return 2
	elseif cols == 4 then
		return 3
	elseif cols == 3 then
		return 4
	elseif cols == 2 then
		return 6
	elseif cols == 1 then
		return 12
	end

	return 1
end

local function GetRowIndex(rows)
	local i

	for i = 1, table.getn(ROW_OPTIONS) do
		if ROW_OPTIONS[i] == rows then
			return i
		end
	end

	return 1
end

-------------------------------------------------------------------------
-- Create main settings frame
-------------------------------------------------------------------------

local function CreateSettingsFrame()
	local f = CreateFrame(
		"Frame",
		"BTVanillaSettingsFrame",
		UIParent
	)

	-- Larger window to accommodate proper sliders.
	f:SetWidth(620)
	f:SetHeight(520)

	f:SetPoint(
		"CENTER",
		UIParent,
		"CENTER",
		0,
		0
	)

	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")

	f:SetScript(
		"OnDragStart",
		SettingsFrame_OnDragStart
	)

	f:SetScript(
		"OnDragStop",
		SettingsFrame_OnDragStop
	)

	f:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = {
			left = 11,
			right = 12,
			top = 12,
			bottom = 11
		},
	})

	f:Hide()

	-------------------------------------------------------------------------
	-- Title
	-------------------------------------------------------------------------

	local title = f:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalLarge"
	)

	title:SetPoint(
		"TOP",
		f,
		"TOP",
		0,
		-16
	)

	title:SetText("BTVanilla Settings")

	-------------------------------------------------------------------------
	-- Close
	-------------------------------------------------------------------------

	local closeButton = CreateFrame(
		"Button",
		"BTVanillaSettingsCloseButton",
		f,
		"UIPanelCloseButton"
	)

	closeButton:SetPoint(
		"TOPRIGHT",
		f,
		"TOPRIGHT",
		-4,
		-4
	)

	closeButton:SetScript(
		"OnClick",
		function()
			f:Hide()
		end
	)

	-------------------------------------------------------------------------
	-- Left bar list
	-------------------------------------------------------------------------

	f.listPanel = CreateFrame(
		"Frame",
		nil,
		f
	)

	f.listPanel:SetWidth(125)
	f.listPanel:SetHeight(420)

	f.listPanel:SetPoint(
		"TOPLEFT",
		f,
		"TOPLEFT",
		18,
		-52
	)

	f.barButtons = {}

	local listTitle = f.listPanel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormal"
	)

	listTitle:SetPoint(
		"TOP",
		f.listPanel,
		"TOP",
		0,
		0
	)

	listTitle:SetText("Action Bars")

	-------------------------------------------------------------------------
	-- Right content panel
	-------------------------------------------------------------------------

	f.contentPanel = CreateFrame(
		"Frame",
		nil,
		f
	)

	f.contentPanel:SetWidth(430)
	f.contentPanel:SetHeight(420)

	f.contentPanel:SetPoint(
		"TOPRIGHT",
		f,
		"TOPRIGHT",
		-18,
		-52
	)

	f.contentPanel:SetBackdrop({
		bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = {
			left = 2,
			right = 2,
			top = 2,
			bottom = 2
		},
	})

	f.contentPanel:SetBackdropColor(
		0,
		0,
		0,
		0.3
	)

	f.pages = {}

	settingsFrame = f

	return f
end

-------------------------------------------------------------------------
-- Create a bar settings page
-------------------------------------------------------------------------

function BTV:GetOrCreateBarPage(barId)
	if not settingsFrame then
		CreateSettingsFrame()
	end

	if settingsFrame.pages[barId] then
		return settingsFrame.pages[barId]
	end

	local page = CreateFrame(
		"Frame",
		nil,
		settingsFrame.contentPanel
	)

	page:SetAllPoints(
		settingsFrame.contentPanel
	)

	page.barId = barId

	-------------------------------------------------------------------------
	-- Title
	-------------------------------------------------------------------------

	local title = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalLarge"
	)

	title:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		18,
		-14
	)

	title:SetText(
		"Bar " .. tostring(barId) .. " Settings"
	)

	page.title = title

	-------------------------------------------------------------------------
	-- Position section
	-------------------------------------------------------------------------

	local positionTitle = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormal"
	)

	positionTitle:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		18,
		-52
	)

	positionTitle:SetText("Position")

	-------------------------------------------------------------------------
	-- X slider
	-------------------------------------------------------------------------

	local xLabel = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	xLabel:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		22,
		-82
	)

	xLabel:SetText("X")

	local xSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "XSlider",
		300
	)

	xSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		85,
		-78
	)

	local minX, maxX, minY, maxY =
		GetScreenCoordinateRange()

	xSlider:SetMinMaxValues(
		minX,
		maxX
	)

	xSlider:SetValueStep(1)

	SetSliderLabel(
		xSlider,
		"X: 0"
	)

	xSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			SetSliderLabel(
				this,
				"X: " .. tostring(value)
			)
		end
	)

	page.xSlider = xSlider

	-------------------------------------------------------------------------
	-- Y slider
	-------------------------------------------------------------------------

	local yLabel = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	yLabel:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		22,
		-122
	)

	yLabel:SetText("Y")

	local ySlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "YSlider",
		300
	)

	ySlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		85,
		-118
	)

	ySlider:SetMinMaxValues(
		minY,
		maxY
	)

	ySlider:SetValueStep(1)

	SetSliderLabel(
		ySlider,
		"Y: 0"
	)

	ySlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			SetSliderLabel(
				this,
				"Y: " .. tostring(value)
			)
		end
	)

	page.ySlider = ySlider

	-------------------------------------------------------------------------
	-- Size & Layout
	-------------------------------------------------------------------------

	local layoutTitle = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormal"
	)

	layoutTitle:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		18,
		-166
	)

	layoutTitle:SetText("Size & Layout")

	-------------------------------------------------------------------------
	-- Button Size
	-------------------------------------------------------------------------

	local buttonSizeLabel = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	buttonSizeLabel:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		22,
		-196
	)

	buttonSizeLabel:SetText("Button Size")

	local buttonSizeSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "ButtonSizeSlider",
		300
	)

	buttonSizeSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		85,
		-192
	)

	buttonSizeSlider:SetMinMaxValues(
		BUTTON_SIZE_MIN,
		BUTTON_SIZE_MAX
	)

	-- Exactly the same 2-pixel increments as the mouse wheel.
	buttonSizeSlider:SetValueStep(
		BUTTON_SIZE_STEP
	)

	SetSliderLabel(
		buttonSizeSlider,
		"Button Size: " .. tostring(BTV.BUTTON_SIZE)
	)

	buttonSizeSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(
				(value / BUTTON_SIZE_STEP) + 0.5
			) * BUTTON_SIZE_STEP

			SetSliderLabel(
				this,
				"Button Size: " .. tostring(value)
			)
		end
	)

	page.buttonSizeSlider = buttonSizeSlider

	-------------------------------------------------------------------------
	-- Rows
	-------------------------------------------------------------------------

	local rowsLabel = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	rowsLabel:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		22,
		-240
	)

	rowsLabel:SetText("Rows")

	local rowsSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "RowsSlider",
		300
	)

	rowsSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		85,
		-236
	)

	-- The slider value is an index into ROW_OPTIONS:
	--
	-- 1 = 1 row
	-- 2 = 2 rows
	-- 3 = 3 rows
	-- 4 = 4 rows
	-- 5 = 6 rows
	-- 6 = 12 rows
	rowsSlider:SetMinMaxValues(
		1,
		table.getn(ROW_OPTIONS)
	)

	rowsSlider:SetValueStep(1)

	SetSliderLabel(
		rowsSlider,
		"Rows: 1"
	)

	rowsSlider:SetScript(
		"OnValueChanged",
		function()
			local index = math.floor(
				(this:GetValue() or 1) + 0.5
			)

			if index < 1 then
				index = 1
			end

			if index > table.getn(ROW_OPTIONS) then
				index = table.getn(ROW_OPTIONS)
			end

			local rows = ROW_OPTIONS[index]
			local cols = GetColsForRows(rows)

			SetSliderLabel(
				this,
				"Rows: " .. tostring(rows) ..
				" / Cols: " .. tostring(cols)
			)

			-- Keep the columns slider synchronized.
			if page.colsSlider then
				page.colsSlider:SetValue(
					GetRowIndex(rows)
				)
			end
		end
	)

	page.rowsSlider = rowsSlider

	-------------------------------------------------------------------------
	-- Columns
	--
	-- This is intentionally another slider because the user requested
	-- sliders for all numeric settings.
	--
	-- It is coupled to Rows. Changing Columns changes Rows automatically
	-- so the product is ALWAYS 12.
	-------------------------------------------------------------------------

	local colsLabel = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	colsLabel:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		22,
		-284
	)

	colsLabel:SetText("Columns")

	local colsSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "ColsSlider",
		300
	)

	colsSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		85,
		-280
	)

	colsSlider:SetMinMaxValues(
		1,
		table.getn(ROW_OPTIONS)
	)

	colsSlider:SetValueStep(1)

	SetSliderLabel(
		colsSlider,
		"Cols: 12"
	)

	colsSlider:SetScript(
		"OnValueChanged",
		function()
			local index = math.floor(
				(this:GetValue() or 1) + 0.5
			)

			if index < 1 then
				index = 1
			end

			if index > table.getn(ROW_OPTIONS) then
				index = table.getn(ROW_OPTIONS)
			end

			local cols = GetColsForRows(
				ROW_OPTIONS[index]
			)

			local rows = GetRowsForCols(cols)

			SetSliderLabel(
				this,
				"Cols: " .. tostring(cols) ..
				" / Rows: " .. tostring(rows)
			)

			-- Keep Rows synchronized.
			if page.rowsSlider then
				page.rowsSlider:SetValue(
					GetRowIndex(rows)
				)
			end
		end
	)

	page.colsSlider = colsSlider

	-------------------------------------------------------------------------
	-- Slot Start
	-------------------------------------------------------------------------

	local slotLabel = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	slotLabel:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		22,
		-328
	)

	slotLabel:SetText("Slot Start")

	local slotSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "SlotSlider",
		300
	)

	slotSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		85,
		-324
	)

	-- A 12-button bar needs 12 consecutive slots.
	--
	-- Therefore the last valid starting slot is:
	--
	-- ACTION_SLOT_END - 12 + 1
	--
	-- which is 109 with the current 73-120 pool.
	slotSlider:SetMinMaxValues(
		BTV.ACTION_SLOT_START,
		BTV.ACTION_SLOT_END - 11
	)

	slotSlider:SetValueStep(1)

	SetSliderLabel(
		slotSlider,
		"Slot Start: " .. tostring(BTV.ACTION_SLOT_START)
	)

	slotSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			SetSliderLabel(
				this,
				"Slot Start: " .. tostring(value)
			)
		end
	)

	page.slotSlider = slotSlider

	-------------------------------------------------------------------------
	-- Apply
	-------------------------------------------------------------------------

	local applyButton = CreateFrame(
		"Button",
		nil,
		page,
		"UIPanelButtonTemplate"
	)

	applyButton:SetWidth(120)
	applyButton:SetHeight(24)

	applyButton:SetPoint(
		"BOTTOMRIGHT",
		page,
		"BOTTOMRIGHT",
		-18,
		12
	)

	applyButton:SetText("Apply")

	applyButton.barId = barId

	applyButton:SetScript(
		"OnClick",
		function()
			local id = this.barId
			local cfg = BTVanillaDB.bars[id]

			if not cfg then
				return
			end

			-------------------------------------------------------------------------
			-- X/Y
			-------------------------------------------------------------------------

			local x = page.xSlider:GetValue()
			local y = page.ySlider:GetValue()

			if x then
				cfg.x = math.floor(x + 0.5)
			end

			if y then
				cfg.y = math.floor(y + 0.5)
			end

			-------------------------------------------------------------------------
			-- Button size
			-------------------------------------------------------------------------

			local buttonSize = page.buttonSizeSlider:GetValue()

			if buttonSize then
				buttonSize =
					math.floor(
						(buttonSize / BUTTON_SIZE_STEP) + 0.5
					) * BUTTON_SIZE_STEP

				if buttonSize < BUTTON_SIZE_MIN then
					buttonSize = BUTTON_SIZE_MIN
				end

				if buttonSize > BUTTON_SIZE_MAX then
					buttonSize = BUTTON_SIZE_MAX
				end

				cfg.buttonSize = buttonSize
			end

			-------------------------------------------------------------------------
			-- Rows / Columns
			-------------------------------------------------------------------------

			local rowIndex = math.floor(
				(page.rowsSlider:GetValue() or 1) + 0.5
			)

			if rowIndex < 1 then
				rowIndex = 1
			end

			if rowIndex > table.getn(ROW_OPTIONS) then
				rowIndex = table.getn(ROW_OPTIONS)
			end

			cfg.rows = ROW_OPTIONS[rowIndex]
			cfg.cols = GetColsForRows(cfg.rows)

			-------------------------------------------------------------------------
			-- Slot Start
			-------------------------------------------------------------------------

			local slotStart = page.slotSlider:GetValue()

			if slotStart then
				slotStart = math.floor(
					slotStart + 0.5
				)

				if slotStart < BTV.ACTION_SLOT_START then
					slotStart = BTV.ACTION_SLOT_START
				end

				if slotStart > BTV.ACTION_SLOT_END - 11 then
					slotStart = BTV.ACTION_SLOT_END - 11
				end

				cfg.slotStart = slotStart
			end

			-------------------------------------------------------------------------
			-- Apply position
			-------------------------------------------------------------------------

			local bar = BTV.bars[id]

			if bar then
				BTV:ApplyBarPosition(bar)

				-------------------------------------------------------------------------
				-- Button size
				-------------------------------------------------------------------------

				BTV:SetBarButtonSize(
					bar,
					cfg.buttonSize
				)

				-------------------------------------------------------------------------
				-- Grid
				-------------------------------------------------------------------------
				--
				-- Changing rows/columns changes the number of buttons.
				-- The Bar.lua implementation should rebuild the buttons
				-- when this function is available.
				-------------------------------------------------------------------------

				if BTV.RebuildBarButtons then
					BTV:RebuildBarButtons(bar)
				else
					BTV:LayoutButtons(bar)
				end
			end

			self:RefreshBarSettingsPage(id)

			BTV:Print(
				"Bar " .. tostring(id) ..
				" settings applied."
			)
		end
	)

	page.applyButton = applyButton

	-------------------------------------------------------------------------
	-- Delete
	-------------------------------------------------------------------------

	local deleteButton = CreateFrame(
		"Button",
		nil,
		page,
		"UIPanelButtonTemplate"
	)

	deleteButton:SetWidth(120)
	deleteButton:SetHeight(24)

	deleteButton:SetPoint(
		"BOTTOMLEFT",
		page,
		"BOTTOMLEFT",
		18,
		12
	)

	deleteButton:SetText("Delete Bar")

	deleteButton.barId = barId

	-- Keep the actual Blizzard button artwork, only make the text red.
	local deleteText = deleteButton:GetFontString()

	if deleteText then
		deleteText:SetTextColor(
			1.0,
			0.2,
			0.2
		)
	end

	deleteButton:SetScript(
		"OnClick",
		function()
			local id = this.barId

			if BTV.DeleteBar then
				BTV:DeleteBar(id)
			end
		end
	)

	page.deleteButton = deleteButton

	-------------------------------------------------------------------------
	-- Hide until selected
	-------------------------------------------------------------------------

	page:Hide()

	settingsFrame.pages[barId] = page

	return page
end

-------------------------------------------------------------------------
-- Refresh values shown by a bar page
-------------------------------------------------------------------------

function BTV:RefreshBarSettingsPage(barId)
	if not settingsFrame then
		return
	end

	local cfg = BTVanillaDB.bars[barId]

	if not cfg then
		return
	end

	local page = settingsFrame.pages[barId]

	if not page then
		return
	end

	-------------------------------------------------------------------------
	-- X/Y
	-------------------------------------------------------------------------

	local minX, maxX, minY, maxY =
		GetScreenCoordinateRange()

	page.xSlider:SetMinMaxValues(
		minX,
		maxX
	)

	page.ySlider:SetMinMaxValues(
		minY,
		maxY
	)

	local x = cfg.x or 0
	local y = cfg.y or 0

	page.xSlider:SetValue(x)
	page.ySlider:SetValue(y)

	-------------------------------------------------------------------------
	-- Button size
	-------------------------------------------------------------------------

	local buttonSize = cfg.buttonSize or BTV.BUTTON_SIZE

	if buttonSize < BUTTON_SIZE_MIN then
		buttonSize = BUTTON_SIZE_MIN
	end

	if buttonSize > BUTTON_SIZE_MAX then
		buttonSize = BUTTON_SIZE_MAX
	end

	page.buttonSizeSlider:SetValue(
		buttonSize
	)

	-------------------------------------------------------------------------
	-- Rows
	-------------------------------------------------------------------------

	local rows = cfg.rows or 1
	local rowIndex = GetRowIndex(rows)

	page.rowsSlider:SetValue(
		rowIndex
	)

	-------------------------------------------------------------------------
	-- Columns
	-------------------------------------------------------------------------

	page.colsSlider:SetValue(
		rowIndex
	)

	-------------------------------------------------------------------------
	-- Slot start
	-------------------------------------------------------------------------

	local slotStart = cfg.slotStart or BTV.ACTION_SLOT_START

	local minSlot = BTV.ACTION_SLOT_START
	local maxSlot = BTV.ACTION_SLOT_END - 11

	if slotStart < minSlot then
		slotStart = minSlot
	end

	if slotStart > maxSlot then
		slotStart = maxSlot
	end

	page.slotSlider:SetValue(
		slotStart
	)
end

-------------------------------------------------------------------------
-- Show a specific bar page
-------------------------------------------------------------------------

function BTV:ShowBarPage(barId)
	if not settingsFrame then
		CreateSettingsFrame()
	end

	local id
	local page

	for id, page in pairs(settingsFrame.pages) do
		page:Hide()
	end

	local target = self:GetOrCreateBarPage(barId)

	self:RefreshBarSettingsPage(barId)

	target:Show()

	settingsFrame.activeBarId = barId
end

-------------------------------------------------------------------------
-- Refresh left bar list
-------------------------------------------------------------------------

function BTV:RefreshBarList()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	local i

	for i = 1, table.getn(settingsFrame.barButtons) do
		settingsFrame.barButtons[i]:Hide()
	end

	settingsFrame.barButtons = {}

	local yOffset = -24

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg then
			local btn = CreateFrame(
				"Button",
				nil,
				settingsFrame.listPanel,
				"UIPanelButtonTemplate"
			)

			btn:SetWidth(110)
			btn:SetHeight(24)

			btn:SetPoint(
				"TOPLEFT",
				settingsFrame.listPanel,
				"TOPLEFT",
				0,
				yOffset
			)

			btn:SetText(
				"Bar " .. tostring(cfg.id)
			)

			btn.barId = cfg.id

			btn:SetScript(
				"OnClick",
				BarListButton_OnClick
			)

			settingsFrame.barButtons[i] = btn

			yOffset = yOffset - 28
		end
	end
end

-------------------------------------------------------------------------
-- Delete Bar
-------------------------------------------------------------------------

function BTV:DeleteBar(barId)
	self:EnsureDB()

	barId = tonumber(barId)

	if not barId then
		return
	end

	-- Find the SavedVariables entry by ID, never by array index - IDs are
	-- intentionally allowed to have gaps (see AddNewBar's comment in
	-- Bar.lua: deleting Bar 3 out of 1,2,3,4 leaves 1,2,4, so Bar 4 no
	-- longer sits at array index 4).
	local dbIndex = nil
	local cfg = nil

	local i

	for i = 1, table.getn(BTVanillaDB.bars) do
		if BTVanillaDB.bars[i] and
			BTVanillaDB.bars[i].id == barId then

			dbIndex = i
			cfg = BTVanillaDB.bars[i]
			break
		end
	end

	if not cfg then
		return
	end

	-------------------------------------------------------------------------
	-- Remove live bar
	--
	-- Goes through DestroyBarButtons so each button's range-check ticker
	-- is cancelled and its scripts/events unhooked, not just hidden -
	-- otherwise the ticker keeps firing against a hidden, orphaned button.
	-------------------------------------------------------------------------

	local bar = self.bars[barId]

	if bar then
		self:DestroyBarButtons(bar)

		bar:Hide()

		bar:SetScript("OnDragStart", nil)
		bar:SetScript("OnDragStop", nil)

		bar:UnregisterAllEvents()

		bar:SetParent(nil)

		self.bars[barId] = nil
	end

	-------------------------------------------------------------------------
	-- Remove ONLY this configuration.
	--
	-- No other configuration is modified, so no other bar's ID or
	-- action-slot assignment changes.
	-------------------------------------------------------------------------

	table.remove(BTVanillaDB.bars, dbIndex)

	-------------------------------------------------------------------------
	-- Remove page
	-------------------------------------------------------------------------

	if settingsFrame.pages[barId] then
		settingsFrame.pages[barId]:Hide()
		settingsFrame.pages[barId] = nil
	end

	settingsFrame.activeBarId = nil

	-------------------------------------------------------------------------
	-- Refresh UI
	-------------------------------------------------------------------------

	self:RefreshBarList()

	if table.getn(BTVanillaDB.bars) > 0 then
		self:ShowBarPage(
			BTVanillaDB.bars[1].id
		)
	else
		settingsFrame:Hide()
	end

	self:Print(
		"Deleted Bar " .. tostring(barId) ..
		". Other bars and their action slots were unchanged."
	)
end

-------------------------------------------------------------------------
-- Show settings
-------------------------------------------------------------------------

function BTV:ShowSettingsFrame()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	self:RefreshBarList()

	settingsFrame:Show()

	if not settingsFrame.activeBarId
		and table.getn(BTVanillaDB.bars) > 0 then

		self:ShowBarPage(
			BTVanillaDB.bars[1].id
		)
	end
end

-------------------------------------------------------------------------
-- Toggle settings
-------------------------------------------------------------------------

function BTV:ToggleSettingsFrame()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	if settingsFrame:IsShown() then
		settingsFrame:Hide()
	else
		self:ShowSettingsFrame()
	end
end

-------------------------------------------------------------------------
-- Open specific bar settings
-------------------------------------------------------------------------

function BTV:OpenBarSettings(bar)
	if not bar or not bar.config then
		return
	end

	self:ShowSettingsFrame()

	self:ShowBarPage(
		bar.config.id
	)
end