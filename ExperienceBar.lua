-- ExperienceBar.lua
-- Experience Bar subsystem: position/enable/scale, bar-fill colors, the
-- custom rested-XP overlay/tick/glow-pulse ticker, and the "Better
-- Experience Bar" text overlay. Built on the shared single-native-frame
-- EnsureContainerOverlay/PixelSetPoint/CompensateScaleKeepingCornerFixed/
-- ResolveNativeAnchorToAbsolute engine defined in DefaultBars.lua - this
-- file must load after DefaultBars.lua.

local ACAB = AlternativeClassicActionBars

-------------------------------------------------------------------------
-- Experience Bar
--
-- MainMenuExpBar (the player's XP StatusBar) is structurally the same
-- kind of element as MainMenuBarPerformanceBarFrame: a single self-
-- contained frame whose child regions/frames (MainMenuBarOverlayFrame,
-- ExhaustionLevelFillBar/ExhaustionTick/ExhaustionTickGlow for the
-- "rested" portion) all anchor relative to it, not independently to
-- UIParent - repositioning/scaling this one frame carries the whole
-- native visual along.
--
-- Every accessor is defensively nil-checked via getglobal, so a wrong
-- name on some other client build just means this container never
-- builds, never a hard error.
--
-- Movable/scalable via the same EnsureContainerOverlay treatment as the
-- Latency Bar/Key Ring, always - independent of
-- ACABDB.betterExpBarEnabled (the text overlay further below).
-------------------------------------------------------------------------

ACAB.EXP_BAR_FRAME_NAME = "MainMenuExpBar"

-- The native percent-of-level "XP current / max" label that
-- duplicates/overlaps ACAB:ApplyBetterExpBarVisual's own text overlay
-- lives on a FontString region owned directly by MainMenuBarOverlayFrame,
-- not a separately-named global - there is no MainMenuExpText global on
-- this client. See ACAB:GetNativeExpOverlayText below, which resolves and
-- caches that region (found by GetObjectType(), never a hardcoded index -
-- GetRegions() ordering isn't a documented/stable contract).
ACAB.EXP_OVERLAY_FRAME_NAME = "MainMenuBarOverlayFrame"

-- Resolves MainMenuBarOverlayFrame's own native "XP current / max"
-- FontString region (see EXP_OVERLAY_FRAME_NAME's comment above for why
-- this replaces the old, nonexistent MainMenuExpText target), caching the
-- result on self once found - mirrors this same feature's own
-- self.betterExpBarText lazy-cache further below (ACAB:ApplyBetterExpBarVisual),
-- just for a native region instead of one this addon creates itself.
function ACAB:GetNativeExpOverlayText()
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
ACAB.EXP_RESTED_FRAME_NAME = "ExhaustionLevelFillBar"

-- Mirrors CaptureLatencyBarPositionIfNeeded/CaptureKeyRingPositionIfNeeded
-- structurally, but adds the real-screen-pixel GetEffectiveScale
-- conversion ACAB:CaptureNativeAnchor (Database.lua) uses: MainMenuExpBar is part
-- of the MainMenuBar cluster, which can have a different effective scale
-- than UIParent, so an unconverted capture would be wrong by that scale
-- factor.
function ACAB:CaptureExpBarPositionIfNeeded()
	self:EnsureDB()

	if ACABDB.expBarPosition then
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

	-- MainMenuExpBar is part of the MainMenuBar cluster, which can have a
	-- different effective scale than UIParent, so an unconverted capture
	-- would be wrong by that scale factor.
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

	ACABDB.expBarPosition = anchor

	-- Permanent pristine snapshot (Reset to Blizzard Default) - stores
	-- the frame's TRUE native anchor via GetPoint(1) rather than the
	-- absolute snapshot above - see CaptureLatencyBarPositionIfNeeded's
	-- own comment for why. ResetExpBarLayout applies this once (via
	-- ResolveNativeAnchorToAbsolute) and re-derives a normal absolute
	-- expBarPosition from the result. Captured ONCE, never written to
	-- again by anything else in this file.
	if not ACABDB.expBarNativeAnchor then
		local point, relativeTo, relativePoint, nx, ny = frame:GetPoint(1)

		if point and relativePoint and nx and ny then
			local relativeToName = "UIParent"

			if relativeTo and relativeTo.GetName and relativeTo:GetName() then
				relativeToName = relativeTo:GetName()
			end

			ACABDB.expBarNativeAnchor = {
				point = point,
				relativeTo = relativeToName,
				relativePoint = relativePoint,
				x = nx,
				y = ny,
			}
		end
	end
end

-- MainMenuXPBarTexture0-3 (native race-themed border art) are real
-- Texture regions owned directly by MainMenuExpBar, anchored "BOTTOM" at
-- y=+3, leaving the real y=0-to-+3 strip permanently uncovered (only ever
-- invisible because MainMenuBarArtFrame's own art used to sit beneath it
-- at the bar's fixed native position).
--
-- Covered by a custom-built gradient strip below rather than cloning the
-- native border texture - cloning MainMenuXPBarTexture0-3's
-- texture/GetTexCoord() has failed twice (duplicated bar, then visibly
-- distorted); do not retry that technique without materially new
-- information.
local function EnsureExpBarBottomBorderStrip(frame)
	if frame.ACABBottomBorderStrip then
		return frame.ACABBottomBorderStrip
	end

	-- "OVERLAY": must render on top of the bar's own StatusBar fill - the
	-- bar's native fill texture layer sits below OVERLAY, so drawing here
	-- keeps the strip visible over a full or near-full bar instead of
	-- being painted over by the fill.
	local strip = frame:CreateTexture(nil, "OVERLAY")
	strip:SetTexture("Interface\\Buttons\\WHITE8X8")

	-- BOTTOMLEFT/BOTTOMRIGHT dual anchor: pins the strip to exactly the
	-- bar's own current width and bottom edge, auto-tracking any width
	-- change (grid/layout edits) or ACAB:SetExpBarScale rescale without
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

	frame.ACABBottomBorderStrip = strip

	return strip
end

-- Mirrors ACAB:ApplyLatencyBarPosition exactly.
function ACAB:ApplyExpBarPosition()
	self:CaptureExpBarPositionIfNeeded()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local pos = ACABDB.expBarPosition

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

	self:EnsureContainerOverlay(frame, self.StartExpBarDrag, self.StopExpBarDrag, "expbar", self.SetExpBarScale, nil, "Experience Bar")
	EnsureExpBarBottomBorderStrip(frame)

	-- The rested-glow pulse child texture inherits this frame's alpha automatically, no separate handling needed.
	self:ApplyHoverOnlyState(frame, ACABDB.expBarHoverOnly, function() return ACABDB.expBarHoverDuration or 3 end)
end

function ACAB:SetExpBarPosition(x, y)
	x = tonumber(x)
	y = tonumber(y)

	if not x or not y or not ACABDB.expBarPosition then
		return
	end

	ACABDB.expBarPosition.x = x
	ACABDB.expBarPosition.y = y

	self:ApplyExpBarPosition()
end

-- Mirrors SetLatencyBarEnabled's exact structure - this is a core UI
-- element (default true, Core.lua's EnsureDB), but still independently
-- toggleable off, same as every other element in this family.
function ACAB:SetExpBarEnabled(enabled)
	self:EnsureDB()

	enabled = enabled and true or false

	ACABDB.expBarEnabled = enabled

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if frame then
		if enabled then
			frame:Show()

			-- Reverses the disable-branch's explicit
			-- frame.ACABTextOverlay:Hide() below - unlike frame.ACABOverlay
			-- (an edit-mode-only overlay, re-derived from
			-- ApplyContainerOverlayVisual on the next edit-mode sweep
			-- regardless), the text overlay is not edit-mode-gated -
			-- nothing else in this file would ever re-Show it on its own,
			-- so it must be re-shown here explicitly or the text would
			-- stay invisible forever after a disable/re-enable cycle.
			if frame.ACABTextOverlay then
				frame.ACABTextOverlay:Show()
			end
		else
			frame:Hide()

			-- Same explicit-hide requirement as SetKeyRingEnabled/
			-- SetLatencyBarEnabled above - EnsureContainerOverlay's overlay
			-- is parented to UIParent, not `frame`, so hiding the real frame
			-- alone doesn't cascade to hide the overlay too.
			if frame.ACABOverlay then
				frame.ACABOverlay:Hide()
				frame.ACABOverlay:EnableMouse(false)
			end

			-- Same cascade problem, same fix, for the "Better Experience
			-- Bar" text's own overlay frame (EnsureExpBarTextOverlay,
			-- further below) - it's also parented to UIParent (not
			-- `frame`), so without this it would keep floating on screen
			-- at MainMenuExpBar's last tracked position even after the
			-- Experience Bar itself is disabled.
			if frame.ACABTextOverlay then
				frame.ACABTextOverlay:Hide()
			end
		end
	end
end

-- Mirrors SetLatencyBarScale/SetKeyRingScale's exact clamp/write/apply
-- template.
function ACAB:SetExpBarScale(scale)
	self:EnsureDB()

	scale = self:ClampScaleSetting(scale)

	if not scale then
		return
	end

	local oldScale = ACABDB.expBarScale or 1
	local pos = ACABDB.expBarPosition
	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if pos and frame then
		self:CompensateScaleKeepingCornerFixed(pos, oldScale, scale, "BOTTOMLEFT", nil, frame:GetHeight())
	end

	ACABDB.expBarScale = scale

	if frame then
		frame:SetScale(scale)
	end

	if pos then
		self:ApplyExpBarPosition()
	end
end

-- Settings.lua's Experience Bar page "Only show on hover" checkbox/slider.
function ACAB:SetExpBarHoverOnly(enabled)
	self:EnsureDB()

	ACABDB.expBarHoverOnly = enabled and true or false

	self:ApplyExpBarPosition()
end

function ACAB:SetExpBarHoverDuration(duration)
	self:EnsureDB()

	duration = self:ClampHoverDuration(duration)

	if not duration then
		return
	end

	ACABDB.expBarHoverDuration = duration

	self:ApplyExpBarPosition()
end

-- Settings.lua's Experience Bar page "Reset to Blizzard Default" button -
-- restores position AND scale in one call, mirroring
-- ACAB:ResetLatencyBarLayout exactly.
function ACAB:ResetExpBarLayout()
	local native = ACABDB.expBarNativeAnchor
	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	-- Direct write, not SetExpBarScale(1) - that setter compensates
	-- the stored position using the OLD scale to keep the bottom-left
	-- corner fixed, which would inflate the native position we're about
	-- to restore below instead of leaving it alone. Set BEFORE resolving
	-- the native anchor to an absolute position, so that resolution is
	-- measured under the same scale=1 this reset is restoring to.
	ACABDB.expBarScale = 1

	if frame then
		frame:SetScale(1)
	end

	local resolved = self:ResolveNativeAnchorToAbsolute(frame, native)

	if resolved then
		ACABDB.expBarPosition = resolved
	end

	self:ApplyExpBarPosition()
end

function ACAB:StartExpBarDrag()
	self:CaptureExpBarPositionIfNeeded()

	local pos = ACABDB.expBarPosition

	if not pos then
		return
	end

	local cx, cy = self:GetCursorPositionUIScale()

	local frame = self:EnsureDragFrame()

	frame.dragKind = "expBar"
	frame.dragStartCursorX = cx
	frame.dragStartCursorY = cy
	frame.dragStartX = pos.x or 0
	frame.dragStartY = pos.y or 0

	frame:SetScript("OnUpdate", self.DefaultBarDrag_OnUpdate)
	frame:Show()
end

function ACAB:StopExpBarDrag()
	self:StopSharedDrag()

	if self.RefreshBarSettingsPage then
		self:RefreshBarSettingsPage("expbar")
	end
end

-------------------------------------------------------------------------
-- Bar-fill colors
--
-- MainMenuExpBar's StatusBar fill (earned-XP progress) and
-- ExhaustionLevelFillBar's Texture fill (the rested-bonus overlay) are
-- each independently recolorable via Settings.lua's color-picker
-- swatches. Native baseline captured lazily from the live frames rather
-- than seeded in Core.lua's EnsureDB, since GetStatusBarColor()/
-- GetVertexColor() return nothing meaningful until these frames exist.
--
-- ExhaustionLevelFillBar is a Texture, not a StatusBar, so it uses
-- SetVertexColor/GetVertexColor; MainMenuExpBar uses
-- SetStatusBarColor/GetStatusBarColor.
-------------------------------------------------------------------------

function ACAB:CaptureExpBarColorsIfNeeded()
	self:EnsureDB()

	if not ACABDB.expBarColorEarned then
		local frame = getglobal(self.EXP_BAR_FRAME_NAME)
		local r, g, b

		if frame and frame.GetStatusBarColor then
			r, g, b = frame:GetStatusBarColor()
		end

		-- Fallback: a reasonable vanilla-matching purple/violet, only used
		-- if the live frame isn't available yet at capture time.
		ACABDB.expBarColorEarned = {
			r = r or 0.58,
			g = g or 0.0,
			b = b or 0.55,
		}

		-- Permanent pristine snapshot ("Reset Colors to Default"), mirroring
		-- expBarNativeAnchor's own capture-once/never-rewritten pattern
		-- above.
		ACABDB.expBarNativeColorEarned = {
			r = ACABDB.expBarColorEarned.r,
			g = ACABDB.expBarColorEarned.g,
			b = ACABDB.expBarColorEarned.b,
		}
	end

	if not ACABDB.expBarColorRested then
		local restedFrame = getglobal(self.EXP_RESTED_FRAME_NAME)
		local r, g, b

		-- Texture region, not a StatusBar - see EXP_RESTED_FRAME_NAME's own
		-- comment above.
		if restedFrame and restedFrame.GetVertexColor then
			r, g, b = restedFrame:GetVertexColor()
		end

		-- Fallback: real vanilla's own rested-bonus blue.
		ACABDB.expBarColorRested = {
			r = r or 0.0,
			g = g or 0.39,
			b = b or 0.88,
		}

		ACABDB.expBarNativeColorRested = {
			r = ACABDB.expBarColorRested.r,
			g = ACABDB.expBarColorRested.g,
			b = ACABDB.expBarColorRested.b,
		}
	end
end

-- CaptureExpBarColorsIfNeeded only reads the live frames to populate the
-- Settings page's swatch preview, never writes to the frame, so it's
-- harmless regardless of the toggle. When the feature is off, this
-- explicitly reverts both frames to their captured native baseline
-- rather than leaving them untouched, so disabling mid-session actually
-- restores the native color. Called from Core.lua's login sequence, the
-- color-picker's live-preview func/cancelFunc, "Reset Colors to Default",
-- and the "Enable Better Experience Bar" checkbox - the single choke
-- point deciding whether anything happens and which color applies.
function ACAB:ApplyExpBarColors()
	self:CaptureExpBarColorsIfNeeded()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)
	local restedFrame = getglobal(self.EXP_RESTED_FRAME_NAME)

	if not ACABDB.betterExpBarEnabled then
		local nativeEarned = ACABDB.expBarNativeColorEarned
		local nativeRested = ACABDB.expBarNativeColorRested

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

	local earned = ACABDB.expBarColorEarned

	if frame and frame.SetStatusBarColor and earned then
		frame:SetStatusBarColor(earned.r, earned.g, earned.b)
	end

	local rested = ACABDB.expBarColorRested

	-- Texture region, not a StatusBar - see EXP_RESTED_FRAME_NAME's own
	-- comment above.
	if restedFrame and restedFrame.SetVertexColor and rested then
		restedFrame:SetVertexColor(rested.r, rested.g, rested.b)
	end

	self:ApplyExpBarRestedOverlay()
end

-- Settings.lua's color-picker swatches call these directly from
-- ColorPickerFrame.func/cancelFunc.
function ACAB:SetExpBarColorEarned(r, g, b)
	self:CaptureExpBarColorsIfNeeded()

	ACABDB.expBarColorEarned = { r = r, g = g, b = b }

	self:ApplyExpBarColors()
end

function ACAB:SetExpBarColorRested(r, g, b)
	self:CaptureExpBarColorsIfNeeded()

	ACABDB.expBarColorRested = { r = r, g = g, b = b }

	self:ApplyExpBarColors()
end

-- Settings.lua's "Reset Colors to Default" button.
function ACAB:ResetExpBarColors()
	self:CaptureExpBarColorsIfNeeded()

	local nativeEarned = ACABDB.expBarNativeColorEarned
	local nativeRested = ACABDB.expBarNativeColorRested

	if nativeEarned then
		ACABDB.expBarColorEarned = {
			r = nativeEarned.r,
			g = nativeEarned.g,
			b = nativeEarned.b,
		}
	end

	if nativeRested then
		ACABDB.expBarColorRested = {
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
-- Replaces ExhaustionLevelFillBar's own native width, which degenerates
-- to ~8 units wide whenever UnitXP("player") + GetXPExhaustion() exceeds
-- UnitXPMax("player") (a large banked rested pool) - since that width is
-- native-computed, a separate custom Texture is drawn on top instead.
-- Formula ported verbatim from BEB/BEB.lua's own
-- BEB.UpdateElement("BEBRestedXpBar")/"BEBXpBar" branches, which already
-- handle the exceeds-max case correctly.
--
-- Gated on ACABDB.betterExpBarEnabled and GetRestState() == 1 (real
-- vanilla API, 1 = currently resting). When the feature is off this stays
-- hidden and the native ExhaustionLevelFillBar is untouched.
-------------------------------------------------------------------------

local function EnsureExpBarRestedOverlay(frame)
	if frame.ACABRestedOverlay then
		return frame.ACABRestedOverlay
	end

	-- "ARTWORK": renders above MainMenuExpBar's own native StatusBar fill
	-- texture, one tier below "OVERLAY" so ACAB:ApplyBetterExpBarVisual's
	-- own text FontString (created on "OVERLAY" further below) always
	-- stays on top of this overlay's fill instead of being obscured by it.
	local tex = frame:CreateTexture(nil, "ARTWORK")
	tex:SetTexture("Interface\\Buttons\\WHITE8X8")

	frame.ACABRestedOverlay = tex

	return tex
end

-- Rested-XP boundary tick: ports BEB's own custom art (copied verbatim
-- into this addon's Textures/ folder - see BEB_TICK_TEXTURE/
-- BEB_TICK_GLOW_TEXTURE below) and its multi-level-crossing position/
-- texcoord logic (ported from BEB/BEB.lua's own BEB.UpdateElement
-- "BEBRestedXpTick"/"BEBRestedXpTickGlow" branches, in the tick block in
-- ACAB:ApplyExpBarRestedOverlay further below).
--
-- Both are plain Texture regions parented to `frame`/MainMenuExpBar,
-- using draw layers to reproduce BEB's own frame-level ordering: the glow
-- renders on top of the tick. "ARTWORK" (tick) below "OVERLAY" (glow)
-- reproduces that same relative order.

-- BEB/BEB.lua's own BEB.XpPerLvl table, ported verbatim (same literal
-- values, same index-by-level meaning: index N is the XP required to go
-- from level N to level N+1) - ACAB:ApplyExpBarRestedOverlay's own tick-
-- position formula below indexes this the same way BEB's own
-- BEB.UpdateElement("BEBRestedXpTick") does.
ACAB.XP_PER_LEVEL = {
	400, 900, 1400, 2100, 2800, 3600, 4400, 5400, 6500, 7600,
	8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
	25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
	50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
	95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
	153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800, 217400,
}

