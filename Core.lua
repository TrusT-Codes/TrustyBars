-- Core.lua
-- BTVanilla: Bartender2-style action bar addon for Vanilla 1.12.1.
--
-- Constraints this file depends on:
--   - No SecureHandler*/SecureActionButtonTemplate on this client. Custom
--     buttons are backed by real vanilla action slots instead.
--   - Vanilla action system: 120 slots (10 pages x 12). Pages 7-10 (slots
--     73-120) are free and never touched by the default UI.
--   - SetPoint/SetSize work unrestricted during combat. InCombatLockdown()
--     always returns false here - never gate logic on it.
--   - Lua 5.0 has no `%` operator - use n - (math.floor(n/d)*d) instead.

BTVanilla = {}
local BTV = BTVanilla

-- Action slot pool: pages 7-10, never surfaced by the default Blizzard UI.
BTV.ACTION_SLOT_START = 73
BTV.ACTION_SLOT_END   = 120

-- Defaults used when creating a NEW bar. Existing bars keep their own
-- saved config.
BTV.BUTTON_SIZE = 36
BTV.BUTTON_COLS = 12
BTV.BUTTON_ROWS = 1

-- Minimum bar spacing while vanilla border style is active, to avoid the
-- native border texture's overhang causing adjacent buttons to overlap.
-- 0 in modern style.
BTV.VANILLA_SPACING_FLOOR = 4

-- Extra buttonSize modern-style buttons need over vanilla-style ones to
-- look the same size (modern's border is bounded to its own frame, vanilla's
-- overhangs via a larger texture). Real spacing shifts by the same amount
-- in the opposite direction on a style switch, so buttonSize + spacing
-- stays visually constant - see BTV:ApplyGlobalButtonStyle.
BTV.MODERN_BUTTON_SIZE_DELTA = 4

-- Position nudge applied alongside MODERN_BUTTON_SIZE_DELTA so a bar
-- doesn't visually shift when its buttonSize grows/shrinks from an
-- anchored (not centered) corner.
BTV.MODERN_BUTTON_SIZE_POSITION_SHIFT = 2

-- Fixed pool size for a custom bar's button slots. Every grid preset the
-- Settings UI offers totals exactly 12 buttons. Buttons beyond a bar's
-- current buttonCount are hidden, never destroyed, so a bound action slot
-- stays valid across resizes/relayouts.
BTV.MAX_BAR_BUTTONS = 12

-- Equip-quality ring size ratio, matching vanilla's own ActionButtonTemplate.
BTV.EQUIP_RING_RATIO = 62 / 36

-- Native border texture ("Interface\Buttons\UI-Quickslot2") ratio to
-- button size (66/36 at the default 36px button).
BTV.BORDER_RATIO = 66 / 36

-- Vertical anchor offset of the native border texture (1px down from
-- center) - asymmetric top/bottom overhang.
BTV.BORDER_Y_OFFSET = 1

-- Flat pixel amount subtracted from the border's visual inset on every
-- side (transparent padding baked into the border texture asset).
BTV.BORDER_TEXTURE_FUDGE = 12

-- Extra top-only trim applied to the Micro Menu's edit-mode overlay,
-- beyond GetHitRectInsets().
BTV.MICRO_MENU_OVERLAY_TOP_FUDGE = 2

-- "Snap to Adjacent Elements": how close (real screen pixels) a dragged
-- edge must get to another edge before it snaps.
BTV.SNAP_THRESHOLD = 8

-- Schema version for BTVanillaDB.defaultBars/bars. Bumping this reseeds
-- default bars and wipes BTVanillaDB.bars - see EnsureDB below.
BTV.SCHEMA_VERSION = 8

-- One-shot per session (login/reload), not per EnsureDB call - see
-- EnsureDB's hoverBindMode reset.
local hasResetHoverBindModeThisSession = false

-- Captures a default bar's on-screen position from its first real
-- Blizzard button frame, converted to real screen pixels and expressed as
-- a UIParent-relative TOPLEFT/BOTTOMLEFT anchor.
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

-- Captures the native gap between adjacent buttons on default bar `id`.
-- Returns spacing (rounded to the nearest pixel), isUniform, and the raw
-- gaps array.
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

	-- Bucket gaps within 0.5px of each other, take the majority bucket.
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

	-- Convert from the native button family's own scale to the bar
	-- frame's scale (== UIParent's).
	local buttonScale = buttons[1]:GetEffectiveScale()
	local targetScale = UIParent:GetEffectiveScale()

	if buttonScale and targetScale and targetScale ~= 0 then
		majority.value = (majority.value * buttonScale) / targetScale
	end

	local spacing = math.floor(majority.value + 0.5)

	if spacing < 0 then
		spacing = 0
	end

	return spacing, uniform, gaps
end

-- Discovers default bar `id`'s (2-5) 12 real action-slot numbers from its
-- live Blizzard button frames (btn.action), falling back to the known
-- fixed multibar slot offsets if that field is missing.
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

-- Pet Bar: a 6th "default bar" family member, wrapping PetActionButton1-10.
-- Not backed by the 1-120 action-slot system (see Button.lua's isPetSlot
-- branch) - fixedActionSlots here is a pet-slot identity map (1-10), not
-- real action slots. Extra Bars occupy ids 6-9, so 10 is free.
BTV.PET_BAR_ID = 10

-- Stance Bar: a 7th "default bar" family member, styled-mode-only entry.
-- This id (and its BTVanillaDB.defaultBars[STANCE_BAR_ID] cfg) drives ONLY
-- the opt-in custom-styled grid mode (Button.lua's isStanceSlot branch) -
-- the pre-existing native mode (ShapeshiftButton1-N reparented into
-- BTV.stanceBarContainer, DefaultBars.lua) keeps using its own separate
-- top-level BTVanillaDB.stanceBar* fields entirely untouched. Which mode is
-- actually active is cfg.useNativeStanceBar (default true), resolved
-- through BTV:IsStanceBarNativeModeEffective().
BTV.STANCE_BAR_ID = 11

-- Every default-bar-family id, in display order. Loops that need to cover
-- "the whole default-bar family" (bars 1-5, Pet Bar, Stance Bar) iterate
-- this instead of a hardcoded 1-5 range.
BTV.DEFAULT_BAR_IDS = { 1, 2, 3, 4, 5, BTV.PET_BAR_ID, BTV.STANCE_BAR_ID }

-- True for any id in BTV.DEFAULT_BAR_IDS - the shared predicate every
-- useDefaultLayout-lock/"is this a default bar" check reads instead of a
-- hardcoded id range.
function BTV:IsDefaultBarFamilyId(barId)
	if not barId then
		return false
	end

	local i

	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		if self.DEFAULT_BAR_IDS[i] == barId then
			return true
		end
	end

	return false
end

-- Grid shape for each default bar. Position is captured live, not stored
-- here - see CaptureNativeAnchor.
BTV.DEFAULT_BAR_GRID = {
	[1] = { cols = 12, rows = 1 },                      -- Main.
	[2] = { cols = 12, rows = 1, enabled = false },      -- Bottom Left.
	[3] = { cols = 12, rows = 1, enabled = false },      -- Bottom Right.
	[4] = { cols = 1,  rows = 12, enabled = false },     -- Right.
	[5] = { cols = 1,  rows = 12, enabled = false },     -- Right 2.
	-- Pet Bar/Stance Bar default enabled (unlike bars 2-5, which are
	-- genuinely opt-in extras) - both have a native-mode counterpart that's
	-- always shown with no enable/disable concept of its own, so switching
	-- to styled mode should keep showing the bar, not hide it.
	[BTV.PET_BAR_ID] = { cols = 10, rows = 1, enabled = true }, -- Pet Bar.
	-- Stance Bar (styled mode): base preset only - SeedOneDefaultBar
	-- overrides cols/rows/buttonCount from the live GetNumShapeshiftForms()
	-- count right after using this table for the initial anchor/spacing
	-- capture's horizontal-orientation guess.
	[BTV.STANCE_BAR_ID] = { cols = 10, rows = 1, enabled = true },
}

-- Native FrameXML global backing each default bar's own Interface Options
-- checkbox. Session-scoped cosmetic use only - these globals do not
-- persist across a real logout on this client, so never read them as the
-- source of truth for what to apply at login. Pet Bar has no equivalent
-- native checkbox/global - table lookup is nil-safe wherever this is read.
BTV.SHOW_MULTI_ACTIONBAR_GLOBAL = {
	[2] = "SHOW_MULTI_ACTIONBAR_1",
	[3] = "SHOW_MULTI_ACTIONBAR_2",
	[4] = "SHOW_MULTI_ACTIONBAR_3",
	[5] = "SHOW_MULTI_ACTIONBAR_4",
}

-- Friendly display names for the default-bar family.
BTV.DEFAULT_BAR_NAMES = {
	[1] = "Main Bar",
	[2] = "Action Bar 1",
	[3] = "Action Bar 2",
	[4] = "Right Action Bar 1",
	[5] = "Right Action Bar 2",
	[BTV.PET_BAR_ID] = "Pet Bar",
	[BTV.STANCE_BAR_ID] = "Stance Bar",
}

-- Extra Bars (ids EXTRA_BAR_ID_START..+COUNT-1) are numbered from 1 for
-- the user. String-keyed chain-anchored elements (Bag Bar, Stance Bar,
-- etc.) are handled separately via EnsureContainerOverlay's displayName
-- argument.
function BTV:GetBarDisplayName(barId)
	if self.DEFAULT_BAR_NAMES[barId] then
		return self.DEFAULT_BAR_NAMES[barId]
	end

	if barId and barId >= 1 and barId <= 5 then
		return "Bar " .. tostring(barId)
	end

	return "Extra Bar " .. tostring((barId or 0) - 5)
end

-- Fallback anchor only used if CaptureNativeAnchor can't read a real
-- Blizzard frame at all.
local FALLBACK_ANCHOR = {
	[1] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 0 },
	[2] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 42 },
	[3] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 84 },
	[4] = { point = "RIGHT", relativePoint = "RIGHT", x = -18, y = 0 },
	[5] = { point = "RIGHT", relativePoint = "RIGHT", x = -58, y = 0 },
	[BTV.PET_BAR_ID] = { point = "BOTTOM", relativePoint = "BOTTOM", x = -200, y = 130 },
	-- Only used if CaptureNativeAnchor can't read a real ShapeshiftButton1
	-- this session (e.g. a class with zero learned forms at first login).
	[BTV.STANCE_BAR_ID] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 90 },
}

