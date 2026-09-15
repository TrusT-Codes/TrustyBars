-- Core.lua
-- AlternativeClassicActionBars: Bartender2-style action bar addon for Vanilla 1.12.1.
-- No SecureHandler system on this client - buttons are backed by real action slots 73-120 (pages 7-10, unused by default UI).
-- SetPoint/SetSize are unrestricted during combat; InCombatLockdown() always returns false here.
-- Lua 5.0 has no `%` operator - use n - (math.floor(n/d)*d) instead.

AlternativeClassicActionBars = {}
local ACAB = AlternativeClassicActionBars

-- Action slot pool: pages 7-10, never surfaced by the default Blizzard UI.
ACAB.ACTION_SLOT_START = 73
ACAB.ACTION_SLOT_END   = 120

-- Defaults used when creating a NEW bar. Existing bars keep their own
-- saved config.
ACAB.BUTTON_SIZE = 36
ACAB.BUTTON_COLS = 12
ACAB.BUTTON_ROWS = 1

-- Minimum bar spacing while vanilla border style is active, to avoid the
-- native border texture's overhang causing adjacent buttons to overlap.
-- 0 in modern style.
ACAB.VANILLA_SPACING_FLOOR = 4

-- Extra buttonSize modern-style buttons need over vanilla-style buttons to
-- look the same size; spacing shifts by the same amount in the opposite
-- direction on a style switch (see ACAB:ApplyGlobalButtonStyle).
ACAB.MODERN_BUTTON_SIZE_DELTA = 4

-- Position nudge paired with MODERN_BUTTON_SIZE_DELTA so an anchored
-- (non-centered) bar doesn't visually shift when buttonSize changes.
ACAB.MODERN_BUTTON_SIZE_POSITION_SHIFT = 2

-- Fixed pool size for a custom bar's button slots (every grid preset totals
-- 12). Buttons beyond buttonCount are hidden, not destroyed, so bound
-- action slots stay valid across resizes.
ACAB.MAX_BAR_BUTTONS = 12

-- Equip-quality ring size ratio, matching vanilla's own ActionButtonTemplate.
ACAB.EQUIP_RING_RATIO = 62 / 36

-- Native border texture ("Interface\Buttons\UI-Quickslot2") ratio to
-- button size (66/36 at the default 36px button).
ACAB.BORDER_RATIO = 66 / 36

-- Vertical anchor offset of the native border texture (1px down from
-- center) - asymmetric top/bottom overhang.
ACAB.BORDER_Y_OFFSET = 1

-- Flat pixel amount subtracted from the border's visual inset on every
-- side (transparent padding baked into the border texture asset).
ACAB.BORDER_TEXTURE_FUDGE = 12

-- Extra top-only trim on top of GetHitRectInsets() for Micro Menu - shared
-- by the edit-mode overlay's top anchor and the grid layout's row spacing,
-- so both stay in sync off one value.
ACAB.MICRO_MENU_OVERLAY_TOP_FUDGE = 2

-- Latency Bar edit-mode overlay inset - MainMenuBarPerformanceBarFrame's
-- visible bar art sits inside a larger frame with transparent padding.
ACAB.LATENCY_BAR_OVERLAY_INSET = { left = 1, right = 6.5, top = 14, bottom = 11 }

-- "Snap to Adjacent Elements": how close (real screen pixels) a dragged
-- edge must get to another edge before it snaps.
ACAB.SNAP_THRESHOLD = 8


-- Pet Bar: a 6th default-bar family member, wrapping PetActionButton1-10.
-- Not backed by the 1-120 action-slot pool (see Button.lua's isPetSlot
-- branch) - fixedActionSlots here is a pet-slot identity map (1-10).
ACAB.PET_BAR_ID = 10

-- Stance Bar: a 7th default-bar family member, styled-mode-only entry.
-- Drives only the opt-in custom-styled grid mode (Button.lua's isStanceSlot
-- branch); the native mode (ShapeshiftButton1-N) keeps its own separate
-- ACABDB.stanceBar* fields untouched. Active mode is
-- cfg.useNativeStanceBar, resolved via ACAB:IsStanceBarNativeModeEffective().
ACAB.STANCE_BAR_ID = 11

-- Every default-bar-family id, in display order. Loops that need to cover
-- "the whole default-bar family" (bars 1-5, Pet Bar, Stance Bar) iterate
-- this instead of a hardcoded 1-5 range.
ACAB.DEFAULT_BAR_IDS = { 1, 2, 3, 4, 5, ACAB.PET_BAR_ID, ACAB.STANCE_BAR_ID }

-- True for any id in ACAB.DEFAULT_BAR_IDS - the shared predicate every
-- useDefaultLayout-lock/"is this a default bar" check reads instead of a
-- hardcoded id range.
function ACAB:IsDefaultBarFamilyId(barId)
	if not barId then
		return false
	end

	local i

	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		if self.DEFAULT_BAR_IDS[i] == barId then
			return true
		end
	end

	return false
end

-- Grid shape for each default bar. Position is captured live, not stored
-- here - see CaptureNativeAnchor.
ACAB.DEFAULT_BAR_GRID = {
	[1] = { cols = 12, rows = 1 },                      -- Main.
	[2] = { cols = 12, rows = 1, enabled = false },      -- Bottom Left.
	[3] = { cols = 12, rows = 1, enabled = false },      -- Bottom Right.
	[4] = { cols = 1,  rows = 12, enabled = false },     -- Right.
	[5] = { cols = 1,  rows = 12, enabled = false },     -- Right 2.
	-- Pet Bar/Stance Bar default enabled - both always show via a native-mode
	-- counterpart with no enable/disable of its own.
	[ACAB.PET_BAR_ID] = { cols = 10, rows = 1, enabled = true }, -- Pet Bar.
	-- Stance Bar base preset only - SeedOneDefaultBar overrides cols/rows
	-- from the live GetNumShapeshiftForms() count.
	[ACAB.STANCE_BAR_ID] = { cols = 10, rows = 1, enabled = true },
}

-- Native FrameXML global backing each default bar's Interface Options
-- checkbox. Session-scoped only - doesn't persist across logout, so never
-- read as the source of truth for what to apply at login.
ACAB.SHOW_MULTI_ACTIONBAR_GLOBAL = {
	[2] = "SHOW_MULTI_ACTIONBAR_1",
	[3] = "SHOW_MULTI_ACTIONBAR_2",
	[4] = "SHOW_MULTI_ACTIONBAR_3",
	[5] = "SHOW_MULTI_ACTIONBAR_4",
}

-- Friendly display names for the default-bar family.
ACAB.DEFAULT_BAR_NAMES = {
	[1] = "Main Bar",
	[2] = "Action Bar 1",
	[3] = "Action Bar 2",
	[4] = "Right Action Bar 1",
	[5] = "Right Action Bar 2",
	[ACAB.PET_BAR_ID] = "Pet Bar",
	[ACAB.STANCE_BAR_ID] = "Stance Bar",
}

-- Extra Bars (ids EXTRA_BAR_ID_START..+COUNT-1) are numbered from 1 for
-- the user. String-keyed chain-anchored elements (Bag Bar, Stance Bar,
-- etc.) are handled separately via EnsureContainerOverlay's displayName
-- argument.
function ACAB:GetBarDisplayName(barId)
	if self.DEFAULT_BAR_NAMES[barId] then
		return self.DEFAULT_BAR_NAMES[barId]
	end

	if barId and barId >= 1 and barId <= 5 then
		return "Bar " .. tostring(barId)
	end

	return "Extra Bar " .. tostring((barId or 0) - 5)
end


-------------------------------------------------------------------------
-- Extra Bars 1-4 (ids 6-9)
--
-- Always exist in ACABDB.bars, toggled via cfg.enabled rather than
-- added/removed. Each is still a real Bar.lua custom bar under the hood.
-------------------------------------------------------------------------

ACAB.EXTRA_BAR_ID_START = 6
ACAB.EXTRA_BAR_COUNT = 4


-- Shared with the edit-mode message's colored key names below.
ACAB.CHAT_PREFIX_COLOR = "|cff33ccff"

function ACAB:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(self.CHAT_PREFIX_COLOR .. "[ACAB]|r " .. tostring(msg))
end

-- Hides `frame` and permanently neuters its Show() to a no-op, so no
-- later native code path (e.g. a re-run FrameXML update function) can
-- make it visible again. Idempotent via frame.ACABShowNeutered - safe to
-- call every time the caller's own reason to hide `frame` recurs.
function ACAB:NeuterFrameShow(frame)
	if not frame then
		return
	end

	frame:Hide()

	if not frame.ACABShowNeutered then
		frame.Show = function() end
		frame.ACABShowNeutered = true
	end
