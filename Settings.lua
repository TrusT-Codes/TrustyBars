-- Settings.lua
-- BTVanilla unified settings window: default bars (1-5, DefaultBars.lua),
-- Extra Bars (6-9, Bar.lua), and the native-frame "simple" pages (Stance
-- Bar / Bag Bar / Micro Menu / Latency Bar / Experience Bar,
-- DefaultBars.lua) all share one bar list, one "Bars" view, plus a second
-- "General" view for addon-wide settings.
--
-- Every control is live: moving a slider, clicking a grid preset, or
-- toggling a checkbox writes straight into BTVanillaDB and re-applies the
-- affected bar's shape/position/size on the spot. There is no "pending"
-- value or Apply button anywhere in this file.
--
-- Per-bar editable settings (default bars 1-5 and Extra Bars 6-9):
--   x / y             live sliders
--   buttonSize        live slider
--   spacing           live slider
--   cols / rows       live grid-preset swatches
--   buttonCount       Extra Bars only, live +/- stepper
--   enabled           default bars 2-5 and Extra Bars 6-9 only, live checkbox
--
-- point / relativePoint are intentionally NOT exposed in the UI. Their
-- existing SavedVariable values remain unchanged.
--
-- slotStart is intentionally NOT exposed either - custom-bar slot
-- assignment is fully internal, computed once at creation by Bar.lua's
-- GetNextFreeSlotStart.
--
-- Grid shape is chosen from exactly 6 literal presets (not free-form
-- rows/cols sliders):
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
--
-- The "simple" bar pages (Stance Bar / Bag Bar / Micro Menu / Latency Bar
-- / Experience Bar) are a separate, narrower page builder further down
-- this file (CreateSimpleBarPage) - Position + optional Enable/Spacing/
-- Scale/Orientation + Reset only, since none of them is a TrustyBars-owned
-- button grid. The General tab (GetOrCreateGeneralPanel) holds addon-wide
-- toggles that aren't specific to any one bar.

local BTV = BTVanilla

local settingsFrame

-------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------

-- The 6 fixed grid presets, in display order. Every preset totals
-- exactly BTV.MAX_BAR_BUTTONS (12) cells, matching the fixed-size button
-- pool every bar (default or custom) is built around.
local GRID_PRESETS = {
	{ rows = 1,  cols = 12 },
	{ rows = 2,  cols = 6  },
	{ rows = 3,  cols = 4  },
	{ rows = 4,  cols = 3  },
	{ rows = 6,  cols = 2  },
	{ rows = 12, cols = 1  },
}

local BUTTON_SIZE_MIN = 16
local BUTTON_SIZE_MAX = 64
local BUTTON_SIZE_STEP = 2

