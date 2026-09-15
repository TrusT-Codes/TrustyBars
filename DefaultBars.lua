-- DefaultBars.lua
-- Owns bars 1-5: the fixed-id "default bars" wrapping Blizzard's own
-- MainMenuBar/MultiBarBottomLeft/MultiBarBottomRight/MultiBarRight/
-- MultiBarLeft frames (see Bar.lua/Button.lua for the bars 6+ pool model).
-- Only repositions/reflows/resizes/shows-hides these real frames, never
-- touches their action-slot bindings.
--
-- Also owns the shared chain/grid-anchored container engine and drag
-- engine (BuildChainAnchoredContainer, ApplyChainAnchoredShape,
-- ApplyGridAnchoredShape, EnsureContainerOverlay, InstallReanchorGuard,
-- InstallShowGuard, EnsureDragFrame, etc.) that NativeElements.lua,
-- PetStanceBars.lua, and ExperienceBar.lua build on. Those 3 files make
-- top-level (file-load-time) calls into these functions, so they MUST
-- load after this file or the client throws "attempt to call nil value"
-- on login.

local ACAB = AlternativeClassicActionBars

-------------------------------------------------------------------------
-- Frame name mapping for the 5 default action bars (12 buttons each,
-- numbered 1-12), centralized here since exact FrameXML names aren't
-- guaranteed on this client fork.
-------------------------------------------------------------------------

ACAB.DEFAULT_BAR_FRAME_PREFIXES = {
	[1] = "ActionButton",             -- Main bar (MainMenuBar).
	[2] = "MultiBarBottomLeftButton", -- Bottom Left.
	[3] = "MultiBarBottomRightButton",-- Bottom Right.
	[4] = "MultiBarRightButton",      -- Right.
	[5] = "MultiBarLeftButton",       -- Right 2.
	[ACAB.PET_BAR_ID] = "PetActionButton", -- Pet Bar (only 10 real frames -
	                                      -- GetDefaultBarButtons' own "stop
	                                      -- at first missing frame" loop
	                                      -- naturally returns a 10-length
	                                      -- table).
	[ACAB.STANCE_BAR_ID] = "ShapeshiftButton", -- Stance Bar (styled mode) -
	                                      -- only for hide+neuter and the
	                                      -- initial anchor/spacing capture;
	                                      -- content is the shapeshift-form
	                                      -- API instead (Button.lua isStanceSlot).
}

-- Real vanilla stance bars top out at 10 slots (ShapeshiftButton1-10).
-- GetStanceBarButtons stops at the first missing frame instead of
-- assuming all 10 exist, the same tolerance as GetDefaultBarButtons.
ACAB.MAX_STANCE_BUTTONS = 10

-- Returns an ordered table (1-12) of the real Blizzard button frames for
-- a given default bar id, or nil if the id isn't a known default bar or
-- the global frames don't exist yet (e.g. called too early).
function ACAB:GetDefaultBarButtons(id)
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
function ACAB:GetMainBarEffectivePage()
	self:EnsureDB()

	local page = 1

	if ACABDB.mainBarPaginationEnabled ~= false then
		page = CURRENT_ACTIONBAR_PAGE or 1
	end

	if ACABDB.mainBarStanceSwapEnabled ~= false and page == 1 then
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
function ACAB:GetActiveStanceIndex()
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
function ACAB:GetMainBarSlotForIndex(slotIndex)
	local page = self:GetMainBarEffectivePage()

	if page >= 7 and page <= 9 then
		local stanceIndex = self:GetActiveStanceIndex()

		local assignedId = stanceIndex
			and ACABDB.mainBarStanceBarAssignment
			and ACABDB.mainBarStanceBarAssignment[stanceIndex]

		local slot = assignedId and self:GetExtraBarSlotForIndex(assignedId, slotIndex)

		if slot then
			return slot
		end
	elseif page ~= 1 then
		local assignedId = ACABDB.mainBarPageBarAssignment
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
function ACAB:RefreshMainBarSlots()
	local bar = self.bars and self.bars[1]

	if bar then
		self:ApplyBarShape(bar)
	end
end

-- Settings.lua General tab checkboxes write through these. Neither toggle
-- changes bar 1's visibility, only which action slots its buttons read
-- from, so both reapply via RefreshMainBarSlots instead of Show()/Hide().
function ACAB:SetMainBarPaginationEnabled(enabled)
	self:EnsureDB()

	ACABDB.mainBarPaginationEnabled = enabled and true or false

	self:RefreshMainBarSlots()

	-- Page Indicator visibility is driven by this same toggle - it has no
	-- independent enable flag of its own.
	if self.ApplyPageIndicatorVisibility then
		self:ApplyPageIndicatorVisibility()
	end
end

function ACAB:SetMainBarStanceSwapEnabled(enabled)
	self:EnsureDB()

	ACABDB.mainBarStanceSwapEnabled = enabled and true or false

	self:RefreshMainBarSlots()
end

-- Runs after real vanilla's ChangeActionBarPage (fires on every Shift/Ctrl
-- page swap and the page-arrow clicks) has updated CURRENT_ACTIONBAR_PAGE,
-- so RefreshMainBarSlots always reads the new value. Registered once at
-- file load since FrameXML's ChangeActionBarPage is already defined by
-- the time addon Lua files load.
if hooksecurefunc and ChangeActionBarPage then
	hooksecurefunc("ChangeActionBarPage", function()
		ACAB:RefreshMainBarSlots()
	end)
end

-- UPDATE_BONUS_ACTIONBAR fires whenever the player's stance/form/stealth
-- state changes. BonusActionBarFrame is a separate native frame from
-- ActionButton1-12 that Blizzard shows as an overlay any time bonus/
-- stance content becomes active - hiding ActionButton1-12 does nothing to
-- suppress it. Hidden and Show()-neutered unconditionally here (not gated
-- on mainBarStanceSwapEnabled), since ACAB' own replica buttons are
-- the sole visual representation of bar 1 regardless of that toggle.
function ACAB:HideBonusActionBarFrame()
	self:NeuterFrameShow(BonusActionBarFrame)
end

-------------------------------------------------------------------------
-- "Disable Blizzard Art" (General tab checkbox)
--
-- Hides/shows MainMenuBarArtFrame's own regions (GetRegions(), not the
-- frame itself - that would take ActionButton1-12, its real children,
-- down with it) so bar 1's replica buttons show against the user's UI.
--
-- MainMenuBarArtFrame stays pinned at strata "MEDIUM" level 5 regardless
-- of the checkbox - must stay strictly between MainMenuExpBar's level 2
-- (XP bar fill would bleed past the art) and ACAB bars' level 10
-- (bars would render behind the art). Do not change without
-- re-verifying both those frames' levels.
--
-- Bars 2-5 have no equivalent art frame in vanilla FrameXML.
function ACAB:ApplyBlizzardArtVisibility()
	local artFrame = MainMenuBarArtFrame

	if not artFrame then
		return
	end

	self:EnsureDB()

	artFrame:SetFrameStrata("MEDIUM")

	-- See this section's header comment for why level 5 specifically.
	artFrame:SetFrameLevel(5)

	local hide = ACABDB.disableBlizzardArt

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

