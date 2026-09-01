-- Core.lua
-- BTVanilla: Bartender2-style action bar addon for Vanilla 1.12.1.
-- See the project's "01-Environment-Capability-Analysis.md" for the full
-- research record behind every choice made in this addon.
--
-- Key constraints confirmed through live testing:
--   - No SecureHandler*/SecureActionButtonTemplate on this client (TBC+).
--     Plain custom buttons backed by vanilla action slots are exactly as
--     safe as Blizzard's own - proven by ButtonForge Classic's source.
--   - Vanilla action system: 120 slots (10 pages x 12). Pages 7-10
--     (slots 73-120, 48 slots) are free - never touched by the default UI.
--   - SetPoint/SetSize unrestricted during real combat. InCombatLockdown()
--     always returns false on this client - never gate logic on it.
--   - Lua 5.0 has no `%` operator at all (added in 5.1) - use
--     n - (math.floor(n/d)*d) instead, never % , anywhere in this addon.

BTVanilla = {}
local BTV = BTVanilla

-- Action slot pool: pages 7-10, never surfaced by the default Blizzard UI.
BTV.ACTION_SLOT_START = 73
BTV.ACTION_SLOT_END   = 120

-- Defaults used when creating a NEW bar. Existing bars keep whatever is
-- saved in their own config once created - these are just the starting
-- point, not a live global override.
BTV.BUTTON_SIZE = 36
BTV.BUTTON_COLS = 12
BTV.BUTTON_ROWS = 1

-- Real minimum bar spacing while vanilla border style is active - below
-- this the native border texture's overhang causes adjacent buttons to
-- visually overlap. 0 in modern style (no overhang - modern's border
-- lives on its own bounded backdrop edge, not an overhanging overlay).
-- The UI never shows this floor directly - see Settings.lua's spacing
-- display-offset.
BTV.VANILLA_SPACING_FLOOR = 4

-- Empirically measured (live-tested by the user): modern-style buttons
-- need this many more pixels of buttonSize than vanilla-style buttons to
-- LOOK the same size, since modern's border is bounded to its own frame
-- (a plain SetBackdrop edge) while vanilla's overhangs via a larger
-- texture. A fixed additive delta, not a ratio - confirmed: vanilla
-- 36px/spacing 2 looks the same as modern 40px/spacing 2. The DISPLAYED
-- spacing number never changes across a switch, but the REAL spacing
-- value does, by this same amount in the opposite direction (buttonSize
-- + spacing stays visually constant) - see BTV:ApplyGlobalButtonStyle
-- (Bar.lua).
BTV.MODERN_BUTTON_SIZE_DELTA = 4

-- Since every element/button is anchored from a fixed point (not its
-- visual center), growing buttonSize by MODERN_BUTTON_SIZE_DELTA when
-- switching to modern style makes the whole bar appear to shift down and
-- right from that anchor - live-tested and confirmed a 2px up-left
-- position nudge exactly compensates (and the reverse, 2px down-right,
-- when shrinking back to vanilla). See BTV:ApplyGlobalButtonStyle.
BTV.MODERN_BUTTON_SIZE_POSITION_SHIFT = 2

-- Every custom-bar grid preset the Settings UI offers (1x12, 2x6, 3x4,
-- 4x3, 6x2, 12x1) totals exactly 12 buttons, so 12 is the fixed size of
-- the per-slot button pool a custom bar allocates once at creation (see
-- Bar.lua's CreateBarFromConfig/ApplyBarShape). Buttons beyond a bar's
-- current buttonCount are hidden, never destroyed, so their live action
-- slot (and therefore BTV.customBindTargets/HoverBind.lua's
-- TRUSTYBARSBIND<n> dispatch pointed at that slot) stays valid across
-- resizes/relayouts for the bar's entire lifetime.
BTV.MAX_BAR_BUTTONS = 12

-- Real proportions from vanilla's own ActionButtonTemplate.xml: the
-- equip-quality ring is 62/36 the size of the button, centered. Kept as
-- a ratio (not a fixed pixel size) so it scales correctly with any
-- button size, including through bar-scaling later.
BTV.EQUIP_RING_RATIO = 62 / 36

-- Round 15: the user live-confirmed real vanilla's own ActionButton1
-- NormalTexture (its border art) is "Interface\Buttons\UI-Quickslot2",
-- sized 66x66 - against ActionButton1's own real ~36px frame size, which
-- is exactly BTV.BUTTON_SIZE above. Kept as a ratio (66/36), same reason
-- as EQUIP_RING_RATIO, so it scales correctly for any configured button
-- size rather than hardcoding 66. The confirmed oversizing is deliberate
-- native technique: the border art is drawn larger than the button frame
-- itself and centered on it, extending past every edge, which is what
-- lets it visually frame/absorb the icon's own inset margin instead of
-- needing a separate backdrop layer (see Button.lua's border texture,
-- which replicates this for default bars 1-5).
BTV.BORDER_RATIO = 66 / 36

-- Round 16: live-confirmed real vanilla's own border art is centered with
-- a y = -1 offset (1px down from exact center), not a bare 0,0 -
-- Button.lua's self.border anchor replicates this. This is a FIXED pixel
-- offset (not proportional to buttonSize, unlike BORDER_RATIO), so it
-- makes the border's TOP overhang 1px LESS than its bottom overhang
-- regardless of button size - live re-confirmed via diag2/diag9 (14px top
-- vs 16px bottom overhang at the default 36px button size, vs. an exactly
-- symmetric 15px left/right). BTV:GetElementVisualInset below uses this to
-- return the true per-side overhang instead of one uniform value.
BTV.BORDER_Y_OFFSET = 1

-- (v1.0 polish pass, live-tested) Even with the exact, live-measured
-- per-side overhang above, the edit-mode overlay for default bars still
-- looked way too big - diag2/diag9 measured the border TEXTURE's own
-- declared bounds correctly, but the texture's actual VISIBLE (opaque)
-- ring art apparently doesn't extend all the way to those bounds - some
-- of the declared 66x66 border is invisible/transparent padding baked
-- into the image itself (present in both our rendering and vanilla's,
-- per diag4 - not a texture-crop mismatch, an intrinsic property of the
-- asset). This is a flat pixel value (not proportional to buttonSize,
-- same category as BORDER_Y_OFFSET) subtracted from every side's overhang
-- in BTV:GetElementVisualInset, floored at 0. Start at 12 - may need
-- further tuning with live feedback.
BTV.BORDER_TEXTURE_FUDGE = 12

-- (v1.0 polish pass, live-tested) Micro Menu's real GetHitRectInsets()
-- (18px on top only, per diag8) trims most, but not all, of the visual
-- gap between the edit-mode overlay and the buttons' actual icon art -
-- live testing found the real clickable area still starts 1-2px above
-- where the icon visually begins. In the SAME local-unit system as
-- GetHitRectInsets() itself (DefaultBars.lua's GetHitInsets/
-- ApplyChainAnchoredShape/EnsureContainerOverlay apply the same
-- effective-scale conversion to this as to the hit-rect values, so it
-- scales correctly if the user changes Micro Menu's own scale). Live-
-- tested: 1 still left a sliver, 2 is correct.
BTV.MICRO_MENU_OVERLAY_TOP_FUDGE = 2

-- "Snap to Adjacent Elements" (round 35, BTV:ComputeSnapAdjustment below):
-- how close (in real screen pixels, i.e. already GetEffectiveScale()-
-- corrected - never raw local-frame units) a dragged edge must get to a
-- screen edge/corner or another element's edge before it snaps. The user's
-- own spec asked for a 5-10px range without requesting a further user-
-- facing setting of its own - 8 is the chosen mid-point.
BTV.SNAP_THRESHOLD = 8

-- Schema version 2 introduces the fixed-id default-bar model (Main +
-- Bottom Left/Bottom Right/Right/Right 2, ids 1-5) alongside the
-- existing custom-bar array (BTVanillaDB.bars, ids starting at 6). This
-- replaces the earlier single-bar prototype schema entirely. Per plan
-- decision 6, no migration of existing testers' saved custom bars is
-- attempted - a clean-slate bump is acceptable at this stage, so
-- schemaVersion < 2 just re-seeds defaultBars and wipes bars = {}.
--
-- Schema version 3 replaces seedDefaultBars' hardcoded, resolution/
-- UI-scale-dependent guessed point/relativePoint/x/y per default bar
-- with a LIVE capture of each bar's real Blizzard frame position (see
-- seedDefaultBars below). Testers on schema 2 had wrong-looking default
-- positions purely because those guesses didn't match their actual
-- Blizzard anchors - bumping again forces a one-time reseed so everyone
-- picks up their own true native positions instead of staying stuck on
-- the old guesses forever.
--
-- Schema version 4 adds the same live-capture treatment to the GAP
-- between adjacent buttons (see CaptureNativeSpacing below).
-- ApplyDefaultBarShape's old grid math (xOff = col * size, yOff =
-- -row * size) assumed zero-gap packing, which never matched real
-- vanilla action bars - visibly wrong for bar 1 (Main) from the very
-- first login, since bar 1's shape gets applied unconditionally with
-- no enable/disable gate. Bumping again forces a one-time reseed so
-- every default bar picks up cfg.spacing/cfg.nativeSpacing instead of
-- silently defaulting to the old spacing = 0 behavior.
--
-- Schema version 5 (major architecture migration, Phase 1 of 2) adds
-- cfg.fixedActionSlots to default bars 2-5 (Bottom Left/Bottom Right/
-- Right/Right 2 - MultiBarBottomLeft/MultiBarBottomRight/MultiBarRight/
-- MultiBarLeft), a 12-entry array of each bar's REAL, permanent vanilla
-- action-slot numbers, captured once here via CaptureFixedActionSlots
-- below. From this point on, bars 2-5 are built through Bar.lua/
-- Button.lua's own custom-bar button-pool machinery (CreateBarFromConfig/
-- ApplyBarShape), pointed at these fixed native slots instead of the
-- free 73-120 pool a real custom bar (id 6+) uses - see DefaultBars.lua's
-- CreateFixedSlotDefaultBars for where these bars are actually built and
-- their now-redundant real Blizzard button frames permanently hidden.
-- Bar 1 (Main) was explicitly OUT OF SCOPE for this migration at the
-- time - see schema version 7 below, which brings it onto the same
-- engine as bars 2-5.
-- cfg.id is also written for every default bar (1-5) here for the first
-- time - Bar.lua/Button.lua/HoverBind.lua all key off bar.config.id (frame
-- naming, BTV.DEFAULT_BAR_BINDING_PREFIXES lookups, etc.), which bars 2-5
-- need now that they run through that same code; harmless for bar 1,
-- which never reads it.
--
-- Schema version 6 (bug-fix batch, Fix 1) corrects CaptureNativeAnchor's
-- captured corner from button 1's BOTTOMLEFT to its TOPLEFT, matching the
-- corner Bar.lua's LayoutButtons actually anchors pool-slot 1 from. Every
-- saved cfg.x/cfg.y/cfg.nativeAnchor value captured under schema 5 was
-- measured against the WRONG corner for bars 4/5 (12-row vertical grids),
-- placing them roughly 11 button-heights off from their true native
-- position - reinterpreting those old numbers as if they were captured
-- against the new corner would just relocate the bug, not fix it, so a
-- fresh reseed is required. Bars 1-3 happened to be numerically unaffected
-- by the corner change (see CaptureNativeAnchor's own comment for why),
-- but bump for all 5 uniformly since seedDefaultBars reseeds every default
-- bar as a single unit, not per-id.
--
-- Schema version 7 (Main Bar migration, Phase 2 of the major architecture
-- migration) brings Bar 1 (Main) onto the same Bar.lua/Button.lua custom-
-- bar button-pool engine bars 2-5 already use, via a NEW cfg.dynamicMainBar
-- flag (written only for id 1, mutually exclusive with bars 2-5's
-- cfg.fixedActionSlots) rather than a fixed slot array - Bar 1's 12 pool
-- buttons resolve their action slot dynamically every time the active
-- page or bonus-bar (stance/form/stealth) offset changes, per
-- DefaultBars.lua's GetMainBarEffectivePage/RefreshMainBarSlots, gated by
-- the two new BTVanillaDB.mainBarPaginationEnabled/mainBarStanceSwapEnabled
-- toggles seeded below. A reseed is required purely so existing saves pick
-- up cfg.dynamicMainBar on bar 1 - every other default bar's config is
-- unaffected by this bump.
--
-- Schema version 8 (Stance/Page Bar Assignment feature, Part 1) replaces
-- the old open-ended "Add New Bar" custom-bar flow (Bar.lua's removed
-- AddNewBar/GetNextBarId) with exactly BTV.EXTRA_BAR_COUNT (4) permanent
-- "Extra Bar" slots (ids EXTRA_BAR_ID_START..+COUNT-1, i.e. 6-9) - same
-- always-exists-toggle-only lifecycle as default bars 2-5, just still
-- backed by the free 73-120 action-slot pool (a real custom bar's own
-- allocation mechanism) rather than a fixed native multibar range. Bumping
-- wipes BTVanillaDB.bars (below) same as every prior schema bump, then
-- EnsureExtraBars (below) seeds fresh entries for all 4 - no migration of
-- any pre-existing tester's manually-added custom bars is attempted, same
-- accepted clean-slate precedent as schema version 2.
BTV.SCHEMA_VERSION = 8

-- EnsureDB runs constantly throughout the session (settings changes, button
-- events, HoverBind.lua's ForEachButton, etc.), not just at login/reload.
-- hoverBindMode must reset to off once per session (login/reload) but must
-- never be re-forced by any later mid-session EnsureDB call, or it stomps
-- BTV:SetHoverBindMode(true) the instant anything downstream of that same
-- toggle (e.g. ApplyHoverBindVisual -> ForEachButton) calls EnsureDB again.
-- This upvalue - not a BTVanillaDB field - is what makes the reset one-shot
-- per session, since BTVanillaDB itself persists across reloads.
local hasResetHoverBindModeThisSession = false

-- Captures a default bar's TRUE on-screen position straight from its
-- first real Blizzard button frame, via GetLeft()/GetTop() rather than
-- GetPoint(). GetPoint() would return whatever point/relativeTo/
-- relativePoint Blizzard's own FrameXML happened to use internally (e.g.
-- ActionButton1 is anchored to MainMenuBar, not UIParent) - each bar
-- would need its own translation rule to convert that back to a UIParent-
-- relative anchor. GetLeft()/GetTop() sidestep this entirely: they always
-- report the frame's absolute position in the root/UIParent coordinate
-- space (origin at the bottom-left of the screen, x-right/y-up positive)
-- regardless of what the frame is really anchored to internally.
--
-- point is "TOPLEFT" (not "BOTTOMLEFT", as an earlier version of this
-- function used) because Bar.lua's LayoutButtons always anchors pool-slot
-- 1 to the bar frame's own TOPLEFT (offset 0,0) - the bar's TOPLEFT corner
-- must therefore equal button 1's captured TOPLEFT corner exactly. The old
-- BOTTOMLEFT capture only coincidentally produced the same result for
-- bars 1-3 (single-row, so the bar's own height equals one button's
-- height, and BOTTOMLEFT-of-bar + barHeight upward == TOPLEFT-of-bar) but
-- was wrong by ~11 button-heights for bars 4/5's 12-row vertical grid.
--
-- relativePoint is deliberately kept "BOTTOMLEFT" (of UIParent), NOT
-- "TOPLEFT" - UIParent's BOTTOMLEFT corner sits at absolute screen
-- position (0,0), the same origin GetLeft()/GetTop() already measure
-- from, so the captured x/y can be used as the SetPoint offset directly
-- with no further math. Anchoring against UIParent's TOPLEFT instead would
-- require subtracting UIParent's own screen height from the captured top
-- value (since UIParent's TOPLEFT corner sits at absolute y = screen
-- height, not 0) - avoidable complexity/an extra live-read this addon has
-- no need for.
--
-- Must run before ApplyAllDefaultBars() ever calls ApplyDefaultBarShape
-- and moves these frames - see the login-sequence load order at the
-- bottom of this file (gated on PLAYER_ENTERING_WORLD, not PLAYER_LOGIN -
-- see loadFrame's own comment, round 9): EnsureDB() (which calls this via
-- seedDefaultBars on a fresh/schema-bumped save) runs first,
-- ApplyAllDefaultBars() after.
-- Round 7 root-cause fix: GetLeft()/GetTop() return a value in the
-- QUERIED frame's OWN effective-scale coordinate space, not in literal
-- screen pixels - real screen pixels = GetLeft() * frame:GetEffectiveScale()
-- (the same conversion LibWindow-style position-saving addons have used
-- for years, and the exact math ClassicAPI's own PixelUtil.SetPoint uses
-- internally: it snaps offsets to the nearest pixel using the frame BEING
-- positioned's GetEffectiveScale(), never the anchor target's - see this
-- file's own PixelSetPoint precedent in DefaultBars.lua/Bar.lua). A plain
-- SetPoint's xOfs/yOfs offsets are likewise always expressed in units of
-- the frame being positioned, not its relativeTo anchor.
--
-- The bar frame this value is eventually applied to (Bar.lua's
-- ApplyBarPosition: PixelSetPoint(bar, ..., UIParent, ..., cfg.x, cfg.y))
-- is a bare CreateFrame(..., UIParent) with no SetScale of its own
-- (confirmed - no SetScale call anywhere touches a bar frame itself, only
-- the separate chain-anchored containers), so its effective scale is
-- always exactly UIParent's own effective scale. If the native button's
-- own effective scale ever differs from UIParent's (e.g. some ancestor in
-- MainMenuBar's chain applies its own SetScale on this client/server
-- build), copying GetLeft()/GetTop() verbatim silently mispositions the
-- bar by exactly that scale ratio - live-confirmed reproducible symptom
-- (captured x=178.67 vs the button's real GetLeft() reporting x=254.52 in
-- the same session, a ~1.4246 ratio, not a random offset).
--
-- Converting explicitly through real screen pixels (multiply by the
-- button's own effective scale, then divide by the target's - here
-- UIParent's, since that's what the bar frame's own effective scale is
-- always equal to) makes this correct regardless of whether such a scale
-- differential exists, and stays correct across any future resolution/
-- UI-scale change too, since both scales move together under a uniform
-- UI-scale change and the ratio is recomputed fresh every capture.
local function CaptureNativeAnchor(self, id)
	local buttons = self.GetDefaultBarButtons and self:GetDefaultBarButtons(id)

	if not buttons then
		return nil
	end

	local first = buttons[1]

	if not first then
		return nil
	end

	local left = first:GetLeft()
	local top = first:GetTop()

	if not left or not top then
		return nil
	end

	local buttonScale = first:GetEffectiveScale()
	local targetScale = UIParent:GetEffectiveScale()

	if not buttonScale or not targetScale or targetScale == 0 then
		return nil
	end

	local screenX = left * buttonScale
	local screenY = top * buttonScale

	return {
		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = screenX / targetScale,
		y = screenY / targetScale,
	}
end

-- Captures the real, native gap between adjacent buttons on default bar
-- `id`, straight from Blizzard's own (not-yet-repositioned) frames - the
-- same "read the real frame instead of guessing" approach as
-- CaptureNativeAnchor above, extended from just button 1's position to
-- the full run of up to 12 buttons so unevenness anywhere in the row/
-- column can actually be detected rather than assumed away.
--
-- Orientation (which axis the row of buttons runs along) is taken from
-- the bar's own grid shape - cols=12/rows=1 for bars 1-3 (horizontal,
-- measured via GetLeft()), cols=1/rows=12 for bars 4-5 (vertical,
-- measured via GetBottom()) - rather than hardcoding per-bar-id
-- assumptions, so this stays correct if DEFAULT_BAR_GRID is ever
-- rebalanced.
--
-- Returns spacing (rounded to the nearest integer pixel, since the
-- Settings UI's spacing slider is integer-stepped), isUniform (true only
-- if every one of the 11 adjacent gaps matched within 0.5px), and the
-- raw gaps array (for the one-time diagnostic print in seedDefaultBars
-- below) - or nil if the real frames can't be read yet.
local function CaptureNativeSpacing(self, id, grid)
	local buttons = self.GetDefaultBarButtons and self:GetDefaultBarButtons(id)

	if not buttons then
		return nil
	end

	local horizontal = (grid.cols or 1) > (grid.rows or 1)

	local positions = {}
	local i

	for i = 1, table.getn(buttons) do
		local btn = buttons[i]

		if not btn then
			break
		end

		local pos = horizontal and btn:GetLeft() or btn:GetBottom()

		if not pos then
			return nil
		end

		positions[i] = pos
	end

	local count = table.getn(positions)

	if count < 2 then
		return nil
	end

	-- Read the real button width/height rather than assuming
	-- self.BUTTON_SIZE - GetLeft()/GetBottom() already sidestep any
	-- UI-scale/anchor-chain guesswork (see CaptureNativeAnchor's
	-- comment above), so the size used to derive the gap should come
	-- from the same live frame, not a constant.
	local size = horizontal and buttons[1]:GetWidth() or buttons[1]:GetHeight()
	size = size or self.BUTTON_SIZE

	local gaps = {}
	local n

	for n = 1, count - 1 do
		local delta = positions[n + 1] - positions[n]

		if delta < 0 then
			delta = -delta
		end

		gaps[n] = delta - size
	end

	-- Bucket gaps within 0.5px of each other (float-rounding tolerance,
	-- per the task's spec) rather than requiring exact equality.
	local buckets = {}
	local gi

	for gi = 1, table.getn(gaps) do
		local g = gaps[gi]
		local matched = false
		local bi

		for bi = 1, table.getn(buckets) do
			local b = buckets[bi]
			local diff = g - b.value

			if diff < 0 then
				diff = -diff
			end

			if diff <= 0.5 then
				b.count = b.count + 1
				matched = true
				break
			end
		end

		if not matched then
			table.insert(buckets, { value = g, count = 1 })
		end
	end

	local majority = buckets[1]
	local bi

	for bi = 2, table.getn(buckets) do
		if buckets[bi].count > majority.count then
			majority = buckets[bi]
		end
	end

	local uniform = table.getn(buckets) == 1

	-- Round 7 root-cause fix: majority.value above is measured entirely in
	-- the native buttons' OWN effective-scale coordinate space (every
	-- position/size read in this function comes from the same native
	-- button family, so the deltas among them are internally consistent
	-- with no correction needed there - unlike CaptureNativeAnchor's
	-- cross-tree UIParent conversion). But cfg.spacing is applied by
	-- Bar.lua's LayoutButtons as `cfg.buttonSize + spacing` inside the BAR
	-- frame's own coordinate space (buttonSize itself is always the fixed
	-- BTV.BUTTON_SIZE constant, not a native-scale-derived value) - so if
	-- the native button family's effective scale differs from the bar's
	-- own (== UIParent's, per CaptureNativeAnchor's comment on why),
	-- copying the raw native-space gap verbatim would produce a spacing
	-- that looks proportionally wrong relative to that fixed button size.
	-- Same real-screen-pixel round-trip conversion as CaptureNativeAnchor.
	local buttonScale = buttons[1]:GetEffectiveScale()
	local targetScale = UIParent:GetEffectiveScale()

	if buttonScale and targetScale and targetScale ~= 0 then
		majority.value = (majority.value * buttonScale) / targetScale
	end

	-- Majority value (not an average - see task spec: an average across
	-- a non-uniform run could land on a nonsensical fractional
	-- compromise that matches none of the real gaps), rounded to the
	-- nearest integer pixel for the slider.
	local spacing = math.floor(majority.value + 0.5)

	if spacing < 0 then
		spacing = 0
	end

	return spacing, uniform, gaps
