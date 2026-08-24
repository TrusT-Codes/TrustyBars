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

	-- Round 10 TEMPORARY instrumentation (see task record): proves, at the
	-- exact moment this function reads it, whether `first` really is the
	-- literal ActionButton1 the settle-poll and the user's own manual /run
	-- checks both reference directly (theory A), and exactly what GetLeft()
	-- returned for id right here (distinguishing a bad read here from a
	-- correct read here that gets stomped/misapplied later).
	self:Print(string.format(
		"DEBUG CaptureNativeAnchor: id=%s name=%s left=%s top=%s",
		tostring(id), tostring(first.GetName and first:GetName() or "?"),
		tostring(left), tostring(top)
	))

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

		result[id] = {
			-- Bar.lua/Button.lua/HoverBind.lua all key off bar.config.id
			-- (frame naming, BTV.DEFAULT_BAR_BINDING_PREFIXES lookups) -
			-- needed now that bars 2-5 run through that same machinery.
			-- Harmless for bar 1, which never reads it (still wraps its
			-- own real Blizzard frames directly, out of scope this pass).
			id = id,

			enabled = grid.enabled,
			point = anchor.point,
			relativePoint = anchor.relativePoint,
			x = anchor.x,
			y = anchor.y,
			cols = grid.cols,
			rows = grid.rows,
			buttonSize = self.BUTTON_SIZE,
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
-- round10DebugRecaptureDone, see EnsureDB below) was read character-by-
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

		buttonSize = self.BUTTON_SIZE,

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
	-- (no extra text) until the user explicitly opts in via the General
	-- tab (Settings.lua). Fully independent of expBarEnabled/expBarScale
	-- above - this only governs DefaultBars.lua's
	-- BTV:ApplyBetterExpBarVisual text overlay, never the container's own
	-- movability/scalability.
	if BTVanillaDB.betterExpBarEnabled == nil then
		BTVanillaDB.betterExpBarEnabled = false
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

	-- Round 10 TEMPORARY instrumentation marker (see task record): every
	-- prior recapture marker above (anchorRecaptureDone/anchorScaleFixDone/
	-- anchorTimingFixDone/anchorEnterWorldFixDone) is, by this point, already
	-- permanently consumed for anyone who tested a previous round - meaning
	-- BTVanillaDB.defaultBars is already non-nil and the `if not
	-- BTVanillaDB.defaultBars` branch below would otherwise NOT call
	-- seedDefaultBars again this session, so CaptureNativeAnchor's new debug
	-- print would never fire and no fresh data could be gathered. This
	-- one-shot marker forces exactly one more fresh capture, purely so this
	-- round's instrumentation actually runs and reports a live value - same
	-- "clear the mutable fields, not a schemaVersion bump" pattern as every
	-- marker above. Remove this block (and the debug prints it exists to
	-- feed) once round 10's diagnosis is complete.
	if not BTVanillaDB.round10DebugRecaptureDone then
		BTVanillaDB.round10DebugRecaptureDone = true

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

function BTV:SetEditMode(enabled)
	self:EnsureDB()
	enabled = enabled and true or false

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
		and "Configure Layout ON - drag buttons to move bars, scroll to scale, right-click for bar settings."
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

	-- Round 10 TEMPORARY instrumentation (see task record): one more direct
	-- read of the exact same global frame the settle-poll just finished
	-- polling, taken immediately before EnsureDB() (and therefore
	-- CaptureNativeAnchor, if this session's one-shot guard is still
	-- unconsumed) actually runs - proves whether ActionButton1 has already
	-- moved again by the time our own capture code gets control, with zero
	-- gap left unaccounted for.
	do
		local diagRef = getglobal("ActionButton1")
		if diagRef then
			BTV:Print(string.format(
				"DEBUG pre-EnsureDB: ActionButton1:GetLeft()=%s",
				tostring(diagRef:GetLeft())
			))
		end
	end

	BTV:EnsureDB()
	BTV:CreateAllBars()

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

	-- Round 10 TEMPORARY instrumentation (see task record): confirms
	-- whether ActionButton1's real GetLeft() is back to its "settled"
	-- value by the time the ENTIRE login sequence (EnsureDB,
	-- CreateFixedSlotDefaultBars hiding the real default-bar buttons,
	-- ApplyAllDefaultBars, etc.) has finished running - matches this
	-- against the user's own later manual /run checks.
	do
		local diagRef = getglobal("ActionButton1")
		if diagRef then
			BTV:Print(string.format(
				"DEBUG post-login-sequence: ActionButton1:GetLeft()=%s",
				tostring(diagRef:GetLeft())
			))
		end
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
loadFrame:SetScript("OnEvent", function()
	loadFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
	WaitForNativeBarSettle(RunLoginSequence)
end)

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
	else
		BTV:ToggleMainMenu()
	end
end