-- General tab's hotkey/count text font size sliders (Button.lua's
-- self.hotkey/self.count FontStrings). 6-24 comfortably brackets vanilla's
-- own NumberFontNormalSmall/NumberFontNormal template sizes on this
-- client generation - flagged in the task report as worth a live check,
-- since the true native size is only knowable by GetFont()'ing a real
-- FontString (Button.lua's captured BTV.NATIVE_HOTKEY_FONT/NATIVE_COUNT_FONT),
-- not at this constant's definition time.
local FONT_SIZE_MIN = 6
local FONT_SIZE_MAX = 24
local FONT_SIZE_STEP = 1

-- Clamps a saved/native font size into the sliders' fixed [MIN, MAX]
-- display range - a saved value from a build with a different range (or a
-- captured native size that happens to sit outside 6-24 on some other
-- client build) still needs a sane slider position rather than an error.
--
-- Fix 2 (bug-fix batch): also ROUNDS via math.floor(value + 0.5) - a
-- captured native default (GetFont() off a real FontString/Font object,
-- see Button.lua's hasCapturedFontDefaults block and DefaultBars.lua's
-- BTV:CaptureNativeExpBarFontIfNeeded) can itself come back with float
-- imprecision (e.g. 11.999999726451 instead of 12) on this client - this
-- is the single place every display path (RefreshGeneralPanel, both
-- General-tab Reset buttons, RefreshSimpleBarPage's Experience Bar Font
-- Size slider - round 22 item 2) funnels a size through before it ever
-- reaches a value-label FontString.
--
-- Declared here, immediately after FONT_SIZE_MIN/MAX/STEP (moved up from
-- its original position further down the file, round 22): Lua 5.0
-- resolves locals lexically at parse time, so a closure/function body can
-- only capture a local already declared earlier in the file, never one
-- declared later even if it runs afterward - and this now needs to be
-- visible to BTV:RefreshSimpleBarPage (declared well before the General
-- panel's own builder), not just GetOrCreateGeneralPanel's Reset button
-- closures.
local function ClampFontSize(size)
	if not size then
		return FONT_SIZE_MIN
	end

	size = math.floor(size + 0.5)

	if size < FONT_SIZE_MIN then
		return FONT_SIZE_MIN
	end

	if size > FONT_SIZE_MAX then
		return FONT_SIZE_MAX
	end

	return size
end

-- Shared by both bar kinds' Spacing slider (bug-fix batch Fix 4 added it
-- to true custom bars 6+ too, alongside default bars 1-5's existing one -
-- see the spacing slider block below).
local SPACING_MIN = 0
local SPACING_MAX = 20
local SPACING_STEP = 1

-- Real-to-displayed spacing offset for the PER-BAR default/custom bar
-- (1-9) spacing slider - NOT the simple-bar (Bag Bar/Micro Menu/etc.)
-- slider, and NOT the global-spacing slider's own displayed number
-- (that one shows BTVanillaDB.globalSpacingValue raw, un-offset - see
-- Bar.lua's ApplyGlobalSpacing). Vanilla-only, matching the real minimum
-- spacing clamp (Bar.lua's SetBarSpacing) exactly - the displayed number
-- stays constant across a style switch not because this offset is
-- frozen, but because BTV:ApplyGlobalButtonStyle (Bar.lua) actively
-- converts the REAL spacing value by the same amount in the opposite
-- direction of the buttonSize delta on every transition, so
-- real - offset always nets out to the same displayed number. Real
-- values are only ever written at the OnValueChanged/refresh boundary -
-- the slider's own on-screen value is always in DISPLAYED space.
local function GetSpacingDisplayOffset()
	return BTV:IsVanillaBorderStyle() and BTV.VANILLA_SPACING_FLOOR or 0
end

-- Friendly names for the 5 fixed default bars (1-5) now live on
-- BTV.DEFAULT_BAR_NAMES (Core.lua, round 36) - promoted out of this file
-- so Bar.lua's EnsureBarOverlay edit-mode label (which loads before this
-- file) can share the exact same table instead of a second, independently-
-- maintained copy. GetBarDisplayName below delegates to BTV:GetBarDisplayName
-- for the default-bar/Extra-Bar case.

-- Friendly names for the Stance Bar / Bag Bar / Micro Menu (features 2/3)
-- - these use distinct STRING keys ("stance"/"bagbar"/"micromenu"),
-- never numeric ids, so they can never collide with the numeric
-- default-bar (1-5)/custom-bar (6+) id scheme above. Declared here (used
-- by GetBarDisplayName, CreateBarListRow, and the simple-bar-page system
-- further below) rather than duplicated per call site.
local SIMPLE_BAR_NAMES = {
	stance = "Stance Bar",
	bagbar = "Bag Bar",
	micromenu = "Micro Menu",
	latencybar = "Latency Bar",
	expbar = "Experience Bar",
}

-- Populated near the bottom of this file (CreateSimpleBarPage's own
-- section) once BTV:SetStanceBarPosition/SetBagBarPosition/etc. (all
-- DefaultBars.lua) are known to exist - declared here (a real Lua 5.0
-- upvalue, not a global) so CreateBarListRow/GetOrCreateBarPage/
-- RefreshBarSettingsPage below can all reference the same table via
-- simpleBarPageConfigs[barId] as their "is this a simple string-keyed
-- page?" test, regardless of definition order elsewhere in the file.
local simpleBarPageConfigs = {}

-- Extra Bars start at id 6 (ids 1-5 are reserved for the default bars;
-- BTV.EXTRA_BAR_ID_START/EXTRA_BAR_COUNT, Core.lua, fix ids 6-9
-- permanently), but are numbered from 1 for the user rather than showing
-- the internal id.
local function GetBarDisplayName(barId, isDefault)
	if SIMPLE_BAR_NAMES[barId] then
		return SIMPLE_BAR_NAMES[barId]
	end

	-- isDefault is unused here now (round 36) - every call site already
	-- computes it as exactly `barId >= 1 and barId <= 5` (IsDefaultBarId),
	-- the same numeric range BTV:GetBarDisplayName itself checks, so
	-- delegating unconditionally produces an identical result.
	return BTV:GetBarDisplayName(barId)
end

-- Layout indent constants, used instead of scattering magic numbers
-- through every page-building call below.
local INDENT_SECTION = 18
local INDENT_CONTROL = 22
local INDENT_INPUT   = 85

local LIST_ROW_HEIGHT = 24
local LIST_ROW_GAP    = 4

-- Matches f.listPanel's own backdrop (SetWidth 140, SetBackdrop insets 2px
-- each side, CreateSettingsFrame) - every row's fade-strip highlight
-- (BTVListRowMixin:SetVisualWidth) spans this SAME fixed width/offset
-- regardless of whether that particular row has an inline checkbox, so the
-- highlighted area always fills the boxed list panel's own inner content
-- rectangle edge-to-edge and reads as symmetrical, instead of stopping at
-- wherever each row's own clickable width (110, or 132 with a checkbox)
-- happens to end.
local LIST_ITEM_VISUAL_OFFSET = 2
local LIST_ITEM_VISUAL_WIDTH = 140 - (LIST_ITEM_VISUAL_OFFSET * 2)

-- Defers `fn` to the next frame via C_Timer.After(0, ...) - DLL-native,
-- confirmed real (docs/01-Environment-Capability-Analysis.md), never a
-- hand-rolled OnUpdate poll. Falls back to calling fn immediately if
-- C_Timer somehow isn't available, same defensive tolerance this
-- codebase already uses everywhere else it touches C_Timer.
--
-- Used specifically to wrap every Fit*View call below: a panel just
-- Show()'n/populated this same tick can have candidates whose
-- GetBottom() hasn't resolved to real values yet - live-tested, this
-- produced a completely wrong (either far too small or far too tall)
-- viewport on EVERY switch to General/Profiles, self-correcting only on
-- a second, separate visit (i.e. once the engine had an actual render
-- frame to settle the newly-shown layout in before anything measured
-- it). Waiting one frame before measuring fixes this at the source
-- instead of guessing at which specific read was stale.
local function DeferFit(fn)
	if C_Timer and C_Timer.After then
		C_Timer.After(0, fn)
	else
		fn()
	end
end

-- Width reserved for each content viewport's scrollbar
-- (UIPanelScrollFrameTemplate anchors it just outside the scrollframe's
-- own right edge) - reserved unconditionally, whether or not the current
-- view's content actually needs to scroll, so nothing has to reflow when
-- it toggles. Shared by CreateSettingsFrame and
-- BTV:CreateWideContentScrollFrame (both below).
local SETTINGS_SCROLLBAR_RESERVED_WIDTH = 28

-- Fixed vertical band reserved for the Default-profile-lock warning
-- banner (CreateProfileLockWarning below), anchored right under each
-- page's title and right above its first content control. Reserved
-- unconditionally (whether or not the banner is currently shown) so
-- nothing needs to reflow when it toggles.
local PROFILE_LOCK_BANNER_TOP = -34

-- Generous reserve for the LONGER of the two possible lock messages
-- (BTV:CreateProfileLockWarning) wrapped at the narrowest page width this
-- banner ever appears at - the banner's own real height is still
-- recomputed dynamically from its actual wrapped text
-- (BTV:ApplyProfileLockGating), so this is a safety margin against
-- overlapping the control below it, not a hard cap.
local PROFILE_LOCK_BANNER_HEIGHT = 56

local SWATCH_SIZE = 46
local SWATCH_GAP  = 8
local SWATCH_PAD  = 4

-------------------------------------------------------------------------
-- Basic helpers
-------------------------------------------------------------------------

local function SettingsFrame_OnDragStart()
	this:StartMoving()
end

local function SettingsFrame_OnDragStop()
	this:StopMovingOrSizing()
end

local function IsDefaultBarId(barId)
	return barId ~= nil and barId >= 1 and barId <= 5
end

-- Finds an Extra Bar's SavedVariables entry by ID (never by array index -
-- BTVanillaDB.bars is still a plain array under the hood, even though ids
-- 6-9 are now permanent/fixed - see Core.lua's EnsureExtraBars).
local function FindCustomBarConfig(barId)
	local i

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg and cfg.id == barId then
			return cfg
		end
	end

	return nil
end

-- Returns cfg, isDefault for any bar id (1-5 default, 6+ custom).
local function GetBarConfig(barId)
	if IsDefaultBarId(barId) then
		return BTVanillaDB.defaultBars[barId], true
	end

	return FindCustomBarConfig(barId), false
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

	slider:SetWidth(width or 300)
	slider:SetHeight(17)

	slider:SetOrientation("HORIZONTAL")

	return slider
end

local function SetSliderLabel(slider, text)
	if slider.Text then
		slider.Text:SetText(text)
	end
end

-------------------------------------------------------------------------
-- Screen coordinate ranges
--
-- Computed once per page build (point 5), never per-tick - the caption
-- showing "Position (X: -1024 to 1024)" is a static FontString set at
-- build time, not recalculated on every OnValueChanged.
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
-- Grid preset swatches
--
-- Small preview frames built from WHITE8X8-textured squares, matching
-- the texture idiom already used by Button.lua's editOverlay. Clicking
-- a swatch is a single deliberate action, so it applies immediately -
-- no Apply-button gating (point 2).
-------------------------------------------------------------------------

local function CreateGridSwatch(parent, preset)
	local swatch = CreateFrame(
		"Button",
		nil,
		parent
	)

	swatch:SetWidth(SWATCH_SIZE)
	swatch:SetHeight(SWATCH_SIZE)

	swatch:SetBackdrop({
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

	swatch:SetBackdropColor(0, 0, 0, 0.35)
	swatch:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	swatch.rows = preset.rows
	swatch.cols = preset.cols

	-- Build the tiny cell grid once, scaled to fit inside the swatch.
	local maxDim = preset.rows

	if preset.cols > maxDim then
		maxDim = preset.cols
	end

	local avail = SWATCH_SIZE - (SWATCH_PAD * 2)
	local cellSize = math.floor(avail / maxDim)

	if cellSize < 1 then
		cellSize = 1
	end

	local r
	local c

	for r = 0, preset.rows - 1 do
		for c = 0, preset.cols - 1 do
			local tex = swatch:CreateTexture(nil, "ARTWORK")

			tex:SetTexture("Interface\\Buttons\\WHITE8X8")
			tex:SetVertexColor(0.8, 0.8, 0.8, 0.9)

			tex:SetWidth(cellSize - 1)
			tex:SetHeight(cellSize - 1)

			tex:SetPoint(
				"TOPLEFT",
				swatch,
				"TOPLEFT",
				SWATCH_PAD + (c * cellSize),
				-(SWATCH_PAD + (r * cellSize))
			)
		end
	end

	local caption = swatch:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	caption:SetPoint(
		"TOP",
		swatch,
		"BOTTOM",
		0,
		-2
	)

	caption:SetText(
		tostring(preset.cols) .. "x" .. tostring(preset.rows)
	)

	swatch.caption = caption

	return swatch
end

local function GridSwatch_OnClick()
	local page = this.page

	if not page then
		return
	end

	local barId = page.barId

	if page.isDefault then
		-- BTV:SetDefaultBarLayout (DefaultBars.lua) owns the bar-1-vs-
		-- bars-2-5 branch internally now (major architecture migration,
		-- Phase 1 of 2) - bars 2-5 delegate straight to Bar.lua's own
		-- SetBarLayout, exactly like a real custom bar (id 6+) below.
		BTV:SetDefaultBarLayout(barId, this.cols, this.rows)
	else
		local bar = BTV.bars[barId]

		if bar then
			BTV:SetBarLayout(bar, this.cols, this.rows)
		end
	end

	BTV:RefreshBarSettingsPage(barId)
end

-- Highlights whichever swatch matches the bar's current cols/rows.
local function RefreshGridSwatchSelection(page, cols, rows)
	local i

	for i = 1, table.getn(page.gridSwatches) do
		local swatch = page.gridSwatches[i]

		if swatch.cols == cols and swatch.rows == rows then
			swatch:SetBackdropBorderColor(1, 0.82, 0, 1)
		else
			swatch:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
		end
	end
end

-------------------------------------------------------------------------
-- Reusable scrollable content area
--
-- One generic ScrollFrame + wiring helper, used to back every settings
-- page/tab (bar pages via contentPanel, the General tab, the Profiles
-- tab) - so the up/down scrollbar buttons, mouse-wheel scrolling, and
-- draggable thumb only need to be built and wired once, and any page
-- that grows past its available height automatically gets scrolling
-- with zero page-specific code.
-------------------------------------------------------------------------

-- How far one mouse-wheel notch moves the scrollbar, in pixels.
local SETTINGS_SCROLL_WHEEL_STEP = 30

-- Creates a native ScrollFrame (UIPanelScrollFrameTemplate already
-- supplies the up/down arrow buttons and the draggable thumb) parented
-- to `parent`, with mouse-wheel scrolling wired in. The caller positions/
-- sizes the returned scrollFrame exactly like it would a plain content
-- Frame; actual content should be parented into whatever scrollchild
-- BTV:UpdateScrollFrame below is later given for it (via
-- scrollFrame:SetScrollChild), not into scrollFrame itself.
-- scrollbarOnLeft (optional): UIPanelScrollBarTemplate's own XML anchors
-- the scrollbar to the scrollframe's RIGHT side (TOPLEFT/BOTTOMLEFT ->
-- TOPRIGHT/BOTTOMRIGHT, +4 x-offset) - passing true re-anchors it to the
-- LEFT side instead (mirrored offsets), for callers like the bar-list
-- sidebar where the scrollbar reads better on the left. Purely cosmetic
-- repositioning - the scrollbar's own up/down buttons and thumb-drag
-- still work exactly the same, since they're anchored relative to the
-- scrollbar frame itself, not the scrollframe.
function BTV:CreateScrollFrame(parent, name, scrollbarOnLeft)
	local scrollFrame = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")

	local scrollBar = getglobal(name .. "ScrollBar")

	scrollFrame.scrollBar = scrollBar

	-- UIPanelScrollFrameTemplate's own XML wires OnScrollRangeChanged to the
	-- native ScrollFrame_OnScrollRangeChanged (Interface\FrameXML\UIPanelTemplates.lua),
	-- which shows/hides the scrollbar itself based on its OWN internal range
	-- calc - a second, conflicting authority over visibility on top of our
	-- own maxScroll-based Show()/Hide() in BTV:UpdateScrollFrame (confirmed
	-- live via diag19: it was re-Show()-ing a scrollbar our own code had
	-- just Hidden, since no reserve was allocated for it - the "MainBar
	-- scrollbar renders outside the window" bug). Overriding this to a
	-- no-op makes BTV:UpdateScrollFrame the single source of truth for
	-- scrollbar visibility, matching the reserve-space decision it already
	-- drives.
	scrollFrame:SetScript("OnScrollRangeChanged", function() end)

	if scrollBar and scrollbarOnLeft then
		scrollBar:ClearAllPoints()
		scrollBar:SetPoint("TOPRIGHT", scrollFrame, "TOPLEFT", -4, -16)
		scrollBar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMLEFT", -4, 16)
	end

	if scrollBar then
		-- Same dark backdrop the top nav tabs carry
		-- (BTV:StyleModernButton, UIWidgets.lua) so the scrollbar reads as
		-- part of the same UI rather than a bare native slider track.
		scrollBar:SetBackdrop({
			bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})

		scrollBar:SetBackdropColor(0.08, 0.08, 0.08, 0.85)
		scrollBar:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
	end

	scrollFrame:EnableMouseWheel(true)

	scrollFrame:SetScript("OnMouseWheel", function()
		if not scrollBar then
			return
		end

		local minVal, maxVal = scrollBar:GetMinMaxValues()
		local newValue = scrollBar:GetValue() - (arg1 * SETTINGS_SCROLL_WHEEL_STEP)

		if newValue < minVal then
			newValue = minVal
		elseif newValue > maxVal then
			newValue = maxVal
		end

		scrollBar:SetValue(newValue)
	end)

	if scrollBar then
		-- UIPanelScrollBarTemplate's own up/down buttons and thumb-drag
		-- both work purely by changing the slider's value - this is the
		-- one place that actually moves the scroll view in response.
		scrollBar:SetScript("OnValueChanged", function()
			scrollFrame:SetVerticalScroll(this:GetValue())
		end)
	end

	return scrollFrame
end

-- Points `scrollFrame` at `scrollChild` (a plain Frame the caller already
-- parents its real page content into - e.g. settingsFrame.contentPanel/
-- generalPanel/profilesPanel), sizes the scrollchild to
-- `requiredContentHeight` (the page's real, possibly-taller-than-visible
-- content height, as already measured by ApplySettingsHeightFromCandidates
-- below), sizes the scrollFrame itself to the clamped `viewportHeight`,
-- restores scroll to `preserveScroll` (clamped to the new range) instead of
-- always snapping to the top, and shows/hides the scrollbar depending on
-- whether there's actually anything to scroll. Called every time a page's
-- content changes, so scrolling turns on/off automatically as content
-- grows/shrinks - no per-page special-casing needed.
-- preserveScroll (optional): the scroll offset to restore, in the SAME
-- units as GetVerticalScroll()/SetMinMaxValues (pixels) - the caller reads
-- this via scrollFrame:GetVerticalScroll() BEFORE doing anything that would
-- reset it (see ApplySettingsHeightFromCandidates, which itself resets
-- scroll to 0 to get accurate GetTop()/GetBottom() reads while measuring).
-- Omitted/nil means "start at the top", same as the old unconditional
-- behavior - every caller that doesn't care about preserving position
-- (e.g. a brand new page being shown for the first time) can just leave
-- this out.
function BTV:UpdateScrollFrame(scrollFrame, scrollChild, requiredContentHeight, viewportHeight, preserveScroll)
	scrollChild:SetWidth(scrollFrame:GetWidth())
	scrollChild:SetHeight(requiredContentHeight)

	scrollFrame:SetScrollChild(scrollChild)
	scrollFrame:SetHeight(viewportHeight)

	local scrollBar = scrollFrame.scrollBar

	local maxScroll = requiredContentHeight - viewportHeight

	if maxScroll < 0 then
		maxScroll = 0
	end

	local targetScroll = preserveScroll or 0

	if targetScroll > maxScroll then
		targetScroll = maxScroll
	end

	if targetScroll < 0 then
		targetScroll = 0
	end

	scrollFrame:SetVerticalScroll(targetScroll)

	if scrollBar then
		scrollBar:SetMinMaxValues(0, maxScroll)
		scrollBar:SetValue(targetScroll)

		if maxScroll > 0 then
			scrollBar:Show()
		else
			scrollBar:Hide()
		end

		-- Hand the space a hidden scrollbar would have occupied back to the
		-- content, instead of reserving it permanently - each scrollframe
		-- that cares supplies its own re-layout callback at creation time
		-- (see CreateSettingsFrame's ApplyBarsViewScrollbarReserves and
		-- BTV:CreateWideContentScrollFrame). Note the scrollchild width is
		-- re-synced above from the frame's PREVIOUS width, so it settles one
		-- call behind a width change - harmless here, since every caller
		-- re-fits whenever the content it holds actually changes.
		scrollFrame.needsScrollbar = maxScroll > 0

		if scrollFrame.applyScrollbarReserve then
			scrollFrame.applyScrollbarReserve()
			scrollChild:SetWidth(scrollFrame:GetWidth())
		end
	end
end

-- Lets other files (DefaultBars.lua's native-checkbox reconciliation)
-- check whether the settings window has ever been built this session
-- WITHOUT forcing it into existence as a side effect - unlike calling any
-- of the BTV:GetOrCreate*/RefreshBarList-style functions directly, which
-- all create it lazily if it doesn't exist yet.
function BTV:IsSettingsFrameCreated()
	return settingsFrame ~= nil
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

	-- Enlarged from the original 640x560 (Phase C point 1) - the content
	-- panel's grid swatches, sliders, and stepper/delete controls were
	-- clipping against the bottom/right edges at the old size.
	f:SetWidth(780)
	f:SetHeight(680)

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
	-- Top-level view tabs ("Bars" / "General")
	--
	-- Only two views exist, so this is a plain two-button switch rather
	-- than a general-purpose tab system - ShowBarPage/ShowGeneralView
	-- below own which panels are shown, mirroring the same show/hide-one-
	-- page-at-a-time pattern GetOrCreateBarPage/ShowBarPage already use
	-- for individual bar pages.
	-------------------------------------------------------------------------

	f.currentView = "bars"

	-- Top nav tabs get a fading gold highlight (BTV:CreateFadeStrip,
	-- UIWidgets.lua) instead of BTV:StyleModernButton's own default solid
	-- border swap - scoped to just these 3 buttons per the styling pass
	-- ("the top navigation row" only); every other StyleModernButton call
	-- site in this file keeps its original border-swap hover look.
	-- Matches BTV:StyleModernButton's own backdrop insets (3px each side) -
	-- the fade strips previously covered the FULL 90x20 button frame, which
	-- spills past the button's actual black backdrop rectangle (inset from
	-- the frame edges by this same amount), live-tested and confirmed.
	local TAB_FADE_INSET = 3

	-- StyleModernButton's own rest-state border color (UIWidgets.lua) -
	-- restored here as the tab's own "inactive" border color, since tabs
	-- keep a real border (unlike bar-list rows) for visual distinctness,
	-- just recolored per-state instead of left at StyleModernButton's own
	-- fixed grey/gold swap.
	local TAB_BORDER_REST_COLOR = { 0.55, 0.55, 0.55 }

	local function ApplyTabFadeHighlight(button)
		local stripWidth = 90 - (TAB_FADE_INSET * 2)
		local stripHeight = 20 - (TAB_FADE_INSET * 2)

		-- Persistent highlight for whichever tab matches the currently open
		-- view (settingsFrame.currentView, see BTV:RefreshActiveTabHighlight
		-- below) - same gold BTV.UI_ACCENT_COLOR the bar-list sidebar's own
		-- selected row uses (BTVListRowMixin), so "currently open" reads
		-- consistently across both the tabs and the sidebar. Created FIRST
		-- so hoverStrip (below) draws on top of it when both show at once.
		local selectStrip = BTV:CreateFadeStrip(button, stripWidth, stripHeight)

		selectStrip:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", TAB_FADE_INSET, TAB_FADE_INSET)
		selectStrip:SetFadeColor(BTV.UI_ACCENT_COLOR[1], BTV.UI_ACCENT_COLOR[2], BTV.UI_ACCENT_COLOR[3])
		selectStrip:SetPeakAlpha(0.5)
		selectStrip:Hide()

		button.tabSelectStrip = selectStrip

		-- Hover uses the neutral BTV.UI_HOVER_COLOR instead - matches the
		-- bar-list sidebar's own hover/select color split (white hover,
		-- gold select) rather than reusing gold for both, which would make
		-- "hovering" and "currently open" indistinguishable from each
		-- other.
		local hoverStrip = BTV:CreateFadeStrip(button, stripWidth, stripHeight)

		hoverStrip:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", TAB_FADE_INSET, TAB_FADE_INSET)
		hoverStrip:SetFadeColor(BTV.UI_HOVER_COLOR[1], BTV.UI_HOVER_COLOR[2], BTV.UI_HOVER_COLOR[3])
		hoverStrip:SetPeakAlpha(0.5)
		hoverStrip:Hide()

		button.isHovering = false

		-- Border color always tracks whichever fade is currently the most
		-- prominent for this button - hover wins over select (matches the
		-- fade layering, hoverStrip drawn on top of selectStrip), select
		-- wins over rest. Called on hover change AND from
		-- BTV:RefreshActiveTabHighlight (select-state changes elsewhere).
		function button:UpdateFadeBorderColor()
			if self.isHovering then
				self:SetBackdropBorderColor(BTV.UI_HOVER_COLOR[1], BTV.UI_HOVER_COLOR[2], BTV.UI_HOVER_COLOR[3], 1)
			elseif self.tabSelectStrip and self.tabSelectStrip:IsShown() then
				self:SetBackdropBorderColor(BTV.UI_ACCENT_COLOR[1], BTV.UI_ACCENT_COLOR[2], BTV.UI_ACCENT_COLOR[3], 1)
			else
				self:SetBackdropBorderColor(TAB_BORDER_REST_COLOR[1], TAB_BORDER_REST_COLOR[2], TAB_BORDER_REST_COLOR[3], 1)
			end
		end

		button:UpdateFadeBorderColor()

		-- Set AFTER StyleModernButton, which installed its own
		-- OnEnter/OnLeave above - this replaces them rather than adding
		-- to them. OnMouseDown/OnMouseUp (press-nudge) are untouched.
		button:SetScript("OnEnter", function()
			this.isHovering = true
			hoverStrip:Show()
			this:UpdateFadeBorderColor()
		end)

		button:SetScript("OnLeave", function()
			this.isHovering = false
			hoverStrip:Hide()
			this:UpdateFadeBorderColor()
		end)
	end

	local tabBarsButton = CreateFrame(
		"Button",
		nil,
		f
	)

	tabBarsButton:SetHeight(20)

	tabBarsButton:SetPoint(
		"TOPLEFT",
		f,
		"TOPLEFT",
		18,
		-34
	)

	BTV:StyleModernButton(tabBarsButton, 90, 90)
	tabBarsButton:SetText("Bars")
	ApplyTabFadeHighlight(tabBarsButton)

	tabBarsButton:SetScript(
		"OnClick",
		function()
			BTV:ShowBarsView()
		end
	)

	local tabGeneralButton = CreateFrame(
		"Button",
		nil,
		f
	)

	tabGeneralButton:SetHeight(20)

	tabGeneralButton:SetPoint(
		"LEFT",
		tabBarsButton,
		"RIGHT",
		6,
		0
	)

	BTV:StyleModernButton(tabGeneralButton, 90, 90)
	tabGeneralButton:SetText("General")
	ApplyTabFadeHighlight(tabGeneralButton)

	tabGeneralButton:SetScript(
		"OnClick",
		function()
			BTV:ShowGeneralView()
		end
	)

	local tabProfilesButton = CreateFrame(
		"Button",
		nil,
		f
	)

	tabProfilesButton:SetHeight(20)

	tabProfilesButton:SetPoint(
		"LEFT",
		tabGeneralButton,
		"RIGHT",
		6,
		0
	)

	BTV:StyleModernButton(tabProfilesButton, 90, 90)
	tabProfilesButton:SetText("Profiles")
	ApplyTabFadeHighlight(tabProfilesButton)

	tabProfilesButton:SetScript(
		"OnClick",
		function()
			BTV:ShowProfilesView()
		end
	)

	f.tabButtonsByView = {
		bars = tabBarsButton,
		general = tabGeneralButton,
		profiles = tabProfilesButton,
	}

	-- Matches f.currentView's own initial value ("bars", set at the top of
	-- this function) - every later view switch calls
	-- BTV:RefreshActiveTabHighlight itself, but this is the one point
	-- before settingsFrame is even assigned where that function can't be
	-- called yet.
	tabBarsButton.tabSelectStrip:Show()
	tabBarsButton:UpdateFadeBorderColor()

	-------------------------------------------------------------------------
	-- Divider between the tab row and the content below it - the tab
	-- buttons' own bottom edge (y=-34-20=-54) and the content panels'
	-- previous top edge (y=-52) used to OVERLAP by 2px with no visual
	-- separation at all. Two-point SetPoint (TOPLEFT+TOPRIGHT, no fixed
	-- width) so it stretches to match the window's own width regardless
	-- of which view resized it, matching the bars/extra-bars divider's own
	-- WHITE8X8 technique further down this file.
	-------------------------------------------------------------------------

	local tabContentDivider = f:CreateTexture(nil, "ARTWORK")

	tabContentDivider:SetTexture("Interface\\Buttons\\WHITE8X8")
	tabContentDivider:SetVertexColor(0.5, 0.5, 0.5, 0.6)
	tabContentDivider:SetHeight(1)

	tabContentDivider:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -59)
	tabContentDivider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -59)

	-------------------------------------------------------------------------
	-- Left bar list
	-------------------------------------------------------------------------

	-- f.listPanel is the fixed VIEWPORT (visible bounds + border +
	-- scrollbar), same shape as contentScrollFrame below - f.listContent
	-- is its permanent scroll child that the actual bar-list rows/divider
	-- get parented/anchored into (BTV:RefreshBarList), sized to the FULL
	-- row-list height so BTV:UpdateScrollFrame can turn scrolling on
	-- whenever the list has more rows than the window currently has room
	-- for - previously a plain, non-scrolling Frame, which let rows render
	-- past the window's own bottom edge (into the game world beneath it)
	-- whenever the fitted window height came out shorter than the full
	-- row list, live-tested and confirmed. Also future-proofs against a
	-- later user-resizable window, where the list needs to already know
	-- how to cope with less vertical space than its content needs.
	f.listPanel = BTV:CreateScrollFrame(f, "BTVanillaSettingsListScrollFrame", true)

	f.listPanel:SetWidth(140)
	f.listPanel:SetHeight(610)

	-- Positioned by ApplyBarsViewScrollbarReserves (defined once both
	-- panels exist, just below contentScrollFrame) - the space each
	-- scrollbar needs is only reserved while that scrollbar is actually
	-- shown, so neither panel gives up room to a bar that isn't there.

	-- Same backdrop technique/values as contentScrollFrame just below, so
	-- the row list reads as one bordered/divided container, matching the
	-- native Options window's own list style (UI-redesign plan).
	f.listPanel:SetBackdrop({
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

	f.listPanel:SetBackdropColor(
		0,
		0,
		0,
		0.3
	)

	f.barButtons = {}
	f.barButtonsByBarId = {}

	-- Lives directly on the viewport (f.listPanel), NOT the scrolling
	-- f.listContent below - stays fixed/visible at the top regardless of
	-- scroll position, rather than scrolling away with the rows.
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
		-8
	)

	listTitle:SetText("Action Bars")

	f.listContent = CreateFrame("Frame", nil, f.listPanel)

	-- Matches f.contentPanel's own pattern just below (SetWidth/SetHeight +
	-- SetScrollChild called IMMEDIATELY here, not left until the first
	-- deferred Fit) - without this, the list rendered nothing at all until
	-- BTV:UpdateScrollFrame's own SetScrollChild call finally ran on the
	-- next-frame-deferred Fit, and even then the scroll child had never
	-- been given a real starting size, live-tested and confirmed as the
	-- list not appearing at all.
	f.listContent:SetWidth(f.listPanel:GetWidth())
	f.listContent:SetHeight(610)

	f.listPanel:SetScrollChild(f.listContent)

	-------------------------------------------------------------------------
	-- Right content panel
	--
	-- contentScrollFrame is the fixed VIEWPORT (visible bounds + border +
	-- scrollbar) for the Bars view specifically - contentPanel is its
	-- permanent scroll child (BTV:UpdateScrollFrame resizes it to fit
	-- whichever bar page is showing, which can exceed the viewport -
	-- that's exactly what makes the scrollbar appear). General/Profiles
	-- each get their OWN scrollframe+scrollchild pair the same shape
	-- (BTV:CreateWideContentScrollFrame below, called from
	-- GetOrCreateGeneralPanel/GetOrCreateProfilesPanel) rather than
	-- sharing this one - re-targeting a single shared scrollframe's
	-- scroll child at a DIFFERENT frame after creation (tried first) left
	-- that frame with no resolvable position/size at all the first time
	-- it was ever attached, rendering completely empty; every scrollframe
	-- here is instead permanently paired with its one scrollchild from
	-- the moment both are created, never re-targeted.
	-------------------------------------------------------------------------

	f.contentScrollFrame = BTV:CreateScrollFrame(f, "BTVanillaSettingsContentScrollFrame")

	f.contentScrollFrame:SetHeight(610)

	-------------------------------------------------------------------------
	-- Bars-view horizontal geometry
	--
	-- Both panels' widths/anchors are recomputed from whichever scrollbars
	-- are CURRENTLY shown, rather than permanently reserving room for both:
	-- a panel that doesn't need to scroll gets that space back as usable
	-- content width. Same "only reserve the space while the thing is
	-- actually visible" rule as the profile-lock banner band
	-- (BTV:ApplyPageBannerReserve) and the General tab's own reveal-sliders
	-- (BTV:ReflowGeneralOverrideSliders).
	--
	-- The two are coupled - listPanel's scrollbar sits on its LEFT
	-- (BTV:CreateScrollFrame's scrollbarOnLeft) and contentScrollFrame's on
	-- its right - so one function owns both rather than each re-anchoring
	-- itself and fighting over the gap between them. Driven from
	-- BTV:UpdateScrollFrame, which is where scrollbar visibility is
	-- actually decided.
	-------------------------------------------------------------------------

	local BARS_VIEW_PADDING = 18
	local BARS_VIEW_LIST_WIDTH = 140
	local BARS_VIEW_PANEL_GAP = 2
	local BARS_VIEW_TOP = -64

	local function ApplyBarsViewScrollbarReserves()
		local leftReserve = f.listPanel.needsScrollbar and SETTINGS_SCROLLBAR_RESERVED_WIDTH or 0
		local rightReserve = f.contentScrollFrame.needsScrollbar and SETTINGS_SCROLLBAR_RESERVED_WIDTH or 0

		f.listPanel:ClearAllPoints()
		f.listPanel:SetPoint(
			"TOPLEFT",
			f,
			"TOPLEFT",
			BARS_VIEW_PADDING + leftReserve,
			BARS_VIEW_TOP
		)

		f.contentScrollFrame:ClearAllPoints()
		f.contentScrollFrame:SetPoint(
			"TOPRIGHT",
			f,
			"TOPRIGHT",
			-BARS_VIEW_PADDING - rightReserve,
			BARS_VIEW_TOP
		)

		-- Anchored by TOPRIGHT, so its width is what sets its LEFT edge -
		-- i.e. the gap to the bar list beside it.
		f.contentScrollFrame:SetWidth(
			f:GetWidth()
				- (2 * BARS_VIEW_PADDING)
				- BARS_VIEW_LIST_WIDTH
				- BARS_VIEW_PANEL_GAP
				- leftReserve
				- rightReserve
		)
	end

	f.listPanel.applyScrollbarReserve = ApplyBarsViewScrollbarReserves
	f.contentScrollFrame.applyScrollbarReserve = ApplyBarsViewScrollbarReserves

	ApplyBarsViewScrollbarReserves()

	f.contentScrollFrame:SetBackdrop({
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

	f.contentScrollFrame:SetBackdropColor(
		0,
		0,
		0,
		0.3
	)

	f.contentPanel = CreateFrame(
		"Frame",
		nil,
		f.contentScrollFrame
	)

	f.contentPanel:SetWidth(f.contentScrollFrame:GetWidth())
	f.contentPanel:SetHeight(610)

	f.contentScrollFrame:SetScrollChild(f.contentPanel)

	f.pages = {}

	settingsFrame = f

	return f
end

-- Creates one scrollframe+scrollchild pair spanning the FULL content
-- width (the space the bar list would otherwise occupy, since it's
-- hidden in General/Profiles) - shared shape for GetOrCreateGeneralPanel/
-- GetOrCreateProfilesPanel below, each calling this once to build their
-- own independent pair (see CreateSettingsFrame's own comment on why each
-- view gets its own rather than sharing one). Returns scrollFrame,
-- scrollChild - caller stores both (e.g. settingsFrame.generalScrollFrame/
-- generalPanel) and builds its real content into scrollChild.
function BTV:CreateWideContentScrollFrame(name)
	local scrollFrame = BTV:CreateScrollFrame(settingsFrame, name)

	scrollFrame:SetHeight(610)

	-- settingsFrame:GetWidth() is a fixed literal (SetWidth(780) once, in
	-- CreateSettingsFrame, never anchor-derived) so it's always
	-- immediately correct to read - unlike the two-opposing-anchor
	-- implied width this used to be computed from (TOPLEFT to listPanel +
	-- TOPRIGHT here), which was not guaranteed resolved yet the moment
	-- code right after this reads it back via GetWidth().
	-- Only reserves room for its own scrollbar while that bar is actually
	-- shown (BTV:UpdateScrollFrame flips needsScrollbar and calls this back)
	-- - an unscrolled panel gets the full width instead.
	scrollFrame.applyScrollbarReserve = function()
		local reserve = scrollFrame.needsScrollbar and SETTINGS_SCROLLBAR_RESERVED_WIDTH or 0

		scrollFrame:SetWidth(settingsFrame:GetWidth() - 18 - 18 - reserve)

		scrollFrame:ClearAllPoints()
		scrollFrame:SetPoint(
			"TOPRIGHT",
			settingsFrame,
			"TOPRIGHT",
			-18 - reserve,
			-64
		)
	end

	scrollFrame.applyScrollbarReserve()

	scrollFrame:SetBackdrop({
		bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})

	scrollFrame:SetBackdropColor(0, 0, 0, 0.3)

	local scrollChild = CreateFrame("Frame", nil, scrollFrame)

	scrollChild:SetWidth(scrollFrame:GetWidth())
	scrollChild:SetHeight(610)

	scrollFrame:SetScrollChild(scrollChild)

	return scrollFrame, scrollChild
end

-------------------------------------------------------------------------
-- Create a bar settings page
--
-- Shared between default bars (1-5) and custom bars (6+). The controls
-- that don't apply to one kind (enable checkbox for bar 1 / default
-- bars 2-5 only, button-count stepper and Delete Bar for custom bars
-- only) are simply not created for the other kind, rather than
-- maintaining two parallel page builders.
-------------------------------------------------------------------------

function BTV:GetOrCreateBarPage(barId)
	if not settingsFrame then
		CreateSettingsFrame()
	end

	-- Stance Bar / Bag Bar / Micro Menu (features 2/3): dispatched out to
	-- the shared "simple" page builder further down this file (Position +
	-- optional Enable + Reset only) rather than through the full grid/
	-- spacing/button-size/buttonCount/delete page builder below - none of
	-- these three elements is a TrustyBars-owned button grid.
	if simpleBarPageConfigs[barId] then
		return self:GetOrCreateSimpleBarPage(barId)
	end

	if settingsFrame.pages[barId] then
		return settingsFrame.pages[barId]
	end

	local isDefault = IsDefaultBarId(barId)

	local page = CreateFrame(
		"Frame",
		nil,
		settingsFrame.contentPanel
	)

	-- Anchored through ApplyPageBannerReserve (rather than SetAllPoints) so
	-- the page can slide down to open up the profile-lock banner's band
	-- only while that banner is actually shown - starts unlocked/flush.
	BTV:ApplyPageBannerReserve(page, false)

	page.barId = barId
	page.isDefault = isDefault

	page.profileLockWarning = self:CreateProfileLockWarning(page)

	-------------------------------------------------------------------------
	-- Title
	-------------------------------------------------------------------------

	local title = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalLarge"
	)

	-- Anchored to contentPanel, not `page` - the title has to stay put
	-- while the page slides down to open the banner's band beneath it
	-- (BTV:ApplyPageBannerReserve).
	title:SetPoint(
		"TOPLEFT",
		settingsFrame.contentPanel,
		"TOPLEFT",
		INDENT_SECTION,
		-14
	)

	local titleText = GetBarDisplayName(barId, isDefault) .. " Settings"

	if isDefault then
		titleText = titleText .. " (Default)"
	end

	title:SetText(titleText)

	-- Extra Bars (ids 6-9, Stance/Page Bar Assignment feature, Part 1):
	-- get the exact same "Enabled" checkbox default bars 2-5 get, since
	-- they now follow the same always-exists-toggle-only lifecycle -
	-- see BTV:IsExtraBarId/SetExtraBarEnabled (Bar.lua).
	local isExtraBar = BTV:IsExtraBarId(barId)
	local hasEnableCheckbox = (isDefault and barId ~= 1) or isExtraBar

	-------------------------------------------------------------------------
	-- Vertical layout cursor
	--
	-- Recomputed from scratch (fix-up batch) after two changes cascaded
	-- through the whole page: the static Position range caption is gone
	-- (freeing the space it used to occupy), and the enable checkbox
	-- (bars 2-5 only) moved from an off-to-the-right TOPRIGHT anchor to
	-- being the first control on the page, above the Position section.
	-- Every offset below is derived from deltas rather than independent
	-- magic numbers, so this whole block is the single place to retune
	-- spacing instead of hunting through every control's SetPoint.
	-------------------------------------------------------------------------

	-- No banner reserve baked in here any more - the whole page slides down
	-- by PROFILE_LOCK_BANNER_HEIGHT only while the banner is actually shown
	-- (BTV:ApplyPageBannerReserve, called from ApplyProfileLockGating), so
	-- an unlocked page's first control sits directly under its title
	-- instead of below a permanently reserved empty band.
	local contentTopOffset = 0

	local checkboxY = -44 + contentTopOffset

	-- Position section starts right under the title, or - on bars 2-5 -
	-- right under the enable checkbox block (checkbox height + the gap
	-- reserved before Position begins).
	local positionStartY = -46 + contentTopOffset

	if hasEnableCheckbox then
		positionStartY = checkboxY - 24 - 14
	end

	local xLabelY = positionStartY
	local xSliderY = xLabelY + 4
	local yLabelY = xSliderY - 40
	local ySliderY = yLabelY + 4
	local sizeLayoutTitleY = ySliderY - 36
	local buttonSizeSliderY = sizeLayoutTitleY - 26

	-------------------------------------------------------------------------
	-- Enable checkbox (default bars 2-5 only - bar 1 always active)
	--
	-- Now the very first control on the page (fix-up batch) - previously
	-- TOPRIGHT-anchored to the page's top-right corner, which pushed it
	-- outside the window's visible bounds. Re-anchored TOPLEFT like every
	-- other control so it participates in the normal top-down flow.
	-------------------------------------------------------------------------

	if hasEnableCheckbox then
		local enableCheckbox = CreateFrame(
			"CheckButton",
			"BTVanillaDefaultBar" .. tostring(barId) .. "EnableCheckbox",
			page,
			"UICheckButtonTemplate"
		)

		enableCheckbox:SetWidth(24)
		enableCheckbox:SetHeight(24)

		enableCheckbox:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_SECTION,
			checkboxY
		)

		enableCheckbox.barId = barId

		enableCheckbox:SetScript(
			"OnClick",
			function()
				local checked = this:GetChecked() and true or false

				if isDefault then
					BTV:SetDefaultBarEnabled(this.barId, checked)
				else
					BTV:SetExtraBarEnabled(this.barId, checked)
				end

				BTV:RefreshBarList()
			end
		)

		-- UICheckButtonTemplate auto-creates $parentText, anchored to the
		-- checkbox's own right side - the same "Enabled" label pattern
		-- already used by the General tab's "Use Default Blizzard Layout"
		-- checkbox.
		local enableLabel = getglobal(enableCheckbox:GetName() .. "Text")

		if enableLabel then
			enableLabel:SetText("Enabled")
		end

		page.enableCheckbox = enableCheckbox
	end

	-------------------------------------------------------------------------
	-- Position section
	--
	-- The static "Position (X: ... to ..., Y: ... to ...)" range caption
	-- (fix-up batch) is gone entirely - GetScreenCoordinateRange's min/max
	-- are still needed for the sliders' SetMinMaxValues below, just no
	-- longer echoed back as a page caption. The live current X/Y values
	-- are now shown the same way Button Size shows its own live value:
	-- a centered FontString under each slider (see xValueText/yValueText).
	-------------------------------------------------------------------------

	local minX, maxX, minY, maxY =
		GetScreenCoordinateRange()

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
		INDENT_CONTROL,
		xLabelY
	)

	xLabel:SetText("X")

	local xSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "XSlider",
		290
	)

	xSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		INDENT_INPUT,
		xSliderY
	)

	xSlider:SetMinMaxValues(
		minX,
		maxX
	)

	xSlider:SetValueStep(1)

	-- The slider's own built-in label just names the control now (matches
	-- the Button Size slider's pattern) - the live numeric value lives in
	-- xValueText below instead.
	SetSliderLabel(
		xSlider,
		"X"
	)

	-- Live numeric readout, centered below the slider (fix-up batch,
	-- Change 2) - bare number only, same pattern as buttonSizeValueText.
	-- Placeholder only: RefreshBarSettingsPage (called immediately after
	-- GetOrCreateBarPage by ShowBarPage) overwrites this with the real
	-- %.2f-formatted value from cfg.x before this page is ever shown.
	local xValueText = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	xValueText:SetPoint(
		"TOP",
		xSlider,
		"BOTTOM",
		0,
		-2
	)

	xValueText:SetText(
		string.format("%.2f", 0)
	)

	page.xValueText = xValueText

	xSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			-- Display-only rounding (Phase C point 2) - the slider's raw
			-- GetValue() keeps full precision, which ApplyLiveBarPosition
			-- below still reads directly and passes straight through to
			-- SetBarPosition/SetDefaultBarPosition unrounded.
			xValueText:SetText(
				string.format("%.2f", value)
			)

			-- Live: applied on every tick, not gated behind Apply.
			if not this.suppressApply then
				BTV:ApplyLiveBarPosition(page)
			end
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
		INDENT_CONTROL,
		yLabelY
	)

	yLabel:SetText("Y")

	local ySlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "YSlider",
		290
	)

	ySlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		INDENT_INPUT,
		ySliderY
	)

	ySlider:SetMinMaxValues(
		minY,
		maxY
	)

	ySlider:SetValueStep(1)

	-- The slider's own built-in label just names the control now - see the
	-- X slider's matching comment above.
	SetSliderLabel(
		ySlider,
		"Y"
	)

	-- Live numeric readout, centered below the slider - see the X slider's
	-- matching xValueText above.
	local yValueText = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	yValueText:SetPoint(
		"TOP",
		ySlider,
		"BOTTOM",
		0,
		-2
	)

	yValueText:SetText(
		string.format("%.2f", 0)
	)

	page.yValueText = yValueText

	ySlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			-- Display-only rounding (Phase C point 2) - see the X slider's
			-- OnValueChanged comment above.
			yValueText:SetText(
				string.format("%.2f", value)
			)

			if not this.suppressApply then
				BTV:ApplyLiveBarPosition(page)
			end
		end
	)

	page.ySlider = ySlider

	-- Reset to Blizzard Default (default bars only) now lives below the
	-- Spacing slider, just above Grid Layout - see that block further
	-- down, after the Spacing section, for its creation.

	-------------------------------------------------------------------------
	-- Size & Layout
	--
	-- sizeLayoutTitleY/buttonSizeSliderY were computed up in the vertical
	-- layout cursor block above (cascading from the Y slider's own value
	-- text), so both bar kinds - and both the checkbox/no-checkbox default
	-- bar variants - derive from the same delta chain instead of separate
	-- hand-tuned constants.
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
		INDENT_SECTION,
		sizeLayoutTitleY
	)

	layoutTitle:SetText(
		"Button Size (" .. tostring(BUTTON_SIZE_MIN) ..
		" to " .. tostring(BUTTON_SIZE_MAX) .. ")"
	)

	-------------------------------------------------------------------------
	-- Button Size
	-------------------------------------------------------------------------

	local buttonSizeSlider = CreateSettingSlider(
		page,
		"BTVanillaBar" .. tostring(barId) .. "ButtonSizeSlider",
		290
	)

	buttonSizeSlider:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		INDENT_INPUT,
		buttonSizeSliderY
	)

	buttonSizeSlider:SetMinMaxValues(
		BUTTON_SIZE_MIN,
		BUTTON_SIZE_MAX
	)

	-- Exactly the same 2-pixel increments as the mouse wheel.
	buttonSizeSlider:SetValueStep(
		BUTTON_SIZE_STEP
	)

	-- The slider's own built-in label just names the control - the live
	-- numeric value lives in buttonSizeValueText below instead (point 5).
	SetSliderLabel(
		buttonSizeSlider,
		"Button Size"
	)

	-- min/max end captions (point 6) - UISliderTemplate/OptionsSliderTemplate
	-- creates these as $parentLow/$parentHigh, defaulting to "Low"/"High".
	local buttonSizeSliderLow = getglobal(
		buttonSizeSlider:GetName() .. "Low"
	)

	if buttonSizeSliderLow then
		buttonSizeSliderLow:SetText(
			tostring(BUTTON_SIZE_MIN)
		)
	end

	local buttonSizeSliderHigh = getglobal(
		buttonSizeSlider:GetName() .. "High"
	)

	if buttonSizeSliderHigh then
		buttonSizeSliderHigh:SetText(
			tostring(BUTTON_SIZE_MAX)
		)
	end

	-- Live numeric readout, centered below the slider (point 5) - bare
	-- number only, no "Button Size:" prefix.
	local buttonSizeValueText = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	buttonSizeValueText:SetPoint(
		"TOP",
		buttonSizeSlider,
		"BOTTOM",
		0,
		-2
	)

	buttonSizeValueText:SetText(
		tostring(BTV.BUTTON_SIZE)
	)

	page.buttonSizeValueText = buttonSizeValueText

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

			buttonSizeValueText:SetText(
				tostring(value)
			)

			if not this.suppressApply then
				if page.isDefault then
					BTV:SetDefaultBarButtonSize(page.barId, value)
				else
					local bar = BTV.bars[page.barId]

					if bar then
						BTV:SetBarButtonSize(bar, value)
					end
				end
			end
		end
	)

	page.buttonSizeSlider = buttonSizeSlider

	-------------------------------------------------------------------------
	-- Spacing - every bar kind gets this control, default bars 1-5 AND
	-- true custom bars 6+ (see the SPACING_MIN/MAX comment above). Mirrors
	-- the Button Size slider's own live-value-label/min-max-end-label
	-- pattern exactly.
	-------------------------------------------------------------------------

	local gridTitleY
	local swatchY

	-- Spacing now exists for EVERY bar, default (1-5, bug-fix batch Fix 2)
	-- AND true custom (6+, bug-fix batch Fix 4) - Bar.lua's LayoutButtons/
	-- BarFrameSize already honor cfg.spacing generically for any bar that
	-- has one, and every bar (default or custom) is now guaranteed to have
	-- a real cfg.spacing field from creation (Core.lua's
	-- CaptureNativeSpacing/seedDefaultBars for default bars; Bar.lua's
	-- AddNewBar explicitly writing spacing = 0 for new custom bars). The
	-- OnValueChanged handler below branches to whichever setter the bar
	-- kind actually needs - BTV:SetDefaultBarSpacing (which itself further
	-- branches bar-1-direct-cfg-write vs. bars-2-5-delegate-to-Bar.lua
	-- internally) for default bars, BTV:SetBarSpacing for true custom bars.
	do
		local spacingTitleY = buttonSizeSliderY - 36
		local spacingSliderY = spacingTitleY - 26

		local spacingTitle = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormal"
		)

		spacingTitle:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_SECTION,
			spacingTitleY
		)

		spacingTitle:SetText(
			"Spacing (" .. tostring(SPACING_MIN) ..
			" to " .. tostring(SPACING_MAX) .. ")"
		)

		local spacingSlider = CreateSettingSlider(
			page,
			"BTVanillaBar" .. tostring(barId) .. "SpacingSlider",
			290
		)

		spacingSlider:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_INPUT,
			spacingSliderY
		)

		-- Displayed range (0-based) - see GetSpacingDisplayOffset. Also
		-- recomputed on every RefreshBarSettingsPage call, since the
		-- offset can change live with the border-style toggle.
		spacingSlider:SetMinMaxValues(
			0,
			SPACING_MAX - GetSpacingDisplayOffset()
		)

		spacingSlider:SetValueStep(
			SPACING_STEP
		)

		SetSliderLabel(
			spacingSlider,
			"Spacing"
		)

		local spacingSliderLow = getglobal(
			spacingSlider:GetName() .. "Low"
		)

		if spacingSliderLow then
			spacingSliderLow:SetText("0")
		end

		local spacingSliderHigh = getglobal(
			spacingSlider:GetName() .. "High"
		)

		if spacingSliderHigh then
			spacingSliderHigh:SetText(
				tostring(SPACING_MAX - GetSpacingDisplayOffset())
			)
		end

		page.spacingSliderLow = spacingSliderLow
		page.spacingSliderHigh = spacingSliderHigh

		local spacingValueText = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormalSmall"
		)

		spacingValueText:SetPoint(
			"TOP",
			spacingSlider,
			"BOTTOM",
			0,
			-2
		)

		-- Placeholder only - RefreshBarSettingsPage (called immediately
		-- after GetOrCreateBarPage by ShowBarPage) sets the real value
		-- from cfg.spacing before this page is ever shown.
		spacingValueText:SetText("0")

		page.spacingValueText = spacingValueText

		spacingSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor(value + 0.5)

				-- The slider's own value is always DISPLAYED (0-based) -
				-- convert to real only at this write boundary.
				spacingValueText:SetText(
					tostring(value)
				)

				if not this.suppressApply then
					local real = value + GetSpacingDisplayOffset()

					if page.isDefault then
						BTV:SetDefaultBarSpacing(page.barId, real)
					else
						local bar = BTV.bars[page.barId]

						if bar then
							BTV:SetBarSpacing(bar, real)
						end
					end
				end
			end
		)

		page.spacingSlider = spacingSlider

		if isDefault then
			-------------------------------------------------------------------------
			-- Reset to Blizzard default position (default bars only - custom
			-- bars have no native Blizzard anchor to reset to, see
			-- DefaultBars.lua's ResetDefaultBarLayout/nativeAnchor). Lives
			-- below the Spacing slider and above Grid Layout.
			-------------------------------------------------------------------------

			local resetButtonY = spacingSliderY - 36

			local resetPositionButton = CreateFrame(
				"Button",
				nil,
				page
			)

			resetPositionButton:SetHeight(22)

			resetPositionButton:SetPoint(
				"TOPLEFT",
				page,
				"TOPLEFT",
				INDENT_INPUT,
				resetButtonY
			)

			BTV:StyleModernButton(resetPositionButton, 200, 200)
			resetPositionButton:SetText("Reset to Blizzard Default")

			resetPositionButton:SetScript(
				"OnClick",
				function()
					-- Renamed from ResetDefaultBarPosition (bug-fix batch,
					-- Issue 3): now also restores cols/rows/buttonSize back
					-- to their native defaults, not just position/spacing.
					BTV:ResetDefaultBarLayout(page.barId)

					-- Same pattern as GridSwatch_OnClick: re-sync every
					-- control's displayed value from the saved config after
					-- an external (non-slider) write, rather than trusting
					-- pre-reset values. RefreshBarSettingsPage already
					-- re-syncs the X/Y sliders, the Button Size slider/
					-- value text, AND the grid-swatch selection
					-- (RefreshGridSwatchSelection) in one call, so nothing
					-- else needs to be called separately here for
					-- cols/rows/buttonSize to catch up too.
					BTV:RefreshBarSettingsPage(page.barId)
				end
			)

			page.resetPositionButton = resetPositionButton

			-- Grid Layout shifts down to make room for the Spacing section
			-- plus the Reset button above it.
			gridTitleY = resetButtonY - 34
			swatchY = gridTitleY - 26
		else
			-- True custom bars (6+): no Reset-to-Blizzard-Default concept
			-- (Fix 4 - they have no native baseline to reset to), so Grid
			-- Layout follows directly under the Spacing slider using the
			-- same title/slider delta (36/26) used everywhere else in this
			-- cascade.
			gridTitleY = spacingSliderY - 36
			swatchY = gridTitleY - 26
		end
	end

	-------------------------------------------------------------------------
	-- Grid layout presets
	-------------------------------------------------------------------------

	local gridTitle = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormal"
	)

	gridTitle:SetPoint(
		"TOPLEFT",
		page,
		"TOPLEFT",
		INDENT_SECTION,
		gridTitleY
	)

	gridTitle:SetText("Grid Layout")

	page.gridSwatches = {}

	local i
	local xOffset = INDENT_CONTROL

	for i = 1, table.getn(GRID_PRESETS) do
		local preset = GRID_PRESETS[i]

		local swatch = CreateGridSwatch(page, preset)

		swatch:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			xOffset,
			swatchY
		)

		swatch.page = page

		swatch:SetScript(
			"OnClick",
			GridSwatch_OnClick
		)

		page.gridSwatches[i] = swatch

		xOffset = xOffset + SWATCH_SIZE + SWATCH_GAP
	end

	-------------------------------------------------------------------------
	-- Button count stepper (custom bars only)
	--
	-- Default bars always show all 12 Blizzard buttons - Phase 1
	-- explicitly decided default bars don't need buttonCount.
	-------------------------------------------------------------------------

	if not isDefault then
		-- Derived from swatchY (fix-up batch) rather than a hand-tuned
		-- constant: the swatch grid is SWATCH_SIZE tall plus its own
		-- caption line below it, then a 14px gap before this section's
		-- label, then a 28px label-to-row gap (matches the same delta
		-- used by every other section-title-to-control step above).
		local buttonCountLabelY = swatchY - SWATCH_SIZE - 14 - 14
		local buttonCountRowY = buttonCountLabelY - 28

		local buttonCountLabel = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormal"
		)

		buttonCountLabel:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_SECTION,
			buttonCountLabelY
		)

		buttonCountLabel:SetText("Buttons Shown")

		local buttonCountMinus = CreateFrame(
			"Button",
			"BTVanillaBar" .. tostring(barId) .. "ButtonCountMinus",
			page
		)

		buttonCountMinus:SetHeight(22)

		buttonCountMinus:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_INPUT,
			buttonCountRowY
		)

		BTV:StyleModernButton(buttonCountMinus, 24, 24)
		buttonCountMinus:SetText("-")

		local buttonCountValueText = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormalSmall"
		)

		buttonCountValueText:SetPoint(
			"LEFT",
			buttonCountMinus,
			"RIGHT",
			8,
			0
		)

		buttonCountValueText:SetWidth(24)
		buttonCountValueText:SetJustifyH("CENTER")
		buttonCountValueText:SetText("12")

		local buttonCountPlus = CreateFrame(
			"Button",
			"BTVanillaBar" .. tostring(barId) .. "ButtonCountPlus",
			page
		)

		buttonCountPlus:SetHeight(22)

		buttonCountPlus:SetPoint(
			"LEFT",
			buttonCountValueText,
			"RIGHT",
			8,
			0
		)

		BTV:StyleModernButton(buttonCountPlus, 24, 24)
		buttonCountPlus:SetText("+")

		-- Live now (Phase 4 point 3): reads/writes cfg.buttonCount
		-- directly through SetBarButtonCount on every click, no pending
		-- page-local value anymore.
		local function RefreshButtonCountStepperVisual()
			local cfg = FindCustomBarConfig(page.barId)

			if not cfg then
				return
			end

			local maxButtons = (cfg.cols or 1) * (cfg.rows or 1)
			local count = cfg.buttonCount or maxButtons

			buttonCountValueText:SetText(
				tostring(count)
			)

			if count <= 1 then
				buttonCountMinus:Disable()
			else
				buttonCountMinus:Enable()
			end

			if count >= maxButtons then
				buttonCountPlus:Disable()
			else
				buttonCountPlus:Enable()
			end
		end

		buttonCountMinus:SetScript(
			"OnClick",
			function()
				local cfg = FindCustomBarConfig(page.barId)
				local bar = BTV.bars[page.barId]

				if not cfg or not bar then
					return
				end

				local count = (cfg.buttonCount or (cfg.cols * cfg.rows)) - 1

				BTV:SetBarButtonCount(bar, count)

				RefreshButtonCountStepperVisual()
			end
		)

		buttonCountPlus:SetScript(
			"OnClick",
			function()
				local cfg = FindCustomBarConfig(page.barId)
				local bar = BTV.bars[page.barId]

				if not cfg or not bar then
					return
				end

				local count = (cfg.buttonCount or (cfg.cols * cfg.rows)) + 1

				BTV:SetBarButtonCount(bar, count)

				RefreshButtonCountStepperVisual()
			end
		)

		page.buttonCountMinus = buttonCountMinus
		page.buttonCountPlus = buttonCountPlus
		page.buttonCountValueText = buttonCountValueText
		page.RefreshButtonCountStepperVisual = RefreshButtonCountStepperVisual
	end

	-- "Delete Bar" - REMOVED (Stance/Page Bar Assignment feature, Part 1).
	-- Every non-default bar id (6-9) is now a permanent Extra Bar with a
	-- fixed lifecycle (always exists, toggled via the Enabled checkbox
	-- above) rather than a freely add/removable custom bar - there is no
	-- longer any bar this button could ever legally apply to. See
	-- Bar.lua's IsExtraBarId/SetExtraBarEnabled and Core.lua's
	-- EnsureExtraBars for the replacement lifecycle.

	-------------------------------------------------------------------------
	-- Page Indicator Scale (Main Bar only - Stance/Page Bar Assignment
	-- feature, Part 4)
	--
	-- Position is drag-only (this element's own EnsureContainerOverlay in
	-- DefaultBars.lua handles that, exactly like Bag Bar/Micro Menu/Stance
	-- Bar/Latency Bar/Key Ring) - only Scale is exposed here, mirroring
	-- every other chain-anchored container's Scale slider structure.
	-- Reuses the button-count stepper's own Y-offset formula (swatchY-
	-- derived) since that stepper never exists on bar 1 (default bars have
	-- no buttonCount concept), so this shares its vertical slot instead of
	-- needing a new one.
	--
	-- Shown/hidden live by BTV:RefreshMainBarPageIndicatorControlsVisibility
	-- (gated on BTVanillaDB.mainBarPaginationEnabled) - called both here at
	-- build time (via RefreshBarSettingsPage, right after ShowBarPage) and
	-- from the General panel's own pagination checkbox handler, so toggling
	-- that checkbox immediately shows/hides this slider even while this
	-- page is already open.
	-------------------------------------------------------------------------

	if barId == 1 then
		local pageIndicatorTitleY = swatchY - SWATCH_SIZE - 14 - 14
		local pageIndicatorSliderY = pageIndicatorTitleY - 28

		local pageIndicatorTitle = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormal"
		)

		pageIndicatorTitle:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_SECTION,
			pageIndicatorTitleY
		)

		pageIndicatorTitle:SetText("Page Indicator Scale")

		local pageIndicatorSlider = CreateSettingSlider(
			page,
			"BTVanillaMainBarPageIndicatorScaleSlider",
			290
		)

		pageIndicatorSlider:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_INPUT,
			pageIndicatorSliderY
		)

		pageIndicatorSlider:SetMinMaxValues(0.5, 2.0)
		pageIndicatorSlider:SetValueStep(0.1)

		SetSliderLabel(pageIndicatorSlider, "Scale")

		local pageIndicatorValueText = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormalSmall"
		)

		pageIndicatorValueText:SetPoint(
			"TOP",
			pageIndicatorSlider,
			"BOTTOM",
			0,
			-2
		)

		pageIndicatorValueText:SetText("1.0")

		pageIndicatorSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor((value * 10) + 0.5) / 10

				pageIndicatorValueText:SetText(
					string.format("%.1f", value)
				)

				if not this.suppressApply then
					BTV:SetPageIndicatorScale(value)
				end
			end
		)

		page.pageIndicatorTitle = pageIndicatorTitle
		page.pageIndicatorSlider = pageIndicatorSlider
		page.pageIndicatorValueText = pageIndicatorValueText

		-------------------------------------------------------------------------
		-- Stance / Page Bar Assignment (Part 2) - RELOCATED here from the
		-- General tab (bug-fix batch round 4, Issue 5): these settings are
		-- specific to bar 1's own pagination/stance-swap behavior (the two
		-- checkboxes that gate them still live on the General tab), so they
		-- belong on bar 1's own page next to its other pagination-related
		-- control (Page Indicator Scale above), not on the general panel.
		--
		-- Empty placeholder container only - BTV:RebuildMainBarAssignmentRows
		-- (Settings.lua, defined further below in this file) populates the
		-- actual rows, exactly mirroring how the old General-tab version
		-- worked: a fixed-position, dynamically-HEIGHTED container that
		-- collapses to nothing when neither stance-swap nor pagination is
		-- enabled, called from RefreshBarSettingsPage(1) below, from both
		-- checkboxes' own OnClick handlers, and from DefaultBars.lua's
		-- UPDATE_SHAPESHIFT_FORMS handler.
		-------------------------------------------------------------------------

		local assignmentContainer = CreateFrame("Frame", nil, page)

		-- Anchored straight to `page`'s own left margin, NOT to
		-- pageIndicatorValueText - that FontString only has a single
		-- "TOP" anchor point (centered under the 290px-wide slider above
		-- it, not left-aligned), so its BOTTOMLEFT sits ~215px in from
		-- the page's real left edge. Anchoring off it pushed every
		-- assignment row (and its dropdown) that same ~215px to the
		-- right, overflowing past the page's visible width entirely -
		-- the Y offset below approximates where that BOTTOMLEFT used to
		-- land (slider height 17 + value text's own -2 gap/height + the
		-- original -14 gap), just measured from `page` at the correct X.
		assignmentContainer:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_SECTION,
			pageIndicatorSliderY - 44
		)

		assignmentContainer:SetWidth(500)
		assignmentContainer:SetHeight(1)

		page.assignmentContainer = assignmentContainer
		page.assignmentRows = {}
	end

	-------------------------------------------------------------------------
	-- Hide until selected
	-------------------------------------------------------------------------

	page:Hide()

	settingsFrame.pages[barId] = page

	return page
