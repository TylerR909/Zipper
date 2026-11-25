local _, ns = ...
local L = ns.L

ns.Config = {}

-- Minutes of trail shown on the map while glancing. 0 is the whole history.
ns.Config.GLANCE_STOPS = { 5, 10, 15, 20, 30, 45, 60, 0 }

local TRACK_DEFAULTS = { path = true }
local KIND_KEY = {}
local TRACKS = {}
local ROAD = {
	{ key = "path", label = L["Movement"], order = 1 },
}
local MOMENTS = {}

do
	local seen = {}
	for kind, spec in pairs(ns.EventSpec or {}) do
		local key = (spec.config and spec.config.key) or spec.configKey
		if key then
			KIND_KEY[kind] = key
			TRACK_DEFAULTS[key] = true
		end
		if spec.config and spec.config.key and not seen[spec.config.key] then
			seen[spec.config.key] = true
			local entry = {
				key = spec.config.key,
				label = spec.config.label or spec.name,
				order = spec.config.order or 999,
				kind = kind,
			}
			TRACKS[#TRACKS + 1] = entry
			if spec.config.page == "road" then
				ROAD[#ROAD + 1] = entry
			elseif spec.config.page == "moments" then
				MOMENTS[#MOMENTS + 1] = entry
			end
		end
	end
	local function byOrder(a, b)
		if (a.order or 999) ~= (b.order or 999) then
			return (a.order or 999) < (b.order or 999)
		end
		return (a.kind or 0) < (b.kind or 0)
	end
	table.sort(ROAD, byOrder)
	table.sort(MOMENTS, byOrder)
end

function ns.Config:ClampMinutes(value)
	value = math.floor((tonumber(value) or 60) + 0.5)
	if value < 30 then
		value = 30
	elseif value > 180 then
		value = 180
	end
	local steps = math.floor((value + 7.5) / 15)
	value = steps * 15
	if value < 30 then
		value = 30
	elseif value > 180 then
		value = 180
	end
	return value
end

function ns.Config:IntervalLabel(minutes)
	minutes = self:ClampMinutes(minutes)
	if minutes == 60 then
		return L["1 hour"]
	end
	if minutes % 60 == 0 then
		return string.format(L["%d hours"], minutes / 60)
	end
	if minutes > 60 then
		return string.format(L["%d hr %d min"], math.floor(minutes / 60), minutes % 60)
	end
	return string.format(L["%d min"], minutes)
end

function ns.Config:ReminderText()
	local minutes = self:Get().remindMinutes
	local span
	if minutes == 60 then
		span = L["an hour"]
	elseif minutes % 60 == 0 then
		span = string.format(L["%d hours"], minutes / 60)
	else
		span = string.format(L["%d minutes"], minutes)
	end
	return string.format(L["Zipper has accumulated %s of data which can be lost. Suggest `/reload` to save it forever."], span)
end

function ns.Config:Get()
	ZipperDB = ZipperDB or {}
	local cfg = ZipperDB.config
	if type(cfg) ~= "table" then
		cfg = {}
		ZipperDB.config = cfg
	end
	if cfg.remind == nil then
		cfg.remind = true
	end
	cfg.remindMinutes = self:ClampMinutes(cfg.remindMinutes or 60)
	if cfg.showMarkers == nil then
		cfg.showMarkers = true
	end
	if cfg.ghostRed == nil then
		cfg.ghostRed = false
	end
	if cfg.milestoneSummaries == nil then
		cfg.milestoneSummaries = true
	end
	if cfg.skipQuiet == nil then
		cfg.skipQuiet = true
	end
	if cfg.glanceTrail == nil then
		cfg.glanceTrail = 30
	end
	if type(cfg.track) ~= "table" then
		cfg.track = {}
	end
	for key, value in pairs(TRACK_DEFAULTS) do
		if cfg.track[key] == nil then
			cfg.track[key] = value
		end
	end
	return cfg
end

function ns.Config:Enabled(key)
	local track = self:Get().track
	if track[key] == nil then
		return true
	end
	return track[key] and true or false
end

function ns.Config:WantsKind(kind)
	local key = KIND_KEY[kind]
	if not key then
		return true
	end
	return self:Enabled(key)
end

function ns.Config:ShowMarkers()
	return self:Get().showMarkers and true or false
end

function ns.Config:GlanceTrail()
	local minutes = self:Get().glanceTrail
	if minutes == nil then
		return 30
	end
	return minutes
end

function ns.Config:GlanceIndex(minutes)
	local stops = self.GLANCE_STOPS
	for i = 1, #stops do
		if stops[i] == minutes then
			return i
		end
	end
	return 5
end

function ns.Config:GlanceLabel(minutes)
	if not minutes or minutes <= 0 then
		return L["Full"]
	end
	return string.format(L["%d min"], minutes)
end

function ns.Config:SetGlanceTrail(minutes)
	self:Get().glanceTrail = minutes or 0
	if self.glanceText then
		self.glanceText:SetText(self:GlanceLabel(minutes))
	end
	local replay = ns.Replay
	if replay and replay.route and not (replay.UsingReplayTrail and replay:UsingReplayTrail()) then
		replay:Redraw()
	end
end

function ns.Config:ApplyReminder()
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end
	if not self.reminderArmed then
		return
	end
	local cfg = self:Get()
	if not cfg.remind then
		return
	end
	self.ticker = C_Timer.NewTicker(cfg.remindMinutes * 60, function()
		ns:Print(ns.Config:ReminderText())
	end)
end

function ns.Config:StartReminder()
	self.reminderArmed = true
	self:ApplyReminder()
end

function ns.Config:SetRemind(on)
	self:Get().remind = on and true or false
	self:ApplyReminder()
	self:RefreshSlider()
end

function ns.Config:SetMinutes(minutes)
	local cfg = self:Get()
	minutes = self:ClampMinutes(minutes)
	if cfg.remindMinutes == minutes then
		return
	end
	cfg.remindMinutes = minutes
	if cfg.remind then
		self:ApplyReminder()
	end
end

function ns.Config:SetTrack(key, on)
	local cfg = self:Get()
	if cfg.track[key] == nil and key ~= "path" then
		return
	end
	cfg.track[key] = on and true or false
	if key == "party" and ns.Social and ns.Social.active then
		if cfg.track.party then
			ns.Social:Schedule()
		else
			ns.Social:Disable()
		end
	end
end

function ns.Config:GhostRed()
	return self:Get().ghostRed and true or false
end

function ns.Config:MilestoneSummaries()
	return self:Get().milestoneSummaries and true or false
end

function ns.Config:SkipQuiet()
	return self:Get().skipQuiet and true or false
end

function ns.Config:SetSkipQuiet(on)
	self:Get().skipQuiet = on and true or false
end

function ns.Config:SetGhostRed(on)
	self:Get().ghostRed = on and true or false
	if ns.Replay and ns.Replay.route then
		ns.Replay:Redraw()
	end
end

function ns.Config:SetMilestoneSummaries(on)
	self:Get().milestoneSummaries = on and true or false
end

function ns.Config:SetShowMarkers(on)
	self:Get().showMarkers = on and true or false
	if ns.Replay and ns.Replay.Redraw then
		ns.Replay:Redraw()
	end
end

function ns.Config:RefreshSlider()
	local slider = self.slider
	local valueText = self.sliderText
	if not slider then
		return
	end
	local cfg = self:Get()
	self.lock = true
	slider:SetValue(cfg.remindMinutes)
	self.lock = false
	if valueText then
		valueText:SetText(self:IntervalLabel(cfg.remindMinutes))
	end
	if cfg.remind then
		slider:Enable()
		if valueText then
			valueText:SetTextColor(1, 0.82, 0)
		end
	else
		slider:Disable()
		if valueText then
			valueText:SetTextColor(0.5, 0.5, 0.5)
		end
	end
end

local function CheckText(box)
	if box.Text then
		return box.Text
	end
	local name = box:GetName()
	if name then
		return _G[name .. "Text"]
	end
end

local PAGES = {
	{ key = "general", label = L["General"] },
	{ key = "road", label = L["The road"] },
	{ key = "moments", label = L["Moments"] },
	{ key = "saved", label = L["Saved data"] },
}

local function AddCheck(parent, name, label)
	local box = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	local text = CheckText(box)
	if text then
		text:SetText(label)
	end
	return box
end

local function HideSliderLabels(slider)
	for _, key in ipairs({ "Low", "High", "Text" }) do
		local label = slider[key] or _G[slider:GetName() .. key]
		if label then
			label:Hide()
		end
	end
end

local function PageFrame(parent)
	local page = CreateFrame("Frame", nil, parent)
	page:SetAllPoints()
	page:Hide()
	return page
end

local function PageNote(parent, text)
	local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 16, -16)
	note:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
	note:SetJustifyH("LEFT")
	note:SetText(text)
	return note
end

function ns.Config:ShowPage(key)
	self.page = key
	if self.pages then
		for name, page in pairs(self.pages) do
			page:SetShown(name == key)
		end
	end
	if self.navButtons then
		for i = 1, #self.navButtons do
			local button = self.navButtons[i]
			local selected = button.pageKey == key
			button.bar:SetShown(selected)
			if selected then
				button.label:SetTextColor(1, 1, 1)
			else
				button.label:SetTextColor(1, 0.82, 0)
			end
		end
	end
	if self.purgeList and key ~= "saved" then
		self.purgeList:Hide()
	end
end

function ns.Config:CreateFrame()
	if self.frame then
		return
	end
	-- Same registration Forever Quest Tint uses. The name is what the AddOns list shows.
	local canvas = CreateFrame("Frame")
	canvas.name = "Zipper"

	local nav = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
	nav:SetPoint("TOPLEFT", 8, -8)
	nav:SetPoint("BOTTOMLEFT", 8, 8)
	nav:SetWidth(168)
	nav:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	nav:SetBackdropColor(0, 0, 0, 0.35)
	nav:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)

	local body = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
	body:SetPoint("TOPLEFT", nav, "TOPRIGHT", 8, 0)
	body:SetPoint("BOTTOMRIGHT", -8, 8)
	body:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	body:SetBackdropColor(0, 0, 0, 0.2)
	body:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)

	local pages = {}
	local navButtons = {}
	for i = 1, #PAGES do
		local entry = PAGES[i]
		local button = CreateFrame("Button", nil, nav)
		button:SetHeight(26)
		button:SetPoint("TOPLEFT", 6, -8 - ((i - 1) * 26))
		button:SetPoint("RIGHT", nav, "RIGHT", -6, 0)
		button.pageKey = entry.key
		button.bar = button:CreateTexture(nil, "BACKGROUND")
		button.bar:SetAllPoints()
		button.bar:SetColorTexture(0.18, 0.40, 0.72, 0.9)
		button.bar:Hide()
		button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		button.label:SetPoint("LEFT", 10, 0)
		button.label:SetText(entry.label)
		button:SetScript("OnClick", function(self)
			ns.Config:ShowPage(self.pageKey)
		end)
		navButtons[i] = button
		pages[entry.key] = PageFrame(body)
	end

	local general = pages.general
	local remind = AddCheck(general, "ZipperConfigRemind", L["Remind me to /reload"])
	remind:SetPoint("TOPLEFT", 12, -16)
	remind:SetScript("OnClick", function(self)
		ns.Config:SetRemind(self:GetChecked())
	end)

	local remindLabel = general:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	remindLabel:SetPoint("TOPLEFT", 20, -52)
	remindLabel:SetText(L["How often"])

	local slider = CreateFrame("Slider", "ZipperConfigRemindSlider", general, "UISliderTemplate")
	slider:SetPoint("TOPLEFT", 28, -76)
	slider:SetSize(220, 16)
	slider:SetMinMaxValues(30, 180)
	slider:SetValueStep(15)
	slider:SetObeyStepOnDrag(true)
	HideSliderLabels(slider)
	slider:SetScript("OnValueChanged", function(_, value)
		if ns.Config.lock then
			return
		end
		local minutes = ns.Config:ClampMinutes(value)
		ns.Config:SetMinutes(minutes)
		if ns.Config.sliderText then
			ns.Config.sliderText:SetText(ns.Config:IntervalLabel(minutes))
		end
	end)

	local valueText = general:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	valueText:SetPoint("LEFT", slider, "RIGHT", 16, 0)
	valueText:SetText(L["1 hour"])

	local glanceLabel = general:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	glanceLabel:SetPoint("TOPLEFT", 16, -112)
	glanceLabel:SetText(L["Trail on the map"])

	local glanceText = general:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	glanceText:SetPoint("LEFT", glanceLabel, "RIGHT", 10, 0)
	glanceText:SetText(ns.Config:GlanceLabel(ns.Config:GlanceTrail()))

	local glance = CreateFrame("Slider", "ZipperConfigGlanceSlider", general, "UISliderTemplate")
	glance:SetPoint("TOPLEFT", 28, -140)
	glance:SetSize(220, 16)
	glance:SetMinMaxValues(1, #ns.Config.GLANCE_STOPS)
	glance:SetValueStep(1)
	glance:SetObeyStepOnDrag(true)
	HideSliderLabels(glance)
	glance:SetScript("OnValueChanged", function(slider, value)
		if ns.Config.lock then
			return
		end
		local index = math.floor(value + 0.5)
		if index < 1 then
			index = 1
		elseif index > #ns.Config.GLANCE_STOPS then
			index = #ns.Config.GLANCE_STOPS
		end
		if math.abs(slider:GetValue() - index) > 0.01 then
			ns.Config.lock = true
			slider:SetValue(index)
			ns.Config.lock = false
		end
		ns.Config:SetGlanceTrail(ns.Config.GLANCE_STOPS[index])
	end)

	local glanceHint = general:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	glanceHint:SetPoint("TOPLEFT", 28, -162)
	glanceHint:SetPoint("RIGHT", general, "RIGHT", -16, 0)
	glanceHint:SetJustifyH("LEFT")
	glanceHint:SetText(L["Solid back to this point, then a short fade. The replay panel has its own slider."])

	local markers = AddCheck(general, "ZipperConfigMarkers", L["Show event markers on the map"])
	markers:SetPoint("TOPLEFT", 12, -196)
	markers:SetScript("OnClick", function(self)
		ns.Config:SetShowMarkers(self:GetChecked())
	end)

	local ghostRed = AddCheck(general, "ZipperConfigGhostRed", L["Red ghost trail"])
	ghostRed:SetPoint("TOPLEFT", 12, -228)
	ghostRed:SetScript("OnClick", function(self)
		ns.Config:SetGhostRed(self:GetChecked())
	end)

	local milestones = AddCheck(general, "ZipperConfigMilestones", L["Milestone Summaries"])
	milestones:SetPoint("TOPLEFT", 12, -260)
	milestones:SetScript("OnClick", function(self)
		ns.Config:SetMilestoneSummaries(self:GetChecked())
	end)

	local boxes = { remind = remind, showMarkers = markers, ghostRed = ghostRed, milestoneSummaries = milestones }
	local roadNote = PageNote(pages.road, L["Unchecking a type stops new records of it. Saved history stays."])
	for i = 1, #ROAD do
		local entry = ROAD[i]
		local box = AddCheck(pages.road, "ZipperConfig" .. entry.key, entry.label)
		box:SetPoint("TOPLEFT", 12, -36 - ((i - 1) * 28))
		box.trackKey = entry.key
		box:SetScript("OnClick", function(self)
			ns.Config:SetTrack(self.trackKey, self:GetChecked())
		end)
		boxes[entry.key] = box
	end
	roadNote:SetShown(true)

	PageNote(pages.moments, L["Unchecking a type stops new records of it. Saved history stays."])
	for i = 1, #MOMENTS do
		local entry = MOMENTS[i]
		local column = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		local box = AddCheck(pages.moments, "ZipperConfig" .. entry.key, entry.label)
		box:SetPoint("TOPLEFT", 12 + (column * 230), -36 - (row * 28))
		box.trackKey = entry.key
		box:SetScript("OnClick", function(self)
			ns.Config:SetTrack(self.trackKey, self:GetChecked())
		end)
		boxes[entry.key] = box
	end

	local sizeText = pages.saved:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sizeText:SetPoint("TOPLEFT", 16, -20)
	sizeText:SetPoint("RIGHT", pages.saved, "RIGHT", -16, 0)
	sizeText:SetJustifyH("LEFT")
	sizeText:SetJustifyV("TOP")
	sizeText:SetText(L["Saved journeys"])

	local isoNote = pages.saved:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	isoNote:SetPoint("TOPLEFT", sizeText, "BOTTOMLEFT", 0, -10)
	isoNote:SetPoint("RIGHT", pages.saved, "RIGHT", -16, 0)
	isoNote:SetJustifyH("LEFT")
	isoNote:SetText(L["Pick Global or Non-Global for each character. Non-Global keeps that journey in a per-character save so other characters load less, but they cannot replay it until you make it Global again."])

	-- Column widths match RefreshIsolationList: name | size | Global | Non-Global
	local ISO_SIZE_W, ISO_GLOBAL_W, ISO_PRIVATE_W = 72, 70, 90
	local isoHeader = CreateFrame("Frame", nil, pages.saved)
	isoHeader:SetPoint("TOPLEFT", isoNote, "BOTTOMLEFT", 0, -12)
	isoHeader:SetPoint("RIGHT", pages.saved, "RIGHT", -36, 0)
	isoHeader:SetHeight(16)
	local isoNameHead = isoHeader:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	isoNameHead:SetPoint("LEFT", 0, 0)
	isoNameHead:SetPoint("RIGHT", isoHeader, "RIGHT", -(ISO_SIZE_W + ISO_GLOBAL_W + ISO_PRIVATE_W), 0)
	isoNameHead:SetJustifyH("LEFT")
	isoNameHead:SetText(L["Character"])
	local isoSizeHead = isoHeader:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	isoSizeHead:SetPoint("RIGHT", isoHeader, "RIGHT", -(ISO_GLOBAL_W + ISO_PRIVATE_W), 0)
	isoSizeHead:SetWidth(ISO_SIZE_W)
	isoSizeHead:SetJustifyH("RIGHT")
	isoSizeHead:SetText(L["Size"])
	local isoGlobalHead = isoHeader:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	isoGlobalHead:SetPoint("RIGHT", isoHeader, "RIGHT", -ISO_PRIVATE_W, 0)
	isoGlobalHead:SetWidth(ISO_GLOBAL_W)
	isoGlobalHead:SetJustifyH("CENTER")
	isoGlobalHead:SetText(L["Global"])
	local isoPrivateHead = isoHeader:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	isoPrivateHead:SetPoint("RIGHT", 0, 0)
	isoPrivateHead:SetWidth(ISO_PRIVATE_W)
	isoPrivateHead:SetJustifyH("CENTER")
	isoPrivateHead:SetText(L["Non-Global"])

	-- Purge / quiet controls sit on a bottom footer so the character list can stretch.
	local savedFooter = CreateFrame("Frame", nil, pages.saved)
	savedFooter:SetPoint("BOTTOMLEFT", 16, 12)
	savedFooter:SetPoint("BOTTOMRIGHT", -16, 12)
	savedFooter:SetHeight(168)

	-- Same chrome RareScanner/AceGUI uses for "Warning sound for rare NPCs".
	local purgeWrap = CreateFrame("Frame", nil, savedFooter)
	purgeWrap:SetSize(280, 32)
	purgeWrap:SetPoint("TOPLEFT", 0, 0)
	local purgeDrop = CreateFrame("Frame", "ZipperConfigCharDrop", purgeWrap, "UIDropDownMenuTemplate")
	purgeDrop:ClearAllPoints()
	purgeDrop:SetPoint("TOPLEFT", purgeWrap, "TOPLEFT", -15, 0)
	purgeDrop:SetPoint("BOTTOMRIGHT", purgeWrap, "BOTTOMRIGHT", 17, 0)
	purgeDrop:SetScript("OnHide", nil)
	local purgeLeft = purgeDrop.Left or _G[purgeDrop:GetName() .. "Left"]
	local purgeMiddle = purgeDrop.Middle or _G[purgeDrop:GetName() .. "Middle"]
	local purgeRight = purgeDrop.Right or _G[purgeDrop:GetName() .. "Right"]
	local purgeText = purgeDrop.Text or _G[purgeDrop:GetName() .. "Text"]
	local purgeButton = purgeDrop.Button or _G[purgeDrop:GetName() .. "Button"]
	if purgeMiddle and purgeLeft and purgeRight then
		purgeMiddle:ClearAllPoints()
		purgeRight:ClearAllPoints()
		purgeMiddle:SetPoint("LEFT", purgeLeft, "RIGHT", 0, 0)
		purgeMiddle:SetPoint("RIGHT", purgeRight, "LEFT", 0, 0)
		purgeRight:SetPoint("TOPRIGHT", purgeDrop, "TOPRIGHT", 0, 17)
	end
	if purgeText and purgeLeft and purgeRight then
		purgeText:ClearAllPoints()
		purgeText:SetPoint("LEFT", purgeLeft, "LEFT", 25, 2)
		purgeText:SetPoint("RIGHT", purgeRight, "RIGHT", -43, 2)
		purgeText:SetJustifyH("LEFT")
		purgeText:SetWordWrap(false)
		if purgeText.SetNonSpaceWrap then
			purgeText:SetNonSpaceWrap(false)
		end
		purgeText:SetText(L["Saved characters"])
	end
	local function TogglePurgeMenu()
		ns.Config:TogglePurgeList()
		if PlaySound then
			PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
		end
	end
	if purgeButton then
		purgeButton:SetScript("OnClick", TogglePurgeMenu)
	end
	local purgeCover = CreateFrame("Button", nil, purgeWrap)
	purgeCover:SetPoint("TOPLEFT", 0, 0)
	purgeCover:SetPoint("BOTTOMRIGHT", 0, 0)
	purgeCover:SetScript("OnClick", TogglePurgeMenu)

	local purgeList = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	purgeList:SetPoint("TOPLEFT", purgeWrap, "BOTTOMLEFT", 0, 2)
	purgeList:SetPoint("TOPRIGHT", purgeWrap, "BOTTOMRIGHT", 0, 2)
	purgeList:SetFrameStrata("FULLSCREEN_DIALOG")
	purgeList:SetFrameLevel(20)
	purgeList:Hide()
	purgeList:EnableMouse(true)
	purgeList:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		tileSize = 32,
		tile = true,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	purgeList:SetBackdropColor(0, 0, 0, 1)

	local purge = CreateFrame("Button", "ZipperConfigPurge", savedFooter, "UIPanelButtonTemplate")
	purge:SetSize(80, 24)
	purge:SetPoint("LEFT", purgeWrap, "RIGHT", 8, 4)
	purge:SetText(L["Delete"])
	purge:SetScript("OnClick", function()
		ns.Config:ConfirmPurge()
	end)

	local quiet = AddCheck(savedFooter, "ZipperConfigSkipQuiet", L["Skip quiet stops"])
	quiet:SetPoint("TOPLEFT", purgeWrap, "BOTTOMLEFT", -4, -10)
	quiet:SetScript("OnClick", function(self)
		ns.Config:SetSkipQuiet(self:GetChecked())
	end)

	local quietNote = savedFooter:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	quietNote:SetPoint("TOPLEFT", quiet, "BOTTOMLEFT", 28, 2)
	quietNote:SetPoint("RIGHT", savedFooter, "RIGHT", 0, 0)
	quietNote:SetJustifyH("LEFT")
	quietNote:SetText(L["The next login drops a stop where you never turned in a quest, fought, died, or walked 250 yards from where you arrived. Checking mail or the auction house does not keep it."])

	local cleanupBtn = CreateFrame("Button", "ZipperConfigDropQuiet", savedFooter, "UIPanelButtonTemplate")
	cleanupBtn:SetSize(160, 22)
	cleanupBtn:SetPoint("BOTTOMLEFT", 0, 0)
	cleanupBtn:SetText(L["Clean up sessions..."])
	cleanupBtn:SetScript("OnClick", function()
		ns.Config:OpenCleanup()
	end)

	local isoScroll = CreateFrame("ScrollFrame", "ZipperConfigIsolationScroll", pages.saved, "UIPanelScrollFrameTemplate")
	isoScroll:SetPoint("TOPLEFT", isoHeader, "BOTTOMLEFT", 0, -4)
	isoScroll:SetPoint("BOTTOMRIGHT", savedFooter, "TOPRIGHT", -20, 10)
	local isoContent = CreateFrame("Frame", nil, isoScroll)
	isoContent:SetSize(400, 16)
	isoScroll:SetScrollChild(isoContent)
	self.isoSizeW = ISO_SIZE_W
	self.isoGlobalW = ISO_GLOBAL_W
	self.isoPrivateW = ISO_PRIVATE_W
	self.savedFooter = savedFooter

	self.pages = pages
	self.navButtons = navButtons
	self:ShowPage("general")

	local function Paint()
		-- OnRefresh runs for every canvas when the Options panel opens, even
		-- canvases that stay hidden. Skip until this page is the one on screen.
		if not canvas:IsShown() then
			return
		end
		ns.Config:ShowPage(ns.Config.page or "general")
		ns.Config:Refresh()
	end

	-- New frames start shown. Settings reparents an already-shown canvas without
	-- firing OnShow, so checkboxes kept blank defaults until something else
	-- refreshed them. Hide so the first display fires OnShow; OnRefresh covers
	-- every later open (Forever Quest Tint / Better Vendor Price pattern).
	canvas:Hide()
	canvas:SetScript("OnShow", Paint)
	canvas:SetScript("OnHide", function()
		if ns.Config.purgeList then
			ns.Config.purgeList:Hide()
		end
	end)
	canvas.OnRefresh = Paint

	local category
	if Settings and Settings.RegisterCanvasLayoutCategory then
		category = Settings.RegisterCanvasLayoutCategory(canvas, canvas.name)
		Settings.RegisterAddOnCategory(category)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(canvas)
	end

	self.frame = canvas
	self.category = category
	self.slider = slider
	self.sliderText = valueText
	self.glanceSlider = glance
	self.glanceText = glanceText
	self.sizeText = sizeText
	self.isoScroll = isoScroll
	self.isoContent = isoContent
	self.isoRows = {}
	self.purgeWrap = purgeWrap
	self.purgeDrop = purgeDrop
	self.purgeDropText = purgeText
	self.purgeList = purgeList
	self.purgeRows = {}
	self.purgeButton = purge
	self.boxes = boxes
	boxes.skipQuiet = quiet
end

function ns.Config:Refresh()
	if not self.boxes then
		return
	end
	local cfg = self:Get()
	self.boxes.remind:SetChecked(cfg.remind)
	self.boxes.path:SetChecked(self:Enabled("path"))
	self.boxes.showMarkers:SetChecked(self:ShowMarkers())
	if self.boxes.ghostRed then
		self.boxes.ghostRed:SetChecked(self:GhostRed())
	end
	if self.boxes.milestoneSummaries then
		self.boxes.milestoneSummaries:SetChecked(self:MilestoneSummaries())
	end
	if self.boxes.skipQuiet then
		self.boxes.skipQuiet:SetChecked(self:SkipQuiet())
	end
	for i = 1, #TRACKS do
		local key = TRACKS[i].key
		self.boxes[key]:SetChecked(self:Enabled(key))
	end
	self:RefreshSlider()
	if self.glanceSlider then
		self.lock = true
		self.glanceSlider:SetValue(self:GlanceIndex(cfg.glanceTrail))
		self.lock = false
		if self.glanceText then
			self.glanceText:SetText(self:GlanceLabel(cfg.glanceTrail))
		end
	end
	-- Sizing walks every open session. Let the Options panel draw, then fill
	-- the saved-data page in on the next frame.
	if self.frame and self.frame:IsShown() then
		self:QueueSavedRefresh()
	end
end

function ns.Config:QueueSavedRefresh()
	if self.savedRefreshQueued then
		return
	end
	self.savedRefreshQueued = true
	local function run()
		ns.Config.savedRefreshQueued = false
		if ns.Config.frame and ns.Config.frame:IsShown() then
			ns.Config:RefreshSize()
			ns.Config:RefreshIsolationList()
		end
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, run)
	else
		run()
	end
