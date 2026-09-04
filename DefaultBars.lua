-- DefaultBars.lua
-- Owns bars 1-5: the fixed-id "default bars" that wrap Blizzard's own
-- MainMenuBar / MultiBarBottomLeft / MultiBarBottomRight / MultiBarRight /
-- MultiBarLeft action button frames, rather than TrustyBars' own custom
-- button-pool frames (see Bar.lua/Button.lua for the bars 6+ model).
--
-- These are real Blizzard frames already backed by real action slots on
-- the default UI's own paging - we only reposition/reflow/resize/show-hide
-- them here, we never touch their action-slot bindings.

local BTV = BTVanilla

-------------------------------------------------------------------------
-- Frame name mapping for the 5 default action bars (12 buttons each,
-- numbered 1-12), centralized here since exact FrameXML names aren't
-- guaranteed on this client fork.
-------------------------------------------------------------------------

BTV.DEFAULT_BAR_FRAME_PREFIXES = {
	[1] = "ActionButton",             -- Main bar (MainMenuBar).
	[2] = "MultiBarBottomLeftButton", -- Bottom Left.
	[3] = "MultiBarBottomRightButton",-- Bottom Right.
	[4] = "MultiBarRightButton",      -- Right.
	[5] = "MultiBarLeftButton",       -- Right 2.
}

-- Real vanilla stance bars top out at 10 slots (ShapeshiftButton1-10).
-- GetStanceBarButtons stops at the first missing frame instead of
-- assuming all 10 exist, the same tolerance as GetDefaultBarButtons.
BTV.MAX_STANCE_BUTTONS = 10

-- Returns an ordered table (1-12) of the real Blizzard button frames for
-- a given default bar id, or nil if the id isn't a known default bar or
-- the global frames don't exist yet (e.g. called too early).
function BTV:GetDefaultBarButtons(id)
	local prefix = self.DEFAULT_BAR_FRAME_PREFIXES[id]

	if not prefix then
		return nil
	end

	local buttons = {}
	local i

	for i = 1, self.MAX_BAR_BUTTONS do
		local frame = getglobal(prefix .. tostring(i))

		if not frame then
			-- Stops collecting rather than producing a sparse table.
			break
		end

		buttons[i] = frame
	end

	if table.getn(buttons) == 0 then
		return nil
	end

	return buttons
end

-------------------------------------------------------------------------
-- Main Bar (bar 1) dynamic paging
--
-- Bar 1's 12 pool buttons resolve their action slot dynamically from the
-- currently effective page (GetMainBarEffectivePage below), instead of a
-- fixed cfg.fixedActionSlots array like bars 2-5. Native paging formula:
-- actionSlot = buttonID + (page-1)*12. GetBonusBarOffset() (1/2/3 for
-- stance/form/stealth) maps to page 6+offset (7/8/9).
-------------------------------------------------------------------------

-- Page bar 1's buttons currently read from. Pagination toggle locks to
-- page 1 (Shift/Ctrl modifier keybinds become inert for this bar).
-- Stance-swap only applies on top of page 1, mirroring real vanilla's
-- own main bar, so a manually-paged-away bar is never overridden by a
-- stance change.
function BTV:GetMainBarEffectivePage()
	self:EnsureDB()

	local page = 1

	if BTVanillaDB.mainBarPaginationEnabled ~= false then
		page = CURRENT_ACTIONBAR_PAGE or 1
	end

	if BTVanillaDB.mainBarStanceSwapEnabled ~= false and page == 1 then
		local offset = GetBonusBarOffset and GetBonusBarOffset() or 0

		if offset and offset > 0 then
			page = 6 + offset
		end
	end

	return page
end

-- Resolves which of the player's stance slots (1..GetNumShapeshiftForms())
-- is currently active. GetBonusBarOffset() alone only reports which bonus
-- bar is showing, not the stance-form index - not a 1:1 mapping for a
-- class with more forms than bonus bars (e.g. Druid's Travel Form grants
-- no bonus bar of its own).
function BTV:GetActiveStanceIndex()
	local count = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

	if not count or count <= 0 then
		return nil
	end

	local i

	for i = 1, count do
		local icon, name, isActive = GetShapeshiftFormInfo(i)

		if isActive then
			return i
		end
	end

	return nil
end

-- Resolves the action slot for pool button `slotIndex` on the effective
-- page. If the user has assigned an Extra Bar as this state's content
-- source (Stance/Page Bar Assignment), reads that Extra Bar's live slot
-- instead of computing a native page slot:
--   page 7-9  -> try the stance-indexed assignment.
--   page ~= 1 -> try the page-bar assignment.
--   page == 1 -> native math only.
-- Falls through to native math if unassigned or unresolved.
function BTV:GetMainBarSlotForIndex(slotIndex)
	local page = self:GetMainBarEffectivePage()

	if page >= 7 and page <= 9 then
		local stanceIndex = self:GetActiveStanceIndex()

		local assignedId = stanceIndex
			and BTVanillaDB.mainBarStanceBarAssignment
			and BTVanillaDB.mainBarStanceBarAssignment[stanceIndex]

		local slot = assignedId and self:GetExtraBarSlotForIndex(assignedId, slotIndex)

		if slot then
			return slot
		end
	elseif page ~= 1 then
		local assignedId = BTVanillaDB.mainBarPageBarAssignment
		local slot = assignedId and self:GetExtraBarSlotForIndex(assignedId, slotIndex)

		if slot then
			return slot
		end
	end

	return slotIndex + ((page - 1) * 12)
end

-- Re-resolves all of bar 1's pool buttons' action slots from the current
-- page/bonus-bar state (via Bar.lua's ApplyBarShape, cfg.dynamicMainBar
-- branch). Called whenever CURRENT_ACTIONBAR_PAGE or GetBonusBarOffset()
-- changes, or either toggle is flipped from Settings.
function BTV:RefreshMainBarSlots()
	local bar = self.bars and self.bars[1]

	if bar then
		self:ApplyBarShape(bar)
	end
end

-- Settings.lua General tab checkboxes write through these. Neither toggle
-- changes bar 1's visibility, only which action slots its buttons read
-- from, so both reapply via RefreshMainBarSlots instead of Show()/Hide().
function BTV:SetMainBarPaginationEnabled(enabled)
	self:EnsureDB()

	BTVanillaDB.mainBarPaginationEnabled = enabled and true or false

	self:RefreshMainBarSlots()

	-- Page Indicator visibility is driven by this same toggle - it has no
	-- independent enable flag of its own.
	if self.ApplyPageIndicatorVisibility then
		self:ApplyPageIndicatorVisibility()
	end
end

function BTV:SetMainBarStanceSwapEnabled(enabled)
	self:EnsureDB()

	BTVanillaDB.mainBarStanceSwapEnabled = enabled and true or false

	self:RefreshMainBarSlots()
end

-- Runs after real vanilla's ChangeActionBarPage (fires on every Shift/Ctrl
-- page swap and the page-arrow clicks) has updated CURRENT_ACTIONBAR_PAGE,
-- so RefreshMainBarSlots always reads the new value. Registered once at
-- file load since FrameXML's ChangeActionBarPage is already defined by
-- the time addon Lua files load.
if hooksecurefunc and ChangeActionBarPage then
	hooksecurefunc("ChangeActionBarPage", function()
		BTV:RefreshMainBarSlots()
	end)
end

-- UPDATE_BONUS_ACTIONBAR fires whenever the player's stance/form/stealth
-- state changes. BonusActionBarFrame is a separate native frame from
-- ActionButton1-12 that Blizzard shows as an overlay any time bonus/
-- stance content becomes active - hiding ActionButton1-12 does nothing to
-- suppress it. Hidden and Show()-neutered unconditionally here (not gated
-- on mainBarStanceSwapEnabled), since TrustyBars' own replica buttons are
-- the sole visual representation of bar 1 regardless of that toggle.
local hasNeuteredBonusActionBarFrame = false

local function HideBonusActionBarFrame()
	if not BonusActionBarFrame then
		return
	end

	BonusActionBarFrame:Hide()

	if not hasNeuteredBonusActionBarFrame then
		BonusActionBarFrame.Show = function() end
		hasNeuteredBonusActionBarFrame = true
	end
end

local mainBarBonusEventFrame = CreateFrame("Frame", "BTVanillaMainBarBonusEventFrame")
mainBarBonusEventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
mainBarBonusEventFrame:SetScript("OnEvent", function()
	HideBonusActionBarFrame()
	BTV:RefreshMainBarSlots()
end)

-------------------------------------------------------------------------
-- "Disable Blizzard Art" (General tab checkbox)
--
-- MainMenuBarArtFrame is the main bar's decorative end-cap/background art
-- (the textured strip bar 1's real ActionButton1-12 frames sit on top
-- of). Hiding it lets bar 1's replica buttons show against the user's own
-- UI/background instead.
--
-- Only its own regions (via GetRegions(), which returns a frame's own
-- directly-owned Texture/FontString regions, never child Frames) are
-- hidden/shown - never the frame itself, which would take ActionButton1-12
-- (real child Frames of artFrame) down with it.
--
-- MainMenuBarArtFrame is pinned to strata "MEDIUM", frame level 5, at all
-- times, independent of the checkbox (texture visibility and z-order are
-- separate concerns). Level 5 must stay strictly between MainMenuExpBar's
-- level 2 (or the XP bar's fill bleeds past the art) and TrustyBars bars'
-- level 10 (or bars render behind the art) - do not change without
-- re-verifying both those frames' levels.
--
-- MultiBarBottomLeft/MultiBarBottomRight/MultiBarRight/MultiBarLeft (bars
-- 2-5) have no equivalent decorative art frame in vanilla FrameXML.
function BTV:ApplyBlizzardArtVisibility()
	local artFrame = MainMenuBarArtFrame

	if not artFrame then
		return
	end

	self:EnsureDB()

	artFrame:SetFrameStrata("MEDIUM")

	-- See this section's header comment for why level 5 specifically.
	artFrame:SetFrameLevel(5)

	local hide = BTVanillaDB.disableBlizzardArt

	local regions = { artFrame:GetRegions() }
	local i

	for i = 1, table.getn(regions) do
		local region = regions[i]

		if region and region.GetObjectType and region:GetObjectType() == "Texture" then
			if hide then
				region:Hide()
			else
				region:Show()
			end
		end
	end
end

-------------------------------------------------------------------------
-- Position + grid reflow: reuses the same 1-based-index -> col/row math
-- as Bar.lua's ButtonIndexToGridPos/LayoutButtons, applied to the real
-- Blizzard frames instead of a custom bar's own button pool. Re-derived
-- here (rather than shared) since it's local to Bar.lua.
-------------------------------------------------------------------------

local function ButtonIndexToGridPos(index, cols)
	local i = index - 1
	local row = math.floor(i / cols)
	local col = i - (row * cols)
	return col, row
end

-- PixelUtil.SetPoint calls GetEffectiveScale() on both `region` and its
-- relativeTo anchor - a method FontString/Texture objects (Region-derived,
-- not Frame) don't expose. Falls back to plain SetPoint when either side
-- lacks GetEffectiveScale (e.g. the Page Indicator's MainMenuBarPageNumber
-- FontString, chain-anchored alongside ActionBarUpButton/
-- ActionBarDownButton) instead of erroring.
local function PixelSetPoint(region, ...)
	local relativeTo = arg[2]
	local canPixelSnap = region and region.GetEffectiveScale
		and (not relativeTo or relativeTo.GetEffectiveScale)

	if PixelUtil and PixelUtil.SetPoint and canPixelSnap then
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

-- Default bars 1-5 share Bar.lua's EnsureBarOverlay with every other bar
-- for their edit-mode overlay. The Stance Bar uses the chain-anchored-
-- container technique (BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay) shared with Bag Bar/Micro Menu - see the
-- "Stance Bar" section further below in this file.

-- Positions and grid-reflows the 12 real Blizzard buttons for default
-- bar `id` according to its saved config (point/relativePoint/x/y/cols/
-- rows/buttonSize). The first button is anchored directly to UIParent at
-- the configured point; the remaining 11 are anchored relative to the
-- first button using the same grid math as custom bars.
--
-- Every default bar (1-5) is a real Bar.lua bar object (self.bars[id])
-- and delegates to Bar.lua's own ApplyBarShape/ApplyBarPosition, which
-- already know how to reposition/reflow a button pool - including bar 1's
-- own dynamic per-button slot resolution (cfg.dynamicMainBar).
function BTV:ApplyDefaultBarShape(id)
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg then
		return
	end

	local bar = self.bars and self.bars[id]

	if bar then
		self:ApplyBarPosition(bar)
		self:ApplyBarShape(bar)
	end
end

-- Resizes the 12 real Blizzard buttons for default bar `id`, delegating
-- to Bar.lua's own SetBarButtonSize (clamp rule plus equip-ring/glow/
-- backdrop scaling).
function BTV:SetDefaultBarButtonSize(id, size)
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg then
		return
	end

	local bar = self.bars and self.bars[id]

	if bar then
		self:SetBarButtonSize(bar, size)
	end
end

-- Mirrors SetDefaultBarButtonSize's structure (clamp, write, reapply) for
-- the Spacing slider. Writes cfg.spacing directly (bar.config IS this same
-- BTVanillaDB.defaultBars[id] table) then reapplies via Bar.lua's own
-- ApplyBarShape.
function BTV:SetDefaultBarSpacing(id, spacing)
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg then
		return
	end

	spacing = tonumber(spacing)

	if not spacing then
		return
	end

	spacing = math.floor(spacing + 0.5)

	-- Vanilla-only real minimum spacing - see Bar.lua's SetBarSpacing
	-- for why. Mirrors that clamp exactly.
	local minSpacing = self:IsVanillaBorderStyle() and self.VANILLA_SPACING_FLOOR or 0

	if spacing < minSpacing then
		spacing = minSpacing
	end

	if spacing > 20 then
		spacing = 20
	end

	cfg.spacing = spacing

	local bar = self.bars and self.bars[id]

	if bar then
		self:ApplyBarShape(bar)
	end
end

-------------------------------------------------------------------------
-- Position (live). Default bars only move via x/y (point/relativePoint
-- stay whatever seedDefaultBars chose) - dragging isn't supported since
-- they're real Blizzard frames, not TrustyBars' own draggable bar frame.
-------------------------------------------------------------------------

-- Delegates to Bar.lua's own SetBarPosition.
function BTV:SetDefaultBarPosition(id, x, y)
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg then
		return
	end

	local bar = self.bars and self.bars[id]

	if bar then
		self:SetBarPosition(bar, x, y)
	end
end

-------------------------------------------------------------------------
-- Reset to Blizzard default layout (position, spacing, grid shape, and
-- button size)
--
-- Restores from cfg.nativeAnchor/cfg.nativeSpacing, the pristine
-- snapshots Core.lua's seedDefaultBars captured once, before TrustyBars
-- ever repositioned this bar. Does not re-read the real Blizzard frame's
-- current position - by reset time it likely already reflects wherever
-- the user last dragged/resized it, not Blizzard's original layout.
--
-- Grid shape (cols/rows) and button size are restored from the fixed
-- BTV.DEFAULT_BAR_GRID/BTV.BUTTON_SIZE constants instead, since
-- seedDefaultBars always assigns a fresh bar these same values (no
-- snapshot needed).
-------------------------------------------------------------------------

-- Restores position, grid shape, and button size for default bar `id`,
-- applied through Bar.lua's own ApplyBarPosition/SetBarLayout/
-- SetBarButtonSize. ApplyBarShape is called explicitly afterward so the
-- restored spacing takes visual effect even if SetBarLayout was skipped
-- (e.g. no grid entry for this id).
function BTV:ResetDefaultBarLayout(id)
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg or not cfg.nativeAnchor then
		return
	end

	cfg.point = cfg.nativeAnchor.point
	cfg.relativePoint = cfg.nativeAnchor.relativePoint
	cfg.x = cfg.nativeAnchor.x
	cfg.y = cfg.nativeAnchor.y

	local grid = self.DEFAULT_BAR_GRID[id]

	local bar = self.bars and self.bars[id]

	if not bar then
		return
	end

	if cfg.nativeSpacing then
		cfg.spacing = cfg.nativeSpacing
	end

	self:ApplyBarPosition(bar)

	if grid then
		self:SetBarLayout(bar, grid.cols, grid.rows)
	end

	self:SetBarButtonSize(bar, self.BUTTON_SIZE)

	-- Guarantees the restored spacing is reflected even if SetBarLayout
	-- above didn't run (e.g. grid is nil for this id).
	self:ApplyBarShape(bar)
end

-------------------------------------------------------------------------
-- Enable / disable (bars 2-5 only - bar 1 is always active, no UI)
--
-- Bars 2-5's real Blizzard buttons are permanently hidden regardless of
-- state (CreateFixedSlotDefaultBars below); cfg.enabled + Show()/Hide()
-- on this addon's own Bar.lua bar frame is the sole visibility mechanism.
-------------------------------------------------------------------------

-- Toggling bar 2 (Bottom Left) reflows the Stance Bar's own position
-- (ReflowStanceBarForBar2Toggle below) to keep it from overlapping bar 2.
-- Real vanilla FrameXML normally does this itself via
-- ShapeshiftBar_UpdatePosition(), but that no longer has any visible
-- effect once the Stance Bar's buttons are reparented into a synthetic
-- container (see BuildChainAnchoredContainer) - Blizzard's own reflow
-- keys off the real MultiBarBottomLeftButton1-12 frames' shown state,
-- which never changes now that they're permanently hidden.
function BTV:SetDefaultBarEnabled(id, enabled)
	if id == 1 then
		-- Bar 1 (Main) has no enable/disable - always active.
		return
	end

	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg then
		return
	end

	enabled = enabled and true or false

	-- Captured before cfg.enabled is overwritten - ReflowStanceBarForBar2Toggle
	-- must only fire on an actual state change, not on every call (e.g.
	-- ApplyAllDefaultBars calls this at every login with the already-
	-- current value).
	local wasEnabled = cfg.enabled and true or false

	cfg.enabled = enabled

	local bar = self.bars and self.bars[id]

	if bar then
		if enabled then
			bar:Show()
		else
			bar:Hide()
		end
	end

	if id == 2 and enabled ~= wasEnabled and BTVanillaDB.useDefaultLayout ~= false then
		self:ReflowStanceBarForBar2Toggle(enabled)
	end

	-- Matches native's own dependency (bar 5 requires bar 4 - see
	-- FixRightActionBar2Checkbox) - user can opt out via the General tab.
	if id == 4 then
		if enabled ~= wasEnabled and not enabled and not BTVanillaDB.bypassRightActionBar2Dependency then
			self:SetDefaultBarEnabled(5, false)
		end

		-- Refreshes bar 5's own Settings UI (sidebar + page checkbox) since
		-- it locks/unlocks based on bar 4's state.
		if enabled ~= wasEnabled and BTV:IsSettingsFrameCreated() then
			BTV:RefreshBarList()
			BTV:RefreshBarSettingsPage(5)
		end
	end

	-- Mirrors state into the native "Show ... ActionBar" global purely so
	-- the Interface Options checkbox doesn't look stuck - cfg.enabled
	-- above remains the sole visual authority.
	local nativeGlobal = BTV.SHOW_MULTI_ACTIONBAR_GLOBAL[id]

	if nativeGlobal then
		-- Stored/compared as the string "1"/"0", not a boolean or number -
		-- matches LOCK_ACTIONBAR/ALWAYS_SHOW_MULTIBARS convention.
		--
		-- Deliberately does not call MultiActionBar_Update() here - doing
		-- so caused "Right ActionBar 2" (bar 5) to get stuck permanently
		-- unable to re-enable after bar 4 was toggled off once. Setting
		-- the global alone is enough for the real Options panel checkbox
		-- to read correctly next time it's shown.
		setglobal(nativeGlobal, enabled and "1" or nil)

		-- This custom Options framework only reads the global into the
		-- checkbox's checked-display at panel-show time, not reactively -
		-- set the control directly too so an already-open panel stays synced.
		local control = getglobal("OptionsFrameCheckButton" .. tostring(id) .. "Control")

		if control and control.SetChecked then
			control:SetChecked(enabled)
		end
	end

	self:FixRightActionBar2Checkbox()
end

-- Reconciles our own cfg.enabled (bars 2-5) from the native
-- SHOW_MULTI_ACTIONBAR_1-4 globals whenever MultiActionBar_Update runs
-- (e.g. the real Interface Options checkbox's own OnClick). Only trusted
-- reactively within the current session - these globals don't survive a
-- real logout on this fork (see BTV.SHOW_MULTI_ACTIONBAR_GLOBAL).
function BTV:ReconcileDefaultBarEnabledFromNative()
	if not (BTVanillaDB and BTVanillaDB.defaultBars) then
		return
	end

	local id

	for id = 2, 5 do
		local nativeGlobal = BTV.SHOW_MULTI_ACTIONBAR_GLOBAL[id]
		local cfg = BTVanillaDB.defaultBars[id]

		if nativeGlobal and cfg then
			local nativeEnabled = getglobal(nativeGlobal) and true or false
			local currentEnabled = cfg.enabled and true or false

			if nativeEnabled ~= currentEnabled then
				-- Re-enters SetDefaultBarEnabled, which writes the same
				-- (already-matching) value back to nativeGlobal and calls
				-- MultiActionBar_Update() again - re-fires this same
				-- hook once more, but by then nativeEnabled ==
				-- currentEnabled already, so it's a harmless one-level
				-- no-op re-entry, not a loop.
				self:SetDefaultBarEnabled(id, nativeEnabled)

				-- Keep the Settings window's own displayed checkboxes
				-- (sidebar + that bar's own page, if currently open) in
				-- sync too - only if the window has actually been built
				-- this session, so toggling a native checkbox never
				-- silently forces our settings UI into existence as a
				-- side effect.
				if BTV:IsSettingsFrameCreated() then
					BTV:RefreshBarList()
					BTV:RefreshBarSettingsPage(id)
				end
			end
		end
	end

	self:FixRightActionBar2Checkbox()
end

-- This fork's Options -> Action Bars panel is a custom framework (not
-- stock FrameXML): "Show Right ActionBar 2" (bar 5,
-- OptionsFrameCheckButton5Control) gets stuck disabled instead of
-- reactively following "Show Right ActionBar" (bar 4). Bar 4's real state
-- is mirrored onto it directly whenever bar 4/5 state is touched. Only
-- fixes the enabled state, not the label's grey text color (not tied to
-- :IsEnabled() on this framework). This custom framework does not call
-- native MultiActionBar_Update() on its own checkbox clicks, so bar 4's
-- checkbox click is hooked directly instead, once.
local hookedBar4Checkbox = false

