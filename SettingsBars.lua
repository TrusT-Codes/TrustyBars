-- SettingsBars.lua
-- Bar-page builders split out of Settings.lua: default/custom bar pages
-- (GetOrCreateBarPage), native-frame "simple" pages (CreateSimpleBarPage/
-- GetOrCreateSimpleBarPage/RefreshSimpleBarPage), the shared refresh/gating
-- entry point (RefreshBarSettingsPage), the bar-list sidebar (CreateBarListRow/
-- RefreshBarList), bar-page navigation (ShowBarPage/OpenBarSettings/
-- OpenDefaultBarSettings), and the Main Bar stance/page assignment rows
-- (RebuildMainBarAssignmentRows) and default-layout toggle
-- (ApplyUseDefaultLayoutChange).
--
-- Engine-invoked script handlers (OnClick, OnEvent, OnEnter, OnLeave, ...)
-- receive the frame via the global `this`, never as a `self` parameter.

local ACAB = AlternativeClassicActionBars


-- The 6 fixed grid presets, in display order; each totals
-- ACAB.MAX_BAR_BUTTONS (12) cells.
local GRID_PRESETS = {
	{ rows = 1,  cols = 12 },
	{ rows = 2,  cols = 6  },
	{ rows = 3,  cols = 4  },
	{ rows = 4,  cols = 3  },
	{ rows = 6,  cols = 2  },
	{ rows = 12, cols = 1  },
}

-- Pet Bar only ever has 10 real pool buttons (identity-mapped to pet slots
-- 1-10, see Core.lua's SeedOneDefaultBar) - its own preset set totals 10
-- cells instead of GRID_PRESETS' 12, so every preset actually fills the bar.
local PET_BAR_GRID_PRESETS = {
	{ rows = 1,  cols = 10 },
	{ rows = 2,  cols = 5  },
	{ rows = 5,  cols = 2  },
	{ rows = 10, cols = 1  },
}

-- Micro Menu always has exactly 8 fixed named buttons - its own preset set
-- totals 8 cells instead of GRID_PRESETS' 12.
local MICRO_MENU_GRID_PRESETS = {
	{ rows = 1, cols = 8 },
	{ rows = 2, cols = 4 },
	{ rows = 4, cols = 2 },
	{ rows = 8, cols = 1 },
}

-- Stance Bar's usable form count varies per class/talent/session (commonly
-- 0-4, but not hardcoded to that range) - unlike Pet Bar's fixed 10, its
-- preset list can't be a static table. Returns every exact factor-pair
-- (rows, cols) of the given live count N, e.g. N=4 -> 4x1, 2x2, 1x4; N=3 ->
-- 3x1, 1x3; N=1 -> 1x1. Empty table for N <= 0 (no stances available).
local function GetStanceBarGridOptions(count)
	local presets = {}
	local n = 0

	if not count or count <= 0 then
		return presets
	end

	local d

	for d = 1, count do
		if count - (math.floor(count / d) * d) == 0 then
			n = n + 1
			presets[n] = { rows = d, cols = count / d }
		end
	end

	return presets
end

-- Which preset list a given bar's page builds its Grid Layout swatches from.
local function GetGridPresetsForBar(barId)
	if barId == ACAB.PET_BAR_ID then
		return PET_BAR_GRID_PRESETS
	end

	if barId == "micromenu" then
		return MICRO_MENU_GRID_PRESETS
	end

	if barId == ACAB.STANCE_BAR_ID then
		local liveCount = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

		if liveCount > ACAB.MAX_STANCE_BUTTONS then
			liveCount = ACAB.MAX_STANCE_BUTTONS
		end

		return GetStanceBarGridOptions(liveCount)
	end

	return GRID_PRESETS
end

-- Friendly names for the 5 fixed default bars (1-5) live on
-- ACAB.DEFAULT_BAR_NAMES (Core.lua). GetBarDisplayName below delegates to
-- ACAB:GetBarDisplayName for the default-bar/Extra-Bar case.

-- Friendly names for the Bag Bar / Micro Menu pages, keyed by string
-- ("bagbar"/"micromenu") so they never collide with the numeric
-- default-bar (1-5)/custom-bar (6+) id scheme. The Stance Bar (like the
-- Pet Bar) is keyed by its own numeric ACAB.STANCE_BAR_ID instead, and gets
-- its display name from ACAB:GetBarDisplayName (Core.lua's
-- DEFAULT_BAR_NAMES) via the fallthrough below.
local SIMPLE_BAR_NAMES = {
	bagbar = "Bag Bar",
	micromenu = "Micro Menu",
	latencybar = "Latency Bar",
	expbar = "Experience Bar",
	castbar = "Cast Bar",
	tooltip = "Tooltip",
}


-- True while the Pet Bar's "Use Vanilla Pet Bar" checkbox is on -
-- GetOrCreateBarPage/RefreshBarSettingsPage route the Pet Bar's numeric id
-- to the simple-page builder (ACAB.simpleBarPageConfigs[ACAB.PET_BAR_ID], set up
-- alongside stance/bagbar/etc. further below) only while this is true;
-- otherwise it uses the normal full grid/spacing/button-size default-bar
-- page every other numbered default bar gets.
local function IsPetBarNativeMode()
	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[ACAB.PET_BAR_ID]

	return cfg and cfg.useNativePetBar == true
end

-- Same role as IsPetBarNativeMode above, for the Stance Bar's own
-- styled-mode-only toggle (cfg.useNativeStanceBar).
local function IsStanceBarNativeMode()
	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[ACAB.STANCE_BAR_ID]

	return cfg and cfg.useNativeStanceBar == true
end

-- Extra Bars use internal ids 6-9 (ACAB.EXTRA_BAR_ID_START/EXTRA_BAR_COUNT,
-- Core.lua; ids 1-5 reserved for default bars) but display numbered from 1.
local function GetBarDisplayName(barId, isDefault)
	if SIMPLE_BAR_NAMES[barId] then
		return SIMPLE_BAR_NAMES[barId]
	end

	return ACAB:GetBarDisplayName(barId)
end
-------------------------------------------------------------------------
-- Hover-only slider show/hide reflow
--
-- The duration slider only occupies space while its checkbox is checked; everything below it on the page shifts to match.
-------------------------------------------------------------------------

-- Registers `frame` (positioned at its "collapsed" baseline x/y) so ReflowRowsBelowHoverOnly can shift it when the slider toggles.
-- Defined as a ACAB: method, not a file-local, since Lua 5.0 caps a function at 32 upvalues and GetOrCreateBarPage is already close to it.
function ACAB:AddHoverOnlyReflowRow(page, frame, x, y)
	if not frame then
		return
	end

	if not page.hoverOnlyReflowRows then
		page.hoverOnlyReflowRows = {}
	end

	table.insert(page.hoverOnlyReflowRows, { frame = frame, x = x, y = y })
end

-- Shifts every registered row by `sliderRowHeight` while the slider is shown, or back to baseline while hidden.
-- page.hoverOnlyExtraReflow (optional) covers content that can't just be repositioned, like regenerated Grid Layout swatches.
function ACAB:ReflowRowsBelowHoverOnly(page, sliderShown, sliderRowHeight)
	local offset = sliderShown and sliderRowHeight or 0

	if page.hoverOnlyReflowRows then
		local i

		for i = 1, table.getn(page.hoverOnlyReflowRows) do
			local row = page.hoverOnlyReflowRows[i]

			row.frame:ClearAllPoints()
			row.frame:SetPoint("TOPLEFT", page, "TOPLEFT", row.x, row.y - offset)
		end
	end

	if page.hoverOnlyExtraReflow then
		page.hoverOnlyExtraReflow(offset)
	end
end

-- Shown instead of the normal explanatory tooltip whenever this checkbox
-- is locked (RefreshSimpleBarPage's petLocked/stanceLocked, both cases:
-- Default Layout or Default Profile) - forcing native mode is what makes
-- Stance/Pet Bar's own position/shape controls stay usable in that state,
-- so switching AWAY from native there isn't allowed.
local VANILLA_MODE_LOCKED_TEXT =
	"Can't change while using Default Blizzard Layout / Profile. Disable " ..
	"in General Settings to enable this Setting"

-- Shared "Use Vanilla Pet Bar" checkbox, added to both the Pet Bar's full grid page and its simple/native-mode page.
-- Switching mode only takes effect on the next login (both build paths run once at PLAYER_LOGIN).
local function CreateUseVanillaPetBarCheckbox(page, y)
	-- Native mode's real PetActionButton1-10 aren't Bar.lua/Button.lua pool buttons, so they're outside Hoverbind's dispatch system.
	local checkbox = ACAB:CreateLabeledCheckbox(page, "ACABPetBarUseVanillaCheckbox", {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, y },
		label = "Use Vanilla Pet Bar",
		tooltip = {
			title = "Use Vanilla Pet Bar",
			lines = {
				"While enabled, this addon's Hoverbind mode cannot bind keys on " ..
				"the Pet Bar. Use the real Blizzard Keybindings menu instead, or " ..
				"disable this option.",
			},
		},
		lockedText = VANILLA_MODE_LOCKED_TEXT,
		onClick = function()
			local checked = this:GetChecked() and true or false
			local clickedCheckbox = this

			ACAB:ShowDialog({
				title = "Use Vanilla Pet Bar",
				message = "Switching the Pet Bar's style rebuilds its buttons and requires a UI reload. " ..
					"While enabled, this addon's Hoverbind mode cannot bind keys on the Pet Bar - use " ..
					"the real Blizzard Keybindings menu instead, or disable this option.",
				mode = "confirm",
				buttons = {
					{
						text = "Reload Now",
						isDefault = true,
						onClick = function()
							local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]

							if cfg then
								cfg.useNativePetBar = checked
							end

							ReloadUI()
						end,
					},
					{
						text = "Cancel",
						onClick = function()
							clickedCheckbox:SetChecked(not checked)
						end,
					},
				},
			})
		end,
	})

	page.useVanillaPetBarCheckbox = checkbox

	return checkbox
end

-- Mirrors CreateUseVanillaPetBarCheckbox exactly, for the Stance Bar's own
-- styled-mode-only toggle (cfg.useNativeStanceBar). Added to both the
-- Stance Bar's full grid page and its native/simple page, same as Pet Bar.
local function CreateUseVanillaStanceBarCheckbox(page, y)
	-- Native mode's real ShapeshiftButton1-N aren't Bar.lua/Button.lua pool buttons, so they're outside Hoverbind's dispatch system.
	local checkbox = ACAB:CreateLabeledCheckbox(page, "ACABStanceBarUseVanillaCheckbox", {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, y },
		label = "Use Vanilla Stance Bar",
		tooltip = {
			title = "Use Vanilla Stance Bar",
			lines = {
				"While enabled, this addon's Hoverbind mode cannot bind keys on " ..
				"the Stance Bar. Use the real Blizzard Keybindings menu instead, or " ..
				"disable this option.",
			},
		},
		lockedText = VANILLA_MODE_LOCKED_TEXT,
		onClick = function()
			local checked = this:GetChecked() and true or false
			local clickedCheckbox = this

			ACAB:ShowDialog({
				title = "Use Vanilla Stance Bar",
				message = "Switching the Stance Bar's style rebuilds its buttons and requires a UI reload. " ..
					"While enabled, this addon's Hoverbind mode cannot bind keys on the Stance Bar - use " ..
					"the real Blizzard Keybindings menu instead, or disable this option.",
				mode = "confirm",
				buttons = {
					{
						text = "Reload Now",
						isDefault = true,
						onClick = function()
							local cfg = ACABDB.defaultBars[ACAB.STANCE_BAR_ID]

							if cfg then
								cfg.useNativeStanceBar = checked
							end

							ReloadUI()
						end,
					},
					{
						text = "Cancel",
						onClick = function()
							clickedCheckbox:SetChecked(not checked)
						end,
					},
				},
			})
		end,
	})

	page.useVanillaStanceBarCheckbox = checkbox

	return checkbox
end

-- Shared "Condense empty Button Space" checkbox, added next to "Use
-- Vanilla Pet Bar" above on both Pet Bar pages. Pure visibility toggle
-- (unlike "Use Vanilla Pet Bar"), so it applies live with no reload -
-- writes cfg.condenseEmptyPetSlots then re-applies whichever mode's own
-- shape function is currently effective (the other one no-ops safely,
-- same as ACAB:ResetPetBarNativeLayout's own comment).
local function CreateCondenseEmptyPetSlotsCheckbox(page, y)
	local checkbox = ACAB:CreateLabeledCheckbox(page, "ACABPetBarCondenseCheckbox", {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, y },
		label = "Condense empty Button Space",
		lockedText = VANILLA_MODE_LOCKED_TEXT,
		onClick = function()
			local checked = this:GetChecked() and true or false
			local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]

			if cfg then
				cfg.condenseEmptyPetSlots = checked
			end

			if ACAB.ApplyDefaultBarShape then
				ACAB:ApplyDefaultBarShape(ACAB.PET_BAR_ID)
			end

			if ACAB.ApplyPetBarNativeShape then
				ACAB:ApplyPetBarNativeShape()
			end

			-- Condensing changes the bar's actual on-screen footprint, so the
			-- Position sliders' clamp range must be recomputed immediately -
			-- dispatched to whichever page kind is actually showing right now
			-- (GetOrCreateBarPage/RefreshPositionSliderRange for the
			-- custom-styled grid page, RefreshSimpleBarPage for the native
			-- page, which measures petBarNativeContainer's own real size).
			if IsPetBarNativeMode() then
				if ACAB.RefreshSimpleBarPage then
					ACAB:RefreshSimpleBarPage(ACAB.PET_BAR_ID)
				end
			else
				if ACAB.RefreshPositionSliderRange then
					ACAB:RefreshPositionSliderRange(page)
				end
			end
		end,
	})

	page.condenseEmptyPetSlotsCheckbox = checkbox

	return checkbox
end

-- Re-applies the animated/static glow choice to already-existing Pet Bar
-- buttons immediately, rather than waiting for the next PET_BAR_UPDATE
-- event to round-trip.
local function RefreshPetBarAutoCastGlowState()
	local bar = ACAB.bars and ACAB.bars[ACAB.PET_BAR_ID]

	if not bar or not bar.buttons then
		return
	end

	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn and btn.UpdateState then
			btn:UpdateState()
		end
	end
end

-- "Animate Auto-Cast Toggle" checkbox, styled/grid Pet Bar page only - the
-- native page uses real PetActionButton1-10 and never draws this glow at all.
local function CreateAnimateAutoCastGlowCheckbox(page, y)
	local checkbox = ACAB:CreateLabeledCheckbox(page, "ACABPetBarAnimateAutoCastCheckbox", {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, y },
		label = "Animate Auto-Cast Toggle",
		onClick = function()
			local checked = this:GetChecked() and true or false
			local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]

			if cfg then
				cfg.animateAutoCastGlow = checked
			end

			RefreshPetBarAutoCastGlowState()
		end,
	})

	page.animateAutoCastGlowCheckbox = checkbox

	return checkbox
end

local LIST_ROW_HEIGHT = 24
local LIST_ROW_GAP    = 4

-- Matches f.listPanel's backdrop (SetWidth 140, 2px insets). Every row's
-- fade-strip highlight (ACABListRowMixin:SetVisualWidth) spans this same
-- fixed width/offset regardless of whether the row has an inline checkbox,
-- so the highlighted area always fills the list panel's inner rectangle
-- edge-to-edge.
local LIST_ITEM_VISUAL_OFFSET = 2
local LIST_ITEM_VISUAL_WIDTH = 140 - (LIST_ITEM_VISUAL_OFFSET * 2)
local SWATCH_SIZE = 46
local SWATCH_GAP  = 8
local SWATCH_PAD  = 4
-------------------------------------------------------------------------
-- Only show on hover - shared checkbox + slider
--
-- Used by both GetOrCreateBarPage and CreateSimpleBarPage. The slider (and its live value label) only show while the checkbox is checked.
-------------------------------------------------------------------------

-- Vertical space each row reserves for callers' layout-cursor math. ACAB fields, not file-locals, for the same reason as ACAB:AddHoverOnlyReflowRow above.
ACAB.HOVER_ONLY_CHECKBOX_ROW_HEIGHT = 24 + 14
ACAB.HOVER_ONLY_SLIDER_ROW_HEIGHT = 17 + 20

-- Bumped on every call so each checkbox/slider pair gets its own unique frame name.
local hoverOnlyControlsCounter = 0

-- idOrKey: the owning page's barId (number) or simple-page key (string), passed to ACAB:FitSettingsWindowToBarPage after a live reflow.
function ACAB:CreateHoverOnlyControls(page, y, getEnabled, setEnabled, getDuration, setDuration, idOrKey)
	hoverOnlyControlsCounter = hoverOnlyControlsCounter + 1

	local suffix = tostring(hoverOnlyControlsCounter)

	-- OnClick is wired further below - it closes over the slider/labels
	-- this function creates next.
	local checkbox = ACAB:CreateLabeledCheckbox(page, "ACABHoverOnlyCheckbox" .. suffix, {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, y },
		label = "Only show on hover",
		tooltip = {
			title = "Only show on hover",
			lines = {
				"When enabled, this Element will be hidden until Mouseover.",
				"When enabled a new Slider appears to set how long the Element stays visible after a Mouseover Event until it disappears again.",
			},
		},
	})

	local sliderY = y - 24 - 14

	-- Inline label to the left of the slider, same convention as the X/Y sliders, not OptionsSliderTemplate's own top label.
	local fadeOutLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	fadeOutLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, sliderY)
	fadeOutLabel:SetText("Fade out time")

	local slider = ACAB:CreateSettingSlider(
		page,
		"ACABHoverOnlyDurationSlider" .. suffix,
		225
	)

	slider:SetPoint("TOPLEFT", page, "TOPLEFT", 150, sliderY + 4)
	slider:SetMinMaxValues(0, 10)
	slider:SetValueStep(0.5)

	local sliderLow = getglobal(slider:GetName() .. "Low")

	if sliderLow then
		sliderLow:SetText("0s")
	end

	local sliderHigh = getglobal(slider:GetName() .. "High")

	if sliderHigh then
		sliderHigh:SetText("10s")
	end

	local valueText = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)
	valueText:SetText("3.0s")

	slider:SetScript("OnValueChanged", function()
		local value = this:GetValue()

		if not value then
			return
		end

		value = math.floor((value * 2) + 0.5) / 2

		valueText:SetText(string.format("%.1fs", value))

		if not this.suppressApply then
			setDuration(value)
		end
	end)

	checkbox:SetScript("OnClick", function()
		local checked = this:GetChecked() and true or false

		setEnabled(checked)

		fadeOutLabel:SetShown(checked)
		slider:SetShown(checked)
		valueText:SetShown(checked)

		self:ReflowRowsBelowHoverOnly(page, checked, self.HOVER_ONLY_SLIDER_ROW_HEIGHT)

		ACAB:DeferFit(function() ACAB:FitSettingsWindowToBarPage(idOrKey) end)
	end)

	local startEnabled = getEnabled() == true

	fadeOutLabel:SetShown(startEnabled)
	slider:SetShown(startEnabled)
	valueText:SetShown(startEnabled)

	page.hoverOnlyCheckbox = checkbox
	page.hoverOnlyFadeLabel = fadeOutLabel
	page.hoverDurationSlider = slider
	page.hoverDurationValueText = valueText

	return self.HOVER_ONLY_CHECKBOX_ROW_HEIGHT
end

