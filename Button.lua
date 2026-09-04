-- Button.lua
-- Single action-slot-backed button. Plain, non-secure frame backed by a
-- real vanilla action slot, driven through native
-- UseAction/PlaceAction/PickupAction/HasAction.
--
-- Engine-invoked script handlers (OnClick, OnEvent, OnEnter, OnLeave,
-- OnDragStart, OnReceiveDrag) receive the frame via the global `this`, not
-- a `self` parameter. Methods called explicitly with `:` receive `self`.
-- Every handler below is a plain function using `this`; every method
-- called directly uses `:`.

local BTV = BTVanilla

-- Gets the quality color for an action slot holding an equipped item.
-- Matches the action slot's texture against each inventory slot's texture
-- to find which equipment slot the item is in, then reads its quality.
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
	-- Lowercases both sides since texture path casing varies by call site.
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

-- ALWAYS_SHOW_MULTIBARS is the plain global Lua variable Blizzard's own
-- "Always Show Action Bars" checkbox reads/writes (string "1" when
-- checked, not a CVar). Real vanilla FrameXML checks both the string and
-- numeric form, so this reproduces the same dual check for custom bars.
local function IsAlwaysShowMultibars()
	return ALWAYS_SHOW_MULTIBARS == "1" or ALWAYS_SHOW_MULTIBARS == 1
end

-- Exposed as a BTV: method too so Menu.lua's minimap-dropdown toggle can
-- read the same check.
BTV.IsAlwaysShowMultibars = IsAlwaysShowMultibars

-- Real vanilla fires ACTIONBAR_SHOWGRID/ACTIONBAR_HIDEGRID whenever the
-- player picks up/releases a spell, item, or macro, making empty native
-- action buttons temporarily reappear while dragging. This flag mirrors
-- that state for custom-bar buttons, which never registered for those
-- events individually.
BTV.isShowingActionGrid = false

-- Re-evaluates UpdateGridVisibility on every live custom-bar button.
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

-- Re-sweeps every live button's UpdateRange, covering every bar in
-- BTV.bars (custom bars id 6+ and default bars 1-5 alike).
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

-- Menu.lua's minimap-dropdown entry. Toggles the plain global and forces
-- an immediate visual refresh on both default and custom bars.
function BTV:ToggleAlwaysShowMultibars()
	local newState = not IsAlwaysShowMultibars()

	ALWAYS_SHOW_MULTIBARS = newState and "1" or nil

	-- Default bars: drives MultiActionBarButton grid visibility.
	if MultiActionBar_UpdateGridVisibility then
		MultiActionBar_UpdateGridVisibility()
	end

	-- Custom bars: no native equivalent, sweep them directly.
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

