-- Settings.lua
-- AlternativeClassicActionBars unified settings window: default bars (1-5), Extra Bars (6-9),
-- and native-frame "simple" pages (Stance/Bag/Micro Menu/Latency/Experience
-- Bar) share one bar list and a "Bars" view, plus a "General" view for
-- addon-wide settings. Every control is live: no pending/Apply state.
--
-- Per-bar editable settings (default bars 1-5, Extra Bars 6-9): x/y,
-- buttonSize, spacing, cols/rows (grid presets), buttonCount (Extra Bars
-- only), enabled (bars 2-5 and 6-9 only).
--
-- point/relativePoint and slotStart are not exposed in the UI.
--
-- Grid shape is one of 6 fixed presets (1x12, 2x6, 3x4, 4x3, 6x2, 12x1),
-- not free-form rows/cols sliders. Button size steps in 2px increments.
--
-- CreateSimpleBarPage builds the narrower simple-bar pages (Position plus
-- optional Enable/Spacing/Scale/Orientation/Reset). GetOrCreateGeneralPanel
-- builds the General tab of addon-wide toggles.

local ACAB = AlternativeClassicActionBars

-------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------

ACAB.BUTTON_SIZE_MIN = 16
ACAB.BUTTON_SIZE_MAX = 64
ACAB.BUTTON_SIZE_STEP = 2

-- General tab's hotkey/count text font size sliders (Button.lua's
-- self.hotkey/self.count FontStrings).
ACAB.FONT_SIZE_MIN = 6
ACAB.FONT_SIZE_MAX = 24
ACAB.FONT_SIZE_STEP = 1

-- Clamps a saved/native font size into the sliders' fixed [MIN, MAX] range,
-- rounding via math.floor(value + 0.5) - a captured native default
-- (GetFont() off a real FontString) can come back with float imprecision
-- (e.g. 11.999999726451 instead of 12) on this client. Every display path
-- that shows a font size funnels it through here first.
--
-- A ACAB: method (not a file-local) since both Settings.lua's shell and
-- SettingsGeneral.lua's font-size sliders call it.
function ACAB:ClampFontSize(size)
	if not size then
		return ACAB.FONT_SIZE_MIN
	end

	size = math.floor(size + 0.5)

	if size < ACAB.FONT_SIZE_MIN then
		return ACAB.FONT_SIZE_MIN
	end

	if size > ACAB.FONT_SIZE_MAX then
		return ACAB.FONT_SIZE_MAX
	end

	return size
end

-- Shared by both default bars (1-5) and custom bars (6+) Spacing sliders.
ACAB.SPACING_MIN = 0
ACAB.SPACING_MAX = 20
ACAB.SPACING_STEP = 1

-- Real-to-displayed spacing offset for the per-bar (1-9) spacing slider
-- only - not the simple-bar sliders, and not the global-spacing slider
-- (which shows ACABDB.globalSpacingValue raw, un-offset; see Bar.lua's
-- ApplyGlobalSpacing). ACAB:ApplyGlobalButtonStyle (Bar.lua) converts the
-- real spacing value by this same offset on every style transition, so the
-- displayed number stays constant. Real values are only ever written at
-- the OnValueChanged/refresh boundary; the slider's on-screen value is
-- always in displayed space.
function ACAB:GetSpacingDisplayOffset()
	return ACAB:IsVanillaBorderStyle() and ACAB.VANILLA_SPACING_FLOOR or 0
end
-- Populated later in this file (CreateSimpleBarPage) once
-- ACAB:SetStanceBarPosition/SetBagBarPosition/etc. (DefaultBars.lua) exist.
-- A ACAB field (not a file-local) since both Settings.lua's own
-- RefreshSimplePositionSliderRange and SettingsBars.lua's page builders
-- need to read/write it regardless of file/definition order.
ACAB.simpleBarPageConfigs = {}

-- Layout indent constants, used instead of scattering magic numbers
-- through every page-building call below.
ACAB.INDENT_SECTION = 18
ACAB.INDENT_CONTROL = 22
ACAB.INDENT_INPUT   = 85

-- Defers `fn` to the next frame via C_Timer.After(0, ...), falling back to
-- calling fn immediately if C_Timer isn't available. Wraps every Fit*View
-- call below: GetBottom() on a panel just Show()'n/populated this same
-- tick has not resolved to real values yet, so measuring must wait one
-- frame.
--
-- A ACAB: method (not a file-local) since SettingsBars.lua/SettingsGeneral.lua
-- call it too, not just this file's own Fit*View functions.
function ACAB:DeferFit(fn)
	if C_Timer and C_Timer.After then
		C_Timer.After(0, fn)
	else
		fn()
	end
end

-- Width reserved for each content viewport's scrollbar (anchored just
-- outside the scrollframe's right edge), reserved unconditionally so
-- nothing reflows when scrolling toggles on/off. Shared by
-- CreateSettingsFrame and ACAB:CreateWideContentScrollFrame.
local SETTINGS_SCROLLBAR_RESERVED_WIDTH = 28

-- Fixed vertical band reserved for the Default-profile-lock warning banner
-- (CreateProfileLockWarning), anchored under each page's title, above its
-- first control. Reserved unconditionally so nothing reflows when the
-- banner toggles.
local PROFILE_LOCK_BANNER_TOP = -34

-- Safety-margin reserve for the longer of the two lock messages, wrapped
-- at the narrowest page width the banner appears at. Real height is still
-- recomputed dynamically from wrapped text (ACAB:ApplyProfileLockGating).
local PROFILE_LOCK_BANNER_HEIGHT = 56
-------------------------------------------------------------------------
-- Basic helpers
-------------------------------------------------------------------------

local function SettingsFrame_OnDragStart()
	this:StartMoving()
end

local function SettingsFrame_OnDragStop()
	this:StopMovingOrSizing()
end

-- A ACAB: method (not a file-local) since Settings.lua's own
-- RefreshPositionSliderRange and SettingsBars.lua's page builders both call it.
function ACAB:IsDefaultBarId(barId)
	return ACAB:IsDefaultBarFamilyId(barId)
end

-- Finds an Extra Bar's SavedVariables entry by ID, not array index -
-- ACABDB.bars is a plain array under the hood. A ACAB: method for the
-- same cross-file reason as IsDefaultBarId above.
function ACAB:FindCustomBarConfig(barId)
	local i

	for i = 1, table.getn(ACABDB.bars) do
		local cfg = ACABDB.bars[i]

		if cfg and cfg.id == barId then
			return cfg
		end
	end

	return nil
end

-- Returns cfg, isDefault for any bar id (1-5 default, 6+ custom). A ACAB:
-- method for the same cross-file reason as IsDefaultBarId above.
function ACAB:GetBarConfig(barId)
	if ACAB:IsDefaultBarId(barId) then
		return ACABDB.defaultBars[barId], true
	end

	return ACAB:FindCustomBarConfig(barId), false
end
-------------------------------------------------------------------------
-- Screen coordinate ranges
--
-- Computed once per page build, not per-tick - the "Position (X: -1024 to
-- 1024)" caption is a static FontString set at build time.
-------------------------------------------------------------------------

