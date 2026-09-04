-- UIWidgets.lua
-- Small, reusable Mixin-based dialog/dropdown widget kit, built directly
-- on ClassicAPI's own confirmed-working primitives (Mixin/CreateFromMixins
-- - true DLL-native globals on this client, not Lua polyfills) rather than
-- vendoring in a third-party UI library - see
-- docs/01-Environment-Capability-Analysis.md section 3.1 for what
-- ClassicAPI actually provides and how it was confirmed. This is
-- deliberately the pilot for a broader future UI redesign (per the user's
-- own plan), so it's a small general-purpose widget kit rather than one-off
-- copy-pasted frames per dialog need - BTVDialogMixin covers every dialog
-- shape the Profiles feature needs (plain confirm, text input, dropdown
-- selection) through one config table instead of three separate widgets.
--
-- Vanilla WoW 1.12.1 / Lua 5.0 compatible - see Button.lua's own header
-- comment for the `this`-vs-`:method()` convention this file follows too:
-- engine-invoked script handlers (OnClick, OnShow, OnHide) receive the
-- frame via the global `this`, never as a `self` parameter.
--
-- No StaticPopup/EditBox/inline-dropdown-selector precedent exists
-- anywhere else in this addon (confirmed via a full-repo search before
-- writing this file) - this is genuinely new UI infrastructure, not a
-- refactor of something that already worked.

local BTV = BTVanilla

-- Shared colors for the fade-strip hover/select treatment (BTVFadeStripMixin
-- below) - one place to change "the gold" addon-wide instead of a scattered
-- literal per call site (StyleModernButton's own hover border literal is
-- left as its own inline value on purpose - out of scope here, not broken).
BTV.UI_ACCENT_COLOR = { 1, 0.82, 0 }
BTV.UI_HOVER_COLOR = { 1, 1, 1 }

-------------------------------------------------------------------------
-- BTVInlineDropdownMixin
--
-- Wraps the same native UIDropDownMenuTemplate/UIDropDownMenu_AddButton/
-- UIDropDownMenu_Initialize system Menu.lua already uses for the minimap
-- button's right-click context menu - but as a PERSISTENT in-panel
-- selector (a "<select>") instead of a transient right-click popup. The
-- underlying native API is unchanged; only how/when it's shown differs.
-------------------------------------------------------------------------

BTVInlineDropdownMixin = {}

-- parent: frame to anchor into. name: REQUIRED, not optional - unlike
-- every other frame in this addon, UIDropDownMenuTemplate's own native
-- FrameXML machinery (Interface\FrameXML\UIDropDownMenu.lua) builds
-- internal sub-widget references by string-concatenating this frame's
-- own GetName() throughout (UIDropDownMenu_Initialize/SetWidth/etc.) -
-- a nameless dropdown makes that native code fail with "attempt to
-- concatenate a nil value" the moment UIDropDownMenu_Initialize runs
-- below, live-tested and confirmed (Interface\FrameXML\UIDropDownMenu.lua:714).
-- Returns the created dropdown frame with this mixin applied.
function BTV:CreateInlineDropdown(parent, widthPixels, name)
	local dropdown = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")

	-- CreateFrame only applies `parent` the FIRST time a given global `name`
	-- is created - on every reuse (the whole point of passing a stable name
	-- here, see the header comment above) it silently keeps whatever parent
	-- the frame already had. RebuildMainBarAssignmentRows builds a brand
	-- new `row` frame every rebuild and SetParent(nil)'s the OLD one once
	-- it's replaced - without this explicit SetParent, the dropdown stays
	-- attached to that now-orphaned old row forever, which is the actual
	-- cause of the fragmented skin/blank label after switching bar pages
	-- away and back (an orphaned-parent frame doesn't reliably render or
	-- receive OnShow through the hierarchy even while IsShown() is true).
	dropdown:SetParent(parent)

	Mixin(dropdown, BTVInlineDropdownMixin)
	dropdown:OnLoad(widthPixels)

	return dropdown
end

