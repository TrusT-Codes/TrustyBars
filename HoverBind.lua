-- HoverBind.lua
-- "Hoverbind" mode: hover any button (default-bar or custom-bar) and press
-- a key to bind it, mirroring Bartender2's hoverbind feature. Mutually
-- exclusive with edit mode - see Core.lua's SetEditMode/SetHoverBindMode.
--
-- Binding-source priority (non-negotiable per the v1.0 plan): both bar
-- kinds are now bound exclusively through real, named binding actions -
-- never SetBindingClick, which doesn't work on this client at all (see
-- below).
--
--   - Default-bar buttons (bars 1-5) are real Blizzard action-bar frames
--     that already have real native binding actions (ACTIONBUTTON1-12,
--     MULTIACTIONBAR#BUTTON1-12) - we bind through SetBinding on those
--     names.
--   - Custom-bar slots (bars 6+) live on action-bar pages 7-10, which
--     vanilla's own Bindings.xml has no native per-slot binding action
--     for at all (it only covers the main bar's paging plus the 4 fixed
--     multibars). SetBindingClick/"CLICK <frame>:<button>" and
--     SetBinding(key, "BONUSACTIONBUTTON1") were both live-tested this
--     session and confirmed dead: the binding system records them fine
--     (GetBindingAction/GetBindingKey and bindings-cache.wtf both show
--     them) but the client's input dispatcher never actually fires them.
--     The fix that DOES work, confirmed live via the third-party addon
--     aBindings (shipped as reference under aBindings/, not modified):
--     this addon's own bindings.xml declares 48 static binding-action
--     names, TRUSTYBARSBIND1-48, one per free action slot (73-120), each
--     invoking TrustyBars_HoverBindFire(N) with a literal index. That's a
--     first-class binding action exactly like ACTIONBUTTON1-12, so a
--     plain SetBinding(key, "TRUSTYBARSBIND<n>") on it works the same way
--     the default-bar path already does.

local BTV = BTVanilla

-------------------------------------------------------------------------
-- Custom-bar slot -> button lookup table, keyed by actionSlot - 72
-- (range 1-48, matching bindings.xml's TRUSTYBARSBIND1-48 names).
--
-- Populated/updated in Button.lua wherever a custom-bar button's
-- actionSlot is set (CreateActionButton/Init, and Rebind's slot-remap
-- path) so this always reflects whichever live button frame currently
-- occupies a given free action slot, independent of bar IDs (which grow
-- unbounded as bars are created/deleted - the action slot itself is the
-- stable, bounded 1-48 index bindings.xml needs).
-------------------------------------------------------------------------

BTV.customBindTargets = {}

-- Called only from bindings.xml's TRUSTYBARSBIND1-48 bodies - must be a
-- bare global function, not a BTV: method, since an XML Binding body can
-- only invoke a plain global function name.
function TrustyBars_HoverBindFire(slotIndex)
	local btn = BTV.customBindTargets and BTV.customBindTargets[slotIndex]
	if btn then
		btn:Click()
	end
end

-------------------------------------------------------------------------
-- Default-bar binding-action-name mapping
--
-- UNVERIFIED on this specific client (plan §6 item 3 - no live client
-- available this session). This is the well-established vanilla 1.12.1
-- FrameXML/Bindings.xml convention: MULTIACTIONBAR1BUTTON# for
-- MultiBarBottomLeft, MULTIACTIONBAR2BUTTON# for MultiBarBottomRight,
-- MULTIACTIONBAR3BUTTON# for MultiBarRight, MULTIACTIONBAR4BUTTON# for
-- MultiBarLeft. Centralized here, mirroring DefaultBars.lua's
-- DEFAULT_BAR_FRAME_PREFIXES, so a wrong prefix is a one-line fix.
-------------------------------------------------------------------------

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
-- Walks every currently-visible/active button of both bar kinds and
-- calls fn(ref) for each one, where ref is:
--
--   ref.kind        "custom" or "default"
--   ref.frame        the real button Frame (custom pool slot, or
--                        Blizzard's own ActionButtonN/MultiBar...ButtonN)
--   ref.bindingId        native binding-action name: ACTIONBUTTON#/
--                        MULTIACTIONBAR#BUTTON# (default) or
--                        TRUSTYBARSBIND<actionSlot-72> (custom) - both
--                        are real bindings.xml-declared action names now,
--                        so both are handled identically everywhere else
--                        in this file.
--   ref.actionSlot        custom bars only: the live action slot
--                        (73-120) this pool slot is currently bound to -
--                        the same key BTV.customBindTargets is indexed
--                        by (actionSlot - 72).
--   ref.barId        1-5 (default) or 6+ (custom)
--   ref.slotIndex        1-12 within the bar
-------------------------------------------------------------------------

function BTV:ForEachButton(fn)
	-- Custom bars (6+) AND, since the major architecture migration
	-- (Phases 1 and 2), every default bar (1-5 - see Bar.lua/
	-- DefaultBars.lua's CreateFixedSlotDefaultBars) all live in self.bars
	-- now and share the exact same pool-slot structure. Only visible pool
	-- slots (SetSlotVisible-hidden slots aren't real bound targets right
	-- now). bindingId differs by bar kind: a default bar's button (1-5)
	-- dispatches through its real native binding name (e.g.
	-- MULTIACTIONBAR1BUTTON5 for bars 2-5, ACTIONBUTTON5 for bar 1 -
	-- already handled natively by Blizzard's own, now-hidden, ActionButton
	-- frame), never TRUSTYBARSBIND<n> (which only covers the free 73-120
	-- pool) - Button.lua's Init/Rebind already precompute this exact
	-- binding name onto btn.nativeBindingId for both fixed-slot (2-5) and
	-- dynamic-slot (1) default-bar buttons alike, so it's read straight
	-- from there rather than re-derived per bar kind here.
	local barId
	for barId, bar in pairs(self.bars) do
		if bar and bar.buttons then
			local i
			for i = 1, table.getn(bar.buttons) do
				local btn = bar.buttons[i]
				if btn and btn.slotVisible then
					local bindingId

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

-- Custom-bar slots are now real bindings.xml-declared binding actions
-- (TRUSTYBARSBIND1-48), so GetBindingKey works exactly the same way it
-- already does for the default-bar path below - no more scanning
-- GetNumBindings()/GetBinding(i) for a "CLICK ..." string match.
local function IsCustomSlotBound(actionSlot)
	return GetBindingKey("TRUSTYBARSBIND" .. (actionSlot - 72)) ~= nil
end

function BTV:IsButtonBound(ref)
	if ref.kind == "default" then
		return GetBindingKey(ref.bindingId) ~= nil
	end

	-- Fixed-slot default bars (2-5): bindingId is already the real native
	-- binding name (see ForEachButton/SetHoverBindHoveredCustomButton), so
	-- this checks it directly, mirroring the "default" branch above -
	-- IsCustomSlotBound's TRUSTYBARSBIND<n> lookup only applies to the
	-- free 73-120 pool.
	if ref.fixedSlotBar then
		return GetBindingKey(ref.bindingId) ~= nil
	end

	return IsCustomSlotBound(ref.actionSlot)
end

-------------------------------------------------------------------------
-- Tinting
--
-- Wins outright over Button.lua's normal range/usability tint while
-- hoverbind mode is active (UpdateRange short-circuits on
-- BTV:IsHoverBindMode() - see Button.lua). Default-bar buttons use their
-- real FrameXML icon texture, named "<frameName>Icon" per standard
-- vanilla ActionButtonTemplate convention (same class of well-established
-- naming DefaultBars.lua already relies on for the frame prefixes
-- themselves).
-------------------------------------------------------------------------

local HOVERBIND_BOUND_COLOR   = { 0.2, 1.0, 0.2 }
local HOVERBIND_UNBOUND_COLOR = { 1.0, 0.25, 0.25 }

local function GetButtonIconTexture(ref)
	if ref.kind == "custom" then
		return ref.frame.icon
	end
	return getglobal(ref.frame:GetName() .. "Icon")
end

function BTV:TintHoverBindButton(ref)
	local icon = GetButtonIconTexture(ref)
	if not icon then
		return
	end

	local color = self:IsButtonBound(ref)
		and HOVERBIND_BOUND_COLOR
		or HOVERBIND_UNBOUND_COLOR

	icon:SetVertexColor(color[1], color[2], color[3])
end

local function RestoreButtonIconTint(ref)
	if ref.kind == "custom" then
		-- Let the button's own normal logic recompute range/usability
		-- tint immediately rather than waiting on the next event/ticker
		-- tick to correct it.
		ref.frame:UpdateRange()
	else
		local icon = GetButtonIconTexture(ref)
		if icon then
			icon:SetVertexColor(1, 1, 1)
		end
	end
end

-- Called from Core.lua's SetHoverBindMode. Runs a repeating tint pass
-- while hoverbind mode is on, restores normal tinting once on exit, and
-- toggles the capture frame's keyboard.
--
-- The repeating pass (rather than a single one-shot tint on entry) exists
-- because MultiBarRight/MultiBarLeft (default bars 4/5) have been observed
-- losing their tint back to white shortly after the one-shot pass used to
-- run, only for it to "stick" once the user toggled that bar off/on via
-- Settings. Root cause unconfirmed (suspected: Blizzard's own native
-- ActionButton_Update, which runs on its own event/OnUpdate cycle
-- independent of this addon, re-asserting SetVertexColor on those two
-- bars specifically) - rather than chase that further, this just
-- re-asserts our tint every HOVERBIND_TINT_INTERVAL seconds so any such
-- reset is invisible to the user. C_Timer.NewTicker is confirmed real and
-- DLL-native (doc section 5b) - same pattern already used for the
-- per-button range ticker in Button.lua.
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
				-- Belt-and-suspenders: the ticker is cancelled the instant
				-- hoverbind mode turns off (above), but guard against mode
				-- having flipped again between two already-queued ticks.
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
-- ClearHoverBindHoveredButton directly (only while hoverbind mode is on).
-- Default-bar buttons get the same tracking via HookScript below, hooked
-- exactly once (guarded by a hooked-frames table) rather than re-hooked
-- on every mode toggle.
-------------------------------------------------------------------------

function BTV:SetHoverBindHoveredCustomButton(btn)
	if not self.hoverBindCaptureFrame or not btn or not btn.parentBar or not btn.parentBar.config then
		return
	end

	-- Fixed-slot default bars (2-5): btn.nativeBindingId (set at Init/
	-- Rebind time in Button.lua) is the real native binding name - mirrors
	-- ForEachButton's fixedPrefix branch exactly, just derived from the
	-- button itself rather than re-deriving the prefix here.
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

function BTV:SetHoverBindHoveredDefaultButton(ref)
	if not self.hoverBindCaptureFrame then
		return
	end
	self.hoverBindCaptureFrame.hoveredButton = ref
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

local function BuildComboString(key)
	local combo = ""
	if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
	if IsControlKeyDown() then combo = combo .. "CTRL-" end
	if IsAltKeyDown() then combo = combo .. "ALT-" end
	return combo .. key
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

	local combo = BuildComboString(key)

	local previousAction = GetBindingAction(combo)
	if previousAction and previousAction ~= "" and previousAction ~= hovered.bindingId then
		BTV:Print("Rebound " .. combo .. " (was: " .. previousAction .. ")")
	end

	-- hovered.bindingId is already the correct binding-action name for
	-- every kind (see ForEachButton/SetHoverBindHoveredCustomButton above):
	-- the native ACTIONBUTTON#/MULTIACTIONBAR#BUTTON# name for bar 1 and
	-- fixed-slot default bars 2-5 alike, or TRUSTYBARSBIND<n> for a real
	-- free-pool custom bar (id 6+) - TRUSTYBARSBIND<n> (bindings.xml) is a
	-- real, client-dispatched binding action, unlike the dead-end
	-- SetBindingClick/"CLICK <frame>:<button>" and BONUSACTIONBUTTON1
	-- mechanisms both live-tested and confirmed non-functional this
	-- session (see file-level comment at top). No branch needed here.
	SetBinding(combo, hovered.bindingId)

	SaveBindings(GetCurrentBindingSet())

	BTV:TintHoverBindButton(hovered)

	-- Issue 5 (bug-fix batch): refresh this button's own hotkey text
	-- immediately rather than waiting on its next unrelated Refresh() -
	-- default-bar buttons have no equivalent custom hotkey FontString
	-- (Button.lua's self.hotkey is a custom-bar-only addition), so this
	-- only applies to the custom-bar path.
	if hovered.kind == "custom" and hovered.frame.UpdateHotkeyText then
		hovered.frame:UpdateHotkeyText()
	end
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
-- Default-bar button hover + right-click-to-settings hookup
--
-- Main Bar migration, Phase 2: this section's per-frame HookScript
-- implementation (HookDefaultBarButton/hookedDefaultButtons) is REMOVED
-- entirely - it hooked the real Blizzard ActionButton1-12/MultiBar...
-- frames directly, all 60 of which are now permanently hidden (see
-- DefaultBars.lua's CreateFixedSlotDefaultBars), making every one of
-- those hooks pure dead code (a Hidden frame never receives OnEnter/
-- OnClick regardless of what's hooked onto it). HookAllDefaultBarButtons
-- below is kept as a callable no-op only - see its own comment.
-------------------------------------------------------------------------

-- Now a no-op for EVERY default bar (Main Bar migration, Phase 2): bar 1's
-- real Blizzard ActionButton1-12 frames are, as of this migration,
-- permanently hidden exactly like bars 2-5's already were (see
-- DefaultBars.lua's CreateFixedSlotDefaultBars) - hooking them here would
-- be pure dead code, a Hidden frame never receives OnEnter/OnClick at all
-- regardless of what's hooked onto it. Every default bar's replica buttons
-- (real Bar.lua/Button.lua pool buttons, living in self.bars) already get
-- equivalent hover-tracking for free through Button.lua's own OnEnter/
-- OnLeave (BTV:SetHoverBindHoveredCustomButton) and right-click-to-settings
-- through Bar.lua's per-bar edit-mode overlay (EnsureBarOverlay) - exactly
-- the same mechanisms a real custom bar (id 6+) already uses, needing no
-- separate hookup here. Kept as a callable no-op (Core.lua still calls it
-- at PLAYER_LOGIN) rather than removed outright, matching Core.lua's own
-- comment on why that call site is harmless to keep.
function BTV:HookAllDefaultBarButtons()
end