-- Enabled label color (1, 0.82, 0) - only forced when enabled; native
-- handles the disabled grey color on its own.
local RIGHT_ACTIONBAR2_LABEL_ENABLED_COLOR = { 1, 0.82, 0 }

local function SetCheckbox5LabelEnabledColor()
	local outer = getglobal("OptionsFrameCheckButton5")

	if not outer then
		return
	end

	local regions = { outer:GetRegions() }
	local i

	for i = 1, table.getn(regions) do
		local r = regions[i]
		local okType, objType = pcall(function() return r.GetObjectType and r:GetObjectType() end)

		if okType and objType == "FontString" then
			r:SetTextColor(
				RIGHT_ACTIONBAR2_LABEL_ENABLED_COLOR[1],
				RIGHT_ACTIONBAR2_LABEL_ENABLED_COLOR[2],
				RIGHT_ACTIONBAR2_LABEL_ENABLED_COLOR[3]
			)
		end
	end
end

function BTV:FixRightActionBar2Checkbox()
	local control5 = getglobal("OptionsFrameCheckButton5Control")

	if control5 and control5.Enable and control5.Disable then
		local bar4Cfg = BTVanillaDB and BTVanillaDB.defaultBars and BTVanillaDB.defaultBars[4]
		local shouldEnable = (BTVanillaDB and BTVanillaDB.bypassRightActionBar2Dependency)
			or (bar4Cfg and bar4Cfg.enabled)

		if shouldEnable then
			control5:Enable()
			SetCheckbox5LabelEnabledColor()
		else
			control5:Disable()
		end
	end

	if not hookedBar4Checkbox then
		local control4 = getglobal("OptionsFrameCheckButton4Control")

		if control4 and control4.HookScript then
			control4:HookScript("OnClick", function()
				BTV:FixRightActionBar2Checkbox()
			end)

			hookedBar4Checkbox = true
		end
	end
end

-- hooksecurefunc runs AFTER the real MultiActionBar_Update has already
-- applied whatever the native checkbox/globals currently say, so the
-- reconcile above always reads the new value, never the stale one. Same
-- top-level "register once at file load" convention as
-- ChangeActionBarPage's own hook elsewhere in this file.
if hooksecurefunc and MultiActionBar_Update then
	hooksecurefunc("MultiActionBar_Update", function()
		BTV:ReconcileDefaultBarEnabledFromNative()
	end)
end

-- Every default bar (1-5) delegates to Bar.lua's own SetBarLayout (which
-- also re-clamps buttonCount - always a no-op here in practice, since
-- every grid preset totals exactly 12 and default bars have no
-- buttons-shown stepper, but keeping the exact same call custom bars use
-- costs nothing and stays consistent).
function BTV:SetDefaultBarLayout(id, cols, rows)
	self:EnsureDB()

	local bar = self.bars and self.bars[id]

	if bar then
		self:SetBarLayout(bar, cols, rows)
	end
end

-------------------------------------------------------------------------
-- Builds every default bar (1-5) as a Bar.lua bar object.
--
-- Must run once at PLAYER_LOGIN, before ApplyAllDefaultBars - every
-- function above reads self.bars[id], which this creates.
--
-- For each of bars 2-5 with a discovered cfg.fixedActionSlots, and for
-- bar 1 (cfg.dynamicMainBar, always present):
--   1. Permanently hides the bar's 12 real Blizzard buttons and neuters
--      their Show method to a no-op. Hiding a real ActionButton does not
--      break its native keybind dispatch, so our own replica bar becomes
--      the sole visual representation from this point on.
--   2. Builds this bar's own Bar.lua/Button.lua button pool
--      (CreateBarFromConfig, pointed at cfg.fixedActionSlots or resolved
--      dynamically per cfg.dynamicMainBar) and stores it in self.bars[id]
--      - the same table a custom bar (id 6+) lives in, so every other
--      system that iterates self.bars picks these bars up automatically.
--
-- If discovery failed for one of bars 2-5, that bar is skipped here and
-- keeps its real Blizzard buttons visible until a later login succeeds.
-------------------------------------------------------------------------