-- Builds one default-bar-family id's fresh saved config, capturing its
-- real native anchor/spacing/action-slots. Shared by seedDefaultBars (all
-- ids) and EnsureDB's migration path (a single missing id, e.g. an
-- existing save from before the Pet Bar existed).
local function SeedOneDefaultBar(self, id)
	local grid = self.DEFAULT_BAR_GRID[id]
	local anchor = CaptureNativeAnchor(self, id) or FALLBACK_ANCHOR[id]

	local spacing, uniform, gaps = CaptureNativeSpacing(self, id, grid)

	spacing = spacing or 0

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

	-- NOT read from BTV.SHOW_MULTI_ACTIONBAR_GLOBAL - that global does
	-- not survive a logout on this client.
	local enabled = grid.enabled

	local cfg = {
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
		buttonCount = grid.cols * grid.rows,

		-- Permanent pristine snapshot for "Reset to Blizzard Default".
		nativeAnchor = {
			point = anchor.point,
			relativePoint = anchor.relativePoint,
			x = anchor.x,
			y = anchor.y,
		},
		nativeSpacing = spacing,
	}

	if id == 1 then
		cfg.dynamicMainBar = true
	end

	if id >= 2 and id <= 5 then
		local fixedActionSlots, usedFallback = CaptureFixedActionSlots(self, id)

		if fixedActionSlots then
			cfg.fixedActionSlots = fixedActionSlots

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

	-- Pet Bar: pet slots 1-10 are an identity map (pool index N always
	-- drives pet slot N), not real action slots discovered from a live
	-- button's own .action field - no CaptureFixedActionSlots call needed.
	if id == self.PET_BAR_ID then
		cfg.isPetBar = true

		local petSlots = {}
		local ps

		for ps = 1, 10 do
			petSlots[ps] = ps
		end

		cfg.fixedActionSlots = petSlots

		-- Default off: matches real vanilla's own Pet Bar, which always
		-- shows all 10 slots blank where unassigned.
		cfg.condenseEmptyPetSlots = false
	end

	-- Stance Bar (styled mode): pool index N always drives shapeshift form
	-- index N directly (no "empty slot" concept - see Button.lua's
	-- isStanceSlot IsSlotFilled). Pool is a fixed MAX_STANCE_BUTTONS (10)
	-- slots so it never needs growing at runtime; cfg.buttonCount tracks
	-- the LIVE GetNumShapeshiftForms() count instead, and gets recomputed
	-- on UPDATE_SHAPESHIFT_FORMS (DefaultBars.lua) whenever that changes.
	if id == self.STANCE_BAR_ID then
		cfg.isStanceBar = true

		local stanceSlots = {}
		local ss

		for ss = 1, self.MAX_STANCE_BUTTONS do
			stanceSlots[ss] = ss
		end

		cfg.fixedActionSlots = stanceSlots

		local liveCount = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

		if liveCount > self.MAX_STANCE_BUTTONS then
			liveCount = self.MAX_STANCE_BUTTONS
		end

		cfg.cols = liveCount > 0 and liveCount or 1
		cfg.rows = 1
		cfg.buttonCount = liveCount

		-- Defaults on: today's only behavior (real ShapeshiftButton1-N),
		-- so an existing user sees no change until they opt into styled mode.
		if cfg.useNativeStanceBar == nil then
			cfg.useNativeStanceBar = true
		end
	end

	return cfg
end

-- Builds a fresh BTVanillaDB.defaultBars table for every default-bar-family
-- id (BTV.DEFAULT_BAR_IDS).
local function seedDefaultBars(self)
	local result = {}
	local i

	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		local id = self.DEFAULT_BAR_IDS[i]

		result[id] = SeedOneDefaultBar(self, id)
	end

	return result
end

-- On-demand recapture of every default bar's native anchor/spacing, run
-- synchronously so the caller can confirm the result immediately (unlike
-- an automatic one-shot marker, which can silently be consumed by an
-- earlier login on this account-wide SavedVariables setup). Reapplies
-- live if bars already exist this session.
function BTV:RecaptureDefaultBarNativeAnchors()
	self:EnsureDB()

	BTVanillaDB.defaultBars = nil
	BTVanillaDB.defaultBars = seedDefaultBars(self)

	self:Print("Recapture complete. New cfg.x/cfg.y per default bar:")

	local i

	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		local id = self.DEFAULT_BAR_IDS[i]
		local cfg = BTVanillaDB.defaultBars[id]

		if cfg then
			self:Print(string.format(
				"  Bar %d: x=%.2f y=%.2f (point=%s, relativePoint=%s)",
				id, cfg.x or -1, cfg.y or -1,
				tostring(cfg.point), tostring(cfg.relativePoint)
			))
		end
	end

	if self.bars and self.bars[1] then
		self:ApplyAllDefaultBars()
		self:Print("Live bar positions re-applied from the fresh capture.")
	end
end

-------------------------------------------------------------------------
-- Extra Bars 1-4 (ids 6-9)
--
-- Always exist in BTVanillaDB.bars, toggled via cfg.enabled rather than
-- added/removed. Each is still a real Bar.lua custom bar under the hood.
-------------------------------------------------------------------------

BTV.EXTRA_BAR_ID_START = 6
BTV.EXTRA_BAR_COUNT = 4

-- Allocates one Extra Bar's config. Position defaults to a vertical stack
-- under UIParent's center.
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

		enabled = false,
	}
end

-- Ensures exactly BTV.EXTRA_BAR_COUNT Extra Bar configs exist.
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
-- BTVanillaDB is always the active profile's live data. BTVanillaProfilesDB
-- (account-wide) stores every profile's data keyed by name.
-- BTVanillaCharDB (per-character) stores which profile this character
-- currently uses.
-------------------------------------------------------------------------

BTV.DEFAULT_PROFILE_NAME = "Default"

-- Plain recursive deep copy - BTVanillaDB only ever holds plain data.
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

-- Sorted list of every saved profile name, Default always first.
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

-- Resolves which profile this character uses, migrates any pre-existing
-- account data into Default exactly once, and loads the resolved
-- profile's data into BTVanillaDB. Must run before EnsureDB.
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
function BTV:SaveActiveProfileData()
	if not self.activeProfileName or not BTVanillaDB then
		return
	end

	BTVanillaProfilesDB = BTVanillaProfilesDB or {}
	BTVanillaProfilesDB[self.activeProfileName] = self:DeepCopyTable(BTVanillaDB)
