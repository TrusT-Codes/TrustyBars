-- NativeElements.lua
-- Bag Bar, Micro Menu, Key Ring, Latency Bar, Cast Bar, Page Indicator.
-- Built on the shared chain/grid-anchored container engine and drag
-- engine defined in DefaultBars.lua (BuildChainAnchoredContainer,
-- ApplyChainAnchoredShape, EnsureContainerOverlay, InstallReanchorGuard,
-- InstallShowGuard, etc.). This file MUST load after DefaultBars.lua:
-- Key Ring/Latency Bar/Cast Bar each make a top-level (file-load-time)
-- ACAB:InstallShowGuard/ACAB:InstallReanchorGuard call below, and loading
-- out of order throws "attempt to call nil value" on the player's very
-- first login.

local ACAB = AlternativeClassicActionBars

-------------------------------------------------------------------------
-- Bag Bar position/enable
-------------------------------------------------------------------------

-- Applies ACABDB.bagBarPosition to the real container, and ensures
-- its overlay exists. Unlike a single real native frame (e.g. Key Ring/
-- Latency Bar below), this synthetic container has no independent
-- existence outside this addon to self-heal from - it's simply assumed
-- CreateBagBarAndMicroMenu has already run and seeded bagBarPosition by
-- the time this is called.
function ACAB:ApplyBagBarPosition()
	local pos = ACABDB.bagBarPosition
	local container = self.bagBarContainer

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

	self:EnsureContainerOverlay(container, self.StartBagBarDrag, self.StopBagBarDrag, "bagbar", self.SetBagBarScale, nil, "Bag Bar")

	self:ApplyHoverOnlyState(container, ACABDB.bagBarHoverOnly, function() return ACABDB.bagBarHoverDuration or 3 end)
end

-- Settings.lua's Bag Bar page X/Y sliders write through this.
function ACAB:SetBagBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.bagBarPosition then
		return
	end

	ACABDB.bagBarPosition.x = x
	ACABDB.bagBarPosition.y = y

	self:ApplyBagBarPosition()
end

-- Settings.lua's Bag Bar page "Reset to Blizzard Default" button.
function ACAB:ResetBagBarPosition()
	local native = ACABDB.bagBarNativeAnchor

	if not native then
		return
	end

	ACABDB.bagBarPosition = {
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
function ACAB:SetBagBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	ACABDB.bagBarEnabled = enabled

	if self.bagBarContainer then
		if enabled then
			self.bagBarContainer:Show()
		else
			self.bagBarContainer:Hide()

			-- EnsureContainerOverlay's overlay is parented to UIParent, not
			-- this container, so hiding the container doesn't cascade to
			-- hide the overlay too.
			if self.bagBarContainer.ACABOverlay then
				self.bagBarContainer.ACABOverlay:Hide()
				self.bagBarContainer.ACABOverlay:EnableMouse(false)
			end
		end
	end
end

-- Settings.lua's Bag Bar page "Only show on hover" checkbox - also governs the Key Ring frame, which has no fields of its own.
function ACAB:SetBagBarHoverOnly(enabled)
	self:EnsureDB()

	ACABDB.bagBarHoverOnly = enabled and true or false

	self:ApplyBagBarPosition()
	self:ApplyKeyRingPosition()
end

function ACAB:SetBagBarHoverDuration(duration)
	self:EnsureDB()

	duration = self:ClampHoverDuration(duration)

	if not duration then
		return
	end

	ACABDB.bagBarHoverDuration = duration

	self:ApplyBagBarPosition()
	self:ApplyKeyRingPosition()
end

-- Re-lays-out the Bag Bar's real buttons from its current saved
-- spacing/orientation/scale, via the shared ApplyChainAnchoredShape
-- helper above. A no-op until CreateBagBarAndMicroMenu has built the
-- container (ApplyChainAnchoredShape's own container.chainButtons
-- nil-check).
function ACAB:ApplyBagBarShape()
	self:EnsureDB()

	self:ApplyChainAnchoredShape(
		self.bagBarContainer,
		ACABDB.bagBarSpacing or 0,
		ACABDB.bagBarOrientation == true,
		ACABDB.bagBarScale or 1
	)
end

-- Mirrors SetDefaultBarSpacing's exact clamp/write/reapply template
-- (DefaultBars.lua) - same 0-20 range, matching the Settings UI's shared
-- SPACING_MIN/MAX constants.
function ACAB:SetBagBarSpacing(spacing)
	self:EnsureDB()

	spacing = self:ClampSpacingSetting(spacing, 0, 20)

	if not spacing then
		return
	end

	ACABDB.bagBarSpacing = spacing

	self:ApplyBagBarShape()
end

-- Same clamp/write/reapply template, rounded to the nearest 0.1 (the
-- Settings slider's step) instead of an integer pixel - Scale is a
-- proportional multiplier, not a pixel quantity.
function ACAB:SetBagBarScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.bagBarScale or 1
	local pos = ACABDB.bagBarPosition

	if pos and self.bagBarContainer then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, self.bagBarContainer:GetHeight())
	end

	ACABDB.bagBarScale = scale

	self:ApplyBagBarShape()

	if pos then
		self:ApplyBagBarPosition()
	end
end

-- Orientation is a plain boolean toggle (true = vertical/swapped) - no
-- clamping needed, unlike Spacing/Scale above.
function ACAB:SetBagBarOrientation(vertical)
	self:EnsureDB()

	ACABDB.bagBarOrientation = vertical and true or false

	self:ApplyBagBarShape()
end

-- Settings.lua's Bag Bar page reset flow calls this alongside
-- ResetBagBarPosition (simpleBarPageConfigs["bagbar"].reset) - restores
-- spacing/scale/orientation to their native baseline (bagBarNativeSpacing,
-- 1, false), mirroring ResetDefaultBarLayout's own nativeSpacing restore
-- for default bars.
function ACAB:ResetBagBarLayout()
	self:EnsureDB()

	ACABDB.bagBarSpacing = ACABDB.bagBarNativeSpacing or 0
	ACABDB.bagBarScale = 1
	ACABDB.bagBarOrientation = false

	self:ApplyBagBarShape()
end

function ACAB:StartBagBarDrag()
	local pos = ACABDB.bagBarPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "bagBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopBagBarDrag()
	self:StopSharedDrag()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("bagbar")
	end
end

-------------------------------------------------------------------------
-- Micro Menu position/enable - mirrors the Bag Bar block above exactly.
-------------------------------------------------------------------------

function ACAB:ApplyMicroMenuPosition()
	local pos = ACABDB.microMenuPosition
	local container = self.microMenuContainer

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

	self:EnsureContainerOverlay(container, self.StartMicroMenuDrag, self.StopMicroMenuDrag, "micromenu", self.SetMicroMenuScale, nil, "Micro Menu")

	self:ApplyHoverOnlyState(container, ACABDB.microMenuHoverOnly, function() return ACABDB.microMenuHoverDuration or 3 end)
end

function ACAB:SetMicroMenuPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.microMenuPosition then
		return
	end

	ACABDB.microMenuPosition.x = x
	ACABDB.microMenuPosition.y = y

	self:ApplyMicroMenuPosition()
end

function ACAB:ResetMicroMenuPosition()
	local native = ACABDB.microMenuNativeAnchor

	if not native then
		return
	end

	ACABDB.microMenuPosition = {
		point = native.point,
		relativePoint = native.relativePoint,
		x = native.x,
		y = native.y,
	}

	self:ApplyMicroMenuPosition()
end

function ACAB:SetMicroMenuEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	ACABDB.microMenuEnabled = enabled

	if self.microMenuContainer then
		if enabled then
			self.microMenuContainer:Show()
		else
			self.microMenuContainer:Hide()

			-- Same explicit-hide requirement as SetBagBarEnabled above.
			if self.microMenuContainer.ACABOverlay then
				self.microMenuContainer.ACABOverlay:Hide()
				self.microMenuContainer.ACABOverlay:EnableMouse(false)
			end
		end
	end
end

-- Settings.lua's Micro Menu page "Only show on hover" checkbox/slider.
function ACAB:SetMicroMenuHoverOnly(enabled)
	self:EnsureDB()

	ACABDB.microMenuHoverOnly = enabled and true or false

	self:ApplyMicroMenuPosition()
end

function ACAB:SetMicroMenuHoverDuration(duration)
	self:EnsureDB()

	duration = self:ClampHoverDuration(duration)

	if not duration then
		return
	end

	ACABDB.microMenuHoverDuration = duration

	self:ApplyMicroMenuPosition()
end

-- Unlike Bag Bar/Stance Bar, Micro Menu lays out via the fixed-grid function -
-- see ApplyGridAnchoredShape's own comment above.
function ACAB:ApplyMicroMenuShape()
	self:EnsureDB()

	self:ApplyGridAnchoredShape(
		self.microMenuContainer,
		ACABDB.microMenuCols or 8,
		ACABDB.microMenuRows or 1,
		ACABDB.microMenuSpacing or 0,
		ACABDB.microMenuScale or 1
	)
end

function ACAB:SetMicroMenuSpacing(spacing)
	self:EnsureDB()

	-- Actual range is [-14, 16], shifted -4 from the slider's own displayed
	-- [-10, 20] range - Settings.lua's Micro Menu spacing slider applies a
	-- +4 display offset on top of this (see simpleBarPageConfigs["micromenu"]'s
	-- spacingUiOffset) to compensate for native button art padding that
	-- makes an actual spacing of 0 look like a visible gap.
	spacing = self:ClampSpacingSetting(spacing, -14, 16)

	if not spacing then
		return
	end

	ACABDB.microMenuSpacing = spacing

	self:ApplyMicroMenuShape()
end

-- Modeled on Bar.lua's ACAB:SetBarLayout, simplified (no buttonCount concept -
-- Micro Menu's grid always shows all 8 named buttons).
function ACAB:SetMicroMenuLayout(cols, rows)
	self:EnsureDB()

	cols = tonumber(cols)
	rows = tonumber(rows)

	if not cols or not rows then
		return false
	end

	cols = math.floor(cols)
	rows = math.floor(rows)

	if cols < 1 or rows < 1 then
		return false
	end

	if cols * rows > table.getn(self.MICRO_MENU_BUTTON_NAMES) then
		self:Print("Micro Menu layout cannot exceed " ..
			tostring(table.getn(self.MICRO_MENU_BUTTON_NAMES)) .. " buttons.")
		return false
	end

	ACABDB.microMenuCols = cols
	ACABDB.microMenuRows = rows

	self:ApplyMicroMenuShape()

	return true
end

function ACAB:SetMicroMenuScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.microMenuScale or 1
	local pos = ACABDB.microMenuPosition

	if pos and self.microMenuContainer then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, self.microMenuContainer:GetHeight())
	end

	ACABDB.microMenuScale = scale

	self:ApplyMicroMenuShape()

	if pos then
		self:ApplyMicroMenuPosition()
	end