end

-------------------------------------------------------------------------
-- Apply X/Y position live from a page's sliders
--
-- Shared by both slider OnValueChanged handlers above so the "which bar
-- kind gets which setter" branch only lives in one place.
-------------------------------------------------------------------------

function BTV:ApplyLiveBarPosition(page)
	local x = page.xSlider:GetValue()
	local y = page.ySlider:GetValue()

	if not x or not y then
		return
	end

	-- Full precision passed through untouched (Phase C point 2) - only
	-- the sliders' displayed text is rounded to 2 decimals, not the
	-- value actually written to BTVanillaDB / applied to the bar.
	if page.isDefault then
		self:SetDefaultBarPosition(page.barId, x, y)
	else
		local bar = self.bars[page.barId]

		if bar then
			self:SetBarPosition(bar, x, y)
		end
	end
end

-------------------------------------------------------------------------
-- Default-PROFILE lock (Profiles feature follow-up)
--
-- Not to be confused with ApplyDefaultLayoutGating below, which gates a
-- different, unrelated feature (the General tab's "Use Default Blizzard
-- Layout" checkbox) that happens to share the word "Default" - both gates
-- are independent and can apply to the same controls simultaneously. The
-- Default PROFILE is a fixed, always-available baseline and must never be
-- edited: every bar/simple-bar settings page shows a red warning banner
-- and has all of its interactive controls locked while it's active.
-------------------------------------------------------------------------

-- Text shown while the Default PROFILE is active - takes priority over
-- the layout-lock text below if both conditions happen to be true at
-- once (the Default profile's own restriction is the broader one).
local PROFILE_LOCK_MESSAGE_PROFILE =
	"Editing Settings is prohibited while in default profile mode. " ..
	"Go to Profile Settings and set up a profile if you wish to " ..
	"change Settings or access Layout Edit Mode."

-- Text shown while "Use Default Blizzard Layout" (General tab) is on, on
-- pages that gate ONLY applies to (bar 1 and the simple/native-backed
-- pages - see ApplyDefaultLayoutGating's own header comment).
local PROFILE_LOCK_MESSAGE_LAYOUT =
	"Editing Settings is prohibited while using the Default Blizzard " ..
	"Layout. Disable Default Blizzard Layout under General Settings " ..
	"if you wish to change Settings or access Layout Edit Mode."

-- One reusable warning banner per page - a solid strip anchored right
-- below the page's title and right above its first content control
-- (PROFILE_LOCK_BANNER_TOP/PROFILE_LOCK_BANNER_HEIGHT reserve that band
-- unconditionally, so nothing needs to reflow when this toggles). Hidden
-- by default; toggled (and its exact height/text) set by
-- ApplyProfileLockGating below - text isn't fixed at creation time since
-- which of the two messages above applies can change live.
function BTV:CreateProfileLockWarning(page)
	local banner = CreateFrame("Frame", nil, page)

	-- PARENTED to `page` (so it hides/shows along with it) but ANCHORED to
	-- contentPanel - `page` itself now slides DOWN by this banner's height
	-- only while the banner is actually shown (BTV:ApplyPageBannerReserve),
	-- and the banner has to stay put in the band that opens up rather than
	-- sliding down with it.
	banner:SetPoint("TOPLEFT", settingsFrame.contentPanel, "TOPLEFT", 0, PROFILE_LOCK_BANNER_TOP)
	banner:SetPoint("TOPRIGHT", settingsFrame.contentPanel, "TOPRIGHT", 0, PROFILE_LOCK_BANNER_TOP)
	banner:SetHeight(PROFILE_LOCK_BANNER_HEIGHT)
	banner:SetFrameLevel(page:GetFrameLevel() + 5)

	banner:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})

	banner:SetBackdropColor(0.35, 0, 0, 0.9)

	local text = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	text:SetPoint("TOPLEFT", banner, "TOPLEFT", INDENT_SECTION, -6)
	text:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -INDENT_SECTION, -6)
	text:SetJustifyH("LEFT")
	text:SetJustifyV("TOP")
	text:SetTextColor(1, 0.15, 0.15)

	banner.text = text

	banner:Hide()

	return banner
end