end

-- Shared clamp/rounding for every native-element Scale setter (SetBagBarScale,
-- SetMicroMenuScale, SetPetBarNativeScale, SetStanceBarScale, etc.) - rounds
-- to 0.1 and clamps to [0.5, 2.0]. Returns nil for a non-numeric input.
function ACAB:ClampScaleSetting(scale)
	scale = tonumber(scale)

	if not scale then
		return nil
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	return scale
end

-- Shared clamp/rounding for every native-element Spacing setter - rounds to
-- the nearest whole pixel. Each caller supplies its own min/max range.
-- Returns nil for a non-numeric input.
function ACAB:ClampSpacingSetting(spacing, minSpacing, maxSpacing)
	spacing = tonumber(spacing)

	if not spacing then
		return nil
	end

	spacing = math.floor(spacing + 0.5)

	if spacing < minSpacing then
		spacing = minSpacing
	end

	if spacing > maxSpacing then
		spacing = maxSpacing
	end

	return spacing
end

-------------------------------------------------------------------------
-- Snap to Adjacent Elements
--
-- Shared by every draggable element via DefaultBars.lua's
-- DefaultBarDrag_OnUpdate, called per-tick before the element is actually
-- moved so it can nudge the proposed position in place.
-------------------------------------------------------------------------

-- Converts a region's frame bounds to real screen pixels, optionally
-- expanded by a per-side visual inset (used for default bars 1-5, whose
-- native border overhangs the frame).
local function GetRealScreenBounds(region, insetLeft, insetRight, insetTop, insetBottom)
	if not region or not region.GetLeft then
		return nil
	end

	insetLeft = insetLeft or 0
	insetRight = insetRight or 0
	insetTop = insetTop or 0
	insetBottom = insetBottom or 0

	local left, right, top, bottom = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
	local scale = region:GetEffectiveScale()

	if not left or not right or not top or not bottom or not scale then
		return nil
	end

	return (left - insetLeft) * scale, (right + insetRight) * scale, (top + insetTop) * scale, (bottom - insetBottom) * scale
end

-- Calibrated border-texture overhang for a vanilla-style button of the
-- given size, beyond the button's own frame bounds. Used by both
-- GetElementVisualInset below and ACAB:GetLayoutGridSpacing.
local function ComputeVanillaBorderInsets(buttonSize, borderRatio, yOffset, fudge)
	local uniform = buttonSize * (borderRatio - 1) / 2

	local left = uniform - fudge
	local right = uniform - fudge
	local top = uniform - yOffset - fudge
	local bottom = uniform + yOffset - fudge

	if left < 0 then left = 0 end
	if right < 0 then right = 0 end
	if top < 0 then top = 0 end
	if bottom < 0 then bottom = 0 end

	return left, right, top, bottom
end

-- Returns how far (local units, pre-scale) a frame's visible border
-- overhangs its own frame bounds on each side, non-zero only for default
-- bars 1-5 in vanilla border style. Custom bars and every chain-anchored
-- element return 0.
function ACAB:GetElementVisualInset(frame)
	if frame and frame.config and frame.config.id and self:IsVanillaBorderStyle() then
		local buttonSize = frame.config.buttonSize or self.BUTTON_SIZE

		return ComputeVanillaBorderInsets(
			buttonSize,
			self.BORDER_RATIO,
			self.BORDER_Y_OFFSET or 0,
			self.BORDER_TEXTURE_FUDGE or 0
		)
	end

	return 0, 0, 0, 0
end

-- Every currently visible/enabled draggable element except `excludeElement`,
-- as real-screen-pixel bounding boxes.
function ACAB:GetAllSnapTargetBoxes(excludeElement)
	local boxes = {}

	local function AddBox(frame)
		if not frame or frame == excludeElement then
			return
		end

		if not frame.IsShown or not frame:IsShown() then
			return
		end

		local left, right, top, bottom = GetRealScreenBounds(frame, self:GetElementVisualInset(frame))

		if left then
			table.insert(boxes, { left = left, right = right, top = top, bottom = bottom })
		end
	end

	if self.bars then
		local barId

		for barId, bar in pairs(self.bars) do
			AddBox(bar)
		end
	end

	AddBox(self.bagBarContainer)
	AddBox(self.microMenuContainer)
	AddBox(self.stanceBarContainer)
	AddBox(self.pageIndicatorContainer)

	AddBox(getglobal(self.KEYRING_BUTTON_NAME))
	AddBox(getglobal(self.LATENCY_BAR_FRAME_NAME))
	AddBox(getglobal(self.EXP_BAR_FRAME_NAME))

	return boxes
end

-- Computes a snap-adjusted (proposedLeft, proposedTop) for a dragged
-- element's top-left corner, checking screen edges/corners (same-side
-- only) and every other visible element's edges (either side, to allow
-- edge-to-edge stacking). Each axis returns nil if it shouldn't snap.
function ACAB:ComputeSnapAdjustment(proposedLeft, proposedTop, width, height, excludeElement)
	local baseline = (ACABDB and ACABDB.snapToAdjacentElements) and true or false
	local shiftHeld = (IsShiftKeyDown and IsShiftKeyDown()) and true or false

	-- Shift inverts the baseline setting for this drag tick.
	if baseline == shiftHeld then
		return nil, nil
	end

	if not proposedLeft or not proposedTop or not width or not height then
		return nil, nil
	end

	local threshold = self.SNAP_THRESHOLD or 8

	local proposedRight = proposedLeft + width
	local proposedBottom = proposedTop - height

	local adjustedLeft, bestLeftDist
	local adjustedTop, bestTopDist

	local function ConsiderX(candidate, edge)
		local dist = candidate - edge

		if dist < 0 then
			dist = -dist
		end

		if dist <= threshold and (not bestLeftDist or dist < bestLeftDist) then
			adjustedLeft = proposedLeft + (candidate - edge)
			bestLeftDist = dist
		end
	end

	local function ConsiderY(candidate, edge)
		local dist = candidate - edge

		if dist < 0 then
			dist = -dist
		end

		if dist <= threshold and (not bestTopDist or dist < bestTopDist) then
			adjustedTop = proposedTop + (candidate - edge)
			bestTopDist = dist
		end
	end

	local screenLeft, screenRight, screenTop, screenBottom = GetRealScreenBounds(UIParent)

	if screenLeft then
		ConsiderX(screenLeft, proposedLeft)
		ConsiderX(screenRight, proposedRight)
		ConsiderY(screenTop, proposedTop)
		ConsiderY(screenBottom, proposedBottom)
	end

	local boxes = self:GetAllSnapTargetBoxes(excludeElement)
	local i

	for i = 1, table.getn(boxes) do
		local box = boxes[i]

		ConsiderX(box.left, proposedLeft)
		ConsiderX(box.right, proposedLeft)
		ConsiderX(box.left, proposedRight)
		ConsiderX(box.right, proposedRight)

		ConsiderY(box.top, proposedTop)
		ConsiderY(box.bottom, proposedTop)
		ConsiderY(box.top, proposedBottom)
		ConsiderY(box.bottom, proposedBottom)
	end

	return adjustedLeft, adjustedTop
end

-- Rounds `value` to the nearest multiple of `step`, half away from zero.
local function RoundToNearestMultiple(value, step)
	if not step or step == 0 then
		return value
	end

	local n = value / step

	if n >= 0 then
		n = math.floor(n + 0.5)
	else
		n = -math.floor(-n + 0.5)
	end

	return n * step
end

-- Picks whichever candidate anchor position (a list of real-screen-pixel
-- values, all meaning "proposed's own axis value if this candidate wins")
-- keeps `proposed` closest to where the cursor actually is.
local function BestSnapCandidate(proposed, candidates)
	local best, bestDist
	local i

	for i = 1, table.getn(candidates) do
		local dist = candidates[i] - proposed

		if dist < 0 then
			dist = -dist
		end

		if not bestDist or dist < bestDist then
			best = candidates[i]
			bestDist = dist
		end
	end

	return best
end