end

-- Settings.lua's Micro Menu page reset flow calls this alongside
-- ResetMicroMenuPosition (simpleBarPageConfigs["micromenu"].reset).
function ACAB:ResetMicroMenuLayout()
	self:EnsureDB()

	ACABDB.microMenuSpacing = -3
	ACABDB.microMenuScale = 1
	ACABDB.microMenuCols = 8
	ACABDB.microMenuRows = 1

	self:ApplyMicroMenuShape()
end

function ACAB:StartMicroMenuDrag()
	local pos = ACABDB.microMenuPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "microMenu"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopMicroMenuDrag()
	self:StopSharedDrag()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("micromenu")
	end
end

-------------------------------------------------------------------------
-- Build both containers (called once at PLAYER_LOGIN, Core.lua)
--
-- Idempotent via self.bagBarContainer/microMenuContainer nil-checks.
-- Degrades gracefully (that element simply isn't built this session) if
-- any of its real button frames are missing.
-------------------------------------------------------------------------

function ACAB:CreateBagBarAndMicroMenu()
	self:EnsureDB()

	if not self.bagBarContainer then
		local buttons = self:GetButtonsByName(self.BAG_BAR_BUTTON_NAMES)

		if buttons then
			self:SortButtonsByNativeLeft(buttons)

			local container, nativeLeft, nativeTop, nativeSpacing =
				self:BuildChainAnchoredContainer("ACABBagBarContainer", buttons)

			self.bagBarContainer = container
			self.bagBarButtons = buttons

			-- Same TOPLEFT/BOTTOMLEFT-of-UIParent convention as
			-- ACAB:CaptureNativeAnchor (Database.lua) - nativeLeft/nativeTop here are already
			-- the real-screen-pixel-converted values
			-- BuildChainAnchoredContainer returns, not a raw
			-- GetLeft()/GetTop() copy, so no further translation is needed.
			if not ACABDB.bagBarNativeAnchor then
				ACABDB.bagBarNativeAnchor = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			if not ACABDB.bagBarPosition then
				ACABDB.bagBarPosition = {
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
			if not ACABDB.bagBarNativeSpacing then
				ACABDB.bagBarNativeSpacing = nativeSpacing
			end

			if not ACABDB.bagBarSpacing then
				ACABDB.bagBarSpacing = nativeSpacing
			end

			-- Lays out the chain from the (freshly seeded, or previously
			-- saved) spacing/orientation/scale before ApplyBagBarPosition
			-- below, so the container's real size is already correct.
			self:ApplyBagBarShape()

			self:ApplyBagBarPosition()
			self:SetBagBarEnabled(ACABDB.bagBarEnabled ~= false)
		end
	end

	if not self.microMenuContainer then
		local buttons = self:GetButtonsByName(self.MICRO_MENU_BUTTON_NAMES)

		if buttons then
			self:SortButtonsByNativeLeft(buttons)

			local container, nativeLeft, nativeTop, nativeSpacing =
				self:BuildChainAnchoredContainer("ACABMicroMenuContainer", buttons)

			self.microMenuContainer = container
			self.microMenuButtons = buttons

			-- Same external-re-anchor bug class as the Cast Bar/Latency Bar
			-- (InstallReanchorGuard's own comment above) - live-confirmed on
			-- QuestLogMicroButton stretching from its Micro Menu position up
			-- toward its native default one. Every one of these 8 real
			-- buttons is a native frame native code could re-anchor, so all
			-- 8 get guarded, not just the one that's been seen so far.
			do
				local guardIndex

				for guardIndex = 1, table.getn(buttons) do
					self:InstallReanchorGuard(buttons[guardIndex], "ACABApplyingMicroMenuPosition")
				end
			end

			-- Extra top-only overlay trim beyond the buttons' own real
			-- GetHitRectInsets() - see ACAB.MICRO_MENU_OVERLAY_TOP_FUDGE's
			-- own comment (Core.lua). Read generically by
			-- EnsureContainerOverlay/ApplyChainAnchoredShape's overlay
			-- anchors via container.overlayTopFudge (nil/0 for every other
			-- chain-anchored container - Bag Bar, Stance Bar).
			container.overlayTopFudge = self.MICRO_MENU_OVERLAY_TOP_FUDGE

			if not ACABDB.microMenuNativeAnchor then
				ACABDB.microMenuNativeAnchor = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			if not ACABDB.microMenuPosition then
				ACABDB.microMenuPosition = {
					point = "TOPLEFT",
					relativePoint = "BOTTOMLEFT",
					x = nativeLeft,
					y = nativeTop,
				}
			end

			if not ACABDB.microMenuNativeSpacing then
				ACABDB.microMenuNativeSpacing = nativeSpacing
			end

			-- Fixed default of -3 (slider position 1, see the +4 display
			-- offset in simpleBarPageConfigs["micromenu"]) rather than the
			-- measured native gap - see ACAB:SetMicroMenuSpacing's own comment.
			if not ACABDB.microMenuSpacing then
				ACABDB.microMenuSpacing = -3
			end

			self:ApplyMicroMenuShape()

			self:ApplyMicroMenuPosition()
			self:SetMicroMenuEnabled(ACABDB.microMenuEnabled ~= false)
		end
	end
end

-- UpdateMicroButtons is real vanilla FrameXML's own global function that
-- decides TalentMicroButton's (and other conditionally-hidden buttons')
-- Show()/Hide() state. Hooked directly so ApplyMicroMenuShape's grid-
-- compaction loop reacts the instant Blizzard's own code changes a
-- button's shown state - e.g. a newly-unlocked Talent button reclaims a
-- cell instead of staying collapsed out.
if hooksecurefunc and UpdateMicroButtons then
	hooksecurefunc("UpdateMicroButtons", function()
		ACAB:ApplyMicroMenuShape()
	end)
end

-------------------------------------------------------------------------
-- Key Ring
--
-- KeyRingButton is confirmed to exist as a real global frame on this
-- client (not present in true vanilla 1.12.0). Deliberately not added to
-- BAG_BAR_BUTTON_NAMES/the Bag Bar's own chain - independently toggleable
-- and positionable, not just another chained member. Repositioned
-- directly via PixelSetPoint on itself, the same single-real-frame
-- treatment ApplyStanceBarPosition uses for ShapeshiftBarFrame.
--
-- Every function below no-ops if KeyRingButton doesn't exist on some
-- other client build.
-------------------------------------------------------------------------

ACAB.KEYRING_BUTTON_NAME = "KeyRingButton"

ACAB:InstallShowGuard(getglobal(ACAB.KEYRING_BUTTON_NAME), function()
	return ACABDB and ACABDB.keyRingEnabled ~= false
end)

-- Mirrors CaptureLatencyBarPositionIfNeeded below exactly - captured
-- lazily the first time it's actually needed, never at normal EnsureDB
-- seed time, since it can only be read from the real live frame.
function ACAB:CaptureKeyRingPositionIfNeeded()
	self:EnsureDB()

	if ACABDB.keyRingPosition then
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

	-- KeyRingButton is part of the MainMenuBar cluster, which can have a
	-- different effective scale than UIParent, so an unconverted capture
	-- would be wrong by that scale factor (same conversion as
	-- ACAB:CaptureExpBarPositionIfNeeded).
	local frameScale = frame:GetEffectiveScale()
	local uiParentScale = UIParent:GetEffectiveScale()

	local x, y = left, top

	if frameScale and uiParentScale and uiParentScale ~= 0 then
		x = (left * frameScale) / uiParentScale
		y = (top * frameScale) / uiParentScale
	end

	local anchor = {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = x,
		y = y,
	}

	ACABDB.keyRingPosition = anchor

	-- Permanent pristine snapshot (Reset to Blizzard Default) - stores the
	-- frame's true native anchor via GetPoint(1) rather than an absolute
	-- snapshot, since native code anchors this frame relative to another
	-- real frame, not UIParent (see CaptureLatencyBarPositionIfNeeded's
	-- own comment). ResetKeyRingPosition re-derives a normal absolute
	-- keyRingPosition from this. Captured ONCE, never rewritten.
	if not ACABDB.keyRingNativeAnchor then
		local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)

		if point and relativePoint and x and y then
			local relativeToName = "UIParent"

			if relativeTo and relativeTo.GetName and relativeTo:GetName() then
				relativeToName = relativeTo:GetName()
			end

			ACABDB.keyRingNativeAnchor = {
				point = point,
				relativeTo = relativeToName,
				relativePoint = relativePoint,
				x = x,
				y = y,
			}
		end
	end
end

-- Applies ACABDB.keyRingPosition to the real KeyRingButton, and
-- ensures its drag/right-click overlay exists - mirrors
-- ApplyBagBarPosition's structure, against KeyRingButton itself instead
-- of a synthetic container. EnsureContainerOverlay is called whenever
-- `frame` exists, independent of whether a saved/native position is
-- available yet.
function ACAB:ApplyKeyRingPosition()
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

	local pos = ACABDB.keyRingPosition

	if pos then
		frame:ClearAllPoints()
		self:PixelSetPoint(
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
	self:EnsureContainerOverlay(frame, self.StartKeyRingDrag, self.StopKeyRingDrag, "bagbar", self.SetKeyRingScale, 150, "Key Ring")

	-- Shares the Bag Bar's own hoverOnly/hoverDuration fields; no separate Key Ring setting.
	self:ApplyHoverOnlyState(frame, ACABDB.bagBarHoverOnly, function() return ACABDB.bagBarHoverDuration or 3 end)
end

-- Settings.lua's Bag Bar page "Show Key Ring" checkbox writes through
-- this - independent of the Bag Bar's own enable flag (the checkbox
-- lives on the Bag Bar page, but this element moves/shows/hides
-- independently of the Bag Bar container itself).
function ACAB:SetKeyRingEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	ACABDB.keyRingEnabled = enabled

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
			if frame.ACABOverlay then
				frame.ACABOverlay:Hide()
				frame.ACABOverlay:EnableMouse(false)
			end
		end
	end
end

function ACAB:SetKeyRingPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.keyRingPosition then
		return
	end

	ACABDB.keyRingPosition.x = x
	ACABDB.keyRingPosition.y = y

	self:ApplyKeyRingPosition()
end

function ACAB:ResetKeyRingPosition()
	self:EnsureDB()

	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	-- Direct write, not SetKeyRingScale(1) - that setter compensates the
	-- stored position using the OLD scale to keep the bottom-left corner
	-- fixed, which would inflate the native position resolved below
	-- instead of leaving it alone. Set BEFORE resolving the native anchor,
	-- so that resolution is measured under the same scale=1 this reset is
	-- restoring to. Mirrors ResetLatencyBarLayout's own exact structure.
	ACABDB.keyRingScale = 1

	if frame then
		frame:SetScale(1)
	end

	local native = ACABDB.keyRingNativeAnchor
	local resolved = self:ResolveNativeAnchorToAbsolute(frame, native)

	if resolved then
		ACABDB.keyRingPosition = resolved
	end

	self:ApplyKeyRingPosition()
end

-- Mirrors SetLatencyBarScale's exact clamp/compensate/write/apply template.
function ACAB:SetKeyRingScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.keyRingScale or 1
	local pos = ACABDB.keyRingPosition
	local frame = getglobal(self.KEYRING_BUTTON_NAME)

	if pos and frame then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, frame:GetHeight())
	end

	ACABDB.keyRingScale = scale

	if frame then
		frame:SetScale(scale)
	end

	if pos then
		self:ApplyKeyRingPosition()
	end
