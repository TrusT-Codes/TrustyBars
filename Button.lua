-- Button.lua
-- Single action-slot-backed button. Follows the pattern confirmed working
-- by ButtonForge Classic (see doc section 5f): a plain, non-secure custom
-- frame, backed by a real vanilla action slot, driven entirely through the
-- native UseAction/PlaceAction/PickupAction/HasAction API. No
-- SecureHandler templates exist on this client and none are needed
-- (confirmed doc section 5e/5h - custom-frame SetPoint/SetSize is
-- unrestricted even during real combat).
--
-- IMPORTANT Lua/vanilla convention note: script handlers invoked BY THE
-- ENGINE (OnClick, OnEvent, OnEnter, OnLeave, OnDragStart, OnReceiveDrag)
-- receive the frame via the global `this`, NOT as a `self` parameter from
-- a method call - that's a modern convention this client predates.
-- Methods we call OURSELVES (Refresh, UpdateCooldown, etc.) are ordinary
-- colon-methods and work normally with `:`. Mixing these two conventions
-- up is an easy, silent mistake - every handler below is a plain function
-- using `this`; every method we call directly uses `:`.

local BTV = BTVanilla

-- Get quality color for an action slot that holds an equipped item.
-- Uses GetInventoryItemQuality("player", invSlot) which reads live from
-- the actual equipped gear state, no item-cache requirement. Bridge from
-- action slot -> inventory slot is done by matching textures: both
-- GetActionTexture and GetInventoryItemTexture return the same path for
-- the same item, so we iterate equipment slots until we find a match.
-- INVSLOT constants confirmed in ClassicAPI's Constants.lua (doc §5c).
local EQUIP_SLOTS_TO_SCAN = {
	0,  -- ammo
	1,  -- head
	2,  -- neck
	3,  -- shoulder
	4,  -- shirt
	5,  -- chest
	6,  -- waist
	7,  -- legs
	8,  -- feet
	9,  -- wrist
	10, -- hands
	11, -- finger1
	12, -- finger2
	13, -- trinket1
	14, -- trinket2
	15, -- back
	16, -- mainhand
	17, -- offhand
	18, -- ranged
	19, -- tabard
}

function BTV:GetActionItemQualityColor(actionSlot)
	if not GetInventoryItemQuality or not GetInventoryItemTexture or not GetActionTexture or not GetItemQualityColor then
		return nil
	end
	local actionTexture = GetActionTexture(actionSlot)
	if not actionTexture then
		return nil
	end
	-- Normalise both sides to lowercase for a reliable match; texture
	-- paths can vary in case across different API call sites.
	local actionTexLower = string.lower(actionTexture)
	for i = 1, table.getn(EQUIP_SLOTS_TO_SCAN) do
		local invSlot = EQUIP_SLOTS_TO_SCAN[i]
		local invTex = GetInventoryItemTexture("player", invSlot)
		if invTex and string.lower(invTex) == actionTexLower then
			local quality = GetInventoryItemQuality("player", invSlot)
			if quality then
				return GetItemQualityColor(quality)
			end
		end
	end
	return nil
end

-- Issue 4 (bug-fix batch): ALWAYS_SHOW_MULTIBARS is the same plain global
-- Lua variable Blizzard's own "Always Show Action Bars" Interface Options
-- checkbox reads/writes (confirmed live by the user via their own
-- SavedVariables.lua: string "1" when checked - not a CVar), cross-checked
-- against the real vanilla 1.12.1 FrameXML source (MultiActionBars.lua),
-- which checks it as `ALWAYS_SHOW_MULTIBARS == "1" or ALWAYS_SHOW_MULTIBARS
-- == 1` to tolerate both the string and numeric forms - custom bars have no
-- native equivalent of MultiActionBar_UpdateGridVisibility() to defer to,
-- so this same dual check is reproduced here directly.
local function IsAlwaysShowMultibars()
	return ALWAYS_SHOW_MULTIBARS == "1" or ALWAYS_SHOW_MULTIBARS == 1
end

-- Exposed as a BTV: method too (Menu.lua's minimap-dropdown toggle needs
-- to read this same check rather than re-deriving a second copy of it -
-- the extra `self` argument this receives when called as BTV:
-- IsAlwaysShowMultibars() is harmless since the underlying function takes
-- no parameters at all).
BTV.IsAlwaysShowMultibars = IsAlwaysShowMultibars

-- Issues 3/4 (bug-fix batch): real vanilla fires ACTIONBAR_SHOWGRID/
-- ACTIONBAR_HIDEGRID whenever the player picks up (respectively releases/
-- cancels) a spell, item, or macro that could be placed on an action bar
-- - this is what makes empty native action buttons temporarily reappear
-- while you're dragging something toward them. Custom-bar buttons never
-- registered for these at all, so they never participated in that native
-- "show empty slots while placing" behavior.
--
-- Single shared listener + a module-level flag, rather than 48+
-- individual per-button RegisterEvent calls, mirrors how this codebase
-- already handles "one global state change, many buttons need to react"
-- elsewhere (HoverBind.lua's IsHoverBindMode - a single flag every
-- button's UpdateRange checks, not a per-button event registration).
-- The event fires globally (it's about what's on the cursor, not about
-- any specific button), so every custom-bar button needs to react
-- identically and simultaneously - a shared flag read by
-- UpdateGridVisibility below is the natural fit.
BTV.isShowingActionGrid = false

-- Shared sweep: re-evaluates UpdateGridVisibility on every live custom-
-- bar button. Factored out so both the ACTIONBAR_SHOWGRID/HIDEGRID
-- listener below AND Menu.lua's "Always Show Action Bars" toggle (which
-- needs the same immediate re-sweep, not just the 0.2s self-healing
-- ticker) call this one place rather than each keeping their own copy of
-- the loop.
function BTV:SweepCustomBarGridVisibility()
	local barId

	for barId, bar in pairs(BTV.bars) do
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn then
					btn:UpdateGridVisibility()
				end
			end
		end
	end
end