-- Opens up (or collapses) the band the profile-lock banner occupies, by
-- sliding the whole `page` down by the banner's height only while it's
-- actually shown - so a page with no banner doesn't leave a large empty
-- gap between its title and its first control. Same "only reserve the
-- space when the thing is actually visible" reflow the General tab's own
-- Global Spacing/ButtonSize sliders use (BTV:ReflowGeneralOverrideSliders).
--
-- Works by moving `page` rather than re-anchoring each control on it:
-- every real control is anchored to `page` with a fixed Y, so they all
-- follow it together. The two things that must NOT move - the page title
-- and the banner itself - are anchored to contentPanel instead (see
-- BTV:CreateProfileLockWarning above and each page builder's own title).
function BTV:ApplyPageBannerReserve(page, locked)
	if not page or not settingsFrame or not settingsFrame.contentPanel then
		return
	end

	local reserve = 0

	if locked then
		-- The banner's REAL height, not PROFILE_LOCK_BANNER_HEIGHT: its
		-- height is recomputed from however many lines its message actually
		-- wraps to (SetProfileLockBannerMessage, called just before this
		-- from ApplyProfileLockGating), which can exceed that constant.
		-- Falls back to the constant if it hasn't been measured yet.
		reserve = (page.profileLockWarning and page.profileLockWarning:GetHeight())
			or PROFILE_LOCK_BANNER_HEIGHT

		if reserve < PROFILE_LOCK_BANNER_HEIGHT then
			reserve = PROFILE_LOCK_BANNER_HEIGHT
		end
	end

	page:ClearAllPoints()
	page:SetPoint("TOPLEFT", settingsFrame.contentPanel, "TOPLEFT", 0, -reserve)
	page:SetPoint("BOTTOMRIGHT", settingsFrame.contentPanel, "BOTTOMRIGHT", 0, 0)
end

-- Sets the banner's message and resizes the banner to fit however many
-- lines that message actually wraps to at the page's CURRENT width
-- (text:GetHeight() reflects real wrapped height once SetText runs, same
-- content-aware-sizing technique UIWidgets.lua's dialog uses) - so a
-- longer message, a narrower window, or a translation never gets cut off
-- rather than just being clamped to PROFILE_LOCK_BANNER_HEIGHT's own
-- (generous, but not guaranteed-sufficient) reserved space.
local function SetProfileLockBannerMessage(banner, message)
	-- Explicit SetWidth on BOTH banner and text, computed from `page`'s
	-- own (reliable, always-explicitly-set) current width - banner/text
	-- previously relied purely on their TOPLEFT+TOPRIGHT anchor pairs to
	-- imply their width, which live-tested as NOT reliably wrapping text
	-- at all (rendered as one long line, clipped by the ancestor
	-- scrollframe rather than wrapping) - explicit SetWidth is the one
	-- thing that's proven reliable for width in this environment
	-- throughout this whole settings-window rework.
	local page = banner:GetParent()
	local width = page:GetWidth()

	if width and width > 0 then
		banner:SetWidth(width)
		banner.text:SetWidth(width - (2 * INDENT_SECTION))
	end

	banner.text:SetText(message)
	banner:SetHeight((banner.text:GetHeight() or 0) + 12)
end

local function LockControl(control, locked)
	control:EnableMouse(not locked)
	control:SetAlpha(locked and 0.5 or 1)

	-- Templated Buttons additionally need :Disable()/:Enable() -
	-- EnableMouse alone doesn't grey them out or block their OnClick the
	-- way it does for sliders/template-less swatch buttons.
	if control.Disable and control.Enable then
		if locked then
			control:Disable()
		else
			control:Enable()
		end
	end
end

-- Every optional widget name either a full bar page (GetOrCreateBarPage)
-- or a simple bar page (CreateSimpleBarPage, including its Experience
-- Bar-only extras) can have on itself. Checked by presence so the same
-- list works for both page shapes. enableCheckbox IS locked like
-- everything else here by default - it's only exempted, inline below,
-- for the numbered default bars (1-5), where the user wants
-- enable/disable to stay the one available option even while everything
-- else on the page is locked.
local PROFILE_LOCK_CONTROL_NAMES = {
	"xSlider", "ySlider", "buttonSizeSlider", "spacingSlider",
	"scaleSlider", "resetPositionButton", "enableCheckbox",
	"buttonCountMinus", "buttonCountPlus", "pageIndicatorSlider",
	"orientationCheckbox", "keyRingCheckbox", "keyRingScaleSlider",
	"betterExpBarCheckbox", "expBarShowLevelCheckbox",
	"expBarShowCurrentOverMaxCheckbox", "expBarShowPercentCheckbox",
	"expBarShowRestedPercentCheckbox", "expBarShowRestedTotalCheckbox",
	"expBarFontSizeSlider", "earnedColorSwatch", "restedColorSwatch",
	"expBarTextColorSwatch", "expBarGlowPulseIntervalSlider",
}

-- alsoCheckLayoutLock: true on the pages the Default-layout lock also
-- applies to (bar 1's page, every simple/native-backed page) - the
-- banner shows for THAT lock too there, with its own message, and the
-- SAME combined lock now drives control-locking below too (user
-- decision: while EITHER lock is active, enable/disable is the only
-- thing that should stay available on a numbered default bar - every
-- other control locks the same way under either reason).
function BTV:ApplyProfileLockGating(page, alsoCheckLayoutLock)
	local profileLocked = self:IsDefaultProfileActive()
	local layoutLocked = alsoCheckLayoutLock and (BTVanillaDB.useDefaultLayout == true)
	local locked = profileLocked or layoutLocked

	if page.profileLockWarning then
		page.profileLockWarning:SetShown(locked)

		if locked then
			SetProfileLockBannerMessage(
				page.profileLockWarning,
				profileLocked and PROFILE_LOCK_MESSAGE_PROFILE or PROFILE_LOCK_MESSAGE_LAYOUT
			)
		end
	end

	-- Opens up the banner's band only while it's actually shown, instead
	-- of every page permanently reserving it.
	BTV:ApplyPageBannerReserve(page, locked)

	-- Numbered default bars (1-5) keep enable/disable available even
	-- while everything else locks - every other page (extra bars 6-9,
	-- simple/native-backed pages) has NO exemption, its enable checkbox
	-- locks exactly like every other control.
	local barId = page.barId
	local isNumberedDefaultBar = type(barId) == "number" and barId >= 1 and barId <= 5

	local i

	for i = 1, table.getn(PROFILE_LOCK_CONTROL_NAMES) do
		local name = PROFILE_LOCK_CONTROL_NAMES[i]
		local control = page[name]

		if control then
			local exempt = isNumberedDefaultBar and name == "enableCheckbox"

			LockControl(control, locked and not exempt)
		end
	end

	if page.gridSwatches then
		for i = 1, table.getn(page.gridSwatches) do
			LockControl(page.gridSwatches[i], locked)
		end
	end

	if page.assignmentRows then
		for i = 1, table.getn(page.assignmentRows) do
			local row = page.assignmentRows[i]

			if row.dropdown then
				-- EnableMouse(false) on the dropdown frame itself doesn't
				-- block its click handling - UIDropDownMenuTemplate's own
				-- clickable region is a separate child Button
				-- ("<name>Button", native FrameXML naming convention),
				-- which needs :Disable()/:Enable() directly.
				local dropdownButton = getglobal(row.dropdown:GetName() .. "Button")

				if dropdownButton then
					LockControl(dropdownButton, locked)
				else
					LockControl(row.dropdown, locked)
				end
			end
		end
	end
end

-------------------------------------------------------------------------
-- Default-layout gating (General tab's "Use Default Blizzard Layout")
--
-- EnableMouse(false) is used rather than Slider/Button-specific
-- Enable()/Disable() calls: it's a universal Frame method guaranteed to
-- work on every widget type touched here (sliders AND the plain,
-- template-less grid swatch buttons), whereas Disable() only reliably
-- changes appearance/behavior on templated Button widgets. Controls stay
-- visible and keep showing their current value either way (point 3 of
-- the spec) - only interactivity is gated. Only simple/native-backed
-- pages (Stance/Bag/Micro/Latency/Exp Bar) call this now - numbered
-- default bars (1-5) get the SAME layout-lock effect through
-- BTV:ApplyProfileLockGating's own combined lock instead (its
-- alsoCheckLayoutLock parameter), which also exempts their enable
-- checkbox; custom bars' pages never have either applied, so they're
-- always fully interactive regardless of BTVanillaDB.useDefaultLayout.
-------------------------------------------------------------------------

local function ApplyDefaultLayoutGating(page, interactive)
	local alpha = interactive and 1 or 0.5

	if page.xSlider then
		page.xSlider:EnableMouse(interactive)
		page.xSlider:SetAlpha(alpha)
	end

	if page.ySlider then
		page.ySlider:EnableMouse(interactive)
		page.ySlider:SetAlpha(alpha)
	end

	if page.buttonSizeSlider then
		page.buttonSizeSlider:EnableMouse(interactive)
		page.buttonSizeSlider:SetAlpha(alpha)
	end

	if page.spacingSlider then
		page.spacingSlider:EnableMouse(interactive)
		page.spacingSlider:SetAlpha(alpha)
	end

	if page.gridSwatches then
		local i

		for i = 1, table.getn(page.gridSwatches) do
			local swatch = page.gridSwatches[i]

			swatch:EnableMouse(interactive)
			swatch:SetAlpha(alpha)
		end
	end
end

-- Re-applies gating to every currently-built default-bar page (1-5) -
-- called whenever the General tab's checkbox changes, so any page
-- already open/cached updates immediately without needing to close and
-- reopen Settings.
function BTV:RefreshDefaultLayoutGatingOnAllPages()
	if not settingsFrame then
		return
	end

	local id

	for id = 1, 5 do
		if settingsFrame.pages[id] then
			self:RefreshBarSettingsPage(id)
		end
	end

	-- Stance Bar / Bag Bar / Micro Menu / Latency Bar / Experience Bar
	-- (features 2/3, round 16 part 2) are also gated on useDefaultLayout
	-- (RefreshSimpleBarPage below), so their pages need the same live
	-- refresh if already built/cached.
	local specialKeys = { "stance", "bagbar", "micromenu", "latencybar", "expbar" }
	local si

	for si = 1, table.getn(specialKeys) do
		if settingsFrame.pages[specialKeys[si]] then
			self:RefreshBarSettingsPage(specialKeys[si])
		end
	end
end

-------------------------------------------------------------------------
-- Experience Bar page-only helpers (round 17, items 3-5)
--
-- Declared here (real Lua 5.0 locals, ahead of CreateSimpleBarPage's own
-- definition below) rather than inline in the "expbar"-only block inside
-- it, since Lua 5.0 has no forward-declaration/hoisting for local
-- functions - a local must exist before whatever references it.
-------------------------------------------------------------------------

-- A small clickable color swatch: a bordered square button (same
-- backdrop/insets convention CreateGridSwatch above already uses) with a
-- solid WHITE8X8 texture inside that gets tinted to whatever color it
-- currently represents.
local function CreateColorSwatchButton(parent, name)
	local swatch = CreateFrame("Button", name, parent)

	swatch:SetWidth(24)
	swatch:SetHeight(24)

	swatch:SetBackdrop({
		bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = {
			left = 1,
			right = 1,
			top = 1,
			bottom = 1
		},
	})

	swatch:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

	local tex = swatch:CreateTexture(nil, "ARTWORK")

	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetPoint("TOPLEFT", swatch, "TOPLEFT", 2, -2)
	tex:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", -2, 2)

	swatch.colorTexture = tex

	return swatch
end

local function SetColorSwatchColor(swatch, color)
	if not swatch or not swatch.colorTexture or not color then
		return
	end

	swatch.colorTexture:SetVertexColor(color.r or 1, color.g or 1, color.b or 1)
end

-- Opens vanilla's standard native ColorPickerFrame, wired to `getter`
-- (BTVanillaDB.expBarColorEarned/expBarColorRested) for the initial value
-- and `setter` (BTV:SetExpBarColorEarned/SetExpBarColorRested) for both
-- live-drag updates (func) and Cancel (cancelFunc, restoring whatever was
-- active before the picker opened) - the well-documented vanilla 1.12
-- ColorPickerFrame API (SetColorRGB/func/opacityFunc/cancelFunc/
-- hasOpacity), not a modern/Classic-only equivalent. `swatch` is kept in
-- sync live too, so the button's own color always reflects the current
-- value without needing to close/reopen the settings page.
local function OpenExpBarColorPicker(swatch, getter, setter)
	local current = getter() or { r = 1, g = 1, b = 1 }

	ColorPickerFrame.func = function()
		local r, g, b = ColorPickerFrame:GetColorRGB()

		setter(r, g, b)
		SetColorSwatchColor(swatch, getter())
	end

	-- hasOpacity = false (round 17 item 3 - bar-fill colors have no
	-- meaningful separate alpha channel here), but opacityFunc is still
	-- assigned defensively to a no-op per ColorPickerFrame's documented
	-- field set, in case the client ever calls it regardless.
	ColorPickerFrame.opacityFunc = function() end
	ColorPickerFrame.hasOpacity = false

	ColorPickerFrame.cancelFunc = function(previousValues)
		if previousValues then
			setter(previousValues.r, previousValues.g, previousValues.b)
			SetColorSwatchColor(swatch, getter())
		end
	end

	ColorPickerFrame:SetColorRGB(current.r, current.g, current.b)

	-- Round 18 Bug 4 fix: anchor the native picker right next to this
	-- addon's own Settings window instead of wherever it last was/centered
	-- on screen, so the user never has to manually drag the Settings window
	-- out of the way to see it. `settingsFrame` (this file's own module
	-- local, set once by CreateSettingsFrame) is guaranteed non-nil here -
	-- this function is only ever reachable by clicking a swatch on an
	-- already-open Experience Bar settings page.
	ColorPickerFrame:ClearAllPoints()
	ColorPickerFrame:SetPoint("TOPLEFT", settingsFrame, "TOPRIGHT", 10, 0)

	-- CreateSettingsFrame pins the Settings window itself to "DIALOG"
	-- strata. "FULLSCREEN_DIALOG" is the next tier up in this client's
	-- fixed FRAME_STRATA ordering (BACKGROUND < LOW < MEDIUM < HIGH <
	-- DIALOG < FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP - a stock client
	-- enum, not something any of this addon's four mods change), which
	-- guarantees the picker renders above the Settings window regardless of
	-- whatever strata ColorPickerFrame's own native FrameXML definition
	-- already uses - no need to guess/check its prior value first.
	ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")

	ShowUIPanel(ColorPickerFrame)
end

-- One row: a label + a 24x24 CheckButton for one of the 5 independently
-- toggleable text segments (round 17 item 4). Returns the checkbox so the
-- caller can stash it on `page` for RefreshSimpleBarPage/gating.
local function CreateExpBarTextToggleCheckbox(page, name, labelText, y, dbKey)
	local checkbox = CreateFrame(
		"CheckButton",
		"BTVanillaSimplePageExpBar" .. name .. "Checkbox",
		page,
		"UICheckButtonTemplate"
	)

	checkbox:SetWidth(24)
	checkbox:SetHeight(24)

	checkbox:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, y)

	checkbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false

			BTVanillaDB[dbKey] = checked

			BTV:ApplyBetterExpBarVisual()
		end
	)

	local label = getglobal(checkbox:GetName() .. "Text")

	if label then
		label:SetText(labelText)
	end

	return checkbox
end

-- Gates the 5 text-toggle checkboxes + Font Size slider + 3 color
-- swatches + Reset Colors button + Pulse Interval slider on whether
-- "Enable Better Experience Bar" is currently checked - these sub-controls
-- are meaningless while that's off, same EnableMouse(false)+SetAlpha(0.5)
-- treatment ApplyDefaultLayoutGating uses above (controls stay visible,
-- showing their current value, just not interactive) rather than hiding
-- them outright. Round 22 items 2/3/4 added the Font Size slider and the
-- Overlay Text Color swatch to this same list; round 31 item 2 added the
-- Pulse Interval slider - genuinely meaningless while the feature is off,
-- since the rested-glow pulse it controls only ever runs while the rested
-- tick/glow itself is shown, which is itself gated on this same checkbox
-- (BTV:ApplyExpBarRestedOverlay's own `not BTVanillaDB.betterExpBarEnabled`
-- early-return, DefaultBars.lua).
local function ApplyBetterExpBarGating(page)
	if not page or not page.betterExpBarCheckbox then
		return
	end

	local interactive = page.betterExpBarCheckbox:GetChecked() and true or false
	local alpha = interactive and 1 or 0.5

	local controls = {
		page.expBarShowLevelCheckbox,
		page.expBarShowCurrentOverMaxCheckbox,
		page.expBarShowPercentCheckbox,
		page.expBarShowRestedPercentCheckbox,
		page.expBarShowRestedTotalCheckbox,
		page.expBarFontSizeSlider,
		page.earnedColorSwatch,
		page.restedColorSwatch,
		page.expBarTextColorSwatch,
		page.resetColorsButton,
		page.expBarGlowPulseIntervalSlider,
	}

	local i

	for i = 1, table.getn(controls) do
		local control = controls[i]

		if control then
			control:EnableMouse(interactive)
			control:SetAlpha(alpha)
		end
	end
end

-------------------------------------------------------------------------
-- Simple bar pages (Stance Bar / Bag Bar / Micro Menu, features 2/3)
--
-- Shares one builder, parameterized via simpleBarPageConfigs, rather than
-- three near-identical page builders - Position (X/Y sliders, live) +
-- an optional Enable checkbox (Bag Bar/Micro Menu only - the Stance
-- Bar's shape/button-count is native, class/talent-driven, so it has no
-- meaningful enable/disable) + a "Reset to Blizzard Default" button.
-- Deliberately has NO grid/spacing/button-size/buttonCount/Delete
-- controls at all - none of these three elements is a TrustyBars-owned
-- button grid the way default bars (1-5) or custom bars (6+) are.
-------------------------------------------------------------------------

local function CreateSimpleBarPage(key)
	local config = simpleBarPageConfigs[key]

	if not config then
		return nil
	end

	local page = CreateFrame(
		"Frame",
		nil,
		settingsFrame.contentPanel
	)

	-- Same banner-reserve handling as GetOrCreateBarPage above.
	BTV:ApplyPageBannerReserve(page, false)

	page.barId = key
	page.isDefault = true

	page.profileLockWarning = BTV:CreateProfileLockWarning(page)

	local title = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalLarge"
	)

	-- Anchored to contentPanel, not `page` - stays put while the page
	-- slides down for the banner (BTV:ApplyPageBannerReserve).
	title:SetPoint(
		"TOPLEFT",
		settingsFrame.contentPanel,
		"TOPLEFT",
		INDENT_SECTION,
		-14
	)

	title:SetText(config.title .. " Settings (Default)")

	-- No unconditional banner reserve - see GetOrCreateBarPage's own
	-- contentTopOffset comment.
	local contentTopOffset = 0
	local enableCheckboxY = -44 + contentTopOffset

	local topY = -46 + contentTopOffset

	if config.hasEnable then
		local enableCheckbox = CreateFrame(
			"CheckButton",
			"BTVanillaSimplePage" .. key .. "EnableCheckbox",
			page,
			"UICheckButtonTemplate"
		)

		enableCheckbox:SetWidth(24)
		enableCheckbox:SetHeight(24)

		enableCheckbox:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			INDENT_SECTION,
			enableCheckboxY
		)

		enableCheckbox:SetScript(
			"OnClick",
			function()
				local checked = this:GetChecked() and true or false

				config.setEnabled(checked)

				BTV:RefreshBarList()
			end
		)

		local enableLabel = getglobal(enableCheckbox:GetName() .. "Text")

		if enableLabel then
			enableLabel:SetText("Enabled")
		end

		page.enableCheckbox = enableCheckbox

		topY = enableCheckboxY - 24 - 14
	end

	local minX, maxX, minY, maxY = GetScreenCoordinateRange()

	local xLabelY = topY
	local xSliderY = xLabelY + 4
	local yLabelY = xSliderY - 40
	local ySliderY = yLabelY + 4

	-------------------------------------------------------------------------
	-- X slider
	-------------------------------------------------------------------------

	local xLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	xLabel:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_CONTROL, xLabelY)
	xLabel:SetText("X")

	local xSlider = CreateSettingSlider(
		page,
		"BTVanillaSimplePage" .. key .. "XSlider",
		290
	)

	xSlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, xSliderY)
	xSlider:SetMinMaxValues(minX, maxX)
	xSlider:SetValueStep(1)

	SetSliderLabel(xSlider, "X")

	local xValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	xValueText:SetPoint("TOP", xSlider, "BOTTOM", 0, -2)
	xValueText:SetText(string.format("%.2f", 0))

	page.xValueText = xValueText

	xSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			xValueText:SetText(string.format("%.2f", value))

			if not this.suppressApply then
				local y = page.ySlider:GetValue()

				config.setPosition(value, y)
			end
		end
	)

	page.xSlider = xSlider

	-------------------------------------------------------------------------
	-- Y slider
	-------------------------------------------------------------------------

	local yLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	yLabel:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_CONTROL, yLabelY)
	yLabel:SetText("Y")

	local ySlider = CreateSettingSlider(
		page,
		"BTVanillaSimplePage" .. key .. "YSlider",
		290
	)

	ySlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, ySliderY)
	ySlider:SetMinMaxValues(minY, maxY)
	ySlider:SetValueStep(1)

	SetSliderLabel(ySlider, "Y")

	local yValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	yValueText:SetPoint("TOP", ySlider, "BOTTOM", 0, -2)
	yValueText:SetText(string.format("%.2f", 0))

	page.yValueText = yValueText

	ySlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			yValueText:SetText(string.format("%.2f", value))

			if not this.suppressApply then
				local x = page.xSlider:GetValue()

				config.setPosition(x, value)
			end
		end
	)

	page.ySlider = ySlider

	-- Cursor for whichever of Spacing/Scale/Orientation this element
	-- actually has (bug-fix batch Fix 4) - cascades exactly like
	-- CreateBarPage's own section-to-section deltas (36px title gap, 26px
	-- title-to-slider gap), so the Reset button (and the window's own
	-- dynamic height-fit, FitSettingsWindowToBarPage) always lands
	-- correctly below however many of these three optional sections this
	-- config actually enables.
	local cursorY = ySliderY - 36

	-------------------------------------------------------------------------
	-- Spacing (Bag Bar/Micro Menu only - config.hasSpacing) - reuses the
	-- default-bar page's own Spacing slider block structure/styling
	-- exactly (title, slider, live value label, min/max end labels).
	-------------------------------------------------------------------------

	if config.hasSpacing then
		-- (v1.0 polish pass) config.spacingMin lets one element override the
		-- shared SPACING_MIN floor - Micro Menu sets this to -10 so users can
		-- pull its native buttons into a slight overlap, compensating for
		-- padding baked into their own art that a spacing of 0 (their
		-- measured native gap) doesn't remove. Every other hasSpacing
		-- element (Bag Bar, Stance Bar) has no override and keeps the
		-- original SPACING_MIN (0) floor.
		local spacingMin = config.spacingMin or SPACING_MIN

		local spacingTitleY = cursorY
		local spacingSliderY = spacingTitleY - 26

		local spacingTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		spacingTitle:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, spacingTitleY)
		spacingTitle:SetText(
			"Spacing (" .. tostring(spacingMin) .. " to " .. tostring(SPACING_MAX) .. ")"
		)

		local spacingSlider = CreateSettingSlider(
			page,
			"BTVanillaSimplePage" .. key .. "SpacingSlider",
			290
		)

		spacingSlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, spacingSliderY)
		spacingSlider:SetMinMaxValues(spacingMin, SPACING_MAX)
		spacingSlider:SetValueStep(SPACING_STEP)

		SetSliderLabel(spacingSlider, "Spacing")

		local spacingSliderLow = getglobal(spacingSlider:GetName() .. "Low")

		if spacingSliderLow then
			spacingSliderLow:SetText(tostring(spacingMin))
		end

		local spacingSliderHigh = getglobal(spacingSlider:GetName() .. "High")

		if spacingSliderHigh then
			spacingSliderHigh:SetText(tostring(SPACING_MAX))
		end

		local spacingValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		spacingValueText:SetPoint("TOP", spacingSlider, "BOTTOM", 0, -2)
		spacingValueText:SetText("0")

		page.spacingValueText = spacingValueText

		spacingSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor(value + 0.5)

				spacingValueText:SetText(tostring(value))

				if not this.suppressApply then
					config.setSpacing(value)
				end
			end
		)

		page.spacingSlider = spacingSlider

		cursorY = spacingSliderY - 36
	end

	-------------------------------------------------------------------------
	-- Scale (all three simple pages that have one - config.hasScale). Range
	-- 0.5 to 2.0, step 0.1 - a proportional container/frame SetScale, not a
	-- pixel quantity, so the live value label shows one decimal place
	-- rather than an integer.
	-------------------------------------------------------------------------

	if config.hasScale then
		local scaleTitleY = cursorY
		local scaleSliderY = scaleTitleY - 26

		local scaleTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		scaleTitle:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, scaleTitleY)
		scaleTitle:SetText("Scale (0.5 to 2.0)")

		local scaleSlider = CreateSettingSlider(
			page,
			"BTVanillaSimplePage" .. key .. "ScaleSlider",
			290
		)

		scaleSlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, scaleSliderY)
		scaleSlider:SetMinMaxValues(0.5, 2.0)
		scaleSlider:SetValueStep(0.1)

		SetSliderLabel(scaleSlider, "Scale")

		local scaleSliderLow = getglobal(scaleSlider:GetName() .. "Low")

		if scaleSliderLow then
			scaleSliderLow:SetText("0.5")
		end

		local scaleSliderHigh = getglobal(scaleSlider:GetName() .. "High")

		if scaleSliderHigh then
			scaleSliderHigh:SetText("2.0")
		end

		local scaleValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		scaleValueText:SetPoint("TOP", scaleSlider, "BOTTOM", 0, -2)
		scaleValueText:SetText("1.0")

		page.scaleValueText = scaleValueText

		scaleSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor((value * 10) + 0.5) / 10

				scaleValueText:SetText(string.format("%.1f", value))

				if not this.suppressApply then
					config.setScale(value)
				end
			end
		)

		page.scaleSlider = scaleSlider

		cursorY = scaleSliderY - 36
	end

	-------------------------------------------------------------------------
	-- Orientation (Bag Bar/Micro Menu only - config.hasOrientation). A
	-- simple "Vertical Layout" checkbox rather than the 6-preset grid
	-- swatch picker real bars use - these clusters have a fixed button
	-- count and only two possible layouts (horizontal/vertical), so a
	-- checkbox is the right control here.
	-------------------------------------------------------------------------

	if config.hasOrientation then
		local orientationCheckbox = CreateFrame(
			"CheckButton",
			"BTVanillaSimplePage" .. key .. "OrientationCheckbox",
			page,
			"UICheckButtonTemplate"
		)

		orientationCheckbox:SetWidth(24)
		orientationCheckbox:SetHeight(24)

		orientationCheckbox:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, cursorY)

		orientationCheckbox:SetScript(
			"OnClick",
			function()
				local checked = this:GetChecked() and true or false

				config.setOrientation(checked)
			end
		)

		local orientationLabel = getglobal(orientationCheckbox:GetName() .. "Text")

		if orientationLabel then
			orientationLabel:SetText("Vertical Layout")
		end

		page.orientationCheckbox = orientationCheckbox

		cursorY = cursorY - 24 - 14
	end

	-------------------------------------------------------------------------
	-- "Better Experience Bar" + its 5 text toggles + 2 bar-fill color
	-- pickers (round 17, items 3-5) - Experience Bar page only. Relocated
	-- off the General tab (item 5): grouped here as this feature's own
	-- settings home instead of scattered across General. Deliberately
	-- independent of the "Enabled" checkbox further up this function
	-- (config.hasEnable, the container's own Position/Scale/Enable/Reset) -
	-- BTVanillaDB.betterExpBarEnabled only ever governed the text overlay,
	-- never the container's own movability, per this feature's own spec.
	-------------------------------------------------------------------------

	if key == "expbar" then
		local betterExpBarCheckbox = CreateFrame(
			"CheckButton",
			"BTVanillaSimplePageExpBarBetterCheckbox",
			page,
			"UICheckButtonTemplate"
		)

		betterExpBarCheckbox:SetWidth(24)
		betterExpBarCheckbox:SetHeight(24)

		betterExpBarCheckbox:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, cursorY)

		betterExpBarCheckbox:SetScript(
			"OnClick",
			function()
				local checked = this:GetChecked() and true or false

				BTVanillaDB.betterExpBarEnabled = checked

				BTV:ApplyBetterExpBarVisual()

				-- Round 18 Bug 1 fix: this call site was previously missing
				-- entirely - toggling the feature ON never applied whatever
				-- color (custom or default) was already saved in
				-- BTVanillaDB.expBarColorEarned/Rested, leaving the bar
				-- looking native until the user separately touched a color
				-- picker or the Reset Colors button. BTV:ApplyExpBarColors
				-- now internally gates on betterExpBarEnabled itself, so this
				-- is safe to call unconditionally here too - it applies the
				-- saved color when turning the feature on, and does nothing
				-- when turning it off (leaving native colors untouched).
				BTV:ApplyExpBarColors()

				ApplyBetterExpBarGating(page)
			end
		)

		local betterExpBarLabel = getglobal(betterExpBarCheckbox:GetName() .. "Text")

		if betterExpBarLabel then
			betterExpBarLabel:SetText("Enable Better Experience Bar")
		end

		page.betterExpBarCheckbox = betterExpBarCheckbox

		local betterExpBarDescription = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

		betterExpBarDescription:SetPoint("TOPLEFT", betterExpBarCheckbox, "BOTTOMLEFT", 4, -6)
		betterExpBarDescription:SetWidth(440)
		betterExpBarDescription:SetJustifyH("LEFT")

		betterExpBarDescription:SetText(
			"Replaces the native percent label with a customizable text " ..
			"line, and lets you recolor the bar's own fill and rested-" ..
			"bonus fill below."
		)

		page.betterExpBarDescription = betterExpBarDescription

		-- Fixed vertical budget for the checkbox+description pair above
		-- (24px checkbox, up to 2 wrapped lines of GameFontHighlightSmall)
		-- rather than an anchor-chained follow-up section - this function
		-- positions every other control here via computed cursorY math, and
		-- the description text above is short/width-bounded enough to
		-- reliably stay within 2 lines, so a generous fixed offset is
		-- simpler than switching this one section to real-anchor-chaining
		-- (the General tab's own approach, only needed there because ITS
		-- description text length isn't controlled/bounded the same way).
		cursorY = cursorY - 24 - 6 - 24 - 14

		-------------------------------------------------------------------------
		-- Overlay Text Size slider (round 22 item 2) - directly below the
		-- "Enable Better Experience Bar" checkbox/description above. Range/
		-- step (FONT_SIZE_MIN/MAX/STEP) and ClampFontSize match this file's
		-- only other font-size controls, the General panel's Hotkey/Count
		-- Text Size sliders - not a new convention. Layout (title/slider/
		-- value-text via this page's own cursorY tracking, no separate
		-- Reset button) mirrors the Key Ring Scale slider further below in
		-- this same function instead, since that already lives in this
		-- exact page-builder idiom rather than the General panel's
		-- different chain-anchor one.
		-------------------------------------------------------------------------

		local fontSizeTitleY = cursorY
		local fontSizeSliderY = fontSizeTitleY - 26

		local fontSizeTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		fontSizeTitle:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, fontSizeTitleY)
		fontSizeTitle:SetText(
			"Overlay Text Size (" .. tostring(FONT_SIZE_MIN) ..
			" to " .. tostring(FONT_SIZE_MAX) .. ")"
		)

		local fontSizeSlider = CreateSettingSlider(
			page,
			"BTVanillaSimplePageExpBarFontSizeSlider",
			290
		)

		fontSizeSlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, fontSizeSliderY)
		fontSizeSlider:SetMinMaxValues(FONT_SIZE_MIN, FONT_SIZE_MAX)
		fontSizeSlider:SetValueStep(FONT_SIZE_STEP)

		SetSliderLabel(fontSizeSlider, "Overlay Text Size")

		local fontSizeSliderLow = getglobal(fontSizeSlider:GetName() .. "Low")

		if fontSizeSliderLow then
			fontSizeSliderLow:SetText(tostring(FONT_SIZE_MIN))
		end

		local fontSizeSliderHigh = getglobal(fontSizeSlider:GetName() .. "High")

		if fontSizeSliderHigh then
			fontSizeSliderHigh:SetText(tostring(FONT_SIZE_MAX))
		end

		local fontSizeValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		fontSizeValueText:SetPoint("TOP", fontSizeSlider, "BOTTOM", 0, -2)

		-- Placeholder only - RefreshSimpleBarPage overwrites this with the
		-- real saved/native value before this page is ever visible.
		fontSizeValueText:SetText(tostring(FONT_SIZE_MIN))

		page.expBarFontSizeValueText = fontSizeValueText

		fontSizeSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor(value + 0.5)

				fontSizeValueText:SetText(tostring(value))

				if not this.suppressApply then
					BTV:SetExpBarFontSize(value)
				end
			end
		)

		page.expBarFontSizeSlider = fontSizeSlider

		cursorY = fontSizeSliderY - 36

		-------------------------------------------------------------------------
		-- 5 text-segment toggles (item 4)
		-------------------------------------------------------------------------

		local showLevelCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowLevel", "Show Current Lvl", cursorY, "expBarShowLevel"
		)
		page.expBarShowLevelCheckbox = showLevelCheckbox
		cursorY = cursorY - 24 - 6

		local showCurrentOverMaxCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowCurrentOverMax", "Show Current XP / Max", cursorY, "expBarShowCurrentOverMax"
		)
		page.expBarShowCurrentOverMaxCheckbox = showCurrentOverMaxCheckbox
		cursorY = cursorY - 24 - 6

		local showPercentCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowPercent", "Show Current % / Max", cursorY, "expBarShowPercent"
		)
		page.expBarShowPercentCheckbox = showPercentCheckbox
		cursorY = cursorY - 24 - 6

		local showRestedPercentCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowRestedPercent", "Show Current Rested XP %", cursorY, "expBarShowRestedPercent"
		)
		page.expBarShowRestedPercentCheckbox = showRestedPercentCheckbox
		cursorY = cursorY - 24 - 6

		local showRestedTotalCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowRestedTotal", "Show Current Total Rested XP", cursorY, "expBarShowRestedTotal"
		)
		page.expBarShowRestedTotalCheckbox = showRestedTotalCheckbox
		cursorY = cursorY - 24 - 18

		-------------------------------------------------------------------------
		-- 2 bar-fill color pickers (item 3)
		-------------------------------------------------------------------------

		local earnedColorLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		earnedColorLabel:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_CONTROL, cursorY)
		earnedColorLabel:SetText("Earned XP Bar Color")

		local earnedColorSwatch = CreateColorSwatchButton(
			page, "BTVanillaSimplePageExpBarEarnedColorSwatch"
		)

		earnedColorSwatch:SetPoint("LEFT", earnedColorLabel, "RIGHT", 12, 0)

		earnedColorSwatch:SetScript(
			"OnClick",
			function()
				OpenExpBarColorPicker(
					earnedColorSwatch,
					function() return BTVanillaDB.expBarColorEarned end,
					function(r, g, b) BTV:SetExpBarColorEarned(r, g, b) end
				)
			end
		)

		page.earnedColorSwatch = earnedColorSwatch

		cursorY = cursorY - 24 - 14

		local restedColorLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		restedColorLabel:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_CONTROL, cursorY)
		restedColorLabel:SetText("Rested XP Bar Color")

		local restedColorSwatch = CreateColorSwatchButton(
			page, "BTVanillaSimplePageExpBarRestedColorSwatch"
		)

		restedColorSwatch:SetPoint("LEFT", restedColorLabel, "RIGHT", 12, 0)

		restedColorSwatch:SetScript(
			"OnClick",
			function()
				OpenExpBarColorPicker(
					restedColorSwatch,
					function() return BTVanillaDB.expBarColorRested end,
					function(r, g, b) BTV:SetExpBarColorRested(r, g, b) end
				)
			end
		)

		page.restedColorSwatch = restedColorSwatch

		cursorY = cursorY - 24 - 14

		-------------------------------------------------------------------------
		-- Overlay Text Color swatch (round 22 item 3) - directly below the
		-- Rested XP Bar Color picker above. Reuses the EXACT SAME
		-- CreateColorSwatchButton/OpenExpBarColorPicker mechanic as the two
		-- bar-fill color pickers above, just wired to
		-- BTVanillaDB.expBarTextColor/BTV:SetExpBarTextColor instead of a
		-- bar-fill color - OpenExpBarColorPicker is already a generic
		-- getter/setter-driven helper despite its name (see its own
		-- comment), not something specific to the two bar-fill pickers.
		-------------------------------------------------------------------------

		local textColorLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		textColorLabel:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_CONTROL, cursorY)
		textColorLabel:SetText("Overlay Text Color")

		local textColorSwatch = CreateColorSwatchButton(
			page, "BTVanillaSimplePageExpBarTextColorSwatch"
		)

		textColorSwatch:SetPoint("LEFT", textColorLabel, "RIGHT", 12, 0)

		textColorSwatch:SetScript(
			"OnClick",
			function()
				OpenExpBarColorPicker(
					textColorSwatch,
					function() return BTVanillaDB.expBarTextColor end,
					function(r, g, b) BTV:SetExpBarTextColor(r, g, b) end
				)
			end
		)

		page.expBarTextColorSwatch = textColorSwatch

		cursorY = cursorY - 24 - 14

		local resetColorsButton = CreateFrame(
			"Button",
			nil,
			page
		)

		resetColorsButton:SetHeight(22)

		resetColorsButton:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, cursorY)
		BTV:StyleModernButton(resetColorsButton, 200, 200)
		resetColorsButton:SetText("Reset Colors to Default")

		resetColorsButton:SetScript(
			"OnClick",
			function()
				BTV:ResetExpBarColors()

				BTV:RefreshBarSettingsPage("expbar")
			end
		)

		page.resetColorsButton = resetColorsButton

		cursorY = cursorY - 22 - 26

		-------------------------------------------------------------------------
		-- Rested Glow Pulse Interval slider (round 31 item 2) - directly below
		-- the Reset Colors button above. Layout/step mirrors the Overlay Text
		-- Size slider above (title/slider/value-text via this page's own
		-- cursorY tracking) rather than the shared config.hasScale block
		-- further up this function, since this is a Better-Experience-Bar-only
		-- sub-control (gated by ApplyBetterExpBarGating below, not
		-- config-driven). Range/step (0.5 to 5.0 seconds, step 0.1) matches
		-- how granular the Key Ring Scale slider elsewhere on this page's
		-- sibling pages already is - fine enough to dial in a "roughly
		-- 1-2 second" pulse precisely without an impractically long slider
		-- track.
		-------------------------------------------------------------------------

		local pulseIntervalTitleY = cursorY
		local pulseIntervalSliderY = pulseIntervalTitleY - 26

		local pulseIntervalTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		pulseIntervalTitle:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, pulseIntervalTitleY)
		pulseIntervalTitle:SetText("Rested Glow Pulse Interval (0.5 to 5.0 sec)")

		local pulseIntervalSlider = CreateSettingSlider(
			page,
			"BTVanillaSimplePageExpBarPulseIntervalSlider",
			290
		)

		pulseIntervalSlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, pulseIntervalSliderY)
		pulseIntervalSlider:SetMinMaxValues(0.5, 5.0)
		pulseIntervalSlider:SetValueStep(0.1)

		SetSliderLabel(pulseIntervalSlider, "Pulse Interval")

		local pulseIntervalSliderLow = getglobal(pulseIntervalSlider:GetName() .. "Low")

		if pulseIntervalSliderLow then
			pulseIntervalSliderLow:SetText("0.5")
		end

		local pulseIntervalSliderHigh = getglobal(pulseIntervalSlider:GetName() .. "High")

		if pulseIntervalSliderHigh then
			pulseIntervalSliderHigh:SetText("5.0")
		end

		local pulseIntervalValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		pulseIntervalValueText:SetPoint("TOP", pulseIntervalSlider, "BOTTOM", 0, -2)

		-- Placeholder only - RefreshSimpleBarPage overwrites this with the
		-- real saved value before this page is ever visible.
		pulseIntervalValueText:SetText("1.5")

		page.expBarGlowPulseIntervalValueText = pulseIntervalValueText

		pulseIntervalSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor((value * 10) + 0.5) / 10

				pulseIntervalValueText:SetText(string.format("%.1f", value))

				if not this.suppressApply then
					BTV:SetExpBarGlowPulseInterval(value)
				end
			end
		)

		page.expBarGlowPulseIntervalSlider = pulseIntervalSlider

		cursorY = pulseIntervalSliderY - 36
	end

	-------------------------------------------------------------------------
	-- Show Key Ring (Bag Bar page only, bug-fix batch Fix 2) - KeyRingButton
	-- is independently toggleable/positionable (DefaultBars.lua's
	-- BTV:SetKeyRingEnabled/SetKeyRingPosition), but the user explicitly
	-- asked for its enable checkbox to live on the Bag Bar's own settings
	-- page rather than a dedicated page/bar-list entry - it isn't a
	-- TrustyBars-owned chain member, just a lone native button toggled from
	-- here. Dragging KeyRingButton itself is still done directly on the
	-- button (its own overlay, right-click also routes back to this same
	-- page - see DefaultBars.lua's ApplyKeyRingPosition), this checkbox is
	-- purely show/hide.
	-------------------------------------------------------------------------

	if key == "bagbar" then
		local keyRingCheckbox = CreateFrame(
			"CheckButton",
			"BTVanillaSimplePageBagBarKeyRingCheckbox",
			page,
			"UICheckButtonTemplate"
		)

		keyRingCheckbox:SetWidth(24)
		keyRingCheckbox:SetHeight(24)

		keyRingCheckbox:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, cursorY)

		keyRingCheckbox:SetScript(
			"OnClick",
			function()
				local checked = this:GetChecked() and true or false

				BTV:SetKeyRingEnabled(checked)
			end
		)

		local keyRingLabel = getglobal(keyRingCheckbox:GetName() .. "Text")

		if keyRingLabel then
			keyRingLabel:SetText("Show Key Ring")
		end

		page.keyRingCheckbox = keyRingCheckbox

		cursorY = cursorY - 24 - 14

		-------------------------------------------------------------------------
		-- Key Ring Scale (bug-fix batch round 2, Issue B) - a second, small
		-- labeled section beneath the checkbox above, mirroring the shared
		-- Scale slider block earlier in this function (config.hasScale)
		-- exactly, just standalone rather than config-driven: Key Ring has
		-- no simpleBarPageConfigs entry of its own (it lives on the Bag
		-- Bar's page per the task's own placement decision, not as a
		-- separate page/bar-list entry), so this can't just add
		-- hasScale/getScale/setScale to simpleBarPageConfigs["bagbar"]
		-- without that also (incorrectly) driving the Bag Bar's OWN scale
		-- slider above. Writes directly through BTV:SetKeyRingScale.
		-------------------------------------------------------------------------

		local keyRingScaleTitleY = cursorY
		local keyRingScaleSliderY = keyRingScaleTitleY - 26

		local keyRingScaleTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		keyRingScaleTitle:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_SECTION, keyRingScaleTitleY)
		keyRingScaleTitle:SetText("Key Ring Scale (0.5 to 2.0)")

		local keyRingScaleSlider = CreateSettingSlider(
			page,
			"BTVanillaSimplePageBagBarKeyRingScaleSlider",
			290
		)

		keyRingScaleSlider:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, keyRingScaleSliderY)
		keyRingScaleSlider:SetMinMaxValues(0.5, 2.0)
		keyRingScaleSlider:SetValueStep(0.1)

		SetSliderLabel(keyRingScaleSlider, "Key Ring Scale")

		local keyRingScaleSliderLow = getglobal(keyRingScaleSlider:GetName() .. "Low")

		if keyRingScaleSliderLow then
			keyRingScaleSliderLow:SetText("0.5")
		end

		local keyRingScaleSliderHigh = getglobal(keyRingScaleSlider:GetName() .. "High")

		if keyRingScaleSliderHigh then
			keyRingScaleSliderHigh:SetText("2.0")
		end

		local keyRingScaleValueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		keyRingScaleValueText:SetPoint("TOP", keyRingScaleSlider, "BOTTOM", 0, -2)
		keyRingScaleValueText:SetText("1.0")

		page.keyRingScaleValueText = keyRingScaleValueText

		keyRingScaleSlider:SetScript(
			"OnValueChanged",
			function()
				local value = this:GetValue()

				if not value then
					return
				end

				value = math.floor((value * 10) + 0.5) / 10

				keyRingScaleValueText:SetText(string.format("%.1f", value))

				if not this.suppressApply then
					BTV:SetKeyRingScale(value)
				end
			end
		)

		page.keyRingScaleSlider = keyRingScaleSlider

		cursorY = keyRingScaleSliderY - 36
	end

	local resetY = cursorY

	-------------------------------------------------------------------------
	-- Reset to Blizzard Default
	-------------------------------------------------------------------------

	local resetButton = CreateFrame(
		"Button",
		nil,
		page
	)

	resetButton:SetHeight(22)

	resetButton:SetPoint("TOPLEFT", page, "TOPLEFT", INDENT_INPUT, resetY)
	BTV:StyleModernButton(resetButton, 200, 200)
	resetButton:SetText("Reset to Blizzard Default")

	resetButton:SetScript(
		"OnClick",
		function()
			config.reset()

			BTV:RefreshBarSettingsPage(key)
		end
	)

	page.resetPositionButton = resetButton

	page:Hide()

	settingsFrame.pages[key] = page

	return page
end

function BTV:GetOrCreateSimpleBarPage(key)
	if not settingsFrame then
		CreateSettingsFrame()
	end

	if settingsFrame.pages[key] then
		return settingsFrame.pages[key]
	end

	return CreateSimpleBarPage(key)
end

function BTV:RefreshSimpleBarPage(key)
	if not settingsFrame then
		return
	end

	local page = settingsFrame.pages[key]
	local config = simpleBarPageConfigs[key]

	if not page or not config then
		return
	end

	local pos = config.getPosition() or { x = 0, y = 0 }

	page.xSlider.suppressApply = true
	page.ySlider.suppressApply = true

	page.xSlider:SetValue(pos.x or 0)
	page.ySlider:SetValue(pos.y or 0)

	page.xValueText:SetText(string.format("%.2f", pos.x or 0))
	page.yValueText:SetText(string.format("%.2f", pos.y or 0))

	page.xSlider.suppressApply = nil
	page.ySlider.suppressApply = nil

	if page.enableCheckbox and config.getEnabled then
		page.enableCheckbox:SetChecked(config.getEnabled() ~= false)
	end

	-- Show Key Ring (bug-fix batch Fix 2, Bag Bar page only) - independent
	-- of config.getEnabled above (that's the Bag Bar's OWN enable flag),
	-- reads BTVanillaDB.keyRingEnabled directly since it has no
	-- simpleBarPageConfigs entry of its own.
	if page.keyRingCheckbox then
		page.keyRingCheckbox:SetChecked(BTVanillaDB.keyRingEnabled ~= false)
	end

	-- Key Ring Scale (bug-fix batch round 2, Issue B) - same standalone
	-- (non-config-driven) treatment as the checkbox above.
	if page.keyRingScaleSlider then
		local keyRingScale = BTVanillaDB.keyRingScale or 1

		if keyRingScale < 0.5 then
			keyRingScale = 0.5
		end

		if keyRingScale > 2.0 then
			keyRingScale = 2.0
		end

		page.keyRingScaleSlider.suppressApply = true
		page.keyRingScaleSlider:SetValue(keyRingScale)
		page.keyRingScaleSlider.suppressApply = nil

		if page.keyRingScaleValueText then
			page.keyRingScaleValueText:SetText(string.format("%.1f", keyRingScale))
		end
	end

	-------------------------------------------------------------------------
	-- Spacing/Scale/Orientation (bug-fix batch Fix 4) - each optional per
	-- config.hasSpacing/hasScale/hasOrientation, mirroring the enable
	-- checkbox's own presence check above.
	-------------------------------------------------------------------------

	if page.spacingSlider and config.getSpacing then
		local spacing = config.getSpacing() or 0
		local spacingMin = config.spacingMin or SPACING_MIN

		if spacing < spacingMin then
			spacing = spacingMin
		end

		if spacing > SPACING_MAX then
			spacing = SPACING_MAX
		end

		page.spacingSlider.suppressApply = true
		page.spacingSlider:SetValue(spacing)
		page.spacingSlider.suppressApply = nil

		if page.spacingValueText then
			page.spacingValueText:SetText(tostring(spacing))
		end
	end

	if page.scaleSlider and config.getScale then
		local scale = config.getScale() or 1

		if scale < 0.5 then
			scale = 0.5
		end

		if scale > 2.0 then
			scale = 2.0
		end

		page.scaleSlider.suppressApply = true
		page.scaleSlider:SetValue(scale)
		page.scaleSlider.suppressApply = nil

		if page.scaleValueText then
			page.scaleValueText:SetText(string.format("%.1f", scale))
		end
	end

	if page.orientationCheckbox and config.getOrientation then
		page.orientationCheckbox:SetChecked(config.getOrientation() == true)
	end

	-------------------------------------------------------------------------
	-- "Better Experience Bar" + its 5 text toggles + Font Size slider +
	-- 3 color swatches (round 17 items 3-5; round 22 items 2-4 added the
	-- Font Size slider and Overlay Text Color swatch, Experience Bar page
	-- only) - independent of config.getEnabled above (that's the
	-- container's OWN enable flag), so these read
	-- BTVanillaDB.betterExpBarEnabled/expBarShow*/expBarFontSize/
	-- expBarColor*/expBarTextColor directly, same non-config-driven
	-- treatment as Key Ring's own fields above.
	-------------------------------------------------------------------------

	if page.betterExpBarCheckbox then
		page.betterExpBarCheckbox:SetChecked(BTVanillaDB.betterExpBarEnabled == true)

		if page.expBarShowLevelCheckbox then
			page.expBarShowLevelCheckbox:SetChecked(BTVanillaDB.expBarShowLevel == true)
		end

		if page.expBarShowCurrentOverMaxCheckbox then
			page.expBarShowCurrentOverMaxCheckbox:SetChecked(BTVanillaDB.expBarShowCurrentOverMax == true)
		end

		if page.expBarShowPercentCheckbox then
			page.expBarShowPercentCheckbox:SetChecked(BTVanillaDB.expBarShowPercent == true)
		end

		if page.expBarShowRestedPercentCheckbox then
			page.expBarShowRestedPercentCheckbox:SetChecked(BTVanillaDB.expBarShowRestedPercent == true)
		end

		if page.expBarShowRestedTotalCheckbox then
			page.expBarShowRestedTotalCheckbox:SetChecked(BTVanillaDB.expBarShowRestedTotal == true)
		end

		-- Round 22 item 2: BTVanillaDB.expBarFontSize stays nil until the
		-- user actually moves this slider (same lazy-default idiom as
		-- hotkeyFontSize/countFontSize) - BTV:CaptureNativeExpBarFontIfNeeded
		-- guarantees BTV.NATIVE_EXPBAR_FONT is populated (it reads the real
		-- vanilla GameFontNormalSmall Font object directly, not a live
		-- FontString instance, so it's safe to call here even before this
		-- overlay has ever been built - see its own comment,
		-- DefaultBars.lua) so a real "native default minus one" placeholder
		-- shows even before the feature has ever been turned on this
		-- session.
		if page.expBarFontSizeSlider then
			BTV:CaptureNativeExpBarFontIfNeeded()

			local nativeDefault = BTV.NATIVE_EXPBAR_FONT and (BTV.NATIVE_EXPBAR_FONT.size - 1)
			local fontSize = ClampFontSize(BTVanillaDB.expBarFontSize or nativeDefault)

			page.expBarFontSizeSlider.suppressApply = true
			page.expBarFontSizeSlider:SetValue(fontSize)
			page.expBarFontSizeSlider.suppressApply = nil

			if page.expBarFontSizeValueText then
				page.expBarFontSizeValueText:SetText(tostring(fontSize))
			end
		end

		-- BTV:CaptureExpBarColorsIfNeeded (via BTV:ApplyExpBarColors,
		-- called unconditionally from Core.lua's login sequence) has
		-- already guaranteed both fields are non-nil by the time Settings
		-- can even be opened, so no nil fallback is needed here the way
		-- the color picker's own OpenExpBarColorPicker call defensively
		-- has one.
		if page.earnedColorSwatch then
			SetColorSwatchColor(page.earnedColorSwatch, BTVanillaDB.expBarColorEarned)
		end

		if page.restedColorSwatch then
			SetColorSwatchColor(page.restedColorSwatch, BTVanillaDB.expBarColorRested)
		end

		-- Round 22 item 3: BTVanillaDB.expBarTextColor is always seeded by
		-- Core.lua's EnsureDB (a straight default, no live-frame capture
		-- needed - see its own comment there), so it's never nil here.
		if page.expBarTextColorSwatch then
			SetColorSwatchColor(page.expBarTextColorSwatch, BTVanillaDB.expBarTextColor)
		end

		-- Round 31 item 2: BTVanillaDB.expBarGlowPulseInterval is always
		-- seeded by Core.lua's EnsureDB (a straight default, no live-frame
		-- capture needed - same as expBarTextColor above), so it's never nil
		-- here.
		if page.expBarGlowPulseIntervalSlider then
			local interval = BTVanillaDB.expBarGlowPulseInterval or 1.5

			page.expBarGlowPulseIntervalSlider.suppressApply = true
			page.expBarGlowPulseIntervalSlider:SetValue(interval)
			page.expBarGlowPulseIntervalSlider.suppressApply = nil

			if page.expBarGlowPulseIntervalValueText then
				page.expBarGlowPulseIntervalValueText:SetText(string.format("%.1f", interval))
			end
		end

		ApplyBetterExpBarGating(page)
	end

	-- Same gating window as bar 1 (CanDragDefaultLayout's underlying
	-- rule) - the enable checkbox and Reset button are deliberately
	-- excluded, mirroring ApplyDefaultLayoutGating's own established
	-- rule for bar 1 (they stay fully functional regardless of
	-- useDefaultLayout).
	ApplyDefaultLayoutGating(page, BTVanillaDB.useDefaultLayout ~= true)

	-- Default-profile lock (independent of the useDefaultLayout gate
	-- above) - every simple page is also subject to that layout lock
	-- (the ApplyDefaultLayoutGating call just above), so the banner
	-- should reflect it here too.
	self:ApplyProfileLockGating(page, true)