-- Syncs the checkbox/slider pair above FROM the saved config. No-op if this page never built the controls.
function ACAB:RefreshHoverOnlyControls(page, enabled, duration)
	if not page.hoverOnlyCheckbox then
		return
	end

	enabled = enabled == true
	duration = self:ClampHoverDuration(duration) or 3

	page.hoverOnlyCheckbox:SetChecked(enabled)

	if page.hoverOnlyFadeLabel then
		page.hoverOnlyFadeLabel:SetShown(enabled)
	end

	if page.hoverDurationSlider then
		page.hoverDurationSlider.suppressApply = true
		page.hoverDurationSlider:SetValue(duration)
		page.hoverDurationSlider.suppressApply = nil

		page.hoverDurationSlider:SetShown(enabled)
	end

	if page.hoverDurationValueText then
		page.hoverDurationValueText:SetText(string.format("%.1fs", duration))
		page.hoverDurationValueText:SetShown(enabled)
	end

	-- Reflects the real saved state on open/reselect, not just the freshly built page's collapsed baseline.
	self:ReflowRowsBelowHoverOnly(page, enabled, self.HOVER_ONLY_SLIDER_ROW_HEIGHT)
end

-------------------------------------------------------------------------
-- Grid preset swatches
--
-- Small preview frames built from WHITE8X8-textured squares, matching the
-- texture idiom used by Button.lua's editOverlay. Clicking a swatch
-- applies immediately.
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

	if barId == "micromenu" then
		-- page.isDefault is unconditionally true for every simple page
		-- (CreateSimpleBarPage, unrelated profile-lock-gating reuse of that
		-- field name) - must be checked before the page.isDefault branch
		-- below or this would wrongly call ACAB:SetDefaultBarLayout.
		ACAB:SetMicroMenuLayout(this.cols, this.rows)
	elseif page.isDefault then
		-- ACAB:SetDefaultBarLayout (DefaultBars.lua) handles both bar 1 and
		-- bars 2-5, delegating to Bar.lua's SetBarLayout for bars 2-5.
		ACAB:SetDefaultBarLayout(barId, this.cols, this.rows)
	else
		local bar = ACAB.bars[barId]

		if bar then
			ACAB:SetBarLayout(bar, this.cols, this.rows)
		end
	end

	ACAB:RefreshBarSettingsPage(barId)
end

-- Builds (or rebuilds) a page's Grid Layout swatch row at a fixed Y anchor,
-- from GetGridPresetsForBar(barId). Stance Bar's preset list is live
-- (GetStanceBarGridOptions) rather than a fixed table, so unlike every
-- other bar kind its swatches must be torn down and rebuilt on every page
-- refresh, not just once at page creation - see RefreshBarSettingsPage's
-- own Stance Bar branch, which calls this again on every page show.
local function RebuildGridSwatches(page, barId, swatchY)
	local i

	if page.gridSwatches then
		for i = 1, table.getn(page.gridSwatches) do
			page.gridSwatches[i]:Hide()
			page.gridSwatches[i]:ClearAllPoints()
		end
	end

	if page.noStancesText then
		page.noStancesText:Hide()
		page.noStancesText = nil
	end

	page.gridSwatches = {}

	local gridPresets = GetGridPresetsForBar(barId)

	if barId == ACAB.STANCE_BAR_ID and table.getn(gridPresets) == 0 then
		local noStancesText = page:CreateFontString(
			nil,
			"OVERLAY",
			"GameFontNormalSmall"
		)

		noStancesText:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			ACAB.INDENT_CONTROL,
			swatchY
		)

		noStancesText:SetText("No stances currently available.")

		page.noStancesText = noStancesText
	end

	local xOffset = ACAB.INDENT_CONTROL

	for i = 1, table.getn(gridPresets) do
		local preset = gridPresets[i]

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
-- Create a bar settings page
--
-- Shared between default bars (1-5) and custom bars (6+). The controls
-- that don't apply to one kind (enable checkbox for bar 1 / default
-- bars 2-5 only, button-count stepper and Delete Bar for custom bars
-- only) are simply not created for the other kind, rather than
-- maintaining two parallel page builders.
-------------------------------------------------------------------------

function ACAB:GetOrCreateBarPage(barId)
	if not ACAB.settingsFrame then
		ACAB:CreateSettingsFrame()
	end

	-- Pet Bar in native mode: same simple-page builder as Bag Bar/Micro
	-- Menu below, keyed by its own numeric id rather than a string -
	-- checked separately from the generic ACAB.simpleBarPageConfigs test below
	-- so the SAME id can route to either page builder depending on mode.
	if barId == ACAB.PET_BAR_ID and IsPetBarNativeMode() then
		return self:GetOrCreateSimpleBarPage(barId)
	end

	-- Stance Bar, same dispatch as the Pet Bar branch above - the SAME
	-- numeric id can route to either page builder depending on
	-- cfg.useNativeStanceBar.
	if barId == ACAB.STANCE_BAR_ID and IsStanceBarNativeMode() then
		return self:GetOrCreateSimpleBarPage(barId)
	end

	-- Bag Bar / Micro Menu (features 2/3): dispatched out to the shared
	-- "simple" page builder further down this file (Position + optional
	-- Enable + Reset only) rather than through the full grid/spacing/
	-- button-size/buttonCount/delete page builder below - neither element
	-- is a ACAB-owned button grid.
	if ACAB.simpleBarPageConfigs[barId] and barId ~= ACAB.PET_BAR_ID and barId ~= ACAB.STANCE_BAR_ID then
		return self:GetOrCreateSimpleBarPage(barId)
	end

	if ACAB.settingsFrame.pages[barId] then
		return ACAB.settingsFrame.pages[barId]
	end

	local isDefault = ACAB:IsDefaultBarId(barId)

	local page = CreateFrame(
		"Frame",
		nil,
		ACAB.settingsFrame.contentPanel
	)

	-- Anchored through ApplyPageBannerReserve (rather than SetAllPoints) so
	-- the page can slide down to open up the profile-lock banner's band
	-- only while that banner is actually shown - starts unlocked/flush.
	ACAB:ApplyPageBannerReserve(page, false)

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
	-- (ACAB:ApplyPageBannerReserve).
	title:SetPoint(
		"TOPLEFT",
		ACAB.settingsFrame.contentPanel,
		"TOPLEFT",
		ACAB.INDENT_SECTION,
		-14
	)

	local titleText = GetBarDisplayName(barId, isDefault) .. " Settings"

	if isDefault then
		titleText = titleText .. " (Default)"
	end

	title:SetText(titleText)

	-- Extra Bars (ids 6-9) get the same "Enabled" checkbox default bars
	-- 2-5 get (ACAB:IsExtraBarId/SetExtraBarEnabled, Bar.lua).
	local isExtraBar = ACAB:IsExtraBarId(barId)
	local hasEnableCheckbox = (isDefault and barId ~= 1) or isExtraBar

	-------------------------------------------------------------------------
	-- Vertical layout cursor
	--
	-- Every offset below is derived from deltas rather than independent
	-- magic numbers, so this whole block is the single place to retune
	-- spacing instead of hunting through every control's SetPoint.
	-------------------------------------------------------------------------

	-- The page slides down by PROFILE_LOCK_BANNER_HEIGHT only while the
	-- lock banner is actually shown (ACAB:ApplyPageBannerReserve, called
	-- from ApplyProfileLockGating).
	local contentTopOffset = 0

	local checkboxY = -44 + contentTopOffset

	-- Position section starts right under the title, or - on bars 2-5 -
	-- right under the enable checkbox block.
	local positionStartY = -46 + contentTopOffset

	if hasEnableCheckbox then
		positionStartY = checkboxY - 24 - 14
	end

	-- "Only show on hover" checkbox + slider - every bar page this builder produces.
	local hoverOnlyCheckboxY = positionStartY

	positionStartY = positionStartY - self.HOVER_ONLY_CHECKBOX_ROW_HEIGHT

	-- Pet Bar only: three more checkbox rows push the Position section down to make room.
	local isPetBarPage = barId == ACAB.PET_BAR_ID
	local useVanillaPetBarY = positionStartY
	local condenseEmptyPetSlotsY = useVanillaPetBarY - 24 - 14
	local animateAutoCastGlowY = condenseEmptyPetSlotsY - 24 - 14

	if isPetBarPage then
		positionStartY = positionStartY - (24 + 14) * 3
	end

	-- Stance Bar only: "Use Vanilla Stance Bar" reserves one more row right
	-- below Enabled - no condense/autocast equivalent (see Button.lua's
	-- isStanceSlot header comment for why).
	local isStanceBarPage = barId == ACAB.STANCE_BAR_ID
	local useVanillaStanceBarY = positionStartY

	if isStanceBarPage then
		positionStartY = positionStartY - (24 + 14)
	end

	local xLabelY = positionStartY
	local xSliderY = xLabelY + 4
	local yLabelY = xSliderY - 40
	local ySliderY = yLabelY + 4
	local sizeLayoutTitleY = ySliderY - 36
	local buttonSizeSliderY = sizeLayoutTitleY - 26

	-------------------------------------------------------------------------
	-- Enable checkbox (default bars 2-5 only - bar 1 always active)
	-------------------------------------------------------------------------

	if hasEnableCheckbox then
		local enableCheckbox = ACAB:CreateLabeledCheckbox(page, "ACABDefaultBar" .. tostring(barId) .. "EnableCheckbox", {
			anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, checkboxY },
			label = "Enabled",
			onClick = function()
				local checked = this:GetChecked() and true or false

				if isDefault then
					ACAB:SetDefaultBarEnabled(this.barId, checked)
				else
					ACAB:SetExtraBarEnabled(this.barId, checked)
				end

				ACAB:RefreshBarList()
			end,
		})

		enableCheckbox.barId = barId

		page.enableCheckbox = enableCheckbox
	end

	-------------------------------------------------------------------------
	-- Only show on hover
	-------------------------------------------------------------------------

	self:CreateHoverOnlyControls(
		page,
		hoverOnlyCheckboxY,
		function()
			local cfg = ACAB:GetBarConfig(barId)
			return cfg and cfg.hoverOnly
		end,
		function(v)
			local bar = ACAB.bars[barId]

			if bar then
				ACAB:SetBarHoverOnly(bar, v)
			end
		end,
		function()
			local cfg = ACAB:GetBarConfig(barId)
			return (cfg and cfg.hoverDuration) or 3
		end,
		function(v)
			local bar = ACAB.bars[barId]

			if bar then
				ACAB:SetBarHoverDuration(bar, v)
			end
		end,
		barId
	)

	-------------------------------------------------------------------------
	-- Use Vanilla Pet Bar (Pet Bar page only)
	-------------------------------------------------------------------------

	if isPetBarPage then
		CreateUseVanillaPetBarCheckbox(page, useVanillaPetBarY)
		self:AddHoverOnlyReflowRow(page, page.useVanillaPetBarCheckbox, ACAB.INDENT_SECTION, useVanillaPetBarY)

		CreateCondenseEmptyPetSlotsCheckbox(page, condenseEmptyPetSlotsY)
		self:AddHoverOnlyReflowRow(page, page.condenseEmptyPetSlotsCheckbox, ACAB.INDENT_SECTION, condenseEmptyPetSlotsY)

		CreateAnimateAutoCastGlowCheckbox(page, animateAutoCastGlowY)
		self:AddHoverOnlyReflowRow(page, page.animateAutoCastGlowCheckbox, ACAB.INDENT_SECTION, animateAutoCastGlowY)
	end

	-------------------------------------------------------------------------
	-- Use Vanilla Stance Bar (Stance Bar page only)
	-------------------------------------------------------------------------

	if isStanceBarPage then
		CreateUseVanillaStanceBarCheckbox(page, useVanillaStanceBarY)
		self:AddHoverOnlyReflowRow(page, page.useVanillaStanceBarCheckbox, ACAB.INDENT_SECTION, useVanillaStanceBarY)
	end

	-------------------------------------------------------------------------
	-- Position section: sliders' min/max come from GetActionBarCoordinateRange
	-- (this bar's own buttonSize/buttonCount/border), kept live by
	-- RefreshPositionSliderRange. Live X/Y values show as a centered
	-- FontString under each slider, same as Button Size.
	-------------------------------------------------------------------------

	local minX, maxX, minY, maxY =
		ACAB:GetActionBarCoordinateRange(ACAB:GetBarConfig(barId))

	-------------------------------------------------------------------------
	-- X slider
	-------------------------------------------------------------------------

	local xLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	xLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, xLabelY)
	xLabel:SetText("X")

	self:AddHoverOnlyReflowRow(page, xLabel, ACAB.INDENT_CONTROL, xLabelY)

	self:CreatePositionAxisSlider(page, {
		axisKey = "x",
		namePrefix = "ACABBar" .. tostring(barId),
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, xSliderY },
		min = minX,
		max = maxX,
		lowText = "Left",
		highText = "Right",
		onApply = function() ACAB:ApplyLiveBarPosition(page) end,
	})

	-------------------------------------------------------------------------
	-- Y slider
	-------------------------------------------------------------------------

	local yLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	yLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, yLabelY)
	yLabel:SetText("Y")

	self:AddHoverOnlyReflowRow(page, yLabel, ACAB.INDENT_CONTROL, yLabelY)

	self:CreatePositionAxisSlider(page, {
		axisKey = "y",
		namePrefix = "ACABBar" .. tostring(barId),
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, ySliderY },
		min = minY,
		max = maxY,
		lowText = "Down",
		highText = "Up",
		onApply = function() ACAB:ApplyLiveBarPosition(page) end,
	})

	-- Reset to Blizzard Default (default bars only) is created further
	-- down, below the Spacing slider and above Grid Layout.

	-------------------------------------------------------------------------
	-- Size & Layout
	--
	-- sizeLayoutTitleY/buttonSizeSliderY are computed in the vertical
	-- layout cursor block above, cascading from the Y slider's value text.
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
		ACAB.INDENT_SECTION,
		sizeLayoutTitleY
	)

	layoutTitle:SetText(
		"Button Size (" .. tostring(ACAB.BUTTON_SIZE_MIN) ..
		" to " .. tostring(ACAB.BUTTON_SIZE_MAX) .. ")"
	)

	self:AddHoverOnlyReflowRow(page, layoutTitle, ACAB.INDENT_SECTION, sizeLayoutTitleY)

	-------------------------------------------------------------------------
	-- Button Size
	-------------------------------------------------------------------------

	local buttonSizeSlider, buttonSizeValueText = ACAB:CreateLabeledSlider(
		page,
		"ACABBar" .. tostring(barId) .. "ButtonSizeSlider",
		{
			anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, buttonSizeSliderY },
			min = ACAB.BUTTON_SIZE_MIN,
			max = ACAB.BUTTON_SIZE_MAX,
			-- Exactly the same 2-pixel increments as the mouse wheel.
			step = ACAB.BUTTON_SIZE_STEP,
			lowText = tostring(ACAB.BUTTON_SIZE_MIN),
			highText = tostring(ACAB.BUTTON_SIZE_MAX),
			-- Bare number only, no "Button Size:" prefix.
			initialText = tostring(ACAB.BUTTON_SIZE),
			round = function(value) return math.floor((value / ACAB.BUTTON_SIZE_STEP) + 0.5) * ACAB.BUTTON_SIZE_STEP end,
			format = tostring,
			onChange = function(value, suppressApply)
				if not suppressApply then
					if page.isDefault then
						ACAB:SetDefaultBarButtonSize(page.barId, value)
					else
						local bar = ACAB.bars[page.barId]

						if bar then
							ACAB:SetBarButtonSize(bar, value)
						end
					end
				end

				-- Button size feeds the X/Y clamp range (GetActionBarCoordinateRange) - keep it current.
				ACAB:RefreshPositionSliderRange(page)
			end,
		}
	)

	page.buttonSizeValueText = buttonSizeValueText
	page.buttonSizeSlider = buttonSizeSlider

	self:AddHoverOnlyReflowRow(page, buttonSizeSlider, ACAB.INDENT_INPUT, buttonSizeSliderY)

	-- Lock icon - every bar kind gets one (Action/Extra Bars 1-9 and
	-- Pet Bar/Stance Bar's own styled-mode page alike), matching
	-- ApplyGlobalButtonSize's own scope (Bar.lua). Hidden/shown and kept
	-- in sync by RefreshBarPageGlobalOverrideGating, not here - this only
	-- wires the click.
	local buttonSizeLockButton = ACAB:CreateLockToggleButton(
		page,
		"ACABBar" .. tostring(barId) .. "ButtonSizeLockButton",
		{
			anchor = { "LEFT", buttonSizeSlider, "RIGHT", 4, 0 },
			tooltipTitle = "Button Size",
			lockedLine = "Locked to the General tab's global Button Size. Click to unlock and set an independent value for this bar.",
			unlockedLine = "Unlocked - independent of the General tab's global Button Size. Click to re-lock and sync it.",
			onClick = function()
				local cfg = ACAB:GetBarConfig(page.barId)

				if not cfg then
					return
				end

				cfg.buttonSizeUnlocked = not (cfg.buttonSizeUnlocked == true)

				if not cfg.buttonSizeUnlocked then
					local bar = ACAB.bars[page.barId]

					if bar then
						ACAB:ApplyGlobalButtonSizeToBar(bar)
					end
				end

				ACAB:RefreshBarSettingsPage(page.barId)
			end,
		}
	)

	buttonSizeLockButton:SetLocked(true)
	buttonSizeLockButton:Hide()

	page.buttonSizeLockButton = buttonSizeLockButton

	-------------------------------------------------------------------------
	-- Spacing - every bar kind gets this control, default bars 1-5 and
	-- custom bars 6+. Mirrors the Button Size slider's live-value-label/
	-- min-max-end-label pattern.
	-------------------------------------------------------------------------

	local gridTitleY
	local swatchY

	-- Every bar (default or custom) is guaranteed a real cfg.spacing field
	-- from creation. The OnValueChanged handler below branches to whichever
	-- setter the bar kind needs: ACAB:SetDefaultBarSpacing for default bars
	-- (itself branching bar-1-direct-write vs. bars-2-5-delegate-to-Bar.lua),
	-- ACAB:SetBarSpacing for custom bars.
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
			ACAB.INDENT_SECTION,
			spacingTitleY
		)

		spacingTitle:SetText(
			"Spacing (" .. tostring(ACAB.SPACING_MIN) ..
			" to " .. tostring(ACAB.SPACING_MAX) .. ")"
		)

		self:AddHoverOnlyReflowRow(page, spacingTitle, ACAB.INDENT_SECTION, spacingTitleY)

		-- Placeholder initial text only - RefreshBarSettingsPage (called
		-- immediately after GetOrCreateBarPage by ShowBarPage) sets the
		-- real value from cfg.spacing before this page is ever shown.
		local spacingSlider, spacingValueText, spacingSliderLow, spacingSliderHigh = ACAB:CreateLabeledSlider(
			page,
			"ACABBar" .. tostring(barId) .. "SpacingSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, spacingSliderY },
				-- Displayed range (0-based); see GetSpacingDisplayOffset. Recomputed
				-- on every RefreshBarSettingsPage call since the offset can change
				-- live with the border-style toggle.
				min = 0,
				max = ACAB.SPACING_MAX - ACAB:GetSpacingDisplayOffset(),
				step = ACAB.SPACING_STEP,
				lowText = "0",
				highText = tostring(ACAB.SPACING_MAX - ACAB:GetSpacingDisplayOffset()),
				initialText = "0",
				round = function(value) return math.floor(value + 0.5) end,
				format = tostring,
				onChange = function(value, suppressApply)
					if not suppressApply then
						-- The slider's own value is always DISPLAYED (0-based) -
						-- convert to real only at this write boundary.
						local real = value + ACAB:GetSpacingDisplayOffset()

						if page.isDefault then
							ACAB:SetDefaultBarSpacing(page.barId, real)
						else
							local bar = ACAB.bars[page.barId]

							if bar then
								ACAB:SetBarSpacing(bar, real)
							end
						end
					end

					-- Spacing feeds the X/Y clamp range (GetActionBarCoordinateRange) - keep it current.
					ACAB:RefreshPositionSliderRange(page)
				end,
			}
		)

		page.spacingSliderLow = spacingSliderLow
		page.spacingSliderHigh = spacingSliderHigh
		page.spacingValueText = spacingValueText
		page.spacingSlider = spacingSlider

		self:AddHoverOnlyReflowRow(page, spacingSlider, ACAB.INDENT_INPUT, spacingSliderY)

		-- Lock icon - mirrors the Button Size lock button above exactly,
		-- for the General tab's global Spacing override.
		local spacingLockButton = ACAB:CreateLockToggleButton(
			page,
			"ACABBar" .. tostring(barId) .. "SpacingLockButton",
			{
				anchor = { "LEFT", spacingSlider, "RIGHT", 4, 0 },
				tooltipTitle = "Spacing",
				lockedLine = "Locked to the General tab's global Spacing. Click to unlock and set an independent value for this bar.",
				unlockedLine = "Unlocked - independent of the General tab's global Spacing. Click to re-lock and sync it.",
				onClick = function()
					local cfg = ACAB:GetBarConfig(page.barId)

					if not cfg then
						return
					end

					cfg.spacingUnlocked = not (cfg.spacingUnlocked == true)

					if not cfg.spacingUnlocked then
						local bar = ACAB.bars[page.barId]

						if bar then
							ACAB:ApplyGlobalSpacingToBar(bar)
						end
					end

					ACAB:RefreshBarSettingsPage(page.barId)
				end,
			}
		)

		spacingLockButton:SetLocked(true)
		spacingLockButton:Hide()

		page.spacingLockButton = spacingLockButton

		if isDefault then
			-------------------------------------------------------------------------
			-- Reset to Blizzard default position (default bars only - custom
			-- bars have no native Blizzard anchor to reset to).
			-------------------------------------------------------------------------

			local resetButtonY = spacingSliderY - 36

			local resetPositionButton = ACAB:CreateResetButton(page, {
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, resetButtonY },
				minWidth = 200,
				maxWidth = 200,
				text = "Reset to Blizzard Default",
				onClick = function()
					-- Restores position/spacing/cols/rows/buttonSize to
					-- their native defaults.
					ACAB:ResetDefaultBarLayout(page.barId)

					-- Re-syncs every control's displayed value (X/Y sliders,
					-- Button Size, grid-swatch selection) from the saved
					-- config after this external write.
					ACAB:RefreshBarSettingsPage(page.barId)
				end,
			})

			page.resetPositionButton = resetPositionButton

			self:AddHoverOnlyReflowRow(page, resetPositionButton, ACAB.INDENT_INPUT, resetButtonY)

			-- Grid Layout shifts down to make room for the Spacing section
			-- plus the Reset button above it.
			gridTitleY = resetButtonY - 34
			swatchY = gridTitleY - 26
		elseif ACAB:IsExtraBarId(barId) then
			-------------------------------------------------------------------------
			-- Reset to Default position/buttonSize/spacing/grid layout -
			-- Extra Bars have no native Blizzard anchor, so this resets to
			-- the addon's own default instead (ACAB:ResetExtraBarLayout,
			-- Bar.lua).
			-------------------------------------------------------------------------

			local resetButtonY = spacingSliderY - 36

			local resetPositionButton = ACAB:CreateResetButton(page, {
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, resetButtonY },
				minWidth = 200,
				maxWidth = 200,
				text = "Reset to Default",
				onClick = function()
					ACAB:ResetExtraBarLayout(page.barId)
					ACAB:RefreshBarSettingsPage(page.barId)
				end,
			})

			page.resetPositionButton = resetPositionButton

			self:AddHoverOnlyReflowRow(page, resetPositionButton, ACAB.INDENT_INPUT, resetButtonY)

			gridTitleY = resetButtonY - 34
			swatchY = gridTitleY - 26
		else
			-- Any other custom bar has no Reset concept.
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
		ACAB.INDENT_SECTION,
		gridTitleY
	)

	gridTitle:SetText("Grid Layout")

	-- Stored so RefreshBarSettingsPage can rebuild this row later (Stance Bar's live preset list only).
	page.gridSwatchY = swatchY

	RebuildGridSwatches(page, barId, swatchY)

	-- Grid Layout can't just be added to page.hoverOnlyReflowRows - its swatches are a dynamic array, repositioned in place instead of rebuilt here.
	page.hoverOnlyExtraReflow = function(offset)
		gridTitle:ClearAllPoints()
		gridTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, gridTitleY - offset)

		page.gridSwatchY = swatchY - offset

		if page.noStancesText then
			page.noStancesText:ClearAllPoints()
			page.noStancesText:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, page.gridSwatchY)
		end

		if page.gridSwatches then
			local xOffset = ACAB.INDENT_CONTROL
			local i

			for i = 1, table.getn(page.gridSwatches) do
				local swatch = page.gridSwatches[i]

				swatch:ClearAllPoints()
				swatch:SetPoint("TOPLEFT", page, "TOPLEFT", xOffset, page.gridSwatchY)

				xOffset = xOffset + SWATCH_SIZE + SWATCH_GAP
			end
		end
	end

	-------------------------------------------------------------------------
	-- Button count stepper (custom bars only) - default bars always show
	-- all 12 Blizzard buttons.
	-------------------------------------------------------------------------

	if not isDefault then
		-- Derived from swatchY: the swatch grid is SWATCH_SIZE tall plus
		-- its own caption line below it, then a 14px gap before this
		-- section's label, then a 28px label-to-row gap.
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
			ACAB.INDENT_SECTION,
			buttonCountLabelY
		)

		buttonCountLabel:SetText("Buttons Shown")

		self:AddHoverOnlyReflowRow(page, buttonCountLabel, ACAB.INDENT_SECTION, buttonCountLabelY)

		local buttonCountMinus = CreateFrame(
			"Button",
			"ACABBar" .. tostring(barId) .. "ButtonCountMinus",
			page
		)

		buttonCountMinus:SetHeight(22)

		buttonCountMinus:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			ACAB.INDENT_INPUT,
			buttonCountRowY
		)

		ACAB:StyleModernButton(buttonCountMinus, 24, 24)
		buttonCountMinus:SetText("-")

		self:AddHoverOnlyReflowRow(page, buttonCountMinus, ACAB.INDENT_INPUT, buttonCountRowY)

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
			"ACABBar" .. tostring(barId) .. "ButtonCountPlus",
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

		ACAB:StyleModernButton(buttonCountPlus, 24, 24)
		buttonCountPlus:SetText("+")

		-- Reads/writes cfg.buttonCount directly through SetBarButtonCount
		-- on every click.
		local function RefreshButtonCountStepperVisual()
			local cfg = ACAB:FindCustomBarConfig(page.barId)

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
				local cfg = ACAB:FindCustomBarConfig(page.barId)
				local bar = ACAB.bars[page.barId]

				if not cfg or not bar then
					return
				end

				local count = (cfg.buttonCount or (cfg.cols * cfg.rows)) - 1

				ACAB:SetBarButtonCount(bar, count)

				RefreshButtonCountStepperVisual()

				-- Button count feeds the X/Y clamp range - keep it current.
				ACAB:RefreshPositionSliderRange(page)
			end
		)

		buttonCountPlus:SetScript(
			"OnClick",
			function()
				local cfg = ACAB:FindCustomBarConfig(page.barId)
				local bar = ACAB.bars[page.barId]

				if not cfg or not bar then
					return
				end

				local count = (cfg.buttonCount or (cfg.cols * cfg.rows)) + 1

				ACAB:SetBarButtonCount(bar, count)

				RefreshButtonCountStepperVisual()

				-- Button count feeds the X/Y clamp range - keep it current.
				ACAB:RefreshPositionSliderRange(page)
			end
		)

		page.buttonCountMinus = buttonCountMinus
		page.buttonCountPlus = buttonCountPlus
		page.buttonCountValueText = buttonCountValueText
		page.RefreshButtonCountStepperVisual = RefreshButtonCountStepperVisual
	end

	-------------------------------------------------------------------------
	-- Page Indicator Scale (Main Bar only). Position is drag-only
	-- (EnsureContainerOverlay, DefaultBars.lua); only Scale is exposed here,
	-- reusing the button-count stepper's Y-offset formula (never present on
	-- bar 1). Shown/hidden by ACAB:RefreshMainBarPageIndicatorControlsVisibility
	-- (gated on ACABDB.mainBarPaginationEnabled).
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
			ACAB.INDENT_SECTION,
			pageIndicatorTitleY
		)

		pageIndicatorTitle:SetText("Page Indicator Scale")

		self:AddHoverOnlyReflowRow(page, pageIndicatorTitle, ACAB.INDENT_SECTION, pageIndicatorTitleY)

		local pageIndicatorSlider, pageIndicatorValueText = ACAB:CreateLabeledSlider(
			page,
			"ACABMainBarPageIndicatorScaleSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, pageIndicatorSliderY },
				min = 0.5,
				max = 2.0,
				step = 0.1,
				initialText = "1.0",
				round = function(value) return math.floor((value * 10) + 0.5) / 10 end,
				format = function(value) return string.format("%.1f", value) end,
				onChange = function(value, suppressApply)
					if not suppressApply then
						ACAB:SetPageIndicatorScale(value)
					end
				end,
			}
		)

		page.pageIndicatorTitle = pageIndicatorTitle
		page.pageIndicatorSlider = pageIndicatorSlider
		page.pageIndicatorValueText = pageIndicatorValueText

		self:AddHoverOnlyReflowRow(page, pageIndicatorSlider, ACAB.INDENT_INPUT, pageIndicatorSliderY)

		-------------------------------------------------------------------------
		-- Stance / Page Bar Assignment (bar 1's pagination/stance-swap
		-- settings; the two gating checkboxes live on the General tab).
		-- Empty placeholder container - ACAB:RebuildMainBarAssignmentRows
		-- populates the rows and collapses it to nothing when neither
		-- feature is enabled; called from RefreshBarSettingsPage(1), both
		-- checkboxes' OnClick, and DefaultBars.lua's UPDATE_SHAPESHIFT_FORMS.
		-------------------------------------------------------------------------

		local assignmentContainer = CreateFrame("Frame", nil, page)

		-- Anchored to `page`'s left margin, not to pageIndicatorValueText -
		-- that FontString's only "TOP" anchor point is centered under the
		-- slider, not left-aligned, which would push assignment rows too
		-- far right and overflow the page's visible width.
		assignmentContainer:SetPoint(
			"TOPLEFT",
			page,
			"TOPLEFT",
			ACAB.INDENT_SECTION,
			pageIndicatorSliderY - 44
		)

		assignmentContainer:SetWidth(500)
		assignmentContainer:SetHeight(1)

		page.assignmentContainer = assignmentContainer
		page.assignmentRows = {}

		-- Rows RebuildMainBarAssignmentRows populates later anchor to assignmentContainer, so repositioning it carries all of them along.
		self:AddHoverOnlyReflowRow(page, assignmentContainer, ACAB.INDENT_SECTION, pageIndicatorSliderY - 44)
	end

	-------------------------------------------------------------------------
	-- Hide until selected
	-------------------------------------------------------------------------

	page:Hide()

	ACAB.settingsFrame.pages[barId] = page

	return page