-- PixelUtil.SetPoint requires GetEffectiveScale() on both region and its
-- relativeTo anchor - FontString/Texture regions lack it. Falls back to
-- plain SetPoint when either side lacks GetEffectiveScale instead of
-- erroring (e.g. Page Indicator's MainMenuBarPageNumber FontString).
function ACAB:PixelSetPoint(region, ...)
	local relativeTo = arg[2]
	local canPixelSnap = region and region.GetEffectiveScale
		and (not relativeTo or relativeTo.GetEffectiveScale)

	if PixelUtil and PixelUtil.SetPoint and canPixelSnap then
		PixelUtil.SetPoint(region, unpack(arg))
	else
		region:SetPoint(unpack(arg))
	end
end

function ACAB:PixelSetSize(region, width, height)
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

-- Positions and grid-reflows default bar `id`'s 12 real Blizzard buttons
-- per its saved config (point/relativePoint/x/y/cols/rows/buttonSize).
-- Delegates to Bar.lua's own ApplyBarPosition/ApplyBarShape against this
-- bar's real Bar.lua bar object (self.bars[id]), including bar 1's own
-- dynamic per-button slot resolution (cfg.dynamicMainBar).
function ACAB:ApplyDefaultBarShape(id)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[id]

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
function ACAB:SetDefaultBarButtonSize(id, size)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[id]

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
-- ACABDB.defaultBars[id] table) then reapplies via Bar.lua's own
-- ApplyBarShape.
function ACAB:SetDefaultBarSpacing(id, spacing)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[id]

	if not cfg then
		return
	end

	-- Vanilla-only real minimum spacing - see Bar.lua's SetBarSpacing
	-- for why. Mirrors that clamp exactly.
	local minSpacing = self:IsVanillaBorderStyle() and self.VANILLA_SPACING_FLOOR or 0

	spacing = self:ClampSpacingSetting(spacing, minSpacing, 20)

	if not spacing then
		return
	end

	cfg.spacing = spacing

	local bar = self.bars and self.bars[id]

	if bar then
		self:ApplyBarShape(bar)
	end

	-- Vanilla-style grid spacing (ACAB:GetLayoutGridSpacing, Core.lua)
	-- includes Main Bar's real configured spacing, not just its
	-- buttonSize - see that function's own comment.
	if id == 1 and self:IsEditMode() then
		self:RebuildLayoutGrid()
	end
end

-------------------------------------------------------------------------
-- Position (live). Default bars only move via x/y (point/relativePoint
-- stay whatever seedDefaultBars chose) - dragging isn't supported since
-- they're real Blizzard frames, not ACAB' own draggable bar frame.
-------------------------------------------------------------------------

-- Delegates to Bar.lua's own SetBarPosition.
function ACAB:SetDefaultBarPosition(id, x, y)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[id]

	if not cfg then
		return
	end

	local bar = self.bars and self.bars[id]

	if bar then
		self:SetBarPosition(bar, x, y)
	end
end

-------------------------------------------------------------------------
-- Reset to Blizzard default layout (position, spacing, grid shape, size)
--
-- Restores position/spacing from cfg.nativeAnchor/cfg.nativeSpacing, the
-- pristine snapshots Core.lua's seedDefaultBars captured once before
-- ACAB ever touched this bar - never re-read from the live frame,
-- which by reset time reflects wherever the user last dragged it.
-- Grid shape/button size restore from the fixed ACAB.DEFAULT_BAR_GRID/
-- ACAB.BUTTON_SIZE constants instead.
-------------------------------------------------------------------------

-- Restores position, grid shape, and button size for default bar `id`,
-- applied through Bar.lua's own ApplyBarPosition/SetBarLayout/
-- SetBarButtonSize. ApplyBarShape is called explicitly afterward so the
-- restored spacing takes visual effect even if SetBarLayout was skipped
-- (e.g. no grid entry for this id).
function ACAB:ResetDefaultBarLayout(id)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[id]

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

-- Toggling bar 2 (Bottom Left) also reflows the Stance Bar's position
-- (ReflowStanceBarForBar2Toggle below) to avoid overlap - real vanilla's
-- own ShapeshiftBar_UpdatePosition() no longer has any effect once the
-- Stance Bar's buttons are reparented into their own synthetic container.
function ACAB:SetDefaultBarEnabled(id, enabled)
	if id == 1 then
		-- Bar 1 (Main) has no enable/disable - always active.
		return
	end

	self:EnsureDB()

	local cfg = ACABDB.defaultBars[id]

	if not cfg then
		return
	end

	enabled = enabled and true or false

	-- Captured before cfg.enabled is overwritten - Reflow*ForBar*Toggle must
	-- only fire on an actual state change, not every call (e.g.
	-- ApplyAllDefaultBars calls this at login with the already-current value).
	local wasEnabled = cfg.enabled and true or false

	cfg.enabled = enabled

	-- Pet Bar in native mode has no self.bars[id] pool bar (see
	-- CreateFixedSlotDefaultBars) - the chain-anchored container is its
	-- visibility target instead.
	local bar = self.bars and self.bars[id]
	local isNativePetBar = id == self.PET_BAR_ID and self:IsPetBarNativeModeEffective()

	if isNativePetBar then
		bar = self.petBarNativeContainer
	end

	-- Stance Bar native mode has no self.bars[id] pool bar - `bar` stays nil,
	-- a no-op below. Its native visibility uses the separate
	-- ACABDB.stanceBarEnabled flag instead of this function's
	-- cfg.enabled (styled mode only) - intentionally separate, do not merge.

	if bar then
		-- Pet Bar additionally requires a real controllable pet action bar
		-- right now (PetHasActionBar) on top of the user's own enabled
		-- toggle - re-evaluated every call, including the reactive
		-- PET_BAR_UPDATE/UNIT_PET refresh below.
		local shouldShow = enabled

		if enabled and id == self.PET_BAR_ID then
			shouldShow = PetHasActionBar and PetHasActionBar() and true or false
		end

		if shouldShow then
			bar:Show()
		else
			bar:Hide()

			-- Container's overlay is parented to UIParent, not the
			-- container - hiding the container doesn't cascade to it.
			if isNativePetBar and bar.ACABOverlay then
				bar.ACABOverlay:Hide()
				bar.ACABOverlay:EnableMouse(false)
			end
		end
	end

	if id == 2 and enabled ~= wasEnabled and ACABDB.useDefaultLayout ~= false then
		self:ReflowStanceBarForBar2Toggle(enabled)
	end

	if id == 3 and enabled ~= wasEnabled and ACABDB.useDefaultLayout ~= false then
		self:ReflowPetBarForBar3Toggle(enabled)
	end

	-- Cast Bar independently stacks above an actually-shown Pet Bar
	-- (GetCastBarBaselineY, NativeElements.lua) - re-evaluated on every
	-- Pet Bar call since its real shown state can change reactively
	-- (PetHasActionBar above) without cfg.enabled itself changing.
	if id == self.PET_BAR_ID and ACABDB.useDefaultLayout ~= false and self.ReflowCastBarForStackToggle then
		self:ReflowCastBarForStackToggle()
	end

	-- Matches native's own dependency (bar 5 requires bar 4 - see
	-- FixRightActionBar2Checkbox) - user can opt out via the General tab.
	if id == 4 then
		if enabled ~= wasEnabled and not enabled and not ACABDB.bypassRightActionBar2Dependency then
			self:SetDefaultBarEnabled(5, false)
		end

		-- Refreshes bar 5's own Settings UI (sidebar + page checkbox) since
		-- it locks/unlocks based on bar 4's state.
		if enabled ~= wasEnabled and ACAB:IsSettingsFrameCreated() then
			ACAB:RefreshBarList()
			ACAB:RefreshBarSettingsPage(5)
		end
	end

	-- Mirrors state into the native "Show ... ActionBar" global just so
	-- the Interface Options checkbox doesn't look stuck - cfg.enabled
	-- above remains the sole visual authority.
	local nativeGlobal = ACAB.SHOW_MULTI_ACTIONBAR_GLOBAL[id]

	if nativeGlobal then
		-- Stored/compared as string "1"/"0" (LOCK_ACTIONBAR convention).
		-- Do NOT call MultiActionBar_Update() here - it got "Right
		-- ActionBar 2" (bar 5) stuck permanently disabled after bar 4 was
		-- toggled off once. Setting the global alone is enough for the
		-- real Options panel checkbox to read correctly next time it's shown.
		setglobal(nativeGlobal, enabled and "1" or nil)

		-- This custom Options framework only reads the global at panel-show
		-- time, not reactively - set the control directly too so an
		-- already-open panel stays synced.
		local control = getglobal("OptionsFrameCheckButton" .. tostring(id) .. "Control")

		if control and control.SetChecked then
			control:SetChecked(enabled)
		end
	end

	self:FixRightActionBar2Checkbox()
end

-------------------------------------------------------------------------
-- Pet Bar auto-hide (no controllable pet action bar right now)
--
-- Re-evaluates through SetDefaultBarEnabled above (the single Show/Hide
-- authority for this id) rather than calling bar:Show()/:Hide() directly.
-- Event names (PET_BAR_UPDATE, UNIT_PET, PLAYER_CONTROL_LOST/GAINED)
-- still need live confirmation on this client - if one doesn't fire, Pet
-- Bar just re-checks visibility on login/target-change instead of erroring.
-------------------------------------------------------------------------