end

-- Config table for each simple page - populated here (rather than at
-- each DefaultBars.lua setter's own definition site) so this file stays
-- the single place that knows how Settings.lua's UI maps onto
-- DefaultBars.lua's BTV:Set*/Reset*/Get* API. Referenced by
-- CreateBarListRow above (via the simpleBarPageConfigs upvalue declared
-- near SIMPLE_BAR_NAMES) and GetOrCreateBarPage/RefreshBarSettingsPage's
-- dispatch checks.
-- Bug-fix batch Fix 3: Stance Bar now gets an enable checkbox too, matching
-- Bag Bar/Micro Menu (BTV:SetStanceBarEnabled mirrors SetBagBarEnabled's
-- exact structure - DefaultBars.lua).
--
-- Chain-anchored container migration: Stance Bar now gets the exact same
-- Spacing/Scale/Orientation controls as Bag Bar/Micro Menu, since it's
-- built from the exact same BuildChainAnchoredContainer/
-- ApplyChainAnchoredShape machinery (DefaultBars.lua) rather than wrapping
-- ShapeshiftBarFrame's own native layout directly - mirrors the Bag Bar
-- config below exactly, just against the Stance Bar's own Set*/Reset*/Get*
-- API.
simpleBarPageConfigs["stance"] = {
	title = "Stance Bar",
	hasEnable = true,
	getPosition = function() return BTVanillaDB.stanceBarPosition end,
	setPosition = function(x, y) BTV:SetStanceBarPosition(x, y) end,
	reset = function()
		BTV:ResetStanceBarPosition()
		BTV:ResetStanceBarLayout()
	end,
	getEnabled = function() return BTVanillaDB.stanceBarEnabled end,
	setEnabled = function(v) BTV:SetStanceBarEnabled(v) end,
	hasSpacing = true,
	getSpacing = function() return BTVanillaDB.stanceBarSpacing end,
	setSpacing = function(v) BTV:SetStanceBarSpacing(v) end,
	hasScale = true,
	getScale = function() return BTVanillaDB.stanceBarScale end,
	setScale = function(v) BTV:SetStanceBarScale(v) end,
	hasOrientation = true,
	getOrientation = function() return BTVanillaDB.stanceBarOrientation end,
	setOrientation = function(v) BTV:SetStanceBarOrientation(v) end,
}

-- Bug-fix batch Fix 4: Spacing/Scale/Orientation, since Bag Bar's
-- synthetic container IS a TrustyBars-owned chain-anchored layout
-- (BuildChainAnchoredContainer/ApplyChainAnchoredShape - DefaultBars.lua),
-- unlike the Stance Bar above.
simpleBarPageConfigs["bagbar"] = {
	title = "Bag Bar",
	hasEnable = true,
	getPosition = function() return BTVanillaDB.bagBarPosition end,
	setPosition = function(x, y) BTV:SetBagBarPosition(x, y) end,
	reset = function()
		BTV:ResetBagBarPosition()
		BTV:ResetBagBarLayout()

		-- Key Ring (bug-fix batch round 2, Issue B): lives on this same
		-- page (see CreateSimpleBarPage's `if key == "bagbar"` block), so
		-- its own "Reset to Blizzard Default" button restoring only the
		-- Bag Bar itself and silently leaving Key Ring untouched would be
		-- surprising - bundled in here, mirroring how the "Use Default
		-- Blizzard Layout" re-enable flow already calls
		-- BTV:ResetKeyRingPosition() independently (Settings.lua's General
		-- tab handler).
		if BTV.ResetKeyRingPosition then
			BTV:ResetKeyRingPosition()
		end
	end,
	getEnabled = function() return BTVanillaDB.bagBarEnabled end,
	setEnabled = function(v) BTV:SetBagBarEnabled(v) end,
	hasSpacing = true,
	getSpacing = function() return BTVanillaDB.bagBarSpacing end,
	setSpacing = function(v) BTV:SetBagBarSpacing(v) end,
	hasScale = true,
	getScale = function() return BTVanillaDB.bagBarScale end,
	setScale = function(v) BTV:SetBagBarScale(v) end,
	hasOrientation = true,
	getOrientation = function() return BTVanillaDB.bagBarOrientation end,
	setOrientation = function(v) BTV:SetBagBarOrientation(v) end,
}

-- Bug-fix batch Fix 3: Scale only, same reasoning as the Stance Bar's own
-- config above - Blizzard owns MainMenuBarPerformanceBarFrame's own
-- internal layout entirely (it's a single self-contained frame, not a
-- TrustyBars-owned chain), so Spacing/Orientation have nothing real to
-- drive.
simpleBarPageConfigs["latencybar"] = {
	title = "Latency Bar",
	hasEnable = true,
	getPosition = function() return BTVanillaDB.latencyBarPosition end,
	setPosition = function(x, y) BTV:SetLatencyBarPosition(x, y) end,
	reset = function()
		BTV:ResetLatencyBarLayout()
	end,
	getEnabled = function() return BTVanillaDB.latencyBarEnabled end,
	setEnabled = function(v) BTV:SetLatencyBarEnabled(v) end,
	hasScale = true,
	getScale = function() return BTVanillaDB.latencyBarScale end,
	setScale = function(v) BTV:SetLatencyBarScale(v) end,
}

-- Experience Bar (round 16 part 2, Part A): Scale only, same reasoning as
-- the Latency Bar's own config above - MainMenuExpBar is a single self-
-- contained native frame, not a TrustyBars-owned chain, so Spacing/
-- Orientation have nothing real to drive. This config only covers the
-- container's own Position/Scale/Enable/Reset - "Enable Better Experience
-- Bar" and its own text-toggle/color-picker controls (round 17 items 3-5)
-- now live on this SAME settings page too (CreateSimpleBarPage's own
-- "if key == 'expbar'" block), but remain functionally independent
-- (BTVanillaDB.betterExpBarEnabled only ever governs the text overlay,
-- never this container's own movability), per this feature's own spec.
simpleBarPageConfigs["expbar"] = {
	title = "Experience Bar",
	hasEnable = true,
	getPosition = function() return BTVanillaDB.expBarPosition end,
	setPosition = function(x, y) BTV:SetExpBarPosition(x, y) end,
	reset = function()
		BTV:ResetExpBarLayout()
	end,
	getEnabled = function() return BTVanillaDB.expBarEnabled end,
	setEnabled = function(v) BTV:SetExpBarEnabled(v) end,
	hasScale = true,
	getScale = function() return BTVanillaDB.expBarScale end,
	setScale = function(v) BTV:SetExpBarScale(v) end,
}

simpleBarPageConfigs["micromenu"] = {
	title = "Micro Menu",
	hasEnable = true,
	getPosition = function() return BTVanillaDB.microMenuPosition end,
	setPosition = function(x, y) BTV:SetMicroMenuPosition(x, y) end,
	reset = function()
		BTV:ResetMicroMenuPosition()
		BTV:ResetMicroMenuLayout()
	end,
	getEnabled = function() return BTVanillaDB.microMenuEnabled end,
	setEnabled = function(v) BTV:SetMicroMenuEnabled(v) end,
	hasSpacing = true,
	-- (v1.0 polish pass) -10 floor, not the shared SPACING_MIN (0) - see
	-- BTV:SetMicroMenuSpacing's own comment (DefaultBars.lua) and
	-- CreateSimpleBarPage's spacingMin handling above.
	spacingMin = -10,
	getSpacing = function() return BTVanillaDB.microMenuSpacing end,
	setSpacing = function(v) BTV:SetMicroMenuSpacing(v) end,
	hasScale = true,
	getScale = function() return BTVanillaDB.microMenuScale end,
	setScale = function(v) BTV:SetMicroMenuScale(v) end,
	hasOrientation = true,
	getOrientation = function() return BTVanillaDB.microMenuOrientation end,
	setOrientation = function(v) BTV:SetMicroMenuOrientation(v) end,
}

-- Shared right-click-to-settings entry point for any string-keyed simple
-- page - DefaultBars.lua's Stance Bar/Bag Bar/Micro Menu/Key Ring/Latency
-- Bar overlays all call this directly (EnsureContainerOverlay) rather than
-- needing their own OpenXSettings wrapper apiece, mirroring
-- OpenDefaultBarSettings' role for the numeric default bars (1-5) below.
function BTV:OpenBarSettingsByKey(key)
	self:ShowSettingsFrame()
	self:ShowBarPage(key)
end

-------------------------------------------------------------------------
-- Refresh values shown by a bar page
-------------------------------------------------------------------------

function BTV:RefreshBarSettingsPage(barId)
	if not settingsFrame then
		return
	end

	if simpleBarPageConfigs[barId] then
		self:RefreshSimpleBarPage(barId)
		return
	end

	local page = settingsFrame.pages[barId]

	if not page then
		return
	end

	local cfg, isDefault = GetBarConfig(barId)

	if not cfg then
		return
	end

	-------------------------------------------------------------------------
	-- Suppress OnValueChanged re-application while we're just syncing the
	-- sliders' visual state FROM the saved config - only user-driven
	-- ticks should write back to the config.
	-------------------------------------------------------------------------

	page.xSlider.suppressApply = true
	page.ySlider.suppressApply = true
	page.buttonSizeSlider.suppressApply = true

	if page.spacingSlider then
		page.spacingSlider.suppressApply = true
	end

	-------------------------------------------------------------------------
	-- X/Y
	-------------------------------------------------------------------------

	local x = cfg.x or 0
	local y = cfg.y or 0

	page.xSlider:SetValue(x)
	page.ySlider:SetValue(y)

	-- SetValue only fires OnValueChanged (and therefore the %.2f-formatted
	-- value-text update in each slider's own handler) when the value
	-- actually CHANGES - if cfg.x/y equals whatever the slider was already
	-- sitting at (e.g. the page's initial unformatted "0.00" placeholder
	-- text from GetOrCreateBarPage, or a value unchanged since the last
	-- refresh), that handler never runs and xValueText/yValueText would
	-- keep showing stale/unrounded text. Setting them explicitly here
	-- guarantees the same %.2f formatting on every refresh regardless of
	-- whether the value changed.
	page.xValueText:SetText(
		string.format("%.2f", x)
	)

	page.yValueText:SetText(
		string.format("%.2f", y)
	)

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
	-- Spacing (default bars only)
	-------------------------------------------------------------------------

	if page.spacingSlider then
		local offset = GetSpacingDisplayOffset()

		-- Recomputed every refresh - the offset (and therefore the
		-- displayed range) can change live when the border-style toggle
		-- flips while this page is already built.
		page.spacingSlider:SetMinMaxValues(0, SPACING_MAX - offset)

		if page.spacingSliderLow then
			page.spacingSliderLow:SetText("0")
		end

		if page.spacingSliderHigh then
			page.spacingSliderHigh:SetText(tostring(SPACING_MAX - offset))
		end

		local spacing = cfg.spacing or 0

		if spacing < SPACING_MIN then
			spacing = SPACING_MIN
		end

		if spacing > SPACING_MAX then
			spacing = SPACING_MAX
		end

		local displayed = spacing - offset

		if displayed < 0 then
			displayed = 0
		end

		page.spacingSlider:SetValue(displayed)

		if page.spacingValueText then
			page.spacingValueText:SetText(tostring(displayed))
		end
	end

	page.xSlider.suppressApply = nil
	page.ySlider.suppressApply = nil
	page.buttonSizeSlider.suppressApply = nil

	if page.spacingSlider then
		page.spacingSlider.suppressApply = nil
	end

	-------------------------------------------------------------------------
	-- Grid preset selection
	-------------------------------------------------------------------------

	RefreshGridSwatchSelection(
		page,
		cfg.cols or 12,
		cfg.rows or 1
	)

	-------------------------------------------------------------------------
	-- Button count (custom bars only)
	-------------------------------------------------------------------------

	if page.RefreshButtonCountStepperVisual then
		page.RefreshButtonCountStepperVisual()
	end

	-------------------------------------------------------------------------
	-- Enable checkbox (default bars 2-5 AND Extra Bars 6-9)
	--
	-- Major architecture migration, Phase 1 of 2: reconciliation from the
	-- live native SHOW_MULTI_ACTIONBAR_* globals (via the now-removed
	-- IsDefaultBarNativelyShown) is gone - bars 2-5's real Blizzard
	-- buttons are permanently hidden regardless of those globals, so
	-- cfg.enabled (our own saved flag) is now the sole source of truth.
	-- Extra Bars (Stance/Page Bar Assignment feature, Part 1) follow the
	-- exact same rule - see Bar.lua's SetExtraBarEnabled.
	-------------------------------------------------------------------------

	if page.enableCheckbox and ((isDefault and barId ~= 1) or BTV:IsExtraBarId(barId)) then
		page.enableCheckbox:SetChecked(
			cfg.enabled == true
		)
	end

	-------------------------------------------------------------------------
	-- Page Indicator Scale (Main Bar only - Part 4)
	-------------------------------------------------------------------------

	if barId == 1 and page.pageIndicatorSlider then
		local scale = BTVanillaDB.mainBarPageIndicatorScale or 1

		page.pageIndicatorSlider.suppressApply = true
		page.pageIndicatorSlider:SetValue(scale)
		page.pageIndicatorValueText:SetText(string.format("%.1f", scale))
		page.pageIndicatorSlider.suppressApply = nil

		BTV:RefreshMainBarPageIndicatorControlsVisibility()

		-- Stance/Page Bar Assignment rows (Issue 5, bug-fix batch round
		-- 4): rebuilt every time bar 1's page is (re)shown, same as the
		-- Page Indicator controls just above, so the rows always reflect
		-- the CURRENT stance count/pagination-and-stance-swap toggle state
		-- rather than whatever they looked like the last time this page
		-- happened to be open.
		BTV:RebuildMainBarAssignmentRows()
	end

	-------------------------------------------------------------------------
	-- Default-layout lock, numbered default bars (1-5) - user decision:
	-- while "Use Default Blizzard Layout" is on, every one of these
	-- bars' controls locks EXCEPT enable/disable, exactly like the
	-- Default-profile lock - both reasons share the same combined lock
	-- and control list now (BTV:ApplyProfileLockGating below), rather
	-- than this being a separate, narrower, bar-1-only gate.
	-------------------------------------------------------------------------

	-- Default-profile lock (independent of the useDefaultLayout gate
	-- above) - applies to every bar page, not just numbered default bars.
	-- Only numbered default bars (1-5) are also subject to the layout
	-- lock, so only their banner/controls should reflect that lock too.
	self:ApplyProfileLockGating(page, page.isDefault)

	-- Locks this page's own spacing/buttonSize sliders whenever the
	-- corresponding global override (General tab) is on, so a bar page
	-- opened after the global toggle was already enabled still starts
	-- locked.
	BTV:RefreshBarPageGlobalOverrideGating(page)

	-- Bar 5 can only be enabled while bar 4 is (matches native's own
	-- dependency, DefaultBars.lua's SetDefaultBarEnabled) unless the
	-- General tab's bypass option is on. Runs AFTER ApplyProfileLockGating
	-- (not alongside the SetChecked block above) - that call unconditionally
	-- UNLOCKS enableCheckbox whenever the Default-profile/layout lock
	-- itself isn't active (its own exemption for numbered default bars),
	-- which was clobbering this lock when placed earlier in the function.
	if page.enableCheckbox and barId == 5 then
		local bar4Cfg = BTVanillaDB.defaultBars[4]
		local allowed = BTVanillaDB.bypassRightActionBar2Dependency == true
			or (bar4Cfg and bar4Cfg.enabled == true)

		LockControl(page.enableCheckbox, not allowed)
	end
end

-- Locks (dims, EnableMouse(false)) a full bar page's own spacing/
-- buttonSize sliders while the corresponding global override (General
-- tab) is enabled - only ever called from RefreshBarSettingsPage's
-- non-simple-bar path above, so simple bar pages (Bag Bar/Micro Menu/
-- etc.) are naturally never affected, matching the global overrides'
-- scope (true action bars 1-9 only).
function BTV:RefreshBarPageGlobalOverrideGating(page)
	if not page then
		return
	end

	-- Must also respect the Default-profile/Default-layout lock
	-- (BTV:ApplyProfileLockGating, called just before this in
	-- RefreshBarSettingsPage/RefreshSimpleBarPage) - without this, this
	-- function unconditionally RE-ENABLES the slider whenever the global
	-- override checkbox happens to be off, blindly overwriting whatever
	-- that other lock had just set.
	local alsoLocked = self:IsDefaultProfileActive()
		or (page.isDefault and BTVanillaDB.useDefaultLayout == true)

	if page.spacingSlider then
		local locked = alsoLocked or (BTVanillaDB.globalSpacingEnabled == true)

		page.spacingSlider:EnableMouse(not locked)
		page.spacingSlider:SetAlpha(locked and 0.5 or 1)
	end

	if page.buttonSizeSlider then
		local locked = alsoLocked or (BTVanillaDB.globalButtonSizeEnabled == true)

		page.buttonSizeSlider:EnableMouse(not locked)
		page.buttonSizeSlider:SetAlpha(locked and 0.5 or 1)
	end
end

-- Live-refreshes the spacing/buttonSize lock on every currently cached
-- full bar page (1-9) without a full RefreshBarSettingsPage resync -
-- called from the two new global-override checkboxes/sliders (General
-- tab) so already-open bar pages lock/unlock immediately. Simple bar
-- pages (string keys in settingsFrame.pages) are skipped - out of scope
-- for the global overrides.
function BTV:RefreshAllBarPagesGlobalOverrideGating()
	if not settingsFrame then
		return
	end

	local id
	local page

	for id, page in pairs(settingsFrame.pages) do
		if type(id) == "number" and BTV.bars and BTV.bars[id] then
			self:RefreshBarPageGlobalOverrideGating(page)
		end
	end
end

-- Shows/hides the Main Bar page's Page Indicator Scale slider per
-- BTVanillaDB.mainBarPaginationEnabled - called both from
-- RefreshBarSettingsPage(1) above and from the General panel's own
-- pagination checkbox handler (below), so toggling that checkbox
-- immediately shows/hides this slider even while bar 1's page is already
-- open (mirrors RefreshDefaultLayoutGatingOnAllPages' own "live-refresh an
-- already-open page" reasoning).
function BTV:RefreshMainBarPageIndicatorControlsVisibility()
	if not settingsFrame then
		return
	end

	local page = settingsFrame.pages[1]

	if not page or not page.pageIndicatorSlider then
		return
	end

	local show = BTVanillaDB.mainBarPaginationEnabled ~= false

	if show then
		page.pageIndicatorTitle:Show()
		page.pageIndicatorSlider:Show()
		page.pageIndicatorValueText:Show()
	else
		page.pageIndicatorTitle:Hide()
		page.pageIndicatorSlider:Hide()
		page.pageIndicatorValueText:Hide()
	end
end

-------------------------------------------------------------------------
-- Dynamic content-panel/window height (Fix 3)
--
-- Rather than a fixed size tuned for the busiest page, this measures the
-- REAL on-screen bottom edge (Frame:GetTop()/GetBottom(), genuine vanilla
-- API - not an introspection/polyfill trick) of whichever controls are
-- actually shown right now, so a simpler page (e.g. a custom bar, which
-- lacks the enable checkbox/Reset button/Spacing slider, or a default
-- bar, which lacks the button-count stepper/Delete Bar) gets a window
-- sized to ITS content instead of the fixed size tuned for the busiest
-- combination of controls.
-------------------------------------------------------------------------

-- Distance from the settings window's own top edge down to
-- contentPanel/listPanel's top (matches their "-64" TOPRIGHT/TOPLEFT
-- anchor offset in CreateSettingsFrame, raised from the original "-52" to
-- make room for the tab/content divider line) and from their bottom edge
-- down to the window's own bottom edge - the fixed "chrome" every view's
-- content sits inside, regardless of which view/page is showing.
local SETTINGS_CHROME_TOP = 64
local SETTINGS_CHROME_BOTTOM = 18

-- Never shrinks below whatever the current view's own frame naturally
-- needs to avoid feeling cramped, even if every one of its controls
-- happens to measure shorter than this.
local SETTINGS_CONTENT_MIN_HEIGHT = 260

-- The settings window can never grow taller than this fraction of the
-- player's actual screen height - see ApplySettingsHeightFromCandidates'
-- own comment on why capping height alone (the window is CENTER-anchored)
-- is enough to guarantee top/bottom screen padding too.
local SETTINGS_MAX_HEIGHT_RATIO = 0.9

-- Appends frame to list only if non-nil, at the next free index (n+1).
-- table.getn/# have undefined behavior on tables with nil "holes" (Lua
-- 5.0 manual) - since several of the candidate controls below are nil
-- depending on bar kind (custom vs. default) or bar id (bar 1 has no
-- enable checkbox), candidate lists are built through this helper rather
-- than a table constructor with nils embedded in it, so the resulting
-- table is always hole-free.
local function AppendCandidate(list, n, frame)
	if frame then
		list[n + 1] = frame
		return n + 1
	end

	return n
end

-- Deepest distance from `referenceTop` (a real, resolved GetTop() of the
-- scroll child every candidate lives inside) down to any candidate's own
-- bottom edge - i.e. exactly how much vertical room this content needs.
--
-- Measured as a DELTA between two live positions rather than against a
-- computed "where the window's top edge should be" estimate: the settings
-- window is movable (f:SetMovable(true)/StartMoving, CreateSettingsFrame),
-- so the old screen-center-derived estimate
-- ((GetScreenHeight() / 2) + (frameHeight / 2) - SETTINGS_CHROME_TOP) was
-- only ever correct while the window happened to still sit exactly where
-- it was first anchored. Once dragged anywhere, every fit computed a
-- wrong height - sometimes SHORTER than the content, which also silently
-- suppressed the scrollbar (BTV:UpdateScrollFrame only shows one when
-- requiredContentHeight exceeds the viewport), leaving content both cut
-- off AND unreachable. A top-to-bottom delta is position-independent, so
-- it stays correct wherever the window has been dragged to.
local function MeasureDeepestExtent(candidateList, referenceTop)
	if not candidateList or not referenceTop then
		return nil
	end

	local deepest = nil
	local i

	for i = 1, table.getn(candidateList) do
		local frame = candidateList[i]

		if frame and frame.GetBottom and not (frame.IsShown and not frame:IsShown()) then
			local bottom = frame:GetBottom()

			if bottom then
				local depth = referenceTop - bottom

				if not deepest or depth > deepest then
					deepest = depth
				end
			end
		end
	end

	return deepest
end

-- Resizes `scrollChildPanel` (settingsFrame.contentPanel/generalPanel/
-- profilesPanel - whichever view is currently being fitted)/listPanel/the
-- outer window to fit the lowest bottom edge found across every frame in
-- candidateList, floored at SETTINGS_CONTENT_MIN_HEIGHT and CEILED at the
-- screen-relative max (BTV:UpdateScrollFrame turns scrolling on for
-- whatever doesn't fit within that ceiling).
-- listCandidateList (optional): when given, the bar-list sidebar
-- (settingsFrame.listPanel/listContent) is fitted/scrolled independently
-- using the SAME shared viewportHeight this function computes for
-- scrollFrame/scrollChildPanel - the window is still sized to fit
-- whichever of the two (page content vs. bar list) needs more room (same
-- as before), but now EACH side gets its own real BTV:UpdateScrollFrame
-- call, so a bar list too long for the fitted/capped viewport scrolls
-- instead of rendering rows past the window's own bottom edge - the
-- previous behavior, since settingsFrame.listPanel used to be a plain,
-- non-scrolling Frame just given a same-as-content SetHeight with nothing
-- to actually clip its rows to that height.
-- minContentHeight (optional): a floor for the shared viewport, on top of
-- SETTINGS_CONTENT_MIN_HEIGHT - see FitSettingsWindowToBarPage's own
-- "standard bar page" baseline, which keeps the window from shrinking
-- below what an ordinary bar page needs just because the page currently
-- being shown happens to be a shorter one.
--
-- Returns the measured (unclamped, unfloored) content height so callers
-- can record a baseline from it.
local function ApplySettingsHeightFromCandidates(candidateList, scrollFrame, scrollChildPanel, listCandidateList, minContentHeight)
	if not settingsFrame or not scrollFrame or not scrollChildPanel then
		return nil
	end

	-- Captured before either scroll position gets reset below, so the
	-- BTV:UpdateScrollFrame calls at the bottom of this function can
	-- restore the user's actual scroll position (clamped to whatever the
	-- new content size allows) instead of always snapping back to the top
	-- on every re-fit - e.g. toggling a General-tab checkbox that reveals/
	-- hides a slider used to reset scroll to the top every time.
	local previousContentScroll = scrollFrame:GetVerticalScroll()
	local previousListScroll = listCandidateList and settingsFrame.listPanel
		and settingsFrame.listPanel:GetVerticalScroll()

	-- Both scroll positions have to be reset to the top BEFORE measuring:
	-- GetTop()/GetBottom() read real SCREEN positions that shift with the
	-- current scroll offset, so a previously-scrolled view would otherwise
	-- measure as shorter than it really is.
	scrollFrame:SetVerticalScroll(0)

	if listCandidateList and settingsFrame.listPanel then
		settingsFrame.listPanel:SetVerticalScroll(0)
	end

	-- Every candidate is a descendant of scrollChildPanel, which is
	-- PERMANENTLY the given scrollFrame's scroll child (set once, at
	-- creation - see CreateSettingsFrame/BTV:CreateWideContentScrollFrame's
	-- own comments on why nothing here ever re-targets SetScrollChild at a
	-- different frame), so its own top is the right reference to measure
	-- each candidate's depth from.
	local contentDepth = MeasureDeepestExtent(candidateList, scrollChildPanel:GetTop())

	local listDepth = nil

	if listCandidateList and settingsFrame.listContent then
		listDepth = MeasureDeepestExtent(listCandidateList, settingsFrame.listContent:GetTop())
	end

	if not contentDepth and not listDepth then
		return nil
	end

	local BOTTOM_MARGIN = 20
	local measuredContentHeight = contentDepth and (contentDepth + BOTTOM_MARGIN) or 0
	local listContentHeight = listDepth and (listDepth + BOTTOM_MARGIN) or 0

	-- The shared viewport is driven by whichever side needs more room -
	-- same "tallest side wins" rule as before, just now from two
	-- independently measured depths instead of one merged bottom edge.
	local sharedRequirement = measuredContentHeight

	if listContentHeight > sharedRequirement then
		sharedRequirement = listContentHeight
	end

	if minContentHeight and sharedRequirement < minContentHeight then
		sharedRequirement = minContentHeight
	end

	if sharedRequirement < SETTINGS_CONTENT_MIN_HEIGHT then
		sharedRequirement = SETTINGS_CONTENT_MIN_HEIGHT
	end

	local contentHeight = measuredContentHeight

	if contentHeight < SETTINGS_CONTENT_MIN_HEIGHT then
		contentHeight = SETTINGS_CONTENT_MIN_HEIGHT
	end

	-- Hard screen-relative ceiling on the VISIBLE viewport (never on the
	-- real content height above, which BTV:UpdateScrollFrame needs
	-- unclamped to size the scrollchild correctly) - the window is
	-- CENTER-anchored to UIParent, so capping height alone guarantees at
	-- least (1 - SETTINGS_MAX_HEIGHT_RATIO) / 2 of screen height as
	-- padding above AND below it.
	local maxViewportHeight = (GetScreenHeight() * SETTINGS_MAX_HEIGHT_RATIO)
		- SETTINGS_CHROME_TOP - SETTINGS_CHROME_BOTTOM

	local viewportHeight = sharedRequirement

	if viewportHeight > maxViewportHeight then
		viewportHeight = maxViewportHeight
	end

	-- Temporary diag (UI redesign branch, General-panel disappearing-items
	-- investigation): diag22 showed every candidate's own shown/bottom
	-- state was sane and correctly populated at measurement time, so the
	-- bug isn't in WHICH candidates get measured - this prints the actual
	-- computed numbers (reference top, raw depth, and every height this
	-- function derives from it) so the next repro shows exactly where a
	-- wrong value first appears. Remove once root-caused.
	BTV:Print(
		"diag23: referenceTop=" .. tostring(scrollChildPanel:GetTop()) ..
		" contentDepth=" .. tostring(contentDepth) ..
		" measuredContentHeight=" .. tostring(measuredContentHeight) ..
		" sharedRequirement=" .. tostring(sharedRequirement) ..
		" minContentHeight=" .. tostring(minContentHeight) ..
		" contentHeight=" .. tostring(contentHeight) ..
		" viewportHeight=" .. tostring(viewportHeight) ..
		" maxViewportHeight=" .. tostring(maxViewportHeight) ..
		" previousContentScroll=" .. tostring(previousContentScroll)
	)

	BTV:UpdateScrollFrame(
		scrollFrame,
		scrollChildPanel,
		contentHeight,
		viewportHeight,
		previousContentScroll
	)

	if listCandidateList and settingsFrame.listPanel and settingsFrame.listContent then
		BTV:UpdateScrollFrame(
			settingsFrame.listPanel,
			settingsFrame.listContent,
			listContentHeight,
			viewportHeight,
			previousListScroll
		)
	elseif settingsFrame.listPanel then
		settingsFrame.listPanel:SetHeight(viewportHeight)
	end

	settingsFrame:SetHeight(
		viewportHeight + SETTINGS_CHROME_TOP + SETTINGS_CHROME_BOTTOM
	)

	return measuredContentHeight
end

-- Bars view: combines the current bar page's own controls with the bar
-- list's rows - both are visible side by side in this view, so the
-- window has to be tall enough for whichever of the two is actually
-- taller (e.g. a short custom-bar page next to a long bar list with many
-- custom bars added).
function BTV:FitSettingsWindowToBarPage(barId)
	if not settingsFrame then
		return
	end

	local page = settingsFrame.pages[barId]

	if not page then
		return
	end

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, page.xValueText)
	n = AppendCandidate(candidates, n, page.yValueText)
	n = AppendCandidate(candidates, n, page.spacingValueText)
	n = AppendCandidate(candidates, n, page.buttonSizeValueText)
	n = AppendCandidate(candidates, n, page.resetPositionButton)
	n = AppendCandidate(candidates, n, page.buttonCountMinus)
	n = AppendCandidate(candidates, n, page.buttonCountPlus)
	n = AppendCandidate(candidates, n, page.buttonCountValueText)
	n = AppendCandidate(candidates, n, page.enableCheckbox)
	n = AppendCandidate(candidates, n, page.pageIndicatorValueText)

	-- Bug-fix batch Fix 4: Scale/Orientation controls, added to the simple
	-- bar pages (Stance Bar/Bag Bar/Micro Menu) alongside Spacing above -
	-- included here (the SHARED bar-page height-fit function, used for
	-- both default/custom AND simple pages) rather than a separate simple-
	-- page-only fit function, since FitSettingsWindowToBarPage already
	-- looks up settingsFrame.pages[barId] generically regardless of key
	-- type (numeric bar id or string simple-page key).
	n = AppendCandidate(candidates, n, page.scaleValueText)
	n = AppendCandidate(candidates, n, page.orientationCheckbox)
	n = AppendCandidate(candidates, n, page.keyRingCheckbox)
	n = AppendCandidate(candidates, n, page.keyRingScaleValueText)

	-- "Better Experience Bar" + its 5 text toggles + Font Size slider + 3
	-- color pickers + Reset Colors button + Pulse Interval slider (round 17,
	-- items 3-5; round 22 items 2-4; round 31 item 2, Experience Bar page
	-- only) - expBarGlowPulseIntervalValueText is now the effective lowest
	-- control on this page (below even resetPositionButton above, and below
	-- resetColorsButton, which used to hold that title before round 31 item
	-- 2 added a control beneath it), so it's what actually drives this
	-- page's real fitted height; every other entry here is still listed for
	-- the same "include every real candidate" thoroughness this list
	-- already follows.
	n = AppendCandidate(candidates, n, page.betterExpBarCheckbox)
	n = AppendCandidate(candidates, n, page.betterExpBarDescription)
	n = AppendCandidate(candidates, n, page.expBarFontSizeSlider)
	n = AppendCandidate(candidates, n, page.expBarFontSizeValueText)
	n = AppendCandidate(candidates, n, page.expBarShowLevelCheckbox)
	n = AppendCandidate(candidates, n, page.expBarShowCurrentOverMaxCheckbox)
	n = AppendCandidate(candidates, n, page.expBarShowPercentCheckbox)
	n = AppendCandidate(candidates, n, page.expBarShowRestedPercentCheckbox)
	n = AppendCandidate(candidates, n, page.expBarShowRestedTotalCheckbox)
	n = AppendCandidate(candidates, n, page.earnedColorSwatch)
	n = AppendCandidate(candidates, n, page.restedColorSwatch)
	n = AppendCandidate(candidates, n, page.expBarTextColorSwatch)
	n = AppendCandidate(candidates, n, page.resetColorsButton)
	n = AppendCandidate(candidates, n, page.expBarGlowPulseIntervalSlider)
	n = AppendCandidate(candidates, n, page.expBarGlowPulseIntervalValueText)

	-- Stance/Page Bar Assignment rows (relocated here from the General tab,
	-- bug-fix batch round 4, Issue 5) - only ever present on bar 1's page.
	-- Each individual row is included as its own candidate, same "walk the
	-- rows, not their shared container" convention gridSwatches below uses.
	if page.assignmentRows then
		local i

		for i = 1, table.getn(page.assignmentRows) do
			n = AppendCandidate(candidates, n, page.assignmentRows[i])
		end
	end

	if page.gridSwatches then
		local i

		for i = 1, table.getn(page.gridSwatches) do
			local swatch = page.gridSwatches[i]

			n = AppendCandidate(candidates, n, swatch)
			n = AppendCandidate(candidates, n, swatch.caption)
		end
	end

	-- Measured/fitted SEPARATELY from the page's own candidates above (own
	-- listCandidates table, not appended into `candidates`) - the bar-list
	-- sidebar now scrolls independently of the content page
	-- (BTV:CreateScrollFrame's settingsFrame.listPanel/listContent), so it
	-- needs its own true bottom-most-row measurement rather than being
	-- merged into one combined list, even though the window's own overall
	-- height still ends up driven by whichever of the two is taller (see
	-- ApplySettingsHeightFromCandidates' own listCandidateList handling).
	local listCandidates = {}
	local listN = 0

	if settingsFrame.barButtons then
		local i

		for i = 1, table.getn(settingsFrame.barButtons) do
			listN = AppendCandidate(listCandidates, listN, settingsFrame.barButtons[i])
		end
	end

	-- The scrollchild is settingsFrame.contentPanel itself, NOT `page` -
	-- every bar page uses page:SetAllPoints(settingsFrame.contentPanel)
	-- (GetOrCreateBarPage), so `page` always just mirrors contentPanel's
	-- own rect rather than having independently meaningful dimensions.
	local measured = ApplySettingsHeightFromCandidates(
		candidates,
		settingsFrame.contentScrollFrame,
		settingsFrame.contentPanel,
		listCandidates,
		settingsFrame.standardBarPageHeight
	)

	-- "Standard bar page" baseline: every numbered bar page except bar 1
	-- (Action Bars 2-5 and Extra Bars 6-9) is built by the same code path
	-- with the same controls, so they all measure the same height - record
	-- it and use it as the window's floor from then on (passed back in as
	-- minContentHeight above). This is what stops the window from resizing
	-- at all while clicking between those pages, and from shrinking below
	-- that baseline when a SHORTER page (a simple bar) is selected.
	--
	-- Bar 1 is deliberately excluded: its Stance/Page Bar Assignment rows
	-- make it taller than a standard page, and using it as the baseline
	-- would inflate every other page to Main Bar's height.
	if measured and type(barId) == "number" and barId ~= 1 then
		if not settingsFrame.standardBarPageHeight or measured > settingsFrame.standardBarPageHeight then
			settingsFrame.standardBarPageHeight = measured
		end
	end
end

-- General view: no bar list is shown here, just the checkbox and its
-- description text.
function BTV:FitSettingsWindowToGeneralView()
	if not settingsFrame or not settingsFrame.generalPanel then
		return
	end

	local panel = settingsFrame.generalPanel

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, panel.useDefaultLayoutCheckbox)
	n = AppendCandidate(candidates, n, panel.description)
	n = AppendCandidate(candidates, n, panel.tintWholeButtonCheckbox)
	n = AppendCandidate(candidates, n, panel.disableBlizzardArtCheckbox)
	n = AppendCandidate(candidates, n, panel.mainBarPaginationCheckbox)
	n = AppendCandidate(candidates, n, panel.mainBarStanceSwapCheckbox)
	n = AppendCandidate(candidates, n, panel.mainBarStanceSwapDescription)

	-- Stance/Page Bar Assignment rows - RELOCATED to bar 1's own settings
	-- page (bug-fix batch round 4, Issue 5) - see
	-- FitSettingsWindowToBarPage for their candidate handling now.

	n = AppendCandidate(candidates, n, panel.hotkeyValueText)
	n = AppendCandidate(candidates, n, panel.hotkeyResetButton)
	n = AppendCandidate(candidates, n, panel.countValueText)
	n = AppendCandidate(candidates, n, panel.countResetButton)
	n = AppendCandidate(candidates, n, panel.snapToAdjacentDescription)
	n = AppendCandidate(candidates, n, panel.modernBorderStyleCheckbox)
	n = AppendCandidate(candidates, n, panel.modernBorderStyleDescription)
	n = AppendCandidate(candidates, n, panel.globalSpacingCheckbox)
	n = AppendCandidate(candidates, n, panel.globalSpacingSlider)
	n = AppendCandidate(candidates, n, panel.globalSpacingValueText)
	n = AppendCandidate(candidates, n, panel.globalButtonSizeCheckbox)
	n = AppendCandidate(candidates, n, panel.globalButtonSizeSlider)
	n = AppendCandidate(candidates, n, panel.globalButtonSizeValueText)
	n = AppendCandidate(candidates, n, panel.bypassBar2DepCheckbox)

	-- "Enable Better Experience Bar" - RELOCATED to the Experience Bar's
	-- own settings page (round 17 item 5) - see FitSettingsWindowToBarPage
	-- for its candidate handling now.

	-- Temporary diag (UI redesign branch, General-panel disappearing-items
	-- investigation): diag20 showed the measured content height matching
	-- modernBorderStyleDescription's own depth exactly - i.e. every
	-- candidate from globalSpacingCheckbox onward got skipped by
	-- MeasureDeepestExtent - but diag20 is a manually-typed slash command
	-- run AFTER the fact, so it can't tell "those candidates really were
	-- skipped at measurement time" apart from "the deferred Fit just
	-- hadn't run yet when diag20 was typed, and this is stale data from
	-- an earlier fit". Printing straight from inside this function
	-- (n and each candidate's own IsShown()/GetBottom() at the exact
	-- moment it actually runs) removes that timing ambiguity entirely.
	-- Remove once root-caused.
	BTV:Print("diag22: FitSettingsWindowToGeneralView candidates n=" .. tostring(n))

	local diagI

	for diagI = 1, n do
		local diagFrame = candidates[diagI]

		BTV:Print(
			"diag22: candidate " .. diagI ..
			" name=" .. tostring(diagFrame.GetName and diagFrame:GetName()) ..
			" shown=" .. tostring(diagFrame.IsShown and diagFrame:IsShown()) ..
			" bottom=" .. tostring(diagFrame.GetBottom and diagFrame:GetBottom())
		)
	end

	ApplySettingsHeightFromCandidates(candidates, settingsFrame.generalScrollFrame, panel)
end

-------------------------------------------------------------------------
-- Show a specific bar page
-------------------------------------------------------------------------

function BTV:ShowBarPage(barId)
	if not settingsFrame then
		CreateSettingsFrame()
	end

	-- Always switches back to the "Bars" view - every caller of this
	-- function (bar list clicks, OpenBarSettings, OpenDefaultBarSettings,
	-- ShowBarsView itself) wants a bar page on
	-- screen, so this is the one place that needs to own un-hiding
	-- listPanel/contentPanel and hiding the General panel, rather than
	-- every caller remembering to do it.
	settingsFrame.currentView = "bars"
	BTV:RefreshActiveTabHighlight()
	settingsFrame.listPanel:Show()
	settingsFrame.contentScrollFrame:Show()
	settingsFrame.contentPanel:Show()

	if settingsFrame.generalScrollFrame then
		settingsFrame.generalScrollFrame:Hide()
	end

	if settingsFrame.generalPanel then
		settingsFrame.generalPanel:Hide()
	end

	if settingsFrame.profilesScrollFrame then
		settingsFrame.profilesScrollFrame:Hide()
	end

	if settingsFrame.profilesPanel then
		settingsFrame.profilesPanel:Hide()
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

	-- Keep the sidebar row's persistent gold highlight in sync with
	-- whichever bar page is actually showing (BTVListRowMixin:SetSelected).
	-- Both lookups are nil-guarded: barButtonsByBarId may not have an
	-- entry yet (list not built this session) or ever (e.g. bagbar/
	-- micromenu/latencybar/expbar rows are conditionally absent per
	-- RefreshBarList's own exists checks).
	if settingsFrame.selectedBarId ~= nil and settingsFrame.selectedBarId ~= barId then
		local oldRow = settingsFrame.barButtonsByBarId[settingsFrame.selectedBarId]

		if oldRow then
			oldRow:SetSelected(false)
		end
	end

	local newRow = settingsFrame.barButtonsByBarId[barId]

	if newRow then
		newRow:SetSelected(true)
	end

	settingsFrame.selectedBarId = barId

	-- Fix 3: resize the window to fit this page's actual controls now
	-- that it (and the always-visible bar list) are both on-screen and
	-- positioned - GetTop()/GetBottom() only return real values for
	-- currently-shown frames, so this has to run after target:Show()
	-- above, not before it. Deferred one frame (DeferFit) so its own
	-- candidates' positions have settled before anything measures them.
	DeferFit(function() BTV:FitSettingsWindowToBarPage(barId) end)
end

-------------------------------------------------------------------------
-- General tab panel (BTVanillaDB.useDefaultLayout)
--
-- Built lazily on first use, exactly like GetOrCreateBarPage - anchored
-- to span the same combined area listPanel + contentPanel occupy
-- together, since the bar list has no meaning in this view.
-------------------------------------------------------------------------

-- ClampFontSize now lives near FONT_SIZE_MIN/MAX/STEP's own declaration,
-- at the top of this file (round 22) - see that copy's comment for why.

-------------------------------------------------------------------------
-- Stance / Page Bar Assignment cyclic value (Part 2)
--
-- 0 is the "Unassigned" sentinel - NOT a real table hole (a raw
-- `{nil, 6, 7, 8, 9}` constructor would put a nil at index 1, and
-- table.getn/# have undefined behavior on a table with a hole at the
-- start, per the Lua 5.0 manual) - translated to/from a real nil only at
-- the BTVanillaDB read/write boundary in CreateExtraBarAssignmentRow's
-- own getFn/setFn callers below.
-------------------------------------------------------------------------

local EXTRA_BAR_ASSIGNMENT_CYCLE = { 0, 6, 7, 8, 9 }

local function ExtraBarAssignmentLabel(assignedId)
	if not assignedId or assignedId == 0 then
		return "Unassigned"
	end

	return "Extra Bar " .. tostring(assignedId - BTV.EXTRA_BAR_ID_START + 1)
end

-- Same 5 choices (Unassigned + Extra Bar 1-4) for every assignment row, so
-- the option list itself only ever needs building once. { value = 0 }
-- represents EXTRA_BAR_ASSIGNMENT_CYCLE's own "Unassigned" sentinel -
-- translated to/from a real nil only at RefreshValue/onSelect's own
-- BTVanillaDB read/write boundary below.
local function BuildExtraBarAssignmentDropdownOptions()
	local options = {}
	local i

	for i = 1, table.getn(EXTRA_BAR_ASSIGNMENT_CYCLE) do
		local rawValue = EXTRA_BAR_ASSIGNMENT_CYCLE[i]

		options[i] = {
			text = ExtraBarAssignmentLabel(rawValue ~= 0 and rawValue or nil),
			value = rawValue,
		}
	end

	return options
end

local EXTRA_BAR_ASSIGNMENT_DROPDOWN_OPTIONS = BuildExtraBarAssignmentDropdownOptions()

-- Builds one Extra Bar assignment row, styled to match the real native
-- dropdown the Profiles tab uses (BTV:CreateInlineDropdown) rather than
-- the old hand-built "< Extra Bar N >" cycle-button pair. dropdownName
-- must be a unique, stable global frame name (UIDropDownMenuTemplate's own
-- requirement - see BTV:CreateInlineDropdown's header comment); callers
-- pass one keyed off the row's stable identity (stance index / "page bar")
-- so repeated rebuilds re-use the same underlying frame. getFn must return
-- a raw BTVanillaDB value (a real Extra Bar id 6-9, or nil/false for
-- unassigned) - never the 0 sentinel, which is purely an internal
-- EXTRA_BAR_ASSIGNMENT_CYCLE/dropdown-options detail of this function.
local function CreateExtraBarAssignmentRow(parent, labelText, getFn, setFn, dropdownName)
	local row = CreateFrame("Frame", nil, parent)

	row:SetWidth(500)
	row:SetHeight(32)

	local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	label:SetPoint("LEFT", row, "LEFT", 0, 0)
	label:SetWidth(180)
	label:SetJustifyH("LEFT")
	label:SetText(labelText)

	local dropdown = BTV:CreateInlineDropdown(row, 140, dropdownName)

	dropdown:SetPoint("LEFT", label, "RIGHT", -8, -2)
	dropdown:SetOptions(EXTRA_BAR_ASSIGNMENT_DROPDOWN_OPTIONS)

	local function RefreshValue()
		local current = getFn() or 0

		dropdown:SetSelected(current, ExtraBarAssignmentLabel(current ~= 0 and current or nil))
	end

	dropdown.onSelect = function(value)
		-- Temporary diag print (UI redesign branch, stance/page dropdown
		-- investigation - /btv diag16) - remove once the bug is confirmed
		-- fixed live. The stack dump distinguishes a callback that came
		-- through the dropdown's own button (UIWidgets.lua's info.func,
		-- which prints its own line just before this one) from one invoked
		-- directly by something else entirely.
		BTV:Print("diag16: onSelect fired for " .. tostring(dropdownName) .. " value=" .. tostring(value))

		if debugstack then
			BTV:Print("diag16: onSelect caller -> " .. tostring(debugstack(2, 4, 0)))
		end

		setFn(value ~= 0 and value or nil)
		RefreshValue()
	end

	RefreshValue()

	-- Exposed so ApplyProfileLockGating can lock this dropdown too.
	row.dropdown = dropdown

	return row
end

-- Rebuilds the Main Bar (bar 1) settings page's Stance/Page Bar
-- Assignment rows from scratch (Part 2; relocated here from the General
-- tab in bug-fix batch round 4, Issue 5 - these settings are specific to
-- bar 1's own pagination/stance-swap behavior, not a general addon-wide
-- setting, so they belong on bar 1's own page alongside
-- mainBarPaginationEnabled/mainBarStanceSwapEnabled's OTHER live-gated
-- control, the Page Indicator Scale slider). One row per currently-active
-- stance (GetNumShapeshiftForms()) IF Stance/Form/Stealth Swapping is
-- currently enabled (0 rows if it's off, mirroring how the Page Bar row
-- below already only appears while pagination is on - previously the
-- stance rows ignored this toggle entirely and always showed whenever the
-- class had stances, regardless of whether stance-swapping itself was
-- enabled), plus one Page Bar row IF pagination is currently enabled. A
-- no-op if bar 1's settings page hasn't been built yet this session
-- (mirrors every other Refresh*/Apply* function's own
-- "settingsFrame[...] nil-check" tolerance). Called from
-- GetOrCreateBarPage's own RefreshBarSettingsPage(1) every time bar 1's
-- page is shown, from the pagination/stance-swap checkboxes' OnClick
-- (General tab), and from DefaultBars.lua's UPDATE_SHAPESHIFT_FORMS
-- handler.
function BTV:RebuildMainBarAssignmentRows()
	local page = settingsFrame and settingsFrame.pages[1]

	-- Temporary diag print (UI redesign branch, stance/page dropdown
	-- investigation - /btv diag16) - remove once the bug is confirmed
	-- fixed live.
	BTV:Print(
		"diag16: RebuildMainBarAssignmentRows called, page=" .. tostring(page ~= nil) ..
		" assignmentContainer=" .. tostring(page and page.assignmentContainer ~= nil)
	)

	if not page or not page.assignmentContainer then
		return
	end

	-- Force-close any open dropdown popout before tearing down/rebuilding
	-- the rows below - DropDownList1 is a single shared global popout, not
	-- owned per-dropdown, so a left-open one could otherwise still be
	-- sitting on screen referencing a row this rebuild is about to discard.
	if CloseDropDownMenus then
		CloseDropDownMenus()
	end

	-- Live diag (UI redesign branch, stance/page dropdown investigation -
	-- /btv diag16) proved CreateFrame does NOT actually return the same
	-- underlying frame object on this client when a name is reused - two
	-- consecutive rebuilds produced two DIFFERENT dropdown identities
	-- (confirmed via tostring() address) despite passing the identical
	-- name string both times, contradicting this function's own previous
	-- assumption (and UIDropDownMenuMixin's whole generation-tracking
	-- system, built on that assumption). Concretely: every rebuild was
	-- silently creating a brand new dropdown widget that just HAPPENED to
	-- share its predecessor's name - and native UIDropDownMenu_* code
	-- resolves its own sub-pieces (Text/Left/Middle/Right) via
	-- getglobal(self:GetName() .. "...") string lookups, so two different
	-- live frame objects both nominally answering to the same name is
	-- exactly the kind of collision that produces a fragmented skin/blank
	-- label - even though the OLD frame's own row was Hidden, its
	-- same-named regions were never actually a safe, non-colliding target
	-- for those lookups in the first place. Suffixing every dropdown name
	-- with a monotonic per-rebuild generation counter gives each rebuild's
	-- dropdowns (and their native sub-pieces) a name no earlier or later
	-- rebuild will ever reuse, closing the collision outright instead of
	-- relying on a reuse behavior that doesn't actually happen here.
	page.assignmentRebuildGeneration = (page.assignmentRebuildGeneration or 0) + 1

	local generationSuffix = "_" .. tostring(page.assignmentRebuildGeneration)

	local container = page.assignmentContainer
	local i

	for i = 1, table.getn(page.assignmentRows) do
		page.assignmentRows[i]:Hide()
		page.assignmentRows[i]:SetParent(nil)
	end

	page.assignmentRows = {}

	local rowIndex = 0
	local y = 0

	-- Issue 5 (bug-fix batch round 4): gated on mainBarStanceSwapEnabled
	-- now, matching the Page Bar row's own existing
	-- mainBarPaginationEnabled gate below - previously these rows ignored
	-- the Stance/Form/Stealth Swapping checkbox entirely.
	local stanceSwapOn = BTVanillaDB.mainBarStanceSwapEnabled ~= false
	local count = stanceSwapOn and GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

	if count and count > 0 then
		local s

		for s = 1, count do
			local icon, name = GetShapeshiftFormInfo(s)
			local label = (name and name ~= "" and name) or ("Stance " .. tostring(s))

			local row = CreateExtraBarAssignmentRow(
				container,
				label .. ":",
				function()
					return BTVanillaDB.mainBarStanceBarAssignment
						and BTVanillaDB.mainBarStanceBarAssignment[s]
				end,
				function(value)
					if not BTVanillaDB.mainBarStanceBarAssignment then
						BTVanillaDB.mainBarStanceBarAssignment = {}
					end

					BTVanillaDB.mainBarStanceBarAssignment[s] = value

					BTV:RefreshMainBarSlots()
				end,
				-- Named by stance index PLUS this rebuild's own generation
				-- (see the comment above this function's CloseDropDownMenus
				-- call) - a name is required (CreateExtraBarAssignmentRow's
				-- own dropdownName comment), but must be unique per rebuild,
				-- not stable across them.
				"BTVanillaMainBarStanceAssignmentDropdown" .. tostring(s) .. generationSuffix
			)

			row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y)

			rowIndex = rowIndex + 1
			page.assignmentRows[rowIndex] = row

			y = y - 34
		end
	end

	if BTVanillaDB.mainBarPaginationEnabled ~= false then
		local row = CreateExtraBarAssignmentRow(
			container,
			"Page 2 Content Source:",
			function()
				return BTVanillaDB.mainBarPageBarAssignment
			end,
			function(value)
				BTVanillaDB.mainBarPageBarAssignment = value

				BTV:RefreshMainBarSlots()
			end,
			"BTVanillaMainBarPageBarAssignmentDropdown" .. generationSuffix
		)

		row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y)

		rowIndex = rowIndex + 1
		page.assignmentRows[rowIndex] = row

		y = y - 34
	end

	-- Never 0 - a zero-height frame is a harmless but needless edge case
	-- for the live BOTTOMLEFT anchor chain hotkeyTitle depends on
	-- (GetOrCreateGeneralPanel's own comment) when nothing rendered at all
	-- (no stances, pagination off).
	local height = -y

	if height < 1 then
		height = 1
	end

	container:SetHeight(height)
end

function BTV:GetOrCreateGeneralPanel()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	if settingsFrame.generalPanel then
		return settingsFrame.generalPanel
	end

	-- Own dedicated scrollframe+scrollchild pair (BTV:CreateWideContentScrollFrame)
	-- - see CreateSettingsFrame's own comment on why this doesn't share
	-- the Bars view's contentScrollFrame.
	local scrollFrame, panel = BTV:CreateWideContentScrollFrame("BTVanillaSettingsGeneralScrollFrame")

	settingsFrame.generalScrollFrame = scrollFrame
	scrollFrame:Hide()

	local title = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalLarge"
	)

	title:SetPoint(
		"TOPLEFT",
		panel,
		"TOPLEFT",
		INDENT_SECTION,
		-14
	)

	title:SetText("General Settings")

	local checkbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralUseDefaultLayoutCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	checkbox:SetWidth(24)
	checkbox:SetHeight(24)

	checkbox:SetPoint(
		"TOPLEFT",
		panel,
		"TOPLEFT",
		INDENT_SECTION,
		-52
	)

	checkbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false
			local wasDefault = BTVanillaDB.useDefaultLayout == true

			BTVanillaDB.useDefaultLayout = checked

			-- Re-gate any default-bar page already built/cached so it
			-- reflects the new state immediately if it happens to be
			-- visible (or gets shown next) without needing a reload.
			BTV:RefreshDefaultLayoutGatingOnAllPages()

			-- Idempotent when the saved cfg values themselves haven't
			-- changed (only interactivity changed) - safe/cheap to call
			-- unconditionally so bars are guaranteed visually in sync
			-- rather than only catching up on next login.
			if BTV.ApplyAllDefaultBars then
				BTV:ApplyAllDefaultBars()
			end

			-- Issue 3 (bug-fix batch): useDefaultLayout changes whether
			-- dragging is currently possible (BTV:CanDragDefaultLayout())
			-- even when edit mode's own state hasn't changed, so the
			-- default-bar/stance-bar overlays need their own refresh here
			-- too, not just from ApplyEditModeVisual's call sites.
			if BTV.ApplyDefaultLayoutEditVisual then
				BTV:ApplyDefaultLayoutEditVisual()
			end

			-- Stance Bar (chain-anchored container migration): no longer
			-- has any special-cased handling here - it's now an
			-- unconditionally-positioned TrustyBars-owned container
			-- exactly like Bag Bar/Micro Menu (see
			-- BTV:CreateStanceBarContainer's PLAYER_LOGIN placement,
			-- Core.lua), so switching OFF doesn't need to capture/apply
			-- anything (its position is always live), and switching back
			-- ON is handled by the same reset cascade below as Bag Bar/
			-- Micro Menu/Latency Bar/Key Ring, rather than a
			-- ShapeshiftBar_UpdatePosition() native-reconciliation call.
			if (not wasDefault) and checked then
				-------------------------------------------------------------
				-- Bug-fix batch Fix 5: full reset-to-Blizzard-default
				-- cascade. Switching back to true previously left every
				-- default bar, INCLUDING bar 1, wherever the user had last
				-- dragged/resized/spaced it instead of actually restoring
				-- Blizzard's own defaults, as the checkbox's own
				-- description promises - ApplyAllDefaultBars/
				-- ApplyDefaultLayoutEditVisual above only re-apply shape
				-- from whatever cfg currently holds, they do NOT reset cfg
				-- back to its native values the way ResetDefaultBarLayout
				-- does (live-tested: bar 1 needed its own "Reset to
				-- Blizzard Default" button clicked manually before this
				-- fix). The Bag Bar/Micro Menu/Latency Bar/Key Ring/Stance
				-- Bar elements never had ANY reset wired to this toggle at
				-- all either.
				-------------------------------------------------------------

				local id

				for id = 1, 5 do
					BTV:ResetDefaultBarLayout(id)
				end

				if BTV.ResetBagBarPosition then
					BTV:ResetBagBarPosition()
				end

				if BTV.ResetBagBarLayout then
					BTV:ResetBagBarLayout()
				end

				if BTV.ResetMicroMenuPosition then
					BTV:ResetMicroMenuPosition()
				end

				if BTV.ResetMicroMenuLayout then
					BTV:ResetMicroMenuLayout()
				end

				if BTV.ResetStanceBarPosition then
					BTV:ResetStanceBarPosition()
				end

				if BTV.ResetStanceBarLayout then
					BTV:ResetStanceBarLayout()
				end

				if BTV.ResetLatencyBarLayout then
					BTV:ResetLatencyBarLayout()
				end

				if BTV.ResetKeyRingPosition then
					BTV:ResetKeyRingPosition()
				end

				-- Experience Bar (round 16 part 2, Part A): same reset
				-- treatment as every other single-native-frame element above.
				if BTV.ResetExpBarLayout then
					BTV:ResetExpBarLayout()
				end

				-- Issue 4 (bug-fix batch round 5): Page Indicator was never
				-- added to this cascade when its container shipped - see
				-- BTV:ResetPageIndicatorLayout's own comment (DefaultBars.lua).
				if BTV.ResetPageIndicatorLayout then
					BTV:ResetPageIndicatorLayout()
				end

				-- Re-syncs every already-built default/simple bar page's
				-- sliders/checkboxes from the values the resets above just
				-- wrote - the earlier RefreshDefaultLayoutGatingOnAllPages
				-- call in this handler ran BEFORE these resets, so it only
				-- caught up gating/alpha, not the underlying values.
				BTV:RefreshDefaultLayoutGatingOnAllPages()
			end

			-- Runs LAST, after any reset cascade above, so bars 1-5 are
			-- already at their true native values by the time this reads
			-- them - re-evaluates BTV:IsVanillaBorderStyle() live: turning
			-- this ON forces every bar back to vanilla styling (skipping
			-- bars 1-5, already handled by the reset cascade above -
			-- see ApplyGlobalButtonStyle's own skipDefaultBars comment);
			-- turning it OFF re-applies whatever modernBorderStyle is
			-- currently stored instead of leaving bars showing the
			-- forced-vanilla look until next login.
			BTV:ApplyGlobalButtonStyle()

			-- The global spacing/buttonSize overrides both no-op while
			-- useDefaultLayout is on (Bar.lua) - re-running them here
			-- means turning it back OFF immediately re-applies a
			-- previously-locked-out override instead of waiting for the
			-- next slider move.
			BTV:ApplyGlobalSpacing()
			BTV:ApplyGlobalButtonSize()

			-- Updates the new "Use Modern Button Style" checkbox's own
			-- checked/grey-out state immediately (RefreshGeneralPanel
			-- isn't otherwise called from this handler) so it reflects
			-- the lock the moment useDefaultLayout changes, without
			-- needing to leave and reopen the General tab.
			BTV:RefreshGeneralPanel()

			BTV:RefreshAllBarPagesGlobalOverrideGating()
		end
	)

	local checkboxLabel = getglobal(checkbox:GetName() .. "Text")

	if checkboxLabel then
		checkboxLabel:SetText("Use Default Blizzard Layout")
	end

	panel.useDefaultLayoutCheckbox = checkbox

	local description = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontHighlightSmall"
	)

	description:SetPoint(
		"TOPLEFT",
		checkbox,
		"BOTTOMLEFT",
		4,
		-10
	)

	description:SetWidth(520)
	description:SetJustifyH("LEFT")

	description:SetText(
		"When enabled, default action bars keep Blizzard's native " ..
		"position, size, and layout, and can only be shown/hidden - " ..
		"dragging and resizing them is disabled. Disable this to " ..
		"freely reposition, resize, and drag default bars like custom " ..
		"bars."
	)

	panel.description = description

	-------------------------------------------------------------------------
	-- Tint whole button on out of range
	--
	-- Real Blizzard action buttons only tint the HOTKEY TEXT red on out-of-
	-- range, never the whole icon - this addon has always tinted the whole
	-- icon instead (BTVanillaDB.tintWholeButtonOnRange, default true - see
	-- Core.lua's EnsureDB), so this checkbox lets users opt into the
	-- native-accurate hotkey-only behavior instead. Styled/positioned
	-- exactly like the "Use Default Blizzard Layout" checkbox above -
	-- same UICheckButtonTemplate, anchored off the previous section's
	-- description text the same BOTTOMLEFT-chain way.
	-------------------------------------------------------------------------

	local tintWholeButtonCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralTintWholeButtonCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	tintWholeButtonCheckbox:SetWidth(24)
	tintWholeButtonCheckbox:SetHeight(24)

	tintWholeButtonCheckbox:SetPoint(
		"TOPLEFT",
		description,
		"BOTTOMLEFT",
		-4,
		-14
	)

	tintWholeButtonCheckbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false

			BTVanillaDB.tintWholeButtonOnRange = checked

			-- Live: immediately re-sweeps every live button's range/
			-- usability tint rather than waiting on the next natural
			-- UpdateRange trigger (the 0.2s self-healing ticker or the
			-- next real event) - mirrors BTV:ToggleAlwaysShowMultibars'
			-- own immediate-sweep pattern (Button.lua) rather than this
			-- toggle silently doing nothing until something else happens
			-- to re-run UpdateRange.
			BTV:SweepAllButtonRangeTint()
		end
	)

	local tintWholeButtonLabel = getglobal(
		tintWholeButtonCheckbox:GetName() .. "Text"
	)

	if tintWholeButtonLabel then
		tintWholeButtonLabel:SetText("Tint whole button on out of range")
	end

	panel.tintWholeButtonCheckbox = tintWholeButtonCheckbox

	-------------------------------------------------------------------------
	-- Disable Blizzard Art (feature 1)
	--
	-- Hides MainMenuBarArtFrame (DefaultBars.lua's
	-- ApplyBlizzardArtVisibility) - styled/positioned exactly like the two
	-- checkboxes above, anchored off tintWholeButtonCheckbox the same
	-- BOTTOMLEFT-chain way.
	-------------------------------------------------------------------------

	local disableBlizzardArtCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralDisableBlizzardArtCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	disableBlizzardArtCheckbox:SetWidth(24)
	disableBlizzardArtCheckbox:SetHeight(24)

	disableBlizzardArtCheckbox:SetPoint(
		"TOPLEFT",
		tintWholeButtonCheckbox,
		"BOTTOMLEFT",
		0,
		-14
	)

	disableBlizzardArtCheckbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false

			BTVanillaDB.disableBlizzardArt = checked

			BTV:ApplyBlizzardArtVisibility()
		end
	)

	local disableBlizzardArtLabel = getglobal(
		disableBlizzardArtCheckbox:GetName() .. "Text"
	)

	if disableBlizzardArtLabel then
		disableBlizzardArtLabel:SetText("Disable Blizzard Art")
	end

	panel.disableBlizzardArtCheckbox = disableBlizzardArtCheckbox

	-------------------------------------------------------------------------
	-- Main Bar pagination / stance-swap (Main Bar migration, Parts 2/3)
	--
	-- Both default true (Core.lua's EnsureDB), matching real vanilla bar
	-- 1's own always-on behavior unless the user explicitly opts out here.
	-- Styled/positioned exactly like the three checkboxes above, chained
	-- off disableBlizzardArtCheckbox the same BOTTOMLEFT way.
	-------------------------------------------------------------------------

	local mainBarPaginationCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralMainBarPaginationCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	mainBarPaginationCheckbox:SetWidth(24)
	mainBarPaginationCheckbox:SetHeight(24)

	mainBarPaginationCheckbox:SetPoint(
		"TOPLEFT",
		disableBlizzardArtCheckbox,
		"BOTTOMLEFT",
		0,
		-14
	)

	mainBarPaginationCheckbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false

			BTV:SetMainBarPaginationEnabled(checked)

			-- Stance/Page Bar Assignment feature, Part 2/4: the Page Bar
			-- assignment row (only meaningful while pagination is on) and
			-- bar 1's own Page Indicator Scale slider both need to appear/
			-- disappear live the instant this checkbox is clicked, without
			-- requiring the General tab or bar 1's page to be closed and
			-- reopened.
			BTV:RebuildMainBarAssignmentRows()
			BTV:RefreshMainBarPageIndicatorControlsVisibility()
		end
	)

	local mainBarPaginationLabel = getglobal(
		mainBarPaginationCheckbox:GetName() .. "Text"
	)

	if mainBarPaginationLabel then
		mainBarPaginationLabel:SetText("Main Bar: Shift/Ctrl Page Swapping")
	end

	panel.mainBarPaginationCheckbox = mainBarPaginationCheckbox

	local mainBarStanceSwapCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralMainBarStanceSwapCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	mainBarStanceSwapCheckbox:SetWidth(24)
	mainBarStanceSwapCheckbox:SetHeight(24)

	mainBarStanceSwapCheckbox:SetPoint(
		"TOPLEFT",
		mainBarPaginationCheckbox,
		"BOTTOMLEFT",
		0,
		-14
	)

	mainBarStanceSwapCheckbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false

			BTV:SetMainBarStanceSwapEnabled(checked)

			-- Issue 5 (bug-fix batch round 4): the per-stance assignment
			-- rows (bar 1's own settings page) need to appear/disappear
			-- live the instant this checkbox is clicked, exactly like the
			-- pagination checkbox above already does for the Page Bar row.
			BTV:RebuildMainBarAssignmentRows()
		end
	)

	local mainBarStanceSwapLabel = getglobal(
		mainBarStanceSwapCheckbox:GetName() .. "Text"
	)

	if mainBarStanceSwapLabel then
		mainBarStanceSwapLabel:SetText("Main Bar: Stance/Form/Stealth Swapping")
	end

	panel.mainBarStanceSwapCheckbox = mainBarStanceSwapCheckbox

	local mainBarStanceSwapDescription = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontHighlightSmall"
	)

	mainBarStanceSwapDescription:SetPoint(
		"TOPLEFT",
		mainBarStanceSwapCheckbox,
		"BOTTOMLEFT",
		4,
		-10
	)

	mainBarStanceSwapDescription:SetWidth(520)
	mainBarStanceSwapDescription:SetJustifyH("LEFT")

	-- Part 5's own slot-allocator documentation note (per the migration
	-- plan) - the real vanilla stance/form/stealth bonus pages (7-9,
	-- slots 73-108) are the SAME "free" range a custom bar (id 6+) can
	-- draw from, so a stance-capable class with this toggle on may see a
	-- custom bar's content coincide with this bar while shapeshifted -
	-- see Bar.lua's GetNextFreeSlotStart, which already prefers slots
	-- 109-120 first for exactly this reason.
	mainBarStanceSwapDescription:SetText(
		"Stance/Form/Stealth Swapping shares its action-slot range " ..
		"(73-108) with custom bars 6+. New custom bars are allocated " ..
		"from slots 109-120 first to avoid this, falling back to " ..
		"73-108 only once that range is full."
	)

	panel.mainBarStanceSwapDescription = mainBarStanceSwapDescription

	-- Stance / Page Bar Assignment rows - RELOCATED (bug-fix batch round 4,
	-- Issue 5) to bar 1's own settings page (GetOrCreateBarPage/
	-- RebuildMainBarAssignmentRows) - these are bar 1-specific settings, not
	-- general addon-wide ones, so they now live alongside that page's Page
	-- Indicator Scale slider instead of here. The two checkboxes above
	-- still live on this General tab (unchanged) and still drive those rows
	-- live via BTV:RebuildMainBarAssignmentRows, which now looks up bar 1's
	-- page instead of this panel.

	-------------------------------------------------------------------------
	-- Hotkey / Count text font size (both bars, live sliders)
	--
	-- Global, not per-button (Button.lua's hasCapturedFontDefaults comment)
	-- - one setting governs every button's hotkey/count text on every bar.
	-- Mirrors a bar page's Button Size slider exactly: built-in label just
	-- names the control, a live centered value readout below it, integer
	-- min/max end captions, OnValueChanged applies immediately (no Apply-
	-- button gating, matching the rest of this rebuilt Settings UI). A
	-- "Reset to Default" button sits to the right of each slider, restoring
	-- the captured native size (Button.lua's BTV.NATIVE_HOTKEY_FONT/
	-- NATIVE_COUNT_FONT).
	--
	-- Anchored via a real anchor chain off the tint-whole-button checkbox
	-- above (BOTTOMLEFT -> TOPLEFT), not a computed pixel-Y offset like the
	-- bar pages use - description's actual height depends on how its
	-- 520px-wide sentence wraps, which isn't knowable at build time, so
	-- anchor-chaining lets this section follow wherever the checkbox's real
	-- bottom edge lands instead of guessing a fixed Y.
	-------------------------------------------------------------------------

	local hotkeyTitle = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormal"
	)

	-- Anchored to mainBarStanceSwapDescription's BOTTOMLEFT - the Stance/
	-- Page Bar Assignment rows that used to sit between these two
	-- (RebuildMainBarAssignmentRows) moved to bar 1's own settings page in
	-- bug-fix batch round 4 (Issue 5), so this anchor chain is back to a
	-- direct link between the two General-tab elements.
	hotkeyTitle:SetPoint(
		"TOPLEFT",
		mainBarStanceSwapDescription,
		"BOTTOMLEFT",
		4,
		-22
	)

	hotkeyTitle:SetText(
		"Hotkey Text Size (" .. tostring(FONT_SIZE_MIN) ..
		" to " .. tostring(FONT_SIZE_MAX) .. ")"
	)

	local hotkeySlider = CreateSettingSlider(
		panel,
		"BTVanillaGeneralHotkeyFontSizeSlider",
		260
	)

	hotkeySlider:SetPoint(
		"TOPLEFT",
		hotkeyTitle,
		"BOTTOMLEFT",
		INDENT_INPUT - INDENT_SECTION,
		-12
	)

	hotkeySlider:SetMinMaxValues(
		FONT_SIZE_MIN,
		FONT_SIZE_MAX
	)

	hotkeySlider:SetValueStep(FONT_SIZE_STEP)

	SetSliderLabel(hotkeySlider, "Hotkey Text Size")

	local hotkeySliderLow = getglobal(hotkeySlider:GetName() .. "Low")

	if hotkeySliderLow then
		hotkeySliderLow:SetText(tostring(FONT_SIZE_MIN))
	end

	local hotkeySliderHigh = getglobal(hotkeySlider:GetName() .. "High")

	if hotkeySliderHigh then
		hotkeySliderHigh:SetText(tostring(FONT_SIZE_MAX))
	end

	local hotkeyValueText = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	hotkeyValueText:SetPoint(
		"TOP",
		hotkeySlider,
		"BOTTOM",
		0,
		-2
	)

	-- Placeholder only - RefreshGeneralPanel (called by ShowGeneralView
	-- every time this view is shown) overwrites this with the real saved/
	-- native value before the panel is ever visible.
	hotkeyValueText:SetText(tostring(FONT_SIZE_MIN))

	panel.hotkeyValueText = hotkeyValueText

	hotkeySlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			hotkeyValueText:SetText(tostring(value))

			if not this.suppressApply then
				BTV:SetHotkeyFontSize(value)
			end
		end
	)

	panel.hotkeySlider = hotkeySlider

	local hotkeyResetButton = CreateFrame(
		"Button",
		nil,
		panel
	)

	hotkeyResetButton:SetHeight(22)

	hotkeyResetButton:SetPoint(
		"LEFT",
		hotkeySlider,
		"RIGHT",
		16,
		4
	)

	BTV:StyleModernButton(hotkeyResetButton, 90, 90)
	hotkeyResetButton:SetText("Reset")

	hotkeyResetButton:SetScript(
		"OnClick",
		function()
			-- Nothing captured yet (no button created this session) - no
			-- native size to restore to, so this is a no-op rather than a
			-- guessed fallback value.
			if not BTV.NATIVE_HOTKEY_FONT then
				return
			end

			-- ClampFontSize rounds (Fix 2) as well as clamps, so this
			-- Reset button's displayed text can never show the same raw
			-- GetFont()-precision decimal the bug report described.
			local size = ClampFontSize(BTV.NATIVE_HOTKEY_FONT.size)

			BTV:SetHotkeyFontSize(size)

			panel.hotkeySlider.suppressApply = true
			panel.hotkeySlider:SetValue(size)
			panel.hotkeyValueText:SetText(tostring(size))
			panel.hotkeySlider.suppressApply = nil
		end
	)

	panel.hotkeyResetButton = hotkeyResetButton

	-------------------------------------------------------------------------
	-- Count text font size - identical structure to Hotkey Text Size above,
	-- anchored off it the same anchor-chain way.
	-------------------------------------------------------------------------

	local countTitle = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormal"
	)

	-- Fix 1 (bug-fix batch): previously anchored off hotkeyValueText's
	-- BOTTOMLEFT, but hotkeyValueText uses a "TOP" anchor point (centered
	-- under hotkeySlider - see its SetPoint above), so its LEFT edge shifts
	-- with the displayed digit count/width instead of sitting at a fixed X.
	-- That's what caused the whole Item Count block to drift right of the
	-- Hotkey block above it. Anchored off hotkeyTitle instead (a plain
	-- TOPLEFT-anchored FontString with a fixed, text-width-independent left
	-- edge), with 0 X offset so both titles - and everything anchored off
	-- them below (sliders, Reset buttons) - share exactly the same X. The Y
	-- offset is computed rather than hardcoded, preserving the original
	-- title -> slider -> value-text -> gap spacing exactly (12px title-to-
	-- slider gap, the slider's own real height, 2px slider-to-valuetext
	-- gap, the value text's own real height, then the original 18px gap to
	-- this title) without guessing GameFontNormalSmall's pixel height.
	countTitle:SetPoint(
		"TOPLEFT",
		hotkeyTitle,
		"BOTTOMLEFT",
		0,
		-12 - hotkeySlider:GetHeight() - 2 - hotkeyValueText:GetHeight() - 18
	)

	countTitle:SetText(
		"Item Count Text Size (" .. tostring(FONT_SIZE_MIN) ..
		" to " .. tostring(FONT_SIZE_MAX) .. ")"
	)

	local countSlider = CreateSettingSlider(
		panel,
		"BTVanillaGeneralCountFontSizeSlider",
		260
	)

	countSlider:SetPoint(
		"TOPLEFT",
		countTitle,
		"BOTTOMLEFT",
		INDENT_INPUT - INDENT_SECTION,
		-12
	)

	countSlider:SetMinMaxValues(
		FONT_SIZE_MIN,
		FONT_SIZE_MAX
	)

	countSlider:SetValueStep(FONT_SIZE_STEP)

	SetSliderLabel(countSlider, "Item Count Text Size")

	local countSliderLow = getglobal(countSlider:GetName() .. "Low")

	if countSliderLow then
		countSliderLow:SetText(tostring(FONT_SIZE_MIN))
	end

	local countSliderHigh = getglobal(countSlider:GetName() .. "High")

	if countSliderHigh then
		countSliderHigh:SetText(tostring(FONT_SIZE_MAX))
	end

	local countValueText = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalSmall"
	)

	countValueText:SetPoint(
		"TOP",
		countSlider,
		"BOTTOM",
		0,
		-2
	)

	countValueText:SetText(tostring(FONT_SIZE_MIN))

	panel.countValueText = countValueText

	countSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			countValueText:SetText(tostring(value))

			if not this.suppressApply then
				BTV:SetCountFontSize(value)
			end
		end
	)

	panel.countSlider = countSlider

	local countResetButton = CreateFrame(
		"Button",
		nil,
		panel
	)

	countResetButton:SetHeight(22)

	countResetButton:SetPoint(
		"LEFT",
		countSlider,
		"RIGHT",
		16,
		4
	)

	BTV:StyleModernButton(countResetButton, 90, 90)
	countResetButton:SetText("Reset")

	countResetButton:SetScript(
		"OnClick",
		function()
			if not BTV.NATIVE_COUNT_FONT then
				return
			end

			-- ClampFontSize rounds (Fix 2) as well as clamps - see the
			-- Hotkey Reset button's matching comment above.
			local size = ClampFontSize(BTV.NATIVE_COUNT_FONT.size)

			BTV:SetCountFontSize(size)

			panel.countSlider.suppressApply = true
			panel.countSlider:SetValue(size)
			panel.countValueText:SetText(tostring(size))
			panel.countSlider.suppressApply = nil
		end
	)

	panel.countResetButton = countResetButton

	-------------------------------------------------------------------------
	-- Snap to Adjacent Elements (round 35)
	--
	-- BTVanillaDB.snapToAdjacentElements (default false, Core.lua's
	-- EnsureDB) - gates BOTH of this addon's snap injection points
	-- (Bar.lua's StopBarDrag drop-time snap, DefaultBars.lua's live
	-- OnUpdate-driven snap) via the single shared BTV:ComputeSnapAdjustment
	-- utility, which reads this field directly - no separate Apply/refresh
	-- call is needed here the way disableBlizzardArtCheckbox's OnClick
	-- needs one, since this setting only ever affects the NEXT drag, never
	-- anything already on screen.
	--
	-- Styled/positioned like the two font-size sections above, but
	-- anchored via a real anchor chain off countTitle (a fixed-X FontString,
	-- same Fix-1 reasoning as countTitle's own anchor off hotkeyTitle above)
	-- rather than off countResetButton/countValueText directly - countValueText
	-- uses a "TOP" anchor (centered under countSlider), so its LEFT edge
	-- shifts with the displayed digit count/width exactly like
	-- hotkeyValueText's did (see countTitle's own comment).
	-------------------------------------------------------------------------

	local snapToAdjacentCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralSnapToAdjacentCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	snapToAdjacentCheckbox:SetWidth(24)
	snapToAdjacentCheckbox:SetHeight(24)

	snapToAdjacentCheckbox:SetPoint(
		"TOPLEFT",
		countTitle,
		"BOTTOMLEFT",
		0,
		-12 - countSlider:GetHeight() - 2 - countValueText:GetHeight() - 18
	)

	snapToAdjacentCheckbox:SetScript(
		"OnClick",
		function()
			local checked = this:GetChecked() and true or false

			BTVanillaDB.snapToAdjacentElements = checked
		end
	)

	local snapToAdjacentLabel = getglobal(
		snapToAdjacentCheckbox:GetName() .. "Text"
	)

	if snapToAdjacentLabel then
		snapToAdjacentLabel:SetText("Snap to Adjacent Elements")
	end

	panel.snapToAdjacentCheckbox = snapToAdjacentCheckbox

	local snapToAdjacentDescription = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontHighlightSmall"
	)

	snapToAdjacentDescription:SetPoint(
		"TOPLEFT",
		snapToAdjacentCheckbox,
		"BOTTOMLEFT",
		4,
		-10
	)

	snapToAdjacentDescription:SetWidth(520)
	snapToAdjacentDescription:SetJustifyH("LEFT")

	snapToAdjacentDescription:SetText(
		"When enabled, elements moved in Edit Layout Mode snap to nearby " ..
		"screen edges/corners and to adjacent elements' edges for pixel-" ..
		"perfect alignment and stacking."
	)

	panel.snapToAdjacentDescription = snapToAdjacentDescription

	-------------------------------------------------------------------------
	-- Global border/spacing style (default bars vs. extra bars alignment)
	--
	-- One global checkbox choosing the button border style used by ALL
	-- bars (default 1-5 AND extra 6-9): "modern" (today's Extra Bar look
	-- - backdrop border) or "vanilla" (today's default bar look - native
	-- Blizzard border). Also shifts every bar's button size (and real
	-- spacing, in the opposite direction, keeping the two visually in
	-- sync) so default and extra bars stay aligned - see
	-- BTV:ApplyGlobalButtonStyle (Bar.lua). Locked to vanilla while "Use
	-- Default Blizzard Layout" is on (BTV:IsVanillaBorderStyle, Core.lua).
	-------------------------------------------------------------------------

	local modernBorderStyleCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralModernBorderStyleCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	modernBorderStyleCheckbox:SetWidth(24)
	modernBorderStyleCheckbox:SetHeight(24)

	modernBorderStyleCheckbox:SetPoint(
		"TOPLEFT",
		snapToAdjacentDescription,
		"BOTTOMLEFT",
		-4,
		-14
	)

	modernBorderStyleCheckbox:SetScript(
		"OnClick",
		function()
			-- Belt-and-suspenders re-check, mirrors this addon's existing
			-- convention (e.g. Button.lua's OnMouseWheel re-checking
			-- useDefaultLayout) - RefreshGeneralPanel's own gating below
			-- is what actually prevents this OnClick from firing in the
			-- normal case (EnableMouse(false) while locked).
			if BTVanillaDB.useDefaultLayout ~= false then
				this:SetChecked(false)
				return
			end

			BTVanillaDB.modernBorderStyle = this:GetChecked() and true or false

			BTV:ApplyGlobalButtonStyle()

			-- The global spacing/buttonSize overrides' last-applied real
			-- value was computed under whatever style was active at the
			-- time - re-run them now so a switch immediately recomputes
			-- for the new style's floor, instead of staying stale until
			-- the global slider itself is next touched.
			BTV:ApplyGlobalSpacing()
			BTV:ApplyGlobalButtonSize()

			BTV:RefreshDefaultLayoutGatingOnAllPages()

			-- Re-syncs the global spacing slider's displayed value/range/
			-- labels to the new floor (RefreshGeneralPanel wasn't
			-- otherwise called from this handler).
			BTV:RefreshGeneralPanel()
		end
	)

	local modernBorderStyleLabel = getglobal(
		modernBorderStyleCheckbox:GetName() .. "Text"
	)

	if modernBorderStyleLabel then
		modernBorderStyleLabel:SetText("Use Modern Button Style")
	end

	panel.modernBorderStyleCheckbox = modernBorderStyleCheckbox

	local modernBorderStyleDescription = panel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontHighlightSmall"
	)

	modernBorderStyleDescription:SetPoint(
		"TOPLEFT",
		modernBorderStyleCheckbox,
		"BOTTOMLEFT",
		4,
		-10
	)

	modernBorderStyleDescription:SetWidth(520)
	modernBorderStyleDescription:SetJustifyH("LEFT")

	modernBorderStyleDescription:SetText(
		"Choose the button border style used by ALL bars, default and " ..
		"extra: modern (backdrop border, today's Extra Bar look) or " ..
		"vanilla (native Blizzard border, today's default bar look). " ..
		"Also adjusts every bar's button size to match, keeping visual " ..
		"spacing consistent. Locked to vanilla while \"Use Default " ..
		"Blizzard Layout\" is enabled."
	)

	panel.modernBorderStyleDescription = modernBorderStyleDescription

	-------------------------------------------------------------------------
	-- Global Spacing / global ButtonSize overrides
	--
	-- Unlike every other control in this panel, these two sliders are
	-- Shown/Hidden (not just dimmed) per the checkbox's own checked state,
	-- per the user's explicit spec - the first such reveal pattern in this
	-- file. Applies to every true action bar (default 1-5 + extra 6-9)
	-- ONLY, never the simple bars (Bag Bar/Micro Menu/etc.) - see
	-- BTV:ApplyGlobalSpacing/ApplyGlobalButtonSize (Bar.lua), which iterate
	-- BTV.bars (simple bars are never in it). Both also lock (dim idiom)
	-- whenever useDefaultLayout forces vanilla styling, same as
	-- modernBorderStyleCheckbox above - see the gating block in
	-- RefreshGeneralPanel.
	-------------------------------------------------------------------------

	local globalSpacingCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralGlobalSpacingCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	globalSpacingCheckbox:SetWidth(24)
	globalSpacingCheckbox:SetHeight(24)

	globalSpacingCheckbox:SetPoint(
		"TOPLEFT",
		modernBorderStyleDescription,
		"BOTTOMLEFT",
		-4,
		-14
	)

	local globalSpacingSlider = CreateSettingSlider(
		panel,
		"BTVanillaGeneralGlobalSpacingSlider",
		290
	)

	globalSpacingSlider:SetPoint(
		"TOPLEFT",
		globalSpacingCheckbox,
		"BOTTOMLEFT",
		20,
		-28
	)

	globalSpacingSlider:SetValueStep(SPACING_STEP)
	SetSliderLabel(globalSpacingSlider, "Global Spacing")

	local globalSpacingSliderLow = getglobal(globalSpacingSlider:GetName() .. "Low")
	local globalSpacingSliderHigh = getglobal(globalSpacingSlider:GetName() .. "High")

	local globalSpacingValueText = panel:CreateFontString(
		nil, "OVERLAY", "GameFontNormalSmall"
	)

	globalSpacingValueText:SetPoint("TOP", globalSpacingSlider, "BOTTOM", 0, -2)
	globalSpacingValueText:SetText("0")

	globalSpacingSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			globalSpacingValueText:SetText(tostring(value))

			if not this.suppressApply then
				BTVanillaDB.globalSpacingValue = value
				BTV:ApplyGlobalSpacing()
			end
		end
	)

	globalSpacingCheckbox:SetScript(
		"OnClick",
		function()
			if BTVanillaDB.useDefaultLayout ~= false then
				this:SetChecked(false)
				return
			end

			local checked = this:GetChecked() and true or false

			BTVanillaDB.globalSpacingEnabled = checked

			globalSpacingSlider:SetShown(checked)
			globalSpacingValueText:SetShown(checked)

			if checked then
				BTV:ApplyGlobalSpacing()
			end

			BTV:ReflowGeneralOverrideSliders(panel)
			BTV:RefreshAllBarPagesGlobalOverrideGating()
		end
	)

	local globalSpacingLabel = getglobal(globalSpacingCheckbox:GetName() .. "Text")

	if globalSpacingLabel then
		globalSpacingLabel:SetText("Toggle global Spacing")
	end

	panel.globalSpacingCheckbox = globalSpacingCheckbox
	panel.globalSpacingSlider = globalSpacingSlider
	panel.globalSpacingSliderLow = globalSpacingSliderLow
	panel.globalSpacingSliderHigh = globalSpacingSliderHigh
	panel.globalSpacingValueText = globalSpacingValueText

	local globalButtonSizeCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralGlobalButtonSizeCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	globalButtonSizeCheckbox:SetWidth(24)
	globalButtonSizeCheckbox:SetHeight(24)

	-- Anchored off globalSpacingSlider itself (a reliable left edge), NOT
	-- globalSpacingValueText - that FontString only has a bare "TOP"
	-- anchor, so it auto-centers under the slider and its BOTTOMLEFT sits
	-- near the slider's horizontal CENTER, not its left edge (this used
	-- to make this checkbox render indented instead of left-aligned).
	-- The -20 x-offset cancels globalSpacingSlider's own +20 offset from
	-- ITS checkbox, landing this checkbox back in the same left column.
	globalButtonSizeCheckbox:SetPoint(
		"TOPLEFT",
		globalSpacingSlider,
		"BOTTOMLEFT",
		-20,
		-26
	)

	local globalButtonSizeSlider = CreateSettingSlider(
		panel,
		"BTVanillaGeneralGlobalButtonSizeSlider",
		290
	)

	globalButtonSizeSlider:SetPoint(
		"TOPLEFT",
		globalButtonSizeCheckbox,
		"BOTTOMLEFT",
		20,
		-28
	)

	globalButtonSizeSlider:SetMinMaxValues(BUTTON_SIZE_MIN, BUTTON_SIZE_MAX)
	globalButtonSizeSlider:SetValueStep(1)
	SetSliderLabel(globalButtonSizeSlider, "Global Button Size")

	local globalButtonSizeSliderLow = getglobal(globalButtonSizeSlider:GetName() .. "Low")

	if globalButtonSizeSliderLow then
		globalButtonSizeSliderLow:SetText(tostring(BUTTON_SIZE_MIN))
	end

	local globalButtonSizeSliderHigh = getglobal(globalButtonSizeSlider:GetName() .. "High")

	if globalButtonSizeSliderHigh then
		globalButtonSizeSliderHigh:SetText(tostring(BUTTON_SIZE_MAX))
	end

	local globalButtonSizeValueText = panel:CreateFontString(
		nil, "OVERLAY", "GameFontNormalSmall"
	)

	globalButtonSizeValueText:SetPoint("TOP", globalButtonSizeSlider, "BOTTOM", 0, -2)
	globalButtonSizeValueText:SetText(tostring(BTV.BUTTON_SIZE))

	globalButtonSizeSlider:SetScript(
		"OnValueChanged",
		function()
			local value = this:GetValue()

			if not value then
				return
			end

			value = math.floor(value + 0.5)

			globalButtonSizeValueText:SetText(tostring(value))

			if not this.suppressApply then
				BTVanillaDB.globalButtonSizeValue = value
				BTV:ApplyGlobalButtonSize()
			end
		end
	)

	globalButtonSizeCheckbox:SetScript(
		"OnClick",
		function()
			if BTVanillaDB.useDefaultLayout ~= false then
				this:SetChecked(false)
				return
			end

			local checked = this:GetChecked() and true or false

			BTVanillaDB.globalButtonSizeEnabled = checked

			globalButtonSizeSlider:SetShown(checked)
			globalButtonSizeValueText:SetShown(checked)

			if checked then
				BTV:ApplyGlobalButtonSize()
			end

			BTV:ReflowGeneralOverrideSliders(panel)
			BTV:RefreshAllBarPagesGlobalOverrideGating()
		end
	)

	local globalButtonSizeLabel = getglobal(globalButtonSizeCheckbox:GetName() .. "Text")

	if globalButtonSizeLabel then
		globalButtonSizeLabel:SetText("Toggle global ButtonSize")
	end

	panel.globalButtonSizeCheckbox = globalButtonSizeCheckbox
	panel.globalButtonSizeSlider = globalButtonSizeSlider
	panel.globalButtonSizeValueText = globalButtonSizeValueText

	-- Right ActionBar 2 dependency bypass (DefaultBars.lua's
	-- SetDefaultBarEnabled/FixRightActionBar2Checkbox) - lets bar 5 be
	-- toggled independent of bar 4, in both the addon and the native
	-- Options checkbox.
	local bypassBar2DepCheckbox = CreateFrame(
		"CheckButton",
		"BTVanillaGeneralBypassBar2DepCheckbox",
		panel,
		"UICheckButtonTemplate"
	)

	bypassBar2DepCheckbox:SetWidth(24)
	bypassBar2DepCheckbox:SetHeight(24)

	-- Anchored off globalButtonSizeSlider itself (a reliable left edge),
	-- NOT globalButtonSizeValueText - same left-alignment bug as before
	-- (value-text FontStrings only have a bare "TOP" anchor, so they
	-- auto-center under their slider and their BOTTOMLEFT sits near the
	-- slider's horizontal CENTER, not its left edge). Always anchor new
	-- General-tab controls off a slider/checkbox's own edge, never off a
	-- *ValueText FontString.
	bypassBar2DepCheckbox:SetPoint(
		"TOPLEFT",
		globalButtonSizeSlider,
		"BOTTOMLEFT",
		-20,
		-28
	)

	bypassBar2DepCheckbox:SetScript(
		"OnClick",
		function()
			BTVanillaDB.bypassRightActionBar2Dependency = this:GetChecked() and true or false

			BTV:FixRightActionBar2Checkbox()
		end
	)

	local bypassBar2DepLabel = getglobal(bypassBar2DepCheckbox:GetName() .. "Text")

	if bypassBar2DepLabel then
		bypassBar2DepLabel:SetText("Allow Right ActionBar 2 independent of Right ActionBar 1")
	end

	panel.bypassBar2DepCheckbox = bypassBar2DepCheckbox

	-- "Enable Better Experience Bar" (round 16 part 2, Part B) - RELOCATED
	-- to the Experience Bar's own settings page (round 17 item 5,
	-- CreateSimpleBarPage's own "if key == 'expbar'" block) alongside its
	-- new text-toggle checkboxes and color pickers, grouped there as this
	-- feature's own settings home instead of scattered across General.

	panel:Hide()

	settingsFrame.generalPanel = panel

	return panel
end

-------------------------------------------------------------------------
-- Profiles tab panel
--
-- Built lazily on first use, exactly like GetOrCreateGeneralPanel -
-- anchored the same way, spanning the combined listPanel+contentPanel
-- area since the bar list has no meaning here either.
-------------------------------------------------------------------------

-- Sentinel dropdown entry - not a real profile name, so a normal profile
-- can never collide with it. Chosen when the user wants to open the
-- create-new-profile dialog straight from the profile dropdown.
local CREATE_NEW_PROFILE_SENTINEL = "+ Create new profile"

function BTV:GetOrCreateProfilesPanel()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	if settingsFrame.profilesPanel then
		return settingsFrame.profilesPanel
	end

	-- Own dedicated scrollframe+scrollchild pair (BTV:CreateWideContentScrollFrame)
	-- - see CreateSettingsFrame's own comment on why this doesn't share
	-- the Bars view's contentScrollFrame.
	local scrollFrame, panel = BTV:CreateWideContentScrollFrame("BTVanillaSettingsProfilesScrollFrame")

	settingsFrame.profilesScrollFrame = scrollFrame
	scrollFrame:Hide()

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", INDENT_SECTION, -14)
	title:SetText("Profiles")
	panel.title = title

	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
	label:SetText("Active Profile:")
	panel.label = label

	local dropdown = BTV:CreateInlineDropdown(panel, 220, "BTVanillaProfilesDropdown")
	dropdown:ClearAllPoints()
	dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -16, -6)
	panel.profileDropdown = dropdown

	dropdown.onSelect = function(value)
		if value == CREATE_NEW_PROFILE_SENTINEL then
			BTV:ShowCreateProfileDialog(function()
				-- On validation failure the dialog already stayed on the
				-- old profile (CreateProfile/SwitchProfile only reload on
				-- success) - re-sync the dropdown text either way so it
				-- never shows the sentinel as if it were a real selection.
				BTV:RefreshProfilesPanel()
			end)

			return
		end

		if value and value ~= BTVanillaCharDB.activeProfile then
			BTV:SwitchProfile(value)
		end
	end

	local copyButton = CreateFrame("Button", nil, panel)
	copyButton:SetHeight(22)
	copyButton:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 16, -14)
	BTV:StyleModernButton(copyButton, 200, 200)
	copyButton:SetText("Copy from other profile")
	panel.copyButton = copyButton

	copyButton:SetScript("OnClick", function()
		local otherProfiles = {}
		local names = BTV:GetProfileNames()
		local i

		for i = 1, table.getn(names) do
			if names[i] ~= BTVanillaCharDB.activeProfile then
				table.insert(otherProfiles, names[i])
			end
		end

		BTV:ShowDialog({
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
							BTV:CopyProfileInto(value, BTVanillaCharDB.activeProfile)
							BTV:SaveActiveProfileData()
							ReloadUI()
						end
					end,
				},
				{ text = "Cancel", onClick = function() end },
			},
		})
	end)

	local deleteButton = CreateFrame("Button", nil, panel)
	deleteButton:SetHeight(22)
	deleteButton:SetPoint("TOPLEFT", copyButton, "BOTTOMLEFT", 0, -8)
	BTV:StyleModernButton(deleteButton, 200, 200)
	deleteButton:SetText("Delete profile")
	panel.deleteButton = deleteButton

	deleteButton:SetScript("OnClick", function()
		BTV:ShowDialog({
			title = "Delete Profile",
			message = "ATTENTION: This action will delete all settings present " ..
				"on the current profile and is not reversible.",
			mode = "confirm",
			buttons = {
				{
					text = "Accept",
					onClick = function()
						BTV:DeleteProfile(BTVanillaCharDB.activeProfile)
						ReloadUI()
					end,
				},
				{ text = "Cancel", onClick = function() end },
			},
		})
	end)

	panel:Hide()

	settingsFrame.profilesPanel = panel

	return panel