-- The addon's real installed folder name is "AlternativeClassicActionBars" (the .toc in
-- this repo is AlternativeClassicActionBars.toc), not "ACAB" (only the dev repo/
-- project folder's own name) - these SetTexture paths must resolve
-- against the in-game AddOns folder name.
local BEB_TICK_TEXTURE = "Interface\\AddOns\\AlternativeClassicActionBars\\Textures\\BEB-ExhaustionTicks"
local BEB_TICK_GLOW_TEXTURE = "Interface\\AddOns\\AlternativeClassicActionBars\\Textures\\BEB-ExhaustionTicksGlow"

-- BEB's own default BEBRestedXpTick size (BEB/BEB.lua's own BEBCharSettings
-- defaults: `size = {x=27,y=26}`) - the tick/glow art is a hand-drawn 2x2
-- quadrant sheet (see the texcoord selection in
-- ACAB:ApplyExpBarRestedOverlay below), so its pixel dimensions are tied to
-- that art's own intended aspect ratio, not to MainMenuExpBar's own (much
-- thinner, ~8px) native height - kept as literal constants matching BEB's
-- own default rather than derived from frame:GetHeight().
local BEB_TICK_WIDTH = 27
local BEB_TICK_HEIGHT = 26

local function EnsureExpBarRestedTick(frame)
	if frame.ACABRestedTick then
		return frame.ACABRestedTick, frame.ACABRestedTickGlow
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

	frame.ACABRestedTick = tick
	frame.ACABRestedTickGlow = glow

	return tick, glow
