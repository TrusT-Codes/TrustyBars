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
-- Frame name mapping
--
-- These prefixes are the well-established vanilla 1.12.1 FrameXML names
-- for the 5 default action bars (12 buttons each, numbered 1-12). They
-- are extremely unlikely to differ on this client, but are centralized
-- here as a single table so a wrong name is a one-line fix - see the
-- plan's "01-Environment-Capability-Analysis.md" section 6 unresolved-
-- verification list.
-------------------------------------------------------------------------

BTV.DEFAULT_BAR_FRAME_PREFIXES = {
	[1] = "ActionButton",             -- Main bar (MainMenuBar).
	[2] = "MultiBarBottomLeftButton", -- Bottom Left.
	[3] = "MultiBarBottomRightButton",-- Bottom Right.
	[4] = "MultiBarRightButton",      -- Right.
	[5] = "MultiBarLeftButton",       -- Right 2.
}

-- Real vanilla 1.12.1 shapeshift bars top out at 10 stance slots
-- (ShapeshiftButton1-10, well-established FrameXML naming) - no class
-- needs more than that on this client. Some classes have far fewer
-- (e.g. Warrior stances), which is exactly why GetStanceBarButtons below
-- uses the same "stop at the first missing frame" tolerance as
-- GetDefaultBarButtons rather than assuming all 10 exist.
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
			-- Missing frames beyond this point aren't collected - a
			-- partially-loaded UI shouldn't produce a sparse table.
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
-- Main Bar (bar 1) dynamic paging - Main Bar migration, Parts 2/3
--
-- Unlike bars 2-5 (a fixed cfg.fixedActionSlots array, resolved once),
-- bar 1's 12 pool buttons resolve their action slot dynamically from
-- whichever page is currently "effective" - see GetMainBarEffectivePage
-- below - re-evaluated any time CURRENT_ACTIONBAR_PAGE or
-- GetBonusBarOffset() changes. This deliberately never writes to the
-- real CURRENT_ACTIONBAR_PAGE global itself (unlike Bartender2's own
-- technique, which relies on it because Bartender2 wraps the real,
-- still-paged ActionButton1-12 frames directly) - our own replica
-- buttons read a real native action slot number directly via
-- Rebind/GetActionTexture etc, so there is nothing native left for us
-- to redirect; only our OWN resolved slot needs to track the paged
-- state.
--
-- Real FrameXML source (ActionButton_GetPagedID) confirms the formula:
-- actionSlot = buttonID + (page-1)*12. GetBonusBarOffset() (1/2/3 for
-- stance/form/stealth) maps to page 6+offset (7/8/9) - confirmed via
-- Bartender2's own GetBonusActionBarPage (vendored under Bartender2/,
-- read directly for this migration) and this addon's own Part 5 slot-
-- allocator research.
-------------------------------------------------------------------------

-- Page the Main Bar's buttons should currently read from, honoring both
-- toggles (Core.lua's EnsureDB seeds both true, matching real vanilla's
-- own always-on paging/stance-swap behavior).
--
-- Pagination disabled: locked to page 1, CURRENT_ACTIONBAR_PAGE is never
-- read at all - the player's Shift/Ctrl modifier keybinds become inert
-- for this bar, matching what "no pagination" means.
--
-- Stance-swap only applies "on top of" page 1 - mirrors Bartender2's own
-- `if CURRENT_ACTIONBAR_PAGE == 1 then` guard exactly, so the two
-- toggles compose correctly instead of fighting: a manually-paged-away
-- bar (e.g. Shift held, page 2) never gets silently overridden by a
-- stance change, exactly like real vanilla's own main bar never does
-- either.
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

-- Real vanilla 1.12.1 FrameXML signature (stock ShapeshiftBar.lua's own
-- ShapeshiftBar_Update): icon, name, isActive, isCastable =
-- GetShapeshiftFormInfo(index). Used here (Stance/Page Bar Assignment
-- feature, Parts 2/3) to resolve WHICH of the player's stance slots
-- (1..GetNumShapeshiftForms()) is currently active - GetBonusBarOffset()
-- alone only reports which of up to 3 bonus action bars is showing, not
-- the stance-form INDEX that corresponds to, which isn't a 1:1 mapping
-- for a class with more forms than bonus bars (e.g. Druid's Travel Form
-- grants no bonus bar of its own at all).
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

-- Real vanilla paging formula (ActionButton_GetPagedID), applied to
-- whichever page GetMainBarEffectivePage currently resolves to - UNLESS
-- the user has explicitly assigned an Extra Bar (Stance/Page Bar
-- Assignment feature, Parts 2/3) as this state's content source, in which
-- case this reads that Extra Bar's own live action slot instead of
-- computing a native page number at all.
--
-- Composition/precedence: deliberately derived from GetMainBarEffectivePage's
-- OWN resolved page number, rather than re-deriving "is a stance active"/
-- "is pagination away from page 1" independently - that function already
-- encodes the exact "stance-swap only applies on top of page 1" rule
-- (its own header comment), so reading its result back here means an
-- assignment can only ever kick in in the exact same circumstances native
-- redirection already would have, extending - never replacing - that same
-- precedence rule instead of inventing a new one:
--
--   page in 7-9  -> GetMainBarEffectivePage already resolved this via the
--                   stance/form/stealth branch (only possible when page 1
--                   AND stance-swap is on) - try this stance's assignment.
--   page ~= 1    -> otherwise this is CURRENT_ACTIONBAR_PAGE itself (the
--                   Shift/Ctrl pagination toggle actually paged away) -
--                   try the page-bar assignment.
--   page == 1    -> neither redirect is active - untouched native math.
--
-- Either branch falls straight through to the native math below if
-- unassigned (nil) or the assigned Extra Bar can't currently resolve a
-- slot (e.g. a corrupt/hand-edited save) - additive, not a replacement,
-- for any state the user hasn't explicitly configured, per the feature's
-- own spec.
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

-- Re-resolves every one of bar 1's 12 pool buttons' action slot from the
-- CURRENT page/bonus-bar state - just Bar.lua's own ApplyBarShape, which
-- already re-runs GetMainBarSlotForIndex for every button on every call
-- (see its own cfg.dynamicMainBar branch) - called any time
-- CURRENT_ACTIONBAR_PAGE or GetBonusBarOffset() changes (the
-- hooksecurefunc/event registrations below), or either toggle is flipped
-- from Settings (SetMainBarPaginationEnabled/SetMainBarStanceSwapEnabled
-- below).
function BTV:RefreshMainBarSlots()
	local bar = self.bars and self.bars[1]

	if bar then
		self:ApplyBarShape(bar)
	end
end

-- Settings.lua General tab checkboxes write through these - mirrors
-- every other Set*Enabled clamp/write/reapply template in this file
-- (e.g. SetBagBarEnabled), just reapplying via RefreshMainBarSlots
-- instead of a Show()/Hide() cascade, since neither toggle changes bar
-- 1's visibility, only which action slots its buttons read from.
function BTV:SetMainBarPaginationEnabled(enabled)
	self:EnsureDB()

	BTVanillaDB.mainBarPaginationEnabled = enabled and true or false

	self:RefreshMainBarSlots()

	-- Page Indicator (Part 4): shown/hidden entirely by this same toggle -
	-- see ApplyPageIndicatorVisibility's own comment for why it has no
	-- independent enable flag of its own. Settings.lua's General panel
	-- checkbox also live-refreshes its own assignment rows and the Main
	-- Bar page's Scale slider visibility on this same click - see that
	-- checkbox's own OnClick handler.
	if self.ApplyPageIndicatorVisibility then
		self:ApplyPageIndicatorVisibility()
	end
end

function BTV:SetMainBarStanceSwapEnabled(enabled)
	self:EnsureDB()

	BTVanillaDB.mainBarStanceSwapEnabled = enabled and true or false

	self:RefreshMainBarSlots()
end

-- hooksecurefunc runs AFTER the real vanilla ChangeActionBarPage (real
-- FrameXML global, confirmed present - fires on every Shift/Ctrl page
-- swap and the page-arrow clicks) has already updated
-- CURRENT_ACTIONBAR_PAGE, so RefreshMainBarSlots always reads the new
-- value, never the stale one. hooksecurefunc is confirmed DLL-native on
-- this client (ClassicAPI - see this addon's environment doc), not a
-- Lua 5.0 polyfill. Registered once here at file load (top-level, not
-- deferred to PLAYER_LOGIN) - FrameXML's own ChangeActionBarPage is
-- already defined by the time addon Lua files load, same timing every
-- other top-level hooksecurefunc/event registration in this file already
-- relies on (e.g. stanceFormEventFrame further below).
if hooksecurefunc and ChangeActionBarPage then
	hooksecurefunc("ChangeActionBarPage", function()
		BTV:RefreshMainBarSlots()
	end)
end

-- UPDATE_BONUS_ACTIONBAR is real vanilla's own event (confirmed via
-- Bartender2's own UPDATE_BONUS_ACTIONBAR handler, vendored under
-- Bartender2/) - fires whenever the player's stance/form/stealth state
-- changes (GetBonusBarOffset() about to report a new value). A dedicated
-- listener is needed on top of the ChangeActionBarPage hook above:
-- entering/leaving a stance doesn't necessarily call
-- ChangeActionBarPage itself, it just changes what GetBonusBarOffset()
-- reports - GetMainBarEffectivePage reads that value directly, so this
-- event is what actually drives the stance-swap toggle's live behavior.
-- Issue 2 (bug-fix batch): BonusActionBarFrame is a SEPARATE real vanilla
-- FrameXML frame from ActionButton1-12 - Blizzard's own stock
-- UPDATE_BONUS_ACTIONBAR handler (vendored Bartender2/Bartender2.lua's own
-- UPDATE_BONUS_ACTIONBAR handler confirms this, calling
-- BonusActionBarFrame:Hide() itself for exactly this reason) shows it as an
-- overlay any time bonus/stance content becomes active (entering
-- stealth/shapeshift/stance). ActionButton1-12 being permanently hidden
-- (CreateFixedSlotDefaultBars above) does nothing to suppress this
-- distinct frame, which is why stealth/stance entry was still visibly
-- changing buttons on top of bar 1's replica regardless of the
-- Stance/Form/Stealth Swapping toggle's state - that toggle only governs
-- which action slot OUR OWN replica buttons read from
-- (GetMainBarEffectivePage), it has no relationship to this native overlay
-- frame at all. Hidden unconditionally here (not gated on
-- mainBarStanceSwapEnabled) since TrustyBars' own replica buttons are now
-- the sole visual representation of bar 1 regardless of that toggle's
-- state - exactly like ActionButton1-12 are hidden unconditionally too.
--
-- Show is permanently neutered the same way ActionButton1-12's is
-- (CreateFixedSlotDefaultBars above) rather than relying on a plain Hide()
-- alone - same class of problem (a native frame Blizzard's own FrameXML
-- may call :Show() on again later from code this addon doesn't control),
-- same permanent fix.
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
-- "Disable Blizzard Art" (General tab checkbox, feature 1)
--
-- MainMenuBarArtFrame is the well-established vanilla 1.12.1 FrameXML
-- name for the main bar's decorative end-cap/background art (the
-- textured strip bar 1's real ActionButton1-12 frames sit on top of).
-- Hiding it lets bar 1's own replica-free real buttons show against
-- whatever the user's own UI/background looks like instead, exactly
-- like Bartender2's "hide Blizzard art" option on other client
-- generations.
--
-- Bug-fix batch Fix 1: live testing confirmed ActionButton1:GetParent()
-- IS MainMenuBarArtFrame on this client - the old skip-and-warn logic
-- above (now removed) correctly refused to hide the whole frame, since
-- doing so would have taken bar 1's real action buttons down with it.
--
-- Fixed via a different mechanism instead of hiding MainMenuBarArtFrame
-- itself: enumerate ONLY its own regions via {artFrame:GetRegions()} and
-- hide/show whichever of those are Textures. GetRegions() is a real
-- vanilla API guarantee - it returns a frame's own directly-owned
-- Texture/FontString regions, never its child Frames - so this can never
-- touch ActionButton1-12 (real child Frames of artFrame) regardless of
-- parentage, while it still hides whatever decorative background/
-- gryphon/endcap textures are drawn directly on MainMenuBarArtFrame
-- itself.
-- Issue 4 (bug-fix batch round 4): pin MainMenuBarArtFrame to a strata
-- BELOW every TrustyBars bar/container UNCONDITIONALLY, independent of
-- BTVanillaDB.disableBlizzardArt - texture visibility (hide/show the art's
-- own regions, below) and z-order (this frame must always render BEHIND
-- every TrustyBars bar/container, whether its texture is currently shown
-- or hidden) are two independent concerns. The previous approach
-- (repeatedly re-raising bar:SetFrameLevel(10) on every ApplyBarShape call,
-- for bar 1 only, plus a blanket SetFrameStrata("MEDIUM") on every bar) was
-- whack-a-mole: it only ever worked for as long as it correctly guessed
-- whatever level MainMenuBarArtFrame itself happened to be at, and never
-- covered bars 2-5's own render order at all. Flipping the approach -
-- directly lowering the ONE native art frame instead of chasing it with
-- ever-higher bar levels - fixes this permanently regardless of whatever
-- level Blizzard's own FrameXML assigns MainMenuBarArtFrame under any
-- circumstance.
--
-- Round 15: this was originally pinned to "BACKGROUND" (the lowest strata
-- this client has), which fixed the z-order bug above but had a live-
-- confirmed side effect - the user found a stray ~1px artifact (a "blue
-- bar" visible just under the XP bar, present only while TrustyBars is
-- enabled) that disappeared when the art frame's strata was raised to
-- "MEDIUM" live, meaning BACKGROUND was low enough to expose some other
-- native texture/frame that normally sits hidden behind the art at its
-- true native strata (also live-confirmed as "MEDIUM", via a fresh reload
-- with TrustyBars fully disabled). Reverting all the way back to "MEDIUM"
-- isn't safe either - our own bars also sit at "MEDIUM" (Bar.lua's
-- CreateBarFromConfig/ApplyBarShape) with only an explicit FrameLevel to
-- break the tie, which is exactly the less-reliable same-tier ordering
-- this BACKGROUND pin was introduced to replace. "LOW" is the corrected
-- middle ground: a real, distinct frame-strata tier that sits below
-- "MEDIUM" (still guaranteeing every TrustyBars bar renders above it,
-- strata alone deciding the tie, no level race) but above "BACKGROUND"
-- (no longer pushed all the way down to whatever tier was hiding that
-- native artifact). Applied once here (this function itself is only ever
-- called once, at PLAYER_LOGIN, per Core.lua) rather than needing its own
-- separate call site.
--
-- MultiBarBottomLeft/MultiBarBottomRight/MultiBarRight/MultiBarLeft (bars
-- 2-5) have no equivalent decorative art frame of their own in real
-- vanilla 1.12.1 FrameXML - they're plain button-holding frames with no
-- background/endcap textures - so MainMenuBarArtFrame is the only native
-- frame that ever needs this treatment. (Re-verify live if a future
-- client build turns out to add one - see this task's own report for the
-- flag.)
function BTV:ApplyBlizzardArtVisibility()
	local artFrame = MainMenuBarArtFrame

	if not artFrame then
		return
	end

	self:EnsureDB()

	artFrame:SetFrameStrata("LOW")

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
-- Position + grid reflow
--
-- Reuses the same 1-based-index -> col/row math as Bar.lua's
-- ButtonIndexToGridPos/LayoutButtons, just applied to the real Blizzard
-- frames instead of a custom bar's own button pool. That helper is
-- local to Bar.lua, so it's re-derived here rather than shared - it's a
-- two-line formula, not worth exposing a cross-file dependency for.
-------------------------------------------------------------------------

