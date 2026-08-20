-- Bar.lua
-- Multi-bar grid engine for BTVanilla.
--
-- Vanilla WoW 1.12.1 / Lua 5.0 compatible.
--
-- Each bar has its own saved configuration:
--
--   id
--   point
--   relativePoint
--   x
--   y
--   cols
--   rows
--   buttonSize
--   slotStart
--
-- IMPORTANT:
-- Bar IDs are persistent identities. They are NOT array indices.
--
-- Example:
--
--   Bar 1
--   Bar 2
--   Bar 4
--
-- is perfectly valid after Bar 3 has been deleted.
--
-- Action slots are also persistent. Deleting a bar NEVER moves or
-- reassigns another bar's slots.
--
-- New bars search the entire available action-slot pool for a free
-- contiguous block instead of assuming that the highest existing slot
-- is always the correct place to start.

local BTV = BTVanilla

BTV.bars = {}

-------------------------------------------------------------------------
-- PixelUtil wrappers
-------------------------------------------------------------------------

local function PixelSetPoint(region, ...)
	if PixelUtil and PixelUtil.SetPoint then
		PixelUtil.SetPoint(region, unpack(arg))
	else
		region:SetPoint(unpack(arg))
	end
end

local function PixelSetSize(region, width, height)
	if PixelUtil and PixelUtil.SetSize then
		PixelUtil.SetSize(region, width, height)
	else
		region:SetWidth(width)
		region:SetHeight(height)
	end
end

-------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------

local function BarFrameSize(cfg)
	return cfg.buttonSize * cfg.cols, cfg.buttonSize * cfg.rows
end

-- Converts a 1-based button index into a 0-based column and row.
--
-- Lua 5.0 has no % operator, therefore:
--
--   remainder = i - (math.floor(i / cols) * cols)

local function ButtonIndexToGridPos(index, cols)
	local i = index - 1
	local row = math.floor(i / cols)
	local col = i - (row * cols)
	return col, row
end

-------------------------------------------------------------------------
-- Position
-------------------------------------------------------------------------

function BTV:ApplyBarPosition(bar)
	if not bar or not bar.config then
		return
	end

	local cfg = bar.config

	bar:ClearAllPoints()

	PixelSetPoint(
		bar,
		cfg.point or "TOPLEFT",
		UIParent,
		cfg.relativePoint or "TOPLEFT",
		cfg.x or 0,
		cfg.y or 0
	)
end

-------------------------------------------------------------------------
-- Button layout
-------------------------------------------------------------------------

function BTV:LayoutButtons(bar)
	if not bar or not bar.buttons or not bar.config then
		return
	end

	local cfg = bar.config
	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			local col, row = ButtonIndexToGridPos(i, cfg.cols)

			local xOff = col * cfg.buttonSize
			local yOff = -row * cfg.buttonSize

			btn:ClearAllPoints()
			PixelSetPoint(
				btn,
				"TOPLEFT",
				bar,
				"TOPLEFT",
				xOff,
				yOff
			)
		end
	end
end

-------------------------------------------------------------------------
-- Edit mode visuals
-------------------------------------------------------------------------

function BTV:ApplyEditModeVisual()
	local editMode = self:IsEditMode()

	local barId
	for barId, bar in pairs(self.bars) do
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn then
					btn:SetEditModeVisual(editMode)
				end
			end
		end
	end
end

-------------------------------------------------------------------------
-- Button size
-------------------------------------------------------------------------

function BTV:SetBarButtonSize(bar, newSize)
	if not bar or not bar.config then
		return
	end

	newSize = tonumber(newSize)

	if not newSize then
		return
	end

	-- Button size is deliberately restricted to even values.
	--
	-- The edit-mode mouse wheel changes the size by 2 pixels and the
	-- Settings UI uses the same granularity.
	newSize = math.floor(newSize / 2) * 2

	-- Keep the same sensible limits used by the addon.
	if newSize < 16 then
		newSize = 16
	end

	if newSize > 64 then
		newSize = 64
	end

	bar.config.buttonSize = newSize

	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			btn:ApplySize(newSize)
		end
	end

	local barW, barH = BarFrameSize(bar.config)

	PixelSetSize(bar, barW, barH)

	self:LayoutButtons(bar)
end

-------------------------------------------------------------------------
-- Apply position directly from settings
-------------------------------------------------------------------------