end

-- Creates a new profile seeded from Default's current data.
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

-- Deletes a profile. Default is never deletable; deleting the active
-- profile falls the character back to Default.
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

		-- Also update the live in-memory pointer/data, not just
		-- BTVanillaCharDB's - otherwise PLAYER_LOGOUT's SaveActiveProfileData
		-- (fired by the caller's ReloadUI) saves BTVanillaDB back under the
		-- just-deleted name, resurrecting it (same class of bug fixed for
		-- CopyProfileInto/ApplyImportedProfileData above).
		self.activeProfileName = self.DEFAULT_PROFILE_NAME
		BTVanillaDB = self:DeepCopyTable(BTVanillaProfilesDB[self.DEFAULT_PROFILE_NAME] or {})
	end

	return true
end

-- Overwrites targetName's saved data with a copy of sourceName's.
function BTV:CopyProfileInto(sourceName, targetName)
	if not BTVanillaProfilesDB or not BTVanillaProfilesDB[sourceName] then
		return false, "Source profile \"" .. tostring(sourceName) .. "\" does not exist."
	end

	if not targetName or targetName == "" then
		return false, "Invalid target profile."
	end

	BTVanillaProfilesDB[targetName] = self:DeepCopyTable(BTVanillaProfilesDB[sourceName])

	if targetName == self.activeProfileName then
		BTVanillaDB = self:DeepCopyTable(BTVanillaProfilesDB[targetName])
	end

	return true
end

-------------------------------------------------------------------------
-- Profile export/import
--
-- A profile's data is serialized as this addon's own compact table-literal
-- syntax (a signature prefix followed by nested [key]=value pairs), not
-- executed as Lua - importing never runs loadstring on pasted text.
-------------------------------------------------------------------------

local PROFILE_EXPORT_PREFIX = "TBVPROFILE1:"

BTV.PROFILE_IMPORT_ERROR_MESSAGE =
	"Invalid Profile Import Syntax, please double check you copied all " ..
	"Text correctly on your Export and try again"

local function EscapeExportString(s)
	s = string.gsub(s, "\\", "\\\\")
	s = string.gsub(s, "\"", "\\\"")
	s = string.gsub(s, "\n", "\\n")
	s = string.gsub(s, "\r", "\\r")
	s = string.gsub(s, "\t", "\\t")

	return s
end

local function SerializeValue(value, parts)
	if type(value) == "table" then
		table.insert(parts, "{")

		local k, v

		for k, v in pairs(value) do
			if v ~= nil then
				table.insert(parts, "[")
				SerializeValue(k, parts)
				table.insert(parts, "]=")
				SerializeValue(v, parts)
				table.insert(parts, ",")
			end
		end

		table.insert(parts, "}")
	elseif type(value) == "string" then
		table.insert(parts, "\"" .. EscapeExportString(value) .. "\"")
	elseif type(value) == "number" then
		table.insert(parts, tostring(value))
	elseif type(value) == "boolean" then
		table.insert(parts, value and "true" or "false")
	else
		table.insert(parts, "nil")
	end
end

-- Serializes the currently active profile's live settings into a single
-- exportable string.
function BTV:ExportActiveProfileString()
	local parts = {}

	SerializeValue(BTVanillaDB, parts)

	return PROFILE_EXPORT_PREFIX .. table.concat(parts, "")
end

-- Manual recursive-descent parser matching SerializeValue's exact grammar -
-- a hand-rolled table literal ([key]=value pairs, quoted strings, numbers,
-- booleans), never Lua source that gets executed.
local function NewImportParser(str)
	return { str = str, pos = 1, len = string.len(str) }
end

local function SkipImportWhitespace(p)
	while p.pos <= p.len do
		local c = string.sub(p.str, p.pos, p.pos)

		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			p.pos = p.pos + 1
		else
			break
		end
	end
end

local ParseImportValue

local function ParseImportString(p)
	p.pos = p.pos + 1

	local resultParts = {}

	while true do
		if p.pos > p.len then
			return nil, "unterminated string"
		end

		local c = string.sub(p.str, p.pos, p.pos)

		if c == "\"" then
			p.pos = p.pos + 1
			break
		elseif c == "\\" then
			local nextC = string.sub(p.str, p.pos + 1, p.pos + 1)

			if nextC == "\\" then
				table.insert(resultParts, "\\")
			elseif nextC == "\"" then
				table.insert(resultParts, "\"")
			elseif nextC == "n" then
				table.insert(resultParts, "\n")
			elseif nextC == "r" then
				table.insert(resultParts, "\r")
			elseif nextC == "t" then
				table.insert(resultParts, "\t")
			else
				return nil, "bad escape sequence"
			end

			p.pos = p.pos + 2
		else
			table.insert(resultParts, c)
			p.pos = p.pos + 1
		end
	end

	return table.concat(resultParts, "")
end

local function ParseImportNumberOrKeyword(p)
	local startPos = p.pos

	while p.pos <= p.len do
		local c = string.sub(p.str, p.pos, p.pos)

		if c == "," or c == "}" or c == "]" then
			break
		end

		p.pos = p.pos + 1
	end

	local token = string.sub(p.str, startPos, p.pos - 1)

	if token == "true" then
		return true
	elseif token == "false" then
		return false
	elseif token == "nil" then
		return nil
	end

	local num = tonumber(token)

	if not num then
		return nil, "invalid token"
	end

	return num
end

local function ParseImportTable(p)
	p.pos = p.pos + 1

	local result = {}

	SkipImportWhitespace(p)

	if string.sub(p.str, p.pos, p.pos) == "}" then
		p.pos = p.pos + 1
		return result
	end

	while true do
		SkipImportWhitespace(p)

		if string.sub(p.str, p.pos, p.pos) ~= "[" then
			return nil, "expected '[' for table key"
		end

		p.pos = p.pos + 1
		SkipImportWhitespace(p)

		local key, keyErr = ParseImportValue(p)

		if key == nil and keyErr then
			return nil, keyErr
		end

		SkipImportWhitespace(p)

		if string.sub(p.str, p.pos, p.pos) ~= "]" then
			return nil, "expected ']' after table key"
		end

		p.pos = p.pos + 1
		SkipImportWhitespace(p)

		if string.sub(p.str, p.pos, p.pos) ~= "=" then
			return nil, "expected '=' after table key"
		end

		p.pos = p.pos + 1
		SkipImportWhitespace(p)

		local value, valueErr = ParseImportValue(p)

		if value == nil and valueErr then
			return nil, valueErr
		end

		if key ~= nil then
			result[key] = value
		end

		SkipImportWhitespace(p)

		local c = string.sub(p.str, p.pos, p.pos)

		if c == "," then
			p.pos = p.pos + 1
			SkipImportWhitespace(p)

			if string.sub(p.str, p.pos, p.pos) == "}" then
				p.pos = p.pos + 1
				break
			end
		elseif c == "}" then
			p.pos = p.pos + 1
			break
		else
			return nil, "expected ',' or '}' in table"
		end
	end

	return result
end

ParseImportValue = function(p)
	SkipImportWhitespace(p)

	if p.pos > p.len then
		return nil, "unexpected end of input"
	end

	local c = string.sub(p.str, p.pos, p.pos)

	if c == "{" then
		return ParseImportTable(p)
	elseif c == "\"" then
		return ParseImportString(p)
	else
		return ParseImportNumberOrKeyword(p)
	end
end

local function ParseImportBody(body)
	local p = NewImportParser(body)
	local value, err = ParseImportValue(p)

	if err then
		return nil
	end

	SkipImportWhitespace(p)

	if p.pos <= p.len then
		return nil
	end

	return value
end

-- Validates and parses an exported profile string without applying it.
-- Returns true, dataTable on success or false, errorMessage on failure.
function BTV:ParseProfileImportString(str)
	if type(str) ~= "string" then
		return false, self.PROFILE_IMPORT_ERROR_MESSAGE
	end

	local prefixLen = string.len(PROFILE_EXPORT_PREFIX)

	if string.sub(str, 1, prefixLen) ~= PROFILE_EXPORT_PREFIX then
		return false, self.PROFILE_IMPORT_ERROR_MESSAGE
	end

	local body = string.sub(str, prefixLen + 1)
	local ok, result = pcall(ParseImportBody, body)

	if not ok or type(result) ~= "table" then
		return false, self.PROFILE_IMPORT_ERROR_MESSAGE
	end

	return true, result
end

-- Overwrites the currently active profile (live data and its saved-profile
-- entry) with already-parsed import data - mirrors CopyProfileInto's dual
-- write so a PLAYER_LOGOUT-triggered SaveActiveProfileData right before the
-- caller's ReloadUI() can't clobber it.
function BTV:ApplyImportedProfileData(data)
	BTVanillaDB = self:DeepCopyTable(data)

	BTVanillaProfilesDB = BTVanillaProfilesDB or {}
	BTVanillaProfilesDB[self.activeProfileName] = self:DeepCopyTable(data)
end

-- Switches this character to an existing profile and reloads the UI.
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

-- Shared "enter a new profile name" dialog used by both the Profiles tab
-- and the first-login dialog.
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

-- First-ever-login-with-profiles dialog for this character.
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

	if BTVanillaDB.useDefaultLayout == nil then
		BTVanillaDB.useDefaultLayout = true
	end

	if BTVanillaDB.modernBorderStyle == nil then
		BTVanillaDB.modernBorderStyle = false
	end

	if BTVanillaDB.bypassRightActionBar2Dependency == nil then
		BTVanillaDB.bypassRightActionBar2Dependency = false
	end

	if BTVanillaDB.lastAppliedVanillaStyle == nil then
		BTVanillaDB.lastAppliedVanillaStyle = BTV:IsVanillaBorderStyle()
	end

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

	if BTVanillaDB.mainBarPaginationEnabled == nil then
		BTVanillaDB.mainBarPaginationEnabled = true
	end
	if BTVanillaDB.mainBarStanceSwapEnabled == nil then
		BTVanillaDB.mainBarStanceSwapEnabled = true
	end

	-- mainBarStanceBarAssignment/mainBarPageBarAssignment stay nil
	-- (unassigned) until the user explicitly picks an Extra Bar.

	if BTVanillaDB.mainBarPageIndicatorScale == nil then
		BTVanillaDB.mainBarPageIndicatorScale = 1
	end

	-- stanceBarPosition/stanceBarNativeAnchor are captured lazily on
	-- first real build (DefaultBars.lua), not seeded here.

	-- Self-heal a corrupted stanceBarNativeGap value every EnsureDB call
	-- (a bad capture nils it so the next login attempts a real capture).
	if BTVanillaDB.stanceBarNativeGap
		and (BTVanillaDB.stanceBarNativeGap <= 0 or BTVanillaDB.stanceBarNativeGap >= self.BUTTON_SIZE) then
		BTVanillaDB.stanceBarNativeGap = nil
	end

	if BTVanillaDB.tintWholeButtonOnRange == nil then
		BTVanillaDB.tintWholeButtonOnRange = true
	end

	if BTVanillaDB.disableBlizzardArt == nil then
		BTVanillaDB.disableBlizzardArt = false
	end

	if BTVanillaDB.snapToAdjacentElements == nil then
		BTVanillaDB.snapToAdjacentElements = true
	end

	-- One-time correction for saves that already had this explicitly
	-- false from before the default flipped to true.
	if not BTVanillaDB.snapDefaultCorrectedOnce then
		BTVanillaDB.snapDefaultCorrectedOnce = true
		BTVanillaDB.snapToAdjacentElements = true
	end

	if BTVanillaDB.showLayoutGrid == nil then
		BTVanillaDB.showLayoutGrid = true
	end

	if BTVanillaDB.snapToGrid == nil then
		BTVanillaDB.snapToGrid = true
	end

	if BTVanillaDB.useCustomGridSize == nil then
		BTVanillaDB.useCustomGridSize = false
	end

	if BTVanillaDB.bagBarEnabled == nil then
		BTVanillaDB.bagBarEnabled = true
	end
	if BTVanillaDB.microMenuEnabled == nil then
		BTVanillaDB.microMenuEnabled = true
	end

	if BTVanillaDB.stanceBarEnabled == nil then
		BTVanillaDB.stanceBarEnabled = true
	end

	if BTVanillaDB.keyRingEnabled == nil then
		BTVanillaDB.keyRingEnabled = true
	end
	if BTVanillaDB.latencyBarEnabled == nil then
		BTVanillaDB.latencyBarEnabled = true
	end
	if BTVanillaDB.latencyBarScale == nil then
		BTVanillaDB.latencyBarScale = 1
	end

	if BTVanillaDB.expBarEnabled == nil then
		BTVanillaDB.expBarEnabled = true
	end
	if BTVanillaDB.expBarScale == nil then
		BTVanillaDB.expBarScale = 1
	end

	-- Only-show-on-hover for simple elements (Bag Bar's pair also governs the Key Ring frame). Grid-bar cfg tables use nil-safe cfg.hoverOnly/cfg.hoverDuration reads instead.
	if BTVanillaDB.bagBarHoverOnly == nil then
		BTVanillaDB.bagBarHoverOnly = false
	end
	if BTVanillaDB.bagBarHoverDuration == nil then
		BTVanillaDB.bagBarHoverDuration = 3
	end

	if BTVanillaDB.microMenuHoverOnly == nil then
		BTVanillaDB.microMenuHoverOnly = false
	end
	if BTVanillaDB.microMenuHoverDuration == nil then
		BTVanillaDB.microMenuHoverDuration = 3
	end

	if BTVanillaDB.latencyBarHoverOnly == nil then
		BTVanillaDB.latencyBarHoverOnly = false
	end
	if BTVanillaDB.latencyBarHoverDuration == nil then
		BTVanillaDB.latencyBarHoverDuration = 3
	end

	if BTVanillaDB.expBarHoverOnly == nil then
		BTVanillaDB.expBarHoverOnly = false
	end
	if BTVanillaDB.expBarHoverDuration == nil then
		BTVanillaDB.expBarHoverDuration = 3
	end

	if BTVanillaDB.castBarScale == nil then
		BTVanillaDB.castBarScale = 1
	end

	if BTVanillaDB.betterExpBarEnabled == nil then
		BTVanillaDB.betterExpBarEnabled = false
	end

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

	-- expBarColorEarned/Rested (+ native snapshots) and expBarFontSize are
	-- captured lazily from the live frame, not seeded here.

	if not BTVanillaDB.expBarTextColor then
		BTVanillaDB.expBarTextColor = { r = 1, g = 0.82, b = 0 }
	end

	if BTVanillaDB.expBarGlowPulseInterval == nil then
		BTVanillaDB.expBarGlowPulseInterval = 1.5
	end

	if BTVanillaDB.keyRingScale == nil then
		BTVanillaDB.keyRingScale = 1
	end

	if BTVanillaDB.bagBarScale == nil then
		BTVanillaDB.bagBarScale = 1
	end
	if BTVanillaDB.microMenuScale == nil then
		BTVanillaDB.microMenuScale = 1
	end
	if BTVanillaDB.stanceBarScale == nil then
		BTVanillaDB.stanceBarScale = 1
	end

	if BTVanillaDB.bagBarOrientation == nil then
		BTVanillaDB.bagBarOrientation = false
	end
	if BTVanillaDB.microMenuOrientation == nil then
		BTVanillaDB.microMenuOrientation = false
	end
	if BTVanillaDB.stanceBarOrientation == nil then
		BTVanillaDB.stanceBarOrientation = false
	end

	-- bagBarSpacing/microMenuSpacing/stanceBarSpacing (+ native snapshots)
	-- are captured lazily on first real container build.

	-- One-time forced recapture of Bag Bar/Micro Menu/Stance Bar spacing,
	-- so an existing save picks up the corrected median-based capture
	-- math. Not a schema bump - that would also wipe BTVanillaDB.bars.
	if not BTVanillaDB.spacingRecaptureDone then
		BTVanillaDB.spacingRecaptureDone = true

		BTVanillaDB.bagBarSpacing = nil
		BTVanillaDB.bagBarNativeSpacing = nil
		BTVanillaDB.microMenuSpacing = nil
		BTVanillaDB.microMenuNativeSpacing = nil
		BTVanillaDB.stanceBarSpacing = nil
		BTVanillaDB.stanceBarNativeSpacing = nil
	end

	-- hotkeyFontSize/countFontSize/macroFontSize stay nil until the user
	-- moves a slider; Button.lua treats nil as "use the captured default".

	if BTVanillaDB.showMacroText == nil then
		BTVanillaDB.showMacroText = false
	end

	-- One-time forced recapture of default-bar native anchors/spacing
	-- (clears BTVanillaDB.defaultBars so seedDefaultBars reruns), without
	-- wiping BTVanillaDB.bars the way a schema bump would.
	if not BTVanillaDB.anchorRecaptureDone then
		BTVanillaDB.anchorRecaptureDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

	if not BTVanillaDB.anchorScaleFixDone then
		BTVanillaDB.anchorScaleFixDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

	if not BTVanillaDB.anchorTimingFixDone then
		BTVanillaDB.anchorTimingFixDone = true

		BTVanillaDB.defaultBars = nil

		BTVanillaDB.mainBarPageIndicatorNativeAnchor = nil
		BTVanillaDB.mainBarPageIndicatorPosition = nil
	end

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

	-- Migration-safe: an existing save from before the Pet Bar existed has
	-- BTVanillaDB.defaultBars already populated (ids 1-5) but no entry for
	-- BTV.PET_BAR_ID - seed just that one id rather than bumping
	-- SCHEMA_VERSION (which would wipe BTVanillaDB.bars).
	if not BTVanillaDB.defaultBars[self.PET_BAR_ID] then
		BTVanillaDB.defaultBars[self.PET_BAR_ID] = SeedOneDefaultBar(self, self.PET_BAR_ID)
	end

	-- Structural constants for the Pet Bar cfg, re-asserted every call so a
	-- save from before this field existed self-heals without a reseed.
	do
		local petCfg = BTVanillaDB.defaultBars[self.PET_BAR_ID]

		petCfg.isPetBar = true

		local petSlots = {}
		local ps

		for ps = 1, 10 do
			petSlots[ps] = ps
		end

		petCfg.fixedActionSlots = petSlots

		-- User-editable, so nil-checked rather than reasserted every call
		-- (unlike isPetBar/fixedActionSlots above), so an existing choice
		-- persists.
		if petCfg.condenseEmptyPetSlots == nil then
			petCfg.condenseEmptyPetSlots = false
		end

		if petCfg.animateAutoCastGlow == nil then
			petCfg.animateAutoCastGlow = false
		end
	end

	-- Migration-safe: an existing save from before the Stance Bar's styled
	-- mode existed has no entry for BTV.STANCE_BAR_ID - seed just that one
	-- id, same treatment as the Pet Bar migration above. This is purely
	-- additive - the pre-existing native-mode BTVanillaDB.stanceBar* fields
	-- are never touched here.
	if not BTVanillaDB.defaultBars[self.STANCE_BAR_ID] then
		BTVanillaDB.defaultBars[self.STANCE_BAR_ID] = SeedOneDefaultBar(self, self.STANCE_BAR_ID)
	end

	-- Structural constants for the Stance Bar cfg, re-asserted every call so
	-- a save from before this field existed self-heals without a reseed.
	do
		local stanceCfg = BTVanillaDB.defaultBars[self.STANCE_BAR_ID]

		stanceCfg.isStanceBar = true

		local stanceSlots = {}
		local ss

		for ss = 1, self.MAX_STANCE_BUTTONS do
			stanceSlots[ss] = ss
		end

		stanceCfg.fixedActionSlots = stanceSlots

		-- User-editable, so nil-checked rather than reasserted every call -
		-- an existing choice persists.
		if stanceCfg.useNativeStanceBar == nil then
			stanceCfg.useNativeStanceBar = true
		end
	end

	if not BTVanillaDB.bars then
		BTVanillaDB.bars = {}
	end

	self:EnsureExtraBars()

	-- Force hoverbind off once per session, not on every EnsureDB call
	-- (which would stomp BTV:SetHoverBindMode(true) mid-session).
	if not hasResetHoverBindModeThisSession then
		BTVanillaDB.hoverBindMode = false
		hasResetHoverBindModeThisSession = true
	end
end

function BTV:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccff[BTVanilla]|r " .. tostring(msg))
end

-------------------------------------------------------------------------
-- Snap to Adjacent Elements
--
-- Shared by every draggable element via DefaultBars.lua's
-- DefaultBarDrag_OnUpdate, called per-tick before the element is actually
-- moved so it can nudge the proposed position in place.
-------------------------------------------------------------------------

-- Converts a region's frame bounds to real screen pixels, optionally
-- expanded by a per-side visual inset (used for default bars 1-5, whose
-- native border overhangs the frame).
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

-- Shared calibrated-overhang math for a vanilla-style button of the given
-- size: how far its native border TEXTURE actually reads as visible
-- beyond the button's own frame bounds, after BORDER_TEXTURE_FUDGE
-- corrects for the texture's own transparent padding (the raw
-- BORDER_RATIO ratio alone overstates it - see BORDER_TEXTURE_FUDGE's own
-- comment). Used by both GetElementVisualInset below (per-frame, gates on
-- frame.config.id) and BTV:GetLayoutGridSpacing (Edit Layout mode's
-- reference grid, which has no single frame to measure against).
local function ComputeVanillaBorderInsets(buttonSize, borderRatio, yOffset, fudge)
	local uniform = buttonSize * (borderRatio - 1) / 2

	local left = uniform - fudge
	local right = uniform - fudge
	local top = uniform - yOffset - fudge
	local bottom = uniform + yOffset - fudge

	if left < 0 then left = 0 end
	if right < 0 then right = 0 end
	if top < 0 then top = 0 end
	if bottom < 0 then bottom = 0 end

	return left, right, top, bottom
end

-- Returns how far (local units, pre-scale) a frame's visible border
-- overhangs its own frame bounds on each side, non-zero only for default
-- bars 1-5 in vanilla border style. Custom bars and every chain-anchored
-- element return 0.
function BTV:GetElementVisualInset(frame)
	if frame and frame.config and frame.config.id and self:IsVanillaBorderStyle() then
		local buttonSize = frame.config.buttonSize or self.BUTTON_SIZE

		return ComputeVanillaBorderInsets(
			buttonSize,
			self.BORDER_RATIO,
			self.BORDER_Y_OFFSET or 0,
			self.BORDER_TEXTURE_FUDGE or 0
		)
	end

	return 0, 0, 0, 0
end

-- Every currently visible/enabled draggable element except `excludeElement`,
-- as real-screen-pixel bounding boxes.
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

	if self.bars then
		local barId

		for barId, bar in pairs(self.bars) do
			AddBox(bar)
		end
	end

	AddBox(self.bagBarContainer)
	AddBox(self.microMenuContainer)
	AddBox(self.stanceBarContainer)
	AddBox(self.pageIndicatorContainer)

	AddBox(getglobal(self.KEYRING_BUTTON_NAME))
	AddBox(getglobal(self.LATENCY_BAR_FRAME_NAME))
	AddBox(getglobal(self.EXP_BAR_FRAME_NAME))

	return boxes
end

-- Computes a snap-adjusted (proposedLeft, proposedTop) for a dragged
-- element's top-left corner, checking screen edges/corners (same-side
-- only) and every other visible element's edges (either side, to allow
-- edge-to-edge stacking). Each axis returns nil if it shouldn't snap.
function BTV:ComputeSnapAdjustment(proposedLeft, proposedTop, width, height, excludeElement)
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