local function ButtonIndexToGridPos(index, cols)
	local i = index - 1
	local row = math.floor(i / cols)
	local col = i - (row * cols)
	return col, row
end

-- CRITICAL FIX (login-breaking crash): PixelUtil.SetPoint calls
-- GetEffectiveScale() on BOTH the region being positioned and its
-- relativeTo anchor - a real Frame/Button method, but NOT one FontString
-- objects expose in this client's object model (FontString/Texture are
-- plain Region-derived widgets with no scale of their own - GetLeft/
-- GetTop/GetWidth/GetHeight/SetParent/IsShown/SetPoint all work on them,
-- GetEffectiveScale does not). Live-confirmed root cause of
-- "!!!ClassicAPI\Util\PixelUtil.lua:66: attempt to call method
-- 'GetEffectiveScale' (a nil value)": the Page Indicator container (Part
-- 4, below) chain-anchors MainMenuBarPageNumber - a real FontString, not
-- a Button - alongside ActionBarUpButton/ActionBarDownButton via this
-- exact helper, and ApplyChainAnchoredShape's PixelSetPoint calls pass
-- that FontString as either `region` or as another button's `relativeTo`
-- anchor. Every OTHER call site of PixelSetPoint in this file only ever
-- touches containers/overlays (frames we created ourselves), so this
-- guard is a no-op cost for them - it only actually changes behavior for
-- the Page Indicator's FontString member, which now degrades to plain
-- (non-pixel-perfect-scale-corrected) SetPoint instead of erroring
-- outright. Checked on both region AND relativeTo (arg[2]) since
-- PixelUtil.SetPoint's own internal GetEffectiveScale call can be against
-- either object depending on which one it's computing relative-scale
-- for.
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

