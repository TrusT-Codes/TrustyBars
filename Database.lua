-- Database.lua
-- SavedVariable lifecycle: schema/seeding constants, native-anchor/
-- spacing/action-slot capture, default- and extra-bar seeding,
-- ACAB:EnsureDB (migration-safe defaults), and the full profile system
-- (create/delete/copy/export/import). Loads right after Core.lua.

local ACAB = AlternativeClassicActionBars

-- Schema version for ACABDB.defaultBars/bars. Bumping this reseeds
-- default bars and wipes ACABDB.bars - see EnsureDB below.
ACAB.SCHEMA_VERSION = 8

-- One-shot per session (login/reload), not per EnsureDB call - see
-- EnsureDB's hoverBindMode reset.
local hasResetHoverBindModeThisSession = false

-- Captures a default bar's on-screen position from its first real
-- Blizzard button frame, converted to real screen pixels and expressed as
-- a UIParent-relative TOPLEFT/BOTTOMLEFT anchor. A method (not a local
-- function) so Core.lua's post-login drift check can call it too.
function ACAB:CaptureNativeAnchor(id)
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

-- Fallback anchor only used if CaptureNativeAnchor can't read a real
-- Blizzard frame at all.
local FALLBACK_ANCHOR = {
	[1] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 0 },
	[2] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 42 },
	[3] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 84 },
	[4] = { point = "RIGHT", relativePoint = "RIGHT", x = -18, y = 0 },
	[5] = { point = "RIGHT", relativePoint = "RIGHT", x = -58, y = 0 },
	[ACAB.PET_BAR_ID] = { point = "BOTTOM", relativePoint = "BOTTOM", x = -200, y = 130 },
	-- Only used if CaptureNativeAnchor can't read a real ShapeshiftButton1
	-- this session (e.g. a class with zero learned forms at first login).
	[ACAB.STANCE_BAR_ID] = { point = "BOTTOM", relativePoint = "BOTTOM", x = 0, y = 90 },
}

-- Builds one default-bar-family id's fresh saved config, capturing its
-- real native anchor/spacing/action-slots. Shared by seedDefaultBars and
-- EnsureDB's migration path (a single missing id).
local function SeedOneDefaultBar(self, id)
	local grid = self.DEFAULT_BAR_GRID[id]
	local anchor = self:CaptureNativeAnchor(id) or FALLBACK_ANCHOR[id]

	local spacing = CaptureNativeSpacing(self, id, grid)

	spacing = spacing or 0

	-- NOT read from ACAB.SHOW_MULTI_ACTIONBAR_GLOBAL - that global does
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

			if usedFallback then
				self:Print(
					"WARNING: Default bar " .. tostring(id) ..
					" fixed action slots used FALLBACK offsets - " ..
					"button.action was missing, please verify live."
				)
			end
		else
			self:Print(
				"WARNING: Default bar " .. tostring(id) ..
				" could not discover its real action slots this session " ..
				"- it will keep using the old native-Blizzard-frame layout " ..
				"until this succeeds on a later login."
			)
		end
	end

	-- Pet Bar: pet slots 1-10 are an identity map (pool index N drives pet
	-- slot N), not real action slots discovered via CaptureFixedActionSlots.
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

	-- Stance Bar (styled mode): pool index N drives shapeshift form index N
	-- directly (no "empty slot" concept). Pool is a fixed MAX_STANCE_BUTTONS
	-- (10) slots; cfg.buttonCount tracks the live GetNumShapeshiftForms()
	-- count instead, recomputed on UPDATE_SHAPESHIFT_FORMS.
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