function ACAB:RefreshPetBarVisibility()
	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[self.PET_BAR_ID]

	if cfg then
		self:SetDefaultBarEnabled(self.PET_BAR_ID, cfg.enabled)
	end

	-- Re-chain-anchors the real buttons back into our container - native
	-- code re-anchors them directly on these same events, same as
	-- RebuildStanceBarContainer's treatment of ShapeshiftBar_Update.
	if self.petBarNativeContainer then
		self:ApplyPetBarNativeShape()
	end
end

-- Reconciles our own cfg.enabled (bars 2-5) from the native
-- SHOW_MULTI_ACTIONBAR_1-4 globals whenever MultiActionBar_Update runs
-- (e.g. the real Interface Options checkbox's own OnClick). Only trusted
-- reactively within the current session - these globals don't survive a
-- real logout on this fork (see ACAB.SHOW_MULTI_ACTIONBAR_GLOBAL).
function ACAB:ReconcileDefaultBarEnabledFromNative()
	if not (ACABDB and ACABDB.defaultBars) then
		return
	end

	local id

	for id = 2, 5 do
		local nativeGlobal = ACAB.SHOW_MULTI_ACTIONBAR_GLOBAL[id]
		local cfg = ACABDB.defaultBars[id]

		if nativeGlobal and cfg then
			local nativeEnabled = getglobal(nativeGlobal) and true or false
			local currentEnabled = cfg.enabled and true or false

			if nativeEnabled ~= currentEnabled then
				-- Re-enters SetDefaultBarEnabled, which re-fires this same
				-- hook once more, but by then nativeEnabled ==
				-- currentEnabled already, so it's a harmless one-level
				-- no-op re-entry, not a loop.
				self:SetDefaultBarEnabled(id, nativeEnabled)

				-- Keep the Settings window's checkboxes in sync too, only if
				-- it's actually been built this session already.
				if ACAB:IsSettingsFrameCreated() then
					ACAB:RefreshBarList()
					ACAB:RefreshBarSettingsPage(id)
				end
			end
		end
	end

	self:FixRightActionBar2Checkbox()
end

-- This fork's Options -> Action Bars panel is a custom framework (not
-- stock FrameXML): "Show Right ActionBar 2" (bar 5) gets stuck disabled
-- instead of following "Show Right ActionBar" (bar 4) reactively. Bar 4's
-- state is mirrored onto it directly whenever bar 4/5 state changes, and
-- bar 4's checkbox click is hooked once since this framework doesn't call
-- native MultiActionBar_Update() on its own clicks.
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

function ACAB:FixRightActionBar2Checkbox()
	local control5 = getglobal("OptionsFrameCheckButton5Control")

	if control5 and control5.Enable and control5.Disable then
		local bar4Cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[4]
		local shouldEnable = (ACABDB and ACABDB.bypassRightActionBar2Dependency)
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
				ACAB:FixRightActionBar2Checkbox()
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
		ACAB:ReconcileDefaultBarEnabledFromNative()
	end)
end

-- Every default bar (1-5) delegates to Bar.lua's own SetBarLayout (which
-- also re-clamps buttonCount - always a no-op here in practice, since
-- every grid preset totals exactly 12 and default bars have no
-- buttons-shown stepper, but keeping the exact same call custom bars use
-- costs nothing and stays consistent).
function ACAB:SetDefaultBarLayout(id, cols, rows)
	self:EnsureDB()

	local bar = self.bars and self.bars[id]

	if bar then
		self:SetBarLayout(bar, cols, rows)
	end
end

-------------------------------------------------------------------------
-- Builds every default bar (1-5) as a Bar.lua bar object.
--
-- Must run once at PLAYER_LOGIN before ApplyAllDefaultBars - every
-- function above reads self.bars[id], which this creates. For each bar:
-- permanently hides its 12 real Blizzard buttons (Show neutered to a
-- no-op; native keybind dispatch keeps working) and builds this bar's
-- own Bar.lua/Button.lua button pool into self.bars[id], the same table
-- custom bars (id 6+) live in.
--
-- If discovery failed for one of bars 2-5, that bar is skipped and keeps
-- its real Blizzard buttons visible until a later login succeeds.
-------------------------------------------------------------------------

-- Real vanilla's ShapeshiftBar_Update() reads MultiBarBottomLeft:IsShown()
-- to decide whether the Stance Bar can expand its border into that space,
-- swapping ShapeshiftButtonN's NormalTexture bigger when it thinks the
-- space is empty (confirmed live: 50x50 border when shown, 64x64 when
-- hidden, on an unchanged 30x30 button). Since ACAB permanently
-- hides bar 2's own 12 buttons regardless of the checkbox, vanilla would
-- otherwise wrongly inflate the Stance Bar's border - forcing this parent
-- frame permanently shown (Hide neutered, same as HideBonusActionBarFrame)
-- keeps ShapeshiftBar_Update() on the correct compact branch instead.
local hasNeuteredMultiBarBottomLeft = false

local function ForceShowMultiBarBottomLeft(parent)
	if not parent then
		return
	end

	parent:Show()

	if not hasNeuteredMultiBarBottomLeft then
		parent.Hide = function() end
		hasNeuteredMultiBarBottomLeft = true
	end
end