-- Rounds `value` to the nearest multiple of `step`, half away from zero.
local function RoundToNearestMultiple(value, step)
	if not step or step == 0 then
		return value
	end

	local n = value / step

	if n >= 0 then
		n = math.floor(n + 0.5)
	else
		n = -math.floor(-n + 0.5)
	end

	return n * step
end

-- Picks whichever candidate anchor position (a list of real-screen-pixel
-- values, all meaning "proposed's own axis value if this candidate wins")
-- keeps `proposed` closest to where the cursor actually is.
local function BestSnapCandidate(proposed, candidates)
	local best, bestDist
	local i

	for i = 1, table.getn(candidates) do
		local dist = candidates[i] - proposed

		if dist < 0 then
			dist = -dist
		end

		if not bestDist or dist < bestDist then
			best = candidates[i]
			bestDist = dist
		end
	end

	return best
end

-- Computes a grid-snapped (proposedLeft, proposedTop) for a dragged
-- element's top-left corner. Unlike ComputeSnapAdjustment (edge-to-edge,
-- threshold-gated against OTHER elements), this snaps every tick against
-- the layout grid itself (BTV:GetLayoutGridSpacing(), same screen-center
-- origin the grid overlay is drawn from - Bar.lua's RebuildLayoutGrid),
-- and considers three ways an axis can land on a grid line: the near
-- edge, the far edge, or the center - whichever keeps the element closest
-- to the cursor wins, so an edge locks onto a line to align a bar's
-- border with the grid just as readily as the center locking onto a line
-- intersection. The screen's own edges are included as explicit
-- candidates too, since they aren't guaranteed to fall on a regular
-- spacing multiple from screen center.
--
-- `scale` is the dragged frame's own GetEffectiveScale() (same value
-- DefaultBars.lua's ApplyDragSnap already computed to convert its local
-- width/height into the real screen pixels proposedLeft/proposedTop/
-- width/height are given in here) - BTV:GetLayoutGridSpacing() is a LOCAL
-- unit (a raw button-size number, same units as button:SetWidth()), so it
-- needs the same conversion before comparing against real-pixel screen
-- coordinates.
function BTV:ComputeGridSnapAdjustment(proposedLeft, proposedTop, width, height, scale)
	if IsShiftKeyDown and IsShiftKeyDown() then
		return nil, nil
	end

	if not BTVanillaDB or not BTVanillaDB.snapToGrid then
		return nil, nil
	end

	if not proposedLeft or not proposedTop or not width or not height then
		return nil, nil
	end

	local spacing = self:GetLayoutGridSpacing()

	if not spacing or spacing <= 0 then
		return nil, nil
	end

	spacing = spacing * (scale or 1)

	local screenLeft, screenRight, screenTop, screenBottom = GetRealScreenBounds(UIParent)

	if not screenLeft then
		return nil, nil
	end

	local centerX = (screenLeft + screenRight) / 2
	local centerY = (screenTop + screenBottom) / 2

	local function NearestOnAxis(point, origin)
		return origin + RoundToNearestMultiple(point - origin, spacing)
	end

	local adjustedLeft = BestSnapCandidate(proposedLeft, {
		NearestOnAxis(proposedLeft, centerX),
		NearestOnAxis(proposedLeft + width, centerX) - width,
		NearestOnAxis(proposedLeft + (width / 2), centerX) - (width / 2),
		screenLeft,
		screenRight - width,
	})

	local adjustedTop = BestSnapCandidate(proposedTop, {
		NearestOnAxis(proposedTop, centerY),
		NearestOnAxis(proposedTop - height, centerY) + height,
		NearestOnAxis(proposedTop - (height / 2), centerY) + (height / 2),
		screenTop,
		screenBottom + height,
	})

	return adjustedLeft, adjustedTop