-- Builds a fresh ACABDB.defaultBars table for every default-bar-family
-- id (ACAB.DEFAULT_BAR_IDS).
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
-- synchronously so the caller can confirm the result immediately. Reapplies
-- live if bars already exist this session.
function ACAB:RecaptureDefaultBarNativeAnchors()
	self:EnsureDB()

	self:Print("Recapturing positions to align Bars with your Screen.")

	local fresh = seedDefaultBars(self)
	local i

	-- Updates each existing cfg table in place instead of replacing
	-- ACABDB.defaultBars wholesale, since self.bars[id].config is the
	-- same table reference captured at login. Only anchor/spacing/
	-- action-slot fields are copied; every other user setting is untouched.
	for i = 1, table.getn(self.DEFAULT_BAR_IDS) do
		local id = self.DEFAULT_BAR_IDS[i]
		local oldCfg = ACABDB.defaultBars[id]
		local newCfg = fresh[id]

		-- Pet Bar/Stance Bar in native mode reparent their real Blizzard
		-- buttons into our own container, so GetLeft()/GetTop() on those
		-- buttons reports our own applied position, not Blizzard's native
		-- one - skip recapturing once their container already exists.
		local selfReferencing =
			(id == self.PET_BAR_ID and self.petBarNativeContainer) or
			(id == self.STANCE_BAR_ID and self.stanceBarContainer)

		if selfReferencing then
			-- Leave oldCfg's anchor/spacing untouched.
		elseif oldCfg and newCfg then
			oldCfg.point = newCfg.point
			oldCfg.relativePoint = newCfg.relativePoint
			oldCfg.x = newCfg.x
			oldCfg.y = newCfg.y
			oldCfg.spacing = newCfg.spacing
			oldCfg.nativeAnchor = newCfg.nativeAnchor
			oldCfg.nativeSpacing = newCfg.nativeSpacing

			if newCfg.fixedActionSlots then
				oldCfg.fixedActionSlots = newCfg.fixedActionSlots
			end
		elseif newCfg then
			-- No existing cfg for this id (e.g. a save from before the Pet
			-- Bar existed) - the fresh table becomes the real one.
			ACABDB.defaultBars[id] = newCfg
		end
	end

	if self.bars and self.bars[1] then
		self:ApplyAllDefaultBars()
	end

	-- Re-derives Pet Bar's x/y from Bar 3/Bar 1's just-refreshed nativeAnchor.
	if self.SyncPetBarAnchorX then
		self:SyncPetBarAnchorX()
	end

	if self.petBarNativeContainer and ACABDB.useDefaultLayout ~= false then
		local bar3Cfg = ACABDB.defaultBars[3]
		self:ReflowPetBarForBar3Toggle(bar3Cfg and bar3Cfg.enabled)
	end

	-- Extra Bar 1-4's default layout is defined relative to a default bar's
	-- nativeAnchor (GetDefaultExtraBarLayout) - re-derive each one now that
	-- the reference bars above just got their real nativeAnchor, the same
	-- way each Extra Bar's own "Reset to Default" button already does.
	if self.ResetExtraBarLayout then
		for i = self.EXTRA_BAR_ID_START, self.EXTRA_BAR_ID_START + self.EXTRA_BAR_COUNT - 1 do
			self:ResetExtraBarLayout(i)
		end
	end

	self:Print("All Bars and UI-Elements applied to their correct position after recapture.")
end