-- Global hotkey/count text font size (Settings.lua's General tab): the
-- native default (path/size/flags) is captured once, module-level, the
-- first time any button is created each session, via GetFont() on a real
-- FontString rather than hardcoded.
local hasCapturedFontDefaults = false

function BTVButtonMixin:Init(parent, actionSlot, slotIndex)
	self.actionSlot = actionSlot
	self.parentBar = parent
	self.slotIndex = slotIndex

	-- Sets frame strata explicitly rather than relying on inheriting it
	-- from the parent bar frame, which is unconfirmed on this client.
	self:SetFrameStrata("HIGH")

	-- Default bars (1-5) are already dispatched by a real native keybind
	-- action name, so their hotkey text shows that name directly instead
	-- of going through the custom-bar TRUSTYBARSBIND<n> dispatch table.
	-- Bar 1's dynamic slot can land inside the 73-120 pool range while
	-- stance-swapped onto page 7-9, so self.nativeBindingId is also used
	-- below to keep it out of that table.
	if parent.config and (parent.config.fixedActionSlots or parent.config.dynamicMainBar) and slotIndex then
		local prefix = BTV.DEFAULT_BAR_BINDING_PREFIXES and
			BTV.DEFAULT_BAR_BINDING_PREFIXES[parent.config.id]

		if prefix then
			self.nativeBindingId = prefix .. tostring(slotIndex)
		end
	end

	-- Registers this button as the live target for HoverBind.lua's
	-- bindings.xml-driven TRUSTYBARSBIND<n> dispatch (n = actionSlot - 72,
	-- range 1-48), keyed by action slot. Guarded on self.nativeBindingId
	-- so a bar-1 button stance-swapped onto a slot >= 73 is never
	-- registered here, since it already dispatches via its own native
	-- binding name.
	if actionSlot >= BTV.ACTION_SLOT_START and not self.nativeBindingId then
		BTV.customBindTargets = BTV.customBindTargets or {}
		BTV.customBindTargets[actionSlot - 72] = self
	end

	-- Equipped-item ring, quality-colored. CENTER-only anchor has no
	-- implied size, so it relies on ApplySize's SetWidth/SetHeight below
	-- for sizing — must be created before the ApplySize call runs below,
	-- or the ring stays unsized (invisible) until the bar next resizes.
	self.equipRing = self:CreateTexture(nil, "OVERLAY")
	self.equipRing:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	self.equipRing:SetBlendMode("ADD")
	self.equipRing:SetPoint("CENTER", self, "CENTER", 0, 0)
	self.equipRing:Hide()

	-- Native-accurate button border, default bars 1-5 only. Custom bars
	-- (id 6+) have no native chrome to replicate and keep the
	-- SetBackdrop-drawn border further below instead.
	self.hasNativeBorder = BTV:IsVanillaBorderStyle()

	if self.hasNativeBorder then
		-- Explicit sublevel -1, still above self.icon's own "ARTWORK"
		-- layer, so the border always frames the icon.
		self.border = self:CreateTexture(nil, "OVERLAY")
		self.border:SetDrawLayer("OVERLAY", -1)
		self.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		-- Real vanilla border art is centered with a y = -1 offset.
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

	-- Modern-style buttons (self.hasNativeBorder false) inset the icon so
	-- the SetBackdrop-drawn border (bottom-most layer) stays visible under
	-- the "ARTWORK"-layer icon. Vanilla-style buttons use a separate
	-- overlay border texture instead, so their icon stays flush (0 inset),
	-- matching real vanilla's own ActionButton1Icon.
	local iconInset = self.hasNativeBorder and 0 or 2

	self.icon = self:CreateTexture(nil, "ARTWORK")
	self.icon:SetPoint("TOPLEFT", self, "TOPLEFT", iconInset, -iconInset)
	self.icon:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -iconInset, iconInset)
	self.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- "Current action" glow, replicating the CheckedTexture a real
	-- CheckButton-based ActionButtonTemplate gets for free.
	self.glow = self:CreateTexture(nil, "OVERLAY")
	self.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	self.glow:SetBlendMode("ADD")
	self.glow:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	self.glow:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
	self.glow:Hide()

	-- Vanilla 1.12's cooldown spiral is a Model frame using
	-- CooldownFrameTemplate, not a "Cooldown" widget type.
	self.cooldown = CreateFrame("Model", nil, self, "CooldownFrameTemplate")
	self.cooldown:ClearAllPoints()
	self.cooldown:SetPoint("TOPLEFT", self, "TOPLEFT", 2, -2)
	self.cooldown:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -2, 2)

	-- Must match this button's own "HIGH" strata explicitly, or the
	-- cooldown swipe defaults to "MEDIUM" and renders behind the icon/border.
	self.cooldown:SetFrameStrata("HIGH")
	self.cooldown:SetFrameLevel(self:GetFrameLevel() + 1)

	-- Backdrop template (texture/tile/edge) is set once here; only its
	-- color/border alpha are toggled afterward, by UpdateBackdropVisibility.
	-- Starts fully transparent; real on/off state is decided there.
	local backdropInset = self.hasNativeBorder and 0 or 1

	self:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = backdropInset, right = backdropInset, top = backdropInset, bottom = backdropInset },
	})
	self:SetBackdropColor(0, 0, 0, 0)
	self:SetBackdropBorderColor(0, 0, 0, 0)

	self.count = self:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	self.count:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -2, 2)

	-- Keybind hotkey text, top-right.
	self.hotkey = self:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	self.hotkey:SetPoint("TOPRIGHT", self, "TOPRIGHT", -2, -2)

	-- Captures both font templates' native (path, size, flags) once.
	-- Must run after both FontStrings are created and before the SetFont
	-- calls below, which need BTV.NATIVE_HOTKEY_FONT/NATIVE_COUNT_FONT.
	if not hasCapturedFontDefaults then
		local hkPath, hkSize, hkFlags = self.hotkey:GetFont()
		local cntPath, cntSize, cntFlags = self.count:GetFont()

		BTV.NATIVE_HOTKEY_FONT = { path = hkPath, size = hkSize, flags = hkFlags }
		BTV.NATIVE_COUNT_FONT = { path = cntPath, size = cntSize, flags = cntFlags }

		-- Hotkey text's default color, used to reset the "tint whole
		-- button on out of range" state back to normal.
		local hkR, hkG, hkB = self.hotkey:GetTextColor()
		BTV.NATIVE_HOTKEY_TEXT_COLOR = { r = hkR, g = hkG, b = hkB }

		hasCapturedFontDefaults = true
	end

	-- Applies the current saved font size, falling back to the captured
	-- native size when BTVanillaDB.hotkeyFontSize/countFontSize is nil.
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
	-- Drives the item stack-count text when bag count changes without a
	-- slot being re-placed (using/gaining/losing stacks of a consumable).
	self:RegisterEvent("BAG_UPDATE")
	self:RegisterEvent("BAG_UPDATE_COOLDOWN")
	self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
	self:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
	self:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
	self:RegisterEvent("SPELL_UPDATE_USABLE")
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	-- Drives the equip-quality-ring, fires on equip/unequip.
	self:RegisterEvent("UNIT_INVENTORY_CHANGED")
	-- Drives the checked/glow state. CRAFT_SHOW/CLOSE and
	-- TRADE_SKILL_SHOW/CLOSE cover a profession window's "currently
	-- active" action, which ACTIONBAR_UPDATE_STATE alone doesn't catch.
	self:RegisterEvent("ACTIONBAR_UPDATE_STATE")
	self:RegisterEvent("CRAFT_SHOW")
	self:RegisterEvent("CRAFT_CLOSE")
	self:RegisterEvent("TRADE_SKILL_SHOW")
	self:RegisterEvent("TRADE_SKILL_CLOSE")
	self:SetScript("OnEvent", BTVButtonMixin.OnEvent)

	self:Refresh()

	-- Range/usability can change without a dedicated event (e.g. walking
	-- toward/away from a target); also self-heals grid visibility if
	-- ALWAYS_SHOW_MULTIBARS changes while a bar's settings page is open.
	if C_Timer and C_Timer.NewTicker then
		local button = self
		self.rangeTicker = C_Timer.NewTicker(0.2, function()
			button:UpdateRange()
			button:UpdateGridVisibility()
		end)
	end