-- Each real button's Show method is permanently overridden to a no-op
-- once hidden, so any later native call (e.g. ACTIONBAR_SHOWGRID's sweep)
-- can't make it visible again.
function BTV:CreateFixedSlotDefaultBars()
	self:EnsureDB()

	local id

	for id = 1, 5 do
		local cfg = BTVanillaDB.defaultBars[id]

		if cfg and (cfg.fixedActionSlots or cfg.dynamicMainBar) and not self.bars[id] then
			local nativeButtons = self:GetDefaultBarButtons(id)

			if nativeButtons then
				local i

				for i = 1, table.getn(nativeButtons) do
					local btn = nativeButtons[i]

					if btn then
						btn:Hide()
						btn.Show = function() end
					end
				end
			end

			self.bars[id] = self:CreateBarFromConfig(cfg)

			-- Bar 1 has no cfg.enabled key (always nil), so it must be
			-- shown explicitly here - nothing else ever calls :Show() on it.
			if id == 1 or cfg.enabled then
				self.bars[id]:Show()
			else
				self.bars[id]:Hide()
			end
		end
	end
end

-------------------------------------------------------------------------
-- Apply all 5 default bars from SavedVariables
-------------------------------------------------------------------------

function BTV:ApplyAllDefaultBars()
	self:EnsureDB()

	local id

	for id = 1, 5 do
		local cfg = BTVanillaDB.defaultBars[id]

		if cfg then
			if id ~= 1 then
				-- Bars 2-5: cfg.enabled is the sole visibility source now
				-- that their real Blizzard buttons are permanently hidden.
				self:SetDefaultBarEnabled(id, cfg.enabled)
			end

			-- Always reapply shape/overlay here regardless of enabled state.
			-- Vanilla FrameXML anchors the extra multibars relative to the
			-- main bar/each other, not UIParent - a disabled bar skipped
			-- here would stay riding that native anchor chain and never get
			-- its own overlay frame, instead of being independently
			-- re-anchored to UIParent from its own cfg.
			self:ApplyDefaultBarShape(id)
		end
	end
end

-------------------------------------------------------------------------
-- Default bar / stance bar dragging (Edit Layout mode,
-- useDefaultLayout == false only)
--
-- Default bars 1-5 drag via Bar.lua's own EnsureBarOverlay/StartBarDrag/
-- StopBarDrag, same as every custom/Extra Bar (dragKind == "bar").
--
-- The Stance Bar (dragKind == "stanceBar") has no Bar.lua container frame
-- of its own - it's a single real Blizzard frame (ShapeshiftBarFrame)
-- tracked and repositioned directly through this same shared cursor-
-- tracking OnUpdate mechanism.
-------------------------------------------------------------------------

-- Created lazily, exactly once - shared by every default-bar AND
-- stance-bar drag (only one drag can ever be in progress at a time,
-- since it's driven by mouse button state), so a second frame per drag
-- kind would be redundant.
local dragFrame

-- Dragging is intercepted at the frame-stacking level: Bar.lua's overlay
-- frames (EnsureBarOverlay/EnsureContainerOverlay, see
-- ApplyDefaultLayoutEditVisual below) are mouse-enabled and sit in HIGH
-- strata fully covering the real buttons, so the native OnDragStart
-- handler on those buttons never fires and LOCK_ACTIONBAR never needs to
-- be touched.

local function GetCursorPositionUIScale()
	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / scale, y / scale
end

-- Shared per-tick snap injection for every dragKind below
-- (BTV:ComputeSnapAdjustment, Core.lua): called with the real frame being
-- repositioned (never its overlay) and the pending position table, and
-- nudges pos.x/pos.y in place before the caller applies them. Also used
-- by the dragKind == "bar" branch (Bar.lua's StartBarDrag/StopBarDrag,
-- bars 1-9), so every draggable element shares one snap code path.
-- No-ops when the setting is off or the frame can't yet report a
-- size/scale (e.g. never shown this session).
--
-- pos.point/pos.relativePoint are always "TOPLEFT"/"BOTTOMLEFT" - every
-- caller normalizes to this pair before a drag starts - so pos.x/pos.y
-- (the frame's local-unit offset from UIParent's BOTTOMLEFT corner)
-- convert to/from screen pixels via this frame's effective scale alone,
-- no anchor-point math needed.
local function ApplyDragSnap(frame, pos)
	if not frame or not pos then
		return
	end

	local scale = frame:GetEffectiveScale()
	local width = frame:GetWidth()
	local height = frame:GetHeight()

	if not scale or not width or not height then
		return
	end

	-- Inflates the dragged element's own proposed box by its visual inset
	-- (Core.lua's BTV:GetElementVisualInset - nonzero only
	-- for default bars 1-5, whose native border overhangs their frame, and
	-- NOT symmetric top vs. bottom - see BTV.BORDER_Y_OFFSET's comment) so
	-- it's compared against every target's own inset-adjusted box
	-- (Core.lua's GetAllSnapTargetBoxes) on equal terms - border edge vs.
	-- border edge, not frame edge vs. border edge. Deflated back out of the
	-- result before writing to pos.x/pos.y, since pos always represents
	-- this frame's own TOPLEFT corner, never its inflated box.
	local il, ir, it, ib = BTV:GetElementVisualInset(frame)
	local ilPx, irPx, itPx, ibPx = il * scale, ir * scale, it * scale, ib * scale

	local proposedLeft = pos.x * scale - ilPx
	local proposedTop = pos.y * scale + itPx

	local adjustedLeft, adjustedTop = BTV:ComputeSnapAdjustment(
		proposedLeft,
		proposedTop,
		width * scale + ilPx + irPx,
		height * scale + itPx + ibPx,
		frame
	)

	if adjustedLeft then
		pos.x = (adjustedLeft + ilPx) / scale
	end

	if adjustedTop then
		pos.y = (adjustedTop - itPx) / scale
	end
end

-- Shared OnUpdate body for both drag kinds - `this` is dragFrame itself
-- (an engine-invoked handler, so `this` per the file-level convention
-- noted throughout this addon, e.g. Button.lua's header comment).
local function DefaultBarDrag_OnUpdate()
	local cx, cy = GetCursorPositionUIScale()
	local dx = cx - this.dragStartCursorX
	local dy = cy - this.dragStartCursorY

	if this.dragKind == "stanceBar" then
		local pos = BTVanillaDB.stanceBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(BTV.stanceBarContainer, pos)

			BTV:ApplyStanceBarPosition()
		end
	elseif this.dragKind == "bagBar" then
		local pos = BTVanillaDB.bagBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(BTV.bagBarContainer, pos)

			BTV:ApplyBagBarPosition()
		end
	elseif this.dragKind == "microMenu" then
		local pos = BTVanillaDB.microMenuPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(BTV.microMenuContainer, pos)

			BTV:ApplyMicroMenuPosition()
		end
	elseif this.dragKind == "keyRing" then
		local pos = BTVanillaDB.keyRingPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(getglobal(BTV.KEYRING_BUTTON_NAME), pos)

			BTV:ApplyKeyRingPosition()
		end
	elseif this.dragKind == "latencyBar" then
		local pos = BTVanillaDB.latencyBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(getglobal(BTV.LATENCY_BAR_FRAME_NAME), pos)

			BTV:ApplyLatencyBarPosition()
		end
	elseif this.dragKind == "expBar" then
		local pos = BTVanillaDB.expBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(getglobal(BTV.EXP_BAR_FRAME_NAME), pos)

			BTV:ApplyExpBarPosition()
		end
	elseif this.dragKind == "pageIndicator" then
		local pos = BTVanillaDB.mainBarPageIndicatorPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ApplyDragSnap(BTV.pageIndicatorContainer, pos)

			BTV:ApplyPageIndicatorPosition()
		end
	elseif this.dragKind == "bar" then
		-- Bars 1-9 (Bar.lua's StartBarDrag/StopBarDrag): unlike the other
		-- dragKinds above, a bar's position lives directly on
		-- bar.config.x/y (Bar.lua's own ApplyBarPosition reads exactly
		-- these two fields), so this reads/writes bar.config in place
		-- rather than a separate position table. BTV:ApplyBarPosition (not
		-- ApplyBarShape) is the minimal correct call here - ApplyBarShape
		-- would also re-bind every button's action slot, resize the bar
		-- frame, and re-run LayoutButtons on every tick.
		local bar = BTV.bars and BTV.bars[this.dragId]

		if bar and bar.config then
			local pos = {
				x = this.dragStartX + dx,
				y = this.dragStartY + dy,
			}

			ApplyDragSnap(bar, pos)

			bar.config.x = pos.x
			bar.config.y = pos.y

			BTV:ApplyBarPosition(bar)
		end
	end
end

local function EnsureDragFrame()
	if not dragFrame then
		dragFrame = CreateFrame("Frame", "BTVanillaDefaultBarDragFrame", UIParent)
		dragFrame:Hide()
	end

	return dragFrame
end

-------------------------------------------------------------------------
-- Generic start/stop seam onto the shared cursor-tracking drag frame
-- above (dragFrame/EnsureDragFrame/DefaultBarDrag_OnUpdate/
-- GetCursorPositionUIScale are all file-local to this file), exposed as
-- BTV methods so Bar.lua's own StartBarDrag/StopBarDrag (bars 1-9) can
-- initiate/finalize a drag through this same mechanism.
-------------------------------------------------------------------------

function BTV:StartSharedDrag(dragKind, dragId, startX, startY)
	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = dragKind
	frame.dragId = dragId
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = startX or 0
	frame.dragStartY = startY or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopSharedDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()
end

-- True only while both Edit Layout mode AND useDefaultLayout == false are
-- active - the single shared gate every default-bar-button/stance-bar
-- drag hook below checks before doing anything, mirroring
-- BTV:IsEditMode()'s own nil-safety (this can in principle be queried
-- before EnsureDB has ever run).
function BTV:CanDragDefaultLayout()
	return self:IsEditMode() and BTVanillaDB and BTVanillaDB.useDefaultLayout == false
end

-- Stance Bar position/spacing/scale/orientation/enable/drag: see the
-- "Stance Bar (chain-anchored container)" section further below, which
-- shares the BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay machinery with Bag Bar/Micro Menu/Key Ring/
-- Latency Bar.

-------------------------------------------------------------------------
-- Bag Bar / Micro Menu
--
-- Neither element has a single native Blizzard container frame on real
-- vanilla 1.12.1. Builds a synthetic container frame and reparents each
-- real button into it, chain-anchored (button 2 to button 1's own edge,
-- etc. - not each button anchored independently to the container), the
-- same pattern the Bartender2 reference addon uses on this client
-- generation.
--
-- Bag Bar = the 5 real vanilla 1.12 bag buttons (no Key Ring - a later-
-- expansion feature). Micro Menu = the 8 real micro-menu buttons
-- ("Socials", not "Social" - real FrameXML name).
-------------------------------------------------------------------------

BTV.BAG_BAR_BUTTON_NAMES = {
	"CharacterBag0Slot",
	"CharacterBag1Slot",
	"CharacterBag2Slot",
	"CharacterBag3Slot",
	"MainMenuBarBackpackButton",
}

BTV.MICRO_MENU_BUTTON_NAMES = {
	"CharacterMicroButton",
	"SpellbookMicroButton",
	"TalentMicroButton",
	"QuestLogMicroButton",
	"SocialsMicroButton",
	"WorldMapMicroButton",
	"MainMenuMicroButton",
	"HelpMicroButton",
}

-- Resolves a fixed list of real global frame names into an ordered
-- table, skipping (not erroring on) any name that doesn't exist on this
-- client - same defensive tolerance as GetDefaultBarButtons/
-- GetStanceBarButtons' "stop/skip on missing frame" rule, just applied
-- to a heterogeneous name list instead of a numbered prefix run.
local function GetButtonsByName(names)
	local buttons = {}
	local n = 0
	local i

	for i = 1, table.getn(names) do
		local frame = getglobal(names[i])

		if frame then
			n = n + 1
			buttons[n] = frame
		end
	end

	if n == 0 then
		return nil
	end

	return buttons
end

-- Sorts a button list left-to-right by each frame's REAL, current
-- on-screen GetLeft() - must be called before any of these frames are
-- reparented/repositioned. The literal order names are listed in
-- BAG_BAR_BUTTON_NAMES/MICRO_MENU_BUTTON_NAMES above is not assumed to
-- already be the real native left-to-right visual order (another
-- "capture, don't guess" case, same as Core.lua's CaptureNativeSpacing) -
-- this derives the true order directly from the live frames instead.
local function SortButtonsByNativeLeft(buttons)
	table.sort(buttons, function(a, b)
		local aLeft = a:GetLeft() or 0
		local bLeft = b:GetLeft() or 0

		return aLeft < bLeft
	end)
end

-- Computes the per-pair gap across a chain of native button positions/
-- widths - used once at container-build time (below) to seed this
-- element's permanent nativeSpacing baseline - never re-derived
-- afterward, per the same "capture, don't guess" reasoning as
-- CaptureNativeSpacing.
--
-- Uses the median of the raw gaps, which is more robust against
-- outliers/ties than a majority-vote bucket scheme.
local function ComputeMajorityGap(lefts, widths)
	local gaps = {}
	local n = 0
	local i

	for i = 2, table.getn(lefts) do
		local gap = (lefts[i] - lefts[i - 1]) - (widths[i - 1] or 0)

		if gap < 0 then
			gap = 0
		end

		n = n + 1
		gaps[n] = gap
	end

	if n == 0 then
		return 0
	end

	table.sort(gaps, function(a, b) return a < b end)

	local median

	if n - (math.floor(n / 2) * 2) == 0 then
		-- Even count: average the two middle values.
		local lo = gaps[n / 2]
		local hi = gaps[(n / 2) + 1]
		median = (lo + hi) / 2
	else
		median = gaps[math.floor((n + 1) / 2)]
	end

	return math.floor(median + 0.5)
end

-- Builds one synthetic container frame and reparents `buttons` (already
-- sorted left-to-right by SortButtonsByNativeLeft) into it. The actual
-- chain-anchoring (button 1 to the container's own TOPLEFT, every
-- subsequent button anchored to the previous one) is factored out into
-- ApplyChainAnchoredShape below, so it can be re-run any time
-- cfg.spacing/cfg.orientation/cfg.scale changes, not just once here.
--
-- HIGH strata: without an explicit strata this frame inherits the
-- ordinary default tier, which can render behind MainMenuBarArtFrame's
-- own background art - HIGH sits above that unconditionally, not just
-- during edit mode.
--
-- Returns the container, plus button 1's own captured native
-- GetLeft()/GetTop() (in UIParent-absolute space, same convention as
-- Core.lua's CaptureNativeAnchor) and the chain's majority native gap
-- (ComputeMajorityGap above) - the caller uses these to seed this
-- element's permanent nativeAnchor/nativeSpacing and initial mutable
-- position/spacing, since by the time this function returns the buttons
-- have already been reparented and their original positions are no
-- longer readable.
local function BuildChainAnchoredContainer(frameName, buttons)
	local lefts, tops, widths, heights = {}, {}, {}, {}
	local i

	for i = 1, table.getn(buttons) do
		lefts[i]   = buttons[i]:GetLeft() or 0
		tops[i]    = buttons[i]:GetTop() or 0
		widths[i]  = buttons[i]:GetWidth() or 36
		heights[i] = buttons[i]:GetHeight() or 36
	end

	local container = CreateFrame("Frame", frameName, UIParent)
	container:SetFrameStrata("HIGH")

	for i = 1, table.getn(buttons) do
		buttons[i]:SetParent(container)
	end

	-- Cached on the container itself so ApplyChainAnchoredShape can
	-- re-lay-out this exact chain later (spacing/orientation/scale
	-- changes) without re-measuring - widths/heights never change after
	-- this point, since these real Blizzard buttons are never
	-- individually resized here, only the container's own SetScale.
	container.chainButtons = buttons
	container.chainWidths = widths
	container.chainHeights = heights

	local nativeSpacing = ComputeMajorityGap(lefts, widths)

	-- button 1's captured lefts[1]/tops[1] are in its own effective-scale
	-- coordinate space, not literal screen pixels (same conversion as
	-- Core.lua's CaptureNativeAnchor). Converts through real screen pixels
	-- here so every caller (Bag Bar/Micro Menu/Stance Bar) gets a
	-- consistent nativeX/nativeY.
	local buttonScale = buttons[1]:GetEffectiveScale()
	local uiParentScale = UIParent:GetEffectiveScale()

	local nativeX = lefts[1]
	local nativeY = tops[1]

	if buttonScale and uiParentScale and uiParentScale ~= 0 then
		nativeX = (nativeX * buttonScale) / uiParentScale
		nativeY = (nativeY * buttonScale) / uiParentScale
	end

	return container, nativeX, nativeY, nativeSpacing
end

-- Re-chain-anchors a Bag Bar/Micro Menu container's buttons from its
-- current spacing/orientation, and applies its current scale - shared by
-- BTV:ApplyBagBarShape/ApplyMicroMenuShape below, since both elements use
-- the same chain-anchoring technique BuildChainAnchoredContainer sets up.
--
-- horizontal (orientation == false, native default): each button's
-- TOPLEFT anchors to the previous button's TOPRIGHT, offset by `spacing`.
--
-- vertical/orientation-swapped (orientation == true): each button's
-- TOPLEFT anchors to the previous button's BOTTOMLEFT, offset downward
-- by `spacing`.
--
-- Chains only currently-shown buttons, filtered live via IsShown() on
-- every call rather than cached once at container-build time - a hidden
-- button (e.g. TalentMicroButton, natively hidden below level 10) must
-- not reserve a slot in the chain, and shown state can change mid-session
-- (leveling past 10 unlocks Talent) - see the UpdateMicroButtons hook
-- further below, which re-runs ApplyMicroMenuShape exactly when Blizzard's
-- own code re-evaluates that.

-- Finds the first and last currently-shown button in a chain (shared by
-- ApplyChainAnchoredShape below and EnsureContainerOverlay's own initial
-- anchor) - a hidden button is parked at the last-shown button's own
-- TOPLEFT, so it must never be picked as either endpoint. Returns first,
-- last (both nil if every button in the chain is currently hidden).
local function GetChainShownEndpoints(container)
	if not container or not container.chainButtons then
		return nil, nil
	end

	local buttons = container.chainButtons
	local first, last
	local i

	for i = 1, table.getn(buttons) do
		if buttons[i] and buttons[i]:IsShown() then
			if not first then
				first = buttons[i]
			end

			last = buttons[i]
		end
	end

	return first, last
end

-- A real Button can define GetHitRectInsets() - four values (left,
-- right, top, bottom) trimming its actual clickable/visually-relevant
-- area inward from its own frame edges, independent of the frame's own
-- GetWidth()/GetHeight(). Every Micro Menu button reports a 58px-tall
-- frame but a (0, 0, 18, 0) hit-rect inset - only the bottom 40px is real
-- content, the top 18px is a decorative flare. Returns 0 for any frame
-- that doesn't support the API, so every call site here is always safe
-- to use unconditionally.
local function GetHitInsets(frame)
	if not frame or not frame.GetHitRectInsets then
		return 0, 0, 0, 0
	end

	local left, right, top, bottom = frame:GetHitRectInsets()

	return left or 0, right or 0, top or 0, bottom or 0
end

-- GetHitInsets' values are in `frame`'s own local unit system (a fixed
-- property of the widget's declared size, unaffected by SetScale). The
-- chain-anchored container's own SetScale changes `frame`'s on-screen
-- size without changing that declared value, but the overlay (a separate
-- frame parented straight to UIParent, no SetScale of its own) has a
-- fixed effective scale that does not track the container's scale - this
-- converts a value in `frame`'s local units into the equivalent offset
-- in `overlay`'s local units, so it stays correct at any scale.
local function ScaleRatio(frame, overlay)
	local frameScale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
	local overlayScale = overlay and overlay.GetEffectiveScale and overlay:GetEffectiveScale()

	if not frameScale or not overlayScale or overlayScale == 0 then
		return 1
	end

	return frameScale / overlayScale
end

local function ApplyChainAnchoredShape(container, spacing, orientation, scale)
	if not container or not container.chainButtons then
		return
	end

	local buttons = container.chainButtons
	local widths = container.chainWidths
	local heights = container.chainHeights

	spacing = spacing or 0

	local first
	local firstIndex
	local i

	for i = 1, table.getn(buttons) do
		if buttons[i] and buttons[i]:IsShown() then
			first = buttons[i]
			firstIndex = i
			break
		end
	end

	if not first then
		-- Every button in this chain is currently hidden (e.g. a class
		-- with zero active stance forms) - collapse the container instead
		-- of leaving it at its last real size.
		PixelSetSize(container, 1, 1)
		container:SetScale(scale or 1)

		if container.btvOverlay then
			container.btvOverlay:ClearAllPoints()
			container.btvOverlay:SetAllPoints(container)
		end

		return
	end

	-- `first`'s frame TOPLEFT must stay at container's TOPLEFT with no
	-- hit-rect trim - container's saved position (BTVanillaDB.*Position)
	-- was captured against `first`'s raw frame corner
	-- (BuildChainAnchoredContainer's nativeLeft/nativeTop), so trimming
	-- here would shift every existing user's saved position. The overlay
	-- below has no such dependency, so it gets full trimming on every side.
	first:ClearAllPoints()
	PixelSetPoint(first, "TOPLEFT", container, "TOPLEFT", 0, 0)

	-- Main-axis seed (width for horizontal, height for vertical) stays
	-- `first`'s raw frame size, matching its untrimmed leading edge above.
	-- Cross-axis seed is seeded already-trimmed by `first`'s own hit-rect
	-- inset on that axis, so the loop below's visibleW/visibleH
	-- comparisons can shrink it below `first`'s untrimmed size when other
	-- buttons' real visible size is smaller (e.g. Micro Menu: 58 vs the
	-- real 40).
	local firstLeftSeed, firstRightSeed, firstTopSeed, firstBottomSeed = GetHitInsets(first)

	local totalWidth = widths[firstIndex] or 0
	local totalHeight = heights[firstIndex] or 0

	if orientation then
		totalWidth = totalWidth - firstLeftSeed - firstRightSeed
	else
		totalHeight = totalHeight - firstTopSeed - firstBottomSeed
	end

	local prevBtn = first

	for i = firstIndex + 1, table.getn(buttons) do
		local btn = buttons[i]

		if btn then
			if btn:IsShown() then
				local w = widths[i] or 0
				local h = heights[i] or 0

				local prevLeft, prevRight, prevTop, prevBottom = GetHitInsets(prevBtn)
				local btnLeft, btnRight, btnTop, btnBottom = GetHitInsets(btn)

				btn:ClearAllPoints()

				if orientation then
					-- Real visible bottom of prevBtn = its frame bottom +
					-- prevBottom (a bottom inset trims UPWARD from the
					-- bottom edge); real visible top of btn = its frame
					-- top - btnTop. Solving for the TOPLEFT->BOTTOMLEFT
					-- offset that makes those two real edges exactly
					-- `spacing` apart (instead of the raw frames) gives
					-- this formula - reduces to the original bare
					-- `-spacing` when both insets are 0.
					PixelSetPoint(btn, "TOPLEFT", prevBtn, "BOTTOMLEFT", 0, prevBottom - spacing + btnTop)

					totalHeight = totalHeight + spacing + h - prevBottom - btnTop

					local visibleW = w - btnLeft - btnRight

					if visibleW > totalWidth then
						totalWidth = visibleW
					end
				else
					-- Same reasoning, horizontal axis: real visible right
					-- of prevBtn = frame right - prevRight; real visible
					-- left of btn = frame left + btnLeft.
					PixelSetPoint(btn, "TOPLEFT", prevBtn, "TOPRIGHT", spacing - prevRight - btnLeft, 0)

					totalWidth = totalWidth + spacing + w - prevRight - btnLeft

					local visibleH = h - btnTop - btnBottom

					if visibleH > totalHeight then
						totalHeight = visibleH
					end
				end

				prevBtn = btn
			else
				-- Hidden - parked at the last visible button's own TOPLEFT
				-- (harmless overlap, since a hidden frame renders/receives
				-- no mouse events either way) rather than left dangling on
				-- a stale anchor or consuming a chain slot.
				btn:ClearAllPoints()
				PixelSetPoint(btn, "TOPLEFT", prevBtn, "TOPLEFT", 0, 0)
			end
		end
	end

	-- Container's own size trims only the TRAILING edge (prevBtn's own
	-- hit-rect inset on whichever side it ends the chain) - shrinking from
	-- the far end never touches container's TOPLEFT origin, so this part
	-- is safe to always apply in full, unlike `first`'s own leading inset
	-- above.
	do
		local prevLeft, prevRight, prevTop, prevBottom = GetHitInsets(prevBtn)

		if orientation then
			totalHeight = totalHeight - prevBottom
		else
			totalWidth = totalWidth - prevRight
		end
	end

	PixelSetSize(container, totalWidth, totalHeight)
	container:SetScale(scale or 1)

	-- The overlay has no saved-position dependency (unlike `container`'s
	-- own TOPLEFT above), so it gets full trimming on every side -
	-- `first`'s own leading (left/top) inset and `prevBtn`'s (the last
	-- currently-shown button, tracked through the loop above) trailing
	-- (right/bottom) inset - re-applied every time this function runs
	-- (spacing/orientation/scale change, or a button's shown state
	-- changing, e.g. Talent unlocking).
	if container.btvOverlay then
		local firstLeft, firstRight, firstTop, firstBottom = GetHitInsets(first)
		local lastLeft, lastRight, lastTop, lastBottom = GetHitInsets(prevBtn)
		local firstRatio = ScaleRatio(first, container.btvOverlay)
		local lastRatio = ScaleRatio(prevBtn, container.btvOverlay)
		local topFudge = container.overlayTopFudge or 0

		container.btvOverlay:ClearAllPoints()
		container.btvOverlay:SetPoint("TOPLEFT", first, "TOPLEFT", firstLeft * firstRatio, -(firstTop + topFudge) * firstRatio)
		container.btvOverlay:SetPoint("BOTTOMRIGHT", prevBtn, "BOTTOMRIGHT", -lastRight * lastRatio, lastBottom * lastRatio)
	end
end

-- Shared overlay helper: drag ownership + right-click-to-settings,
-- mirroring Bar.lua's EnsureBarOverlay boilerplate (TOOLTIP strata for
-- the same filled-button-strata-gap workaround). Parameterized by
-- container frame, drag start/stop callbacks, the settings-page key to
-- open on right-click, an optional scroll-to-scale setter, and an
-- optional FrameLevel - shared by Bag Bar/Micro Menu/Key Ring/Latency
-- Bar/Stance Bar.
--
-- scaleSetFn mirrors Button.lua's BTVButtonMixin.OnMouseWheel's
-- step/delta convention (arg1 = scroll delta, positive = up/away),
-- applied to scale instead of buttonSize. Current scale is read directly
-- off `container:GetScale()` rather than a separate getter parameter,
-- since every scale setter (SetBagBarScale/SetMicroMenuScale/
-- SetStanceBarScale/SetLatencyBarScale/SetKeyRingScale) already calls
-- SetScale on this exact frame as its last step.
--
-- level defaults to 100. Same-strata frames on this client are NOT
-- reliably ordered by creation order, only by explicit FrameLevel -
-- overlays that visually overlap on screen (e.g. Key Ring's native
-- default position sits against/inside the Bag Bar container's own
-- bounding box) need distinct levels or the z-order winner is undefined.
--
-- Overlay is parented to UIParent, not `container`: Key Ring/Latency Bar
-- wrap real native frames (KeyRingButton/MainMenuBarPerformanceBarFrame)
-- deep inside Blizzard's own FrameXML ancestor chain, not UIParent-direct
-- children - parenting the overlay to them would compare its FrameLevel
-- within a different ancestor tree than every sibling overlay it competes
-- against on screen. SetAllPoints(container)/SetPoint anchoring still
-- tracks the real frame's live position/size regardless of parent.
-- Because the overlay is no longer a child of the real frame, hiding the
-- real frame alone no longer implicitly hides the overlay too - see
-- SetKeyRingEnabled/SetLatencyBarEnabled below for the explicit
-- overlay:Hide() this requires.
local function EnsureContainerOverlay(container, startDragFn, stopDragFn, settingsKey, scaleSetFn, level, displayName)
	if container.btvOverlay then
		return container.btvOverlay
	end

	local overlay = CreateFrame("Frame", nil, UIParent)

	overlay:SetFrameStrata("TOOLTIP")
	overlay:SetFrameLevel(level or 100)

	-- For a chain-anchored container (Bag Bar/Micro Menu/Stance Bar -
	-- container.chainButtons exists), anchors directly to the real
	-- first/last currently-shown button instead of SetAllPoints(container)
	-- - see ApplyChainAnchoredShape's own matching anchor below.
	-- GetChainShownEndpoints gives a correct anchor even before
	-- ApplyChainAnchoredShape has ever run; ApplyChainAnchoredShape
	-- re-applies the same anchor on every later spacing/orientation/scale/
	-- visibility change. Every other container kind (Key Ring/Latency
	-- Bar/Exp Bar's wrapped native frames, Page Indicator) has no
	-- chainButtons and keeps the SetAllPoints(container) anchor.
	local chainFirst, chainLast = GetChainShownEndpoints(container)

	if chainFirst and chainLast then
		-- Trimmed by each endpoint's own hit-rect inset, same formula as
		-- ApplyChainAnchoredShape's own matching overlay anchor below (see
		-- GetHitInsets' comment above for the Micro Menu case). Converted
		-- through ScaleRatio since `overlay` and the buttons don't share an
		-- effective scale once the container's own Scale slider is
		-- anything but 1, plus container.overlayTopFudge (Micro Menu only
		-- - see BTV.MICRO_MENU_OVERLAY_TOP_FUDGE's comment, Core.lua) for
		-- the small extra sliver GetHitRectInsets alone doesn't cover.
		local firstLeft, firstRight, firstTop, firstBottom = GetHitInsets(chainFirst)
		local lastLeft, lastRight, lastTop, lastBottom = GetHitInsets(chainLast)
		local firstRatio = ScaleRatio(chainFirst, overlay)
		local lastRatio = ScaleRatio(chainLast, overlay)
		local topFudge = container.overlayTopFudge or 0

		overlay:SetPoint("TOPLEFT", chainFirst, "TOPLEFT", firstLeft * firstRatio, -(firstTop + topFudge) * firstRatio)
		overlay:SetPoint("BOTTOMRIGHT", chainLast, "BOTTOMRIGHT", -lastRight * lastRatio, lastBottom * lastRatio)
	else
		overlay:SetAllPoints(container)
	end

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	tex:SetAllPoints(overlay)

	-- Hover border + centered element-name label, mirroring Bar.lua's own
	-- EnsureBarOverlay treatment, against a chain-anchored container/
	-- single native frame instead of a bar-pool frame. displayName is
	-- passed explicitly per call site below rather than derived from
	-- settingsKey, since settingsKey doesn't uniquely identify an element
	-- here (Key Ring's settingsKey is "bagbar" - it shares Bag Bar's
	-- settings page - and Page Indicator's is the numeric Main Bar id 1,
	-- since it has no page of its own).
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

	if displayName then
		local nameText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		nameText:SetPoint("CENTER", overlay, "CENTER", 0, 0)
		nameText:SetText(displayName)
	end

	overlay:RegisterForDrag("LeftButton")
	overlay:SetScript("OnDragStart", function()
		startDragFn(BTV)
	end)
	overlay:SetScript("OnDragStop", function()
		stopDragFn(BTV)
	end)

	overlay:SetScript("OnMouseUp", function()
		if arg1 == "RightButton" then
			BTV:OpenBarSettingsByKey(settingsKey)
		end
	end)

	-- Scroll-to-scale, gated the same way Button.lua's
	-- BTVButtonMixin.OnMouseWheel gates scroll-to-resize for custom bars
	-- (edit mode required). This overlay is only ever mouse-enabled during
	-- that same CanDragDefaultLayout() window (ApplyContainerOverlayVisual
	-- below), but the explicit check keeps this self-contained rather than
	-- relying solely on EnableMouse(false) elsewhere.
	overlay:EnableMouseWheel(true)
	overlay:SetScript("OnMouseWheel", function()
		if not scaleSetFn then
			return
		end

		if not BTV:CanDragDefaultLayout() then
			return
		end

		local delta = arg1 or 0
		local step = 0.1
		local current = container:GetScale() or 1

		scaleSetFn(BTV, current + (delta * step))
	end)

	overlay:EnableMouse(false)
	overlay:Hide()

	container.btvOverlay = overlay

	return overlay
end

-- Shows/hides + toggles mouse on a Bag Bar/Micro Menu overlay - called
-- from ApplyDefaultLayoutEditVisual below. `enabledFlag` is the
-- element's own BTVanillaDB.bagBarEnabled/microMenuEnabled (unlike the
-- stance bar/bar 1, these CAN be meaningfully disabled - see
-- SetBagBarEnabled/SetMicroMenuEnabled below), `show` is
-- BTV:CanDragDefaultLayout()'s result - mirrors the same
-- enabled-AND-shown gating `ApplyDefaultLayoutEditVisual` applies to
-- default bars 2-5 directly.
local function ApplyContainerOverlayVisual(container, enabledFlag, show)
	if not container or not container.btvOverlay then
		return
	end

	local overlay = container.btvOverlay
	local interactive = show and (enabledFlag ~= false)

	overlay:EnableMouse(interactive and true or false)

	if interactive then
		overlay:Show()

		-- Resets the hover border every time the overlay is (re-)shown,
		-- matching Bar.lua's own ApplyEditModeVisual.
		overlay:SetBackdropBorderColor(0, 0, 0, 0)
	else
		overlay:Hide()
	end
end

-------------------------------------------------------------------------
-- Bag Bar position/enable
-------------------------------------------------------------------------

-- Applies BTVanillaDB.bagBarPosition to the real container, and ensures
-- its overlay exists. Unlike a single real native frame (e.g. Key Ring/
-- Latency Bar below), this synthetic container has no independent
-- existence outside this addon to self-heal from - it's simply assumed
-- CreateBagBarAndMicroMenu has already run and seeded bagBarPosition by
-- the time this is called.
function BTV:ApplyBagBarPosition()
	local pos = BTVanillaDB.bagBarPosition
	local container = self.bagBarContainer

	if not pos or not container then
		return
	end

	container:ClearAllPoints()
	PixelSetPoint(
		container,
		pos.point or "TOPLEFT",
		UIParent,
		pos.relativePoint or "BOTTOMLEFT",
		pos.x or 0,
		pos.y or 0
	)

	EnsureContainerOverlay(container, self.StartBagBarDrag, self.StopBagBarDrag, "bagbar", self.SetBagBarScale, nil, "Bag Bar")
end

-- Settings.lua's Bag Bar page X/Y sliders write through this.
function BTV:SetBagBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not BTVanillaDB.bagBarPosition then
		return
	end

	BTVanillaDB.bagBarPosition.x = x
	BTVanillaDB.bagBarPosition.y = y

	self:ApplyBagBarPosition()
end

-- Settings.lua's Bag Bar page "Reset to Blizzard Default" button.
function BTV:ResetBagBarPosition()
	local native = BTVanillaDB.bagBarNativeAnchor

	if not native then
		return
	end

	BTVanillaDB.bagBarPosition = {
		point = native.point,
		relativePoint = native.relativePoint,
		x = native.x,
		y = native.y,
	}

	self:ApplyBagBarPosition()
end

-- Settings.lua's Bag Bar page enable checkbox (and its bar-list inline
-- checkbox). Unlike default bars 2-5 (SetDefaultBarEnabled), there's no
-- fixed-slot replica/native-hide distinction to branch on here - the
-- container's own Show()/Hide() cascades to every real child button,
-- which is the sole visibility mechanism for this element.
function BTV:SetBagBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	BTVanillaDB.bagBarEnabled = enabled

	if self.bagBarContainer then
		if enabled then
			self.bagBarContainer:Show()
		else
			self.bagBarContainer:Hide()

			-- EnsureContainerOverlay's overlay is parented to UIParent, not
			-- this container, so hiding the container doesn't cascade to
			-- hide the overlay too.
			if self.bagBarContainer.btvOverlay then
				self.bagBarContainer.btvOverlay:Hide()
				self.bagBarContainer.btvOverlay:EnableMouse(false)
			end
		end
	end
end

-- Re-lays-out the Bag Bar's real buttons from its current saved
-- spacing/orientation/scale, via the shared ApplyChainAnchoredShape
-- helper above. A no-op until CreateBagBarAndMicroMenu has built the
-- container (ApplyChainAnchoredShape's own container.chainButtons
-- nil-check).
function BTV:ApplyBagBarShape()
	self:EnsureDB()

	ApplyChainAnchoredShape(
		self.bagBarContainer,
		BTVanillaDB.bagBarSpacing or 0,
		BTVanillaDB.bagBarOrientation == true,
		BTVanillaDB.bagBarScale or 1
	)
end

-- Mirrors SetDefaultBarSpacing's exact clamp/write/reapply template
-- (DefaultBars.lua) - same 0-20 range, matching the Settings UI's shared
-- SPACING_MIN/MAX constants.
function BTV:SetBagBarSpacing(spacing)
	self:EnsureDB()

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

	BTVanillaDB.bagBarSpacing = spacing

	self:ApplyBagBarShape()
end

-- Same clamp/write/reapply template, rounded to the nearest 0.1 (the
-- Settings slider's step) instead of an integer pixel - Scale is a
-- proportional multiplier, not a pixel quantity.
function BTV:SetBagBarScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.bagBarScale = scale

	self:ApplyBagBarShape()
end

-- Orientation is a plain boolean toggle (true = vertical/swapped) - no
-- clamping needed, unlike Spacing/Scale above.
function BTV:SetBagBarOrientation(vertical)
	self:EnsureDB()

	BTVanillaDB.bagBarOrientation = vertical and true or false

	self:ApplyBagBarShape()
end

-- Settings.lua's Bag Bar page reset flow calls this alongside
-- ResetBagBarPosition (simpleBarPageConfigs["bagbar"].reset) - restores
-- spacing/scale/orientation to their native baseline (bagBarNativeSpacing,
-- 1, false), mirroring ResetDefaultBarLayout's own nativeSpacing restore
-- for default bars.
function BTV:ResetBagBarLayout()
	self:EnsureDB()

	BTVanillaDB.bagBarSpacing = BTVanillaDB.bagBarNativeSpacing or 0
	BTVanillaDB.bagBarScale = 1
	BTVanillaDB.bagBarOrientation = false

	self:ApplyBagBarShape()
end

function BTV:StartBagBarDrag()
	local pos = BTVanillaDB.bagBarPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "bagBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopBagBarDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("bagbar")
	end
end

-------------------------------------------------------------------------
-- Micro Menu position/enable - mirrors the Bag Bar block above exactly.
-------------------------------------------------------------------------

function BTV:ApplyMicroMenuPosition()
	local pos = BTVanillaDB.microMenuPosition
	local container = self.microMenuContainer

	if not pos or not container then
		return
	end

	container:ClearAllPoints()
	PixelSetPoint(
		container,
		pos.point or "TOPLEFT",
		UIParent,
		pos.relativePoint or "BOTTOMLEFT",
		pos.x or 0,
		pos.y or 0
	)

	EnsureContainerOverlay(container, self.StartMicroMenuDrag, self.StopMicroMenuDrag, "micromenu", self.SetMicroMenuScale, nil, "Micro Menu")
end

function BTV:SetMicroMenuPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not BTVanillaDB.microMenuPosition then
		return
	end

	BTVanillaDB.microMenuPosition.x = x
	BTVanillaDB.microMenuPosition.y = y

	self:ApplyMicroMenuPosition()
end

function BTV:ResetMicroMenuPosition()
	local native = BTVanillaDB.microMenuNativeAnchor

	if not native then
		return
	end

	BTVanillaDB.microMenuPosition = {
		point = native.point,
		relativePoint = native.relativePoint,
		x = native.x,
		y = native.y,
	}

	self:ApplyMicroMenuPosition()
end

function BTV:SetMicroMenuEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	BTVanillaDB.microMenuEnabled = enabled

	if self.microMenuContainer then
		if enabled then
			self.microMenuContainer:Show()
		else
			self.microMenuContainer:Hide()

			-- Same explicit-hide requirement as SetBagBarEnabled above.
			if self.microMenuContainer.btvOverlay then
				self.microMenuContainer.btvOverlay:Hide()
				self.microMenuContainer.btvOverlay:EnableMouse(false)
			end
		end
	end
end

-- Mirrors BTV:ApplyBagBarShape exactly - see its own comment above.
function BTV:ApplyMicroMenuShape()
	self:EnsureDB()

	ApplyChainAnchoredShape(
		self.microMenuContainer,
		BTVanillaDB.microMenuSpacing or 0,
		BTVanillaDB.microMenuOrientation == true,
		BTVanillaDB.microMenuScale or 1
	)
end

function BTV:SetMicroMenuSpacing(spacing)
	self:EnsureDB()

	spacing = tonumber(spacing)

	if not spacing then
		return
	end

	spacing = math.floor(spacing + 0.5)

	-- Floor is -10, not 0, unlike every other chain-anchored container's
	-- spacing setter: Micro Menu's real native buttons have a measured
	-- native gap of 0 but still show a small visible gap at spacing=0,
	-- since the buttons' own native art has padding inside their nominal
	-- frame bounds that spacing alone can't remove - only a slight overlap
	-- (negative spacing) compensates for that.
	if spacing < -10 then
		spacing = -10
	end

	if spacing > 20 then
		spacing = 20
	end

	BTVanillaDB.microMenuSpacing = spacing

	self:ApplyMicroMenuShape()
end

function BTV:SetMicroMenuScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.microMenuScale = scale

	self:ApplyMicroMenuShape()
end

function BTV:SetMicroMenuOrientation(vertical)
	self:EnsureDB()

	BTVanillaDB.microMenuOrientation = vertical and true or false

	self:ApplyMicroMenuShape()
end

-- Settings.lua's Micro Menu page reset flow calls this alongside
-- ResetMicroMenuPosition (simpleBarPageConfigs["micromenu"].reset).
function BTV:ResetMicroMenuLayout()
	self:EnsureDB()

	BTVanillaDB.microMenuSpacing = BTVanillaDB.microMenuNativeSpacing or 0
	BTVanillaDB.microMenuScale = 1
	BTVanillaDB.microMenuOrientation = false

	self:ApplyMicroMenuShape()
end

function BTV:StartMicroMenuDrag()
	local pos = BTVanillaDB.microMenuPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "microMenu"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopMicroMenuDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("micromenu")
	end
end

-------------------------------------------------------------------------
-- Build both containers (called once at PLAYER_LOGIN, Core.lua)
--
-- Idempotent via self.bagBarContainer/microMenuContainer nil-checks -
-- safe to call more than once, but only ever meaningfully builds each
-- container the first time. Degrades gracefully (that element simply
-- isn't built this session) if any of its real button frames are
-- missing - same tolerance as CreateFixedSlotDefaultBars' fixedActionSlots
-- discovery failure.
-------------------------------------------------------------------------

function BTV:CreateBagBarAndMicroMenu()
	self:EnsureDB()

	if not self.bagBarContainer then
		local buttons = GetButtonsByName(self.BAG_BAR_BUTTON_NAMES)

		if buttons then
			SortButtonsByNativeLeft(buttons)

			local container, nativeLeft, nativeTop, nativeSpacing =
				BuildChainAnchoredContainer("BTVanillaBagBarContainer", buttons)

			self.bagBarContainer = container
			self.bagBarButtons = buttons

			-- Same TOPLEFT/BOTTOMLEFT-of-UIParent convention as Core.lua's
			-- CaptureNativeAnchor - nativeLeft/nativeTop here are already
			-- the real-screen-pixel-converted values
			-- BuildChainAnchoredContainer returns, not a raw
			-- GetLeft()/GetTop() copy, so no further translation is needed.
			if not BTVanillaDB.bagBarNativeAnchor then
				BTVanillaDB.bagBarNativeAnchor = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			if not BTVanillaDB.bagBarPosition then
				BTVanillaDB.bagBarPosition = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			-- Permanent pristine spacing snapshot, mirroring
			-- bagBarNativeAnchor above - captured once via
			-- ComputeMajorityGap (BuildChainAnchoredContainer), never
			-- re-derived afterward.
			if not BTVanillaDB.bagBarNativeSpacing then
				BTVanillaDB.bagBarNativeSpacing = nativeSpacing
			end

			if not BTVanillaDB.bagBarSpacing then
				BTVanillaDB.bagBarSpacing = nativeSpacing
			end

			-- Lays out the chain from the (freshly seeded, or previously
			-- saved) spacing/orientation/scale before ApplyBagBarPosition
			-- below, so the container's real size is already correct by
			-- the time the print below reads GetWidth()/GetHeight().
			self:ApplyBagBarShape()

			self:ApplyBagBarPosition()
			self:SetBagBarEnabled(BTVanillaDB.bagBarEnabled ~= false)

			-- Reports the captured native size/spacing to chat once,
			-- mirroring seedDefaultBars' own capture print (Core.lua).
			self:Print(
				"Bag Bar captured: " .. tostring(container:GetWidth()) ..
				"x" .. tostring(container:GetHeight()) ..
				" (native anchor x=" .. tostring(nativeLeft) ..
				", y=" .. tostring(nativeTop) .. ")"
			)
		end
	end

	if not self.microMenuContainer then
		local buttons = GetButtonsByName(self.MICRO_MENU_BUTTON_NAMES)

		if buttons then
			SortButtonsByNativeLeft(buttons)

			local container, nativeLeft, nativeTop, nativeSpacing =
				BuildChainAnchoredContainer("BTVanillaMicroMenuContainer", buttons)

			self.microMenuContainer = container
			self.microMenuButtons = buttons

			-- Extra top-only overlay trim beyond the buttons' own real
			-- GetHitRectInsets() - see BTV.MICRO_MENU_OVERLAY_TOP_FUDGE's
			-- own comment (Core.lua). Read generically by
			-- EnsureContainerOverlay/ApplyChainAnchoredShape's overlay
			-- anchors via container.overlayTopFudge (nil/0 for every other
			-- chain-anchored container - Bag Bar, Stance Bar).
			container.overlayTopFudge = self.MICRO_MENU_OVERLAY_TOP_FUDGE

			if not BTVanillaDB.microMenuNativeAnchor then
				BTVanillaDB.microMenuNativeAnchor = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			if not BTVanillaDB.microMenuPosition then
				BTVanillaDB.microMenuPosition = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			if not BTVanillaDB.microMenuNativeSpacing then
				BTVanillaDB.microMenuNativeSpacing = nativeSpacing
			end

			if not BTVanillaDB.microMenuSpacing then
				BTVanillaDB.microMenuSpacing = nativeSpacing
			end

			self:ApplyMicroMenuShape()

			self:ApplyMicroMenuPosition()
			self:SetMicroMenuEnabled(BTVanillaDB.microMenuEnabled ~= false)

			self:Print(
				"Micro Menu captured: " .. tostring(container:GetWidth()) ..
				"x" .. tostring(container:GetHeight()) ..
				" (native anchor x=" .. tostring(nativeLeft) ..
				", y=" .. tostring(nativeTop) .. ")"
			)
		end
	end
end

-- UpdateMicroButtons is real vanilla FrameXML's own global function
-- (MainMenuBarMicroButtons.lua) that decides TalentMicroButton's (and any
-- other conditionally-hidden micro button's) Show()/Hide() state.
-- Hooking it directly, rather than each individual native event, means
-- this addon reacts at exactly the moment Blizzard's own code changes a
-- button's shown state. hooksecurefunc runs after the native handler has
-- already called Show()/Hide(), so ApplyMicroMenuShape's IsShown() checks
-- see the new state immediately. No-ops if microMenuContainer hasn't been
-- built yet this session.
if hooksecurefunc and UpdateMicroButtons then
	hooksecurefunc("UpdateMicroButtons", function()
		BTV:ApplyMicroMenuShape()
	end)
end

-------------------------------------------------------------------------
-- Stance Bar (chain-anchored container)
--
-- Uses the same chain-anchored-container technique as Bag Bar/Micro Menu
-- above: real ShapeshiftButton# frames are reparented into our own
-- synthetic container and chain-anchored via ApplyChainAnchoredShape,
-- keeping their native shapeshift-form rendering (icon/cooldown/
-- active-form glow) entirely intact.
--
-- Unlike Bag Bar/Micro Menu, the Stance Bar's button count is
-- class/talent-driven (BTV:GetStanceBarButtons' GetNumShapeshiftForms()
-- based enumeration above), not a fixed 5/8 - RebuildStanceBarContainer
-- below re-enumerates and updates the container's chain in place whenever
-- that count can change, instead of only ever building once.
-------------------------------------------------------------------------

-- Captures the real, permanent vertical clearance vanilla leaves between
-- whichever default bar (1 or 2) is topmost and the Stance Bar's own real
-- native ShapeshiftBarFrame - captured once, while ShapeshiftBarFrame is
-- still queryable at its true native position. This addon only ever
-- reparents its buttons (ShapeshiftButton1-N, into our own container,
-- below); the ShapeshiftBarFrame frame itself is never moved, so it keeps
-- reporting its real native GetBottom() for as long as we read it here.
--
-- referenceY is whichever of bar 1/bar 2's own nativeAnchor.y
-- ShapeshiftBarFrame is currently sitting above - bar 2 if cfg2.enabled
-- is true at this exact moment, else bar 1 (same selection rule
-- GetStanceBarBaselineY itself uses below). The gap is stored as a single
-- state-independent constant, since vanilla leaves the same fixed
-- clearance above whichever bar is topmost.
--
-- Lazy-capture-once, guarded on BTVanillaDB.stanceBarNativeGap already
-- being present - same idiom as stanceBarNativeAnchor/stanceBarNativeSpacing.
--
-- Must run before BTV:CreateFixedSlotDefaultBars() (Core.lua's
-- RunLoginSequence calls it first) - CreateFixedSlotDefaultBars
-- permanently hides bar 2's real MultiBarBottomLeftButton1-12 frames,
-- which triggers vanilla FrameXML's own ShapeshiftBar_UpdatePosition()
-- side effect and collapses ShapeshiftBarFrame's real anchor before this
-- capture can read its true native position. The call from
-- CreateStanceBarContainer (below) is kept as a harmless no-op safety net
-- for any path that reaches here without the early call having run.
function BTV:CaptureStanceBarNativeGap()
	if BTVanillaDB.stanceBarNativeGap then
		return
	end

	local frame = ShapeshiftBarFrame

	if not frame then
		return
	end

	local bottom = frame:GetBottom()

	if not bottom then
		return
	end

	local frameScale = frame:GetEffectiveScale()
	local targetScale = UIParent:GetEffectiveScale()

	if not frameScale or not targetScale or targetScale == 0 then
		return
	end

	local screenBottom = (bottom * frameScale) / targetScale

	local defaults = BTVanillaDB.defaultBars
	local cfg1 = defaults and defaults[1]
	local cfg2 = defaults and defaults[2]

	local referenceY = cfg1 and cfg1.nativeAnchor and cfg1.nativeAnchor.y

	if cfg2 and cfg2.enabled and cfg2.nativeAnchor then
		referenceY = cfg2.nativeAnchor.y
	end

	if not referenceY then
		return
	end

	local gap = screenBottom - referenceY

	-- A real inter-row gap here is never negative (that would mean the
	-- Stance Bar overlaps its reference bar's top edge) and never
	-- anywhere near a full button's size (the real value is ~5 - see
	-- GetStanceBarBaselineY's own comment below). A value outside this
	-- range means the read above hit a corrupted/unreflowed frame - never
	-- persist a bad read, so an earlier or later good capture is never
	-- overwritten, and GetStanceBarBaselineY's own `or 5` fallback covers
	-- the gap until a good capture lands.
	if gap <= 0 or gap >= self.BUTTON_SIZE then
		self:Print(
			"WARNING: Stance Bar native gap capture produced an implausible " ..
			"value (" .. tostring(gap) .. ") and was discarded - falling back " ..
			"to a default clearance until a later capture succeeds."
		)
		return
	end

	BTVanillaDB.stanceBarNativeGap = gap
end

-- Builds the Stance Bar's synthetic container the first time this session
-- there are any active stance/form buttons to show - mirrors
-- CreateBagBarAndMicroMenu's per-element structure exactly (native anchor/
-- spacing captured ONCE here, permanent baseline, never re-derived
-- afterward - same "capture, don't guess" rule as every other element in
-- this file). A no-op (and NOT an error) if GetNumShapeshiftForms() is 0
-- right now (a class with no stance mechanic, or a class that simply
-- hasn't learned one yet) - RebuildStanceBarContainer (below) is what
-- calls this again later, on UPDATE_SHAPESHIFT_FORMS, once forms actually
-- become available.
function BTV:CreateStanceBarContainer()
	self:EnsureDB()

	if self.stanceBarContainer then
		return
	end

	local buttons = self:GetStanceBarButtons()

	if not buttons then
		return
	end

	-- The real capture happens earlier, from Core.lua's RunLoginSequence,
	-- before CreateFixedSlotDefaultBars() runs (see
	-- CaptureStanceBarNativeGap's own comment) - this call is a harmless
	-- no-op safety net, guarded on stanceBarNativeGap already being set.
	self:CaptureStanceBarNativeGap()

	SortButtonsByNativeLeft(buttons)

	local container, nativeLeft, nativeTop, nativeSpacing =
		BuildChainAnchoredContainer("BTVanillaStanceBarContainer", buttons)

	self.stanceBarContainer = container
	self.stanceBarButtons = buttons

	if not BTVanillaDB.stanceBarNativeAnchor then
		BTVanillaDB.stanceBarNativeAnchor = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	if not BTVanillaDB.stanceBarPosition then
		BTVanillaDB.stanceBarPosition = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	if not BTVanillaDB.stanceBarNativeSpacing then
		BTVanillaDB.stanceBarNativeSpacing = nativeSpacing
	end

	if not BTVanillaDB.stanceBarSpacing then
		BTVanillaDB.stanceBarSpacing = nativeSpacing
	end

	self:ApplyStanceBarShape()

	self:ApplyStanceBarPosition()
	self:SetStanceBarEnabled(BTVanillaDB.stanceBarEnabled ~= false)

	self:Print(
		"Stance Bar captured: " .. tostring(container:GetWidth()) ..
		"x" .. tostring(container:GetHeight()) ..
		" (native anchor x=" .. tostring(nativeLeft) ..
		", y=" .. tostring(nativeTop) .. ")"
	)
end

-- Called from UPDATE_SHAPESHIFT_FORMS (below) any time the set of
-- available forms can have changed (talent respec, zone-granted stance,
-- etc.). If the container doesn't exist yet, this is just
-- CreateStanceBarContainer's job instead (e.g. the very first time a
-- freshly-rolled Druid learns Bear Form). If it already exists, this
-- updates its chain IN PLACE - re-enumerating the active buttons,
-- reparenting any newly-active ones (previously-active ones are already
-- parented from an earlier build/rebuild), and re-running
-- ApplyChainAnchoredShape - rather than tearing down and recreating the
-- container, so the user's saved position/spacing/scale/orientation are
-- never touched by a rebuild.
function BTV:RebuildStanceBarContainer()
	self:EnsureDB()

	local buttons = self:GetStanceBarButtons()

	if not buttons then
		-- A class that had forms and lost every one of them (rare, but
		-- possible via a talent respec) - hide rather than destroy the
		-- container, since it may become active again later this session.
		if self.stanceBarContainer then
			self.stanceBarContainer:Hide()
			self.stanceBarContainer.chainButtons = {}
			self.stanceBarContainer.chainWidths = {}
			self.stanceBarContainer.chainHeights = {}
		end

		return
	end

	local container = self.stanceBarContainer

	if not container then
		self:CreateStanceBarContainer()
		return
	end

	local widths, heights = {}, {}
	local i

	for i = 1, table.getn(buttons) do
		if buttons[i]:GetParent() ~= container then
			buttons[i]:SetParent(container)
		end

		widths[i] = buttons[i]:GetWidth() or 36
		heights[i] = buttons[i]:GetHeight() or 36
	end

	container.chainButtons = buttons
	container.chainWidths = widths
	container.chainHeights = heights

	self.stanceBarButtons = buttons

	self:ApplyStanceBarShape()

	if BTVanillaDB.stanceBarEnabled ~= false then
		container:Show()
	end
end

-- Applies BTVanillaDB.stanceBarPosition to the container, and ensures its
-- drag/right-click overlay exists - mirrors ApplyBagBarPosition exactly.
function BTV:ApplyStanceBarPosition()
	local pos = BTVanillaDB.stanceBarPosition
	local container = self.stanceBarContainer

	if not pos or not container then
		return
	end

	container:ClearAllPoints()
	PixelSetPoint(
		container,
		pos.point or "TOPLEFT",
		UIParent,
		pos.relativePoint or "BOTTOMLEFT",
		pos.x or 0,
		pos.y or 0
	)

	EnsureContainerOverlay(container, self.StartStanceBarDrag, self.StopStanceBarDrag, "stance", self.SetStanceBarScale, nil, "Stance Bar")
end

-- Settings.lua's Stance Bar page X/Y sliders write through this.
function BTV:SetStanceBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not BTVanillaDB.stanceBarPosition then
		return
	end

	BTVanillaDB.stanceBarPosition.x = x
	BTVanillaDB.stanceBarPosition.y = y

	self:ApplyStanceBarPosition()
end

-- Settings.lua's Stance Bar page "Reset to Blizzard Default" button.
function BTV:ResetStanceBarPosition()
	local native = BTVanillaDB.stanceBarNativeAnchor

	if not native then
		return
	end

	BTVanillaDB.stanceBarPosition = {
		point = native.point,
		relativePoint = native.relativePoint,
		x = native.x,
		y = native.y,
	}

	self:ApplyStanceBarPosition()
end

-- Settings.lua's Stance Bar page enable checkbox. The container's own
-- Show()/Hide() cascades to every real child stance button, exactly like
-- Bag Bar/Micro Menu's own SetBagBarEnabled/SetMicroMenuEnabled - no
-- fixed-slot-replica/native-hide distinction to branch on here either.
function BTV:SetStanceBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	BTVanillaDB.stanceBarEnabled = enabled

	if self.stanceBarContainer then
		if enabled then
			self.stanceBarContainer:Show()
		else
			self.stanceBarContainer:Hide()

			-- Same explicit-hide requirement as SetBagBarEnabled above.
			if self.stanceBarContainer.btvOverlay then
				self.stanceBarContainer.btvOverlay:Hide()
				self.stanceBarContainer.btvOverlay:EnableMouse(false)
			end
		end
	end
end

-- Computes the absolute Stance Bar top-edge Y (UIParent-bottom-left
-- origin, y increases upward - see Core.lua's CaptureNativeAnchor
-- comment) for a given bar-2 enabled state, computed fresh from
-- live-captured native baselines every time - never derived from
-- whatever BTVanillaDB.stanceBarPosition.y currently holds.
--
-- The Stance Bar's own footprint isn't the same size as a standard bar
-- row, so a standard row-to-row spacing constant is the wrong clearance
-- here. The correct relationship: SBF.bottom - referenceBar.top is a
-- fixed native gap constant (~5, captured once as
-- BTVanillaDB.stanceBarNativeGap - see CaptureStanceBarNativeGap above)
-- between the reference bar's top edge and the Stance Bar's own bottom
-- edge; SBF.top - SBF.bottom is the Stance Bar's own native occupied
-- height, read live from self.stanceBarContainer:GetHeight() so this
-- stays correct if the user scales the Stance Bar. So:
-- baselineY = referenceBar.top + gap + height.
--
-- referenceY is bar 2's own nativeAnchor.y if bar 2 is enabled, else
-- bar 1's.
function BTV:GetStanceBarBaselineY(bar2Enabled)
	local defaults = BTVanillaDB and BTVanillaDB.defaultBars
	local cfg1 = defaults and defaults[1]
	local cfg2 = defaults and defaults[2]

	local referenceY = cfg1 and cfg1.nativeAnchor and cfg1.nativeAnchor.y

	if bar2Enabled and cfg2 and cfg2.nativeAnchor then
		referenceY = cfg2.nativeAnchor.y
	end

	if not referenceY then
		return nil
	end

	local container = self.stanceBarContainer

	if not container then
		return nil
	end

	-- Falls back to a literal 5 only if the lazy capture above never ran
	-- (e.g. ShapeshiftBarFrame missing on some other client build) - every
	-- normal login captures the real value instead.
	local gap = BTVanillaDB.stanceBarNativeGap or 5

	return referenceY + gap + container:GetHeight()
end

-- Replicates real vanilla's ShapeshiftBar_UpdatePosition side effect
-- against the Stance Bar's own synthetic container, since the native call
-- against the real (now purely internal) ShapeshiftBarFrame no longer has
-- any visual effect post-migration.
--
-- Always an absolute, self-correcting recompute: pos.y is overwritten
-- with GetStanceBarBaselineY's fresh result for the current bar2Enabled
-- state, so this can never accumulate drift. Only x is left untouched -
-- horizontal alignment is not part of this vertical-stacking mechanism.
--
-- Only called while useDefaultLayout ~= false (SetDefaultBarEnabled's own
-- gate, and Core.lua's RunLoginSequence) - once the user has switched the
-- Stance Bar to manual positioning, this must never fight their own
-- dragged position.
function BTV:ReflowStanceBarForBar2Toggle(bar2Enabled)
	local pos = BTVanillaDB.stanceBarPosition
	local container = self.stanceBarContainer

	if not pos or not container then
		return
	end

	local y = self:GetStanceBarBaselineY(bar2Enabled)

	if not y then
		return
	end

	pos.y = y

	self:ApplyStanceBarPosition()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("stance")
	end
end

-- Re-lays-out the Stance Bar's real buttons from its CURRENT saved
-- spacing/orientation/scale, via the shared ApplyChainAnchoredShape helper
-- - mirrors BTV:ApplyBagBarShape exactly. A no-op until
-- CreateStanceBarContainer has built the container.
function BTV:ApplyStanceBarShape()
	self:EnsureDB()

	ApplyChainAnchoredShape(
		self.stanceBarContainer,
		BTVanillaDB.stanceBarSpacing or 0,
		BTVanillaDB.stanceBarOrientation == true,
		BTVanillaDB.stanceBarScale or 1
	)
end

-- Mirrors SetBagBarSpacing's exact clamp/write/reapply template.
function BTV:SetStanceBarSpacing(spacing)
	self:EnsureDB()

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

	BTVanillaDB.stanceBarSpacing = spacing

	self:ApplyStanceBarShape()
end

-- Mirrors SetBagBarScale's exact clamp/write/reapply template.
function BTV:SetStanceBarScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.stanceBarScale = scale

	self:ApplyStanceBarShape()
end

-- Orientation is a plain boolean toggle (true = vertical/swapped) - no
-- clamping needed, mirrors SetBagBarOrientation.
function BTV:SetStanceBarOrientation(vertical)
	self:EnsureDB()

	BTVanillaDB.stanceBarOrientation = vertical and true or false

	self:ApplyStanceBarShape()
end

-- Settings.lua's Stance Bar page reset flow calls this alongside
-- ResetStanceBarPosition (simpleBarPageConfigs["stance"].reset) - restores
-- spacing/scale/orientation to their native baseline, mirroring
-- ResetBagBarLayout.
function BTV:ResetStanceBarLayout()
	self:EnsureDB()

	BTVanillaDB.stanceBarSpacing = BTVanillaDB.stanceBarNativeSpacing or 0
	BTVanillaDB.stanceBarScale = 1
	BTVanillaDB.stanceBarOrientation = false

	self:ApplyStanceBarShape()
end

function BTV:StartStanceBarDrag()
	local pos = BTVanillaDB.stanceBarPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "stanceBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopStanceBarDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("stance")
	end
end

-- UPDATE_SHAPESHIFT_FORMS is real vanilla 1.12.1's own FrameXML event
-- (stock ShapeshiftBar.lua registers it and calls ShapeshiftBar_Update()
-- in response) - fires whenever the player's available stance/form set
-- changes, e.g. a talent respec unlocking a new form, or a zone/buff
-- granting/removing one.
local stanceFormEventFrame = CreateFrame("Frame", "BTVanillaStanceFormEventFrame")
stanceFormEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
stanceFormEventFrame:SetScript("OnEvent", function()
	BTV:RebuildStanceBarContainer()

	-- Stance/Page Bar Assignment feature, Part 2: the General panel's
	-- per-stance assignment rows are built from this same
	-- GetNumShapeshiftForms() count - re-sync them too if the panel
	-- already exists this session, so a mid-session talent respec that
	-- changes the player's stance count doesn't leave stale rows behind.
	if BTV.RebuildMainBarAssignmentRows then
		BTV:RebuildMainBarAssignmentRows()
	end
end)

-------------------------------------------------------------------------
-- Key Ring
--
-- KeyRingButton is confirmed to exist as a real global frame on this
-- client (not present in true vanilla 1.12.0, but present here).
-- SetPoint targets a frame, not a parent, so reparenting a bag button
-- into the Bag Bar's own synthetic container doesn't change what
-- KeyRingButton is anchored to - without independent management it would
-- visually ride along behind/underneath the Bag Bar container.
--
-- Deliberately not added to BAG_BAR_BUTTON_NAMES/the Bag Bar's own
-- chain - independently toggleable and independently positionable, not
-- just another chained member. It's a single real native button, not a
-- container we build, so it's repositioned directly via PixelSetPoint on
-- itself, the same "one real Blizzard frame, no chain-anchoring needed"
-- treatment ApplyStanceBarPosition uses for ShapeshiftBarFrame.
--
-- Every function below no-ops if KeyRingButton doesn't exist on some
-- other client build, matching every other optional-native-element
-- accessor in this file.
-------------------------------------------------------------------------

BTV.KEYRING_BUTTON_NAME = "KeyRingButton"

-- Mirrors CaptureLatencyBarPositionIfNeeded below exactly (GetLeft()/
-- GetTop() rather than GetPoint(), for the same "sidesteps whatever this
-- frame is really anchored to internally" reasoning) - captured lazily the
-- first time it's actually needed, never at normal EnsureDB seed time, since it
-- can only be read from the real live frame.
function BTV:CaptureKeyRingPositionIfNeeded()
	self:EnsureDB()

	if BTVanillaDB.keyRingPosition then
		return
	end

	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	if not frame then
		return
	end

	local left = frame:GetLeft()
	local top = frame:GetTop()

	if not left or not top then
		return
	end

	local anchor = {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = left,
		y = top,
	}

	BTVanillaDB.keyRingPosition = anchor

	-- Permanent pristine snapshot (Reset to Blizzard Default), mirroring
	-- bagBarNativeAnchor/stanceBarNativeAnchor exactly - captured ONCE,
	-- never written to again by anything else in this file.
	if not BTVanillaDB.keyRingNativeAnchor then
		BTVanillaDB.keyRingNativeAnchor = {
			point = anchor.point,
			relativePoint = anchor.relativePoint,
			x = anchor.x,
			y = anchor.y,
		}
	end
end

-- Applies BTVanillaDB.keyRingPosition to the real KeyRingButton, and
-- ensures its drag/right-click overlay exists - mirrors
-- ApplyBagBarPosition's structure, reusing EnsureContainerOverlay
-- directly against KeyRingButton itself (generic over any frame with its
-- own .btvOverlay cache, not specific to a synthetic container).
--
-- EnsureContainerOverlay is called unconditionally whenever `frame`
-- exists, not only when the native position capture also succeeded -
-- building the overlay only needs `frame` itself to exist (a real
-- always-present FrameXML global), independent of whether a saved/native
-- position is available yet.
function BTV:ApplyKeyRingPosition()
	self:CaptureKeyRingPositionIfNeeded()

	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	if not frame then
		return
	end

	-- Unlike Bag Bar/Micro Menu/Stance Bar/Page Indicator (all built on
	-- BuildChainAnchoredContainer, which already gives its synthetic
	-- container an explicit "HIGH" strata), KeyRingButton is a single real
	-- native Blizzard frame with no explicit strata of its own - it only
	-- rendered above MainMenuBarArtFrame by coincidence. Sets an explicit
	-- "HIGH" strata on every call (cheap/idempotent) so nothing can
	-- silently reset it back to a lower tier.
	frame:SetFrameStrata("HIGH")

	local pos = BTVanillaDB.keyRingPosition

	if pos then
		frame:ClearAllPoints()
		PixelSetPoint(
			frame,
			pos.point or "TOPLEFT",
			UIParent,
			pos.relativePoint or "BOTTOMLEFT",
			pos.x or 0,
			pos.y or 0
		)
	end

	-- level = 150, strictly above the 100 every other default-bar/
	-- chain-anchored-container overlay uses (see EnsureContainerOverlay's
	-- own comment) - Key Ring's native default position overlaps the Bag
	-- Bar container's own overlay, so this guarantees Key Ring's drag/
	-- right-click/scroll surface always wins that overlap.
	EnsureContainerOverlay(frame, self.StartKeyRingDrag, self.StopKeyRingDrag, "bagbar", self.SetKeyRingScale, 150, "Key Ring")
end

-- Settings.lua's Bag Bar page "Show Key Ring" checkbox writes through
-- this - independent of the Bag Bar's own enable flag (the checkbox
-- lives on the Bag Bar page, but this element moves/shows/hides
-- independently of the Bag Bar container itself).
function BTV:SetKeyRingEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	BTVanillaDB.keyRingEnabled = enabled

	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	if frame then
		if enabled then
			frame:Show()
		else
			frame:Hide()

			-- EnsureContainerOverlay's overlay is parented to UIParent, not
			-- `frame`, so hiding the real frame doesn't implicitly hide the
			-- overlay too - done explicitly here or a disabled-but-still-
			-- in-edit-mode Key Ring would leave a dangling, interactable
			-- drag/scroll hitbox floating where the (now invisible) button
			-- used to be.
			if frame.btvOverlay then
				frame.btvOverlay:Hide()
				frame.btvOverlay:EnableMouse(false)
			end
		end
	end
end

function BTV:SetKeyRingPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not BTVanillaDB.keyRingPosition then
		return
	end

	BTVanillaDB.keyRingPosition.x = x
	BTVanillaDB.keyRingPosition.y = y

	self:ApplyKeyRingPosition()
end

function BTV:ResetKeyRingPosition()
	local native = BTVanillaDB.keyRingNativeAnchor

	if native then
		BTVanillaDB.keyRingPosition = {
			point = native.point,
			relativePoint = native.relativePoint,
			x = native.x,
			y = native.y,
		}

		self:ApplyKeyRingPosition()
	end

	-- Scale is folded into this same reset entry point rather than a
	-- separate ResetKeyRingScale - every caller of ResetKeyRingPosition
	-- (Settings.lua's bagbar page reset button and its "Use Default
	-- Blizzard Layout" re-enable flow) expects one call to fully restore
	-- Key Ring to its native/default state, mirroring
	-- ResetLatencyBarLayout's own position+scale bundling.
	self:SetKeyRingScale(1)
end

-- Mirrors SetLatencyBarScale's exact clamp/write/apply template.
function BTV:SetKeyRingScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.keyRingScale = scale

	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	if frame then
		frame:SetScale(scale)
	end
end

function BTV:StartKeyRingDrag()
	self:CaptureKeyRingPositionIfNeeded()

	local pos = BTVanillaDB.keyRingPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "keyRing"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopKeyRingDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()
end

-------------------------------------------------------------------------
-- Latency Bar
--
-- MainMenuBarPerformanceBarFrame - confirmed real vanilla 1.12.1 frame
-- name - is a single self-contained frame (background texture + a hover-
-- tooltip button, MainMenuBarPerformanceBarFrameButton) and a direct
-- SIBLING of MainMenuBarArtFrame under MainMenuBar, NOT a child of it -
-- so BTV:ApplyBlizzardArtVisibility's region-hiding never touches it, and
-- it needs this fully independent enable/scale/position treatment,
-- structurally identical to the Stance Bar's own single-real-frame case
-- above (one native frame we don't own the shape of, not a container we
-- build).
-------------------------------------------------------------------------

BTV.LATENCY_BAR_FRAME_NAME = "MainMenuBarPerformanceBarFrame"

-- Mirrors CaptureKeyRingPositionIfNeeded above exactly.
function BTV:CaptureLatencyBarPositionIfNeeded()
	self:EnsureDB()

	if BTVanillaDB.latencyBarPosition then
		return
	end

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local left = frame:GetLeft()
	local top = frame:GetTop()

	if not left or not top then
		return
	end

	local anchor = {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = left,
		y = top,
	}

	BTVanillaDB.latencyBarPosition = anchor

	if not BTVanillaDB.latencyBarNativeAnchor then
		BTVanillaDB.latencyBarNativeAnchor = {
			point = anchor.point,
			relativePoint = anchor.relativePoint,
			x = anchor.x,
			y = anchor.y,
		}
	end
end

-- Applies BTVanillaDB.latencyBarPosition to the real frame, and ensures
-- its drag/right-click overlay exists - mirrors BTV:ApplyKeyRingPosition
-- above, just against MainMenuBarPerformanceBarFrame instead of
-- KeyRingButton (EnsureContainerOverlay is equally generic over either),
-- including the same "always build the overlay, only conditionally apply
-- the captured position" structure.
function BTV:ApplyLatencyBarPosition()
	self:CaptureLatencyBarPositionIfNeeded()

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local pos = BTVanillaDB.latencyBarPosition

	if pos then
		frame:ClearAllPoints()
		PixelSetPoint(
			frame,
			pos.point or "TOPLEFT",
			UIParent,
			pos.relativePoint or "BOTTOMLEFT",
			pos.x or 0,
			pos.y or 0
		)
	end

	EnsureContainerOverlay(frame, self.StartLatencyBarDrag, self.StopLatencyBarDrag, "latencybar", self.SetLatencyBarScale, nil, "Latency Bar")
end

function BTV:SetLatencyBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not BTVanillaDB.latencyBarPosition then
		return
	end

	BTVanillaDB.latencyBarPosition.x = x
	BTVanillaDB.latencyBarPosition.y = y

	self:ApplyLatencyBarPosition()
end

function BTV:SetLatencyBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	BTVanillaDB.latencyBarEnabled = enabled

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if frame then
		if enabled then
			frame:Show()
		else
			frame:Hide()

			-- Same explicit-hide requirement as SetKeyRingEnabled above.
			if frame.btvOverlay then
				frame.btvOverlay:Hide()
				frame.btvOverlay:EnableMouse(false)
			end
		end
	end
end

-- Mirrors SetStanceBarScale's exact clamp/write/apply template.
function BTV:SetLatencyBarScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.latencyBarScale = scale

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if frame then
		frame:SetScale(scale)
	end
end

-- Settings.lua's Latency Bar page "Reset to Blizzard Default" button -
-- restores position AND scale in one call (unlike the Stance Bar's own
-- two separate Reset* calls), since Settings.lua's simple-bar-page
-- config only ever wires one `reset` function per element.
function BTV:ResetLatencyBarLayout()
	local native = BTVanillaDB.latencyBarNativeAnchor

	if native then
		BTVanillaDB.latencyBarPosition = {
			point = native.point,
			relativePoint = native.relativePoint,
			x = native.x,
			y = native.y,
		}

		self:ApplyLatencyBarPosition()
	end

	self:SetLatencyBarScale(1)
end

function BTV:StartLatencyBarDrag()
	self:CaptureLatencyBarPositionIfNeeded()

	local pos = BTVanillaDB.latencyBarPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "latencyBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopLatencyBarDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("latencybar")
	end
end

-------------------------------------------------------------------------
-- Experience Bar
--
-- MainMenuExpBar - the real vanilla 1.12.1 FrameXML name for the
-- player's XP bar (a StatusBar) - is structurally the same kind of
-- element as MainMenuBarPerformanceBarFrame above: a single self-
-- contained real Blizzard frame whose own child regions/frames
-- (MainMenuBarOverlayFrame - itself owning the native "XP current / max"
-- FontString, see BTV:GetNativeExpOverlayText further below -,
-- ExhaustionLevelFillBar/ExhaustionTick/ExhaustionTickGlow for the
-- "rested" shaded portion) are all anchored relative to it, not
-- independently to UIParent - so repositioning/scaling this one frame
-- carries its whole native visual along, exactly like the Latency Bar.
--
-- Every accessor is defensively nil-checked via getglobal, so a name
-- that ever turns out wrong on some other client build just means this
-- container never builds (degrades exactly like a failed Bag Bar/Micro
-- Menu discovery), never a hard error.
--
-- Movable/scalable via the same single-real-frame EnsureContainerOverlay
-- treatment as the Latency Bar/Key Ring, always - independent of
-- BTVanillaDB.betterExpBarEnabled (the text overlay further below): this
-- container's own position/scale is unaffected by whether that text is
-- on or off.
-------------------------------------------------------------------------

BTV.EXP_BAR_FRAME_NAME = "MainMenuExpBar"

-- The native percent-of-level "XP current / max" label that
-- duplicates/overlaps BTV:ApplyBetterExpBarVisual's own text overlay
-- lives on a FontString region owned directly by MainMenuBarOverlayFrame
-- (a real child frame of MainMenuExpBar), not a separately-named global -
-- there is no MainMenuExpText global on this client. See
-- BTV:GetNativeExpOverlayText below, which resolves and caches that
-- FontString region (found by GetObjectType(), never a hardcoded region
-- index - GetRegions() ordering is that frame's own internal creation
-- order, not a documented/stable contract).
BTV.EXP_OVERLAY_FRAME_NAME = "MainMenuBarOverlayFrame"

-- Resolves MainMenuBarOverlayFrame's own native "XP current / max"
-- FontString region (see EXP_OVERLAY_FRAME_NAME's comment above for why
-- this replaces the old, nonexistent MainMenuExpText target), caching the
-- result on self once found - mirrors this same feature's own
-- self.betterExpBarText lazy-cache further below (BTV:ApplyBetterExpBarVisual),
-- just for a native region instead of one this addon creates itself.
function BTV:GetNativeExpOverlayText()
	if self.nativeExpOverlayText then
		return self.nativeExpOverlayText
	end

	local overlayFrame = getglobal(self.EXP_OVERLAY_FRAME_NAME)

	if not overlayFrame then
		return nil
	end

	local regions = { overlayFrame:GetRegions() }
	local i

	for i = 1, table.getn(regions) do
		local region = regions[i]

		if region and region.GetObjectType and region:GetObjectType() == "FontString" then
			self.nativeExpOverlayText = region
			return region
		end
	end

	return nil
end

-- Real vanilla FrameXML name for the native "how far the rested bonus
-- would carry the player" blue overlay - a region directly on
-- MainMenuExpBar. It's a Texture with a solid-color fill (GetTexture()
-- returns "Solid Texture"), not a StatusBar, so SetVertexColor/
-- GetVertexColor (not SetStatusBarColor/GetStatusBarColor) is the
-- correct color API for it. Every accessor that uses this name is
-- defensively nil/method-checked via getglobal, so a wrong/missing name
-- just means the rested-color picker silently has nothing to apply to.
BTV.EXP_RESTED_FRAME_NAME = "ExhaustionLevelFillBar"

-- Mirrors CaptureLatencyBarPositionIfNeeded/CaptureKeyRingPositionIfNeeded
-- structurally, but adds the real-screen-pixel GetEffectiveScale
-- conversion Core.lua's CaptureNativeAnchor uses: MainMenuExpBar is part
-- of the MainMenuBar cluster, which can have a different effective scale
-- than UIParent, so an unconverted capture would be wrong by that scale
-- factor.
function BTV:CaptureExpBarPositionIfNeeded()
	self:EnsureDB()

	if BTVanillaDB.expBarPosition then
		return
	end

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local left = frame:GetLeft()
	local top = frame:GetTop()

	if not left or not top then
		return
	end

	local buttonScale = frame:GetEffectiveScale()
	local uiParentScale = UIParent:GetEffectiveScale()

	local x, y = left, top

	if buttonScale and uiParentScale and uiParentScale ~= 0 then
		x = (left * buttonScale) / uiParentScale
		y = (top * buttonScale) / uiParentScale
	end

	local anchor = {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = x,
		y = y,
	}

	BTVanillaDB.expBarPosition = anchor

	-- Permanent pristine snapshot (Reset to Blizzard Default), mirroring
	-- latencyBarNativeAnchor/keyRingNativeAnchor exactly - captured ONCE,
	-- never written to again by anything else in this file.
	if not BTVanillaDB.expBarNativeAnchor then
		BTVanillaDB.expBarNativeAnchor = {
			point = anchor.point,
			relativePoint = anchor.relativePoint,
			x = anchor.x,
			y = anchor.y,
		}
	end
end

-- MainMenuXPBarTexture0-3 (the native race-themed border/end-cap art) are
-- real Texture regions owned directly by MainMenuExpBar, not
-- MainMenuBarArtFrame - they already follow MainMenuExpBar automatically
-- when this container repositions/rescales it.
--
-- Those pieces anchor their own "BOTTOM" point to MainMenuExpBar's
-- "BOTTOM" point at y=+3, leaving the real y=0-to-+3 strip of the frame
-- permanently uncovered by any native texture - only ever invisible
-- because MainMenuBarArtFrame's own art used to sit directly beneath it
-- at the bar's one fixed native screen position.
--
-- Covered by a custom-built gradient strip below rather than cloning the
-- native border texture - cloning MainMenuXPBarTexture0-3's
-- texture/GetTexCoord() has failed twice (rendered as a duplicated bar,
-- then as visibly distorted); do not retry that technique without
-- materially new information.
local function EnsureExpBarBottomBorderStrip(frame)
	if frame.btvBottomBorderStrip then
		return frame.btvBottomBorderStrip
	end

	-- "OVERLAY": must render on top of the bar's own StatusBar fill - the
	-- bar's native fill texture layer sits below OVERLAY, so drawing here
	-- keeps the strip visible over a full or near-full bar instead of
	-- being painted over by the fill.
	local strip = frame:CreateTexture(nil, "OVERLAY")
	strip:SetTexture("Interface\\Buttons\\WHITE8X8")

	-- BOTTOMLEFT/BOTTOMRIGHT dual anchor: pins the strip to exactly the
	-- bar's own current width and bottom edge, auto-tracking any width
	-- change (grid/layout edits) or BTV:SetExpBarScale rescale without
	-- this function needing to be re-run. A fixed height with only the
	-- bottom two corners anchored grows the texture upward from the bar's
	-- true bottom edge (y=0) - 4 units safely overshoots the 3-unit-tall
	-- y=0-to-+3 native gap.
	strip:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
	strip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	strip:SetHeight(4)

	-- SetGradientAlpha is a real vanilla 1.12 Texture method - a light-to-
	-- dark vertical fade over the flat WHITE8X8 base texture gives a
	-- subtle beveled look rather than a flat block of color. Guarded
	-- (rather than assumed present) since this exact method has no prior
	-- live confirmation on this client; a solid dark-gray SetVertexColor
	-- is the fallback so the strip is never left invisible/stark-white
	-- either way.
	if strip.SetGradientAlpha then
		strip:SetGradientAlpha("VERTICAL", 0.05, 0.05, 0.05, 0.85, 0.25, 0.25, 0.25, 0.55)
	else
		strip:SetVertexColor(0.12, 0.12, 0.12)
	end

	frame.btvBottomBorderStrip = strip

	return strip
end

-- Mirrors BTV:ApplyLatencyBarPosition exactly.
function BTV:ApplyExpBarPosition()
	self:CaptureExpBarPositionIfNeeded()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local pos = BTVanillaDB.expBarPosition

	if pos then
		frame:ClearAllPoints()
		PixelSetPoint(
			frame,
			pos.point or "TOPLEFT",
			UIParent,
			pos.relativePoint or "BOTTOMLEFT",
			pos.x or 0,
			pos.y or 0
		)
	end

	EnsureContainerOverlay(frame, self.StartExpBarDrag, self.StopExpBarDrag, "expbar", self.SetExpBarScale, nil, "Experience Bar")
	EnsureExpBarBottomBorderStrip(frame)
end

function BTV:SetExpBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not BTVanillaDB.expBarPosition then
		return
	end

	BTVanillaDB.expBarPosition.x = x
	BTVanillaDB.expBarPosition.y = y

	self:ApplyExpBarPosition()
end

-- Mirrors SetLatencyBarEnabled's exact structure - this is a core UI
-- element (default true, Core.lua's EnsureDB), but still independently
-- toggleable off, same as every other element in this family.
function BTV:SetExpBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	BTVanillaDB.expBarEnabled = enabled

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if frame then
		if enabled then
			frame:Show()

			-- Reverses the disable-branch's explicit
			-- frame.btvTextOverlay:Hide() below - unlike frame.btvOverlay
			-- (an edit-mode-only overlay, re-derived from
			-- ApplyContainerOverlayVisual on the next edit-mode sweep
			-- regardless), the text overlay is not edit-mode-gated -
			-- nothing else in this file would ever re-Show it on its own,
			-- so it must be re-shown here explicitly or the text would
			-- stay invisible forever after a disable/re-enable cycle.
			if frame.btvTextOverlay then
				frame.btvTextOverlay:Show()
			end
		else
			frame:Hide()

			-- Same explicit-hide requirement as SetKeyRingEnabled/
			-- SetLatencyBarEnabled above - EnsureContainerOverlay's overlay
			-- is parented to UIParent, not `frame`, so hiding the real frame
			-- alone doesn't cascade to hide the overlay too.
			if frame.btvOverlay then
				frame.btvOverlay:Hide()
				frame.btvOverlay:EnableMouse(false)
			end

			-- Same cascade problem, same fix, for the "Better Experience
			-- Bar" text's own overlay frame (EnsureExpBarTextOverlay,
			-- further below) - it's also parented to UIParent (not
			-- `frame`), so without this it would keep floating on screen
			-- at MainMenuExpBar's last tracked position even after the
			-- Experience Bar itself is disabled.
			if frame.btvTextOverlay then
				frame.btvTextOverlay:Hide()
			end
		end
	end
end

-- Mirrors SetLatencyBarScale/SetKeyRingScale's exact clamp/write/apply
-- template.
function BTV:SetExpBarScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.expBarScale = scale

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if frame then
		frame:SetScale(scale)
	end
end

-- Settings.lua's Experience Bar page "Reset to Blizzard Default" button -
-- restores position AND scale in one call, mirroring
-- BTV:ResetLatencyBarLayout exactly.
function BTV:ResetExpBarLayout()
	local native = BTVanillaDB.expBarNativeAnchor

	if native then
		BTVanillaDB.expBarPosition = {
			point = native.point,
			relativePoint = native.relativePoint,
			x = native.x,
			y = native.y,
		}

		self:ApplyExpBarPosition()
	end

	self:SetExpBarScale(1)
end

function BTV:StartExpBarDrag()
	self:CaptureExpBarPositionIfNeeded()

	local pos = BTVanillaDB.expBarPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "expBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopExpBarDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("expbar")
	end
end

-------------------------------------------------------------------------
-- Bar-fill colors
--
-- MainMenuExpBar's own StatusBar fill (the earned-XP progress, a purple/
-- violet in real vanilla) and ExhaustionLevelFillBar's own solid-color-fill
-- Texture (the native "how far the rested bonus would carry the player"
-- overlay, a blue in real vanilla) are each independently recolorable via
-- Settings.lua's color-picker swatches on the Experience Bar's own
-- settings page. Native baseline captured lazily from the real live
-- frames (mirrors CaptureExpBarPositionIfNeeded's own "capture once, real
-- live values only" idiom above) rather than seeded in Core.lua's
-- EnsureDB, since neither GetStatusBarColor() nor GetVertexColor() returns
-- meaningful values until these frames actually exist.
--
-- ExhaustionLevelFillBar is a Texture region, not a StatusBar - see
-- EXP_RESTED_FRAME_NAME's own comment above. Every read/write against it
-- below uses SetVertexColor/GetVertexColor accordingly; MainMenuExpBar
-- itself uses SetStatusBarColor/GetStatusBarColor, since it is a real
-- StatusBar.
-------------------------------------------------------------------------

function BTV:CaptureExpBarColorsIfNeeded()
	self:EnsureDB()

	if not BTVanillaDB.expBarColorEarned then
		local frame = getglobal(self.EXP_BAR_FRAME_NAME)
		local r, g, b

		if frame and frame.GetStatusBarColor then
			r, g, b = frame:GetStatusBarColor()
		end

		-- Fallback: a reasonable vanilla-matching purple/violet, only used
		-- if the live frame isn't available yet at capture time.
		BTVanillaDB.expBarColorEarned = {
			r = r or 0.58,
			g = g or 0.0,
			b = b or 0.55,
		}

		-- Permanent pristine snapshot ("Reset Colors to Default"), mirroring
		-- expBarNativeAnchor's own capture-once/never-rewritten pattern
		-- above.
		BTVanillaDB.expBarNativeColorEarned = {
			r = BTVanillaDB.expBarColorEarned.r,
			g = BTVanillaDB.expBarColorEarned.g,
			b = BTVanillaDB.expBarColorEarned.b,
		}
	end

	if not BTVanillaDB.expBarColorRested then
		local restedFrame = getglobal(self.EXP_RESTED_FRAME_NAME)
		local r, g, b

		-- Texture region, not a StatusBar - see EXP_RESTED_FRAME_NAME's own
		-- comment above.
		if restedFrame and restedFrame.GetVertexColor then
			r, g, b = restedFrame:GetVertexColor()
		end

		-- Fallback: real vanilla's own rested-bonus blue.
		BTVanillaDB.expBarColorRested = {
			r = r or 0.0,
			g = g or 0.39,
			b = b or 0.88,
		}

		BTVanillaDB.expBarNativeColorRested = {
			r = BTVanillaDB.expBarColorRested.r,
			g = BTVanillaDB.expBarColorRested.g,
			b = BTVanillaDB.expBarColorRested.b,
		}
	end
end

-- CaptureExpBarColorsIfNeeded is always called unconditionally - it only
-- reads the live frames to populate BTVanillaDB.expBarColorEarned/Rested
-- for the Settings page's swatch preview, never writes to the frame
-- itself, so it's harmless regardless of the toggle.
--
-- When the feature is off, this explicitly reverts both frames to their
-- captured native baseline (BTVanillaDB.expBarNativeColorEarned/
-- expBarNativeColorRested) rather than leaving them untouched, so
-- turning the feature off mid-session after a custom color was applied
-- actually restores the native color rather than just skipping future
-- changes.
--
-- Called from Core.lua's login sequence, the color-picker's live-preview
-- func/cancelFunc, the "Reset Colors to Default" button, and the "Enable
-- Better Experience Bar" checkbox's OnClick - safe to call
-- unconditionally from all of them, since this function is the single
-- choke point deciding whether anything happens and which color applies.
function BTV:ApplyExpBarColors()
	self:CaptureExpBarColorsIfNeeded()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)
	local restedFrame = getglobal(self.EXP_RESTED_FRAME_NAME)

	if not BTVanillaDB.betterExpBarEnabled then
		local nativeEarned = BTVanillaDB.expBarNativeColorEarned
		local nativeRested = BTVanillaDB.expBarNativeColorRested

		if frame and frame.SetStatusBarColor and nativeEarned then
			frame:SetStatusBarColor(nativeEarned.r, nativeEarned.g, nativeEarned.b)
		end

		-- Texture region, not a StatusBar - see EXP_RESTED_FRAME_NAME's own
		-- comment above.
		if restedFrame and restedFrame.SetVertexColor and nativeRested then
			restedFrame:SetVertexColor(nativeRested.r, nativeRested.g, nativeRested.b)
		end

		-- The custom rested-XP overlay (below) reuses this same
		-- expBarColorRested field, and must be kept in sync with every
		-- color change/revert this function handles.
		self:ApplyExpBarRestedOverlay()

		return
	end

	local earned = BTVanillaDB.expBarColorEarned

	if frame and frame.SetStatusBarColor and earned then
		frame:SetStatusBarColor(earned.r, earned.g, earned.b)
	end

	local rested = BTVanillaDB.expBarColorRested

	-- Texture region, not a StatusBar - see EXP_RESTED_FRAME_NAME's own
	-- comment above.
	if restedFrame and restedFrame.SetVertexColor and rested then
		restedFrame:SetVertexColor(rested.r, rested.g, rested.b)
	end

	self:ApplyExpBarRestedOverlay()
end

-- Settings.lua's color-picker swatches call these directly from
-- ColorPickerFrame.func/cancelFunc.
function BTV:SetExpBarColorEarned(r, g, b)
	self:CaptureExpBarColorsIfNeeded()

	BTVanillaDB.expBarColorEarned = { r = r, g = g, b = b }

	self:ApplyExpBarColors()
end

function BTV:SetExpBarColorRested(r, g, b)
	self:CaptureExpBarColorsIfNeeded()

	BTVanillaDB.expBarColorRested = { r = r, g = g, b = b }

	self:ApplyExpBarColors()
end

-- Settings.lua's "Reset Colors to Default" button.
function BTV:ResetExpBarColors()
	self:CaptureExpBarColorsIfNeeded()

	local nativeEarned = BTVanillaDB.expBarNativeColorEarned
	local nativeRested = BTVanillaDB.expBarNativeColorRested

	if nativeEarned then
		BTVanillaDB.expBarColorEarned = {
			r = nativeEarned.r,
			g = nativeEarned.g,
			b = nativeEarned.b,
		}
	end

	if nativeRested then
		BTVanillaDB.expBarColorRested = {
			r = nativeRested.r,
			g = nativeRested.g,
			b = nativeRested.b,
		}
	end

	self:ApplyExpBarColors()
end

-------------------------------------------------------------------------
-- Custom rested-XP overlay
--
-- Replaces reliance on ExhaustionLevelFillBar's own native width for the
-- visible rested-XP indicator - BTV:ApplyExpBarColors above still
-- recolors that native Texture (harmless, left in place) but its
-- width - computed entirely by native Blizzard code this addon has no
-- access to - degenerates to ~8 units wide whenever
-- UnitXP("player") + GetXPExhaustion() exceeds UnitXPMax("player") (a
-- large banked rested pool). Since the width itself is native-computed,
-- this can't be fixed by recoloring - a separate custom Texture region
-- is drawn on top instead.
--
-- Formula ported verbatim from BEB/BEB.lua's own
-- BEB.UpdateElement("BEBRestedXpBar")/"BEBXpBar" branches (read directly,
-- not reconstructed from guesswork) - BEB draws this exact same rested
-- overlay itself rather than using ExhaustionLevelFillBar at all, and
-- already handles the exceeds-max case correctly (fills the entire bar
-- remainder instead of the native element's broken ~8-unit width).
--
-- Gated on both BTVanillaDB.betterExpBarEnabled and GetRestState() == 1
-- (real vanilla API - 1 means "currently resting," e.g. in a city/inn,
-- gaining the rested bonus), matching BEB's own BEBRestedXpBar branch, so
-- this overlay only ever shows in the same circumstances BEB's reference
-- implementation would show its own. When the feature is off this stays
-- hidden and the bar looks fully native - the native ExhaustionLevelFillBar
-- element itself is untouched by this section (see BTV:ApplyExpBarColors
-- above).
--
-------------------------------------------------------------------------

local function EnsureExpBarRestedOverlay(frame)
	if frame.btvRestedOverlay then
		return frame.btvRestedOverlay
	end

	-- "ARTWORK": renders above MainMenuExpBar's own native StatusBar fill
	-- texture, one tier below "OVERLAY" so BTV:ApplyBetterExpBarVisual's
	-- own text FontString (created on "OVERLAY" further below) always
	-- stays on top of this overlay's fill instead of being obscured by it.
	local tex = frame:CreateTexture(nil, "ARTWORK")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")

	frame.btvRestedOverlay = tex

	return tex
end

-- Rested-XP boundary tick: ports both BEB's own custom art
-- (BEB/BEB-ExhaustionTicks.tga and BEB/BEB-ExhaustionTicksGlow.tga,
-- copied verbatim into this addon's own Textures/ folder - see
-- BEB_TICK_TEXTURE/BEB_TICK_GLOW_TEXTURE below) and its real multi-
-- level-crossing position/texcoord logic (the tick block in
-- BTV:ApplyExpBarRestedOverlay further below, ported from BEB/BEB.lua's
-- own BEB.UpdateElement "BEBRestedXpTick"/"BEBRestedXpTickGlow" branches).
--
-- BEB.TexturePath resolves its own texture names against
-- "Interface\AddOns\BEB\Textures\" - the Textures/ subfolder copies (not
-- the duplicate root-level .tga files also present in BEB/) are the ones
-- BEB's own code path actually loads, which is why those are the ones
-- copied here too.
--
-- Both are plain Texture regions (not child Frames the way BEB's own
-- BEBRestedXpTick/BEBRestedXpTickGlow are - both are already parented to
-- `frame`/MainMenuExpBar, so no frame-level ordering is needed) using
-- draw layers to reproduce BEB's own frame-level ordering: the glow
-- renders on top of the tick. "ARTWORK" (tick) below "OVERLAY" (glow)
-- reproduces that same relative order.

-- BEB/BEB.lua's own BEB.XpPerLvl table, ported verbatim (same literal
-- values, same index-by-level meaning: index N is the XP required to go
-- from level N to level N+1) - BTV:ApplyExpBarRestedOverlay's own tick-
-- position formula below indexes this the same way BEB's own
-- BEB.UpdateElement("BEBRestedXpTick") does.
BTV.XP_PER_LEVEL = {
	400, 900, 1400, 2100, 2800, 3600, 4400, 5400, 6500, 7600,
	8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
	25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
	50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
	95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
	153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800, 217400,
}

-- The addon's real installed folder name is "BTVanilla" (the .toc in
-- this repo is BTVanilla.toc), not "TrustyBars" (only the dev repo/
-- project folder's own name) - these SetTexture paths must resolve
-- against the in-game AddOns folder name.
local BEB_TICK_TEXTURE = "Interface\\AddOns\\BTVanilla\\Textures\\BEB-ExhaustionTicks"
local BEB_TICK_GLOW_TEXTURE = "Interface\\AddOns\\BTVanilla\\Textures\\BEB-ExhaustionTicksGlow"

-- BEB's own default BEBRestedXpTick size (BEB/BEB.lua's own BEBCharSettings
-- defaults: `size = {x=27,y=26}`) - the tick/glow art is a hand-drawn 2x2
-- quadrant sheet (see the texcoord selection in
-- BTV:ApplyExpBarRestedOverlay below), so its pixel dimensions are tied to
-- that art's own intended aspect ratio, not to MainMenuExpBar's own (much
-- thinner, ~8px) native height - kept as literal constants matching BEB's
-- own default rather than derived from frame:GetHeight().
local BEB_TICK_WIDTH = 27
local BEB_TICK_HEIGHT = 26

local function EnsureExpBarRestedTick(frame)
	if frame.btvRestedTick then
		return frame.btvRestedTick, frame.btvRestedTickGlow
	end

	local tick = frame:CreateTexture(nil, "ARTWORK")
	tick:SetTexture(BEB_TICK_TEXTURE)
	tick:SetWidth(BEB_TICK_WIDTH)
	tick:SetHeight(BEB_TICK_HEIGHT)

	-- BEB/BEB.lua's own BEBRestedXpTickGlow setup anchors it to exactly
	-- cover BEBRestedXpTick's own bounds (`SetPoint("TOPLEFT",
	-- "BEBRestedXpTick", "TOPLEFT", 0, 0)` + a matching BOTTOMRIGHT) rather
	-- than sizing itself independently - SetAllPoints(tick) reproduces the
	-- same result in one call once `tick` itself is positioned/sized each
	-- update (see ApplyExpBarRestedOverlay below).
	local glow = frame:CreateTexture(nil, "OVERLAY")
	glow:SetTexture(BEB_TICK_GLOW_TEXTURE)

	frame.btvRestedTick = tick
	frame.btvRestedTickGlow = glow

	return tick, glow
end

-- Rested-XP tick glow pulse: BEB's own source has no scripted
-- fade/alpha-animation logic for BEBRestedXpTickGlow, so this is a fresh,
-- standard vanilla-era looping alpha animation instead, driven by
-- C_Timer.NewTicker (the same periodic-update convention used elsewhere
-- in this codebase - Button.lua's rangeTicker, HoverBind.lua's
-- hoverBindTintTicker) rather than a hand-rolled OnUpdate polling frame.
-- Only the glow's alpha is animated; the base tick texture stays at
-- constant visibility. MainMenuExpBar is a single native frame with a
-- single glow texture, so one file-local ticker is all this needs.
local EXP_BAR_RESTED_GLOW_PULSE_INTERVAL = 0.05
local EXP_BAR_RESTED_GLOW_PULSE_LOW_ALPHA = 0.35
local EXP_BAR_RESTED_GLOW_PULSE_HIGH_ALPHA = 1.0

-- Full fade-in/fade-out cycle, seconds - customizable via Settings.lua's
-- Experience Bar page Pulse Interval slider
-- (BTVanillaDB.expBarGlowPulseInterval, BTV:SetExpBarGlowPulseInterval
-- below). This constant is only the fallback for a save file that
-- predates that field. The ticker callback below reads the DB field
-- fresh on every tick rather than baking a period into a closure upvalue
-- at ticker-start time, so the slider can change the running animation's
-- speed live without needing to Cancel()/restart the ticker.
local EXP_BAR_RESTED_GLOW_PULSE_PERIOD_DEFAULT = 1.5

local expBarRestedGlowPulseTicker
local expBarRestedGlowPulseStartTime

-- Cancels the ticker outright (not just a "pause" flag) whenever the glow
-- isn't shown, matching HoverBind.lua's hoverBindTintTicker precedent of
-- Cancel()-and-nil rather than leaving a ticker running with an early-out
-- check inside it - no wasted ticks while the glow is hidden.
local function StopExpBarRestedGlowPulse()
	if expBarRestedGlowPulseTicker then
		expBarRestedGlowPulseTicker:Cancel()
		expBarRestedGlowPulseTicker = nil
	end
end

-- Idempotent - a call while already running is a no-op (doesn't restart/
-- reset the phase), so repeated ApplyExpBarRestedOverlay calls while resting
-- (PLAYER_XP_UPDATE etc. can fire often) never visibly stutter the
-- animation.
local function StartExpBarRestedGlowPulse(glow)
	if expBarRestedGlowPulseTicker or not C_Timer or not C_Timer.NewTicker then
		return
	end

	expBarRestedGlowPulseStartTime = GetTime()

	expBarRestedGlowPulseTicker = C_Timer.NewTicker(EXP_BAR_RESTED_GLOW_PULSE_INTERVAL, function()
		local elapsed = GetTime() - expBarRestedGlowPulseStartTime

		-- Standard sine-wave time-based oscillation. t sweeps 0..1..0 once
		-- per `period` seconds - read fresh every tick (not captured once
		-- at ticker start) so the Settings.lua slider's live writes to
		-- BTVanillaDB.expBarGlowPulseInterval take effect on the very next
		-- tick.
		local period = (BTVanillaDB and BTVanillaDB.expBarGlowPulseInterval)
			or EXP_BAR_RESTED_GLOW_PULSE_PERIOD_DEFAULT

		local t = 0.5 + 0.5 * math.sin(elapsed * ((2 * math.pi) / period))
		local alpha = EXP_BAR_RESTED_GLOW_PULSE_LOW_ALPHA
			+ ((EXP_BAR_RESTED_GLOW_PULSE_HIGH_ALPHA - EXP_BAR_RESTED_GLOW_PULSE_LOW_ALPHA) * t)

		glow:SetAlpha(alpha)
	end)
end

-- Called from BTV:ApplyExpBarColors (color changes/reverts),
-- BTV:ApplyBetterExpBarVisual (feature toggled on/off), and the
-- betterExpBarEventFrame OnEvent handler further below - safe to call
-- unconditionally from all of them, the same "single choke point" pattern
-- as BTV:ApplyExpBarColors.
function BTV:ApplyExpBarRestedOverlay()
	self:EnsureDB()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local tex = frame.btvRestedOverlay
	local tick = frame.btvRestedTick
	local glow = frame.btvRestedTickGlow

	if not BTVanillaDB.betterExpBarEnabled or not GetRestState or GetRestState() ~= 1 then
		if tex then
			tex:Hide()
		end

		if tick then
			tick:Hide()
		end

		if glow then
			glow:Hide()
		end

		StopExpBarRestedGlowPulse()

		return
	end

	-- Real screen width, not a scaled one - MainMenuExpBar's own StatusBar
	-- fill sizes itself the exact same way (against GetWidth(), unaffected
	-- by BTV:SetExpBarScale's frame:SetScale() call - SetScale changes
	-- RENDERING, never what GetWidth() reports), so computing this overlay
	-- against the same value keeps it pixel-consistent with the real fill
	-- at any configured Experience Bar scale.
	local barWidth = frame:GetWidth()
	local xpMax = UnitXPMax and UnitXPMax("player")
	local xp = UnitXP and UnitXP("player")
	local exhaustion = GetXPExhaustion and GetXPExhaustion()

	if not barWidth or barWidth <= 0 or not xpMax or xpMax <= 0 or not xp or not exhaustion then
		if tex then
			tex:Hide()
		end

		if tick then
			tick:Hide()
		end

		if glow then
			glow:Hide()
		end

		StopExpBarRestedGlowPulse()

		return
	end

	-- BEB/BEB.lua's own BEBXpBar branch - the earned-XP fill's own width,
	-- needed here as the rested overlay's LEFT edge (it starts exactly
	-- where the earned-XP fill ends).
	local scale = barWidth / xpMax
	local xpWidth = (xp == 0) and 1 or (scale * xp)

	local width

	if (xp + exhaustion) > xpMax then
		-- Exceeds max: fill the entire remainder of the bar - BEB's own
		-- exact branch for this case (BEB/BEB.lua), and the specific case
		-- ExhaustionLevelFillBar's own native width degenerates on.
		width = barWidth - xpWidth
	else
		local restedEdge = (xp + exhaustion) * scale
		width = restedEdge - xpWidth
	end

	if not width or width <= 0 then
		if tex then
			tex:Hide()
		end

		if tick then
			tick:Hide()
		end

		if glow then
			glow:Hide()
		end

		StopExpBarRestedGlowPulse()

		return
	end

	tex = EnsureExpBarRestedOverlay(frame)

	local color = BTVanillaDB.expBarColorRested

	if color then
		tex:SetVertexColor(color.r, color.g, color.b)
	end

	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", frame, "TOPLEFT", xpWidth, 0)
	tex:SetWidth(width)
	tex:SetHeight(frame:GetHeight())
	tex:Show()

	-- The tick's own position is not derived from the rested-overlay
	-- fill's boundaryX above. BEB/BEB.lua's own
	-- BEB.UpdateElement("BEBRestedXpTick") computes an independent
	-- position formula that can represent progress into the next (or
	-- next-next) level's own XP requirement, expressed as a fraction of
	-- the same bar width - ported verbatim below, reusing this function's
	-- own already-computed scale/barWidth and xp/exhaustion/xpMax.
	local level = UnitLevel and UnitLevel("player")

	if not level or level < 1 or not BTV.XP_PER_LEVEL[1] then
		if tick then
			tick:Hide()
		end

		if glow then
			glow:Hide()
		end

		StopExpBarRestedGlowPulse()

		return
	end

	local position
	local restState

	-- Ported verbatim from BEB/BEB.lua's own "BEBRestedXpTick" branch
	-- (BEB.XpPerLvl-indexed) - three level brackets (level < 59 / level ==
	-- 59 / level == 60), each with the same 3-state within-level /
	-- crosses-one-level / crosses-two-levels sub-branching BEB itself uses,
	-- kept exactly as found rather than collapsed or reordered.
	if level < 59 then
		if (xp + exhaustion - xpMax) > BTV.XP_PER_LEVEL[level + 1] then
			position = ((xp + exhaustion - xpMax - BTV.XP_PER_LEVEL[level + 1]) / BTV.XP_PER_LEVEL[level + 2]) * barWidth
			restState = 3
		elseif (xp + exhaustion) > xpMax then
			position = ((xp + exhaustion - xpMax) / BTV.XP_PER_LEVEL[level + 1]) * barWidth
			restState = 2
		else
			position = (xp + exhaustion) * scale
			restState = 1
		end
	elseif level == 59 then
		-- Same 3 states, but the "crosses two levels" case has no level 61
		-- entry in BTV.XP_PER_LEVEL to measure fractional progress against
		-- (BEB's own table stops at level 60's requirement, i.e. the
		-- level-60-to-61 threshold) - BEB's own source clamps this to the
		-- bar's right edge instead, ported as-is.
		if (xp + exhaustion - xpMax) > BTV.XP_PER_LEVEL[level + 1] then
			position = barWidth
			restState = 3
		elseif (xp + exhaustion) > xpMax then
			position = ((xp + exhaustion - xpMax) / BTV.XP_PER_LEVEL[level + 1]) * barWidth
			restState = 2
		else
			position = (xp + exhaustion) * scale
			restState = 1
		end
	else
		-- level == 60 in BEB's own source (the vanilla level cap - no
		-- further level to cross into at all, only 2 states). Also used
		-- here as the fallback for level > 60 (e.g. a higher level cap on
		-- this server than vanilla's own 60 - BEB's own source has no
		-- branch for that case at all, which would otherwise leave
		-- `position`/`restState` nil and error below; the same "no further
		-- level to cross into, clamp at the bar's right edge" behavior BEB
		-- itself already uses for level 60 is the correct extension, not a
		-- new invented behavior).
		if (xp + exhaustion) > xpMax then
			position = barWidth
			restState = 2
		else
			position = (xp + exhaustion) * scale
			restState = 1
		end
	end

	tick, glow = EnsureExpBarRestedTick(frame)

	-- BEB's own texcoord selection (BEB/BEB.lua's "BEBRestedXpTick" branch)
	-- - a 2x2 quadrant sheet, same mapping for both the tick and the glow
	-- (BEB/BEB.lua's own "BEBRestedXpTickGlow" branch uses the identical 3
	-- SetTexCoord calls keyed off the same BEB.BEBRestState value).
	local left, right, top, bottom

	if restState == 3 then
		left, right, top, bottom = 0, 0.5, 0.5, 1
	elseif restState == 2 then
		left, right, top, bottom = 0.5, 1, 0, 0.5
	else
		left, right, top, bottom = 0, 0.5, 0, 0.5
	end

	tick:SetTexCoord(left, right, top, bottom)
	glow:SetTexCoord(left, right, top, bottom)

	-- BEB's own anchor: `BEBRestedXpTick:SetPoint("CENTER", "BEBMain",
	-- "LEFT", position, 0)` (BEBCharSettings.BEBRestedXpTick.location
	-- offsets, both 0 by default - not ported as a separate user-facing
	-- offset setting, per this feature's own scope).
	tick:ClearAllPoints()
	tick:SetPoint("CENTER", frame, "LEFT", position, 0)
	tick:Show()

	glow:ClearAllPoints()
	glow:SetAllPoints(tick)

	-- BEB's own "BEBRestedXpTickGlow" branch gates on IsResting() == 1 in
	-- ADDITION to (GetRestState() == 1 and BEBRestState ~= 0) - both of
	-- which are already guaranteed true at this point in this function
	-- (the early-return above already requires GetRestState() == 1, and
	-- restState is always 1/2/3 here, never BEB's own "0" meaning hidden).
	-- IsResting() (distinct from GetRestState()) reports whether the
	-- player is currently standing in a rest area (inn/city) right now,
	-- so this is the one remaining real distinction: a player who banked
	-- rest XP but has since left the inn keeps GetRestState() == 1 (the
	-- tick itself stays visible) while IsResting() drops to nil/0 (the
	-- glow highlight turns off).
	if IsResting and IsResting() == 1 then
		glow:Show()
		StartExpBarRestedGlowPulse(glow)
	else
		glow:Hide()
		StopExpBarRestedGlowPulse()
	end
end

-------------------------------------------------------------------------
-- "Better Experience Bar" text overlay
--
-- Modeled on the BEB reference addon (BEB/TextVars.lua's own "$plv"/"$pdl"/
-- "$prt"/"$rxp" variable formulas) rather than copied 1:1 - a single
-- centered FontString assembled from up to 5 independently toggleable
-- segments (BTVanillaDB.expBarShowLevel/expBarShowCurrentOverMax/
-- expBarShowPercent/expBarShowRestedPercent/expBarShowRestedTotal,
-- Settings.lua's Experience Bar page), kept live via PLAYER_XP_UPDATE/
-- UPDATE_EXHAUSTION/PLAYER_LEVEL_UP - all three registered unconditionally
-- regardless of which segments are currently on, simpler and safer than
-- churning RegisterEvent/UnregisterEvent on every checkbox click.
-- UnitLevel/UnitXP/UnitXPMax/GetXPExhaustion are real native vanilla API
-- functions (BEB's own proven usage on this exact client) - not
-- reimplemented, just read the same way BEB already does.
--
-- Entirely independent of the Experience Bar container above
-- (BTV:ApplyExpBarPosition/SetExpBarScale) - this text automatically
-- follows MainMenuExpBar's position/scale with no separate tracking
-- needed (see EnsureExpBarTextOverlay's own comment for how).
--
-- The FontString lives on its own dedicated overlay frame
-- (EnsureExpBarTextOverlay below) at "HIGH" strata, rather than directly
-- on MainMenuExpBar - a region's own draw layer only orders regions
-- within the same frame, it has no say over a different frame's art
-- (MainMenuBarArtFrame) rendering on top of it. MainMenuExpBar sits at
-- strata "MEDIUM" level 2, strictly below MainMenuBarArtFrame's level 5
-- within that same tier, so a region of the bar itself was structurally
-- unable to out-rank the art. A dedicated "HIGH"-strata overlay frame
-- (the same technique BuildChainAnchoredContainer uses for Bag Bar/Micro
-- Menu) sidesteps that outright, rather than chasing another explicit
-- frame level within the same MEDIUM tier.
-------------------------------------------------------------------------

-- Dedicated overlay frame the "Better Experience Bar" text FontString is
-- created on - see this section's own header comment above.
-- SetAllPoints(frame) means this overlay always exactly tracks
-- MainMenuExpBar's own position/size, the same "one real frame,
-- SetAllPoints-tracked" technique EnsureContainerOverlay uses elsewhere
-- in this file for edit-mode drag overlays - unlike that overlay
-- (transient, edit-mode-only), this one has no texture of its own, only
-- the text FontString as a child, whose own Show/Hide
-- (BTV:ApplyBetterExpBarVisual/UpdateBetterExpBarText) controls the
-- text's visibility.
--
-- This overlay's own Show/Hide only matters for one edge case: if the
-- Experience Bar starts disabled, SetExpBarEnabled's own
-- frame.btvTextOverlay:Hide() call runs before this overlay exists yet
-- (it's created lazily by BTV:ApplyBetterExpBarVisual) and can't do
-- anything - reading the live BTVanillaDB.expBarEnabled flag here at
-- creation time avoids the text floating on screen at MainMenuExpBar's
-- last position while the bar itself starts disabled.
local function EnsureExpBarTextOverlay(frame)
	if frame.btvTextOverlay then
		return frame.btvTextOverlay
	end

	-- Parented to `frame` (MainMenuExpBar) itself, not UIParent:
	-- GetWidth()/GetHeight() report a frame's size in its own local
	-- coordinate units, which only numerically matches another frame's
	-- when both share the identical scale ancestry chain - UIParent-
	-- parented did not (MainMenuExpBar sits under MainMenuBar/etc
	-- instead), producing a scale-chain mismatch and an off-center text
	-- overlay. Parenting directly to MainMenuExpBar puts this overlay in
	-- the identical ancestry, eliminating the mismatch structurally.
	--
	-- This does not reintroduce the art-masking problem this overlay
	-- exists to avoid (see this section's header comment): strata/level
	-- for a real child frame (unlike a region like a Texture/FontString)
	-- is independent of the parent's own strata/level - rendering order
	-- is governed by the child's own explicit values.
	-- MainMenuBarOverlayFrame (a real native child of MainMenuExpBar)
	-- already draws its own XP text FontString on top of the bar's art
	-- despite being parented to the very frame that art sits on, the same
	-- principle this overlay relies on.
	local overlay = CreateFrame("Frame", "BTVanillaExpBarTextOverlay", frame)

	overlay:SetFrameStrata("HIGH")
	overlay:SetAllPoints(frame)

	-- See this function's own header comment above - matches whatever
	-- SetExpBarEnabled would already have set had this overlay existed at
	-- login time, instead of defaulting to CreateFrame's normal "shown".
	if BTVanillaDB and BTVanillaDB.expBarEnabled == false then
		overlay:Hide()
	end

	frame.btvTextOverlay = overlay

	return overlay
end

-- Lua 5.0 has no math.round - same simple floor(x + 0.5) idiom used
-- throughout this addon (e.g. Core.lua's CaptureNativeSpacing), rather
-- than depending on BEB's own BEB.round - this addon only takes
-- inspiration from BEB's formulas, not a runtime dependency on BEB itself
-- being installed/enabled.
local function ExpBarRound(n)
	return math.floor(n + 0.5)
end

-- Assembles only the currently-enabled segments into one space-joined
-- line. Each segment is already self-labeled ("Lvl 2",
-- "26/900", "3%", "Rested: 3%", "27 Rested Xp"), so a plain space join
-- never needs separator/punctuation logic for whichever subset happens to
-- be off - no double-spaces or dangling separators regardless of which
-- combination of the 5 toggles is active (including all-off, which simply
-- yields an empty string). "$plv"/"$pdl"/"$prt"/"$rxp" from
-- BEB/TextVars.lua are the exact source formulas for the level/percent/
-- rested-percent/rested-total segments respectively, ported Lua-5.0-safe.
local function ComputeBetterExpBarText()
	local cur = UnitXP and UnitXP("player")
	local max = UnitXPMax and UnitXPMax("player")
	local exhaustion = GetXPExhaustion and GetXPExhaustion()

	local segments = {}
	local n = 0

	if BTVanillaDB.expBarShowLevel then
		n = n + 1
		segments[n] = "Lvl " .. tostring(UnitLevel("player"))
	end

	if BTVanillaDB.expBarShowCurrentOverMax and cur and max then
		n = n + 1
		segments[n] = tostring(cur) .. "/" .. tostring(max)
	end

	if BTVanillaDB.expBarShowPercent then
		local levelPct = 0

		if cur and max and max > 0 then
			levelPct = ExpBarRound((cur / max) * 100)
		end

		n = n + 1
		segments[n] = tostring(levelPct) .. "%"
	end

	if BTVanillaDB.expBarShowRestedPercent then
		local restedPct = 0

		if exhaustion and max and max > 0 then
			restedPct = ExpBarRound((exhaustion * 100) / (max * 1.5))
		end

		n = n + 1
		segments[n] = "Rested: " .. tostring(restedPct) .. "%"
	end

	if BTVanillaDB.expBarShowRestedTotal then
		n = n + 1
		segments[n] = tostring(exhaustion or 0) .. " Rested Xp"
	end

	return table.concat(segments, " ")
end

-- A plain Hide() call (reasserted on every PLAYER_XP_UPDATE/
-- UPDATE_EXHAUSTION/PLAYER_LEVEL_UP) does not stick - Blizzard's native
-- XP bar code re-Shows this FontString on some other trigger these three
-- events don't cover (most likely an OnUpdate script). Neutering Show()
-- itself, the same technique used for the 48 real default-bar buttons
-- and BonusActionBarFrame, fixes it - but unlike those two (permanent),
-- this one must be reversible: the native label needs to come back the
-- instant the user disables the setting, so the real Show method is
-- captured exactly once, lazily, in BTV:ApplyBetterExpBarVisual (not at
-- file-load time, since MainMenuBarOverlayFrame's FontString region may
-- not exist yet that early) and restored verbatim when the feature is
-- turned back off.
local realExpOverlayTextShow

local function UpdateBetterExpBarText()
	local text = BTV.betterExpBarText

	if text then
		text:SetText(ComputeBetterExpBarText())
	end

	-- Show() itself is neutered while the feature is on (see
	-- BTV:ApplyBetterExpBarVisual below), so this Hide() call is mostly
	-- defense-in-depth at this point - kept because it's harmless.
	local nativeText = BTV:GetNativeExpOverlayText()

	if nativeText and BTVanillaDB.betterExpBarEnabled then
		nativeText:Hide()
	end
end

-- Shared OnEvent handler for betterExpBarEventFrame below - refreshes
-- both the text overlay and the custom rested-XP overlay
-- (BTV:ApplyExpBarRestedOverlay) on the same event set, since both are
-- gated on the same BTVanillaDB.betterExpBarEnabled toggle.
local function BetterExpBarOnEvent()
	UpdateBetterExpBarText()
	BTV:ApplyExpBarRestedOverlay()
end

-- Created lazily, once - shared by every later BTV:ApplyBetterExpBarVisual
-- call this session, mirroring every other lazy-build-once frame in this
-- file (e.g. barOverlays in Bar.lua).
local betterExpBarEventFrame

-- Creates (once)/shows/hides/live-updates the text overlay per
-- BTVanillaDB.betterExpBarEnabled - called from Core.lua's login sequence
-- and from the Experience Bar's own settings page (Settings.lua,
-- simpleBarPageConfigs["expbar"]).
--
-- Unlike Button.lua's hotkey/count text (captured off a real FontString
-- that always exists from every button's Init), this overlay is
-- deliberately never created until "Enable Better Experience Bar" is
-- turned on for the first time (see the early-return below) - so there
-- may be no live FontString to sample a size from yet the first time
-- Settings.lua's Experience Bar page needs a value to show.
-- GameFontNormalSmall is the same real vanilla FrameXML global Font
-- object this overlay's own CreateFontString(..., "GameFontNormalSmall")
-- call below always inherits from - Font objects support GetFont()
-- directly, with no FontString instance required - so it's read once
-- here, lazily, from wherever a size is first needed.
function BTV:CaptureNativeExpBarFontIfNeeded()
	if self.NATIVE_EXPBAR_FONT then
		return self.NATIVE_EXPBAR_FONT
	end

	if not GameFontNormalSmall or not GameFontNormalSmall.GetFont then
		return nil
	end

	local path, size = GameFontNormalSmall:GetFont()

	if not path then
		return nil
	end

	self.NATIVE_EXPBAR_FONT = { path = path, size = size }

	return self.NATIVE_EXPBAR_FONT
end

function BTV:ApplyBetterExpBarVisual()
	self:EnsureDB()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	-- Resolved via BTV:GetNativeExpOverlayText (the real
	-- MainMenuBarOverlayFrame FontString region).
	local nativeText = self:GetNativeExpOverlayText()

	-- Captured unconditionally here (not inside the enabled-only branch
	-- further below) so BTV.NATIVE_EXPBAR_FONT is populated on every
	-- login regardless of whether the feature itself is currently on.
	self:CaptureNativeExpBarFontIfNeeded()

	-- Captures the real Show method exactly once, lazily, the first time
	-- this runs after MainMenuBarOverlayFrame's FontString region
	-- actually exists - must happen before it's ever neutered below.
	if nativeText and not realExpOverlayTextShow then
		realExpOverlayTextShow = nativeText.Show
	end

	if not BTVanillaDB.betterExpBarEnabled then
		if self.betterExpBarText then
			self.betterExpBarText:Hide()
		end

		-- Reversible restore: undo the Show() neutering below (if it was
		-- ever applied this session) before calling Show(), so real
		-- vanilla's own label comes straight back rather than silently
		-- no-oping against its own neutered method.
		if nativeText then
			if realExpOverlayTextShow then
				nativeText.Show = realExpOverlayTextShow
			end

			nativeText:Show()
		end

		-- Hides the custom rested-XP overlay too - it's gated on this same
		-- BTVanillaDB.betterExpBarEnabled toggle, so turning the feature
		-- off must hide it immediately rather than leaving it showing
		-- until the next XP/resting-state event happens to fire.
		self:ApplyExpBarRestedOverlay()

		return
	end

	if nativeText then
		-- Neuters Show() itself (not just calling Hide()) so no native
		-- OnUpdate/event handler can re-show this label out from under us
		-- - a plain Hide() alone doesn't stick. Reversed above the moment
		-- betterExpBarEnabled goes back to false.
		if realExpOverlayTextShow then
			nativeText.Show = function() end
		end

		nativeText:Hide()
	end

	if not self.betterExpBarText then
		-- Created on the dedicated text-overlay frame
		-- (EnsureExpBarTextOverlay above), not on `frame` (MainMenuExpBar)
		-- itself - see this section's own header comment for why. The
		-- overlay SetAllPoints(frame), so anchoring CENTER to the
		-- overlay's own CENTER at a plain 0,0 offset lands this exactly
		-- in the middle of the bar, same as anchoring to `frame` directly
		-- would have.
		local textOverlay = EnsureExpBarTextOverlay(frame)
		local text = textOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		text:SetPoint("CENTER", textOverlay, "CENTER", 0, 0)

		-- OUTLINE flag keeps this readable regardless of whatever's
		-- underneath it (the earned-XP fill vs. the rested-bonus fill can
		-- be any user-chosen color, without needing to sample/react to
		-- the bar's current fill color).
		local fontPath, fontSize = text:GetFont()

		-- Starts one size smaller than GameFontNormalSmall's own native
		-- default (BTV.NATIVE_EXPBAR_FONT, captured above) until
		-- BTVanillaDB.expBarFontSize holds a real saved value (stays nil
		-- until the user moves Settings.lua's Experience Bar page Font
		-- Size slider - same lazy-default idiom as
		-- BTVanillaDB.hotkeyFontSize/countFontSize).
		local applySize = BTVanillaDB.expBarFontSize

		if not applySize and self.NATIVE_EXPBAR_FONT then
			applySize = self.NATIVE_EXPBAR_FONT.size - 1
		end

		if fontPath then
			text:SetFont(fontPath, applySize or fontSize, "OUTLINE")
		end

		-- BTVanillaDB.expBarTextColor (default gold, Core.lua's EnsureDB)
		-- has no native vanilla equivalent to preserve/revert to (it's
		-- this addon's own FontString, not a native region), so a
		-- straight default is seeded unconditionally rather than lazily
		-- captured from a live frame.
		local textColor = BTVanillaDB.expBarTextColor

		if textColor then
			text:SetTextColor(textColor.r, textColor.g, textColor.b)
		end

		self.betterExpBarText = text

		if not betterExpBarEventFrame then
			betterExpBarEventFrame = CreateFrame("Frame", "BTVanillaBetterExpBarEventFrame")

			-- All events are kept unconditionally registered regardless of
			-- which of the 5 segment toggles are currently on - simpler
			-- and safer than churning registration on every checkbox click.
			betterExpBarEventFrame:RegisterEvent("PLAYER_XP_UPDATE")
			betterExpBarEventFrame:RegisterEvent("UPDATE_EXHAUSTION")
			betterExpBarEventFrame:RegisterEvent("PLAYER_LEVEL_UP")

			-- PLAYER_UPDATE_RESTING is the real vanilla event that fires
			-- when the player's resting state itself changes (entering/
			-- leaving an inn or city) - needed so
			-- BTV:ApplyExpBarRestedOverlay's GetRestState() gate
			-- re-evaluates the instant resting starts/stops, not just on
			-- the next XP/exhaustion change.
			betterExpBarEventFrame:RegisterEvent("PLAYER_UPDATE_RESTING")

			betterExpBarEventFrame:SetScript("OnEvent", BetterExpBarOnEvent)
		end
	end

	self.betterExpBarText:Show()
	UpdateBetterExpBarText()

	-- Shows/refreshes the custom rested-XP overlay the instant the
	-- feature is turned on, rather than waiting for the next
	-- PLAYER_XP_UPDATE/UPDATE_EXHAUSTION/PLAYER_LEVEL_UP/PLAYER_UPDATE_RESTING
	-- event.
	self:ApplyExpBarRestedOverlay()
end

-- Settings.lua's Experience Bar page Font Size slider calls this directly
-- on every OnValueChanged - mirrors Button.lua's BTV:SetHotkeyFontSize/
-- SetCountFontSize's exact round-then-write template (single FontString
-- here instead of a sweep across every button's hotkey/count, but the
-- same "funnel every caller through one rounding point" reasoning
-- applies - GetFont()'s own float imprecision, e.g. 11.999999726451
-- instead of 12, on this client).
function BTV:SetExpBarFontSize(size)
	self:EnsureDB()

	size = math.floor(size + 0.5)

	BTVanillaDB.expBarFontSize = size

	if self.betterExpBarText and self.NATIVE_EXPBAR_FONT then
		self.betterExpBarText:SetFont(self.NATIVE_EXPBAR_FONT.path, size, "OUTLINE")
	end
end

-- Settings.lua's Experience Bar page Pulse Interval slider calls this
-- directly on every OnValueChanged - mirrors SetExpBarFontSize's
-- round-then-write template above, except rounded to 1 decimal place
-- (the slider's own 0.1 step), and clamped to the slider's own 0.5-5.0
-- range so a stray direct-write can't hand the sine formula above a
-- zero/negative period. Writing BTVanillaDB.expBarGlowPulseInterval here
-- is already sufficient to reach the running animation -
-- StartExpBarRestedGlowPulse's own ticker callback reads this same field
-- fresh every tick, so no separate "push to the live animation" step is
-- needed.
function BTV:SetExpBarGlowPulseInterval(interval)
	self:EnsureDB()

	interval = tonumber(interval)

	if not interval then
		return
	end

	interval = math.floor((interval * 10) + 0.5) / 10

	if interval < 0.5 then
		interval = 0.5
	end

	if interval > 5 then
		interval = 5
	end

	BTVanillaDB.expBarGlowPulseInterval = interval
end

-- Settings.lua's Experience Bar page's own text-color swatch calls this
-- directly from ColorPickerFrame.func/cancelFunc - same mechanic as
-- BTV:SetExpBarColorEarned/SetExpBarColorRested above, just against this
-- addon's own FontString via SetTextColor instead of a native bar-fill
-- region.
function BTV:SetExpBarTextColor(r, g, b)
	self:EnsureDB()

	BTVanillaDB.expBarTextColor = { r = r, g = g, b = b }

	if self.betterExpBarText then
		self.betterExpBarText:SetTextColor(r, g, b)
	end
end

-------------------------------------------------------------------------
-- Stance bar buttons
--
-- GetNumShapeshiftForms() (real vanilla API, part of the stock
-- ShapeshiftBar.lua FrameXML this button set already belongs to) is the
-- authoritative source for how many ShapeshiftButton# frames are actually
-- "active" for the current class/talent state - NOT :IsShown(), which
-- isn't reliable before the native stance bar has ever been touched (see
-- the migration plan's own reasoning). Returns 0 for a class with no
-- stance/form mechanic at all (e.g. a fresh Warrior with no stances
-- learned yet, or a class that never gets one), in which case this
-- returns nil and CreateStanceBarContainer/RebuildStanceBarContainer below
-- simply don't build/show anything.
-------------------------------------------------------------------------

-- Returns an ordered table of the currently-active real Blizzard stance
-- button frames (1 through GetNumShapeshiftForms(), capped at
-- MAX_STANCE_BUTTONS), or nil if there are none right now.
function BTV:GetStanceBarButtons()
	local count = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

	if not count or count <= 0 then
		return nil
	end

	if count > self.MAX_STANCE_BUTTONS then
		count = self.MAX_STANCE_BUTTONS
	end

	local buttons = {}
	local i

	for i = 1, count do
		local frame = getglobal("ShapeshiftButton" .. tostring(i))

		if not frame then
			-- Missing frames beyond this point aren't collected - mirrors
			-- GetDefaultBarButtons' same "stop at first missing frame"
			-- tolerance for a partially-loaded UI.
			break
		end

		buttons[i] = frame
	end

	if table.getn(buttons) == 0 then
		return nil
	end

	return buttons
end

-------------------------------------------------------------------------
-- Default-layout / stance-bar edit-mode overlay refresh
--
-- Mirrors Bar.lua's ApplyEditModeVisual for custom bars, but gated on
-- BTV:CanDragDefaultLayout() (edit mode
-- AND useDefaultLayout == false) rather than edit mode alone - showing a
-- "this is draggable" cue when dragging isn't actually possible
-- (useDefaultLayout == true) would be misleading. Called from Bar.lua's
-- ApplyEditModeVisual (so both bar kinds' overlays update together
-- whenever edit mode toggles) and from Settings.lua's General panel
-- checkbox handler (since toggling useDefaultLayout also changes whether
-- dragging is currently possible even with edit mode state unchanged).
-------------------------------------------------------------------------

function BTV:ApplyDefaultLayoutEditVisual()
	local show = self:CanDragDefaultLayout()

	-- Default bars 1-5 have no bar-level overlay loop here - they share
	-- Bar.lua's EnsureBarOverlay/ApplyEditModeVisual with every other
	-- bar, which already handles their show/hide and mouse-enable gating
	-- (including the useDefaultLayout == false requirement via
	-- isDefaultBar1to5's canEdit check there). This function only drives
	-- the chain-anchored containers and native-wrapped elements below.

	-- Stance Bar / Bag Bar / Micro Menu - all three are now the same kind
	-- of TrustyBars-owned chain-anchored container (BuildChainAnchoredContainer/
	-- ApplyChainAnchoredShape), so they share the exact same
	-- ApplyContainerOverlayVisual treatment: overlay visibility gated on
	-- both edit-mode/useDefaultLayout (`show`) AND this element's own
	-- enable flag.
	ApplyContainerOverlayVisual(self.stanceBarContainer, BTVanillaDB.stanceBarEnabled, show)
	ApplyContainerOverlayVisual(self.bagBarContainer, BTVanillaDB.bagBarEnabled, show)
	ApplyContainerOverlayVisual(self.microMenuContainer, BTVanillaDB.microMenuEnabled, show)

	-- Key Ring / Latency Bar - same generic ApplyContainerOverlayVisual
	-- treatment as Bag Bar/Micro Menu above; EnsureContainerOverlay is
	-- equally generic over a single real button/frame as it is over a
	-- synthetic container, so no separate helper is needed here. Looked
	-- up by name each call (rather than cached) since this only runs on
	-- edit-mode/useDefaultLayout toggles, not per frame.
	ApplyContainerOverlayVisual(getglobal(self.KEYRING_BUTTON_NAME), BTVanillaDB.keyRingEnabled, show)
	ApplyContainerOverlayVisual(getglobal(self.LATENCY_BAR_FRAME_NAME), BTVanillaDB.latencyBarEnabled, show)

	-- Experience Bar - same generic ApplyContainerOverlayVisual treatment
	-- as Key Ring/Latency Bar above.
	ApplyContainerOverlayVisual(getglobal(self.EXP_BAR_FRAME_NAME), BTVanillaDB.expBarEnabled, show)

	-- Page Indicator (Part 4) - same generic ApplyContainerOverlayVisual
	-- treatment, gated on mainBarPaginationEnabled instead of an
	-- independent enable flag (this element has none of its own - see
	-- ApplyPageIndicatorVisibility's comment).
	ApplyContainerOverlayVisual(
		self.pageIndicatorContainer,
		BTVanillaDB.mainBarPaginationEnabled,
		show
	)
end

-------------------------------------------------------------------------
-- Page Indicator (chain-anchored container)
--
-- Wraps the Main Bar's native page-turn arrows/page-number FontString the
-- same way Bag Bar/Micro Menu/Stance Bar wrap their own real Blizzard
-- frames above (BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay) - a real vanilla FontString
-- (MainMenuBarPageNumber) supports GetLeft/GetTop/GetWidth/GetHeight/
-- SetParent/IsShown/SetPoint exactly like a Frame/Button region does, so
-- it slots into that same generic machinery, except GetEffectiveScale,
-- which it does not support - see PixelSetPoint's own comment above for
-- the fallback to plain SetPoint whenever either side of a chain-anchor
-- is a FontString/Texture lacking that method.
--
-- ActionBarUpButton/ActionBarDownButton/MainMenuBarPageNumber are the
-- real vanilla 1.12.1 FrameXML names for these three elements, but -
-- unlike every other frame name this file relies on - these three have
-- not been live-confirmed on this specific modded client.
-- CreatePageIndicatorContainer below requires all three names to resolve
-- (stricter than GetButtonsByName's own generic "skip whatever's
-- missing" tolerance - a partial 1- or 2-element page indicator would be
-- visually broken, not a healthy smaller variant) - a wrong/missing name
-- here just silently never builds this container, the same as a failed
-- Bag Bar/Micro Menu discovery.
--
-- Position + Scale only (no Spacing/Orientation slider, unlike Bag Bar/
-- Micro Menu/Stance Bar). Orientation is fixed vertical here (the native
-- up/down arrows + page number are a vertical stack, not the left-to-
-- right chains those three elements are), and spacing is fixed at 0
-- rather than auto-captured: BuildChainAnchoredContainer's own
-- ComputeMajorityGap only measures a horizontal gap (lefts/widths), so
-- the 3 elements are simply laid out edge-to-edge instead of at their
-- true native gap - a cosmetic simplification, the whole container is
-- still fully draggable/scalable to compensate.
-------------------------------------------------------------------------

BTV.PAGE_INDICATOR_UP_NAME = "ActionBarUpButton"
BTV.PAGE_INDICATOR_DOWN_NAME = "ActionBarDownButton"
BTV.PAGE_INDICATOR_TEXT_NAME = "MainMenuBarPageNumber"

-- This container is not a single row/column of same-size, same-type
-- elements chained edge-to-edge - it's two stacked arrow buttons plus a
-- text label that needs to sit to their right, vertically centered
-- against the pair, not "next in the chain" underneath them.
-- BuildChainAnchoredContainer/ApplyChainAnchoredShape (the generic
-- engine Bag Bar/Micro Menu/Stance Bar all use) has no way to express
-- that, so this container has its own dedicated, purpose-built layout
-- (CreatePageIndicatorContainer/ApplyPageIndicatorShape below) instead.
-- Its own external position/scale/enable behavior
-- (ApplyPageIndicatorPosition/SetPageIndicatorScale/
-- ApplyPageIndicatorVisibility, EnsureContainerOverlay-based drag) is
-- unchanged - only the internal up/down/text arrangement is custom.
function BTV:CreatePageIndicatorContainer()
	self:EnsureDB()

	if self.pageIndicatorContainer then
		return
	end

	local up = getglobal(self.PAGE_INDICATOR_UP_NAME)
	local down = getglobal(self.PAGE_INDICATOR_DOWN_NAME)
	local text = getglobal(self.PAGE_INDICATOR_TEXT_NAME)

	-- Same "require every element or skip the whole feature" tolerance as
	-- the previous implementation - a partial page indicator (missing an
	-- arrow or the number) would be visually broken, not a healthy smaller
	-- variant.
	if not up or not down or not text then
		return
	end

	-- Reads each element's real native anchor point (GetPoint(1) - a real
	-- Region method every one of these three supports, including the
	-- FontString, unlike GetEffectiveScale) before reparenting/moving
	-- anything. SetParent never rewrites another frame's own anchor
	-- points - it only changes rendering ownership/strata inheritance -
	-- so if Down and/or the page-number text are natively anchored
	-- directly to Up (or to each other) rather than to some frame outside
	-- this trio, that anchor is already exactly correct and needs no
	-- reconstruction: it keeps resolving relative to that same Up/Down
	-- frame object regardless of what that object's own parent becomes.
	local upPoint, upRelTo, upRelPoint, upX, upY = up:GetPoint(1)
	local downPoint, downRelTo, downRelPoint, downX, downY = down:GetPoint(1)
	local textPoint, textRelTo, textRelPoint, textX, textY = text:GetPoint(1)

	-- Reports the real native anchor topology to chat once, at first build.
	self:Print(
		"Page Indicator native anchors - Up: " .. tostring(upPoint) .. " of " ..
		tostring(upRelTo and upRelTo:GetName() or "?") .. " " .. tostring(upRelPoint) ..
		" (" .. tostring(upX) .. ", " .. tostring(upY) .. ")" ..
		" | Down: " .. tostring(downPoint) .. " of " ..
		tostring(downRelTo and downRelTo:GetName() or "?") .. " " .. tostring(downRelPoint) ..
		" (" .. tostring(downX) .. ", " .. tostring(downY) .. ")" ..
		" | Text: " .. tostring(textPoint) .. " of " ..
		tostring(textRelTo and textRelTo:GetName() or "?") .. " " .. tostring(textRelPoint) ..
		" (" .. tostring(textX) .. ", " .. tostring(textY) .. ")"
	)

	-- The container's own TOPLEFT is defined to equal Up's real native
	-- TOPLEFT (GetLeft()/GetTop()), converted through real screen pixels
	-- via each frame's own GetEffectiveScale, the same conversion as
	-- Core.lua's CaptureNativeAnchor (this container, like every default
	-- bar, is anchored directly to UIParent, and is a bare
	-- CreateFrame(..., UIParent) with no SetScale of its own, so its
	-- effective scale always equals UIParent's exactly).
	local nativeLeft = up:GetLeft()
	local nativeTop = up:GetTop()

	if not nativeLeft or not nativeTop then
		return
	end

	local upScale = up:GetEffectiveScale()
	local uiParentScale = UIParent:GetEffectiveScale()

	if not upScale or not uiParentScale or uiParentScale == 0 then
		return
	end

	nativeLeft = (nativeLeft * upScale) / uiParentScale
	nativeTop = (nativeTop * upScale) / uiParentScale

	-- Down/Text's relationship to Up (or to each other) - read from the
	-- captured GetPoint() data above, not assumed. If a captured
	-- relativeTo isn't one of the other two elements in this trio (e.g.
	-- natively anchored straight to MainMenuBarArtFrame instead), falls
	-- back to reproducing the exact same real on-screen delta from Up's
	-- own native corner, measured while every one of these three frames
	-- is still at its true, un-reparented Blizzard position. This delta
	-- is a same-family (Up/Down/Text all share one native ancestor chain)
	-- measurement, so no GetEffectiveScale correction is needed for it,
	-- unlike the UIParent-crossing nativeLeft/nativeTop above.
	self.pageIndicatorDownFollowsUp = (downRelTo == up)
	self.pageIndicatorTextFollowsUp = (textRelTo == up)
	self.pageIndicatorTextFollowsDown = (textRelTo == down)

	local downLeft, downTop = down:GetLeft(), down:GetTop()
	local textLeft, textTop = text:GetLeft(), text:GetTop()

	if not self.pageIndicatorDownFollowsUp and downLeft and downTop then
		self.pageIndicatorDownDeltaX = downLeft - up:GetLeft()
		self.pageIndicatorDownDeltaY = downTop - up:GetTop()
	end

	if not (self.pageIndicatorTextFollowsUp or self.pageIndicatorTextFollowsDown)
		and textLeft and textTop then
		self.pageIndicatorTextDeltaX = textLeft - up:GetLeft()
		self.pageIndicatorTextDeltaY = textTop - up:GetTop()
	end

	local container = CreateFrame("Frame", "BTVanillaPageIndicatorContainer", UIParent)
	container:SetFrameStrata("HIGH")

	up:SetParent(container)
	down:SetParent(container)
	text:SetParent(container)

	self.pageIndicatorContainer = container
	self.pageIndicatorUp = up
	self.pageIndicatorDown = down
	self.pageIndicatorText = text

	if not BTVanillaDB.mainBarPageIndicatorNativeAnchor then
		BTVanillaDB.mainBarPageIndicatorNativeAnchor = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	if not BTVanillaDB.mainBarPageIndicatorPosition then
		BTVanillaDB.mainBarPageIndicatorPosition = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	self:ApplyPageIndicatorShape()
	self:ApplyPageIndicatorPosition()
	self:ApplyPageIndicatorVisibility()

	self:Print(
		"Page Indicator captured: " .. tostring(container:GetWidth()) ..
		"x" .. tostring(container:GetHeight()) ..
		" (native anchor x=" .. tostring(nativeLeft) ..
		", y=" .. tostring(nativeTop) .. ")"
	)
end

-- Up is always reanchored to the container's own TOPLEFT (it has to be -
-- it's the one frame this addon's own drag/position system moves the
-- whole container by). Down and the page-number text are each handled
-- per the real native relationship CreatePageIndicatorContainer captured
-- via GetPoint() before anything was reparented:
--   - If natively anchored directly to Up (or, for Text, to Down) -
--     SetParent never rewrote that anchor, so it's already exactly
--     correct and is left completely untouched here.
--   - Otherwise, reproduced as a TOPLEFT-of-container offset using the
--     real screen-space delta from Up's own native corner, captured at
--     the same time (mathematically identical to "translate its native
--     offset from its true ancestor to be relative to the container
--     instead", since Up sits at the container's own (0,0)).
-- Either way this reuses Blizzard's own already-correct relative layout
-- instead of reconstructing one from absolute screen coordinates.
function BTV:ApplyPageIndicatorShape()
	local container = self.pageIndicatorContainer
	local up = self.pageIndicatorUp
	local down = self.pageIndicatorDown
	local text = self.pageIndicatorText

	if not container or not up or not down or not text then
		return
	end

	up:ClearAllPoints()
	PixelSetPoint(up, "TOPLEFT", container, "TOPLEFT", 0, 0)

	if not self.pageIndicatorDownFollowsUp then
		down:ClearAllPoints()
		PixelSetPoint(
			down,
			"TOPLEFT",
			container,
			"TOPLEFT",
			self.pageIndicatorDownDeltaX or 0,
			self.pageIndicatorDownDeltaY or 0
		)
	end

	if not (self.pageIndicatorTextFollowsUp or self.pageIndicatorTextFollowsDown) then
		-- PixelSetPoint already safely falls back to plain SetPoint here
		-- (text is a FontString, no GetEffectiveScale - see PixelSetPoint's
		-- own comment above).
		text:ClearAllPoints()
		PixelSetPoint(
			text,
			"TOPLEFT",
			container,
			"TOPLEFT",
			self.pageIndicatorTextDeltaX or 0,
			self.pageIndicatorTextDeltaY or 0
		)
	end

	-- Container bounding box derived from the three real elements' actual
	-- current on-screen extents (a same-native-family measurement, exactly
	-- like Core.lua's CaptureNativeSpacing gap math - no cross-tree
	-- GetEffectiveScale correction needed here), rather than a formula that
	-- assumes any particular chain topology - correct regardless of which
	-- branch above actually ran for Down/Text.
	local left, top, right, bottom = up:GetLeft(), up:GetTop(), up:GetRight(), up:GetBottom()

	local function Expand(l, t, r, b)
		if l and t and r and b then
			if l < left then left = l end
			if t > top then top = t end
			if r > right then right = r end
			if b < bottom then bottom = b end
		end
	end

	Expand(down:GetLeft(), down:GetTop(), down:GetRight(), down:GetBottom())
	Expand(text:GetLeft(), text:GetTop(), text:GetRight(), text:GetBottom())

	local width = (right or 0) - (left or 0)
	local height = (top or 0) - (bottom or 0)

	if width <= 0 then
		width = up:GetWidth() or 1
	end
	if height <= 0 then
		height = up:GetHeight() or 1
	end

	PixelSetSize(container, width, height)

	container:SetScale(BTVanillaDB.mainBarPageIndicatorScale or 1)
end

function BTV:ApplyPageIndicatorPosition()
	local pos = BTVanillaDB.mainBarPageIndicatorPosition
	local container = self.pageIndicatorContainer

	if not pos or not container then
		return
	end

	container:ClearAllPoints()
	PixelSetPoint(
		container,
		pos.point or "TOPLEFT",
		UIParent,
		pos.relativePoint or "BOTTOMLEFT",
		pos.x or 0,
		pos.y or 0
	)

	-- settingsKey = 1 (not a "simple bar page" string key like Bag Bar/
	-- Micro Menu/Stance Bar/Latency Bar use) - this element has no page of
	-- its own; its Scale slider lives directly on the Main Bar's (bar 1's)
	-- own settings page (Settings.lua), so a right-click opens that page
	-- instead.
	EnsureContainerOverlay(
		container,
		self.StartPageIndicatorDrag,
		self.StopPageIndicatorDrag,
		1,
		self.SetPageIndicatorScale,
		nil,
		"Page Indicator"
	)
end

-- Settings.lua's Main Bar page Scale slider (only shown while
-- mainBarPaginationEnabled is true) writes through this - mirrors
-- SetStanceBarScale's exact clamp/write/apply template.
function BTV:SetPageIndicatorScale(scale)
	self:EnsureDB()

	scale = tonumber(scale)

	if not scale then
		return
	end

	scale = math.floor((scale * 10) + 0.5) / 10

	if scale < 0.5 then
		scale = 0.5
	end

	if scale > 2.0 then
		scale = 2.0
	end

	BTVanillaDB.mainBarPageIndicatorScale = scale

	if self.pageIndicatorContainer then
		self.pageIndicatorContainer:SetScale(scale)
	end
end

-- Mirrors ResetKeyRingPosition's exact structure: restore position from
-- the permanent mainBarPageIndicatorNativeAnchor snapshot (captured once
-- in CreatePageIndicatorContainer, never re-derived), then reset scale
-- to 1 via the existing setter.
function BTV:ResetPageIndicatorLayout()
	self:EnsureDB()

	local native = BTVanillaDB.mainBarPageIndicatorNativeAnchor

	if native then
		BTVanillaDB.mainBarPageIndicatorPosition = {
			point = native.point,
			relativePoint = native.relativePoint,
			x = native.x,
			y = native.y,
		}

		self:ApplyPageIndicatorPosition()
	end

	self:SetPageIndicatorScale(1)
end

-- No independent enable flag (unlike Bag Bar/Micro Menu/Stance Bar/
-- Latency Bar/Key Ring) - this element's visibility is entirely DERIVED
-- from BTVanillaDB.mainBarPaginationEnabled, per the feature's own spec
-- ("hidden entirely otherwise").
function BTV:ApplyPageIndicatorVisibility()
	local container = self.pageIndicatorContainer

	if not container then
		return
	end

	if BTVanillaDB.mainBarPaginationEnabled ~= false then
		container:Show()
	else
		container:Hide()
	end
end

function BTV:StartPageIndicatorDrag()
	local pos = BTVanillaDB.mainBarPageIndicatorPosition

	if not pos then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "pageIndicator"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopPageIndicatorDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	-- The Scale slider lives on the Main Bar's own settings page (barId
	-- 1) - see Settings.lua's GetOrCreateBarPage - since this element has
	-- no "simple bar page" of its own the way Bag Bar/Micro Menu/Stance
	-- Bar/Latency Bar do.
	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(1)
	end
end

-------------------------------------------------------------------------
-- Position reassert after combat / looting
--
-- MainMenuBarPerformanceBarFrame (Latency Bar) and KeyRingButton wrap a
-- single real native Blizzard frame directly, never reparented into a
-- container of our own - so if any native FrameXML code path calls
-- SetPoint/ClearAllPoints on that frame for its own reasons, our own
-- last-applied position is silently discarded with nothing to notice or
-- correct it. Bag Bar/Micro Menu/Stance Bar/Page Indicator's own
-- container frames are synthetic and never repositioned by Blizzard
-- directly, but the individual real buttons reparented into them are
-- still real native frames a native code path could re-anchor -
-- reasserting each container's own ApplyChainAnchoredShape alongside its
-- position closes the same class of gap for those four too.
--
-- Every Apply* call below is idempotent and safely no-ops if that
-- element was never built this session, so simply re-running them is
-- safe regardless of what actually caused the drift. Triggered on
-- PLAYER_REGEN_ENABLED (leaving combat) and LOOT_CLOSED (the loot window
-- closing) - chosen over CHAT_MSG_LOOT, which fires once per looted item
-- and would mean reasserting far more often than needed, and over
-- LOOT_OPENED, which fires too early, before looting has happened.
--
-- Default bars 1-5 are not included here: their real Blizzard button
-- frames are permanently hidden and Show()-neutered at login
-- (CreateFixedSlotDefaultBars above), so native FrameXML code can no
-- longer make them visibly move at all.
-------------------------------------------------------------------------

local function ReassertNativeElementPositions()
	BTV:ApplyBagBarPosition()
	BTV:ApplyBagBarShape()

	BTV:ApplyMicroMenuPosition()
	BTV:ApplyMicroMenuShape()

	BTV:ApplyStanceBarPosition()
	BTV:ApplyStanceBarShape()

	BTV:ApplyKeyRingPosition()

	BTV:ApplyLatencyBarPosition()

	-- Experience Bar: same single-native-frame risk class as the Latency
	-- Bar/Key Ring above (MainMenuExpBar isn't reparented into a
	-- TrustyBars-owned container) - reasserted here for the same reason.
	BTV:ApplyExpBarPosition()

	BTV:ApplyPageIndicatorPosition()
	BTV:ApplyPageIndicatorShape()
end

local positionReassertFrame = CreateFrame("Frame", "BTVanillaPositionReassertFrame")
positionReassertFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
positionReassertFrame:RegisterEvent("LOOT_CLOSED")
positionReassertFrame:SetScript("OnEvent", ReassertNativeElementPositions)