-- Elements anchor at various corners (TOPLEFT-TOPLEFT, CENTER-CENTER,
-- etc. - see ApplyBarPosition/DefaultBars.lua's per-frame anchors), so
-- depending on which corner pair a given element uses, its offset from
-- UIParent can need to span up to a full screen dimension just to reach
-- the opposite edge, plus some room to drag it fully off-screen in
-- either direction. Doubling UIParent's own size comfortably covers
-- every anchor-corner combination in use, with room to spare.
-- A ACAB: method (not a file-local) since SettingsBars.lua's simple-page
-- builder calls it too, not just this file's own position-range functions.
function ACAB:GetScreenCoordinateRange()
	local width = UIParent:GetWidth()
	local height = UIParent:GetHeight()

	if not width or width <= 0 then
		width = 1024
	end

	if not height or height <= 0 then
		height = 768
	end

	return -width * 2, width * 2, -height * 2, height * 2
end

-------------------------------------------------------------------------
-- Action-bar-specific X/Y position clamp range
--
-- Computed per-bar (depends on buttonSize/buttonCount/border style), kept
-- live via RefreshPositionSliderRange below. Bars anchor TOPLEFT-to-
-- UIParent's BOTTOMLEFT (Core.lua), y=0 at the screen bottom, increasing
-- upward.
--
-- WARNING: use GetScreenWidth()/GetScreenHeight() for the screen-bounds
-- terms, NOT UIParent:GetWidth()/GetHeight() - UIParent has a non-1
-- self-scale, so its own GetWidth()/GetHeight() undershoots the real
-- screen edges; GetRight()/GetTop() (which equal GetScreenWidth()/
-- GetScreenHeight()) are the correct reference.
--
-- xMin = 0
-- xMax = GetScreenWidth() - barWidth - borderSize
-- yMin = barHeight + borderSize
-- yMax = GetScreenHeight()
-- (barWidth/barHeight include inter-button spacing; use cols/rows, not
-- buttonCount, since a multi-row bar isn't buttonCount cells wide)
-------------------------------------------------------------------------

-- 4-unit vanilla action-button border vs. 1-unit modern/minimal border.
local function GetActionBarBorderSize()
	return ACAB:IsVanillaBorderStyle() and 4 or 1
end

-- A ACAB: method (not a file-local) since SettingsBars.lua's bar-page
-- builder calls it too, not just this file's own RefreshPositionSliderRange.
function ACAB:GetActionBarCoordinateRange(cfg)
	-- See the coordinate-range comment above: screen bounds come from
	-- GetScreenWidth()/GetScreenHeight(), not UIParent:GetWidth()/GetHeight().
	local screenWidthUnits = GetScreenWidth()
	local screenHeightUnits = GetScreenHeight()

	if not screenWidthUnits or screenWidthUnits <= 0 then
		screenWidthUnits = 1024
	end

	if not screenHeightUnits or screenHeightUnits <= 0 then
		screenHeightUnits = 768
	end

	local buttonSize = (cfg and cfg.buttonSize) or ACAB.BUTTON_SIZE
	local cols = (cfg and cfg.cols) or 1
	local rows = (cfg and cfg.rows) or 1
	local spacing = (cfg and cfg.spacing) or 0
	local borderSize = GetActionBarBorderSize()

	-- Pet Bar condense: Bar.lua's LayoutButtons compacts filled slots into
	-- cfg.cols-wide rows instead of reserving every one of the 10 pool
	-- slots' own cell - the on-screen footprint shrinks to match, so the
	-- clamp range must be computed from that same effective shape or the
	-- bar can never reach screen edges the full uncondensed grid blocked.
	if cfg and cfg.isPetBar and ACAB:ShouldCondensePetBarSlots() then
		local filled = ACAB:GetPetBarFilledSlotCount()

		if filled <= 0 then
			cols = 1
			rows = 1
		elseif filled < cols then
			cols = filled
			rows = 1
		else
			rows = math.ceil(filled / cols)
		end
	end

	local barWidth = (cols * buttonSize) + ((cols - 1) * spacing)
	local barHeight = (rows * buttonSize) + ((rows - 1) * spacing)

	local minX = 0
	local maxX = screenWidthUnits - barWidth - borderSize

	local minY = barHeight + borderSize
	local maxY = screenHeightUnits

	-- Never feed SetMinMaxValues a backwards span (max < min) if an
	-- oversized bar/border combination would otherwise invert it.
	if maxX < minX then
		maxX = minX
	end

	if maxY < minY then
		maxY = minY
	end

	return minX, maxX, minY, maxY
end

-- Recomputes and re-applies an action-bar page's X/Y slider clamp range
-- from its CURRENT buttonSize/buttonCount/cols/rows and border style -
-- call whenever any of those change live (button size drag, button
-- count stepper, grid preset pick), since GetActionBarCoordinateRange
-- depends on them. Also re-clamps the current value, in case a
-- shrinking range no longer contains it.
function ACAB:RefreshPositionSliderRange(page)
	if not page or not page.xSlider or not page.ySlider or not page.barId then
		return
	end

	local cfg = ACAB:GetBarConfig(page.barId)

	if not cfg then
		return
	end

	local minX, maxX, minY, maxY = ACAB:GetActionBarCoordinateRange(cfg)

	page.xSlider:SetMinMaxValues(minX, maxX)
	page.ySlider:SetMinMaxValues(minY, maxY)

	local x = page.xSlider:GetValue()
	local y = page.ySlider:GetValue()

	if x < minX then
		ACAB:SetSliderValueUnsnapped(page.xSlider, minX)
	elseif x > maxX then
		ACAB:SetSliderValueUnsnapped(page.xSlider, maxX)
	end

	if y < minY then
		ACAB:SetSliderValueUnsnapped(page.ySlider, minY)
	elseif y > maxY then
		ACAB:SetSliderValueUnsnapped(page.ySlider, maxY)
	end
end

-------------------------------------------------------------------------
-- Native/simple-element X/Y position clamp range (Bag Bar, Micro Menu,
-- Stance/Pet Bar native mode, Experience Bar, Cast Bar - NOT Latency Bar,
-- whose overlay hitbox is currently oversized relative to its visual
-- footprint, a separate known issue).
--
-- Unlike action bars, these elements' footprint isn't formula-derived
-- (native frames, or chain-anchored containers) - read the real rendered
-- size instead, via each element's `.ACABOverlay` (EnsureContainerOverlay,
-- DefaultBars.lua), which tracks the trimmed real visual footprint.
--
-- WARNING - two things action bars don't need:
-- 1. Hit-rect padding: frame:GetWidth()/GetHeight() can exceed the real
--    drawn size - prefer the overlay for measurement, not the raw frame.
-- 2. Scale: these elements call :SetScale() directly, so pos.x/y are in
--    pre-scale unit space - divide by scale to compare against
--    screenWidth/frameWidth: x <= (screenWidth - frameWidth)/scale.
--
-- extraMaxYPixels (optional): extra real screen pixels of headroom
-- (GetPixelStep()) added before the scale division.
-------------------------------------------------------------------------

-- A ACAB: method (not a file-local) since SettingsBars.lua's simple-page
-- builder calls it too, not just this file's own RefreshSimplePositionSliderRange.
function ACAB:GetSimpleElementCoordinateRange(frame, extraMaxYPixels)
	local screenWidthUnits = GetScreenWidth()
	local screenHeightUnits = GetScreenHeight()

	if not screenWidthUnits or screenWidthUnits <= 0 then
		screenWidthUnits = 1024
	end

	if not screenHeightUnits or screenHeightUnits <= 0 then
		screenHeightUnits = 768
	end

	-- frame:GetWidth()/GetHeight() are scale-independent; multiply by the
	-- container's own scale for the same space frame:GetLeft()*scale uses.
	-- WARNING: don't use the overlay's GetWidth()/GetHeight() as the base
	-- size - it measures smaller than the true footprint once scale isn't
	-- 1. The overlay is only used below for the inset correction.
	local overlay = frame and frame.ACABOverlay

	local scale = (frame and frame:GetScale()) or 1

	if not scale or scale <= 0 then
		scale = 1
	end

	-- Some elements' overlay is trimmed inward from the container's own raw
	-- anchor corner (e.g. Micro Menu's grid overlay, Latency Bar's own
	-- ACAB.LATENCY_BAR_OVERLAY_INSET) - left/right and top/bottom trims are
	-- tracked independently since they aren't always symmetric. Measured
	-- directly below (container-vs-overlay offset) rather than hardcoded,
	-- so it stays correct for any element/inset; 0 when the overlay is a
	-- plain SetAllPoints(container) with no trim.
	local leftInset, rightInset, topInset, bottomInset = 0, 0, 0, 0

	if overlay and frame then
		-- frame:GetLeft()/GetTop() are in the container's own local unit
		-- system (scaled by its own SetScale); the overlay's scale is
		-- always 1. Multiply the container's edge by its own scale before
		-- diffing against the overlay's edge, or the inset picks up a
		-- scale-dependent error.
		local containerLeft = frame:GetLeft()
		local overlayLeft = overlay:GetLeft()
		local containerRight = frame:GetRight()
		local overlayRight = overlay:GetRight()
		local containerTop = frame:GetTop()
		local overlayTop = overlay:GetTop()
		local containerBottom = frame:GetBottom()
		local overlayBottom = overlay:GetBottom()

		if containerLeft and overlayLeft then
			leftInset = overlayLeft - (containerLeft * scale)
		end

		if containerRight and overlayRight then
			rightInset = (containerRight * scale) - overlayRight
		end

		if containerTop and overlayTop then
			topInset = (containerTop * scale) - overlayTop
		end

		if containerBottom and overlayBottom then
			bottomInset = overlayBottom - (containerBottom * scale)
		end
	end

	local extraY = 0

	if extraMaxYPixels and extraMaxYPixels ~= 0 then
		extraY = extraMaxYPixels * ACAB:GetPixelStep()
	end

	-- frameWidth/frameHeight convert the container's raw size into the same
	-- space as the insets above.
	-- Real right edge: (x*scale) + frameWidth*scale - rightInset <= screenWidth
	--   => x <= (screenWidth + rightInset)/scale - frameWidth
	-- Real top edge:   (x*scale) - topInset <= screenHeight + extra
	--   => x <= (screenHeight + extra + topInset)/scale
	-- Real bottom edge (minY): (y - frameHeight)*scale + bottomInset >= 0
	--   => y >= frameHeight - bottomInset/scale
	local frameWidth = (frame and frame:GetWidth()) or 0
	local frameHeight = (frame and frame:GetHeight()) or 0

	local minX = 0
	local maxX = (screenWidthUnits + rightInset) / scale - frameWidth

	local minY = frameHeight - bottomInset / scale
	local maxY = (screenHeightUnits + extraY + topInset) / scale

	if maxX < minX then
		maxX = minX
	end

	if minY < 0 then
		minY = 0
	end

	if maxY < minY then
		maxY = minY
	end

	return minX, maxX, minY, maxY
end

-- Recomputes and re-applies a simple-page element's X/Y slider clamp
-- range from its CURRENT rendered size - call whenever anything that
-- can change that size happens live (scale drag, spacing drag, grid
-- preset pick). No-ops for pages without config.getElementFrame (i.e.
-- Latency Bar, deliberately left on the generic screen-relative range).
-- Also re-clamps the current value, in case a shrinking range no longer
-- contains it.
function ACAB:RefreshSimplePositionSliderRange(page, key)
	if not page or not page.xSlider or not page.ySlider then
		return
	end

	local config = ACAB.simpleBarPageConfigs[key]

	if not config or not config.getElementFrame then
		return
	end

	local frame = config.getElementFrame()

	if not frame then
		return
	end

	local minX, maxX, minY, maxY = ACAB:GetSimpleElementCoordinateRange(frame, config.extraMaxYPixels)

	page.xSlider:SetMinMaxValues(minX, maxX)
	page.ySlider:SetMinMaxValues(minY, maxY)

	local x = page.xSlider:GetValue()
	local y = page.ySlider:GetValue()

	if x < minX then
		ACAB:SetSliderValueUnsnapped(page.xSlider, minX)
	elseif x > maxX then
		ACAB:SetSliderValueUnsnapped(page.xSlider, maxX)
	end

	if y < minY then
		ACAB:SetSliderValueUnsnapped(page.ySlider, minY)
	elseif y > maxY then
		ACAB:SetSliderValueUnsnapped(page.ySlider, maxY)
	end
end
-------------------------------------------------------------------------
-- Reusable scrollable content area
--
-- One generic ScrollFrame + wiring helper backs every settings page/tab
-- (bar pages via contentPanel, General tab, Profiles tab), so any page
-- that grows past its available height gets scrolling with zero
-- page-specific code.
-------------------------------------------------------------------------

-- How far one mouse-wheel notch moves the scrollbar, in pixels.
local SETTINGS_SCROLL_WHEEL_STEP = 30

-- Creates a native ScrollFrame (UIPanelScrollFrameTemplate) parented to
-- `parent`, with mouse-wheel scrolling wired in. Content should be
-- parented into whatever scrollchild ACAB:UpdateScrollFrame is later given
-- for it (via scrollFrame:SetScrollChild), not into scrollFrame itself.
-- scrollbarOnLeft (optional): re-anchors the scrollbar to the LEFT side
-- instead of UIPanelScrollBarTemplate's default RIGHT side, for callers
-- like the bar-list sidebar.
function ACAB:CreateScrollFrame(parent, name, scrollbarOnLeft)
	local scrollFrame = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")

	local scrollBar = getglobal(name .. "ScrollBar")

	scrollFrame.scrollBar = scrollBar

	-- Overrides the template's native OnScrollRangeChanged (which would
	-- show/hide the scrollbar from its own internal range calc) to a no-op,
	-- making ACAB:UpdateScrollFrame the single source of truth for scrollbar
	-- visibility.
	scrollFrame:SetScript("OnScrollRangeChanged", function() end)

	if scrollBar and scrollbarOnLeft then
		scrollBar:ClearAllPoints()
		scrollBar:SetPoint("TOPRIGHT", scrollFrame, "TOPLEFT", -4, -16)
		scrollBar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMLEFT", -4, 16)
	end

	if scrollBar then
		-- Same dark backdrop as the top nav tabs (ACAB:StyleModernButton).
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
		-- Moves the scroll view in response to the slider's value changing
		-- (the up/down buttons and thumb-drag both work by changing it).
		scrollBar:SetScript("OnValueChanged", function()
			scrollFrame:SetVerticalScroll(this:GetValue())
		end)
	end

	return scrollFrame