end

-- Resizes the button and everything anchored to it that isn't already
-- purely anchor-relative. icon/glow auto-track via their TOPLEFT/
-- BOTTOMRIGHT anchors; equipRing and border are CENTER-anchored with no
-- implied size, so their size is recomputed explicitly here.
function BTVButtonMixin:ApplySize(size)
	self.buttonSize = size
	self:SetWidth(size)
	self:SetHeight(size)
	if self.equipRing then
		local ringSize = size * BTV.EQUIP_RING_RATIO
		self.equipRing:SetWidth(ringSize)
		self.equipRing:SetHeight(ringSize)
	end
	if self.border then
		local borderSize = size * BTV.BORDER_RATIO
		self.border:SetWidth(borderSize)
		self.border:SetHeight(borderSize)
	end

end

-- Re-applies the current global border style to an already-created button
-- without recreating the frame. Must stay in lockstep with every
-- self.hasNativeBorder-gated block in Init.
function BTVButtonMixin:ApplyBorderStyle()
	self.hasNativeBorder = BTV:IsVanillaBorderStyle()

	if self.hasNativeBorder then
		if not self.border then
			self.border = self:CreateTexture(nil, "OVERLAY")
			self.border:SetDrawLayer("OVERLAY", -1)
			self.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
			self.border:SetPoint("CENTER", self, "CENTER", 0, -1)
		end

		self.border:Show()
	elseif self.border then
		self.border:Hide()
	end

	-- Reuses ApplySize's own border-sizing math.
	self:ApplySize(self.buttonSize or BTV.BUTTON_SIZE)

	local iconInset = self.hasNativeBorder and 0 or 2
	self.icon:ClearAllPoints()
	self.icon:SetPoint("TOPLEFT", self, "TOPLEFT", iconInset, -iconInset)
	self.icon:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -iconInset, iconInset)

	local backdropInset = self.hasNativeBorder and 0 or 1
	self:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = backdropInset, right = backdropInset, top = backdropInset, bottom = backdropInset },
	})

	-- Resets to transparent; real on/off state is decided by
	-- UpdateBackdropVisibility below.
	self:SetBackdropColor(0, 0, 0, 0)
	self:SetBackdropBorderColor(0, 0, 0, 0)

	self:UpdateBackdropVisibility()