end

-- Rested-XP tick glow pulse: BEB's source has no fade/alpha-animation for
-- BEBRestedXpTickGlow, so this is a fresh looping alpha animation driven
-- by C_Timer.NewTicker (same convention as Button.lua's range ticker/
-- HoverBind.lua's hoverBindTintTicker), not a hand-rolled OnUpdate loop.
-- Only the glow's alpha is animated; the tick texture stays constant.
local EXP_BAR_RESTED_GLOW_PULSE_INTERVAL = 0.05
local EXP_BAR_RESTED_GLOW_PULSE_LOW_ALPHA = 0.35
local EXP_BAR_RESTED_GLOW_PULSE_HIGH_ALPHA = 1.0

-- Full fade-in/fade-out cycle, seconds - customizable via Settings.lua's
-- Experience Bar page Pulse Interval slider
-- (ACABDB.expBarGlowPulseInterval, ACAB:SetExpBarGlowPulseInterval
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
		-- ACABDB.expBarGlowPulseInterval take effect on the very next
		-- tick.
		local period = (ACABDB and ACABDB.expBarGlowPulseInterval)
			or EXP_BAR_RESTED_GLOW_PULSE_PERIOD_DEFAULT

		local t = 0.5 + 0.5 * math.sin(elapsed * ((2 * math.pi) / period))
		local alpha = EXP_BAR_RESTED_GLOW_PULSE_LOW_ALPHA
			+ ((EXP_BAR_RESTED_GLOW_PULSE_HIGH_ALPHA - EXP_BAR_RESTED_GLOW_PULSE_LOW_ALPHA) * t)

		glow:SetAlpha(alpha)
	end)
end

-- Called from ACAB:ApplyExpBarColors (color changes/reverts),
-- ACAB:ApplyBetterExpBarVisual (feature toggled on/off), and Events.lua's
-- betterExpBarEventFrame OnEvent handler - safe to call unconditionally
-- from all of them, the same "single choke point" pattern as
-- ACAB:ApplyExpBarColors.
function ACAB:ApplyExpBarRestedOverlay()
	self:EnsureDB()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	local tex = frame.ACABRestedOverlay
	local tick = frame.ACABRestedTick
	local glow = frame.ACABRestedTickGlow

	if not ACABDB.betterExpBarEnabled or not GetRestState or GetRestState() ~= 1 then
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
	-- by ACAB:SetExpBarScale's frame:SetScale() call - SetScale changes
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

	local color = ACABDB.expBarColorRested

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

	if not level or level < 1 or not ACAB.XP_PER_LEVEL[1] then
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
		if (xp + exhaustion - xpMax) > ACAB.XP_PER_LEVEL[level + 1] then
			position = ((xp + exhaustion - xpMax - ACAB.XP_PER_LEVEL[level + 1]) / ACAB.XP_PER_LEVEL[level + 2]) * barWidth
			restState = 3
		elseif (xp + exhaustion) > xpMax then
			position = ((xp + exhaustion - xpMax) / ACAB.XP_PER_LEVEL[level + 1]) * barWidth
			restState = 2
		else
			position = (xp + exhaustion) * scale
			restState = 1
		end
	elseif level == 59 then
		-- Same 3 states, but the "crosses two levels" case has no level 61
		-- entry in ACAB.XP_PER_LEVEL to measure fractional progress against
		-- (BEB's own table stops at level 60's requirement, i.e. the
		-- level-60-to-61 threshold) - BEB's own source clamps this to the
		-- bar's right edge instead, ported as-is.
		if (xp + exhaustion - xpMax) > ACAB.XP_PER_LEVEL[level + 1] then
			position = barWidth
			restState = 3
		elseif (xp + exhaustion) > xpMax then
			position = ((xp + exhaustion - xpMax) / ACAB.XP_PER_LEVEL[level + 1]) * barWidth
			restState = 2
		else
			position = (xp + exhaustion) * scale
			restState = 1
		end
	else
		-- level == 60 (vanilla cap, only 2 states) - also used as the
		-- fallback for level > 60 (a higher server cap), clamping at the
		-- bar's right edge instead of erroring on a nil position/restState.
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

	-- IsResting() (distinct from GetRestState()) reports whether the
	-- player is standing in a rest area right now: a player who banked
	-- rest XP but has since left the inn keeps GetRestState() == 1 (tick
	-- stays visible) while IsResting() drops to nil/0 (glow turns off).
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
-- "$prt"/"$rxp" formulas) - a single centered FontString assembled from up
-- to 5 independently toggleable segments, kept live via PLAYER_XP_UPDATE/
-- UPDATE_EXHAUSTION/PLAYER_LEVEL_UP, all registered unconditionally
-- regardless of which segments are on (simpler than churning
-- RegisterEvent/UnregisterEvent per checkbox).
--
-- Entirely independent of the Experience Bar container above - this text
-- automatically follows MainMenuExpBar's position/scale.
--
-- The FontString lives on its own dedicated "HIGH"-strata overlay frame
-- (EnsureExpBarTextOverlay below) rather than directly on MainMenuExpBar:
-- MainMenuExpBar sits at strata "MEDIUM" level 2, strictly below
-- MainMenuBarArtFrame's level 5 within that tier, so a region on the bar
-- itself can't out-rank the art. A dedicated HIGH-strata overlay frame
-- (same technique BuildChainAnchoredContainer uses for Bag Bar/Micro
-- Menu) sidesteps that.
-------------------------------------------------------------------------