end

-- Refreshes the dropdown's option list/current selection and the Copy/
-- Delete buttons' visibility (only shown while a non-Default profile is
-- active, per spec) - called whenever the Profiles view is (re)shown and
-- after any profile CRUD action that doesn't already trigger a ReloadUI.
function BTV:RefreshProfilesPanel()
	local panel = self:GetOrCreateProfilesPanel()

	BTVanillaCharDB = BTVanillaCharDB or { activeProfile = self.DEFAULT_PROFILE_NAME }

	local names = self:GetProfileNames()
	local dropdownOptions = {}
	local i

	for i = 1, table.getn(names) do
		dropdownOptions[i] = names[i]
	end

	table.insert(dropdownOptions, CREATE_NEW_PROFILE_SENTINEL)

	panel.profileDropdown:SetOptions(dropdownOptions)
	panel.profileDropdown:SetSelected(BTVanillaCharDB.activeProfile)

	if BTVanillaCharDB.activeProfile ~= self.DEFAULT_PROFILE_NAME then
		panel.copyButton:Show()
		panel.deleteButton:Show()
	else
		panel.copyButton:Hide()
		panel.deleteButton:Hide()
	end
end

function BTV:FitSettingsWindowToProfilesView()
	if not settingsFrame or not settingsFrame.profilesPanel then
		return
	end

	local panel = settingsFrame.profilesPanel

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, panel.profileDropdown)
	n = AppendCandidate(candidates, n, panel.copyButton)
	n = AppendCandidate(candidates, n, panel.deleteButton)

	ApplySettingsHeightFromCandidates(candidates, settingsFrame.profilesScrollFrame, panel)