-- Each real button's Show method is permanently overridden to a no-op
-- once hidden, so any later native call (e.g. ACTIONBAR_SHOWGRID's sweep)
-- can't make it visible again.
function ACAB:CreateFixedSlotDefaultBars()
	self:EnsureDB()

	local i

	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		local id = self.DEFAULT_BAR_IDS[i]
		local cfg = ACABDB.defaultBars[id]

		-- Pet Bar in native mode skips the pool-button replica entirely -
		-- CreatePetBarNativeContainer builds its own chain-anchored
		-- container from the real PetActionButton1-10 frames instead, and
		-- those must stay genuinely shown/clickable, not neutered below.
		if id == self.PET_BAR_ID and cfg and self:IsPetBarNativeModeEffective() then
			-- Handled by CreatePetBarNativeContainer.
		elseif id == self.STANCE_BAR_ID and cfg and self:IsStanceBarNativeModeEffective() then
			-- Handled by CreateStanceBarContainer - the pre-existing native
			-- machinery, entirely separate from this pool-button path.
		elseif cfg and (cfg.fixedActionSlots or cfg.dynamicMainBar) and not self.bars[id] then
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

				if id == 2 then
					ForceShowMultiBarBottomLeft(nativeButtons[1]:GetParent())

					-- Forces an immediate recompute for a login that
					-- already ran ShapeshiftBar_Update() against the
					-- wrong (hidden) state above, before this fix ran.
					-- Native code re-runs this itself on every later
					-- UPDATE_SHAPESHIFT_FORMS regardless.
					if ShapeshiftBar_Update then
						ShapeshiftBar_Update()
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

function ACAB:ApplyAllDefaultBars()
	self:EnsureDB()

	local i

	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		local id = self.DEFAULT_BAR_IDS[i]
		local cfg = ACABDB.defaultBars[id]

		if cfg then
			if id ~= 1 then
				-- Bars 2-5: cfg.enabled is the sole visibility source now
				-- that their real Blizzard buttons are permanently hidden.
				self:SetDefaultBarEnabled(id, cfg.enabled)
			end

			-- Always reapply shape/overlay regardless of enabled state -
			-- vanilla anchors extra multibars relative to each other, not
			-- UIParent, so a skipped bar would stay on that native anchor
			-- chain instead of getting its own independent overlay.
			self:ApplyDefaultBarShape(id)
		end
	end
end

-------------------------------------------------------------------------
-- Default bar / stance bar dragging (Edit Layout mode,
-- useDefaultLayout == false only)
--
-- Default bars 1-5 drag via Bar.lua's own EnsureBarOverlay/StartBarDrag/
-- StopBarDrag (dragKind == "bar"). The Stance Bar (dragKind == "stanceBar")
-- has no Bar.lua container of its own - it's tracked/repositioned directly
-- through this same shared cursor-tracking OnUpdate mechanism.
-------------------------------------------------------------------------

-- Created lazily, exactly once - shared by every default-bar AND
-- stance-bar drag (only one drag can ever be in progress at a time,
-- since it's driven by mouse button state), so a second frame per drag
-- kind would be redundant.
local dragFrame

-- Dragging is intercepted at the frame-stacking level: Bar.lua's overlay
-- frames sit mouse-enabled in HIGH strata over the real buttons, so the
-- native OnDragStart handler never fires and LOCK_ACTIONBAR is never
-- touched.

function ACAB:GetCursorPositionUIScale()
	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / scale, y / scale
end

-- Shared per-tick snap injection for every dragKind below and Bar.lua's
-- own bar drag - nudges pos.x/pos.y in place before the caller applies
-- them. No-ops when the setting is off or the frame can't report a
-- size/scale yet.
--
-- pos.point/pos.relativePoint are always "TOPLEFT"/"BOTTOMLEFT" (every
-- caller normalizes to this pair before dragging), so pos.x/pos.y convert
-- to/from screen pixels via this frame's effective scale alone.
-- centerSnap (Cast Bar only) uses ComputeCenterGridSnapAdjustment instead
-- of ComputeGridSnapAdjustment.
function ACAB:ApplyDragSnap(frame, pos, centerSnap)
	if not frame or not pos then
		return
	end

	local scale = frame:GetEffectiveScale()
	local width = frame:GetWidth()
	local height = frame:GetHeight()

	if not scale or not width or not height then
		return
	end

	-- Inflates the dragged box by its visual inset (Core.lua's
	-- GetElementVisualInset - nonzero only for default bars 1-5, and NOT
	-- symmetric top vs. bottom) so it compares border-edge-to-border-edge
	-- against every target's own inset-adjusted box. Deflated back out
	-- before writing to pos.x/pos.y.
	local il, ir, it, ib = ACAB:GetElementVisualInset(frame)
	local ilPx, irPx, itPx, ibPx = il * scale, ir * scale, it * scale, ib * scale

	local proposedLeft = pos.x * scale - ilPx
	local proposedTop = pos.y * scale + itPx

	local boxWidth = width * scale + ilPx + irPx
	local boxHeight = height * scale + itPx + ibPx

	-- Snap to Adjacent Elements takes priority per axis - Snap to Grid
	-- only fills in whichever axis Adjacent Elements left unresolved.
	local adjLeft, adjTop = ACAB:ComputeSnapAdjustment(
		proposedLeft,
		proposedTop,
		boxWidth,
		boxHeight,
		frame
	)

	local gridLeft, gridTop

	if centerSnap then
		gridLeft, gridTop = ACAB:ComputeCenterGridSnapAdjustment(
			proposedLeft,
			proposedTop,
			boxWidth,
			boxHeight,
			scale
		)
	else
		gridLeft, gridTop = ACAB:ComputeGridSnapAdjustment(
			proposedLeft,
			proposedTop,
			boxWidth,
			boxHeight,
			scale
		)
	end

	local adjustedLeft = adjLeft or gridLeft
	local adjustedTop = adjTop or gridTop

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
function ACAB:DefaultBarDrag_OnUpdate()
	local cx, cy = ACAB:GetCursorPositionUIScale()
	local dx = cx - this.dragStartCursorX
	local dy = cy - this.dragStartCursorY

	if this.dragKind == "stanceBar" then
		local pos = ACABDB.stanceBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(ACAB.stanceBarContainer, pos)

			ACAB:ApplyStanceBarPosition()
		end
	elseif this.dragKind == "bagBar" then
		local pos = ACABDB.bagBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(ACAB.bagBarContainer, pos)

			ACAB:ApplyBagBarPosition()
		end
	elseif this.dragKind == "microMenu" then
		local pos = ACABDB.microMenuPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(ACAB.microMenuContainer, pos)

			ACAB:ApplyMicroMenuPosition()
		end
	elseif this.dragKind == "keyRing" then
		local pos = ACABDB.keyRingPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(getglobal(ACAB.KEYRING_BUTTON_NAME), pos)

			ACAB:ApplyKeyRingPosition()
		end
	elseif this.dragKind == "latencyBar" then
		local pos = ACABDB.latencyBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(getglobal(ACAB.LATENCY_BAR_FRAME_NAME), pos)

			ACAB:ApplyLatencyBarPosition()
		end
	elseif this.dragKind == "expBar" then
		local pos = ACABDB.expBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(getglobal(ACAB.EXP_BAR_FRAME_NAME), pos)

			ACAB:ApplyExpBarPosition()
		end
	elseif this.dragKind == "castBar" then
		local pos = ACABDB.castBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(getglobal(ACAB.CAST_BAR_FRAME_NAME), pos, true)

			ACAB:ApplyCastBarPosition()
		end
	elseif this.dragKind == "pageIndicator" then
		local pos = ACABDB.mainBarPageIndicatorPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(ACAB.pageIndicatorContainer, pos)

			ACAB:ApplyPageIndicatorPosition()
		end
	elseif this.dragKind == "tooltip" then
		local pos = ACABDB.tooltipPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(ACAB.tooltipFrame, pos)

			ACAB:ApplyTooltipPosition()
		end
	elseif this.dragKind == "petBarNative" then
		-- Writes straight into the shared ACABDB.defaultBars[PET_BAR_ID]
		-- cfg (see ACAB:StartPetBarNativeDrag) so position stays in sync with
		-- the custom-styled Pet Bar's own x/y regardless of active mode.
		local cfg = ACABDB.defaultBars[ACAB.PET_BAR_ID]

		if cfg then
			cfg.x = this.dragStartX + dx
			cfg.y = this.dragStartY + dy

			ACAB:ApplyDragSnap(ACAB.petBarNativeContainer, cfg)

			ACAB:ApplyPetBarNativePosition()
		end
	elseif this.dragKind == "bar" then
		-- Bars 1-9: position lives directly on bar.config.x/y, read/written
		-- in place. ApplyBarPosition (not ApplyBarShape) is the minimal
		-- correct call - ApplyBarShape would also re-bind every button's
		-- action slot and re-run LayoutButtons on every tick.
		local bar = ACAB.bars and ACAB.bars[this.dragId]

		if bar and bar.config then
			local pos = {
				x = this.dragStartX + dx,
				y = this.dragStartY + dy,
			}

			ACAB:ApplyDragSnap(bar, pos)

			bar.config.x = pos.x
			bar.config.y = pos.y

			ACAB:ApplyBarPosition(bar)
		end
	end
end

function ACAB:EnsureDragFrame()
	if not dragFrame then
		dragFrame = CreateFrame("Frame", "ACABDefaultBarDragFrame", UIParent)
		dragFrame:Hide()
	end

	return dragFrame
end

-------------------------------------------------------------------------
-- Generic start/stop seam onto the shared cursor-tracking drag frame
-- above (dragFrame stays file-local to this file; EnsureDragFrame/
-- DefaultBarDrag_OnUpdate/GetCursorPositionUIScale are ACAB: methods so
-- other files can reach them post-split), exposed as ACAB methods so
-- Bar.lua's own StartBarDrag/StopBarDrag (bars 1-9) can initiate/finalize
-- a drag through this same mechanism.
-------------------------------------------------------------------------

function ACAB:StartSharedDrag(dragKind, dragId, startX, startY)
	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = dragKind
	frame.dragId = dragId
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = startX or 0
	frame.dragStartY = startY or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopSharedDrag()
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()
end

-- True only while both Edit Layout mode AND useDefaultLayout == false are
-- active - the single shared gate every default-bar-button/stance-bar
-- drag hook below checks before doing anything, mirroring
-- ACAB:IsEditMode()'s own nil-safety (this can in principle be queried
-- before EnsureDB has ever run).
function ACAB:CanDragDefaultLayout()
	return self:IsEditMode() and ACABDB and ACABDB.useDefaultLayout == false
end

-- Stance Bar position/spacing/scale/orientation/enable/drag: see the
-- "Stance Bar (chain-anchored container)" section further below, which
-- shares the BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay machinery with Bag Bar/Micro Menu/Key Ring/
-- Latency Bar.

-------------------------------------------------------------------------
-- Bag Bar / Micro Menu button-name constants, feeding the shared
-- chain/grid-anchored container engine below (BuildChainAnchoredContainer/
-- ApplyChainAnchoredShape/ApplyGridAnchoredShape/EnsureContainerOverlay).
-- The Bag Bar/Micro Menu position/shape/enable functions themselves live
-- in NativeElements.lua, which loads after this file.
--
-- Neither element has a single native container frame on real vanilla
-- 1.12.1, so each builds a synthetic container and reparents its real
-- buttons into it, chain-anchored button-to-button (Bartender2's own
-- pattern on this client generation).
--
-- Bag Bar = the 5 real vanilla bag buttons (no Key Ring). Micro Menu =
-- the 8 real micro-menu buttons ("Socials", not "Social" - real name).
-------------------------------------------------------------------------

ACAB.BAG_BAR_BUTTON_NAMES = {
	"CharacterBag0Slot",
	"CharacterBag1Slot",
	"CharacterBag2Slot",
	"CharacterBag3Slot",
	"MainMenuBarBackpackButton",
}

ACAB.MICRO_MENU_BUTTON_NAMES = {
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
-- GetStanceBarButtons.
function ACAB:GetButtonsByName(names)
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

-- Sorts a button list left-to-right by each frame's real, current
-- on-screen GetLeft() - must be called before any of these frames are
-- reparented/repositioned. Does not assume the name-list order above is
-- already the true native visual order.
function ACAB:SortButtonsByNativeLeft(buttons)
	table.sort(buttons, function(a, b)
		local aLeft = a:GetLeft() or 0
		local bLeft = b:GetLeft() or 0

		return aLeft < bLeft
	end)
end

-- Computes the per-pair gap across a chain of native button positions/
-- widths - used once at container-build time to seed this element's
-- permanent nativeSpacing baseline, never re-derived afterward. Uses the
-- median of the raw gaps for robustness against outliers.
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
-- sorted left-to-right by SortButtonsByNativeLeft) into it. Chain-
-- anchoring itself is factored out into ApplyChainAnchoredShape below, so
-- it can be re-run any time spacing/orientation/scale changes.
--
-- HIGH strata: without it this frame would render behind
-- MainMenuBarArtFrame's background art, not just during edit mode.
--
-- Returns the container plus button 1's captured native GetLeft()/
-- GetTop() (UIParent-absolute) and the chain's majority native gap
-- (ComputeMajorityGap) - the caller seeds nativeAnchor/nativeSpacing from
-- these, since the buttons' original positions aren't readable once
-- reparented.
function ACAB:BuildChainAnchoredContainer(frameName, buttons)
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
	-- ACAB:CaptureNativeAnchor, Database.lua). Converts through real screen pixels
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