end

-- Points `scrollFrame` at `scrollChild` (a plain Frame the caller already
-- parents its real page content into), sizes the scrollchild to
-- `requiredContentHeight` and the scrollFrame to the clamped
-- `viewportHeight`, restores scroll to `preserveScroll` (clamped to the
-- new range), and shows/hides the scrollbar depending on whether there's
-- anything to scroll. Called every time a page's content changes.
-- preserveScroll (optional): scroll offset to restore, in the same units
-- as GetVerticalScroll()/SetMinMaxValues (pixels). Omitted/nil starts at
-- the top.
function ACAB:UpdateScrollFrame(scrollFrame, scrollChild, requiredContentHeight, viewportHeight, preserveScroll)
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

		-- Each scrollframe that cares supplies its own re-layout callback at
		-- creation time (CreateSettingsFrame's ApplyBarsViewScrollbarReserves,
		-- ACAB:CreateWideContentScrollFrame) to hand the space a hidden
		-- scrollbar would have occupied back to the content.
		scrollFrame.needsScrollbar = maxScroll > 0

		if scrollFrame.applyScrollbarReserve then
			scrollFrame.applyScrollbarReserve()
			scrollChild:SetWidth(scrollFrame:GetWidth())
		end
	end
end

-- Lets other files (DefaultBars.lua's native-checkbox reconciliation)
-- check whether the settings window has been built this session without
-- forcing it into existence, unlike the ACAB:GetOrCreate*/RefreshBarList
-- functions, which create it lazily.
function ACAB:IsSettingsFrameCreated()
	return ACAB.settingsFrame ~= nil
end

-------------------------------------------------------------------------
-- Create main settings frame
-------------------------------------------------------------------------

-- A ACAB: method (not a file-local) since every GetOrCreate*Page/Panel
-- builder across all three settings files lazily creates the shell
-- through this same entry point.
function ACAB:CreateSettingsFrame()
	local f = CreateFrame(
		"Frame",
		"ACABSettingsFrame",
		UIParent
	)

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

	title:SetText("AlternativeClassicActionBars Settings")

	-------------------------------------------------------------------------
	-- Close
	-------------------------------------------------------------------------

	local closeButton = CreateFrame(
		"Button",
		"ACABSettingsCloseButton",
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
	-- Top-level view tabs ("Bars" / "General" / "Profiles")
	--
	-- ShowBarsView/ShowGeneralView/ShowProfilesView own which panel is
	-- shown, mirroring the show/hide-one-page-at-a-time pattern
	-- GetOrCreateBarPage/ShowBarPage use for individual bar pages.
	-------------------------------------------------------------------------

	f.currentView = "bars"

	-- Top nav tabs get a fading gold highlight (ACAB:CreateFadeStrip,
	-- UIWidgets.lua) instead of ACAB:StyleModernButton's default solid
	-- border swap; every other StyleModernButton call site keeps the
	-- default border-swap hover look.
	-- Matches ACAB:StyleModernButton's backdrop insets (3px each side) so
	-- the fade strip stays inside the button's black backdrop rectangle.
	local TAB_FADE_INSET = 3

	-- StyleModernButton's rest-state border color, used as the tab's
	-- "inactive" border color since tabs keep a real border for visual
	-- distinctness (unlike bar-list rows).
	local TAB_BORDER_REST_COLOR = { 0.55, 0.55, 0.55 }

	local function ApplyTabFadeHighlight(button)
		local stripWidth = 90 - (TAB_FADE_INSET * 2)
		local stripHeight = 20 - (TAB_FADE_INSET * 2)

		-- Persistent highlight for whichever tab matches the currently open
		-- view (ACAB.settingsFrame.currentView; see ACAB:RefreshActiveTabHighlight),
		-- same gold ACAB.UI_ACCENT_COLOR as the bar-list sidebar's selected
		-- row. Created first so hoverStrip draws on top of it.
		local selectStrip = ACAB:CreateFadeStrip(button, stripWidth, stripHeight)

		selectStrip:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", TAB_FADE_INSET, TAB_FADE_INSET)
		selectStrip:SetFadeColor(ACAB.UI_ACCENT_COLOR[1], ACAB.UI_ACCENT_COLOR[2], ACAB.UI_ACCENT_COLOR[3])
		selectStrip:SetPeakAlpha(0.5)
		selectStrip:Hide()

		button.tabSelectStrip = selectStrip

		-- Hover uses the neutral ACAB.UI_HOVER_COLOR, matching the bar-list
		-- sidebar's hover/select color split (white hover, gold select) so
		-- "hovering" and "currently open" stay distinguishable.
		local hoverStrip = ACAB:CreateFadeStrip(button, stripWidth, stripHeight)

		hoverStrip:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", TAB_FADE_INSET, TAB_FADE_INSET)
		hoverStrip:SetFadeColor(ACAB.UI_HOVER_COLOR[1], ACAB.UI_HOVER_COLOR[2], ACAB.UI_HOVER_COLOR[3])
		hoverStrip:SetPeakAlpha(0.5)
		hoverStrip:Hide()

		button.isHovering = false

		-- Border color tracks whichever fade is most prominent: hover wins
		-- over select, select wins over rest.
		function button:UpdateFadeBorderColor()
			if self.isHovering then
				self:SetBackdropBorderColor(ACAB.UI_HOVER_COLOR[1], ACAB.UI_HOVER_COLOR[2], ACAB.UI_HOVER_COLOR[3], 1)
			elseif self.tabSelectStrip and self.tabSelectStrip:IsShown() then
				self:SetBackdropBorderColor(ACAB.UI_ACCENT_COLOR[1], ACAB.UI_ACCENT_COLOR[2], ACAB.UI_ACCENT_COLOR[3], 1)
			else
				self:SetBackdropBorderColor(TAB_BORDER_REST_COLOR[1], TAB_BORDER_REST_COLOR[2], TAB_BORDER_REST_COLOR[3], 1)
			end
		end

		button:UpdateFadeBorderColor()

		-- Replaces the OnEnter/OnLeave StyleModernButton installed;
		-- OnMouseDown/OnMouseUp (press-nudge) are untouched.
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

	ACAB:StyleModernButton(tabBarsButton, 90, 90)
	tabBarsButton:SetText("Bars")
	ApplyTabFadeHighlight(tabBarsButton)

	tabBarsButton:SetScript(
		"OnClick",
		function()
			ACAB:ShowBarsView()
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

	ACAB:StyleModernButton(tabGeneralButton, 90, 90)
	tabGeneralButton:SetText("General")
	ApplyTabFadeHighlight(tabGeneralButton)

	tabGeneralButton:SetScript(
		"OnClick",
		function()
			ACAB:ShowGeneralView()
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

	ACAB:StyleModernButton(tabProfilesButton, 90, 90)
	tabProfilesButton:SetText("Profiles")
	ApplyTabFadeHighlight(tabProfilesButton)

	tabProfilesButton:SetScript(
		"OnClick",
		function()
			ACAB:ShowProfilesView()
		end
	)

	local tabEditModeButton = CreateFrame(
		"Button",
		nil,
		f
	)

	tabEditModeButton:SetHeight(20)

	tabEditModeButton:SetPoint(
		"LEFT",
		tabProfilesButton,
		"RIGHT",
		6,
		0
	)

	ACAB:StyleModernButton(tabEditModeButton, 90, 90)
	tabEditModeButton:SetText("Edit Mode")
	ApplyTabFadeHighlight(tabEditModeButton)

	tabEditModeButton:SetScript(
		"OnClick",
		function()
			ACAB:ShowEditModeView()
		end
	)

	f.tabButtonsByView = {
		bars = tabBarsButton,
		general = tabGeneralButton,
		profiles = tabProfilesButton,
		editmode = tabEditModeButton,
	}

	-- Matches f.currentView's initial value ("bars"); set manually here
	-- since ACAB.settingsFrame isn't assigned yet for ACAB:RefreshActiveTabHighlight
	-- to use.
	tabBarsButton.tabSelectStrip:Show()
	tabBarsButton:UpdateFadeBorderColor()

	-------------------------------------------------------------------------
	-- Divider between the tab row and the content below it. Two-point
	-- SetPoint (TOPLEFT+TOPRIGHT, no fixed width) so it stretches to match
	-- the window's width regardless of which view resized it.
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

	-- f.listPanel is the fixed viewport (visible bounds + border +
	-- scrollbar), same shape as contentScrollFrame below. f.listContent is
	-- its permanent scroll child that bar-list rows/divider get
	-- parented/anchored into (ACAB:RefreshBarList), sized to the full
	-- row-list height so ACAB:UpdateScrollFrame can turn scrolling on
	-- whenever the list has more rows than the window has room for.
	f.listPanel = ACAB:CreateScrollFrame(f, "ACABSettingsListScrollFrame", true)

	f.listPanel:SetWidth(140)
	f.listPanel:SetHeight(610)

	-- Positioned by ApplyBarsViewScrollbarReserves (below): reserves
	-- scrollbar space only while that scrollbar is actually shown.

	-- Same backdrop as contentScrollFrame below, so the row list reads as
	-- one bordered/divided container.
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

	-- Lives on the viewport (f.listPanel), not the scrolling f.listContent
	-- below, so it stays fixed at the top regardless of scroll position.
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

	-- SetWidth/SetHeight + SetScrollChild must be called immediately here,
	-- not left until the first deferred Fit, or the list renders nothing
	-- until the next-frame-deferred Fit finally runs.
	f.listContent:SetWidth(f.listPanel:GetWidth())
	f.listContent:SetHeight(610)

	f.listPanel:SetScrollChild(f.listContent)

	-------------------------------------------------------------------------
	-- Right content panel: contentScrollFrame is the fixed viewport for the
	-- Bars view, contentPanel its scroll child (ACAB:UpdateScrollFrame
	-- resizes it to fit the showing bar page). General/Profiles get their
	-- own pair (ACAB:CreateWideContentScrollFrame) instead of sharing this.
	--
	-- WARNING: a scrollframe must stay permanently paired with the
	-- scrollchild it was created with - never re-target it at a different
	-- frame, or that frame renders with no resolvable position/size.
	-------------------------------------------------------------------------

	f.contentScrollFrame = ACAB:CreateScrollFrame(f, "ACABSettingsContentScrollFrame")

	f.contentScrollFrame:SetHeight(610)

	-------------------------------------------------------------------------
	-- Bars-view horizontal geometry: both panels' widths/anchors are
	-- recomputed from whichever scrollbars are currently shown, so an
	-- unscrolled panel gets that space back. listPanel's scrollbar sits on
	-- its left, contentScrollFrame's on its right - one function owns both.
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

	ACAB.settingsFrame = f

	return f
end

-- Creates one scrollframe+scrollchild pair spanning the FULL content
-- width (the space the bar list would otherwise occupy, since it's
-- hidden in General/Profiles) - shared shape for GetOrCreateGeneralPanel/
-- GetOrCreateProfilesPanel below, each calling this once to build their
-- own independent pair (see CreateSettingsFrame's own comment on why each
-- view gets its own rather than sharing one). Returns scrollFrame,
-- scrollChild - caller stores both (e.g. ACAB.settingsFrame.generalScrollFrame/
-- generalPanel) and builds its real content into scrollChild.
function ACAB:CreateWideContentScrollFrame(name)
	local scrollFrame = ACAB:CreateScrollFrame(ACAB.settingsFrame, name)

	scrollFrame:SetHeight(610)

	-- Must read ACAB.settingsFrame:GetWidth() (a fixed literal, SetWidth(780)
	-- once in CreateSettingsFrame, never anchor-derived) rather than an
	-- anchor-implied width - an anchor-implied width is not guaranteed
	-- resolved yet the moment code right after this reads it back.
	-- Only reserves room for its own scrollbar while that bar is actually
	-- shown (ACAB:UpdateScrollFrame flips needsScrollbar and calls this back)
	-- - an unscrolled panel gets the full width instead.
	scrollFrame.applyScrollbarReserve = function()
		local reserve = scrollFrame.needsScrollbar and SETTINGS_SCROLLBAR_RESERVED_WIDTH or 0

		scrollFrame:SetWidth(ACAB.settingsFrame:GetWidth() - 18 - 18 - reserve)

		scrollFrame:ClearAllPoints()
		scrollFrame:SetPoint(
			"TOPRIGHT",
			ACAB.settingsFrame,
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
-- Default-PROFILE lock, distinct from ApplyDefaultLayoutGating below
-- (which gates the unrelated "Use Default Blizzard Layout" checkbox -
-- both gates are independent and can apply to the same controls at once).
-- The Default PROFILE must never be edited: every settings page shows a
-- red warning banner and locks its controls while it's active.
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
function ACAB:CreateProfileLockWarning(page)
	local banner = CreateFrame("Frame", nil, page)

	-- PARENTED to `page` (so it hides/shows along with it) but ANCHORED to
	-- contentPanel - `page` itself now slides DOWN by this banner's height
	-- only while the banner is actually shown (ACAB:ApplyPageBannerReserve),
	-- and the banner has to stay put in the band that opens up rather than
	-- sliding down with it.
	banner:SetPoint("TOPLEFT", ACAB.settingsFrame.contentPanel, "TOPLEFT", 0, PROFILE_LOCK_BANNER_TOP)
	banner:SetPoint("TOPRIGHT", ACAB.settingsFrame.contentPanel, "TOPRIGHT", 0, PROFILE_LOCK_BANNER_TOP)
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

	text:SetPoint("TOPLEFT", banner, "TOPLEFT", ACAB.INDENT_SECTION, -6)
	text:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -ACAB.INDENT_SECTION, -6)
	text:SetJustifyH("LEFT")
	text:SetJustifyV("TOP")
	text:SetTextColor(1, 0.15, 0.15)

	banner.text = text

	banner:Hide()

	return banner
end

-- Opens/collapses the band the profile-lock banner occupies by sliding
-- `page` down by the banner's height only while shown - same reflow
-- technique as ACAB:ReflowGeneralOverrideSliders. Works by moving `page`
-- itself (every control is anchored to it with a fixed Y); the page title
-- and the banner must stay anchored to contentPanel instead so they don't
-- move with it.
function ACAB:ApplyPageBannerReserve(page, locked)
	if not page or not ACAB.settingsFrame or not ACAB.settingsFrame.contentPanel then
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
	page:SetPoint("TOPLEFT", ACAB.settingsFrame.contentPanel, "TOPLEFT", 0, -reserve)
	page:SetPoint("BOTTOMRIGHT", ACAB.settingsFrame.contentPanel, "BOTTOMRIGHT", 0, 0)
end

-- Sets the banner's message and resizes the banner to fit however many
-- lines that message actually wraps to at the page's CURRENT width
-- (text:GetHeight() reflects real wrapped height once SetText runs, same
-- content-aware-sizing technique UIWidgets.lua's dialog uses) - so a
-- longer message, a narrower window, or a translation never gets cut off
-- rather than just being clamped to PROFILE_LOCK_BANNER_HEIGHT's own
-- (generous, but not guaranteed-sufficient) reserved space.
local function SetProfileLockBannerMessage(banner, message)
	-- Must set explicit SetWidth on BOTH banner and text, computed from
	-- `page`'s own current width - a TOPLEFT+TOPRIGHT anchor pair alone
	-- does not reliably wrap text in this environment (renders as one long
	-- line, clipped by the ancestor scrollframe instead of wrapping).
	local page = banner:GetParent()
	local width = page:GetWidth()

	if width and width > 0 then
		banner:SetWidth(width)
		banner.text:SetWidth(width - (2 * ACAB.INDENT_SECTION))
	end

	banner.text:SetText(message)
	banner:SetHeight((banner.text:GetHeight() or 0) + 12)
end

-- A ACAB: method (not a file-local) since SettingsBars.lua's
-- RefreshBarSettingsPage/CreateBarListRow/RefreshBarList call it too, not
-- just this file's own gating family.
function ACAB:LockControl(control, locked)
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

-- Greys `control` like ACAB:LockControl, but never touches EnableMouse OR
-- Disable()/Enable() - both confirmed live on this client to also swallow
-- OnEnter/OnLeave entirely (not just OnClick), which would silently kill
-- the "why is this locked" tooltip a caller wired via
-- CreateLabeledCheckbox's config.lockedText. Only stamps control.ACABLocked;
-- the actual click-block lives in CreateLabeledCheckbox's own OnClick
-- wrapper (UIWidgets.lua), which checks this same field and reverts the
-- toggle instead of calling through to config.onClick while locked.
function ACAB:LockControlKeepingTooltip(control, locked)
	control.ACABLocked = locked and true or false

	control:SetAlpha(locked and 0.5 or 1)
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
	"xSlider", "ySlider", "xStepperBigMinus", "xStepperMinus", "xStepperPlus", "xStepperBigPlus",
	"yStepperBigMinus", "yStepperMinus", "yStepperPlus", "yStepperBigPlus", "xValueClick", "yValueClick",
	"buttonSizeSlider", "spacingSlider",
	"scaleSlider", "resetPositionButton", "enableCheckbox",
	"buttonCountMinus", "buttonCountPlus", "pageIndicatorSlider",
	"orientationCheckbox", "keyRingCheckbox", "keyRingScaleSlider",
	"betterExpBarCheckbox", "expBarShowLevelCheckbox",
	"expBarShowCurrentOverMaxCheckbox", "expBarShowPercentCheckbox",
	"expBarShowRestedPercentCheckbox", "expBarShowRestedTotalCheckbox",
	"expBarFontSizeSlider", "earnedColorSwatch", "restedColorSwatch",
	"expBarTextColorSwatch", "expBarGlowPulseIntervalSlider",
	"useVanillaPetBarCheckbox", "condenseEmptyPetSlotsCheckbox",
	"animateAutoCastGlowCheckbox", "useVanillaStanceBarCheckbox",
	"hoverOnlyCheckbox", "hoverDurationSlider",
}

-- alsoCheckLayoutLock: true on the pages the Default-layout lock also
-- applies to (bar 1's page, every simple/native-backed page) - the
-- banner shows for THAT lock too there, with its own message, and the
-- SAME combined lock now drives control-locking below too (user
-- decision: while EITHER lock is active, enable/disable is the only
-- thing that should stay available on a numbered default bar - every
-- other control locks the same way under either reason).
function ACAB:ApplyProfileLockGating(page, alsoCheckLayoutLock)
	local profileLocked = self:IsDefaultProfileActive()
	local layoutLocked = alsoCheckLayoutLock and (ACABDB.useDefaultLayout == true)
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
	ACAB:ApplyPageBannerReserve(page, locked)

	-- Numbered default bars (1-5, Pet Bar) keep enable/disable available
	-- even while everything else locks - every other page (extra bars 6-9,
	-- simple/native-backed pages) has NO exemption, its enable checkbox
	-- locks exactly like every other control.
	local barId = page.barId
	local isNumberedDefaultBar = type(barId) == "number" and ACAB:IsDefaultBarFamilyId(barId)

	local i

	for i = 1, table.getn(PROFILE_LOCK_CONTROL_NAMES) do
		local name = PROFILE_LOCK_CONTROL_NAMES[i]
		local control = page[name]

		if control then
			local exempt = isNumberedDefaultBar and name == "enableCheckbox"

			ACAB:LockControl(control, locked and not exempt)
		end
	end

	if page.gridSwatches then
		for i = 1, table.getn(page.gridSwatches) do
			ACAB:LockControl(page.gridSwatches[i], locked)
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
					ACAB:LockControl(dropdownButton, locked)
				else
					ACAB:LockControl(row.dropdown, locked)
				end
			end
		end
	end
end

-------------------------------------------------------------------------
-- Default-layout gating (General tab's "Use Default Blizzard Layout")
--
-- Uses EnableMouse(false) rather than Slider/Button Enable()/Disable():
-- a universal Frame method that works on both sliders and the plain
-- template-less grid swatch buttons, unlike Disable() which only
-- reliably affects templated Button widgets. Only simple/native-backed
-- pages call this; default bars (1-5) get the same effect via
-- ACAB:ApplyProfileLockGating's alsoCheckLayoutLock instead; custom bars
-- never gate on this.
-------------------------------------------------------------------------

-- A ACAB: method (not a file-local) since SettingsBars.lua's
-- RefreshSimpleBarPage calls it too, not just this file's own gating family.
function ACAB:ApplyDefaultLayoutGating(page, interactive)
	local alpha = interactive and 1 or 0.5

	if page.xSlider then
		page.xSlider:EnableMouse(interactive)
		page.xSlider:SetAlpha(alpha)
	end

	if page.ySlider then
		page.ySlider:EnableMouse(interactive)
		page.ySlider:SetAlpha(alpha)
	end

	-- Stepper buttons and the click-to-edit value readouts gate the same
	-- way the sliders they flank do - Buttons additionally need
	-- Disable()/Enable(), see LockControl's comment above.
	local positionButtonNames = {
		"xStepperBigMinus", "xStepperMinus", "xStepperPlus", "xStepperBigPlus",
		"yStepperBigMinus", "yStepperMinus", "yStepperPlus", "yStepperBigPlus",
		"xValueClick", "yValueClick",
	}

	local pi

	for pi = 1, table.getn(positionButtonNames) do
		local control = page[positionButtonNames[pi]]

		if control then
			control:EnableMouse(interactive)
			control:SetAlpha(alpha)

			if interactive then
				control:Enable()
			else
				control:Disable()
			end
		end
	end

	if page.buttonSizeSlider then
		page.buttonSizeSlider:EnableMouse(interactive)
		page.buttonSizeSlider:SetAlpha(alpha)
	end

	if page.spacingSlider then
		page.spacingSlider:EnableMouse(interactive)
		page.spacingSlider:SetAlpha(alpha)
	end

	if page.hoverOnlyCheckbox then
		page.hoverOnlyCheckbox:EnableMouse(interactive)
		page.hoverOnlyCheckbox:SetAlpha(alpha)

		-- EnableMouse alone doesn't block this template's OnClick, see LockControl's comment above.
		if interactive then
			page.hoverOnlyCheckbox:Enable()
		else
			page.hoverOnlyCheckbox:Disable()
		end
	end

	if page.hoverDurationSlider then
		page.hoverDurationSlider:EnableMouse(interactive)
		page.hoverDurationSlider:SetAlpha(alpha)
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
function ACAB:RefreshDefaultLayoutGatingOnAllPages()
	if not ACAB.settingsFrame then
		return
	end

	local i

	for i = 1, table.getn(ACAB.DEFAULT_BAR_IDS) do
		local id = ACAB.DEFAULT_BAR_IDS[i]

		if ACAB.settingsFrame.pages[id] then
			self:RefreshBarSettingsPage(id)
		end
	end

	-- Bag Bar / Micro Menu / Latency Bar / Experience Bar / Cast Bar are
	-- also gated on useDefaultLayout (RefreshSimpleBarPage below), so their
	-- pages need the same live refresh if already built/cached. The Stance
	-- Bar (like the Pet Bar) is covered by the ACAB.DEFAULT_BAR_IDS loop
	-- above instead, since it's keyed by its own numeric id now.
	local specialKeys = { "bagbar", "micromenu", "latencybar", "expbar", "castbar", "tooltip" }
	local si

	for si = 1, table.getn(specialKeys) do
		if ACAB.settingsFrame.pages[specialKeys[si]] then
			self:RefreshBarSettingsPage(specialKeys[si])
		end
	end
end

-------------------------------------------------------------------------
-- Dynamic content-panel/window height: measures the real on-screen bottom
-- edge (Frame:GetTop()/GetBottom()) of whichever controls are actually
-- shown, so each page (which vary in which controls they have) gets a
-- window sized to its own content instead of a fixed size tuned for the
-- busiest page.
-------------------------------------------------------------------------

-- Distance from the settings window's own top edge down to
-- contentPanel/listPanel's top (matches their "-64" TOPRIGHT/TOPLEFT
-- anchor offset in CreateSettingsFrame, leaving room for the tab/content
-- divider line) and from their bottom edge down to the window's own
-- bottom edge - the fixed "chrome" every view's content sits inside,
-- regardless of which view/page is showing.
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

-- Deepest distance from `referenceTop` (scroll child's real GetTop()) down
-- to any candidate's bottom edge - how much vertical room the content
-- needs.
--
-- WARNING: measured as a DELTA between two live positions, not a computed
-- screen-center estimate - the settings window is movable, so a position-
-- derived estimate goes wrong (sometimes shorter than the content, which
-- also silently suppresses the scrollbar) once dragged. A top-to-bottom
-- delta stays correct wherever the window is.
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

-- Resizes `scrollChildPanel` (whichever view is being fitted)/listPanel/
-- the outer window to fit the lowest bottom edge in candidateList,
-- floored at SETTINGS_CONTENT_MIN_HEIGHT and capped at the screen-
-- relative max (ACAB:UpdateScrollFrame turns scrolling on for whatever
-- doesn't fit).
-- listCandidateList (optional): fits/scrolls the bar-list sidebar
-- independently using the same shared viewportHeight, so an overlong
-- list scrolls instead of rendering past the window's bottom edge.
-- minContentHeight (optional): floor on top of SETTINGS_CONTENT_MIN_HEIGHT
-- (see FitSettingsWindowToBarPage's baseline).
-- noMinFloor (optional): skips SETTINGS_CONTENT_MIN_HEIGHT for a view
-- (Profiles) meant to shrink-to-fit its own short content.
--
-- Returns the measured (unclamped, unfloored) content height.
local function ApplySettingsHeightFromCandidates(candidateList, scrollFrame, scrollChildPanel, listCandidateList, minContentHeight, noMinFloor)
	if not ACAB.settingsFrame or not scrollFrame or not scrollChildPanel then
		return nil
	end

	-- Captured before either scroll position gets reset below, so the
	-- ACAB:UpdateScrollFrame calls at the bottom of this function can
	-- restore the user's actual scroll position (clamped to whatever the
	-- new content size allows) instead of snapping back to the top on
	-- every re-fit.
	local previousContentScroll = scrollFrame:GetVerticalScroll()
	local previousListScroll = listCandidateList and ACAB.settingsFrame.listPanel
		and ACAB.settingsFrame.listPanel:GetVerticalScroll()

	-- Both scroll positions have to be reset to the top BEFORE measuring:
	-- GetTop()/GetBottom() read real SCREEN positions that shift with the
	-- current scroll offset, so a previously-scrolled view would otherwise
	-- measure as shorter than it really is.
	scrollFrame:SetVerticalScroll(0)

	if listCandidateList and ACAB.settingsFrame.listPanel then
		ACAB.settingsFrame.listPanel:SetVerticalScroll(0)
	end

	-- Every candidate is a descendant of scrollChildPanel, which is
	-- PERMANENTLY the given scrollFrame's scroll child (set once, at
	-- creation - see CreateSettingsFrame/ACAB:CreateWideContentScrollFrame's
	-- own comments on why nothing here ever re-targets SetScrollChild at a
	-- different frame), so its own top is the right reference to measure
	-- each candidate's depth from.

	-- Top-down resolve pass. REQUIRED, not a debug leftover - the discarded
	-- return values ARE the point, the CALL is the work (see
	-- docs/01-Environment-Capability-Analysis.md §5af).
	--
	-- WARNING: frame rects resolve lazily on this client, against the
	-- anchor's own cached rect. SetVerticalScroll(0) above moves this
	-- subtree without re-resolving it, so reading a child while its
	-- ancestor is still stale caches that child against the ancestor's OLD
	-- position, and the measurement below then reads back confidently
	-- wrong values. Resolving top-down (scrollChildPanel, then every
	-- measured frame) avoids that.
	--
	-- Live-verified: dropping either loop, or reading children before
	-- scrollChildPanel, brings the bug back (panel measures short,
	-- everything below the toggled control becomes unreachable).
	scrollChildPanel:GetTop()

	local resolveI

	for resolveI = 1, table.getn(candidateList) do
		local resolveFrame = candidateList[resolveI]

		if resolveFrame.GetBottom then
			resolveFrame:GetBottom()
		end
	end

	if scrollChildPanel.hotkeyTitle then
		local resolveNames = {
			"macroTextCheckbox", "macroTitle", "macroSlider", "macroValueText", "macroResetButton",
			"hotkeyTitle", "hotkeySlider", "hotkeyValueText", "hotkeyResetButton",
			"countTitle", "countSlider", "countValueText", "countResetButton",
			"modernBorderStyleCheckbox",
		}

		local resolveJ

		for resolveJ = 1, table.getn(resolveNames) do
			local resolveFrame = scrollChildPanel[resolveNames[resolveJ]]

			if resolveFrame then
				resolveFrame:GetBottom()
			end
		end
	end

	local contentDepth = MeasureDeepestExtent(candidateList, scrollChildPanel:GetTop())

	local listDepth = nil

	if listCandidateList and ACAB.settingsFrame.listContent then
		listDepth = MeasureDeepestExtent(listCandidateList, ACAB.settingsFrame.listContent:GetTop())
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

	if not noMinFloor and sharedRequirement < SETTINGS_CONTENT_MIN_HEIGHT then
		sharedRequirement = SETTINGS_CONTENT_MIN_HEIGHT
	end

	local contentHeight = measuredContentHeight

	if not noMinFloor and contentHeight < SETTINGS_CONTENT_MIN_HEIGHT then
		contentHeight = SETTINGS_CONTENT_MIN_HEIGHT
	end

	-- Clamps the visible viewport height to a screen-relative ceiling.
	-- Real content height (above) stays unclamped for ACAB:UpdateScrollFrame.
	local maxViewportHeight = (GetScreenHeight() * SETTINGS_MAX_HEIGHT_RATIO)
		- SETTINGS_CHROME_TOP - SETTINGS_CHROME_BOTTOM

	local viewportHeight = sharedRequirement

	if viewportHeight > maxViewportHeight then
		viewportHeight = maxViewportHeight
	end

	ACAB:UpdateScrollFrame(
		scrollFrame,
		scrollChildPanel,
		contentHeight,
		viewportHeight,
		previousContentScroll
	)

	if listCandidateList and ACAB.settingsFrame.listPanel and ACAB.settingsFrame.listContent then
		ACAB:UpdateScrollFrame(
			ACAB.settingsFrame.listPanel,
			ACAB.settingsFrame.listContent,
			listContentHeight,
			viewportHeight,
			previousListScroll
		)
	elseif ACAB.settingsFrame.listPanel then
		ACAB.settingsFrame.listPanel:SetHeight(viewportHeight)
	end

	ACAB.settingsFrame:SetHeight(
		viewportHeight + SETTINGS_CHROME_TOP + SETTINGS_CHROME_BOTTOM
	)

	return measuredContentHeight
end

-- Bars view: combines the current bar page's own controls with the bar
-- list's rows - both are visible side by side in this view, so the
-- window has to be tall enough for whichever of the two is actually
-- taller (e.g. a short custom-bar page next to a long bar list with many
-- custom bars added).
function ACAB:FitSettingsWindowToBarPage(barId)
	if not ACAB.settingsFrame then
		return
	end

	local page = ACAB.settingsFrame.pages[barId]

	if not page then
		return
	end

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, page.hoverOnlyCheckbox)
	n = AppendCandidate(candidates, n, page.hoverDurationSlider)
	n = AppendCandidate(candidates, n, page.hoverDurationValueText)
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
	n = AppendCandidate(candidates, n, page.useVanillaPetBarCheckbox)

	-- Scale/Orientation controls, present on the simple bar pages
	-- (Stance Bar/Bag Bar/Micro Menu) alongside Spacing above - included
	-- here (the shared bar-page height-fit function, used for both
	-- default/custom AND simple pages) since FitSettingsWindowToBarPage
	-- already looks up ACAB.settingsFrame.pages[barId] generically regardless
	-- of key type (numeric bar id or string simple-page key).
	n = AppendCandidate(candidates, n, page.scaleValueText)
	n = AppendCandidate(candidates, n, page.orientationCheckbox)
	n = AppendCandidate(candidates, n, page.keyRingCheckbox)
	n = AppendCandidate(candidates, n, page.keyRingScaleValueText)

	-- "Better Experience Bar" + its 5 text toggles + Font Size slider + 3
	-- color pickers + Reset Colors button + Pulse Interval slider
	-- (Experience Bar page only) - expBarGlowPulseIntervalValueText is the
	-- effective lowest control on this page, so it's what actually drives
	-- this page's real fitted height; every other entry here is still
	-- listed for the same "include every real candidate" thoroughness this
	-- list already follows.
	n = AppendCandidate(candidates, n, page.betterExpBarCheckbox)
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

	-- Stance/Page Bar Assignment rows - only ever present on bar 1's page.
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

	-- Stance Bar's "no stances currently available" message (0 live forms)
	-- takes the grid swatches' place - same candidate treatment.
	n = AppendCandidate(candidates, n, page.noStancesText)

	n = AppendCandidate(candidates, n, page.useVanillaStanceBarCheckbox)

	-- Measured/fitted SEPARATELY from the page's own candidates above (own
	-- listCandidates table, not appended into `candidates`) - the bar-list
	-- sidebar now scrolls independently of the content page
	-- (ACAB:CreateScrollFrame's ACAB.settingsFrame.listPanel/listContent), so it
	-- needs its own true bottom-most-row measurement rather than being
	-- merged into one combined list, even though the window's own overall
	-- height still ends up driven by whichever of the two is taller (see
	-- ApplySettingsHeightFromCandidates' own listCandidateList handling).
	local listCandidates = {}
	local listN = 0

	if ACAB.settingsFrame.barButtons then
		local i

		for i = 1, table.getn(ACAB.settingsFrame.barButtons) do
			listN = AppendCandidate(listCandidates, listN, ACAB.settingsFrame.barButtons[i])
		end
	end

	-- The scrollchild is ACAB.settingsFrame.contentPanel itself, NOT `page` -
	-- every bar page uses page:SetAllPoints(ACAB.settingsFrame.contentPanel)
	-- (GetOrCreateBarPage), so `page` always just mirrors contentPanel's
	-- own rect rather than having independently meaningful dimensions.
	local measured = ApplySettingsHeightFromCandidates(
		candidates,
		ACAB.settingsFrame.contentScrollFrame,
		ACAB.settingsFrame.contentPanel,
		listCandidates,
		ACAB.settingsFrame.standardBarPageHeight
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
		if not ACAB.settingsFrame.standardBarPageHeight or measured > ACAB.settingsFrame.standardBarPageHeight then
			ACAB.settingsFrame.standardBarPageHeight = measured
		end
	end
end

-- General view: no bar list is shown here, just its checkboxes/sliders.
function ACAB:FitSettingsWindowToGeneralView()
	if not ACAB.settingsFrame or not ACAB.settingsFrame.generalPanel then
		return
	end

	local panel = ACAB.settingsFrame.generalPanel

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, panel.useDefaultLayoutCheckbox)
	n = AppendCandidate(candidates, n, panel.tintWholeButtonCheckbox)
	n = AppendCandidate(candidates, n, panel.disableBlizzardArtCheckbox)
	n = AppendCandidate(candidates, n, panel.mainBarPaginationCheckbox)
	n = AppendCandidate(candidates, n, panel.mainBarStanceSwapCheckbox)

	-- Stance/Page Bar Assignment rows live on bar 1's own settings page -
	-- see FitSettingsWindowToBarPage for their candidate handling.

	n = AppendCandidate(candidates, n, panel.macroTextCheckbox)
	n = AppendCandidate(candidates, n, panel.macroValueText)
	n = AppendCandidate(candidates, n, panel.macroResetButton)

	n = AppendCandidate(candidates, n, panel.hotkeyValueText)
	n = AppendCandidate(candidates, n, panel.hotkeyResetButton)
	n = AppendCandidate(candidates, n, panel.countValueText)
	n = AppendCandidate(candidates, n, panel.countResetButton)
	n = AppendCandidate(candidates, n, panel.modernBorderStyleCheckbox)
	n = AppendCandidate(candidates, n, panel.globalSpacingCheckbox)
	n = AppendCandidate(candidates, n, panel.globalSpacingSlider)
	n = AppendCandidate(candidates, n, panel.globalSpacingValueText)
	n = AppendCandidate(candidates, n, panel.globalButtonSizeCheckbox)
	n = AppendCandidate(candidates, n, panel.globalButtonSizeSlider)
	n = AppendCandidate(candidates, n, panel.globalButtonSizeValueText)
	n = AppendCandidate(candidates, n, panel.bypassBar2DepCheckbox)

	-- "Enable Better Experience Bar" lives on the Experience Bar's own
	-- settings page - see FitSettingsWindowToBarPage for its candidate
	-- handling.

	ApplySettingsHeightFromCandidates(candidates, ACAB.settingsFrame.generalScrollFrame, panel)
end
function ACAB:FitSettingsWindowToProfilesView()
	if not ACAB.settingsFrame or not ACAB.settingsFrame.profilesPanel then
		return
	end

	local panel = ACAB.settingsFrame.profilesPanel

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, panel.profileDropdown)
	n = AppendCandidate(candidates, n, panel.exportButton)
	n = AppendCandidate(candidates, n, panel.copyButton)
	n = AppendCandidate(candidates, n, panel.importButton)
	n = AppendCandidate(candidates, n, panel.deleteButton)

	-- Profiles is a short page by nature - shrink-to-fit instead of
	-- matching the Bars/General views' SETTINGS_CONTENT_MIN_HEIGHT floor.
	ApplySettingsHeightFromCandidates(candidates, ACAB.settingsFrame.profilesScrollFrame, panel, nil, nil, true)
end
function ACAB:FitSettingsWindowToEditModeView()
	if not ACAB.settingsFrame or not ACAB.settingsFrame.editModePanel then
		return
	end

	local panel = ACAB.settingsFrame.editModePanel

	local candidates = {}
	local n = 0

	n = AppendCandidate(candidates, n, panel.snapToAdjacentCheckbox)
	n = AppendCandidate(candidates, n, panel.showLayoutGridCheckbox)
	n = AppendCandidate(candidates, n, panel.snapToGridCheckbox)
	n = AppendCandidate(candidates, n, panel.useCustomGridSizeCheckbox)
	n = AppendCandidate(candidates, n, panel.customGridSizeSlider)
	n = AppendCandidate(candidates, n, panel.customGridSizeValueText)

	-- Edit Mode is a short page by nature - shrink-to-fit instead of
	-- matching the Bars/General views' SETTINGS_CONTENT_MIN_HEIGHT floor.
	ApplySettingsHeightFromCandidates(candidates, ACAB.settingsFrame.editModeScrollFrame, panel, nil, nil, true)
end
-------------------------------------------------------------------------
-- Show settings
-------------------------------------------------------------------------

function ACAB:ShowSettingsFrame()
	if not ACAB.settingsFrame then
		ACAB:CreateSettingsFrame()
	end

	self:RefreshBarList()

	ACAB.settingsFrame:Show()

	if not ACAB.settingsFrame.activeBarId then
		self:ShowBarPage(1)
	elseif ACAB.settingsFrame.currentView == "general" then
		ACAB:DeferFit(function() ACAB:FitSettingsWindowToGeneralView() end)
	elseif ACAB.settingsFrame.currentView == "profiles" then
		ACAB:DeferFit(function() ACAB:FitSettingsWindowToProfilesView() end)
	elseif ACAB.settingsFrame.currentView == "editmode" then
		ACAB:DeferFit(function() ACAB:FitSettingsWindowToEditModeView() end)
	else
		-- RefreshBarList (above) just rebuilt the bar-list rows from
		-- scratch (e.g. a bar added/removed while the window was closed),
		-- so even though the active page itself isn't changing here, the
		-- window still needs to refit against the new row count.
		ACAB:DeferFit(function() ACAB:FitSettingsWindowToBarPage(ACAB.settingsFrame.activeBarId) end)
	end
end

-------------------------------------------------------------------------
-- Toggle settings
-------------------------------------------------------------------------

function ACAB:ToggleSettingsFrame()
	if not ACAB.settingsFrame then
		ACAB:CreateSettingsFrame()
	end

	if ACAB.settingsFrame:IsShown() then
		ACAB.settingsFrame:Hide()
	else
		self:ShowSettingsFrame()
	end
end
