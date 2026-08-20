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

-- Real proportions from vanilla's own ActionButtonTemplate.xml: the
-- equip-quality ring is 62/36 the size of the button, centered. Kept as
-- a ratio (not a fixed pixel size) so it scales correctly with any
-- button size, including through bar-scaling later.
BTV.EQUIP_RING_RATIO = 62 / 36

function BTV:EnsureDB()
	if not BTVanillaDB then
		BTVanillaDB = {}
	end
	if BTVanillaDB.editMode == nil then
		BTVanillaDB.editMode = false
	end
	if BTVanillaDB.lockActionBars == nil then
		BTVanillaDB.lockActionBars = false
	end
	if not BTVanillaDB.bars then
		BTVanillaDB.bars = {}
		if BTVanillaDB.bar then
			-- Migrate from the earlier single-bar prototype's saved data
			-- so testers don't lose their bar position when updating.
			local old = BTVanillaDB.bar
			BTVanillaDB.bars[1] = {
				id = 1,
				point = old.point, relativePoint = old.relativePoint,
				x = old.x, y = old.y,
				cols = self.BUTTON_COLS, rows = self.BUTTON_ROWS,
				buttonSize = self.BUTTON_SIZE,
				slotStart = self.ACTION_SLOT_START,
			}
			BTVanillaDB.bar = nil
		else
			BTVanillaDB.bars[1] = {
				id = 1,
				point = "CENTER", relativePoint = "CENTER", x = 0, y = -200,
				cols = self.BUTTON_COLS, rows = self.BUTTON_ROWS,
				buttonSize = self.BUTTON_SIZE,
				slotStart = self.ACTION_SLOT_START,
			}
		end
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
	BTVanillaDB.editMode = enabled and true or false
	self:ApplyEditModeVisual()
end

function BTV:ToggleEditMode()
	self:SetEditMode(not self:IsEditMode())
	self:Print(self:IsEditMode()
		and "Configure Layout ON - drag buttons to move bars, scroll to scale, right-click for bar settings."
		or "Configure Layout OFF.")
end

-------------------------------------------------------------------------
-- Lock Action Bars
-------------------------------------------------------------------------
-- Attempts to mirror this to a real Blizzard CVar if one exists on this
-- client, but is NOT confirmed to exist in true vanilla 1.12 - neither
-- ClassicAPI/nampower/SuperWoW/UnitXP's extracted strings nor the real
-- 1.12.1 FrameXML source for ActionButton.lua reference any such CVar or
-- drag-lock logic. This may be a later-patch (TBC+) addition, the same
-- way SecureHandler templates are. Our own bars work correctly either
-- way since BTVanillaDB.lockActionBars is the authoritative source for
-- them; the CVar sync is best-effort only. Worth confirming in-game.
--
-- IMPORTANT: GetCVar throws a hard Lua error on an unrecognized CVar
-- name on this client (confirmed live - "lockActionBars" errored rather
-- than returning nil), not the graceful nil-return I'd assumed. Pulled
-- back to a safe no-op until a real CVar name is confirmed via
-- /btvcvar - guessing further candidate names blind risks the same
-- crash again for a setting that may not even exist on this client
-- generation at all.

function BTV:TrySyncNativeLockCVar(value)
	-- Deliberately not attempting any CVar name right now - see note
	-- above. Returns false (not synced) unconditionally until we've
	-- confirmed a real CVar together via /btvcvar.
	return false
end

-- Diagnostic: safely probes any CVar name (wraps GetCVar in pcall, since
-- it errors hard on an unrecognized name rather than returning nil).
-- Usage: /btvcvar lockActionBar
SLASH_BTVCVAR1 = "/btvcvar"
SlashCmdList["BTVCVAR"] = function(msg)
	if not msg or msg == "" then
		BTV:Print("Usage: /btvcvar <cvarname>  e.g. /btvcvar lockActionBar")
		return
	end
	if type(GetCVar) ~= "function" then
		BTV:Print("GetCVar is not available at all in this client.")
		return
	end
	local ok, result = pcall(GetCVar, msg)
	if ok then
		BTV:Print("GetCVar('" .. msg .. "') = " .. tostring(result) .. "  -> CVar exists.")
	else
		BTV:Print("GetCVar('" .. msg .. "') FAILED: " .. tostring(result) .. "  -> CVar does not exist.")
	end
end

function BTV:IsLockActionBars()
	-- Nil-safe for the same reason as IsEditMode above.
	return BTVanillaDB and BTVanillaDB.lockActionBars == true
end

function BTV:SetLockActionBars(enabled)
	self:EnsureDB()
	BTVanillaDB.lockActionBars = enabled and true or false
	self:TrySyncNativeLockCVar(BTVanillaDB.lockActionBars)
	-- No confirmed native CVar on this client yet - our own bars still
	-- respect BTVanillaDB.lockActionBars correctly regardless.
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

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("PLAYER_LOGIN")
loadFrame:SetScript("OnEvent", function()
	BTV:EnsureDB()
	BTV:CreateAllBars()
	BTV:CreateMinimapButton()
	BTV:Print("Loaded. Click the minimap button for options.")
end)

SLASH_BTVANILLA1 = "/btv"
SlashCmdList["BTVANILLA"] = function()
	BTV:ToggleMainMenu()
end