function BTV:SetBarPosition(bar, x, y)
	if not bar or not bar.config then
		return
	end

	x = tonumber(x)
	y = tonumber(y)

	if not x or not y then
		return
	end

	bar.config.x = x
	bar.config.y = y

	self:ApplyBarPosition(bar)
end

-------------------------------------------------------------------------
-- Apply layout configuration
--
-- rows * cols is expected to equal 12.
--
-- The Settings UI should enforce this constraint, but the engine also
-- validates it so invalid SavedVariables cannot accidentally create an
-- inconsistent bar.
-------------------------------------------------------------------------

function BTV:SetBarLayout(bar, cols, rows)
	if not bar or not bar.config then
		return false
	end

	cols = tonumber(cols)
	rows = tonumber(rows)

	if not cols or not rows then
		return false
	end

	cols = math.floor(cols)
	rows = math.floor(rows)

	if cols < 1 or rows < 1 then
		return false
	end

	if cols * rows ~= 12 then
		self:Print("Bar " .. tostring(bar.config.id) ..
			" layout must contain exactly 12 buttons.")
		return false
	end

	bar.config.cols = cols
	bar.config.rows = rows

	self:RebuildBarButtons(bar)

	return true
end

-------------------------------------------------------------------------
-- Slot start
-------------------------------------------------------------------------

-- Returns true when a bar currently occupies a given action slot.

function BTV:IsActionSlotUsed(slot, ignoredBarId)
	local i

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg and cfg.id ~= ignoredBarId then
			local count = (cfg.cols or 0) * (cfg.rows or 0)
			local first = cfg.slotStart
			local last = first and (first + count - 1)

			if first and last then
				if slot >= first and slot <= last then
					return true
				end
			end
		end
	end

	return false
end

-- Checks whether a complete contiguous slot range is free.

function BTV:IsActionSlotRangeFree(startSlot, count, ignoredBarId)
	if not startSlot or not count then
		return false
	end

	if startSlot < self.ACTION_SLOT_START then
		return false
	end

	if startSlot + count - 1 > self.ACTION_SLOT_END then
		return false
	end

	local slot

	for slot = startSlot, startSlot + count - 1 do
		if self:IsActionSlotUsed(slot, ignoredBarId) then
			return false
		end
	end

	return true
end

-- Finds the first free contiguous action-slot range large enough for
-- `neededCount`.
--
-- This deliberately scans from ACTION_SLOT_START instead of simply
-- looking after the highest existing bar.
--
-- Example:
--
--   Bar 1 -> 73-84
--   Bar 2 -> 85-96
--   Bar 3 -> 97-108
--   Bar 4 -> 109-120
--
-- Delete Bar 2:
--
--   Bar 1 -> 73-84
--   Bar 3 -> 97-108
--   Bar 4 -> 109-120
--
-- New bar can now correctly use 85-96.

function BTV:GetNextFreeSlotStart(neededCount)
	if not neededCount or neededCount < 1 then
		return nil
	end

	local candidate

	for candidate = self.ACTION_SLOT_START,
		self.ACTION_SLOT_END - neededCount + 1 do

		if self:IsActionSlotRangeFree(candidate, neededCount, nil) then
			return candidate
		end
	end

	return nil
end

-------------------------------------------------------------------------
-- Change slotStart of an existing bar
-------------------------------------------------------------------------

function BTV:SetBarSlotStart(bar, newSlotStart)
	if not bar or not bar.config then
		return false
	end

	newSlotStart = tonumber(newSlotStart)

	if not newSlotStart then
		return false
	end

	newSlotStart = math.floor(newSlotStart)

	local neededCount =
		(bar.config.cols or 1) *
		(bar.config.rows or 1)

	if not self:IsActionSlotRangeFree(
		newSlotStart,
		neededCount,
		bar.config.id
	) then

		self:Print(
			"Cannot move Bar " .. tostring(bar.config.id) ..
			" to action slots " .. tostring(newSlotStart) ..
			 "-" ..
			tostring(newSlotStart + neededCount - 1) ..
			": slots are already in use."
		)

		return false
	end

	-- IMPORTANT:
	-- We deliberately do NOT move actions between slots.
	--
	-- Changing slotStart means the bar's buttons will now reference the
	-- new action slots. The previous slots are left untouched.
	--
	-- This is why the Settings UI should normally leave slotStart alone
	-- unless the user explicitly wants to change it.

	bar.config.slotStart = newSlotStart

	self:RebuildBarButtons(bar)

	return true