end

-- Shows or hides this pool slot without destroying it, used when a bar's
-- buttonCount is smaller than the pool size. The frame, its events, and
-- its script handlers stay intact while hidden.
function BTVButtonMixin:SetSlotVisible(visible)
	self.slotVisible = visible and true or false
	self:UpdateGridVisibility()
end

-- Final on-screen Show/Hide state for a custom-bar pool slot, combining
-- slotVisible (grid-shape membership) with content/ALWAYS_SHOW_MULTIBARS
-- (whether anything is on the slot, or the user wants empty slots shown
-- anyway). Called from both SetSlotVisible and Refresh so either kind of
-- change re-evaluates visibility through this one place.
function BTVButtonMixin:UpdateGridVisibility()
	local hasContent = self:IsSlotFilled() and true or false

	-- Real vanilla's Main Bar (bar 1) never hides an empty button; all 12
	-- slots stay permanently visible regardless of content or
	-- ALWAYS_SHOW_MULTIBARS, which only ever governs the multi bars (2-5).
	local isMainBar = self.parentBar and self.parentBar.config and self.parentBar.config.dynamicMainBar

	-- BTV.isShowingActionGrid makes an empty slot temporarily reappear
	-- while something is picked up to place, matching native behavior.
	-- BTV:IsEditMode() is ORed in too so every slot is interactable
	-- (right-click-for-settings) while in edit mode, matching how default
	-- bars' overlay owns mouse interaction across the whole bar area.
	if self.slotVisible and (isMainBar or hasContent or IsAlwaysShowMultibars() or BTV.isShowingActionGrid or BTV:IsEditMode()) then
		self:Show()
	else
		self:Hide()
	end

	-- Backdrop visibility is a deliberately narrower condition than
	-- Show/Hide above - it must NOT include the BTV:IsEditMode() term, or
	-- every empty slot's border would reappear purely because edit mode
	-- Show()s it for interactability.
	self:UpdateBackdropVisibility()
end

-- Toggles only the backdrop's color/border alpha; the template set once
-- in Init is never touched again. Condition matches UpdateGridVisibility
-- minus the BTV:IsEditMode() OR-term, so an empty slot's backdrop border
-- never appears purely because edit mode made the slot interactable.
function BTVButtonMixin:UpdateBackdropVisibility()
	local hasContent = self:IsSlotFilled() and true or false

	-- Same Main Bar exemption as UpdateGridVisibility: an empty bar-1
	-- slot's border stays permanently on.
	local isMainBar = self.parentBar and self.parentBar.config and self.parentBar.config.dynamicMainBar

	if self.slotVisible and (isMainBar or hasContent or IsAlwaysShowMultibars() or BTV.isShowingActionGrid) then
		self:SetBackdropColor(0, 0, 0, 0.75)

		-- Vanilla-style buttons have their own border texture (self.border)
		-- layered above the backdrop, so the backdrop's own border edge is
		-- skipped here to avoid a double border. The background fill stays
		-- on for every button either way.
		if not self.hasNativeBorder then
			self:SetBackdropBorderColor(1, 1, 1, 1)
		end
	else
		self:SetBackdropColor(0, 0, 0, 0)
		self:SetBackdropBorderColor(0, 0, 0, 0)
	end
end

-- Re-points this already-existing button at a different action slot,
-- called from Bar.lua's ApplyBarShape whenever a bar's slotStart, grid
-- shape, or page/stance state changes which native slot a pool slot
-- should show. The frame itself never changes; only
-- BTV.customBindTargets' old/new slot indices need updating to follow it.
function BTVButtonMixin:Rebind(newActionSlot)
	local oldActionSlot = self.actionSlot

	-- Clears the old index first so a stale entry never briefly points at
	-- a button that no longer owns that slot. Guarded the same way Init
	-- is: fixed-slot default-bar buttons and bar 1's dynamic-slot buttons
	-- (self.nativeBindingId set) never touch this table.
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

-- Item stack-count text. A consumable/stackable action with exactly 1
-- charge still shows "1", matching real vanilla ActionButton_UpdateCount;
-- a non-stacking action (a spell) stays blank.
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