end

-- Discovers default bar `id`'s (2-5 only) 12 REAL, permanent vanilla
-- action-slot numbers directly from its live Blizzard button frames,
-- rather than hardcoding/guessing vanilla's fixed multibar slot-range
-- constants - this is what step 1 of the migration plan asks for
-- ("read ground truth directly from the live client").
--
-- Primary accessor: real vanilla ActionButtonTemplate's own Lua field,
-- set by FrameXML's ActionButton_CalculateAction/ActionButton_OnLoad,
-- holding this exact button's bound action-slot number (btn.action).
-- This is the same well-established field ButtonForge Classic and every
-- other action-bar addon of this era reads directly - not reimplemented
-- here, just read.
--
-- Defensive fallback ONLY if that field is somehow missing on this
-- client build: the well-established vanilla 1.12.1 fixed multibar
-- action-id offsets (MultiBarBottomLeft = 61-72, MultiBarBottomRight =
-- 49-60, MultiBarRight = 13-24, MultiBarLeft = 25-36, per real FrameXML
-- source). This is the one accessor the task plan explicitly authorizes
-- a defensive multi-fallback for, rather than a single blind guess - see
-- this addon's task record. usedFallback (2nd return) is surfaced so the
-- one-time seed print below can flag whenever the fallback path was
-- actually exercised, so a live tester can immediately see whether it was
-- ever needed.
local FIXED_SLOT_FALLBACK_OFFSET = {
	[2] = 60, -- MultiBarBottomLeft
	[3] = 48, -- MultiBarBottomRight
	[4] = 12, -- MultiBarRight
	[5] = 24, -- MultiBarLeft
}

local function CaptureFixedActionSlots(self, id)
	local buttons = self.GetDefaultBarButtons and self:GetDefaultBarButtons(id)

	if not buttons then
		return nil
	end

	local slots = {}
	local usedFallback = false
	local i

	for i = 1, table.getn(buttons) do
		local btn = buttons[i]

		if not btn then
			return nil
		end

		local slot = btn.action

		if not slot then
			local offset = FIXED_SLOT_FALLBACK_OFFSET[id]

			if offset then
				slot = offset + i
				usedFallback = true
			end
		end

		if not slot then
			return nil
		end

		slots[i] = slot
	end

	return slots, usedFallback
end

-- Grid shape only - unchanged from the old hardcoded table. Position is
-- no longer guessed here at all (see CaptureNativeAnchor above).
--
-- Exposed as BTV.DEFAULT_BAR_GRID (not just a local) so DefaultBars.lua's
-- BTV:ResetDefaultBarLayout (bug-fix batch, Issue 3) can restore a bar's
-- native cols/rows from the exact same source seedDefaultBars uses,
-- rather than a second guessed/duplicated table.
BTV.DEFAULT_BAR_GRID = {
	[1] = { cols = 12, rows = 1 },                      -- Main.
	[2] = { cols = 12, rows = 1, enabled = false },      -- Bottom Left.
	[3] = { cols = 12, rows = 1, enabled = false },      -- Bottom Right.
	[4] = { cols = 1,  rows = 12, enabled = false },     -- Right.
	[5] = { cols = 1,  rows = 12, enabled = false },     -- Right 2.
}

-- Native vanilla FrameXML global backing each default bar's own built-in
-- Interface Options -> Action Bars checkbox ("Show Bottom Left
-- ActionBar", etc. - MULTIACTIONBAR1-4, same mapping HoverBind.lua's own
-- MULTIACTIONBAR_PREFIXES table uses: default bar id -> MULTIACTIONBAR(id-1)).
-- Bars 2-5's real native buttons are permanently hidden regardless (see
-- DefaultBars.lua's CreateFixedSlotDefaultBars) - our own cfg.enabled
-- stays the sole VISUAL authority. SAME-SESSION COSMETIC USE ONLY -
-- docs/01-Environment-Capability-Analysis.md (§5m) already live-confirmed
-- these globals do NOT persist to this fork's WTF SavedVariables at all
-- (unlike LOCK_ACTIONBAR), reliably reading nil/reset on every fresh
-- login regardless of what was true last session - never treat this as
-- authoritative for anything that needs to survive a login boundary
-- (seedDefaultBars deliberately does NOT read it, for exactly this
-- reason). DefaultBars.lua's SetDefaultBarEnabled still mirrors our
-- state into it (so the real Options checkbox doesn't look stuck/wrong
-- within the current session), purely cosmetic.
BTV.SHOW_MULTI_ACTIONBAR_GLOBAL = {
	[2] = "SHOW_MULTI_ACTIONBAR_1",
	[3] = "SHOW_MULTI_ACTIONBAR_2",
	[4] = "SHOW_MULTI_ACTIONBAR_3",
	[5] = "SHOW_MULTI_ACTIONBAR_4",
}

-- Friendly display names for the 5 fixed default bars (1-5) - round 36
-- (Item 2) promotes this out of Settings.lua's own file-local copy into a
-- single BTV-level source of truth, since Bar.lua's EnsureBarOverlay now
-- needs the exact same names for its own edit-mode label and Bar.lua loads
-- before Settings.lua (BTVanilla.toc order) - a file-local Lua table can't
-- be shared across files regardless of load order anyway. Settings.lua's
-- own GetBarDisplayName now delegates to BTV:GetBarDisplayName below
-- instead of keeping a second, independently-maintained copy.
BTV.DEFAULT_BAR_NAMES = {
	[1] = "Main Bar",
	[2] = "Action Bar 1",
	[3] = "Action Bar 2",
	[4] = "Right Action Bar 1",
	[5] = "Right Action Bar 2",
}

-- Extra Bars (ids EXTRA_BAR_ID_START..+COUNT-1, i.e. 6-9) are numbered
-- from 1 for the user rather than showing the internal id - mirrors
-- Settings.lua's own pre-existing "Extra Bar " .. (barId - 5) numbering
-- exactly (5 is the count of default bars 1-5 that precede them, not a
-- magic number tied to EXTRA_BAR_ID_START). String-keyed chain-anchored
-- elements (Bag Bar, Stance Bar, etc. - never numeric ids) are a separate
-- naming domain entirely and are NOT handled here - see DefaultBars.lua's
-- EnsureContainerOverlay, which takes an explicit displayName argument per
-- call site instead, since those 7 elements have no single shared id
-- scheme this function could key off.
function BTV:GetBarDisplayName(barId)
	if barId and barId >= 1 and barId <= 5 then
		return self.DEFAULT_BAR_NAMES[barId] or ("Bar " .. tostring(barId))
	end

	return "Extra Bar " .. tostring((barId or 0) - 5)
end

-- Last-resort fallback ONLY for the case CaptureNativeAnchor can't read
-- a real Blizzard frame at all (e.g. called too early, or one of the 5
-- global frame names is missing on this client) - these are the same
-- guessed offsets the addon shipped with before this fix, kept only so a
-- seed never produces a bar sitting at (0,0)-off-UIParent-center with no
-- explanation, not because they're expected to be accurate.
local FALLBACK_ANCHOR = {
	[1] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 0 },
	[2] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 42 },
	[3] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 84 },
	[4] = { point = "RIGHT", relativePoint = "RIGHT", x = -18, y = 0 },
	[5] = { point = "RIGHT", relativePoint = "RIGHT", x = -58, y = 0 },
}