end

-- Per-axis real-pixel capture radius for ComputeCenterGridSnapAdjustment.
local CENTER_GRID_SNAP_CAPTURE_PX_X = 10
local CENTER_GRID_SNAP_CAPTURE_PX_Y = 2

-- Snaps a point to its nearest grid line if within capturePx, else nil.
local function SnapPointWithinCapture(point, origin, spacing, capturePx)
	local offset = point - origin
	local nearestOffset = RoundToNearestMultiple(offset, spacing)
	local distance = offset - nearestOffset

	if distance < 0 then
		distance = -distance
	end

	if distance <= capturePx then
		return origin + nearestOffset
	end

	return nil
end

-- Appends `value` to `list` at index n+1 if non-nil, returns the new n.
local function AppendCandidate(list, n, value)
	if value then
		list[n + 1] = value
		return n + 1
	end

	return n
end

-- Snaps proposedLeft/proposedTop's near edge, far edge, or center - each
-- only within its own capture radius - to the nearest grid line per axis.
function BTV:ComputeCenterGridSnapAdjustment(proposedLeft, proposedTop, width, height, scale)
	if IsShiftKeyDown and IsShiftKeyDown() then
		return nil, nil
	end

	if not BTVanillaDB or not BTVanillaDB.snapToGrid then
		return nil, nil
	end

	if not proposedLeft or not proposedTop or not width or not height then
		return nil, nil
	end

	local spacing = self:GetLayoutGridSpacing()

	if not spacing or spacing <= 0 then
		return nil, nil
	end

	spacing = spacing * (scale or 1)

	local screenLeft, screenRight, screenTop, screenBottom = GetRealScreenBounds(UIParent)

	if not screenLeft then
		return nil, nil
	end

	local centerX = (screenLeft + screenRight) / 2
	local centerY = (screenTop + screenBottom) / 2

	local nearX = SnapPointWithinCapture(proposedLeft, centerX, spacing, CENTER_GRID_SNAP_CAPTURE_PX_X)
	local farX = SnapPointWithinCapture(proposedLeft + width, centerX, spacing, CENTER_GRID_SNAP_CAPTURE_PX_X)
	local midX = SnapPointWithinCapture(proposedLeft + (width / 2), centerX, spacing, CENTER_GRID_SNAP_CAPTURE_PX_X)

	local xCandidates = {}
	local xn = 0
	xn = AppendCandidate(xCandidates, xn, nearX)
	xn = AppendCandidate(xCandidates, xn, farX and (farX - width))
	xn = AppendCandidate(xCandidates, xn, midX and (midX - (width / 2)))

	local adjustedLeft

	if xn > 0 then
		adjustedLeft = BestSnapCandidate(proposedLeft, xCandidates)
	end

	local nearY = SnapPointWithinCapture(proposedTop, centerY, spacing, CENTER_GRID_SNAP_CAPTURE_PX_Y)
	local farY = SnapPointWithinCapture(proposedTop - height, centerY, spacing, CENTER_GRID_SNAP_CAPTURE_PX_Y)
	local midY = SnapPointWithinCapture(proposedTop - (height / 2), centerY, spacing, CENTER_GRID_SNAP_CAPTURE_PX_Y)

	local yCandidates = {}
	local yn = 0
	yn = AppendCandidate(yCandidates, yn, nearY)
	yn = AppendCandidate(yCandidates, yn, farY and (farY + height))
	yn = AppendCandidate(yCandidates, yn, midY and (midY + (height / 2)))

	local adjustedTop

	if yn > 0 then
		adjustedTop = BestSnapCandidate(proposedTop, yCandidates)
	end

	return adjustedLeft, adjustedTop