-- Grid-snaps a dragged element's top-left corner against the layout grid
-- (ACAB:GetLayoutGridSpacing(), same origin as the grid overlay), checking
-- near edge, far edge, and center per axis - whichever keeps the element
-- closest to the cursor wins. Screen edges are included as candidates too.
-- `scale` converts GetLayoutGridSpacing()'s local units to real screen pixels.
function ACAB:ComputeGridSnapAdjustment(proposedLeft, proposedTop, width, height, scale)
	local baseline = (ACABDB and ACABDB.snapToGrid) and true or false
	local altHeld = (IsAltKeyDown and IsAltKeyDown()) and true or false

	-- Alt inverts the baseline setting for this drag tick.
	if baseline == altHeld then
		return nil, nil
	end

	if not proposedLeft or not proposedTop or not width or not height then
		return nil, nil
	end

	local spacing = self:GetLayoutGridSpacing()

	if not spacing or spacing <= 0 then
		return nil, nil
	end

	spacing = spacing * (scale or 1)

	local screenLeft, screenRight, screenTop, screenBottom = GetRealScreenBounds(UIParent)

	if not screenLeft then
		return nil, nil
	end

	local centerX = (screenLeft + screenRight) / 2
	local centerY = (screenTop + screenBottom) / 2

	local function NearestOnAxis(point, origin)
		return origin + RoundToNearestMultiple(point - origin, spacing)
	end

	local adjustedLeft = BestSnapCandidate(proposedLeft, {
		NearestOnAxis(proposedLeft, centerX),
		NearestOnAxis(proposedLeft + width, centerX) - width,
		NearestOnAxis(proposedLeft + (width / 2), centerX) - (width / 2),
		screenLeft,
		screenRight - width,
	})

	local adjustedTop = BestSnapCandidate(proposedTop, {
		NearestOnAxis(proposedTop, centerY),
		NearestOnAxis(proposedTop - height, centerY) + height,
		NearestOnAxis(proposedTop - (height / 2), centerY) + (height / 2),
		screenTop,
		screenBottom + height,
	})

	return adjustedLeft, adjustedTop
end

-- Per-axis real-pixel capture radius for ComputeCenterGridSnapAdjustment.
local CENTER_GRID_SNAP_CAPTURE_PX_X = 10
local CENTER_GRID_SNAP_CAPTURE_PX_Y = 2

-- Snaps a point to its nearest grid line if within capturePx, else nil.
local function SnapPointWithinCapture(point, origin, spacing, capturePx)
	local offset = point - origin
	local nearestOffset = RoundToNearestMultiple(offset, spacing)
	local distance = offset - nearestOffset

	if distance < 0 then
		distance = -distance
	end

	if distance <= capturePx then
		return origin + nearestOffset
	end

	return nil
end

-- Appends `value` to `list` at index n+1 if non-nil, returns the new n.
local function AppendCandidate(list, n, value)
	if value then
		list[n + 1] = value
		return n + 1
	end

	return n
end

-- Snaps proposedLeft/proposedTop's near edge, far edge, or center - each
-- only within its own capture radius - to the nearest grid line per axis.
function ACAB:ComputeCenterGridSnapAdjustment(proposedLeft, proposedTop, width, height, scale)
	local baseline = (ACABDB and ACABDB.snapToGrid) and true or false
	local altHeld = (IsAltKeyDown and IsAltKeyDown()) and true or false

	-- Alt inverts the baseline setting for this drag tick.
	if baseline == altHeld then
		return nil, nil
	end

	if not proposedLeft or not proposedTop or not width or not height then
		return nil, nil
	end

	local spacing = self:GetLayoutGridSpacing()

	if not spacing or spacing <= 0 then
		return nil, nil
	end

	spacing = spacing * (scale or 1)

	local screenLeft, screenRight, screenTop, screenBottom = GetRealScreenBounds(UIParent)

	if not screenLeft then
		return nil, nil
	end

	local centerX = (screenLeft + screenRight) / 2
	local centerY = (screenTop + screenBottom) / 2

	local nearX = SnapPointWithinCapture(proposedLeft, centerX, spacing, CENTER_GRID_SNAP_CAPTURE_PX_X)
	local farX = SnapPointWithinCapture(proposedLeft + width, centerX, spacing, CENTER_GRID_SNAP_CAPTURE_PX_X)
	local midX = SnapPointWithinCapture(proposedLeft + (width / 2), centerX, spacing, CENTER_GRID_SNAP_CAPTURE_PX_X)

	local xCandidates = {}
	local xn = 0
	xn = AppendCandidate(xCandidates, xn, nearX)
	xn = AppendCandidate(xCandidates, xn, farX and (farX - width))
	xn = AppendCandidate(xCandidates, xn, midX and (midX - (width / 2)))

	local adjustedLeft

	if xn > 0 then
		adjustedLeft = BestSnapCandidate(proposedLeft, xCandidates)
	end

	local nearY = SnapPointWithinCapture(proposedTop, centerY, spacing, CENTER_GRID_SNAP_CAPTURE_PX_Y)
	local farY = SnapPointWithinCapture(proposedTop - height, centerY, spacing, CENTER_GRID_SNAP_CAPTURE_PX_Y)
	local midY = SnapPointWithinCapture(proposedTop - (height / 2), centerY, spacing, CENTER_GRID_SNAP_CAPTURE_PX_Y)

	local yCandidates = {}
	local yn = 0
	yn = AppendCandidate(yCandidates, yn, nearY)
	yn = AppendCandidate(yCandidates, yn, farY and (farY + height))
	yn = AppendCandidate(yCandidates, yn, midY and (midY + (height / 2)))

	local adjustedTop

	if yn > 0 then
		adjustedTop = BestSnapCandidate(proposedTop, yCandidates)
	end

	return adjustedLeft, adjustedTop
end

-------------------------------------------------------------------------
-- Global border/spacing style
-------------------------------------------------------------------------

-- Single source of truth for the global border/spacing style - Button.lua
-- and GetElementVisualInset above must both read this.
function ACAB:IsVanillaBorderStyle()
	if ACABDB and ACABDB.useDefaultLayout ~= false then
		return true
	end

	return not (ACABDB and ACABDB.modernBorderStyle)
end

-- Single source of truth for whether the Pet Bar is effectively in native
-- (real PetActionButton1-10) mode - forces native+uncondensed while
-- default layout is on, regardless of the user's stored preference.
function ACAB:IsPetBarNativeModeEffective()
	if ACABDB and ACABDB.useDefaultLayout ~= false then
		return true
	end

	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[self.PET_BAR_ID]

	return cfg and cfg.useNativePetBar == true
end

-- Single source of truth for whether the Stance Bar is effectively in
-- native (real ShapeshiftButton1-N) mode - forces native while default
-- layout is on, regardless of the user's stored preference. Mirrors
-- ACAB:IsPetBarNativeModeEffective exactly.
function ACAB:IsStanceBarNativeModeEffective()
	if ACABDB and ACABDB.useDefaultLayout ~= false then
		return true
	end

	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[self.STANCE_BAR_ID]

	return cfg and cfg.useNativeStanceBar == true
end

-- Re-syncs the Stance Bar (styled mode) cfg's buttonCount/cols/rows against
-- the live GetNumShapeshiftForms() count - called at login and on every
-- UPDATE_SHAPESHIFT_FORMS. Leaves a legitimate custom shape alone (matching
-- buttonCount AND cols*rows). Returns true if it changed something.
function ACAB:ApplyStanceBarLiveShape()
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.STANCE_BAR_ID]

	if not cfg then
		return false
	end

	local liveCount = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

	if liveCount > self.MAX_STANCE_BUTTONS then
		liveCount = self.MAX_STANCE_BUTTONS
	end

	local shapeValid = cfg.cols and cfg.rows and (cfg.cols * cfg.rows) == liveCount

	if cfg.buttonCount == liveCount and shapeValid then
		return false
	end

	cfg.buttonCount = liveCount
	-- Resets to a sensible default Nx1 shape - the old cols/rows may no
	-- longer be a valid factor pair of the new count at all.
	cfg.cols = liveCount > 0 and liveCount or 1
	cfg.rows = 1

	return true
end

-- Single source of truth for whether the Pet Bar should hide empty slots -
-- real vanilla never does, so this is forced false while default layout is
-- on regardless of the user's stored preference.
function ACAB:ShouldCondensePetBarSlots()
	if ACABDB and ACABDB.useDefaultLayout ~= false then
		return false
	end

	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[self.PET_BAR_ID]

	return cfg and cfg.condenseEmptyPetSlots == true
end

-- Live count of Pet Bar slots (1-10, identity-mapped pet slots - see
-- SeedOneDefaultBar) that currently have a pet ability/command assigned.
-- Used to size the condensed bar's actual on-screen footprint for the
-- Position sliders' clamp range (Settings.lua's GetActionBarCoordinateRange).
function ACAB:GetPetBarFilledSlotCount()
	if not GetPetActionInfo then
		return 0
	end

	local count = 0
	local i

	for i = 1, 10 do
		if GetPetActionInfo(i) ~= nil then
			count = count + 1
		end
	end

	return count