-- Re-chain-anchors a container's buttons from its current spacing/
-- orientation and applies its current scale - shared by ApplyBagBarShape/
-- ApplyStanceBarShape. Micro Menu uses the separate fixed-grid
-- ApplyGridAnchoredShape instead (compacts into cols x rows cells).
--
-- horizontal (orientation == false): each button's TOPLEFT anchors to
-- the previous button's TOPRIGHT, offset by `spacing`.
-- vertical (orientation == true): TOPLEFT anchors to the previous
-- button's BOTTOMLEFT, offset downward by `spacing`.
--
-- Chains only currently-shown buttons (live IsShown() check every call,
-- not cached) - a hidden button must not reserve a chain slot.

-- Finds the first and last currently-shown button in a chain (shared by
-- ApplyChainAnchoredShape and EnsureContainerOverlay's initial anchor).
-- Returns first, last (both nil if every button is hidden).
-- forceAllShown treats every button as shown - used by Pet Bar's native
-- container when condense is off, so all 10 slots stay in a fixed chain.
function ACAB:GetChainShownEndpoints(container, forceAllShown)
	if not container or not container.chainButtons then
		return nil, nil
	end

	local buttons = container.chainButtons
	local first, last
	local i

	for i = 1, table.getn(buttons) do
		if buttons[i] and (forceAllShown or buttons[i]:IsShown()) then
			if not first then
				first = buttons[i]
			end

			last = buttons[i]
		end
	end

	return first, last
end

-- GetHitRectInsets() returns (left, right, top, bottom) trimming a
-- button's actual clickable/visible area inward from its frame edges.
-- Every Micro Menu button reports a 58px-tall frame but a (0,0,18,0)
-- inset - only the bottom 40px is real content, the top 18px is a
-- decorative flare. Returns 0 for frames without the API.
function ACAB:GetHitInsets(frame)
	if not frame or not frame.GetHitRectInsets then
		return 0, 0, 0, 0
	end

	local left, right, top, bottom = frame:GetHitRectInsets()

	return left or 0, right or 0, top or 0, bottom or 0
end

-- GetHitInsets' values are in `frame`'s own local unit system, unaffected
-- by the container's SetScale. `overlay` (parented straight to UIParent)
-- has a fixed effective scale that doesn't track the container's scale -
-- this converts a value from `frame`'s local units into `overlay`'s.
function ACAB:ScaleRatio(frame, overlay)
	local frameScale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
	local overlayScale = overlay and overlay.GetEffectiveScale and overlay:GetEffectiveScale()

	if not frameScale or not overlayScale or overlayScale == 0 then
		return 1
	end

	return frameScale / overlayScale
end

-- A frame's SetPoint offset is multiplied by its own SetScale() when
-- resolved against its parent, so a fixed pos.x/pos.y would visibly
-- drift as scale increases. Called BEFORE writing a changed scale, this
-- adjusts pos.x/pos.y so `corner` (one of TOPLEFT/TOPRIGHT/BOTTOMLEFT/
-- BOTTOMRIGHT) stays exactly where it was on screen. `localWidth`/
-- `localHeight` are the frame's scale-invariant design size
-- (frame:GetWidth()/GetHeight()) - localWidth is only read for a RIGHT
-- corner, localHeight only for a BOTTOM corner, so either may be omitted
-- when the caller's corner doesn't need it.
function ACAB:CompensateScaleKeepingCornerFixed(pos, oldScale, newScale, corner, localWidth, localHeight)
	if not pos or not oldScale or not newScale then
		return
	end

	if oldScale == newScale or oldScale <= 0 or newScale <= 0 then
		return
	end

	local ratio = oldScale / newScale
	localWidth = localWidth or 0
	localHeight = localHeight or 0

	local offsetX = 0
	local offsetY = 0

	if corner == "TOPRIGHT" or corner == "BOTTOMRIGHT" then
		offsetX = localWidth
	end

	if corner == "BOTTOMLEFT" or corner == "BOTTOMRIGHT" then
		offsetY = -localHeight
	end

	pos.x = ((pos.x or 0) + offsetX) * ratio - offsetX
	pos.y = ((pos.y or 0) + offsetY) * ratio - offsetY
end

-- forceAllShown (Pet Bar native container, condense off) skips every
-- IsShown() check below so all 10 slots stay chained at a fixed position
-- regardless of whether a pet ability is currently assigned to them.
function ACAB:ApplyChainAnchoredShape(container, spacing, orientation, scale, forceAllShown)
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
		if buttons[i] and (forceAllShown or buttons[i]:IsShown()) then
			first = buttons[i]
			firstIndex = i
			break
		end
	end

	if not first then
		-- Every button in this chain is currently hidden (e.g. a class
		-- with zero active stance forms) - collapse the container instead
		-- of leaving it at its last real size.
		self:PixelSetSize(container, 1, 1)
		container:SetScale(scale or 1)

		if container.ACABOverlay then
			container.ACABOverlay:ClearAllPoints()
			container.ACABOverlay:SetAllPoints(container)
		end

		return
	end

	-- `first`'s frame TOPLEFT must stay at container's TOPLEFT with no
	-- hit-rect trim - container's saved position (ACABDB.*Position)
	-- was captured against `first`'s raw frame corner
	-- (BuildChainAnchoredContainer's nativeLeft/nativeTop), so trimming
	-- here would shift every existing user's saved position. The overlay
	-- below has no such dependency, so it gets full trimming on every side.
	first:ClearAllPoints()
	self:PixelSetPoint(first, "TOPLEFT", container, "TOPLEFT", 0, 0)

	-- Main-axis seed (width for horizontal, height for vertical) stays
	-- `first`'s raw frame size, matching its untrimmed leading edge above.
	-- Cross-axis seed is seeded already-trimmed by `first`'s own hit-rect
	-- inset on that axis, so the loop below's visibleW/visibleH
	-- comparisons can shrink it below `first`'s untrimmed size when other
	-- buttons' real visible size is smaller (e.g. Micro Menu: 58 vs the
	-- real 40).
	local firstLeftSeed, firstRightSeed, firstTopSeed, firstBottomSeed = self:GetHitInsets(first)

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
			if forceAllShown or btn:IsShown() then
				local w = widths[i] or 0
				local h = heights[i] or 0

				local prevLeft, prevRight, prevTop, prevBottom = self:GetHitInsets(prevBtn)
				local btnLeft, btnRight, btnTop, btnBottom = self:GetHitInsets(btn)

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
					self:PixelSetPoint(btn, "TOPLEFT", prevBtn, "BOTTOMLEFT", 0, prevBottom - spacing + btnTop)

					totalHeight = totalHeight + spacing + h - prevBottom - btnTop

					local visibleW = w - btnLeft - btnRight

					if visibleW > totalWidth then
						totalWidth = visibleW
					end
				else
					-- Same reasoning, horizontal axis: real visible right
					-- of prevBtn = frame right - prevRight; real visible
					-- left of btn = frame left + btnLeft.
					self:PixelSetPoint(btn, "TOPLEFT", prevBtn, "TOPRIGHT", spacing - prevRight - btnLeft, 0)

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
				self:PixelSetPoint(btn, "TOPLEFT", prevBtn, "TOPLEFT", 0, 0)
			end
		end
	end

	-- Container's own size trims only the TRAILING edge (prevBtn's own
	-- hit-rect inset on whichever side it ends the chain) - shrinking from
	-- the far end never touches container's TOPLEFT origin, so this part
	-- is safe to always apply in full, unlike `first`'s own leading inset
	-- above.
	do
		local prevLeft, prevRight, prevTop, prevBottom = self:GetHitInsets(prevBtn)

		if orientation then
			totalHeight = totalHeight - prevBottom
		else
			totalWidth = totalWidth - prevRight
		end
	end

	self:PixelSetSize(container, totalWidth, totalHeight)
	container:SetScale(scale or 1)

	-- The overlay has no saved-position dependency (unlike `container`'s
	-- own TOPLEFT above), so it gets full trimming on every side -
	-- `first`'s own leading (left/top) inset and `prevBtn`'s (the last
	-- currently-shown button, tracked through the loop above) trailing
	-- (right/bottom) inset - re-applied every time this function runs
	-- (spacing/orientation/scale change, or a button's shown state
	-- changing, e.g. Talent unlocking).
	if container.ACABOverlay then
		local firstLeft, firstRight, firstTop, firstBottom = self:GetHitInsets(first)
		local lastLeft, lastRight, lastTop, lastBottom = self:GetHitInsets(prevBtn)
		local firstRatio = self:ScaleRatio(first, container.ACABOverlay)
		local lastRatio = self:ScaleRatio(prevBtn, container.ACABOverlay)
		local topFudge = container.overlayTopFudge or 0

		container.ACABOverlay:ClearAllPoints()
		container.ACABOverlay:SetPoint("TOPLEFT", first, "TOPLEFT", firstLeft * firstRatio, -(firstTop + topFudge) * firstRatio)
		container.ACABOverlay:SetPoint("BOTTOMRIGHT", prevBtn, "BOTTOMRIGHT", -lastRight * lastRatio, lastBottom * lastRatio)
	end