end

-------------------------------------------------------------------------
-- Global border/spacing style
-------------------------------------------------------------------------

-- Single source of truth for the global border/spacing style - Button.lua
-- and GetElementVisualInset above must both read this.
function BTV:IsVanillaBorderStyle()
	if BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
		return true
	end

	return not (BTVanillaDB and BTVanillaDB.modernBorderStyle)
end

-- Single source of truth for whether the Pet Bar is effectively in native
-- (real PetActionButton1-10) mode - forces native+uncondensed while
-- default layout is on, regardless of the user's stored preference.
function BTV:IsPetBarNativeModeEffective()
	if BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
		return true
	end

	local cfg = BTVanillaDB and BTVanillaDB.defaultBars and BTVanillaDB.defaultBars[self.PET_BAR_ID]

	return cfg and cfg.useNativePetBar == true
end

-- Single source of truth for whether the Stance Bar is effectively in
-- native (real ShapeshiftButton1-N) mode - forces native while default
-- layout is on, regardless of the user's stored preference. Mirrors
-- BTV:IsPetBarNativeModeEffective exactly.
function BTV:IsStanceBarNativeModeEffective()
	if BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
		return true
	end

	local cfg = BTVanillaDB and BTVanillaDB.defaultBars and BTVanillaDB.defaultBars[self.STANCE_BAR_ID]

	return cfg and cfg.useNativeStanceBar == true
end