end

-- buttonSize a brand-new bar should seed at, already correct for the
-- currently active style.
function ACAB:GetCurrentButtonSizeBaseline()
	if self:IsVanillaBorderStyle() then
		return self.BUTTON_SIZE
	end

	return self.BUTTON_SIZE + self.MODERN_BUTTON_SIZE_DELTA
end

-- Layout-grid line spacing (Edit Layout mode).
-- ACABDB.useCustomGridSize overrides everything with a flat user value.
-- Otherwise tracks Main Bar's live buttonSize (+ spacing in vanilla style,
-- matching real button-to-button pitch). Modern style uses buttonSize alone -
-- do not add spacing there without re-confirming live, it already aligns.
function ACAB:GetLayoutGridSpacing()
	if ACABDB and ACABDB.useCustomGridSize and ACABDB.customGridSize then
		return ACABDB.customGridSize
	end

	local mainBar = self.bars and self.bars[1]
	local size = (mainBar and mainBar.config and mainBar.config.buttonSize)
		or self:GetCurrentButtonSizeBaseline()

	if not self:IsVanillaBorderStyle() then
		return size
	end

	local spacing = (mainBar and mainBar.config and mainBar.config.spacing)
		or self.VANILLA_SPACING_FLOOR

	return size + spacing
end

-------------------------------------------------------------------------
-- Edit mode ("Configure Layout")
-------------------------------------------------------------------------

-- Escape-only keyboard capture so edit mode can never trap a player with
-- no way out. EnableKeyboard(true) blocks all other keyboard input while
-- active (same tradeoff HoverBind.lua's capture frame makes) - kept in
-- sync with edit mode's own on/off state from Bar.lua's ApplyEditModeVisual,
-- not just SetEditMode, since that function is also called on its own from
-- bar-creation/login code paths.
ACAB.editModeCaptureFrame = CreateFrame("Frame", "ACABEditModeCaptureFrame", UIParent)
ACAB.editModeCaptureFrame:EnableKeyboard(false)
ACAB.editModeCaptureFrame:Hide()
ACAB.editModeCaptureFrame:SetScript("OnKeyDown", function()
	if arg1 == "ESCAPE" then
		ACAB:SetEditMode(false)
	end
end)

function ACAB:IsEditMode()
	return ACABDB and ACABDB.editMode == true
end

-- The Default profile can never be edited.
function ACAB:IsDefaultProfileActive()
	return not ACABCharDB or ACABCharDB.activeProfile == self.DEFAULT_PROFILE_NAME
end

-- Wraps a modifier-key name in the same color as the chat prefix.
local function ColorKeyName(key)
	return ACAB.CHAT_PREFIX_COLOR .. key .. "|r"
end

-- Printed from SetEditMode itself (not ToggleEditMode) so it fires
-- identically whether edit mode was left via /acab or via the Escape
-- capture frame above.
local function PrintEditModeState(enabled)
	if enabled then
		ACAB:Print("Configure Layout |cff20ff20ON|r \r")
		ACAB:Print(ColorKeyName("drag").." to move, " .. ColorKeyName("scroll") .. " to scale, " .. ColorKeyName("right-click") .. " to open settings for any Element")
		ACAB:Print("Hold " .. ColorKeyName("Shift") .. " while dragging to temporarily invert 'Snap to Adjacent Elements' Setting")
		ACAB:Print("Hold " .. ColorKeyName("Alt") .. " while dragging to temporarily invert 'Snap to Grid' Setting")
		ACAB:Print("Hold " .. ColorKeyName("Ctrl") .. " to temporarily show/hide the layout grid")
		ACAB:Print("Press " .. ColorKeyName("Escape") .. " to |cffff2020exit|r the Configure Layout mode")
	else
		ACAB:Print("Configure Layout |cffff2020OFF|r.")
	end
end

function ACAB:SetEditMode(enabled)
	self:EnsureDB()
	enabled = enabled and true or false

	if enabled and self:IsDefaultProfileActive() then
		self:Print("Edit Layout mode is disabled while the Default profile is active. Switch to another profile (Settings > Profiles) to edit your bar layout.")
		return
	end

	-- Edit mode always wins over hoverbind mode.
	if enabled and self:IsHoverBindMode() then
		self:SetHoverBindMode(false)
	end

	ACABDB.editMode = enabled
	self:ApplyEditModeVisual()

	if enabled then
		self:ForceHoverFadeFramesVisible()
	else
		self:RestoreHoverFadeFrames()
	end

	PrintEditModeState(enabled)
end

function ACAB:ToggleEditMode()
	self:SetEditMode(not self:IsEditMode())
end

-------------------------------------------------------------------------
-- Hoverbind mode
--
-- Mutually exclusive with edit mode.
-------------------------------------------------------------------------

function ACAB:IsHoverBindMode()
	return ACABDB and ACABDB.hoverBindMode == true
end

function ACAB:SetHoverBindMode(enabled)
	self:EnsureDB()
	enabled = enabled and true or false

	if enabled and self:IsEditMode() then
		self:Print("Cannot enable Hoverbind while Configure Layout is on.")
		return
	end

	ACABDB.hoverBindMode = enabled

	if self.ApplyHoverBindVisual then
		self:ApplyHoverBindVisual(enabled)
	end

	if enabled then
		self:ForceHoverFadeFramesVisible()
	else
		self:RestoreHoverFadeFrames()
	end
end

function ACAB:ToggleHoverBindMode()
	if not self:IsHoverBindMode() and self:IsEditMode() then
		self:Print("Cannot enable Hoverbind while Configure Layout is on.")
		return
	end

	self:SetHoverBindMode(not self:IsHoverBindMode())
	self:Print(self:IsHoverBindMode()
		and "Hoverbind |cff20ff20ON|r - hover a button and press a key to bind it. Red = unbound, green = bound."
		or "Hoverbind |cffff2020OFF|r.")
end

-------------------------------------------------------------------------
-- Only show on hover
--
-- Shared controller for every hover-only-eligible bar/element. Fade ticker
-- mirrors DefaultBars.lua's rested-glow-pulse idiom. Hover detection is a
-- shared cursor-position poll rather than OnEnter/OnLeave, since a bounding-
-- box test doesn't care which child frame wins mouse-enter dispatch.
-------------------------------------------------------------------------

local HOVER_FADE_TICK_INTERVAL = 0.04
local HOVER_POLL_TICK_INTERVAL = 0.06

-- Every frame with an installed hover-fade controller, keyed by itself.
local hoverFadeFrames = {}

-- Clamps to the 0-10s hover-fade duration range, or nil if not a valid number. Shared by every Set*HoverDuration setter.
function ACAB:ClampHoverDuration(duration)
	duration = tonumber(duration)

	if not duration then
		return nil
	end

	if duration < 0 then
		duration = 0
	end

	if duration > 10 then
		duration = 10
	end

	return duration
end

-- Mirrors DefaultBars.lua's file-local helper of the same name (not reachable from here).
local function GetCursorPositionUIScale()
	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / scale, y / scale
end

-- Bounds check against an already-known cursor position, shared across all registered frames per tick.
local function IsPointOverFrame(x, y, frame)
	local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()

	if not left or not right or not top or not bottom then
		return false
	end

	return x >= left and x <= right and y >= bottom and y <= top
end

-- One-off single-frame check, used only for ApplyHoverOnlyState's initial state.
local function IsCursorOverFrame(frame)
	local x, y = GetCursorPositionUIScale()

	return IsPointOverFrame(x, y, frame)
end

local hoverPollTicker = nil

-- Single shared ticker for every registered hover-only frame, started lazily on first registration.
local function StartHoverPollTicker()
	if hoverPollTicker or not C_Timer or not C_Timer.NewTicker then
		return
	end

	hoverPollTicker = C_Timer.NewTicker(HOVER_POLL_TICK_INTERVAL, function()
		if ACAB:IsEditMode() or ACAB:IsHoverBindMode() then
			return
		end

		local x, y = GetCursorPositionUIScale()
		local frame

		for frame in pairs(hoverFadeFrames) do
			if frame.ACABHoverOnlyEnabled then
				local hovering = IsPointOverFrame(x, y, frame)

				if hovering and not frame.ACABHoverOnlyHovering then
					ACAB:CancelHoverFadeTicker(frame)
					frame:SetAlpha(1)
				elseif not hovering and frame.ACABHoverOnlyHovering then
					ACAB:StartHoverFadeTicker(frame, frame.ACABHoverOnlyGetDuration and frame.ACABHoverOnlyGetDuration() or 3)
				end

				frame.ACABHoverOnlyHovering = hovering
			end
		end
	end)
end

-- Cancel()-and-nil, same convention used for tickers elsewhere in this codebase.
function ACAB:CancelHoverFadeTicker(frame)
	if frame.ACABHoverFadeTicker then
		frame.ACABHoverFadeTicker:Cancel()
		frame.ACABHoverFadeTicker = nil
	end
end

-- Full alpha for the first 4/5 of duration, then a linear fade to 0 over the last 1/5. duration <= 0 hides immediately.
-- Edit Layout/Hoverbind mode force alpha 1 while active, rechecked every tick.
function ACAB:StartHoverFadeTicker(frame, duration)
	self:CancelHoverFadeTicker(frame)

	duration = tonumber(duration) or 0

	if duration <= 0 or not C_Timer or not C_Timer.NewTicker then
		frame:SetAlpha(0)
		return
	end

	local holdEnd = duration * 0.8
	local startTime = GetTime()

	frame:SetAlpha(1)

	frame.ACABHoverFadeTicker = C_Timer.NewTicker(HOVER_FADE_TICK_INTERVAL, function()
		if ACAB:IsEditMode() or ACAB:IsHoverBindMode() then
			frame:SetAlpha(1)
			return
		end

		local elapsed = GetTime() - startTime

		if elapsed >= duration then
			frame:SetAlpha(0)
			ACAB:CancelHoverFadeTicker(frame)
			return
		end

		if elapsed <= holdEnd then
			frame:SetAlpha(1)
		else
			frame:SetAlpha(1 - ((elapsed - holdEnd) / (duration - holdEnd)))
		end
	end)
end

-- Registers `frame` (once, idempotent) into the shared poll registry, starting the poll ticker on first registration.
function ACAB:InstallHoverFadeController(frame)
	if frame.ACABHoverFadeInstalled then
		return
	end

	frame.ACABHoverFadeInstalled = true
	hoverFadeFrames[frame] = frame

	StartHoverPollTicker()
end

-- Central per-frame apply/toggle for every settings-change path that owns a hover-only-eligible frame.
function ACAB:ApplyHoverOnlyState(frame, enabled, getDuration)
	if not frame then
		return
	end

	enabled = enabled and true or false

	-- Stored on the frame so the poll ticker always reads the latest value.
	frame.ACABHoverOnlyEnabled = enabled
	frame.ACABHoverOnlyGetDuration = getDuration

	if not enabled then
		self:CancelHoverFadeTicker(frame)
		frame:SetAlpha(1)
		return
	end

	frame:EnableMouse(true)

	self:InstallHoverFadeController(frame)

	-- Immediate bounds check so toggling on while the cursor is already over the frame doesn't snap it to hidden.
	frame.ACABHoverOnlyHovering = IsCursorOverFrame(frame)

	if not frame.ACABHoverFadeTicker then
		if self:IsEditMode() or self:IsHoverBindMode() or frame.ACABHoverOnlyHovering then
			frame:SetAlpha(1)
		else
			frame:SetAlpha(0)
		end
	end
end

-- Forces every installed hover-fade frame to alpha 1, so hover-only elements stay visible while editing/binding.
function ACAB:ForceHoverFadeFramesVisible()
	local frame

	for frame in pairs(hoverFadeFrames) do
		frame:SetAlpha(1)
	end
end

-- Snaps every installed hover-fade frame back to its normal hidden-until-hover state, undoing ForceHoverFadeFramesVisible.
function ACAB:RestoreHoverFadeFrames()
	if self:IsEditMode() or self:IsHoverBindMode() then
		return
	end

	local frame

	for frame in pairs(hoverFadeFrames) do
		if frame.ACABHoverOnlyEnabled and not frame.ACABHoverFadeTicker and not frame.ACABHoverOnlyHovering then
			frame:SetAlpha(0)
		end
	end
end

-------------------------------------------------------------------------
-- Lock Action Bars
--
-- Not a CVar - backed by the plain global LOCK_ACTIONBAR ("0"/"1"),
-- same global Blizzard's own Interface Options checkbox uses.
-------------------------------------------------------------------------

function ACAB:IsLockActionBars()
	return LOCK_ACTIONBAR == "1"
end

function ACAB:SetLockActionBars(enabled)
	LOCK_ACTIONBAR = enabled and "1" or "0"
end

function ACAB:ToggleLockActionBars()
	self:SetLockActionBars(not self:IsLockActionBars())
	self:Print(self:IsLockActionBars()
		and "Action bars locked - dragging a filled button no longer picks up its action."
		or "Action bars unlocked.")
end

-------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------

-- Polls ActionButton1's position until two consecutive reads agree (or a
-- timeout), since its native position isn't guaranteed final immediately
-- after PLAYER_ENTERING_WORLD.
local SETTLE_POLL_INTERVAL = 0.1
local SETTLE_STABLE_READS_REQUIRED = 2
local SETTLE_TIMEOUT = 3

