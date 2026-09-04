-- HoverBind.lua
-- Hoverbind mode: hover a button, press a key to bind it. Mutually
-- exclusive with edit mode (Core.lua's SetEditMode/SetHoverBindMode).
--
-- Default-bar buttons (bars 1-5) bind through native binding actions
-- (ACTIONBUTTON1-12, MULTIACTIONBAR#BUTTON1-12). Custom-bar slots (bars
-- 6+) bind through this addon's own bindings.xml-declared actions
-- (TRUSTYBARSBIND1-48, one per free action slot 73-120), each invoking
-- TrustyBars_HoverBindFire(N). Do not use SetBindingClick or
-- SetBinding(key, "BONUSACTIONBUTTON1") for custom slots - both record in
-- the binding system but the client's input dispatcher never fires them
-- on this client.

local BTV = BTVanilla

-- Custom-bar slot -> button lookup, keyed by actionSlot - 72 (1-48,
-- matching bindings.xml's TRUSTYBARSBIND1-48). Kept in sync by Button.lua
-- wherever a custom-bar button's actionSlot is set.
BTV.customBindTargets = {}

-- Must be a bare global function, not a BTV: method - bindings.xml's
-- TRUSTYBARSBIND1-48 bodies can only invoke a plain global function name.
function TrustyBars_HoverBindFire(slotIndex)
	local btn = BTV.customBindTargets and BTV.customBindTargets[slotIndex]
	if btn then
		btn:Click()
	end
end

-- Default-bar binding-action-name mapping: vanilla 1.12.1's own
-- Bindings.xml convention (MULTIACTIONBAR1BUTTON# for MultiBarBottomLeft,
-- MULTIACTIONBAR2BUTTON# for MultiBarBottomRight, MULTIACTIONBAR3BUTTON#
-- for MultiBarRight, MULTIACTIONBAR4BUTTON# for MultiBarLeft). Mirrors
-- DefaultBars.lua's DEFAULT_BAR_FRAME_PREFIXES.
BTV.DEFAULT_BAR_BINDING_PREFIXES = {
	[1] = "ACTIONBUTTON",          -- Main bar.
	[2] = "MULTIACTIONBAR1BUTTON", -- Bottom Left.
	[3] = "MULTIACTIONBAR2BUTTON", -- Bottom Right.
	[4] = "MULTIACTIONBAR3BUTTON", -- Right.
	[5] = "MULTIACTIONBAR4BUTTON", -- Right 2.
}

-------------------------------------------------------------------------
-- BTV:ForEachButton(fn)
--
-- Calls fn(ref) for every visible button on both default bars (1-5) and
-- custom bars (6+), where ref is:
--   ref.kind          always "custom" - both bar kinds are Bar.lua/
--                      Button.lua pool buttons; ref.fixedSlotBar is what
--                      distinguishes them.
--   ref.frame          the pool button Frame.
--   ref.bindingId       native binding-action name (default bars, via
--                      btn.nativeBindingId) or TRUSTYBARSBIND<actionSlot
--                      -72> (custom bars).
--   ref.actionSlot       action slot the button is bound to (73-120 for
--                      custom bars, indexes BTV.customBindTargets as
--                      actionSlot - 72).
--   ref.barId          1-5 (default) or 6+ (custom).
--   ref.slotIndex       1-12 within the bar.
--   ref.fixedSlotBar     true when btn.nativeBindingId is set (default-bar
--                      button).
-------------------------------------------------------------------------

function BTV:ForEachButton(fn)
	local barId
	for barId, bar in pairs(self.bars) do
		if bar and bar.buttons then
			local i
			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]
				if btn and btn.slotVisible then
					local bindingId

					-- Default-bar buttons use their precomputed native
					-- binding name; custom-bar buttons derive
					-- TRUSTYBARSBIND<actionSlot-72>.
					if btn.nativeBindingId then
						bindingId = btn.nativeBindingId
					else
						bindingId = "TRUSTYBARSBIND" .. tostring(btn.actionSlot - 72)
					end

					fn({
						kind = "custom",
						frame = btn,
						bindingId = bindingId,
						actionSlot = btn.actionSlot,
						barId = barId,
						slotIndex = i,
						fixedSlotBar = btn.nativeBindingId and true or nil,
					})
				end
			end
		end
	end
end

-------------------------------------------------------------------------
-- Bound check
-------------------------------------------------------------------------

local function IsCustomSlotBound(actionSlot)
	return GetBindingKey("TRUSTYBARSBIND" .. (actionSlot - 72)) ~= nil
end

function BTV:IsButtonBound(ref)
	-- Default-bar buttons: bindingId is already the native binding name.
	if ref.fixedSlotBar then
		return GetBindingKey(ref.bindingId) ~= nil
	end

	return IsCustomSlotBound(ref.actionSlot)
end

-------------------------------------------------------------------------
-- Tinting
--
-- Overrides Button.lua's normal range/usability tint while hoverbind mode
-- is active (UpdateRange short-circuits on BTV:IsHoverBindMode()).
-------------------------------------------------------------------------

local HOVERBIND_BOUND_COLOR   = { 0.2, 1.0, 0.2 }
local HOVERBIND_UNBOUND_COLOR = { 1.0, 0.25, 0.25 }

function BTV:TintHoverBindButton(ref)
	local icon = ref.frame.icon
	if not icon then
		return
	end

	local color = self:IsButtonBound(ref)
		and HOVERBIND_BOUND_COLOR
		or HOVERBIND_UNBOUND_COLOR

	icon:SetVertexColor(color[1], color[2], color[3])
end

-- Lets the button's own normal logic recompute range/usability tint
-- immediately rather than waiting on the next event/ticker tick.
local function RestoreButtonIconTint(ref)
	ref.frame:UpdateRange()
end

-- Called from Core.lua's SetHoverBindMode. Re-asserts tint on a repeating
-- ticker, not a one-shot pass - MultiBarRight/MultiBarLeft revert to white
-- shortly after a one-shot tint, so keep this on a ticker.
local HOVERBIND_TINT_INTERVAL = 0.25

function BTV:ApplyHoverBindVisual(enabled)
	if self.hoverBindTintTicker then
		self.hoverBindTintTicker:Cancel()
		self.hoverBindTintTicker = nil
	end

	if enabled then
		self:ForEachButton(function(ref) self:TintHoverBindButton(ref) end)
		if C_Timer and C_Timer.NewTicker then
			self.hoverBindTintTicker = C_Timer.NewTicker(HOVERBIND_TINT_INTERVAL, function()
				-- Guards against hoverbind mode changing again before this
				-- already-queued tick fires.
				if BTV:IsHoverBindMode() then
					BTV:ForEachButton(function(ref) BTV:TintHoverBindButton(ref) end)
				end
			end)
		end
	else
		self:ForEachButton(function(ref) RestoreButtonIconTint(ref) end)
	end

	local captureFrame = self.hoverBindCaptureFrame
	if captureFrame then
		if enabled then
			captureFrame:Show()
			captureFrame:EnableKeyboard(true)
		else
			captureFrame:EnableKeyboard(false)
			captureFrame:Hide()
			captureFrame.hoveredButton = nil
		end
	end
end

-------------------------------------------------------------------------
-- Hover tracking
--
-- Button.lua's OnEnter/OnLeave call SetHoverBindHoveredCustomButton /
-- ClearHoverBindHoveredButton directly while hoverbind mode is on,
-- covering both default and custom bars through one entry point.
-------------------------------------------------------------------------

function BTV:SetHoverBindHoveredCustomButton(btn)
	if not self.hoverBindCaptureFrame or not btn or not btn.parentBar or not btn.parentBar.config then
		return
	end

	-- Default-bar buttons: btn.nativeBindingId (set at Init/Rebind time in
	-- Button.lua) is already the native binding name.
	local bindingId = btn.nativeBindingId or ("TRUSTYBARSBIND" .. tostring(btn.actionSlot - 72))

	self.hoverBindCaptureFrame.hoveredButton = {
		kind = "custom",
		frame = btn,
		bindingId = bindingId,
		actionSlot = btn.actionSlot,
		barId = btn.parentBar.config.id,
		slotIndex = btn.slotIndex,
		fixedSlotBar = btn.nativeBindingId and true or nil,
	}
end

function BTV:ClearHoverBindHoveredButton(frame)
	if not self.hoverBindCaptureFrame then
		return
	end
	local hovered = self.hoverBindCaptureFrame.hoveredButton
	if hovered and hovered.frame == frame then
		self.hoverBindCaptureFrame.hoveredButton = nil
	end
end

-------------------------------------------------------------------------
-- Capture frame + key handling
-------------------------------------------------------------------------

local MODIFIER_KEYS = {
	LSHIFT = true, RSHIFT = true,
	LCTRL = true, RCTRL = true,
	LALT = true, RALT = true,
}

-- Mouse-button OnMouseDown arg1 name -> SetBinding/GetBindingKey key string.
-- Live-confirmed on this client (diag2 + SetBinding round-trip): OnMouseDown
-- reports "MiddleButton"/"Button4"/"Button5", but the binding system itself
-- only recognizes "BUTTON3"/"BUTTON4"/"BUTTON5". LeftButton/RightButton are
-- deliberately absent - those stay reserved for normal button use.
local MOUSE_BUTTON_BINDING_KEYS = {
	MiddleButton = "BUTTON3",
	Button4 = "BUTTON4",
	Button5 = "BUTTON5",
}

local function BuildComboString(key)
	local combo = ""
	if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
	if IsControlKeyDown() then combo = combo .. "CTRL-" end
	if IsAltKeyDown() then combo = combo .. "ALT-" end
	return combo .. key
end

-- Refreshes tint/hotkey text for hovered after its binding changed.
local function RefreshHoverBindTarget(hovered)
	BTV:TintHoverBindButton(hovered)
	if hovered.frame.UpdateHotkeyText then
		hovered.frame:UpdateHotkeyText()
	end
end

local function ApplyHoverBindKey(hovered, combo)
	local previousAction = GetBindingAction(combo)
	if previousAction and previousAction ~= "" and previousAction ~= hovered.bindingId then
		BTV:Print("Rebound " .. combo .. " (was: " .. previousAction .. ")")
	end

	-- SetBinding only adds a key, it never clears old keys for an action.
	-- Clear any existing key(s) bound to hovered.bindingId first (SetBinding
	-- with no action unbinds it), or the old key keeps showing until reload.
	local existingKey1, existingKey2 = GetBindingKey(hovered.bindingId)

	if existingKey1 and existingKey1 ~= combo then
		SetBinding(existingKey1)
	end

	if existingKey2 and existingKey2 ~= combo then
		SetBinding(existingKey2)
	end

	SetBinding(combo, hovered.bindingId)

	SaveBindings(GetCurrentBindingSet())

	RefreshHoverBindTarget(hovered)
end

-- Escape deletes the hovered button's current keybind rather than binding
-- itself - it never becomes a keybind on this client.
local function ClearHoverBindKey(hovered)
	local existingKey1, existingKey2 = GetBindingKey(hovered.bindingId)

	if not existingKey1 and not existingKey2 then
		return
	end

	if existingKey1 then
		SetBinding(existingKey1)
	end
	if existingKey2 then
		SetBinding(existingKey2)
	end

	SaveBindings(GetCurrentBindingSet())

	BTV:Print("Cleared keybind for " .. hovered.bindingId)

	RefreshHoverBindTarget(hovered)
end

local function HoverBindCaptureFrame_OnKeyDown()
	local key = arg1
	if not key or MODIFIER_KEYS[key] then
		return
	end

	local hovered = this.hoveredButton
	if not hovered then
		return
	end

	if key == "ESCAPE" then
		ClearHoverBindKey(hovered)
		return
	end

	ApplyHoverBindKey(hovered, BuildComboString(key))
end

-- Called from Button.lua's OnMouseDown while hoverbind mode is active, for
-- any mouse button besides Left/Right (those never reach here - see the
-- guard in Button.lua). arg1's OnMouseDown name is looked up against
-- MOUSE_BUTTON_BINDING_KEYS since it isn't the string SetBinding expects.
function BTV:HandleHoverBindMouseButton(frame, buttonName)
	local captureFrame = self.hoverBindCaptureFrame
	local hovered = captureFrame and captureFrame.hoveredButton
	if not hovered or hovered.frame ~= frame then
		return
	end

	local key = MOUSE_BUTTON_BINDING_KEYS[buttonName]
	if not key then
		return
	end

	ApplyHoverBindKey(hovered, BuildComboString(key))
end

local function CreateHoverBindCaptureFrame()
	local f = CreateFrame("Frame", "BTVanillaHoverBindCaptureFrame", UIParent)
	f:EnableKeyboard(false)
	f:Hide()
	f:SetScript("OnKeyDown", HoverBindCaptureFrame_OnKeyDown)
	BTV.hoverBindCaptureFrame = f
	return f
end

CreateHoverBindCaptureFrame()

-------------------------------------------------------------------------
-- Default-bar button hover hookup - no-op
--
-- Hover tracking for default-bar buttons happens through Button.lua's own
-- OnEnter/OnLeave (BTV:SetHoverBindHoveredCustomButton), same as custom
-- bars. Kept as a callable no-op since Core.lua still calls it at
-- PLAYER_LOGIN.
-------------------------------------------------------------------------

function BTV:HookAllDefaultBarButtons()
end