end

function ACAB:StartKeyRingDrag()
	self:CaptureKeyRingPositionIfNeeded()

	local pos = ACABDB.keyRingPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "keyRing"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopKeyRingDrag()
	self:StopSharedDrag()
end

-------------------------------------------------------------------------
-- Latency Bar
--
-- MainMenuBarPerformanceBarFrame is a single self-contained frame and a
-- direct SIBLING of MainMenuBarArtFrame under MainMenuBar, NOT a child of
-- it - so ACAB:ApplyBlizzardArtVisibility's region-hiding never touches
-- it, and it needs its own fully independent enable/scale/position
-- treatment (one native frame we don't own the shape of, not a container
-- we build).
-------------------------------------------------------------------------

ACAB.LATENCY_BAR_FRAME_NAME = "MainMenuBarPerformanceBarFrame"

ACAB:InstallReanchorGuard(getglobal(ACAB.LATENCY_BAR_FRAME_NAME), "ACABApplyingLatencyBarPosition")

-- Mirrors CaptureKeyRingPositionIfNeeded above exactly.
function ACAB:CaptureLatencyBarPositionIfNeeded()
	self:EnsureDB()

	if ACABDB.latencyBarPosition then
		return
	end

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if not frame then
		return
	end

	-- Permanent pristine snapshot (Reset to Blizzard Default) - stores the
	-- frame's true native anchor via GetPoint(1) rather than an absolute
	-- snapshot, since native code re-anchors this frame relative to
	-- another real frame, not UIParent (confirmed: BOTTOMRIGHT of
	-- MainMenuBar, -235,-10). Captured ONCE, never rewritten.
	if not ACABDB.latencyBarNativeAnchor then
		local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)

		if point and relativePoint and x and y then
			local relativeToName = "UIParent"

			if relativeTo and relativeTo.GetName and relativeTo:GetName() then
				relativeToName = relativeTo:GetName()
			end

			ACABDB.latencyBarNativeAnchor = {
				point = point,
				relativeTo = relativeToName,
				relativePoint = relativePoint,
				x = x,
				y = y,
			}
		end
	end

	-- Derives the initial absolute position from the relative native
	-- anchor above (ResolveNativeAnchorToAbsolute, DefaultBars.lua) instead
	-- of a raw GetLeft()/GetTop() read - the same resolution
	-- ResetLatencyBarLayout uses, since a raw read this early in login can
	-- catch MainMenuBar's own layout before it's actually settled, while
	-- the relative anchor (and ResolveNativeAnchorToAbsolute's preference
	-- for InstallReanchorGuard's freshest swallowed attempt) doesn't.
	local resolved = self:ResolveNativeAnchorToAbsolute(frame, ACABDB.latencyBarNativeAnchor, "ACABApplyingLatencyBarPosition")

	if resolved then
		ACABDB.latencyBarPosition = resolved
	end
end

-- Applies ACABDB.latencyBarPosition to the real frame, and ensures
-- its drag/right-click overlay exists - mirrors ACAB:ApplyKeyRingPosition
-- above, just against MainMenuBarPerformanceBarFrame instead of
-- KeyRingButton (EnsureContainerOverlay is equally generic over either),
-- including the same "always build the overlay, only conditionally apply
-- the captured position" structure.
function ACAB:ApplyLatencyBarPosition()
	self:CaptureLatencyBarPositionIfNeeded()

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local pos = ACABDB.latencyBarPosition

	if pos then
		frame.ACABApplyingLatencyBarPosition = true

		frame:ClearAllPoints()
		self:PixelSetPoint(
			frame,
			pos.point or "TOPLEFT",
			UIParent,
			pos.relativePoint or "BOTTOMLEFT",
			pos.x or 0,
			pos.y or 0
		)

		frame.ACABApplyingLatencyBarPosition = nil
	end

	frame.overlayInset = self.LATENCY_BAR_OVERLAY_INSET

	self:EnsureContainerOverlay(frame, self.StartLatencyBarDrag, self.StopLatencyBarDrag, "latencybar", self.SetLatencyBarScale, nil, "Latency Bar")

	self:ApplyHoverOnlyState(frame, ACABDB.latencyBarHoverOnly, function() return ACABDB.latencyBarHoverDuration or 3 end)
end

function ACAB:SetLatencyBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.latencyBarPosition then
		return
	end

	ACABDB.latencyBarPosition.x = x
	ACABDB.latencyBarPosition.y = y

	self:ApplyLatencyBarPosition()
end

function ACAB:SetLatencyBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	ACABDB.latencyBarEnabled = enabled

	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if frame then
		if enabled then
			frame:Show()
		else
			frame:Hide()

			-- Same explicit-hide requirement as SetKeyRingEnabled above.
			if frame.ACABOverlay then
				frame.ACABOverlay:Hide()
				frame.ACABOverlay:EnableMouse(false)
			end
		end
	end
end

-- Mirrors SetCastBarScale's exact clamp/compensate/write/apply template.
function ACAB:SetLatencyBarScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.latencyBarScale or 1
	local pos = ACABDB.latencyBarPosition
	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	if pos and frame then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, frame:GetHeight())
	end

	ACABDB.latencyBarScale = scale

	if frame then
		frame:SetScale(scale)
	end

	if pos then
		self:ApplyLatencyBarPosition()
	end