function BTVInlineDropdownMixin:OnLoad(widthPixels)
	self.options = {}
	self.selected = nil
	self.onSelect = nil
	self.widthPixels = widthPixels or 160

	UIDropDownMenu_SetWidth(self.widthPixels, self)

	-- Re-applied on every OnShow too, not just here - live-tested reports
	-- of the Left/Middle/Right skin pieces rendering fragmented (visible
	-- gaps between them) on a dropdown built while its page was still
	-- hidden (e.g. RebuildMainBarAssignmentRows runs before ShowBarPage's
	-- own :Show() call) suggest UIDropDownMenuTemplate's skin textures
	-- don't reliably finish settling into the width this call already
	-- passed them at that point - cheap to just redo once actually shown.
	-- Same reasoning applies to the displayed label text: SetSelected can
	-- (and for the Main Bar assignment rows, always does) run while this
	-- frame is still hidden, and UIDropDownMenu_SetText doesn't reliably
	-- stick from that state either - reapplying the cached
	-- selectedDisplayText here fixes the label going blank/stale after
	-- switching bar pages away and back.
	self:SetScript("OnShow", function()
		UIDropDownMenu_SetWidth(this.widthPixels, this)

		if this.selectedDisplayText then
			UIDropDownMenu_SetText(this.selectedDisplayText, this)
		end
	end)

	local dropdown = self

	UIDropDownMenu_Initialize(self, function()
		local info
		local i

		for i = 1, table.getn(dropdown.options) do
			local option = dropdown.options[i]

			-- Each entry is either a plain string (label IS the value - the
			-- original/common case, e.g. profile names) or a
			-- { text = "...", value = ... } table when the underlying
			-- stored value isn't itself a sensible display label (e.g. a
			-- numeric bar id) - both shapes share one code path here.
			local optionText = (type(option) == "table") and option.text or option
			local optionValue = (type(option) == "table") and option.value or option

			info = {}
			info.text = optionText
			info.notCheckable = true
			info.func = function()
				dropdown:SetSelected(optionValue, optionText)

				if dropdown.onSelect then
					dropdown.onSelect(optionValue)
				end
			end

			UIDropDownMenu_AddButton(info)
		end
	end)
end

-- options: a plain array of strings (already ordered by the caller - e.g.
-- BTV:GetProfileNames() with a trailing "Create new profile" sentinel
-- appended by Settings.lua where relevant), OR an array of
-- { text = "...", value = ... } tables when the value isn't itself a
-- usable label.
function BTVInlineDropdownMixin:SetOptions(options)
	self.options = options or {}
end

-- displayText is optional - when omitted (the plain-string-options case),
-- `value` itself is shown, same as before. When options are
-- { text =, value = } pairs, callers should pass the matching text
-- explicitly (as OnLoad's own selection handler above does); this function
-- falls back to searching self.options for a matching value so a caller
-- driving the initial/refreshed selection from stored data alone still
-- shows the right label without duplicating the options table.
function BTVInlineDropdownMixin:SetSelected(value, displayText)
	self.selected = value

	if not displayText then
		local i

		for i = 1, table.getn(self.options) do
			local option = self.options[i]

			if type(option) == "table" then
				if option.value == value then
					displayText = option.text
					break
				end
			elseif option == value then
				displayText = option
				break
			end
		end
	end

	-- Cached so OnShow (below) can reapply the label - UIDropDownMenu_SetText
	-- called while this frame is still hidden (RebuildMainBarAssignmentRows
	-- runs RefreshValue()/SetSelected before ShowBarPage's own :Show()) does
	-- not reliably stick, same underlying cause as the width-fragmentation
	-- fix already applied in OnLoad's OnShow handler below.
	self.selectedDisplayText = displayText or value

	UIDropDownMenu_SetText(self.selectedDisplayText, self)
end

function BTVInlineDropdownMixin:GetSelected()
	return self.selected
end

-------------------------------------------------------------------------
-- Modern button styling
--
-- UIPanelButtonTemplate's native 3-slice texture is built for short,
-- fixed-width labels (e.g. "Okay"/"Cancel") - stretched out to the wide,
-- variable widths this addon's dialogs need for long button labels (the
-- first-login dialog's own "I know what im doing, use default profile"),
-- its corner/middle pieces visibly distort. This backdrop-based button
-- instead scales cleanly to any width (SetBackdrop tiles/stretches its
-- edge and background independently, unlike a fixed 3-slice texture) and
-- matches the "modern" border look already used elsewhere in this addon
-- (Button.lua's own modern button style) for one consistent visual
-- language. General-purpose (not dialog-specific) since this file is
-- meant to be the pilot for a broader future UI redesign.
-------------------------------------------------------------------------

-- Turns a plain, template-less Button frame into a modern-styled one.
-- Caller still creates the frame (CreateFrame("Button", ...)), sets its
-- own SetHeight/OnClick/etc as normal - this only applies the visuals and
-- installs a :SetText that both updates the label AND resizes the button
-- to fit it (BTV_BUTTON_PADDING_X either side), clamped to
-- [minWidth, maxWidth] so a short label doesn't look stretched and a long
-- one doesn't overflow its container. Pass 0/math.huge (or omit) for no
-- clamping on that side.
local BTV_BUTTON_PADDING_X = 32

function BTV:StyleModernButton(button, minWidth, maxWidth)
	button:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})

	button:SetBackdropColor(0.08, 0.08, 0.08, 0.85)
	button:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)

	local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

	text:SetPoint("CENTER", button, "CENTER", 0, 0)
	text:SetJustifyH("CENTER")

	button.text = text
	button.minWidth = minWidth or 0
	button.maxWidth = maxWidth or 0

	-- Overrides the native Button:SetText - a plain, template-less Button
	-- has no default font region wired to it the way a templated one
	-- does, and this addon still wants every caller to just say
	-- button:SetText(...) as normal.
	button.SetText = function(self, value)
		text:SetText(value or "")

		local width = (text:GetStringWidth() or 0) + BTV_BUTTON_PADDING_X

		if self.minWidth and self.minWidth > 0 and width < self.minWidth then
			width = self.minWidth
		end

		if self.maxWidth and self.maxWidth > 0 and width > self.maxWidth then
			width = self.maxWidth
		end

		self:SetWidth(width)
	end

	button:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 0.82, 0, 1)
	end)

	button:SetScript("OnLeave", function()
		this:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
	end)

	button:SetScript("OnMouseDown", function()
		if this:IsEnabled() ~= false then
			this.text:SetPoint("CENTER", this, "CENTER", 1, -1)
		end
	end)

	button:SetScript("OnMouseUp", function()
		this.text:SetPoint("CENTER", this, "CENTER", 0, 0)
	end)

	-- :Disable()/:Enable() are native Button methods (grey out + block
	-- clicks) - just also dim our own backdrop/text to match, since the
	-- native greyed-out look is baked into UIPanelButtonTemplate's
	-- texture, which this button no longer has.
	local nativeDisable = button.Disable
	local nativeEnable = button.Enable

	button.Disable = function(self)
		nativeDisable(self)
		self:SetBackdropColor(0.08, 0.08, 0.08, 0.5)
		self.text:SetTextColor(0.5, 0.5, 0.5)
	end

	button.Enable = function(self)
		nativeEnable(self)
		self:SetBackdropColor(0.08, 0.08, 0.08, 0.85)
		self.text:SetTextColor(1, 1, 1)
	end
