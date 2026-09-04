-- UIWidgets.lua
-- Reusable Mixin-based dialog/dropdown widget kit, built on ClassicAPI's
-- Mixin/CreateFromMixins primitives.
--
-- Engine-invoked script handlers (OnClick, OnShow, OnHide) receive the
-- frame via the global `this`, never as a `self` parameter.

local BTV = BTVanilla

-- Shared accent/hover colors for the fade-strip treatment below.
BTV.UI_ACCENT_COLOR = { 1, 0.82, 0 }
BTV.UI_HOVER_COLOR = { 1, 1, 1 }

-------------------------------------------------------------------------
-- BTVInlineDropdownMixin
--
-- Wraps the native UIDropDownMenuTemplate as a persistent in-panel
-- selector instead of a transient right-click popup.
-------------------------------------------------------------------------

BTVInlineDropdownMixin = {}

-- parent: frame to anchor into. name: REQUIRED - UIDropDownMenuTemplate's
-- native FrameXML machinery builds internal sub-widget references by
-- string-concatenating this frame's own GetName() (UIDropDownMenu_
-- Initialize/SetWidth/etc.); a nameless dropdown fails with "attempt to
-- concatenate a nil value".
-- Returns the created dropdown frame with this mixin applied.
function BTV:CreateInlineDropdown(parent, widthPixels, name)
	local dropdown = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")

	-- CreateFrame only applies `parent` the first time a given global
	-- `name` is created - on reuse it keeps whatever parent it already
	-- had. Must SetParent explicitly here or a reused dropdown stays
	-- attached to an orphaned old frame and stops rendering reliably.
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

	-- Re-applied on OnShow too: a dropdown built while its page is still
	-- hidden can end up with fragmented skin pieces and a stale/blank
	-- label otherwise.
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

			-- option is either a plain string, or a { text =, value = }
			-- table when the stored value isn't a sensible display label.
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

-- options: array of strings, or { text = "...", value = ... } tables when
-- the value isn't itself a usable label.
function BTVInlineDropdownMixin:SetOptions(options)
	self.options = options or {}
end

-- displayText is optional - when omitted, `value` itself is shown (plain-
-- string options) or looked up from a matching { text=, value= } entry.
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

	-- Cached so OnShow can reapply the label after this frame becomes visible.
	self.selectedDisplayText = displayText or value

	UIDropDownMenu_SetText(self.selectedDisplayText, self)
end

function BTVInlineDropdownMixin:GetSelected()
	return self.selected
end

-------------------------------------------------------------------------
-- Modern button styling
--
-- Backdrop-based button styling (not UIPanelButtonTemplate) that scales
-- cleanly to arbitrary widths.
-------------------------------------------------------------------------