function ACAB:WaitForNativeBarSettle(callback)
	local ref = getglobal("ActionButton1")

	if not ref or not C_Timer or not C_Timer.NewTicker then
		callback(nil, nil, nil, nil, 0)
		return
	end

	local earlyLeft, earlyTop = ref:GetLeft(), ref:GetTop()
	local lastLeft, lastTop = earlyLeft, earlyTop
	local stableCount = 0
	local elapsed = 0

	local ticker
	ticker = C_Timer.NewTicker(SETTLE_POLL_INTERVAL, function()
		elapsed = elapsed + SETTLE_POLL_INTERVAL

		local left, top = ref:GetLeft(), ref:GetTop()

		if left and top and lastLeft and lastTop
			and left == lastLeft and top == lastTop then
			stableCount = stableCount + 1
		else
			stableCount = 0
		end

		lastLeft, lastTop = left, top

		local settled = stableCount >= SETTLE_STABLE_READS_REQUIRED
		local timedOut = elapsed >= SETTLE_TIMEOUT

		if settled or timedOut then
			ticker:Cancel()

			if timedOut and not settled then
				ACAB:Print(
					"WARNING: native action bar position did not settle within " ..
					tostring(SETTLE_TIMEOUT) .. "s - proceeding with its current, " ..
					"possibly not-yet-final position."
				)
			end

			callback(earlyLeft, earlyTop, lastLeft, lastTop, elapsed)
		end
	end)
end

-- Same stability-polling pattern as WaitForNativeBarSettle, but watches
-- frame.ACABSwallowedAnchor (set by DefaultBars.lua's InstallReanchorGuard,
-- only on Latency Bar/Cast Bar) instead of GetLeft()/GetTop(), since a
-- synchronous read at login can catch native code's anchor attempt before
-- it settles. callback receives the settled anchor, or nil if none observed.
local function WaitForWrappedFrameAnchorSettle(frame, callback)
	if not frame or not C_Timer or not C_Timer.NewTicker then
		callback(nil)
		return
	end

	local function SameAnchor(a, b)
		if not a or not b then
			return false
		end

		return a.point == b.point and a.relativeTo == b.relativeTo
			and a.relativePoint == b.relativePoint and a.x == b.x and a.y == b.y
	end

	local lastAnchor = frame.ACABSwallowedAnchor
	local stableCount = 0
	local elapsed = 0

	local ticker
	ticker = C_Timer.NewTicker(SETTLE_POLL_INTERVAL, function()
		elapsed = elapsed + SETTLE_POLL_INTERVAL

		local anchor = frame.ACABSwallowedAnchor

		if anchor and SameAnchor(anchor, lastAnchor) then
			stableCount = stableCount + 1
		else
			stableCount = 0
		end

		lastAnchor = anchor

		local settled = anchor and stableCount >= SETTLE_STABLE_READS_REQUIRED
		local timedOut = elapsed >= SETTLE_TIMEOUT

		if settled or timedOut then
			ticker:Cancel()
			callback(settled and lastAnchor or nil)
		end
	end)
end

-- Re-checks ActionButton1 once settled and silently recaptures if it
-- drifted from what was captured (RecaptureDefaultBarNativeAnchors).
local DRIFT_TOLERANCE = 1

-- Stricter than WaitForNativeBarSettle's own requirement - a full second of
-- stable reads before the drift check above runs.
local POST_LOGIN_SETTLE_STABLE_READS = 10
local POST_LOGIN_SETTLE_TIMEOUT = 10