end

-------------------------------------------------------------------------
-- BTVDialogMixin
--
-- One reusable dialog frame covering every shape the spec needs:
--   mode = "confirm"   - title/message + buttons only
--   mode = "textinput" - adds an EditBox (InputBoxTemplate - the standard
--                         vanilla 1.12 FrameXML text-input widget, e.g.
--                         used by the Guild Info/note editors)
--   mode = "dropdown"  - adds a BTVInlineDropdownMixin populated from
--                         config.options
--
-- A single frame instance is created lazily once (BTV.activeDialog) and
-- reconfigured on every BTV:ShowDialog call, mirroring Settings.lua's own
-- "one frame, reused" convention (CreateSettingsFrame) rather than
-- building/destroying a new frame per dialog. Only one BTV dialog is ever
-- open at a time in this addon's flows (each dialog's own button click
-- closes it before any follow-up dialog opens), so this is sufficient -
-- flagged here in case a future caller ever needs to stack dialogs.
-------------------------------------------------------------------------

BTVDialogMixin = {}

local DIALOG_WIDTH = 360
local DIALOG_BUTTON_HEIGHT = 22
local DIALOG_BUTTON_MIN_WIDTH = 100

local function EnsureDialogFrame()
	if BTV.activeDialog then
		return BTV.activeDialog
	end

	local dialog = CreateFrame("Frame", "BTVanillaDialog", UIParent)

	Mixin(dialog, BTVDialogMixin)
	dialog:OnLoad()

	BTV.activeDialog = dialog

	return dialog
end