-- Re-syncs the Stance Bar (styled mode) cfg's buttonCount/cols/rows against
-- the LIVE GetNumShapeshiftForms() count - called at login and on every
-- UPDATE_SHAPESHIFT_FORMS (DefaultBars.lua's stanceFormEventFrame). A no-op
-- (returns false) only when both buttonCount matches AND cols*rows still
-- exactly accounts for it - checking cols*rows too (not just buttonCount)
-- matters: a cfg can have a matching buttonCount but a stale cols/rows from
-- an earlier mismatch, which a buttonCount-only check would never self-heal.
-- A legitimate custom shape (e.g. 2x2 for 4 forms) is left alone. Returns
-- true when it changed something, so the caller knows to re-layout/refresh.
function BTV:ApplyStanceBarLiveShape()
	self:EnsureDB()

	local cfg = BTVanillaDB.defaultBars[self.STANCE_BAR_ID]

	if not cfg then
		return false
	end

	local liveCount = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0

	if liveCount > self.MAX_STANCE_BUTTONS then
		liveCount = self.MAX_STANCE_BUTTONS
	end

	local shapeValid = cfg.cols and cfg.rows and (cfg.cols * cfg.rows) == liveCount

	if cfg.buttonCount == liveCount and shapeValid then
		return false
	end

	cfg.buttonCount = liveCount
	-- Resets to a sensible default Nx1 shape - the old cols/rows may no
	-- longer be a valid factor pair of the new count at all.
	cfg.cols = liveCount > 0 and liveCount or 1
	cfg.rows = 1

	return true
end

-- Single source of truth for whether the Pet Bar should hide empty slots -
-- real vanilla never does, so this is forced false while default layout is
-- on regardless of the user's stored preference.
function BTV:ShouldCondensePetBarSlots()
	if BTVanillaDB and BTVanillaDB.useDefaultLayout ~= false then
		return false
	end

	local cfg = BTVanillaDB and BTVanillaDB.defaultBars and BTVanillaDB.defaultBars[self.PET_BAR_ID]

	return cfg and cfg.condenseEmptyPetSlots == true
end

-- buttonSize a brand-new bar should seed at, already correct for the
-- currently active style.
function BTV:GetCurrentButtonSizeBaseline()
	if self:IsVanillaBorderStyle() then
		return self.BUTTON_SIZE
	end

	return self.BUTTON_SIZE + self.MODERN_BUTTON_SIZE_DELTA
end

-- Layout-grid line spacing (Edit Layout mode).
--
-- BTVanillaDB.useCustomGridSize (default false, EnsureDB) overrides
-- everything below with a flat user-chosen number (BTVanillaDB.
-- customGridSize, the Edit Mode tab's "Use custom Grid Size" slider) when
-- on.
--
-- Otherwise, tracks the Main Bar's (bar id 1) CURRENT buttonSize live -
-- not a fixed baseline constant - so resizing Main Bar (its own settings
-- page, the General tab's Global Button Size override, or scroll-wheel
-- resize while editing, all of which funnel through BTV:SetBarButtonSize)
-- immediately changes grid spacing too, via that function's own rebuild
-- hook. Falls back to GetCurrentButtonSizeBaseline() only if Main Bar
-- somehow isn't in BTV.bars yet (e.g. very first load).
--
-- Vanilla style ALSO adds Main Bar's real configured cfg.spacing (via the
-- same rebuild hook in BTV:SetBarSpacing/BTV:SetDefaultBarSpacing) - this
-- is the actual button-to-button PITCH real buttons tile at
-- (BarFrameSize/LayoutButtons' own layout formula: buttonSize + spacing),
-- not a border-overhang correction. An earlier version added
-- BTV:GetElementVisualInset's calibrated border-texture overhang instead
-- (reusing the Edit Layout overlay hitbox's own math) - REVERTED: that
-- overhang is a BAR-LEVEL correction (how far the whole bar's outer edge
-- needs to expand to visually contain every button's overhanging border
-- as one unit) and is irrelevant to PER-BUTTON tiling, since adjacent
-- buttons' oversized native borders overlap each other rather than adding
-- real distance between buttons - using it here caused visible cumulative
-- drift between grid lines and buttons across a bar with many buttons
-- (each cell ended up wider than the real per-button pitch). Modern style
-- is deliberately left untouched (buttonSize alone, no spacing added) -
-- already confirmed to align perfectly, do not add spacing there too
-- without separately re-confirming live.
function BTV:GetLayoutGridSpacing()
	if BTVanillaDB and BTVanillaDB.useCustomGridSize and BTVanillaDB.customGridSize then
		return BTVanillaDB.customGridSize
	end

	local mainBar = self.bars and self.bars[1]
	local size = (mainBar and mainBar.config and mainBar.config.buttonSize)
		or self:GetCurrentButtonSizeBaseline()

	if not self:IsVanillaBorderStyle() then
		return size
	end

	local spacing = (mainBar and mainBar.config and mainBar.config.spacing)
		or self.VANILLA_SPACING_FLOOR

	return size + spacing
end

-------------------------------------------------------------------------
-- Edit mode ("Configure Layout")
-------------------------------------------------------------------------

function BTV:IsEditMode()
	return BTVanillaDB and BTVanillaDB.editMode == true
end

-- The Default profile can never be edited.
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

	-- Edit mode always wins over hoverbind mode.
	if enabled and self:IsHoverBindMode() then
		self:SetHoverBindMode(false)
	end

	BTVanillaDB.editMode = enabled
	self:ApplyEditModeVisual()

	if enabled then
		self:ForceHoverFadeFramesVisible()
	else
		self:RestoreHoverFadeFrames()
	end
end

function BTV:ToggleEditMode()
	self:SetEditMode(not self:IsEditMode())
	self:Print(self:IsEditMode()
		and "Configure Layout ON - drag buttons to move bars, scroll to scale, right-click for bar settings. Hold Shift while dragging to temporarily disable snapping. Hold Ctrl to temporarily show/hide the layout grid."
		or "Configure Layout OFF.")
end

-------------------------------------------------------------------------
-- Hoverbind mode
--
-- Mutually exclusive with edit mode.
-------------------------------------------------------------------------

function BTV:IsHoverBindMode()
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

	if self.ApplyHoverBindVisual then
		self:ApplyHoverBindVisual(enabled)
	end

	if enabled then
		self:ForceHoverFadeFramesVisible()
	else
		self:RestoreHoverFadeFrames()
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
-- Only show on hover
--
-- Shared controller for every hover-only-eligible bar/element. Fade ticker
-- mirrors DefaultBars.lua's rested-glow-pulse idiom. Hover detection is a
-- shared cursor-position poll rather than OnEnter/OnLeave, since a bounding-
-- box test doesn't care which child frame wins mouse-enter dispatch.
-------------------------------------------------------------------------

local HOVER_FADE_TICK_INTERVAL = 0.04
local HOVER_POLL_TICK_INTERVAL = 0.06

-- Every frame with an installed hover-fade controller, keyed by itself.
local hoverFadeFrames = {}

-- Clamps to the 0-10s hover-fade duration range, or nil if not a valid number. Shared by every Set*HoverDuration setter.
function BTV:ClampHoverDuration(duration)
	duration = tonumber(duration)

	if not duration then
		return nil
	end

	if duration < 0 then
		duration = 0
	end

	if duration > 10 then
		duration = 10
	end

	return duration
end

-- Mirrors DefaultBars.lua's file-local helper of the same name (not reachable from here).
local function GetCursorPositionUIScale()
	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / scale, y / scale
end

-- Bounds check against an already-known cursor position, shared across all registered frames per tick.
local function IsPointOverFrame(x, y, frame)
	local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()

	if not left or not right or not top or not bottom then
		return false
	end

	return x >= left and x <= right and y >= bottom and y <= top
end

-- One-off single-frame check, used only for ApplyHoverOnlyState's initial state.
local function IsCursorOverFrame(frame)
	local x, y = GetCursorPositionUIScale()

	return IsPointOverFrame(x, y, frame)
end

local hoverPollTicker = nil

-- Single shared ticker for every registered hover-only frame, started lazily on first registration.
local function StartHoverPollTicker()
	if hoverPollTicker or not C_Timer or not C_Timer.NewTicker then
		return
	end

	hoverPollTicker = C_Timer.NewTicker(HOVER_POLL_TICK_INTERVAL, function()
		if BTV:IsEditMode() or BTV:IsHoverBindMode() then
			return
		end

		local x, y = GetCursorPositionUIScale()
		local frame

		for frame in pairs(hoverFadeFrames) do
			if frame.btvHoverOnlyEnabled then
				local hovering = IsPointOverFrame(x, y, frame)

				if hovering and not frame.btvHoverOnlyHovering then
					BTV:CancelHoverFadeTicker(frame)
					frame:SetAlpha(1)
				elseif not hovering and frame.btvHoverOnlyHovering then
					BTV:StartHoverFadeTicker(frame, frame.btvHoverOnlyGetDuration and frame.btvHoverOnlyGetDuration() or 3)
				end

				frame.btvHoverOnlyHovering = hovering
			end
		end
	end)
end

-- Cancel()-and-nil, same convention as Button.lua's rangeTicker.
function BTV:CancelHoverFadeTicker(frame)
	if frame.btvHoverFadeTicker then
		frame.btvHoverFadeTicker:Cancel()
		frame.btvHoverFadeTicker = nil
	end
end

-- Full alpha for the first 4/5 of duration, then a linear fade to 0 over the last 1/5. duration <= 0 hides immediately.
-- Edit Layout/Hoverbind mode force alpha 1 while active, rechecked every tick.
function BTV:StartHoverFadeTicker(frame, duration)
	self:CancelHoverFadeTicker(frame)

	duration = tonumber(duration) or 0

	if duration <= 0 or not C_Timer or not C_Timer.NewTicker then
		frame:SetAlpha(0)
		return
	end

	local holdEnd = duration * 0.8
	local startTime = GetTime()

	frame:SetAlpha(1)

	frame.btvHoverFadeTicker = C_Timer.NewTicker(HOVER_FADE_TICK_INTERVAL, function()
		if BTV:IsEditMode() or BTV:IsHoverBindMode() then
			frame:SetAlpha(1)
			return
		end

		local elapsed = GetTime() - startTime

		if elapsed >= duration then
			frame:SetAlpha(0)
			BTV:CancelHoverFadeTicker(frame)
			return
		end

		if elapsed <= holdEnd then
			frame:SetAlpha(1)
		else
			frame:SetAlpha(1 - ((elapsed - holdEnd) / (duration - holdEnd)))
		end
	end)
end

-- Registers `frame` (once, idempotent) into the shared poll registry, starting the poll ticker on first registration.
function BTV:InstallHoverFadeController(frame)
	if frame.btvHoverFadeInstalled then
		return
	end

	frame.btvHoverFadeInstalled = true
	hoverFadeFrames[frame] = frame

	StartHoverPollTicker()
end

-- Central per-frame apply/toggle for every settings-change path that owns a hover-only-eligible frame.
function BTV:ApplyHoverOnlyState(frame, enabled, getDuration)
	if not frame then
		return
	end

	enabled = enabled and true or false

	-- Stored on the frame so the poll ticker always reads the latest value.
	frame.btvHoverOnlyEnabled = enabled
	frame.btvHoverOnlyGetDuration = getDuration

	if not enabled then
		self:CancelHoverFadeTicker(frame)
		frame:SetAlpha(1)
		return
	end

	frame:EnableMouse(true)

	self:InstallHoverFadeController(frame)

	-- Immediate bounds check so toggling on while the cursor is already over the frame doesn't snap it to hidden.
	frame.btvHoverOnlyHovering = IsCursorOverFrame(frame)

	if not frame.btvHoverFadeTicker then
		if self:IsEditMode() or self:IsHoverBindMode() or frame.btvHoverOnlyHovering then
			frame:SetAlpha(1)
		else
			frame:SetAlpha(0)
		end
	end
end

-- Forces every installed hover-fade frame to alpha 1, so hover-only elements stay visible while editing/binding.
function BTV:ForceHoverFadeFramesVisible()
	local frame

	for frame in pairs(hoverFadeFrames) do
		frame:SetAlpha(1)
	end
end

-- Snaps every installed hover-fade frame back to its normal hidden-until-hover state, undoing ForceHoverFadeFramesVisible.
function BTV:RestoreHoverFadeFrames()
	if self:IsEditMode() or self:IsHoverBindMode() then
		return
	end

	local frame

	for frame in pairs(hoverFadeFrames) do
		if frame.btvHoverOnlyEnabled and not frame.btvHoverFadeTicker and not frame.btvHoverOnlyHovering then
			frame:SetAlpha(0)
		end
	end
end

-------------------------------------------------------------------------
-- Lock Action Bars
--
-- Not a CVar - backed by the plain global LOCK_ACTIONBAR ("0"/"1"),
-- same global Blizzard's own Interface Options checkbox uses.
-------------------------------------------------------------------------

function BTV:IsLockActionBars()
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

-- Polls ActionButton1's real position until two consecutive reads agree
-- (or a timeout is hit), since its true native position is not guaranteed
-- final the instant PLAYER_ENTERING_WORLD fires.
local SETTLE_POLL_INTERVAL = 0.1
local SETTLE_STABLE_READS_REQUIRED = 2
local SETTLE_TIMEOUT = 3

local function WaitForNativeBarSettle(callback)
	local ref = getglobal("ActionButton1")

	if not ref or not C_Timer or not C_Timer.NewTicker then
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

-- Full login sequence, run once WaitForNativeBarSettle confirms the
-- native bars have settled.
local function RunLoginSequence(earlyLeft, earlyTop, settledLeft, settledTop, waited)
	if earlyLeft and settledLeft then
		BTV:Print(string.format(
			"Anchor capture: left early=%.2f settled=%.2f, top early=%.2f settled=%.2f (waited %.2fs)",
			earlyLeft, settledLeft, earlyTop or 0, settledTop or 0, waited or 0
		))
	end

	BTV:ResolveActiveProfile()

	BTV:EnsureDB()

	-- Must run before CreateFixedSlotDefaultBars builds the Stance Bar's
	-- styled-mode button pool, so cfg.buttonCount already reflects the
	-- live form count this session (covers a class that learned/lost a
	-- form between two logins).
	BTV:ApplyStanceBarLiveShape()

	BTV:CreateAllBars()

	-- Must run before CreateFixedSlotDefaultBars, which hides bar 2's
	-- real buttons and would otherwise cause this to capture
	-- ShapeshiftBarFrame in an already-reflowed state.
	BTV:CaptureStanceBarNativeGap()

	BTV:CreateFixedSlotDefaultBars()

	BTV:ApplyAllDefaultBars()

	BTV:ApplyGlobalButtonStyle()

	BTV:ApplyGlobalSpacing()
	BTV:ApplyGlobalButtonSize()

	BTV:HookAllDefaultBarButtons()

	BTV:CreateStanceBarContainer()

	if BTVanillaDB.useDefaultLayout ~= false then
		local bar2Cfg = BTVanillaDB.defaultBars[2]
		BTV:ReflowStanceBarForBar2Toggle(bar2Cfg and bar2Cfg.enabled)
	end

	BTV:CreateBagBarAndMicroMenu()
	BTV:CreatePetBarNativeContainer()

	BTV:CreatePageIndicatorContainer()

	BTV:SetKeyRingEnabled(BTVanillaDB.keyRingEnabled ~= false)

	BTV:SetKeyRingScale(BTVanillaDB.keyRingScale or 1)
	BTV:ApplyKeyRingPosition()

	BTV:SetLatencyBarEnabled(BTVanillaDB.latencyBarEnabled ~= false)
	BTV:SetLatencyBarScale(BTVanillaDB.latencyBarScale or 1)
	BTV:ApplyLatencyBarPosition()

	BTV:SetExpBarEnabled(BTVanillaDB.expBarEnabled ~= false)
	BTV:SetExpBarScale(BTVanillaDB.expBarScale or 1)
	BTV:ApplyExpBarPosition()

	BTV:SetCastBarScale(BTVanillaDB.castBarScale or 1)
	BTV:ApplyCastBarPosition()

	BTV:ApplyExpBarColors()

	BTV:ApplyBetterExpBarVisual()

	BTV:ApplyBlizzardArtVisibility()

	BTV:CreateMinimapButton()

	BTV:Print("Loaded. Click the minimap button for options.")

	if BTV.pendingFirstLoginDialog then
		BTV.pendingFirstLoginDialog = nil
		BTV:ShowFirstLoginDialog()
	end
end

-- PLAYER_ENTERING_WORLD (not PLAYER_LOGIN) so the native MainMenuBar
-- cluster's own layout pass has more room to finish before the settle
-- poll starts measuring. Unregistered after the first fire.
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loadFrame:RegisterEvent("PLAYER_LOGOUT")

loadFrame:SetScript("OnEvent", function()
	if event == "PLAYER_LOGOUT" then
		BTV:SaveActiveProfileData()
		return
	end

	loadFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
	WaitForNativeBarSettle(RunLoginSequence)
end)

-- /btv recapture - forces a fresh, synchronous capture of every default
-- bar's native anchor (see RecaptureDefaultBarNativeAnchors above).
-- /btv with no argument toggles the main menu.
SLASH_BTVANILLA1 = "/btv"
SlashCmdList["BTVANILLA"] = function(msg)
	if msg == "recapture" then
		BTV:RecaptureDefaultBarNativeAnchors()
	else
		BTV:ToggleMainMenu()
	end
end