end

-------------------------------------------------------------------------
-- Apply X/Y position live from a page's sliders
--
-- Shared by both slider OnValueChanged handlers above so the "which bar
-- kind gets which setter" branch only lives in one place.
-------------------------------------------------------------------------

function ACAB:ApplyLiveBarPosition(page)
	-- Reads the cached applied value (xAppliedValue/yAppliedValue, kept
	-- current by each slider's own OnValueChanged), not slider:GetValue()
	-- directly - during an active drag those can differ, since the
	-- pixel-snap is applied to the cache only. Calling slider:SetValue()
	-- from inside OnValueChanged to force the snap onto the slider itself
	-- was tried and reverted: it desyncs the native widget's own
	-- drag-tracking the moment it fires mid-drag, breaking further
	-- dragging for the rest of that gesture.
	local x = page.xAppliedValue or page.xSlider:GetValue()
	local y = page.yAppliedValue or page.ySlider:GetValue()

	if not x or not y then
		return
	end

	-- Passes full precision through untouched - only the sliders' displayed
	-- text is rounded to 2 decimals, not the value written to
	-- ACABDB / applied to the bar.
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
-- Experience Bar page-only helpers.
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
-- (ACABDB.expBarColorEarned/expBarColorRested) for the initial value
-- and `setter` (ACAB:SetExpBarColorEarned/SetExpBarColorRested) for both
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

	-- hasOpacity = false: bar-fill colors have no separate alpha channel
	-- here. opacityFunc is still assigned as a no-op per ColorPickerFrame's
	-- documented field set, in case the client calls it regardless.
	ColorPickerFrame.opacityFunc = function() end
	ColorPickerFrame.hasOpacity = false

	ColorPickerFrame.cancelFunc = function(previousValues)
		if previousValues then
			setter(previousValues.r, previousValues.g, previousValues.b)
			SetColorSwatchColor(swatch, getter())
		end
	end

	ColorPickerFrame:SetColorRGB(current.r, current.g, current.b)

	-- Anchors the native picker next to this addon's own Settings window
	-- instead of wherever it was last centered. `ACAB.settingsFrame` (this
	-- file's own module local, set once by CreateSettingsFrame) is
	-- guaranteed non-nil here - only reachable by clicking a swatch on an
	-- already-open Experience Bar settings page.
	ColorPickerFrame:ClearAllPoints()
	ColorPickerFrame:SetPoint("TOPLEFT", ACAB.settingsFrame, "TOPRIGHT", 10, 0)

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
-- toggleable text segments. Returns the checkbox so the caller can stash
-- it on `page` for RefreshSimpleBarPage/gating.
local function CreateExpBarTextToggleCheckbox(page, name, labelText, y, dbKey)
	return ACAB:CreateLabeledCheckbox(page, "ACABSimplePageExpBar" .. name .. "Checkbox", {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, y },
		label = labelText,
		onClick = function()
			local checked = this:GetChecked() and true or false

			ACABDB[dbKey] = checked

			ACAB:ApplyBetterExpBarVisual()
		end,
	})
end

-- Gates the 5 text-toggle checkboxes + Font Size slider + 3 color swatches
-- + Reset Colors button + Pulse Interval slider on "Enable Better
-- Experience Bar" - EnableMouse(false)+SetAlpha(0.5), same as
-- ApplyDefaultLayoutGating. Pulse Interval is included since the rested-
-- glow pulse it controls is separately gated on this same checkbox
-- (ACAB:ApplyExpBarRestedOverlay, DefaultBars.lua).
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
-- Simple bar pages (Stance Bar / Bag Bar / Micro Menu): one builder,
-- parameterized via ACAB.simpleBarPageConfigs, instead of three near-
-- identical page builders. Position (X/Y, live) + optional Enable
-- checkbox (Bag Bar/Micro Menu only - Stance Bar's shape is native/class-
-- driven) + "Reset to Blizzard Default". No grid/spacing/button-size/
-- buttonCount/Delete controls - none of these is a ACAB-owned
-- button grid.
-------------------------------------------------------------------------

local function CreateSimpleBarPage(key)
	local config = ACAB.simpleBarPageConfigs[key]

	if not config then
		return nil
	end

	local page = CreateFrame(
		"Frame",
		nil,
		ACAB.settingsFrame.contentPanel
	)

	-- Same banner-reserve handling as GetOrCreateBarPage above.
	ACAB:ApplyPageBannerReserve(page, false)

	page.barId = key
	page.isDefault = true

	page.profileLockWarning = ACAB:CreateProfileLockWarning(page)

	local title = page:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontNormalLarge"
	)

	-- Anchored to contentPanel, not `page` - stays put while the page
	-- slides down for the banner (ACAB:ApplyPageBannerReserve).
	title:SetPoint(
		"TOPLEFT",
		ACAB.settingsFrame.contentPanel,
		"TOPLEFT",
		ACAB.INDENT_SECTION,
		-14
	)

	title:SetText(config.title .. " Settings (Default)")

	-- No unconditional banner reserve - see GetOrCreateBarPage's own
	-- contentTopOffset comment.
	local contentTopOffset = 0
	local enableCheckboxY = -44 + contentTopOffset

	local topY = -46 + contentTopOffset

	if config.hasEnable then
		local enableCheckbox = ACAB:CreateLabeledCheckbox(page, "ACABSimplePage" .. key .. "EnableCheckbox", {
			anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, enableCheckboxY },
			label = "Enabled",
			onClick = function()
				local checked = this:GetChecked() and true or false

				config.setEnabled(checked)

				ACAB:RefreshBarList()
			end,
		})

		page.enableCheckbox = enableCheckbox

		topY = enableCheckboxY - 24 - 14
	end

	-------------------------------------------------------------------------
	-- Only show on hover (config.hasHoverOnly) - always the entry right after Enabled.
	-------------------------------------------------------------------------

	if config.hasHoverOnly then
		topY = topY - ACAB:CreateHoverOnlyControls(
			page,
			topY,
			config.getHoverOnly,
			config.setHoverOnly,
			config.getHoverDuration,
			config.setHoverDuration,
			key
		)
	end

	-- Use Vanilla Pet Bar (Pet Bar page only) - lets the user switch back to the custom-styled grid mode from here too.
	if key == ACAB.PET_BAR_ID then
		CreateUseVanillaPetBarCheckbox(page, topY)
		ACAB:AddHoverOnlyReflowRow(page, page.useVanillaPetBarCheckbox, ACAB.INDENT_SECTION, topY)

		topY = topY - 24 - 14

		CreateCondenseEmptyPetSlotsCheckbox(page, topY)
		ACAB:AddHoverOnlyReflowRow(page, page.condenseEmptyPetSlotsCheckbox, ACAB.INDENT_SECTION, topY)

		topY = topY - 24 - 14
	end

	-- Use Vanilla Stance Bar (Stance Bar native page only) - lets the user switch to the custom-styled grid mode from here too.
	if key == ACAB.STANCE_BAR_ID then
		CreateUseVanillaStanceBarCheckbox(page, topY)
		ACAB:AddHoverOnlyReflowRow(page, page.useVanillaStanceBarCheckbox, ACAB.INDENT_SECTION, topY)

		topY = topY - 24 - 14
	end

	-- Tooltip Grows From (Tooltip page only) - which corner of GameTooltip
	-- anchors to this box's matching corner.
	if key == "tooltip" then
		local row = CreateFrame("Frame", nil, page)

		row:SetWidth(500)
		row:SetHeight(32)
		row:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, topY)

		local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		label:SetPoint("LEFT", row, "LEFT", 0, 0)
		label:SetWidth(180)
		label:SetJustifyH("LEFT")
		label:SetText("Tooltip Grows From")

		local dropdown = ACAB:CreateInlineDropdown(row, 180, "ACABTooltipAnchorCornerDropdown")

		dropdown:SetPoint("LEFT", label, "RIGHT", -8, -2)
		dropdown:SetOptions({
			{ text = "Bottom Right (Default)", value = "BOTTOMRIGHT" },
			{ text = "Bottom Left", value = "BOTTOMLEFT" },
			{ text = "Top Right", value = "TOPRIGHT" },
			{ text = "Top Left", value = "TOPLEFT" },
		})

		local function RefreshTooltipAnchorCorner()
			dropdown:SetSelected(ACABDB.tooltipAnchorCorner or "BOTTOMRIGHT")
		end

		dropdown.onSelect = function(value)
			ACAB:SetTooltipAnchorCorner(value)
			RefreshTooltipAnchorCorner()
		end

		RefreshTooltipAnchorCorner()

		-- Exposed for RefreshSimpleBarPage's own refresh and
		-- ApplyProfileLockGating's generic assignmentRows lock sweep -
		-- this page never otherwise uses assignmentRows.
		row.dropdown = dropdown
		page.tooltipAnchorCornerRow = row
		page.assignmentRows = { row }

		topY = topY - 32 - 14
	end

	-- Elements with a real measurable frame (config.getElementFrame) use
	-- that frame's own current size for the clamp range (kept live by
	-- RefreshSimplePositionSliderRange below); any page without one falls
	-- back to the generic screen-relative range.
	local minX, maxX, minY, maxY

	if config.getElementFrame then
		minX, maxX, minY, maxY = ACAB:GetSimpleElementCoordinateRange(config.getElementFrame(), config.extraMaxYPixels)
	else
		minX, maxX, minY, maxY = ACAB:GetScreenCoordinateRange()
	end

	local xLabelY = topY
	local xSliderY = xLabelY + 4
	local yLabelY = xSliderY - 40
	local ySliderY = yLabelY + 4

	-------------------------------------------------------------------------
	-- X slider
	-------------------------------------------------------------------------

	local xLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	xLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, xLabelY)
	xLabel:SetText("X")

	ACAB:AddHoverOnlyReflowRow(page, xLabel, ACAB.INDENT_CONTROL, xLabelY)

	ACAB:CreatePositionAxisSlider(page, {
		axisKey = "x",
		namePrefix = "ACABSimplePage" .. key,
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, xSliderY },
		min = minX,
		max = maxX,
		lowText = "Left",
		highText = "Right",
		onApply = function(applied)
			local y = page.yAppliedValue or page.ySlider:GetValue()

			config.setPosition(applied, y)
		end,
	})

	-------------------------------------------------------------------------
	-- Y slider
	-------------------------------------------------------------------------

	local yLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	yLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, yLabelY)
	yLabel:SetText("Y")

	ACAB:AddHoverOnlyReflowRow(page, yLabel, ACAB.INDENT_CONTROL, yLabelY)

	ACAB:CreatePositionAxisSlider(page, {
		axisKey = "y",
		namePrefix = "ACABSimplePage" .. key,
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, ySliderY },
		min = minY,
		max = maxY,
		lowText = "Down",
		highText = "Up",
		onApply = function(applied)
			local x = page.xAppliedValue or page.xSlider:GetValue()

			config.setPosition(x, applied)
		end,
	})

	-- Cursor for whichever of Spacing/Scale/Orientation this element
	-- actually has - cascades exactly like
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
		-- config.spacingMin lets one element override the shared
		-- ACAB.SPACING_MIN floor - Micro Menu sets this to -10 so users can
		-- pull its native buttons into a slight overlap, compensating for
		-- padding baked into their own art that a spacing of 0 (their
		-- measured native gap) doesn't remove. Every other hasSpacing
		-- element (Bag Bar, Stance Bar) has no override and keeps the
		-- original ACAB.SPACING_MIN (0) floor.
		local spacingMin = config.spacingMin or ACAB.SPACING_MIN

		local spacingTitleY = cursorY
		local spacingSliderY = spacingTitleY - 26

		local spacingTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		spacingTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, spacingTitleY)
		spacingTitle:SetText(
			"Spacing (" .. tostring(spacingMin) .. " to " .. tostring(ACAB.SPACING_MAX) .. ")"
		)

		ACAB:AddHoverOnlyReflowRow(page, spacingTitle, ACAB.INDENT_SECTION, spacingTitleY)

		local spacingSlider, spacingValueText = ACAB:CreateLabeledSlider(
			page,
			"ACABSimplePage" .. key .. "SpacingSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, spacingSliderY },
				min = spacingMin,
				max = ACAB.SPACING_MAX,
				step = ACAB.SPACING_STEP,
				lowText = tostring(spacingMin),
				highText = tostring(ACAB.SPACING_MAX),
				initialText = "0",
				round = function(value) return math.floor(value + 0.5) end,
				format = tostring,
				onChange = function(value, suppressApply)
					if not suppressApply then
						-- Micro Menu displays value - uiOffset as the actual
						-- stored/applied spacing (config.spacingUiOffset); every
						-- other hasSpacing page has no offset (defaults to 0).
						local uiOffset = config.spacingUiOffset or 0

						config.setSpacing(value - uiOffset)
					end

					-- Spacing feeds this element's rendered footprint - keep the X/Y clamp range current.
					ACAB:RefreshSimplePositionSliderRange(page, key)
				end,
			}
		)

		page.spacingValueText = spacingValueText
		page.spacingSlider = spacingSlider

		ACAB:AddHoverOnlyReflowRow(page, spacingSlider, ACAB.INDENT_INPUT, spacingSliderY)

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

		scaleTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, scaleTitleY)
		scaleTitle:SetText("Scale (0.5 to 2.0)")

		ACAB:AddHoverOnlyReflowRow(page, scaleTitle, ACAB.INDENT_SECTION, scaleTitleY)

		local scaleSlider, scaleValueText = ACAB:CreateLabeledSlider(
			page,
			"ACABSimplePage" .. key .. "ScaleSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, scaleSliderY },
				min = 0.5,
				max = 2.0,
				step = 0.1,
				lowText = "0.5",
				highText = "2.0",
				initialText = "1.0",
				round = function(value) return math.floor((value * 10) + 0.5) / 10 end,
				format = function(value) return string.format("%.1f", value) end,
				onChange = function(value, suppressApply)
					if not suppressApply then
						config.setScale(value)

						-- Scale change also compensates stored x/y
						-- (DefaultBars.lua's Set*Scale, keeping the element's
						-- bottom-left corner fixed). WARNING: a full page
						-- refresh is required here, not just
						-- RefreshSimplePositionSliderRange - it re-syncs the
						-- X/Y sliders' displayed value from the new true
						-- position before re-clamping, or the min/max
						-- recompute reclamps against a stale value and
						-- produces a spurious jump.
						ACAB:RefreshSimpleBarPage(key)
					else
						-- Feeds this element's rendered footprint - keep the X/Y clamp range current.
						ACAB:RefreshSimplePositionSliderRange(page, key)
					end
				end,
			}
		)

		page.scaleValueText = scaleValueText
		page.scaleSlider = scaleSlider

		ACAB:AddHoverOnlyReflowRow(page, scaleSlider, ACAB.INDENT_INPUT, scaleSliderY)

		cursorY = scaleSliderY - 36
	end

	-------------------------------------------------------------------------
	-- Grid Layout (Micro Menu only - config.hasGrid). Fixed preset swatch
	-- picker, same mechanism as the full grid pages (GetOrCreateBarPage),
	-- reusing RebuildGridSwatches/RefreshGridSwatchSelection directly.
	-------------------------------------------------------------------------

	if config.hasGrid then
		local gridTitleY = cursorY
		local swatchY = gridTitleY - 26

		local gridTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		gridTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, gridTitleY)
		gridTitle:SetText("Grid Layout")

		page.gridSwatchY = swatchY

		RebuildGridSwatches(page, key, swatchY)

		-- Grid Layout can't just be added to page.hoverOnlyReflowRows - its
		-- swatches are a dynamic array, repositioned in place instead.
		page.hoverOnlyExtraReflow = function(offset)
			gridTitle:ClearAllPoints()
			gridTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, gridTitleY - offset)

			page.gridSwatchY = swatchY - offset

			if page.gridSwatches then
				local xOffset = ACAB.INDENT_CONTROL
				local i

				for i = 1, table.getn(page.gridSwatches) do
					local swatch = page.gridSwatches[i]

					swatch:ClearAllPoints()
					swatch:SetPoint("TOPLEFT", page, "TOPLEFT", xOffset, page.gridSwatchY)

					xOffset = xOffset + SWATCH_SIZE + SWATCH_GAP
				end
			end
		end

		-- Same swatch-height-plus-caption-plus-gap arithmetic as
		-- GetOrCreateBarPage's own button-count-row positioning below its
		-- Grid Layout section.
		cursorY = swatchY - SWATCH_SIZE - 14 - 14
	end

	-------------------------------------------------------------------------
	-- "Better Experience Bar" + its 5 text toggles + 2 bar-fill color
	-- pickers - Experience Bar page only. Independent of the "Enabled"
	-- checkbox further up this function (config.hasEnable, the container's
	-- own Position/Scale/Enable/Reset) - ACABDB.betterExpBarEnabled
	-- only governs the text overlay, never the container's own movability.
	-------------------------------------------------------------------------

	if key == "expbar" then
		local betterExpBarCheckbox = ACAB:CreateLabeledCheckbox(page, "ACABSimplePageExpBarBetterCheckbox", {
			anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, cursorY },
			label = "Enable Better Experience Bar",
			tooltip = {
				title = "Enable Better Experience Bar",
				lines = {
					"Replaces the native percent label with a customizable text " ..
					"line, and lets you recolor the bar's own fill and rested-" ..
					"bonus fill below.",
				},
			},
			onClick = function()
				local checked = this:GetChecked() and true or false

				ACABDB.betterExpBarEnabled = checked

				ACAB:ApplyBetterExpBarVisual()

				-- Applies the saved earned/rested color when turning the
				-- feature on; ACAB:ApplyExpBarColors itself gates on
				-- betterExpBarEnabled, so this is a no-op when turning it off.
				ACAB:ApplyExpBarColors()

				ApplyBetterExpBarGating(page)
			end,
		})

		page.betterExpBarCheckbox = betterExpBarCheckbox

		ACAB:AddHoverOnlyReflowRow(page, betterExpBarCheckbox, ACAB.INDENT_SECTION, cursorY)

		cursorY = cursorY - 24 - 14

		-------------------------------------------------------------------------
		-- Overlay Text Size slider, below "Enable Better Experience Bar".
		-- Range/step/ClampFontSize match the General panel's Hotkey/Count
		-- Text Size sliders.
		-------------------------------------------------------------------------

		local fontSizeTitleY = cursorY
		local fontSizeSliderY = fontSizeTitleY - 26

		local fontSizeTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		fontSizeTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, fontSizeTitleY)
		fontSizeTitle:SetText(
			"Overlay Text Size (" .. tostring(ACAB.FONT_SIZE_MIN) ..
			" to " .. tostring(ACAB.FONT_SIZE_MAX) .. ")"
		)

		ACAB:AddHoverOnlyReflowRow(page, fontSizeTitle, ACAB.INDENT_SECTION, fontSizeTitleY)

		-- Placeholder initial text only - RefreshSimpleBarPage overwrites
		-- this with the real saved/native value before this page is ever
		-- visible.
		local fontSizeSlider, fontSizeValueText = ACAB:CreateLabeledSlider(
			page,
			"ACABSimplePageExpBarFontSizeSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, fontSizeSliderY },
				min = ACAB.FONT_SIZE_MIN,
				max = ACAB.FONT_SIZE_MAX,
				step = ACAB.FONT_SIZE_STEP,
				lowText = tostring(ACAB.FONT_SIZE_MIN),
				highText = tostring(ACAB.FONT_SIZE_MAX),
				initialText = tostring(ACAB.FONT_SIZE_MIN),
				round = function(value) return math.floor(value + 0.5) end,
				format = tostring,
				onChange = function(value, suppressApply)
					if not suppressApply then
						ACAB:SetExpBarFontSize(value)
					end
				end,
			}
		)

		page.expBarFontSizeValueText = fontSizeValueText
		page.expBarFontSizeSlider = fontSizeSlider

		ACAB:AddHoverOnlyReflowRow(page, fontSizeSlider, ACAB.INDENT_INPUT, fontSizeSliderY)

		cursorY = fontSizeSliderY - 36

		-------------------------------------------------------------------------
		-- 5 text-segment toggles
		-------------------------------------------------------------------------

		local showLevelCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowLevel", "Show Current Lvl", cursorY, "expBarShowLevel"
		)
		page.expBarShowLevelCheckbox = showLevelCheckbox
		ACAB:AddHoverOnlyReflowRow(page, showLevelCheckbox, ACAB.INDENT_SECTION, cursorY)
		cursorY = cursorY - 24 - 6

		local showCurrentOverMaxCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowCurrentOverMax", "Show Current XP / Max", cursorY, "expBarShowCurrentOverMax"
		)
		page.expBarShowCurrentOverMaxCheckbox = showCurrentOverMaxCheckbox
		ACAB:AddHoverOnlyReflowRow(page, showCurrentOverMaxCheckbox, ACAB.INDENT_SECTION, cursorY)
		cursorY = cursorY - 24 - 6

		local showPercentCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowPercent", "Show Current % / Max", cursorY, "expBarShowPercent"
		)
		page.expBarShowPercentCheckbox = showPercentCheckbox
		ACAB:AddHoverOnlyReflowRow(page, showPercentCheckbox, ACAB.INDENT_SECTION, cursorY)
		cursorY = cursorY - 24 - 6

		local showRestedPercentCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowRestedPercent", "Show Current Rested XP %", cursorY, "expBarShowRestedPercent"
		)
		page.expBarShowRestedPercentCheckbox = showRestedPercentCheckbox
		ACAB:AddHoverOnlyReflowRow(page, showRestedPercentCheckbox, ACAB.INDENT_SECTION, cursorY)
		cursorY = cursorY - 24 - 6

		local showRestedTotalCheckbox = CreateExpBarTextToggleCheckbox(
			page, "ShowRestedTotal", "Show Current Total Rested XP", cursorY, "expBarShowRestedTotal"
		)
		page.expBarShowRestedTotalCheckbox = showRestedTotalCheckbox
		ACAB:AddHoverOnlyReflowRow(page, showRestedTotalCheckbox, ACAB.INDENT_SECTION, cursorY)
		cursorY = cursorY - 24 - 18

		-------------------------------------------------------------------------
		-- 2 bar-fill color pickers
		-------------------------------------------------------------------------

		local earnedColorLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		earnedColorLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, cursorY)
		earnedColorLabel:SetText("Earned XP Bar Color")

		ACAB:AddHoverOnlyReflowRow(page, earnedColorLabel, ACAB.INDENT_CONTROL, cursorY)

		local earnedColorSwatch = CreateColorSwatchButton(
			page, "ACABSimplePageExpBarEarnedColorSwatch"
		)

		earnedColorSwatch:SetPoint("LEFT", earnedColorLabel, "RIGHT", 12, 0)

		earnedColorSwatch:SetScript(
			"OnClick",
			function()
				OpenExpBarColorPicker(
					earnedColorSwatch,
					function() return ACABDB.expBarColorEarned end,
					function(r, g, b) ACAB:SetExpBarColorEarned(r, g, b) end
				)
			end
		)

		page.earnedColorSwatch = earnedColorSwatch

		cursorY = cursorY - 24 - 14

		local restedColorLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		restedColorLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, cursorY)
		restedColorLabel:SetText("Rested XP Bar Color")

		ACAB:AddHoverOnlyReflowRow(page, restedColorLabel, ACAB.INDENT_CONTROL, cursorY)

		local restedColorSwatch = CreateColorSwatchButton(
			page, "ACABSimplePageExpBarRestedColorSwatch"
		)

		restedColorSwatch:SetPoint("LEFT", restedColorLabel, "RIGHT", 12, 0)

		restedColorSwatch:SetScript(
			"OnClick",
			function()
				OpenExpBarColorPicker(
					restedColorSwatch,
					function() return ACABDB.expBarColorRested end,
					function(r, g, b) ACAB:SetExpBarColorRested(r, g, b) end
				)
			end
		)

		page.restedColorSwatch = restedColorSwatch

		cursorY = cursorY - 24 - 14

		-------------------------------------------------------------------------
		-- Overlay Text Color swatch, below the Rested XP Bar Color picker.
		-- Wired to ACABDB.expBarTextColor/ACAB:SetExpBarTextColor via the
		-- same CreateColorSwatchButton/OpenExpBarColorPicker mechanic as the
		-- bar-fill pickers above.
		-------------------------------------------------------------------------

		local textColorLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		textColorLabel:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_CONTROL, cursorY)
		textColorLabel:SetText("Overlay Text Color")

		ACAB:AddHoverOnlyReflowRow(page, textColorLabel, ACAB.INDENT_CONTROL, cursorY)

		local textColorSwatch = CreateColorSwatchButton(
			page, "ACABSimplePageExpBarTextColorSwatch"
		)

		textColorSwatch:SetPoint("LEFT", textColorLabel, "RIGHT", 12, 0)

		textColorSwatch:SetScript(
			"OnClick",
			function()
				OpenExpBarColorPicker(
					textColorSwatch,
					function() return ACABDB.expBarTextColor end,
					function(r, g, b) ACAB:SetExpBarTextColor(r, g, b) end
				)
			end
		)

		page.expBarTextColorSwatch = textColorSwatch

		cursorY = cursorY - 24 - 14

		local resetColorsButton = ACAB:CreateResetButton(page, {
			anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, cursorY },
			minWidth = 200,
			maxWidth = 200,
			text = "Reset Colors to Default",
			onClick = function()
				ACAB:ResetExpBarColors()

				ACAB:RefreshBarSettingsPage("expbar")
			end,
		})

		page.resetColorsButton = resetColorsButton

		ACAB:AddHoverOnlyReflowRow(page, resetColorsButton, ACAB.INDENT_INPUT, cursorY)

		cursorY = cursorY - 22 - 26

		-------------------------------------------------------------------------
		-- Rested Glow Pulse Interval slider, below the Reset Colors button.
		-- Better-Experience-Bar-only (gated by ApplyBetterExpBarGating
		-- below). Range/step: 0.5 to 5.0 seconds, step 0.1.
		-------------------------------------------------------------------------

		local pulseIntervalTitleY = cursorY
		local pulseIntervalSliderY = pulseIntervalTitleY - 26

		local pulseIntervalTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		pulseIntervalTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, pulseIntervalTitleY)
		pulseIntervalTitle:SetText("Rested Glow Pulse Interval (0.5 to 5.0 sec)")

		ACAB:AddHoverOnlyReflowRow(page, pulseIntervalTitle, ACAB.INDENT_SECTION, pulseIntervalTitleY)

		-- Placeholder initial text only - RefreshSimpleBarPage overwrites
		-- this with the real saved value before this page is ever visible.
		local pulseIntervalSlider, pulseIntervalValueText = ACAB:CreateLabeledSlider(
			page,
			"ACABSimplePageExpBarPulseIntervalSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, pulseIntervalSliderY },
				min = 0.5,
				max = 5.0,
				step = 0.1,
				lowText = "0.5",
				highText = "5.0",
				initialText = "1.5",
				round = function(value) return math.floor((value * 10) + 0.5) / 10 end,
				format = function(value) return string.format("%.1f", value) end,
				onChange = function(value, suppressApply)
					if not suppressApply then
						ACAB:SetExpBarGlowPulseInterval(value)
					end
				end,
			}
		)

		page.expBarGlowPulseIntervalValueText = pulseIntervalValueText
		page.expBarGlowPulseIntervalSlider = pulseIntervalSlider

		ACAB:AddHoverOnlyReflowRow(page, pulseIntervalSlider, ACAB.INDENT_INPUT, pulseIntervalSliderY)

		cursorY = pulseIntervalSliderY - 36
	end

	-------------------------------------------------------------------------
	-- Show Key Ring (Bag Bar page only) - KeyRingButton is independently
	-- toggleable/positionable (DefaultBars.lua's SetKeyRingEnabled/
	-- SetKeyRingPosition); this checkbox is purely show/hide. Dragging is
	-- done directly on the button itself (its own overlay, right-click
	-- routes back to this page - DefaultBars.lua's ApplyKeyRingPosition).
	-------------------------------------------------------------------------

	if key == "bagbar" then
		local keyRingCheckbox = ACAB:CreateLabeledCheckbox(page, "ACABSimplePageBagBarKeyRingCheckbox", {
			anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, cursorY },
			label = "Show Key Ring",
			onClick = function()
				local checked = this:GetChecked() and true or false

				ACAB:SetKeyRingEnabled(checked)
			end,
		})

		page.keyRingCheckbox = keyRingCheckbox

		ACAB:AddHoverOnlyReflowRow(page, keyRingCheckbox, ACAB.INDENT_SECTION, cursorY)

		cursorY = cursorY - 24 - 14

		-------------------------------------------------------------------------
		-- Key Ring Scale, below the checkbox above. Standalone rather than
		-- config-driven: Key Ring has no ACAB.simpleBarPageConfigs entry of
		-- its own (it lives on the Bag Bar's page). Writes through
		-- ACAB:SetKeyRingScale.
		-------------------------------------------------------------------------

		local keyRingScaleTitleY = cursorY
		local keyRingScaleSliderY = keyRingScaleTitleY - 26

		local keyRingScaleTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")

		keyRingScaleTitle:SetPoint("TOPLEFT", page, "TOPLEFT", ACAB.INDENT_SECTION, keyRingScaleTitleY)
		keyRingScaleTitle:SetText("Key Ring Scale (0.5 to 2.0)")

		ACAB:AddHoverOnlyReflowRow(page, keyRingScaleTitle, ACAB.INDENT_SECTION, keyRingScaleTitleY)

		local keyRingScaleSlider, keyRingScaleValueText = ACAB:CreateLabeledSlider(
			page,
			"ACABSimplePageBagBarKeyRingScaleSlider",
			{
				anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, keyRingScaleSliderY },
				min = 0.5,
				max = 2.0,
				step = 0.1,
				lowText = "0.5",
				highText = "2.0",
				initialText = "1.0",
				round = function(value) return math.floor((value * 10) + 0.5) / 10 end,
				format = function(value) return string.format("%.1f", value) end,
				onChange = function(value, suppressApply)
					if not suppressApply then
						ACAB:SetKeyRingScale(value)
					end
				end,
			}
		)

		page.keyRingScaleValueText = keyRingScaleValueText
		page.keyRingScaleSlider = keyRingScaleSlider

		ACAB:AddHoverOnlyReflowRow(page, keyRingScaleSlider, ACAB.INDENT_INPUT, keyRingScaleSliderY)

		cursorY = keyRingScaleSliderY - 36
	end

	local resetY = cursorY

	-------------------------------------------------------------------------
	-- Reset to Blizzard Default
	-------------------------------------------------------------------------

	local resetButton = ACAB:CreateResetButton(page, {
		anchor = { "TOPLEFT", page, "TOPLEFT", ACAB.INDENT_INPUT, resetY },
		minWidth = 200,
		maxWidth = 200,
		text = "Reset to Blizzard Default",
		onClick = function()
			config.reset()

			-- GetSimpleElementCoordinateRange reads the element's real
			-- rendered GetWidth()/GetHeight() - a SetWidth/SetHeight from
			-- config.reset() above doesn't resolve until the next frame on
			-- this client, so refreshing synchronously here would compute
			-- the slider range against the stale pre-reset footprint.
			-- Deferred one frame so it reads the settled size instead.
			if C_Timer and C_Timer.After then
				C_Timer.After(0, function()
					ACAB:RefreshBarSettingsPage(key)
				end)
			else
				ACAB:RefreshBarSettingsPage(key)
			end
		end,
	})

	ACAB:AddHoverOnlyReflowRow(page, resetButton, ACAB.INDENT_INPUT, resetY)

	page.resetPositionButton = resetButton

	page:Hide()

	ACAB.settingsFrame.pages[key] = page

	return page