-- Copies Bar 3's (or Bar 1's) current nativeAnchor.x into Pet Bar's cfg.x.
-- Reapplies live if the container already exists.
function ACAB:SyncPetBarAnchorX()
	local defaults = ACABDB and ACABDB.defaultBars
	local cfg = defaults and defaults[ACAB.PET_BAR_ID]

	if not cfg or ACABDB.useDefaultLayout == false then
		return
	end

	local bar3Anchor = defaults[3] and defaults[3].nativeAnchor
	local bar1Anchor = defaults[1] and defaults[1].nativeAnchor
	local anchor = bar3Anchor or bar1Anchor

	if not anchor then
		return
	end

	cfg.point = "TOPLEFT"
	cfg.relativePoint = "BOTTOMLEFT"
	cfg.x = anchor.x
	cfg.nativeAnchor = cfg.nativeAnchor or {}
	cfg.nativeAnchor.point = "TOPLEFT"
	cfg.nativeAnchor.relativePoint = "BOTTOMLEFT"
	cfg.nativeAnchor.x = anchor.x

	if ACAB.petBarNativeContainer then
		ACAB:ApplyPetBarNativePosition()
	end
end

local function SetupPetBarNativeContainer()
	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[ACAB.PET_BAR_ID]

	if not cfg or ACAB.petBarNativeContainer then
		return
	end

	ACAB:SyncPetBarAnchorX()
	ACAB:CreatePetBarNativeContainer()

	if ACABDB.useDefaultLayout ~= false then
		local bar3Cfg = ACABDB.defaultBars[3]
		ACAB:ReflowPetBarForBar3Toggle(bar3Cfg and bar3Cfg.enabled)
	end
end

local function VerifyDefaultBarAnchorsSettled()
	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[1]
	local liveAnchor = cfg and ACAB:CaptureNativeAnchor(1)

	if not cfg or not cfg.nativeAnchor or not liveAnchor then
		return
	end

	if math.abs(liveAnchor.x - cfg.nativeAnchor.x) > DRIFT_TOLERANCE
		or math.abs(liveAnchor.y - cfg.nativeAnchor.y) > DRIFT_TOLERANCE then
		ACAB:RecaptureDefaultBarNativeAnchors()
	end
end

local function WaitForPostLoginSettleThenVerify()
	local ref = getglobal("ActionButton1")

	if not ref or not C_Timer or not C_Timer.NewTicker then
		VerifyDefaultBarAnchorsSettled()
		return
	end

	local lastLeft, lastTop = ref:GetLeft(), ref:GetTop()
	local stableCount = 0
	local elapsed = 0

	local ticker
	ticker = C_Timer.NewTicker(SETTLE_POLL_INTERVAL, function()
		elapsed = elapsed + SETTLE_POLL_INTERVAL

		local left, top = ref:GetLeft(), ref:GetTop()

		if left and top and lastLeft and lastTop
			and left == lastLeft and top == lastTop then
			stableCount = stableCount + 1
		else
			stableCount = 0
		end

		lastLeft, lastTop = left, top

		if stableCount >= POST_LOGIN_SETTLE_STABLE_READS or elapsed >= POST_LOGIN_SETTLE_TIMEOUT then
			ticker:Cancel()
			VerifyDefaultBarAnchorsSettled()
		end
	end)
end

-- Full login sequence, run once WaitForNativeBarSettle confirms the
-- native bars have settled.
function ACAB:RunLoginSequence(earlyLeft, earlyTop, settledLeft, settledTop, waited)
	ACAB:ResolveActiveProfile()

	ACAB:EnsureDB()

	-- Must run before CreateFixedSlotDefaultBars/CreateBagBarAndMicroMenu -
	-- these frames are repositioned directly (not measured via a separate
	-- untouched reference frame like bars 1-5), so capturing after that
	-- reflow would measure an already-disturbed position. No-op on later logins.
	ACAB:CaptureKeyRingPositionIfNeeded()
	ACAB:CaptureLatencyBarPositionIfNeeded()
	ACAB:CaptureExpBarPositionIfNeeded()
	ACAB:CaptureCastBarPositionIfNeeded()

	-- Gives Latency Bar/Cast Bar's native anchor its best chance of being
	-- correct this login, instead of only correcting on the next manual
	-- recapture. Asynchronous - doesn't block the rest of login.
	do
		local function SyncNativeAnchorFromSwallow(frame, dbKey)
			WaitForWrappedFrameAnchorSettle(frame, function(anchor)
				if anchor then
					ACABDB[dbKey] = anchor
				end
			end)
		end

		SyncNativeAnchorFromSwallow(getglobal(ACAB.LATENCY_BAR_FRAME_NAME), "latencyBarNativeAnchor")
		SyncNativeAnchorFromSwallow(getglobal(ACAB.CAST_BAR_FRAME_NAME), "castBarNativeAnchor")
	end

	-- Must run before CreateFixedSlotDefaultBars builds the Stance Bar's
	-- button pool, so buttonCount reflects this session's live form count.
	ACAB:ApplyStanceBarLiveShape()

	ACAB:CreateAllBars()

	-- Must run before CreateFixedSlotDefaultBars, which hides bar 2's real
	-- buttons and would otherwise capture ShapeshiftBarFrame already-reflowed.
	ACAB:CaptureStanceBarNativeGap()

	ACAB:CreateFixedSlotDefaultBars()

	ACAB:ApplyAllDefaultBars()

	ACAB:ApplyGlobalButtonStyle()

	ACAB:ApplyGlobalSpacing()
	ACAB:ApplyGlobalButtonSize()

	ACAB:CreateStanceBarContainer()

	if ACABDB.useDefaultLayout ~= false then
		local bar2Cfg = ACABDB.defaultBars[2]
		ACAB:ReflowStanceBarForBar2Toggle(bar2Cfg and bar2Cfg.enabled)
	end

	ACAB:CreateBagBarAndMicroMenu()
	SetupPetBarNativeContainer()

	ACAB:CreatePageIndicatorContainer()

	ACAB:SetKeyRingEnabled(ACABDB.keyRingEnabled ~= false)

	ACAB:SetKeyRingScale(ACABDB.keyRingScale or 1)
	ACAB:ApplyKeyRingPosition()

	ACAB:SetLatencyBarEnabled(ACABDB.latencyBarEnabled ~= false)
	ACAB:SetLatencyBarScale(ACABDB.latencyBarScale or 1)
	ACAB:ApplyLatencyBarPosition()

	ACAB:SetExpBarEnabled(ACABDB.expBarEnabled ~= false)
	ACAB:SetExpBarScale(ACABDB.expBarScale or 1)
	ACAB:ApplyExpBarPosition()

	ACAB:SetCastBarScale(ACABDB.castBarScale or 1)
	ACAB:ApplyCastBarPosition()

	ACAB:SetTooltipEnabled(ACABDB.tooltipEnabled == true)
	ACAB:SetTooltipScale(ACABDB.tooltipScale or 1)
	ACAB:ApplyTooltipPosition()
	ACAB:HookGameTooltipDefaultAnchor()

	-- Extra Bar 1/2 and Pet Bar are all live by now (CreateAllBars/
	-- SetupPetBarNativeContainer above) - establishes this session's
	-- correct stacked Y immediately instead of waiting for the first
	-- relevant toggle.
	if ACABDB.useDefaultLayout ~= false then
		ACAB:ReflowCastBarForStackToggle()
	end

	ACAB:ApplyExpBarColors()

	ACAB:ApplyBetterExpBarVisual()

	ACAB:ApplyBlizzardArtVisibility()

	ACAB:CreateMinimapButton()

	ACAB:Print("Fully initialized! Click the minimap button or use /acab for options.")

	if ACAB.pendingFirstLoginDialog then
		ACAB.pendingFirstLoginDialog = nil
		ACAB:ShowFirstLoginDialog()
	end

	WaitForPostLoginSettleThenVerify()
end


