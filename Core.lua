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

-- Grid shape for each default bar. Position is captured live, not stored
-- here - see CaptureNativeAnchor.
BTV.DEFAULT_BAR_GRID = {
	[1] = { cols = 12, rows = 1 },                      -- Main.
	[2] = { cols = 12, rows = 1, enabled = false },      -- Bottom Left.
	[3] = { cols = 12, rows = 1, enabled = false },      -- Bottom Right.
	[4] = { cols = 1,  rows = 12, enabled = false },     -- Right.
	[5] = { cols = 1,  rows = 12, enabled = false },     -- Right 2.
}

-- Native FrameXML global backing each default bar's own Interface Options
-- checkbox. Session-scoped cosmetic use only - these globals do not
-- persist across a real logout on this client, so never read them as the
-- source of truth for what to apply at login.
BTV.SHOW_MULTI_ACTIONBAR_GLOBAL = {
	[2] = "SHOW_MULTI_ACTIONBAR_1",
	[3] = "SHOW_MULTI_ACTIONBAR_2",
	[4] = "SHOW_MULTI_ACTIONBAR_3",
	[5] = "SHOW_MULTI_ACTIONBAR_4",
}

-- Friendly display names for the 5 fixed default bars.
BTV.DEFAULT_BAR_NAMES = {
	[1] = "Main Bar",
	[2] = "Action Bar 1",
	[3] = "Action Bar 2",
	[4] = "Right Action Bar 1",
	[5] = "Right Action Bar 2",
}

-- Extra Bars (ids EXTRA_BAR_ID_START..+COUNT-1) are numbered from 1 for
-- the user. String-keyed chain-anchored elements (Bag Bar, Stance Bar,
-- etc.) are handled separately via EnsureContainerOverlay's displayName
-- argument.
function BTV:GetBarDisplayName(barId)
	if barId and barId >= 1 and barId <= 5 then
		return self.DEFAULT_BAR_NAMES[barId] or ("Bar " .. tostring(barId))
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
}

-- Builds a fresh BTVanillaDB.defaultBars table by capturing each default
-- bar's real native anchor/spacing/action-slots.
local function seedDefaultBars(self)
	local result = {}
	local id

	for id = 1, 5 do
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

		result[id] = {
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
			result[id].dynamicMainBar = true
		end

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

	return true
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

	-- hotkeyFontSize/countFontSize stay nil until the user moves a
	-- slider; Button.lua treats nil as "use the native captured default".

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

-- Returns how far (local units, pre-scale) a frame's visible border
-- overhangs its own frame bounds on each side, non-zero only for default
-- bars 1-5 in vanilla border style. Custom bars and every chain-anchored
-- element return 0.
function BTV:GetElementVisualInset(frame)
	if frame and frame.config and frame.config.id and self:IsVanillaBorderStyle() then
		local buttonSize = frame.config.buttonSize or self.BUTTON_SIZE
		local uniform = buttonSize * (self.BORDER_RATIO - 1) / 2
		local yOffset = self.BORDER_Y_OFFSET or 0
		local fudge = self.BORDER_TEXTURE_FUDGE or 0

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

-- buttonSize a brand-new bar should seed at, already correct for the
-- currently active style.
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
