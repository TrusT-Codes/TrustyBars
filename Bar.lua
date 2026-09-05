-- Bar.lua
-- Multi-bar grid engine for BTVanilla, backed by the action-slot pool.
--
-- Each bar's saved config: id, point, relativePoint, x, y, cols, rows,
-- buttonSize, slotStart, buttonCount.
--
-- Bar IDs are persistent identities, not array indices (e.g. bars 1, 2, 4
-- can exist after bar 3 is deleted). Action slots are also persistent -
-- deleting a bar never moves or reassigns another bar's slots. New bars
-- search the whole action-slot pool for a free contiguous block rather
-- than starting after the highest existing bar.

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

-- cfg.spacing may be absent on a bar saved before spacing was tracked;
-- default to 0.
local function BarFrameSize(cfg)
	local spacing = cfg.spacing or 0

	local width = (cfg.buttonSize * cfg.cols) + ((cfg.cols - 1) * spacing)
	local height = (cfg.buttonSize * cfg.rows) + ((cfg.rows - 1) * spacing)

	return width, height
end

-- Converts a 1-based button index into a 0-based column and row.
-- Lua 5.0 has no % operator: remainder = i - (math.floor(i / cols) * cols).

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
	-- cfg.spacing may be absent on a bar saved before spacing was tracked;
	-- default to 0.
	local spacing = cfg.spacing or 0
	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			local col, row = ButtonIndexToGridPos(i, cfg.cols)

			local xOff = col * (cfg.buttonSize + spacing)
			local yOff = -row * (cfg.buttonSize + spacing)

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
-- Bar-level edit-mode overlay
--
-- One full-bar-sized overlay frame owns all edit-mode interaction (drag,
-- right-click-to-settings, scroll-to-resize) for a bar. It sits above the
-- bar/buttons' own "HIGH" strata at "TOOLTIP" while edit mode is on, so it
-- wins every hit-test across the whole bar area, including gaps between
-- hidden pool slots that have no button frame of their own to catch a
-- click. Outside edit mode it is mouse-disabled and inert. This is the
-- only edit-mode hitbox tint in the addon; there is no per-button
-- equivalent.
-------------------------------------------------------------------------

local barOverlays = {}

local function EnsureBarOverlay(bar)
	local overlay = barOverlays[bar]

	if overlay then
		return overlay
	end

	overlay = CreateFrame(
		"Frame",
		"BTVanillaBarOverlay" .. tostring(bar.config.id),
		bar
	)

	-- Starts inert at HIGH strata / the bar's own frame level;
	-- ApplyEditModeVisual below elevates to TOOLTIP + EnableMouse(true)
	-- for the duration of edit mode only.
	overlay:SetFrameStrata("HIGH")
	overlay:SetFrameLevel(bar:GetFrameLevel())

	-- Default bars (id 1-5) expand the overlay past the bar's own frame
	-- bounds via GetElementVisualInset so the tint reaches the visible
	-- native border's outer edge; custom bars (id 6+, all insets 0) just
	-- SetAllPoints(bar).
	local insetLeft, insetRight, insetTop, insetBottom = BTV:GetElementVisualInset(bar)

	if insetLeft ~= 0 or insetRight ~= 0 or insetTop ~= 0 or insetBottom ~= 0 then
		overlay:SetPoint("TOPLEFT", bar, "TOPLEFT", -insetLeft, insetTop)
		overlay:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", insetRight, -insetBottom)
	else
		overlay:SetAllPoints(bar)
	end

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	tex:SetAllPoints(overlay)

	-- Hover border: a plain SetBackdrop edge, kept fully transparent until
	-- OnEnter/OnLeave below toggle it.
	overlay:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 8,
	})
	overlay:SetBackdropBorderColor(0, 0, 0, 0)

	overlay:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0, 0, 0, 1)
	end)
	overlay:SetScript("OnLeave", function()
		this:SetBackdropBorderColor(0, 0, 0, 0)
	end)

	-- Centered element-name label, shown/hidden together with the overlay
	-- (it has no Show/Hide of its own) - reuses BTV:GetBarDisplayName, the
	-- same name Settings.lua's bar list/page title shows.
	local nameText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nameText:SetPoint("CENTER", overlay, "CENTER", 0, 0)
	nameText:SetText(BTV:GetBarDisplayName(bar.config.id))

	-- RegisterForDrag is set once here unconditionally; only
	-- EnableMouse/strata toggle per edit-mode state, in
	-- ApplyEditModeVisual below.
	overlay:RegisterForDrag("LeftButton")
	overlay:SetScript("OnDragStart", function()
		BTV:StartBarDrag(bar)
	end)
	overlay:SetScript("OnDragStop", function()
		BTV:StopBarDrag(bar)
	end)

	-- Right-click-to-settings. While mouse-enabled (edit mode only) this
	-- overlay fully covers the real buttons underneath, so it is the only
	-- place that opens bar settings via right-click.
	overlay:SetScript("OnMouseUp", function()
		if arg1 == "RightButton" then
			BTV:OpenBarSettings(bar)
		end
	end)

	-- Scroll-wheel-to-resize, covering the whole overlay the same way
	-- drag-to-move does, not just directly over an individual button.
	overlay:EnableMouseWheel(true)
	overlay:SetScript("OnMouseWheel", function()
		if not BTV:IsEditMode() then
			return
		end

		local barId = bar.config.id

		if barId and barId >= 1 and barId <= 5 and
			BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
			return
		end

		local delta = arg1 or 0
		local step = 2

		BTV:SetBarButtonSize(bar, bar.config.buttonSize + (delta * step))
	end)

	overlay:EnableMouse(false)
	overlay:Hide()

	barOverlays[bar] = overlay

	return overlay