end

-- Fixed-grid layout for Micro Menu only (Bag Bar/Stance Bar keep using
-- ApplyChainAnchoredShape). cols x rows stays exactly as configured - a
-- currently-hidden button (e.g. TalentMicroButton below level 10) does not
-- reserve its own cell though: every currently-shown button compacts back
-- to fill grid cells in order, same "collapse empty slots" idea as the Pet
-- Bar's condense option, leaving any leftover cells empty at the end of the
-- grid instead of resizing cols/rows. Re-run by the UpdateMicroButtons hook
-- below whenever Blizzard shows/hides a button.
function ACAB:ApplyGridAnchoredShape(container, cols, rows, spacing, scale)
	if not container or not container.chainButtons then
		return
	end

	local buttons = container.chainButtons
	local widths = container.chainWidths
	local heights = container.chainHeights

	spacing = spacing or 0

	-- Uniform cell size (largest button on each axis), plus each axis' own
	-- hit-rect inset (GetHitInsets' comment above explains why: Micro Menu's
	-- real button frames are much taller than their visible content) - the
	-- row/column pitch below is measured edge-to-edge on real visible
	-- content, not raw frame size, or vertical spacing would show a big
	-- empty gap sized by that invisible padding.
	local cellWidth, cellHeight = 0, 0
	local leftInset, rightInset, topInset, bottomInset = 0, 0, 0, 0
	local shown = {}
	local shownCount = 0
	local i

	for i = 1, table.getn(buttons) do
		if (widths[i] or 0) > cellWidth then
			cellWidth = widths[i]
		end

		if (heights[i] or 0) > cellHeight then
			cellHeight = heights[i]
		end

		local btnLeft, btnRight, btnTop, btnBottom = self:GetHitInsets(buttons[i])

		if btnLeft > leftInset then
			leftInset = btnLeft
		end

		if btnRight > rightInset then
			rightInset = btnRight
		end

		if btnTop > topInset then
			topInset = btnTop
		end

		if btnBottom > bottomInset then
			bottomInset = btnBottom
		end

		if buttons[i]:IsShown() then
			shownCount = shownCount + 1
			shown[shownCount] = buttons[i]
		else
			-- Flag consumed by InstallReanchorGuard (installed on every
			-- Micro Menu button in CreateBagBarAndMicroMenu) - lets our own
			-- ClearAllPoints through while swallowing anything else that
			-- touches this frame.
			buttons[i].ACABApplyingMicroMenuPosition = true
			buttons[i]:ClearAllPoints()
			buttons[i].ACABApplyingMicroMenuPosition = nil
		end
	end

	-- container.overlayTopFudge (Micro Menu only, ACAB.MICRO_MENU_OVERLAY_TOP_FUDGE
	-- - Core.lua) is the same extra top trim the edit-mode overlay's own
	-- anchor applies beyond GetHitRectInsets() - folded in here too so row
	-- pitch lines up with where the overlay actually shows the button ending.
	local rowTopInset = topInset + (container.overlayTopFudge or 0)

	local colStep = cellWidth - leftInset - rightInset + spacing
	local rowStep = cellHeight - rowTopInset - bottomInset + spacing

	for i = 1, shownCount do
		local col, row = ButtonIndexToGridPos(i, cols)
		local xOff = col * colStep
		local yOff = -row * rowStep

		-- Same flag/reasoning as the hidden-button branch above.
		shown[i].ACABApplyingMicroMenuPosition = true
		shown[i]:ClearAllPoints()
		self:PixelSetPoint(shown[i], "TOPLEFT", container, "TOPLEFT", xOff, yOff)
		shown[i].ACABApplyingMicroMenuPosition = nil
	end

	local totalWidth = cellWidth + ((cols - 1) * colStep) - rightInset
	local totalHeight = cellHeight + ((rows - 1) * rowStep) - bottomInset

	self:PixelSetSize(container, totalWidth, totalHeight)
	container:SetScale(scale or 1)

	if container.ACABOverlay then
		local first = shown[1]
		local last = shown[shownCount]

		if first and last then
			local firstLeft, firstRight, firstTop, firstBottom = self:GetHitInsets(first)
			local lastLeft, lastRight, lastTop, lastBottom = self:GetHitInsets(last)
			local firstRatio = self:ScaleRatio(first, container.ACABOverlay)
			local lastRatio = self:ScaleRatio(last, container.ACABOverlay)
			local topFudge = container.overlayTopFudge or 0

			container.ACABOverlay:ClearAllPoints()
			container.ACABOverlay:SetPoint("TOPLEFT", first, "TOPLEFT", firstLeft * firstRatio, -(firstTop + topFudge) * firstRatio)
			container.ACABOverlay:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", -lastRight * lastRatio, lastBottom * lastRatio)
		end
	end
end