end

-------------------------------------------------------------------------
-- General panel: dynamic reflow for the Global Spacing / Global
-- ButtonSize sliders
--
-- Both sliders are SetShown()-toggled by their own checkbox, but the
-- checkbox/slider immediately below each one was anchored with a FIXED
-- offset set once at creation time - Hide() doesn't remove a frame from
-- its neighbors' anchor math the way it would in a real layout system,
-- so the gap stayed reserved even while the slider was hidden. This
-- walks the checkbox/slider stack and re-anchors everything after the
-- first entry to sit flush against whichever entry above it is actually
-- SHOWN right now, collapsing the gap when a slider is hidden and
-- restoring it when shown. Column = the stack's two indent levels
-- (checkboxes sit at the base indent, sliders 20px further right, per
-- their own original hand-tuned offsets).
-------------------------------------------------------------------------

local REFLOW_COLUMN_CHECKBOX = 0
local REFLOW_COLUMN_SLIDER = 20
local REFLOW_GAP_CHECKBOX_TO_SLIDER = -28
local REFLOW_GAP_SLIDER_TO_CHECKBOX = -26
local REFLOW_GAP_CHECKBOX_TO_CHECKBOX = -14

-- entries: ordered array of { frame = <Frame>, column = REFLOW_COLUMN_*,
-- isOptional = true|nil }. The first entry's own anchor is never touched -
-- callers set that once, outside this list, to whatever fixed frame it
-- should follow. An `isOptional` entry that's currently Hidden is skipped
-- entirely (neither re-anchored nor used as the next entry's anchor
-- source), so hiding it collapses its slot rather than leaving a gap.
local function ReflowStack(entries)
	local prev = entries[1].frame
	local prevColumn = entries[1].column
	local i

	for i = 2, table.getn(entries) do
		local entry = entries[i]

		if (not entry.isOptional) or entry.frame:IsShown() then
			local gap

			if prevColumn == REFLOW_COLUMN_SLIDER and entry.column == REFLOW_COLUMN_CHECKBOX then
				gap = REFLOW_GAP_SLIDER_TO_CHECKBOX
			elseif prevColumn == REFLOW_COLUMN_CHECKBOX and entry.column == REFLOW_COLUMN_SLIDER then
				gap = REFLOW_GAP_CHECKBOX_TO_SLIDER
			else
				gap = REFLOW_GAP_CHECKBOX_TO_CHECKBOX
			end

			entry.frame:ClearAllPoints()
			entry.frame:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", entry.column - prevColumn, gap)

			prev = entry.frame
			prevColumn = entry.column
		end
	end