-------------------------------------------------------------------------
-- Bar-level edit-mode overlay (Issue 2, bug-fix batch)
--
-- Default bars are 12 independent real Blizzard button frames, not a
-- single container frame we own the way Bar.lua's custom bars are (see
-- Bar.lua's bar:CreateTexture-backed per-button editOverlay, which looks
-- continuous only because custom bars use zero button spacing - default
-- bars now have real spacing, see cfg.spacing, so per-button overlays
-- would show visible gaps). Instead, one borderless frame per default
-- bar spans the bar's full bounding box (button 1's top-left corner to
-- the last button's bottom-right corner), computed from the exact same
-- cols/rows/buttonSize/spacing fields ApplyDefaultBarShape below already
-- uses to lay out the real buttons - so it's always in sync with
-- whatever the buttons actually look like, never independently derived.
--
-- Created lazily, cached per bar id (never destroyed), and kept
-- repositioned/resized every time ApplyDefaultBarShape runs (below) -
-- shown/hidden by BTV:ApplyDefaultLayoutEditVisual instead, mirroring
-- Button.lua's SetEditModeVisual/Bar.lua's ApplyEditModeVisual.
--
-- The old per-button overlays (HoverBind.lua's HookDefaultBarButton) are
-- removed for default bars specifically, since this bar-level frame
-- replaces them outright - keeping both would just double-draw the same
-- area with no visual difference, and the per-button ones had the exact
-- gap problem this issue reports.
-------------------------------------------------------------------------

local defaultBarOverlays = {}

local function EnsureDefaultBarOverlay(id)
	local overlay = defaultBarOverlays[id]

	if overlay then
		return overlay
	end

	overlay = CreateFrame(
		"Frame",
		"BTVanillaDefaultBarOverlay" .. tostring(id),
		UIParent
	)

	-- TOOLTIP strata (the topmost strata this client has) rather than
	-- HIGH: live-confirmed the tint + drag interception silently failed
	-- specifically over FILLED buttons on bars 2-5 (MultiBarBottomLeft/
	-- MultiBarBottomRight/MultiBarRight/MultiBarLeft) while working fine
	-- on bar 1 (ActionButton) and on empty buttons on every bar. Both
	-- rendering order AND mouse hit-testing are governed by frame
	-- strata/level in this client, so a filled multibar button's own
	-- glow/cooldown-swipe child textures (which only exist/elevate when
	-- the slot is actually filled - explaining why empty buttons were
	-- unaffected) were apparently winning against HIGH. TOOLTIP sits
	-- above every ordinary game-UI frame regardless of that button's own
	-- native strata, closing the gap outright rather than chasing the
	-- exact native strata Blizzard's multibars use.
	overlay:SetFrameStrata("TOOLTIP")

	-- Explicit high frame level too, in case level (not just strata) was
	-- part of the bar 1 vs bars 2-5 inconsistency - overlays are parented
	-- to UIParent (not to the real button frames), so there's no relative
	-- level dependency to preserve; a comfortably high fixed level just
	-- guarantees this frame never loses a within-strata tie-break against
	-- anything else that might also end up at TOOLTIP strata.
	overlay:SetFrameLevel(100)

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	tex:SetAllPoints(overlay)

	-- Issue 2 (bug-fix batch v3): this overlay now owns dragging directly
	-- (SetScript, not HookScript - this is entirely our own frame with no
	-- native behavior to preserve), replacing the old per-button HookScript
	-- drag hooks entirely (see HoverBind.lua's HookDefaultBarButton, which
	-- no longer installs any drag hooks). RegisterForDrag is registered
	-- once here unconditionally - only EnableMouse is toggled per the
	-- CanDragDefaultLayout() window, in ApplyDefaultLayoutEditVisual below.
	overlay:RegisterForDrag("LeftButton")
	overlay:SetScript("OnDragStart", function()
		BTV:StartDefaultBarDrag(id)
	end)
	overlay:SetScript("OnDragStop", function()
		BTV:StopDefaultBarDrag(id)
	end)

	-- Right-click-to-settings (mirrors HoverBind.lua's HookDefaultBarButton
	-- right-click hook): while this overlay is mouse-enabled (exactly the
	-- CanDragDefaultLayout() window - edit mode AND useDefaultLayout ==
	-- false) it fully covers the real buttons underneath, so their own
	-- right-click hook can no longer receive the event at all. A plain
	-- (non-Button-widgetType) Frame with EnableMouse(true) still receives
	-- OnMouseUp with the button name as arg1 - the same convention
	-- RegisterForClicks-driven OnClick uses on a real Button widget - so no
	-- separate widgetType is needed just for this.
	overlay:SetScript("OnMouseUp", function()
		if arg1 == "RightButton" then
			BTV:OpenDefaultBarSettings(id)
		end
	end)

	-- Issue 2 (bug-fix batch v6): scroll-to-resize, mirroring Button.lua's
	-- BTVButtonMixin.OnMouseWheel for custom bars exactly (same step, same
	-- arg1-is-delta convention) - this overlay is the sole mouse-
	-- interactive surface over a default bar during the
	-- CanDragDefaultLayout() window (drag + right-click already routed
	-- through it above), so scroll has to be wired here too rather than on
	-- the real Blizzard buttons underneath, which never receive the event
	-- while this overlay has mouse enabled.
	overlay:EnableMouseWheel(true)
	overlay:SetScript("OnMouseWheel", function()
		if not BTV:CanDragDefaultLayout() then
			return
		end

		local delta = arg1 or 0
		local cfg = BTVanillaDB.defaultBars[id]

		if not cfg then
			return
		end

		local step = 2
		local newSize = (cfg.buttonSize or BTV.BUTTON_SIZE) + (delta * step)

		BTV:SetDefaultBarButtonSize(id, newSize)

		if BTV.RefreshBarSettingsPage then
			BTV:RefreshBarSettingsPage(id)
		end
	end)

	overlay:EnableMouse(false)
	overlay:Hide()

	defaultBarOverlays[id] = overlay

	return overlay
end

-- Stance Bar (ShapeshiftButton1-N) migration: this used to wrap the real
-- ShapeshiftBarFrame directly with its own bespoke overlay/position/drag
-- implementation (EnsureStanceBarOverlay/PositionStanceBarOverlay, removed
-- here). It now uses the exact same chain-anchored-container technique as
-- the Bag Bar/Micro Menu below (BuildChainAnchoredContainer/
-- ApplyChainAnchoredShape/EnsureContainerOverlay) instead of a bespoke
-- implementation - see the "Stance Bar" section further below in this file
-- (after BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay are defined, since it depends on all three). The
-- old per-element overlay this used to have is gone; EnsureContainerOverlay
-- is generic enough to serve it exactly like it already serves Bag Bar/
-- Micro Menu.

-- Positions and grid-reflows the 12 real Blizzard buttons for default
-- bar `id` according to its saved config (point/relativePoint/x/y/cols/
-- rows/buttonSize). The first button is anchored directly to UIParent at
-- the configured point; the remaining 11 are anchored relative to the
-- first button using the same grid math as custom bars.
--
-- Every default bar (1-5, major architecture migration Phases 1 and 2) is
-- now a real Bar.lua bar object (self.bars[id], built by
-- CreateFixedSlotDefaultBars) and delegates straight to Bar.lua's own
-- ApplyBarShape/ApplyBarPosition, which already know how to reposition/
-- reflow a button pool - including bar 1's own dynamic per-button slot
-- resolution (cfg.dynamicMainBar, see Bar.lua's ApplyBarShape).
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

-- Resizes the 12 real Blizzard buttons for default bar `id`. Blizzard's
-- own ActionButtonTemplate buttons respond correctly to plain
-- SetWidth/SetHeight - unlike TrustyBars' own pool buttons there's no
-- separate ApplySize wrapper to call here.
--
-- Every default bar (1-5) delegates to Bar.lua's own SetBarButtonSize
-- (which already handles the clamp rule, plus the equip-ring/glow/
-- backdrop scaling every Bar.lua button pool has), same reasoning as
-- ApplyDefaultBarShape above.
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

-- Mirrors SetDefaultBarButtonSize's structure exactly - clamp, write,
-- reapply - for the analogous spacing slider added alongside the
-- Button Size slider in Settings.lua.
--
-- Bug-fix batch Fix 2: bars 2-5 now also get a Spacing slider, since
-- Bar.lua's LayoutButtons/BarFrameSize honor cfg.spacing for any bar that
-- has it and every default bar (1-5, Main Bar migration included) has a
-- real captured cfg.spacing/cfg.nativeSpacing baseline (Core.lua's
-- CaptureNativeSpacing/seedDefaultBars) - it just went unread by Bar.lua
-- until now. Writes cfg.spacing directly (bar.config IS this same
-- BTVanillaDB.defaultBars[id] table - see CreateBarFromConfig) then
-- delegates to Bar.lua's own ApplyBarShape (LayoutButtons/BarFrameSize),
-- which already knows how to re-lay-out a button pool from cfg.spacing.
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

	if spacing < 0 then
		spacing = 0
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
-- Position (live, Phase 4 Settings UI)
--
-- Mirrors Bar.lua's SetBarPosition for custom bars. Default bars only
-- ever move via x/y (point/relativePoint stay whatever seedDefaultBars
-- chose) - dragging isn't supported for default bars since they're real
-- Blizzard frames, not TrustyBars' own draggable bar frame.
-------------------------------------------------------------------------

-- Every default bar (1-5) delegates straight to Bar.lua's own
-- SetBarPosition (same reasoning as ApplyDefaultBarShape/
-- SetDefaultBarButtonSize above).
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
-- Restores FROM cfg.nativeAnchor/cfg.nativeSpacing - the pristine
-- snapshots Core.lua's seedDefaultBars captured ONCE, the very first
-- time this bar's config was ever seeded, before TrustyBars had
-- repositioned it even a single time. Deliberately does NOT re-read the
-- real Blizzard frame's current GetPoint()/GetLeft() here: by the time a
-- user clicks this button (potentially well into a play session),
-- ApplyDefaultBarShape has likely already moved that frame to wherever
-- the user last dragged/slid/resized it, so a live re-read at this point
-- would just capture our own last SetPoint, not Blizzard's true original
-- position/spacing - only the untouched snapshots still remember that.
--
-- Spacing is restored here too (not a separate reset control) so the
-- button's "Reset to Blizzard Default" framing is honest: one click
-- returns the ENTIRE default-bar layout to pristine, not just position.
--
-- Renamed from ResetDefaultBarPosition (bug-fix batch, Issue 3): grid
-- shape (cols/rows) and button size are now restored too, so "Position"
-- was no longer an accurate name for what this does. Unlike position/
-- spacing, cols/rows/buttonSize don't need a live-captured snapshot the
-- way nativeAnchor/nativeSpacing do - they're simply the fixed literal
-- defaults seedDefaultBars (Core.lua) always assigns a fresh bar (grid
-- shape from the shared BTV.DEFAULT_BAR_GRID table, button size from
-- BTV.BUTTON_SIZE), so those same constants are re-applied directly here
-- rather than needing their own snapshot fields.
-------------------------------------------------------------------------

-- Every default bar (1-5): position and grid shape/button size are
-- restored the exact same way (from the same permanent nativeAnchor/
-- DEFAULT_BAR_GRID/BUTTON_SIZE snapshots), APPLIED through Bar.lua's own
-- ApplyBarPosition/SetBarLayout/SetBarButtonSize.
--
-- Bug-fix batch Fix 2: cfg.nativeSpacing is restored too - Bar.lua's
-- LayoutButtons/BarFrameSize honor cfg.spacing for any bar that has it
-- (see SetDefaultBarSpacing's updated comment). ApplyBarShape (not just
-- SetBarLayout/SetBarButtonSize) is called explicitly afterward to make
-- the restored spacing take visual effect immediately, since neither of
-- those two setters alone re-lays-out the grid from a freshly-written
-- cfg.spacing.
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

	-- SetBarLayout/SetBarButtonSize above already each internally
	-- re-apply the bar's shape (Bar.lua's ApplyBarShape), but this
	-- final explicit call guarantees the just-restored cfg.spacing is
	-- reflected too, regardless of which (if either) of those two
	-- calls actually ran (e.g. grid being nil would skip SetBarLayout
	-- entirely).
	self:ApplyBarShape(bar)
end

-------------------------------------------------------------------------
-- Enable / disable (bars 2-5 only - bar 1 is always active, no UI)
--
-- Major architecture migration, Phase 1 of 2: the entire native
-- SHOW_MULTI_ACTIONBAR_1-4/MultiActionBar_Update()/SetActionBarToggles()
-- mechanism this section used to own is now DEAD for bars 2-5 - their
-- real Blizzard buttons are permanently hidden at migration time (see
-- CreateFixedSlotDefaultBars below) regardless of TrustyBars' own
-- enabled/disabled state, so there is nothing left for those native
-- globals to usefully drive. Our own cfg.enabled + a plain Show()/Hide()
-- on our own Bar.lua bar frame is now the SOLE visibility mechanism -
-- exactly the "simple, reliable enable toggle" the migration plan asks
-- for, with no native persistence quirks (see the removed comment on the
-- old SetDefaultBarEnabled about SHOW_MULTI_ACTIONBAR_* never actually
-- surviving a real logout) left to work around.
-------------------------------------------------------------------------

-- Issue 3 (round 14): real vanilla 1.12.1 FrameXML (MultiActionBarFrame.lua)
-- calls ShapeshiftBar_UpdatePosition() as a side effect whenever
-- MultiBarBottomLeft's shown state changes, sliding ShapeshiftBarFrame up/
-- down so it never overlaps that bar - this addon's own pre-migration
-- version (see backupVersionBeforeArchitecture/DefaultBars.lua's
-- SetDefaultBarEnabled) replicated this by calling that same native
-- function directly, gated on `id == 2` and `useDefaultLayout ~= false`.
-- That native call stopped having any visible effect once the Stance Bar
-- was migrated to its own synthetic chain-anchored container
-- (CreateStanceBarContainer below): the real ShapeshiftBarFrame's own
-- position is no longer what's on screen at all (its buttons were
-- reparented out of it into our container - see
-- BuildChainAnchoredContainer), and Blizzard's reflow logic keys off the
-- REAL MultiBarBottomLeftButton1-12 frames' shown state, which never
-- changes anymore now that they're permanently hidden regardless of our
-- own cfg.enabled (CreateFixedSlotDefaultBars). This has to be replicated
-- ourselves instead - see ReflowStanceBarForBar2Toggle below (defined
-- alongside the rest of the Stance Bar section, since it operates on
-- self.stanceBarContainer).
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

	-- Captured BEFORE overwriting cfg.enabled below - ReflowStanceBarForBar2Toggle
	-- must only fire on a genuine state CHANGE, not on every call (e.g.
	-- ApplyAllDefaultBars calls this at every login with cfg.enabled's own
	-- already-current value, which must never shift the Stance Bar's saved
	-- position on its own).
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
-- Build every default bar (1-5) as a Bar.lua bar object (major
-- architecture migration, Phases 1 and 2)
--
-- Called once at PLAYER_LOGIN (Core.lua), BEFORE ApplyAllDefaultBars -
-- every function above (ApplyDefaultBarShape, SetDefaultBarButtonSize,
-- SetDefaultBarPosition, ResetDefaultBarLayout, SetDefaultBarEnabled,
-- SetDefaultBarLayout) reads self.bars[id], so that entry must already
-- exist by the time any of them first run.
--
-- For each of bars 2-5 whose cfg.fixedActionSlots was successfully
-- discovered by Core.lua's seedDefaultBars (via CaptureFixedActionSlots),
-- and for bar 1 (cfg.dynamicMainBar, always present - see seedDefaultBars):
--   1. Permanently hides its 12 real Blizzard buttons - confirmed live
--      that Hide()ing a real ActionButton does not break its native
--      keybind dispatch (SetBinding'd action names like ACTIONBUTTON5/
--      MULTIACTIONBAR1BUTTON5 still fire UseAction on that slot via the
--      hidden frame's own internal handler), so this is safe to do
--      unconditionally and permanently, independent of TrustyBars' own
--      enabled/disabled state for that bar - our own replica's Show()/
--      Hide() becomes the sole VISUAL mechanism from this point on.
--   2. Builds this bar's own Bar.lua/Button.lua button pool
--      (CreateBarFromConfig, pointed at cfg.fixedActionSlots or resolved
--      dynamically per cfg.dynamicMainBar - see Bar.lua's ApplyBarShape -
--      instead of a free-pool slotStart) and stores it in self.bars[id] -
--      the exact same table a real custom bar (id 6+) lives in, so every
--      other system that already iterates self.bars (edit-mode overlay/
--      drag/scroll-resize, HoverBind.lua's ForEachButton, grid-visibility
--      sweeps) picks these bars up automatically with zero extra code.
--
-- If discovery failed for one of bars 2-5 (cfg.fixedActionSlots absent -
-- see CaptureFixedActionSlots' own comment on when this can happen), that
-- bar is simply skipped here and keeps behaving exactly like it did
-- before this migration (its real Blizzard buttons stay visible/native-
-- wrapped) until a later login succeeds. Bar 1's cfg.dynamicMainBar has no
-- equivalent discovery-failure case (see its own comment in
-- seedDefaultBars), so it's built unconditionally.
-------------------------------------------------------------------------

-- Bug-fix batch Fix 3: the recurring ~1-second C_Timer.NewTicker re-hide
-- sweep that used to live here is REMOVED. It was both needless CPU
-- overhead and too slow to prevent a visible flash - Blizzard's own
-- ACTIONBAR_SHOWGRID handling calls :Show() on EVERY action button,
-- including these 48 real (now-redundant) ones, the instant the player
-- picks up a spell/item, and the old ticker's up-to-1-second polling
-- interval meant that Show() could render for up to a full second before
-- the next sweep caught it.
--
-- Fixed at the source instead: each real button's own Show method is
-- permanently overridden to a no-op the moment it's hidden here. This
-- makes ANY future native code path's own :Show() call on these specific
-- frames (ACTIONBAR_SHOWGRID's sweep, ActionButton_Update on a stance/
-- talent change, etc.) silently do nothing forever, with zero ongoing
-- polling cost and no dependency on catching any particular event.
-- Confirmed live (per the major architecture migration's own testing)
-- that Hide()ing a real ActionButton does not break its native keybind
-- dispatch - overriding :Show() the same permanent way is exactly as
-- safe, since nothing else in this addon (or in native FrameXML) has any
-- remaining reason to make one of these 48 real buttons visible again;
-- their visual role is permanently replaced by TrustyBars' own replica
-- buttons (self.bars[id]) for the rest of the session.
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

			-- Issue 1 (bug-fix batch, CRITICAL): bar 1 (Main) has NO
			-- enable/disable concept at all (see SetDefaultBarEnabled's own
			-- "Bar 1 (Main) has no enable/disable - always active" comment
			-- above) - unlike bars 2-5, cfg.enabled is never written for id
			-- 1 (Core.lua's BTV.DEFAULT_BAR_GRID[1] has no `enabled` key, so
			-- seedDefaultBars' result[1].enabled is always nil). The old
			-- `if cfg.enabled then Show() else Hide() end` gate here was
			-- written generically for every id 1-5 without accounting for
			-- that - since nil is falsy, bar 1 was unconditionally Hidden
			-- the instant it was created, every single login, with nothing
			-- anywhere in this addon ever calling :Show() on it afterward
			-- (ApplyAllDefaultBars only calls SetDefaultBarEnabled, which
			-- itself early-returns for id == 1, for ids 2-5). This is why
			-- the Main Bar rendered nothing at all post-migration while
			-- still dispatching keybinds correctly (the real, now-hidden
			-- ActionButton1-12 still fire natively regardless of our own
			-- replica's Show/Hide state - see this function's own comment
			-- on Hide() not breaking native keybind dispatch).
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
				-- Bars 2-5: apply OUR OWN saved cfg.enabled directly - it's
				-- now the sole source of truth (see SetDefaultBarEnabled's
				-- header comment above; the old native-global
				-- reconciliation this comment used to describe no longer
				-- exists, since bars 2-5's real Blizzard buttons are
				-- permanently hidden regardless of this flag).
				self:SetDefaultBarEnabled(id, cfg.enabled)
			end

			-- Issue 1 (bug-fix batch v4): ALWAYS (re)apply this bar's
			-- shape/overlay here, regardless of enabled state - this was
			-- the actual root cause of the overlay-sharing regression.
			-- Previously, for ids 2-5, ApplyDefaultBarShape only ever ran
			-- as a side effect INSIDE SetDefaultBarEnabled(id, true) - so
			-- a bar that resolved disabled here (e.g. bars 4/5, which
			-- additionally depend on each other per
			-- IsDefaultBarNativelyShown's bar-4/bar-5 rule) never got its
			-- real Blizzard button frames repositioned away from
			-- whatever raw anchor Blizzard's own FrameXML left them at,
			-- and EnsureDefaultBarOverlay (only ever called FROM
			-- ApplyDefaultBarShape) never even created that bar's overlay
			-- frame at all - explaining bars 4/5 having no overlay
			-- whatsoever. Worse, since vanilla's own FrameXML anchors the
			-- extra multibars relative to the main bar/each other (not to
			-- UIParent) for their native stacked-above-the-main-bar
			-- layout, a bar that was never independently re-anchored by
			-- ApplyDefaultBarShape stayed visually coincident with
			-- whichever bar it was still natively anchored to - which is
			-- exactly why bar 1's overlay APPEARED to span bars 2/3's
			-- area too (their real buttons had never moved away from
			-- bar 1's native anchor chain) and why dragging bar 1
			-- appeared to drag bars 2/3 along with it (they were still
			-- riding bar 1's anchor, not independently positioned from
			-- their own cfg.x/cfg.y at all). Calling ApplyDefaultBarShape
			-- unconditionally here guarantees every one of the 5 bars is
			-- independently re-anchored to UIParent from its own cfg (see
			-- ApplyDefaultBarShape's `first:ClearAllPoints()` /
			-- PixelSetPoint call), which fully severs any such inherited
			-- anchor chain, and guarantees every bar's overlay frame
			-- exists and is correctly sized/positioned from that point on
			-- - independent of whether the bar is currently enabled to
			-- display (a hidden bar's buttons/overlay simply stay
			-- Hidden, per SetDefaultBarEnabled's Show()/Hide() loop and
			-- ApplyDefaultLayoutEditVisual's enabled check, respectively).
			self:ApplyDefaultBarShape(id)
		end
	end
end

-------------------------------------------------------------------------
-- Default bar / stance bar dragging (Edit Layout mode, useDefaultLayout
-- == false only)
--
-- Default bars (1-5) are real Blizzard frames, not a container frame we
-- own the way Bar.lua's custom bars are (see Bar.lua's
-- StartBarDrag/StopBarDrag, which just call bar:StartMoving()/
-- StopMovingOrSizing() on a frame TrustyBars itself created with
-- SetMovable(true)). We only have the 12 individual button frames per
-- default bar, and there's no single frame anchoring all 12 that
-- StartMoving() could be called on instead - so this tracks the cursor
-- delta manually every frame (one shared OnUpdate-driven frame, not a
-- polling-from-scratch loop) and re-applies cfg.x/cfg.y through
-- ApplyDefaultBarShape, which already knows how to reposition all 12
-- buttons from those two fields. The stance bar (below) reuses this same
-- shared drag frame/OnUpdate for the same reason: it's also a single
-- real Blizzard frame we don't own.
-------------------------------------------------------------------------

-- Created lazily, exactly once - shared by every default-bar AND
-- stance-bar drag (only one drag can ever be in progress at a time,
-- since it's driven by mouse button state), so a second frame per drag
-- kind would be redundant.
local dragFrame

-- LOCK_ACTIONBAR proactive session-scoped lock - REMOVED (Issue 2, bug-fix
-- batch v3). This used to force LOCK_ACTIONBAR = "1" for the entire
-- CanDragDefaultLayout() window as a workaround for HookScript("OnDragStart",
-- ...) always running AFTER Blizzard's own native handler had already
-- decided to PickupAction - too late to react by the time a post-hook ran.
-- That workaround is no longer needed: dragging is now owned entirely by
-- EnsureDefaultBarOverlay/EnsureContainerOverlay's own bar-level frames
-- (SetScript, not HookScript), which are mouse-enabled and sit in HIGH
-- strata fully covering the real buttons during exactly this same window
-- (see ApplyDefaultLayoutEditVisual below). A mouse-enabled frame on top
-- intercepts the drag gesture at the frame-stacking level before it ever
-- reaches the real button underneath - the native OnDragStart handler
-- those buttons still have is simply never invoked at all in this state,
-- so there is nothing left for LOCK_ACTIONBAR to need to prevent.

local function GetCursorPositionUIScale()
	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / scale, y / scale
end

-- Shared OnUpdate body for both drag kinds - `this` is dragFrame itself
-- (an engine-invoked handler, so `this` per the file-level convention
-- noted throughout this addon, e.g. Button.lua's header comment).
local function DefaultBarDrag_OnUpdate()
	local cx, cy = GetCursorPositionUIScale()
	local dx = cx - this.dragStartCursorX
	local dy = cy - this.dragStartCursorY

	if this.dragKind == "defaultBar" then
		local cfg = BTVanillaDB.defaultBars[this.dragId]

		if cfg then
			cfg.x = this.dragStartX + dx
			cfg.y = this.dragStartY + dy

			BTV:ApplyDefaultBarShape(this.dragId)
		end
	elseif this.dragKind == "stanceBar" then
		local pos = BTVanillaDB.stanceBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyStanceBarPosition()
		end
	elseif this.dragKind == "bagBar" then
		local pos = BTVanillaDB.bagBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyBagBarPosition()
		end
	elseif this.dragKind == "microMenu" then
		local pos = BTVanillaDB.microMenuPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyMicroMenuPosition()
		end
	elseif this.dragKind == "keyRing" then
		local pos = BTVanillaDB.keyRingPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyKeyRingPosition()
		end
	elseif this.dragKind == "latencyBar" then
		local pos = BTVanillaDB.latencyBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyLatencyBarPosition()
		end
	elseif this.dragKind == "expBar" then
		local pos = BTVanillaDB.expBarPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyExpBarPosition()
		end
	elseif this.dragKind == "pageIndicator" then
		local pos = BTVanillaDB.mainBarPageIndicatorPosition

		if pos then
			pos.x = this.dragStartX + dx
			pos.y = this.dragStartY + dy

			BTV:ApplyPageIndicatorPosition()
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

-- True only while both Edit Layout mode AND useDefaultLayout == false are
-- active - the single shared gate every default-bar-button/stance-bar
-- drag hook below checks before doing anything, mirroring
-- BTV:IsEditMode()'s own nil-safety (this can in principle be queried
-- before EnsureDB has ever run).
function BTV:CanDragDefaultLayout()
	return self:IsEditMode() and BTVanillaDB and BTVanillaDB.useDefaultLayout == false
end

function BTV:StartDefaultBarDrag(id)
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[id]

	if not cfg then
		return
	end

	local cx, cy = GetCursorPositionUIScale()

	local frame = EnsureDragFrame()

	frame.dragKind = "defaultBar"
	frame.dragId = id
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = cfg.x or 0
	frame.dragStartY = cfg.y or 0

	frame:SetScript("OnUpdate", DefaultBarDrag_OnUpdate)
	frame:Show()
end

function BTV:StopDefaultBarDrag(id)
	if not dragFrame then
		return
	end

	dragFrame:SetScript("OnUpdate", nil)
	dragFrame:Hide()

	-- Keeps the Settings X/Y sliders in sync if this bar's page happens
	-- to already be built/cached - same pattern as GridSwatch_OnClick/the
	-- "Reset to Blizzard Default" button (Settings.lua). A no-op if the
	-- Settings window/page was never opened this session.
	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(id)
	end
end

-- Stance Bar position/spacing/scale/orientation/enable/drag: moved to the
-- "Stance Bar (chain-anchored container)" section further below in this
-- file, alongside Bag Bar/Micro Menu/Key Ring/Latency Bar - it now uses the
-- exact same BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay machinery those elements use, rather than wrapping
-- the real ShapeshiftBarFrame directly the way this section used to.

-------------------------------------------------------------------------
-- Bag Bar / Micro Menu (feature 3)
--
-- Neither element has a single native Blizzard container frame on real
-- vanilla 1.12.1 (confirmed via the vendored Bartender2/ reference
-- addon's own approach on this same client generation) - Bartender2's
-- proven pattern is followed exactly: build our own empty synthetic
-- container frame and individually reparent+chain-anchor each real
-- button into it (button 2 anchored to button 1's own edge, etc. - NOT
-- each button anchored independently to the container).
--
-- Bag Bar = the 5 real vanilla 1.12 bag buttons (no KeyRing - that's a
-- later-expansion feature). Micro Menu = the 8 real micro-menu buttons
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
-- Bug-fix batch Fix 1: uses the MEDIAN of the raw gaps array rather than
-- a bucket-within-0.5px/majority-vote scheme. The old majority-vote
-- approach silently defaulted to buckets[1] (whichever gap was measured
-- first) on a tie between two equally-sized buckets - live-tested native
-- data for the Micro Menu turned out to be extremely uniform (no real
-- bug triggered there), but a median is still more statistically robust
-- against outliers/ties than a vote system, and removes that silent-
-- tiebreak failure mode entirely for any chain whose native spacing
-- turns out less uniform than the Micro Menu's. Sorting a small (<=7
-- element, one fewer than BAG_BAR_BUTTON_NAMES/MICRO_MENU_BUTTON_NAMES'
-- own max length) array via table.sort is real Lua 5.0 (confirmed
-- working per this addon's environment doc), so no custom sort is
-- needed.
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
-- sorted left-to-right by SortButtonsByNativeLeft) into it, exactly
-- mirroring Bartender2's own technique - the actual chain-anchoring
-- (button 1 to the container's own TOPLEFT, every subsequent button
-- anchored to the previous one) is factored out into
-- ApplyChainAnchoredShape below (bug-fix batch Fix 4) so it can be
-- re-run any time cfg.spacing/cfg.orientation/cfg.scale changes, not just
-- once here at creation.
--
-- HIGH strata (bug-fix batch Fix 2): without an explicit strata this
-- frame inherits the ordinary default tier, which can render BEHIND
-- MainMenuBarArtFrame's own background art - HIGH sits above that
-- unconditionally, not just during edit mode (EnsureContainerOverlay's
-- own TOOLTIP-strata overlay is unaffected, being a separate frame only
-- shown during editing).
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

	-- Round 7 root-cause fix: button 1's captured lefts[1]/tops[1] are in
	-- ITS OWN effective-scale coordinate space, not literal screen pixels -
	-- same conversion as Core.lua's CaptureNativeAnchor (see its own
	-- comment for the full derivation and the live-confirmed ~1.4246x
	-- scale-mismatch symptom this exact unguarded pattern produced for
	-- default bar 1). The caller always stores these two return values as
	-- a UIParent-anchored container's own x/y offset (this container is
	-- itself a bare CreateFrame(..., UIParent) with no SetScale of its
	-- own, so its effective scale always equals UIParent's exactly) - so
	-- converting through real screen pixels here, once, fixes every
	-- caller (Bag Bar/Micro Menu/Stance Bar) uniformly rather than
	-- patching each one's own capture site separately.
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
-- CURRENT spacing/orientation, and applies its current scale - shared by
-- BTV:ApplyBagBarShape/ApplyMicroMenuShape below (bug-fix batch Fix 4)
-- rather than duplicated, since both elements use the exact same
-- chain-anchoring technique BuildChainAnchoredContainer already set up.
--
-- horizontal (orientation == false, native default): each button's
-- TOPLEFT anchors to the previous button's TOPRIGHT, offset by `spacing`
-- - identical to the original inline logic this replaces, just reading
-- the current cfg.spacing instead of the one-time captured native gap.
--
-- vertical/orientation-swapped (orientation == true): each button's
-- TOPLEFT anchors to the previous button's BOTTOMLEFT, offset downward
-- by `spacing` - mirrors Bartender2's own Swap branch.
-- Issue A (bug-fix batch round 2, live-confirmed root cause): this used to
-- chain EVERY enumerated button unconditionally, regardless of IsShown() -
-- GetButtonsByName only ever filtered on the global existing, never on
-- whether Blizzard currently has that button shown. TalentMicroButton is
-- natively hidden below level 10 (real FrameXML's own UpdateMicroButtons,
-- MainMenuBarMicroButtons.lua) while still being a real, existing global -
-- so it was still being anchored INTO the chain and still reserving a
-- full button-width-plus-spacing slot, producing a visible gap right where
-- the (invisible) Talent button "would have been" between Spellbook and
-- QuestLog. Confirmed via the user's own screenshot (gap immediately after
-- the Spellbook icon) matching exactly the Spellbook->Talent->QuestLog
-- chain position. Filtered live (IsShown(), re-checked on every call, not
-- just once at container-build time) rather than at GetButtonsByName/
-- BuildChainAnchoredContainer time, since a button's shown state CAN
-- change mid-session (leveling past 10 unlocks Talent) - see the
-- UpdateMicroButtons hook further below, which re-runs ApplyMicroMenuShape
-- exactly when Blizzard's own code re-evaluates that.
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
		return
	end

	first:ClearAllPoints()
	PixelSetPoint(first, "TOPLEFT", container, "TOPLEFT", 0, 0)

	local totalWidth = widths[firstIndex] or 0
	local totalHeight = heights[firstIndex] or 0

	local prevBtn = first

	for i = firstIndex + 1, table.getn(buttons) do
		local btn = buttons[i]

		if btn then
			if btn:IsShown() then
				local w = widths[i] or 0
				local h = heights[i] or 0

				btn:ClearAllPoints()

				if orientation then
					PixelSetPoint(btn, "TOPLEFT", prevBtn, "BOTTOMLEFT", 0, -spacing)

					totalHeight = totalHeight + spacing + h

					if w > totalWidth then
						totalWidth = w
					end
				else
					PixelSetPoint(btn, "TOPLEFT", prevBtn, "TOPRIGHT", spacing, 0)

					totalWidth = totalWidth + spacing + w

					if h > totalHeight then
						totalHeight = h
					end
				end

				prevBtn = btn
			else
				-- Hidden - parked at the last VISIBLE button's own TOPLEFT
				-- (harmless overlap, since a hidden frame renders/receives
				-- no mouse events either way) rather than left dangling on
				-- a stale anchor from an earlier layout pass, or - worse -
				-- left consuming a chain slot the way this bug used to.
				btn:ClearAllPoints()
				PixelSetPoint(btn, "TOPLEFT", prevBtn, "TOPLEFT", 0, 0)
			end
		end
	end

	PixelSetSize(container, totalWidth, totalHeight)
	container:SetScale(scale or 1)
end

-- Shared overlay helper (feature 3) - drag ownership + right-click-to-
-- settings, exactly mirroring EnsureDefaultBarOverlay's boilerplate above
-- (TOOLTIP strata for the same filled-button-strata-gap workaround - see
-- EnsureDefaultBarOverlay's own comment for why TOOLTIP specifically).
-- Parameterized rather than one near-identical copy per caller: only the
-- container frame, the drag start/stop callbacks, the settings-page key to
-- open on right-click, and (Issue 4, bug-fix batch) an optional
-- scroll-to-scale setter differ per caller (Bag Bar/Micro Menu/Key
-- Ring/Latency Bar/Stance Bar all share this one implementation).
--
-- scaleSetFn (Issue 4): mirrors Button.lua's BTVButtonMixin.OnMouseWheel's
-- step/delta convention (arg1 = scroll delta, positive = up/away) applied
-- to scale instead of buttonSize - EnsureDefaultBarOverlay's own default-
-- bar-only mouse-wheel-resize handler was never carried over to this
-- shared helper when it was written, which is why none of these 5 elements
-- had scroll-to-scale despite dragging already working identically on all
-- of them. Optional parameter still - remains nil for any future caller
-- with no real scale concept - but Key Ring (bug-fix batch round 2, Issue
-- B) now has one too (BTV:SetKeyRingScale/BTVanillaDB.keyRingScale,
-- DefaultBars.lua), so its own call site (BTV:ApplyKeyRingPosition) wires
-- it in exactly like the other 4 elements.
-- Current scale is read directly off `container:GetScale()` rather than a
-- separate getter parameter - every one of the 5 real setters
-- (SetBagBarScale/SetMicroMenuScale/SetStanceBarScale/SetLatencyBarScale/
-- SetKeyRingScale) already calls SetScale on this exact frame as its very
-- last step, so GetScale() always reflects the last applied value with no
-- extra plumbing needed.
--
-- level (Issue 2, bug-fix batch round 5): optional, defaults to 100 - the
-- value every caller used unconditionally before this fix. Bar.lua's own
-- CreateBarFromConfig comment (Issue C) already established, from live
-- testing, that same-strata ties on this client are NOT reliably broken by
-- creation order - only explicit FrameLevel does that reliably. Every
-- default-bar overlay (EnsureDefaultBarOverlay above) AND every one of
-- these 5 chain-anchored containers' own overlays previously shared this
-- exact same TOOLTIP+100 combination, so any pair of them that happened to
-- overlap on screen had an UNDEFINED winner. Key Ring's native default
-- position sits directly against/inside the Bag Bar container's own
-- bounding box (KeyRingButton is anchored to whichever bag-bar button it
-- originally sat beside - see ApplyKeyRingPosition's header comment - and
-- that button now lives inside bagBarContainer, whose own overlay
-- SetAllPoints(bagBarContainer) covers that same screen region) - live-
-- tested to lose that tie while positioned there, confirming the Bag Bar's
-- overlay was winning it. Passing a level strictly greater than 100 for
-- Key Ring's own call site (below) removes the ambiguity outright rather
-- than depending on undefined tie-break behavior.
--
-- Overlay is parented to UIParent, NOT `container` (bug-fix batch round
-- 6, Issue 2 continued): dragging at Key Ring's native default position
-- still lost to something even at level 150, while every OTHER chain-
-- anchored container (Bag Bar/Micro Menu/Stance Bar/Page Indicator) is
-- already a direct UIParent child (BuildChainAnchoredContainer's own
-- `CreateFrame("Frame", frameName, UIParent)`) - so THEIR overlays'
-- absolute level numbers were always being compared apples-to-apples
-- (one level of UIParent-child nesting each). KeyRingButton/
-- MainMenuBarPerformanceBarFrame are real native frames, deep inside
-- Blizzard's own FrameXML ancestor chain (NOT a UIParent-direct child) -
-- parenting their overlay TO them (the old `CreateFrame("Frame", nil,
-- container)`) put those two overlays at a different, native-client-
-- controlled nesting depth than every sibling overlay they compete
-- against on screen. SetAllPoints(container) still anchors the overlay
-- to the real frame's own live position/size exactly as before -
-- parenting and anchoring are independent in this client (SetPoint takes
-- a frame reference, not a parent relationship) - so this only changes
-- which ancestor tree the overlay's own absolute FrameLevel is compared
-- within, not where it visually sits. See SetKeyRingEnabled/
-- SetLatencyBarEnabled below for the explicit overlay:Hide() this now
-- requires: with the overlay no longer a child of the real frame, hiding
-- the real frame alone no longer implicitly cascades to hide the overlay
-- too.
local function EnsureContainerOverlay(container, startDragFn, stopDragFn, settingsKey, scaleSetFn, level)
	if container.btvOverlay then
		return container.btvOverlay
	end

	local overlay = CreateFrame("Frame", nil, UIParent)

	overlay:SetFrameStrata("TOOLTIP")
	overlay:SetFrameLevel(level or 100)
	overlay:SetAllPoints(container)

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")
	tex:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	tex:SetAllPoints(overlay)

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

	-- Issue 4 (bug-fix batch): scroll-to-scale, gated the same way
	-- Button.lua's BTVButtonMixin.OnMouseWheel gates scroll-to-resize for
	-- custom bars (edit mode required) - this overlay is only ever
	-- mouse-enabled during that same CanDragDefaultLayout() window anyway
	-- (ApplyContainerOverlayVisual below), so in practice this handler can
	-- only ever fire then, but the explicit check keeps this self-
	-- contained/consistent with the rest of this addon's convention rather
	-- than relying solely on EnableMouse(false) elsewhere.
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
-- BTV:CanDragDefaultLayout()'s result - mirrors
-- EnsureDefaultBarOverlay's own enabled-AND-shown gating for default
-- bars 2-5.
local function ApplyContainerOverlayVisual(container, enabledFlag, show)
	if not container or not container.btvOverlay then
		return
	end

	local overlay = container.btvOverlay
	local interactive = show and (enabledFlag ~= false)

	overlay:EnableMouse(interactive and true or false)

	if interactive then
		overlay:Show()
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

	EnsureContainerOverlay(container, self.StartBagBarDrag, self.StopBagBarDrag, "bagbar", self.SetBagBarScale)
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

			-- Bug-fix batch round 6: EnsureContainerOverlay's overlay is now
			-- parented to UIParent, not this container (see its own updated
			-- comment) - hiding the container no longer implicitly cascades
			-- to hide the overlay too.
			if self.bagBarContainer.btvOverlay then
				self.bagBarContainer.btvOverlay:Hide()
				self.bagBarContainer.btvOverlay:EnableMouse(false)
			end
		end
	end
end

-- Bug-fix batch Fix 4: re-lays-out the Bag Bar's real buttons from its
-- CURRENT saved spacing/orientation/scale, via the shared
-- ApplyChainAnchoredShape helper above - called by every one of this
-- section's setters below instead of each duplicating the chain-anchor
-- logic. A no-op until CreateBagBarAndMicroMenu has built the container
-- (ApplyChainAnchoredShape's own container.chainButtons nil-check).
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

	EnsureContainerOverlay(container, self.StartMicroMenuDrag, self.StopMicroMenuDrag, "micromenu", self.SetMicroMenuScale)
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

			-- Bug-fix batch round 6: same explicit-hide requirement as
			-- SetBagBarEnabled above.
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

	if spacing < 0 then
		spacing = 0
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
			-- the real-screen-pixel-converted values BuildChainAnchoredContainer
			-- returns (Round 7 root-cause fix - see its own comment), not a
			-- raw GetLeft()/GetTop() copy, so no further translation is
			-- needed here.
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

			-- Permanent pristine spacing snapshot (bug-fix batch Fix 4),
			-- mirroring bagBarNativeAnchor above exactly - captured ONCE
			-- here via ComputeMajorityGap (BuildChainAnchoredContainer),
			-- never re-derived afterward.
			if not BTVanillaDB.bagBarNativeSpacing then
				BTVanillaDB.bagBarNativeSpacing = nativeSpacing
			end

			if not BTVanillaDB.bagBarSpacing then
				BTVanillaDB.bagBarSpacing = nativeSpacing
			end

			-- Lays out the chain from the (freshly seeded, or previously
			-- saved) spacing/orientation/scale BEFORE ApplyBagBarPosition
			-- below, so the container's real size is already correct by
			-- the time the one-time diagnostic print reads GetWidth()/
			-- GetHeight().
			self:ApplyBagBarShape()

			self:ApplyBagBarPosition()
			self:SetBagBarEnabled(BTVanillaDB.bagBarEnabled ~= false)

			-- One-time diagnostic (never fires again this session) - lets a
			-- live tester confirm exactly what native size/spacing was
			-- captured, mirroring seedDefaultBars' own diagnostic print
			-- (Core.lua) for the exact same "live-captured, not guessed"
			-- reason.
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

-- Issue A (bug-fix batch round 2): UpdateMicroButtons is real vanilla
-- FrameXML's own global function (MainMenuBarMicroButtons.lua) that decides
-- TalentMicroButton's (and any other conditionally-hidden micro button's)
-- Show()/Hide() state, registered against PLAYER_LEVEL_UP/
-- PLAYER_ENTERING_WORLD/PLAYER_TALENT_UPDATE/etc. in native FrameXML.
-- Hooking THIS function directly - rather than re-registering our own
-- listener on each of those individual native events ourselves - means
-- this addon always reacts at exactly the same moment Blizzard's own code
-- actually changed a button's shown state, regardless of which native
-- event triggered that decision. hooksecurefunc runs AFTER the native
-- handler has already called Show()/Hide() on the real button, so
-- ApplyMicroMenuShape's own IsShown() checks (ApplyChainAnchoredShape
-- above) see the new state immediately. A harmless no-op call if
-- self.microMenuContainer hasn't been built yet this session
-- (ApplyChainAnchoredShape's own container.chainButtons nil-check).
-- Registered once here at file load (top-level), same timing the
-- ChangeActionBarPage hook above this file already relies on.
if hooksecurefunc and UpdateMicroButtons then
	hooksecurefunc("UpdateMicroButtons", function()
		BTV:ApplyMicroMenuShape()
	end)
end

-------------------------------------------------------------------------
-- Stance Bar (chain-anchored container)
--
-- Migrated from a bespoke ShapeshiftBarFrame-wrapping implementation (the
-- old EnsureStanceBarOverlay/PositionStanceBarOverlay/
-- CaptureStanceBarPositionIfNeeded/HookStanceBarDrag are gone entirely;
-- ApplyStanceBarPosition/StartStanceBarDrag/StopStanceBarDrag/
-- SetStanceBarEnabled are redefined below against the container instead of
-- the real ShapeshiftBarFrame) to the exact same chain-anchored-container
-- technique Bag Bar/Micro Menu use above: real
-- ShapeshiftButton# frames are reparented into our own synthetic container
-- and chain-anchored via ApplyChainAnchoredShape, keeping their native
-- shapeshift-form rendering (icon/cooldown/active-form glow) entirely
-- intact - a custom Button.lua-style replica would have meant
-- reimplementing all of that from the shapeshift-form API from scratch.
--
-- The one real difference from Bag Bar/Micro Menu: the Stance Bar's button
-- COUNT is class/talent-driven (BTV:GetStanceBarButtons' GetNumShapeshiftForms()
-- based enumeration above), not a fixed 5/8, so RebuildStanceBarContainer
-- below re-enumerates and updates the container's chain in place whenever
-- that count can have changed, instead of only ever building once.
-------------------------------------------------------------------------

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

	EnsureContainerOverlay(container, self.StartStanceBarDrag, self.StopStanceBarDrag, "stance", self.SetStanceBarScale)
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

			-- Bug-fix batch round 6: same explicit-hide requirement as
			-- SetBagBarEnabled above.
			if self.stanceBarContainer.btvOverlay then
				self.stanceBarContainer.btvOverlay:Hide()
				self.stanceBarContainer.btvOverlay:EnableMouse(false)
			end
		end
	end
end

-- Issue 3 (round 14): real, live-captured row-to-row vertical distance
-- between bar 1 (Main) and bar 2 (Bottom Left) - NOT a hardcoded/guessed
-- pixel constant. Both bars' cfg.nativeAnchor.y were already captured live
-- from their real Blizzard frames at login (Core.lua's CaptureNativeAnchor/
-- seedDefaultBars), regardless of either bar's enabled state, so this is
-- always available. Real vanilla's default action-bar cluster stacks every
-- row (Main, Bottom Left, Bottom Right, and the Stance Bar when shown) at
-- this same uniform vertical spacing, so the gap between bar 1 and bar 2 is
-- the same amount of room the Stance Bar needs to open up above bar 2 when
-- it becomes visible - see ReflowStanceBarForBar2Toggle below, its only
-- caller.
function BTV:GetDefaultBarRowHeight()
	local defaults = BTVanillaDB and BTVanillaDB.defaultBars
	local cfg1 = defaults and defaults[1]
	local cfg2 = defaults and defaults[2]

	if not cfg1 or not cfg2 or not cfg1.nativeAnchor or not cfg2.nativeAnchor then
		return nil
	end

	return cfg2.nativeAnchor.y - cfg1.nativeAnchor.y
end

-- Issue 3 (round 14): replicates real vanilla's ShapeshiftBar_UpdatePosition
-- side effect against the Stance Bar's own synthetic container instead of
-- the (now purely internal, no-longer-visually-relevant) real
-- ShapeshiftBarFrame - see SetDefaultBarEnabled's own comment above for why
-- the native call stopped doing anything useful post-migration. Applies a
-- symmetric +/- delta on every actual bar-2 enabled-state CHANGE (never a
-- from-scratch recompute) so any number of toggles in either order stays
-- exactly in sync with no drift - each enable is undone by exactly one
-- later disable of equal, opposite magnitude, and vice versa. Only ever
-- called while useDefaultLayout ~= false (SetDefaultBarEnabled's own gate,
-- mirroring the pre-migration implementation's identical gate) - once the
-- user has switched the Stance Bar to manual positioning
-- (CanDragDefaultLayout() == true), this must never fight their own
-- dragged position.
function BTV:ReflowStanceBarForBar2Toggle(bar2Enabled)
	local pos = BTVanillaDB.stanceBarPosition
	local container = self.stanceBarContainer

	if not pos or not container then
		return
	end

	local rowHeight = self:GetDefaultBarRowHeight()

	if not rowHeight then
		return
	end

	-- UIParent-bottom-left-origin coordinates (y increases upward - see
	-- Core.lua's CaptureNativeAnchor comment): bar 2 sitting ABOVE bar 1
	-- means becoming shown means the Stance Bar above IT must move further
	-- up (y increases) to keep clearing it; becoming hidden reverses that.
	pos.y = pos.y + (bar2Enabled and rowHeight or -rowHeight)

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
-- ResetBagBarLayout exactly. Renamed from the old ResetStanceBarScale
-- (Scale-only) now that Spacing/Orientation are real, saved fields too.
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
-- in response) - it fires whenever the player's available stance/form set
-- changes, e.g. a talent respec unlocking a new form, or a zone/buff
-- granting/removing one. UNVERIFIED specifically on this modded client
-- (SuperWoW/nampower/ClassicAPI/UnitXP_SP3 don't touch this event, but it
-- hasn't been live-confirmed to still fire exactly like stock 1.12.1 here)
-- - if a live test ever shows it doesn't fire, RebuildStanceBarContainer
-- can also be called manually via a slash command as a fallback, but no
-- such fallback is wired up preemptively per this addon's "don't guess,
-- verify" rule.
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
-- Key Ring (bug-fix batch Fix 2)
--
-- KeyRingButton is confirmed live to exist as a real global frame on this
-- client (not present in true vanilla 1.12.0, but present here) -
-- previously completely unmanaged: it stays anchored to whichever real
-- bag button it was natively anchored to (SetPoint targets a FRAME, not a
-- parent, so reparenting that bag button into the Bag Bar's own synthetic
-- container above doesn't change what KeyRingButton itself is anchored
-- to), so it visually "rides along" behind/underneath the Bag Bar
-- container - a stray floating button never independently managed.
--
-- Deliberately NOT added to BAG_BAR_BUTTON_NAMES/the Bag Bar's own chain
-- - the user wants it independently toggleable and independently
-- positionable, not just another chained member. It's also a single real
-- native button, not a container we build, so (unlike Bag Bar/Micro Menu
-- above) it's repositioned directly via PixelSetPoint on itself - the
-- exact same "one real Blizzard frame, no chain-anchoring needed"
-- treatment ApplyStanceBarPosition already uses for ShapeshiftBarFrame.
--
-- Every function below defensively no-ops if KeyRingButton doesn't exist
-- on some other client build - matches how every other optional-native-
-- element accessor in this file already degrades (GetDefaultBarButtons/
-- GetStanceBarButtons' "stop/skip on missing frame" tolerance,
-- CreateBagBarAndMicroMenu's own per-element existence check).
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
-- ApplyBagBarPosition's structure exactly, reusing EnsureContainerOverlay
-- directly against KeyRingButton itself (that helper is generic over any
-- frame with its own .btvOverlay cache, not specific to the synthetic
-- containers Bag Bar/Micro Menu build - a single real button works
-- exactly the same way).
-- Issue 2 (bug-fix batch round 4): EnsureContainerOverlay is now called
-- unconditionally whenever `frame` exists, NOT only when the native
-- position capture also happened to succeed this call. The old
-- `if not pos or not frame then return end` guard meant a login-time call
-- where CaptureKeyRingPositionIfNeeded's GetLeft()/GetTop() read (real
-- native frame, possibly not yet fully laid out at PLAYER_LOGIN) failed to
-- resolve a value would bail out BEFORE ever building the drag/right-click
-- overlay at all - leaving Key Ring undraggable in Edit Layout mode until
-- some later, unrelated call happened to re-invoke this function (e.g. via
-- Settings.lua) once the frame's position had stabilized. Building the
-- overlay is independent of whether a saved/native position is available
-- yet - it's a no-op frame that just needs `frame` itself to exist, which
-- it reliably does at login (a real always-present FrameXML global) - so
-- it's no longer gated on `pos`.
function BTV:ApplyKeyRingPosition()
	self:CaptureKeyRingPositionIfNeeded()

	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	if not frame then
		return
	end

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

	-- scaleSetFn wired (bug-fix batch round 2, Issue B): Key Ring now has a
	-- real scale concept (BTVanillaDB.keyRingScale/BTV:SetKeyRingScale
	-- below), mirroring the other 4 shared-overlay elements exactly - see
	-- SetKeyRingScale's own comment for why this was previously nil.
	--
	-- level = 150 (Issue 2, bug-fix batch round 5): strictly above the 100
	-- every other default-bar/chain-anchored-container overlay uses (see
	-- EnsureContainerOverlay's own updated comment) - Key Ring's native
	-- default position overlaps the Bag Bar container's own overlay, and
	-- this guarantees Key Ring's drag/right-click/scroll surface always
	-- wins that overlap regardless of creation order.
	EnsureContainerOverlay(frame, self.StartKeyRingDrag, self.StopKeyRingDrag, "bagbar", self.SetKeyRingScale, 150)
end

-- Settings.lua's Bag Bar page "Show Key Ring" checkbox writes through
-- this - independent of the Bag Bar's own enable flag, per the task spec
-- (the checkbox lives ON the Bag Bar page, but this element moves/shows/
-- hides independently of the Bag Bar container itself).
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

			-- Bug-fix batch round 6: EnsureContainerOverlay's overlay is now
			-- parented to UIParent, not `frame` (see its own updated
			-- comment) - hiding the real frame no longer implicitly cascades
			-- to hide the overlay too, so this now must be done explicitly
			-- or a disabled-but-still-in-edit-mode Key Ring would leave a
			-- dangling, still-interactable drag/scroll hitbox floating where
			-- the (now invisible) button used to be.
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

	-- Scale (bug-fix batch round 2, Issue B): folded into this same reset
	-- entry point rather than a separate ResetKeyRingScale - every existing
	-- caller of ResetKeyRingPosition (Settings.lua's bagbar page reset
	-- button and its "Use Default Blizzard Layout" re-enable flow) expects
	-- one call to fully restore Key Ring to its native/default state,
	-- mirroring ResetLatencyBarLayout's own position+scale bundling.
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
-- Latency Bar (bug-fix batch Fix 3)
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
-- above exactly, just against MainMenuBarPerformanceBarFrame instead of
-- KeyRingButton (EnsureContainerOverlay is equally generic over either).
-- Issue 2 (bug-fix batch round 4): same "always build the overlay, only
-- conditionally apply the captured position" restructuring as
-- ApplyKeyRingPosition above, for the same reason.
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

	EnsureContainerOverlay(frame, self.StartLatencyBarDrag, self.StopLatencyBarDrag, "latencybar", self.SetLatencyBarScale)
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

			-- Bug-fix batch round 6: same explicit-hide requirement as
			-- SetKeyRingEnabled above, now that EnsureContainerOverlay's
			-- overlay is parented to UIParent instead of `frame` (see its
			-- own updated comment) and no longer auto-hides via parent
			-- cascade.
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
-- Experience Bar (round 16 part 2, Part A)
--
-- MainMenuExpBar - the well-established real vanilla 1.12.1 FrameXML name
-- for the player's XP bar (a StatusBar) - is structurally the same KIND of
-- element as MainMenuBarPerformanceBarFrame above: a single self-contained
-- real Blizzard frame whose own child regions (MainMenuExpText,
-- ExhaustionLevelFillBar/ExhaustionTick/ExhaustionTickGlow for the
-- "rested" shaded portion) are all anchored RELATIVE TO IT, not
-- independently to UIParent - so repositioning/scaling this one frame
-- carries its whole native visual along, exactly like the Latency Bar.
-- UNCONFIRMED on this specific modded client build (same tolerance as the
-- Page Indicator's own UNCONFIRMED-name comment above): every accessor
-- below is defensively nil-checked via getglobal, so a wrong/missing name
-- here just means this container never builds (degrades exactly like a
-- failed Bag Bar/Micro Menu discovery), never a hard error - see this
-- feature's own task report for the live check this still needs.
--
-- Movable/scalable via the same single-real-frame EnsureContainerOverlay
-- treatment as the Latency Bar/Key Ring, ALWAYS - independent of
-- BTVanillaDB.betterExpBarEnabled (Part B's text overlay, further below):
-- this container's own position/scale is unaffected by whether that text
-- is on or off, per this feature's own spec.
-------------------------------------------------------------------------

BTV.EXP_BAR_FRAME_NAME = "MainMenuExpBar"

-- Round 17 item 1: real vanilla FrameXML name for the native percent-of-
-- level label MainMenuExpBar shows by default - confirmed ALWAYS visible
-- on this client (not hover-only, as originally assumed when Part B was
-- first built), so it duplicates/overlaps BTV:ApplyBetterExpBarVisual's own
-- text overlay whenever that's enabled. Hidden/restored live from that
-- function below.
BTV.EXP_TEXT_FRAME_NAME = "MainMenuExpText"

-- Round 17 item 3: real vanilla FrameXML name for the native "how far the
-- rested bonus would carry the player" blue overlay bar - a StatusBar
-- child of MainMenuExpBar per real vanilla 1.12.1 FrameXML
-- (MainMenuBarXP.xml). UNCONFIRMED on this specific modded client build in
-- the same sense as EXP_BAR_FRAME_NAME below - every accessor that uses
-- this is defensively nil/method-checked via getglobal, so a wrong/missing
-- name or unexpected widget type just means the rested-color picker
-- silently has nothing to apply to, never a hard error. Flagged in this
-- feature's own task report as worth a live check.
BTV.EXP_RESTED_FRAME_NAME = "ExhaustionLevelFillBar"

-- Mirrors CaptureLatencyBarPositionIfNeeded/CaptureKeyRingPositionIfNeeded
-- structurally, but - unlike those two (real vanilla SIBLINGS of
-- MainMenuBarArtFrame, not MainMenuBar descendants, which have never shown
-- this symptom) - ADDS the real-screen-pixel GetEffectiveScale conversion
-- Core.lua's CaptureNativeAnchor uses for ActionButton1: MainMenuExpBar is
-- part of that same MainMenuBar cluster, which live-testing already proved
-- CAN have a different effective scale than UIParent (a ~1.4246x live-
-- confirmed mismatch - see CaptureNativeAnchor's own comment for the full
-- derivation). Reusing that exact conversion here guards this element
-- against the same class of bug rather than reintroducing the old
-- unconverted capture for a MainMenuBar-family frame.
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

-- New item (round 17, added mid-round alongside the 5 originally assigned
-- items): MainMenuExpBar has no real bottom border/edge texture of its
-- own in real vanilla - stock UI relies on MainMenuBarArtFrame (sitting
-- beneath the bar at its one fixed native position) to visually cap the
-- bar's raw bottom edge. Once this container is dragged away from that
-- native position - the whole point of this feature - that art no longer
-- sits underneath, exposing the same class of stray native-texture
-- artifact already investigated once before near this exact spot (see
-- BTV:ApplyBlizzardArtVisibility's own "blue bar" comment further above in
-- this file). Fixed by giving the bar its own permanent bottom-edge cap,
-- parented directly to MainMenuExpBar itself - NOT the edit-mode-only
-- btvOverlay square EnsureContainerOverlay creates below, which is only
-- ever shown while actively dragging/editing - so it inherits the real
-- frame's position/scale/show-hide state automatically and stays correct
-- in any dragged position without any extra tracking.
--
-- A real child FRAME (not a bare texture parented straight onto
-- MainMenuExpBar's own OVERLAY layer) - explicit FrameLevel, not creation
-- order or region-layer enum, is what reliably wins same-strata ties on
-- this client (confirmed live - see Bar.lua's CreateBarFromConfig Issue C
-- comment) - guarantees this cap renders above ExhaustionLevelFillBar/
-- ExhaustionTick (real sibling child FRAMES of MainMenuExpBar, whose own
-- frame level a same-frame OVERLAY-layer texture cannot reliably out-
-- render) regardless of whatever level Blizzard's own FrameXML happens to
-- assign them.
local function EnsureExpBarBottomCap(frame)
	if frame.btvBottomCap then
		return frame.btvBottomCap
	end

	local cap = CreateFrame("Frame", nil, frame)

	cap:SetFrameLevel((frame:GetFrameLevel() or 0) + 20)
	cap:SetHeight(2)
	cap:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
	cap:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

	local tex = cap:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")

	-- Dark neutral rather than an attempt to color-match the bevel exactly
	-- (unknowable without a live side-by-side screenshot) - fully opaque,
	-- so it reliably masks whatever native texture is being exposed
	-- underneath regardless of what it actually is. Flagged in this
	-- feature's own task report as worth a live look in case a different
	-- shade reads better against the user's real UI/theme.
	tex:SetVertexColor(0.06, 0.06, 0.06, 1)
	tex:SetAllPoints(cap)

	frame.btvBottomCap = cap

	return cap
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

	EnsureContainerOverlay(frame, self.StartExpBarDrag, self.StopExpBarDrag, "expbar", self.SetExpBarScale)
	EnsureExpBarBottomCap(frame)
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
-- Bar-fill colors (round 17 item 3)
--
-- MainMenuExpBar's own StatusBar fill (the earned-XP progress, a purple/
-- violet in real vanilla) and ExhaustionLevelFillBar's own StatusBar fill
-- (the native "how far the rested bonus would carry the player" overlay,
-- a blue in real vanilla) are each independently recolorable via
-- Settings.lua's color-picker swatches on the Experience Bar's own
-- settings page. Native baseline captured lazily from the real live
-- frames (mirrors CaptureExpBarPositionIfNeeded's own "capture once, real
-- live values only" idiom above) rather than seeded in Core.lua's
-- EnsureDB, since GetStatusBarColor() only returns meaningful values once
-- these frames actually exist.
-------------------------------------------------------------------------

function BTV:CaptureExpBarColorsIfNeeded()
	self:EnsureDB()

	if not BTVanillaDB.expBarColorEarned then
		local frame = getglobal(self.EXP_BAR_FRAME_NAME)
		local r, g, b

		if frame and frame.GetStatusBarColor then
			r, g, b = frame:GetStatusBarColor()
		end

		-- Fallback: a reasonable vanilla-matching purple/violet, only ever
		-- used if the live frame isn't available yet at capture time - see
		-- this feature's own task report flagging that the true native
		-- default should still be confirmed via a live GetStatusBarColor()
		-- check.
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

		if restedFrame and restedFrame.GetStatusBarColor then
			r, g, b = restedFrame:GetStatusBarColor()
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

-- Round 18 Bug 1 fix (CRITICAL REGRESSION): this used to be called
-- unconditionally from Core.lua's login sequence and unconditionally
-- applied whatever was captured/fell back to, regardless of
-- BTVanillaDB.betterExpBarEnabled - meaning EVERY user's native XP bar got
-- recolored on every login, even with the "Better Experience Bar" feature
-- fully off (the default). Live-confirmed symptom: the native translucent
-- rested-XP overlay went completely invisible for a tester who never
-- touched this feature at all. CaptureExpBarColorsIfNeeded is still called
-- unconditionally (it only READS the live frames to populate
-- BTVanillaDB.expBarColorEarned/Rested for the Settings page's swatch
-- preview - see Settings.lua's RefreshSimpleBarPage comment - it never
-- writes to the frame itself, so it's harmless regardless of the toggle),
-- but the actual SetStatusBarColor calls below are now gated: when the
-- feature is off, neither MainMenuExpBar nor ExhaustionLevelFillBar has its
-- color touched AT ALL, leaving vanilla's own native colors/alpha exactly
-- as they are. Called from: Core.lua's login sequence, the color-picker's
-- live-preview func/cancelFunc (SetExpBarColorEarned/SetExpBarColorRested),
-- the "Reset Colors to Default" button (ResetExpBarColors), and the
-- "Enable Better Experience Bar" checkbox's own OnClick (Settings.lua) -
-- every one of those is safe to call unconditionally now, since this
-- function itself is the single choke point that decides whether anything
-- actually happens.
function BTV:ApplyExpBarColors()
	self:CaptureExpBarColorsIfNeeded()

	if not BTVanillaDB.betterExpBarEnabled then
		return
	end

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)
	local earned = BTVanillaDB.expBarColorEarned

	if frame and frame.SetStatusBarColor and earned then
		frame:SetStatusBarColor(earned.r, earned.g, earned.b)
	end

	local restedFrame = getglobal(self.EXP_RESTED_FRAME_NAME)
	local rested = BTVanillaDB.expBarColorRested

	if restedFrame and restedFrame.SetStatusBarColor and rested then
		restedFrame:SetStatusBarColor(rested.r, rested.g, rested.b)
	end
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
-- "Better Experience Bar" text overlay (round 16 part 2, Part B; heavily
-- expanded round 17 items 1/2/4)
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
-- (BTV:ApplyExpBarPosition/SetExpBarScale) - this text is parented AND
-- anchored directly to MainMenuExpBar itself, so it automatically follows
-- that frame's position/scale with no separate tracking needed.
-------------------------------------------------------------------------

-- Lua 5.0 has no math.round - same simple floor(x + 0.5) idiom used
-- throughout this addon (e.g. Core.lua's CaptureNativeSpacing), rather
-- than depending on BEB's own BEB.round - this addon only takes
-- inspiration from BEB's formulas, not a runtime dependency on BEB itself
-- being installed/enabled.
local function ExpBarRound(n)
	return math.floor(n + 0.5)
end

-- Round 17 items 2/4: assembles only the currently-enabled segments into
-- one space-joined line. Each segment is already self-labeled ("Lvl 2",
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

-- Round 18 Bug 3 fix: a plain reversed Hide() call (round 17 item 1's
-- original fix, reasserted on every PLAYER_XP_UPDATE/UPDATE_EXHAUSTION/
-- PLAYER_LEVEL_UP) was live-confirmed to NOT stick - MainMenuExpText kept
-- showing regardless. This means Blizzard's native XP bar code re-Shows
-- this FontString on some OTHER trigger these three events don't cover -
-- most likely an OnUpdate script (XP bar text commonly refreshes every
-- frame rather than only on discrete events), which would silently undo a
-- same-frame Hide() no matter which events we listen to.
--
-- Fixed using this codebase's own established precedent for exactly this
-- class of problem (a permanently-re-shown native element) - see the 48
-- real default-bar buttons and BonusActionBarFrame, both neutered via a
-- `Show = function() end` override. Unlike those two (permanent,
-- one-way), this one must be REVERSIBLE - the native label needs to come
-- back the instant the user disables the setting - so the real Show
-- method is captured exactly once, lazily, here in
-- BTV:ApplyBetterExpBarVisual (not at file-load time, since
-- MainMenuExpText may not exist yet that early), and restored verbatim
-- when the feature is turned back off.
local realExpTextShow

local function UpdateBetterExpBarText()
	local text = BTV.betterExpBarText

	if text then
		text:SetText(ComputeBetterExpBarText())
	end

	-- Round 18 Bug 3 fix: Show() itself is now neutered while the feature
	-- is on (see BTV:ApplyBetterExpBarVisual below), so this Hide() call is
	-- largely defense-in-depth at this point rather than the actual fix -
	-- kept because it's harmless and matches the original round 17 item 1
	-- reassert-on-every-update idiom.
	local nativeText = getglobal(BTV.EXP_TEXT_FRAME_NAME)

	if nativeText and BTVanillaDB.betterExpBarEnabled then
		nativeText:Hide()
	end
end

-- Created lazily, once - shared by every later BTV:ApplyBetterExpBarVisual
-- call this session, mirroring every other lazy-build-once frame in this
-- file (e.g. defaultBarOverlays).
local betterExpBarEventFrame

-- Creates (once)/shows/hides/live-updates the text overlay per
-- BTVanillaDB.betterExpBarEnabled - called from Core.lua's login sequence
-- and from the Experience Bar's own settings page (Settings.lua,
-- simpleBarPageConfigs["expbar"] - relocated off the General tab in round
-- 17 item 5).
function BTV:ApplyBetterExpBarVisual()
	self:EnsureDB()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local nativeText = getglobal(self.EXP_TEXT_FRAME_NAME)

	-- Capture the real Show method exactly once, lazily, the first time
	-- this runs after MainMenuExpText actually exists - see this feature's
	-- own header comment above realExpTextShow's declaration for why this
	-- must happen before it's ever neutered below.
	if nativeText and not realExpTextShow then
		realExpTextShow = nativeText.Show
	end

	if not BTVanillaDB.betterExpBarEnabled then
		if self.betterExpBarText then
			self.betterExpBarText:Hide()
		end

		-- Round 17 item 1 / Round 18 Bug 3 fix: reversible restore - undo
		-- the Show() neutering below (if it was ever applied this session)
		-- before calling Show(), so real vanilla's own label comes straight
		-- back rather than silently no-oping against its own neutered method.
		if nativeText then
			if realExpTextShow then
				nativeText.Show = realExpTextShow
			end

			nativeText:Show()
		end

		return
	end

	if nativeText then
		-- Round 18 Bug 3 fix: neuter Show() itself (not just call Hide())
		-- so no native OnUpdate/event handler can re-show this label out
		-- from under us, regardless of what triggers it - a plain Hide()
		-- alone (round 17's fix) was confirmed NOT to stick. Reversed above
		-- the moment betterExpBarEnabled goes back to false.
		if realExpTextShow then
			nativeText.Show = function() end
		end

		nativeText:Hide()
	end

	if not self.betterExpBarText then
		local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		text:SetPoint("CENTER", frame, "CENTER", 0, 0)

		-- OUTLINE flag keeps this readable regardless of whatever's
		-- underneath it (the earned-XP fill vs. the rested-bonus fill can
		-- now be any user-chosen color - round 17 item 3 - without needing
		-- to sample/react to the bar's current fill color).
		local fontPath, fontSize = text:GetFont()

		if fontPath then
			text:SetFont(fontPath, fontSize, "OUTLINE")
		end

		self.betterExpBarText = text

		if not betterExpBarEventFrame then
			betterExpBarEventFrame = CreateFrame("Frame", "BTVanillaBetterExpBarEventFrame")

			-- Round 17 item 4: PLAYER_LEVEL_UP added alongside BEB's own
			-- "$pdl"/"$prt" event list ("$plv"'s own event list covers this
			-- one) so the new Level segment stays live too. All three kept
			-- unconditionally registered regardless of which of the 5
			-- segment toggles are currently on - simpler and safer than
			-- churning registration on every checkbox click.
			betterExpBarEventFrame:RegisterEvent("PLAYER_XP_UPDATE")
			betterExpBarEventFrame:RegisterEvent("UPDATE_EXHAUSTION")
			betterExpBarEventFrame:RegisterEvent("PLAYER_LEVEL_UP")
			betterExpBarEventFrame:SetScript("OnEvent", UpdateBetterExpBarText)
		end
	end

	self.betterExpBarText:Show()
	UpdateBetterExpBarText()
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
-- Default-layout / stance-bar edit-mode overlay refresh (Issue 3,
-- bug-fix batch)
--
-- Mirrors Button.lua's SetEditModeVisual/Bar.lua's ApplyEditModeVisual
-- for custom bars, but gated on BTV:CanDragDefaultLayout() (edit mode
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

	-- Issue 2 (bug-fix batch v2): one bar-level overlay per default bar,
	-- not per-button (see EnsureDefaultBarOverlay's comment above).
	-- Disabled bars (2-5, cfg.enabled == false) keep their overlay hidden
	-- regardless of `show` - their buttons are Hide()'n too (see
	-- SetDefaultBarEnabled), and this frame isn't a child of theirs so it
	-- doesn't automatically hide along with them.
	local id

	for id = 1, 5 do
		local cfg = BTVanillaDB.defaultBars[id]
		local overlay = defaultBarOverlays[id]

		if overlay then
			local enabled = show and cfg and (id == 1 or cfg.enabled == true)

			-- Issue 2 (bug-fix batch v3): the overlay only intercepts mouse
			-- (and can therefore only be dragged from, or right-clicked for
			-- settings) during exactly this same enabled/shown window -
			-- outside of it EnableMouse(false) lets every click/drag pass
			-- straight through to the real buttons underneath, so normal
			-- play (native casting, right-click, hover) is completely
			-- unaffected the rest of the time.
			overlay:EnableMouse(enabled and true or false)

			if enabled then
				overlay:Show()
			else
				overlay:Hide()
			end
		end
	end

	-- Stance Bar / Bag Bar / Micro Menu - all three are now the same kind
	-- of TrustyBars-owned chain-anchored container (BuildChainAnchoredContainer/
	-- ApplyChainAnchoredShape), so they share the exact same
	-- ApplyContainerOverlayVisual treatment: overlay visibility gated on
	-- both edit-mode/useDefaultLayout (`show`) AND this element's own
	-- enable flag, mirroring default bars 2-5's own enabled-AND-shown
	-- gating in the loop above.
	ApplyContainerOverlayVisual(self.stanceBarContainer, BTVanillaDB.stanceBarEnabled, show)
	ApplyContainerOverlayVisual(self.bagBarContainer, BTVanillaDB.bagBarEnabled, show)
	ApplyContainerOverlayVisual(self.microMenuContainer, BTVanillaDB.microMenuEnabled, show)

	-- Key Ring / Latency Bar (bug-fix batch Fixes 2/3) - same generic
	-- ApplyContainerOverlayVisual treatment as Bag Bar/Micro Menu above;
	-- EnsureContainerOverlay is equally generic over a single real button/
	-- frame as it is over a synthetic container, so no separate helper is
	-- needed here. Looked up by name each call (rather than cached) since
	-- this only runs on edit-mode/useDefaultLayout toggles, not per frame.
	ApplyContainerOverlayVisual(getglobal(self.KEYRING_BUTTON_NAME), BTVanillaDB.keyRingEnabled, show)
	ApplyContainerOverlayVisual(getglobal(self.LATENCY_BAR_FRAME_NAME), BTVanillaDB.latencyBarEnabled, show)

	-- Experience Bar (round 16 part 2, Part A) - same generic
	-- ApplyContainerOverlayVisual treatment as Key Ring/Latency Bar above.
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
-- Page Indicator (chain-anchored container) - Stance/Page Bar Assignment
-- feature, Part 4
--
-- Wraps the Main Bar's native page-turn arrows/page-number FontString the
-- exact same way Bag Bar/Micro Menu/Stance Bar wrap their own real
-- Blizzard frames above (BuildChainAnchoredContainer/
-- ApplyChainAnchoredShape/EnsureContainerOverlay) - a real vanilla
-- FontString (MainMenuBarPageNumber) supports GetLeft/GetTop/GetWidth/
-- GetHeight/SetParent/IsShown/SetPoint exactly like a Frame/Button region
-- does, so it slots into that same generic machinery - EXCEPT
-- GetEffectiveScale, which it does NOT support (live-confirmed root cause
-- of a login-breaking crash - see PixelSetPoint's own comment above for
-- the fix: PixelUtil.SetPoint calls GetEffectiveScale on both its region
-- and relativeTo arguments, so PixelSetPoint now falls back to plain
-- SetPoint whenever either side of a chain-anchor is a FontString/Texture
-- lacking that method).
--
-- UNCONFIRMED frame names on this specific modded client: ActionBarUpButton/
-- ActionBarDownButton/MainMenuBarPageNumber are the well-established real
-- vanilla 1.12.1 FrameXML names (MainMenuBar.xml) for these three elements,
-- but - unlike every other frame name this file already relies on
-- (ActionButton#, MultiBarBottomLeftButton#, KeyRingButton,
-- MainMenuBarPerformanceBarFrame, etc, all previously live-confirmed
-- present on this client) - these three have NOT yet been live-confirmed
-- here. CreatePageIndicatorContainer below requires ALL three names to
-- resolve (stricter than GetButtonsByName's own generic "skip whatever's
-- missing" tolerance - a partial 1- or 2-element page indicator would be
-- visually broken, not a healthy smaller variant) - a wrong/missing name
-- here just silently never builds this container (degrades exactly like a
-- failed Bag Bar/Micro Menu discovery already does) rather than erroring -
-- but this should still be re-checked live (e.g.
-- `/run print(ActionBarUpButton, ActionBarDownButton, MainMenuBarPageNumber)`)
-- before relying on this feature actually rendering anything.
--
-- Position + Scale only (no Spacing/Orientation slider, unlike Bag Bar/
-- Micro Menu/Stance Bar) - per the feature's own scope. Orientation is
-- fixed vertical here (the native up/down arrows + page number are a
-- vertical stack, not the left-to-right chains those three elements are),
-- and spacing is fixed at 0 rather than auto-captured: BuildChainAnchoredContainer's
-- own ComputeMajorityGap only ever measures a HORIZONTAL gap (lefts/
-- widths) - reusing it here would produce a nonsensical vertical spacing
-- value, and this element deliberately has no user-facing Spacing control
-- to expose/correct that number through anyway, so the 3 elements are
-- simply laid out edge-to-edge instead of at their true native gap. Purely
-- a cosmetic simplification (the whole container is still fully
-- draggable/scalable to compensate) given this element's deliberately
-- narrow scope.
-------------------------------------------------------------------------

BTV.PAGE_INDICATOR_UP_NAME = "ActionBarUpButton"
BTV.PAGE_INDICATOR_DOWN_NAME = "ActionBarDownButton"
BTV.PAGE_INDICATOR_TEXT_NAME = "MainMenuBarPageNumber"

-- Issue 3 (bug-fix batch round 4): this container is NOT a single row/
-- column of same-size, same-type elements chained edge-to-edge - it's two
-- stacked arrow buttons PLUS a text label that needs to sit to their
-- RIGHT, vertically centered against the pair, not "next in the chain"
-- underneath them. BuildChainAnchoredContainer/ApplyChainAnchoredShape
-- (the generic engine Bag Bar/Micro Menu/Stance Bar all correctly use) has
-- no way to express that - forcing this element through it (the previous
-- implementation) chained all three in one vertical run with zero real
-- spacing, which is why the page number rendered at the bottom-left of the
-- container instead of centered-right, and why the up/down gap didn't
-- match Blizzard's own. This container now has its own dedicated,
-- purpose-built layout (CreatePageIndicatorContainer/
-- ApplyPageIndicatorShape below) instead. Its OWN external position/scale/
-- enable behavior (ApplyPageIndicatorPosition/SetPageIndicatorScale/
-- ApplyPageIndicatorVisibility, EnsureContainerOverlay-based drag) is
-- entirely unchanged - only the internal up/down/text arrangement is
-- rewritten here.
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

	-- Round 7 root-cause fix: read each element's REAL native anchor point
	-- (GetPoint(1) - a real Region method every one of these three
	-- supports, including the FontString, unlike GetEffectiveScale - see
	-- PixelSetPoint's own comment above) BEFORE reparenting/moving
	-- anything. SetParent never rewrites another frame's OWN anchor
	-- points - it only changes rendering ownership/strata inheritance -
	-- so if Down and/or the page-number text are natively anchored
	-- directly to Up (or to each other) rather than to some frame outside
	-- this trio, that anchor is already exactly correct and needs no
	-- reconstruction at all: it keeps resolving relative to that same Up/
	-- Down frame object regardless of what that object's own parent
	-- becomes. This replaces the old absolute-pixel-gap measurement +
	-- hardcoded PAGE_INDICATOR_GAP_REDUCTION/TEXT_OFFSET_X/Y nudge
	-- constants entirely - those were reconstructing a relative layout
	-- from absolute screen coordinates (exactly the same fragile pattern
	-- Issue 1's CaptureNativeAnchor bug came from), when Blizzard's own
	-- FrameXML anchor already encodes that relationship correctly.
	local upPoint, upRelTo, upRelPoint, upX, upY = up:GetPoint(1)
	local downPoint, downRelTo, downRelPoint, downX, downY = down:GetPoint(1)
	local textPoint, textRelTo, textRelPoint, textX, textY = text:GetPoint(1)

	-- Diagnostic (fires once, at first build) so the real native topology
	-- on this client build is visible in chat rather than assumed - see
	-- this function's own report for what a live tester should look for.
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
	-- via each frame's own GetEffectiveScale - identical fix/reasoning as
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
	-- natively anchored straight to MainMenuBarArtFrame instead), fall
	-- back to reproducing the exact same real on-screen delta from Up's
	-- own native corner, measured while every one of these three frames is
	-- still at its true, un-reparented Blizzard position - mathematically
	-- the same "translate to be relative to the container instead" the
	-- task calls for, since Up becomes the container's own (0,0) anchor
	-- root below. This delta is a same-family (Up/Down/Text all share one
	-- native ancestor chain) measurement, so no GetEffectiveScale
	-- correction is needed for it, unlike the UIParent-crossing nativeLeft/
	-- nativeTop above.
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

-- Round 7 root-cause fix: no more absolute-pixel-gap measurement or
-- hardcoded pixel nudges. Up is always reanchored to the container's own
-- TOPLEFT (it has to be - it's the one frame this addon's own drag/
-- position system moves the whole container by). Down and the page-number
-- text are each handled per the real native relationship
-- CreatePageIndicatorContainer captured via GetPoint() BEFORE anything was
-- reparented:
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
		self.SetPageIndicatorScale
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

-- Issue 4 (bug-fix batch round 5): "Use Default Blizzard Layout"'s reset
-- cascade (Settings.lua's useDefaultLayout checkbox handler) previously
-- reset every other chain-anchored container (Bag Bar/Micro Menu/Stance
-- Bar/Latency Bar/Key Ring) plus default bars 2-5, but never this one -
-- it was simply never added to that list when this container shipped.
-- Mirrors ResetKeyRingPosition's exact structure: restore position from
-- the permanent mainBarPageIndicatorNativeAnchor snapshot (captured once
-- in CreatePageIndicatorContainer, never re-derived - same "capture, don't
-- guess" rule as every other element's nativeAnchor), then reset scale to
-- 1 via the existing setter.
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
-- Position reassert after combat / looting (round 16, Latency Bar drift
-- fix)
--
-- Live-reported bug: MainMenuBarPerformanceBarFrame (Latency Bar) visibly
-- changes position after combat ends or after looting a mob. Root cause,
-- confirmed by reading every Apply*Position/Apply*Shape function above:
-- every one of these six elements (Bag Bar/Micro Menu/Stance Bar/Key Ring/
-- Latency Bar/Page Indicator) only ever applies its saved position/shape
-- ONCE - at container-build time (RunLoginSequence, Core.lua) or in direct
-- response to a user action (drag stop, a Settings slider, "Reset to
-- Blizzard Default"). Nothing re-asserts it afterward on its own - unlike
-- Bar.lua's ApplyBarShape, which was already fixed in an earlier round to
-- reassert frame level on every shape-affecting call, this whole family of
-- elements has never had an equivalent safety net against something else
-- moving them later.
--
-- Latency Bar and Key Ring are the most exposed to this specific class of
-- bug: both wrap a SINGLE real native Blizzard frame directly (see
-- CaptureLatencyBarPositionIfNeeded/ApplyLatencyBarPosition and
-- CaptureKeyRingPositionIfNeeded/ApplyKeyRingPosition above), never
-- reparented into a container of our own - so if any native FrameXML code
-- path on this client ever calls SetPoint/ClearAllPoints on that exact
-- frame for its own reasons, our own last-applied position is silently
-- discarded with nothing to notice or correct it. Bag Bar/Micro Menu/
-- Stance Bar/Page Indicator's own container frames ARE synthetic
-- (BuildChainAnchoredContainer's CreateFrame("Frame", ..., UIParent)) that
-- Blizzard's FrameXML has no knowledge of and therefore never repositions
-- directly, but the individual real buttons reparented INTO them are still
-- real native frames a native code path could in principle re-anchor -
-- reasserting each container's own ApplyChainAnchoredShape alongside its
-- position closes that same class of gap for those four too, in case the
-- same underlying mechanism ever reaches them (not yet reported by the
-- user for any of them, but the architecture is shared, so the same fix is
-- applied uniformly rather than patched for Latency Bar alone).
--
-- Deliberately does NOT track down the exact native call path that moves
-- MainMenuBarPerformanceBarFrame - that would need a live client check
-- (see the environment doc's §5w for a throwaway diagnostic script), and
-- isn't actually necessary for a correct fix: every Apply* call below is
-- already idempotent and safely no-ops if that element was never built
-- this session (see each function's own nil-guards), so simply re-running
-- them is safe regardless of what actually caused the drift. Triggered on
-- the two events the user's own report describes reproducing the symptom
-- with - PLAYER_REGEN_ENABLED (leaving combat, confirmed firing correctly
-- on this client - doc §5h) and LOOT_CLOSED (the loot window closing, real
-- vanilla's own well-established "looting this corpse is finished" event -
-- chosen over CHAT_MSG_LOOT, which fires once per looted item and would
-- mean reasserting far more often than needed, and over LOOT_OPENED, which
-- fires too early - before looting has actually happened).
--
-- Default bars 1-5 are deliberately NOT included here: their real Blizzard
-- button frames are permanently hidden and Show()-neutered at login
-- (CreateFixedSlotDefaultBars above), so native FrameXML code can no
-- longer make them visibly move at all - this class of bug structurally
-- cannot reach them.
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

	-- Experience Bar (round 16 part 2, Part A): same single-native-frame
	-- risk class as the Latency Bar/Key Ring above (MainMenuExpBar isn't
	-- reparented into a TrustyBars-owned container, unlike Bag Bar/Micro
	-- Menu/Stance Bar/Page Indicator) - reasserted here for the same
	-- reason, even though this specific symptom hasn't been reported for
	-- it yet (see this section's own header comment on why the fix is
	-- applied uniformly across the whole family rather than patched per
	-- element as each one gets reported).
	BTV:ApplyExpBarPosition()

	BTV:ApplyPageIndicatorPosition()
	BTV:ApplyPageIndicatorShape()
end

local positionReassertFrame = CreateFrame("Frame", "BTVanillaPositionReassertFrame")
positionReassertFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
positionReassertFrame:RegisterEvent("LOOT_CLOSED")
positionReassertFrame:SetScript("OnEvent", ReassertNativeElementPositions)