end

function ACAB:GetOrCreateSimpleBarPage(key)
	if not ACAB.settingsFrame then
		ACAB:CreateSettingsFrame()
	end

	if ACAB.settingsFrame.pages[key] then
		return ACAB.settingsFrame.pages[key]
	end

	return CreateSimpleBarPage(key)
end

function ACAB:RefreshSimpleBarPage(key)
	if not ACAB.settingsFrame then
		return
	end

	local page = ACAB.settingsFrame.pages[key]
	local config = ACAB.simpleBarPageConfigs[key]

	if not page or not config then
		return
	end

	-- Suppress OnValueChanged re-application before touching the sliders at
	-- all - SetMinMaxValues just below re-clamps the slider's CURRENT value
	-- if it's now outside the new range, which fires OnValueChanged same as
	-- a real drag would. Setting suppressApply first (not after, as this
	-- used to) stops that clamp from writing a stray value into the saved
	-- config ahead of the explicit clamp-and-persist logic below.
	page.xSlider.suppressApply = true
	page.ySlider.suppressApply = true
	page.xSlider.suppressSnap = true
	page.ySlider.suppressSnap = true

	-- X/Y clamp range - recomputed from this element's CURRENT rendered
	-- size before syncing the value below, so scale/spacing changes,
	-- grid-preset picks, and "Reset to Blizzard Default" (all of which
	-- route here) always re-clamp against the up to date footprint.
	if config.getElementFrame then
		local frame = config.getElementFrame()

		if frame then
			local minX, maxX, minY, maxY = ACAB:GetSimpleElementCoordinateRange(frame, config.extraMaxYPixels)

			page.xSlider:SetMinMaxValues(minX, maxX)
			page.ySlider:SetMinMaxValues(minY, maxY)

			-- A scale increase keeps the bottom-left corner fixed and grows
			-- toward the top-right, so a position that was valid before can
			-- push the far edge off-screen after the footprint grows -
			-- clamp and persist here (not just SetMinMaxValues, which only
			-- clamps the slider's DISPLAYED value, not the saved position)
			-- so the stored position never silently drifts off-screen.
			local rawPos = config.getPosition()

			if rawPos and config.setPosition then
				local clampedX = rawPos.x or 0
				local clampedY = rawPos.y or 0

				if clampedX < minX then clampedX = minX end
				if clampedX > maxX then clampedX = maxX end
				if clampedY < minY then clampedY = minY end
				if clampedY > maxY then clampedY = maxY end

				if clampedX ~= rawPos.x or clampedY ~= rawPos.y then
					config.setPosition(clampedX, clampedY)
				end
			end
		end
	end

	local pos = config.getPosition() or { x = 0, y = 0 }

	page.xSlider:SetValue(pos.x or 0)
	page.ySlider:SetValue(pos.y or 0)

	-- Explicit, not just relying on OnValueChanged: it doesn't fire (and
	-- so wouldn't refresh xAppliedValue/yAppliedValue) when pos.x/y equals
	-- whatever the slider was already sitting at.
	page.xAppliedValue = pos.x or 0
	page.yAppliedValue = pos.y or 0

	page.xValueText:SetText(string.format("%.2f", pos.x or 0))
	page.yValueText:SetText(string.format("%.2f", pos.y or 0))

	page.xSlider.suppressApply = nil
	page.ySlider.suppressApply = nil
	page.xSlider.suppressSnap = nil
	page.ySlider.suppressSnap = nil

	if page.enableCheckbox and config.getEnabled then
		page.enableCheckbox:SetChecked(config.getEnabled() ~= false)
	end

	-- Both checkboxes lock (greyed out via ACAB:LockControlKeepingTooltip
	-- further below, after ApplyProfileLockGating) and their DISPLAYED
	-- checked-state collapses to the vanilla-forced value while locked,
	-- rather than showing the raw stored preference - same collapse idiom
	-- as modernBorderStyleCheckbox (Core.lua's IsVanillaBorderStyle).
	if page.useVanillaPetBarCheckbox or page.condenseEmptyPetSlotsCheckbox then
		local petLocked = ACAB:IsDefaultProfileActive() or ACABDB.useDefaultLayout == true
		local petCfg = ACABDB.defaultBars and ACABDB.defaultBars[ACAB.PET_BAR_ID]

		if page.useVanillaPetBarCheckbox then
			page.useVanillaPetBarCheckbox:SetChecked(petLocked or IsPetBarNativeMode())
		end

		if page.condenseEmptyPetSlotsCheckbox then
			page.condenseEmptyPetSlotsCheckbox:SetChecked(
				(not petLocked) and petCfg and petCfg.condenseEmptyPetSlots == true
			)
		end
	end

	-- Same collapse idiom, for the Stance Bar's own toggle.
	if page.useVanillaStanceBarCheckbox then
		local stanceLocked = ACAB:IsDefaultProfileActive() or ACABDB.useDefaultLayout == true

		page.useVanillaStanceBarCheckbox:SetChecked(stanceLocked or IsStanceBarNativeMode())
	end

	-- Show Key Ring (Bag Bar page only) - independent of config.getEnabled
	-- above (that's the Bag Bar's OWN enable flag), reads
	-- ACABDB.keyRingEnabled directly since it has no
	-- ACAB.simpleBarPageConfigs entry of its own.
	if page.keyRingCheckbox then
		page.keyRingCheckbox:SetChecked(ACABDB.keyRingEnabled ~= false)
	end

	-- Key Ring Scale - same standalone (non-config-driven) treatment as
	-- the checkbox above.
	if page.keyRingScaleSlider then
		local keyRingScale = ACABDB.keyRingScale or 1

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
	-- Spacing/Scale/Orientation - each optional per
	-- config.hasSpacing/hasScale/hasOrientation, mirroring the enable
	-- checkbox's own presence check above.
	-------------------------------------------------------------------------

	if page.spacingSlider and config.getSpacing then
		-- Displayed slider value = actual stored spacing + uiOffset
		-- (Micro Menu only - see config.spacingUiOffset).
		local uiOffset = config.spacingUiOffset or 0
		local spacing = (config.getSpacing() or 0) + uiOffset
		local spacingMin = config.spacingMin or ACAB.SPACING_MIN

		if spacing < spacingMin then
			spacing = spacingMin
		end

		if spacing > ACAB.SPACING_MAX then
			spacing = ACAB.SPACING_MAX
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

	if page.gridSwatches and config.getGridLayout then
		local cols, rows = config.getGridLayout()

		RefreshGridSwatchSelection(page, cols, rows)
	end

	if config.hasHoverOnly then
		self:RefreshHoverOnlyControls(page, config.getHoverOnly(), config.getHoverDuration())
	end

	if page.tooltipAnchorCornerRow and page.tooltipAnchorCornerRow.dropdown then
		page.tooltipAnchorCornerRow.dropdown:SetSelected(ACABDB.tooltipAnchorCorner or "BOTTOMRIGHT")
	end

	-------------------------------------------------------------------------
	-- "Better Experience Bar" + its 5 text toggles + Font Size slider +
	-- 3 color swatches (Experience Bar page only) - independent of
	-- config.getEnabled above (that's the container's OWN enable flag), so
	-- these read ACABDB.betterExpBarEnabled/expBarShow*/expBarFontSize/
	-- expBarColor*/expBarTextColor directly, same non-config-driven
	-- treatment as Key Ring's own fields above.
	-------------------------------------------------------------------------

	if page.betterExpBarCheckbox then
		page.betterExpBarCheckbox:SetChecked(ACABDB.betterExpBarEnabled == true)

		if page.expBarShowLevelCheckbox then
			page.expBarShowLevelCheckbox:SetChecked(ACABDB.expBarShowLevel == true)
		end

		if page.expBarShowCurrentOverMaxCheckbox then
			page.expBarShowCurrentOverMaxCheckbox:SetChecked(ACABDB.expBarShowCurrentOverMax == true)
		end

		if page.expBarShowPercentCheckbox then
			page.expBarShowPercentCheckbox:SetChecked(ACABDB.expBarShowPercent == true)
		end

		if page.expBarShowRestedPercentCheckbox then
			page.expBarShowRestedPercentCheckbox:SetChecked(ACABDB.expBarShowRestedPercent == true)
		end

		if page.expBarShowRestedTotalCheckbox then
			page.expBarShowRestedTotalCheckbox:SetChecked(ACABDB.expBarShowRestedTotal == true)
		end

		-- ACABDB.expBarFontSize stays nil until the user moves this
		-- slider (same lazy-default idiom as hotkeyFontSize/countFontSize).
		-- ACAB:CaptureNativeExpBarFontIfNeeded guarantees ACAB.NATIVE_EXPBAR_FONT
		-- is populated, safe to call even before this overlay is built.
		if page.expBarFontSizeSlider then
			ACAB:CaptureNativeExpBarFontIfNeeded()

			local nativeDefault = ACAB.NATIVE_EXPBAR_FONT and (ACAB.NATIVE_EXPBAR_FONT.size - 1)
			local fontSize = ACAB:ClampFontSize(ACABDB.expBarFontSize or nativeDefault)

			page.expBarFontSizeSlider.suppressApply = true
			page.expBarFontSizeSlider:SetValue(fontSize)
			page.expBarFontSizeSlider.suppressApply = nil

			if page.expBarFontSizeValueText then
				page.expBarFontSizeValueText:SetText(tostring(fontSize))
			end
		end

		-- ACAB:CaptureExpBarColorsIfNeeded (via ACAB:ApplyExpBarColors,
		-- called unconditionally from Core.lua's login sequence) has
		-- already guaranteed both fields are non-nil by the time Settings
		-- can even be opened, so no nil fallback is needed here the way
		-- the color picker's own OpenExpBarColorPicker call defensively
		-- has one.
		if page.earnedColorSwatch then
			SetColorSwatchColor(page.earnedColorSwatch, ACABDB.expBarColorEarned)
		end

		if page.restedColorSwatch then
			SetColorSwatchColor(page.restedColorSwatch, ACABDB.expBarColorRested)
		end

		-- ACABDB.expBarTextColor is always seeded by Core.lua's
		-- EnsureDB (a straight default, no live-frame capture needed), so
		-- it's never nil here.
		if page.expBarTextColorSwatch then
			SetColorSwatchColor(page.expBarTextColorSwatch, ACABDB.expBarTextColor)
		end

		-- ACABDB.expBarGlowPulseInterval is always seeded by
		-- Core.lua's EnsureDB (same as expBarTextColor above), so it's
		-- never nil here.
		if page.expBarGlowPulseIntervalSlider then
			local interval = ACABDB.expBarGlowPulseInterval or 1.5

			page.expBarGlowPulseIntervalSlider.suppressApply = true
			page.expBarGlowPulseIntervalSlider:SetValue(interval)
			page.expBarGlowPulseIntervalSlider.suppressApply = nil

			if page.expBarGlowPulseIntervalValueText then
				page.expBarGlowPulseIntervalValueText:SetText(string.format("%.1f", interval))
			end
		end

		ApplyBetterExpBarGating(page)
	end

	-- Stance Bar/Pet Bar/Cast Bar stay fully unlocked on this gate even
	-- while useDefaultLayout is on - they stack dynamically off Action
	-- Bar 1/2/Extra Bar 1/2 (GetStanceBarBaselineY/GetPetBarBaselineY/
	-- GetCastBarBaselineY, only while each element's own
	-- usesDefaultPosition flag is true) and are draggable in edit mode
	-- regardless (DefaultBars.lua's ApplyDefaultLayoutEditVisual), so
	-- their own Settings page must stay editable the same way. Every
	-- other simple page keeps the normal layout lock.
	local skipLayoutLock = key == ACAB.PET_BAR_ID or key == ACAB.STANCE_BAR_ID or key == "castbar" or key == "tooltip"

	-- Same gating window as bar 1 (CanDragDefaultLayout's underlying
	-- rule) - the enable checkbox and Reset button are deliberately
	-- excluded, mirroring ApplyDefaultLayoutGating's own established
	-- rule for bar 1 (they stay fully functional regardless of
	-- useDefaultLayout).
	ACAB:ApplyDefaultLayoutGating(page, skipLayoutLock or ACABDB.useDefaultLayout ~= true)

	-- Default-profile lock (independent of the useDefaultLayout gate
	-- above) - every simple page is also subject to that layout lock
	-- (the ApplyDefaultLayoutGating call just above), so the banner
	-- should reflect it here too - except the three elements exempted above.
	self:ApplyProfileLockGating(page, not skipLayoutLock)

	-- Use Vanilla Pet Bar/Stance Bar (and Pet Bar's coupled Condense Empty
	-- Slots) stay locked by Default Layout/Default Profile even on the
	-- Pet Bar/Stance Bar page's otherwise-unlocked gate above - forcing
	-- native mode is exactly what lets that page's position/shape controls
	-- stay usable, so switching away from native isn't allowed while
	-- either lock is active. Runs AFTER ApplyProfileLockGating (not
	-- folded into the exempt list there) so it has the final say, and
	-- uses ACAB:LockControlKeepingTooltip instead of ACAB:LockControl so
	-- the red locked-reason tooltip (VANILLA_MODE_LOCKED_TEXT,
	-- CreateUseVanillaPetBarCheckbox/CreateUseVanillaStanceBarCheckbox)
	-- still shows on hover while locked.
	local vanillaModeLocked = ACAB:IsDefaultProfileActive() or ACABDB.useDefaultLayout == true

	if page.useVanillaPetBarCheckbox then
		ACAB:LockControlKeepingTooltip(page.useVanillaPetBarCheckbox, vanillaModeLocked)
	end

	if page.condenseEmptyPetSlotsCheckbox then
		ACAB:LockControlKeepingTooltip(page.condenseEmptyPetSlotsCheckbox, vanillaModeLocked)
	end

	if page.useVanillaStanceBarCheckbox then
		ACAB:LockControlKeepingTooltip(page.useVanillaStanceBarCheckbox, vanillaModeLocked)
	end
end

-- Config table for each simple page - the single place mapping
-- Settings.lua's UI onto DefaultBars.lua's ACAB:Set*/Reset*/Get* API.
-- Referenced by CreateBarListRow and GetOrCreateBarPage/
-- RefreshBarSettingsPage's dispatch checks.
--
-- Stance Bar native mode: keyed by the numeric ACAB.STANCE_BAR_ID (like the
-- Pet Bar's entry below), reached only via IsStanceBarNativeMode()
-- dispatch. WARNING: drives the native-mode ACABDB.stanceBar* fields
-- ONLY - separate from ACABDB.defaultBars[STANCE_BAR_ID], the styled
-- mode's own cfg (see Core.lua's ACAB.STANCE_BAR_ID header comment).
ACAB.simpleBarPageConfigs[ACAB.STANCE_BAR_ID] = {
	title = "Stance Bar",
	hasEnable = true,
	getPosition = function() return ACABDB.stanceBarPosition end,
	setPosition = function(x, y) ACAB:SetStanceBarPosition(x, y) end,
	getElementFrame = function() return ACAB.stanceBarContainer end,
	reset = function()
		-- Layout first: it writes scale directly to the DB without
		-- reapplying position, so applying position after settles it
		-- under the final scale instead of the stale pre-reset one.
		ACAB:ResetStanceBarLayout()
		ACAB:ResetStanceBarPosition()
	end,
	getEnabled = function() return ACABDB.stanceBarEnabled end,
	setEnabled = function(v) ACAB:SetStanceBarEnabled(v) end,
	hasSpacing = true,
	getSpacing = function() return ACABDB.stanceBarSpacing end,
	setSpacing = function(v) ACAB:SetStanceBarSpacing(v) end,
	hasScale = true,
	getScale = function() return ACABDB.stanceBarScale end,
	setScale = function(v) ACAB:SetStanceBarScale(v) end,
	hasOrientation = true,
	getOrientation = function() return ACABDB.stanceBarOrientation end,
	setOrientation = function(v) ACAB:SetStanceBarOrientation(v) end,
	-- Shared with the custom-styled Stance Bar's grid: defaultBars[STANCE_BAR_ID].hoverOnly/hoverDuration, not a separate flat field.
	hasHoverOnly = true,
	getHoverOnly = function()
		local cfg = ACABDB.defaultBars[ACAB.STANCE_BAR_ID]
		return cfg and cfg.hoverOnly
	end,
	setHoverOnly = function(v) ACAB:SetStanceBarNativeHoverOnly(v) end,
	getHoverDuration = function()
		local cfg = ACABDB.defaultBars[ACAB.STANCE_BAR_ID]
		return (cfg and cfg.hoverDuration) or 3
	end,
	setHoverDuration = function(v) ACAB:SetStanceBarNativeHoverDuration(v) end,
}

-- Bag Bar's synthetic container is a ACAB-owned chain-anchored
-- layout (BuildChainAnchoredContainer/ApplyChainAnchoredShape -
-- DefaultBars.lua), so it gets Spacing/Scale/Orientation controls too.
ACAB.simpleBarPageConfigs["bagbar"] = {
	title = "Bag Bar",
	hasEnable = true,
	getPosition = function() return ACABDB.bagBarPosition end,
	setPosition = function(x, y) ACAB:SetBagBarPosition(x, y) end,
	getElementFrame = function() return ACAB.bagBarContainer end,
	reset = function()
		-- Layout first: it writes scale directly to the DB without
		-- reapplying position, so applying position after settles it
		-- under the final scale instead of the stale pre-reset one.
		ACAB:ResetBagBarLayout()
		ACAB:ResetBagBarPosition()

		-- Key Ring lives on this same page (see CreateSimpleBarPage's
		-- `if key == "bagbar"` block), so its position resets here too
		-- rather than leaving it untouched by the Bag Bar's own Reset
		-- button - mirrors the "Use Default Blizzard Layout" re-enable
		-- flow, which calls ACAB:ResetKeyRingPosition() independently
		-- (Settings.lua's General tab handler). Key Ring's native anchor is
		-- relative to the Bag Bar container ResetBagBarPosition just moved
		-- above - that SetPoint doesn't resolve until the next frame on
		-- this client, so resolving Key Ring's anchor against it
		-- synchronously here would read the stale pre-reset position.
		-- Deferred one frame so it reads the settled one instead.
		if ACAB.ResetKeyRingPosition then
			if C_Timer and C_Timer.After then
				C_Timer.After(0, function()
					ACAB:ResetKeyRingPosition()
				end)
			else
				ACAB:ResetKeyRingPosition()
			end
		end
	end,
	getEnabled = function() return ACABDB.bagBarEnabled end,
	setEnabled = function(v) ACAB:SetBagBarEnabled(v) end,
	hasSpacing = true,
	getSpacing = function() return ACABDB.bagBarSpacing end,
	setSpacing = function(v) ACAB:SetBagBarSpacing(v) end,
	hasScale = true,
	getScale = function() return ACABDB.bagBarScale end,
	setScale = function(v) ACAB:SetBagBarScale(v) end,
	hasOrientation = true,
	getOrientation = function() return ACABDB.bagBarOrientation end,
	setOrientation = function(v) ACAB:SetBagBarOrientation(v) end,
	-- Also governs the Key Ring frame - no separate Key Ring fields/controls.
	hasHoverOnly = true,
	getHoverOnly = function() return ACABDB.bagBarHoverOnly end,
	setHoverOnly = function(v) ACAB:SetBagBarHoverOnly(v) end,
	getHoverDuration = function() return ACABDB.bagBarHoverDuration or 3 end,
	setHoverDuration = function(v) ACAB:SetBagBarHoverDuration(v) end,
}

-- Pet Bar native mode: reuses the same defaultBars[PET_BAR_ID] cfg the custom-styled grid mode uses, so x/y/spacing never drift between modes.
-- Keyed by the numeric ACAB.PET_BAR_ID, only reached via IsPetBarNativeMode() dispatch.
ACAB.simpleBarPageConfigs[ACAB.PET_BAR_ID] = {
	title = "Pet Bar",
	hasEnable = true,
	getPosition = function() return ACABDB.defaultBars[ACAB.PET_BAR_ID] end,
	setPosition = function(x, y) ACAB:SetPetBarNativePosition(x, y) end,
	getElementFrame = function() return ACAB.petBarNativeContainer end,
	reset = function() ACAB:ResetPetBarNativeLayout() end,
	getEnabled = function()
		local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]
		return cfg and cfg.enabled
	end,
	setEnabled = function(v) ACAB:SetDefaultBarEnabled(ACAB.PET_BAR_ID, v) end,
	hasSpacing = true,
	getSpacing = function()
		local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]
		return cfg and cfg.spacing
	end,
	setSpacing = function(v) ACAB:SetPetBarNativeSpacing(v) end,
	hasScale = true,
	getScale = function()
		local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]
		return cfg and cfg.scale
	end,
	setScale = function(v) ACAB:SetPetBarNativeScale(v) end,
	-- Shared with the custom-styled Pet Bar's grid, same treatment as the Stance Bar's own entry above.
	hasHoverOnly = true,
	getHoverOnly = function()
		local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]
		return cfg and cfg.hoverOnly
	end,
	setHoverOnly = function(v) ACAB:SetPetBarNativeHoverOnly(v) end,
	getHoverDuration = function()
		local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]
		return (cfg and cfg.hoverDuration) or 3
	end,
	setHoverDuration = function(v) ACAB:SetPetBarNativeHoverDuration(v) end,
}

