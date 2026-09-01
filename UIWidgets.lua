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

	Mixin(dropdown, BTVInlineDropdownMixin)
	dropdown:OnLoad(widthPixels)

	return dropdown
end

function BTVInlineDropdownMixin:OnLoad(widthPixels)
	self.options = {}
	self.selected = nil
	self.onSelect = nil

	UIDropDownMenu_SetWidth(widthPixels or 160, self)

	local dropdown = self

	UIDropDownMenu_Initialize(self, function()
		local info = {}
		local i

		for i = 1, table.getn(dropdown.options) do
			local optionValue = dropdown.options[i]

			info = {}
			info.text = optionValue
			info.notCheckable = true
			info.func = function()
				dropdown:SetSelected(optionValue)

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
-- appended by Settings.lua where relevant).
function BTVInlineDropdownMixin:SetOptions(options)
	self.options = options or {}
end

function BTVInlineDropdownMixin:SetSelected(value)
	self.selected = value
	UIDropDownMenu_SetText(value, self)
end

function BTVInlineDropdownMixin:GetSelected()
	return self.selected
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
local DIALOG_BUTTON_WIDTH = 140

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
		local button = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")

		button:SetWidth(DIALOG_BUTTON_WIDTH)
		button:SetHeight(DIALOG_BUTTON_HEIGHT)
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

	local contentBottom = self.messageText

	if self.mode == "textinput" then
		self.editBox:SetPoint("TOP", self.messageText, "BOTTOM", 0, -14)
		self.editBox:SetText(config.defaultText or "")
		self.editBox:HighlightText()
		self.editBox:Show()
		contentBottom = self.editBox
	elseif self.mode == "dropdown" then
		self.dropdown:ClearAllPoints()
		self.dropdown:SetPoint("TOP", self.messageText, "BOTTOM", 0, -10)
		self.dropdown:SetOptions(config.options or {})
		self.dropdown:SetSelected((config.options or {})[1])
		self.dropdown:Show()
		contentBottom = self.dropdown
	end

	-- Buttons stack vertically, one per row, rather than side by side - the
	-- spec's own button labels ("I know what im doing, use default
	-- profile") are long, and the first-login dialog needs up to 4 of
	-- them, so a horizontal row either overflows the dialog or forces
	-- unreadable truncation. Each row is full-width.
	local i
	local count = table.getn(self.buttonConfigs)
	self.defaultButtonIndex = nil

	for i = 1, 4 do
		local button = self.buttons[i]
		local buttonConfig = self.buttonConfigs[i]

		if buttonConfig then
			-- First button gets a bigger gap below the message/input
			-- content; every button after that sits a small fixed gap
			-- below the PREVIOUS button (contentBottom is reassigned to
			-- the just-shown button at the end of each iteration).
			local gap = (i == 1) and -14 or -8

			button:SetWidth(DIALOG_WIDTH - 40)
			button:SetText(buttonConfig.text or "")
			button:ClearAllPoints()
			button:SetPoint("TOP", contentBottom, "BOTTOM", 0, gap)

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

			contentBottom = button
		else
			button:Hide()
		end
	end

	if not self.defaultButtonIndex and count > 0 then
		self.defaultButtonIndex = 1
	end

	-- Content-aware sizing: measures the ACTUAL height every element ends
	-- up taking (title/message auto-wrap to their real GetHeight() at the
	-- fixed width set in OnLoad) and adds up the exact same gaps used to
	-- anchor them above, rather than guessing a fixed formula - so the
	-- dialog always fits whatever title/message/mode content/button count
	-- a given config actually throws at it. Mirrors the anchor chain
	-- above: TOP_OFFSET (title's own offset from self's TOP, set in
	-- OnLoad) -> title -> 10px gap -> message -> mode content (if any) ->
	-- buttons (first gap 14, then 8 each) -> BOTTOM_PADDING.
	local TOP_OFFSET = 18
	local BOTTOM_PADDING = 20

	local height = TOP_OFFSET
	height = height + (self.titleText:GetHeight() or 0)
	height = height + 10 + (self.messageText:GetHeight() or 0)

	if self.mode == "textinput" then
		height = height + 14 + (self.editBox:GetHeight() or 0)
	elseif self.mode == "dropdown" then
		height = height + 10 + (self.dropdown:GetHeight() or 0)
	end

	for i = 1, count do
		local gap = (i == 1) and 14 or 8

		height = height + gap + DIALOG_BUTTON_HEIGHT
	end

	self:SetHeight(height + BOTTOM_PADDING)
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
