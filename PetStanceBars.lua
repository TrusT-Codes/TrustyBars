-- PetStanceBars.lua
-- Pet Bar (native mode) and Stance Bar (native mode) - kept in one file
-- since they cross-call each other's Reflow*ForBar*Toggle functions.
-- Built on the shared chain-anchored container engine defined in
-- DefaultBars.lua - this file must load after DefaultBars.lua.

local ACAB = AlternativeClassicActionBars

-------------------------------------------------------------------------
-- Pet Bar (native container - opt-in alternative to the custom-styled
-- pool-button Pet Bar, cfg.useNativePetBar)
--
-- Same BuildChainAnchoredContainer/ApplyChainAnchoredShape/
-- EnsureContainerOverlay machinery as Bag Bar/Micro Menu, applied to the
-- real PetActionButton1-10 frames - keeps their native icon/cooldown/
-- drag-to-reorder/autocast-glow rendering intact.
--
-- Position/spacing read/write straight from
-- ACABDB.defaultBars[PET_BAR_ID] (the same cfg the custom-styled
-- mode uses), so toggling modes never desyncs placement - only cfg.scale
-- is new (custom mode uses buttonSize instead).
-------------------------------------------------------------------------

-- Fixed vertical clearance between Pet Bar and whichever default bar (1 or
-- 3) is topmost - PetActionBarFrame's own GetBottom() is never read for
-- this (unreliable on this client). Value taken from a manually-verified
-- layout.
ACAB.PET_BAR_NATIVE_GAP = 14

-- referenceY is bar 3's nativeAnchor.y if bar 3 is enabled, else bar 1's -
-- mirrors GetStanceBarBaselineY for Bar 3 instead of Bar 2.
-- baselineY = referenceBar.top + gap + height.
function ACAB:GetPetBarBaselineY(bar3Enabled)
	local defaults = ACABDB and ACABDB.defaultBars
	local cfg1 = defaults and defaults[1]
	local cfg3 = defaults and defaults[3]

	local referenceY = cfg1 and cfg1.nativeAnchor and cfg1.nativeAnchor.y

	if bar3Enabled and cfg3 and cfg3.nativeAnchor then
		referenceY = cfg3.nativeAnchor.y

		-- Extra Bar 2 sits above Bar 3 - stack Pet Bar above it too when
		-- both are enabled (GetExtraBarStackPitch, Database.lua).
		referenceY = referenceY + self:GetExtraBarStackPitch(self.EXTRA_BAR_ID_START + 1)
	end

	if not referenceY then
		return nil
	end

	local container = self.petBarNativeContainer

	if not container then
		return nil
	end

	return referenceY + self.PET_BAR_NATIVE_GAP + container:GetHeight()
end

-- Re-stacks Pet Bar vertically off Bar 3's toggle state - mirrors
-- ReflowStanceBarForBar2Toggle for Bar 3 instead of Bar 2. Only y is
-- touched; only call while useDefaultLayout ~= false, or this fights the
-- user's own manually dragged position. Also a no-op once
-- cfg.usesDefaultPosition is false - the user has since moved this
-- element themselves (settings slider or edit-mode drag).
function ACAB:ReflowPetBarForBar3Toggle(bar3Enabled)
	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]
	local container = self.petBarNativeContainer

	if not cfg or not container or cfg.usesDefaultPosition == false then
		return
	end

	local y = self:GetPetBarBaselineY(bar3Enabled)

	if not y then
		return
	end

	cfg.y = y

	if cfg.nativeAnchor then
		cfg.nativeAnchor.y = y
	end

	self:ApplyPetBarNativePosition()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(self.PET_BAR_ID)
	end
end

function ACAB:CreatePetBarNativeContainer()
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	if not cfg or not self:IsPetBarNativeModeEffective() or self.petBarNativeContainer then
		return
	end

	local buttons = self:GetDefaultBarButtons(self.PET_BAR_ID)

	if not buttons then
		return
	end

	self:SortButtonsByNativeLeft(buttons)

	local container = self:BuildChainAnchoredContainer("ACABPetBarNativeContainer", buttons)

	self.petBarNativeContainer = container
	self.petBarNativeButtons = buttons

	self:ApplyPetBarNativeShape()
	self:ApplyPetBarNativePosition()
	self:SetDefaultBarEnabled(self.PET_BAR_ID, cfg.enabled)