function BTVDialogMixin:OnLoad()
	-- FULLSCREEN_DIALOG: above Settings.lua's own DIALOG-strata window
	-- (CreateSettingsFrame, Settings.lua) so a Profiles dialog always
	-- renders on top of it.
	self:SetFrameStrata("FULLSCREEN_DIALOG")
	self:SetWidth(DIALOG_WIDTH)
	self:SetHeight(160)
	self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

	-- Same DialogFrame backdrop CreateSettingsFrame uses (Settings.lua),
	-- for visual consistency with the rest of the addon's UI.
	self:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})

	self:EnableMouse(true)
	self:SetMovable(true)
	self:RegisterForDrag("LeftButton")
	self:SetScript("OnDragStart", function() this:StartMoving() end)
	self:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

	self.titleText = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	self.titleText:SetPoint("TOP", self, "TOP", 0, -18)
	self.titleText:SetWidth(DIALOG_WIDTH - 40)

	self.messageText = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.messageText:SetPoint("TOP", self.titleText, "BOTTOM", 0, -10)
	self.messageText:SetWidth(DIALOG_WIDTH - 40)
	self.messageText:SetJustifyH("CENTER")

	-- InputBoxTemplate: the standard vanilla 1.12 FrameXML EditBox
	-- template (first use anywhere in this addon - no existing EditBox
	-- precedent to mirror). Created hidden; shown only for mode ==
	-- "textinput".
	self.editBox = CreateFrame("EditBox", "BTVanillaDialogEditBox", self, "InputBoxTemplate")
	self.editBox:SetWidth(DIALOG_WIDTH - 80)
	self.editBox:SetHeight(20)
	self.editBox:SetAutoFocus(true)
	self.editBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	self.editBox:SetScript("OnEnterPressed", function()
		this:ClearFocus()
		BTV.activeDialog:ClickDefaultButton()
	end)
	self.editBox:Hide()

	self.dropdown = BTV:CreateInlineDropdown(self, DIALOG_WIDTH - 80, "BTVanillaDialogDropdown")
	self.dropdown:Hide()

	-- 4, not 3 - the first-login dialog (Core.lua's BTV:ShowFirstLoginDialog)
	-- has 3 default buttons plus a conditional 4th ("use existing profile"),
	-- the largest button count any dialog in this feature needs.
	self.buttons = {}

	local i

	for i = 1, 4 do
		local button = CreateFrame("Button", nil, self)

		button:SetHeight(DIALOG_BUTTON_HEIGHT)

		-- Min width keeps very short labels ("OK") from looking like a
		-- tiny nub; max width is the same usable width the title/message
		-- text already wraps to, so a long label is the only thing that
		-- ever grows a button to full dialog width.
		BTV:StyleModernButton(button, DIALOG_BUTTON_MIN_WIDTH, DIALOG_WIDTH - 40)
		button:Hide()

		self.buttons[i] = button
	end

	self:Hide()
end

-- config = {
--     title = "...", message = "...",
--     mode = "confirm" | "textinput" | "dropdown",
--     defaultText = "...",     -- textinput: EditBox starting value
--     options = { "A", "B" },  -- dropdown: selectable values
--     buttons = { { text = "Accept", isDefault = true, onClick = function(value) end }, ... },
-- }
function BTVDialogMixin:Init(config)
	config = config or {}

	self.mode = config.mode or "confirm"
	self.buttonConfigs = config.buttons or {}

	self.titleText:SetText(config.title or "")
	self.messageText:SetText(config.message or "")

	self.editBox:Hide()
	self.dropdown:Hide()

	if self.mode == "textinput" then
		self.editBox:SetPoint("TOP", self.messageText, "BOTTOM", 0, -14)
		self.editBox:SetText(config.defaultText or "")
		self.editBox:HighlightText()
		self.editBox:Show()
	elseif self.mode == "dropdown" then
		self.dropdown:ClearAllPoints()
		self.dropdown:SetPoint("TOP", self.messageText, "BOTTOM", 0, -10)
		self.dropdown:SetOptions(config.options or {})
		self.dropdown:SetSelected((config.options or {})[1])
		self.dropdown:Show()
	end

	-- Buttons flow horizontally, wrapping into as many centered rows as
	-- needed - each row's buttons sit side by side with equal
	-- BUTTON_GAP_X spacing, and the row itself is centered on the
	-- dialog's own horizontal center (matching title/message/mode content,
	-- which are all centered the same way). A row only wraps to a new
	-- line once it can no longer fit the next button within the dialog's
	-- usable width, so a single short-label confirm still renders as one
	-- row, while the first-login dialog's four long labels spread across
	-- multiple rows instead of forcing one axis to be either overflowing
	-- (all in one row) or needlessly tall (one per row, the old design).
	local BUTTON_GAP_X = 12
	local BUTTON_ROW_GAP_Y = 8
	local availableWidth = DIALOG_WIDTH - 40

	local i
	local count = table.getn(self.buttonConfigs)
	self.defaultButtonIndex = nil

	-- Pass 1: configure every visible button (label/click handler) so its
	-- real, content-fit width (BTV:StyleModernButton's SetText override)
	-- is known before row-packing below.
	for i = 1, 4 do
		local button = self.buttons[i]
		local buttonConfig = self.buttonConfigs[i]

		if buttonConfig then
			button:SetText(buttonConfig.text or "")

			button:SetScript("OnClick", function()
				local value = BTV.activeDialog:GetValue()

				BTV.activeDialog:Hide()

				if buttonConfig.onClick then
					buttonConfig.onClick(value)
				end
			end)

			if buttonConfig.isDefault then
				self.defaultButtonIndex = i
			end

			button:Show()
		else
			button:Hide()
		end
	end

	if not self.defaultButtonIndex and count > 0 then
		self.defaultButtonIndex = 1
	end

	-- Pass 2: greedily wrap buttons 1..count into rows - rows[r] is an
	-- array of button indices, rowWidths[r] is that row's total width
	-- (buttons + the BUTTON_GAP_X between them), used to center it below.
	local rows = {}
	local rowWidths = {}
	local rowCount = 0

	for i = 1, count do
		local button = self.buttons[i]
		local width = button:GetWidth()
		local addWidth = width

		if rowCount > 0 and table.getn(rows[rowCount]) > 0 then
			addWidth = BUTTON_GAP_X + width

			if (rowWidths[rowCount] + addWidth) > availableWidth then
				rowCount = rowCount + 1
				rows[rowCount] = {}
				rowWidths[rowCount] = 0
				addWidth = width
			end
		else
			rowCount = rowCount + 1
			rows[rowCount] = {}
			rowWidths[rowCount] = 0
		end

		table.insert(rows[rowCount], i)
		rowWidths[rowCount] = rowWidths[rowCount] + addWidth
	end

	-- Content-aware sizing/positioning: every button row is anchored
	-- directly off self's own TOP with a precomputed pixel offset (rather
	-- than chaining off the previous element's rendered position) so its
	-- horizontal centering offset can be applied independently of its
	-- vertical stacking order. Mirrors titleText's own existing pattern of
	-- anchoring straight to self "TOP". TOP_OFFSET/title/message/mode-
	-- content gaps match OnLoad's own anchor chain for those elements.
	local TOP_OFFSET = 18
	local BOTTOM_PADDING = 20

	local contentBottomY = TOP_OFFSET
	contentBottomY = contentBottomY + (self.titleText:GetHeight() or 0)
	contentBottomY = contentBottomY + 10 + (self.messageText:GetHeight() or 0)

	if self.mode == "textinput" then
		contentBottomY = contentBottomY + 14 + (self.editBox:GetHeight() or 0)
	elseif self.mode == "dropdown" then
		contentBottomY = contentBottomY + 10 + (self.dropdown:GetHeight() or 0)
	end

	local rowY = contentBottomY
	local r

	for r = 1, rowCount do
		local rowGap = (r == 1) and 14 or BUTTON_ROW_GAP_Y

		rowY = rowY + rowGap

		local row = rows[r]
		local cursorX = -(rowWidths[r] / 2)
		local j

		for j = 1, table.getn(row) do
			local button = self.buttons[row[j]]
			local width = button:GetWidth()
			local centerX = cursorX + (width / 2)

			button:ClearAllPoints()
			button:SetPoint("TOP", self, "TOP", centerX, -rowY)

			cursorX = cursorX + width + BUTTON_GAP_X
		end

		rowY = rowY + DIALOG_BUTTON_HEIGHT
	end

	self:SetHeight(rowY + BOTTOM_PADDING)
end

function BTVDialogMixin:GetValue()
	if self.mode == "textinput" then
		return self.editBox:GetText()
	elseif self.mode == "dropdown" then
		return self.dropdown:GetSelected()
	end

	return nil
end

-- Invokes the default button's own OnClick handler directly rather than
-- via a Button:Click() call - vanilla 1.12's Button widget type isn't
-- confirmed to support :Click() (a later-API addition), and the handler
-- itself doesn't depend on `this`/engine-invocation context, so calling it
-- as a plain function is equivalent and doesn't rely on an unconfirmed
-- API.
function BTVDialogMixin:ClickDefaultButton()
	local index = self.defaultButtonIndex
	local button = index and self.buttons[index]

	if button and button:IsShown() then
		local handler = button:GetScript("OnClick")

		if handler then
			handler()
		end
	end
end

-- Named Display rather than Show deliberately - Mixin(dialog,
-- BTVDialogMixin) copies this function directly onto the frame's own
-- table, which would SHADOW the frame's native :Show() method if we named
-- it that (direct table assignment always wins over the widget
-- prototype's metatable-based method lookup), making the native Show
-- unreachable/recursive. Keeping this under a different name avoids that
-- entirely rather than relying on unverified metatable internals to reach
-- back through it.
function BTVDialogMixin:Display()
	self:Show()

	if self.mode == "textinput" then
		self.editBox:SetFocus()
	end
end

-- BTV:ShowDialog(config) - the one entry point every caller (Settings.lua,
-- Core.lua's first-login flow) uses for every dialog need. Reuses the one
-- lazily-created dialog frame (EnsureDialogFrame above).
function BTV:ShowDialog(config)
	local dialog = EnsureDialogFrame()

	dialog:Init(config)
	dialog:Display()

	return dialog
end

-------------------------------------------------------------------------
-- BTVFadeStripMixin / BTV:CreateFadeStrip
--
-- A horizontal transparent -> solid -> transparent highlight strip, split
-- 10%/80%/10% across its own width. This client's Texture:SetGradientAlpha
-- only interpolates between 2 stops (no native 3-stop gradient primitive),
-- so the flat 80% middle section has to be a separately-colored plain
-- WHITE8X8 texture, not a wider gradient - hence 3 stacked textures rather
-- than 1. Used both by the top nav tabs (Settings.lua, replacing their old
-- solid-border hover swap) and by BTVListRowMixin's select/hover layers
-- below - one widget, two call sites.
-------------------------------------------------------------------------

BTVFadeStripMixin = {}

-- parent: frame to anchor into. width/height: the strip's initial pixel
-- size (see :SetStripWidth to resize later without recreating textures).
function BTV:CreateFadeStrip(parent, width, height)
	local strip = CreateFrame("Frame", nil, parent)

	Mixin(strip, BTVFadeStripMixin)

	-- Never wants to intercept mouse events itself - it's a pure visual
	-- overlay, layered over whatever real interactive frame (button/row/
	-- checkbox) it's decorating, and per item 4 of the styling pass it can
	-- extend past its own parent row's width into a sibling checkbox's
	-- hit-region, where it must not steal clicks/hover.
	strip:EnableMouse(false)
	strip:SetHeight(height)

	strip.r, strip.g, strip.b = 1, 1, 1
	strip.peakAlpha = 1

	strip.leftTex = strip:CreateTexture(nil, "ARTWORK")
	strip.leftTex:SetTexture("Interface\\Buttons\\WHITE8X8")

	strip.midTex = strip:CreateTexture(nil, "ARTWORK")
	strip.midTex:SetTexture("Interface\\Buttons\\WHITE8X8")

	strip.rightTex = strip:CreateTexture(nil, "ARTWORK")
	strip.rightTex:SetTexture("Interface\\Buttons\\WHITE8X8")

	strip:SetStripWidth(width)
	strip:ApplyFadeColors()

	return strip
end

-- Resizes the frame and recomputes the 10/80/10 texture split - kept
-- separate from color/alpha updates so BTVListRowMixin:SetVisualWidth can
-- resize an already-colored strip without touching its color.
function BTVFadeStripMixin:SetStripWidth(width)
	self:SetWidth(width)

	local edgeWidth = width * 0.1
	local midWidth = width - (edgeWidth * 2)
	local height = self:GetHeight()

	self.leftTex:ClearAllPoints()
	self.leftTex:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	self.leftTex:SetWidth(edgeWidth)
	self.leftTex:SetHeight(height)

	self.midTex:ClearAllPoints()
	self.midTex:SetPoint("TOPLEFT", self.leftTex, "TOPRIGHT", 0, 0)
	self.midTex:SetWidth(midWidth)
	self.midTex:SetHeight(height)

	self.rightTex:ClearAllPoints()
	self.rightTex:SetPoint("TOPLEFT", self.midTex, "TOPRIGHT", 0, 0)
	self.rightTex:SetWidth(edgeWidth)
	self.rightTex:SetHeight(height)
end

-- Resizes just the height (SetStripWidth already recomputes the 3
-- textures' own SetHeight from self:GetHeight() every time it runs, but
-- nothing re-runs SetStripWidth when only the strip's HEIGHT changes -
-- e.g. BTVListRowMixin:SetHeight, called by every row's own
-- row:SetHeight(LIST_ROW_HEIGHT) AFTER OnLoad already created the strips
-- at whatever bogus height the row had at that point, typically 0).
function BTVFadeStripMixin:SetStripHeight(height)
	self:SetHeight(height)

	self.leftTex:SetHeight(height)
	self.midTex:SetHeight(height)
	self.rightTex:SetHeight(height)
end

-- Re-runs the gradient/solid-color calls with the current r/g/b/peakAlpha -
-- shared by SetFadeColor and SetPeakAlpha so each only has to update the
-- one field it owns before calling this.
function BTVFadeStripMixin:ApplyFadeColors()
	local r, g, b, a = self.r, self.g, self.b, self.peakAlpha

	self.leftTex:SetGradientAlpha("HORIZONTAL", r, g, b, 0, r, g, b, a)
	self.midTex:SetVertexColor(r, g, b, a)
	self.rightTex:SetGradientAlpha("HORIZONTAL", r, g, b, a, r, g, b, 0)
end

function BTVFadeStripMixin:SetFadeColor(r, g, b)
	self.r, self.g, self.b = r, g, b
	self:ApplyFadeColors()
end

function BTVFadeStripMixin:SetPeakAlpha(a)
	self.peakAlpha = a
	self:ApplyFadeColors()
end

-------------------------------------------------------------------------
-- BTVListRowMixin
--
-- Generic reusable list-row widget: owns two BTVFadeStripMixin layers
-- (selectStrip, hoverStrip) instead of the border-and-tinted-backdrop
-- technique BTV:StyleModernButton uses - the "divided list, fading
-- highlight on hover/select" look from this client's native Options
-- window, rather than a dialog-style button. Shared by both the bar-list
-- sidebar (Settings.lua's CreateBarListRow) and the settings search
-- results list - one widget, two call sites, per the UI-redesign plan.
--
-- States: rest / hover / selected / selected+hover / disabled. Both
-- strips can be shown at once (selected + hovered layers the neutral
-- hoverStrip on top of the gold selectStrip) - this naturally covers the
-- old "selected+hover" 4th color without hand-picking one. Disabled
-- always wins - a disabled row never shows either strip (even if it was
-- selected before becoming disabled, e.g. bar5's row losing its
-- dependency lock's grey-out) and blocks the onClick callback.
-------------------------------------------------------------------------

BTVListRowMixin = {}

-- parent: frame to anchor into. name: optional - unlike
-- BTVInlineDropdownMixin's UIDropDownMenuTemplate wrapper, this widget has
-- no native FrameXML machinery that depends on a real GetName().
function BTV:CreateListRow(parent, name)
	local row = CreateFrame("Button", name, parent)

	-- Captured BEFORE Mixin below overwrites row.SetWidth with
	-- BTVListRowMixin's own override - same capture-then-wrap technique
	-- BTV:StyleModernButton uses for Enable/Disable. This lets the row's
	-- own SetWidth (called by every caller today, e.g. CreateBarListRow's
	-- row:SetWidth(110)) keep the fade strips in sync with the row's size
	-- "for free", without every call site needing to remember to also call
	-- SetVisualWidth. (Capturing this AFTER Mixin, as an earlier version of
	-- this function did, captured the mixin's own SetWidth instead of the
	-- native one - an infinite self-recursion the moment SetWidth was
	-- called, live-tested and confirmed as a stack overflow opening
	-- Settings.)
	row.nativeSetWidth = row.SetWidth
	row.nativeSetHeight = row.SetHeight

	Mixin(row, BTVListRowMixin)

	row:OnLoad()

	return row
end

function BTVListRowMixin:OnLoad()
	self.isSelected = false
	self.isDisabled = false
	self.isHovering = false
	self.onClick = nil

	local width, height = self:GetWidth(), self:GetHeight()

	self.selectStrip = BTV:CreateFadeStrip(self, width, height)
	self.selectStrip:SetPoint("LEFT", self, "LEFT", 0, 0)
	self.selectStrip:SetFadeColor(BTV.UI_ACCENT_COLOR[1], BTV.UI_ACCENT_COLOR[2], BTV.UI_ACCENT_COLOR[3])
	self.selectStrip:SetPeakAlpha(0.35)
	self.selectStrip:Hide()

	-- Created (and therefore drawn) after selectStrip, so it layers on top
	-- of it when both are shown at once - no explicit frame level needed,
	-- sibling frames created later draw above earlier siblings by default.
	self.hoverStrip = BTV:CreateFadeStrip(self, width, height)
	self.hoverStrip:SetPoint("LEFT", self, "LEFT", 0, 0)
	self.hoverStrip:SetFadeColor(BTV.UI_HOVER_COLOR[1], BTV.UI_HOVER_COLOR[2], BTV.UI_HOVER_COLOR[3])
	self.hoverStrip:SetPeakAlpha(0.25)
	self.hoverStrip:Hide()

	self.label = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.label:SetPoint("LEFT", self, "LEFT", 8, 0)
	self.label:SetJustifyH("LEFT")

	self:SetScript("OnEnter", function()
		this:OnRowEnter()
	end)

	self:SetScript("OnLeave", function()
		this:OnRowLeave()
	end)

	self:SetScript("OnClick", function()
		if (not this.isDisabled) and this.onClick then
			this.onClick(this)
		end
	end)

	self:UpdateVisualState()
end

function BTVListRowMixin:SetLabel(text)
	self.label:SetText(text or "")
end

function BTVListRowMixin:SetOnClick(onClick)
	self.onClick = onClick
end

function BTVListRowMixin:SetSelected(selected)
	self.isSelected = selected and true or false
	self:UpdateVisualState()
end

function BTVListRowMixin:IsRowSelected()
	return self.isSelected
end

-- Disabled overrides hover/selected visuals entirely (matches the existing
-- LockControl/dim convention used elsewhere in Settings.lua, e.g. bar5's
-- dependency lock) and blocks the onClick callback above - mouse events
-- still reach OnEnter/OnLeave (kept enabled) so a disabled row can still
-- show a tooltip explaining why it's locked, if a caller wants one.
function BTVListRowMixin:SetDisabled(disabled)
	self.isDisabled = disabled and true or false
	self:UpdateVisualState()
end

-- Resizes/repositions only the two fade strips, NOT the row's own click
-- hit-box (self:SetWidth) - lets the visual highlight extend across a
-- sibling inline checkbox (Settings.lua's CreateBarListRow), or align to
-- a container box wider than the row itself (e.g. the bar-list sidebar's
-- own bordered panel), without changing what area the row itself actually
-- responds to clicks/hover on. Works because WoW doesn't clip a child
-- texture to its parent frame's own bounds. offsetX (default 0) shifts
-- BOTH strips' own LEFT anchor relative to the row - lets a caller align
-- the highlight to a box that doesn't start flush with the row's own left
-- edge (e.g. a panel with its own left inset/padding).
function BTVListRowMixin:SetVisualWidth(width, offsetX)
	offsetX = offsetX or 0

	self.selectStrip:ClearAllPoints()
	self.selectStrip:SetPoint("LEFT", self, "LEFT", offsetX, 0)
	self.selectStrip:SetStripWidth(width)

	self.hoverStrip:ClearAllPoints()
	self.hoverStrip:SetPoint("LEFT", self, "LEFT", offsetX, 0)
	self.hoverStrip:SetStripWidth(width)
end

-- Overrides the native Button:SetWidth (captured as self.nativeSetWidth in
-- BTV:CreateListRow before this shadows it) so the common case - a row
-- with no inline checkbox, or the initial row:SetWidth(110) before a
-- checkbox is added - keeps its strips sized to match without the caller
-- having to also call SetVisualWidth. A later explicit SetVisualWidth
-- call (e.g. once a checkbox exists) simply overrides this again.
function BTVListRowMixin:SetWidth(width)
	self.nativeSetWidth(self, width)

	if self.selectStrip then
		self.selectStrip:SetStripWidth(width)
		self.hoverStrip:SetStripWidth(width)
	end
end

-- Same reasoning/technique as SetWidth above, for height - without this,
-- the strips stay stuck at whatever height OnLoad captured them at
-- (typically 0, since OnLoad runs inside BTV:CreateListRow BEFORE the
-- caller ever calls row:SetHeight(...)), rendering both strips at 0px
-- tall - invisible regardless of Show()/Hide() state. This was the root
-- cause of the bar-list sidebar showing no hover/select feedback at all
-- after the fade-strip rework, live-tested and confirmed.
function BTVListRowMixin:SetHeight(height)
	self.nativeSetHeight(self, height)

	if self.selectStrip then
		self.selectStrip:SetStripHeight(height)
		self.hoverStrip:SetStripHeight(height)
	end
end

-- Factored out of the row's own OnEnter/OnLeave scripts (see OnLoad) so
-- another frame - e.g. a sibling inline checkbox that wants to share this
-- row's hover fade - can invoke the exact same logic without needing
-- `this` to be the row itself.
function BTVListRowMixin:OnRowEnter()
	self.isHovering = true
	self:UpdateVisualState()
end

function BTVListRowMixin:OnRowLeave()
	self.isHovering = false
	self:UpdateVisualState()
end

function BTVListRowMixin:UpdateVisualState()
	if self.isDisabled then
		self.selectStrip:Hide()
		self.hoverStrip:Hide()
		self.label:SetTextColor(0.5, 0.5, 0.5)
		return
	end

	self.label:SetTextColor(1, 1, 1)

	if self.isSelected then
		self.selectStrip:Show()
	else
		self.selectStrip:Hide()
	end

	if self.isHovering then
		self.hoverStrip:Show()
	else
		self.hoverStrip:Hide()
	end
end