end

-- Settings.lua's Latency Bar page "Only show on hover" checkbox/slider.
function ACAB:SetLatencyBarHoverOnly(enabled)
	self:EnsureDB()

	ACABDB.latencyBarHoverOnly = enabled and true or false

	self:ApplyLatencyBarPosition()
end

function ACAB:SetLatencyBarHoverDuration(duration)
	self:EnsureDB()

	duration = self:ClampHoverDuration(duration)

	if not duration then
		return
	end

	ACABDB.latencyBarHoverDuration = duration

	self:ApplyLatencyBarPosition()
end

-- Settings.lua's Latency Bar page "Reset to Blizzard Default" button -
-- restores position AND scale in one call (unlike the Stance Bar's own
-- two separate Reset* calls), since Settings.lua's simple-bar-page
-- config only ever wires one `reset` function per element.
function ACAB:ResetLatencyBarLayout()
	local native = ACABDB.latencyBarNativeAnchor
	local frame = getglobal(self.LATENCY_BAR_FRAME_NAME)

	-- Direct write, not SetLatencyBarScale(1) - that setter compensates
	-- the stored position using the OLD scale to keep the bottom-left
	-- corner fixed, which would inflate the native position we're about
	-- to restore below instead of leaving it alone. Set BEFORE resolving
	-- the native anchor to an absolute position, so that resolution is
	-- measured under the same scale=1 this reset is restoring to.
	ACABDB.latencyBarScale = 1

	if frame then
		frame:SetScale(1)
	end

	local resolved = self:ResolveNativeAnchorToAbsolute(frame, native, "ACABApplyingLatencyBarPosition")

	if resolved then
		ACABDB.latencyBarPosition = resolved
	end

	self:ApplyLatencyBarPosition()
