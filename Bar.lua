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
--   buttonCount
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

-- cfg.spacing: default bars 1-5 have a real captured value (Core.lua's
-- CaptureNativeSpacing/seedDefaultBars); true custom bars (id 6+,
-- bug-fix batch Fix 4) are also given a real spacing = 0 field at
-- creation (Bar.lua's AddNewBar) so their own Settings-page slider has
-- something to read/write. The `or 0` fallback here now exists purely
-- for any bar saved before Fix 4 whose config predates that field.
local function BarFrameSize(cfg)
	local spacing = cfg.spacing or 0

	local width = (cfg.buttonSize * cfg.cols) + ((cfg.cols - 1) * spacing)
	local height = (cfg.buttonSize * cfg.rows) + ((cfg.rows - 1) * spacing)

	return width, height
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
	-- Every bar now has a real cfg.spacing field (default bars via
	-- Core.lua's CaptureNativeSpacing, custom bars via AddNewBar's
	-- explicit spacing = 0 - bug-fix batch Fix 4). `or 0` remains only as
	-- a fallback for a bar saved before Fix 4.
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
-- Consolidated (simplification pass) to fully own ALL edit-mode
-- interaction for a custom bar, exactly mirroring DefaultBars.lua's
-- EnsureDefaultBarOverlay/ApplyDefaultLayoutEditVisual pattern: while
-- BTV:IsEditMode() is true, this frame is mouse-enabled AND elevated to
-- "TOOLTIP" strata (above the bar/buttons' own round-34 "HIGH" - see
-- CreateBarFromConfig), so it wins every hit-test within its bounds and
-- intercepts drag AND right-click uniformly across the whole bar area -
-- button, gap, or beyond-buttonCount cell alike. Outside edit mode it
-- drops back to EnableMouse(false) and "HIGH" strata, becoming
-- completely inert so buttons regain unobstructed native interaction
-- (cast-on-click, native pickup-drag) exactly as if this overlay didn't
-- exist. This replaces the earlier "always-mouse-enabled, one level below
-- the buttons" approach, which depended on buttons individually declining
-- to shadow it via their own per-click IsEditMode() branches (Button.lua)
-- - see this simplification's task comment for why owning ALL interaction
-- here removes the need for those per-button branches.
--
-- Why a bar-level overlay is needed at all even though Button.lua's
-- per-button editOverlay already exists: custom bars lay out their
-- buttons with zero spacing (LayoutButtons above: xOff = col *
-- cfg.buttonSize, no gap term), so in principle the per-button overlays
-- should already look continuous - but a hidden pool slot (i >
-- buttonCount, SetSlotVisible(false)) leaves a real gap in the middle of
-- an otherwise-full row/column, and any button whose glow/equip-ring
-- OVERLAY-layer texture happens to still be racing the per-button tint on
-- a given frame can flash a visible seam. A single frame spanning the
-- bar's own bounding box has no such gaps by construction, and has no
-- button frame at all sitting over those beyond-buttonCount cells to
-- catch a right-click there. Kept ADDITIVE to the per-button tint
-- overlays (not a replacement) since Button.lua's editOverlay is still
-- what actually paints the individual-button tint.
--
-- BarFrameSize (cfg.buttonSize * cfg.cols/rows, plus any cfg.spacing -
-- bug-fix batch Fix 4 gave custom bars a real, user-adjustable spacing
-- field too) IS exactly the bar frame's own width/height, since
-- CreateBarFromConfig/SetBarButtonSize/ApplyBarShape all size `bar` itself
-- from that same formula - so unlike the default-bar overlay (which has
-- to independently derive a bounding box from the 12 real Blizzard button
-- frames' own positions), this one can simply SetAllPoints(bar) once and
-- never needs separate position/size math of its own, regardless of
-- whatever spacing value the bar currently has.
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

	-- Starts at HIGH strata / bar's own frame level (inert baseline,
	-- matching the bar/buttons' own round-34 "HIGH" strata - see
	-- CreateBarFromConfig's comment) - ApplyEditModeVisual below elevates
	-- to TOOLTIP + EnableMouse(true) for the duration of edit mode only.
	overlay:SetFrameStrata("HIGH")
	overlay:SetFrameLevel(bar:GetFrameLevel())
	overlay:SetAllPoints(bar)

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	tex:SetAllPoints(overlay)

	-- Round 36 (Item 2): hover border - a plain SetBackdrop edge (no
	-- bgFile, the blue tint texture above already fills that role), kept
	-- fully transparent until OnEnter/OnLeave below toggle it. Mirrors
	-- Button.lua's own SetBackdropBorderColor-toggle technique for its
	-- native-border buttons (Init/UpdateBackdropVisibility) rather than a
	-- separate texture, since a backdrop edge already gives a clean solid
	-- outline with no extra region to keep positioned/sized in sync.
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

	-- Round 36 (Item 2): centered element-name label, always visible while
	-- in edit mode (not just on hover) - reuses BTV:GetBarDisplayName
	-- (Core.lua), the exact same friendly name Settings.lua's bar list/page
	-- title already shows, so there's no separate/divergent name invented
	-- here. A plain child FontString has no Show/Hide of its own called
	-- anywhere - it simply inherits overlay's own Show()/Hide() state
	-- (ApplyEditModeVisual below), the same "shown exactly whenever the
	-- blue tint is" gate the task calls for, with no separate bookkeeping.
	local nameText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nameText:SetPoint("CENTER", overlay, "CENTER", 0, 0)
	nameText:SetText(BTV:GetBarDisplayName(bar.config.id))

	-- Owns dragging directly (SetScript, not HookScript - this is
	-- entirely our own frame with no native behavior to preserve),
	-- exactly mirroring DefaultBars.lua's EnsureDefaultBarOverlay.
	-- RegisterForDrag is registered once here unconditionally - only
	-- EnableMouse/strata are toggled per edit-mode state, in
	-- ApplyEditModeVisual below.
	overlay:RegisterForDrag("LeftButton")
	overlay:SetScript("OnDragStart", function()
		BTV:StartBarDrag(bar)
	end)
	overlay:SetScript("OnDragStop", function()
		BTV:StopBarDrag(bar)
	end)

	-- Right-click-to-settings. While this overlay is mouse-enabled (edit
	-- mode only) it fully covers the real buttons underneath, so their
	-- own right-click handling can no longer receive the event at all -
	-- this is now the ONLY place that opens bar settings via right-click.
	overlay:SetScript("OnMouseUp", function()
		if arg1 == "RightButton" then
			BTV:OpenBarSettings(bar)
		end
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
		-- Bug-fix batch round 3, Bug 1: bars 1-5 are only EVER individually
		-- draggable (i.e. each button independently movable) when edit mode
		-- is on AND useDefaultLayout == false - DefaultBars.lua's own
		-- CanDragDefaultLayout() is exactly this same condition. When
		-- useDefaultLayout == true, the whole bar is locked to its default
		-- position as a single unit (no per-button dragging is possible
		-- either way), so per-button tinting must be suppressed exactly
		-- like it already correctly is whenever useDefaultLayout == false
		-- and edit mode is off. This used to only gate the bar-level
		-- overlay (below) - the per-button tint loop unconditionally used
		-- `editMode` on its own, which is what let individual buttons on
		-- bars 1-5 light up blue even while useDefaultLayout == true, even
		-- though the whole-bar overlay (the only thing actually draggable
		-- in that state) stayed correctly hidden. Computed BEFORE the
		-- button loop now so both the per-button tint and the bar-level
		-- overlay agree on the exact same "is this button/bar actually
		-- individually draggable right now" condition.
		local isDefaultBar1to5 = barId and barId >= 1 and barId <= 5

		local canEdit = editMode

		if isDefaultBar1to5 then
			canEdit = editMode and BTVanillaDB and BTVanillaDB.useDefaultLayout == false
		end

		-- Per-button tint (the old btn:SetEditModeVisual(canEdit) call
		-- here) is REMOVED outright, not just re-gated: the user tested the
		-- prior round's canEdit-gated fix and decided the per-button tint
		-- "looks weird" in every state, for every bar (default 1-5 and
		-- custom 6+ alike) - not only when useDefaultLayout == true. The
		-- bar-level overlay hitbox tint below (EnsureBarOverlay's own
		-- texture) is the ONLY edit-mode tint left anywhere - it already
		-- correctly represents "this whole bar is draggable as a unit" with
		-- no per-button redundancy needed on top of it. Button.lua's
		-- SetEditModeVisual/self.editOverlay are now unused (confirmed by
		-- inspection - no other call site exists anywhere in this addon);
		-- left in place rather than deleted since removing the call site
		-- here is the smallest, safest change, and the method does nothing
		-- but toggle that one now-permanently-hidden texture.
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn then
					-- Issue 3 (bug-fix batch v5): re-evaluate final Show/
					-- Hide state the moment edit mode toggles, not just next
					-- time some other refresh happens to run - mirrors the
					-- ACTIONBAR_SHOWGRID/ACTIONBAR_HIDEGRID sweep in
					-- Button.lua (gridVisibilityFrame's OnEvent above),
					-- which walks every live custom-bar button the same
					-- way. UpdateGridVisibility itself now also checks
					-- BTV:IsEditMode() (see Button.lua), so this call makes
					-- empty slots become visible/interactable immediately
					-- on entering edit mode, and correctly revert (hide
					-- empty slots again per normal rules) immediately on
					-- exiting.
					btn:UpdateGridVisibility()
				end
			end
		end

		-- Bar-level overlay, additive to the per-button tint overlays
		-- above - see EnsureBarOverlay's comment. Now fully owns edit-mode
		-- interaction: mouse-enabled and elevated to TOOLTIP strata (above
		-- the bar/buttons' own round-34 "HIGH" - see CreateBarFromConfig's
		-- comment) only while editMode is true, so it intercepts every
		-- drag/right-click within its bounds during that window and is
		-- otherwise completely inert - mirrors DefaultBars.lua's
		-- ApplyDefaultLayoutEditVisual gating its own overlay's EnableMouse
		-- the same way (that overlay has needed TOOLTIP, not just HIGH,
		-- since the "bug-fix batch" filled-multibar-button strata gap - see
		-- EnsureDefaultBarOverlay's own comment - and this overlay now
		-- needs the exact same headroom now that the buttons underneath it
		-- are "HIGH" too, not "MEDIUM").
		if bar then
			local overlay = EnsureBarOverlay(bar)

			overlay:EnableMouse(canEdit and true or false)

			if canEdit then
				overlay:SetFrameStrata("TOOLTIP")
				overlay:Show()

				-- Round 36 (Item 2): reset the hover border to invisible every
				-- time edit mode is (re-)entered, rather than leaving whatever
				-- state a stale OnEnter left it in from a previous edit-mode
				-- session (mouse was left sitting over the overlay the instant
				-- edit mode turned off, so OnLeave never fired) - without this
				-- the border could appear "stuck" on at the very start of a
				-- new edit-mode session, before the mouse next actually
				-- leaves/re-enters this overlay.
				overlay:SetBackdropBorderColor(0, 0, 0, 0)
			else
				overlay:SetFrameStrata("HIGH")
				overlay:Hide()
			end
		end
	end

	-- Issue 3 (bug-fix batch): default-bar/stance-bar overlays live in
	-- DefaultBars.lua (they're gated on CanDragDefaultLayout, not just
	-- edit mode, unlike custom bars above) - folded in here rather than
	-- added as a separate call at every one of this function's own call
	-- sites, so both bar kinds' overlays always update together.
	-- Defensive existence check: DefaultBars.lua loads before this file
	-- per BTVanilla.toc, so this is always defined in practice, but the
	-- rest of this codebase already prefers this guard for cross-file
	-- calls (see e.g. RefreshBarSettingsPage in DefaultBars.lua).
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
-- Spacing (true custom bars, id 6+)
--
-- Fix 4 (bug-fix batch): mirrors DefaultBars.lua's SetDefaultBarSpacing
-- structure exactly (clamp, write, reapply) - the only difference is this
-- one always writes straight to bar.config (a real custom bar's cfg IS
-- its own BTVanillaDB.bars[] entry, no id==1-vs-2-5 branch needed here)
-- and reapplies via ApplyBarShape, which already re-lays-out the grid from
-- whatever cfg.spacing now holds (LayoutButtons/BarFrameSize above both
-- already read cfg.spacing generically for any bar that has it).
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

	if spacing < 0 then
		spacing = 0
	end

	if spacing > 20 then
		spacing = 20
	end

	bar.config.spacing = spacing

	self:ApplyBarShape(bar)
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
-- All current grid presets total exactly 12 buttons (see Core.lua's
-- MAX_BAR_BUTTONS), which is also the pool size every custom bar
-- allocates once at creation - so a plain cols*rows change never needs
-- more pool slots than already exist. The hard "must equal 12" rejection
-- has been dropped: buttonCount is allowed to be decoupled from
-- cols*rows (Phase 3b UI work), ApplyBarShape already shows/hides pool
-- slots to match whatever buttonCount ends up being.
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

	-- A shrinking grid can leave a previously-chosen buttonCount pointing
	-- past the new cell count (e.g. 12 -> 6 cells while buttonCount was
	-- 9). Clamp it down to fit. Growing the grid back out deliberately
	-- does NOT restore the old buttonCount - the user's explicit choice
	-- to show fewer buttons should not be silently discarded just
	-- because the grid got bigger again.
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
-- Lets a custom bar show fewer than cols*rows buttons (Phase 3b). Driven
-- by the Settings UI's +/- stepper. Unlike SetBarLayout, this never
-- resizes the button pool itself - ApplyBarShape simply shows/hides
-- existing pool slots per Phase 2's stable-frame model.
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

-- Main Bar migration, Part 5: page 10 (slots 109-120) is the ONLY range no
-- native mechanism ever reaches - confirmed via real FrameXML source that
-- Bar 1's own paging tops out at page 6 (slots 61-72) and
-- GetBonusBarOffset() (stance/form/stealth) only ever maps to pages 7-9
-- (slots 73-108), never page 10. Slots 73-108 are still perfectly usable
-- for a custom bar, but for a stance-capable class with the Main Bar's own
-- Stance/Form/Stealth Swapping toggle (DefaultBars.lua's
-- GetMainBarEffectivePage) enabled, they can show the same content the
-- Main Bar itself is currently displaying while shapeshifted/stealthed -
-- so new bars prefer 109-120 first, only falling back to 73-108 once page
-- 10's 12 slots are exhausted.
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

	self:ApplyBarShape(bar)

	return true
end

-------------------------------------------------------------------------
-- Destroy buttons belonging to a bar
--
-- Reserved for actual bar DELETION (Settings.lua's Delete Bar flow) only.
-- Every other layout/resize/slot-move operation goes through
-- ApplyBarShape instead, which reuses the existing pool rather than
-- tearing it down - see the file-level ApplyBarShape comment below for
-- why (Rebind keeps BTV.customBindTargets, HoverBind.lua's slot->button
-- dispatch table, correctly pointed at the right frame across relayouts).
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

			-- Clear this slot's HoverBind.lua dispatch target (see
			-- BTV.customBindTargets/Button.lua's Rebind) so a deleted bar's
			-- TRUSTYBARSBIND<n> entry can never fire against a hidden,
			-- script-stripped button - if another bar later reclaims this
			-- action slot, its own Init/Rebind repopulates the entry.
			-- Range-guarded (>= ACTION_SLOT_START): fixed-slot default bars
			-- (2-5, major architecture migration) point at real native
			-- slots (1-72), which were never registered into
			-- customBindTargets in the first place (see Button.lua's
			-- Init/Rebind) - this function is never actually called for
			-- those bars (they're not deletable), but the guard keeps this
			-- consistent with Init/Rebind's own rule regardless.
			if BTV.customBindTargets and btn.actionSlot and btn.actionSlot >= BTV.ACTION_SLOT_START then
				BTV.customBindTargets[btn.actionSlot - 72] = nil
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
-- Apply a bar's shape (grid, slotStart, buttonCount) to its existing
-- button pool
--
-- This is the replacement for the old RebuildBarButtons/DestroyBarButtons
-- destroy-and-recreate cycle. The pool of button-slot frames is created
-- exactly once, in CreateBarFromConfig, and never destroyed again until
-- the bar itself is deleted (BTV:DestroyBarButtons). Every layout change
-- - grid shape, button count, or slotStart - just:
--
--   1. Re-maps which action slot each pool slot points at (Rebind),
--   2. Shows pool slots up to buttonCount and hides the rest,
--   3. Repositions/resizes via the existing LayoutButtons math.
--
-- Because Rebind (Button.lua) keeps BTV.customBindTargets updated as
-- each pool slot's actionSlot changes, a TRUSTYBARSBIND<n> binding
-- (HoverBind.lua) aimed at a specific action slot stays valid across
-- any resize/relayout of that bar.
-------------------------------------------------------------------------

function BTV:ApplyBarShape(bar)
	if not bar or not bar.config or not bar.buttons then
		return
	end

	local cfg = bar.config

	-- Bars saved before Phase 3b never wrote buttonCount, so fall back to
	-- filling the whole grid - that was the only possible behavior then.
	local buttonCount = cfg.buttonCount or (cfg.cols * cfg.rows)

	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			local desiredSlot
			local slotValid

			-- Fixed-slot bars (default bars 2-5, major architecture
			-- migration) always rebind pool slot i to the SAME real native
			-- action slot cfg.fixedActionSlots[i] every time - unlike a
			-- free-pool custom bar (id 6+), there's no slotStart to derive
			-- this from, and no ACTION_SLOT_END pool-range check applies at
			-- all (native slots 1-72 are outside that pool's 73-120 range
			-- entirely).
			if cfg.fixedActionSlots then
				desiredSlot = cfg.fixedActionSlots[i]
				slotValid = desiredSlot ~= nil
			elseif cfg.dynamicMainBar then
				-- Bar 1 (Main) only (Main Bar migration, schema version 7):
				-- unlike a fixed-slot default bar (2-5), pool slot i has no
				-- single permanent action slot - it's recomputed every call
				-- from whichever page/bonus-bar state currently applies (see
				-- DefaultBars.lua's GetMainBarEffectivePage/
				-- GetMainBarSlotForIndex). ApplyBarShape already re-runs this
				-- for every button on every call, so calling this here means
				-- a page/stance change just needs to call
				-- BTV:ApplyBarShape(BTV.bars[1]) (DefaultBars.lua's
				-- RefreshMainBarSlots) to take effect - no separate resolve-
				-- and-diff step is needed.
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
				-- Out of the valid action-slot range entirely (only
				-- possible from a corrupt/hand-edited SavedVariables
				-- entry) - keep it hidden rather than rebinding to an
				-- invalid slot number.
				btn:SetSlotVisible(false)
			end
		end
	end

	local barW, barH = BarFrameSize(cfg)

	PixelSetSize(bar, barW, barH)

	-- Bug-fix batch round 3, Bug 2: re-assert strata/level on every
	-- ApplyBarShape call, not just once at CreateBarFromConfig time (see
	-- that function's own comment on why this matters). ApplyBarShape is
	-- exactly what RefreshMainBarSlots (DefaultBars.lua) calls on every
	-- native page swap (ChangeActionBarPage hook) and every stance/form/
	-- stealth change (UPDATE_BONUS_ACTIONBAR handler) - live testing
	-- confirmed Bar 1 drops back behind the native art specifically after
	-- one of those two triggers, meaning something in that path re-levels
	-- either Bar 1's own frame or MainMenuBarArtFrame itself back above
	-- the one-shot login-time value. Cheap and idempotent for every other
	-- bar/trigger (SetFrameStrata/SetFrameLevel to their own current
	-- values is a harmless no-op), so this is applied unconditionally
	-- here rather than only from the two Main-Bar-specific call sites.
	--
	-- Round 34: this is now a "HIGH"-strata reassertion, not "MEDIUM" -
	-- see CreateBarFromConfig's own comment for the full history of why a
	-- same-tier level race against MainMenuBarArtFrame (round 2 through
	-- round 24) was never fully robust, and why a full strata-tier
	-- separation (matching this file's own BuildChainAnchoredContainer/
	-- DefaultBars.lua's EnsureExpBarTextOverlay precedent) is the fix that
	-- finally makes this permanently immune to ANY future level change on
	-- the art frame's part. MainMenuBarArtFrame itself is untouched here
	-- and stays at its own "MEDIUM" strata/level 5 (DefaultBars.lua's
	-- ApplyBlizzardArtVisibility) - still correctly needed for the
	-- separate art-above-Experience-Bar masking relationship - since
	-- "HIGH" beats "MEDIUM" unconditionally regardless of either frame's
	-- level, both relationships hold at once with no further tuning.
	bar:SetFrameStrata("HIGH")
	bar:SetFrameLevel(10)

	self:LayoutButtons(bar)

	-- Issue 4 (bug-fix batch): ensure this bar's overlay exists as soon as
	-- the bar itself does, rather than lazily deferring creation to the
	-- first edit-mode toggle - mirrors ApplyDefaultBarShape keeping
	-- EnsureDefaultBarOverlay in sync on every call. SetAllPoints(bar) at
	-- creation (see EnsureBarOverlay) means no separate resize call is
	-- needed here even though PixelSetSize just changed bar's own
	-- dimensions - the overlay's anchor to `bar` already tracks that.
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

	-- Round 34 fix: promoted from "MEDIUM" to "HIGH" strata outright,
	-- replacing the old same-tier level race against MainMenuBarArtFrame
	-- entirely. History: round 2 (Issue C, see below) found Bar 1 losing a
	-- same-"MEDIUM"-strata level tie against the art frame and fixed it
	-- with an explicit SetFrameLevel(10); round 24 (DefaultBars.lua's
	-- ApplyBlizzardArtVisibility) pinned the art frame to an explicit
	-- level 5, strictly below this bar's level 10, to fix that same
	-- relationship while ALSO restoring the Experience Bar's own fill-
	-- masking (which needs the art frame to stay in "MEDIUM", above
	-- MainMenuExpBar's level 2). That worked only for as long as nothing
	-- else ever raised the art frame's level past 10 within that shared
	-- tier - live-confirmed broken by a genuinely dynamic trigger this
	-- round: clicking anywhere on the native Blizzard art bar that isn't
	-- one of our own buttons raises the art frame's OWN level (a common
	-- vanilla FrameXML `:Raise()`-on-click pattern), pushing it back above
	-- this bar's level 10 and making Bar 1 disappear behind the art again
	-- - reproducing exactly the round-2 symptom from a different trigger.
	-- Frame STRATA fully dominates frame LEVEL regardless of tier (see
	-- Settings.lua's own documented strata-tier ordering comment,
	-- BACKGROUND < LOW < MEDIUM < HIGH < ...) - moving to "HIGH" makes
	-- this permanently immune to ANY future level change on the art
	-- frame's part, ours or Blizzard's, rather than re-chasing whatever
	-- level it happens to reach next. Matches the exact same "HIGH beats
	-- MainMenuBarArtFrame's MEDIUM unconditionally" precedent this file's
	-- own BuildChainAnchoredContainer (Bag Bar/Micro Menu/Stance Bar) and
	-- DefaultBars.lua's EnsureExpBarTextOverlay already established -
	-- those were never vulnerable to this bug in the first place because
	-- they were already a full tier above, not just a higher level within
	-- the same tier. Does NOT touch MainMenuBarArtFrame's own "MEDIUM"
	-- strata/level 5 (still needed, unchanged, for the separate
	-- art-above-Experience-Bar masking relationship) - "HIGH" beats
	-- "MEDIUM" unconditionally no matter what level either frame is at, so
	-- both relationships hold simultaneously with no further tuning.
	--
	-- Button.lua's BTVButtonMixin:Init gives every individual button
	-- (and its cooldown-swipe child frame) this exact same explicit
	-- "HIGH" strata too, rather than assuming it would simply inherit
	-- this bar's own value - see docs/01-Environment-Capability-
	-- Analysis.md's round-34 entry for why that assumption is left an
	-- open (still-not-live-confirmed) question rather than guessed on:
	-- every frame in this codebase that needs a non-default strata
	-- already sets it explicitly on itself, so this round follows the
	-- same convention instead of depending on inheritance either way.
	-- This bar frame's own backdrop is fully transparent (see
	-- SetBackdropColor(0,0,0,0) below) and was never itself the thing
	-- visually racing the art frame; the buttons are, which is why they
	-- need this explicit treatment regardless of how inheritance works.
	bar:SetFrameStrata("HIGH")

	-- Issue C (bug-fix batch round 2, level ordering AMONG our own bars/
	-- overlays only as of round 34 - see this function's own strata
	-- comment above for why it's no longer what wins the fight against
	-- MainMenuBarArtFrame): without an explicit frame LEVEL, a freshly
	-- CreateFrame(..., UIParent)'d frame starts at whatever low level
	-- UIParent's own child-nesting default assigns it - within a shared
	-- strata tier, frame LEVEL (not creation order) is what actually
	-- decides stacking (same rule already established in this codebase
	-- for EnsureDefaultBarOverlay/EnsureContainerOverlay's own explicit
	-- high levels - see their comments on this same client-specific
	-- tie-break behavior). Applied uniformly to every bar (all of 1-5 and
	-- every custom bar 6+ share this one creation path) - comfortably
	-- higher than any other "HIGH"-strata frame this bar needs to sit
	-- under, with plenty of headroom below the overlay frames' own level
	-- 100 (Bar.lua's EnsureBarOverlay reads bar:GetFrameLevel() relatively,
	-- so it always stays correctly above whatever this is set to).
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

	-- The pool is sized to MAX_BAR_BUTTONS (12) - the largest any current
	-- grid preset needs - once, here, and never destroyed/recreated again
	-- (see ApplyBarShape). Slots beyond the bar's current buttonCount are
	-- simply hidden by the ApplyBarShape call below.
	local i

	for i = 1, self.MAX_BAR_BUTTONS do
		local slot

		-- Fixed-slot bars (default bars 2-5, major architecture
		-- migration): each pool slot i is permanently tied to
		-- cfg.fixedActionSlots[i], a REAL native action slot discovered
		-- once from the live Blizzard button frame (Core.lua's
		-- CaptureFixedActionSlots) - never the free 73-120 pool a real
		-- custom bar (id 6+) allocates from.
		if cfg.fixedActionSlots then
			slot = cfg.fixedActionSlots[i]

			if not slot then
				break
			end
		elseif cfg.dynamicMainBar then
			-- Bar 1 (Main) only - resolved the same way ApplyBarShape does
			-- (see its own comment above); the initial pool-creation slot
			-- just needs to be A valid slot to bind to, since the
			-- ApplyBarShape call at the end of this function immediately
			-- re-resolves every button anyway.
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

			-- Extra Bars (ids 6-9, Stance/Page Bar Assignment feature,
			-- Part 1): honor cfg.enabled the same way
			-- CreateFixedSlotDefaultBars honors it for default bars 2-5 -
			-- a fresh bar defaults to Hidden until enabled, matching
			-- cfg.enabled's own default-false seed (Core.lua's
			-- seedExtraBarConfig). Every OTHER bar kind (a real default
			-- bar 1-5 is never built here at all - see
			-- CreateFixedSlotDefaultBars instead) has no cfg.enabled
			-- field, so this is a no-op for anything but an Extra Bar.
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
-- Extra Bar enable/disable (ids 6-9, Stance/Page Bar Assignment feature,
-- Part 1)
--
-- Mirrors DefaultBars.lua's SetDefaultBarEnabled exactly (cfg.enabled +
-- a plain bar:Show()/Hide(), the sole visibility mechanism) - just
-- against a true custom-bar config (bar.config IS this exact
-- BTVanillaDB.bars[] entry, not BTVanillaDB.defaultBars, and there's no
-- id == 1 "always active, no toggle" special case to skip here).
--
-- The old open-ended "Add New Bar" flow (Bar.lua's removed AddNewBar/
-- GetNextBarId, Menu.lua's removed menu entry, Settings.lua's removed
-- "+ Add New Bar" list button) is gone - capacity is now fixed at exactly
-- BTV.EXTRA_BAR_COUNT (4), seeded once by Core.lua's EnsureExtraBars, so
-- a user enables/disables an already-existing Extra Bar rather than
-- adding/removing one.
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
-- Extra Bar slot lookup (Stance/Page Bar Assignment feature, Part 3)
--
-- Resolves pool-slot `slotIndex` (1-12) of Extra Bar `barId` to its real,
-- currently-bound native action slot - used by DefaultBars.lua's
-- GetMainBarSlotForIndex to read an assigned Extra Bar's OWN content
-- straight off its live cfg.slotStart, instead of computing a native page
-- number. Deliberately does NOT check bar.config.enabled or bar:IsShown()
-- - an Extra Bar assigned as a stance/page content source keeps supplying
-- the Main Bar regardless of whether that Extra Bar is separately shown
-- as its own visible bar (Part 3's own "assignment always works for
-- content resolution" design decision - see this feature's task record).
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
-- Round 36 (unify bar dragging with the chain-anchored live-drag system):
-- bars 1-9 used to drag via native bar:StartMoving()/StopMovingOrSizing(),
-- which gives NO per-frame hook during the drag itself - snap could only
-- ever be applied once, at drop time (the old ApplyBarDropSnap, removed).
-- Bars now start/stop the exact same shared cursor-tracking OnUpdate loop
-- DefaultBars.lua's 7 chain-anchored elements (Bag Bar, Micro Menu, Stance
-- Bar, Key Ring, Latency Bar, Experience Bar, Page Indicator) already use
-- for live, real-time snap-while-dragging - see DefaultBars.lua's
-- BTV:StartSharedDrag/StopSharedDrag (the exposed seam onto that file's
-- own file-local dragFrame/DefaultBarDrag_OnUpdate machinery) and its
-- dragKind == "bar" branch, which reads/writes bar.config.x/y directly
-- and calls BTV:ApplyBarPosition(bar) every tick - the cheapest correct
-- reposition-only call (ApplyBarShape would also redundantly re-bind
-- every button's action slot, resize the bar frame, and re-run
-- LayoutButtons on every single tick, none of which changes during a pure
-- position drag). No bar frame calls StartMoving()/StopMovingOrSizing()
-- anywhere in this addon anymore.
-------------------------------------------------------------------------

function BTV:StartBarDrag(bar)
	if not bar or not bar.config then
		return
	end

	local cfg = bar.config

	-- Normalize to the exact TOPLEFT-of-bar/BOTTOMLEFT-of-UIParent anchor
	-- convention Core.lua's CaptureNativeAnchor and every one of
	-- DefaultBars.lua's 7 chain-anchored elements already use (see
	-- DefaultBars.lua's ApplyDragSnap comment on why this pairing is
	-- required) - necessary because a real custom/Extra Bar (id 6+) is
	-- originally seeded CENTER/CENTER (Core.lua's seedExtraBarConfig),
	-- under which the same cfg.x/cfg.y numbers would mean an offset from
	-- screen CENTER, not from UIParent's BOTTOMLEFT corner, and the shared
	-- drag mechanism's per-tick math only ever works in that one
	-- convention. Reading the bar's own real GetLeft()/GetTop() sidesteps
	-- having to convert between anchor conventions by hand, exactly like
	-- CaptureNativeAnchor already does for default bars 1-5 (this is a
	-- one-time, permanent normalization - once a bar has been dragged
	-- through this addon once, it stays TOPLEFT/BOTTOMLEFT from then on).
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
	-- already be built/cached - same pattern as every one of the 7 chain-
	-- anchored elements' own Stop*Drag (e.g. StopBagBarDrag). A no-op if
	-- the Settings window/this bar's page was never opened this session.
	if bar.config and self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(bar.config.id)
	end
end