-- Shared overlay helper: drag ownership + right-click-to-settings,
-- mirroring Bar.lua's own EnsureBarOverlay (TOOLTIP strata). Takes the
-- container frame, drag start/stop callbacks, the settings-page key for
-- right-click, an optional scroll-to-scale setter, an optional
-- FrameLevel, and forceAllShown (same meaning as ApplyChainAnchoredShape's
-- own parameter).
--
-- scaleSetFn mirrors Button.lua's OnMouseWheel step/delta convention,
-- applied to scale instead of buttonSize.
--
-- level defaults to 100 - same-strata frames aren't reliably ordered by
-- creation order, only by explicit FrameLevel, so overlapping overlays
-- (e.g. Key Ring over Bag Bar) need distinct levels.
--
-- Overlay is parented to UIParent, not `container` - Key Ring/Latency Bar
-- wrap real native frames deep in Blizzard's own ancestor chain, so every
-- sibling overlay needs to compare FrameLevel within the same tree. This
-- means hiding the real frame does NOT cascade to hide its overlay - see
-- SetKeyRingEnabled/SetLatencyBarEnabled for the explicit overlay:Hide()
-- this requires.
function ACAB:EnsureContainerOverlay(container, startDragFn, stopDragFn, settingsKey, scaleSetFn, level, displayName, forceAllShown)
	if container.ACABOverlay then
		return container.ACABOverlay
	end

	local overlay = CreateFrame("Frame", nil, UIParent)

	overlay:SetFrameStrata("TOOLTIP")
	overlay:SetFrameLevel(level or 100)

	-- Chain-anchored containers (chainButtons exists) anchor the overlay
	-- directly to the real first/last currently-shown button instead of
	-- SetAllPoints(container) - see ApplyChainAnchoredShape's matching
	-- anchor below, which re-applies this on every later change. Other
	-- container kinds (Key Ring, Latency Bar, Page Indicator) have no
	-- chainButtons and keep the SetAllPoints(container) anchor.
	local chainFirst, chainLast = self:GetChainShownEndpoints(container, forceAllShown)

	if chainFirst and chainLast then
		-- Trimmed by each endpoint's own hit-rect inset, same formula as
		-- ApplyChainAnchoredShape's own matching overlay anchor below (see
		-- GetHitInsets' comment above for the Micro Menu case). Converted
		-- through ScaleRatio since `overlay` and the buttons don't share an
		-- effective scale once the container's own Scale slider is
		-- anything but 1, plus container.overlayTopFudge (Micro Menu only
		-- - see ACAB.MICRO_MENU_OVERLAY_TOP_FUDGE's comment, Core.lua) for
		-- the small extra sliver GetHitRectInsets alone doesn't cover.
		local firstLeft, firstRight, firstTop, firstBottom = self:GetHitInsets(chainFirst)
		local lastLeft, lastRight, lastTop, lastBottom = self:GetHitInsets(chainLast)
		local firstRatio = self:ScaleRatio(chainFirst, overlay)
		local lastRatio = self:ScaleRatio(chainLast, overlay)
		local topFudge = container.overlayTopFudge or 0

		overlay:SetPoint("TOPLEFT", chainFirst, "TOPLEFT", firstLeft * firstRatio, -(firstTop + topFudge) * firstRatio)
		overlay:SetPoint("BOTTOMRIGHT", chainLast, "BOTTOMRIGHT", -lastRight * lastRatio, lastBottom * lastRatio)
	elseif container.overlayInset then
		-- Trims the overlay in by a fixed per-side amount (Latency Bar
		-- only, container.overlayInset) for a wrapped native frame whose
		-- bounds are bigger than its visible art. Converted through
		-- ScaleRatio so this stays correct at any Scale slider value.
		local inset = container.overlayInset
		local ratio = self:ScaleRatio(container, overlay)

		overlay:SetPoint("TOPLEFT", container, "TOPLEFT", (inset.left or 0) * ratio, -(inset.top or 0) * ratio)
		overlay:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -(inset.right or 0) * ratio, (inset.bottom or 0) * ratio)
	else
		overlay:SetAllPoints(container)
	end

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	tex:SetAllPoints(overlay)

	-- Hover border + centered element-name label, mirroring Bar.lua's own
	-- EnsureBarOverlay. displayName is passed explicitly per call site
	-- since settingsKey doesn't uniquely identify an element (e.g. Key
	-- Ring shares Bag Bar's settingsKey "bagbar").
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
		startDragFn(ACAB)
	end)
	overlay:SetScript("OnDragStop", function()
		stopDragFn(ACAB)
	end)

	overlay:SetScript("OnMouseUp", function()
		if arg1 == "RightButton" then
			ACAB:OpenBarSettingsByKey(settingsKey)
		end
	end)

	-- Scroll-to-scale. Gated on the overlay's own mouse-enabled state
	-- (set by ApplyContainerOverlayVisual/ApplyDefaultLayoutEditVisual per
	-- element - CanDragDefaultLayout() for most elements, edit-mode-only
	-- for the skipLayoutLock group) instead of hardcoding
	-- CanDragDefaultLayout(), so drag and scroll always agree on when this
	-- overlay is actually interactive.
	overlay:EnableMouseWheel(true)
	overlay:SetScript("OnMouseWheel", function()
		if not scaleSetFn then
			return
		end

		if not overlay:IsMouseEnabled() then
			return
		end

		local delta = arg1 or 0
		local step = 0.1
		local current = container:GetScale() or 1

		scaleSetFn(ACAB, current + (delta * step))
	end)

	overlay:EnableMouse(false)
	overlay:Hide()

	container.ACABOverlay = overlay

	return overlay
end

-- Shows/hides + toggles mouse on a Bag Bar/Micro Menu overlay - called
-- from ApplyDefaultLayoutEditVisual below. `enabledFlag` is the
-- element's own ACABDB.bagBarEnabled/microMenuEnabled (unlike the
-- stance bar/bar 1, these CAN be meaningfully disabled - see
-- SetBagBarEnabled/SetMicroMenuEnabled below), `show` is
-- ACAB:CanDragDefaultLayout()'s result - mirrors the same
-- enabled-AND-shown gating `ApplyDefaultLayoutEditVisual` applies to
-- default bars 2-5 directly.
function ACAB:ApplyContainerOverlayVisual(container, enabledFlag, show)
	if not container or not container.ACABOverlay then
		return
	end

	local overlay = container.ACABOverlay
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