end

-------------------------------------------------------------------------
-- Edit mode visuals
-------------------------------------------------------------------------

function BTV:ApplyEditModeVisual()
	local editMode = self:IsEditMode()

	local barId
	for barId, bar in pairs(self.bars) do
		-- Bars 1-5 are individually draggable only when edit mode is on
		-- AND useDefaultLayout is false (mirrors DefaultBars.lua's own
		-- CanDragDefaultLayout). Computed once here so both the per-button
		-- tint and the bar-level overlay below agree on the same
		-- "is this bar actually individually draggable right now"
		-- condition.
		local isDefaultBar1to5 = barId and barId >= 1 and barId <= 5

		local canEdit = editMode

		if isDefaultBar1to5 then
			canEdit = editMode and BTVanillaDB and BTVanillaDB.useDefaultLayout == false
		end

		-- There is deliberately no per-button edit-mode tint for any bar
		-- kind; the bar-level overlay hitbox tint below is the only
		-- edit-mode tint in the addon.
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn then
					-- Re-evaluate Show/Hide the moment edit mode toggles,
					-- not just next time some other refresh happens to
					-- run.
					btn:UpdateGridVisibility()
				end
			end
		end

		-- Bar-level overlay: fully owns edit-mode interaction while
		-- canEdit is true (mouse-enabled, elevated to TOOLTIP strata
		-- above the bar/buttons' own HIGH), otherwise fully inert.
		if bar then
			local overlay = EnsureBarOverlay(bar)

			overlay:EnableMouse(canEdit and true or false)

			if canEdit then
				overlay:SetFrameStrata("TOOLTIP")
				overlay:Show()

				-- Reset the hover border to invisible every time edit
				-- mode is (re-)entered, in case OnLeave never fired from
				-- a previous edit-mode session (mouse left sitting over
				-- the overlay when edit mode turned off).
				overlay:SetBackdropBorderColor(0, 0, 0, 0)
			else
				overlay:SetFrameStrata("HIGH")
				overlay:Hide()
			end
		end
	end

	-- Also refreshes DefaultBars.lua's own overlays (gated on
	-- CanDragDefaultLayout, not just edit mode) so both bar kinds update
	-- together.
	if self.ApplyDefaultLayoutEditVisual then
		self:ApplyDefaultLayoutEditVisual()
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

	-- Restricted to even values, matching the 2px mouse-wheel/Settings UI
	-- step.
	newSize = math.floor(newSize / 2) * 2

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
-- Spacing (true custom bars, id 6+)
--
-- Mirrors DefaultBars.lua's SetDefaultBarSpacing (clamp, write, reapply);
-- writes directly to bar.config since a custom bar's cfg IS its own
-- BTVanillaDB.bars[] entry.
-------------------------------------------------------------------------