end

-------------------------------------------------------------------------
-- Destroy buttons belonging to a bar
-------------------------------------------------------------------------

function BTV:DestroyBarButtons(bar)
	if not bar or not bar.buttons then
		return
	end

	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			-- Stop the range ticker created in Button.lua.
			if btn.rangeTicker and btn.rangeTicker.Cancel then
				btn.rangeTicker:Cancel()
				btn.rangeTicker = nil
			end

			-- Prevent the old button from continuing to receive events.
			if btn.UnregisterAllEvents then
				btn:UnregisterAllEvents()
			end

			btn:SetScript("OnEvent", nil)
			btn:SetScript("OnClick", nil)
			btn:SetScript("OnReceiveDrag", nil)
			btn:SetScript("OnDragStart", nil)
			btn:SetScript("OnDragStop", nil)
			btn:SetScript("OnMouseWheel", nil)
			btn:SetScript("OnEnter", nil)
			btn:SetScript("OnLeave", nil)

			btn:Hide()
		end
	end

	bar.buttons = {}
end

-------------------------------------------------------------------------
-- Rebuild buttons for a bar
-------------------------------------------------------------------------

function BTV:RebuildBarButtons(bar)
	if not bar or not bar.config then
		return
	end

	local cfg = bar.config

	-- Always destroy the previous buttons first.
	self:DestroyBarButtons(bar)

	local totalButtons = cfg.cols * cfg.rows

	bar.buttons = {}

	local i

	for i = 1, totalButtons do
		local slot = cfg.slotStart + (i - 1)

		if slot > self.ACTION_SLOT_END then
			self:Print(
				"Warning: Bar " .. tostring(cfg.id) ..
				" ran out of action slots at button " ..
				tostring(i)
			)

			break
		end

		local buttonIndex =
			tostring(cfg.id) .. "_" .. tostring(i)

		bar.buttons[i] =
			self:CreateActionButton(
				bar,
				slot,
				buttonIndex
			)
	end

	local barW, barH = BarFrameSize(cfg)

	PixelSetSize(bar, barW, barH)

	self:LayoutButtons(bar)
	self:ApplyEditModeVisual()
end

-------------------------------------------------------------------------
-- Bar creation
-------------------------------------------------------------------------

function BTV:CreateBarFromConfig(cfg)
	local barW, barH = BarFrameSize(cfg)

	local bar = CreateFrame(
		"Frame",
		"BTVanillaBar" .. tostring(cfg.id),
		UIParent
	)

	bar:SetFrameStrata("MEDIUM")

	PixelSetSize(bar, barW, barH)

	bar:SetBackdrop({
		bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true,
		tileSize = 8,
		edgeSize = 8,
		insets   = {
			left = 0,
			right = 0,
			top = 0,
			bottom = 0
		},
	})

	bar:SetBackdropColor(0, 0, 0, 0)
	bar:SetBackdropBorderColor(0, 0, 0, 0)

	bar:SetMovable(true)
	bar:RegisterForDrag("LeftButton")

	bar:SetScript("OnDragStart", function()
		if not BTV:IsEditMode() then
			return
		end

		BTV:StartBarDrag(this)
	end)

	bar:SetScript("OnDragStop", function()
		BTV:StopBarDrag(this)
	end)

	bar.config = cfg

	self:ApplyBarPosition(bar)

	bar.buttons = {}

	local totalButtons = cfg.cols * cfg.rows

	local i

	for i = 1, totalButtons do
		local slot = cfg.slotStart + (i - 1)

		if slot > self.ACTION_SLOT_END then
			self:Print(
				"Warning: Bar " .. tostring(cfg.id) ..
				" ran out of free action slots at button " ..
				tostring(i)
			)

			break
		end

		local buttonIndex =
			tostring(cfg.id) .. "_" .. tostring(i)

		bar.buttons[i] =
			self:CreateActionButton(
				bar,
				slot,
				buttonIndex
			)
	end

	self:LayoutButtons(bar)

	return bar
end

-------------------------------------------------------------------------
-- Create all bars from SavedVariables
-------------------------------------------------------------------------

function BTV:CreateAllBars()
	self:EnsureDB()

	self.bars = {}

	local i

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg and cfg.id then
			self.bars[cfg.id] =
				self:CreateBarFromConfig(cfg)
		end
	end

	self:ApplyEditModeVisual()
end

-------------------------------------------------------------------------
-- Find next persistent Bar ID
-------------------------------------------------------------------------