end

function ACAB:StartLatencyBarDrag()
	self:CaptureLatencyBarPositionIfNeeded()

	local pos = ACABDB.latencyBarPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "latencyBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopLatencyBarDrag()
	self:StopSharedDrag()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("latencybar")
	end
end

-------------------------------------------------------------------------
-- Cast Bar (CastingBarFrame) - single native frame, no Spacing/
-- Orientation/Enable, same Position/Scale/Reset/Drag treatment as the
-- Latency Bar/Experience Bar above.
-------------------------------------------------------------------------

ACAB.CAST_BAR_FRAME_NAME = "CastingBarFrame"

ACAB:InstallReanchorGuard(getglobal(ACAB.CAST_BAR_FRAME_NAME), "ACABApplyingCastBarPosition")

-- Mirrors CaptureLatencyBarPositionIfNeeded exactly.
function ACAB:CaptureCastBarPositionIfNeeded()
	self:EnsureDB()

	if ACABDB.castBarPosition then
		return
	end

	local frame = getglobal(self.CAST_BAR_FRAME_NAME)

	if not frame then
		return
	end

	-- Permanent pristine snapshot (Reset to Blizzard Default) - stores
	-- the frame's TRUE native anchor via GetPoint(1) rather than an
	-- absolute snapshot - see CaptureLatencyBarPositionIfNeeded's own
	-- comment for why. Captured ONCE, never written to again by anything
	-- else in this file.
	if not ACABDB.castBarNativeAnchor then
		local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)

		if point and relativePoint and x and y then
			local relativeToName = "UIParent"

			if relativeTo and relativeTo.GetName and relativeTo:GetName() then
				relativeToName = relativeTo:GetName()
			end

			ACABDB.castBarNativeAnchor = {
				point = point,
				relativeTo = relativeToName,
				relativePoint = relativePoint,
				x = x,
				y = y,
			}
		end
	end

	-- Derives the initial absolute position from the relative native
	-- anchor above (ResolveNativeAnchorToAbsolute, DefaultBars.lua) instead
	-- of a raw GetLeft()/GetTop() read - see CaptureLatencyBarPositionIfNeeded's
	-- own comment for why.
	local resolved = self:ResolveNativeAnchorToAbsolute(frame, ACABDB.castBarNativeAnchor, "ACABApplyingCastBarPosition")

	if resolved then
		ACABDB.castBarPosition = resolved
	end
end