-- Temporary diagnostic for the position/timing bugs found after the 1.0
-- rename (Main Bar style-switch drift, Micro Menu reset, initial-load
-- offsets, Pet Bar anchor, Extra Bar seed anchors). Run "/acab diag1 <label>"
-- at each repro step to dump saved position config + a few live frame
-- anchors, then diff the labeled dumps. Remove once findings are confirmed.
local function DiagPrint(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[ACABdiag]|r " .. msg)
end

local function DiagBarCfg(id, label)
	local cfg = ACABDB.defaultBars and ACABDB.defaultBars[id]

	if not cfg then
		DiagPrint(label .. ": no cfg")
		return
	end

	DiagPrint(string.format("%s pos=%s %s,%s size=%s spacing=%s enabled=%s",
		label, tostring(cfg.point), tostring(cfg.x), tostring(cfg.y),
		tostring(cfg.buttonSize), tostring(cfg.spacing), tostring(cfg.enabled)))

	local na = cfg.nativeAnchor

	if na then
		DiagPrint(string.format("%s nativeAnchor=%s %s,%s nativeSpacing=%s",
			label, tostring(na.point), tostring(na.x), tostring(na.y), tostring(cfg.nativeSpacing)))
	else
		DiagPrint(label .. " nativeAnchor=nil")
	end
end

-- ACABDB.bars is a plain array (custom bars 10+ live here too), not keyed
-- by id - scan for the entry whose .id field matches.
local function DiagExtraBar(id, label)
	local cfg = nil
	local i

	if ACABDB.bars then
		for i = 1, table.getn(ACABDB.bars) do
			if ACABDB.bars[i] and ACABDB.bars[i].id == id then
				cfg = ACABDB.bars[i]
				break
			end
		end
	end

	if not cfg then
		DiagPrint(label .. ": no cfg")
		return
	end

	DiagPrint(string.format("%s pos=%s rel=%s %s,%s size=%s spacing=%s enabled=%s",
		label, tostring(cfg.point), tostring(cfg.relativePoint), tostring(cfg.x), tostring(cfg.y),
		tostring(cfg.buttonSize), tostring(cfg.spacing), tostring(cfg.enabled)))
end

local function DiagElement(prefix, label)
	local pos = ACABDB[prefix .. "Position"]
	local na = ACABDB[prefix .. "NativeAnchor"]

	if pos then
		DiagPrint(string.format("%s pos=%s %s,%s", label, tostring(pos.point), tostring(pos.x), tostring(pos.y)))
	else
		DiagPrint(label .. " pos=nil")
	end

	if na then
		DiagPrint(string.format("%s nativeAnchor=%s %s,%s", label, tostring(na.point), tostring(na.x), tostring(na.y)))
	else
		DiagPrint(label .. " nativeAnchor=nil")
	end
end

local function DiagFrame(name, label)
	local frame = getglobal(name)

	if not frame then
		DiagPrint(label .. ": frame missing")
		return
	end

	local left = frame.GetLeft and frame:GetLeft()
	local bottom = frame.GetBottom and frame:GetBottom()
	local point, relTo, relPoint, x, y = frame:GetPoint()

	DiagPrint(string.format("%s live left=%s bottom=%s point=%s rel=%s relPoint=%s x=%s y=%s",
		label, tostring(left), tostring(bottom), tostring(point),
		relTo and relTo:GetName() or "nil", tostring(relPoint), tostring(x), tostring(y)))
end

local function RunDiag1(stage)
	ACAB:EnsureDB()

	DiagPrint("--- diag1 [" .. tostring(stage) .. "] ---")
	DiagPrint(string.format("useDefaultLayout=%s lastAppliedVanillaStyle=%s schemaVersion=%s",
		tostring(ACABDB.useDefaultLayout), tostring(ACABDB.lastAppliedVanillaStyle), tostring(ACABDB.schemaVersion)))

	local id

	for id = 1, 5 do
		DiagBarCfg(id, "bar" .. id)
	end

	DiagBarCfg(ACAB.PET_BAR_ID, "petBar")

	for id = ACAB.EXTRA_BAR_ID_START, ACAB.EXTRA_BAR_ID_START + ACAB.EXTRA_BAR_COUNT - 1 do
		DiagExtraBar(id, "extraBar" .. (id - ACAB.EXTRA_BAR_ID_START + 1))
	end

	local bar3 = ACABDB.defaultBars and ACABDB.defaultBars[3]
	local bar3Enabled = bar3 and bar3.enabled
	local baselineY = ACAB.GetPetBarBaselineY and ACAB:GetPetBarBaselineY(bar3Enabled)

	DiagPrint(string.format("bar3.enabled=%s GetPetBarBaselineY=%s", tostring(bar3Enabled), tostring(baselineY)))

	DiagElement("stanceBar", "stanceBar")
	DiagElement("bagBar", "bagBar")
	DiagElement("microMenu", "microMenu")
	DiagElement("keyRing", "keyRing")
	DiagElement("latencyBar", "latencyBar")
	DiagElement("castBar", "castBar")
	DiagElement("expBar", "expBar")
	DiagElement("mainBarPageIndicator", "pageIndicator")

	DiagFrame("ActionButton1", "ActionButton1")
	DiagFrame("PetActionButton1", "PetActionButton1")
	DiagFrame(ACAB.LATENCY_BAR_FRAME_NAME, "LatencyBarFrame")
	DiagFrame(ACAB.CAST_BAR_FRAME_NAME, "CastBarFrame")
	DiagFrame(ACAB.KEYRING_BUTTON_NAME, "KeyRingButton")

	DiagPrint("--- end diag1 ---")
end

-- /acab settings <pagename> - name -> settings page resolution table.
-- Mirrors the pages reachable by right-clicking a bar/element in edit mode
-- (SettingsBars.lua's OpenBarSettingsByKey/OpenDefaultBarSettings).
local SETTINGS_PAGE_ALIASES = {
	general = { view = "general" },
	profiles = { view = "profiles" },
	editmode = { view = "editmode" },
	bars = { view = "bars" },

	main = { page = 1 },
	mainbar = { page = 1 },
	["1"] = { page = 1 },
	["2"] = { page = 2 },
	["3"] = { page = 3 },
	["4"] = { page = 4 },
	["5"] = { page = 5 },
	["6"] = { page = ACAB.EXTRA_BAR_ID_START },
	["7"] = { page = ACAB.EXTRA_BAR_ID_START + 1 },
	["8"] = { page = ACAB.EXTRA_BAR_ID_START + 2 },
	["9"] = { page = ACAB.EXTRA_BAR_ID_START + 3 },
	extra1 = { page = ACAB.EXTRA_BAR_ID_START },
	extra2 = { page = ACAB.EXTRA_BAR_ID_START + 1 },
	extra3 = { page = ACAB.EXTRA_BAR_ID_START + 2 },
	extra4 = { page = ACAB.EXTRA_BAR_ID_START + 3 },
	pet = { page = ACAB.PET_BAR_ID },
	petbar = { page = ACAB.PET_BAR_ID },
	stance = { page = ACAB.STANCE_BAR_ID },
	stancebar = { page = ACAB.STANCE_BAR_ID },

	bags = { page = "bagbar" },
	bagbar = { page = "bagbar" },
	keyring = { page = "bagbar" },
	micro = { page = "micromenu" },
	micromenu = { page = "micromenu" },
	latency = { page = "latencybar" },
	latencybar = { page = "latencybar" },
	xp = { page = "expbar" },
	exp = { page = "expbar" },
	expbar = { page = "expbar" },
	experience = { page = "expbar" },
	cast = { page = "castbar" },
	castbar = { page = "castbar" },
	tooltip = { page = "tooltip" },
}

-- Opens the settings window to a specific page by name (/acab settings
-- <pagename>) - same destination right-clicking that bar/element opens.
function ACAB:OpenSettingsPageByName(name)
	local target = SETTINGS_PAGE_ALIASES[string.lower(name or "")]

	if not target then
		self:Print("Unknown settings page \"" .. tostring(name) .. "\". Type " .. ColorKeyName("/acab help") .. " for a list.")
		return
	end

	self:ShowSettingsFrame()

	if target.view == "general" then
		self:ShowGeneralView()
	elseif target.view == "profiles" then
		self:ShowProfilesView()
	elseif target.view == "editmode" then
		self:ShowEditModeView()
	elseif target.view == "bars" then
		self:ShowBarsView()
	elseif target.page then
		self:ShowBarPage(target.page)
	end
end

-- /acab profile <...> - profile management from chat, mirroring the
-- Profiles settings tab's add/delete/copy dialogs (SettingsGeneral.lua).
local function PrintProfileStatus()
	ACAB:Print("Current profile: \"" .. tostring(ACABCharDB and ACABCharDB.activeProfile or ACAB.DEFAULT_PROFILE_NAME) .. "\"")
	ACAB:Print("Available " .. ColorKeyName("/acab profile") .. " parameters:")
	ACAB:Print(ColorKeyName("/acab profile list") .. " - list all profiles in chat")
	ACAB:Print(ColorKeyName("/acab profile select <name>") .. " - switch to another profile")
	ACAB:Print(ColorKeyName("/acab profile add <name>") .. " - create a new profile")
	ACAB:Print(ColorKeyName("/acab profile delete <name>") .. " - delete a profile")
	ACAB:Print(ColorKeyName("/acab profile copy [name]") .. " - copy settings into the current profile from [name], or pick from a dropdown if omitted")
	ACAB:Print(ColorKeyName("/acab profile export") .. " - show the current profile's export string")
	ACAB:Print(ColorKeyName("/acab profile import") .. " - paste an export string into the current profile")
end

local function PrintProfileList()
	local names = ACAB:GetProfileNames()
	local active = ACABCharDB and ACABCharDB.activeProfile or ACAB.DEFAULT_PROFILE_NAME
	local i

	ACAB:Print("Profiles:")

	for i = 1, table.getn(names) do
		local marker = (names[i] == active) and " |cff20ff20(active)|r" or ""
		ACAB:Print("  " .. names[i] .. marker)
	end
end

function ACAB:HandleProfileCommand(rest)
	local subcommand, arg = string.match(rest or "", "^(%S*)%s*(.-)$")

	subcommand = string.lower(subcommand or "")

	if subcommand == "" then
		PrintProfileStatus()
	elseif subcommand == "list" then
		PrintProfileList()
	elseif subcommand == "select" then
		if arg == "" then
			self:Print("Usage: /acab profile select <name>")
			return
		end

		local ok, reason = self:SwitchProfile(arg)

		if not ok and reason then
			self:Print(reason)
		end
	elseif subcommand == "add" then
		if arg == "" then
			self:Print("Usage: /acab profile add <name>")
			return
		end

		local ok, reason = self:CreateProfile(arg)

		if ok then
			self:SwitchProfile(arg)
		elseif reason then
			self:Print(reason)
		end
	elseif subcommand == "delete" then
		if arg == "" then
			self:Print("Usage: /acab profile delete <name>")
			return
		end

		if arg == self.DEFAULT_PROFILE_NAME then
			self:Print("The Default profile cannot be deleted.")
			return
		end

		if not ACABProfilesDB or not ACABProfilesDB[arg] then
			self:Print("Profile \"" .. arg .. "\" does not exist.")
			return
		end

		local targetName = arg
		local wasActive = (ACABCharDB and ACABCharDB.activeProfile == targetName)

		self:ShowDialog({
			title = "Delete Profile",
			message = "ATTENTION: This action will delete all settings present " ..
				"on profile \"" .. targetName .. "\" and is not reversible.",
			mode = "confirm",
			buttons = {
				{
					text = "Accept",
					onClick = function()
						ACAB:DeleteProfile(targetName)

						if wasActive then
							ReloadUI()
						elseif ACAB.settingsFrame and ACAB.settingsFrame.profilesPanel then
							ACAB:RefreshProfilesPanel()
						end
					end,
				},
				{ text = "Cancel", onClick = function() end },
			},
		})
	elseif subcommand == "copy" then
		local targetName = (ACABCharDB and ACABCharDB.activeProfile) or self.DEFAULT_PROFILE_NAME

		if arg == "" then
			-- No name given - same dropdown-picker dialog as the Profiles
			-- tab's "Copy from other profile" button.
			local otherProfiles = {}
			local names = self:GetProfileNames()
			local i

			for i = 1, table.getn(names) do
				if names[i] ~= targetName then
					table.insert(otherProfiles, names[i])
				end
			end

			self:ShowDialog({
				title = "Copy From Other Profile",
				message = "Choose another profile to copy all settings from. ATTENTION: " ..
					"This action will override all settings present on the current " ..
					"profile and is not reversible.",
				mode = "dropdown",
				options = otherProfiles,
				buttons = {
					{
						text = "Accept",
						isDefault = false,
						onClick = function(value)
							if value then
								ACAB:CopyProfileInto(value, targetName)
								ReloadUI()
							end
						end,
					},
					{ text = "Cancel", onClick = function() end },
				},
			})
			return
		end

		if not ACABProfilesDB or not ACABProfilesDB[arg] then
			self:Print("Profile \"" .. arg .. "\" does not exist.")
			return
		end

		local sourceName = arg

		if sourceName == targetName then
			self:Print("Cannot copy a profile into itself.")
			return
		end

		self:ShowDialog({
			title = "Copy From Other Profile",
			message = "Choose another profile to copy all settings from. ATTENTION: " ..
				"This action will override all settings present on the current " ..
				"profile and is not reversible.",
			mode = "confirm",
			buttons = {
				{
					text = "Accept",
					onClick = function()
						ACAB:CopyProfileInto(sourceName, targetName)
						ReloadUI()
					end,
				},
				{ text = "Cancel", onClick = function() end },
			},
		})
	elseif subcommand == "export" then
		self:ShowDialog({
			title = "Export Profile",
			message = "Copy the text below (Ctrl+C) to share this profile.",
			mode = "textarea",
			defaultText = self:ExportActiveProfileString(),
			buttons = {
				{
					text = "Select all",
					isDefault = true,
					keepOpen = true,
					onClick = function()
						ACAB.activeDialog.textArea.editBox:SetFocus()
						ACAB.activeDialog.textArea.editBox:HighlightText()
					end,
				},
				{ text = "Close", onClick = function() end },
			},
		})
	elseif subcommand == "import" then
		local function ValidateImportText(value)
			return ACAB:ParseProfileImportString(value)
		end

		self:ShowDialog({
			title = "Import Profile",
			message = "You are about to Import a Profile on to your currently " ..
				"active Profile " .. tostring(ACABCharDB and ACABCharDB.activeProfile),
			warningText = "WARNING! This will override all data on your " ..
				"current Profile with the imported Data",
			mode = "textarea",
			reserveErrorBanner = true,
			liveValidate = ValidateImportText,
			buttons = {
				{
					text = "Import",
					isDefault = true,
					validate = ValidateImportText,
					onClick = function(value)
						local ok, data = ACAB:ParseProfileImportString(value)

						if ok then
							ACAB:ApplyImportedProfileData(data)
							ReloadUI()
						end
					end,
				},
				{ text = "Close", onClick = function() end },
			},
		})
	else
		self:Print("Unknown profile command \"" .. subcommand .. "\". Type " .. ColorKeyName("/acab profile") .. " for a list.")
	end
end

local function PrintCommandHelp()
	ACAB:Print("Available " .. ColorKeyName("/acab") .. " commands:")
	ACAB:Print(ColorKeyName("/acab") .. " - toggle the Settings window")
	ACAB:Print(ColorKeyName("/acab menu") .. " - open the minimap right-click menu")
	ACAB:Print(ColorKeyName("/acab edit") .. " - toggle Configure Layout mode")
	ACAB:Print(ColorKeyName("/acab bind") .. " - toggle Hoverbind keybind mode")
	ACAB:Print(ColorKeyName("/acab settings <page>") .. " - jump straight to a settings page")
	ACAB:Print("  pages: general, bars, profiles, editmode, main, 1-9/extra1-4, pet, stance, bags, keyring, micro, latency, exp, cast, tooltip")
	ACAB:Print(ColorKeyName("/acab profile") .. " - show current profile and profile commands")
	ACAB:Print(ColorKeyName("/acab recapture") .. " - force a fresh capture of default bar native anchors")
	ACAB:Print(ColorKeyName("/acab help") .. " - show this list")
end

-- /acab alone toggles the Settings window; see PrintCommandHelp above for
-- the full command list.
SLASH_ACAB1 = "/acab"
SlashCmdList["ACAB"] = function(msg)
	msg = msg or ""

	local command, rest = string.match(msg, "^(%S*)%s*(.-)$")
	command = string.lower(command or "")

	if command == "" then
		ACAB:ToggleSettingsFrame()
	elseif command == "menu" then
		ACAB:ToggleMainMenu()
	elseif command == "edit" then
		ACAB:ToggleEditMode()
	elseif command == "bind" then
		ACAB:ToggleHoverBindMode()
	elseif command == "settings" then
		if rest == "" then
			ACAB:ShowSettingsFrame()
		else
			ACAB:OpenSettingsPageByName(rest)
		end
	elseif command == "profile" then
		ACAB:HandleProfileCommand(rest)
	elseif command == "recapture" then
		ACAB:RecaptureDefaultBarNativeAnchors()
		ACAB:RecaptureWrappedNativeFrameAnchors()
	elseif command == "help" then
		PrintCommandHelp()
	elseif string.find(msg, "^diag1") then
		RunDiag1(string.gsub(msg, "^diag1%s*", ""))
	else
		ACAB:Print("Unknown command \"" .. msg .. "\". Type " .. ColorKeyName("/acab help") .. " for a list.")
	end
end