-- Turns a plain, template-less Button frame into a modern-styled one.
-- Caller still creates the frame and sets its own SetHeight/OnClick/etc
-- as normal - this applies the visuals and installs a :SetText that
-- resizes the button to fit its label (BTV_BUTTON_PADDING_X either side),
-- clamped to [minWidth, maxWidth]. Pass 0/math.huge (or omit) for no
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

	-- Overrides the native Button:SetText - a template-less Button has no
	-- font region wired to it by default.
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

	-- Dims backdrop/text to match native Disable/Enable's grey-out, since
	-- this button has no UIPanelButtonTemplate texture to grey out itself.
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
-- One reusable dialog frame covering:
--   mode = "confirm"   - title/message + buttons only
--   mode = "textinput" - adds an EditBox (InputBoxTemplate)
--   mode = "dropdown"  - adds a BTVInlineDropdownMixin from config.options
--
-- A single frame instance is created lazily (BTV.activeDialog) and
-- reconfigured on every BTV:ShowDialog call rather than rebuilt. Only one
-- dialog is ever open at a time.
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
	-- FULLSCREEN_DIALOG: renders above Settings.lua's DIALOG-strata window.
	self:SetFrameStrata("FULLSCREEN_DIALOG")
	self:SetWidth(DIALOG_WIDTH)
	self:SetHeight(160)
	self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

	-- Matches CreateSettingsFrame's own backdrop (Settings.lua).
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

	-- InputBoxTemplate: standard vanilla FrameXML EditBox. Created hidden;
	-- shown only for mode == "textinput".
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

	-- Up to 4 buttons - the first-login dialog needs 3 plus a conditional
	-- 4th ("use existing profile").
	self.buttons = {}

	local i

	for i = 1, 4 do
		local button = CreateFrame("Button", nil, self)

		button:SetHeight(DIALOG_BUTTON_HEIGHT)

		-- minWidth avoids short labels looking like a tiny nub; maxWidth
		-- matches the dialog's usable text width.
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

	-- Buttons wrap into as many centered rows as needed, each row centered
	-- on the dialog's own horizontal center.
	local BUTTON_GAP_X = 12
	local BUTTON_ROW_GAP_Y = 8
	local availableWidth = DIALOG_WIDTH - 40

	local i
	local count = table.getn(self.buttonConfigs)
	self.defaultButtonIndex = nil

	-- Pass 1: configure each visible button so its content-fit width
	-- (BTV:StyleModernButton's SetText override) is known before
	-- row-packing below.
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
	-- array of button indices, rowWidths[r] that row's total width.
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

	-- Each row is anchored off self's own TOP with a precomputed offset,
	-- independent of vertical stacking order.
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
-- via :Click().
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

-- Named Display, not Show - Mixin() copies this directly onto the frame's
-- table, which would shadow the native :Show() and make it unreachable if
-- this were named Show.
function BTVDialogMixin:Display()
	self:Show()

	if self.mode == "textinput" then
		self.editBox:SetFocus()
	end
end

-- The one entry point every caller uses for every dialog need. Reuses the
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
-- Horizontal transparent -> solid -> transparent highlight strip, split
-- 10%/80%/10% across its width. SetGradientAlpha only interpolates
-- between 2 stops, so the flat middle section is a separate solid
-- texture rather than part of one wider gradient - 3 stacked textures.
-------------------------------------------------------------------------

BTVFadeStripMixin = {}

-- parent: frame to anchor into. width/height: the strip's initial pixel
-- size (see :SetStripWidth to resize later without recreating textures).
function BTV:CreateFadeStrip(parent, width, height)
	local strip = CreateFrame("Frame", nil, parent)

	Mixin(strip, BTVFadeStripMixin)

	-- Pure visual overlay - must not intercept mouse events meant for the
	-- frame it decorates.
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

-- Resizes just the height - SetStripWidth recomputes height from
-- self:GetHeight() too, but nothing re-runs it when only the strip's
-- height changes.
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
-- Generic list-row widget: owns two BTVFadeStripMixin layers (selectStrip,
-- hoverStrip) for a divided-list fading highlight look.
--
-- States: rest / hover / selected / selected+hover / disabled. Both
-- strips can be shown at once (hoverStrip layers on top of selectStrip).
-- Disabled always wins - never shows either strip and blocks onClick.
-------------------------------------------------------------------------

BTVListRowMixin = {}

-- parent: frame to anchor into. name: optional.
function BTV:CreateListRow(parent, name)
	local row = CreateFrame("Button", name, parent)

	-- Must capture BEFORE Mixin below overwrites row.SetWidth/SetHeight
	-- with BTVListRowMixin's own overrides - capturing after Mixin grabs
	-- the mixin's own override instead of the native method, causing
	-- infinite recursion the moment SetWidth/SetHeight is called.
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

	-- Created after selectStrip so it draws on top when both are shown.
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

-- Disabled overrides hover/selected visuals and blocks onClick; OnEnter/
-- OnLeave still fire so a disabled row can still show a tooltip.
function BTVListRowMixin:SetDisabled(disabled)
	self.isDisabled = disabled and true or false
	self:UpdateVisualState()
end

-- Resizes/repositions only the fade strips, not the row's own hit-box -
-- lets the highlight extend across a sibling checkbox or align to a wider
-- container without changing what area responds to clicks. offsetX
-- shifts both strips' LEFT anchor relative to the row.
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
-- BTV:CreateListRow) so a row with no inline checkbox keeps its strips
-- sized to match without a separate SetVisualWidth call.
function BTVListRowMixin:SetWidth(width)
	self.nativeSetWidth(self, width)

	if self.selectStrip then
		self.selectStrip:SetStripWidth(width)
		self.hoverStrip:SetStripWidth(width)
	end
end

-- Same technique as SetWidth, for height - without this the strips stay
-- stuck at whatever height OnLoad captured (typically 0, since OnLoad
-- runs before the caller ever calls SetHeight), rendering invisible.
function BTVListRowMixin:SetHeight(height)
	self.nativeSetHeight(self, height)

	if self.selectStrip then
		self.selectStrip:SetStripHeight(height)
		self.hoverStrip:SetStripHeight(height)
	end
end

-- Factored out of OnEnter/OnLeave (see OnLoad) so another frame - e.g. a
-- sibling checkbox sharing this row's hover fade - can call it directly
-- without needing `this` to be the row itself.
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