-- Scale only: Blizzard owns MainMenuBarPerformanceBarFrame's own internal
-- layout entirely (it's a single self-contained frame, not a
-- ACAB-owned chain), so Spacing/Orientation have nothing real to
-- drive.
ACAB.simpleBarPageConfigs["latencybar"] = {
	title = "Latency Bar",
	hasEnable = true,
	getPosition = function() return ACABDB.latencyBarPosition end,
	setPosition = function(x, y) ACAB:SetLatencyBarPosition(x, y) end,
	getElementFrame = function() return getglobal(ACAB.LATENCY_BAR_FRAME_NAME) end,
	reset = function()
		ACAB:ResetLatencyBarLayout()
	end,
	getEnabled = function() return ACABDB.latencyBarEnabled end,
	setEnabled = function(v) ACAB:SetLatencyBarEnabled(v) end,
	hasScale = true,
	getScale = function() return ACABDB.latencyBarScale end,
	setScale = function(v) ACAB:SetLatencyBarScale(v) end,
	hasHoverOnly = true,
	getHoverOnly = function() return ACABDB.latencyBarHoverOnly end,
	setHoverOnly = function(v) ACAB:SetLatencyBarHoverOnly(v) end,
	getHoverDuration = function() return ACABDB.latencyBarHoverDuration or 3 end,
	setHoverDuration = function(v) ACAB:SetLatencyBarHoverDuration(v) end,
}