-- Swallows SetPoint/ClearAllPoints on `frame` unless flagged via
-- frame[flagName] (set by the element's own Apply*Position call). Must
-- stay in place - native code re-anchors these frames without clearing
-- the existing point first, corrupting their position.
--
-- Every swallowed SetPoint attempt is recorded into
-- frame.ACABSwallowedAnchor instead of discarded - native code can
-- repeatedly try to re-anchor a frame (e.g. Latency Bar to MainMenuBar)
-- and the true final anchor can differ from what a synchronous GetPoint(1)
-- observes at login. Core.lua's WaitForWrappedFrameAnchorSettle polls
-- this field for stability; Reset*Layout below also re-checks it
-- directly at click-time as a backstop for a later re-anchor.
function ACAB:InstallReanchorGuard(frame, flagName)
	if not frame or frame.ACABReanchorGuarded then
		return
	end

	local nativeSetPoint = frame.SetPoint
	local nativeClearAllPoints = frame.ClearAllPoints

	frame.SetPoint = function(self, ...)
		if self[flagName] then
			return nativeSetPoint(self, unpack(arg))
		end

		-- arg[2] (relativeTo) is whatever native code itself passed to
		-- SetPoint - a real frame reference OR a plain string name, both
		-- valid per the SetPoint API. Indexing a string with .GetName
		-- errors outright on this client (no string-method metatable),
		-- so the string case must be checked first, never indexed.
		local relTo = arg[2]
		local relName = "UIParent"

		if type(relTo) == "string" then
			relName = relTo
		elseif relTo and relTo.GetName and relTo:GetName() then
			relName = relTo:GetName()
		end

		self.ACABSwallowedAnchor = {
			point = arg[1],
			relativeTo = relName,
			relativePoint = arg[3],
			x = arg[4],
			y = arg[5],
		}
	end

	frame.ClearAllPoints = function(self)
		if self[flagName] then
			return nativeClearAllPoints(self)
		end
	end

	frame.ACABReanchorGuarded = true
end

-- Applies `native` (a true relative anchor - point/relativeTo/
-- relativePoint/x/y, captured via GetPoint(1)) directly to `frame`, then
-- re-reads its now-correct GetLeft()/GetTop() to build a normal
-- UIParent-relative absolute anchor table. Used by every Reset*Position/
-- Reset*Layout below instead of copying `native`'s fields directly,
-- since the live position/Settings.lua sliders are always
-- UIParent-relative. guardFlagName (optional) must be set for elements
-- with an InstallReanchorGuard (Latency Bar/Cast Bar), or this SetPoint
-- would be silently swallowed by the frame's own guard.
function ACAB:ResolveNativeAnchorToAbsolute(frame, native, guardFlagName)
	if not frame then
		return nil
	end

	-- Prefer whatever native code most recently, actually tried to
	-- re-anchor this frame to (InstallReanchorGuard's swallow tracking)
	-- over the possibly-stale/never-settled `native` snapshot passed in -
	-- see InstallReanchorGuard's own comment for why. No-op (falls
	-- through to `native`) for frames with no guard installed at all
	-- (Key Ring/Exp Bar currently), or if nothing's been observed yet.
	native = frame.ACABSwallowedAnchor or native

	if not native then
		return nil
	end

	if guardFlagName then
		frame[guardFlagName] = true
	end

	frame:ClearAllPoints()
	self:PixelSetPoint(
		frame,
		native.point or "TOPLEFT",
		getglobal(native.relativeTo or "UIParent") or UIParent,
		native.relativePoint or "BOTTOMLEFT",
		native.x or 0,
		native.y or 0
	)

	if guardFlagName then
		frame[guardFlagName] = nil
	end

	local left, top = frame:GetLeft(), frame:GetTop()

	if not left or not top then
		return nil
	end

	return {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = left,
		y = top,
	}
end

-- Swallows Show() on `frame` unless isEnabledFn() returns true.
function ACAB:InstallShowGuard(frame, isEnabledFn)
	if not frame or frame.ACABShowGuarded then
		return
	end

	local nativeShow = frame.Show

	frame.Show = function(self)
		if isEnabledFn() then
			return nativeShow(self)
		end
	end

	frame.ACABShowGuarded = true
end

-------------------------------------------------------------------------
-- Default-layout / stance-bar edit-mode overlay refresh
--
-- Mirrors Bar.lua's ApplyEditModeVisual, but gated on
-- ACAB:CanDragDefaultLayout() (edit mode AND useDefaultLayout == false)
-- rather than edit mode alone - a "draggable" cue would be misleading
-- when dragging isn't actually possible. Called from Bar.lua's own
-- ApplyEditModeVisual and from Settings.lua's General panel checkbox
-- handler.
-------------------------------------------------------------------------

function ACAB:ApplyDefaultLayoutEditVisual()
	local show = self:CanDragDefaultLayout()

	-- Stance Bar/Pet Bar/Cast Bar are draggable in edit mode even on
	-- useDefaultLayout == true (Default Layout/Default Profile) - their own
	-- baseline reflow (ReflowStanceBarForBar2Toggle/ReflowPetBarForBar3Toggle/
	-- ReflowCastBarForStackToggle) still re-asserts Y on the next relevant
	-- toggle, same as every other useDefaultLayout == true position.
	local showAlwaysEditable = self:IsEditMode()

	-- Default bars 1-5 have no bar-level overlay loop here - they share
	-- Bar.lua's EnsureBarOverlay/ApplyEditModeVisual with every other
	-- bar, which already handles their show/hide and mouse-enable gating
	-- (including the useDefaultLayout == false requirement via
	-- isDefaultBar1to5's canEdit check there). This function only drives
	-- the chain-anchored containers and native-wrapped elements below.

	-- Stance Bar / Bag Bar / Micro Menu - all three are now the same kind
	-- of ACAB-owned chain-anchored container (BuildChainAnchoredContainer/
	-- ApplyChainAnchoredShape), so they share the exact same
	-- ApplyContainerOverlayVisual treatment: overlay visibility gated on
	-- both edit-mode/useDefaultLayout (`show`) AND this element's own
	-- enable flag.
	self:ApplyContainerOverlayVisual(self.stanceBarContainer, ACABDB.stanceBarEnabled, showAlwaysEditable)
	self:ApplyContainerOverlayVisual(self.bagBarContainer, ACABDB.bagBarEnabled, show)
	self:ApplyContainerOverlayVisual(self.microMenuContainer, ACABDB.microMenuEnabled, show)

	-- Pet Bar native container (cfg.useNativePetBar) - same treatment,
	-- gated on the SAME cfg.enabled the custom-styled mode uses.
	do
		local petCfg = ACABDB.defaultBars and ACABDB.defaultBars[self.PET_BAR_ID]

		self:ApplyContainerOverlayVisual(self.petBarNativeContainer, petCfg and petCfg.enabled, showAlwaysEditable)
	end

	-- Key Ring / Latency Bar - same generic ApplyContainerOverlayVisual
	-- treatment as Bag Bar/Micro Menu above; EnsureContainerOverlay is
	-- equally generic over a single real button/frame as it is over a
	-- synthetic container, so no separate helper is needed here. Looked
	-- up by name each call (rather than cached) since this only runs on
	-- edit-mode/useDefaultLayout toggles, not per frame.
	self:ApplyContainerOverlayVisual(getglobal(self.KEYRING_BUTTON_NAME), ACABDB.keyRingEnabled, show)
	self:ApplyContainerOverlayVisual(getglobal(self.LATENCY_BAR_FRAME_NAME), ACABDB.latencyBarEnabled, show)

	-- Experience Bar - same generic ApplyContainerOverlayVisual treatment
	-- as Key Ring/Latency Bar above.
	self:ApplyContainerOverlayVisual(getglobal(self.EXP_BAR_FRAME_NAME), ACABDB.expBarEnabled, show)

	self:ApplyContainerOverlayVisual(getglobal(self.CAST_BAR_FRAME_NAME), true, showAlwaysEditable)

	-- Page Indicator (Part 4) - same generic ApplyContainerOverlayVisual
	-- treatment, gated on mainBarPaginationEnabled instead of an
	-- independent enable flag (this element has none of its own - see
	-- ApplyPageIndicatorVisibility's comment).
	self:ApplyContainerOverlayVisual(
		self.pageIndicatorContainer,
		ACABDB.mainBarPaginationEnabled,
		show
	)

	-- Tooltip - independent of action-bar layout mode, same reasoning as
	-- Cast Bar above (showAlwaysEditable, not show).
	self:ApplyContainerOverlayVisual(self.tooltipFrame, ACABDB.tooltipEnabled, showAlwaysEditable)
end

-------------------------------------------------------------------------
-- Position reassert after combat / looting
--
-- Latency Bar and Key Ring wrap a single real native frame directly, so
-- if any native FrameXML code re-anchors that frame on its own, our
-- last-applied position is silently discarded with nothing to notice it.
-- Bag Bar/Micro Menu/Stance Bar/Page Indicator's buttons are also real
-- native frames reparented into our own synthetic containers, so the
-- same risk applies to them.
--
-- Every Apply* call below is idempotent and no-ops if that element was
-- never built this session. Triggered on PLAYER_REGEN_ENABLED (leaving
-- combat) and LOOT_CLOSED, chosen over CHAT_MSG_LOOT (fires once per
-- looted item) and LOOT_OPENED (fires too early).
--
-- Default bars 1-5 are excluded: their real buttons are permanently
-- hidden and Show()-neutered at login, so native code can't move them.
-------------------------------------------------------------------------

function ACAB:ReassertNativeElementPositions()
	self:ApplyBagBarPosition()
	self:ApplyBagBarShape()

	self:ApplyMicroMenuPosition()
	self:ApplyMicroMenuShape()

	self:ApplyStanceBarPosition()
	self:ApplyStanceBarShape()

	self:ApplyKeyRingPosition()

	self:ApplyLatencyBarPosition()

	-- Experience Bar: same single-native-frame risk class as the Latency
	-- Bar/Key Ring above (MainMenuExpBar isn't reparented into a
	-- ACAB-owned container) - reasserted here for the same reason.
	self:ApplyExpBarPosition()

	self:ApplyCastBarPosition()

	self:ApplyPageIndicatorPosition()
	self:ApplyPageIndicatorShape()
end