function BTV:GetNextBarId()
	local highestId = 0

	local i

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg and cfg.id then
			if cfg.id > highestId then
				highestId = cfg.id
			end
		end
	end

	return highestId + 1
end

-------------------------------------------------------------------------
-- Add new bar
-------------------------------------------------------------------------

function BTV:AddNewBar()
	self:EnsureDB()

	-- All bars currently use exactly 12 action buttons.
	local cols = self.BUTTON_COLS
	local rows = self.BUTTON_ROWS
	local needed = cols * rows

	local slotStart =
		self:GetNextFreeSlotStart(needed)

	if not slotStart then
		self:Print(
			"Cannot add a new bar - no free contiguous action-slot range " ..
			"is available in the pool (" ..
			self.ACTION_SLOT_START ..
			"-" ..
			self.ACTION_SLOT_END ..
			")."
		)

		return nil
	end

	-- IMPORTANT:
	-- Do NOT use table.getn(BTVanillaDB.bars) + 1.
	--
	-- If Bar 3 was deleted:
	--
	--   1, 2, 4
	--
	-- the next bar must become Bar 5, not Bar 4.
	local newId = self:GetNextBarId()

	-- New bars are positioned relative to the last existing bar.
	--
	-- Find the bar with the highest ID rather than assuming the last
	-- element of the SavedVariables array is the highest bar.
	local lastCfg = nil
	local lastBar = nil

	local i

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg then
			if not lastCfg or cfg.id > lastCfg.id then
				lastCfg = cfg
			end
		end
	end

	if lastCfg then
		lastBar = self.bars[lastCfg.id]
	end

	-- Read the actual live position of the previous bar.
	local point
	local relativePoint
	local lastX
	local lastY

	if lastBar then
		point,
		_,
		relativePoint,
		lastX,
		lastY = lastBar:GetPoint()
	end

	-- Stack the new bar directly above the previous bar.
	local previousHeight =
		lastBar and lastBar:GetHeight()

	local newY = lastY

	if newY and previousHeight then
		newY = newY + previousHeight
	else
		point = "CENTER"
		relativePoint = "CENTER"
		lastX = 0
		newY = -200
	end

	-- Inherit the previous bar's configured button size.
	local newButtonSize = self.BUTTON_SIZE

	if lastBar and
		lastBar.config and
		lastBar.config.buttonSize then

		newButtonSize =
			lastBar.config.buttonSize
	end

	-- Ensure the inherited value follows the same even-number rule.
	newButtonSize =
		math.floor(newButtonSize / 2) * 2

	if newButtonSize < 16 then
		newButtonSize = 16
	end

	if newButtonSize > 64 then
		newButtonSize = 64
	end

	local cfg = {
		id = newId,

		point = point or "CENTER",
		relativePoint = relativePoint or "CENTER",

		x = lastX or 0,
		y = newY or -200,

		cols = cols,
		rows = rows,

		buttonSize = newButtonSize,

		slotStart = slotStart,
	}

	-- IMPORTANT:
	-- The table index is NOT necessarily equal to the ID.
	--
	-- This remains valid:
	--
	--   BTVanillaDB.bars[1].id = 1
	--   BTVanillaDB.bars[2].id = 2
	--   BTVanillaDB.bars[3].id = 4
	--
	-- We append the new configuration rather than inserting it based on
	-- its ID. This preserves existing configurations untouched.
	table.insert(BTVanillaDB.bars, cfg)

	local bar =
		self:CreateBarFromConfig(cfg)

	self.bars[newId] = bar

	self:Print(
		"Added Bar " ..
		tostring(newId) ..
		" (slots " ..
		tostring(slotStart) ..
		"-" ..
		tostring(slotStart + needed - 1) ..
		")."
	)

	return bar
end

-------------------------------------------------------------------------
-- Bar drag
-------------------------------------------------------------------------

function BTV:StartBarDrag(bar)
	if not bar then
		return
	end

	bar:StartMoving()
end

function BTV:StopBarDrag(bar)
	if not bar then
		return
	end

	bar:StopMovingOrSizing()

	local point,
		_,
		relativePoint,
		x,
		y = bar:GetPoint()

	if point then
		bar.config.point = point
	end

	if relativePoint then
		bar.config.relativePoint = relativePoint
	end

	if x then
		bar.config.x = x
	end

	if y then
		bar.config.y = y
	end
end