end

local function FormatBytes(bytes)
	if type(bytes) ~= "number" then
		return "—"
	end
	if bytes < 0 then
		bytes = 0
	end
	if bytes < 1024 then
		return string.format(L["%d B"], math.floor(bytes + 0.5))
	end
	if bytes < (1024 * 1024) then
		return string.format(L["%.1f KB"], bytes / 1024)
	end
	return string.format(L["%.2f MB"], bytes / (1024 * 1024))
end

function ns.Config:GrowthText()
	local perHour, span = ns.DB:SizeGrowth()
	if not perHour or perHour < 1 or (span or 0) < 300 then
		return ""
	end
	return string.format(L["About %s per hour."], FormatBytes(perHour))
end

function ns.Config:IsolationTooltip(row)
	if not row or not row.pending then
		return nil
	end
	if row.pending == "purgePrivate" then
		return L["You must log in to this character to finish deleting its Non-Global journey."]
	end
	if row.pending == "toGlobal" then
		return L["You must log in to this character to migrate its data to Global."]
	end
	if row.pending == "toPrivate" then
		return L["You must log in to this character to migrate its data to Non-Global."]
	end
	return L["You must log in to this character to migrate its data to Non-Global/Global."]
end

local function IsolationClicked(wantGlobal, box)
	local key = box.charKey
	if not key or not ns.DB.SetGlobal then
		return
	end
	ns.DB:SetGlobal(key, wantGlobal)
	ns.Config:RefreshIsolationList()
	ns.Config:RefreshPurgeList()
	ns.Config:RefreshSize()
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