-- Dedicated overlay frame the "Better Experience Bar" text FontString is
-- created on. SetAllPoints(frame) tracks MainMenuExpBar's own position/
-- size; unlike EnsureContainerOverlay's edit-mode overlays, this one has
-- only the text FontString as a child, whose own Show/Hide controls the
-- text's visibility.
--
-- Reads the live ACABDB.expBarEnabled flag at creation time so a
-- bar that starts disabled doesn't leave this text floating on screen -
-- SetExpBarEnabled's own Hide() call can't reach this overlay before it
-- exists yet (it's created lazily by ACAB:ApplyBetterExpBarVisual).
local function EnsureExpBarTextOverlay(frame)
	if frame.ACABTextOverlay then
		return frame.ACABTextOverlay
	end

	-- Parented to `frame` (MainMenuExpBar), not UIParent: GetWidth()/
	-- GetHeight() only numerically match another frame's when both share
	-- the identical scale ancestry chain, so a UIParent-parented overlay
	-- would drift off-center. This doesn't reintroduce the art-masking
	-- problem above - a child frame's strata/level is independent of its
	-- parent's, unlike a Texture/FontString region.
	local overlay = CreateFrame("Frame", "ACABExpBarTextOverlay", frame)

	overlay:SetFrameStrata("HIGH")
	overlay:SetAllPoints(frame)

	-- See this function's own header comment above - matches whatever
	-- SetExpBarEnabled would already have set had this overlay existed at
	-- login time, instead of defaulting to CreateFrame's normal "shown".
	if ACABDB and ACABDB.expBarEnabled == false then
		overlay:Hide()
	end

	frame.ACABTextOverlay = overlay

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

	if ACABDB.expBarShowLevel then
		n = n + 1
		segments[n] = "Lvl " .. tostring(UnitLevel("player"))
	end

	if ACABDB.expBarShowCurrentOverMax and cur and max then
		n = n + 1
		segments[n] = tostring(cur) .. "/" .. tostring(max)
	end

	if ACABDB.expBarShowPercent then
		local levelPct = 0

		if cur and max and max > 0 then
			levelPct = ExpBarRound((cur / max) * 100)
		end

		n = n + 1
		segments[n] = tostring(levelPct) .. "%"
	end

	if ACABDB.expBarShowRestedPercent then
		local restedPct = 0

		if exhaustion and max and max > 0 then
			restedPct = ExpBarRound((exhaustion * 100) / (max * 1.5))
		end

		n = n + 1
		segments[n] = "Rested: " .. tostring(restedPct) .. "%"
	end

	if ACABDB.expBarShowRestedTotal then
		n = n + 1
		segments[n] = tostring(exhaustion or 0) .. " Rested Xp"
	end

	return table.concat(segments, " ")
end

-- A plain Hide() call does not stick - Blizzard's native XP bar code
-- re-Shows this FontString on some other trigger PLAYER_XP_UPDATE/
-- UPDATE_EXHAUSTION/PLAYER_LEVEL_UP don't cover. Neutering Show() itself
-- fixes it, but unlike the permanent neutering used elsewhere, this one
-- must be reversible: the real Show method is captured once, lazily, in
-- ACAB:ApplyBetterExpBarVisual and restored verbatim when the feature is
-- turned back off.
local realExpOverlayTextShow

local function UpdateBetterExpBarText()
	local text = ACAB.betterExpBarText

	if text then
		text:SetText(ComputeBetterExpBarText())
	end

	-- Show() itself is neutered while the feature is on (see
	-- ACAB:ApplyBetterExpBarVisual below), so this Hide() call is mostly
	-- defense-in-depth at this point - kept because it's harmless.
	local nativeText = ACAB:GetNativeExpOverlayText()

	if nativeText and ACABDB.betterExpBarEnabled then
		nativeText:Hide()
	end
end

-- Shared OnEvent handler for the betterExpBarEventFrame watcher
-- (Events.lua) - refreshes both the text overlay and the custom
-- rested-XP overlay (ACAB:ApplyExpBarRestedOverlay) on the same event set,
-- since both are gated on the same ACABDB.betterExpBarEnabled toggle.
function ACAB:BetterExpBarOnEvent()
	UpdateBetterExpBarText()
	self:ApplyExpBarRestedOverlay()
end

-- Creates (once)/shows/hides/live-updates the text overlay per
-- ACABDB.betterExpBarEnabled - called from Core.lua's login sequence
-- and from the Experience Bar's own settings page.
--
-- This overlay is never created until "Enable Better Experience Bar" is
-- turned on for the first time, so there may be no live FontString to
-- sample a size from yet. GameFontNormalSmall (the Font object this
-- overlay's own text inherits from) supports GetFont() directly with no
-- FontString instance required, so it's read lazily from here instead.
function ACAB:CaptureNativeExpBarFontIfNeeded()
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

function ACAB:ApplyBetterExpBarVisual()
	self:EnsureDB()

	local frame = getglobal(self.EXP_BAR_FRAME_NAME)

	if not frame then
		return
	end

	-- Resolved via ACAB:GetNativeExpOverlayText (the real
	-- MainMenuBarOverlayFrame FontString region).
	local nativeText = self:GetNativeExpOverlayText()

	-- Captured unconditionally here (not inside the enabled-only branch
	-- further below) so ACAB.NATIVE_EXPBAR_FONT is populated on every
	-- login regardless of whether the feature itself is currently on.
	self:CaptureNativeExpBarFontIfNeeded()

	-- Captures the real Show method exactly once, lazily, the first time
	-- this runs after MainMenuBarOverlayFrame's FontString region
	-- actually exists - must happen before it's ever neutered below.
	if nativeText and not realExpOverlayTextShow then
		realExpOverlayTextShow = nativeText.Show
	end

	if not ACABDB.betterExpBarEnabled then
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
		-- ACABDB.betterExpBarEnabled toggle, so turning the feature
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
		-- default (ACAB.NATIVE_EXPBAR_FONT, captured above) until
		-- ACABDB.expBarFontSize holds a real saved value (stays nil
		-- until the user moves Settings.lua's Experience Bar page Font
		-- Size slider - same lazy-default idiom as
		-- ACABDB.hotkeyFontSize/countFontSize).
		local applySize = ACABDB.expBarFontSize

		if not applySize and self.NATIVE_EXPBAR_FONT then
			applySize = self.NATIVE_EXPBAR_FONT.size - 1
		end

		if fontPath then
			text:SetFont(fontPath, applySize or fontSize, "OUTLINE")
		end

		-- ACABDB.expBarTextColor (default gold, Core.lua's EnsureDB)
		-- has no native vanilla equivalent to preserve/revert to (it's
		-- this addon's own FontString, not a native region), so a
		-- straight default is seeded unconditionally rather than lazily
		-- captured from a live frame.
		local textColor = ACABDB.expBarTextColor

		if textColor then
			text:SetTextColor(textColor.r, textColor.g, textColor.b)
		end

		self.betterExpBarText = text

		-- The betterExpBarEventFrame watcher (PLAYER_XP_UPDATE/
		-- UPDATE_EXHAUSTION/PLAYER_LEVEL_UP/PLAYER_UPDATE_RESTING ->
		-- ACAB:BetterExpBarOnEvent) is a standing frame created
		-- unconditionally at file load in Events.lua, not lazily here - it
		-- no-ops safely (via self.betterExpBarText's own nil-checks) for
		-- however long the feature stays off.
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
-- on every OnValueChanged - mirrors Button.lua's ACAB:SetHotkeyFontSize/
-- SetCountFontSize's exact round-then-write template (single FontString
-- here instead of a sweep across every button's hotkey/count, but the
-- same "funnel every caller through one rounding point" reasoning
-- applies - GetFont()'s own float imprecision, e.g. 11.999999726451
-- instead of 12, on this client).
function ACAB:SetExpBarFontSize(size)
	self:EnsureDB()

	size = math.floor(size + 0.5)

	ACABDB.expBarFontSize = size

	if self.betterExpBarText and self.NATIVE_EXPBAR_FONT then
		self.betterExpBarText:SetFont(self.NATIVE_EXPBAR_FONT.path, size, "OUTLINE")
	end
end

-- Settings.lua's Experience Bar page Pulse Interval slider calls this
-- directly - rounds to 1 decimal (the slider's 0.1 step) and clamps to
-- the slider's 0.5-5.0 range so a stray direct-write can't hand the sine
-- formula above a zero/negative period. StartExpBarRestedGlowPulse's own
-- ticker callback reads this field fresh every tick, so writing it here
-- is enough to reach the running animation.
function ACAB:SetExpBarGlowPulseInterval(interval)
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

	ACABDB.expBarGlowPulseInterval = interval
end

-- Settings.lua's Experience Bar page's own text-color swatch calls this
-- directly from ColorPickerFrame.func/cancelFunc - same mechanic as
-- ACAB:SetExpBarColorEarned/SetExpBarColorRested above, just against this
-- addon's own FontString via SetTextColor instead of a native bar-fill
-- region.
function ACAB:SetExpBarTextColor(r, g, b)
	self:EnsureDB()

	ACABDB.expBarTextColor = { r = r, g = g, b = b }

	if self.betterExpBarText then
		self.betterExpBarText:SetTextColor(r, g, b)
	end
end