end

-- Re-fits the General view after its own content height changed. Deferred
-- one frame so the reflowed controls' positions have settled before
-- anything measures them (same reason ShowGeneralView defers its own
-- fit), and guarded on the General view actually being the one on screen -
-- RefreshGeneralPanel can run while another view is showing, and fitting
-- the window to a hidden panel would resize it to the wrong thing.
local function RefitGeneralViewSoon()
	if not settingsFrame or settingsFrame.currentView ~= "general" then
		return
	end

	DeferFit(function() BTV:FitSettingsWindowToGeneralView() end)
end

function BTV:ReflowGeneralOverrideSliders(panel)
	ReflowStack({
		{ frame = panel.globalSpacingCheckbox, column = REFLOW_COLUMN_CHECKBOX },
		{ frame = panel.globalSpacingSlider, column = REFLOW_COLUMN_SLIDER, isOptional = true },
		{ frame = panel.globalButtonSizeCheckbox, column = REFLOW_COLUMN_CHECKBOX },
		{ frame = panel.globalButtonSizeSlider, column = REFLOW_COLUMN_SLIDER, isOptional = true },
		{ frame = panel.bypassBar2DepCheckbox, column = REFLOW_COLUMN_CHECKBOX },
	})

	-- Revealing/hiding either slider changes how tall this panel's content
	-- is, so the window (and its scrollchild) has to be re-measured -
	-- otherwise turning a toggle ON grows the content past the viewport
	-- with no matching scroll range, leaving the bottom unreachable.
	RefitGeneralViewSoon()
end

function BTV:RefreshGeneralPanel()
	local panel = self:GetOrCreateGeneralPanel()

	panel.useDefaultLayoutCheckbox:SetChecked(
		BTVanillaDB.useDefaultLayout == true
	)

	-- Locked to unchecked+non-interactive while useDefaultLayout forces
	-- vanilla styling (BTV:IsVanillaBorderStyle, Core.lua) - reuses the
	-- established EnableMouse(false)+SetAlpha(0.5) gating idiom
	-- (ApplyDefaultLayoutGating) rather than :Disable(), matching every
	-- other gated control in this file.
	local vanillaBorderStyleLocked = BTVanillaDB.useDefaultLayout ~= false

	panel.modernBorderStyleCheckbox:SetChecked(
		(not vanillaBorderStyleLocked) and BTVanillaDB.modernBorderStyle == true
	)
	panel.modernBorderStyleCheckbox:EnableMouse(not vanillaBorderStyleLocked)
	panel.modernBorderStyleCheckbox:SetAlpha(vanillaBorderStyleLocked and 0.5 or 1)

	-- Global Spacing / global ButtonSize overrides: same
	-- vanillaBorderStyleLocked lock as modernBorderStyleCheckbox above
	-- (user-requested), plus their own checked/value sync and the
	-- Show/Hide reveal of their sliders. The displayed range (spacing
	-- only) is recomputed here too, same reason as the per-bar slider.
	local spacingDisplayed = BTVanillaDB.globalSpacingEnabled == true and
		not vanillaBorderStyleLocked

	panel.globalSpacingCheckbox:SetChecked(spacingDisplayed)
	panel.globalSpacingCheckbox:EnableMouse(not vanillaBorderStyleLocked)
	panel.globalSpacingCheckbox:SetAlpha(vanillaBorderStyleLocked and 0.5 or 1)

	local spacingOffset = GetSpacingDisplayOffset()

	panel.globalSpacingSlider:SetMinMaxValues(0, SPACING_MAX - spacingOffset)

	if panel.globalSpacingSliderLow then
		panel.globalSpacingSliderLow:SetText("0")
	end

	if panel.globalSpacingSliderHigh then
		panel.globalSpacingSliderHigh:SetText(tostring(SPACING_MAX - spacingOffset))
	end

	panel.globalSpacingSlider.suppressApply = true
	panel.globalSpacingSlider:SetValue(BTVanillaDB.globalSpacingValue or 0)
	panel.globalSpacingSlider.suppressApply = nil
	panel.globalSpacingValueText:SetText(tostring(BTVanillaDB.globalSpacingValue or 0))

	panel.globalSpacingSlider:SetShown(spacingDisplayed)
	panel.globalSpacingValueText:SetShown(spacingDisplayed)
	panel.globalSpacingSlider:EnableMouse(not vanillaBorderStyleLocked)
	panel.globalSpacingSlider:SetAlpha(vanillaBorderStyleLocked and 0.5 or 1)

	local buttonSizeDisplayed = BTVanillaDB.globalButtonSizeEnabled == true and
		not vanillaBorderStyleLocked

	panel.globalButtonSizeCheckbox:SetChecked(buttonSizeDisplayed)
	panel.globalButtonSizeCheckbox:EnableMouse(not vanillaBorderStyleLocked)
	panel.globalButtonSizeCheckbox:SetAlpha(vanillaBorderStyleLocked and 0.5 or 1)

	panel.globalButtonSizeSlider.suppressApply = true
	panel.globalButtonSizeSlider:SetValue(BTVanillaDB.globalButtonSizeValue or BTV.BUTTON_SIZE)
	panel.globalButtonSizeSlider.suppressApply = nil
	panel.globalButtonSizeValueText:SetText(
		tostring(BTVanillaDB.globalButtonSizeValue or BTV.BUTTON_SIZE)
	)

	panel.globalButtonSizeSlider:SetShown(buttonSizeDisplayed)
	panel.globalButtonSizeValueText:SetShown(buttonSizeDisplayed)
	panel.globalButtonSizeSlider:EnableMouse(not vanillaBorderStyleLocked)
	panel.globalButtonSizeSlider:SetAlpha(vanillaBorderStyleLocked and 0.5 or 1)

	-- Both sliders' Shown state is now final for this refresh - collapse/
	-- restore the gap below each one accordingly.
	BTV:ReflowGeneralOverrideSliders(panel)

	panel.bypassBar2DepCheckbox:SetChecked(BTVanillaDB.bypassRightActionBar2Dependency == true)

	-- Default true (Core.lua's EnsureDB) - only an explicit false ever
	-- unchecks this.
	panel.tintWholeButtonCheckbox:SetChecked(
		BTVanillaDB.tintWholeButtonOnRange ~= false
	)

	-- Default false (Core.lua's EnsureDB) - only an explicit true ever
	-- checks this.
	panel.disableBlizzardArtCheckbox:SetChecked(
		BTVanillaDB.disableBlizzardArt == true
	)

	-- Both default true (Core.lua's EnsureDB) - only an explicit false
	-- ever unchecks either.
	panel.mainBarPaginationCheckbox:SetChecked(
		BTVanillaDB.mainBarPaginationEnabled ~= false
	)

	-- Stance/Page Bar Assignment rows themselves - RELOCATED to bar 1's own
	-- settings page (bug-fix batch round 4, Issue 5); refreshed from
	-- RefreshBarSettingsPage(1) instead of here now.

	panel.mainBarStanceSwapCheckbox:SetChecked(
		BTVanillaDB.mainBarStanceSwapEnabled ~= false
	)

	-------------------------------------------------------------------------
	-- Hotkey / Count text font size
	--
	-- nil (never yet touched by the user) falls back to the captured
	-- native default - see Core.lua's EnsureDB comment on why these two
	-- fields are deliberately left unseeded.
	-------------------------------------------------------------------------

	local hotkeyDefault = BTV.NATIVE_HOTKEY_FONT and BTV.NATIVE_HOTKEY_FONT.size
	local hotkeySize = ClampFontSize(BTVanillaDB.hotkeyFontSize or hotkeyDefault)

	panel.hotkeySlider.suppressApply = true
	panel.hotkeySlider:SetValue(hotkeySize)
	panel.hotkeyValueText:SetText(tostring(hotkeySize))
	panel.hotkeySlider.suppressApply = nil

	local countDefault = BTV.NATIVE_COUNT_FONT and BTV.NATIVE_COUNT_FONT.size
	local countSize = ClampFontSize(BTVanillaDB.countFontSize or countDefault)

	panel.countSlider.suppressApply = true
	panel.countSlider:SetValue(countSize)
	panel.countValueText:SetText(tostring(countSize))
	panel.countSlider.suppressApply = nil

	-- Default false (Core.lua's EnsureDB) - only an explicit true ever
	-- checks this.
	panel.snapToAdjacentCheckbox:SetChecked(
		BTVanillaDB.snapToAdjacentElements == true
	)

	-- "Enable Better Experience Bar" - RELOCATED to the Experience Bar's
	-- own settings page (round 17 item 5); refreshed from
	-- RefreshSimpleBarPage("expbar") instead of here now.
end

-------------------------------------------------------------------------
-- View switching ("Bars" / "General" tabs)
-------------------------------------------------------------------------

-- Syncs each top nav tab's persistent gold selectStrip (CreateSettingsFrame's
-- ApplyTabFadeHighlight) to settingsFrame.currentView - called after every
-- place that assigns settingsFrame.currentView, so whichever tab matches
-- the now-active view is the only one highlighted.
function BTV:RefreshActiveTabHighlight()
	if not settingsFrame or not settingsFrame.tabButtonsByView then
		return
	end

	local view
	local button

	for view, button in pairs(settingsFrame.tabButtonsByView) do
		if button.tabSelectStrip then
			button.tabSelectStrip:SetShown(settingsFrame.currentView == view)
		end

		if button.UpdateFadeBorderColor then
			button:UpdateFadeBorderColor()
		end
	end
end

function BTV:ShowBarsView()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	self:ShowBarPage(settingsFrame.activeBarId or 1)
end

function BTV:ShowGeneralView()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	local id
	local page

	for id, page in pairs(settingsFrame.pages) do
		page:Hide()
	end

	settingsFrame.listPanel:Hide()
	settingsFrame.contentScrollFrame:Hide()
	settingsFrame.contentPanel:Hide()
	settingsFrame.currentView = "general"
	BTV:RefreshActiveTabHighlight()

	-- Ensure the General panel (and its own dedicated scrollframe) exist
	-- before trying to Show() the scrollframe below.
	self:GetOrCreateGeneralPanel()

	if settingsFrame.profilesScrollFrame then
		settingsFrame.profilesScrollFrame:Hide()
	end

	if settingsFrame.profilesPanel then
		settingsFrame.profilesPanel:Hide()
	end

	settingsFrame.generalScrollFrame:Show()

	self:RefreshGeneralPanel()
	self:GetOrCreateGeneralPanel():Show()

	-- Fix 3: same reasoning as ShowBarPage's call - has to run after
	-- :Show() so GetBottom() reads real values. Deferred one frame
	-- (DeferFit) so its own candidates' positions have settled before
	-- anything measures them.
	DeferFit(function() BTV:FitSettingsWindowToGeneralView() end)
end

function BTV:ShowProfilesView()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	local id
	local page

	for id, page in pairs(settingsFrame.pages) do
		page:Hide()
	end

	settingsFrame.listPanel:Hide()
	settingsFrame.contentScrollFrame:Hide()
	settingsFrame.contentPanel:Hide()
	settingsFrame.currentView = "profiles"
	BTV:RefreshActiveTabHighlight()

	-- Ensure the Profiles panel (and its own dedicated scrollframe) exist
	-- before trying to Show() the scrollframe below.
	self:GetOrCreateProfilesPanel()

	if settingsFrame.generalScrollFrame then
		settingsFrame.generalScrollFrame:Hide()
	end

	if settingsFrame.generalPanel then
		settingsFrame.generalPanel:Hide()
	end

	settingsFrame.profilesScrollFrame:Show()

	self:RefreshProfilesPanel()
	self:GetOrCreateProfilesPanel():Show()

	-- Fix 3: same reasoning as ShowBarPage's call - has to run after
	-- :Show() so GetBottom() reads real values. Deferred one frame
	-- (DeferFit) so its own candidates' positions have settled before
	-- anything measures them.
	DeferFit(function() BTV:FitSettingsWindowToProfilesView() end)
end

-------------------------------------------------------------------------
-- Bar list row creation
--
-- One row layout shared by default bars (1-5) and custom bars (6+) -
-- only the presence of the inline enable-checkbox (default bars 2-5)
-- and the small kind indicator text differ.
-------------------------------------------------------------------------

local function CreateBarListRow(barId, isDefault, cfg)
	local row = BTV:CreateListRow(settingsFrame.listContent, nil)

	-- Wide enough for the longest friendly name ("Right Action Bar 2")
	-- plus the inline enable checkbox some rows also carry.
	row:SetWidth(110)
	row:SetHeight(LIST_ROW_HEIGHT)

	-- Every row's highlight spans the SAME fixed width/offset (matching
	-- f.listPanel's own boxed inner area) regardless of whether this
	-- particular row has an inline checkbox - see LIST_ITEM_VISUAL_WIDTH's
	-- own comment. Overridden again below for checkbox rows only in the
	-- sense that they'd already match (checkbox rows just also get their
	-- own hover events forwarded into the same highlight).
	row:SetVisualWidth(LIST_ITEM_VISUAL_WIDTH, LIST_ITEM_VISUAL_OFFSET)

	row:SetLabel(
		GetBarDisplayName(barId, isDefault)
	)

	row.barId = barId

	-- Inlined rather than reusing the old BarListButton_OnClick (which read
	-- this.barId per the engine this-convention) - BTVListRowMixin's
	-- onClick is instead invoked as onClick(row), an explicit arg.
	row:SetOnClick(function(clickedRow)
		BTV:ShowBarPage(clickedRow.barId)
	end)

	-- Bars 2-5 (default only) AND the Bag Bar/Micro Menu (feature 3 - the
	-- only two of the three "simple" string-keyed pages that can be
	-- meaningfully disabled, unlike the Stance Bar) get an inline
	-- enable/disable checkbox - live, applies on click immediately
	-- (point 7). Generalized (rather than the old hardcoded
	-- SetDefaultBarEnabled-only version) so both sources of an "enabled"
	-- flag share one checkbox-creation code path.
	local simpleConfig = simpleBarPageConfigs[barId]

	local wantsCheckbox = false
	local checkedState = false
	local onToggle = nil

	if isDefault and type(barId) == "number" and barId ~= 1 then
		wantsCheckbox = true
		checkedState = cfg and cfg.enabled == true
		onToggle = function(checked)
			BTV:SetDefaultBarEnabled(barId, checked)
		end
	elseif simpleConfig and simpleConfig.hasEnable then
		wantsCheckbox = true
		checkedState = simpleConfig.getEnabled and simpleConfig.getEnabled() ~= false
		onToggle = function(checked)
			simpleConfig.setEnabled(checked)
		end
	elseif not isDefault and type(barId) == "number" and BTV:IsExtraBarId(barId) then
		-- Extra Bars (ids 6-9, Stance/Page Bar Assignment feature, Part 1):
		-- same inline list checkbox default bars 2-5 get above.
		wantsCheckbox = true
		checkedState = cfg and cfg.enabled == true
		onToggle = function(checked)
			BTV:SetExtraBarEnabled(barId, checked)
		end
	end

	if wantsCheckbox then
		local checkbox = CreateFrame(
			"CheckButton",
			"BTVanillaBarList" .. tostring(barId) .. "Checkbox",
			settingsFrame.listContent,
			"UICheckButtonTemplate"
		)

		checkbox:SetWidth(20)
		checkbox:SetHeight(20)

		checkbox:SetPoint(
			"LEFT",
			row,
			"RIGHT",
			2,
			0
		)

		checkbox:SetChecked(checkedState)

		checkbox.barId = barId

		-- Forwards the checkbox's own hover events into the row's shared
		-- highlight (BTVListRowMixin:OnRowEnter/OnRowLeave) - the highlight
		-- itself already spans the checkbox's space too, since every row
		-- (checkbox or not) is set to the same fixed LIST_ITEM_VISUAL_WIDTH
		-- above, not just checkbox rows.
		checkbox:SetScript("OnEnter", function() row:OnRowEnter() end)
		checkbox:SetScript("OnLeave", function() row:OnRowLeave() end)

		checkbox:SetScript(
			"OnClick",
			function()
				local checked = this:GetChecked() and true or false

				onToggle(checked)

				-- Keep the corresponding page's own checkbox (if built)
				-- in sync too.
				BTV:RefreshBarSettingsPage(this.barId)
			end
		)

		row.checkbox = checkbox

		-- Only exempt for numbered default bars (2-5 - bar 1 never gets a
		-- sidebar checkbox at all) from BOTH the Default-profile AND
		-- Default-layout locks, matching page.enableCheckbox's own
		-- exemption on those pages (BTV:ApplyProfileLockGating). Bag Bar/
		-- Micro Menu and Extra Bars (6-9) get NO exemption - their
		-- checkbox locks exactly like every other control on their page,
		-- under the Default-profile lock only (layout lock never applies
		-- to them).
		local isNumberedDefaultBar = isDefault and type(barId) == "number" and barId ~= 1

		if not isNumberedDefaultBar then
			LockControl(checkbox, BTV:IsDefaultProfileActive())
		end

		-- Bar 5's sidebar checkbox mirrors its page's own enableCheckbox
		-- lock (see RefreshBarSettingsPage) - only enabled while bar 4 is,
		-- unless the bypass option is on.
		if isNumberedDefaultBar and barId == 5 then
			local bar4Cfg = BTVanillaDB.defaultBars[4]
			local allowed = BTVanillaDB.bypassRightActionBar2Dependency == true
				or (bar4Cfg and bar4Cfg.enabled == true)

			LockControl(checkbox, not allowed)
		end
	end

	-- Grey out (BTVListRowMixin:SetDisabled - also blocks the row's own
	-- onClick, but bar 5's page is still reachable via its own checkbox's
	-- lock/the bypass option, same as before) the row itself too, so its
	-- locked state is visible at a glance in the list, not just on the
	-- small checkbox beside it.
	if isDefault and barId == 5 then
		local bar4Cfg = BTVanillaDB.defaultBars[4]
		local allowed = BTVanillaDB.bypassRightActionBar2Dependency == true
			or (bar4Cfg and bar4Cfg.enabled == true)

		row:SetDisabled(not allowed)
	end

	return row
end

-------------------------------------------------------------------------
-- Refresh left bar list
--
-- Unified list (point 1): Bar 1 -> Bar 5, a divider, then the 4 permanent
-- Extra Bars (6-9, Stance/Page Bar Assignment feature Part 1) - no more
-- "+ Add New Bar" row, since capacity is fixed and every possible bar id
-- already always exists.
-------------------------------------------------------------------------

function BTV:RefreshBarList()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	local i

	for i = 1, table.getn(settingsFrame.barButtons) do
		local widget = settingsFrame.barButtons[i]

		widget:Hide()

		if widget.checkbox then
			widget.checkbox:Hide()
		end
	end

	settingsFrame.barButtons = {}
	settingsFrame.barButtonsByBarId = {}

	local yOffset = -24
	local rowIndex = 0

	-------------------------------------------------------------------------
	-- Default bars 1-5
	-------------------------------------------------------------------------

	local id

	for id = 1, 5 do
		local cfg = BTVanillaDB.defaultBars[id]

		if cfg then
			-- Major architecture migration, Phase 1 of 2: no more native-
			-- global reconciliation here (see RefreshBarSettingsPage's
			-- matching comment) - bars 2-5's real Blizzard buttons are
			-- permanently hidden regardless of the old SHOW_MULTI_
			-- ACTIONBAR_* globals, so cfg.enabled is read directly as the
			-- sole source of truth.
			local row = CreateBarListRow(id, true, cfg)

			row:SetPoint(
				"TOPLEFT",
				settingsFrame.listContent,
				"TOPLEFT",
				0,
				yOffset
			)

			rowIndex = rowIndex + 1
			settingsFrame.barButtons[rowIndex] = row
			settingsFrame.barButtonsByBarId[id] = row

			yOffset = yOffset - (LIST_ROW_HEIGHT + LIST_ROW_GAP)
		end
	end

	-------------------------------------------------------------------------
	-- Stance Bar / Bag Bar / Micro Menu (features 2/3) - distinct string
	-- keys, not numbered default/custom bars. Grouped here with the
	-- default bars above the divider since they're equally native-backed,
	-- not user-created. Always shown in the list (never hidden entirely,
	-- point made explicit in this feature's own task spec) - drag/
	-- position-slider interactivity is gated separately by
	-- useDefaultLayout (ApplyDefaultLayoutGating, reused by
	-- RefreshSimpleBarPage below), exactly mirroring how default bars 1-5
	-- stay visible and just grey out rather than disappearing.
	-------------------------------------------------------------------------

	local specialKeys = { "stance", "bagbar", "micromenu", "latencybar", "expbar" }
	local si

	for si = 1, table.getn(specialKeys) do
		local key = specialKeys[si]

		-- Bag Bar/Micro Menu rows are only meaningful once their real
		-- container was successfully built (BTV:CreateBagBarAndMicroMenu,
		-- DefaultBars.lua) - degrades gracefully (row simply absent) if
		-- discovery failed this session, the same tolerance default bars
		-- 2-5 already have for a failed fixedActionSlots discovery. The
		-- Stance Bar has no equivalent "did this fail" case - ShapeshiftBarFrame
		-- is a fixed, always-present real Blizzard global. The Latency Bar
		-- (bug-fix batch Fix 3) is defensively checked too, even though
		-- MainMenuBarPerformanceBarFrame is confirmed to exist on this
		-- client, in case it's ever missing on some other client build.
		-- The Experience Bar (round 16 part 2, Part A) gets the same
		-- defensive check - MainMenuExpBar's presence on this specific
		-- modded client build is UNCONFIRMED (see
		-- DefaultBars.lua's own header comment on this element).
		local exists = true

		if key == "bagbar" then
			exists = BTV.bagBarContainer ~= nil
		elseif key == "micromenu" then
			exists = BTV.microMenuContainer ~= nil
		elseif key == "latencybar" then
			exists = getglobal(BTV.LATENCY_BAR_FRAME_NAME) ~= nil
		elseif key == "expbar" then
			exists = getglobal(BTV.EXP_BAR_FRAME_NAME) ~= nil
		end

		if exists then
			local row = CreateBarListRow(key, true, nil)

			row:SetPoint(
				"TOPLEFT",
				settingsFrame.listContent,
				"TOPLEFT",
				0,
				yOffset
			)

			rowIndex = rowIndex + 1
			settingsFrame.barButtons[rowIndex] = row
			settingsFrame.barButtonsByBarId[key] = row

			yOffset = yOffset - (LIST_ROW_HEIGHT + LIST_ROW_GAP)
		end
	end

	-------------------------------------------------------------------------
	-- Divider between default and custom bars
	-------------------------------------------------------------------------

	-- WHITE8X8 rather than "Interface\Common\UI-TooltipDivider" - the
	-- latter isn't confirmed to exist on this 1.12.1 client, while
	-- WHITE8X8 is already proven working here (see Button.lua's
	-- editOverlay). A thin dim line is enough of a section break.
	local divider = settingsFrame.listContent:CreateTexture(
		nil,
		"ARTWORK"
	)

	divider:SetTexture("Interface\\Buttons\\WHITE8X8")
	divider:SetVertexColor(0.5, 0.5, 0.5, 0.6)
	divider:SetWidth(120)
	divider:SetHeight(2)

	divider:SetPoint(
		"TOPLEFT",
		settingsFrame.listContent,
		"TOPLEFT",
		2,
		yOffset + 2
	)

	rowIndex = rowIndex + 1

	-- The divider shares the same tracked-widget list purely so it gets
	-- hidden/recreated alongside everything else on refresh - it has no
	-- barId/checkbox/onClick, and (unlike every real row) is deliberately
	-- NOT added to barButtonsByBarId.
	settingsFrame.barButtons[rowIndex] = divider

	yOffset = yOffset - 14

	-------------------------------------------------------------------------
	-- Extra Bars 6-9 (Stance/Page Bar Assignment feature, Part 1) - always
	-- exactly 4 entries (Core.lua's EnsureExtraBars), each toggled via its
	-- own inline checkbox above.
	-------------------------------------------------------------------------

	for i = 1, table.getn(BTVanillaDB.bars) do
		local cfg = BTVanillaDB.bars[i]

		if cfg then
			local row = CreateBarListRow(cfg.id, false, cfg)

			row:SetPoint(
				"TOPLEFT",
				settingsFrame.listContent,
				"TOPLEFT",
				0,
				yOffset
			)

			rowIndex = rowIndex + 1
			settingsFrame.barButtons[rowIndex] = row
			settingsFrame.barButtonsByBarId[cfg.id] = row

			yOffset = yOffset - (LIST_ROW_HEIGHT + LIST_ROW_GAP)
		end
	end

	-- "+ Add New Bar" - REMOVED (Stance/Page Bar Assignment feature,
	-- Part 1). Capacity is now fixed at exactly BTV.EXTRA_BAR_COUNT (4)
	-- permanent Extra Bars, always listed in the loop above - a user
	-- enables/disables one via its inline checkbox rather than adding a
	-- new one, so there is nothing left for this button to do.

	-- Rows are all rebuilt fresh above (RefreshBarList can run after a bar
	-- page is already showing - profile switch, bar enable/disable) - the
	-- new row for the already-selected bar has isSelected == false until
	-- this restores it, since BTVListRowMixin state lives on the row
	-- instance, not the barId.
	if settingsFrame.selectedBarId ~= nil then
		local selectedRow = settingsFrame.barButtonsByBarId[settingsFrame.selectedBarId]

		if selectedRow then
			selectedRow:SetSelected(true)
		end
	end
end

-- BTV:DeleteBar - REMOVED (Stance/Page Bar Assignment feature, Part 1).
-- Every non-default bar id (6-9) is now a permanent Extra Bar (Core.lua's
-- EnsureExtraBars) toggled via cfg.enabled (Bar.lua's SetExtraBarEnabled),
-- never added/removed - there is no longer any bar this could legally
-- apply to, and no remaining call site (the old Delete Bar button and
-- Menu.lua's "Add New Bar" entry are both gone too).

-------------------------------------------------------------------------
-- Show settings
-------------------------------------------------------------------------

function BTV:ShowSettingsFrame()
	if not settingsFrame then
		CreateSettingsFrame()
	end

	self:RefreshBarList()

	settingsFrame:Show()

	if not settingsFrame.activeBarId then
		self:ShowBarPage(1)
	elseif settingsFrame.currentView == "general" then
		DeferFit(function() BTV:FitSettingsWindowToGeneralView() end)
	elseif settingsFrame.currentView == "profiles" then
		DeferFit(function() BTV:FitSettingsWindowToProfilesView() end)
	else
		-- RefreshBarList (above) just rebuilt the bar-list rows from
		-- scratch (e.g. a bar added/removed while the window was closed),
		-- so even though the active page itself isn't changing here, the
		-- window still needs to refit against the new row count.
		DeferFit(function() BTV:FitSettingsWindowToBarPage(settingsFrame.activeBarId) end)
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
-- Open specific bar settings (custom bars only - called from
-- Button.lua's right-click-to-configure on a live custom-bar button;
-- default bars aren't backed by BTV.bars, see DefaultBars.lua)
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

-------------------------------------------------------------------------
-- Open specific bar settings (default bars 1-5 - called from
-- HoverBind.lua's right-click hook on a live Blizzard default-bar
-- button; default bars have no live BTV.bars entry the way custom bars
-- do, so this takes a bar id directly rather than a bar object).
-------------------------------------------------------------------------

function BTV:OpenDefaultBarSettings(barId)
	if not IsDefaultBarId(barId) then
		return
	end

	self:ShowSettingsFrame()

	self:ShowBarPage(barId)
end