-- Clears the stored native anchor + position for every single-real-frame
-- wrapped element (Key Ring/Latency Bar/Exp Bar/Cast Bar). Unlike bars 1-5,
-- these elements ARE the one real Blizzard frame this addon repositions
-- directly, so nothing here can re-measure Blizzard's native position live -
-- only clearing the stored capture and letting a fresh read happen on the
-- next reload (before this session's Apply*Position touches the frame) gets
-- the real position.
function ACAB:RecaptureWrappedNativeFrameAnchors()
	self:EnsureDB()

	ACABDB.keyRingPosition = nil
	ACABDB.keyRingNativeAnchor = nil
	ACABDB.latencyBarPosition = nil
	ACABDB.latencyBarNativeAnchor = nil
	ACABDB.expBarPosition = nil
	ACABDB.expBarNativeAnchor = nil
	ACABDB.castBarPosition = nil
	ACABDB.castBarNativeAnchor = nil

	-- Stack-reflow floor (GetCastBarBaselineY, NativeElements.lua) - must
	-- clear alongside castBarPosition above or it keeps stacking off the
	-- stale pre-recapture floor forever instead of re-deriving from the
	-- freshly captured position.
	ACABDB.castBarStackBaseY = nil

	self:Print("Key Ring/Latency Bar/Exp Bar/Cast Bar native anchors cleared - /reload now to capture them fresh.")
end

-- Fallback only - used if the referenced default bar's native anchor
-- (below) isn't captured yet. TOPLEFT/BOTTOMLEFT-to-UIParent, same
-- convention as every other Action Bar - stacked vertically by index so
-- the 4 don't overlap.
local function GetFallbackExtraBarPosition(self, index)
	return 20, 150 + (index * ((self.BUTTON_ROWS * self.BUTTON_SIZE) + 40))
end

-- Extra Bar N's default position/shape sits one (or two, for Extra Bar 4)
-- button-size-plus-spacing pitch to the given side of a specific default
-- bar's OWN default (native) position - matching that bar's default grid
-- shape/spacing/button size so it reads as a direct visual extension of
-- it. Index is 0-3 for Extra Bar 1-4.
local EXTRA_BAR_DEFAULT_REFERENCE = {
	[0] = { refId = 2, side = "above", pitchCount = 1 }, -- Extra Bar 1: above Action Bar 1.
	[1] = { refId = 3, side = "above", pitchCount = 1 }, -- Extra Bar 2: above Action Bar 2.
	[2] = { refId = 5, side = "left",  pitchCount = 1 }, -- Extra Bar 3: left of Right Action Bar 2.
	[3] = { refId = 5, side = "left",  pitchCount = 2 }, -- Extra Bar 4: left of Right Action Bar 2 (double pitch, i.e. left of Extra Bar 3).
}

-- Shared between seedExtraBarConfig below and ACAB:ResetExtraBarLayout
-- (Bar.lua), so a freshly-created bar and a "Reset to Default" click land
-- in the same place. Returns x, y, cols, rows, buttonSize, spacing.
function ACAB:GetDefaultExtraBarLayout(index)
	local ref = EXTRA_BAR_DEFAULT_REFERENCE[index]
	local refCfg = ref and ACABDB.defaultBars and ACABDB.defaultBars[ref.refId]
	local grid = ref and self.DEFAULT_BAR_GRID[ref.refId]

	if not ref or not refCfg or not refCfg.nativeAnchor or not grid then
		local x, y = GetFallbackExtraBarPosition(self, index)
		return x, y, self.BUTTON_COLS, self.BUTTON_ROWS, self:GetCurrentButtonSizeBaseline(), 0
	end

	local buttonSize = self.BUTTON_SIZE
	local spacing = refCfg.nativeSpacing or refCfg.spacing or 0
	local pitch = (buttonSize + spacing) * ref.pitchCount

	local x = refCfg.nativeAnchor.x
	local y = refCfg.nativeAnchor.y

	if ref.side == "above" then
		y = y + pitch
	elseif ref.side == "left" then
		x = x - pitch
	end

	return x, y, grid.cols, grid.rows, buttonSize, spacing
end

-- Extra bar's live vertical footprint (real frame height, not the seeded
-- default) plus the same gap-to-reference-bar spacing GetDefaultExtraBarLayout
-- above used to seed its position - 0 if the extra bar doesn't exist, isn't
-- enabled, or is no longer at its own default position (bar.config.
-- usesDefaultPosition == false - the user dragged/slider-moved it away from
-- its seeded slot above Action Bar 1/2, so it no longer reads as stacked
-- there regardless of enabled state). Used by Stance/Pet/Cast Bar baseline
-- reflow to stack above an enabled Extra Bar the same way they already
-- stack above Action Bar 1/2.
function ACAB:GetExtraBarStackPitch(extraBarId)
	local bar = self.bars and self.bars[extraBarId]

	if not bar or not bar.config or not bar.config.enabled
		or bar.config.usesDefaultPosition == false then
		return 0
	end

	local index = extraBarId - self.EXTRA_BAR_ID_START
	local ref = EXTRA_BAR_DEFAULT_REFERENCE[index]
	local refCfg = ref and ACABDB.defaultBars and ACABDB.defaultBars[ref.refId]
	local gap = (refCfg and (refCfg.nativeSpacing or refCfg.spacing)) or 0

	return (bar:GetHeight() or 0) + gap
end