end

-- Delegates to Bar.lua's own PixelSetPoint convention via cfg.point/
-- cfg.relativePoint directly (same defaults as Bar.lua's ApplyBarPosition)
-- rather than Bag Bar's hardcoded TOPLEFT/BOTTOMLEFT - this cfg is shared
-- with the custom-styled mode, which already interprets it that way.
function ACAB:ApplyPetBarNativePosition()
	local cfg = ACABDB and ACABDB.defaultBars and ACABDB.defaultBars[self.PET_BAR_ID]
	local container = self.petBarNativeContainer

	if not cfg or not container then
		return
	end

	container:ClearAllPoints()
	self:PixelSetPoint(
		container,
		cfg.point or "TOPLEFT",
		UIParent,
		cfg.relativePoint or "TOPLEFT",
		cfg.x or 0,
		cfg.y or 0
	)

	self:EnsureContainerOverlay(container, self.StartPetBarNativeDrag, self.StopPetBarNativeDrag, self.PET_BAR_ID, self.SetPetBarNativeScale, nil, "Pet Bar", not self:ShouldCondensePetBarSlots())

	-- Same cfg the custom-styled Pet Bar's grid reads, so toggling display mode preserves the hover preference.
	self:ApplyHoverOnlyState(container, cfg.hoverOnly, function() return cfg.hoverDuration or 3 end)
end

-- Settings.lua's Pet Bar page X/Y sliders (native mode) write through this.
function ACAB:SetPetBarNativePosition(x, y)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	x = tonumber(x)
	y = tonumber(y)

	if not cfg or not x or not y then
		return
	end

	cfg.x = x
	cfg.y = y

	-- User is now positioning this element by hand - stop auto-stacking
	-- its Y off Bar 3/Extra Bar 2 (ReflowPetBarForBar3Toggle's own guard).
	cfg.usesDefaultPosition = false

	self:ApplyPetBarNativePosition()
end

-- Re-lays-out the real PetActionButton1-10 frames from cfg.spacing/
-- cfg.scale - orientation is always horizontal (real native Pet Bar has no
-- vertical layout option).
function ACAB:ApplyPetBarNativeShape()
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	if not cfg then
		return
	end

	self:ApplyChainAnchoredShape(
		self.petBarNativeContainer,
		cfg.spacing or 0,
		false,
		cfg.scale or 1,
		not self:ShouldCondensePetBarSlots()
	)
end

-- Mirrors SetDefaultBarSpacing's clamp/write/reapply template, writing the
-- SAME cfg.spacing field the custom-styled Pet Bar's grid uses.
function ACAB:SetPetBarNativeSpacing(spacing)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	spacing = self:ClampSpacingSetting(spacing, 0, 20)

	if not cfg or not spacing then
		return
	end

	cfg.spacing = spacing

	self:ApplyPetBarNativeShape()
end

-- Mirrors SetBagBarScale's clamp/write/reapply template.
function ACAB:SetPetBarNativeScale(scale)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	scale = self:ClampScaleSetting(scale)

	if not cfg or not scale then
		return
	end

	local oldScale = cfg.scale or 1

	if self.petBarNativeContainer then
		self:CompensateScaleKeepingCornerFixed(cfg, oldScale, scale, "BOTTOMLEFT", nil, self.petBarNativeContainer:GetHeight())
	end

	cfg.scale = scale

	self:ApplyPetBarNativeShape()
	self:ApplyPetBarNativePosition()
end

-- Settings.lua's Pet Bar native page "Only show on hover" checkbox/slider - writes the same cfg.hoverOnly/cfg.hoverDuration fields the styled grid uses.
function ACAB:SetPetBarNativeHoverOnly(enabled)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	if not cfg then
		return
	end

	cfg.hoverOnly = enabled and true or false

	self:ApplyPetBarNativePosition()
end

function ACAB:SetPetBarNativeHoverDuration(duration)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	duration = self:ClampHoverDuration(duration)

	if not cfg or not duration then
		return
	end

	cfg.hoverDuration = duration

	self:ApplyPetBarNativePosition()
end

-- Restores position/spacing (cfg.nativeAnchor/cfg.nativeSpacing) and scale, mirroring ResetBagBarLayout's own reset template.
function ACAB:ResetPetBarNativeLayout()
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	if not cfg or not cfg.nativeAnchor then
		return
	end

	cfg.point = cfg.nativeAnchor.point
	cfg.relativePoint = cfg.nativeAnchor.relativePoint
	cfg.x = cfg.nativeAnchor.x
	cfg.y = cfg.nativeAnchor.y

	-- Prefer the computed baseline (stacked off Bar 3's own anchor when
	-- enabled, same as GetPetBarBaselineY) over the raw captured
	-- nativeAnchor - PetActionButton1's live position only reflects
	-- whichever bar Blizzard's native layout had it stacked against at
	-- capture time, which can be stale.
	local bar3Cfg = ACABDB.defaultBars[3]
	local computedY = self:GetPetBarBaselineY(bar3Cfg and bar3Cfg.enabled)

	if computedY then
		cfg.y = computedY
	end

	if cfg.nativeSpacing then
		cfg.spacing = cfg.nativeSpacing
	end

	cfg.scale = 1

	cfg.usesDefaultPosition = true

	self:ApplyPetBarNativePosition()
	self:ApplyPetBarNativeShape()
end

function ACAB:StartPetBarNativeDrag()
	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	if not cfg then
		return
	end

	self:StartSharedDrag("petBarNative", nil, cfg.x or 0, cfg.y or 0)
end

function ACAB:StopPetBarNativeDrag()
	self:StopSharedDrag()

	-- User just moved this element by hand - stop auto-stacking its Y
	-- (same flag SetPetBarNativePosition flips for the settings-page sliders).
	local cfg = ACABDB.defaultBars[self.PET_BAR_ID]

	if cfg then
		cfg.usesDefaultPosition = false
	end

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(self.PET_BAR_ID)
	end
end

-------------------------------------------------------------------------
-- Stance Bar (chain-anchored container)
--
-- Uses the same chain-anchored-container technique as Bag Bar/Micro Menu:
-- real ShapeshiftButton# frames are reparented into our own synthetic
-- container and chain-anchored via ApplyChainAnchoredShape, keeping their
-- native shapeshift-form rendering intact.
--
-- Unlike Bag Bar/Micro Menu, the Stance Bar's button count is
-- class/talent-driven (GetNumShapeshiftForms()-based), not a fixed 5/8 -
-- RebuildStanceBarContainer below re-enumerates and updates the
-- container's chain in place whenever that count changes.
-------------------------------------------------------------------------

-- Captures the real, permanent vertical clearance vanilla leaves between
-- whichever default bar (1 or 2) is topmost and the Stance Bar's own real
-- native ShapeshiftBarFrame - captured once while still queryable at its
-- true native position (this addon only ever reparents ShapeshiftButton
-- N's buttons, never moves ShapeshiftBarFrame itself). referenceY is
-- whichever of bar 1/bar 2's nativeAnchor.y ShapeshiftBarFrame currently
-- sits above (same selection rule GetStanceBarBaselineY uses below).
-- Lazy-capture-once, guarded on ACABDB.stanceBarNativeGap already
-- being present.
--
-- MUST run before ACAB:CreateFixedSlotDefaultBars() (Core.lua's
-- RunLoginSequence calls it first) - CreateFixedSlotDefaultBars
-- permanently hides bar 2's real buttons, which triggers vanilla's own
-- ShapeshiftBar_UpdatePosition() side effect and collapses
-- ShapeshiftBarFrame's real anchor before this capture can read it. The
-- call from CreateStanceBarContainer below is a harmless no-op safety
-- net for any path that reaches here without the early call having run.
function ACAB:CaptureStanceBarNativeGap()
	if ACABDB.stanceBarNativeGap then
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

	local defaults = ACABDB.defaultBars
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

	ACABDB.stanceBarNativeGap = gap
end

-- ShapeshiftBarFrame keeps its own native end-cap/middle background
-- textures even after every ShapeshiftButtonN is reparented out of it -
-- reparenting a button doesn't touch the parent frame's own regions.
-- Hidden and Show()-neutered unconditionally (same treatment as
-- DefaultBars.lua's HideBonusActionBarFrame), since UPDATE_SHAPESHIFT_FORMS
-- runs vanilla's own ShapeshiftBar_Update() (which re-Shows this frame)
-- alongside RebuildStanceBarContainer below.
local function HideShapeshiftBarFrame()
	ACAB:NeuterFrameShow(ShapeshiftBarFrame)
end

-- Builds the Stance Bar's synthetic container the first time this session
-- there are any active stance/form buttons to show - mirrors
-- CreateBagBarAndMicroMenu's structure (native anchor/spacing captured
-- ONCE, never re-derived). A no-op (not an error) if
-- GetNumShapeshiftForms() is 0 right now - RebuildStanceBarContainer
-- below calls this again later, on UPDATE_SHAPESHIFT_FORMS, once forms
-- become available.
function ACAB:CreateStanceBarContainer()
	self:EnsureDB()

	-- Styled mode (cfg.useNativeStanceBar false): the real ShapeshiftButtonN
	-- frames are hidden+neutered and driven by Button.lua's own isStanceSlot
	-- pool instead - this native container must not build over them.
	if not self:IsStanceBarNativeModeEffective() then
		return
	end

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

	self:SortButtonsByNativeLeft(buttons)

	local container, nativeLeft, nativeTop, nativeSpacing =
		self:BuildChainAnchoredContainer("ACABStanceBarContainer", buttons)

	self.stanceBarContainer = container
	self.stanceBarButtons = buttons

	if not ACABDB.stanceBarNativeAnchor then
		ACABDB.stanceBarNativeAnchor = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	if not ACABDB.stanceBarPosition then
		ACABDB.stanceBarPosition = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	if not ACABDB.stanceBarNativeSpacing then
		ACABDB.stanceBarNativeSpacing = nativeSpacing
	end

	-- Routed through the setter (not a direct write) so a fresh install's
	-- very first default spacing still gets floored to the real measured
	-- border overhang in vanilla style - see SetStanceBarSpacing's comment.
	if not ACABDB.stanceBarSpacing then
		self:SetStanceBarSpacing(nativeSpacing)
	end

	self:ApplyStanceBarShape()
	self:ApplyStanceBarBorderStyle()

	self:ApplyStanceBarPosition()
	self:SetStanceBarEnabled(ACABDB.stanceBarEnabled ~= false)

	HideShapeshiftBarFrame()
end

-- Called from UPDATE_SHAPESHIFT_FORMS any time the set of available forms
-- can have changed. If the container doesn't exist yet, defers to
-- CreateStanceBarContainer. If it already exists, updates its chain IN
-- PLACE (re-enumerates active buttons, reparents newly-active ones,
-- re-runs ApplyChainAnchoredShape) rather than tearing down and
-- recreating it, so saved position/spacing/scale/orientation survive.
function ACAB:RebuildStanceBarContainer()
	self:EnsureDB()

	-- Styled mode: this native rebuild must not run - see
	-- CreateStanceBarContainer's own guard above for why.
	if not self:IsStanceBarNativeModeEffective() then
		return
	end

	-- Vanilla's own ShapeshiftBar_Update() also runs off this same
	-- UPDATE_SHAPESHIFT_FORMS event and re-Shows ShapeshiftBarFrame - see
	-- HideShapeshiftBarFrame's own comment above.
	HideShapeshiftBarFrame()

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
	self:ApplyStanceBarBorderStyle()

	if ACABDB.stanceBarEnabled ~= false then
		container:Show()
	end
end

-- Applies ACABDB.stanceBarPosition to the container, and ensures its
-- drag/right-click overlay exists - mirrors ApplyBagBarPosition exactly.
function ACAB:ApplyStanceBarPosition()
	local pos = ACABDB.stanceBarPosition
	local container = self.stanceBarContainer

	if not pos or not container then
		return
	end

	container:ClearAllPoints()
	self:PixelSetPoint(
		container,
		pos.point or "TOPLEFT",
		UIParent,
		pos.relativePoint or "BOTTOMLEFT",
		pos.x or 0,
		pos.y or 0
	)

	self:EnsureContainerOverlay(container, self.StartStanceBarDrag, self.StopStanceBarDrag, self.STANCE_BAR_ID, self.SetStanceBarScale, nil, "Stance Bar")

	-- Same cfg the custom-styled Stance Bar's grid reads, so toggling display mode preserves the hover preference.
	local cfg = ACABDB.defaultBars[self.STANCE_BAR_ID]

	if cfg then
		self:ApplyHoverOnlyState(container, cfg.hoverOnly, function() return cfg.hoverDuration or 3 end)
	end
end

-- Settings.lua's Stance Bar page X/Y sliders write through this.
function ACAB:SetStanceBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.stanceBarPosition then
		return
	end

	ACABDB.stanceBarPosition.x = x
	ACABDB.stanceBarPosition.y = y

	-- User is now positioning this element by hand - stop auto-stacking
	-- its Y off Bar 2/Extra Bar 1 (ReflowStanceBarForBar2Toggle's own guard).
	ACABDB.stanceBarUsesDefaultPosition = false

	self:ApplyStanceBarPosition()
end

-- Settings.lua's Stance Bar page "Reset to Blizzard Default" button.
function ACAB:ResetStanceBarPosition()
	local native = ACABDB.stanceBarNativeAnchor

	if not native then
		return
	end

	ACABDB.stanceBarPosition = {
		point = native.point,
		relativePoint = native.relativePoint,
		x = native.x,
		y = native.y,
	}

	-- Prefer the computed baseline (stacked off Bar 2/Extra Bar 1 when
	-- enabled, same as GetStanceBarBaselineY) over the raw captured
	-- nativeAnchor - mirrors ResetPetBarNativeLayout's own reasoning.
	local bar2Cfg = ACABDB.defaultBars[2]
	local computedY = self:GetStanceBarBaselineY(bar2Cfg and bar2Cfg.enabled)

	if computedY then
		ACABDB.stanceBarPosition.y = computedY
	end

	ACABDB.stanceBarUsesDefaultPosition = true

	self:ApplyStanceBarPosition()
end

-- Settings.lua's Stance Bar page enable checkbox. The container's own
-- Show()/Hide() cascades to every real child stance button, exactly like
-- Bag Bar/Micro Menu's own SetBagBarEnabled/SetMicroMenuEnabled - no
-- fixed-slot-replica/native-hide distinction to branch on here either.
function ACAB:SetStanceBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	ACABDB.stanceBarEnabled = enabled

	if self.stanceBarContainer then
		if enabled then
			self.stanceBarContainer:Show()
		else
			self.stanceBarContainer:Hide()

			-- Same explicit-hide requirement as SetBagBarEnabled above.
			if self.stanceBarContainer.ACABOverlay then
				self.stanceBarContainer.ACABOverlay:Hide()
				self.stanceBarContainer.ACABOverlay:EnableMouse(false)
			end
		end
	end
end

-- Computes the absolute Stance Bar top-edge Y (UIParent-bottom-left
-- origin, y increases upward) for a given bar-2 enabled state, computed
-- fresh from live-captured native baselines every time - never derived
-- from whatever ACABDB.stanceBarPosition.y currently holds.
--
-- baselineY = referenceBar.top + gap + height, where gap is the fixed
-- native clearance (~5, ACABDB.stanceBarNativeGap) between the
-- reference bar's top edge and the Stance Bar's bottom edge, and height
-- is read live from self.stanceBarContainer:GetHeight() so this stays
-- correct if the user scales the Stance Bar.
--
-- referenceY is bar 2's own nativeAnchor.y if bar 2 is enabled, else
-- bar 1's.
function ACAB:GetStanceBarBaselineY(bar2Enabled)
	local defaults = ACABDB and ACABDB.defaultBars
	local cfg1 = defaults and defaults[1]
	local cfg2 = defaults and defaults[2]

	local referenceY = cfg1 and cfg1.nativeAnchor and cfg1.nativeAnchor.y

	if bar2Enabled and cfg2 and cfg2.nativeAnchor then
		referenceY = cfg2.nativeAnchor.y

		-- Extra Bar 1 sits above Bar 2 - stack Stance Bar above it too when
		-- both are enabled (GetExtraBarStackPitch, Database.lua).
		referenceY = referenceY + self:GetExtraBarStackPitch(self.EXTRA_BAR_ID_START)
	end

	if not referenceY then
		return nil
	end

	local container = self.stanceBarContainer

	if not container then
		return nil
	end

	-- Same fixed clearance Pet Bar uses (PET_BAR_NATIVE_GAP) rather than
	-- the smaller captured stanceBarNativeGap - the real captured gap sat
	-- the Stance Bar too low against Bar 1/2's actual footprint.
	return referenceY + self.PET_BAR_NATIVE_GAP + container:GetHeight()
end

-- Replicates real vanilla's ShapeshiftBar_UpdatePosition side effect
-- against the Stance Bar's own synthetic container, since the native call
-- against the real ShapeshiftBarFrame no longer has any visual effect
-- post-migration. Always an absolute, self-correcting recompute: pos.y is
-- overwritten with GetStanceBarBaselineY's fresh result, so this can
-- never accumulate drift. Only x is left untouched.
--
-- Only called while useDefaultLayout ~= false - once the user switches
-- the Stance Bar to manual positioning, this must never fight their own
-- dragged position. Also a no-op once ACABDB.stanceBarUsesDefaultPosition
-- is false - the user has since moved this element themselves (settings
-- slider or edit-mode drag), so auto-stacking must leave it alone too.
function ACAB:ReflowStanceBarForBar2Toggle(bar2Enabled)
	if ACABDB.stanceBarUsesDefaultPosition == false then
		return
	end

	local pos = ACABDB.stanceBarPosition
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
		self:RefreshBarSettingsPage(self.STANCE_BAR_ID)
	end
end

-- Re-lays-out the Stance Bar's real buttons from its CURRENT saved
-- spacing/orientation/scale, via the shared ApplyChainAnchoredShape helper
-- - mirrors ACAB:ApplyBagBarShape exactly. A no-op until
-- CreateStanceBarContainer has built the container.
function ACAB:ApplyStanceBarShape()
	self:EnsureDB()

	self:ApplyChainAnchoredShape(
		self.stanceBarContainer,
		ACABDB.stanceBarSpacing or 0,
		ACABDB.stanceBarOrientation == true,
		ACABDB.stanceBarScale or 1
	)
end

-- Applies the current global border style (ACAB:IsVanillaBorderStyle) to
-- the Stance Bar's real ShapeshiftButtonN frames - mirrors Button.lua's
-- ACABButtonMixin:ApplyBorderStyle against a real Blizzard button instead
-- of a synthetic one. Vanilla mode leaves the native NormalTexture alone;
-- modern mode hides it and draws the flat dark-backdrop/inset-icon look
-- Extra Bar buttons use.
--
-- Do NOT draw the backdrop via btn:SetBackdrop() directly - on this
-- native template it renders ABOVE ShapeshiftButtonNIcon, washing the
-- icon out grey. Uses a separate plain child frame at a lower FrameLevel
-- (matching FrameStrata) instead - a real sibling frame's level/strata
-- ordering is reliable here, backdrop-vs-native-region ordering is not.
function ACAB:ApplyStanceBarBorderStyle()
	local buttons = self.stanceBarButtons

	if not buttons then
		return
	end

	local vanilla = self:IsVanillaBorderStyle()
	local i

	for i = 1, table.getn(buttons) do
		local btn = buttons[i]

		if btn then
			local name = btn:GetName()
			local icon = name and getglobal(name .. "Icon")
			local normalTex = btn:GetNormalTexture()

			-- One-time cleanup for any button that already picked up the
			-- old (buggy) btn:SetBackdrop() treatment this session, before
			-- this fix - never applied by the code below anymore.
			if btn.ACABBackdropApplied then
				btn:SetBackdrop(nil)
				btn.ACABBackdropApplied = nil
			end

			if vanilla then
				if normalTex then
					normalTex:Show()
				end

				if icon then
					icon:ClearAllPoints()
					icon:SetAllPoints(btn)
				end

				if btn.ACABModernBackdrop then
					btn.ACABModernBackdrop:Hide()
				end
			else
				if normalTex then
					normalTex:Hide()
				end

				if icon then
					icon:ClearAllPoints()
					icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
					icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
				end

				if not btn.ACABModernBackdrop then
					local backdrop = CreateFrame("Frame", nil, btn:GetParent())

					backdrop:SetFrameStrata(btn:GetFrameStrata())
					backdrop:SetFrameLevel(math.max((btn:GetFrameLevel() or 1) - 1, 0))
					backdrop:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
					backdrop:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
					backdrop:SetBackdrop({
						bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
						edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
						tile = true,
						tileSize = 8,
						edgeSize = 8,
						insets = { left = 1, right = 1, top = 1, bottom = 1 },
					})
					backdrop:SetBackdropColor(0, 0, 0, 0.75)
					backdrop:SetBackdropBorderColor(1, 1, 1, 1)

					btn.ACABModernBackdrop = backdrop
				end

				btn.ACABModernBackdrop:Show()
			end
		end
	end
end

-- Mirrors SetPetBarNativeSpacing's exact clamp/write/reapply template -
-- plain 0 to 20, same as Pet Bar. An earlier version enforced a vanilla-
-- border-style floor (the real overhang measures exactly 20 on this
-- client, collapsing the slider's whole range to one value) - the border
-- never actually overlaps at spacing 0 in either style, so it was dropped.
function ACAB:SetStanceBarSpacing(spacing)
	self:EnsureDB()

	spacing = self:ClampSpacingSetting(spacing, 0, 20)

	if not spacing then
		return
	end

	ACABDB.stanceBarSpacing = spacing

	self:ApplyStanceBarShape()
end

-- Mirrors SetBagBarScale's exact clamp/write/reapply template.
function ACAB:SetStanceBarScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.stanceBarScale or 1
	local pos = ACABDB.stanceBarPosition

	if pos and self.stanceBarContainer then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, self.stanceBarContainer:GetHeight())
	end

	ACABDB.stanceBarScale = scale

	self:ApplyStanceBarShape()

	if pos then
		self:ApplyStanceBarPosition()
	end
end

-- Orientation is a plain boolean toggle (true = vertical/swapped) - no
-- clamping needed, mirrors SetBagBarOrientation.
function ACAB:SetStanceBarOrientation(vertical)
	self:EnsureDB()

	ACABDB.stanceBarOrientation = vertical and true or false

	self:ApplyStanceBarShape()
end

-- Settings.lua's Stance Bar native page "Only show on hover" checkbox/slider - writes the same cfg.hoverOnly/cfg.hoverDuration fields the styled grid uses.
function ACAB:SetStanceBarNativeHoverOnly(enabled)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.STANCE_BAR_ID]

	if not cfg then
		return
	end

	cfg.hoverOnly = enabled and true or false

	self:ApplyStanceBarPosition()
end

function ACAB:SetStanceBarNativeHoverDuration(duration)
	self:EnsureDB()

	local cfg = ACABDB.defaultBars[self.STANCE_BAR_ID]

	duration = self:ClampHoverDuration(duration)

	if not cfg or not duration then
		return
	end

	cfg.hoverDuration = duration

	self:ApplyStanceBarPosition()
end

-- Settings.lua's Stance Bar page reset flow calls this alongside
-- ResetStanceBarPosition (simpleBarPageConfigs[ACAB.STANCE_BAR_ID].reset) -
-- restores spacing/scale/orientation to their native baseline, mirroring
-- ResetBagBarLayout.
function ACAB:ResetStanceBarLayout()
	self:EnsureDB()

	-- Routed through the setter (not a direct write) so the native gap
	-- still gets floored to the real border overhang in vanilla style -
	-- see SetStanceBarSpacing's own comment.
	self:SetStanceBarSpacing(ACABDB.stanceBarNativeSpacing or 0)
	ACABDB.stanceBarScale = 1
	ACABDB.stanceBarOrientation = false

	self:ApplyStanceBarShape()
end

function ACAB:StartStanceBarDrag()
	local pos = ACABDB.stanceBarPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "stanceBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopStanceBarDrag()
	self:StopSharedDrag()

	-- User just moved this element by hand - stop auto-stacking its Y
	-- (same flag SetStanceBarPosition flips for the settings-page sliders).
	ACABDB.stanceBarUsesDefaultPosition = false

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(self.STANCE_BAR_ID)
	end
end

-------------------------------------------------------------------------
-- Stance bar buttons
--
-- GetNumShapeshiftForms() is the authoritative source for how many
-- ShapeshiftButton# frames are "active" for the current class/talent
-- state - NOT :IsShown(), which isn't reliable before the native stance
-- bar has ever been touched. Returns 0 for a class with no stance/form
-- mechanic, in which case CreateStanceBarContainer/RebuildStanceBarContainer
-- simply don't build/show anything.
-------------------------------------------------------------------------

-- Returns an ordered table of the currently-active real Blizzard stance
-- button frames (1 through GetNumShapeshiftForms(), capped at
-- MAX_STANCE_BUTTONS), or nil if there are none right now.
function ACAB:GetStanceBarButtons()
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