-- Experience Bar: Scale only, same reasoning as the Latency Bar's own
-- config above - MainMenuExpBar is a single self-contained native frame,
-- not a ACAB-owned chain, so Spacing/Orientation have nothing real
-- to drive. This config only covers the container's own
-- Position/Scale/Enable/Reset - "Enable Better Experience Bar" and its
-- own text-toggle/color-picker controls live on this same settings page
-- too (CreateSimpleBarPage's own "if key == 'expbar'" block), but remain
-- functionally independent (ACABDB.betterExpBarEnabled only governs
-- the text overlay, never this container's own movability).
ACAB.simpleBarPageConfigs["expbar"] = {
	title = "Experience Bar",
	hasEnable = true,
	getPosition = function() return ACABDB.expBarPosition end,
	setPosition = function(x, y) ACAB:SetExpBarPosition(x, y) end,
	getElementFrame = function() return getglobal(ACAB.EXP_BAR_FRAME_NAME) end,
	-- Extra headroom on Y max: users may want to hide the top sliver of
	-- this frame off-screen. In real screen pixels (GetPixelStep(),
	-- applied before the /scale division in GetSimpleElementCoordinateRange
	-- so the on-screen effect stays exactly this many pixels regardless of
	-- the frame's own current scale) - not a raw position-value amount,
	-- since a given change in x/y doesn't always move the element by a
	-- matching amount on screen.
	extraMaxYPixels = 2,
	reset = function()
		ACAB:ResetExpBarLayout()
	end,
	getEnabled = function() return ACABDB.expBarEnabled end,
	setEnabled = function(v) ACAB:SetExpBarEnabled(v) end,
	hasScale = true,
	getScale = function() return ACABDB.expBarScale end,
	setScale = function(v) ACAB:SetExpBarScale(v) end,
	hasHoverOnly = true,
	getHoverOnly = function() return ACABDB.expBarHoverOnly end,
	setHoverOnly = function(v) ACAB:SetExpBarHoverOnly(v) end,
	getHoverDuration = function() return ACABDB.expBarHoverDuration or 3 end,
	setHoverDuration = function(v) ACAB:SetExpBarHoverDuration(v) end,
}

-- Cast Bar: Position + Scale only, no Enable checkbox.
ACAB.simpleBarPageConfigs["castbar"] = {
	title = "Cast Bar",
	getPosition = function() return ACABDB.castBarPosition end,
	setPosition = function(x, y) ACAB:SetCastBarPosition(x, y) end,
	getElementFrame = function() return getglobal(ACAB.CAST_BAR_FRAME_NAME) end,
	reset = function()
		ACAB:ResetCastBarLayout()
	end,
	hasScale = true,
	getScale = function() return ACABDB.castBarScale end,
	setScale = function(v) ACAB:SetCastBarScale(v) end,
}

-- Tooltip: repositions only the fixed-position GameTooltip (quest log,
-- NPC hover, Micro Menu buttons, etc) - widget-relative tooltips are
-- untouched. See NativeElements.lua's HookGameTooltipDefaultAnchor.
ACAB.simpleBarPageConfigs["tooltip"] = {
	title = "Tooltip",
	hasEnable = true,
	getPosition = function() return ACABDB.tooltipPosition end,
	setPosition = function(x, y) ACAB:SetTooltipPosition(x, y) end,
	getElementFrame = function() return ACAB.tooltipFrame end,
	reset = function()
		ACAB:ResetTooltipLayout()
	end,
	getEnabled = function() return ACABDB.tooltipEnabled end,
	setEnabled = function(v) ACAB:SetTooltipEnabled(v) end,
	hasScale = true,
	getScale = function() return ACABDB.tooltipScale end,
	setScale = function(v) ACAB:SetTooltipScale(v) end,
}

ACAB.simpleBarPageConfigs["micromenu"] = {
	title = "Micro Menu",
	hasEnable = true,
	getPosition = function() return ACABDB.microMenuPosition end,
	setPosition = function(x, y) ACAB:SetMicroMenuPosition(x, y) end,
	getElementFrame = function() return ACAB.microMenuContainer end,
	extraMaxYPixels = 4,
	reset = function()
		-- Layout first: it writes scale directly to the DB without
		-- reapplying position, so applying position after settles it
		-- under the final scale instead of the stale pre-reset one.
		ACAB:ResetMicroMenuLayout()
		ACAB:ResetMicroMenuPosition()
	end,
	getEnabled = function() return ACABDB.microMenuEnabled end,
	setEnabled = function(v) ACAB:SetMicroMenuEnabled(v) end,
	hasSpacing = true,
	-- -10 floor, not the shared ACAB.SPACING_MIN (0) - see
	-- ACAB:SetMicroMenuSpacing's own comment (DefaultBars.lua) and
	-- CreateSimpleBarPage's spacingMin handling above.
	spacingMin = -10,
	-- Displayed slider value = actual stored spacing + 4 (native button art
	-- padding makes an actual spacing of 0 look like a visible gap) - see
	-- ACAB:SetMicroMenuSpacing's own comment (DefaultBars.lua).
	spacingUiOffset = 4,
	getSpacing = function() return ACABDB.microMenuSpacing end,
	setSpacing = function(v) ACAB:SetMicroMenuSpacing(v) end,
	hasScale = true,
	getScale = function() return ACABDB.microMenuScale end,
	setScale = function(v) ACAB:SetMicroMenuScale(v) end,
	hasGrid = true,
	-- GridSwatch_OnClick calls ACAB:SetMicroMenuLayout directly (barId ==
	-- "micromenu" branch), not through a config setter - only getGridLayout
	-- is needed here, to sync swatch selection on refresh.
	getGridLayout = function() return ACABDB.microMenuCols or 8, ACABDB.microMenuRows or 1 end,
	hasHoverOnly = true,
	getHoverOnly = function() return ACABDB.microMenuHoverOnly end,
	setHoverOnly = function(v) ACAB:SetMicroMenuHoverOnly(v) end,
	getHoverDuration = function() return ACABDB.microMenuHoverDuration or 3 end,
	setHoverDuration = function(v) ACAB:SetMicroMenuHoverDuration(v) end,
}

-- Shared right-click-to-settings entry point for any string-keyed simple
-- page - DefaultBars.lua's Stance Bar/Bag Bar/Micro Menu/Key Ring/Latency
-- Bar overlays all call this directly (EnsureContainerOverlay) rather than
-- needing their own OpenXSettings wrapper apiece, mirroring
-- OpenDefaultBarSettings' role for the numeric default bars (1-5) below.
function ACAB:OpenBarSettingsByKey(key)
	self:ShowSettingsFrame()
	self:ShowBarPage(key)
end

-------------------------------------------------------------------------
-- Refresh values shown by a bar page
-------------------------------------------------------------------------

function ACAB:RefreshBarSettingsPage(barId)
	if not ACAB.settingsFrame then
		return
	end

	if barId == ACAB.PET_BAR_ID and IsPetBarNativeMode() then
		self:RefreshSimpleBarPage(barId)
		return
	end

	if barId == ACAB.STANCE_BAR_ID and IsStanceBarNativeMode() then
		self:RefreshSimpleBarPage(barId)
		return
	end

	if ACAB.simpleBarPageConfigs[barId] and barId ~= ACAB.PET_BAR_ID and barId ~= ACAB.STANCE_BAR_ID then
		self:RefreshSimpleBarPage(barId)
		return
	end

	local page = ACAB.settingsFrame.pages[barId]

	if not page then
		return
	end

	local cfg, isDefault = ACAB:GetBarConfig(barId)

	if not cfg then
		return
	end

	self:RefreshHoverOnlyControls(page, cfg.hoverOnly, cfg.hoverDuration)

	-------------------------------------------------------------------------
	-- X/Y clamp range - recomputed from this bar's CURRENT
	-- buttonSize/buttonCount/cols/rows before syncing the value below, so
	-- a grid-preset pick or "Reset to Blizzard Default" (both of which
	-- route here) always re-clamps against the up to date range. Just
	-- SetMinMaxValues, not the full RefreshPositionSliderRange (which also
	-- re-clamps the CURRENT value) - SetValue(x) right below already
	-- re-syncs the value from cfg, the actual source of truth here.
	-------------------------------------------------------------------------

	-------------------------------------------------------------------------
	-- Suppress OnValueChanged re-application before touching the sliders at
	-- all - SetMinMaxValues below re-clamps the slider's CURRENT value if
	-- it's now outside the new range, which fires OnValueChanged same as a
	-- real drag would. Setting suppressApply first (not after) stops that
	-- clamp from writing a stray value into the saved config before
	-- SetValue(x)/SetValue(y) below applies the real one.
	-------------------------------------------------------------------------

	page.xSlider.suppressApply = true
	page.ySlider.suppressApply = true
	page.buttonSizeSlider.suppressApply = true
	page.xSlider.suppressSnap = true
	page.ySlider.suppressSnap = true

	do
		local minX, maxX, minY, maxY = ACAB:GetActionBarCoordinateRange(cfg)

		page.xSlider:SetMinMaxValues(minX, maxX)
		page.ySlider:SetMinMaxValues(minY, maxY)
	end

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
	-- refresh), that handler never runs and xValueText/yValueText (and
	-- xAppliedValue/yAppliedValue) would keep showing/holding stale
	-- values. Setting them explicitly here guarantees they're current on
	-- every refresh regardless of whether the value changed.
	page.xAppliedValue = x
	page.yAppliedValue = y

	page.xValueText:SetText(
		string.format("%.2f", x)
	)

	page.yValueText:SetText(
		string.format("%.2f", y)
	)

	-------------------------------------------------------------------------
	-- Button size
	-------------------------------------------------------------------------

	local buttonSize = cfg.buttonSize or ACAB.BUTTON_SIZE

	if buttonSize < ACAB.BUTTON_SIZE_MIN then
		buttonSize = ACAB.BUTTON_SIZE_MIN
	end

	if buttonSize > ACAB.BUTTON_SIZE_MAX then
		buttonSize = ACAB.BUTTON_SIZE_MAX
	end

	page.buttonSizeSlider:SetValue(
		buttonSize
	)

	-------------------------------------------------------------------------
	-- Spacing (default bars only)
	-------------------------------------------------------------------------

	if page.spacingSlider then
		local offset = ACAB:GetSpacingDisplayOffset()

		-- Recomputed every refresh - the offset (and therefore the
		-- displayed range) can change live when the border-style toggle
		-- flips while this page is already built.
		page.spacingSlider:SetMinMaxValues(0, ACAB.SPACING_MAX - offset)

		if page.spacingSliderLow then
			page.spacingSliderLow:SetText("0")
		end

		if page.spacingSliderHigh then
			page.spacingSliderHigh:SetText(tostring(ACAB.SPACING_MAX - offset))
		end

		local spacing = cfg.spacing or 0

		if spacing < ACAB.SPACING_MIN then
			spacing = ACAB.SPACING_MIN
		end

		if spacing > ACAB.SPACING_MAX then
			spacing = ACAB.SPACING_MAX
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
	page.xSlider.suppressSnap = nil
	page.ySlider.suppressSnap = nil

	if page.spacingSlider then
		page.spacingSlider.suppressApply = nil
	end

	-------------------------------------------------------------------------
	-- Grid preset selection
	--
	-- Stance Bar only: its preset list is live (GetStanceBarGridOptions),
	-- so the swatch row itself is torn down and rebuilt here every time the
	-- page is shown - see RebuildGridSwatches' own comment.
	-------------------------------------------------------------------------

	if barId == ACAB.STANCE_BAR_ID and page.gridSwatchY then
		RebuildGridSwatches(page, barId, page.gridSwatchY)
	end

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
	-- Bars 2-5's real Blizzard buttons are permanently hidden regardless
	-- of the native SHOW_MULTI_ACTIONBAR_* globals, so cfg.enabled (our
	-- own saved flag) is the sole source of truth. Extra Bars follow the
	-- same rule - see Bar.lua's SetExtraBarEnabled.
	-------------------------------------------------------------------------

	if page.enableCheckbox and ((isDefault and barId ~= 1) or ACAB:IsExtraBarId(barId)) then
		page.enableCheckbox:SetChecked(
			cfg.enabled == true
		)
	end

	-------------------------------------------------------------------------
	-- Use Vanilla Pet Bar / Condense empty Button Space (Pet Bar page only)
	--
	-- Both lock (ApplyProfileLockGating below) and their DISPLAYED
	-- checked-state collapses to the vanilla-forced value while locked -
	-- same collapse idiom as modernBorderStyleCheckbox (Core.lua's
	-- IsVanillaBorderStyle).
	-------------------------------------------------------------------------

	if page.useVanillaPetBarCheckbox then
		local petLocked = ACAB:IsDefaultProfileActive() or ACABDB.useDefaultLayout == true

		page.useVanillaPetBarCheckbox:SetChecked(petLocked or cfg.useNativePetBar == true)
	end

	if page.condenseEmptyPetSlotsCheckbox then
		local petLocked = ACAB:IsDefaultProfileActive() or ACABDB.useDefaultLayout == true

		page.condenseEmptyPetSlotsCheckbox:SetChecked((not petLocked) and cfg.condenseEmptyPetSlots == true)
	end

	-------------------------------------------------------------------------
	-- Use Vanilla Stance Bar (Stance Bar page only) - same lock/collapse
	-- idiom as Use Vanilla Pet Bar above.
	-------------------------------------------------------------------------

	if page.useVanillaStanceBarCheckbox then
		local stanceLocked = ACAB:IsDefaultProfileActive() or ACABDB.useDefaultLayout == true

		page.useVanillaStanceBarCheckbox:SetChecked(stanceLocked or cfg.useNativeStanceBar == true)
	end

	if page.animateAutoCastGlowCheckbox then
		page.animateAutoCastGlowCheckbox:SetChecked(cfg.animateAutoCastGlow == true)
	end

	-------------------------------------------------------------------------
	-- Page Indicator Scale (Main Bar only)
	-------------------------------------------------------------------------

	if barId == 1 and page.pageIndicatorSlider then
		local scale = ACABDB.mainBarPageIndicatorScale or 1

		page.pageIndicatorSlider.suppressApply = true
		page.pageIndicatorSlider:SetValue(scale)
		page.pageIndicatorValueText:SetText(string.format("%.1f", scale))
		page.pageIndicatorSlider.suppressApply = nil

		ACAB:RefreshMainBarPageIndicatorControlsVisibility()

		-- Stance/Page Bar Assignment rows rebuild every time bar 1's page
		-- is (re)shown, same as the Page Indicator controls just above, so
		-- the rows always reflect the current stance count/pagination-and-
		-- stance-swap toggle state.
		ACAB:RebuildMainBarAssignmentRows()
	end

	-------------------------------------------------------------------------
	-- Default-layout lock, numbered default bars (1-5) - while "Use
	-- Default Blizzard Layout" is on, every one of these bars' controls
	-- locks except enable/disable, exactly like the Default-profile lock.
	-- Both share the same combined lock and control list
	-- (ACAB:ApplyProfileLockGating below).
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
	ACAB:RefreshBarPageGlobalOverrideGating(page)

	-- Bar 5 can only be enabled while bar 4 is (matches native's own
	-- dependency, DefaultBars.lua's SetDefaultBarEnabled) unless the
	-- General tab's bypass option is on. Runs AFTER ApplyProfileLockGating
	-- (not alongside the SetChecked block above) - that call unconditionally
	-- UNLOCKS enableCheckbox whenever the Default-profile/layout lock
	-- itself isn't active (its own exemption for numbered default bars),
	-- which was clobbering this lock when placed earlier in the function.
	if page.enableCheckbox and barId == 5 then
		local bar4Cfg = ACABDB.defaultBars[4]
		local allowed = ACABDB.bypassRightActionBar2Dependency == true
			or (bar4Cfg and bar4Cfg.enabled == true)

		ACAB:LockControl(page.enableCheckbox, not allowed)
	end
end

-- Locks (dims, EnableMouse(false)) a full bar page's own spacing/
-- buttonSize sliders while the corresponding global override (General
-- tab) is enabled AND this bar hasn't been unlocked from it via its own
-- lock icon (cfg.spacingUnlocked/buttonSizeUnlocked, toggled by
-- page.spacingLockButton/buttonSizeLockButton's onClick in
-- GetOrCreateBarPage) - only ever called from RefreshBarSettingsPage's
-- non-simple-bar path above, so simple bar pages (Bag Bar/Micro Menu/
-- etc.) are naturally never affected. Pet Bar/Stance Bar's styled-mode
-- page goes through this same path and is treated identically to every
-- other bar - see Bar.lua's ApplyGlobalSpacing/ApplyGlobalButtonSize.
function ACAB:RefreshBarPageGlobalOverrideGating(page)
	if not page then
		return
	end

	local cfg = ACAB:GetBarConfig(page.barId)

	-- Must also respect the Default-profile/Default-layout lock
	-- (ACAB:ApplyProfileLockGating, called just before this in
	-- RefreshBarSettingsPage/RefreshSimpleBarPage) - without this, this
	-- function unconditionally RE-ENABLES the slider whenever the global
	-- override checkbox happens to be off, blindly overwriting whatever
	-- that other lock had just set. While alsoLocked, the lock icons hide
	-- too - clicking them couldn't free anything from a lock that broad.
	local alsoLocked = self:IsDefaultProfileActive()
		or (page.isDefault and ACABDB.useDefaultLayout == true)

	if page.spacingSlider then
		local globalOn = ACABDB.globalSpacingEnabled == true
		local unlocked = cfg and cfg.spacingUnlocked == true
		local locked = alsoLocked or (globalOn and not unlocked)

		page.spacingSlider:EnableMouse(not locked)
		page.spacingSlider:SetAlpha(locked and 0.5 or 1)

		if page.spacingLockButton then
			page.spacingLockButton:SetShown(globalOn and not alsoLocked)
			page.spacingLockButton:SetLocked(not unlocked)
		end
	end

	if page.buttonSizeSlider then
		local globalOn = ACABDB.globalButtonSizeEnabled == true
		local unlocked = cfg and cfg.buttonSizeUnlocked == true
		local locked = alsoLocked or (globalOn and not unlocked)

		page.buttonSizeSlider:EnableMouse(not locked)
		page.buttonSizeSlider:SetAlpha(locked and 0.5 or 1)

		if page.buttonSizeLockButton then
			page.buttonSizeLockButton:SetShown(globalOn and not alsoLocked)
			page.buttonSizeLockButton:SetLocked(not unlocked)
		end
	end
end

-- Live-refreshes the spacing/buttonSize lock on every currently cached
-- full bar page (1-9) without a full RefreshBarSettingsPage resync -
-- called from the two new global-override checkboxes/sliders (General
-- tab) so already-open bar pages lock/unlock immediately. Simple bar
-- pages (string keys in ACAB.settingsFrame.pages) are skipped - out of scope
-- for the global overrides.
function ACAB:RefreshAllBarPagesGlobalOverrideGating()
	if not ACAB.settingsFrame then
		return
	end

	local id
	local page

	for id, page in pairs(ACAB.settingsFrame.pages) do
		if type(id) == "number" and ACAB.bars and ACAB.bars[id] then
			self:RefreshBarPageGlobalOverrideGating(page)
		end
	end
end

-- Shows/hides the Main Bar page's Page Indicator Scale slider per
-- ACABDB.mainBarPaginationEnabled - called both from
-- RefreshBarSettingsPage(1) above and from the General panel's own
-- pagination checkbox handler (below), so toggling that checkbox
-- immediately shows/hides this slider even while bar 1's page is already
-- open (mirrors RefreshDefaultLayoutGatingOnAllPages' own "live-refresh an
-- already-open page" reasoning).
function ACAB:RefreshMainBarPageIndicatorControlsVisibility()
	if not ACAB.settingsFrame then
		return
	end

	local page = ACAB.settingsFrame.pages[1]

	if not page or not page.pageIndicatorSlider then
		return
	end

	local show = ACABDB.mainBarPaginationEnabled ~= false

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
-- Show a specific bar page
-------------------------------------------------------------------------

function ACAB:ShowBarPage(barId)
	if not ACAB.settingsFrame then
		ACAB:CreateSettingsFrame()
	end

	-- Always switches back to the "Bars" view - every caller of this
	-- function (bar list clicks, OpenBarSettings, OpenDefaultBarSettings,
	-- ShowBarsView itself) wants a bar page on
	-- screen, so this is the one place that needs to own un-hiding
	-- listPanel/contentPanel and hiding the General panel, rather than
	-- every caller remembering to do it.
	ACAB.settingsFrame.currentView = "bars"
	ACAB:RefreshActiveTabHighlight()
	ACAB.settingsFrame.listPanel:Show()
	ACAB.settingsFrame.contentScrollFrame:Show()
	ACAB.settingsFrame.contentPanel:Show()

	if ACAB.settingsFrame.generalScrollFrame then
		ACAB.settingsFrame.generalScrollFrame:Hide()
	end

	if ACAB.settingsFrame.generalPanel then
		ACAB.settingsFrame.generalPanel:Hide()
	end

	if ACAB.settingsFrame.profilesScrollFrame then
		ACAB.settingsFrame.profilesScrollFrame:Hide()
	end

	if ACAB.settingsFrame.profilesPanel then
		ACAB.settingsFrame.profilesPanel:Hide()
	end

	if ACAB.settingsFrame.editModeScrollFrame then
		ACAB.settingsFrame.editModeScrollFrame:Hide()
	end

	if ACAB.settingsFrame.editModePanel then
		ACAB.settingsFrame.editModePanel:Hide()
	end

	local id
	local page

	for id, page in pairs(ACAB.settingsFrame.pages) do
		page:Hide()
	end

	local target = self:GetOrCreateBarPage(barId)

	self:RefreshBarSettingsPage(barId)

	target:Show()

	ACAB.settingsFrame.activeBarId = barId

	-- Keep the sidebar row's persistent gold highlight in sync with
	-- whichever bar page is actually showing (ACABListRowMixin:SetSelected).
	-- Both lookups are nil-guarded: barButtonsByBarId may not have an
	-- entry yet (list not built this session) or ever (e.g. bagbar/
	-- micromenu/latencybar/expbar rows are conditionally absent per
	-- RefreshBarList's own exists checks).
	if ACAB.settingsFrame.selectedBarId ~= nil and ACAB.settingsFrame.selectedBarId ~= barId then
		local oldRow = ACAB.settingsFrame.barButtonsByBarId[ACAB.settingsFrame.selectedBarId]

		if oldRow then
			oldRow:SetSelected(false)
		end
	end

	local newRow = ACAB.settingsFrame.barButtonsByBarId[barId]

	if newRow then
		newRow:SetSelected(true)
	end

	ACAB.settingsFrame.selectedBarId = barId

	-- Resizes the window to fit this page's actual controls now that it
	-- (and the always-visible bar list) are both on-screen and
	-- positioned - GetTop()/GetBottom() only return real values for
	-- currently-shown frames, so this has to run after target:Show()
	-- above, not before it. Deferred one frame (DeferFit) so its own
	-- candidates' positions have settled before anything measures them.
	ACAB:DeferFit(function() ACAB:FitSettingsWindowToBarPage(barId) end)
end

-------------------------------------------------------------------------
-- General tab panel (ACABDB.useDefaultLayout)
--
-- Built lazily on first use, exactly like GetOrCreateBarPage - anchored
-- to span the same combined area listPanel + contentPanel occupy
-- together, since the bar list has no meaning in this view.
-------------------------------------------------------------------------

-------------------------------------------------------------------------
-- Stance / Page Bar Assignment cyclic value
--
-- 0 is the "Unassigned" sentinel - NOT a real table hole (a raw
-- `{nil, 6, 7, 8, 9}` constructor would put a nil at index 1, and
-- table.getn/# have undefined behavior on a table with a hole at the
-- start, per the Lua 5.0 manual) - translated to/from a real nil only at
-- the ACABDB read/write boundary in CreateExtraBarAssignmentRow's
-- own getFn/setFn callers below.
-------------------------------------------------------------------------

local EXTRA_BAR_ASSIGNMENT_CYCLE = { 0, 6, 7, 8, 9 }

local function ExtraBarAssignmentLabel(assignedId)
	if not assignedId or assignedId == 0 then
		return "Unassigned"
	end

	return "Extra Bar " .. tostring(assignedId - ACAB.EXTRA_BAR_ID_START + 1)
end

-- Same 5 choices (Unassigned + Extra Bar 1-4) for every assignment row, so
-- the option list itself only ever needs building once. { value = 0 }
-- represents EXTRA_BAR_ASSIGNMENT_CYCLE's own "Unassigned" sentinel -
-- translated to/from a real nil only at RefreshValue/onSelect's own
-- ACABDB read/write boundary below.
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

-- Builds one Extra Bar assignment row (native dropdown via
-- ACAB:CreateInlineDropdown). dropdownName must be a unique, stable global
-- frame name keyed off the row's stable identity (stance index / "page
-- bar"), so repeated rebuilds reuse the same frame. getFn/setFn use a raw
-- ACABDB value (Extra Bar id 6-9, or nil) - never the 0 sentinel,
-- which is internal to this function.
local function CreateExtraBarAssignmentRow(parent, labelText, getFn, setFn, dropdownName)
	local row = CreateFrame("Frame", nil, parent)

	row:SetWidth(500)
	row:SetHeight(32)

	local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

	label:SetPoint("LEFT", row, "LEFT", 0, 0)
	label:SetWidth(180)
	label:SetJustifyH("LEFT")
	label:SetText(labelText)

	local dropdown = ACAB:CreateInlineDropdown(row, 140, dropdownName)

	dropdown:SetPoint("LEFT", label, "RIGHT", -8, -2)
	dropdown:SetOptions(EXTRA_BAR_ASSIGNMENT_DROPDOWN_OPTIONS)

	local function RefreshValue()
		local current = getFn() or 0

		dropdown:SetSelected(current, ExtraBarAssignmentLabel(current ~= 0 and current or nil))
	end

	dropdown.onSelect = function(value)
		setFn(value ~= 0 and value or nil)
		RefreshValue()
	end

	RefreshValue()

	-- Exposed so ApplyProfileLockGating can lock this dropdown too.
	row.dropdown = dropdown

	return row
end

-- Rebuilds bar 1's Stance/Page Bar Assignment rows from scratch: one row
-- per currently-active stance (if Stance/Form/Stealth Swapping is
-- enabled) plus one Page Bar row (if pagination is enabled). No-op if bar
-- 1's page hasn't been built yet. Called from RefreshBarSettingsPage(1),
-- the pagination/stance-swap checkboxes' OnClick, and DefaultBars.lua's
-- UPDATE_SHAPESHIFT_FORMS handler.
function ACAB:RebuildMainBarAssignmentRows()
	local page = ACAB.settingsFrame and ACAB.settingsFrame.pages[1]

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

	-- CreateFrame with a reused name creates a NEW frame that merely
	-- shares the name, not the same underlying object - two dropdowns
	-- sharing a name corrupt each other's native UIDropDownMenu_*
	-- sub-piece lookups (getglobal(self:GetName() .. "...")). Suffixing
	-- every dropdown name with a monotonic per-rebuild generation counter
	-- must stay in place or the fragmented-skin/blank-label bug returns.
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

	-- Gated on mainBarStanceSwapEnabled, matching the Page Bar row's own
	-- mainBarPaginationEnabled gate below.
	local stanceSwapOn = ACABDB.mainBarStanceSwapEnabled ~= false
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
					return ACABDB.mainBarStanceBarAssignment
						and ACABDB.mainBarStanceBarAssignment[s]
				end,
				function(value)
					if not ACABDB.mainBarStanceBarAssignment then
						ACABDB.mainBarStanceBarAssignment = {}
					end

					ACABDB.mainBarStanceBarAssignment[s] = value

					ACAB:RefreshMainBarSlots()
				end,
				-- Named by stance index plus this rebuild's own generation
				-- suffix (see the frame-identity note above), so no two
				-- rebuilds ever share a dropdown name.
				"ACABMainBarStanceAssignmentDropdown" .. tostring(s) .. generationSuffix
			)

			row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y)

			rowIndex = rowIndex + 1
			page.assignmentRows[rowIndex] = row

			y = y - 34
		end
	end

	if ACABDB.mainBarPaginationEnabled ~= false then
		local row = CreateExtraBarAssignmentRow(
			container,
			"Page 2 Content Source:",
			function()
				return ACABDB.mainBarPageBarAssignment
			end,
			function(value)
				ACABDB.mainBarPageBarAssignment = value

				ACAB:RefreshMainBarSlots()
			end,
			"ACABMainBarPageBarAssignmentDropdown" .. generationSuffix
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

-- Applies a "Use Default Blizzard Layout" checkbox change: persists the
-- value, re-gates every affected page, and (only when switching ON from
-- OFF) runs the full reset-to-Blizzard-default cascade. Split out from the
-- checkbox's OnClick so the confirm dialog below can defer this call until
-- the user accepts the reset warning.
function ACAB:ApplyUseDefaultLayoutChange(checked)
	local wasDefault = ACABDB.useDefaultLayout == true

	ACABDB.useDefaultLayout = checked

	-- Re-gate any default-bar page already built/cached so it
	-- reflects the new state immediately if it happens to be
	-- visible (or gets shown next) without needing a reload.
	ACAB:RefreshDefaultLayoutGatingOnAllPages()

	-- Idempotent when the saved cfg values themselves haven't
	-- changed (only interactivity changed) - safe/cheap to call
	-- unconditionally so bars are guaranteed visually in sync
	-- rather than only catching up on next login.
	if ACAB.ApplyAllDefaultBars then
		ACAB:ApplyAllDefaultBars()
	end

	-- useDefaultLayout changes whether dragging is currently
	-- possible (ACAB:CanDragDefaultLayout()) even when edit mode's
	-- own state hasn't changed, so the default-bar/stance-bar
	-- overlays need their own refresh here too, not just from
	-- ApplyEditModeVisual's call sites.
	if ACAB.ApplyDefaultLayoutEditVisual then
		ACAB:ApplyDefaultLayoutEditVisual()
	end

	-- Stance Bar is an unconditionally-positioned ACAB-owned
	-- container exactly like Bag Bar/Micro Menu (see
	-- ACAB:CreateStanceBarContainer's PLAYER_LOGIN placement,
	-- Core.lua), so switching OFF doesn't need to capture/apply
	-- anything (its position is always live), and switching back
	-- ON is handled by the same reset cascade below as Bag Bar/
	-- Micro Menu/Latency Bar/Key Ring.
	if (not wasDefault) and checked then
		-------------------------------------------------------------
		-- Full reset-to-Blizzard-default cascade: ApplyAllDefaultBars/
		-- ApplyDefaultLayoutEditVisual above only re-apply shape from
		-- whatever cfg currently holds, they do not reset cfg back to
		-- its native values - ResetDefaultBarLayout does that for
		-- every default-bar-family id (1-5, Pet Bar), and each
		-- single-native-frame element below gets its own reset call.
		-------------------------------------------------------------

		local i

		for i = 1, table.getn(ACAB.DEFAULT_BAR_IDS) do
			ACAB:ResetDefaultBarLayout(ACAB.DEFAULT_BAR_IDS[i])
		end

		-- Bars 2-5's enabled state now mirrors the real native "Show ...
		-- Action Bar" checkboxes (session-live only, per
		-- docs/01-Environment-Capability-Analysis.md §5m/§6) instead of
		-- whatever ACAB had stored - same reconciliation
		-- MultiActionBar_Update's own hook already performs reactively.
		if ACAB.ReconcileDefaultBarEnabledFromNative then
			ACAB:ReconcileDefaultBarEnabledFromNative()
		end

		-- Extra Bars (6-9) are ACAB-only content with no Blizzard-
		-- default equivalent - hidden outright while the native layout
		-- owns bars 1-5.
		local extraId

		for extraId = ACAB.EXTRA_BAR_ID_START, ACAB.EXTRA_BAR_ID_START + ACAB.EXTRA_BAR_COUNT - 1 do
			ACAB:SetExtraBarEnabled(extraId, false)

			if ACAB.settingsFrame and ACAB.settingsFrame.pages[extraId] then
				ACAB:RefreshBarSettingsPage(extraId)
			end
		end

		ACAB:RefreshBarList()

		if ACAB.ResetBagBarPosition then
			ACAB:ResetBagBarPosition()
		end

		if ACAB.ResetBagBarLayout then
			ACAB:ResetBagBarLayout()
		end

		if ACAB.ResetMicroMenuPosition then
			ACAB:ResetMicroMenuPosition()
		end

		if ACAB.ResetMicroMenuLayout then
			ACAB:ResetMicroMenuLayout()
		end

		if ACAB.ResetStanceBarPosition then
			ACAB:ResetStanceBarPosition()
		end

		if ACAB.ResetStanceBarLayout then
			ACAB:ResetStanceBarLayout()
		end

		if ACAB.ResetLatencyBarLayout then
			ACAB:ResetLatencyBarLayout()
		end

		-- Cast Bar: same single-native-frame reset treatment as Latency
		-- Bar above - also resets castBarUsesDefaultPosition to true
		-- (ResetCastBarLayout itself), re-enabling its own dynamic stacking.
		if ACAB.ResetCastBarLayout then
			ACAB:ResetCastBarLayout()
		end

		if ACAB.ResetKeyRingPosition then
			ACAB:ResetKeyRingPosition()
		end

		-- Key Ring ships visible on native vanilla - re-enable it
		-- regardless of whatever the user had it set to.
		if ACAB.SetKeyRingEnabled then
			ACAB:SetKeyRingEnabled(true)
		end

		-- Native layout always shows Blizzard's own bar art.
		ACABDB.disableBlizzardArt = false

		if ACAB.ApplyBlizzardArtVisibility then
			ACAB:ApplyBlizzardArtVisibility()
		end

		-- Main Bar paging/stance-swap ship on by default on native vanilla.
		if ACAB.SetMainBarPaginationEnabled then
			ACAB:SetMainBarPaginationEnabled(true)
		end

		if ACAB.SetMainBarStanceSwapEnabled then
			ACAB:SetMainBarStanceSwapEnabled(true)
		end

		-- Experience Bar: same reset treatment as every other
		-- single-native-frame element above.
		if ACAB.ResetExpBarLayout then
			ACAB:ResetExpBarLayout()
		end

		-- See ACAB:ResetPageIndicatorLayout's own comment (DefaultBars.lua).
		if ACAB.ResetPageIndicatorLayout then
			ACAB:ResetPageIndicatorLayout()
		end

		-- Pet Bar native mode only - ResetDefaultBarLayout above (the
		-- custom-styled grid mode's own reset) has nothing to act on
		-- while self.bars[PET_BAR_ID] doesn't exist. No-ops safely in
		-- custom mode (self.petBarNativeContainer is nil then).
		if ACAB.ResetPetBarNativeLayout then
			ACAB:ResetPetBarNativeLayout()
		end

		-- Persists the enforced-effective values (ACAB:IsPetBarNativeModeEffective/
		-- ShouldCondensePetBarSlots) into the stored cfg too, so they
		-- don't silently diverge from what's actually applied.
		do
			local petCfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]

			if petCfg then
				petCfg.useNativePetBar = true
				petCfg.condenseEmptyPetSlots = false
			end
		end

		-- Same treatment for the Stance Bar's own styled-mode-only
		-- toggle - ACAB:IsStanceBarNativeModeEffective() already
		-- forces this at runtime while useDefaultLayout is on, this
		-- just persists it into the stored cfg too so it doesn't
		-- silently diverge from what's actually applied.
		do
			local stanceCfg = ACABDB.defaultBars[ACAB.STANCE_BAR_ID]

			if stanceCfg then
				stanceCfg.useNativeStanceBar = true
			end
		end

		-- "Use Modern Button Style"/Global Spacing/Global ButtonSize only
		-- take visual effect while useDefaultLayout is off
		-- (ApplyGlobalSpacing/ApplyGlobalButtonSize/IsVanillaBorderStyle
		-- all no-op/override while it's on) - clear the flags themselves
		-- too, not just leave them cosmetically locked, so they don't
		-- silently reapply the instant the user switches back off.
		ACABDB.modernBorderStyle = false
		ACABDB.globalSpacingEnabled = false
		ACABDB.globalButtonSizeEnabled = false

		-- Re-syncs every already-built default/simple bar page's
		-- sliders/checkboxes from the values the resets above just
		-- wrote - the earlier RefreshDefaultLayoutGatingOnAllPages
		-- call in this handler ran BEFORE these resets, so it only
		-- caught up gating/alpha, not the underlying values.
		ACAB:RefreshDefaultLayoutGatingOnAllPages()
	end

	-- Runs LAST, after any reset cascade above, so bars 1-5 are
	-- already at their true native values by the time this reads
	-- them - re-evaluates ACAB:IsVanillaBorderStyle() live: turning
	-- this ON forces every bar back to vanilla styling (skipping
	-- bars 1-5, already handled by the reset cascade above -
	-- see ApplyGlobalButtonStyle's own skipDefaultBars comment);
	-- turning it OFF re-applies whatever modernBorderStyle is
	-- currently stored instead of leaving bars showing the
	-- forced-vanilla look until next login.
	ACAB:ApplyGlobalButtonStyle()

	-- The global spacing/buttonSize overrides both no-op while
	-- useDefaultLayout is on (Bar.lua) - re-running them here
	-- means turning it back OFF immediately re-applies a
	-- previously-locked-out override instead of waiting for the
	-- next slider move.
	ACAB:ApplyGlobalSpacing()
	ACAB:ApplyGlobalButtonSize()

	-- Updates the new "Use Modern Button Style" checkbox's own
	-- checked/grey-out state immediately (RefreshGeneralPanel
	-- isn't otherwise called from this handler) so it reflects
	-- the lock the moment useDefaultLayout changes, without
	-- needing to leave and reopen the General tab.
	ACAB:RefreshGeneralPanel()

	ACAB:RefreshAllBarPagesGlobalOverrideGating()

	-- Stance Bar position must be re-verified dead last, after every other
	-- reset/reapply above (bar 2's enabled state included) - its Y is
	-- computed relative to bar 2's own final on/off state
	-- (ACAB:GetStanceBarBaselineY), and ResetStanceBarPosition above only
	-- restores the stale point-in-time snapshot captured at first seed,
	-- not a fresh recompute. Without this, the Stance Bar can visually
	-- land overlapping/behind Bar 1 until something else (e.g. manually
	-- toggling bar 2 off then on) happens to trigger a reflow.
	if (not wasDefault) and checked and ACAB.ReflowStanceBarForBar2Toggle then
		local bar2Cfg = ACABDB.defaultBars and ACABDB.defaultBars[2]

		ACAB:ReflowStanceBarForBar2Toggle(bar2Cfg and bar2Cfg.enabled)
	end
end
-------------------------------------------------------------------------
-- Bar list row creation
--
-- One row layout shared by default bars (1-5) and custom bars (6+) -
-- only the presence of the inline enable-checkbox (default bars 2-5)
-- and the small kind indicator text differ.
-------------------------------------------------------------------------

local function CreateBarListRow(barId, isDefault, cfg, generationSuffix)
	local row = ACAB:CreateListRow(ACAB.settingsFrame.listContent, nil)

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
	-- this.barId per the engine this-convention) - ACABListRowMixin's
	-- onClick is instead invoked as onClick(row), an explicit arg.
	row:SetOnClick(function(clickedRow)
		ACAB:ShowBarPage(clickedRow.barId)
	end)

	-- Bars 2-5 (default only) AND the Bag Bar/Micro Menu (the only two of
	-- the three "simple" string-keyed pages that can be meaningfully
	-- disabled, unlike the Stance Bar) get an inline enable/disable
	-- checkbox - live, applies on click immediately. One shared
	-- checkbox-creation code path handles both sources of an "enabled"
	-- flag.
	local simpleConfig = ACAB.simpleBarPageConfigs[barId]

	local wantsCheckbox = false
	local checkedState = false
	local onToggle = nil

	-- Stance Bar: ACABDB.stanceBarEnabled (native) and
	-- ACABDB.defaultBars[STANCE_BAR_ID].enabled (styled) are two
	-- deliberately separate flags (see Core.lua's ACAB.STANCE_BAR_ID header
	-- comment) - checked BEFORE the generic numeric-default-bar branch
	-- below so the list row's one checkbox always reflects/drives whichever
	-- flag is actually active, mirroring the full/simple settings page
	-- dispatch (IsStanceBarNativeMode()).
	if barId == ACAB.STANCE_BAR_ID and IsStanceBarNativeMode() then
		local stanceConfig = ACAB.simpleBarPageConfigs[ACAB.STANCE_BAR_ID]

		wantsCheckbox = true
		checkedState = stanceConfig.getEnabled and stanceConfig.getEnabled() ~= false
		onToggle = function(checked)
			stanceConfig.setEnabled(checked)
		end
	elseif isDefault and type(barId) == "number" and barId ~= 1 then
		wantsCheckbox = true
		checkedState = cfg and cfg.enabled == true
		onToggle = function(checked)
			ACAB:SetDefaultBarEnabled(barId, checked)
		end
	elseif simpleConfig and simpleConfig.hasEnable then
		wantsCheckbox = true
		checkedState = simpleConfig.getEnabled and simpleConfig.getEnabled() ~= false
		onToggle = function(checked)
			simpleConfig.setEnabled(checked)
		end
	elseif not isDefault and type(barId) == "number" and ACAB:IsExtraBarId(barId) then
		-- Extra Bars (ids 6-9) get the same inline list checkbox default
		-- bars 2-5 get above.
		wantsCheckbox = true
		checkedState = cfg and cfg.enabled == true
		onToggle = function(checked)
			ACAB:SetExtraBarEnabled(barId, checked)
		end
	end

	if wantsCheckbox then
		local checkbox = CreateFrame(
			"CheckButton",
			-- Suffixed with this rebuild's own generation counter (see
			-- RefreshBarList) so a stable, finite barId never causes two
			-- rebuilds to create a same-named frame - same mitigation
			-- RebuildMainBarAssignmentRows already establishes for its own
			-- dynamically created dropdowns.
			"ACABBarList" .. tostring(barId) .. "Checkbox" .. generationSuffix,
			ACAB.settingsFrame.listContent,
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
		-- highlight (ACABListRowMixin:OnRowEnter/OnRowLeave) - the highlight
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
				ACAB:RefreshBarSettingsPage(this.barId)
			end
		)

		row.checkbox = checkbox

		-- Only exempt for numbered default bars (2-5 - bar 1 never gets a
		-- sidebar checkbox at all) from BOTH the Default-profile AND
		-- Default-layout locks, matching page.enableCheckbox's own
		-- exemption on those pages (ACAB:ApplyProfileLockGating). Bag Bar/
		-- Micro Menu and Extra Bars (6-9) get NO exemption - their
		-- checkbox locks exactly like every other control on their page,
		-- under the Default-profile lock only (layout lock never applies
		-- to them).
		local isNumberedDefaultBar = isDefault and type(barId) == "number" and barId ~= 1

		if not isNumberedDefaultBar then
			ACAB:LockControl(checkbox, ACAB:IsDefaultProfileActive())
		end

		-- Bar 5's sidebar checkbox mirrors its page's own enableCheckbox
		-- lock (see RefreshBarSettingsPage) - only enabled while bar 4 is,
		-- unless the bypass option is on.
		if isNumberedDefaultBar and barId == 5 then
			local bar4Cfg = ACABDB.defaultBars[4]
			local allowed = ACABDB.bypassRightActionBar2Dependency == true
				or (bar4Cfg and bar4Cfg.enabled == true)

			ACAB:LockControl(checkbox, not allowed)
		end
	end

	-- Grey out (ACABListRowMixin:SetDisabled - also blocks the row's own
	-- onClick, but bar 5's page is still reachable via its own checkbox's
	-- lock/the bypass option) the row itself too, so its locked state is
	-- visible at a glance in the list, not just on the small checkbox
	-- beside it.
	if isDefault and barId == 5 then
		local bar4Cfg = ACABDB.defaultBars[4]
		local allowed = ACABDB.bypassRightActionBar2Dependency == true
			or (bar4Cfg and bar4Cfg.enabled == true)

		row:SetDisabled(not allowed)
	end

	return row
end

-------------------------------------------------------------------------
-- Refresh left bar list
--
-- Unified list: Bar 1 -> Bar 5, a divider, then the 4 permanent Extra
-- Bars (6-9) - no "+ Add New Bar" row, since capacity is fixed and every
-- possible bar id already always exists.
-------------------------------------------------------------------------

function ACAB:RefreshBarList()
	if not ACAB.settingsFrame then
		ACAB:CreateSettingsFrame()
	end

	local i

	for i = 1, table.getn(ACAB.settingsFrame.barButtons) do
		local widget = ACAB.settingsFrame.barButtons[i]

		widget:Hide()

		if widget.checkbox then
			widget.checkbox:Hide()
		end
	end

	ACAB.settingsFrame.barButtons = {}
	ACAB.settingsFrame.barButtonsByBarId = {}

	-- Same per-rebuild generation-counter mitigation RebuildMainBarAssignmentRows
	-- uses for its own dynamically created dropdowns - see CreateBarListRow's
	-- checkbox naming.
	ACAB.settingsFrame.barListRebuildGeneration = (ACAB.settingsFrame.barListRebuildGeneration or 0) + 1
	local generationSuffix = "_" .. tostring(ACAB.settingsFrame.barListRebuildGeneration)

	local yOffset = -24
	local rowIndex = 0

	-------------------------------------------------------------------------
	-- Default bars 1-5, plus the Pet Bar (same family, ACAB.DEFAULT_BAR_IDS)
	-------------------------------------------------------------------------

	local dbi

	for dbi = 1, table.getn(ACAB.DEFAULT_BAR_IDS) do
		local id = ACAB.DEFAULT_BAR_IDS[dbi]
		local cfg = ACABDB.defaultBars[id]

		if cfg then
			-- Bars 2-5/Pet Bar's real Blizzard buttons are permanently hidden
			-- regardless of the native SHOW_MULTI_ACTIONBAR_* globals, so
			-- cfg.enabled is read directly as the sole source of truth.
			local row = CreateBarListRow(id, true, cfg, generationSuffix)

			row:SetPoint(
				"TOPLEFT",
				ACAB.settingsFrame.listContent,
				"TOPLEFT",
				0,
				yOffset
			)

			rowIndex = rowIndex + 1
			ACAB.settingsFrame.barButtons[rowIndex] = row
			ACAB.settingsFrame.barButtonsByBarId[id] = row

			yOffset = yOffset - (LIST_ROW_HEIGHT + LIST_ROW_GAP)
		end
	end

	-------------------------------------------------------------------------
	-- Bag Bar / Micro Menu - distinct string keys, not numbered default/
	-- custom bars, grouped with the default bars above the divider since
	-- they're equally native-backed. Always shown; drag/position-slider
	-- interactivity is gated separately by useDefaultLayout
	-- (ApplyDefaultLayoutGating), same as default bars 1-5. The Stance Bar
	-- (like the Pet Bar) is covered by the ACAB.DEFAULT_BAR_IDS loop above
	-- instead, keyed by its own numeric id.
	-------------------------------------------------------------------------

	local specialKeys = { "bagbar", "micromenu", "latencybar", "expbar", "castbar", "tooltip" }
	local si

	for si = 1, table.getn(specialKeys) do
		local key = specialKeys[si]

		-- Bag Bar/Micro Menu rows only appear once their container was
		-- built (ACAB:CreateBagBarAndMicroMenu, DefaultBars.lua) - degrades
		-- gracefully if discovery failed. Latency/Experience/Cast Bar get
		-- the same defensive check since their native frame's presence on
		-- this modded client isn't fully confirmed (see DefaultBars.lua's
		-- own header comment).
		local exists = true

		if key == "bagbar" then
			exists = ACAB.bagBarContainer ~= nil
		elseif key == "micromenu" then
			exists = ACAB.microMenuContainer ~= nil
		elseif key == "latencybar" then
			exists = getglobal(ACAB.LATENCY_BAR_FRAME_NAME) ~= nil
		elseif key == "castbar" then
			exists = getglobal(ACAB.CAST_BAR_FRAME_NAME) ~= nil
		elseif key == "expbar" then
			exists = getglobal(ACAB.EXP_BAR_FRAME_NAME) ~= nil
		elseif key == "tooltip" then
			exists = ACAB.tooltipFrame ~= nil
		end

		if exists then
			local row = CreateBarListRow(key, true, nil, generationSuffix)

			row:SetPoint(
				"TOPLEFT",
				ACAB.settingsFrame.listContent,
				"TOPLEFT",
				0,
				yOffset
			)

			rowIndex = rowIndex + 1
			ACAB.settingsFrame.barButtons[rowIndex] = row
			ACAB.settingsFrame.barButtonsByBarId[key] = row

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
	local divider = ACAB.settingsFrame.listContent:CreateTexture(
		nil,
		"ARTWORK"
	)

	divider:SetTexture("Interface\\Buttons\\WHITE8X8")
	divider:SetVertexColor(0.5, 0.5, 0.5, 0.6)
	divider:SetWidth(120)
	divider:SetHeight(2)

	divider:SetPoint(
		"TOPLEFT",
		ACAB.settingsFrame.listContent,
		"TOPLEFT",
		2,
		yOffset + 2
	)

	rowIndex = rowIndex + 1

	-- The divider shares the same tracked-widget list purely so it gets
	-- hidden/recreated alongside everything else on refresh - it has no
	-- barId/checkbox/onClick, and (unlike every real row) is deliberately
	-- NOT added to barButtonsByBarId.
	ACAB.settingsFrame.barButtons[rowIndex] = divider

	yOffset = yOffset - 14

	-------------------------------------------------------------------------
	-- Extra Bars 6-9 - always exactly 4 entries (Core.lua's
	-- EnsureExtraBars), each toggled via its own inline checkbox above.
	-------------------------------------------------------------------------

	for i = 1, table.getn(ACABDB.bars) do
		local cfg = ACABDB.bars[i]

		if cfg then
			local row = CreateBarListRow(cfg.id, false, cfg, generationSuffix)

			row:SetPoint(
				"TOPLEFT",
				ACAB.settingsFrame.listContent,
				"TOPLEFT",
				0,
				yOffset
			)

			rowIndex = rowIndex + 1
			ACAB.settingsFrame.barButtons[rowIndex] = row
			ACAB.settingsFrame.barButtonsByBarId[cfg.id] = row

			yOffset = yOffset - (LIST_ROW_HEIGHT + LIST_ROW_GAP)
		end
	end

	-- No "+ Add New Bar" button - capacity is fixed at exactly
	-- ACAB.EXTRA_BAR_COUNT (4) permanent Extra Bars, always listed in the
	-- loop above; a user enables/disables one via its inline checkbox
	-- instead.

	-- Rows are all rebuilt fresh above (RefreshBarList can run after a bar
	-- page is already showing - profile switch, bar enable/disable) - the
	-- new row for the already-selected bar has isSelected == false until
	-- this restores it, since ACABListRowMixin state lives on the row
	-- instance, not the barId.
	if ACAB.settingsFrame.selectedBarId ~= nil then
		local selectedRow = ACAB.settingsFrame.barButtonsByBarId[ACAB.settingsFrame.selectedBarId]

		if selectedRow then
			selectedRow:SetSelected(true)
		end
	end
end

-- No ACAB:DeleteBar function exists - every non-default bar id (6-9) is a
-- permanent Extra Bar (Core.lua's EnsureExtraBars) toggled via
-- cfg.enabled (Bar.lua's SetExtraBarEnabled), never added/removed.

-------------------------------------------------------------------------
-- Open specific bar settings (custom bars only - called from
-- Button.lua's right-click-to-configure on a live custom-bar button;
-- default bars aren't backed by ACAB.bars, see DefaultBars.lua)
-------------------------------------------------------------------------

function ACAB:OpenBarSettings(bar)
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
-- button; default bars have no live ACAB.bars entry the way custom bars
-- do, so this takes a bar id directly rather than a bar object).
-------------------------------------------------------------------------

function ACAB:OpenDefaultBarSettings(barId)
	if not ACAB:IsDefaultBarId(barId) then
		return
	end

	self:ShowSettingsFrame()

	self:ShowBarPage(barId)
end