-- Settings.lua General tab's "Tint whole button on out of range" checkbox:
-- immediately re-sweeps every live button's UpdateRange so the visual
-- change is instant rather than waiting on the next natural trigger (the
-- 0.2s self-healing rangeTicker set up in Init, or a real usable/range
-- event). Covers every bar in BTV.bars - true custom bars (id 6+) and
-- every default bar (1-5), all of which are real Bar.lua bar objects
-- post-migration (see SetHotkeyFontSize's matching comment).
function BTV:SweepAllButtonRangeTint()
	local barId
	local bar

	for barId, bar in pairs(BTV.bars) do
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn then
					btn:UpdateRange()
				end
			end
		end
	end
end

-- Menu.lua's minimap-dropdown entry. Writes the plain global directly
-- (same "read/write a plain global" pattern as ToggleLockActionBars),
-- then forces an immediate visual refresh instead of waiting on either
-- the 0.2s self-healing ticker (custom bars) or a real
-- ACTIONBAR_SHOWGRID/HIDEGRID event (default bars) to notice the change.
function BTV:ToggleAlwaysShowMultibars()
	local newState = not IsAlwaysShowMultibars()

	ALWAYS_SHOW_MULTIBARS = newState and "1" or nil

	-- Default bars: real vanilla FrameXML global, drives
	-- MultiActionBarButton grid visibility the same way our own
	-- UpdateGridVisibility drives custom bars below.
	if MultiActionBar_UpdateGridVisibility then
		MultiActionBar_UpdateGridVisibility()
	end

	-- Custom bars: no native equivalent to defer to, so sweep them
	-- ourselves through the same shared function the ACTIONBAR_SHOWGRID/
	-- HIDEGRID listener already uses.
	BTV:SweepCustomBarGridVisibility()
end

local gridVisibilityFrame = CreateFrame("Frame")
gridVisibilityFrame:RegisterEvent("ACTIONBAR_SHOWGRID")
gridVisibilityFrame:RegisterEvent("ACTIONBAR_HIDEGRID")
gridVisibilityFrame:SetScript("OnEvent", function()
	BTV.isShowingActionGrid = (event == "ACTIONBAR_SHOWGRID")

	BTV:SweepCustomBarGridVisibility()
end)

BTVButtonMixin = {}

-- Global hotkey/count text font size (Settings.lua's General tab): every
-- button shares ONE setting, not a per-button independent one, so the
-- native default (path/size/flags) is captured ONCE, module-level, the
-- first time any button is created each session - not re-derived per
-- button. Mirrors this codebase's established "capture live, don't guess"
-- convention (Core.lua's CaptureNativeAnchor/CaptureNativeSpacing): the
-- true native size can only be read off a real FontString using its font
-- template (NumberFontNormalSmall/NumberFontNormal), not known ahead of
-- time, so it's captured via GetFont() rather than hardcoded.
local hasCapturedFontDefaults = false

function BTVButtonMixin:Init(parent, actionSlot, slotIndex)
	self.actionSlot = actionSlot
	self.parentBar = parent
	self.slotIndex = slotIndex

	-- Fixed-slot default bars (2-5, major architecture migration) and the
	-- Main Bar (bar 1, dynamic slots - Main Bar migration): these buttons
	-- are already dispatched by a real, native keybind action name -
	-- confirmed live that Hide()ing a real ActionButton does not break its
	-- keybind. This replica's OWN click handling still works identically
	-- (UseAction/PickupAction are generic over any valid slot number), but
	-- it must never register into BTV.customBindTargets/TRUSTYBARSBIND<n>
	-- - that dispatch table is for the free action-slot pool (73-120)
	-- only, and bar 1's dynamic slot CAN land inside that same numeric
	-- range while stance-swapped onto page 7-9 (see the actionSlot check
	-- below, which additionally guards on self.nativeBindingId for exactly
	-- this reason). Its hotkey text (UpdateHotkeyText below) instead shows
	-- the real native binding name, precomputed here from the parent bar's
	-- own id via BTV.DEFAULT_BAR_BINDING_PREFIXES (HoverBind.lua) -
	-- ACTIONBUTTON<slotIndex> for bar 1, MULTIACTIONBAR#BUTTON<slotIndex>
	-- for bars 2-5.
	if parent.config and (parent.config.fixedActionSlots or parent.config.dynamicMainBar) and slotIndex then
		local prefix = BTV.DEFAULT_BAR_BINDING_PREFIXES and
			BTV.DEFAULT_BAR_BINDING_PREFIXES[parent.config.id]

		if prefix then
			self.nativeBindingId = prefix .. tostring(slotIndex)
		end
	end

	-- Registers this button as the live target for HoverBind.lua's
	-- bindings.xml-driven TRUSTYBARSBIND<n> dispatch (n = actionSlot - 72,
	-- range 1-48) - see HoverBind.lua's BTV.customBindTargets comment for
	-- why this is keyed by action slot rather than bar id/frame name.
	-- Range-guarded on actionSlot (a fixed-slot default-bar button's
	-- actionSlot is always < BTV.ACTION_SLOT_START (73), a real native
	-- slot, never part of this free pool) AND on self.nativeBindingId
	-- (Main Bar migration: bar 1's own dynamic slot CAN be >= 73 while
	-- stance-swapped onto page 7-9, which would otherwise wrongly register
	-- it into this free-pool-only table - it already has a real native
	-- binding name of its own, set just above, so it must never dispatch
	-- through TRUSTYBARSBIND<n> regardless of its current numeric slot).
	if actionSlot >= BTV.ACTION_SLOT_START and not self.nativeBindingId then
		BTV.customBindTargets = BTV.customBindTargets or {}
		BTV.customBindTargets[actionSlot - 72] = self
	end

	-- Equipped-item ring, quality-colored. Confirmed from the real XML
	-- template: "UI-ActionButton-Border" is the correct file. Its anchor
	-- (CENTER only) implies no size on its own - it relies entirely on
	-- ApplySize's explicit SetWidth/SetHeight below to get a real size, so
	-- it MUST exist before the initial ApplySize call runs (a bug fixed
	-- here: this used to be created after that call, leaving every
	-- button's ring un-sized - and therefore invisible - until the bar
	-- happened to be resized a second time after creation).
	self.equipRing = self:CreateTexture(nil, "OVERLAY")
	self.equipRing:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	self.equipRing:SetBlendMode("ADD")
	self.equipRing:SetPoint("CENTER", self, "CENTER", 0, 0)
	self.equipRing:Hide()

	-- Native-accurate button border (round 15) - default bars 1-5 only.
	-- True custom bars (id 6+) never were real Blizzard action buttons, so
	-- they have no native chrome to replicate - they keep the existing
	-- SetBackdrop-drawn border further below instead (see
	-- UpdateBackdropVisibility's own self.hasNativeBorder check, which
	-- skips turning that backdrop border opaque for THIS button so the two
	-- styles can never stack).
	self.hasNativeBorder = parent.config and parent.config.id and
		parent.config.id >= 1 and parent.config.id <= 5

	if self.hasNativeBorder then
		-- "OVERLAY", explicit sublevel -1 (below equipRing/glow's own
		-- default sublevel of 0) rather than relying on creation-order
		-- tie-breaking within the same layer/sublevel - Bar.lua's own
		-- CreateBarFromConfig comment (Issue C) already established that
		-- same-strata ties are NOT reliably broken by creation order on
		-- this client, and the same caution applies here. Still
		-- unconditionally above self.icon's own "ARTWORK" layer regardless
		-- of sublevel, since layer takes precedence over sublevel - this is
		-- what actually frames the icon instead of being hidden underneath
		-- it (see the icon-inset comment below for why a same-layered
		-- backdrop border couldn't do this).
		self.border = self:CreateTexture(nil, "OVERLAY")
		self.border:SetDrawLayer("OVERLAY", -1)
		self.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		-- Round 16: live-confirmed via the user's own
		-- `ActionButton1:GetNormalTexture():GetPoint(1)` check - real
		-- vanilla's own border art is centered with a y = -1 offset (1px
		-- down from exact center), not a bare 0,0 - replacing the earlier
		-- reasoned-but-unconfirmed default this round supersedes.
		self.border:SetPoint("CENTER", self, "CENTER", 0, -1)
	end

	-- Initialize from the parent bar's configured size. New bars can inherit
	-- a resized buttonSize from the previous bar, so using the global default
	-- here would make the buttons temporarily/default-sized until a later
	-- resize event corrects them.
	self:ApplySize((parent.config and parent.config.buttonSize) or BTV.BUTTON_SIZE)
	self:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	self:RegisterForDrag("LeftButton")
	self:EnableMouse(true)
	self:EnableMouseWheel(true)

	-- Icon inset: round 13 tried flush 0,0 for default bars (1-5) on the
	-- reasoning that real vanilla's own ActionButton1Icon is anchored flush
	-- to its button frame with zero offset. Live-tested and reverted (round
	-- 14, Issue 1): that reasoning addressed the wrong layer. self.icon is
	-- drawn on the "ARTWORK" layer, which always renders ABOVE this
	-- button's own SetBackdrop-drawn border (backdrop bg/edge textures are
	-- always the bottom-most thing a frame draws, beneath every
	-- CreateTexture-based layer including "BACKGROUND") - so a flush 0,0
	-- icon completely covers the border on every side, regardless of how
	-- big the border's own edgeSize is. The border was only ever visible
	-- at all because the icon used to be smaller than the button, leaving
	-- the backdrop's perimeter exposed in the margin - which is exactly
	-- what a uniform inset restores here. Native vanilla avoids this
	-- entirely by drawing its border as a SEPARATE, larger overlay texture
	-- (its CheckButton's own NormalTexture, layered above the icon) rather
	-- than a same-size backdrop layered below it - round 15 replicates this
	-- properly for default bars 1-5 (self.border above), using the live-
	-- confirmed real texture/size (Interface\Buttons\UI-Quickslot2, 66x66
	-- against a real ~36px button - BTV.BORDER_RATIO, Core.lua). The icon
	-- inset itself stays this same flat uniform 2px for every button
	-- regardless (default bars 1-5 AND true custom bars 6+, which have no
	-- native border texture to match and keep the plain SetBackdrop-drawn
	-- border instead) - that was never actually the wrong piece; only the
	-- (now separately solved) border-visibility problem was.
	local iconInset = 2

	self.icon = self:CreateTexture(nil, "ARTWORK")
	self.icon:SetPoint("TOPLEFT", self, "TOPLEFT", iconInset, -iconInset)
	self.icon:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -iconInset, iconInset)
	self.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- "Current action" glow. Real vanilla ActionButtonTemplate gets this
	-- for free via a CheckButton's built-in CheckedTexture, which we're
	-- replicating manually here (see the Init-level note above this
	-- block's original version for why). Confirmed from the actual
	-- 1.12.1 FrameXML XML template (not just the .lua) that the correct
	-- file for this specific glow is "Interface\Buttons\CheckButtonHilight"
	-- - NOT "UI-ActionButton-Border", which is a different, unrelated
	-- texture used only for the green "equipped item" ring (driven by
	-- IsEquippedAction, a separate feature we haven't built yet). That
	-- wrong file is what caused both earlier attempts to look wrong -
	-- the anchoring itself was already correct, confirmed via /btvglow.
	self.glow = self:CreateTexture(nil, "OVERLAY")
	self.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	self.glow:SetBlendMode("ADD")
	self.glow:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	self.glow:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
	self.glow:Hide()

	-- Edit-mode ("Configure Layout") overlay: a plain solid-color texture,
	-- light blue, shown only while BTVanillaDB.editMode is on. Uses the
	-- standard blank white texture asset (universally available, used by
	-- countless addons for solid-color overlays) tinted via vertex color
	-- rather than a dedicated art asset, since this is our own UI
	-- affordance, not a replication of anything Blizzard ships.
	-- Issue 1 (bug-fix batch): this used to be an "ARTWORK"-layer texture,
	-- which OVERLAY-layer textures (self.glow/self.equipRing, both created
	-- above) always draw above regardless of creation order or their own
	-- sublevel - a button with an active glow ring or equip-quality ring
	-- painted right over the edit tint, hiding it completely. Moved to
	-- "OVERLAY" itself, sublevel 7 (the maximum/highest sublevel within
	-- OVERLAY - a real vanilla texture layer concept, confirmed valid via
	-- the two-argument SetDrawLayer(layer, sublevel) form), so it reliably
	-- renders above both of those regardless of their own (default,
	-- untouched) sublevel - this only fixes editOverlay being hidden, it
	-- doesn't reorder glow vs. equipRing relative to each other.
	self.editOverlay = self:CreateTexture(nil, "OVERLAY")
	self.editOverlay:SetDrawLayer("OVERLAY", 7)
	self.editOverlay:SetTexture("Interface\\Buttons\\WHITE8X8")
	self.editOverlay:SetVertexColor(0.35, 0.65, 1.0, 0.45)
	self.editOverlay:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	self.editOverlay:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
	self.editOverlay:Hide()

	-- Vanilla 1.12's cooldown spiral is a Model frame using
	-- CooldownFrameTemplate (not a "Cooldown" widget type - that came
	-- later). Confirmed working via ButtonForge Classic's shipped source.
	self.cooldown = CreateFrame("Model", nil, self, "CooldownFrameTemplate")
	self.cooldown:ClearAllPoints()
	self.cooldown:SetPoint("TOPLEFT", self, "TOPLEFT", 2, -2)
	self.cooldown:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -2, 2)
	self.cooldown:SetFrameLevel(self:GetFrameLevel() + 1)

	-- Issue 1 (bug-fix batch v6): the backdrop TEMPLATE (texture/tile/edge
	-- settings) is set exactly once here and never touched again - only
	-- its color/border alpha are toggled afterward (UpdateBackdropVisibility
	-- below), so this stays cheap to flip back on/off with no
	-- SetBackdrop(nil)/re-SetBackdrop churn. Starts fully transparent
	-- (both fill and border) rather than the old permanent
	-- SetBackdropColor(0,0,0,0.75): that unconditional call is what used to
	-- make every Shown slot's backdrop visible regardless of content, which
	-- is exactly what let an empty custom-bar slot's border show through
	-- once the edit-mode grid-visibility fix started Show()ing it. Real
	-- on/off state is decided by UpdateBackdropVisibility, called from
	-- UpdateGridVisibility below so the two can never drift out of sync.
	self:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	self:SetBackdropColor(0, 0, 0, 0)
	self:SetBackdropBorderColor(0, 0, 0, 0)

	self.count = self:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	self.count:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -2, 2)

	-- Issue 5 (bug-fix batch): keybind hotkey text, top-right - same
	-- FontString-creation/anchoring convention as self.count above, just
	-- TOPRIGHT instead of BOTTOMRIGHT and vanilla's small numeric font
	-- (NumberFontNormalSmall - there's no other small-overlay-text font
	-- object already in use elsewhere in this file to prefer instead).
	self.hotkey = self:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	self.hotkey:SetPoint("TOPRIGHT", self, "TOPRIGHT", -2, -2)

	-- Capture the two font templates' real native (path, size, flags) ONCE,
	-- module-level - see hasCapturedFontDefaults' comment above. Must run
	-- after both FontStrings are created (GetFont() needs a real object to
	-- read from) and before the SetFont calls just below, which need
	-- BTV.NATIVE_HOTKEY_FONT/NATIVE_COUNT_FONT to already exist.
	if not hasCapturedFontDefaults then
		local hkPath, hkSize, hkFlags = self.hotkey:GetFont()
		local cntPath, cntSize, cntFlags = self.count:GetFont()

		BTV.NATIVE_HOTKEY_FONT = { path = hkPath, size = hkSize, flags = hkFlags }
		BTV.NATIVE_COUNT_FONT = { path = cntPath, size = cntSize, flags = cntFlags }

		-- Captured once alongside the font itself - "tint whole button on
		-- out of range" (Settings.lua General tab) needs to know the
		-- hotkey text's real default color to reset back to whenever a
		-- button leaves the out-of-range state, rather than hardcoding a
		-- guessed white (NumberFontNormalSmall's real default, confirmed
		-- via GetTextColor() rather than assumed).
		local hkR, hkG, hkB = self.hotkey:GetTextColor()
		BTV.NATIVE_HOTKEY_TEXT_COLOR = { r = hkR, g = hkG, b = hkB }

		hasCapturedFontDefaults = true
	end

	-- Apply the CURRENT saved size immediately at creation (not just the
	-- template's untouched native size) - BTVanillaDB.hotkeyFontSize/
	-- countFontSize stay nil until the user actually moves a slider
	-- (Core.lua's EnsureDB deliberately does not seed a numeric default,
	-- same idiom as stanceBarPosition), so nil falls back to the just-
	-- captured native size here.
	self.hotkey:SetFont(
		BTV.NATIVE_HOTKEY_FONT.path,
		(BTVanillaDB and BTVanillaDB.hotkeyFontSize) or BTV.NATIVE_HOTKEY_FONT.size,
		BTV.NATIVE_HOTKEY_FONT.flags
	)

	self.count:SetFont(
		BTV.NATIVE_COUNT_FONT.path,
		(BTVanillaDB and BTVanillaDB.countFontSize) or BTV.NATIVE_COUNT_FONT.size,
		BTV.NATIVE_COUNT_FONT.flags
	)

	self:SetScript("OnClick", BTVButtonMixin.OnClick)
	self:SetScript("OnReceiveDrag", BTVButtonMixin.OnReceiveDrag)
	self:SetScript("OnDragStart", BTVButtonMixin.OnDragStart)
	self:SetScript("OnDragStop", BTVButtonMixin.OnDragStop)
	self:SetScript("OnMouseWheel", BTVButtonMixin.OnMouseWheel)
	self:SetScript("OnEnter", BTVButtonMixin.OnEnter)
	self:SetScript("OnLeave", BTVButtonMixin.OnLeave)

	self:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	-- Issue 5 (bug-fix batch): drives the item stack-count text
	-- specifically - ACTIONBAR_SLOT_CHANGED alone only catches count
	-- changes that come from re-placing an action, not from the bag
	-- count itself changing (using/gaining/losing stacks of an already-
	-- placed consumable), which is exactly what real vanilla's own
	-- ActionButton_UpdateCount additionally reacts to BAG_UPDATE for.
	self:RegisterEvent("BAG_UPDATE")
	self:RegisterEvent("BAG_UPDATE_COOLDOWN")
	self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
	self:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
	self:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
	self:RegisterEvent("SPELL_UPDATE_USABLE")
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	-- Drives the equip-quality-ring specifically: fires whenever the
	-- player equips/unequips anything, matching real vanilla's own
	-- ActionButton_OnEvent handling for this exact case.
	self:RegisterEvent("UNIT_INVENTORY_CHANGED")
	-- Drives the checked/glow state specifically. ACTIONBAR_UPDATE_STATE is
	-- vanilla's own generic "re-check IsCurrentAction" event; CRAFT_SHOW/
	-- CLOSE and TRADE_SKILL_SHOW/CLOSE are needed on top of it because a
	-- profession window's "currently active" action isn't otherwise tied
	-- to any of the other events this button listens for (confirmed from
	-- real FrameXML - this is the exact set Blizzard's own button uses).
	self:RegisterEvent("ACTIONBAR_UPDATE_STATE")
	self:RegisterEvent("CRAFT_SHOW")
	self:RegisterEvent("CRAFT_CLOSE")
	self:RegisterEvent("TRADE_SKILL_SHOW")
	self:RegisterEvent("TRADE_SKILL_CLOSE")
	self:SetScript("OnEvent", BTVButtonMixin.OnEvent)

	self:Refresh()

	-- Range/usability can change without a dedicated event (e.g. walking
	-- toward/away from a target). C_Timer.NewTicker is confirmed real and
	-- DLL-native (doc section 5b) - preferred over a raw OnUpdate frame.
	-- Issue 3 (bug-fix batch): also self-heals ALWAYS_SHOW_MULTIBARS
	-- staleness on this same existing ticker (mirroring the same
	-- self-healing-ticker approach HoverBind.lua's tint-persistence fix
	-- already uses) - toggling that global while a custom bar's settings
	-- page is open doesn't retroactively show/hide its empty slots on its
	-- own, since nothing else re-evaluates UpdateGridVisibility when the
	-- global changes out from under an already-built button. One more
	-- cheap call on the existing per-button tick, not a second ticker.
	if C_Timer and C_Timer.NewTicker then
		local button = self
		self.rangeTicker = C_Timer.NewTicker(0.2, function()
			button:UpdateRange()
			button:UpdateGridVisibility()
		end)
	end
end

-- Resizes the button and everything anchored to it that isn't already
-- purely anchor-relative. icon/glow/editOverlay auto-track via their
-- TOPLEFT/BOTTOMRIGHT anchors (see Init) so they need no code here;
-- equipRing is single-point (CENTER) anchored, so it has no implied size
-- of its own and is recomputed explicitly here to the real vanilla 62/36
-- proportions (BTV.EQUIP_RING_RATIO in Core.lua). Called once from Init
-- (equipRing is created before this first call specifically so it
-- already exists here - see Init) and again any time the bar is rescaled
-- (Bar.lua SetBarButtonSize). The nil-check stays as a cheap defensive
-- guard, not because a real call path skips creating equipRing.
function BTVButtonMixin:ApplySize(size)
	self.buttonSize = size
	self:SetWidth(size)
	self:SetHeight(size)
	if self.equipRing then
		local ringSize = size * BTV.EQUIP_RING_RATIO
		self.equipRing:SetWidth(ringSize)
		self.equipRing:SetHeight(ringSize)
	end
	-- Round 15: self.border (default bars 1-5 only, see Init) is single-
	-- point (CENTER) anchored the same way equipRing is, so it needs the
	-- same explicit recompute here rather than tracking size implicitly.
	if self.border then
		local borderSize = size * BTV.BORDER_RATIO
		self.border:SetWidth(borderSize)
		self.border:SetHeight(borderSize)
	end
end

-- Shows or hides this pool slot without destroying it. Used when a bar's
-- buttonCount is smaller than the pool size (12 - see Core.lua's
-- MAX_BAR_BUTTONS) or, in a future phase, when a grid preset needs fewer
-- visible slots than the pool holds. The frame itself, its events, and
-- its script handlers all stay intact while hidden.
function BTVButtonMixin:SetSlotVisible(visible)
	self.slotVisible = visible and true or false
	self:UpdateGridVisibility()
end

-- Issue 4 (bug-fix batch): final on-screen Show/Hide state for a custom-
-- bar pool slot, combining slotVisible (grid-shape membership - is this
-- slot even part of the bar's current buttonCount, set by SetSlotVisible
-- above) with content/ALWAYS_SHOW_MULTIBARS (is there anything on it, or
-- does the user want empty slots shown anyway) - the two conditions are
-- ANDed together, neither replaces the other. Called both from
-- SetSlotVisible (grid-shape changes) and from Refresh (content changes,
-- driven by the existing ACTIONBAR_SLOT_CHANGED-etc. event path in
-- OnEvent below) so either kind of change re-evaluates final visibility
-- through this single shared place.
function BTVButtonMixin:UpdateGridVisibility()
	local hasContent = self:IsSlotFilled() and true or false

	-- Round 13: real vanilla's Main Bar (bar 1) never hides an empty
	-- button at all - all 12 slots stay permanently visible with their
	-- normal bordered look regardless of content or the "Always Show
	-- Action Bars" setting. ALWAYS_SHOW_MULTIBARS's own name is the tell -
	-- it (and the ACTIONBAR_SHOWGRID/HIDEGRID show-while-placing behavior)
	-- only ever governed the MULTI bars (2-5 in this addon's numbering),
	-- never the Main Bar - confirmed live by the user via a vanilla-only
	-- screenshot (this addon fully disabled): Main Bar shows no separate
	-- "empty slot highlight" state to toggle at all, because it's never
	-- hidden in the first place. cfg.dynamicMainBar (schema version 7,
	-- Core.lua) is the same flag already used elsewhere in this file to
	-- single out bar 1 specifically.
	local isMainBar = self.parentBar and self.parentBar.config and self.parentBar.config.dynamicMainBar

	-- Issues 3/4 (bug-fix batch): BTV.isShowingActionGrid (module-level,
	-- driven by ACTIONBAR_SHOWGRID/HIDEGRID above) makes an empty slot
	-- temporarily reappear while the player has something picked up to
	-- place, matching native default-bar behavior exactly - without it, a
	-- button emptied by dragging its content away (with
	-- ALWAYS_SHOW_MULTIBARS off) would vanish mid-drag instead of staying
	-- visible until the drag actually ends.
	--
	-- Issue 3 (bug-fix batch v5): BTV:IsEditMode() is ORed in too - an
	-- empty custom-bar slot is otherwise genuinely Hide()'n (a hidden frame
	-- receives no mouse events at all), which meant right-clicking empty
	-- space within a custom bar's blue edit-mode overlay area did nothing,
	-- unlike default bars whose bar-level overlay owns ALL mouse
	-- interaction across the whole bounding box uniformly regardless of
	-- individual slot content. Making every slot visible while in edit
	-- mode gives custom-bar right-click-for-settings the same
	-- whole-bar-area interactability default bars already have.
	if self.slotVisible and (isMainBar or hasContent or IsAlwaysShowMultibars() or BTV.isShowingActionGrid or BTV:IsEditMode()) then
		self:Show()
	else
		self:Hide()
	end

	-- Issue 1 (bug-fix batch v6): backdrop cosmetic visibility is a
	-- DELIBERATELY narrower condition than Show/Hide above - it must NOT
	-- include the BTV:IsEditMode() term, or every empty slot's black
	-- border would reappear the instant edit mode Show()s it purely so it
	-- can be right-clicked. Called from here (rather than duplicated at
	-- every one of this method's own call sites) so the two can never
	-- drift out of sync - anything that already calls UpdateGridVisibility
	-- gets the backdrop kept in step for free.
	self:UpdateBackdropVisibility()
end

-- Issue 1 (bug-fix batch v6): toggles ONLY the backdrop's color/border
-- alpha - never SetBackdrop(nil)/re-SetBackdrop, so the template set once
-- in Init is never touched again (cheap to flip, nothing to recreate).
-- The condition is UpdateGridVisibility's own formula minus the
-- BTV:IsEditMode() OR-term: default bars never show a generic backdrop
-- border on empty slots even while their edit-mode overlay makes them
-- interactable, so custom bars shouldn't either - only content (or the
-- show-empty-slots affordances that predate the edit-mode fix) should
-- reveal it.
function BTVButtonMixin:UpdateBackdropVisibility()
	local hasContent = self:IsSlotFilled() and true or false

	-- Round 13: same Main Bar exemption as UpdateGridVisibility above,
	-- applied to the backdrop specifically so an empty bar-1 slot's border
	-- stays permanently on (matching a filled slot's own border, which
	-- already always shows via hasContent) rather than toggling with
	-- ALWAYS_SHOW_MULTIBARS/isShowingActionGrid the way bars 2-5 correctly
	-- still do.
	local isMainBar = self.parentBar and self.parentBar.config and self.parentBar.config.dynamicMainBar

	if self.slotVisible and (isMainBar or hasContent or IsAlwaysShowMultibars() or BTV.isShowingActionGrid) then
		self:SetBackdropColor(0, 0, 0, 0.75)

		-- Round 15: default bars 1-5 now have their own native-accurate
		-- border texture (self.border, Init) layered above everything the
		-- backdrop draws - leaving the backdrop's own white border edge
		-- turned on here too would double-border those buttons, which is
		-- exactly what this addon's border texture was added to avoid.
		-- True custom bars (6+, self.hasNativeBorder false) are unaffected
		-- - unchanged from before. The dark background FILL above is left
		-- untouched for every button either way; only the border edge
		-- color is skipped here, a separate concern from the fill.
		if not self.hasNativeBorder then
			self:SetBackdropBorderColor(1, 1, 1, 1)
		end
	else
		self:SetBackdropColor(0, 0, 0, 0)
		self:SetBackdropBorderColor(0, 0, 0, 0)
	end
end

-- Re-points this already-existing button at a different action slot -
-- e.g. when a bar's slotStart changes (BTV:SetBarSlotStart). Unlike the
-- old destroy/recreate path, the frame itself never changes - only
-- BTV.customBindTargets' old/new slot indices (HoverBind.lua) need
-- updating to follow it, which this does below.
function BTVButtonMixin:Rebind(newActionSlot)
	local oldActionSlot = self.actionSlot

	-- Keep BTV.customBindTargets pointed at whichever button currently
	-- owns each free action slot - clear the old index first so a stale
	-- entry never briefly points at a button that no longer owns that
	-- slot (see HoverBind.lua). Guarded the same way Init is (see its
	-- comment): fixed-slot default-bar buttons (2-5) never touch this
	-- table at all (their slot is always < BTV.ACTION_SLOT_START), and
	-- bar 1's dynamic-slot buttons never do either (self.nativeBindingId
	-- is already set, regardless of what its slot number currently is -
	-- Rebind never changes it).
	if BTV.customBindTargets and oldActionSlot and oldActionSlot >= BTV.ACTION_SLOT_START and not self.nativeBindingId then
		BTV.customBindTargets[oldActionSlot - 72] = nil
	end

	self.actionSlot = newActionSlot

	if newActionSlot >= BTV.ACTION_SLOT_START and not self.nativeBindingId then
		BTV.customBindTargets = BTV.customBindTargets or {}
		BTV.customBindTargets[newActionSlot - 72] = self
	end

	self:Refresh()
end

function BTVButtonMixin:SetEditModeVisual(enabled)
	if enabled then
		self.editOverlay:Show()
	else
		self.editOverlay:Hide()
	end
end

-- Named IsSlotFilled rather than HasAction to avoid any reader confusion
-- with the global vanilla API function of the (near-)same name that this
-- method wraps.
function BTVButtonMixin:IsSlotFilled()
	return HasAction and HasAction(self.actionSlot)
end

function BTVButtonMixin:UpdateState()
	-- Same logic real vanilla ActionButton_UpdateState uses, just driving
	-- our own self.glow texture's visibility directly instead of going
	-- through SetChecked/a CheckButton's built-in mechanism.
	if (IsCurrentAction and IsCurrentAction(self.actionSlot)) or (IsAutoRepeatAction and IsAutoRepeatAction(self.actionSlot)) then
		self.glow:Show()
	else
		self.glow:Hide()
	end
end

function BTVButtonMixin:UpdateEquipRing()
	if not self.actionSlot or not IsEquippedAction or not IsEquippedAction(self.actionSlot) then
		self.equipRing:Hide()
		return
	end

	local r, g, b = BTV:GetActionItemQualityColor(self.actionSlot)
	if r then
		self.equipRing:SetVertexColor(r, g, b)
		self.equipRing:Show()
	else
		-- Equipped but we couldn't resolve a quality (e.g. GetItemInfo
		-- hasn't cached this item yet) - stay hidden rather than show a
		-- wrongly-colored ring. It'll appear next refresh once cached.
		self.equipRing:Hide()
	end
end

-- Issue 5 (bug-fix batch): item stack-count text, extracted out of
-- Refresh into its own method so both the content-change path (Refresh,
-- below) and the bag-count-change path (BAG_UPDATE, OnEvent below) can
-- call it without re-touching the icon/cooldown/range/etc.
--
-- Fix 3 (bug-fix batch): this used to blank ANY count <= 1 unconditionally,
-- which is NOT what real vanilla ActionButton_UpdateCount actually does -
-- a consumable/stackable action (e.g. a health potion with exactly 1
-- charge left) still shows "1" on a real default-bar button; only a
-- non-stacking action (a spell, which GetActionCount reports as 0/falsy
-- for anyway) is blanked. Root cause of the reported bug: the `count > 1`
-- condition threw away the legitimate "1" case for consumables outright,
-- regardless of what kind of action it was. IsConsumableAction/
-- IsStackableAction are real vanilla 1.12 globals (not part of any of the
-- 4 client mods, so not separately covered by the environment doc, but no
-- more in question than GetActionCount/HasAction/etc. themselves) -
-- existence-guarded the same defensive way every other native call in
-- this file already is.
function BTVButtonMixin:UpdateCount()
	if not self.count then
		return
	end

	if not GetActionCount or not self:IsSlotFilled() then
		self.count:SetText("")
		return
	end

	local count = GetActionCount(self.actionSlot)

	if count and count > 1 then
		self.count:SetText(tostring(count))
	elseif count and count == 1 and
		((IsConsumableAction and IsConsumableAction(self.actionSlot)) or
		 (IsStackableAction and IsStackableAction(self.actionSlot))) then
		self.count:SetText("1")
	else
		self.count:SetText("")
	end
end

-- Fix 2 (bug-fix batch): compact modifier abbreviation. Live testing showed
-- GetBindingText(key, "KEY_") does NOT abbreviate modifier prefixes on this
-- client (still renders "SHIFT-F"/"ALT-SHIFT-^" in full) - our original
-- assumption that it would was wrong, so this hand-rolls the same compact
-- form Blizzard's own action bars use instead of relying on that API's
-- output. GetBindingKey's raw format is hyphen-separated modifier tokens
-- followed by a base key (e.g. "ALT-SHIFT-F", "SHIFT-R", or a bare "F"
-- with no modifiers at all) - split on "-", map each known modifier token
-- to its lowercase single-letter form, leave the final (base key) token
-- untouched, and rejoin with "-".
local HOTKEY_MODIFIER_ABBREVIATIONS = {
	ALT = "a",
	SHIFT = "s",
	CTRL = "c",
}

local function CompactBindingKeyText(key)
	if not key then
		return ""
	end

	-- No string.gmatch on Lua 5.0 (doc's Lua 5.0 constraint section) -
	-- string.gfind is the 5.0-native equivalent, used here to walk each
	-- "-"-delimited token in turn.
	local tokens = {}
	local n = 0
	local token

	for token in string.gfind(key, "[^%-]+") do
		n = n + 1
		tokens[n] = token
	end

	if n == 0 then
		return key
	end

	local parts = {}
	local i

	for i = 1, n - 1 do
		parts[i] = HOTKEY_MODIFIER_ABBREVIATIONS[tokens[i]] or tokens[i]
	end

	parts[n] = tokens[n]

	return table.concat(parts, "-")
end

-- Issue 5 (bug-fix batch): keybind hotkey text. Custom-bar keybinds are
-- registered via the Bindings.xml/TRUSTYBARSBIND<n> mechanism (doc
-- section 5j), n = actionSlot - 72, so the same lookup HoverBind.lua's
-- IsCustomSlotBound already uses works here.
function BTVButtonMixin:UpdateHotkeyText()
	if not self.hotkey then
		return
	end

	local key

	-- Fixed-slot default-bar buttons (2-5, major architecture migration)
	-- show their real native binding name (e.g. MULTIACTIONBAR1BUTTON5),
	-- precomputed at Init/Rebind time - never the TRUSTYBARSBIND<n>
	-- lookup, which only applies to the free action-slot pool (73-120).
	if self.nativeBindingId then
		key = GetBindingKey(self.nativeBindingId)
	elseif self.actionSlot then
		key = GetBindingKey("TRUSTYBARSBIND" .. tostring(self.actionSlot - 72))
	end

	if not key then
		self.hotkey:SetText("")
	else
		self.hotkey:SetText(CompactBindingKeyText(key))
	end
end

function BTVButtonMixin:Refresh()
	if self:IsSlotFilled() then
		local texture = GetActionTexture(self.actionSlot)
		self.icon:SetTexture(texture)
	else
		self.icon:SetTexture(nil)
		self.equipRing:Hide()
	end

	self:UpdateCount()
	self:UpdateCooldown()
	self:UpdateRange()
	self:UpdateState()
	self:UpdateEquipRing()
	self:UpdateHotkeyText()

	-- Issue 4 (bug-fix batch): re-evaluate final Show/Hide state now that
	-- content may have changed - see UpdateGridVisibility's comment
	-- above. Replaces the old unconditional self:Show() this function
	-- used to do at the top of the IsSlotFilled() branch, which ignored
	-- slotVisible entirely.
	self:UpdateGridVisibility()
end

function BTVButtonMixin:UpdateCooldown()
	if not self.actionSlot or not GetActionCooldown or not CooldownFrame_SetTimer then
		return
	end
	local start, duration, enable = GetActionCooldown(self.actionSlot)
	CooldownFrame_SetTimer(self.cooldown, start or 0, duration or 0, enable or 0)
end

function BTVButtonMixin:UpdateRange()
	-- Hoverbind mode owns icon tinting outright while active (HoverBind.lua's
	-- ApplyHoverBindVisual/tint pass) - short-circuit here so range/usability
	-- tinting can't fight it. Normal tinting resumes as soon as hoverbind
	-- mode turns off, since events keep calling UpdateRange throughout.
	if BTV:IsHoverBindMode() then
		return
	end

	if not self:IsSlotFilled() then
		self.icon:SetVertexColor(1, 1, 1)
		self:ResetHotkeyRangeColor()
		return
	end

	local inRange = nil
	if IsActionInRange then
		inRange = IsActionInRange(self.actionSlot)
	end

	-- Defaults to "usable" (not "unusable") when IsUsableAction itself isn't
	-- present at all - a real vanilla global that's always expected to
	-- exist on this client (doc section 5c/6), but falling back to the old
	-- always-white behavior here rather than always-grey keeps this
	-- function's normal-case output unchanged in that hypothetical case,
	-- rather than a hard regression to permanently greyed-out icons.
	local usable, noMana = 1, nil
	if IsUsableAction then
		usable, noMana = IsUsableAction(self.actionSlot)
	end

	-- Feature (General tab's "Tint whole button on out of range"): real
	-- Blizzard action buttons only tint the HOTKEY TEXT red on out-of-range,
	-- never the whole icon - BTVanillaDB.tintWholeButtonOnRange lets users
	-- opt into that native-accurate behavior instead of this addon's own
	-- historical whole-icon tint (default true, preserving the original
	-- shipped behavior - see Core.lua's EnsureDB).
	local outOfRange = (inRange == 0)
	local tintWholeButton = BTVanillaDB == nil or BTVanillaDB.tintWholeButtonOnRange ~= false

	-- Fix 1 (bug-fix batch): matches real vanilla ActionButton_UpdateUsable's
	-- own priority chain exactly - out-of-range (red) wins outright when
	-- applicable; otherwise usable/not-enough-mana/unusable governs the
	-- tint. The previous version only ever produced the blue "not enough
	-- mana" tint and normal white - it never actually greyed out a
	-- genuinely-unusable action (wrong stance, 0-charge consumable, etc.),
	-- since its condition folded "not usable" and "no mana" into a single
	-- branch instead of a real if/elseif/else chain.
	if outOfRange and tintWholeButton then
		self.icon:SetVertexColor(1.0, 0.15, 0.15)
	elseif usable and usable ~= 0 then
		self.icon:SetVertexColor(1.0, 1.0, 1.0)
	elseif noMana and noMana ~= 0 then
		self.icon:SetVertexColor(0.35, 0.35, 1.0)
	else
		self.icon:SetVertexColor(0.4, 0.4, 0.4)
	end

	-- Hotkey-text-only tint mode: the icon above already tinted itself as
	-- if NOT out of range (usable/mana/grey), so only the hotkey text signals
	-- out-of-range here. Explicitly reset back to the captured native color
	-- in every other case (in-range, or whole-button mode already handled
	-- the red) so a stale red hotkey never lingers past its out-of-range
	-- window - this call is unconditional on every UpdateRange pass, not
	-- just gated inside the outOfRange branch.
	if outOfRange and not tintWholeButton then
		self.hotkey:SetTextColor(1, 0, 0)
	else
		self:ResetHotkeyRangeColor()
	end
end

-- Restores self.hotkey to its captured native default color (white on this
-- client's NumberFontNormalSmall template, confirmed via GetTextColor() at
-- Init time rather than hardcoded - see hasCapturedFontDefaults' capture
-- block above). Falls back to plain white only in the (never-expected)
-- case no button has captured it yet this session.
function BTVButtonMixin:ResetHotkeyRangeColor()
	local c = BTV.NATIVE_HOTKEY_TEXT_COLOR

	if c then
		self.hotkey:SetTextColor(c.r, c.g, c.b)
	else
		self.hotkey:SetTextColor(1, 1, 1)
	end
end

function BTVButtonMixin:PlaceCursor()
	if PlaceAction then
		PlaceAction(self.actionSlot)
		self:Refresh()
	end
end

-- Plain functions from here down: engine-invoked script handlers, using
-- the global `this` (see the file-level note above).

function BTVButtonMixin.OnEvent()
	if event == "ACTIONBAR_SLOT_CHANGED" then
		local changedSlot = arg1
		if not changedSlot or changedSlot == 0 or changedSlot == this.actionSlot then
			this:Refresh()
		end
	elseif event == "BAG_UPDATE" then
		this:UpdateCount()
	elseif event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" or event == "BAG_UPDATE_COOLDOWN" then
		this:UpdateCooldown()
	elseif event == "ACTIONBAR_UPDATE_USABLE" or event == "SPELL_UPDATE_USABLE" or event == "PLAYER_TARGET_CHANGED" then
		this:UpdateRange()
	elseif event == "ACTIONBAR_UPDATE_STATE" or event == "CRAFT_SHOW" or event == "CRAFT_CLOSE" or event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_CLOSE" then
		this:UpdateState()
	elseif event == "UNIT_INVENTORY_CHANGED" then
		if arg1 == "player" then
			this:UpdateEquipRing()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		this:Refresh()
	end
end

function BTVButtonMixin.OnClick()
	-- Edit-mode interaction (right-click-to-settings, bar drag) is now
	-- fully owned by Bar.lua's per-bar overlay (EnsureBarOverlay), which
	-- sits at HIGH strata - above this button's own MEDIUM strata - and is
	-- mouse-enabled for the entire duration of edit mode. Since that
	-- overlay spans the bar's whole cols x rows bounding box (which
	-- necessarily contains every button), it wins every hit-test here
	-- first; this handler can no longer fire at all while
	-- BTV:IsEditMode() is true, so the old edit-mode branch that used to
	-- live here has been removed as unreachable. arg1 is the mouse button
	-- that triggered OnClick ("LeftButton"/"RightButton") - confirmed real
	-- vanilla convention (a global, not a passed parameter), cross-checked
	-- against real vanilla-era addon source (Bongos_ActionBar) and
	-- WoWWiki's own documented RegisterForClicks example.
	if BTV:ButtonHasCursor() then
		this:PlaceCursor()
	elseif this:IsSlotFilled() and UseAction then
		UseAction(this.actionSlot, 0, 0)
		-- Matches real ActionButtonUp: update the checked/glow state
		-- immediately rather than waiting on ACTIONBAR_UPDATE_STATE to
		-- round-trip, so the glow appears the instant you click.
		this:UpdateState()
	end
end

-- Edit-mode guards that used to live in this file's OnReceiveDrag/
-- OnDragStart/OnDragStop were removed in the overlay-consolidation pass:
-- Bar.lua's per-bar overlay (EnsureBarOverlay) now sits at HIGH strata -
-- above every button's own MEDIUM strata - and is mouse-enabled for the
-- entire BTV:IsEditMode() window, spanning the bar's whole cols x rows
-- bounding box (which necessarily contains every button). That overlay
-- therefore wins every hit-test at any position within the bar during
-- edit mode, so none of these handlers can fire at all while editing -
-- the drag-to-move-bar and right-click-to-settings behavior they used to
-- special-case here is now handled exclusively by the overlay's own
-- OnDragStart/OnDragStop/OnMouseUp scripts.
function BTVButtonMixin.OnReceiveDrag()
	this:PlaceCursor()
end

function BTVButtonMixin.OnDragStart()
	-- Lock Action Bars (see Core.lua) gates whether dragging a filled
	-- button picks up its action. Backed by the real Blizzard global
	-- LOCK_ACTIONBAR (confirmed live, not a CVar - see Core.lua), so
	-- this automatically matches the native default-bar lock behavior.
	if BTV:IsLockActionBars() then
		return
	end

	if this:IsSlotFilled() and PickupAction then
		PickupAction(this.actionSlot)
		this:Refresh()
	end
end

function BTVButtonMixin.OnDragStop()
end

function BTVButtonMixin.OnMouseWheel()
	if not BTV:IsEditMode() then
		return
	end
	-- arg1 is the scroll delta: positive = scroll up/away (zoom in),
	-- negative = scroll down/toward (zoom out) - standard vanilla
	-- OnMouseWheel convention, used the same way for camera zoom, chat
	-- scroll, etc. since the earliest WoW versions.
	local delta = arg1 or 0
	local bar = this.parentBar
	if not bar or not bar.config then
		return
	end

	-- Bug-fix batch Fix 4 (extended to bar 1 by the Main Bar migration):
	-- every default bar (1-5, all migrated onto this same button-pool
	-- engine) must keep respecting useDefaultLayout's lock on resizing -
	-- mirrors Bar.lua's ApplyEditModeVisual gating the drag-owning bar
	-- overlay the same way for these same bar ids. True custom bars (6+)
	-- have no such native-layout concept and are never gated here.
	local barId = bar.config.id

	if barId and barId >= 1 and barId <= 5 and
		BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
		return
	end

	local step = 2
	local newSize = bar.config.buttonSize + (delta * step)
	BTV:SetBarButtonSize(bar, newSize)
end

function BTVButtonMixin.OnEnter()
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	if this:IsSlotFilled() and GameTooltip.SetAction then
		GameTooltip:SetAction(this.actionSlot)
	else
		GameTooltip:SetText("BTVanilla")
		GameTooltip:AddLine("Drag a spell, item, or macro here.", 1, 1, 1)
	end
	GameTooltip:Show()

	-- Hoverbind (HoverBind.lua): only touches the capture frame while
	-- hoverbind mode is actually on, so this is a no-op the rest of the
	-- time - existing OnEnter behavior above is otherwise untouched.
	if BTV:IsHoverBindMode() and BTV.SetHoverBindHoveredCustomButton then
		BTV:SetHoverBindHoveredCustomButton(this)
	end
end

function BTVButtonMixin.OnLeave()
	GameTooltip:Hide()

	if BTV:IsHoverBindMode() and BTV.ClearHoverBindHoveredButton then
		BTV:ClearHoverBindHoveredButton(this)
	end
end

function BTV:ButtonHasCursor()
	if GetCursorInfo then
		local cursorType = GetCursorInfo()
		if cursorType == "spell" or cursorType == "item" or cursorType == "macro" then
			return true
		end
	end
	if CursorHasSpell and CursorHasSpell() then
		return true
	end
	if CursorHasItem and CursorHasItem() then
		return true
	end
	if CursorHasMacro and CursorHasMacro() then
		return true
	end
	return false
end

function BTV:CreateActionButton(parent, actionSlot, slotIndex)
	-- Frame names are stable for the bar's entire lifetime: one button
	-- object per pool slot, created exactly once (see CreateBarFromConfig).
	-- There is deliberately no generation counter baked in here anymore -
	-- a bumped generation used to orphan any SetBindingClick pointed at a
	-- specific frame name the instant a bar was resized/relayouted (see
	-- Bar.lua's ApplyBarShape, which now reuses this same frame instead of
	-- destroying and recreating it).
	local frameName =
		"BTVanillaButton" ..
		tostring(parent.config.id) ..
		"_" ..
		tostring(slotIndex or 1)

	local button = CreateFrame(
		"Button",
		frameName,
		parent
	)

	if Mixin then
		Mixin(button, BTVButtonMixin)
	else
		for k, v in pairs(BTVButtonMixin) do
			button[k] = v
		end
	end

	button:Init(parent, actionSlot, slotIndex)

	return button
end

-------------------------------------------------------------------------
-- Global hotkey/count font size (Settings.lua's General tab)
--
-- Sweeps every live button in BTV.bars - covers true custom bars (id 6+)
-- and every default bar (1-5), all of which are real Bar.lua bar objects
-- post-migration and therefore live in this same table (see Core.lua's
-- SCHEMA_VERSION 5/7 comments / HoverBind.lua's matching note).
-------------------------------------------------------------------------

function BTV:SetHotkeyFontSize(size)
	self:EnsureDB()

	-- Fix 2 (bug-fix batch): callers can pass a captured-native or
	-- otherwise not-guaranteed-integer size (e.g. the Reset button's
	-- BTV.NATIVE_HOTKEY_FONT.size, which GetFont() can itself hand back
	-- with float imprecision like 11.999999726451 on this client) - round
	-- once here, at the single point every apply path funnels through,
	-- rather than trusting each caller to have already rounded. Matches
	-- the same math.floor(value + 0.5) idiom already used by the Button
	-- Size/Spacing sliders' own OnValueChanged handlers.
	size = math.floor(size + 0.5)

	BTVanillaDB.hotkeyFontSize = size

	-- Nothing captured yet (no button created this session) - the write
	-- above is enough, the next button Init will pick it up directly.
	if not BTV.NATIVE_HOTKEY_FONT then
		return
	end

	local path = BTV.NATIVE_HOTKEY_FONT.path
	local flags = BTV.NATIVE_HOTKEY_FONT.flags
	local barId
	local bar

	for barId, bar in pairs(BTV.bars) do
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn and btn.hotkey then
					btn.hotkey:SetFont(path, size, flags)
				end
			end
		end
	end
end

function BTV:SetCountFontSize(size)
	self:EnsureDB()

	-- Fix 2 (bug-fix batch): see SetHotkeyFontSize's matching comment above.
	size = math.floor(size + 0.5)

	BTVanillaDB.countFontSize = size

	if not BTV.NATIVE_COUNT_FONT then
		return
	end

	local path = BTV.NATIVE_COUNT_FONT.path
	local flags = BTV.NATIVE_COUNT_FONT.flags
	local barId
	local bar

	for barId, bar in pairs(BTV.bars) do
		if bar and bar.buttons then
			local i

			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]

				if btn and btn.count then
					btn.count:SetFont(path, size, flags)
				end
			end
		end
	end
end