-- Compact modifier abbreviation for hotkey text. GetBindingKey's raw
-- format is hyphen-separated modifier tokens followed by a base key (e.g.
-- "ALT-SHIFT-F", "SHIFT-R", or a bare "F"). Splits on "-", maps each
-- modifier token to a lowercase single letter, leaves the base key token
-- alone, and rejoins with "-".
local HOTKEY_MODIFIER_ABBREVIATIONS = {
	ALT = "a",
	SHIFT = "s",
	CTRL = "c",
}

-- Mouse-button bindings use the literal prefix "BUTTON" followed by
-- digits (e.g. "BUTTON5"), wide enough to overflow the button's border
-- when shown verbatim, so it's compacted to "MB<n>". Any other final
-- token passes through unchanged.
local function CompactFinalKeyToken(finalToken)
	local _, _, mouseButtonNumber = string.find(finalToken, "^BUTTON(%d+)$")

	if mouseButtonNumber then
		return "MB" .. mouseButtonNumber
	end

	return finalToken
end

local function CompactBindingKeyText(key)
	if not key then
		return ""
	end

	-- Lua 5.0 has no string.gmatch; string.gfind is the 5.0 equivalent.
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

	parts[n] = CompactFinalKeyToken(tokens[n])

	return table.concat(parts, "-")
end

-- Keybind hotkey text. Custom-bar keybinds are registered via the
-- bindings.xml/TRUSTYBARSBIND<n> mechanism, n = actionSlot - 72.
function BTVButtonMixin:UpdateHotkeyText()
	if not self.hotkey then
		return
	end

	local key

	-- Fixed-slot default-bar buttons show their real native binding name
	-- (e.g. MULTIACTIONBAR1BUTTON5), precomputed at Init/Rebind time.
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

	-- Re-evaluates final Show/Hide state now that content may have changed.
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

	-- Defaults to "usable" when IsUsableAction isn't present, rather than
	-- permanently greying out every icon in that case.
	local usable, noMana = 1, nil
	if IsUsableAction then
		usable, noMana = IsUsableAction(self.actionSlot)
	end

	-- Real Blizzard action buttons only tint the hotkey text red on
	-- out-of-range, never the whole icon. BTVanillaDB.tintWholeButtonOnRange
	-- (default true) lets users opt into that native-accurate behavior.
	local outOfRange = (inRange == 0)
	local tintWholeButton = BTVanillaDB == nil or BTVanillaDB.tintWholeButtonOnRange ~= false

	-- Matches real vanilla ActionButton_UpdateUsable's priority chain:
	-- out-of-range wins outright when applicable, otherwise
	-- usable/not-enough-mana/unusable governs the tint.
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
	-- if not out of range, so only the hotkey text signals out-of-range
	-- here. Resets to the captured native color in every other case so a
	-- stale red hotkey never lingers.
	if outOfRange and not tintWholeButton then
		self.hotkey:SetTextColor(1, 0, 0)
	else
		self:ResetHotkeyRangeColor()
	end
end

-- Restores self.hotkey to its captured native default color. Falls back
-- to plain white if no button has captured it yet this session.
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
	-- Edit-mode interaction (right-click-to-settings, bar drag) is owned
	-- by Bar.lua's per-bar overlay, which sits at TOOLTIP strata above
	-- this button's own HIGH strata, so this handler never fires while
	-- editing.
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

-- None of the handlers below need an edit-mode guard: Bar.lua's per-bar
-- overlay wins every hit-test within the bar while BTV:IsEditMode() is
-- true, so drag-to-move-bar and right-click-to-settings are handled by
-- the overlay's own scripts instead.
function BTVButtonMixin.OnReceiveDrag()
	this:PlaceCursor()
end

function BTVButtonMixin.OnDragStart()
	-- Lock Action Bars gates whether dragging a filled button picks up its
	-- action, backed by the real Blizzard global LOCK_ACTIONBAR.
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
	-- arg1 is the scroll delta: positive = scroll up, negative = scroll down.
	local delta = arg1 or 0
	local bar = this.parentBar
	if not bar or not bar.config then
		return
	end

	-- Every default bar (1-5) respects useDefaultLayout's lock on
	-- resizing. Custom bars (6+) have no such native-layout concept and
	-- are never gated here.
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
	-- object per pool slot, created exactly once.
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
-- Sweeps every live button in BTV.bars, covering custom bars (id 6+) and
-- default bars (1-5) alike.
-------------------------------------------------------------------------

function BTV:SetHotkeyFontSize(size)
	self:EnsureDB()

	-- Rounds to an integer since GetFont() can return a float size.
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

	-- Rounds to an integer since GetFont() can return a float size.
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