function ns.Config:RefreshIsolationList()
	local content = self.isoContent
	if not content or not ns.DB or not ns.DB.CharacterList then
		return
	end
	local list = ns.DB:CharacterList()
	self.isoRows = self.isoRows or {}
	local width = (self.isoScroll and self.isoScroll:GetWidth()) or 400
	if width < 200 then
		width = 400
	end
	local sizeW = self.isoSizeW or 72
	local globalW = self.isoGlobalW or 70
	local privateW = self.isoPrivateW or 90
	local rightCols = sizeW + globalW + privateW
	content:SetWidth(width)
	for i = 1, #list do
		local info = list[i]
		local row = self.isoRows[i]
		if not row or not row.global or not row.size then
			row = CreateFrame("Frame", nil, content)
			row:SetHeight(24)
			row.warn = row:CreateTexture(nil, "ARTWORK")
			row.warn:SetSize(14, 14)
			row.warn:SetPoint("LEFT", 0, 0)
			row.warn:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
			row.warn:Hide()
			row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.label:SetJustifyH("LEFT")
			row.label:SetWordWrap(false)
			if row.label.SetNonSpaceWrap then
				row.label:SetNonSpaceWrap(false)
			end
			row.size = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.size:SetJustifyH("RIGHT")
			row.size:SetWordWrap(false)
			if row.size.SetNonSpaceWrap then
				row.size:SetNonSpaceWrap(false)
			end
			row.private = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
			row.private:SetSize(24, 24)
			row.private:SetScript("OnClick", function(box)
				IsolationClicked(false, box)
			end)
			row.global = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
			row.global:SetSize(24, 24)
			row.global:SetScript("OnClick", function(box)
				IsolationClicked(true, box)
			end)
			row:SetScript("OnEnter", function(frame)
				local tip = ns.Config:IsolationTooltip(frame.rowInfo)
				if tip then
					GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
					GameTooltip:SetText(tip, nil, nil, nil, nil, true)
					GameTooltip:Show()
					return
				end
				local label = frame.label
				local truncated = label and label.IsTruncated and label:IsTruncated()
				if truncated and frame.rowInfo then
					GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
					GameTooltip:SetText(frame.rowInfo.label)
					GameTooltip:Show()
				end
			end)
			row:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			self.isoRows[i] = row
		end
		row.rowInfo = info
		row.global.charKey = info.key
		row.private.charKey = info.key
		local isGlobal = info.scope ~= "private"
		row.global:SetChecked(isGlobal)
		row.private:SetChecked(not isGlobal)
		row.label:SetText(info.label)
		row.size:SetText(FormatBytes(info.bytes))
		local pendingOther = info.pending and info.key ~= ns.DB.playerKey
		row.warn:SetShown(pendingOther and true or false)
		row.label:ClearAllPoints()
		if pendingOther then
			row.label:SetPoint("LEFT", row.warn, "RIGHT", 4, 0)
			row.label:SetTextColor(1, 0.55, 0.2)
			row.size:SetTextColor(1, 0.55, 0.2)
		else
			row.label:SetPoint("LEFT", 0, 0)
			if info.current then
				row.label:SetTextColor(1, 0.86, 0.45)
				row.size:SetTextColor(1, 0.86, 0.45)
			else
				row.label:SetTextColor(0.9, 0.88, 0.78)
				row.size:SetTextColor(0.9, 0.88, 0.78)
			end
		end
		row.label:SetPoint("RIGHT", row, "RIGHT", -rightCols - 4, 0)
		row.size:ClearAllPoints()
		row.size:SetPoint("RIGHT", row, "RIGHT", -(globalW + privateW), 0)
		row.size:SetWidth(sizeW)
		row.private:ClearAllPoints()
		row.private:SetPoint("CENTER", row, "RIGHT", -(privateW / 2), 0)
		row.global:ClearAllPoints()
		row.global:SetPoint("CENTER", row, "RIGHT", -(privateW + globalW / 2), 0)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 24))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #list + 1, #self.isoRows do
		self.isoRows[i]:Hide()
	end
	content:SetHeight(math.max(16, #list * 24))
end

function ns.Config:PaintSize()
	if not self.sizeText then
		return
	end
	local text = string.format(L["Saved journeys  %s"], FormatBytes(self.accountBytes))
	local rate = self:GrowthText()
	if rate ~= "" then
		text = text .. "\n" .. rate
	end
	self.sizeText:SetText(text)
	self:RefreshPurgeList()
end

-- Settings is one of the two places that measure saved data. The other is the quiet poll.
function ns.Config:RefreshSize()
	if not self.sizeText or not ns.DB or not ns.DB.EstimateCharacter then
		return
	end
	self.characterBytes = ns.DB:EstimateCharacter()
	self.accountBytes = ns.DB:EstimateAll()
	self:PaintSize()
end

-- The other measurement. No chat output. A gap longer than 20 minutes starts the watch over.
function ns.Config:SampleSize()
	if not ns.DB or not ns.DB.char then
		return
	end
	local bytes = ns.DB:EstimateCharacter()
	if type(bytes) ~= "number" then
		return
	end
	ns.DB:RememberSize(bytes, ns.DB:Now())
	if self.sizeText and self.frame and self.frame:IsShown() then
		self.characterBytes = bytes
		self:PaintSize()
	end
end

function ns.Config:StartSizePoll()
	if self.sizePoll then
		return
	end
	self:SampleSize()
	self.sizePoll = C_Timer.NewTicker(5 * 60, function()
		ns.Config:SampleSize()
	end)
end

local function PurgePhrase(text)
	text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
	return text == "gone forever"
end

local function DialogEditBox(dialog)
	if dialog.GetEditBox then
		return dialog:GetEditBox()
	end
	return dialog.editBox
end

local function DialogAccept(dialog)
	if dialog.GetButton1 then
		return dialog:GetButton1()
	end
	return dialog.button1
end

function ns.Config:PurgeLabel(row)
	if not row then
		return L["Saved characters"]
	end
	return string.format("%s   %s", row.label, FormatBytes(row.bytes))
end

function ns.Config:RefreshPurgeList()
	if not self.purgeDropText or not ns.DB or not ns.DB.CharacterList then
		return
	end
	local list = ns.DB:CharacterList()
	local selected
	for i = 1, #list do
		if list[i].key == self.purgeKey then
			selected = list[i]
			break
		end
	end
	if not selected then
		selected = list[1]
		self.purgeKey = selected and selected.key or nil
	end
	self.purgeDropText:SetText(self:PurgeLabel(selected))
	if self.purgeButton then
		if selected then
			self.purgeButton:Enable()
		else
			self.purgeButton:Disable()
		end
	end
	local menu = self.purgeList
	if not menu then
		return
	end
	-- Dialog-box border insets from AceGUI's Dropdown-Pullout.
	local insetL, insetR, insetT, insetB = 14, 14, 14, 14
	local sizeW = 72
	self.purgeRows = self.purgeRows or {}
	for i = 1, #list do
		local row = self.purgeRows[i]
		if not row or not row.size then
			row = CreateFrame("Button", nil, menu)
			row:SetHeight(16)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetJustifyH("LEFT")
			row.label:SetWordWrap(false)
			if row.label.SetNonSpaceWrap then
				row.label:SetNonSpaceWrap(false)
			end
			row.size = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.size:SetJustifyH("RIGHT")
			row.size:SetWordWrap(false)
			if row.size.SetNonSpaceWrap then
				row.size:SetNonSpaceWrap(false)
			end
			row:SetScript("OnClick", function(button)
				ns.Config.purgeKey = button.charKey
				if ns.Config.purgeList then
					ns.Config.purgeList:Hide()
				end
				ns.Config:RefreshPurgeList()
			end)
			row:SetScript("OnEnter", function(frame)
				frame.label:SetTextColor(1, 0.82, 0)
				frame.size:SetTextColor(1, 0.82, 0)
			end)
			row:SetScript("OnLeave", function(frame)
				local color = (frame.charKey == ns.Config.purgeKey) and { 1, 0.82, 0 } or { 1, 1, 1 }
				frame.label:SetTextColor(color[1], color[2], color[3])
				frame.size:SetTextColor(color[1], color[2], color[3])
			end)
			self.purgeRows[i] = row
		end
		row.charKey = list[i].key
		row.label:SetText(list[i].label)
		row.size:SetText(FormatBytes(list[i].bytes))
		local r, g, b = 1, 1, 1
		if list[i].key == self.purgeKey then
			r, g, b = 1, 0.82, 0
		end
		row.label:SetTextColor(r, g, b)
		row.size:SetTextColor(r, g, b)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", menu, "TOPLEFT", insetL, -insetT - ((i - 1) * 16))
		row:SetPoint("RIGHT", menu, "RIGHT", -insetR, 0)
		row.size:ClearAllPoints()
		row.size:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		row.size:SetWidth(sizeW)
		row.label:ClearAllPoints()
		row.label:SetPoint("LEFT", 0, 0)
		row.label:SetPoint("RIGHT", row.size, "LEFT", -6, 0)
		row:Show()
	end
	for i = #list + 1, #self.purgeRows do
		self.purgeRows[i]:Hide()
	end
	menu:SetHeight(math.max(40, #list * 16 + insetT + insetB))
end

function ns.Config:TogglePurgeList()
	local menu = self.purgeList
	if not menu then
		return
	end
	if menu:IsShown() then
		menu:Hide()
		return
	end
	self:RefreshPurgeList()
	menu:Show()
end

local function PurgeIsDeferred(key, journey)
	if not key or type(journey) ~= "table" then
		return false
	end
	if key == ns.DB.playerKey then
		return false
	end
	if type(journey.sessions) == "table" then
		return false
	end
	return journey.scope == "private"
		or journey.pending == "toGlobal"
		or journey.pending == "purgePrivate"
end

function ns.Config:ConfirmPurge()
	if not StaticPopupDialogs or not StaticPopup_Show then
		return
	end
	local key = self.purgeKey
	local journey = key and ZipperDB and ZipperDB.journeys and ZipperDB.journeys[key]
	if type(journey) ~= "table" then
		return
	end
	local label = ns.DB:JourneyLabel(journey)
	if not StaticPopupDialogs.ZIPPER_PURGE then
		StaticPopupDialogs.ZIPPER_PURGE = {
			text = L["Delete %s?\n\nType gone forever to confirm."],
			button1 = L["Delete"],
			button2 = L["Cancel"],
			hasEditBox = true,
			maxLetters = 32,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
			OnShow = function(dialog)
				local which = dialog.data
				local row = which and ZipperDB and ZipperDB.journeys and ZipperDB.journeys[which]
				local name = ns.DB:JourneyLabel(row)
				dialog.deferredPurge = PurgeIsDeferred(which, row)
				dialog.charLabel = name
				if dialog.text then
					if dialog.deferredPurge then
						dialog.text:SetText(string.format(
							L["Delete %s?\n\nIts Non-Global journey is wiped the next time that character logs in.\n\nType gone forever to confirm."],
							name
						))
					else
						dialog.text:SetText(string.format(
							L["Delete %s?\n\nType gone forever to confirm."],
							name
						))
					end
				end
				local box = DialogEditBox(dialog)
				if box then
					box:SetText("")
					box:SetFocus()
				end
				local accept = DialogAccept(dialog)
				if accept then
					accept:Disable()
				end
			end,
			EditBoxOnTextChanged = function(editBox)
				local dialog = editBox:GetParent()
				local accept = DialogAccept(dialog)
				if accept then
					if PurgePhrase(editBox:GetText()) then
						accept:Enable()
					else
						accept:Disable()
					end
				end
			end,
			OnAccept = function(dialog, data)
				local box = DialogEditBox(dialog)
				if not box or not PurgePhrase(box:GetText()) then
					return
				end
				local which = data or ns.Config.purgeKey
				local gone = which and ZipperDB and ZipperDB.journeys and ZipperDB.journeys[which]
				local name = ns.DB:JourneyLabel(gone)
				local deferred = dialog.deferredPurge
				if ns.DB:Purge(which) then
					ns.Config.purgeKey = nil
					ns.Config:RefreshSize()
					ns.Config:RefreshIsolationList()
					ns.Config:RefreshPurgeList()
					if deferred then
						ns:Print(string.format(L["%s will be wiped the next time that character logs in."], name))
					else
						ns:Print(string.format(L["%s is gone."], name))
					end
				end
			end,
		}
	end
	StaticPopup_Show("ZIPPER_PURGE", label, nil, key)
end

local CLEANUP_PRESETS = {
	{
		id = "quiet",
		label = L["Quiet stops"],
		note = L["Stops with no kills, quests, level-ups, events, or 250 yards of travel."],
		defaultCap = true,
		usesPreCap = false,
		usesCraftFish = false,
	},
	{
		id = "idle",
		label = L["Mostly idle"],
		note = L["Sessions where at least 80% of the time was idle or AFK, with no combat, quests, or instances."],
		defaultCap = false,
		usesPreCap = false,
		usesCraftFish = false,
	},
	{
		id = "city",
		label = L["City only"],
		note = L["Sessions spent entirely in capital cities with no combat, quests, instances, or XP."],
		defaultCap = true,
		usesPreCap = true,
		usesCraftFish = true,
	},
	{
		id = "short",
		label = L["Short stops"],
		note = L["Sessions under 15 minutes with no combat, quests, instances, or XP."],
		defaultCap = true,
		usesPreCap = true,
		usesCraftFish = true,
	},
}

local function CleanupPresetMeta(id)
	for i = 1, #CLEANUP_PRESETS do
		if CLEANUP_PRESETS[i].id == id then
			return CLEANUP_PRESETS[i]
		end
	end
	return CLEANUP_PRESETS[1]
end

local function FormatShortDuration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local hours = math.floor(seconds / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	if hours > 0 then
		return string.format(L["%dh %dm"], hours, mins)
	end
	if mins > 0 then
		return string.format(L["%dm %02ds"], mins, secs)
	end
	return string.format(L["%ds"], secs)
end

local function MakeCleanupButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
	button:SetSize(width, 22)
	button:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	button:SetBackdropColor(0.12, 0.11, 0.10, 1)
	button:SetBackdropBorderColor(0.38, 0.32, 0.16, 0.9)
	local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("CENTER")
	label:SetText(text)
	button:SetFontString(label)
	return button
end

local function StyleCleanupButton(button, active)
	if not button then
		return
	end
	local font = button:GetFontString()
	if font then
		if active then
			font:SetTextColor(1, 0.86, 0.45)
		else
			font:SetTextColor(0.78, 0.76, 0.70)
		end
	end
	if active then
		button:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
		button:SetBackdropColor(0.20, 0.16, 0.08, 1)
	else
		button:SetBackdropBorderColor(0.38, 0.32, 0.16, 0.9)
		button:SetBackdropColor(0.12, 0.11, 0.10, 1)
	end
end

function ns.Config:CreateCleanupFrame()
	if self.cleanupFrame then
		return self.cleanupFrame
	end
	local frame = CreateFrame("Frame", "ZipperCleanupFrame", UIParent, "BackdropTemplate")
	frame:SetSize(580, 450)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetFrameLevel(30)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(0.07, 0.07, 0.08, 0.96)
	frame:SetBackdropBorderColor(0.58, 0.46, 0.20, 0.95)
	frame:Hide()
	tinsert(UISpecialFrames, "ZipperCleanupFrame")

	local headerBg = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	headerBg:SetColorTexture(0.12, 0.10, 0.08, 1)
	headerBg:SetPoint("TOPLEFT", 2, -2)
	headerBg:SetPoint("TOPRIGHT", -2, -2)
	headerBg:SetHeight(38)

	local headerSheen = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
	headerSheen:SetColorTexture(1, 0.86, 0.45, 0.07)
	headerSheen:SetPoint("TOPLEFT", headerBg, "TOPLEFT", 0, 0)
	headerSheen:SetPoint("TOPRIGHT", headerBg, "TOPRIGHT", 0, 0)
	headerSheen:SetHeight(14)

	local headerRule = frame:CreateTexture(nil, "BORDER")
	headerRule:SetColorTexture(0.85, 0.68, 0.28, 0.95)
	headerRule:SetPoint("TOPLEFT", headerBg, "BOTTOMLEFT", 0, 0)
	headerRule:SetPoint("TOPRIGHT", headerBg, "BOTTOMRIGHT", 0, 0)
	headerRule:SetHeight(2)

	local brandIcon = frame:CreateTexture(nil, "ARTWORK")
	brandIcon:SetSize(20, 20)
	brandIcon:SetPoint("LEFT", headerBg, "LEFT", 14, 0)
	brandIcon:SetTexture("Interface\\AddOns\\Zipper\\Media\\MapButton")

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("LEFT", brandIcon, "RIGHT", 8, 0)
	title:SetTextColor(1, 0.86, 0.45)
	title:SetText(L["Zipper — Session Cleanup"])

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function()
		frame:Hide()
	end)

	-- Preset row
	local presetButtons = {}
	local prevBtn
	for i = 1, #CLEANUP_PRESETS do
		local meta = CLEANUP_PRESETS[i]
		local btn = MakeCleanupButton(frame, meta.label, 108)
		if prevBtn then
			btn:SetPoint("LEFT", prevBtn, "RIGHT", 6, 0)
		else
			btn:SetPoint("TOPLEFT", 16, -50)
		end
		btn.presetId = meta.id
		btn:SetScript("OnClick", function(selfBtn)
			ns.Config:SetCleanupPreset(selfBtn.presetId)
		end)
		presetButtons[meta.id] = btn
		prevBtn = btn
	end

	-- Scope row
	local scopeAll = MakeCleanupButton(frame, L["All Global"], 86)
	scopeAll:SetPoint("TOPLEFT", 16, -80)
	scopeAll:SetScript("OnClick", function()
		ns.Config.cleanupScope = "all"
		ns.Config:RefreshCleanup()
	end)
	local scopeCur = MakeCleanupButton(frame, L["This character"], 108)
	scopeCur:SetPoint("LEFT", scopeAll, "RIGHT", 6, 0)
	scopeCur:SetScript("OnClick", function()
		ns.Config.cleanupScope = "current"
		ns.Config:RefreshCleanup()
	end)

	local function WireGuardTooltip(box)
		if box.SetMotionScriptsWhileDisabled then
			box:SetMotionScriptsWhileDisabled(true)
		end
		box:SetScript("OnEnter", function(selfBox)
			if not GameTooltip or not selfBox.tipText then
				return
			end
			GameTooltip:SetOwner(selfBox, "ANCHOR_TOPLEFT")
			GameTooltip:SetText(selfBox.tipTitle or "", 1, 0.86, 0.45)
			GameTooltip:AddLine(selfBox.tipText, 0.85, 0.85, 0.85, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", function(selfBox)
			if GameTooltip and GameTooltip:IsOwned(selfBox) then
				GameTooltip:Hide()
			end
		end)
	end

	-- Guard checkboxes (anchored to frame so widths never collide or overflow)
	local guardPreCap = AddCheck(frame, "ZipperCleanupPreCap", L["Protect pre-60 sessions"])
	guardPreCap:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -106)
	guardPreCap.tipTitle = L["Protect pre-60 sessions"]
	WireGuardTooltip(guardPreCap)
	guardPreCap:SetScript("OnClick", function(selfBox)
		ns.Config.cleanupProtectPreCap = selfBox:GetChecked() and true or false
		ns.Config:RefreshCleanup()
	end)

	local guardCap = AddCheck(frame, "ZipperCleanupCap15", L["Skip sessions over 15m"])
	guardCap:SetPoint("TOPLEFT", frame, "TOPLEFT", 198, -106)
	guardCap.tipTitle = L["Skip sessions over 15m"]
	WireGuardTooltip(guardCap)
	guardCap:SetScript("OnClick", function(selfBox)
		ns.Config.cleanupCap15 = selfBox:GetChecked() and true or false
		ns.Config:RefreshCleanup()
	end)

	local guardCraft = AddCheck(frame, "ZipperCleanupKeepCraft", L["Keep crafting & fishing"])
	guardCraft:SetPoint("TOPLEFT", frame, "TOPLEFT", 384, -106)
	guardCraft.tipTitle = L["Keep crafting & fishing"]
	WireGuardTooltip(guardCraft)
	guardCraft:SetScript("OnClick", function(selfBox)
		ns.Config.cleanupKeepCraft = selfBox:GetChecked() and true or false
		ns.Config:RefreshCleanup()
	end)

	local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 16, -138)
	note:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)

	-- Column headers + Select all / none
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 16, -168)
	header:SetPoint("TOPRIGHT", -38, -168)
	header:SetHeight(18)

	local hChar = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hChar:SetPoint("LEFT", 26, 0)
	hChar:SetWidth(120)
	hChar:SetJustifyH("LEFT")
	hChar:SetText(L["Character"])

	local hDate = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hDate:SetPoint("LEFT", hChar, "RIGHT", 6, 0)
	hDate:SetWidth(86)
	hDate:SetJustifyH("LEFT")
	hDate:SetText(L["Date"])

	local hDur = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hDur:SetPoint("LEFT", hDate, "RIGHT", 6, 0)
	hDur:SetWidth(68)
	hDur:SetJustifyH("RIGHT")
	hDur:SetText(L["Duration"])

	local hReason = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hReason:SetPoint("LEFT", hDur, "RIGHT", 10, 0)
	hReason:SetWidth(110)
	hReason:SetJustifyH("LEFT")
	hReason:SetText(L["Reason"])

	local hSize = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hSize:SetPoint("RIGHT", 0, 0)
	hSize:SetWidth(64)
	hSize:SetJustifyH("RIGHT")
	hSize:SetText(L["Size"])

	local selNone = MakeCleanupButton(frame, L["Select none"], 82)
	selNone:SetPoint("TOPRIGHT", -16, -80)
	selNone:SetScript("OnClick", function()
		ns.Config:SetAllCleanupChecked(false)
	end)
	local selAll = MakeCleanupButton(frame, L["Select all"], 74)
	selAll:SetPoint("RIGHT", selNone, "LEFT", -6, 0)
	selAll:SetScript("OnClick", function()
		ns.Config:SetAllCleanupChecked(true)
	end)

	-- Results scroll list
	local inset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	inset:SetPoint("TOPLEFT", 16, -188)
	inset:SetPoint("BOTTOMRIGHT", -16, 48)
	inset:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	inset:SetBackdropColor(0, 0, 0, 0.35)
	inset:SetBackdropBorderColor(0.35, 0.30, 0.16, 0.85)

	local scroll = CreateFrame("ScrollFrame", "ZipperCleanupScroll", inset, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(510, 24)
	scroll:SetScrollChild(content)

	local emptyText = inset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	emptyText:SetPoint("CENTER")
	emptyText:SetText(L["No matching sessions found."])
	emptyText:Hide()

	-- Footer
	local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summary:SetPoint("BOTTOMLEFT", 16, 18)
	summary:SetPoint("RIGHT", frame, "RIGHT", -210, 0)
	summary:SetJustifyH("LEFT")

	local deleteBtn = CreateFrame("Button", "ZipperCleanupDeleteBtn", frame, "UIPanelButtonTemplate")
	deleteBtn:SetSize(112, 24)
	deleteBtn:SetPoint("BOTTOMRIGHT", -16, 13)
	deleteBtn:SetText(L["Delete selected"])
	deleteBtn:SetScript("OnClick", function()
		ns.Config:ConfirmCleanupDelete()
	end)

	local rescanBtn = CreateFrame("Button", "ZipperCleanupRescanBtn", frame, "UIPanelButtonTemplate")
	rescanBtn:SetSize(74, 24)
	rescanBtn:SetPoint("RIGHT", deleteBtn, "LEFT", -8, 0)
	rescanBtn:SetText(L["Rescan"])
	rescanBtn:SetScript("OnClick", function()
		ns.Config:RefreshCleanup()
	end)

	self.cleanupFrame = frame
	self.cleanupPresetButtons = presetButtons
	self.cleanupScopeAll = scopeAll
	self.cleanupScopeCur = scopeCur
	self.cleanupGuardPreCap = guardPreCap
	self.cleanupGuardCap = guardCap
	self.cleanupGuardCraft = guardCraft
	self.cleanupNote = note
	self.cleanupScroll = scroll
	self.cleanupContent = content
	self.cleanupEmpty = emptyText
	self.cleanupSummary = summary
	self.cleanupDeleteBtn = deleteBtn
	self.cleanupRows = {}
	self.cleanupMatches = {}
	self.cleanupChecked = {}
	self.cleanupPreset = "quiet"
	self.cleanupScope = "all"
	self.cleanupProtectPreCap = true
	self.cleanupCap15 = true
	self.cleanupKeepCraft = true
	return frame
end

function ns.Config:SetCleanupPreset(presetId)
	local meta = CleanupPresetMeta(presetId)
	self.cleanupPreset = meta.id
	self.cleanupCap15 = meta.defaultCap and true or false
	self:RefreshCleanup()
end

function ns.Config:UpdateCleanupSummary()
	local matches = self.cleanupMatches or {}
	local checked = self.cleanupChecked or {}
	local selected = 0
	local totalSec = 0
	local totalBytes = 0
	for i = 1, #matches do
		if checked[i] then
			selected = selected + 1
			totalSec = totalSec + (matches[i].duration or 0)
			totalBytes = totalBytes + (matches[i].bytes or 0)
		end
	end
	if self.cleanupSummary then
		self.cleanupSummary:SetText(string.format(
			L["%d of %d selected  |  %s  |  ~%s"],
			selected, #matches, FormatShortDuration(totalSec), FormatBytes(totalBytes)
		))
	end
	if self.cleanupDeleteBtn then
		if selected > 0 then
			self.cleanupDeleteBtn:Enable()
		else
			self.cleanupDeleteBtn:Disable()
		end
	end
end

function ns.Config:SetAllCleanupChecked(state)
	local matches = self.cleanupMatches or {}
	self.cleanupChecked = self.cleanupChecked or {}
	for i = 1, #matches do
		self.cleanupChecked[i] = state and true or false
		local row = self.cleanupRows and self.cleanupRows[i]
		if row and row.check then
			row.check:SetChecked(state and true or false)
		end
	end
	self:UpdateCleanupSummary()
end

function ns.Config:RefreshCleanup()
	local frame = self:CreateCleanupFrame()
	local meta = CleanupPresetMeta(self.cleanupPreset or "quiet")
	for id, btn in pairs(self.cleanupPresetButtons) do
		StyleCleanupButton(btn, id == meta.id)
	end
	StyleCleanupButton(self.cleanupScopeAll, (self.cleanupScope or "all") == "all")
	StyleCleanupButton(self.cleanupScopeCur, self.cleanupScope == "current")

	self.cleanupGuardPreCap:SetChecked(meta.usesPreCap and (self.cleanupProtectPreCap ~= false) or false)
	self.cleanupGuardPreCap:SetEnabled(meta.usesPreCap)
	self.cleanupGuardPreCap:SetAlpha(meta.usesPreCap and 1 or 0.45)
	self.cleanupGuardPreCap.tipText = meta.usesPreCap
		and L["Skip sessions recorded below level 60 so leveling history is not flagged."]
		or L["Not used by this preset. Quiet and idle stops can be found at any level; sessions with XP, kills, quests, or instances are always protected."]

	self.cleanupGuardCap:SetChecked(meta.id == "short" or (self.cleanupCap15 and true or false))
	self.cleanupGuardCap:SetEnabled(meta.id ~= "short")
	self.cleanupGuardCap:SetAlpha(meta.id ~= "short" and 1 or 0.45)
	self.cleanupGuardCap.tipText = meta.id == "short"
		and L["Always on for Short stops, which only looks for sessions under 15 minutes."]
		or L["Leave sessions longer than 15 minutes out of the results."]

	self.cleanupGuardCraft:SetChecked(not meta.usesCraftFish or (self.cleanupKeepCraft ~= false))
	self.cleanupGuardCraft:SetEnabled(meta.usesCraftFish)
	self.cleanupGuardCraft:SetAlpha(meta.usesCraftFish and 1 or 0.45)
	self.cleanupGuardCraft.tipText = meta.usesCraftFish
		and L["Leave sessions where you crafted or fished out of the results."]
		or L["Always on for this preset. Sessions with crafting or fishing are never flagged here."]

	self.cleanupNote:SetText(meta.note)

	local matches = ns.DB:FindCleanupSessions({
		preset = meta.id,
		scope = self.cleanupScope or "all",
		maxMinutes = (meta.id == "short" or self.cleanupCap15) and 15 or nil,
		idlePct = 80,
		protectPreCap = self.cleanupProtectPreCap ~= false,
		keepCraftFish = self.cleanupKeepCraft ~= false,
	})
	self.cleanupMatches = matches
	self.cleanupChecked = {}
	for i = 1, #matches do
		self.cleanupChecked[i] = true
	end

	local content = self.cleanupContent
	local width = (content:GetParent() and content:GetParent():GetWidth()) or 510
	if width < 200 then
		width = 510
	end
	content:SetWidth(width)

	for i = 1, #matches do
		local item = matches[i]
		local row = self.cleanupRows[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetHeight(24)
			row.bg = row:CreateTexture(nil, "BACKGROUND")
			row.bg:SetAllPoints()
			row.check = CreateFrame("CheckButton", nil, row, "InterfaceOptionsCheckButtonTemplate")
			row.check:SetSize(20, 20)
			row.check:SetPoint("LEFT", 2, 0)
			row.check:SetScript("OnClick", function(box)
				local idx = box:GetParent().matchIndex
				if idx then
					ns.Config.cleanupChecked[idx] = box:GetChecked() and true or false
					ns.Config:UpdateCleanupSummary()
				end
			end)
			row.charText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.charText:SetPoint("LEFT", 26, 0)
			row.charText:SetWidth(120)
			row.charText:SetJustifyH("LEFT")
			row.charText:SetWordWrap(false)

			row.dateText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.dateText:SetPoint("LEFT", row.charText, "RIGHT", 6, 0)
			row.dateText:SetWidth(86)
			row.dateText:SetJustifyH("LEFT")
			row.dateText:SetWordWrap(false)

			row.durText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.durText:SetPoint("LEFT", row.dateText, "RIGHT", 6, 0)
			row.durText:SetWidth(68)
			row.durText:SetJustifyH("RIGHT")
			row.durText:SetWordWrap(false)

			row.reasonText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			row.reasonText:SetPoint("LEFT", row.durText, "RIGHT", 10, 0)
			row.reasonText:SetWidth(110)
			row.reasonText:SetJustifyH("LEFT")
			row.reasonText:SetWordWrap(false)

			row.sizeText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.sizeText:SetPoint("RIGHT", -4, 0)
			row.sizeText:SetWidth(64)
			row.sizeText:SetJustifyH("RIGHT")
			row.sizeText:SetWordWrap(false)

			row:SetScript("OnClick", function(selfRow)
				local idx = selfRow.matchIndex
				if not idx then
					return
				end
				local nextState = not ns.Config.cleanupChecked[idx]
				ns.Config.cleanupChecked[idx] = nextState
				selfRow.check:SetChecked(nextState)
				ns.Config:UpdateCleanupSummary()
			end)
			self.cleanupRows[i] = row
		end
		row.matchIndex = i
		row.check:SetChecked(true)
		row.charText:SetText(item.charLabel or "")
		row.dateText:SetText(date("%m/%d %H:%M", item.session.s))
		row.durText:SetText(FormatShortDuration(item.duration))
		row.reasonText:SetText(item.reason or "")
		row.sizeText:SetText(FormatBytes(item.bytes))
		if i % 2 == 0 then
			row.bg:SetColorTexture(1, 1, 1, 0.03)
		else
			row.bg:SetColorTexture(0, 0, 0, 0)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 24))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #matches + 1, #self.cleanupRows do
		self.cleanupRows[i]:Hide()
	end
	content:SetHeight(math.max(24, #matches * 24))
	if self.cleanupScroll and self.cleanupScroll.SetVerticalScroll then
		self.cleanupScroll:SetVerticalScroll(0)
	end
	self.cleanupEmpty:SetShown(#matches == 0)
	self:UpdateCleanupSummary()
	frame:Show()
end

function ns.Config:OpenCleanup()
	self:CreateCleanupFrame()
	self:RefreshCleanup()
end

function ns.Config:ConfirmCleanupDelete()
	local matches = self.cleanupMatches or {}
	local checked = self.cleanupChecked or {}
	local selected = {}
	local totalBytes = 0
	for i = 1, #matches do
		if checked[i] then
			selected[#selected + 1] = matches[i]
			totalBytes = totalBytes + (matches[i].bytes or 0)
		end
	end
	if #selected == 0 then
		return
	end
	if not StaticPopupDialogs or not StaticPopup_Show then
		self:ExecuteCleanupDelete(selected)
		return
	end
	if not StaticPopupDialogs.ZIPPER_CLEANUP_CONFIRM then
		StaticPopupDialogs.ZIPPER_CLEANUP_CONFIRM = {
			text = "%s",
			button1 = L["Delete"],
			button2 = L["Cancel"],
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
			OnAccept = function(_, data)
				if type(data) == "table" and type(data.items) == "table" then
					ns.Config:ExecuteCleanupDelete(data.items)
				end
			end,
		}
	end
	local msg
	if #selected == 1 then
		msg = string.format(L["Delete 1 session (~%s)?\n\nThis cannot be undone."], FormatBytes(totalBytes))
	else
		msg = string.format(L["Delete %d sessions (~%s)?\n\nThis cannot be undone."], #selected, FormatBytes(totalBytes))
	end
	StaticPopup_Show("ZIPPER_CLEANUP_CONFIRM", msg, nil, {
		items = selected,
	})
end

function ns.Config:ExecuteCleanupDelete(items)
	local snap = ns.Replay and ns.Replay.CaptureSelectionRefs and ns.Replay:CaptureSelectionRefs() or nil
	local dropped, freed = ns.DB:DeleteSessions(items)
	if dropped == 1 then
		ns:Print(string.format(L["Deleted 1 session (~%s)."], FormatBytes(freed)))
	elseif dropped > 1 then
		ns:Print(string.format(L["Deleted %d sessions (~%s)."], dropped, FormatBytes(freed)))
	end
	if ns.Replay and ns.Replay.RestoreSelectionAfterDelete then
		ns.Replay:RestoreSelectionAfterDelete(snap)
	end
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
	self:RefreshSize()
	self:RefreshIsolationList()
	self:RefreshPurgeList()
	if self.cleanupFrame and self.cleanupFrame:IsShown() then
		self:RefreshCleanup()
	end
end

function ns.Config:OpenSaved()
	self.page = "saved"
	self:CreateFrame()
	self:ShowPage("saved")
	if Settings and Settings.OpenToCategory and self.category then
		Settings.OpenToCategory(self.category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(self.frame)
		InterfaceOptionsFrame_OpenToCategory(self.frame)
	end
	self:Refresh()
end

function ns.Config:Toggle()
	self:CreateFrame()
	if Settings and Settings.OpenToCategory and self.category then
		Settings.OpenToCategory(self.category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(self.frame)
		InterfaceOptionsFrame_OpenToCategory(self.frame)
	end
	self:Refresh()
end

ns.Config:CreateFrame()