function BTV:SetBarSpacing(bar, spacing)
	if not bar or not bar.config then
		return
	end

	spacing = tonumber(spacing)

	if not spacing then
		return
	end

	spacing = math.floor(spacing + 0.5)

	-- Vanilla style has a real minimum spacing floor; modern has none.
	-- Settings.lua's GetSpacingDisplayOffset keeps the per-bar slider's
	-- displayed number consistent across a style switch.
	local minSpacing = self:IsVanillaBorderStyle() and self.VANILLA_SPACING_FLOOR or 0

	if spacing < minSpacing then
		spacing = minSpacing
	end

	if spacing > 20 then
		spacing = 20
	end

	bar.config.spacing = spacing

	self:ApplyBarShape(bar)
end

-------------------------------------------------------------------------
-- Global border/spacing style sweep (General tab checkbox,
-- BTVanillaDB.modernBorderStyle / useDefaultLayout's forced-vanilla lock)
--
-- Re-styles every bar's buttons for the current global style
-- (BTV:IsVanillaBorderStyle(), via Button.lua's
-- BTVButtonMixin:ApplyBorderStyle) on every call. On a real style
-- transition (tracked via BTVanillaDB.lastAppliedVanillaStyle, not on
-- every call) it also shifts every bar's buttonSize by
-- BTV.MODERN_BUTTON_SIZE_DELTA, nudges position to compensate, and shifts
-- real spacing by the same amount in the opposite direction so
-- buttonSize + spacing stays visually constant - Settings.lua's
-- GetSpacingDisplayOffset cancels this shift so the displayed spacing
-- number never changes. Not a live lock; per-bar sliders stay freely
-- adjustable afterward.
-------------------------------------------------------------------------

function BTV:ApplyGlobalButtonStyle()
	if not self.bars then
		return
	end

	local vanilla = self:IsVanillaBorderStyle()

	if BTVanillaDB.lastAppliedVanillaStyle == nil then
		BTVanillaDB.lastAppliedVanillaStyle = vanilla
	elseif BTVanillaDB.lastAppliedVanillaStyle ~= vanilla then
		local delta = vanilla and -self.MODERN_BUTTON_SIZE_DELTA or self.MODERN_BUTTON_SIZE_DELTA

		-- posShift compensates for the size delta being anchor-relative,
		-- not centered: growing to modern shifts the bar up-left,
		-- shrinking back to vanilla shifts it back down-right.
		local posShift = self.MODERN_BUTTON_SIZE_POSITION_SHIFT
		local dx = vanilla and posShift or -posShift
		local dy = vanilla and -posShift or posShift

		-- Opposite sign to the buttonSize delta above, so buttonSize +
		-- spacing stays visually constant across the switch.
		local spacingDelta = vanilla and self.VANILLA_SPACING_FLOOR or -self.VANILLA_SPACING_FLOOR

		-- useDefaultLayout turning ON forces vanilla=true here and its own
		-- OnClick already reset bars 1-5's buttonSize/position to native
		-- values before calling this function - applying the delta on top
		-- would double-shift them. Skip bars 1-5 in that case only; extra
		-- bars 6-9 (never touched by that reset) still need the delta.
		local skipDefaultBars = BTVanillaDB.useDefaultLayout ~= false

		local barId
		local bar

		for barId, bar in pairs(self.bars) do
			if bar and bar.config and bar.config.buttonSize and
				not (skipDefaultBars and barId >= 1 and barId <= 5) then
				self:SetBarButtonSize(bar, bar.config.buttonSize + delta)
				self:SetBarPosition(bar, (bar.config.x or 0) + dx, (bar.config.y or 0) + dy)
				self:SetBarSpacing(bar, (bar.config.spacing or 0) + spacingDelta)
			end
		end

		-- The global buttonSize override (if enabled) needs the same
		-- shift applied to its own stored value, then re-applied so it
		-- stays authoritative over whatever the per-bar loop above just
		-- wrote.
		if BTVanillaDB.globalButtonSizeEnabled and BTVanillaDB.globalButtonSizeValue then
			BTVanillaDB.globalButtonSizeValue = BTVanillaDB.globalButtonSizeValue + delta
			self:ApplyGlobalButtonSize()
		end

		BTVanillaDB.lastAppliedVanillaStyle = vanilla
	end

	local barId
	local bar

	for barId, bar in pairs(self.bars) do
		if bar and bar.config then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn and btn.ApplyBorderStyle then
					btn:ApplyBorderStyle()
				end
			end
		end
	end

	-- Stance Bar is a chain-anchored container of real Blizzard buttons,
	-- not one of self.bars above - swept separately via its own
	-- DefaultBars.lua-owned border-style function.
	if self.ApplyStanceBarBorderStyle then
		self:ApplyStanceBarBorderStyle()
	end
end

-------------------------------------------------------------------------
-- Global spacing/button-size overrides (General tab checkboxes,
-- BTVanillaDB.globalSpacingEnabled/globalButtonSizeEnabled)
--
-- While enabled, the General-tab slider is the single source of truth for
-- every bar in self.bars (default 1-5 + extra 6-9; simple bars like Bag
-- Bar/Micro Menu are never in self.bars); each bar's own per-bar slider
-- locks (Settings.lua's RefreshBarPageGlobalOverrideGating). No-ops while
-- disabled, leaving each bar's last-applied value in place. Also no-ops
-- while useDefaultLayout is on (its reset cascade already owns bars 1-5's
-- spacing/size then, and the General-tab sliders are locked too - see
-- RefreshGeneralPanel).
-------------------------------------------------------------------------

function BTV:ApplyGlobalSpacing()
	if not (self.bars and BTVanillaDB.globalSpacingEnabled) or
		BTVanillaDB.useDefaultLayout ~= false then
		return
	end

	-- Vanilla-only floor, see SetBarSpacing's comment. The global slider's
	-- own displayed number is the raw stored value, never itself offset,
	-- so the same displayed number applies the correct real spacing per
	-- style.
	local floor = self:IsVanillaBorderStyle() and self.VANILLA_SPACING_FLOOR or 0
	local real = (BTVanillaDB.globalSpacingValue or 0) + floor

	local barId
	local bar

	for barId, bar in pairs(self.bars) do
		if bar and bar.config then
			self:SetBarSpacing(bar, real)
		end
	end
end

function BTV:ApplyGlobalButtonSize()
	if not (self.bars and BTVanillaDB.globalButtonSizeEnabled) or
		BTVanillaDB.useDefaultLayout ~= false then
		return
	end

	local size = BTVanillaDB.globalButtonSizeValue or self.BUTTON_SIZE

	local barId
	local bar

	for barId, bar in pairs(self.bars) do
		if bar and bar.config then
			self:SetBarButtonSize(bar, size)
		end
	end
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
-- buttonCount can be smaller than cols*rows; ApplyBarShape shows/hides
-- pool slots to match. Every grid preset totals at most MAX_BAR_BUTTONS
-- (12, Core.lua), the pool size every custom bar allocates at creation.
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

	if cols * rows > self.MAX_BAR_BUTTONS then
		self:Print("Bar " .. tostring(bar.config.id) ..
			" layout cannot exceed " .. tostring(self.MAX_BAR_BUTTONS) ..
			" buttons.")
		return false
	end

	bar.config.cols = cols
	bar.config.rows = rows

	-- Clamps buttonCount down when the new grid has fewer cells; growing
	-- the grid back out does not restore a previously reduced buttonCount.
	local maxButtons = cols * rows
	local currentCount = bar.config.buttonCount or maxButtons

	if currentCount > maxButtons then
		bar.config.buttonCount = maxButtons
	end

	self:ApplyBarShape(bar)

	return true
end

-------------------------------------------------------------------------
-- Button count
--
-- Lets a custom bar show fewer than cols*rows buttons. Never resizes the
-- button pool itself - ApplyBarShape shows/hides existing pool slots.
-------------------------------------------------------------------------

function BTV:SetBarButtonCount(bar, count)
	if not bar or not bar.config then
		return false
	end

	count = tonumber(count)

	if not count then
		return false
	end

	count = math.floor(count)

	local maxButtons = bar.config.cols * bar.config.rows

	if count < 1 then
		count = 1
	end

	if count > maxButtons then
		count = maxButtons
	end

	bar.config.buttonCount = count

	self:ApplyBarShape(bar)

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

-- Finds the first free contiguous action-slot range of `neededCount`
-- slots. Scans the whole action-slot pool from ACTION_SLOT_START rather
-- than starting after the highest existing bar, so a slot freed by
-- deleting a bar in the middle of the range can be reused.
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

-- Page 10 (slots 109-120) is the only range no native paging mechanism
-- ever reaches (Bar 1's own paging tops out at page 6, slots 61-72; stance/
-- form/stealth paging only ever reaches pages 7-9, slots 73-108). New bars
-- prefer 109-120 first so pages 7-9 stay available for stance/page content
-- assignment, only falling back to 73-108 once page 10 is exhausted.
local PREFERRED_SLOT_START = 109

function BTV:GetNextFreeSlotStart(neededCount)
	if not neededCount or neededCount < 1 then
		return nil
	end

	local candidate

	for candidate = PREFERRED_SLOT_START,
		self.ACTION_SLOT_END - neededCount + 1 do

		if self:IsActionSlotRangeFree(candidate, neededCount, nil) then
			return candidate
		end
	end

	for candidate = self.ACTION_SLOT_START,
		PREFERRED_SLOT_START - 1 - neededCount + 1 do

		if self:IsActionSlotRangeFree(candidate, neededCount, nil) then
			return candidate
		end
	end

	return nil
end

-------------------------------------------------------------------------
-- Apply a bar's shape (grid, slotStart, buttonCount) to its existing
-- button pool
--
-- The button-slot pool is created once, in CreateBarFromConfig, and never
-- destroyed - bars are permanent, there is no bar deletion in this addon.
-- Any layout change (grid shape, button count, or slotStart) just:
--
--   1. Re-maps which action slot each pool slot points at (Rebind),
--   2. Shows pool slots up to buttonCount and hides the rest,
--   3. Repositions/resizes via the existing LayoutButtons math.
--
-- Rebind (Button.lua) keeps BTV.customBindTargets updated as each pool
-- slot's actionSlot changes, so a TRUSTYBARSBIND<n> binding (HoverBind.lua)
-- aimed at a specific action slot stays valid across any resize/relayout.
-------------------------------------------------------------------------

function BTV:ApplyBarShape(bar)
	if not bar or not bar.config or not bar.buttons then
		return
	end

	local cfg = bar.config

	-- Bars saved before buttonCount existed fall back to filling the
	-- whole grid.
	local buttonCount = cfg.buttonCount or (cfg.cols * cfg.rows)

	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			local desiredSlot
			local slotValid

			-- Fixed-slot bars (default bars 2-5) always rebind pool slot
			-- i to the same native action slot cfg.fixedActionSlots[i] -
			-- unlike a free-pool custom bar (id 6+), there is no
			-- slotStart to derive this from, and no ACTION_SLOT_END
			-- pool-range check applies (native slots 1-72 are outside the
			-- 73-120 pool range entirely).
			if cfg.fixedActionSlots then
				desiredSlot = cfg.fixedActionSlots[i]
				slotValid = desiredSlot ~= nil
			elseif cfg.dynamicMainBar then
				-- Bar 1 (Main) only: pool slot i has no single permanent
				-- action slot - it is recomputed every call from whichever
				-- page/bonus-bar state currently applies (see
				-- DefaultBars.lua's GetMainBarEffectivePage/
				-- GetMainBarSlotForIndex). Calling
				-- BTV:ApplyBarShape(BTV.bars[1]) after a page/stance change
				-- is enough to pick up the new slots.
				desiredSlot = self:GetMainBarSlotForIndex(i)
				slotValid = desiredSlot ~= nil
			else
				desiredSlot = cfg.slotStart + (i - 1)
				slotValid = desiredSlot <= self.ACTION_SLOT_END
			end

			if slotValid then
				btn:Rebind(desiredSlot)
				btn:SetSlotVisible(i <= buttonCount)
			else
				-- Only reachable from a corrupt/hand-edited SavedVariables
				-- entry - keep hidden rather than rebind to an invalid
				-- slot number.
				btn:SetSlotVisible(false)
			end
		end
	end

	local barW, barH = BarFrameSize(cfg)

	PixelSetSize(bar, barW, barH)

	-- Re-asserted on every call, not just once at creation: some native
	-- page-swap/stance-change path can re-level Bar 1 behind the native
	-- art frame otherwise. Harmless no-op for every other bar/trigger.
	bar:SetFrameStrata("HIGH")
	bar:SetFrameLevel(10)

	self:LayoutButtons(bar)

	-- Ensure this bar's overlay exists as soon as the bar itself does,
	-- rather than lazily deferring to the first edit-mode toggle. The
	-- overlay is anchored to `bar`, so no separate resize call is needed
	-- here even though PixelSetSize just changed the bar's dimensions.
	EnsureBarOverlay(bar)

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

	-- Strata HIGH, not MEDIUM: MEDIUM lets MainMenuBarArtFrame's own
	-- :Raise() (fired on native art bar click) push above the bar within
	-- the same tier and hide it behind the art. Button.lua also sets HIGH
	-- explicitly on every button rather than relying on strata inheritance.
	bar:SetFrameStrata("HIGH")

	-- Frame LEVEL (not creation order) decides stacking within a shared
	-- strata tier on this client. Comfortably below the overlay frames'
	-- own level 100 (EnsureBarOverlay reads bar:GetFrameLevel()
	-- relatively, so it always stays above this).
	bar:SetFrameLevel(10)

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

	-- The pool is sized to MAX_BAR_BUTTONS (12), the largest any current
	-- grid preset needs, once here, and never destroyed/recreated again
	-- (see ApplyBarShape). Slots beyond the bar's current buttonCount are
	-- hidden by the ApplyBarShape call below.
	local i

	for i = 1, self.MAX_BAR_BUTTONS do
		local slot

		-- Fixed-slot bars (default bars 2-5): each pool slot i is
		-- permanently tied to cfg.fixedActionSlots[i], a real native
		-- action slot discovered once from the live Blizzard button frame
		-- (Core.lua's CaptureFixedActionSlots) - never the free 73-120
		-- pool a real custom bar (id 6+) allocates from.
		if cfg.fixedActionSlots then
			slot = cfg.fixedActionSlots[i]

			if not slot then
				break
			end
		elseif cfg.dynamicMainBar then
			-- Bar 1 (Main) only, resolved the same way ApplyBarShape does
			-- - the initial pool-creation slot just needs to be a valid
			-- slot to bind to, since the ApplyBarShape call at the end of
			-- this function immediately re-resolves every button anyway.
			slot = self:GetMainBarSlotForIndex(i)

			if not slot then
				break
			end
		else
			slot = cfg.slotStart + (i - 1)

			if slot > self.ACTION_SLOT_END then
				self:Print(
					"Warning: Bar " .. tostring(cfg.id) ..
					" ran out of free action slots at button " ..
					tostring(i)
				)

				break
			end
		end

		bar.buttons[i] =
			self:CreateActionButton(
				bar,
				slot,
				i
			)
	end

	self:ApplyBarShape(bar)

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
			local bar = self:CreateBarFromConfig(cfg)

			self.bars[cfg.id] = bar

			-- Extra Bars (ids 6-9) default to hidden until cfg.enabled is
			-- set, mirroring CreateFixedSlotDefaultBars for default bars
			-- 2-5. Every other bar kind has no cfg.enabled field, so this
			-- is a no-op for anything but an Extra Bar.
			if self:IsExtraBarId(cfg.id) then
				if cfg.enabled then
					bar:Show()
				else
					bar:Hide()
				end
			end
		end
	end

	self:ApplyEditModeVisual()
end

-------------------------------------------------------------------------
-- Extra Bar enable/disable (ids 6-9)
--
-- Mirrors DefaultBars.lua's SetDefaultBarEnabled against a true custom-bar
-- config (bar.config IS this exact BTVanillaDB.bars[] entry). Capacity is
-- fixed at BTV.EXTRA_BAR_COUNT (4), seeded once by Core.lua's
-- EnsureExtraBars - there is no add/remove-bar flow.
-------------------------------------------------------------------------

function BTV:IsExtraBarId(barId)
	return barId ~= nil
		and barId >= self.EXTRA_BAR_ID_START
		and barId < self.EXTRA_BAR_ID_START + self.EXTRA_BAR_COUNT
end

function BTV:SetExtraBarEnabled(barId, enabled)
	local bar = self.bars and self.bars[barId]

	if not bar or not bar.config then
		return
	end

	enabled = enabled and true or false

	bar.config.enabled = enabled

	if enabled then
		bar:Show()
	else
		bar:Hide()
	end
end

-------------------------------------------------------------------------
-- Extra Bar slot lookup
--
-- Resolves pool-slot `slotIndex` (1-12) of Extra Bar `barId` to its
-- currently-bound native action slot - used by DefaultBars.lua's
-- GetMainBarSlotForIndex to read an assigned Extra Bar's own content.
-- Deliberately does not check bar.config.enabled or bar:IsShown(): an
-- Extra Bar assigned as a stance/page content source keeps supplying the
-- Main Bar regardless of whether it is separately shown as its own
-- visible bar.
-------------------------------------------------------------------------

function BTV:GetExtraBarSlotForIndex(barId, slotIndex)
	local bar = self.bars and self.bars[barId]

	if not bar or not bar.config or not bar.config.slotStart then
		return nil
	end

	local slot = bar.config.slotStart + (slotIndex - 1)

	if slot > self.ACTION_SLOT_END then
		return nil
	end

	return slot
end

-------------------------------------------------------------------------
-- Bar drag
--
-- Bars start/stop the same shared cursor-tracking OnUpdate loop
-- DefaultBars.lua's chain-anchored elements (Bag Bar, Micro Menu, Stance
-- Bar, Key Ring, Latency Bar, Experience Bar, Page Indicator) use for
-- live, real-time snap-while-dragging - see DefaultBars.lua's
-- BTV:StartSharedDrag/StopSharedDrag and its dragKind == "bar" branch,
-- which reads/writes bar.config.x/y directly and calls
-- BTV:ApplyBarPosition(bar) every tick.
-------------------------------------------------------------------------

function BTV:StartBarDrag(bar)
	if not bar or not bar.config then
		return
	end

	local cfg = bar.config

	-- Normalize to the TOPLEFT-of-bar/BOTTOMLEFT-of-UIParent anchor
	-- convention Core.lua's CaptureNativeAnchor and every chain-anchored
	-- element already use - needed because a real custom/Extra Bar (id 6+)
	-- is originally seeded CENTER/CENTER (Core.lua's seedExtraBarConfig),
	-- under which the same cfg.x/cfg.y numbers would mean an offset from
	-- screen CENTER rather than from UIParent's BOTTOMLEFT corner. Reading
	-- the bar's own real GetLeft()/GetTop() sidesteps converting between
	-- anchor conventions by hand; this is a one-time, permanent
	-- normalization.
	local scale = bar:GetEffectiveScale()
	local uiParentScale = UIParent:GetEffectiveScale()
	local left, top = bar:GetLeft(), bar:GetTop()

	if not scale or not uiParentScale or uiParentScale == 0 or not left or not top then
		return
	end

	cfg.point = "TOPLEFT"
	cfg.relativePoint = "BOTTOMLEFT"
	cfg.x = (left * scale) / uiParentScale
	cfg.y = (top * scale) / uiParentScale

	self:ApplyBarPosition(bar)

	self:StartSharedDrag("bar", cfg.id, cfg.x, cfg.y)
end

function BTV:StopBarDrag(bar)
	if not bar then
		return
	end

	self:StopSharedDrag()

	-- Keeps the Settings X/Y sliders in sync if this bar's page happens to
	-- already be built/cached. No-op if the Settings window/this bar's
	-- page was never opened this session.
	if bar.config and self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(bar.config.id)
	end
end