-- Nudges Stance/Pet/Cast Bar to resettle the moment Extra Bar 1/2's own
-- stacking contribution changes - enable/disable while still at default
-- position, or the usesDefaultPosition flag itself just flipped (Bar.lua's
-- SetBarPosition/StopBarDrag/ResetExtraBarLayout). Each Reflow* call below
-- already no-ops on its own guard (useDefaultLayout, and the DEPENDANT
-- element's own usesDefaultPosition flag), so this is always safe to call.
function ACAB:ReflowExtraBarDependants(extraBarId)
	local index = extraBarId - self.EXTRA_BAR_ID_START

	if index == 0 then
		local bar2Cfg = ACABDB.defaultBars[2]
		self:ReflowStanceBarForBar2Toggle(bar2Cfg and bar2Cfg.enabled)
	elseif index == 1 then
		local bar3Cfg = ACABDB.defaultBars[3]
		self:ReflowPetBarForBar3Toggle(bar3Cfg and bar3Cfg.enabled)
	end

	if self.ReflowCastBarForStackToggle then
		self:ReflowCastBarForStackToggle()
	end
end

-- Allocates one Extra Bar's config.
local function seedExtraBarConfig(self, id)
	local index = id - self.EXTRA_BAR_ID_START
	local x, y, cols, rows, buttonSize, spacing = self:GetDefaultExtraBarLayout(index)

	local needed = cols * rows
	local slotStart = self:GetNextFreeSlotStart(needed)

	if not slotStart then
		self:Print(
			"WARNING: Extra Bar " .. tostring(id - self.EXTRA_BAR_ID_START + 1) ..
			" could not be allocated a free action-slot block this session " ..
			"- the 48-slot free pool (73-120) is unexpectedly already full."
		)

		return nil
	end

	return {
		id = id,

		point = "TOPLEFT",
		relativePoint = "BOTTOMLEFT",
		x = x,
		y = y,

		cols = cols,
		rows = rows,

		buttonSize = buttonSize,

		slotStart = slotStart,
		buttonCount = cols * rows,

		spacing = spacing,

		enabled = false,
	}
end

-- One-time migration: converts a legacy CENTER-anchored Extra Bar to the
-- TOPLEFT/BOTTOMLEFT convention every other Action Bar uses, preserving its
-- real on-screen position. No-op once already migrated.
function ACAB:MigrateExtraBarAnchor(cfg)
	if not cfg or cfg.point ~= "CENTER" then
		return
	end

	local screenWidth = GetScreenWidth() or 1024
	local screenHeight = GetScreenHeight() or 768
	local cols = cfg.cols or self.BUTTON_COLS
	local rows = cfg.rows or self.BUTTON_ROWS
	local buttonSize = cfg.buttonSize or self:GetCurrentButtonSizeBaseline()
	local spacing = cfg.spacing or 0

	local barWidth = (cols * buttonSize) + ((cols - 1) * spacing)
	local barHeight = (rows * buttonSize) + ((rows - 1) * spacing)

	local centerX = (screenWidth / 2) + (cfg.x or 0)
	local centerY = (screenHeight / 2) + (cfg.y or 0)

	cfg.point = "TOPLEFT"
	cfg.relativePoint = "BOTTOMLEFT"
	cfg.x = centerX - (barWidth / 2)
	cfg.y = centerY + (barHeight / 2)
end

-- Ensures exactly ACAB.EXTRA_BAR_COUNT Extra Bar configs exist.
function ACAB:EnsureExtraBars()
	local id

	for id = self.EXTRA_BAR_ID_START, self.EXTRA_BAR_ID_START + self.EXTRA_BAR_COUNT - 1 do
		local found = false
		local i

		for i = 1, table.getn(ACABDB.bars) do
			if ACABDB.bars[i] and ACABDB.bars[i].id == id then
				found = true
				self:MigrateExtraBarAnchor(ACABDB.bars[i])
				break
			end
		end

		if not found then
			local cfg = seedExtraBarConfig(self, id)

			if cfg then
				table.insert(ACABDB.bars, cfg)
			end
		end
	end
end

-------------------------------------------------------------------------
-- Profiles
--
-- ACABDB is always the active profile's live data. ACABProfilesDB
-- (account-wide) stores every profile's data keyed by name.
-- ACABCharDB (per-character) stores which profile this character
-- currently uses.
-------------------------------------------------------------------------

ACAB.DEFAULT_PROFILE_NAME = "Default"

-- Plain recursive deep copy - ACABDB only ever holds plain data.
function ACAB:DeepCopyTable(t)
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
function ACAB:GetProfileNames()
	local names = {}
	local n = 0
	local name

	for name in pairs(ACABProfilesDB or {}) do
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
-- profile's data into ACABDB. Must run before EnsureDB.
function ACAB:ResolveActiveProfile()
	if not ACABCharDB then
		ACABCharDB = {
			activeProfile = self.DEFAULT_PROFILE_NAME,
			hasSelectedProfileBefore = false,
		}
	end

	if not ACABProfilesDB then
		ACABProfilesDB = {}
	end

	if not ACABProfilesDB[self.DEFAULT_PROFILE_NAME] and ACABDB then
		ACABProfilesDB[self.DEFAULT_PROFILE_NAME] = self:DeepCopyTable(ACABDB)
	end

	if not ACABCharDB.hasSelectedProfileBefore then
		self.pendingFirstLoginDialog = true
	end

	local activeProfile = ACABCharDB.activeProfile or self.DEFAULT_PROFILE_NAME

	self.activeProfileName = activeProfile

	local snapshot = ACABProfilesDB[activeProfile]

	if snapshot then
		ACABDB = self:DeepCopyTable(snapshot)
	else
		ACABDB = nil
	end
end

-- Writes the live ACABDB back into ACABProfilesDB[activeProfileName].
function ACAB:SaveActiveProfileData()
	if not self.activeProfileName or not ACABDB then
		return
	end

	ACABProfilesDB = ACABProfilesDB or {}
	ACABProfilesDB[self.activeProfileName] = self:DeepCopyTable(ACABDB)
end

-- Creates a new profile seeded from Default's current data.
function ACAB:CreateProfile(name)
	if not name or name == "" then
		return false, "Profile name cannot be empty."
	end

	ACABProfilesDB = ACABProfilesDB or {}

	if ACABProfilesDB[name] then
		return false, "A profile named \"" .. name .. "\" already exists."
	end

	local defaultData = ACABProfilesDB[self.DEFAULT_PROFILE_NAME]

	ACABProfilesDB[name] = defaultData and self:DeepCopyTable(defaultData) or {}

	return true
end

-- Deletes a profile. Default is never deletable; deleting the active
-- profile falls the character back to Default.
function ACAB:DeleteProfile(name)
	if not name or name == self.DEFAULT_PROFILE_NAME then
		return false, "The Default profile cannot be deleted."
	end

	if not ACABProfilesDB or not ACABProfilesDB[name] then
		return false, "Profile \"" .. tostring(name) .. "\" does not exist."
	end

	ACABProfilesDB[name] = nil

	if ACABCharDB and ACABCharDB.activeProfile == name then
		ACABCharDB.activeProfile = self.DEFAULT_PROFILE_NAME

		-- Also update the live in-memory pointer, not just ACABCharDB's -
		-- otherwise a later SaveActiveProfileData saves ACABDB back
		-- under the just-deleted name, resurrecting it.
		self.activeProfileName = self.DEFAULT_PROFILE_NAME
		ACABDB = self:DeepCopyTable(ACABProfilesDB[self.DEFAULT_PROFILE_NAME] or {})
	end

	return true
end

-- Overwrites targetName's saved data with a copy of sourceName's.
function ACAB:CopyProfileInto(sourceName, targetName)
	if not ACABProfilesDB or not ACABProfilesDB[sourceName] then
		return false, "Source profile \"" .. tostring(sourceName) .. "\" does not exist."
	end

	if not targetName or targetName == "" then
		return false, "Invalid target profile."
	end

	ACABProfilesDB[targetName] = self:DeepCopyTable(ACABProfilesDB[sourceName])

	if targetName == self.activeProfileName then
		ACABDB = self:DeepCopyTable(ACABProfilesDB[targetName])
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

ACAB.PROFILE_IMPORT_ERROR_MESSAGE =
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
function ACAB:ExportActiveProfileString()
	local parts = {}

	SerializeValue(ACABDB, parts)

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
function ACAB:ParseProfileImportString(str)
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
function ACAB:ApplyImportedProfileData(data)
	ACABDB = self:DeepCopyTable(data)

	ACABProfilesDB = ACABProfilesDB or {}
	ACABProfilesDB[self.activeProfileName] = self:DeepCopyTable(data)
end

-- Switches this character to an existing profile and reloads the UI.
function ACAB:SwitchProfile(name)
	if not ACABProfilesDB or not ACABProfilesDB[name] then
		return false, "Profile \"" .. tostring(name) .. "\" does not exist."
	end

	self:SaveActiveProfileData()

	ACABCharDB = ACABCharDB or {}
	ACABCharDB.activeProfile = name
	ACABCharDB.hasSelectedProfileBefore = true

	ReloadUI()

	return true
end

-- Shared "enter a new profile name" dialog used by both the Profiles tab
-- and the first-login dialog.
function ACAB:ShowCreateProfileDialog(onCreated)
	self:ShowDialog({
		title = "New Profile",
		message = "Enter the name for the new profile",
		mode = "textinput",
		buttons = {
			{
				text = "Accept",
				isDefault = true,
				onClick = function(value)
					local ok, reason = ACAB:CreateProfile(value)

					if ok then
						ACAB:SwitchProfile(value)
					elseif reason then
						ACAB:Print(reason)
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
function ACAB:ShowFirstLoginDialog()
	local buttons = {
		{
			text = "I know what im doing, use default profile",
			isDefault = true,
			onClick = function()
				ACABCharDB = ACABCharDB or {}
				ACABCharDB.hasSelectedProfileBefore = true
			end,
		},
		{
			text = "Create a named profile",
			onClick = function()
				ACAB:ShowCreateProfileDialog()
			end,
		},
		{
			text = "Create a profile for this character",
			onClick = function()
				local charName = UnitName("player") or "Unknown"
				local realmName = GetRealmName() or "Unknown"
				local charProfileName = charName .. " - " .. realmName

				local ok, reason = ACAB:CreateProfile(charProfileName)

				if ok then
					ACAB:SwitchProfile(charProfileName)
				elseif reason then
					ACAB:Print(reason)
				end
			end,
		},
	}

	if table.getn(self:GetProfileNames()) > 1 then
		table.insert(buttons, {
			text = "use existing profile",
			onClick = function()
				ACAB:ShowDialog({
					title = "Use Existing Profile",
					message = "Choose a profile to use for this character.",
					mode = "dropdown",
					options = ACAB:GetProfileNames(),
					buttons = {
						{
							text = "Accept",
							isDefault = true,
							onClick = function(value)
								if value then
									ACAB:SwitchProfile(value)
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
		title = "Welcome to ACAB",
		message = "Thank you for choosing ACAB, you are currently using the Profile \"Default\". " ..
			"The Default profile is locked and cannot be edited - Edit Layout mode and Settings changes are unavailable while it is active.\n\n" ..
			"Do you wish to create a new custom profile or a profile for this character?",
		mode = "confirm",
		buttons = buttons,
	})
end

function ACAB:EnsureDB()
	if not ACABDB then
		ACABDB = {}
	end
	if ACABDB.editMode == nil then
		ACABDB.editMode = false
	end
	if ACABDB.minimapAngle == nil then
		ACABDB.minimapAngle = 200
	end

	if ACABDB.useDefaultLayout == nil then
		ACABDB.useDefaultLayout = true
	end

	if ACABDB.modernBorderStyle == nil then
		ACABDB.modernBorderStyle = false
	end

	if ACABDB.bypassRightActionBar2Dependency == nil then
		ACABDB.bypassRightActionBar2Dependency = false
	end

	if ACABDB.lastAppliedVanillaStyle == nil then
		ACABDB.lastAppliedVanillaStyle = ACAB:IsVanillaBorderStyle()
	end

	if ACABDB.globalSpacingEnabled == nil then
		ACABDB.globalSpacingEnabled = false
	end

	if ACABDB.globalSpacingValue == nil then
		ACABDB.globalSpacingValue = 0
	end

	if ACABDB.globalButtonSizeEnabled == nil then
		ACABDB.globalButtonSizeEnabled = false
	end

	if ACABDB.globalButtonSizeValue == nil then
		ACABDB.globalButtonSizeValue = ACAB.BUTTON_SIZE
	end

	if ACABDB.mainBarPaginationEnabled == nil then
		ACABDB.mainBarPaginationEnabled = true
	end
	if ACABDB.mainBarStanceSwapEnabled == nil then
		ACABDB.mainBarStanceSwapEnabled = true
	end

	-- mainBarStanceBarAssignment/mainBarPageBarAssignment stay nil
	-- (unassigned) until the user explicitly picks an Extra Bar.

	if ACABDB.mainBarPageIndicatorScale == nil then
		ACABDB.mainBarPageIndicatorScale = 1
	end

	-- stanceBarPosition/stanceBarNativeAnchor are captured lazily on
	-- first real build (DefaultBars.lua), not seeded here.

	-- Self-heal a corrupted stanceBarNativeGap value every EnsureDB call
	-- (a bad capture nils it so the next login attempts a real capture).
	if ACABDB.stanceBarNativeGap
		and (ACABDB.stanceBarNativeGap <= 0 or ACABDB.stanceBarNativeGap >= self.BUTTON_SIZE) then
		ACABDB.stanceBarNativeGap = nil
	end

	if ACABDB.tintWholeButtonOnRange == nil then
		ACABDB.tintWholeButtonOnRange = true
	end

	if ACABDB.disableBlizzardArt == nil then
		ACABDB.disableBlizzardArt = false
	end

	if ACABDB.snapToAdjacentElements == nil then
		ACABDB.snapToAdjacentElements = true
	end

	-- One-time correction for saves that already had this explicitly
	-- false from before the default flipped to true.
	if not ACABDB.snapDefaultCorrectedOnce then
		ACABDB.snapDefaultCorrectedOnce = true
		ACABDB.snapToAdjacentElements = true
	end

	if ACABDB.showLayoutGrid == nil then
		ACABDB.showLayoutGrid = true
	end

	if ACABDB.snapToGrid == nil then
		ACABDB.snapToGrid = true
	end

	if ACABDB.useCustomGridSize == nil then
		ACABDB.useCustomGridSize = false
	end

	if ACABDB.bagBarEnabled == nil then
		ACABDB.bagBarEnabled = true
	end
	if ACABDB.microMenuEnabled == nil then
		ACABDB.microMenuEnabled = true
	end

	if ACABDB.stanceBarEnabled == nil then
		ACABDB.stanceBarEnabled = true
	end

	if ACABDB.keyRingEnabled == nil then
		ACABDB.keyRingEnabled = true
	end
	if ACABDB.latencyBarEnabled == nil then
		ACABDB.latencyBarEnabled = true
	end
	if ACABDB.latencyBarScale == nil then
		ACABDB.latencyBarScale = 1
	end

	if ACABDB.tooltipEnabled == nil then
		ACABDB.tooltipEnabled = false
	end
	if ACABDB.tooltipScale == nil then
		ACABDB.tooltipScale = 1
	end
	if ACABDB.tooltipAnchorCorner == nil then
		ACABDB.tooltipAnchorCorner = "BOTTOMRIGHT"
	end

	if ACABDB.expBarEnabled == nil then
		ACABDB.expBarEnabled = true
	end
	if ACABDB.expBarScale == nil then
		ACABDB.expBarScale = 1
	end

	-- Stance Bar/Cast Bar "at default position" flags (Pet Bar's own lives
	-- on its cfg table instead - defaultBars[PET_BAR_ID].usesDefaultPosition,
	-- nil-safe read like every other grid-bar cfg field, no seeding here).
	-- ReflowStanceBarForBar2Toggle/ReflowCastBarForStackToggle only ever
	-- move Y while this stays true - flips false the moment the user drags
	-- or slider-edits that element's own position.
	if ACABDB.stanceBarUsesDefaultPosition == nil then
		ACABDB.stanceBarUsesDefaultPosition = true
	end

	if ACABDB.castBarUsesDefaultPosition == nil then
		ACABDB.castBarUsesDefaultPosition = true
	end

	-- Only-show-on-hover for simple elements (Bag Bar's pair also governs the Key Ring frame). Grid-bar cfg tables use nil-safe cfg.hoverOnly/cfg.hoverDuration reads instead.
	if ACABDB.bagBarHoverOnly == nil then
		ACABDB.bagBarHoverOnly = false
	end
	if ACABDB.bagBarHoverDuration == nil then
		ACABDB.bagBarHoverDuration = 3
	end

	if ACABDB.microMenuHoverOnly == nil then
		ACABDB.microMenuHoverOnly = false
	end
	if ACABDB.microMenuHoverDuration == nil then
		ACABDB.microMenuHoverDuration = 3
	end

	if ACABDB.latencyBarHoverOnly == nil then
		ACABDB.latencyBarHoverOnly = false
	end
	if ACABDB.latencyBarHoverDuration == nil then
		ACABDB.latencyBarHoverDuration = 3
	end

	if ACABDB.expBarHoverOnly == nil then
		ACABDB.expBarHoverOnly = false
	end
	if ACABDB.expBarHoverDuration == nil then
		ACABDB.expBarHoverDuration = 3
	end

	if ACABDB.castBarScale == nil then
		ACABDB.castBarScale = 1
	end

	if ACABDB.betterExpBarEnabled == nil then
		ACABDB.betterExpBarEnabled = false
	end

	if ACABDB.expBarShowCurrentOverMax == nil then
		ACABDB.expBarShowCurrentOverMax = true
	end
	if ACABDB.expBarShowPercent == nil then
		ACABDB.expBarShowPercent = true
	end
	if ACABDB.expBarShowLevel == nil then
		ACABDB.expBarShowLevel = true
	end
	if ACABDB.expBarShowRestedPercent == nil then
		ACABDB.expBarShowRestedPercent = true
	end
	if ACABDB.expBarShowRestedTotal == nil then
		ACABDB.expBarShowRestedTotal = true
	end

	-- expBarColorEarned/Rested (+ native snapshots) and expBarFontSize are
	-- captured lazily from the live frame, not seeded here.

	if not ACABDB.expBarTextColor then
		ACABDB.expBarTextColor = { r = 1, g = 0.82, b = 0 }
	end

	if ACABDB.expBarGlowPulseInterval == nil then
		ACABDB.expBarGlowPulseInterval = 1.5
	end

	if ACABDB.keyRingScale == nil then
		ACABDB.keyRingScale = 1
	end

	if ACABDB.bagBarScale == nil then
		ACABDB.bagBarScale = 1
	end
	if ACABDB.microMenuScale == nil then
		ACABDB.microMenuScale = 1
	end
	if ACABDB.stanceBarScale == nil then
		ACABDB.stanceBarScale = 1
	end

	if ACABDB.bagBarOrientation == nil then
		ACABDB.bagBarOrientation = false
	end
	if ACABDB.stanceBarOrientation == nil then
		ACABDB.stanceBarOrientation = false
	end

	-- Micro Menu uses a fixed grid (cols x rows) instead of an
	-- orientation flag - default is one row of 8, same look as before.
	if ACABDB.microMenuCols == nil then
		ACABDB.microMenuCols = 8
	end
	if ACABDB.microMenuRows == nil then
		ACABDB.microMenuRows = 1
	end

	-- bagBarSpacing/microMenuSpacing/stanceBarSpacing (+ native snapshots)
	-- are captured lazily on first real container build.

	-- One-time forced recapture of Bag Bar/Micro Menu/Stance Bar spacing,
	-- so an existing save picks up the corrected median-based capture
	-- math. Not a schema bump - that would also wipe ACABDB.bars.
	if not ACABDB.spacingRecaptureDone then
		ACABDB.spacingRecaptureDone = true

		ACABDB.bagBarSpacing = nil
		ACABDB.bagBarNativeSpacing = nil
		ACABDB.microMenuSpacing = nil
		ACABDB.microMenuNativeSpacing = nil
		ACABDB.stanceBarSpacing = nil
		ACABDB.stanceBarNativeSpacing = nil
	end

	-- hotkeyFontSize/countFontSize/macroFontSize stay nil until the user
	-- moves a slider; Button.lua treats nil as "use the captured default".

	if ACABDB.showMacroText == nil then
		ACABDB.showMacroText = false
	end

	-- One-time forced recapture of default-bar native anchors/spacing
	-- (clears ACABDB.defaultBars so seedDefaultBars reruns), without
	-- wiping ACABDB.bars the way a schema bump would.
	if not ACABDB.anchorRecaptureDone then
		ACABDB.anchorRecaptureDone = true

		ACABDB.defaultBars = nil

		ACABDB.mainBarPageIndicatorNativeAnchor = nil
		ACABDB.mainBarPageIndicatorPosition = nil
	end

	if not ACABDB.anchorScaleFixDone then
		ACABDB.anchorScaleFixDone = true

		ACABDB.defaultBars = nil

		ACABDB.mainBarPageIndicatorNativeAnchor = nil
		ACABDB.mainBarPageIndicatorPosition = nil
	end

	if not ACABDB.anchorTimingFixDone then
		ACABDB.anchorTimingFixDone = true

		ACABDB.defaultBars = nil

		ACABDB.mainBarPageIndicatorNativeAnchor = nil
		ACABDB.mainBarPageIndicatorPosition = nil
	end

	if not ACABDB.anchorEnterWorldFixDone then
		ACABDB.anchorEnterWorldFixDone = true

		ACABDB.defaultBars = nil

		ACABDB.mainBarPageIndicatorNativeAnchor = nil
		ACABDB.mainBarPageIndicatorPosition = nil
	end

	if not ACABDB.schemaVersion or ACABDB.schemaVersion < self.SCHEMA_VERSION then
		ACABDB.schemaVersion = self.SCHEMA_VERSION
		ACABDB.defaultBars = seedDefaultBars(self)
		ACABDB.bars = {}
	end

	if not ACABDB.defaultBars then
		ACABDB.defaultBars = seedDefaultBars(self)
	end

	-- Migration-safe: an existing save from before the Pet Bar existed has
	-- ACABDB.defaultBars already populated (ids 1-5) but no entry for
	-- ACAB.PET_BAR_ID - seed just that one id rather than bumping
	-- SCHEMA_VERSION (which would wipe ACABDB.bars).
	if not ACABDB.defaultBars[self.PET_BAR_ID] then
		ACABDB.defaultBars[self.PET_BAR_ID] = SeedOneDefaultBar(self, self.PET_BAR_ID)
	end

	-- Structural constants for the Pet Bar cfg, re-asserted every call so a
	-- save from before this field existed self-heals without a reseed.
	do
		local petCfg = ACABDB.defaultBars[self.PET_BAR_ID]

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

	-- Pet Bar's own default position is set later, by SetupPetBarNativeContainer.

	-- Migration-safe: an existing save from before the Stance Bar's styled
	-- mode existed has no entry for ACAB.STANCE_BAR_ID - seed just that one
	-- id, same treatment as the Pet Bar migration above. This is purely
	-- additive - the pre-existing native-mode ACABDB.stanceBar* fields
	-- are never touched here.
	if not ACABDB.defaultBars[self.STANCE_BAR_ID] then
		ACABDB.defaultBars[self.STANCE_BAR_ID] = SeedOneDefaultBar(self, self.STANCE_BAR_ID)
	end

	-- Structural constants for the Stance Bar cfg, re-asserted every call so
	-- a save from before this field existed self-heals without a reseed.
	do
		local stanceCfg = ACABDB.defaultBars[self.STANCE_BAR_ID]

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

	if not ACABDB.bars then
		ACABDB.bars = {}
	end

	self:EnsureExtraBars()

	-- Force hoverbind off once per session, not on every EnsureDB call
	-- (which would stomp ACAB:SetHoverBindMode(true) mid-session).
	if not hasResetHoverBindModeThisSession then
		ACABDB.hoverBindMode = false
		hasResetHoverBindModeThisSession = true
	end
end