local function seedDefaultBars(self)
	local result = {}
	local id

	for id = 1, 5 do
		local grid = self.DEFAULT_BAR_GRID[id]
		local anchor = CaptureNativeAnchor(self, id) or FALLBACK_ANCHOR[id]

		local spacing, uniform, gaps = CaptureNativeSpacing(self, id, grid)

		-- Same "no real frame yet" fallback reasoning as FALLBACK_ANCHOR
		-- above - 0 (the old hardcoded behavior) rather than guessing a
		-- nonzero constant blind.
		spacing = spacing or 0

		-- One-time diagnostic (only fires the moment a bar is first
		-- seeded/reseeded, never again) - lets a tester confirm exactly
		-- what was captured, and specifically whether the gap run was
		-- uniform, straight from the chat frame. See this file's header
		-- comment and the task report for why this matters: the Main
		-- Bar's button 9->10 transition was suspected non-uniform and
		-- needs live confirmation this print supplies.
		if gaps then
			local gapStr = ""
			local gi

			for gi = 1, table.getn(gaps) do
				gapStr = gapStr .. string.format("%.1f", gaps[gi])

				if gi < table.getn(gaps) then
					gapStr = gapStr .. ", "
				end
			end

			self:Print(
				"Default bar " .. tostring(id) .. " native spacing capture: " ..
				(uniform and "uniform" or "NON-UNIFORM") ..
				", using " .. tostring(spacing) .. "px. Raw gaps: " .. gapStr
			)
		end

		-- NOT read from BTV.SHOW_MULTI_ACTIONBAR_GLOBAL here (deliberately) -
		-- this project's own docs/01-Environment-Capability-Analysis.md
		-- (§5m) already live-confirmed SHOW_MULTI_ACTIONBAR_1-4 do NOT
		-- persist to this fork's WTF SavedVariables at all, unlike
		-- LOCK_ACTIONBAR - they reliably read nil/reset on every fresh
		-- login regardless of what was true last session. Seeding from
		-- them here would silently discard the player's real saved
		-- cfg.enabled (from BTVanillaProfilesDB) on every schema-version
		-- reseed, and can never actually recover a "prior preference"
		-- either, since the global itself never survived to be read.
		local enabled = grid.enabled

		result[id] = {
			-- Bar.lua/Button.lua/HoverBind.lua all key off bar.config.id
			-- (frame naming, BTV.DEFAULT_BAR_BINDING_PREFIXES lookups) -
			-- needed now that bars 2-5 run through that same machinery.
			-- Harmless for bar 1, which never reads it (still wraps its
			-- own real Blizzard frames directly, out of scope this pass).
			id = id,

			enabled = enabled,
			point = anchor.point,
			relativePoint = anchor.relativePoint,
			x = anchor.x,
			y = anchor.y,
			cols = grid.cols,
			rows = grid.rows,
			buttonSize = self:GetCurrentButtonSizeBaseline(),
			spacing = spacing,

			-- Bar.lua's ApplyBarShape falls back to cols*rows when this is
			-- absent, but every default-bar grid preset already always
			-- fills the whole grid (Phase 1 explicitly doesn't add a
			-- buttons-shown stepper for bars 2-5), so writing it explicitly
			-- here is just clearer than relying on that fallback silently.
			buttonCount = grid.cols * grid.rows,

			-- Permanent pristine snapshot, captured ONCE here and never
			-- written to again by anything else in the addon (not even
			-- BTV:ResetDefaultBarLayout in DefaultBars.lua, which
			-- restores FROM this field, never by re-reading the live
			-- frame - by the time a user clicks Reset, the real
			-- Blizzard frame's current position may already be wherever
			-- ApplyDefaultBarShape last put it, not its true original
			-- position, so a live re-read at reset time would just
			-- capture our own last SetPoint instead of Blizzard's
			-- default).
			nativeAnchor = {
				point = anchor.point,
				relativePoint = anchor.relativePoint,
				x = anchor.x,
				y = anchor.y,
			},

			-- Permanent pristine snapshot of the captured gap, mirroring
			-- nativeAnchor exactly - never written to again after this
			-- seed (see BTV:ResetDefaultBarLayout in DefaultBars.lua,
			-- which restores cfg.spacing FROM this field).
			nativeSpacing = spacing,
		}

		-- Bar 1 (Main) only - schema version 7's dynamic-slot migration
		-- (see BTV.SCHEMA_VERSION's header comment above). Unlike bars 2-5's
		-- fixedActionSlots (which needs a live discovery pass that can, in
		-- principle, fail - see CaptureFixedActionSlots below), Bar 1's
		-- dynamic slot resolution needs no such discovery: it's recomputed
		-- on demand from CURRENT_ACTIONBAR_PAGE/GetBonusBarOffset() every
		-- time (DefaultBars.lua's GetMainBarEffectivePage), so this flag can
		-- simply always be written.
		if id == 1 then
			result[id].dynamicMainBar = true
		end

		-- Bars 2-5 only. Discovery failure
		-- here (should essentially never happen given the real frames
		-- exist by PLAYER_LOGIN, same timing CaptureNativeAnchor already
		-- relies on) degrades gracefully: this bar simply has no
		-- fixedActionSlots field, so DefaultBars.lua's
		-- CreateFixedSlotDefaultBars skips it entirely and its real
		-- Blizzard buttons are left alone (old native-wrapping visuals),
		-- rather than the whole login sequence erroring out.
		if id >= 2 and id <= 5 then
			local fixedActionSlots, usedFallback = CaptureFixedActionSlots(self, id)

			if fixedActionSlots then
				result[id].fixedActionSlots = fixedActionSlots

				local slotStr = ""
				local si

				for si = 1, table.getn(fixedActionSlots) do
					slotStr = slotStr .. tostring(fixedActionSlots[si])

					if si < table.getn(fixedActionSlots) then
						slotStr = slotStr .. ", "
					end
				end

				self:Print(
					"Default bar " .. tostring(id) .. " fixed action slots: " ..
					slotStr ..
					(usedFallback and
						" (FALLBACK offsets used - button.action was missing, please verify live)" or
						" (confirmed via button.action)")
				)
			else
				self:Print(
					"WARNING: Default bar " .. tostring(id) ..
					" could not discover its real action slots this session " ..
					"- it will keep using the old native-Blizzard-frame layout " ..
					"until this succeeds on a later login."
				)
			end
		end
	end

	return result
end

-- Round 11 root-cause fix: EVERY prior recapture marker (anchorRecaptureDone/
-- anchorScaleFixDone/anchorTimingFixDone/anchorEnterWorldFixDone/
-- round10DebugRecaptureDone - the last of these was a temporary diagnostic
-- marker, since removed along with the debug prints it fed; see EnsureDB
-- below for the markers still in effect) was read character-by-
-- character and found logically sound in isolation - each nils
-- BTVanillaDB.defaultBars strictly BEFORE the `if not BTVanillaDB.defaultBars
-- then seedDefaultBars() end` gate runs, in the same synchronous EnsureDB
-- call, with no inverted condition and no wrong field name. The actual flaw
-- is architectural, not a typo: this addon's `## SavedVariables: BTVanillaDB`
-- (see BTVanilla.toc) is account-wide, not per-character, so a "fresh"
-- one-shot marker is only genuinely fresh the very first time ANY character
-- on the account runs EnsureDB() after the marker's code was saved -
-- literally any earlier reload/login (a sanity-check reload, an alt, a
-- reload that happened before the tester started watching chat) silently
-- spends it, and there is no way for a single later pasted chat log to prove
-- it was watching the shot that actually fired. Round 10's own evidence is
-- consistent with exactly this: "DEBUG pre-EnsureDB" read the correct settled
-- 254.52 live off ActionButton1 immediately before EnsureDB() ran, yet
-- BTVanillaDB.defaultBars stayed at the old 178.66-family value with zero
-- CaptureNativeAnchor debug output - only possible if seedDefaultBars simply
-- never executed that call, i.e. round10DebugRecaptureDone (and by extension
-- every earlier marker) was already consumed before that particular login
-- even started.
--
-- Fix: an explicit, ON-DEMAND recapture the user triggers themselves (see
-- the "/btv recapture" slash command at the bottom of this file) removes the
-- "was this really the first login since the marker was added" ambiguity
-- entirely - it runs synchronously the instant the command is typed, so the
-- tester is provably watching chat at the exact moment of capture, no
-- account-wide one-shot race involved. Also directly fixes
-- DefaultBars.lua's BTV:ResetDefaultBarLayout (which restores FROM
-- cfg.nativeAnchor/cfg.nativeSpacing, never by re-reading the live frame -
-- see seedDefaultBars' own comment on nativeAnchor above): those fields are
-- written by this same seedDefaultBars call, so a successful on-demand
-- recapture refreshes the Reset button's own baseline too, with no separate
-- fix needed in ResetDefaultBarLayout itself.
--
-- Deliberately does NOT touch the old marker chain in EnsureDB (harmless at
-- this point, not a source of incorrect behavior - just an unreliable way to
-- PROVE a fresh capture happened) and deliberately reapplies live (not just
-- to SavedVariables) via ApplyAllDefaultBars, which is always safe to call
-- again mid-session - it unconditionally re-applies every default bar's
-- shape/position from its own cfg regardless of enabled state (see its own
-- comment in DefaultBars.lua), so this snaps bars 1-5 to their true native
-- position immediately, not just on the next reload.
function BTV:RecaptureDefaultBarNativeAnchors()
	self:EnsureDB()

	BTVanillaDB.defaultBars = nil
	BTVanillaDB.defaultBars = seedDefaultBars(self)

	self:Print("Recapture complete. New cfg.x/cfg.y per default bar:")

	local id

	for id = 1, 5 do
		local cfg = BTVanillaDB.defaultBars[id]

		if cfg then
			self:Print(string.format(
				"  Bar %d: x=%.2f y=%.2f (point=%s, relativePoint=%s)",
				id, cfg.x or -1, cfg.y or -1,
				tostring(cfg.point), tostring(cfg.relativePoint)
			))
		end
	end

	-- Only reposition the live frames if this session's bars already exist
	-- (RunLoginSequence has already run) - calling this before login has
	-- built anything would error on nil bar frames inside ApplyDefaultBarShape.
	if self.bars and self.bars[1] then
		self:ApplyAllDefaultBars()
		self:Print("Live bar positions re-applied from the fresh capture.")
	end
end

-------------------------------------------------------------------------
-- Extra Bars 1-4 (ids 6-9) - Stance/Page Bar Assignment feature, Part 1
--
-- Permanent, like default bars 1-5: exactly BTV.EXTRA_BAR_COUNT of these
-- always exist in BTVanillaDB.bars, toggled on/off via their own
-- cfg.enabled flag (default false, mirroring how bars 2-5 start disabled
-- too - BTV.DEFAULT_BAR_GRID's own `enabled = false`) rather than the old
-- incremental "Add New Bar" flow this replaces. Each one is still a real
-- Bar.lua custom bar under the hood (built via CreateBarFromConfig off
-- cfg.slotStart, same as any bar 6+ always was) - only its LIFECYCLE
-- changed (always-exists instead of add/remove), not its shape/settings
-- machinery, so Settings.lua's existing custom-bar page (grid/spacing/
-- button-size/buttonCount controls) needs no changes to keep working for
-- these ids.
--
-- Exactly 4 extra bars, each permanently reserving a 12-slot block, fills
-- the ENTIRE 48-slot free pool (73-120) - this was already the true
-- maximum bar count the old GetNextFreeSlotStart-based allocator could
-- ever support (see Bar.lua's own header comment), just now fixed and
-- always-present instead of opportunistically discovered one "Add New
-- Bar" click at a time.
-------------------------------------------------------------------------

BTV.EXTRA_BAR_ID_START = 6
BTV.EXTRA_BAR_COUNT = 4

-- Allocates one Extra Bar's config from scratch - called only for an id
-- that doesn't already have an entry in BTVanillaDB.bars (EnsureExtraBars
-- below). Position defaults to a simple vertical stack under UIParent's
-- center, one button-height apart per extra bar - purely a sane, always-
-- on-screen starting point the user can drag away from once enabled,
-- mirroring the old AddNewBar's own CENTER/CENTER fallback branch (the
-- one it used whenever there was no earlier live bar to stack against -
-- always true here, since this runs at EnsureDB time, before Bar.lua's
-- CreateAllBars has built any live bar frame at all this session).
local function seedExtraBarConfig(self, id)
	local needed = self.BUTTON_COLS * self.BUTTON_ROWS
	local slotStart = self:GetNextFreeSlotStart(needed)

	if not slotStart then
		self:Print(
			"WARNING: Extra Bar " .. tostring(id - self.EXTRA_BAR_ID_START + 1) ..
			" could not be allocated a free action-slot block this session " ..
			"- the 48-slot free pool (73-120) is unexpectedly already full."
		)

		return nil
	end

	local index = id - self.EXTRA_BAR_ID_START

	return {
		id = id,

		point = "CENTER",
		relativePoint = "CENTER",
		x = 0,
		y = -200 - (index * self.BUTTON_SIZE),

		cols = self.BUTTON_COLS,
		rows = self.BUTTON_ROWS,

		buttonSize = self:GetCurrentButtonSizeBaseline(),

		slotStart = slotStart,
		buttonCount = self.BUTTON_COLS * self.BUTTON_ROWS,

		spacing = 0,

		-- Default false (Part 1) - same "stay invisible until the user
		-- explicitly opts in" reasoning as default bars 2-5's own
		-- `enabled = false` default, so 4 brand-new visible bars never
		-- appear unannounced for an existing tester the first time they
		-- log in post-update.
		enabled = false,
	}
end

-- Ensures exactly BTV.EXTRA_BAR_COUNT Extra Bar configs exist in
-- BTVanillaDB.bars - called both from the schema-bump branch below
-- (fresh, empty bars array) and unconditionally on every EnsureDB call
-- (a cheap linear scan of at most 4 entries), so a partially-completed
-- seed from an earlier session (e.g. the free-slot pool was still
-- occupied by a leftover pre-Part-1 custom bar that session) can finish
-- topping itself up on a later login once room exists, without needing
-- another schema bump.
function BTV:EnsureExtraBars()
	local id

	for id = self.EXTRA_BAR_ID_START, self.EXTRA_BAR_ID_START + self.EXTRA_BAR_COUNT - 1 do
		local found = false
		local i

		for i = 1, table.getn(BTVanillaDB.bars) do
			if BTVanillaDB.bars[i] and BTVanillaDB.bars[i].id == id then
				found = true
				break
			end
		end

		if not found then
			local cfg = seedExtraBarConfig(self, id)

			if cfg then
				table.insert(BTVanillaDB.bars, cfg)
			end
		end
	end
end

-------------------------------------------------------------------------
-- Profiles
--
-- BTVanillaDB stays exactly what every other read/write site in this
-- addon already assumes it is: the live, active profile's data - the
-- 200+ existing `BTVanillaDB.field` call sites across every file need
-- zero changes. What's new: BTVanillaDB's CONTENTS can now be swapped out
-- wholesale at well-defined moments (login, and right before a
-- ReloadUI() this feature triggers), copied to/from BTVanillaProfilesDB
-- (a new account-wide SavedVariable, a plain table keyed by profile
-- name) via BTV:ResolveActiveProfile()/BTV:SaveActiveProfileData() below.
--
-- WoW's SavedVariables system requires every persisted global to be
-- statically declared in the .toc at load time - a literal, separately-
-- declared SavedVariable per arbitrary user-typed profile name is not
-- possible. BTVanillaProfilesDB (one declared SavedVariable, a table
-- keyed by name inside it) is the closest achievable equivalent: each
-- profile still gets fully independent settings storage, just not as a
-- literally-separate global variable name.
--
-- BTVanillaCharDB (new SavedVariablesPerCharacter) stores only which
-- profile name THIS character/realm currently uses - naturally scoped by
-- vanilla's own per-character SavedVariables file layout, no manual
-- realm-key namespacing needed inside it.
-------------------------------------------------------------------------

BTV.DEFAULT_PROFILE_NAME = "Default"

-- Small hand-written recursive deep copy rather than ClassicAPI's
-- TableUtil.CopyTable/CopyTableSafe (present on this client per
-- docs/01-Environment-Capability-Analysis.md, but their exact deep-copy
-- semantics haven't been independently live-confirmed for a table shape
-- as deeply nested as BTVanillaDB's own bars/defaultBars arrays) - profile
-- data integrity is exactly the kind of thing this addon's own convention
-- says not to guess on. BTVanillaDB only ever holds plain data (strings/
-- numbers/booleans/nested plain tables, no functions/frames/metatables),
-- so a plain recursive copy is correct and sufficient.
function BTV:DeepCopyTable(t)
	if type(t) ~= "table" then
		return t
	end

	local copy = {}
	local k, v

	for k, v in pairs(t) do
		copy[k] = self:DeepCopyTable(v)
	end

	return copy
end

-- Sorted list of every saved profile name, BTV.DEFAULT_PROFILE_NAME always
-- first regardless of alphabetical order - used to populate every profile
-- dropdown in Settings.lua's Profiles tab and the first-login dialog.
function BTV:GetProfileNames()
	local names = {}
	local n = 0
	local name

	for name in pairs(BTVanillaProfilesDB or {}) do
		if name ~= self.DEFAULT_PROFILE_NAME then
			n = n + 1
			names[n] = name
		end
	end

	table.sort(names)

	local result = { self.DEFAULT_PROFILE_NAME }
	local i

	for i = 1, n do
		table.insert(result, names[i])
	end

	return result
end

-- Runs as the very first line of RunLoginSequence, strictly before
-- BTV:EnsureDB() - resolves which profile this character uses, migrates
-- any pre-existing account data into the Default profile exactly once,
-- and loads the resolved profile's data into BTVanillaDB (or leaves it
-- nil for a brand new profile with no snapshot yet, letting EnsureDB's own
-- `if not BTVanillaDB then BTVanillaDB = {} end` do the from-scratch seed,
-- which then gets captured into BTVanillaProfilesDB on the next save).
function BTV:ResolveActiveProfile()
	if not BTVanillaCharDB then
		BTVanillaCharDB = {
			activeProfile = self.DEFAULT_PROFILE_NAME,
			hasSelectedProfileBefore = false,
		}
	end

	if not BTVanillaProfilesDB then
		BTVanillaProfilesDB = {}
	end

	-- One-time migration: an account that already had BTVanillaDB data
	-- before this feature existed gets it copied into the Default profile
	-- exactly once. A fresh install (no BTVanillaDB at all yet) leaves
	-- this branch untaken - EnsureDB's own from-scratch seed handles that
	-- case below, same as it always has.
	if not BTVanillaProfilesDB[self.DEFAULT_PROFILE_NAME] and BTVanillaDB then
		BTVanillaProfilesDB[self.DEFAULT_PROFILE_NAME] = self:DeepCopyTable(BTVanillaDB)
	end

	if not BTVanillaCharDB.hasSelectedProfileBefore then
		self.pendingFirstLoginDialog = true
	end

	local activeProfile = BTVanillaCharDB.activeProfile or self.DEFAULT_PROFILE_NAME

	self.activeProfileName = activeProfile

	local snapshot = BTVanillaProfilesDB[activeProfile]

	if snapshot then
		BTVanillaDB = self:DeepCopyTable(snapshot)
	else
		BTVanillaDB = nil
	end
end

-- Writes the live BTVanillaDB back into BTVanillaProfilesDB[activeProfileName].
-- Called from the PLAYER_LOGOUT handler below (the reliable "flush on
-- session end" point - BTVanillaProfilesDB is an independent SavedVariable
-- from BTVanillaDB, so mutations to the live table never implicitly
-- propagate into it) and immediately before every ReloadUI() call this
-- feature triggers (belt-and-suspenders; ReloadUI() does trigger
-- PLAYER_LOGOUT in real vanilla, but this removes any doubt about ordering
-- on this modded client at zero cost). Deliberately NOT called from
-- EnsureDB() itself, which runs constantly all session long.
function BTV:SaveActiveProfileData()
	if not self.activeProfileName or not BTVanillaDB then
		return
	end

	BTVanillaProfilesDB = BTVanillaProfilesDB or {}
	BTVanillaProfilesDB[self.activeProfileName] = self:DeepCopyTable(BTVanillaDB)
end

-- Creates a new profile, seeded from the Default profile's current data
-- (not whichever profile happens to be active) so a brand new profile
-- always starts from a known-good baseline. Returns true on success, or
-- false plus a reason string the UI can display directly.
function BTV:CreateProfile(name)
	if not name or name == "" then
		return false, "Profile name cannot be empty."
	end

	BTVanillaProfilesDB = BTVanillaProfilesDB or {}

	if BTVanillaProfilesDB[name] then
		return false, "A profile named \"" .. name .. "\" already exists."
	end

	local defaultData = BTVanillaProfilesDB[self.DEFAULT_PROFILE_NAME]

	BTVanillaProfilesDB[name] = defaultData and self:DeepCopyTable(defaultData) or {}

	return true
end

-- Deletes a profile outright. Refuses the Default profile (never
-- deletable, per spec). Since "Delete profile" only ever appears in the
-- UI while the profile being deleted IS the currently active one, this
-- also falls back the character to Default so there's always a valid
-- active profile afterward - the caller (Settings.lua) still triggers the
-- ReloadUI() that actually applies this.
function BTV:DeleteProfile(name)
	if not name or name == self.DEFAULT_PROFILE_NAME then
		return false, "The Default profile cannot be deleted."
	end

	if not BTVanillaProfilesDB or not BTVanillaProfilesDB[name] then
		return false, "Profile \"" .. tostring(name) .. "\" does not exist."
	end

	BTVanillaProfilesDB[name] = nil

	if BTVanillaCharDB and BTVanillaCharDB.activeProfile == name then
		BTVanillaCharDB.activeProfile = self.DEFAULT_PROFILE_NAME
	end

	return true
end

-- Overwrites targetName's saved data with a copy of sourceName's - used by
-- "Copy from other profile." If targetName is the currently active
-- profile, the caller still needs to ReloadUI() afterward for the copied
-- data to actually take effect (the next login's BTV:ResolveActiveProfile
-- picks it up from BTVanillaProfilesDB normally - no special-casing of the
-- live BTVanillaDB table is needed here).
function BTV:CopyProfileInto(sourceName, targetName)
	if not BTVanillaProfilesDB or not BTVanillaProfilesDB[sourceName] then
		return false, "Source profile \"" .. tostring(sourceName) .. "\" does not exist."
	end

	if not targetName or targetName == "" then
		return false, "Invalid target profile."
	end

	BTVanillaProfilesDB[targetName] = self:DeepCopyTable(BTVanillaProfilesDB[sourceName])

	return true
end

-- Switches this character to a different (already-existing) profile:
-- flushes the current profile's live data, records the new choice, then
-- reloads the UI so the next login cleanly picks up the new profile's
-- data via the normal BTV:ResolveActiveProfile/EnsureDB path - this addon
-- has no live rebuild-everything-in-place mechanism, so a reload is the
-- safe way to apply a profile switch.
function BTV:SwitchProfile(name)
	if not BTVanillaProfilesDB or not BTVanillaProfilesDB[name] then
		return false, "Profile \"" .. tostring(name) .. "\" does not exist."
	end

	self:SaveActiveProfileData()

	BTVanillaCharDB = BTVanillaCharDB or {}
	BTVanillaCharDB.activeProfile = name
	BTVanillaCharDB.hasSelectedProfileBefore = true

	ReloadUI()

	return true
end

-- Shared "Enter the name for the new profile" dialog - used both by the
-- Profiles settings tab's "Create new profile" dropdown entry and by the
-- first-login dialog's "Create a named profile" button, so the two flows
-- can never drift apart. onCreated(name), if given, is called after a
-- successful create+switch - SwitchProfile already reloads the UI, so
-- onCreated only ever matters for validation-failure feedback today (see
-- Settings.lua's call site).
function BTV:ShowCreateProfileDialog(onCreated)
	self:ShowDialog({
		title = "New Profile",
		message = "Enter the name for the new profile",
		mode = "textinput",
		buttons = {
			{
				text = "Accept",
				isDefault = true,
				onClick = function(value)
					local ok, reason = BTV:CreateProfile(value)

					if ok then
						BTV:SwitchProfile(value)
					elseif reason then
						BTV:Print(reason)
					end

					if onCreated then
						onCreated(ok, value)
					end
				end,
			},
			{ text = "Cancel", onClick = function() end },
		},
	})
end

-- First-ever-login-with-profiles dialog for this character - see
-- BTV:ResolveActiveProfile (sets BTV.pendingFirstLoginDialog) and
-- RunLoginSequence's own tail call for when this fires.
function BTV:ShowFirstLoginDialog()
	local buttons = {
		{
			text = "I know what im doing, use default profile",
			isDefault = true,
			onClick = function()
				BTVanillaCharDB = BTVanillaCharDB or {}
				BTVanillaCharDB.hasSelectedProfileBefore = true
			end,
		},
		{
			text = "Create a named profile",
			onClick = function()
				BTV:ShowCreateProfileDialog()
			end,
		},
		{
			text = "Create a profile for this character",
			onClick = function()
				local charName = UnitName("player") or "Unknown"
				local realmName = GetRealmName() or "Unknown"
				local charProfileName = charName .. " - " .. realmName

				local ok, reason = BTV:CreateProfile(charProfileName)

				if ok then
					BTV:SwitchProfile(charProfileName)
				elseif reason then
					BTV:Print(reason)
				end
			end,
		},
	}

	-- 4th button only when this character has never chosen a profile
	-- before (always true here - this dialog only ever fires in that
	-- state) AND more than just Default already exists to choose from.
	if table.getn(self:GetProfileNames()) > 1 then
		table.insert(buttons, {
			text = "use existing profile",
			onClick = function()
				BTV:ShowDialog({
					title = "Use Existing Profile",
					message = "Choose a profile to use for this character.",
					mode = "dropdown",
					options = BTV:GetProfileNames(),
					buttons = {
						{
							text = "Accept",
							isDefault = true,
							onClick = function(value)
								if value then
									BTV:SwitchProfile(value)
								end
							end,
						},
						{ text = "Cancel", onClick = function() end },
					},
				})
			end,
		})
	end

	self:ShowDialog({
		title = "Welcome to TrustyBars",
		message = "Thank you for choosing TrustyBars, you are currently using the Profile \"Default\". " ..
			"The Default profile is locked and cannot be edited - Edit Layout mode and Settings changes are unavailable while it is active.\n\n" ..
			"Do you wish to create a new custom profile or a profile for this character?",
		mode = "confirm",
		buttons = buttons,
	})
end

function BTV:EnsureDB()
	if not BTVanillaDB then
		BTVanillaDB = {}
	end
	if BTVanillaDB.editMode == nil then
		BTVanillaDB.editMode = false
	end
	if BTVanillaDB.minimapAngle == nil then
		BTVanillaDB.minimapAngle = 200
	end

	-- Default true: matches the safe/native starting mode - default bars
	-- (1-5) keep Blizzard's own position/size/layout and can only be
	-- shown/hidden through TrustyBars until the user explicitly opts in
	-- (Settings.lua's General tab) to freely repositioning/resizing them
	-- like custom bars.
	if BTVanillaDB.useDefaultLayout == nil then
		BTVanillaDB.useDefaultLayout = true
	end

	-- Global border/spacing style (General tab checkbox): true = "modern"
	-- (today's Extra Bars 6-9 look - backdrop border, spacing 0), false =
	-- "vanilla" (today's default Bars 1-5 look - native UI-Quickslot2
	-- texture, captured native spacing). Default false so upgraders' bars
	-- 1-5 keep their current look; extra bars 6-9 do visually change to
	-- vanilla the first time this ships, since one global toggle can't
	-- preserve both groups' current-but-mismatched looks at once.
	if BTVanillaDB.modernBorderStyle == nil then
		BTVanillaDB.modernBorderStyle = false
	end

	-- Tracks which style every bar's CURRENTLY STORED buttonSize was last
	-- corrected for (BTV:ApplyGlobalButtonStyle, Bar.lua) - lets that
	-- function apply BTV.MODERN_BUTTON_SIZE_DELTA exactly once per real
	-- style transition instead of drifting further on every call (it's
	-- called unconditionally at every login). Seeded to the CURRENT style
	-- so an existing install's first load under this logic doesn't
	-- spuriously shift every bar's size.
	if BTVanillaDB.lastAppliedVanillaStyle == nil then
		BTVanillaDB.lastAppliedVanillaStyle = BTV:IsVanillaBorderStyle()
	end

	-- Global spacing/button-size overrides (General tab). When enabled,
	-- one slider value applies to every true action bar (default 1-5 +
	-- extra 6-9), locking each bar's own per-bar slider. Value is stored
	-- in the same space each slider itself uses (spacing: DISPLAYED,
	-- 0-based - see Settings.lua's spacing display-offset; buttonSize:
	-- real, no offset needed).
	if BTVanillaDB.globalSpacingEnabled == nil then
		BTVanillaDB.globalSpacingEnabled = false
	end

	if BTVanillaDB.globalSpacingValue == nil then
		BTVanillaDB.globalSpacingValue = 0
	end

	if BTVanillaDB.globalButtonSizeEnabled == nil then
		BTVanillaDB.globalButtonSizeEnabled = false
	end

	if BTVanillaDB.globalButtonSizeValue == nil then
		BTVanillaDB.globalButtonSizeValue = BTV.BUTTON_SIZE
	end

	-- Main Bar migration Part 2/3 (DefaultBars.lua's
	-- GetMainBarEffectivePage/RefreshMainBarSlots): both default true,
	-- matching real vanilla bar 1's own always-on native paging/stance-
	-- swap behavior unless the user explicitly opts out via the General
	-- tab (Settings.lua).
	if BTVanillaDB.mainBarPaginationEnabled == nil then
		BTVanillaDB.mainBarPaginationEnabled = true
	end
	if BTVanillaDB.mainBarStanceSwapEnabled == nil then
		BTVanillaDB.mainBarStanceSwapEnabled = true
	end

	-- Stance/Page Bar Assignment feature, Part 2:
	-- BTVanillaDB.mainBarStanceBarAssignment (stance index -> Extra Bar id)
	-- and BTVanillaDB.mainBarPageBarAssignment (a single Extra Bar id) are
	-- deliberately NOT seeded with a default value here - both stay nil
	-- (unassigned) until the user explicitly picks an Extra Bar for a given
	-- stance/the page-2 swap (Settings.lua's General tab). This mirrors
	-- every other "additive, not a replacement" toggle in this addon
	-- (mainBarPaginationEnabled/mainBarStanceSwapEnabled above): an
	-- unassigned stance or page falls all the way back to the original
	-- native-page-math behavior (DefaultBars.lua's GetMainBarSlotForIndex),
	-- so nothing about an existing tester's Main Bar changes the moment
	-- this feature ships, until they opt in per-stance/per-page.
	--
	-- BTVanillaDB.mainBarPageIndicatorScale (Part 4) IS safe to seed
	-- unconditionally here (default 1, no scaling) - unlike
	-- mainBarPageIndicatorPosition/NativeAnchor (DefaultBars.lua's
	-- CreatePageIndicatorContainer), it has no live-frame dependency, same
	-- reasoning as bagBarScale/latencyBarScale below.
	if BTVanillaDB.mainBarPageIndicatorScale == nil then
		BTVanillaDB.mainBarPageIndicatorScale = 1
	end

	-- BTVanillaDB.stanceBarPosition/stanceBarNativeAnchor are deliberately
	-- NOT seeded here with a default value the way every other field above
	-- is - same lazy-capture-on-first-real-build reasoning as
	-- bagBarPosition/bagBarNativeAnchor (DefaultBars.lua's
	-- CreateStanceBarContainer), since a real native anchor can only be
	-- captured from the real live ShapeshiftButton# frames, which don't
	-- exist meaningfully (or reliably report an active count) yet at
	-- EnsureDB time.

	-- Round 33 self-heal: BTV:CaptureStanceBarNativeGap's own sanity check
	-- (same `<= 0 or >= BUTTON_SIZE` bound) only guards FUTURE captures -
	-- it does nothing for a value already corrupted and persisted by the
	-- round-32 ordering bug this round fixed (live-confirmed real save:
	-- stanceBarNativeGap = -40.000000547098). An unconditional check-and-
	-- heal every EnsureDB call, rather than a one-shot migration marker, is
	-- deliberate - this session's own experience is that one-shot markers
	-- can fail to fire when expected under SavedVariables' account-wide
	-- semantics, and this check is cheap enough to just always run. Nil'ing
	-- a bad value simply makes it look like a fresh, never-captured save to
	-- BTV:CaptureStanceBarNativeGap's own guard, so the next login attempts
	-- a real capture again (now correctly ordered before
	-- CreateFixedSlotDefaultBars) instead of ever writing/leaving a bad
	-- number in place.
	if BTVanillaDB.stanceBarNativeGap
		and (BTVanillaDB.stanceBarNativeGap <= 0 or BTVanillaDB.stanceBarNativeGap >= self.BUTTON_SIZE) then
		BTVanillaDB.stanceBarNativeGap = nil
	end

	-- Tint-whole-button-on-range (Settings.lua General tab): default true
	-- preserves the behavior this addon has always shipped (whole-icon red
	-- tint on out-of-range) rather than switching everyone over to real
	-- Blizzard's actual behavior (hotkey-text-only tint) unannounced -
	-- users who prefer the Blizzard-accurate look opt in explicitly.
	if BTVanillaDB.tintWholeButtonOnRange == nil then
		BTVanillaDB.tintWholeButtonOnRange = true
	end

	-- General tab's "Disable Blizzard Art" checkbox (DefaultBars.lua's
	-- ApplyBlizzardArtVisibility). Default false: the native main-bar art
	-- (MainMenuBarArtFrame) stays visible exactly as it always has unless
	-- the user explicitly opts in to hiding it.
	if BTVanillaDB.disableBlizzardArt == nil then
		BTVanillaDB.disableBlizzardArt = false
	end

	-- "Snap to Adjacent Elements" (General tab, round 35/36) - default TRUE
	-- as of round 36 (changed from round 35's original default false): the
	-- user decided snapping should be the expected default experience now
	-- that Shift-to-disable (Item 3, BTV:ComputeSnapAdjustment) gives an
	-- easy escape hatch for anyone who wants unassisted free dragging for a
	-- single drag.
	if BTVanillaDB.snapToAdjacentElements == nil then
		BTVanillaDB.snapToAdjacentElements = true
	end

	-- Round 36 one-time correction: this codebase's own EnsureDB pattern
	-- above only ever seeds a field `if x == nil` - it will NOT retroactively
	-- flip an existing tester's save that already has
	-- snapToAdjacentElements = false explicitly written from round 35 (not
	-- nil). A one-shot marker (rather than an unconditional self-heal, this
	-- session's usual preference for anything position-corruption-related)
	-- is judged appropriate here specifically because the stakes are low
	-- and purely cosmetic - a marker that somehow doesn't fire (e.g. an
	-- account-wide SavedVariables race, per this file's own extensive
	-- anchorRecaptureDone/etc. history above) just means the user keeps
	-- their current explicit choice one login longer, never a broken
	-- feature or a corrupted position.
	if not BTVanillaDB.snapDefaultCorrectedOnce then
		BTVanillaDB.snapDefaultCorrectedOnce = true
		BTVanillaDB.snapToAdjacentElements = true
	end

	-- Bag Bar / Micro Menu (feature 3, DefaultBars.lua's
	-- CreateBagBarAndMicroMenu) enable flags. Default true: both stay
	-- visible exactly as native FrameXML already shows them unless the
	-- user explicitly disables one. BTVanillaDB.bagBarPosition/
	-- microMenuPosition/*NativeAnchor are deliberately NOT seeded here -
	-- same lazy-capture-on-first-real-build reasoning as
	-- stanceBarPosition above, since they can only be captured from the
	-- real live button frames, which don't exist yet at EnsureDB time.
	if BTVanillaDB.bagBarEnabled == nil then
		BTVanillaDB.bagBarEnabled = true
	end
	if BTVanillaDB.microMenuEnabled == nil then
		BTVanillaDB.microMenuEnabled = true
	end

	-- Stance Bar enable parity (bug-fix batch Fix 3) - same default-true
	-- reasoning as bagBarEnabled/microMenuEnabled above.
	if BTVanillaDB.stanceBarEnabled == nil then
		BTVanillaDB.stanceBarEnabled = true
	end

	-- Key Ring (bug-fix batch Fix 2) / Latency Bar (bug-fix batch Fix 3)
	-- enable parity - same default-true reasoning as bagBarEnabled/
	-- microMenuEnabled/stanceBarEnabled above: both match their real
	-- native default-visible state unless the user explicitly disables
	-- them. keyRingPosition/keyRingNativeAnchor and latencyBarPosition/
	-- latencyBarNativeAnchor are deliberately NOT seeded here - same lazy-
	-- capture-on-first-real-use idiom as stanceBarPosition/bagBarPosition
	-- above, since both can only be captured from their real live frames,
	-- which don't exist yet at EnsureDB time.
	if BTVanillaDB.keyRingEnabled == nil then
		BTVanillaDB.keyRingEnabled = true
	end
	if BTVanillaDB.latencyBarEnabled == nil then
		BTVanillaDB.latencyBarEnabled = true
	end
	if BTVanillaDB.latencyBarScale == nil then
		BTVanillaDB.latencyBarScale = 1
	end

	-- Experience Bar container (round 16 part 2, Part A) - default true:
	-- this is a core UI element (unlike the optional extras above), so it
	-- stays visible/movable exactly like real vanilla's own XP bar unless
	-- the user explicitly disables it. BTVanillaDB.expBarPosition/
	-- expBarNativeAnchor are deliberately NOT seeded here - same lazy-
	-- capture-on-first-real-build idiom as stanceBarPosition/
	-- latencyBarPosition above (DefaultBars.lua's
	-- CaptureExpBarPositionIfNeeded), since a real native anchor can only
	-- be captured from the real live MainMenuExpBar frame, which doesn't
	-- exist meaningfully at EnsureDB time.
	if BTVanillaDB.expBarEnabled == nil then
		BTVanillaDB.expBarEnabled = true
	end
	if BTVanillaDB.expBarScale == nil then
		BTVanillaDB.expBarScale = 1
	end

	-- "Better Experience Bar" text overlay (round 16 part 2, Part B) -
	-- default false: the XP bar looks and behaves exactly like vanilla
	-- (no extra text) until the user explicitly opts in via the Experience
	-- Bar's own settings page (Settings.lua's simpleBarPageConfigs["expbar"]
	-- - relocated off the General tab in round 17 item 5). Fully
	-- independent of expBarEnabled/expBarScale above - this only governs
	-- DefaultBars.lua's BTV:ApplyBetterExpBarVisual text overlay, never the
	-- container's own movability/scalability.
	if BTVanillaDB.betterExpBarEnabled == nil then
		BTVanillaDB.betterExpBarEnabled = false
	end

	-- Round 17 items 2/4: the 5 independently toggleable text segments
	-- (Settings.lua's Experience Bar page). All 5 default true - since the
	-- feature itself already defaults off via betterExpBarEnabled above,
	-- there's no "surprise new text" risk in defaulting every segment on;
	-- the user only ever sees any of this after explicitly opting in, at
	-- which point showing the fullest, most informative line by default
	-- (rather than guessing which subset they'd prefer) is the more useful
	-- starting point - they can trim it down per-segment from there.
	if BTVanillaDB.expBarShowCurrentOverMax == nil then
		BTVanillaDB.expBarShowCurrentOverMax = true
	end
	if BTVanillaDB.expBarShowPercent == nil then
		BTVanillaDB.expBarShowPercent = true
	end
	if BTVanillaDB.expBarShowLevel == nil then
		BTVanillaDB.expBarShowLevel = true
	end
	if BTVanillaDB.expBarShowRestedPercent == nil then
		BTVanillaDB.expBarShowRestedPercent = true
	end
	if BTVanillaDB.expBarShowRestedTotal == nil then
		BTVanillaDB.expBarShowRestedTotal = true
	end

	-- Round 17 item 3: BTVanillaDB.expBarColorEarned/expBarColorRested
	-- (plus their expBarNativeColor* pristine-snapshot counterparts) are
	-- deliberately NOT seeded here - same lazy-capture-on-first-real-use
	-- idiom as expBarPosition/expBarNativeAnchor above
	-- (DefaultBars.lua's BTV:CaptureExpBarColorsIfNeeded), since a real
	-- native color can only be read via GetStatusBarColor() off the real
	-- live MainMenuExpBar/ExhaustionLevelFillBar frames, which don't exist
	-- meaningfully at EnsureDB time.

	-- Round 22 item 2: BTVanillaDB.expBarFontSize follows the exact same
	-- lazy-capture idiom as hotkeyFontSize/countFontSize just above (this
	-- file's own comment on those two) - deliberately NOT seeded with a
	-- guessed numeric value here. The true native GameFontNormalSmall size
	-- can only be read via GetFont() (DefaultBars.lua's
	-- BTV:CaptureNativeExpBarFontIfNeeded), and this overlay's own spec is
	-- to start ONE SIZE SMALLER than that native default, not at some
	-- hardcoded constant that could drift from the real template's actual
	-- size on a different client build. Stays nil until the user moves
	-- Settings.lua's Experience Bar page Font Size slider; every apply path
	-- (BTV:ApplyBetterExpBarVisual's first-build, BTV:SetExpBarFontSize)
	-- treats nil as "native captured default minus one."

	-- Round 22 item 3: BTVanillaDB.expBarTextColor - unlike
	-- expBarColorEarned/Rested above, this is this addon's OWN FontString's
	-- color, not a native vanilla region's, so there is no live frame to
	-- lazily capture a "native" baseline from - a straight default (gold,
	-- matching typical WoW UI informational-text convention) is safe to
	-- seed unconditionally here, same as any other simple addon-owned
	-- default (e.g. expBarScale above).
	if not BTVanillaDB.expBarTextColor then
		BTVanillaDB.expBarTextColor = { r = 1, g = 0.82, b = 0 }
	end

	-- Round 31 item 2: rested-XP tick glow pulse's full fade-in/fade-out
	-- cycle length, seconds - customizable via Settings.lua's Experience Bar
	-- page Pulse Interval slider. Straight default (no live-frame capture
	-- needed, same as expBarTextColor above) matching the value this was
	-- hardcoded to before this round (DefaultBars.lua's
	-- EXP_BAR_RESTED_GLOW_PULSE_PERIOD_DEFAULT, kept in sync as the same
	-- literal in both places).
	if BTVanillaDB.expBarGlowPulseInterval == nil then
		BTVanillaDB.expBarGlowPulseInterval = 1.5
	end

	-- Key Ring Scale (bug-fix batch round 2, Issue B): default 1 (no
	-- scaling), same safe-to-seed-unconditionally reasoning as
	-- bagBarScale/latencyBarScale above - KeyRingButton is a single real
	-- native frame (DefaultBars.lua's BTV.KEYRING_BUTTON_NAME), so this
	-- has no live-frame dependency either.
	if BTVanillaDB.keyRingScale == nil then
		BTVanillaDB.keyRingScale = 1
	end

	-- Bag Bar / Micro Menu / Stance Bar Scale (bug-fix batch Fix 4).
	-- Default 1 (no scaling) is safe to seed unconditionally here, unlike
	-- bagBarSpacing/microMenuSpacing below - it doesn't depend on reading
	-- any live frame, just like bagBarEnabled above.
	if BTVanillaDB.bagBarScale == nil then
		BTVanillaDB.bagBarScale = 1
	end
	if BTVanillaDB.microMenuScale == nil then
		BTVanillaDB.microMenuScale = 1
	end
	if BTVanillaDB.stanceBarScale == nil then
		BTVanillaDB.stanceBarScale = 1
	end

	-- Bag Bar / Micro Menu / Stance Bar Orientation (chain-anchored
	-- container migration). Default false (horizontal) matches all three
	-- elements' real native layout - same reasoning as bagBarOrientation/
	-- microMenuOrientation having no live-frame dependency, so (unlike
	-- *Spacing below) they're safe to seed here rather than lazily at
	-- container-build time.
	if BTVanillaDB.bagBarOrientation == nil then
		BTVanillaDB.bagBarOrientation = false
	end
	if BTVanillaDB.microMenuOrientation == nil then
		BTVanillaDB.microMenuOrientation = false
	end
	if BTVanillaDB.stanceBarOrientation == nil then
		BTVanillaDB.stanceBarOrientation = false
	end

	-- BTVanillaDB.bagBarSpacing/microMenuSpacing/stanceBarSpacing/
	-- bagBarNativeSpacing/microMenuNativeSpacing/stanceBarNativeSpacing are
	-- deliberately NOT seeded here - same lazy-capture-on-first-real-build
	-- idiom as bagBarPosition/bagBarNativeAnchor
	-- above (DefaultBars.lua's CreateBagBarAndMicroMenu/
	-- CreateStanceBarContainer), since a real native gap baseline can only
	-- be measured from the real live button
	-- frames, which don't exist yet at EnsureDB time.

	-- Issue 3 (bug-fix batch): DefaultBars.lua's ComputeMajorityGap was
	-- previously fixed to use a sorted median instead of a majority-vote/
	-- tie-break scheme, but that fix had ZERO visible effect for any tester
	-- who had already logged in even once before it landed. Reason: every
	-- caller (CreateBagBarAndMicroMenu/CreateStanceBarContainer) only ever
	-- writes bagBarSpacing/microMenuSpacing/stanceBarSpacing (and their
	-- *NativeSpacing pairs) behind an `if not BTVanillaDB.xSpacing then ...
	-- end` lazy-capture guard - once ANY value (good or bad) is saved, that
	-- guard permanently skips recapturing it forever, so the improved
	-- median math never actually ran again for existing saves; only a
	-- brand-new SavedVariables file ever benefited from it. This is a
	-- narrow, dedicated one-time marker rather than another
	-- BTV.SCHEMA_VERSION bump specifically because bumping schemaVersion
	-- ALSO wipes BTVanillaDB.bars (every custom bar, id 6+) per the block
	-- below - far too destructive just to force these 6 fields to
	-- recapture. Clearing them here (once, ever - the persisted
	-- spacingRecaptureDone flag itself is the guard against repeating this
	-- on a later EnsureDB call, same session or not) makes
	-- CreateBagBarAndMicroMenu/CreateStanceBarContainer's own existing
	-- lazy-capture logic recompute all three elements' spacing fresh via
	-- the corrected median math on the very next login. Note this also
	-- resets any spacing value a user had manually adjusted via the
	-- Settings sliders for these three elements - unavoidable, since a
	-- stale pre-fix auto-capture and a deliberate user choice are stored in
	-- the exact same field with no way to tell them apart.
	if not BTVanillaDB.spacingRecaptureDone then
		BTVanillaDB.spacingRecaptureDone = true

		BTVanillaDB.bagBarSpacing = nil
		BTVanillaDB.bagBarNativeSpacing = nil
		BTVanillaDB.microMenuSpacing = nil
		BTVanillaDB.microMenuNativeSpacing = nil
		BTVanillaDB.stanceBarSpacing = nil
		BTVanillaDB.stanceBarNativeSpacing = nil
	end

	-- BTVanillaDB.hotkeyFontSize / countFontSize (Settings.lua's General
	-- tab) follow the exact same lazy-capture idiom as stanceBarPosition
	-- above, and for the same reason: the true native default font size
	-- can only be read live off a real FontString (Button.lua's
	-- self.hotkey/self.count, via GetFont() on their NumberFontNormalSmall/
	-- NumberFontNormal templates), which doesn't exist yet at EnsureDB
	-- time (this can run before PLAYER_LOGIN creates the first button).
	-- Both fields stay nil - never seeded with a guessed numeric value
	-- here - until the user actually moves one of the two sliders;
	-- Button.lua's Init/SetHotkeyFontSize/SetCountFontSize all treat nil
	-- as "use the native captured default" (BTV.NATIVE_HOTKEY_FONT/
	-- NATIVE_COUNT_FONT, captured once module-level the first time any
	-- button is created this session).

	-- Issue 1 (bug-fix batch round 6): the last several rounds' Main Bar
	-- migration work (schema versions 7/8) forced default bar 1's cfg.x/y
	-- to be recaptured via CaptureNativeAnchor, but no reordering/hide-
	-- before-capture bug was found in the current PLAYER_LOGIN sequence -
	-- EnsureDB() (which runs seedDefaultBars on a schema bump) is always
	-- the very first call in Core.lua's loadFrame OnEvent handler, strictly
	-- before CreateFixedSlotDefaultBars ever hides/reparents any real
	-- Blizzard button. A live-confirmed discrepancy between
	-- BTVanillaDB.defaultBars[1].x and ActionButton1's current GetLeft()
	-- was still reported, though - most likely explained by cfg.x (the
	-- mutable, live-applied field) having drifted away from cfg.nativeAnchor.x
	-- at some point via a manual drag while useDefaultLayout was off during
	-- earlier testing (turning useDefaultLayout back on does NOT snap cfg.x/y
	-- back to nativeAnchor - only the explicit "Reset to Blizzard Default"
	-- button, BTV:ResetDefaultBarLayout, does that), though a genuinely bad
	-- capture (doc 5k's still-open "does GetLeft()/GetTop() reliably reflect
	-- the frame's true, fully-settled native position at PLAYER_LOGIN time"
	-- question) can't be ruled out either. Either way, a fresh recapture
	-- fixes the symptom: nil out BTVanillaDB.defaultBars entirely (not a
	-- field-by-field clear) so the "if not BTVanillaDB.defaultBars" branch
	-- below runs seedDefaultBars completely fresh, re-deriving point/
	-- relativePoint/x/y AND nativeAnchor/nativeSpacing/fixedActionSlots/
	-- dynamicMainBar together from scratch - exactly what a schema bump
	-- already does, but WITHOUT wiping BTVanillaDB.bars (every custom/Extra
	-- Bar), which a real SCHEMA_VERSION bump would also destroy and is far
	-- too destructive just for this. Same one-time-only precedent as
	-- spacingRecaptureDone above (its own persisted flag is the guard
	-- against repeating this on every later EnsureDB call). NOTE: this also
	-- resets any position a user manually dragged for a default bar with
	-- useDefaultLayout off - same unavoidable caveat as spacingRecaptureDone.
	--
	-- The Page Indicator container (DefaultBars.lua's
	-- CreatePageIndicatorContainer) uses the identical GetLeft()/GetTop()
	-- capture technique at a similar point in the login sequence and was
	-- also reported mis-scaled/positioned - its own baseline fields are
	-- cleared under this same marker so both are corrected together.
	if not BTVanillaDB.anchorRecaptureDone then
		BTVanillaDB.anchorRecaptureDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

	-- Round 7: the recapture above (anchorRecaptureDone) was a one-time
	-- "reseed and hope" band-aid - it re-ran the exact same GetLeft()/
	-- GetTop() capture code that had the real bug (a missing
	-- GetEffectiveScale conversion between the native button's own
	-- effective-scale coordinate space and the target bar frame's, see
	-- CaptureNativeAnchor/CaptureNativeSpacing's own updated comments), so
	-- anyone who already ran through anchorRecaptureDone before this fix
	-- landed just got a fresh capture of the SAME wrong value, and the
	-- guard above now permanently blocks them from ever recapturing again.
	-- A second, independent one-time marker is needed (not reusing
	-- anchorRecaptureDone, since that flag is already true for existing
	-- testers) so every save - whether pre- or post- anchorRecaptureDone -
	-- gets exactly one fresh capture through the now scale-corrected math.
	-- Same "clear the mutable fields, not a schemaVersion bump" reasoning
	-- as anchorRecaptureDone above (a real bump would also wipe
	-- BTVanillaDB.bars, far too destructive just for this).
	if not BTVanillaDB.anchorScaleFixDone then
		BTVanillaDB.anchorScaleFixDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

	-- Round 8 root-cause fix: anchorScaleFixDone above re-ran the exact same
	-- CaptureNativeAnchor/CaptureNativeSpacing capture code, but at the same
	-- too-early MOMENT in the login sequence - live-confirmed reproducible
	-- symptom: the same ActionButton1:GetLeft() call returned a value
	-- matching the OLD captured number early at PLAYER_LOGIN, then a
	-- DIFFERENT value ~75.85px further right later in that same session
	-- (GetTop() and GetEffectiveScale() both bit-identical between the two
	-- reads, ruling out a scale-conversion bug and pointing squarely at some
	-- later Blizzard-native pass re-centering the MainMenuBar cluster after
	-- PLAYER_LOGIN's own OnEvent handlers already fired). The PLAYER_LOGIN
	-- handler at the bottom of this file now defers calling EnsureDB (and
	-- the rest of the login sequence) until WaitForNativeBarSettle confirms
	-- ActionButton1's real position has actually stopped changing, so this
	-- function's own captures are correct from here on - but anyone who
	-- already consumed anchorScaleFixDone before that timing fix landed is
	-- permanently blocked from ever recapturing by that guard alone, so a
	-- fresh, independent one-time marker is needed here too. Same "clear the
	-- mutable fields, not a schemaVersion bump" reasoning as
	-- anchorScaleFixDone/anchorRecaptureDone above (a real bump would also
	-- wipe BTVanillaDB.bars, far too destructive just for this) - and the
	-- same caveat applies: this also discards any position a user manually
	-- dragged for a default bar while useDefaultLayout was off.
	if not BTVanillaDB.anchorTimingFixDone then
		BTVanillaDB.anchorTimingFixDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

	-- Round 9 root-cause fix: anchorTimingFixDone above is a PERMANENT
	-- one-shot - whichever single login/reload first saw it nil is the
	-- only one that ever calls seedDefaultBars again; every call after
	-- that (this session or any future one) hits the `if not
	-- BTVanillaDB.defaultBars` branch below and finds it already non-nil,
	-- so nothing re-captures, no matter how that one shot turned out.
	-- Live-confirmed reproducible symptom: a later reload's RunLoginSequence
	-- diagnostic print shows NO drift at all this run (early and settled
	-- both 254.52 - ActionButton1 was already stable for the entire poll),
	-- while BTVanillaDB.defaultBars[1].x AND .nativeAnchor.x both still
	-- held the OLD wrong 178.67 - proving the diagnostic's accuracy on a
	-- given reload says nothing about whether the ONE shot that actually
	-- wrote defaultBars was accurate, since the one-shot guard was already
	-- spent before this reload even started polling.
	--
	-- The actual gap anchorTimingFixDone's fix left open: WaitForNativeBarSettle
	-- only proves LOCAL stability (two 0.1s-apart reads agree), and it was
	-- started from PLAYER_LOGIN - which fires strictly BEFORE any guarantee
	-- that Blizzard's own MainMenuBar-recentering pass (round 8's diagnosed
	-- cause) has even been scheduled yet, let alone completed. A poll that
	-- starts too early can still lock onto a plateau that only LOOKS final
	-- for 0.2s and isn't - reproducing the exact same bug the poll was
	-- built to catch. PLAYER_ENTERING_WORLD is the standard, well-established
	-- WoW event marking "the world/UI is now fully loaded and laid out"
	-- (fires after the loading screen on a real login, and again after
	-- every /reload while already in world) - strictly later than
	-- PLAYER_LOGIN in the client's fixed event order, so the login
	-- sequence (loadFrame, bottom of this file) is now gated on that event
	-- instead, giving Blizzard's own native layout pass far more room to
	-- have already finished by the time the poll even starts (the poll
	-- itself is kept as a defense-in-depth check, not removed - see
	-- loadFrame's own comment for why PLAYER_LOGIN alone was insufficient).
	-- Same "clear the mutable fields, not a schemaVersion bump" pattern as
	-- every marker above - anyone who already consumed anchorTimingFixDone
	-- against the old, too-early PLAYER_LOGIN-started poll gets exactly one
	-- more fresh capture here, now through the corrected event timing.
	if not BTVanillaDB.anchorEnterWorldFixDone then
		BTVanillaDB.anchorEnterWorldFixDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

	if not BTVanillaDB.schemaVersion or BTVanillaDB.schemaVersion < self.SCHEMA_VERSION then
		BTVanillaDB.schemaVersion = self.SCHEMA_VERSION
		BTVanillaDB.defaultBars = seedDefaultBars(self)
		BTVanillaDB.bars = {}
	end

	if not BTVanillaDB.defaultBars then
		BTVanillaDB.defaultBars = seedDefaultBars(self)
	end
	if not BTVanillaDB.bars then
		BTVanillaDB.bars = {}
	end

	-- Stance/Page Bar Assignment feature, Part 1: idempotent top-up, see
	-- EnsureExtraBars' own comment above for why this runs unconditionally
	-- here rather than only inside the schema-bump branch above.
	self:EnsureExtraBars()

	-- Force hoverbind off once per session (login/reload only - see the
	-- hasResetHoverBindModeThisSession comment above) so a stale/hand-edited
	-- saved value never silently starts a session with hoverbind enabled.
	-- Deliberately NOT unconditional: EnsureDB is called from many places
	-- mid-session (e.g. HoverBind.lua's ForEachButton), and stomping the
	-- field on every one of those calls would undo BTV:SetHoverBindMode(true)
	-- before the toggle's own caller ever sees the new value take effect.
	if not hasResetHoverBindModeThisSession then
		BTVanillaDB.hoverBindMode = false
		hasResetHoverBindModeThisSession = true
	end
end

function BTV:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccff[BTVanilla]|r " .. tostring(msg))
end

-------------------------------------------------------------------------
-- Snap to Adjacent Elements (round 35)
--
-- One shared, mechanism-agnostic utility used by every draggable element in
-- the addon via DefaultBars.lua's single shared DefaultBarDrag_OnUpdate
-- (bars 1-9 via Bar.lua's StartBarDrag/StopBarDrag AND Stance Bar, Bag Bar,
-- Micro Menu, Key Ring, Latency Bar, Experience Bar, Page Indicator - every
-- element wrapping a real/synthetic native frame instead of a bar-pool
-- frame). All of these share one live per-frame hook (round 36 unified
-- bars 1-9 onto this same mechanism, replacing their earlier native
-- bar:StartMoving()/StopMovingOrSizing() drop-time-only path), called every
-- tick right after DefaultBars.lua's ApplyDragSnap computes the proposed
-- pos.x/pos.y and before the relevant Apply*Position function actually
-- moves the real frame - giving every element live, real-time snapping
-- while dragging.
--
-- Both call sites are responsible for converting their own proposed
-- position into real screen pixels before calling this, and converting the
-- (possibly adjusted) result back into whatever units their own mechanism
-- stores - this function only ever works in real screen pixels itself, so
-- it never needs to know which mechanism/element kind is calling it.
-------------------------------------------------------------------------

-- Real screen pixels = region:GetLeft() * region:GetEffectiveScale() (also
-- true of GetRight()/GetTop()/GetBottom()) - the same conversion this
-- addon already relies on throughout (CaptureNativeAnchor/
-- CaptureNativeSpacing above, DefaultBars.lua's BuildChainAnchoredContainer)
-- - it's scale-agnostic and lets two elements with different effective
-- scales (e.g. a plain bar frame vs. a Bag Bar container the user scaled
-- to 1.5x) be compared directly in one common coordinate space, with no
-- per-pair special-casing needed. Returns nil if the region can't report a
-- position yet (e.g. hidden/never laid out).
--
-- `insetLeft/insetRight/insetTop/insetBottom` (v1.0 polish pass, optional,
-- each defaults to 0): default bars 1-5 draw a native-accurate border
-- texture (Button.lua's self.border) sized to BTV.BORDER_RATIO (66/36) of
-- the button - i.e. the VISIBLE border overhangs the button/bar frame on
-- every side (see BTV:GetElementVisualInset below, which is NOT symmetric
-- top vs. bottom - the border's own y=-1 anchor offset, round 16, live-
-- confirmed via diag2/diag9, makes the top overhang 1px less and the
-- bottom 1px more than the left/right overhang). Without this, two default
-- bars whose FRAMES snap flush end up with their VISIBLE borders
-- overlapping by that overhang amount - these four params (in the same
-- local units as GetLeft()/GetWidth(), pre-scale) let a caller expand the
-- reported bounds outward on each side independently so the box returned
-- actually matches the bar's visible extent, not just its frame.
local function GetRealScreenBounds(region, insetLeft, insetRight, insetTop, insetBottom)
	if not region or not region.GetLeft then
		return nil
	end

	insetLeft = insetLeft or 0
	insetRight = insetRight or 0
	insetTop = insetTop or 0
	insetBottom = insetBottom or 0

	local left, right, top, bottom = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
	local scale = region:GetEffectiveScale()

	if not left or not right or not top or not bottom or not scale then
		return nil
	end

	return (left - insetLeft) * scale, (right + insetRight) * scale, (top + insetTop) * scale, (bottom - insetBottom) * scale
end

-- (v1.0 polish pass, RE-ENABLED after live-client diagnosis) Returns how
-- far, in local units (pre-scale, same as GetLeft()/GetWidth()), a frame's
-- VISIBLE extent overhangs its own frame bounds on each side independently
-- - left, right, top, bottom - all 0 for anything without such an
-- overhang. Only default bars (id 1-5) currently have one: their buttons
-- draw a native-accurate border texture (Button.lua's self.border) at
-- BTV.BORDER_RATIO (66/36) of the button size, centered on the button
-- except for the BTV.BORDER_Y_OFFSET (1px) vertical nudge - a deliberate/
-- correct replication of real vanilla action-button art (round 15/16), not
-- a bug. Custom bars (id 6+) use a SetBackdrop edge inset essentially at
-- the frame edge, and every chain-anchored container/native-wrapped
-- element (Bag Bar, Micro Menu, Key Ring, Latency Bar, Exp Bar, Page
-- Indicator) has no known equivalent overhang, so they all return 0 here.
--
-- This was disabled for a while after an early live-client report that
-- the resulting overlay/snap boxes were far larger than intended - the
-- per-button math alone never explained that magnitude on paper, and a
-- prior single-uniform-value version of this function was suspected as
-- the culprit. Subsequent diagnostics (diag2, diag9) directly measured the
-- real border-vs-frame overhang on live bars and found it exactly matches
-- this formula (14px top / 16px bottom / 15px left / 15px right at the
-- default 36px button size - precisely BORDER_RATIO's per-side overhang
-- with the 1px BORDER_Y_OFFSET vertical asymmetry, nothing more) - so
-- whatever the original "way too big" report was actually measuring, it
-- was not this formula's own output. Re-enabled with full per-side
-- precision (the disabled version's replacement had only ever computed
-- one symmetric value for all 4 sides, silently wrong by 1px top/bottom).
function BTV:GetElementVisualInset(frame)
	-- Reads the same global border-style source of truth as Button.lua's
	-- Init/ApplyBorderStyle (BTV:IsVanillaBorderStyle) instead of a
	-- hardcoded id range, so this stays correct after the global
	-- border-style toggle changes which bars actually render the native
	-- border texture - the sizing FORMULA below is untouched, only the
	-- condition that decides whether to apply it at all. (Border-size-
	-- parity fallback: an attempt to give modern style an equally
	-- overhanging border overlay was reverted as broken/live-tested, back
	-- to modern's border living on its OWN bounded backdrop edge, which
	-- doesn't overhang at all - so this gates on vanilla style again.)
	if frame and frame.config and frame.config.id and self:IsVanillaBorderStyle() then
		local buttonSize = frame.config.buttonSize or self.BUTTON_SIZE
		local uniform = buttonSize * (self.BORDER_RATIO - 1) / 2
		local yOffset = self.BORDER_Y_OFFSET or 0
		local fudge = self.BORDER_TEXTURE_FUDGE or 0

		local left = uniform - fudge
		local right = uniform - fudge
		local top = uniform - yOffset - fudge
		local bottom = uniform + yOffset - fudge

		-- Floored at 0 (never a negative inset - that would flip the
		-- overlay/snap box to shrink INWARD past the frame instead of just
		-- stopping at it) - only matters for very small configured button
		-- sizes, where BORDER_TEXTURE_FUDGE could exceed the raw overhang.
		if left < 0 then left = 0 end
		if right < 0 then right = 0 end
		if top < 0 then top = 0 end
		if bottom < 0 then bottom = 0 end

		return left, right, top, bottom
	end

	return 0, 0, 0, 0
end

-- Every currently visible/enabled draggable element EXCEPT `excludeElement`
-- (the one actually being dragged), as real-screen-pixel bounding boxes -
-- shared by both drag mechanisms via BTV:ComputeSnapAdjustment below.
-- IsShown() is the sole visibility gate (matching how every one of these
-- elements is actually hidden - a plain :Hide() call, per Bar.lua's
-- SetExtraBarEnabled/DefaultBars.lua's SetBagBarEnabled and friends) so a
-- disabled element is naturally excluded with no separate enabled-flag
-- bookkeeping needed here.
function BTV:GetAllSnapTargetBoxes(excludeElement)
	local boxes = {}

	local function AddBox(frame)
		if not frame or frame == excludeElement then
			return
		end

		if not frame.IsShown or not frame:IsShown() then
			return
		end

		local left, right, top, bottom = GetRealScreenBounds(frame, self:GetElementVisualInset(frame))

		if left then
			table.insert(boxes, { left = left, right = right, top = top, bottom = bottom })
		end
	end

	-- Bars 1-5 (default bars) and Extra Bars 6-9 (custom bars) - both kinds
	-- live in this one table, keyed by id (Bar.lua's CreateAllBars/
	-- DefaultBars.lua's CreateFixedSlotDefaultBars).
	if self.bars then
		local barId

		for barId, bar in pairs(self.bars) do
			AddBox(bar)
		end
	end

	-- Chain-anchored containers (DefaultBars.lua's BuildChainAnchoredContainer).
	AddBox(self.bagBarContainer)
	AddBox(self.microMenuContainer)
	AddBox(self.stanceBarContainer)
	AddBox(self.pageIndicatorContainer)

	-- Single real native frames DefaultBars.lua wraps in place (never
	-- reparented into a synthetic container of our own).
	AddBox(getglobal(self.KEYRING_BUTTON_NAME))
	AddBox(getglobal(self.LATENCY_BAR_FRAME_NAME))
	AddBox(getglobal(self.EXP_BAR_FRAME_NAME))

	return boxes
end

-- Computes a snap-adjusted (proposedLeft, proposedTop), independently per
-- axis, given the dragged element's proposed real-screen-pixel top-left
-- corner and size. Returns adjustedLeft, adjustedTop - each nil if that
-- axis shouldn't snap (the caller should leave its own proposed value on
-- that axis untouched in that case).
--
-- Screen-edge/corner snapping only ever matches a dragged edge against the
-- SAME-side screen edge (dragged LEFT vs. screen LEFT, never screen RIGHT)
-- - per the feature's own spec, no crossed/opposite-side snapping. Corner
-- snapping falls out of this for free: a dragged element's bottom-right
-- corner "snaps to the screen's bottom-right corner" simply because its
-- RIGHT edge snaps to screenRight and its BOTTOM edge independently snaps
-- to screenBottom in the same call - no separate corner-case code needed.
--
-- Element-to-element snapping deliberately DOES allow crossed matching
-- (dragged LEFT vs. another element's LEFT *or* RIGHT) so pixel-perfect
-- edge-to-edge stacking (one bar's bottom touching another's top) is
-- possible, matching the feature's explicit stacking use case - screen
-- edges and other-element edges intentionally use different matching
-- rules for this reason.
function BTV:ComputeSnapAdjustment(proposedLeft, proposedTop, width, height, excludeElement)
	-- Item 3 (round 36): holding Shift temporarily disables snapping,
	-- exactly as if no target was within threshold on either axis. A
	-- single choke point here covers every caller uniformly (bars 1-9 via
	-- Bar.lua's StartBarDrag/StopBarDrag, all 7 chain-anchored elements via
	-- DefaultBars.lua's DefaultBarDrag_OnUpdate, and any future caller) with
	-- no need to duplicate this check at each drag call site.
	-- IsShiftKeyDown is a native, always-available WoW API on this client.
	if IsShiftKeyDown and IsShiftKeyDown() then
		return nil, nil
	end

	if not BTVanillaDB or not BTVanillaDB.snapToAdjacentElements then
		return nil, nil
	end

	if not proposedLeft or not proposedTop or not width or not height then
		return nil, nil
	end

	local threshold = self.SNAP_THRESHOLD or 8

	local proposedRight = proposedLeft + width
	local proposedBottom = proposedTop - height

	local adjustedLeft, bestLeftDist
	local adjustedTop, bestTopDist

	-- `edge` is the dragged element's own real-screen-pixel edge value on
	-- this axis right now (proposedLeft/proposedRight for X, proposedTop/
	-- proposedBottom for Y) - kept separate from proposedLeft/proposedTop
	-- themselves (the corner actually being solved for) since the RIGHT/
	-- BOTTOM edges need to snap too, but always resolve back to an
	-- adjustment of the TOPLEFT corner the caller actually stores.
	local function ConsiderX(candidate, edge)
		local dist = candidate - edge

		if dist < 0 then
			dist = -dist
		end

		if dist <= threshold and (not bestLeftDist or dist < bestLeftDist) then
			adjustedLeft = proposedLeft + (candidate - edge)
			bestLeftDist = dist
		end
	end

	local function ConsiderY(candidate, edge)
		local dist = candidate - edge

		if dist < 0 then
			dist = -dist
		end

		if dist <= threshold and (not bestTopDist or dist < bestTopDist) then
			adjustedTop = proposedTop + (candidate - edge)
			bestTopDist = dist
		end
	end

	-- Screen bounds, in the same real-screen-pixel space as everything
	-- else here - UIParent spans the whole screen, so its own edges ARE
	-- the screen's edges (same "GetLeft() * GetEffectiveScale()" technique
	-- as GetRealScreenBounds above, applied to UIParent specifically).
	local screenLeft, screenRight, screenTop, screenBottom = GetRealScreenBounds(UIParent)

	if screenLeft then
		ConsiderX(screenLeft, proposedLeft)
		ConsiderX(screenRight, proposedRight)
		ConsiderY(screenTop, proposedTop)
		ConsiderY(screenBottom, proposedBottom)
	end

	local boxes = self:GetAllSnapTargetBoxes(excludeElement)
	local i

	for i = 1, table.getn(boxes) do
		local box = boxes[i]

		ConsiderX(box.left, proposedLeft)
		ConsiderX(box.right, proposedLeft)
		ConsiderX(box.left, proposedRight)
		ConsiderX(box.right, proposedRight)

		ConsiderY(box.top, proposedTop)
		ConsiderY(box.bottom, proposedTop)
		ConsiderY(box.top, proposedBottom)
		ConsiderY(box.bottom, proposedBottom)
	end

	return adjustedLeft, adjustedTop
end

-------------------------------------------------------------------------
-- Global border/spacing style (General tab checkbox)
-------------------------------------------------------------------------

-- Single source of truth for the global border/spacing style - both
-- Button.lua's Init/ApplyBorderStyle AND GetElementVisualInset above
-- must read this exact function, never re-derive the id-based check
-- independently, or the two could disagree after the toggle flips.
function BTV:IsVanillaBorderStyle()
	if BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
		return true
	end

	return not (BTVanillaDB and BTVanillaDB.modernBorderStyle)
end

-- The buttonSize a brand-new bar should seed at, already correct for
-- whichever style is CURRENTLY active (BTV.MODERN_BUTTON_SIZE_DELTA) -
-- so a freshly created bar doesn't need an immediate correction from
-- BTV:ApplyGlobalButtonStyle's transition-only delta.
function BTV:GetCurrentButtonSizeBaseline()
	if self:IsVanillaBorderStyle() then
		return self.BUTTON_SIZE
	end

	return self.BUTTON_SIZE + self.MODERN_BUTTON_SIZE_DELTA
end

-------------------------------------------------------------------------
-- Edit mode ("Configure Layout")
-------------------------------------------------------------------------

function BTV:IsEditMode()
	-- Nil-safe: this can be queried before EnsureDB has run (e.g.
	-- UIDropDownMenu_Initialize appears to invoke its init callback once
	-- immediately at registration time, which happens at addon-load,
	-- before PLAYER_LOGIN creates BTVanillaDB). `and` short-circuits
	-- before ever indexing a nil BTVanillaDB, unlike a bare
	-- BTVanillaDB.editMode access.
	return BTVanillaDB and BTVanillaDB.editMode == true
end

-- The Default profile is a fixed, always-available baseline and must
-- never be edited - treats a nil activeProfile (not yet resolved) as
-- Default too, matching ResolveActiveProfile's own fallback.
function BTV:IsDefaultProfileActive()
	return not BTVanillaCharDB or BTVanillaCharDB.activeProfile == self.DEFAULT_PROFILE_NAME
end

function BTV:SetEditMode(enabled)
	self:EnsureDB()
	enabled = enabled and true or false

	if enabled and self:IsDefaultProfileActive() then
		self:Print("Edit Layout mode is disabled while the Default profile is active. Switch to another profile (Settings > Profiles) to edit your bar layout.")
		return
	end

	-- Edit mode always wins over hoverbind mode - force hoverbind off
	-- first rather than letting both run at once (their button-tint/
	-- click behaviors would fight each other). Uses the raw DB write +
	-- SetHoverBindMode(false) rather than ToggleHoverBindMode, since the
	-- latter's mutual-exclusion check would otherwise refuse to turn
	-- itself off here (IsEditMode would already read true if we set it
	-- first) - order matters: exit hoverbind BEFORE writing editMode.
	if enabled and self:IsHoverBindMode() then
		self:SetHoverBindMode(false)
	end

	BTVanillaDB.editMode = enabled
	self:ApplyEditModeVisual()
end

function BTV:ToggleEditMode()
	self:SetEditMode(not self:IsEditMode())
	self:Print(self:IsEditMode()
		and "Configure Layout ON - drag buttons to move bars, scroll to scale, right-click for bar settings. Hold Shift while dragging to temporarily disable snapping."
		or "Configure Layout OFF.")
end

-------------------------------------------------------------------------
-- Hoverbind mode
--
-- Mutually exclusive with edit mode (see SetEditMode above, which force-
-- exits hoverbind whenever edit mode turns on). Hoverbind itself refuses
-- to turn on while edit mode is active rather than force-exiting edit
-- mode - edit mode is the "senior" mode of the two.
-------------------------------------------------------------------------

function BTV:IsHoverBindMode()
	-- Nil-safe for the same reason as IsEditMode above.
	return BTVanillaDB and BTVanillaDB.hoverBindMode == true
end

function BTV:SetHoverBindMode(enabled)
	self:EnsureDB()
	enabled = enabled and true or false

	if enabled and self:IsEditMode() then
		self:Print("Cannot enable Hoverbind while Configure Layout is on.")
		return
	end

	BTVanillaDB.hoverBindMode = enabled

	-- HoverBind.lua owns the capture frame and the tint pass; Core.lua
	-- only owns the mode flag itself, matching how ApplyEditModeVisual is
	-- called from SetEditMode rather than inlined here.
	if self.ApplyHoverBindVisual then
		self:ApplyHoverBindVisual(enabled)
	end
end

function BTV:ToggleHoverBindMode()
	if not self:IsHoverBindMode() and self:IsEditMode() then
		self:Print("Cannot enable Hoverbind while Configure Layout is on.")
		return
	end

	self:SetHoverBindMode(not self:IsHoverBindMode())
	self:Print(self:IsHoverBindMode()
		and "Hoverbind ON - hover a button and press a key to bind it. Red = unbound, green = bound."
		or "Hoverbind OFF.")
end

-------------------------------------------------------------------------
-- Lock Action Bars
-------------------------------------------------------------------------
-- NOT a CVar on this client (an earlier version of this code guessed at
-- CVar names and hit a hard Lua error from GetCVar on an unrecognized
-- name). Confirmed live by the user: Blizzard's own Interface Options
-- "Lock Action Bars" checkbox reads/writes a plain global Lua variable,
-- LOCK_ACTIONBAR, stored as the STRING "0" (unlocked) or "1" (locked),
-- persisted the same way the client persists any other native UI global
-- (e.g. ACTIONBUTTON_SHOW_GRID) - not something we need to save
-- ourselves. Using this global directly as the single source of truth
-- means default bars (real Blizzard frames 1-5, natively governed by
-- this exact variable) and our own custom bars (which just call
-- IsLockActionBars()) both honor one shared flag with no extra wiring.

function BTV:IsLockActionBars()
	-- LOCK_ACTIONBAR may not exist as a global yet if Blizzard's own
	-- Interface Options code hasn't initialized it this session - treat
	-- nil the same as "0" (unlocked).
	return LOCK_ACTIONBAR == "1"
end

function BTV:SetLockActionBars(enabled)
	LOCK_ACTIONBAR = enabled and "1" or "0"
end

function BTV:ToggleLockActionBars()
	self:SetLockActionBars(not self:IsLockActionBars())
	self:Print(self:IsLockActionBars()
		and "Action bars locked - dragging a filled button no longer picks up its action."
		or "Action bars unlocked.")
end

-------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------

-- Round 8 root-cause fix: MainMenuBar's real native position is not
-- guaranteed final the instant PLAYER_LOGIN's own OnEvent handlers fire -
-- live-confirmed reproducible symptom (ActionButton1:GetLeft() read one
-- value at PLAYER_LOGIN time, a DIFFERENT value ~75.85px further right
-- later in that same session, with GetTop() and GetEffectiveScale() both
-- bit-identical between the two reads - ruling out a scale-conversion bug
-- and pointing squarely at some later Blizzard-native pass re-centering
-- the MainMenuBar cluster, most likely triggered by PLAYER_ENTERING_WORLD
-- or a similar init step that simply hasn't run yet the instant
-- PLAYER_LOGIN fires - no amount of this addon's own code running earlier
-- in the SAME synchronous OnEvent call can "wait through" a later event
-- that hasn't been dispatched yet). CaptureNativeAnchor/
-- CaptureNativeSpacing/CaptureFixedActionSlots (all called from
-- seedDefaultBars, via EnsureDB below) read straight off ActionButton1's
-- family of frames, so capturing before that settles bakes in the wrong,
-- pre-settle position permanently (only ever fixed by another one-time
-- recapture marker, per the anchorTimingFixDone comment above).
--
-- Rather than guessing a fixed wait (fragile across machines/load times),
-- WaitForNativeBarSettle polls ActionButton1's own real GetLeft()/GetTop()
-- on a short C_Timer.NewTicker (DLL-native - never build a raw OnUpdate
-- poll for this, per this addon's own established precedent in
-- Button.lua's rangeTicker/HoverBind.lua's hoverBindTintTicker) until two
-- consecutive reads agree, then runs the rest of the login sequence. A
-- generous 3s safety ceiling prevents a pathological "never settles" case
-- from hanging login forever - if hit, a warning is printed and login
-- proceeds anyway with whatever position is currently readable, same "log
-- and degrade gracefully" precedent as CaptureFixedActionSlots' own
-- fallback path.
--
-- Round 9 follow-up: this poll only proves LOCAL stability (two 0.1s-apart
-- reads agree) - it's not by itself a guarantee that the position will
-- never change again, and since EnsureDB's capture guard is a PERMANENT
-- one-shot (anchorTimingFixDone/`if not BTVanillaDB.defaultBars`, see
-- EnsureDB below), a single bad capture - e.g. this poll locking onto a
-- plateau that only looks final for 0.2s before the real recentering pass
-- moves the button again - is never retried by anything, ever, even though
-- a LATER reload's own diagnostic print (below) would show the position is
-- now correct. Live-confirmed: this is exactly what happened - see
-- loadFrame's own comment at the bottom of this file for the fix (starting
-- this poll from PLAYER_ENTERING_WORLD instead of PLAYER_LOGIN) and the
-- anchorEnterWorldFixDone marker in EnsureDB for the one-time recapture
-- this required for saves that already consumed anchorTimingFixDone
-- against the old, too-early timing.
local SETTLE_POLL_INTERVAL = 0.1
local SETTLE_STABLE_READS_REQUIRED = 2
local SETTLE_TIMEOUT = 3

local function WaitForNativeBarSettle(callback)
	local ref = getglobal("ActionButton1")

	if not ref or not C_Timer or not C_Timer.NewTicker then
		-- No reference frame, or no native ticker on this client build
		-- (should never happen - ActionButton1 is a core FrameXML frame
		-- and C_Timer is confirmed DLL-native, see the doc's summary
		-- table) - degrade to running immediately rather than never
		-- logging in at all.
		callback(nil, nil, nil, nil, 0)
		return
	end

	local earlyLeft, earlyTop = ref:GetLeft(), ref:GetTop()
	local lastLeft, lastTop = earlyLeft, earlyTop
	local stableCount = 0
	local elapsed = 0

	local ticker
	ticker = C_Timer.NewTicker(SETTLE_POLL_INTERVAL, function()
		elapsed = elapsed + SETTLE_POLL_INTERVAL

		local left, top = ref:GetLeft(), ref:GetTop()

		-- Stability is judged against the PREVIOUS tick's reading, not the
		-- early one - this is what actually detects "stopped changing",
		-- rather than just "returned to its original value once".
		if left and top and lastLeft and lastTop
			and left == lastLeft and top == lastTop then
			stableCount = stableCount + 1
		else
			stableCount = 0
		end

		lastLeft, lastTop = left, top

		local settled = stableCount >= SETTLE_STABLE_READS_REQUIRED
		local timedOut = elapsed >= SETTLE_TIMEOUT

		if settled or timedOut then
			ticker:Cancel()

			if timedOut and not settled then
				BTV:Print(
					"WARNING: native action bar position did not settle within " ..
					tostring(SETTLE_TIMEOUT) .. "s - proceeding with its current, " ..
					"possibly not-yet-final position."
				)
			end

			callback(earlyLeft, earlyTop, lastLeft, lastTop, elapsed)
		end
	end)
end

-- Everything below used to run synchronously and unconditionally the
-- instant PLAYER_LOGIN fired; it's now the callback WaitForNativeBarSettle
-- invokes once settled (or timed out). CreateAllBars (Extra Bars 6-9
-- only - default bars 1-5 are built separately further down) doesn't
-- itself read any captured native anchor, so it could in principle run
-- before the settle-poll completes - but splitting the sequence into two
-- phases just to let Extra Bars (which default to disabled anyway -
-- Core.lua's own seedExtraBarConfig) possibly appear a few tenths of a
-- second earlier isn't worth the added complexity/re-entrancy risk for
-- this addon. Keeping the whole sequence as one atomic block after the
-- poll also happens to be the least visually jarring outcome by
-- construction: nothing this addon owns has touched a single native frame
-- yet while the poll runs, so the user simply keeps seeing Blizzard's own
-- default UI (exactly as if TrustyBars hadn't loaded yet) for that brief
-- window, then TrustyBars' bars replace it fully-formed and correctly
-- positioned in one step - never a flash of a wrongly-placed custom bar.
local function RunLoginSequence(earlyLeft, earlyTop, settledLeft, settledTop, waited)
	-- Self-verifying diagnostic: proves in the user's own chat log, every
	-- login, whether a real settle-drift happened this session and by how
	-- much - no manual /run round-trip needed to confirm the fix is
	-- actually doing something (or to catch a regression later).
	if earlyLeft and settledLeft then
		BTV:Print(string.format(
			"Anchor capture: left early=%.2f settled=%.2f, top early=%.2f settled=%.2f (waited %.2fs)",
			earlyLeft, settledLeft, earlyTop or 0, settledTop or 0, waited or 0
		))
	end

	-- Profiles: resolves which profile this character uses and loads its
	-- data into BTVanillaDB BEFORE EnsureDB's own seeding/migration logic
	-- ever touches the table - see BTV:ResolveActiveProfile's own comment.
	BTV:ResolveActiveProfile()

	BTV:EnsureDB()
	BTV:CreateAllBars()

	-- Round 33 fix: must run BEFORE BTV:CreateFixedSlotDefaultBars() below,
	-- not after it (which is where this used to happen, nested inside
	-- DefaultBars.lua's CreateStanceBarContainer) - CreateFixedSlotDefaultBars
	-- permanently Hide()s bar 2's real MultiBarBottomLeftButton1-12 frames,
	-- and real vanilla 1.12.1 FrameXML reflows ShapeshiftBarFrame's own
	-- native anchor as a documented side effect of that bar's buttons'
	-- shown state changing (see DefaultBars.lua's SetDefaultBarEnabled
	-- comment, Issue 3/round 14) - so capturing the Stance Bar's native gap
	-- AFTER that Hide() pass reads ShapeshiftBarFrame back in an already-
	-- reflowed, collapsed state instead of its true native position. Live-
	-- confirmed corruption from the old ordering: stanceBarNativeGap =
	-- -40.000000547098 (screenBottom read as exactly 0). This capture needs
	-- nothing from CreateFixedSlotDefaultBars/CreateStanceBarContainer -
	-- only ShapeshiftBarFrame itself plus BTVanillaDB.defaultBars'
	-- nativeAnchor.y, both already available immediately after EnsureDB -
	-- so there's no reason to delay it any further than this.
	BTV:CaptureStanceBarNativeGap()

	-- Bars 1-5 (major architecture migration, Phases 1 and 2): builds each
	-- bar's own Bar.lua/Button.lua button pool - bars 2-5 from
	-- cfg.fixedActionSlots, bar 1 from cfg.dynamicMainBar (schema version
	-- 7) - and permanently hides its now-redundant real Blizzard buttons -
	-- see DefaultBars.lua's CreateFixedSlotDefaultBars. Must run BEFORE
	-- ApplyAllDefaultBars, since that now calls (for every default bar)
	-- SetDefaultBarEnabled/ApplyDefaultBarShape, both of which operate on
	-- self.bars[id] rather than the real Blizzard frames from this point
	-- on - those need to already exist.
	BTV:CreateFixedSlotDefaultBars()

	BTV:ApplyAllDefaultBars()

	-- Global border/spacing style (General tab checkbox): every bar
	-- (default 1-5 AND extra 6-9) now exists, so apply the currently
	-- saved global style to all of them - covers a fresh login where
	-- some/all bars have never had this sweep applied before, keeping
	-- them consistent with whatever the user last chose (or the seeded
	-- default).
	BTV:ApplyGlobalButtonStyle()

	-- Global spacing/button-size overrides (General tab): applied AFTER
	-- the border-style sweep above, so an active global override always
	-- wins over whatever that sweep's own per-bar delta just wrote.
	BTV:ApplyGlobalSpacing()
	BTV:ApplyGlobalButtonSize()

	-- Now a no-op for every default bar (Main Bar migration, Phase 2):
	-- bars 1-5's real Blizzard buttons are all now permanently hidden -
	-- see its own comment in HoverBind.lua. Kept as a harmless call rather
	-- than removed outright, in case a future default bar variant needs
	-- this hookup again.
	BTV:HookAllDefaultBarButtons()

	-- Stance Bar (chain-anchored container migration, DefaultBars.lua):
	-- builds the synthetic container from whatever real ShapeshiftButton#
	-- frames GetNumShapeshiftForms() reports as currently active, applies
	-- its saved (or freshly-captured native) position, and shows/hides per
	-- BTVanillaDB.stanceBarEnabled - exactly mirroring CreateBagBarAndMicroMenu
	-- below, unconditional of useDefaultLayout (that flag now only governs
	-- default bars 1-5's own separate positioning behavior, per
	-- ApplyDefaultBarShape). Idempotent (self.stanceBarContainer
	-- nil-checked internally) and a no-op if GetNumShapeshiftForms() is 0
	-- right now (e.g. this class/level has no stance mechanic yet) -
	-- DefaultBars.lua's UPDATE_SHAPESHIFT_FORMS listener calls
	-- RebuildStanceBarContainer later if/when that changes.
	BTV:CreateStanceBarContainer()

	-- Round 30 fix: force a one-time absolute recompute of the Stance Bar's
	-- Y baseline against bar 2's CURRENT enabled state every login/reload -
	-- not just the next time the user happens to toggle Action Bar 1
	-- themselves. DefaultBars.lua's ReflowStanceBarForBar2Toggle is only
	-- otherwise invoked from SetDefaultBarEnabled on an actual bar-2
	-- enabled-state CHANGE, so without this a stale/bad stanceBarPosition.y
	-- left over from a previous session's own capture-timing bug (see
	-- GetStanceBarBaselineY's own comment in DefaultBars.lua) would silently
	-- persist until the user manually toggled bar 2 once. Calling it here is
	-- always safe/idempotent - it's an absolute recompute, not a delta, so
	-- repeating it every login lands on the same correct value every time.
	-- Same useDefaultLayout gate as the toggle call site - a no-op once the
	-- user has taken manual control of the Stance Bar's position, so this
	-- can never fight a manually-dragged position.
	if BTVanillaDB.useDefaultLayout ~= false then
		local bar2Cfg = BTVanillaDB.defaultBars[2]
		BTV:ReflowStanceBarForBar2Toggle(bar2Cfg and bar2Cfg.enabled)
	end

	-- Bag Bar / Micro Menu (feature 3, DefaultBars.lua): builds the two
	-- synthetic chain-anchored containers once from the real live
	-- CharacterBag#Slot/MainMenuBarBackpackButton and #MicroButton
	-- frames, applies their saved (or freshly-captured native) position,
	-- and shows/hides per BTVanillaDB.bagBarEnabled/microMenuEnabled.
	-- Idempotent (self.bagBarContainer/microMenuContainer nil-checked
	-- internally), but only ever meaningfully runs once per session.
	BTV:CreateBagBarAndMicroMenu()

	-- Page Indicator (Stance/Page Bar Assignment feature, Part 4): builds
	-- the chain-anchored container wrapping the Main Bar's native page-turn
	-- arrows/number (DefaultBars.lua), applies its saved (or freshly-
	-- captured native) position/scale, and shows/hides per
	-- BTVanillaDB.mainBarPaginationEnabled (no independent enable flag of
	-- its own - see CreatePageIndicatorContainer's own comment). Run after
	-- ApplyAllDefaultBars, mirroring CreateStanceBarContainer/
	-- CreateBagBarAndMicroMenu's own placement above.
	BTV:CreatePageIndicatorContainer()

	-- Key Ring (bug-fix batch Fix 2): KeyRingButton is a single real
	-- native button (confirmed live to exist on this client), unmanaged
	-- until now - it stays natively anchored to whichever bag button it
	-- was originally anchored to (SetPoint targets a frame, not a parent,
	-- so reparenting that bag button into the Bag Bar's own container
	-- above doesn't change what KeyRingButton itself is anchored to), so
	-- it's given its own independent enable/position handling here,
	-- mirroring the Bag Bar's own unconditional-at-login position apply
	-- (BTV:ApplyKeyRingPosition self-heals via a lazy capture the same way
	-- BTV:ApplyBagBarPosition does).
	BTV:SetKeyRingEnabled(BTVanillaDB.keyRingEnabled ~= false)

	-- Key Ring Scale (bug-fix batch round 2, Issue B): applied before
	-- ApplyKeyRingPosition (which builds/refreshes the overlay and now
	-- wires SetKeyRingScale into its scroll-to-scale handler), mirroring
	-- how the Latency Bar's SetLatencyBarScale is applied before
	-- ApplyLatencyBarPosition just below.
	BTV:SetKeyRingScale(BTVanillaDB.keyRingScale or 1)
	BTV:ApplyKeyRingPosition()

	-- Latency Bar (bug-fix batch Fix 3): MainMenuBarPerformanceBarFrame is
	-- a direct sibling of MainMenuBarArtFrame (not a child), so hiding
	-- Blizzard Art doesn't affect it and it needs this same independent
	-- enable/scale/position handling default bars 1-5 already get (the
	-- Stance Bar no longer needs this useDefaultLayout-gated treatment,
	-- having migrated to an unconditionally-positioned chain-anchored
	-- container above - see BTV:CreateStanceBarContainer).
	--
	-- Issue 2 (bug-fix batch round 4): ApplyLatencyBarPosition is now
	-- ALWAYS called here, unconditionally - it used to be skipped entirely
	-- while useDefaultLayout == true (the default), which meant
	-- EnsureContainerOverlay (only ever called from inside
	-- ApplyLatencyBarPosition) never ran at login either, leaving the
	-- Latency Bar undraggable in Edit Layout mode until some later,
	-- unrelated call happened to invoke ApplyLatencyBarPosition (e.g. after
	-- toggling useDefaultLayout off and back on). This is safe to call
	-- unconditionally now: ApplyLatencyBarPosition only actually repositions
	-- the frame when BTVanillaDB.latencyBarPosition is already set, and the
	-- very first time it's ever set (CaptureLatencyBarPositionIfNeeded) is
	-- captured FROM this frame's own current native position - so this
	-- first call simply reasserts the frame exactly where it already
	-- natively is (a visual no-op) while also guaranteeing the overlay
	-- exists from login onward, exactly like Key Ring's own always-on
	-- ApplyKeyRingPosition call just above.
	BTV:SetLatencyBarEnabled(BTVanillaDB.latencyBarEnabled ~= false)
	BTV:SetLatencyBarScale(BTVanillaDB.latencyBarScale or 1)
	BTV:ApplyLatencyBarPosition()

	-- Experience Bar (round 16 part 2, Part A): MainMenuExpBar is a single
	-- self-contained real Blizzard frame, structurally the same kind of
	-- element as the Latency Bar above - same independent enable/scale/
	-- position treatment, applied unconditionally regardless of Part B's
	-- BTVanillaDB.betterExpBarEnabled (that toggle only governs the text
	-- overlay just below, never this container's own movability).
	BTV:SetExpBarEnabled(BTVanillaDB.expBarEnabled ~= false)
	BTV:SetExpBarScale(BTVanillaDB.expBarScale or 1)
	BTV:ApplyExpBarPosition()

	-- Bar-fill colors (round 17 item 3). Round 18 Bug 1 fix: this call
	-- itself is still unconditional, but BTV:ApplyExpBarColors (DefaultBars.lua)
	-- now internally gates on BTVanillaDB.betterExpBarEnabled before ever
	-- touching MainMenuExpBar/ExhaustionLevelFillBar's color - calling it
	-- unconditionally here used to ALSO apply unconditionally, which broke
	-- the native rested-XP overlay for every user regardless of whether they
	-- ever touched this feature. Safe to keep calling from here every login
	-- now that the function itself is the single choke point deciding
	-- whether anything actually happens.
	BTV:ApplyExpBarColors()

	-- "Better Experience Bar" text overlay (round 16 part 2, Part B) -
	-- creates/shows/hides the live percent-complete/percent-rested
	-- FontString per BTVanillaDB.betterExpBarEnabled; a no-op (stays
	-- hidden) when that setting is off, which is the default.
	BTV:ApplyBetterExpBarVisual()

	-- "Disable Blizzard Art" (feature 1, DefaultBars.lua): hides/shows
	-- MainMenuBarArtFrame per BTVanillaDB.disableBlizzardArt. Run after
	-- bar 1's real ActionButton1-12 frames are guaranteed to already
	-- exist (ApplyAllDefaultBars above), since the function defensively
	-- checks ActionButton1's parent before ever hiding anything.
	BTV:ApplyBlizzardArtVisibility()

	BTV:CreateMinimapButton()

	-- Issue 2 (bug-fix batch v5)'s hooksecurefunc("MultiActionBar_Update",
	-- ...) reconciliation - REMOVED (major architecture migration, Phase 1
	-- of 2). That hook existed only to keep bars 2-5 in sync with
	-- Blizzard's OWN native Interface Options checkbox, reconciling
	-- cfg.enabled from the SHOW_MULTI_ACTIONBAR_* globals via
	-- IsDefaultBarNativelyShown. Bars 2-5's real Blizzard buttons are now
	-- permanently hidden (see DefaultBars.lua's CreateFixedSlotDefaultBars)
	-- and never shown/hidden through the native mechanism again - our own
	-- saved cfg.enabled + bar:Show()/Hide() is now the SOLE visibility
	-- mechanism for these bars, so there is nothing left for this hook to
	-- reconcile. IsDefaultBarNativelyShown/SHOW_MULTI_ACTIONBAR_GLOBAL
	-- themselves have been removed from DefaultBars.lua for the same
	-- reason (dead code, per the migration plan).

	BTV:Print("Loaded. Click the minimap button for options.")

	-- Profiles: shown after everything above has finished building, so it
	-- doesn't visually collide with bar-creation flicker. Set by
	-- BTV:ResolveActiveProfile (called at the very top of this function)
	-- when this character has never explicitly chosen a profile before.
	if BTV.pendingFirstLoginDialog then
		BTV.pendingFirstLoginDialog = nil
		BTV:ShowFirstLoginDialog()
	end
end

-- Round 9 root-cause fix: this used to register PLAYER_LOGIN. Live-confirmed
-- bug with that: EnsureDB's anchorTimingFixDone/`if not
-- BTVanillaDB.defaultBars` capture guard is a PERMANENT one-shot (see its
-- own comment in EnsureDB above) - whichever single login/reload first
-- consumes it is the ONLY one that ever calls seedDefaultBars again, so
-- WaitForNativeBarSettle's poll only gets to do its job that one time. A
-- poll started from PLAYER_LOGIN has no guarantee Blizzard's own
-- MainMenuBar-recentering pass (round 8's diagnosed cause) has even been
-- scheduled yet, let alone completed, so it can lock onto a plateau that
-- only LOOKS final for the required two 0.1s-apart reads and isn't -
-- silently baking in the wrong position for good, since no later reload's
-- (correctly-timed) diagnostic print ever gets the chance to re-trigger a
-- capture once the one-shot guard is already spent.
--
-- PLAYER_ENTERING_WORLD is the well-established, standard WoW event
-- marking "the world/UI is now fully loaded and laid out" - it fires
-- strictly after PLAYER_LOGIN in the client's own fixed event order (after
-- the loading screen on a real login, and again after every /reload while
-- already in world), giving Blizzard's own native layout pass far more
-- room to have already finished before the settle-poll even starts
-- measuring. The poll itself is kept (not removed) as a defense-in-depth
-- check in case anything still shifts after that.
--
-- PLAYER_ENTERING_WORLD can fire more than once per session (every zone/
-- instance transition later on, not just login/reload) - unregistering it
-- the first time it fires keeps the whole login sequence a strict
-- once-per-UI-load event, matching PLAYER_LOGIN's own natural
-- once-per-load semantics.
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Profiles: flush the active profile's live data back into
-- BTVanillaProfilesDB on session end - see BTV:SaveActiveProfileData's own
-- comment for why this can't be left implicit (BTVanillaProfilesDB is an
-- independent SavedVariable from BTVanillaDB, so edits to the live table
-- never automatically propagate into it).
loadFrame:RegisterEvent("PLAYER_LOGOUT")

loadFrame:SetScript("OnEvent", function()
	if event == "PLAYER_LOGOUT" then
		BTV:SaveActiveProfileData()
		return
	end

	loadFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
	WaitForNativeBarSettle(RunLoginSequence)
end)

-- TEMPORARY live-diagnostic commands (v1.0 polish pass, overlay/snap
-- regression follow-up) - dump raw frame geometry to chat so it can be
-- read directly in-game instead of via a `/run` one-liner, which this
-- client caps at 511 characters including the leading "/run " (too short
-- for anything beyond a trivial single-frame check). Each of these exists
-- purely to gather the numbers docs/plan/default-bar-visual-inset-
-- regression.md and docs/plan/keyring-latency-expbar-overlay-inset.md ask
-- for - remove all three (and their SLASH_BTVANILLA1 dispatch entries
-- below) once those two follow-ups are resolved, the same way Round 10's
-- own temporary debug instrumentation was removed once it had served its
-- purpose.

function BTV:DiagKeyRingLatencyExpBar()
	local function dump(name)
		local f = getglobal(name)

		if not f then
			self:Print(name .. " missing")
			return
		end

		self:Print(name .. ": w=" .. tostring(f:GetWidth()) .. " h=" .. tostring(f:GetHeight()))

		local nt = f.GetNormalTexture and f:GetNormalTexture()

		if nt then
			self:Print("  NormalTexture w=" .. tostring(nt:GetWidth()) .. " h=" .. tostring(nt:GetHeight()))
		else
			self:Print("  no NormalTexture")
		end
	end

	dump("KeyRingButton")
	dump("MainMenuBarPerformanceBarFrame")
	dump("MainMenuExpBar")
end

function BTV:DiagDefaultBarInset(id)
	id = tonumber(id) or 1

	local bar = self.bars and self.bars[id]

	if not bar then
		self:Print("DiagDefaultBarInset: no bar with id " .. tostring(id))
		return
	end

	self:Print("bar " .. tostring(id) .. ": L=" .. tostring(bar:GetLeft()) ..
		" R=" .. tostring(bar:GetRight()) ..
		" T=" .. tostring(bar:GetTop()) ..
		" B=" .. tostring(bar:GetBottom()))

	local btn = bar.buttons and bar.buttons[1]

	if btn and btn.border then
		self:Print("button1.border: L=" .. tostring(btn.border:GetLeft()) ..
			" R=" .. tostring(btn.border:GetRight()) ..
			" T=" .. tostring(btn.border:GetTop()) ..
			" B=" .. tostring(btn.border:GetBottom()))
	end

	if btn and btn.icon then
		self:Print("button1.icon: L=" .. tostring(btn.icon:GetLeft()) ..
			" R=" .. tostring(btn.icon:GetRight()) ..
			" T=" .. tostring(btn.icon:GetTop()) ..
			" B=" .. tostring(btn.icon:GetBottom()))
	end

	local size = (bar.config and bar.config.buttonSize) or self.BUTTON_SIZE

	self:Print("formula inset would be: " .. tostring(size * (self.BORDER_RATIO - 1) / 2))
	self:Print("GetElementVisualInset actually returns: " .. tostring(self:GetElementVisualInset(bar)))
end

function BTV:DiagMicroMenuPageIndicator()
	local micro = {
		"CharacterMicroButton", "SpellbookMicroButton", "TalentMicroButton",
		"QuestLogMicroButton", "SocialsMicroButton", "WorldMapMicroButton",
		"MainMenuMicroButton", "HelpMicroButton",
	}

	local i

	for i = 1, table.getn(micro) do
		local f = getglobal(micro[i])

		if f then
			self:Print(micro[i] .. ": shown=" .. tostring(f:IsShown()) ..
				" L=" .. tostring(f:GetLeft()) ..
				" T=" .. tostring(f:GetTop()) ..
				" W=" .. tostring(f:GetWidth()) ..
				" H=" .. tostring(f:GetHeight()))
		end
	end

	if self.microMenuContainer then
		local c = self.microMenuContainer

		self:Print("microMenuContainer: L=" .. tostring(c:GetLeft()) ..
			" R=" .. tostring(c:GetRight()) ..
			" T=" .. tostring(c:GetTop()) ..
			" B=" .. tostring(c:GetBottom()))
	end

	local up = getglobal("ActionBarUpButton")
	local down = getglobal("ActionBarDownButton")
	local text = getglobal("MainMenuBarPageNumber")

	self:Print("ActionBarUpButton: " .. tostring(up and up:GetWidth()) .. "x" .. tostring(up and up:GetHeight()))
	self:Print("ActionBarDownButton: " .. tostring(down and down:GetWidth()) .. "x" .. tostring(down and down:GetHeight()))
	self:Print("MainMenuBarPageNumber: " .. tostring(text and text:GetWidth()) .. "x" .. tostring(text and text:GetHeight()))

	if self.pageIndicatorContainer then
		local c = self.pageIndicatorContainer

		self:Print("pageIndicatorContainer: L=" .. tostring(c:GetLeft()) ..
			" R=" .. tostring(c:GetRight()) ..
			" T=" .. tostring(c:GetTop()) ..
			" B=" .. tostring(c:GetBottom()))
	end
end

-- Live-tested: geometry alone (GetLeft/Right/Top/Bottom, GetWidth/Height)
-- says our default-bar border fully covers the icon with margin on every
-- side, but a live A/B against completely vanilla UI shows no gap at all
-- on the left - so the border TEXTURE's declared frame size and its
-- actually-drawn (visible) art apparently don't match 1:1. GetTexCoord()
-- is what would reveal that: if real vanilla's ActionButton1 NormalTexture
-- crops its UV rect away from the full 0..1 range (i.e. only shows part of
-- the source image) while ours doesn't, that crop is exactly what's
-- missing. GetTexCoord can return either 4 values (left, right, top,
-- bottom) or 8 (four corner x,y pairs) depending on this client's exact
-- API surface - printed generically via select("#", ...) rather than
-- assumed, per this repo's "don't guess API behavior" convention.
function BTV:DiagBorderTexCoord()
	local function dumpTexture(label, tex)
		if not tex then
			self:Print(label .. ": missing")
			return
		end

		self:Print(label .. ": texture=" .. tostring(tex:GetTexture()) ..
			" w=" .. tostring(tex:GetWidth()) .. " h=" .. tostring(tex:GetHeight()))

		local coords = { tex:GetTexCoord() }
		local n = table.getn(coords)
		local parts = {}
		local i

		for i = 1, n do
			parts[i] = tostring(coords[i])
		end

		self:Print(label .. ": GetTexCoord (" .. tostring(n) .. " values) = " .. table.concat(parts, ", "))
	end

	local bar = self.bars and self.bars[1]
	local btn = bar and bar.buttons and bar.buttons[1]

	if btn then
		self:Print("our button1: buttonSize=" .. tostring(btn.buttonSize) ..
			" w=" .. tostring(btn:GetWidth()) .. " h=" .. tostring(btn:GetHeight()))
		dumpTexture("our border", btn.border)
	else
		self:Print("our button1: not found")
	end

	local nativeBtn = getglobal("ActionButton1")

	if nativeBtn then
		self:Print("ActionButton1: w=" .. tostring(nativeBtn:GetWidth()) .. " h=" .. tostring(nativeBtn:GetHeight()))
		dumpTexture("ActionButton1 NormalTexture", nativeBtn.GetNormalTexture and nativeBtn:GetNormalTexture())
	else
		self:Print("ActionButton1: missing")
	end
end

-- Live-tested: Micro Menu's edit-mode overlay visibly extends well above
-- its buttons even though diag3's own container-vs-buttons comparison
-- came out exactly matching. This isolates whether the OVERLAY frame
-- itself (container.btvOverlay, a separate CreateFrame(..., UIParent)
-- SetAllPoints(container)) has actually drifted from `container`'s own
-- bounds - if these two blocks of numbers don't match, the bug is in how
-- the overlay tracks the container; if they DO match, the discrepancy is
-- somewhere else entirely (e.g. the backdrop border, or a completely
-- different frame being mistaken for this one).
function BTV:DiagMicroMenuOverlay()
	local c = self.microMenuContainer

	if not c then
		self:Print("microMenuContainer: missing")
		return
	end

	self:Print("microMenuContainer: L=" .. tostring(c:GetLeft()) ..
		" R=" .. tostring(c:GetRight()) ..
		" T=" .. tostring(c:GetTop()) ..
		" B=" .. tostring(c:GetBottom()))

	local overlay = c.btvOverlay

	if not overlay then
		self:Print("microMenuContainer.btvOverlay: missing")
		return
	end

	self:Print("microMenuContainer.btvOverlay: L=" .. tostring(overlay:GetLeft()) ..
		" R=" .. tostring(overlay:GetRight()) ..
		" T=" .. tostring(overlay:GetTop()) ..
		" B=" .. tostring(overlay:GetBottom()) ..
		" shown=" .. tostring(overlay:IsShown()))
end

-- Live-tested: diag4 showed our default-bar border texture is byte-for-
-- byte identical to real vanilla ActionButton1's (same texture path, same
-- size, same TexCoord) - so the earlier "border texture doesn't match its
-- own declared bounds" theory is disproven; the border itself renders
-- exactly like vanilla. The one confirmed difference between our default-
-- bar buttons and a real ActionButton1 is that ours ALSO gets a custom
-- SetBackdrop background fill (Button.lua's UpdateBackdropVisibility -
-- SetBackdropColor(0,0,0,0.75) applies even when hasNativeBorder is true,
-- only the backdrop BORDER color is skipped for those buttons) sitting on
-- the BACKGROUND layer, beneath everything else - a real ActionButton1 has
-- no such fill. If the border ring texture has any naturally see-through
-- area near where it approaches the icon (plausible for a decorative ring
-- asset), our backdrop fill would tint that sliver dark while vanilla
-- (with nothing behind it there) wouldn't. This zeroes bar 1's own
-- buttons' backdrop alpha for a quick visual A/B - if the gap disappears,
-- that confirms the theory; a /reload undoes this (nothing is saved).
function BTV:DiagZeroDefaultBarBackdropFill()
	local bar = self.bars and self.bars[1]

	if not bar or not bar.buttons then
		self:Print("DiagZeroDefaultBarBackdropFill: bar 1 not found")
		return
	end

	local i

	for i = 1, table.getn(bar.buttons) do
		local btn = bar.buttons[i]

		if btn then
			btn:SetBackdropColor(0, 0, 0, 0)
		end
	end

	self:Print("Bar 1's backdrop fill set to fully transparent - check the icon/border gap now. /reload to undo (nothing is saved).")
end

-- Live-tested: zeroing the backdrop fill (diag6) made the gap MORE visible,
-- not less - the opposite of what "backdrop tinting a transparent border
-- sliver" would predict. That disproves the backdrop theory: the backdrop
-- was actually partially MASKING a real, structural gap (by filling it
-- with black, similar in tone to whatever's normally behind it) rather
-- than causing one. Combined with diag4 already proving the border texture
-- itself is pixel-identical to vanilla, the last unverified piece specific
-- to hasNativeBorder buttons is whether OUR icon (Button.lua's flat
-- iconInset = 2, chosen for round 13/14's own reasoning, not necessarily
-- live-measured against vanilla's real icon) sits exactly where vanilla's
-- real icon does. This dumps ActionButton1's own icon texture
-- (ActionButton1Icon, the real global per FrameXML convention) bounds
-- directly next to our button1.icon's, so an inset mismatch (real vanilla
-- icon extending further outward, closer to where the border ring visually
-- starts, than ours) would show up as a straightforward before/after
-- comparison rather than a further guess.
function BTV:DiagIconInset()
	local nativeIcon = getglobal("ActionButton1Icon")

	if nativeIcon then
		self:Print("ActionButton1Icon: L=" .. tostring(nativeIcon:GetLeft()) ..
			" R=" .. tostring(nativeIcon:GetRight()) ..
			" T=" .. tostring(nativeIcon:GetTop()) ..
			" B=" .. tostring(nativeIcon:GetBottom()) ..
			" W=" .. tostring(nativeIcon:GetWidth()) ..
			" H=" .. tostring(nativeIcon:GetHeight()))
	else
		self:Print("ActionButton1Icon: missing")
	end

	local nativeBtn = getglobal("ActionButton1")

	if nativeBtn then
		self:Print("ActionButton1: L=" .. tostring(nativeBtn:GetLeft()) ..
			" R=" .. tostring(nativeBtn:GetRight()) ..
			" T=" .. tostring(nativeBtn:GetTop()) ..
			" B=" .. tostring(nativeBtn:GetBottom()))
	end

	local bar = self.bars and self.bars[1]
	local btn = bar and bar.buttons and bar.buttons[1]

	if btn and btn.icon then
		self:Print("our button1.icon: L=" .. tostring(btn.icon:GetLeft()) ..
			" R=" .. tostring(btn.icon:GetRight()) ..
			" T=" .. tostring(btn.icon:GetTop()) ..
			" B=" .. tostring(btn.icon:GetBottom()) ..
			" W=" .. tostring(btn.icon:GetWidth()) ..
			" H=" .. tostring(btn.icon:GetHeight()))

		self:Print("our button1: L=" .. tostring(btn:GetLeft()) ..
			" R=" .. tostring(btn:GetRight()) ..
			" T=" .. tostring(btn:GetTop()) ..
			" B=" .. tostring(btn:GetBottom()))
	else
		self:Print("our button1.icon: missing")
	end
end

-- Live-tested: even after anchoring the Micro Menu overlay directly to its
-- first/last SHOWN button's real frame bounds (v1.0 polish pass), the
-- overlay still looked too big. GetLeft/Right/Top/Bottom (what every prior
-- diagnostic measured) report a Button's FRAME bounds - but a real Button
-- widget can additionally define GetHitRectInsets(), which shrinks its
-- actual clickable/visually-relevant area within that frame without
-- changing the frame's own reported size at all. MicroButtons are known to
-- have a taller frame (58px, per diag3) than their visible icon art (a
-- decorative "flare" shape above/below the actual clickable button) - if
-- that extra height is expressed via a hit-rect inset rather than the
-- frame's own size, every earlier L/R/T/B-based diagnostic would have
-- missed it entirely, since none of them checked this. Dumps each Micro
-- Menu button's frame size next to its hit-rect insets (left, right, top,
-- bottom - the amount trimmed off each edge of the frame to get to the
-- real clickable rect, per the native GetHitRectInsets() API).
function BTV:DiagMicroMenuHitRects()
	local micro = {
		"CharacterMicroButton", "SpellbookMicroButton", "TalentMicroButton",
		"QuestLogMicroButton", "SocialsMicroButton", "WorldMapMicroButton",
		"MainMenuMicroButton", "HelpMicroButton",
	}

	local i

	for i = 1, table.getn(micro) do
		local f = getglobal(micro[i])

		if f then
			local w, h = f:GetWidth(), f:GetHeight()
			local left, right, top, bottom = f:GetHitRectInsets()

			self:Print(micro[i] .. ": frame=" .. tostring(w) .. "x" .. tostring(h) ..
				" hitInsets(L,R,T,B)=" .. tostring(left) .. ", " .. tostring(right) ..
				", " .. tostring(top) .. ", " .. tostring(bottom))
		end
	end
end

-- (v1.0 polish pass) Instead of guessing a blind "padding" constant for
-- default bars' still-slightly-off snap/overlay alignment, this measures
-- the ACTUAL gap between two bars the user has already positioned exactly
-- how they want them (both frame-to-frame and border-to-border, for
-- whichever button 1 has a border) - reusable for any pair of bar ids
-- (1-9), not just the two the user happens to ask about right now. Prints
-- both bars' own frame bounds, button 1's border bounds where
-- self.hasNativeBorder, and the horizontal (bar2.left - bar1.right) and
-- vertical (bar1.bottom - bar2.top) gaps for both frame and border edges -
-- whichever of the two actually corresponds to how the bars are arranged
-- is the number that matters; the other one is meaningless noise from
-- bars that aren't actually side by side/stacked in that direction.
function BTV:DiagBarGap(id1, id2)
	id1 = tonumber(id1)
	id2 = tonumber(id2)

	if not id1 or not id2 then
		self:Print("DiagBarGap: usage /btv diag9 <id1> <id2>")
		return
	end

	local bar1 = self.bars and self.bars[id1]
	local bar2 = self.bars and self.bars[id2]

	if not bar1 or not bar2 then
		self:Print("DiagBarGap: bar " .. tostring(not bar1 and id1 or id2) .. " not found")
		return
	end

	local function dump(id, bar)
		self:Print("bar " .. tostring(id) .. ": L=" .. tostring(bar:GetLeft()) ..
			" R=" .. tostring(bar:GetRight()) ..
			" T=" .. tostring(bar:GetTop()) ..
			" B=" .. tostring(bar:GetBottom()))

		local btn = bar.buttons and bar.buttons[1]

		if btn and btn.border then
			self:Print("bar " .. tostring(id) .. " button1.border: L=" .. tostring(btn.border:GetLeft()) ..
				" R=" .. tostring(btn.border:GetRight()) ..
				" T=" .. tostring(btn.border:GetTop()) ..
				" B=" .. tostring(btn.border:GetBottom()))

			return btn.border
		end

		return nil
	end

	local border1 = dump(id1, bar1)
	local border2 = dump(id2, bar2)

	self:Print("frame gap horizontal (bar" .. tostring(id2) .. ".L - bar" .. tostring(id1) .. ".R) = " ..
		tostring(bar2:GetLeft() - bar1:GetRight()))
	self:Print("frame gap vertical (bar" .. tostring(id1) .. ".B - bar" .. tostring(id2) .. ".T) = " ..
		tostring(bar1:GetBottom() - bar2:GetTop()))

	if border1 and border2 then
		self:Print("border gap horizontal (bar" .. tostring(id2) .. ".border.L - bar" .. tostring(id1) .. ".border.R) = " ..
			tostring(border2:GetLeft() - border1:GetRight()))
		self:Print("border gap vertical (bar" .. tostring(id1) .. ".border.B - bar" .. tostring(id2) .. ".border.T) = " ..
			tostring(border1:GetBottom() - border2:GetTop()))
	end
end

-- "diag10": the Profiles dialog (UIWidgets.lua's BTVDialogMixin) reported
-- live-tested as showing only its backdrop/border - fully draggable, no
-- Lua error, but title/message/buttons all invisible. Forces open a known
-- test dialog and dumps every child's IsShown/GetText/size/strata/level/
-- alpha so the actual runtime state is visible instead of guessed at from
-- source alone.
function BTV:DiagDialog()
	BTV:ShowDialog({
		title = "Diag10 Test Title",
		message = "Diag10 test message body.",
		mode = "confirm",
		buttons = {
			{ text = "Diag Button One", isDefault = true, onClick = function() end },
			{ text = "Diag Button Two", onClick = function() end },
		},
	})

	local dialog = BTV.activeDialog

	if not dialog then
		self:Print("DiagDialog: BTV.activeDialog is nil after ShowDialog - Mixin/OnLoad never completed.")
		return
	end

	self:Print("DiagDialog: dialog shown=" .. tostring(dialog:IsShown()) ..
		" w=" .. tostring(dialog:GetWidth()) ..
		" h=" .. tostring(dialog:GetHeight()) ..
		" strata=" .. tostring(dialog:GetFrameStrata()) ..
		" level=" .. tostring(dialog:GetFrameLevel()) ..
		" alpha=" .. tostring(dialog:GetAlpha()))

	if dialog.titleText then
		self:Print("DiagDialog: titleText shown=" .. tostring(dialog.titleText:IsShown()) ..
			" text='" .. tostring(dialog.titleText:GetText()) .. "'" ..
			" alpha=" .. tostring(dialog.titleText:GetAlpha()) ..
			" w=" .. tostring(dialog.titleText:GetWidth()) ..
			" fontObj=" .. tostring(dialog.titleText:GetFontObject()))
	else
		self:Print("DiagDialog: dialog.titleText is nil!")
	end

	if dialog.messageText then
		self:Print("DiagDialog: messageText shown=" .. tostring(dialog.messageText:IsShown()) ..
			" text='" .. tostring(dialog.messageText:GetText()) .. "'" ..
			" alpha=" .. tostring(dialog.messageText:GetAlpha()) ..
			" w=" .. tostring(dialog.messageText:GetWidth()))
	else
		self:Print("DiagDialog: dialog.messageText is nil!")
	end

	if dialog.buttons then
		local i

		for i = 1, 4 do
			local btn = dialog.buttons[i]

			if btn then
				self:Print("DiagDialog: button" .. tostring(i) ..
					" shown=" .. tostring(btn:IsShown()) ..
					" text='" .. tostring(btn:GetText()) .. "'" ..
					" strata=" .. tostring(btn:GetFrameStrata()) ..
					" level=" .. tostring(btn:GetFrameLevel()) ..
					" w=" .. tostring(btn:GetWidth()) ..
					" h=" .. tostring(btn:GetHeight()) ..
					" alpha=" .. tostring(btn:GetAlpha()))
			else
				self:Print("DiagDialog: button" .. tostring(i) .. " is nil!")
			end
		end
	else
		self:Print("DiagDialog: dialog.buttons is nil!")
	end
end

-- "diag11": live-investigating why BTV:SetDefaultBarEnabled's mirroring
-- of cfg.enabled into SHOW_MULTI_ACTIONBAR_1-4 doesn't visibly affect the
-- real Interface Options -> Action Bars checkboxes, unlike the confirmed-
-- working LOCK_ACTIONBAR/ALWAYS_SHOW_MULTIBARS globals (same plain-
-- global mechanism, per docs/01-Environment-Capability-Analysis.md §5i
-- and Button.lua's own IsAlwaysShowMultibars). Dumps every candidate's
-- CURRENT live value so a before/after comparison (toggle the real
-- checkbox, or our own Settings checkbox, then run this again) shows
-- exactly what does and doesn't change - no guessing.
function BTV:DiagMultiActionBar()
	self:Print("--- diag11: Multi-ActionBar state ---")

	self:Print("LOCK_ACTIONBAR = " .. tostring(LOCK_ACTIONBAR) .. " (type " .. type(LOCK_ACTIONBAR) .. ")")
	self:Print("ALWAYS_SHOW_MULTIBARS = " .. tostring(ALWAYS_SHOW_MULTIBARS) .. " (type " .. type(ALWAYS_SHOW_MULTIBARS) .. ")")

	local i

	for i = 1, 4 do
		local name = "SHOW_MULTI_ACTIONBAR_" .. tostring(i)
		local value = getglobal(name)

		self:Print(name .. " = " .. tostring(value) .. " (type " .. type(value) .. ")")
	end

	local frameNames = { "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarLeft", "MultiBarRight" }

	for i = 1, table.getn(frameNames) do
		local f = getglobal(frameNames[i])

		if f then
			self:Print(frameNames[i] .. ": IsShown=" .. tostring(f:IsShown()))
		else
			self:Print(frameNames[i] .. ": frame not found")
		end
	end

	-- Testing the user's own hypothesis: bars 2-5's real BUTTONS
	-- (MultiBar*Button1-12) have their :Show() permanently overridden to
	-- a no-op by CreateFixedSlotDefaultBars, so they can never actually
	-- become IsShown()=1 again regardless of the bar FRAME's or the
	-- SavedVariable's own state - if the real Options panel's "Right
	-- ActionBar 2 requires Right ActionBar 1" dependency check reads
	-- BUTTON-level visibility (not the frame's) to decide whether Bar 1
	-- currently "counts" as shown, that would explain Bar 2 staying
	-- greyed out no matter what the frame/global say.
	local id

	for id = 2, 5 do
		local buttonName = self.DEFAULT_BAR_FRAME_PREFIXES[id] .. "1"
		local button = getglobal(buttonName)

		if button then
			self:Print(buttonName .. ": IsShown=" .. tostring(button:IsShown()) ..
				" IsVisible=" .. tostring(button:IsVisible()))
		else
			self:Print(buttonName .. ": frame not found")
		end
	end

	self:Print("MultiActionBar_Update exists: " .. tostring(MultiActionBar_Update ~= nil))
	self:Print("SetActionBarToggles exists: " .. tostring(SetActionBarToggles ~= nil))
	self:Print("ShowMultiCastActionBar exists: " .. tostring(ShowMultiCastActionBar ~= nil))

	-- GetCVar throws a hard Lua error on an unrecognized CVar name on
	-- this client (§5i) - pcall-guarded so one bad guess doesn't abort
	-- the rest of this dump.
	local cvarCandidates = {
		"multiBarBottomLeft", "multiBarBottomRight", "multiBarLeft", "multiBarRight",
		"multibarBottomLeft", "multibarBottomRight", "multibarLeft", "multibarRight",
		"ShowMultiActionBar1", "showMultiActionBar1",
	}

	for i = 1, table.getn(cvarCandidates) do
		local ok, value = pcall(GetCVar, cvarCandidates[i])

		if ok and value ~= nil then
			self:Print("CVar " .. cvarCandidates[i] .. " = " .. tostring(value))
		end
	end

	self:Print("--- diag11 end ---")
end

-- "diag12": rather than guessing the real Interface Options -> Action
-- Bars panel's exact checkbox frame names (unconfirmed on this fork),
-- scans _G directly for anything CheckButton-shaped whose global name
-- mentions "ActionBar", and dumps each one's real IsEnabled()/
-- GetChecked() state - specifically to see whether "Right ActionBar 2"'s
-- checkbox genuinely reports IsEnabled()=false (confirming a real
-- dependency-driven disable, matching diag11's button-visibility
-- finding) or something else entirely once actually inspected live.
function BTV:DiagActionBarCheckboxes()
	self:Print("--- diag12: scanning _G for CheckButtons (open Options -> Action Bars first) ---")

	local key, value
	local found = 0

	for key, value in pairs(_G) do
		if type(key) == "string" and type(value) == "table" then
			local okType, objType = pcall(function() return value.GetObjectType and value:GetObjectType() end)

			if okType and objType == "CheckButton" then
				found = found + 1

				local okEnabled, enabled = pcall(function() return value:IsEnabled() end)
				local okChecked, checked = pcall(function() return value:GetChecked() end)

				self:Print(
					key ..
					": IsEnabled=" .. tostring(okEnabled and enabled) ..
					" GetChecked=" .. tostring(okChecked and checked)
				)
			end
		end
	end

	self:Print("Found " .. tostring(found) .. " matching CheckButtons.")
	self:Print("--- diag12 end ---")
end

-- "diag13": diag12 found zero named "ActionBar" checkboxes - the real
-- panel's checkboxes are anonymous (no global name), so walk the panel's
-- frame tree directly instead (anonymous children are still reachable
-- via GetChildren()). Open Options -> Action Bars first.
function BTV:DiagActionBarsPanelTree()
	self:Print("--- diag13: walking InterfaceOptionsFramePanelContainer tree ---")

	local container = getglobal("InterfaceOptionsFramePanelContainer") or getglobal("InterfaceOptionsFrame")

	if not container then
		-- Neither guessed name exists - scan _G for anything Frame-shaped
		-- whose name mentions "Interface" and "Option", so the real name
		-- can be found instead of guessing again.
		local key, value

		for key, value in pairs(_G) do
			if type(key) == "string" and type(value) == "table" and
				string.find(key, "Interface") and string.find(key, "Option") then
				self:Print("candidate: " .. key)
			end
		end
	end

	if not container then
		self:Print("Neither InterfaceOptionsFramePanelContainer nor InterfaceOptionsFrame found in _G.")
		self:Print("--- diag13 end ---")
		return
	end

	self:Print("Using container: " .. (container.GetName and container:GetName() or "?"))

	local children = { container:GetChildren() }
	local i

	for i = 1, table.getn(children) do
		local child = children[i]
		local name = (child.GetName and child:GetName()) or "(anonymous)"
		local okShown, shown = pcall(function() return child:IsShown() end)

		self:Print(name .. ": IsShown=" .. tostring(okShown and shown))

		-- Only recurse into the currently-SHOWN panel (the Action Bars
		-- one, if that's the tab open) - printing every panel's full
		-- child tree would be a huge, mostly-irrelevant dump.
		if okShown and shown then
			local grandchildren = { child:GetChildren() }
			local j

			for j = 1, table.getn(grandchildren) do
				local gc = grandchildren[j]
				local gcName = (gc.GetName and gc:GetName()) or "(anonymous)"
				local okType, objType = pcall(function() return gc.GetObjectType and gc:GetObjectType() end)

				if okType and objType == "CheckButton" then
					local okEnabled, enabled = pcall(function() return gc:IsEnabled() end)
					local okChecked, checked = pcall(function() return gc:GetChecked() end)

					self:Print(
						"  " .. gcName ..
						": CheckButton IsEnabled=" .. tostring(okEnabled and enabled) ..
						" GetChecked=" .. tostring(okChecked and checked)
					)
				else
					self:Print("  " .. gcName .. ": type=" .. tostring(okType and objType))
				end
			end
		end
	end

	self:Print("Child count: " .. tostring(table.getn(children)))
	self:Print("--- diag13 end ---")
end

-- "diag14": panel isn't stock vanilla (custom Options UI, no matching
-- name found via _G scans) - name-guessing is dead. Hover the mouse
-- directly over "Show Right ActionBar 2" and run this instead:
-- GetMouseFocus() returns whatever frame is under the cursor right now,
-- no name needed. Prints it and its parent chain.
function BTV:DiagMouseFocus()
	self:Print("--- diag14: GetMouseFocus() ---")

	local frame = GetMouseFocus and GetMouseFocus()

	if not frame then
		self:Print("GetMouseFocus() returned nothing - make sure the mouse is over the checkbox when you run this.")
		self:Print("--- diag14 end ---")
		return
	end

	local depth = 0

	while frame and depth < 6 do
		local name = (frame.GetName and frame:GetName()) or "(anonymous)"
		local okType, objType = pcall(function() return frame.GetObjectType and frame:GetObjectType() end)
		local okEnabled, enabled = pcall(function() return frame.IsEnabled and frame:IsEnabled() end)
		local okChecked, checked = pcall(function() return frame.GetChecked and frame:GetChecked() end)

		self:Print(
			string.rep("  ", depth) .. name ..
			" type=" .. tostring(okType and objType) ..
			" IsEnabled=" .. tostring(okEnabled and enabled) ..
			" GetChecked=" .. tostring(okChecked and checked)
		)

		frame = frame.GetParent and frame:GetParent()
		depth = depth + 1
	end

	self:Print("--- diag14 end ---")
end

-- "diag15": finds the greyed-out text region on checkbox 5 (Right
-- ActionBar 2, still grey even when enabled/checked) and dumps its
-- current color, plus checkbox 4's (normal, for comparison) - so the
-- exact RGB to force can be read directly instead of guessed.
function BTV:DiagCheckboxTextColor()
	self:Print("--- diag15: checkbox text colors ---")

	local names = {
		"OptionsFrameCheckButton4", "OptionsFrameCheckButton5",
		"OptionsFrameCheckButton4Control", "OptionsFrameCheckButton5Control",
		"OptionsFrameCheckButton4Text", "OptionsFrameCheckButton5Text",
	}
	local i

	for i = 1, table.getn(names) do
		local btn = getglobal(names[i])

		if not btn then
			self:Print(names[i] .. ": not found")
		elseif btn.GetObjectType and btn:GetObjectType() == "FontString" then
			local okColor, cr, cg, cb = pcall(function() return btn:GetTextColor() end)

			self:Print(
				names[i] .. " (itself a FontString) text='" .. tostring(btn:GetText()) .. "'" ..
				" color=" .. tostring(okColor and cr) .. "," .. tostring(okColor and cg) .. "," .. tostring(okColor and cb)
			)
		else
			local regions = { btn:GetRegions() }
			local j

			for j = 1, table.getn(regions) do
				local r = regions[j]
				local okType, objType = pcall(function() return r.GetObjectType and r:GetObjectType() end)

				if okType and objType == "FontString" then
					local okColor, cr, cg, cb, ca = pcall(function() return r:GetTextColor() end)

					self:Print(
						names[i] .. " region" .. tostring(j) .. " text='" .. tostring(r:GetText()) .. "'" ..
						" color=" .. tostring(okColor and cr) .. "," .. tostring(okColor and cg) .. "," .. tostring(okColor and cb)
					)
				end
			end
		end
	end

	self:Print("--- diag15 end ---")
end

-- "recapture" (Round 11): on-demand, deterministic alternative to the
-- account-wide one-shot markers in EnsureDB above - see
-- BTV:RecaptureDefaultBarNativeAnchors's own comment for why an automatic
-- "hope it fires on the next uncontrolled login" marker can't reliably be
-- proven to have run from a single pasted chat log. `msg` arrives as
-- whatever text follows "/btv " (empty string, not nil, when no argument is
-- given), matching this client's real vanilla slash-command handler
-- signature - a plain `SlashCmdList["BTVANILLA"] = function()` (no args)
-- would have thrown this argument away entirely.
SLASH_BTVANILLA1 = "/btv"
SlashCmdList["BTVANILLA"] = function(msg)
	if msg == "recapture" then
		BTV:RecaptureDefaultBarNativeAnchors()
	elseif msg == "diag1" then
		BTV:DiagKeyRingLatencyExpBar()
	elseif msg == "diag2" or string.find(msg, "^diag2 ") then
		local spacePos = string.find(msg, " ")
		local arg = spacePos and string.sub(msg, spacePos + 1) or nil

		BTV:DiagDefaultBarInset(arg)
	elseif msg == "diag3" then
		BTV:DiagMicroMenuPageIndicator()
	elseif msg == "diag4" then
		BTV:DiagBorderTexCoord()
	elseif msg == "diag5" then
		BTV:DiagMicroMenuOverlay()
	elseif msg == "diag6" then
		BTV:DiagZeroDefaultBarBackdropFill()
	elseif msg == "diag7" then
		BTV:DiagIconInset()
	elseif msg == "diag8" then
		BTV:DiagMicroMenuHitRects()
	elseif string.find(msg, "^diag9 ") then
		local rest = string.sub(msg, string.find(msg, " ") + 1)
		local spacePos = string.find(rest, " ")
		local id1 = spacePos and string.sub(rest, 1, spacePos - 1) or rest
		local id2 = spacePos and string.sub(rest, spacePos + 1) or nil

		BTV:DiagBarGap(id1, id2)
	elseif msg == "diag10" then
		BTV:DiagDialog()
	elseif msg == "diag11" then
		BTV:DiagMultiActionBar()
	elseif msg == "diag12" then
		BTV:DiagActionBarCheckboxes()
	elseif msg == "diag13" then
		BTV:DiagActionBarsPanelTree()
	elseif msg == "diag14" then
		BTV:DiagMouseFocus()
	elseif msg == "diag15" then
		BTV:DiagCheckboxTextColor()
	else
		BTV:ToggleMainMenu()
	end
end