-- Mirrors ACAB:ApplyLatencyBarPosition exactly, minus the Enable branch.
function ACAB:ApplyCastBarPosition()
	self:CaptureCastBarPositionIfNeeded()

	local frame = getglobal(self.CAST_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local pos = ACABDB.castBarPosition

	if pos then
		frame.ACABApplyingCastBarPosition = true

		frame:ClearAllPoints()
		self:PixelSetPoint(
			frame,
			pos.point or "TOPLEFT",
			UIParent,
			pos.relativePoint or "BOTTOMLEFT",
			pos.x or 0,
			pos.y or 0
		)

		frame.ACABApplyingCastBarPosition = nil
	end

	self:EnsureContainerOverlay(frame, self.StartCastBarDrag, self.StopCastBarDrag, "castbar", self.SetCastBarScale, nil, "Cast Bar")
end

function ACAB:SetCastBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.castBarPosition then
		return
	end

	ACABDB.castBarPosition.x = x
	ACABDB.castBarPosition.y = y

	-- User is now positioning this element by hand - stop auto-stacking
	-- its Y off Action Bar 1/2/Extra Bar 1/2/Pet Bar
	-- (ReflowCastBarForStackToggle's own guard).
	ACABDB.castBarUsesDefaultPosition = false

	self:ApplyCastBarPosition()
end

-- Mirrors SetLatencyBarScale's exact clamp/write/apply template.
function ACAB:SetCastBarScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.castBarScale or 1
	local pos = ACABDB.castBarPosition
	local frame = getglobal(self.CAST_BAR_FRAME_NAME)

	if pos and frame then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, frame:GetHeight())
	end

	ACABDB.castBarScale = scale

	if frame then
		frame:SetScale(scale)
	end

	if pos then
		self:ApplyCastBarPosition()
	end
end

-- Mirrors ResetLatencyBarLayout's position+scale bundling.
function ACAB:ResetCastBarLayout()
	local native = ACABDB.castBarNativeAnchor
	local frame = getglobal(self.CAST_BAR_FRAME_NAME)

	-- Direct write, not SetCastBarScale(1) - that setter compensates
	-- the stored position using the OLD scale to keep the bottom-left
	-- corner fixed, which would inflate the native position we're about
	-- to restore below instead of leaving it alone. Set BEFORE resolving
	-- the native anchor to an absolute position, so that resolution is
	-- measured under the same scale=1 this reset is restoring to.
	ACABDB.castBarScale = 1

	if frame then
		frame:SetScale(1)
	end

	local resolved = self:ResolveNativeAnchorToAbsolute(frame, native, "ACABApplyingCastBarPosition")

	if resolved then
		ACABDB.castBarPosition = resolved

		-- Stale floor would otherwise keep stacking off the pre-reset
		-- position - re-capture it fresh from the just-restored native spot.
		ACABDB.castBarStackBaseY = resolved.y
	end

	ACABDB.castBarUsesDefaultPosition = true

	self:ApplyCastBarPosition()

	-- Prefer the computed baseline (stacked off Action Bar 1/2/Extra Bar
	-- 1/2/Pet Bar when active, same as GetCastBarBaselineY) over the raw
	-- restored native position - mirrors ResetPetBarNativeLayout's own
	-- unconditional-recompute reasoning exactly (called regardless of
	-- useDefaultLayout there too).
	self:ReflowCastBarForStackToggle()
end

-------------------------------------------------------------------------
-- Cast Bar dynamic stacking (Default Layout mode only)
--
-- Cast Bar starts at its own default Blizzard layout position (the floor
-- below) and moves up by, independently: the buttonSize of Action Bar 1
-- or 2 if either is active, the buttonSize of Extra Bar 1 or 2 if either
-- is active, and Pet Bar's own size if it's active.
-------------------------------------------------------------------------

-- Permanent floor Y for the dynamic stack offset below, captured once from
-- the resolved native/current position - mirrors castBarNativeAnchor's own
-- one-time capture (CaptureCastBarPositionIfNeeded above). Never itself
-- touched by ReflowCastBarForStackToggle; only that function's own output
-- (ACABDB.castBarPosition.y) moves, always recomputed fresh off this floor
-- so repeated toggles never compound.
function ACAB:CaptureCastBarStackBaseYIfNeeded()
	self:EnsureDB()

	if ACABDB.castBarStackBaseY then
		return
	end

	self:CaptureCastBarPositionIfNeeded()

	local pos = ACABDB.castBarPosition

	if pos and pos.y then
		ACABDB.castBarStackBaseY = pos.y
	end
end

-- baselineY = floor (default Blizzard layout position) + Action Bar
-- 1/2's buttonSize (whichever is active; max of the two if both are) +
-- Extra Bar 1/2's buttonSize (same rule) + Pet Bar's own live height (if
-- actually shown right now). Action Bar 1/2 and Extra Bar 1/2 each use
-- max, not sum, since they're side-by-side pairs at the same tier - only
-- one shared Cast Bar position needs to clear whichever side is taller.
function ACAB:GetCastBarBaselineY()
	self:CaptureCastBarStackBaseYIfNeeded()

	local baseY = ACABDB.castBarStackBaseY

	if not baseY then
		return nil
	end

	local bar2Cfg = ACABDB.defaultBars and ACABDB.defaultBars[2]
	local bar3Cfg = ACABDB.defaultBars and ACABDB.defaultBars[3]
	local actionBarPitch = 0

	if bar2Cfg and bar2Cfg.enabled and (bar2Cfg.buttonSize or 0) > actionBarPitch then
		actionBarPitch = bar2Cfg.buttonSize
	end

	if bar3Cfg and bar3Cfg.enabled and (bar3Cfg.buttonSize or 0) > actionBarPitch then
		actionBarPitch = bar3Cfg.buttonSize
	end

	local extra1 = self.bars and self.bars[self.EXTRA_BAR_ID_START]
	local extra2 = self.bars and self.bars[self.EXTRA_BAR_ID_START + 1]
	local extraBarPitch = 0

	-- usesDefaultPosition == false - the user dragged/slider-moved that
	-- Extra Bar away from its seeded slot, so it no longer counts here
	-- either (mirrors GetExtraBarStackPitch's own same-named guard).
	if extra1 and extra1.config and extra1.config.enabled
		and extra1.config.usesDefaultPosition ~= false
		and (extra1.config.buttonSize or 0) > extraBarPitch then
		extraBarPitch = extra1.config.buttonSize
	end

	if extra2 and extra2.config and extra2.config.enabled
		and extra2.config.usesDefaultPosition ~= false
		and (extra2.config.buttonSize or 0) > extraBarPitch then
		extraBarPitch = extra2.config.buttonSize
	end

	local petPitch = 0
	local petContainer = self.petBarNativeContainer

	if petContainer and petContainer:IsShown() then
		petPitch = petContainer:GetHeight() or 0
	end

	return baseY + actionBarPitch + extraBarPitch + petPitch
end

-- Only called while useDefaultLayout ~= false - mirrors
-- ReflowStanceBarForBar2Toggle/ReflowPetBarForBar3Toggle's own guard, so
-- this never fights the user's own manually dragged position once they
-- switch to a custom layout. Also a no-op once
-- ACABDB.castBarUsesDefaultPosition is false - the user has since moved
-- this element themselves (settings slider or edit-mode drag).
function ACAB:ReflowCastBarForStackToggle()
	self:EnsureDB()

	if ACABDB.castBarUsesDefaultPosition == false then
		return
	end

	local pos = ACABDB.castBarPosition
	local y = self:GetCastBarBaselineY()

	if not pos or not y then
		return
	end

	pos.y = y

	self:ApplyCastBarPosition()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("castbar")
	end
end

function ACAB:StartCastBarDrag()
	self:CaptureCastBarPositionIfNeeded()

	local pos = ACABDB.castBarPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "castBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopCastBarDrag()
	self:StopSharedDrag()

	-- User just moved this element by hand - stop auto-stacking its Y
	-- (same flag SetCastBarPosition flips for the settings-page sliders).
	ACABDB.castBarUsesDefaultPosition = false

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("castbar")
	end
end


-------------------------------------------------------------------------
-- Page Indicator (chain-anchored container)
--
-- Wraps the Main Bar's native page-turn arrows/page-number FontString the
-- same way Bag Bar/Micro Menu/Stance Bar wrap real Blizzard frames above.
-- MainMenuBarPageNumber (a FontString) supports GetLeft/GetTop/GetWidth/
-- GetHeight/SetParent/IsShown/SetPoint like a Frame/Button region, except
-- GetEffectiveScale - see PixelSetPoint's own comment for the fallback.
--
-- ActionBarUpButton/ActionBarDownButton/MainMenuBarPageNumber are the
-- real vanilla 1.12.1 FrameXML names, but - unlike every other frame name
-- this file relies on - these three have not been live-confirmed on this
-- specific modded client. CreatePageIndicatorContainer requires all
-- three to resolve (a partial page indicator would be visually broken,
-- not a healthy smaller variant) - a wrong/missing name just silently
-- never builds this container.
--
-- Position + Scale only. Orientation is fixed vertical (up/down arrows +
-- page number are a vertical stack), and spacing is fixed at 0 rather
-- than auto-captured (ComputeMajorityGap only measures a horizontal gap) -
-- a cosmetic simplification; the container is still fully draggable/
-- scalable to compensate.
-------------------------------------------------------------------------

ACAB.PAGE_INDICATOR_UP_NAME = "ActionBarUpButton"
ACAB.PAGE_INDICATOR_DOWN_NAME = "ActionBarDownButton"
ACAB.PAGE_INDICATOR_TEXT_NAME = "MainMenuBarPageNumber"

-- This container isn't a single row/column of same-size elements chained
-- edge-to-edge - it's two stacked arrow buttons plus a text label sitting
-- to their right, vertically centered. BuildChainAnchoredContainer/
-- ApplyChainAnchoredShape can't express that, so this container has its
-- own dedicated layout (CreatePageIndicatorContainer/ApplyPageIndicatorShape
-- below) - only the internal up/down/text arrangement is custom; external
-- position/scale/enable behavior is unchanged.
function ACAB:CreatePageIndicatorContainer()
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

	-- Reads each element's real native anchor point (GetPoint(1), which
	-- the FontString supports unlike GetEffectiveScale) before
	-- reparenting anything. SetParent never rewrites another frame's own
	-- anchor points, so if Down/Text are natively anchored directly to Up
	-- (or each other), that anchor stays correct with no reconstruction
	-- needed regardless of what their parent becomes.
	local upPoint, upRelTo, upRelPoint, upX, upY = up:GetPoint(1)
	local downPoint, downRelTo, downRelPoint, downX, downY = down:GetPoint(1)
	local textPoint, textRelTo, textRelPoint, textX, textY = text:GetPoint(1)

	-- The container's own TOPLEFT is defined to equal Up's real native
	-- TOPLEFT (GetLeft()/GetTop()), converted through real screen pixels
	-- via each frame's own GetEffectiveScale, the same conversion as
	-- ACAB:CaptureNativeAnchor (Database.lua) (this container, like every default
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
	-- captured GetPoint() data, not assumed. If a captured relativeTo
	-- isn't one of the other two elements in this trio, falls back to
	-- reproducing the real on-screen delta from Up's own native corner
	-- (same-family measurement, no GetEffectiveScale correction needed,
	-- unlike nativeLeft/nativeTop above).
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

	local container = CreateFrame("Frame", "ACABPageIndicatorContainer", UIParent)
	container:SetFrameStrata("HIGH")

	up:SetParent(container)
	down:SetParent(container)
	text:SetParent(container)

	self.pageIndicatorContainer = container
	self.pageIndicatorUp = up
	self.pageIndicatorDown = down
	self.pageIndicatorText = text

	if not ACABDB.mainBarPageIndicatorNativeAnchor then
		ACABDB.mainBarPageIndicatorNativeAnchor = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	if not ACABDB.mainBarPageIndicatorPosition then
		ACABDB.mainBarPageIndicatorPosition = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = nativeLeft,
			y = nativeTop,
		}
	end

	self:ApplyPageIndicatorShape()
	self:ApplyPageIndicatorPosition()
	self:ApplyPageIndicatorVisibility()
end

-- Up is always reanchored to the container's own TOPLEFT (it's the one
-- frame this addon's drag/position system moves the whole container by).
-- Down and the page-number text use the real native relationship
-- CreatePageIndicatorContainer captured via GetPoint():
--   - If natively anchored directly to Up (or, for Text, to Down) - left
--     untouched, since SetParent never rewrote that anchor.
--   - Otherwise, reproduced as a TOPLEFT-of-container offset using the
--     real screen-space delta from Up's own native corner, captured at
--     the same time.
-- Either way this reuses Blizzard's own already-correct relative layout.
function ACAB:ApplyPageIndicatorShape()
	local container = self.pageIndicatorContainer
	local up = self.pageIndicatorUp
	local down = self.pageIndicatorDown
	local text = self.pageIndicatorText

	if not container or not up or not down or not text then
		return
	end

	up:ClearAllPoints()
	self:PixelSetPoint(up, "TOPLEFT", container, "TOPLEFT", 0, 0)

	if not self.pageIndicatorDownFollowsUp then
		down:ClearAllPoints()
		self:PixelSetPoint(
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
		self:PixelSetPoint(
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

	self:PixelSetSize(container, width, height)

	container:SetScale(ACABDB.mainBarPageIndicatorScale or 1)
end

function ACAB:ApplyPageIndicatorPosition()
	local pos = ACABDB.mainBarPageIndicatorPosition
	local container = self.pageIndicatorContainer

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

	-- settingsKey = 1 (not a "simple bar page" string key like Bag Bar/
	-- Micro Menu/Stance Bar/Latency Bar use) - this element has no page of
	-- its own; its Scale slider lives directly on the Main Bar's (bar 1's)
	-- own settings page (Settings.lua), so a right-click opens that page
	-- instead.
	self:EnsureContainerOverlay(
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
function ACAB:SetPageIndicatorScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	ACABDB.mainBarPageIndicatorScale = scale

	if self.pageIndicatorContainer then
		self.pageIndicatorContainer:SetScale(scale)
	end
end

-- Mirrors ResetKeyRingPosition's exact structure: restore position from
-- the permanent mainBarPageIndicatorNativeAnchor snapshot (captured once
-- in CreatePageIndicatorContainer, never re-derived), then reset scale
-- to 1 via the existing setter.
function ACAB:ResetPageIndicatorLayout()
	self:EnsureDB()

	local native = ACABDB.mainBarPageIndicatorNativeAnchor

	if native then
		ACABDB.mainBarPageIndicatorPosition = {
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
-- from ACABDB.mainBarPaginationEnabled, per the feature's own spec
-- ("hidden entirely otherwise").
function ACAB:ApplyPageIndicatorVisibility()
	local container = self.pageIndicatorContainer

	if not container then
		return
	end

	if ACABDB.mainBarPaginationEnabled ~= false then
		container:Show()
	else
		container:Hide()
	end
end

function ACAB:StartPageIndicatorDrag()
	local pos = ACABDB.mainBarPageIndicatorPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "pageIndicator"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopPageIndicatorDrag()
	self:StopSharedDrag()

	-- The Scale slider lives on the Main Bar's own settings page (barId
	-- 1) - see Settings.lua's GetOrCreateBarPage - since this element has
	-- no "simple bar page" of its own the way Bag Bar/Micro Menu/Stance
	-- Bar/Latency Bar do.
	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage(1)
	end
end

-------------------------------------------------------------------------
-- Tooltip (synthetic container, redirects the fixed-position GameTooltip)
--
-- No real Blizzard frame to wrap - like Page Indicator, this is a bare
-- CreateFrame with a representative size, moved/scaled through the same
-- position/scale/enable/drag family every other native element uses.
-- Repositions ONLY the fixed-position GameTooltip (quest log rows, NPC
-- hover, exp bar, reputation/friends/guild rows, Micro Menu buttons) via
-- a hooksecurefunc on GameTooltip_SetDefaultAnchor - widget-relative
-- tooltips (action bar buttons, bag items, character item slots) never
-- call that function and stay untouched.
-------------------------------------------------------------------------

ACAB.TOOLTIP_FRAME_WIDTH = 200
ACAB.TOOLTIP_FRAME_HEIGHT = 100

-- Creates the synthetic frame once and lazily seeds ACABDB.tooltipPosition
-- from the real native corner GameTooltip_SetDefaultAnchor always ends up
-- at (BOTTOMRIGHT of UIParent, -103/125), converted to this addon's
-- TOPLEFT-of-frame/BOTTOMLEFT-of-UIParent convention.
function ACAB:EnsureTooltipFrame()
	self:EnsureDB()

	if self.tooltipFrame then
		return
	end

	local frame = CreateFrame("Frame", "ACABTooltipFrame", UIParent)

	self:PixelSetSize(frame, self.TOOLTIP_FRAME_WIDTH, self.TOOLTIP_FRAME_HEIGHT)

	self.tooltipFrame = frame

	if not ACABDB.tooltipPosition then
		local screenWidth = GetScreenWidth() or 1024

		ACABDB.tooltipPosition = {
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = screenWidth - 103 - self.TOOLTIP_FRAME_WIDTH,
			y = 125 + self.TOOLTIP_FRAME_HEIGHT,
		}
	end
end

-- Applies ACABDB.tooltipPosition to the synthetic frame and ensures its
-- drag/right-click overlay exists.
function ACAB:ApplyTooltipPosition()
	self:EnsureTooltipFrame()

	local pos = ACABDB.tooltipPosition
	local frame = self.tooltipFrame

	if not pos or not frame then
		return
	end

	frame:ClearAllPoints()
	self:PixelSetPoint(
		frame,
		pos.point or "TOPLEFT",
		UIParent,
		pos.relativePoint or "BOTTOMLEFT",
		pos.x or 0,
		pos.y or 0
	)

	self:EnsureContainerOverlay(frame, self.StartTooltipDrag, self.StopTooltipDrag, "tooltip", self.SetTooltipScale, nil, "Tooltip")
end

-- Settings.lua's Tooltip page X/Y sliders write through this.
function ACAB:SetTooltipPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.tooltipPosition then
		return
	end

	ACABDB.tooltipPosition.x = x
	ACABDB.tooltipPosition.y = y

	self:ApplyTooltipPosition()
end

-- Mirrors SetLatencyBarScale's clamp/compensate/write/apply template, but
-- compensates whichever corner ACABDB.tooltipAnchorCorner currently
-- selects, not a fixed corner - that's the corner GameTooltip actually
-- anchors to (HookGameTooltipDefaultAnchor), so it's the one that must
-- stay visually fixed on screen while scaling.
function ACAB:SetTooltipScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.tooltipScale or 1
	local pos = ACABDB.tooltipPosition
	local frame = self.tooltipFrame

	if pos and frame then
		local corner = ACABDB.tooltipAnchorCorner or "BOTTOMRIGHT"

		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, corner, frame:GetWidth(), frame:GetHeight())
	end

	ACABDB.tooltipScale = scale

	if frame then
		frame:SetScale(scale)
	end

	if pos then
		self:ApplyTooltipPosition()
	end
end

-- Settings.lua's Tooltip page "Grows From" dropdown. Display preference
-- only - takes effect the next time a tooltip is shown, no reposition here.
function ACAB:SetTooltipAnchorCorner(corner)
	self:EnsureDB()

	if corner ~= "TOPLEFT" and corner ~= "TOPRIGHT" and corner ~= "BOTTOMLEFT" and corner ~= "BOTTOMRIGHT" then
		return
	end

	ACABDB.tooltipAnchorCorner = corner
end

-- Settings.lua's Tooltip page enable checkbox (and its bar-list inline
-- checkbox).
function ACAB:SetTooltipEnabled(enabled)
	self:EnsureDB()

	ACABDB.tooltipEnabled = enabled and true or false

	self:ApplyDefaultLayoutEditVisual()
end

-- Settings.lua's Tooltip page "Reset to Blizzard Default" button -
-- recomputes the same native-default conversion EnsureTooltipFrame's lazy
-- seed uses (screen width may have changed since login), position+scale+
-- anchor corner, same scope as every other Reset button.
function ACAB:ResetTooltipLayout()
	self:EnsureDB()

	-- Direct write, not SetTooltipScale(1) - that setter compensates the
	-- stored position using the OLD scale to keep the current anchor
	-- corner fixed, which would shift the fresh default position below
	-- instead of leaving it alone. Mirrors ResetLatencyBarLayout's own
	-- established pattern.
	ACABDB.tooltipScale = 1
	ACABDB.tooltipAnchorCorner = "BOTTOMRIGHT"

	if self.tooltipFrame then
		self.tooltipFrame:SetScale(1)
	end

	local screenWidth = GetScreenWidth() or 1024

	ACABDB.tooltipPosition = {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = screenWidth - 103 - self.TOOLTIP_FRAME_WIDTH,
		y = 125 + self.TOOLTIP_FRAME_HEIGHT,
	}

	self:ApplyTooltipPosition()
end

function ACAB:StartTooltipDrag()
	local pos = ACABDB.tooltipPosition

	if not pos then
		return
	end

	self:StartSharedDrag("tooltip", nil, pos.x or 0, pos.y or 0)
end

function ACAB:StopTooltipDrag()
	self:StopSharedDrag()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("tooltip")
	end
end

-- Redirects every fixed-position GameTooltip call (quest log, NPC hover,
-- exp bar, reputation/friends/guild rows, Micro Menu buttons) onto this
-- addon's own frame. hooksecurefunc on a plain global function fires for
-- ANY tooltip object calling it (e.g. ItemRefTooltip), not just
-- GameTooltip, hence the identity guard below. Widget-relative tooltips
-- (action bar buttons, bag items, character item slots) never call
-- GameTooltip_SetDefaultAnchor, so they're unaffected.
function ACAB:HookGameTooltipDefaultAnchor()
	if self.tooltipDefaultAnchorHooked then
		return
	end

	self.tooltipDefaultAnchorHooked = true

	hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip, owner)
		if tooltip ~= GameTooltip then
			return
		end

		if not ACABDB.tooltipEnabled then
			return
		end

		if not ACAB.tooltipFrame then
			return
		end

		local corner = ACABDB.tooltipAnchorCorner or "BOTTOMRIGHT"

		GameTooltip:ClearAllPoints()
		GameTooltip:SetPoint(corner, ACAB.tooltipFrame, corner, 0, 0)
		GameTooltip:SetScale(ACABDB.tooltipScale or 1)
	end)
end

