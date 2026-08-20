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

BTVButtonMixin = {}

function BTVButtonMixin:Init(parent, actionSlot)
	self.actionSlot = actionSlot
	self.parentBar = parent

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

	-- Initialize from the parent bar's configured size. New bars can inherit
	-- a resized buttonSize from the previous bar, so using the global default
	-- here would make the buttons temporarily/default-sized until a later
	-- resize event corrects them.
	self:ApplySize((parent.config and parent.config.buttonSize) or BTV.BUTTON_SIZE)
	self:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	self:RegisterForDrag("LeftButton")
	self:EnableMouse(true)
	self:EnableMouseWheel(true)

	self.icon = self:CreateTexture(nil, "ARTWORK")
	self.icon:SetPoint("TOPLEFT", self, "TOPLEFT", 2, -2)
	self.icon:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -2, 2)
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
	self.editOverlay = self:CreateTexture(nil, "ARTWORK")
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

	self:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	self:SetBackdropColor(0, 0, 0, 0.75)

	self.count = self:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	self.count:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -2, 2)

	self:SetScript("OnClick", BTVButtonMixin.OnClick)
	self:SetScript("OnReceiveDrag", BTVButtonMixin.OnReceiveDrag)
	self:SetScript("OnDragStart", BTVButtonMixin.OnDragStart)
	self:SetScript("OnDragStop", BTVButtonMixin.OnDragStop)
	self:SetScript("OnMouseWheel", BTVButtonMixin.OnMouseWheel)
	self:SetScript("OnEnter", BTVButtonMixin.OnEnter)
	self:SetScript("OnLeave", BTVButtonMixin.OnLeave)

	self:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
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
	if C_Timer and C_Timer.NewTicker then
		local button = self
		self.rangeTicker = C_Timer.NewTicker(0.2, function() button:UpdateRange() end)
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

function BTVButtonMixin:Refresh()
	if self:IsSlotFilled() then
		self:Show()
		local texture = GetActionTexture(self.actionSlot)
		self.icon:SetTexture(texture)

		if GetActionCount then
			local count = GetActionCount(self.actionSlot)
			if count and count > 1 then
				self.count:SetText(tostring(count))
			else
				self.count:SetText("")
			end
		end
	else
		self.icon:SetTexture(nil)
		self.count:SetText("")
		self.equipRing:Hide()
	end

	self:UpdateCooldown()
	self:UpdateRange()
	self:UpdateState()
	self:UpdateEquipRing()
end

function BTVButtonMixin:UpdateCooldown()
	if not self.actionSlot or not GetActionCooldown or not CooldownFrame_SetTimer then
		return
	end
	local start, duration, enable = GetActionCooldown(self.actionSlot)
	CooldownFrame_SetTimer(self.cooldown, start or 0, duration or 0, enable or 0)
end

function BTVButtonMixin:UpdateRange()
	if not self:IsSlotFilled() then
		self.icon:SetVertexColor(1, 1, 1)
		return
	end

	local inRange = nil
	if IsActionInRange then
		inRange = IsActionInRange(self.actionSlot)
	end

	local usable, noMana = nil, nil
	if IsUsableAction then
		usable, noMana = IsUsableAction(self.actionSlot)
	end

	if inRange == 0 then
		self.icon:SetVertexColor(1.0, 0.15, 0.15)
	elseif (usable == nil or usable == 0) and noMana == 1 then
		self.icon:SetVertexColor(0.35, 0.35, 1.0)
	else
		self.icon:SetVertexColor(1.0, 1.0, 1.0)
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
	-- Edit mode: right-click opens this button's bar settings page instead
	-- of casting. arg1 is the mouse button that triggered OnClick
	-- ("LeftButton"/"RightButton") - confirmed real vanilla convention
	-- (a global, not a passed parameter), cross-checked against real
	-- vanilla-era addon source (Bongos_ActionBar) and WoWWiki's own
	-- documented RegisterForClicks example.
	if BTV:IsEditMode() then
		if arg1 == "RightButton" then
			BTV:OpenBarSettings(this.parentBar)
		end
		return
	end

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

function BTVButtonMixin.OnReceiveDrag()
	if BTV:IsEditMode() then
		return
	end
	this:PlaceCursor()
end

function BTVButtonMixin.OnDragStart()
	if BTV:IsEditMode() then
		-- Edit mode overrides normal pickup-action dragging entirely:
		-- dragging any button moves its whole bar.
		BTV:StartBarDrag(this.parentBar)
		return
	end

	-- Lock Action Bars (see Core.lua) gates whether dragging a filled
	-- button picks up its action, matching what the real Blizzard
	-- setting is understood to do (prevent accidental reassignment) -
	-- see Core.lua's honesty note on this specific CVar's uncertain
	-- status in true vanilla 1.12.
	if BTV:IsLockActionBars() then
		return
	end

	if this:IsSlotFilled() and PickupAction then
		PickupAction(this.actionSlot)
		this:Refresh()
	end
end

function BTVButtonMixin.OnDragStop()
	if BTV:IsEditMode() then
		BTV:StopBarDrag(this.parentBar)
	end
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
end

function BTVButtonMixin.OnLeave()
	GameTooltip:Hide()
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

function BTV:CreateActionButton(parent, actionSlot, index)
	-- Button names must be globally unique, including after a bar is
	-- rebuilt because of a settings change.
	--
	-- Example:
	--   Bar 2 generation 1 -> BTVanillaButton2_1_1
	--   Bar 2 generation 2 -> BTVanillaButton2_2_1
	--
	-- This prevents CreateFrame() name collisions when changing
	-- rows/columns/slotStart from the settings UI.

	local generation = parent.buttonGeneration or 1

	local frameName =
		"BTVanillaButton" ..
		tostring(parent.config.id) ..
		"_" ..
		tostring(generation) ..
		"_" ..
		tostring(index or 1)

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

	button:Init(parent, actionSlot)

	return button
end
